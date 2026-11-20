-- Basics (TRACKERS_AND_BOARDS §4, HC-21): gold and XP per hour, shipped with Hard Counters itself (the user's
-- decision, 2026-11-15). Written ONLY against the public API (the global HardCounters), so it is also the reference
-- pack for authors: counters, trackers, sources with feeds, readings (computed ones too) and attributors.
--
-- Money and XP are state diffs (GetMoney, UnitXP): the truth. Where they came from (loot, quest, vendor...) is
-- "none" ("Unknown") unless a pack supplies an attributor: HardCounters:SetAttributor(counterId, fn). Basics hands
-- each change to it as fn(amount, t, book); the attributor calls book(amount, source) for all or part of it, now or
-- later (Farmer matches chat lines that arrive just before or after PLAYER_MONEY). Whatever isn't booked within
-- ATTR_TIMEOUT seconds is booked as "none", so nothing is ever lost or counted twice.
-- Mail between your own characters counts on both sides, gold/h included (Farmer DESIGN §4.1, user, 2026-11-15).
local HC = HardCounters
if not HC then return end

local GetTime, GetMoney, UnitXP, UnitXPMax, UnitLevel = GetTime, GetMoney, UnitXP, UnitXPMax, UnitLevel
local GetXPExhaustion = GetXPExhaustion
local After = C_Timer and C_Timer.After
local type, pcall = type, pcall

local IN, OUT, OWNED, XP = "hc:money.in", "hc:money.out", "hc:money.owned", "hc:xp"
--- Seconds Basics waits for an attributor's answer before booking the rest as "none" (TRACKERS_AND_BOARDS §11.1,
--- settled with Farmer's attribution tests: its window is 2 s and its expiry check runs at 2.25 s).
local ATTR_TIMEOUT = 5

local function zone() return { name = "zone", cap = 64 } end
local DIFF = { status = "unverified", ref = "api-surface.md#economy-and-progression",
  note = "the total is exact (a state diff); sources need an attributor (Farmer), else they read Unknown" }

---------------------------------------------------------------------------
-- Counters (moved from Farmer, same shapes)
---------------------------------------------------------------------------

HC:RegisterCounter({ id = IN, version = 1, kind = "flow", unit = "copper", measures = { "sum", "count", "max" },
  dimensions = { { name = "source", cap = 16 }, zone() }, aggregations = { {}, { "source" }, { "zone" } },
  context = { max = { "zone" } }, title = "Money in", category = "Economy", formatter = "money", accuracy = "exact",
  capture = { mode = "snapshot-diff", source = "PLAYER_MONEY + GetMoney()" }, feasibility = DIFF,
  runBreakdowns = { "source" }, liveRate = true })

HC:RegisterCounter({ id = OUT, version = 1, kind = "flow", unit = "copper", measures = { "sum", "count", "max" },
  dimensions = { { name = "sink", cap = 16 }, zone() }, aggregations = { {}, { "sink" }, { "zone" } },
  context = { max = { "zone" } }, title = "Money out", category = "Economy", formatter = "money", accuracy = "exact",
  capture = { mode = "snapshot-diff", source = "PLAYER_MONEY + GetMoney()" }, feasibility = DIFF,
  runBreakdowns = { "sink" } })

HC:RegisterCounter({ id = OWNED, version = 1, kind = "stock", unit = "copper", measures = { "last", "min", "max", "twa" },
  title = "Gold owned", category = "Economy", formatter = "money", accuracy = "exact",
  capture = { mode = "pull-snapshot", source = "GetMoney()" }, feasibility = { status = "unverified" } })

HC:RegisterCounter({ id = XP, version = 1, kind = "flow", unit = "xp", measures = { "sum", "count" },
  dimensions = { { name = "source", cap = 8 }, zone() }, aggregations = { {}, { "source" }, { "zone" } },
  title = "Experience", category = "Progression", formatter = "number", accuracy = "exact",
  capture = { mode = "snapshot-diff", source = "PLAYER_XP_UPDATE + UnitXP()" }, feasibility = DIFF,
  runBreakdowns = { "source" }, liveRate = true })

---------------------------------------------------------------------------
-- Trackers: the two starters, on for a fresh install (TRACKERS_AND_BOARDS §0.3), history off
---------------------------------------------------------------------------

HC:RegisterTracker("hc:goldph", { title = "Gold per hour", category = "Basics", icon = 133784,
  counters = { IN, OUT, OWNED }, default = "on",
  description = "Money looted and earned, and spent, per active hour: this run, this login, or by day with history." })
HC:RegisterTracker("hc:xpph", { title = "XP per hour", category = "Basics", icon = 894556,
  counters = { XP }, default = "on",
  description = "Experience per active hour, time to level and rested XP." })

---------------------------------------------------------------------------
-- Attribution plumbing: hand a change to the attributor, book what it answers, time out the rest
---------------------------------------------------------------------------

local pending = { [IN] = { amount = 0, t = 0 }, [OUT] = { amount = 0, t = 0 }, [XP] = { amount = 0, t = 0 } }
local ctx = {}            -- reused: zone comes from the dimension
local overbooked = 0

local function emit(id, amount, source)
  if id == XP then HC:Emit(id, amount, source, HC:ZoneKey())
  else HC:EmitCtx(id, amount, ctx, source, HC:ZoneKey()) end
end

local function makeBook(id)
  local p = pending[id]
  return function(amount, source)
    if type(amount) ~= "number" or amount <= 0 then return end
    if amount > p.amount then
      overbooked = overbooked + (amount - p.amount)   -- an attributor booking more than it was given: never count it
      amount = p.amount
    end
    if amount <= 0 then return end
    p.amount = p.amount - amount
    emit(id, amount, type(source) == "string" and source ~= "" and source or "none")
  end
end
local book = { [IN] = makeBook(IN), [OUT] = makeBook(OUT), [XP] = makeBook(XP) }

local timing = false
local function expire()
  timing = false
  local now = GetTime()
  local waiting = false
  for id, p in pairs(pending) do
    if p.amount > 0 then
      if now - p.t >= ATTR_TIMEOUT then book[id](p.amount, "none") else waiting = true end
    end
  end
  if waiting then
    timing = true
    After(1, expire)
  end
end

local function hand(id, amount)
  local fn = HC:GetAttributor(id)
  if not fn then emit(id, amount, "none"); return end
  local p = pending[id]
  local t = GetTime()
  p.amount = p.amount + amount
  p.t = t
  local ok = pcall(fn, amount, t, book[id])
  if not ok then book[id](p.amount, "none"); return end
  if p.amount > 0 and not timing and After then
    timing = true
    After(ATTR_TIMEOUT, expire)
  end
end

--- For tests and diagnostics: what is waiting for an attributor's answer, and how much was over-booked.
function HC:_BasicsPending() -- luacheck: ignore 122 (a test and diagnostics hook, private by its underscore)
  return pending[IN].amount, pending[OUT].amount, pending[XP].amount, overbooked
end

---------------------------------------------------------------------------
-- Sources
---------------------------------------------------------------------------

local lastMoney
local function readMoney()
  local m = GetMoney()
  if not HC:Readable(m) or type(m) ~= "number" then return nil end
  return m
end

HC:RegisterSource("hc:money", { mode = "event", events = { "PLAYER_MONEY", "PLAYER_ENTERING_WORLD" },
  feeds = { IN, OUT, OWNED }, handler = function(event)
    local m = readMoney()
    if not m then return end
    if event == "PLAYER_MONEY" and lastMoney then
      local d = m - lastMoney
      if d > 0 then hand(IN, d) elseif d < 0 then hand(OUT, -d) end
    end
    lastMoney = m                 -- the first reading (login, or the tracker just switched on) is a baseline
    HC:Observe(OWNED, m)
  end })

--- XP gained between two readings, across at most one level-up (the previous level's max is known).
local function xpDelta(lastXP, lastMax, lastLevel, xp, level)
  if not (lastXP and lastMax and lastLevel and xp and level) then return 0 end
  if level == lastLevel then
    -- XP never goes down within a level; a drop means a ding that UnitLevel hasn't caught up with yet
    if xp < lastXP then return (lastMax - lastXP) + xp end
    return xp - lastXP
  elseif level == lastLevel + 1 then
    local d = (lastMax - lastXP) + xp
    return d > 0 and d or 0
  end
  return 0 -- several levels at once (or a level reset): unknown, don't guess
end

local lastXP, lastMax, lastLevel
local function readXP()
  local a, m, l = UnitXP("player"), UnitXPMax("player"), UnitLevel("player")
  if not HC:Readable(a, m, l) then return nil end
  return a, m, l
end

HC:RegisterSource("hc:xp", { mode = "event", events = { "PLAYER_XP_UPDATE", "PLAYER_ENTERING_WORLD" },
  feeds = { XP }, handler = function(event, unit)
    if event == "PLAYER_XP_UPDATE" and unit and unit ~= "player" then return end
    local a, m, l = readXP()
    if not a then return end
    if event == "PLAYER_XP_UPDATE" then
      local d = xpDelta(lastXP, lastMax, lastLevel, a, l)
      if d > 0 then hand(XP, d) end
    end
    lastXP, lastMax, lastLevel = a, m, l
  end })

-- Switching a tracker back on starts a fresh baseline: what changed while it was off is a gap, never a gain.
local owner = {}
HC.RegisterCallback(owner, "HC_TRACKERS_CHANGED", function()
  local st = HC:CounterState(IN)
  local stOut, stOwned = HC:CounterState(OUT), HC:CounterState(OWNED)
  if (st and st.active) or (stOut and stOut.active) or (stOwned and stOwned.active) then
    if lastMoney == nil then lastMoney = readMoney() end
  else
    lastMoney = nil
  end
  local sx = HC:CounterState(XP)
  if sx and sx.active then
    if lastXP == nil then lastXP, lastMax, lastLevel = readXP() end
  else
    lastXP, lastMax, lastLevel = nil, nil, nil
  end
end)

---------------------------------------------------------------------------
-- Readings (what a board can show)
---------------------------------------------------------------------------

local ALL = { "run", "session", "today", "week", "month", "year", "lifetime" }

-- One reading per thing counted; per hour is the tile's calc (DESIGN 16.9, HC-51). The old per-hour twins
-- (hc:goldph, hc:netph, hc:xpph) stay as hidden aliases: HC:Reading("hc:goldph", scope) keeps its value, and the run
-- list and the launcher keep showing them.
HC:RegisterReading("hc:gold", { title = "Gold earned", rateTitle = "Gold/h", tracker = "hc:goldph", counter = IN,
  scopes = ALL, formatter = "money", order = 20, description = "Money looted and earned." })
HC:RegisterReading("hc:net", { title = "Net gold", rateTitle = "Net gold/h", tracker = "hc:goldph", counter = IN,
  minus = OUT, scopes = ALL, formatter = "money", order = 21, description = "Money in minus money out." })
HC:RegisterReading("hc:goldph", { aliasOf = "hc:gold", calc = "perHour", headline = true, order = 10,
  description = "Money looted and earned per active hour (AFK and loading screens don't count)." })
HC:RegisterReading("hc:netph", { aliasOf = "hc:net", calc = "perHour", order = 11,
  description = "Money in minus money out, per active hour." })
-- Readings with a parameter (DESIGN 16.4): one source or sink, picked on the tile. Sources and sinks are named by
-- a pack (Farmer's attributors); without one everything is "none".
HC:RegisterReading("hc:goldfrom", { title = "Gold from %s", tracker = "hc:goldph", counter = IN,
  param = { dim = "source", type = "enum" }, scopes = ALL, formatter = "money", order = 26,
  description = "Money earned from one source (loot, quests, vendor, mail...)." })
HC:RegisterReading("hc:spenton", { title = "Spent on %s", tracker = "hc:goldph", counter = OUT,
  param = { dim = "sink", type = "enum" }, scopes = ALL, formatter = "money", order = 27,
  description = "Money spent on one thing (repairs, vendor, training, mail...)." })
HC:RegisterReading("hc:xpgained", { title = "XP gained", rateTitle = "XP/h", tracker = "hc:xpph", counter = XP,
  scopes = ALL, formatter = "number", order = 22, description = "Experience gained." })
HC:RegisterReading("hc:xpph", { aliasOf = "hc:xpgained", calc = "perHour", headline = true, order = 12,
  description = "Experience per active hour." })

HC:RegisterReading("hc:ttl", { title = "Time to level", tracker = "hc:xpph", scopes = { "run", "session" },
  formatter = "duration", order = 23, inputs = { "hc:xpph" },
  calcs = { "total", "recent" }, recentTitle = "Time to level (current pace)",
  description = "XP left in this level divided by your XP per hour over the same scope (or your recent XP per hour).",
  compute = function(get, _, _, calc)
    -- (HC-52) "total": at your average pace over the scope; "recent": at your recent pace
    local rate = get("hc:xpph", nil, calc == "recent" and "recent" or nil)
    if not rate or rate <= 0 then return nil end
    local a, m = UnitXP("player"), UnitXPMax("player")
    if not HC:Readable(a, m) or type(a) ~= "number" or type(m) ~= "number" or m <= 0 then return nil end
    return (m - a) / rate * 3600
  end })

HC:RegisterReading("hc:rested", { title = "Rested XP", tracker = "hc:xpph", scopes = { "now" },
  formatter = "number", order = 24, description = "Rested bonus experience left (double XP from kills).",
  compute = function()
    if not GetXPExhaustion then return nil end
    local r = GetXPExhaustion()
    if r == nil then return 0 end
    if not HC:Readable(r) or type(r) ~= "number" then return nil end
    return r
  end })

-- A value with a natural target (DESIGN 16.6, HC-33): made for the bar style. No counter: read when asked, and
-- redrawn on the XP events while it is on a board.
HC:RegisterReading("hc:xplevel", { title = "XP this level", tracker = "hc:xpph", scopes = { "now" },
  formatter = "number", order = 25, refresh = { "PLAYER_XP_UPDATE", "PLAYER_LEVEL_UP" },
  description = "Experience in this level; as a bar it fills toward the next level.",
  compute = function()
    local a = UnitXP("player")
    if not HC:Readable(a) or type(a) ~= "number" then return nil end
    return a
  end,
  target = function()
    local m = UnitXPMax("player")
    if not HC:Readable(m) or type(m) ~= "number" or m <= 0 then return nil end
    return m
  end })

HC:RegisterReading("hc:owned", { title = "Gold owned", tracker = "hc:goldph", counter = OWNED,
  scopes = { "now", "today", "week", "month", "year", "lifetime" }, formatter = "money", order = 25,
  description = "The gold this character has (with history: its last value in that period)." })
