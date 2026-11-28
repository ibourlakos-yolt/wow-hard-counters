# Changelog

What changed for players, newest first. Alpha and beta versions may reset saved data; when one does, its entry says
so at the top. Developer notes (pack API changes) are at the end of an entry.

## Unreleased

### The window
- The Hard Counters window is bigger: a little more room inside, and everything in it (text included) drawn about 8%
  larger. If you had changed its scale in Options, your scale stays.
- One **Help** button at the top right replaces the three (help, tour, Grand tour). Its menu: Help for the open
  tab, Tutorial for the open tab, the Full tutorial, and the Guide. Tours are called tutorials now;
  `/hc tutorial <tab>` starts one tab's (`/hc tour` still works).
- **Ctrl+K** puts the cursor in the open tab's search box (the Explorer, Runs, Diagnostics). Out of combat only;
  Options, Windows turns it off.
- Right-click opens a menu in more places (the Help button, and more below).

### Boards on your HUD
- Two new tile sizes: **Big, half width** (a big number in one of two columns) and **Line, half width**. "Half
  width" is now called **Medium, half width**. Any two half-width tiles next to each other share a row, whatever
  their size.
- The board's title row is slimmer (8 px less), on a faint dark strip. A Big tile is only as tall as what it draws:
  without its small graph or comparison line it no longer leaves a gap.
- One colour family on every size: labels grey, numbers white (12 pt on Medium and Line tiles, 10 before), gold for
  the board's name and headings. A Big number too wide for its room steps down a size instead of being cut.
- The trend badge fits every number tile: an arrow on the smaller sizes, arrow and words on Big.
- **Look**, in the board's menu: its opacity, background colour and background opacity, the numbers' colour, and its
  scale. A board that fades (in combat, or until the mouse is over it) now shows at **half of its own opacity**
  (it was a fixed 35% or 30%).
- A tile's menu: **Colour** (its own, or the board's) and **Move to top** / **Move to bottom**.
- Pause, Resume and Reset on a board are **icons** (Options, Boards: "Board buttons as icons" puts the words back).
- Hovering a board shows **Hide** beside Edit: it takes the board off your HUD (it keeps counting) and says in chat how
  to bring it back. Right-click Move, Hide or Edit for the board's menu.
- Menus opened on the HUD no longer say "Only here": "(not on your HUD)", "Take this tile off the HUD".

### How a number is made
- **Alt+click a number on a board** on your HUD: a tooltip says what it counts, over when, how the number is worked out
  and anything that is an estimate. Any other click closes it. With Alt held, a right-click opens the tile's menu.
  The key is in Options, Boards ("Explain a number with").
- In the window: the **?** on a tile's card in the Boards tab, or "How it's made" in its menu and in the Explorer, opens
  the same as a small panel; a click outside or Escape closes it. The Explorer's tile details show it too.

### Runs (the word)
- **Stints are called runs again** (the tab, the board's Save as run, the Visibility rule Only during a run, the Options,
  `/hc runs` and `/hc run`; `/hc stints` and `/hc stint` still work). Nothing is renamed in your saved data.

### Runs: finding them
- The Runs tab finds runs with fields over the list instead of the tree: **Who**, **Where**, **When**, **Length**,
  **From** (a board, a board's Reset, a dungeon, started by hand) and **Counted** (a tracker or one of its numbers,
  runs with splits or with an item list); **Clear** puts them back. A new **From** column says where each came from.
  Runs saved before 0.5 read "Unknown" there.

### Right-click
- Right-click opens a menu on: tabs (help, tutorial, tab labels), column headings (sort), status switches, the
  Explorer's kinds, Overview rows, a board's clock buttons, the packs reminder and the "more boards" panel in the
  Boards tab, and on the HUD the Move, Hide and Edit tabs.

### Explorer
- The list on the left folds like the Auction House's: **Boards** (with Ready-made boards under it), **Tiles** (per
  board, and Displays), **Readings**, **Trackers**, then one entry per other character. A + opens one; what you open
  is remembered. Right-click a kind for Open all / Close all.
- The New board... button left the Explorer (the Boards tab has it; a right-click on Boards in the Explorer too).
- Details say more: a board's rules are switches you can click (in combat, in instances, faded until hovered), with
  its look and what it was made from; a ready-made board shows each tile's size and its value now; a reading says
  what it is counted from, how it can show and which displays fit.

### Report a problem
- A new tab along the bottom of the Hard Counters window, **Report a problem**, always there, with or without
  Diagnostics. It replaces the separate report window: `/hc report`, the Overview's **Report...** buttons and
  Diagnostics' **Report** button open it.
- Write a line on what went wrong (optional): it goes in the report as you wrote it.
- The same three boxes as before (your class and addon list ticked, your name not), what the report holds, and the
  text itself, already selected: **Select all** (or a right-click on the text), then Ctrl+C. It says how long the
  report is and when it had to be shortened.
- With Diagnostics loaded: **Run the checks first**, **Mark the log now** and **Open Diagnostics** are right there.
  Without it, the tab says the report is shorter and takes you to the Packs tab.
- **Copy as text** on a run, and **Copy** and **Copy all** on Diagnostics' probes, now show the text in the details
  pane below the list, selected, with **Back to details**; no more separate copy window.

### Class boards
- **Character Stats' ready-made boards are by class and role now:** Warrior (Tank), Warrior (Melee damage), Paladin
  (Healer), Paladin (Tank), Paladin (Melee damage), Hunter (Ranged), Rogue (Melee damage), Priest (Healer), Priest
  (Caster), Shaman (Healer), Shaman (Caster), Shaman (Melee damage), Mage (Caster), Warlock (Caster), Druid (Healer),
  Druid (Tank), Druid (Melee damage), Druid (Caster). Each holds the stats that class watches in that role.
- **They replace the role boards** (Tank (physical), Tank (spell), Melee DPS, Ranged DPS, Caster DPS, Healer (direct),
  Healer (over time)), **the one-per-class boards** and **the schools boards** ("Mage: schools"). Boards you already
  made from them are kept, tiles and all; they are just no longer offered.
- **Tank (spell) has no successor:** resistance is a matter of the fight's gear, not of a role. A Resistance tile is
  still one + Tile away (Character Stats, Resistances).
- New board... lists them under **Your class** and **Other classes**; in Other classes each class has a title row.
  The Explorer's Group column shows the class.
- The tutorial's first-board step names your class's boards. A class with several roles gets a button that asks
  which one ("Make my Druid board..."). A class board you made in 0.4 counts: the step shows it instead of offering
  another.
- Character Stats window: right-click a stat for **Add tile...** (put it on a board) and **Its tracker** (its section
  in the Explorer).

### Packs tab
- Hover a pack for its whole description, its state and its version; the version also shows after its name. One of
  the packs that come with Hard Counters whose version doesn't match says so, in amber.
- A pack that can't load says what it needs ("Can't load: needs ...").
- Turning off a pack whose numbers are on your tiles asks first: those tiles read "needs ..." until it is back.
- "trackers counting" instead of "trackers on": a tracker goes on by itself when you place one of its tiles.
- The tab says your ticks are for this character.
- Right-click a pack, or click its **...**: Turn on or off, **Its trackers** (the Explorer, searched by the pack),
  **Its ready-made boards**.
- Diagnostics is listed last, under **Tools**: it adds no numbers.

Developer notes: `HC:RegisterBoardPreset` takes an optional `role` ("tank", "healer", "melee", "caster", "ranged");
`category = "role"` is still accepted and listed under Roles, after the classes. New for a pack's own window
(`HC:Supports("packMenus")`): `HC:ShowMenu(anchor, items)`, `HC:AddTile(readingId, anchor, arg)`,
`HC:ShowTracker(trackerId)`.

## 0.4.0-beta2 (2026-11-27)

A beta, **still experimental**. One fix to 0.4.0-beta1.

**Saved data:** kept. **Updating:** `/reload` is enough after 0.4.0-beta1 (no new addon files); from an older
version, restart the game client.

### Fixed
- The Boards tab said "Only gold and experience are counted: no pack is on", and Overview listed "No packs chosen",
  while packs were loaded: only a tick in the Packs tab counted. Packs installed through the game's AddOns list now
  count too; the reminder shows only when no pack is loaded.

## 0.4.0-beta1 (2026-11-26)

A beta, **still experimental**. The Hard Counters window is reorganised: new tab names, two new tabs, everything you
can count in one Explorer, and history that comes on with your tiles.

**Saved data:** kept (boards, tiles, trackers, runs and settings all carry over; nothing is renamed on disk).
**Updating:** **restart the game client** (new addon files; `/reload` is not enough). **History:** at the first login
on this version, every tracker that one of your tiles reads is switched on, and gets daily history unless you chose
its history yourself; the chat line names them.

### New tab names
- **Boards** is the old **Overview** tab: your boards as panels, their tiles as cards.
- **Explorer** replaces the old **Boards** and **Trackers** tabs: your boards and tiles, the ready-made boards, every
  reading, the five displays (number, bar, gauge, odometer, mix) and the trackers, in one browser. Pick a kind on the
  left, a row in the middle; its details and actions are below. **Drag the bar between the list and the details** to
  give either more room (double-click: back to the usual split). `/hc trackers` opens it on Trackers.
- **Stints** is the old **Runs** tab ("run" was easy to confuse with a board's timer and the session). It is a browser
  now: click a stint and its numbers, counts, loot, best and splits are below the list (no separate card window), with
  **Rename...**, **Copy as text** and **Delete**. `/hc stint start | stop | pause | resume | split`; `/hc run` still
  works.
- The **Tutorial** button is now **Grand tour**; **Help** and **Tab tour** carry the open tab's name ("Boards help",
  "Boards tour"). The Guide tab's own "Run the tutorial" button is gone.

### New
- **Overview** (a tab along the bottom): where everything stands for this character (packs, trackers, boards on your
  HUD, the open stint, this session, how much history is kept, Diagnostics) and, first, anything that **needs a
  look**, each with the click that fixes it.
- **Options** (a tab along the bottom): the `/hc options` panel inside the window (General, History, Profiles). No
  separate window any more.
- **A line on top of every tab** says what the tab is for.
- **History options** (Options ▸ History): how many **stints are kept** (100 to 2000; 500 by default, was 200), the
  **days of daily totals** a tracker keeps when you didn't choose (14 to 365; 90 by default, was 14), how long
  **hours** and **weeks** are kept for Detailed history, and **when your day ends** (midnight local time by default;
  pick 04:00 if you play late; takes effect at the next reload). Older days and weeks still count in their month,
  year and lifetime totals.
- **Buttons and switches look different.** A red-and-gold button does something; a dark pill with a lamp is a switch
  that shows a state (green on, grey off, amber needs a look), such as **On HUD / Only here** and **Counting / Not
  counting**. Every button and switch has a tooltip.
- **The minimap button's tooltip is live:** this session, the open stint, your boards on the HUD with their first
  tiles, today's net gold, what needs a look; hold **Shift** for every board and tile. It updates while you hover.
- **Boards tab:** a board on its own timer has **Pause / Start** and **Reset** on its panel, and its clock in the
  heading; a bar, gauge or mix tile shows its strip on its card, with the display named; a panel at the end of the
  list says how to add more boards; a player with no pack chosen is reminded.
- **Automatic field notes** on test versions (alpha, beta) and with Diagnostics loaded: at a login, a reload,
  entering or leaving an instance, a level gained, an error and a logout, the moment is noted with a few counts
  (never a value or a name); `/hc report` carries the last 40. With Diagnostics loaded, its probes also run after a
  level, on leaving an instance and after an error, and the first error of a session saves the log. Options ▸
  General ▸ Diagnostics turns it off.

### Changed
- **A new character starts with no boards.** New board... (Boards tab) makes the first one.
- **A pack's trackers go on with their tiles.** Adding a tile, or making a board from a ready-made one, switches its
  tracker on (no question asked) with daily history, unless you chose that tracker's history yourself. The Packs
  tab's **Use these packs** button is gone: a tick is the choice.
- **Hovering a board that is not on your HUD** (Explorer) shows it only faintly where it would be, without the
  flash.
- **All on HUD, All off HUD and Edit all** are gone from the boards list (`/hc edit` and ctrl-click on the minimap
  button still edit every board).
- Profiles are a tab of the options instead of a page of their own in the game's AddOns options.

### Fixed
- The board panels' borders in the Boards tab could vanish while scrolling and the gaps between panels looked uneven
  at small UI scales: the borders are now one screen pixel at any scale.

### For pack authors
- `HardCounters:RegisterWindow` takes `about` (one line on what happens in the tab, shown in the header).
- New aliases: `StartStint`, `PauseStint`, `ResumeStint`, `SplitStint`, `StopStint`, `DiscardStint`, `GetStint`,
  `Stints`, `GetStintRecord`, `DeleteStint`, `RenameStint` (the `*Run` names keep working; `Supports("stints")`).

## 0.3.0-beta3 (2026-11-25)

A beta, **still experimental**. The Fishing basket counts your casts too.

**Saved data:** kept. **Updating:** `/reload` is enough (no new addon files). A Fishing basket board you already made
keeps its tiles: make a new one from New board... ▸ Activity ▸ Fishing basket for the new tiles, or add them with
**+ Tile** (Farming ▸ Fishing).

### New
- **Casts on the Fishing basket.** Every Fishing cast is counted, caught or not: **Fishing casts** (and per hour),
  **Got away** (clicked too early or too late, nothing bit, or the cast was broken), and the **Catch rate**.
- **How long a bite takes.** For every catch, the seconds from your cast to your click: **Average wait for a bite**,
  **Longest wait for a bite**, and **Time waiting for bites** (all of them added up).

## 0.3.0-beta2 (2026-11-25)

A beta, **still experimental**. A fishing board for Farmer, and the five-second rule fixed.

**Saved data:** kept. **Updating:** `/reload` is enough (no new addon files).

### New
- **The Fishing basket** (Farmer; New board... ▸ Activity ▸ **Fishing basket**). Counts what you fish up on the
  board's timer (**Reset** empties the basket): every catch (fish, junk, clams, chests), per hour, a bar of each
  catch with its **count and share**, and the **fish in your bags** with theirs. Turn on the new **Fishing** tracker
  (Trackers tab, Farming) for it to count. A catch is loot from a fishing bobber, as the game reports it; opening a
  clam or chest you fished is not another catch.
- Two readings for any board: **Fish caught** (all, or one catch; per hour too) and **Fish in bags** (every item you
  have fished on this character, or one).

### Fixed
- **The five-second rule** (Character Stats) started on any spell the game didn't give a cost for, so **Fishing**,
  professions and other free casts emptied the bar. It now starts only when you really spend mana: your spell went
  off and your mana fell (either may come first). Free spells, a wand, mounts, food, potions and clearcast spells
  leave the bar full. Where your mana is hidden in combat, the spell's listed mana cost decides, so a clearcast spell
  may still start it there. The rule starts when the cast completes (a channel: when it starts), as in the game.

### For pack authors
- `HC:CounterMembers(counterId, dim)`: the members of a small dimension this character has counted.
- A reading's `mixList = true`: its mix tile lists each part on its own line with amount and share.

## 0.3.0-beta1 (2026-11-25)

A beta, **still experimental**. Nothing lands on your screen unasked any more: boards are made in the window and you
choose what goes on your HUD. The window gains a Packs tab, and Help and a short tour on every tab. Character Stats
reads regeneration, the five-second rule and spell schools side by side.

**Saved data:** kept. One change you will see: tiles that sat under "Window only" in the Overview tab are now on a
board called **Unsorted** (not on your HUD, as before); a board called "Run" made from the ready-made board is now
called "Farming".

**Updating:** restart the game (two new addon files: `/reload` is not enough).

### New
- **Nothing lands on your screen unasked.** A new board is made in the Hard Counters window and stays there, "Only
  here", until you put it on your HUD: tick **Put it on my HUD** in the New board dialog, use the board's **On HUD**
  switch in the Overview tab, or `/hc board <name>`. A new character starts with its Leveling board in the window, not
  on screen. Boards you already have on screen stay there.
- **Make boards and tiles in the Overview tab.** **New board...** at the top; on each board's panel **+ Tile** (pick a
  number by tracker) and a switch that reads **On HUD** or **Only here**.
- **A tile can stay off the HUD while its board is on it.** In Overview, a card's menu has **On HUD**; on a board,
  a tile's menu has **Hide from HUD**. The tile keeps counting and stays on its board in the window (dashed card).
- **Move a board without editing it.** Hover a board on your HUD: a **Move** tab shows above its left corner (drag
  it), **Edit** stays above its right corner. Or hold **Ctrl** and drag the board itself; Options, Boards chooses
  Shift or Alt instead, or switches the key off. Boards stay click-through the rest of the time.
- **The Packs tab.** Choose the packs you want inside the window. A tick counts at once: the game is told, and
  **Reload now** appears when a pack has to be loaded or unloaded (`/reload` does the same). **Use these packs**
  switches on the trackers of the packs you kept, with history off. The tab says what history is and where to turn
  it on. The tutorial has a step for it.
- **Help and Tab tour on every tab.** At the top of the window, beside Tutorial: **Help** is one page about the open
  tab (what it is, what you can do there, how it changes your play), **Tab tour** a few steps through that tab
  alone. Farmer's Ledger, Character Stats and Diagnostics have theirs too. `/hc tour <tab>` does the same.
- **Character Stats: regeneration.** Health regen out of combat and in combat (per 5 seconds, and per second for
  boards), mana per second casting and not casting beside the per-5 readings, mana regen from spirit. Mana regen
  now counts Blessing of Wisdom and Mana Spring, which the game leaves out of its own figure.
- **Character Stats: the five-second rule.** A reading that counts the five seconds after a spell that cost mana,
  until spirit regeneration is back; as a bar it fills while you wait. On every ready-made board of a class that
  casts.
- **Character Stats: more for casters and healers.** Healing crit, spell haste and melee haste as readings. The
  class boards show schools side by side: a warlock's shadow and fire, a mage's fire, frost and arcane, each with
  damage and crit; a priest's holy and shadow; a shaman's nature and fire; a druid's nature and arcane.
- **Character Stats: a schools board per class.** New board..., Your class: "<Class>: schools" has a damage and a crit
  tile for every magic school your class uses. Hunters (arcane, nature, fire, frost) and rogues (nature) get one
  too, and Spell damage and Spell crit now read for them instead of "n/a". The numbers are what the game reports
  per school; a hunter or rogue will often see 0 damage there, since their abilities run on attack power.

### Changed
- "Window only" is gone: every tile is on a board. Deleting a board deletes its tiles (the question says so);
  "Remove from board" became **Hide from HUD** and **Delete tile**.
- A board's status reads **On HUD** or **Only here** (it was "Shown" / "Off"), in the Boards and Overview tabs and in
  `/hc board`. The Boards tab's buttons are Put on HUD / Take off HUD, All on HUD / All off HUD.
- The ready-made board "Run" is called **Farming** ("run" already means a saved stretch of play).
- **Start from** in the New board dialog is a dropdown that looks like one.
- Adding a tile to a board from the Trackers tab no longer puts that board on your screen.
- **`/hc report` now includes your class and your addon list unless you untick them** (both boxes start ticked;
  they were off). Your character's name and realm stay out unless you tick that box. The report window, this
  README and the CurseForge page say so. Why: a tester's report is hard to read without knowing the class, and a
  conflict needs the addon list.
- The Guide and the tutorial say all of the above; the tutorial has 11 steps.

### Not checked in game yet
- Turning packs on and off from the Packs tab uses the game's AddOn calls for one character, and Reload now calls
  the game's reload from our button: if the game refuses, the tab says so and the AddOns list still works.
- The five-second rule reads a spell's mana cost from the game; where it can't, any spell you cast starts it.
- Health regen, mana from spirit and haste use calls this client documents; a call that is missing shows "n/a".
- Per-school spell hit is not offered: the game reports one spell hit number, and the per-school part comes from
  talents.

### For testers
- Play as usual (one fight is enough), then `/hc report`, copy the text and send it to whoever asked. With
  Diagnostics on, the report carries this build's checks of the game's API: spell schools, talents, regeneration,
  mana-per-5 buffs, item stat names.

### For pack authors
- `HC:RegisterWindowHelp(id, def)`: the Help page and tour of your window (docs/API.md §9).
- `HC:ReadingsChanged()` and `HC:Supports("readingsChanged")`: ask boards to redraw for a live reading that moves
  with no event (a timer's progress).

## 0.2.4-beta1 (2026-11-25)

A beta, **still experimental**: Hard Counters now shows you around. A tutorial opens at your first login, with a
first board for your class, and the window gains a Guide tab, the manual inside the game.

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
