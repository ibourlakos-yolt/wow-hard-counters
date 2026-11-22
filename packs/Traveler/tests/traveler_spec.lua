-- Traveler on the real Hard Counters engine (../../HardCounters), through its public API only: the fake game moves
-- the player, the engine's own poll ticks, readings answer.
local Env = require("env")
Env.ROOT = "../../HardCounters"

local GAME = { "UnitPosition", "UnitOnTaxi", "UnitInVehicle", "UnitIsGhost", "IsFlying", "IsSwimming", "IsSubmerged",
  "IsMounted", "IsFalling", "GetUnitSpeed", "GetShapeshiftForm", "GetShapeshiftFormInfo", "C_Spell", "C_TaxiMap",
  "GetTaxiMapID", "C_UnitAuras", "C_Map", "C_DeathInfo" }

local SPELL_NAMES = { [8690] = "Hearthstone", [999001] = "Hearthstone", [783] = "Travel Form", [10291] = "Devotion Aura" }

local function boot()
  local env = Env.new()
  local game = { x = 0, y = 0, cont = 0, v = 0, combat = false, taxi = false, mounted = false, falling = false,
    form = 0, formSpell = nil }
  env.game = game
  local function sec(v) if game.combat then return env:secretValue() end return v end
  _G.UnitPosition = function() return game.y, game.x, 0, game.cont end
  _G.UnitOnTaxi = function() return game.taxi end
  _G.UnitInVehicle = function() return false end
  _G.UnitIsGhost = function() return false end
  _G.IsFlying = function() return false end
  _G.IsSwimming = function() return false end
  _G.IsSubmerged = function() return false end
  _G.IsMounted = function() return game.mounted end
  _G.IsFalling = function() return game.falling end
  _G.GetUnitSpeed = function() return sec(game.v), sec(7), sec(7), sec(4.72) end
  _G.GetShapeshiftForm = function() return game.form end
  _G.GetShapeshiftFormInfo = function() return 0, true, true, game.formSpell end
  _G.C_Spell = { GetSpellName = function(id) return SPELL_NAMES[id] end }
  _G.GetTaxiMapID = function() return 1414 end
  _G.C_TaxiMap = { GetAllTaxiNodes = function()
    return { { nodeID = 26, slotIndex = 1, state = 0, name = "Auberdine" },
      { nodeID = 28, slotIndex = 2, state = 1, name = "Astranaar" } }
  end }
  env.settings = nil
  env:load()
  local ns = env.ns
  ns.settings = ns.DefaultProfile()
  env.settings = ns.settings
  ns.settings.trackers = {
    ["hctravel:distance"] = { on = true, history = "detailed", seen = true },
    ["hctravel:flights"] = { on = true, history = "detailed", seen = true },
  }
  ns.AddSlash = function() end
  ns.AddOptions = function() end
  for _, f in ipairs({ "UI/Widgets.lua", "UI/BoardModel.lua" }) do
    assert(loadfile(Env.ROOT .. "/" .. f))("HardCounters", ns)
  end
  local pack = {}
  for _, f in ipairs({ "Motion.lua", "Traveler.lua" }) do
    assert(loadfile("HardCounters_Traveler/" .. f))("HardCounters_Traveler", pack)
  end
  env.pack = pack
  env:fire("ADDON_LOADED", "HardCounters")
  env.sv.HardCountersDB = _G.HardCountersDB
  env:fire("PLAYER_ENTERING_WORLD", true, false)
  env.M = ns.BoardModel
  return env
end

--- Move at `v` yd/s along x for `secs` seconds; the engine's poll reads the position as the clock runs.
local function move(env, v, secs)
  local g = env.game
  g.v = v
  local step = 0.05
  for _ = 1, math.floor(secs / step + 0.5) do
    g.x = g.x + v * step
    env:advance(step)
  end
  g.v = 0
end

local function read(env, id, scope, arg)
  return env.HC:Reading(id, scope or "session", arg and { arg = arg } or nil)
end

local function near(a, b, tol) return type(a) == "number" and math.abs(a - b) <= (tol or 1) end

describe("Traveler on Hard Counters", function()
  after_each(function() for _, n in ipairs(GAME) do _G[n] = nil end end)

  it("registers its pack, two trackers and its readings; the trackers start off for a fresh install", function()
    local env = boot()
    local HC = env.HC
    local t = HC:GetTracker("hctravel:distance")
    assert.is_truthy(t)
    assert.is_truthy(HC:GetTracker("hctravel:flights"))
    local r = HC:GetReading("hctravel:distance")
    assert.is_true(r.param.multi)
    assert.are.equal("Everything but teleports", r.param.default)
    for _, id in ipairs({ "time", "avgspeed", "avgspeedpct", "topspeed", "speednow", "longest", "jumps", "hops",
      "airtime", "longestair", "corpseruns", "healer", "corpse", "flights", "flightdist", "longestflight" }) do
      assert.is_truthy(HC:GetReading("hctravel:" .. id), id)
    end
    local fresh = env.ns.DefaultProfile()
    assert.is_falsy(fresh.trackers and fresh.trackers["hctravel:distance"] and fresh.trackers["hctravel:distance"].on)
  end)

  it("counts running and riding from the position poll, and the filters choose what a tile adds up", function()
    local env = boot()
    env:advance(1)
    move(env, 7, 20)
    env.game.mounted = true
    move(env, 14, 10)
    env.game.mounted = false
    env:advance(5)
    local all = read(env, "hctravel:distance")
    assert.is_true(near(all, 280, 3), tostring(all))
    assert.is_true(near(read(env, "hctravel:distance", nil, { "walk", "run" }), 140, 2))
    assert.is_true(near(read(env, "hctravel:distance", nil, { "mounted" }), 140, 2))
    assert.is_true(near(read(env, "hctravel:time"), 30, 1))
    local v, text = read(env, "hctravel:avgspeed")
    assert.is_true(near(v, 280 / 30, 0.5))
    assert.is_truthy(text:find("yd/s"))
    local _, pct = read(env, "hctravel:avgspeedpct", nil, { "walk", "run" })
    assert.are.equal("100%", pct)
    -- history: the longest leg (the ride, 140 yd) and the top speed (riding)
    assert.is_true(near(read(env, "hctravel:longest", "lifetime"), 140, 3))
    assert.is_true(near(read(env, "hctravel:topspeed", "lifetime"), 14, 0.5))
  end)

  it("keeps counting in a fight (speed secret, position plain), and Speed now works there", function()
    local env = boot()
    env:advance(1)
    env.game.combat = true
    env.game.v = 7
    for _ = 1, 20 do env.game.x = env.game.x + 0.35; env:advance(0.05) end
    assert.is_true(near(env.pack.motion:SpeedNow(env.t), 7, 0.5))
    local v, text = read(env, "hctravel:speednow", "now")
    assert.is_true(near(v, 7, 0.5))
    assert.are.equal("7.0 yd/s", text)
    move(env, 7, 9)
    assert.is_true(near(read(env, "hctravel:distance"), 70, 2))
  end)

  it("names a hearth across a loading screen by its spell (also by name, for a Forever ID), and leaves it out by default", function()
    local env = boot()
    env:advance(1)
    move(env, 7, 10)
    env:fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", 999001)    -- a Hearthstone with another ID
    env:advance(0.5)
    env:fire("LOADING_SCREEN_ENABLED")
    env:advance(8)
    env.game.x = env.game.x + 3000
    env:fire("LOADING_SCREEN_DISABLED")
    env:advance(2)
    assert.are.equal(1, (read(env, "hctravel:jumps", nil, { "hearth" })))
    assert.is_true(near(read(env, "hctravel:distance"), 70, 2))                  -- everything but teleports
    assert.is_true(near(read(env, "hctravel:distance", nil, env.pack.MODES), 3070, 3))
  end)

  it("counts spacebar jumps through the hook, and a fall off a ledge", function()
    local env = boot()
    env:advance(1)
    env:callHook("JumpOrAscendStart")
    env.game.falling = true
    env:advance(0.7)
    env.game.falling = false
    env:advance(1)
    assert.are.equal(1, (read(env, "hctravel:hops")))
    env.game.falling = true
    env:advance(1.5)
    env.game.falling = false
    env:advance(1)
    assert.are.equal(1, (read(env, "hctravel:hops")))
    assert.are.equal(1, (read(env, "hctravel:hops", nil, { "fall" })))
    assert.is_true(near(read(env, "hctravel:airtime"), 2.2, 0.6))
  end)

  it("records a flight with where from and to, named for the session", function()
    local env = boot()
    env:advance(1)
    env:fire("TAXIMAP_OPENED")
    env:callHook("TakeTaxiNode", 2)
    env.game.taxi = true
    move(env, 30, 60)
    env.game.taxi = false
    env:advance(2)
    assert.are.equal(1, (read(env, "hctravel:flights")))
    assert.is_true(near(read(env, "hctravel:flightdist"), 1800, 30))
    assert.is_true(near(read(env, "hctravel:time", nil, { "taxi" }), 60, 2))
    local rows = env.HC:Query({ counter = "hctravel:flight", grain = "lifetime", groupBy = "to" })
    assert.are.equal(28, rows[1].member)
    assert.are.equal("Astranaar", env.pack.NodeLabel(28))
    assert.are.equal("Flight point 99", env.pack.NodeLabel(99))
  end)

  it("tells a travel form from a paladin aura (auras are shapeshift forms on Forever)", function()
    local env = boot()
    env:advance(1)
    env.game.form, env.game.formSpell = 1, 10291
    move(env, 7, 4)
    env.game.form, env.game.formSpell = 1, 783
    move(env, 10, 4)
    env:advance(4)
    assert.is_true(near(read(env, "hctravel:distance", nil, { "run" }), 28, 2))
    assert.is_true(near(read(env, "hctravel:distance", nil, { "travelform" }), 40, 2))
  end)

  it("offers the Trip and Flight log boards, with the odometer and the mix where they fit", function()
    local env = boot()
    local M = env.M
    assert.is_truthy(M.PRESETS["hctravel:trip"])
    assert.is_truthy(M.PRESETS["hctravel:flightlog"])
    local b = M.Create("hctravel:trip")
    assert.are.equal("odometer", M.TileDisplay(b.tiles[1]))
    assert.are.equal("mix", M.TileDisplay(b.tiles[2]))
    assert.are.same({ "run", "walk" }, (function() local a = { unpack(b.tiles[3].arg) }; table.sort(a); return a end)())
  end)
end)
