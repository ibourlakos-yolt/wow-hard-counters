# Hard Counters: Farmer

The farming pack for Hard Counters: money, items, gathering, XP, reputation and farming time, with rates and records. Built only on Hard Counters' public API, as the first real test of it.

- Addon: `HardCounters_Farmer/` (phase 1: Ledger `/hc ledger` and readings). Tools: `tools\test.ps1`, `lint.ps1`,
  `link.ps1`, `package.ps1`. Tests boot the real engine from `../..` (the engine at the repo root).
- Design: [docs/DESIGN.md](docs/DESIGN.md)
- Farm targets (the menu for the first cut): [docs/FARM_TARGETS.md](docs/FARM_TARGETS.md)

Formerly `HardCountersPacks` (renamed 2026-11-14). Depends on `../..` (the engine at the repo root), which embeds
LibGranaryDB. Ships in the Hard Counters bundle; MIT, © Yolt Labs (the repo's `LICENSE`).
