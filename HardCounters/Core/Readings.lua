-- Readings (TRACKERS_AND_BOARDS §5, HC-17): one number a board can show. A reading is a counter (or a computation
-- over other readings), a measure and a choice of scopes, declared by a pack as data:
--
--   HardCounters:RegisterReading("hc:goldph", { title = "Gold/h", tracker = "hc:goldph",
--     counter = "hc:money.in", per = "activeHour", scopes = { "run", "session", "today", "week" },
--     formatter = "money", headline = true, order = 10,
--     description = "Money looted and earned per active hour (AFK time excluded)." })
--   local value, text, settled, state = HardCounters:Reading("hc:goldph", "session")
--
-- Scopes, and where their numbers come from (all hot data: no reading ever touches closed buckets):
--   run      the open run: a window over the odometers (Runs.lua, Odometer.lua)
--   session  the session window over the odometers (Odometer.lua): a /reload carries on, a login starts over
--            ("login" until HC-49, 2026-11-19: the player sees "session", so the code says it too)
--   today, week, month, year, lifetime   the open bucket of that grain in storage (needs history of that grain)
--   now      a stock's last value, from its odometer (gold owned, a character stat): kept across logins
-- A computed reading has `compute(get, scope)` instead of a counter: get(readingId[, scope]) returns another
-- reading's value (nil when it has none), so derived numbers (time to level) are never stored.
--
-- The calc (DESIGN §16.9, HC-51): which number of a reading over its scope. `total` (the scope's value) or
-- `perHour` (÷ active time over the same scope). Flows allow both, stocks `total`; a `compute` reading lists its
-- `calcs` and receives the calc. A reading registered with `per = "activeHour"` defaults to perHour. An alias
-- (`aliasOf` + `calc`: "hc:goldph" is "hc:gold" per hour) is hidden from the catalog and reads as its target.
local ADDON, ns = ...

local HC, U = ns.HC, ns.U
local type, ipairs, error, tostring, pcall = type, ipairs, error, tostring, pcall
local format = string.format

ns.readings = {}            -- id -> reading (internal; copies go out); aliases too
ns.allReadingOrder = {}     -- every reading but aliases, in display order (the catalog: + menu, Trackers window)
ns.readingOrder = {}        -- the readings that have a run scope, aliases included (run list, summary card, launcher)
local allIds = {}           -- every id, aliases included
local aliasDefs = {}        -- alias id -> its def (rebuilt when its target is registered again)

--- The calcs (DESIGN §16.9), in menu order.
ns.CALC_ORDER = { "total", "perHour", "recent", "trend" }
local CALCS = { total = true, perHour = true, recent = true, trend = true }
ns.CALCS = CALCS
local ONLY_TOTAL = { "total" }
local FLOW_CALCS = { "total", "perHour", "recent", "trend" }
local ONLY_RATE = { "perHour", "recent", "trend" }
--- trend (HC-53): inside this band (in %) it is shown neutral (user, 2026-11-19: ±10%)
ns.TREND_BAND = 10
--- Calcs that are rates: the text ends in "/h" (not for a computed reading: its formatter says what it is).
local RATE_CALC = { perHour = true, recent = true }
ns.RATE_CALC = RATE_CALC
--- Scopes that are windows with their own clock: `recent` is kept only there (HC-52; on a calendar period it would
--- equal the session's).
local CLOCK_SCOPES = { run = true, session = true }

ns.SCOPE_ORDER = { "run", "session", "today", "week", "month", "year", "lifetime", "now" }
local SCOPES = {}
for i, s in ipairs(ns.SCOPE_ORDER) do SCOPES[s] = i end
ns.SCOPES = SCOPES
-- scopes served by storage: the grain whose open bucket answers them ("thisweek" = the player's week choice)
local SCOPE_GRAIN = { today = "day", week = "thisweek", month = "month", year = "year", lifetime = "lifetime" }
ns.SCOPE_GRAIN = SCOPE_GRAIN
-- distance: yards; speed: yards a second, shown as yd/s, or by speedpct as a percentage of the 100% run speed
-- (TR-10; the Traveler decisions of 2026-11-22: yards only, speed in both forms)
local FORMATTERS = { money = true, duration = true, number = true, percent = true, distance = true, speed = true,
  speedpct = true }
ns.RUN_SPEED = 7                                   -- yards a second: 100% speed, the character sheet's convention

--- Display text of a value for a formatter (counters, views and readings): "12g 3s 4c", "1:02:03", "5.2%",
--- "1,234 yd", "7.0 yd/s", "115%" (speedpct: yd/s against 7 yd/s), else a number with thousands separators.
function ns.FormatValue(f, v)
  if type(v) ~= "number" then return "-" end
  if f == "money" then return U.money(v)
  elseif f == "duration" then return U.duration(v)
  elseif f == "percent" then return U.number(v, 1) .. "%"
  elseif f == "distance" then return U.number(v) .. " yd"
  elseif f == "speed" then return U.number(v, 1) .. " yd/s"
  elseif f == "speedpct" then return U.number(v * 100 / ns.RUN_SPEED) .. "%" end
  return U.number(v)
end
-- min, max: a stock's lowest and highest level over the scope, or a flow's smallest and largest single value where
-- something keeps it; avg: a flow's sum / count (HC-27)
local MEASURES = { sum = true, count = true, last = true, min = true, max = true, avg = true }
local PARAM_TYPES = { enum = true, zone = true, item = true, faction = true }
local DEFAULT_SCOPES = { "run", "session" }
local TIME = ns.TIME_ID

--- Active seconds before a per-hour rate settles. Until then one drop swings it (in game 2026-11-15: one 48c item
--- after 99 s read as 17s/h), so displays grey it out; under a minute it is "-".
ns.RATE_SETTLE = 300

local function misuse(fmt, ...)
  error("HardCounters: " .. format(fmt, ...), 3)
end

---------------------------------------------------------------------------
-- Registration
---------------------------------------------------------------------------

local function sortOrder()
  table.sort(allIds, function(a, b)
    local oa, ob = ns.readings[a].order or 100, ns.readings[b].order or 100
    if oa ~= ob then return oa < ob end
    return a < b
  end)
  local all, runs = {}, {}
  for _, id in ipairs(allIds) do
    local r = ns.readings[id]
    if not r.aliasOf then all[#all + 1] = id end
    -- (a reading with a parameter has no single run value: it is left out of the run lists)
    if r.scopeSet.run and not r.param then runs[#runs + 1] = id end
  end
  ns.allReadingOrder = all
  ns.readingOrder = runs
end

--- The calcs a reading allows, in menu order (a shared list: don't change it).
function ns.ReadingCalcs(r)
  if not r then return ONLY_TOTAL end
  if r.calcs then return r.calcs end
  if r.legacyPer then return ONLY_RATE end       -- `per` without a total title: "Fish/h" can't be shown as a total
  if r.compute or r.best then return ONLY_TOTAL end
  local m = r.measure
  if m ~= nil and m ~= "sum" and m ~= "count" then return ONLY_TOTAL end
  local c = r.counter and ns.counters and ns.counters[r.counter]
  if c and c.kind == "stock" then return ONLY_TOTAL end
  return FLOW_CALCS
end

function ns.CalcAllowed(r, calc)
  local list = ns.ReadingCalcs(r)
  for i = 1, #list do if list[i] == calc then return true end end
  return false
end

--- Does a calc the reading allows fit where it is asked? `recent` needs a window with its own clock (the board's
--- timer, the open run, the session), this character, and no zone argument (its rate would need the time in that
--- zone weighted the same way). Returns true, or false and why: "scope", "account", "zone".
function ns.CalcFits(r, calc, scope, who)
  if calc ~= "recent" and calc ~= "trend" then return true end   -- (trend is made of recent)
  if not CLOCK_SCOPES[scope] then return false, "scope" end
  if who == "account" then return false, "account" end
  if r and r.param and r.param.dim == "zone" then return false, "zone" end
  return true
end

--- The calc a reading is read with when none is asked for: its own default (an alias's calc, perHour for `per`),
--- else the first it allows.
function ns.DefaultCalc(r)
  if r and r.defaultCalc then return r.defaultCalc end
  return ns.ReadingCalcs(r)[1]
end

--- Build (or rebuild) an alias's reading from its target's: same counters, scopes and rules, hidden from the
--- catalog, read with its own calc by default.
local function makeAlias(id, def)
  local t = ns.readings[def.aliasOf]
  local a = {}
  for k, v in pairs(t) do a[k] = v end
  a.id, a.aliasOf, a.defaultCalc = id, def.aliasOf, def.calc
  a.totalTitle = t.title
  a.title = def.title or (def.calc == "perHour" and ns.RateTitle(t)) or t.title
  a.headline = def.headline and true or false
  a.order = def.order or t.order
  a.description = def.description or t.description
  return a
end

--- def = { title, counter | compute, tracker, measure ("sum"|"count"|"last"), minus (a second counter subtracted),
---   per = "activeHour", scopes = { ... }, best (the run's best single value, from runLive.max; run scope only),
---   formatter ("money"|"duration"|"number"|"percent"|"distance"|"speed"|"speedpct"), headline, order, description, inputs = { readingId, ... }
---   (what a computed reading reads, for the Trackers window), rateTitle (the per-hour title; default title .. "/h"),
---   calcs = { "total", "perHour" } (a computed reading's: which calcs it answers; default { "total" }) }.
--- Or an alias: def = { aliasOf = readingId, calc = "perHour", title?, headline?, order? } (registered after its
--- target). Returns the id.
function HC:RegisterReading(id, def)
  if not U.validId(id) then misuse("RegisterReading: id must be \"namespace:name\", got %s", tostring(id)) end
  if type(def) ~= "table" then misuse("RegisterReading('%s', def): def must be a table", id) end
  if def.aliasOf ~= nil then
    local t = ns.readings[def.aliasOf]
    if type(def.aliasOf) ~= "string" or not t or t.aliasOf then
      misuse("RegisterReading('%s'): aliasOf must name a registered reading that is no alias", id)
    end
    if def.calc ~= nil and not CALCS[def.calc] then misuse("RegisterReading('%s'): unknown calc '%s'", id, tostring(def.calc)) end
    local d = { aliasOf = def.aliasOf, calc = def.calc or ns.DefaultCalc(t), title = def.title, headline = def.headline,
      order = def.order, description = def.description }
    if not ns.readings[id] then allIds[#allIds + 1] = id end
    aliasDefs[id] = d
    ns.readings[id] = makeAlias(id, d)
    sortOrder()
    if ns.OnReadingsChanged then ns.OnReadingsChanged() end
    return id
  end
  if def.compute ~= nil and type(def.compute) ~= "function" then misuse("RegisterReading('%s'): compute must be a function", id) end
  if def.compute == nil and type(def.counter) ~= "string" then misuse("RegisterReading('%s'): def.counter (or def.compute) is required", id) end
  if def.minus ~= nil and type(def.minus) ~= "string" then misuse("RegisterReading('%s'): minus must be a counter id", id) end
  if def.measure ~= nil and not MEASURES[def.measure] then misuse("RegisterReading('%s'): measure must be sum, count, last, min, max or avg", id) end
  if def.formatter ~= nil and not FORMATTERS[def.formatter] then
    misuse("RegisterReading('%s'): formatter must be money, duration, number, percent, distance, speed or speedpct", id)
  end
  local per = def.per
  if per ~= nil and per ~= "activeHour" then misuse("RegisterReading('%s'): per must be \"activeHour\"", id) end
  local scopes = def.scopes or DEFAULT_SCOPES
  if type(scopes) ~= "table" or #scopes == 0 then misuse("RegisterReading('%s'): scopes must be a non-empty array", id) end
  local list, set = {}, {}
  for _, s in ipairs(scopes) do
    if not SCOPES[s] then misuse("RegisterReading('%s'): unknown scope '%s'", id, tostring(s)) end
    if not set[s] then set[s] = true; list[#list + 1] = s end
  end
  table.sort(list, function(a, b) return SCOPES[a] < SCOPES[b] end)
  if def.best and (#list ~= 1 or list[1] ~= "run") then misuse("RegisterReading('%s'): best readings have the run scope only", id) end
  if def.target ~= nil and type(def.target) ~= "number" and type(def.target) ~= "function" then
    misuse("RegisterReading('%s'): target must be a number or a function", id)
  end
  if def.refresh ~= nil and type(def.refresh) ~= "table" then misuse("RegisterReading('%s'): refresh must be a list of events", id) end
  if def.applies ~= nil and type(def.applies) ~= "function" then misuse("RegisterReading('%s'): applies must be a function", id) end
  if def.stale ~= nil and type(def.stale) ~= "function" then misuse("RegisterReading('%s'): stale must be a function", id) end
  if def.live ~= nil and type(def.live) ~= "function" then misuse("RegisterReading('%s'): live must be a function", id) end
  if def.liveFormat ~= nil and type(def.liveFormat) ~= "string" then misuse("RegisterReading('%s'): liveFormat must be a format string", id) end
  local param
  if def.param ~= nil then
    local p = def.param
    if type(p) ~= "table" or type(p.dim) ~= "string" then misuse("RegisterReading('%s'): param must be { dim = \"dimension\", type = ... }", id) end
    if p.type ~= nil and not PARAM_TYPES[p.type] then misuse("RegisterReading('%s'): param.type must be enum, zone, item or faction", id) end
    if p.label ~= nil and type(p.label) ~= "function" then misuse("RegisterReading('%s'): param.label must be a function", id) end
    if def.best then misuse("RegisterReading('%s'): a best reading takes no param", id) end
    param = { dim = p.dim, type = p.type or "enum", label = p.label }
  end
  if def.rateTitle ~= nil and type(def.rateTitle) ~= "string" then misuse("RegisterReading('%s'): rateTitle must be a string", id) end
  if def.recentTitle ~= nil and type(def.recentTitle) ~= "string" then misuse("RegisterReading('%s'): recentTitle must be a string", id) end
  local calcs
  if def.calcs ~= nil then
    if def.compute == nil then misuse("RegisterReading('%s'): only a computed reading lists its calcs", id) end
    if type(def.calcs) ~= "table" or #def.calcs == 0 then misuse("RegisterReading('%s'): calcs must be a non-empty array", id) end
    calcs = {}
    for _, c in ipairs(ns.CALC_ORDER) do
      for _, d in ipairs(def.calcs) do if d == c then calcs[#calcs + 1] = c; break end end
    end
    for _, d in ipairs(def.calcs) do
      if not CALCS[d] then misuse("RegisterReading('%s'): unknown calc '%s'", id, tostring(d)) end
    end
  end
  local r = {
    id = id, title = def.title or id, tracker = def.tracker, counter = def.counter, measure = def.measure,
    minus = def.minus, scopes = list, scopeSet = set, best = def.best and true or false,
    formatter = def.formatter, headline = def.headline and true or false, order = def.order,
    description = def.description, compute = def.compute, inputs = def.inputs and U.copy(def.inputs) or nil,
    param = param, target = def.target, refresh = def.refresh and U.copy(def.refresh) or nil,
    applies = def.applies, stale = def.stale, live = def.live, liveFormat = def.liveFormat,
    rateTitle = def.rateTitle, recentTitle = def.recentTitle, calcs = calcs,
    -- `per = "activeHour"` (before HC-51): per hour by default; with no rateTitle its title is the rate's, so it
    -- offers only perHour
    defaultCalc = per and "perHour" or nil, legacyPer = per and not calcs and def.rateTitle == nil or nil,
  }
  if not ns.readings[id] then allIds[#allIds + 1] = id end
  ns.readings[id] = r
  for aid, d in pairs(aliasDefs) do
    if d.aliasOf == id then ns.readings[aid] = makeAlias(aid, d) end
  end
  sortOrder()
  -- packs load after Hard Counters, whose displays are already drawn by then
  if ns.OnReadingsChanged then ns.OnReadingsChanged() end
  return id
end

local function publicCopy(r)
  local def = ns.DefaultCalc(r)
  return { id = r.id, title = r.title, tracker = r.tracker, counter = r.counter, measure = r.measure, minus = r.minus,
    per = def == "perHour" and "activeHour" or nil,     -- (before HC-51; read `calc` now)
    calc = def, calcs = U.copy(ns.ReadingCalcs(r)), rateTitle = ns.RateTitle(r), aliasOf = r.aliasOf,
    scopes = U.copy(r.scopes), best = r.best, formatter = r.formatter, headline = r.headline,
    order = r.order, description = r.description, computed = r.compute ~= nil, inputs = r.inputs and U.copy(r.inputs),
    param = r.param and { dim = r.param.dim, type = r.param.type } or nil,
    applies = ns.ReadingApplies(r) }   -- (evaluated now: HC-28's rule for this character)
end

function HC:GetReading(id)
  local r = ns.readings[id]
  return r and publicCopy(r) or nil
end

--- Every reading (copies), in display order. filter = { scope = "session", tracker = "hc:goldph", aliases = true }
--- (aliases are left out unless asked for).
function HC:Readings(filter)
  local out = {}
  for _, id in ipairs(filter and filter.aliases and allIds or ns.allReadingOrder) do
    local r = ns.readings[id]
    if not filter or ((not filter.scope or r.scopeSet[filter.scope]) and (not filter.tracker or r.tracker == filter.tracker)) then
      out[#out + 1] = publicCopy(r)
    end
  end
  return out
end

--- The readings that have a run scope (copies, in order): what the run panel shows.
function HC:RunReadings()
  local out = {}
  for _, id in ipairs(ns.readingOrder) do out[#out + 1] = publicCopy(ns.readings[id]) end
  return out
end

---------------------------------------------------------------------------
-- Values
---------------------------------------------------------------------------

--- The storage grain behind a scope ("week" follows the player's week choice), or nil for run/login/now.
function ns.ScopeGrain(scope)
  local g = SCOPE_GRAIN[scope]
  if g == "thisweek" then g = (ns.settings and ns.settings.weekGrain) or "week" end
  return g
end

--- Can storage answer `grain` for this counter? (Its effective history; HC-19 changes what counters keep.)
local function servesGrain(c, grain)
  return c and c.h and c.grainSet and c.grainSet[grain] or false
end
ns.ServesGrain = servesGrain

--- One number of a counter over a scope: value, or nil and a state ("norun", "needs history", "unknown").
--- Allocation-free for run, login and now; a small query for the storage scopes.
-- "account" while a reading is asked for the whole account (DESIGN 16.5, HC-32), else nil: this character
local curWho

--- A stock over the whole account: the sum of each known character's last value (of one member, with dim and
--- key). nil when no character has one: unknown, not zero. Characters never played with Hard Counters loaded are
--- not in it.
local function accountLast(counterId, dim, key)
  local sum
  for _, odo in pairs(ns.SV and ns.SV.odo or {}) do
    local o = odo[counterId]
    local v
    if dim then
      local m = o and o.lb and o.lb[dim]
      v = m and m[key]
    else
      v = o and o.l
    end
    if v ~= nil then sum = (sum or 0) + v end
  end
  return sum
end

--- One number of a counter over a window of ours (HC-27 adds min, max, avg). A stock's min and max are its lowest
--- and highest level over the window (Odometer.lua keeps them as it is observed); a flow's max is its best single
--- value where a window keeps one (a board's w.max, the open run's runLive tallies). Over the account's windows a
--- stock's level is whoever is playing, so min and max have no meaning there: nil.
local function winValue(w, c, counterId, measure)
  if measure == "avg" then
    local n = ns.Win.Total(w, counterId, "count")
    if n == 0 then return nil end
    return ns.Win.Total(w, counterId, "sum") / n
  elseif measure == "min" or measure == "max" then
    if c.kind == "stock" then
      if curWho then return nil end
      return ns.Win.Total(w, counterId, measure)
    end
    if measure == "min" then return nil end
    if w.live then
      local L = w.live[counterId]
      return L and L.max and L.max.v or nil
    end
    local m = w.max and w.max[counterId]
    return type(m) == "table" and m.v or nil
  end
  return ns.Win.Total(w, counterId, measure)
end

local function raw(counterId, measure, scope, w)
  local c = ns.counters[counterId]
  if not c then return nil, "unknown" end
  if scope == "run" then
    local run = w or ns.OpenRun()
    if not run then return nil, "norun" end
    return winValue(run, c, counterId, measure)
  elseif scope == "session" then
    local s = ns.Session()
    if not s then return nil end
    return winValue(s, c, counterId, measure)
  elseif scope == "now" then
    if curWho then return accountLast(counterId) end
    local o = ns.odo[counterId]
    if o and o.l ~= nil then return o.l end
    if servesGrain(c, "lifetime") then
      local rows = ns.db:Query({ counter = counterId, measure = "last", grain = "lifetime" })
      return rows and rows.total
    end
    return nil
  end
  local grain = ns.ScopeGrain(scope)
  if not servesGrain(c, grain) then return nil, "needs history" end
  local rows = ns.db:Query({ counter = counterId, measure = measure, grain = grain, entity = curWho })
  if measure == "min" or measure == "max" or measure == "avg" then
    -- (the counter must declare the measure; an empty period has none)
    if not rows then return nil, "unknown" end
    return rows.total
  end
  local v = rows and rows.total or 0
  if counterId == TIME and ns.PendingActive then v = v + ns.PendingActive() end
  return v
end
ns.RawValue = raw

--- Is `key` missing from a counter's small dimension because the odometer's cap was reached? (Then its writes
--- went to "other": say so, never show 0.)
local function overCap(counterId, dim, key)
  local o = ns.odo[counterId]
  local m = o and o.by and o.by[dim]
  if not m or m[key] ~= nil then return false end
  return ((o.bn and o.bn[dim]) or 0) >= ns.ODO_MEMBER_CAP
end

--- Did storage count `key` in "other" because the dimension's cap was reached before it was first written? (Its
--- member list is full and the key isn't in it. A member never written reads the same then: it could only land in
--- "other".) Asked only for a member that reads 0, and the answer is kept with the value (MEMBER_TTL): the list
--- is a copy.
local function storageCapped(c, dim, key)
  local cap = c.dimCap and c.dimCap[dim]
  if not (cap and ns.db and ns.db.Members) then return false end
  local list = ns.db:Members(c.id, dim)
  if type(list) ~= "table" or #list < cap then return false end
  for i = 1, #list do if list[i] == key then return false end end
  return true
end

-- storage answers for one member, kept a few seconds: a filtered query on a 4,096-member bucket costs ~3 ms
-- (LibGranaryDB BENCHMARKS, HC-31) and a board asks at every redraw
local MEMBER_TTL = 10
local memberCache = {}

--- One member's number of a counter over a scope (DESIGN §16.4): value, or nil and a state ("norun", "needs
--- history", "unknown", "capped" = past a cap, counted in "other"). v1: sums only in our windows.
local function rawMember(counterId, measure, scope, w, dim, key)
  local c = ns.counters[counterId]
  if not c or not c.dimIndex[dim] then return nil, "unknown" end
  if scope == "run" or scope == "session" then
    local win = w
    if scope == "session" then
      win = ns.Session()
    elseif not win then
      win = ns.OpenRun()
      if not win then return nil, "norun" end
    end
    if not win then return nil end
    if measure ~= "sum" then return nil, "unknown" end
    local rl = c.runLive
    if win.live and rl and rl.member == dim then
      -- the open run tallies every member of this dimension itself (items), up to its own cap
      local L = win.live[counterId]
      local v = L and L.m[key]
      if v == nil and L and L.n >= rl.cap then return nil, "capped" end
      return v or 0
    end
    if c.bigDims then ns.WatchMember(counterId, dim, key) end   -- a big dimension counts from the first ask
    local v = ns.Win.MemberTotal(win, counterId, dim, key)
    if v == 0 and overCap(counterId, dim, key) then return nil, "capped" end
    return v
  elseif scope == "now" then
    if curWho then return accountLast(counterId, dim, key) end
    local o = ns.odo[counterId]
    local m = o and o.lb and o.lb[dim]
    return m and m[key] or nil
  end
  local grain = ns.ScopeGrain(scope)
  if not servesGrain(c, grain) then return nil, "needs history" end
  local ck = counterId .. "|" .. measure .. "|" .. grain .. "|" .. dim .. "|" .. tostring(key) .. (curWho and "|account" or "")
  local hit = memberCache[ck]
  local now = ns.wow.now()
  if hit and now - hit.t < MEMBER_TTL then return hit.v, hit.state end
  local rows = ns.db:Query({ counter = counterId, measure = measure, grain = grain, filter = { [dim] = key }, entity = curWho })
  local v, state
  if rows then v = rows.total or 0 else state = "needs history" end   -- no aggregation set holds this dimension
  if v == 0 and storageCapped(c, dim, key) then v, state = nil, "capped" end
  if not hit then hit = {}; memberCache[ck] = hit end
  hit.t, hit.v, hit.state = now, v, state
  return v, state
end
ns.RawMember = rawMember

---------------------------------------------------------------------------
-- Members an account-wide value leaves out (FM-16: money between your own characters moved, nobody earned or
-- spent it). A pack names them; every account-wide sum of that counter, whole or per member, goes without them.
---------------------------------------------------------------------------

local accountExclude = {}     -- counterId -> { { dim, member }, ... }

function HC:ExcludeOnAccount(counterId, dim, member)
  if type(counterId) ~= "string" or type(dim) ~= "string" or member == nil then
    misuse("ExcludeOnAccount(counterId, dim, member): a counter id, a dimension name and a member")
  end
  local list = accountExclude[counterId]
  if not list then list = {}; accountExclude[counterId] = list end
  for i = 1, #list do if list[i][1] == dim and list[i][2] == member then return end end
  list[#list + 1] = { dim, member }
end

--- raw or rawMember (one member when dim is given), less what an account-wide sum leaves out. An excluded member
--- asked for on its own reads 0 over the account.
local function counterValue(id, measure, scope, w, dim, arg)
  local ex = curWho and measure == "sum" and accountExclude[id]
  if dim then
    if ex then
      for i = 1, #ex do if ex[i][1] == dim and ex[i][2] == arg then return 0 end end
    end
    return rawMember(id, measure, scope, w, dim, arg)
  end
  local v, state = raw(id, measure, scope, w)
  if ex and type(v) == "number" then
    for i = 1, #ex do
      local x = rawMember(id, "sum", scope, w, ex[i][1], ex[i][2])
      if type(x) == "number" then v = v - x end
    end
  end
  return v, state
end

---------------------------------------------------------------------------
-- Live in combat by passing the value through (CS-9, answered in game 2026-11-19: a secret handed unchanged to a
-- font string's SetText / SetFormattedText or a StatusBar's SetValue raises no error). A reading that is "stale"
-- may also declare `live = function(arg) return <the game's value, secret or not> end`: a display hands that value
-- straight to its widget with ns.LiveFormat's format, and never compares, adds or concatenates it. Nothing else in
-- Hard Counters ever sees it: HC:Reading still answers with the stale value.
---------------------------------------------------------------------------

--- The value to pass through, or nil (no `live`, it failed or returned nothing).
function ns.ReadingLive(r, arg)
  local f = r and r.live
  if not f then return nil end
  local ok, v = pcall(f, arg)
  if not ok then ns.Count("readingErrors"); return nil end
  if v == nil then return nil end
  return v
end

-- Same decimals as the formatters out of combat (percent: U.number(v, 1)), so the text doesn't jump at combat edges.
local LIVE_FORMAT = { percent = "%.1f%%", number = "%.0f", distance = "%.0f yd", speed = "%.1f yd/s", duration = nil,
  money = nil, speedpct = nil }
--- The format a display passes a live value through: the reading's `liveFormat`, or one for its formatter (money,
--- durations and speedpct need arithmetic to format: none, so no pass-through for them).
function ns.LiveFormat(r)
  if not r then return nil end
  if r.liveFormat then return r.liveFormat end
  return LIVE_FORMAT[r.formatter or "number"]
end

--- For a pack's own display: the value to pass through and its format, or nil. Hand both to a widget
--- (fs:SetFormattedText(format, value), StatusBar:SetValue(value)) and do nothing else with the value: it may be a
--- secret. Only for a reading whose state is "stale".
function HC:ReadingLive(id, arg)
  local r = ns.readings[id]
  local fmt = ns.LiveFormat(r)
  if not fmt then return nil end
  local v = ns.ReadingLive(r, arg)
  if v == nil then return nil end
  return v, fmt
end

--- Is the reading used by this character? (HC-28: `applies = function() return <class can parry> end`.) A reading
--- without the rule always is; a rule that fails counts as a reading error and leaves the reading listed.
function ns.ReadingApplies(r)
  local f = r and r.applies
  if not f then return true end
  local ok, yes = pcall(f)
  if not ok then ns.Count("readingErrors"); return true end
  return yes and true or false
end

function HC:ReadingApplies(id)
  return ns.ReadingApplies(ns.readings[id])
end

--- Display text for a member of a reading's parameter: the pack's own label function, a zone's name, else as is.
function ns.MemberLabel(r, arg)
  if arg == nil then return "?" end
  local p = r and r.param
  if p and p.label then
    local ok, text = pcall(p.label, arg)
    if ok and type(text) == "string" and text ~= "" then return text end
  end
  if p and p.type == "zone" then return HC:ZoneName(arg) end
  return tostring(arg)
end

--- A reading's per-hour title: its `rateTitle`, else its total title .. "/h" ("Gold earned/h" is better named:
--- Basics names its own).
function ns.RateTitle(r)
  if r.rateTitle then return r.rateTitle end
  if r.defaultCalc == "perHour" then return r.title end     -- an alias, or `per` before HC-51: the title is the rate's
  return r.title .. "/h"
end

--- The title for a calc: the reading's own for its default calc, the rate title for perHour, the total title for
--- total (an alias's target's).
local function calcTitle(r, calc)
  if calc == nil or calc == ns.DefaultCalc(r) then return r.title end
  if calc == "perHour" then return ns.RateTitle(r) end
  if calc == "recent" then
    -- "Gold/h recent"; a computed reading names its own ("Time to level (current pace)")
    if r.recentTitle then return r.recentTitle end
    if r.compute then return r.title .. " (recent)" end
    return ns.RateTitle(r) .. " recent"
  end
  if calc == "trend" then
    if r.compute then return r.title .. " (trend)" end
    return ns.RateTitle(r) .. " trend"
  end
  return r.totalTitle or r.title
end

--- A reading's title with its argument and calc: "%s rep" -> "Timbermaw Hold rep"; without %s, "Title: member".
function ns.ReadingTitle(r, arg, calc)
  local title = calcTitle(r, calc)
  if not r.param then return title end
  if arg == nil then return (title:gsub("%%s", "...")) end
  local label = ns.MemberLabel(r, arg)
  if title:find("%%s") then return (title:gsub("%%s", (label:gsub("%%", "%%%%")))) end
  return title .. ": " .. label
end

local readValue
local curScope, curWin, curArg
--- (inside a compute) another reading's value over the same scope, or another; calc: its default when nil
local function get(id, scope, calc)
  local r = ns.readings[id]
  if not r then return nil end
  local s = scope or curScope
  local v = readValue(r, s, s == "run" and curWin or nil, r.param and curArg or nil, curWho, calc)
  return v
end

--- value (nil when there's none), settled (false for a young rate), state (nil, or why there's no value:
--- "scope" = not offered, "norun", "needs history", "unknown", "error", "noarg" = a reading with a parameter asked
--- without an argument, "capped" = the member is past a cap, "inapplicable" = the reading's `applies` says it
--- isn't used by this character, "calc" = the calc isn't one the reading allows). A value can also come with the
--- state "stale" (readValue: the reading's `stale` says it is the last value read, not the current one).
local function readInner(r, scope, w, arg, calc)
  if not r.scopeSet[scope] then return nil, true, "scope" end
  if not ns.CalcAllowed(r, calc) or not ns.CalcFits(r, calc, scope, curWho) then return nil, true, "calc" end
  if r.applies and not ns.ReadingApplies(r) then return nil, true, "inapplicable" end
  if r.param and arg == nil then return nil, true, "noarg" end
  -- switched off (HC-19): its tracker is off, or nothing keeps its counter running. Shown as "off", never 0.
  if r.tracker and ns.trackers and ns.trackers[r.tracker] and not HC:IsTrackerOn(r.tracker) then return nil, true, "off" end
  if r.counter then
    local c = ns.counters[r.counter]
    if c and not c.active then return nil, true, "off" end
  end
  if r.compute then
    local saved, savedWin, savedArg = curScope, curWin, curArg
    curScope, curWin, curArg = scope, w, arg
    local ok, v, settled = pcall(r.compute, get, scope, arg, calc)
    curScope, curWin, curArg = saved, savedWin, savedArg
    if not ok then
      ns.Count("readingErrors")
      return nil, true, "error"
    end
    if type(v) ~= "number" then return nil, settled ~= false end
    return v, settled ~= false
  end
  if r.best then
    -- the best single value: a board's window keeps one per counter (w.max, Runs.lua); else the open run's tallies
    if w and not w.live then
      local m = w.max and w.max[r.counter]
      return type(m) == "table" and m.v or nil, true
    end
    local run = w or ns.OpenRun()
    if not run then return nil, true, "norun" end
    local L = run.live[r.counter]
    return L and L.max and L.max.v or nil, true
  end
  local c = ns.counters[r.counter]
  local measure = r.measure or (c and c.kind == "stock" and "last" or "sum")
  local dim = r.param and r.param.dim
  if calc == "trend" then
    -- (HC-53) recent against per hour over the same scope, in %: not a derivative (that amplifies the noise).
    -- Shown only when both are settled.
    local rec, rs, rst = readInner(r, scope, w, arg, "recent")
    if rst then return nil, true, rst end
    local per, ps = readInner(r, scope, w, arg, "perHour")
    if rec == nil or per == nil or not rs or not ps then return nil, false end
    if per == 0 then return nil, true end
    return (rec / per - 1) * 100, true
  end
  if calc == "recent" then
    -- (HC-52) the window with its own clock: the board's (w), the open run, the session
    local win = w
    if scope == "session" then win = ns.Session()
    elseif not win then
      win = ns.OpenRun()
      if not win then return nil, true, "norun" end
    end
    if not win then return nil, true end
    if dim and c and c.bigDims then ns.WatchMember(r.counter, dim, arg) end   -- a big dimension counts from the first ask
    local v, gains = ns.Win.Recent(win, r.counter, measure, dim, arg)
    if v == nil then return nil, true end
    if r.minus then
      local m = ns.Win.Recent(win, r.minus, measure, dim, arg)
      v = v - (m or 0)
    end
    return v, ns.Win.Active(win) >= ns.RATE_SETTLE and gains >= ns.RECENT_MIN_GAINS
  end
  local v, state = counterValue(r.counter, measure, scope, w, dim, arg)
  if state then return nil, true, state end
  if v == nil then return nil, true end
  if r.minus then
    local m, mstate = counterValue(r.minus, measure, scope, w, dim, arg)
    if mstate then return nil, true, mstate end
    v = v - (m or 0)
  end
  local settled = true
  if calc == "perHour" then
    -- per hour of all active time; for a zone argument, of the time spent in that zone
    local active
    if dim == "zone" then active = rawMember(TIME, "sum", scope, w, "zone", arg)
    else active = raw(TIME, "sum", scope, w) end
    v = U.perHour(v, active)
    settled = (active or 0) >= ns.RATE_SETTLE
  end
  return v, settled
end
--- who: "account" for the whole account (DESIGN §16.5), nil for this character. It changes the storage scopes
--- (every character with history) and `now` (the sum of last known values); our windows count whoever plays.
--- calc: nil for the reading's default (DESIGN §16.9).
function readValue(r, scope, w, arg, who, calc)
  local saved = curWho
  curWho = who
  local v, settled, state = readInner(r, scope, w, arg, calc or ns.DefaultCalc(r))
  curWho = saved
  if v ~= nil and state == nil and r.stale then
    -- (HC-28) the pack says the value is the last one read: shown, marked, with the pack's word for why
    local ok, isStale, why = pcall(r.stale, arg)
    if ok and isStale then return v, settled, "stale", type(why) == "string" and why or nil end
  end
  return v, settled, state
end
ns.ReadingValue = readValue

--- A trend's text, in words (HC-54, user 2026-11-19): "on pace" inside the band, "87% slower", "13% faster", and a
--- multiple from twice the pace up ("2.7× faster", "12× faster"; × is Latin-1, not yet seen in the game's fonts).
local TIMES = "\195\151"
function ns.TrendText(v)
  local st = ns.TrendState(v)
  if st == "flat" then return "on pace" end
  local n = math.floor(math.abs(v) + 0.5)
  if st == "down" then return n .. "% slower" end
  if n < 100 then return n .. "% faster" end
  local x = 1 + v / 100
  local s = x < 10 and string.format("%.1f", x):gsub("%.0$", "") or tostring(math.floor(x + 0.5))
  return s .. TIMES .. " faster"
end

--- "up", "down" or "flat" (inside the dead band, ns.TREND_BAND), for colours and arrows.
function ns.TrendState(v)
  if type(v) ~= "number" then return nil end
  if v >= ns.TREND_BAND then return "up" elseif v <= -ns.TREND_BAND then return "down" end
  return "flat"
end

--- Display text of a reading's value ("-" when there's none); calc: nil for the reading's default ("/h" for
--- perHour and recent, except on a computed reading: its formatter says what it is).
function ns.FormatReading(r, v, calc)
  if v == nil then return "-" end
  if calc == "trend" then return ns.TrendText(v) end
  local text = ns.FormatValue(r.formatter, v)
  if RATE_CALC[calc or ns.DefaultCalc(r)] and not r.compute then text = text .. "/h" end
  return text
end

local function answer(r, calc, v, settled, state, note)
  if state == "off" then return nil, "off", true, state end
  if state == "capped" then return nil, "over the limit", true, state end
  if state == "inapplicable" then return nil, "n/a", true, state end
  return v, ns.FormatReading(r, v, calc), settled, state, note
end

--- A reading's value over a scope (default: its first scope): value, text, settled, state, note. See readValue;
--- note is the pack's word for a "stale" value ("in combat"), else nil.
--- The third argument is `arg` or an options table (HC-51, DESIGN §16.9):
---   HC:Reading("hcfarm:repwith", "session", 576)                       -- arg: the member of a reading's parameter
---   HC:Reading("hc:gold", "session", { calc = "perHour", arg = nil, who = "account" })
--- `calc` is "total" or "perHour" (nil: the reading's default); one the reading doesn't allow gives the state
--- "calc". Reuse the options table if you call this every frame.
--- "run" here is the character's open run; a tile with that scope reads its board's window (ns.ReadingOver).
function HC:Reading(id, scope, arg, who)
  local r = ns.readings[id]
  if not r then return nil, "-", true, "unknown" end
  local calc
  if type(arg) == "table" then arg, who, calc = arg.arg, arg.who, arg.calc end
  scope = scope or r.scopes[1]
  return answer(r, calc, readValue(r, scope, nil, arg, who == "account" and "account" or nil, calc))
end

--- The same over a window of ours (a board's): value, text, settled, state. Never "norun".
function ns.ReadingOver(id, w, arg, who, calc)
  local r = ns.readings[id]
  if not r then return nil, "-", true, "unknown" end
  return answer(r, calc, readValue(r, "run", w, arg, who == "account" and "account" or nil, calc))
end

--- The counters a window must watch to serve a reading: a set, or nil for "all of them" (a computed reading that
--- doesn't declare its inputs). Active time is always in.
function ns.ReadingCounters(id, set, depth)
  local r = ns.readings[id]
  set = set or { [TIME] = true }
  depth = depth or 0
  if not r or depth > 5 then return set end
  if r.counter then set[r.counter] = true end
  if r.minus then set[r.minus] = true end
  if r.compute then
    if not r.inputs then return nil end
    for _, input in ipairs(r.inputs) do
      if not ns.ReadingCounters(input, set, depth + 1) then return nil end
    end
  end
  return set
end

--- The pre-v2 call: the reading over the open run (nil when no run is open), text, settled.
function HC:RunReading(id)
  local r = ns.readings[id]
  if not r then return nil end
  local run = ns.OpenRun()
  if not run then return nil end
  local v, settled = readValue(r, "run")
  return v, ns.FormatReading(r, v), settled
end

---------------------------------------------------------------------------
-- Targets and live values (DESIGN 16.6, HC-33)
---------------------------------------------------------------------------

--- A reading's natural target (XP to level, the next reputation standing): its `target` number, or what its
--- `target(arg)` function returns; nil when it has none or the function fails. A tile may set its own instead.
function ns.ReadingTarget(r, arg)
  local t = r and r.target
  if type(t) == "function" then
    local ok, v = pcall(t, arg)
    t = ok and v or nil
  end
  if type(t) ~= "number" or t ~= t or t <= 0 then return nil end
  return t
end

function HC:ReadingTarget(id, arg)
  return ns.ReadingTarget(ns.readings[id], arg)
end

--- Something a display shows may have changed: displays redraw on the next frame (UI/Boards.lua). The emit path
--- sets ns.dirty itself (Registry.lua); this is for readings with no counter.
function ns.MarkDirty() ns.dirty = true end

-- `refresh = { events }` of a computed reading (a value with no counter: an item count, a reputation standing):
-- the engine listens only while the reading is on a board, and marks displays dirty.
local listening = {}     -- event -> number of placed readings that want it

--- Tell the engine which readings are on screen: `placed` is a set of reading ids. Registers and unregisters the
--- refresh events accordingly.
function ns.SetPlacedReadings(placed)
  local want = {}
  for id in pairs(placed) do
    local r = ns.readings[id]
    if r and r.refresh then
      for _, ev in ipairs(r.refresh) do if type(ev) == "string" then want[ev] = true end end
    end
  end
  for ev in pairs(listening) do
    if not want[ev] then ns.Off(ev, ns.MarkDirty); listening[ev] = nil end
  end
  for ev in pairs(want) do
    if not listening[ev] then ns.On(ev, ns.MarkDirty, "Readings"); listening[ev] = true end
  end
end
