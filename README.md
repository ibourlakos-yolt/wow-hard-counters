# Hard Counters

**Put any number you care about on your screen.** Gold per hour, XP to level, how many Linen Cloth you've looted, your
reputation toward the next standing, your crit chance: pick it, drop it on a board, done. History, records and rates
are there when you want them and never in the way when you don't.

For **World of Warcraft: Forever** (Interface 16001).

> **Experimental (beta).** An early build for friends and curious players. Things will change, and a new beta may
> reset saved data (its changelog says so when one does). Please report what breaks (see
> [Reporting a problem](#reporting-a-problem)).

## What you get

One download, five addon folders. Choose the packs you want in the window's **Packs** tab (or the game's AddOns list).

| Folder | What it does |
|---|---|
| **Hard Counters** | The engine and the boards. Comes with **Hard Counters Basic**, always on: gold in and gold out (by source, if you like), net gold, gold owned, gold per hour, XP gained, XP this level, rested XP, time to level, your level. Ready-made Pocket, Leveling and Farming boards. |
| **Hard Counters: Farmer** | Counts what you farm: a money Ledger by source (loot, vendor, quests, mail, ...), items looted (all, or one item) and their vendor value, your best drop, reputation gained (all, or one faction), "In bags: *item*" and "Standing progress: *faction*", and your fishing: each catch's count and share, the fish in your bags, casts, the ones that got away, catch rate and the wait for a bite, on a ready-made Fishing basket board. |
| **Hard Counters: Character Stats** | Your character sheet as readings: attributes, melee, ranged, spell and defense stats, weapon damage, speed and skills, resistances, durability and item level. Ready-made boards for every class, one for each role it can play: Warrior (Tank), Druid (Healer), ... |
| **Hard Counters: Traveler** | Counts how you travel: distance on foot, mounted, swimming, by flight path and by boat, instant travel such as blinks and teleports (each tile picks which), time moving, average and top speed (in yd/s or % of run speed), speed now (in combat too), jumps, falls, time in the air, corpse runs and flights. Ready-made Trip and Flight log boards. |
| **Hard Counters: Diagnostics** | A console for finding problems: log, live values, storage use, game API checks. On in alpha and beta builds so reports are useful; untick it in the Packs tab if you don't want it. |

## Getting started

1. Install through the CurseForge app (set this addon's release type to **Beta**, or the app won't offer it), or
   unzip the download into `World of Warcraft\_forever_\Interface\AddOns`. After installing or updating, restart
   the game: a new addon folder doesn't load with a `/reload`.
2. Log in. A short **tutorial** opens: the boards on your screen, a first board for your class, then the Hard
   Counters window tab by tab. Close it whenever you like; `/hc tutorial` or the window's **Help** button (Full
   tutorial) runs it again.
   A new character starts with no boards: the **Boards** tab's *New board...* makes the first one.
3. Open Hard Counters with **`/hc`**, the **minimap button**, or the game's **AddOns menu**. Its **Guide** tab is the
   manual: the concepts, boards and tiles, history, stints, the packs and every command. The **Overview** tab (along
   the bottom) says where everything stands, and what needs a look; **Options** sits beside it.

**Boards** are the panels that stay on screen while you play. Each one holds tiles, and each tile shows one reading.

- **Add a board:** right-click the minimap button, then *New board* (blank or from a ready-made one).
- **Edit a board:** hover it and click its *Edit* tab, or open Blizzard's Edit Mode to edit them all.
  - `+` adds a reading: pick from the list, an item from your bags, a recent loot or a faction.
  - Right-click a tile to change it: big number, row, **bar toward a target**, **gauge**, total or per hour,
    character or whole account, or a target of your own.
- **The board's clock:** start, pause and reset the board's timer; a tile can follow the board (this session, today,
  this stint...). Dungeons record themselves as **stints**; any other stretch of play can be saved as one.
- **History comes with your tiles.** Placing a tile switches its tracker on, with daily totals (90 days by default),
  unless you chose that tracker's history yourself. The **Explorer** tab lists every tracker with what it keeps and
  what it takes on disk; **Options ▸ History** sets how long days, hours and weeks are kept, how many stints are
  kept, and when your day ends.

### Commands

| Command | |
|---|---|
| `/hc` | Open the Hard Counters window |
| `/hc tutorial` | The full tutorial, from its first step; `/hc tutorial <tab>` that tab's own |
| `/hc guide` | The Guide tab (`/hc guide commands`: straight to a page) |
| `/hc boards`, `/hc explorer`, `/hc stints`, `/hc overview`, `/hc options` | Those tabs (`/hc trackers`: the Explorer on Trackers) |
| `/hc board` | List your boards; `/hc board <name>` puts one on your HUD or takes it off; `/hc board new` makes one |
| `/hc stint start [label]`, `/hc stint stop` | Record a stint by hand (`/hc run` still works) |
| `/hc ledger` | Farmer's money Ledger |
| `/hc stats` | The Character Stats window |
| `/hc edit` | Edit every board |
| `/hc report` | The **Report a problem** tab: a report to copy and paste for bug reports, with what is in it and what to include |
| `/hc diag` | The Diagnostics console |
| `/hc help` | Every command (the Guide tab's Commands page lists them too, with examples) |

## Good to know

- **Combat.** WoW: Forever hides many character stats from addons during combat. Single-value stats keep updating;
  the rest show their last value, marked *in combat*, until the fight ends.
- **Nothing leaves your computer.** Addons have no network access. The **Report a problem** tab (along the bottom of
  the Hard Counters window, or `/hc report`) only shows text for you to copy, with a list of what is in it.
- **What a report holds.** Versions, error and warning counts, which packs are loaded, storage sizes and, with
  Diagnostics on, its checks of the game's API (types, counts and game IDs: no amounts, no positions, no chat). It
  also holds **your character's class and the list of addons you have installed, unless you untick those two
  boxes** in the Report a problem tab, your character's name and realm **only if you tick that box**, and the line
  on what went wrong if you write one. Whatever you paste into a public bug report is public.
- **Saved data** lives in `HardCountersDB` and `HardCountersSettings` (WTF folder). During the beta a new version may
  reset it; the changelog will say so.
- **The packs' API is experimental.** Other authors can build packs on Hard Counters, but the API may still change.

## Reporting a problem

1. Open the **Report a problem** tab (along the bottom of the Hard Counters window, or `/hc report`), say in a line
   what went wrong if you like, then **Select all** and Ctrl+C. With **Hard Counters: Diagnostics** enabled the
   report also carries its checks of the game's API, which helps most (**Run the checks first** makes them fresh).
2. Open a bug report on GitHub ([new bug report](https://github.com/ibourlakos-yolt/wow-hard-counters/issues/new?template=bug.yml)) and paste it into the form, with what you did
   and what you expected.
3. If BugSack or the game showed an error, include that too.

No GitHub account? Leave a comment on the CurseForge page and we'll take it from there.

## How it's made

Hard Counters is designed, directed and play-tested by Yolt Labs. Most of its code and documentation is written with
**Claude**, Anthropic's AI, through Claude Code, working from that design. Every change is reviewed and has to pass
the automated tests and lint. Beta builds are for trying things early and can go out before they have been played;
a full release is played in game before it ships. Commits written with Claude say so in a
`Co-Authored-By: Claude` line, so the history shows which ones.

## License

Open source under the [MIT License](LICENSE), © 2026 Yolt Labs. The libraries in `HardCounters/Libs` keep their own
licenses ([Libs/README.md](HardCounters/Libs/README.md)).

---

## For developers

The engine generalises the damage-meter idea to any statistic: capture sources → LibGranaryDB storage → views →
displays, with a public API for packs.

- Design: [docs/DESIGN.md](docs/DESIGN.md); trackers, history and boards: [docs/TRACKERS_AND_BOARDS.md](docs/TRACKERS_AND_BOARDS.md)
- Public API for packs (experimental): [docs/API.md](docs/API.md); the pack contract: [docs/PACKS.md](docs/PACKS.md)
- Layout: `HardCounters/` (engine, Basics (the Hard Counters Basic pack), boards, embedded libraries), `HardCounters_Diagnostics/`, and the packs in
  `packs/Farmer`, `packs/CharacterStats` and `packs/Traveler` (each with its own tests, lint and docs).
- Tools: `tools\test.ps1`, `lint.ps1`, `link.ps1`, `link-sv.ps1`, `package.ps1` (the bundle zip), `bump.ps1` (one
  version everywhere), `sync-libs.ps1`, `decode-report.ps1`, `draw-icon.py` (the icon and logo, drawn in code; WSL,
  Pillow). Development setup: [docs/DEV_SETUP.md](docs/DEV_SETUP.md)
- CI ([.github/workflows/ci.yml](.github/workflows/ci.yml)): busted and luacheck on PUC Lua 5.1 for the engine and
  each pack on every push; a `v*` tag builds the zip, attaches it to a GitHub release (a pre-release for alpha,
  beta and rc versions) and uploads the same zip to CurseForge (`tools/curseforge.ps1`).
- WoW API we call: [docs/WOW_API.md](docs/WOW_API.md); API verdicts: [docs/api-surface.md](docs/api-surface.md);
  research: [docs/research.md](docs/research.md)
- Open work and bugs: [GitHub Issues](https://github.com/ibourlakos-yolt/wow-hard-counters/issues). Design notes
  name work items as HC-n, FM-n and CS-n; the queue behind those IDs is kept in the developers' working notes.

Embeds `../LibGranaryDB` (LibStub `LibGranaryDB-1.0`; its guide is `../LibGranaryDB/docs/API.md`).
