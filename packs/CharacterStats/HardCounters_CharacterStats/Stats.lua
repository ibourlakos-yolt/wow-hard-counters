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

local skillLine                -- (below: the C_SkillInfo entry for a skill line id)
local FIST_SUBCLASS, FIST_SKILL = 13, 473

--- The skill line id of the weapon in a slot: nil when the slot holds no weapon (an off-hand shield, nothing in the
--- ranged slot); bare hands for an empty main hand.
local function weaponSkillID(slot)
  if type(GetInventoryItemID) ~= "function" then return nil end
  local id = GetInventoryItemID("player", slot)
  if id == nil then return slot == SLOT_MAIN and UNARMED or nil end
  if HC:IsSecret(id) then return nil end
  local classID, sub = itemClass(id)
  if classID ~= WEAPON_CLASS or HC:IsSecret(sub) then return nil end
  -- (CS-12, the user's sighting 2026-11-23) on Forever a fist weapon trains Unarmed: there is no Fist Weapons
  -- line. A client that has the line keeps it.
  if sub == FIST_SUBCLASS and not skillLine(FIST_SKILL) then return UNARMED end
  return SKILL_OF_SUBCLASS[sub]
end

--- The C_SkillInfo entry for a skill line id (by id where the client offers it, else by walking the visible lines;
--- a line under a header the player collapsed isn't listed). nil when the character doesn't have it.
function skillLine(skillID)
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
  { id = "hcstats:melee", title = "Melee", description = "Attack power, crit and hit chance, weapon damage, speed and skill." },
  { id = "hcstats:ranged", title = "Ranged",
    description = "Ranged attack power and crit, ranged damage, speed and weapon skill, with a ranged weapon equipped." },
  { id = "hcstats:spell", title = "Spell",
    description = "Spell damage and healing (by school too), spell crit and hit, spell penetration, mana regeneration." },
  -- (the id keeps the old spelling; the player sees the game's)
  { id = "hcstats:defence", title = "Defense", description = "Armor, dodge, parry and block, Defense skill." },
  -- (CS-14, 2026-11-24) one reading, the school picked on the tile
  { id = "hcstats:resist", title = "Resistances", description = "Fire, frost, nature, shadow and arcane resistance, buffs included." },
  { id = "hcstats:gear", title = "Gear", description = "Your lowest durability and your average item level." },
}
for _, t in ipairs(ns.TRACKERS) do
  HC:RegisterTracker(t.id, { title = t.title, category = "Character", counters = {}, default = "off",
    description = t.description .. " Live only: in combat a value is the last one read before the fight." })
end

---------------------------------------------------------------------------
-- More readers (2026-11-24, the user: "add any missing stats"): weapon damage and speed, spell power by school,
-- spell penetration, resistances (CS-14), gear. Every call answered Diagnostics' CS-1 probes on Forever (numbers out
-- of combat, 2026-11-24); each still returns nil when a call is missing.
---------------------------------------------------------------------------

--- A weapon's damage per second: the average of its damage range (buffs and attack power included, as the game
--- reports it) over its speed. off: the off hand.
local function weaponDps(off)
  return function()
    if type(UnitDamage) ~= "function" or type(UnitAttackSpeed) ~= "function" then return nil end
    local lo, hi, olo, ohi = UnitDamage("player")
    local ms, os = UnitAttackSpeed("player")
    if anySecret(lo, hi, olo, ohi, ms, os) then return SECRET end
    local a, b, s
    if off then a, b, s = num(olo), num(ohi), num(os) else a, b, s = num(lo), num(hi), num(ms) end
    if not (a and b and s) or s <= 0 then return nil end
    return (a + b) / 2 / s
  end
end

--- Seconds between swings (haste included).
local function weaponSpeed(off)
  return function()
    if type(UnitAttackSpeed) ~= "function" then return nil end
    local ms, os = UnitAttackSpeed("player")
    local v = off and os or ms
    if anySecret(v) then return SECRET end
    v = num(v)
    return v and v > 0 and v or nil
  end
end

--- The ranged weapon's damage per second ("dps") or its speed ("speed").
local function ranged(what)
  return function()
    if type(UnitRangedDamage) ~= "function" then return nil end
    local s, lo, hi = UnitRangedDamage("player")
    if anySecret(s, lo, hi) then return SECRET end
    s, lo, hi = num(s), num(lo), num(hi)
    if not s or s <= 0 then return nil end
    if what == "speed" then return s end
    if not (lo and hi) then return nil end
    return (lo + hi) / 2 / s
  end
end

-- Spell schools as GetSpellBonusDamage and GetSpellCritChance number them; resistances as UnitResistance does.
local SPELL_SCHOOLS = { 2, 3, 4, 5, 6, 7 }
local SPELL_SCHOOL = { [2] = "Holy", [3] = "Fire", [4] = "Nature", [5] = "Frost", [6] = "Shadow", [7] = "Arcane" }
local RESISTS = { 2, 3, 4, 5, 6 }
local RESIST = { [2] = "Fire", [3] = "Nature", [4] = "Frost", [5] = "Shadow", [6] = "Arcane" }
ns.SPELL_SCHOOL, ns.RESIST = SPELL_SCHOOL, RESIST

--- One school's value of fn(school), or the best school's when none is picked (as the character pane's line).
local function bySchool(fnName)
  local best = bestSchool(fnName)
  return function(arg)
    if arg == nil then return best() end
    return first(_G[fnName], arg)
  end
end

local function resistance(arg)
  if type(UnitResistance) ~= "function" or type(arg) ~= "number" then return nil end
  local _, total = UnitResistance("player", arg)
  if anySecret(total) then return SECRET end
  return num(total)
end

--- The lowest durability of what you wear, in %: the item that breaks first. nil with nothing that has durability.
local function lowestDurability()
  if type(GetInventoryItemDurability) ~= "function" then return nil end
  local low
  for slot = 1, 18 do
    local cur, max = GetInventoryItemDurability(slot)
    if anySecret(cur, max) then return SECRET end
    cur, max = num(cur), num(max)
    if cur and max and max > 0 then
      local p = cur / max * 100
      if not low or p < low then low = p end
    end
  end
  return low
end

--- The average item level of what you wear (the game's second return), else of your best items.
local function itemLevel()
  if type(GetAverageItemLevel) ~= "function" then return nil end
  local all, equipped = GetAverageItemLevel()
  if anySecret(all, equipped) then return SECRET end
  local v = num(equipped) or num(all)
  return v and v > 0 and v or nil
end

-- (CS-13) the weapon skills and Defense: what "Weapon skill: pick a skill" offers
local WEAPON_SKILLS = { [UNARMED] = true, [DEFENSE] = true, [FIST_SKILL] = true }
for _, sk in pairs(SKILL_OF_SUBCLASS) do WEAPON_SKILLS[sk] = true end

---------------------------------------------------------------------------
-- Readings (DESIGN §3, phase 1). { id, title, tracker, read, formatter, applies, description, opts }
-- opts (2026-11-24): param, target, pickTitle, rows (the window's rows: { { arg, title } }; none: one row), noRow.
---------------------------------------------------------------------------

local A, M, R, S, D = "hcstats:attributes", "hcstats:melee", "hcstats:ranged", "hcstats:spell", "hcstats:defence"
local RS, G = "hcstats:resist", "hcstats:gear"

local function schoolParam(any)
  return { dim = "school", type = "enum", members = SPELL_SCHOOLS, label = function(k) return SPELL_SCHOOL[k] end,
    optional = true, anyLabel = "Best school", anyTitle = any }
end
local resistRows = {}
for _, k in ipairs(RESISTS) do resistRows[#resistRows + 1] = { arg = k, title = RESIST[k] .. " resistance" } end

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
  -- (2026-11-24) "Melee crit": there are ranged and spell crit too
  { "crit", "Melee crit", M, function() return first(GetCritChance) end, "percent", nil, "Melee crit chance." },
  { "hit", "Hit (melee and ranged)", M, function() return first(GetHitModifier) end, "percent", hasCall("GetHitModifier"),
    "Hit bonus from gear and talents, for melee and ranged attacks (spell hit is its own)." },
  { "mhdps", "Main-hand DPS", M, weaponDps(false), "decimal", nil,
    "Your main-hand weapon's damage per second, attack power and buffs included." },
  { "mhspeed", "Main-hand speed", M, weaponSpeed(false), "seconds", nil, "Seconds between main-hand swings." },
  { "ohdps", "Off-hand DPS", M, weaponDps(true), "decimal", holdsWeapon(SLOT_OFF),
    "Your off-hand weapon's damage per second, attack power and buffs included." },
  { "ohspeed", "Off-hand speed", M, weaponSpeed(true), "seconds", holdsWeapon(SLOT_OFF), "Seconds between off-hand swings." },
  { "mainskill", "Main-hand skill", M, slotSkill(SLOT_MAIN), "number", nil,
    "Weapon skill of your main-hand weapon (bare hands and fist weapons: Unarmed), gear and talent bonus included. Its cap is the target." },
  { "offskill", "Off-hand skill", M, slotSkill(SLOT_OFF), "number", holdsWeapon(SLOT_OFF),
    "Weapon skill of your off-hand weapon, gear and talent bonus included. Its cap is the target." },
  { "skill", "Weapon skill", M, function(arg) return skillValue(arg) end, "number", nil,
    "Any weapon skill you have, or Defense, whatever you hold: watch one you are training. Its cap is the target.",
    { param = { dim = "skill", type = "skill", filter = function(line) return WEAPON_SKILLS[line.id] == true end },
      pickTitle = "Weapon skill: pick a skill", target = function(arg) return skillCap(arg) end, noRow = true } },
  { "rap", "Ranged attack power", R, function() return apTotal(UnitRangedAttackPower) end, "number", usesRanged,
    "Ranged attack power with buffs." },
  { "rcrit", "Ranged crit", R, function() return first(GetRangedCritChance) end, "percent", usesRanged,
    "Ranged crit chance." },
  { "rdps", "Ranged DPS", R, ranged("dps"), "decimal", holdsWeapon(SLOT_RANGED),
    "Your ranged weapon's damage per second, ranged attack power and buffs included." },
  { "rspeed", "Ranged speed", R, ranged("speed"), "seconds", holdsWeapon(SLOT_RANGED), "Seconds between ranged shots." },
  { "rangedskill", "Ranged skill", R, slotSkill(SLOT_RANGED), "number", holdsWeapon(SLOT_RANGED),
    "Weapon skill of your ranged weapon (bow, gun, crossbow, thrown, wand). Its cap is the target." },
  { "spelldmg", "Spell damage", S, bySchool("GetSpellBonusDamage"), "number", classIs(CASTER),
    "Bonus spell damage: of your best school, or one school picked on the tile.",
    { param = schoolParam("Spell damage (best school)") } },
  { "healing", "Bonus healing", S, function() return first(GetSpellBonusHealing) end, "number", classIs(HEALER),
    "Bonus healing from gear." },
  { "spellcrit", "Spell crit", S, bySchool("GetSpellCritChance"), "percent", classIs(CASTER),
    "Spell crit chance: of your best school, or one school picked on the tile.",
    { param = schoolParam("Spell crit (best school)") } },
  { "spellhit", "Spell hit", S, function() return first(GetSpellHitModifier) end, "percent", classIs(CASTER),
    "Spell hit bonus from gear and talents." },
  { "spellpen", "Spell penetration", S, function() return first(GetSpellPenetration) end, "number",
    function() return classIs(CASTER)() and hasCall("GetSpellPenetration")() end,
    "Enemy resistance your spells ignore, from gear." },
  { "mp5", "Mana regen (not casting)", S, manaRegen(false), "number", classIs(MANA), "Mana per 5 seconds while not casting." },
  { "mp5cast", "Mana regen (casting)", S, manaRegen(true), "number", classIs(MANA),
    "Mana per 5 seconds while casting (the five-second rule)." },
  { "armor", "Armor", D, function()
      if type(UnitArmor) ~= "function" then return nil end
      local _, eff = UnitArmor("player")
      if anySecret(eff) then return SECRET end
      return num(eff)
    end, "number", nil, "Armor with gear and buffs." },
  { "dodge", "Dodge", D, function() return first(GetDodgeChance) end, "percent", nil, "Dodge chance." },
  { "parry", "Parry", D, function() return first(GetParryChance) end, "percent", classIs(PARRY), "Parry chance." },
  { "block", "Block chance", D, function() return first(GetBlockChance) end, "percent", classIs(BLOCK),
    "Block chance (with a shield)." },
  { "blockvalue", "Block value", D, function() return first(GetShieldBlock) end, "number", classIs(BLOCK),
    "Damage a block stops (with a shield)." },
  { "defense", "Defense", D, function() return skillValue(DEFENSE) end, "number", nil,
    "Defense skill, gear and talent bonus included. Its cap is the target." },
  { "resist", "Resistance", RS, resistance, "number", nil,
    "One school's resistance, buffs included, picked on the tile: fire, frost, nature, shadow or arcane.",
    { param = { dim = "school", type = "enum", members = RESISTS, label = function(k) return RESIST[k] end },
      pickTitle = "Resistance: pick a school", rows = resistRows } },
  { "durability", "Lowest durability", G, lowestDurability, "percent", nil,
    "The durability of the item you wear that breaks first, in %. Repair before it reaches 0." },
  { "ilvl", "Average item level", G, itemLevel, "decimal", hasCall("GetAverageItemLevel"),
    "The average item level of what you wear." },
}

-- The game tells us when stats may have changed: boards that show a stat redraw then (Hard Counters listens only
-- while one of these readings is on a shown board). Combat start and end flip the "in combat" mark.
local REFRESH = { "UNIT_STATS", "UNIT_AURA", "PLAYER_EQUIPMENT_CHANGED", "UNIT_ATTACK_POWER", "UNIT_RANGED_ATTACK_POWER",
  "UNIT_DAMAGE", "UNIT_ATTACK_SPEED", "UNIT_RESISTANCES", "UNIT_MAXHEALTH", "UNIT_MAXPOWER", "PLAYER_LEVEL_UP",
  "COMBAT_RATING_UPDATE", "SPELL_POWER_CHANGED", "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED", "SKILL_LINES_CHANGED",
  "UPDATE_INVENTORY_DURABILITY", "UNIT_RANGEDDAMAGE" }

local last, inCombat = {}, {}     -- key -> the last value read out of combat; key -> true while it is secret
ns.last = last

--- The cache key of a reading with its member (the school of a resistance): one value kept per member.
local function cacheKey(id, arg)
  if arg == nil then return id end
  return id .. "\0" .. tostring(arg)
end
ns.LastKey = cacheKey

--- The compute of a live reading: the game's value now, or the last one read while the game keeps it secret.
local function liveCompute(id, read)
  return function(_, _, arg)
    local k = cacheKey(id, arg)
    local v = read(arg)
    if v == SECRET then
      inCombat[k] = true
      return last[k]
    end
    inCombat[k] = nil
    if v ~= nil then last[k] = v end
    return v
  end
end

-- Live in combat (CS-9, answered in game 2026-11-19): in combat these come back as secrets (CS-1), and Hard Counters
-- hands them straight to a tile's font string. Only stats that are one value from one call: attack power (a sum),
-- the best of six schools, mana per 5 and damage per second need arithmetic, so they keep the last value read
-- before the fight. Never compare, add or concatenate what these return.
local function attrLive(index)
  return function() if UnitStat then local _, eff = UnitStat("player", index); return eff end end
end
local function schoolLive(fnName)
  return function(arg) local f = _G[fnName]; if arg ~= nil and f then return f(arg) end end
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
  mhspeed = function() if UnitAttackSpeed then return (UnitAttackSpeed("player")) end end,
  ohspeed = function() if UnitAttackSpeed then local _, os = UnitAttackSpeed("player"); return os end end,
  rspeed = function() if UnitRangedDamage then return (UnitRangedDamage("player")) end end,
  spelldmg = schoolLive("GetSpellBonusDamage"), spellcrit = schoolLive("GetSpellCritChance"),
  spellpen = function() return GetSpellPenetration and GetSpellPenetration() end,
  resist = function(arg) if UnitResistance and arg ~= nil then local _, total = UnitResistance("player", arg); return total end end,
}
ns.LIVE = LIVE

-- The window's rows (UI/Window.lua): one per reading, or one per member listed in `rows`; none for `noRow`.
ns.IDS, ns.ROWS = {}, {}
for i, s in ipairs(ns.STATS) do
  local id = "hcstats:" .. s[1]
  local o = s[8] or {}
  ns.IDS[i] = id
  HC:RegisterReading(id, { title = s[2], tracker = s[3], scopes = { "now" }, formatter = s[5], order = 300 + i,
    description = s[7], compute = liveCompute(id, s[4]), applies = s[6], refresh = REFRESH,
    param = o.param, pickTitle = o.pickTitle,
    stale = function(arg) return inCombat[cacheKey(id, arg)] == true, "in combat" end, live = LIVE[s[1]],
    target = o.target or TARGET[s[1]] })
  if o.rows then
    for _, row in ipairs(o.rows) do
      ns.ROWS[#ns.ROWS + 1] = { id = id, arg = row.arg, title = row.title, tracker = s[3], tip = s[7] }
    end
  elseif not o.noRow then
    ns.ROWS[#ns.ROWS + 1] = { id = id, title = s[2], tracker = s[3], tip = s[7] }
  end
end

---------------------------------------------------------------------------
-- Board presets (DESIGN §6), offered under New board: by role and by class (the user, 2026-11-24; Hard Counters
-- HC-57). No derived rows yet (CS-7): a tank board shows Defense toward its cap, not "crit immune".
---------------------------------------------------------------------------

if HC.RegisterBoardPreset then
  -- (Hard Counters DESIGN §16.9, CS-11) a tile's display and size; every stat is a stock, so the calc is total.
  -- Default: a half-width number. A skill is a line bar toward its cap.
  local function tile(stat, size, display, arg)
    return { reading = "hcstats:" .. stat, scope = "now", display = display or "number", size = size or "half", arg = arg }
  end
  local BIG, LINE = "large", "line"
  local function bar(stat) return tile(stat, LINE, "bar") end
  local function school(stat, k, size) return tile(stat, size, nil, k) end
  local FIRE, NATURE, FROST, SHADOW, ARCANE = 2, 3, 4, 5, 6             -- (UnitResistance's numbers)
  local S_NATURE, S_SHADOW = 4, 6                                       -- (GetSpellBonusDamage's numbers)
  local function role(key, name, tip, tiles)
    HC:RegisterBoardPreset("hcstats:" .. key, { name = name, category = "role", tip = tip, tiles = tiles })
  end
  local CLASS_TIP = "Your class's stats across its roles. Playing one role? Its board under Roles fits better."
  local function class(key, name, token, tiles)
    HC:RegisterBoardPreset("hcstats:" .. key, { name = name, category = "class", class = token, tip = CLASS_TIP, tiles = tiles })
  end

  -- Roles. The old keys stay (boards remember the preset they came from): Tank, Melee and Caster became the first
  -- of their kind; Hunter became the Hunter class board.
  role("tank", "Tank (physical)", "Armor, avoidance and Defense: taking hits from monsters that strike.",
    { tile("armor", BIG), bar("defense"), tile("dodge"), tile("parry"), tile("block"), tile("blockvalue"), tile("health", LINE) })
  role("spelltank", "Tank (spell)", "Health and every resistance: taking spells, as against a fire or shadow boss.",
    { tile("health", BIG), school("resist", FIRE), school("resist", FROST), school("resist", NATURE),
      school("resist", SHADOW), school("resist", ARCANE), tile("sta"), tile("armor", LINE) })
  role("melee", "Melee DPS", "Attack power, crit, hit and your weapon.",
    { tile("ap", BIG), tile("crit"), tile("hit"), tile("mhdps"), tile("mhspeed"), tile("str"), tile("agi"), bar("mainskill") })
  role("ranged", "Ranged DPS", "Ranged attack power, crit, hit and your ranged weapon.",
    { tile("rap", BIG), tile("rcrit"), tile("hit"), tile("rdps"), tile("agi"), tile("rspeed"), bar("rangedskill") })
  role("caster", "Caster DPS", "Spell damage, crit and hit, penetration and mana.",
    { tile("spelldmg", BIG), tile("spellcrit"), tile("spellhit"), tile("int"), tile("spellpen"), tile("mp5cast"), tile("power", LINE) })
  role("healdirect", "Healer (direct)", "Bonus healing and spell crit: direct heals can crit.",
    { tile("healing", BIG), tile("spellcrit"), tile("int"), tile("power"), tile("mp5cast", LINE) })
  role("healhot", "Healer (over time)", "Bonus healing, spirit and regen: heals over time don't crit, long fights reward mana.",
    { tile("healing", BIG), tile("spi"), tile("mp5cast"), tile("mp5"), tile("power"), tile("int") })

  -- The nine classes.
  class("warrior", "Warrior", "WARRIOR", { tile("ap", BIG), tile("crit"), tile("hit"), bar("mainskill"), tile("armor"),
    tile("dodge"), tile("parry"), bar("defense") })
  class("paladin", "Paladin", "PALADIN", { tile("healing", BIG), tile("spellcrit"), tile("int"), tile("mp5cast"), tile("ap"),
    tile("crit"), tile("armor"), tile("blockvalue") })
  class("hunter", "Hunter", "HUNTER", { tile("rap", BIG), tile("rcrit"), tile("hit"), tile("rdps"), tile("agi"), tile("mp5"),
    bar("rangedskill") })
  class("rogue", "Rogue", "ROGUE", { tile("ap", BIG), tile("crit"), tile("hit"), tile("agi"), tile("mhdps"), tile("dodge"),
    bar("mainskill"), bar("offskill") })
  class("priest", "Priest", "PRIEST", { tile("healing", BIG), school("spelldmg", S_SHADOW), tile("spellcrit"), tile("int"),
    tile("spi"), tile("mp5cast"), tile("power", LINE) })
  class("shaman", "Shaman", "SHAMAN", { tile("healing", BIG), school("spelldmg", S_NATURE), tile("spellcrit"), tile("int"),
    tile("mp5cast"), tile("ap"), tile("crit", LINE) })
  class("mage", "Mage", "MAGE", { tile("spelldmg", BIG), tile("spellcrit"), tile("spellhit"), tile("int"), tile("power"),
    tile("mp5cast") })
  class("warlock", "Warlock", "WARLOCK", { school("spelldmg", S_SHADOW, BIG), tile("spellcrit"), tile("spellhit"), tile("sta"),
    tile("int"), tile("health"), tile("spellpen") })
  class("druid", "Druid", "DRUID", { tile("healing", BIG), school("spelldmg", S_NATURE), tile("spellcrit"), tile("ap"),
    tile("crit"), tile("armor"), tile("dodge"), tile("power") })
end
