-- The recent calc (HC-52, DESIGN §16.9): an exponentially weighted rate over a window with its own clock, half-life
-- 5 minutes, settled after 5 active minutes and 5 gains, frozen while AFK, kept across /reload.
local Env = require("env")

local function globals(game)
  _G.GetMoney = function() return game.money end
  _G.UnitXP = function() return game.xp end
  _G.UnitXPMax = function() return game.xpMax end
  _G.UnitLevel = function() return game.level end
  _G.GetXPExhaustion = function() return 0 end
end

local function ui(env)
  local ns = env.ns
  ns.AddSlash = function() end
  ns.AddOptions = function() end
  for _, f in ipairs({ "UI/Widgets.lua", "UI/BoardModel.lua" }) do
    assert(loadfile(Env.ROOT .. "/" .. f))("HardCounters", ns)
  end
  env.M = ns.BoardModel
end

local function boot()
  Env.BASICS = true
  local env = Env.new()
  local game = { money = 100000, xp = 100, xpMax = 10000, level = 20 }
  env.game = game
  globals(game)
  env:boot()
  Env.BASICS = nil
  ui(env)
  return env
end

local function reload(env)
  Env.BASICS = true
  globals(env.game)
  local r = env:reload()
  Env.BASICS = nil
  r.game = env.game
  ui(r)
  return r
end

local TAU = 300 / math.log(2)
local function weight(a) return TAU * (1 - math.exp(-a / TAU)) end
local R = { calc = "recent" }

local function recent(HC, id, scope) return HC:Reading(id, scope or "session", R) end

describe("the recent calc (HC-52)", function()
  it("weights a gain by exp(-age/tau): half after 5 active minutes, and averages early on", function()
    local env = boot()
    local HC, ns = env.HC, env.ns
    env:advance(60)
    ns.FoldRecent()                                       -- (the 15 s job does this in game)
    HC:Emit("hc:money.in", 1000, "none", 1429)
    ns.FoldRecent()
    -- one active minute in: the plain average
    local v, text, settled = recent(HC, "hc:gold")
    assert.is_near(1000 / weight(60) * 3600, v, 1e-6)
    assert.is_false(settled)
    assert.truthy(text:find("/h$"))
    env:advance(300)                                      -- no gain for 5 minutes: S halves
    v = recent(HC, "hc:gold")
    assert.is_near(500 / weight(360) * 3600, v, 1e-3)
    -- per hour, by contrast, is the plain average over 6 minutes
    assert.is_near(1000 / 360 * 3600, (HC:Reading("hc:gold", "session", { calc = "perHour" })), 1e-6)
  end)

  it("follows a change of pace that per hour barely shows", function()
    local env = boot()
    local HC = env.HC
    for _ = 1, 60 do env:advance(60); HC:Emit("hc:money.in", 100, "none", 1429) end      -- an hour at 6,000/h
    for _ = 1, 15 do env:advance(60); HC:Emit("hc:money.in", 300, "none", 1429) end      -- 15 minutes at 18,000/h
    local per = HC:Reading("hc:gold", "session", { calc = "perHour" })
    local rec, _, settled = recent(HC, "hc:gold")
    assert.is_near(8400, per, 1)                         -- (6000 + 4500) / 1.25 h
    assert.is_true(rec > 16000 and rec < 18600)           -- most of the way to the new pace
    assert.is_true(settled)
  end)

  it("is settled after 5 active minutes and 5 gains, not before", function()
    local env = boot()
    local HC = env.HC
    for _ = 1, 4 do env:advance(120); HC:Emit("hc:money.in", 50, "none", 1429) end
    assert.is_false(select(3, recent(HC, "hc:gold")))       -- 8 minutes, 4 gains
    env:advance(10); HC:Emit("hc:money.in", 50, "none", 1429)
    assert.is_true(select(3, recent(HC, "hc:gold")))
  end)

  it("stands still while AFK, and nets money out for Net gold", function()
    local env = boot()
    local HC = env.HC
    for _ = 1, 10 do env:advance(60); HC:Emit("hc:money.in", 100, "none", 1429) end
    HC:Emit("hc:money.out", 200, "repair", 1429)
    local before = recent(HC, "hc:gold")
    local net = recent(HC, "hc:net")
    assert.is_true(net < before)
    env.afk = true
    env:fire("PLAYER_FLAGS_CHANGED", "player")
    env:advance(1800)
    assert.is_near(before, recent(HC, "hc:gold"), 1e-6)
    assert.is_near(net, recent(HC, "hc:net"), 1e-6)
  end)

  it("is kept only where a window has its own clock, for this character, not per zone", function()
    local env = boot()
    local HC = env.HC
    HC:SetTrackerHistory("hc:goldph", "daily")
    assert.are.equal("calc", select(4, recent(HC, "hc:gold", "today")))
    assert.are.equal("calc", select(4, HC:Reading("hc:gold", "session", { calc = "recent", who = "account" })))
    assert.are.equal("norun", select(4, recent(HC, "hc:gold", "run")))
    assert.are.equal("calc", select(4, recent(HC, "hc:owned", "now")))           -- a stock: total only
    assert.are.same({ "total", "perHour", "recent", "trend" }, HC:GetReading("hc:gold").calcs)
    assert.are.equal("Gold/h recent", env.ns.ReadingTitle(env.ns.readings["hc:gold"], nil, "recent"))
    HC:StartRun("r")
    env:advance(120); HC:Emit("hc:money.in", 300, "none", 1429)
    assert.is_number((recent(HC, "hc:gold", "run")))
  end)

  it("is kept across /reload (it lives in the saved window), and starts over with a new session", function()
    local env = boot()
    local HC = env.HC
    for _ = 1, 10 do env:advance(60); HC:Emit("hc:money.in", 100, "none", 1429) end
    local v = recent(HC, "hc:gold")
    assert.is_table(env.ns.SV.windows.session.ew["hc:money.in"])
    local r = reload(env)
    assert.is_near(v, recent(r.HC, "hc:gold"), 1e-6)
  end)

  it("gives time to level at the recent pace", function()
    local env = boot()
    local HC = env.HC
    for _ = 1, 30 do env:advance(60); HC:Emit("hc:xp", 50, "none", 1429) end            -- 3,000/h
    for _ = 1, 10 do env:advance(60); HC:Emit("hc:xp", 200, "none", 1429) end           -- then 12,000/h
    local avg = HC:Reading("hc:ttl", "session")
    local now, text = HC:Reading("hc:ttl", "session", R)
    assert.is_true(now < avg)                                                            -- faster now: sooner
    assert.is_nil(text:find("/h", 1, true))                                              -- a duration, no "/h"
    assert.are.same({ "total", "recent" }, HC:GetReading("hc:ttl").calcs)
    assert.are.equal("Time to level (current pace)", env.ns.ReadingTitle(env.ns.readings["hc:ttl"], nil, "recent"))
  end)
end)

describe("recent on a board (HC-52)", function()
  it("reads the board's window, pauses with it, and starts over with Reset", function()
    local env = boot()
    local HC, M = env.HC, env.M
    local b = M.Create(nil, { name = "Farm" })
    local t = M.AddReading(b, "hc:gold", { calc = "recent", size = "large" })
    assert.are.equal("recent", t.calc)
    for _ = 1, 10 do env:advance(60); HC:Emit("hc:money.in", 100, "none", 1429) end
    local v, text = M.TileValue(t, b)
    assert.is_number(v)
    assert.are.equal("Gold/h recent", M.TileTitle(t))
    assert.truthy(text:find("/h$"))
    M.ControlAll(b, "pause")
    env:advance(600)
    HC:Emit("hc:money.in", 5000, "none", 1429)                                          -- while paused: not counted
    assert.is_near(v, (M.TileValue(t, b)), 1e-6)
    M.ControlAll(b, "reset")
    M.ControlAll(b, "start")
    assert.is_nil((M.TileValue(t, b)))                                                   -- under a minute again
  end)

  it("greys recent where it can't be, and falls back to per hour when the tile moves there", function()
    local env = boot()
    local M = env.M
    local b = M.Create(nil, { name = "B" })
    local t = M.AddReading(b, "hc:gold")
    local function why(c) for _, x in ipairs(M.CalcChoices(t)) do if x.calc == c then return x.ok, x.why end end end
    assert.is_true(why("recent"))
    assert.is_true(M.SetCalc(t, "recent"))
    M.SetScope(t, "today", b)
    assert.are.equal("perHour", t.calc)                                                  -- no recent over a calendar day
    assert.are.same({ false, "scope" }, { why("recent") })
    assert.is_false(M.SetCalc(t, "recent"))
    M.SetScope(t, "session", b)
    assert.is_true(M.SetCalc(t, "recent"))
    M.SetTarget(t, "1")
    M.SetDisplay(t, "bar")
    assert.are.equal("perHour", t.calc)                                                  -- a bar takes no recent
    assert.are.same({ false, "display" }, { why("recent") })
    M.SetDisplay(t, "gauge")
    assert.is_true(M.SetCalc(t, "recent"))                                               -- a gauge does
    M.SetWho(t, "account", b)
    assert.are.equal("perHour", t.calc)
    assert.are.same({ false, "account" }, { why("recent") })
  end)

  it("draws the hero's sparkline from the recent rate, one sample per active minute", function()
    local env = boot()
    local HC, M = env.HC, env.M
    local b = M.Create(nil, { name = "Farm" })
    local t = M.AddReading(b, "hc:gold", { size = "large" })
    t.extras = { sparkline = true }
    assert.is_nil(M.RecentSparkline(t, b, 10, {}))
    for _ = 1, 4 do env:advance(60); HC:Emit("hc:money.in", 100, "none", 1429) end
    local out = M.RecentSparkline(t, b, 10, {})
    assert.are.equal(10, #out)
    assert.are.equal(0, out[1])                                                          -- not sampled yet: 0 on the left
    assert.is_true(out[10] > 0)
  end)

  it("leaves past runs without a recent rate; their comparison uses per hour", function()
    local env = boot()
    local HC, ns = env.HC, env.ns
    HC:StartRun("r")
    env:advance(600); HC:Emit("hc:money.in", 1000, "none", 1429)
    local rec = HC:GetRunRecord(HC:StopRun())
    assert.is_nil((ns.Widgets.RecordReading(ns.readings["hc:gold"], rec, "recent")))
    assert.are.equal(6000, (ns.Widgets.RecordReading(ns.readings["hc:gold"], rec, "perHour")))
  end)
end)
