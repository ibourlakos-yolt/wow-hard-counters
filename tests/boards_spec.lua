-- Boards, the model (HC-18, TRACKERS_AND_BOARDS §6): presets, first use and migration, tiles, layout, visibility,
-- the comparison line and sparklines. The frames are UI/Boards.lua (load smoke test; seen in game by the user).
local Env = require("env")

local function boot(settings)
  Env.BASICS = true
  local env = Env.new({ settings = settings })
  local game = { money = 100000, xp = 100, xpMax = 1000, level = 20 }
  env.game = game
  _G.GetMoney = function() return game.money end
  _G.UnitXP = function() return game.xp end
  _G.UnitXPMax = function() return game.xpMax end
  _G.UnitLevel = function() return game.level end
  _G.GetXPExhaustion = function() return 0 end
  env:boot()
  Env.BASICS = nil
  local ns = env.ns
  ns.AddSlash = function() end
  ns.AddOptions = function() end
  for _, f in ipairs({ "UI/Widgets.lua", "UI/BoardModel.lua" }) do
    assert(loadfile(Env.ROOT .. "/" .. f))("HardCounters", ns)
  end
  env.M = ns.BoardModel
  return env
end

local function ids(board)
  local out = {}
  for _, t in ipairs(board.tiles) do
    out[#out + 1] = t.kind == "reading" and (t.reading .. "@" .. t.scope .. ":" .. (t.calc or "-") .. ":" .. t.display .. ":" .. t.size)
      or t.kind
  end
  return out
end

describe("boards", function()
  it("start a fresh install with the Pocket board only, in mini mode; the Run board is a preset to add", function()
    local env = boot()
    local M = env.M
    assert.is_true(M.Seed())
    assert.is_false(M.Seed())                         -- once
    local list = M.Store().list
    assert.are.equal(1, #list)
    assert.are.equal("Pocket", list[1].name)
    assert.is_true(list[1].mini)
    assert.is_true(list[1].shown)
    -- on the board's timer (HC-41): the strip's dot pauses them
    assert.same({ "hc:gold@run:perHour:number:large", "hc:xpgained@run:perHour:number:half",
      "hc:net@run:perHour:number:half" }, ids(list[1]))
    assert.is_true(M.UsesTimer(list[1]))
    env.HC:StartRun("manual")                         -- a run no longer brings a board with it (HC-30)
    assert.are.equal(1, #list)
    local run = M.Create("run")
    assert.are.equal("Run", run.name)
    assert.is_true(M.UsesTimer(run))
    local lev = M.Create("leveling")
    assert.same({ "hc:xpgained@run:perHour:number:large", "hc:xplevel@now:-:bar:line", "hc:ttl@run:-:number:half",
      "hc:rested@now:-:number:half", "hc:xpgained@run:-:number:half", "hc:gold@run:perHour:number:half" }, ids(lev))
    -- without Farmer its tiles are left out of the preset
    for _, t in ipairs(run.tiles) do assert.is_nil(t.reading and t.reading:match("^hcfarm")) end
  end)

  it("seed the Run board from the old run panel, once: shown, compact as mini, width, place, headline", function()
    local settings = { runPanel = { compact = true, headline = "hcfarm:netph" },
      windows = { runPanel = { shown = true, width = 320, pos = { "TOPLEFT", 10, -20, "BOTTOMLEFT" }, scale = 1.2 } },
      liveNumber = { shown = false } }
    local env = boot(settings)
    local M = env.M
    M.Seed()
    local run, pocket = M.Store().list[1], M.Store().list[2]
    assert.are.equal("Run", run.name)
    assert.is_true(run.mini)
    assert.are.equal(320, run.width)
    assert.are.equal(1.2, run.scale)
    assert.same({ "TOPLEFT", 10, -20, "BOTTOMLEFT" }, run.pos)
    local hero = run.tiles[M.HeroIndex(run)]                         -- Farmer's old headline, now Basics'
    assert.are.equal("hc:net", hero.reading)                          -- (HC-51: hc:netph is hc:net per hour)
    assert.are.equal("perHour", hero.calc)
    assert.is_false(pocket.shown)
  end)

  it("put a new tile on the board's timer when the reading can be, else what the reading has", function()
    local env = boot()
    local M = env.M
    local run, pocket = M.Create("run"), M.Create("pocket")
    assert.are.equal("run", M.DefaultScope(run, "hc:goldph"))
    assert.are.equal("run", M.DefaultScope(pocket, "hc:goldph"))
    assert.are.equal("now", M.DefaultScope(pocket, "hc:rested"))
    local t = M.AddReading(pocket, "hc:gold")
    assert.are.equal("run", t.scope)
    assert.are.equal("number", t.display)
    assert.are.equal("line", t.size)
    run.shown, pocket.shown = false, true             -- HC-36: the [+] offers boards on screen first
    assert.are.same({ pocket, run }, M.AddTargets())
    assert.is_nil(M.AddReading(pocket, "nope:x"))
    assert.is_true(M.MoveTile(pocket, #pocket.tiles, -1))
    assert.is_false(M.MoveTile(pocket, 1, -1))
    assert.are.equal("hc:gold", M.RemoveTile(pocket, #pocket.tiles - 1).reading)
  end)

  it("lay tiles out in rows whose heights follow the content, pairing grid tiles", function()
    local env = boot()
    local M = env.M
    local b = M.Create("run")
    local rows, h = M.Layout(b)
    local kinds = {}
    for _, r in ipairs(rows) do kinds[#kinds + 1] = r.kind .. #r.tiles end
    -- the control row first (no tile: drawn by itself), then XP/h+Net, Gold+time to level
    assert.same({ "run0", "hero1", "grid2", "grid2", "splits1" }, kinds)
    local sum = 2 * M.PAD
    for _, r in ipairs(rows) do sum = sum + r.h end
    assert.are.equal(sum, h)
    local _, h2 = M.Layout(b, { compare = { [1] = true } })
    assert.are.equal(h + M.HEIGHT.heroCompare - M.HEIGHT.hero, h2)
  end)

  it("decide visibility: combat, instances, run only, mouse-over fade; edit mode shows everything", function()
    local env = boot()
    local M = env.M
    local b = M.Create("pocket")
    assert.same({ true, 1 }, { M.Visibility(b, {}) })
    b.show.combat = "fade"
    assert.same({ true, 0.35 }, { M.Visibility(b, { combat = true }) })
    b.show.combat = "hide"
    assert.same({ false, 1 }, { M.Visibility(b, { combat = true }) })
    assert.same({ true, 1 }, { M.Visibility(b, { combat = true, editing = true }) })
    b.show.instance = "hide"
    assert.is_false((M.Visibility(b, { instance = true })))
    b.show.runOnly = true
    assert.is_false((M.Visibility(b, {})))
    assert.is_true((M.Visibility(b, { runOpen = true })))
    b.show.mouseoverFade = true
    assert.same({ true, 0.3 }, { M.Visibility(b, { runOpen = true }) })
    assert.same({ true, 1 }, { M.Visibility(b, { runOpen = true, mouseOver = true }) })
    b.shown = false
    assert.is_false((M.Visibility(b, { editing = true })))
    assert.are.equal(0.5, M.TickRate(b, true))         -- its clock runs: twice a second
    assert.are.equal(5, M.TickRate(b, false))
    local plain = M.Create(nil)
    M.AddReading(plain, "hc:rested")                    -- `now` only: no clock
    assert.are.equal(5, M.TickRate(plain, true))
  end)

  it("grey scopes that need history, and offer them once history is on", function()
    local env = boot()
    local M = env.M
    local t = { kind = "reading", reading = "hc:goldph", scope = "session", style = "row" }
    local by = {}
    for _, c in ipairs(M.ScopeChoices(t)) do by[c.scope] = c.ok end
    assert.is_true(by.run)
    assert.is_true(by.session)
    assert.is_false(by.today)
    env.HC:SetTrackerHistory("hc:goldph", "daily")
    for _, c in ipairs(M.ScopeChoices(t)) do by[c.scope] = c.ok end
    assert.is_true(by.today)
    assert.is_true(by.week)
  end)

  it("compare the hero with this zone's past runs, from three runs on", function()
    local env = boot()
    local M, HC = env.M, env.HC
    for i = 1, 3 do
      HC:StartRun("R" .. i)
      HC:Emit("hc:money.in", i * 1000, "none", 1429)
      env:advance(3600)
      HC:StopRun()
      if i == 2 then assert.is_nil(M.ZoneAverage("hc:goldph", 1429)) end
    end
    local avg, n = M.ZoneAverage("hc:goldph", 1429)
    assert.are.equal(3, n)
    assert.are.equal(2000, avg)
    assert.is_nil(M.ZoneAverage("hc:goldph", 1411))
    local text, pct = M.CompareText(2360, avg)
    assert.are.equal(18, math.floor(pct + 0.5))
    assert.truthy(text:find("%+18%%"))
    assert.truthy(text:find("vs your average here"))
    assert.is_nil(M.CompareText(nil, avg))
  end)

  it("draw sparklines from the in-memory rate window, and labels with the scope", function()
    local env = boot()
    local M, HC = env.M, env.HC
    for k = 1, 4 do
      HC:Emit("hc:money.in", k * 100, "none", 1429)
      env:advance(60)
    end
    local vals = M.Sparkline("hc:goldph", 5, 60)
    assert.same({ 100, 200, 300, 400, 0 }, vals)      -- oldest first; the minute now running is empty
    assert.same({ 3, 5, 8, 10, 1 }, M.SparkHeights(vals, 10))
    assert.is_nil(M.Sparkline("hc:ttl", 5, 60))       -- computed: no counter, no sparkline
    assert.are.equal("Gold/h \194\183 session", M.TileLabel({ kind = "reading", reading = "hc:goldph", scope = "session" }))
    local _, text, _, state = M.TileValue({ kind = "reading", reading = "hcfarm:best", scope = "run" })
    assert.are.equal("needs hcfarm", text)
    assert.are.equal("missing", state)
  end)
end)


-- DESIGN §16.8, HC-41: the board is the clock. One window per board and character; tiles on the board's timer read it.
describe("the board's timer", function()
  local function relog(env, opts)
    opts = opts or {}
    env:fire("PLAYER_LOGOUT")
    local sv = { HardCountersDB = Env.svCopy(env.sv.HardCountersDB) }
    Env.BASICS = true
    local r = Env.new({ t = env.t + (opts.offline or 0), guid = opts.guid or env.guid, sv = sv, settings = Env.svCopy(env.ns.settings) })
    r.game = env.game
    r:boot({ reload = opts.reload })
    Env.BASICS = nil
    local ns = r.ns
    ns.AddSlash = function() end
    ns.AddOptions = function() end
    for _, f in ipairs({ "UI/Widgets.lua", "UI/BoardModel.lua" }) do
      assert(loadfile(Env.ROOT .. "/" .. f))("HardCounters", ns)
    end
    r.M = ns.BoardModel
    return r
  end

  it("starts with the board's first tile on it; every tile reads the board's whole period; labels lose the clock", function()
    local env = boot()
    local M, HC = env.M, env.HC
    local b = M.Create(nil, { name = "Mine" })
    assert.is_nil((M.BoardState(b)))                   -- no tile on its timer: no clock
    HC:Emit("hc:money.in", 5000, "none", 1429)        -- before the board's window: not in it
    local gold = M.AddReading(b, "hc:gold")
    assert.are.equal(0, (M.TileValue(gold, b)))       -- a number at once, never "-"
    HC:Emit("hc:money.in", 100, "none", 1429)
    env:advance(120)
    local rate = M.AddReading(b, "hc:goldph")         -- placed two minutes later: the board's period all the same
    HC:Emit("hc:money.in", 60, "none", 1429)
    env:advance(60)
    assert.are.equal(160, (M.TileValue(gold, b)))
    assert.are.equal(3200, (M.TileValue(rate)))       -- 160 in the board's 180 s (the board found by a scan)
    assert.are.equal("Gold earned", M.TileLabel(gold, b))
    assert.are.equal("Gold/h", M.TileLabel(rate, b))
    local st, active = M.BoardState(b)
    assert.are.equal("running", st)
    assert.are.equal(180, active)
    assert.is_nil(HC:GetRun())                        -- no run was ever started
    -- one window for the board, watching every counter with its members
    local w = M.TileWindow(gold, b)
    assert.are.equal(w, M.TileWindow(rate, b))
    assert.is_true(w.board)
    assert.is_nil(w.ids)
    assert.is_nil(w.noBy)
    assert.truthy(env.sv.HardCountersDB.windows["b" .. b.wid .. "@" .. env.guid])
    assert.is_nil(M.TileWindow({ kind = "reading", reading = "hc:gold", scope = "session" }, b))
    assert.are.equal("Gold earned \194\183 session", M.TileLabel({ kind = "reading", reading = "hc:gold", scope = "session" }, b))
  end)

  it("pause, stop, start and reset act on every tile of the board together", function()
    local env = boot()
    local M, HC = env.M, env.HC
    local b = M.Create(nil, { name = "Mine" })
    local a, c = M.AddReading(b, "hc:gold"), M.AddReading(b, "hc:xpgained")
    local other = M.AddReading(M.Create(nil, { name = "Other" }), "hc:gold")
    HC:Emit("hc:money.in", 10, "none", 1429)
    M.ControlAll(b, "pause")
    assert.are.equal("paused", (M.BoardState(b)))
    HC:Emit("hc:money.in", 5, "none", 1429)
    HC:Emit("hc:xp", 9, "none", 1429)
    assert.are.equal(10, (M.TileValue(a, b)))
    assert.are.equal(0, (M.TileValue(c, b)))
    assert.are.equal(15, (M.TileValue(other)))        -- another board: its own timer
    M.ControlAll(b, "start")                          -- resume: carries on
    HC:Emit("hc:money.in", 1, "none", 1429)
    assert.are.equal(11, (M.TileValue(a, b)))
    M.ControlAll(b, "stop")                           -- frozen
    HC:Emit("hc:money.in", 100, "none", 1429)
    assert.are.equal(11, (M.TileValue(a, b)))
    assert.are.equal("stopped", (M.BoardState(b)))
    M.ControlAll(b, "start")                          -- after a stop: a new period from zero
    assert.are.equal(0, (M.TileValue(a, b)))
    HC:Emit("hc:money.in", 2, "none", 1429)
    assert.is_nil(M.ControlAll(b, "reset"))           -- under 5 active minutes: no record
    assert.are.equal(0, (M.TileValue(a, b)))
    assert.are.equal("running", (M.BoardState(b)))
    assert.are.equal(118, (M.TileValue(other)))
    assert.are.equal(0, #HC:Runs())
  end)

  it("save as run: one record of every counter for the board, also for the period a stop ended; never by itself", function()
    local env = boot()
    local M, HC = env.M, env.HC
    local b = M.Create(nil, { name = "Farm" })
    M.AddReading(b, "hc:goldph")
    HC:Emit("hc:money.in", 500, "none", 1429)
    env:advance(200)
    assert.is_nil(M.BoardSavable(b))
    assert.is_nil(M.SaveBoard(b))
    M.ControlAll(b, "reset")                          -- too short: nothing kept
    HC:Emit("hc:money.in", 1000, "none", 1429)
    HC:Emit("hc:xp", 70, "none", 1429)                -- no tile shows XP: the record has it anyway
    env:advance(600)
    assert.are.equal("now", M.BoardSavable(b))
    M.ControlAll(b, "stop")
    M.ControlAll(b, "start")                          -- a new period: the one that ended can still be saved
    assert.are.equal(0, #HC:Runs())
    assert.are.equal("prev", M.BoardSavable(b))
    local id = M.SaveBoard(b)
    local rec = HC:GetRunRecord(id)
    assert.are.equal("Farm", rec.label)
    assert.is_nil(rec.partial)
    assert.are.equal(1000, rec.deltas["hc:money.in"].sum)
    assert.are.equal(70, rec.deltas["hc:xp"].sum)
    assert.are.equal(600, rec.activeSeconds)
    assert.are.equal(1429, rec.mainZone)
    assert.is_nil(M.BoardSavable(b))                  -- saved once
    local Wd = env.ns.Widgets
    assert.are.equal(6000, (Wd.RecordReading(env.ns.readings["hc:goldph"], rec)))
    assert.are.equal(70, (Wd.RecordReading(env.ns.readings["hc:xpgained"], rec)))
    -- reset with 5 active minutes saves the period it ends, once, and starts from zero
    HC:Emit("hc:money.in", 300, "none", 1429)
    env:advance(400)
    local id2 = M.ControlAll(b, "reset")
    assert.are.equal(2, #HC:Runs())
    assert.are.equal(300, HC:GetRunRecord(id2).deltas["hc:money.in"].sum)
    assert.are.equal(400, HC:GetRunRecord(id2).activeSeconds)
    assert.are.equal(0, env.ns.Win.Total(M.BoardWindow(b), "hc:money.in"))   -- from zero again
  end)

  it("moves a tile to another board, where it shows that board's whole period; or to a new board of its own", function()
    local env = boot()
    local M, HC = env.M, env.HC
    local old = M.Create(nil, { name = "Old" })
    M.AddReading(old, "hc:xpgained")
    HC:Emit("hc:money.in", 100, "none", 1429)
    HC:Emit("hc:money.in", 7, "quest", 1429)
    env:advance(300)
    local new = M.Create(nil, { name = "New" })
    local gold = M.AddReading(new, "hc:gold")
    local from = M.AddReading(new, "hc:goldfrom", nil, nil, "quest")   -- a member of a small dimension
    HC:Emit("hc:money.in", 20, "none", 1429)
    HC:Emit("hc:money.in", 3, "quest", 1429)
    assert.are.equal(23, (M.TileValue(gold, new)))
    assert.are.equal(3, (M.TileValue(from, new)))
    assert.are.same({ old }, M.MoveTargets(new))
    local t, on = M.MoveTo(new, 1, old)
    assert.are.equal(gold, t)
    assert.are.equal(old, on)
    assert.are.equal(130, (M.TileValue(gold, old)))   -- the old board's whole period, at once
    M.MoveTo(new, 1, old)
    assert.are.equal(10, (M.TileValue(from, old)))    -- its member too: small dimensions are in the base
    assert.are.equal(0, #new.tiles)
    assert.are.equal(3, #old.tiles)
    -- to a new board: named after the tile, shown, running from zero
    local _, own = M.MoveTo(old, 2, nil)
    assert.are.equal("Gold earned", own.name)
    assert.is_true(own.shown)
    assert.are.equal(0, (M.TileValue(gold, own)))
    assert.are.equal("running", (M.BoardState(own)))
    M.ControlAll(own, "pause")                         -- pausing it pauses that one tile only
    HC:Emit("hc:money.in", 1, "quest", 1429)
    assert.are.equal(0, (M.TileValue(gold, own)))
    assert.are.equal(11, (M.TileValue(from, old)))
    assert.is_nil(M.MoveTo(old, 1, old))
  end)

  it("draws the control row by itself on a board with a tile on its timer; the old kind of tile goes", function()
    local env = boot({ boards = { list = { { id = "b1", name = "Old run", shown = true, mini = false, width = 260,
      show = {}, tiles = { { kind = "run" }, { kind = "reading", reading = "hc:gold", scope = "run", style = "row", wid = 4 } } } },
      nextId = 2, seeded = true } })
    local M = env.M
    local b = M.Store().list[1]
    assert.are.equal(1, #b.tiles)                      -- the control-row tile went, at the profile's first use
    assert.is_nil(b.tiles[1].wid)                      -- and the tile's own window
    assert.are.equal(5, M.Store().v)
    local rows = M.Layout(b)
    assert.are.equal("run", rows[1].kind)
    assert.are.equal(0, #rows[1].tiles)
    assert.are.equal("row", M.Layout(b, { noControls = true })[1].kind)   -- a mini board's flyout
    b.tiles[1].scope = "session"
    assert.are.equal("row", M.Layout(b)[1].kind)       -- nothing on the timer: no control row
    assert.are.equal("reading", M.Create("run").tiles[1].kind)          -- the preset has no such tile
  end)

  it("survives /reload and logout: the board carries on at the next login, without the time offline", function()
    local env = boot()
    local M, HC = env.M, env.HC
    local b = M.Create(nil, { name = "Mine" })
    M.AddReading(b, "hc:gold")
    HC:Emit("hc:money.in", 40, "none", 1429)
    env:advance(100)
    local r = relog(env, { reload = true })
    local b2 = r.M.Store().list[#r.M.Store().list]
    assert.are.equal(b.wid, b2.wid)
    assert.are.equal(40, (r.M.TileValue(b2.tiles[1], b2)))
    r.HC:Emit("hc:money.in", 2, "none", 1429)
    r:advance(50)
    local l = relog(r, { offline = 9000 })
    local b3 = l.M.Store().list[#l.M.Store().list]
    local w = l.M.BoardWindow(b3)
    assert.are.equal("running", w.state)
    assert.is_true(l.ns.Win.Counting(w))
    assert.are.equal(42, (l.M.TileValue(b3.tiles[1], b3)))
    assert.are.equal(150, l.ns.Win.Elapsed(w))
    l.HC:Emit("hc:money.in", 8, "none", 1429)
    l:advance(30)
    assert.are.equal(50, (l.M.TileValue(b3.tiles[1], b3)))
    assert.are.equal(180, l.ns.Win.Active(w))
  end)

  it("is per character: an alt gets its own, the main's waits for the main; deleting the board forgets them", function()
    local env = boot()
    local M, HC = env.M, env.HC
    local b = M.Create(nil, { name = "Mine" })
    M.AddReading(b, "hc:gold")
    HC:Emit("hc:money.in", 40, "none", 1429)
    env:advance(100)
    local alt = relog(env, { guid = "Player-1-00000002", offline = 60 })
    local ba = alt.M.Store().list[#alt.M.Store().list]
    assert.are.equal(b.wid, ba.wid)                   -- the same board (one profile) ...
    assert.are.equal(0, (alt.M.TileValue(ba.tiles[1], ba)))   -- ... its own window on this character
    alt.HC:Emit("hc:money.in", 7, "none", 1429)
    alt:advance(500)
    assert.are.equal(7, (alt.M.TileValue(ba.tiles[1], ba)))
    local main = relog(alt, { guid = "Player-1-00000001", offline = 60 })
    local bm = main.M.Store().list[#main.M.Store().list]
    assert.are.equal(40, (main.M.TileValue(bm.tiles[1], bm)))
    assert.are.equal(100, main.ns.Win.Elapsed(main.M.BoardWindow(bm)))   -- the alt's session is not on its clock
    main.M.RemoveTile(bm, 1)                          -- a tile owns no window: the board's stays
    assert.truthy(main.sv.HardCountersDB.windows["b" .. b.wid .. "@Player-1-00000002"])
    main.M.Delete(bm.id)
    for k in pairs(main.sv.HardCountersDB.windows) do assert.is_nil(tostring(k):match("^b" .. b.wid .. "@")) end
  end)

  it("drops the tile windows of builds before HC-41, on every character, once", function()
    local env = boot()
    local db = env.sv.HardCountersDB
    db.windows["t3@Player-1-00000001"] = { acc = {} }
    db.windows["t3@account"] = { acc = {} }
    db.windows["t12@Player-1-00000002"] = { acc = {} }
    db.migrations.hc41 = nil
    local r = relog(env, { reload = true })
    local w = r.sv.HardCountersDB.windows
    assert.is_nil(w["t3@Player-1-00000001"])
    assert.is_nil(w["t3@account"])
    assert.is_nil(w["t12@Player-1-00000002"])
    assert.truthy(w.session)
    assert.is_true(r.sv.HardCountersDB.migrations.hc41)
  end)

  it("moves saved tiles from the login scope to session once (HC-49), with no alias left", function()
    local env = boot({ boards = { list = { { id = "b1", name = "Old", shown = true, mini = false, width = 260, show = {},
      tiles = { { kind = "reading", reading = "hc:gold", scope = "login", display = "number", size = "line" },
        { kind = "reading", reading = "hc:gold", scope = "today", display = "number", size = "line" } } } },
      nextId = 2, seeded = true, v = 3 } })
    local M, HC = env.M, env.HC
    local b = M.Store().list[1]
    assert.are.equal(5, M.Store().v)
    assert.are.equal("session", b.tiles[1].scope)
    assert.are.equal("today", b.tiles[2].scope)
    assert.are.equal("Gold earned \194\183 session", M.TileLabel(b.tiles[1], b))
    HC:Emit("hc:money.in", 700, "none", 1429)
    assert.are.equal(700, (M.TileValue(b.tiles[1], b)))
    assert.are.equal("scope", select(4, HC:Reading("hc:gold", "login")))   -- the old word is gone
    assert.are.equal("session", M.DefaultScope(nil, "nope:missing"))
    assert.are.same({ "run", "session", "today", "week", "month", "year", "lifetime" }, HC:GetReading("hc:gold").scopes)
    assert.is_nil(HC:GetCounter("hc:money.in").runTracked)
  end)

  -- HC-55 (DESIGN §16.8, user 2026-11-20): a scope for the board
  it("makes saved tiles on the board's timer follow the board, once (boards.v = 5); other scopes keep theirs", function()
    local env = boot({ boards = { list = { { id = "b1", name = "Leveling", shown = true, mini = false, width = 260, show = {},
      tiles = { { kind = "reading", reading = "hc:xpgained", scope = "run", calc = "perHour", display = "number", size = "large" },
        { kind = "reading", reading = "hc:xplevel", scope = "now", display = "bar", size = "line" },
        { kind = "reading", reading = "hc:gold", scope = "session", display = "number", size = "half" } } } },
      nextId = 2, seeded = true, v = 4 } })
    local M = env.M
    local b = M.Store().list[1]
    assert.are.equal(5, M.Store().v)
    assert.are.equal("run", M.BoardScope(b))
    assert.is_nil(b.scope)
    assert.is_true(b.tiles[1].follow)
    assert.is_nil(b.tiles[2].follow)
    assert.is_nil(b.tiles[3].follow)
    assert.are.equal("run", b.tiles[1].scope)        -- values don't change
    for _, t in ipairs(M.Create("leveling").tiles) do assert.are.equal(t.scope == "run" or nil, t.follow) end
  end)

  it("moves every following tile when the board's scope changes; tiles with their own scope stay", function()
    local env = boot()
    local M = env.M
    local b = M.Create("leveling")
    local today = M.AddReading(b, "hc:net", nil, "today")
    assert.is_nil(today.follow)                        -- not the board's scope: its own
    assert.is_true(M.SetBoardScope(b, "session"))
    assert.is_false(M.SetBoardScope(b, "session"))
    assert.are.equal("session", b.scope)
    local by = {}
    for _, t in ipairs(b.tiles) do by[#by + 1] = t.reading .. "@" .. t.scope end
    assert.same({ "hc:xpgained@session", "hc:xplevel@now", "hc:ttl@session", "hc:rested@now", "hc:xpgained@session",
      "hc:gold@session", "hc:net@today" }, by)
    -- the scope is said once, by the board: following tiles carry no word, others theirs
    assert.are.equal("XP gained", M.TileLabel(b.tiles[5], b))
    assert.are.equal("Net gold \194\183 today", M.TileLabel(today, b))
    assert.are.equal("XP this level \194\183 now", M.TileLabel(b.tiles[2], b))
    -- back on the timer, the following tiles come back; on the timer a session tile says so again
    M.SetBoardScope(b, "run")
    assert.is_nil(b.scope)
    assert.are.equal("run", b.tiles[1].scope)
    assert.are.equal("today", today.scope)
    assert.is_false(M.SetBoardScope(b, "now"))         -- not a board's scope
  end)

  it("hides Pause, Reset and Save as run off the board's timer: the session shows its clock, a calendar none", function()
    local env = boot()
    local M = env.M
    local b = M.Create("pocket")
    env.HC:Emit("hc:money.in", 40, "none", 1429)
    env:advance(400)
    assert.are.equal("timer", (M.BoardClock(b)))
    assert.is_true(M.OnTimer(b))
    M.SetBoardScope(b, "session")
    assert.is_false(M.OnTimer(b))
    assert.is_nil((M.BoardState(b)))
    assert.is_nil(M.BoardSavable(b))
    assert.is_nil(M.SaveBoard(b))
    assert.is_nil(M.ControlAll(b, "reset"))
    local kind, st, active = M.BoardClock(b)
    assert.are.equal("session", kind)
    assert.are.equal("running", st)
    assert.are.equal(env.ns.Win.Active(env.ns.Session()), active)
    assert.are.equal(0.5, M.TickRate(b, true))
    assert.is_true(M.HasHeader(b))
    assert.are.equal("run", M.Layout(b)[1].kind)       -- the header row: "Pocket · session"
    env.HC:SetTrackerHistory("hc:goldph", "daily")
    env.HC:SetTrackerHistory("hc:xpph", "daily")
    M.SetBoardScope(b, "today")
    assert.is_nil((M.BoardClock(b)))                  -- no clock on a calendar scope
    assert.are.equal(5, M.TickRate(b, true))
    assert.is_true(M.HasHeader(b))
  end)

  it("pauses the board's timer while the board is on another scope, and resumes it on coming back", function()
    local env = boot()
    local M = env.M
    local b = M.Create("pocket")
    local w = M.BoardWindow(b)
    env:advance(100)
    M.SetBoardScope(b, "session")
    assert.are.equal("paused", w.state)
    env:advance(500)
    M.SetBoardScope(b, "run")
    assert.are.equal("running", w.state)
    assert.are.equal(100, env.ns.Win.Elapsed(w))      -- the time on session isn't on its clock
    M.ControlAll(b, "pause")                           -- paused by the player: stays paused after a trip away
    M.SetBoardScope(b, "session")
    M.SetBoardScope(b, "run")
    assert.are.equal("paused", w.state)
  end)

  it("puts a new tile on the board's scope to follow it; picking another scope gives the tile its own", function()
    local env = boot()
    local M = env.M
    local b = M.Create(nil, { name = "Day" })
    M.SetBoardScope(b, "session")
    local gold = M.AddReading(b, "hc:gold")
    assert.are.equal("session", gold.scope)
    assert.is_true(gold.follow)
    local rested = M.AddReading(b, "hc:rested")        -- `now` only: can't follow
    assert.are.equal("now", rested.scope)
    assert.is_nil(rested.follow)
    local choices = {}
    for _, c in ipairs(M.ScopeChoices(gold, b)) do choices[#choices + 1] = c.scope .. (c.board and "*" or "") end
    assert.same({ "session*", "today", "week", "month", "year", "lifetime" }, choices)   -- no timer off the timer
    assert.are.equal("run", M.ScopeChoices(gold)[1].scope)                              -- (no board: as before)
    M.SetScope(gold, "week", b)
    assert.is_nil(gold.follow)
    M.SetBoardScope(b, "month")
    assert.are.equal("week", gold.scope)
    M.SetScope(gold, "month", b)
    assert.is_true(gold.follow)
  end)

  it("greys a calendar scope for the board while a following tile keeps no history, naming its tracker", function()
    local env = boot()
    local M = env.M
    local b = M.Create("pocket")
    local by = {}
    for _, c in ipairs(M.BoardScopeChoices(b)) do by[c.scope] = c end
    assert.is_true(by.run.ok)
    assert.is_true(by.session.ok)
    assert.is_false(by.today.ok)
    assert.are.equal("needs history", by.today.why)
    assert.same({ "hc:goldph", "hc:xpph" }, by.today.trackers)
    env.HC:SetTrackerHistory("hc:goldph", "daily")
    env.HC:SetTrackerHistory("hc:xpph", "daily")
    for _, c in ipairs(M.BoardScopeChoices(b)) do by[c.scope] = c end
    assert.is_true(by.today.ok)
  end)

  it("moves a following tile onto its new board's scope; a tile with its own scope keeps it", function()
    local env = boot()
    local M = env.M
    local day = M.Create(nil, { name = "Day" })
    M.SetBoardScope(day, "session")
    local gold = M.AddReading(day, "hc:gold")
    local net = M.AddReading(day, "hc:net", nil, "week")
    local farm = M.Create("pocket")
    M.MoveTo(day, 1, farm)
    assert.are.equal("run", gold.scope)
    assert.is_true(gold.follow)
    M.MoveTo(day, 1, farm)
    assert.are.equal("week", net.scope)
    M.MoveTo(farm, #farm.tiles - 1, day)              -- back to the session board: off the timer
    assert.are.equal("session", gold.scope)
  end)
end)
