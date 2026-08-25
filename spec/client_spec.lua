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
print("FlagDash Lua SDK tests passed")
