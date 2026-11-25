-- Character Stats, phase 1 (DESIGN §8, decided 2026-11-19): the character sheet as live `now` readings with no
-- counters. Each reading asks the game when a board or the window draws it; nothing is stored, nothing polls.
-- Stats are secret in combat on Forever (CS-1): a reading then shows the last value it read out of combat, greyed,
-- with "in combat" after its title (Hard Counters' `stale` state, HC-28), never a secret. Rows that don't apply to
-- this character (parry for a mage) say so (`applies`, HC-28). No derived "≈" rows before CS-7.
-- Built ONLY on Hard Counters' public API (docs/API.md at the repo root).
-- luacheck: no max line length (descriptions: one sentence, one string)
local ADDON, ns = ...

local HC = HardCounters
if not HC or (HC.API_VERSION or 0) < 1 or not (HC.Supports and HC:Supports("liveTrackers")
    and HC:Supports("readingStates")) then return end

local type, select, ipairs = type, select, ipairs

ns.VERSION = "0.3.0-beta2"
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

-- Mana per 5 seconds from buffs (the user, 2026-11-25: "Blessing of Wisdom doesn't seem to affect the mana regen").
-- GetManaRegen leaves flat "mana per 5" buffs out, as it does on Classic, where the stat addons add them by hand.
-- So do we: the player's own helpful auras are looked up by spell id. { mana per 5 of that rank, scale }: the
-- aura's own amount (`points[1]`), where the client gives one, is used instead of the rank's figure, times `scale`
-- (a blessing's amount is per 5 seconds: 1; Mana Spring's is per 2 seconds: 2.5).
-- The ids are Classic's (Blessing of Wisdom and its Greater form, Mana Spring Totem): unverified on Forever; the
-- Diagnostics probe "CS-18 mana per 5 auras" says which of your buffs matched.
local MP5_AURAS = {
  [19742] = { 10, 1 }, [19850] = { 15, 1 }, [19852] = { 20, 1 }, [19853] = { 25, 1 }, [19854] = { 30, 1 },
  [25290] = { 33, 1 }, [25894] = { 30, 1 }, [25918] = { 33, 1 },
  [5677] = { 10, 2.5 }, [10491] = { 15, 2.5 }, [10493] = { 20, 2.5 }, [10494] = { 25, 2.5 },
}
ns.MP5_AURAS = MP5_AURAS

--- Mana per 5 seconds from the buffs on you that give a flat amount; 0 with none; SECRET when the game hides auras.
local function auraMp5()
  local A = C_UnitAuras
  if type(A) ~= "table" or type(A.GetAuraDataByIndex) ~= "function" then return 0 end
  local sum = 0
  for i = 1, 40 do
    local ok, d = pcall(A.GetAuraDataByIndex, "player", i, "HELPFUL")
    if not ok or d == nil then break end
    if HC:IsSecret(d) then return SECRET end
    if type(d) ~= "table" then break end
    local id = d.spellId
    if anySecret(id) then return SECRET end
    local known = MP5_AURAS[id]
    if known then
      local p = type(d.points) == "table" and d.points[1] or nil
      if p ~= nil and anySecret(p) then return SECRET end
      p = num(p)
      sum = sum + ((p and p > 0) and p * known[2] or known[1])
    end
  end
  return sum
end
ns.AuraMp5 = auraMp5

--- Mana regenerated per 5 seconds (per second with `perSecond`): GetManaRegen returns per second, (not casting,
--- casting); flat mana-per-5 buffs are added to both (they tick while you cast too).
local function manaRegen(casting, perSecond)
  return function()
    if type(GetManaRegen) ~= "function" then return nil end
    local base, whileCasting = GetManaRegen()
    if anySecret(base, whileCasting) then return SECRET end
    local v = num(casting and whileCasting or base)
    if not v then return nil end
    local buffs = auraMp5()
    if buffs == SECRET then return SECRET end
    v = v * 5 + buffs
    return perSecond and v / 5 or v
  end
end

--- A regeneration call that returns two rates per second (GetManaRegen: not casting, casting; GetHealthRegen: out
--- of combat, in combat; GetManaRegenFromSpirit likewise): the first or the second, times `mult` (5: per five
--- seconds, as players say it; 1: per second).
local function regen(fnName, second, mult)
  return function()
    local fn = _G[fnName]
    if type(fn) ~= "function" then return nil end
    local a, b = fn()
    if anySecret(a, b) then return SECRET end
    local v = num(second and b or a)
    return v and v * mult or nil
  end
end

---------------------------------------------------------------------------
-- The five-second rule (the user, 2026-11-25; the trigger fixed 2026-11-25 for 0.3.0-beta2). Spending mana on a
-- spell stops spirit regeneration for five seconds from the moment the cast completes (a channel: from its start,
-- when its mana is taken); each spend restarts the five seconds. It is the spend that counts, not the cast: a spell
-- that costs nothing (Fishing, a profession, a wand's Shoot, a mount, eating or drinking, a potion) and a free cast
-- (Clearcasting, Inner Focus) leave regeneration running, and so does a cast that is cancelled or interrupted. Mp5
-- from gear and buffs ignores the rule. (Sources: the 1.4.0 patch note on warcraft.wiki.gg "Mana regeneration", and
-- the FiveSecondRule addon, which starts its timer on UNIT_SPELLCAST_SUCCEEDED only when the player's mana fell.)
--
-- The reading counts those seconds, 0 to 5, toward a target of 5, so as a bar it fills while you wait and is full
-- once regeneration is back. How a spend is told:
--   1. Mana readable (UnitPower not secret): your own cast succeeded AND your mana fell, either one first, within
--      half a second of each other (the two events arrive in either order). This is the proof; the spell's listed
--      cost is not asked, so a clearcast (listed cost, nothing paid) doesn't start it.
--   2. Mana secret (in combat on Forever, possibly): the spell's own power cost (C_Spell.GetSpellPowerCost) must
--      list mana. A clearcast then starts it too: the one known miss, said in the reading's description.
--   3. Neither can tell: the clock does NOT start. Before 0.3.0-beta2 "can't tell" counted as a spend, so a spell
--      with no cost entry at all (Fishing: the client answers nil) started the clock.
-- Unverified on Forever: whether UnitPower("player", 0) turns secret in combat (then path 2 runs in fights).
---------------------------------------------------------------------------

local FSR = 5
local PAIR = 0.5                  -- seconds allowed between a cast and the mana drop that proves it cost mana
local POWER_MANA = 0              -- Enum.PowerType.Mana
local fsrAt                       -- GetTime() of the last mana-spending cast
local fsrTicker
local lastMana                    -- the player's mana when last seen plain (nil: unknown or secret)
local dropAt                      -- GetTime() of the last mana drop not yet matched to a cast
local castAt                      -- GetTime() of the last cast of ours not yet matched to a mana drop

local function clockNow()
  if type(GetTime) ~= "function" then return nil end
  local t = GetTime()
  if HC:IsSecret(t) then return nil end
  return num(t)
end

--- The player's mana now, or nil when the call is missing or the value is secret.
local function manaNow()
  if type(UnitPower) ~= "function" then return nil end
  local ok, m = pcall(UnitPower, "player", POWER_MANA)
  if not ok or HC:IsSecret(m) then return nil end
  return num(m)
end

--- Does this spell list a mana cost? true, false, or nil when the client can't say (nil is NOT a spend).
--- An entry that needs an aura the player hasn't got doesn't count; a cost per second (a channel) or in percent does.
local function costsMana(spellID)
  local f = (type(C_Spell) == "table" and C_Spell.GetSpellPowerCost) or GetSpellPowerCost
  if type(f) ~= "function" or spellID == nil or HC:IsSecret(spellID) then return nil end
  local ok, costs = pcall(f, spellID)
  if not ok or type(costs) ~= "table" then return nil end
  for i = 1, #costs do
    local c = costs[i]
    if type(c) == "table" then
      if anySecret(c.type, c.cost, c.costPerSec, c.costPercent, c.requiredAuraID, c.hasRequiredAura) then return nil end
      local needsAura = (num(c.requiredAuraID) or 0) ~= 0 and c.hasRequiredAura == false
      if c.type == POWER_MANA and not needsAura
        and ((num(c.cost) or 0) > 0 or (num(c.costPerSec) or 0) > 0 or (num(c.costPercent) or 0) > 0) then
        return true
      end
    end
  end
  return false
end
ns.CostsMana = costsMana

--- The five seconds start again at time t. Boards are told to redraw while they run.
local function startFsr(t)
  fsrAt = t
  dropAt, castAt = nil, nil
  if HC.ReadingsChanged then
    HC:ReadingsChanged()
    if fsrTicker then fsrTicker:Cancel() end
    if type(C_Timer) == "table" and C_Timer.NewTicker then
      -- four redraws a second for the five seconds, and one after: then nothing runs until the next spend
      fsrTicker = C_Timer.NewTicker(0.25, function() HC:ReadingsChanged() end, FSR * 4 + 1)
    end
  end
end

--- Your mana changed (UNIT_POWER_FREQUENT: unit, power token) or you entered the world (seeds the last value).
--- A drop right after a cast of ours proves that cast cost mana; a drop with no cast yet waits half a second for one.
local function onPower(event, unit, powerType)
  if event ~= "PLAYER_ENTERING_WORLD" then
    if HC:IsSecret(unit) or unit ~= "player" then return end
    if powerType ~= nil and (HC:IsSecret(powerType) or powerType ~= "MANA") then return end
  end
  local m = manaNow()
  if not m then lastMana = nil return end
  if lastMana and m < lastMana then
    local t = clockNow()
    if t then
      if castAt and t - castAt <= PAIR then startFsr(castAt) else dropAt = t end
    end
  end
  lastMana = m
end
ns.OnPower = onPower

--- A spell of yours went off (UNIT_SPELLCAST_SUCCEEDED: unit, cast id, spell id). It starts the five seconds only
--- if it spent mana: see the block comment above for how that is told.
local function onCast(_, unit, _, spellID)
  if HC:IsSecret(unit) or unit ~= "player" then return end
  local t = clockNow()
  if not t then return end
  local m = manaNow()
  if m then
    if lastMana and m < lastMana then              -- the drop is already in UnitPower, its event not seen yet
      lastMana = m
      startFsr(t)
    elseif dropAt and t - dropAt <= PAIR then      -- the drop's event came first
      lastMana = m
      startFsr(t)
    else                                           -- no drop yet: wait half a second for one
      lastMana = m
      castAt = t
    end
  elseif costsMana(spellID) == true then           -- mana is secret: trust the listed cost
    startFsr(t)
  end
end
ns.OnCast = onCast

--- Seconds since the last spell that cost mana, at most 5 (5: spirit regeneration is running).
local function fsrElapsed()
  local t = clockNow()
  if not (t and fsrAt) then return FSR end
  local d = t - fsrAt
  if d >= FSR then return FSR end
  return d > 0 and d or 0
end

--- Spell crit of the school this class heals with (Holy: priest, paladin; Nature: druid, shaman).
local HEAL_SCHOOL = { PRIEST = 2, PALADIN = 2, DRUID = 4, SHAMAN = 4 }
local function healCrit()
  if type(UnitClass) ~= "function" then return nil end
  local _, token = UnitClass("player")
  if HC:IsSecret(token) then return nil end
  local k = HEAL_SCHOOL[token]
  if not k then return nil end
  return first(GetSpellCritChance, k)
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

-- (the user, 2026-11-25) The magic schools a class has abilities in, the ones worth a tile each, in the order its
-- schools board shows them (GetSpellBonusDamage's numbers: 2 holy, 3 fire, 4 nature, 5 frost, 6 shadow, 7 arcane).
-- Not only casters: a hunter's Arcane Shot, stings and traps, a rogue's poisons. A warrior has none.
-- What the game reports per school is its own sum (CS-16 probes say how far that goes); a hunter's and a rogue's
-- abilities mostly scale with attack power, so their spell damage often reads 0: the tiles show what there is.
local CLASS_SCHOOLS = {
  MAGE = { 3, 5, 7 }, WARLOCK = { 6, 3 }, PRIEST = { 2, 6 }, PALADIN = { 2 }, SHAMAN = { 4, 3, 5 }, DRUID = { 4, 7 },
  HUNTER = { 7, 4, 3, 5 }, ROGUE = { 4 },
}
ns.CLASS_SCHOOLS = CLASS_SCHOOLS

--- Does this class have abilities of a magic school? (The per-school readings apply to it.)
local function usesSchools()
  if type(UnitClass) ~= "function" then return true end
  local _, token = UnitClass("player")
  if type(token) ~= "string" or HC:IsSecret(token) then return true end
  return CLASS_SCHOOLS[token] ~= nil
end

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
    description = "Strength, agility, stamina, intellect, spirit, health and mana, health regeneration, as the game reports them now." },
  { id = "hcstats:melee", title = "Melee", description = "Attack power, crit, hit and haste, weapon damage, speed and skill." },
  { id = "hcstats:ranged", title = "Ranged",
    description = "Ranged attack power and crit, ranged damage, speed and weapon skill, with a ranged weapon equipped." },
  { id = "hcstats:spell", title = "Spell",
    description = "Spell damage and crit (by school too), healing and healing crit, spell hit, haste and penetration, mana regeneration and the five-second rule." },
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
  -- (2026-11-25) health regeneration: GetHealthRegen gives health per second, out of combat and in combat
  { "hp5", "Health regen (out of combat)", A, regen("GetHealthRegen", false, 5), "decimal", hasCall("GetHealthRegen"),
    "Health per 5 seconds while out of combat, from spirit, talents and gear." },
  { "hp5combat", "Health regen (in combat)", A, regen("GetHealthRegen", true, 5), "decimal", hasCall("GetHealthRegen"),
    "Health per 5 seconds while in combat." },
  { "hps", "Health per second (out of combat)", A, regen("GetHealthRegen", false, 1), "decimal", hasCall("GetHealthRegen"),
    "Health regenerated each second while out of combat: Health regen (out of combat) divided by 5.", { noRow = true } },
  { "ap", "Attack power", M, function() return apTotal(UnitAttackPower) end, "number", nil,
    "Melee attack power with buffs." },
  -- (2026-11-24) "Melee crit": there are ranged and spell crit too
  { "crit", "Melee crit", M, function() return first(GetCritChance) end, "percent", nil, "Melee crit chance." },
  { "hit", "Hit (melee and ranged)", M, function() return first(GetHitModifier) end, "percent", hasCall("GetHitModifier"),
    "Hit bonus from gear and talents, for melee and ranged attacks (spell hit is its own)." },
  { "haste", "Melee haste", M, function() return first(GetMeleeHaste) end, "percent", hasCall("GetMeleeHaste"),
    "Attack speed bonus from gear and buffs, in %. Weapon speeds below already include it.", { noRow = true } },
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
  { "spelldmg", "Spell damage", S, bySchool("GetSpellBonusDamage"), "number", usesSchools,
    "Bonus spell damage: of your best school, or one school picked on the tile.",
    { param = schoolParam("Spell damage (best school)") } },
  { "healing", "Bonus healing", S, function() return first(GetSpellBonusHealing) end, "number", classIs(HEALER),
    "Bonus healing from gear." },
  { "healcrit", "Healing crit", S, healCrit, "percent", classIs(HEALER),
    "Crit chance of your healing spells: the spell crit of the school your class heals with (Holy or Nature).",
    { noRow = true } },
  { "spellcrit", "Spell crit", S, bySchool("GetSpellCritChance"), "percent", usesSchools,
    "Spell crit chance: of your best school, or one school picked on the tile.",
    { param = schoolParam("Spell crit (best school)") } },
  { "spellhit", "Spell hit", S, function() return first(GetSpellHitModifier) end, "percent", classIs(CASTER),
    "Spell hit bonus from gear and talents." },
  { "spellpen", "Spell penetration", S, function() return first(GetSpellPenetration) end, "number",
    function() return classIs(CASTER)() and hasCall("GetSpellPenetration")() end,
    "Enemy resistance your spells ignore, from gear." },
  { "spellhaste", "Spell haste", S, function() return first(UnitSpellHaste, "player") end, "percent",
    function() return classIs(CASTER)() and hasCall("UnitSpellHaste")() end,
    "Casting speed bonus from gear and buffs, in %.", { noRow = true } },
  { "mp5", "Mana regen (not casting)", S, manaRegen(false), "number", classIs(MANA),
    "Mana per 5 seconds while not casting, Blessing of Wisdom and Mana Spring included." },
  { "mp5cast", "Mana regen (casting)", S, manaRegen(true), "number", classIs(MANA),
    "Mana per 5 seconds while casting (the five-second rule), Blessing of Wisdom and Mana Spring included." },
  -- (2026-11-25) the same two per second, mana from spirit alone, and the five-second rule itself
  { "mps", "Mana per second (not casting)", S, manaRegen(false, true), "decimal", classIs(MANA),
    "Mana regenerated each second while not casting: Mana regen (not casting) divided by 5.", { noRow = true } },
  { "mpscast", "Mana per second (casting)", S, manaRegen(true, true), "decimal", classIs(MANA),
    "Mana regenerated each second while casting: Mana regen (casting) divided by 5.", { noRow = true } },
  { "mp5spirit", "Mana regen from spirit", S, regen("GetManaRegenFromSpirit", false, 5), "decimal",
    function() return classIs(MANA)() and hasCall("GetManaRegenFromSpirit")() end,
    "The part of your mana per 5 seconds that comes from spirit: what the five-second rule switches off." },
  { "fsr", "Five-second rule", S, fsrElapsed, "seconds", classIs(MANA),
    "Seconds since you last spent mana on a spell, up to 5. As a bar it fills while spirit regeneration is off and is full when it is back. Spells that cost nothing (Fishing, professions, a wand, mounts, food, potions) and free casts leave it full. Where your mana is hidden in combat, a clearcast spell may start it.",
    { target = function() return FSR end, noRow = true, plain = true } },
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
  haste = function() return GetMeleeHaste and GetMeleeHaste() end,
  spellhaste = function() return UnitSpellHaste and UnitSpellHaste("player") end,
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
    description = s[7], compute = o.plain and function() return s[4]() end or liveCompute(id, s[4]),
    applies = s[6], refresh = (not o.plain) and REFRESH or nil,
    param = o.param, pickTitle = o.pickTitle,
    -- (`plain`: a clock of our own, the five-second rule: never secret, redrawn by HC:ReadingsChanged)
    stale = (not o.plain) and function(arg) return inCombat[cacheKey(id, arg)] == true, "in combat" end or nil,
    live = LIVE[s[1]],
    target = o.target or TARGET[s[1]] })
  if o.rows then
    for _, row in ipairs(o.rows) do
      ns.ROWS[#ns.ROWS + 1] = { id = id, arg = row.arg, title = row.title, tracker = s[3], tip = s[7] }
    end
  elseif not o.noRow then
    ns.ROWS[#ns.ROWS + 1] = { id = id, title = s[2], tracker = s[3], tip = s[7] }
  end
end

-- The five-second rule's clock: your own spells going off, and your mana falling. No counter is written (no
-- `feeds`), and nothing is done while the Spell tracker is off.
if HC.RegisterSource then
  HC:RegisterSource("hcstats:casts", { mode = "event", events = { "UNIT_SPELLCAST_SUCCEEDED" },
    handler = function(event, ...)
      if HC.IsTrackerOn and not HC:IsTrackerOn(S) then return end
      onCast(event, ...)
    end })
  HC:RegisterSource("hcstats:mana", { mode = "event", events = { "UNIT_POWER_FREQUENT", "PLAYER_ENTERING_WORLD" },
    handler = function(event, ...)
      -- off: forget the last mana seen, or a spend made meanwhile would read as a drop at the next cast
      if HC.IsTrackerOn and not HC:IsTrackerOn(S) then lastMana = nil return end
      onPower(event, ...)
    end })
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
  -- (GetSpellBonusDamage's and GetSpellCritChance's numbers)
  local S_HOLY, S_FIRE, S_NATURE, S_FROST, S_SHADOW, S_ARCANE = 2, 3, 4, 5, 6, 7
  -- (2026-11-25) the five-second rule, a bar on every board of a class that casts
  local function fsr() return tile("fsr", LINE, "bar") end
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
    { tile("spelldmg", BIG), tile("spellcrit"), tile("spellhit"), tile("int"), tile("spellpen"), tile("mp5cast"), tile("mp5"),
      tile("power"), fsr() })
  role("healdirect", "Healer (direct)", "Bonus healing and healing crit: direct heals can crit.",
    { tile("healing", BIG), tile("healcrit"), tile("int"), tile("power"), tile("mp5cast"), tile("mp5"), fsr() })
  role("healhot", "Healer (over time)", "Bonus healing, spirit and regen: heals over time don't crit, long fights reward mana.",
    { tile("healing", BIG), tile("spi"), tile("mp5cast"), tile("mp5"), tile("power"), tile("int"), fsr() })

  -- The nine classes.

  -- (2026-11-25) casters get their schools side by side (a warlock's shadow and fire, a mage's fire, frost and
  -- arcane: damage and crit each), healers their healing crit, and every class that casts the five-second rule.
  class("warrior", "Warrior", "WARRIOR", { tile("ap", BIG), tile("crit"), tile("hit"), bar("mainskill"), tile("armor"),
    tile("dodge"), tile("parry"), bar("defense") })
  class("paladin", "Paladin", "PALADIN", { tile("healing", BIG), tile("healcrit"), school("spelldmg", S_HOLY), tile("int"),
    tile("mp5cast"), tile("ap"), tile("crit"), tile("armor"), tile("blockvalue"), fsr() })
  class("hunter", "Hunter", "HUNTER", { tile("rap", BIG), tile("rcrit"), tile("hit"), tile("rdps"), tile("agi"), tile("mp5"),
    bar("rangedskill") })
  class("rogue", "Rogue", "ROGUE", { tile("ap", BIG), tile("crit"), tile("hit"), tile("agi"), tile("mhdps"), tile("dodge"),
    bar("mainskill"), bar("offskill") })
  class("priest", "Priest", "PRIEST", { tile("healing", BIG), tile("healcrit"), school("spelldmg", S_HOLY),
    school("spelldmg", S_SHADOW), school("spellcrit", S_SHADOW), tile("int"), tile("spi"), tile("mp5cast"), tile("mp5"),
    fsr() })
  class("shaman", "Shaman", "SHAMAN", { tile("healing", BIG), tile("healcrit"), school("spelldmg", S_NATURE),
    school("spellcrit", S_NATURE), school("spelldmg", S_FIRE), tile("int"), tile("mp5cast"), tile("ap"), tile("crit"), fsr() })
  class("mage", "Mage", "MAGE", { tile("spelldmg", BIG), school("spelldmg", S_FIRE), school("spellcrit", S_FIRE),
    school("spelldmg", S_FROST), school("spellcrit", S_FROST), school("spelldmg", S_ARCANE), school("spellcrit", S_ARCANE),
    tile("spellhit"), tile("int"), tile("power"), tile("mp5cast"), fsr() })
  class("warlock", "Warlock", "WARLOCK", { school("spelldmg", S_SHADOW, BIG), school("spellcrit", S_SHADOW),
    school("spelldmg", S_FIRE), school("spellcrit", S_FIRE), tile("spellhit"), tile("spellpen"), tile("sta"), tile("int"),
    tile("health"), tile("hp5combat"), fsr() })
  class("druid", "Druid", "DRUID", { tile("healing", BIG), tile("healcrit"), school("spelldmg", S_NATURE),
    school("spelldmg", S_ARCANE), tile("spellcrit"), tile("ap"), tile("crit"), tile("armor"), tile("dodge"), tile("power"),
    fsr() })

  -- (the user, 2026-11-25) The per-school set: one board per class that has magic-school abilities, a pair of
  -- tiles per school (damage, crit) in the class's own order, then what the game reports once for every school
  -- (spell hit, penetration) where the class casts. Offered beside the class board ("Your class").
  local SCHOOL_NAME = { MAGE = "Mage", WARLOCK = "Warlock", PRIEST = "Priest", PALADIN = "Paladin", SHAMAN = "Shaman",
    DRUID = "Druid", HUNTER = "Hunter", ROGUE = "Rogue" }
  local SCHOOLS_TIP = "Spell damage and spell crit for each magic school your class uses, side by side."
  for _, token in ipairs({ "MAGE", "WARLOCK", "PRIEST", "PALADIN", "SHAMAN", "DRUID", "HUNTER", "ROGUE" }) do
    local tiles = {}
    for _, k in ipairs(CLASS_SCHOOLS[token]) do
      tiles[#tiles + 1] = school("spelldmg", k)
      tiles[#tiles + 1] = school("spellcrit", k)
    end
    if CASTER[token] then
      tiles[#tiles + 1] = tile("spellhit")
      tiles[#tiles + 1] = tile("spellpen")
    end
    HC:RegisterBoardPreset("hcstats:schools." .. token:lower(), { name = SCHOOL_NAME[token] .. ": schools",
      category = "class", class = token, tip = SCHOOLS_TIP, tiles = tiles })
  end
end
