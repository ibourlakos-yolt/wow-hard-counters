# Hard Counters — research notes (2026-11-13)

Compiled from four web/source research passes plus inspection of the local `_forever_` install.
Items marked **[unverified]** must be checked in game before code depends on them.

## 1. Target platform: WoW Forever

- *World of Warcraft: Forever* — Blizzard's official "Classic+", codename **Camelot**. Announced 2026-09-12, live 2026-11-04. Reimagined original Azeroth, level cap 60, new zones/dungeons/raids/race. Permanent product, not seasonal.
- **Runs on the Mainline (retail 12.x) engine**, not the Classic Era 1.15 client. Blizzard: Forever "shares Mainline WoW's UI architecture, including the vast majority of APIs available in 12.1.5".
  - https://warcraft.wiki.gg/wiki/Patch_1.60.1/API_changes/notes
  - https://warcraft.wiki.gg/wiki/Patch_1.60
- Local install: `C:\Program Files (x86)\World of Warcraft\_forever_\`, client 1.60.1.70888, `## Interface: 16001`.
- Flavor detection: `WOW_PROJECT_ID == WOW_PROJECT_CAMELOT` (= 18). There is no `WOW_PROJECT_FOREVER`.
- TOC: the client accepts `_Forever.toc` or `_Camelot.toc`, then falls back to `_Mainline.toc`, then the unsuffixed TOC. `## AllowLoadGameType: forever` is supported. https://warcraft.wiki.gg/wiki/TOC_format
- Patches: only 1.60.1 so far.
  - Content roadmap:
    - Dec 9 2026: raid unlocks (likely server-side, no client patch).
    - Winter: Hardcore.
    - Spring 2027 and Summer 2027: content patches.
  - "Group by patch" therefore needs **both** `GetBuildInfo()` version **and** a content-phase label we maintain ourselves.
- API source of truth:
  - Gethe/wow-ui-source `forever` branch (current): https://github.com/Gethe/wow-ui-source/tree/forever
  - Ketho/BlizzardInterfaceResources `forever` branch (slightly stale).
  - In game: `/api` (Blizzard_APIDocumentation ships) **[unverified]**.

### 1.1 Addon restrictions (Midnight "disarmament" applies to Forever)

- **`COMBAT_LOG_EVENT_UNFILTERED` is forbidden** (registering it throws ADDON_ACTION_FORBIDDEN). `CombatLogGetCurrentEventInfo` is absent from Forever API dumps.
  - https://warcraft.wiki.gg/wiki/COMBAT_LOG_EVENT_UNFILTERED
- **Secret values:** many combat values can be displayed (`SetText`, `StatusBar:SetValue`) but not compared or used in arithmetic. Guard with `issecretvalue` / `canaccessvalue`. `C_RestrictedActions.IsAddOnRestrictionActive` and the `ADDON_RESTRICTION_STATE_CHANGED` event report when restrictions are active.
- **Damage/healing source:** `C_DamageMeter` (Blizzard's built-in meter).
  - Functions: `GetCombatSessionFromType/ID`, `GetCombatSessionSourceFromType/ID`, `GetAvailableCombatSessions`, `GetSessionDurationSeconds`, `IsDamageMeterAvailable`.
  - Events: `DAMAGE_METER_COMBAT_SESSION_UPDATED`, `DAMAGE_METER_CURRENT_SESSION_UPDATED`, `DAMAGE_METER_RESET`.
  - Meter types: DamageDone, Dps, HealingDone, Hps, Absorbs, Interrupts, Dispels, DamageTaken, AvoidableDamageTaken, EnemyDamageTaken.
  - Calls are `SecretWhenInCombat`, so read totals **after combat**. Meter authors report some fields still secret or nil afterwards **[unverified on Forever]**.
  - https://warcraft.wiki.gg/wiki/Category:API_systems/DamageMeter
- `PARTY_KILL` / `UNIT_DIED` are `SecretWhenUnitIdentityRestricted`. Kill and death counting is **[unverified]**.
- Creature GUIDs are obfuscated and stable only within a session, so never persist them as keys. Use NPC names or IDs only if they are obtainable unobfuscated **[unverified]**.
- Fall damage is reportedly not reported to addons any more; one addon infers it from airtime plus health lost.
- Trial accounts can't send addon messages. EMOTE chat needs a hardware event. Lua `require` was renamed to `import`.
- Present in the Forever API: `C_Timer`, `UnitPosition`, `C_Map.GetPlayerMapPosition`/`GetBestMapForUnit`, `GetUnitSpeed`, `IsFlying`/`IsMounted`/`IsSwimming`, `UnitOnTaxi`, `GetMoney`/`PLAYER_MONEY`, `PLAYER_XP_UPDATE`, `C_AddOns`, Line widgets (`CreateLine`), the modern Settings API, `C_EncodingUtil` (CBOR, deflate, Base64, JSON) **[unverified at runtime]**, `C_AddOnProfiler`.
- `UnitPosition` / `GetPlayerMapPosition` inside instances is likely nil or restricted **[unverified]**.
- Achievement **statistics are readable on Forever** (StatPoker and Forever Statistics import them), so lifetime totals from before install can be imported.
- Locally observed: AltsForever notes Forever uses retail's trait talent system (`CamelotCombat` config type) and has `C_Timer`.

## 2. Competitive landscape

| Addon | What | Gap for us |
|---|---|---|
| AutoBiographer (181K dl, Forever) | Very broad Classic-style stats: damage/heal, kills by type, deaths by source, money, time by state, distance by mode, map replay | Organized by level/journal, not calendar or patch. No counter API. No LDB. |
| **Forever Stats** (new, Retail+Forever) | Lifetime stats, charts, alt comparison, records and streaks, weekly/yearly journal, CSV, farming panel | **Closest rival.** No public API, no distance. |
| Azeroth Odometer (Forever) | Distance by mode, milestones, LDB, share command | Distance only |
| Accountant Classic (979K dl, Forever) | Gold in/out by source, day/week/month/year | Gold only, no charts |
| MoneyLooter / Haul / LootRun | Live gold/hour with smoothing and item valuation | Session-only |
| Syyke's Stats (Classic/TBC) | Jumps, kills, deaths, hearths, gold; daily / lifetime / best day | No Forever, no API |
| Journey Tracker (Forever) | Level snapshots, web "Wrapped" recap | External site, ends at 60 |
| Details! / Skada / Recount | Combat meters | No lifetime totals |
| quantify (abandoned 2020) | Modular stats with time segments | Shows demand for segments and sortable tables |

**Ground nobody holds:** a public counter/visualization API + calendar/patch scopes + account-wide totals + live widgets, charts and a recap, in one framework. The Forever market is fragmented into single-purpose addons.

Sources:
- https://www.curseforge.com/wow/addons/autobiographer
- https://www.curseforge.com/wow/addons/forever-stats
- https://www.curseforge.com/wow/addons/azeroth-odometer
- https://www.curseforge.com/wow/addons/accountant-classic
- https://www.curseforge.com/wow/addons/moneylooter
- https://www.curseforge.com/wow/addons/syykes-stats
- https://us.forums.blizzard.com/en/wow/t/what-addon-do-u-wish-forever-had/2387005

## 3. Candidate counters (evidence: B = Blizzard Statistics panel, R = Blizzard Forever beta recap, A = an existing addon tracks it, F = forum request, I = inferred)

- **Economy:**
  - Gold looted, quest, vendor and mail (B, A)
  - Repairs (A)
  - Travel, postage, training, barber (B)
  - AH sales, purchases and lost deposits (A)
  - Most gold owned (B)
  - Gold/hour, raw and with item value (A, F)
  - Gold per zone (A)
- **Travel:**
  - Distance on foot, mounted, swimming, flying, flight path and as a ghost (A, R)
  - Boats, zeppelins, trams (A)
  - Hearthstones (B)
  - Flight paths taken (B)
  - Portals and summons (B)
  - Longest run, top speed, best day (A)
  - Falls (A)
- **Combat (restricted on Forever; see 1.1):**
  - Damage and healing done and taken (A)
  - Top hits and crits (A)
  - Kills by type and NPC (A, R)
  - Interrupts and dispels (A)
- **Deaths:**
  - Total and by source (A)
  - "Nemesis" (R)
  - Falling, drowning and fatigue deaths (B)
  - Streak without dying (A)
- **Time:**
  - Played per day, week and month (A)
  - Per zone (A, R)
  - AFK, combat, rested, dead, flying, mounted (A)
  - XP/hour, time per level (A)
- **Quirky:**
  - Jumps (A, R; the fun stat in Blizzard's recap)
  - Bag opens (F)
  - Emotes (B)
  - Chat messages (A)
  - Fish caught, clams opened, chests looted (B, R)
  - Consumables used (B)
  - Duels (A)
  - Players grouped with (R)
  - Items by quality (A)
- **Progression:**
  - Quests completed and abandoned (B, R)
  - Levels gained (R)
  - Dungeon clears (A, F)
  - Reputation (A)
  - Rares (A)

### Visualization expectations
- Movable, pausable live readouts with smoothed rates (MoneyLooter).
- An LDB feed for Titan Panel, ElvUI and others.
- "Compared to yesterday" and "best day" records and streaks.
- Line chart of gold over time; daily gain/loss bar chart; comparison across alts.
- Milestone toasts with real-world comparisons.
- A "Wrapped"-style recap. Blizzard's own beta recap used share cards and percentiles.
- Sortable tables, CSV export, a chat share command.
- **Privacy:** players dislike exposing gold history, so data stays local and sharing is opt-in.

## 4. Libraries and tooling

- **Ace3:** maintained (commit 2026-10-28), Forever supported. Limited BSD licence. https://github.com/WoWUIDev/Ace3
  - Use: LibStub, CallbackHandler, AceDB, AceDBOptions, AceConfig + AceConfigDialog, AceLocale, AceEvent, AceTimer.
  - Skip: AceSerializer, AceComm.
  - Keep Ace types out of the public API.
- **LibDataBroker-1.1:** frozen since 2009 but the universal standard; publish counters as LDB data objects.
- **LibDBIcon-1.0, LibSharedMedia-3.0:** maintained, Forever supported.
- **Charts:**
  - Native `CreateLine` plus pooled textures. Reference: Details' `Libs/DF/charts.lua`.
  - Alternative: LibGraph-2.0 *Revived* (MIT, maintained, Forever flavor): https://www.curseforge.com/wow/addons/libgraph-2-0-revived
  - The original LibGraph-2.0 is unmaintained.
- **Storage:**
  - Native `C_EncodingUtil` on Forever. Fallbacks: LibSerialize (maintained, MIT) and LibDeflate (stable, unmaintained).
  - SavedVariables load time scales with the number of table entries, and 14–40 MB files cause long logins.
  - Mitigations:
    - Bucket by integer day keys.
    - Roll up day → week → month and prune raw data.
    - Use columnar numeric arrays.
    - Intern string IDs.
    - Compress cold history into one string per period.
  - No maintained query or index library exists; hand-roll indexes (reference: TSM LibTSMUtil).
- **Performance:**
  - `C_AddOnProfiler` (always on). Viewers: AddonUsage, `debugprofilestop()`.
  - Use `C_Timer.NewTicker` (0.2–1 s) rather than OnUpdate.
  - Hot path: dispatch tables, no per-event allocation, `wipe()` and reuse tables.
- **Dev:**
  - Ketho VS Code WoW API extension (LuaLS annotations; retail annotations mostly apply).
  - luacheck 1.2.0 with a WoW std.
  - busted 2.3.0 on Lua 5.1 with our own API stubs.
  - wowless (headless FrameXML), WoWUnit (in-game tests).
  - BugSack and BugGrabber (Forever supported).
  - DevTool is **archived**; use `/tinspect`, `/fstack`, `/etrace`, `/dump`.
- **Release:**
  - BigWigsMods/packager ≥ v2.6.0 supports Forever; v2.7.0 is current.
  - Game type `forever` (alias `camelot`). It generates `_Camelot.toc` and recognizes the `_Camelot` suffix only, not `_Forever`.
  - CurseForge game version type ID 88568. Wago key `forever` (accepts `_Forever`/`_Camelot`). WoWInterface does not support Forever yet.
  - GitHub Actions with `fetch-depth: 0`. Secrets: `CF_API_KEY`, `WAGO_API_TOKEN`.
  - Localization via the CurseForge tool and `@localization@` tokens.
  - Versioning: git tags `vX.Y.Z`.
  - https://github.com/BigWigsMods/packager

## 5. Damage-meter architecture → Hard Counters

Studied Details! (master 2026-11-09), Skada (zarnivoop midnight branch; bkader Classic), and Recount. Clones are in the session scratchpad (temporary).

| Damage meter | Hard Counters |
|---|---|
| Subevent handler / `RegisterForCL` | **Source adapter** (event, poll, `C_DamageMeter`, CLEU on Classic) → `Emit(counterId, value, dims)` |
| Actor / spell / target | **Dimensions** on a counter (mode, source, zone, item…) with capped cardinality (top-N + "other") |
| Segment (current / overall / boss / trash) | **Scope instance** (this login, day, week, month, patch/phase, zone visit, user run, lifetime; character / account) |
| Skada `DispatchSets` | **Scope fan-out at capture**: one emit increments every active scope bucket |
| Mode / attribute | **View** = counter + scope + group-by dimension + aggregator (sum, count, max, rate) |
| Window / feed / statusbar plugin | **Sink**: widget, summary, chart, LDB, chat report |
| Details custom display scripts | Derived counters and queries |

Lessons:
1. Counter definitions should be declarative.
2. The capture hot path never allocates. Format and sort at display time only.
3. Cap memory per scope. Time series are opt-in and coarse (1 s live; minute or hour persisted). Roll calendar data up.
4. Persist plain tables, no metatables (Details' strip/restore is fragile). Keep history bounded and pinnable.
5. Values can be **pending / secret / unavailable**. Fold combat values into scopes after combat.
6. Track wall time **and** active time per scope so any view can show rates.
7. Sinks consume generic dataset rows `{id, label, value, valuetext, icon, color}` (Skada). Drill-down is a nested view. Redraw only dirty sinks on a 0.2–0.5 s throttled timer.
8. Plugin lifecycle callbacks (`OnScopeStart`, `OnScopeComplete`, `OnReset`). Each plugin gets a namespaced, versioned SavedVariables subtable with migrations.
9. Version the API with a semver-ish major/minor plus capability probes (`Supports("series")`), not a single integer. Use LibStub `HardCounters-1.0` with a MINOR, CallbackHandler events, and `addon:name` namespaced IDs. Never expose SavedVariables tables.
10. Pain points to avoid:
    - A monolithic parser.
    - A container per stat type.
    - Unbounded per-second series.
    - Capture coupled to the model. Every retail meter had to be rewritten when CLEU was removed.

API pattern references:
- DataStore (core + `DataStore_*` modules): https://github.com/Thaoky/DataStore
- Skada API: https://github.com/zarnivoop/skada/blob/midnight/API.md
- Details plugins: https://github.com/Tercioo/Details-Damage-Meter
- TomTom (small public facade).

## 6. Competitor teardown (second pass, source read where public)

Read without running it: four GitHub clones and the Forever Stats 0.77.0 package (GPL-3). [V] = confirmed in source or on the listing page.

- **Forever Stats** (2.6K downloads, ~19 releases from Oct 27 to Nov 12, Spanish-first, ~40k-line monolith with 28 modules).
  - Tracks almost everything.
  - Stores day, level and zone buckets; derives week, month and year when you view them. **No patch scope, no LDB.** [V]
  - Reads `C_DamageMeter` after combat (sessions are secret during combat; the game keeps about 30). Probes capabilities and has a `/fstats diagnostico` command. [V]
  - Keeps unlimited detail plus a weekly compressed full-DB backup. A source comment admits a year of data slows login. [V]
  - `FS:NewModule` exists but is undocumented, and each module stores its own data shape. [V]
  - Appears AI-assisted (a source comment refers to a CLAUDE.md file). Don't compete with it on breadth.
- **Journey Tracker** (13.9K, Forever-only).
  - Per-level and per-session journal. Imports Blizzard statistics via `GetStatistic`.
  - Recap and comparison happen on an external website (journeytracker.dev).
  - Skips CLEU when `CombatLogGetCurrentEventInfo` is absent; turns secret values into nil.
  - No API.
- **Accountant Classic** (979K, very active).
  - Gold only: session, day, week, month and year plus the previous of each, and total. All-characters view, LDB feed.
  - 2.30.02 added a gold ledger by character × day × category with hour and zone breakdowns ("groundwork for an upcoming feature", probably charts).
  - Crashed on a secret `UnitIsAFK` value (fixed Nov 12).
  - No API.
- **quantify** (abandoned): path-addressed stats with segments and LibGraph charts. Day key is `date("%b%d")` with no year (a bug). Modules register through an open table. Depends on CLEU, so dead on Forever.
- **AutoBiographer** (181K): event journal and per-level stats. No day/week view, no API.
- **Statistical**: the only documented API, and it's read-only getters.
- **DataStore** (4.5M): third-party modules need the author's consent, and "authorized modules: none".
- **Other Forever addons:**
  - Saga: Wrapped-style recaps for month, year and all time; this week vs last week.
  - PlayerGraphs: time series across alts.
  - Forever IRS: 25.8K downloads.
  - Forever Echoes: lifetime totals merged across Retail and Forever.
  - Azeroth Odometer: LDB feed and a guild ranking; estimates speed during combat because the real value is secret.
  - **None of them has a public API.**

## 7. Unmet demand

Reddit and CurseForge comments were unreachable, so direct player-voice evidence is thin. Supply-side evidence is strong.

- **Developer duplication (strong):**
  - At least 6 distance and step counters and 216 "gold tracker" results, each with its own storage, session logic, charts and export.
  - At least 5 bespoke paste-to-website export pipelines.
  - No LibHistory, LibStats or time-series library exists. LibDataBroker carries live values only. LibGraph needed a community revival (Oct 2026).
- **Restrictions (strong, technical):**
  - Arithmetic or comparison on a secret value taints execution, and pcall does not protect against it (Recount Revived).
  - Epic Damage Meter polls every 0.3 s for up to about 9 s after combat, until values stop being secret.
  - Nobody has a verified recipe for keeping combat totals across sessions.
- **Fragile data (moderate):**
  - The Forever beta lost SavedVariables at login (fixed in build 70009).
  - Murloc Census Bureau avoids logout-time saves because one crashed the client; it updates its saved tables every 15 s instead.
  - Rarity and AutoBiographer have data-loss and slowdown issues.
- **Alt comparison and account totals (moderate):** inferred from download counts (Forever IRS, Alts Forever).
- **Recaps and periods (moderate, crowded):** Blizzard's beta-only recap showed demand; Saga and Journey Tracker filled it.
- **Fun custom counters (moderate, small sample):** forum wishes for a /train emote counter, gnomes punted, bag opens, and a Statistics search box.
- **Privacy:** rivals market "no network" and anonymised exports. Needed to compete, not a differentiator.
