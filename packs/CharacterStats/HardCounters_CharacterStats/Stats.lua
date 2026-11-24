-- Character Stats, phase 1 (DESIGN §8, decided 2026-11-19): the character sheet as live `now` readings with no
-- counters. Each reading asks the game when a board or the window draws it; nothing is stored, nothing polls.
-- Stats are secret in combat on Forever (CS-1): a reading then shows the last value it read out of combat, greyed,
-- with "in combat" after its title (Hard Counters' `stale` state, HC-28), never a secret. Rows that don't apply to
-- this character (parry for a mage) say so (`applies`, HC-28). No derived "≈" rows before CS-7.
-- Built ONLY on Hard Counters' public API (docs/API.md at the repo root).
local ADDON, ns = ...

local HC = HardCounters
if not HC or (HC.API_VERSION or 0) < 1 or not (HC.Supports and HC:Supports("liveTrackers")
    and HC:Supports("readingStates")) then return end

local type, select, ipairs = type, select, ipairs

ns.VERSION = "0.2.2-beta2"
ns.pack = HC:RegisterPack("CharacterStats", { namespace = "hcstats", version = ns.VERSION, title = "Character Stats" })

---------------------------------------------------------------------------
-- Reading the game. A reader returns a number, nil (no value: the call is missing or returned nothing) or SECRET.
---------------------------------------------------------------------------

local SECRET = {}
ns.SECRET = SECRET

local function anySecret(...)
  for i = 1, select("#", ...) do
    if HC:IsSecret((select(i, ...))) then return true end
  end
  return false
end

local function num(v)
  if type(v) ~= "number" or v ~= v then return nil end
  return v
end

--- The first return of fn(...), or SECRET, or nil.
local function first(fn, ...)
  if type(fn) ~= "function" then return nil end
  local v = fn(...)
  if anySecret(v) then return SECRET end
  return num(v)
end

--- base + positive + negative (UnitAttackPower, UnitRangedAttackPower).
local function apTotal(fn)
  if type(fn) ~= "function" then return nil end
  local base, pos, neg = fn("player")
  if anySecret(base, pos, neg) then return SECRET end
  if not num(base) then return nil end
  return base + (num(pos) or 0) + (num(neg) or 0)
end

--- The effective value of an attribute (UnitStat returns base, effective, plus, minus).
local function attribute(index)
  return function()
    if type(UnitStat) ~= "function" then return nil end
    local _, eff = UnitStat("player", index)
    if anySecret(eff) then return SECRET end
    return num(eff)
  end
end

local SCHOOLS = { 2, 3, 4, 5, 6, 7 }      -- holy, fire, nature, frost, shadow, arcane
--- The best school's value of fn(school): spell damage and spell crit as the character pane's best line.
local function bestSchool(fnName)
  return function()
    local fn = _G[fnName]
    if type(fn) ~= "function" then return nil end
    local best
    for i = 1, #SCHOOLS do
      local v = fn(SCHOOLS[i])
      if anySecret(v) then return SECRET end
      v = num(v)
      if v and (not best or v > best) then best = v end
    end
    return best
  end
end

--- Mana regenerated per 5 seconds: GetManaRegen returns per second, (not casting, casting).
local function manaRegen(casting)
  return function()
    if type(GetManaRegen) ~= "function" then return nil end
    local base, whileCasting = GetManaRegen()
    if anySecret(base, whileCasting) then return SECRET end
    local v = num(casting and whileCasting or base)
    return v and v * 5 or nil
  end
end

---------------------------------------------------------------------------
-- Who uses what (DESIGN §3.10): class rules. UnitClass's second return is the English token.
---------------------------------------------------------------------------

local function classIs(set)
  return function()
    if type(UnitClass) ~= "function" then return true end
    local _, token = UnitClass("player")
    if type(token) ~= "string" or HC:IsSecret(token) then return true end
    return set[token] == true
  end
end

local function set(...)
  local s = {}
  for i = 1, select("#", ...) do s[select(i, ...)] = true end
  return s
end

local MANA = set("MAGE", "PRIEST", "WARLOCK", "DRUID", "SHAMAN", "PALADIN", "HUNTER")
local CASTER = set("MAGE", "PRIEST", "WARLOCK", "DRUID", "SHAMAN", "PALADIN")
local HEALER = set("PRIEST", "DRUID", "SHAMAN", "PALADIN")
local PARRY = set("WARRIOR", "PALADIN", "ROGUE", "HUNTER")
local BLOCK = set("WARRIOR", "PALADIN", "SHAMAN")
local RANGED = set("HUNTER", "WARRIOR", "ROGUE")

local rangedSlot
--- Ranged rows: a class that uses a ranged weapon and has one equipped.
local function usesRanged()
  if not classIs(RANGED)() then return false end
  if type(GetInventoryItemID) ~= "function" then return true end
  if not rangedSlot and type(GetInventorySlotInfo) == "function" then
    local ok, slot = pcall(GetInventorySlotInfo, "RangedSlot")
    rangedSlot = ok and type(slot) == "number" and slot or 18
  end
  local id = GetInventoryItemID("player", rangedSlot or 18)
  if HC:IsSecret(id) then return true end
  return id ~= nil
end

local function hasCall(name) return function() return type(_G[name]) == "function" end end

---------------------------------------------------------------------------
-- Weapon skill and Defense (CS-8, answered in game 2026-11-19: C_SkillInfo lists every skill line as a table with
-- name, rank, maxRank, modifier, skillID). The equipped weapon's subclass names its skill line; the value is rank
-- plus the gear and talent modifier, and the line's maxRank is the reading's natural target (a bar shows skill-ups).
---------------------------------------------------------------------------

-- weapon subclass (Enum.ItemWeaponSubclass) -> skill line id (classic ids)
local SKILL_OF_SUBCLASS = { [0] = 44, [1] = 172, [2] = 45, [3] = 46, [4] = 54, [5] = 160, [6] = 229, [7] = 43,
  [8] = 55, [10] = 136, [13] = 473, [15] = 173, [16] = 176, [18] = 226, [19] = 228 }
local UNARMED, DEFENSE = 162, 95
local SLOT_MAIN, SLOT_OFF, SLOT_RANGED = 16, 17, 18
local WEAPON_CLASS = 2

local function itemClass(itemID)
  local f = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
  if type(f) ~= "function" then return nil end
  local _, _, _, _, _, classID, subclassID = f(itemID)
  return classID, subclassID
end

--- The skill line id of the weapon in a slot: nil when the slot holds no weapon (an off-hand shield, nothing in the
--- ranged slot); bare hands for an empty main hand.
local function weaponSkillID(slot)
  if type(GetInventoryItemID) ~= "function" then return nil end
  local id = GetInventoryItemID("player", slot)
  if id == nil then return slot == SLOT_MAIN and UNARMED or nil end
  if HC:IsSecret(id) then return nil end
  local classID, sub = itemClass(id)
  if classID ~= WEAPON_CLASS or HC:IsSecret(sub) then return nil end
  return SKILL_OF_SUBCLASS[sub]
end

--- The C_SkillInfo entry for a skill line id (by id where the client offers it, else by walking the visible lines;
--- a line under a header the player collapsed isn't listed). nil when the character doesn't have it.
local function skillLine(skillID)
  local S = C_SkillInfo
  if type(S) ~= "table" or not skillID then return nil end
  if type(S.GetSkillLineInfoByID) == "function" then
    local ok, d = pcall(S.GetSkillLineInfoByID, skillID)
    if ok and type(d) == "table" and d.name ~= nil then return d end
  end
  if type(S.GetNumSkillLines) ~= "function" or type(S.GetSkillLineInfo) ~= "function" then return nil end
  local n = S.GetNumSkillLines()
  if HC:IsSecret(n) or type(n) ~= "number" then return nil end
  for i = 1, n do
    local d = S.GetSkillLineInfo(i)
    if type(d) == "table" and not HC:IsSecret(d.skillID) and d.skillID == skillID then return d end
  end
  return nil
end

--- Rank plus modifier of a skill line, SECRET, or nil.
local function skillValue(skillID)
  local d = skillLine(skillID)
  if not d then return nil end
  if anySecret(d.rank, d.modifier) then return SECRET end
  local rank = num(d.rank)
  if not rank then return nil end
  return rank + (num(d.modifier) or 0)
end

--- The cap of a skill line (its maxRank), the reading's natural target; nil when unknown.
local function skillCap(skillID)
  local d = skillLine(skillID)
  if not d or HC:IsSecret(d.maxRank) then return nil end
  local m = num(d.maxRank)
  return m and m > 0 and m or nil
end

local function slotSkill(slot) return function() return skillValue(weaponSkillID(slot)) end end
local function slotCap(slot) return function() return skillCap(weaponSkillID(slot)) end end
local function holdsWeapon(slot) return function() return weaponSkillID(slot) ~= nil end end

-- natural targets, by stat (see TARGET in the registration below)
local TARGET = {
  mainskill = slotCap(SLOT_MAIN), offskill = slotCap(SLOT_OFF), rangedskill = slotCap(SLOT_RANGED),
  defense = function() return skillCap(DEFENSE) end,
}

---------------------------------------------------------------------------
-- Trackers: one per catalog section. Live readings only (counters = {}): switching one on costs nothing but the
-- calls its tiles make while drawn. Off by default, like every pack's (TRACKERS_AND_BOARDS §0.3).
---------------------------------------------------------------------------

ns.TRACKERS = {
  { id = "hcstats:attributes", title = "Attributes",
    description = "Strength, agility, stamina, intellect, spirit, health and mana, as the game reports them now." },
  { id = "hcstats:melee", title = "Melee", description = "Attack power, crit and hit chance, weapon skill." },
  { id = "hcstats:ranged", title = "Ranged", description = "Ranged attack power and crit, ranged weapon skill, with a ranged weapon equipped." },
  { id = "hcstats:spell", title = "Spell", description = "Spell damage and healing, spell crit and hit, mana regeneration." },
  { id = "hcstats:defence", title = "Defence", description = "Armour, dodge, parry and block, Defense skill." },
}
for _, t in ipairs(ns.TRACKERS) do
  HC:RegisterTracker(t.id, { title = t.title, category = "Character", counters = {}, default = "off",
    description = t.description .. " Live only: in combat a value is the last one read before the fight." })
end

---------------------------------------------------------------------------
-- Readings (DESIGN §3, phase 1). { id, title, tracker, read, formatter, applies, description }
---------------------------------------------------------------------------

local A, M, R, S, D = "hcstats:attributes", "hcstats:melee", "hcstats:ranged", "hcstats:spell", "hcstats:defence"

ns.STATS = {
  { "str", "Strength", A, attribute(1), "number", nil, "Strength with gear and buffs." },
  { "agi", "Agility", A, attribute(2), "number", nil, "Agility with gear and buffs." },
  { "sta", "Stamina", A, attribute(3), "number", nil, "Stamina with gear and buffs." },
  { "int", "Intellect", A, attribute(4), "number", classIs(MANA), "Intellect with gear and buffs." },
  { "spi", "Spirit", A, attribute(5), "number", nil, "Spirit with gear and buffs." },
  { "health", "Max health", A, function() return first(UnitHealthMax, "player") end, "number", nil, "Maximum health." },
  { "power", "Max mana", A, function() return first(UnitPowerMax, "player", 0) end, "number", classIs(MANA),
    "Maximum mana." },
  { "ap", "Attack power", M, function() return apTotal(UnitAttackPower) end, "number", nil,
    "Melee attack power with buffs." },
  { "crit", "Crit", M, function() return first(GetCritChance) end, "percent", nil, "Melee crit chance." },
  { "hit", "Hit", M, function() return first(GetHitModifier) end, "percent", hasCall("GetHitModifier"),
    "Melee hit bonus from gear and talents." },
  { "mainskill", "Main-hand skill", M, slotSkill(SLOT_MAIN), "number", nil,
    "Weapon skill of your main-hand weapon (bare hands: Unarmed), gear and talent bonus included. Its cap is the target." },
  { "offskill", "Off-hand skill", M, slotSkill(SLOT_OFF), "number", holdsWeapon(SLOT_OFF),
    "Weapon skill of your off-hand weapon, gear and talent bonus included. Its cap is the target." },
  { "rap", "Ranged attack power", R, function() return apTotal(UnitRangedAttackPower) end, "number", usesRanged,
    "Ranged attack power with buffs." },
  { "rcrit", "Ranged crit", R, function() return first(GetRangedCritChance) end, "percent", usesRanged,
    "Ranged crit chance." },
  { "rangedskill", "Ranged skill", R, slotSkill(SLOT_RANGED), "number", holdsWeapon(SLOT_RANGED),
    "Weapon skill of your ranged weapon (bow, gun, crossbow, thrown, wand). Its cap is the target." },
  { "spelldmg", "Spell damage", S, bestSchool("GetSpellBonusDamage"), "number", classIs(CASTER),
    "Bonus spell damage of your best school." },
  { "healing", "Bonus healing", S, function() return first(GetSpellBonusHealing) end, "number", classIs(HEALER),
    "Bonus healing from gear." },
  { "spellcrit", "Spell crit", S, bestSchool("GetSpellCritChance"), "percent", classIs(CASTER),
    "Spell crit chance of your best school." },
  { "spellhit", "Spell hit", S, function() return first(GetSpellHitModifier) end, "percent", classIs(CASTER),
    "Spell hit bonus from gear and talents." },
  { "mp5", "Mana regen", S, manaRegen(false), "number", classIs(MANA), "Mana per 5 seconds while not casting." },
  { "mp5cast", "Mana regen while casting", S, manaRegen(true), "number", classIs(MANA),
    "Mana per 5 seconds while casting (the five-second rule)." },
  { "armor", "Armour", D, function()
      if type(UnitArmor) ~= "function" then return nil end
      local _, eff = UnitArmor("player")
      if anySecret(eff) then return SECRET end
      return num(eff)
    end, "number", nil, "Armour with gear and buffs." },
  { "dodge", "Dodge", D, function() return first(GetDodgeChance) end, "percent", nil, "Dodge chance." },
  { "parry", "Parry", D, function() return first(GetParryChance) end, "percent", classIs(PARRY), "Parry chance." },
  { "block", "Block", D, function() return first(GetBlockChance) end, "percent", classIs(BLOCK),
    "Block chance (with a shield)." },
  { "blockvalue", "Block value", D, function() return first(GetShieldBlock) end, "number", classIs(BLOCK),
    "Damage a block stops (with a shield)." },
  { "defense", "Defense", D, function() return skillValue(DEFENSE) end, "number", nil,
    "Defense skill, gear and talent bonus included. Its cap is the target." },
}

-- The game tells us when stats may have changed: boards that show a stat redraw then (Hard Counters listens only
-- while one of these readings is on a shown board). Combat start and end flip the "in combat" mark.
local REFRESH = { "UNIT_STATS", "UNIT_AURA", "PLAYER_EQUIPMENT_CHANGED", "UNIT_ATTACK_POWER", "UNIT_RANGED_ATTACK_POWER",
  "UNIT_DAMAGE", "UNIT_ATTACK_SPEED", "UNIT_RESISTANCES", "UNIT_MAXHEALTH", "UNIT_MAXPOWER", "PLAYER_LEVEL_UP",
  "COMBAT_RATING_UPDATE", "SPELL_POWER_CHANGED", "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED", "SKILL_LINES_CHANGED" }

local last, inCombat = {}, {}     -- id -> the last value read out of combat; id -> true while it is secret
ns.last = last

--- The compute of a live reading: the game's value now, or the last one read while the game keeps it secret.
local function liveCompute(id, read)
  return function()
    local v = read()
    if v == SECRET then
      inCombat[id] = true
      return last[id]
    end
    inCombat[id] = nil
    if v ~= nil then last[id] = v end
    return v
  end
end

-- Live in combat (CS-9, answered in game 2026-11-19): in combat these come back as secrets (CS-1), and Hard Counters
-- hands them straight to a tile's font string. Only stats that are one value from one call: attack power (a sum),
-- the best of six schools and mana per 5 need arithmetic, so they keep the last value read before the fight.
-- Never compare, add or concatenate what these return.
local function attrLive(index)
  return function() if UnitStat then local _, eff = UnitStat("player", index); return eff end end
end
local LIVE = {
  str = attrLive(1), agi = attrLive(2), sta = attrLive(3), int = attrLive(4), spi = attrLive(5),
  crit = function() return GetCritChance and GetCritChance() end,
  hit = function() return GetHitModifier and GetHitModifier() end,
  rcrit = function() return GetRangedCritChance and GetRangedCritChance() end,
  healing = function() return GetSpellBonusHealing and GetSpellBonusHealing() end,
  spellhit = function() return GetSpellHitModifier and GetSpellHitModifier() end,
  armor = function() if UnitArmor then local _, eff = UnitArmor("player"); return eff end end,
  dodge = function() return GetDodgeChance and GetDodgeChance() end,
  parry = function() return GetParryChance and GetParryChance() end,
  block = function() return GetBlockChance and GetBlockChance() end,
  blockvalue = function() return GetShieldBlock and GetShieldBlock() end,
}
ns.LIVE = LIVE

ns.IDS = {}
for i, s in ipairs(ns.STATS) do
  local id = "hcstats:" .. s[1]
  ns.IDS[i] = id
  HC:RegisterReading(id, { title = s[2], tracker = s[3], scopes = { "now" }, formatter = s[5], order = 300 + i,
    description = s[7], compute = liveCompute(id, s[4]), applies = s[6], refresh = REFRESH,
    stale = function() return inCombat[id] == true, "in combat" end, live = LIVE[s[1]], target = TARGET[s[1]] })
end

---------------------------------------------------------------------------
-- Board presets (DESIGN §6), offered under New board. No derived rows yet (CS-7).
---------------------------------------------------------------------------

if HC.RegisterBoardPreset then
  -- (Hard Counters DESIGN §16.9, CS-11) a tile's display and size; every stat is a stock, so the calc is total.
  -- Default: a half-width number. A skill is a line bar toward its cap.
  local function tile(stat, size, display)
    return { reading = "hcstats:" .. stat, scope = "now", display = display or "number", size = size or "half" }
  end
  local BIG, LINE = "large", "line"
  local function bar(stat) return tile(stat, LINE, "bar") end
  HC:RegisterBoardPreset("hcstats:caster", { name = "Caster", tiles = { tile("spelldmg", BIG), tile("spellcrit"),
    tile("spellhit"), tile("mp5cast"), tile("int"), tile("healing", LINE) } })
  HC:RegisterBoardPreset("hcstats:melee", { name = "Melee", tiles = { tile("ap", BIG), tile("crit"), tile("hit"),
    tile("str"), tile("agi"), bar("mainskill") } })
  HC:RegisterBoardPreset("hcstats:hunter", { name = "Hunter", tiles = { tile("rap", BIG), tile("rcrit"), tile("hit"),
    tile("agi"), tile("mp5"), bar("rangedskill") } })
  HC:RegisterBoardPreset("hcstats:tank", { name = "Tank", tiles = { tile("armor", BIG), tile("dodge"), tile("parry"),
    tile("block"), tile("health"), tile("blockvalue"), bar("defense") } })
end
