-- Registry: validation of counter definitions (data only), normalisation, canonical form,
-- fingerprints and the compatibility check on re-registration (SPEC §2.4).
local lib = LibStub and LibStub("LibGranaryDB-1.0", true)
local M = lib and lib.__M
if not M then return end

local type, pairs, ipairs, tostring, error, pcall = type, pairs, ipairs, tostring, error, pcall
local format, concat, floor = string.format, table.concat, math.floor

local R = {}
M.Registry = R

-- r2 (QUEUE LG-1): cap 1024 -> 4096 and tuples 4096 -> 16384, measured in docs/BENCHMARKS.md §7.
R.MAX_DIMS, R.MAX_SETS, R.MAX_CAP, R.DEFAULT_CAP, R.MAX_TUPLES = 6, 8, 4096, 32, 16384

R.MEASURES = {
  flow = { sum = { "s" }, count = { "n" }, min = { "lo" }, max = { "hi" }, first = { "f", "ft" }, last = { "l", "lt" } },
  stock = { last = { "l", "lt" }, min = { "lo" }, max = { "hi" }, twa = { "l", "lt", "ti", "td" }, first = { "f", "ft" } },
}
R.DEFAULT_MEASURES = { flow = { "sum", "count" }, stock = { "last", "min", "max", "twa" } }
R.COLUMN_ORDER = { "s", "n", "lo", "hi", "f", "ft", "l", "lt", "ti", "td", "xlo", "xhi" }
R.COLUMN_RANK = {}
for i, c in ipairs(R.COLUMN_ORDER) do R.COLUMN_RANK[c] = i end
R.STRING_COLUMNS = { xlo = true, xhi = true }
R.DEFAULT_GRAINS = { "day", "week", "month", "year", "lifetime" }
R.DEFAULT_RETENTION = { hour = "48h", day = "90d", week = "2y", resetweek = "2y" }
R.DEFAULT_CTX_GRAINS = { "day", "lifetime" }

local KNOWN_KEYS = {
  id = true, version = true, kind = true, unit = true, measures = true, dimensions = true, aggregations = true,
  grains = true, retention = true, context = true, contextGrains = true, scope = true, maxGap = true,
  budget = true, onIncompatible = true, hist = true, removed = true,
}

local function fail(fmt, ...)
  error({ def = format(fmt, ...) }, 0)
end

local function isName(s) return type(s) == "string" and s:match("^[%a_][%w_]*$") ~= nil and #s <= 32 end

local function validate(def, internal)
  if type(def) ~= "table" then fail("counter definition must be a table, got %s", type(def)) end
  for k in pairs(def) do
    if not KNOWN_KEYS[k] then fail("unknown definition field '%s'", tostring(k)) end
  end
  local nd = {}
  -- id
  local id = def.id
  if type(id) ~= "string" then fail("definition field 'id' must be a string like \"myaddon:jumps\"") end
  if not internal and (not id:match("^[%w_%-%.]+:[%w_%-%.:]+$") or #id > 64) then
    fail("counter id '%s' must be namespaced \"addon:name\" ([%%w_.-:], at most 64 characters)", id)
  end
  nd.id = id
  -- version
  local v = def.version
  if type(v) ~= "number" or v < 1 or v ~= floor(v) then fail("'%s': 'version' must be an integer >= 1", id) end
  nd.version = v
  -- kind
  local kind = def.kind or "flow"
  if kind ~= "flow" and kind ~= "stock" then fail("'%s': 'kind' must be \"flow\" or \"stock\"", id) end
  nd.kind = kind
  if def.unit ~= nil and (type(def.unit) ~= "string" or #def.unit > 32) then
    fail("'%s': 'unit' must be a string of at most 32 characters", id)
  end
  nd.unit = def.unit
  if def.hist ~= nil then
    fail("'%s': 'hist' is not supported in LibGranaryDB v1 (see Supports(\"hist\"))", id)
  end
  -- measures
  local measures = def.measures or R.DEFAULT_MEASURES[kind]
  if type(measures) ~= "table" or #measures == 0 then fail("'%s': 'measures' must be a non-empty array", id) end
  local mset, mlist = {}, {}
  for _, m in ipairs(measures) do
    if not R.MEASURES[kind][m] then
      local allowed = {}
      for name in pairs(R.MEASURES[kind]) do allowed[#allowed + 1] = name end
      table.sort(allowed)
      if kind == "stock" and (m == "sum" or m == "count") then
        fail("'%s': stocks can't use '%s' (summing a level over time is meaningless); use %s", id, m,
          concat(allowed, ", "))
      end
      fail("'%s': unknown measure '%s' for a %s; allowed: %s", id, tostring(m), kind, concat(allowed, ", "))
    end
    if mset[m] then fail("'%s': measure '%s' listed twice", id, m) end
    mset[m] = true
    mlist[#mlist + 1] = m
  end
  table.sort(mlist)
  nd.measures, nd.mset = mlist, mset
  -- dimensions (ordered array)
  local dims = def.dimensions or {}
  if type(dims) ~= "table" then fail("'%s': 'dimensions' must be an array", id) end
  if not M.U.isArray(dims) then
    fail("'%s': 'dimensions' must be an ordered array like { { name = \"mode\", cap = 8 } }, not a map "
      .. "(Lua tables don't keep key order, and dimension order matters for Add)", id)
  end
  if #dims > R.MAX_DIMS then fail("'%s': at most %d dimensions", id, R.MAX_DIMS) end
  nd.dims, nd.dimIndex = {}, {}
  for i, d in ipairs(dims) do
    if type(d) ~= "table" or not isName(d.name) then
      fail("'%s': dimension %d needs a 'name' (letters, digits, _)", id, i)
    end
    for k in pairs(d) do
      if k ~= "name" and k ~= "cap" and k ~= "private" and k ~= "other" then
        fail("'%s': dimension '%s' has unknown field '%s'", id, d.name, tostring(k))
      end
    end
    if nd.dimIndex[d.name] then fail("'%s': dimension '%s' declared twice", id, d.name) end
    local cap = d.cap or R.DEFAULT_CAP
    if type(cap) ~= "number" or cap < 1 or cap > R.MAX_CAP or cap ~= floor(cap) then
      fail("'%s': dimension '%s' cap must be an integer 1..%d", id, d.name, R.MAX_CAP)
    end
    nd.dims[i] = { name = d.name, cap = cap, private = d.private == true }
    nd.dimIndex[d.name] = i
  end
  -- aggregation sets
  local aggs = def.aggregations or { {} }
  if type(aggs) ~= "table" or not M.U.isArray(aggs) then fail("'%s': 'aggregations' must be an array of arrays", id) end
  nd.sets, nd.setByKey = {}, {}
  local function addSet(names, where)
    if type(names) ~= "table" or not M.U.isArray(names) then fail("'%s': %s must be an array of dimension names", id, where) end
    local idx, seen = {}, {}
    for _, name in ipairs(names) do
      local di = nd.dimIndex[name]
      if not di then fail("'%s': %s names unknown dimension '%s'", id, where, tostring(name)) end
      if seen[di] then fail("'%s': %s lists '%s' twice", id, where, name) end
      seen[di] = true
      idx[#idx + 1] = di
    end
    table.sort(idx)
    local key = concat(idx, ",")
    if not nd.setByKey[key] then
      local set = { key = key, n = #idx }
      for k = 1, #idx do set[k] = idx[k] end
      nd.sets[#nd.sets + 1] = set
      nd.setByKey[key] = #nd.sets
    end
  end
  addSet({}, "the grand total")
  for i, a in ipairs(aggs) do addSet(a, "aggregation " .. i) end
  if #nd.sets > R.MAX_SETS then fail("'%s': at most %d aggregation sets", id, R.MAX_SETS) end
  -- grains
  local grains = def.grains or R.DEFAULT_GRAINS
  if type(grains) ~= "table" or #grains == 0 then fail("'%s': 'grains' must be a non-empty array", id) end
  local gset, glist = {}, {}
  for _, g in ipairs(grains) do
    local gid = M.Cal.GRAIN_ID[g]
    if not gid then fail("'%s': unknown grain '%s' (allowed: %s)", id, tostring(g), concat(M.Cal.GRAINS, ", ")) end
    if not gset[gid] then gset[gid] = true; glist[#glist + 1] = gid end
  end
  table.sort(glist)
  nd.grains, nd.gset = glist, gset
  -- retention
  local ret = def.retention or {}
  if type(ret) ~= "table" then fail("'%s': 'retention' must be a table", id) end
  nd.retention = {}
  for gname, spec in pairs(ret) do
    local gid = M.Cal.GRAIN_ID[gname]
    if not gid or not M.Cal.CALENDAR_GRAINS[gid] or gid >= 5 then
      fail("'%s': retention can only be set for hour, day, week or resetweek (got '%s')", id, tostring(gname))
    end
    local p = M.U.retentionPeriods(spec, gname)
    if not p then fail("'%s': retention for '%s' must look like \"48h\", \"90d\", \"12w\", \"2y\" or a period count", id, gname) end
    nd.retention[gid] = p
  end
  for gname, spec in pairs(R.DEFAULT_RETENTION) do
    local gid = M.Cal.GRAIN_ID[gname]
    if not nd.retention[gid] then nd.retention[gid] = M.U.retentionPeriods(spec, gname) end
  end
  -- context
  nd.context = {}
  if def.context ~= nil then
    if type(def.context) ~= "table" then fail("'%s': 'context' must be a table like { max = { \"zone\" } }", id) end
    for m, fields in pairs(def.context) do
      if m ~= "min" and m ~= "max" then fail("'%s': context can only be kept for min or max (got '%s')", id, tostring(m)) end
      if not mset[m] then fail("'%s': context for '%s' needs the measure '%s' declared", id, m, m) end
      if type(fields) ~= "table" or not M.U.isArray(fields) or #fields > 4 then
        fail("'%s': context.%s must be an array of at most 4 field names", id, m)
      end
      local fl = {}
      for i, f in ipairs(fields) do
        if not isName(f) then fail("'%s': context.%s field %d must be a name", id, m, i) end
        fl[i] = f
      end
      nd.context[m] = fl
    end
  end
  local cg = def.contextGrains or R.DEFAULT_CTX_GRAINS
  if type(cg) ~= "table" then fail("'%s': 'contextGrains' must be an array", id) end
  nd.ctxGrains = {}
  for _, g in ipairs(cg) do
    local gid = M.Cal.GRAIN_ID[g]
    if not gid then fail("'%s': contextGrains names unknown grain '%s'", id, tostring(g)) end
    nd.ctxGrains[gid] = true
  end
  -- scope, maxGap, budget, onIncompatible
  local scope = def.scope or "character"
  if type(scope) == "table" then scope = scope[1] end -- DESIGN draft used { "character" }
  if scope ~= "character" and scope ~= "account" then fail("'%s': 'scope' must be \"character\" or \"account\"", id) end
  nd.scope = scope
  if def.maxGap ~= nil and (type(def.maxGap) ~= "number" or def.maxGap <= 0) then
    fail("'%s': 'maxGap' must be a positive number of seconds", id)
  end
  if def.maxGap ~= nil and kind ~= "stock" then fail("'%s': 'maxGap' only applies to stocks", id) end
  nd.maxGap = def.maxGap
  if def.budget ~= nil then
    local b = def.budget
    if type(b) ~= "table" then fail("'%s': 'budget' must be a table like { entries = 5000 }", id) end
    for k, val in pairs(b) do
      if (k ~= "entries" and k ~= "bytes" and k ~= "cells") or type(val) ~= "number" or val <= 0 then
        fail("'%s': budget accepts positive 'entries' and 'bytes'", id)
      end
    end
    nd.budget = { entries = b.entries or b.cells, bytes = b.bytes }
  end
  local oi = def.onIncompatible or "error"
  if oi ~= "error" and oi ~= "reset" then fail("'%s': 'onIncompatible' must be \"error\" or \"reset\"", id) end
  nd.onIncompatible = oi
  -- r3 (LG-17): what maintenance does with data of grains and aggregation sets no longer declared. "drop" deletes it
  -- (r1/r2 behaviour); "keep" freezes it: not written, not maintained, kept, and resumed when declared again.
  -- Not structural: it isn't in the fingerprint or the canonical form.
  local removed = def.removed or "drop"
  if removed ~= "drop" and removed ~= "keep" then fail("'%s': 'removed' must be \"drop\" or \"keep\"", id) end
  nd.removed = removed
  -- columns
  local cols, cset = {}, {}
  for _, m in ipairs(mlist) do
    for _, c in ipairs(R.MEASURES[kind][m]) do
      if not cset[c] then cset[c] = true; cols[#cols + 1] = c end
    end
  end
  if nd.context.min then cset.xlo = true; cols[#cols + 1] = "xlo" end
  if nd.context.max then cset.xhi = true; cols[#cols + 1] = "xhi" end
  table.sort(cols, function(a, b) return R.COLUMN_RANK[a] < R.COLUMN_RANK[b] end)
  nd.cols, nd.cset = cols, cset
  nd.fingerprint = R.fingerprint(nd)
  return nd
end

--- Validate a definition. Returns the normalised definition, or nil and a message.
function R.validate(def, internal)
  local ok, res = pcall(validate, def, internal)
  if ok then return res end
  if type(res) == "table" and res.def then return nil, res.def end
  return nil, "invalid definition: " .. tostring(res)
end

--- Fingerprint: Adler-32 of the structural parts (kind, measures, dimension names, sets, grains).
function R.fingerprint(nd)
  local parts = { nd.kind, concat(nd.measures, ",") }
  local dn = {}
  for i, d in ipairs(nd.dims) do dn[i] = d.name end
  parts[#parts + 1] = concat(dn, ",")
  local sk = {}
  for i, s in ipairs(nd.sets) do sk[i] = s.key end
  table.sort(sk)
  parts[#parts + 1] = concat(sk, "|")
  parts[#parts + 1] = concat(nd.grains, ",")
  return M.Codec.adler32(concat(parts, ";"))
end

--- The canonical, data-only form of a normalised definition (stored and exported).
function R.canonical(nd)
  local d = { id = nd.id, version = nd.version, kind = nd.kind, unit = nd.unit, scope = nd.scope }
  d.measures = M.U.copy(nd.measures)
  d.dimensions = {}
  for i, dim in ipairs(nd.dims) do
    d.dimensions[i] = { name = dim.name, cap = dim.cap, private = dim.private or nil }
  end
  d.aggregations = {}
  for i, s in ipairs(nd.sets) do
    local names = {}
    for k = 1, s.n do names[k] = nd.dims[s[k]].name end
    d.aggregations[i] = names
  end
  d.grains = {}
  for i, gid in ipairs(nd.grains) do d.grains[i] = M.Cal.GRAINS[gid] end
  d.retention = {}
  for gid, p in pairs(nd.retention) do d.retention[M.Cal.GRAINS[gid]] = p end
  if next(nd.context) then
    d.context = {}
    for m, fl in pairs(nd.context) do d.context[m] = M.U.copy(fl) end
  end
  local cg = {}
  for gid in pairs(nd.ctxGrains) do cg[#cg + 1] = gid end
  table.sort(cg)
  d.contextGrains = {}
  for i, gid in ipairs(cg) do d.contextGrains[i] = M.Cal.GRAINS[gid] end
  d.maxGap = nd.maxGap
  if nd.budget then d.budget = M.U.copy(nd.budget) end
  d.onIncompatible = nd.onIncompatible
  return d
end

--- Compare an old stored definition (normalised) with a new one.
--- Returns "same" | "compatible" | "incompatible", and a reason for incompatible.
function R.compare(old, new)
  if old.fingerprint == new.fingerprint then return "same" end
  if old.kind ~= new.kind then return "incompatible", "kind changed from " .. old.kind .. " to " .. new.kind end
  if #new.dims < #old.dims then return "incompatible", "dimensions were removed" end
  for i, d in ipairs(old.dims) do
    if new.dims[i].name ~= d.name then
      return "incompatible", format("dimension %d changed from '%s' to '%s' (renamed or reordered)", i, d.name, new.dims[i].name)
    end
  end
  return "compatible"
end
