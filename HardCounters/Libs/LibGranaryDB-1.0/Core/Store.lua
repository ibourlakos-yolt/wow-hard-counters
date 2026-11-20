-- Store: attached roots, runtime indexes, interning, buckets and the hot write path (SPEC §2.3, §3).
-- Hot-path rules: no allocation in steady state, no callbacks except deferred ones, the secret guard
-- runs before any comparison or arithmetic on a caller-supplied value.
local lib = LibStub and LibStub("LibGranaryDB-1.0", true)
local M = lib and lib.__M
if not M then return end

local type, pairs, ipairs, tostring, next = type, pairs, ipairs, tostring, next
local concat, sub = table.concat, string.sub
local HUGE, NHUGE = math.huge, -math.huge

local S = {}
M.Store = S

local U, Cal, R = M.U, M.Cal, M.Registry
local misuse = U.misuse

---------------------------------------------------------------------------
-- Callbacks (deferred, throttled)
---------------------------------------------------------------------------
function S.fire(db, event, ...)
  local cb = db._cb
  if not cb then return end
  local ok, err = pcall(cb.Fire, event, ...)
  if not ok then pcall(db._ad.errors.handle, err) end
end

local function scheduleFlush(db)
  if db._flushScheduled then return end
  db._flushScheduled = true
  db._ad.scheduler.after(0, db._flushFn)
end

local EXTREME_THROTTLE, SECRET_THROTTLE = 10, 60

function S.flush(db)
  db._flushScheduled = false
  local now = db._now()
  -- bucket closings
  local q = db._closedQ
  if #q > 0 then
    db._closedQ = {}
    for i = 1, #q do
      local e = q[i]
      S.fire(db, "OnBucketClosed", e[1], e[2], e[3])
    end
  end
  -- extremes and secret rejections (throttled; the latest pending one is delivered later)
  local wait
  for _, rc in pairs(db._counters) do
    if rc.xPend then
      local left = EXTREME_THROTTLE - (now - (rc.xLast or NHUGE))
      if left <= 0 then
        rc.xPend = false
        rc.xLast = now
        local tid = rc.xTid
        local label = S.tupleLabel(rc, tid)
        S.fire(db, "OnNewExtreme", rc.id, rc.xMeasure, rc.xValue, S.parseCtx(rc, rc.xMeasure, rc.xCtx), rc.xPrev, label)
      elseif not wait or left < wait then
        wait = left
      end
    end
    if rc.sPend then
      local left = SECRET_THROTTLE - (now - (rc.sLast or NHUGE))
      if left <= 0 then
        rc.sPend = false
        rc.sLast = now
        S.fire(db, "OnSecretRejected", rc.id)
      elseif not wait or left < wait then
        wait = left
      end
    end
  end
  if wait and not db._flushScheduled then
    db._flushScheduled = true
    db._ad.scheduler.after(wait, db._flushFn)
  end
end

local function queueExtreme(db, rc, measure, v, prev, tid, ctxStr)
  rc.xPend, rc.xMeasure, rc.xValue, rc.xPrev, rc.xTid, rc.xCtx = true, measure, v, prev, tid, ctxStr
  scheduleFlush(db)
end

local function rejectSecret(db, rc)
  local s = db._stats
  s.rejectedSecrets = (s.rejectedSecrets or 0) + 1
  if not rc.sPend then
    rc.sPend = true
    scheduleFlush(db)
  end
  return false
end

---------------------------------------------------------------------------
-- Keys and rollover
---------------------------------------------------------------------------
function S.advanceKeys(db, t)
  local k, tmp = db._keys, db._tmpKeys
  Cal.compute(db._cfg, t, tmp)
  local changed = false
  for g = 1, 6 do
    local nk = tmp[g]
    if nk ~= k[g] then
      if k[g] ~= nil then db._bstart[g] = tmp.start end
      k[g] = nk
      changed = true
    end
  end
  db._cacheStart, db._cacheEnd = tmp.start, tmp.stop
  if changed then db._keyEpoch = db._keyEpoch + 1 end
  return changed
end

local function newBucket(rc, gid, key)
  local b = { k = key }
  local cols = rc.colsByGrain[gid]
  for i = 1, #cols do b[cols[i]] = {} end
  return b
end
S.newBucket = newBucket

function S.bucketEmpty(b)
  for c, col in pairs(b) do
    if c ~= "k" and type(col) == "table" and next(col) ~= nil then return false end
  end
  return true
end

--- Close a bucket: integrate the stock tail up to `boundary`, move it to the pending list.
function S.closeBucket(db, rc, e, gid, b, boundary)
  if b.ti and boundary then
    local ti, td, l, maxGap, ss = b.ti, b.td, b.l, rc.def.maxGap, db._sessionStart
    for tid, lt in pairs(b.lt) do
      if lt >= ss and boundary > lt then
        local dt = boundary - lt
        if maxGap and dt > maxGap then dt = maxGap end
        ti[tid] = (ti[tid] or 0) + l[tid] * dt
        td[tid] = (td[tid] or 0) + dt
      end
    end
  end
  if e.o[gid] == b then e.o[gid] = nil end
  if not S.bucketEmpty(b) then
    local q = e.q[gid]
    if not q then q = {}; e.q[gid] = q end
    q[#q + 1] = b
    U.stat(db, "bucketsClosed")
    local cq = db._closedQ
    cq[#cq + 1] = { rc.id, Cal.GRAINS[gid], b.k }
    scheduleFlush(db)
  end
end

local function rollover(db, rc, ce)
  local keys, grains, ob, e = db._keys, rc.grains, ce.ob, ce.e
  for gi = 1, rc.ng do
    local gid = grains[gi]
    local key = keys[gid]
    local b = ob[gi]
    if b == nil or b.k ~= key then
      if b ~= nil then S.closeBucket(db, rc, e, gid, b, db._bstart[gid]) end
      b = e.o[gid]
      if b == nil or b.k ~= key then
        b = newBucket(rc, gid, key)
        e.o[gid] = b
      end
      ob[gi] = b
      ce.bstart[gi] = db._bstart[gid]
    end
  end
  ce.keyEpoch = db._keyEpoch
end
S.rollover = rollover

---------------------------------------------------------------------------
-- Entities, members, tuples
---------------------------------------------------------------------------
--- Runtime entity for writing: binds the saved entity and unparks it if needed.
function S.entity(db, rc, key)
  local ce = rc.ents[key]
  if not ce then
    local saved = rc.saved
    local e = saved.e[key]
    if not e then
      e = { o = {}, q = {}, k = {} }
      saved.e[key] = e
    end
    e.o, e.q, e.k = e.o or {}, e.q or {}, e.k or {}
    ce = { key = key, e = e, ob = {}, bstart = {}, keyEpoch = 0, carryV = {}, carryT = {} }
    for gi, gid in ipairs(rc.grains) do ce.ob[gi] = e.o[gid] end
    rc.ents[key] = ce
  end
  if ce.e.park and not db._ro then S.unpark(db, rc, ce) end
  return ce
end

---------------------------------------------------------------------------
-- Parking (SPEC D17): a character that isn't playing keeps its open buckets as one packed string
-- per grain ("<key>|<blob>") instead of thousands of table entries. Unparked on its next write.
---------------------------------------------------------------------------
function S.parseParked(s)
  if type(s) ~= "string" then return nil end
  local key, blob = s:match("^(%-?%d+)|(.*)$")
  if not key then return nil end
  return tonumber(key), blob
end

function S.park(db, _rc, ce)
  local e = ce.e
  if next(e.o) == nil then return 0 end
  local park = e.park or {}
  local n = 0
  for gid, b in pairs(e.o) do
    if not S.bucketEmpty(b) then
      local cols = {}
      for c, col in pairs(b) do
        if c ~= "k" and type(col) == "table" then cols[#cols + 1] = c end
      end
      park[gid] = b.k .. "|" .. M.Pack.toBlob(db, M.Pack.encode(gid, cols, { b }))
      n = n + 1
    end
  end
  e.o = {}
  e.park = next(park) and park or nil
  ce.ob = {}
  ce.keyEpoch = 0
  return n
end

function S.unpark(db, rc, ce)
  local e = ce.e
  local park = e.park
  if not park then return end
  e.park = nil
  for gid, s in pairs(park) do
    local key, blob = S.parseParked(s)
    local text = key and M.Pack.fromBlob(db, blob)
    local parsed = text and M.Pack.parse(text)
    local b = parsed and parsed.periods[1]
    if b and b.k == key then
      for _, c in ipairs(rc.colsByGrain[gid] or {}) do b[c] = b[c] or {} end
      if e.o[gid] then M.Pack.mergeBucket(e.o[gid], b, "time") else e.o[gid] = b end
    elseif parsed == nil or b == nil then
      U.internal(db, "parked bucket of '" .. rc.id .. "' unreadable; kept aside", false)
      e.bad = e.bad or {}
      e.bad[#e.bad + 1] = s
    end
  end
  for gi, gid in ipairs(rc.grains) do ce.ob[gi] = e.o[gid] end
  ce.keyEpoch = 0
end

local function bindEntity(db, h)
  local rc = h.rc
  local key = rc.scopeAccount and "@account" or db._entity
  local ce = S.entity(db, rc, key)
  h.ce, h.ceEpoch = ce, db._entityEpoch
  return ce
end

local function internMember(db, rc, i, v, level)
  local tv = type(v)
  local label = v
  if tv == "string" then
    if #v > 64 then label = sub(v, 1, 64) end
  elseif tv == "number" then
    if v ~= v or v == HUGE or v == NHUGE then
      misuse(level, "'%s': dimension '%s' got a non-finite number", rc.id, rc.def.dims[i].name)
    end
  else
    misuse(level, "'%s': dimension '%s' must be a string or number, got %s", rc.id, rc.def.dims[i].name, tv)
  end
  local idx = rc.memIdx[i]
  local id = idx[label]
  if id == nil then
    local labels = rc.saved.dm[i]
    if #labels < rc.def.dims[i].cap then
      id = #labels + 1
      labels[id] = label
    else
      id = 0
      U.stat(db, "otherOverflow")
      local oc = rc.otherCache
      if oc[i] >= 256 then return 0 end -- don't grow the cache without bound
      oc[i] = oc[i] + 1
    end
    idx[label] = id
  end
  if label ~= v then idx[v] = id end
  return id
end

local function insertPath(set, parts, tid)
  local n = set.n
  if n == 0 then set.tid0 = tid; return end
  local node = set.root
  for k = 1, n - 1 do
    local nx = node[parts[k]]
    if nx == nil then nx = {}; node[parts[k]] = nx end
    node = nx
  end
  node[parts[n]] = tid
end

local function newTuple(rc, si, tkey, parts)
  local tid = rc.ntup + 1
  rc.ntup = tid
  rc.saved.tk[tid] = tkey
  rc.tupleSet[tid] = si
  rc.tupleByKey[tkey] = tid
  rc.tupleMembers[tid] = parts
  return tid
end

local function internTuple(db, rc, si)
  local set = rc.sets[si]
  local mids = rc.mids
  local parts = {}
  for k = 1, set.n do parts[k] = mids[set[k]] end
  local tkey = set.key .. ":" .. concat(parts, ",")
  local tid = rc.tupleByKey[tkey]
  if tid == nil then
    if rc.ntup >= R.MAX_TUPLES then
      U.stat(db, "otherOverflow")
      local op = {}
      for k = 1, set.n do op[k] = 0 end
      local okey = set.key .. ":" .. concat(op, ",")
      tid = rc.tupleByKey[okey] or newTuple(rc, si, okey, op)
      insertPath(set, op, tid)
      return tid -- the original member path is not cached (bounded memory)
    end
    tid = newTuple(rc, si, tkey, parts)
  end
  insertPath(set, parts, tid)
  return tid
end

--- Resolve member ids and tuple ids for a write into rc.mids / rc.tids. Returns false on misuse.
local function resolveTids(db, rc, level, d1, d2, d3, d4, d5, d6)
  local nd = rc.nd
  if nd > 0 then
    local mids, mi = rc.mids, rc.memIdx
    local id
    if d1 == nil or d1 == false then id = -1 else id = mi[1][d1] or internMember(db, rc, 1, d1, level + 1) end
    mids[1] = id
    if nd > 1 then
      if d2 == nil or d2 == false then id = -1 else id = mi[2][d2] or internMember(db, rc, 2, d2, level + 1) end
      mids[2] = id
      if nd > 2 then
        if d3 == nil or d3 == false then id = -1 else id = mi[3][d3] or internMember(db, rc, 3, d3, level + 1) end
        mids[3] = id
        if nd > 3 then
          if d4 == nil or d4 == false then id = -1 else id = mi[4][d4] or internMember(db, rc, 4, d4, level + 1) end
          mids[4] = id
          if nd > 4 then
            if d5 == nil or d5 == false then id = -1 else id = mi[5][d5] or internMember(db, rc, 5, d5, level + 1) end
            mids[5] = id
            if nd > 5 then
              if d6 == nil or d6 == false then id = -1 else id = mi[6][d6] or internMember(db, rc, 6, d6, level + 1) end
              mids[6] = id
            end
          end
        end
      end
    end
  end
  local sets, tids, mids = rc.sets, rc.tids, rc.mids
  for si = 1, rc.ns do
    local set = sets[si]
    local n = set.n
    local tid
    if n == 0 then
      tid = set.tid0
    else
      local node = set.root
      for k = 1, n do
        node = node[mids[set[k]]]
        if node == nil then break end
      end
      tid = node
    end
    if tid == nil then tid = internTuple(db, rc, si) end
    tids[si] = tid
  end
end

---------------------------------------------------------------------------
-- Context strings
---------------------------------------------------------------------------
local CTX_SEP = "\31"
local function ctxString(db, rc, measure, t, ctx)
  local fields = rc.def.context[measure]
  local parts = { tostring(t) }
  local isSecret = db._isSecret
  local dv = rc.dvals
  for i = 1, #fields do
    local name = fields[i]
    local v
    if ctx ~= nil then v = ctx[name] end
    if v == nil then
      local di = rc.def.dimIndex[name]
      if di then v = dv[di] end
    end
    if v == nil or isSecret(v) then v = "" end
    local tv = type(v)
    if tv ~= "string" and tv ~= "number" and tv ~= "boolean" then v = "" end
    v = tostring(v)
    if #v > 64 then v = sub(v, 1, 64) end
    parts[i + 1] = v:gsub(CTX_SEP, " ")
  end
  return concat(parts, CTX_SEP)
end

function S.parseCtx(rc, measure, s)
  if type(s) ~= "string" then return nil end
  local fields = rc.def.context and rc.def.context[measure]
  local r = {}
  local i = 0
  for part in (s .. CTX_SEP):gmatch("(.-)" .. CTX_SEP) do
    if i == 0 then r.t = tonumber(part)
    elseif fields and fields[i] then
      if part ~= "" then r[fields[i]] = part end
    end
    i = i + 1
  end
  return r
end

---------------------------------------------------------------------------
-- Applying a write to one bucket
---------------------------------------------------------------------------
local function applyBucket(db, rc, ce, b, gi, t, v, ctx, late)
  local tids, ns = rc.tids, rc.ns
  local s, n, lo, hi, f, l = b.s, b.n, b.lo, b.hi, b.f, b.l
  local isLife = gi == rc.lifeGi
  for si = 1, ns do
    local tid = tids[si]
    if s then s[tid] = (s[tid] or 0) + v end
    if n then n[tid] = (n[tid] or 0) + 1 end
    if lo then
      local o = lo[tid]
      if o == nil or v < o then
        lo[tid] = v
        local x = b.xlo
        local cs
        if x then cs = ctxString(db, rc, "min", t, ctx); x[tid] = cs end
        if isLife and o ~= nil then queueExtreme(db, rc, "min", v, o, tid, cs) end
      end
    end
    if hi then
      local o = hi[tid]
      if o == nil or v > o then
        hi[tid] = v
        local x = b.xhi
        local cs
        if x then cs = ctxString(db, rc, "max", t, ctx); x[tid] = cs end
        if isLife and o ~= nil then queueExtreme(db, rc, "max", v, o, tid, cs) end
      end
    end
    if f then
      local ft = b.ft
      local o = ft[tid]
      if o == nil or t < o then f[tid] = v; ft[tid] = t end
    end
    if l then
      local lt = b.lt
      local plt = lt[tid]
      local ti = b.ti
      if ti then
        local td = b.td
        if late then
          if ti[tid] == nil then ti[tid] = 0; td[tid] = 0 end
        else
          local dt, prev
          if plt ~= nil and plt >= db._sessionStart then
            dt, prev = t - plt, l[tid]
          else
            local ct = ce.carryT[tid]
            local bs = ce.bstart[gi]
            if ct ~= nil and bs ~= nil then
              dt, prev = t - (ct > bs and ct or bs), ce.carryV[tid]
            end
          end
          local acc, dur = ti[tid] or 0, td[tid] or 0
          if dt ~= nil and dt > 0 then
            local mg = rc.def.maxGap
            if mg and dt > mg then dt = mg end
            acc = acc + prev * dt
            dur = dur + dt
          end
          ti[tid], td[tid] = acc, dur
        end
      end
      if plt == nil or t >= plt then l[tid] = v; lt[tid] = t end
    end
  end
end

---------------------------------------------------------------------------
-- Late writes (before the current hour): slow path, may allocate
---------------------------------------------------------------------------
local function findBucket(e, gid, key)
  local b = e.o[gid]
  if b and b.k == key then return b end
  local q = e.q[gid]
  if q then
    for i = 1, #q do if q[i].k == key then return q[i] end end
  end
end

local function lateWrite(db, h, t, v, ctx, d1, d2, d3, d4, d5, d6)
  local rc = h.rc
  local ce = h.ce
  if h.ceEpoch ~= db._entityEpoch then ce = bindEntity(db, h) end
  local keys = db._lateKeys
  Cal.compute(db._cfg, t, keys)
  keys[7], keys[8], keys[9] = db._keys[7], db._keys[8], 0
  resolveTids(db, rc, 5, d1, d2, d3, d4, d5, d6)
  local wrote = false
  for gi = 1, rc.ng do
    local gid = rc.grains[gi]
    local b = findBucket(ce.e, gid, keys[gid])
    if b then
      applyBucket(db, rc, ce, b, gi, t, v, ctx, true)
      wrote = true
    else
      U.stat(db, "lateDropped")
    end
  end
  rc.gen = rc.gen + 1
  return wrote
end

---------------------------------------------------------------------------
-- The write path
---------------------------------------------------------------------------
--- Shared by Handle:Add/AddAt/AddCtx/Observe*. Misuse errors blame the caller of the Handle method.
function S.write(h, observe, t, v, ctx, d1, d2, d3, d4, d5, d6)
  local db = h.db
  if db._ro then
    local st = db._stats
    st.readOnlyDrops = (st.readOnlyDrops or 0) + 1
    return false
  end
  local rc = h.rc
  if observe ~= rc.isStock then
    if observe then misuse(3, "'%s' is a flow; use Add, not Observe", rc.id) end
    misuse(3, "'%s' is a stock; use Observe, not Add", rc.id)
  end
  local isSecret = db._isSecret
  if isSecret(v) then return rejectSecret(db, rc) end
  local nd = rc.nd
  if nd > 0 then
    if isSecret(d1) then return rejectSecret(db, rc) end
    if nd > 1 then
      if isSecret(d2) then return rejectSecret(db, rc) end
      if nd > 2 then
        if isSecret(d3) then return rejectSecret(db, rc) end
        if nd > 3 then
          if isSecret(d4) then return rejectSecret(db, rc) end
          if nd > 4 then
            if isSecret(d5) then return rejectSecret(db, rc) end
            if nd > 5 and isSecret(d6) then return rejectSecret(db, rc) end
          end
        end
      end
    end
  end
  if type(v) ~= "number" then misuse(3, "'%s': value must be a number, got %s", rc.id, type(v)) end
  if v ~= v or v == HUGE or v == NHUGE then
    local st = db._stats
    st.rejectedInvalid = (st.rejectedInvalid or 0) + 1
    return false
  end
  local explicit = t ~= nil
  if not explicit then
    t = db._now()
  else
    if isSecret(t) then return rejectSecret(db, rc) end
    if type(t) ~= "number" or t ~= t then misuse(3, "'%s': time must be epoch seconds", rc.id) end
  end
  if rc.hasCtx then
    local dv = rc.dvals
    dv[1], dv[2], dv[3], dv[4], dv[5], dv[6] = d1, d2, d3, d4, d5, d6
  end
  if t >= db._cacheEnd then
    S.advanceKeys(db, t)
  elseif t < db._cacheStart then
    if explicit then
      local ok = lateWrite(db, h, t, v, ctx, d1, d2, d3, d4, d5, d6)
      return ok
    end
    S.advanceKeys(db, t) -- the clock itself moved back (PC clock corrected): re-anchor, don't drop
  end
  local ce = h.ce
  if h.ceEpoch ~= db._entityEpoch then ce = bindEntity(db, h) end
  if ce.keyEpoch ~= db._keyEpoch then rollover(db, rc, ce) end
  resolveTids(db, rc, 4, d1, d2, d3, d4, d5, d6)
  local ob = ce.ob
  if rc.fast then
    -- inlined path for plain flows (sum/count/min/max, no context): one call fewer per grain
    local tids, ns, life = rc.tids, rc.ns, rc.lifeGi
    for gi = 1, rc.ng do
      local b = ob[gi]
      local s, n, lo, hi = b.s, b.n, b.lo, b.hi
      for si = 1, ns do
        local tid = tids[si]
        if s then s[tid] = (s[tid] or 0) + v end
        if n then n[tid] = (n[tid] or 0) + 1 end
        if hi then
          local o = hi[tid]
          if o == nil or v > o then
            hi[tid] = v
            if gi == life and o ~= nil then queueExtreme(db, rc, "max", v, o, tid, nil) end
          end
        end
        if lo then
          local o = lo[tid]
          if o == nil or v < o then
            lo[tid] = v
            if gi == life and o ~= nil then queueExtreme(db, rc, "min", v, o, tid, nil) end
          end
        end
      end
    end
  else
    for gi = 1, rc.ng do
      applyBucket(db, rc, ce, ob[gi], gi, t, v, ctx, false)
    end
  end
  if observe then
    local tids, cv, ct = rc.tids, ce.carryV, ce.carryT
    for si = 1, rc.ns do
      local tid = tids[si]
      cv[tid], ct[tid] = v, t
    end
  end
  rc.gen = rc.gen + 1
  return true
end

---------------------------------------------------------------------------
-- Runtime counters
---------------------------------------------------------------------------
function S.tupleLabel(rc, tid, labelsOverride)
  local si = rc.tupleSet[tid]
  local parts = rc.tupleMembers[tid]
  if not si or not parts then return nil end
  local set = rc.sets[si]
  if set.n == 0 then return "total" end
  local out = {}
  local dm = labelsOverride or rc.saved.dm
  for k = 1, set.n do
    local id = parts[k]
    if id == 0 then out[k] = "other"
    elseif id == -1 then out[k] = "none"
    else
      local labels = dm[set[k]]
      out[k] = labels and labels[id] ~= nil and tostring(labels[id]) or ("#" .. tostring(id))
    end
  end
  return concat(out, " / ")
end

--- Parse "1,2:5,7" into set key "1,2" and member ids {5,7}.
function S.parseTupleKey(tkey)
  if type(tkey) ~= "string" then return nil end
  local setKey, mem = tkey:match("^([%d,]*):([%-%d,]*)$")
  if not setKey then return nil end
  local parts = {}
  for m in mem:gmatch("[^,]+") do
    local id = tonumber(m)
    if not id then return nil end
    parts[#parts + 1] = id
  end
  return setKey, parts
end

--- Build (or rebuild) the runtime for a counter from its normalised def and saved table.
function S.buildRuntime(db, nd, saved, internal)
  local rc = {
    id = nd.id, def = nd, saved = saved, internal = internal or false,
    isStock = nd.kind == "stock", scopeAccount = nd.scope == "account",
    nd = #nd.dims, ns = #nd.sets, ng = #nd.grains, grains = nd.grains,
    sets = {}, memIdx = {}, otherCache = {}, mids = {}, tids = {}, dvals = {},
    tupleSet = {}, tupleByKey = {}, tupleMembers = {}, ntup = 0,
    ents = {}, gen = 0, lifeGi = 0, colsByGrain = {},
    hasCtx = next(nd.context) ~= nil,
  }
  rc.fast = not rc.isStock and not rc.hasCtx and not nd.cset.f and not nd.cset.l
  for gi, gid in ipairs(nd.grains) do
    if gid == Cal.LIFETIME then rc.lifeGi = gi end
    local cols = {}
    for _, c in ipairs(nd.cols) do
      if (c ~= "xlo" and c ~= "xhi") or nd.ctxGrains[gid] then cols[#cols + 1] = c end
    end
    rc.colsByGrain[gid] = cols
  end
  for si, s in ipairs(nd.sets) do
    local set = { key = s.key, n = s.n, root = {} }
    for k = 1, s.n do set[k] = s[k] end
    rc.sets[si] = set
  end
  for i = 1, rc.nd do
    rc.memIdx[i] = {}
    rc.otherCache[i] = 0
    local labels = saved.dm[i]
    if not labels then
      labels = {}
      if not db._ro then saved.dm[i] = labels end -- read-only never adds to saved data
    end
    for id, label in ipairs(labels) do rc.memIdx[i][label] = id end
    local retired = saved.dr and saved.dr[i]
    if retired then
      for id in pairs(retired) do
        local label = labels[id]
        if label ~= nil then rc.memIdx[i][label] = 0 end
      end
    end
  end
  local tk = saved.tk
  for tid = 1, #tk do
    local setKey, parts = S.parseTupleKey(tk[tid])
    if setKey then
      rc.tupleByKey[tk[tid]] = tid
      rc.tupleMembers[tid] = parts
      local si = nd.setByKey[setKey]
      if si then
        rc.tupleSet[tid] = si
        local set = rc.sets[si]
        local skip = false
        if set.n > 0 then
          -- retired members must not keep a direct path (writes for them go to `other`)
          for k = 1, set.n do
            local id = parts[k]
            if id > 0 and saved.dr and saved.dr[set[k]] and saved.dr[set[k]][id] then skip = true end
          end
        end
        if not skip then insertPath(set, parts, tid) end
      end
    else
      U.internal(db, "bad tuple key for '" .. nd.id .. "' at " .. tid, false)
    end
    rc.ntup = tid
  end
  -- existing entities are bound lazily (S.entity)
  return rc
end

--- Register (or re-register) a counter. Returns rc, or nil and a misuse message.
function S.register(db, def, internal)
  local nd, err = R.validate(def, internal)
  if not nd then return nil, err end
  local G = db._G
  local saved = G.c[nd.id]
  if saved and type(saved.def) == "table" and type(saved.def.d) == "table" then
    local old = R.validate(saved.def.d, internal)
    if not old then
      U.internal(db, "stored definition for '" .. nd.id .. "' is unreadable; keeping its data untouched", true)
      return nil, "stored definition for '" .. nd.id .. "' is corrupt (database is now read-only)"
    end
    local cmp, why = R.compare(old, nd)
    if cmp == "incompatible" then
      if nd.version > (saved.def.v or 0) and nd.onIncompatible == "reset" then
        U.warn(db, "counter '" .. nd.id .. "' reset after an incompatible change: " .. why)
        G.c[nd.id] = nil
        saved = nil
        S.fire(db, "OnMigration", "counter:" .. nd.id, nd.version, { reset = true, reason = why })
      else
        return nil, string.format("'%s' changed incompatibly (%s); bump 'version' and set onIncompatible = \"reset\" "
          .. "to start it over (its old data is then dropped)", nd.id, why)
      end
    end
  end
  if not saved then
    saved = { def = {}, dm = {}, tk = {}, e = {} }
    G.c[nd.id] = saved
  end
  saved.def = { v = nd.version, h = nd.fingerprint, d = R.canonical(nd) }
  saved.dm, saved.tk, saved.e = saved.dm or {}, saved.tk or {}, saved.e or {}
  local rc = S.buildRuntime(db, nd, saved, internal)
  db._counters[nd.id] = rc
  local h = db._handles[nd.id]
  if h then h.rc, h.ce, h.ceEpoch = rc, nil, -1 end
  return rc
end

---------------------------------------------------------------------------
-- Host state: entity, phase, active, tick
---------------------------------------------------------------------------
local function clip(s, n)
  if type(s) ~= "string" then return nil end
  if #s > n then return sub(s, 1, n) end
  return s
end

function S.setEntity(db, key, info)
  db._entity = key
  db._entityEpoch = db._entityEpoch + 1
  local ents = db._G.ents
  local rec = ents[key]
  if type(rec) ~= "table" then rec = {}; ents[key] = rec end
  if type(info) == "table" then
    rec.n = clip(info.name, 48) or rec.n
    rec.r = clip(info.realm, 48) or rec.r
    rec.c = clip(info.class, 24) or rec.c
    rec.f = clip(info.faction, 24) or rec.f
  end
  rec.s = db._now()
end

function S.intern(list, map, label)
  local id = map[label]
  if id then return id end
  id = #list + 1
  list[id] = label
  map[label] = id
  return id
end

function S.setPhase(db, label)
  local G = db._G
  local id = S.intern(G.dict.p, db._pIdx, label)
  if db._keys[Cal.PHASE] ~= id then
    if db._keys[Cal.PHASE] ~= nil then db._bstart[Cal.PHASE] = db._now() end
    db._keys[Cal.PHASE] = id
    db._keyEpoch = db._keyEpoch + 1
  end
end

function S.tick(db, now)
  now = now or db._now()
  local last = db._lastTick
  db._lastTick = now
  local crossed = false
  if now >= db._cacheEnd or now < db._cacheStart then crossed = S.advanceKeys(db, now) end
  if db._ro then return end
  if last then
    local dt = now - last
    if dt > 0 and dt <= db._opts.tickGap then
      db._wallH:AddAt(now, dt)
      if db._active then db._activeH:AddAt(now, dt) end
    end
  end
  if crossed and db._opts.autoMaintenance then M.Maint.schedule(db, 1) end
end
