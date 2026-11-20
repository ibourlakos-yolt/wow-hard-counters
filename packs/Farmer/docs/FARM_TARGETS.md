# Farm targets: what players farm, and how we could count it

> **Status:** reference menu (2026-11-14). **Desk research only**: nothing here has been tested on WoW Forever. **The first cut is decided** and lives in [`DESIGN.md`](DESIGN.md) §4 (the farmer's toolkit: Ledger and run report first, manual runs). §12 and §14 below are superseded by it; the rest stays as the menu for later tools.
>
> **Context:** Forever is a Classic+ game (level cap 60, original Azeroth reimagined, new zones and dungeons) on the retail 12.x engine with Midnight addon restrictions. The combat log is forbidden. See `../../../docs/research.md` §1 and `../../../docs/api-surface.md`.
>
> **Status key:** 🟡 likely works (API reported present) · ❓ unknown · ⚠️ degraded (estimate or gaps) · ⛔ likely blocked. Items marked *(Forever?)* depend on content that Classic had but Forever may have changed.

---

## 0. The one insight that shapes the pack

Most farm targets are **the same event seen through different filters**: *an item, money or points arrived, from some source, somewhere*. Herbs, ore, cloth, enchanting dust, rep tokens, BoE drops and recipes are all "items acquired", told apart by item class, subclass and quality (`GetItemInfoInstant`) and by the loot source (a creature, a gathering node, a container, a fishing bobber).

So the pack should not be 40 counters. It should be **about 8 primitive counters** with good dimensions, plus **views** (filters and presets) that present them as "herbs per hour", "runecloth this week" and so on. That's also the better test of Hard Counters: views, filters and dimensions get exercised, not just `RegisterCounter`.

| Primitive | Kind | Capture mode | Covers |
|---|---|---|---|
| **Money** | flow + stock | push-delta (`CHAT_MSG_MONEY`) and snapshot-diff (`PLAYER_MONEY` + `GetMoney`) | §1 |
| **Items acquired** | flow | push-delta (`CHAT_MSG_LOOT` own loot) cross-checked with bag diffs (`BAG_UPDATE_DELAYED`) | §4–§7 |
| **Loot events** | flow | loot window (`LOOT_READY`, `GetLootSourceInfo`) + the spell that opened it (`UNIT_SPELLCAST_SUCCEEDED`) | nodes, containers, kills looted |
| **XP** | flow | push-delta (`CHAT_MSG_COMBAT_XP_GAIN`) and snapshot-diff (`PLAYER_XP_UPDATE`) | §2 |
| **Reputation** | flow | push-delta (`CHAT_MSG_COMBAT_FACTION_CHANGE`) and snapshot-diff (`UPDATE_FACTION`) | §3 |
| **Skill-ups** | flow | push-delta (`CHAT_MSG_SKILL`) | §4, §5 |
| **Honor / currencies** | flow | push-delta (`CHAT_MSG_COMBAT_HONOR_GAIN`, `CHAT_MSG_CURRENCY`, `CURRENCY_DISPLAY_UPDATE`) | §8, §9 |
| **Farming time** | flow | state-duration (active, not AFK, per zone; per run once runs exist) | the denominator of every "per hour" |

Every "per hour" number is `sum / farming time`, so **active time is not optional**: without it, gold per hour counts AFK and city time.

---

## 1. Money

| Target | Why players farm it | Capture on Forever | Status | Dimensions / notes |
|---|---|---|---|---|
| Raw gold looted from mobs | The baseline farm | `CHAT_MSG_MONEY` ("You loot …"), parsed with the localized `YOU_LOOT_MONEY` pattern | 🟡 | zone. Chat may be restricted inside instance encounters (Midnight) ❓ |
| Net money change | The honest number: income minus spending | `PLAYER_MONEY` + `GetMoney()` diff | 🟡 | source / sink inferred from open windows (merchant, mail, AH, trainer, taxi) |
| Vendor income | Selling greys and mats to NPCs | money diff while `MERCHANT_SHOW` is open | 🟡 | split greys vs other via bag diff |
| AH income and deposits lost | Sellers farm to sell | mail money from AH (`MAIL_INBOX_UPDATE`), AH events | ❓ | overlaps Auctionator |
| Quest gold | Quest hubs at 60 pay gold instead of XP | `QUEST_TURNED_IN` (money argument) | 🟡 | |
| Costs: repairs, ammo, reagents, food, training, travel | Turns gross into **net** gold per hour | money diff with the merchant open after `RepairAllItems`, taxi, trainer | 🟡 inferred | sink dimension |
| Gold owned (stock) | "Most gold ever", net worth over time | `GetMoney()` → `Observe` | 🟡 | account sum across alts comes free |
| **Vendor value of loot** | "What did this farm make if I vendor it all?" | items acquired × `GetItemInfo` sell price | 🟡 | sell price can be nil until the item is cached; retry |
| **Market value of loot** | The number farmers actually care about | items acquired × Auctionator / TSM price | ❓ | optional dependency **behind an adapter**; prices change, so store the value at loot time |
| Gold per hour (gross, net, by value) | The speedometer showcase | derived: money / farming time | 🟡 | three flavours; label which |

## 2. Experience and leveling

| Target | Why | Capture | Status | Notes |
|---|---|---|---|---|
| XP from kills | Grinding spots, AoE farms | `CHAT_MSG_COMBAT_XP_GAIN` (localized patterns) | 🟡 | gives mob name, not GUID |
| XP from quests | Quest efficiency | `QUEST_TURNED_IN` (xp argument) | 🟡 | |
| XP from discovery, other | Exploration | `PLAYER_XP_UPDATE` diff minus the above | ⚠️ inferred | |
| Rested bonus share | How much rested XP helped | the "(+N exp Rested bonus)" part of the message; `GetXPExhaustion` | 🟡 | |
| Group and level penalties | Dungeon grinding | message variants | ❓ | |
| Kills (via XP messages) | "Mobs per hour" | count XP-gain kill messages | ⚠️ | misses grey-level mobs (no XP) and kills without XP; the kill events themselves are restricted |
| XP per hour, time to level, levels gained | The leveling dashboard | derived; `PLAYER_LEVEL_UP` | 🟡 | |

## 3. Reputation

| Target | Why | Capture | Status | Notes |
|---|---|---|---|---|
| Rep points per faction | Exalted grinds, rewards behind rep | `CHAT_MSG_COMBAT_FACTION_CHANGE`; `UPDATE_FACTION` + reputation API diff as a cross-check | 🟡 | faction dimension (≈ 30–60 factions; fits a cap) |
| Rep from kills vs turn-ins vs quests | Which method is faster | context: open gossip/quest window at the time | ⚠️ inferred | |
| Rep turn-in items collected | Classic-style token grinds (Scourgestones, Timbermaw feathers, Cenarion signets, Zandalar coins and bijous, Thorium Brotherhood mats…) *(Forever?)* | items acquired, filtered by a list | 🟡 | the list is content data and needs maintaining |
| Standing reached (Honored, Revered, Exalted) | Milestones | standing change | 🟡 | milestone with date and context |
| Rep per hour, time to next standing | Planning | derived | 🟡 | |

## 4. Gathering professions

| Target | Why | Capture | Status | Notes |
|---|---|---|---|---|
| **Herbs** | Potions and flasks for raids; sells well | loot after the Herb Gathering cast (`UNIT_SPELLCAST_SUCCEEDED`) + items acquired | 🟡 | herb, zone |
| **Ore, stone, gems** | Smithing, engineering, gems are bonus drops | loot after Mining | 🟡 | ore, gem, zone. Rare gem procs are a good "luck" stat |
| **Leather, hides, scales** | Leatherworking | loot after Skinning | 🟡 | |
| **Fish** | Cooking buffs, oils, rare catches | loot after Fishing; pools vs open water inferred from the target | 🟡 / ❓ | catches, junk, rare catches; casts per catch |
| Nodes gathered | "Nodes per hour", route efficiency | count gathering loots | 🟡 | per node type and zone |
| Node outcomes | Bonus items, failed gathers, nodes stolen by others | `UI_ERROR_MESSAGE`, loot contents | ❓ | |
| Gathering skill-ups | Leveling the profession | `CHAT_MSG_SKILL` | 🟡 | |

## 5. Mob drops and materials

| Target | Why | Capture | Status | Notes |
|---|---|---|---|---|
| **Cloth** (linen to runecloth, felcloth) | Tailoring, bandages, rep turn-ins | items acquired, Trade Goods › Cloth | 🟡 | |
| **Elemental materials** (Elemental Fire, Essence of Fire/Earth/Water/Air/Undeath, Living Essence, Heart of Fire…) | Raid consumables, crafted gear | items acquired, Trade Goods › Elemental | 🟡 | |
| Cooking ingredients (meat, eggs) | Buff food | items acquired, by class | 🟡 | |
| **Enchanting materials** from disenchanting | Dusts, essences, shards | items acquired after the Disenchant cast | 🟡 | yield per item disenchanted |
| Raid and crafting rarities (Righteous Orbs, Dark Iron, Arcanite, cores…) *(Forever?)* | High-value endgame mats | items acquired, watch list | 🟡 | |
| Quest collection items | "Kill 10, collect 8" efficiency | items acquired, Quest class | 🟡 | low value as a stat |

## 6. Loot quality, rares and luck

| Target | Why | Capture | Status | Notes |
|---|---|---|---|---|
| Items looted by quality | "How many greens and blues today" | items acquired, quality dimension | 🟡 | |
| **BoE world drops** (green, blue, epic) | Gold from the AH; the jackpot moment | items acquired, quality ≥ green, bind type | 🟡 | best drop with context = the record board |
| Recipes, patterns, formulas, plans | Profession unlocks, sell well | items acquired, Recipe class | 🟡 | |
| **Target-item hunts with attempts** | "Kills / boxes / casts since my last [mount, pet, recipe]"; drop-rate luck | user picks an item; count attempts (kills looted, containers opened, casts) until it drops | 🟡 / ⚠️ | a beloved stat, no rival on Forever is known to have it. Needs a "watch list" (user data, not a pack constant) |
| Mounts, pets, toys | Collection grinds *(Forever?)* | collection APIs if Forever has them | ❓ | |

## 7. Containers, lockboxes and pickpocketing

| Target | Why | Capture | Status | Notes |
|---|---|---|---|---|
| Containers opened (chests, clams, crates, bags in loot) | "Treasure" farming; clam pearls | loot source is an object, or the item was a container | 🟡 | |
| Lockboxes and Pick Lock | Rogue lockpicking | Pick Lock cast + container loot | 🟡 | |
| Pickpocketing | Rogue gold and junkboxes | Pick Pocket cast + loot | 🟡 | money and junkboxes per hour |

## 8. PvP

| Target | Why | Capture | Status | Notes |
|---|---|---|---|---|
| Honor points | Ranks and PvP gear *(Forever?)* | `CHAT_MSG_COMBAT_HONOR_GAIN`, honor APIs | ❓ | Forever's PvP system is unknown to us |
| Honorable kills | Rank progress | same | ❓ | kill attribution may be restricted |
| Battleground marks and wins/losses | Reward tokens | items acquired; BG end events | ❓ | |

## 9. Currencies, tokens and events

| Target | Why | Capture | Status | Notes |
|---|---|---|---|---|
| Any currency in the currency tab | Forever may add currencies | `CURRENCY_DISPLAY_UPDATE` diff, `CHAT_MSG_CURRENCY` | ❓ | generic: one counter, currency dimension |
| Darkmoon Faire tickets and turn-ins *(Forever?)* | Decks, prizes | items acquired + currency | ❓ | |
| Holiday event tokens (Lunar Festival coins…) *(Forever?)* | Seasonal rewards | items acquired, watch list | ❓ | |

## 10. Dungeon farming

| Target | Why | Capture | Status | Notes |
|---|---|---|---|---|
| Instance runs and resets | Gold and loot runs (e.g. solo farms); Classic had a limit of 5 instances per hour per account *(Forever?)* | instance enter/leave, the "has been reset" system message | 🟡 / ❓ | **"resets left this hour"** is a real pain point for dungeon farmers |
| Time, gold, XP and loot per run | Run efficiency | per-run aggregates | ❓ | needs **runs as a scope** (see §12) |
| Boss kills | Loot attempts | `ENCOUNTER_END` | ❓ | encounter events may be restricted |

## 11. Costs and friction (what eats the profit)

| Target | Why | Capture | Status | Notes |
|---|---|---|---|---|
| Repair costs | Net profit; Blizzard has **no statistic** for it | money diff with the merchant open after `RepairAllItems` | 🟡 inferred | |
| Consumables and reagents used (ammo, food, potions) | Net profit | bag diffs while farming | ⚠️ | |
| Deaths while farming | Time and repair cost | `PLAYER_DEAD` | 🟡 | |
| **Loot lost to full bags** | Farmers hate it; tells you to buy bags or vendor more often | `UI_ERROR_MESSAGE` "Inventory is full" while a loot window is open | ❓ | cheap and novel |
| Vendor and mailbox trips | Downtime | `MERCHANT_SHOW`, `MAIL_SHOW` | 🟡 | |
| Time AFK or idle while "farming" | Honest rates | AFK and idle state | 🟡 | `UnitIsAFK` may return a secret boolean; guard it |

## 12. Derived views farmers expect (not counters)

- Per hour for everything: gold, value, XP, rep, nodes, kills, drops.
- Today, this week, this reset week, best day, best hour, streaks.
- **This farming run:** start/stop, or automatic (zone entered, a gap of idle time ends it). *Not in Hard Counters v1 and not a LibGranaryDB grain.* Farmers think in runs, so the Farmer pack probably can't ship without it. Decide early.
- Per zone and per spot: "Winterspring vs Eastern Plaguelands for runecloth".
- Character vs account (alts that farm different things).
- Top drops (record board), "jackpot" pop-up (`OnNewExtreme`).

---

## 13. Hard limits this list runs into (blunt)

1. **Item cardinality vs LibGranaryDB caps.** A dimension holds at most 1,024 members, first come, first kept, forever (SPEC D16). A farmer loots thousands of distinct items over months, mostly greys. An "item" dimension fills with early junk and sends every later item to `other`. Options: key items only for non-grey or watch-listed items and let greys aggregate by quality; one counter per category (herbs, ore, cloth…) so each cap is spent on that category; or a library change (per-period members or eviction). **This is the first real test of the library's model, and probably the first library change.**
2. **Chat parsing is localized.** All `CHAT_MSG_*` patterns must be built from the client's global strings (`LOOT_ITEM_SELF`, `YOU_LOOT_MONEY`, `COMBATLOG_XPGAIN_*`, `FACTION_STANDING_INCREASED`…), never hard-coded English. enUS first, but build it right.
3. **Midnight restrictions on chat inside instances** are unverified on Forever. If loot and XP messages go secret in instances, bag diffs and `PLAYER_*` diffs become the fallback, and they lose the source.
4. **Kills are not observable directly** (no combat log; `PARTY_KILL`/`UNIT_DIED` restricted). "Kills" means "kills that gave XP or were looted". Label it.
5. **Prices are not ours.** Market value needs Auctionator or TSM data behind an adapter, and is an estimate by definition.
6. **Content lists rot.** Rep tokens, raid mats and event items are game data that changes with patches. Keep them as data, versioned, and let users edit their own watch list.

## 14. A suggested first cut (for the user to overrule)

Chosen to exercise every capture mode and the library's hard parts, not for breadth:
1. **Money:** gross loot, net change by source/sink, gold owned (stock). *push-delta, snapshot-diff, stock, `twa`.*
2. **Items acquired:** item (watch list + non-grey), category, quality, source kind, zone; vendor value. *High cardinality, caps, context records.*
3. **Gathering:** nodes and yields per profession. *Spell + loot correlation.*
4. **XP and reputation:** by source and by faction. *Localized chat parsing with diff cross-checks.*
5. **Farming time:** active time per zone. *State-duration; the denominator for every rate.*
6. **One luck tracker:** attempts until a watched item drops. *User data driving a counter.*

Deliberately out of the first cut: PvP, currencies and events (Forever content unknown), dungeon runs (need the run scope), market prices (an optional dependency).
