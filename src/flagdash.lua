local flagdash = { _VERSION = "0.1.0" }
flagdash.BackendReplay = require("flagdash_replay")

local function now()
  return os.time()
end

local function encode(value)
  return tostring(value):gsub("([^%w%-_%.~])", function(char)
    return string.format("%%%02X", string.byte(char))
  end)
end

local function default_transport(method, url, query, body, sdk_key, timeout)
  local http = url:match("^https://") and require("ssl.https") or require("socket.http")
  local ltn12 = require("ltn12")
  local json = require("dkjson")
  local pairs_list = {}
  for key, value in pairs(query or {}) do
    pairs_list[#pairs_list + 1] = encode(key) .. "=" .. encode(value)
  end
  table.sort(pairs_list)
  if #pairs_list > 0 then url = url .. "?" .. table.concat(pairs_list, "&") end
  local payload = body and json.encode(body) or nil
  local chunks = {}
  http.TIMEOUT = timeout
  local _, status = http.request({
    method = method, url = url,
    headers = { authorization = "Bearer " .. sdk_key, accept = "application/json", ["content-type"] = "application/json", ["content-length"] = payload and #payload or 0 },
    source = payload and ltn12.source.string(payload) or nil,
    sink = ltn12.sink.table(chunks), protocol = "tlsv1_2"
  })
  if tonumber(status) < 200 or tonumber(status) >= 300 then error("FlagDash HTTP " .. tostring(status)) end
  local decoded, _, err = json.decode(table.concat(chunks), 1, nil)
  if err then error(err) end
  return decoded
end

local Client = {}
Client.__index = Client

function flagdash.new(sdk_key, options)
  if not sdk_key or sdk_key == "" then error("sdk_key is required") end
  options = options or {}
  local region_names = { "FLAGDASH_REGION", "FLY_REGION", "AWS_REGION", "AWS_DEFAULT_REGION", "VERCEL_REGION", "GOOGLE_CLOUD_REGION", "RAILWAY_REPLICA_REGION", "RENDER_REGION" }
  local region = options.region
  if region == nil then
    for _, name in ipairs(region_names) do if os.getenv(name) then region = os.getenv(name); break end end
  end
  return setmetatable({
    sdk_key = sdk_key, base_url = (options.base_url or "https://flagdash.io"):gsub("/$", ""),
    timeout = options.timeout or 5, cache_ttl = options.cache_ttl or 60, region = region,
    transport = options.transport or default_transport, cache = {}, events = {}
  }, Client)
end

function Client:_context(context)
  local result = {}
  for key, value in pairs(context or {}) do
    if key == "user" and type(value) == "table" then
      for user_key, user_value in pairs(value) do result[user_key == "id" and "user_id" or "user_" .. user_key] = user_value end
    elseif type(value) ~= "table" then result[key] = value end
  end
  if self.region and result.region == nil then result.region = self.region end
  return result
end

function Client:_request(method, path, query, body)
  return self.transport(method, self.base_url .. "/api/v1" .. path, query or {}, body, self.sdk_key, self.timeout)
end

function Client:_cached(key, loader)
  local hit = self.cache[key]
  if self.cache_ttl > 0 and hit and hit.expires > now() then return hit.value end
  local value = loader()
  if self.cache_ttl > 0 then self.cache[key] = { value = value, expires = now() + self.cache_ttl } end
  return value
end

function Client:all_flags(context)
  local function load()
    local values = (self:_request("GET", "/server/flags", self:_context(context)).evaluated or {})
    if not context or next(context) == nil then
      for key, value in pairs(values) do self.cache["flag:" .. key] = { value = value, expires = now() + self.cache_ttl } end
    end
    return values
  end
  if context and next(context) ~= nil then return load() end
  return self:_cached("all_flags", load)
end

function Client:flag(key, default, context)
  default = default == nil and false or default
  if context and next(context) ~= nil then return self:flag_detail(key, default, context).value end
  return self:_cached("flag:" .. key, function() local value = self:all_flags()[key]; if value == nil then return default end; return value end)
end

function Client:flag_detail(key, default, context)
  local ok, data = pcall(self._request, self, "GET", "/server/flags/" .. encode(key), self:_context(context))
  if not ok or not data.flag then return { key = key, value = default, reason = "default" } end
  local item = data.flag
  return { key = item.key or key, value = item.evaluated_value == nil and default or item.evaluated_value,
    reason = item.evaluation_path or "default", variation_key = item.variation_key }
end

function Client:config(key, default)
  local ok, value = pcall(function()
    return self:_cached("config:" .. key, function() return (self:_request("GET", "/server/configs/" .. encode(key)).config or {}).value end)
  end)
  return ok and value ~= nil and value or default
end

function Client:list_configs() return self:_request("GET", "/server/configs").configs or {} end

-- Fetch a decrypted secret by key.
--
-- Deliberately unlike :config() — never cached, never defaulted, and it raises
-- on failure. Returning a stale or default credential is worse than failing
-- loudly: a rotated key must take effect on the next call.
--
-- Requires an sk_ key carrying the secrets:read scope.
function Client:get_secret(key)
  local secret = self:_request("GET", "/server/secrets/" .. encode(key)).secret
  if type(secret) ~= "table" or secret.value == nil then
    error("FlagDash: secret '" .. tostring(key) .. "' returned no value", 2)
  end
  return secret
end

-- Just the decrypted value. Raises for the same reasons as :get_secret().
-- Explicit backend resolution. Never cached; errors propagate.
function Client:resolve_config(key)
  return assert(self:_request("POST", "/server/configs/" .. encode(key) .. "/resolve", {}, {}).config, "Resolved config missing")
end
function Client:resolve_ai_release(key, user_id)
  return assert(self:_request("POST", "/server/ai-config-releases/" .. encode(key) .. "/resolve", {}, {user_id = user_id or "anonymous"}).ai_config, "Resolved AI release missing")
end

function Client:secret(key) return self:get_secret(key).value end
-- Uncached evaluation; secret references remain unresolved.
function Client:ai_config_release(key, user_id)
  return self:_request("GET", "/ai-config-releases/" .. encode(key), {user_id = user_id or "anonymous"}).ai_config
end

function Client:ai_config(name)
  local ok, value = pcall(function() return self:_cached("ai:" .. name, function() return self:_request("GET", "/server/ai-configs/" .. encode(name)).ai_config end) end)
  return ok and value or nil
end
function Client:list_ai_configs() return self:_request("GET", "/server/ai-configs").ai_configs or {} end

function Client:translation(key, locale, default, variables)
  local namespace, message = key:match("^([^.]+)%.(.+)$")
  if not message then return default or key end
  local ok, result = pcall(function()
    local catalog = self:_cached("translation:" .. locale .. ":" .. namespace, function()
      return self:_request("GET", "/server/translations/" .. encode(locale) .. "/" .. encode(namespace)).catalog or {}
    end)
    local pattern = (catalog.messages or {})[message]
    if not pattern then return default or key end
    return pattern:gsub("{([%w.]+)}", function(name) return tostring((variables or {})[name] or "{" .. name .. "}") end)
  end)
  return ok and result or default or key
end

function Client:experiment(key, context)
  local identity = context and (context.user_id or context.unit_id or (context.user and context.user.id))
  if not identity then return nil end
  local ok, data = pcall(self._request, self, "GET", "/server/experiments/" .. encode(key), self:_context(context))
  return ok and data.experiment or nil
end

function Client:track_experiment_metric(experiment_key, event_name, user_id, options)
  if #self.events >= 1000 then return end
  options = options or {}
  self.events[#self.events + 1] = { event_id = options.event_id or "evt_" .. tostring(now()) .. "_" .. tostring(#self.events + 1),
    experiment_key = experiment_key, event_name = event_name, user_id = user_id, value = options.value,
    properties = options.properties or {}, occurred_at = options.occurred_at or os.date("!%Y-%m-%dT%H:%M:%SZ") }
end

function Client:flush()
  while #self.events > 0 do
    local batch = {}; for index = 1, math.min(100, #self.events) do batch[index] = self.events[index] end
    local ok = pcall(self._request, self, "POST", "/server/experiment-events/batch", {}, { events = batch })
    if not ok then return false end
    for _ = 1, #batch do table.remove(self.events, 1) end
  end
  return true
end
function Client:clear_cache() self.cache = {} end
function Client:close() return self:flush() end

return flagdash
