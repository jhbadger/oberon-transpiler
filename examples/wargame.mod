MODULE Wargame;
(*
 * One Hour Wargames — Neil Thomas (2014)
 * Human (Red, north) vs Computer (Blue, south).
 *
 * Setup: choose period → choose scenario → roll army composition.
 * Scenarios: 0=random (open ground), 1=Pitched Battle (two hill groups).
 * Victory: eliminate all enemy units within 15 turns.
 *
 * Controls:
 *   Arrow keys  – move cursor
 *   Enter       – select unit / confirm move or shot
 *   Esc         – cancel selection
 *   N           – end current phase / pass
 *   Q / Ctrl-Q  – quit
 *)

IMPORT TUI, Random;

CONST
  GRID_W   = 12;  GRID_H  = 12;
  MAX_HITS = 15;  MAX_UNITS = 6;
  TURNS    = 15;

  RED  = 0;  BLUE  = 1;

  NORTH = 0;  EAST = 1;  SOUTH = 2;  WEST = 3;

  PH_MOVE   = 0;
  PH_SHOOT  = 1;
  PH_COMBAT = 2;
  PH_ELIM   = 3;

  (* Terrain types — only OPEN used in v1; others reserved for future scenarios *)
  TERR_OPEN   = 0;  TERR_HILL  = 1;  TERR_WOOD  = 2;
  TERR_TOWN   = 3;  TERR_MARSH = 4;  TERR_RIVER = 5;
  TERR_FORD   = 6;  TERR_BRIDGE = 7;

  (* Victory condition types — v1 uses ELIM only *)
  VIC_ELIM   = 0;  VIC_HOLD  = 1;
  VIC_EXIT   = 2;  VIC_SURVIVE = 3;

  (* Scenario numbers *)
  SCEN_RANDOM = 0;   (* open ground, random army roll *)
  SCEN_1      = 1;   (* Pitched Battle — two hill groups *)
  SCEN_2      = 2;   (* Crossroads — hill + road junction objective *)
  SCEN_3      = 3;   (* Control the River — hold both bridges at turn 15 *)

  TERR_ROAD = 8;     (* road: +1 move if entire move stays on road *)

  (* Victory condition types for territory scenarios *)
  VIC_BRIDGES = 2;   (* reuses VIC_EXIT slot; hold both river bridges *)

  (* Scenario 2 objective locations *)
  CROSS_COL = 10;  CROSS_ROW = 9;

  (* Scenario 3 bridge locations (both on row 6) *)
  BRIDGE_ROW  = 6;
  BRIDGE1_COL = 1;
  BRIDGE2_COL = 9;

  (* Info panel in the gap between map (cols 3-26) and sidebar (col 46) *)
  PANX = 29;   (* MAPX + GRID_W*2 + 2 *)
  PANY = 4;    (* MAPY + 1 *)
  PANW = 16;   (* SIDEX - PANX - 1 *)

  NPER = 9;
  NO_FIRE = -99;  (* unit type may not fire in this period *)
  NO_H2H  = -99;  (* unit type may not enter hand-to-hand *)

  (* Display geometry *)
  MAPX = 3;   (* screen col of cell (0,0) *)
  MAPY = 3;   (* screen row of cell (0,0) *)
  SIDEX = 46; (* screen col for right sidebar *)

TYPE
  Unit = RECORD
    utype      : INTEGER;   (* 0..3, indexes period tables *)
    hits       : INTEGER;   (* accumulated hits; eliminated at MAX_HITS *)
    col, row   : INTEGER;   (* 0..GRID_W-1, 0..GRID_H-1 *)
    facing     : INTEGER;   (* NORTH/EAST/SOUTH/WEST *)
    alive      : BOOLEAN;
    ammoOut    : BOOLEAN;   (* Pike & Shot: out of ammunition *)
    inSquare   : BOOLEAN;   (* Horse & Musket optional infantry square *)
    entrenched : BOOLEAN;   (* Machine Age optional entrenchment *)
    moved      : BOOLEAN;   (* already moved this turn *)
    shot       : BOOLEAN;   (* already shot this turn *)
  END;

  Army = RECORD
    units : ARRAY MAX_UNITS OF Unit;
    count : INTEGER;
    side  : INTEGER;
  END;

VAR
  period       : INTEGER;   (* 1..9 *)
  turn         : INTEGER;   (* 1..15 *)
  phase        : INTEGER;
  activeSide   : INTEGER;   (* RED or BLUE *)
  red, blue    : Army;

  (* terrain[row][col] — all TERR_OPEN in v1 *)
  terrain : ARRAY GRID_H OF ARRAY GRID_W OF INTEGER;

  victoryType : INTEGER;   (* VIC_* constant; hook for scenario variants *)
  scenario    : INTEGER;   (* SCEN_* constant *)

  msgLog    : ARRAY 8 OF ARRAY 64 OF CHAR;
  logHead : INTEGER;

  (* UI state *)
  curCol, curRow : INTEGER;
  selUnit        : INTEGER;   (* index into activeSide's army, -1=none *)

  ev       : TUI.Event;
  gameOver : BOOLEAN;

  (* Undo stack for movement phase — cleared when phase advances to PH_SHOOT *)
  undoIdx    : ARRAY MAX_UNITS OF INTEGER;
  undoCol    : ARRAY MAX_UNITS OF INTEGER;
  undoRow    : ARRAY MAX_UNITS OF INTEGER;
  undoFacing : ARRAY MAX_UNITS OF INTEGER;
  undoMoved  : ARRAY MAX_UNITS OF BOOLEAN;
  undoTop    : INTEGER;

  (* ─── Period lookup tables [period-1][utype] ─── *)
  (* unitName[p][t] = display name (max 14 chars) *)
  unitName  : ARRAY NPER OF ARRAY 4 OF ARRAY 16 OF CHAR;
  (* unitGlyph[p][t] = single-char identifier for map display *)
  unitGlyph : ARRAY NPER OF ARRAY 4 OF CHAR;
  (* moveAllow[p][t] = movement allowance in grid cells *)
  moveAllow : ARRAY NPER OF ARRAY 4 OF INTEGER;
  (* shootMod[p][t] = die modifier when shooting (NO_FIRE = cannot shoot) *)
  shootMod  : ARRAY NPER OF ARRAY 4 OF INTEGER;
  (* shootRange[p][t] = range in cells (NO_FIRE = cannot shoot) *)
  shootRange : ARRAY NPER OF ARRAY 4 OF INTEGER;
  (* h2hMod[p][t] = die modifier for H2H combat (NO_H2H = cannot melee) *)
  h2hMod    : ARRAY NPER OF ARRAY 4 OF INTEGER;
  (* hasArmour[p][t] = TRUE: unit halves incoming hits *)
  hasArmour : ARRAY NPER OF ARRAY 4 OF BOOLEAN;
  (* canMoveShoot[p][t] = TRUE: allowed to shoot after moving *)
  canMoveShoot : ARRAY NPER OF ARRAY 4 OF BOOLEAN;
  (* canWoods[p][t] = TRUE: may enter woods (hook for terrain) *)
  canWoods  : ARRAY NPER OF ARRAY 4 OF BOOLEAN;
  (* canTown[p][t] = TRUE: may end move in town (hook for terrain) *)
  canTown   : ARRAY NPER OF ARRAY 4 OF BOOLEAN;

  periodName : ARRAY NPER OF ARRAY 24 OF CHAR;

  (* Army composition table [period-1][die1-1][unit-slot] *)
  compTable : ARRAY NPER OF ARRAY 6 OF ARRAY MAX_UNITS OF INTEGER;

(* ═══════════════════════════════════════════════════════════════════════ *)
(*  Table Initialisation                                                    *)
(* ═══════════════════════════════════════════════════════════════════════ *)

PROCEDURE SetUnit(p, t: INTEGER; name: ARRAY OF CHAR; glyph: CHAR;
                  mv, sMod, sRng, hMod: INTEGER;
                  armour, mvShoot, woods, town: BOOLEAN);
BEGIN
  COPY(name, unitName[p][t]);
  unitGlyph[p][t]    := glyph;
  moveAllow[p][t]    := mv;
  shootMod[p][t]     := sMod;
  shootRange[p][t]   := sRng;
  h2hMod[p][t]       := hMod;
  hasArmour[p][t]    := armour;
  canMoveShoot[p][t] := mvShoot;
  canWoods[p][t]     := woods;
  canTown[p][t]      := town
END SetUnit;

PROCEDURE SetComp(p, roll: INTEGER; a, b, c, d, e, f: INTEGER);
BEGIN
  compTable[p][roll][0] := a;  compTable[p][roll][1] := b;
  compTable[p][roll][2] := c;  compTable[p][roll][3] := d;
  compTable[p][roll][4] := e;  compTable[p][roll][5] := f
END SetComp;

PROCEDURE InitTables;
VAR p, t: INTEGER;
BEGIN
  (* ── default: nothing set ── *)
  FOR p := 0 TO NPER - 1 DO
    FOR t := 0 TO 3 DO
      COPY("???", unitName[p][t]);
      unitGlyph[p][t]    := '?';
      moveAllow[p][t]    := 2;
      shootMod[p][t]     := NO_FIRE;
      shootRange[p][t]   := NO_FIRE;
      h2hMod[p][t]       := 0;
      hasArmour[p][t]    := FALSE;
      canMoveShoot[p][t] := FALSE;
      canWoods[p][t]     := FALSE;
      canTown[p][t]      := TRUE
    END
  END;

  (* ── Period 1: Ancient (A=Infantry B=Archers C=Skirmishers D=Cavalry) ── *)
  COPY("Ancient", periodName[0]);
  (*                  name          glyph mv  sMod sRng  hMod  arm   mvS   wds   twn *)
  SetUnit(0,0, "Infantry",    'I', 2, NO_FIRE,  NO_FIRE, 2, TRUE,  FALSE, FALSE, TRUE);
  SetUnit(0,1, "Archers",     'A', 2,  0,        4,      0, FALSE, FALSE, FALSE, TRUE);
  SetUnit(0,2, "Skirmishers", 'S', 3, -2,        4,     -2, FALSE, FALSE, TRUE,  TRUE);
  SetUnit(0,3, "Cavalry",     'C', 4, NO_FIRE,  NO_FIRE, 0, FALSE, FALSE, FALSE, TRUE);

  (* ── Period 2: Dark Age (A=Infantry B=Warband C=Skirmishers D=Cavalry) ── *)
  COPY("Dark Age", periodName[1]);
  SetUnit(1,0, "Infantry",    'I', 2, NO_FIRE, NO_FIRE,  0, TRUE,  FALSE, FALSE, TRUE);
  SetUnit(1,1, "Warband",     'W', 3, NO_FIRE, NO_FIRE,  2, FALSE, FALSE, FALSE, TRUE);
  SetUnit(1,2, "Skirmishers", 'S', 3, -2,       4,      -2, FALSE, FALSE, TRUE,  TRUE);
  SetUnit(1,3, "Cavalry",     'C', 4, NO_FIRE, NO_FIRE,  0, FALSE, FALSE, FALSE, TRUE);

  (* ── Period 3: Medieval (A=Knights B=Archers C=Men-at-Arms D=Levies) ── *)
  COPY("Medieval", periodName[2]);
  (* Medieval woods are impassable to all *)
  SetUnit(2,0, "Knights",     'K', 4, NO_FIRE, NO_FIRE,  2, FALSE, FALSE, FALSE, TRUE);
  SetUnit(2,1, "Archers",     'A', 2,  2,       4,      -2, FALSE, FALSE, FALSE, TRUE);
  SetUnit(2,2, "Men-at-Arms", 'M', 2, NO_FIRE, NO_FIRE,  0, TRUE,  FALSE, FALSE, TRUE);
  SetUnit(2,3, "Levies",      'L', 2, NO_FIRE, NO_FIRE,  0, FALSE, FALSE, FALSE, TRUE);

  (* ── Period 4: Pike & Shot (A=Infantry B=Swordsmen C=Reiters D=Cavalry) ── *)
  COPY("Pike & Shot", periodName[3]);
  (* Infantry/Reiters may shoot after moving; only Swordsmen enter woods *)
  SetUnit(3,0, "Infantry",    'I', 2,  0,  4,  0, FALSE, TRUE,  FALSE, FALSE);
  SetUnit(3,1, "Swordsmen",   'W', 2, NO_FIRE, NO_FIRE,  2, FALSE, FALSE, TRUE,  TRUE);
  SetUnit(3,2, "Reiters",     'R', 2,  0,  4,  0, FALSE, TRUE,  FALSE, FALSE);
  SetUnit(3,3, "Cavalry",     'C', 4, NO_FIRE, NO_FIRE,  2, FALSE, FALSE, FALSE, FALSE);

  (* ── Period 5: Horse & Musket (A=Infantry B=Cavalry C=Skirmishers D=Artillery) ── *)
  COPY("Horse & Musket", periodName[4]);
  (* Only Cavalry can charge in H2H; Infantry/Skirmishers may enter town *)
  SetUnit(4,0, "Infantry",    'I', 2,  0,  4,    NO_H2H, FALSE, FALSE, FALSE, TRUE);
  SetUnit(4,1, "Cavalry",     'C', 4, NO_FIRE, NO_FIRE,  2, FALSE, FALSE, FALSE, FALSE);
  SetUnit(4,2, "Skirmishers", 'S', 3, -2,  4,    NO_H2H, FALSE, FALSE, TRUE,  TRUE);
  SetUnit(4,3, "Artillery",   'A', 2, -2,  16,   NO_H2H, FALSE, FALSE, FALSE, FALSE);

  (* ── Period 6: Rifle & Sabre (same unit types as H&M, different modifiers) ── *)
  COPY("Rifle & Sabre", periodName[5]);
  SetUnit(5,0, "Infantry",    'I', 2,  2,  4,    NO_H2H, FALSE, FALSE, FALSE, TRUE);
  SetUnit(5,1, "Cavalry",     'C', 4, NO_FIRE, NO_FIRE,  0, FALSE, FALSE, FALSE, FALSE);
  SetUnit(5,2, "Skirmishers", 'S', 3,  0,  4,    NO_H2H, FALSE, FALSE, TRUE,  TRUE);
  SetUnit(5,3, "Artillery",   'A', 2,  0,  16,   NO_H2H, FALSE, FALSE, FALSE, FALSE);

  (* ── Period 7: American Civil War (A=Infantry B=Zouaves C=Cavalry D=Artillery) ── *)
  COPY("Amer. Civil War", periodName[6]);
  (* No H2H at all; Infantry/Zouaves enter woods and towns *)
  SetUnit(6,0, "Infantry",    'I', 2,  0,  4,    NO_H2H, FALSE, FALSE, TRUE,  TRUE);
  SetUnit(6,1, "Zouaves",     'Z', 3,  2,  4,    NO_H2H, FALSE, FALSE, TRUE,  TRUE);
  SetUnit(6,2, "Cavalry",     'C', 4, -2,  4,    NO_H2H, FALSE, FALSE, FALSE, FALSE);
  SetUnit(6,3, "Artillery",   'A', 2, -2,  16,   NO_H2H, FALSE, FALSE, FALSE, FALSE);

  (* ── Period 8: Machine Age (A=Infantry B=Heavy Inf C=Cavalry D=Artillery) ── *)
  COPY("Machine Age", periodName[7]);
  (* No H2H; Infantry/Heavy Infantry enter woods and towns *)
  SetUnit(7,0, "Infantry",    'I', 2,  0,  4,    NO_H2H, FALSE, FALSE, TRUE,  TRUE);
  SetUnit(7,1, "Heavy Inf",   'H', 2,  2,  4,    NO_H2H, FALSE, FALSE, TRUE,  TRUE);
  SetUnit(7,2, "Cavalry",     'C', 4, -2,  4,    NO_H2H, FALSE, FALSE, FALSE, FALSE);
  SetUnit(7,3, "Artillery",   'A', 2,  0,  16,   NO_H2H, FALSE, FALSE, FALSE, FALSE);

  (* ── Period 9: WWII (A=Infantry B=Mortars C=Anti-Tank Guns D=Tanks) ── *)
  COPY("WWII", periodName[8]);
  (* 360-degree fire for all; only Infantry enter woods/towns;
     WWII combat table is an image in the source — values below are approximate *)
  SetUnit(8,0, "Infantry",    'I', 2,  0,  4,    NO_H2H, FALSE, FALSE, TRUE,  TRUE);
  SetUnit(8,1, "Mortars",     'M', 2,  0, 16,    NO_H2H, FALSE, FALSE, FALSE, FALSE);
  SetUnit(8,2, "Anti-Tank",   'T', 2,  0,  4,    NO_H2H, FALSE, FALSE, FALSE, FALSE);
  SetUnit(8,3, "Tanks",       'K', 4,  0,  4,    NO_H2H, FALSE, FALSE, FALSE, FALSE);

  (* ── Army Composition Tables (6-unit armies, die 1..6) ── *)
  (* Ancient *)
  SetComp(0,0, 0,0,0,0,1,3);   (* 4I 1A 1C *)
  SetComp(0,1, 0,0,0,1,1,3);   (* 3I 2A 1C *)
  SetComp(0,2, 0,0,0,1,2,3);   (* 3I 1A 1S 1C *)
  SetComp(0,3, 0,0,0,1,1,2);   (* 3I 2A 1S *)
  SetComp(0,4, 0,0,1,1,2,3);   (* 2I 2A 1S 1C *)
  SetComp(0,5, 0,0,0,0,2,3);   (* 4I 1S 1C *)

  (* Dark Age *)
  SetComp(1,0, 0,0,0,0,1,3);   (* 4I 1W 1C *)
  SetComp(1,1, 0,0,0,1,1,3);   (* 3I 2W 1C *)
  SetComp(1,2, 0,0,0,1,2,3);   (* 3I 1W 1S 1C *)
  SetComp(1,3, 0,0,0,1,2,2);   (* 3I 1W 2S *)
  SetComp(1,4, 0,0,1,1,2,3);   (* 2I 2W 1S 1C *)
  SetComp(1,5, 0,0,0,0,1,2);   (* 4I 1W 1S *)

  (* Medieval *)
  SetComp(2,0, 0,1,1,2,2,3);   (* 1K 2A 2M 1L *)
  SetComp(2,1, 0,0,1,1,2,3);   (* 2K 2A 1M 1L *)
  SetComp(2,2, 0,0,1,2,2,3);   (* 2K 1A 2M 1L *)
  SetComp(2,3, 0,1,1,1,2,3);   (* 1K 3A 1M 1L *)
  SetComp(2,4, 0,0,1,2,3,3);   (* 2K 1A 1M 2L *)
  SetComp(2,5, 0,0,0,1,2,3);   (* 3K 1A 1M 1L *)

  (* Pike & Shot *)
  SetComp(3,0, 0,0,0,1,2,3);   (* 3I 1W 1R 1C *)
  SetComp(3,1, 0,0,0,1,1,3);   (* 3I 2W 1C *)
  SetComp(3,2, 0,0,0,0,1,2);   (* 4I 1W 1R *)
  SetComp(3,3, 0,0,1,1,2,3);   (* 2I 2W 1R 1C *)
  SetComp(3,4, 0,0,1,2,2,3);   (* 2I 1W 2R 1C *)
  SetComp(3,5, 0,0,0,0,2,3);   (* 4I 1R 1C *)

  (* Horse & Musket *)
  SetComp(4,0, 0,0,0,1,2,3);   (* 3I 1C 1S 1A *)
  SetComp(4,1, 0,0,0,1,1,3);   (* 3I 2C 1A *)
  SetComp(4,2, 0,0,0,0,1,3);   (* 4I 1C 1A *)
  SetComp(4,3, 0,0,0,1,3,3);   (* 3I 1C 2A *)
  SetComp(4,4, 0,0,1,1,2,3);   (* 2I 2C 1S 1A *)
  SetComp(4,5, 0,0,0,0,2,3);   (* 4I 1S 1A *)

  (* Rifle & Sabre — same composition as Horse & Musket *)
  SetComp(5,0, 0,0,0,1,2,3);
  SetComp(5,1, 0,0,0,1,1,3);
  SetComp(5,2, 0,0,0,0,1,3);
  SetComp(5,3, 0,0,0,1,3,3);
  SetComp(5,4, 0,0,1,1,2,3);
  SetComp(5,5, 0,0,0,0,2,3);

  (* American Civil War *)
  SetComp(6,0, 0,0,0,1,2,3);   (* 3I 1Z 1C 1A *)
  SetComp(6,1, 0,0,0,1,1,3);   (* 3I 2Z 1A *)
  SetComp(6,2, 0,0,0,0,2,3);   (* 4I 1C 1A *)
  SetComp(6,3, 0,0,1,1,3,3);   (* 2I 2Z 2A *)
  SetComp(6,4, 0,0,1,2,2,3);   (* 2I 1Z 2C 1A *)
  SetComp(6,5, 0,0,0,0,1,3);   (* 4I 1Z 1A *)

  (* Machine Age *)
  SetComp(7,0, 0,0,0,1,2,3);   (* 3I 1H 1C 1A *)
  SetComp(7,1, 0,0,0,1,1,3);   (* 3I 2H 1A *)
  SetComp(7,2, 0,0,0,0,1,3);   (* 4I 1H 1A *)
  SetComp(7,3, 0,0,1,1,2,3);   (* 2I 2H 1C 1A *)
  SetComp(7,4, 0,0,1,2,2,3);   (* 2I 1H 2C 1A *)
  SetComp(7,5, 0,0,0,1,2,3);   (* 3I 1H 1C 1A *)

  (* WWII *)
  SetComp(8,0, 0,0,0,0,1,2);   (* 4I 1M 1T *)
  SetComp(8,1, 0,0,0,0,1,3);   (* 4I 1M 1K *)
  SetComp(8,2, 0,0,0,1,1,3);   (* 3I 2M 1K *)
  SetComp(8,3, 0,0,0,1,3,3);   (* 3I 1M 2K *)
  SetComp(8,4, 0,0,1,1,2,3);   (* 2I 2M 1T 1K *)
  SetComp(8,5, 0,0,0,0,2,3)    (* 4I 1T 1K *)
END InitTables;

(* ═══════════════════════════════════════════════════════════════════════ *)
(*  Utility                                                                 *)
(* ═══════════════════════════════════════════════════════════════════════ *)

PROCEDURE D6(): INTEGER;
BEGIN RETURN Random.Int(6) + 1 END D6;

PROCEDURE ArmyOf(side: INTEGER): Army;
BEGIN
  IF side = RED THEN RETURN red ELSE RETURN blue END
END ArmyOf;

PROCEDURE SetArmy(side: INTEGER; a: Army);
BEGIN
  IF side = RED THEN red := a ELSE blue := a END
END SetArmy;

PROCEDURE UnitAt(col, row: INTEGER; VAR side, idx: INTEGER);
VAR i: INTEGER;
BEGIN
  side := -1; idx := -1;
  FOR i := 0 TO red.count - 1 DO
    IF red.units[i].alive & (red.units[i].col = col) & (red.units[i].row = row) THEN
      side := RED; idx := i; RETURN
    END
  END;
  FOR i := 0 TO blue.count - 1 DO
    IF blue.units[i].alive & (blue.units[i].col = col) & (blue.units[i].row = row) THEN
      side := BLUE; idx := i; RETURN
    END
  END
END UnitAt;

PROCEDURE OccupiedBy(col, row, side: INTEGER): BOOLEAN;
VAR a: Army;  i: INTEGER;
BEGIN
  a := ArmyOf(side);
  FOR i := 0 TO a.count - 1 DO
    IF a.units[i].alive & (a.units[i].col = col) & (a.units[i].row = row) THEN
      RETURN TRUE
    END
  END;
  RETURN FALSE
END OccupiedBy;

PROCEDURE Abs(n: INTEGER): INTEGER;
BEGIN IF n < 0 THEN RETURN -n ELSE RETURN n END END Abs;

PROCEDURE Max(a, b: INTEGER): INTEGER;
BEGIN IF a > b THEN RETURN a ELSE RETURN b END END Max;

PROCEDURE Min(a, b: INTEGER): INTEGER;
BEGIN IF a < b THEN RETURN a ELSE RETURN b END END Min;

(* Chebyshev distance *)
PROCEDURE CDist(c1, r1, c2, r2: INTEGER): INTEGER;
BEGIN RETURN Max(Abs(c1 - c2), Abs(r1 - r2)) END CDist;

PROCEDURE AppendLog(msg: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  COPY(msg, msgLog[logHead MOD 8]);
  INC(logHead)
END AppendLog;

PROCEDURE IntStr(n: INTEGER; VAR s: ARRAY OF CHAR);
VAR buf: ARRAY 12 OF CHAR;  i, j, len: INTEGER;  neg: BOOLEAN;
BEGIN
  IF n < 0 THEN neg := TRUE; n := -n ELSE neg := FALSE END;
  i := 0;
  REPEAT
    buf[i] := CHR(ORD('0') + (n MOD 10));
    n := n DIV 10; INC(i)
  UNTIL n = 0;
  IF neg THEN buf[i] := '-'; INC(i) END;
  len := i;
  FOR j := 0 TO len - 1 DO s[j] := buf[len - 1 - j] END;
  s[len] := 0X
END IntStr;

PROCEDURE AppendStr(VAR dst: ARRAY OF CHAR; src: ARRAY OF CHAR);
VAR i, j, dlen: INTEGER;
BEGIN
  i := 0; WHILE dst[i] # 0X DO INC(i) END;
  j := 0; WHILE (src[j] # 0X) & (i < LEN(dst) - 1) DO
    dst[i] := src[j]; INC(i); INC(j)
  END;
  dst[i] := 0X
END AppendStr;

(* ═══════════════════════════════════════════════════════════════════════ *)
(*  Facing Helpers                                                          *)
(* ═══════════════════════════════════════════════════════════════════════ *)

PROCEDURE FaceToward(srcCol, srcRow, dstCol, dstRow: INTEGER): INTEGER;
VAR dc, dr: INTEGER;
BEGIN
  dc := dstCol - srcCol; dr := dstRow - srcRow;
  IF Abs(dr) >= Abs(dc) THEN
    IF dr < 0 THEN RETURN NORTH ELSE RETURN SOUTH END
  ELSE
    IF dc > 0 THEN RETURN EAST ELSE RETURN WEST END
  END
END FaceToward;

(* Returns TRUE if the attacker (aCol,aRow) hits the defender's flank or rear *)
PROCEDURE IsFlankOrRear(aCol, aRow: INTEGER; def: Unit): BOOLEAN;
VAR dc, dr: INTEGER;
BEGIN
  dc := aCol - def.col; dr := aRow - def.row;
  CASE def.facing OF
    NORTH: RETURN dr >= 0   (* attacker south of or at same row = flank/rear *)
  | EAST:  RETURN dc <= 0
  | SOUTH: RETURN dr <= 0
  | WEST:  RETURN dc >= 0
  END;
  RETURN FALSE
END IsFlankOrRear;

(* Returns TRUE if attacker is within 45° frontal arc of the shooter *)
PROCEDURE InFrontArc(sCol, sRow, tCol, tRow: INTEGER; facing: INTEGER): BOOLEAN;
VAR dc, dr: INTEGER;
BEGIN
  dc := tCol - sCol; dr := tRow - sRow;
  CASE facing OF
    NORTH: RETURN (dr < 0) & (Abs(dc) <= Abs(dr))
  | EAST:  RETURN (dc > 0) & (Abs(dr) <= Abs(dc))
  | SOUTH: RETURN (dr > 0) & (Abs(dc) <= Abs(dr))
  | WEST:  RETURN (dc < 0) & (Abs(dr) <= Abs(dc))
  END;
  RETURN FALSE
END InFrontArc;

(* ═══════════════════════════════════════════════════════════════════════ *)
(*  Combat Resolution                                                       *)
(* ═══════════════════════════════════════════════════════════════════════ *)

(* Apply hits to a unit, capped at MAX_HITS *)
PROCEDURE AddHits(VAR u: Unit; h: INTEGER);
BEGIN
  IF h < 0 THEN h := 0 END;
  INC(u.hits, h);
  IF u.hits > MAX_HITS THEN u.hits := MAX_HITS END
END AddHits;

(* Shooting cover: woods and towns only (§2 rules) *)
PROCEDURE HasShotCover(col, row: INTEGER): BOOLEAN;
VAR t: INTEGER;
BEGIN
  t := terrain[row][col];
  RETURN (t = TERR_WOOD) OR (t = TERR_TOWN)
END HasShotCover;

(* H2H terrain advantage: woods, towns, hills, river crossings (§3 rules) *)
PROCEDURE HasH2HAdvantage(col, row: INTEGER): BOOLEAN;
VAR t: INTEGER;
BEGIN
  t := terrain[row][col];
  RETURN (t = TERR_WOOD) OR (t = TERR_TOWN) OR (t = TERR_HILL) OR
         (t = TERR_FORD) OR (t = TERR_BRIDGE)
END HasH2HAdvantage;

(* Pike & Shot special H2H reductions *)
PROCEDURE PikeShotH2HReduction(attUtype, defUtype: INTEGER): BOOLEAN;
BEGIN
  (* Cavalry(3) and Reiters(2) inflict half hits vs Infantry(0) *)
  IF ((attUtype = 3) OR (attUtype = 2)) & (defUtype = 0) THEN RETURN TRUE END;
  (* Swordsmen(1) inflict half hits vs Cavalry(3) or Reiters(2) *)
  IF (attUtype = 1) & ((defUtype = 3) OR (defUtype = 2)) THEN RETURN TRUE END;
  RETURN FALSE
END PikeShotH2HReduction;

(* Horse & Musket: Cavalry vs Cavalry gives half hits to defender *)
PROCEDURE HMCavVsCav(attUtype, defUtype: INTEGER): BOOLEAN;
BEGIN RETURN (attUtype = 1) & (defUtype = 1) END HMCavVsCav;

PROCEDURE ResolveShot(attSide, attIdx, defSide, defIdx: INTEGER;
                      VAR msg: ARRAY OF CHAR);
VAR p, die, mod, hits, aMod, dMod: INTEGER;
    att, def: Unit;
    aArmy, dArmy: Army;
    flank: BOOLEAN;
    numStr: ARRAY 8 OF CHAR;
BEGIN
  p := period - 1;
  aArmy := ArmyOf(attSide); att := aArmy.units[attIdx];
  dArmy := ArmyOf(defSide); def := dArmy.units[defIdx];
  aMod := shootMod[p][att.utype];
  IF aMod = NO_FIRE THEN COPY("Cannot shoot", msg); RETURN END;

  die := D6();
  mod := aMod;

  (* WWII approximate modifier vs Tanks: Anti-Tank guns get +4 *)
  IF (period = 9) & (att.utype = 2) & (def.utype = 3) THEN INC(mod, 4) END;
  (* WWII: Tanks get +2 vs Infantry *)
  IF (period = 9) & (att.utype = 3) & (def.utype = 0) THEN INC(mod, 2) END;

  hits := die + mod;
  IF hits < 0 THEN hits := 0 END;

  (* Woods/town cover halves hits; hills give no cover from shooting *)
  IF HasShotCover(def.col, def.row) THEN hits := (hits + 1) DIV 2 END;

  (* Target's armour halves hits (rounds up in shooter's favour) *)
  IF hasArmour[p][def.utype] THEN hits := (hits + 1) DIV 2 END;

  (* Apply *)
  IF defSide = RED THEN AddHits(red.units[defIdx], hits)
  ELSE                  AddHits(blue.units[defIdx], hits)
  END;

  COPY("Shot: roll ", msg); IntStr(die, numStr); AppendStr(msg, numStr);
  AppendStr(msg, "+"); IntStr(mod, numStr); AppendStr(msg, numStr);
  AppendStr(msg, "="); IntStr(hits, numStr); AppendStr(msg, numStr);
  AppendStr(msg, " hit(s)")
END ResolveShot;

PROCEDURE ResolveH2H(attSide, attIdx, defSide, defIdx: INTEGER;
                     VAR msg: ARRAY OF CHAR);
VAR p, die, mod, hits: INTEGER;
    att, def: Unit;
    aArmy, dArmy: Army;
    numStr: ARRAY 8 OF CHAR;
BEGIN
  p := period - 1;
  aArmy := ArmyOf(attSide); att := aArmy.units[attIdx];
  dArmy := ArmyOf(defSide); def := dArmy.units[defIdx];
  mod := h2hMod[p][att.utype];
  IF mod = NO_H2H THEN COPY("Cannot melee", msg); RETURN END;

  die := D6();
  hits := die + mod;
  IF hits < 0 THEN hits := 0 END;

  (* Pike & Shot special reductions *)
  IF (period = 4) & PikeShotH2HReduction(att.utype, def.utype) THEN
    hits := (hits + 1) DIV 2
  END;

  (* Horse & Musket: Cavalry vs Cavalry *)
  IF (period = 5) & HMCavVsCav(att.utype, def.utype) THEN
    hits := (hits + 1) DIV 2
  END;

  (* Hills, woods, towns, river crossings all halve H2H hits *)
  IF HasH2HAdvantage(def.col, def.row) THEN hits := (hits + 1) DIV 2 END;

  (* Armour halves hits *)
  IF hasArmour[p][def.utype] THEN hits := (hits + 1) DIV 2 END;

  (* Flank or rear attack doubles hits *)
  IF IsFlankOrRear(att.col, att.row, def) THEN hits := hits * 2 END;

  IF defSide = RED THEN AddHits(red.units[defIdx], hits)
  ELSE                  AddHits(blue.units[defIdx], hits)
  END;

  COPY("H2H: roll ", msg); IntStr(die, numStr); AppendStr(msg, numStr);
  AppendStr(msg, "+"); IntStr(mod, numStr); AppendStr(msg, numStr);
  AppendStr(msg, "="); IntStr(hits, numStr); AppendStr(msg, numStr);
  AppendStr(msg, " hit(s)")
END ResolveH2H;

(* ═══════════════════════════════════════════════════════════════════════ *)
(*  Game Logic: Validity Checks                                             *)
(* ═══════════════════════════════════════════════════════════════════════ *)

PROCEDURE CanCharge(side, idx: INTEGER): BOOLEAN;
VAR p, ut: INTEGER;
    a: Army;
BEGIN
  p  := period - 1;
  a  := ArmyOf(side);
  ut := a.units[idx].utype;
  IF h2hMod[p][ut] = NO_H2H THEN RETURN FALSE END;
  (* Pike & Shot: Infantry(0) and Reiters(2) may only charge when ammo-out *)
  IF (period = 4) & ((ut = 0) OR (ut = 2)) THEN
    RETURN a.units[idx].ammoOut
  END;
  RETURN TRUE
END CanCharge;

PROCEDURE ValidMoveTarget(side, idx, dstCol, dstRow: INTEGER): BOOLEAN;
VAR p, ut, mv, srcCol, srcRow, oSide, oIdx: INTEGER;
    u: Unit;
    a: Army;
BEGIN
  p  := period - 1;
  a  := ArmyOf(side);
  u  := a.units[idx];
  ut := u.utype;
  mv := moveAllow[p][ut];
  srcCol := u.col; srcRow := u.row;

  (* Road movement bonus: +1 cell when moving along a road (same row or col) *)
  IF (terrain[srcRow][srcCol] = TERR_ROAD) &
     (terrain[dstRow][dstCol] = TERR_ROAD) &
     ((srcRow = dstRow) OR (srcCol = dstCol)) THEN
    INC(mv)
  END;

  IF (dstCol < 0) OR (dstCol >= GRID_W) OR (dstRow < 0) OR (dstRow >= GRID_H) THEN
    RETURN FALSE
  END;

  (* Out of range *)
  IF CDist(srcCol, srcRow, dstCol, dstRow) > mv THEN RETURN FALSE END;

  (* Can't stay put *)
  IF (dstCol = srcCol) & (dstRow = srcRow) THEN RETURN FALSE END;

  (* Cannot move into any occupied cell; H2H happens by moving adjacent *)
  UnitAt(dstCol, dstRow, oSide, oIdx);
  IF oSide >= 0 THEN RETURN FALSE END;

  (* Terrain restriction: woods *)
  IF terrain[dstRow][dstCol] = TERR_WOOD THEN
    RETURN canWoods[p][ut]
  END;

  (* Terrain restriction: marsh/lake impassable *)
  IF terrain[dstRow][dstCol] = TERR_MARSH THEN RETURN FALSE END;

  (* River: only via ford/bridge — hook for future *)
  IF terrain[dstRow][dstCol] = TERR_RIVER THEN RETURN FALSE END;

  RETURN TRUE
END ValidMoveTarget;

PROCEDURE CanShootTarget(side, idx, tCol, tRow: INTEGER): BOOLEAN;
VAR p, ut, sr: INTEGER;
    u: Unit;
    a: Army;
    inTown: BOOLEAN;
BEGIN
  p  := period - 1;
  a  := ArmyOf(side);
  u  := a.units[idx];
  ut := u.utype;

  IF shootMod[p][ut] = NO_FIRE THEN RETURN FALSE END;

  (* Can't shoot if already shot *)
  IF u.shot THEN RETURN FALSE END;

  (* Can't shoot if moved (unless canMoveShoot) *)
  IF u.moved & ~canMoveShoot[p][ut] THEN RETURN FALSE END;

  (* H&M optional square: no shooting *)
  IF u.inSquare THEN RETURN FALSE END;

  sr := shootRange[p][ut];
  IF CDist(u.col, u.row, tCol, tRow) > sr THEN RETURN FALSE END;

  (* Field of fire: 45° arc, except 360° for units in town or WWII *)
  inTown := terrain[u.row][u.col] = TERR_TOWN;
  IF ~inTown & (period # 9) THEN
    IF ~InFrontArc(u.col, u.row, tCol, tRow, u.facing) THEN RETURN FALSE END
  END;

  RETURN TRUE
END CanShootTarget;

PROCEDURE CheckElimination;
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO red.count - 1 DO
    IF red.units[i].alive & (red.units[i].hits >= MAX_HITS) THEN
      red.units[i].alive := FALSE;
      AppendLog("Red unit eliminated!")
    END
  END;
  FOR i := 0 TO blue.count - 1 DO
    IF blue.units[i].alive & (blue.units[i].hits >= MAX_HITS) THEN
      blue.units[i].alive := FALSE;
      AppendLog("Blue unit eliminated!")
    END
  END
END CheckElimination;

PROCEDURE AliveCount(side: INTEGER): INTEGER;
VAR a: Army; i, n: INTEGER;
BEGIN
  a := ArmyOf(side); n := 0;
  FOR i := 0 TO a.count - 1 DO
    IF a.units[i].alive THEN INC(n) END
  END;
  RETURN n
END AliveCount;

PROCEDURE SideOnHill(side: INTEGER): BOOLEAN;
VAR i: INTEGER; a: Army;
BEGIN
  a := ArmyOf(side);
  FOR i := 0 TO a.count - 1 DO
    IF a.units[i].alive & (terrain[a.units[i].row][a.units[i].col] = TERR_HILL) THEN
      RETURN TRUE
    END
  END;
  RETURN FALSE
END SideOnHill;

PROCEDURE SideAtCell(side, col, row: INTEGER): BOOLEAN;
VAR i: INTEGER; a: Army;
BEGIN
  a := ArmyOf(side);
  FOR i := 0 TO a.count - 1 DO
    IF a.units[i].alive & (a.units[i].col = col) & (a.units[i].row = row) THEN
      RETURN TRUE
    END
  END;
  RETURN FALSE
END SideAtCell;

PROCEDURE CheckVictory;
VAR rAlive, bAlive: INTEGER;
    rHill, bHill, rCross, bCross: BOOLEAN;
    rB1, bB1, rB2, bB2: BOOLEAN;
BEGIN
  rAlive := AliveCount(RED); bAlive := AliveCount(BLUE);

  (* Elimination always ends the game early *)
  IF rAlive = 0 THEN
    AppendLog("BLUE WINS — Red army destroyed!");
    gameOver := TRUE; RETURN
  ELSIF bAlive = 0 THEN
    AppendLog("RED WINS — Blue army destroyed!");
    gameOver := TRUE; RETURN
  END;

  IF turn > TURNS THEN
    IF victoryType = VIC_HOLD THEN
      (* Control = sole occupancy; contested = neither controls *)
      rHill  := SideOnHill(RED)  & ~SideOnHill(BLUE);
      bHill  := SideOnHill(BLUE) & ~SideOnHill(RED);
      rCross := SideAtCell(RED,  CROSS_COL, CROSS_ROW) &
               ~SideAtCell(BLUE, CROSS_COL, CROSS_ROW);
      bCross := SideAtCell(BLUE, CROSS_COL, CROSS_ROW) &
               ~SideAtCell(RED,  CROSS_COL, CROSS_ROW);
      IF rHill & rCross THEN
        AppendLog("RED WINS — hill and crossroads held!")
      ELSIF bHill & bCross THEN
        AppendLog("BLUE WINS — hill and crossroads held!")
      ELSIF rAlive > bAlive THEN
        AppendLog("RED WINS — more survivors (objectives split)")
      ELSIF bAlive > rAlive THEN
        AppendLog("BLUE WINS — more survivors (objectives split)")
      ELSE
        AppendLog("DRAW — objectives split, equal survivors")
      END
    ELSIF victoryType = VIC_BRIDGES THEN
      rB1 := SideAtCell(RED,  BRIDGE1_COL, BRIDGE_ROW) &
            ~SideAtCell(BLUE, BRIDGE1_COL, BRIDGE_ROW);
      bB1 := SideAtCell(BLUE, BRIDGE1_COL, BRIDGE_ROW) &
            ~SideAtCell(RED,  BRIDGE1_COL, BRIDGE_ROW);
      rB2 := SideAtCell(RED,  BRIDGE2_COL, BRIDGE_ROW) &
            ~SideAtCell(BLUE, BRIDGE2_COL, BRIDGE_ROW);
      bB2 := SideAtCell(BLUE, BRIDGE2_COL, BRIDGE_ROW) &
            ~SideAtCell(RED,  BRIDGE2_COL, BRIDGE_ROW);
      IF rB1 & rB2 THEN
        AppendLog("RED WINS — both bridges held!")
      ELSIF bB1 & bB2 THEN
        AppendLog("BLUE WINS — both bridges held!")
      ELSIF rAlive > bAlive THEN
        AppendLog("RED WINS — more survivors (bridges split)")
      ELSIF bAlive > rAlive THEN
        AppendLog("BLUE WINS — more survivors (bridges split)")
      ELSE
        AppendLog("DRAW — bridges split, equal survivors")
      END
    ELSE
      IF rAlive > bAlive THEN
        AppendLog("RED WINS — most units surviving!")
      ELSIF bAlive > rAlive THEN
        AppendLog("BLUE WINS — most units surviving!")
      ELSE
        AppendLog("DRAW — equal survivors!")
      END
    END;
    gameOver := TRUE
  END
END CheckVictory;

(* ═══════════════════════════════════════════════════════════════════════ *)
(*  AI (Blue side)                                                          *)
(* ═══════════════════════════════════════════════════════════════════════ *)

PROCEDURE AIFindClosestEnemy(bIdx: INTEGER; VAR tCol, tRow: INTEGER);
VAR i, dist, best: INTEGER;
    bu: Unit;
BEGIN
  bu := blue.units[bIdx];
  best := 9999; tCol := -1; tRow := -1;
  FOR i := 0 TO red.count - 1 DO
    IF red.units[i].alive THEN
      dist := CDist(bu.col, bu.row, red.units[i].col, red.units[i].row);
      IF dist < best THEN
        best := dist; tCol := red.units[i].col; tRow := red.units[i].row
      END
    END
  END
END AIFindClosestEnemy;

(* AI: find best shooting target (most hits = closest to death) *)
PROCEDURE AIFindShotTarget(bIdx: INTEGER; VAR tSide, tIdx: INTEGER);
VAR i, best: INTEGER;
    bu: Unit;
BEGIN
  bu := blue.units[bIdx];
  tSide := -1; tIdx := -1; best := -1;
  FOR i := 0 TO red.count - 1 DO
    IF red.units[i].alive &
       CanShootTarget(BLUE, bIdx, red.units[i].col, red.units[i].row) THEN
      (* prefer weakest target *)
      IF red.units[i].hits > best THEN
        best := red.units[i].hits; tSide := RED; tIdx := i
      END
    END
  END
END AIFindShotTarget;

PROCEDURE AIFindH2HTarget(bIdx: INTEGER; VAR tSide, tIdx: INTEGER);
VAR i: INTEGER;
    bu: Unit;
BEGIN
  bu := blue.units[bIdx];
  tSide := -1; tIdx := -1;
  FOR i := 0 TO red.count - 1 DO
    IF red.units[i].alive &
       (CDist(bu.col, bu.row, red.units[i].col, red.units[i].row) = 1) &
       CanCharge(BLUE, bIdx) THEN
      tSide := RED; tIdx := i; RETURN
    END
  END
END AIFindH2HTarget;

PROCEDURE AIMoveUnit(bIdx: INTEGER);
VAR tCol, tRow, bestCol, bestRow, bestDist, dc, dr, nc, nr, newDist: INTEGER;
    p, ut, mv: INTEGER;
    msg: ARRAY 64 OF CHAR;
BEGIN
  p  := period - 1;
  ut := blue.units[bIdx].utype;
  mv := moveAllow[p][ut];
  AIFindClosestEnemy(bIdx, tCol, tRow);
  IF tCol < 0 THEN RETURN END;

  bestCol := blue.units[bIdx].col; bestRow := blue.units[bIdx].row;
  bestDist := CDist(bestCol, bestRow, tCol, tRow);

  (* Try each cell within move allowance; greedy closest-to-target *)
  FOR dc := -mv TO mv DO
    FOR dr := -mv TO mv DO
      nc := blue.units[bIdx].col + dc;
      nr := blue.units[bIdx].row + dr;
      IF ValidMoveTarget(BLUE, bIdx, nc, nr) THEN
        newDist := CDist(nc, nr, tCol, tRow);
        IF newDist < bestDist THEN
          bestDist := newDist; bestCol := nc; bestRow := nr
        END
      END
    END
  END;

  IF (bestCol # blue.units[bIdx].col) OR (bestRow # blue.units[bIdx].row) THEN
    blue.units[bIdx].facing := FaceToward(blue.units[bIdx].col,
                                           blue.units[bIdx].row, bestCol, bestRow);
    blue.units[bIdx].col   := bestCol;
    blue.units[bIdx].row   := bestRow;
    blue.units[bIdx].moved := TRUE
  END
END AIMoveUnit;

PROCEDURE DoAITurn;
VAR i, tSide, tIdx: INTEGER;
    msg: ARRAY 64 OF CHAR;
BEGIN
  (* Move phase *)
  FOR i := 0 TO blue.count - 1 DO
    IF blue.units[i].alive & ~blue.units[i].moved THEN AIMoveUnit(i) END
  END;

  (* Shoot phase *)
  FOR i := 0 TO blue.count - 1 DO
    IF blue.units[i].alive THEN
      AIFindShotTarget(i, tSide, tIdx);
      IF tIdx >= 0 THEN
        ResolveShot(BLUE, i, tSide, tIdx, msg);
        AppendLog(msg);
        blue.units[i].shot := TRUE;
        (* Pike & Shot ammo check *)
        IF (period = 4) & (D6() <= 2) THEN
          blue.units[i].ammoOut := TRUE;
          AppendLog("Blue: ammo out!")
        END
      END
    END
  END;

  (* H2H Combat phase *)
  FOR i := 0 TO blue.count - 1 DO
    IF blue.units[i].alive THEN
      AIFindH2HTarget(i, tSide, tIdx);
      IF tIdx >= 0 THEN
        ResolveH2H(BLUE, i, tSide, tIdx, msg);
        AppendLog(msg);
        (* H&M/R&S Cavalry retreat 6" = 2 cells if target survived *)
        IF ((period = 5) OR (period = 6)) & (blue.units[i].utype = 1) &
           red.units[tIdx].alive THEN
          (* retreat 2 cells south (away from Red's northern deployment) *)
          IF blue.units[i].row < GRID_H - 1 THEN INC(blue.units[i].row) END;
          IF blue.units[i].row < GRID_H - 1 THEN INC(blue.units[i].row) END
        END
      END
    END
  END;

  CheckElimination
END DoAITurn;

(* ═══════════════════════════════════════════════════════════════════════ *)
(*  Display                                                                 *)
(* ═══════════════════════════════════════════════════════════════════════ *)

PROCEDURE UnitGlyph(side: INTEGER; u: Unit): CHAR;
BEGIN RETURN unitGlyph[period - 1][u.utype] END UnitGlyph;

PROCEDURE DrawCell(col, row: INTEGER);
VAR sx, sy, uSide, uIdx: INTEGER;
    u: Unit;
    tmpArmy: Army;
    fg, bg: INTEGER;
    c0, c1: CHAR;
    isCursor, isSelected, isValidMove, isShootable, isTargetable: BOOLEAN;
    p, ut: INTEGER;
BEGIN
  sx := MAPX + col * 2;
  sy := MAPY + row;
  UnitAt(col, row, uSide, uIdx);
  p := period - 1;

  isCursor   := (col = curCol) & (row = curRow);
  isSelected := (selUnit >= 0) & (uSide = activeSide) & (uIdx = selUnit);

  (* Valid move destination: empty cell in range when moving *)
  isValidMove := FALSE;
  IF (selUnit >= 0) & (phase = PH_MOVE) & (uSide < 0) THEN
    isValidMove := ValidMoveTarget(activeSide, selUnit, col, row)
  END;

  (* Eligible shooter: Red unit that hasn't moved/shot and can shoot *)
  isShootable := FALSE;
  IF (selUnit < 0) & (phase = PH_SHOOT) & (uSide = RED) & (uIdx >= 0) THEN
    ut := red.units[uIdx].utype;
    isShootable := (shootMod[p][ut] # NO_FIRE) &
                   ~red.units[uIdx].shot &
                   (~red.units[uIdx].moved OR canMoveShoot[p][ut])
  END;

  (* Valid shoot target: Blue unit in range and field of fire of selected shooter *)
  isTargetable := FALSE;
  IF (selUnit >= 0) & (phase = PH_SHOOT) & (uSide = BLUE) THEN
    isTargetable := CanShootTarget(activeSide, selUnit, col, row)
  END;

  IF isCursor THEN
    bg := TUI.Cyan;    fg := TUI.Black
  ELSIF isSelected THEN
    bg := TUI.Yellow;  fg := TUI.Black
  ELSIF isValidMove OR isTargetable THEN
    bg := TUI.Green;   fg := TUI.Black
  ELSIF isShootable THEN
    bg := TUI.Magenta; fg := TUI.White
  ELSIF terrain[row][col] = TERR_HILL THEN
    bg := TUI.Yellow;  fg := TUI.Black
  ELSIF (terrain[row][col] = TERR_RIVER) OR (terrain[row][col] = TERR_MARSH) OR
        (terrain[row][col] = TERR_BRIDGE) THEN
    bg := TUI.Blue;    fg := TUI.White
  ELSE
    bg := TUI.Black;   fg := TUI.White
  END;

  IF uSide >= 0 THEN
    tmpArmy := ArmyOf(uSide);
    u := tmpArmy.units[uIdx];
    IF uSide = RED THEN
      IF ~isCursor & ~isSelected & ~isShootable THEN fg := TUI.Red
      ELSE fg := TUI.Black END;
      c0 := 'R'
    ELSE
      IF ~isCursor & ~isTargetable THEN fg := TUI.Cyan
      ELSE fg := TUI.Black END;
      c0 := 'B'
    END;
    c1 := UnitGlyph(uSide, u)
  ELSE
    IF isCursor OR isValidMove THEN fg := TUI.Black ELSE fg := TUI.White END;
    IF terrain[row][col] = TERR_HILL THEN c0 := '^'
    ELSIF terrain[row][col] = TERR_ROAD THEN
      IF (col = CROSS_COL) & (row = CROSS_ROW) THEN c0 := '+' ELSE c0 := '#' END
    ELSIF terrain[row][col] = TERR_BRIDGE THEN c0 := '['
    ELSIF (terrain[row][col] = TERR_RIVER) OR (terrain[row][col] = TERR_MARSH) THEN
      c0 := '~'
    ELSE c0 := '.'
    END;
    c1 := ' '
  END;

  TUI.PutCell(sx, sy, c0, fg, bg);
  TUI.PutCell(sx + 1, sy, c1, fg, bg)
END DrawCell;

PROCEDURE DrawMap;
VAR c, r: INTEGER;
    label: CHAR;
BEGIN
  (* Column labels *)
  FOR c := 0 TO GRID_W - 1 DO
    IF c < 10 THEN label := CHR(ORD('0') + c)
    ELSE           label := CHR(ORD('A') + c - 10)
    END;
    TUI.PutCell(MAPX + c * 2, MAPY - 1, label, TUI.Yellow, TUI.Black);
    TUI.PutCell(MAPX + c * 2 + 1, MAPY - 1, ' ', TUI.Yellow, TUI.Black)
  END;

  (* Row labels + cells *)
  FOR r := 0 TO GRID_H - 1 DO
    IF r < 10 THEN label := CHR(ORD('0') + r)
    ELSE           label := CHR(ORD('A') + r - 10)
    END;
    TUI.PutCell(MAPX - 2, MAPY + r, label, TUI.Yellow, TUI.Black);
    TUI.PutCell(MAPX - 1, MAPY + r, ' ', TUI.Black, TUI.Black);
    FOR c := 0 TO GRID_W - 1 DO DrawCell(c, r) END
  END
END DrawMap;

PROCEDURE DrawUnitList;
VAR i, sx, sy: INTEGER;
    a: Army;
    u: Unit;
    fg: INTEGER;
    num: ARRAY 4 OF CHAR;
BEGIN
  sx := SIDEX;
  TUI.PutStr(sx, 2, "Unit           Hits", TUI.Yellow, TUI.Black);

  (* Red units *)
  sy := 3;
  TUI.PutStr(sx, sy, "[Red]", TUI.Red, TUI.Black); INC(sy);
  FOR i := 0 TO red.count - 1 DO
    u := red.units[i];
    IF u.alive THEN fg := TUI.White ELSE fg := TUI.White (*dim*) END;
    TUI.PutStr(sx, sy, unitName[period - 1][u.utype], fg, TUI.Black);
    IntStr(u.hits, num);
    TUI.PutStr(sx + 16, sy, num, fg, TUI.Black);
    IF ~u.alive THEN TUI.PutStr(sx + 19, sy, "X", TUI.Red, TUI.Black) END;
    INC(sy)
  END;

  (* Blue units *)
  INC(sy);
  TUI.PutStr(sx, sy, "[Blue]", TUI.Cyan, TUI.Black); INC(sy);
  FOR i := 0 TO blue.count - 1 DO
    u := blue.units[i];
    IF u.alive THEN fg := TUI.White ELSE fg := TUI.White END;
    TUI.PutStr(sx, sy, unitName[period - 1][u.utype], fg, TUI.Black);
    IntStr(u.hits, num);
    TUI.PutStr(sx + 16, sy, num, fg, TUI.Black);
    IF ~u.alive THEN TUI.PutStr(sx + 19, sy, "X", TUI.Cyan, TUI.Black) END;
    INC(sy)
  END
END DrawUnitList;

PROCEDURE DrawLog;
VAR i, sy, nShow: INTEGER;
BEGIN
  sy := MAPY + GRID_H + 2;  (* first entry row, header is sy-1 *)
  nShow := TUI.Rows - sy - 1;
  IF nShow > 8 THEN nShow := 8 END;
  IF nShow < 1 THEN RETURN END;
  TUI.PutStr(1, sy - 1, "--- Log ---", TUI.Yellow, TUI.Black);
  FOR i := 0 TO nShow - 1 DO
    TUI.PutStr(1, sy + i,
               msgLog[(logHead - nShow + i + 64) MOD 8],
               TUI.White, TUI.Black)
  END
END DrawLog;

PROCEDURE PutPanel(row: INTEGER; s: ARRAY OF CHAR; fg: INTEGER);
VAR buf: ARRAY 17 OF CHAR; i: INTEGER;
BEGIN
  i := 0;
  WHILE (i < PANW) & (s[i] # 0X) DO buf[i] := s[i]; INC(i) END;
  WHILE i < PANW DO buf[i] := ' '; INC(i) END;
  buf[PANW] := 0X;
  TUI.PutStr(PANX, row, buf, fg, TUI.Black)
END PutPanel;

PROCEDURE DrawCursorInfo;
VAR uSide, uIdx, p, ut: INTEGER;
    a: Army;
    u: Unit;
    s: ARRAY 20 OF CHAR;
    n: ARRAY 8 OF CHAR;
    fg, sMod, hMod: INTEGER;
BEGIN
  UnitAt(curCol, curRow, uSide, uIdx);

  IF uSide < 0 THEN
    IF curCol < 10 THEN s[0] := CHR(ORD('0') + curCol)
    ELSE s[0] := CHR(ORD('A') + curCol - 10)
    END;
    IF curRow < 10 THEN s[1] := CHR(ORD('0') + curRow)
    ELSE s[1] := CHR(ORD('A') + curRow - 10)
    END;
    s[2] := ' '; s[3] := 0X;
    AppendStr(s, "(empty)");
    PutPanel(PANY,   s, TUI.White);
    PutPanel(PANY+1, "", TUI.White);
    PutPanel(PANY+2, "", TUI.White);
    PutPanel(PANY+3, "", TUI.White);
    PutPanel(PANY+4, "", TUI.White);
    PutPanel(PANY+5, "", TUI.White);
    RETURN
  END;

  p  := period - 1;
  a  := ArmyOf(uSide);
  u  := a.units[uIdx];
  ut := u.utype;
  IF uSide = RED THEN fg := TUI.Red ELSE fg := TUI.Cyan END;

  (* Row 0: unit name *)
  COPY(unitName[p][ut], s);
  PutPanel(PANY, s, fg);

  (* Row 1: side + damage taken + facing *)
  IF uSide = RED THEN COPY("Red ", s) ELSE COPY("Blu ", s) END;
  IntStr(u.hits, n); AppendStr(s, n);
  AppendStr(s, "/15dmg ");
  CASE u.facing OF
    NORTH: AppendStr(s, "N") | EAST:  AppendStr(s, "E")
  | SOUTH: AppendStr(s, "S") | WEST:  AppendStr(s, "W")
  END;
  PutPanel(PANY+1, s, fg);

  (* Row 2: movement allowance in cells *)
  COPY("mv: ", s); IntStr(moveAllow[p][ut], n); AppendStr(s, n);
  PutPanel(PANY+2, s, TUI.White);

  (* Row 3: shoot modifier + current availability *)
  sMod := shootMod[p][ut];
  IF sMod = NO_FIRE THEN
    COPY("sht: no", s)
  ELSE
    COPY("sht: ", s);
    IF sMod >= 0 THEN AppendStr(s, "+") END;
    IntStr(sMod, n); AppendStr(s, n);
    IF u.shot THEN AppendStr(s, " done")
    ELSIF u.moved & ~canMoveShoot[p][ut] THEN AppendStr(s, " mvd")
    ELSE AppendStr(s, " ok")
    END
  END;
  PutPanel(PANY+3, s, TUI.White);

  (* Row 4: H2H modifier *)
  hMod := h2hMod[p][ut];
  IF hMod = NO_H2H THEN
    COPY("h2h: no", s)
  ELSE
    COPY("h2h: ", s);
    IF hMod >= 0 THEN AppendStr(s, "+") END;
    IntStr(hMod, n); AppendStr(s, n)
  END;
  PutPanel(PANY+4, s, TUI.White);

  (* Row 5: special flags *)
  s[0] := 0X;
  IF u.ammoOut  THEN COPY("ammo!", s) END;
  IF u.inSquare THEN
    IF s[0] # 0X THEN AppendStr(s, " ") END;
    AppendStr(s, "sqr")
  END;
  PutPanel(PANY+5, s, TUI.Yellow)
END DrawCursorInfo;

PROCEDURE DrawStatus;
VAR s: ARRAY 64 OF CHAR;
    n: ARRAY 8 OF CHAR;
BEGIN
  (* Title line *)
  COPY("ONE HOUR WARGAMES  Period: ", s);
  AppendStr(s, periodName[period - 1]);
  TUI.PutStr(1, 1, s, TUI.Yellow, TUI.Black);

  (* Turn / phase line *)
  IF activeSide = RED THEN COPY("[RED]  ", s) ELSE COPY("[BLUE] ", s) END;
  AppendStr(s, "Turn "); IntStr(turn, n); AppendStr(s, n);
  AppendStr(s, "/15  ");
  CASE phase OF
    PH_MOVE:   AppendStr(s, "Move Phase  ")
  | PH_SHOOT:  AppendStr(s, "Shoot Phase ")
  | PH_COMBAT: AppendStr(s, "Combat Phase")
  | PH_ELIM:   AppendStr(s, "Elim Phase  ")
  END;
  TUI.PutStr(1, 2, s, TUI.White, TUI.Black);

  (* Controls *)
  IF gameOver THEN
    TUI.PutStr(1, TUI.Rows - 1,
      "Game Over! Press Q to quit.                                    ",
      TUI.Yellow, TUI.Black)
  ELSIF activeSide = RED THEN
    CASE phase OF
      PH_MOVE:
        TUI.PutStr(1, TUI.Rows - 1,
          "Arrows=cursor  Enter=select/move  F=face  U=undo  Esc=cancel  N=end",
          TUI.White, TUI.Black)
    | PH_SHOOT:
        IF selUnit < 0 THEN
          TUI.PutStr(1, TUI.Rows - 1,
            "Magenta=can shoot  Enter=select shooter  N=end shoot phase  ",
            TUI.White, TUI.Black)
        ELSE
          COPY("Shooter selected: ", s);
          AppendStr(s, unitName[period - 1][red.units[selUnit].utype]);
          AppendStr(s, "  Green=in range  Enter=shoot  Esc=cancel        ");
          TUI.PutStr(1, TUI.Rows - 1, s, TUI.Yellow, TUI.Black)
        END
    | PH_COMBAT:
        TUI.PutStr(1, TUI.Rows - 1,
          "H2H combat resolving...  (press any key)                      ",
          TUI.White, TUI.Black)
    | PH_ELIM:
        TUI.PutStr(1, TUI.Rows - 1,
          "Press any key to continue to Blue's turn.                     ",
          TUI.White, TUI.Black)
    END
  ELSE
    TUI.PutStr(1, TUI.Rows - 1,
      "Blue (computer) is playing...                                  ",
      TUI.Cyan, TUI.Black)
  END
END DrawStatus;

PROCEDURE DrawScreen;
BEGIN
  TUI.ClearBack(TUI.White, TUI.Black);
  DrawStatus;
  DrawCursorInfo;
  DrawMap;
  DrawUnitList;
  DrawLog;
  TUI.Flush
END DrawScreen;

(* ═══════════════════════════════════════════════════════════════════════ *)
(*  Player Input Handling                                                   *)
(* ═══════════════════════════════════════════════════════════════════════ *)

(* Returns TRUE if any Red unit still needs to move/shoot *)
PROCEDURE RedHasAction(ph: INTEGER): BOOLEAN;
VAR i, p, ut: INTEGER;
BEGIN
  p := period - 1;
  FOR i := 0 TO red.count - 1 DO
    IF red.units[i].alive THEN
      IF (ph = PH_MOVE) & ~red.units[i].moved THEN RETURN TRUE END;
      ut := red.units[i].utype;
      IF (ph = PH_SHOOT) & ~red.units[i].shot &
         (shootMod[p][ut] # NO_FIRE) &
         (~red.units[i].moved OR canMoveShoot[p][ut]) THEN
        RETURN TRUE
      END
    END
  END;
  RETURN FALSE
END RedHasAction;

PROCEDURE HandleMovePhase(key: INTEGER);
VAR logMsg: ARRAY 64 OF CHAR;
    prevCol, prevRow: INTEGER;
    oSide, oIdx: INTEGER;
BEGIN
  IF key = TUI.KUp    THEN IF curRow > 0 THEN DEC(curRow) END
  ELSIF key = TUI.KDown  THEN IF curRow < GRID_H - 1 THEN INC(curRow) END
  ELSIF key = TUI.KLeft  THEN IF curCol > 0 THEN DEC(curCol) END
  ELSIF key = TUI.KRight THEN IF curCol < GRID_W - 1 THEN INC(curCol) END
  ELSIF key = TUI.KEnter THEN
    IF selUnit < 0 THEN
      (* Select: must be own alive unmoved unit *)
      UnitAt(curCol, curRow, oSide, oIdx);
      IF (oSide = RED) & ~red.units[oIdx].moved THEN
        selUnit := oIdx
      END
    ELSE
      (* Confirm move destination — units cannot enter enemy-occupied cells;
         moving adjacent to an enemy puts them in H2H for the combat phase *)
      IF ValidMoveTarget(RED, selUnit, curCol, curRow) THEN
        (* Push state onto undo stack *)
        IF undoTop < MAX_UNITS THEN
          undoIdx[undoTop]    := selUnit;
          undoCol[undoTop]    := red.units[selUnit].col;
          undoRow[undoTop]    := red.units[selUnit].row;
          undoFacing[undoTop] := red.units[selUnit].facing;
          undoMoved[undoTop]  := red.units[selUnit].moved;
          INC(undoTop)
        END;
        prevCol := red.units[selUnit].col;
        prevRow := red.units[selUnit].row;
        red.units[selUnit].facing :=
          FaceToward(prevCol, prevRow, curCol, curRow);
        red.units[selUnit].col   := curCol;
        red.units[selUnit].row   := curRow;
        red.units[selUnit].moved := TRUE;
        COPY("Red ", logMsg);
        AppendStr(logMsg, unitName[period - 1][red.units[selUnit].utype]);
        AppendStr(logMsg, " moves");
        AppendLog(logMsg);
        selUnit := -1
      END
    END
  ELSIF (key = ORD('f')) OR (key = ORD('F')) THEN
    IF selUnit >= 0 THEN
      (* Push state onto undo stack *)
      IF undoTop < MAX_UNITS THEN
        undoIdx[undoTop]    := selUnit;
        undoCol[undoTop]    := red.units[selUnit].col;
        undoRow[undoTop]    := red.units[selUnit].row;
        undoFacing[undoTop] := red.units[selUnit].facing;
        undoMoved[undoTop]  := red.units[selUnit].moved;
        INC(undoTop)
      END;
      red.units[selUnit].facing := (red.units[selUnit].facing + 1) MOD 4;
      red.units[selUnit].moved  := TRUE;
      COPY("Red ", logMsg);
      AppendStr(logMsg, unitName[period - 1][red.units[selUnit].utype]);
      AppendStr(logMsg, " faces ");
      CASE red.units[selUnit].facing OF
        NORTH: AppendStr(logMsg, "N")
      | EAST:  AppendStr(logMsg, "E")
      | SOUTH: AppendStr(logMsg, "S")
      | WEST:  AppendStr(logMsg, "W")
      END;
      AppendLog(logMsg);
      selUnit := -1
    END
  ELSIF (key = ORD('u')) OR (key = ORD('U')) THEN
    IF undoTop > 0 THEN
      DEC(undoTop);
      oIdx := undoIdx[undoTop];
      curCol := undoCol[undoTop];
      curRow := undoRow[undoTop];
      red.units[oIdx].col    := undoCol[undoTop];
      red.units[oIdx].row    := undoRow[undoTop];
      red.units[oIdx].facing := undoFacing[undoTop];
      red.units[oIdx].moved  := undoMoved[undoTop];
      COPY("Red ", logMsg);
      AppendStr(logMsg, unitName[period - 1][red.units[oIdx].utype]);
      AppendStr(logMsg, " move undone");
      AppendLog(logMsg);
      selUnit := -1
    END
  ELSIF key = TUI.KEsc THEN
    selUnit := -1
  END
END HandleMovePhase;

PROCEDURE HasShootTargets(side, idx: INTEGER): BOOLEAN;
VAR i: INTEGER;
    enemies: Army;
BEGIN
  IF side = RED THEN enemies := blue ELSE enemies := red END;
  FOR i := 0 TO enemies.count - 1 DO
    IF enemies.units[i].alive &
       CanShootTarget(side, idx, enemies.units[i].col, enemies.units[i].row) THEN
      RETURN TRUE
    END
  END;
  RETURN FALSE
END HasShootTargets;

PROCEDURE HandleShootPhase(key: INTEGER);
VAR oSide, oIdx: INTEGER;
    msg: ARRAY 64 OF CHAR;
BEGIN
  IF key = TUI.KUp    THEN IF curRow > 0 THEN DEC(curRow) END
  ELSIF key = TUI.KDown  THEN IF curRow < GRID_H - 1 THEN INC(curRow) END
  ELSIF key = TUI.KLeft  THEN IF curCol > 0 THEN DEC(curCol) END
  ELSIF key = TUI.KRight THEN IF curCol < GRID_W - 1 THEN INC(curCol) END
  ELSIF key = TUI.KEnter THEN
    IF selUnit < 0 THEN
      (* Select shooter *)
      UnitAt(curCol, curRow, oSide, oIdx);
      IF oSide = RED THEN
        IF shootMod[period - 1][red.units[oIdx].utype] = NO_FIRE THEN
          AppendLog("This unit cannot shoot.")
        ELSIF red.units[oIdx].shot THEN
          AppendLog("Already shot this turn.")
        ELSIF red.units[oIdx].moved & ~canMoveShoot[period - 1][red.units[oIdx].utype] THEN
          AppendLog("Moved this turn - cannot shoot.")
        ELSE
          selUnit := oIdx;
          (* Warn immediately if no targets are in range *)
          IF ~HasShootTargets(RED, oIdx) THEN
            AppendLog("No targets in range/arc (advance first).")
          END
        END
      END
    ELSE
      (* Deselect on own unit, or fire at enemy *)
      UnitAt(curCol, curRow, oSide, oIdx);
      IF oSide = activeSide THEN
        selUnit := -1   (* re-select a different shooter *)
      ELSIF oSide = BLUE THEN
        IF CanShootTarget(RED, selUnit, curCol, curRow) THEN
          ResolveShot(RED, selUnit, BLUE, oIdx, msg);
          AppendLog(msg);
          red.units[selUnit].shot := TRUE;
          (* Pike & Shot ammo check *)
          IF (period = 4) & (D6() <= 2) THEN
            red.units[selUnit].ammoOut := TRUE;
            AppendLog("Red: ammo out!")
          END;
          CheckElimination;
          selUnit := -1
        ELSE
          AppendLog("Target out of range or arc!")
        END
      END
    END
  ELSIF key = TUI.KEsc THEN
    selUnit := -1
  END
END HandleShootPhase;

(* ═══════════════════════════════════════════════════════════════════════ *)
(*  Phase Advancement                                                       *)
(* ═══════════════════════════════════════════════════════════════════════ *)

PROCEDURE ClearTurnFlags(side: INTEGER);
VAR a: Army; i: INTEGER;
BEGIN
  a := ArmyOf(side);
  FOR i := 0 TO a.count - 1 DO
    a.units[i].moved := FALSE; a.units[i].shot := FALSE
  END;
  SetArmy(side, a)
END ClearTurnFlags;

PROCEDURE ResolveH2HAll;
VAR i, j: INTEGER;
    msg: ARRAY 64 OF CHAR;
BEGIN
  (* Each Red unit adjacent to a Blue unit fights (Red's turn) *)
  IF activeSide = RED THEN
    FOR i := 0 TO red.count - 1 DO
      IF red.units[i].alive THEN
        FOR j := 0 TO blue.count - 1 DO
          IF blue.units[j].alive &
             (CDist(red.units[i].col, red.units[i].row,
                    blue.units[j].col, blue.units[j].row) = 1) &
             CanCharge(RED, i) THEN
            ResolveH2H(RED, i, BLUE, j, msg);
            AppendLog(msg)
          END
        END
      END
    END
  ELSE
    FOR i := 0 TO blue.count - 1 DO
      IF blue.units[i].alive THEN
        FOR j := 0 TO red.count - 1 DO
          IF red.units[j].alive &
             (CDist(blue.units[i].col, blue.units[i].row,
                    red.units[j].col, red.units[j].row) = 1) &
             CanCharge(BLUE, i) THEN
            ResolveH2H(BLUE, i, RED, j, msg);
            AppendLog(msg)
          END
        END
      END
    END
  END;
  CheckElimination
END ResolveH2HAll;

PROCEDURE AdvancePhase;
BEGIN
  selUnit := -1;
  CASE phase OF
    PH_MOVE:
      undoTop := 0;   (* moves are now fixed *)
      phase := PH_SHOOT
  | PH_SHOOT:
      phase := PH_COMBAT
  | PH_COMBAT:
      ResolveH2HAll;    (* resolve H2H for all adjacent pairs *)
      phase := PH_ELIM;
      CheckElimination;
      CheckVictory
  | PH_ELIM:
      IF activeSide = RED THEN
        activeSide := BLUE;
        ClearTurnFlags(BLUE);
        phase := PH_MOVE;
        DrawScreen;
        DoAITurn;
        CheckVictory;
        activeSide := RED;
        INC(turn);
        ClearTurnFlags(RED);
        phase := PH_MOVE
      END
  END
END AdvancePhase;

(* ═══════════════════════════════════════════════════════════════════════ *)
(*  Setup                                                                   *)
(* ═══════════════════════════════════════════════════════════════════════ *)

PROCEDURE InitTerrain;
VAR r, c: INTEGER;
BEGIN
  FOR r := 0 TO GRID_H - 1 DO
    FOR c := 0 TO GRID_W - 1 DO terrain[r][c] := TERR_OPEN END
  END
END InitTerrain;

(* Scenario 1: Pitched Battle.  Two symmetrical hill groups, cols 5-8. *)
PROCEDURE InitScenario1;
VAR r, c: INTEGER;
BEGIN
  InitTerrain;
  FOR r := 1 TO 3 DO
    FOR c := 5 TO 8 DO terrain[r][c] := TERR_HILL END
  END;
  FOR r := 8 TO 10 DO
    FOR c := 5 TO 8 DO terrain[r][c] := TERR_HILL END
  END
END InitScenario1;

(* Scenario 2: Crossroads.  Hill (rows 1-3, cols 2-5) + road junction.
   Vertical road: col 10, all rows.  Horizontal road: row 9, all cols. *)
PROCEDURE InitScenario2;
VAR r, c: INTEGER;
BEGIN
  InitTerrain;
  FOR r := 1 TO 3 DO
    FOR c := 2 TO 5 DO terrain[r][c] := TERR_HILL END
  END;
  FOR r := 0 TO GRID_H - 1 DO terrain[r][CROSS_COL] := TERR_ROAD END;
  FOR c := 0 TO GRID_W - 1 DO terrain[CROSS_ROW][c] := TERR_ROAD END
END InitScenario2;

(* Scenario 3: Control the River.
   Lake (impassable): rows 1-3, cols 8-10.
   River (row 6) splits the board; bridges at cols 1 and 9.
   Hills: rows 8-10, cols 1-3. *)
PROCEDURE InitScenario3;
VAR r, c: INTEGER;
BEGIN
  InitTerrain;
  FOR r := 1 TO 3 DO
    FOR c := 8 TO 10 DO terrain[r][c] := TERR_MARSH END
  END;
  FOR c := 0 TO GRID_W - 1 DO terrain[BRIDGE_ROW][c] := TERR_RIVER END;
  terrain[BRIDGE_ROW][BRIDGE1_COL] := TERR_BRIDGE;
  terrain[BRIDGE_ROW][BRIDGE2_COL] := TERR_BRIDGE;
  FOR r := 8 TO 10 DO
    FOR c := 1 TO 3 DO terrain[r][c] := TERR_HILL END
  END
END InitScenario3;

PROCEDURE DeployArmy(VAR a: Army; side: INTEGER; roll: INTEGER);
VAR i, p, col, row, t: INTEGER;
    startRow: INTEGER;
BEGIN
  p := period - 1;
  a.side  := side;
  a.count := MAX_UNITS;

  (* Red deploys on north rows (row 0..1); Blue on south (row 10..11) *)
  IF side = RED THEN startRow := 1 ELSE startRow := GRID_H - 2 END;

  (* Spread 6 units across 12 columns: positions 1,3,5,7,9,11.
     Step away from enemy if the default cell is water. *)
  FOR i := 0 TO MAX_UNITS - 1 DO
    a.units[i].utype      := compTable[p][roll][i];
    a.units[i].hits       := 0;
    col := 1 + i * 2;
    row := startRow;
    t := terrain[row][col];
    WHILE (t = TERR_MARSH) OR (t = TERR_RIVER) DO
      IF side = RED THEN DEC(row) ELSE INC(row) END;
      IF (row < 0) OR (row >= GRID_H) THEN row := startRow; t := TERR_OPEN
      ELSE t := terrain[row][col]
      END
    END;
    a.units[i].col        := col;
    a.units[i].row        := row;
    a.units[i].alive      := TRUE;
    a.units[i].ammoOut    := FALSE;
    a.units[i].inSquare   := FALSE;
    a.units[i].entrenched := FALSE;
    a.units[i].moved      := FALSE;
    a.units[i].shot       := FALSE;
    IF side = RED THEN a.units[i].facing := SOUTH
    ELSE               a.units[i].facing := NORTH
    END
  END
END DeployArmy;

PROCEDURE ClearLog;
VAR i: INTEGER;
BEGIN
  logHead := 0;
  FOR i := 0 TO 7 DO msgLog[i][0] := 0X END
END ClearLog;

PROCEDURE ChoosePeriod;
VAR i: INTEGER;
    ev2: TUI.Event;
BEGIN
  TUI.ClearBack(TUI.White, TUI.Black);
  TUI.PutStr(2, 1, "ONE HOUR WARGAMES — Choose Period", TUI.Yellow, TUI.Black);
  FOR i := 0 TO NPER - 1 DO
    TUI.PutCell(2, 3 + i, CHR(ORD('1') + i), TUI.Cyan, TUI.Black);
    TUI.PutStr(4, 3 + i, periodName[i], TUI.White, TUI.Black)
  END;
  TUI.PutStr(2, 13, "Press 1-9 to select:", TUI.White, TUI.Black);
  TUI.Flush;
  period := 1;
  LOOP
    TUI.WaitEvent(ev2);
    IF ev2.kind = TUI.EvKey THEN
      IF (ev2.key >= ORD('1')) & (ev2.key <= ORD('9')) THEN
        period := ev2.key - ORD('0'); EXIT
      ELSIF ev2.key = 17 THEN TUI.Done; HALT(0)
      END
    END
  END
END ChoosePeriod;

PROCEDURE ChooseScenario;
VAR ev2: TUI.Event;
BEGIN
  TUI.ClearBack(TUI.White, TUI.Black);
  TUI.PutStr(2, 1, "ONE HOUR WARGAMES — Choose Scenario", TUI.Yellow, TUI.Black);
  TUI.PutStr(2, 2, "──────────────────────────────────", TUI.White,  TUI.Black);
  TUI.PutCell(2, 4, '0', TUI.Cyan, TUI.Black);
  TUI.PutStr(4, 4, "Random (open ground)", TUI.White, TUI.Black);
  TUI.PutCell(2, 5, '1', TUI.Cyan, TUI.Black);
  TUI.PutStr(4, 5, "Scenario 1: Pitched Battle  (^ hills give H2H cover)", TUI.White, TUI.Black);
  TUI.PutCell(2, 6, '2', TUI.Cyan, TUI.Black);
  TUI.PutStr(4, 6, "Scenario 2: Crossroads  (hold hill + crossroads on turn 15)", TUI.White, TUI.Black);
  TUI.PutCell(2, 7, '3', TUI.Cyan, TUI.Black);
  TUI.PutStr(4, 7, "Scenario 3: Control the River  (hold both bridges on turn 15)", TUI.White, TUI.Black);
  TUI.PutStr(2, 9, "Press 0-3 to select:", TUI.White, TUI.Black);
  TUI.Flush;
  scenario := SCEN_RANDOM;
  LOOP
    TUI.WaitEvent(ev2);
    IF ev2.kind = TUI.EvKey THEN
      IF ev2.key = ORD('0') THEN scenario := SCEN_RANDOM; EXIT
      ELSIF ev2.key = ORD('1') THEN scenario := SCEN_1;      EXIT
      ELSIF ev2.key = ORD('2') THEN scenario := SCEN_2;      EXIT
      ELSIF ev2.key = ORD('3') THEN scenario := SCEN_3;      EXIT
      ELSIF ev2.key = 17 THEN TUI.Done; HALT(0)
      END
    END
  END
END ChooseScenario;

PROCEDURE ShowRoll(side: INTEGER; roll: INTEGER);
VAR sx, sy, i: INTEGER;
    u: Unit;
    a: Army;
    fg: INTEGER;
    n: ARRAY 4 OF CHAR;
BEGIN
  IF side = RED THEN sx := 2; sy := 0; fg := TUI.Red
  ELSE               sx := 2; sy := 8; fg := TUI.Cyan
  END;
  IF side = RED THEN TUI.PutStr(sx, sy, "Red army (die roll: ", fg, TUI.Black)
  ELSE               TUI.PutStr(sx, sy, "Blue army (die roll: ", fg, TUI.Black)
  END;
  IntStr(roll + 1, n);
  TUI.PutStr(sx + 21, sy, n, TUI.White, TUI.Black);
  TUI.PutStr(sx + 22, sy, ")", TUI.White, TUI.Black);
  a := ArmyOf(side);
  FOR i := 0 TO MAX_UNITS - 1 DO
    TUI.PutStr(sx + 2, sy + 1 + i,
               unitName[period - 1][a.units[i].utype],
               TUI.White, TUI.Black)
  END
END ShowRoll;

PROCEDURE SetupGame;
VAR rollR, rollB: INTEGER;
    ev2: TUI.Event;
BEGIN
  (* Init terrain first so DeployArmy can avoid water cells *)
  IF scenario = SCEN_1 THEN InitScenario1
  ELSIF scenario = SCEN_2 THEN InitScenario2
  ELSIF scenario = SCEN_3 THEN InitScenario3
  ELSE InitTerrain
  END;

  rollR := Random.Int(6); rollB := Random.Int(6);
  (* Re-roll if identical compositions *)
  WHILE rollR = rollB DO rollB := Random.Int(6) END;

  DeployArmy(red, RED, rollR);
  DeployArmy(blue, BLUE, rollB);

  TUI.ClearBack(TUI.White, TUI.Black);
  TUI.PutStr(2, 1, "Army Compositions", TUI.Yellow, TUI.Black);
  ShowRoll(RED, rollR);
  ShowRoll(BLUE, rollB);
  TUI.PutStr(2, 15, "Press any key to begin...", TUI.White, TUI.Black);
  TUI.Flush;
  LOOP
    TUI.WaitEvent(ev2);
    IF ev2.kind = TUI.EvKey THEN
      IF ev2.key = 17 THEN TUI.Done; HALT(0) END;
      EXIT
    END
  END;
  ClearLog;
  turn        := 1;
  phase       := PH_MOVE;
  activeSide  := RED;
  IF scenario = SCEN_2 THEN victoryType := VIC_HOLD
  ELSIF scenario = SCEN_3 THEN victoryType := VIC_BRIDGES
  ELSE victoryType := VIC_ELIM
  END;
  selUnit     := -1;
  undoTop     := 0;
  gameOver    := FALSE;
  curCol      := 0; curRow := 5;
  AppendLog("Game started. Red goes first.")
END SetupGame;

(* ═══════════════════════════════════════════════════════════════════════ *)
(*  Main Game Loop                                                          *)
(* ═══════════════════════════════════════════════════════════════════════ *)

PROCEDURE RunGame;
VAR mc, mr: INTEGER;
BEGIN
  DrawScreen;
  LOOP
    TUI.WaitEvent(ev);
    IF ev.kind = TUI.EvResize THEN TUI.UpdateSize

    ELSIF ev.kind = TUI.EvMouse THEN
      (* Left click or motion — move cursor to clicked map cell *)
      IF (ev.mb = 0) OR (ev.mb = 32) THEN
        mc := (ev.mx - MAPX) DIV 2;
        mr := ev.my - MAPY;
        IF (mc >= 0) & (mc < GRID_W) & (mr >= 0) & (mr < GRID_H) THEN
          curCol := mc; curRow := mr
        END
      END

    ELSIF ev.kind = TUI.EvKey THEN
      IF (ev.key = ORD('q')) OR (ev.key = ORD('Q')) OR (ev.key = 17) THEN
        EXIT
      END;
      IF gameOver THEN (* any key exits *) EXIT END;

      IF activeSide = RED THEN
        CASE phase OF
          PH_MOVE:
            IF (ev.key = ORD('n')) OR (ev.key = ORD('N')) THEN
              AdvancePhase
            ELSE
              HandleMovePhase(ev.key)
            END
        | PH_SHOOT:
            IF (ev.key = ORD('n')) OR (ev.key = ORD('N')) THEN
              AdvancePhase
            ELSE
              HandleShootPhase(ev.key)
            END
        | PH_COMBAT:
            AdvancePhase   (* auto-resolve, then advance *)
        | PH_ELIM:
            AdvancePhase
        END
      END
    END;
    DrawScreen
  END
END RunGame;

(* ═══════════════════════════════════════════════════════════════════════ *)
(*  Entry Point                                                             *)
(* ═══════════════════════════════════════════════════════════════════════ *)

BEGIN
  InitTables;
  TUI.Init;
  TUI.UpdateSize;
  ChoosePeriod;
  ChooseScenario;
  SetupGame;
  RunGame;
  TUI.Done
END Wargame.
