-- Maintenance: closing stale buckets, packing closed buckets into chunks, retention, cleanup of
-- removed grains/sets, the size estimator and budget degradation (SPEC D6, D7, D9, §5.3).
-- Runs sliced through the scheduler adapter; never at logout, never inside a write.
local lib = LibStub and LibStub("LibGranaryDB-1.0", true)
local M = lib and lib.__M
if not M then return end

local type, pairs, ipairs, tostring = type, pairs, ipairs, tostring
local floor, format = math.floor, string.format
local cocreate, coresume, costatus, coyield = coroutine.create, coroutine.resume, coroutine.status, coroutine.yield

local Mt = {}
M.Maint = Mt

local U, Cal, P = M.U, M.Cal, M.Pack

Mt.RETENTION_FLOOR = { [1] = 24, [2] = 35, [3] = 12, [4] = 12 }
Mt.OLD_AGE = { [1] = 35 * 24, [2] = 35, [3] = 5, [4] = 5 } -- "older than 35 days" per fine grain

local function keysOf(t)
  local ks = {}
  for k in pairs(t) do ks[#ks + 1] = k end
  table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
  return ks
end

function Mt.retentionFor(rc, gid)
  local r = rc.def.retention[gid]
  local br = rc.saved.br
  if br and br[gid] and (not r or br[gid] < r) then r = br[gid] end
  return r
end

---------------------------------------------------------------------------
-- Steps
---------------------------------------------------------------------------
local function closeStale(db, rc, ce, report)
  local keys, e = db._keys, ce.e
  for gi, gid in ipairs(rc.grains) do
    if gid ~= Cal.LIFETIME then
      local b = e.o[gid]
      local cur = keys[gid]
      if b and cur ~= nil then
        local stale
        if Cal.CALENDAR_GRAINS[gid] then stale = b.k < cur else stale = b.k ~= cur end
        if stale then
          M.Store.closeBucket(db, rc, e, gid, b, db._bstart[gid])
          if ce.ob[gi] == b then ce.ob[gi] = nil end
          ce.keyEpoch = 0
          report.closed = report.closed + 1
        end
      end
    end
  end
end

--- The columns present in a list of buckets (frozen data has no live definition to say which).
local function bucketCols(q)
  local set, out = {}, {}
  for _, b in ipairs(q) do
    for c, col in pairs(b) do
      if c ~= "k" and type(col) == "table" and not set[c] then set[c] = true; out[#out + 1] = c end
    end
  end
  table.sort(out, function(a, b) return (M.Registry.COLUMN_RANK[a] or 99) < (M.Registry.COLUMN_RANK[b] or 99) end)
  return out
end

--- Pack pending buckets into chunks. want(gid): which grains (default: the declared ones; data of grains no longer
--- declared is frozen or about to be deleted, never maintained). frozenCols: take the columns from the buckets.
local function packPending(db, rc, ce, report, cp, want, frozenCols)
  local e = ce.e
  want = want or function(gid) return rc.def.gset[gid] end
  for _, gid in ipairs(keysOf(e.q)) do
    local q = e.q[gid]
    if want(gid) then
      -- detach first: buckets closed by writes during a yield go to a fresh list
      e.q[gid] = nil
      if type(q) == "table" and #q > 0 then
        local qcols = frozenCols and bucketCols(q) or nil
        local groups, order = {}, {}
        for _, b in ipairs(q) do
          local ck = Cal.chunkKey(gid, b.k)
          if not groups[ck] then groups[ck] = {}; order[#order + 1] = ck end
          local g = groups[ck]
          g[#g + 1] = b
        end
        local cold = e.k[gid]
        if not cold then cold = {}; e.k[gid] = cold end
        for _, ck in ipairs(order) do
          local periods, byKey, colSet = {}, {}, {}
          for _, c in ipairs(qcols or rc.colsByGrain[gid] or rc.def.cols) do colSet[c] = true end
          local existing = cold[ck]
          if existing then
            local text, err = P.fromBlob(db, existing)
            local parsed
            if text then parsed, err = P.parse(text, { cp = cp }) end
            if not parsed then
              U.internal(db, format("packed chunk %s/%s/%d unreadable (%s); kept aside", rc.id, Cal.GRAINS[gid], ck, tostring(err)), false)
              local bad = e.bad or {}
              e.bad = bad
              bad[#bad + 1] = existing
            else
              for _, c in ipairs(parsed.cols) do colSet[c] = true end
              for _, p in ipairs(parsed.periods) do periods[#periods + 1] = p; byKey[p.k] = p end
            end
          end
          for _, b in ipairs(groups[ck]) do
            local p = byKey[b.k]
            if p then
              P.mergeBucket(p, b, "time")
            else
              periods[#periods + 1] = b
              byKey[b.k] = b
            end
            report.packed = report.packed + 1
          end
          local cols = {}
          for c in pairs(colSet) do cols[#cols + 1] = c end
          cold[ck] = P.toBlob(db, P.encode(gid, cols, periods))
          report.chunks = report.chunks + 1
          U.stat(db, "packs")
          if cp then cp() end
        end
      end
    end
  end
end

local function applyRetention(db, rc, ce, report)
  local e, keys = ce.e, db._keys
  for gid = 1, 4 do
    -- frozen grains (removed = "keep") are not maintained: retention applies again from the first pass after they
    -- are declared again (TRACKERS_AND_BOARDS §3.3)
    local r = rc.def.gset[gid] and Mt.retentionFor(rc, gid)
    local cold = e.k[gid]
    if r and cold and keys[gid] then
      local cutoff = keys[gid] - r + 1
      for _, ck in ipairs(keysOf(cold)) do
        if Cal.chunkMaxKey(gid, ck) < cutoff then
          cold[ck] = nil
          report.dropped = report.dropped + 1
        end
      end
    end
  end
end

local function cleanupRemoved(db, rc, ce)
  -- removed = "keep": grains and sets no longer declared are frozen (kept as they are), not deleted
  if rc.def.removed == "keep" then return end
  local e, gset = ce.e, rc.def.gset
  for _, part in ipairs({ "o", "q", "k", "park" }) do
    local t = e[part] or {}
    for _, gid in ipairs(keysOf(t)) do
      if not gset[gid] then
        t[gid] = nil
        if not rc.warnedRemoved then
          rc.warnedRemoved = true
          U.log(db, "info", format("dropping data of grains no longer declared by '%s'", rc.id))
        end
      end
    end
  end
  -- orphan tuples (their set was removed from the definition): drop from open buckets
  if rc.ntup > 0 then
    local orphans
    for tid = 1, rc.ntup do
      if rc.tupleSet[tid] == nil then orphans = orphans or {}; orphans[#orphans + 1] = tid end
    end
    if orphans then
      for _, b in pairs(e.o) do
        for c, col in pairs(b) do
          if c ~= "k" and type(col) == "table" then
            for _, tid in ipairs(orphans) do col[tid] = nil end
          end
        end
      end
    end
  end
end

---------------------------------------------------------------------------
-- Size estimator (SPEC §3.5)
---------------------------------------------------------------------------
local function countBucket(b, acc)
  for c, col in pairs(b) do
    if c ~= "k" and type(col) == "table" then
      for _, v in pairs(col) do
        acc.entries = acc.entries + 1
        if type(v) == "string" then acc.bytes = acc.bytes + #v + 8 else acc.bytes = acc.bytes + 12 end
      end
      acc.entries = acc.entries + 1
      acc.bytes = acc.bytes + 8
    end
  end
  acc.entries = acc.entries + 1
  acc.bytes = acc.bytes + 16
end

function Mt.estimateCounter(saved)
  local acc = { entries = 6, bytes = 160, open = 0, pending = 0, chunks = 0, tuples = 0 }
  if type(saved.dm) == "table" then
    for _, labels in pairs(saved.dm) do
      for _, l in pairs(labels) do acc.entries = acc.entries + 1; acc.bytes = acc.bytes + #tostring(l) + 8 end
    end
  end
  if type(saved.tk) == "table" then
    acc.tuples = #saved.tk
    for _, k in pairs(saved.tk) do acc.entries = acc.entries + 1; acc.bytes = acc.bytes + #k + 8 end
  end
  -- r3: bytes per grain id too (acc.byGrain), so hosts can show what a grain costs and what is frozen
  local byGrain = {}
  acc.byGrain = byGrain
  local function grainBytes(gid, before)
    if type(gid) == "number" then byGrain[gid] = (byGrain[gid] or 0) + acc.bytes - before end
  end
  if type(saved.e) == "table" then
    for _, e in pairs(saved.e) do
      acc.entries = acc.entries + 3
      acc.bytes = acc.bytes + 48
      for gid, b in pairs(e.o or {}) do
        local before = acc.bytes
        countBucket(b, acc); acc.open = acc.open + 1
        grainBytes(gid, before)
      end
      if type(e.park) == "table" then
        acc.entries = acc.entries + 1
        for gid, s in pairs(e.park) do
          acc.entries = acc.entries + 1
          acc.bytes = acc.bytes + #s + 16
          acc.parked = (acc.parked or 0) + 1
          grainBytes(gid, acc.bytes - #s - 16)
        end
      end
      for gid, q in pairs(e.q or {}) do
        local before = acc.bytes
        for _, b in ipairs(q) do countBucket(b, acc); acc.pending = acc.pending + 1 end
        grainBytes(gid, before)
      end
      for gid, cold in pairs(e.k or {}) do
        acc.entries = acc.entries + 1
        local before = acc.bytes
        for _, blob in pairs(cold) do
          acc.entries = acc.entries + 1
          acc.bytes = acc.bytes + #blob + 16
          acc.chunks = acc.chunks + 1
        end
        grainBytes(gid, before)
      end
    end
  end
  return acc
end

--- Bytes of frozen data in a counter: all of it when nothing registered it this session, else the grains its
--- definition no longer declares (removed = "keep" keeps them).
function Mt.frozenBytes(db, id, acc)
  local rc = db._counters[id]
  if not rc then return acc.bytes end
  local n = 0
  for gid, b in pairs(acc.byGrain or {}) do
    if not rc.def.gset[gid] then n = n + b end
  end
  return n
end

function Mt.estimate(db)
  local G = db._G
  local per = {}
  local total = { entries = 30, bytes = 600 }
  for id, saved in pairs(G.c) do
    local acc = Mt.estimateCounter(saved)
    per[id] = acc
    total.entries = total.entries + acc.entries
    total.bytes = total.bytes + acc.bytes
  end
  for _, imp in pairs(G.imp or {}) do
    total.entries = total.entries + 5
    total.bytes = total.bytes + (imp.n or 0) + 64
  end
  for _ in pairs(G.ents or {}) do
    total.entries = total.entries + 6
    total.bytes = total.bytes + 96
  end
  for _, l in ipairs(G.dict.v) do total.entries = total.entries + 1; total.bytes = total.bytes + #l + 8 end
  for _, l in ipairs(G.dict.p) do total.entries = total.entries + 1; total.bytes = total.bytes + #l + 8 end
  return per, total
end

---------------------------------------------------------------------------
-- Budget degradation (SPEC D7)
---------------------------------------------------------------------------
local function budgetAction(db, rc, action, detail)
  U.stat(db, "budget")
  U.warn(db, format("budget: %s on '%s' (%s)", action, rc and rc.id or "*", detail))
  M.Store.fire(db, "OnBudget", rc and rc.id or "*", action, detail)
end

local function stepShorten(_db, rc)
  local br = rc.saved.br or {}
  local changed = {}
  for gid = 1, 4 do
    if rc.def.gset[gid] then
      local cur = Mt.retentionFor(rc, gid)
      if cur then
        local nv = floor(cur / 2)
        if nv < Mt.RETENTION_FLOOR[gid] then nv = Mt.RETENTION_FLOOR[gid] end
        if nv < cur then br[gid] = nv; changed[#changed + 1] = Cal.GRAINS[gid] .. "=" .. nv end
      end
    end
  end
  if #changed == 0 then return false end
  rc.saved.br = br
  return true, "retention now " .. table.concat(changed, ", ")
end

local function rewriteChunks(db, rc, filterFn)
  local keys = db._keys
  local touched = 0
  for _, e in pairs(rc.saved.e) do
    for gid = 1, 4 do
      local cold = e.k and e.k[gid]
      if cold and keys[gid] then
        local oldBefore = keys[gid] - Mt.OLD_AGE[gid]
        for _, ck in ipairs(keysOf(cold)) do
          if Cal.chunkMaxKey(gid, ck) < oldBefore then
            local text = P.fromBlob(db, cold[ck])
            local parsed = text and P.parse(text)
            if parsed then
              local removed = false
              for _, p in ipairs(parsed.periods) do
                for _, c in ipairs(parsed.cols) do
                  for tid in pairs(p[c]) do
                    if filterFn(tid) then p[c][tid] = nil; removed = true end
                  end
                end
              end
              if removed then
                cold[ck] = P.toBlob(db, P.encode(gid, parsed.cols, parsed.periods))
                touched = touched + 1
              end
            end
          end
        end
      end
    end
  end
  return touched
end

local function stepDropSets(db, rc)
  rc.saved.bd = rc.saved.bd or {}
  local counts = {}
  for tid = 1, rc.ntup do
    local si = rc.tupleSet[tid]
    if si and rc.sets[si].n > 0 and not rc.saved.bd[rc.sets[si].key] then counts[si] = (counts[si] or 0) + 1 end
  end
  local best, bestN
  for si, n in pairs(counts) do if not bestN or n > bestN then best, bestN = si, n end end
  if not best then return false end
  local setKey = rc.sets[best].key
  rc.saved.bd[setKey] = true
  local touched = rewriteChunks(db, rc, function(tid) return rc.tupleSet[tid] == best end)
  local names = {}
  for k = 1, rc.sets[best].n do names[k] = rc.def.dims[rc.sets[best][k]].name end
  return true, format("dropped set {%s} from %d old chunks", table.concat(names, ","), touched)
end

local function stepRetire(db, rc)
  local bestDim, bestCount
  for i = 1, rc.nd do
    local n = #rc.saved.dm[i]
    if n > 1 and (not bestCount or n > bestCount) then bestDim, bestCount = i, n end
  end
  if not bestDim then return false end
  local i = bestDim
  -- frequency per member from lifetime (or the coarsest open) buckets of sets containing the dimension
  local freq = {}
  local life = Cal.LIFETIME
  for _, e in pairs(rc.saved.e) do
    local b = e.o and (e.o[life] or e.o[rc.grains[rc.ng]])
    if b then
      local col = b.n or b.s or b.l
      if col then
        for tid, v in pairs(col) do
          local si = rc.tupleSet[tid]
          if si then
            local set = rc.sets[si]
            for k = 1, set.n do
              if set[k] == i then
                local id = rc.tupleMembers[tid][k]
                if id > 0 then freq[id] = (freq[id] or 0) + math.abs(v) end
              end
            end
          end
        end
      end
    end
  end
  local dr = rc.saved.dr or {}
  rc.saved.dr = dr
  dr[i] = dr[i] or {}
  local active = {}
  for id = 1, #rc.saved.dm[i] do
    if not dr[i][id] then active[#active + 1] = id end
  end
  local target = floor(rc.def.dims[i].cap * 0.75)
  if #active <= target then target = #active - 1 end
  if target < 1 then return false end
  table.sort(active, function(a, b) return (freq[a] or 0) < (freq[b] or 0) end)
  local retired = 0
  local k = 1
  while #active - retired > target and k <= #active do
    dr[i][active[k]] = true
    retired = retired + 1
    k = k + 1
  end
  if retired == 0 then return false end
  -- rebuild runtime so retired members resolve to `other`, then fold open cells into `other` tuples
  local nrc = M.Store.buildRuntime(db, rc.def, rc.saved, rc.internal)
  db._counters[rc.id] = nrc
  local h = db._handles[rc.id]
  if h then h.rc, h.ce, h.ceEpoch = nrc, nil, -1 end
  for _, e in pairs(nrc.saved.e) do
    for _, b in pairs(e.o or {}) do
      local moves = {}
      local col = b.n or b.s or b.l or b.lo or b.hi
      if col then
        for tid in pairs(col) do
          local parts = nrc.tupleMembers[tid]
          local si = nrc.tupleSet[tid]
          if parts and si then
            local set = nrc.sets[si]
            local np, changed = {}, false
            for kk = 1, set.n do
              local id = parts[kk]
              if id > 0 and dr[set[kk]] and dr[set[kk]][id] then np[kk] = 0; changed = true else np[kk] = id end
            end
            if changed then moves[#moves + 1] = { tid, si, np } end
          end
        end
      end
      for _, mv in ipairs(moves) do
        local tid, si, np = mv[1], mv[2], mv[3]
        for kk = 1, #np do nrc.mids[nrc.sets[si][kk]] = np[kk] end
        local set = nrc.sets[si]
        local tkey = set.key .. ":" .. table.concat(np, ",")
        local dst = nrc.tupleByKey[tkey]
        if not dst then
          dst = nrc.ntup + 1
          nrc.ntup = dst
          nrc.saved.tk[dst] = tkey
          nrc.tupleSet[dst] = si
          nrc.tupleByKey[tkey] = dst
          nrc.tupleMembers[dst] = np
        end
        P.mergeCell(b, dst, b, tid, "time")
        for c, colT in pairs(b) do
          if c ~= "k" and type(colT) == "table" then colT[tid] = nil end
        end
      end
    end
  end
  -- runtime again, so the new `other` tuples get lookup paths
  local nrc2 = M.Store.buildRuntime(db, rc.def, rc.saved, rc.internal)
  db._counters[rc.id] = nrc2
  if h then h.rc, h.ce, h.ceEpoch = nrc2, nil, -1 end
  return true, format("retired %d members of '%s'", retired, rc.def.dims[i].name)
end

local STEPS = {
  { "pack", function(db, rc)
      for _, key in ipairs(keysOf(rc.saved.e)) do
        packPending(db, rc, M.Store.entity(db, rc, key), { packed = 0, chunks = 0 })
      end
      return true, "packed all pending buckets"
    end },
  { "shorten", stepShorten },
  { "dropsets", stepDropSets },
  { "retire", stepRetire },
}

---------------------------------------------------------------------------
-- Frozen data in the budget (r3, LG-17). Frozen data has no live definition, so only steps that need none: pack
-- stale buckets of hours, days and weeks into chunks, then apply the default retention (or the definition's, for a
-- registered counter's frozen grains) to them. Months, years and lifetime are never cut.
---------------------------------------------------------------------------
local FROZEN_GRAINS = { 1, 2, 3, 4 }   -- hour, day, week, resetweek

local function frozenList(db, per)
  local list = {}
  for id, saved in pairs(db._G.c) do
    local rc = db._counters[id]
    if type(saved) == "table" and type(saved.e) == "table" and id:sub(1, 1) ~= "@" then
      local grains = {}
      local any = false
      for _, gid in ipairs(FROZEN_GRAINS) do
        if not rc or (rc.def.removed == "keep" and not rc.def.gset[gid]) then grains[gid] = true; any = true end
      end
      if any then
        local acc = per[id]
        list[#list + 1] = { id = id, saved = saved, rc = rc, grains = grains, bytes = acc and Mt.frozenBytes(db, id, acc) or 0 }
      end
    end
  end
  table.sort(list, function(a, b)
    if a.bytes ~= b.bytes then return a.bytes > b.bytes end
    return a.id < b.id
  end)
  return list
end

local function isStale(db, gid, k)
  local cur = db._keys[gid]
  if cur == nil or k == nil then return false end
  return k < cur
end

local function frozenPack(db, f)
  local report = { packed = 0, chunks = 0 }
  local fake = { id = f.id, colsByGrain = {}, def = { cols = {} } }
  for _, key in ipairs(keysOf(f.saved.e)) do
    local e = f.saved.e[key]
    e.o, e.q, e.k = e.o or {}, e.q or {}, e.k or {}
    for gid in pairs(f.grains) do
      local b = e.o[gid]
      if b and isStale(db, gid, b.k) then
        e.o[gid] = nil
        if not M.Store.bucketEmpty(b) then
          local q = e.q[gid] or {}
          e.q[gid] = q
          q[#q + 1] = b
        end
      end
    end
    packPending(db, fake, { e = e }, report, nil, function(gid) return f.grains[gid] end, true)
  end
  if report.packed == 0 then return false end
  return true, format("packed %d frozen buckets", report.packed)
end

local function frozenRetention(db, f)
  local dropped = 0
  for _, key in ipairs(keysOf(f.saved.e)) do
    local e = f.saved.e[key]
    for gid in pairs(f.grains) do
      local r = f.rc and Mt.retentionFor(f.rc, gid)
      if not r then
        local spec = M.Registry.DEFAULT_RETENTION[Cal.GRAINS[gid]]
        r = spec and U.retentionPeriods(spec, Cal.GRAINS[gid])
      end
      local cur = db._keys[gid]
      if r and cur then
        local cutoff = cur - r + 1
        local cold = e.k and e.k[gid]
        if cold then
          for _, ck in ipairs(keysOf(cold)) do
            if Cal.chunkMaxKey(gid, ck) < cutoff then cold[ck] = nil; dropped = dropped + 1 end
          end
        end
        local q = e.q and e.q[gid]
        if q then
          for i = #q, 1, -1 do
            if q[i].k < cutoff then table.remove(q, i); dropped = dropped + 1 end
          end
        end
        if e.o and e.o[gid] and e.o[gid].k < cutoff then e.o[gid] = nil; dropped = dropped + 1 end
        if e.park and e.park[gid] then
          local k = M.Store.parseParked(e.park[gid])
          if k and k < cutoff then
            e.park[gid] = nil
            if next(e.park) == nil then e.park = nil end
            dropped = dropped + 1
          end
        end
      end
    end
  end
  if dropped == 0 then return false end
  return true, format("dropped %d frozen hour/day/week pieces past retention", dropped)
end

--- One frozen step, on the counter with the most frozen bytes that still has one to take. True if it did one.
function Mt.frozenBudgetStep(db, per, report)
  for _, f in ipairs(frozenList(db, per)) do
    for _, step in ipairs({ { "frozen-pack", frozenPack }, { "frozen-retention", frozenRetention } }) do
      local did, detail = step[2](db, f)
      if did then
        U.stat(db, "budget")
        U.warn(db, format("budget: %s on '%s' (%s)", step[1], f.id, detail))
        M.Store.fire(db, "OnBudget", f.id, step[1], detail)
        report.budget = step[1]
        if f.rc then
          -- the runtime's entity bindings may point at buckets that just moved
          f.rc.ents = {}
          local h = db._handles[f.id]
          if h then h.ce, h.ceEpoch = nil, -1 end
        end
        return true
      end
    end
  end
  return false
end

local function applyBudget(db, report)
  local per, total = Mt.estimate(db)
  report.entries, report.bytes = total.entries, total.bytes
  local target
  for id, rc in pairs(db._counters) do
    local b = rc.def.budget
    if b and not rc.internal then
      local acc = per[id]
      if acc and ((b.entries and acc.entries > b.entries) or (b.bytes and acc.bytes > b.bytes)) then target = rc; break end
    end
  end
  if not target and (total.entries > db._opts.maxEntries or total.bytes > db._opts.maxBytes) then
    -- r3 (LG-17): frozen data goes first, so it can't get active counters degraded for good
    if Mt.frozenBudgetStep(db, per, report) then return end
    local bestBytes
    for id, rc in pairs(db._counters) do
      if not rc.internal and (rc.saved.bs or 0) < #STEPS then
        local acc = per[id]
        if acc and (not bestBytes or acc.bytes > bestBytes) then target, bestBytes = rc, acc.bytes end
      end
    end
    if not target then
      if not db._warnedBudget then
        db._warnedBudget = true
        U.warn(db, format("budget: still over (%d entries, %d bytes) with every degradation step used", total.entries, total.bytes))
      end
      return
    end
  end
  if not target then return end
  local bs = target.saved.bs or 0
  while bs < #STEPS do
    local step = STEPS[bs + 1]
    local did, detail = step[2](db, db._counters[target.id] or target)
    if did then
      budgetAction(db, target, step[1], detail)
      if step[1] == "pack" then target.saved.bs = bs + 1 end
      report.budget = step[1]
      return
    end
    bs = bs + 1
    target.saved.bs = bs
  end
end

---------------------------------------------------------------------------
-- The pass
---------------------------------------------------------------------------
--- A parked entity needs unparking when one of its parked buckets closed or its grain was removed.
local function parkedNeedsWork(db, rc, e)
  local keys = db._keys
  local keep = rc.def.removed == "keep"
  for gid, s in pairs(e.park) do
    -- a frozen grain's parked bucket (removed = "keep") stays parked; a deleted one needs the unpark to go
    if not rc.def.gset[gid] then
      if not keep then return true end
    else
      local k = M.Store.parseParked(s)
      if k == nil then return true end
      if gid ~= Cal.LIFETIME and keys[gid] ~= nil then
        if Cal.CALENDAR_GRAINS[gid] then
          if k < keys[gid] then return true end
        elseif k ~= keys[gid] then
          return true
        end
      end
    end
  end
  return false
end
function Mt.pass(db, cp)
  cp = cp or function() end
  local report = { packed = 0, chunks = 0, dropped = 0, closed = 0 }
  local t0 = db._ad.clock.preciseMs()
  local now = db._now()
  if now >= db._cacheEnd or now < db._cacheStart then M.Store.advanceKeys(db, now) end
  for _, id in ipairs(keysOf(db._counters)) do
    local rc = db._counters[id]
    if rc then
      for _, key in ipairs(keysOf(rc.saved.e)) do
        rc = db._counters[id]
        local e = rc and rc.saved.e[key]
        if e then   -- DropCounter cancels a running pass; this guards the slice it was in
          local current = (rc.scopeAccount and "@account" or db._entity) == key
          local ce
          if current or next(e.o or {}) ~= nil or (e.park and parkedNeedsWork(db, rc, e)) then
            ce = M.Store.entity(db, rc, key) -- unparks if needed
            closeStale(db, rc, ce, report)
          else
            ce = { e = e, ob = {} } -- parked and up to date: only cold data to look after
            e.q, e.k = e.q or {}, e.k or {}
          end
          packPending(db, rc, ce, report, cp)
          applyRetention(db, rc, ce, report)
          cleanupRemoved(db, rc, ce)
          if not current and next(ce.e.o or {}) ~= nil then
            report.parked = (report.parked or 0) + M.Store.park(db, rc, ce)
          end
        end
        cp()
      end
    end
  end
  applyBudget(db, report)
  report.ms = db._ad.clock.preciseMs() - t0
  local G = db._G
  G.meta.last = G.meta.last or {}
  G.meta.last.maint = now
  G.libMinor = M.MINOR
  U.stat(db, "maintenance")
  if report.packed > 0 or report.dropped > 0 then
    M.Store.fire(db, "OnCompaction", report)
    M.Store.fire(db, "OnRollup", report)
  end
  db._lastReport = report
  return report
end

--- Run a full pass synchronously.
function Mt.runNow(db)
  if db._ro then return nil, db._roReason end
  local ok, res = pcall(Mt.pass, db)
  if not ok then
    U.internal(db, "maintenance failed: " .. tostring(res), true)
    return nil, res
  end
  return res
end

--- Schedule a sliced pass after `delay` seconds (one at a time).
function Mt.schedule(db, delay)
  if db._maintScheduled or db._maintCo or db._ro or db._detached then return end
  db._maintScheduled = true
  db._ad.scheduler.after(delay, function()
    db._maintScheduled = false
    Mt.start(db)
  end)
end

function Mt.start(db)
  if db._maintCo or db._ro or db._detached then return end
  local clock, sliceMs = db._ad.clock, db._opts.sliceMs
  local sliceStart = 0
  local function cp()
    if clock.preciseMs() - sliceStart > sliceMs then coyield() end
  end
  local co = cocreate(function() return Mt.pass(db, cp) end)
  db._maintCo = co
  local function step()
    if db._maintCo ~= co then return end
    sliceStart = clock.preciseMs()
    local ok, err = coresume(co)
    if not ok then
      db._maintCo = nil
      U.internal(db, "maintenance failed: " .. tostring(err), true)
      return
    end
    if costatus(co) == "dead" then
      db._maintCo = nil
      if db._opts.autoMaintenance then Mt.schedule(db, db._opts.maintenanceInterval) end
    else
      db._ad.scheduler.after(0, step)
    end
  end
  step()
end

---------------------------------------------------------------------------
-- DropCounter (r3, LG-17): the only call that deletes data. Never called by the library itself.
---------------------------------------------------------------------------
local function entityHasData(e, grains)
  if type(e) ~= "table" then return false end
  for _, part in ipairs({ "o", "q", "k", "park" }) do
    local t = e[part]
    if type(t) == "table" then
      for gid, v in pairs(t) do
        if not grains or grains[gid] then
          if part == "q" then
            if type(v) == "table" and #v > 0 then return true end
          elseif part == "k" then
            if type(v) == "table" and next(v) ~= nil then return true end
          elseif part == "o" then
            if type(v) == "table" and not M.Store.bucketEmpty(v) then return true end
          else
            return true
          end
        end
      end
    end
  end
  return false
end

--- Drop saved data of counter `id` in this root. opts.entity: one entity only; opts.grains: { gid = true } only.
--- Returns the estimated bytes freed, or false when there was nothing to drop.
function Mt.drop(db, id, entity, grains)
  local G = db._G
  local saved = G.c[id]
  if type(saved) ~= "table" then return false end
  local rc = db._counters[id]
  local before = Mt.estimateCounter(saved).bytes
  local had = false
  if type(saved.e) == "table" then
    for key, e in pairs(saved.e) do
      if (entity == nil or key == entity) and entityHasData(e, grains) then had = true end
    end
  end
  if not grains and not entity and ((type(saved.dm) == "table" and next(saved.dm[1] or {}) ~= nil)
      or (type(saved.tk) == "table" and #saved.tk > 0)) then
    had = true
  end
  -- a sliced pass in progress may hold references into this counter: stop it, run a fresh one later
  if db._maintCo then
    db._maintCo = nil
    if db._opts.autoMaintenance then Mt.schedule(db, 1) end
  end
  if not grains and not entity then
    if rc then
      -- reset in place: the definition and the handle stay valid, writes continue from zero
      local fresh = { def = saved.def, dm = {}, tk = {}, e = {} }
      G.c[id] = fresh
      local nrc = M.Store.buildRuntime(db, rc.def, fresh, rc.internal)
      db._counters[id] = nrc
      local h = db._handles[id]
      if h then h.rc, h.ce, h.ceEpoch = nrc, nil, -1 end
    else
      G.c[id] = nil   -- no tombstone: registering the id again starts it empty
    end
  else
    for key, e in pairs(saved.e or {}) do
      if entity == nil or key == entity then
        if grains then
          for _, part in ipairs({ "o", "q", "k", "park" }) do
            local t = e[part]
            if type(t) == "table" then for gid in pairs(grains) do t[gid] = nil end end
          end
          if e.park and next(e.park) == nil then e.park = nil end
        else
          saved.e[key] = nil
        end
      end
    end
    if grains and type(saved.br) == "table" then
      for gid in pairs(grains) do saved.br[gid] = nil end
    end
    if rc then
      rc.ents = {}
      rc.gen = (rc.gen or 0) + 1
      local h = db._handles[id]
      if h then h.ce, h.ceEpoch = nil, -1 end
    end
  end
  db._qcache, db._qcacheN = {}, 0
  if not had then return false end
  local after = G.c[id] and Mt.estimateCounter(G.c[id]).bytes or 0
  local freed = before - after
  if freed < 1 then freed = 1 end
  U.stat(db, "drops")
  return freed
end
