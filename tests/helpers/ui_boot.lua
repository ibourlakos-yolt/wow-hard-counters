-- Boot all three addons (Hard Counters with Ace3 and LibGranaryDB, Diagnostics, and the packs in packs/ when
-- present) under the permissive fake client, and log in. Used by the load smoke test and the window tests.
--
--   require("ui_boot").with(function(ctx) ... end, { settings = <HardCountersSettings SavedVariable>,
--     client = { templates = false },     -- client options: a client without Blizzard's panel templates
--     newCharacter = true, db = <HardCountersDB> })
--   ctx = { env, client, hc = <HC namespace>, diag, farm, HC = <public API>, farmer = <Farmer loaded?> }
-- The character has loaded Hard Counters before (it is in HardCountersDB.chars), so it starts with the Pocket board
-- as before HC-74; newCharacter = true logs in a character Hard Counters never saw (the Leveling board, the welcome).
local Env = require("env")
local Client = require("client")
local F = require("files")

local B = {}
B.FARMER = "packs/Farmer/HardCounters_Farmer/HardCounters_Farmer.toc"
B.STATS = "packs/CharacterStats/HardCounters_CharacterStats/HardCounters_CharacterStats.toc"

local function boot(opts)
  local env = Env.new()
  env.sv.HardCountersDB = opts.db
  if not opts.newCharacter then
    env.sv.HardCountersDB = env.sv.HardCountersDB or {}
    env.sv.HardCountersDB.chars = env.sv.HardCountersDB.chars or { [env.guid] = { name = "Main", realm = "Realm" } }
  end
  env:installGlobals()                      -- clock, timers, frames for events
  local client = Client.install(env, opts.client)
  local ctx = { env = env, client = client, hc = {}, diag = {}, farm = {}, stats = {} }
  local clientFrame = _G.CreateFrame
  _G.CreateFrame = function(kind, name, ...)
    local f = clientFrame(kind, name, ...)
    local reg = f.RegisterEvent
    f.RegisterEvent = function(self, e) reg(self, e); env.frames[self] = true; self.events = self._events end
    f.SetScript = function(self, k, fn) self._scripts[k] = fn; if k == "OnEvent" then self.scripts = { OnEvent = fn } end end
    return f
  end
  _G.HardCountersSettings = opts.settings
  local addons = {
    { "HardCounters/HardCounters.toc", "HardCounters", ctx.hc },
    { "HardCounters_Diagnostics/HardCounters_Diagnostics.toc", "HardCounters_Diagnostics", ctx.diag },
  }
  if F.exists(B.FARMER) then
    addons[#addons + 1] = { B.FARMER, "HardCounters_Farmer", ctx.farm }
    ctx.farmer = true
  end
  if F.exists(B.STATS) then
    addons[#addons + 1] = { B.STATS, "HardCounters_CharacterStats", ctx.stats }
    ctx.charstats = true
  end
  for _, a in ipairs(addons) do
    local files, missing = F.loadList(a[1])
    -- (busted's assert.* lives in spec files only, not in helper modules)
    if next(missing) then error(a[1] .. " lists missing files: " .. table.concat(missing, ", "), 0) end
    for _, path in ipairs(files) do
      local chunk = assert(loadfile(path))
      chunk(a[2], a[3])
    end
  end
  -- (0.4.0) the Options tab draws AceConfig's panel into an AceGUI container: the fake client can't draw AceGUI's
  -- widgets (their templates' named children are missing), so the call is recorded instead (ctx.aceOpens)
  local LS = rawget(_G, "LibStub")
  local ACD = LS and LS("AceConfigDialog-3.0", true)
  ctx.aceOpens = {}
  if ACD then
    ACD.Open = function(_, app, container) ctx.aceOpens[#ctx.aceOpens + 1] = { app = app, container = container } end
  end
  -- ADDON_LOADED for each, then the login
  for _, a in ipairs(addons) do env:fire("ADDON_LOADED", a[2]) end
  env:fire("PLAYER_LOGIN")
  env:fire("PLAYER_ENTERING_WORLD", true, false)
  if #env.errors > 0 then error("errors during login: " .. tostring(env.errors[1]), 0) end
  ctx.HC = ctx.hc.HC
  return ctx
end

--- Boot, run fn(ctx), always put the real globals back. Errors from either step are re-raised.
function B.with(fn, opts)
  local ctx
  local ok, err = pcall(function()
    ctx = boot(opts or {})
    fn(ctx)
  end)
  if ctx then ctx.client.restore() elseif getmetatable(_G) then setmetatable(_G, nil) end
  if not ok then error(err, 0) end
  return ctx
end

return B
