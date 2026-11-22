# Hard Counters: Traveler — design as built (first edition, 2026-11-22)

What the client gives, as probed on Forever (Hard Counters' `docs/api-surface.md` has the verdicts): `UnitPosition`
is plain in combat outdoors and nil inside instances; its height is always 0; every movement flag (`IsFalling`,
`IsSwimming`, `IsMounted`, `UnitOnTaxi`, `UnitIsGhost`...) is plain in combat; `GetUnitSpeed` is secret in combat;
the player's spell IDs are plain in combat; auras are not readable in combat; a secure post-hook on
`JumpOrAscendStart` fires for every spacebar press (on the ground, in mid-air, in water); a paladin's auras are
shapeshift forms.

## 1. The model (`Motion.lua`)

One poll, `hctravel:pos`: 4 times a second on foot, swimming or in the air, twice mounted, once a second on a
flight, a boat or standing still (a spacebar press brings it back to 4). Each read gives the position, the flags,
the zone key and, out of combat, the game's speed.

- **Mode of a stretch**, first match: taxi, vehicle, ghost, flying, swim / dive (aquatic form), carried (the
  position moves while the game says you stand: two such reads in a row; the read you stop on belongs to the mode
  you were in), travel form (Travel Form, Ghost Wolf: by spell, since auras are forms too), mounted, walk (slower
  than half the run speed: the game's speed out of combat, two slow reads in a row in a fight), run.
- **Time moving** is each read's gap, except the read you start or stop on: there it is the yards at the speed you
  were going (a start may follow a 1 s still read).
- **Jumps** (the same `mode` dimension): a blink or leap (8 to 40 yards in one read within 1.5 s of Blink, Charge,
  Intercept or Feral Charge; without the spell, a knockback: dropped); across a loading screen or more than 40
  yards in one read: spirit (the ghost state just turned on), hearth or teleport (the spell in the 30 s before), a
  summon (offered in the 2 minutes before), transport (a boat ride in the 15 s before), an instance door (the zone
  key crosses 100000), else "other". Yards when both ends share a continent; between continents a count and 0
  yards. Back where it was after a loading screen (a `/reload`): nothing.
- Spells are known by Classic's IDs and by their localized names, so a Forever-only ID with the same name matches.
- **Inside dungeons** there is no position: distance is the game's speed × time, out of combat only (an under-count;
  the readings say so). No legs or top speed from estimates.
- **Legs**: one mode, no stop over 3 s, no jump; written when they end (and at logout) for the modes under your
  own power. **Top speed**: over windows of 2 s or more inside a leg, the same modes.
- **Spacebar jumps**: counted at the press when on the ground (not falling, swimming or on a taxi); the take-off
  within 0.75 s gives its air time. A take-off with no press is a fall, counted from 1 s in the air; with Slow Fall
  or Levitate (read out of combat) a slow fall.
- **Deaths**: the release is a `spirit` jump; the corpse run is `ghost` distance; back alive near the corpse (or
  nowhere known) a corpse run, after the spirit healer's dialog or farther than 60 yards from the corpse a spirit
  healer visit. The distance to the corpse comes from `C_DeathInfo.GetCorpseMapPosition` and the player's map
  position, both through `C_Map.GetWorldPosFromMapPos`. Not yet seen in game.
- **Flights**: from take-off to landing; where from and to are taxi node IDs from the flight master's map at
  `TakeTaxiNode` (names kept for the session only, for labels).

## 2. Counters, trackers, readings

| Counter | Measures | Dimensions |
|---|---|---|
| `hctravel:dist` (yards) | sum | mode (32), zone (400) |
| `hctravel:time` (seconds) | sum | mode, zone |
| `hctravel:jumps` | sum (1 a jump) | mode |
| `hctravel:leg` (yards) | sum, count, max (+zone, mode, sec) | mode |
| `hctravel:speed` (yd/s) | max (+zone, mode) | mode |
| `hctravel:hop` | sum (1 each) | kind (jump, fall, float), mode |
| `hctravel:airtime` (seconds) | sum, max | kind |
| `hctravel:corpse`, `hctravel:healer` | sum (1 each) | |
| `hctravel:flight` (yards) | sum, count, max (+from, to, sec) | from, to (taxi node IDs) |

Trackers **Distance** (all but flights) and **Flights**, off for a fresh install like every pack's.

Readings: Distance travelled, Time moving, Average speed (yd/s and %), each with the tile's filter of modes (On
foot, Under my own power, Everything but teleports: the default, Everything, or a checklist); Teleports and blinks
(a filter of the jump modes); Jumps (jumps, falls); Time in the air; Top speed (yd/s and %), Farthest without
stopping, Longest time in the air, Longest flight (best single values: a board's timer and the history periods);
Speed now (yd/s and %, from position, so it works in combat); Corpse runs, Spirit healer visits, Corpse (yards,
while a ghost); Flights taken, Distance flown.

Boards: **Trip** (Distance travelled as an odometer, Time moving as a mix, On foot, Mounted, Average and Top speed,
Speed now, Flights taken) and **Flight log**.

## 3. Not in this edition

Speed boosts as a dimension, places and exploration (visits, discoveries, x of y), per-mode records ("longest
swim"), mounted jumps, routes as a parameter, the hearthstone cooldown, keeping an open leg across `/reload`,
marking estimated dungeon distance on the tile, and the fun lines (steps, marathons, moonwalk). They are queued.
