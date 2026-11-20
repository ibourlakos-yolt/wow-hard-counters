-- Query: planner, row queries, time series, derived measures, account merging, sliced execution
-- (SPEC §2.5). Reads open, pending and packed buckets; never raw events (there are none).
local lib = LibStub and LibStub("LibGranaryDB-1.0", true)
local M = lib and lib.__M
if not M then return end

local type, pairs, ipairs, tostring, tonumber = type, pairs, ipairs, tostring, tonumber
local format, concat, sort, floor = string.format, table.concat, table.sort, math.floor

local Q = {}
M.Query = Q

local U, Cal, P = M.U, M.Cal, M.Pack

Q.MEASURES = {
  sum = true, count = true, min = true, max = true, first = true, last = true, twa = true,
  avg = true, rate = true, rate_active = true, share = true, change = true,
}
local NEEDS = {
  sum = "sum", count = "count", min = "min", max = "max", first = "first", last = "last", twa = "twa",
}
local MAX_SPAN = 100000
local CP_EVERY = 32 -- sliced queries: check the frame budget every 32 merged tuples of a parsed period

---------------------------------------------------------------------------
-- Sources
---------------------------------------------------------------------------
local function snapshotKeys(t)
  local ks = {}
  for k in pairs(t) do ks[#ks + 1] = k end
  return ks
end

function Q.localSource(db, counterId)
  local rc = db._counters[counterId]
  if not rc then return nil end
  local src = {
    kind = "local", id = counterId, def = rc.def, labels = rc.saved.dm,
    tupleSet = rc.tupleSet, tupleMembers = rc.tupleMembers, ntup = rc.ntup, gen = rc.gen,
  }
  function src.entities()
    local ks = snapshotKeys(rc.saved.e)
    sort(ks)
    return ks
  end
  function src.current() return rc.scopeAccount and "@account" or db._entity end
  function src.curKey(gid)
    if gid == Cal.LIFETIME then return 0 end
    return db._keys[gid]
  end
  -- fn(period, frozen): `frozen` is true for parsed (immutable) periods, where fn may call cp() mid-period.
  -- Open and queued buckets are live tables that writes can change between frames, so fn must not yield
  -- while iterating those; visit checkpoints only between them.
  function src.visit(ekey, gid, from, to, fn, cp)
    local e = rc.saved.e[ekey]
    if not e then return end
    local b = e.o and e.o[gid]
    if b and b.k >= from and b.k <= to then fn(b, false) end
    local parked = e.park and e.park[gid]
    if parked then
      local pk, blob = M.Store.parseParked(parked)
      if pk and pk >= from and pk <= to then
        local parsed = P.unpack(db, counterId .. "|" .. ekey .. "|park" .. gid, blob, cp and { cp = cp } or nil)
        if parsed and parsed.periods[1] then fn(parsed.periods[1], true) end
      end
    end
    local q = e.q and e.q[gid]
    if q then
      for i = 1, #q do
        local qb = q[i]
        if qb.k >= from and qb.k <= to then fn(qb, false) end
      end
    end
    local cold = e.k and e.k[gid]
    if cold then
      local ckFrom, ckTo = Cal.chunkKey(gid, from), Cal.chunkKey(gid, to)
      for _, ck in ipairs(snapshotKeys(cold)) do
        if ck >= ckFrom and ck <= ckTo then
          local blob = cold[ck]
          if blob then
            local parsed, err = P.unpack(db, counterId .. "|" .. ekey .. "|" .. gid .. "|" .. ck, blob, cp and { cp = cp } or nil)
            if parsed then
              -- in-game run 2: merging a whole month chunk here without a checkpoint took 9-24 ms slices
              for _, p in ipairs(parsed.periods) do
                if p.k >= from and p.k <= to then
                  fn(p, true)
                  if cp then cp() end
                end
              end
            else
              U.warn(db, format("query skipped an unreadable chunk of '%s' (%s)", counterId, tostring(err)))
            end
            if cp then cp() end
          end
        end
      end
    end
  end
  function src.sibling(id) return Q.localSource(db, id) end
  return src
end

local function resolveSource(db, q)
  local ds = q.dataset or "local"
  if ds == "local" then
    local src = Q.localSource(db, q.counter)
    if not src then return nil, format("unknown counter '%s' (register it first)", tostring(q.counter)) end
    return src
  end
  return M.Exchange.source(db, ds, q.counter)
end

---------------------------------------------------------------------------
-- Validation (misuse) and planning
---------------------------------------------------------------------------
local QUERY_KEYS = {
  counter = true, measure = true, entity = true, grain = true, range = true, last = true, groupBy = true,
  filter = true, top = true, order = true, dataset = true, gaps = true, base = true,
}

--- Returns nil if the query is well-formed, else a misuse message.
function Q.check(q, series)
  if type(q) ~= "table" then return "query must be a table" end
  for k in pairs(q) do
    if not QUERY_KEYS[k] then return format("unknown query field '%s'", tostring(k)) end
  end
  if type(q.counter) ~= "string" then return "query needs 'counter' (a counter id string)" end
  if q.measure ~= nil and not Q.MEASURES[q.measure] then
    return format("unknown measure '%s' (use sum, count, min, max, first, last, twa, avg, rate, rate_active, share, change)", tostring(q.measure))
  end
  if q.grain ~= nil and not Cal.GRAIN_ID[q.grain] then return format("unknown grain '%s'", tostring(q.grain)) end
  local e = q.entity
  if e ~= nil and type(e) ~= "string" and type(e) ~= "table" then return "'entity' must be a key, \"account\" or an array of keys" end
  if q.range ~= nil then
    local r = q.range
    if type(r) ~= "table" or not U.isInteger(r.from) or not U.isInteger(r.to) or r.from > r.to then
      return "'range' must be { from = key, to = key } with integer period keys, from <= to"
    end
    if r.to - r.from > MAX_SPAN then return "'range' spans too many periods" end
  end
  if q.last ~= nil and (not U.isInteger(q.last) or q.last < 1 or q.last > MAX_SPAN) then return "'last' must be a positive integer" end
  if q.range ~= nil and q.last ~= nil then return "use either 'range' or 'last', not both" end
  if q.groupBy ~= nil then
    if series then return "Series takes no 'groupBy'; use 'filter' to pick one breakdown" end
    local g = q.groupBy
    if type(g) == "string" then g = { g } end
    if type(g) ~= "table" or not U.isArray(g) or #g == 0 then return "'groupBy' must be a dimension name or an array of names" end
    for _, name in ipairs(g) do if type(name) ~= "string" then return "'groupBy' entries must be dimension names" end end
  end
  if q.filter ~= nil and type(q.filter) ~= "table" then return "'filter' must be a table { dim = value }" end
  if q.top ~= nil and (not U.isInteger(q.top) or q.top < 1) then return "'top' must be a positive integer" end
  if q.order ~= nil and q.order ~= "desc" and q.order ~= "asc" and q.order ~= "label" then return "'order' must be \"desc\", \"asc\" or \"label\"" end
  if q.dataset ~= nil and type(q.dataset) ~= "string" then return "'dataset' must be \"local\" or an import id" end
  if q.gaps ~= nil and q.gaps ~= "zero" and q.gaps ~= "carry" and q.gaps ~= "nil" then return "'gaps' must be \"zero\", \"carry\" or \"nil\"" end
  if q.base ~= nil and not NEEDS[q.base] then return "'base' must be a stored measure (sum, count, min, max, first, last, twa)" end
  return nil
end

local function setNames(nd, set)
  local names = {}
  for k = 1, set.n do names[k] = nd.dims[set[k]].name end
  return "{" .. concat(names, ",") .. "}"
end

--- Choose the smallest declared set that contains all needed dimensions.
local function plan(src, q)
  local nd = src.def
  local need, needList = {}, {}
  local groupBy = q.groupBy
  if type(groupBy) == "string" then groupBy = { groupBy } end
  local gdims = {}
  for i, name in ipairs(groupBy or {}) do
    local di = nd.dimIndex[name]
    if not di then return nil, format("'%s' has no dimension '%s'", nd.id, name) end
    gdims[i] = di
    if not need[di] then need[di] = true; needList[#needList + 1] = name end
  end
  local fdims = {}
  for name, value in pairs(q.filter or {}) do
    local di = nd.dimIndex[name]
    if not di then return nil, format("'%s' has no dimension '%s' to filter on", nd.id, tostring(name)) end
    fdims[#fdims + 1] = { di = di, value = value }
    if not need[di] then need[di] = true; needList[#needList + 1] = name end
  end
  local best
  for si, set in ipairs(nd.sets) do
    local ok = true
    for di in pairs(need) do
      local found = false
      for k = 1, set.n do if set[k] == di then found = true end end
      if not found then ok = false; break end
    end
    if ok and (not best or set.n < nd.sets[best].n) then best = si end
  end
  if not best then
    local declared = {}
    for i, set in ipairs(nd.sets) do declared[i] = setNames(nd, set) end
    sort(needList)
    return nil, format("can't break '%s' down by {%s}: no aggregation set contains %s. Declared sets: %s. "
      .. "Add { \"%s\" } to 'aggregations' (it only applies to data written from then on).",
      nd.id, concat(needList, ","), #needList > 1 and "all of them" or "it", concat(declared, ", "), concat(needList, "\", \""))
  end
  local set = nd.sets[best]
  local pos = {}
  for k = 1, set.n do pos[set[k]] = k end
  -- filter member ids
  local fpos = {}
  for i, f in ipairs(fdims) do
    local labels = src.labels[f.di] or {}
    local id
    if f.value == "other" then id = 0
    elseif f.value == "none" or f.value == false then id = -1
    else
      for mid, l in ipairs(labels) do if l == f.value then id = mid; break end end
    end
    fpos[i] = { k = pos[f.di], id = id }
  end
  local gpos = {}
  for i, di in ipairs(gdims) do gpos[i] = { k = pos[di], di = di } end
  return { si = best, set = set, fpos = fpos, gpos = gpos }
end

local function memberLabel(src, di, id)
  if id == 0 then return "other" end
  if id == -1 then return "none" end
  local l = src.labels[di] and src.labels[di][id]
  if l == nil then return "#" .. tostring(id) end
  return l
end

---------------------------------------------------------------------------
-- Accumulation
---------------------------------------------------------------------------
local function memberMode(nd) return nd.kind == "stock" and "entity" or "time" end

--- Returns groupOf(tid) -> group key or false, and gids: { [group key] = { member id per groupBy dim } }.
local function tupleGroupFn(src, pl)
  local cache, gids = {}, {}
  local ng = #pl.gpos
  return function(tid)
    local g = cache[tid]
    if g ~= nil then return g end
    g = false
    if src.tupleSet[tid] == pl.si then
      local parts = src.tupleMembers[tid]
      local ok = true
      for _, f in ipairs(pl.fpos) do
        if f.id == nil or parts[f.k] ~= f.id then ok = false; break end
      end
      if ok then
        if ng == 0 then
          g = "*"
        elseif ng == 1 then
          local id = parts[pl.gpos[1].k]
          g = tostring(id)
          if not gids[g] then gids[g] = { id } end
        else
          local ks, ids = {}, {}
          for i, gp in ipairs(pl.gpos) do ids[i] = parts[gp.k]; ks[i] = tostring(ids[i]) end
          g = concat(ks, ",")
          if not gids[g] then gids[g] = ids end
        end
      end
    end
    cache[tid] = g
    return g
  end, gids
end

local function entityList(src, entity)
  if entity == nil then
    if src.kind == "local" then return { src.current() } end
    return src.entities()
  end
  if entity == "account" then return src.entities() end
  if type(entity) == "string" then return { entity } end
  return entity
end

--- Returns groups { [gkey] = cells } merged over entities, time and tuples, and the group member ids.
local function accumulate(src, pl, entities, gid, from, to, cp)
  local nd = src.def
  local cols = nd.cols
  local mm = memberMode(nd)
  local groupOf, gids = tupleGroupFn(src, pl)
  local final = {}
  local primary = cols[1]
  if mm == "time" then
    -- Flows: every merge (across periods, tuples and characters) is the same associative "time"
    -- merge, so accumulate straight into one cell per group. One table set per group, not three
    -- (QUEUE LG-12: by-item queries over ~1,000 members spent most of their time here).
    for _, ekey in ipairs(entities) do
      src.visit(ekey, gid, from, to, function(p, frozen)
        local col = p[primary]
        if not col then
          for _, c in ipairs(cols) do if p[c] then col = p[c]; break end end
        end
        if not col then return end
        local yieldable, since = frozen and cp, 0
        for tid in pairs(col) do
          local g = groupOf(tid)
          if g then
            local acc = final[g]
            if not acc then acc = P.newCells(cols); final[g] = acc end
            P.mergeCell(acc, 1, p, tid, "time")
          end
          if yieldable then
            since = since + 1
            if since >= CP_EVERY then since = 0; cp() end
          end
        end
      end, cp)
      if cp then cp() end
    end
    return final, gids
  end
  -- Stocks: levels merge across time per tuple first ("time": the latest wins), then across tuples
  -- and characters ("entity": levels add up). The two modes don't commute, so keep the stages.
  for _, ekey in ipairs(entities) do
    local tidAcc = {}
    src.visit(ekey, gid, from, to, function(p, frozen)
      local col = p[primary]
      if not col then
        for _, c in ipairs(cols) do if p[c] then col = p[c]; break end end
      end
      if not col then return end
      local yieldable, since = frozen and cp, 0
      for tid in pairs(col) do
        if groupOf(tid) then
          local acc = tidAcc[tid]
          if not acc then acc = P.newCells(cols); tidAcc[tid] = acc end
          P.mergeCell(acc, 1, p, tid, "time")
        end
        if yieldable then
          since = since + 1
          if since >= CP_EVERY then since = 0; cp() end
        end
      end
    end, cp)
    -- tidAcc and groups belong to this query alone, so yielding while iterating them is safe
    local groups = {}
    local since = 0
    for tid, acc in pairs(tidAcc) do
      local g = groupOf(tid)
      local ga = groups[g]
      if not ga then ga = P.newCells(cols); groups[g] = ga end
      P.mergeCell(ga, 1, acc, 1, mm)
      if cp then
        since = since + 1
        if since >= CP_EVERY then since = 0; cp() end
      end
    end
    for g, ga in pairs(groups) do
      local fa = final[g]
      if not fa then fa = P.newCells(cols); final[g] = fa end
      P.mergeCell(fa, 1, ga, 1, mm)
      if cp then
        since = since + 1
        if since >= CP_EVERY then since = 0; cp() end
      end
    end
    if cp then cp() end
  end
  return final, gids
end

local function valueOf(c, measure)
  if not c then return nil end
  if measure == "sum" then return c.s and c.s[1] end
  if measure == "count" then return c.n and c.n[1] end
  if measure == "min" then return c.lo and c.lo[1] end
  if measure == "max" then return c.hi and c.hi[1] end
  if measure == "first" then return c.f and c.f[1] end
  if measure == "last" then return c.l and c.l[1] end
  if measure == "twa" then
    local ti, td = c.ti and c.ti[1], c.td and c.td[1]
    if ti and td and td > 0 then return ti / td end
    return nil
  end
  if measure == "avg" then
    local s, n = c.s and c.s[1], c.n and c.n[1]
    if s and n and n > 0 then return s / n end
    return nil
  end
end

local function checkMeasure(nd, measure, base)
  local function has(m)
    if not nd.mset[m] then
      return format("'%s' doesn't keep the measure '%s' (declared: %s)", nd.id, m, concat(nd.measures, ", "))
    end
  end
  if nd.kind == "stock" and (measure == "sum" or measure == "count" or measure == "avg" or measure == "rate" or measure == "rate_active") then
    return format("'%s' is a stock: stocks can't be summed across time; use last, min, max or twa", nd.id)
  end
  if measure == "avg" then return has("sum") or has("count") end
  if measure == "rate" or measure == "rate_active" then return has("sum") end
  if measure == "share" or measure == "change" then return has(base) end
  return has(measure)
end

local function resolveRange(src, q, gid)
  if q.range then return q.range.from, q.range.to end
  local cur = src.curKey(gid)
  if cur == nil then return nil, nil end
  if q.last then return cur - q.last + 1, cur end
  return cur, cur
end

---------------------------------------------------------------------------
-- Row queries
---------------------------------------------------------------------------
function Q.run(db, q, cp)
  local src, err = resolveSource(db, q)
  if not src then return nil, err end
  local nd = src.def
  local measure = q.measure or (nd.kind == "stock" and "last" or "sum")
  local base = q.base or (nd.kind == "stock" and "last" or "sum")
  local gname = q.grain or (nd.gset[Cal.LIFETIME] and "lifetime" or Cal.GRAINS[nd.grains[1]])
  local gid = Cal.GRAIN_ID[gname]
  if not nd.gset[gid] then
    local names = {}
    for i, g in ipairs(nd.grains) do names[i] = Cal.GRAINS[g] end
    return nil, format("'%s' has no '%s' grain (declared: %s)", nd.id, gname, concat(names, ", "))
  end
  local merr = checkMeasure(nd, measure, base)
  if merr then return nil, merr end
  local pl, perr = plan(src, q)
  if not pl then return nil, perr end
  local from, to = resolveRange(src, q, gid)
  local entities = entityList(src, q.entity)
  -- cache for account queries on local data
  local cacheKey
  if q.entity == "account" and src.kind == "local" and not cp then
    cacheKey = Q.signature(q, from, to)
    local hit = db._qcache[cacheKey]
    local wallGen = db._counters["@wall"] and db._counters["@wall"].gen or 0
    if hit and hit.gen == src.gen and hit.wgen == wallGen then return hit.rows end
  end
  local rows = { measure = measure, grain = gname, from = from, to = to }
  if from == nil then rows.total = nil; return rows end
  local groups, gids = accumulate(src, pl, entities, gid, from, to, cp)
  local vm = measure
  if measure == "share" or measure == "change" then vm = base end
  if measure == "rate" or measure == "rate_active" then vm = "sum" end
  -- total over the whole selection
  local totalCells = P.newCells(nd.cols)
  local mm = memberMode(nd)
  local since = 0 -- groups is local to this query: yielding mid-iteration is safe
  for _, c in pairs(groups) do
    P.mergeCell(totalCells, 1, c, 1, mm)
    if cp then
      since = since + 1
      if since >= CP_EVERY then since = 0; cp() end
    end
  end
  local divisor
  if measure == "rate" or measure == "rate_active" then
    local wsrc = src.sibling(measure == "rate" and "@wall" or "@active")
    if wsrc and wsrc.def.gset[gid] then
      local wpl = plan(wsrc, {})
      local wg = accumulate(wsrc, wpl, entities, gid, from, to, cp)
      divisor = wg["*"] and valueOf(wg["*"], "sum")
    end
  end
  local prevGroups
  if measure == "change" then
    local len = to - from + 1
    prevGroups = accumulate(src, pl, entities, gid, from - len, from - 1, cp)
  end
  local function finish(c)
    local v = valueOf(c, vm)
    if divisor ~= nil or measure == "rate" or measure == "rate_active" then
      if v ~= nil and divisor and divisor > 0 then v = v / divisor else v = nil end
    end
    return v
  end
  rows.total = finish(totalCells)
  for g, c in pairs(groups) do
    if cp then
      since = since + 1
      if since >= CP_EVERY then since = 0; cp() end
    end
    local v = finish(c)
    if v ~= nil then
      local row = { key = g, value = v }
      if g == "*" then
        row.label = "total"
      else
        local ids = gids[g]
        if #ids == 1 then
          local di, id1 = pl.gpos[1].di, ids[1]
          row.label = tostring(memberLabel(src, di, id1))
          -- r4 (LG-16): the stored member, numbers as numbers; none for "other", "none" and unknown ids
          local stored = id1 > 0 and src.labels[di] and src.labels[di][id1]
          if stored ~= nil and stored ~= false then row.member = stored end
        else
          local parts = {}
          for i = 1, #ids do parts[i] = tostring(memberLabel(src, pl.gpos[i].di, ids[i])) end
          row.label = concat(parts, " / ")
        end
      end
      if vm == "min" and c.xlo and c.xlo[1] then row.ctx = M.Store.parseCtx({ def = nd }, "min", c.xlo[1]) end
      if vm == "max" and c.xhi and c.xhi[1] then row.ctx = M.Store.parseCtx({ def = nd }, "max", c.xhi[1]) end
      if measure == "share" then
        local tv = valueOf(totalCells, base)
        row.share = (tv and tv ~= 0) and v / tv or nil
        row.value = row.share
      end
      if measure == "change" then
        local pv = prevGroups[g] and valueOf(prevGroups[g], base)
        row.prev = pv
        row.delta = pv and v - pv or nil
        row.pct = (pv and pv ~= 0) and (v - pv) / math.abs(pv) or nil
      end
      rows[#rows + 1] = row
    end
  end
  if measure == "change" then
    local pt = P.newCells(nd.cols)
    for _, c in pairs(prevGroups) do P.mergeCell(pt, 1, c, 1, mm) end
    rows.prevTotal = valueOf(pt, base)
  end
  -- Ties are common (many items looted once), and the tie-break was the biggest cost of a
  -- 1,000-row query (QUEUE LG-12): tostring() on both sides, then Lua 5.1's locale-aware string
  -- compare. Now every row gets one numeric tie key, computed once: labels that are numbers (item
  -- IDs, map IDs) use their value, and text labels are ranked among themselves (as strings) after
  -- all numbers. Each comparison is then two number compares.
  local order = q.order or "desc"
  local sign = order == "asc" and -1 or 1
  local NEG = -math.huge
  local texts, maxNum = {}, nil
  for i = 1, #rows do
    local r = rows[i]
    local v = r.value
    r._sk = (v ~= nil and v == v) and sign * v or NEG
    local n = tonumber(r.label)
    if n and n == n and n ~= math.huge and n ~= NEG then
      r._t = n
      if not maxNum or n > maxNum then maxNum = n end
    else
      texts[#texts + 1] = r
    end
  end
  if #texts > 0 then
    sort(texts, function(a, b) return a.label < b.label end)
    local textBase = (maxNum or 0) + 1
    for i = 1, #texts do texts[i]._t = textBase + i end
  end
  -- Fast path: when every sort value is an integer below 2^31 and every tie key an integer in
  -- [0, 2^22) (the usual case: counts, copper, item and map IDs), fold both into one exact number
  -- and sort plain numbers, with no Lua comparator call per comparison (3x faster for 1,000 rows).
  local nrows, fast = #rows, true
  local keys, byKey = {}, {}
  for i = 1, nrows do
    local r = rows[i]
    local sk, t = order == "label" and 0 or r._sk, r._t
    if sk ~= floor(sk) or sk >= 2147483648 or sk <= -2147483648 or t ~= floor(t) or t < 0 or t >= 4194304 then
      fast = false
      break
    end
    local k = -sk * 4194304 + t
    if byKey[k] then fast = false; break end
    keys[i], byKey[k] = k, r
  end
  if fast then
    sort(keys)
    for i = 1, nrows do rows[i] = byKey[keys[i]] end
  elseif order == "label" then
    sort(rows, function(a, b) return a._t < b._t end)
  else
    sort(rows, function(a, b)
      local av, bv = a._sk, b._sk
      if av ~= bv then return av > bv end
      return a._t < b._t
    end)
  end
  for i = 1, nrows do rows[i]._sk = nil; rows[i]._t = nil end
  if q.top then
    for i = #rows, q.top + 1, -1 do rows[i] = nil end
  end
  if cacheKey then
    local wallGen = db._counters["@wall"] and db._counters["@wall"].gen or 0
    Q.cachePut(db, cacheKey, { gen = src.gen, wgen = wallGen, rows = rows })
  end
  return rows
end

function Q.signature(q, from, to)
  local parts = { q.counter, q.measure or "", tostring(q.entity), q.grain or "", tostring(from), tostring(to),
    q.dataset or "local", tostring(q.top), q.order or "", q.base or "" }
  local g = q.groupBy
  if type(g) == "table" then parts[#parts + 1] = concat(g, ",") else parts[#parts + 1] = tostring(g) end
  if q.filter then
    for _, k in ipairs(U.sortedKeys(q.filter)) do parts[#parts + 1] = k .. "=" .. tostring(q.filter[k]) end
  end
  return concat(parts, "|")
end

function Q.cachePut(db, key, entry)
  local c = db._qcache
  if not c[key] then
    db._qcacheN = (db._qcacheN or 0) + 1
    if db._qcacheN > 16 then
      db._qcache = {}
      db._qcacheN = 1
      c = db._qcache
    end
  end
  c[key] = entry
end

---------------------------------------------------------------------------
-- Time series
---------------------------------------------------------------------------
function Q.series(db, q, cp)
  local src, err = resolveSource(db, q)
  if not src then return nil, err end
  local nd = src.def
  local measure = q.measure or (nd.kind == "stock" and "last" or "sum")
  local gname = q.grain or "day"
  local gid = Cal.GRAIN_ID[gname]
  if not nd.gset[gid] then return nil, format("'%s' has no '%s' grain", nd.id, gname) end
  if measure == "share" or measure == "change" then return nil, "Series supports stored measures, avg, rate and rate_active" end
  local merr = checkMeasure(nd, measure, measure)
  if merr then return nil, merr end
  local pl, perr = plan(src, q)
  if not pl then return nil, perr end
  local from, to = resolveRange(src, q, gid)
  local res = { keys = {}, values = {}, measure = measure, grain = gname, from = from, to = to }
  if from == nil then return res end
  local entities = entityList(src, q.entity)
  local groupOf = tupleGroupFn(src, pl)
  local cols = nd.cols
  local mm = memberMode(nd)
  local perKey = {}
  for _, ekey in ipairs(entities) do
    local eAcc = {}
    src.visit(ekey, gid, from, to, function(p, frozen)
      local col
      for _, c in ipairs(cols) do if p[c] then col = p[c]; break end end
      if not col then return end
      local yieldable, since = frozen and cp, 0
      for tid in pairs(col) do
        if groupOf(tid) then
          local acc = eAcc[p.k]
          if not acc then acc = P.newCells(cols); eAcc[p.k] = acc end
          P.mergeCell(acc, 1, p, tid, mm)
        end
        if yieldable then
          since = since + 1
          if since >= CP_EVERY then since = 0; cp() end
        end
      end
    end, cp)
    for k, acc in pairs(eAcc) do
      local fa = perKey[k]
      if not fa then fa = P.newCells(cols); perKey[k] = fa end
      P.mergeCell(fa, 1, acc, 1, mm)
    end
  end
  local divisors
  if measure == "rate" or measure == "rate_active" then
    divisors = {}
    local wsrc = src.sibling(measure == "rate" and "@wall" or "@active")
    if wsrc and wsrc.def.gset[gid] then
      local wq = Q.series(db, { counter = wsrc.id or (measure == "rate" and "@wall" or "@active"), measure = "sum",
        grain = gname, range = { from = from, to = to }, entity = q.entity, dataset = q.dataset, gaps = "nil" }, cp)
      if wq then for i, k in ipairs(wq.keys) do divisors[k] = wq.values[i] end end
    end
  end
  local gaps = q.gaps or (nd.kind == "stock" and "carry" or "zero")
  local vm = (measure == "rate" or measure == "rate_active") and "sum" or measure
  local prev
  local n = 0
  for k = from, to do
    local c = perKey[k]
    local v = c and valueOf(c, vm)
    if divisors then
      local d = divisors[k]
      if v ~= nil and d and d > 0 then v = v / d else v = nil end
    end
    if v == nil then
      if gaps == "zero" and not divisors then v = 0 elseif gaps == "carry" then v = prev end
    else
      prev = v
    end
    n = n + 1
    res.keys[n] = k
    res.values[n] = v
    if c and (vm == "max" or vm == "min") then
      local x = vm == "max" and c.xhi or c.xlo
      if x and x[1] then
        res.ctx = res.ctx or {}
        res.ctx[n] = M.Store.parseCtx({ def = nd }, vm, x[1])
      end
    end
  end
  return res
end

---------------------------------------------------------------------------
-- Sliced execution
---------------------------------------------------------------------------
function Q.async(db, fn, q, cb)
  local clock, sliceMs = db._ad.clock, db._opts.sliceMs
  local sliceStart = 0
  local cancelled = false
  local function cp()
    if clock.preciseMs() - sliceStart > sliceMs then coroutine.yield() end
  end
  local co = coroutine.create(function() return fn(db, q, cp) end)
  local job = {}
  function job.Cancel() cancelled = true end
  local function step()
    if cancelled then return end
    sliceStart = clock.preciseMs()
    local ok, res, err = coroutine.resume(co)
    if not ok then
      local okcb, e2 = pcall(cb, nil, "query failed: " .. tostring(res))
      if not okcb then pcall(db._ad.errors.handle, e2) end
      return
    end
    if coroutine.status(co) == "dead" then
      local okcb, e2 = pcall(cb, res, err)
      if not okcb then pcall(db._ad.errors.handle, e2) end
    else
      db._ad.scheduler.after(0, step)
    end
  end
  db._ad.scheduler.after(0, step)
  return job
end
