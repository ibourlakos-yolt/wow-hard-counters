# Changelog

What changed for players, newest first. Alpha versions may reset saved data; when one does, its entry says so at
the top. Developer notes (pack API changes) are at the end of an entry.

## Unreleased

<!-- Renamed to "## <version> (<date>)" at the next cut: the release job looks for "## <version>". -->

### Fixes
- Percent tiles keep one decimal in combat ("5.2%"), as out of combat; they showed two ("5.20%") and the text
  jumped at every fight's start and end.

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
