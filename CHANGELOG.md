# Changelog

What changed for players, newest first. Alpha and beta versions may reset saved data; when one does, its entry says
so at the top. Developer notes (pack API changes) are at the end of an entry.

## Unreleased

**Saved data:** kept.

**Updating:** restart the game (a new addon file: `/reload` is not enough).

### New
- **A tutorial.** The first time you log in with this version a short tour opens, once per account: what a
  reading, a tile and a board are; the boards on your screen (yours flashes); a **first board for your class**, made
  with one click (it needs the Character Stats pack); then the Hard Counters window, opened for you on each tab in
  turn: Overview, Boards, Trackers, Runs, the packs' tabs and the new Guide. Back and Next, close it whenever you
  like. It waits for the end of a fight. Players who already use Hard Counters get it once too.
- **Run it again** with the **Tutorial** button at the top of the Hard Counters window (on every tab), the Guide
  tab's **Run the tutorial** button, or `/hc tutorial`.
- **The Guide tab**, the fifth icon tab of the window: the manual, in the game. Pages: Start here, Concepts, Boards,
  Tiles, The window, Trackers and history, Runs, Packs, Commands, For addon authors. The Commands page lists every
  `/hc` command that is loaded right now, the packs' too, with examples. `/hc guide` opens it; `/hc guide commands`
  goes straight to a page.

### Changed
- The tutorial replaces the one-page welcome a new character got. `/hc welcome` still works and opens the tour. A
  new character on an account that has seen the tour gets its Leveling board and one chat line, as before.

### Developer notes
- A pack's `/hc` subcommand registered with a help line (`HC:RegisterSlash(name, fn, help, owner)`) is listed on the
  Guide tab's Commands page with its owner. API §8, §9.

## 0.2.3-beta1 (2026-11-24)

A beta, **still experimental**: gold and XP become the Hard Counters Basic pack, related numbers merge into one
with a choice on the tile, Character Stats gains the stats it lacked and a board for every role and class, the main
window's tabs swap places, and names say what they count.

**Saved data:** kept. Tiles on "Gold from ...", "Spent on ...", "... looted" and "... rep" move to the readings
those were merged into, with the same choice, calc, look and name.

**Updating:** `/reload` is enough (no new addon files).

### New
- **Hard Counters Basic.** The gold and XP numbers that come with Hard Counters are now a pack of their own name,
  always on, listed with the other packs. Its trackers are called **Gold** and **Experience**. New reading:
  **Level**.
- **Gold out:** all the gold that left this character (repairs, purchases, training, flights, mail, ...), as a
  total or per hour.
- **Pick sources on the tile.** Gold in, Gold out and XP gained count everything by default; a tile's menu picks
  which sources (loot and quests only, say). The sources come from the Farmer pack; without it they are all
  "Unknown". Counting everything, Gold/h keeps its recent rate and trend.
- **Items looted** and **Reputation gained** count everything by default, or one item or faction picked on the
  tile. "... looted" and "... rep" are gone from the lists: these replace them.
- **Character Stats:** main-hand, off-hand and ranged DPS and speed, spell penetration, resistances (one tile per
  school), lowest durability, average item level, and a weapon skill of your choice (any weapon skill or Defense).
  Spell damage and spell crit can show one school; without one they show your best school, as before. New trackers
  **Resistances** and **Gear**.
- **Boards for every role and class** (Character Stats): Tank (physical), Tank (spell), Melee DPS, Ranged DPS,
  Caster DPS, Healer (direct), Healer (over time), and one board per class.
- **Traveler's speeds** switch between yd/s and % of run speed in the tile's menu (**Units**), so the % readings no
  longer fill the lists.

### Changed
- **The Hard Counters window's tabs swap places.** Overview, Boards, Trackers and Runs are icon tabs down the right
  edge; the packs' windows and Diagnostics are the tabs along the bottom (the Tab labels option now applies to
  them). The window's title names the open tab ("Hard Counters: Boards").
- **The New board dialog groups the ready-made boards:** Activity, Roles, Your class, Other classes, then the rest,
  then your own presets.
- **Clearer names** (your tiles keep working): Gold in (was Gold earned), Loot vendor value (was Vendor value), Best
  drop (vendor price), Standing progress: *faction*, In bags: *item*, Average speed (moving), Instant travel (was
  Teleports and blinks), Spirit healer resurrections, Distance to corpse, Melee crit, Hit (melee and ranged), Mana
  regen (casting) and (not casting), Armor, Block chance, and the Defense tracker.
- **Character Stats:** a fist weapon now reads your Unarmed skill when you have no Fist Weapons skill. Its window
  only scrolls when the rows you use don't fit.

### Developer notes
- Readings: `param.optional` (one member or none: none reads the whole total), `param.anyLabel`, `param.anyTitle`,
  `param.members` for a single enum, `param.type = "skill"` with `param.filter`, `hidden`, `foldInto` / `foldArg`,
  `unitOf` / `unitLabel`, `pickTitle`, formatters `seconds` and `decimal`. API §5.1.
- `RegisterBoardPreset` takes `category` (`"activity"`, `"role"`, `"class"`), `class` and `tip`. API §7.
- A pack's window is now a tab along the bottom of the Hard Counters window (API §9).

## 0.2.2-beta2 (2026-11-24)

A small beta, **still experimental**: a clearer `/hc report`, so testers can send everything in one paste.

**Saved data:** kept; nothing in it changes.

**Updating:** `/reload` is enough (no new files).

### New
- **A clearer `/hc report`.** The report window now says what the report is for and lists what is in it before you
  copy it. Three boxes, off each time it opens: include your character's name (with the realm), your class, your
  addon list. With **Hard Counters: Diagnostics** enabled, the report carries its checks of the game's API and its
  travel counts (types, counts and game IDs; no positions, names or chat), so one paste is all a tester sends. The
  Diagnostics console's Report button opens the same window.

## 0.2.2-beta1 (2026-11-24)

The third beta, **still experimental**: every character gets boards of its own (copy one from another character
in two clicks), a new character starts with the Leveling board and a short welcome, and Overview groups your
tiles by board.

**Saved data:** kept. Boards become each character's own: every character that ran Hard Counters before gets a copy
of the boards they all shared, the first time it logs in, timers included. The Overview tab's sections are gone
(see below); your tiles don't change. Your presets stay shared by all your characters.

**Updating:** quit and restart the game after installing (new files; `/reload` is not enough).

### New
- **Each character has its own boards.** What you change on one character's boards no longer changes another's.
- **Copy another character's board:** New board... > Start from > Copy of a board lists your other characters'
  boards (and the boards your characters shared before this version); the Boards tab has an **Other characters**
  list with **Copy to this character...**. The copy is this character's own, with its own timer: change it as you
  like.
- **A new character starts with the Leveling board** in front of it (XP/h, the XP bar, time to level, rested XP,
  gold), instead of the Pocket board. The first new character on your account also gets a short **welcome**: what
  the Hard Counters window holds (Overview, Boards, Trackers, Runs) and how to copy boards; later new characters
  get one chat line. `/hc welcome` shows it again.

### Changed
- **Overview groups your tiles by board.** Each board is a framed panel with its name, its status as in the Boards
  tab (Shown, Off, Hidden...) and its tiles in the board's order; an empty board shows too. Click a board's header
  for that board's actions, as in the Boards tab. Tiles on no board come last under **Window only**, with dashed
  borders. Each card now says its scope (board timer, session, today...) instead of where it is. The sections of
  0.2.1-beta1 are gone: they were named after a board once and then fell out of step with it. Search finds a tile
  by its name or its board's.

## 0.2.1-beta1 (2026-11-23)

The second beta, **still experimental**: the Hard Counters window rebuilt in the spirit of the Auction House, with
Overview (all your tiles) and Boards (every board, easy to find) as its first tabs.

**Saved data:** kept. The first time you log in, your boards' tiles move into your tile collection (the new
Overview tab); the boards look and count exactly as before.

**Updating:** quit and restart the game after installing (new files; `/reload` is not enough).

### New
- **Overview**, the first tab of the Hard Counters window: all your tiles in one place, as cards with their number
  now, grouped in sections (one per board to start with; rename them, make your own) and searchable. Each says
  where it is: "On HUD: Leveling" or "Window only". Click one to edit it (the same choices as on a board), put it on
  a board or move it to another, take it off the HUD, change its section or delete it. **Add tile** picks a number
  from the Trackers tab and adds it here.
- **Boards**, the second tab: every board with its status in words (Shown; Off; Hidden, naming the rule: in
  combat, in instances, only during runs; Off screen? or Tiny? when it may be hard to find), its tiles and mini
  mode. **Hover a board's row and that board shows and flashes** on screen, above the window, until you move away.
  Buttons: Show or Hide, **Show now** (for 20 seconds, whatever its rules), Edit on screen, **Reset position**
  (back to the centre at its normal size), Duplicate, **Save as preset**, Delete; at the top New board..., Show all,
  Hide all, Edit all. The Presets list groups Hard Counters', each pack's and **your own presets**: make a board
  from one, rename or delete yours.
- **The New board dialog**: every way to make a board opens it (the Boards tab, a board's +, the minimap button's
  menu, Options, `/hc board new`). Name it (required, 24 letters at most, and **no two boards share a name**, so
  `/hc board <name>` always finds the right one), start it from a preset, one of yours, an empty board or a copy
  of another board (with tiles of its own), and choose when it shows. It appears at the centre of the screen with a
  flash. `/hc board new <name>` still makes one straight away.
- **Diagnostics: a probes browser** (for testers who help with the game's APIs). The Probes view lists every
  probe by kind (functions, events, client strings, samplers) with the feature it serves and its status (ok,
  missing, error, changed since the last run, secret, never fired, not run yet), filters by both, and shows what
  each kept. Run one or all, Copy one or all (to paste for us), Clear history.

### Fixed
- **The run summary card opened behind the Hard Counters window.** Clicking a run in the Runs tab opened its card
  under the window, so it looked as if nothing happened. The card now opens on top, and comes back on top when you
  click it.
- **Recent rates went negative after Reset.** Resetting a board's timer while it ran could leave its recent rates
  (e.g. "XP/h recent") hugely negative, with a trend like "1087% slower", for hours. Reset now starts them from
  zero, and boards already showing a negative rate correct themselves on their own.

### Changed
- **A board in mini mode names what it shows** ("Gold/h 12g 40s/h 0:42"): a fresh Pocket board used to read only
  "- 0:09".
- **The Hard Counters window is one fixed size.** It no longer resizes, and it stays the same size on every tab
  (a little wider than before, for the new Trackers tab). A tab with more than fits scrolls. A size you dragged
  before is forgotten, and the "Reset its size" option is gone. Windows of their own and popups still resize.
- **New tabs in the Hard Counters window.** Hard Counters' own tabs (Trackers, Runs) stay along the bottom, now with
  icons; Options ▸ Windows ▸ **Tab labels** shows icon and title, the title only, or the icon only. The packs'
  windows (Ledger, Character Stats) and Diagnostics move to **icon tabs down the right edge**, like the profession
  window's; hover one for its name. The window can no longer be dragged so far that its tabs leave the screen.
- **The Trackers tab is rebuilt**, in the spirit of the Auction House: categories on the left (Basics, Farming,
  Travel, Character, and "Not loaded" for data nothing uses), a search box and a **Filters** menu (on, off, with
  history, used by this character, per pack), a list you can sort by name, on, history or size, and below it the
  selected tracker's numbers, each with **Add tile**. The buttons at the bottom follow the selection: **Turn on** or
  **off**, **History...** (keep history, how much and how long, delete it) and **Delete data**. Right-click a
  tracker for the same. Trackers your character has no use for show grey.
- **A tile you take off a board is no longer lost.** A board's tile menu says **Remove from board**: the tile stays
  in the Overview tab (Window only), from where you can put it on a board again, its size kept. Deleting a board
  keeps its tiles there too. Off a board a tile can't use the board's timer, so it counts the session instead.
  `/hc board reset` still starts from nothing.
- **Two boards made from the same preset in one session** no longer share their tiles' extras (until a `/reload`,
  a trend badge switched on one board also showed on the other).
- **The minimap button's right-click menu** reads New board..., Open Boards tab, Edit every board, Options.
  Options ▸ Boards no longer lists a Show and a mini switch per board (they are in the Boards tab), and the Trackers
  tab's "Edit boards" button moved to the Boards tab ("Edit all"). Renaming a board can't take another board's name.

### Developer notes
- `HC:RegisterWindow` takes an `icon` (a texture path or file id): a pack's window is now an icon tab down the
  right edge of the Hard Counters window, with its `title` as the tooltip. The window is a design size (780 × 640);
  a `minHeight` taller than its body makes your tab scroll instead of growing the window. API §9.

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
