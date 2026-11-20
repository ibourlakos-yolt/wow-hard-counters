-- Calendar: integer period keys for every grain (SPEC D3). Pure arithmetic on civil dates, so day
-- keys are immune to daylight saving and always carry the year.
local lib = LibStub and LibStub("LibGranaryDB-1.0", true)
local M = lib and lib.__M
if not M then return end

local floor = math.floor

local Cal = {}
M.Cal = Cal

Cal.GRAINS = { "hour", "day", "week", "resetweek", "month", "year", "version", "phase", "lifetime" }
Cal.GRAIN_ID = {}
for i, name in ipairs(Cal.GRAINS) do Cal.GRAIN_ID[name] = i end
Cal.HOUR, Cal.DAY, Cal.WEEK, Cal.RESETWEEK, Cal.MONTH, Cal.YEAR, Cal.VERSION, Cal.PHASE, Cal.LIFETIME =
  1, 2, 3, 4, 5, 6, 7, 8, 9
Cal.CALENDAR_GRAINS = { true, true, true, true, true, true, false, false, false }
Cal.WEEK_SECONDS = 604800

--- Days since 1970-01-01 for a proleptic Gregorian date (H. Hinnant's algorithm).
function Cal.daysFromCivil(y, m, d)
  if m <= 2 then y = y - 1 end
  local era = floor(y / 400)
  local yoe = y - era * 400
  local mp = (m + 9) % 12
  local doy = floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + floor(yoe / 4) - floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

--- Inverse of daysFromCivil: returns y, m, d.
function Cal.civilFromDays(z)
  z = z + 719468
  local era = floor(z / 146097)
  local doe = z - era * 146097
  local yoe = floor((doe - floor(doe / 1460) + floor(doe / 36524) - floor(doe / 146096)) / 365)
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + floor(yoe / 4) - floor(yoe / 100))
  local mp = floor((5 * doy + 2) / 153)
  local d = doy - floor((153 * mp + 2) / 5) + 1
  local m = mp < 10 and mp + 3 or mp - 9
  if m <= 2 then y = y + 1 end
  return y, m, d
end

function Cal.weekOfDay(day) return floor((day + 3) / 7) end

--- Compute the calendar-grain keys for epoch `t` into `out[1..6]`, and the validity window
--- [out.start, out.stop) during which those keys stay the same. `cfg` = { fields, utc, dsh, anchor }.
function Cal.compute(cfg, t, out)
  local fields, utc, dsh = cfg.fields, cfg.utc, cfg.dsh
  local y, mo, d, h, mi, s = fields(t, utc)
  local day0 = Cal.daysFromCivil(y, mo, d)
  out[1] = day0 * 24 + h -- hour key: the real local hour
  if dsh ~= 0 then
    y, mo, d = fields(t - dsh * 3600, utc)
  end
  local day = Cal.daysFromCivil(y, mo, d)
  out[2] = day
  out[3] = floor((day + 3) / 7)
  local rw = floor((t - cfg.anchor) / 604800)
  out[4] = rw
  out[5] = y * 12 + (mo - 1)
  out[6] = y
  local start = t - (mi or 0) * 60 - (s or 0)
  local stop = start + 3600
  local nextReset = cfg.anchor + (rw + 1) * 604800
  if nextReset < stop then stop = nextReset end
  local prevReset = cfg.anchor + rw * 604800
  if prevReset > start then start = prevReset end
  out.start, out.stop = start, stop
  return out
end

--- Chunk key for packed storage (SPEC §3.4).
function Cal.chunkKey(gid, key)
  if gid == 1 then return floor(key / 24) end
  if gid == 2 then
    local y, m = Cal.civilFromDays(key)
    return y * 12 + (m - 1)
  end
  if gid == 3 or gid == 4 then return floor(key / 52) end
  if gid == 5 then return floor(key / 12) end
  if gid == 6 then return floor(key / 10) end
  return key
end

--- Largest period key that a chunk can hold (for retention by chunk).
function Cal.chunkMaxKey(gid, ck)
  if gid == 1 then return ck * 24 + 23 end
  if gid == 2 then
    local y, m = floor(ck / 12), ck % 12 + 1
    local ny, nm = y, m + 1
    if nm > 12 then nm = 1; ny = y + 1 end
    return Cal.daysFromCivil(ny, nm, 1) - 1
  end
  if gid == 3 or gid == 4 then return ck * 52 + 51 end
  if gid == 5 then return ck * 12 + 11 end
  if gid == 6 then return ck * 10 + 9 end
  return ck
end

--- Human-readable info for a period key.
function Cal.info(gid, key, anchor)
  local r = { grain = Cal.GRAINS[gid], key = key }
  if gid == 1 then
    local day = floor(key / 24)
    r.y, r.m, r.d = Cal.civilFromDays(day)
    r.h = key - day * 24
  elseif gid == 2 then
    r.y, r.m, r.d = Cal.civilFromDays(key)
  elseif gid == 3 then
    r.y, r.m, r.d = Cal.civilFromDays(key * 7 - 3) -- the Monday that starts the ISO week
  elseif gid == 4 then
    r.start = (anchor or 0) + key * 604800
  elseif gid == 5 then
    r.y, r.m = floor(key / 12), key % 12 + 1
  elseif gid == 6 then
    r.y = key
  end
  return r
end
