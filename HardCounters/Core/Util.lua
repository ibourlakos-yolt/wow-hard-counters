-- Util: pure helpers (no game globals).
local ADDON, ns = ...

local U = {}
ns.U = U

local floor, format, abs = math.floor, string.format, math.abs
local type, pairs, next = type, pairs, next

function U.copy(t)
  if type(t) ~= "table" then return t end
  local r = {}
  for k, v in pairs(t) do r[k] = v end
  return r
end

--- Deep copy of plain data (no cycles, no metatables). Used to hand out run records without exposing saved tables.
function U.deepcopy(t)
  if type(t) ~= "table" then return t end
  local r = {}
  for k, v in pairs(t) do r[k] = U.deepcopy(v) end
  return r
end

function U.isEmpty(t) return next(t) == nil end

function U.wipe(t)
  for k in pairs(t) do t[k] = nil end
  return t
end

--- 3725 -> "1:02:05", 65 -> "1:05", nil -> "0:00"
function U.duration(sec)
  sec = floor((sec or 0) + 0.5)
  if sec < 0 then sec = 0 end
  local h = floor(sec / 3600)
  local m = floor((sec - h * 3600) / 60)
  local s = sec - h * 3600 - m * 60
  if h > 0 then return format("%d:%02d:%02d", h, m, s) end
  return format("%d:%02d", m, s)
end

--- 1234567 -> "1,234,567"; keeps a minus sign and up to `dec` decimals.
function U.number(n, dec)
  if type(n) ~= "number" then return "-" end
  local neg = n < 0
  n = abs(n)
  local s = dec and dec > 0 and format("%." .. dec .. "f", n) or format("%d", floor(n + 0.5))
  local int, frac = s:match("^(%d+)(%.?%d*)$")
  int = int:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
  return (neg and "-" or "") .. int .. frac
end

--- Copper as "12g 34s 56c" (plain text; displays may add coin icons). Drops leading zero units.
function U.money(copper)
  if type(copper) ~= "number" then return "-" end
  local neg = copper < 0
  copper = floor(abs(copper) + 0.5)
  local g = floor(copper / 10000)
  local s = floor((copper - g * 10000) / 100)
  local c = copper - g * 10000 - s * 100
  local out
  if g > 0 then out = format("%sg %ds %dc", U.number(g), s, c)
  elseif s > 0 then out = format("%ds %dc", s, c)
  else out = format("%dc", c) end
  return (neg and "-" or "") .. out
end

--- Rate per hour from an amount and active seconds; nil when there is too little time to say (under a minute).
function U.perHour(amount, seconds)
  if type(amount) ~= "number" or type(seconds) ~= "number" or seconds < 60 then return nil end
  return amount * 3600 / seconds
end

--- Pure Adler-32 as 8 hex digits (the checksum in !HCReport strings, same as LibGranaryDB's envelopes).
function U.adler32(s)
  local a, b = 1, 0
  local byte = string.byte
  for i = 1, #s do
    a = (a + byte(s, i)) % 65521
    b = (b + a) % 65521
  end
  return format("%08x", b * 65536 + a)
end

--- A Lua pattern from a client format string ("You receive loot: %s." -> "^You receive loot: (.-)%.$").
--- %s -> (.-), %d -> (%d+); positional forms (%1$s, %2$d) are accepted, but captures stay in text order.
function U.patternFrom(fmt)
  if type(fmt) ~= "string" then return nil end
  local p = fmt:gsub("%%%d*%$?([sd])", "\1%1")
  p = p:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
  p = p:gsub("\1s", "(.-)"):gsub("\1d", "(%%d+)")
  return "^" .. p .. "$"
end

--- The key of a query row: the member as stored (LibGranaryDB r4, LG-16: numbers stay numbers, so item and zone
--- keys match the keys packs emit), else the label ("other", "none", "total").
function U.member(row)
  if row.member ~= nil then return row.member end
  return row.label
end

--- Context values come back from LibGranaryDB as text; zone keys are numbers (HC-25). Fixes ctx in place.
function U.fixCtx(ctx)
  if type(ctx) == "table" and type(ctx.zone) == "string" then ctx.zone = tonumber(ctx.zone) or ctx.zone end
  return ctx
end

--- Validate a namespaced id "ns:name" (ns: letters, digits, _ and -; name: also dots).
function U.validId(id)
  return type(id) == "string" and #id <= 64 and id:match("^[%w_%-]+:[%w_%.%-]+$") ~= nil
end

function U.namespace(id)
  return type(id) == "string" and id:match("^([^:]+):") or nil
end
