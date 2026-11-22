# Changelog

What changed for players, newest first. Alpha and beta versions may reset saved data; when one does, its entry says
so at the top. Developer notes (pack API changes) are at the end of an entry.

## 0.2.0-beta1 (2026-11-22)

The first beta, **still experimental**: things will change, and so may the pack API. Everything from the alpha, plus
a fifth folder, **Traveler**.

**Saved data:** kept. Your boards, runs and history from 0.1.0-alpha1 carry over. A later beta may still reset saved
data; if one does, its entry will say so at the top.

**Updating:** quit and restart the game after installing. The new Traveler folder doesn't load with a `/reload`.

### New
- **Hard Counters: Traveler**, a new pack (first edition): how far you travel and how. Distance on foot, mounted,
  swimming, in a travel form, by flight path and by boat, plus blinks, hearthstones and teleports, measured from
  your position 4 times a second, in fights too; a tile picks which ways of travel it adds up (On foot, Under my own
  power, Everything but teleports, Everything, or tick your own). Time moving, average and top speed (in yards a
  second or as % of run speed), Speed now, farthest without stopping, spacebar jumps, falls, time in the air,
  corpse runs, spirit healer visits, the distance to your corpse while a ghost, and flights taken, flown and the
  longest. Inside dungeons distance is an estimate, out of combat only. Ready-made **Trip** and **Flight log**
  boards. Its trackers start off: switch on *Distance* and *Flights* in the Trackers tab. A new addon folder:
  restart the game after updating (a `/reload` doesn't load it).
- Two more ways to draw a tile (Display, in a tile's menu while editing): **Odometer**, rolling digits for a
  total, and **Mix**, one bar split by kind with each part's share, for readings that count by kind.

### Fixes
- Per-hour numbers, board clocks and gold counts no longer stop when the saved history can't be written: they froze
  for the rest of the session while XP kept counting (gold per hour and time to level read "-"). History missed in
  such a session is still lost.
- The cause of that: storage upkeep failed once any saved total passed about 2.1 billion (gold in copper gets there),
  which switched history off for the session at every login. Fixed (LibGranaryDB r5).
- Percent tiles keep one decimal in combat ("5.2%"), as out of combat; they showed two ("5.20%") and the text
  jumped at every fight's start and end.
- The Hard Counters window's tabs show their whole name ("Character Stats", "Diagnostics"); longer names were cut
  short with "...".

### Developer notes
- Readings and counters take three more formatters: `distance` (yards), `speed` (yards a second) and `speedpct`
  (yards a second shown as a percentage of the 100% run speed, 7 yd/s).
- A reading's parameter can take a set of members instead of one (`param.multi`, with presets and a default): a
  tile then counts the members ticked in its menu ("Includes: ...").

## 0.1.0-alpha1 (2026-11-21)

The first experimental build: Hard Counters, Farmer, Character Stats and Diagnostics in one download.

**Saved data:** start fresh. Data from earlier private test builds is not guaranteed to carry over.

### Hard Counters
- Boards: on-screen panels of readings, each with its own clock (start, pause, reset). Ready-made boards to start
  from, or an empty one.
- Tiles: big number, row, bar toward a target, or gauge; total or per hour; this character or the whole account;
  a target of your own; a trend badge against your usual pace.
- Readings to start with: gold earned, gold owned, net gold, gold per hour, gold from or spent on a source, XP gained,
  XP this level, rested XP, time to level.
- Pick readings from lists, an item in your bags, something you just looted, or a faction.
- Runs: dungeons record themselves; any other stretch of play can be saved as a run.
- History off by default, one switch per tracker to keep day-by-day totals and records.
- Edit a board from its hover tab, or every board with Blizzard's Edit Mode.
- Opens from `/hc`, the minimap button and the game's AddOns menu.
- Its own icon, a gold number sign, on the minimap button and in the AddOn list.
- `/hc report`: a copyable report for bug reports, with no character names.

### Farmer
- The Ledger (`/hc ledger`): money in by source and out by sink, per day.
- Readings: items looted and their vendor value, best drop, reputation gained, "*item* looted", "*item* in bags",
  "*faction* rep" and "*faction* standing" (a bar toward the next standing).

### Character Stats
- Attributes, melee, ranged, spell and defence stats, weapon skills and Defense as readings, with a window of their
  own (`/hc stats`) and Caster, Melee, Hunter and Tank boards.
- In combat, stats the game hides from addons show their last value, marked *in combat*.

### Diagnostics
- On in alpha builds: log, live values, storage, game API checks (`/hc diag`).

### Developer notes
- Pack API version 1, experimental: `HardCounters:RegisterPack`, `RegisterTracker`, `RegisterReading`,
  `RegisterBoardPreset`, `RegisterWindow`, `RegisterSlash` and the rest in `docs/API.md`. It may change before the
  first beta.
