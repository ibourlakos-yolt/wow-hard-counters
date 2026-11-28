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

ns.VERSION = "0.5.0-beta2"
local pack = HC:RegisterPack("Farmer", { namespace = "hcfarm", version = ns.VERSION, title = "Farmer" })
ns.pack = pack

-- Money and XP are Hard Counters' Basics counters now; Farmer names their sources (attributors, below). The old
-- hcfarm:money.* and hcfarm:xp data is left on disk, unregistered: the Trackers window lists it under "Not loaded"
-- with a Delete button (only the developer's test data had it).
ns.ID = {
  moneyIn = "hc:money.in", moneyOut = "hc:money.out", owned = "hc:money.owned", xp = "hc:xp",
  items = "hcfarm:loot.items", vendor = "hcfarm:loot.vendorvalue", rep = "hcfarm:rep",
  fish = "hcfarm:fish.caught",
  casts = "hcfarm:fish.casts", missed = "hcfarm:fish.missed", wait = "hcfarm:fish.wait",
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

-- (2026-11-25) The Fishing basket: what you fished up, by item. `fish` is a small dimension (cap 200, every member
-- kept per character), so a board's timer can split it per catch (the mix) and "Fish in bags" knows every catch.
HC:RegisterCounter({ id = ID.fish, version = 1, kind = "flow", unit = "items", measures = { "sum", "count" },
  dimensions = { { name = "fish", cap = 200 }, zone() },
  aggregations = { {}, { "fish" }, { "zone" }, { "fish", "zone" } },
  title = "Fished items", category = "Loot", formatter = "number", accuracy = "exact",
  capture = { mode = "push-delta", source = "CHAT_MSG_LOOT while a fishing bobber's loot is open" }, feasibility = CHAT,
  runBreakdowns = { "fish" } })
-- (2026-11-25, 0.3.0-beta3) Every Fishing cast, the ones that got away (no bobber loot after the channel), and the
-- seconds each catch took from the cast to the click: a separate counter for the misses, so the catch rate is two
-- plain totals; the wait keeps its best (runLive max) for "Longest wait" on a board's timer.
local FISHING_CAPTURE = { mode = "push-delta", source = "your Fishing channel (UNIT_SPELLCAST_CHANNEL_START/STOP) and the bobber's loot" }
HC:RegisterCounter({ id = ID.casts, version = 1, kind = "flow", unit = "casts", measures = { "sum", "count" },
  dimensions = { zone() }, aggregations = { {}, { "zone" } }, title = "Fishing casts", category = "Loot",
  formatter = "number", accuracy = "exact", capture = FISHING_CAPTURE, feasibility = CHAT })
HC:RegisterCounter({ id = ID.missed, version = 1, kind = "flow", unit = "casts", measures = { "sum", "count" },
  dimensions = { zone() }, aggregations = { {}, { "zone" } }, title = "Fishing casts that got away", category = "Loot",
  formatter = "number", accuracy = "exact", capture = FISHING_CAPTURE, feasibility = CHAT })
HC:RegisterCounter({ id = ID.wait, version = 1, kind = "flow", unit = "seconds", measures = { "sum", "count", "max" },
  dimensions = { zone() }, aggregations = { {}, { "zone" } }, title = "Wait for a bite", category = "Loot",
  formatter = "seconds", accuracy = "exact", capture = FISHING_CAPTURE, feasibility = CHAT, runLive = { max = true } })

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
HC:RegisterTracker("hcfarm:fishing", { title = "Fishing", category = "Farming", icon = 136245,
  counters = { ID.fish, ID.casts, ID.missed, ID.wait }, default = "off",
  description = "What you fish up, item by item (fish, junk, clams, chests): your catch, its mix and the fish in your bags;"
    .. " your casts, the ones that got away and how long each bite took." })
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
-- Fishing (2026-11-25, the Fishing basket). A catch is your own loot line (CHAT_MSG_LOOT, as above) while the loot
-- window of a fishing bobber is open, or within FISH_GRACE seconds of it closing (with auto loot the lines can
-- come just after the window shuts). The game says which loot is a bobber's: IsFishingLoot() at LOOT_READY /
-- LOOT_OPENED. Where the client has no IsFishingLoot, the loot counts as fishing if it opens while your Fishing
-- channel runs or within FISH_GRACE seconds of it ending (the channel ends as you click the bobber). Fishing is
-- told by spell id (Classic ranks and the later single spell) or by the spell's name, so a rank we don't list
-- still counts. Items from opening a fished clam or chest are not catches (that loot is no bobber's).
---------------------------------------------------------------------------

local FISH_GRACE = 2
ns.FISHING_SPELLS = { [7620] = true, [7731] = true, [7732] = true, [18248] = true, [33095] = true, [51294] = true,
  [88868] = true, [131474] = true }
local fishOpen, fishClosedAt = false, nil      -- a bobber's loot window: open now, or when it closed
local channelOn, channelEndAt = false, nil     -- your Fishing channel (only used without IsFishingLoot)
local fishingName

local function spellName(id)
  local ok, name
  if C_Spell and C_Spell.GetSpellName then ok, name = pcall(C_Spell.GetSpellName, id)
  elseif GetSpellInfo then ok, name = pcall(GetSpellInfo, id) end
  if ok and type(name) == "string" and not HC:IsSecret(name) then return name end
  return nil
end

local function isFishingSpell(id)
  if id == nil or HC:IsSecret(id) then return false end
  if ns.FISHING_SPELLS[id] then return true end
  fishingName = fishingName or spellName(7620)
  local name = fishingName and spellName(id)
  return name ~= nil and name == fishingName
end
ns.IsFishingSpell = isFishingSpell

--- Is the loot window that just opened a fishing bobber's?
local function bobberLoot(t)
  if type(IsFishingLoot) == "function" then
    local ok, yes = pcall(IsFishingLoot)
    if ok and not HC:IsSecret(yes) then return yes and true or false end
  end
  if channelOn then return true end
  return channelEndAt ~= nil and t ~= nil and t - channelEndAt <= FISH_GRACE
end

--- Is a loot line now a catch?
local function catching(t)
  if fishOpen then return true end
  return fishClosedAt ~= nil and t ~= nil and t - fishClosedAt <= FISH_GRACE
end

-- (0.3.0-beta3) Casts. One cast is one Fishing channel of yours. It is caught when a bobber's loot opens during the
-- channel or within FISH_GRACE seconds of its end (the click ends the channel; the two events may come in either
-- order), and got away when that time passes with no bobber loot: clicked too early or too late, nothing bit before
-- the bobber vanished, or the channel was broken (moving, jumping, a hit). A cast the game refuses (no pole, no water)
-- never starts a channel and is not counted. The wait of a catch: seconds from the cast to the click (the channel's
-- end, or the loot's opening when that comes first).
local cast = { start = nil, stop = nil, settled = true }

local function settleCaught(t)
  if cast.settled or not cast.start then return end
  cast.settled = true
  local z = HC:ZoneKey()
  HC:Emit(ID.casts, 1, z)
  local wait = (cast.stop or t) - cast.start
  if wait >= 0 then HC:Emit(ID.wait, wait, z) end
end

local function settleMissed()
  if cast.settled or not cast.start then return end
  cast.settled = true
  local z = HC:ZoneKey()
  HC:Emit(ID.casts, 1, z)
  HC:Emit(ID.missed, 1, z)
end

--- After a channel ends: no bobber loot within FISH_GRACE seconds means the fish got away.
local function settleLater()
  local t = GetTime()
  if not cast.settled and cast.stop and t - cast.stop >= FISH_GRACE then settleMissed() end
end
ns.SettleCast = settleLater

HC:RegisterSource("hcfarm:fishing", { mode = "event", feeds = { ID.fish, ID.casts, ID.missed, ID.wait },
  events = { "LOOT_READY", "LOOT_OPENED", "LOOT_CLOSED", "CHAT_MSG_LOOT",
    "UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_CHANNEL_STOP" },
  handler = function(event, a1, _, a3)
    local t = GetTime()
    if event == "LOOT_READY" or event == "LOOT_OPENED" then
      if not fishOpen then fishOpen = bobberLoot(t) end
      if fishOpen then
        fishClosedAt = nil
        if not cast.settled and (cast.stop == nil or t - cast.stop <= FISH_GRACE) then settleCaught(t) end
      end
    elseif event == "LOOT_CLOSED" then
      if fishOpen then fishClosedAt = t end
      fishOpen = false
    elseif event == "CHAT_MSG_LOOT" then
      if not catching(t) or not HC:Readable(a1) then return end
      local id, n = Parse.loot(pat, a1)
      if id then HC:Emit(ID.fish, n, id, HC:ZoneKey()) end
    elseif event == "UNIT_SPELLCAST_CHANNEL_START" or event == "UNIT_SPELLCAST_CHANNEL_STOP" then
      if HC:IsSecret(a1) or a1 ~= "player" or not isFishingSpell(a3) then return end
      channelOn = event == "UNIT_SPELLCAST_CHANNEL_START"
      if channelOn then
        settleMissed()                                  -- a new cast before the last one was settled: it got away
        cast.start, cast.stop, cast.settled = t, nil, false
      else
        channelEndAt = t
        if not cast.settled then
          cast.stop = t
          if C_Timer and C_Timer.After then C_Timer.After(FISH_GRACE + 0.1, settleLater) end
        end
      end
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

---------------------------------------------------------------------------
-- The Fishing basket (2026-11-25, the user): a board that counts what you fish in a run (its timer: Reset empties
-- the basket), each catch's count and share (a list mix), and the fish you carry.
---------------------------------------------------------------------------

local FISH = { dim = "fish", type = "enum", label = itemLabel, optional = true, anyLabel = "Every catch" }
HC:RegisterReading("hcfarm:fished", { title = "Fish caught", rateTitle = "Fish/h", tracker = "hcfarm:fishing",
  counter = ID.fish, param = FISH, scopes = ALL, formatter = "number", order = 32, mixList = true,
  description = "What you fished up, each item counted (fish, junk, clams, chests): pick one catch on the tile, or count them all."
    .. " As a mix: each catch with its count and share." })

--- Fish in your bags: one catch, or every item you have ever fished on this character together.
local function fishInBags(arg)
  if arg ~= nil then return inBags(arg) end
  local sum = 0
  for _, id in ipairs(HC.CounterMembers and HC:CounterMembers(ID.fish, "fish") or {}) do
    sum = sum + (inBags(id) or 0)
  end
  return sum
end
ns.FishInBags = fishInBags
HC:RegisterReading("hcfarm:fishbags", { title = "Fish in bags", tracker = "hcfarm:fishing", counter = ID.fish,
  param = FISH, scopes = { "now" }, formatter = "number", order = 33, mixList = true, refresh = { "BAG_UPDATE" },
  description = "How many of the things you have fished you carry right now (bags only): one catch, or all of them."
    .. " As a mix: each one with its count and share.",
  compute = function(_, _, arg) return fishInBags(arg) end })

-- (0.3.0-beta3) Casts and their timing. No "fastest bite": a board's timer keeps a flow's best (its max) only.
local FISH_BEST = { "run", "today", "week", "month", "year", "lifetime" }   -- a best single value: the board's timer or history
HC:RegisterReading("hcfarm:fishcasts", { title = "Fishing casts", rateTitle = "Casts/h", tracker = "hcfarm:fishing",
  counter = ID.casts, scopes = ALL, formatter = "number", order = 34,
  description = "Times you cast Fishing, caught or not. A cast the game refuses (no pole, no water) isn't one." })
HC:RegisterReading("hcfarm:fishmissed", { title = "Got away", rateTitle = "Got away/h", tracker = "hcfarm:fishing",
  counter = ID.missed, scopes = ALL, formatter = "number", order = 35,
  description = "Casts with no catch: clicked too early or too late, nothing bit before the bobber vanished, or the cast was broken." })
local function catchRate(get, scope)
  local all, missed = get("hcfarm:fishcasts", scope), get("hcfarm:fishmissed", scope)
  if type(all) ~= "number" or all <= 0 then return nil end
  return (all - (type(missed) == "number" and missed or 0)) / all * 100
end
ns.CatchRate = catchRate
HC:RegisterReading("hcfarm:fishrate", { title = "Catch rate", tracker = "hcfarm:fishing", inputs = { "hcfarm:fishcasts", "hcfarm:fishmissed" },
  compute = catchRate, scopes = ALL, formatter = "percent", order = 36,
  description = "The share of your casts that caught something." })
HC:RegisterReading("hcfarm:fishwait", { title = "Average wait for a bite", tracker = "hcfarm:fishing", counter = ID.wait,
  measure = "avg", scopes = { "run", "session" }, formatter = "seconds", order = 37,
  description = "Seconds from your cast to the click, averaged over the casts that caught something." })
HC:RegisterReading("hcfarm:fishwaitmax", { title = "Longest wait for a bite", tracker = "hcfarm:fishing", counter = ID.wait,
  measure = "max", scopes = FISH_BEST, formatter = "seconds", order = 38,
  description = "Your longest wait from a cast to a catch." })
HC:RegisterReading("hcfarm:fishtime", { title = "Time waiting for bites", tracker = "hcfarm:fishing", counter = ID.wait,
  scopes = ALL, formatter = "duration", order = 39,
  description = "Every catch's wait added up: time with a line in the water that ended in a catch." })

if HC.RegisterBoardPreset then
  HC:RegisterBoardPreset("hcfarm:fishing", { name = "Fishing basket", category = "activity",
    tip = "What you fish in a run (Reset empties the basket), each catch's count and share, your casts, catch rate"
      .. " and waits, and the fish in your bags. Needs the Fishing tracker on.",
    tiles = {
      { reading = "hcfarm:fished", size = "large", extras = { "sparkline" } },
      { reading = "hcfarm:fished", calc = "perHour", size = "half" },
      { reading = "hcfarm:fishbags", scope = "now", size = "half" },
      { reading = "hcfarm:fishcasts", size = "half" },
      { reading = "hcfarm:fishmissed", size = "half" },
      { reading = "hcfarm:fishrate", size = "half" },
      { reading = "hcfarm:fishwait", size = "half" },
      { reading = "hcfarm:fishwaitmax", size = "line" },
      { reading = "hcfarm:fished", display = "mix" },
      { reading = "hcfarm:fishbags", scope = "now", display = "mix" },
    } })
end
