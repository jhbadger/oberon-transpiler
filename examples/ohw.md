# One Hour Wargames — Implementation Plan

## Overview

A TUI computer-vs-human implementation of Neil Thomas's *One Hour Wargames* (2014).
The player picks a historical period, scenario, and army composition; the computer
controls the opposing army. Target implementation: single `ohw.mod` Oberon file,
using the existing `TUI` module, consistent with how `chessattack.mod` and other
examples work.

---

## 1. Data Model

### 1.1 Periods (9 total)

| # | Name            | Era              | Unit Types                                      |
|---|-----------------|------------------|-------------------------------------------------|
| 1 | Ancient         | 500 BC–AD 100    | Infantry, Archers, Skirmishers, Cavalry         |
| 2 | Dark Age        | AD 600–1000      | Infantry, Warband, Skirmishers, Cavalry         |
| 3 | Medieval        | AD 1000–1500     | Knights, Archers, Men-at-Arms, Levies           |
| 4 | Pike and Shot   | 1500–1700        | Infantry, Swordsmen, Reiters, Cavalry           |
| 5 | Horse & Musket  | 1700–1860        | Infantry, Cavalry, Skirmishers, Artillery       |
| 6 | Rifle & Sabre   | 1860–1900        | Infantry, Cavalry, Skirmishers, Artillery       |
| 7 | American Civil War | 1860–1865     | Infantry, Zouaves, Cavalry, Artillery           |
| 8 | Machine Age     | 1900–1939        | Infantry, Heavy Infantry, Cavalry, Artillery    |
| 9 | Second World War | 1939–1945       | Infantry, Mortars, Anti-Tank Guns, Tanks        |

### 1.2 Unit Type Constants

```
(* per period, unit IDs 0..3 — names differ by period *)
UNIT_A = 0; UNIT_B = 1; UNIT_C = 2; UNIT_D = 3;
```

Map `UNIT_A..UNIT_D` to human-readable names via a 9×4 string table keyed by period.

### 1.3 Unit Record

```
TYPE Unit = RECORD
  utype   : INTEGER;    (* 0..3 = unit type within period *)
  hits    : INTEGER;    (* 0..15; eliminated at 15 *)
  col     : INTEGER;    (* 0..11 on the 12×12 grid *)
  row     : INTEGER;
  facing  : INTEGER;    (* 0=N, 1=E, 2=S, 3=W *)
  alive   : BOOLEAN;
  ammoOut : BOOLEAN;    (* Pike & Shot only: ran out of ammo *)
  inSquare: BOOLEAN;    (* Horse & Musket optional Infantry Square *)
  entrenched : BOOLEAN; (* Machine Age optional entrenchments *)
END;
```

### 1.4 Army Record

```
TYPE Army = RECORD
  units : ARRAY 6 OF Unit;
  count : INTEGER;   (* 3, 4, or 6 depending on scenario *)
  side  : INTEGER;   (* 0=Red (human), 1=Blue (computer) *)
END;
```

### 1.5 Terrain

Grid terrain is set per scenario. Terrain types:

```
TERRAIN_OPEN   = 0;
TERRAIN_HILL   = 1;
TERRAIN_WOOD   = 2;
TERRAIN_TOWN   = 3;
TERRAIN_MARSH  = 4;
TERRAIN_LAKE   = 4;   (* same impassable rule *)
TERRAIN_RIVER  = 5;   (* passable only at ford/bridge cells *)
TERRAIN_ROAD   = 6;
TERRAIN_FORD   = 7;   (* river + crossing *)
TERRAIN_BRIDGE = 8;
```

Grid is `terrain : ARRAY 12 OF ARRAY 12 OF INTEGER`.

### 1.6 Scenario Record

```
TYPE Scenario = RECORD
  id          : INTEGER;
  name        : ARRAY 32 OF CHAR;
  redSize     : INTEGER;    (* 3, 4, or 6 *)
  blueSize    : INTEGER;
  redFirst    : BOOLEAN;    (* which side has first turn *)
  turns       : INTEGER;    (* always 15 *)
  (* Deployment and reinforcement encoded as arrays of
     DeployEvent records — see Section 3 *)
END;
```

### 1.7 Game State

```
TYPE GameState = RECORD
  period      : INTEGER;    (* 1..9 *)
  scenario    : INTEGER;    (* 1..30 *)
  turn        : INTEGER;    (* 1..15 *)
  phase       : INTEGER;    (* PHASE_MOVE, PHASE_SHOOT, PHASE_COMBAT, PHASE_ELIM *)
  activePlayer: INTEGER;    (* 0=Red, 1=Blue *)
  red         : Army;
  blue        : Army;
  grid        : ARRAY 12 OF ARRAY 12 OF INTEGER;  (* terrain *)
  chanceDeckR : ARRAY 15 OF INTEGER; (* shuffled 1..15 *)
  chanceDeckB : ARRAY 15 OF INTEGER;
  cardPosR    : INTEGER;
  cardPosB    : INTEGER;
  log         : ARRAY 8 OF ARRAY 64 OF CHAR;  (* recent event strings *)
  logHead     : INTEGER;
END;
```

---

## 2. Board Representation

The physical table is 36"×36". Map to a 12×12 grid (each cell = 3").

| Physical distance | Grid cells |
|-------------------|-----------|
| 6"  (Inf/Art move)   | 2 |
| 8"  (Reiters)        | 2 (round down) |
| 9"  (Skirmishers)    | 3 |
| 12" (Cavalry)        | 4 |
| 12" (short range)    | 4 |
| 48" (Artillery)      | 16 (effectively whole table) |

The book's scenario maps divide the table into 3×3 sectors of 12"×12", which maps
to 3×3 blocks of 4×4 cells on our grid.

TUI display: 2 characters wide per cell, yielding a 24×12 character map area.
Unit glyphs: 2-char codes (e.g. `RI` = Red Infantry, `BC` = Blue Cavalry).
Hit count shown in a separate sidebar list.

---

## 3. Scenarios (all 30)

Each scenario defines:
- Terrain layout (as a list of terrain placements)
- Army sizes for Red and Blue
- Deployment zones or specific starting cells
- Reinforcement events: `(turn, side, unitCount, entryEdge/zone, randomDie)`
- Special rules (flags, per-scenario booleans)
- Victory condition type + parameters

### 3.1 Victory Condition Types

```
VICTORY_ELIM      = 0;   (* eliminate most units *)
VICTORY_HOLD_OBJ  = 1;   (* occupy objective cell(s) at end *)
VICTORY_CONTROL_N = 2;   (* control N objectives *)
VICTORY_EXIT_N    = 3;   (* exit N units off a table edge *)
VICTORY_SURVIVE   = 4;   (* defender not eliminated by turn 15 *)
```

### 3.2 Scenario Table (summary)

| # | Name                    | Sizes  | First | Victory              |
|---|-------------------------|--------|-------|----------------------|
| 1 | Pitched Battle (1)      | 6v6    | Red   | Most eliminations    |
| 2 | Pitched Battle (2)      | 6v6    | Red   | Hold hill+crossroads |
| 3 | Control the River       | 6v6    | Red   | Hold both fords      |
| 4 | Take the High Ground    | 6v6    | Red   | Hold hill            |
| 5 | Bridgehead              | 6v6    | Red   | N bank clear         |
| 6 | Flank Attack (1)        | 6v6    | Blue  | Blue exits 3 units   |
| 7 | Flank Attack (2)        | 6v6    | Blue  | Blue holds big hill  |
| 8 | Mêlée                   | 6v6    | Blue  | Hold hill            |
| 9 | Double Delaying Action  | 6v6    | Red   | Exit/survive         |
|10 | Late Arrivals           | 6v6    | Red   | Most eliminations    |
|11 | Surprise Attack         | 6v6    | Red   | Seize objective      |
|12 | An Unfortunate Oversight| 6v6    | Blue  | Hold supply base     |
|13 | Escape                  | 4v6    | Blue  | Red exits 3 units    |
|14 | Static Defence          | 6v6    | Blue  | Red defends          |
|15 | Fortified Defence       | 6v6    | Blue  | Red survives         |
|16 | Advance Guard           | 4v4    | Red   | Hold bridge          |
|17 | Encounter               | 4v4    | Red   | Most eliminations    |
|18 | Counter-Attack          | 6v6    | Red   | Recapture obj        |
|19 | Blow from the Rear      | 6v6    | Blue  | Red breakthrough     |
|20 | Fighting Retreat        | 6v6    | Red   | Blue exits units     |
|21 | Twin Objectives         | 6v6    | Red   | Hold 2 objectives    |
|22 | Ambush                  | 6v6    | Blue  | Ambusher eliminates  |
|23 | Defence in Depth        | 6v6    | Blue  | Hold all lines       |
|24 | Bottleneck              | 6v6    | Red   | Force crossing       |
|25 | Infiltration            | 6v6    | Blue  | Units infiltrate     |
|26 | Triple Line             | 6v6    | Blue  | Break through all    |
|27 | Disordered Defence      | 6v6    | Blue  | Hold when disordered |
|28 | Botched Relief          | 6v6    | Blue  | Relieve besieged     |
|29 | Shambolic Command       | 6v6    | Blue  | Confusion scenario   |
|30 | Last Stand              | 3v6    | Blue  | Blue elims Red all   |

---

## 4. Army Composition Tables

The book's three tables (6-, 4-, 3-unit armies) are images. The tables below
are reconstructed from the period descriptions and follow the book's stated
principle: each roll gives a distinctly different force.

### Table 1 — 6-Unit Armies (roll 1d6)

Each period's four unit types are labelled A/B/C/D as in Section 1.1.

| Roll | Ancient      | Dark Age      | Medieval       | Pike&Shot     | H&M/R&S      | ACW           | Machine Age   | WWII          |
|------|-------------|---------------|----------------|---------------|--------------|---------------|---------------|---------------|
| 1    | 4A 1B 1D    | 4A 1B 1D      | 1A 2B 2C 1D    | 3A 1B 1C 1D   | 3A 1B 1C 1D  | 3A 1B 1C 1D   | 3A 1B 1C 1D   | 4A 1B 1C      |
| 2    | 3A 2B 1D    | 3A 2B 1D      | 2A 2B 1C 1D    | 3A 2B 1D      | 3A 2B 1D     | 3A 2B 1D      | 3A 2B 1D      | 4A 1B 1D      |
| 3    | 3A 1B 1C 1D | 3A 1C 1B 1D   | 2A 1B 2C 1D    | 4A 1B 1C      | 4A 1B 1D     | 4A 1C 1D      | 4A 1B 1D      | 3A 2B 1D      |
| 4    | 3A 2B 1C    | 3A 1B 2C      | 1A 3B 1C 1D    | 2A 2B 1C 1D   | 3A 1B 2D     | 2A 2B 2D      | 2A 2B 1C 1D   | 3A 1B 2D      |
| 5    | 2A 2B 1C 1D | 2A 2B 1C 1D   | 2A 1B 1C 2D    | 2A 1B 2C 1D   | 2A 2B 1C 1D  | 2A 1B 2C 1D   | 2A 1B 2C 1D   | 2A 2B 1C 1D   |
| 6    | 4A 1C 1D    | 4A 1B 1C      | 3A 1B 1C 1D    | 4A 1C 1D      | 4A 1C 1D     | 4A 1B 1D      | 3A 1B 1C 1D   | 4A 1C 1D      |

### Table 2 — 4-Unit Armies (roll 1d6)

| Roll | All periods (relative composition)              |
|------|------------------------------------------------|
| 1    | 2A 1B 1D                                       |
| 2    | 2A 1C 1D                                       |
| 3    | 3A 1D                                          |
| 4    | 1A 1B 1C 1D                                    |
| 5    | 2A 2B                                          |
| 6    | 2A 1B 1C                                       |

### Table 3 — 3-Unit Armies (roll 1d6)

| Roll | All periods (relative composition)              |
|------|------------------------------------------------|
| 1    | 2A 1D                                          |
| 2    | 2A 1B                                          |
| 3    | 1A 1B 1D                                       |
| 4    | 1A 1C 1D                                       |
| 5    | 3A                                             |
| 6    | 1A 1B 1C                                       |

*Note: these tables are reconstructions. Verify against the original images when
available and adjust. Users can also freely pick composition via a menu override.*

---

## 5. Combat Rules Engine

### 5.1 Movement

```
moveAllowance[period][utype] : INTEGER  (* in grid cells *)
```

Terrain modifiers:
- Woods: only certain unit types may enter (period-dependent)
- Marsh/Lake: impassable
- River cell: impassable unless FORD or BRIDGE
- Road: +1 cell if entire move on road, and not charging
- Hills/Towns: free to enter (no move cost) but grant defensive bonus in combat

Charge move constraints:
- May turn at most 45° (1 facing step) at start of move
- One attacker per face of target
- Skirmishers (and WWII units) may interpenetrate

### 5.2 Shooting

Shooters: varies by period (no shooting in Ancient cavalry; ACW cavalry shoots;
WWII has no hand-to-hand at all).

Field of fire: 45° arc from facing (360° for units in towns; 360° for WWII all units).

Range (cells):
- Short range (12"): 4 cells
- Artillery/mortar long range (48"): 16 cells

Casualty roll: 1d6 + modifier → hits on target:
- Modifiers by unit type (e.g. Archers -2, Heavy Infantry +2, Zouaves +2, etc.)
- Cover halves hits (round up in shooter's favour)
- Armour (Ancient Infantry) halves hits (round up in shooter's favour)

Pike & Shot ammo check: after firing, roll 1d6; on 1–2 the unit is ammo-out and may not fire again.

### 5.3 Hand-to-Hand Combat

Only applies to periods 1–5 (WWII and ACW have no H2H; Machine Age and Rifle & Sabre also no H2H).

One-sided: attacker rolls during their turn only.

Casualty roll: 1d6 + modifier → hits:
- Period-specific type modifiers (e.g. Ancient Infantry +2, Skirmishers -2)
- Terrain defender halves hits
- Armour halves hits
- Flank/rear doubles hits
- Horse & Musket Cavalry retreat 6" (2 cells) if target not eliminated

Combat only ends with elimination; units may turn to face a flank attack unless
frontally engaged.

### 5.4 Elimination

Unit eliminated at 15 hits. Remove from board, advance scenario state if needed.

### 5.5 Period-Specific Special Rules

| Period          | Special Rule                                         |
|-----------------|------------------------------------------------------|
| Pike & Shot     | Infantry/Reiters may only charge when ammo-out       |
| Horse & Musket  | Optional Infantry Square (no move/shoot, immune to cav charge) |
| Machine Age     | Optional Entrenchments + pre-game Barrage            |
| WWII            | Observation phase; Mortars use indirect fire         |
| Last Stand (S30)| Red units get +2 to all combat; Blue respawn         |

---

## 6. Chance Cards

A 15-card deck (values 1–15) is shuffled separately for each side at game start.
One card drawn per side at the start of that side's turn.

| Card(s) | Effect                                                              |
|---------|---------------------------------------------------------------------|
| 1–5     | No Event                                                            |
| 6–7     | Confusion: 1d3 own units may not move this turn (random selection) |
| 8–9     | Ammo Shortage: 1d3 own units may not shoot this turn               |
| 10      | Demoralisation: one own unit gains 1d6 hits                        |
| 11–12   | Initiative: one own unit may move twice, move+shoot, or shoot twice|
| 13–14   | Rally: 1d3 own units each remove 1d3 hits                          |
| 15      | Enemy Panic: one enemy unit gains 1d6 hits                         |

Units affected chosen uniformly at random. Deck reshuffled if exhausted.

---

## 7. AI Design

### 7.1 Foundation: Book's Solo Rules

The book specifies:
- **Deployment**: divide Blue deployment zone into left/centre/right (4 cells wide each).
  Roll 1d6: 1–2 put 3 randomly-chosen units on the left; 3–4 centre; 5–6 right.
  Roll again: 1–3 put 2 more units in one remaining sector; 4–6 in the other.
  Place the last unit in the remaining sector.
- **Reinforcements**: from 1 turn before schedule, roll each turn; arrive on 5–6.
  The arriving unit type is chosen randomly.

### 7.2 Enhanced AI: Priority Scoring

Every AI turn, for each alive AI unit, generate all legal destinations and evaluate
a score for each (move, shoot target, or charge target). Pick the highest-scoring
action.

#### Move Scoring

```
score = 0

(* Scenario-objective weight *)
if hasObjective(scenario):
  score += WEIGHT_OBJECTIVE * (prevDistToObj - newDistToObj)

(* Range positioning *)
if canShootFrom(newPos, anyEnemy):
  score += WEIGHT_IN_RANGE

(* Terrain cover *)
if terrainAt(newPos) ∈ {HILL, WOOD, TOWN}:
  score += WEIGHT_COVER

(* Flank approach: bonus if newPos is beside or behind an enemy *)
for each enemy: score += WEIGHT_FLANK * flankBonus(newPos, enemy)

(* Avoid being flanked *)
score -= WEIGHT_AVOID_FLANK * (exposedFlanksAt(newPos) - exposedFlanksAt(curPos))

(* Cohesion: penalise if moving away from friendly units *)
score -= WEIGHT_COHESION * avgDistIncrease(newPos, friendlies)
```

#### Shoot/Charge Target Scoring

```
score = baseHits(attacker, target)   (* expected hits from combat *)
      + 50 * (target.hits + expectedHits >= 15)  (* bonus for kill *)
      + 10 * isFlankOrRear            (* bonus for advantaged attack *)
      - 5 * targetInGoodTerrain       (* discount defended target *)
```

The AI always picks the highest-scoring legal action. If all scores are equal,
choose uniformly at random.

### 7.3 Role-Based Behaviour

Unit roles (overriding default scoring weights):

| Unit Role      | Examples                          | Bias                           |
|----------------|-----------------------------------|--------------------------------|
| Shock / mobile | Cavalry, Warband, Knights, Tanks  | Aggressive, seek flanks        |
| Ranged support | Archers, Artillery, Mortars       | Maintain distance, focus fire  |
| Screen         | Skirmishers                       | Stay in cover, harass          |
| Line infantry  | Infantry, Zouaves, Heavy Inf      | Hold or advance steadily       |

### 7.4 Scenario-Aware Strategy

The AI reads the `victoryCondType` and `objectiveCell(s)` from the scenario record:

- `VICTORY_ELIM`: maximise expected damage
- `VICTORY_HOLD_OBJ`: weight heavily toward keeping units on/near objective
- `VICTORY_EXIT_N`: pathfind units toward exit edge
- `VICTORY_SURVIVE`: defensive posture — stay in cover, minimise exposure

### 7.5 Difficulty Levels

Three levels accessed from the setup menu:

| Level     | Change                                              |
|-----------|-----------------------------------------------------|
| Easy      | AI picks random action 40% of the time             |
| Normal    | Full priority scoring                              |
| Hard      | Full scoring + 1 turn lookahead for key units      |

---

## 8. User Interface

### 8.1 Screen Layout

```
+------ ONE HOUR WARGAMES ------+-- LOG ---+
| Period: Horse & Musket        | Inf -> C7 |
| Scenario: 3 Control the River | Roll: 4   |
| Turn: 7  Phase: Shoot         | +2 hits   |
|                               | Cav chg   |
+-- MAP (24×12) ----------------+ Roll: 6   |
|. . H H . . . . . . . .       | Kills Sk! |
|. . H RI. . . . . . . .       |           |
|. . . . . . . . . . . .       |           |
|. . . . . . BC. . . . .       |           |
|~~~~. . . . . . . . . .       |           |
|. . F . . . . . . . . .       |           |
...
+-- UNITS -------------------------+
| [Red] Inf(0) Cav(3) Skm(0) Art(12)
| [Blue] Inf(0) Cav(7) Skm(3) Art(5)
+----------------------------------+
Cursor: D4  [Arrows=move] [Enter=select] [S=shoot] [Q=quit]
```

- `H` = hill, `~` = river, `F` = ford/bridge, `T` = town, `W` = wood
- Unit glyphs: first char = side (R/B), second = type initial
- Selected unit shown with inverse/highlight
- Cursor navigation with arrow keys; Enter to select/confirm

### 8.2 Menu Flow

```
Main Menu
  ├── New Game
  │     ├── Choose Period (1–9 with descriptions)
  │     ├── Choose Scenario (1–30 with one-line summaries)
  │     ├── Army Composition
  │     │     ├── Auto-roll (book method)
  │     │     └── Manual pick
  │     ├── Difficulty (Easy / Normal / Hard)
  │     └── Start
  ├── Rules Reference (per-period quick-ref card)
  └── Quit
```

### 8.3 Player Turn Flow

```
1. Draw Chance Card (display result if any effect)
2. Movement Phase:
   a. Highlight movable units
   b. Player selects unit (Enter)
   c. Valid moves shown; player moves cursor to destination
   d. Confirm move (Enter) or cancel (Esc)
   e. Repeat for remaining units
3. Shooting Phase (if applicable):
   a. Eligible shooters highlighted
   b. Player selects shooter, then target
   c. Dice roll shown with modifiers; hits applied
4. H2H Combat Phase (if applicable):
   a. Units in contact shown; resolve automatically
   b. Dice + modifiers displayed in log
5. Elimination check: flash eliminated units, remove
6. Victory check: announce if conditions met
7. AI turn (animated, ~0.3s per action)
```

---

## 9. Implementation Phases

### Phase 1 — Engine Core
- `Unit`, `Army`, `GameState` TYPE declarations
- Combat resolution functions (shoot, H2H, charge)
- Movement validation (terrain, interpenetration, charge rules)
- Elimination and victory checking
- Dice utilities (d6, d3, shuffle deck)

### Phase 2 — Period Lookup Tables
- Movement allowance table: `moveAllow[9][4]`
- Shoot modifier table: `shootMod[9][4]`
- Combat modifier table: `combatMod[9][4]` (H2H periods only)
- Terrain restriction table: which unit types enter which terrain
- Shoot eligibility table: which unit types may shoot (and range)
- H2H eligibility: which periods/types engage in melee

### Phase 3 — All 30 Scenarios
- Terrain grid definitions (stored as compressed strings or init arrays)
- Reinforcement event arrays
- Special rule flags per scenario
- Victory condition parameters

### Phase 4 — TUI Display
- Grid renderer (terrain glyphs, unit glyphs, cursor, highlights)
- Sidebar log (last 8 events)
- Unit list panel (hits per unit)
- Menu system (period/scenario/army pickers)
- Animated AI move display

### Phase 5 — AI
- Deployment randomisation (book method)
- Per-unit action scorer
- Objective-awareness by scenario
- Difficulty level toggle

### Phase 6 — Army Composition
- Roll-and-display for Tables 1/2/3
- Manual picker override
- Re-roll on duplicate detection

### Phase 7 — Chance Cards + Polish
- Shuffle/deal deck
- Card effect applier
- Machine Age optional entrenchment/barrage pre-game
- Horse & Musket optional Square formation toggle
- Rules quick-reference viewer

---

## 10. Key Constants (ohw.mod)

```oberon
CONST
  GRID_W   = 12;  GRID_H = 12;  (* cells *)
  CELL_PX  = 2;                  (* chars per cell horizontally *)
  MAX_HITS = 15;
  MAX_UNITS = 6;
  TURNS    = 15;

  (* Phase IDs *)
  PH_MOVE  = 0;  PH_OBS  = 1;  (* OBS = WWII observation *)
  PH_SHOOT = 2;  PH_COMBAT = 3;  PH_ELIM = 4;

  (* Side IDs *)
  RED = 0;  BLUE = 1;

  (* Facing *)
  NORTH = 0;  EAST = 1;  SOUTH = 2;  WEST = 3;
```

---

## 11. Open Questions / Decisions Needed

1. **Army composition tables**: the three tables are images in the source PDF.
   The reconstructions above are reasonable but should be verified. If the original
   images can be extracted, hard-code the exact die-result compositions.

2. **Scenario terrain maps**: also encoded as images in the book. Each scenario's
   terrain must be hand-transcribed from the maps. There are 30 maps to encode.
   Encoding approach: store each map as a 9×9 array of sector types, then expand
   to 12×12 during init.

3. **Language choice**: the plan assumes Oberon `.mod` (consistent with the repo).
   If a standalone C or Python prototype is preferred for faster iteration, the
   data model and AI logic above are language-agnostic.

4. **Rifle & Sabre vs Horse & Musket**: these share unit types but differ in combat
   modifiers (Rifle & Sabre infantry/artillery are more lethal; cavalry less so).
   Should they share a period enum value with a sub-flag, or be fully separate?
   Recommendation: fully separate entries in the lookup tables for clarity.

5. **WWII casualty tables**: the book uses a 2D matrix (attacker type × defender type)
   stored as an image. Reconstruct or leave as a tunable parameter array.
