-- Targets, bars and live values (HC-33, DESIGN 16.6): a reading's natural target or a tile's own, the bar style,
-- refresh events only while a reading is placed, and the dirty flag displays redraw on.
local Env = require("env")

local function boot()
  Env.BASICS = true
  local env = Env.new()
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

describe("targets and bars", function()
  it("a reading has a natural target, a number or a function of the argument; a tile may set its own", function()
    local env = boot()
    local M, HC = env.M, env.HC
    assert.are.equal(1000, HC:ReadingTarget("hc:xplevel"))
    assert.is_nil(HC:ReadingTarget("hc:gold"))
    HC:RegisterPack("Test", { namespace = "t" })
    HC:RegisterReading("t:fixed", { title = "Fixed", scopes = { "now" }, compute = function() return 30 end, target = 200 })
    HC:RegisterReading("t:byarg", { title = "%s left", scopes = { "now" }, param = { dim = "x" },
      compute = function(_, _, arg) return arg end, target = function(arg) return arg * 10 end })
    HC:RegisterReading("t:broken", { title = "Broken", scopes = { "now" }, compute = function() return 1 end,
      target = function() error("boom") end })
    assert.are.equal(200, HC:ReadingTarget("t:fixed"))
    assert.are.equal(70, HC:ReadingTarget("t:byarg", 7))
    assert.is_nil(HC:ReadingTarget("t:broken"))
    assert.has_error(function() HC:RegisterReading("t:bad", { counter = "hc:xp", target = "lots" }) end)

    local b = M.Create(nil, { name = "B" })
    local xp = M.AddReading(b, "hc:xplevel", "bar")
    assert.are.equal(1000, M.TileTarget(xp))
    local frac, text, done = M.Progress(xp)
    assert.are.equal(0.1, frac)
    assert.are.equal("100 / 1,000", text)
    assert.is_false(done)
    env.game.xp = 1000
    frac, text, done = M.Progress(xp)
    assert.are.equal(1, frac)
    assert.is_true(done)

    -- a goal the player sets: money in gold; empty clears it
    local gold = M.AddReading(b, "hc:gold", "bar")
    assert.is_nil(M.TileTarget(gold))
    assert.is_nil((M.Progress(gold)))
    assert.is_true(M.SetTarget(gold, "2"))
    assert.are.equal(20000, M.TileTarget(gold))
    HC:Emit("hc:money.in", 5000, "none", 1429)
    frac, text = M.Progress(gold)
    assert.are.equal(0.25, frac)
    assert.are.equal("50s 0c / 2g 0s 0c", text)
    HC:Emit("hc:money.in", 50000, "none", 1429)
    frac, text, done = M.Progress(gold)
    assert.are.equal(1, frac)                                  -- past the goal: a full bar
    assert.is_true(done)
    M.SetTarget(gold, "")
    assert.is_nil(M.TileTarget(gold))
    -- the tile's own beats the reading's
    M.SetTarget(xp, "500")
    assert.are.equal(500, M.TileTarget(xp))
  end)

  it("the bar display is a row of its own height; the leveling preset has the XP bar", function()
    local env = boot()
    local M = env.M
    local b = M.Create("leveling")
    local rows = M.Layout(b, { noControls = true })
    assert.are.equal("hero", rows[1].kind)
    assert.are.equal("bar", rows[2].kind)
    assert.are.equal(M.HEIGHT.bar, rows[2].h)
    assert.is_true(M.SetDisplay(b.tiles[2], "number"))
    assert.are.equal("row", M.Layout(b)[3].kind)                -- after the control row (HC-41)
    assert.is_true(M.SetDisplay(b.tiles[2], "bar"))
    assert.is_true(M.SetDisplay(b.tiles[2], "gauge"))
    assert.are.equal("gauge", M.Layout(b)[3].kind)
    assert.are.equal(M.HEIGHT.gauge, M.Layout(b)[3].h)
    assert.is_false(M.SetDisplay(b.tiles[2], "dial"))
    assert.is_false(M.SetSize(b.tiles[2], "half"))   -- HC-51 draws a gauge as a line only
  end)

  it("no empty bars or dials: without a target a bar or a gauge is laid out as a row (HC-33, statement 17b)", function()
    local env = boot()
    local M = env.M
    local b = M.Create(nil, { name = "B" })
    local NC = { noControls = true }
    local gold = M.AddReading(b, "hc:gold", { display = "gauge" })
    assert.are.equal("row", M.Layout(b, NC)[1].kind)
    M.SetTarget(gold, "2")
    assert.are.equal("gauge", M.Layout(b, NC)[1].kind)
    M.SetDisplay(gold, "bar")
    assert.are.equal("bar", M.Layout(b, NC)[1].kind)
    M.SetTarget(gold, "")
    assert.are.equal("row", M.Layout(b, NC)[1].kind)
  end)

  it("listens to a computed reading's refresh events only while it is on a shown board", function()
    local env = boot()
    local M, ns = env.M, env.ns
    ns.dirty = false
    env:fire("PLAYER_XP_UPDATE", "player")                     -- (Basics' own handler runs; nothing changed)
    assert.is_false(ns.dirty)
    local b = M.Create(nil, { name = "B" })
    M.AddReading(b, "hc:xplevel", "bar")
    ns.SetPlacedReadings(M.PlacedReadings())
    env:fire("PLAYER_LEVEL_UP", 21)
    assert.is_true(ns.dirty)
    ns.dirty = false
    b.shown = false
    ns.SetPlacedReadings(M.PlacedReadings())
    env:fire("PLAYER_LEVEL_UP", 22)
    assert.is_false(ns.dirty)
  end)

  it("marks displays dirty at every write, and not when a write is refused", function()
    local env = boot()
    local ns, HC = env.ns, env.HC
    ns.dirty = false
    HC:Emit("hc:money.in", 10, "none", 1429)
    assert.is_true(ns.dirty)
    ns.dirty = false
    HC:Observe("hc:money.owned", 5)
    assert.is_true(ns.dirty)
    ns.dirty = false
    HC:Emit("hc:money.in", env:secretValue(), "none", 1429)
    assert.is_false(ns.dirty)
  end)
end)

describe("the gauge on screen (HC-33)", function()
  it("lights its dots toward the target, green when reached; choosing it without a target asks for one", function()
    local UI = require("ui_boot")
    UI.with(function(ctx)
      local HC, ns = ctx.HC, ctx.hc
      local M, B = ns.BoardModel, ns.Boards
      local b = M.Create(nil, { name = "Goal" })
      local gold = M.AddReading(b, "hc:gold")
      gold.scope = "session"
      B.Refresh(b.id, true)
      local f = B.Frame(b.id)
      -- choosing Gauge asks "Gauge toward (gold):"; cancelling keeps the row
      local asked
      local realShow = ns.Menu.Show
      local items
      ns.Menu.Show = function(_, it) items = it end
      B.TileMenu(f.rowFrames[1], b, 1)
      ns.Menu.Show = realShow
      local displays
      for _, it in ipairs(items) do if it.text == "Display" then displays = it.sub end end
      local gauge
      for _, it in ipairs(displays) do if it.text == "Gauge" then gauge = it end end
      local realPopup = _G.StaticPopup_Show
      _G.StaticPopup_Show = function(_, a1, _, data) asked = a1 or (data and data.prompt) or true; return nil end
      gauge.func()
      _G.StaticPopup_Show = realPopup
      assert.are.equal("Gauge toward (gold):", asked)
      assert.are.equal("number", gold.display)
      -- with a target it draws as a gauge
      M.SetTarget(gold, "1")
      M.SetDisplay(gold, "gauge")
      B.Refresh(b.id, true)
      local w
      for _, rf in ipairs(f.rowFrames) do if rf.row and rf.row.kind == "gauge" then w = rf end end
      assert.truthy(w and w.dots)
      HC:Emit("hc:money.in", 5000, "none", 1429)             -- half of 1 gold
      B.Refresh(b.id, true)
      for _, rf in ipairs(f.rowFrames) do if rf.row and rf.row.kind == "gauge" then w = rf end end
      assert.are.equal("50s 0c / 1g 0s 0c", w.value:GetText())
      assert.are.same({}, ctx.env.errors)
    end)
  end)
end)
