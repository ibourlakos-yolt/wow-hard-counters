-- Phases: the content-phase registry behind LibGranaryDB's `phase` grain (DESIGN §5).
-- The current phase is the one with the latest start at or before now; it's re-checked hourly.
-- Phase ids are what storage keeps (db:SetPhase), labels are for display. Start times are UTC epoch seconds.
local ADDON, ns = ...

local HC, W, U = ns.HC, ns.wow, ns.U

local phases, order = {}, {}

local function utc(y, m, d, h)
  -- days from civil (proleptic Gregorian), no os.time: independent of the machine's timezone
  if m <= 2 then y = y - 1 end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp = (m + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return (era * 146097 + doe - 719468) * 86400 + (h or 0) * 3600
end
ns.utc = utc

--- Register a phase: id (≤ 40 characters, stored), label (shown), startTime (UTC epoch seconds).
function HC:RegisterPhase(id, label, startTime)
  if type(id) ~= "string" or id == "" or #id > 40 then error("HardCounters: RegisterPhase(id, ...): id must be 1-40 characters", 2) end
  if type(startTime) ~= "number" then error("HardCounters: RegisterPhase: startTime must be UTC epoch seconds", 2) end
  if not phases[id] then order[#order + 1] = id end
  phases[id] = { id = id, label = label or id, start = startTime }
  if ns.ready then ns.ApplyPhase() end
end

--- The phase in effect at time t (default now), or nil before the first one.
function ns.PhaseAt(t)
  local best
  for _, id in ipairs(order) do
    local p = phases[id]
    if p.start <= t and (not best or p.start > best.start) then best = p end
  end
  return best
end

function ns.ApplyPhase()
  local p = ns.PhaseAt(W.now())
  if p and p.id ~= ns.currentPhase then
    ns.currentPhase = p.id
    ns.db:SetPhase(p.id)
  end
end

--- All phases, oldest first (copies).
function HC:Phases()
  local out = {}
  for _, id in ipairs(order) do out[#out + 1] = U.copy(phases[id]) end
  table.sort(out, function(a, b) return a.start < b.start end)
  return out
end

function HC:CurrentPhase()
  local p = ns.PhaseAt(W.now())
  return p and U.copy(p) or nil
end

-- WoW Forever's known roadmap (research.md). Unlock hours are approximate: the EU weekly reset (Wed 04:00 UTC).
HC:RegisterPhase("forever-launch", "Launch (1.60.1)", utc(2026, 11, 4, 4))
HC:RegisterPhase("forever-dec9", "Barrow Deeps, Hyjal Summit, Onyxia's Lair", utc(2026, 12, 9, 4))

ns.OnReady(function()
  ns.ApplyPhase()
  ns.Every(3600, ns.ApplyPhase)
end)
