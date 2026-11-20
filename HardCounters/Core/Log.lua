-- Log and health: tier-1 diagnostics, present in every build (DESIGN §8.1).
-- - Health counters: cheap integers (secrets rejected, errors caught, ...), per login and lifetime.
-- - A ring of the last 200 warnings and errors, kept in HardCountersDB.health so it survives /reload.
-- - info/debug lines are dropped unless HardCounters_Diagnostics has installed a sink (no formatting cost).
-- Lines carry an origin tag: "HC", "Pack:<name>" or "LibGranaryDB r<minor>". Never put names or chat text in them.
local ADDON, ns = ...

local format, select, type, tostring, pcall = string.format, select, type, tostring, pcall
local Ring = ns.Ring

local LEVELS = { error = 1, warn = 2, info = 3, debug = 4 }
ns.LEVELS = LEVELS
ns.WARN_CAP = 200

local health = { session = {}, saved = {} }   -- saved is swapped for HardCountersDB.health.c at ADDON_LOADED
ns.health = health
local warnRing = Ring.new(ns.WARN_CAP)
local sink                                     -- function(t, level, origin, msg)

function ns.Count(name, n)
  n = n or 1
  local s, v = health.session, health.saved
  s[name] = (s[name] or 0) + n
  v[name] = (v[name] or 0) + n
end

local function render(fmt, ...)
  if select("#", ...) == 0 then return tostring(fmt) end
  local ok, msg = pcall(format, fmt, ...)
  if ok then return msg end
  return tostring(fmt) .. " (bad log arguments)"
end

--- ns.Log(level, origin, fmt, ...): level is "error" | "warn" | "info" | "debug".
function ns.Log(level, origin, fmt, ...)
  local lv = LEVELS[level] or 3
  if lv > 2 and not sink then return end
  local msg = render(fmt, ...)
  local t = ns.wow.now()
  if lv <= 2 then
    Ring.push(warnRing, { t = t, level = level, origin = origin, msg = msg })
    ns.Count(level == "error" and "errors" or "warnings")
  end
  if sink then pcall(sink, t, level, origin, msg) end
end

--- Report a caught error: counted, logged, and handed to the game's error handler (BugSack) without breaking the caller.
function ns.Error(err, origin)
  ns.Count("errorsCaught")
  ns.Log("error", origin or "HC", "%s", tostring(err))
  local ok, handler = pcall(ns.wow.errorHandler)
  if ok and type(handler) == "function" then pcall(handler, err) end
end

--- Move the in-memory health state and warnings into the saved table (called once at ADDON_LOADED).
function ns.AdoptHealth(saved)
  saved.c = type(saved.c) == "table" and saved.c or {}
  for k, v in pairs(health.saved) do saved.c[k] = (saved.c[k] or 0) + v end
  health.saved = saved.c
  local early = Ring.list(warnRing)
  warnRing = Ring.adopt(saved.warn, ns.WARN_CAP)
  saved.warn = warnRing
  for i = 1, #early do Ring.push(warnRing, early[i]) end
end

--- Recent warnings and errors, oldest first (a new table).
function ns.RecentWarnings(max)
  return Ring.list(warnRing, max)
end

function ns.ClearWarnings()
  Ring.clear(warnRing)
end

--- Diagnostics installs a sink to receive every line (info/debug included). Private: not part of the public API.
function ns.SetLogSink(fn)
  sink = fn
end
