package.path = "src/?.lua;" .. package.path
local flagdash = require("flagdash")
local calls = {}
local function transport(method, url, query, body)
  calls[#calls + 1] = { method = method, url = url, query = query, body = body }
  local path = url:match("https?://[^/]+(.*)")
  if path == "/api/v1/server/flags" then return { evaluated = { checkout = true } } end
  if path == "/api/v1/server/flags/checkout" then return { flag = { key = "checkout", evaluated_value = true, evaluation_path = "rule_match" } } end
  if path == "/api/v1/server/configs/theme" then return { config = { value = "violet" } } end
  if path == "/api/v1/server/ai-configs/agent.md" then return { ai_config = { content = "Be useful" } } end
  if path == "/api/v1/server/translations/en/common" then return { catalog = { messages = { welcome = "Hello {name}" } } } end
  if path == "/api/v1/server/experiments/test" then return { experiment = { variant_key = "b" } } end
  return { accepted = #(body and body.events or {}) }
end
local client = flagdash.new("sk_test", { base_url = "https://example.test", region = "eu", transport = transport })
assert(client:flag("checkout") == true)
assert(client:flag_detail("checkout", false, { user = { id = "alice" } }).reason == "rule_match")
assert(client:config("theme") == "violet")
assert(client:ai_config("agent.md").content == "Be useful")
assert(client:translation("common.welcome", "en", nil, { name = "Ada" }) == "Hello Ada")
assert(client:experiment("test", { user_id = "alice" }).variant_key == "b")
client:track_experiment_metric("test", "purchase", "alice")
assert(client:flush())

local replay_calls = {}
local function replay_transport(method, url, headers, body)
  replay_calls[#replay_calls + 1] = { method = method, url = url, headers = headers, body = body }
  local path = url:match("https?://[^/]+(.*)")
  if path == "/api/v1/replay-sessions/start" then return 201, '{"id":"rpl_lua"}' end
  if path == "/api/v1/replay-sessions/rpl_lua/chunks/presign" then return 200, '{"upload":{"url":"https://storage.test/chunk","headers":{}}}' end
  return 200, "{}"
end
local replay = flagdash.BackendReplay.new("sk_test", { base_url = "https://example.test", transport = replay_transport, metadata = { api_key = "hidden" } })
assert(replay:start())
replay:event("checkout_started", "action", { password = "hidden", items = 2 })
assert(replay:context_headers()["x-flagdash-replay-id"] == "rpl_lua")
assert(replay:stop())
local uploaded
for _, call in ipairs(replay_calls) do if call.url:match("storage%.test") then uploaded = call.body end end
assert(uploaded and uploaded:match("checkout_started"))
assert(not uploaded:match('"hidden"'))

-- An empty metadata/attributes must serialise as a JSON object, not `[]`.
-- The server stores both as an Ecto `:map`, which rejects a list outright, so
-- `[]` failed every session that did not happen to pass metadata -- and every
-- assertion above passes non-empty maps, which is exactly why this went unseen.
local empty_calls = {}
local function empty_transport(method, url, headers, body)
  empty_calls[#empty_calls + 1] = { url = url, body = body }
  local path = url:match("https?://[^/]+(.*)")
  if path == "/api/v1/replay-sessions/start" then return 201, '{"id":"rpl_empty"}' end
  if path == "/api/v1/replay-sessions/rpl_empty/chunks/presign" then return 200, '{"upload":{"url":"https://storage.test/chunk","headers":{}}}' end
  return 200, "{}"
end
local empty = flagdash.BackendReplay.new("sk_test", { base_url = "https://example.test", transport = empty_transport })
assert(empty:start())
empty:event("probe")
assert(empty:stop())
assert(empty_calls[1].body:match('"metadata":{}'), "empty metadata must encode as an object")
local empty_upload
for _, call in ipairs(empty_calls) do if call.url:match("storage%.test") then empty_upload = call.body end end
assert(empty_upload and empty_upload:match('"attributes":{}'), "empty attributes must encode as an object")

-- ...while a genuine nested list must stay a list.
local list_calls = {}
local function list_transport(method, url, headers, body)
  list_calls[#list_calls + 1] = { url = url, body = body }
  return 201, '{"id":"rpl_list"}'
end
local list = flagdash.BackendReplay.new("sk_test", { base_url = "https://example.test", transport = list_transport, metadata = { tags = { "a", "b" } } })
assert(list:start())
assert(list_calls[1].body:match('"tags":%["a","b"%]'), "a nested list must stay a list")

print("FlagDash Lua SDK tests passed")
