MODULE Swords;
(*
 * Swords & Spells: Fantastic Miniatures Rules (Gygax, 1976)
 * TUI adaptation — Human (Red, south) vs Computer (Blue, north).
 *
 * Scale: 1:10, 1 cell ≈ 1 inch.  HP tracks damage; figures removed every
 * hpPerFig HP.  Combat table gives HP per attacking figure vs defender AC.
 * Morale: d100 <= adjusted score to stand; failure drops one of 5 levels.
 *
 * Controls:
 *   Arrow keys – move cursor
 *   Enter      – select unit / confirm move or fire
 *   Esc        – cancel selection / deselect commander
 *   N          – next phase
 *   V          – toggle verbose AI
 *   Q / Ctrl-Q – quit
 *   Ctrl-L     – force screen redraw
 *)

IMPORT TUI, Random;

CONST
  GRID_W = 14;  GRID_H = 10;
  MAX_UNITS = 8;
  TURNS = 20;
  RED = 0;  BLUE = 1;

  (* Unit types *)
  LEVY   = 0;  (* levy infantry    AC5 HD1  1-6 mv3 *)
  SWORD  = 1;  (* regular infantry AC4 HD1  1-6 mv3 *)
  ARCHER = 2;  (* bowmen           AC6 HD1  1-3 bow7 mv3 *)
  PIKE   = 3;  (* pikemen          AC4 HD1  1-6 mv2 reach2 *)
  ELITE  = 4;  (* elite guards     AC3 HD2  1-8 mv3 *)
  LCAV   = 5;  (* light cavalry    AC5 HD2  1-6 mv6 *)
  HCAV   = 6;  (* heavy cavalry    AC3 HD3  1-8 mv5 charge *)
  DWARF  = 7;  (* dwarves          AC3 HD1  1-6 mv2 stalwart *)
  ELF    = 8;  (* elves            AC4 HD2  1-6 bow7 mv4 *)
  ORC    = 9;  (* orcs             AC6 HD1  1-6 mv3 *)
  NTYPES = 10;

  (* Weapon damage categories (multiplier vs 1-6 baseline) *)
  DMG_SMALL = 0;  (* 1-3:  x57/100 — bows, daggers *)
  DMG_MED   = 1;  (* 1-6:  x100   — swords, spears *)
  DMG_LARGE = 2;  (* 1-8:  x132/100 — bastard swords, lances *)

  (* Attack bands: attacker HD/level -> damage table row *)
  BND_HALF  = 0;   (* HD <1  / Lv 0    *)
  BND_ONE   = 1;   (* HD 1   / Lv 1-3  *)
  BND_TWO   = 2;   (* HD 2   / Lv 4-6  *)
  BND_THREE = 3;   (* HD 3   / Lv 7-9  *)
  BND_FOUR  = 4;   (* HD 4+  / Lv 10+  *)
  NBANDS    = 5;
  N_AC      = 10;  (* AC 9 .. AC 0; acIdx = 9 - AC *)

  (* Morale levels (5 progressive) *)
  ML_ELITE    = 0;
  ML_REGULAR  = 1;
  ML_SHAKEN   = 2;
  ML_DISORDER = 3;
  ML_ROUTED   = 4;

  (* Turn phases *)
  PH_SHOOT  = 0;
  PH_MOVE   = 1;
  PH_COMBAT = 2;
  PH_ELIM   = 3;

  (* Terrain *)
  TERR_OPEN  = 0;
  TERR_HILL  = 1;
  TERR_WOOD  = 2;
  TERR_MARSH = 3;

  FIGS_START = 10;
  CMD_MOVE   = 4;

  MAPX = 4;  MAPY = 2;
  SIDEX = 34;

TYPE
  Unit = RECORD
    utype      : INTEGER;
    figures    : INTEGER;  (* current figure count *)
    totalHp    : INTEGER;  (* current total hit points *)
    hpPerFig   : INTEGER;  (* HP per scale figure *)
    col, row   : INTEGER;
    alive      : BOOLEAN;
    moved      : BOOLEAN;
    morale     : INTEGER;  (* ML_ELITE .. ML_ROUTED *)
    baseScore  : INTEGER;  (* base d100 score (roll <= score to stand) *)
    meleeWins  : INTEGER;  (* accumulated melee victories *)
    shotsLeft  : INTEGER;
    charged    : BOOLEAN;
    inMelee    : BOOLEAN;
  END;

  Army = RECORD
    units    : ARRAY MAX_UNITS OF Unit;
    count    : INTEGER;
    side     : INTEGER;
    cmdAlive : BOOLEAN;
    cmdCol   : INTEGER;
    cmdRow   : INTEGER;
    cmdMoved : BOOLEAN;
  END;

VAR
  turn      : INTEGER;
  phase     : INTEGER;
  red, blue : Army;
  terrain   : ARRAY GRID_H OF ARRAY GRID_W OF INTEGER;

  (* Damage per attacking figure for 1-6 weapons: dmgTable[band][9-AC] *)
  dmgTable  : ARRAY NBANDS OF ARRAY N_AC OF INTEGER;

  unitName   : ARRAY NTYPES OF ARRAY 10 OF CHAR;
  unitGlyph  : ARRAY NTYPES OF CHAR;
  unitAC     : ARRAY NTYPES OF INTEGER;
  unitBand   : ARRAY NTYPES OF INTEGER;
  unitDmgCat : ARRAY NTYPES OF INTEGER;
  unitMove   : ARRAY NTYPES OF INTEGER;
  unitHpFig  : ARRAY NTYPES OF INTEGER;
  unitBaseML : ARRAY NTYPES OF INTEGER;
  unitHasBow      : ARRAY NTYPES OF BOOLEAN;
  unitBowRng      : ARRAY NTYPES OF INTEGER;
  unitShotsPerTurn: ARRAY NTYPES OF INTEGER;
  unitIsElite : ARRAY NTYPES OF BOOLEAN;
  unitIsCav   : ARRAY NTYPES OF BOOLEAN;
  unitCost    : ARRAY NTYPES OF INTEGER;
  unitDesc   : ARRAY NTYPES OF ARRAY 32 OF CHAR;

  msgLog    : ARRAY 64 OF ARRAY 72 OF CHAR;
  logHead   : INTEGER;
  logScroll : INTEGER;

  curCol, curRow : INTEGER;
  selUnit        : INTEGER;
  cmdSelected    : BOOLEAN;
  gameOver       : BOOLEAN;
  verboseAI      : BOOLEAN;
  ev             : TUI.Event;

(* ════════════════════════════════════════════════════════════════════════ *)
(*  Table Initialisation                                                    *)
(* ════════════════════════════════════════════════════════════════════════ *)

PROCEDURE SetRow(b, a0,a1,a2,a3,a4,a5,a6,a7,a8,a9: INTEGER);
BEGIN
  dmgTable[b][0]:=a0; dmgTable[b][1]:=a1; dmgTable[b][2]:=a2;
  dmgTable[b][3]:=a3; dmgTable[b][4]:=a4; dmgTable[b][5]:=a5;
  dmgTable[b][6]:=a6; dmgTable[b][7]:=a7; dmgTable[b][8]:=a8;
  dmgTable[b][9]:=a9
END SetRow;

PROCEDURE InitTables;
(*
 * dmgTable[band][acIdx] = HP damage per attacking figure for 1-6 weapons.
 * Derived from S&S combat table (1-6 column), AC 9 (index 0) to AC 0 (index 9).
 *)
BEGIN
  SetRow(BND_HALF,  18,16,14,12,11, 9, 7, 5, 4, 2);
  SetRow(BND_ONE,   19,18,16,14,12,11, 9, 7, 5, 4);
  SetRow(BND_TWO,   23,21,19,18,16,14,12,11, 9, 7);
  SetRow(BND_THREE, 28,26,25,23,21,19,18,16,14,12);
  SetRow(BND_FOUR,  32,30,28,26,25,23,21,19,18,16);

  COPY("Levy",    unitName[LEVY]);   unitGlyph[LEVY]   := 'L';
  COPY("Sword",   unitName[SWORD]);  unitGlyph[SWORD]  := 'S';
  COPY("Archers", unitName[ARCHER]); unitGlyph[ARCHER] := 'A';
  COPY("Pikemen", unitName[PIKE]);   unitGlyph[PIKE]   := 'P';
  COPY("Elite",   unitName[ELITE]);  unitGlyph[ELITE]  := 'E';
  COPY("Lt.Cav",  unitName[LCAV]);   unitGlyph[LCAV]   := 'c';
  COPY("Hv.Cav",  unitName[HCAV]);   unitGlyph[HCAV]   := 'K';
  COPY("Dwarves", unitName[DWARF]);  unitGlyph[DWARF]  := 'D';
  COPY("Elves",   unitName[ELF]);    unitGlyph[ELF]    := 'V';
  COPY("Orcs",    unitName[ORC]);    unitGlyph[ORC]    := 'O';

  COPY("Levy; poor morale, cheap",       unitDesc[LEVY]);
  COPY("Regular swordsmen",              unitDesc[SWORD]);
  COPY("Longbow; range 7, 1-3 melee",    unitDesc[ARCHER]);
  COPY("Pikes; reach 2, slow",           unitDesc[PIKE]);
  COPY("Elite guards; HD2, 1-8 dmg",     unitDesc[ELITE]);
  COPY("Fast cavalry; mv 6, charge",     unitDesc[LCAV]);
  COPY("Knights; HD3, 1-8, mv5 charge",  unitDesc[HCAV]);
  COPY("Dwarves; stalwart, tough",       unitDesc[DWARF]);
  COPY("Elves; elite bow+sword, mv 4",   unitDesc[ELF]);
  COPY("Orcs; cheap, brutal",            unitDesc[ORC]);

  unitAC[LEVY]  :=5; unitAC[SWORD] :=4; unitAC[ARCHER]:=6;
  unitAC[PIKE]  :=4; unitAC[ELITE] :=3; unitAC[LCAV]  :=5;
  unitAC[HCAV]  :=3; unitAC[DWARF] :=3; unitAC[ELF]   :=4;
  unitAC[ORC]   :=6;

  unitBand[LEVY]  :=BND_ONE;   unitBand[SWORD] :=BND_ONE;
  unitBand[ARCHER]:=BND_ONE;   unitBand[PIKE]  :=BND_ONE;
  unitBand[ELITE] :=BND_TWO;   unitBand[LCAV]  :=BND_TWO;
  unitBand[HCAV]  :=BND_THREE; unitBand[DWARF] :=BND_ONE;
  unitBand[ELF]   :=BND_TWO;   unitBand[ORC]   :=BND_ONE;

  unitDmgCat[LEVY]  :=DMG_MED;   unitDmgCat[SWORD] :=DMG_MED;
  unitDmgCat[ARCHER]:=DMG_SMALL; unitDmgCat[PIKE]  :=DMG_MED;
  unitDmgCat[ELITE] :=DMG_LARGE; unitDmgCat[LCAV]  :=DMG_MED;
  unitDmgCat[HCAV]  :=DMG_LARGE; unitDmgCat[DWARF] :=DMG_MED;
  unitDmgCat[ELF]   :=DMG_MED;   unitDmgCat[ORC]   :=DMG_MED;

  unitMove[LEVY]  :=3; unitMove[SWORD] :=3; unitMove[ARCHER]:=3;
  unitMove[PIKE]  :=2; unitMove[ELITE] :=3; unitMove[LCAV]  :=6;
  unitMove[HCAV]  :=5; unitMove[DWARF] :=2; unitMove[ELF]   :=4;
  unitMove[ORC]   :=3;

  (* hpPerFig = avgHD x 4.5 x 10, rounded; mounted adds mount HP *)
  unitHpFig[LEVY]  :=45;  unitHpFig[SWORD] :=45;  unitHpFig[ARCHER]:=45;
  unitHpFig[PIKE]  :=45;  unitHpFig[ELITE] :=90;  unitHpFig[LCAV]  :=90;
  unitHpFig[HCAV]  :=135; unitHpFig[DWARF] :=55;  unitHpFig[ELF]   :=55;
  unitHpFig[ORC]   :=45;

  (* Base d100 morale score: roll <= score to stand.
     Built from S&S table (HD 1-2 = 40) plus race/class adjustments. *)
  unitBaseML[LEVY]  :=35;  (* 40 - 5 levy *)
  unitBaseML[SWORD] :=45;  (* 40 + 5 men *)
  unitBaseML[ARCHER]:=45;  (* 40 + 5 men *)
  unitBaseML[PIKE]  :=50;  (* 40 + 5 men + 5 formation *)
  unitBaseML[ELITE] :=65;  (* 40 + 5 men + 10 elite + 10 guards *)
  unitBaseML[LCAV]  :=55;  (* 45 + 5 men + 5 mounted *)
  unitBaseML[HCAV]  :=70;  (* 50 + 5 men + 5 mounted + 10 heavy cav *)
  unitBaseML[DWARF] :=65;  (* 40 + 5 men + 10 elite + 10 dwarf bonus *)
  unitBaseML[ELF]   :=65;  (* 40 + 10 elf + 5 elite + 10 in formation *)
  unitBaseML[ORC]   :=40;

  unitHasBow[LEVY]  :=FALSE; unitHasBow[SWORD] :=FALSE;
  unitHasBow[ARCHER]:=TRUE;  unitHasBow[PIKE]  :=FALSE;
  unitHasBow[ELITE] :=FALSE; unitHasBow[LCAV]  :=FALSE;
  unitHasBow[HCAV]  :=FALSE; unitHasBow[DWARF] :=FALSE;
  unitHasBow[ELF]   :=TRUE;  unitHasBow[ORC]   :=FALSE;

  unitBowRng[LEVY]  :=0; unitBowRng[SWORD] :=0; unitBowRng[ARCHER]:=7;
  unitBowRng[PIKE]  :=0; unitBowRng[ELITE] :=0; unitBowRng[LCAV]  :=0;
  unitBowRng[HCAV]  :=0; unitBowRng[DWARF] :=0; unitBowRng[ELF]   :=7;
  unitBowRng[ORC]   :=0;

  (* Book gives longbows 3 shots/turn; other bow units also 3 *)
  unitShotsPerTurn[LEVY]  :=0; unitShotsPerTurn[SWORD] :=0; unitShotsPerTurn[ARCHER]:=3;
  unitShotsPerTurn[PIKE]  :=0; unitShotsPerTurn[ELITE] :=0; unitShotsPerTurn[LCAV]  :=0;
  unitShotsPerTurn[HCAV]  :=0; unitShotsPerTurn[DWARF] :=0; unitShotsPerTurn[ELF]   :=3;
  unitShotsPerTurn[ORC]   :=0;

  unitIsElite[LEVY]  :=FALSE; unitIsElite[SWORD] :=FALSE;
  unitIsElite[ARCHER]:=FALSE; unitIsElite[PIKE]  :=FALSE;
  unitIsElite[ELITE] :=TRUE;  unitIsElite[LCAV]  :=FALSE;
  unitIsElite[HCAV]  :=TRUE;  unitIsElite[DWARF] :=TRUE;
  unitIsElite[ELF]   :=TRUE;  unitIsElite[ORC]   :=FALSE;

  unitIsCav[LEVY]  :=FALSE; unitIsCav[SWORD] :=FALSE;
  unitIsCav[ARCHER]:=FALSE; unitIsCav[PIKE]  :=FALSE;
  unitIsCav[ELITE] :=FALSE; unitIsCav[LCAV]  :=TRUE;
  unitIsCav[HCAV]  :=TRUE;  unitIsCav[DWARF] :=FALSE;
  unitIsCav[ELF]   :=FALSE; unitIsCav[ORC]   :=FALSE;

  unitCost[LEVY]  :=1; unitCost[SWORD] :=2; unitCost[ARCHER]:=3;
  unitCost[PIKE]  :=2; unitCost[ELITE] :=5; unitCost[LCAV]  :=4;
  unitCost[HCAV]  :=7; unitCost[DWARF] :=4; unitCost[ELF]   :=5;
  unitCost[ORC]   :=1
END InitTables;

(* ════════════════════════════════════════════════════════════════════════ *)
(*  Utility                                                                 *)
(* ════════════════════════════════════════════════════════════════════════ *)

PROCEDURE D100(): INTEGER;
BEGIN RETURN Random.Int(100) + 1 END D100;

PROCEDURE ArmyOf(side: INTEGER): Army;
BEGIN IF side = RED THEN RETURN red ELSE RETURN blue END END ArmyOf;

PROCEDURE SetArmy(side: INTEGER; a: Army);
BEGIN IF side = RED THEN red := a ELSE blue := a END END SetArmy;

PROCEDURE UnitAt(col, row: INTEGER; VAR uSide, uIdx: INTEGER);
VAR i: INTEGER;
BEGIN
  uSide := -1; uIdx := -1;
  FOR i := 0 TO red.count - 1 DO
    IF red.units[i].alive & (red.units[i].col = col) & (red.units[i].row = row) THEN
      uSide := RED; uIdx := i; RETURN
    END
  END;
  FOR i := 0 TO blue.count - 1 DO
    IF blue.units[i].alive & (blue.units[i].col = col) & (blue.units[i].row = row) THEN
      uSide := BLUE; uIdx := i; RETURN
    END
  END
END UnitAt;

PROCEDURE OccupiedBy(col, row, side: INTEGER): BOOLEAN;
VAR a: Army; i: INTEGER;
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

PROCEDURE CDist(c1, r1, c2, r2: INTEGER): INTEGER;
BEGIN RETURN Max(Abs(c1 - c2), Abs(r1 - r2)) END CDist;

PROCEDURE AppendLog(msg: ARRAY OF CHAR);
BEGIN
  COPY(msg, msgLog[logHead MOD 64]);
  INC(logHead);
  IF logScroll > 0 THEN INC(logScroll) END
END AppendLog;

PROCEDURE IntStr(n: INTEGER; VAR s: ARRAY OF CHAR);
VAR buf: ARRAY 12 OF CHAR; i, j, len: INTEGER; neg: BOOLEAN;
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
VAR i, j: INTEGER;
BEGIN
  i := 0; WHILE dst[i] # 0X DO INC(i) END;
  j := 0; WHILE (src[j] # 0X) & (i < LEN(dst) - 1) DO
    dst[i] := src[j]; INC(i); INC(j)
  END;
  dst[i] := 0X
END AppendStr;

(* ════════════════════════════════════════════════════════════════════════ *)
(*  Movement Validity                                                       *)
(* ════════════════════════════════════════════════════════════════════════ *)

PROCEDURE ValidMoveTarget(side, idx, dstCol, dstRow: INTEGER): BOOLEAN;
VAR mv, srcCol, srcRow, oSide, oIdx: INTEGER;
    u: Unit; a: Army;
BEGIN
  a := ArmyOf(side); u := a.units[idx];
  IF u.morale >= ML_DISORDER THEN RETURN FALSE END;
  mv := unitMove[u.utype];
  IF u.morale = ML_SHAKEN THEN mv := mv DIV 2; IF mv < 1 THEN mv := 1 END END;
  srcCol := u.col; srcRow := u.row;
  IF (dstCol < 0) OR (dstCol >= GRID_W) OR (dstRow < 0) OR (dstRow >= GRID_H) THEN
    RETURN FALSE
  END;
  IF (dstCol = srcCol) & (dstRow = srcRow) THEN RETURN FALSE END;
  IF CDist(srcCol, srcRow, dstCol, dstRow) > mv THEN RETURN FALSE END;
  IF terrain[dstRow][dstCol] = TERR_MARSH THEN RETURN FALSE END;
  IF unitIsCav[u.utype] THEN
    IF terrain[dstRow][dstCol] = TERR_WOOD THEN RETURN FALSE END;
    IF terrain[dstRow][dstCol] = TERR_HILL THEN
      IF CDist(srcCol, srcRow, dstCol, dstRow) > mv DIV 2 THEN RETURN FALSE END
    END
  END;
  UnitAt(dstCol, dstRow, oSide, oIdx);
  RETURN oSide < 0
END ValidMoveTarget;

PROCEDURE ValidCmdMove(side, dstCol, dstRow: INTEGER): BOOLEAN;
VAR a: Army;
BEGIN
  a := ArmyOf(side);
  IF ~a.cmdAlive OR a.cmdMoved THEN RETURN FALSE END;
  IF (dstCol < 0) OR (dstCol >= GRID_W) OR (dstRow < 0) OR (dstRow >= GRID_H) THEN
    RETURN FALSE
  END;
  IF CDist(a.cmdCol, a.cmdRow, dstCol, dstRow) > CMD_MOVE THEN RETURN FALSE END;
  IF (dstCol = a.cmdCol) & (dstRow = a.cmdRow) THEN RETURN FALSE END;
  IF OccupiedBy(dstCol, dstRow, 1 - side) THEN RETURN FALSE END;
  RETURN TRUE
END ValidCmdMove;

(* ════════════════════════════════════════════════════════════════════════ *)
(*  Missile Fire                                                            *)
(* ════════════════════════════════════════════════════════════════════════ *)

PROCEDURE CanShootTarget(side, idx, tCol, tRow: INTEGER): BOOLEAN;
VAR u: Unit; a: Army;
BEGIN
  a := ArmyOf(side); u := a.units[idx];
  IF ~unitHasBow[u.utype] THEN RETURN FALSE END;
  IF u.shotsLeft <= 0 THEN RETURN FALSE END;
  IF u.inMelee THEN RETURN FALSE END;
  IF CDist(u.col, u.row, tCol, tRow) > unitBowRng[u.utype] THEN RETURN FALSE END;
  RETURN TRUE
END CanShootTarget;

(* ════════════════════════════════════════════════════════════════════════ *)
(*  Damage and Morale                                                       *)
(* ════════════════════════════════════════════════════════════════════════ *)

PROCEDURE CalcDamage(atkBand, defAC, atkFigs, dmgCat: INTEGER): INTEGER;
VAR acIdx, base, total: INTEGER;
BEGIN
  acIdx := 9 - defAC;
  IF acIdx < 0 THEN acIdx := 0 END;
  IF acIdx >= N_AC THEN acIdx := N_AC - 1 END;
  base := dmgTable[atkBand][acIdx];
  IF dmgCat = DMG_SMALL THEN total := base * 57 DIV 100
  ELSIF dmgCat = DMG_LARGE THEN total := base * 132 DIV 100
  ELSE total := base
  END;
  RETURN total * atkFigs
END CalcDamage;

PROCEDURE CmdMoraleBonus(side, col, row: INTEGER): INTEGER;
VAR a: Army;
BEGIN
  a := ArmyOf(side);
  IF a.cmdAlive & (CDist(a.cmdCol, a.cmdRow, col, row) <= 3) THEN RETURN 30 END;
  RETURN 0
END CmdMoraleBonus;

PROCEDURE RetreatUnit(side, idx, steps: INTEGER);
VAR nc, nr, prevNr, i: INTEGER; a: Army;
BEGIN
  a := ArmyOf(side);
  nc := a.units[idx].col; nr := a.units[idx].row;
  i := 0;
  WHILE i < steps DO
    INC(i); prevNr := nr;
    IF side = RED THEN
      IF nr > 0 THEN DEC(nr) END
    ELSE
      IF nr < GRID_H - 1 THEN INC(nr) END
    END;
    IF (terrain[nr][nc] = TERR_MARSH) OR
       OccupiedBy(nc, nr, RED) OR OccupiedBy(nc, nr, BLUE) THEN
      nr := prevNr; i := steps
    END
  END;
  IF side = RED THEN red.units[idx].col := nc; red.units[idx].row := nr
  ELSE blue.units[idx].col := nc; blue.units[idx].row := nr
  END
END RetreatUnit;

PROCEDURE NearbyUnitModifier(side, col, row: INTEGER): INTEGER;
(* Nearby disordered/routed enemy = bonus; nearby disordered/routed friendly = penalty *)
VAR i, dist, mod: INTEGER;
BEGIN
  mod := 0;
  IF side = RED THEN
    FOR i := 0 TO blue.count - 1 DO
      IF blue.units[i].alive THEN
        dist := CDist(col, row, blue.units[i].col, blue.units[i].row);
        IF dist <= 6 THEN
          IF blue.units[i].morale = ML_DISORDER THEN INC(mod, 5)
          ELSIF blue.units[i].morale >= ML_ROUTED THEN INC(mod, 10)
          END
        END
      END
    END;
    FOR i := 0 TO red.count - 1 DO
      IF red.units[i].alive THEN
        dist := CDist(col, row, red.units[i].col, red.units[i].row);
        IF dist <= 6 THEN
          IF red.units[i].morale = ML_DISORDER THEN DEC(mod, 5)
          ELSIF red.units[i].morale >= ML_ROUTED THEN DEC(mod, 10)
          END
        END
      END
    END
  ELSE
    FOR i := 0 TO red.count - 1 DO
      IF red.units[i].alive THEN
        dist := CDist(col, row, red.units[i].col, red.units[i].row);
        IF dist <= 6 THEN
          IF red.units[i].morale = ML_DISORDER THEN INC(mod, 5)
          ELSIF red.units[i].morale >= ML_ROUTED THEN INC(mod, 10)
          END
        END
      END
    END;
    FOR i := 0 TO blue.count - 1 DO
      IF blue.units[i].alive THEN
        dist := CDist(col, row, blue.units[i].col, blue.units[i].row);
        IF dist <= 6 THEN
          IF blue.units[i].morale = ML_DISORDER THEN DEC(mod, 5)
          ELSIF blue.units[i].morale >= ML_ROUTED THEN DEC(mod, 10)
          END
        END
      END
    END
  END;
  RETURN mod
END NearbyUnitModifier;

PROCEDURE CheckMorale(side, idx, modifier: INTEGER;
                      reason: ARRAY OF CHAR): BOOLEAN;
VAR a: Army; u: Unit; score, roll: INTEGER;
    numStr: ARRAY 8 OF CHAR; msg, mlStr: ARRAY 72 OF CHAR;
BEGIN
  a := ArmyOf(side); u := a.units[idx];
  IF u.morale >= ML_ROUTED THEN RETURN FALSE END;
  score := u.baseScore;
  INC(score, u.meleeWins * 5);
  INC(score, CmdMoraleBonus(side, u.col, u.row));
  INC(score, NearbyUnitModifier(side, u.col, u.row));
  DEC(score, u.morale * 10);
  INC(score, modifier);
  IF score < 1 THEN score := 1 END;
  IF score > 99 THEN score := 99 END;
  roll := D100();
  IF side = RED THEN COPY("R.", msg) ELSE COPY("B.", msg) END;
  AppendStr(msg, unitName[u.utype]);
  AppendStr(msg, " morale("); AppendStr(msg, reason); AppendStr(msg, ")");
  AppendStr(msg, "<="); IntStr(score, numStr); AppendStr(msg, numStr);
  AppendStr(msg, ":"); IntStr(roll, numStr); AppendStr(msg, numStr);
  IF roll <= score THEN
    AppendStr(msg, " holds"); AppendLog(msg);
    RETURN TRUE
  ELSE
    AppendStr(msg, " fails!");
    AppendLog(msg);
    IF side = RED THEN
      INC(red.units[idx].morale);
      IF red.units[idx].morale = ML_SHAKEN THEN RetreatUnit(RED, idx, 1)
      ELSIF red.units[idx].morale = ML_DISORDER THEN RetreatUnit(RED, idx, 2)
      ELSIF red.units[idx].morale >= ML_ROUTED THEN RetreatUnit(RED, idx, 3)
      END
    ELSE
      INC(blue.units[idx].morale);
      IF blue.units[idx].morale = ML_SHAKEN THEN RetreatUnit(BLUE, idx, 1)
      ELSIF blue.units[idx].morale = ML_DISORDER THEN RetreatUnit(BLUE, idx, 2)
      ELSIF blue.units[idx].morale >= ML_ROUTED THEN RetreatUnit(BLUE, idx, 3)
      END
    END;
    RETURN FALSE
  END
END CheckMorale;

PROCEDURE ApplyDamage(side, idx, dmgAmt: INTEGER);
VAR prevFigs, newFigs: INTEGER;
BEGIN
  IF side = RED THEN
    DEC(red.units[idx].totalHp, dmgAmt);
    IF red.units[idx].totalHp < 0 THEN red.units[idx].totalHp := 0 END;
    prevFigs := red.units[idx].figures;
    newFigs  := red.units[idx].totalHp DIV red.units[idx].hpPerFig;
    red.units[idx].figures := newFigs;
    IF (newFigs <= FIGS_START * 3 DIV 4) & (prevFigs > FIGS_START * 3 DIV 4) THEN
      IF ~CheckMorale(RED, idx, 0, "25%") THEN END
    END;
    IF (newFigs <= FIGS_START DIV 2) & (prevFigs > FIGS_START DIV 2) THEN
      IF ~CheckMorale(RED, idx, -5, "50%") THEN END
    END;
    IF (newFigs <= FIGS_START DIV 4) & (prevFigs > FIGS_START DIV 4) THEN
      IF ~CheckMorale(RED, idx, -15, "75%") THEN END
    END
  ELSE
    DEC(blue.units[idx].totalHp, dmgAmt);
    IF blue.units[idx].totalHp < 0 THEN blue.units[idx].totalHp := 0 END;
    prevFigs := blue.units[idx].figures;
    newFigs  := blue.units[idx].totalHp DIV blue.units[idx].hpPerFig;
    blue.units[idx].figures := newFigs;
    IF (newFigs <= FIGS_START * 3 DIV 4) & (prevFigs > FIGS_START * 3 DIV 4) THEN
      IF ~CheckMorale(BLUE, idx, 0, "25%") THEN END
    END;
    IF (newFigs <= FIGS_START DIV 2) & (prevFigs > FIGS_START DIV 2) THEN
      IF ~CheckMorale(BLUE, idx, -5, "50%") THEN END
    END;
    IF (newFigs <= FIGS_START DIV 4) & (prevFigs > FIGS_START DIV 4) THEN
      IF ~CheckMorale(BLUE, idx, -15, "75%") THEN END
    END
  END
END ApplyDamage;

PROCEDURE ResolveShot(attSide, attIdx, defSide, defIdx: INTEGER;
                      VAR msg: ARRAY OF CHAR);
VAR att, def: Unit; aArmy, dArmy: Army;
    rng, dmg, rangePct: INTEGER;
    numStr: ARRAY 8 OF CHAR;
    attLabel, defLabel: ARRAY 16 OF CHAR;
BEGIN
  aArmy := ArmyOf(attSide); att := aArmy.units[attIdx];
  dArmy := ArmyOf(defSide); def := dArmy.units[defIdx];
  IF attSide = RED THEN COPY("R.", attLabel) ELSE COPY("B.", attLabel) END;
  AppendStr(attLabel, unitName[att.utype]);
  IF defSide = RED THEN COPY("R.", defLabel) ELSE COPY("B.", defLabel) END;
  AppendStr(defLabel, unitName[def.utype]);
  rng := CDist(att.col, att.row, def.col, def.row);
  (* Range penalty from S&S missile table *)
  IF rng <= unitBowRng[att.utype] * 1 DIV 3 THEN rangePct := 100
  ELSIF rng <= unitBowRng[att.utype] * 2 DIV 3 THEN rangePct := 80
  ELSE rangePct := 70
  END;
  (* Cover: woods -30%, hill -10% *)
  IF terrain[def.row][def.col] = TERR_WOOD THEN rangePct := rangePct * 70 DIV 100 END;
  IF terrain[def.row][def.col] = TERR_HILL THEN rangePct := rangePct * 90 DIV 100 END;
  dmg := CalcDamage(unitBand[att.utype], unitAC[def.utype],
                    att.figures, DMG_SMALL) * rangePct DIV 100;
  COPY(attLabel, msg); AppendStr(msg, "->"); AppendStr(msg, defLabel);
  AppendStr(msg, " bow:"); IntStr(dmg, numStr); AppendStr(msg, numStr);
  AppendStr(msg, "hp");
  IF attSide = RED THEN DEC(red.units[attIdx].shotsLeft)
  ELSE DEC(blue.units[attIdx].shotsLeft)
  END;
  ApplyDamage(defSide, defIdx, dmg)
END ResolveShot;

PROCEDURE ResolveMelee(attSide, attIdx, defSide, defIdx: INTEGER;
                       VAR msg: ARRAY OF CHAR);
VAR att, def: Unit; aArmy, dArmy: Army;
    atkBand, defBand: INTEGER;
    dmg1, dmg2: INTEGER;
    numStr: ARRAY 8 OF CHAR;
    attLabel, defLabel: ARRAY 16 OF CHAR;
BEGIN
  aArmy := ArmyOf(attSide); att := aArmy.units[attIdx];
  dArmy := ArmyOf(defSide); def := dArmy.units[defIdx];
  IF attSide = RED THEN red.units[attIdx].inMelee := TRUE
  ELSE blue.units[attIdx].inMelee := TRUE END;
  IF defSide = RED THEN red.units[defIdx].inMelee := TRUE
  ELSE blue.units[defIdx].inMelee := TRUE END;
  IF attSide = RED THEN COPY("R.", attLabel) ELSE COPY("B.", attLabel) END;
  AppendStr(attLabel, unitName[att.utype]);
  IF defSide = RED THEN COPY("R.", defLabel) ELSE COPY("B.", defLabel) END;
  AppendStr(defLabel, unitName[def.utype]);

  atkBand := unitBand[att.utype];
  defBand := unitBand[def.utype];

  (* Flank: attacker and defender not aligned cardinal -> +1 attack band *)
  IF (att.col # def.col) & (att.row # def.row) THEN
    IF atkBand < BND_FOUR THEN INC(atkBand) END
  END;

  dmg1 := CalcDamage(atkBand, unitAC[def.utype], att.figures, unitDmgCat[att.utype]);
  IF att.charged & unitIsCav[att.utype] THEN dmg1 := dmg1 * 5 DIV 4 END;
  IF terrain[def.row][def.col] = TERR_HILL THEN dmg1 := dmg1 DIV 2 END;

  dmg2 := 0;
  IF def.morale < ML_DISORDER THEN
    dmg2 := CalcDamage(defBand, unitAC[att.utype], def.figures, unitDmgCat[def.utype]);
    IF terrain[att.row][att.col] = TERR_HILL THEN dmg2 := dmg2 DIV 2 END
  END;

  COPY(attLabel, msg); AppendStr(msg, "->"); AppendStr(msg, defLabel);
  AppendStr(msg, " "); IntStr(dmg1, numStr); AppendStr(msg, numStr);
  AppendStr(msg, "/"); IntStr(dmg2, numStr); AppendStr(msg, numStr);
  AppendStr(msg, " hp");
  IF att.charged & unitIsCav[att.utype] THEN AppendStr(msg, " CHG") END;

  ApplyDamage(defSide, defIdx, dmg1);
  IF dmg2 > 0 THEN ApplyDamage(attSide, attIdx, dmg2) END;

  IF dmg1 > dmg2 THEN
    IF attSide = RED THEN INC(red.units[attIdx].meleeWins)
    ELSE INC(blue.units[attIdx].meleeWins) END
  ELSIF dmg2 > dmg1 THEN
    IF defSide = RED THEN INC(red.units[defIdx].meleeWins)
    ELSE INC(blue.units[defIdx].meleeWins) END
  END;

  (* Flank attack: morale check for defender *)
  IF (att.col # def.col) & (att.row # def.row) THEN
    IF ~CheckMorale(defSide, defIdx, -10, "flank") THEN END
  END;

  (* Cavalry charge forces morale check on foot defenders *)
  IF att.charged & unitIsCav[att.utype] & ~unitIsCav[def.utype] THEN
    IF ~CheckMorale(defSide, defIdx, -20, "cav!") THEN END
  END
END ResolveMelee;

PROCEDURE ResolveMeleeAll;
VAR i, j: INTEGER; msg: ARRAY 72 OF CHAR;
BEGIN
  FOR i := 0 TO red.count - 1 DO
    IF red.units[i].alive THEN
      FOR j := 0 TO blue.count - 1 DO
        IF blue.units[j].alive &
           (CDist(red.units[i].col, red.units[i].row,
                  blue.units[j].col, blue.units[j].row) = 1) THEN
          ResolveMelee(RED, i, BLUE, j, msg);
          AppendLog(msg)
        END
      END
    END
  END
END ResolveMeleeAll;

(* ════════════════════════════════════════════════════════════════════════ *)
(*  Elimination, Victory, Bookkeeping                                      *)
(* ════════════════════════════════════════════════════════════════════════ *)

PROCEDURE CheckArmyMorale(side, modifier: INTEGER; reason: ARRAY OF CHAR);
VAR i: INTEGER; a: Army;
BEGIN
  a := ArmyOf(side);
  FOR i := 0 TO a.count - 1 DO
    IF a.units[i].alive THEN
      IF ~CheckMorale(side, i, modifier, reason) THEN END
    END
  END
END CheckArmyMorale;

PROCEDURE CheckElimination;
VAR i: INTEGER; msg: ARRAY 48 OF CHAR;
BEGIN
  FOR i := 0 TO red.count - 1 DO
    IF red.units[i].alive & (red.units[i].figures <= 0) THEN
      red.units[i].alive := FALSE;
      COPY("R.", msg); AppendStr(msg, unitName[red.units[i].utype]);
      AppendStr(msg, " eliminated!"); AppendLog(msg)
    END
  END;
  FOR i := 0 TO blue.count - 1 DO
    IF blue.units[i].alive & (blue.units[i].figures <= 0) THEN
      blue.units[i].alive := FALSE;
      COPY("B.", msg); AppendStr(msg, unitName[blue.units[i].utype]);
      AppendStr(msg, " eliminated!"); AppendLog(msg)
    END
  END;
  (* Routed units that reach their own back edge flee the field *)
  FOR i := 0 TO red.count - 1 DO
    IF red.units[i].alive & (red.units[i].morale >= ML_ROUTED) & (red.units[i].row = 0) THEN
      red.units[i].alive := FALSE; AppendLog("R.unit flees the field!")
    END
  END;
  FOR i := 0 TO blue.count - 1 DO
    IF blue.units[i].alive & (blue.units[i].morale >= ML_ROUTED) &
       (blue.units[i].row = GRID_H - 1) THEN
      blue.units[i].alive := FALSE; AppendLog("B.unit flees the field!")
    END
  END;
  (* Commander captured if enemy occupies their cell *)
  IF red.cmdAlive & OccupiedBy(red.cmdCol, red.cmdRow, BLUE) THEN
    red.cmdAlive := FALSE; AppendLog("Red COMMANDER captured!");
    CheckArmyMorale(RED, -40, "cmd!")
  END;
  IF blue.cmdAlive & OccupiedBy(blue.cmdCol, blue.cmdRow, RED) THEN
    blue.cmdAlive := FALSE; AppendLog("Blue COMMANDER captured!");
    CheckArmyMorale(BLUE, -40, "cmd!")
  END
END CheckElimination;

PROCEDURE AliveCount(side: INTEGER): INTEGER;
VAR a: Army; i, n: INTEGER;
BEGIN
  a := ArmyOf(side); n := 0;
  FOR i := 0 TO a.count - 1 DO IF a.units[i].alive THEN INC(n) END END;
  RETURN n
END AliveCount;

PROCEDURE CheckVictory;
VAR rA, bA: INTEGER;
BEGIN
  rA := AliveCount(RED); bA := AliveCount(BLUE);
  IF rA = 0 THEN AppendLog("BLUE WINS — Red army destroyed!"); gameOver := TRUE
  ELSIF bA = 0 THEN AppendLog("RED WINS — Blue army destroyed!"); gameOver := TRUE
  ELSIF turn > TURNS THEN
    IF rA > bA THEN AppendLog("RED WINS — more units survived!")
    ELSIF bA > rA THEN AppendLog("BLUE WINS — more units survived!")
    ELSE AppendLog("DRAW — equal survivors")
    END;
    gameOver := TRUE
  END
END CheckVictory;

PROCEDURE ClearTurnFlags(side: INTEGER);
VAR a: Army; i: INTEGER;
BEGIN
  a := ArmyOf(side);
  FOR i := 0 TO a.count - 1 DO
    a.units[i].moved   := FALSE;
    a.units[i].charged := FALSE;
    a.units[i].inMelee := FALSE;
    a.units[i].shotsLeft := 0
  END;
  a.cmdMoved := FALSE;
  SetArmy(side, a)
END ClearTurnFlags;

PROCEDURE SetShotsForTurn(side: INTEGER);
VAR a: Army; i: INTEGER;
BEGIN
  a := ArmyOf(side);
  FOR i := 0 TO a.count - 1 DO
    IF a.units[i].alive & unitHasBow[a.units[i].utype] THEN
      a.units[i].shotsLeft := unitShotsPerTurn[a.units[i].utype]
    ELSE
      a.units[i].shotsLeft := 0
    END
  END;
  SetArmy(side, a)
END SetShotsForTurn;

PROCEDURE CheckRally(side: INTEGER);
VAR a: Army; i: INTEGER; msg: ARRAY 48 OF CHAR;
BEGIN
  a := ArmyOf(side);
  FOR i := 0 TO a.count - 1 DO
    IF a.units[i].alive & (a.units[i].morale > ML_REGULAR) &
       ~a.units[i].inMelee THEN
      IF CheckMorale(side, i, 10, "rally") THEN
        IF side = RED THEN
          IF red.units[i].morale > ML_REGULAR THEN DEC(red.units[i].morale) END
        ELSE
          IF blue.units[i].morale > ML_REGULAR THEN DEC(blue.units[i].morale) END
        END;
        IF side = RED THEN COPY("R.", msg) ELSE COPY("B.", msg) END;
        AppendStr(msg, unitName[a.units[i].utype]); AppendStr(msg, " rallies.");
        AppendLog(msg)
      END
    END
  END
END CheckRally;

(* ════════════════════════════════════════════════════════════════════════ *)
(*  AI (Blue)                                                              *)
(* ════════════════════════════════════════════════════════════════════════ *)

PROCEDURE AIFindClosestEnemy(bIdx: INTEGER; VAR tCol, tRow: INTEGER);
VAR i, dist, best: INTEGER;
BEGIN
  best := 9999; tCol := -1; tRow := -1;
  FOR i := 0 TO red.count - 1 DO
    IF red.units[i].alive THEN
      dist := CDist(blue.units[bIdx].col, blue.units[bIdx].row,
                    red.units[i].col, red.units[i].row);
      IF dist < best THEN best := dist; tCol := red.units[i].col; tRow := red.units[i].row END
    END
  END
END AIFindClosestEnemy;

PROCEDURE AIMoveUnit(bIdx: INTEGER);
VAR tCol, tRow, bestCol, bestRow, bestDist, nc, nr, newDist, mv, dc, dr: INTEGER;
    msg: ARRAY 48 OF CHAR;
BEGIN
  IF blue.units[bIdx].morale >= ML_DISORDER THEN RETURN END;
  mv := unitMove[blue.units[bIdx].utype];
  IF blue.units[bIdx].morale = ML_SHAKEN THEN mv := mv DIV 2; IF mv < 1 THEN mv := 1 END END;

  (* Self-preservation: retreat when down to 2 or fewer figures *)
  IF blue.units[bIdx].figures <= 2 THEN
    bestCol := blue.units[bIdx].col; bestRow := blue.units[bIdx].row;
    FOR dc := -mv TO mv DO
      FOR dr := -mv TO mv DO
        nc := blue.units[bIdx].col + dc;
        nr := blue.units[bIdx].row + dr;
        IF ValidMoveTarget(BLUE, bIdx, nc, nr) & (nr > bestRow) THEN
          bestRow := nr; bestCol := nc
        END
      END
    END;
    IF (bestCol # blue.units[bIdx].col) OR (bestRow # blue.units[bIdx].row) THEN
      blue.units[bIdx].col := bestCol; blue.units[bIdx].row := bestRow;
      blue.units[bIdx].moved := TRUE
    END;
    RETURN
  END;

  AIFindClosestEnemy(bIdx, tCol, tRow);
  IF tCol < 0 THEN RETURN END;
  bestCol := blue.units[bIdx].col; bestRow := blue.units[bIdx].row;
  bestDist := CDist(bestCol, bestRow, tCol, tRow);
  FOR dc := -mv TO mv DO
    FOR dr := -mv TO mv DO
      nc := blue.units[bIdx].col + dc;
      nr := blue.units[bIdx].row + dr;
      IF ValidMoveTarget(BLUE, bIdx, nc, nr) THEN
        newDist := CDist(nc, nr, tCol, tRow);
        IF newDist < bestDist THEN bestDist := newDist; bestCol := nc; bestRow := nr END
      END
    END
  END;
  IF (bestCol # blue.units[bIdx].col) OR (bestRow # blue.units[bIdx].row) THEN
    blue.units[bIdx].col := bestCol; blue.units[bIdx].row := bestRow;
    blue.units[bIdx].moved := TRUE;
    IF unitIsCav[blue.units[bIdx].utype] THEN blue.units[bIdx].charged := TRUE END
  END
END AIMoveUnit;

PROCEDURE AIShootUnit(bIdx: INTEGER);
VAR i, bestIdx, bestFigs: INTEGER; msg: ARRAY 64 OF CHAR;
BEGIN
  IF ~unitHasBow[blue.units[bIdx].utype] THEN RETURN END;
  WHILE blue.units[bIdx].shotsLeft > 0 DO
    bestIdx := -1; bestFigs := 9999;
    FOR i := 0 TO red.count - 1 DO
      IF red.units[i].alive &
         CanShootTarget(BLUE, bIdx, red.units[i].col, red.units[i].row) THEN
        IF red.units[i].figures < bestFigs THEN
          bestFigs := red.units[i].figures; bestIdx := i
        END
      END
    END;
    IF bestIdx >= 0 THEN
      ResolveShot(BLUE, bIdx, RED, bestIdx, msg);
      AppendLog(msg)
    ELSE
      blue.units[bIdx].shotsLeft := 0
    END
  END
END AIShootUnit;

PROCEDURE AIMoveCmd;
VAR i, tCol, tRow, weakFigs, bestCol, bestRow, bestDist, newDist, dc, dr: INTEGER;
    nc, nr: INTEGER;
BEGIN
  IF ~blue.cmdAlive OR blue.cmdMoved THEN RETURN END;
  weakFigs := 9999; tCol := -1; tRow := -1;
  FOR i := 0 TO blue.count - 1 DO
    IF blue.units[i].alive & (blue.units[i].figures < weakFigs) THEN
      weakFigs := blue.units[i].figures;
      tCol := blue.units[i].col; tRow := blue.units[i].row
    END
  END;
  IF tCol < 0 THEN RETURN END;
  bestCol := blue.cmdCol; bestRow := blue.cmdRow;
  bestDist := CDist(bestCol, bestRow, tCol, tRow);
  FOR dc := -CMD_MOVE TO CMD_MOVE DO
    FOR dr := -CMD_MOVE TO CMD_MOVE DO
      nc := blue.cmdCol + dc; nr := blue.cmdRow + dr;
      IF ValidCmdMove(BLUE, nc, nr) THEN
        newDist := CDist(nc, nr, tCol, tRow);
        IF newDist < bestDist THEN bestDist := newDist; bestCol := nc; bestRow := nr END
      END
    END
  END;
  IF (bestCol # blue.cmdCol) OR (bestRow # blue.cmdRow) THEN
    blue.cmdCol := bestCol; blue.cmdRow := bestRow; blue.cmdMoved := TRUE
  END
END AIMoveCmd;

PROCEDURE DoAITurn;
VAR i: INTEGER;
BEGIN
  AIMoveCmd;
  FOR i := 0 TO blue.count - 1 DO
    IF blue.units[i].alive THEN AIShootUnit(i) END
  END;
  FOR i := 0 TO blue.count - 1 DO
    IF blue.units[i].alive THEN AIMoveUnit(i) END
  END;
  IF verboseAI THEN END
END DoAITurn;

(* ════════════════════════════════════════════════════════════════════════ *)
(*  Display                                                                 *)
(* ════════════════════════════════════════════════════════════════════════ *)

PROCEDURE DrawCell(col, row: INTEGER);
VAR sx, sy, uSide, uIdx: INTEGER;
    u: Unit; a: Army;
    fg, bg: INTEGER;
    c0, c1: CHAR;
    isCursor, isSelected, isValidMove, isShootable, isTargetable: BOOLEAN;
    isValidCmdMove, isCmdCell: BOOLEAN;
BEGIN
  sx := MAPX + col * 2; sy := MAPY + row;
  UnitAt(col, row, uSide, uIdx);
  isCursor   := (col = curCol) & (row = curRow);
  isSelected := (selUnit >= 0) & (uSide = RED) & (uIdx = selUnit);
  isValidMove := FALSE;
  IF (selUnit >= 0) & (phase = PH_MOVE) & (uSide < 0) THEN
    isValidMove := ValidMoveTarget(RED, selUnit, col, row)
  END;
  isShootable := FALSE;
  IF (selUnit < 0) & (phase = PH_SHOOT) & (uSide = RED) & (uIdx >= 0) THEN
    isShootable := unitHasBow[red.units[uIdx].utype] & (red.units[uIdx].shotsLeft > 0)
  END;
  isTargetable := FALSE;
  IF (selUnit >= 0) & (phase = PH_SHOOT) & (uSide = BLUE) THEN
    isTargetable := CanShootTarget(RED, selUnit, col, row)
  END;
  isCmdCell := red.cmdAlive & (red.cmdCol = col) & (red.cmdRow = row);
  isValidCmdMove := FALSE;
  IF cmdSelected & (phase = PH_MOVE) & ~isCmdCell THEN
    isValidCmdMove := ValidCmdMove(RED, col, row)
  END;

  IF isCursor THEN             bg := TUI.Cyan;    fg := TUI.Black
  ELSIF isSelected OR (cmdSelected & isCmdCell) THEN bg := TUI.Yellow; fg := TUI.Black
  ELSIF isValidMove OR isTargetable OR isValidCmdMove THEN bg := TUI.Green; fg := TUI.Black
  ELSIF isShootable THEN       bg := TUI.Magenta; fg := TUI.White
  ELSIF terrain[row][col] = TERR_HILL  THEN bg := TUI.Yellow;  fg := TUI.Black
  ELSIF terrain[row][col] = TERR_WOOD  THEN bg := TUI.Green;   fg := TUI.Black
  ELSIF terrain[row][col] = TERR_MARSH THEN bg := TUI.Blue;    fg := TUI.White
  ELSE bg := TUI.Black; fg := TUI.White
  END;

  IF uSide >= 0 THEN
    a := ArmyOf(uSide); u := a.units[uIdx];
    IF uSide = RED THEN
      IF ~isCursor & ~isSelected THEN fg := TUI.Red ELSE fg := TUI.Black END;
      IF red.cmdAlive & (red.cmdCol = col) & (red.cmdRow = row) THEN c0 := '*'
      ELSE c0 := 'R' END
    ELSE
      IF ~isCursor & ~isTargetable THEN fg := TUI.Cyan ELSE fg := TUI.Black END;
      IF blue.cmdAlive & (blue.cmdCol = col) & (blue.cmdRow = row) THEN c0 := '*'
      ELSE c0 := 'B' END
    END;
    c1 := unitGlyph[u.utype]
  ELSIF red.cmdAlive & (red.cmdCol = col) & (red.cmdRow = row) THEN
    IF ~isCursor & ~(cmdSelected & isCmdCell) THEN fg := TUI.Red ELSE fg := TUI.Black END;
    c0 := 'R'; c1 := 'C'
  ELSIF blue.cmdAlive & (blue.cmdCol = col) & (blue.cmdRow = row) THEN
    IF ~isCursor THEN fg := TUI.Cyan ELSE fg := TUI.Black END;
    c0 := 'B'; c1 := 'C'
  ELSE
    IF isCursor OR isValidMove OR isValidCmdMove THEN fg := TUI.Black END;
    IF    terrain[row][col] = TERR_HILL  THEN c0 := '^'
    ELSIF terrain[row][col] = TERR_WOOD  THEN c0 := 'T'
    ELSIF terrain[row][col] = TERR_MARSH THEN c0 := '~'
    ELSE c0 := '.'
    END;
    c1 := ' '
  END;
  TUI.PutCell(sx,     sy, c0, fg, bg);
  TUI.PutCell(sx + 1, sy, c1, fg, bg)
END DrawCell;

PROCEDURE DrawMap;
VAR c, r: INTEGER; lbl: CHAR;
BEGIN
  FOR c := 0 TO GRID_W - 1 DO
    IF c < 10 THEN lbl := CHR(ORD('0') + c) ELSE lbl := CHR(ORD('A') + c - 10) END;
    TUI.PutCell(MAPX + c*2,     MAPY - 1, lbl, TUI.Yellow, TUI.Black);
    TUI.PutCell(MAPX + c*2 + 1, MAPY - 1, ' ', TUI.Yellow, TUI.Black)
  END;
  FOR r := 0 TO GRID_H - 1 DO
    IF r < 10 THEN lbl := CHR(ORD('0') + r) ELSE lbl := CHR(ORD('A') + r - 10) END;
    TUI.PutCell(MAPX - 2, MAPY + r, lbl, TUI.Yellow, TUI.Black);
    TUI.PutCell(MAPX - 1, MAPY + r, ' ', TUI.Black,  TUI.Black);
    FOR c := 0 TO GRID_W - 1 DO DrawCell(c, r) END
  END
END DrawMap;

PROCEDURE DrawUnitList;
VAR i, sy: INTEGER; u: Unit; fg: INTEGER;
    num: ARRAY 6 OF CHAR; mlStr: ARRAY 10 OF CHAR;
BEGIN
  TUI.PutStr(SIDEX, 1, "Unit      Figs  ML", TUI.Yellow, TUI.Black);
  sy := 2;
  TUI.PutStr(SIDEX, sy, "[Red]", TUI.Red, TUI.Black); INC(sy);
  IF red.cmdAlive THEN TUI.PutStr(SIDEX, sy, "Cmdr:alive ", TUI.Red, TUI.Black)
  ELSE TUI.PutStr(SIDEX, sy, "Cmdr:gone  ", TUI.White, TUI.Black)
  END; INC(sy);
  FOR i := 0 TO red.count - 1 DO
    u := red.units[i];
    IF u.alive THEN fg := TUI.White ELSE fg := TUI.Red END;
    TUI.PutStr(SIDEX, sy, unitName[u.utype], fg, TUI.Black);
    IntStr(u.figures, num); TUI.PutStr(SIDEX + 10, sy, num, fg, TUI.Black);
    (* morale indicator *)
    IF    u.morale = ML_ELITE    THEN COPY("Elt", mlStr)
    ELSIF u.morale = ML_REGULAR  THEN COPY("Reg", mlStr)
    ELSIF u.morale = ML_SHAKEN   THEN COPY("Shk", mlStr)
    ELSIF u.morale = ML_DISORDER THEN COPY("Dis", mlStr)
    ELSE                              COPY("Rut", mlStr)
    END;
    TUI.PutStr(SIDEX + 14, sy, mlStr, fg, TUI.Black);
    IF ~u.alive THEN TUI.PutStr(SIDEX + 17, sy, "X", TUI.Red, TUI.Black) END;
    INC(sy)
  END;
  INC(sy);
  TUI.PutStr(SIDEX, sy, "[Blue]", TUI.Cyan, TUI.Black); INC(sy);
  IF blue.cmdAlive THEN TUI.PutStr(SIDEX, sy, "Cmdr:alive ", TUI.Cyan, TUI.Black)
  ELSE TUI.PutStr(SIDEX, sy, "Cmdr:gone  ", TUI.White, TUI.Black)
  END; INC(sy);
  FOR i := 0 TO blue.count - 1 DO
    u := blue.units[i];
    IF u.alive THEN fg := TUI.White ELSE fg := TUI.Cyan END;
    TUI.PutStr(SIDEX, sy, unitName[u.utype], fg, TUI.Black);
    IntStr(u.figures, num); TUI.PutStr(SIDEX + 10, sy, num, fg, TUI.Black);
    IF    u.morale = ML_ELITE    THEN COPY("Elt", mlStr)
    ELSIF u.morale = ML_REGULAR  THEN COPY("Reg", mlStr)
    ELSIF u.morale = ML_SHAKEN   THEN COPY("Shk", mlStr)
    ELSIF u.morale = ML_DISORDER THEN COPY("Dis", mlStr)
    ELSE                              COPY("Rut", mlStr)
    END;
    TUI.PutStr(SIDEX + 14, sy, mlStr, fg, TUI.Black);
    IF ~u.alive THEN TUI.PutStr(SIDEX + 17, sy, "X", TUI.Cyan, TUI.Black) END;
    INC(sy)
  END
END DrawUnitList;

PROCEDURE DrawLog;
VAR i, sy, nShow, base, avail: INTEGER;
BEGIN
  sy := MAPY + GRID_H + 2;
  nShow := TUI.Rows - sy - 1;
  IF nShow > 8 THEN nShow := 8 END;
  IF nShow < 1 THEN RETURN END;
  avail := logHead - nShow;
  IF avail < 0 THEN avail := 0 END;
  IF logScroll > avail THEN logScroll := avail END;
  base := logHead - nShow - logScroll;
  IF base < 0 THEN base := 0 END;
  FOR i := 0 TO nShow - 1 DO
    IF base + i < logHead THEN
      TUI.PutStr(2, sy + i, msgLog[(base + i) MOD 64], TUI.White, TUI.Black)
    ELSE
      TUI.PutStr(2, sy + i, "                                                 ",
                 TUI.Black, TUI.Black)
    END
  END
END DrawLog;

PROCEDURE DrawHeader;
VAR hdr: ARRAY 64 OF CHAR; numStr: ARRAY 8 OF CHAR;
BEGIN
  COPY("SWORDS & SPELLS  Turn ", hdr); IntStr(turn, numStr); AppendStr(hdr, numStr);
  AppendStr(hdr, "/"); IntStr(TURNS, numStr); AppendStr(hdr, numStr);
  AppendStr(hdr, "  Phase:");
  CASE phase OF
    PH_SHOOT:  AppendStr(hdr, "SHOOT")
  | PH_MOVE:   AppendStr(hdr, "MOVE ")
  | PH_COMBAT: AppendStr(hdr, "MELEE")
  | PH_ELIM:   AppendStr(hdr, "END  ")
  ELSE         AppendStr(hdr, "?    ")
  END;
  TUI.PutStr(0, 0, hdr, TUI.Yellow, TUI.Black)
END DrawHeader;

PROCEDURE DrawPrompt;
VAR prompt: ARRAY 72 OF CHAR;
BEGIN
  CASE phase OF
    PH_SHOOT:
      IF selUnit >= 0 THEN COPY("Select target (Enter=fire, Esc=cancel)", prompt)
      ELSE COPY("SHOOT: Select archer/elf to fire  N=done", prompt)
      END
  | PH_MOVE:
      IF selUnit >= 0 THEN COPY("Select destination (Enter=move, Esc=cancel)", prompt)
      ELSIF cmdSelected THEN COPY("Select commander destination (Esc=cancel)", prompt)
      ELSE COPY("MOVE: Select unit or commander (C)  N=done", prompt)
      END
  | PH_COMBAT: COPY("MELEE: Press N to resolve combat", prompt)
  | PH_ELIM:   COPY("END: Press N for next turn", prompt)
  ELSE COPY("", prompt)
  END;
  TUI.PutStr(0, 1, prompt, TUI.White, TUI.Black)
END DrawPrompt;

PROCEDURE DrawHpBar(col, row: INTEGER; unit: Unit);
VAR sx, sy, full, cur, i: INTEGER; c: CHAR;
BEGIN
  (* Tiny HP bar below the map area, for selected unit *)
  sx := MAPX; sy := MAPY + GRID_H + 1;
  IF (selUnit < 0) & ~cmdSelected THEN RETURN END;
  IF ~unit.alive THEN RETURN END;
  TUI.PutStr(sx, sy, unitName[unit.utype], TUI.Yellow, TUI.Black);
  TUI.PutStr(sx + 9, sy, " figs:", TUI.White, TUI.Black);
  full := FIGS_START; cur := unit.figures;
  FOR i := 0 TO full - 1 DO
    IF i < cur THEN c := '#' ELSE c := '-' END;
    TUI.PutCell(sx + 15 + i, sy, c, TUI.Green, TUI.Black)
  END
END DrawHpBar;

PROCEDURE DrawScreen;
VAR selU: Unit;
BEGIN
  TUI.ClearBack(TUI.White, TUI.Black);
  DrawHeader;
  DrawPrompt;
  DrawMap;
  DrawUnitList;
  DrawLog;
  IF selUnit >= 0 THEN
    selU := red.units[selUnit];
    DrawHpBar(selU.col, selU.row, selU)
  END;
  TUI.Flush
END DrawScreen;

(* ════════════════════════════════════════════════════════════════════════ *)
(*  Input Handlers                                                          *)
(* ════════════════════════════════════════════════════════════════════════ *)

PROCEDURE MoveCursor(key: INTEGER);
BEGIN
  CASE key OF
    TUI.KUp:    IF curRow > 0 THEN DEC(curRow) END
  | TUI.KDown:  IF curRow < GRID_H - 1 THEN INC(curRow) END
  | TUI.KLeft:  IF curCol > 0 THEN DEC(curCol) END
  | TUI.KRight: IF curCol < GRID_W - 1 THEN INC(curCol) END
  ELSE
  END
END MoveCursor;

PROCEDURE HandleShootPhase(key: INTEGER);
VAR uSide, uIdx: INTEGER; msg: ARRAY 72 OF CHAR;
BEGIN
  IF key = TUI.KEsc THEN selUnit := -1; RETURN END;
  MoveCursor(key);
  IF key = TUI.KEnter THEN
    UnitAt(curCol, curRow, uSide, uIdx);
    IF selUnit < 0 THEN
      IF (uSide = RED) & unitHasBow[red.units[uIdx].utype] &
         (red.units[uIdx].shotsLeft > 0) THEN
        selUnit := uIdx
      END
    ELSE
      IF uSide = BLUE THEN
        IF CanShootTarget(RED, selUnit, curCol, curRow) THEN
          ResolveShot(RED, selUnit, BLUE, uIdx, msg);
          AppendLog(msg);
          selUnit := -1
        END
      ELSIF uSide < 0 THEN selUnit := -1
      END
    END
  END
END HandleShootPhase;

PROCEDURE HandleMovePhase(key: INTEGER);
VAR uSide, uIdx: INTEGER;
BEGIN
  IF key = TUI.KEsc THEN
    selUnit := -1; cmdSelected := FALSE; RETURN
  END;
  MoveCursor(key);
  IF key = TUI.KEnter THEN
    UnitAt(curCol, curRow, uSide, uIdx);
    IF cmdSelected THEN
      IF ValidCmdMove(RED, curCol, curRow) THEN
        red.cmdCol := curCol; red.cmdRow := curRow;
        red.cmdMoved := TRUE; cmdSelected := FALSE
      ELSE cmdSelected := FALSE
      END
    ELSIF selUnit < 0 THEN
      IF (uSide = RED) & ~red.units[uIdx].moved THEN
        selUnit := uIdx
      ELSIF (uSide < 0) & red.cmdAlive &
            (red.cmdCol = curCol) & (red.cmdRow = curRow) &
            ~red.cmdMoved THEN
        cmdSelected := TRUE
      END
    ELSE
      IF uSide < 0 THEN
        IF ValidMoveTarget(RED, selUnit, curCol, curRow) THEN
          red.units[selUnit].col  := curCol;
          red.units[selUnit].row  := curRow;
          red.units[selUnit].moved := TRUE;
          IF unitIsCav[red.units[selUnit].utype] THEN
            red.units[selUnit].charged := TRUE
          END;
          selUnit := -1
        END
      ELSE selUnit := -1
      END
    END
  END
END HandleMovePhase;

(* ════════════════════════════════════════════════════════════════════════ *)
(*  Phase Management                                                        *)
(* ════════════════════════════════════════════════════════════════════════ *)

PROCEDURE AdvancePhase;
BEGIN
  selUnit := -1; cmdSelected := FALSE;
  CASE phase OF
    PH_SHOOT:
      phase := PH_MOVE
  | PH_MOVE:
      (* Run Blue AI, then go to melee *)
      DoAITurn;
      phase := PH_COMBAT
  | PH_COMBAT:
      ResolveMeleeAll;
      CheckElimination;
      CheckVictory;
      phase := PH_ELIM
  | PH_ELIM:
      IF ~gameOver THEN
        INC(turn);
        ClearTurnFlags(RED);
        ClearTurnFlags(BLUE);
        CheckRally(RED);
        CheckRally(BLUE);
        SetShotsForTurn(RED);
        SetShotsForTurn(BLUE);
        phase := PH_SHOOT
      END
  END
END AdvancePhase;

(* ════════════════════════════════════════════════════════════════════════ *)
(*  Terrain Setup                                                           *)
(* ════════════════════════════════════════════════════════════════════════ *)

PROCEDURE InitTerrain;
VAR r, c: INTEGER;
BEGIN
  FOR r := 0 TO GRID_H - 1 DO
    FOR c := 0 TO GRID_W - 1 DO terrain[r][c] := TERR_OPEN END
  END
END InitTerrain;

PROCEDURE GenTerrain;
VAR r, c, i, n, cr, cc, sz, d: INTEGER;
BEGIN
  InitTerrain;
  n := 1 + Random.Int(3);
  FOR i := 0 TO n - 1 DO
    cr := 2 + Random.Int(GRID_H - 4); cc := Random.Int(GRID_W); sz := 1 + Random.Int(2);
    FOR r := cr - sz TO cr + sz DO
      FOR c := cc - sz TO cc + sz DO
        d := Abs(r - cr) + Abs(c - cc);
        IF (r >= 1) & (r <= GRID_H - 2) & (c >= 0) & (c < GRID_W) &
           (d <= sz) & (Random.Int(3) # 0) THEN
          terrain[r][c] := TERR_HILL
        END
      END
    END
  END;
  n := Random.Int(2);
  FOR i := 0 TO n - 1 DO
    cr := 2 + Random.Int(GRID_H - 4); cc := Random.Int(GRID_W); sz := 1 + Random.Int(2);
    FOR r := cr - sz TO cr + sz DO
      FOR c := cc - sz TO cc + sz DO
        d := Abs(r - cr) + Abs(c - cc);
        IF (r >= 1) & (r <= GRID_H - 2) & (c >= 0) & (c < GRID_W) &
           (d <= sz) & (terrain[r][c] = TERR_OPEN) & (Random.Int(2) = 0) THEN
          terrain[r][c] := TERR_WOOD
        END
      END
    END
  END;
  IF Random.Int(4) = 0 THEN
    r := 2 + Random.Int(GRID_H - 4);
    FOR c := 2 TO 5 DO terrain[r][c] := TERR_MARSH END
  END
END GenTerrain;

(* ════════════════════════════════════════════════════════════════════════ *)
(*  Army Deployment                                                         *)
(* ════════════════════════════════════════════════════════════════════════ *)

PROCEDURE DeployUnit(VAR a: Army; i, utype, col, row: INTEGER);
BEGIN
  a.units[i].utype     := utype;
  a.units[i].figures   := FIGS_START;
  a.units[i].hpPerFig  := unitHpFig[utype];
  a.units[i].totalHp   := FIGS_START * unitHpFig[utype];
  a.units[i].col       := col;
  a.units[i].row       := row;
  a.units[i].alive     := TRUE;
  a.units[i].moved     := FALSE;
  a.units[i].morale    := ML_REGULAR;
  IF unitIsElite[utype] THEN a.units[i].morale := ML_ELITE END;
  a.units[i].baseScore := unitBaseML[utype];
  a.units[i].meleeWins := 0;
  a.units[i].shotsLeft := 0;
  a.units[i].charged   := FALSE;
  a.units[i].inMelee   := FALSE
END DeployUnit;

PROCEDURE DeployArmy(VAR a: Army; side, count: INTEGER;
                     comp: ARRAY OF INTEGER);
VAR i, col, row, startRow: INTEGER;
BEGIN
  a.side  := side;
  a.count := count;
  IF side = RED THEN startRow := GRID_H - 2 ELSE startRow := 1 END;
  FOR i := 0 TO count - 1 DO
    col := 1 + i * 2;
    IF col >= GRID_W - 1 THEN col := GRID_W - 2 END;
    row := startRow;
    WHILE (terrain[row][col] = TERR_MARSH) & (row >= 1) & (row <= GRID_H - 2) DO
      IF side = RED THEN DEC(row) ELSE INC(row) END
    END;
    DeployUnit(a, i, comp[i], col, row)
  END;
  IF side = RED THEN
    a.cmdRow := GRID_H - 1; a.cmdCol := GRID_W DIV 2
  ELSE
    a.cmdRow := 0; a.cmdCol := GRID_W DIV 2
  END;
  a.cmdAlive := TRUE; a.cmdMoved := FALSE
END DeployArmy;

(* ════════════════════════════════════════════════════════════════════════ *)
(*  Army Selection                                                          *)
(* ════════════════════════════════════════════════════════════════════════ *)

PROCEDURE AISelectArmy(VAR comp: ARRAY OF INTEGER; VAR count: INTEGER);
(*
 * Blue prefers cheap numbers (ORC, LEVY) plus a melee threat (HCAV or PIKE).
 * Randomly vary each game.
 *)
VAR budget, spent, t, tries: INTEGER;
BEGIN
  budget := 12; count := 0; spent := 0;
  WHILE (count < MAX_UNITS) & (spent < budget) DO
    tries := 0;
    REPEAT
      t := Random.Int(NTYPES); INC(tries)
    UNTIL (unitCost[t] <= budget - spent) OR (tries > 40);
    IF unitCost[t] <= budget - spent THEN
      comp[count] := t; INC(spent, unitCost[t]); INC(count)
    ELSE spent := budget
    END
  END
END AISelectArmy;

PROCEDURE SelectArmy(side: INTEGER; VAR comp: ARRAY OF INTEGER; VAR count: INTEGER);
VAR ev2: TUI.Event; t, budget, spent: INTEGER;
    cStr, hdr: ARRAY 48 OF CHAR; cNum: ARRAY 4 OF CHAR;
    fg: INTEGER;
BEGIN
  budget := 12; count := 0; spent := 0;
  LOOP
    TUI.ClearBack(TUI.White, TUI.Black);
    IF side = RED THEN
      TUI.PutStr(2, 0, "SWORDS & SPELLS — Red Army Selection", TUI.Red, TUI.Black)
    ELSE
      TUI.PutStr(2, 0, "SWORDS & SPELLS — Blue Army Selection", TUI.Cyan, TUI.Black)
    END;
    COPY("Budget: 12 pts   Used: ", hdr);
    IntStr(spent, cNum); AppendStr(hdr, cNum);
    AppendStr(hdr, "   Slots: "); IntStr(count, cNum); AppendStr(hdr, cNum);
    AppendStr(hdr, "/"); IntStr(MAX_UNITS, cNum); AppendStr(hdr, cNum);
    TUI.PutStr(2, 1, hdr, TUI.Yellow, TUI.Black);
    TUI.PutStr(2, 3, "Your army:", TUI.White, TUI.Black);
    IF count = 0 THEN TUI.PutStr(4, 4, "(empty)", TUI.White, TUI.Black)
    ELSE
      FOR t := 0 TO count - 1 DO
        TUI.PutStr(4, 4 + t, unitName[comp[t]], TUI.White, TUI.Black)
      END
    END;
    TUI.PutStr(2, 13, "Add unit (1-0=types), D=remove last, N=done:", TUI.White, TUI.Black);
    FOR t := 0 TO NTYPES - 1 DO
      IF (unitCost[t] <= budget - spent) & (count < MAX_UNITS) THEN fg := TUI.Cyan
      ELSE fg := TUI.White
      END;
      IF t < 9 THEN cStr[0] := CHR(ORD('1') + t)
      ELSE cStr[0] := '0'
      END;
      cStr[1] := 0X;
      hdr[0] := '['; hdr[1] := 0X;
      AppendStr(hdr, cStr); AppendStr(hdr, "] ");
      AppendStr(hdr, unitName[t]); AppendStr(hdr, "  ");
      IntStr(unitCost[t], cNum); AppendStr(hdr, cNum); AppendStr(hdr, "pt  ");
      AppendStr(hdr, unitDesc[t]);
      TUI.PutStr(4, 14 + t, hdr, fg, TUI.Black)
    END;
    TUI.Flush;
    TUI.WaitEvent(ev2);
    IF ev2.kind = TUI.EvKey THEN
      IF ev2.key = 17 THEN TUI.Done; HALT(0)
      ELSIF (ev2.key = ORD('n')) OR (ev2.key = ORD('N')) THEN
        IF count > 0 THEN EXIT END
      ELSIF (ev2.key = ORD('d')) OR (ev2.key = ORD('D')) THEN
        IF count > 0 THEN DEC(count); DEC(spent, unitCost[comp[count]]) END
      ELSIF (ev2.key >= ORD('1')) & (ev2.key <= ORD('9')) THEN
        t := ev2.key - ORD('1');
        IF (t < NTYPES) & (unitCost[t] <= budget - spent) & (count < MAX_UNITS) THEN
          comp[count] := t; INC(spent, unitCost[t]); INC(count)
        END
      ELSIF ev2.key = ORD('0') THEN
        t := 9;  (* ORC *)
        IF (unitCost[t] <= budget - spent) & (count < MAX_UNITS) THEN
          comp[count] := t; INC(spent, unitCost[t]); INC(count)
        END
      END
    END
  END
END SelectArmy;

(* ════════════════════════════════════════════════════════════════════════ *)
(*  Setup                                                                   *)
(* ════════════════════════════════════════════════════════════════════════ *)

PROCEDURE ShowArmyPreview(side: INTEGER; comp: ARRAY OF INTEGER; count: INTEGER);
VAR i, sx, sy, fg: INTEGER;
BEGIN
  sx := 2; sy := 0;
  IF side = BLUE THEN sy := 11 END;
  fg := TUI.Red; IF side = BLUE THEN fg := TUI.Cyan END;
  IF side = RED THEN TUI.PutStr(sx, sy, "Red army:", fg, TUI.Black)
  ELSE TUI.PutStr(sx, sy, "Blue army:", fg, TUI.Black)
  END;
  FOR i := 0 TO count - 1 DO
    TUI.PutStr(sx + 2, sy + 1 + i, unitName[comp[i]], TUI.White, TUI.Black)
  END
END ShowArmyPreview;

PROCEDURE SetupGame;
VAR ev2: TUI.Event;
    redComp, blueComp: ARRAY MAX_UNITS OF INTEGER;
    redCount, blueCount: INTEGER;
BEGIN
  GenTerrain;
  SelectArmy(RED, redComp, redCount);
  AISelectArmy(blueComp, blueCount);
  DeployArmy(red,  RED,  redCount,  redComp);
  DeployArmy(blue, BLUE, blueCount, blueComp);

  TUI.ClearBack(TUI.White, TUI.Black);
  TUI.PutStr(2, 0, "SWORDS & SPELLS — Army Review", TUI.Yellow, TUI.Black);
  ShowArmyPreview(RED,  redComp,  redCount);
  ShowArmyPreview(BLUE, blueComp, blueCount);
  TUI.PutStr(2, 22, "Press any key to begin...", TUI.White, TUI.Black);
  TUI.Flush;
  LOOP
    TUI.WaitEvent(ev2);
    IF ev2.kind = TUI.EvKey THEN
      IF ev2.key = 17 THEN TUI.Done; HALT(0) END;
      EXIT
    END
  END;

  logHead := 0; logScroll := 0;
  turn := 1; phase := PH_SHOOT;
  selUnit := -1; cmdSelected := FALSE;
  gameOver := FALSE; verboseAI := FALSE;
  curCol := 0; curRow := GRID_H DIV 2;
  SetShotsForTurn(RED);
  SetShotsForTurn(BLUE);
  AppendLog("Swords & Spells begins. Red (south) fires first.")
END SetupGame;

(* ════════════════════════════════════════════════════════════════════════ *)
(*  Main Game Loop                                                          *)
(* ════════════════════════════════════════════════════════════════════════ *)

PROCEDURE RunGame;
VAR mc, mr: INTEGER;
BEGIN
  TUI.InvalidateFront;
  DrawScreen;
  LOOP
    TUI.WaitEvent(ev);
    IF ev.kind = TUI.EvResize THEN
      TUI.UpdateSize; TUI.InvalidateFront

    ELSIF ev.kind = TUI.EvMouse THEN
      IF (ev.mb = 0) OR (ev.mb = 32) THEN
        mc := (ev.mx - MAPX) DIV 2;
        mr := ev.my - MAPY;
        IF (mc >= 0) & (mc < GRID_W) & (mr >= 0) & (mr < GRID_H) THEN
          curCol := mc; curRow := mr
        END
      END

    ELSIF ev.kind = TUI.EvKey THEN
      IF (ev.key = ORD('q')) OR (ev.key = ORD('Q')) OR (ev.key = 17) THEN EXIT END;
      IF gameOver THEN EXIT END;
      IF ev.key = TUI.KPgUp THEN INC(logScroll)
      ELSIF ev.key = TUI.KPgDn THEN
        DEC(logScroll); IF logScroll < 0 THEN logScroll := 0 END
      ELSIF ev.key = 12 THEN TUI.InvalidateFront
      ELSIF (ev.key = ORD('v')) OR (ev.key = ORD('V')) THEN
        verboseAI := ~verboseAI
      ELSIF (ev.key = ORD('n')) OR (ev.key = ORD('N')) THEN
        IF selUnit < 0 & ~cmdSelected THEN AdvancePhase END
      ELSE
        CASE phase OF
          PH_SHOOT:  HandleShootPhase(ev.key)
        | PH_MOVE:   HandleMovePhase(ev.key)
        | PH_COMBAT: (* N advances, handled above *)
        | PH_ELIM:   (* N advances *)
        ELSE
        END
      END
    END;
    DrawScreen
  END
END RunGame;

(* ════════════════════════════════════════════════════════════════════════ *)
(*  Entry Point                                                             *)
(* ════════════════════════════════════════════════════════════════════════ *)

BEGIN
  InitTables;
  TUI.Init;
  TUI.UpdateSize;
  SetupGame;
  RunGame;
  TUI.Done
END Swords.
