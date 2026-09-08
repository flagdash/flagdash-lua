local json = require("dkjson")
local Replay = {}
Replay.__index = Replay

local sensitive = { "pass", "secret", "token", "authorization", "cookie", "session", "api_key", "api-key", "credit", "card", "cvv", "cvc", "otp", "ssn" }

local function sensitive_key(key)
  key = tostring(key):lower()
  for _, fragment in ipairs(sensitive) do if key:find(fragment, 1, true) then return true end end
  return false
end

local function sanitize(value, depth)
  depth = depth or 0
  if depth > 8 then return "[REDACTED]" end
  if type(value) == "string" then return value:sub(1, 2000) end
  if type(value) ~= "table" then
    if value == nil or type(value) == "boolean" or type(value) == "number" then return value end
    return "[REDACTED]"
  end
  local clean, count = {}, 0
  for key, item in pairs(value) do
    count = count + 1
    if count > 500 then break end
    clean[key] = sensitive_key(key) and "[REDACTED]" or sanitize(item, depth + 1)
  end
  return clean
end

-- Force a JSON object for the two map-typed fields.
--
-- dkjson renders an empty table as `[]`, and the server stores both as an Ecto
-- `:map`, which rejects a list outright -- so an empty metadata or attributes
-- silently failed the whole session with a 422. Only the top level is marked:
-- nested lists must keep dkjson's own array inference.
local function as_object(value)
  if type(value) ~= "table" then return value end
  return setmetatable(value, { __jsontype = "object" })
end

local function default_transport(method, url, headers, body, timeout)
  local http = url:match("^https://") and require("ssl.https") or require("socket.http")
  local ltn12 = require("ltn12")
  local chunks = {}
  headers = headers or {}
  headers["content-length"] = #body
  http.TIMEOUT = timeout
  local _, status = http.request({ method = method, url = url, headers = headers,
    source = ltn12.source.string(body), sink = ltn12.sink.table(chunks), protocol = "tlsv1_2" })
  return tonumber(status), table.concat(chunks)
end

function Replay.new(sdk_key, options)
  if not sdk_key or sdk_key == "" then error("sdk_key is required") end
  options = options or {}
  return setmetatable({ sdk_key = sdk_key, base_url = (options.base_url or "https://flagdash.io"):gsub("/$", ""),
    identity = options.identity, release = options.release, metadata = as_object(sanitize(options.metadata or {})),
    timeout = options.timeout or 5, transport = options.transport or default_transport,
    started_at = os.time(), sequence = 0, events = {} }, Replay)
end

function Replay:_api(path, payload)
  local status, body = self.transport("POST", self.base_url .. path,
    { authorization = "Bearer " .. self.sdk_key, ["content-type"] = "application/json" }, json.encode(payload), self.timeout)
  if status == 204 then return nil end
  if not status or status < 200 or status >= 300 then error("FlagDash replay HTTP " .. tostring(status)) end
  if body == "" then return {} end
  local decoded, _, err = json.decode(body, 1, nil); if err then error(err) end; return decoded
end

function Replay:start()
  local ok, result = pcall(self._api, self, "/api/v1/replay-sessions/start", {
    type = "trace", platform = "lua", sdk_name = "flagdash-lua", started_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    identity = self.identity, release = self.release, metadata = self.metadata })
  if not ok or not result then return false end
  self.id = result.id; return self.id ~= nil
end

function Replay:event(name, category, attributes)
  if not self.id or not name or name == "" or #self.events >= 1000 then return end
  self.events[#self.events + 1] = { name = tostring(name):sub(1, 100), category = (category or "action"):sub(1, 40),
    timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"), attributes = as_object(sanitize(attributes or {})) }
end
function Replay:breadcrumb(message, attributes) self:event(message, "breadcrumb", attributes) end
function Replay:capture_exception(error, attributes) self:event(type(error) == "table" and (error.name or "Error") or "Error", "exception", attributes) end
function Replay:context_headers() return self.id and { ["x-flagdash-replay-id"] = self.id } or {} end

function Replay:flush()
  while self.id and #self.events > 0 do
    local batch = {}; for _ = 1, math.min(100, #self.events) do batch[#batch + 1] = table.remove(self.events, 1) end
    local raw = json.encode(batch)
    local manifest = self:_api("/api/v1/replay-sessions/" .. self.id .. "/chunks/presign", {
      sequence = self.sequence, byte_size = #raw, event_count = #batch, content_encoding = "identity" })
    self.sequence = self.sequence + 1
    local status = self.transport("PUT", manifest.upload.url, manifest.upload.headers or {}, raw, self.timeout)
    if not status or status < 200 or status >= 300 then return false end
  end
  return true
end

function Replay:stop()
  if not self:flush() then return false end
  if self.id then self:_api("/api/v1/replay-sessions/" .. self.id .. "/complete", {
    ended_at = os.date("!%Y-%m-%dT%H:%M:%SZ"), duration_ms = math.max(0, os.time() - self.started_at) * 1000 }) end
  return true
end

return Replay
