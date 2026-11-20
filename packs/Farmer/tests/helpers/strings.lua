-- Client format strings for tests: enUS (as shipped) and a synthetic second locale to prove nothing is English-only.
local S = {}

S.enUS = {
  LOOT_ITEM_SELF = "You receive loot: %s.",
  LOOT_ITEM_SELF_MULTIPLE = "You receive loot: %sx%d.",
  YOU_LOOT_MONEY = "You loot %s",
  LOOT_MONEY_SPLIT = "Your share of the loot is %s.",
  GOLD_AMOUNT = "%d Gold", SILVER_AMOUNT = "%d Silver", COPPER_AMOUNT = "%d Copper",
  COMBATLOG_XPGAIN_FIRSTPERSON = "%s dies, you gain %d experience.",
  COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED = "You gain %d experience.",
  FACTION_STANDING_INCREASED = "Your %s reputation has increased by %d.",
}

S.xxXX = {
  LOOT_ITEM_SELF = "Beute erhalten: %s.",
  LOOT_ITEM_SELF_MULTIPLE = "Beute erhalten: %sx%d.",
  YOU_LOOT_MONEY = "Ihr erbeutet %s",
  LOOT_MONEY_SPLIT = "Euer Anteil: %s.",
  GOLD_AMOUNT = "%d Gold", SILVER_AMOUNT = "%d Silber", COPPER_AMOUNT = "%d Kupfer",
  COMBATLOG_XPGAIN_FIRSTPERSON = "%s stirbt, Ihr bekommt %d Erfahrung.",
  COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED = "Ihr bekommt %d Erfahrung.",
  FACTION_STANDING_INCREASED = "Euer Ruf bei der Fraktion '%s' hat sich um %d verbessert.",
}

function S.link(id, name, color)
  return ("|cff%s|Hitem:%d::::::::60:::::::::|h[%s]|h|r"):format(color or "ffffff", id, name or "Item")
end

--- Hard Counters' pattern maker (the same function HardCounters:ChatPattern uses).
function S.patternFrom()
  local ns = {}
  assert(loadfile("../../HardCounters/Core/Util.lua"))("HardCounters", ns)
  return ns.U.patternFrom
end

return S
