# Hard Counters

**Put any number you care about on your screen.** Gold per hour, XP to level, how many Linen Cloth you've looted, your
reputation toward the next standing, your crit chance: pick it, drop it on a board, done. History, records and rates
are there when you want them and never in the way when you don't.

For **World of Warcraft: Forever** (Interface 16001).

> **Experimental (alpha).** This is an early build for friends and curious players. Things will change, and saved
> data may be reset between alpha versions. Please report what breaks (see [Reporting a problem](#reporting-a-problem)).

## What you get

One download, four addon folders. Turn off any pack you don't want in the game's AddOns list.

| Folder | What it does |
|---|---|
| **Hard Counters** | The engine and the boards. Comes with the basics: gold earned, gold owned, net gold, gold per hour, XP gained, XP this level, rested XP, time to level. |
| **Hard Counters: Farmer** | Counts what you farm: a money Ledger by source (loot, vendor, quests, mail, ...), items looted and their vendor value, your best drop, reputation gained, "*item* in bags" and "*faction* standing". |
| **Hard Counters: Character Stats** | Your character sheet as readings: attributes, melee, ranged, spell and defence stats, weapon skills and Defense. Ready-made Caster, Melee, Hunter and Tank boards. |
| **Hard Counters: Diagnostics** | A console for finding problems: log, live values, storage use, game API checks. On in alpha builds so reports are useful; turn it off in the AddOns list if you don't want it. |

## Getting started

1. Install through the CurseForge app (set this addon's release type to **Alpha**, or the app won't offer it), or
   unzip the download into `World of Warcraft\_forever_\Interface\AddOns`.
2. Log in. A first board appears on screen.
3. Open Hard Counters with **`/hc`**, the **minimap button**, or the game's **AddOns menu**.

**Boards** are the panels that stay on screen while you play. Each one holds tiles, and each tile shows one reading.

- **Add a board:** right-click the minimap button, then *New board* (blank or from a ready-made one).
- **Edit a board:** hover it and click its *Edit* tab, or open Blizzard's Edit Mode to edit them all.
  - `+` adds a reading: pick from the list, an item from your bags, a recent loot or a faction.
  - Right-click a tile to change it: big number, row, **bar toward a target**, **gauge**, total or per hour,
    character or whole account, or a target of your own.
- **The board's clock:** start, pause and reset the board's timer; a tile can follow the board (this session, today,
  this run...). Dungeons record themselves as runs; any other stretch of play can be saved as a run.
- **History is off by default.** Turn it on per tracker (the *Trackers* tab of `/hc`) to keep day-by-day totals and
  records. Off means nothing is stored beyond what your boards show right now.

### Commands

| Command | |
|---|---|
| `/hc` | Open the Hard Counters window |
| `/hc ledger` | Farmer's money Ledger |
| `/hc stats` | The Character Stats window |
| `/hc edit` | Edit every board |
| `/hc report` | A copyable report for bug reports (`/hc report addons` adds your addon list) |
| `/hc diag` | The Diagnostics console |
| `/hc help` | Every command |

## Good to know

- **Combat.** WoW: Forever hides many character stats from addons during combat. Single-value stats keep updating;
  the rest show their last value, marked *in combat*, until the fight ends.
- **Nothing leaves your computer.** Addons have no network access. `/hc report` only shows text for you to copy.
  It includes no character names or realms, and your addon list only if you ask for it.
- **Saved data** lives in `HardCountersDB` and `HardCountersSettings` (WTF folder). During the alpha a new version may
  reset it; the changelog will say so.
- **The packs' API is experimental.** Other authors can build packs on Hard Counters, but the API may still change.

## Reporting a problem

1. Type `/hc report`, copy the text in the box (Ctrl+A, Ctrl+C).
2. Open a bug report on GitHub ([new bug report](https://github.com/ibourlakos-yolt/wow-hard-counters/issues/new?template=bug.yml)) and paste it into the form, with what you did
   and what you expected.
3. If BugSack or the game showed an error, include that too.

No GitHub account? Leave a comment on the CurseForge page and we'll take it from there.

## How it's made

Hard Counters is designed, directed and play-tested by Yolt Labs. Most of its code and documentation is written with
**Claude**, Anthropic's AI, through Claude Code, working from that design. Every change is reviewed, has to pass the
automated tests and lint, and is played in game before it ships. Commits written with Claude say so in a
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
- Layout: `HardCounters/` (engine, Basics, boards, embedded libraries), `HardCounters_Diagnostics/`, and the packs in
  `packs/Farmer` and `packs/CharacterStats` (each with its own tests, lint and docs).
- Tools: `tools\test.ps1`, `lint.ps1`, `link.ps1`, `link-sv.ps1`, `package.ps1` (the bundle zip), `bump.ps1` (one
  version everywhere), `sync-libs.ps1`, `decode-report.ps1`. Development setup: [docs/DEV_SETUP.md](docs/DEV_SETUP.md)
- WoW API we call: [docs/WOW_API.md](docs/WOW_API.md); API verdicts: [docs/api-surface.md](docs/api-surface.md);
  research: [docs/research.md](docs/research.md)
- Open work and bugs: [GitHub Issues](https://github.com/ibourlakos-yolt/wow-hard-counters/issues). Design notes
  name work items as HC-n, FM-n and CS-n; the queue behind those IDs is kept in the developers' working notes.

Embeds `../LibGranaryDB` (LibStub `LibGranaryDB-1.0`; its guide is `../LibGranaryDB/docs/API.md`).
