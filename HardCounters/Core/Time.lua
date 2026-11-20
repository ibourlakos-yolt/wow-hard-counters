-- hc:time.active: active (not AFK, not on a loading screen) seconds by zone. A core counter: the denominator of
-- every "per hour" rate (DESIGN §5.1). Capture mode state-duration: an interval opens when the player becomes active
-- and closes on AFK, zone change, loading screen or the 60 s flush. Seconds accumulate in memory and are written at
-- most once a minute (plus zone changes and logout), so the counter costs ~60 writes an hour, not 3,600.
-- Also tracks the current zone key for every pack (HardCounters:ZoneKey()).
local ADDON, ns = ...

local HC, W = ns.HC, ns.wow

ns.TIME_ID = "hc:time.active"
local ID = ns.TIME_ID
local FLUSH_EVERY, MAX_INTERVAL = 60, 120

HC:RegisterCounter({
  id = ID, version = 1, kind = "flow", unit = "seconds", measures = { "sum" },
  dimensions = { { name = "zone", cap = 64 } }, aggregations = { {}, { "zone" } },
  title = "Active time", category = "Time", formatter = "duration", accuracy = "exact",
  capture = { mode = "state-duration", source = "AFK flag, loading screens, zone changes" },
  feasibility = { status = "unverified", note = "UnitIsAFK may return a secret value; then the player counts as active" },
  runBreakdowns = { "zone" },
})

local acc, accZone = 0, nil
local since           -- W.time() when the open interval began; nil when inactive
local afk = false

local function isActive()
  return ns.ready and not afk and not ns.loadingScreen
end

local function close()
  if not since then return end
  local d = W.time() - since
  since = nil
  if d <= 0 then return end
  if d > MAX_INTERVAL then ns.Count("timeIntervalsCapped"); d = MAX_INTERVAL end
  acc = acc + d
end

local function open()
  if not since and isActive() then since = W.time() end
end

--- Write accumulated seconds to storage (to the zone they were spent in), then reopen if still active.
local function flush()
  close()
  if acc > 0 then
    HC:Emit(ID, acc, accZone)
    acc = 0
  end
  accZone = ns.currentZone
  open()
end
ns.FlushTime = flush
ns.AddFlusher(flush)

--- Seconds not yet written (for live displays: run panel, Live tab). No writes.
local function pending()
  return acc + (since and (W.time() - since) or 0)
end
ns.PendingActive = pending

local function setAFK(v)
  if v == afk then return end
  flush()
  afk = v
  if afk then close() end
  if ns.db then ns.db:SetActive(not afk) end
  open()
end

local function readAFK()
  local v = W.isAFK()
  if v == nil then ns.Count("afkSecret"); v = false end
  setAFK(v)
end

local function updateZone()
  local z = W.zone()
  if z == ns.currentZone then return end
  flush()            -- seconds so far belong to the old zone
  ns.currentZone = z
  accZone = z
  ns.Fire("HC_ZONE_CHANGED", z)
end

ns.OnReady(function()
  local c = ns.counters[ID]
  if c then c.pending = pending end
  ns.currentZone = W.zone()
  accZone = ns.currentZone
  local v = W.isAFK()
  afk = v == true
  ns.db:SetActive(not afk)
  open()
  ns.Every(FLUSH_EVERY, flush)
end)

ns.On("PLAYER_FLAGS_CHANGED", function(_, unit) if unit == "player" and ns.ready then readAFK() end end)
for _, ev in ipairs({ "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED", "ZONE_CHANGED_INDOORS", "PLAYER_ENTERING_WORLD" }) do
  ns.On(ev, function() if ns.ready then updateZone() end end)
end
ns.On("LOADING_SCREEN_ENABLED", function() close() end)
ns.On("LOADING_SCREEN_DISABLED", function() open() end)

--- Is the player active right now (not AFK, not loading)?
function HC:IsActive()
  return isActive()
end
