-- Codec: Adler-32, Base64 (RFC 4648) and CBOR (RFC 8949) in pure Lua 5.1.
-- These are the pure-Lua defaults behind the serializer/encoder adapters, and the checksum.
-- The CBOR decoder enforces depth, length and item limits WHILE decoding (imports are hostile input).
local lib = LibStub and LibStub("LibGranaryDB-1.0", true)
local M = lib and lib.__M
if not M then return end

local byte, char, sub, format, concat = string.byte, string.char, string.sub, string.format, table.concat
local floor, frexp, ldexp, huge = math.floor, math.frexp, math.ldexp, math.huge
local type, pairs, error, tostring = type, pairs, error, tostring

local C = {}
M.Codec = C

---------------------------------------------------------------------------
-- Adler-32
---------------------------------------------------------------------------
function C.adler32(s)
  local a, b = 1, 0
  local n = #s
  local i = 1
  while i <= n do
    local j = i + 1023
    if j > n then j = n end
    for k = i, j do
      a = a + byte(s, k)
      b = b + a
    end
    a = a % 65521
    b = b % 65521
    i = j + 1
  end
  return format("%08x", b * 65536 + a)
end

---------------------------------------------------------------------------
-- Base64 (standard alphabet, '=' padding)
---------------------------------------------------------------------------
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local enc, dec = {}, {}
for i = 1, 64 do
  enc[i - 1] = sub(B64, i, i)
  dec[byte(B64, i)] = i - 1
end

function C.base64Encode(s)
  local out, n = {}, #s
  local o = 0
  for i = 1, n - 2, 3 do
    local a, b, c = byte(s, i, i + 2)
    local v = a * 65536 + b * 256 + c
    o = o + 1
    out[o] = enc[floor(v / 262144)] .. enc[floor(v / 4096) % 64] .. enc[floor(v / 64) % 64] .. enc[v % 64]
  end
  local rem = n % 3
  if rem == 1 then
    local a = byte(s, n)
    local v = a * 65536
    out[o + 1] = enc[floor(v / 262144)] .. enc[floor(v / 4096) % 64] .. "=="
  elseif rem == 2 then
    local a, b = byte(s, n - 1, n)
    local v = a * 65536 + b * 256
    out[o + 1] = enc[floor(v / 262144)] .. enc[floor(v / 4096) % 64] .. enc[floor(v / 64) % 64] .. "="
  end
  return concat(out)
end

--- Strict decoder: whitespace is ignored, anything else outside the alphabet fails.
function C.base64Decode(s)
  if type(s) ~= "string" then return nil, "not a string" end
  s = s:gsub("%s", "")
  local n = #s
  if n % 4 ~= 0 then return nil, "bad base64 length" end
  local out, o = {}, 0
  for i = 1, n, 4 do
    local c1, c2, c3, c4 = byte(s, i, i + 3)
    local v1, v2 = dec[c1], dec[c2]
    if not v1 or not v2 then return nil, "bad base64 character" end
    local pad3, pad4 = c3 == 61, c4 == 61
    if (pad3 or pad4) and i + 3 ~= n then return nil, "base64 padding in the middle" end
    local v3 = pad3 and 0 or dec[c3]
    local v4 = pad4 and 0 or dec[c4]
    if not v3 or not v4 or (pad3 and not pad4) then return nil, "bad base64 character" end
    local v = v1 * 262144 + v2 * 4096 + v3 * 64 + v4
    local a, b, c = floor(v / 65536), floor(v / 256) % 256, v % 256
    o = o + 1
    if pad3 then out[o] = char(a)
    elseif pad4 then out[o] = char(a, b)
    else out[o] = char(a, b, c) end
  end
  return concat(out)
end

---------------------------------------------------------------------------
-- IEEE 754 helpers
---------------------------------------------------------------------------
local function packDouble(v)
  local sign = 0
  if v < 0 or (v == 0 and 1 / v < 0) then sign = 128; v = -v end
  if v ~= v then return char(127, 248, 0, 0, 0, 0, 0, 0) end
  if v == huge then return char(sign + 127, 240, 0, 0, 0, 0, 0, 0) end
  if v == 0 then return char(sign, 0, 0, 0, 0, 0, 0, 0) end
  local m, e = frexp(v) -- v = m * 2^e, 0.5 <= m < 1
  local ef = e + 1022
  local mant
  if ef <= 0 then
    mant = ldexp(v, 1074) -- subnormal
    ef = 0
  else
    mant = (m * 2 - 1) * 4503599627370496 -- 2^52
  end
  local hi = floor(mant / 281474976710656) -- top 4 bits of the 52-bit fraction
  local lo = mant - hi * 281474976710656   -- low 48 bits
  local b = {}
  for i = 6, 1, -1 do
    b[i] = lo % 256
    lo = floor(lo / 256)
  end
  return char(sign + floor(ef / 16), (ef % 16) * 16 + hi, b[1], b[2], b[3], b[4], b[5], b[6])
end

local function unpackDouble(s, i)
  local b1, b2, b3, b4, b5, b6, b7, b8 = byte(s, i, i + 7)
  local sign = b1 >= 128 and -1 or 1
  local ef = (b1 % 128) * 16 + floor(b2 / 16)
  local mant = ((((((b2 % 16) * 256 + b3) * 256 + b4) * 256 + b5) * 256 + b6) * 256 + b7) * 256 + b8
  if ef == 2047 then
    if mant == 0 then return sign * huge end
    return 0 / 0
  end
  if ef == 0 then return sign * ldexp(mant, -1074) end
  return sign * ldexp(mant + 4503599627370496, ef - 1075)
end

local function unpackSingle(s, i)
  local b1, b2, b3, b4 = byte(s, i, i + 3)
  local sign = b1 >= 128 and -1 or 1
  local ef = (b1 % 128) * 2 + floor(b2 / 128)
  local mant = ((b2 % 128) * 256 + b3) * 256 + b4
  if ef == 255 then
    if mant == 0 then return sign * huge end
    return 0 / 0
  end
  if ef == 0 then return sign * ldexp(mant, -149) end
  return sign * ldexp(mant + 8388608, ef - 150)
end

local function unpackHalf(s, i)
  local b1, b2 = byte(s, i, i + 1)
  local sign = b1 >= 128 and -1 or 1
  local ef = floor((b1 % 128) / 4)
  local mant = (b1 % 4) * 256 + b2
  if ef == 31 then
    if mant == 0 then return sign * huge end
    return 0 / 0
  end
  if ef == 0 then return sign * ldexp(mant, -24) end
  return sign * ldexp(mant + 1024, ef - 25)
end

C.packDouble, C.unpackDouble = packDouble, unpackDouble

---------------------------------------------------------------------------
-- CBOR encode (deterministic: map keys sorted, numbers before strings)
---------------------------------------------------------------------------
local function head(major, n)
  local mb = major * 32
  if n < 24 then return char(mb + n) end
  if n < 256 then return char(mb + 24, n) end
  if n < 65536 then return char(mb + 25, floor(n / 256), n % 256) end
  if n < 4294967296 then
    return char(mb + 26, floor(n / 16777216), floor(n / 65536) % 256, floor(n / 256) % 256, n % 256)
  end
  local hi = floor(n / 4294967296)
  local lo = n - hi * 4294967296
  return char(mb + 27, floor(hi / 16777216), floor(hi / 65536) % 256, floor(hi / 256) % 256, hi % 256,
    floor(lo / 16777216), floor(lo / 65536) % 256, floor(lo / 256) % 256, lo % 256)
end

local function keyLess(a, b)
  local ta, tb = type(a), type(b)
  if ta ~= tb then return ta < tb end
  return a < b
end

local encodeValue
encodeValue = function(v, out, depth)
  local t = type(v)
  if depth > 64 then error("cbor: nesting too deep (cycle?)") end
  if t == "nil" then
    out[#out + 1] = "\246"
  elseif t == "boolean" then
    out[#out + 1] = v and "\245" or "\244"
  elseif t == "number" then
    if v == floor(v) and v > -9007199254740992 and v < 9007199254740992 and not (v == 0 and 1 / v < 0) then
      if v >= 0 then out[#out + 1] = head(0, v) else out[#out + 1] = head(1, -1 - v) end
    else
      out[#out + 1] = "\251" .. packDouble(v)
    end
  elseif t == "string" then
    out[#out + 1] = head(3, #v)
    out[#out + 1] = v
  elseif t == "table" then
    local n = #v
    local count = 0
    for _ in pairs(v) do count = count + 1 end
    local isArr = count == n
    if isArr then
      for k in pairs(v) do
        if type(k) ~= "number" or k < 1 or k > n or k ~= floor(k) then isArr = false; break end
      end
    end
    if isArr then
      out[#out + 1] = head(4, n)
      for i = 1, n do encodeValue(v[i], out, depth + 1) end
    else
      local keys = {}
      for k in pairs(v) do
        local kt = type(k)
        if kt ~= "string" and kt ~= "number" then error("cbor: unsupported key type " .. kt) end
        keys[#keys + 1] = k
      end
      table.sort(keys, keyLess)
      out[#out + 1] = head(5, #keys)
      for i = 1, #keys do
        encodeValue(keys[i], out, depth + 1)
        encodeValue(v[keys[i]], out, depth + 1)
      end
    end
  else
    error("cbor: cannot encode a " .. t)
  end
end

function C.cborEncode(v)
  local out = {}
  encodeValue(v, out, 0)
  return concat(out)
end

---------------------------------------------------------------------------
-- CBOR decode with limits
---------------------------------------------------------------------------
-- limits: maxDepth (default 16), maxString (default 4 MB), maxItems (default 1e6 total containers' items)
local BREAK = {}

local function decodeError(msg) error({ cbor = msg }, 0) end

local function readUint(s, pos, info, n)
  if info < 24 then return info, pos end
  if info == 24 then
    if pos > n then decodeError("truncated") end
    return byte(s, pos), pos + 1
  elseif info == 25 then
    if pos + 1 > n then decodeError("truncated") end
    local a, b = byte(s, pos, pos + 1)
    return a * 256 + b, pos + 2
  elseif info == 26 then
    if pos + 3 > n then decodeError("truncated") end
    local a, b, c, d = byte(s, pos, pos + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d, pos + 4
  elseif info == 27 then
    if pos + 7 > n then decodeError("truncated") end
    local v = 0
    for k = pos, pos + 7 do v = v * 256 + byte(s, k) end
    return v, pos + 8
  end
  decodeError("bad additional info " .. info)
end

local decodeItem
decodeItem = function(s, pos, n, depth, st)
  if pos > n then decodeError("truncated") end
  if depth > st.maxDepth then decodeError("nesting deeper than " .. st.maxDepth) end
  local ib = byte(s, pos)
  pos = pos + 1
  local major, info = floor(ib / 32), ib % 32
  if major == 0 then
    local v
    v, pos = readUint(s, pos, info, n)
    return v, pos
  elseif major == 1 then
    local v
    v, pos = readUint(s, pos, info, n)
    return -1 - v, pos
  elseif major == 2 or major == 3 then
    if info == 31 then -- indefinite string: concatenation of definite chunks
      local parts = {}
      local total = 0
      while true do
        if pos > n then decodeError("truncated") end
        if byte(s, pos) == 255 then pos = pos + 1; break end
        local chunk
        chunk, pos = decodeItem(s, pos, n, depth + 1, st)
        if type(chunk) ~= "string" then decodeError("bad indefinite string chunk") end
        total = total + #chunk
        if total > st.maxString then decodeError("string longer than limit") end
        parts[#parts + 1] = chunk
      end
      return concat(parts), pos
    end
    local len
    len, pos = readUint(s, pos, info, n)
    if len > st.maxString then decodeError("string longer than limit") end
    if pos + len - 1 > n then decodeError("truncated") end
    return sub(s, pos, pos + len - 1), pos + len
  elseif major == 4 or major == 5 then
    local len
    local indefinite = info == 31
    if not indefinite then
      len, pos = readUint(s, pos, info, n)
      -- every item needs at least one byte: a declared length beyond the input is a lie
      if len * (major == 5 and 2 or 1) > n - pos + 1 then decodeError("container longer than input") end
    end
    local t = {}
    local i = 0
    while true do
      if indefinite then
        if pos > n then decodeError("truncated") end
        if byte(s, pos) == 255 then pos = pos + 1; break end
      elseif i >= len then
        break
      end
      i = i + 1
      st.items = st.items + 1
      if st.items > st.maxItems then decodeError("too many items") end
      if major == 4 then
        local v
        v, pos = decodeItem(s, pos, n, depth + 1, st)
        if v == BREAK then decodeError("unexpected break") end
        t[i] = v
      else
        local k, v
        k, pos = decodeItem(s, pos, n, depth + 1, st)
        local kt = type(k)
        if kt ~= "string" and kt ~= "number" then decodeError("unsupported map key type") end
        if k ~= k then decodeError("NaN map key") end
        v, pos = decodeItem(s, pos, n, depth + 1, st)
        if v == BREAK then decodeError("unexpected break") end
        if t[k] ~= nil then decodeError("duplicate map key") end
        t[k] = v
      end
    end
    return t, pos
  elseif major == 6 then
    local _
    _, pos = readUint(s, pos, info, n) -- tags are ignored; the tagged item is returned as-is
    return decodeItem(s, pos, n, depth + 1, st)
  else -- major 7
    if info == 20 then return false, pos end
    if info == 21 then return true, pos end
    if info == 22 or info == 23 then return nil, pos end
    if info == 25 then
      if pos + 1 > n then decodeError("truncated") end
      return unpackHalf(s, pos), pos + 2
    end
    if info == 26 then
      if pos + 3 > n then decodeError("truncated") end
      return unpackSingle(s, pos), pos + 4
    end
    if info == 27 then
      if pos + 7 > n then decodeError("truncated") end
      return unpackDouble(s, pos), pos + 8
    end
    if info == 31 then return BREAK, pos end
    if info < 20 then return info, pos end -- unassigned simple values: return the number
    if info == 24 then
      if pos > n then decodeError("truncated") end
      return byte(s, pos), pos + 1
    end
    decodeError("bad simple value")
  end
end

--- Decode one CBOR item. Returns value or nil, err. Trailing bytes are an error.
function C.cborDecode(s, limits)
  if type(s) ~= "string" then return nil, "not a string" end
  limits = limits or {}
  local st = {
    maxDepth = limits.maxDepth or 16,
    maxString = limits.maxString or 4194304,
    maxItems = limits.maxItems or 1000000,
    items = 0,
  }
  local ok, v, pos = pcall(decodeItem, s, 1, #s, 0, st)
  if not ok then
    if type(v) == "table" and v.cbor then return nil, "cbor: " .. v.cbor end
    return nil, "cbor: " .. tostring(v)
  end
  if v == BREAK then return nil, "cbor: unexpected break" end
  if pos ~= #s + 1 then return nil, "cbor: trailing bytes" end
  return v
end
