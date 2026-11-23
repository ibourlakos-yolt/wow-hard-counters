-- DiagBridge: what HardCounters_Diagnostics (our companion addon) may see of the engine.
-- PRIVATE: HardCounters._diag is not part of the public API and changes without notice. Packs use the API.
local ADDON, ns = ...

local W = ns.wow
local D = {}
ns.HC._diag = D

D.SetLogSink = function(fn) ns.SetLogSink(fn) end
D.Log = function(level, origin, fmt, ...) ns.Log(level, origin, fmt, ...) end
D.RecentWarnings = function(max) return ns.RecentWarnings(max) end
D.Health = function() return ns.U.copy(ns.health.session), ns.U.copy(ns.health.saved) end
D.ShowCopyBox = function(title, text) ns.ShowCopyBox(title, text) end
D.BuildReport = function(opts) return ns.BuildReport(opts) end
D.SchedulerStats = function() return ns.SchedulerStats() end
D.Context = function()
  return { zone = W.zone(), instance = W.instanceType(), combat = W.inCombat(), loading = ns.loadingScreen }
end
D.Wow = W

--- Storage diagnostics (LibGranaryDB db:Stats()), or nil before ADDON_LOADED.
D.StorageStats = function()
  if not ns.db then return nil end
  return ns.db:Stats()
end

D.SelfTest = function()
  return ns.GDB:SelfTest()
end

--- Engine state for the Live tab: counters with their lifetime and today totals for this character.
D.LiveRows = function()
  local out = {}
  if not (ns.db and ns.counterOrder) then return out end
  for _, id in ipairs(ns.counterOrder) do
    local c = ns.counters[id]
    local measure = c.kind == "stock" and "last" or "sum"
    local okT, today = pcall(ns.db.Query, ns.db, { counter = id, grain = "day", measure = measure })
    local okL, life = pcall(ns.db.Query, ns.db, { counter = id, grain = "lifetime", measure = measure })
    out[#out + 1] = {
      id = id, kind = c.kind, unit = c.unit,
      today = okT and today and today.total or nil, lifetime = okL and life and life.total or nil,
      pending = c.pending and c.pending() or nil,
    }
  end
  return out
end

D.Run = function() return ns.HC:GetRun() end
D.RunSummary = function() return ns.RunSummary() end
D.Sources = function() return ns.SourceStats and ns.SourceStats() or {} end

-- (HC-70) the shared browser widget and a confirm popup, for the Diagnostics tab's probes browser (UI files load after
-- this one: looked up at the call)
D.NewBrowser = function(parent, spec) return ns.Browser and ns.Browser.New(parent, spec) or nil end
D.Confirm = function(text, fn)
  if ns.Boards and ns.Boards.Confirm then ns.Boards.Confirm(text, fn) else fn() end
end
