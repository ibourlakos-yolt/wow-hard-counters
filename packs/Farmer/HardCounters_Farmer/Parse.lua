-- Parse: chat parsers built from the client's own strings (FM-4; DESIGN §5 rule 1: no English literals), and the
-- item category classifier. Pure: everything comes in as arguments, so busted can test it with any locale's strings.
local ADDON, ns = ...

local P = {}
ns.Parse = P

local tonumber, type = tonumber, type

local function unanchorEnd(p) return p and (p:gsub("%$$", "")) end
local function unanchor(p) return p and (p:gsub("^%^", ""):gsub("%$$", "")) end

--- Build every pattern from a table of global strings (G) and Hard Counters' pattern maker.
function P.build(G, patternFrom)
  local t = {}
  t.lootMulti = patternFrom(G.LOOT_ITEM_SELF_MULTIPLE)
  t.loot = patternFrom(G.LOOT_ITEM_SELF)
  t.moneyLoot = patternFrom(G.YOU_LOOT_MONEY)
  t.moneySplit = patternFrom(G.LOOT_MONEY_SPLIT)
  t.gold = unanchor(patternFrom(G.GOLD_AMOUNT))
  t.silver = unanchor(patternFrom(G.SILVER_AMOUNT))
  t.copper = unanchor(patternFrom(G.COPPER_AMOUNT))
  -- XP lines may carry a rested-bonus suffix after the sentence: match the start only
  t.xpKill = unanchorEnd(patternFrom(G.COMBATLOG_XPGAIN_FIRSTPERSON))
  t.xpUnnamed = unanchorEnd(patternFrom(G.COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED))
  t.repUp = unanchorEnd(patternFrom(G.FACTION_STANDING_INCREASED))
  return t
end

--- Own loot: "You receive loot: [item]x3." -> itemID, quantity. nil for anything else (others' loot, pushes).
function P.loot(t, msg)
  if type(msg) ~= "string" then return nil end
  local link, n
  if t.lootMulti then link, n = msg:match(t.lootMulti) end
  if not link and t.loot then link = msg:match(t.loot); n = 1 end
  if not link then return nil end
  local id = tonumber(link:match("item:(%d+)"))
  if not id then return nil end
  return id, tonumber(n) or 1
end

--- "1 Gold, 2 Silver, 3 Copper" (in the client's language) -> copper.
function P.moneyText(t, text)
  if type(text) ~= "string" then return nil end
  local g = t.gold and tonumber(text:match(t.gold)) or 0
  local s = t.silver and tonumber(text:match(t.silver)) or 0
  local c = t.copper and tonumber(text:match(t.copper)) or 0
  local total = g * 10000 + s * 100 + c
  if total == 0 then return nil end
  return total
end

--- CHAT_MSG_MONEY: "You loot 5 Silver" or "Your share of the loot is 5 Silver." -> copper.
function P.money(t, msg)
  if type(msg) ~= "string" then return nil end
  local text = (t.moneyLoot and msg:match(t.moneyLoot)) or (t.moneySplit and msg:match(t.moneySplit))
  if not text then return nil end
  return P.moneyText(t, text)
end

--- CHAT_MSG_COMBAT_XP_GAIN -> amount, "kill" | "other".
function P.xp(t, msg)
  if type(msg) ~= "string" then return nil end
  if t.xpKill then
    local _, n = msg:match(t.xpKill)
    if n then return tonumber(n), "kill" end
  end
  if t.xpUnnamed then
    local n = msg:match(t.xpUnnamed)
    if n then return tonumber(n), "other" end
  end
  return nil
end

--- CHAT_MSG_COMBAT_FACTION_CHANGE (increases only) -> faction name, amount.
function P.rep(t, msg)
  if type(msg) ~= "string" or not t.repUp then return nil end
  local name, n = msg:match(t.repUp)
  if not name then return nil end
  return name, tonumber(n)
end

---------------------------------------------------------------------------
-- Item category (DESIGN §4.6 "farm category"): a small, stable key from the AH taxonomy.
-- Class and subclass numbers are the retail Enum.ItemClass / Enum.ItemTradeGoodsSubclass values, which the
-- Classic-era numbering shares for everything used here. Stored as a dimension: never renumber.
---------------------------------------------------------------------------

local TRADE = {
  [1] = "parts", [4] = "gem", [5] = "cloth", [6] = "leather", [7] = "metal", [8] = "cooking", [9] = "herb",
  [10] = "elemental", [12] = "enchanting", [16] = "inscription",
}
local CLASS = {
  [0] = "consumable", [1] = "container", [2] = "gear", [3] = "gem", [4] = "gear", [5] = "reagent", [9] = "recipe",
  [12] = "quest", [13] = "key",
}

--- (classID, subclassID, quality, overrides[itemID], itemID) -> category key.
function P.category(classID, subclassID, quality, overrides, itemID)
  if overrides and itemID and overrides[itemID] then return overrides[itemID] end
  if quality == 0 then return "junk" end
  if classID == 7 then return TRADE[subclassID] or "tradegoods" end
  if classID == 15 then return subclassID == 0 and "junk" or "misc" end
  return CLASS[classID] or "other"
end

P.CATEGORIES = { "junk", "parts", "gem", "cloth", "leather", "metal", "cooking", "herb", "elemental", "enchanting",
  "inscription", "tradegoods", "consumable", "container", "gear", "reagent", "recipe", "quest", "key", "misc", "other" }
