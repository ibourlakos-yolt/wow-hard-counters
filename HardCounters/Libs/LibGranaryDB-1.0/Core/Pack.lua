-- Pack: the packed chunk text format (SPEC §3.4), blob encoding for cold storage, cell merging,
-- and the LRU of unpacked chunks.
--   GDB1,<grainId>,<col>.<col>...;#<periodKey>;<tid>,<v>,<v>...;...;#<periodKey>;...
local lib = LibStub and LibStub("LibGranaryDB-1.0", true)
local M = lib and lib.__M
if not M then return end

local type, pairs, ipairs, tonumber, tostring = type, pairs, ipairs, tonumber, tostring
local format, concat, floor, sort, byte, gsub, sub = string.format, table.concat, math.floor, table.sort, string.byte, string.gsub, string.sub

local P = {}
M.Pack = P

--- Shortest text that reads back as exactly the same double. Integers go through "%.0f", never "%d": the game's
--- string.format raises "integer overflow attempting to store" for %d past 32 bits (r5; a 4.9e9 sum broke packing).
local function fmtNum(v)
  if v == floor(v) and v > -9007199254740992 and v < 9007199254740992 then
    if v == 0 then return "0" end               -- not "-0"
    return format("%.0f", v)
  end
  local s = format("%.15g", v)
  if tonumber(s) == v then return s end
  s = format("%.16g", v)
  if tonumber(s) == v then return s end
  return format("%.17g", v)
end

local function escape(s)
  return (gsub(s, "[%%,;#%c]", function(c) return format("%%%02X", byte(c)) end))
end

-- hex pair -> byte, both cases: gsub with a table is far cheaper than with a function
local HEXBYTE = {}
for i = 0, 255 do
  local c = string.char(i)
  HEXBYTE[format("%02X", i)] = c
  HEXBYTE[format("%02x", i)] = c
end

local function unescape(s)
  if s:find("%", 1, true) then s = gsub(s, "%%(%x%x)", HEXBYTE) end
  return s
end

P.escape, P.unescape = escape, unescape

--- Encode periods into chunk text. `periods` = array of buckets { k = key, [col] = { [tid] = v } }.
--- `cols` = canonical column list. Periods are sorted by key; tids ascending.
function P.encode(gid, cols, periods)
  local RANK = M.Registry.COLUMN_RANK
  local STR = M.Registry.STRING_COLUMNS
  local present = {}
  for _, c in ipairs(cols) do present[#present + 1] = c end
  sort(present, function(a, b) return RANK[a] < RANK[b] end)
  local out = { "GDB1," .. gid .. "," .. concat(present, ".") }
  local ps = {}
  for i = 1, #periods do ps[i] = periods[i] end
  sort(ps, function(a, b) return a.k < b.k end)
  local nc = #present
  for _, b in ipairs(ps) do
    -- union of tids in this period
    local tids, seen = {}, {}
    for ci = 1, nc do
      local col = b[present[ci]]
      if col then
        for tid in pairs(col) do
          if not seen[tid] then seen[tid] = true; tids[#tids + 1] = tid end
        end
      end
    end
    if #tids > 0 then
      sort(tids)
      out[#out + 1] = "#" .. fmtNum(b.k)
      for _, tid in ipairs(tids) do
        local row = { fmtNum(tid) }
        for ci = 1, nc do
          local c = present[ci]
          local col = b[c]
          local v = col and col[tid]
          if v == nil then row[ci + 1] = ""
          elseif STR[c] then row[ci + 1] = escape(tostring(v))
          else row[ci + 1] = fmtNum(v) end
        end
        out[#out + 1] = concat(row, ",")
      end
    end
  end
  return concat(out, ";")
end

--- Parser. Returns { g = gid, cols = {...}, periods = { bucket... } (ascending), byKey = {} }
--- or nil, err. opts: maxTid (reject tids above), allowedCols (set), maxPeriods, strict.
--- Structure (ascending keys/tids, field counts, column codes, finite numbers) is always checked;
--- strict = true (imports) also rejects any number spelling other than plain decimal.
local HUGE = math.huge
function P.parse(text, opts)
  if type(text) ~= "string" then return nil, "chunk is not a string" end
  opts = opts or {}
  local RANK = M.Registry.COLUMN_RANK
  local STR = M.Registry.STRING_COLUMNS
  local gidS, colS, bodyStart = text:match("^GDB1,(%d+),([%a%.]*)();?")
  if not gidS then return nil, "bad chunk header" end
  local gid = tonumber(gidS)
  if gid < 1 or gid > 9 then return nil, "bad grain id in chunk" end
  local cols = {}
  local lastRank = 0
  for c in colS:gmatch("[^%.]+") do
    local r = RANK[c]
    if not r then return nil, "unknown column '" .. c .. "' in chunk" end
    if r <= lastRank then return nil, "columns out of order in chunk" end
    if opts.allowedCols and not opts.allowedCols[c] then return nil, "column '" .. c .. "' not allowed by the definition" end
    lastRank = r
    cols[#cols + 1] = c
  end
  local nc = #cols
  if nc == 0 then return nil, "chunk has no columns" end
  local isStr = {}
  for ci = 1, nc do isStr[ci] = STR[cols[ci]] or false end
  local strict = opts.strict
  local res = { g = gid, cols = cols, periods = {}, byKey = {} }
  local periods, byKey = res.periods, res.byKey
  local np = 0
  local cur, curCols
  local lastKey, lastTid
  local maxTid = opts.maxTid
  local maxPeriods = opts.maxPeriods or 100000
  local cp, sinceCp = opts.cp, 0 -- sliced callers: check the budget every 32 rows so one chunk never holds a frame
  local body = sub(text, bodyStart)
  if body ~= "" and byte(body, 1) ~= 59 then return nil, "bad chunk header" end
  if body:find(";;", 1, true) or (#body > 0 and byte(body, -1) == 59) then return nil, "empty field in chunk" end
  for f in body:gmatch("[^;]+") do
    if byte(f, 1) == 35 then -- '#'
      local ks = sub(f, 2)
      local k = tonumber(ks)
      if not k or k ~= floor(k) or k < -1e9 or k > 1e9 or ks:find("[^%-%d]") then
        return nil, "bad period key in chunk"
      end
      if lastKey and k <= lastKey then return nil, "period keys not ascending in chunk" end
      lastKey, lastTid = k, nil
      cur = { k = k }
      curCols = {}
      for ci = 1, nc do
        local t = {}
        cur[cols[ci]] = t
        curCols[ci] = t
      end
      np = np + 1
      if np > maxPeriods then return nil, "too many periods in chunk" end
      periods[np] = cur
      byKey[k] = cur
    else
      if not cur then return nil, "row before the first period in chunk" end
      if cp then
        sinceCp = sinceCp + 1
        if sinceCp >= 32 then sinceCp = 0; cp() end
      end
      local fi = -1
      local tid
      for tok in (f .. ","):gmatch("([^,]*),") do
        fi = fi + 1
        if fi == 0 then
          tid = tonumber(tok)
          if not tid or tid ~= floor(tid) or tid < 1 or (strict and tok:find("[^%d]")) then return nil, "bad tuple id in chunk" end
          if maxTid and tid > maxTid then return nil, "tuple id out of range in chunk" end
          if lastTid and tid <= lastTid then return nil, "tuple ids not ascending in chunk" end
          lastTid = tid
        elseif fi > nc then
          return nil, "too many fields in chunk row"
        elseif tok ~= "" then
          if isStr[fi] then
            if #tok > 512 then return nil, "context string too long in chunk" end
            local col = curCols[fi]
            col[tid] = unescape(tok)
          else
            local v = tonumber(tok)
            if not v or v ~= v or v == HUGE or v == -HUGE or (strict and tok:find("[^%d%.eE%+%-]")) then
              return nil, "bad number in chunk"
            end
            local col = curCols[fi]
            col[tid] = v
          end
        end
      end
      if fi ~= nc then return nil, "wrong number of fields in chunk row" end
    end
  end
  return res
end
---------------------------------------------------------------------------
-- Blobs (cold storage): "D" .. base64(deflate(text)) or "T" .. text
---------------------------------------------------------------------------
function P.toBlob(db, text)
  local comp = db._ad.compressor
  if comp.name ~= "none" then
    local ok, z = pcall(comp.compress, text)
    if ok and type(z) == "string" then
      local ok2, e = pcall(db._ad.encoder.encode, z)
      if ok2 and type(e) == "string" then return "D" .. e end
    end
  end
  return "T" .. text
end

function P.fromBlob(db, blob)
  if type(blob) ~= "string" or #blob == 0 then return nil, "empty blob" end
  local tag = byte(blob, 1)
  if tag == 84 then return blob:sub(2) end -- 'T'
  if tag == 68 then -- 'D'
    local comp = db._ad.compressor
    if comp.name == "none" then return nil, "this client has no Deflate decompressor for packed data" end
    local ok, z = pcall(db._ad.encoder.decode, blob:sub(2))
    if not ok or type(z) ~= "string" then return nil, "packed data: bad base64" end
    local ok2, text = pcall(comp.decompress, z)
    if not ok2 or type(text) ~= "string" then return nil, "packed data: decompression failed" end
    return text
  end
  return nil, "unknown blob tag"
end

---------------------------------------------------------------------------
-- LRU of unpacked chunks (keyed by cache key; validated by blob identity)
---------------------------------------------------------------------------
function P.newLRU(size)
  return { size = size or 32, map = {}, order = {} }
end

function P.lruGet(lru, key, blob)
  local e = lru.map[key]
  if e and e.blob == blob then
    e.used = (lru.clock or 0) + 1
    lru.clock = e.used
    return e.value
  end
end

function P.lruPut(lru, key, blob, value)
  local e = lru.map[key]
  lru.clock = (lru.clock or 0) + 1
  if e then
    e.blob, e.value, e.used = blob, value, lru.clock
    return
  end
  lru.map[key] = { blob = blob, value = value, used = lru.clock }
  lru.n = (lru.n or 0) + 1
  if lru.n > lru.size then
    local oldestK, oldestU
    for k, v in pairs(lru.map) do
      if not oldestU or v.used < oldestU then oldestK, oldestU = k, v.used end
    end
    lru.map[oldestK] = nil
    lru.n = lru.n - 1
  end
end

function P.lruClear(lru)
  lru.map, lru.n = {}, 0
end

--- Unpack a blob with caching. Returns the parsed chunk, or nil, err.
function P.unpack(db, cacheKey, blob, opts)
  local hit = P.lruGet(db._lru, cacheKey, blob)
  if hit then return hit end
  local text, err = P.fromBlob(db, blob)
  if not text then return nil, err end
  local parsed, perr = P.parse(text, opts)
  if not parsed then return nil, perr end
  P.lruPut(db._lru, cacheKey, blob, parsed)
  return parsed
end

---------------------------------------------------------------------------
-- Cell merging
---------------------------------------------------------------------------
--- Merge one source cell (columns of `src` at `st`) into dst cell (columns of `dst` at `dt`).
--- mode "time": merge across periods/tuples (flows add; stocks never add levels).
--- mode "entity": merge across characters (stock last/twa become sums of per-entity values).
function P.mergeCell(dst, dt, src, st, mode)
  local s = src.s
  if s and s[st] ~= nil then local d = dst.s; d[dt] = (d[dt] or 0) + s[st] end
  local n = src.n
  if n and n[st] ~= nil then local d = dst.n; d[dt] = (d[dt] or 0) + n[st] end
  local lo = src.lo
  if lo and lo[st] ~= nil then
    local d, v = dst.lo, lo[st]
    if d[dt] == nil or v < d[dt] then
      d[dt] = v
      if dst.xlo then dst.xlo[dt] = src.xlo and src.xlo[st] or nil end
    end
  end
  local hi = src.hi
  if hi and hi[st] ~= nil then
    local d, v = dst.hi, hi[st]
    if d[dt] == nil or v > d[dt] then
      d[dt] = v
      if dst.xhi then dst.xhi[dt] = src.xhi and src.xhi[st] or nil end
    end
  end
  local f = src.f
  if f and f[st] ~= nil then
    local ft = src.ft[st] or 0
    if dst.f[dt] == nil or ft < (dst.ft[dt] or 0) then dst.f[dt] = f[st]; dst.ft[dt] = ft end
  end
  if mode == "entity" then
    local l = src.l
    if l and l[st] ~= nil then
      dst.l[dt] = (dst.l[dt] or 0) + l[st]
      local lt = src.lt[st] or 0
      if (dst.lt[dt] or -1) < lt then dst.lt[dt] = lt end
    end
    local ti = src.ti
    if ti and ti[st] ~= nil and (src.td[st] or 0) > 0 then
      -- sum of per-entity time-weighted averages, kept with a unit duration
      dst.ti[dt] = (dst.ti[dt] or 0) + ti[st] / src.td[st]
      dst.td[dt] = 1
    end
  else
    local l = src.l
    if l and l[st] ~= nil then
      local lt = src.lt[st] or 0
      if dst.l[dt] == nil or lt >= (dst.lt[dt] or -1) then dst.l[dt] = l[st]; dst.lt[dt] = lt end
    end
    local ti = src.ti
    if ti and ti[st] ~= nil then
      dst.ti[dt] = (dst.ti[dt] or 0) + ti[st]
      dst.td[dt] = (dst.td[dt] or 0) + (src.td[st] or 0)
    end
  end
end

--- Merge every cell of bucket `src` into bucket `dst` (same tuple ids).
function P.mergeBucket(dst, src, mode)
  for c, col in pairs(src) do
    if c ~= "k" and type(col) == "table" and dst[c] == nil then dst[c] = {} end
  end
  local seen = {}
  for c, col in pairs(src) do
    if c ~= "k" and type(col) == "table" then
      for tid in pairs(col) do
        if not seen[tid] then
          seen[tid] = true
          P.mergeCell(dst, tid, src, tid, mode)
        end
      end
    end
  end
end

--- A fresh accumulator with the given columns.
function P.newCells(cols)
  local b = {}
  for i = 1, #cols do b[cols[i]] = {} end
  return b
end
