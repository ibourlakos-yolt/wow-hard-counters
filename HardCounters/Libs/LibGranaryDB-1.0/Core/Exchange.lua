-- Exchange: scoped export strings, the whitelist validator, read-only imported datasets (SPEC §7).
--   !GranaryDB:1!<c>:<adler32>:<base64(payload)>!End:GranaryDB:1!
-- Imports are data only: decoded by the pure-Lua CBOR decoder with limits, never loadstring.
local lib = LibStub and LibStub("LibGranaryDB-1.0", true)
local M = lib and lib.__M
if not M then return end

local type, pairs, ipairs, tostring, pcall = type, pairs, ipairs, tostring, pcall
local format, sort = string.format, table.sort

local X = {}
M.Exchange = X

local U, Cal, P, R = M.U, M.Cal, M.Pack, M.Registry

X.PREFIX, X.SUFFIX = "!GranaryDB:1!", "!End:GranaryDB:1!"
X.MAX_INPUT = 4194304
X.LIMITS = { maxDepth = 8, maxString = 1048576, maxItems = 400000 }
X.MAX_COUNTERS, X.MAX_ENTITIES = 32, 64 -- labels per dimension: R.MAX_CAP; tuples: R.MAX_TUPLES

---------------------------------------------------------------------------
-- Envelope
---------------------------------------------------------------------------
function X.wrap(db, body, prefix, suffix)
  local raw = db._ad.serializer.encode(body)
  local cs = M.Codec.adler32(raw)
  local c, payload = "n", raw
  local comp = db._ad.compressor
  if comp.name ~= "none" then
    local ok, z = pcall(comp.compress, raw)
    if ok and type(z) == "string" then c, payload = "d", z end
  end
  return (prefix or X.PREFIX) .. c .. ":" .. cs .. ":" .. db._ad.encoder.encode(payload) .. (suffix or X.SUFFIX)
end

--- Unwrap and checksum-verify. Returns the raw CBOR bytes or nil, err.
function X.unwrap(db, str, prefix, suffix, name)
  prefix, suffix, name = prefix or X.PREFIX, suffix or X.SUFFIX, name or "GranaryDB"
  if type(str) ~= "string" then return nil, "not a string" end
  if #str > X.MAX_INPUT then return nil, format("too large (%d bytes; the limit is %d)", #str, X.MAX_INPUT) end
  str = str:gsub("%s", "")
  local fmtTag = str:match("^!" .. name .. ":(%d+)!")
  if not fmtTag then return nil, "not a " .. name .. " string (missing the !" .. name .. ":1! prefix)" end
  if fmtTag ~= "1" then return nil, format("unsupported %s format %s (this copy reads format 1; update the addon)", name, fmtTag) end
  if str:sub(-#suffix) ~= suffix then return nil, "truncated: the end marker " .. suffix .. " is missing (copy the whole string)" end
  local inner = str:sub(#prefix + 1, -#suffix - 1)
  local c, cs, text = inner:match("^([dn]):(%x%x%x%x%x%x%x%x):([A-Za-z0-9%+/=]*)$")
  if not c then return nil, "corrupt: bad header" end
  local payload, derr = M.Codec.base64Decode(text)
  if not payload then return nil, "corrupt: " .. tostring(derr) end
  local raw = payload
  if c == "d" then
    local comp = db._ad.compressor
    if comp.name == "none" then return nil, "this client can't decompress Deflate data" end
    local ok, out = pcall(comp.decompress, payload)
    if not ok or type(out) ~= "string" then return nil, "corrupt: decompression failed" end
    raw = out
  end
  if #raw > X.MAX_INPUT * 4 then return nil, "too large after decompression" end
  if M.Codec.adler32(raw) ~= cs then return nil, "corrupt: checksum mismatch" end
  return raw
end

---------------------------------------------------------------------------
-- Export
---------------------------------------------------------------------------
local EXPORT_KEYS = { counters = true, entity = true, grains = true, range = true, scrub = true, label = true, maxBytes = true }

function X.checkSpec(db, spec)
  if type(spec) ~= "table" then return "export spec must be a table" end
  for k in pairs(spec) do if not EXPORT_KEYS[k] then return format("unknown export field '%s'", tostring(k)) end end
  if type(spec.counters) ~= "table" or #spec.counters == 0 then
    return "export needs 'counters' (a non-empty array of ids); exporting everything is not supported"
  end
  for _, id in ipairs(spec.counters) do
    if type(id) ~= "string" or not db._counters[id] or db._counters[id].internal then
      return format("export: unknown counter '%s'", tostring(id))
    end
  end
  if spec.grains ~= nil then
    if type(spec.grains) ~= "table" then return "'grains' must be an array of grain names" end
    for _, g in ipairs(spec.grains) do if not Cal.GRAIN_ID[g] then return format("unknown grain '%s'", tostring(g)) end end
  end
  if spec.range ~= nil and (type(spec.range) ~= "table" or type(spec.range.from) ~= "number" or type(spec.range.to) ~= "number") then
    return "'range' must be { from = epochSeconds, to = epochSeconds }"
  end
  if spec.entity ~= nil and type(spec.entity) ~= "string" then return "'entity' must be \"current\", \"account\" or a key" end
  if spec.label ~= nil and (type(spec.label) ~= "string" or #spec.label > 64) then return "'label' must be a string of at most 64 characters" end
  if spec.maxBytes ~= nil and (type(spec.maxBytes) ~= "number" or spec.maxBytes < 1) then return "'maxBytes' must be a positive number" end
  return nil
end

local function collectPeriods(db, rc, key, gid, from, to)
  local src = M.Query.localSource(db, rc.id)
  local byKey, list = {}, {}
  src.visit(key, gid, from, to, function(p)
    local d = byKey[p.k]
    if not d then
      d = { k = p.k }
      byKey[p.k] = d
      list[#list + 1] = d
    end
    P.mergeBucket(d, p, "time")
  end)
  return list
end

function X.export(db, spec)
  local G = db._G
  local grains = spec.grains or { "day", "month", "lifetime" }
  local scrub = spec.scrub == true
  local body = {
    fmt = 1, lib = M.MINOR, schema = M.SCHEMA, at = db._now(), label = spec.label or "", scrub = scrub,
    cal = { cal = db._opts.calendar, dsh = db._opts.dayStartHour, region = db._opts.region },
    c = {},
  }
  local ids = {}
  for _, id in ipairs(spec.counters) do ids[#ids + 1] = id end
  -- carry wall/active time so imported rate queries work
  ids[#ids + 1] = "@wall"
  ids[#ids + 1] = "@active"
  local scrubIds, nextScrub = {}, 0
  for _, id in ipairs(ids) do
    local rc = db._counters[id]
    if rc then
      local nd = rc.def
      local entry = { id = id, def = R.canonical(nd), dm = {}, tk = {}, e = {} }
      for i, labels in ipairs(rc.saved.dm) do
        local out = {}
        for j, l in ipairs(labels) do
          if scrub and nd.dims[i] and nd.dims[i].private then out[j] = "#" .. j else out[j] = l end
        end
        entry.dm[i] = out
      end
      for tid = 1, rc.ntup do entry.tk[tid] = rc.saved.tk[tid] end
      local keys
      local which = spec.entity or "current"
      if rc.scopeAccount then keys = { "@account" }
      elseif which == "current" then keys = { db._entity }
      elseif which == "account" then
        keys = {}
        for k in pairs(rc.saved.e) do if k ~= "@account" then keys[#keys + 1] = k end end
        sort(keys)
      else keys = { which } end
      for _, key in ipairs(keys) do
        if rc.saved.e[key] then
          local g = {}
          local any = false
          for _, gname in ipairs(grains) do
            local gid = Cal.GRAIN_ID[gname]
            if nd.gset[gid] then
              local from, to = -1e9, 1e9
              if spec.range and Cal.CALENDAR_GRAINS[gid] then
                from = db:PeriodKey(gname, spec.range.from)
                to = db:PeriodKey(gname, spec.range.to)
              end
              local periods = collectPeriods(db, rc, key, gid, from, to)
              if #periods > 0 then
                g[gname] = P.encode(gid, rc.colsByGrain[gid], periods)
                any = true
              end
            end
          end
          if any then
            local eid, info = key, nil
            if scrub then
              if not scrubIds[key] then nextScrub = nextScrub + 1; scrubIds[key] = "E" .. nextScrub end
              eid = scrubIds[key]
            else
              local rec = G.ents[key]
              if type(rec) == "table" then info = { n = rec.n, r = rec.r, c = rec.c, f = rec.f } end
            end
            entry.e[#entry.e + 1] = { id = eid, info = info, g = g }
          end
        end
      end
      body.c[#body.c + 1] = entry
    end
  end
  local str = X.wrap(db, body)
  local limit = spec.maxBytes or 1000000
  if #str > limit then
    return nil, format("export is %d bytes, over the limit of %d; narrow the scope (fewer counters or grains, or a shorter range)", #str, limit)
  end
  return str
end

---------------------------------------------------------------------------
-- Validator (whitelist)
---------------------------------------------------------------------------
local function vfail(fmt, ...) error({ v = format(fmt, ...) }, 0) end

local function checkKeys(t, allowed, where)
  if type(t) ~= "table" then vfail("%s must be a table", where) end
  for k in pairs(t) do
    if not allowed[k] then vfail("unexpected field '%s' in %s", tostring(k), where) end
  end
end

local function isLabel(v)
  local tv = type(v)
  if tv == "string" then return #v <= 64 end
  return tv == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local BODY_KEYS = { fmt = true, lib = true, schema = true, at = true, label = true, scrub = true, cal = true, c = true }
local CAL_KEYS = { cal = true, dsh = true, region = true }
local ENTRY_KEYS = { id = true, def = true, dm = true, tk = true, e = true }
local ENT_KEYS = { id = true, info = true, g = true }
local INFO_KEYS = { n = true, r = true, c = true, f = true }

local function validateBody(body)
  checkKeys(body, BODY_KEYS, "the body")
  if body.fmt ~= 1 then vfail("unsupported body format") end
  if not U.isInteger(body.lib) or not U.isInteger(body.schema) or not U.isInteger(body.at) then vfail("bad header numbers") end
  if body.schema > M.SCHEMA then vfail("written by a newer LibGranaryDB (schema %d); update the addon", body.schema) end
  if type(body.label) ~= "string" or #body.label > 64 then vfail("bad label") end
  if type(body.scrub) ~= "boolean" then vfail("bad scrub flag") end
  if body.cal ~= nil then
    checkKeys(body.cal, CAL_KEYS, "cal")
    if body.cal.cal ~= nil and body.cal.cal ~= "local" and body.cal.cal ~= "utc" then vfail("bad calendar") end
    if body.cal.dsh ~= nil and (not U.isInteger(body.cal.dsh) or body.cal.dsh < 0 or body.cal.dsh > 23) then vfail("bad day start") end
    if body.cal.region ~= nil and body.cal.region ~= "EU" and body.cal.region ~= "US" then vfail("bad region") end
  end
  local c = body.c
  if type(c) ~= "table" or not U.isArray(c) or #c > X.MAX_COUNTERS + 2 then vfail("bad counter list") end
  local out = {}
  for ci, entry in ipairs(c) do
    checkKeys(entry, ENTRY_KEYS, "counter " .. ci)
    local internal = entry.id == "@wall" or entry.id == "@active"
    if type(entry.id) ~= "string" then vfail("counter %d has no id", ci) end
    local nd, err = R.validate(entry.def, internal)
    if not nd then vfail("counter %d definition: %s", ci, err) end
    if nd.id ~= entry.id then vfail("counter %d id mismatch", ci) end
    if internal and (nd.kind ~= "flow" or #nd.dims ~= 0) then vfail("bad internal counter") end
    -- labels
    if type(entry.dm) ~= "table" or not U.isArray(entry.dm) or #entry.dm > #nd.dims then vfail("counter %d: bad labels", ci) end
    for di, labels in ipairs(entry.dm) do
      if type(labels) ~= "table" or not U.isArray(labels) or #labels > R.MAX_CAP then vfail("counter %d: bad labels for dimension %d", ci, di) end
      for _, l in ipairs(labels) do if not isLabel(l) then vfail("counter %d: bad label", ci) end end
    end
    -- tuples
    if type(entry.tk) ~= "table" or not U.isArray(entry.tk) or #entry.tk > R.MAX_TUPLES + R.MAX_SETS then vfail("counter %d: bad tuple list", ci) end
    local tupleSet, tupleMembers = {}, {}
    for tid, tkey in ipairs(entry.tk) do
      local setKey, parts = M.Store.parseTupleKey(tkey)
      if not setKey then vfail("counter %d: bad tuple %d", ci, tid) end
      local si = nd.setByKey[setKey]
      if si then
        local set = nd.sets[si]
        if #parts ~= set.n then vfail("counter %d: tuple %d has the wrong arity", ci, tid) end
        for k = 1, set.n do
          local id = parts[k]
          local labels = entry.dm[set[k]] or {}
          if id ~= 0 and id ~= -1 and (id < 1 or id > #labels) then vfail("counter %d: tuple %d names an unknown member", ci, tid) end
        end
        tupleSet[tid] = si
      end
      tupleMembers[tid] = parts
    end
    -- entities
    if type(entry.e) ~= "table" or not U.isArray(entry.e) or #entry.e > X.MAX_ENTITIES then vfail("counter %d: bad entity list", ci) end
    local ents = {}
    local allowedCols = {}
    for _, col in ipairs(nd.cols) do allowedCols[col] = true end
    local maxKeys = {}
    for ei, ent in ipairs(entry.e) do
      checkKeys(ent, ENT_KEYS, "entity " .. ei)
      if type(ent.id) ~= "string" or #ent.id > 64 or ent.id == "" then vfail("counter %d: bad entity id", ci) end
      if ents[ent.id] then vfail("counter %d: duplicate entity", ci) end
      if ent.info ~= nil then
        checkKeys(ent.info, INFO_KEYS, "entity info")
        for _, v in pairs(ent.info) do if type(v) ~= "string" or #v > 48 then vfail("bad entity info") end end
      end
      checkKeys(ent.g, Cal.GRAIN_ID, "entity grains")
      local grains = {}
      for gname, text in pairs(ent.g) do
        local gid = Cal.GRAIN_ID[gname]
        if not nd.gset[gid] then vfail("counter %d: grain '%s' not declared", ci, gname) end
        if type(text) ~= "string" then vfail("counter %d: chunk is not text", ci) end
        local parsed, perr = P.parse(text, { maxTid = #entry.tk, allowedCols = allowedCols, strict = true })
        if not parsed then vfail("counter %d: %s", ci, perr) end
        if parsed.g ~= gid then vfail("counter %d: chunk grain mismatch", ci) end
        grains[gid] = parsed
        local last = parsed.periods[#parsed.periods]
        if last and (not maxKeys[gid] or last.k > maxKeys[gid]) then maxKeys[gid] = last.k end
      end
      ents[ent.id] = { info = ent.info, g = grains }
    end
    out[entry.id] = { def = nd, labels = entry.dm, tupleSet = tupleSet, tupleMembers = tupleMembers, ntup = #entry.tk,
      ents = ents, maxKeys = maxKeys }
  end
  return out
end

--- Fully decode and validate an export string. Returns { body, counters } or nil, err. Never raises.
function X.decode(db, str)
  local ok, res, err = pcall(function()
    local raw, uerr = X.unwrap(db, str)
    if not raw then return nil, uerr end
    local body, derr = M.Codec.cborDecode(raw, X.LIMITS) -- always the pure decoder, with limits
    if body == nil then return nil, "corrupt: " .. tostring(derr) end
    local vok, counters = pcall(validateBody, body)
    if not vok then
      if type(counters) == "table" and counters.v then return nil, "rejected: " .. counters.v end
      return nil, "rejected: " .. tostring(counters)
    end
    return { body = body, counters = counters }
  end)
  if not ok then return nil, "rejected: " .. tostring(res) end
  return res, err
end

---------------------------------------------------------------------------
-- Import and imported datasets
---------------------------------------------------------------------------
function X.import(db, str, opts)
  if db._ro then return nil, "database is read-only" end
  local dec, err = X.decode(db, str)
  if not dec then return nil, err end
  local G = db._G
  G.imp = G.imp or {}
  local n = 1
  while G.imp["imp" .. n] do n = n + 1 end
  local id = "imp" .. n
  local label = (type(opts) == "table" and type(opts.label) == "string" and opts.label:sub(1, 64)) or dec.body.label or ""
  G.imp[id] = { l = label, a = db._now(), n = #str, s = str }
  db._impCache[id] = dec
  return id
end

local function loadImport(db, id)
  local cached = db._impCache[id]
  if cached then return cached end
  local rec = db._G.imp and db._G.imp[id]
  if not rec then return nil, format("unknown dataset '%s'", tostring(id)) end
  local dec, err = X.decode(db, rec.s)
  if not dec then return nil, "stored dataset is unreadable: " .. tostring(err) end
  -- keep at most 2 decoded imports in memory
  local n = 0
  for _ in pairs(db._impCache) do n = n + 1 end
  if n >= 2 then db._impCache = {} end
  db._impCache[id] = dec
  return dec
end

function X.source(db, datasetId, counterId)
  local dec, err = loadImport(db, datasetId)
  if not dec then return nil, err end
  local c = dec.counters[counterId]
  if not c then return nil, format("dataset '%s' has no counter '%s'", datasetId, tostring(counterId)) end
  local src = {
    kind = "import", id = counterId, def = c.def, labels = c.labels, tupleSet = c.tupleSet,
    tupleMembers = c.tupleMembers, ntup = c.ntup, gen = 0,
  }
  function src.entities()
    local ks = {}
    for k in pairs(c.ents) do ks[#ks + 1] = k end
    sort(ks)
    return ks
  end
  function src.current() return nil end
  function src.curKey(gid)
    if gid == Cal.LIFETIME then return 0 end
    return c.maxKeys[gid]
  end
  function src.visit(ekey, gid, from, to, fn, cp)
    local ent = c.ents[ekey]
    local parsed = ent and ent.g[gid]
    if not parsed then return end
    for _, p in ipairs(parsed.periods) do
      if p.k >= from and p.k <= to then
        fn(p, true) -- imported data is immutable: fn may checkpoint mid-period
        if cp then cp() end
      end
    end
  end
  function src.sibling(id)
    if dec.counters[id] then return X.source(db, datasetId, id) end
  end
  return src
end

function X.datasets(db)
  local out = {}
  for id, rec in pairs(db._G.imp or {}) do
    local counters = {}
    local dec = db._impCache[id]
    if dec then
      for cid in pairs(dec.counters) do
        if cid ~= "@wall" and cid ~= "@active" then counters[#counters + 1] = cid end
      end
      sort(counters)
    end
    out[#out + 1] = { id = id, label = rec.l, at = rec.a, bytes = rec.n, counters = counters }
  end
  sort(out, function(a, b) return a.id < b.id end)
  return out
end

function X.remove(db, id)
  local G = db._G
  if db._ro or not G.imp or not G.imp[id] then return false end
  G.imp[id] = nil
  db._impCache[id] = nil
  return true
end
