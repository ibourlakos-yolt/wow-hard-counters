-- Basics (HC-21, TRACKERS_AND_BOARDS §4): gold and XP per hour inside Hard Counters, on the public API only, with
-- attributors for the sources. A fresh install: both trackers on, history off.
local Env = require("env")

local function boot()
  Env.BASICS = true
  local env = Env.new()
  local game = { money = 100000, xp = 100, xpMax = 1000, level = 20, rested = 300 }
  env.game = game
  _G.GetMoney = function() return game.money end
  _G.UnitXP = function() return game.xp end
  _G.UnitXPMax = function() return game.xpMax end
  _G.UnitLevel = function() return game.level end
  _G.GetXPExhaustion = function() return game.rested end
  env:load()
  env:fire("ADDON_LOADED", "HardCounters")
  env.sv.HardCountersDB = _G.HardCountersDB
  env:fire("PLAYER_ENTERING_WORLD", true, false)
  Env.BASICS = nil
  return env
end

local function money(env, d)
  env.game.money = env.game.money + d
  env:fire("PLAYER_MONEY")
end

local function login(env, id)
  return env.ns.Win.Total(env.ns.Session(), id)

end

describe("Basics", function()
  it("starts with Gold per hour and XP per hour on, history off, and counts money with no sources", function()
    local env = boot()
    local HC = env.HC
    assert.is_true(HC:IsTrackerOn("hc:goldph"))
    assert.is_true(HC:IsTrackerOn("hc:xpph"))
    assert.is_false(HC:GetTracker("hc:goldph").new)
    assert.are.equal("off", HC:CounterState("hc:money.in").history)
    money(env, 2500)
    money(env, -500)
    env:advance(3600)
    assert.are.equal(2500, login(env, "hc:money.in"))
    assert.are.equal(500, login(env, "hc:money.out"))
    assert.are.equal(2500, (HC:Reading("hc:goldph", "session")))
    assert.are.equal(2000, (HC:Reading("hc:netph", "session")))
    assert.are.equal(102000, (HC:Reading("hc:owned", "now")))
    assert.are.equal("needs history", select(4, HC:Reading("hc:goldph", "today")))
    assert.is_nil(env.ns.health.session.counterWithoutTracker)
  end)

  it("books what an attributor answers, now or later, and the rest as none after the timeout", function()
    local env = boot()
    local HC = env.HC
    local held
    HC:SetAttributor("hc:money.in", function(amount, _, book)
      if held then return end                         -- answers the first change only
      book(amount - 100, "loot")                      -- most of it now
      held = { book = book }                          -- 100 later
    end)
    HC:StartRun("Attr")
    money(env, 1000)
    local _, _, _, over = HC:_BasicsPending()
    assert.are.equal(0, over)
    held.book(60, "quest")
    held.book(999, "quest")                           -- more than it was given: only the 40 left count
    money(env, 300)                                   -- 300 more, never answered
    env:advance(6)
    local by = HC:GetRun({ breakdowns = true }).totals["hc:money.in"].by.source
    assert.are.same({ loot = 900, quest = 100, none = 300 }, by)
    assert.are.equal(1300, login(env, "hc:money.in"))
    local _, _, _, over2 = HC:_BasicsPending()
    assert.are.equal(959, over2)
    -- an attributor that errors loses nothing
    HC:SetAttributor("hc:money.in", function() error("bad") end)
    money(env, 7)
    assert.are.equal(1307, login(env, "hc:money.in"))
  end)

  it("counts XP across a level-up, time to level and rested XP", function()
    local env = boot()
    local HC = env.HC
    env.game.xp = 400
    env:fire("PLAYER_XP_UPDATE", "player")
    env.game.xp, env.game.level, env.game.xpMax = 100, 21, 1200
    env:fire("PLAYER_XP_UPDATE", "player")
    env:advance(3600)
    assert.are.equal(300 + 600 + 100, login(env, "hc:xp"))
    assert.are.equal(1000, (HC:Reading("hc:xpph", "session")))
    local ttl, text = HC:Reading("hc:ttl", "session")
    assert.are.equal(1100 / 1000 * 3600, ttl)
    assert.are.equal("1:06:00", text)
    assert.are.equal(300, (HC:Reading("hc:rested", "now")))
    env:fire("PLAYER_XP_UPDATE", "target")            -- not ours
    assert.are.equal(1000, login(env, "hc:xp"))
  end)

  it("stops listening when both trackers are off, and takes a fresh baseline when switched back on", function()
    local env = boot()
    local HC = env.HC
    HC:SetTrackerOn("hc:goldph", false)
    money(env, 5000)                                   -- not seen
    HC:SetTrackerOn("hc:goldph", true)
    money(env, 100)                                    -- measured from a fresh reading taken when switched on
    assert.are.equal(100, login(env, "hc:money.in"))   -- the 5,000 while off is a gap, not a gain
    HC:SetTrackerOn("hc:goldph", false)
    HC:SetTrackerOn("hc:xpph", false)
    assert.is_false(HC:CounterState("hc:time.active").active)
    local sources = {}
    for _, s in ipairs(env.ns.SourceStats()) do sources[s.id] = s.active end
    assert.is_false(sources["hc:money"])
    assert.is_false(sources["hc:xp"])
  end)
end)
