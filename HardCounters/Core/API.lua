-- API: small public helpers. The rest of the public API lives with its module (Registry, Runs, Views, ...).
-- Everything on `HardCounters` without a leading underscore is public and documented in docs/API.md.
local ADDON, ns = ...

local HC, U, W = ns.HC, ns.U, ns.wow

local FEATURES = {
  counters = true, sources = true, emit = true, views = true, runs = true, splits = true, pause = true,
  records = true, live = true, phases = true, displays = true, report = true,
  windows = true, slash = true,   -- HC:RegisterWindow, HC:RegisterSlash (UI/Windows.lua, UI/Slash.lua)
  liveTrackers = true,            -- RegisterTracker with counters = {} (readings only)
  boardPresets = true,            -- HC:RegisterBoardPreset (UI/BoardModel.lua)
  readingStates = true,           -- reading `applies` and `stale` (HC-28)
  livePassThrough = true,         -- reading `live`, HC:ReadingLive (CS-9: secrets handed straight to widgets)
  hist = false, autoRuns = false, journal = false,
}

--- Capability probe: HardCounters:Supports("runs").
function HC:Supports(feature)
  -- dimensions with caps up to 4096 (LibGranaryDB API_VERSION 2; only the newest embedded copy runs)
  if feature == "bigDimensions" then return (ns.GDB and ns.GDB.API_VERSION or 0) >= 2 end
  return FEATURES[feature] == true
end

--- true if v is a secret value (Midnight restrictions). Check BEFORE any arithmetic or comparison (PACKS §3 rule 1).
function HC:IsSecret(v)
  return W.isSecret(v)
end

--- true if none of the arguments is secret; counts a rejection otherwise. For guards in pack handlers:
---   if not HardCounters:Readable(amount) then return end
function HC:Readable(...)
  for i = 1, select("#", ...) do
    if W.isSecret((select(i, ...))) then
      ns.Count("secretsRejected")
      return false
    end
  end
  return true
end

--- A Lua pattern from one of the client's format strings (e.g. LOOT_ITEM_SELF): magic characters escaped,
--- %s -> (.-), %d -> (%d+), positional %1$s handled, anchored. Use it for every chat parser (no English literals).
function HC:ChatPattern(fmt)
  return U.patternFrom(fmt)
end

function HC:FormatDuration(seconds) return U.duration(seconds) end
function HC:FormatMoney(copper) return U.money(copper) end
function HC:FormatNumber(n, decimals) return U.number(n, decimals) end

--- The player's zone key as stored in every "zone" dimension, always a number (HC-25): a map ID outdoors, 100000 +
--- the instance ID inside an instance, 0 when unknown. Label it for display with HardCounters:ZoneName(key).
function HC:ZoneKey()
  return ns.currentZone or W.zone()
end

function HC:ZoneName(key)
  return W.mapName(key)
end

--- UTC epoch seconds (the timestamp format of everything Hard Counters stores).
function HC:Now()
  return W.now()
end
