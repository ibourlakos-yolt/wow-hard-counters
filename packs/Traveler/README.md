# Hard Counters: Traveler

The travel pack for Hard Counters: how far you go and how (on foot, mounted, swimming, flight paths, boats, blinks,
teleports), time moving, speeds, jumps and falls, corpse runs and flights. Built only on Hard Counters' public API.

- Addon: `HardCounters_Traveler/` (first edition): `Motion.lua` (the movement model, pure Lua) and `Traveler.lua`
  (counters, sources, readings, the Trip and Flight log boards). Tools: `tools\test.ps1`, `lint.ps1`, `link.ps1`.
  Tests boot the real engine from `../..` (the engine at the repo root).
- Design as built: [docs/DESIGN.md](docs/DESIGN.md)

Depends on `../..` (the engine at the repo root). Ships in the Hard Counters bundle; MIT, © Yolt Labs (the repo's
`LICENSE`). A new addon folder: after linking it (`tools\link.ps1`), restart the game client.
