-- Readings with a parameter (HC-31, DESIGN §16.4): a reading declares `param`, a tile (or a caller) supplies the
-- member; values come from the odometer's per-member totals, the open run's tallies, or a filtered query.
local Env = require("env")

local function setup(env, history)
  local HC = env.HC
  HC:RegisterPack("Test", { namespace = "t" })
  HC:RegisterCounter({ id = "t:rep", version = 1, measures = { "sum", "count" },
    dimensions = { { name = "faction", cap = 64 }, { name = "zone", cap = 64 } }, aggregations = { {}, { "faction" }, { "zone" } } })
  HC:RegisterCounter({ id = "t:lost", version = 1, measures = { "sum", "count" },
    dimensions = { { name = "faction", cap = 64 } }, aggregations = { {}, { "faction" } } })
  HC:RegisterCounter({ id = "t:items", version = 1, measures = { "sum", "count" },
    dimensions = { { name = "item", cap = 4096 } }, aggregations = { {}, { "item" } }, runLive = { member = "item", cap = 2 } })
  HC:RegisterCounter({ id = "t:bag", version = 1, kind = "stock", measures = { "last" },
    dimensions = { { name = "kind", cap = 8 } }, aggregations = { {}, { "kind" } } })
  HC:RegisterCounter({ id = "t:noagg", version = 1, dimensions = { { name = "who", cap = 8 } } })
  HC:RegisterCounter({ id = "t:tiny", version = 1, dimensions = { { name = "k", cap = 2 } }, aggregations = { {}, { "k" } } })
  HC:RegisterCounter({ id = "t:drop", version = 1, measures = { "sum", "count" }, runTracked = true, runLive = { max = true } })
  Env.trackAll(env, "t:all", { "t:rep", "t:lost", "t:items", "t:bag", "t:noagg", "t:tiny", "t:drop", "hc:time.active" }, history or "off")
  local ALL = { "run", "session", "today", "lifetime" }
  HC:RegisterReading("t:repwith", { title = "%s rep", tracker = "t:all", counter = "t:rep",
    param = { dim = "faction", type = "faction", label = function(k) return k == 576 and "Timbermaw Hold" or nil end }, scopes = ALL })
  HC:RegisterReading("t:netrep", { title = "Net rep", tracker = "t:all", counter = "t:rep", minus = "t:lost",
    param = { dim = "faction" }, scopes = ALL })
  HC:RegisterReading("t:repin", { title = "Rep/h in %s", tracker = "t:all", counter = "t:rep", per = "activeHour",
    param = { dim = "zone", type = "zone" }, scopes = ALL })
  HC:RegisterReading("t:looted", { title = "%s looted", tracker = "t:all", counter = "t:items",
    param = { dim = "item", type = "item" }, scopes = ALL })
  HC:RegisterReading("t:inbag", { title = "%s in bags", tracker = "t:all", counter = "t:bag",
    param = { dim = "kind" }, scopes = { "now" } })
  HC:RegisterReading("t:tinyk", { title = "Tiny %s", tracker = "t:all", counter = "t:tiny", param = { dim = "k" }, scopes = ALL })
  HC:RegisterReading("t:carried", { title = "%s carried", tracker = "t:all", counter = "t:items", scopes = { "now" },
    param = { dim = "item", type = "item" }, compute = function(_, _, arg) return arg end })
  HC:RegisterReading("t:who", { title = "By %s", tracker = "t:all", counter = "t:noagg", param = { dim = "who" }, scopes = ALL })
  HC:RegisterReading("t:best", { title = "Best drop", tracker = "t:all", counter = "t:drop", best = true, scopes = { "run" } })
  HC:RegisterReading("t:togo", { title = "%s to go", tracker = "t:all", scopes = { "session" }, param = { dim = "faction" },
    inputs = { "t:repwith" }, compute = function(get, _, arg) return 1000 - (get("t:repwith") or 0) + (arg == 576 and 0 or 1) end })
end

local function start(env, login, history, ui)
  env:load()
  setup(env, history)
  env:fire("ADDON_LOADED", "HardCounters")
  env.sv.HardCountersDB = _G.HardCountersDB
  env:fire("PLAYER_ENTERING_WORLD", login, not login)
  if ui then
    local ns = env.ns
    ns.AddSlash = function() end
    ns.AddOptions = function() end
    for _, f in ipairs({ "UI/Widgets.lua", "UI/BoardModel.lua" }) do
      assert(loadfile(Env.ROOT .. "/" .. f))("HardCounters", ns)
    end
    env.M = ns.BoardModel
  end
  return env
end

local function boot(history, ui) return start(Env.new(), true, history, ui) end

local function again(env, opts)
  opts = opts or {}
  env:fire("PLAYER_LOGOUT")
  local sv = { HardCountersDB = Env.svCopy(env.sv.HardCountersDB) }
  local r = Env.new({ t = env.t + (opts.offline or 0), guid = env.guid, sv = sv, settings = Env.svCopy(env.ns.settings),
    chars = Env.svCopy(env.chars) })
  r.zone = env.zone
  return start(r, opts.login and true or false, opts.history, opts.ui)
end

describe("readings with a parameter", function()
  it("read one member over our windows, with history off; no argument is 'noarg', never the total", function()
    local env = boot()
    local HC = env.HC
    HC:Emit("t:rep", 25, 576, 1429)
    HC:Emit("t:rep", 10, 59, 1429)
    HC:Emit("t:rep", 5, 576, 1429)
    HC:Emit("t:lost", 3, 576)
    assert.are.equal(30, (HC:Reading("t:repwith", "session", 576)))
    assert.are.equal(10, (HC:Reading("t:repwith", "session", 59)))
    assert.are.equal(0, (HC:Reading("t:repwith", "session", 9999)))    -- never seen: 0 is true here
    assert.are.equal(27, (HC:Reading("t:netrep", "session", 576)))     -- minus reads the same member
    local v, text, _, state = HC:Reading("t:repwith", "session")
    assert.is_nil(v)
    assert.are.equal("-", text)
    assert.are.equal("noarg", state)
    assert.are.equal("needs history", select(4, HC:Reading("t:repwith", "today", 576)))
    assert.are.equal("norun", select(4, HC:Reading("t:repwith", "run", 576)))
    HC:StartRun()
    HC:Emit("t:rep", 7, 576, 1429)
    assert.are.equal(7, (HC:Reading("t:repwith", "run", 576)))
    assert.are.equal(37, (HC:Reading("t:repwith", "session", 576)))
    -- a /reload carries the login on; a new login starts it over, the odometer does not
    local r = again(env)
    assert.are.equal(37, (r.HC:Reading("t:repwith", "session", 576)))
    local l = again(r, { login = true })
    assert.are.equal(0, (l.HC:Reading("t:repwith", "session", 576)))
    assert.are.equal(37, l.ns.odo["t:rep"].by.faction[576])
  end)

  it("title and label the member; the definition is public without its functions", function()
    local env = boot()
    local ns, HC = env.ns, env.HC
    local r = ns.readings["t:repwith"]
    assert.are.equal("Timbermaw Hold rep", ns.ReadingTitle(r, 576))
    assert.are.equal("59 rep", ns.ReadingTitle(r, 59))               -- no label from the pack: the key
    assert.are.equal("... rep", ns.ReadingTitle(r, nil))
    assert.are.equal("Net rep: 576", ns.ReadingTitle(ns.readings["t:netrep"], 576))
    assert.are.equal("Rep/h in Map 1429", ns.ReadingTitle(ns.readings["t:repin"], 1429))
    assert.are.same({ dim = "faction", type = "faction" }, HC:GetReading("t:repwith").param)
    assert.are.equal("enum", HC:GetReading("t:netrep").param.type)
    assert.has_error(function() HC:RegisterReading("t:bad", { counter = "t:rep", param = { type = "zone" } }) end)
    assert.has_error(function() HC:RegisterReading("t:bad", { counter = "t:rep", param = { dim = "zone", type = "nope" } }) end)
    for _, rr in ipairs(HC:RunReadings()) do assert.is_nil(rr.param) end   -- not in the run lists
  end)

  it("ask storage for one member by filter when the counter keeps history", function()
    local env = boot("detailed")
    local HC = env.HC
    HC:Emit("t:rep", 25, 576, 1429)
    HC:Emit("t:rep", 10, 59, 1429)
    assert.are.equal(25, (HC:Reading("t:repwith", "today", 576)))
    assert.are.equal(10, (HC:Reading("t:repwith", "lifetime", 59)))
    assert.are.equal(0, (HC:Reading("t:repwith", "today", 9999)))
    HC:Emit("t:items", 3, 2589)
    assert.are.equal(3, (HC:Reading("t:looted", "lifetime", 2589)))
    -- the answer is kept a few seconds (a filtered query per redraw adds up), then asked again
    HC:Emit("t:rep", 5, 576, 1429)
    assert.are.equal(25, (HC:Reading("t:repwith", "today", 576)))
    env:advance(11)
    assert.are.equal(30, (HC:Reading("t:repwith", "today", 576)))
    -- a dimension with no aggregation set of its own can't be filtered: say so
    HC:Emit("t:noagg", 1, "me")
    assert.are.equal("needs history", select(4, HC:Reading("t:who", "today", "me")))
    assert.are.equal(1, (HC:Reading("t:who", "session", "me")))        -- our windows don't need storage
  end)

  it("count a member of a big dimension from the first time it is asked for; the open run knows every item", function()
    local env = boot()
    local HC = env.HC
    HC:Emit("t:items", 4, 2589)                                      -- before anyone asked: not kept
    assert.is_nil(env.ns.odo["t:items"].by)
    assert.are.equal(0, (HC:Reading("t:looted", "session", 2589)))
    HC:Emit("t:items", 2, 2589)
    HC:Emit("t:items", 9, 4306)                                      -- another item: still not kept
    assert.are.equal(2, (HC:Reading("t:looted", "session", 2589)))
    assert.are.same({ [2589] = 2 }, env.ns.odo["t:items"].by.item)
    assert.are.equal(15, env.ns.odo["t:items"].s)
    HC:StartRun()
    HC:Emit("t:items", 1, 2589)
    HC:Emit("t:items", 1, 7000)
    HC:Emit("t:items", 1, 8000)                                      -- the run's own cap (2) is reached
    assert.are.equal(1, (HC:Reading("t:looted", "run", 2589)))
    local v, text, _, state = HC:Reading("t:looted", "run", 8000)
    assert.is_nil(v)
    assert.are.equal("capped", state)
    assert.are.equal("over the limit", text)                         -- never 0 for something that was counted
  end)

  it("say 'over the limit' for a member past the odometer's cap", function()
    local env = boot()
    local HC = env.HC
    for i = 1, env.ns.ODO_MEMBER_CAP do HC:Emit("t:noagg", 1, "m" .. i) end
    HC:Emit("t:noagg", 5, "late")
    assert.are.equal(1, (HC:Reading("t:who", "session", "m7")))
    assert.are.equal("capped", select(4, HC:Reading("t:who", "session", "late")))
  end)

  it("divide a zone's reading by the time spent in that zone; pass the argument to computed readings; stocks per member", function()
    local env = boot()
    local HC = env.HC
    HC:Emit("t:rep", 100, 576, 1429)
    env:advance(600)
    env.zone = 1436
    env:fire("ZONE_CHANGED_NEW_AREA")
    HC:Emit("t:rep", 50, 576, 1436)
    env:advance(1200)
    assert.are.equal(600, (HC:Reading("t:repin", "session", 1429)))    -- 100 in 600 s
    assert.are.equal(150, (HC:Reading("t:repin", "session", 1436)))    -- 50 in 1200 s
    assert.are.equal(850, (HC:Reading("t:togo", "session", 576)))
    assert.are.equal(1001, (HC:Reading("t:togo", "session", 59)))
    HC:Observe("t:bag", 143, "cloth")
    HC:Observe("t:bag", 20, "ore")
    assert.are.equal(143, (HC:Reading("t:inbag", "now", "cloth")))
    assert.is_nil((HC:Reading("t:inbag", "now", "gems")))            -- unknown, not 0
  end)
end)

describe("tiles with an argument", function()
  it("read their member over the board's period; another member shows over the same period", function()
    local env = boot(nil, true)
    local M, HC = env.M, env.HC
    local b = M.Create(nil, { name = "Rep" })
    HC:Emit("t:rep", 500, 576, 1429)
    local t = M.AddReading(b, "t:repwith", nil, nil, 576)
    assert.are.equal("run", t.scope)
    assert.are.equal(576, t.arg)
    assert.are.equal(0, (M.TileValue(t)))
    HC:Emit("t:rep", 25, 576, 1429)
    HC:Emit("t:rep", 10, 59, 1429)
    env:advance(65)
    assert.are.equal(25, (M.TileValue(t)))
    assert.are.equal("Timbermaw Hold rep", M.TileLabel(t))
    local w = M.TileWindow(t)
    assert.are.equal(500, w.base["t:rep"].by.faction[576])          -- the whole breakdown is in the board's base
    M.ControlAll(b, "pause")
    HC:Emit("t:rep", 99, 576, 1429)
    M.ControlAll(b, "start")
    HC:Emit("t:rep", 1, 576, 1429)
    assert.are.equal(26, (M.TileValue(t)))
    local r = again(env, { ui = true })
    local t2 = r.M.Store().list[#r.M.Store().list].tiles[1]
    assert.are.equal(26, (r.M.TileValue(t2)))
    assert.is_true(r.M.SetArg(t2, 59))
    assert.are.equal(10, (r.M.TileValue(t2)))                        -- 59's 10 over the same period, at once
    r.HC:Emit("t:rep", 4, 59, 1429)
    assert.are.equal(14, (r.M.TileValue(t2)))
    -- a tile with no member picked yet shows nothing, not the total
    local t3 = r.M.AddReading(r.M.Store().list[1], "t:repwith")
    local v, text, _, state = r.M.TileValue(t3)
    assert.is_nil(v)
    assert.are.equal("-", text)
    assert.are.equal("noarg", state)
    assert.are.equal("... rep", r.M.TileTitle(t3))
  end)

  it("count an item nothing kept before from when it is first watched, and say since when, until a reset", function()
    local env = boot(nil, true)
    local M, HC = env.M, env.HC
    -- an item watched before the board's base: exact
    HC:Reading("t:looted", "session", 2589)
    local b = M.Create(nil, { name = "Loot" })
    local gold = M.AddReading(b, "t:best")                          -- the board's window starts here
    HC:Emit("t:items", 2, 2589)
    HC:Emit("t:items", 4, 14047)                                    -- nothing keeps 14047 yet: not counted
    env:advance(120)
    local known = M.AddReading(b, "t:looted", nil, nil, 2589)
    assert.are.equal(2, (M.TileValue(known, b)))
    assert.are.equal("2589 looted", M.TileLabel(known, b))
    -- an item first watched now: counted from now, and the tile says so
    local at = env.ns.wow.date("%H:%M", env.ns.wow.now())
    local late = M.AddReading(b, "t:looted", nil, nil, 14047)
    HC:Emit("t:items", 3, 14047)
    assert.are.equal(3, (M.TileValue(late, b)))
    assert.are.equal("14047 looted (since " .. at .. ")", M.TileLabel(late, b))
    -- on a board made after the watch it is exact; back on the older board, late again
    local fresh = M.Create(nil, { name = "Fresh" })
    M.AddReading(fresh, "t:best")
    env:advance(10)
    HC:Emit("t:items", 1, 14047)
    M.MoveTo(b, 3, fresh)
    assert.are.equal(1, (M.TileValue(late, fresh)))
    assert.are.equal("14047 looted", M.TileLabel(late, fresh))
    M.MoveTo(fresh, 2, b)
    assert.truthy(M.TileLabel(late, b):find("(since ", 1, true))
    -- a reset starts a period that counted it all along
    M.ControlAll(b, "reset")
    assert.are.equal("14047 looted", M.TileLabel(late, b))
    assert.are.equal(0, (M.TileValue(late, b)))
    assert.truthy(gold)
  end)

  it("keep the best single value per counter on the board, so a moved 'Best drop' reads its new board's", function()
    local env = boot(nil, true)
    local M, HC = env.M, env.HC
    local a = M.Create(nil, { name = "A" })
    local best = M.AddReading(a, "t:best")
    HC:Emit("t:drop", 50)
    HC:Emit("t:drop", 20)
    local b = M.Create(nil, { name = "B" })
    M.AddReading(b, "t:repwith", nil, nil, 576)                      -- B's window starts here
    HC:Emit("t:drop", 30)
    assert.are.equal(50, (M.TileValue(best, a)))
    M.MoveTo(a, 1, b)
    assert.are.equal(30, (M.TileValue(best, b)))                     -- B's best, of B's whole period
    assert.are.equal(30, M.BoardWindow(b).max["t:drop"].v)
    M.ControlAll(b, "pause")
    HC:Emit("t:drop", 90)                                            -- paused: not B's
    assert.are.equal(30, (M.TileValue(best, b)))
    env:advance(400)
    M.ControlAll(b, "start")
    -- B's record keeps its best
    env:advance(400)
    local id = M.SaveBoard(b)
    local rec = HC:GetRunRecord(id)
    assert.are.equal(30, (env.ns.Widgets.RecordReading(env.ns.readings["t:best"], rec)))
    M.ControlAll(b, "reset")
    assert.is_nil((M.TileValue(best, b)))
  end)

  it("watch a big dimension's member from placement, on the board's window and in the login scope", function()
    local env = boot(nil, true)
    local M, HC = env.M, env.HC
    local b = M.Create(nil, { name = "Loot" })
    HC:Emit("t:items", 7, 14047)
    local t = M.AddReading(b, "t:looted", nil, nil, 14047)
    local login = M.AddReading(b, "t:looted", nil, "session", 14047)
    HC:Emit("t:items", 3, 14047)
    HC:Emit("t:items", 1, 2589)
    assert.are.equal(3, (M.TileValue(t)))
    assert.are.equal(3, (M.TileValue(login)))
    assert.are.equal("14047 looted \194\183 session", M.TileLabel(login))
  end)

  it("offer the members known so far, sorted by label, and parse a typed one", function()
    local env = boot(nil, true)
    local M, HC = env.M, env.HC
    assert.are.same({}, (M.MemberChoices("t:repwith")))
    HC:Emit("t:rep", 1, 59, 1429)
    HC:Emit("t:rep", 1, 576, 1429)
    HC:Emit("t:rep", 1, "Booty Bay", 1429)
    local list, more = M.MemberChoices("t:repwith")
    assert.is_false(more)
    assert.are.same({ { arg = 59, label = "59" }, { arg = "Booty Bay", label = "Booty Bay" }, { arg = 576, label = "Timbermaw Hold" } }, list)
    assert.are.equal(576, M.ResolveArg("t:repwith", " 576 "))
    assert.are.equal("Booty Bay", M.ResolveArg("t:repwith", "booty bay"))          -- a known member, any case
    assert.are.equal(576, M.ResolveArg("t:repwith", "Timbermaw hold"))             -- its label gives the id
    assert.are.equal("Gelkis Clan", M.ResolveArg("t:repwith", "Gelkis Clan"))      -- factions may be keyed by name
    assert.are.same({ nil, "empty" }, { M.ResolveArg("t:repwith", "  ") })
    assert.are.same({}, (M.MemberChoices("t:looted")))               -- a big dimension keeps no list: type the id
    M.MEMBER_CHOICES = 2
    list, more = M.MemberChoices("t:repwith")
    assert.are.equal(2, #list)
    assert.is_true(more)
    assert.are.equal("Booty Bay", M.ResolveArg("t:repwith", "BOOTY BAY"))         -- matching ignores the menu's limit
  end)

  -- HC-47 (saved files 2026-11-18): "Refreshing Spring Water" typed for "... looted" was kept as text and read 0
  -- for ever, since loot is keyed by item id. Items and zones are always ids: a name becomes one or is refused.
  it("turn a typed item or zone name into an id, or refuse it (HC-47)", function()
    local env = boot(nil, true)
    local M, HC, ns = env.M, env.HC, env.ns
    assert.are.equal(2589, M.ResolveArg("t:looted", "2589"))
    assert.are.equal(2589, M.ResolveArg("t:looted", "|cffffffff|Hitem:2589::::::::60:::::|h[Linen Cloth]|h|r"))
    assert.are.same({ nil, "unknown" }, { M.ResolveArg("t:looted", "Refreshing Spring Water") })
    ns.wow.itemIdByName = function(name) return name == "Refreshing Spring Water" and 159 or nil end
    assert.are.equal(159, M.ResolveArg("t:looted", "Refreshing Spring Water"))
    HC:Emit("t:items", 1, 14047)                                                   -- recent loot, by its label
    assert.are.equal(14047, M.ResolveArg("t:looted", "14047"))
    HC:Emit("t:rep", 1, 576, 1429)
    assert.are.equal(1429, M.ResolveArg("t:repin", HC:ZoneName(1429)))
    assert.are.same({ nil, "unknown" }, { M.ResolveArg("t:repin", "Nowhere Land") })
  end)
end)

-- HC-34: the player picks instead of typing an id
describe("pickers", function()
  it("remember the members of a big dimension written last, newest first, across a /reload and a login", function()
    local env = boot()
    local HC, ns = env.HC, env.ns
    assert.are.same({}, ns.RecentMembers("t:items", "item"))
    HC:Emit("t:items", 1, 2589)
    HC:Emit("t:items", 1, 4306)
    HC:Emit("t:items", 2, 2589)                                      -- again: moves to the front, once
    assert.are.same({ 2589, 4306 }, ns.RecentMembers("t:items", "item"))
    HC:Emit("t:items", 1, nil)                                       -- no member: not remembered
    for i = 1, ns.RECENT_MEMBERS do HC:Emit("t:items", 1, 9000 + i) end
    local list = ns.RecentMembers("t:items", "item")
    assert.are.equal(ns.RECENT_MEMBERS, #list)                       -- the oldest fall off
    assert.are.equal(9000 + ns.RECENT_MEMBERS, list[1])
    assert.are.equal(9001, list[#list])
    assert.is_nil(ns.odo["t:items"].by)                              -- remembered, not counted per member
    assert.is_nil(ns.odo["t:rep"] and ns.odo["t:rep"].rc)            -- small dimensions keep every member anyway
    local l = again(env, { login = true })
    assert.are.equal(9000 + ns.RECENT_MEMBERS, l.ns.RecentMembers("t:items", "item")[1])
  end)

  it("offer recent items, then the ones a tile watches; a big dimension never lists all of storage", function()
    local env = boot("detailed", true)
    local M, HC = env.M, env.HC
    for id = 1, 60 do HC:Emit("t:items", 1, 100 + id) end
    HC:Emit("t:items", 1, 2589)
    local b = M.Create(nil, { name = "Loot" })
    M.AddReading(b, "t:looted", nil, nil, 14047)                     -- watched, never looted
    local list = M.RecentChoices("t:looted")
    assert.are.equal(env.ns.RECENT_MEMBERS + 1, #list)
    assert.are.same({ arg = 2589, label = "2589" }, list[1])
    assert.are.same({ arg = 14047, label = "14047" }, list[#list])
    assert.are.same({ { arg = 14047, label = "14047" } }, (M.MemberChoices("t:looted")))   -- not the 61 stored ones
    assert.are.same({}, M.RecentChoices("t:repwith"))
  end)

  it("list the game's factions by group, then the ones counted that the game doesn't list", function()
    local env = boot(nil, true)
    local M, HC = env.M, env.HC
    assert.are.same({ {}, 0 }, { M.FactionChoices("t:repwith") })    -- no faction API: the caller falls back
    env.ns.wow.factions = function()
      return { { id = 576, name = "Timbermaw Hold", group = "Classic" }, { id = 59, name = "Thorium Brotherhood", group = "Classic" },
        { id = 72, name = "Stormwind", group = "Alliance" }, { id = 72, name = "Stormwind", group = "Alliance" },
        { id = 909, name = "Darkmoon Faire" } }
    end
    HC:Emit("t:rep", 1, 576, 1429)
    HC:Emit("t:rep", 1, "Booty Bay", 1429)                           -- keyed by name: the game gave no id
    local groups, n = M.FactionChoices("t:repwith")
    assert.are.equal(5, n)
    assert.are.same({
      { name = "Classic", list = { { arg = 576, label = "Timbermaw Hold" }, { arg = 59, label = "Thorium Brotherhood" } } },
      { name = "Alliance", list = { { arg = 72, label = "Stormwind" } } },
      { list = { { arg = 909, label = "Darkmoon Faire" } } },
      { name = false, list = { { arg = "Booty Bay", label = "Booty Bay" } } },
    }, groups)
  end)

  it("turn an item dropped on a board into a tile: every reading that takes an item, the tile under it first", function()
    local env = boot(nil, true)
    local M = env.M
    assert.are.same({ "t:carried", "t:looted" }, M.ItemReadings())   -- display order
    local b = M.Create(nil, { name = "Loot" })
    local rep = M.AddReading(b, "t:repwith", nil, nil, 576)
    local loot = M.AddReading(b, "t:looted", nil, nil, 2589)
    local add = { { reading = "t:carried", text = "4306 carried" }, { reading = "t:looted", text = "4306 looted" } }
    assert.are.same(add, M.DropChoices(b, nil, 4306))                -- beside the tiles
    assert.are.same(add, M.DropChoices(b, rep, 4306))                -- a tile that takes no item
    local on = M.DropChoices(b, loot, 4306)
    assert.are.equal(3, #on)
    assert.are.equal(loot, on[1].tile)
    assert.are.equal("4306 looted", on[1].text)
    on = M.DropChoices(b, loot, 2589)                                -- the item it shows already: only "add"
    assert.are.equal(2, #on)
    assert.is_nil(on[1].tile)
  end)

  it("say 'over the limit' for a member storage counted in 'other', never 0", function()
    local env = boot("detailed")
    local HC = env.HC
    HC:Emit("t:tiny", 1, "a")
    assert.are.equal(0, (HC:Reading("t:tinyk", "today", "c")))       -- room left: 0 is true
    HC:Emit("t:tiny", 1, "b")
    env:advance(11)
    HC:Emit("t:tiny", 5, "c")                                        -- past the cap of 2: storage books it as "other"
    assert.are.equal(1, (HC:Reading("t:tinyk", "today", "a")))
    local v, text, _, state = HC:Reading("t:tinyk", "today", "c")
    assert.is_nil(v)
    assert.are.equal("capped", state)
    assert.are.equal("over the limit", text)
    -- a member never written reads the same once the list is full: it could only ever land in "other"
    assert.are.equal("capped", select(4, HC:Reading("t:tinyk", "lifetime", "never")))
  end)
end)
