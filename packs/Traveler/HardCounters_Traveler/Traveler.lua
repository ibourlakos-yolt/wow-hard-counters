-- Traveler, first edition (DESIGN §6 phase 1, cut down 2026-11-22: notes packs/Traveler/QUEUE.md has the rest).
-- Distance by every way of changing place, one counter with a `mode` dimension (§0.2 b), legs, top speed,
-- spacebar jumps and falls (§0.2 c), corpse runs (§1.6), flights, dungeon distance estimated out of combat (§0.3).
-- The model is Motion.lua; this file reads the game into it and writes what it reports.
-- Built ONLY on Hard Counters' public API (docs/API.md at the repo root).
local ADDON, ns = ...

local HC = HardCounters
if not HC or (HC.API_VERSION or 0) < 1 or not ns.Motion then return end

local type, pcall, ipairs, pairs, sqrt, tostring = type, pcall, ipairs, pairs, math.sqrt, tostring
local GetTime = GetTime

ns.VERSION = "0.3.0-dev"
local pack = HC:RegisterPack("Traveler", { namespace = "hctravel", version = ns.VERSION, title = "Traveler" })
ns.pack = pack

ns.ID = {
  dist = "hctravel:dist", time = "hctravel:time", jumps = "hctravel:jumps", leg = "hctravel:leg",
  speed = "hctravel:speed", hop = "hctravel:hop", airtime = "hctravel:airtime", corpse = "hctravel:corpse",
  healer = "hctravel:healer", flight = "hctravel:flight",
}
local ID = ns.ID

---------------------------------------------------------------------------
-- Modes (§1.2, §0.2): every way of changing place, in the order the tile's checklist shows them
---------------------------------------------------------------------------

ns.MODES = { "walk", "run", "mounted", "travelform", "aquaticform", "swim", "dive", "flying", "ghost", "taxi",
  "carried", "vehicle", "blink", "leap", "hearth", "teleport", "portal", "summon", "spirit", "instance",
  "transport", "jump" }
ns.MODE_LABEL = {
  walk = "Walking", run = "Running", mounted = "Mounted", travelform = "Travel form", aquaticform = "Aquatic form",
  swim = "Swimming", dive = "Diving", flying = "Flying", ghost = "Corpse runs", taxi = "Flight paths",
  carried = "Boats and lifts", vehicle = "Vehicles", blink = "Blinks", leap = "Leaps", hearth = "Hearthstone",
  teleport = "Teleports", portal = "Portals", summon = "Summons", spirit = "Released spirit",
  instance = "Instance doors", transport = "Boat crossings", jump = "Other jumps",
}
local JUMPS = { "blink", "leap", "hearth", "teleport", "portal", "summon", "spirit", "instance", "transport", "jump" }
local TELEPORTS = { hearth = true, teleport = true, portal = true, summon = true, spirit = true, instance = true,
  transport = true, jump = true }
local function without(list, drop)
  local out = {}
  for _, m in ipairs(list) do if not drop[m] then out[#out + 1] = m end end
  return out
end
local MODE_PRESETS = {
  { name = "On foot", members = { "walk", "run" } },
  { name = "Under my own power", members = { "walk", "run", "mounted", "travelform", "aquaticform", "swim", "dive",
    "flying", "ghost", "blink", "leap" } },
  { name = "Everything but teleports", members = without(ns.MODES, TELEPORTS) },
  { name = "Everything", members = ns.MODES },
}
local function modeLabel(m) return ns.MODE_LABEL[m] or tostring(m) end
local function modeParam(default)
  return { dim = "mode", type = "enum", multi = true, members = ns.MODES, presets = MODE_PRESETS, default = default,
    label = modeLabel }
end
local function jumpParam()
  return { dim = "mode", type = "enum", multi = true, members = JUMPS, label = modeLabel, presets = {
    { name = "Hearthstone", members = { "hearth" } },
    { name = "Teleports", members = { "hearth", "teleport", "portal", "summon" } },
    { name = "Blinks and leaps", members = { "blink", "leap" } },
  } }
end
local AIR_LABEL = { jump = "Jumps", fall = "Falls", float = "Slow falls" }
local function airParam(default)
  return { dim = "kind", type = "enum", multi = true, members = { "jump", "fall", "float" },
    label = function(k) return AIR_LABEL[k] or tostring(k) end, default = default, presets = {
      { name = "Jumps", members = { "jump" } }, { name = "Falls", members = { "fall", "float" } } } }
end

---------------------------------------------------------------------------
-- Counters (DESIGN §2, first edition). Polled four times a second while moving on foot (DESIGN §3.2: say the rate)
---------------------------------------------------------------------------

local POLL = { mode = "poll", source = "UnitPosition, 4 times a second on foot (2 mounted, 1 on a flight)" }
local FEAS = { status = "feasible", note = "position is plain in combat outdoors; none inside dungeons (estimated there, out of combat only)",
  ref = "api-surface.md#movement" }
local function mode(cap) return { name = "mode", cap = cap or 32 } end
local function zone() return { name = "zone", cap = 400 } end

HC:RegisterCounter({ id = ID.dist, version = 1, kind = "flow", unit = "yards", measures = { "sum" },
  dimensions = { mode(), zone() }, aggregations = { {}, { "mode" }, { "zone" }, { "mode", "zone" } },
  title = "Distance travelled", category = "Travel", formatter = "distance", accuracy = "exact", capture = POLL,
  feasibility = FEAS, runBreakdowns = { "mode" } })
HC:RegisterCounter({ id = ID.time, version = 1, kind = "flow", unit = "seconds", measures = { "sum" },
  dimensions = { mode(), zone() }, aggregations = { {}, { "mode" }, { "zone" }, { "mode", "zone" } },
  title = "Time moving", category = "Travel", formatter = "duration", accuracy = "exact", capture = POLL,
  feasibility = FEAS, runBreakdowns = { "mode" } })
HC:RegisterCounter({ id = ID.jumps, version = 1, kind = "flow", unit = "jumps", measures = { "sum" },
  dimensions = { mode() }, aggregations = { {}, { "mode" } }, title = "Teleports and blinks", category = "Travel",
  formatter = "number", accuracy = "exact", capture = POLL, feasibility = FEAS, runBreakdowns = { "mode" } })
HC:RegisterCounter({ id = ID.leg, version = 1, kind = "flow", unit = "yards", measures = { "sum", "count", "max" },
  dimensions = { mode(16) }, aggregations = { {}, { "mode" } }, context = { max = { "zone", "mode", "sec" } },
  title = "Legs (without stopping)", category = "Travel", formatter = "distance", accuracy = "exact", capture = POLL,
  feasibility = FEAS, runLive = { max = true } })
HC:RegisterCounter({ id = ID.speed, version = 1, kind = "flow", unit = "yd/s", measures = { "max" },
  dimensions = { mode(16) }, aggregations = { {}, { "mode" } }, context = { max = { "zone", "mode" } },
  title = "Top speed", category = "Travel", formatter = "speed", accuracy = "exact", capture = POLL,
  feasibility = FEAS, runLive = { max = true } })
HC:RegisterCounter({ id = ID.hop, version = 1, kind = "flow", unit = "jumps", measures = { "sum" },
  dimensions = { { name = "kind", cap = 4 }, mode() }, aggregations = { {}, { "kind" }, { "kind", "mode" } },
  title = "Jumps and falls", category = "Travel", formatter = "number", accuracy = "exact",
  capture = { mode = "hook", source = "JumpOrAscendStart (a secure post-hook) and IsFalling" }, feasibility = FEAS,
  runBreakdowns = { "kind" } })
HC:RegisterCounter({ id = ID.airtime, version = 1, kind = "flow", unit = "seconds", measures = { "sum", "max" },
  dimensions = { { name = "kind", cap = 4 } }, aggregations = { {}, { "kind" } }, title = "Time in the air",
  category = "Travel", formatter = "duration", accuracy = "estimate", capture = POLL, feasibility = FEAS,
  runBreakdowns = { "kind" }, runLive = { max = true } })
HC:RegisterCounter({ id = ID.corpse, version = 1, kind = "flow", unit = "runs", measures = { "sum" },
  title = "Corpse runs", category = "Travel", formatter = "number", accuracy = "exact", capture = POLL,
  feasibility = { status = "unverified", note = "deaths not yet seen in game (TR-6)" } })
HC:RegisterCounter({ id = ID.healer, version = 1, kind = "flow", unit = "visits", measures = { "sum" },
  title = "Spirit healer visits", category = "Travel", formatter = "number", accuracy = "exact", capture = POLL,
  feasibility = { status = "unverified", note = "deaths not yet seen in game (TR-6)" } })
HC:RegisterCounter({ id = ID.flight, version = 1, kind = "flow", unit = "yards", measures = { "sum", "count", "max" },
  dimensions = { { name = "from", cap = 300 }, { name = "to", cap = 300 } },
  aggregations = { {}, { "from" }, { "to" }, { "from", "to" } }, context = { max = { "from", "to", "sec" } },
  title = "Flights", category = "Travel", formatter = "distance", accuracy = "exact", capture = POLL,
  feasibility = FEAS, runLive = { max = true } })

local DIST_COUNTERS = { ID.dist, ID.time, ID.jumps, ID.leg, ID.speed, ID.hop, ID.airtime, ID.corpse, ID.healer }
HC:RegisterTracker("hctravel:distance", { title = "Distance", category = "Travel", icon = 132307,
  counters = DIST_COUNTERS, default = "off",
  description = "How far you travel and how: on foot, mounted, swimming, flight paths, boats, blinks and teleports; jumps, falls and corpse runs." })
HC:RegisterTracker("hctravel:flights", { title = "Flights", category = "Travel", icon = 132239,
  counters = { ID.flight }, default = "off", description = "Flight paths taken: how many, how far, the longest." })

---------------------------------------------------------------------------
-- Reading the game into a sample (no allocation per tick: one table, refilled)
---------------------------------------------------------------------------

local function plain(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, v = pcall(fn, ...)
  if not ok or not HC:Readable(v) then return nil end
  return v
end

-- spells by kind: Classic's IDs, and their localized names (Forever's IDs may differ; a name match catches those)
local SPELLS = {
  hearth = { 8690, 556 },                                            -- Hearthstone, Astral Recall
  teleport = { 3561, 3562, 3563, 3565, 3566, 3567, 18960 },           -- mage teleports, Teleport: Moonglade
  blink = { 1953 },                                                   -- Blink
  leap = { 100, 6178, 11578, 20252, 20616, 20617, 16979 },            -- Charge, Intercept, Feral Charge
  travelform = { 783, 2645 },                                         -- Travel Form, Ghost Wolf
  aquaticform = { 1066 },                                             -- Aquatic Form
  float = { 130, 1706 },                                              -- Slow Fall, Levitate
}
local byId, byName = {}, nil
for kind, ids in pairs(SPELLS) do for _, id in ipairs(ids) do byId[id] = kind end end
ns.SPELLS = SPELLS

local function spellName(id)
  local fn = (_G.C_Spell and _G.C_Spell.GetSpellName) or _G.GetSpellInfo
  local n = plain(fn, id)
  return type(n) == "string" and n ~= "" and n or nil
end

--- The kind of a spell: by ID, else by its name against the names of the known IDs (built once, lazily: spell
--- data may not be there at load).
local function spellKind(id)
  local k = byId[id]
  if k then return k end
  if not byName then
    byName = {}
    for kind, ids in pairs(SPELLS) do
      for _, sid in ipairs(ids) do
        local n = spellName(sid)
        if n then byName[n] = kind end
      end
    end
  end
  local n = spellName(id)
  return n and byName[n] or nil
end
ns.SpellKind = spellKind

-- The shapeshift form as a mode (§0.2 d). On Forever a paladin's auras are shapeshift forms too (TR-6, 2026-11-22),
-- so a form is a travel form only by its spell.
local function formKind()
  local idx = plain(_G.GetShapeshiftForm)
  if type(idx) ~= "number" or idx <= 0 or type(_G.GetShapeshiftFormInfo) ~= "function" then return nil end
  local ok, _, _, _, spell = pcall(_G.GetShapeshiftFormInfo, idx)
  if not ok or type(spell) ~= "number" or not HC:Readable(spell) then return nil end
  local k = spellKind(spell)
  if k == "travelform" then return "travel" elseif k == "aquaticform" then return "aquatic" end
  return nil
end

--- A slow-fall aura (out of combat: auras are not readable in a fight, TR-6).
local function floating()
  local get = _G.C_UnitAuras and _G.C_UnitAuras.GetPlayerAuraBySpellID
  if type(get) ~= "function" then return false end
  for _, id in ipairs(SPELLS.float) do
    local a = plain(get, id)
    if type(a) == "table" then return true end
  end
  return false
end

local s = {}
local function flag(fn) return plain(fn, "player") == true end

local function fill(t)
  s.t = t
  local ok, y, x, _, inst = pcall(_G.UnitPosition, "player")
  if ok and type(x) == "number" and type(y) == "number" and HC:Readable(x, y, inst) then
    s.x, s.y, s.cont = x, y, inst
  else
    s.x, s.y, s.cont = nil, nil, nil
  end
  s.zone = HC:ZoneKey()
  s.inst = s.zone >= 100000
  s.taxi, s.vehicle, s.ghost = flag(_G.UnitOnTaxi), flag(_G.UnitInVehicle), flag(_G.UnitIsGhost)
  s.flying, s.swim, s.dive = plain(_G.IsFlying) == true, plain(_G.IsSwimming) == true, plain(_G.IsSubmerged) == true
  s.mounted, s.falling = plain(_G.IsMounted) == true, plain(_G.IsFalling) == true
  s.form = formKind()
  local okS, cur, run = pcall(_G.GetUnitSpeed, "player")
  if okS and type(cur) == "number" and HC:Readable(cur, run) then s.speed, s.run = cur, run else s.speed, s.run = nil, nil end
  s.float = s.falling and s.speed ~= nil and floating()                 -- s.speed readable: out of combat
  return s
end
ns.Fill = fill

---------------------------------------------------------------------------
-- The corpse (§1.6): both positions through the same map call, so their axes agree
---------------------------------------------------------------------------

local function worldXY(map, pos)
  local toWorld = _G.C_Map and _G.C_Map.GetWorldPosFromMapPos
  if type(toWorld) ~= "function" or pos == nil or not HC:Readable(pos) then return nil end
  local ok, cont, wp = pcall(toWorld, map, pos)
  if not ok or type(wp) ~= "table" then return nil end
  local x, y = wp.x, wp.y
  if type(x) ~= "number" and type(wp.GetXY) == "function" then x, y = wp:GetXY() end
  if type(x) ~= "number" or not HC:Readable(x, y) then return nil end
  return x, y, cont
end

--- Yards from the player to the corpse, or nil (not a ghost, or the game doesn't say).
local function corpseDistance()
  if not flag(_G.UnitIsGhost) then return nil end
  local C_Map, C_DeathInfo = _G.C_Map, _G.C_DeathInfo
  if not (C_Map and C_DeathInfo and C_DeathInfo.GetCorpseMapPosition) then return nil end
  local map = plain(C_Map.GetBestMapForUnit, "player")
  if type(map) ~= "number" then return nil end
  local cx, cy, cc = worldXY(map, plain(C_DeathInfo.GetCorpseMapPosition, map))
  local px, py, pc = worldXY(map, plain(C_Map.GetPlayerMapPosition, map, "player"))
  if not cx or not px or cc ~= pc then return nil end
  local dx, dy = px - cx, py - cy
  return sqrt(dx * dx + dy * dy)
end
ns.CorpseDistance = corpseDistance

---------------------------------------------------------------------------
-- Flights: where from and to (taxi node IDs, numbers; names kept for this session only, for labels)
---------------------------------------------------------------------------

local nodeNames = {}
local route = { from = 0, to = 0 }

local function taxiNodes()
  local all = _G.C_TaxiMap and _G.C_TaxiMap.GetAllTaxiNodes
  local map = plain(_G.GetTaxiMapID)
  if type(map) ~= "number" then map = plain(_G.C_Map and _G.C_Map.GetBestMapForUnit, "player") end
  if type(all) ~= "function" or type(map) ~= "number" then return nil end
  local ok, list = pcall(all, map)
  if not ok or type(list) ~= "table" then return nil end
  for _, node in ipairs(list) do
    if type(node) == "table" and type(node.nodeID) == "number" and type(node.name) == "string" then
      nodeNames[node.nodeID] = node.name
    end
  end
  return list
end

local function takeTaxi(slot)
  local list = taxiNodes()
  route.from, route.to = 0, 0
  if not list then return end
  for _, node in ipairs(list) do
    if type(node) == "table" and type(node.nodeID) == "number" then
      if node.slotIndex == slot then route.to = node.nodeID end
      if node.state == 0 then route.from = node.nodeID end              -- Enum.FlightPathState.Current
    end
  end
end
ns.TakeTaxi = takeTaxi

local function nodeLabel(id)
  if id == 0 then return "Unknown" end
  return nodeNames[id] or ("Flight point " .. tostring(id))
end
ns.NodeLabel = nodeLabel

---------------------------------------------------------------------------
-- The model's reports become the counters' writes
---------------------------------------------------------------------------

local legCtx, speedCtx, flightCtx = {}, {}, {}
local out = {
  move = function(m, yd, sec, z)
    HC:Emit(ID.dist, yd, m, z)
    HC:Emit(ID.time, sec, m, z)
  end,
  jump = function(m, yd, z)
    if yd > 0 then HC:Emit(ID.dist, yd, m, z) end
    HC:Emit(ID.jumps, 1, m)
  end,
  leg = function(m, yd, sec, z)
    legCtx.zone, legCtx.mode, legCtx.sec = z, m, sec
    HC:EmitCtx(ID.leg, yd, legCtx, m)
  end,
  speed = function(m, v, z)
    speedCtx.zone, speedCtx.mode = z, m
    HC:EmitCtx(ID.speed, v, speedCtx, m)
  end,
  hop = function(kind, m) HC:Emit(ID.hop, 1, kind, m) end,
  air = function(kind, sec) if sec > 0 then HC:Emit(ID.airtime, sec, kind) end end,
  death = function(kind) HC:Emit(kind == "healer" and ID.healer or ID.corpse, 1) end,
  flight = function(yd, sec)
    if yd <= 0 then return end
    flightCtx.from, flightCtx.to, flightCtx.sec = route.from, route.to, sec
    HC:EmitCtx(ID.flight, yd, flightCtx, route.from, route.to)
    route.from, route.to = 0, 0
  end,
}
local motion = ns.Motion.new(out)
ns.motion = motion

---------------------------------------------------------------------------
-- Sources: the position poll (adaptive, §1.1), the jump hook, the taxi hook, and the events that name causes
---------------------------------------------------------------------------

local POS = "hctravel:pos"
local interval = 0.25
local function pace(every)
  if every == interval then return end
  interval = every
  HC:SetSourceInterval(POS, every)
end

HC:RegisterSource(POS, { mode = "poll", interval = 0.25, feeds = DIST_COUNTERS, read = function()
  local smp = fill(GetTime())
  if smp.ghost then motion:Corpse(corpseDistance()) end
  motion:Step(smp)
  -- 4 Hz on foot, swimming or in the air (blinks and air time need it), 2 Hz mounted, 1 Hz on a flight, a boat or
  -- standing still (a press or a move brings it back)
  local m = motion.mode
  if smp.falling or m == "walk" or m == "run" or m == "swim" or m == "dive" or m == "ghost" then pace(0.25)
  elseif m == "mounted" or m == "travelform" or m == "aquaticform" or m == "flying" then pace(0.5)
  else pace(1) end
end })
ns.Tick = function() local smp = fill(GetTime()); motion:Step(smp) end

local press = {}
HC:RegisterSource("hctravel:jump", { mode = "hook", hook = "JumpOrAscendStart", feeds = { ID.hop, ID.airtime },
  handler = function()
    press.falling, press.swim, press.taxi = plain(_G.IsFalling) == true, plain(_G.IsSwimming) == true, flag(_G.UnitOnTaxi)
    press.ghost, press.mounted, press.form = flag(_G.UnitIsGhost), plain(_G.IsMounted) == true, formKind()
    if motion:Press(GetTime(), press) then pace(0.25) end
  end })

HC:RegisterSource("hctravel:taxi", { mode = "hook", hook = "TakeTaxiNode", feeds = { ID.flight }, handler = takeTaxi })

HC:RegisterSource("hctravel:events", { mode = "event", feeds = DIST_COUNTERS,
  events = { "UNIT_SPELLCAST_SUCCEEDED", "LOADING_SCREEN_ENABLED", "CONFIRM_SUMMON", "CONFIRM_XP_LOSS", "PLAYER_LOGOUT",
    "TAXIMAP_OPENED" },
  handler = function(event, unit, _, spell)
    local t = GetTime()
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
      if unit ~= "player" or type(spell) ~= "number" or not HC:Readable(spell) then return end
      local kind = spellKind(spell)
      if kind == "hearth" or kind == "teleport" or kind == "blink" or kind == "leap" then motion:Cast(kind, t) end
    elseif event == "LOADING_SCREEN_ENABLED" then motion:Loading()
    elseif event == "CONFIRM_SUMMON" then motion:Summon(t)
    elseif event == "CONFIRM_XP_LOSS" then motion:XPLoss(t)
    elseif event == "PLAYER_LOGOUT" then motion:Close()
    elseif event == "TAXIMAP_OPENED" then taxiNodes()
    end
  end })

---------------------------------------------------------------------------
-- Readings (DESIGN §4, first edition)
---------------------------------------------------------------------------

local ALL = { "run", "session", "today", "week", "month", "year", "lifetime" }
local BEST = { "run", "today", "week", "month", "year", "lifetime" }          -- a best single value: the board's timer or history
local DIST, FLIGHTS = "hctravel:distance", "hctravel:flights"

HC:RegisterReading("hctravel:distance", { title = "Distance travelled", rateTitle = "Distance/h", tracker = DIST,
  counter = ID.dist, param = modeParam("Everything but teleports"), scopes = ALL, formatter = "distance", order = 40,
  description = "Yards travelled, from your position 4 times a second. Pick the ways of travel on the tile (default: everything"
    .. " but teleports). Inside dungeons it is an estimate, out of combat only." })
HC:RegisterReading("hctravel:time", { title = "Time moving", tracker = DIST, counter = ID.time,
  param = modeParam("Everything but teleports"), scopes = ALL, formatter = "duration", order = 41,
  description = "Time spent moving (standing still doesn't count). Pick the ways of travel on the tile. As a Mix it shows how you travel." })
local function avgSpeed(get, scope)
  local d, t = get("hctravel:distance", scope), get("hctravel:time", scope)
  if type(d) ~= "number" or type(t) ~= "number" or t <= 0 then return nil end
  return d / t
end
HC:RegisterReading("hctravel:avgspeed", { title = "Average speed", tracker = DIST, param = modeParam("Everything but teleports"),
  inputs = { "hctravel:distance", "hctravel:time" }, compute = avgSpeed, scopes = ALL, formatter = "speed", order = 42,
  description = "Distance divided by time moving, over the ways of travel picked on the tile." })
HC:RegisterReading("hctravel:avgspeedpct", { title = "Average speed (%)", tracker = DIST, param = modeParam("Everything but teleports"),
  inputs = { "hctravel:distance", "hctravel:time" }, compute = avgSpeed, scopes = ALL, formatter = "speedpct", order = 42.5,
  description = "Average speed as a percentage of the normal run speed (100% = 7 yards a second, as on the character sheet)." })
HC:RegisterReading("hctravel:topspeed", { title = "Top speed", tracker = DIST, counter = ID.speed, measure = "max",
  scopes = BEST, formatter = "speed", order = 43,
  description = "Your best speed over 2 seconds or more under your own power (not flight paths or boats)." })
HC:RegisterReading("hctravel:topspeedpct", { title = "Top speed (%)", tracker = DIST, counter = ID.speed, measure = "max",
  scopes = BEST, formatter = "speedpct", order = 43.5,
  description = "Top speed as a percentage of the normal run speed (100% = 7 yards a second)." })
local function speedNow() return motion:SpeedNow(GetTime()) end
HC:RegisterReading("hctravel:speednow", { title = "Speed now", tracker = DIST, scopes = { "now" }, formatter = "speed",
  compute = speedNow, order = 44,
  description = "How fast you are moving, from your position: it keeps working in combat. Updates while you move." })
HC:RegisterReading("hctravel:speednowpct", { title = "Speed now (%)", tracker = DIST, scopes = { "now" },
  formatter = "speedpct", compute = speedNow, order = 44.5,
  description = "Speed now as a percentage of the normal run speed (100% = 7 yards a second)." })
HC:RegisterReading("hctravel:longest", { title = "Farthest without stopping", tracker = DIST, counter = ID.leg,
  measure = "max", scopes = BEST, formatter = "distance", order = 45,
  description = "The longest stretch under your own power with no stop over 3 seconds and no change of how you travel." })
HC:RegisterReading("hctravel:jumps", { title = "Teleports and blinks", tracker = DIST, counter = ID.jumps,
  param = jumpParam(), scopes = ALL, formatter = "number", order = 46,
  description = "Jumps from place to place: hearthstone, teleports, summons, blinks and leaps, releases, instance doors, boat"
    .. " crossings. Pick which on the tile." })
HC:RegisterReading("hctravel:hops", { title = "Jumps", tracker = DIST, counter = ID.hop, param = airParam("Jumps"),
  scopes = ALL, formatter = "number", order = 47,
  description = "Spacebar jumps from the ground; or, picked on the tile, falls of a second or more (slow falls apart)." })
HC:RegisterReading("hctravel:airtime", { title = "Time in the air", tracker = DIST, counter = ID.airtime,
  param = airParam(nil), scopes = ALL, formatter = "duration", order = 48,
  description = "Time in the air from jumps and falls, measured 4 times a second (about)." })
HC:RegisterReading("hctravel:longestair", { title = "Longest time in the air", tracker = DIST, counter = ID.airtime,
  measure = "max", scopes = BEST, formatter = "duration", order = 48.5,
  description = "Your longest single jump or fall, in seconds in the air (the game gives no heights)." })
HC:RegisterReading("hctravel:corpseruns", { title = "Corpse runs", tracker = DIST, counter = ID.corpse, scopes = ALL,
  formatter = "number", order = 49, description = "Times you ran back to your corpse as a ghost and took your body." })
HC:RegisterReading("hctravel:healer", { title = "Spirit healer visits", tracker = DIST, counter = ID.healer, scopes = ALL,
  formatter = "number", order = 49.5, description = "Times you took the spirit healer's resurrection." })
HC:RegisterReading("hctravel:corpse", { title = "Corpse", tracker = DIST, scopes = { "now" }, formatter = "distance",
  compute = function() return corpseDistance() end, order = 50,
  description = "While a ghost: how far away your corpse is. Empty otherwise." })
HC:RegisterReading("hctravel:flights", { title = "Flights taken", tracker = FLIGHTS, counter = ID.flight,
  measure = "count", scopes = ALL, formatter = "number", order = 51, description = "Flight paths taken, counted on landing." })
HC:RegisterReading("hctravel:flightdist", { title = "Distance flown", tracker = FLIGHTS, counter = ID.flight,
  scopes = ALL, formatter = "distance", order = 52, description = "Yards flown on flight paths." })
HC:RegisterReading("hctravel:longestflight", { title = "Longest flight", tracker = FLIGHTS, counter = ID.flight,
  measure = "max", scopes = BEST, formatter = "distance", order = 53, description = "Your longest flight path, in yards." })

---------------------------------------------------------------------------
-- Board presets (DESIGN §5): Trip and Flight log
---------------------------------------------------------------------------

if HC.RegisterBoardPreset then
  HC:RegisterBoardPreset("hctravel:trip", { name = "Trip", tiles = {
    { reading = "hctravel:distance", display = "odometer", size = "large" },
    { reading = "hctravel:time", display = "mix", size = "line" },
    { reading = "hctravel:distance", arg = { "walk", "run" }, size = "half" },
    { reading = "hctravel:distance", arg = { "mounted" }, size = "half" },
    { reading = "hctravel:avgspeed", size = "half" },
    { reading = "hctravel:topspeed", size = "half" },
    { reading = "hctravel:speednow", scope = "now", size = "line" },
    { reading = "hctravel:flights", size = "line" },
  } })
  HC:RegisterBoardPreset("hctravel:flightlog", { name = "Flight log", tiles = {
    { reading = "hctravel:flights", size = "large" },
    { reading = "hctravel:flightdist", size = "half" },
    { reading = "hctravel:time", arg = { "taxi" }, size = "half" },
    { reading = "hctravel:longestflight", size = "line" },
  } })
end
