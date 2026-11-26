-- Registry: packs, sources and counters, and the emit path (DESIGN §3-4, §10).
-- Packs never see the LibGranaryDB db: RegisterCounter passes the storage fields to db:RegisterCounter and keeps
-- the Hard Counters fields (title, capture, accuracy, feasibility, run tracking, ...).
local ADDON, ns = ...

local HC, U, W = ns.HC, ns.U, ns.wow
local type, pairs, ipairs, tostring, error, pcall, select = type, pairs, ipairs, tostring, error, pcall, select
local format = string.format

ns.counters, ns.counterOrder = {}, {}
ns.sources, ns.sourceOrder = {}, {}
ns.packs, ns.packOrder = {}, {}

--- Members an odometer keeps per dimension before the rest go to "other". A dimension whose cap is at most this
--- is "small" (zones, sources, factions): every member is kept. Bigger ones (items): only watched members.
ns.ODO_MEMBER_CAP = 500


-- Fields LibGranaryDB understands (../LibGranaryDB/docs/API.md §3); everything else stays with Hard Counters.
local STORAGE_FIELDS = {
  id = true, version = true, kind = true, unit = true, measures = true, dimensions = true, aggregations = true,
  grains = true, retention = true, context = true, contextGrains = true, scope = true, maxGap = true, budget = true,
  onIncompatible = true,
}
local DEFAULT_GRAINS = { "hour", "day", "week", "resetweek", "month", "year", "lifetime" }
local ACCURACY = { exact = true, estimate = true, baseline = true }
local FEASIBILITY = { feasible = true, degraded = true, infeasible = true, unverified = true }

local function misuse(level, fmt, ...)
  error("HardCounters: " .. format(fmt, ...), level + 1)
end

---------------------------------------------------------------------------
-- Packs
---------------------------------------------------------------------------

local Pack = {}
Pack.__index = Pack

function Pack:Log(level, fmt, ...) ns.Log(level, self.tag, fmt, ...) end
function Pack:Count(name, n)
  n = n or 1
  self.health[name] = (self.health[name] or 0) + n
  -- also into the saved health counters (lifetime), so they can be read after a session
  ns.Count(self.namespace .. ":" .. name, n)
end

--- Register a pack (an addon that adds counters). Returns a pack object with :Log(level, fmt, ...) and
--- :Count(name). def = { namespace = "hcfarm", version = "0.1.0", title = "Farmer" }.
function HC:RegisterPack(name, def)
  if type(name) ~= "string" or not name:match("^[%w_]+$") then misuse(2, "RegisterPack(name, def): name must be letters, digits or _") end
  if type(def) ~= "table" or type(def.namespace) ~= "string" or not def.namespace:match("^[%w_%-]+$") then
    misuse(2, "RegisterPack: def.namespace (the counter id prefix) is required")
  end
  if def.namespace == "hc" then misuse(2, "RegisterPack: the 'hc' namespace belongs to Hard Counters") end
  local existing = ns.packs[name]
  if existing then return existing end
  for _, p in pairs(ns.packs) do
    if p.namespace == def.namespace then misuse(2, "RegisterPack: namespace '%s' is taken by pack %s", def.namespace, p.name) end
  end
  local p = setmetatable({ name = name, namespace = def.namespace, version = tostring(def.version or "?"),
    title = def.title or name, tag = "Pack:" .. name, health = {} }, Pack)
  ns.packs[name] = p
  ns.packOrder[#ns.packOrder + 1] = name
  return p
end

--- (2026-11-24) Hard Counters Basic: gold and XP, shipped inside Hard Counters and always on. It is a pack like the
--- others for the player (pack lists, the New board dialog, /hc report) but keeps the `hc` namespace, so every id it
--- registered before stays as it was. Not public: only Basics/Basics.lua calls it.
function ns.RegisterBuiltinPack(name, def)
  local existing = ns.packs[name]
  if existing then return existing end
  local p = setmetatable({ name = name, namespace = "hc", version = tostring(def.version or HC.VERSION or "?"),
    title = def.title or name, tag = "HC", health = {}, builtin = true }, Pack)
  ns.packs[name] = p
  table.insert(ns.packOrder, 1, name)
  return p
end

function ns.PackSummaries()
  local out = {}
  for _, name in ipairs(ns.packOrder) do
    local p = ns.packs[name]
    out[#out + 1] = { name = name, version = p.version, health = U.copy(p.health) }
  end
  return out
end

local function ownerOf(id)
  local nsName = U.namespace(id)
  if nsName == "hc" then return nil, "HC" end
  for _, p in pairs(ns.packs) do if p.namespace == nsName then return p, p.tag end end
  return nil, nil
end

---------------------------------------------------------------------------
-- Counters
---------------------------------------------------------------------------

local function buildCounter(def)
  local sdef = {}
  for k, v in pairs(def) do if STORAGE_FIELDS[k] then sdef[k] = v end end
  sdef.grains = sdef.grains or DEFAULT_GRAINS
  -- (HC-49: `runTracked` is gone. It forced the lifetime grain because runs once subtracted lifetime totals; runs
  -- read odometers since HC-29, and every history preset keeps lifetime when the counter declares it.)
  local dims, dimIndex = {}, {}
  for i, d in ipairs(def.dimensions or {}) do dims[i] = d.name; dimIndex[d.name] = i end
  local measures = {}
  for _, m in ipairs(def.measures or { "sum", "count" }) do measures[m] = true end
  local c = {
    id = def.id, kind = def.kind or "flow", unit = def.unit, title = def.title or def.id, category = def.category,
    icon = def.icon, capture = U.copy(def.capture), accuracy = def.accuracy or "exact",
    feasibility = U.copy(def.feasibility) or { status = "unverified" }, formatter = def.formatter,
    dims = dims, dimIndex = dimIndex, measures = measures,
    runBreakdowns = {}, runLive = nil,
    sdef = sdef, owner = def.owner,
  }
  for _, dim in ipairs(def.runBreakdowns or {}) do
    if not dimIndex[dim] then misuse(4, "RegisterCounter('%s'): runBreakdowns names unknown dimension '%s'", def.id, tostring(dim)) end
    local stored = false
    for _, set in ipairs(def.aggregations or {}) do
      if #set == 1 and set[1] == dim then stored = true end
    end
    if not stored then misuse(4, "RegisterCounter('%s'): runBreakdowns '%s' needs the aggregation set { \"%s\" }", def.id, dim, dim) end
    c.runBreakdowns[#c.runBreakdowns + 1] = dim
  end
  -- The odometer keeps a total per member (DESIGN §16.2, §16.4): of every small dimension (cap up to
  -- ODO_MEMBER_CAP), every member; of a big one (items), only the members a tile watches (ns.WatchMember).
  local small, big = {}, {}
  c.dimCap = {}                                        -- declared caps: past one, storage counts in "other"
  for _, d in ipairs(def.dimensions or {}) do
    if (d.cap or 0) <= ns.ODO_MEMBER_CAP then small[#small + 1] = d.name else big[#big + 1] = d.name end
    if type(d.cap) == "number" then c.dimCap[d.name] = d.cap end
  end
  if #small > 0 then c.memberDims = small end
  if #big > 0 then c.bigDims = big end
  if def.runLive then
    local rl = def.runLive
    local idx = rl.member and dimIndex[rl.member]
    if rl.member and not idx then misuse(4, "RegisterCounter('%s'): runLive.member names unknown dimension '%s'", def.id, tostring(rl.member)) end
    c.runLive = { member = rl.member, memberIdx = idx, cap = rl.cap or 500, max = rl.max and true or false }
  end
  return c
end

--- Bring a counter in line with the trackers (Trackers.lua, HC-19): active or not, and if active, Live only
--- (history off: no storage handle, totals in memory) or registered with LibGranaryDB in its history's shape
--- (grains and retention of the preset, removed = "keep": lowering history freezes data, never deletes it).
--- Storage registration can't be undone within a session, so a counter that stops storing just stops writing.
local function reconcileCounter(c)
  local active, level, days = false, 0, 14
  if ns.CounterPlan then active, level, days = ns.CounterPlan(c.id) end
  local was = c.active
  c.active, c.level, c.days = active, level, days
  if active and c.liveRate and not c.rate then
    c.rate = ns.GDB.RateWindow:New({ slots = 60, slotSeconds = 10, now = W.time })
  end
  if active and not was then ns.Fire("HC_COUNTER_REGISTERED", c.id) end
  if not active or level == 0 or not ns.db then
    c.h, c.grainSet, c.shape = nil, nil, nil
    return
  end
  local grains, retention = ns.HistoryShape(level, days, c.sdef.grains)
  local shape = table.concat(grains, ",") .. "|" .. tostring(retention and retention.hour) .. ","
    .. tostring(retention and retention.day) .. "," .. tostring(retention and retention.week)
  if c.h and c.shape == shape then return end
  local sdef = {}
  for k, v in pairs(c.sdef) do sdef[k] = v end
  sdef.grains = grains
  local ret = {}
  for k, v in pairs(c.sdef.retention or {}) do ret[k] = v end
  for k, v in pairs(retention or {}) do ret[k] = v end
  sdef.retention = ret
  sdef.removed = "keep"
  local ok, err = pcall(ns.db.RegisterCounter, ns.db, sdef)
  if not ok then
    ns.Log("error", c.ownerTag or "HC", "counter %s rejected by storage: %s", c.id, tostring(err))
    c.h, c.grainSet, c.shape = nil, nil, nil
    return
  end
  c.h = ns.db:Handle(c.id)
  c.shape = shape
  if ns.RememberCounterName then ns.RememberCounterName(c) end   -- (HC-48) "Not loaded" names it when its pack is gone
  c.grainSet = {}
  for _, g in ipairs(grains) do c.grainSet[g] = true end
end

--- Sources follow the counters they feed (`feeds`); a source without feeds always runs.
local function sourceWanted(s)
  if not s.feeds then return true end
  for _, cid in ipairs(s.feeds) do
    local c = ns.counters[cid]
    if c and c.active then return true end
  end
  return false
end

local function setSourceActive(s, on)
  on = on and true or false
  if s.active == on then return end
  s.active = on
  if s.mode == "event" then
    for _, ev in ipairs(s.eventList) do
      if on then ns.On(ev, s.fn, s.tag) else ns.Off(ev, s.fn) end
    end
  elseif s.mode == "poll" then
    if on then s.job:Resume() else s.job:Pause() end
  end
  -- hooks can't be removed: the wrapper checks s.active
end

--- Recompute every counter and source from the trackers (a tracker registered or switched, history changed,
--- profile switched). Cheap: a counter whose shape didn't change isn't touched.
function ns.Reconcile()
  if not ns.ready then return end
  for _, id in ipairs(ns.counterOrder) do reconcileCounter(ns.counters[id]) end
  for _, id in ipairs(ns.sourceOrder) do setSourceActive(ns.sources[id], sourceWanted(ns.sources[id])) end
end

--- Register a counter: LibGranaryDB fields (id, version, kind, unit, measures, dimensions, aggregations, grains,
--- retention, context, budget, onIncompatible) plus Hard Counters fields:
---   title, category, icon, formatter, capture = { mode = ... }, accuracy ("exact"|"estimate"|"baseline"),
---   feasibility = { status = "feasible"|"degraded"|"infeasible"|"unverified", note, ref },
---   runBreakdowns = { dim, ... } (snapshotted per run; keep them small),
---   runLive = { member = dim, cap = 500, max = true } (tallied live during a run; e.g. Farmer's items),
---   liveRate (bool: keep a 10-minute in-memory rate window for HardCounters:Live).
--- The id is "<pack namespace>:<name>"; register the pack first. Returns the id.
function HC:RegisterCounter(def)
  if type(def) ~= "table" then misuse(2, "RegisterCounter(def): def must be a table") end
  if not U.validId(def.id) then misuse(2, "RegisterCounter: id must be \"namespace:name\", got %s", tostring(def.id)) end
  local pack, tag = ownerOf(def.id)
  if not tag then misuse(2, "RegisterCounter('%s'): register a pack with namespace '%s' first", def.id, tostring(U.namespace(def.id))) end
  if def.accuracy ~= nil and not ACCURACY[def.accuracy] then misuse(2, "RegisterCounter('%s'): bad accuracy '%s'", def.id, tostring(def.accuracy)) end
  if def.feasibility ~= nil and (type(def.feasibility) ~= "table" or not FEASIBILITY[def.feasibility.status]) then
    misuse(2, "RegisterCounter('%s'): feasibility.status must be feasible, degraded, infeasible or unverified", def.id)
  end
  local c = buildCounter(def)
  c.pack, c.ownerTag, c.liveRate = pack, tag, def.liveRate and true or false
  local old = ns.counters[def.id]
  if old then c.active, c.rate = old.active, old.rate end
  ns.counters[def.id] = c
  if not old then ns.counterOrder[#ns.counterOrder + 1] = def.id end
  -- Storage registration follows the trackers (reconcileCounter); before storage is attached, at OnReady.
  if ns.ready then ns.Reconcile() end
  return def.id
end

ns.OnReady(function() ns.Reconcile() end)

function ns.CounterCount() return #ns.counterOrder end

--- Public description of a counter (a copy): title, kind, unit, dimensions, accuracy, feasibility, ...
function HC:GetCounter(id)
  local c = ns.counters[id]
  if not c then return nil end
  return { id = c.id, title = c.title, kind = c.kind, unit = c.unit, category = c.category, icon = c.icon,
    dimensions = U.copy(c.dims), accuracy = c.accuracy, feasibility = U.copy(c.feasibility), formatter = c.formatter,
    capture = U.copy(c.capture), active = c.active or false, stored = c.h ~= nil }
end

function HC:Counters()
  local out = {}
  for i, id in ipairs(ns.counterOrder) do out[i] = id end
  return out
end

--- Change a counter's feasibility verdict at run time (e.g. a probe found position missing in instances).
function HC:SetFeasibility(id, status, note)
  local c = ns.counters[id]
  if not c then misuse(2, "SetFeasibility: unknown counter '%s'", tostring(id)) end
  if not FEASIBILITY[status] then misuse(2, "SetFeasibility: bad status '%s'", tostring(status)) end
  if c.feasibility.status == status and c.feasibility.note == note then return end
  c.feasibility.status, c.feasibility.note = status, note
  ns.Fire("HC_FEASIBILITY_CHANGED", id, status, note)
end

---------------------------------------------------------------------------
-- Emit (hot path: no allocation unless a run sees a new member or a new run record)
---------------------------------------------------------------------------

local isSecret = function(v) return W.isSecret(v) end

local function unknown(id)
  ns.Count("emitUnknownCounter")
  ns.Log("warn", "HC", "emit to unknown or unattached counter %s", tostring(id))
  return false
end

local ODO_MEMBER_CAP = ns.ODO_MEMBER_CAP
--- How many of a big dimension's members the odometer remembers as "recent" (a picker's list).
ns.RECENT_MEMBERS = 20
local RECENT_MEMBERS = ns.RECENT_MEMBERS

--- The odometer (Odometer.lua): this character's running total, and a total per member of the counter's
--- memberDims. Allocation only at a counter's or a member's first write ever.
local function odoAdd(c, v, ...)
  local odo = ns.odo
  local o = odo[c.id]
  if not o then o = { s = 0, n = 0 }; odo[c.id] = o end
  o.s = (o.s or 0) + v
  o.n = (o.n or 0) + 1
  local dims = c.memberDims
  if dims then
    local by = o.by
    if not by then by = {}; o.by = by end
    local bn = o.bn
    if not bn then bn = {}; o.bn = bn end
    for i = 1, #dims do
      local dim = dims[i]
      local key = select(c.dimIndex[dim], ...)
      if key == nil then key = "none" end
      local m = by[dim]
      if not m then m = {}; by[dim] = m end
      local cur = m[key]
      if cur == nil then
        local n = bn[dim] or 0
        if n >= ODO_MEMBER_CAP then
          key = "other"
          cur = m.other
        else
          bn[dim] = n + 1
        end
      end
      m[key] = (cur or 0) + v
    end
  end
  -- big dimensions: only members somebody watches exist in o.by; the last few members written are remembered
  -- (o.rc[dim], newest first) so a picker can offer "recently looted" (HC-34). No allocation once the lists exist.
  local bigs = c.bigDims
  if bigs then
    local by = o.by
    local rc = o.rc
    if not rc then rc = {}; o.rc = rc end
    for i = 1, #bigs do
      local dim = bigs[i]
      local key = select(c.dimIndex[dim], ...)
      if key ~= nil then
        local list = rc[dim]
        if not list then list = {}; rc[dim] = list end
        local n = #list
        local at = n < RECENT_MEMBERS and n + 1 or n
        for j = 1, n do if list[j] == key then at = j; break end end
        for j = at, 2, -1 do list[j] = list[j - 1] end
        list[1] = key
      else
        key = "none"
      end
      local m = by and by[dim]
      if m then
        local cur = m[key]
        if cur ~= nil then m[key] = cur + v end
      end
    end
  end
end

--- A stock's last value per member of its small dimensions (o.lb), next to its last value overall.
local function odoObserve(c, v, ...)
  local odo = ns.odo
  local o = odo[c.id]
  if not o then o = {}; odo[c.id] = o end
  o.l = v
  local dims = c.memberDims
  if dims then
    local lb = o.lb
    if not lb then lb = {}; o.lb = lb end
    for i = 1, #dims do
      local dim = dims[i]
      local key = select(c.dimIndex[dim], ...)
      if key == nil then key = "none" end
      local m = lb[dim]
      if not m then m = {}; lb[dim] = m end
      m[key] = v
    end
  end
end

local function afterWrite(c, v, ctx, ...)
  ns.dirty = true                -- displays redraw on the next frame (HC-33)
  odoAdd(c, v, ...)
  if c.rate then c.rate:Add(v) end
  if c.runLive and ns.runEmitHook then ns.runEmitHook(c, v, ctx, ...) end
end

local HUGE = math.huge
--- A Live only counter has no storage to validate its values: refuse what LibGranaryDB would.
local function liveOk(v)
  return type(v) == "number" and v == v and v ~= HUGE and v ~= -HUGE
end

-- Storage refused a valid value (LibGranaryDB read-only: 2026-11-21 its maintenance failed at load and switched
-- storage off for the session). The live numbers (odometers, windows, boards) keep counting; history isn't saved.
-- Counted every time, said once per session.
local refusedSaid = false
local function storageRefused(c)
  ns.Count("storageRefused")
  if refusedSaid then return end
  refusedSaid = true
  local ro, why = false, nil
  if ns.db and ns.db.IsReadOnly then ro, why = ns.db:IsReadOnly() end
  ns.Log("warn", "HC", "storage refused a write to %s%s: live numbers keep counting, history isn't saved this session",
    tostring(c.id), ro and (" (read-only: " .. tostring(why) .. ")") or "")
end

--- Add v to a flow counter. Dimensions in declared order. Returns true when counted, false when refused (secret
--- or invalid value, unknown counter) or quietly ignored (the counter is off: no tracker that is on needs it, or
--- storage isn't attached yet). A valid value storage won't take (read-only) still counts live.
function HC:Emit(id, v, ...)
  local c = ns.counters[id]
  if not c then return unknown(id) end
  if not c.active then return false end
  if isSecret(v) then ns.Count("secretsRejected"); return false end
  if not liveOk(v) then return false end
  local h = c.h
  if h and not h:Add(v, ...) then storageRefused(c) end
  afterWrite(c, v, nil, ...)
  return true
end

--- Add v with a context table for records (max/min with context). The table is read, never kept: reuse it.
function HC:EmitCtx(id, v, ctx, ...)
  local c = ns.counters[id]
  if not c then return unknown(id) end
  if not c.active then return false end
  if isSecret(v) then ns.Count("secretsRejected"); return false end
  if not liveOk(v) then return false end
  local h = c.h
  if h and not h:AddCtx(v, ctx, ...) then storageRefused(c) end
  afterWrite(c, v, ctx, ...)
  return true
end

--- Observe the current level of a stock counter (e.g. gold owned).
function HC:Observe(id, v, ...)
  return HC.ObserveCtx(self, id, v, nil, ...)
end

--- Observe a stock's level with a context table for records (HC-26: "most attack power ever, in BRD, 6 buffs"):
--- storage keeps it with a new lowest or highest value. The table is read, never kept: reuse one.
function HC:ObserveCtx(id, v, ctx, ...)
  local c = ns.counters[id]
  if not c then return unknown(id) end
  if not c.active then return false end
  if isSecret(v) then ns.Count("secretsRejected"); return false end
  if not liveOk(v) then return false end
  if c.h then
    local stored
    if ctx ~= nil then stored = c.h:ObserveCtx(v, ctx, ...) else stored = c.h:Observe(v, ...) end
    if not stored then storageRefused(c) end
  end
  odoObserve(c, v, ...)
  if ns.ObserveWindows then ns.ObserveWindows(c.id, v) end
  ns.dirty = true
  return true
end

---------------------------------------------------------------------------
-- Sources: event, poll and hook capture registered through the engine (PACKS §3: polling only here)
---------------------------------------------------------------------------

--- def = { mode = "event"|"poll"|"hook", events = { "PLAYER_MONEY", ... } (event), handler = fn(event, ...),
---         interval = seconds (poll), read = fn() (poll), hook = "GlobalFunctionName" (hook),
---         feeds = { counterId, ... } (the counters it writes: it runs only while one of them is active) }
--- Handlers run isolated (pcall) and are tagged with the pack in logs. Returns the source id.
--- A source whose counters are all off unregisters its events, pauses its poll, or ignores its hook's calls
--- (hooks can't be removed). Without `feeds` it always runs (PACKS §3: declare them).
function HC:RegisterSource(id, def)
  if not U.validId(id) then misuse(2, "RegisterSource: id must be \"namespace:name\", got %s", tostring(id)) end
  if type(def) ~= "table" then misuse(2, "RegisterSource('%s', def): def must be a table", id) end
  if ns.sources[id] then misuse(2, "RegisterSource: '%s' is already registered", id) end
  local _, tag = ownerOf(id)
  if not tag then misuse(2, "RegisterSource('%s'): register a pack with namespace '%s' first", id, tostring(U.namespace(id))) end
  if def.feeds ~= nil and (type(def.feeds) ~= "table" or #def.feeds == 0) then
    misuse(2, "RegisterSource('%s'): feeds must list the counters it writes", id)
  end
  local s = { id = id, mode = def.mode, events = 0, errors = 0, last = nil, tag = tag, active = false,
    feeds = def.feeds and U.copy(def.feeds) or nil }
  if def.mode == "event" then
    if type(def.events) ~= "table" or type(def.handler) ~= "function" then misuse(2, "RegisterSource('%s'): event sources need events and handler", id) end
    local handler = def.handler
    s.fn = function(event, ...)
      s.events = s.events + 1
      s.last = W.now()
      local ok, err = pcall(handler, event, ...)
      if not ok then s.errors = s.errors + 1; ns.Error(err, tag) end
    end
    s.eventList = U.copy(def.events)
  elseif def.mode == "poll" then
    if type(def.read) ~= "function" or type(def.interval) ~= "number" or def.interval < 0.1 then
      misuse(2, "RegisterSource('%s'): poll sources need read and an interval of at least 0.1 s", id)
    end
    local read = def.read
    s.job = ns.Every(def.interval, function()
      s.events = s.events + 1
      s.last = W.now()
      local ok, err = pcall(read)
      if not ok then s.errors = s.errors + 1; ns.Error(err, tag) end
    end, { origin = tag, paused = true })
  elseif def.mode == "hook" then
    if type(def.hook) ~= "string" or type(def.handler) ~= "function" then misuse(2, "RegisterSource('%s'): hook sources need hook and handler", id) end
    local handler = def.handler
    local okHook, herr = pcall(W.hook, def.hook, function(...)
      if not s.active then return end
      s.events = s.events + 1
      local ok, err = pcall(handler, ...)
      if not ok then s.errors = s.errors + 1; ns.Error(err, tag) end
    end)
    if not okHook then ns.Log("warn", tag, "hook %s failed: %s", def.hook, tostring(herr)) end
  else
    misuse(2, "RegisterSource('%s'): mode must be event, poll or hook", id)
  end
  ns.sources[id] = s
  ns.sourceOrder[#ns.sourceOrder + 1] = id
  -- before storage is attached, only sources without feeds run (the rest wait for the trackers, at OnReady)
  setSourceActive(s, (ns.ready or not s.feeds) and sourceWanted(s))
  return id
end

--- Change a poll source's interval (adaptive polling). The scheduler applies it from the next tick.
function HC:SetSourceInterval(id, interval)
  local s = ns.sources[id]
  if not (s and s.job) then misuse(2, "SetSourceInterval: '%s' is not a poll source", tostring(id)) end
  s.job:SetInterval(interval)
end

function ns.SourceStats()
  local out = {}
  for _, id in ipairs(ns.sourceOrder) do
    local s = ns.sources[id]
    out[#out + 1] = { id = id, mode = s.mode, events = s.events, errors = s.errors, last = s.last, active = s.active }
  end
  return out
end

---------------------------------------------------------------------------
-- Attributors (TRACKERS_AND_BOARDS §4, HC-21): a pack names the source of a change it didn't capture itself.
-- Basics diffs GetMoney and UnitXP; Farmer knows from chat lines and open windows where the money came from.
---------------------------------------------------------------------------

local attributors = {}

--- fn(amount, t, book): called by the counter's capturing module (Basics for hc:money.in, hc:money.out, hc:xp) at
--- each change; call book(amount, source) for all or part of `amount`, now or within a few seconds (Basics books
--- whatever is left after 5 s as "none"). One attributor per counter: the last one set wins. nil clears it.
function HC:SetAttributor(counterId, fn)
  if type(counterId) ~= "string" then misuse(2, "SetAttributor(counterId, fn): counterId must be a counter id") end
  if fn ~= nil and type(fn) ~= "function" then misuse(2, "SetAttributor('%s', fn): fn must be a function", counterId) end
  if attributors[counterId] and fn and attributors[counterId] ~= fn then
    ns.Log("warn", "HC", "attributor for %s replaced", counterId)
  end
  attributors[counterId] = fn
end

function HC:GetAttributor(counterId)
  return attributors[counterId]
end
