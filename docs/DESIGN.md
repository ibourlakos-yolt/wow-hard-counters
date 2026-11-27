# Hard Counters — design document

> **Status:** v2 built and run in game (2026-11-15: engine, trackers, history, readings, boards, Basics; §14 lists what v1 left out). **Next direction agreed 2026-11-18: §16** (the dream, windows per tile, readings with a parameter, character or account per tile); §16 is not built. Local-only project of Yolt Labs. No publishing for now.
> **Synced with LibGranaryDB r1 on 2026-11-14:** the storage library was built and verified in game under the name **LibGranaryDB** (working name "LibTally"). Library calls below follow its real API; where the library differs from what this design first assumed, the text says so.
>
> **Related documents:**
> - This project:
>   - [`research.md`](research.md): platform facts, restrictions, libraries, competitors, damage-meter architecture, demand.
>   - [`api-surface.md`](api-surface.md): the verdicts on WoW API behaviour.
>   - [`PACKS.md`](PACKS.md): the pack contract, rules for pack authors, and counter ideas beyond farming.
>   - [`TRACKERS_AND_BOARDS.md`](TRACKERS_AND_BOARDS.md): **the v2 design, agreed and built 2026-11-15** (as built: §4.1, §4.2, §5.2, §7.2, §7.3 here): trackers switched on on demand (counters no tracker needs are inactive), history off by default with presets per tracker, one reading API, player-built boards replacing the run panel and the live number, a Basics module (gold and XP per hour) inside Hard Counters, and the wider UX review. Its §5.2 (runs as a manual scope) is replaced by §16.3 here once that is built.
>   - Open work (HC-n) is queued in the developers' working notes, not in this repo.
> - Sibling projects:
>   - `../LibGranaryDB`: the storage library (LibStub `LibGranaryDB-1.0`). **Its `docs/API.md` is the source of truth** for library calls; `docs/SPEC.md` holds the decisions (D1–D20).
>   - `packs/Farmer`: the first pack, farming counters. See its `docs/DESIGN.md`.

---

## 1. Vision

**Hard Counters is a generalization of the damage-meter *engine*, not of damage-meter stats.** Damage meters do four things:
- capture events
- aggregate them into **segments**
- break them down by **actor and spell**
- show **modes** in **windows**, with plugin APIs

Hard Counters does the same for *any* statistic a player might care about:
- gold, distance, time, jumps, quests, records
- combat totals where the API allows

These are viewed by character or account, and across calendar periods, game versions, content phases and lifetime. It's aimed to be the **OLAP of WoW**:
- dimensions with levels
- measures (totals, counts, records, averages, rates, distributions)
- slicing, drill-down and pivoting
- plenty of polished displays

Done within what the game allows.

```
[LibGranaryDB]  ←  [HardCounters]  ←  [Farmer, Character Stats (packs/), third-party addons]
 storage cube       capture engine, views, displays, public API
```

### 1.0 The dream (user, 2026-11-18)

**A wildly user-friendly way to put readings on the UI.** A reading is virtually any numeric value of interest to
the player. It may or may not be stored in history, and it may or may not be on screen as a visual counter: a plain
number, a bar toward a target, a gauge, a sparkline, an odometer (the user: "pretty much all of them").

- **The word is "reading"** (user, 2026-11-18), as in the code. "Tracker" keeps its code meaning: a switchable
  group of counters. Don't use it for a single number.
- **Breadth comes from three places:** packs we ship, readings the player makes in game with no code (pick an item,
  a faction, a source), and other authors through the public API.
- **Casual first, depth behind:** a two-click path for everyone; scopes, history, styles and storage exist but are
  never required.

This is the test for every design choice and queue item: does it put a number the player cares about on screen
more easily? The OLAP side below (pivot windows, export, a companion app) stays possible on the same engine, but
comes after it. §16 is the direction that follows from this.

### 1.1 What sets it apart (from competitor research, 2026-11-13)

**Selling points, ranked:**
1. **An open engine and API.** Register a counter, and periods, measures, displays, the bar feed and export come with it. Nobody else offers this:
   - Forever Stats has an undocumented module hook, with a different data shape per module.
   - DataStore forbids third-party modules.
   - quantify is abandoned.
2. **Measures beyond counts for every counter:** records with context, rates over a time window and over active time. Distributions later (not in LibGranaryDB v1).
3. **Storage that stays small** (LibGranaryDB): rollups, budgets, migrations, and no risky work at logout. Forever Stats admits its own login slowdown.
4. **Visualizations as display plugins** (speedometer, odometer, calendar heatmap, sparkline, record board): any display works with any counter. They're the showcase, not the moat, because rivals can copy any single widget.
5. **Cheap extras:**
   - game-version and content-phase periods (no rival has them)
   - a documented export format
   - the diagnostics module and public `api-surface.md`

**Not selling points, but table stakes** (crowded, so we provide them as generic views): alt and account comparison, "Wrapped" recaps, privacy, breadth of counters. **Do not compete with Forever Stats on breadth.**

## 2. Platform reality (summary; details in research.md)

- **Target:**
  - WoW Forever: Interface 16001, client 1.60.1, `WOW_PROJECT_CAMELOT = 18`.
  - TOC `_Forever.toc` (alias `_Camelot.toc`).
  - Runs on the retail 12.x engine with **Midnight restrictions**.
- **Combat log:** `COMBAT_LOG_EVENT_UNFILTERED` is **forbidden**; registering it raises ADDON_ACTION_FORBIDDEN.
- **Secret values:** many combat values can be displayed but not used in arithmetic or comparisons, and tainted execution isn't catchable with `pcall`.
- **Combat totals:** only through `C_DamageMeter` sessions, read after combat. On Forever this is **unverified**.
- **Obfuscated GUIDs:** creature GUIDs are obfuscated and stable only within one session. Player GUIDs are fine.
- **Position:** likely missing inside instances (**unverified**).
- **Saved data:** SavedVariables are written only on logout, `/reload` or a clean disconnect. A hard crash loses everything since then.
- **Two WoW account folders exist on this machine.** "Account-wide" in game means one WoW account folder.

### 2.1 Feasibility policy (agreed with the user)

Every counter gets a verdict:
- **feasible:** captured directly.
- **degraded:** an estimate, labelled in the UI, with the reason documented.
- **infeasible:** the API blocks it and no workaround fits the CPU, memory or frame budget. Documented in `api-surface.md` with evidence, then dropped.

**Combat is just one example. Do not fixate on it.**

### 2.2 The two hard limits

1. What the game's API exposes.
2. What the saved file can hold and still load quickly.

Everything else is engineering.

## 3. Architecture

```
Game events / polls / hooks / one-off queries
        │
  [Source adapters]  ── capture mode, accuracy, feasibility, secret guard
        │  Emit(counterId, value, dims…, ctx)
  [Counter registry] ── definitions (LibGranaryDB def + capture metadata)
        │  db:Handle(id):Add / :AddCtx / :Observe
  [LibGranaryDB]     ── cube store: grains × aggregation sets × measures, rollups, budgets
        │  db:Query / db:Series / *Async (sliced) / GDB:RateWindow (live, in memory)
  [Views]            ── counter × measure × period × breakdown (+ filter, drill-down, pivot)
        │  generic dataset rows {id,label,value,valuetext,icon,color,ctx}
  [Sinks/Displays]   ── widgets, summary/pivot window, charts, LDB feed, chat report, export
```

### 3.1 Capture modes

Each counter declares one capture mode, plus its accuracy and feasibility.

| Mode | How it works | Example | Accuracy | Idle cost | How it fails |
|---|---|---|---|---|---|
| **push-delta** | The event carries the amount | `CHAT_MSG_MONEY` ("You loot 5 silver"), XP gain messages | Exact | 0 | Missed events (loading screens, before load); messages hidden in instances (unverified) |
| **push-signal + snapshot-diff** | The event only signals a change; read the current value and subtract the last one | `PLAYER_MONEY` then `GetMoney()` | Exact net change; the reason has to be inferred | 0 | Needs a stored previous value; two changes merge into one; the first reading after login is only a baseline |
| **poll-integrate** | Read state every N ms and add up the deltas | `UnitPosition` / `C_Map.GetPlayerMapPosition`, giving distance | **Approximate** (straight lines between readings) | Paid on every reading | Gaps in instances and loading screens; teleports must be filtered |
| **state-duration** | Start a clock on entering a state, stop it on leaving | time mounted, AFK, flying, in combat, on taxi | Exact if both transitions are seen | ~0 | A missed exit inflates the time, so cap it and reconcile at logout or reload |
| **pull-snapshot** | Read on demand | `GetStatistic` (achievement stats), `/played` (`TIME_PLAYED_MSG`), current gold | Exact for that moment | Only when asked | Snapshot only; some calls are throttled; `/played` prints to chat unless suppressed |
| **post-combat harvest** | Read `C_DamageMeter` sessions after combat ends | damage and healing totals | Totals only, if readable | Small | Values may stay secret or nil for seconds after combat (Epic Damage Meter retries every 0.3 s for up to about 9 s); about 30 sessions kept by the game |

**Flow vs stock:**
- push-delta, poll-integrate and state-duration produce **flows**.
- snapshot-diff produces a flow (the delta) **and** can feed a stock (the absolute value).
- pull-snapshot produces **stocks** or baselines.

LibGranaryDB enforces the correct rollup semantics: `Add` on a stock raises, and stocks are never summed across time.

### 3.2 Polling discipline

Polling is the only kind of capture that costs anything while idle. Rules:
- No reading while speed is 0 (`GetUnitSpeed("player") == 0`) or while AFK. Instead, take one confirming reading every few seconds.
- An adaptive rate: faster when flying or mounted, slower on foot. Something like 2–5 Hz, to be tuned against accuracy measured in game.
- Pause during loading screens (`LOADING_SCREEN_ENABLED`/`DISABLED`).
- **Discontinuity filter:**
  - Discard deltas across map or instance changes and teleports (hearthstone, portal, summon, death and release).
  - Discard implausible speeds, i.e. a delta above the maximum possible speed × dt.
- Taxi (flight path) distance comes from position readings too, if available; otherwise estimate it from the flight path's known length (degraded).
- Every polled counter publishes its reading rate, e.g. "estimated (sampled at 4 Hz)".

### 3.3 Secret-value handling

- Source adapters check `issecretvalue` / `canaccessvalue` **before** any arithmetic or comparison. Secret values are deferred (combat values: harvest after combat) or rejected with a counter (`stats.rejectedSecrets`).
- LibGranaryDB guards its own writes too: `Add`/`Observe` return `false` for a secret value (counted in `db:Stats()`, `OnSecretRejected` at most once per 60 s). That is a backstop, not a substitute: our own arithmetic happens before the write.
- Listen for `ADDON_RESTRICTION_STATE_CHANGED` and `C_RestrictedActions.IsAddOnRestrictionActive` to know when restrictions are active.
- **Displays may show secret values only by passing them straight through** (`SetText`, `StatusBar:SetValue`). No needle angles, no comparisons. A speedometer therefore can't be driven by a secret value.

## 4. Counter definitions (Hard Counters' layer over LibGranaryDB)

Hard Counters owns **one** LibGranaryDB root. At `ADDON_LOADED` it calls
`db = LibStub("LibGranaryDB-1.0"):Attach(HardCountersDB, { host = "HardCounters", region = … })`,
then `db:SetEntity(UnitGUID("player"), …)` and a `db:Tick()` ticker. Every counter, from the engine or from any pack, lives on that `db` object. There is no global `RegisterCounter` on the library (SPEC D10). Packs never see `db`; they go through `HardCounters:RegisterCounter`, which passes the storage fields on to `db:RegisterCounter` and keeps the rest.

```lua
HardCounters:RegisterCounter({
  -- LibGranaryDB fields (see ../LibGranaryDB/docs/API.md §3): id, version, kind, unit, measures,
  -- dimensions, aggregations, grains, context, budget, onIncompatible
  id = "hc:travel.distance", version = 1, kind = "flow", unit = "yards",
  measures = { "sum", "count", "max" },
  -- an ordered array: the map form { mode = { cap = 8 }, … } is rejected (Lua tables don't keep key order)
  dimensions = { { name = "mode", cap = 8 }, { name = "zone", cap = 40 } },
  aggregations = { {}, { "mode" }, { "zone" } },   -- only these sets are stored
  context = { max = { "zone" } },                  -- kept with each record
  -- Hard Counters fields:
  title = "Distance travelled", category = "Travel", icon = 132307,
  capture = { mode = "poll-integrate", rateHz = "adaptive", source = "hc:position" },
  accuracy = "estimate",                -- "exact" | "estimate" | "baseline"
  feasibility = { status = "degraded", note = "No position inside instances (unverified)", ref = "api-surface.md#position" },
  formatter = "distance",               -- yards/miles/km per user setting
  defaultViews = { "widget:odometer", "chart:daily" },
})
```

**Storage rules inherited from LibGranaryDB** (they shape every pack definition):
- Every dimension has a `cap` (1..4096 since LibGranaryDB r2 / `API_VERSION` 2; 1..1024 in r1; default 32). The first `cap` members keep their slots **for good**; later members go to `other`. Grand totals stay exact. A counter holds at most 16,384 tuples (r2; 4,096 in r1) (SPEC D16).
- At most 6 dimensions and 8 aggregation sets per counter. Each stored set multiplies the write cost (grains × sets × measures).
- Definitions are data only. Compatible changes (new measures, grains or sets, appended dimensions) re-register freely. Renaming, reordering or removing a dimension, or changing `kind`, needs a `version` bump with `onIncompatible = "reset"`, which **drops** that counter's data.
- Default retention: hour 48 h, **day 90 days** (SPEC D6), week and reset week 2 years, everything coarser forever.
- Idle alts are **parked** (D17): their open buckets are packed, and unpacked on their next write. Account queries still see them.

**Built 2026-11-15** (§4.1; [TRACKERS_AND_BOARDS §2–3](TRACKERS_AND_BOARDS.md)): counters are grouped into player-facing *trackers*; a counter is active only if a tracker that is on uses it. **History is off by default** (Live only); per tracker the player picks Off, Lifetime, Daily or Detailed, mapped onto each counter's grains and retention.

Sources are registered separately, so several counters can share one poll or event handler:

```lua
HardCounters:RegisterSource("hc:position", {
  mode = "poll", tick = adaptiveTick, read = readPosition, emits = { "hc:travel.distance", "hc:travel.topspeed" },
})
```

### 4.1 Trackers, activation and history (built 2026-11-15, v2 M3; TRACKERS_AND_BOARDS §2, §3)

- **Trackers** (`RegisterTracker`) are what the player switches; counters and sources follow (`Core/Trackers.lua`,
  `ns.Reconcile` in `Core/Registry.lua`). A counter is active iff a tracker that is on lists it; `hc:time.active`
  iff any tracker is on. A source with `feeds` runs iff one of them is active: event sources are unregistered from
  the event frame, poll jobs paused (`Job:Pause`), hook wrappers return early.
- **History presets per tracker**, a counter keeping the most any active tracker asks for: `off` (Live only),
  `lifetime`, `daily` (day, the player's week grain, month, year, lifetime; day retention 14/30/90/365 d),
  `detailed` (hour 48 h, day 90 d or more, week and reset week 2 y). The preset's grains are intersected with what
  the counter declares; run-tracked counters always keep lifetime when they keep anything (runs subtract it).
- **Live only** (history off, the default): no LibGranaryDB registration. Emits validate the number themselves and
  feed the counter's odometer (§16.2, HC-29) and the rate window. Runs and the login scope are windows over the
  odometers, so they are exact whatever the history setting; nothing reads storage for them.
- **Every storage registration says `removed = "keep"`** (LibGranaryDB r3): lowering history freezes grains;
  switching a tracker off leaves its counters unregistered at the next `/reload`, so their data is frozen too.
  Within a session a registration can't be undone, so switching off stops writes at once. Delete is the only
  removal (`DeleteTrackerHistory`, `DeleteCounterData`, through `DropCounter`).
- **Choices per AceDB profile:** `settings.trackers[id] = { on, history, days, seen }`; a pack's tracker without an
  entry is *New*. A profile switch reconciles everything.

### 4.2 Basics: gold and XP per hour in Hard Counters (built 2026-11-15, v2 M4; TRACKERS_AND_BOARDS §4)

- `HardCounters/Basics/Basics.lua`, loaded by Hard Counters' TOC after the engine, public API only (it replaces the
  jumps sample of HC-6 as the reference pack). Counters `hc:money.in/out/owned`, `hc:xp` with Farmer's old shapes;
  trackers Gold per hour (money in, out, owned) and XP per hour, **on** for a fresh install (user, §0.3).
- **Sources are diffs** of `GetMoney` / `UnitXP` (with the level-up wrap: across one level the previous level's max
  is known; several levels at once count nothing). The first reading, and the first after a tracker comes back on
  (`HC_TRACKERS_CHANGED`), is a baseline.
- **Attributors** (`SetAttributor`) name the source; Basics hands each change over with a `book` function, books
  the rest as `none` after 5 s (TRACKERS_AND_BOARDS §11.1) and never books more than it handed over. Mail between
  your own characters counts on both sides, gold/h included (Farmer DESIGN §4.1, user's decision).
- Readings: Gold/h, Net gold/h, Gold earned, Net gold, Gold owned, XP/h, XP gained, time to level (computed: XP left
  in the level ÷ XP/h over the same scope) and rested XP (`GetXPExhaustion`, scope now).
- **Migration:** Farmer's `hcfarm:money.*` and `hcfarm:xp` are no longer registered; their data (developer test
  data only) shows under "Not loaded" with Delete.

## 5. Time periods and scopes

- **Character** and **account** (one WoW account folder).
- **Time:** hour, day, week (ISO), reset week (WoW weekly reset, verified in game: Wednesday 04:00 UTC on this realm), month, year, **game version** (`GetBuildInfo()`), **content phase**, lifetime. These are LibGranaryDB grains (`hour`, `day`, `week`, `resetweek`, `month`, `year`, `version`, `phase`, `lifetime`); a counter stores only the grains it declares.
- **No "session" term.** Use precise periods instead: "this login", "today", "this week" and so on. "This login" means from the real login to logout and **survives a `/reload`** (decided 2026-11-14), keyed by login time.
- **Content-phase registry:** Hard Counters ships a small table of phases with start dates and sets the current one with `db:SetPhase(label)`.
  - **Known Forever roadmap:** launch on 2026-11-04 (1.60.1); Dec 9 2026 unlocks Barrow Deeps, Hyjal Summit and Onyxia's Lair; Winter 2026/27 brings Hardcore; content patches follow in Spring and Summer 2027.
  - The user can add their own phases.
- **Later:**
  - automatic runs (start on the first loot in a zone, stop after N idle minutes or on leaving)
  - zone visits as periods (zone is a dimension in v1)
  - a monthly or yearly "Wrapped" recap

### 5.1 Runs (v1, manual; agreed 2026-11-14)

A **run** is a user-marked time range: "I'm farming now" → "done". It isn't a LibGranaryDB grain and needs no library change.

- **Start/stop:** manual only in v1 (a button, the bar feed, `/hc run start|stop`). One open run at a time.
- **Exact totals by subtraction:** at start, Hard Counters reads the **lifetime** totals of every counter marked `runTracked = true`; at stop it reads them again. The difference is the run's exact total for every flow, for the grand total and for each breakdown the counter declares in `runBreakdowns` (bounded: top N members). Active time comes from `hc:time.active` the same way. Lifetime buckets never close, so these reads hit live memory. *Cost to be measured; expected tiny.*
- **Live-tracked during the run** (things subtraction can't give): the run's records (`max` with context, e.g. best drop) and any per-member detail too fine to snapshot. Kept in memory, bounded, written into the record at stop.
- **Stocks** in a run report show the value at start and at stop.
- **Storage:** run records live in Hard Counters' own saved table (a bounded list, newest first; proposed 200), not in LibGranaryDB. A record holds start, stop, character, active seconds, main zone (most active time), per-counter deltas and the live-tracked records.
- **Survives `/reload`** (decided). **Logout** (proposed, to be judged once it can be tried): the run **pauses** at logout and the next login asks "Resume run X or stop it?". Offline time never counts as active time. The run's state is saved continuously, so a crash behaves like a logout.
- **Pause/resume and splits:** a pause stops the run's clock without ending it; AFK pauses automatically through active time. A **split** is a named sub-range of a run, taken by the same snapshot subtraction, so splits cost nothing extra. Packs give runs their face (Farmer's farm stopwatch).
- **Arbitrary past ranges are a different feature.** Without a recorded run, "yesterday 14:00–16:00" is answerable only to the hour and only while hour buckets are kept (48 h).
- **First client:** `packs/Farmer` (the run report).

`hc:time.active` is a **core counter** owned by Hard Counters: active (not AFK) seconds, by zone. Every "per hour" rate in every pack divides by it.

**Zone keys (HC-13, decided by the user 2026-11-15):** outdoors, the map ID (climbed out of caves); **inside an
instance, 100000 + `GetInstanceInfo()`'s instance ID** (Deadmines 100036, Shadowfang Keep 100033), because the map
API returns nil there (run 3) and instance IDs overlap map IDs. Numeric and language-free like every other key;
names for display are remembered while inside (`HardCountersDB.instanceNames`), else "Instance 36".

**Zone keys are numbers everywhere (HC-25, user 2026-11-15: "since we are committing to numeric ids, stick with
that"):** `W.zone()` never returns the zone text; where neither the instance nor the map API answers the key is
**0, "Unknown zone"** (no map has ID 0; `nil` was rejected because run breakdowns are Lua tables keyed by zone).
LibGranaryDB r4 gives rows the stored member (`row.member`, numbers stay numbers; LG-16), so views, run snapshots
and breakdowns, `mainZone`, per-zone active hours, boards' "vs your average here" and packs all see numbers; record
contexts (`ctx.zone`, stored as text by the library) are turned back into numbers. Breakdowns may also hold the
library's buckets `"other"` (past the cap) and `"none"`, which are not zone keys and never win `mainZone`.
**Purge (one-time migration `hc25`, `Core/Migrations.lua`):** text keys saved by earlier builds ("The Deadmines",
"Shadowfang Keep", "Silverpine Forest" in the developer's test data) can't be deleted member by member, so every
counter, registered or frozen, whose `zone` dimension holds text is dropped whole (`DropCounter`, found with r4's
`db:Members`); an open run's segment is closed before the drop and reopened after, so its totals never go
backwards; run records and the open run lose their text zone keys (totals kept) and get `mainZone` again from what
is left. `HardCountersDB.migrations.hc25` marks it done.

### 5.2 Readings and their scopes (built 2026-11-15, v2 M2; TRACKERS_AND_BOARDS §5)

One reading API (`RegisterReading`, `Reading(id, scope)`, API §5.1) replaces run readings; `RegisterRunReading` is a
wrapper for one release. Scopes and how they are served:
- **`run`:** the run mechanism above.
- **`login`:** the session window (`HardCountersDB.windows.session`, HC-29): a baseline of the odometers taken at
  the real login, so a `/reload` carries on and a new login starts over. The same mechanism as a run (§16.2).
  Active time for the scope is `hc:time.active`'s window total plus its unwritten seconds.
- **`today`, `week`, `month`, `year`, `lifetime`:** one query on the open bucket of that grain; only for counters
  that keep the grain ("needs history" otherwise). Never closed buckets: ranges stay in windows and views.
- **`now`:** a stock's last observed value this login, else its lifetime `last`.
- **Computed readings** (`compute(get, scope)`) read other readings; their values are never stored.

## 6. Measures and views

- Measures come from LibGranaryDB:
  - flows: `sum`, `count`, `min`/`max` **with context** (when, where, against what), `first`, `last`, `avg`
  - stocks: `last`, `min`, `max`, `twa` (time-weighted average while logged in)
  - query-time: `rate` (per second of wall time), `rate_active` (per second of active time; we call `db:SetActive` on AFK changes), `share`, `change` (against the period range just before)
  - live rates over a window: `GDB:RateWindow`, in memory only
  - **distributions: not in LibGranaryDB v1** (`hist`, SPEC D8; `Supports("hist")` is false). Needs a library MINOR and a schema migration.
- Derived in Hard Counters: best period, streaks (from `db:Series`).
- **Not in LibGranaryDB v1, and Hard Counters must not assume them:** the notable-events journal and segments. "This login" and user runs are Hard Counters' job, not grains.
- **View** = counter + measure + period (+ range) + breakdown + filter. Views can be saved and shared as data-only strings.
- **Pivot window:**
  - rows: pick a dimension or time grain
  - columns: pick a measure or a second grouping, if materialized
  - sort and filter
  - drill-down: a click opens a nested view
  - large queries run in slices (`db:QueryAsync` / `db:SeriesAsync`, 2 ms per frame; verified in game at median 2.2 ms, max 3.5 ms). A cold synchronous query costs 10–30 ms, so the UI never calls `db:Query` on data that may be cold.

## 7. Displays (display plugins; may become a separate display library later, behind adapters)

All displays consume generic dataset rows or time series. Each declares which measures it accepts: a number, a rate, a series, a distribution, or records.

| Display | Shows | Notes |
|---|---|---|
| Live number | any measure | Movable, lockable, scalable; optional comparison ("+12% vs yesterday") |
| **Speedometer / gauge** | **rates** (gold/hour, yards/sec, XP/hour, casts/min) | Rotated needle texture plus an arc (pre-rendered TGA with a rotating mask, or WeakAuras-style radial fill). Zones for "your average" and "your best". Smooth needle movement **only while visible**. Never driven by secret values. |
| Odometer | lifetime totals | Rolling digits |
| **Calendar heatmap** | daily flow over months | GitHub-contribution-style grid of textures. Cheap; not seen in any WoW addon so far. |
| Sparkline | short trend next to a number | Also in the bar-feed tooltip |
| Record board | top-N extremes with context | Plus a **"new record!" pop-up** (LibGranaryDB `OnNewExtreme`: lifetime records, deferred, at most once per counter per 10 s) |
| Goal ring | progress toward a user target | e.g. 1,000g this week |
| Comparison bar | today vs yesterday or best day | With a record marker |
| Line / bar chart | time series, alt comparison | Own small renderer on `CreateLine` plus pooled textures. LibGraph-2.0 Revived is the fallback behind an adapter. |
| Histogram | distributions | **Blocked until LibGranaryDB has `hist`** (not in v1) |
| Bar feed (LDB) | any counter as a LibDataBroker data object | Titan Panel, ElvUI, ChocolateBar, Bazooka. Accountant and Odometer offer this; Forever Stats doesn't. |
| Chat report | top rows of a view | Opt-in; privacy by default |
| World-map heatmap | where you travelled | **Later / expensive.** Needs route storage; bounded grid cells per map. |

**Rendering toolkit (what's possible):**
- **Available:** textures, `CreateLine`, `SetRotation`, MaskTextures, cooldown-swipe radial fill, AnimationGroups, bundled TTF fonts, model frames, drawing on the map canvas.
- **Not available:** shaders, arbitrary pixel drawing.

Redraw only dirty displays, on a timer every 0.2–0.5 s. Idle displays cost nothing.

**UI rule: simple on the surface, deep on demand** (agreed 2026-11-14). Three layers, each optional:
1. **Glance:** one widget per pack and a bar-feed / minimap entry, working with no setup.
2. **Look:** windows with tabs, periods, character vs account, simple filters.
3. **Shape:** setup of counters, views, displays, targets and reports. v1 ships toggles and a few choices; a full view/report builder comes later.

Nothing from a deeper layer leaks into a shallower one: no setting has to be touched before the Glance layer is useful.

**Built 2026-11-15** (§7.2, §7.3; [TRACKERS_AND_BOARDS §4–6](TRACKERS_AND_BOARDS.md)): the Glance layer becomes player-built **boards** (vertical stacks of tiles, each a reading with a scope, with a one-line mini mode), edited in an edit mode from a Trackers window; the run panel and the live number become the Run and Pocket presets. Run readings and views merge into one `RegisterReading`. Gold and XP per hour ship in a Basics module of Hard Counters.

### 7.1 Windows and commands (decided 2026-11-14, from the user's in-game feedback)

- **One window host for every window, packs included** (`UI/Windows.lua`, API §9). Hard Counters owns the chrome:
  title, close, drag, resize grip, Escape, BlizzMove registration, and the saved position, size and scale per
  window (`settings.windows[id]`). Packs only build content. So "every window is resizable and BlizzMove-aware" holds
  by construction, not by each pack remembering to do it. **Except the shared window** (user, 2026-11-23): it is not
  resizable, and it is **one size for every tab** (one panel, visually consistent). Since HC-69 that size is a
  design size, **780 × 640** (§17.2: the browser needs the width; 640 keeps Character Stats unscrolled), wider only
  when a tab's minimum width needs it (width never scrolls), capped at the screen; a tab whose minimum height is
  taller than the body scrolls vertically inside it. A tab's own `width` / `height` don't count. A size saved from an
  old drag is dropped at load, and the "Reset its size" option is gone. Windows of their own and popups keep their
  grip.
- **The shared Hard Counters window: every window is a tab of it** (Trackers, Runs, Farmer's Ledger, the
  Diagnostics console, any pack's). **No pop-out** (user, 2026-11-15, replacing the Dock / Pop out choice of
  2026-11-14): in run 3 every tab had been popped out, which left an empty Hard Counters window, and the Dock buttons
  that would bring them back didn't draw. Things that stay on screen while playing are boards (§7.2), not windows.
  Only a window registered with `dockable = false` (a HUD) gets a frame of its own. Popups (run summary card, copy
  box) are resizable and BlizzMove-aware but never tabs. A saved pop-out choice is dropped at load.
- **One command root, `/hc`.** Packs add `/hc <name>` through `HC:RegisterSlash` (`/hc ledger`, `/hc diag`); `/hc`
  alone opens the shared window. The older `/hcf`, `/farmer`, `/hcdiag` remain as aliases: cheap, and they are in
  the player's muscle memory and in the checklists. Drop them before a public release if they cause confusion.
- **Revised 2026-11-15 (user, with a screenshot):** the shared window and every window of its own use Blizzard's
  panel frame (`ButtonFrameTemplate`: border, title, close, an inset for the content; the shared window has our
  icon as its portrait) with tabs along the bottom (`PanelTabButtonTemplate`), like the character panel. Windows
  raise when clicked, so a row highlight no longer shows on top of another window. If a template is missing the
  host falls back to its own plain frame. The template draws its border high above the frame: the host never lowers
  the close button below it (run 3: lowered to the body's level, the close button vanished under the border).
- **The run panel was never a tab** (user, 2026-11-15) and is gone since HC-24: boards replaced it (§7.2);
  `/hc panel` and `HC:ToggleRunPanel()` toggle the Run board.
- **Minimap button** (2026-11-15): LibDBIcon-1.0, downloaded with the user's OK. Click: the Hard Counters window;
  shift-click: show or hide all boards; ctrl-click: edit boards (`UI/Broker.lua`); right-click: options. `/hc minimap` or the options hide it. The bar feed's click does
  the same. Its default angle is 290, not LibDBIcon's 225: every undragged LibDBIcon button lands on 225, and in
  game ours sat exactly under BugSack's and looked missing.
- **The AddOns menu** (HC-45, 2026-11-18): the same launcher is an entry in the game's AddOns menu, always, with no
  option (LibDBIcon's `showInCompartment`, set on every load). It reads "HardCounters": LibDBIcon labels the entry
  with the registration name, and renaming that would rename the minimap button's frame. Shift and ctrl clicks are
  passed on as they are. The minimap button's tooltip ends "Right-click: new board, options (you can hide this
  button there)" (a menu since HC-42, §7.2); hiding it prints where Hard Counters still is (the AddOns menu,
  `/hc minimap`).
- **Draw order** (HC-43, 2026-11-18): boards and their flyouts are in the `LOW` strata, our windows in `MEDIUM`, so
  a window is always above every board whichever was clicked last. Blizzard's panels and bags (`MEDIUM`) are
  above boards too; unit frames share `LOW`. Menus and popups stay above everything of ours (the edit bar went
  with HC-42).
- **Windows never open bigger than the screen** (2026-11-15): the old grip had saved the shared window at
  1333×1151; saved sizes are now capped at the screen (at the window's scale).
- **Resize grip fix** (2026-11-15): sizing a frame anchored by its centre moved both edges, so the window jumped on
  a slight drag. The grip now pins the frame by its top-left corner first, and layout leaves the size alone while
  the grip is held. Saved positions are top-left points from then on.
- Not done: tabs wrap or scroll (fine for a handful), dragging a tab out with the mouse (the button does it).

### 7.2 Boards (built 2026-11-15, v2 M5; TRACKERS_AND_BOARDS §6)

Boards replace the run panel and the live number (user, 2026-11-15). `UI/BoardModel.lua` holds the model and every
decision (pure, tested); `UI/Boards.lua` draws; `UI/Menu.lua` is a small popup menu of our own (the client's
dropdown templates differ between clients).
- **Model:** `charSettings.boards = { list, nextId, seeded, runBoard, v, tiles, tileOrder, nextTile }`, per
  character (HC-74, §17.12; per profile before, which every character shared); since v6 (HC-67, §17.9) a board's reading tiles live in the collection (`tiles`) and the board keeps
  placements (`{ ref, size }`); v7 (HC-73) dropped v6's `sections` (`lastEdited` is gone since HC-36;
  old saved files keep it, unread). A board: name, preset,
  shown, mini, pos, scale, width, visibility rules, tiles. Tile kinds `reading` (styles hero, grid, row, bar, gauge;
  agreed to become calc + display + size, §16.9), `splits`, `label`; the control row is drawn by itself since HC-41 (§16.8; the `run` tile kind is gone).
- **Height follows the tiles** (§6.1): rows from `M.Layout` (grid tiles pair up); the grip changes only the width.
- **Locked by default:** a board is click-through text except the control row's buttons and the mini strip. Edit mode
  is per board since HC-42 (below): a board's hover handle or its strip's menu edits that board; `/hc edit`,
  ctrl-click on the launcher and Options edit every board. It adds name bars (Done at the right end; drag to move,
  right-click for mini, visibility, rename, hide, delete; Escape leaves), `+` under each board (a
  reading by tracker, splits, a heading, New board; a reading of a tracker that is off asks first) and a tile
  menu on right-click (scope, with "needs history" greyed and an offer to turn daily history on; style; rename;
  move up/down; Move to another board or a new one, HC-41; remove). Drag and drop is HC-22.
- **As built (HC-42, 2026-11-20; playtest statements 11 and 13; not seen in game, checklist part S):**
  - *Per board:* `Boards.EditBoard(id, on)` edits one board, `Boards.SetEditing(on)` every board (off ends both);
    `Boards.IsEditing(id)`. Only an edited board takes the mouse and shows its chrome; the others stay click-through.
    The Trackers window opens with "every board" only, as before; one board's `+` is enough for one board.
  - *The handle (a):* a 40×16 gold "Edit" tab above a full board's top-right corner while the cursor is over the
    board. Boards are click-through and get no `OnEnter`, so `Boards.Hover` polls `IsMouseOver` ten times a second
    from the boards' `OnUpdate` (the choice the queue left open: an always-on handle would take clicks and camera
    drags on its spot). Not on mini boards (their strip already takes the mouse: its menu has "Edit this board"),
    not in combat, not on a board being edited. An error in the poll stops it once, with one report.
  - *The toolbar is gone (b):* Done is on each name bar (with every board edited it ends all); Escape works through
    an invisible frame in `UISpecialFrames` (`HardCountersBoardEdit`), shown while any board is edited. "New board"
    is in the `+` menu, on the launcher's right-click (now a small menu at the cursor: New board ▸, Edit every
    board / Stop editing boards, Options; it opened Options alone before) and in Options ▸ Boards (a dropdown). An
    empty new board opens for editing; a preset board doesn't. The "Trackers" button went with the toolbar. **Since
    HC-68 (§17.10)** each of those opens the New board dialog, and the launcher's menu reads New board..., Open Boards
    tab, Edit every board, Options.
  - *Blizzard's Edit Mode (c), built 2026-11-20 (the user's go after the probe):* mirroring only. `EventRegistry`'s
    `EditMode.Enter` puts every board in edit mode (`Boards.SetEditing(true, true)`: without opening the Trackers
    window, Edit Mode has its own panels up); `EditMode.Exit` ends edit mode on every board, also one edited on its
    own before. Both run on the next frame (`C_Timer.After(0)`), outside Blizzard's call. No option. On a client
    without `EventRegistry` nothing mirrors (`Boards.mirrorsEditMode` is false). Our boards are not Edit Mode
    systems: they don't appear in its list, snap to its grid or save in its layouts (that would need a third-party
    library: ask first).
  - *The probe (Diagnostics "HC-42 Edit Mode", answered 2026-11-20 07:07):* `EditMode.Enter` and `EditMode.Exit`
    reach addons, once per visit, with no error or taint; the manager frame shows and hides twice in one visit, so
    (c) mirrors on the callbacks. The probe stays (counts in `HardCountersDiagDB.probes.editMode`).
  - *BlizzMove and boards (fixed 2026-11-20, after an old board snapped back when moved):* boards register with
    BlizzMove as `NonDraggable`. As draggable frames BlizzMove turned their mouse on (a board not edited since login
    wasn't click-through) and hooked `SetPoint` to return them to its last drag spot, which undid our moves.
    BlizzMove now only scales boards (Ctrl+wheel, in edit mode, when the board takes the mouse).
  - *Not built:* drag handles on tiles (HC-22, which builds on this); a keybinding (HC-23).
- **Mini mode:** one 22 px strip: the board's dot (click: pause or start its timer), the hero's value, the
  comparison as `+18%`, the board's clock; right-click: Pause / Resume, Stop, Reset, Save as run, full board, edit;
  hover: the full board as a flyout (without the control row). Glyphs are ASCII or Latin-1 or textures: the game's
  fonts lack arrows and block characters.
- **Hero:** label, big number, a 10-minute sparkline (bar textures from the counter's in-memory rate window,
  `liveRate`), and "+18% vs your average here" against this zone's past runs from 3 runs on (runs with fewer than 5
  active minutes are left out of the average).
- **Visibility per board:** in combat show/fade/hide, in instances show/hide, only while a run is open, faded until
  the mouse is over it. **Cost:** one ticker per visible board, 0.5 s while the board's clock runs (HC-41), else 5 s;
  hidden boards stop their ticker.
- **Presets** (tiles on the board's timer except `now`, HC-41): Run (Gold/h hero, XP/h, Net gold/h, Gold
  earned, Items, Vendor value/h, time to level, splits, best drop; Farmer's tiles only when Farmer is loaded),
  Pocket (mini; Gold/h hero, XP/h, Net gold/h), Leveling (XP/h hero, the XP bar, time to level, rested XP, XP gained, Gold/h).
- **First use and migration (once, `M.Seed`):** a new character gets the Leveling board and, once per account, the
  tutorial (HC-74, §17.12; the tour, §17.13; before, a fresh install got the Pocket board, as a returning character
  with no boards still does). A player of the old run panel (its window state exists) gets a Run board in its place,
  width and scale, compact as mini, its headline as the hero (Farmer's old reading ids mapped to Basics'), and a
  Pocket board shown if the live number was. `/hc panel` and `/hc live` toggle those boards.
- The run panel and the live number (`UI/RunPanel.lua`, `UI/LiveNumber.lua`) were deleted 2026-11-15 (HC-24), once the
  user had seen boards working in game; the migration above still reads their settings keys once.

### 7.3 The Trackers window (built 2026-11-15, v2 M6; TRACKERS_AND_BOARDS §7)

**Rebuilt on the shared browser in HC-66 (§17.4 "As built"):** the per-pack list below became a category tree, a
list with columns, a detail pane and an action bar; what each part does is unchanged unless §17 says otherwise. The
2026-11-15 layout, for the record:

`UI/Trackers.lua`, a tab of the shared window (`/hc trackers`; edit mode opens it beside the boards). A virtual
list (pooled rows, mouse wheel) so no scroll template is needed:
- **Per pack** (Hard Counters' Basics first): each tracker with **on/off** (switching off asks first, listing the
  readings it stops and the trackers that keep shared counters running; switching on a tracker that needs history
  says so), its **history** button (Live / Lifetime / Daily *n*d / Detailed, or "needs daily history" while off;
  the menu offers the presets, disables those below what the tracker needs, and **Delete history**: all of it, the
  hourly part or the daily part, each with its size and a confirm that names shared counters) and its **size** on
  disk with the frozen part apart (from `db:Stats()`).
- **Expanded** (the + before a tracker, or a search): its readings, each with its scopes (grey with a dot: needs
  history) and a **[+]** that adds it to a board (asking first if its tracker is off). **HC-36 (2026-11-18):** its
  tooltip names where ("Add to Pocket"); with one board it adds there at once; with several a menu lists them, the
  ones on screen first, hidden ones marked "(hidden)", then "New board"; with none it makes one. A hidden board is
  shown and the new tile flashes once (a mini board's strip). A new board is made only when the tile is added, so a
  cancelled pick leaves none.
- **Not loaded:** counters on disk that nothing registered this session and no tracker lists, with Delete.
- **Footer:** "History on for 2 of 9 trackers · 180 KB on disk". Tooltips carry the §3.4 texts.
- **The one-time New behaviour:** a pack's tracker the player hasn't touched is *New*; when new ones appear the
  window opens once by itself at login, and closing it marks them seen. A fresh install (Basics only) has nothing
  New, so the window stays shut; the first login prints one chat tip about history instead.

## 8. Diagnostics, dev console and field feedback (agreed 2026-11-13)

### 8.1 Three tiers

Field feedback matters: other players' machines, classes, languages, instances and addon mixes are the cheapest way to settle API verdicts. So diagnostics are not dev-only. They are tiered:

| Tier | Who gets it | What's in it | Cost |
|---|---|---|---|
| **1. In every build** | Everyone | Cheap health counters (secret values rejected, position gaps, errors caught, budget actions taken), a **ring buffer of the last ~200 warnings and errors**, and **`/hc report`** | ~0; logging below warning level is off |
| **2. `HardCounters_Diagnostics`** (optional companion addon) | Shipped alongside, **disabled by default**; users turn it on when asked, or out of curiosity | The full **dev console** (§8.2) | Only when enabled |
| **3. Repo only** | Us | Benchmarks, synthetic data generators, **fault injection** (pretend a value is secret, pretend position is missing), dumps of the saved data | Never shipped |

When `HardCounters_Diagnostics` isn't loaded, the engine's verbose logging calls go to a no-op logger.

### 8.2 Dev console (`HardCounters_Diagnostics`)

It has its own SavedVariable, so debug data never mixes with statistics.

| Tab | Shows |
|---|---|
| **Log** | A bounded, filterable log (level, source, counter, origin: engine / LibGranaryDB / pack) kept in a ring buffer of about 2,000 lines |
| **Live** | Each counter's current values, the buckets currently being filled, live rates |
| **Sources** | Per source: capture mode, last event time, events per second, polling rate, last position reading, gaps and teleports detected |
| **Restrictions** | Secret values rejected, whether restrictions are active (`ADDON_RESTRICTION_STATE_CHANGED`), combat state |
| **Storage** | LibGranaryDB `db:Stats()`, `GDB:SelfTest()` and `GDB:Bench()` results (see §8.4) |
| **Probes** | API and event probe results that feed [`api-surface.md`](api-surface.md) |
| **Perf** | `C_AddOnProfiler` metrics, per-handler `debugprofilestop` timings |

**Getting text and images out:**
- **Copy box:** any tab opens as plain text in a multi-line text box that selects all on click, for Ctrl+A, Ctrl+C. WoW can't copy text from ordinary labels.
- **Snapshot (the main route):** writes the current tab, timestamped, to the console's saved variable. After `/reload` Claude reads it directly from `WTF\Account\<acct>\SavedVariables\`. No copying, no truncation.
- **Marker:** writes "MARK #n hh:mm:ss" to the log and on screen. A screenshot taken right after can be matched to the exact log lines.
- **Screenshots:** the Print Screen key saves a `.jpg` to `_forever_\Screenshots\`, which Claude reads directly. Whether an addon may call `Screenshot()` itself is ❓ unverified (see api-surface.md). If it can, the marker could take the screenshot automatically.

**Don't rebuild what exists:** `/etrace`, `/tinspect`, `/dump`, `/fstack` and BugSack cover raw events, tables, frames and errors. The console shows only **our engine's** state.

**v1 of the console** is **Log + Live + Snapshot + Copy box + Marker**. The other tabs arrive as the engine parts behind them get built. The console is the **first piece of Hard Counters to build**, before any capture code, because every in-game test depends on it.

### 8.3 `/hc report`, the field-feedback string

- **Format:** prefixed and versioned (`!HCReport:1!…!End:HCReport:1!`), encoded like LibGranaryDB exports (CBOR → raw Deflate → Base64; verified in game).
- **Contents:**
  - addon, pack and library versions
  - **the LibGranaryDB MINOR and `API_VERSION` actually running** (it may not be the copy Hard Counters shipped: only the newest embedded copy runs)
  - client build and language
  - health counters and recent warnings
  - a separate **LibGranaryDB section**: the `!GranaryDBReport:1!…` string from `LibStub("LibGranaryDB-1.0"):BuildReport()` (≤ 8 KB, no character names)
- **Opt-in and visible:** the user sees the box and copies it. Nothing is sent automatically, and addons have no network access anyway.
- **Scrubbed by default:** no character names, realms or other players' data.
- **The list of other installed addons** is behind a separate checkbox: useful for finding conflicts, but more personal.
- **As built (HC-61, 2026-11-24): the report window and the probes.** `/hc report` and the Diagnostics console's
  Report button open one window: what the report is for (fixing and improving Hard Counters; the addon sends nothing;
  pasted into GitHub it is public; zone, map and spell IDs hint at where you play), a plain list of what is in it
  (`ns.ReportSummary`), three checkboxes (**Include my character's name** (with the realm), **my character's class**,
  **my addon list**), then the string. The boxes start off every time the window opens and are never saved;
  `/hc report addons` pre-ticks the addon list. With `HardCounters_Diagnostics` loaded the body gains `diag`, set
  through the private bridge (`_diag.SetReportSection`): the latest result of each function probe (status, the
  value's types, the context line: map or instance key, instance type, combat), the events (fires by instance type,
  argument types), the client strings and the samplers' tables (travel and TR-6 counts, loading screens, item link
  shapes, Edit Mode), as kept: types, counts and game IDs, never coordinates, names or chat text. Over the 24,000
  character cap the report sheds the oldest warnings, the addon list, the storage report, then the probes'
  samplers, events and strings; the function results go last. One tester's real probe data came to about 10,800
  characters. Decoding is unchanged (`tools\decode-report.ps1` takes any file holding the string, a chat paste
  included). Not built from HC-61: the decoder's merge mode across reports and a "Diagnostics report" GitHub issue
  template.
- **Size-capped,** so the paste never freezes the text box.
- **Feedback channel:**
  - **Now:** friends paste the string back to you (Discord, email…).
  - **Later, if published:** the same strings go into issue trackers. No redesign needed.

### 8.4 Routing feedback: LibGranaryDB vs Hard Counters

- **LibGranaryDB exposes diagnostics but never shows them.** It has no UI, prints nothing by itself, and registers **no slash commands**. A library doing that clashes and spams inside other people's addons. (Its repo-only dev addon has `/granary`; that is never embedded.)
- **What LibGranaryDB provides:**
  - `db:Stats()`, `GDB:SelfTest()` and `GDB:Bench()`
  - a logger adapter, supplied by the host through `Attach({ adapters = { logger = … } })`
  - `GDB:BuildReport()` (or `db:BuildReport()`), which returns its own **`!GranaryDBReport:1!`** string
  - `db:IsReadOnly()`: an older embedded copy meeting newer saved data goes read-only instead of writing
  
  Hard Counters surfaces them in the Storage tab and in `/hc report`. Third-party hosts can surface them in their own UI.
- **Errors say whose fault they are:**
  - **Host misuse** raises `error(msg, 2)`, pointing at the caller's line, starting with `LibGranaryDB-1.0: `.
  - **LibGranaryDB internal failures** carry a tag: `LibGranaryDB-1.0 r<minor> INTERNAL: … - please report`.
- **Origin tags:** every log line carries `[LibGranaryDB r<minor>]`, `[HC]` or `[Pack:<name>]`. BugSack file paths also show which embedded LibGranaryDB copy is the one running.
- **Triage by prefix:**
  - `!GranaryDBReport` → `../LibGranaryDB/docs/KNOWN_ISSUES.md` (decode with `../LibGranaryDB/tools/decode-report.ps1`)
  - `!HCReport` → this repo (`api-surface.md` for API verdicts, or KNOWN_ISSUES)

### 8.5 Probes and API verdicts

- The Probes tab, and a standalone **probe addon** that may come before the engine, check every API, event and hook we depend on:
  - Does it exist?
  - Does it fire or return values?
  - Are the values secret?
  
  Each in and out of combat, outdoors vs in instances, and during loading screens. Results carry a timestamp and context.
- **Precedent:** QuestieTrace's timestamped "function streams" and its "frame heartbeat" (whether addon code runs during loading screens). It's GPL-3, so we write our own.
- **Output:** verdicts in [`api-surface.md`](api-surface.md). Field reports from tier 2 add evidence from other machines.

## 9. Data flow: export, import, sharing

- Export and import strings in LibGranaryDB format (`!GranaryDB:1!…!End:GranaryDB:1!`, from `db:Export` / `db:Import`): CBOR → raw Deflate → Base64, Adler-32 checked, 1 MB default limit. Imported datasets are read-only and queryable next to our own data (`dataset = id`).
  - Use them for backups, comparing your characters across your two WoW accounts or PCs (a manual snapshot), and comparing with a friend.
  - Imports are always data only.
- **Sharing views and dashboards as strings**, like WeakAuras shares auras. **Data only, never Lua code.** WeakAuras' code execution is a known security hole.
- **Exports must be scoped.** A text box holding several MB freezes the client. There's no clipboard access: the player always presses Ctrl+A, Ctrl+C.
- **Future companion app (a dream, not v1):**
  - It reads `WTF\Account\<acct>\SavedVariables\HardCounters.lua` outside the game, loads it into DuckDB, and serves a local dashboard with full OLAP and visual polish.
  - It could merge several WoW accounts and PCs (synced through a cloud folder).
  - It could write data back as an addon data file that loads at the next login, the way TradeSkillMaster's desktop app does.
  - It only updates on logout or `/reload`. Requirement now: **keep the saved format documented and versioned.**

## 10. Public API (draft; "experimental" until 2–3 packs have used it)

- `HardCounters:RegisterSource(id, def)`
- `HardCounters:RegisterCounter(def)`
- `HardCounters:Emit(id, value, ...)`. Packs normally emit through sources.
- `HardCounters:Query(view)` / `:Series(view)` / `:Live(counterId, window)`
- `HardCounters:RegisterDisplay(id, def)`, where a display declares the measure kinds it accepts and its factory.
- `HardCounters:RegisterPhase(id, label, startTime)`
- `HardCounters:StartRun(label)` / `:StopRun()` / `:GetRun()` (the open run, live) / `:Runs(filter)` (past records). Counters opt in with `runTracked = true` and `runBreakdowns` (§5.1).
- Callback events:
  - `HC_COUNTER_REGISTERED`
  - `HC_NEW_RECORD`
  - `HC_PERIOD_CLOSED`
  - `HC_RUN_STARTED`, `HC_RUN_STOPPED`
  - `HC_FEASIBILITY_CHANGED`
  - `HC_RESTRICTIONS_CHANGED`
- `HardCounters:Supports(capability)` and `HardCounters.API_VERSION`.
- **Agreed 2026-11-15** ([TRACKERS_AND_BOARDS](TRACKERS_AND_BOARDS.md)): `RegisterReading(id, def)` (built, §5.2), `RegisterTracker(id, def)`, `SetAttributor(counterId, fn)`, `feeds` on `RegisterSource`.
- **Never expose saved tables. Never expose Ace types.**

## 11. Dependencies (each behind our own adapter, swappable for in-house code)

| Need | Candidate | Notes |
|---|---|---|
| Storage | **LibGranaryDB-1.0** (ours) | Embedded under `Libs\LibGranaryDB-1.0\`, loaded through its `lib.xml`, as in `../LibGranaryDB/examples/JumpCounter`. Brings LibStub. |
| Library loading | LibStub | Standard; tiny |
| Callbacks | CallbackHandler-1.0 | |
| Settings and profiles | AceDB-3.0 (+AceDBOptions) | Settings only; data lives in LibGranaryDB. If AceDB owns the same SavedVariable, keep it off the `__granary` key. |
| Options UI | AceConfig-3.0 + AceConfigDialog, or Blizzard's Settings API | |
| Localization | AceLocale-3.0 | enUS first |
| Events and timers | AceEvent / AceTimer, or our own small wrappers | |
| Bar feed | LibDataBroker-1.1 | Frozen since 2009, but the universal standard |
| Minimap button | LibDBIcon-1.0 | Forever-supported |
| Media | LibSharedMedia-3.0 | Fonts and bar textures |
| Charts (fallback) | LibGraph-2.0 Revived (MIT) | The primary choice is our own renderer |
| Codecs | `C_EncodingUtil` (native) | LibSerialize/LibDeflate as fallbacks |

**Rule:** wrap only what we actually use. Every library above, Ace3 included, is maintained and supports Forever as of 2026-11 (see research.md §4).

## 12. Performance rules

- Event handlers are tiny: dispatch tables, no per-event allocation, `wipe()` and reuse tables.
- `C_Timer.NewTicker` instead of OnUpdate, except for animations on visible frames.
- Polling is adaptive (§3.2). Displays redraw only when dirty.
- Large queries, rollups and migrations run in slices (≤ 2 ms per frame).
- Measure with `C_AddOnProfiler` (always on) and `debugprofilestop`. Note that CPU used by embedded libraries is charged to the addon that embeds them.

## 13. Development workflow

**The agreed setup is in [`DEV_SETUP.md`](DEV_SETUP.md)** (decision record, 2026-11-13):
- Code and git on Windows; tests and lint (Lua 5.1, busted, luacheck) in WSL.
- VS Code with Ketho's WoW API extension.
- BugSack for in-game errors.

- **Dev link:** a directory junction from `C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns\HardCounters` to the repo's addon folder. Use `/reload` to pick up changes.
- **Packaging:** a script that builds a `.zip` for hand-shipping. No store publishing.
- **In-game debugging:**
  - **Built-in commands:** `/tinspect`, `/fstack`, `/etrace`, `/dump`.
  - **Addons:** BugSack and `!BugGrabber` are installed and active (confirmed 2026-11-14 during the LibGranaryDB runs). The AddOns folder also has Questie, AtlasLoot, Auctionator, InFlight, Syndicator and AltsForever.
  - **Avoid DevTool:** its repo is archived.
- **Lint and test:**
  - luacheck with a WoW standard.
  - Offline tests for pure logic.
  - The UI is verified only in game, from the user's reports and screenshots.
- **Git:**
  - local, `main`, author set in the local git config
  - no remote
  - **commit per milestone** (decided 2026-11-14, HC-7), each repo separately, never rewriting history

## 14. Proposed v1 scope (LibGranaryDB r1 exists and is verified in game; revised 2026-11-14 for the farmer's toolkit)

1. The engine: source adapters for all capture modes, registry, secret guard, polling discipline, phase registry, **manual runs (§5.1) and the core `hc:time.active` counter**.
2. **Built first:** tier-1 health, the ring buffer, `/hc report`, and `HardCounters_Diagnostics` v1 (Log, Live, Snapshot, Copy box, Marker). Then the probes, with the first `api-surface.md` verdicts filled in.
3. **The first pack drives v1:** `packs/Farmer` phase 1, the **Ledger** and the **run report** (its DESIGN §4). It replaces the gold proof of concept below and exercises push-delta, snapshot-diff, stocks, context records, high-cardinality dimensions and runs.
4. ~~Other proof-of-concept counters~~ **Dropped from v1** (decided 2026-11-14, HC-8): Farmer phase 1 already exercises every capture mode v1 needs. Kept here as later candidates:
   - ~~**Gold:** push events, with a source breakdown.~~ Now the Farmer Ledger.
   - **Distance:** polled, partly degraded.
   - **Jumps:** a hook, built as a separate sample pack using only the public API.
   - **One deliberately risky counter**, to exercise the triage process itself, e.g. combat totals through `C_DamageMeter`, or kills and deaths by source.
5. Displays: live number, speedometer, calendar heatmap, LDB feed, a basic pivot or summary window, **the run panel and run list**.
6. Export and import of scoped strings.

**Built 2026-11-14 (offline-tested only; nothing run in game yet):**
- ✅ 1 engine: registry, event/poll/hook sources, secret guard, scheduler with loading-screen pauses, phase
  registry, manual runs (pause, splits, live tallies, logout pause + login prompt), `hc:time.active`, views,
  run readings, the public API ([`API.md`](API.md), experimental).
- ✅ 2 tier-1 diagnostics, `/hc report`, `HardCounters_Diagnostics` v1 (Log, Live, Storage, Probes, Snapshot, Copy,
  Marker). The probes exist; `api-surface.md` verdicts wait for their first in-game run.
- ✅ 3 Farmer phase 1 (`packs/Farmer`, DESIGN §4.8 there).
- ✅ 5 partly: the run panel (stopwatch), run list and summary card, the live number (a display plugin), the LDB
  feed. ❌ Not built: speedometer, calendar heatmap, pivot/summary window. No minimap button (LibDBIcon not embedded).
- ❌ 6 export/import of scoped strings: not built.
- Tests: 54 specs here (incl. a load smoke test of all three addons under a fake client), 26 in Farmer.

**Not in v1:**
- zone views as periods, automatic runs, the recap
- the world-map heatmap
- Classic flavors with the combat log, even behind an adapter
- sync, the companion app
- languages other than enUS

## 15. Open questions

Decided with the user on 2026-11-14 (start of v1 code):
1. ~~Probe addon first, or engine first?~~ **Neither as a separate addon:** probes live in a Probes tab of `HardCounters_Diagnostics`, built after tier-1 diagnostics and before the capture code that depends on them.
2. ~~Does "this login" survive a `/reload`?~~ **Yes.** "This login" runs from the real login (`PLAYER_ENTERING_WORLD` with `isInitialLogin`) to logout, keyed by login time; a `/reload` carries on.
3. ~~Week definition~~ **The UI shows the ISO week by default**; reset week stays a choice. **Every stored timestamp is UTC epoch seconds** (`GetServerTime()`); local time appears only when formatting for display. LibGranaryDB's calendar (local day boundaries) is unchanged.
4. ~~Blizzard's Settings API or AceConfig?~~ **The Ace3 stack:** AceDB + AceDBOptions for settings and profiles, AceConfig + AceConfigDialog (registered into Blizzard's options with `AddToBlizOptions`), AceLocale. Downloaded from upstream (WoWUIDev/Ace3 `Release-r1403`), only the parts used are embedded. Ace types never cross the public API (§10).
5. Which display library boundary to use now, so it can be split out later? *(still open)*
6. ~~Which counter is the deliberately risky one?~~ **None in v1.** The distance, jumps and risky proofs of concept are dropped in favour of Farmer phase 1 (HC-8). Where the jumps sample pack lives (HC-6) is decided when it's built.
7. Trackers and boards: decided 2026-11-15 ([TRACKERS_AND_BOARDS §0](TRACKERS_AND_BOARDS.md)) and built; attributor timing settled (5 s); still open there: size estimates (§11.2).
8. The 2026-11-18 direction: decided and open points are in §16 (open ones in §16.7).

## 16. Direction agreed 2026-11-18: windows per tile, readings with a parameter (not built)

From a review of the design and queues against the dream (§1.0). **Decided by the user** unless a line says
*proposed*. Work is queued as HC-29 to HC-35, LG-18, FM-15, FM-16 and CS-9.

### 16.1 The model: how a run relates to a reading

They never touch each other. A reading says *which counters to combine*; a window says *between which two moments*.
Both point at counters.

| Notion | What it is | State it holds |
|---|---|---|
| **Counter** | Something counted: a flow or a stock, with dimensions | A running total that only grows (the odometer) |
| **Reading** | A formula over counters: counter, measure, minus, per hour, parameter; or a computation | None |
| **Window** | A stretch of time with pauses: start, end or open, active seconds | Start, pauses |
| **Baseline** | The join of window and counter: the counter's total when the window opened | One number per counter (per member, if kept) |
| **Scope** | The name of a kind of window on a tile: session, the tile's own window, today | None |
| **Value** | A reading asked over a window: (total now − baseline), then the formula | Never stored |
| **Record** | A closed window's frozen totals per counter, with a label and zone | Saved in the run list |
| **Run** | A window that has a name and leaves a record | The two above |
| **Tile** | A saved choice: reading, argument, scope (its window), character or account, calc, display, size, target, name, extras (§16.9; until HC-51, `style` stands for display + size and the reading's `per` for calc) | Settings |

- **Counting doesn't start with a run.** A counter counts while it is active (a tracker that is on uses it). A window
  only bookmarks the total.
- **Two kinds of window.** Ours (session, a tile's window, a run, a split) need a total and a baseline, so they work
  with history off. The storage library's (today, week, month, year, lifetime) are buckets on disk: "needs history".
- **A run never knows about readings:** it baselines counters, so any reading can be asked over any window or any
  saved record, including a reading added later (`Widgets.RecordReading` already does this for the comparison line).

**Where the code still departs (after HC-30):** `runLive` item lists are kept only for the character's open run
(a dungeon run or `/hc run start`), so a record saved from a tile or a board has none; `runTracked` is ignored and
`runBreakdowns` names the dimensions the odometer keeps per member; `norun` survives only for the bare call
`HC:Reading(id, "run")` with no run open, never on a tile.

### 16.2 Odometers and baselines (HC-29, the foundation; built 2026-11-18)

- Each active counter keeps **one running total per character** (`HardCountersDB.odo[character][counterId] =
  { s, n, by, bn, l }`), written by the emit path, saved with the account's data and kept across `/reload` and
  logout. Stocks keep their last value the same way (`l`), so `now` is known right after a login.
- A window (`Core/Odometer.lua`, `ns.Win`) is a baseline of the odometers plus what it banked earlier (`acc`); any
  number can be open at once. Pause banks the difference and drops the baseline; resume takes a new one. Active
  time comes from `hc:time.active`'s odometer the same way. A window can watch every counter or a set (`ids`).
- The run and the session (`login` scope) are both windows; a split banks into the run and into itself.
  `Runs.lua` keeps the records, the run list and the live tallies (`runLive`). No run or login value reads storage
  any more, so history on, off or switched mid-run makes no difference to them.
- **Offline nothing changes,** so a window left counting when the game closes is banked at the next login from the
  saved odometers of the character it was counting (`Win.AtLogin`), and the time offline comes off its clock.
- Per-member totals (§16.4): the odometer keeps them for the counter's `runBreakdowns` dimensions (500 members,
  then "other"); `Win.MemberTotal` reads one. HC-31 widens which dimensions are kept.
- **Upgrade:** the first `/reload` into this code carries the old login totals (`login.mem`) into the session and
  folds an open run's live segment into the run. Odometers start at zero then: nothing before the update is in them.
- **Left as it was:** counters with `runTracked` still get the `lifetime` grain forced when they keep history
  (`Core/Registry.lua`). **Decided 2026-11-19 (§16.7.5): it goes with the flag (HC-49).** No shipped counter
  declares its own grains and every history preset includes `lifetime` when declared, so nothing stored changes.

### 16.3 Every reading tile has its own start, pause and stop (user, 2026-11-18; built the same day, HC-30)

> **Reversed by HC-41 (playtest 2026-11-18; built the same day, §16.8 "As built"): the board is the clock.** A
> board has one window and one clock; tiles follow it; to pause one tile, move it to a board of its own (Move to,
> drag handle in HC-22). Below is HC-30 as it was built; what still holds: no tile waits for a run, windows survive
> logout, records need 5 active minutes and are never prompted, dungeons record themselves, runs are per character.

Runs become transparent: the player never has to start one to see a number.

- **A reading tile owns a window.** Placing the tile starts it. Its controls: pause / resume, stop (the number
  freezes), start (after a stop: a new period from zero), reset. No tile shows "-" for want of a run.
  - In the code a tile with scope `"run"` owns the window (`BoardModel.TileWindow`); readings keep declaring
    `"run"` among their scopes. It is the default scope of a new tile. The label shows the window's clock
    ("Gold/h · 12:48"), or "paused" / "stopped".
  - One window per tile **and character** (`HardCountersDB.windows["t<n>@<character>"]`): boards are shared by the
    profile, the numbers are each character's own (account-wide is HC-32). It watches only the counters its
    reading needs (`ns.ReadingCounters`) and keeps no per-member totals yet (HC-31).
  - **It survives logout** (§16.7.1): banked at the next login, carries on when its character logs in; the time
    offline, and other characters' sessions, are not on its clock.
  - Where the controls are: the tile's menu in edit mode, or **Alt + right-click the tile** without edit mode
    (boards stay click-through otherwise; unverified on Forever).
- **Tiles started at different times cover different periods,** so Gold/h and Net gold/h can disagree. The board
  has **start all, pause all, stop all, reset all** to line them up: on the control row (the old run tile: dot,
  clock, Pause / Resume, Reset), on the mini strip (click: pause or start; right-click: the rest) and in the board's
  menu.
- **Records** (§16.7.2): "Save as run" in a tile's menu once its window has 5 active minutes, also for the period a
  reset or a restart ended (kept as `w.prev` until saved or replaced); never a prompt. "Reset all" saves **one**
  record for the board when there were 5 active minutes, then starts every tile from zero together. Such records
  hold only the counters those tiles watched (`rec.partial`): another reading asked over them has no value, and
  they carry no item list. Their zone is where the player stood when saving.
- **Dungeons record themselves** (HC-2a): entering an instance starts a run named after it, leaving stops and saves
  it; under 5 active minutes it leaves nothing. That run is a full one (every counter, item lists). A run the
  player started is never touched; `/hc run start` inside a dungeon ends the automatic one. Option: "Record dungeon
  runs by themselves" (on).
- **Runs are per character** (`runs.opens[character]`) and carry on across logout like any window: the login
  prompt and its option are gone. "Run" stays the player's word for a record in the Runs tab; the comparison line
  ("vs your average here") reads those records.
- The other scopes (login, today, week, ...) stay as choices in the tile's menu: depth, never required.
- This replaces "a run is a scope the player opens and closes" (TRACKERS_AND_BOARDS §5.2, 2026-11-15). The Run
  board no longer appears with the first run; it is a preset like the others (`/hc panel`).

### 16.4 Readings with a parameter (the important wall, user 2026-11-18)

Counters are already parameterized (dimensions) and trackers need not be. The gap is the reading layer: a reading
always reads its counter's grand total (`Core/Readings.lua` `raw`), so "Rep with Timbermaw", "Gold from quests/h"
or "Runecloth looted" can't be tiles; Farmer's "Reputation gained" sums every faction.

```lua
HC:RegisterReading("hcfarm:repwith", { title = "%s rep", tracker = "hcfarm:rep",
  counter = "hcfarm:rep", param = { dim = "faction", type = "faction" },
  scopes = { "run", "login", "today", "week" } })
-- tile: { kind = "reading", reading = "hcfarm:repwith", arg = 576, scope = "login" }
HC:Reading("hcfarm:repwith", "login", 576)
```

- **A reading declares `param`; a tile supplies `arg`.** `param.dim` must be a dimension with its own aggregation
  set (the check `runBreakdowns` has). **The tile is the instance:** there is no saved list of player-made
  readings; a player-made reading is a parameterized reading whose argument the player picked.
- **`param.type`** picks the picker and the label: `enum` (source, sink, quality), `zone`, `item`, `faction`.
- **Where a member's value comes from:**

| Scope | Source | State today |
|---|---|---|
| today, week, month, year, lifetime | `db:Query` with `filter = { dim = member }` | works in the library; `HC:Reading` passes no filter |
| run, small dimension | `acc.by[dim][member]` + `seg.by[dim][member]` | kept for `runBreakdowns`; no accessor |
| run, big dimension (items) | `run.live[id].m[member]` (cap 500) | kept for `runLive`; no accessor |
| session and tile windows | per-member totals (§16.2) | **missing:** `ns.lmem` is per counter |
| now (stocks) | last value per member | **missing:** one last value per counter |

- **Per-member totals:** small dimensions keep every member; big ones (items) keep only members a tile watches, so
  such a tile counts from when it was placed. One nil check on the emit path for counters nobody watches.
- **Computed readings take the argument too** (`compute(get, scope, arg)`), for values with no counter ("Runecloth
  in bags" from `GetItemCount`, progress to the next reputation standing), with an optional `target(arg)` and a
  `refresh = { events }` list the engine registers only while the reading is placed (HC-33).
- **Pickers make it no-code** (HC-34, built: see "As built (HC-34)" below): a menu of known members for `enum` and
  `zone` (`db:Members`); for `item`, drop an item from the bags on the tile (the cursor carries items) or pick from
  recent loot; for `faction`, a list from the reputation API (probed on Forever 2026-11-18: it exists).
- **Limits accepted in v1:** sum only per member in our windows (`by` keeps no counts); no sparkline and no "vs
  your average here" on a tile with an argument (the rate window is per counter; records trim breakdowns to the top
  N); a member past the cap is in `other` and the tile must say so, never show 0; per hour divides by total active
  time, except for a `zone` argument (`hc:time.active` has that dimension). A filtered query for one member of a
  4,096-member open bucket is unmeasured: bench it.
- **Stocks with a dimension and history** still hit LibGranaryDB's forced grand total (junk when members are
  different quantities; the reason behind Character Stats' one counter per stat, which stands). Live only and
  computed stocks avoid it, so v1 is unaffected; history for "Runecloth in bags" needs LG-18 (unsized).

**As built (HC-31, 2026-11-18).** The text above is the design; this is what the code does, where it differs or
adds:

- **`HC:Reading(id, scope, arg)`**, `tile.arg`, `param = { dim, type, label = fn(member) → text }` (`type` defaults
  to `enum`). A reading with a parameter asked without an argument has no value (state `noarg`), never the total.
  It is left out of the run lists (no single run value). Titles: `%s` is replaced by the member's label
  (`ns.ReadingTitle`), without `%s` it reads "Title: member"; lists show "... rep" until a member is picked.
- **The odometer keeps a total per member of every small dimension** (declared cap up to 500; `runBreakdowns` no
  longer decides it), and for a stock its last value per member (`o.lb`). A big dimension keeps only watched
  members (`ns.WatchMember`: a tile with that argument, or the first `HC:Reading` that asks), from then on.
- **Where a member's value comes from now:**

| Scope | Source |
|---|---|
| today, week, month, year, lifetime | `db:Query` with `filter`, kept 10 s (about 3 ms each on a 4,096-member bucket: LibGranaryDB BENCHMARKS §9). No aggregation set with that dimension: "needs history" |
| the open run, the counter's `runLive` dimension (items) | the run's own tally; past its cap: `capped` |
| the open run, other dimensions; login; a tile's window | `Win.MemberTotal` over the odometer |
| now (stocks) | the odometer's last value for that member; never observed: no value |

- **`param.dim` is not required to have its own aggregation set**: our windows don't need storage. Only the
  storage scopes do, and they say "needs history" without it.
- **A tile with an argument** owns a window that baselines that one member (`w.mem`); changing the member starts
  it over (`BoardModel.SetArg`).
- **A member past a cap** reads "over the limit" (state `capped`), never 0: the odometer's 500 per dimension, the
  open run's `runLive.cap`, and (HC-34) storage's own cap in the storage scopes.
- **Picking a member:** the + menu and the Trackers window open a picker by the parameter's type (HC-34, below);
  for `enum` and `zone` it is the list of the members known so far (this character's odometer, plus storage when
  the counter keeps history; 40 at most, by label). "Other..." to type a name or an id is always there. The
  tile's menu has "Showing: X (change)".
- **Computed readings get the argument** (`compute(get, scope, arg)`; `get` passes it on to readings that take
  one). `target(arg)` and `refresh` are still HC-33.
- **Shipped readings:** Basics "Gold from %s" and "Spent on %s"; Farmer "%s rep" and "%s looted" (FM-15).

**As built (HC-34, 2026-11-18): pickers.** No new saved list: the tile is still the instance. Not seen in game.

- **An item, by dropping it.** While the cursor carries an item (`CURSOR_CHANGED`, `GetCursorInfo`), boards take
  clicks without edit mode. Letting go of it over a board (`OnReceiveDrag`, or a click with the item held) puts
  the item back in its bag (`ClearCursor`) and opens a menu of every reading that takes an item ("Add: Linen
  Cloth looted", "Add: Linen Cloth in bags"). On a tile that shows another item the menu starts with "This tile:
  ... (starts over)"; on a tile still waiting for its item it is set at once, no menu. With no pack that has an
  item reading, a chat line says so. `Boards.DropItem`, `BoardModel.DropChoices`.
- **An item, from recent loot.** The odometer remembers the last 20 members written to a big dimension, newest
  first (`odo[character][counter].rc[dim]`, saved, so a `/reload` keeps them; no allocation on the emit path once
  the list exists). The item picker lists them under "Recent:", then items a tile already watches. It never lists
  storage's members for a big dimension (thousands).
- **A faction, from the game's list** (`C_Reputation.GetNumFactions` / `GetFactionDataByIndex`, `ns.wow.factions`):
  one menu up to 20 factions, by the panel's headers beyond that. Factions under a header the player collapsed in
  the reputation panel aren't listed by the game (we don't expand it for them); ones counted so far that the game
  doesn't list come last. Without the API: the members known so far, as before.
- **"%s in bags"** (Farmer, `C_Item.GetItemCount`, bags only): the computed reading of the design's example; with
  a target on the tile and the bar style it is "143 / 200". Refreshes on `BAG_UPDATE` while placed.
- **Storage's cap:** a member that reads 0 in a storage scope while the dimension's member list is full and
  doesn't hold it reads "over the limit". That is also what a member never written shows then: it could only
  land in "other". The check copies the member list, so it runs only for a 0 and is kept 10 s with the value.
- **"Other..." resolves what is typed (HC-47, 2026-11-18; in game a typed "Refreshing Spring Water" became a text
  member that no loot matched, so its tile read 0 for ever).** `BoardModel.ResolveArg`: a number is an id; a
  pasted item link gives its id; a name is matched, in any case, against the picker's own list (recent loot, the
  game's factions, the members counted so far), then for an item asked of the game (`C_Item.GetItemInfoInstant`,
  which knows only items the client has seen; unverified on Forever). Items and zones are always ids, so an
  unmatched name is refused with a chat line ("type its id, or drag the item ..."); a faction or an enum keeps the
  text (Farmer keys a faction by name when the game can't give its id). Shift-clicking an item does not put its
  link into the popup's box (that works only in chat-like boxes).
- **Not built:** dragging an item onto the Trackers window or onto empty screen (a new board); a bank count; a
  search box for long lists.

#### As built (HC-60, 2026-11-22): a tile's filter, a set of members

Agreed with the Traveler pack (its "Distance travelled" counts every way of moving; a tile picks which). A reading
declares `param = { dim, multi = true, members, presets, default }` (an `enum` parameter of a small dimension):

- **What it reads:** the sum of a set of members. The set is the tile's (`tile.arg`, a sorted array, saved with the
  board; no migration: absent is the default), else the reading's `default` (a preset's name or a list), else
  **everything**: the counter's whole total, "other" included. `minus` reads the same set.
- **How:** our windows (run, session, the board's) add the members' totals, which they keep per member already;
  storage scopes ask one filtered query per member, each cached 10 s as a single member is. A member past a cap
  is left out; all of them past it read "over the limit". Per hour divides by all active time. Recent and Trend
  are not offered for a set yet (`CalcFits` says "set"). Sparklines and "vs usual" are off on set tiles.
- **Ratios over the same filter** need nothing new: a computed reading with the same `param` gets the set as its
  argument, and `get` passes it to the readings it reads (average speed = filtered distance ÷ filtered time).
  So the queue's "second counter for the rate's denominator" was not built.
- **Choosing:** adding the reading needs no member first (it starts on its default). The tile's menu has
  "Includes: <name>": the reading's presets, then a checklist of its `members` in the pack's order (else the
  members counted so far). Unticking the last one is refused. A set equal to the default is kept as nil, so the
  tile follows the default if the pack changes it.
- **Names:** no set chosen shows the plain title; otherwise the preset it equals, up to three member labels joined
  with "+", else "n kinds".

#### As built (2026-11-24): one reading with a choice on the tile; Hard Counters Basic

The user's call (2026-11-24): fewer readings, each with a choice on the tile whose default reads the whole total,
and names that say what is counted. **Reading ids never change:** a rename changes the title only, and a merged
reading stays readable under its old id. Not seen in game.

- **`param.optional = true`** (one member, any `type`; not with `multi`): no member reads the counter's whole total,
  under the plain title, or `param.anyTitle` when the plain title isn't it ("Spell damage (best school)"). The
  picker starts with an "Any" entry (`param.anyLabel`, e.g. "Any item"). Such a reading is added without a pick
  (`ns.NeedsArg` is false) and never reads `noarg`.
- **A fixed list for one member:** `param.members` without `multi` (an `enum`): the picker offers those, in that
  order (a spell school, a resistance), instead of the members counted so far (`BoardModel.MemberChoices`).
- **Recent and Trend for everything** (HC-60's leftover, in part): `ns.CalcFits(r, calc, scope, who, arg)` takes the
  tile's argument. A set reading reading everything (no set chosen and no default), or an optional one with no
  member, is the whole counter, so it keeps Recent and Trend; a set of some members still says "set". Changing a
  tile's set re-fits its calc (`M.SetArg` calls `M.FitCalc`). Without this Gold/h would have lost its trend in the
  merge.
- **Run lists:** a reading with a parameter is listed when its choice defaults to the whole total
  (`ns.ReadsWhole`: optional, or a set with no default). Hidden readings never are.
- **`hidden = true`:** registered and readable (`HC:Reading`), but out of the catalog, the + menu, the Trackers tab
  and the run lists.
- **`foldInto = <id>`, `foldArg`:** a reading merged into another. It is hidden, and a saved tile (or a preset's
  tile) on it moves to the target, keeping its calc, display, size and name: `foldArg = "same"` keeps the argument,
  `"set"` makes it a one-member set, none drops it (`M.FoldAlias`, at each `Store()` and when readings change; no
  board version bump).
- **`unitOf = <id>`, `unitLabel`:** a unit twin, the same value in other units. It is hidden; the tile menu's
  **Units** lists the main reading and its twins by `unitLabel` (`ns.ReadingUnits`), and `M.SetReading` switches the
  tile's reading, keeping everything else.
- **`pickTitle`** (HC-39 d): the list name of a reading that needs a pick ("In bags: pick an item"), instead of
  "In bags: ...".
- **`param.type = "skill"`** (HC-71): the member is a skill line id. The picker lists the character's skill lines
  under the skill panel's headers (`ns.wow.skillLines`, from `C_SkillInfo.GetNumSkillLines` / `GetSkillLineInfo`),
  narrowed by `param.filter(line)` (`line = { id, name, group }`); labels come by id (`GetSkillLineInfoByID`). Lines
  under a header the player collapsed aren't listed, and the picker says so.
- **Formatters** `seconds` ("2.60 s") and `decimal` (one decimal): weapon speed, DPS, item level.
- Copies (`HC:GetReading`) carry `hidden`, `foldInto`, `unitOf`, `unitLabel` and `param.optional`.

**The merges:**

| Reading (id kept) | Title now | Absorbs (hidden, tiles moved) | The choice; default |
|---|---|---|---|
| `hc:gold` | Gold in (was Gold earned) | `hc:goldfrom`, "Gold from %s" (`"set"`) | source, a set: Loot, Quests, Vendor, Auction house, Mail, Trade, Your characters, Other, Unknown; presets "Loot and quests", "Not from your characters"; everything |
| `hc:goldout` (new) | Gold out | `hc:spenton`, "Spent on %s" (`"set"`) | sink, a set: Repairs, Vendor, Training, Travel, Auction house, Mail, Trade, Your characters, Other, Unknown; preset "Not to your characters"; everything |
| `hc:xpgained` | XP gained | | source, a set: Kills, Quests, Other, Unknown (kills and quests are booked by Farmer); everything |
| `hcfarm:items` | Items looted | `hcfarm:looted`, "%s looted" (`"same"`) | item, optional; any item |
| `hcfarm:rep` | Reputation gained | `hcfarm:repwith`, "%s rep" (`"same"`) | faction, optional; any faction |
| `hctravel:avgspeed`, `topspeed`, `speednow` | yd/s | their `...pct` readings, as unit twins (not folded) | Units: yd/s or % of run speed |

The aliases `hc:goldph`, `hc:netph`, `hc:xpph` still read their targets per hour, the whole total. Renames with no
merge are in the packs' DESIGN files (Farmer §4.9, Traveler §2, Character Stats §8).

**Hard Counters Basic.** Basics registers itself as the pack "Hard Counters Basic" (`ns.RegisterBuiltinPack`, a
private call; `RegisterPack` still refuses `hc`): first in the pack list, the `hc` namespace and every id unchanged,
always on (it ships inside Hard Counters and has no AddOns entry of its own). Its trackers are **Gold**
(`hc:goldph`) and **Experience** (`hc:xpph`), category "Basic" (HC-39 a), never marked *New*. New reading **Level**
(`hc:level`, `now`, in Experience). The core presets Run, Pocket and Leveling carry `pack = "hc"` and the category
`activity` (§17.10). Specs: `tests/merges_spec.lua`, `tests/basics_spec.lua`.

### 16.5 Character or account, per tile (user, 2026-11-18)

A tile setting next to scope and argument: **this character**, **whole account** (later maybe a named character).

| Scope | Account-wide today | Needs |
|---|---|---|
| today, week, month, year, lifetime | yes: the library takes `entity = "account"` | history on for every character involved |
| session, tile window, run | no: totals are in memory for the logged-in character | the saved per-character totals of §16.2: the value is the sum over characters of (total now − that character's baseline); per hour divides by the summed active time |

- Only one character plays at a time, so an account tile moves only with whoever is logged in.
- Stocks: the sum of each character's last known value; a character not seen since install is unknown, not zero.
- Settings are one AceDB profile for every character by default (`UI/Options.lua`), so boards and tracker switches
  are already shared; a character on its own profile with a tracker off contributes nothing.
- "Account" is one WoW account folder (§2).
- **Was open, decided and built 2026-11-19 (FM-16):** mail between your own characters counts on both sides (Farmer
  DESIGN §4.1), so an account-wide "Gold earned" counted it twice; see "As built" below.

**As built (HC-32, 2026-11-18).**

- `tile.who = "account"` (nil: this character), set in the tile's menu ("Counts: this character / the whole
  account"); `HC:Reading(id, scope, arg, "account")` for callers. The tile's label ends ", account".
- **Storage periods:** the query passes `entity = "account"` (also for one member, and for the active time a
  per-hour reading divides by). A character without history adds nothing: say so in the tooltip, not on the tile.
- **A tile's own timer** (since HC-41: the board's account window, `b<n>@account`, §16.8): one window for the
  account (HC-32 had `windows["t<n>@account"]`) instead of one per character. It
  is not a sum over saved baselines as the table above says: like every window it is banked at each login, and
  then carries on with whoever logged in, so its total is what every character added while it ran. Same result,
  no per-character bookkeeping. Its clock is the time played on any character.
- **Stocks (`now`):** the sum of each known character's last value, per member too. A character that never
  loaded Hard Counters is simply not in it (there is no list of the account's characters to say "unknown" for).
- **Login and the open run** are whoever is playing: the same number either way.
- Switching a tile between the two starts its timer over (it is another window). Since HC-41 it reads the board's
  other window instead, which may have started earlier.
- **FM-16 (decided by the user 2026-11-19: own source, account only; built the same day):** Farmer books money mailed
  between your own characters under `alts` (source and sink), from the sender of the mail whose money is taken and the
  recipient of `SendMail` checked against `HC:IsOwnCharacter` (names and realms in `HardCountersDB.chars`). Farmer
  calls `HC:ExcludeOnAccount` for both, so every account-wide sum leaves `alts` out; per character it still counts on
  both sides. Unverified on Forever: `GetInboxHeaderInfo`'s sender, `GetSendMailMoney` after `SendMail` (probe "FM-16
  mail API" checks only that they exist).

### 16.6 Displays on tiles (user, 2026-11-18: all of them; "visual forms" until 2026-11-19, §16.9)

Tile styles today are hero, grid and row: numbers only. Wanted: a **bar toward a target** (XP to level, reputation
to the next standing, 143/200 of an item, a goal the player sets), then gauge and odometer. A reading may declare a
natural `target`; a tile may set its own. A status bar can also show a secret value passed straight through (§3.3).
Queued with HC-33; goals absorb the goals half of HC-3.

**`now` values must redraw when they change.** Boards without an open run redraw on a 5 s ticker
(`BoardModel.TickRate`) and otherwise only on run, zone and tracker events, so gold owned or an item count lags.
Writes should mark tiles dirty and redraw on the next frame; tickers stay for rates and clocks (HC-33).

**As built (HC-33, 2026-11-18).**

- **Redraw on change:** every accepted write sets `ns.dirty` (`Core/Registry.lua`: one assignment on the emit
  path); the boards' frame redraws them on the next frame, at most four times a second (`Boards.OnFrame`). Tickers
  stay for rates and clocks. It is one flag for everything: any write redraws every visible board, period tiles
  included (their queries are small; member queries are cached 10 s). If a polled 4 Hz source ever ships, make it
  per counter.
- **Targets:** a reading may declare `target` (a number, or `function(arg)`); a tile may set its own ("Set a
  target..." in the tile's menu; money in gold), which wins. `HC:ReadingTarget(id, arg)`.
- **`refresh = { events }`** on a computed reading: the engine listens only while that reading is on a shown
  board (`ns.SetPlacedReadings`) and marks displays dirty.
- **The `bar` style:** a row over a track, the value toward the target ("143 / 200"), green when reached. Without
  a target it is a row over an empty track. Drawn with two textures, not a StatusBar, so nothing depends on a
  client template; a secret value can't be shown this way (CS-9 would need a real StatusBar).
- **Shipped:** Basics "XP this level" (target: the level's XP; on the Leveling preset as a bar); Farmer
  "%s standing" (reputation inside the current standing, target: its size; the faction API it reads,
  `C_Reputation.GetFactionDataByID`, is unverified on Forever: no value when it can't say).
- **The gauge (HC-33, the user's choice 2026-11-19; not seen in game, checklist part P):** a half circle of 13 dots on
  the tile's left, lit toward the target (gold, green when reached), the title and "x / target" beside it; 38 px
  high. Plain squares: no rotation, no art (a needle is HC-12's speedometer, parked).
- **No empty bars or dials (statement 17b, built with the gauge):** a bar or a gauge without a target is laid out as a
  row; choosing either for a tile without a target asks "Bar toward:" / "Gauge toward (gold):" first, and cancelling
  keeps the old style.
- **Not built:** the `odometer` display; exposing tile targets and watch lists to packs (what is left of HC-3).

### 16.7 Open (the user's to decide)

1. ~~Does a tile's window survive logout by default, or start over at each login?~~ **It survives** (user,
   2026-11-18): it stops counting at logout and carries on at the next login of its character; the time offline is
   not on its clock. The `login` scope stays for numbers that should start over. The run-at-login prompt goes with
   HC-30.
2. ~~Board-level "start / pause / reset all", and the rule for saving records.~~ **Decided (user, 2026-11-18):**
   boards get "start all / pause all / reset all" (HC-30). A stopped or reset window with 5 active minutes or more
   offers **"Save as run"** in the tile's menu, never a prompt; entering an instance saves a record by itself, named
   after the dungeon; "reset all" on a board saves one record, not one per tile.
3. **Decided 2026-11-19 (user, walking through HC-35), except activation:**
   - *Still proposed, undecided* (HC-35): **activation from use**. A counter runs if a reading on a shown board uses
     it **or** its history is on (so history keeps counting with no tile up; the Ledger tab runs on its history
     switch alone); trackers become catalog folders with no on/off switch; changes TRACKERS_AND_BOARDS §0.3 and §0.8.
   - **One "Keep history" switch** per tracker, on or off; the four presets (lifetime, daily, detailed, days) under
     Advanced (HC-48).
   - **"session", not "login", everywhere:** the player sees "session", so the code follows: the scope id, saved tiles
     (a migration), `HC:Reading(id, "session")`, the docs (HC-49). The login window is already
     `HardCountersDB.windows.session`.
   - **"Add a number…"** on the mini strip's right-click menu, opening one flat, searchable list of readings (HC-50).
   - **No raw counter ids in "Not loaded"**: a counter is named by its title and its pack, with "(pack not loaded)"
     when the pack is absent (HC-48).
   - **As built (HC-48, 2026-11-20):** the Trackers window's history button reads "History on" / "History off" and
     a click switches it (`HC:SetTrackerKeepHistory`): on brings back the last preset chosen (saved as `last` in
     the tracker's settings; a choice made before HC-48 counts), else Daily with the days chosen before, else 14;
     off is the Off preset (frozen, not deleted). The preset is in the tooltip. Right-click: Keep history,
     **Advanced** (Lifetime, Daily 14/30/90/365, Detailed) and Delete history. A tracker that needs history (the
     Ledger) refuses to switch it off while on and says why; off, its button still reads "needs daily history" and
     a click turns the tracker on. `/hc track <n> history on` is the switch. "Not loaded" rows read "Farmer: Money
     out (no longer used)" or "... (pack not loaded)": a counter's title and pack are saved account-wide when storage
     first takes it (`HardCountersDB.names[id] = { t, p }`); data stored before that is named from its id ("money.out"
     → "Money out") and its namespace (this suite's packs are known by name); "no longer used" when its pack is
     loaded but no longer registers it. The Delete confirm uses the name.
4. **Decided 2026-11-19:** Character Stats phase 1 is about 15 live `now` readings with no counters (needs HC-28
   only; HC-26 and HC-27 are built anyway, for phase 2 and for gold owned), and no "≈" derived rows before CS-7
   (Character Stats DESIGN §10). CS-8 gets one more probe first (option b).
5. **Decided 2026-11-19:** parked behind §16: HC-20, HC-4, HC-8 and the rest of HC-12. HC-15 and HC-22 stay open
   with the playtest's redirects. Deleted (HC-49): `RegisterRunReading`, `SetWindowDocked`, the `/hcf` aliases and the
   `runTracked` flag. Its last effect, forcing the `lifetime` grain on counters that keep history
   (`Core/Registry.lua`), goes with it: every history preset already includes `lifetime` when the counter declares
   it, so nothing stored changes.
6. **Decided 2026-11-19:** a tile's calc, display and size (§16.9). **All confirmed by the user the same day:**
   `HC:Reading`'s shape for the calc is an options table, `HC:Reading(id, scope, { arg, who, calc })`, and the
   positional `HC:Reading(id, scope, arg, who)` keeps working (with HC-51); `recent`'s half-life is **5 minutes**,
   fixed, not a setting; `recent` and `trend` are **settled after 5 active minutes and 5 gains** in their window; the
   trend's **dead band is ±10%**; no literal "last hour" window in v1.

   **As built (HC-49, 2026-11-19; checklist part R):** the scope is `session` in the code (`ns.SCOPE_ORDER`, the
   default `{ "run", "session" }`, Basics, Farmer, labels "· session", the Trackers window's tips "this session");
   `login` is refused with no alias; saved tiles move once per profile (`boards.v = 4`). `HardCountersDB.login` (the
   real login time) keeps its name: it is a login. Deleted: `HC:RegisterRunReading` (and `per = "hour"`),
   `HC:SetWindowDocked`, Farmer's `/hcf` and `/farmer`, the `runTracked` flag with its forced `lifetime` grain
   (no shipped counter declares its own grains, so all keep `lifetime` through the defaults: nothing stored changes).
   `/hcdiag` was not in the decision and stays.

### 16.8 HC-41 design note: the board is the clock (agreed 2026-11-18; built the same day)

Agreed in the playtest (QUEUE HC-41): a board has one window and one clock; tiles follow it; to pause one tile, move
it to a board of its own; "Save as run" is per board. This note says how, from a reading of what HC-30 built
(`BoardModel.TileWindow`, `Core/Odometer.lua`). **The user agreed it on 2026-11-18, taking the recommended choice on
all four points marked "decided" below.**

**What changes.** Today a tile with the `run` scope owns a window `t<wid>@<character>` that watches only its
reading's counters, without per-member totals (`noBy`), plus one member for a tile with an argument (`w.mem`).
After HC-41:

- **One window per board and character**, `windows["b<wid>@<character>"]`. `board.wid` comes from
  `HardCountersDB.windowSeq` like tile ids today: board ids (`b2`) are per profile and profiles share
  `HardCountersDB.windows`, so they can't name it. Made when the board is first drawn on a character; dropped with
  the board.
- **It watches every active counter, with the per-member totals of small dimensions** (no `ids`, no `noBy`). That is
  what makes a moved tile cheap: its numbers are already there. Cost: a base is copied at each start, resume and
  login (about ten counters with Basics and Farmer; their small dimensions are tens of members: a few KB per board
  per character while counting, nothing while paused, since a pause drops the base). The emit path doesn't change.
- **Tiles with the `run` scope read the board's window** (`ns.ReadingOver(reading, boardWindow, arg, who)`); other
  scopes (login, today, now, ...) are untouched and don't follow the clock. Their label loses the clock: "Gold/h",
  not "Gold/h · 12:48"; the scope word stays only for the other scopes ("Gold/h · login"). In the tile's menu the
  scope reads "the board's timer".
- **The clock is shown once**: the control row on a full board, the strip on a mini board. Pause / Resume, Stop,
  Reset and "Save as run" act on the board's window. The tile's own Pause, Stop, Reset and Save as run go, and so
  does Alt + right-click on a tile (HC-2(d) becomes moot).
- **Move to ▸** in the tile's menu (edit mode): the other boards, then "New board" (named after the tile, made
  running). The tile moves with its settings; nothing is dropped, since it owns no window.

**What a moved tile shows on its new board.**

- **A plain reading, or one whose argument is in a small dimension** (a source, a sink, a zone, a faction): the new
  board's whole period at once. Every per-member total of a small dimension is in the board's base, so
  `Win.MemberTotal` reads it exactly. Same for "Gold/h", "Net gold/h": per hour divides by the board's active time.
- **An argument in a big dimension** (an item): the odometer keeps such a member only once something watches it
  (HC-31). If the member was watched before the board's base was taken, it is in the base: exact. If not, the
  board counts it **from when it was first watched** (`ns.WatchMember` adds it to every counting window's base at
  0 and notes the time in that window, `w.late[counter][member]`). The tile then says so: "Linen Cloth looted
  (since 14:02)", until the board is reset. Never a silent short count.
- **The best single value** ("Best drop"): the window keeps a best per counter (`w.max[counterId]`, today one per
  tile window, `maxOf`), so a moved "Best drop" tile reads the board's best of its whole period.
- **A tracker switched on mid-period** counts from then (its counter has no base): as today, no marker. Worth one
  only if it confuses in play.

**Records.** "Save as run" on a board snapshots its window: every counter, so the record is no longer `partial`
(other readings can be asked over it later); item lists still need HC-2(c). "Reset" saves one record when there
were 5 active minutes, as "Reset all" does now. Dungeon runs and `/hc run` are the character's open run, not board
windows: unchanged.

**Account tiles (decided: a).** HC-32 made "this character / the whole account" a tile setting. With one clock per board:

- *(a, chosen: keeps the decision)* a board also gets an account window `b<wid>@account`, made only when one of
  its tiles is account-wide; both windows start, pause and reset together. The clock shows the character's window.
  After switching characters the account tiles' period includes the other character's play, which is what
  "account" means.
- *(b)* "Counts: this character / the whole account" moves to the board (one window, one clock). Simpler, but it
  changes the HC-32 decision.

**The control row (decided: drawn by itself).** Today it is a tile (`kind = "run"`) that the Run preset has and other boards don't, so a
full board without it has a clock nobody sees and no Pause. *(Chosen)* the row is drawn by itself at the top of
any full board with a tile on the board's timer, and `kind = "run"` tiles are dropped at the update.

**Presets (decided: the board's timer).** Pocket's tiles are on `login` and Leveling's on `login`/`now`, so the board's clock wouldn't move
them: Pocket's strip would pause nothing. *(Chosen)* new boards' preset tiles use the board's timer, except
`now` and the history scopes. Existing tiles keep their scope (the player chose or kept it); a menu change moves one.

**The update (decided: start fresh).** Tile windows can't be merged into one board window: they started at different times.
*(Chosen)* every board starts its window at zero at the first load of the new code, and the old tile windows
are dropped. You are the only player; your one long-running tile window is Pocket's "Gold/h, own timer" (since 07:01
today). The alternative saves each tile window with 5 active minutes as a record first.

**Confirmed by the user 2026-11-20:** this note stands as built. A tile on a board may keep another scope
(session, today, now, ...), and only tiles on the board's timer follow its clock, Pause and Reset. It came up when a
board Reset left its session tiles counting (Leveling: XP/h, Gold/h recent and Vendor value on session); dropping
`session` from tiles was offered and declined.

**Decided the same day, built the same day (HC-55, "As built" below): a scope for the board.** A board has a scope; new tiles follow the board
by default and a tile can still keep its own (this note stands). Switching the board's scope moves every following
tile. The board's scopes are the tiles' scopes as they are (the board's timer, session, today, week, month, year,
lifetime: "these scopes exist horizontally"). The board's timer is the default and today's behaviour. **On a board
not on its own timer, Pause and Reset are hidden** (not greyed). The rest is in QUEUE HC-55 as proposed and not
objected to: header shows the scope once, following tiles show no scope word, `run` tiles become "follow the board"
at the update, presets follow the board except `now` tiles.

**As built (HC-55, 2026-11-20).** `board.scope` (nil: the board's timer; else session, today, week, month, year,
lifetime: `BoardModel.BOARD_SCOPES`) and `tile.follow`. A following tile's `scope` is kept equal to the board's, so
everything that reads a tile's scope is unchanged; `BoardModel.SetBoardScope` moves every following tile. A following
tile whose reading lacks the board's scope (Rested XP has only `now`; Time to level has no calendar scope) keeps the
nearest it has, never the timer off the timer, and comes back when the board does; its label then names its scope.
- **Labels:** a tile shows its scope word only when it differs from the board's (on the timer: as before).
- **The header** (the control row) on a board off its timer: "Leveling · session" with the session's active time, or
  "Leveling · today" with no clock; Pause, Reset, Stop and Save as run are hidden (`BoardModel.OnTimer`); the mini
  strip shows the session's time or the scope word, and its dot and click pause nothing.
- **Leaving the timer pauses it** (it would count with nothing to show it, `board.held`); coming back resumes it if
  leaving paused it, so the period carries on. One the player paused stays paused.
- **New tiles** on the board's scope follow; the tile menu's Scope list marks "(the board's)" and, off the timer,
  doesn't offer the timer. Picking the board's scope makes a tile follow; any other gives it its own.
- **The board's menu ▸ Scope:** a calendar scope is greyed "(needs history)" while a following tile's tracker keeps
  none; clicking it offers to turn daily history on for those trackers, then switches.
- **Moved tiles** (Move to) that follow take their new board's scope; a tile with its own scope keeps it.
- **The update** (`boards.v = 5`, per profile): tiles on the timer follow, others keep their scope; presets' timer
  tiles follow.
- Recent and Trend: unchanged rules (the timer and the session; elsewhere a tile falls back to per hour). No new files.
- **Known limit:** a reading with only the timer scope (Farmer's "Best drop") can't follow a board off its timer: it
  keeps reading the board's window, which stays paused while the board is elsewhere.

**Built on this, later:** HC-51 (a tile's calc, §16.9) divides by the board's active time; HC-42's edit handle
and HC-22's drag handle use Move to. **Not in HC-41:** splits (the open run's), the comparison line (records).

**Size:** `Core/Odometer.lua` (watch adds to bases, `w.late`, best per counter), `UI/BoardModel.lua` (board windows
replace tile windows, `MoveTile`, labels, records), `UI/Boards.lua` (menus, the control row), `Core/Runs.lua` (best per
counter), `Core/Migrations.lua` (the update). No new files. Specs: the tile-window specs are rewritten for board
windows; new ones for a moved tile (small and big dimensions, best, account), the late marker and the update.

**As built (HC-41, 2026-11-18; not seen in game, checklist part O).**

- **Board windows** (`BoardModel.BoardWindow`): `windows["b<wid>@<character>"]`, made when the board's first tile on
  its timer is placed or drawn; a board with only `login`, `now` or history tiles has none, and no clock or control
  row. `board.wid` comes from `windowSeq`. Deleting the board drops its windows on every character; removing or
  moving a tile drops nothing.
- **Late items** (`Core/Odometer.lua`): when `ns.WatchMember` starts keeping a member, every board window of this
  character (and the account's) that has run before notes the time in `w.late[counter][member]`. Nothing is added to
  the bases: the odometer's member starts at 0, which gives the same count. The tile's label says "Linen Cloth looted
  (since 14:02)" until Reset (or a start after Stop); a pause doesn't clear it. Each window keeps a list of the
  members its tiles show (`w.watch`) and keeps them before taking a base, so an account window arriving on another
  character counts them from its first moment there, without a marker.
- **Best per counter:** every board window counting keeps `w.max[counterId]` (`ns.maxWatch` lists the board windows
  in use; `Runs.lua` updates them on the emit path). A board's record keeps them (`rec.live[counter].max`), so "Best
  drop" also answers over a board's record.
- **Records:** "Save as run" on the board (its menu, the strip's menu) saves its window: every counter, not
  `partial`, labelled with the board's name. After Stop then Start the ended period can still be saved ("Save the
  last period as a run"). Reset saves only the period it ends, when it had 5 active minutes.
- **Labels:** tiles on the board's timer show only their title ("Gold/h"); other scopes keep the word ("Gold/h ·
  login"); account tiles add "· account" (or ", account" after a scope word). The hero's comparison line now
  compares the board's value (HC-30 compared the open run's, so it showed nothing without a run).
- **The control row** is a layout row with no tile (`M.Layout`, kind `run`), on full boards with a tile on the
  timer, not in a mini board's flyout (the strip has the clock). In edit mode right-clicking it opens the board's
  menu. The [+] menu no longer offers "Board controls".
- **Move to** (tile menu, edit mode; `M.MoveTo`, `M.MoveTargets`): the other boards (hidden ones marked), then "New
  board", named after the tile (32 characters), shown, its timer started when it is drawn. The board it lands on is
  shown and the tile flashes (`Boards.Reveal`).
- **Account:** the account window is made with the board's first account tile on the timer and copies the
  character window's state (paused or stopped) when made; both follow every control. Switching a tile back to "this
  character" reads the board's own window (no restart).
- **Removed:** per-tile Pause, Stop, Reset and Save as run; Alt + right-click and its `MODIFIER_STATE_CHANGED` handler
  (HC-2(d) is moot); `M.SaveTile`, `M.HasRunTile`, `Boards.TimerMenu`.
- **The update:** migration `hc41` (`Core/Migrations.lua`) drops every `t<n>@...` window once; each profile, at its
  first use (`M.Store`, `boards.v = 2`), loses its `kind = "run"` tiles and `tile.wid`. Existing tiles keep their
  scope, so Pocket's tiles that were on `login` stay there; a tile that was on its own timer is now on the board's,
  from zero. Nothing is saved as a run on the way.
- **Cost:** a base per board window copies every counter's odometer with the members of small dimensions, at each
  start, resume and login (a few KB per counting board); nothing while paused.
- **Not built:** item lists in board records (HC-2(c)); a marker for a tracker switched on mid-period.

### 16.9 A tile's parameters: calc, display, size (agreed 2026-11-19; HC-51 to HC-53 built the same day)

Agreed with the user on 2026-11-19, from two problems. (1) Every per-hour reading is an **anchored average** (the
scope's total ÷ its active time), so after an hour or two it barely moves and nothing shows the current pace.
(2) Per hour is baked into readings, so the catalog has pairs (Gold/h + Gold earned, Net gold/h + Net gold, XP/h + XP
gained) and misses most rates (Rep/h, Items/h, "Gold from %s"/h). Fix: **more parameters on the tile, fewer
readings.** The kind of number is not a scope: scope is *over when*, and it combines with every kind ("Gold/h ·
today", "Gold earned · today"), so folding the kinds into scopes would multiply the scopes instead.

**The parameters of a reading tile:**

| Param | Answers | Values | Before §16.9 |
|---|---|---|---|
| `reading` + `arg` | what is counted | `hc:gold`; "Timbermaw" | same |
| `scope` | over when | run (the board's timer), session, today, week, … | same |
| `who` | whose | this character or the account | same |
| **`calc`** | which number | `total`, `perHour`, `recent`, `trend` | baked into the reading (`per`) |
| **`display`** | drawn as | `number`, `bar`, `gauge`; later `odometer` (HC-33) and others from §7 | half of `style` |
| **`size`** | how much room | `large`, `half` (pairs up), `line` (full width; height from the display) | the other half of `style` |
| `target` | toward what | a number, or the reading's own | same |
| `name` | label override | | same |
| **`extras`** | additions to the number | `sparkline`, `trend` (a badge), `vsUsual` ("+18% vs your average here") | built into hero |

**Words (agreed):** `calc`, shown in the UI as "Show as"; `display`, the §7 word (a display declares what it
accepts); `size`. "Form" is retired: it meant displays in §16.6 and would have meant calcs too. `measure` stays
inside the reading (how counter rows combine: sum, count, min, max, avg); `calc` is what the tile does with the
measured value over its scope. Keep `extras` to the three above: more turns the tile menu into a settings page.

**The calcs:**

- `total`: the scope's value (today's reading without `per`).
- `perHour`: ÷ `hc:time.active` over the scope (today's `per = "activeHour"`).
- `recent`: an exponentially weighted rate. On each active tick of `dt` seconds: `k = exp(-dt/tau)`, `S = S*k + gain`,
  `T = T*k + dt`, `rate = S / T`. No cliff when a big gain ages (a trailing window drops it all at once); no warm-up
  rule (T starts small, so early on it is the plain average); AFK freezes it (decay only on active ticks); two numbers
  per counter per window. Kept for windows that have their own clock: the board's timer, the open run, the session.
  Calendar scopes don't offer it (it would equal the session's). Label "Gold/h recent".
- `trend`: `recent / perHour - 1` over the tile's scope, a signed percentage. Not a derivative: differentiating a lumpy
  rate amplifies the noise. Shown only when both are settled; a dead band shows it neutral. Different from `vsUsual`,
  which compares to this zone's past runs: the two keep different words.
- **Settled** for `recent` and `trend` also needs a minimum number of gains, not only 5 active minutes.
- **Which readings allow which calcs:** flows all four; stocks `total` only; a `compute` reading lists `calcs` and
  receives the calc ("Time to level" with `recent` = at your current pace). Account tiles: `total` and `perHour` only.
- Titles: a reading has `title` ("Gold earned") and an optional `rateTitle` ("Gold/h"; default `title .. "/h"`).

**Which display accepts which calc** (a display also declares the sizes it can draw):

| display | total | perHour | recent | trend |
|---|---|---|---|---|
| number | yes | yes | yes | yes (signed %) |
| bar | with a target | with a target (a goal: 100g/h) | no | no |
| gauge | with a target | with a target (later: your average or best as the range) | yes, the natural fit | no |
| odometer (HC-33) | yes (lifetime totals) | no | no | no |

**Migration** (one pass over saved boards and presets, with the calc refactor, HC-51): hero → `size = large,
display = number, extras = { sparkline, vsUsual }` (drawn only where they apply: a stock shows neither); grid →
`half, number`; row → `line, number`; bar → `line, bar`; gauge → `line, gauge`. A tile on `hc:goldph`, `hc:netph` or
`hc:xpph` → `hc:gold`, `hc:net`, `hc:xpgained` with `calc = perHour`; the old ids stay as hidden aliases, so
`HC:Reading("hc:goldph", scope)` keeps its value. `RegisterReading` with `per = "activeHour"` means the default calc
is `perHour`; `RegisterBoardPreset` tiles with `style` are read through the same map, so packs keep working until
they move (FM-17, CS-11). The board's hero (the mini strip's number, the Pocket strip) is its first `large` tile.
New combinations (a half gauge, a large bar) are allowed by the model; each needs its drawing, so HC-51 ships only
today's footprints. Aliases stay out of HC-50's flat list and the + menu.

**Order:** HC-51 (the axes, `total` and `perHour`, the migration; absorbs HC-46), then HC-52 (`recent`), then HC-53
(`trend` and the badge). HC-49 (`login` → `session`) lands before HC-52, which keeps `recent` per session. Open
points: §16.7.6.

**As built (HC-51, 2026-11-19; not seen in game, checklist part R).**

- **The calc** (`Core/Readings.lua`): `ns.CALC_ORDER = { total, perHour }`; `ns.ReadingCalcs(r)` (flows both; stocks,
  `best`, `min`/`max`/`avg` and `compute` without `calcs` total only), `ns.DefaultCalc(r)`. `HC:Reading(id, scope,
  { arg, who, calc })` (the user's choice), `ns.ReadingOver(id, w, arg, who, calc)`; a calc not allowed → state
  `"calc"`. `compute(get, scope, arg, calc)`, `get(id, scope, calc)`. `rateTitle` (default `title .. "/h"`),
  `ns.ReadingTitle(r, arg, calc)`, `ns.FormatReading(r, v, calc)`. Run records: `Widgets.RecordReading(r, rec, calc)`.
- **Aliases:** `RegisterReading(id, { aliasOf, calc })` copies its target's rules, is kept in `ns.readings` and in
  `ns.readingOrder` (the run list, the summary card, the launcher's headline are unchanged) but not in
  `ns.allReadingOrder` (the + menu, the Trackers window, `HC:Readings()`). Basics: `hc:goldph`, `hc:netph`, `hc:xpph`.
  **Visible consequence:** the + menu and the Trackers window lose the Gold/h, Net gold/h and XP/h rows; per hour
  is "Gold earned" ▸ Show as ▸ Per hour (HC-50's flat list should offer the per-hour names as search words).
- **`per = "activeHour"`** (packs before FM-17): default perHour; without `rateTitle` the reading allows perHour only
  (its title is the rate's: "Vendor value/h" can't be shown as a total under that name).
- **Tiles** (`UI/BoardModel.lua`): `calc` (nil = the reading's default), `display`, `size`, `extras` (a set:
  `{ sparkline = true, vsUsual = true }`). `M.DISPLAYS` declares each display's sizes and calcs; `M.Footprint(tile)`
  maps a tile to today's drawings (large number → hero, half → grid, line → row, bar, gauge; a bar or gauge with no
  target → row). The hero is the first `large` tile; its sparkline and comparison line are drawn only when the extra
  is on. A natural target applies to `total` only (`M.TileTarget`). `M.SetCalc`, `M.SetDisplay` (a size it can't draw
  becomes its first), `M.SetSize` (Big adds both extras the first time), `M.CalcChoices`, `M.SizeChoices`.
- **The tile menu** (`UI/Boards.lua`): Style is replaced by **Show as** (only with 2+ calcs), **Display**, **Size**
  (only with 2+ sizes), each entry with a tip. Names are placeholders: Total, Per hour; Number, Bar, Gauge; Big,
  Half width, Line (HC-39(e) is the user's call).
- **The migration:** per profile at its first use (`M.Store`, `boards.v = 3`): `style` → display, size, extras by
  the map above (`M.STYLE_MAP`, `M.ApplyStyle`), and twin tiles → target + perHour (`M.FoldAlias`; a static map for
  Basics' twins, so it doesn't wait for Basics). A pack's alias registered later folds its tiles when readings
  change (`M.FoldAliases`, from `ns.OnReadingsChanged`). Built-in presets are written on the new model; a pack's
  preset `style` is read through the map (`RegisterBoardPreset` also takes `calc`, `display`, `size`, `extras`).
- **Not built:** `recent` (HC-52), `trend` (HC-53); new footprints (a half gauge, a large bar); an Extras menu.
- Specs: `tests/calc_spec.lua`; `boards_spec`, `bars_spec`, `states_spec`, `windows_spec` assert the new tile shape
  and menus (the values they check are unchanged).

**As built (HC-52, 2026-11-19; not seen in game, checklist part R).**

- **The rate** (`Core/Odometer.lua`, `Win.Recent`): over the window's active seconds A, S = the gains each weighted
  `exp(-(A - A_gain) / tau)`, T = `tau * (1 - exp(-A / tau))`, rate = S / T per second × 3600. The same as the
  per-tick formula above, in closed form, so T needs no state and the decay is applied lazily. Half-life 300 s.
- **State** in the window, saved: `w.ew[counter] = { s, x, a, n, r, ra }` (S; the window's total and A when last
  folded in; gains; up to 10 samples), `w.ew.c` for counts, `w.ew.m[counter][dim][member]` for members. Reset and a
  restart clear it; a new session starts without it.
- **Folding:** on every read, and every 15 s (`ns.FoldRecent`, a scheduler job, plus every flush: a pause or a
  logout) for every active flow of every counting window of this character (not the account's). A gain folded by
  the job is dated in the middle of its 15 s (HC-53 fixed this: HC-52 dated it at the end, up to 3.5% too heavy);
  a shown board reads on every write, so its gains are dated exactly. The emit path is unchanged.
- **Late starts:** a counter or member first seen in a window that already ran starts from the window's average
  (S = total × T / A): a window older than this code, or a member asked for the first time. No marker; it converges
  within a few half-lives. A member's gains toward "settled" count only from its first ask.
- **Where:** `ns.CalcFits`: scopes `run` and `session` (a board's timer is `run`), this character, not a `zone`
  argument (its rate would need the time in that zone weighted the same way). Elsewhere the state is `"calc"`; the
  tile menu greys Recent with why ("needs the board's timer or session", "this character only", "not on a bar",
  "not for one zone"), and a tile whose scope, who or display no longer fits falls back to per hour
  (`M.FitCalc`).
- **Displays:** number and gauge take recent, bar doesn't. The mini strip shows a recent hero as is.
- **The half-life stays 5 minutes (agreed 2026-11-19, after the first play).** The user found the rate slow to
  come down after a burst. That is the maths: after a lump G the recent rate carries a bump that adds up to G
  whatever the half-life; a shorter one only makes it taller and shorter. On the first play's Pocket board (gold
  1g54s/h, 92% of it lumps: vendor sales, quests, mail) a 50s sale reads +270% and is back within ±10% after
  24 minutes; a 3-minute half-life gives +450% and 16 minutes, a 2-minute one +675% and 12 minutes, and steady
  gains every 3 minutes would swing +39%/-31% and +61%/-43% instead of +22%/-19%, which the trend the user likes
  is made of. Only dating a lump back over the time before it (a vendor sale earned by the farming before it), or
  leaving lumps out, makes the bump smaller: neither is built. Per hour (the average) never comes down after a
  lump, only dilutes; at the time of that play every rate tile on the user's boards was per hour.
- **The sparkline** plots the counter's recent rate at each of the last 10 active minutes over the tile's window
  (`M.RecentSparkline`, whatever the tile's calc); until two minutes are sampled it shows gains per minute as before.
  "vs your average here" on a recent tile compares with past runs' per hour (records have no recent).
- **Basics:** "Time to level" lists `{ total, recent }`; with recent it divides by your recent XP/h ("Time to level
  (current pace)"). `HC:Live` is unchanged (wall clock, `liveRate` counters).
- Specs: `tests/recent_spec.lua` (the half-life exactly, a change of pace, settled, AFK, net, scopes, `/reload`, time
  to level, a board's pause and reset, the menu's greying and fallbacks, the sparkline, records).

**As built (HC-53, 2026-11-19; not seen in game, checklist part R).**

- **The calc** `trend` (`Core/Readings.lua`): `(recent / perHour - 1) × 100` over the same scope and window, a
  signed percent, its text in words since HC-54 (`ns.TrendText`, below); no value until both are settled; where
  `recent` fits only. Allowed wherever `recent` is (flows, `per` readings), not on a `compute` reading unless it
  lists it. Title "Gold/h trend".
- **The dead band:** `ns.TREND_BAND = 10`; `ns.TrendState(v)` is "up" (≥ +10%), "down" (≤ -10%) or "flat".
- **As a tile:** Show as ▸ Trend, number only (a bar or gauge falls back to per hour). The value is green up, red
  down, white inside the band.
- **As the badge:** the `trend` extra on a large per hour or recent tile (`M.TrendBadgeFits`): an arrow texture
  (`Interface\Buttons\Arrow-Up-Up` / `Arrow-Down-Up`, desaturated then tinted: the art is gold, so red alone drew
  orange, seen 2026-11-20; none when flat; the textures exist on Forever) and the coloured words beside the big
  number. Off by default; the tile menu's "Trend badge" switches it (`M.SetExtra`). Worded apart from vsUsual: the
  badge is "your pace now against this period's average", vsUsual "vs your average here" (past runs in this zone).
- **Reality check (2026-11-19, from the specs):** gains come in lumps, so right after each one `recent` sits above
  the true rate by `(dt/tau) / (1 - exp(-dt/tau))` and decays below it before the next (dt: time between gains):
  about +2% at one gain every 15 s, +7% at one a minute, **+23% / -19% at one every 3 minutes**. So for sparse gains
  (gathering, quest turn-ins) the trend swings out of the ±10% band between gains, at a steady pace. The dead band
  hides it only for gains more often than about every 90 s. Options if it shows in play: a wider band, comparing a
  rate sampled at the folds instead of the peak, or a minimum gap since the last gain. The user's call.
- **In words (HC-54, agreed after the first play, built 2026-11-19; not seen in game):** `ns.TrendText` reads
  "on pace" inside the band, "87% slower" below it, "13% faster" above it, and from twice the pace a multiple
  ("2.7× faster", one decimal under 10, "12× faster" from there). The words follow `ns.TrendState`, so they agree
  with the colour and the arrow. Why: the bare % was lopsided (never below -100%, one vendor sale +270%) and said
  nothing of what it compares. Tile, badge and `HardCounters:Reading`'s text alike; the value stays the signed %.
  "×" is Latin-1 (UTF-8 C3 97), unseen in the game's fonts. The words are the user's call with HC-39(e).
- **Fixed after the first play (2026-11-19):** a big tile switched to Trend kept its "vs your average here"; past
  runs read their total for `trend`, so it printed "-100% vs your average here". A run record has no trend now
  (`W.RecordReading`, like recent) and the comparison skips trend tiles (`compareFor`).
- **Not built:** an arrow on the mini strip; the badge on half or line tiles; a separate Extras menu.
- Specs: `tests/trend_spec.lua` (the value, the band and signs, not before settled, where it fits, the tile and its
  fallback, the badge's rules, the badge drawn on screen through the tile menu).

#### As built (HC-63 a and b, 2026-11-22): the odometer and the mix

Decided for the Traveler pack (its DESIGN §5, §8.7: built at the start of its phase 1). Two more values of a
tile's `display`, each a full-width row of its own, offered in the Display menu only where they fit:

- **Odometer** (HC-33's leftover): the total as digit wheels under the title, zero-padded to 6, at most 9 (past
  that, or for a state such as "off", the tile writes its text). A digit that changes rolls up into place over
  0.3 s (two font strings in a clipping frame per wheel; the row's `OnUpdate` runs only while a wheel rolls). The
  total only (a per hour tile moves to the total); offered for `number` and `distance` readings ("yd" after the
  wheels), not money or durations, which have units of their own.
- **Mix**: one bar split into a part per member of the reading's small `enum` dimension, largest first, five parts
  and then "other" (grey); under it each part's share in its colour ("run 45%  mounted 30%"). Members: the tile's
  set for a set reading (HC-60), else the members counted so far; each part is the reading read for that one
  member over the tile's scope. The total only; not for big dimensions (too many members) or readings without a
  parameter. `BoardModel.MixParts` returns the parts.
- A display the reading no longer fits draws as a number. No live pass-through (both need arithmetic).
- Specs: `tests/odomix_spec.lua` (digits, where each fits, the parts and "other", the wheels set and rolled on
  screen, the shares written, the Display menu).

## 17. The main window, rebuilt in the spirit of the Auction House (agreed 2026-11-23; built the same day, HC-65 to HC-70)

The user, 2026-11-23, after three mockups: the Hard Counters window is the one-stop panel, modelled on the Auction
House (and Auctioneer): predictable tabs, clear categories, quick clicks, and deep search and filtering still there
for demanding players. Queue: HC-65 to HC-70 (order in §17.7). Supersedes HC-44(a) and answers HC-38.

### 17.1 Words

The stack is **counters → trackers → readings → tiles → boards**. Counters are storage and never shown to players;
a tracker is what the player switches on (it needs counters); a reading is a number a tracker offers; a tile is a
reading the player placed, with its choices (§16.1); a board is a HUD stack of tiles.

### 17.2 Tabs

> **Swapped 2026-11-24** (the user's call; "As built" below): Hard Counters' own tabs are now the right-side icon
> tabs and the packs' windows and Diagnostics the bottom tabs. The bullets below say where each set is now; until
> 2026-11-24 it was the other way round.

- **Right-side icon tabs, Hard Counters' own, in this order:** Overview, Boards, Trackers, Runs. A new player lands
  on Overview, the casual tab (HC-38a). Blizzard's `LargeSideTabButtonTemplate`, as on Forever's profession window
  (`Blizzard_Professions/Camelot/Blizzard_ProfessionsFrame.xml`); the title is the tooltip. They hang off the
  frame's right edge (no width taken); 10 fit beside the 640-high window (55 high, 2 apart, the first 60 down:
  HC-65), then the column scrolls vertically.
- **Bottom tabs:** every pack's window (Ledger, Character Stats, any later pack) and **Diagnostics**, which stays in
  the main window (the user overrode HC-44(a): one-stop panel). `RegisterWindow` gains an `icon` field.
- **Tab labels are an option:** icon only, title only, icon and title (the bottom tabs; side tabs are always
  icons). Icon only shows the title as a tooltip. `PanelTabButtonTemplate` has no icon slot: we add the texture.
- **Overflow:** tab content scrolls vertically when taller than the panel; the side column scrolls when too long.
  Abbreviating titles stays a fallback. `ScrollableTabsContainer` is Mainline-only in the Forever source (not
  reusable); `TabSystemTemplate` loads on Forever but has no overflow handling.
- The panel keeps one size for every tab (§7.1, 2026-11-23). With content scrolling, that size can become a design
  size (the browser layout needs about 780 wide) instead of the tallest tab's minimum; settled when the browser is
  built.

#### As built (2026-11-24): the tabs swap places

The user's call (2026-11-24). `UI/Windows.lua`; not seen in game.
- **Which column now:** a window Hard Counters registers itself (`ns.Windows.Register`) is an icon tab down the
  right edge, sorted by `def.tabOrder` (Overview 1, Boards 2, Trackers 3, Runs 4, Guide 5); one registered through
  `HC:RegisterWindow` (every pack, and Diagnostics) is a tab along the bottom, in load order, Diagnostics last.
  Templates, sizes, clamping and scrolling are as in §17.8; only which set goes where changed.
- The **Tab labels** option now shapes the packs' tabs. Hard Counters' own are icons, the title as the tooltip.
- With no tab selected yet the window opens on the first side tab, Overview.
- **The frame's title names the open tab** ("Hard Counters: Boards"), since Hard Counters' own tabs carry no words
  now. The tutorial (§17.13) says the tabs are down the right edge.
- Known costs, accepted: the casual player's main tabs lose their words (the title and the tooltips make up for it);
  with no pack loaded and Diagnostics off, the bottom row is empty.
- Character Stats' tab asks for the height of the rows this character shows (`minSize`) and lays out again when a
  section is turned on; it asked for room for every row before, and scrolled.

### 17.3 The browser layout (one widget, used by Trackers and Diagnostics)

Category tree on the left; a search box and a **Filters** dropdown on top (casual players see only search and the
tree); a list with sortable columns and a scroll bar; a detail pane for the selected row; an action bar whose
buttons follow the selection. One shared widget, so every tab behaves the same.

### 17.4 Each tab

- **Overview: your tiles** (note #9 of the 2026-11-20 playtest). The player's own collection of tiles, with a search
  box, **grouped by board** (HC-73, the user 2026-11-23, replacing the free sections of HC-67): one framed panel per
  board with its name and status, its tiles in the board's order; the tiles on no board last, unframed, under
  "Window only", with dashed cards. Click a tile: edit, show on HUD, remove; click a board's header: the board's
  actions. "Add tile" goes to Trackers.
- **Every tile lives in the collection; some are also on HUD boards** (the user's rule). So a tile exists apart from
  boards: a board holds references to collection tiles, and each placement keeps only its order and size. Reading,
  argument, scope, character or account, calc, display, target, name and extras belong to the tile and are shared:
  edit it anywhere and the HUD follows. Migration (BoardModel v6): every existing board tile moves into the
  collection. Settings only, no storage change. Copies were rejected: they drift apart.
- **Boards.** "Your boards": name, status (Shown; Hidden by rule, naming the rule; Off; Off screen?), tiles, mini.
  Actions: New board, Show or Hide, Show all / Hide all, **Show now** (ignores the rules for a while), Edit on screen,
  Edit all, **Reset position** (centre of the screen, scale 1), Duplicate, Save as preset, Delete. Hovering a row
  flashes that board on screen, raised above the window (strata HIGH) until the pointer leaves. "Presets": the
  built-in presets grouped by pack plus "Your presets"; create a board from one, save a board as one (HC-22's
  player presets), edit, delete. Categories beyond the pack stay HC-57 (proposed; built 2026-11-24, §17.10).
  Boards are clamped to the screen,
  so they go missing by rules, mouse-over fade, a tiny scale, Blizzard frames on top or a UI scale change: the
  status column, Show now and Reset position cover those.
- **New board dialog.** Every way to make a board opens it (Boards tab, the launcher, a board's [+] menu, Options;
  `/hc board new` without a name). Fields: **Name** (required, at most 24 characters, unique ignoring case; starts
  as the preset's name; a taken name suggests "<name> 2"; shows the `/hc board` command that will toggle it),
  **Start from** (presets by pack, your presets, Empty board, Copy of a board: its own tiles, not shared), **Show it**
  (always, in combat, in instances, during runs: the board's existing flags). Create puts the board at the centre
  of the screen with one flash; an empty board opens in edit mode. Enter creates, Escape cancels; DIALOG strata.
  Rename enforces the same uniqueness, so `/hc board <name>` is never ambiguous. `/hc board new <name>` with a name
  creates directly.
- **Trackers: the catalog and management** (the playtest's note #3; HC-39's words apply). Tree from each tracker's
  `category` (Basics, "Basic" since 2026-11-24; Farming, Travel, Character, ...) plus "Not loaded"; columns Name, On, History, Size; filters
  on or off, history on, used by this character, pack; the detail pane lists the tracker's readings, each with
  "Add tile" (HC-50's searchable reading list is the same catalog). Actions: turn on or off, History..., Delete data.
  Trackers this character can't use show greyed. HC-35 (no on/off switch) stays proposed: the tree suits it, but
  it is not decided here.
- **Runs:** a list and a detail pane; HC-15's run details go in the pane, not a floating card.
- **Diagnostics (side tab; a bottom tab since 2026-11-24, §17.2):** the browser layout for probes. Tree by kind (functions, events, strings, samplers);
  status column and filter (ok, missing, changed, error, never fired); actions Run selected (`ns.RunProbe` exists,
  no UI yet), Run all, Copy, Clear history; Log, Live and Storage stay. Probe definitions are file-local today: a
  `ns.ProbeList` accessor first. Note #7 (probe taxonomy and status) is still the user's to decide.

### 17.5 Overlap: strata, levels, Blizzard's panels

| Strata (low to high) | What |
|---|---|
| LOW | Boards; a board's flyouts above that board (HC-43) |
| MEDIUM | The Hard Counters window and Blizzard's panels: the one clicked last is on top (`SetToplevel`) |
| HIGH | A board while its row is hovered in the Boards tab, then back to LOW |
| DIALOG | The copy box, confirm popups, the New board dialog |
| FULLSCREEN_DIALOG | Our right-click menus |
| TOOLTIP | Tooltips (Blizzard's) |

- **Not a managed UI panel.** Registering in `UIPanelWindows` would give AH-like slots, but Forever's panel manager
  refuses addons in combat ("We no longer allow addons to show or hide UI panels in combat",
  `Blizzard_UIParentPanelManager/Shared/UIParentPanelManager.lua`) and repositions the frame, ignoring the saved
  position. So the window stays free: last clicked on top; default position off the left slot where Blizzard's
  panels open; opens and closes in combat; Escape closes it (`UISpecialFrames`); no secure templates inside it.
- **Side tabs and clamping:** `SetClampRectInsets` extends the clamp to the tab column, so the tabs never leave the
  screen.
- **Popups never open under the window:** the run card shared MEDIUM without `SetToplevel` and opened under the
  window (HC-65, seen on the user's screenshot). Now every `Widgets.Window` popup is `SetToplevel` and the card
  raises each time it opens, until HC-15 removes it.
- Alt+Z, pet battles and cinematics hide everything under UIParent; positions are saved as top-left points.

### 17.6 The launcher (minimap button, AddOns menu, bar feed)

The launcher is a shortcut, never the only way: everything it does is in the window under the same words. Click
opens the window on its last tab; Shift-click shows or hides all boards; Ctrl-click edits every board (all
unchanged). The right-click menu's "New board ▸ presets" becomes one "New board…" that opens the dialog, and gains
"Open Boards tab". Options keeps its general settings; its per-board show and mini toggles move to the Boards tab.
The Trackers tab's "Edit boards" button moves to the Boards tab (also the playtest's note #4).

### 17.7 Before building, and the order

Probe in game first (HC-65): `LargeSideTabButtonTemplate` and an icon texture on `PanelTabButtonTemplate` create
without errors on Forever; `SetClampRectInsets` holds the side tabs on screen; the run card's stuck-under bug.
Then: the tab chrome (HC-69) with the browser widget and the Trackers tab (HC-66); the tile collection and Overview
(HC-67); the Boards tab, the New board dialog and the launcher (HC-68); the Diagnostics probes browser (HC-70).

**As built (HC-65, the probe; run in game 2026-11-23, client 1.60.1.71037):** `/hc diag ui` (Diagnostics, `Probes.lua`) opens a test panel the
size of today's window with the planned chrome: 12 `LargeSideTabButtonTemplate` tabs hanging off its right edge
(anchored as on the Camelot profession window: `TOPLEFT` to the frame's `TOPRIGHT`, y -60, then 2 apart), and four
`PanelTabButtonTemplate` tabs along the bottom, one per label option (icon and title, icon only, title only). Read
from the Forever source before building: the side tab is a **Frame**, not a Button (clicks come through
`SetCustomOnMouseUpHandler`; `SetChecked` shows the selected art; `tooltipText` feeds its own tooltip); its size
comes from the `common-sidetab` atlas. The bottom tab's label is centred, so the icon is anchored to the label's left
and the label is shifted right by half the icon through `selectedTextX` / `deselectedTextX`, which Blizzard's select
and deselect read; the icon-only tab centres the icon and moves it with the select offsets. The panel measures
itself into `HardCountersDiagDB.probes.hc65`: (a) what the side tab is made of and its size; (b) per bottom tab the
gap between icon and label, icon and label inside the tab, truncation, after creation, a hide and show (the
template's own `OnShow` resize, then ours) and each click; (c) the panel set flush right by `SetPoint` without and
with `SetClampRectInsets(0, <column width>, 0, 0)`, then every drag; (d) the run card's frame level against the
window's whole tree whenever their order changes, the card shows, or either is clicked.

Results (the saved file and the user's screenshot; UI scale 0.8, screen 1707 × 960 in UI units):
- **(a) Yes.** The side tab builds as a Frame with every part (background `common-sidetab`, icon, mask, selected,
  glow, highlight) and the mixin's methods; mouse is on at creation. 55 × 55 (atlas 55 × 60); with
  `SetFillToInterior(true)` the icon is 50 × 50. All 12 drew with their icons; clicks reached the handler (7), and
  `SetChecked` shows the selected art (subtle: a lighter frame). 8 sit beside the 566-high panel.
- **(b) Yes.** In all three label options the icon sits 3 from the label, inside the tab, nothing truncated, at
  creation, after a hide and show (Blizzard's resize, then ours) and after clicks. Widths: Overview with icon 99,
  Runs with icon 72.3, Trackers 73.3, icon only 72 (the side art's minimum).
- **(c) Yes.** Flush right by `SetPoint` with no insets, the column hung 55 off screen; with
  `SetClampRectInsets(0, 55, 0, 0)` the same `SetPoint` was clamped so the column ended exactly at the screen's
  edge, and so did a drag pressed against it. Insets clamp both `SetPoint` and drags.
- **(d) Stuck, as predicted.** The card opened under both the Hard Counters window and the probe panel (screenshot:
  only its edge and "Select all" showed between them). On Forever frame levels don't show the raise order: the
  window and the card both read level 1 after clicks (the window's tree reaches 515), so the probe's "card between"
  was not the answer; the screenshot was. Fixed: `SetToplevel` on `Widgets.Window` popups and a `Raise` each time
  the card opens; confirm by eye (checklist situation 12).
- What the panel's tabs don't show: they switch nothing (the probe has no pages behind them), so a click only
  changes the selected art.

- The probe panel and `/hc diag ui` were removed with HC-69, which builds on what it measured (git history:
  `ad24634`).

### 17.8 As built (HC-69 with HC-66, 2026-11-23)

**The tab chrome** (`UI/Windows.lua`):
- **Which column.** A window registered by Hard Counters itself (`ns.Windows.Register`) is a bottom tab; one
  registered through `HC:RegisterWindow` (every pack, and Diagnostics) is a side tab. (Swapped 2026-11-24: §17.2
  "As built".) Bottom tabs sort by
  `def.tabOrder` (Overview 1, Boards 2, Trackers 3, Runs 4; Overview and Boards arrive with HC-67 and HC-68); side
  tabs keep load order with Diagnostics (`hcdiag:`) always last.
- **Bottom tabs** are `PanelTabButtonTemplate` with an icon texture, as the probe measured: the icon 16 square,
  3 left of the label, the label shifted right by half (`selectedTextX` / `deselectedTextX`), resized after
  Blizzard's own `OnShow` / `OnEvent` resize with room for the icon. The label option is
  `settings.tabLabels` ("both", "title", "icon"; Options ▸ Windows ▸ Tab labels); icon only centres the icon, which
  follows the select offsets, and shows the title as a tooltip. A window without an icon always shows its title; the
  plain fallback (no template) shows titles only. Icons: Trackers `INV_Misc_Gear_01`, Runs `INV_Misc_PocketWatch_01`.
- **Side tabs** are `LargeSideTabButtonTemplate` (`SetFillToInterior`, `tooltipText` = the title, clicks through
  `SetCustomOnMouseUpHandler`, `SetChecked` on the selected one), 55 square from 60 down, 2 apart; with no template,
  40-square icon buttons. 10 fit beside the 640-high window; with more, two arrow buttons under the column and the
  mouse wheel over it scroll it, and opening a tab scrolls it into view. A pack window without an icon shows Hard
  Counters' icon. Icons: Ledger `INV_Misc_Coin_01`, Character Stats `INV_Misc_Book_09`, Diagnostics
  `Trade_Engineering`.
- **Clamp:** `SetClampRectInsets(0, 55, 0, -30)` (with side tabs; 42 for the fallback), so neither the column nor
  the bottom tabs leave the screen.
- **Size and scrolling:** the design size 780 × 640 (body 762 × 568; Character Stats needs 566: 27 stat rows and 5 headings), wider for a tab
  whose minimum width is larger. Content sits on a canvas inside a `ScrollFrame`; a tab whose minimum height is
  taller than the body gets a canvas that tall, a slim scroll bar (`Widgets.VScroll`, a plain `Slider`) and the
  mouse wheel (40 per notch); another tab starts at its top. No tab today needs it.

**The browser** (`UI/Browser.lua`, `ns.Browser.New(content, spec)`): search box (with a "Search" hint) and a
Filters button over a 150-wide tree; the list to its right with clickable column headers (" ^" / " v" marks the
sort; a second click reverses), pooled 18-high rows, a slim scroll bar and the mouse wheel; a 160-high detail pane
under the list (title, wrapped lines, then items each with an optional button, mouse wheel for more); an action bar
at the bottom right with the footer text at its left. Right-click on a row offers the same actions as a menu. The
provider owns the data and the filters (spec fields in the file's header); the widget keeps the node, the
selection (by key, dropped when the row disappears), the sort and the search. The Filters menu is a `Menu.Show`
builder whose `keepOpen` items toggle in place.

**The Trackers tab** (`UI/Trackers.lua`, minimum 600 × 360): tree "All trackers", then each category in
registration order (Basics, Farming, Character, Travel), then "Not loaded" (grey) when data on disk has no owner;
counts beside each. Columns Name (with *New*), On, History ("Off", the preset, "needs daily", or "live only" for a
tracker without counters), Size. Filters: on, off, only with history on, only used by this character, and per pack
(shown when more than one). Trackers whose every reading says `applies = false` show grey. Detail: the description,
a state line (on or off · history · size on disk), then the readings with their scope chips, those this character
doesn't use last under their heading, each with **Add tile** (HC-36's rules: the only board, or a menu of them,
or a new one). Actions: **Turn on / Turn off** (the same confirmations), **History...** (the HC-48 menu: Keep
history, Advanced, Delete history), **Delete data** (all of it, with its confirm). For a "Not loaded" row:
**Delete**. "Edit boards" stays in the header until the Boards tab takes it (HC-68). The History column no longer
toggles history on a click: that moved into History... (one place for it).

### 17.9 As built (HC-67, 2026-11-23): the tile collection and the Overview tab

**The collection** (`UI/BoardModel.lua`, `settings.boards.v = 6`; v7 since HC-73, below):
- Every **reading** tile lives in `boards.tiles[id]` (ids `t1`, `t2`, ...; `nextTile`), in `tileOrder` (with a
  `section` until HC-73). A board's `tiles` list holds **placements**,
  `{ ref = <tile id>, size = <size> }`: its order and the size are the board's, everything else is the tile's.
  **Labels and splits rows stay on their board** as before: they are layout, not numbers, and have no meaning in
  the Overview tab.
- **No board code changed shape.** At run time a placement reads every field but `size` from its tile and writes
  them there (a metatable, attached by `M.Store()` and never saved; a `/reload` drops it and the next `Store()`
  puts it back), so `tile.scope`, `follow`, the menus and the drawing read and write as before, and an edit on the
  board is the tile's edit. `M.TileOf(p)` gives the collection tile, `M.IsPlacement(t)` tells them apart.
- **One board at most.** A tile is on one board ("On HUD: <board>") or none ("Window only"); `M.Place` moves it
  when it is already on another. That keeps the board-relative parts unambiguous: "the board's timer", `follow`,
  the account window.
- **Leaving a board** (Remove from board, Take off HUD, a deleted board) keeps the tile in the collection, its size
  kept for its next board (`lastSize`), but **off the board's timer** (no board, no timer): it reads the session
  instead (or the reading's first other scope) and follows nothing. `M.ScopeChoices` offers no timer for it.
  `/hc board reset` deletes the boards' tiles with them (`M.Delete(id, true)`): it means "start again".
- **Migration v6** is `normalize()` in `M.Store()`: every board's reading tiles move into the collection, each in a
  section named after its board, in board order; saved placements get their metatable back; placements of a deleted
  tile go. It also adopts a reading tile added the old way (a raw table) at the next `Store()`. Settings only, no
  storage change. Tested on boards as 0.2.0-beta1 saved them (layout, labels and values the same, also after a
  simulated `/reload`), and run once, outside the repo, on a copy of the user's settings file: 5 boards, 23 tiles,
  identical layout and labels.
- Fixed on the way: two boards made from one preset shared the preset's `extras` (and a set `arg`) table.
- Calls for the Overview tab: `M.CollectionTiles()` (`{ id, tile = its placement or itself, board, raw }`),
  `M.Tile`, `M.NewTile(reading, arg)`, `M.Place`, `M.DeleteTile`, `M.TilesByBoard()` (HC-73, below).

**The Overview tab** (`UI/Overview.lua`, tab order 1, icon `INV_Misc_Note_01`, `/hc overview`): a search box, a
hint and **Add tile** on top; cards about 176 wide (four across), 58 high: the tile's label as on its board, its
number now (grey while not settled; toward its target for a bar or gauge). Click or right-click a card: **Edit**
(`Boards.TileSettingsItems`, the board's own menu; no Size off a board), **Show on HUD** / **Move to board** (the
boards, then New board), **Take off HUD**, **Delete tile** (confirmed). Cards refresh once a second while the tab
is shown; the tab is as tall as its cards, so the window scrolls it (`minSize`). **Add tile** opens the Trackers tab
in a mode (`ns.TrackersForOverview`, until that tab closes) where its Add tile makes a Window-only tile; the
Trackers tab's board menu also has "Overview only (no board)". On a board, the tile menu's Remove is now **Remove
from board** (the tile stays in Overview), and Delete this board says its tiles stay in the Overview tab. (HC-67
grouped the cards in free sections, a name on each tile; HC-73 replaced them, below.)

**HC-73 (2026-11-23): grouped by board.** HC-67's sections were named after the board a tile was born on and never
updated: Move to board, a board's rename or delete and Duplicate left them stale, and a fresh install never saw the
tab's only explanation (it needed zero tiles; the Pocket board seeds three). Agreed from a mockup:
- `M.TilesByBoard()` returns every board in list order (the Boards tab's), each with its reading tiles in the
  board's order (an empty board too), and the tiles on no board in collection order.
- A board is a **framed panel** (dark fill, solid grey border) headed by the Boards tab's icon, its name, its status
  coloured as in the Boards tab (`ns.BoardStatusText`) and its tile count; empty, it says "No numbers on this
  board." Click its header: the board's row menu from the Boards tab (`ns.BoardMenu`), titled with its name.
- **Window only** comes last, unframed, with the Overview's icon and "tracked here, not on screen"; its cards are
  faint with a **dashed** border (`Media/Dash.tga`, 8×8, drawn by `tools/draw-dash.py`, tiled along each edge). It
  shows even when empty ("None yet. Add tile puts a number here..."), so a new player reads what the tab is for.
- A card's footer is its **scope** (board timer, session, today...); where it is, the group says (and the tooltip).
- Search matches a tile's label or its board's name (a matching board shows all its tiles).
- **Migration v7:** `tile.section` and `boards.sections` go; nothing else changes. The Section menu, Rename section,
  `M.Sections`, `M.SetSection`, `M.RenameSection` and `M.DEFAULT_SECTION` are gone.

### 17.10 As built (HC-68, 2026-11-23): the Boards tab, the New board dialog, the launcher lined up

**Names** (`UI/BoardModel.lua`): `M.CheckName` (required, at most `M.NAME_MAX` = 24, unique ignoring case and
surrounding spaces), `M.FreeName` ("<name> 2", ...: keeps the case typed, cut to fit), `M.Rename`. `M.Create`
makes every name free, so a second board from a preset is "Pocket 2". Boards saved before with the same name keep
it until renamed (nothing renamed silently). The board's own menu (Rename) and the Boards tab go through
`Boards.Rename`, which says why it refused.

**Duplicate and your presets** (HC-22's player presets): `M.Duplicate(board, name)` copies the look, rules and
scope with **tiles of its own** (new collection tiles, a fresh timer, at the centre). `M.SaveAsPreset(board, name)`
keeps every tile's settings with its placement's size (no ids) plus mini, scope and rules in
`boards.presets` (keys `user:<n>`); `M.Preset(key)` finds any preset, `M.Create` makes boards from yours too,
`M.RenamePreset`, `M.DeletePreset` (boards made from it stay). `M.PresetGroups()`: Hard Counters', each pack's
under its title, then "Your presets". `M.Create` takes a preset's `show` (rules) and scope when it has them.

**Why a board is hidden**: `M.Visibility` returns a third value, "off", "runOnly", "instance" or "combat";
`state.peek` shows any board at full alpha. `Boards.Status(board)`: Shown, Shown (faded), Off, Hidden: only during
runs / in instances / in combat, Tiny? (scale under 0.5), Off screen? (shown but its rect outside the screen: rare,
boards are clamped). **Show now** (`Boards.ShowNow`, 20 s) and a **hovered row** (`Boards.Highlight`: the board
shows, strata HIGH, a gold overlay, back to LOW when the pointer leaves or the tab hides) peek. **Reset position**
puts the board at the centre, scale 1, with one flash (`Boards.Flash`).

**The New board dialog** (`UI/BoardDialog.lua`, `ns.BoardDialog.Open{ preset | copy | empty }`): a
`ButtonFrameTemplate` panel in DIALOG strata, 380 × 250, movable, Escape cancels (`UISpecialFrames`), Enter in the
name creates. Name (max 24 letters; under it "/hc board <name> will show or hide it", or why not in red, with a
free name suggested; Create greys out), Start from (a button opening the groups: presets, then Empty board and
Copy of a board ▸ boards; picking one renames the board after it until the player typed a name), Show it (in
combat, in instances, only while a run is open: the board's `show` flags; a fade in combat from a preset is kept).
Create puts it at the centre, flashes it, prints its command; an empty board opens in edit mode. Opened by the
Boards tab (New board..., Duplicate, a preset's New board from it...), a board's [+] menu (New board...), the
launcher (New board...), Options ▸ Boards (New board...) and `/hc board new` without a name. `/hc board new <name>`
makes an empty board of that name directly (in edit mode; a taken or too long name is refused), and
`/hc board new <preset key>` still makes that preset.

**The Boards tab** (`UI/BoardsTab.lua`, tab order 2, icon `INV_Misc_Map_01`, `/hc boards`), on the browser (which
gained `hover(row, on)`, `rowMenu(row, anchor)` and `headerBtns`): tree "Your boards" (count), "Presets", then each
group. Columns Name, Status (coloured: green shown, grey off, yellow hidden by a rule, red off screen, orange
tiny), Tiles, Mini. Header: New board..., Show all, Hide all, Edit all (every board in edit mode without switching
to Trackers; "Stop editing" while on). A board's actions: Show/Hide, Show now, Edit on screen / Stop editing,
Reset position, Duplicate (the dialog, a copy), Save as preset (asks a name), Delete (its tiles stay in Overview).
Right-click adds Mini mode and Rename. Detail: its command, its rules in words, Mini (Full / Mini button), Name
(Rename...), its tiles by label. A preset: its tiles (grey: a pack not installed), New board from it...; yours
also Rename..., Delete. The tab refreshes once a second while shown (statuses follow combat and instances).

**Lined up (§17.6):** the launcher's right-click reads New board..., Open Boards tab, Edit every board / Stop
editing boards, Options. Options ▸ Boards keeps Edit every board and gains New board... and Open Boards tab; its
per-board Show and mini switches are gone (the Boards tab has them). The Trackers tab's "Edit boards" is gone (the
Boards tab's Edit all; the playtest's note #4).

**Presets by category (HC-57 a and c, 2026-11-24; not seen in game).** `RegisterBoardPreset` takes `category`
(`"activity"`, `"role"` or `"class"`, a list Hard Counters owns: `M.CATEGORY_ORDER`), `class` (the class file name,
`"MAGE"`; required with `"class"`, refused without it) and `tip` (a line shown on hover). `M.PresetGroups()` now
returns **Activity**, **Roles**, **Your class** (the class board of this character's class, `ns.wow.playerClass`),
**Other classes** (`more = true`: one submenu), then presets with no category under their pack's title, then **Your
presets**; empty groups are left out. The New board dialog's Start from shows them in that order with the tips;
the New board menu (`Boards.NewBoardItems`) has a submenu per group. Run, Pocket, Leveling
(Hard Counters Basic) and Traveler's Trip and Flight log are Activity; Character Stats brings seven role boards and
nine class boards (its DESIGN §6).

### 17.11 As built (HC-70, 2026-11-23): the probes browser in Diagnostics

The playtest's note #7 (probes: status, data, taxonomy, UX) was decided by the user on 2026-11-23 as proposed:
- **Taxonomy:** the tree by kind: Functions (API checks run on demand), Events (fires counted by instance type),
  Global strings (client strings the chat parsers use), Samplers (travel, TR-6, loading screens, item link fields,
  Edit Mode). The **feature** a probe serves is a column and a filter: the queue id at the start of its name
  ("TR-6 dungeons" serves TR-6, "CS-1 UnitStat(player,1)" CS-1), else "Core"; the samplers name theirs.
- **Statuses:** ok; missing (no such API or event); error (it failed); **changed** (a function's last two runs
  differ in status or detail; a string that differs from the last read, with the old value kept in
  `probes.stringsWas`); **secret** (a protected value came back: status "secret" or "secret" in an ok detail; an
  event with secret arguments); **never fired** (an event or a sampler with nothing yet); not run yet.
- **Data:** what was kept already (a function's last 5 runs with time, status, detail and context; an event's
  fires, argument types, secret arguments, chat patterns matched; a string's value; a sampler's tables), shown in
  the detail pane, newest first.

Built: `ns.ProbeList()` in `Probes.lua` (records `{ key, kind, name, feature, status, last, runnable }`),
`ns.ProbeLines(rec)`, `ns.ProbeText(rec)`, `ns.RunProbeRecord(rec)` (a function probe, or a string read again),
`ns.ClearProbe(rec)` / `ns.ClearProbes()` (a sampler's table is emptied **in place**, keeping its version and this
load's registration state: the sampler keeps counting into it). The Diagnostics tab's **Probes** view is now the
shared browser (through the private bridge: `HardCounters._diag.NewBrowser`, `.Confirm`): tree All probes /
Functions / Events / Global strings / Samplers with counts; columns Name, Feature, Status (coloured), Last run;
Filters by status and feature; actions Run (functions and strings), Copy (the probe as text, in the copy box),
Clear history (confirmed); at the top Run all, Copy all (the old text page, for pasting to Claude), Clear all
(confirmed). Log, Live and Storage stay text; the bottom row's Copy copies the probes' text on the Probes view.
Without the browser (an older Hard Counters) the Probes view stays text.

### 17.12 As built (HC-74, 2026-11-24): each character's own boards, copying, a new character's start

The user (2026-11-24): "each character must have their own boards ... new characters [could] copy (and adjust)
another character's board. When a new character joins they could have only one board (the levelling one) spawned in
front of them with a one-off introduction message about the central panel and its capabilities."
- **Where boards live.** `boards` moved from the AceDB profile (every character shares the "Default" profile) to
  AceDB's per-character table, `ns.charSettings` (`HardCountersSettings.char["Name - Realm"]`). `ns.allCharSettings`
  is every character's (AceDB's `sv.char`), `ns.globalSettings` the account's, `ns.charKey` this character's key.
  The other options (and trackers) stay in the profile. **Your presets** stay the account's: `settings.boardPresets`
  (moved once from 0.2's `boards.presets`). Board windows were already per character (`b<wid>@<guid>`).
- **Migration.** 0.2's shared boards stay in the profile, untouched, as a source. At a character's first load on this
  build `M.Store()` gives it a deep copy of them when it is a **returning character** (`ns.knownCharacter`: it is in
  `HardCountersDB.chars` before this login adds it, which every release has written), `fromShared = true`: same
  boards, same tiles, same timer numbers, so the board timers carry on per character as before. A character Hard
  Counters never saw gets an empty store. Deleting a board drops only this character's window while another
  store still has a board with that timer number (`M.WidElsewhere`; `SavedWindows.Drop(key, onlyMine)`), else every
  character's as before.
- **Copying.** `M.OtherBoards()`: `{ key, name, store, boards }` per other character with boards (sorted by key; the
  name before " - " of the AceDB key), then 0.2's shared boards as "Shared boards (0.2)". `M.Duplicate(board, name,
  from)` copies from another store: tiles resolved through that store's collection (placements there are plain
  `{ ref, size }`), shapes of older stores brought up to date (`style`, the "login" scope, `section`, `wid` dropped),
  aliases folded; a fresh timer. The New board dialog's **Copy of a board** lists this character's boards, then a
  submenu per other character (and the shared boards); its Start from reads "Copy of Farm (Alt)". The Boards tab has
  **Other characters** (a node per character): rows Name, the character, Tiles, Mini; the detail lists the tiles;
  one action, **Copy to this character...**, opens the dialog on it.
- **A new character's start.** `M.Seed()` for a character that is not returning (and never used the old run panel):
  the **Leveling** preset (`M.STARTER`; all its readings are on the two trackers on by default) at `M.STARTER_POS`
  (centre, 280 right, 40 up: beside the character, in sight), and `boards.welcome = true`. `UI/Welcome.lua`, two
  seconds after the login's `PLAYER_ENTERING_WORLD` (past the loading screen): the account's first such character
  gets the **welcome window** (`ns.globalSettings.introSeen`), a 400 × 300 dialog left of the board: the board is
  this character's own; the Hard Counters window (minimap button or `/hc`) holds Overview, Boards, Trackers, Runs,
  one line each; each character has its own boards, and how to copy one. Buttons **Open the window** (the Overview
  tab) and **Got it**; Escape closes it. Later new characters get one chat line. `/hc welcome` shows it again.
  **Replaced by the tutorial (§17.13)**; the starter board, `boards.welcome` and the chat line stay.
- **Not done:** a character renamed or moved to another realm gets a new AceDB key, so it starts as new (its old
  boards are listed under its old name, to copy). AceDB's Profiles page no longer affects boards.

### 17.13 As built (2026-11-24): the tutorial and the Guide tab

The user (2026-11-24): "create a tutorial for this addon when the user logs in and they haven't yet run the
tutorial. It has to explain to them what they can find in the addon's components like the central window, each tab,
and in the HUD boards. It could guide them to create their first board based on their class. In addition make sure
we have a guide core tab in the panel, where people can find out about our concepts and what they can do with the
addon including the slash commands API." Then: "we could also add a central action button that re-runs the
tutorial." Not seen in game.
- **The tutorial** (`UI/Welcome.lua`, `ns.Tutorial`; it replaces §17.12's welcome window). A 440 × 430 dialog
  (`HardCountersTutorial`, DIALOG strata, Escape closes it) with a heading, the step's text, "Step n of 10", **Back**
  and **Next** (**Finish** on the last), and on some steps one action button. It does things as it goes, so the
  player sees what it talks about:
  1. *Welcome*: reading, tile, board, the Hard Counters window, in one line each.
  2. *Boards*: the window is moved out of the way and the first shown board flashes (`Boards.Highlight`: HIGH strata,
     shown whatever its rules) while the step explains the Edit tab, `[+]`, a tile's right-click, the clock, the
     name bar's menu.
  3. *Your first board*: `Tutorial.ClassPreset()` finds the preset with `category = "class"` and this character's
     class (Character Stats registers one per class). **Make my <Class> board** creates it (`M.Create`) left of the
     tour (centre, 500 left, 40 up) and flashes it; with one already there the button is **Show it**; without the
     pack it says so and offers **New board...**.
  4. to 8. *The window*, then *Overview*, *Boards*, *Trackers*, *Runs*: the tour opens the window on that tab
     (`Windows.Show`) and sits beside it (anchored to the window's top-left corner, clamped to the screen; left
     alone once the player drags it).
  9. *The packs' tabs*: the bottom tabs by title (`Windows.PackWindows()`), a line for the ones we ship.
  10. *Guide*: opens the Guide tab; says where the tour and the commands are.
- **When it shows.** Two seconds after the login's `PLAYER_ENTERING_WORLD`, `Tutorial.Check()`: when
  `ns.globalSettings.tutorialSeen` is not set it opens (once per account; the flag is set when it opens, so closing
  it early counts as run); in combat it asks again every 10 s instead. That includes a character Hard Counters
  already knew: the tour is newer than they are. `introSeen` (§17.12) is still written, for an older build reading
  the same file. On an account that has seen it, a new character gets §17.12's chat line.
- **Again:** the **Tutorial** button in the Hard Counters window's header row, on every tab (`main.tutorial`, the
  first of the header buttons; a pack's `mainButton` lines up left of it); the Guide tab's **Run the tutorial**;
  `/hc tutorial` (`/hc welcome` still works, unlisted). All start at step 1.
- **The Guide tab** (`UI/Guide.lua`, window id `guide`, `tabOrder = 5`, the question-mark icon): the fifth of Hard
  Counters' own tabs. Ten pages down the left, the page's text on the right in a scroll frame of its own with
  `Widgets.VScroll`: Start here, Concepts, Boards, Tiles, The window, Trackers and history, Runs, Packs, Commands,
  For addon authors. Text is built when a page is shown, so the lists are live: **Commands** from `ns.SlashList()`
  (every `/hc` subcommand with a help line, a pack's with its owner, then worked examples), **Packs** from
  `ns.packOrder`, **The window** from the bottom tabs. **For addon authors** summarises the public API in the
  order a pack uses it and documents `HC:RegisterSlash` in full, pointing to `docs/API.md` and `docs/PACKS.md`.
  `/hc guide [page]` opens it, on a page by key or title.
- **Costs, accepted.** The guide's text lives in Lua strings (one more place to keep in step with README and
  API.md; `tests/tutorial_spec.lua` checks the command list against the registry, not the prose). A new file in the
  TOC: the first load needs a full client restart; on a `/reload` alone the tour works and its last step finds no
  Guide tab. The tour's window can cover the left of the Hard Counters window on a narrow screen (it is movable).
- **Not done:** per-step pointers (an arrow at the Edit tab or a tab's icon); a tour per pack; localisation.

### 17.14 As built (2026-11-25): boards off the HUD by default, tiles on or off it, moving, packs, help

The user's nine points (A to I), built in one round. What was decided on the way is marked **call**.

- **A board lives in the window first** (A). `M.Create` and `M.Duplicate` make boards with `shown = false` unless
  asked (`opts.shown`, the dialog's "Put it on my HUD"); `M.Seed` gives a new character its Leveling board the same
  way. `board.shown` now reads "on the HUD"; the words everywhere are **On HUD** and **Only here** (C). A board edited
  on its own (`state.editOwn`) shows while it is edited even when it is Only here; `/hc edit` leaves those alone.
  `Boards.Reveal` no longer puts a board on screen. **Call:** the tutorial's "Make my <class> board" does put that
  board on the HUD: the button says so and the click is the player's.
- **No tile without a board** (B). BoardModel **v8**: tiles on no board ("Window only": left there by Remove from
  board, by Take off HUD, or by a deleted board, with nothing saying how) move once to a board named "Unsorted",
  `shown = false`, scope session (`B.unsorted`: its Overview panel explains it). `M.NewTile` and `offBoard` are gone;
  `M.RemoveTile` and `M.Delete` delete reading tiles. A placement has `off = true` when the tile is kept off the HUD
  (`M.TileOnHud`, `M.SetTileOnHud`): `M.Layout` and `M.HeroIndex` skip it, `M.LayoutKey` changes with it, presets and
  copies carry it. The board's timer still counts such a tile. **Call:** deleting a board deletes its tiles; the
  confirmation says so.
- **Overview makes things** (A). Per board: the HUD switch, "+ Tile" (`Boards.AddReadingMenu`: the [+] menu's
  reading picker), the tile count; top right "New board...". A card's menu: Edit, On HUD, Move to board, Delete tile.
- **The New board dialog**: "Start from" is `Widgets.Dropdown` (a field with an arrow); "Put it on my HUD" is off by
  default and greys the visibility rules under it.
- **Moving a locked board** (D). `Boards.Hover` (ten times a second) shows two tabs above a hovered full board: Move
  above the left corner (a drag handle), Edit above the right one, never side by side. While the move key
  (`settings.boardMoveKey`: SHIFT, CTRL, ALT or NONE; `ns.wow.modifierDown`) is held with the cursor on a board, the
  board is armed: it takes the mouse and drags (a mini board by its strip), in combat too; released, it is
  click-through again. **Call:** Ctrl is the default (the user, 2026-11-25; Shift at first).
- **The Packs tab** (E, `UI/Packs.lua`, tab order 2.5). Rows from the AddOn list (`## Group: HardCounters`) plus the
  built-in Basic. "Use these packs": a ticked, loaded pack gets the trackers the player never switched (`chosen`)
  turned on, history untouched (off by default); a pack to load or unload goes through `ns.wow.setAddonEnabled` for
  this character and waits for a reload (`globalSettings.packsPending`, finished at the next login);
  `globalSettings.packsChosen`. The history paragraph is always on the tab. Not verified in game: the AddOn calls
  and `ReloadUI` from our click.
- **Help and Tab tour** (F, G, H; `UI/Help.lua`). One window, two uses. Each tab registers `{ what, can, effect,
  tour }` at the end of its own file; packs through `HC:RegisterWindowHelp`. Keeping them true: a `{name}` in the
  text is the exact label of a button, menu item or tab, and `tests/help_spec.lua` fails when no Lua source has that
  string any more, or when a registered window has no help. Ground rule as for the tutorial.
- **Character Stats** (I): its DESIGN §8 "As built (2026-11-25)". Hard Counters' part: `HC:ReadingsChanged()`.
- **Not done:** per-school spell hit (one number from the game; the rest is talents), per-school rows in the stats
  window (they are tiles), a mana tick bar after the five seconds, dragging tiles between boards in Overview.
- **The report's defaults (the user, 2026-11-25, after the first play).** `/hc report` opens with class and the addon
  list ticked and the name unticked (§8.3 had all three off): friends' reports are read for probe results, which need
  the class, and for conflicts, which need the addon list. Still boxes the player sees and can untick; the window's
  first lines, README "Good to know" and the CurseForge description state it. Changing a default again means changing
  those three texts in the same commit.

### 17.15 As built (0.4.0, 2026-11-26): Boards, Explorer, Stints, Overview, Options

The user's list of 2026-11-26 (tab names, two new tabs, action and status buttons, history that follows the tiles,
configurable history, a live launcher tooltip, field notes). Designed by a separate design pass, then built; the
calls that pass made and this build kept or changed are below. Not seen in game when written.

**Tabs.** Down the right edge, Hard Counters' own, by `def.tabOrder`: **Boards** (1, the Overview of 0.2 to 0.3,
`UI/BoardsTab.lua`), **Explorer** (2, `UI/Explorer.lua`), **Packs** (3), **Stints** (4, `UI/Stints.lua`, the Runs
tab), **Guide** (5). Along the bottom (`def.place = "bottom"`, `def.bottomOrder`): **Overview** (−100,
`UI/Overview.lua`, the new summary), the packs' windows (0, load order), **Options** (900, `UI/OptionsTab.lua`),
Diagnostics (1000). `Win.PackWindows()` still lists the packs' windows only; `Win.BottomTabs()` lists all of them. A
saved open tab under an old id moves once (`windows._main.tabsV = 2`: overview → boards, boards and trackers →
explorer, runs → stints). Window ids `trackers` and `runs` are gone; `/hc trackers` and `/hc runs` still answer.

**Words.** A run is a **stint** for players (the word "session" is a tile scope and "period" a calendar bucket).
Only player-facing words and the UI changed: the `run` scope, `HardCountersDB.runs`, `HC_RUN_*` and the `*Run` API
stay, with `*Stint` aliases. The Tutorial button is **Grand tour**; Help and Tab tour read "<tab> help" and "<tab>
tour".

**Header.** Under the title, left of the three buttons, the open tab's `def.about` (one line; packs give theirs to
`RegisterWindow`).

**Buttons.** `Widgets.Button` is an action (Blizzard's red button). `Widgets.Status` is a state: a dark flat pill
with a lamp (green on, grey off, amber needs a look) and a border in the lamp's colour; clicking it switches the
state. `Widgets.RichTip` is the tooltip house style: title, state in colour, what it does, a grey "Click: ..." line.
The browser's actions take `status = true` (a pill) and `more = true` (under More...). Not built from the design:
a test that walks every created button for a tooltip (the fake client can't tell a button that has one).

**Explorer.** One browser over providers: `UI/BoardCatalog.lua` (boards, ready-made boards, other characters),
`UI/Trackers.lua` (trackers, Not loaded; it no longer registers a window) and the Explorer's own Tiles, Readings
(by the tracker's category) and Displays (the visual toolkit: what each display draws, sizes, calcs, target, the
tiles using it, "Add a tile as a bar..." with a reading picker that lists only what that display can draw). Tree
captions (`node.head`) group them: My setup, Add, What is counted, Other characters. Columns change with the node
(`spec.columns` as a function). The list and the detail pane share their height through a splitter (drag;
double-click resets; saved as `windows.explorer.detailH`). Removed: All on HUD, All off HUD, Edit all.

**Hover.** A board on the HUD hovered in the Explorer shows, raised and flashing, as before. One that is Only here is
drawn at 30% alpha where it would be, with no flash and not raised (`Boards.Highlight(id, on, full)`; the tutorial
passes `full`). The design proposed a dashed outline frame instead; a faint board was simpler and says the same.

**Boards tab.** A board's panel: name, status and clock in the heading; at the right its tile count, + Tile, Pause or
Start and Reset (only on its own timer, as on the HUD), and the On HUD switch as a status pill. Cards name a non-number
display in a chip and draw a bar or gauge as a strip toward its target, a mix as one strip in parts. Under the last
panel a dashed panel says more boards can be made (New board..., Ready-made boards); with none it is the whole page.
A yellow strip at the top reminds a player with no pack chosen or none loaded. Panel borders use
`Widgets.Hairline` (PixelUtil, one physical pixel at least): at a UI scale under 1 a 1-unit line rounded to 0 or 1
pixel depending on the scroll offset.

**Trackers follow tiles.** `ns.ActivateTracker(id, force)`: a tile added or a board made (the player's act, force)
switches the tile's tracker on, overriding an earlier off; after each load (not forced) the trackers of every tile
on every board go on unless the player switched them off. Either way a tracker whose history the player never chose
gets Daily history (`settings.historyDays`, 90). The Packs tab's Use these packs is gone; a tick sets
`globalSettings.packsChosen`.

**History options** (Options ▸ History): `maxRuns` 100 to 2000 (500; a record is about 2.6 KB, measured on the test
account's saved file: 45 records, 119 KB), `historyDays` (14, 30, 90, 365; 90), `hourKeep` (24, 48, 168, 336 hours;
48), `weekKeep` (1y, 2y, 5y; 2y), and `globalSettings.dayStartHour` (0 to 23, LibGranaryDB's Attach option, read at
load: days already kept keep their boundary). The retention shape string includes the week retention so a change
re-registers. Not built from the design: a storage budget option and days 180/730.

**Overview.** One page, a second's refresh: version and channel, character, profile; Needs a look (no pack chosen, a
pack waiting for a reload, tiles whose tracker is off, a board lost off screen or tiny, storage read-only, a test
version without Diagnostics); Packs, Trackers, Boards (each board's lamp is its On HUD switch), Stint, This session,
History and storage, Diagnostics; each line one button to where it is changed. The launcher tooltip reuses its
warnings.

**Options tab.** The AceConfig table, now three tabs (General, History, Profiles), drawn by AceConfigDialog into an
AceGUI SimpleGroup over the tab's frame, made on show and released on hide; redrawn on ConfigTableChange.
`/hc options` opens the tab. The game's AddOns options show the same table.

**Launcher tooltip.** Live while shown (rebuilt once a second and on MODIFIER_STATE_CHANGED): version, this session,
the stint and its headline, up to three boards on the HUD with two tiles each, today's net, what needs a look; Shift
for every board and tile, the warnings spelled out, the trackers.

**Field notes** (`Core/FieldNotes.lua`, DESIGN §8): on a pre-release version (`-dev`, `-alpha`, `-beta`) or with
Diagnostics loaded, a ring of 40 notes in `HardCountersDB.field` at login, reload, instance enter and leave, level,
caught error (five a session) and logout: counts and types only. `/hc report` carries them (`body.field`, shed after
the warnings). Diagnostics listens through the bridge (`D.OnFieldNote`) and runs its probes at a level, on leaving an
instance and after an error (once every five minutes at most), and snapshots the log at the first error of a
session. A player without Diagnostics loaded gets the notes only: an addon that is off can't run.

### 17.16 Agreed for 0.5.0 (2026-11-28): the window grown, boards' look, the Explorer by kind, class boards, runs

The user's list of 2026-11-28 (items A1 to H2 below keep its numbers), the open calls made by a design pass, one
call by the user (G3's key). Written before building; "As built" notes follow where the build differs.

- **A1.** The main window and its fonts grow by about 10%; saved sizes from 0.4 are clamped to the new minimum.
- **A2. One Help button** (not "Learn": in WoW that is the trainer's button) replaces `<tab> help`, `<tab> tour`
  and `Grand tour`. Its menu: `Help for "<tab>"`, `Tutorial for "<tab>"`, `Full tutorial`, `Open the Guide`. No
  "tour" in player text; the code keeps `Help.Tour`, `def.tour` and `/hc tour` as an alias.
- **A3.** Ctrl+K in the open window focuses the tab's search box; an option, and a hint by the box. Dropped (with a
  QUEUE row) if it can't be done without eating other keys.
- **B1.** The board's header row: 30 px from the top edge to the first tile becomes 22 (`M.PAD_HEAD = 2`, the run
  row 20, buttons 16), with a faint dark title strip behind it.
- **B2. Five tile sizes:** `large` (Big), `largeHalf` (Big, half width, new), `half` (Medium, half width),
  `line` (Line), `lineHalf` (Line, half width, new). The two new ones draw numbers only. Consecutive half-width
  tiles pair, whatever their size; the row is as tall as its taller cell. Big's height follows its extras (46, +15
  sparkline, +14 comparison). A Big value too wide steps down a font size. The trend badge fits every number size:
  arrow and words on Big, arrow only on the others, never under the number. The hero (mini strip) is the first
  `large` or `largeHalf`. One colour family: gold for structure, grey labels, white values.
- **B3, B4.** `board.alpha` (0.2 to 1), `board.bg` ({r, g, b}) and `board.bgAlpha` (0 to 1); nil means 0.4's
  look. A fading board (combat, faded until hovered) shows at half its own opacity, once. One `Look` submenu on the
  board: Opacity, Background, Background opacity, Number colour, Scale, Reset look.
- **B5.** A value colour per tile (`tile.color`), with a board default (`board.valueColor`), from nine presets;
  states (dim, trend, a reached target) still win. Labels are not coloured per tile. No font-size property: a
  tile's size and the board's Scale are the font size.
- **B6.** The tile menu gains Move to top and Move to bottom.
- **C1.** Pause, Resume and Reset on a HUD board are 16 px icons (the Stopwatch's), words if
  `settings.boardButtonIcons` is off. Tooltips name the action.
- **C2. A Hide tab on hover**, beside Edit: Hide is Take off the HUD (the same switch as the window's, kept), and
  a chat line says how to bring it back. No temporary hidden state.
- **C3.** No "here" in menus opened on the HUD: "(not on your HUD)", "Take this tile off the HUD".
- **D1, D2.** The Explorer's tree folds like the Auction House's category list (+/-, saved per profile). Heads by
  kind: Boards (Ready-made under it), Tiles (per board; Displays), Readings (per category), Trackers (per
  category; Not loaded), then a head per other character.
- **D3.** The Explorer loses its New board button (a right-click on Boards still offers it).
- **E1, E2.** Character Stats' role, class and schools ready-made boards go (boards made from them stay); 18
  class boards by role take their place ("Warrior (Tank)", "Druid (Caster)", ...), grouped Your class / Other
  classes. The tutorial's class step offers the character's roles.
- **E3.** The Packs tab: whole notes in a tip, why a pack can't load, a warning before unticking a pack whose
  readings are on boards, "trackers counting", "for this character", versions, a row menu, Diagnostics under Tools.
- **F1. Report a problem** is a bottom tab, always there: a note box, the three ticks, what is in it, the text to
  copy; the checks and the log marker when Diagnostics is loaded. The report window goes.
- **F2.** The copy-text window folds into the browser's detail pane. Help, the tutorial, the New board dialog and
  confirmations stay windows of their own.
- **G1.** Every details pane leads with the question it answers (board: why is it (not) on screen; tile: why does
  it say that; reading: what is it before I add it; run: how did it go against my others; probe: in words).
- **G2.** "How this number is made" (`BoardModel.Explain`): what is counted, from which counters, whose, the
  period, the sum, filters, target, against usual, the tracker, and every estimate said plainly. In the window a
  small panel (`UI/Synopsis.lua`), closed by its button or a click outside.
- **G3.** On the HUD the same as a tooltip, on **Alt+click** on a tile (the user, 2026-11-28; Ctrl is the move
  key), closed by any other click. Configurable in Options (`settings.boardInfoKey`).
- **H1. Stints are runs again**, not snapshots: a snapshot is a moment, a run is a span with a start, pauses and
  splits, and Diagnostics already uses "snapshot" for a moment. "Save as run"; the tab is Runs. Window id, saved
  keys and the `*Stint` API aliases stay.
- **H2.** The Runs tab finds runs with dropdowns over the list (Who, Where, When, Length, From, Counted), not a
  tree. New runs record where they came from (`src`, `board`, `boardId`, `atReset`); older ones read Unknown.
- **D0. Right-click** opens the same actions wherever there are actions (`Widgets.RightMenu`).
