# Hard Counters: Character Stats — design document

> **Status:** phase 1 built (2026-11-19, live readings; more stats, resistances, gear and role and class boards
> 2026-11-24, §8). The concept below dates from 2026-11-15. Asked for by the user on 2026-11-15 as a new pack "for a detailed
> collection of character stats tracking", to be **really detailed**, in the spirit of the "Forever Extended Character
> Stats" addon (§2.1).
>
> **Depends on** Hard Counters' trackers, readings and boards
> ([`../../../docs/TRACKERS_AND_BOARDS.md`](../../../docs/TRACKERS_AND_BOARDS.md), HC-17, HC-18,
> HC-19), built 2026-11-15, and on three small Hard Counters additions found by reading the code on 2026-11-18:
> HC-26 (`ObserveCtx`), HC-27 (login min and max for stocks), HC-28 (reading states for "in combat" and "doesn't
> apply"). **Don't write pack code before those exist.**
>
> **Decided 2026-11-18 (user):** one stock counter per API stat (§4.1), not one counter per tracker with a `stat`
> dimension.
>
> **2026-11-18, later:** Hard Counters' direction changed (its DESIGN §16: windows per tile, readings with a
> parameter); that work comes before this pack. A review the same day proposed a smaller phase 1 (§10, undecided).
>
> **Related:** Hard Counters [`PACKS.md`](../../../docs/PACKS.md) (the
> pack contract), [`api-surface.md`](../../../docs/api-surface.md) (API verdicts).

---

## 1. Purpose and the honest pitch

Track the whole character sheet, in more detail than the default pane shows: attributes, melee, ranged, spell per
school, defence, avoidance, regeneration, resistances, health and power, gear. Show any stat on a board, and, with
history on, show how it changed.

**Live stat display alone is table stakes.** Extended character-sheet addons already list these stats next to the
paper doll (§2.1). Matching their breadth is the entry ticket (§3 is a superset of both); it wins nobody by
itself. What none of them does, and Hard Counters can:

1. **Any stat on any board,** next to Gold/h or XP/h, in the same edit mode, in combat-friendly mini mode. The
   reference addons live inside the character window: you see your hit chance only with the pane open.
2. **Progression:** each stat at every level and by day ("spell power by level", "crit since launch"). Needs history
   (off by default, §7).
3. **Records with context:** "most attack power ever: 1,204, in Blackrock Depths, 6 buffs active". World-buff stacking
   is a big part of classic culture; a record board for it is fun and unique.
4. **Gear versus buffs:** stats split into *unbuffed* (base and gear) and *buffed* (right now). History stores
   unbuffed values, so a charted line shows real gear progress, not who buffed you.
5. **Upgrade deltas:** after an equipment change, what changed: "+12 spell power, +0.8 % crit, −0.4 % miss vs boss".
6. **Thresholds that matter:** hit cap against bosses, crit immunity (defence), each shown as met or not, not left
   to the player's arithmetic.

## 2. Identity

| | |
|---|---|
| Title | **Hard Counters: Character Stats** |
| Repo | `packs/CharacterStats` in the Hard Counters repo (merged 2026-11-20) |
| Addon folder | `HardCounters_CharacterStats/` |
| Pack name / namespace | `CharacterStats` / `hcstats` |
| Queue IDs | `CS-n` |
| Built on | Hard Counters' public API only (PACKS rule) |

### 2.1 Reference addons (read 2026-11-15)

| Addon | What it shows | Notes |
|---|---|---|
| **Forever Extended Character Stats** (Naw993, CurseForge, v1.3.0, Forever 1.60.1) | A flat list of about 20: four attributes; melee damage, speed, attack power, crit, hit "where available"; ranged damage, speed, attack power, crit; spell damage, crit, hit "where available"; mana regeneration; armour, dodge, parry, block; max health and resource | An "Expanded Stats" panel on the Character window, live while it's open; restricted values show "Protected" or "—". No per-stat toggles. **All Rights Reserved:** read its description only, never its code |
| **Extended Character Stats** (BreakBB, Classic, TBC and WotLK clients; MIT) | About 90 values: movement speed; melee attack power, crit, hit bonus, miss vs same level and vs boss, glancing chance and damage vs same level and vs boss, attack speed per hand; ranged equivalents; defence: armour, crit reduction (melee, ranged, spell), avoidance and vs boss, enemy miss chance and vs boss, defence, block chance and value, parry, dodge; regen: MP5 from items, spirit, buffs, while casting, not casting; spell: base damage, bonus healing, and per school (arcane, fire, frost, holy, nature, physical, shadow) damage, crit, hit bonus, miss vs same level and vs boss | Rows appear only when they apply (block and parry for classes that can, regen for mana users, off-hand for dual-wielders); every stat can be hidden, per character; client checks hide stats a client lacks. Its structure was read from the module layout, not copied |

Sources: [Forever Extended Character Stats](https://www.curseforge.com/wow/addons/forever-extended-character-stats),
[Extended Character Stats (CurseForge)](https://www.curseforge.com/wow/addons/extended-character-stats),
[Extended Character Stats (GitHub)](https://github.com/BreakBB/ExtendedCharacterStats).

## 3. The stat catalog

Every row is a reading the player can put on a board. **Source:** *API* = read directly; *derived* = computed from
API values with a formula (an estimate until the formula is verified on Forever, CS-7; labelled "≈" per the
feasibility policy). Derived values are **never stored**: history keeps the API values they come from, so a
corrected formula fixes the past too. **Built** in a row means it is a reading now (§8, with the reading's name).

### 3.1 General

| Stat | Source |
|---|---|
| Level, movement speed (% of run speed) | API (`UnitLevel`, `GetUnitSpeed`). Not in this pack: Level is Hard Counters Basic's (`hc:level`, 2026-11-24), movement speed Traveler's Speed now |
| Max health, max mana / rage / energy | API (`UnitHealthMax`, `UnitPowerMax`) |
| Health regeneration out of combat | derived (spirit) |

### 3.2 Attributes

| Stat | Source |
|---|---|
| Strength, agility, stamina, intellect, spirit: **base, from gear, from buffs (+/−), total** | API (`UnitStat` returns the split) |

### 3.3 Melee

| Stat | Source |
|---|---|
| Attack power (base, bonus) | API (`UnitAttackPower`) |
| Damage range and DPS, main hand and off hand | API (`UnitDamage`). **Built** 2026-11-24: Main-hand DPS, Off-hand DPS (the range's average ÷ speed; the range itself isn't shown) |
| Attack speed, main hand and off hand (off hand only when dual-wielding) | API (`UnitAttackSpeed`). **Built** 2026-11-24: Main-hand speed, Off-hand speed |
| Weapon skill, main hand and off hand | ~~no source~~ API (`C_SkillInfo`, CS-8 answered 2026-11-19; §9.6). **Built:** Main-hand skill, Off-hand skill (2026-11-19); Weapon skill: pick a skill, any weapon skill or Defense (CS-13, 2026-11-24). A fist weapon reads Unarmed when there is no Fist Weapons line (CS-12) |
| Crit chance | API (`GetCritChance`). **Built:** Melee crit |
| Hit bonus | API (`GetHitModifier`). **Built:** Hit (melee and ranged) |
| Miss chance vs same level, vs boss (level + 3); dual-wield penalty applied | derived (hit bonus, weapon skill) |
| Glancing blow chance and damage, vs same level and vs boss | derived (weapon skill) |
| Dodge and parry chance of the target, vs boss | derived (weapon skill) |
| **Hit cap vs boss: met / short by x %** | derived |
| Haste, expertise, armour penetration (each only if the API returns them) | API (`GetHaste`, `GetExpertise`, ...) |

### 3.4 Ranged (hunters, warriors and rogues with a ranged weapon)

| Stat | Source |
|---|---|
| Ranged attack power | API (`UnitRangedAttackPower`) |
| Damage range, DPS, speed | API (`UnitRangedDamage`). **Built** 2026-11-24: Ranged DPS, Ranged speed |
| Ranged weapon skill | ~~no source~~ API (`C_SkillInfo`, CS-8); §9.6. **Built:** Ranged skill (2026-11-19) |
| Crit chance | API (`GetRangedCritChance`) |
| Hit bonus | API (`GetHitModifier`; ranged-specific if Forever splits it) |
| Miss chance vs same level, vs boss; hit cap vs boss | derived |

### 3.5 Spell (casters and hybrids)

| Stat | Source |
|---|---|
| Base spell damage, bonus healing | API (`GetSpellBonusDamage`, `GetSpellBonusHealing`) |
| **Per school** (arcane, fire, frost, holy, nature, shadow, and physical where it applies): damage bonus, crit chance | API (`GetSpellBonusDamage(school)`, `GetSpellCritChance(school)`). **Built** 2026-11-24: Spell damage and Spell crit take an optional school (the six, not physical); none is the best school |
| Spell hit bonus (global, and per school if talents differ) | API (`GetSpellHitModifier`) |
| Miss chance per school vs same level, vs boss; spell hit cap vs boss | derived |
| Spell penetration, haste (only if the API returns them) | API (`GetSpellPenetration`, `UnitSpellHaste`). **Built** 2026-11-24: Spell penetration (casters, when the call exists); haste not |

### 3.6 Regeneration (mana users)

| Stat | Source |
|---|---|
| Mana regen while casting and not casting | API (`GetManaRegen`). **Built:** Mana regen (casting), Mana regen (not casting) |
| MP5 from gear, from spirit, from buffs | derived (gear from item stats or the API split; spirit from the formula) |
| Five-second-rule state (live) | derived from `UNIT_SPELLCAST_SUCCEEDED`, live only |

### 3.7 Defence and avoidance

| Stat | Source |
|---|---|
| Armour; physical damage reduction vs same level and vs boss | API (`UnitArmor`); reduction derived. **Built:** Armor |
| Defence skill | ~~no source~~ API (`C_SkillInfo`, CS-8); §9.6. **Built:** Defense (2026-11-19) |
| Dodge, parry, block chance (parry and block only for classes that can) | API (`GetDodgeChance`, `GetParryChance`, `GetBlockChance`). **Built:** Dodge, Parry, Block chance |
| Block value | API (`GetShieldBlock`) |
| Crit reduction (melee, ranged, spell); **crit immune vs boss: yes / short by x defence** | derived (defence) |
| Avoidance total, vs same level and vs boss; enemy miss chance, vs same level and vs boss | derived |
| Resilience (only if the API returns it) | API |

### 3.8 Resistances

| Stat | Source |
|---|---|
| Fire, frost, nature, shadow, arcane: base and buffed | API (`UnitResistance`). **Built** 2026-11-24 (CS-14): one reading, Resistance, the school picked on the tile; the buffed total only |
| Average resist % vs same level and vs boss, per school | derived |

### 3.9 Gear

| Stat | Source |
|---|---|
| Average item level (equipped), if Forever returns it | API (`GetAverageItemLevel`). **Built** 2026-11-24: Average item level (equipped, else overall) |
| Lowest durability % and the slot | API (`GetInventoryItemDurability`). **Built** 2026-11-24: Lowest durability, in %; the slot isn't named yet |
| Set pieces worn per set (tooltip-free where the API allows) | API, later |

### 3.10 What applies to whom

Like the Classic reference addon, rows appear only when they mean something: block and parry for classes that can,
off-hand rows when dual-wielding, regeneration for mana users, ranged for classes with a ranged slot in use, "if
present" rows only when the API returns a non-zero value for this character. In the Trackers window, hidden rows
are listed under "Not used by this character", so nothing looks missing by accident. Per-stat visibility comes
free: a stat is shown where the player puts it (boards) and in the pack's own window (§6). Readings have no
"applies to this character" rule yet; it is part of HC-28.

## 4. Trackers and counters

| Tracker | Catalog sections | Default | Built (live readings, §8) |
|---|---|---|---|
| **Attributes** | 3.1 (health, power, level), 3.2 | off (*New*) | 2026-11-19 (no level: Hard Counters Basic has it) |
| **Melee** | 3.3 | off | 2026-11-19; weapon DPS, speed and Weapon skill: pick a skill 2026-11-24 |
| **Ranged** | 3.4 | off | 2026-11-19; DPS and speed 2026-11-24 |
| **Spell** | 3.5, 3.6 | off | 2026-11-19; by school and spell penetration 2026-11-24 |
| **Defense** (id `hcstats:defence`; shown "Defence" until 2026-11-24) | 3.7 | off | 2026-11-19 |
| **Resistances** (`hcstats:resist`) | 3.8 | off | 2026-11-24: Resistance, one school picked |
| **Gear** (`hcstats:gear`) | 3.9 | off | 2026-11-24: Lowest durability, Average item level |

### 4.1 One stock counter per API stat (decided 2026-11-18)

Every value the API returns (§3 rows marked *API*) is **its own stock counter**, `hcstats:<stat>`, written with
`HC:Observe`. That's about 70 counters for the whole catalog (the exact list is part of CS-4), for example
`hcstats:str`, `hcstats:str.buffed`, `hcstats:ap`, `hcstats:spelldmg.fire`, `hcstats:spellcrit.fire`,
`hcstats:dodge`, `hcstats:res.fire`.

**Why not one counter per tracker with a `stat` dimension** (the earlier plan). Read in the code on 2026-11-18
(it closed CS-2):

1. **The library's half was fine.** LibGranaryDB keeps `last`, `min`, `max`, `twa` and the `twa` carry per tuple
   (`LibGranaryDB-1.0/Core/Store.lua`, the stock branch of the write path).
2. **The grand total breaks it.** LibGranaryDB always stores the grand-total set `{}` (`Core/Registry.lua`,
   "the grand total"); a definition can't leave it out. With a `stat` dimension every observation of every stat
   also lands in that one tuple: its `max` is whichever stat has the biggest number (max health), its `last` is the
   stat read last, and `OnNewExtreme` fires "records" for it. A stock's dimension must split **one** quantity
   (a stat by level), never hold different quantities.
3. **Hard Counters reads one value per counter.** Readings name a counter and a measure, with no member filter;
   `HC:Observe` keeps one last value per counter for the `login` and `now` scopes (`ns.lmem`, `Core/Registry.lua`
   and `Core/Readings.lua`). With a `stat` dimension a "Strength now" tile would show whatever stat was written
   last. Fixing that would mean per-member memory and filters in the engine, for no gain.

**Cost:** a counter on a tracker that is off, or on with history off (Live only, the default), isn't registered in
LibGranaryDB at all: about 70 counters cost nothing on disk until the player turns history on. With history on, each
stat is one small stock (one tuple per level per bucket), far below the root budget.

### 4.2 Counter shape

| Field | Value |
|---|---|
| `kind` | `"stock"` |
| `measures` | `last`, `min`, `max`, `twa` |
| `dimensions` | `{ { name = "level", cap = 64 } }`, aggregations `{ { "level" } }`: "this stat at each level". The grand total is then the stat itself, which is what it should be. `form` (druid forms, warrior stances) is a later option, as a second dimension on the same counter: forms change stats a lot |
| `context` | buffed counters only: `{ max = { "zone", "buffs" } }` (`buffs`: a short capped list of active buff names, one string) |
| `formatter`, `accuracy`, `feasibility` | per stat: `"percent"` for chances, `"exact"` for API values |

- **Only API values are counters.** Derived rows (§3) are **computed readings** (`compute` over other readings,
  `inputs` listing them; built in HC-17), never stored, so storage stays small and a corrected formula (CS-7) fixes
  the past too.
- **Unbuffed vs buffed: two counters,** `x` (unbuffed) and `x.buffed`, never a `buffed` dimension (same grand-total
  problem as §4.1). History is meant for the unbuffed counter (gear progress); records for the buffed one. Where
  the API gives only a buffed value (everything but attributes and resistances, §5), the stat has one counter
  until CS-3 finds an unbuffed source; its title says "buffed".
- **Trackers list counters,** one tracker per catalog section (table above). A computed reading may read counters
  of another tracker (spell miss vs boss needs level, from Attributes); list such a counter in both trackers, so it
  counts while either is on.
- **Records:** lifetime `max` of the buffed counters with context, through `OnNewExtreme` → `HC_NEW_RECORD` (at
  most once per counter per 10 s, deferred). Writing context needs **`HC:ObserveCtx` (HC-26)**: LibGranaryDB has
  `Handle:ObserveCtx`, Hard Counters doesn't expose it yet. Lifetime records live in storage, so they need at
  least the `lifetime` history preset; Live only gives the login maximum (HC-27). The record toast is opt-in.

## 5. Capture

- **Event-driven, sampled out of combat.** Events: `UNIT_STATS`, `UNIT_AURA` (player), `PLAYER_EQUIPMENT_CHANGED`,
  `UNIT_ATTACK_POWER`, `UNIT_RANGED_ATTACK_POWER`, `UNIT_ATTACK_SPEED`, `UNIT_DAMAGE`, `UNIT_RESISTANCES`,
  `UNIT_MAXHEALTH`, `UNIT_MAXPOWER`, `PLAYER_LEVEL_UP`, `COMBAT_RATING_UPDATE`, `SPELL_POWER_CHANGED`,
  `SKILL_LINES_CHANGED` (weapon and defence skill), `UPDATE_INVENTORY_DURABILITY`, `PLAYER_REGEN_ENABLED`. **All of
  them fire on Forever, none with a secret argument** (CS-1, in-game run 3, 2026-11-15).
- **All through `RegisterSource` with `feeds`,** so a tracker that's off costs nothing (Hard Counters decision 8).
- **Debounced:** an event marks its trackers dirty; one read per tracker at most every second, and only for trackers
  that are on. An unchanged stat isn't observed again. Built from Hard Counters' own pieces: the event sources only
  set dirty flags, and one **poll source per tracker** (interval 1 s, `feeds` = that tracker's counters) reads the
  dirty ones out of combat. A tracker that is off pauses its poll and unregisters its events.
- **Combat: stats are secret in combat** (CS-1, run 3: one in-combat probe run, four outside). Every return of
  `UnitStat`, `UnitArmor`, attack power, damage, speeds, crit, hit, haste, expertise, penetration, ratings, spell
  bonus damage and healing, mana regen, dodge, parry, block is secret in combat and a plain number out of it. Never
  secret: `GetAverageItemLevel`, `UnitHealthMax`, `UnitPowerMax`, `UnitResistance`. No arithmetic or comparison
  on a secret (Hard Counters DESIGN §3.3), so the pack **reads only out of combat** (`PLAYER_REGEN_ENABLED`
  re-reads what changed during the fight); during combat tiles show the last value read with a small "in combat"
  mark (a reading state Hard Counters doesn't have yet: HC-28). Records and upgrade deltas come from out-of-combat
  reads only. A secret value that reaches a tile anyway
  shows "Protected", like the Forever reference addon.
- **Absent on Forever:** `UnitDefense` and `UnitAttackBothHands` (CS-1), and the skill-line API `GetNumSkillLines` /
  `GetSkillLineInfo` (CS-8, Hard Counters run 3's third session, 2026-11-15: nil outdoors, in combat and in a
  dungeon; `SKILL_LINES_CHANGED` still fires). No row can read weapon skill or Defence; how the rows that need them
  are filled is §9.6.
- **Unbuffed values:** `UnitStat` gives the buff split for attributes. Other stats come buffed only. Options: read them
  when no stat-changing buffs are up, or compute from gear (tooltip scanning: expensive and fragile). Decided in
  CS-3; phase 1 may store unbuffed attributes (and resistances: `UnitResistance` returns the bonus split too) and
  buffed everything else, labelled honestly (§4.2).
- **Upgrade deltas:** on `PLAYER_EQUIPMENT_CHANGED`, keep the previous reading, read again after the debounce, show
  the difference (a tile and an optional chat line), derived rows included. Not stored in phase 1 (packs have no
  saved variables, PACKS §1.1); the upgrade log is CS-6.

## 6. Where stats show

- **Boards** (Hard Counters): any stat as a tile. One reading per counter, `scopes = { "now" }`, plus `login` min
  and max, and `today` and more when history allows. The `now` scope (a stock's current value) was built in HC-17.
  Login min and max don't exist yet: Hard Counters' login memory keeps sum, count and last per counter (HC-27).
- **Board presets,** offered when a tracker is first turned on, never forced: *Caster* (spell power for the main
  school, spell crit, spell hit and miss vs boss, mana regen while casting), *Melee* (attack power, crit, hit and
  miss vs boss, glancing, speed), *Hunter* (ranged equivalents), *Tank* (armour reduction vs boss, defence and crit
  immunity, dodge, parry, block, avoidance vs boss).
- **Built 2026-11-24: role and class boards** (the user; Hard Counters HC-57). Offered under New board, grouped by
  category; no derived rows (CS-7), so a tank board shows Defense as a bar toward its cap, not "crit immune". The
  first tile of each is large.
  - **Roles** (`category = "role"`): Tank (physical) `hcstats:tank`: Armor, Defense, Dodge, Parry, Block chance,
    Block value, Max health. Tank (spell) `hcstats:spelltank`: Max health, a Resistance tile per school, Stamina,
    Armor. Melee DPS `hcstats:melee`: Attack power, Melee crit, Hit, Main-hand DPS and speed, Strength, Agility,
    Main-hand skill. Ranged DPS `hcstats:ranged`: Ranged attack power, Ranged crit, Hit, Ranged DPS, Agility, Ranged
    speed, Ranged skill. Caster DPS `hcstats:caster`: Spell damage, Spell crit, Spell hit, Intellect, Spell
    penetration, Mana regen (casting), Max mana. Healer (direct) `hcstats:healdirect`: Bonus healing, Spell crit,
    Intellect, Max mana, Mana regen (casting). Healer (over time) `hcstats:healhot`: Bonus healing, Spirit, both
    Mana regens, Max mana, Intellect (heals over time don't crit; long fights reward mana).
  - **Classes** (`category = "class"`, with the class): one board per class, `hcstats:warrior` to `hcstats:druid`,
    covering the stats of the class's usual roles; Priest and Warlock read Spell damage for Shadow, Shaman and Druid
    for Nature. Their tip says a role board fits better while playing one role. The New board dialog lists your
    class's board under "Your class" and the other eight under "Other classes".
  - **Old keys stay** (boards remember the preset they came from): Tank, Melee and Caster are now Tank (physical),
    Melee DPS and Caster DPS; `hcstats:hunter` is the Hunter class board.
- **A Character Stats window** (an icon tab down the right edge of the Hard Counters window, since HC-69; a tab
  along the bottom since 2026-11-24): the full catalog grouped as §3, values
  coloured against thresholds (hit cap, crit immunity), with each row's description as its tooltip. Phase 2 can
  anchor it to the Character window like the reference addons; it isn't the selling point.
- **Display rules:** units shown (%, rating, skill), "≈" on derived values, an arrow for change since login, grey in
  combat.

## 7. History

Off by default, like every tracker (Hard Counters decision, 2026-11-15). The tip on these trackers sells what history
gives: "Turn on history to see how each stat grew, level by level, and keep your records." Suggested preset when
turned on: **Daily**, with the `level` dimension. Costs are small: stocks change rarely (gear, level-ups, buffs), and
history keeps API values only.

## 8. Phases (decided 2026-11-19, the user taking §10.2 and §10.3)

**Phase 1: live readings, no counters** (needs HC-28 only; CS-9's probe decides whether they stay live in combat).

1. CS-1 probes: done (run 3, 2026-11-15; §5 Combat and Absent).
2. About 15 API stats as computed `now` readings with no counters (the pattern of `hc:rested` in Basics), in
   trackers Attributes, Melee, Spell (with regen), Defence; class rules as HC-28's `applies`; in combat HC-28's
   `stale` (the last value read, marked) unless CS-9 shows a secret value can be passed straight through.
3. **No derived "≈" rows before CS-7** (hit cap, glancing, armour reduction, crit immunity, resist): a wrong cap is
   worse than none.
4. The board presets; the Character Stats window.

**As built (phase 1, 2026-11-19; not seen in game, Hard Counters checklist part Q).**

- `HardCounters_CharacterStats/Stats.lua`: five trackers of live readings only (`counters = {}`, Hard Counters
  `liveTrackers`): Attributes, Melee, **Ranged** (split out so the Hunter preset has its own switch), Spell,
  Defence; all off. 23 `now` readings: strength, agility, stamina, intellect, spirit, max health, max mana; attack
  power, crit, hit; ranged attack power, ranged crit; spell damage and spell crit (the best school of the six),
  bonus healing, spell hit, mana regen per 5 s (not casting, casting); armour, dodge, parry, block, block value.
- **In combat** each `compute` gets a secret, returns the last value it read and marks itself stale ("in combat");
  nothing read before the fight has no value. Never arithmetic on a secret. CS-9 may make them live later.
- **Live in combat (CS-9 answered in game 2026-11-19: passing a secret to `SetText`, `SetFormattedText` and
  `StatusBar:SetValue` raises no error):** the single-value stats (attributes, crit, hit, ranged crit, healing, spell
  hit, armour, dodge, parry, block, block value) declare `live`, so a plain `now` tile and the window hand the game's
  secret straight to the font string in combat, unmarked. Attack power (a sum), spell damage and spell crit (the best
  of six schools) and mana regen (×5) need arithmetic and keep the stale value. **Seen working in game
  2026-11-19** (the user: Dodge moved with Deterrence).
- **Class rules** (`applies`): intellect, mana and regen for mana classes; spell rows for casters, healing for
  healers; parry for warriors, paladins, rogues, hunters; block for warriors, paladins, shamans; ranged for hunters,
  warriors, rogues with a ranged weapon equipped; melee hit only where `GetHitModifier` exists.
- **Refresh:** each reading lists the stat events (`refresh`): Hard Counters listens only while one is on a shown
  board. The window redraws twice a second while open.
- **Presets** (`HC:RegisterBoardPreset`): Caster, Melee, Hunter, Tank, under New board. Not offered when a tracker is
  first turned on (§6): later, if wanted. Since CS-11 (2026-11-19) their tiles name a `display` and a `size` (Hard
  Counters DESIGN §16.9): the headline stat a large number, the rest half-width numbers, the skills line bars toward
  their caps, Caster's healing a line. Every stat is a stock, so `total` is the only calc and the tile menu offers no
  "Show as".
- **The window** (`UI/Window.lua`, `/hc stats`): a tab listing each section with "Turn on", then the stats this
  character uses, greyed "(in combat)" when stale, descriptions as tooltips.
- **Weapon skill and Defense (2026-11-19, from CS-8's answer):** "Main-hand skill", "Off-hand skill" (only with a
  weapon in the off hand), "Ranged skill" (only with a ranged weapon) and "Defense", each rank + `modifier` from
  `C_SkillInfo` (by id where `GetSkillLineInfoByID` answers, else walking the visible lines), the line's `maxRank` as
  the natural target, so a bar shows skill-ups toward the cap. The weapon's subclass (`GetItemInfoInstant`) names the
  skill line by its classic id (swords 43, bows 45, ..., unarmed 162, Defense 95): main-hand and off-hand bars
  matched the skill sheet in game (the user, 2026-11-19: "Numbers, correct"); other weapon types, Ranged skill and
  Defense not yet seen. In the
  presets as bars: Melee (main hand), Hunter (ranged), Tank (Defense). Skill ranks are **not secret in combat**
  (Hard Counters probe, two fights, 2026-11-19), so these read fresh mid-fight; they would fall back to the last
  value (stale) only on a secret. Unprobed: whether the equipped item id or its subclass turn secret in combat (the
  weapon rows would then read "n/a" mid-fight). A line under a collapsed header isn't found when the client has no
  by-id call.
- Not built: derived rows (CS-7), resistances and gear trackers (built 2026-11-24, below), upgrade deltas,
  thresholds.

**As built (2026-11-24; not seen in game).** The user asked for the stats still missing, role and class boards, and
names that say what each number is. Now 38 `now` readings in seven trackers.

- **New readings**, live only like the rest, each guarded (a missing call gives no value):
  - Melee: **Main-hand DPS**, **Main-hand speed**, **Off-hand DPS**, **Off-hand speed** (the off hand only with a
    weapon there). DPS is the average of `UnitDamage`'s range ÷ `UnitAttackSpeed`, attack power and buffs included
    as the game reports them. Hard Counters' formatters `decimal` ("45.3") and `seconds` ("2.60 s").
  - Melee: **Weapon skill: pick a skill** (CS-13), on Hard Counters' skill picker (HC-71), narrowed to the weapon
    skills and Defense: rank + modifier, the line's cap as the target. It needs a pick, so it has no row in the
    window.
  - Ranged: **Ranged DPS**, **Ranged speed** (`UnitRangedDamage`), with a ranged weapon equipped.
  - Spell: **Spell penetration** (`GetSpellPenetration`), for casters when the call exists.
  - Resistances (new tracker): **Resistance**, one reading with the school picked on the tile (fire, frost, nature,
    shadow, arcane; CS-14): `UnitResistance`'s buffed total. Until a school is picked its list name is "Resistance:
    pick a school"; the window shows one row per school.
  - Gear (new tracker): **Lowest durability** (the worn item that breaks first, in %) and **Average item level**
    (equipped, else overall; only when the call exists).
- **Spell damage and Spell crit** take an optional school (the six as a fixed list): none is the best school, as
  before, shown as "Spell damage (best school)"; with one, "Spell damage: Fire".
- **Names** (titles only; ids unchanged): Melee crit (was Crit), Hit (melee and ranged), Mana regen (not casting),
  Mana regen (casting), Armor, Block chance. The tracker shows as **Defense**; its id stays `hcstats:defence`.
- **CS-12:** a fist weapon reads the Unarmed skill when the character has no Fist Weapons line (seen on the
  character sheet); a client that has the line keeps it.
- **In combat:** the new single-value stats declare `live` (weapon and ranged speed, spell penetration, a
  resistance, spell damage and crit for one school), so a plain tile stays live. DPS, the best school, durability and
  item level need arithmetic or a loop and keep the last value read out of combat.
- **Probes:** every new call answered in Diagnostics' CS-1 probes on Forever (2026-11-24): it exists and returns
  numbers out of combat.
- **Presets:** seven role boards and nine class boards (§6).
- **The window** asks for the height of the rows this character uses (and again when a section is turned on), so it
  no longer scrolls for rows it doesn't show.
- Specs: `tests/stats_spec.lua`.

**Phase 2: counters, history and records,** when a player wants history for a stat: one stock counter per API stat
(§4.1), the `level` dimension, `login` (now "session", HC-49) min and max (HC-27), records of buffed maxima with
context (HC-26), upgrade deltas as a tile.

Later: the `form` dimension; the upgrade log; progression charts (Hard
Counters' chart display, HC-12, parked); anchoring the window to the Character pane.

### As built (2026-11-25): regeneration, the five-second rule, schools on the class boards

From a look at the stat addons players use (Extended Character Stats, CharacterStatsClassic, DejaClassicStats, and
on Forever: Forever Extended Character Stats, CharacterStats, SinStats) and at this client's own API documentation.
What they show that this pack lacked was regeneration beyond mana per 5, healing crit and haste; none of the big
ones shows health regen or the five-second rule.

- **Health regen**: `GetHealthRegen()` (per second: out of combat, in combat): "Health regen (out of combat)" and
  "(in combat)" per 5 seconds, and "Health per second" for boards. In the Attributes section.
- **Mana**: "Mana per second" twins of the two per-5 readings; "Mana regen from spirit"
  (`GetManaRegenFromSpirit()`). In the Spell section, where mana per 5 already was (a tile keeps working with the
  trackers a player has on).
- **Healing crit** (the spell crit of the class's healing school), **spell haste** (`UnitSpellHaste`), **melee
  haste** (`GetMeleeHaste`).
- **The five-second rule** (`hcstats:fsr`): seconds since the last spell that cost mana, 0 to 5, target 5. A clock,
  not a stat: `UNIT_SPELLCAST_SUCCEEDED` for the player and the spell's power cost (`C_Spell.GetSpellPowerCost`),
  never a comparison of mana (secret in combat). Unknown cost: the cast counts. While it runs the pack asks boards to
  redraw four times a second (`HC:ReadingsChanged`), then stops.
- **Rows:** per-second readings, haste, healing crit and the five-second rule are for boards only (`noRow`): the
  window keeps every row without a scroll bar.
- **Boards:** every role and class board of a caster ends with the five-second rule as a bar; class boards show
  the class's schools side by side (damage and crit); healers get healing crit.
- **Not offered:** spell hit by school (the game gives one number; the per-school part is talents, which this pack
  does not read), miss and glancing tables (CS-15), MP5 split into gear and buffs.
- **To see in game:** every call above answers on this client's documentation, not yet in a saved file; Diagnostics
  probes them ("CS-1 GetHealthRegen", ...). Whether `GetSpellCritChance(school)` honours its argument on Forever is
  open: the documentation lists it without one.

## 9. Open questions

1. ~~Stocks with a `stat` dimension (CS-2)~~: closed 2026-11-18, one counter per stat (§4.1). Unbuffed vs buffed is
   two counters (§4.2).
2. Unbuffed values for stats the API gives only buffed (CS-3).
3. Forever has the retail-style calls too (`GetCombatRating`, `GetHaste`, `GetExpertise`, `GetArmorPenetration`
   return numbers; CS-1). Whether they are non-zero for a character is unknown (the probe records types, not
   values): show only what returns non-zero.
4. Are Forever's combat formulas classic ones (CS-7)? Forever re-tunes content; the hit table may differ.
5. Where the upgrade log lives (CS-6).
6. **Weapon skill and Defence (CS-8):** no API reads them on Forever. Either assume the maximum skill for the level
   (5 × level) in every derived row, labelled "≈ assumes max skill", and drop the skill rows; or probe the ratings
   (`GetCombatRating` / `GetCombatRatingBonus` for the TBC-era weapon skill and defence ratings: does Forever fill
   them?) and scan `C_` namespaces for skill functions first. Forever having retail-style expertise and ratings
   (CS-1) suggests weapon skill may not exist as a mechanic at all, which only controlled tests (CS-7) can show.
   **Decided 2026-11-19 (user): probe first** (option b, in Hard Counters' Diagnostics, automatic at load).
   **Answered 2026-11-19 05:42 (Hard Counters api-surface):** `C_SkillInfo.GetSkillLineInfo(i)` (and `ByID`) gives
   every skill line as a table with `name`, `rank`, `maxRank`, `skillID`: Weapon Skills (11 lines) and Defense are
   there. Run 3 checked only the globals. So skill rows and the skill-based derived rows have a source; whether ranks
   are secret in combat is unprobed. The rows themselves wait for the user (and the derived ones for CS-7).
7. ~~The review's proposals of 2026-11-18 (§10)~~: decided 2026-11-19, §10.2 and §10.3 taken (§8).

## 10. Review of 2026-11-18 (2 and 3 decided 2026-11-19)

From the review of the suite against the dream (Hard Counters DESIGN §1.0, §16). Hard Counters' next work is
windows per tile and readings with a parameter (HC-29 to HC-34), which come **before** this pack. **The user took
2 and 3 on 2026-11-19** (§8); 1 is CS-9's probe; §4.1 (one stock counter per API stat) stands.

1. **Show live values in combat by passing them straight through.** A display may show a secret value by handing it
   to `SetText` or a status bar unchanged (Hard Counters DESIGN §3.3), yet §5 plans "the last value read" with an
   "in combat" mark. Combat is when a player looks at procs and buffs. Probe first (CS-9): can a tile show a secret
   stat in combat through `SetFormattedText` or `StatusBar:SetValue`? If yes, `now` tiles are live in combat and
   HC-28's stale state is only the fallback. Unverified on Forever.
2. **Phase 1 as live `now` readings with no counters:** about 15 API stats as computed readings (the pattern of
   `hc:rested` in Basics), which needs HC-28 but neither HC-26 nor HC-27. The ~70 counters, history by level and
   records become phase 2, when a player wants history for a stat.
3. **No "≈" derived rows before CS-7.** Players gear on a hit cap; a wrong one is worse than none. This goes against
   CS-4's "ship derived rows as ≈, don't hold phase 1 for them".
4. Readings with a parameter (HC-31) remove one of §4.1's three reasons (readings had no member filter), but 70
   stats need 70 titles, formatters and class rules either way, so the decision isn't reopened.
5. Stats are stocks read `now`: tile windows (Hard Counters DESIGN §16.3) don't apply to them; character or
   account per tile (§16.5) does only in the sense of "this character".
