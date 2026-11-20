-- A tile's calc, display and size (HC-51, DESIGN §16.9): HC:Reading's options table, the calcs a reading allows,
-- the twins folded into hidden aliases, the one migration of saved tiles and presets, packs' `per` and `style`.
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

local function earn(env, copper, xp)
  local HC = env.HC
  HC:Emit("hc:money.in", copper, "none", 1429)
  if xp then HC:Emit("hc:xp", xp, "none", 1429) end
end

describe("the calc (HC-51)", function()
  it("reads total and per hour from one reading, by an options table; the positional form still works", function()
    local env = boot()
    local HC = env.HC
    earn(env, 3000, 50)
    HC:Emit("hc:money.out", 1000, "repair", 1429)
    env:advance(1800)                                   -- half an hour active
    assert.are.equal(3000, (HC:Reading("hc:gold", "session")))
    assert.are.equal(3000, (HC:Reading("hc:gold", "session", { calc = "total" })))
    local v, text, settled = HC:Reading("hc:gold", "session", { calc = "perHour" })
    assert.are.equal(6000, v)
    assert.are.equal("60s 0c/h", text)
    assert.is_true(settled)
    assert.are.equal(4000, (HC:Reading("hc:net", "session", { calc = "perHour" })))
    assert.are.equal(100, (HC:Reading("hc:xpgained", "session", { calc = "perHour" })))
    -- the twins are aliases: the same values as before, by the same calls
    assert.are.equal(6000, (HC:Reading("hc:goldph", "session")))
    assert.are.equal(4000, (HC:Reading("hc:netph", "session")))
    assert.are.equal(100, (HC:Reading("hc:xpph", "session")))
    assert.are.equal(3000, (HC:Reading("hc:goldph", "session", { calc = "total" })))
    -- the options table carries arg and who too
    assert.are.equal(1000, (HC:Reading("hc:spenton", "session", { arg = "repair" })))
    assert.are.equal(1000, (HC:Reading("hc:spenton", "session", "repair")))
    assert.are.equal(2000, (HC:Reading("hc:spenton", "session", { arg = "repair", calc = "perHour" })))
  end)

  it("allows what the reading's kind allows: a stock and a computed reading total only; else state calc", function()
    local env = boot()
    local HC, ns = env.HC, env.ns
    assert.are.same({ "total", "perHour", "recent", "trend" }, HC:GetReading("hc:gold").calcs)   -- (recent: HC-52)
    assert.are.same({ "total" }, HC:GetReading("hc:owned").calcs)
    assert.are.same({ "total", "recent" }, HC:GetReading("hc:ttl").calcs)   -- (it lists them: HC-52)
    local v, text, settled, state = HC:Reading("hc:owned", "now", { calc = "perHour" })
    assert.is_nil(v)
    assert.are.equal("-", text)
    assert.is_true(settled)
    assert.are.equal("calc", state)
    assert.are.equal("calc", select(4, HC:Reading("hc:gold", "session", { calc = "sideways" })))
    assert.are.equal("total", ns.DefaultCalc(ns.readings["hc:gold"]))
    assert.are.equal("perHour", ns.DefaultCalc(ns.readings["hc:goldph"]))
    -- time to level still reads XP/h through the alias
    earn(env, 0, 450)
    env:advance(3600)
    assert.are.equal(450, (HC:Reading("hc:xpph", "session")))
    assert.are.equal(7200, (HC:Reading("hc:ttl", "session")))   -- 900 XP left in the level at 450/h
  end)

  it("keeps packs' `per` readings working: per hour by default, and per hour only without a rateTitle", function()
    local env = boot()
    local HC = env.HC
    HC:RegisterReading("tp:fishph", { title = "Fish/h", tracker = "hc:goldph", counter = "hc:money.in",
      per = "activeHour", scopes = { "run", "session" } })
    HC:RegisterReading("tp:fish", { title = "Fish", rateTitle = "Fish per hour", tracker = "hc:goldph",
      counter = "hc:money.in", per = "activeHour", scopes = { "run", "session" } })
    earn(env, 500)
    env:advance(1800)
    assert.are.equal(1000, (HC:Reading("tp:fishph", "session")))
    assert.are.same({ "perHour", "recent", "trend" }, HC:GetReading("tp:fishph").calcs)
    assert.are.equal("activeHour", HC:GetReading("tp:fishph").per)
    assert.are.equal("calc", select(4, HC:Reading("tp:fishph", "session", { calc = "total" })))
    assert.are.same({ "total", "perHour", "recent", "trend" }, HC:GetReading("tp:fish").calcs)
    assert.are.equal(500, (HC:Reading("tp:fish", "session", { calc = "total" })))
    assert.are.equal(1000, (HC:Reading("tp:fish", "session")))
  end)

  it("names each calc: the rate title, the total title, '/h' when a reading has none", function()
    local env = boot()
    local HC, ns = env.HC, env.ns
    local gold, goldph = ns.readings["hc:gold"], ns.readings["hc:goldph"]
    assert.are.equal("Gold earned", ns.ReadingTitle(gold, nil, "total"))
    assert.are.equal("Gold/h", ns.ReadingTitle(gold, nil, "perHour"))
    assert.are.equal("Gold/h", ns.ReadingTitle(goldph, nil, "perHour"))
    assert.are.equal("Gold earned", ns.ReadingTitle(goldph, nil, "total"))
    assert.are.equal("Gold from quests/h", ns.ReadingTitle(ns.readings["hc:goldfrom"], "quests", "perHour"))
    assert.are.equal("Gold/h", HC:GetReading("hc:gold").rateTitle)
  end)

  it("hides aliases from the catalog, keeps them in the run lists, and copies them as aliases", function()
    local env = boot()
    local HC, ns = env.HC, env.ns
    local function has(list, id) for _, x in ipairs(list) do if (x.id or x) == id then return true end end return false end
    assert.is_false(has(ns.allReadingOrder, "hc:goldph"))
    assert.is_false(has(HC:Readings(), "hc:goldph"))
    assert.is_false(has(HC:Readings({ tracker = "hc:goldph" }), "hc:netph"))
    assert.is_true(has(HC:Readings({ aliases = true }), "hc:goldph"))
    assert.is_true(has(ns.readingOrder, "hc:goldph"))        -- the run list and summary card keep Gold/h
    assert.is_true(has(ns.readingOrder, "hc:gold"))
    local c = HC:GetReading("hc:goldph")
    assert.are.equal("hc:gold", c.aliasOf)
    assert.are.equal("perHour", c.calc)
    assert.are.equal("Gold/h", c.title)
    assert.are.equal("hc:goldph", env.ns.Widgets.HeadlineId())   -- the launcher's headline is unchanged
    assert.has_error(function() HC:RegisterReading("tp:x", { aliasOf = "tp:none", calc = "perHour" }) end)
    assert.has_error(function() HC:RegisterReading("tp:y", { aliasOf = "hc:goldph" }) end)   -- no alias of an alias
    assert.has_error(function() HC:RegisterReading("tp:z", { aliasOf = "hc:gold", calc = "fast" }) end)
    assert.has_error(function() HC:RegisterReading("tp:w", { counter = "hc:money.in", calcs = { "total" } }) end)
  end)

  it("passes the calc to a computed reading, which lists the calcs it answers", function()
    local env = boot()
    local HC = env.HC
    local seen
    HC:RegisterReading("tp:double", { title = "Double", tracker = "hc:goldph", scopes = { "session" },
      calcs = { "perHour", "total" }, inputs = { "hc:gold" },
      compute = function(get, scope, _, calc)
        seen = calc
        return 2 * (get("hc:gold", scope, calc) or 0)
      end })
    assert.are.same({ "total", "perHour" }, HC:GetReading("tp:double").calcs)   -- in menu order
    earn(env, 100)
    env:advance(1800)
    assert.are.equal(200, (HC:Reading("tp:double", "session")))
    assert.are.equal("total", seen)
    assert.are.equal(400, (HC:Reading("tp:double", "session", { calc = "perHour" })))
    assert.are.equal("perHour", seen)
  end)

  it("reads a saved run with a calc, as the alias did", function()
    local env = boot()
    local HC, Wd, ns = env.HC, env.ns.Widgets, env.ns
    HC:StartRun("r")
    earn(env, 1000)
    env:advance(600)
    local id = HC:StopRun()
    local rec = HC:GetRunRecord(id)
    assert.are.equal(6000, (Wd.RecordReading(ns.readings["hc:goldph"], rec)))
    assert.are.equal(6000, (Wd.RecordReading(ns.readings["hc:gold"], rec, "perHour")))
    assert.are.equal(1000, (Wd.RecordReading(ns.readings["hc:gold"], rec)))
    local _, text = Wd.RecordReading(ns.readings["hc:gold"], rec, "perHour")
    assert.are.equal("60s 0c/h", text)
  end)
end)

describe("a tile's calc, display and size (HC-51)", function()
  it("migrates every saved style once, and folds the twins: the values don't change", function()
    local tiles = {
      { kind = "reading", reading = "hc:goldph", scope = "session", style = "hero" },
      { kind = "reading", reading = "hc:xpph", scope = "session", style = "grid" },
      { kind = "reading", reading = "hc:netph", scope = "session", style = "grid" },
      { kind = "reading", reading = "hc:gold", scope = "session", style = "row" },
      { kind = "reading", reading = "hc:xplevel", scope = "now", style = "bar", target = 5000 },
      { kind = "reading", reading = "hc:gold", scope = "session", style = "gauge", target = 10000 },
      { kind = "reading", reading = "hc:goldph", scope = "session", style = "row", calc = "total" },
      { kind = "splits" },
    }
    local env = boot({ boards = { list = { { id = "b1", name = "Old", shown = true, mini = false, width = 260, show = {},
      tiles = tiles } }, nextId = 2, seeded = true, v = 2 } })
    local M = env.M
    local b = M.Store().list[1]
    assert.are.equal(5, M.Store().v)
    local t = b.tiles
    assert.are.same({ kind = "reading", reading = "hc:gold", scope = "session", calc = "perHour", display = "number",
      size = "large", extras = { sparkline = true, vsUsual = true } }, t[1])
    assert.are.same({ "hc:xpgained", "perHour", "number", "half" }, { t[2].reading, t[2].calc, t[2].display, t[2].size })
    assert.are.same({ "hc:net", "perHour", "number", "half" }, { t[3].reading, t[3].calc, t[3].display, t[3].size })
    assert.are.same({ "hc:gold", "number", "line" }, { t[4].reading, t[4].display, t[4].size })
    assert.is_nil(t[4].calc)
    assert.are.same({ "bar", "line", 5000 }, { t[5].display, t[5].size, t[5].target })
    assert.are.same({ "gauge", "line" }, { t[6].display, t[6].size })
    assert.are.equal("total", t[7].calc)                  -- a calc of its own is kept
    for _, x in ipairs(t) do assert.is_nil(x.style) end
    assert.are.equal("splits", t[8].kind)
    -- footprints as before: hero, a grid pair, a row, a bar, a gauge, a row, splits
    local kinds = {}
    for _, r in ipairs(M.Layout(b)) do kinds[#kinds + 1] = r.kind .. #r.tiles end
    assert.are.same({ "hero1", "grid2", "row1", "bar1", "gauge1", "row1", "splits1" }, kinds)
    assert.are.equal(1, M.HeroIndex(b))
    -- values and labels as the twins gave them
    earn(env, 3000, 40)
    env:advance(1800)
    assert.are.equal(6000, (M.TileValue(t[1], b)))
    assert.are.equal("Gold/h \194\183 session", M.TileLabel(t[1], b))
    assert.are.equal(80, (M.TileValue(t[2], b)))
    assert.are.equal("XP/h \194\183 session", M.TileLabel(t[2], b))
    assert.are.equal("Net gold/h \194\183 session", M.TileLabel(t[3], b))
    assert.are.equal(3000, (M.TileValue(t[4], b)))
    assert.are.equal("Gold earned \194\183 session", M.TileLabel(t[4], b))
    assert.are.equal(3000, (M.TileValue(t[7], b)))
    M.Store()                                             -- once
    assert.are.equal("perHour", t[1].calc)
  end)

  it("builds the presets on the new model and still reads a pack's style", function()
    local env = boot()
    local HC, M = env.HC, env.M
    local pocket = M.Create("pocket")
    assert.are.equal("hc:gold", pocket.tiles[1].reading)
    assert.are.equal("perHour", pocket.tiles[1].calc)
    assert.are.equal("large", pocket.tiles[1].size)
    HC:RegisterBoardPreset("tp:p", { name = "P", tiles = {
      { reading = "hc:gold", scope = "session", style = "grid" },
      { reading = "hc:goldph", scope = "session", display = "number", size = "large", extras = { "sparkline" } },
      { reading = "hc:xplevel", scope = "now", display = "bar" },
      { reading = "hc:gold", scope = "session", calc = "perHour" },
    } })
    local b = M.Create("tp:p")
    assert.are.same({ "number", "half" }, { b.tiles[1].display, b.tiles[1].size })
    assert.are.same({ "hc:gold", "perHour", "large" }, { b.tiles[2].reading, b.tiles[2].calc, b.tiles[2].size })
    assert.are.same({ sparkline = true }, b.tiles[2].extras)
    assert.are.same({ "bar", "line" }, { b.tiles[3].display, b.tiles[3].size })
    assert.are.same({ "perHour", "number", "line" }, { b.tiles[4].calc, b.tiles[4].display, b.tiles[4].size })
    for _, bad in ipairs({ { style = "huge" }, { display = "dial" }, { size = "tiny" }, { calc = "fast" } }) do
      bad.reading = "hc:gold"
      assert.has_error(function() HC:RegisterBoardPreset("tp:bad", { tiles = { bad } }) end)
    end
  end)

  it("folds a pack's alias registered after the boards were read (FM-17's hcfarm:vendorph)", function()
    local env = boot({ boards = { list = { { id = "b1", name = "Old", shown = true, mini = false, width = 260, show = {},
      tiles = { { kind = "reading", reading = "tp:goldph", scope = "session", style = "grid" } } } },
      nextId = 2, seeded = true, v = 2 } })
    local HC, M = env.HC, env.M
    local t = M.Store().list[1].tiles[1]
    assert.are.equal("tp:goldph", t.reading)              -- unknown yet: kept as it is
    HC:RegisterReading("tp:goldph", { aliasOf = "hc:gold", calc = "perHour" })
    assert.are.equal(1, M.FoldAliases())                  -- (Boards.lua calls it when readings change)
    assert.are.same({ "hc:gold", "perHour" }, { t.reading, t.calc })
    assert.are.equal(0, M.FoldAliases())
  end)

  it("offers Show as for the calcs a reading allows, Size for the sizes a display draws", function()
    local env = boot()
    local M = env.M
    local b = M.Create(nil, { name = "B" })
    local gold = M.AddReading(b, "hc:gold")
    local owned = M.AddReading(b, "hc:owned")
    local function calcs(t) local o = {} for _, c in ipairs(M.CalcChoices(t)) do o[#o + 1] = c.calc end return o end
    assert.are.same({ "total", "perHour", "recent", "trend" }, calcs(gold))
    assert.are.same({ "total" }, calcs(owned))
    assert.are.equal("total", M.TileCalc(gold))
    assert.is_true(M.SetCalc(gold, "perHour"))
    assert.are.equal("Gold/h", M.TileTitle(gold))
    assert.is_false(M.SetCalc(owned, "perHour"))
    assert.are.same({ "large", "half", "line" }, M.SizeChoices(gold))
    assert.is_true(M.SetSize(gold, "large"))
    assert.are.same({ sparkline = true, vsUsual = true }, gold.extras)
    assert.are.equal("hero", M.Footprint(gold))
    assert.is_true(M.SetDisplay(gold, "bar"))             -- a bar is a line
    assert.are.equal("line", gold.size)
    assert.are.same({ "line" }, M.SizeChoices(gold))
    assert.are.equal("row", M.Footprint(gold))            -- no target: no empty bar
    M.SetTarget(gold, "1")                                -- 1 gold per hour
    assert.are.equal("bar", M.Footprint(gold))
    earn(env, 5000)
    env:advance(3600)
    local _, ptext = M.Progress(gold, b)
    assert.are.equal("50s 0c/h / 1g 0s 0c/h", ptext)
  end)

  it("shows the splits in the hero's calc (the Run board's Gold/h stays per hour)", function()
    local env = boot()
    local HC, M = env.HC, env.M
    HC:StartRun("r")
    earn(env, 1000)
    env:advance(600)
    assert.are.equal("Split 1   60s 0c/h", M.SplitsText("hc:gold", "perHour"))
    assert.are.equal("Split 1   10s 0c", M.SplitsText("hc:gold"))
  end)

  it("takes a reading's natural target only for the total", function()
    local env = boot()
    local M = env.M
    local b = M.Create(nil, { name = "B" })
    local lvl = M.AddReading(b, "hc:xplevel", { display = "bar" })
    assert.are.equal(1000, M.TileTarget(lvl))
    local xp = M.AddReading(b, "hc:xpgained", { calc = "perHour" })
    assert.is_nil(M.TileTarget(xp))
  end)
end)
