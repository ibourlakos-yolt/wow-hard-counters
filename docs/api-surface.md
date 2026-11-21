# WoW Forever API surface: verdict log

A living document. It records what the WoW Forever API (1.60.1, Interface 16001, retail 12.x engine with Midnight restrictions) **actually allows** addons to capture.

**Rule:** a verdict is **verified** only when a test in game (the diagnostics module or probe addon) or a cited source with a clear statement confirms it. Wiki claims alone are **reported**.

| Status | Meaning |
|---|---|
| ✅ verified | Confirmed in game on this client, or by an unambiguous primary source |
| 🟡 reported | Stated by wiki, Blizzard or other addon authors; not yet tested by us |
| ❓ unverified | Plausible but unknown |
| ⚠️ degraded | Works only partly; an estimate or with gaps |
| ⛔ infeasible | Blocked, or costs too much to work around; documented and dropped |


Evidence comes from in-game sessions read from the saved files; the dated session logs are kept in the
developers' working notes, not in this repo. Verdicts below cite them by name ("run 3", "2026-11-19").

Last updated: 2026-11-20.

## Platform

| Item | Status | Evidence / notes |
|---|---|---|
| `WOW_PROJECT_ID == WOW_PROJECT_CAMELOT (18)` | 🟡 | warcraft.wiki.gg/wiki/WOW_PROJECT_ID |
| TOC `_Forever.toc` / `_Camelot.toc`; load order Forever/Camelot → Mainline → plain | ✅ suffixes / 🟡 order | Suffixed TOCs from Questie and AtlasLoot are installed locally. Load order is from the wiki TOC_format page. |
| `## Interface: 16001` | ✅ | Local client 1.60.1.70888, and the installed addons |
| Shares the 12.1.5 Mainline API "vast majority" | 🟡 | Blizzard, quoted on wiki Patch_1.60.1/API_changes |
| Talents use the retail trait system (`CamelotCombat` config) | 🟡 | AltsForever source comment ("checked in game 2026-10-05") |
| `C_Timer.After` / `NewTicker` | ✅ (in use) | Used throughout AltsForever on this client |
| `C_EncodingUtil` CBOR + Deflate, `Enum.CompressionMethod.Deflate` | ✅ (in use) | QuestieTrace `Modules/Export/Encoding.lua` runs on this client |
| `/api` (Blizzard_APIDocumentation) | ❓ | Ships in the `forever` branch of wow-ui-source |
| `require` renamed to `import` | 🟡 | Wiki API changes 1.60.1 |
| Lua is 5.1 | 🟡 | Standard for WoW |

## Combat and secrets

| Item | Status | Evidence / notes |
|---|---|---|
| `COMBAT_LOG_EVENT_UNFILTERED` registration | ⛔ (🟡 forbidden) | Raises ADDON_ACTION_FORBIDDEN since 12.0.0. `CombatLogGetCurrentEventInfo` is absent from the Forever dumps. Journey Tracker's source avoids it on Forever. |
| Per-hit combat detail (each heal or hit, crits, misses) | ⛔ (🟡) | Follows from the above. Details! lost its hit/crit/miss breakdowns (Blizzard forums). |
| Secret values: arithmetic or comparison taints, and `pcall` doesn't catch it | 🟡 | Recount Revived changelog |
| `issecretvalue` / `canaccessvalue` / `C_Secrets.*` | 🟡 | Wiki |
| `C_RestrictedActions.IsAddOnRestrictionActive`, `ADDON_RESTRICTION_STATE_CHANGED` | 🟡 | Wiki. In game: the event fires (args `number,number`; 540 outdoors, 152 in a dungeon); the function exists and requires a type argument. `Enum.AddOnRestrictionType` lists ChallengeMode, Chat, Combat, Encounter, Map, PvPMatch; each returned a plain boolean at 4 loads outdoors (2026-11-15) |
| `C_DamageMeter` sessions (DamageDone, HealingDone, Absorbs, Interrupts, Dispels, DamageTaken…) | 🟡 exists / ❓ readable after combat | Marked SecretWhenInCombat. Forever Stats reads them after combat (about 30 sessions kept). Epic Damage Meter retries every 0.3 s for up to about 9 s after combat. |
| `combatSpellDetails`: does it contain a single biggest hit? | ❓ | Decides whether "top Holy Light heal" is possible |
| `UNIT_COMBAT` amounts (no spell ID) | ❓ | May be secret in combat |
| `PARTY_KILL` / `UNIT_DIED` | 🟡 restricted | SecretWhenUnitIdentityRestricted. Kill and death-by-source counting is unknown. |
| Fall damage reported to addons | 🟡 no | guild-addons PR #8 now infers it from airtime plus health lost |
| `UnitIsAFK` can return a secret boolean | 🟡 | Accountant Classic fixed a crash on it (2.30.03, Nov 12). Our probe got a plain boolean at 5 loads outdoors, out of combat |
| Creature, pet and object GUIDs obfuscated, stable only within one session | 🟡 | Wiki 1.60.1 notes. **Never persist them as keys.** |
| Player GUID stable | ❓ | Expected (only creature GUIDs are listed as obfuscated) |

## Movement and position

| Item | Status | Evidence / notes |
|---|---|---|
| `UnitPosition("player")` outdoors | ✅ plain, **in combat too** | 2026-11-21: 10,745 reads out of combat and 976 in combat at 4 Hz, none secret (Diagnostics travel sampler). Distance can come from position through fights, unlike speed |
| `UnitPosition` third return (`positionZ`) | ⛔ always 0 | 2026-11-21: 11,721 of 11,721 reads. No heights, so no fall distance |
| `IsMounted`, `IsSwimming`, `IsSubmerged`, `IsFlying`, `IsFalling`, `UnitOnTaxi`, `UnitInVehicle`, `UnitIsGhost`, `GetPlayerFacing` | ✅ plain in and out of combat | 2026-11-21: 2,685 reads out of combat and 244 in combat each, none secret |
| `UNIT_SPELLCAST_SUCCEEDED` spell ID (player) | ✅ plain in combat | 2026-11-21: 84 casts in combat, 40 out, none secret, though the API docs mark the event `SecretWhenUnitSpellCastRestricted` |
| Boats between continents | ✅ a continuous ride, then a loading screen | 2026-11-21: Darkshore to Wetlands: the position moves while `GetUnitSpeed`'s current speed is 0 (out of combat), about 60 s at up to 31 yd/s; one nil position read at the crossing |
| `C_MapExplorationInfo.GetExploredAreaIDsAtPosition` | ✅ in a named subzone / ⚠️ nil elsewhere | 2026-11-21: one area ID whose `C_Map.GetAreaInfo` name equals `GetSubZoneText()` in the Barrens (392) and Stonetalon Mountains (1076); nil on three runs just after a load (Darkshore, Wetlands, Stormwind), place unknown |
| Position on a taxi (flight path) | ✅ moves | 2026-11-21: 1,237 reads with `UnitOnTaxi` true, the position moved on every one; up to 56 yd/s. `PLAYER_CONTROL_LOST` / `GAINED` fire at the start and end (2 each) |
| Exploration achievement criteria (`GetAchievementNumCriteria`, `GetAchievementCriteriaInfo`) | ✅ readable / ⚠️ the metas | 2026-11-21: 776 (Explore Elwynn Forest) gives 12 criteria (type 43) with done flags and an asset ID; 42 and 43 (Explore Eastern Kingdoms / Kalimdor) give 0 criteria |
| `C_TaxiMap.GetTaxiNodesForMap` | ⚠️ the continent's list, `isUndiscovered` never true | 2026-11-21: 38 nodes for any Kalimdor zone, 36 for Eastern Kingdoms, none undiscovered on two characters (one too low to know them all) |
| `MAP_EXPLORATION_UPDATED`, `ZONE_CHANGED` | ✅ fire | 2026-11-21: 13 and 58 fires in a 55-minute session |
| `C_Map.GetPlayerMapPosition` / `GetBestMapForUnit` | 🟡 present | "AllowedWhenUntainted" |
| Position inside instances | ⚠️ | Run 2: no usable `GetBestMapForUnit` in The Deadmines (the zone key fell back to the zone text); run 3: nil again in The Hall of Thanes. Position itself not probed |
| `GetInstanceInfo()` instance ID inside a dungeon | ✅ | Run 3, third session: `type=party id=3065` in The Hall of Thanes; the zone key was `103065` (HC-13) |
| `GetUnitSpeed` | ✅ out of combat / ⛔ in combat | Secret in combat (CS-1, and the 2026-11-21 travel probes); Azeroth Odometer estimates in combat for that reason. `C_PlayerInfo.GetGlidingInfo` present, unprobed |
| Does addon code run during loading screens? | ❓ | QuestieTrace's "frame heartbeat" probes exactly this |
| Jump detection (`hooksecurefunc("JumpOrAscendStart")` or similar) | ❓ | Hooks under the new restrictions are untested |

## Economy and progression

| Item | Status | Evidence / notes |
|---|---|---|
| `PLAYER_MONEY` + `GetMoney()` | ✅ outdoors | Run 1: 91 fires, no args, never secret. A run's money in minus money out equalled the change in `GetMoney` exactly |
| `CHAT_MSG_MONEY` (loot money) | ✅ outdoors and in dungeons | Run 1: 70 lines, every one matched `LOOT_MONEY_SPLIT` ("Your share of the loot"), none matched `YOU_LOOT_MONEY`. Whether that was solo or grouped wasn't recorded. Run 2: 136 lines inside The Deadmines (`party`), all `LOOT_MONEY_SPLIT`, none secret |
| Window context: `MERCHANT_SHOW/CLOSED`, `AUCTION_HOUSE_SHOW/CLOSED`, `TRADE_SHOW/CLOSED` | ✅ | Run 1: they fire in pairs (merchant 8 show / 12 closed: closing can fire twice) |
| `MAIL_CLOSED` | ⛔ doesn't fire | Run 1: registered fine, **0 fires** after 3 `MAIL_SHOW`. Farmer kept the mailbox "open" and later loot money was booked as mail. Fixed by the interaction-manager events below |
| `TRAINER_CLOSED`, `TAXIMAP_CLOSED` | ⚠️ fire, unpaired | Run 2 evening: 5 and 17 fires against 13 and 10 opens. Don't pair opens with closes |
| `PLAYER_INTERACTION_MANAGER_FRAME_SHOW/HIDE` (`Enum.PlayerInteractionType` in arg 1) | ✅ | Run 2 evening: hides fire for every type seen (MailInfo 17: 10 shows, 11 hides); after the switch no loot money was booked as mail. Hides with arg 0 come without shows |
| `PLAYER_XP_UPDATE`, `CHAT_MSG_COMBAT_XP_GAIN` | ✅ outdoors and in dungeons | Run 1: 135 and 129 fires. The probe's end-anchored kill pattern missed lines with a rested suffix (a probe flaw, fixed); Farmer's parser matches without the end anchor |
| `CHAT_MSG_COMBAT_FACTION_CHANGE` | ✅ outdoors | Run 1: 35 lines, all matched `FACTION_STANDING_INCREASED` |
| `QUEST_TURNED_IN` | ✅ | Run 1: 7 fires, `number,number,number` (quest ID, XP, money) |
| `CHAT_MSG_LOOT` | ✅ outdoors and in dungeons / ⚠️ | Run 1: 307 lines, 130 matched our own loot (self + pushed); **177 matched nothing we test**: other players' loot, crafted items or something else. The probe now tells them apart. Run 2: 483 lines inside The Deadmines, none secret |
| `GetStatistic` (achievement statistics) | 🟡 works | StatPoker, Forever Statistics and Journey Tracker import them. Blizzard removed the beta characters' statistics. |
| `TIME_PLAYED_MSG` / `RequestTimePlayed` | ✅ (in use) | AltsForever calls `RequestTimePlayed` and mutes the chat output |

## Character stats (CS-1)

From run 3's second session: 5 automatic probe runs, one of them in combat (13:31:45, 2 s into the first fight).
The probe records types, never values, so whether a stat is non-zero for the character isn't known.

| Item | Status | Evidence / notes |
|---|---|---|
| `UnitStat`, `UnitArmor`, `UnitAttackPower`, `UnitRangedAttackPower`, `UnitDamage`, `UnitRangedDamage`, `UnitAttackSpeed`, `UnitSpellHaste`, `GetUnitSpeed` | ✅ out of combat / ⛔ in combat | Plain numbers out of combat (4 runs); **every return secret** in combat (1 run) |
| `GetCritChance`, `GetRangedCritChance`, `GetSpellCritChance`, `GetHitModifier`, `GetSpellHitModifier`, `GetHaste`, `GetExpertise`, `GetArmorPenetration`, `GetSpellPenetration`, `GetCombatRating`, `GetCombatRatingBonus` | ✅ out of combat / ⛔ in combat | Same: numbers out of combat, secret in combat. Retail-style ratings and haste exist |
| `GetSpellBonusDamage`, `GetSpellBonusHealing`, `GetManaRegen` | ✅ out of combat / ⛔ in combat | Same |
| `GetDodgeChance`, `GetParryChance`, `GetBlockChance`, `GetShieldBlock` | ✅ out of combat / ⛔ in combat | Same |
| `GetAverageItemLevel`, `UnitHealthMax`, `UnitPowerMax`, `UnitResistance` | ✅ in and out of combat | Never secret |
| `UnitDefense`, `UnitAttackBothHands` | ⛔ absent | "not a function" at every run |
| `GetNumSkillLines`, `GetSkillLineInfo` (CS-8) | ⛔ absent | nil at five runs in run 3's third session (outdoors, in combat, in a dungeon), though `SKILL_LINES_CHANGED` fires. No `C_` replacement looked for yet. Weapon skill and Defence can't be read from skill lines |
| `GetInventoryItemDurability(1)` | ❓ | Returned nothing in and out of combat (no head item, or none with durability) |
| `UNIT_STATS`, `UNIT_AURA`, `UNIT_ATTACK_POWER`, `UNIT_RANGED_ATTACK_POWER`, `UNIT_ATTACK_SPEED`, `UNIT_DAMAGE`, `UNIT_RESISTANCES`, `UNIT_MAXHEALTH`, `UNIT_MAXPOWER`, `COMBAT_RATING_UPDATE`, `SPELL_POWER_CHANGED`, `PLAYER_EQUIPMENT_CHANGED`, `SKILL_LINES_CHANGED`, `UPDATE_INVENTORY_DURABILITY`, `PLAYER_LEVEL_UP` | ✅ fire | 60, 526, 38, 164, 43, 160, 48, 43, 11, 6, 30, 6, 184, 395, 11 fires since each was added to the probe, all outdoors; no secret argument |

## Social and data movement

| Item | Status | Evidence / notes |
|---|---|---|
| Addon messages (`C_ChatInfo.SendAddonMessage`) | 🟡 | Not for trial accounts |
| EMOTE chat needs a hardware event | 🟡 | Wiki |
| Sharing stats through chat | 🟡 restricted? | A Blizzard forum reply says API rules block sharing these through chat. Needs testing. |
| Copy-paste export through a text box with `SetMaxLetters(0)` | ✅ (in use) | QuestieTrace ExportUI on this client |
| Clipboard write | ⛔ | No API; the player presses Ctrl+A, Ctrl+C |
| `Screenshot()` callable by an addon (not only from the key binding) | ❓ | Would let the dev console's marker take the screenshot automatically. Screenshots land in `_forever_\Screenshots\*.jpg`; one exists on this machine. |
| File I/O or network from an addon | ⛔ | Only SavedVariables, written on logout or `/reload` |

## Storage

| Item | Status | Evidence / notes |
|---|---|---|
| SavedVariables load time grows with entry count | 🟡 | Many reports (WeakAuras issue #4912, Blizzard forums) |
| Raw-event recorders bloat quickly | ✅ | On this machine, `QuestieTrace.lua` is 5.6 MB and 4.1 MB in two saved-variables folders |
| SavedVariables restored at login | ✅ (since beta build 70009) | Forever beta bug; fixed |
| A logout-time save crashed the client in one addon | 🟡 | Murloc Census Bureau, which now updates its saved tables every 15 s instead |
