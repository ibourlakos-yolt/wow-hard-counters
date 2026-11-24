-- Farmer (DESIGN §4): the Ledger, Loot and Reputation, plus the money and XP *sources* for Hard Counters' Basics
-- (gold and XP per hour moved there, v2 M4, 2026-11-15). Built ONLY on Hard Counters' public API
-- (docs/API.md at the repo root); if something here needs more, the API gets fixed instead.
local ADDON, ns = ...

local HC = HardCounters
if not HC or (HC.API_VERSION or 0) < 1 or not HC.SetAttributor then return end

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
local GetTime = GetTime
local tonumber, type, pairs = tonumber, type, pairs

ns.VERSION = "0.2.2-beta2"
local pack = HC:RegisterPack("Farmer", { namespace = "hcfarm", version = ns.VERSION, title = "Farmer" })
ns.pack = pack

-- Money and XP are Hard Counters' Basics counters now; Farmer names their sources (attributors, below). The old
-- hcfarm:money.* and hcfarm:xp data is left on disk, unregistered: the Trackers window lists it under "Not loaded"
-- with a Delete button (only the developer's test data had it).
ns.ID = {
  moneyIn = "hc:money.in", moneyOut = "hc:money.out", owned = "hc:money.owned", xp = "hc:xp",
  items = "hcfarm:loot.items", vendor = "hcfarm:loot.vendorvalue", rep = "hcfarm:rep",
}
local ID = ns.ID

local function zone() return { name = "zone", cap = 64 } end
local CHAT = { status = "unverified", note = "chat messages inside instances are unverified (FM-5)", ref = "api-surface.md#economy-and-progression" }

---------------------------------------------------------------------------
-- Counters (DESIGN §4.3). Grains follow the trackers' history (Hard Counters HC-19). All run-tracked.
---------------------------------------------------------------------------

HC:RegisterCounter({ id = ID.items, version = 1, kind = "flow", unit = "items", measures = { "sum", "count" },
  dimensions = { { name = "item", cap = 4096 }, { name = "quality", cap = 8 }, { name = "category", cap = 32 }, zone() },
  aggregations = { {}, { "item" }, { "quality" }, { "category" }, { "zone" }, { "category", "zone" } },
  title = "Looted items", category = "Loot", formatter = "number", accuracy = "exact",
  capture = { mode = "push-delta", source = "CHAT_MSG_LOOT (own loot)" }, feasibility = CHAT,
  runBreakdowns = { "quality", "category" }, runLive = { member = "item", cap = 500 } })

HC:RegisterCounter({ id = ID.vendor, version = 1, kind = "flow", unit = "copper", measures = { "sum", "max" },
  dimensions = { { name = "category", cap = 32 }, zone() }, aggregations = { {}, { "category" }, { "zone" } },
  context = { max = { "zone", "item", "qty" } }, title = "Looted items, vendor value", category = "Loot",
  formatter = "money", accuracy = "exact", capture = { mode = "push-delta", source = "quantity x vendor price at loot time" },
  feasibility = CHAT, runBreakdowns = { "category" }, runLive = { max = true } })

HC:RegisterCounter({ id = ID.rep, version = 1, kind = "flow", unit = "reputation", measures = { "sum", "count" },
  dimensions = { { name = "faction", cap = 64 }, zone() }, aggregations = { {}, { "faction" } },
  title = "Reputation gained", category = "Progression", formatter = "number", accuracy = "exact",
  capture = { mode = "push-delta", source = "CHAT_MSG_COMBAT_FACTION_CHANGE (increases)" }, feasibility = CHAT,
  runBreakdowns = { "faction" } })

---------------------------------------------------------------------------
-- Trackers (Hard Counters HC-19): what the player switches on. A pack's trackers start off (the user's decision,
-- TRACKERS_AND_BOARDS §0.3); nothing below counts, listens or polls until one is on. The Ledger reads Basics' money
-- counters and needs daily history: switching it on turns that on for them.
---------------------------------------------------------------------------

HC:RegisterTracker("hcfarm:ledger", { title = "Ledger", category = "Farming", icon = 133785,
  counters = { ID.moneyIn, ID.moneyOut, ID.owned }, default = "off", needsHistory = "daily",
  description = "Income by source and spending by sink, for today, this week, month, year or lifetime." })
HC:RegisterTracker("hcfarm:loot", { title = "Loot", category = "Farming", icon = 133639,
  counters = { ID.items, ID.vendor }, default = "off",
  description = "Items looted, their vendor value and your best drop." })
HC:RegisterTracker("hcfarm:rep", { title = "Reputation", category = "Farming", icon = 236681,
  counters = { ID.rep }, default = "off", description = "Reputation gained, by faction." })

---------------------------------------------------------------------------
-- Patterns from the client's strings
---------------------------------------------------------------------------

local G = _G
ns.pat = ns.Parse.build({
  LOOT_ITEM_SELF = G.LOOT_ITEM_SELF, LOOT_ITEM_SELF_MULTIPLE = G.LOOT_ITEM_SELF_MULTIPLE,
  YOU_LOOT_MONEY = G.YOU_LOOT_MONEY, LOOT_MONEY_SPLIT = G.LOOT_MONEY_SPLIT,
  GOLD_AMOUNT = G.GOLD_AMOUNT, SILVER_AMOUNT = G.SILVER_AMOUNT, COPPER_AMOUNT = G.COPPER_AMOUNT,
  COMBATLOG_XPGAIN_FIRSTPERSON = G.COMBATLOG_XPGAIN_FIRSTPERSON,
  COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED = G.COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED,
  FACTION_STANDING_INCREASED = G.FACTION_STANDING_INCREASED,
}, function(s) return HC:ChatPattern(s) end)
local pat, Parse = ns.pat, ns.Parse

---------------------------------------------------------------------------
-- Money and XP sources (DESIGN §4.1): attributors for Hard Counters' Basics. Basics diffs GetMoney and UnitXP and
-- hands each change over as fn(amount, t, book); the attributors below (Attribution.lua, unchanged) decide the
-- source, now or within their 2 s window, and book it. Basics books whatever is left after 5 s as "none".
---------------------------------------------------------------------------

local bookIn, bookOut, bookXP
local money = ns.NewMoneyAttributor(function(dir, amount, source)
  local book = dir == "in" and bookIn or bookOut
  if book then book(amount, source) end
end)
ns.money = money

local xp = ns.NewXPAttributor(function(amount, source) if bookXP then bookXP(amount, source) end end)
ns.xp = xp

local expiring = false
local function expireTick()
  expiring = false
  local t = GetTime()
  local waitMoney = money:Expire(t)
  local waitXP = xp:Expire(t)
  if money.unmatchedLoot > 0 then pack:Count("lootMoneyUnmatched", money.unmatchedLoot); money.unmatchedLoot = 0 end
  if waitMoney or waitXP then ns.ScheduleExpire() end
end
function ns.ScheduleExpire()
  if expiring then return end
  expiring = true
  C_Timer.After(ns.ATTR_WINDOW + 0.25, expireTick)
end

HC:SetAttributor(ID.moneyIn, function(amount, t, book)
  bookIn = book
  money:Delta(amount, t)
  ns.ScheduleExpire()
end)
HC:SetAttributor(ID.moneyOut, function(amount, t, book)
  bookOut = book
  money:Delta(-amount, t)
end)
HC:SetAttributor(ID.xp, function(amount, t, book)
  bookXP = book
  xp:Delta(amount, t)
  ns.ScheduleExpire()
end)

local WINDOWS = {
  MERCHANT_SHOW = { "merchant", true }, MERCHANT_CLOSED = { "merchant", false },
  MAIL_SHOW = { "mail", true }, MAIL_CLOSED = { "mail", false },
  AUCTION_HOUSE_SHOW = { "ah", true }, AUCTION_HOUSE_CLOSED = { "ah", false },
  TRAINER_SHOW = { "trainer", true }, TRAINER_CLOSED = { "trainer", false },
  TAXIMAP_OPENED = { "taxi", true }, TAXIMAP_CLOSED = { "taxi", false },
  TRADE_SHOW = { "trade", true }, TRADE_CLOSED = { "trade", false },
}
-- In game (2026-11-14) MAIL_CLOSED, TRAINER_CLOSED and TAXIMAP_CLOSED never fired while their _SHOW events did, so
-- those windows stayed "open" and later loot money was booked as mail. The client reports NPC windows through the
-- interaction manager (type in arg 1); those events are the main signal, the old ones a fallback, and a loading
-- screen closes everything.
local PIT = Enum and Enum.PlayerInteractionType
local INTERACTION = {}
if PIT then
  local names = { Merchant = "merchant", MailInfo = "mail", Auctioneer = "ah", Trainer = "trainer",
    TaxiNode = "taxi", TradePartner = "trade" }
  for enumName, kind in pairs(names) do
    if PIT[enumName] ~= nil then INTERACTION[PIT[enumName]] = kind end
  end
end
ns.INTERACTION = INTERACTION

-- The signals that name a money change's source. They matter only while Basics counts money or XP.
local HINTS = { ID.moneyIn, ID.moneyOut, ID.xp }
local hintEvents = { "CHAT_MSG_MONEY", "PLAYER_ENTERING_WORLD", "QUEST_TURNED_IN",
  "PLAYER_INTERACTION_MANAGER_FRAME_SHOW", "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" }
for ev in pairs(WINDOWS) do hintEvents[#hintEvents + 1] = ev end

HC:RegisterSource("hcfarm:money", { mode = "event", events = hintEvents, feeds = HINTS, handler = function(event, a1, a2, a3)
  local w = WINDOWS[event]
  if w then money:SetOpen(w[1], w[2]); return end
  if event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" or event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
    if not HC:Readable(a1) then return end
    local kind = INTERACTION[a1]
    if kind then money:SetOpen(kind, event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW") end
    return
  end
  if event == "CHAT_MSG_MONEY" then
    if not HC:Readable(a1) then return end
    local copper = Parse.money(pat, a1)
    if copper then
      money:LootMessage(copper, GetTime())
      ns.ScheduleExpire()
    else
      pack:Count("moneyLineUnparsed")
    end
  elseif event == "QUEST_TURNED_IN" then
    local xpReward, moneyReward = a2, a3
    local t = GetTime()
    if HC:Readable(moneyReward) and type(moneyReward) == "number" and moneyReward > 0 then money:Mark("quest", t) end
    if HC:Readable(xpReward) and type(xpReward) == "number" and xpReward > 0 then xp:Hint("quest", t) end
  elseif event == "PLAYER_ENTERING_WORLD" then
    money:CloseAll()                                        -- a loading screen closes every window
  end
end })

-- Signals that money is about to move for a known reason (post-hooks: they run after the call, before the
-- server's PLAYER_MONEY arrives).
local MONEY = { ID.moneyIn, ID.moneyOut }
HC:RegisterSource("hcfarm:repair", { mode = "hook", hook = "RepairAllItems", feeds = MONEY, handler = function(guildBank)
  if not guildBank then money:Mark("repair", GetTime()) end
end })
--- Is `name` (a sender or a recipient, "Name" or "Name-Realm") one of your own characters? (FM-16; the name is
--- compared, never kept.)
local function ownName(name)
  return type(name) == "string" and HC:Readable(name) and HC.IsOwnCharacter ~= nil and HC:IsOwnCharacter(name)
end
ns.OwnName = ownName

local function mailTake(index)
  local invoiceType = GetInboxInvoiceInfo and GetInboxInvoiceInfo(index)
  local source = invoiceType == "seller" and "ah" or "mail"
  if source == "mail" and GetInboxHeaderInfo then
    local _, _, sender = GetInboxHeaderInfo(index)
    if ownName(sender) then source = "alts" end
  end
  money:Mark("mailTake", GetTime(), source)
end
HC:RegisterSource("hcfarm:mailmoney", { mode = "hook", hook = "TakeInboxMoney", feeds = MONEY, handler = mailTake })
HC:RegisterSource("hcfarm:mailloot", { mode = "hook", hook = "AutoLootMailItem", feeds = MONEY, handler = mailTake })
-- Money sent: a post-hook runs before the server takes the money, while the send form still holds the amount.
HC:RegisterSource("hcfarm:mailsend", { mode = "hook", hook = "SendMail", feeds = MONEY, handler = function(recipient)
  local own = 0
  if ownName(recipient) and GetSendMailMoney then
    local m = GetSendMailMoney()
    if HC:Readable(m) and type(m) == "number" then own = m end
  end
  money:Mark("mailSend", GetTime(), own)
end })
-- Account-wide values leave money between your own characters out: it moved, nobody earned or spent it (FM-16)
if HC.ExcludeOnAccount then
  HC:ExcludeOnAccount(ID.moneyIn, "source", "alts")
  HC:ExcludeOnAccount(ID.moneyOut, "sink", "alts")
end

---------------------------------------------------------------------------
-- Loot (DESIGN §4.3, §4.6): every item keyed by numeric item ID; attributes looked up, not stored per item
---------------------------------------------------------------------------

ns.categoryOverrides = {}       -- versioned content data (FM-6) goes here: [itemID] = category
local ctxItem = {}               -- reused context for the vendor-value record
local pendingItems, pendingCount = {}, 0
local PENDING_CAP = 200

local function emitItem(id, n, quality, classID, subclassID, sellPrice, z)
  local cat = Parse.category(classID, subclassID, quality, ns.categoryOverrides, id)
  HC:Emit(ID.items, n, id, quality, cat, z)
  if type(sellPrice) == "number" and sellPrice > 0 then
    ctxItem.item, ctxItem.qty = id, n
    HC:EmitCtx(ID.vendor, n * sellPrice, ctxItem, cat, z)
  end
end

local function lootItem(id, n, z)
  local _, _, _, _, _, classID, subclassID = GetItemInfoInstant(id)
  local _, _, quality, _, _, _, _, _, _, _, sellPrice = GetItemInfo(id)
  if quality == nil then
    -- not cached yet: wait for GET_ITEM_INFO_RECEIVED (bounded)
    local p = pendingItems[id]
    if p then p.n = p.n + n; return end
    if pendingCount >= PENDING_CAP then pack:Count("itemInfoDropped"); return end
    pendingItems[id] = { n = n, zone = z }
    pendingCount = pendingCount + 1
    pack:Count("itemInfoWaits")
    return
  end
  emitItem(id, n, quality, classID, subclassID, sellPrice, z)
end

HC:RegisterSource("hcfarm:loot", { mode = "event", events = { "CHAT_MSG_LOOT", "GET_ITEM_INFO_RECEIVED" },
  feeds = { ID.items, ID.vendor }, handler = function(event, a1, a2)
  if event == "CHAT_MSG_LOOT" then
    if not HC:Readable(a1) then return end
    local id, n = Parse.loot(pat, a1)
    if id then lootItem(id, n, HC:ZoneKey()) end
  else
    local id = tonumber(a1)
    local p = id and pendingItems[id]
    if not p then return end
    pendingItems[id] = nil
    pendingCount = pendingCount - 1
    if a2 == false then pack:Count("itemInfoFailed"); return end
    local _, _, _, _, _, classID, subclassID = GetItemInfoInstant(id)
    local _, _, quality, _, _, _, _, _, _, _, sellPrice = GetItemInfo(id)
    emitItem(id, p.n, quality or 1, classID, subclassID, sellPrice, p.zone)
  end
end })

---------------------------------------------------------------------------
-- XP: Basics diffs UnitXP; a kill line or QUEST_TURNED_IN (above) names the source
---------------------------------------------------------------------------

HC:RegisterSource("hcfarm:xp", { mode = "event", events = { "CHAT_MSG_COMBAT_XP_GAIN" }, feeds = { ID.xp },
  handler = function(_, msg)
    if not HC:Readable(msg) then return end
    local n, kind = Parse.xp(pat, msg)
    if n then xp:Hint(kind, GetTime()) end
  end })

---------------------------------------------------------------------------
-- Reputation (increases; faction keyed by ID where the client can tell us, else by name)
---------------------------------------------------------------------------

local factionIds = {}
local function factionKey(name)
  local id = factionIds[name]
  if id then return id end
  if C_Reputation and C_Reputation.GetNumFactions and C_Reputation.GetFactionDataByIndex then
    for i = 1, C_Reputation.GetNumFactions() do
      local d = C_Reputation.GetFactionDataByIndex(i)
      if d and d.name and d.factionID and d.factionID > 0 then factionIds[d.name] = d.factionID end
    end
  end
  return factionIds[name] or name
end

HC:RegisterSource("hcfarm:rep", { mode = "event", events = { "CHAT_MSG_COMBAT_FACTION_CHANGE" }, feeds = { ID.rep }, handler = function(_, msg)
  if not HC:Readable(msg) then return end
  local name, n = Parse.rep(pat, msg)
  if name and n and n > 0 then HC:Emit(ID.rep, n, factionKey(name), HC:ZoneKey()) end
end })

---------------------------------------------------------------------------
-- Readings with a parameter (FM-15, Hard Counters DESIGN 16.4): one faction, one item, picked on the tile.
---------------------------------------------------------------------------

local function factionLabel(key)
  if type(key) ~= "number" then return tostring(key) end
  for name, id in pairs(factionIds) do if id == key then return name end end
  if C_Reputation and C_Reputation.GetFactionDataByID then
    local ok, d = pcall(C_Reputation.GetFactionDataByID, key)
    if ok and type(d) == "table" and HC:Readable(d.name) and type(d.name) == "string" then
      factionIds[d.name] = key
      return d.name
    end
  end
  return "Faction " .. key
end

local function itemLabel(key)
  if type(key) ~= "number" then return tostring(key) end
  local name = GetItemInfo and GetItemInfo(key)      -- nil until the client has the item's data
  if type(name) == "string" and name ~= "" then return name end
  return "Item " .. key
end

--- Progress inside the current standing with a faction: reputation into it, and its size (nil when the client
--- can't say: the faction API on Forever is unverified, so everything is guarded).
local function standing(key)
  if type(key) ~= "number" or not (C_Reputation and C_Reputation.GetFactionDataByID) then return nil end
  local ok, d = pcall(C_Reputation.GetFactionDataByID, key)
  if not ok or type(d) ~= "table" then return nil end
  local cur, lo, hi = d.currentStanding, d.currentReactionThreshold, d.nextReactionThreshold
  if not HC:Readable(cur, lo, hi) then return nil end
  if type(cur) ~= "number" or type(lo) ~= "number" or type(hi) ~= "number" or hi <= lo then return nil end
  return cur - lo, hi - lo
end

local PERIODS = { "run", "session", "today", "week", "month", "year", "lifetime" }
-- One reading per thing counted (Hard Counters DESIGN §16.9, FM-17): per hour, recent and trend are the tile's calc.
-- One faction, one item: folded into Reputation gained and Items looted (2026-11-24), where the faction or the item
-- is the tile's choice. Their tiles move there; HC:Reading("hcfarm:repwith", scope, id) keeps answering.
HC:RegisterReading("hcfarm:repwith", { title = "%s rep", rateTitle = "%s rep/h", tracker = "hcfarm:rep", counter = ID.rep,
  param = { dim = "faction", type = "faction", label = factionLabel }, scopes = PERIODS, formatter = "number", order = 29,
  foldInto = "hcfarm:rep", foldArg = "same", description = "Reputation gained with one faction." })
HC:RegisterReading("hcfarm:looted", { title = "%s looted", tracker = "hcfarm:loot", counter = ID.items,
  param = { dim = "item", type = "item", label = itemLabel }, scopes = PERIODS, formatter = "number", order = 30,
  foldInto = "hcfarm:items", foldArg = "same", description = "How many of one item you looted." })
-- How many of one item are in the bags right now (Hard Counters HC-34): no counter behind it, the game is asked
-- (C_Item.GetItemCount answers on Forever: probed 2026-11-18). With a target on the tile it is "143 / 200" as a
-- bar. `counter` only supplies the picker's list of items looted last.
local function inBags(key)
  local count = (C_Item and C_Item.GetItemCount) or GetItemCount
  if type(key) ~= "number" or not count then return nil end
  local ok, n = pcall(count, key)
  if not ok or not HC:Readable(n) or type(n) ~= "number" then return nil end
  return n
end
HC:RegisterReading("hcfarm:inbags", { title = "In bags: %s", pickTitle = "In bags: pick an item", tracker = "hcfarm:loot", counter = ID.items,
  param = { dim = "item", type = "item", label = itemLabel }, scopes = { "now" }, formatter = "number", order = 30.5,
  refresh = { "BAG_UPDATE" },
  description = "How many of one item you carry right now (bags only, not the bank). Set a target on the tile and show it as a bar for a goal.",
  compute = function(_, _, arg) return inBags(arg) end })
-- A bar toward the next standing (Hard Counters HC-33). `counter` only supplies the list of factions seen.
-- (2026-11-24) "Standing progress", not "standing": it is the rep inside your current standing, not the standing
HC:RegisterReading("hcfarm:standing", { title = "Standing progress: %s", pickTitle = "Standing progress: pick a faction",
  tracker = "hcfarm:rep", counter = ID.rep,
  param = { dim = "faction", type = "faction", label = factionLabel }, scopes = { "now" }, formatter = "number",
  order = 31, refresh = { "UPDATE_FACTION" },
  description = "Reputation inside your current standing with one faction; as a bar it fills toward the next standing.",
  compute = function(_, _, arg) return (standing(arg)) end,
  target = function(arg)
    local _, size = standing(arg)
    return size
  end })

---------------------------------------------------------------------------
-- Readings (the farm stopwatch's numbers, DESIGN §4.2; Hard Counters' reading API, HC-17) and Ledger views (§4.1).
-- Gold/h, Net gold/h, Gold in and XP/h are Basics' (hc:goldph ...), with Farmer's sources.
---------------------------------------------------------------------------

local ALL = { "run", "session", "today", "week", "month", "year", "lifetime" }
-- (2026-11-24) "Loot vendor value": "Vendor value" read like gold from vendors
HC:RegisterReading("hcfarm:vendor", { title = "Loot vendor value", rateTitle = "Loot vendor value/h", tracker = "hcfarm:loot",
  counter = ID.vendor, scopes = ALL, formatter = "money", order = 25,
  description = "What the items you looted would sell for at a vendor." })
-- the per-hour twin before FM-17: a hidden alias, so its tiles and HC:Reading("hcfarm:vendorph", ...) keep their value
HC:RegisterReading("hcfarm:vendorph", { aliasOf = "hcfarm:vendor", calc = "perHour", order = 14,
  description = "What the items you looted would sell for at a vendor, per active hour." })
-- (2026-11-24) the item and the faction are the tile's choice, none for every one together (the merges above)
HC:RegisterReading("hcfarm:items", { title = "Items looted", rateTitle = "Items/h", tracker = "hcfarm:loot", counter = ID.items,
  param = { dim = "item", type = "item", label = itemLabel, optional = true, anyLabel = "Any item" },
  scopes = ALL, formatter = "number", order = 26,
  description = "Items you looted (each one counted, stacks by size); pick one item on the tile, or count them all."
    .. " One item counts from when its tile is placed; with history, the periods count everything stored." })
HC:RegisterReading("hcfarm:best", { title = "Best drop (vendor price)", tracker = "hcfarm:loot", counter = ID.vendor, best = true,
  scopes = { "run" }, formatter = "money", order = 27, description = "The run's most valuable single drop, by vendor price." })
HC:RegisterReading("hcfarm:rep", { title = "Reputation gained", rateTitle = "Rep/h", tracker = "hcfarm:rep", counter = ID.rep,
  param = { dim = "faction", type = "faction", label = factionLabel, optional = true, anyLabel = "Any faction" },
  scopes = ALL, formatter = "number", order = 28,
  description = "Reputation gained: with every faction together, or one picked on the tile." })

HC:RegisterView("hcfarm:ledger.in", { counter = ID.moneyIn, groupBy = "source", grain = "day", title = "Income by source" })
HC:RegisterView("hcfarm:ledger.out", { counter = ID.moneyOut, groupBy = "sink", grain = "day", title = "Spending by sink" })
HC:RegisterView("hcfarm:goldph.today", { counter = ID.moneyIn, per = "activeHour", grain = "day", title = "Gold per hour today",
  formatter = "money", feed = true })
HC:RegisterView("hcfarm:gold.today", { counter = ID.moneyIn, grain = "day", title = "Gold in today", formatter = "money" })
HC:RegisterView("hcfarm:items.bycat", { counter = ID.items, groupBy = "category", grain = "day", title = "Items by category" })
