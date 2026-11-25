-- luacheck config for Hard Counters: Character Stats. Game globals are listed per file group; a new one can't slip in.
std = "lua51"
max_line_length = 160
codes = true
ignore = {
  "212/self",
  "211/_.*",
  "212/_.*",
  "21[12]/ADDON",
}
exclude_files = { "dist/**", ".luarocks/**" }

files["HardCounters_CharacterStats/Stats.lua"] = {
  read_globals = { "HardCounters", "UnitStat", "UnitHealthMax", "UnitPowerMax", "UnitAttackPower",
    "UnitRangedAttackPower", "GetCritChance", "GetHitModifier", "GetRangedCritChance", "GetSpellBonusDamage",
    "GetSpellBonusHealing", "GetSpellCritChance", "GetSpellHitModifier", "GetManaRegen", "GetTime", "C_Spell",
    "GetSpellPowerCost", "C_Timer", "GetMeleeHaste", "UnitSpellHaste", "GetHealthRegen", "GetManaRegenFromSpirit", "UnitArmor",
    "GetDodgeChance", "GetParryChance", "GetBlockChance", "GetShieldBlock", "UnitClass", "GetInventoryItemID",
    "GetInventorySlotInfo", "C_SkillInfo", "C_Item", "GetItemInfoInstant",
    -- (2026-11-24) weapon damage and speed, penetration, resistances, gear
    "UnitDamage", "UnitAttackSpeed", "UnitRangedDamage", "GetSpellPenetration", "UnitResistance",
    "GetInventoryItemDurability", "GetAverageItemLevel" },
}
files["HardCounters_CharacterStats/UI/**"] = {
  read_globals = { "HardCounters", "CreateFrame", "GameTooltip" },   -- Hard Counters hosts the window
}

files["tests/**"] = { std = "+busted", ignore = { "311" }, globals = { "_G" } }
