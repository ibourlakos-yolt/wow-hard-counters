# Hard Counters: Farmer — design document

> **Status:** concept / pre-implementation. Local-only project of Yolt Labs.
> **2026-11-14:** this repo was `HardCountersPacks` (all packs side by side). It is now **the farming pack only**. The general pack contract, the rules for pack authors and the ideas for other packs (travel, time, fun, combat, the jumps sample) moved to `../../docs/PACKS.md`. The old catalog is in this repo's git history (commit `9b5379d` and earlier).
>
> **Depends on:**
> - `../..` (the engine at the repo root): the engine and public API. See its `docs/DESIGN.md`, `docs/PACKS.md`, `docs/research.md` and `docs/api-surface.md`.
> - `../LibGranaryDB`: storage, reached **only** through Hard Counters. The Farmer pack never calls the library directly.

---

## 1. Purpose

**Count what players farm**: money, items, materials, XP, reputation, and the time it took, so every farm has a "per hour" and a "best ever".

It's also **the first pack**, so it's the first real client of Hard Counters' public API. It's built exactly as a third-party author would build it. If it needs anything private, the API has a gap: fix the API, never reach into internals (`../../docs/PACKS.md` §1).

## 2. Identity

| Thing | Value |
|---|---|
| Repo folder | `%USERPROFILE%\Documents\Projects\HardCountersSuite\HardCounters\packs\Farmer` (merged into the Hard Counters repo 2026-11-20) |
| Addon folder and TOC | `HardCounters_Farmer/HardCounters_Farmer.toc` (+ `_Forever.toc`) |
| Title | `Hard Counters: Farmer` |
| Counter ID namespace | `hcfarm:<counter>`, e.g. `hcfarm:money.loot` |
| Log tag | `[Pack:Farmer]` |
| SavedVariables | none; data lives in Hard Counters' LibGranaryDB root |

## 3. Structure

```
HardCounters/packs/Farmer/
  HardCounters_Farmer/   -- the addon: TOC, sources, counters, views, formatters, locale
  tools/                 -- link-to-AddOns, tests, lint (the zip is the bundle's, ../../tools/package.ps1)
  docs/                  -- this design, FARM_TARGETS.md
```

- `## Dependencies: HardCounters`, `## Interface: 16001`.
- Sources, counters and default views are registered through `HardCounters:RegisterSource`, `HardCounters:RegisterCounter` and the view API.
- Content lists (rep turn-in items, raid materials, event tokens) are **versioned data tables**, not code. A player's own watch list is user data owned by Hard Counters' settings.

## 4. The farmer's toolkit (concept model, agreed 2026-11-14)

The pack is a **toolkit**: each tool answers one question farmers ask. All tools sit on the same shared layer of primitive counters, item classification and valuation. The full menu of farm targets is [`FARM_TARGETS.md`](FARM_TARGETS.md).

| Tool | The farmer's question | Phase |
|---|---|---|
| **Ledger** | Where does my money come from and go? | **1** |
| **Run report** | What did this session make, per hour? | **1** (manual runs) |
| Spot compare | Is this zone worth it vs that one? | later |
| Goals | How long until 200 runecloth / Exalted / 1,000g? | later |
| Hunt | How unlucky am I with this item? | later |
| Alerts | Rare drop, goal reached, bags full, resets left | later |

```
 Tools:      [Ledger]  [Run report]  (later: Spot compare, Goals, Hunt, Alerts)
                 │           │
 Shared:     primitive counters · item classification · valuation · runs (Hard Counters)
                 │
 Storage:    Hard Counters → LibGranaryDB
```

### 4.1 Ledger

**Answers:** income and spending by source, net, gold owned over time; today, this week, this reset week, month, year, lifetime; character or account.

**Blunt positioning:** on its own, the Ledger is table stakes. Accountant Classic (979K downloads, on Forever) already does gold in/out by source per day/week/month/year. Ours earns its place by feeding the run report, by account-wide `twa`, and by the shared displays (speedometer, calendar heatmap, bar feed). Don't sink polish into it beyond parity.

**Capture:** `PLAYER_MONEY` + `GetMoney()` diff is the **truth**. Each delta gets a source from the signals around it:

| Signal around the delta | Source (in) / sink (out) |
|---|---|
| `CHAT_MSG_MONEY` own loot within a short window | in: `loot` |
| `QUEST_TURNED_IN` (money argument) | in: `quest` |
| merchant open, delta > 0 / < 0 | in: `vendor` / out: `vendor` |
| merchant open after `RepairAllItems` / repair cost known | out: `repair` |
| mail open, money taken from AH mail / other mail | in: `ah` / `mail` |
| AH open, delta < 0 | out: `ah` (deposits, fees, buys) |
| trainer open | out: `training` |
| taxi map open | out: `travel` |
| trade window | in/out: `trade` |
| none of the above | in/out: `other` |

**Money mailed between your own characters counts** on both sides: spending (`mail`) for the sender, income (`mail`) for the receiver, in the Ledger, gold per hour and run readings alike (user's decision, 2026-11-15, after a day where mail was 44% of income). No filtering by sender. Any money that leaves while the mailbox is open is booked as mail spending: money sent, postage and COD paid, in one change. At account scope the two sides cancel, leaving the postage.

**Own-character mail on account tiles (FM-16, decided by the user 2026-11-19: own source, account only).** Net
gold cancels at account scope, but "Gold earned" and "Spent" don't: an account-wide tile counts the same gold twice.
Mail from or to one of your own characters (the names Hard Counters knows) gets its own source, in and out, and
account-wide readings (Hard Counters DESIGN §16.5) and the Ledger's account view leave that source out. Per
character it still counts on both sides, as decided 2026-11-15; only its source name changes there, so "Gold from
mail" on a character no longer includes it. **Built 2026-11-19:** the source and sink are `alts` ("Your characters" in the
Ledger, whose account view leaves the row and its amount out); the sender comes from `GetInboxHeaderInfo` when money is
taken, the amount sent from `GetSendMailMoney` in a post-hook on `SendMail` (postage stays `mail`); both unverified on
Forever.

Inferred sources are labelled as inferred. Health metric: the gap between `CHAT_MSG_MONEY` loot and the loot share of the diff.

### 4.2 Run report

**Manual runs only** in phase 1. One run at a time. Runs are a **Hard Counters** feature (`../../docs/DESIGN.md` §5.1), so other packs can use them; Farmer is their first client.

**How a run works:** a run is a time range. At start, Hard Counters reads the lifetime totals of every run-tracked counter; at stop, it reads them again; **the difference is the run's exact total**, and active time comes from the same subtraction. Only two things need live tracking during a run: the per-item list (in memory; a run rarely sees more than a few hundred items) and the run's best drop.

**The farm stopwatch (the run's face).** A stopwatch metaphor, but with farmer readings instead of just a clock:

| Stopwatch part | Farmer meaning |
|---|---|
| Start / Stop | Start and stop the run |
| Pause / Resume | Vendor trip, a break. AFK pauses automatically (active time stops) |
| The big number | **Rate** of the user's chosen headline: gold/h by default, or vendor value/h, market value/h, XP/h, rep/h |
| Small readings | Active time, total so far, items looted, best drop |
| **Splits** (laps) | Mark a split when you change spot, after each instance reset, or at each pull. Each split shows its own rate and how it compares with the previous one. Splits are named sub-ranges of the run, made the same way (snapshots), so they cost nothing extra |
| Stop | The summary card: totals, rates, best drop, top items, splits; saved to the run list |

**Run record** (kept by Hard Counters in its own saved table, not in LibGranaryDB):
`{ id, label, character, start, stop, activeSeconds, mainZone, splits = { { label, start, stop, activeSeconds, deltas } }, money = { in, out, net, bySource }, vendorValue, items = { [itemKey] = quantity }, xp, rep = { byFaction }, best = { item, value, zone, time } }`
The full per-item list is kept in the record (a run is small), so market value can be recomputed for any past run with any price source.

### 4.3 Shared layer: phase 1 counters

| Counter | Kind | Measures | Dimensions (ordered, caps) | Sets | Capture |
|---|---|---|---|---|---|
| `hcfarm:money.in` | flow | sum, count, max (+ctx) | `source` 16, `zone` 64 | {}, {source}, {zone} | snapshot-diff + attribution (§4.1) |
| `hcfarm:money.out` | flow | sum, count, max (+ctx) | `sink` 16, `zone` 64 | {}, {sink}, {zone} | same |
| `hcfarm:money.owned` | stock | last, min, max, twa | — | {} | `GetMoney()` |
| `hcfarm:loot.items` — **"Looted items"** | flow | sum (quantity), count (loot events) | `item` (numeric item ID) 4096 (LibGranaryDB r2), `quality` 8, `category` 32, `zone` 64 | {}, {item}, {quality}, {category}, {zone}, {category, zone} | `CHAT_MSG_LOOT` own loot, cross-checked with bag diffs |
| `hcfarm:loot.vendorvalue` — "Looted items, vendor value" | flow | sum (copper), max (+ctx) | `category` 32, `zone` 64 | {}, {category}, {zone} | quantity × `GetItemInfo` sell price, at loot time |
| `hcfarm:xp` | flow | sum, count | `source` 8, `zone` 64 | {}, {source}, {zone} | `CHAT_MSG_COMBAT_XP_GAIN`, `QUEST_TURNED_IN`, `PLAYER_XP_UPDATE` diff |
| `hcfarm:rep` | flow | sum, count | `faction` 64, `zone` 64 | {}, {faction} | `CHAT_MSG_COMBAT_FACTION_CHANGE`, `UPDATE_FACTION` diff |
| `hc:time.active` *(Hard Counters core)* | flow | sum (seconds) | `zone` 64 | {}, {zone} | state-duration while not AFK; the denominator of every rate |

Grains for all: hour, day, week, resetweek, month, year, lifetime. Run-tracked: all of them.

**Decisions inside this table:**
- **Named for what it is: "Looted items".** Mail, AH, trade, crafting and bank moves are not counted; the bag diff only cross-checks loot. If other acquisition routes come later, they get their own counters with their own names.
- **Every item is keyed the same way, greys included** (revised 2026-11-14; the earlier "greys → `grey`" rule broke uniformity). The `item` member is the **numeric item ID** (§4.6), never a name. Everything else about an item (rarity, taxonomy, set…) is an **attribute looked up at query time**, not stored per write. **Variants (random suffix, bonus IDs) are not stored** (decided 2026-11-14; re-examine as FM-10).
- **`quality` and `category` are also stored as their own dimensions on purpose.** They duplicate what the item ID implies, but they keep exact totals and zone crosses even if `item` overflows to `other`, and they're cheap (8 and 32 members).
- **The cap is the cost of uniformity, and it's measured** ([`../LibGranaryDB/docs/BENCHMARKS.md`](../../../../LibGranaryDB/docs/BENCHMARKS.md) §7): a farmer keying every item passes 1,024 within the first month (about 2,000–2,600 distinct items a year in the model). **LibGranaryDB r2 raised the limit to 4,096** (about +0.3 MB a year in game, nothing at login), so Farmer embeds r2 or later and checks `API_VERSION >= 2`.
- **Zone is a number**: `HC:ZoneKey()` (a map ID outdoors, 100000 + the instance ID inside, 0 when unknown; Hard Counters HC-13, HC-25), labelled at display time with `HC:ZoneName`, so it survives language changes. Never the zone text.
- **Stored value = vendor price**, a stable fact recorded at loot time. Market prices are **not stored**; they're computed at query time (§4.5).

### 4.4 Later tools: what they will need

- **Spot compare:** the `zone` dimension already stored above, plus runs grouped by `mainZone`. Mostly views.
- **Goals:** a target per counter (Hard Counters settings) + current rate. Mostly views.
- **Hunt:** a user watch list and attempt counting (loot events from gathering, containers, kills looted). New capture.
- **Alerts:** callbacks (`OnNewExtreme`, goal reached, `UI_ERROR_MESSAGE` bags full). Small.

### 4.5 Prices: a bridge to price addons

- **One price interface, several providers.** `price(itemKey) → copper or nil`, with a provider name and a "how fresh" hint.
  - Built in: **vendor** (`GetItemInfo` sell price), always available.
  - Bridges (optional, each behind its own adapter, loaded only if that addon is present): **Auctionator** first (installed here, and it has a public price API), then TSM and others as users ask.
  - The user picks the provider for "market value"; a fallback chain is allowed (Auctionator → vendor).
- **Market value is computed, never stored.** Because every looted item is keyed (§4.3), "what is this week's loot worth at today's prices" is `Σ quantity(item) × price(item)` at query time. Changing the provider changes every number consistently, with no data rewrite. The cost: values for items past the cap (`other`) are unknown, so the display says "≥".
- **Runs** keep their full item list, so a run's market value can be shown at today's prices, and optionally frozen at stop ("worth at the time").

### 4.6 Item attributes: one key, many classifiers

The stored key is small; the classifiers live in a lookup table. This is the classic star-schema split: the counter is the fact table, the item catalog is the dimension table, and filters and targets work on any attribute.

**Item key:** the **numeric item ID** from the item link (`item:14047:…`), stored as a number. No names, no strings, no variant. Names come from `GetItemInfo(id)` at display time, in the player's language. Variants (random suffix, bonus IDs) are left out for now; FM-10 lists the options for adding them back, and FM-9 probes what Forever's links carry.

| Attribute | Example | Source |
|---|---|---|
| Rarity | Poor, Common, Uncommon, Rare, Epic | `GetItemInfo` quality |
| Class › subclass | Trade Goods › Herb; Armor › Mail | `GetItemInfoInstant` class and subclass IDs (the AH taxonomy) |
| Equip slot | Chest, Finger | `GetItemInfoInstant` equip location |
| **Farm category** (ours, more detailed) | Herb, Ore, Gem, Cloth, Leather, Elemental, Enchanting, Meat, Fish, Recipe, Rep token, Raid material, Junk, BoE gear | class/subclass + a versioned override table |
| ~~Suffix~~ | "of the Whale" | **not stored** (variants dropped; FM-10). Only live at loot time, e.g. for a future alert |
| Base item | "Glimmering Mail Breastplate" | = the item ID itself: in Classic, suffixed versions share one item ID |
| Appearance (a candidate "family") | items that share a look | transmog appearance ID, if Forever has the data (FM-9) |
| Item set | a named set, if any | `GetItemInfo` set ID |
| Item level, required level | 42, 37 | `GetItemInfo` |
| Bind type | BoE, BoP | `GetItemInfo` |
| Vendor price, stack size | 1g 20s, 20 | `GetItemInfo` |
| Crafting reagent | yes / no | `GetItemInfo` |

- **Naming:** WoW itself calls "of the Whale" a **random suffix**; if variants come back (FM-10), the UI says **Suffix**. "Family" could later mean a user-defined group (e.g. "all Thorium products") or the appearance; keep that word free for it.
- **Catalog:** the client knows every attribute at query time (some need `Item:ContinueOnItemLoad` the first time). We keep a small cache of attributes for items we've seen in Hard Counters' saved data, so displays work instantly and exports and a future companion app can read them.
- **What this enables:** filters ("Uncommon Mail armor looted this week"), targets ("20 Thorium Ore", "1 stack of Black Lotus"), groupings by any attribute, all over the one `Looted items` counter. Suffix filters ("of the Whale") wait for FM-10.
- **Cost, honestly:** grouping by an attribute is "group by item, then roll up in Lua". That's up to 4,096 rows per query. **Measured in game (r2):** lifetime by item takes 62 ms synchronously (a hitch), and a 7-day by item over packed days, sliced, takes about 14 s of wall time at ~21 fps (LibGranaryDB KNOWN_ISSUES, LG-15). So per-item tables always run async with a progress indicator, and anything the player waits on prefers lifetime/open buckets or the run's own item list. Fine for windows, not for a 0.2 s live widget; live widgets use the stored `quality`/`category` dimensions.

### 4.7 Simple on the surface, deep on demand

Three layers. Each layer is optional; nobody has to open the next one.

| Layer | What the user sees | Phase 1 |
|---|---|---|
| **1. Glance** | The farm stopwatch widget and a bar-feed / minimap entry (today's gold, run rate). Start/stop in one click. Sensible defaults, no setup | ✅ |
| **2. Look** | The Ledger window and the run list/summary: tabs, periods, character vs account, simple filters (rarity, category, zone) | ✅ |
| **3. Shape** | Setup: which counters are on, the stopwatch's headline and readings, price provider, saved views and filters, display choice, targets | Phase 1: toggles and a few choices only. A full view/report builder is **later**; it's a large project of its own |

**Agreed 2026-11-15** ([`../../docs/TRACKERS_AND_BOARDS.md`](../../../docs/TRACKERS_AND_BOARDS.md), FM-14, not built): money and XP counters move to Hard Counters' Basics module, with Farmer supplying their sources as attributors; Farmer's features become trackers (Ledger, Loot, Reputation), off until the player turns them on, with history off by default (the Ledger turns daily history on); the stopwatch becomes Hard Counters' Run board.

Each counter states: capture mode, flow or stock, measures, dimensions (an ordered array with caps), aggregation sets, accuracy and feasibility (`../../docs/PACKS.md` §1.1–1.2).

### 4.8 Phase 1 as built (2026-11-14; offline-tested only, not yet run in game)

Code: `HardCounters_Farmer/` (`Parse.lua`, `Attribution.lua`, `Farmer.lua`, `UI/Ledger.lua`). Only Hard Counters'
public API; the one engine addition it needed was **run readings** (`HardCounters:RegisterRunReading`), so the
stopwatch's numbers are declared as data. Where it differs from the plan above, bluntly:
- **Money:** the `GetMoney` diff is the truth and the ledger always sums to it. A gain nothing explains is *held* for
  2 s for a loot message (the order of `CHAT_MSG_MONEY` and `PLAYER_MONEY` is unknown until FM-5 probes it), then
  becomes `other`. AH income is recognised only from seller invoices (`GetInboxInvoiceInfo`); outbid refunds count
  as `mail`.
- **Loot:** own `LOOT_ITEM_SELF(_MULTIPLE)` lines only (pushed and created items are not "looted"). The bag-diff
  cross-check is **not built** (FM-11). Uncached items wait for `GET_ITEM_INFO_RECEIVED` (bounded at 200).
- **XP:** the `UnitXP` diff across at most one level-up (also when `UnitLevel` lags a ding); several levels at once
  are dropped rather than guessed.
- **Reputation:** increases only ("Reputation gained"); faction keyed by ID when the faction list knows the name,
  else by its (localized) name. Collapsed faction headers may hide IDs.
- **Prices:** vendor value is stored at loot time; the price interface and the Auctionator bridge (FM-7) are not
  built yet. The item catalog cache (§4.6) is not built: Farmer has no SavedVariables, and HC-11 keeps it out of
  Hard Counters until a second pack needs it (FM-12).
- **Item categories:** retail item class/subclass numbers mapped to 21 stable keys (`Parse.CATEGORIES`), plus an
  override table for FM-6 content data.

### 4.9 On Hard Counters' trackers and Basics (built 2026-11-15, v2 M3/M4; FM-14)

Hard Counters v2 changed what Farmer owns ([`../../../docs/TRACKERS_AND_BOARDS.md`](../../../docs/TRACKERS_AND_BOARDS.md)):
- **Money and XP counters moved to Hard Counters' Basics** as `hc:money.in`, `hc:money.out`, `hc:money.owned` and
  `hc:xp` (same shapes as the table in §4.3, which now describes them there). Basics diffs `GetMoney` / `UnitXP`;
  **Farmer supplies the sources as attributors** (`HardCounters:SetAttributor`): `Attribution.lua` is unchanged and
  its spec still passes; Basics books what an attributor hasn't answered after 5 s as `none`. Gold/h, Net gold/h,
  Gold earned and XP/h are Basics' readings now.
- **Farmer keeps** `hcfarm:loot.items`, `hcfarm:loot.vendorvalue`, `hcfarm:rep`, the Ledger window, the source hints
  (windows, chat money lines, quest turn-ins, repair and mail hooks) and its readings Vendor value, Items looted,
  Best drop and Reputation gained (since FM-17, 2026-11-19, per hour, recent and trend are the tile's "Show as",
  Hard Counters DESIGN §16.9: "Vendor value/h" is Vendor value per hour, and `hcfarm:vendorph` a hidden alias of
  it; Best drop, "%s standing" and "%s in bags" are totals only), and two readings with a parameter (FM-15, 2026-11-18; Hard Counters DESIGN §16.4):
  "%s rep" (one faction, named from the faction list) and "%s looted" (one item, by item id; a tile counts it from
  when it is placed, the open run and stored periods know every item up to their caps); and "%s standing" (HC-33):
  reputation inside the current standing, with the standing's size as its target, for a bar (reads
  `C_Reputation.GetFactionDataByID`: the function and its fields exist on Forever, probed 2026-11-18; the bar
  itself is unseen); and "%s in bags" (HC-34, 2026-11-18): how many of one item are in the bags now, asked of the
  game (`C_Item.GetItemCount`, probed the same day), no counter and no history; with a target on the tile it is a
  goal ("143 / 200"). The item for it and for "%s looted" is picked by dragging it from the bags onto a board, or
  from the last 20 items looted (Hard Counters DESIGN §16.4 "As built (HC-34)").
- **Trackers, all off and New** (user, 2026-11-15): **Ledger** (Basics' money counters, `needsHistory = "daily"`:
  switching it on turns daily history on for them), **Loot**, **Reputation**. Every source declares `feeds`, so
  with all three off Farmer's loot and reputation listeners are unregistered; its money hints run while Basics
  counts money or XP. The Ledger window shows "The Ledger is off" and a button instead of numbers while it is off.
- **Old data:** `hcfarm:money.in/out/owned` and `hcfarm:xp` are no longer registered; their saved data (only the
  developer's test runs) shows in Hard Counters' Trackers window under "Not loaded", with Delete.
- **Merges and names (2026-11-24; Hard Counters DESIGN §16.4 "As built (2026-11-24)"; not seen in game).** Ids are
  unchanged.
  - **Items looted** (`hcfarm:items`) takes an optional item (`param.optional`, "Any item"): none counts every item,
    as before; one item counts from when its tile is placed. "%s looted" (`hcfarm:looted`) is folded into it: hidden,
    its tiles move there with their item, and `HC:Reading("hcfarm:looted", scope, item)` still answers.
  - **Reputation gained** (`hcfarm:rep`) takes an optional faction ("Any faction"); "%s rep" (`hcfarm:repwith`) is
    folded into it the same way.
  - Renamed: **Loot vendor value** (was Vendor value; per hour "Loot vendor value/h"), **Best drop (vendor price)**,
    **Standing progress: %s** (was "%s standing": the reputation inside the current standing, not the standing),
    **In bags: %s** (was "%s in bags"). The last two read "Standing progress: pick a faction" and "In bags: pick an
    item" in lists until one is picked. The view `hcfarm:gold.today` is titled "Gold in today".
  - The money and XP readings Farmer's attributors feed are Hard Counters Basic's: **Gold in** (was Gold earned) and
    **Gold out** (new) take a set of sources or sinks on the tile, which replaces "Gold from %s" and "Spent on %s";
    **XP gained** takes a set of sources (kills and quests are what Farmer books).

### 4.10 The Fishing basket (the user, 2026-11-25; built the same day, not seen in game)

The user: a resettable "Fishing Basket" board that counts the fishable items in a run, the fish in the bags and the
fish looted, with a percentage breakdown of the catch.

- **Counter** `hcfarm:fish.caught` (flow, items; dimensions `fish` (item id, cap 200: small, so every catch is kept
  per character and per board timer) and `zone`; `runBreakdowns = { "fish" }`). **Tracker** "Fishing" (Farming,
  off by default, like every pack tracker).
- **What a catch is:** your own loot line (`CHAT_MSG_LOOT`, parsed as Loot does) while a fishing bobber's loot window
  is open, or up to 2 s after it closes (auto loot). The bobber: `IsFishingLoot()` at `LOOT_READY`/`LOOT_OPENED`;
  without it, loot that opens while your Fishing channel runs or within 2 s of it ending (Fishing by spell id,
  Classic ranks and later, or by the name of spell 7620). Opening a fished clam or chest is not a catch. Unverified
  on Forever: `IsFishingLoot`, and the order of the loot events against the chat lines with auto loot.
- **Readings:** "Fish caught" (`hcfarm:fished`, all or one catch, every period, per hour) and "Fish in bags"
  (`hcfarm:fishbags`, now: one catch's bag count, or the sum over every item this character has fished, from
  `HC:CounterMembers`, new public API). Both `mixList`: their mix tile lists each catch with count and share (new
  in Hard Counters: the mix's one-line legend could not hold item names with counts).
- **Board** "Fishing basket" (Activity): Fish caught (large, sparkline), Fish/h, Fish in bags, then the two list
  mixes. The board's timer is the run; Reset empties the basket.
- **Casts and timing (0.3.0-beta3; the user: "count failed casts too ... timing counts for cast durations").** A cast
  is one Fishing channel of yours (`UNIT_SPELLCAST_CHANNEL_START`). **Caught:** a bobber's loot opens during the
  channel or up to 2 s after it ends (either order). **Got away:** 2 s pass after the channel's end with no bobber
  loot (a `C_Timer.After`), or a new cast starts first. A cast the game refuses never starts a channel and isn't
  counted. Counters: `hcfarm:fish.casts` (every cast, 1 each), `hcfarm:fish.missed` (the misses: a counter of
  their own, so the catch rate is two plain totals that any window serves), `hcfarm:fish.wait` (a catch's seconds
  from the cast to the click, measures sum, count, max, `runLive = { max = true }` so a board's timer keeps the
  longest). Readings: Fishing casts, Got away, Catch rate (compute), Average wait for a bite (measure avg; run and
  session only: storage avg unproven), Longest wait for a bite (max; the board's timer or history), Time waiting
  for bites (sum, duration). **No fastest bite:** windows keep a flow's max, never its min. The board gained Fishing
  casts, Got away, Catch rate, Average wait (halves) and Longest wait (line) between Fish in bags and the mixes.
  Unverified on Forever: that a Fishing cast fires `UNIT_SPELLCAST_CHANNEL_START/STOP` for the player with the
  spell id, and the order of the channel's end against the loot window.

## 5. Rules

The rules for pack authors in `../../docs/PACKS.md` §3 apply in full: no arithmetic on possibly secret values, no per-event allocation, polling only through Hard Counters' scheduler, declare everything up front, privacy, label estimates, never persist creature GUIDs, log through Hard Counters' logger.

Farmer-specific additions:
1. **Localized chat parsing only.** Build every `CHAT_MSG_*` pattern from the client's global strings (`LOOT_ITEM_SELF`, `YOU_LOOT_MONEY`…), never from English literals.
2. **Cross-check every chat-derived number** against a state diff (`GetMoney`, bag counts, XP, reputation) where one exists, and count disagreements as a health metric.
3. **Spend dimension caps deliberately.** `item` is the one deliberately large dimension (§4.3; cap 4096); keep every other dimension small, and never key a dimension on anything that grows without bound (player names, timestamps, whole item links).

## 6. Development setup

Follow `../../docs/DEV_SETUP.md`:
- Code and git on Windows; lint (luacheck) in WSL.
- Load the pack into the game through a directory junction; iterate with `/reload`, BugSack and screenshots.
- Pure helpers (chat-pattern builders, item categorization) get busted tests. The rest is verified with in-game checklists.

## 7. Open questions

1. ~~Which farm targets make the first cut?~~ Decided 2026-11-14: Ledger and run report first (§4).
2. ~~Farming runs?~~ Decided: manual runs, in Hard Counters, as a time range with snapshot diffs (§4.2).
3. ~~Does an open run survive logout?~~ It survives `/reload` (decided). Logout: proposed **pause at logout, ask at next login** ("Resume run X or stop it?"); the user isn't sold on runs spanning logouts, so judge it once it can be tried (`../../docs/DESIGN.md` §5.1).
4. How many past runs to keep (proposed: 200; review queued as HC-10), and whether a run can be exported as a string.
5. ~~Market value?~~ Decided: a price interface with optional bridges, Auctionator first; market value computed at query time (§4.5).
6. Item cardinality: all items keyed uniformly (§4.3) with the r2 cap of 4,096. Check `Stats()` overflow counts on real loot (FM-2).
7. Splits: manual only, or also automatic on zone change and instance reset?
