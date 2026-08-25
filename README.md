# FlagDash Lua SDK

Feature flags, remote config, AI configs, translations and experiments for
Lua 5.1+ (including LuaJIT and OpenResty).

## Installation

```bash
luarocks install flagdash
```

Dependencies: `luasocket`, `luasec` and `dkjson`. A different HTTP stack can be
injected with the `transport` option, which is how this runs inside OpenResty
or under a test double.

## Quick start

```lua
local flagdash = require("flagdash")

local client = flagdash.new(os.getenv("FLAGDASH_SDK_KEY"))

if client:flag("checkout-v2", false, { user_id = "alice" }) then
  -- new checkout
end

client:close()
```

`flagdash.new` raises if the key is empty — an unset environment variable
should fail at start-up, not silently serve defaults forever.

## API key tiers

The key decides which project and environment you read, and what you may reach.
There is no `environment` option anywhere in this SDK — the key carries it.

| Key | Prefix | Reaches |
|---|---|---|
| Client | `pk_` | Flag values and configs. |
| Server | `sk_` | The above, plus targeting rules, translations and experiments. |

## Configuration

```lua
local client = flagdash.new(sdk_key, {
  base_url  = "https://flagdash.io",  -- self-hosted? point it here
  timeout   = 5,                      -- seconds per request
  cache_ttl = 60,                     -- seconds
  region    = "eu-west-1",            -- omit to auto-detect
  transport = my_transport,           -- optional HTTP override
})
```

Region is taken from `FLAGDASH_REGION`, `FLY_REGION`, `AWS_REGION`,
`VERCEL_REGION`, `GOOGLE_CLOUD_REGION`, `RAILWAY_REPLICA_REGION` or
`RENDER_REGION` when you leave it out, so region-scoped targeting works with no
wiring.

## Feature flags

```lua
-- One flag, with the fallback used whenever FlagDash cannot be reached.
local enabled = client:flag("checkout-v2", false, { user_id = "alice" })

-- Every flag for this context, in one request.
local flags = client:all_flags({ user_id = "alice", country = "GB" })

-- Why did it resolve that way?
local detail = client:flag_detail("checkout-v2", false, { user_id = "alice" })
-- detail.value, detail.reason, detail.variation_key
```

**Pass a `user_id`** whenever you want a stable answer. Percentage rollouts and
A/B variations hash it, so a context without one re-rolls on every call by
design.

Note that `flag` without a context is served from the cached `all_flags`
payload; with a context it asks for a fresh evaluation.

Any attribute in the context table can be targeted on:

```lua
client:flag("beta-banner", false, {
  user_id = "alice",
  country = "GB",
  plan    = "premium",
})
```

## Remote config

```lua
local limit = client:config("rate_limit", 100)
local all   = client:list_configs()
```

## AI configs

Prompts, agents, skills and rules, versioned per environment and editable
without a deploy.

```lua
local agent = client:ai_config("support-agent.md")
local files = client:list_ai_configs()
```

## Translations

```lua
local greeting = client:translation("checkout.greeting", "fr", "Hello", {
  name = "Alice",
})
```

The key is `namespace.message`. `{placeholders}` are filled from the variables
table, and the default (falling back to the key) is returned whenever the
catalogue, namespace or message is missing.

## Experiments

```lua
local assignment = client:experiment("checkout-redesign", { user_id = "alice" })

if assignment and assignment.variant == "treatment" then
  -- ...
end

client:track_experiment_metric("checkout-redesign", "purchase", "alice", {
  value = 42.50,
  properties = { currency = "GBP" },
})
```

`experiment` returns `nil` for a context with no identifier — an assignment
that cannot be stable is worse than none.

Metrics are buffered in memory and only sent by `flush`, which `close` calls:

```lua
client:flush()
client:close()
```

In a long-running worker (OpenResty, a game server) call `flush` periodically
so events do not sit in the buffer.

## Caching

Reads are cached in memory for `cache_ttl` seconds (60 by default), so a burst
of `flag` calls costs one request.

```lua
client:clear_cache()
```

The cache is per client table and holds no locks, so in OpenResty give each
worker its own client rather than sharing one across coroutines.

## Failure behaviour

Evaluation reads return the default you passed rather than raising — an outage
degrades to your fallback values instead of erroring inside a request handler.
`flagdash.new` is the one call that raises, and only for a missing key.

## Security

Keep a server key on the server. A client key never receives targeting rules,
so an untrusted client cannot see who else you are targeting.

## License

MIT
