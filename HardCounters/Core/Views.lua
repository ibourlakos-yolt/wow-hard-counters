-- Views (DESIGN §6, HC-4): counter + measure + period (+ range) + breakdown + filter, as data. Packs ship views
-- over a few primitive counters ("herbs per hour" = loot.items filtered by category, per active hour).
--
--   HardCounters:RegisterView("hcfarm:gold.perhour", { counter = "hcfarm:money.in", per = "activeHour",
--     grain = "day", title = "Gold per hour today", formatter = "money" })
--   local rows = HardCounters:Query("hcfarm:gold.perhour", { grain = "week" })   -- overrides on top
--
-- Query fields are LibGranaryDB's (measure, grain, last, range, groupBy, filter, top, order, entity), plus:
--   grain = "thisweek": the player's chosen week ("week" ISO by default, or "resetweek")
--   per = "activeHour": divide by hc:time.active over the same selection (and per zone when grouped by zone)
-- Results are fresh tables (contexts copied); never saved tables. Use QueryAsync for anything that may be big
-- (groupBy over items, cold months): a by-item query over 4,096 members takes ~62 ms synchronously in game.
local ADDON, ns = ...

local HC, U = ns.HC, ns.U
local type, pairs, ipairs, error = type, pairs, ipairs, error

local views, viewOrder = {}, {}
local QUERY_FIELDS = { counter = true, measure = true, grain = true, last = true, range = true, groupBy = true,
  filter = true, top = true, order = true, entity = true, gaps = true, base = true }

function HC:RegisterView(id, def)
  if not U.validId(id) then error("HardCounters: RegisterView: id must be \"namespace:name\"", 2) end
  if type(def) ~= "table" or type(def.counter) ~= "string" then error("HardCounters: RegisterView('" .. id .. "'): def.counter is required", 2) end
  if not views[id] then viewOrder[#viewOrder + 1] = id end
  views[id] = U.deepcopy(def)
  return id
end

function HC:GetView(id)
  return views[id] and U.deepcopy(views[id]) or nil
end

function HC:Views(counterId)
  local out = {}
  for _, id in ipairs(viewOrder) do
    if not counterId or views[id].counter == counterId then out[#out + 1] = id end
  end
  return out
end

local function resolve(view, overrides)
  local def
  if type(view) == "string" then
    def = views[view]
    if not def then return nil, "unknown view " .. view end
  elseif type(view) == "table" then
    def = view
  else
    return nil, "view must be a view id or a table"
  end
  local q, extra = {}, {}
  for k, v in pairs(def) do if QUERY_FIELDS[k] then q[k] = v else extra[k] = v end end
  if overrides then for k, v in pairs(overrides) do if QUERY_FIELDS[k] then q[k] = v else extra[k] = v end end end
  if q.grain == "thisweek" then q.grain = (ns.settings and ns.settings.weekGrain) or "week" end
  if not ns.counters[q.counter] then return nil, "unknown counter " .. tostring(q.counter) end
  return q, extra
end
ns.ResolveView = resolve

--- Copy contexts (zone keys as numbers) and set r.member: the stored member (numbers stay numbers), else the label.
local function copyRows(rows)
  if not rows then return rows end
  for _, r in ipairs(rows) do
    if r.ctx then r.ctx = U.fixCtx(U.copy(r.ctx)) end
    r.member = U.member(r)
  end
  return rows
end

--- Divide by active seconds over the same selection, per hour.
local function perActiveHour(rows, q, cb)
  local tq = { counter = ns.TIME_ID, measure = "sum", grain = q.grain, last = q.last, range = q.range, entity = q.entity }
  if q.groupBy == "zone" then tq.groupBy = "zone" end
  local function apply(t)
    if not t then return rows end
    rows.total = U.perHour(rows.total, t.total)
    if tq.groupBy then
      -- match by zone key: member ids are per counter, zone keys (numbers) are shared
      local byZone = {}
      for _, r in ipairs(t) do byZone[U.member(r)] = r.value end
      for _, r in ipairs(rows) do r.value = U.perHour(r.value, byZone[U.member(r)]) end
    else
      for _, r in ipairs(rows) do r.value = U.perHour(r.value, t.total) end
    end
    rows.per = "activeHour"
    rows.activeSeconds = t.total
    return rows
  end
  if cb then
    return ns.db:QueryAsync(tq, function(t) cb(apply(t)) end)
  end
  return apply(ns.db:Query(tq))
end

--- Run a view (id or table) synchronously. Returns rows (rows.total for the whole selection) or nil, err.
function HC:Query(view, overrides)
  if not ns.db then return nil, "storage not ready" end
  local q, extra = resolve(view, overrides)
  if not q then return nil, extra end
  local rows, err = ns.db:Query(q)
  if not rows then return nil, err end
  copyRows(rows)
  if extra.per == "activeHour" then rows = perActiveHour(rows, q) end
  return rows
end

--- Run a view sliced over frames (2 ms per frame); cb(rows, err) runs later. Returns a job with :Cancel().
function HC:QueryAsync(view, cb, overrides)
  if type(cb) ~= "function" then error("HardCounters: QueryAsync(view, cb): cb must be a function", 2) end
  if not ns.db then cb(nil, "storage not ready"); return { Cancel = function() end } end
  local q, extra = resolve(view, overrides)
  if not q then cb(nil, extra); return { Cancel = function() end } end
  local cancelled, inner = false, nil
  local job = { Cancel = function() cancelled = true; if inner then inner.Cancel() end end }
  inner = ns.db:QueryAsync(q, function(rows, err)
    if cancelled then return end
    if not rows then cb(nil, err); return end
    copyRows(rows)
    if extra.per == "activeHour" then
      inner = perActiveHour(rows, q, function(r) if not cancelled then cb(r) end end)
    else
      cb(rows)
    end
  end)
  return job
end

--- Time series for charts: s.keys[i], s.values[i] (aligned; flows fill gaps with 0, stocks carry forward).
function HC:Series(view, overrides)
  if not ns.db then return nil, "storage not ready" end
  local q, extra = resolve(view, overrides)
  if not q then return nil, extra end
  q.groupBy, q.top, q.order = nil, nil, nil
  return ns.db:Series(q)
end

function HC:SeriesAsync(view, cb, overrides)
  if type(cb) ~= "function" then error("HardCounters: SeriesAsync(view, cb): cb must be a function", 2) end
  if not ns.db then cb(nil, "storage not ready"); return { Cancel = function() end } end
  local q, extra = resolve(view, overrides)
  if not q then cb(nil, extra); return { Cancel = function() end } end
  q.groupBy, q.top, q.order = nil, nil, nil
  return ns.db:SeriesAsync(q, cb)
end

--- Live rate per second over the last `window` seconds (default 600), for counters registered with liveRate.
--- In memory only. Returns rate, total, seconds covered; or nil for counters without liveRate.
function HC:Live(counterId, window)
  local c = ns.counters[counterId]
  if not (c and c.rate) then return nil end
  return c.rate:Rate(window or 600)
end

function HC:PeriodKey(grain, t)
  if not ns.db then return nil end
  if grain == "thisweek" then grain = (ns.settings and ns.settings.weekGrain) or "week" end
  return ns.db:PeriodKey(grain, t)
end

function HC:PeriodInfo(grain, key)
  if not ns.db then return nil end
  if grain == "thisweek" then grain = (ns.settings and ns.settings.weekGrain) or "week" end
  return ns.db:PeriodInfo(grain, key)
end

--- Storage health for this addon's data (LibGranaryDB db:Stats(): sizes, budget, overflows, warnings). A copy.
function HC:StorageStats()
  return ns.db and U.deepcopy(ns.db:Stats()) or nil
end

---------------------------------------------------------------------------
-- Display plugins (DESIGN §7): a display declares the kinds of data it accepts and a factory.
---------------------------------------------------------------------------

ns.displays, ns.displayOrder = {}, {}

--- def = { title, accepts = { "number"|"rate"|"series"|"records" ... }, create = function(parent, opts) -> widget }
function HC:RegisterDisplay(id, def)
  if not U.validId(id) then error("HardCounters: RegisterDisplay: id must be \"namespace:name\"", 2) end
  if type(def) ~= "table" or type(def.create) ~= "function" or type(def.accepts) ~= "table" then
    error("HardCounters: RegisterDisplay('" .. id .. "'): def needs accepts and create", 2)
  end
  if not ns.displays[id] then ns.displayOrder[#ns.displayOrder + 1] = id end
  ns.displays[id] = def
  return id
end

function HC:Displays()
  local out = {}
  for _, id in ipairs(ns.displayOrder) do
    out[#out + 1] = { id = id, title = ns.displays[id].title, accepts = U.copy(ns.displays[id].accepts) }
  end
  return out
end

--- Create a display widget from a registered display; returns the widget or nil, err.
function HC:CreateDisplay(id, parent, opts)
  local def = ns.displays[id]
  if not def then return nil, "unknown display " .. tostring(id) end
  local ok, w = pcall(def.create, parent, opts or {})
  if not ok then ns.Error(w); return nil, w end
  return w
end
