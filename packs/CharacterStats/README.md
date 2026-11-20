# Hard Counters: Character Stats

A Hard Counters pack for the character sheet: attributes, melee, ranged, spell, defence, resistances, health and
mana, gear. Any stat on a board, records with the buffs that made them, and, with history on, each stat level by
level. Built only on Hard Counters' public API.

- Design: [docs/DESIGN.md](docs/DESIGN.md)

Status: phase 1 built 2026-11-19 (live readings, no counters; DESIGN §8 "As built"). Depends on `../..` (the engine
at the repo root), which embeds LibGranaryDB. Ships in the Hard Counters bundle; MIT, © Yolt Labs (the repo's
`LICENSE`).

- Tests: `tools\test.ps1` (busted in WSL, on the real engine in `../..` (the engine at the repo root)); lint: `tools\lint.ps1`.
- Into the game: `tools\link.ps1` (a junction in WoW's AddOns folder), then a full game restart.
