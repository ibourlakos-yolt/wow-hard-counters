-- Character Stats phase 1 on the real Hard Counters engine (../../HardCounters), through its public API only.
local Env = require("env")
Env.ROOT = "../../HardCounters"

local GAME = {
  "UnitStat", "UnitHealthMax", "UnitPowerMax", "UnitAttackPower", "UnitRangedAttackPower", "GetCritChance",
  "GetHitModifier", "GetRangedCritChance", "GetSpellBonusDamage", "GetSpellBonusHealing", "GetSpellCritChance",
  "GetSpellHitModifier", "GetManaRegen", "UnitArmor", "GetDodgeChance", "GetParryChance", "GetBlockChance",
  "GetShieldBlock", "UnitClass", "GetInventoryItemID", "GetInventorySlotInfo", "C_SkillInfo", "GetItemInfoInstant",
}

local function boot(class)
  local env = Env.new()
  -- items: 2504 a bow (subclass 2), 1 a one-handed sword (7), 2 a shield (armour, class 4)
  local ITEMS = { [2504] = { 2, 2 }, [1] = { 2, 7 }, [2] = { 4, 6 } }
  local game = { class = class or "WARRIOR", combat = false, ranged = 2504, main = 1, off = 2,
    skills = { [43] = { 280, 300, 5 }, [45] = { 150, 300, 0 }, [95] = { 295, 300, 10 }, [162] = { 1, 300, 0 } },
    stats = { 50, 40, 60, 30, 35 }, school = { [2] = 10, [3] = 120, [4] = 5, [5] = 90, [6] = 40, [7] = 0 } }
  env.game = game
  local function v(x) if game.combat then return env:secretValue() end return x end
  _G.UnitStat = function(_, i) return game.stats[i] - 5, v(game.stats[i]), 5, 0 end
  _G.UnitHealthMax = function() return 1500 end
  _G.UnitPowerMax = function() return 900 end
  _G.UnitAttackPower = function() return v(300), v(40), v(-10) end
  _G.UnitRangedAttackPower = function() return v(200), v(0), v(0) end
  _G.GetCritChance = function() return v(5.5) end
  _G.GetHitModifier = function() return v(2) end
  _G.GetRangedCritChance = function() return v(4.25) end
  _G.GetSpellBonusDamage = function(s) return v(game.school[s]) end
  _G.GetSpellBonusHealing = function() return v(80) end
  _G.GetSpellCritChance = function(s) return v(s == 3 and 7 or 3) end
  _G.GetSpellHitModifier = function() return v(1) end
  _G.GetManaRegen = function() return v(2.5), v(0.5) end
  _G.UnitArmor = function() return 1000, v(1450), 1450, 0, 0 end
  _G.GetDodgeChance = function() return v(6) end
  _G.GetParryChance = function() return v(5) end
  _G.GetBlockChance = function() return v(4) end
  _G.GetShieldBlock = function() return v(30) end
  _G.UnitClass = function() return "Class", game.class end
  _G.GetInventorySlotInfo = function() return 18 end
  _G.GetInventoryItemID = function(_, slot)
    if slot == 16 then return game.main elseif slot == 17 then return game.off end
    return game.ranged
  end
  _G.GetItemInfoInstant = function(id) local it = ITEMS[id]; if it then return id, nil, nil, nil, nil, it[1], it[2] end end
  _G.C_SkillInfo = { GetSkillLineInfoByID = function(id)
    local s = game.skills[id]
    if not s then return nil end
    return { name = "skill" .. id, skillID = id, rank = v(s[1]), maxRank = s[2], modifier = v(s[3]) }
  end }
  env:load()
  local ns = env.ns
  ns.AddSlash = function() end
  ns.AddOptions = function() end
  for _, f in ipairs({ "UI/Widgets.lua", "UI/BoardModel.lua" }) do
    assert(loadfile(Env.ROOT .. "/" .. f))("HardCounters", ns)
  end
  local pack = {}
  assert(loadfile("HardCounters_CharacterStats/Stats.lua"))("HardCounters_CharacterStats", pack)
  env.pack = pack
  env:fire("ADDON_LOADED", "HardCounters")
  env.sv.HardCountersDB = _G.HardCountersDB
  env:fire("PLAYER_ENTERING_WORLD", true, false)
  for _, t in ipairs(pack.TRACKERS) do env.HC:SetTrackerOn(t.id, true) end
  return env
end

local function read(env, stat) return env.HC:Reading("hcstats:" .. stat, "now") end

describe("Character Stats, phase 1 (live readings)", function()
  after_each(function() for _, n in ipairs(GAME) do _G[n] = nil end end)

  it("registers its pack, five trackers of live readings (off) and every stat as a now reading", function()
    local env = boot()
    local HC = env.HC
    local stats = 0
    for _, t in ipairs(HC:Trackers()) do
      if t.id:find("^hcstats:") then
        stats = stats + 1
        assert.are.same({}, t.counters)
      end
    end
    assert.are.equal(5, stats)
    assert.are.equal(#env.pack.STATS, #HC:Readings({ tracker = nil, scope = "now" }) - #HC:Readings({ scope = "now", tracker = "hc:xpph" })
      - #HC:Readings({ scope = "now", tracker = "hc:goldph" }))
    HC:SetTrackerOn("hcstats:melee", false)
    local _, text = read(env, "ap")
    assert.are.equal("off", text)
  end)

  it("reads the game: totals, the best school, mana per 5, percents", function()
    local env = boot("PALADIN")
    assert.are.equal(50, (read(env, "str")))
    assert.are.equal(330, (read(env, "ap")))                -- 300 + 40 - 10
    assert.are.equal(120, (read(env, "spelldmg")))          -- fire, the best school
    assert.are.equal(7, (read(env, "spellcrit")))
    assert.are.equal(12.5, (read(env, "mp5")))              -- 2.5 a second
    assert.are.equal(2.5, (read(env, "mp5cast")))
    assert.are.equal(1450, (read(env, "armor")))
    local _, text = read(env, "crit")
    assert.are.equal("5.5%", text)
  end)

  it("in combat: the last value read, marked stale with 'in combat'; nothing read yet has no value", function()
    local env = boot()
    assert.are.equal(330, (read(env, "ap")))
    env.game.combat = true
    local v, text, _, state, note = read(env, "ap")
    assert.are.equal(330, v)
    assert.are.equal("330", text)
    assert.are.equal("stale", state)
    assert.are.equal("in combat", note)
    local dv, _, _, dstate = read(env, "dodge")                 -- never read before the fight
    assert.is_nil(dv)
    assert.is_nil(dstate)
    env.game.combat = false
    env.game.stats[1] = 55
    local sv, _, _, sstate = read(env, "str")
    assert.are.equal(55, sv)
    assert.is_nil(sstate)
  end)

  it("in combat, single-value stats hand the game's secret to displays (CS-9); sums and bests don't", function()
    local env = boot("HUNTER")
    local HC = env.HC
    read(env, "dodge")
    env.game.combat = true
    local _, _, _, state = read(env, "dodge")
    assert.are.equal("stale", state)
    local lv, fmt = HC:ReadingLive("hcstats:dodge")
    assert.is_true(HC:IsSecret(lv))
    assert.are.equal("%.1f%%", fmt)
    lv, fmt = HC:ReadingLive("hcstats:str")
    assert.is_true(HC:IsSecret(lv))
    assert.are.equal("%.0f", fmt)
    assert.is_nil(HC:ReadingLive("hcstats:ap"))               -- a sum of three secrets: no pass-through
    assert.is_nil(HC:ReadingLive("hcstats:spelldmg"))         -- the best of six schools: none either
  end)

  it("weapon skill by the weapon in each slot, and Defense, from C_SkillInfo; their caps are the targets", function()
    local env = boot("WARRIOR")
    local HC = env.HC
    assert.are.equal(285, (read(env, "mainskill")))            -- swords: 280 + 5
    assert.are.equal(300, HC:ReadingTarget("hcstats:mainskill"))
    assert.is_false(HC:ReadingApplies("hcstats:offskill"))      -- a shield in the off hand: no weapon skill
    assert.are.equal(150, (read(env, "rangedskill")))           -- bows
    assert.are.equal(305, (read(env, "defense")))
    assert.are.equal(300, HC:ReadingTarget("hcstats:defense"))
    env.game.main = nil                                        -- bare hands
    assert.are.equal(1, (read(env, "mainskill")))
    env.game.off = 1                                           -- a second sword
    assert.is_true(HC:ReadingApplies("hcstats:offskill"))
    assert.are.equal(285, (read(env, "offskill")))
    env.game.ranged = nil
    assert.is_false(HC:ReadingApplies("hcstats:rangedskill"))
    -- in combat: the last value read, marked (no pass-through: rank plus bonus is a sum)
    env.game.combat = true
    local v, _, _, state = read(env, "defense")
    assert.are.equal(305, v)
    assert.are.equal("stale", state)
    assert.is_nil(HC:ReadingLive("hcstats:defense"))
  end)

  it("class rules: parry, block, spell, mana and ranged rows only where they apply", function()
    local env = boot("MAGE")
    local HC = env.HC
    assert.is_false(HC:ReadingApplies("hcstats:parry"))
    assert.is_false(HC:ReadingApplies("hcstats:block"))
    assert.is_false(HC:ReadingApplies("hcstats:rap"))
    assert.is_true(HC:ReadingApplies("hcstats:spelldmg"))
    assert.is_true(HC:ReadingApplies("hcstats:mp5"))
    assert.are.equal("n/a", select(2, read(env, "parry")))
    env.game.class = "WARRIOR"
    assert.is_true(HC:ReadingApplies("hcstats:parry"))
    assert.is_true(HC:ReadingApplies("hcstats:block"))
    assert.is_false(HC:ReadingApplies("hcstats:spelldmg"))
    assert.is_false(HC:ReadingApplies("hcstats:int"))
    assert.is_true(HC:ReadingApplies("hcstats:rap"))
    env.game.ranged = nil                                     -- no ranged weapon equipped
    assert.is_false(HC:ReadingApplies("hcstats:rap"))
  end)

  it("offers four board presets made of its readings", function()
    local env = boot()
    local M = env.ns.BoardModel
    for key, hero in pairs({ ["hcstats:caster"] = "hcstats:spelldmg", ["hcstats:melee"] = "hcstats:ap",
        ["hcstats:hunter"] = "hcstats:rap", ["hcstats:tank"] = "hcstats:armor" }) do
      local b = M.Create(key)
      assert.are.equal(hero, b.tiles[1].reading)
      assert.are.equal("now", b.tiles[1].scope)
      assert.are.equal("large", b.tiles[1].size)              -- (CS-11, DESIGN §16.9) a big number
      assert.are.equal("number", b.tiles[1].display)
      assert.is_nil(b.tiles[1].style)
      assert.are.same({ "total" }, env.HC:GetReading(hero).calcs)   -- a stat is a stock: total only
      local last = b.tiles[#b.tiles]
      assert.are.equal("half", b.tiles[2].size)
      if key ~= "hcstats:caster" then assert.are.same({ "bar", "line" }, { last.display, last.size }) end
      assert.is_false(M.UsesTimer(b) and true or false)       -- now tiles: no timer on these boards
    end
  end)
end)
