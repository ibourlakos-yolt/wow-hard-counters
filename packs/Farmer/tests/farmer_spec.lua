-- Farmer on the real Hard Counters engine (../../HardCounters), through its public API only.
local Env = require("env")
local S = require("strings")
Env.ROOT = "../../HardCounters"

local ITEMS = {
  [2589] = { name = "Linen Cloth", quality = 1, class = 7, sub = 5, price = 13 },
  [4306] = { name = "Silk Cloth", quality = 1, class = 7, sub = 5, price = 150 },
  [7909] = { name = "Aquamarine", quality = 2, class = 7, sub = 4, price = 1000 },
  [1234] = { name = "Grey Junk", quality = 0, class = 15, sub = 0, price = 5 },
}

local function boot(opts)
  local env = Env.new()
  local game = { money = 100000, xp = 100, xpMax = 1000, level = 20, cached = {} }
  env.game = game
  -- the game first: Hard Counters' Basics (gold and XP per hour) reads these when it loads
  for k, v in pairs(S.enUS) do _G[k] = v end
  _G.GetMoney = function() return game.money end
  _G.UnitXP = function() return game.xp end
  _G.UnitXPMax = function() return game.xpMax end
  _G.UnitLevel = function() return game.level end
  _G.GetXPExhaustion = function() return nil end
  Env.BASICS = true
  env:load()
  Env.BASICS = nil
  -- Farmer's trackers start off (TRACKERS_AND_BOARDS §0.3): these specs test counting, so all on, full history
  env.settings = env.ns.DefaultProfile()
  env.settings.trackers = {}
  for _, id in ipairs(opts and opts.defaults and {} or { "hc:goldph", "hc:xpph", "hcfarm:ledger", "hcfarm:loot", "hcfarm:rep" }) do
    env.settings.trackers[id] = { on = true, history = "detailed", seen = true }
  end
  _G.C_Item = nil
  _G.GetItemInfoInstant = function(id) local it = ITEMS[id]; return id, nil, nil, nil, nil, it and it.class, it and it.sub end
  _G.GetItemInfo = function(id)
    local it = ITEMS[id]
    if not it or game.cached[id] == false then return nil end
    return it.name, nil, it.quality, nil, nil, nil, nil, nil, nil, nil, it.price
  end
  _G.GetInboxInvoiceInfo = function() return "seller" end
  _G.Enum = { PlayerInteractionType = { TradePartner = 1, Merchant = 5, TaxiNode = 6, Trainer = 7, MailInfo = 17,
    Auctioneer = 21 } }
  _G.C_Reputation = {
    GetNumFactions = function() return 1 end,
    GetFactionDataByIndex = function() return { name = "Timbermaw Hold", factionID = 576 } end,
    GetFactionDataByID = function(id)
      if id ~= 576 then return nil end
      return { name = "Timbermaw Hold", factionID = 576, currentStanding = 4500, currentReactionThreshold = 3000,
        nextReactionThreshold = 9000 }
    end,
  }
  local fns = {}
  for _, f in ipairs({ "Parse.lua", "Attribution.lua", "Farmer.lua" }) do
    assert(loadfile("HardCounters_Farmer/" .. f))("HardCounters_Farmer", fns)
  end
  env.farm = fns
  env:fire("ADDON_LOADED", "HardCounters")
  env.sv.HardCountersDB = _G.HardCountersDB
  env:fire("PLAYER_ENTERING_WORLD", true, false)
  return env
end

local function total(env, id, extra)
  local q = { counter = id, grain = "lifetime" }
  for k, v in pairs(extra or {}) do q[k] = v end
  return assert(env.HC:Query(q)).total
end

local function bySource(env, id, dim)
  local out = {}
  for _, r in ipairs(assert(env.HC:Query({ counter = id, grain = "lifetime", groupBy = dim }))) do out[r.member] = r.value end
  return out
end

local function gainMoney(env, copper)
  env.game.money = env.game.money + copper
  env:fire("PLAYER_MONEY")
end

describe("Farmer on Hard Counters", function()
  it("registers its pack, three counters, trackers, readings and views through the public API", function()
    local env = boot()
    local ids = env.HC:Counters()
    assert.are.equal(8, #ids)                         -- hc:time.active, Basics' 4, Farmer's 3
    assert.truthy(env.HC:GetCounter("hcfarm:loot.items"))
    assert.are.equal(13, #env.HC:RunReadings())       -- Basics' 8 with a run scope (Gold out: 2026-11-24), Farmer's 5 (vendorph: an alias)
    assert.truthy(env.HC:GetView("hcfarm:ledger.in"))
    assert.is_true(env.HC:Supports("bigDimensions"))
    assert.are.equal(100000, total(env, "hc:money.owned", { measure = "last" }))
  end)

  it("keeps a ledger: loot money either order, vendor, repair, quest, AH mail", function()
    local env = boot()
    local HC = env.HC
    env:fire("CHAT_MSG_MONEY", "You loot 1 Gold, 5 Silver")
    gainMoney(env, 10500)
    gainMoney(env, 300)
    env:fire("CHAT_MSG_MONEY", "You loot 3 Silver")
    env:fire("MERCHANT_SHOW")
    gainMoney(env, 2000)                               -- sold something
    env:callHook("RepairAllItems")
    gainMoney(env, -1500)
    env:fire("MERCHANT_CLOSED")
    env:fire("QUEST_TURNED_IN", 123, 0, 5000)
    gainMoney(env, 5000)
    env:callHook("TakeInboxMoney", 1)
    gainMoney(env, 90000)
    gainMoney(env, 77)                                 -- nothing explains it
    env:advance(3)
    assert.are.same({ loot = 10800, vendor = 2000, quest = 5000, ah = 90000, other = 77 }, bySource(env, "hc:money.in", "source"))
    assert.are.same({ repair = 1500 }, bySource(env, "hc:money.out", "sink"))
    assert.are.equal(env.game.money, total(env, "hc:money.owned", { measure = "last" }))
    -- the ledger matches the GetMoney diff exactly
    assert.are.equal(env.game.money - 100000, total(env, "hc:money.in") - total(env, "hc:money.out"))
    local _ = HC
  end)

  it("FM-16: mail from and to your own characters is booked apart, and account-wide totals leave it out", function()
    local env = boot()
    local HC = env.HC
    env.sv.HardCountersDB.chars["Player-1-00000099"] = { name = "Alty", realm = "Test" }
    local senders = { [1] = "Alty", [2] = "Stranger", [3] = "Alty-Test" }
    _G.GetInboxInvoiceInfo = function() return nil end
    _G.GetInboxHeaderInfo = function(i) return nil, nil, senders[i] end
    local sendMoney = 0
    _G.GetSendMailMoney = function() return sendMoney end
    env:fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 17)
    env:callHook("TakeInboxMoney", 1)
    gainMoney(env, 4000)
    env:callHook("TakeInboxMoney", 2)
    gainMoney(env, 300)
    env:callHook("TakeInboxMoney", 3)
    gainMoney(env, 1000)
    sendMoney = 2000
    env:callHook("SendMail", "Alty", "gold", "")
    gainMoney(env, -2030)
    sendMoney = 500
    env:callHook("SendMail", "Stranger", "gold", "")
    gainMoney(env, -530)
    env:advance(3)
    assert.are.same({ alts = 5000, mail = 300 }, bySource(env, "hc:money.in", "source"))
    assert.are.same({ alts = 2000, mail = 560 }, bySource(env, "hc:money.out", "sink"))
    -- this character: all of it, as decided 2026-11-15; the account: none of what moved between its characters
    assert.are.equal(5300, (HC:Reading("hc:gold", "today")))
    assert.are.equal(300, (HC:Reading("hc:gold", "today", nil, "account")))
    assert.are.equal(2740, (HC:Reading("hc:net", "today")))
    assert.are.equal(-260, (HC:Reading("hc:net", "today", nil, "account")))
    _G.GetInboxHeaderInfo, _G.GetSendMailMoney = nil, nil
  end)

  it("closes windows whose _CLOSED event never fires (in game 2026-11-14: MAIL_CLOSED, TRAINER_CLOSED)", function()
    local env = boot()
    env:fire("MAIL_SHOW")
    env:fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 17)
    env:callHook("TakeInboxMoney", 1)
    gainMoney(env, 400)                                -- a mail take
    env:fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", 17)  -- no MAIL_CLOSED
    gainMoney(env, 25)                                 -- loot money, PLAYER_MONEY first
    env:fire("CHAT_MSG_MONEY", "You loot 25 Copper")
    env:fire("TRAINER_SHOW")                           -- old event only, then a loading screen
    env:fire("PLAYER_ENTERING_WORLD", false, false)
    gainMoney(env, -60)
    env:advance(3)
    assert.are.same({ ah = 400, loot = 25 }, bySource(env, "hc:money.in", "source"))
    assert.are.same({ other = 60 }, bySource(env, "hc:money.out", "sink"))
  end)

  it("keys looted items by numeric item ID with quality, category, vendor value and zone", function()
    local env = boot()
    env:fire("CHAT_MSG_LOOT", S.enUS.LOOT_ITEM_SELF_MULTIPLE:format(S.link(2589, "Linen Cloth"), 4))
    env:fire("CHAT_MSG_LOOT", S.enUS.LOOT_ITEM_SELF:format(S.link(7909, "Aquamarine")))
    env:fire("CHAT_MSG_LOOT", S.enUS.LOOT_ITEM_SELF:format(S.link(1234, "Grey Junk")))
    env:fire("CHAT_MSG_LOOT", "Bob receives loot: " .. S.link(4306) .. ".")
    assert.are.same({ [2589] = 4, [7909] = 1, [1234] = 1 }, bySource(env, "hcfarm:loot.items", "item"))
    assert.are.same({ cloth = 4, gem = 1, junk = 1 }, bySource(env, "hcfarm:loot.items", "category"))
    assert.are.same({ [1] = 4, [2] = 1, [0] = 1 }, bySource(env, "hcfarm:loot.items", "quality"))
    assert.are.equal(4 * 13 + 1000 + 5, total(env, "hcfarm:loot.vendorvalue"))
    local best = assert(env.HC:Query({ counter = "hcfarm:loot.vendorvalue", grain = "lifetime", measure = "max" }))
    assert.are.equal(1000, best.total)
    -- zone keys are numbers end to end (HC-25): the stored member and the record's context
    local zone = env.HC:ZoneKey()
    assert.are.equal("number", type(zone))
    local byZone = assert(env.HC:Query({ counter = "hcfarm:loot.items", grain = "lifetime", groupBy = "zone" }))
    assert.are.equal(zone, byZone[1].member)
    assert.are.equal(zone, best[1].ctx.zone)
  end)

  it("waits for item info that isn't cached yet", function()
    local env = boot()
    env.game.cached[4306] = false
    env:fire("CHAT_MSG_LOOT", S.enUS.LOOT_ITEM_SELF:format(S.link(4306, "Silk Cloth")))
    assert.is_nil(total(env, "hcfarm:loot.items"))
    env.game.cached[4306] = nil
    env:fire("GET_ITEM_INFO_RECEIVED", 4306, true)
    assert.are.equal(1, total(env, "hcfarm:loot.items"))
    assert.are.equal(150, total(env, "hcfarm:loot.vendorvalue"))
  end)

  it("counts XP by source across a level-up, and reputation by faction ID", function()
    local env = boot()
    env:fire("CHAT_MSG_COMBAT_XP_GAIN", S.enUS.COMBATLOG_XPGAIN_FIRSTPERSON:format("Kobold", 150))
    env.game.xp = 250
    env:fire("PLAYER_XP_UPDATE", "player")
    env:fire("QUEST_TURNED_IN", 1, 900, 0)
    env.game.xp, env.game.level, env.game.xpMax = 150, 21, 1200
    env:fire("PLAYER_XP_UPDATE", "player")
    env:advance(3)
    assert.are.same({ kill = 150, quest = 900 }, bySource(env, "hc:xp", "source"))
    env:fire("CHAT_MSG_COMBAT_FACTION_CHANGE", S.enUS.FACTION_STANDING_INCREASED:format("Timbermaw Hold", 25))
    assert.are.same({ [576] = 25 }, bySource(env, "hcfarm:rep", "faction"))
    -- FM-15: a reading with a parameter reads one faction, named by the pack
    assert.are.equal(25, (env.HC:Reading("hcfarm:repwith", "session", 576)))
    assert.are.equal(0, (env.HC:Reading("hcfarm:repwith", "session", 59)))
    assert.are.equal("Timbermaw Hold rep", env.ns.ReadingTitle(env.ns.readings["hcfarm:repwith"], 576))
    assert.are.same({ "run", "session", "today", "week", "month", "year", "lifetime" }, env.HC:GetReading("hcfarm:repwith").scopes)
    -- (2026-11-24) folded into Reputation gained: the faction is the tile's choice, none for every faction
    assert.are.equal(25, (env.HC:Reading("hcfarm:rep", "session")))
    assert.are.equal(25, (env.HC:Reading("hcfarm:rep", "session", 576)))
    assert.are.equal("Reputation gained: Timbermaw Hold", env.ns.ReadingTitle(env.ns.readings["hcfarm:rep"], 576))
    assert.are.equal("hcfarm:rep", env.HC:GetReading("hcfarm:repwith").foldInto)
    assert.are.equal("hcfarm:items", env.HC:GetReading("hcfarm:looted").foldInto)
    -- XP by source as the tile's filter
    assert.are.equal(900, (env.HC:Reading("hc:xpgained", "session", { arg = { "quest" } })))
    -- HC-33: a bar toward the next standing (the faction API is unverified on Forever: nil when it can't say)
    assert.are.equal(1500, (env.HC:Reading("hcfarm:standing", "now", 576)))
    assert.are.equal(6000, env.HC:ReadingTarget("hcfarm:standing", 576))
    assert.is_nil((env.HC:Reading("hcfarm:standing", "now", 59)))
    assert.is_nil(env.HC:ReadingTarget("hcfarm:standing", 59))
    assert.is_nil(env.HC:ReadingTarget("hcfarm:standing", "Booty Bay"))
  end)

  it("gives the run report its numbers: totals, gold/h, items, best drop", function()
    local env = boot()
    local HC = env.HC
    assert(HC:StartRun("Felwood"))
    env:fire("CHAT_MSG_MONEY", "You loot 50 Silver")
    gainMoney(env, 5000)
    env:fire("CHAT_MSG_LOOT", S.enUS.LOOT_ITEM_SELF_MULTIPLE:format(S.link(2589, "Linen Cloth"), 3))
    env:fire("CHAT_MSG_LOOT", S.enUS.LOOT_ITEM_SELF:format(S.link(7909, "Aquamarine")))
    env:advance(1800)
    local v, text = HC:RunReading("hc:goldph")
    assert.are.equal(10000, v)
    assert.are.equal("1g 0s 0c/h", text)
    assert.are.equal(4, (HC:RunReading("hcfarm:items")))
    -- FM-17: one reading per thing counted; the old per-hour id is an alias with the same value
    local vendor = 3 * 13 + 1000
    assert.are.equal(vendor, (HC:RunReading("hcfarm:vendor")))
    assert.are.equal(vendor * 2, (HC:RunReading("hcfarm:vendorph")))
    assert.are.equal(vendor * 2, (HC:Reading("hcfarm:vendor", "run", { calc = "perHour" })))
    assert.are.equal("hcfarm:vendor", HC:GetReading("hcfarm:vendorph").aliasOf)
    assert.are.equal(8, (HC:Reading("hcfarm:items", "run", { calc = "perHour" })))
    assert.are.equal(6, (HC:Reading("hcfarm:looted", "run", { arg = 2589, calc = "perHour" })))
    assert.are.same({ "total", "perHour", "recent", "trend" }, HC:GetReading("hcfarm:rep").calcs)
    assert.are.same({ "total", "perHour", "recent", "trend" }, HC:GetReading("hcfarm:looted").calcs)
    for _, id in ipairs({ "hcfarm:best", "hcfarm:standing", "hcfarm:inbags" }) do
      assert.are.same({ "total" }, HC:GetReading(id).calcs)
    end
    assert.are.equal("Items/h", env.ns.ReadingTitle(env.ns.readings["hcfarm:items"], nil, "perHour"))
    assert.are.equal("Loot vendor value/h recent", env.ns.ReadingTitle(env.ns.readings["hcfarm:vendor"], nil, "recent"))
    assert.are.equal(1000, (HC:RunReading("hcfarm:best")))
    -- FM-15: one item out of the run's item list, one source of the money
    assert.are.equal(3, (HC:Reading("hcfarm:looted", "run", 2589)))
    assert.are.equal(1, (HC:Reading("hcfarm:looted", "run", 7909)))
    assert.are.equal(5000, (HC:Reading("hc:goldfrom", "run", "loot")))
    assert.are.equal(0, (HC:Reading("hc:goldfrom", "run", "vendor")))
    -- HC-34: the items looted last are kept for the picker, newest first; "in bags" asks the game, not a counter
    assert.are.same({ 7909, 2589 }, env.ns.RecentMembers("hcfarm:loot.items", "item"))
    assert.is_nil((HC:Reading("hcfarm:inbags", "now", 2589)))        -- no item count API: no value, not 0
    _G.GetItemCount = function(id) return id == 2589 and 143 or 0 end
    assert.are.equal(143, (HC:Reading("hcfarm:inbags", "now", 2589)))
    assert.are.equal(0, (HC:Reading("hcfarm:inbags", "now", 7909)))
    assert.is_nil((HC:Reading("hcfarm:inbags", "now", "Linen Cloth")))
    assert.are.equal("In bags: Linen Cloth", env.ns.ReadingTitle(env.ns.readings["hcfarm:inbags"], 2589))
    _G.GetItemCount = nil
    local rec = HC:GetRunRecord(HC:StopRun())
    assert.are.equal(5000, rec.deltas["hc:money.in"].sum)
    assert.are.same({ loot = 5000 }, rec.deltas["hc:money.in"].by.source)
    assert.are.same({ [2589] = 3, [7909] = 1 }, rec.live["hcfarm:loot.items"].m)
    assert.are.equal(7909, rec.live["hcfarm:loot.vendorvalue"].max.item)
    assert.are.equal(1800, rec.activeSeconds)
  end)

  it("ignores secret values without touching them", function()
    local env = boot()
    env:fire("CHAT_MSG_LOOT", env:secretValue())
    env:fire("CHAT_MSG_MONEY", env:secretValue())
    env.game.money = env:secretValue()
    env:fire("PLAYER_MONEY")
    assert.is_nil(total(env, "hcfarm:loot.items"))
    assert.is_true(env.ns.health.session.secretsRejected >= 3)
  end)
end)

describe("Farmer's trackers", function()
  it("start off and New: nothing of Farmer's counts or listens, Basics' starters still count", function()
    local env = boot({ defaults = true })
    local HC = env.HC
    for _, id in ipairs({ "hcfarm:ledger", "hcfarm:loot", "hcfarm:rep" }) do
      assert.is_false(HC:IsTrackerOn(id))
      assert.is_true(HC:GetTracker(id).new)
    end
    local active = {}
    for _, s in ipairs(env.ns.SourceStats()) do active[s.id] = s.active end
    assert.is_false(active["hcfarm:loot"])
    assert.is_false(active["hcfarm:rep"])
    assert.is_true(active["hcfarm:money"])           -- names the sources of Basics' money and XP
    env:fire("CHAT_MSG_LOOT", S.enUS.LOOT_ITEM_SELF:format(S.link(7909, "Aquamarine")))
    assert.is_false(HC:CounterState("hcfarm:loot.items").active)
    assert.are.equal("off", select(4, HC:Reading("hcfarm:items", "session")))
    -- Basics counts gold with Farmer's sources, Live only
    env:fire("CHAT_MSG_MONEY", "You loot 5 Silver")
    env.game.money = env.game.money + 500
    env:fire("PLAYER_MONEY")
    env:advance(3)
    assert.are.equal(500, env.ns.Win.Total(env.ns.Session(), "hc:money.in"))
    assert.are.equal("off", HC:CounterState("hc:money.in").history)
    -- the Ledger needs daily history: switching it on turns that on for the money counters
    HC:SetTrackerOn("hcfarm:ledger", true)
    assert.are.equal("daily", HC:CounterState("hc:money.in").history)
    assert.is_true(HC:CounterState("hc:money.in").stored)
  end)
end)
