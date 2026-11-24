# Trackers and boards: choose what you count, build your own HUD

> **Status:** agreed 2026-11-15 (§0); **built 2026-11-15 (v2 M0–M6)** except drag and drop and board strings (HC-22).
> As built: DESIGN.md §4.1 (trackers), §4.2 (Basics), §5.2 (readings), §7.2 (boards), §7.3 (Trackers window). Agreed decisions move into
> [`DESIGN.md`](DESIGN.md) as each part is built; work is queued as HC-16 to HC-23, FM-13, FM-14 and LG-17, and the
> new pack's work as CS-n in `packs/CharacterStats`.
>
> **2026-11-18:** the next direction is [DESIGN §16](DESIGN.md): every reading tile gets its own window (start,
> pause, stop), which will replace §5.2 here (runs as a manual scope) once built; readings get a parameter; a tile
> can be per character or account-wide. The word for a single number is "reading", never "tracker" (DESIGN §1.0).
>
> **Where it came from:** the user's ideas on 2026-11-15 (counters switched on on demand, a history setting per
> counter type, a list of trackers you drag onto your own minimal HUD, a basic pack inside Hard Counters, a
> Character Stats pack), plus a review of the 2026-11-15 in-game screenshot written as a demanding player would.
>
> **What it changes:** the run panel and the live number stop being bespoke HUDs; both become *boards* built from
> *tiles*. Run readings and views merge into one *reading* API. Nothing is counted or stored unless a tracker the
> player switched on needs it. History is off by default. Hard Counters ships a small Basics module (gold and XP per
> hour); Farmer becomes the farmer's collection on top of it.

---

## 0. Decisions (user, 2026-11-15)

1. **Boards replace the run panel and the live number.** Both are re-imagined (§6.3).
2. **The word is "board"** (chosen from board, HUD, readout, tally): `/hc board`, "Add to board", "Run board".
3. **Starters: only Gold/h and XP/h are on** for a fresh install, and both can be switched off. A pack's trackers
   start **off**, marked *New* in the Trackers window, Farmer's included.
4. **No history by default.** Every counter starts Live only. The UI explains clearly what history is and what
   turning it on gives (§3.4).
5. **Gold per hour and XP per hour ship with Hard Counters itself** (the Basics module, §4). The rest of Farmer stays
   the farmer's collection.
6. **Default scope of a new tile:** chosen here (§5.3), to revisit after use.
7. **A new pack, "Hard Counters: Character Stats"**, for detailed character stats tracking
   (`packs/CharacterStats/docs/DESIGN.md`).
8. **Counters that no tracker needs are switched off** to save resources, and so are their sources (§2.2).
9. **Runs stay,** as a scope the player opens and closes on the same window mechanism as `login` (§5.2). A fresh
   install shows the Pocket board; the Run board appears with the first run. (Since HC-74, 2026-11-24: boards are
   each character's own, and a new character starts with the Leveling board; DESIGN §17.12.)

## 1. Words

| Word | Meaning | Who defines it |
|---|---|---|
| **Counter** | What is stored or kept in memory: a LibGranaryDB counter (`hc:money.in`). Players never see this word | Pack |
| **Tracker** | What the player switches on or off: a named feature that needs some counters ("Gold per hour", "Ledger") | Pack |
| **Reading** | One number a player can put on a board: a counter, a measure and a scope ("Gold/h, this run") | Pack |
| **Scope** | The time a reading covers: this run, this login, today, this week, this month, lifetime | Hard Counters |
| **Board** | An on-screen HUD the player builds: a vertical stack of tiles, with a mini mode | Player |
| **Tile** | One reading (or the run controls) placed on a board, with its scope and style | Player |
| **History** | How much of the past is kept on disk. Off (Live only) by default | Player, per tracker |

## 2. Trackers: count only what is used

### 2.1 Definition

```lua
HardCounters:RegisterTracker("hc:goldph", {
  title = "Gold per hour", icon = 133784, category = "Basics",
  counters = { "hc:money.in", "hc:money.out" },
  default = "on",            -- "on" | "off" (packs: "off" unless the user says otherwise; see §0.3)
  needsHistory = nil,        -- or "lean": the tracker makes no sense without history (Farmer's Ledger)
  description = "Money looted and earned per active hour, this run or this login.",
})
```

- **A counter may belong to several trackers.** `hc:money.in` feeds Basics' "Gold per hour" and Farmer's "Ledger".
- **A counter that belongs to no tracker is never active.** A pack that registers one gets a warning in the
  diagnostics log; it's a pack bug, not a player choice.
- **Core counters follow the same rule.** `hc:time.active` is active whenever any tracker is on (every per-hour rate
  divides by it) and keeps the most history any active tracker keeps.
- **State is per profile** (AceDB profiles), so alts can run lean.

### 2.2 Derived activation: nothing runs that nothing needs

```
tracker on?  ──►  counter active  = some tracker that is on uses it
                  counter history = the most any such tracker keeps (§3)
                  source active   = some counter it feeds is active
```

| Layer | Inactive means | Change needed |
|---|---|---|
| Storage | Not registered with LibGranaryDB: no writes, no maintenance. Saved data stays on disk, frozen (maintenance only walks registered counters), and resumes when the tracker is switched on again (§3.3) | Registration happens at load, so switching off takes full effect at the next `/reload`; until then emits return `false` quietly |
| Capture | A source whose counters are all inactive unregisters its events (event sources), pauses (poll sources) or ignores calls (hooks, which can't be removed) | `feeds = { counterId, ... }` on `RegisterSource`. **Pack rule (PACKS §3):** every event a pack listens to goes through `RegisterSource`, so Hard Counters can switch it off. A pack's own frames listening to events are a bug |
| Emits | Silent | Today an emit to an unknown counter logs a warning and counts `emitUnknownCounter`. Inactive counters get a quiet path |
| Readings, views, windows | Readings show "off" (never 0). A window whose trackers are all off shows one line and a button: "The Ledger is off. Turn it on" | Readings and views name their tracker |
| Runs | Inactive counters are not snapshotted | Run snapshots skip them |
| Packs | A pack whose trackers are all off costs its registration and nothing else | Follows from the above |

- **Switching on works mid-session:** registering after load already attaches the counter. The data has a gap for
  the time it was off; that's correct.
- **Switching off shows what goes with it:** "Turning Gold per hour off also stops: Gold/h and Net gold/h tiles on
  your Run board. Farmer's Ledger keeps money counting." The list comes from readings, views and other trackers.

### 2.3 First load

On a fresh install, Gold per hour and XP per hour are on, nothing else is, and history is off. The Trackers window
does **not** open by itself on a fresh install (nothing to decide yet); the Pocket board shows (§5.2, §6.4), with a
one-time tip pointing at the Trackers window. When a new pack appears, the Trackers window opens once with its trackers marked
*New*, all off.

## 3. History

### 3.1 Off by default

Every tracker starts **Live only**: nothing is written to disk for it. What still works:
- **this login:** totals since the real login, kept in memory and carried across `/reload` (one number per counter
  in the login state), gone at logout;
- **runs:** a run subtracts the in-memory totals the same way it subtracts lifetime totals today. **Run records are
  still saved** in the run list: a run is something the player chose to record, not background history (its size
  is HC-10's question).

What needs history: today, this week, this month, lifetime, the Ledger, charts, and comparisons with earlier periods.

### 3.2 Presets, chosen per tracker

The player sets history on the tracker row. A counter keeps the **most** that any active tracker using it asks for.

| Preset | Grains stored | Retention | Gives |
|---|---|---|---|
| **Off** (Live only, default) | none | nothing on disk | this login and runs |
| **Lifetime** | lifetime | forever | all-time totals and records |
| **Daily** | day, week, month, year, lifetime | day 14 d (choice: 14 / 30 / 90 / 365) | today, this week, month, year, lifetime, the Ledger |
| **Detailed** | hour, day, week, reset week, month, year, lifetime | hour 48 h, day 90 d, weeks 2 y, coarser forever | all of the above plus "last 48 h by hour" |

- **The day retention is the real storage lever:** day chunks are most of the bytes (LibGranaryDB SPEC D6).
- **A tracker with `needsHistory`** (the Ledger: "daily") turns history on for its counters when the player turns it
  on, and says so in the confirm line: "The Ledger keeps daily history for money in and out (about 20 KB a month)."
- **A reading's scopes follow history:** a tile can pick only the scopes its counter has (§5.3).

### 3.3 Nothing is lost unless the player presses Delete (user, 2026-11-15)

Counters must be resumable when required. Every action except an explicit Delete freezes data instead of removing
it:

| Player action | What happens on disk | Back again |
|---|---|---|
| **Tracker off** | The counter isn't registered, so LibGranaryDB neither writes nor maintains it: frozen as it was | Switching it on resumes, with a gap: open buckets left from before close into their own periods, lifetime carries on, a stock's time-weighted average never counts the gap (its carry lives in memory only) |
| **History lowered** (Daily → Lifetime, or to Off) | The grains no longer wanted are **frozen, not deleted**: not written, not maintained, kept. Lowering to Off is the same as tracker off for storage | Raising history again resumes those grains, with a gap |
| **History raised** to a grain never kept before | The new grain starts empty | "History starts now; nothing before today can be filled in." |
| **Delete history** (whole tracker, or only its hourly or daily part) | `db:DropCounter` (LG-17) removes the data, with a confirm showing the bytes: "Delete 410 KB of daily history for Gold per hour? This can't be undone." | The tracker can still be switched on; it starts from empty |
| **Retention changed** (days kept) | Applies at the next maintenance pass (no fingerprint change); data is kept at least as long as set, at most one chunk longer | A longer retention keeps future data longer; days already past the old limit are gone |

- **Frozen data isn't exempt from retention.** When a counter or grain resumes, the first maintenance pass applies
  its retention, so hour and day data older than the limit go, exactly as if it had kept running. Months, years and
  lifetime are kept forever, so totals and records always survive a freeze.
- **Frozen data counts toward the storage budget,** and the Trackers window shows it per tracker ("frozen, 410 KB").
  Today LibGranaryDB counts frozen counters in its total but cuts only registered ones, so frozen data could get
  *active* counters degraded for good. LG-17 fixes that: over budget, frozen data is cut first, and only its hour and
  day data (never months, years or lifetime).
- **This needs two library changes** (LG-17): frozen instead of deleted grains (`removed = "keep"` in a definition;
  today removed grains are deleted at the next pass) and `db:DropCounter`.

### 3.4 Making "no history" clear (user's requirement)

The default must never look like a bug ("why is my lifetime gold zero?"). The words, where they appear:

| Where | Text |
|---|---|
| Tracker row, history off | Badge **Live**. Tooltip: "No history: these numbers cover this login and your runs, and reset when you log out. Turn on history to keep daily totals, see today and this week, and compare with earlier days. About 20 KB a month." |
| A tile's scope menu | Scopes the counter can't serve are listed greyed with "needs history". Clicking one offers: "Turn on daily history for Gold per hour?" |
| A window that needs history (Ledger) while it's off | One line and a button in place of the numbers |
| First week of use, once | A tip on the Run board: "Hard Counters keeps nothing on disk until you ask. Trackers ▸ History." |
| Trackers window footer | "History on for 2 of 9 trackers · 180 KB on disk" |

The size figures come from `db:Stats()` (per counter, measured), or an estimate for trackers not yet on (bytes per
day of a comparable counter; marked "about").

### 3.5 What needs new code

| Need | Where | Size |
|---|---|---|
| Effective grains/retention per counter (union over active trackers), applied to `sdef` before `db:RegisterCounter` | Hard Counters `Registry.lua` | small |
| **Live only counters:** no LibGranaryDB handle; Emit/Observe update in-memory totals (flows) or last/min/max (stocks), plus the optional rate window; runs and the login scope subtract from them; the login state and the open run's state carry them across `/reload` | Hard Counters engine | medium |
| Run snapshots that read in-memory totals for Live only counters and lifetime totals otherwise | `Runs.lua` | small |
| **Library support for resumable history** (§3.3): `db:DropCounter(id, opts)` (the only deleting call; by character or by grain; no tombstone, so the id can be registered again from empty), `removed = "keep"` (removed grains frozen, not deleted), and a budget that cuts frozen data first | LibGranaryDB **LG-17**, a MINOR | medium, a library release with tests |
| Hard Counters registers every counter with `removed = "keep"`; Delete buttons per tracker and per grain; frozen sizes in the Trackers window | Hard Counters, after LG-17 | small |
| "Not loaded" list: counters on disk that nothing registered this session (`db:Stats()` lists them), frozen, with size and Delete | Hard Counters, after LG-17 | small |

## 4. Basics: gold and XP per hour inside Hard Counters

- **A module of the Hard Counters addon** (`HardCounters/Basics/`), namespace `hc`, written **only against the
  public API**, so it doubles as the reference pack for authors (replacing the planned jumps sample, HC-6).
- **Counters** (moved from Farmer, same shapes): `hc:money.in` (dimensions `source`, `zone`), `hc:money.out`
  (`sink`, `zone`), `hc:money.owned` (stock), `hc:xp` (`source`, `zone`). One source diffs `GetMoney()` on
  `PLAYER_MONEY`; one diffs `UnitXP()` on `PLAYER_XP_UPDATE` (with the level-up wrap Farmer already handles).
- **Trackers:** *Gold per hour* (money in, out; on) and *XP per hour* (XP; on).
- **Readings:** Gold/h, Net gold/h, Gold earned, XP/h, XP gained, **time to level** (XP left ÷ XP/h, from `UnitXP` /
  `UnitXPMax`), **rested XP** (`GetXPExhaustion`). This settles the leveling question (HC-21): the leveling basics
  are Basics; kills to level needs XP by source and stays Farmer's (or a later pack's).
- **Sources of money and XP without Farmer** are `none` ("Unknown" in the UI). **Farmer plugs in attribution:**
  `HC:SetAttributor("hc:money.in", fn)`: at each change Basics asks the attributor for the source; the attributor
  may answer later (Farmer matches chat lines that can arrive just before or after `PLAYER_MONEY`), in which case
  Basics books it when it answers or after a short timeout as `none`. Farmer's attribution tests
  (`tests/attribution_spec.lua`) move with it.
- **Mail between your own characters** counts on both sides, gold/h included (Farmer DESIGN §4.1, the user's
  decision, 2026-11-15). Basics books it as income and spending like any other money change.
- **Migration:** Farmer's `hcfarm:money.*` and `hcfarm:xp` become orphans (only the developer's own test data); they
  show under "Not loaded" with a Delete button once LG-17 exists.
- **What Farmer keeps:** the Ledger (needs daily history), Loot (items, vendor value, best drop), Reputation, the
  money and XP attributors, and its later tools (Spot compare, Goals, Hunt, Alerts, price bridges).

## 5. Readings: one API instead of two

### 5.1 Definition

Today a pack declares **run readings** (`RegisterRunReading`) and **views** (`RegisterView`) with overlapping fields.
Boards need one thing: a scalar reading over a choice of scopes.

```lua
HardCounters:RegisterReading("hc:goldph", {
  title = "Gold/h", tracker = "hc:goldph",
  counter = "hc:money.in", measure = "sum", minus = nil,
  per = "activeHour",                    -- divide by hc:time.active over the same scope
  scopes = { "run", "login", "today", "week" },
  formatter = "money", headline = true, order = 10,
  description = "Money looted and earned per active hour (AFK time excluded).",
})
```

| Scope | Source | Needs history | Cost |
|---|---|---|---|
| `run` | the open run's snapshot subtraction (exists) | no | allocation-free |
| `login` | a snapshot at the real login (new; today only the login time is kept) | no | allocation-free |
| `today`, `week`, `month`, `year` | `db:Query` on the open bucket of that grain | Daily | small, in memory |
| `lifetime` | the lifetime bucket | Lifetime | small, in memory |

- **Hot data only on boards.** Ranges over closed buckets ("last 7 days") cost 10–30 ms cold (LibGranaryDB P5) and
  are not tiles; windows use views and `QueryAsync` for those.
- **Every reading has a one-line `description`** (tile tooltip, Trackers window): that's where "active hour" is
  explained. Rate labels carry their scope ("Gold/h · run"), so different per-hour numbers stop looking alike.
- **Views stay** for grouped and ranged queries (the Ledger's income by source).
- **Migration:** `RegisterRunReading` becomes a wrapper (`scopes = { "run" }`) for one release; Farmer moves in the
  same change. The API is still experimental (DESIGN §10), so this is the time.

### 5.2 Runs are a scope you set yourself (decided 2026-11-15; replaced 2026-11-18)

> **Replaced by DESIGN §16.3 (HC-30) and §16.8 (HC-41), built 2026-11-18:** a board is the clock (one timer per
> board; tiles with the run scope read it); runs are records (dungeons by themselves, "Save as run" on a board).
> What follows is the history of the decision.

The user asked whether runs are still needed (and on 2026-11-15 chose to **keep them**, as below), now that counters are per character and trackers decide what is
counted. **Trackers answer *what* is counted; a run answers *when*.** Neither replaces the other, but a run no
longer needs to be a concept of its own:

- **Every scope is a time window.** `login`, `today` and `week` are windows that open and close by themselves. **A
  run is a window the player opens and closes** (or a rule does: HC-2's instance runs). A split is a window inside a
  run. One mechanism, snapshot subtraction, serves all of them (the `login` scope in §5.1 reuses the run code).
- **What a run gives that automatic windows can't:** a total that covers *one activity*. "Today" mixes questing, the
  auction house and farming; a run covers just the Deadmines farm. That's what makes per-hour rates honest and what
  lets runs of the same activity be compared (the Run board's "vs your average here", Farmer's Spot compare, the
  loot log per run). Without runs, those features have nothing to stand on.
- **What a run covers:** the trackers that are on, from the moment each is on. A tracker switched on mid-run counts
  from then; its tiles say "since 12:31".
- **Who sees runs:** not every player wants a stopwatch. A levelling player is well served by `login`. So a fresh
  install shows the **Pocket** board (mini, Gold/h and XP/h · login), not the Run board; the Run board appears the
  first time the player starts a run (`/hc run`, the Pocket's right-click menu, a keybinding), or with Farmer.
- **Where runs live:** the window mechanism stays in Hard Counters (it's counter-agnostic and cheap, and `login`
  needs it anyway). The run list, the summary card and comparisons stay there too, because any pack's counters can
  be in a run.

The alternative, dropping runs, removes the run board, the comparison line, Spot compare and per-run loot logs,
and leaves "this login" as the closest thing, which mixes activities.

### 5.3 Default scope of a new tile (decision 6, to revisit)

**`run` if the board has a run tile, otherwise `login`.** Both work with history off, so a new tile never starts
greyed. The player can change it per tile. (Since HC-30: `run`, the board's timer since HC-41, whenever the reading
offers it.)

## 6. Boards

### 6.1 Model

> Since HC-67 (2026-11-23, DESIGN §17.9) a reading tile lives in a collection apart from the boards; a board holds
> its placements (order and size). The sketch below is the first model.

```lua
settings.boards = {
  { id = "b1", name = "Run", pos = {...}, scale = 1, width = 260, mini = false,
    show = { combat = "fade", instance = "show", runOnly = false, mouseoverFade = false },
    tiles = {
      { kind = "run" },                                          -- header: state, name, clock, controls
      { kind = "reading", reading = "hc:goldph",  scope = "run", style = "hero" },
      { kind = "reading", reading = "hc:xpph",    scope = "run", style = "grid" },
      { kind = "reading", reading = "hc:netph",   scope = "run", style = "grid" },
      { kind = "splits" },
      { kind = "reading", reading = "hcfarm:best", scope = "run", style = "row" },
    } },
}
```

- **A vertical stack.** The board's height always follows its tiles (the 2026-11-15 screenshot had ~40 % empty
  space); the grip changes only the width. No free-form grid.
- **Tile styles:**

| Style | Look | Use |
|---|---|---|
| `hero` | small gold label, a large number, a 10-minute sparkline under it, a comparison line ("▲ 18 % vs your average here") | the one number that matters |
| `grid` | consecutive grid tiles pair up in two columns: grey label above, white value | dense secondary numbers |
| `row` | label left, value right | long labels, item links |
| `strip` | used only in mini mode (§6.3) | |

- **Tile kinds:** `reading`; `run` (state dot, run name, active clock, icon controls); `splits` (the last split's
  rate against the one before); `label` (a heading). Packs don't add kinds in v1.
- **Values that haven't settled** (a rate's first 5 active minutes) stay grey, as today.
- **Visibility rules per board:** in combat (show / fade / hide), in instances, only while a run is open, fade until
  moused over. Boards aren't secure frames, so hiding in combat is allowed. Raiders uninstall HUDs that cover the
  boss.

### 6.2 Edit mode

- **Locked by default.** Outside edit mode a board is text: clicks pass through to the world except on the run
  tile's controls and the mini strip; nothing cycles or moves by accident (the 2026-11-15 screenshot had the
  headline cycled to Vendor value/h, most likely by a click on the band).
- **Enter** with `/hc edit`, the Trackers window, the minimap right-click menu or a keybinding. Boards show an
  outline, a name bar, a grip and a "+" at the bottom; the Trackers window opens beside them. Right-click a tile:
  scope, style, rename, remove.
- **Leave** with Escape, Done or the keybinding.

### 6.3 The Run board and its mini mode, re-imagined

The old run panel was a form: big red buttons, a long list of equal rows, empty space. The Run board answers the
farmer's two questions in one glance: *how fast am I going* and *is that good*.

```
┌──────────────────────────────────────────┐
│ ● Deadmines farm            12:48  ⏸ ⑂ ■ │  run tile: state dot, name (click to rename), active clock,
├──────────────────────────────────────────┤            pause, split, stop as small icons
│ GOLD / H · RUN                           │
│ 1g 9s 16c                                │  hero: the headline
│ ▁▂▂▃▅▄▅▆▆▇  ▲ 18% vs your average here    │  sparkline of the last 10 minutes; comparison with this
├────────────────────┬─────────────────────┤  zone's past runs (shown after 3 runs there)
│ XP/h               │ Net gold/h          │
│ 9,491              │ 1g 9s               │  grid tiles
│ Gold earned        │ Items looted        │
│ 23s 29c            │ 9                   │
├────────────────────┴─────────────────────┤
│ Split 3   1g 2s/h   ▲ 8% on split 2      │  splits tile
│ Best  [Linen Cloth] ×4         80c       │  row tile, item link with its tooltip
└──────────────────────────────────────────┘
```

**Mini mode** (any board; the run panel's "compact" view grown up): one line, about 22 px, that fits under the
minimap or above the action bars.

```
 ● 1g 9s/h  ▲18%  12:48
```

- The dot is the run's state; **click it to pause or resume**. Right-click: split, stop, rename, full board, edit.
- **Hover shows the full board as a flyout** next to the strip, and hides it when the mouse leaves: deep on demand
  without screen space.
- A board's mini strip shows its run state (if it has a run tile) and its hero tile; a board without a hero shows
  its first reading.

**Without Farmer** the Run board shows Gold/h, XP/h, Net gold/h, Gold earned, time to level. **With Farmer** the
preset adds vendor value/h, items looted and the best drop. The comparison line needs only the run list (HC's
own saved runs), so it works with history off.

### 6.4 Shipped presets and migration

| Preset | Tiles | Replaces |
|---|---|---|
| **Run** | as §6.3 | the run panel (`RunPanel.lua`, deleted in HC-24) |
| **Pocket** (a board that starts in mini mode) | Gold/h · login as hero | the live number (`LiveNumber.lua`, deleted in HC-24) |
| **Leveling** | XP/h hero, time to level, rested XP, XP gained · login | new |

- `settings.runPanel` (shown, headline, compact, size, position from `windows.runPanel`) seeds the Run board once;
  compact becomes mini mode. `settings.liveNumber` seeds Pocket. `/hc panel` and `/hc live` keep working as aliases
  for those boards. The bespoke files are deleted after the migration has been seen working in game.

### 6.5 Cost

One ticker per visible board: 0.5 s while it holds a `run` tile and a run is open (today's run panel rate), 5 s
otherwise. Hidden boards cost nothing; a board in mini mode redraws only its strip. Ticks read snapshots and open
buckets only (§5.1). Sparklines read the in-memory rate window (`liveRate` counters), never storage.

### 6.6 Elsewhere a reading can go

- **Bar feed:** a tile can be marked "also on the bar" (one LDB object per marked tile), replacing `feed = true`
  views.
- **Minimap and bar-feed tooltip,** trimmed: run state and active time, the headline, today's net if history is on,
  the click hints. Today it repeats the whole run panel and covered Questie's tracker in the screenshot.

## 7. The Trackers window

> Rebuilt 2026-11-23 on the shared browser (HC-66, DESIGN §17.8): category tree, columns, detail pane, actions.
> The mock-up below is the first layout (2026-11-15).

A tab of the shared Hard Counters window, `/hc trackers`. The catalog, the on/off switchboard and the storage panel
in one.

```
 [search            ]                         History on for 2 of 9 · 180 KB
 Hard Counters
  ▾ Gold per hour     [on]   Live ⓘ                     0 KB
      Gold/h ··········· run  login  today·  week·        [+]
      Net gold/h ······· run  login  today·  week·        [+]
      Gold earned ······ run  login  today·  week·        [+]
  ▸ XP per hour       [on]   Live ⓘ                     0 KB
 Farmer                                                  New
  ▸ Ledger            [off]  needs Daily history
  ▸ Loot              [off]  Live ⓘ
  ▸ Reputation        [off]  Live ⓘ
 Character Stats                                         New
  ▸ Attributes        [off]  Live ⓘ
  ...
 Not loaded
    hcfarm:money.in          310 KB                      [Delete]
                                      (· = needs history)
```

- **Tracker row:** on/off, history (Off / Lifetime / Daily / Detailed, with days for Daily), size on disk, expand.
- **Reading row:** title (tooltip: description), scope chips (greyed ones need history), `[+]` adds it to the board
  last edited (or a new board), and the row can be dragged (§7.1).
- **Adding a reading from a tracker that's off** asks: "Turn on Reputation?" Never silently.

### 7.1 Drag and drop

WoW has no drag and drop for addon objects (the cursor carries only items, spells, macros and the like), so it's
built by hand:
1. `OnDragStart` on a reading row creates a ghost tile (the `row` look, 70 % alpha) that follows
   `GetCursorPosition()` divided by the UI scale, in an `OnUpdate` that exists only during the drag.
2. Over a board in edit mode, an insertion line shows where it will land (row index from the cursor's y).
3. `OnDragStop`: over a board → insert; over empty screen → a new board there with this one tile; over the
   Trackers window → cancel.
4. Inside a board: drag a tile to reorder; drop it outside every board to remove it (with an undo line).

The `[+]` button ships first; drag and drop follows on the same model (§10).

## 8. Sharing boards

A board exports as a data-only string (DESIGN §9: never code), `!HCBoard:1!…`: tiles by reading id, scopes,
styles, visibility rules; no position. Importing a board whose readings belong to a missing pack shows those tiles
as "needs Farmer". Cheap word of mouth ("my Deadmines farming board" pasted in Discord).

## 9. Wider UX, folded from the review

### 9.1 Screenshot fixes (2026-11-15), until boards replace the run panel

| Item | Fix | Where |
|---|---|---|
| Run panel: ~40 % empty space in full view | Height follows content (today only compact does) | HC-16; moot once HC-18 lands |
| Headline cycled to Vendor value/h by a click | Right-click cycles; left-drag moves | HC-16; moot once HC-18 lands |
| Tooltip repeats the run panel | §6.6 | HC-16 |
| "»" header button means nothing without a hover | A word ("Pop out") or a clear icon | HC-16 |
| Ledger: the selected period is a greyed, disabled button | A selected look | FM-13 |
| Ledger: the Character/Account toggle floats alone | Into the period row, right-aligned | FM-13 |
| Ledger: dead space under 6 of 10 row slots | Totals follow the last used row | FM-13 |

### 9.2 Runs

- **Start a run I forgot to start:** "Start from 5 / 10 / 15 minutes ago", from a 15-minute in-memory ring of
  run-tracked totals. **HC-20.**
- **Automatic runs** (instances: start on entering, split on reset, stop on leaving): HC-2 (a).
- **Run housekeeping:** delete, rename, exclude from averages (one AFK-ruined run poisons a zone's average, and the
  Run board's comparison line). **HC-20.**
- **Loot log per run:** the record keeps the full item list (Farmer DESIGN §4.2); shown in the redesigned run
  summary, HC-15.
- **This spot against my usual:** the Run board's comparison line is the first piece; Farmer's Spot compare (FM-3)
  is the full view.

### 9.3 Ledger and money (Farmer)

- **Compared with the previous period:** "+12 % vs yesterday" beside Net; Yesterday / Last week buttons
  (LibGranaryDB `change`). Needs Daily history, which the Ledger requires anyway. **FM-13.**
- **Gold by character** with the account total (`hc:money.owned` at account scope, grouped by entity). **FM-13.**
- **Goals** with an ETA: FM-3 / HC-3, as tiles. **Market value from Auctionator:** FM-7.

### 9.4 Everyday comfort

- **Keybindings** (`Bindings.xml`): start/stop run, pause/resume, split, each board, mini mode, edit mode. **HC-23.**
- **`/hc help`** lists every subcommand, packs' included. **HC-23.**
- **Records as a toast or chat line** (`OnNewExtreme`), off by default: Farmer's Alerts (FM-3) and Character Stats'
  records.
- **Dungeon resets left this hour:** Farmer's Alerts (FM-3), after FM-5 probes the reset messages; the cap on Forever
  is unverified.

## 10. Build order

| Step | What | Size | Queue |
|---|---|---|---|
| M0 | Screenshot fixes that survive boards (tooltip, "»", Ledger look); CS-1 probes in the Diagnostics Probes tab | small | HC-16, FM-13, CS-1 |
| M1 | **LG-17**, LibGranaryDB r3: `DropCounter`, `removed = "keep"`, frozen data first in the budget; synced into Hard Counters | a library MINOR | LG-17 |
| M2 | **Readings API** with the `login` and `now` scopes and computed readings (§5) | 1–2 sessions | HC-17 |
| M3 | **Trackers, derived activation, history** (off by default, presets, freeze, Delete), Live only counters (§2, §3); sources' `feeds` | 2 sessions | HC-19 |
| M4 | **Basics** (§4): money and XP counters move into Hard Counters with the attributor hook; Farmer moves to trackers and readings | 1–2 sessions | HC-21, FM-14 |
| M5 | **Boards** with `[+]`, edit mode, styles, mini mode, visibility, presets and migration (§6) | 2–3 sessions | HC-18 |
| M6 | The Trackers window: history choices with the tips, sizes, frozen data, Delete, "Not loaded" (§7) | 1–2 sessions | HC-19 |
| later | Drag and drop (§7.1); boards as strings (§8) | 1–2 sessions | HC-22 |
| later | Character Stats phase 1, after CS-1's in-game answers | see its DESIGN | CS-n |
| later | Runs extras, keybindings, Ledger comparisons | | HC-20, HC-23, FM-13 |

The milestones were those of the v2 handoff (`HANDOFF_V2.md`, in the private development history). LG-17 comes first: it touches only the library, and history
choices must never ship without it (lowering history would delete data). Readings come before trackers and boards
because both name them; trackers and history come before boards because, with history off by default, every tile
depends on knowing which scopes a counter can serve.

## 11. Still open

1. ~~**Attributor timing** (§4)~~ **Settled 2026-11-15 (v2 M4): 5 seconds.** Farmer's attributors answer within
   their 2 s window (a held gain becomes "other" at its expiry check, 2.25 s after the change), so 5 s leaves room
   for a late chat line and a frame hitch, while a broken or missing answer costs at most 5 s of delay. Basics books
   what's left as `none`, never twice: `book` refuses more than it was handed (counted as over-booked).
2. **Size estimates** for trackers not yet on (§3.4): measured per counter once a few have history.
3. **Revisit after use:** the default tile scope (§5.3), Farmer's trackers starting off (§0.3), the comparison
   line's three-run threshold (§6.3).
