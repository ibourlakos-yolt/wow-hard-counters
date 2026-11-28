-- The trend calc and badge (HC-53, DESIGN §16.9): recent / per hour - 1 over the tile's scope, a signed %, neutral
-- inside ±10%, shown only when both are settled; a number tile of its own or a badge on a big per hour/recent tile.
local Env = require("env")

local function boot()
  Env.BASICS = true
  local env = Env.new()
  local game = { money = 100000, xp = 100, xpMax = 10000, level = 20 }
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

local T, P, RC = { calc = "trend" }, { calc = "perHour" }, { calc = "recent" }

--- an hour at `a` copper a minute, then `m` minutes at `b`
local function pace(env, a, m, b)
  for _ = 1, 60 do env:advance(60); env.HC:Emit("hc:money.in", a, "none", 1429) end
  for _ = 1, m do env:advance(60); env.HC:Emit("hc:money.in", b, "none", 1429) end
end

describe("the trend calc (HC-53)", function()
  it("is recent against per hour over the same scope, in %", function()
    local env = boot()
    local HC = env.HC
    pace(env, 100, 15, 300)
    local rec = HC:Reading("hc:gold", "session", RC)
    local per = HC:Reading("hc:gold", "session", P)
    local v, text, settled, state = HC:Reading("hc:gold", "session", T)
    assert.is_near((rec / per - 1) * 100, v, 1e-6)
    assert.is_true(v > 90)                                         -- three times the pace, against an average lifted by it
    assert.are.equal(env.ns.TrendText(v), text)
    assert.truthy(text:match(" faster$"))                         -- in words (HC-54)
    assert.is_true(settled)
    assert.is_nil(state)
    assert.are.equal("up", env.ns.TrendState(v))
    assert.are.equal("Gold/h trend", env.ns.ReadingTitle(env.ns.readings["hc:gold"], nil, "trend"))
  end)

  it("is neutral inside ±10%, down below, and words its sign", function()
    local env = boot()
    local ns = env.ns
    -- a steady pace, a gain every 15 s: right after a gain recent sits (dt/tau)/(1 - exp(-dt/tau)) above the average,
    -- about 2% at a gain every 15 s (one a minute: about 7%; one every 3 minutes: about 23%, outside the band: DESIGN 16.9)
    for _ = 1, 240 do env:advance(15); env.HC:Emit("hc:money.in", 25, "none", 1429) end
    local v = env.HC:Reading("hc:gold", "session", T)
    assert.is_true(math.abs(v) < 5)   -- (+3.5% here: the sawtooth, and gains that land at the start of each 15 s fold)
    assert.are.equal("flat", ns.TrendState(v))
    assert.are.equal("flat", ns.TrendState(9.9))
    assert.are.equal("up", ns.TrendState(10))
    assert.are.equal("down", ns.TrendState(-10))
    -- in words (HC-54): "on pace" inside the band, "% slower", "% faster", and a multiple from twice the pace up
    local X = "×"                                         -- the multiplication sign, Latin-1 in UTF-8
    assert.are.equal("on pace", ns.TrendText(0.3))
    assert.are.equal("on pace", ns.TrendText(-8.4))
    assert.are.equal("on pace", ns.TrendText(9.9))
    assert.are.equal("10% slower", ns.TrendText(-10))
    assert.are.equal("87% slower", ns.TrendText(-87.2))
    assert.are.equal("100% slower", ns.TrendText(-100))
    assert.are.equal("13% faster", ns.TrendText(12.6))
    assert.are.equal("99% faster", ns.TrendText(99.4))
    assert.are.equal("2" .. X .. " faster", ns.TrendText(99.6))
    assert.are.equal("2" .. X .. " faster", ns.TrendText(100))
    assert.are.equal("2.7" .. X .. " faster", ns.TrendText(170))
    assert.are.equal("12" .. X .. " faster", ns.TrendText(1080))
    pace(env, 0, 20, 0)                                           -- an hour of nothing more
    assert.are.equal("down", ns.TrendState((env.HC:Reading("hc:gold", "session", T))))
  end)

  it("has no value until both recent and per hour are settled", function()
    local env = boot()
    local HC = env.HC
    for _ = 1, 3 do env:advance(120); HC:Emit("hc:money.in", 100, "none", 1429) end
    local v, text, settled = HC:Reading("hc:gold", "session", T)
    assert.is_nil(v)
    assert.are.equal("-", text)
    assert.is_false(settled)
  end)

  it("is kept where recent is: not over a calendar period, the account, a stock", function()
    local env = boot()
    local HC = env.HC
    HC:SetTrackerHistory("hc:goldph", "daily")
    assert.are.equal("calc", select(4, HC:Reading("hc:gold", "today", T)))
    assert.are.equal("calc", select(4, HC:Reading("hc:gold", "session", { calc = "trend", who = "account" })))
    assert.are.equal("calc", select(4, HC:Reading("hc:owned", "now", T)))
    assert.are.equal("calc", select(4, HC:Reading("hc:ttl", "session", T)))      -- its calcs are total and recent
    assert.are.same({ "total", "perHour", "recent", "trend" }, HC:GetReading("hc:gold").calcs)
  end)
end)

describe("trend on a board (HC-53)", function()
  it("is a number tile of its own: only Number takes it", function()
    local env = boot()
    local M = env.M
    local b = M.Create(nil, { name = "B", shown = true })
    local t = M.AddReading(b, "hc:gold", { calc = "trend" })
    assert.are.equal("trend", t.calc)
    assert.are.equal("Gold/h trend", M.TileTitle(t))
    M.SetTarget(t, "1")
    M.SetDisplay(t, "gauge")
    assert.are.equal("perHour", t.calc)                           -- a gauge takes no trend
    local ok, why
    for _, c in ipairs(M.CalcChoices(t)) do if c.calc == "trend" then ok, why = c.ok, c.why end end
    assert.are.same({ false, "display" }, { ok, why })
  end)

  it("is a badge on a big per hour or recent tile, switched from the tile menu", function()
    local env = boot()
    local M = env.M
    local b = M.Create(nil, { name = "Farm", shown = true })
    local t = M.AddReading(b, "hc:gold", { calc = "perHour", size = "large" })
    assert.is_true(M.TrendBadgeFits(t))
    assert.is_nil(M.TrendBadge(t, b))                             -- off by default
    assert.is_true(M.SetExtra(t, "trend", true))
    assert.is_false(M.SetExtra(t, "trend", true))
    pace(env, 100, 15, 300)
    local v, st = M.TrendBadge(t, b)
    assert.is_true(v > 10)
    assert.are.equal("up", st)
    M.SetCalc(t, "total")
    assert.is_false(M.TrendBadgeFits(t))                          -- not on a total
    assert.is_nil(M.TrendBadge(t, b))
    M.SetCalc(t, "recent")
    assert.is_true(M.TrendBadgeFits(t))
    M.SetSize(t, "half")
    assert.is_true(M.TrendBadgeFits(t))                           -- (0.5.0) any number tile: an arrow on the smaller sizes
    M.SetSize(t, "lineHalf")
    assert.is_true(M.TrendBadgeFits(t))
    local owned = M.AddReading(b, "hc:owned", { size = "large" })
    assert.is_false(M.TrendBadgeFits(owned))
  end)
end)

describe("the trend badge on screen (HC-53)", function()
  it("draws an arrow and a coloured % beside the big number, and the menu switches it", function()
    local UI = require("ui_boot")
    UI.with(function(ctx)
      local HC, ns, env = ctx.HC, ctx.hc, ctx.env
      local M, B = ns.BoardModel, ns.Boards
      local b = M.Create(nil, { name = "Pace", shown = true })
      local t = M.AddReading(b, "hc:gold", { calc = "perHour", size = "large" })
      t.scope = "session"
      B.Refresh(b.id, true)
      local f = B.Frame(b.id)
      local items
      local realShow = ns.Menu.Show
      ns.Menu.Show = function(_, it) items = it end
      B.TileMenu(f.rowFrames[1], b, 1)
      ns.Menu.Show = realShow
      local badge
      for _, it in ipairs(items) do if it.text == "Trend badge" then badge = it end end
      assert.truthy(badge)
      assert.is_false(badge.checked)
      badge.func()
      assert.is_true(M.HasExtra(t, "trend"))
      for _ = 1, 60 do env:advance(60); HC:Emit("hc:money.in", 100, "none", 1429) end
      for _ = 1, 15 do env:advance(60); HC:Emit("hc:money.in", 300, "none", 1429) end
      B.Refresh(b.id, true)
      local w
      for _, rf in ipairs(f.rowFrames) do if rf.row and rf.row.kind == "hero" then w = rf end end
      assert.truthy(w.trend:GetText():match(" faster$"))
      assert.is_true(w.trendArrow:IsShown())
      -- the gold arrow art is greyed before the tint, so the arrow is the words' colour (it drew orange, 2026-11-20)
      local desat, tint
      w.trendArrow.SetDesaturated = function(_, v) desat = v end
      w.trendArrow.SetVertexColor = function(_, r, g, bl) tint = { r, g, bl } end
      B.Refresh(b.id)
      assert.is_true(desat)
      assert.are.same({ 0.38, 1, 0.38 }, tint)
      assert.are.same({}, ctx.env.errors)
    end)
  end)
end)

describe("trend against past runs", function()
  local function pastRuns(env, HC)
    for i = 1, 3 do
      HC:StartRun("R" .. i)
      HC:Emit("hc:money.in", i * 1000, "none", 1429)
      env:advance(3600)
      HC:StopRun()
    end
  end

  it("has no value in a past run, so no average of it here", function()
    local env = boot()
    local M, ns = env.M, env.ns
    pastRuns(env, env.HC)
    local rec = env.HC:Runs({ character = "current", limit = 1 })[1]
    assert.is_nil((ns.Widgets.RecordReading(ns.readings["hc:gold"], rec, "trend")))
    assert.are.equal(2000, (M.ZoneAverage("hc:gold", 1429, nil, "perHour")))
    assert.is_nil(M.ZoneAverage("hc:gold", 1429, nil, "trend"))
  end)

  it("shows no \"vs your average here\" on a big trend tile", function()
    local UI = require("ui_boot")
    UI.with(function(ctx)
      local HC, ns, env = ctx.HC, ctx.hc, ctx.env
      local M, B = ns.BoardModel, ns.Boards
      pastRuns(env, HC)
      ns.currentZone = 1429
      local b = M.Create(nil, { name = "Pocket", shown = true })
      local t = M.AddReading(b, "hc:gold", { calc = "perHour", size = "large" })
      t.scope = "run"
      t.extras = { sparkline = true, vsUsual = true }          -- as the user's Pocket board had them
      B.Refresh(b.id, true)
      for _ = 1, 20 do env:advance(60); HC:Emit("hc:money.in", 100, "none", 1429) end
      local f = B.Frame(b.id)
      local function compare()
        B.Refresh(b.id, true)
        for _, rf in ipairs(f.rowFrames) do
          if rf.row and rf.row.kind == "hero" then return rf.compare:GetText() or "" end
        end
      end
      assert.truthy(compare():find("vs your average here"))  -- per hour: the board against past runs here
      M.SetCalc(t, "trend")
      assert.are.equal("", compare())                          -- a % has no past-run average to compare with
      assert.are.same({}, ctx.env.errors)
    end)
  end)
end)
