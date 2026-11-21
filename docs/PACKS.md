# Packs: contract, rules for authors, and counter ideas

> **Status:** moved here on 2026-11-14 from the former `HardCountersPacks` design, when that repo became `packs/Farmer` (the farming pack only). Hard Counters owns the pack contract, so it lives in this repo. Statuses are **desk research only** (2026-11-13) unless `api-surface.md` says otherwise.
>
> - The farming counters are designed in `packs/Farmer/docs/DESIGN.md` and listed exhaustively in `packs/Farmer/docs/FARM_TARGETS.md`. Rows below that are about farming (gold, XP, reputation, loot, fishing) are kept for their evidence column; the Farmer docs supersede them.
> - Everything else here is an **idea for a later pack**, not a plan.

---

## 1. What a pack is

Packs are **collections of counters** built **only on Hard Counters' public API**, exactly the way a third-party author would build one. They serve two purposes:
1. **Content:** the statistics players actually see.
2. **Testing the API on ourselves:** if a pack needs anything private, the API is incomplete. Fix the API; never reach into internals. The API stays "experimental" until 2–3 packs have shipped against it.

### 1.1 Pack structure

- **One addon per area** (ideas; only `HardCounters_Farmer` exists): `HardCounters_Economy`, `HardCounters_Travel`, `HardCounters_Time`, `HardCounters_Progression`, `HardCounters_Fun`, `HardCounters_Combat`, `HardCounters_Example`.
- **TOC files:**
  - `## Dependencies: HardCounters`
  - `## Interface: 16001`
  - `## Group: HardCounters` (optional) nests the pack under Hard Counters in the game's AddOn list. The client
    often guesses the group from the folder name and dependencies; an explicit value must match the folder name
    `HardCounters` exactly, or the pack drops back to the top level. The packs in this repo set it.
  - `## IconTexture:` (optional) the icon beside the pack in the AddOn list; without one the client shows a red
    question mark. The packs in this repo use Hard Counters' own, `Interface\AddOns\HardCounters\Media\Icon`;
    a pack with its own icon ships it in its own folder.
  - `_Forever.toc` (or Interface 16001 in a plain TOC)
  - `## LoadOnDemand: 1` where possible. Hard Counters loads the packs the user has switched on.
- **What a pack contains:**
  - source registrations (events, polls, hooks)
  - counter definitions
  - optional pack-specific formatters and default views
  - localization (enUS first)
- **No SavedVariables of its own.** Data lives in Hard Counters' LibGranaryDB root, under the pack's namespace (`<pack>:<counter>`).
- **One repo per pack** for now: `packs/Farmer` is the first. Revisit if packs multiply.
- **Every counter states:**
  - capture mode
  - flow or stock
  - measures
  - dimensions and aggregation sets
  - accuracy
  - **feasibility status**, linked to [`api-surface.md`](api-surface.md)
- **Storage limits come from LibGranaryDB** (see [`DESIGN.md`](DESIGN.md) §4): `dimensions` as an ordered array, `cap` ≤ 4096 (LibGranaryDB r2) with first-N-then-`other`, ≤ 16,384 tuples, ≤ 6 dimensions, ≤ 8 aggregation sets.

### 1.2 Feasibility policy

Every counter is one of three:
- ✅ feasible
- ⚠️ degraded: an estimate, labelled in the UI
- ⛔ infeasible: documented and dropped

Statuses below are **desk research only** (🟡 reported, ❓ unverified) until the diagnostics module or probe addon has tested them in game. **No single counter is critical.** If the API blocks something and no workaround fits the CPU, memory or frame budget, we document it and move on.

**Evidence key** (from [`research.md`](research.md) §3):
- **B**: Blizzard's Statistics panel tracks it
- **R**: shown in Blizzard's Forever beta recap
- **A**: an existing addon tracks it, which shows demand
- **F**: asked for in a forum thread
- **I**: inferred

## 2. Counter ideas by area (from the former packs catalog)

### 2.1 Economy (`HardCounters_Economy`)

| Counter | Capture | Kind | Measures | Dimensions | Evidence | Status |
|---|---|---|---|---|---|---|
| Gold earned | `PLAYER_MONEY` + `GetMoney()` diff, with the source inferred | flow | sum, count, max (single gain + ctx) | source {loot, quest, vendor, mail, AH, trade, other}, zone | B, A | 🟡. The source is **inferred** from context: `CHAT_MSG_MONEY` (loot), `QUEST_TURNED_IN`, merchant, mail and AH windows open. Label inferred sources. |
| Gold spent | same | flow | sum, count, max | sink {repair, vendor, training, travel, postage, AH, barber, other} | B, A | 🟡. Repairs have **no Blizzard statistic** (a gap); spent while the merchant window is open after `RepairAllItems` = repair (inferred). |
| Gold owned | `GetMoney()` snapshot | **stock** | last, min, max, twa | — | B ("most gold owned") | 🟡 |
| Gold per hour | derived (rate window + per active time) | derived | rate | source | A, F (MoneyLooter) | 🟡. The speedometer showcase. |
| Grey items vendored (value) | merchant sale (`MERCHANT_SHOW` + bag diffs) | flow | sum, count | — | I | ❓ |
| AH sales, purchases, lost deposits | mail and AH events | flow | sum, count | — | A | ❓. Partly overlaps with Auctionator. |
| Item value looted (via Auctionator price API) | loot + price lookup | flow | sum | quality | A (Haul, MoneyLooter) | ❓. Optional dependency **behind an adapter**. |

### 2.2 Travel (`HardCounters_Travel`)

| Counter | Capture | Kind | Measures | Dimensions | Evidence | Status |
|---|---|---|---|---|---|---|
| Distance | poll position (adaptive 2–5 Hz) | flow | sum, max (longest non-stop run + ctx) | mode {foot, mount, swim, fly, glide, taxi, ghost, vehicle/boat}, zone | A, R ("yards travelled") | ⚠️ expected: no position in instances (❓); taxi ❓; teleports filtered |
| Top speed | poll `GetUnitSpeed` | stock-like extreme | max + ctx | mode | A | 🟡. May be secret in combat (Odometer estimates in combat). |
| Flight paths taken | `UnitOnTaxi` transitions / taxi events | flow | count | origin→destination? (cap) | B | 🟡 |
| Time on taxi | state-duration | flow | sum | — | A | 🟡 |
| Hearthstone uses | `UNIT_SPELLCAST_SUCCEEDED` (player, hearth spell IDs) | flow | count | — | B, A | ❓. Spell IDs secret in combat? Hearths are rarely cast in combat. |
| Portals and summons taken | map jump + spell context | flow | count | kind | B | ❓ (inferred from discontinuities) |
| Falls: count, distance fallen, longest survived | airtime + `IsFalling` polling + health lost | flow / extreme | count, sum, max + ctx | — | A | ⚠️. Fall damage isn't reported to addons, so it's inferred (guild-addons PR #8). |
| Boats, zeppelins, trams | discontinuity + transport detection | flow | count, sum | — | A (Odometer misses these) | ❓ |
| Steps (cosmetic) | derived from foot distance | derived | — | — | A, F | ⚠️ (yards ÷ stride constant; label as fun) |

### 2.3 Time (`HardCounters_Time`)

| Counter | Capture | Kind | Measures | Dimensions | Evidence | Status |
|---|---|---|---|---|---|---|
| Time played | `TIME_PLAYED_MSG` baseline + wall clock between logins | flow (+ baseline stock) | sum | zone, level band | A, R ("hours played") | ✅ `RequestTimePlayed` works (AltsForever); its chat output needs muting |
| Time per state: AFK, combat, resting, dead/ghost, mounted, flying, taxi, swimming, in instance | state-duration | flow | sum, max (longest) | state, zone | A | 🟡 / ❓. `UnitIsAFK` can return a **secret boolean** (Accountant crash), so guard it. |
| Time per zone | zone-change events + wall clock | flow | sum | zone (cap 60 + other) | A, R ("most played zone") | 🟡 |
| Logins, average login length, longest | `PLAYER_LOGIN` / logout | flow | count, sum, max | — | I | 🟡. "This login" survives a `/reload`? (decision) |
| Time to level / per level | `PLAYER_LEVEL_UP` + played time | flow | sum per level | level | A | 🟡 |

### 2.4 Progression (`HardCounters_Progression`)

| Counter | Capture | Kind | Measures | Dimensions | Evidence | Status |
|---|---|---|---|---|---|---|
| XP gained / XP per hour | `PLAYER_XP_UPDATE` diff (+ rested split) | flow | sum, rate | source {kill, quest, discovery, other} via chat parsing | A, R ("levels gained") | 🟡 / ❓ (chat-based source split) |
| Levels gained | `PLAYER_LEVEL_UP` | flow | count | — | R | 🟡 |
| Quests completed / abandoned | `QUEST_TURNED_IN`, abandon hooks | flow | count | zone | B, R | ❓ |
| Reputation gained | reputation events, diffs | flow | sum | faction | A | ❓ |
| Dungeon clears / wipes | instance enter/leave + boss events (`ENCOUNTER_END`?) | flow | count | instance | A, F | ❓. Encounter events may be restricted. |
| Rares killed | ❓ (kill attribution restricted) | flow | count | — | A | ❓ / likely ⛔ |
| Blizzard statistics baseline | `GetStatistic` one-off import | stock baseline | last | statistic | B | 🟡. Gives lifetime values from before install. |

### 2.5 Fun (`HardCounters_Fun`)

| Counter | Capture | Kind | Measures | Dimensions | Evidence | Status |
|---|---|---|---|---|---|---|
| **Jumps** | `hooksecurefunc("JumpOrAscendStart")` (or equivalent) | flow | count, rate | zone | A, R (the recap's headline fun stat) | ❓. **Also the sample pack** (see §4). |
| Bag opens | hook `ToggleBag` / `OpenAllBags` | flow | count | — | F | ❓ |
| Emotes used (/hug, /train…) | hook `DoEmote` | flow | count | emote (cap) | B, F ("/train counter") | ❓ |
| Gnomes punted (/kick-style fun) | emote + target race | flow | count | — | F | ❓ (target info may be restricted) |
| Fish caught | loot after the fishing cast | flow | count, max (biggest?) | zone | B, R | ❓ |
| Clams opened, chests looted | loot source context | flow | count | — | R | ❓ |
| Consumables used (potions, food, bandages) | `UNIT_SPELLCAST_SUCCEEDED` / item use | flow | count | category | B | ❓ |
| Chat messages sent | hook `SendChatMessage` (own only) | flow | count | channel | A | ❓. Privacy: counts only, never content. |
| Duels won / lost | duel events | flow | count | — | A | ❓ |
| Players grouped with | group roster changes | flow | count distinct (cap) | — | R ("camping companions") | ❓. Privacy-sensitive; keep it local and opt-in. |
| Items looted by quality | `CHAT_MSG_LOOT` (own) | flow | count | quality | A | ❓ |
| First epic, first mount… | event + context | milestone | first + ctx | — | A | ❓ |

### 2.6 Combat (`HardCounters_Combat`), the **risky one**

| Counter | Capture | Kind | Measures | Dimensions | Evidence | Status |
|---|---|---|---|---|---|---|
| Damage / healing done and taken, absorbs, interrupts, dispels (totals per fight) | **post-combat harvest** of `C_DamageMeter` sessions | flow | sum, max (best fight + ctx), rate (best DPS/HPS fight) | spell (cap 30 + other), fight kind | A | ❓. Readable after combat? |
| "Top Holy Light" | `combatSpellDetails` single biggest hit? | extreme | max + ctx | spell | user example | ❓ / likely ⛔ for single hits. Fallback: best per-fight spell total or rate. |
| Deaths (own) | `PLAYER_DEAD` | flow | count | zone, cause? | A | 🟡 count / ❓ cause |
| "Nemesis" (NPC that killed you most) | death cause | flow | count | killer | R | ❓ / likely ⛔ (identity restricted, GUIDs obfuscated) |
| Killing blows / kills by type | `PARTY_KILL` (restricted) / XP messages | flow | count | creature type | A, R | ❓ / likely ⚠️ via XP messages |
| Lowest health survived | `UNIT_HEALTH` (secret in combat?) | extreme | min + ctx | — | A | ❓ / likely ⛔ |

### 2.7 Example (`HardCounters_Example`), the template for third-party authors

- Implements **Jumps** (or another tiny hook counter) with copious comments.
- Shows how to:
  - register a source and a counter
  - declare feasibility
  - add a custom formatter
  - suggest default views
- Uses **only** the public API. If it ever needs anything else, the API has a gap.

## 3. Rules for pack authors

1. **Never do arithmetic on possibly-secret values.** Check with the guard helper Hard Counters provides first.
2. **No per-event allocation in handlers.** Reuse tables; emit with varargs.
3. **Polling only through Hard Counters' scheduler**, which applies the adaptive rate, idle detection and pauses during loading screens.
4. **Declare everything up front:** kind (flow or stock), dimension caps and aggregation sets. Don't materialize cross products you don't need.
5. **Privacy:** count, never record content (chat text, other players' names) unless the user opts in. Data stays local.
6. **Label estimates.** Accuracy and feasibility are part of every definition.
7. **Never persist creature GUIDs** (obfuscated per session).
8. **Log through Hard Counters' logger.** Lines are tagged `[Pack:<name>]`. Never `print` directly. A pack's health counters and version appear in its own section of `/hc report` (see [`DESIGN.md`](DESIGN.md) §8).
9. **Every counter belongs to a tracker** (`RegisterTracker`, v2, HC-19). A counter no tracker lists never counts
   (a warning in the diagnostics log). A pack's trackers start **off** (`default = "off"`) and show as *New* in the
   Trackers window; the player switches them on. Declare `needsHistory` only when the tracker makes no sense
   without it (a ledger by day).
10. **Every event a pack listens to goes through `RegisterSource`, with `feeds`** naming the counters it writes,
    so Hard Counters can switch it off when those counters are off: events unregistered, polls paused, hooks
    ignored. A pack's own frames listening to events are a bug: they keep costing while the player has the
    feature off.
11. **Readings, not bespoke displays.** Declare what a player may put on a board with `RegisterReading` (scopes,
    a `rateTitle` when per hour makes sense, a one-line `description`, the `tracker` it belongs to). One reading
    per thing counted: per hour is the tile's calc ("Show as"), not a second reading (HC-51; `per = "activeHour"`
    still works). Boards, tooltips and the Trackers window show it; a reading whose tracker is off reads "off",
    never 0.

## 4. Open questions

1. Load-on-demand packs: does Hard Counters load them from its options, or let the player enable them in the AddOns list?
2. Which quirky counters are worth the hooks? Each hook has a cost and a risk under the restrictions.
3. Where does the sample pack (Jumps, `HardCounters_Example`) live now: in this repo under `examples/`, or its own repo?
