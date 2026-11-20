-- API: the public surface of LibGranaryDB-1.0, with LuaLS annotations. These annotations are the
-- single source of truth for signatures (docs/API.md and docs/SPEC.md §2 describe behaviour).
-- Public functions never tail-call into internals, so `error(msg, 2)` points at the host's line.
local lib = LibStub and LibStub("LibGranaryDB-1.0", true)
local M = lib and lib.__M
if not M then return end

local type, pairs, ipairs, tostring, setmetatable, pcall = type, pairs, ipairs, tostring, setmetatable, pcall
local format = string.format

local U, S, Q, X, D, Cal, P = M.U, M.Store, M.Query, M.Exchange, M.Diag, M.Cal, M.Pack
local misuse = U.misuse

---@class GranaryDB.Lib
---@field MAJOR string "LibGranaryDB-1.0"
---@field MINOR integer library release number (only the newest embedded copy runs)
---@field API_VERSION integer bumped when the API gains features; probe with Supports() for specifics
---@field SCHEMA integer saved-data schema this copy writes
---@field RateWindow GranaryDB.RateWindowClass

---@class GranaryDB.AttachOptions
---@field host string your addon's name (required; shown in reports)
---@field adapters? GranaryDB.Adapters overrides for clock, calendar, serializer, compressor, encoder, scheduler, callbacks, secret, logger, errors, env
---@field calendar? "local"|"utc" default "local"
---@field dayStartHour? integer 0..23, gaming-day offset (default 0)
---@field region? "EU"|"US" weekly reset anchor for the resetweek grain (default "EU")
---@field maxEntries? integer root budget in estimated saved entries (default 60000)
---@field maxBytes? integer root budget in estimated bytes (default 4000000)
---@field autoMaintenance? boolean schedule sliced maintenance through the scheduler (default true)
---@field maintenanceInterval? number seconds between passes (default 300)
---@field sliceMs? number work budget per frame slice (default 2)
---@field tickGap? number Tick gaps longer than this many seconds aren't counted as time (default 30)

---@class GranaryDB.Adapters
---@field clock? {now: fun(): integer, preciseMs: fun(): number}
---@field calendar? {fields: fun(t: integer, utc: boolean): integer, integer, integer, integer, integer, integer, resetAnchor: fun(region: string): integer}
---@field serializer? {encode: fun(v: any): string, decode: fun(s: string): any, string?}
---@field compressor? {name: string, compress: fun(s: string): string, decompress: fun(s: string): string?}
---@field encoder? {encode: fun(s: string): string, decode: fun(s: string): string?}
---@field scheduler? {after: fun(seconds: number, fn: function)}
---@field callbacks? {Fire: fun(event: string, ...: any)}
---@field secret? {isSecret: fun(v: any): boolean}
---@field logger? {log: fun(level: string, msg: string)}
---@field errors? {handle: fun(err: any)}
---@field env? {gameVersion: fun(): string}

---@class GranaryDB.Dimension
---@field name string
---@field cap? integer 1..4096 (1..1024 before API_VERSION 2), members beyond it go to "other" (default 32)
---@field private? boolean scrub members on export with scrub = true

---@class GranaryDB.CounterDef
---@field id string namespaced "addon:name"
---@field version integer >= 1; bump it with onIncompatible = "reset" for incompatible changes
---@field kind? "flow"|"stock" default "flow"
---@field unit? string free text
---@field measures? string[] flow: sum count min max first last; stock: last min max twa first
---@field dimensions? GranaryDB.Dimension[] ordered; Add/Observe take members in this order
---@field aggregations? string[][] materialized dimension sets; {} (grand total) is always added
---@field grains? string[] hour day week resetweek month year version phase lifetime
---@field retention? table<string, string|integer> hour/day/week/resetweek: "48h", "400d", "2y" or a period count
---@field context? {min?: string[], max?: string[]} context fields kept with extremes
---@field contextGrains? string[] grains that keep context (default { "day", "lifetime" })
---@field scope? "character"|"account"
---@field maxGap? number stocks: cap on the time one observation is weighted for twa
---@field budget? {entries?: integer, bytes?: integer}
---@field onIncompatible? "error"|"reset"
---@field removed? "drop"|"keep" data of grains and sets no longer declared: deleted (default) or frozen and resumable (r3)

---@class GranaryDB.DropOptions
---@field entity? string drop only this entity's data (a deleted alt); "account" is not a key
---@field grains? string[] drop only these grains (e.g. { "hour", "day" })

---@class GranaryDB.Query
---@field counter string
---@field measure? "sum"|"count"|"min"|"max"|"first"|"last"|"twa"|"avg"|"rate"|"rate_active"|"share"|"change"
---@field entity? string|string[] nil = current character, "account", a key, or a list of keys
---@field grain? string default "lifetime" if declared
---@field range? {from: integer, to: integer} inclusive period keys
---@field last? integer the last N periods including the current one
---@field groupBy? string|string[]
---@field filter? table<string, string|number>
---@field top? integer
---@field order? "desc"|"asc"|"label"
---@field dataset? string "local" or an import id
---@field gaps? "zero"|"carry"|"nil" (Series only)
---@field base? string stored measure used by share/change (default sum, or last for stocks)

---@class GranaryDB.Row
---@field key string group key (member ids)
---@field label string the member as text ("other", "none", "total", "a / b" for several dimensions)
---@field member? string|number the stored member, numbers as numbers (r4; one-dimension rows of a real member only)
---@field value number
---@field ctx? table context of the extreme: { t = epoch, <field> = value }
---@field share? number
---@field prev? number
---@field delta? number
---@field pct? number

---@class GranaryDB.Rows: GranaryDB.Row[]
---@field total number? value for the whole selection
---@field measure string
---@field grain string
---@field from integer?
---@field to integer?

---@class GranaryDB.Series
---@field keys integer[]
---@field values (number|nil)[]
---@field ctx? table[]

---@class GranaryDB.ExportSpec
---@field counters string[] required, non-empty
---@field entity? string "current" (default), "account" or a key
---@field grains? string[] default { "day", "month", "lifetime" }
---@field range? {from: integer, to: integer} epoch seconds (calendar grains only)
---@field scrub? boolean replace character ids and private members
---@field label? string
---@field maxBytes? integer default 1000000

---@class GranaryDB.DB
---@class GranaryDB.Handle

local DB = {}
local Handle = {}
M.DB, M.Handle = DB, Handle

local EVENTS = { OnNewExtreme = true, OnBucketClosed = true, OnRollup = true, OnCompaction = true, OnBudget = true,
  OnMigration = true, OnSecretRejected = true, OnDrop = true }
M.EVENTS = EVENTS

local FEATURES = { flow = true, stock = true, context = true, export = true, import = true, resetweek = true,
  account = true, async = true, ratewindow = true, budgets = true, drop = true, keepRemoved = true, members = true,
  hist = false, journal = false, segments = false }

local OPTION_DEFAULTS = {
  calendar = "local", dayStartHour = 0, region = "EU", maxEntries = 60000, maxBytes = 4000000,
  autoMaintenance = true, maintenanceInterval = 300, sliceMs = 2, tickGap = 30,
}

---------------------------------------------------------------------------
-- Library object
---------------------------------------------------------------------------

local function freshHeader(now)
  return {
    schema = M.SCHEMA, minReader = 1, libMinor = M.MINOR, created = now, hosts = {},
    dict = { v = {}, p = {} }, ents = {}, c = {}, imp = {}, meta = { stats = {}, warn = {} },
  }
end

local function ensureStructure(G)
  G.hosts = type(G.hosts) == "table" and G.hosts or {}
  G.dict = type(G.dict) == "table" and G.dict or {}
  G.dict.v = type(G.dict.v) == "table" and G.dict.v or {}
  G.dict.p = type(G.dict.p) == "table" and G.dict.p or {}
  G.ents = type(G.ents) == "table" and G.ents or {}
  G.c = type(G.c) == "table" and G.c or {}
  G.imp = type(G.imp) == "table" and G.imp or {}
  G.meta = type(G.meta) == "table" and G.meta or {}
  G.meta.stats = type(G.meta.stats) == "table" and G.meta.stats or {}
  G.meta.warn = type(G.meta.warn) == "table" and G.meta.warn or {}
end

local function newHandle(db, rc)
  return setmetatable({ db = db, rc = rc, ce = nil, ceEpoch = -1 }, lib.__handleMeta)
end

local function lookupId(list, label)
  for i, l in ipairs(list) do if l == label then return i end end
end

--- Attach the host's SavedVariables root. Call it at your ADDON_LOADED.
---@param root table your addon's SavedVariables table (the library keeps everything under root.__granary)
---@param opts GranaryDB.AttachOptions
---@return GranaryDB.DB db
function lib:Attach(root, opts)
  if type(root) ~= "table" then misuse(2, "Attach(root, opts): root must be your SavedVariables table, got %s", type(root)) end
  if type(opts) ~= "table" or type(opts.host) ~= "string" or opts.host == "" then
    misuse(2, "Attach(root, opts): opts.host (your addon's name) is required")
  end
  for _, other in ipairs(lib.__dbs) do
    if other._root == root and not other._detached then misuse(2, "Attach: this root is already attached by '%s'", other._host) end
  end
  local o = {}
  for k, v in pairs(OPTION_DEFAULTS) do o[k] = v end
  for k, v in pairs(opts) do
    if k ~= "host" and k ~= "adapters" then
      if OPTION_DEFAULTS[k] == nil then misuse(2, "Attach: unknown option '%s'", tostring(k)) end
      if type(v) ~= type(OPTION_DEFAULTS[k]) then misuse(2, "Attach: option '%s' must be a %s", k, type(OPTION_DEFAULTS[k])) end
      o[k] = v
    end
  end
  if o.calendar ~= "local" and o.calendar ~= "utc" then misuse(2, "Attach: calendar must be \"local\" or \"utc\"") end
  if o.dayStartHour < 0 or o.dayStartHour > 23 or o.dayStartHour ~= math.floor(o.dayStartHour) then
    misuse(2, "Attach: dayStartHour must be an integer 0..23")
  end
  if o.region ~= "EU" and o.region ~= "US" then misuse(2, "Attach: region must be \"EU\" or \"US\"") end
  local ad, aerr = M.Adapters.resolve(opts.adapters)
  if not ad then misuse(2, "Attach: %s", aerr) end

  local db = setmetatable({}, lib.__dbMeta)
  db._root, db._host, db._ad, db._opts = root, opts.host, ad, o
  db._now = ad.clock.now
  db._isSecret = ad.secret.isSecret
  db._cb = ad.callbacks or M.Adapters.newRegistry(function(err) pcall(ad.errors.handle, err) end)
  db._ownRegistry = ad.callbacks == nil
  local now = db._now()

  -- header, schema, migrations, read-only
  local G = root.__granary
  local ro, noRead, reason = false, false, nil
  if G == nil then
    G = freshHeader(now)
    root.__granary = G
  elseif type(G) ~= "table" or not U.isInteger(G.schema) or G.schema < 1 then
    reason = U.internalMessage("saved data header is corrupt; left untouched")
    ro, noRead = true, true
    G = freshHeader(now) -- scratch copy, not attached to the root
  elseif G.schema > M.SCHEMA then
    ro = true
    reason = format("saved data was written by a newer LibGranaryDB (schema %d; this copy understands %d); "
      .. "read-only until the newer addon is enabled again", G.schema, M.SCHEMA)
    if (G.minReader or G.schema) > M.SCHEMA then noRead = true end
  elseif G.schema < M.SCHEMA then
    local from = G.schema
    local ok, rep = M.Migrations.run(db, G, M.SCHEMA)
    if not ok then
      reason = U.internalMessage(rep)
      ro, noRead = true, true
    else
      db._migrated = rep
      G.meta = type(G.meta) == "table" and G.meta or {}
      G.meta.stats = type(G.meta.stats) == "table" and G.meta.stats or {}
      G.meta.stats.migrations = (G.meta.stats.migrations or 0) + 1
      db._migratedFrom = from
    end
  end
  if not ro then ensureStructure(G) end
  db._G = G
  db._ro, db._noRead, db._roReason = ro, noRead, reason
  db._stats = (not ro and G.meta.stats) or {}
  if ro then
    G = setmetatable({}, { __index = G }) -- reads fall through; nothing is written to the root
    G.meta = { stats = db._stats, warn = {} }
    G.dict = { v = type(db._G.dict) == "table" and db._G.dict.v or {}, p = type(db._G.dict) == "table" and db._G.dict.p or {} }
    G.c = type(db._G.c) == "table" and db._G.c or {}
    G.ents = type(db._G.ents) == "table" and db._G.ents or {}
    G.imp = type(db._G.imp) == "table" and db._G.imp or {}
    db._G = G
  end
  if reason then U.warn(db, reason) end
  if not ro then G.hosts[opts.host] = now end

  -- runtime state
  db._cfg = { fields = ad.calendar.fields, utc = o.calendar == "utc", dsh = o.dayStartHour,
    anchor = ad.calendar.resetAnchor(o.region) }
  db._keys, db._tmpKeys, db._lateKeys, db._bstart = {}, {}, {}, {}
  db._keyEpoch, db._cacheStart, db._cacheEnd = 1, math.huge, -math.huge
  db._vIdx, db._pIdx = {}, {}
  for i, l in ipairs(db._G.dict.v) do db._vIdx[l] = i end
  for i, l in ipairs(db._G.dict.p) do db._pIdx[l] = i end
  local version = tostring(ad.env.gameVersion() or "?")
  if ro then
    db._keys[Cal.VERSION] = lookupId(db._G.dict.v, version) or (#db._G.dict.v + 1)
    db._keys[Cal.PHASE] = lookupId(db._G.dict.p, "") or (#db._G.dict.p + 1)
  else
    db._keys[Cal.VERSION] = S.intern(G.dict.v, db._vIdx, version)
    db._keys[Cal.PHASE] = S.intern(G.dict.p, db._pIdx, "")
  end
  db._keys[Cal.LIFETIME] = 0
  S.advanceKeys(db, now)
  db._entity, db._entityEpoch = "@local", 1
  db._counters, db._handles, db._closedQ = {}, {}, {}
  db._flushFn = function() S.flush(db) end
  db._lru, db._qcache, db._impCache = P.newLRU(32), {}, {}
  db._sessionStart = now
  db._active = false

  -- wall/active time counters on every grain
  local all = {}
  for i, g in ipairs(Cal.GRAINS) do all[i] = g end
  for _, id in ipairs({ "@wall", "@active" }) do
    local def = { id = id, version = 1, kind = "flow", unit = "seconds", measures = { "sum" }, grains = all }
    local rc
    if ro then rc = M.API.registerReadOnly(db, def, true) else rc = S.register(db, def, true) end
    db._handles[id] = newHandle(db, rc)
  end
  db._wallH, db._activeH = db._handles["@wall"], db._handles["@active"]

  lib.__dbs[#lib.__dbs + 1] = db
  if db._migrated then S.fire(db, "OnMigration", db._migratedFrom, M.SCHEMA, db._migrated) end
  if o.autoMaintenance and not ro then M.Maint.schedule(db, 15) end
  return db
end

--- Capability probe, e.g. Supports("hist") (false in v1), Supports("resetweek").
---@param feature string
---@return boolean
function lib:Supports(feature)
  return FEATURES[feature] == true
end

--- Diagnostics for every attached host.
---@return table
function lib:Stats()
  local r = D.libStats()
  return r
end

--- A LibGranaryDB-only report string for bug reports: !GranaryDBReport:1!...!End:GranaryDBReport:1!
--- Contains versions, hosts, size/health counters and recent internal warnings; no character names.
---@return string
function lib:BuildReport()
  local live = {}
  for _, db in ipairs(lib.__dbs) do if not db._detached then live[#live + 1] = db end end
  local now = live[1] and live[1]._now() or 0
  local s = D.buildReport(live, now)
  return s
end

--- Decode a report string built by BuildReport.
---@param str string
---@return table|nil report, string? err
function lib:ParseReport(str)
  local r, err = D.parseReport(str)
  return r, err
end

--- Quick self-checks against the active adapters (the real WoW ones in game).
---@param opts? {adapters?: GranaryDB.Adapters, region?: string}
---@return boolean ok, table results  results[i] = { name, ok, msg }
function lib:SelfTest(opts)
  local ok, res = D.selfTest(opts)
  return ok, res
end

--- A short benchmark on a temporary in-memory root.
---@param opts? {writes?: integer, adapters?: GranaryDB.Adapters}
---@return table timings
function lib:Bench(opts)
  local r = D.bench(opts)
  return r
end

---@class GranaryDB.RateWindowClass
---@field New fun(self: GranaryDB.RateWindowClass, opts?: {slots?: integer, slotSeconds?: number, now?: fun(): number}): GranaryDB.RateWindow
---@class GranaryDB.RateWindow
---@field Add fun(self: GranaryDB.RateWindow, v: number, t?: number): boolean
---@field SetActive fun(self: GranaryDB.RateWindow, on: boolean, t?: number)
---@field Rate fun(self: GranaryDB.RateWindow, window?: number, t?: number, activeOnly?: boolean): number, number, number
lib.RateWindow = M.RateWindow

---------------------------------------------------------------------------
-- Database object
---------------------------------------------------------------------------

M.API = {}
--- Read-only registration: builds the runtime without writing to saved data.
function M.API.registerReadOnly(db, def, internal)
  local nd, err = M.Registry.validate(def, internal)
  if not nd then return nil, err end
  local saved = db._G.c[nd.id]
  if type(saved) ~= "table" then saved = { dm = {}, tk = {}, e = {} } end
  local view = setmetatable({ dm = saved.dm or {}, tk = saved.tk or {}, e = saved.e or {} }, { __index = saved })
  local rc = S.buildRuntime(db, nd, view, internal)
  db._counters[nd.id] = rc
  return rc
end

--- Declare a counter (data-only definition). Re-registering with compatible changes is fine.
---@param def GranaryDB.CounterDef
---@return string id
function DB:RegisterCounter(def)
  if type(def) ~= "table" then misuse(2, "RegisterCounter(def): def must be a table") end
  local rc, err
  if self._ro then rc, err = M.API.registerReadOnly(self, def, false)
  else rc, err = S.register(self, def, false) end
  if not rc then misuse(2, "%s", err) end
  return rc.id
end

--- Delete the saved data of a counter in this root: the only call that deletes data (r3). Every entity, grain,
--- packed and parked chunk, interned member and tuple, and budget state; or only opts.entity, or only opts.grains.
--- No tombstone: the id can be registered again and starts empty. On a counter registered this session it resets in
--- place (the definition and handles stay valid; writes continue from zero). Imported datasets are untouched.
---@param id string
---@param opts? GranaryDB.DropOptions
---@return integer|false bytesFreed estimated bytes freed, or false when there was nothing to drop
---@return string? err read-only
function DB:DropCounter(id, opts)
  if type(id) ~= "string" or id == "" then misuse(2, "DropCounter(id, opts): id must be a counter id") end
  if id:sub(1, 1) == "@" then misuse(2, "DropCounter: '%s' is the library's own counter", id) end
  if opts ~= nil and type(opts) ~= "table" then misuse(2, "DropCounter(id, opts): opts must be a table") end
  local entity, grains
  if opts then
    if opts.entity ~= nil and (type(opts.entity) ~= "string" or opts.entity == "") then
      misuse(2, "DropCounter: opts.entity must be an entity key")
    end
    entity = opts.entity
    if opts.grains ~= nil then
      if type(opts.grains) ~= "table" or #opts.grains == 0 then misuse(2, "DropCounter: opts.grains must be a non-empty array") end
      grains = {}
      for _, g in ipairs(opts.grains) do
        local gid = Cal.GRAIN_ID[g]
        if not gid then misuse(2, "DropCounter: unknown grain '%s'", tostring(g)) end
        grains[gid] = true
      end
    end
  end
  if self._ro then return false, self._roReason end
  local freed = M.Maint.drop(self, id, entity, grains)
  if freed then
    local copy
    if opts then copy = { entity = opts.entity, grains = opts.grains and U.copy(opts.grains) or nil } end
    S.fire(self, "OnDrop", id, copy)
  end
  return freed
end

--- A dimension's members as stored, in the order first seen (member id = index), numbers as numbers (r4). Works
--- for any counter with saved data in this root, registered this session or frozen; a copy, safe to change.
--- Members past the cap aren't listed: their writes go to "other". Retired members are listed (they keep data).
---@param id string
---@param dim string dimension name
---@return (string|number)[]|nil members
---@return string? err unknown counter or dimension
function DB:Members(id, dim)
  if type(id) ~= "string" or id == "" then misuse(2, "Members(id, dim): id must be a counter id") end
  if type(dim) ~= "string" then misuse(2, "Members(id, dim): dim must be a dimension name") end
  local rc = self._counters[id]
  local saved = rc and rc.saved or self._G.c[id]
  if type(saved) ~= "table" then return nil, format("unknown counter '%s' (nothing saved in this root)", id) end
  local def = rc and rc.def
  if not def and type(saved.def) == "table" and type(saved.def.d) == "table" then
    def = M.Registry.validate(saved.def.d, id:sub(1, 1) == "@")
  end
  local di = def and def.dimIndex[dim]
  if not di then return nil, format("'%s' has no dimension '%s'", id, dim) end
  local out, labels = {}, type(saved.dm) == "table" and saved.dm[di]
  if type(labels) == "table" then for i = 1, #labels do out[i] = labels[i] end end
  return out
end

--- Resolve a counter once and keep the handle; writes go through it.
---@param id string
---@return GranaryDB.Handle
function DB:Handle(id)
  local h = self._handles[id]
  if h then return h end
  local rc = self._counters[id]
  if not rc then misuse(2, "Handle('%s'): unknown counter; call RegisterCounter first", tostring(id)) end
  h = newHandle(self, rc)
  self._handles[id] = h
  return h
end

--- Set whose data is written: normally UnitGUID("player"), plus a display snapshot.
---@param key string
---@param info? {name?: string, realm?: string, class?: string, faction?: string}
function DB:SetEntity(key, info)
  if type(key) ~= "string" or key == "" or #key > 64 then misuse(2, "SetEntity(key): key must be a non-empty string (at most 64 characters)") end
  if info ~= nil and type(info) ~= "table" then misuse(2, "SetEntity(key, info): info must be a table") end
  if self._ro then
    self._entity, self._entityEpoch = key, self._entityEpoch + 1
    return
  end
  S.setEntity(self, key, info)
end

--- Tell the library whether the player is "active" (not AFK/idle); feeds rate_active.
---@param on boolean
function DB:SetActive(on)
  S.tick(self)
  self._active = on and true or false
end

--- Set the content-phase label for the phase grain (e.g. "1.60.1-raids-dec9").
---@param label string
function DB:SetPhase(label)
  if type(label) ~= "string" or #label > 64 then misuse(2, "SetPhase(label): label must be a string of at most 64 characters") end
  if self._ro then return end
  S.setPhase(self, label)
end

--- Host clock tick (every 1-5 s): wall/active time and period rollover while idle.
---@param now? integer epoch seconds (default: the clock adapter)
function DB:Tick(now)
  if now ~= nil and type(now) ~= "number" then misuse(2, "Tick(now): now must be epoch seconds") end
  S.tick(self, now)
end

local function freshKeys(db)
  local now = db._now()
  if now >= db._cacheEnd or now < db._cacheStart then S.advanceKeys(db, now) end
end

--- Aggregate rows. Planner refusals return nil plus an explanation.
---@param q GranaryDB.Query
---@return GranaryDB.Rows|nil rows, string? err
function DB:Query(q)
  local err = Q.check(q, false)
  if err then misuse(2, "Query: %s", err) end
  if self._noRead then return nil, self._roReason end
  freshKeys(self)
  local rows, e = Q.run(self, q)
  return rows, e
end

--- Aligned time series for one selection.
---@param q GranaryDB.Query
---@return GranaryDB.Series|nil series, string? err
function DB:Series(q)
  local err = Q.check(q, true)
  if err then misuse(2, "Series: %s", err) end
  if self._noRead then return nil, self._roReason end
  freshKeys(self)
  local r, e = Q.series(self, q)
  return r, e
end

--- Query sliced over frames; cb(rows, err) runs later.
---@param q GranaryDB.Query
---@param cb fun(rows: GranaryDB.Rows|nil, err: string?)
---@return {Cancel: fun()} job
function DB:QueryAsync(q, cb)
  local err = Q.check(q, false)
  if err then misuse(2, "QueryAsync: %s", err) end
  if type(cb) ~= "function" then misuse(2, "QueryAsync(q, cb): cb must be a function") end
  freshKeys(self)
  if self._noRead then
    local reason = self._roReason
    self._ad.scheduler.after(0, function() cb(nil, reason) end)
    return { Cancel = function() end }
  end
  local job = Q.async(self, Q.run, q, cb)
  return job
end

--- Series sliced over frames; cb(series, err) runs later.
---@param q GranaryDB.Query
---@param cb fun(series: GranaryDB.Series|nil, err: string?)
---@return {Cancel: fun()} job
function DB:SeriesAsync(q, cb)
  local err = Q.check(q, true)
  if err then misuse(2, "SeriesAsync: %s", err) end
  if type(cb) ~= "function" then misuse(2, "SeriesAsync(q, cb): cb must be a function") end
  freshKeys(self)
  local job = Q.async(self, Q.series, q, cb)
  return job
end

--- The period key of `grain` that contains epoch `t` (default now).
---@param grain string
---@param t? integer
---@return integer
function DB:PeriodKey(grain, t)
  local gid = Cal.GRAIN_ID[grain]
  if not gid then misuse(2, "PeriodKey: unknown grain '%s'", tostring(grain)) end
  if t ~= nil and type(t) ~= "number" then misuse(2, "PeriodKey: t must be epoch seconds") end
  if gid <= 6 then
    local tmp = {}
    Cal.compute(self._cfg, t or self._now(), tmp)
    return tmp[gid]
  end
  if gid == Cal.LIFETIME then return 0 end
  return self._keys[gid]
end

--- Human-readable fields for a period key: y, m, d, h; start (resetweek); label (version/phase).
---@param grain string
---@param key integer
---@return table
function DB:PeriodInfo(grain, key)
  local gid = Cal.GRAIN_ID[grain]
  if not gid then misuse(2, "PeriodInfo: unknown grain '%s'", tostring(grain)) end
  if type(key) ~= "number" then misuse(2, "PeriodInfo: key must be a number") end
  local r = Cal.info(gid, key, self._cfg.anchor)
  if gid == Cal.VERSION then r.label = self._G.dict.v[key] end
  if gid == Cal.PHASE then r.label = self._G.dict.p[key] end
  return r
end

--- Build a scoped export string (never "everything").
---@param spec GranaryDB.ExportSpec
---@return string|nil str, string? err
function DB:Export(spec)
  local err = X.checkSpec(self, spec)
  if err then misuse(2, "Export: %s", err) end
  if self._noRead then return nil, self._roReason end
  freshKeys(self)
  local s, e = X.export(self, spec)
  return s, e
end

--- Import an export string as a read-only dataset. Never raises on bad input.
---@param str string
---@param opts? {label?: string}
---@return string|nil datasetId, string? err
function DB:Import(str, opts)
  local ok, id, err = pcall(X.import, self, str, opts)
  if not ok then return nil, "rejected: " .. tostring(id) end
  return id, err
end

--- Imported datasets.
---@return {id: string, label: string, at: integer, bytes: integer, counters: string[]}[]
function DB:Datasets()
  local r = X.datasets(self)
  return r
end

---@param id string
---@return boolean removed
function DB:RemoveDataset(id)
  local r = X.remove(self, id)
  return r
end

--- Run a maintenance pass to completion now (normally it runs sliced in the background).
---@return table|nil report, string? err
function DB:RunMaintenance()
  local r, e = M.Maint.runNow(self)
  return r, e
end

--- Sizes, budget, health counters and warnings for this host's root.
---@return table
function DB:Stats()
  local r = D.dbStats(self)
  return r
end

--- Report string for this host only.
---@return string
function DB:BuildReport()
  local s = D.buildReport({ self }, self._now())
  return s
end

--- Register a callback (built-in registry). With a CallbackHandler adapter, register there instead.
---@param event string OnNewExtreme | OnBucketClosed | OnRollup | OnCompaction | OnBudget | OnMigration | OnSecretRejected
---@param fn fun(event: string, ...: any)
---@param owner? any key used to unregister (default: fn)
function DB:RegisterCallback(event, fn, owner)
  if not EVENTS[event] then misuse(2, "RegisterCallback: unknown event '%s'", tostring(event)) end
  if type(fn) ~= "function" then misuse(2, "RegisterCallback: fn must be a function") end
  if not self._ownRegistry then misuse(2, "RegisterCallback: callbacks go through your callbacks adapter; register there") end
  self._cb.Register(event, fn, owner)
end

---@param event string
---@param owner any
function DB:UnregisterCallback(event, owner)
  if not EVENTS[event] then misuse(2, "UnregisterCallback: unknown event '%s'", tostring(event)) end
  if self._ownRegistry then self._cb.Unregister(event, owner) end
end

--- Optional at logout: flips flags only, no heavy work.
function DB:Detach()
  self._detached = true
  for i, db in ipairs(lib.__dbs) do
    if db == self then table.remove(lib.__dbs, i); break end
  end
end

---@return boolean readOnly, string? reason
function DB:IsReadOnly()
  return self._ro and true or false, self._roReason
end

---------------------------------------------------------------------------
-- Handle (hot path)
---------------------------------------------------------------------------

--- Flow write now. Dimensions in declared order. Returns false for secret/invalid values or read-only.
---@param v number
---@return boolean stored
function Handle:Add(v, d1, d2, d3, d4, d5, d6)
  local ok = S.write(self, false, nil, v, nil, d1, d2, d3, d4, d5, d6)
  return ok
end

--- Flow write at epoch time t (may be late).
---@param t integer
---@param v number
---@return boolean stored
function Handle:AddAt(t, v, d1, d2, d3, d4, d5, d6)
  local ok = S.write(self, false, t, v, nil, d1, d2, d3, d4, d5, d6)
  return ok
end

--- Flow write with a context table for extremes (read, never kept).
---@param v number
---@param ctx table
---@return boolean stored
function Handle:AddCtx(v, ctx, d1, d2, d3, d4, d5, d6)
  local ok = S.write(self, false, nil, v, ctx, d1, d2, d3, d4, d5, d6)
  return ok
end

--- Stock observation now.
---@param v number
---@return boolean stored
function Handle:Observe(v, d1, d2, d3, d4, d5, d6)
  local ok = S.write(self, true, nil, v, nil, d1, d2, d3, d4, d5, d6)
  return ok
end

--- Stock observation at epoch time t.
---@param t integer
---@param v number
---@return boolean stored
function Handle:ObserveAt(t, v, d1, d2, d3, d4, d5, d6)
  local ok = S.write(self, true, t, v, nil, d1, d2, d3, d4, d5, d6)
  return ok
end

--- Stock observation with a context table for extremes.
---@param v number
---@param ctx table
---@return boolean stored
function Handle:ObserveCtx(v, ctx, d1, d2, d3, d4, d5, d6)
  local ok = S.write(self, true, nil, v, ctx, d1, d2, d3, d4, d5, d6)
  return ok
end
