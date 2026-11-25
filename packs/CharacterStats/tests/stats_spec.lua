-- Character Stats phase 1 on the real Hard Counters engine (../../HardCounters), through its public API only.
local Env = require("env")
Env.ROOT = "../../HardCounters"

local GAME = {
  "UnitStat", "UnitHealthMax", "UnitPowerMax", "UnitAttackPower", "UnitRangedAttackPower", "GetCritChance",
  "GetHitModifier", "GetRangedCritChance", "GetSpellBonusDamage", "GetSpellBonusHealing", "GetSpellCritChance",
  "GetSpellHitModifier", "GetManaRegen", "UnitArmor", "GetDodgeChance", "GetParryChance", "GetBlockChance",
  "GetShieldBlock", "UnitClass", "GetInventoryItemID", "GetInventorySlotInfo", "C_SkillInfo", "GetItemInfoInstant",
  "UnitDamage", "UnitAttackSpeed", "UnitRangedDamage", "GetSpellPenetration", "UnitResistance", "GetInventoryItemDurability",
  "GetAverageItemLevel", "GetHealthRegen", "GetManaRegenFromSpirit", "GetMeleeHaste", "UnitSpellHaste", "C_Spell", "C_UnitAuras",
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
  _G.UnitDamage = function() return v(40), v(60), v(20), v(30) end
  _G.UnitAttackSpeed = function() return v(2.5), game.off2 and v(1.25) or nil end
  _G.UnitRangedDamage = function() return v(3), v(30), v(54) end
  _G.GetSpellPenetration = function() return v(10) end
  _G.UnitResistance = function(_, school) return 0, v(school * 10), 0, 0 end
  _G.GetInventoryItemDurability = function(slot)
    if slot == 16 then return 30, 100 elseif slot == 5 then return 60, 80 end
  end
  _G.GetAverageItemLevel = function() return 40.5, 38.25 end
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
    assert.are.equal(7, stats)                                -- (2026-11-24: Resistances and Gear)
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

  it("offers role and class boards made of its readings (2026-11-24, Hard Counters HC-57)", function()
    local env = boot("MAGE")
    local M = env.ns.BoardModel
    local roles, classes = 0, 0
    for key, p in pairs(M.PRESETS) do
      if key:find("^hcstats:") then
        if p.category == "role" then roles = roles + 1 elseif p.category == "class" then classes = classes + 1 end
        local b = M.Create(key)
        assert.are.equal(#p.tiles, #b.tiles)                   -- every reading it names exists
        assert.are.equal("now", b.tiles[1].scope)
        if not key:find("^hcstats:schools%.") then
          assert.are.equal("large", b.tiles[1].size)            -- (CS-11, DESIGN §16.9) a big number first
        end
        assert.are.equal("number", b.tiles[1].display)
        assert.is_false(M.UsesTimer(b) and true or false)       -- now tiles: no timer on these boards
      end
    end
    assert.are.equal(7, roles)
    assert.are.equal(9 + 8, classes)                            -- a class board each, and a schools board for eight
    -- the old keys kept: a board remembers the preset it came from
    assert.are.equal("Tank (physical)", M.PRESETS["hcstats:tank"].name)
    assert.are.equal("Caster DPS", M.PRESETS["hcstats:caster"].name)
    assert.are.equal("HUNTER", M.PRESETS["hcstats:hunter"].class)
    -- your class first
    local by = {}
    for _, g in ipairs(M.PresetGroups()) do by[g.title] = g end
    assert.are.same({ "hcstats:mage", "hcstats:schools.mage" }, by["Your class"].keys)   -- the class board first
    assert.are.equal(8 + 7, #by["Other classes"].keys)
    -- (2026-11-25) the schools board: a damage and a crit tile per school of the class, in its order
    local sm = M.PRESETS["hcstats:schools.mage"]
    assert.are.equal("Mage: schools", sm.name)
    local got = {}
    for _, tl in ipairs(sm.tiles) do got[#got + 1] = tl.reading:gsub("hcstats:", "") .. (tl.arg and (":" .. tl.arg) or "") end
    assert.are.same({ "spelldmg:3", "spellcrit:3", "spelldmg:5", "spellcrit:5", "spelldmg:7", "spellcrit:7", "spellhit",
      "spellpen" }, got)
    assert.are.equal(8, #M.PRESETS["hcstats:schools.hunter"].tiles)     -- arcane, nature, fire, frost; no spell hit
    assert.are.equal(2, #M.PRESETS["hcstats:schools.rogue"].tiles)      -- nature (poisons)
    assert.is_nil(M.PRESETS["hcstats:schools.warrior"])
    assert.are.equal("Spell damage: Fire", M.TileTitle(M.Create("hcstats:schools.mage").tiles[1]))
    -- a spell tank's resistances, one school each
    local st = M.Create("hcstats:spelltank")
    assert.are.equal("hcstats:resist", st.tiles[2].reading)
    assert.are.equal(2, st.tiles[2].arg)
    assert.are.same({ "total" }, env.HC:GetReading("hcstats:armor").calcs)   -- a stat is a stock: total only
    -- (2026-11-25) casters see their schools side by side, and every board of a class that casts has the
    -- five-second rule as a bar
    local function has(key, reading, arg, display)
      for _, t in ipairs(M.PRESETS[key].tiles) do
        if t.reading == "hcstats:" .. reading and t.arg == arg and (display == nil or t.display == display) then return true end
      end
      return false
    end
    for _, k in ipairs({ 6, 3 }) do                             -- shadow and fire
      assert.is_true(has("hcstats:warlock", "spelldmg", k))
      assert.is_true(has("hcstats:warlock", "spellcrit", k))
    end
    for _, k in ipairs({ 3, 5, 7 }) do                          -- fire, frost, arcane
      assert.is_true(has("hcstats:mage", "spelldmg", k))
      assert.is_true(has("hcstats:mage", "spellcrit", k))
    end
    for _, key in ipairs({ "mage", "warlock", "priest", "druid", "shaman", "paladin", "caster", "healdirect", "healhot" }) do
      assert.is_true(has("hcstats:" .. key, "fsr", nil, "bar"), key)
    end
    for _, key in ipairs({ "warrior", "rogue", "hunter", "melee", "tank" }) do
      assert.is_false(has("hcstats:" .. key, "fsr", nil), key)
    end
    for _, key in ipairs({ "priest", "druid", "shaman", "paladin", "healdirect" }) do
      assert.is_true(has("hcstats:" .. key, "healcrit", nil), key)
    end
  end)

  it("reads regeneration per 5 seconds and per second, from spirit, haste and healing crit (2026-11-25)", function()
    _G.GetHealthRegen = function() return 3.2, 0.4 end
    _G.GetManaRegenFromSpirit = function() return 2, 0 end
    _G.GetMeleeHaste = function() return 4 end
    _G.UnitSpellHaste = function() return 6 end
    local env = boot("PRIEST")
    assert.are.equal(16, (read(env, "hp5")))                  -- 3.2 a second out of combat
    assert.are.equal(2, (read(env, "hp5combat")))
    assert.are.equal(3.2, (read(env, "hps")))
    assert.are.equal(2.5, (read(env, "mps")))                 -- GetManaRegen: not casting, casting
    assert.are.equal(0.5, (read(env, "mpscast")))
    assert.are.equal(10, (read(env, "mp5spirit")))
    assert.are.equal(4, (read(env, "haste")))
    assert.are.equal(6, (read(env, "spellhaste")))
    assert.are.equal(3, (read(env, "healcrit")))              -- holy for a priest
    local _, text = read(env, "hp5")
    assert.are.equal("16.0", text)
    -- board-only readings take no row in the window
    local rows = {}
    for _, r in ipairs(env.pack.ROWS) do rows[r.id] = true end
    assert.is_true(rows["hcstats:hp5"] and rows["hcstats:hp5combat"] and rows["hcstats:mp5spirit"])
    for _, k in ipairs({ "hps", "mps", "mpscast", "fsr", "haste", "spellhaste", "healcrit" }) do
      assert.is_nil(rows["hcstats:" .. k], k)
    end
    -- a warrior heals nothing and has no mana
    env = boot("WARRIOR")
    assert.are.equal("inapplicable", (select(4, read(env, "healcrit"))))
    assert.are.equal("inapplicable", (select(4, read(env, "fsr"))))
    -- a client without the call: no value, no error
    _G.GetHealthRegen = nil
    env = boot("PRIEST")
    assert.are.equal("inapplicable", (select(4, read(env, "hp5"))))
  end)

  it("adds flat mana-per-5 buffs to mana regen: Blessing of Wisdom, Mana Spring (the user, 2026-11-25)", function()
    local auras = {}
    _G.C_UnitAuras = { GetAuraDataByIndex = function(_, i) return auras[i] end }
    local env = boot("PRIEST")
    assert.are.equal(12.5, (read(env, "mp5")))                  -- no buff: 2.5 a second
    auras = { { spellId = 1459 }, { spellId = 19854, points = { 30 } } }     -- an unrelated buff, Blessing of Wisdom
    assert.are.equal(42.5, (read(env, "mp5")))
    assert.are.equal(32.5, (read(env, "mp5cast")))              -- while casting too
    assert.are.equal(8.5, (read(env, "mps")))
    assert.are.equal(6.5, (read(env, "mpscast")))
    assert.are.equal(10, (read(env, "mp5spirit")) or 10)        -- spirit's part is not touched (no call here: n/a)
    -- the aura's own amount wins over the rank's figure; Mana Spring's is per 2 seconds
    auras = { { spellId = 19854, points = { 36 } }, { spellId = 10494, points = { 10 } } }
    assert.are.equal(12.5 + 36 + 25, (read(env, "mp5")))
    -- no amount given: the rank's figure
    auras = { { spellId = 19742 } }
    assert.are.equal(22.5, (read(env, "mp5")))
    -- auras hidden in combat: the last value, marked
    auras = { { spellId = env:secretValue() } }
    local v, _, _, state = read(env, "mp5")
    assert.are.equal(22.5, v)
    assert.are.equal("stale", state)
  end)

  it("offers the school readings to every class with magic-school abilities, hunters and rogues too (2026-11-25)", function()
    for _, class in ipairs({ "HUNTER", "ROGUE", "MAGE", "PALADIN" }) do
      local env = boot(class)
      assert.are.equal(120, (env.HC:Reading("hcstats:spelldmg", "now", { arg = 3 })), class)
      assert.is_nil((select(4, env.HC:Reading("hcstats:spellcrit", "now", { arg = 4 }))), class)
    end
    local env = boot("WARRIOR")
    assert.are.equal("inapplicable", (select(4, read(env, "spelldmg"))))
    assert.are.equal("inapplicable", (select(4, read(env, "spellcrit"))))
    assert.are.equal("inapplicable", (select(4, read(boot("ROGUE"), "spellhit"))))   -- spell hit stays the casters'
  end)

  it("counts the five-second rule from a spell that cost mana, up to 5 (2026-11-25)", function()
    local env = boot("MAGE")
    local HC = env.HC
    local realTime = _G.GetTime
    _G.GetTime = function() return env.t end
    _G.C_Spell = { GetSpellPowerCost = function(id)
      if id == 1 then return { { type = 0, cost = 100 } } end            -- mana
      if id == 2 then return { { type = 0, cost = 0 } } end              -- free now (a clearcast)
      if id == 3 then return { { type = 3, cost = 40 } } end             -- energy
      return nil
    end }
    assert.are.equal(5, (read(env, "fsr")))                    -- nothing cast yet: regeneration is running
    assert.are.equal(5, HC:ReadingTarget("hcstats:fsr"))      -- its target: a bar fills toward 5
    env:fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-1", 1)
    assert.are.equal(0, (read(env, "fsr")))
    assert.is_true(env.ns.dirty)                               -- boards are told to redraw
    env:advance(2)
    assert.are.equal(2, (read(env, "fsr")))
    local _, text, _, state = read(env, "fsr")
    assert.are.equal("2.00 s", text)
    assert.is_nil(state)                                       -- a clock of our own: never "in combat"
    -- a free spell, an energy cost and someone else's cast don't restart it
    env:fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-2", 2)
    env:fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-3", 3)
    env:fire("UNIT_SPELLCAST_SUCCEEDED", "target", "cast-4", 1)
    assert.are.equal(2, (read(env, "fsr")))
    env:advance(4)
    assert.are.equal(5, (read(env, "fsr")))                    -- full: spirit regeneration is back
    -- a spell whose cost the client can't tell starts it (said in the description)
    env:fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-5", 99)
    assert.are.equal(0, (read(env, "fsr")))
    env:advance(6)
    -- in combat too: nothing secret is read
    env.game.combat = true
    env:fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-6", 1)
    env:advance(1)
    assert.are.equal(1, (read(env, "fsr")))
    env.game.combat = false
    -- with the Spell tracker off nothing is timed
    env:advance(10)
    HC:SetTrackerOn("hcstats:spell", false)
    env:fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-7", 1)
    HC:SetTrackerOn("hcstats:spell", true)
    assert.are.equal(5, (read(env, "fsr")))
    _G.GetTime = realTime
    assert.are.same({}, env.errors)
  end)

  it("reads weapon damage and speed, schools, penetration, resistances and gear (2026-11-24)", function()
    local env = boot("WARRIOR")
    local HC, ns = env.HC, env.ns
    assert.are.equal(20, (read(env, "mhdps")))                 -- (40 + 60) / 2 / 2.5
    assert.are.equal(2.5, (read(env, "mhspeed")))
    assert.are.equal(14, (read(env, "rdps")))                  -- (30 + 54) / 2 / 3
    assert.are.equal("20.0", select(2, read(env, "mhdps")))
    assert.are.equal("2.50 s", select(2, read(env, "mhspeed")))
    assert.are.equal(30, (HC:Reading("hcstats:resist", "now", 3)))
    assert.are.equal("noarg", select(4, HC:Reading("hcstats:resist", "now")))
    assert.are.equal("Resistance: Nature", ns.ReadingTitle(ns.readings["hcstats:resist"], 3))
    assert.are.equal("Resistance: pick a school", ns.ReadingTitle(ns.readings["hcstats:resist"], nil))
    assert.are.equal(30, (read(env, "durability")))            -- the main hand at 30 of 100
    assert.are.equal(38.25, (read(env, "ilvl")))
    -- the off hand applies only with a weapon there (the shield is armour)
    assert.are.equal("inapplicable", select(4, read(env, "ohdps")))
    -- a school picked, or the best one
    local mage = boot("MAGE")
    assert.are.equal(120, (mage.HC:Reading("hcstats:spelldmg", "now")))
    assert.are.equal(90, (mage.HC:Reading("hcstats:spelldmg", "now", 5)))
    assert.are.equal("Spell damage (best school)", mage.ns.ReadingTitle(mage.ns.readings["hcstats:spelldmg"], nil))
    assert.are.equal("Spell damage: Frost", mage.ns.ReadingTitle(mage.ns.readings["hcstats:spelldmg"], 5))
    assert.are.equal(10, (mage.HC:Reading("hcstats:spellpen", "now")))
    -- in combat: the last value per school, and the game's own value handed through for one school
    mage.game.combat = true
    local v, _, _, state = mage.HC:Reading("hcstats:spelldmg", "now", 5)
    assert.are.equal(90, v)
    assert.are.equal("stale", state)
    assert.is_not_nil(mage.HC:ReadingLive("hcstats:spelldmg", 5))
    -- the window lists the five resistances and no row for "Weapon skill: pick a skill"
    local resist, skill = 0, 0
    for _, row in ipairs(env.pack.ROWS) do
      if row.id == "hcstats:resist" then resist = resist + 1 end
      if row.id == "hcstats:skill" then skill = skill + 1 end
    end
    assert.are.equal(5, resist)
    assert.are.equal(0, skill)
  end)

  it("reads any weapon skill picked on the tile, and a fist weapon as Unarmed when there is no Fist line (CS-12, CS-13)", function()
    local env = boot("WARRIOR")
    local HC = env.HC
    assert.are.equal(150, (HC:Reading("hcstats:skill", "now", 45)))   -- Bows, while a sword is held
    assert.are.equal(300, HC:ReadingTarget("hcstats:skill", 45))
    -- a fist weapon (subclass 13) in the main hand: no line 473 here, so Unarmed (162)
    env.game.main = 13
    _G.GetItemInfoInstant = function(id)
      if id == 13 then return id, nil, nil, nil, nil, 2, 13 end
      if id == 2504 then return id, nil, nil, nil, nil, 2, 2 end
    end
    assert.are.equal(1, (read(env, "mainskill")))                     -- Unarmed's rank
  end)
end)
