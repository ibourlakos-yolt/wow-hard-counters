# Development setup: decision record

- **Status:** accepted
- **Date:** 2026-11-13
- **Applies to:** LibGranaryDB (formerly LibTally), HardCounters, with its packs in `packs/` (Farmer, formerly HardCountersFarmer and before that HardCountersPacks; Character Stats; both merged in 2026-11-20). This file is the canonical copy; the other repos link here.

## Context

**Machine:**
- Windows 11, VS Code. Installed extensions include `ms-vscode-remote.remote-wsl` and the older `septh.wow-bundle`.
- WSL 2 with Ubuntu 22.04: `gcc` and `make` present, the Windows projects visible at `/mnt/c/...`. It warns that the systemd user session failed to start; this is harmless for our use.
- No Lua tooling on either side: no Lua, LuaJIT, LuaRocks, busted or luacheck.
- WoW Forever is installed at `C:\Program Files (x86)\World of Warcraft\_forever_\`.

**What other WoW addon developers use** (general knowledge of the ecosystem, not re-verified for this record):
- **Editor:** VS Code with **Ketho's "WoW API" extension** (Lua language server plus WoW annotations) is the de facto standard. A minority use IntelliJ with EmmyLua, or Notepad++.
- **Testing:** **mostly no automated tests.** The loop is edit, `/reload`, check. Errors are caught with **BugSack + BugGrabber**; things are inspected with `/dump`, `/fstack`, `/etrace` and `/tinspect`. The DevTool addon was common but its repo is now archived.
- **Lint and packaging:** **luacheck** plus the **BigWigs packager**, usually in **GitHub Actions on Linux runners**, not on the developer's machine.
- **Reference:** warcraft.wiki.gg, Gethe/wow-ui-source, Townlong Yak's FrameXML browser, the WoWUIDev Discord.
- **Automated tests are the exception:** large projects like TradeSkillMaster (its utility library), WeakAuras, and probably Questie (busted in CI). A few use wowless, a headless emulator of the game's UI layer.

**Constraints of our own:**
- **No GitHub for now**, so no CI.
- **WoW loads addons through a directory junction**, and a junction can't point into the WSL filesystem (`\\wsl$\…`). So the repos must stay on the Windows filesystem.

## Options considered

1. **Pure Windows:** a Lua binary plus a home-made test runner plus luacheck's Windows `.exe`. *Rejected as the default.* busted on Windows needs LuaRocks with compiled C modules, which is painful, and a home-made runner is extra code to maintain.
2. **Everything inside WSL**, repos included. *Rejected:* WoW can't load addons from the WSL filesystem.
3. **GitHub Actions as the test machine**, which is the ecosystem norm. *Rejected for now:* no GitHub.
4. **Hybrid: code and git on Windows, tests and lint in WSL.** ✅ **Chosen.** WSL stands in for the CI we don't have.

## Decision

| Concern | Choice |
|---|---|
| Repo location | `%USERPROFILE%\Documents\Projects\HardCountersSuite\<Repo>` (Windows filesystem) |
| Editor | Plain Windows VS Code (not WSL-remote mode), with a WSL terminal profile for running tests |
| VS Code extensions | **`ketho.wow-api`** (required; brings in the Lua language server). `septh.wow-bundle` only for TOC highlighting; disable it if it clashes. Optional: StyLua, a luacheck extension. |
| Git | **Run from Windows only.** Never run git from WSL on these repos (line-ending and permission noise). `.gitattributes` uses LF line endings, CRLF for `.ps1`. |
| Test runtime | **PUC Lua 5.1** in WSL (`lua5.1`). The game runs a modified Lua 5.1 **without a JIT compiler**. |
| Test runner | **busted**, installed with LuaRocks in WSL |
| Lint | **luacheck** in WSL, with a `.luacheckrc` per repo listing only the WoW globals we use |
| Benchmarks | **Lua 5.1, never LuaJIT.** LuaJIT inflates speed several times over and distorts allocation counts. The final word on timings is the in-game `/granary bench`. |
| In-game errors | BugSack + BugGrabber (installed by the user from the CurseForge app). Run `/console scriptErrors 1` once. |
| In-game inspection | `/dump`, `/fstack`, `/etrace`, `/tinspect`. Not DevTool (archived). |
| Loading code into the game | Directory junctions (`mklink /J`, no admin needed) from `_forever_\Interface\AddOns\<Addon>` to the repo's addon folder; `/reload` to pick up changes |
| Getting results back | Claude reads `WTF\Account\<account>\SavedVariables\<Addon>.lua` directly after a logout or `/reload`. **There are two account folders**, so say which one was used. Screenshots for UI. |
| Packaging | `tools/package.ps1` per repo builds a zip in `dist/` for hand-shipping. No store publishing. |
| API references | warcraft.wiki.gg, Gethe/wow-ui-source **`forever` branch**, Ketho/BlizzardInterfaceResources `forever` branch (slightly stale), `/api` in game (unverified on Forever) |

## One-time setup

**1. WSL packages.** The user runs these, because `sudo` needs your password:
```bash
sudo apt update && sudo apt install -y lua5.1 liblua5.1-0-dev luarocks
```
```bash
sudo luarocks install busted && sudo luarocks install luacheck
```

**2. VS Code.** Install `ketho.wow-api` and add a WSL terminal profile.

**3. In game.** Install BugSack + BugGrabber, then run `/console scriptErrors 1`.

## Everyday commands

Run them from any Windows terminal, or let Claude Code run them through `wsl -e`.

```bash
wsl -e bash -lc "cd /mnt/c/Users/<you>/Documents/Projects/HardCountersSuite/LibGranaryDB && busted"
```
```bash
wsl -e bash -lc "cd /mnt/c/Users/<you>/Documents/Projects/HardCountersSuite/LibGranaryDB && luacheck ."
```

Each repo gets wrapper scripts under `tools/` so nobody has to remember these. LibGranaryDB has them already: `tools\test.ps1`, `lint.ps1`, `bench.ps1`, `link.ps1`, `link-sv.ps1`, `package.ps1`, `decode-report.ps1`.

## Consequences

- **The same as the mainstream setup** (VS Code, Ketho's extension, luacheck, BugSack, `/reload`), so community advice applies directly.
- **The one deliberate difference is real unit tests for LibGranaryDB.** It's pure logic (rollups, calendars, migrations, export) where bugs silently corrupt months of data, and it's fully testable outside the game.
- **HardCounters and the packs are developed mostly the usual way** (`/reload`, BugSack, screenshots). Their capture and UI code can't be meaningfully tested offline, so expect little offline coverage there: unit tests for pure helpers only, in-game checklists for the rest.
- **Reading files across `/mnt/c` is slower than native Linux**, but fine for repos this size.
- **If GitHub is added later:** move lint and tests into GitHub Actions (the ecosystem norm), and WSL remains the local mirror.
