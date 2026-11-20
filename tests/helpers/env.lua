-- A fake game for engine tests: manual clock and timers, frames that record events, and the real embedded
-- LibGranaryDB (pure adapters + this clock). Loads the engine files listed in the TOC (Core/ only; UI/ and the
-- third-party libraries are skipped, CallbackHandler excepted).
--
--   local env = require("env").new({ t = <epoch> })
--   env:boot()                      -- ADDON_LOADED + PLAYER_ENTERING_WORLD(initial login)
--   env.HC:Emit(...); env:advance(60); env:fire("PLAYER_LOGOUT")
--   local env2 = env:reload()       -- same SavedVariables, fresh engine (a /reload)
local F = require("files")

local E = {}
E.__index = E

-- The addon folder, relative to the directory busted runs in. The packs' tests (packs/<Pack>/tests) set
-- require("env").ROOT = "../../HardCounters" to boot the real engine under their pack.
E.ROOT = "HardCounters"

--- Plain-data copy, like SavedVariables after a save and load (no functions, no metatables, new identities).
local function svCopy(v)
  if type(v) ~= "table" then
    if type(v) == "function" then return nil end
    return v
  end
  local r = {}
  for k, x in pairs(v) do
    local c = svCopy(x)
    if c ~= nil then r[svCopy(k)] = c end
  end
  return r
end
E.svCopy = svCopy

local function engineFiles()
  local ROOT = E.ROOT
  local files = F.loadList(ROOT .. "/HardCounters.toc")
  local out = {}
  for _, path in ipairs(files) do
    local rel = path:sub(#ROOT + 2)
    if rel:match("^Libs/") then
      if rel:match("^Libs/LibStub/") or rel:match("^Libs/CallbackHandler") or rel:match("^Libs/LibGranaryDB%-1%.0/") then
        if not rel:match("Adapters/WoW%.lua$") and not rel:match("LibGranaryDB%-1%.0/LibStub/") then out[#out + 1] = path end
      end
    elseif rel:match("^Core/") or rel:match("^Locale/") then
      out[#out + 1] = path
    elseif rel:match("^Basics/") and E.BASICS then
      -- the Basics module (gold and XP per hour): engine specs leave it out (their counters and trackers are their
      -- own); basics_spec and packs' specs (Farmer) set Env.BASICS = true and stub the game first
      out[#out + 1] = path
    end
  end
  return out
end
E.engineFiles = engineFiles

local function newFrame(env)
  local fr = { events = {}, scripts = {}, shown = true }
  function fr:RegisterEvent(e) self.events[e] = true; env.frames[self] = true end
  function fr:UnregisterEvent(e) self.events[e] = nil end
  function fr:SetScript(k, fn) self.scripts[k] = fn; env.frames[self] = true end
  function fr:Show() self.shown = true end
  function fr:Hide() self.shown = false end
  function fr:IsShown() return self.shown end
  return fr
end

function E.new(opts)
  opts = opts or {}
  local env = setmetatable({
    t = opts.t or 1794657600, -- 2026-11-14 12:00:00 UTC
    frames = {},                         -- strong: the game never garbage-collects frames
    timers = {}, seq = 0,
    secret = setmetatable({}, { __mode = "k" }),
    afk = false, zone = 1429, guid = opts.guid or "Player-1-00000001",
    sv = opts.sv or {}, settings = opts.settings,
    errors = {},
  }, E)
  return env
end

--- A value the fake game treats as secret (a table, so it can't be confused with a number).
function E:secretValue()
  local v = setmetatable({}, { __tostring = function() return "<secret>" end })
  self.secret[v] = true
  return v
end

function E:installGlobals()
  local env = self
  _G.LibStub = nil
  _G.strmatch = string.match
  _G.securecallfunction = function(fn, ...) return fn(...) end
  _G.geterrorhandler = function() return function(err) env.errors[#env.errors + 1] = err end end
  _G.CreateFrame = function() return newFrame(env) end
  _G.GetServerTime = function() return env.t end
  _G.GetTime = function() return env.t end
  _G.debugprofilestop = function() return env.t * 1000 end
  _G.date = os.date
  _G.issecretvalue = function(v) return env.secret[v] == true end
  _G.C_Timer = {
    After = function(sec, fn) env:schedule(sec, fn) end,
    NewTicker = function(sec, fn, n) return env:ticker(sec, fn, n) end,
  }
  _G.HardCountersDB = env.sv.HardCountersDB
  env.hooks = {}
  _G.hooksecurefunc = function(name, fn)
    env.hooks[name] = env.hooks[name] or {}
    table.insert(env.hooks[name], fn)
  end
end

--- Call a hooked global function: runs every post-hook registered with hooksecurefunc.
function E:callHook(name, ...)
  for _, fn in ipairs(self.hooks[name] or {}) do fn(...) end
end

function E:schedule(sec, fn, ticker)
  self.seq = self.seq + 1
  local tm = { at = self.t + sec, fn = fn, seq = self.seq, ticker = ticker }
  self.timers[#self.timers + 1] = tm
  return tm
end

function E:ticker(sec, fn, n)
  local env = self
  local tk = { cancelled = false, left = n }
  function tk.Cancel(t) t.cancelled = true end
  local function run()
    if tk.cancelled then return end
    fn(tk)
    if tk.left then tk.left = tk.left - 1; if tk.left <= 0 then return end end
    if not tk.cancelled then env:schedule(sec, run, tk) end
  end
  env:schedule(sec, run, tk)
  return tk
end

--- Advance the clock by `sec`, running due timers in time order (timers may schedule more).
function E:advance(sec)
  local target = self.t + sec
  while true do
    local best, bi
    for i, tm in ipairs(self.timers) do
      if tm.at <= target and (not best or tm.at < best.at or (tm.at == best.at and tm.seq < best.seq)) then best, bi = tm, i end
    end
    if not best then break end
    table.remove(self.timers, bi)
    if best.at > self.t then self.t = best.at end
    best.fn()
  end
  self.t = target
end

function E:fire(event, ...)
  -- snapshot first: handlers create and register frames, and adding keys to a table during pairs() is undefined in
  -- Lua (it made the load smoke test flaky: a frame's ADDON_LOADED was sometimes skipped)
  local list, n = {}, 0
  for fr in pairs(self.frames) do
    if fr.events[event] then n = n + 1; list[n] = fr end
  end
  for i = 1, n do
    local fr = list[i]
    if fr.events[event] and fr.scripts.OnEvent then fr.scripts.OnEvent(fr, event, ...) end
  end
end

--- The ns.wow adapter for tests (replaces Core/WoW.lua after it loads).
function E:wow(ns)
  local env = self
  local W = ns.wow
  W.now = function() return env.t end
  W.time = function() return env.t end
  W.ms = function() return env.t * 1000 end
  W.date = os.date
  W.after = function(sec, fn) env:schedule(sec, fn) end
  W.newTicker = function(sec, fn, n) return env:ticker(sec, fn, n) end
  W.locale = function() return "enUS" end
  W.isSecret = function(v) return env.secret[v] == true end
  W.errorHandler = function() return function(err) env.errors[#env.errors + 1] = err end end
  W.playerGUID = function() return env.guid end
  W.entityInfo = function() return { name = "Tester", realm = "Test", class = "MAGE", faction = "Alliance" } end
  W.build = function() return "1.60.1", "70938", 16001 end
  W.region = function() return "EU" end
  W.isAFK = function() return env.afk end
  W.zone = function() return env.zone end
  W.mapName = function(id) return "Map " .. tostring(id) end
  W.instanceType = function() return "none" end
  W.inCombat = function() return false end
  W.addonList = function() return { "HardCounters", "Other" } end
  W.encodeReport = function(t)
    env.lastReportBody = t
    local raw = "cbor:" .. tostring(t.fmt)
    return "BASE64", raw
  end
  W.granaryAdapters = {
    clock = { now = function() return env.t end, preciseMs = function() return env.t * 1000 end },
    scheduler = { after = function(sec, fn) env:schedule(sec, fn) end },
    secret = { isSecret = function(v) return env.secret[v] == true end },
  }
end

--- Load the engine into a fresh namespace. Returns ns (also env.ns) and the public object (env.HC).
function E:load()
  self:installGlobals()
  local ns = {}
  self.ns = ns
  for _, path in ipairs(engineFiles()) do
    local chunk = assert(loadfile(path))
    if path:find("/Libs/", 1, true) then
      chunk()
    else
      chunk("HardCounters", ns)
      if path:match("Core/WoW%.lua$") then self:wow(ns) end
    end
  end
  ns.InitSettings = function()
    ns.settings = self.settings or ns.DefaultProfile()
  end
  ns.Print = function() end
  self.HC = ns.HC
  return ns
end

--- Since v2 (HC-19) a counter counts only while a tracker that is on lists it, and keeps history only if asked.
--- Specs written for always-on counters with every grain call this: one tracker, on, with Detailed history (the
--- grains and retention counters had by default before trackers). Call before or after ADDON_LOADED.
function E.trackAll(env, id, counters, history)
  local ns = env.ns
  ns.settings = ns.settings or env.settings or ns.DefaultProfile()
  env.settings = ns.settings
  ns.settings.trackers = ns.settings.trackers or {}
  ns.settings.trackers[id] = { on = true, history = history or "detailed", seen = true }
  local nsName = id:match("^([^:]+):")
  if nsName ~= "hc" and not ns.packs["Env_" .. nsName] then
    local taken = false
    for _, p in pairs(ns.packs) do if p.namespace == nsName then taken = true end end
    if not taken then env.HC:RegisterPack("Env_" .. nsName, { namespace = nsName }) end
  end
  env.HC:RegisterTracker(id, { title = "Test " .. id, counters = counters, default = "on" })
end

--- Load and log in: ADDON_LOADED, then PLAYER_ENTERING_WORLD. Unless opts.bare, a test tracker keeps
--- hc:time.active on with full history (E.trackAll), as it always was before trackers.
function E:boot(opts)
  opts = opts or {}
  self:load()
  if not opts.bare then E.trackAll(self, "env:time", { "hc:time.active" }) end
  self:fire("ADDON_LOADED", "HardCounters")
  self.sv.HardCountersDB = _G.HardCountersDB
  self:fire("PLAYER_ENTERING_WORLD", not opts.reload, opts.reload and true or false)
  return self
end

--- Simulate /reload (or a logout + login with opts.login): save, then boot a fresh engine on the same data.
function E:reload(opts)
  opts = opts or {}
  self:fire("PLAYER_LOGOUT")
  local sv = { HardCountersDB = svCopy(self.sv.HardCountersDB) }
  local env = E.new({ t = self.t + (opts.offline or 0), guid = opts.guid or self.guid, sv = sv, settings = svCopy(self.settings) })
  env.zone = self.zone
  env:boot({ reload = not opts.login })
  return env
end

return E
