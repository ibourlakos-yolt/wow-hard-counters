# Hard Counters public API (experimental)

> **Status: experimental** (`HardCounters.API_VERSION = 1`, `HardCounters.EXPERIMENTAL = true`) until 2-3 packs have
> shipped against it (DESIGN §10). Anything may still change; probe features with `HardCounters:Supports(name)`.
> The global is `HardCounters`. Methods use `:`; callbacks use CallbackHandler's `.` form.
> **Never** reach into saved tables or `HardCounters._diag` (private, for HardCounters_Diagnostics only).

## 1. A pack in 30 lines

```lua
-- MyPack.toc:  ## Dependencies: HardCounters   ## Interface: 16001
local HC = HardCounters
local pack = HC:RegisterPack("MyPack", { namespace = "mypack", version = "0.1.0", title = "My pack" })

HC:RegisterCounter({
  id = "mypack:fish", version = 1, kind = "flow", unit = "fish",
  measures = { "sum", "count" },
  dimensions = { { name = "zone", cap = 64 } }, aggregations = { {}, { "zone" } },
  title = "Fish caught", category = "Fun", accuracy = "exact",
  capture = { mode = "push-delta" }, feasibility = { status = "unverified", ref = "api-surface.md#economy" },
  runBreakdowns = { "zone" },
})

local LOOT = HC:ChatPattern(LOOT_ITEM_SELF)          -- built from the client's own string, never English
HC:RegisterSource("mypack:loot", { mode = "event", events = { "CHAT_MSG_LOOT" }, handler = function(_, msg)
  if not HC:Readable(msg) then return end           -- never touch a secret value
  if msg:match(LOOT) then HC:Emit("mypack:fish", 1, HC:ZoneKey()) end
end })

local today = HC:Query({ counter = "mypack:fish", grain = "day" }).total
```

## 2. Registration

| Call | Notes |
|---|---|
| `HC:RegisterPack(name, { namespace, version, title })` → pack | Required before counters/sources. `hc` is reserved. The pack object has `:Log(level, fmt, ...)` (tagged `[Pack:<name>]`) and `:Count(name[, n])` (health counters in `/hc report`). |
| `HC:RegisterCounter(def)` → id | LibGranaryDB fields (`id, version, kind, unit, measures, dimensions, aggregations, grains, retention, context, contextGrains, scope, maxGap, budget, onIncompatible`; see `../LibGranaryDB/docs/API.md` §3) plus Hard Counters fields below. Default grains: hour, day, week, resetweek, month, year, lifetime. May be called before Hard Counters has loaded its saved data: it attaches at `ADDON_LOADED`. |
| `HC:RegisterSource(id, def)` → id | `mode = "event"` (`events`, `handler(event, ...)`), `"poll"` (`interval` ≥ 0.1 s, `read()`: the scheduler pauses it during loading screens), `"hook"` (`hook = "GlobalFunction"`, `handler(...)`, a secure post-hook). Handlers run isolated: an error is logged, counted and sent to BugSack; other handlers keep running. `feeds = { counterId, ... }`: the source runs only while one of those counters is active (§4.1; declare it). |
| `HC:SetSourceInterval(id, seconds)` | Adaptive polling. |
| `HC:RegisterView(id, def)` | A saved query; see §4. |
| `HC:RegisterPhase(id, label, startUTC)` | Content phases for the `phase` grain. Forever's launch and the Dec 9 unlock are built in. |
| `HC:RegisterDisplay(id, { title, accepts, create(parent, opts) })` | Display plugins; `HC:CreateDisplay(id, parent, opts)`, `HC:Displays()`. |
| `HC:RegisterWindow(id, def)`, `HC:RegisterSlash(name, fn, help)` | A pack's windows and `/hc` subcommands; see §9. |

**Hard Counters counter fields:** `title`, `category`, `icon`, `formatter` (`"money"`, `"duration"`, `"number"`,
`"distance"`, `"speed"`, `"speedpct"`: as for readings, below),
`capture = { mode, source }`, `accuracy` (`"exact"|"estimate"|"baseline"`),
`feasibility = { status = "feasible"|"degraded"|"infeasible"|"unverified", note, ref }`,
`runBreakdowns = { dim, ... }` (the counter's odometer keeps a total per member of these dimensions, so runs and
windows can break it down; each needs the aggregation set `{ dim }`; keep them small: 500 members, then "other"),
(`runTracked` was deleted by HC-49, 2026-11-19: every active counter is in every run; a pack still passing it is ignored), `runLive = { member = dim, cap = 500, max = true }` (per-member tallies and the best
single value with context, kept live during a run: use it for big dimensions such as items instead of a breakdown),
`liveRate` (bool: a 10-minute in-memory rate window for `HC:Live`).

## 3. Writing

| Call | Returns |
|---|---|
| `HC:Emit(id, value, dim1, ..., dim6)` | `true` counted; `false` refused (secret or invalid value, unknown counter, storage not ready). Dimensions in declared order. When storage is read-only the value still counts live (odometers, windows, boards) and only history misses it (counted as `storageRefused`, one warning per session). Same for `EmitCtx` and `Observe`. |
| `HC:EmitCtx(id, value, ctx, dims...)` | Same, with a context table for records (read, never kept: reuse one table). |
| `HC:Observe(id, value, dims...)` | Stocks (levels such as gold owned). |
| `HC:ObserveCtx(id, value, ctx, dims...)` | Stocks, with a context table for records (HC-26): storage keeps it with a new lowest or highest value, if the counter declares `context = { max = { ... } }` (or `min`). Read, never kept: reuse one table. Query rows give it back as `row.ctx`, values as text. |

Rules (PACKS §3): check `HC:Readable(...)` / `HC:IsSecret(v)` before any arithmetic or comparison on game values; no
allocation per event; poll only through sources; numbers for game IDs (`HC:ZoneKey()` is always a number: the map ID, 100000 + the instance ID inside an instance, or 0 when unknown; label it with `HC:ZoneName(key)`; query rows give it back as `r.member`);
never persist creature GUIDs; counts, never chat content.

## 4. Reading

| Call | Notes |
|---|---|
| `HC:Query(view, overrides)` → rows, err | `view` = a view id or a query table: `counter, measure, grain, last, range, groupBy, filter, top, order, entity` (LibGranaryDB's), plus `grain = "thisweek"` (the player's choice: ISO week by default, or reset week) and `per = "activeHour"` (divide by `hc:time.active` over the same selection, per zone when grouped by zone). Rows: `{ label, member, value, ctx?, ... }`, `rows.total`. `member` is the label as a number where it is one (item and map IDs). |
| `HC:QueryAsync(view, cb, overrides)` → job | Sliced over frames (2 ms). **Use it for anything big:** a by-item query over 4,096 members costs ~62 ms synchronously in game. `job.Cancel()`. |
| `HC:Series(view, overrides)` / `HC:SeriesAsync(view, cb, overrides)` | `s.keys[i]`, `s.values[i]`. |
| `HC:Live(id, window)` → rate/s, total, seconds | Counters with `liveRate`. In memory. |
| `HC:PeriodKey(grain, t)`, `HC:PeriodInfo(grain, key)` | Period keys and their calendar fields. |
| `HC:GetCounter(id)`, `HC:Counters()`, `HC:GetView(id)`, `HC:Views(counterId)` | Copies. |
| `HC:SetFeasibility(id, status, note)` | Fires `HC_FEASIBILITY_CHANGED`. |
| `HC:StorageStats()` | A copy of LibGranaryDB's `db:Stats()`. |

## 5. Runs (DESIGN §5.1, §16.3)

Every call is about the **logged-in character's** run: one open run per character (HC-30).

| Call | Notes |
|---|---|
| `HC:StartRun(label)` → id \| nil, err | One open run per character. Inside an instance it ends the automatic run first. |
| `HC:PauseRun()`, `HC:ResumeRun()` → true \| nil, err | Nothing counts while paused. |
| `HC:SplitRun(label)` → split number | A named sub-range (spot change, instance reset). |
| `HC:StopRun()` → id | Saves the record (newest first; 200 kept by default). |
| `HC:DiscardRun()` → id | Closes the open run without a record. |
| `HC:GetRun(opts)` → live copy \| nil | `{ id, label, state, elapsed, activeSeconds, totals = { [counterId] = { sum, count, by?, start?, stop? } }, best, splitCount, auto }` (`auto`: started by entering an instance). `opts.breakdowns`, `opts.live` (full tallies; not every frame). No storage queries. |
| `HC:GetRunTotal(id, measure)` → number | Allocation-free, for displays. |
| `HC:GetRunClock()` → activeSeconds, elapsed, state | For stopwatch displays. |
| `HC:Runs({ character = "current"|key, since, limit })` | Records (copies): `{ id, label, char, charName, start, stop, elapsed, pausedSeconds, activeSeconds, mainZone, deltas, live, splits? }`. |
| `HC:GetRunRecord(id)`, `HC:DeleteRun(id)`, `HC:RenameRun(id, label)` | |

**Run readings:** see §5.1 (`HC:RegisterRunReading` was deleted by HC-49: `HC:RegisterReading` with
`scopes = { "run" }`). `HC:RunReadings()` lists the readings that have a run
scope, `HC:RunReading(id)` → value, text, settled is `HC:Reading(id, "run")` (nil when no run is open).

Totals are exact, with or without history: each active counter has an odometer (a running total per character,
saved, kept across `/reload` and logout) and a run is a window over the odometers: what it banked at earlier
pauses and splits plus the odometer now minus its baseline (HC-29, DESIGN §16.2). Nothing is read from storage.
`GetRunTotal` for a stock nobody has observed is nil, not 0. Records with context (best drop) and big
per-member lists come from `runLive`. A run carries on across `/reload` and logout: it is banked at the next login
and resumes when its own character logs in; time offline and other characters' sessions are not on its clock, and
nobody is asked anything (HC-30). **Dungeon runs start and save by themselves** (entering and leaving an instance;
under 5 active minutes nothing is saved; the player's option switches it off). A record saved from a board's
window ("Save as run", HC-41) has every counter and the best single values in `live` (`live[counter].max`), but no
item lists. A record with `partial = true` was saved by a build between HC-30 and HC-41 (from tile windows): its
`deltas` hold only the counters those tiles watched and `live` is empty.

On boards a reading tile with the `run` scope does not read this run: it reads its board's timer (DESIGN §16.8).
`HC:Reading(id, "run")` still means the character's open run, and is the only place the `"norun"` state remains.

## 4.1 Trackers and history (HC-19)

A **tracker** is what the player switches on: a named feature that needs some counters. Nothing counts, listens or
polls unless a tracker that is on needs it:

```lua
HC:RegisterTracker("mypack:fishing", { title = "Fishing", counters = { "mypack:fish" }, default = "off",
  category = "Fun", icon = 136245, description = "Fish caught, by zone." })
HC:RegisterSource("mypack:loot", { mode = "event", events = { "CHAT_MSG_LOOT" }, feeds = { "mypack:fish" },
  handler = onLoot })
```

| Rule | |
|---|---|
| Active counter | Some tracker that is on lists it (a counter may be in several). `hc:time.active` is active whenever any tracker is on. A counter in no tracker never counts (`counterWithoutTracker` warning). Emits to an inactive counter return `false` quietly |
| Active source | Some counter in its `feeds` is active (no `feeds`: always). Inactive: events unregistered, poll paused, hook calls ignored |
| History | Per tracker: `off` (default: **Live only**), `lifetime`, `daily` (day retention 14, 30, 90 or 365 days), `detailed` (hours 48 h, days 90 d, weeks 2 y). A counter keeps the most any active tracker asks for; `needsHistory` raises a tracker's own |
| Live only | No storage at all: its odometer still counts (saved, survives `/reload` and logout), so the session scope and runs are exact; storage scopes read "needs history" |
| Freeze, never lose | History lowered or a tracker off: data is frozen (LibGranaryDB r3 `removed = "keep"`, or simply not registered), resumes with a gap. Storage registration can't be undone within a session: switching off stops writes at once and takes full effect at the next `/reload` |
| Delete | The only removal: `HC:DeleteTrackerHistory(id[, "hourly"|"daily"])`, `HC:DeleteCounterData(counterId)` (LibGranaryDB `DropCounter`); both return the estimated bytes freed |

| Call | Notes |
|---|---|
| `HC:RegisterTracker(id, def)` | `title`, `counters`, `default` (`"on"`/`"off"`; packs: off), `needsHistory`, `icon`, `category`, `description`. `counters = {}` (check `HC:Supports("liveTrackers")`) is a tracker of live readings only: it switches its readings on and off, has no history and no history button (Character Stats' phase 1) |
| `HC:Trackers()`, `HC:GetTracker(id)` | Copies: `{ id, title, counters, on, history, days, chosenHistory, lastHistory, needsHistory, pack, packTitle, new, ... }` (`lastHistory`: what the switch brings back, HC-48) |
| `HC:IsTrackerOn(id)`, `HC:SetTrackerOn(id, on)` | Saved per AceDB profile; switching marks it seen |
| `HC:SetTrackerHistory(id, preset[, days])`, `HC:MarkTrackerSeen(id)` | The presets ("Advanced" in the Trackers window) |
| `HC:SetTrackerKeepHistory(id, on)` | The "Keep history" switch (HC-48): on = the last preset chosen, else daily; off = the `off` preset (frozen, not deleted). A tracker with `needsHistory` keeps what it needs either way |
| `HC:CounterState(id)` | `{ active, history, days, stored }` |
| `HC:TrackerOffImpact(id)` | `{ readings = { titles }, keptBy = { trackers sharing a counter } }`: what to say before switching off |
| `HC:TrackerSize(id)` → bytes, frozen; `HC:UnloadedCounters()` → `{ { id, bytes, title, pack, why } }` | From LibGranaryDB `Stats()`. `why`: `"pack not loaded"` or `"no longer used"` (its pack is loaded but doesn't register it). Titles and packs are saved when a counter is first stored (`HardCountersDB.names`, HC-48); older data is named from its id |
| `HC:ToggleTrackers()` | The Trackers window (`/hc trackers`): per pack, on/off, history, sizes, readings with scopes and [+], "Not loaded" with Delete |

Callback `HC_TRACKERS_CHANGED` (a switch, history, or profile change), `HC_HISTORY_DELETED` (trackerId, part, or
nil, nil, counterId). Players: `/hc track` lists trackers, `/hc track <n> on|off|history <preset> [days]`.

## 4.2 Basics and attributors (HC-21)

Hard Counters ships **Basics** (`HardCounters/Basics/Basics.lua`), written against this public API only: read it as
the reference pack. Counters `hc:money.in` (`source`, `zone`), `hc:money.out` (`sink`, `zone`), `hc:money.owned`
(stock), `hc:xp` (`source`, `zone`); trackers **Gold per hour** (`hc:goldph`: money in, out, owned) and **XP per
hour** (`hc:xpph`), both on for a fresh install with history off; readings `hc:gold`, `hc:net`, `hc:xpgained` (total or
per hour), `hc:owned`, `hc:ttl` (time to level, computed), `hc:rested` (rested XP, now), `hc:xplevel`, `hc:goldfrom`,
`hc:spenton`; `hc:goldph`, `hc:netph`, `hc:xpph` are hidden aliases of the first three per hour (HC-51).
Another pack's tracker may list Basics' counters (Farmer's Ledger lists the money counters and needs daily history).

Basics measures money and XP as state diffs (`GetMoney`, `UnitXP`); their **source** is `"none"` ("Unknown")
unless a pack names it:

| Call | Notes |
|---|---|
| `HC:SetAttributor(counterId, fn)` | `fn(amount, t, book)` is called at each change of `hc:money.in`, `hc:money.out` or `hc:xp` (`amount` > 0, `t` = `GetTime()`). Call `book(amount, source)` for all or part of it, now or later; whatever isn't booked within **5 s** is booked as `"none"`. `book` never counts more than it was handed. One attributor per counter (the last set wins; `nil` clears). An attributor that errors books the whole change as `"none"` |
| `HC:GetAttributor(counterId)` | The function, or nil |

Switching Gold or XP per hour back on takes a fresh reading: what changed while it was off is a gap, never a gain.

## 5.1 Readings (one number for boards, tooltips and windows; HC-17)

A reading is a counter (or a computation over other readings), a measure and the **scopes** it can be read over,
declared as data:

```lua
HC:RegisterReading("mypack:fish", { title = "Fish caught", rateTitle = "Fish/h", tracker = "mypack:fishing",
  counter = "mypack:fish", scopes = { "run", "session", "today", "week" },
  formatter = "number", order = 10, description = "Fish caught." })
local total = HC:Reading("mypack:fish", "session")
local value, text, settled, state = HC:Reading("mypack:fish", "session", { calc = "perHour" })   -- "12/h"
```

**The calc (HC-51, DESIGN §16.9).** What number a reading gives over its scope is the asker's choice, not a second
reading: `total` (the scope's value) or `perHour` (÷ `hc:time.active` over the same scope; for a `param` in the
`zone` dimension, ÷ the time in that zone). A board tile keeps it as its "Show as". Which calcs a reading allows:
a flow (a counter of kind flow, measure `sum` or `count`, with or without `minus`) both; a stock, a `best` reading, a
`min`/`max`/`avg` measure `total` only; a `compute` reading what it lists in `calcs` (default `{ "total" }`), and
its function receives the calc as a fourth parameter (`compute(get, scope, arg, calc)`; `get(id, scope, calc)` reads
another reading with a calc). `HC:GetReading(id).calcs` lists them, `.calc` is the default. Asking for a calc the
reading doesn't allow gives no value and the state `"calc"`.

**`recent` (HC-52):** your pace now, per hour: an exponentially weighted rate over the window, half-life 5 active
minutes (fixed), so a gain counts half after 5 minutes and an eighth after 15; AFK and pauses freeze it; early on it
is the plain average. Allowed wherever `perHour` is (flows, `per` readings), and a `compute` reading may list it.
Only over a window with its own clock (`run`, `session`, a board's timer), for this character, and not for a `param`
in the `zone` dimension: elsewhere the state is `"calc"`. `settled` needs 5 active minutes **and** 5 gains (writes to
the counter in the window; for one member, gains seen since it was first asked). Kept in the window, so a
`/reload` keeps it; Reset starts it over; run records have none (`nil`). Titles: `recentTitle`, else the rate title
and " recent" ("Gold/h recent"). `HC:Live(id, window)` is unchanged: a wall-clock rate
over the in-memory 10-minute window of `liveRate` counters, for packs' own displays; boards use `recent`.

**`trend` (HC-53):** `(recent / perHour - 1) × 100` over the same scope, a signed percent; its text in words
(HC-54): "on pace" within ±10%, "87% slower", "13% faster", from twice the pace a multiple ("2.7× faster");
no value until both are settled; allowed and fitting exactly where `recent` is. Within ±10% it is "flat": the built-in
displays show it neutral. Lumpy gains make `recent` peak after each one (DESIGN §16.9 "As built (HC-53)"), so with
a gain every few minutes the trend swings out of the band at a steady pace.

**Before HC-51** a per-hour number was its own reading (`per = "activeHour"`). That still works: such a reading's
default calc is `perHour`; with no `rateTitle` its title is the rate's ("Fish/h"), so it allows `perHour` only;
with a `rateTitle`, `title` is the total's and it allows both. Prefer one reading with `rateTitle`. **Aliases:**
`HC:RegisterReading(id, { aliasOf = otherId, calc = "perHour", title?, headline?, order?, description? })`
(registered after its target; no alias of an alias) keeps an old id readable: the same counters and rules as the
target, read with its own calc by default, out of the catalog (`HC:Readings()` and the + menu leave it out unless
`{ aliases = true }`), still in the run list. Saved tiles and presets on an alias are moved to the target with the
alias's calc when the alias is registered. Basics' `hc:goldph`, `hc:netph`, `hc:xpph` are aliases of `hc:gold`,
`hc:net`, `hc:xpgained` per hour.

| Field | Notes |
|---|---|
| `counter` | The counter read. Or `compute = function(get, scope) ... end` instead: `get(readingId[, scope])` returns another reading's value (nil when it has none); return a number or nil. Derived numbers are never stored, so a corrected formula fixes the past. List what it reads in `inputs = { ids }`. |
| `measure` | `"sum"` (flows' default), `"count"`, `"last"` (stocks' default); HC-27: `"min"`, `"max"` (a stock's lowest and highest level over the scope: our windows keep them as the stock is observed, counting the levels the window started and stopped at; storage needs the counter to declare the measure; over an account-wide window they have no value; a flow's `"max"` is its best single value where a window keeps one, a board's or the open run's `runLive`), `"avg"` (sum / count; nil with no write). With a `param`, our windows serve sums only. Run records keep `lo` and `hi` per stock |
| `minus` | A second counter subtracted over the same scope (net values) |
| `rateTitle` | The title shown per hour ("Gold/h"); default `title .. "/h"` (HC-51) |
| `calcs` | A `compute` reading's calcs: `{ "total", "perHour", "recent" }` (default `{ "total" }`); the function gets the calc (HC-51) |
| `recentTitle` | The title shown with `recent` ("Time to level (current pace)"); default the rate title .. " recent" (HC-52) |
| `per = "activeHour"` | Before HC-51: the default calc is `perHour` (and the only one without `rateTitle`, see above). Per hour is `nil` ("-") under one active minute; `settled` is false under 5 active minutes (the built-in displays grey it) |
| `aliasOf`, `calc` | An alias of another reading, read with `calc` by default and hidden from the catalog (HC-51, see above) |
| `scopes` | Any of `run`, `session`, `today`, `week` (the player's week choice), `month`, `year`, `lifetime`, `now`. Default `{ "run", "session" }`. `login` was renamed `session` by HC-49 (2026-11-19), with no alias: a pack listing `login` gets an error |
| `best` | The run's best single value (from the counter's `runLive.max`); run scope only |
| `target` | A natural target for the value: a number, or `function(arg) return n end` (XP to level, the next standing). `HC:ReadingTarget(id[, arg])` reads it. The `bar` and `gauge` displays draw the value toward it, for the `total` calc only (XP to level is no per-hour goal); a tile may set its own, for any calc (DESIGN §16.6) |
| `refresh` | `{ "EVENT", ... }` for a `compute` reading whose value changes without a counter write: the engine listens only while the reading is on a shown board, and redraws |
| `applies` | `function() return bool end` (HC-28): is the reading used by this character (class, talents, level)? Asked at every read. When false the reading has no value (state `"inapplicable"`, text "n/a"), and the + menu and the Trackers window list it last, under "Not used by this character". A rule that errors counts as `readingErrors` and leaves the reading listed. `HC:ReadingApplies(id)`; copies carry `applies` (evaluated now) |
| `stale` | `function(arg) return isStale, word end` (HC-28): the value is the last one read, not the current one (a stat that is secret in combat). The value is still returned, with state `"stale"` and `word` as a fifth return ("in combat"); tiles show it greyed with the word after the title. Asked only when there is a value. The pack keeps the last value itself (a `compute` returns it); a stock's `now` is its last observation anyway |
| `live` | `function(arg) return <the game's value> end` (CS-9, check `HC:Supports("livePassThrough")`): for a reading that goes `stale` because the game keeps the value secret, the raw value. Boards hand it straight to a plain tile's font string (`SetFormattedText(format, value)`) while the reading is stale, so the tile stays live in combat with no mark; bars, gauges, account tiles and other scopes keep the stale value. `liveFormat` (default `"%.1f%%"` for `percent`, `"%.0f"` for `number`; none for money and durations: no thousands separators either way). `HC:ReadingLive(id[, arg])` → value, format for a pack's own display: pass both to a widget and do nothing else with the value. `HC:Reading` never returns it |
| `param` | `{ dim = "faction", type = "enum"\|"zone"\|"item"\|"faction", label = function(member) return text end }`: the reading shows **one member** of that dimension, chosen by whoever asks: `HC:Reading(id, scope, arg)`, or the tile's `arg` (DESIGN §16.4). Put `%s` in `title` for the member's label ("%s rep"). `minus` reads the same member; `per = "activeHour"` divides by all active time, or by the time in that zone when `dim = "zone"`. A `compute` gets the argument as its third parameter. v1: sums only. **A set instead of one member (HC-60):** `multi = true` (an `enum` parameter of a small dimension), with optional `members = { ... }` (the checklist the tile's menu offers, in this order; else the members counted so far), `presets = { { name = "On foot", members = { ... } }, ... }` and `default` (a preset's name or a list; absent: everything). The reading reads the sum of the set: pass it as `HC:Reading(id, scope, { arg = { "walk", "run" } })` (never as a bare third argument: a table there is the options); no set means the default, no default means the counter's whole total. No member is picked before adding it. A `compute` with the same `param` gets the set and passes it to the readings it `get`s (a filtered ratio). Recent and Trend are not offered for a set (DESIGN §16.4 "As built (HC-60)") |
| `formatter` | `"money"`, `"duration"`, `"number"`, `"percent"`, `"distance"` (yards: "1,234 yd"), `"speed"` (yards a second: "7.0 yd/s"), `"speedpct"` (a value in yards a second shown as a percentage of the 100% run speed, 7 yd/s, the character sheet's convention: 8.05 reads "115%"; a tile's target is typed as a percentage). For a speed in both forms, register two readings on the same value. Per-hour readings get "/h". Live pass-through formats: `"%.0f yd"` for distance, `"%.1f yd/s"` for speed, none for speedpct (TR-10) |
| `tracker`, `title`, `description`, `headline`, `order` | `description` is one line shown in tooltips and the Trackers window: say what the number counts |

| Scope | Where the number comes from | Needs history |
|---|---|---|
| `run` | the open run: a window over the odometers | no |
| `session` | the session window over the odometers: a `/reload` carries on, a new login starts over (`login` before HC-49) | no |
| `today`, `week`, `month`, `year`, `lifetime` | the open bucket of that grain in storage | that grain |
| `now` | a stock's last value, from its odometer: known from the first load after a login, before it is observed again | no |

`HC:Reading(id[, scope[, opts]])` → value, text, settled, state, note. `opts = { arg, who, calc }` (HC-51; reuse the
table if you call it every frame); the form before HC-51, `HC:Reading(id, scope, arg, who)`, still works (`arg` is
never a table). `arg`: the member of a reading with `param`; `who = "account"`: every character of the account, for
the storage periods and `now` (DESIGN §16.5); `calc`: `"total"`, `"perHour"`, `"recent"` or `"trend"`, nil for the reading's default
(the text ends in "/h" for `perHour` and `recent`, except on a `compute` reading). `state` is nil, or why there's no value: `"scope"` (not offered), `"calc"` (a calc
the reading doesn't allow), `"off"` (its tracker is off or nothing keeps its counter running; the text is "off"), `"norun"`, `"needs history"`
(the counter keeps no such grain, or for a member: no aggregation set holds that dimension), `"unknown"`, `"error"`
(a compute failed; counted as `readingErrors`), `"noarg"` (a reading with `param` asked without `arg`), `"capped"`
(the member is past a cap and was counted under "other"; the text is "over the limit", never 0),
`"inapplicable"` (HC-28 `applies` said no; the text is "n/a"). One state comes **with** a value: `"stale"` (HC-28
`stale` said so); `note` is then the pack's word for why, else nil.

**One member:** small dimensions (declared `cap` up to 500) are kept per member for every active counter, with or
without history. A big dimension (items) is kept only for members somebody asked for, from the first ask on; the
open run knows every member of its `runLive` dimension. Storage scopes ask by `filter` and keep the answer 10 s.

**Pickers (HC-34):** `param.type` chooses how the player picks the member, with no code from the pack. `"item"`:
an item dragged from the bags onto a board (the member is its numeric item id), or one of the last 20 members
written to that dimension of the reading's `counter`; `"faction"`: the game's reputation list (the member is the
faction id); `"enum"` and `"zone"`: the members counted so far. A `compute` reading with `param` can name a
`counter` only to supply that list (Farmer's "%s in bags"). Key such dimensions by item id and faction id, and
give `param.label` so tiles show names. `HC:GetReading(id)`, `HC:Readings({ scope, tracker })` return copies.
Run, session and now are allocation-free apart from the text; storage scopes run one small query on open buckets.

## 6. Callbacks

`HardCounters.RegisterCallback(owner, event, fn)` / `UnregisterCallback(owner, event)`; `fn(event, ...)`.

| Event | Arguments |
|---|---|
| `HC_COUNTER_REGISTERED` | id |
| `HC_NEW_RECORD` | id, measure, value, ctx (copy), previous (lifetime records, throttled by LibGranaryDB) |
| `HC_PERIOD_CLOSED` | id, grain, key |
| `HC_RUN_STARTED`, `HC_RUN_STOPPED`, `HC_RUN_RESUMED`, `HC_RUN_DELETED` | runId |
| `HC_RUN_PAUSED` | runId, reason (`"manual"` or `"logout"`) |
| `HC_RUN_SPLIT` | runId, split number |
| `HC_RUN_RECORD` | counterId, value (a new best for the open run) |
| `HC_ZONE_CHANGED` | zone key |
| `HC_FEASIBILITY_CHANGED` | id, status, note |

## 7. Helpers

`HC:Supports(feature)` (`"bigDimensions"`: caps up to 4,096, LibGranaryDB API 2), `HC:IsSecret(v)`, `HC:Readable(...)`, `HC:ChatPattern(globalString)`, `HC:ZoneKey()`,
`HC:ZoneName(key)`, `HC:Now()` (UTC epoch seconds: every stored timestamp), `HC:LoginStart()` ("this login",
survives `/reload`), `HC:IsActive()`, `HC:FormatMoney(c)`, `HC:FormatDuration(s)`, `HC:FormatNumber(n, dec)`,
`HC:Phases()`, `HC:CurrentPhase()`, `HC:ToggleRunPanel()`, `HC:ToggleRunList()`.

**Board presets (packs, 2026-11-19).** `HC:RegisterBoardPreset(key, def)` (check `HC:Supports("boardPresets")`): `key`
namespaced (`"hcstats:caster"`), `def = { name, mini, tiles = { { reading, scope, calc, display, size, extras, arg },
... } }` (HC-51, DESIGN §16.9): `scope` defaults to `"run"`, the board's timer; `calc` to the reading's default;
`display` (`"number"`, `"bar"`, `"gauge"`, `"odometer"` for a count or distance total, `"mix"` for a reading with a small `enum` parameter: HC-63) to `"number"`; `size` (`"large"`, `"half"`, `"line"`) to `"line"`; a large
number gets `extras = { sparkline = true, vsUsual = true }` unless the tile lists its own (`{ "sparkline" }`). Bars and
gauges are drawn as lines whatever the size. A tile's `style` of before HC-51 is still read: hero = large number with
both extras, grid = half number, row = line number, bar = line bar, gauge = line gauge. A tile naming an alias
(`hc:goldph`) is made on its target with the alias's calc. Offered in the New board dialog and the Boards tab under your pack's title (after Hard Counters' own), and as
`/hc board new <key>`; tiles whose reading isn't registered are left out when a board is made.

**Your characters and account-wide values (FM-16).** `HC:IsOwnCharacter(name)`: true for a character of this account
that has loaded Hard Counters ("Name" on this realm, or "Name-Realm" with the realm's spaces dropped, as mail
and chat give it); Hard Counters keeps only name and realm per character (`HardCountersDB.chars`), written at each
load. `HC:ExcludeOnAccount(counterId, dim, member)`: every account-wide sum of that counter (`who = "account"`, any
scope, whole or per member, `minus` included) leaves that member out, and the member asked for on its own reads 0
over the account. Farmer uses it for money between your own characters (`alts`): it moved, nobody earned or spent it.

## 8. Slash commands (players)

One root, `/hc` (also `/hardcounters`). `/hc` alone opens the Hard Counters window (or lists the commands when it has
no tabs); `/hc help` lists them, with the pack each one comes from.

`/hc run start [label] | stop | pause | resume | split [label] | status`, `/hc runs`, `/hc board [n | new <preset> | mini <n> | reset]`,
`/hc edit` (edit boards), `/hc panel [compact|full]` (the Run board), `/hc live` (the Pocket board), `/hc trackers`
(the Trackers window), `/hc track` (the same from the chat line),
`/hc windows`, `/hc options`, `/hc welcome` (the introduction a new character gets), `/hc report [addons]`;
`/hc diag [mark|snap|probes]` (Diagnostics);
`/hc ledger` (Farmer). The older `/hcdiag` still works as an alias (`/hcf` and `/farmer` were deleted by HC-49).

## 9. Windows and subcommands (packs)

Hard Counters owns the window chrome, so every pack window behaves the same: Blizzard's panel frame (border, title,
close, inset; `ButtonFrameTemplate`, with a plain fallback), drag, raise on click, Escape, BlizzMove
(Ctrl+mouse wheel scales it when BlizzMove is installed), and its position and scale saved per profile. Every
window is a **tab of the shared Hard Counters window**; there is no pop-out (removed 2026-11-15, DESIGN §7.1). A
pack's window is an **icon tab down the window's right edge** (since 0.2.1; Hard Counters' own tabs run along the
bottom): give it an `icon`, and its `title` is the tab's tooltip. A column too long for the window scrolls.

The shared window is not resizable and is one size for every tab: a design size of 780 × 640 (the body inside is
about 762 × 568), wider only when a tab's `minWidth` needs more, capped at the screen. A tab whose `minHeight` (or
`minSize()` height) is taller than the body **scrolls vertically**: your content frame gets that height and the
window adds a scroll bar. Lay your content out to fill whatever room it gets, and keep your minimum honest: a large
width makes the panel wider for every tab, a large height makes yours scroll. Only a window with `dockable = false`
(a HUD, a popup) gets a frame of its own, with a resize grip and a saved size. Check `HC:Supports("windows")`.

| Call | Notes |
|---|---|
| `HC:RegisterWindow(id, def)` → ok, err | `id` is namespaced like a counter (`"hcfarm:ledger"`). `def.build(content)` builds into a plain frame that fills the window body; it runs once, at the first show. Optional: `title` (the tab's tooltip), `icon` (the tab's icon: a texture path such as `"Interface\\Icons\\INV_Misc_Coin_01"` or a file id; without one the tab shows Hard Counters' icon; a Hard Counters before 0.2.1 ignores it), `onShow(content)` / `onHide(content)` (called exactly when the window comes on or goes off screen: start and stop tickers there), `onClose()`, `width`, `height`, `minWidth`, `minHeight` or `minSize()` → w, h, `maxWidth`, `maxHeight`, `fixedHeight()` → h or nil, `remember` (reopen at login if it was open), `escape` (`false`: Escape doesn't close it), `dockable` (`false`: a frame of its own, never a tab), `mainButton` (a label: the shared window gets a "Show/Hide <label>" button for this window), `chrome` (`"hud"`: a plain dark frame with no title bar instead of the panel frame; the content keeps its top-right corner clear for the close button; `titleBar = false` means the same), `strata`, `frameName` (for `dockable = false`: global name of its own frame; BlizzMove remembers frames by name). Sizes are the content's; the host adds its chrome. |
| `HC:ShowWindow(id[, show])` | `show` nil toggles. A tab is shown by opening the shared frame on it. |
| `HC:ToggleWindow(id)`, `HC:IsWindowShown(id)` | Shown = on screen (a tab counts only while it is the selected one). |
| `HC:RelayoutWindow(id)` | Re-reads `minSize()` / `fixedHeight()` after the content changed shape. |
| `HC:RegisterSlash(name, fn[, help, owner])` → ok, err | `/hc <name> [args]`; `fn(rest)` gets the text after the name. Lowercase letters and digits; a name already taken (by Hard Counters or another pack) is refused. `owner` labels it in `/hc help`. Check `HC:Supports("slash")`. |

Content rules: anchor to the content frame's edges (it is resized), redo width-dependent layout in its
`OnSizeChanged`, never show or hide the content frame yourself, and never call `SetParent` on it.
