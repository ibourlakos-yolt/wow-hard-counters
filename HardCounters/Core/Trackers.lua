-- Trackers (TRACKERS_AND_BOARDS §2, §3; HC-19): what the player switches on and off. A tracker is a named feature
-- that needs some counters ("Gold per hour", "Ledger"). Nothing runs that nothing needs:
--
--   tracker on?  ->  counter active  = some tracker that is on lists it
--                    counter history = the most any such tracker keeps (Off < Lifetime < Daily < Detailed)
--                    source active   = some counter it feeds is active (RegisterSource's `feeds`)
--
-- History is off by default: an active counter without history is **Live only**: no LibGranaryDB registration at
-- all; its totals live in memory (the login state, the open run) and survive a /reload, not a logout. With history
-- on, the counter is registered with the grains and retention of its preset and `removed = "keep"`, so lowering
-- history or switching off only freezes data (LibGranaryDB r3); only Delete (DropCounter) removes it.
-- Choices are saved per AceDB profile: settings.trackers[id] = { on, history, days, seen }.
local ADDON, ns = ...

local HC, U = ns.HC, ns.U
local type, pairs, ipairs, tostring, error = type, pairs, ipairs, tostring, error
local format = string.format

ns.trackers, ns.trackerOrder = {}, {}

local PRESETS = { off = 0, lifetime = 1, daily = 2, detailed = 3 }
local PRESET_NAMES = { [0] = "off", "lifetime", "daily", "detailed" }
ns.HISTORY_PRESETS = PRESETS
ns.HISTORY_ORDER = { "off", "lifetime", "daily", "detailed" }
local DAY_CHOICES = { [14] = true, [30] = true, [90] = true, [365] = true }
ns.HISTORY_DAYS = { 14, 30, 90, 365 }
local DEFAULT_DAYS = 14

local function misuse(fmt, ...)
  error("HardCounters: " .. format(fmt, ...), 3)
end

---------------------------------------------------------------------------
-- Saved choices (per profile)
---------------------------------------------------------------------------

local function store()
  local s = ns.settings
  if not s then return nil end
  if type(s.trackers) ~= "table" then s.trackers = {} end
  return s.trackers
end

local function conf(id)
  local st = store()
  if not st then return nil end
  local c = st[id]
  if type(c) ~= "table" then
    c = {}
    st[id] = c
  end
  return c
end

local function isOn(t)
  local st = store()
  local c = st and st[t.id]
  if type(c) == "table" and c.on ~= nil then return c.on and true or false end
  return t.default == "on"
end

--- The history a tracker keeps: the player's choice, raised to what the tracker needs. Returns level, days.
local function trackerHistory(t)
  local st = store()
  local c = st and st[t.id]
  local h = type(c) == "table" and PRESETS[c.history] or 0
  local need = t.needsHistory and PRESETS[t.needsHistory] or 0
  if need > h then h = need end
  local days = type(c) == "table" and DAY_CHOICES[c.days] and c.days or DEFAULT_DAYS
  return h, days
end

---------------------------------------------------------------------------
-- Registration
---------------------------------------------------------------------------

--- def = { title, counters = { id, ... }, default = "on"|"off" (packs: "off"), needsHistory = "lifetime"|"daily"|
---   "detailed" (the tracker makes no sense without it: Farmer's Ledger), icon, category, description }.
function HC:RegisterTracker(id, def)
  if not U.validId(id) then misuse("RegisterTracker: id must be \"namespace:name\", got %s", tostring(id)) end
  -- (an empty list is a tracker of live readings only: computed `now` readings with no counter, Character Stats'
  -- phase 1; it switches its readings on and off and has no history)
  if type(def) ~= "table" or type(def.counters) ~= "table" then
    misuse("RegisterTracker('%s'): def.counters must list the counters it needs ({} for live readings only)", id)
  end
  if def.default ~= nil and def.default ~= "on" and def.default ~= "off" then misuse("RegisterTracker('%s'): default must be \"on\" or \"off\"", id) end
  if def.needsHistory ~= nil and not (PRESETS[def.needsHistory] and def.needsHistory ~= "off") then
    misuse("RegisterTracker('%s'): needsHistory must be lifetime, daily or detailed", id)
  end
  local nsName = U.namespace(id)
  local pack
  for _, p in pairs(ns.packs) do if p.namespace == nsName then pack = p end end
  if nsName ~= "hc" and not pack then misuse("RegisterTracker('%s'): register a pack with namespace '%s' first", id, tostring(nsName)) end
  local t = {
    id = id, title = def.title or id, counters = U.copy(def.counters), default = def.default or "off",
    needsHistory = def.needsHistory, icon = def.icon, category = def.category, description = def.description,
    pack = pack and pack.name or nil, packTitle = pack and pack.title or "Hard Counters",
    builtin = pack and pack.builtin or nil,     -- (Hard Counters Basic: always there, never announced as new)
  }
  if not ns.trackers[id] then ns.trackerOrder[#ns.trackerOrder + 1] = id end
  ns.trackers[id] = t
  if ns.Reconcile then ns.Reconcile() end
  return id
end

---------------------------------------------------------------------------
-- Derived activation
---------------------------------------------------------------------------

--- For a counter: active, history level (0..3), days (for daily). Pure: reads trackers and settings.
--- hc:time.active is active whenever any tracker is on, and keeps the most history any active tracker keeps.
function ns.CounterPlan(counterId)
  local active, level, days = false, 0, 0
  local isTime = counterId == ns.TIME_ID
  for _, tid in ipairs(ns.trackerOrder) do
    local t = ns.trackers[tid]
    if isOn(t) then
      local uses = isTime
      if not uses then
        for _, cid in ipairs(t.counters) do if cid == counterId then uses = true; break end end
      end
      if uses then
        active = true
        local h, d = trackerHistory(t)
        if h > level then level = h end
        if h == PRESETS.daily and d > days then days = d end
      end
    end
  end
  if days == 0 then days = DEFAULT_DAYS end
  return active, level, days
end

--- The LibGranaryDB grains and retention of a history level (intersected with what the counter declares).
function ns.HistoryShape(level, days, declared)
  local want
  if level == PRESETS.lifetime then
    want = { lifetime = true }
  elseif level == PRESETS.daily then
    want = { day = true, month = true, year = true, lifetime = true }
    want[(ns.settings and ns.settings.weekGrain) or "week"] = true
  elseif level == PRESETS.detailed then
    want = { hour = true, day = true, week = true, resetweek = true, month = true, year = true, lifetime = true }
  else
    return nil
  end
  local grains = {}
  for _, g in ipairs(declared) do if want[g] then grains[#grains + 1] = g end end
  local retention
  if level == PRESETS.daily then
    retention = { day = days .. "d" }
  elseif level == PRESETS.detailed then
    retention = { hour = "48h", day = (days > 90 and days or 90) .. "d", week = "2y", resetweek = "2y" }
  end
  return grains, retention
end

---------------------------------------------------------------------------
-- Public: state and choices
---------------------------------------------------------------------------

local function trackerCopy(t)
  local st = store()
  local c = st and st[t.id]
  local h, days = trackerHistory(t)
  return { id = t.id, title = t.title, counters = U.copy(t.counters), on = isOn(t), default = t.default,
    history = PRESET_NAMES[h], days = days, chosenHistory = type(c) == "table" and c.history or "off",
    lastHistory = type(c) == "table" and PRESETS[c.last] and c.last or "daily",
    needsHistory = t.needsHistory, icon = t.icon, category = t.category, description = t.description,
    chosen = type(c) == "table" and c.on ~= nil,   -- the player switched it on or off themselves
    pack = t.pack, packTitle = t.packTitle, new = t.pack ~= nil and not t.builtin and not (type(c) == "table" and c.seen) }
end

function HC:GetTracker(id)
  local t = ns.trackers[id]
  return t and trackerCopy(t) or nil
end

function HC:Trackers()
  local out = {}
  for _, id in ipairs(ns.trackerOrder) do out[#out + 1] = trackerCopy(ns.trackers[id]) end
  return out
end

function HC:IsTrackerOn(id)
  local t = ns.trackers[id]
  return t and isOn(t) or false
end

local function changed()
  if ns.Reconcile then ns.Reconcile() end
  ns.Fire("HC_TRACKERS_CHANGED")
end

--- Switch a tracker on or off (saved per profile; also marks it seen). Switching on works at once; switching off
--- stops its counters' writes at once and their storage registration at the next /reload.
function HC:SetTrackerOn(id, on)
  local t = ns.trackers[id]
  if not t then return false end
  local c = conf(id)
  if not c then return false end
  c.on = on and true or false
  c.seen = true
  changed()
  return true
end

--- Choose a tracker's history: "off" | "lifetime" | "daily" | "detailed"; days (daily) 14, 30, 90 or 365.
function HC:SetTrackerHistory(id, preset, days)
  local t = ns.trackers[id]
  if not t then return false end
  if PRESETS[preset] == nil then misuse("SetTrackerHistory('%s'): preset must be off, lifetime, daily or detailed", id) end
  if days ~= nil and not DAY_CHOICES[days] then misuse("SetTrackerHistory('%s'): days must be 14, 30, 90 or 365", id) end
  local c = conf(id)
  if not c then return false end
  -- what "Keep history" brings back (HC-48): the preset chosen, or the one switched off (choices made before HC-48)
  c.last = preset ~= "off" and preset or c.history or c.last
  c.history = preset ~= "off" and preset or nil
  if days then c.days = days end
  c.seen = true
  changed()
  return true
end

--- The "Keep history" switch (HC-48, DESIGN §16.7.3): on brings back the last preset chosen under Advanced, else
--- Daily (with the days chosen before, else 14); off is the Off preset (what was kept is frozen, not deleted). A
--- tracker that needs history (the Ledger) keeps what it needs whatever the switch says.
function HC:SetTrackerKeepHistory(id, on)
  local t = ns.trackers[id]
  if not t then return false end
  if not on then return HC:SetTrackerHistory(id, "off") end
  local c = conf(id)
  local last = c and PRESETS[c.last] and c.last ~= "off" and c.last or "daily"
  return HC:SetTrackerHistory(id, last)
end

--- Mark a tracker seen (the Trackers window's New badge goes).
function HC:MarkTrackerSeen(id)
  if not ns.trackers[id] then return false end
  local c = conf(id)
  if c then c.seen = true end
  return true
end

--- A counter's state: { active, history = "off"|..., days, stored (registered with storage this session) }.
function HC:CounterState(id)
  local c = ns.counters[id]
  if not c then return nil end
  return { active = c.active or false, history = PRESET_NAMES[c.level or 0], days = c.days, stored = c.h ~= nil }
end

--- What switching a tracker off would stop: readings that read only its counters, and the other trackers that
--- keep a shared counter running. { readings = { title, ... }, keptBy = { tracker title, ... } }.
function HC:TrackerOffImpact(id)
  local t = ns.trackers[id]
  if not t then return nil end
  local mine = {}
  for _, cid in ipairs(t.counters) do mine[cid] = true end
  local keptBy, kept = {}, {}
  for _, oid in ipairs(ns.trackerOrder) do
    local o = ns.trackers[oid]
    if oid ~= id and isOn(o) then
      for _, cid in ipairs(o.counters) do
        if mine[cid] then kept[cid] = true; keptBy[#keptBy + 1] = o.title; break end
      end
    end
  end
  local readings = {}
  for _, rid in ipairs(ns.allReadingOrder or {}) do
    local r = ns.readings[rid]
    -- display titles: "Gold from ..." for a reading with a parameter, never its raw "%s"
    if r.tracker == id or (r.counter and mine[r.counter] and not kept[r.counter]) then
      readings[#readings + 1] = ns.ReadingTitle and ns.ReadingTitle(r) or r.title
    end
  end
  return { readings = readings, keptBy = keptBy }
end

---------------------------------------------------------------------------
-- Delete: the only path that removes saved data (LibGranaryDB DropCounter, r3)
---------------------------------------------------------------------------

local GRAIN_GROUPS = { hourly = { "hour" }, daily = { "day", "week", "resetweek" } }

--- Delete a tracker's saved history (every counter it lists; counters shared with another tracker lose it too:
--- the confirm says so). part: nil (all of it), "hourly" or "daily". Returns the estimated bytes freed.
function HC:DeleteTrackerHistory(id, part)
  local t = ns.trackers[id]
  if not (t and ns.db) then return 0 end
  local opts
  if part ~= nil then
    if not GRAIN_GROUPS[part] then misuse("DeleteTrackerHistory('%s'): part must be nil, \"hourly\" or \"daily\"", id) end
    opts = { grains = GRAIN_GROUPS[part] }
  end
  local freed = 0
  for _, cid in ipairs(t.counters) do
    local n = ns.db:DropCounter(cid, opts)
    if n then freed = freed + n end
  end
  if freed > 0 then
    ns.Log("info", "HC", "deleted %d bytes of %s history for %s", freed, part or "all", id)
    ns.Fire("HC_HISTORY_DELETED", id, part)
  end
  return freed
end

--- Delete a counter's saved data outright (the Trackers window's "Not loaded" list: data no pack registered this
--- session, such as Farmer's old hcfarm:money.*). Returns the estimated bytes freed (0 when there was none).
function HC:DeleteCounterData(counterId)
  if not ns.db or type(counterId) ~= "string" or counterId:sub(1, 1) == "@" then return 0 end
  local n = ns.db:DropCounter(counterId)
  if n then
    ns.Log("info", "HC", "deleted %d bytes of %s", n, counterId)
    ns.Fire("HC_HISTORY_DELETED", nil, nil, counterId)
    return n
  end
  return 0
end

---------------------------------------------------------------------------
-- Sizes for the Trackers window (LibGranaryDB db:Stats(), measured)
---------------------------------------------------------------------------

--- { [counterId] = { bytes, frozenBytes, registered, grains = { name = bytes } } } for every counter on disk.
function ns.CounterSizes()
  if not ns.db then return {} end
  local s = ns.db:Stats()
  local out = {}
  for id, c in pairs(s.counters or {}) do
    if id:sub(1, 1) ~= "@" then
      out[id] = { bytes = c.bytes or 0, frozenBytes = c.frozenBytes or 0, registered = c.registered, grains = U.copy(c.grains) }
    end
  end
  return out, s.total
end

--- A tracker's bytes on disk and the frozen part (counters shared between trackers count for each).
function HC:TrackerSize(id, sizes)
  local t = ns.trackers[id]
  if not t then return 0, 0 end
  sizes = sizes or ns.CounterSizes()
  local bytes, frozen = 0, 0
  for _, cid in ipairs(t.counters) do
    local s = sizes[cid]
    if s then bytes = bytes + s.bytes; frozen = frozen + s.frozenBytes end
  end
  return bytes, frozen
end

---------------------------------------------------------------------------
-- Names for "Not loaded" (HC-48): never a raw id. A counter's title and pack are saved (account-wide,
-- HardCountersDB.names[id] = { t = title, p = pack title }) when it is first stored, so they can be shown in a
-- session its pack isn't loaded in. Counters stored before HC-48 are named from their id.
---------------------------------------------------------------------------

-- Packs by namespace, for counters stored before their names were kept (the packs of this suite)
local KNOWN_PACKS = { hc = "Hard Counters", hcfarm = "Farmer", hcstats = "Character Stats" }

--- Remember a stored counter's title and pack (Registry's reconcile, when storage takes it). Cheap: runs at a
--- reconcile, not per event, and writes only when something changed.
function ns.RememberCounterName(c)
  local SV = ns.SV
  if not (SV and c and c.id) then return end
  if type(SV.names) ~= "table" then SV.names = {} end
  local title = c.title ~= c.id and c.title or nil      -- (an untitled counter's title is its id)
  local pack = c.pack and c.pack.title or (U.namespace(c.id) == "hc" and "Hard Counters" or nil)
  local n = SV.names[c.id]
  if type(n) == "table" and n.t == title and n.p == pack then return end
  SV.names[c.id] = { t = title, p = pack }
end

--- "money.out" -> "Money out": a readable name from an id's last part.
local function fromId(id)
  local name = tostring(id):match(":(.+)$") or tostring(id)
  name = name:gsub("[%._]+", " ")
  return (name:gsub("^%l", string.upper))
end

--- Is a pack with this namespace loaded this session? Returns true and its title.
local function packLoaded(namespace)
  if namespace == "hc" then return true, "Hard Counters" end
  for _, p in pairs(ns.packs) do if p.namespace == namespace then return true, p.title end end
  return false
end

--- A counter's name for the player: title, pack title, why it isn't loaded ("pack not loaded": its pack isn't
--- installed or enabled this session; "no longer used": the pack is loaded but no longer registers it), and the
--- whole line ("Farmer: Money out (no longer used)").
function ns.CounterName(id)
  local SV = ns.SV
  local n = SV and type(SV.names) == "table" and SV.names[id] or nil
  local space = U.namespace(id)
  local loaded, loadedTitle = packLoaded(space)
  local title = type(n) == "table" and n.t or fromId(id)
  local pack = type(n) == "table" and n.p or loadedTitle or KNOWN_PACKS[space] or space or "?"
  return title, pack, loaded and "no longer used" or "pack not loaded"
end

--- Counters with data on disk that nothing registered this session and no tracker lists ("Not loaded"):
--- { id, bytes, title, pack, why }, by pack then title.
function HC:UnloadedCounters()
  local sizes = ns.CounterSizes()
  local listed = {}
  for _, t in pairs(ns.trackers) do for _, cid in ipairs(t.counters) do listed[cid] = true end end
  local out = {}
  for id, s in pairs(sizes) do
    if not ns.counters[id] and not listed[id] then
      local title, pack, why = ns.CounterName(id)
      out[#out + 1] = { id = id, bytes = s.bytes, title = title, pack = pack, why = why }
    end
  end
  table.sort(out, function(a, b)
    if a.pack ~= b.pack then return a.pack < b.pack end
    if a.title ~= b.title then return a.title < b.title end
    return a.id < b.id
  end)
  return out
end

-- a profile switch replaces ns.settings: recompute what runs
local previous = ns.OnSettingsChanged
function ns.OnSettingsChanged()
  if previous then previous() end
  changed()
end

-- A counter no tracker lists is never active: a pack bug, reported once all addons have loaded.
local checked = false
ns.On("PLAYER_ENTERING_WORLD", function()
  if checked or not ns.ready then return end
  checked = true
  local listed = {}
  for _, t in pairs(ns.trackers) do for _, cid in ipairs(t.counters) do listed[cid] = true end end
  for _, id in ipairs(ns.counterOrder) do
    if id ~= ns.TIME_ID and not listed[id] then
      ns.Count("counterWithoutTracker")
      ns.Log("warn", ns.counters[id].ownerTag or "HC", "counter %s is in no tracker, so it never counts (RegisterTracker)", id)
    end
  end
end)
