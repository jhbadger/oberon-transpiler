MODULE Chainmail;
(*
 * Chainmail: Rules for Medieval Miniatures (Gygax & Perren, 1971)
 * TUI adaptation — Human (Red, north) vs Computer (Blue, south).
 *
 * Unit types: Light Foot (archers/levy), Heavy Foot, Armored Foot,
 *             Light Horse, Medium Horse, Heavy Horse.
 * Each unit has FIGS_START figures; melee rolls dice from Appendix A tables.
 * Light Foot shoot (range 5, 45-deg arc). Morale checked at thresholds.
 * Cavalry charge forces a defender morale check before melee.
 *
 * Controls:
 *   Arrow keys  – move cursor
 *   Enter       – select unit / confirm move or shot
 *   Esc         – cancel selection
 *   N           – end current phase
 *   Q / Ctrl-Q  – quit
 *)

IMPORT TUI, Random;

CONST
  GRID_W = 12;  GRID_H = 12;
  MAX_UNITS = 6;
  TURNS = 20;

  RED = 0;  BLUE = 1;

  NORTH = 0;  EAST = 1;  SOUTH = 2;  WEST = 3;

  PH_MOVE = 0;  PH_SHOOT = 1;  PH_COMBAT = 2;  PH_ELIM = 3;

  (* Unit types *)
  LF = 0;   (* Light Foot — archers, levy *)
  HF = 1;   (* Heavy Foot — normans, saxons *)
  AF = 2;   (* Armored Foot — dismounted knights *)
  LHT = 3;  (* Light Horse *)
  MH = 4;   (* Medium Horse — esquires, knight *)
  HH = 5;   (* Heavy Horse — fully armoured knights *)
  NTYPES = 6;

  FIGS_START = 10;  (* figures per fresh unit *)

  (* Terrain *)
  TERR_OPEN   = 0;  TERR_HILL  = 1;  TERR_WOOD  = 2;
  TERR_TOWN   = 3;  TERR_MARSH = 4;  TERR_RIVER = 5;
  TERR_FORD   = 6;  TERR_BRIDGE = 7; TERR_ROAD  = 8;

  (* Victory *)
  VIC_ELIM    = 0;  VIC_HOLD  = 1;  VIC_BRIDGES = 2;

  (* Scenarios *)
  SCEN_RANDOM = 0;  SCEN_1 = 1;  SCEN_2 = 2;  SCEN_3 = 3;

  CROSS_COL  = 10;  CROSS_ROW   = 9;
  BRIDGE_ROW =  6;  BRIDGE1_COL = 1;  BRIDGE2_COL = 9;

  MAPX = 3;   MAPY = 3;   SIDEX = 46;
  PANX = 29;  PANY = 4;   PANW = 16;

TYPE
  Unit = RECORD
    utype         : INTEGER;  (* LF..HH *)
    figures       : INTEGER;  (* current count, 0 = dead *)
    col, row      : INTEGER;
    facing        : INTEGER;
    alive         : BOOLEAN;
    moved         : BOOLEAN;
    shot          : BOOLEAN;
    charged       : BOOLEAN;  (* cavalry: moved this turn — impetus in melee *)
    moraleChecked : BOOLEAN;  (* TRUE once first threshold check done *)
  END;

  Army = RECORD
    units : ARRAY MAX_UNITS OF Unit;
    count : INTEGER;
    side  : INTEGER;
  END;

VAR
  turn        : INTEGER;
  phase       : INTEGER;
  activeSide  : INTEGER;
  red, blue   : Army;

  terrain  : ARRAY GRID_H OF ARRAY GRID_W OF INTEGER;

  victoryType : INTEGER;
  scenario    : INTEGER;

  msgLog  : ARRAY 8 OF ARRAY 64 OF CHAR;
  logHead : INTEGER;

  curCol, curRow : INTEGER;
  selUnit        : INTEGER;

  ev       : TUI.Event;
  gameOver : BOOLEAN;

  undoIdx    : ARRAY MAX_UNITS OF INTEGER;
  undoCol    : ARRAY MAX_UNITS OF INTEGER;
  undoRow    : ARRAY MAX_UNITS OF INTEGER;
  undoFacing : ARRAY MAX_UNITS OF INTEGER;
  undoMoved  : ARRAY MAX_UNITS OF BOOLEAN;
  undoTop    : INTEGER;

  (* Melee tables [attacker][defender] *)
  meleeNum : ARRAY NTYPES OF ARRAY NTYPES OF INTEGER;
  meleeDen : ARRAY NTYPES OF ARRAY NTYPES OF INTEGER;
  meleeMin : ARRAY NTYPES OF ARRAY NTYPES OF INTEGER;

  (* Missile fire [defType]: archer figures / die, min score to kill *)
  shotDen : ARRAY NTYPES OF INTEGER;
  shotMin : ARRAY NTYPES OF INTEGER;

  (* Per-type stats *)
  moveAllow    : ARRAY NTYPES OF INTEGER;
  moraleThresh : ARRAY NTYPES OF INTEGER;  (* check when figures <= this *)
  moraleScore  : ARRAY NTYPES OF INTEGER;  (* 2d6 needed to stand *)

  (* Charge morale [defType][cavClass], cavClass = utype-LHT *)
  chargeTarget : ARRAY NTYPES OF ARRAY 3 OF INTEGER;

  (* Army composition [die 0..5][slot 0..5] *)
  compTable : ARRAY 6 OF ARRAY MAX_UNITS OF INTEGER;

  unitName  : ARRAY NTYPES OF ARRAY 14 OF CHAR;
  unitGlyph : ARRAY NTYPES OF CHAR;

(* ═══════════════════════════════════════════════════════════════════════ *)
(*  Table Initialisation                                                    *)
(* ═══════════════════════════════════════════════════════════════════════ *)

PROCEDURE SetMelee(at, de, num, den, min: INTEGER);
BEGIN
  meleeNum[at][de] := num;
  meleeDen[at][de] := den;
  meleeMin[at][de] := min
END SetMelee;

PROCEDURE SetComp(roll, a, b, c, d, e, f: INTEGER);
BEGIN
  compTable[roll][0] := a;  compTable[roll][1] := b;
  compTable[roll][2] := c;  compTable[roll][3] := d;
  compTable[roll][4] := e;  compTable[roll][5] := f
END SetComp;

PROCEDURE InitTables;
(*
 * Melee table from Appendix A: SetMelee(attacker, defender, diceNum, diceDen, minScore)
 *   diceNum/diceDen = dice per attacking figure
 *   minScore = d6 score that kills one defender figure
 *
 * LF[0] HF[1] AF[2] LHT[3] MH[4] HH[5]
 *)
BEGIN
  COPY("Lt.Foot",  unitName[LF]);  unitGlyph[LF] := 'L';
  COPY("Hv.Foot",  unitName[HF]);  unitGlyph[HF] := 'H';
  COPY("Arm.Foot", unitName[AF]);  unitGlyph[AF] := 'A';
  COPY("Lt.Horse", unitName[LHT]); unitGlyph[LHT] := 'h';
  COPY("Md.Horse", unitName[MH]);  unitGlyph[MH] := 'm';
  COPY("Hv.Horse", unitName[HH]);  unitGlyph[HH] := 'K';

  (* Movement allowance in grid cells (scale ~3" per cell) *)
  moveAllow[LF] := 3;  moveAllow[HF] := 3;  moveAllow[AF] := 2;
  moveAllow[LHT] := 6; moveAllow[MH] := 5;  moveAllow[HH] := 4;

  (* Excess-casualty morale: threshold figures, 2d6 score to stand *)
  moraleThresh[LF] := 7;  moraleScore[LF] := 8;   (* 25% loss, need 8+ *)
  moraleThresh[HF] := 6;  moraleScore[HF] := 7;   (* 33% loss, need 7+ *)
  moraleThresh[AF] := 6;  moraleScore[AF] := 6;   (* 33% loss, need 6+ *)
  moraleThresh[LHT] := 6; moraleScore[LHT] := 7;
  moraleThresh[MH] := 5;  moraleScore[MH] := 6;   (* 50% loss, need 6+ *)
  moraleThresh[HH] := 5;  moraleScore[HH] := 4;   (* 50% loss, need 4+ *)

  (*
   * Melee combat tables — Appendix A.
   * Format: num/den dice per figure, min score.
   * LF attacks at 1/1 6 vs LF, 1/2 6 vs HF, 1/3 6 vs AF … etc.
   *)
  (* LF attacking *)
  SetMelee(LF,  LF,  1, 1, 6);  SetMelee(LF,  HF,  1, 2, 6);
  SetMelee(LF,  AF,  1, 3, 6);  SetMelee(LF,  LHT, 1, 2, 6);
  SetMelee(LF,  MH,  1, 3, 6);  SetMelee(LF,  HH,  1, 4, 6);

  (* HF attacking — kills on 5-6 vs lighter foot *)
  SetMelee(HF,  LF,  1, 1, 5);  SetMelee(HF,  HF,  1, 1, 6);
  SetMelee(HF,  AF,  1, 2, 6);  SetMelee(HF,  LHT, 1, 2, 6);
  SetMelee(HF,  MH,  1, 3, 6);  SetMelee(HF,  HH,  1, 4, 6);

  (* AF attacking — slightly better than HF *)
  SetMelee(AF,  LF,  1, 1, 5);  SetMelee(AF,  HF,  1, 1, 5);
  SetMelee(AF,  AF,  1, 1, 6);  SetMelee(AF,  LHT, 1, 2, 6);
  SetMelee(AF,  MH,  1, 2, 6);  SetMelee(AF,  HH,  1, 3, 6);

  (* LH attacking — 2 dice/man vs foot *)
  SetMelee(LHT, LF,  2, 1, 5);  SetMelee(LHT, HF,  2, 1, 6);
  SetMelee(LHT, AF,  1, 1, 6);  SetMelee(LHT, LHT, 1, 1, 6);
  SetMelee(LHT, MH,  1, 2, 6);  SetMelee(LHT, HH,  1, 3, 6);

  (* MH attacking *)
  SetMelee(MH,  LF,  2, 1, 4);  SetMelee(MH,  HF,  2, 1, 5);
  SetMelee(MH,  AF,  2, 1, 6);  SetMelee(MH,  LHT, 1, 1, 5);
  SetMelee(MH,  MH,  1, 1, 6);  SetMelee(MH,  HH,  1, 2, 6);

  (* HH attacking — the heavy hitters *)
  SetMelee(HH,  LF,  4, 1, 5);  SetMelee(HH,  HF,  3, 1, 5);
  SetMelee(HH,  AF,  2, 1, 5);  SetMelee(HH,  LHT, 2, 1, 5);
  SetMelee(HH,  MH,  1, 1, 5);  SetMelee(HH,  HH,  1, 1, 6);

  (*
   * Missile fire table [defType]: shotDen = figures per die, shotMin = kill score.
   * Unarmored (LF, LH): 1 die/2 figures, kill on 4+
   * Half-armored (HF, MH): 1 die/2 figures, kill on 5+
   * Full armor (AF, HH): 1 die/4 figures, kill on 6
   *)
  shotDen[LF] := 2;  shotMin[LF] := 4;
  shotDen[HF] := 2;  shotMin[HF] := 5;
  shotDen[AF] := 4;  shotMin[AF] := 6;
  shotDen[LHT] := 2; shotMin[LHT] := 4;
  shotDen[MH] := 2;  shotMin[MH] := 5;
  shotDen[HH] := 4;  shotMin[HH] := 6;

  (*
   * Cavalry charge morale [defType][cavClass]:
   *   cavClass 0=LH, 1=MH, 2=HH.  Foot must roll 2d6 >= table value or retreat.
   *)
  chargeTarget[LF][0]  := 8;  chargeTarget[LF][1]  := 9;  chargeTarget[LF][2]  := 10;
  chargeTarget[HF][0]  := 7;  chargeTarget[HF][1]  := 8;  chargeTarget[HF][2]  :=  9;
  chargeTarget[AF][0]  := 6;  chargeTarget[AF][1]  := 7;  chargeTarget[AF][2]  :=  8;
  chargeTarget[LHT][0] := 5;  chargeTarget[LHT][1] := 6;  chargeTarget[LHT][2] :=  7;
  chargeTarget[MH][0]  := 4;  chargeTarget[MH][1]  := 5;  chargeTarget[MH][2]  :=  6;
  chargeTarget[HH][0]  := 3;  chargeTarget[HH][1]  := 4;  chargeTarget[HH][2]  :=  5;

  (*
   * Army composition [die 0-5]: six unit-type slots per roll.
   * Unit types: LF=0 HF=1 AF=2 LHT=3 MH=4 HH=5
   *)
  SetComp(0, LF, LF, HF, HF, HF, LHT);   (* 2 archer bands + 3 heavy foot + light cav *)
  SetComp(1, LF, LF, HF, AF, LHT, MH);   (* 2 archers + foot + dismounted + cav *)
  SetComp(2, LF, HF, HF, AF, MH, MH);    (* archer + heavy foot + armored + 2 medium horse *)
  SetComp(3, LF, HF, AF, AF, LHT, MH);   (* archer + heavy + 2 armored + horse *)
  SetComp(4, LF, HF, HF, LHT, MH, HH);  (* archer + foot + light + medium + heavy horse *)
  SetComp(5, HF, HF, AF, AF, MH, HH)    (* no archers: all heavy troops *)
END InitTables;

(* ═══════════════════════════════════════════════════════════════════════ *)
(*  Utility                                                                 *)
(* ═══════════════════════════════════════════════════════════════════════ *)

PROCEDURE D6(): INTEGER;
BEGIN RETURN Random.Int(6) + 1 END D6;

PROCEDURE D6D6(): INTEGER;
BEGIN RETURN D6() + D6() END D6D6;

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

PROCEDURE Min(a, b: INTEGER): INTEGER;
BEGIN IF a < b THEN RETURN a ELSE RETURN b END END Min;

PROCEDURE CDist(c1, r1, c2, r2: INTEGER): INTEGER;
BEGIN RETURN Max(Abs(c1 - c2), Abs(r1 - r2)) END CDist;

PROCEDURE AppendLog(msg: ARRAY OF CHAR);
BEGIN
  COPY(msg, msgLog[logHead MOD 8]);
  INC(logHead)
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

(* TRUE if attacker is NOT in defender's 45-degree front arc *)
PROCEDURE IsFlankOrRear(aCol, aRow: INTEGER; def: Unit): BOOLEAN;
VAR dc, dr: INTEGER;
BEGIN
  dc := aCol - def.col; dr := aRow - def.row;
  CASE def.facing OF
    NORTH: RETURN dr >= 0
  | EAST:  RETURN dc <= 0
  | SOUTH: RETURN dr <= 0
  | WEST:  RETURN dc >= 0
  END;
  RETURN FALSE
END IsFlankOrRear;

(* TRUE if attacker is squarely behind defender *)
PROCEDURE IsRearAttack(aCol, aRow: INTEGER; def: Unit): BOOLEAN;
VAR dc, dr: INTEGER;
BEGIN
  dc := aCol - def.col; dr := aRow - def.row;
  CASE def.facing OF
    NORTH: RETURN dr > 0
  | EAST:  RETURN dc < 0
  | SOUTH: RETURN dr < 0
  | WEST:  RETURN dc > 0
  END;
  RETURN FALSE
END IsRearAttack;

PROCEDURE InFrontArc(sCol, sRow, tCol, tRow, facing: INTEGER): BOOLEAN;
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
(*  River / Terrain Helpers                                                 *)
(* ═══════════════════════════════════════════════════════════════════════ *)

PROCEDURE RiverBlocked(srcCol, srcRow, dstCol, dstRow, mv: INTEGER): BOOLEAN;
VAR r, c, rMin, rMax, t, crossCost: INTEGER;
    hasRiver, canCross: BOOLEAN;
BEGIN
  IF srcRow < dstRow THEN rMin := srcRow + 1; rMax := dstRow - 1
  ELSE rMin := dstRow + 1; rMax := srcRow - 1
  END;
  FOR r := rMin TO rMax DO
    hasRiver := FALSE;
    FOR c := 0 TO GRID_W - 1 DO
      IF terrain[r][c] = TERR_RIVER THEN hasRiver := TRUE END
    END;
    IF hasRiver THEN
      canCross := FALSE;
      FOR c := 0 TO GRID_W - 1 DO
        t := terrain[r][c];
        IF (t = TERR_BRIDGE) OR (t = TERR_FORD) THEN
          crossCost := CDist(srcCol, srcRow, c, r) + CDist(c, r, dstCol, dstRow);
          IF crossCost <= mv THEN canCross := TRUE END
        END
      END;
      IF ~canCross THEN RETURN TRUE END
    END
  END;
  RETURN FALSE
END RiverBlocked;

(* ═══════════════════════════════════════════════════════════════════════ *)
(*  Movement Validity                                                        *)
(* ═══════════════════════════════════════════════════════════════════════ *)

PROCEDURE ValidMoveTarget(side, idx, dstCol, dstRow: INTEGER): BOOLEAN;
VAR ut, mv, srcCol, srcRow, oSide, oIdx: INTEGER;
    u: Unit; a: Army;
BEGIN
  a := ArmyOf(side); u := a.units[idx];
  ut := u.utype; mv := moveAllow[ut];
  srcCol := u.col; srcRow := u.row;

  IF (terrain[srcRow][srcCol] = TERR_ROAD) &
     (terrain[dstRow][dstCol] = TERR_ROAD) &
     ((srcRow = dstRow) OR (srcCol = dstCol)) THEN INC(mv) END;

  IF (dstCol < 0) OR (dstCol >= GRID_W) OR (dstRow < 0) OR (dstRow >= GRID_H) THEN
    RETURN FALSE
  END;
  IF CDist(srcCol, srcRow, dstCol, dstRow) > mv THEN RETURN FALSE END;
  IF (dstCol = srcCol) & (dstRow = srcRow) THEN RETURN FALSE END;

  UnitAt(dstCol, dstRow, oSide, oIdx);
  IF oSide >= 0 THEN RETURN FALSE END;

  IF terrain[dstRow][dstCol] = TERR_MARSH THEN RETURN FALSE END;
  IF terrain[dstRow][dstCol] = TERR_RIVER THEN RETURN FALSE END;
  IF RiverBlocked(srcCol, srcRow, dstCol, dstRow, mv) THEN RETURN FALSE END;

  (* Cavalry cannot enter woods *)
  IF (terrain[dstRow][dstCol] = TERR_WOOD) & (ut >= LHT) THEN RETURN FALSE END;

  RETURN TRUE
END ValidMoveTarget;

(* ═══════════════════════════════════════════════════════════════════════ *)
(*  Shooting Validity (Light Foot only, range 5, 45-deg arc)               *)
(* ═══════════════════════════════════════════════════════════════════════ *)

PROCEDURE CanShootTarget(side, idx, tCol, tRow: INTEGER): BOOLEAN;
VAR u: Unit; a: Army;
BEGIN
  a := ArmyOf(side); u := a.units[idx];
  IF u.utype # LF THEN RETURN FALSE END;
  IF u.shot THEN RETURN FALSE END;
  IF u.moved THEN RETURN FALSE END;  (* archers may not move and shoot *)
  IF CDist(u.col, u.row, tCol, tRow) > 5 THEN RETURN FALSE END;
  IF ~InFrontArc(u.col, u.row, tCol, tRow, u.facing) THEN RETURN FALSE END;
  RETURN TRUE
END CanShootTarget;

(* ═══════════════════════════════════════════════════════════════════════ *)
(*  Combat Resolution                                                        *)
(* ═══════════════════════════════════════════════════════════════════════ *)

PROCEDURE ReduceFigures(side, idx, amount: INTEGER);
BEGIN
  IF side = RED THEN
    DEC(red.units[idx].figures, amount);
    IF red.units[idx].figures < 0 THEN red.units[idx].figures := 0 END
  ELSE
    DEC(blue.units[idx].figures, amount);
    IF blue.units[idx].figures < 0 THEN blue.units[idx].figures := 0 END
  END
END ReduceFigures;

PROCEDURE ResolveShot(attSide, attIdx, defSide, defIdx: INTEGER;
                      VAR msg: ARRAY OF CHAR);
VAR att, def: Unit;
    aArmy, dArmy: Army;
    nd, i, d, kills: INTEGER;
    numStr: ARRAY 8 OF CHAR;
BEGIN
  aArmy := ArmyOf(attSide); att := aArmy.units[attIdx];
  dArmy := ArmyOf(defSide); def := dArmy.units[defIdx];

  nd := att.figures DIV shotDen[def.utype];
  IF nd < 1 THEN nd := 1 END;

  (* Cover: halve dice in woods or town *)
  IF (terrain[def.row][def.col] = TERR_WOOD) OR
     (terrain[def.row][def.col] = TERR_TOWN) THEN
    nd := nd DIV 2;
    IF nd < 1 THEN nd := 1 END
  END;

  kills := 0;
  FOR i := 1 TO nd DO
    d := D6();
    IF d >= shotMin[def.utype] THEN INC(kills) END
  END;

  ReduceFigures(defSide, defIdx, kills);

  COPY("Shot: ", msg); IntStr(nd, numStr); AppendStr(msg, numStr);
  AppendStr(msg, "d6->"); IntStr(kills, numStr); AppendStr(msg, numStr);
  AppendStr(msg, " kill(s)")
END ResolveShot;

(*
 * ResolveMelee: both sides exchange casualties simultaneously (Chainmail §Melees).
 * Attacker rolls meleeNum[effAtype][defType] * attFigures / meleeDen dice;
 * defender counter-attacks unless rear-attacked.
 * Flank/rear: treat attacker as next higher class.
 * Cavalry charged this turn: +1 die (impetus bonus).
 *)
PROCEDURE ResolveMelee(attSide, attIdx, defSide, defIdx: INTEGER;
                       noCounter: BOOLEAN; VAR msg: ARRAY OF CHAR);
VAR att, def: Unit;
    aArmy, dArmy: Army;
    effAtype, effDtype: INTEGER;
    nd, i, d, kills1, kills2: INTEGER;
    flanked, rearAtt: BOOLEAN;
    numStr: ARRAY 8 OF CHAR;
BEGIN
  aArmy := ArmyOf(attSide); att := aArmy.units[attIdx];
  dArmy := ArmyOf(defSide); def := dArmy.units[defIdx];

  rearAtt := IsRearAttack(att.col, att.row, def);
  flanked := ~rearAtt & IsFlankOrRear(att.col, att.row, def);

  effAtype := att.utype;
  IF (flanked OR rearAtt) & (effAtype < HH) THEN INC(effAtype) END;

  effDtype := def.utype;

  (* Attacker's dice *)
  nd := meleeNum[effAtype][effDtype] * att.figures DIV meleeDen[effAtype][effDtype];
  IF nd < 1 THEN nd := 1 END;
  IF att.charged & (att.utype >= LHT) THEN INC(nd) END;   (* impetus *)
  (* Hill defence: halve attacker dice when defender on hill *)
  IF terrain[def.row][def.col] = TERR_HILL THEN nd := nd DIV 2; IF nd < 1 THEN nd := 1 END END;

  kills1 := 0;
  FOR i := 1 TO nd DO
    d := D6(); IF d >= meleeMin[effAtype][effDtype] THEN INC(kills1) END
  END;

  (* Defender counter-attacks unless rear attack or noCounter flag set *)
  kills2 := 0;
  IF ~rearAtt & ~noCounter THEN
    nd := meleeNum[effDtype][effAtype] * def.figures DIV meleeDen[effDtype][effAtype];
    IF nd < 1 THEN nd := 1 END;
    FOR i := 1 TO nd DO
      d := D6(); IF d >= meleeMin[effDtype][effAtype] THEN INC(kills2) END
    END
  END;

  ReduceFigures(defSide, defIdx, kills1);
  ReduceFigures(attSide, attIdx, kills2);

  COPY("Melee: ", msg);
  IntStr(kills1, numStr); AppendStr(msg, numStr); AppendStr(msg, "k/");
  IntStr(kills2, numStr); AppendStr(msg, numStr); AppendStr(msg, "k");
  IF rearAtt THEN AppendStr(msg, " REAR!")
  ELSIF flanked THEN AppendStr(msg, " flank")
  END
END ResolveMelee;

(* ═══════════════════════════════════════════════════════════════════════ *)
(*  Morale                                                                   *)
(* ═══════════════════════════════════════════════════════════════════════ *)

(* Retreat unit toward own baseline (Red north, Blue south) *)
PROCEDURE RetreatUnit(side, idx, steps: INTEGER);
VAR nc, nr, t: INTEGER;
    a: Army; i: INTEGER;
BEGIN
  a := ArmyOf(side);
  nc := a.units[idx].col;
  nr := a.units[idx].row;
  FOR i := 1 TO steps DO
    IF side = RED THEN
      IF nr > 0 THEN DEC(nr) END
    ELSE
      IF nr < GRID_H - 1 THEN INC(nr) END
    END;
    (* don't retreat into occupied or impassable cell *)
    t := terrain[nr][nc];
    IF (t = TERR_MARSH) OR (t = TERR_RIVER) THEN
      nr := a.units[idx].row; nc := a.units[idx].col; (* stay put *)
      i := steps  (* break *)
    ELSIF OccupiedBy(nc, nr, RED) OR OccupiedBy(nc, nr, BLUE) THEN
      nr := a.units[idx].row; nc := a.units[idx].col;
      i := steps
    END
  END;
  a := ArmyOf(side);
  a.units[idx].col := nc;
  a.units[idx].row := nr;
  SetArmy(side, a)
END RetreatUnit;

(*
 * Check excess-casualty morale for unit (side, idx).
 * Called after any figure loss.  Returns TRUE if unit stands.
 *)
PROCEDURE CheckUnitMorale(side, idx: INTEGER; VAR msg: ARRAY OF CHAR): BOOLEAN;
VAR a: Army; u: Unit; roll: INTEGER;
    numStr: ARRAY 8 OF CHAR;
BEGIN
  a := ArmyOf(side); u := a.units[idx];
  IF u.moraleChecked THEN RETURN TRUE END;
  IF u.figures > moraleThresh[u.utype] THEN RETURN TRUE END;

  (* Mark as checked so we only roll once per threshold crossing *)
  a.units[idx].moraleChecked := TRUE;
  SetArmy(side, a);

  roll := D6D6();
  IF roll >= moraleScore[u.utype] THEN
    COPY(unitName[u.utype], msg);
    AppendStr(msg, " stands (morale ");
    IntStr(roll, numStr); AppendStr(msg, numStr); AppendStr(msg, ")");
    RETURN TRUE
  ELSE
    COPY(unitName[u.utype], msg);
    AppendStr(msg, " retreats! (morale ");
    IntStr(roll, numStr); AppendStr(msg, numStr); AppendStr(msg, ")");
    RetreatUnit(side, idx, 2);
    RETURN FALSE
  END
END CheckUnitMorale;

(*
 * Cavalry charge morale: foot unit must roll 2d6 vs table before melee.
 * Returns TRUE if defender stands (melee proceeds normally).
 * If FALSE, defender retreats and should not counter-attack.
 *)
PROCEDURE CheckChargeMorale(defSide, defIdx, cavUtype: INTEGER;
                             VAR msg: ARRAY OF CHAR): BOOLEAN;
VAR a: Army; def: Unit;
    roll, need, cavClass: INTEGER;
    numStr: ARRAY 8 OF CHAR;
BEGIN
  a := ArmyOf(defSide); def := a.units[defIdx];
  IF def.utype >= LHT THEN RETURN TRUE END;  (* cavalry vs cavalry: no check *)
  cavClass := cavUtype - LHT;
  IF (cavClass < 0) OR (cavClass > 2) THEN RETURN TRUE END;

  need := chargeTarget[def.utype][cavClass];
  roll := D6D6();

  IF roll >= need THEN
    COPY(unitName[def.utype], msg);
    AppendStr(msg, " stands charge (");
    IntStr(roll, numStr); AppendStr(msg, numStr); AppendStr(msg, ")");
    RETURN TRUE
  ELSE
    COPY(unitName[def.utype], msg);
    AppendStr(msg, " flees charge! (");
    IntStr(roll, numStr); AppendStr(msg, numStr); AppendStr(msg, ")");
    RetreatUnit(defSide, defIdx, 2);
    RETURN FALSE
  END
END CheckChargeMorale;

(* ═══════════════════════════════════════════════════════════════════════ *)
(*  Elimination and Victory                                                 *)
(* ═══════════════════════════════════════════════════════════════════════ *)

PROCEDURE CheckElimination;
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO red.count - 1 DO
    IF red.units[i].alive & (red.units[i].figures <= 0) THEN
      red.units[i].alive := FALSE;
      AppendLog("Red unit eliminated!")
    END
  END;
  FOR i := 0 TO blue.count - 1 DO
    IF blue.units[i].alive & (blue.units[i].figures <= 0) THEN
      blue.units[i].alive := FALSE;
      AppendLog("Blue unit eliminated!")
    END
  END
END CheckElimination;

PROCEDURE AliveCount(side: INTEGER): INTEGER;
VAR a: Army; i, n: INTEGER;
BEGIN
  a := ArmyOf(side); n := 0;
  FOR i := 0 TO a.count - 1 DO IF a.units[i].alive THEN INC(n) END END;
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
    rHill, bHill, rCross, bCross, rB1, bB1, rB2, bB2: BOOLEAN;
BEGIN
  rAlive := AliveCount(RED); bAlive := AliveCount(BLUE);
  IF rAlive = 0 THEN
    AppendLog("BLUE WINS — Red army destroyed!"); gameOver := TRUE; RETURN
  ELSIF bAlive = 0 THEN
    AppendLog("RED WINS — Blue army destroyed!"); gameOver := TRUE; RETURN
  END;

  IF turn > TURNS THEN
    IF victoryType = VIC_HOLD THEN
      rHill  := SideOnHill(RED)  & ~SideOnHill(BLUE);
      bHill  := SideOnHill(BLUE) & ~SideOnHill(RED);
      rCross := SideAtCell(RED,  CROSS_COL, CROSS_ROW) & ~SideAtCell(BLUE, CROSS_COL, CROSS_ROW);
      bCross := SideAtCell(BLUE, CROSS_COL, CROSS_ROW) & ~SideAtCell(RED,  CROSS_COL, CROSS_ROW);
      IF rHill & rCross THEN       AppendLog("RED WINS — hill and crossroads held!")
      ELSIF bHill & bCross THEN    AppendLog("BLUE WINS — hill and crossroads held!")
      ELSIF rAlive > bAlive THEN   AppendLog("RED WINS — more survivors")
      ELSIF bAlive > rAlive THEN   AppendLog("BLUE WINS — more survivors")
      ELSE                         AppendLog("DRAW — equal survivors")
      END
    ELSIF victoryType = VIC_BRIDGES THEN
      rB1 := SideAtCell(RED, BRIDGE1_COL, BRIDGE_ROW) & ~SideAtCell(BLUE, BRIDGE1_COL, BRIDGE_ROW);
      bB1 := SideAtCell(BLUE,BRIDGE1_COL, BRIDGE_ROW) & ~SideAtCell(RED,  BRIDGE1_COL, BRIDGE_ROW);
      rB2 := SideAtCell(RED, BRIDGE2_COL, BRIDGE_ROW) & ~SideAtCell(BLUE, BRIDGE2_COL, BRIDGE_ROW);
      bB2 := SideAtCell(BLUE,BRIDGE2_COL, BRIDGE_ROW) & ~SideAtCell(RED,  BRIDGE2_COL, BRIDGE_ROW);
      IF rB1 & rB2 THEN          AppendLog("RED WINS — both bridges held!")
      ELSIF bB1 & bB2 THEN       AppendLog("BLUE WINS — both bridges held!")
      ELSIF rAlive > bAlive THEN AppendLog("RED WINS — more survivors")
      ELSIF bAlive > rAlive THEN AppendLog("BLUE WINS — more survivors")
      ELSE                       AppendLog("DRAW — bridges split")
      END
    ELSE
      IF rAlive > bAlive THEN    AppendLog("RED WINS — most units surviving!")
      ELSIF bAlive > rAlive THEN AppendLog("BLUE WINS — most units surviving!")
      ELSE                       AppendLog("DRAW — equal survivors!")
      END
    END;
    gameOver := TRUE
  END
END CheckVictory;

(* ═══════════════════════════════════════════════════════════════════════ *)
(*  Combat Phase — all adjacent pairs fight simultaneously                  *)
(* ═══════════════════════════════════════════════════════════════════════ *)

PROCEDURE ResolveMeleeAll;
VAR i, j: INTEGER;
    att, def: Unit;
    msg: ARRAY 64 OF CHAR;
    moraleMsg: ARRAY 64 OF CHAR;
    noCounter: BOOLEAN;
BEGIN
  (*
   * For each Red unit adjacent to a Blue unit (during Red's turn):
   * 1. If Red cavalry charged (moved), check Blue's charge morale first.
   * 2. Resolve simultaneous melee (both take casualties).
   * 3. Check excess-casualty morale for both units.
   *)
  FOR i := 0 TO red.count - 1 DO
    IF red.units[i].alive THEN
      att := red.units[i];
      FOR j := 0 TO blue.count - 1 DO
        IF blue.units[j].alive &
           (CDist(att.col, att.row, blue.units[j].col, blue.units[j].row) = 1) THEN
          def := blue.units[j];
          noCounter := FALSE;

          (* Cavalry charge morale for Blue defender *)
          IF att.charged & (att.utype >= LHT) & (def.utype < LHT) THEN
            IF ~CheckChargeMorale(BLUE, j, att.utype, msg) THEN
              AppendLog(msg);
              noCounter := TRUE  (* defender fled: no counter-attack *)
            ELSE
              AppendLog(msg)
            END
          END;

          ResolveMelee(RED, i, BLUE, j, noCounter, msg);
          AppendLog(msg);

          (* Excess-casualty morale checks *)
          IF blue.units[j].alive THEN
            IF ~CheckUnitMorale(BLUE, j, moraleMsg) THEN AppendLog(moraleMsg) END
          END;
          IF red.units[i].alive THEN
            IF ~CheckUnitMorale(RED, i, moraleMsg) THEN AppendLog(moraleMsg) END
          END
        END
      END
    END
  END;
  CheckElimination
END ResolveMeleeAll;

(* ═══════════════════════════════════════════════════════════════════════ *)
(*  AI (Blue)                                                               *)
(* ═══════════════════════════════════════════════════════════════════════ *)

PROCEDURE AIFindClosestEnemy(bIdx: INTEGER; VAR tCol, tRow: INTEGER);
VAR i, dist, best: INTEGER; bu: Unit;
BEGIN
  bu := blue.units[bIdx]; best := 9999; tCol := -1; tRow := -1;
  FOR i := 0 TO red.count - 1 DO
    IF red.units[i].alive THEN
      dist := CDist(bu.col, bu.row, red.units[i].col, red.units[i].row);
      IF dist < best THEN best := dist; tCol := red.units[i].col; tRow := red.units[i].row END
    END
  END
END AIFindClosestEnemy;

PROCEDURE AIFindShotTarget(bIdx: INTEGER; VAR tSide, tIdx: INTEGER);
VAR i, best: INTEGER;
BEGIN
  tSide := -1; tIdx := -1; best := -1;
  FOR i := 0 TO red.count - 1 DO
    IF red.units[i].alive &
       CanShootTarget(BLUE, bIdx, red.units[i].col, red.units[i].row) THEN
      IF red.units[i].figures < best OR best < 0 THEN
        best := red.units[i].figures; tSide := RED; tIdx := i
      END
    END
  END
END AIFindShotTarget;

PROCEDURE AIMoveUnit(bIdx: INTEGER);
VAR tCol, tRow, bestCol, bestRow, bestDist, dc, dr, nc, nr, newDist: INTEGER;
    ut, mv: INTEGER;
    msg: ARRAY 64 OF CHAR;
BEGIN
  ut := blue.units[bIdx].utype; mv := moveAllow[ut];
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
        IF newDist < bestDist THEN
          bestDist := newDist; bestCol := nc; bestRow := nr
        END
      END
    END
  END;

  IF (bestCol # blue.units[bIdx].col) OR (bestRow # blue.units[bIdx].row) THEN
    blue.units[bIdx].facing := FaceToward(blue.units[bIdx].col, blue.units[bIdx].row,
                                           bestCol, bestRow);
    blue.units[bIdx].col    := bestCol;
    blue.units[bIdx].row    := bestRow;
    blue.units[bIdx].moved  := TRUE;
    (* Cavalry gets charged flag when it moves — impetus for melee *)
    IF blue.units[bIdx].utype >= LHT THEN blue.units[bIdx].charged := TRUE END
  END
END AIMoveUnit;

PROCEDURE DoAITurn;
VAR i, tSide, tIdx: INTEGER;
    msg: ARRAY 64 OF CHAR;
    moraleMsg: ARRAY 64 OF CHAR;
    noCounter: BOOLEAN;
BEGIN
  (* Move *)
  FOR i := 0 TO blue.count - 1 DO
    IF blue.units[i].alive & ~blue.units[i].moved THEN AIMoveUnit(i) END
  END;

  (* Shoot (only LF archers) *)
  FOR i := 0 TO blue.count - 1 DO
    IF blue.units[i].alive & (blue.units[i].utype = LF) THEN
      AIFindShotTarget(i, tSide, tIdx);
      IF tIdx >= 0 THEN
        ResolveShot(BLUE, i, tSide, tIdx, msg);
        AppendLog(msg);
        blue.units[i].shot := TRUE;
        IF red.units[tIdx].alive THEN
          IF ~CheckUnitMorale(RED, tIdx, moraleMsg) THEN AppendLog(moraleMsg) END
        END
      END
    END
  END;

  (* Melee: each Blue unit adjacent to Red *)
  FOR i := 0 TO blue.count - 1 DO
    IF blue.units[i].alive THEN
      FOR tIdx := 0 TO red.count - 1 DO
        IF red.units[tIdx].alive &
           (CDist(blue.units[i].col, blue.units[i].row,
                  red.units[tIdx].col, red.units[tIdx].row) = 1) THEN
          noCounter := FALSE;
          (* Cavalry charge morale for Red defender *)
          IF blue.units[i].charged & (blue.units[i].utype >= LHT) &
             (red.units[tIdx].utype < LHT) THEN
            IF ~CheckChargeMorale(RED, tIdx, blue.units[i].utype, msg) THEN
              AppendLog(msg); noCounter := TRUE
            ELSE AppendLog(msg)
            END
          END;
          ResolveMelee(BLUE, i, RED, tIdx, noCounter, msg);
          AppendLog(msg);
          IF red.units[tIdx].alive THEN
            IF ~CheckUnitMorale(RED, tIdx, moraleMsg) THEN AppendLog(moraleMsg) END
          END;
          IF blue.units[i].alive THEN
            IF ~CheckUnitMorale(BLUE, i, moraleMsg) THEN AppendLog(moraleMsg) END
          END
        END
      END
    END
  END;
  CheckElimination
END DoAITurn;

(* ═══════════════════════════════════════════════════════════════════════ *)
(*  Display                                                                 *)
(* ═══════════════════════════════════════════════════════════════════════ *)

PROCEDURE DrawCell(col, row: INTEGER);
VAR sx, sy, uSide, uIdx: INTEGER;
    u: Unit; tmpArmy: Army;
    fg, bg: INTEGER;
    c0, c1: CHAR;
    isCursor, isSelected, isValidMove, isShootable, isTargetable: BOOLEAN;
BEGIN
  sx := MAPX + col * 2; sy := MAPY + row;
  UnitAt(col, row, uSide, uIdx);

  isCursor   := (col = curCol) & (row = curRow);
  isSelected := (selUnit >= 0) & (uSide = activeSide) & (uIdx = selUnit);

  isValidMove := FALSE;
  IF (selUnit >= 0) & (phase = PH_MOVE) & (uSide < 0) THEN
    isValidMove := ValidMoveTarget(activeSide, selUnit, col, row)
  END;

  isShootable := FALSE;
  IF (selUnit < 0) & (phase = PH_SHOOT) & (uSide = RED) THEN
    isShootable := (uIdx >= 0) & (red.units[uIdx].utype = LF) &
                   ~red.units[uIdx].shot & ~red.units[uIdx].moved
  END;

  isTargetable := FALSE;
  IF (selUnit >= 0) & (phase = PH_SHOOT) & (uSide = BLUE) THEN
    isTargetable := CanShootTarget(activeSide, selUnit, col, row)
  END;

  IF isCursor THEN              bg := TUI.Cyan;    fg := TUI.Black
  ELSIF isSelected THEN         bg := TUI.Yellow;  fg := TUI.Black
  ELSIF isValidMove OR isTargetable THEN bg := TUI.Green; fg := TUI.Black
  ELSIF isShootable THEN        bg := TUI.Magenta; fg := TUI.White
  ELSIF terrain[row][col] = TERR_HILL  THEN bg := TUI.Yellow;  fg := TUI.Black
  ELSIF terrain[row][col] = TERR_WOOD  THEN bg := TUI.Green;   fg := TUI.Black
  ELSIF (terrain[row][col] = TERR_RIVER) OR (terrain[row][col] = TERR_MARSH) OR
        (terrain[row][col] = TERR_BRIDGE) OR (terrain[row][col] = TERR_FORD) THEN
    bg := TUI.Blue; fg := TUI.White
  ELSE bg := TUI.Black; fg := TUI.White
  END;

  IF uSide >= 0 THEN
    tmpArmy := ArmyOf(uSide); u := tmpArmy.units[uIdx];
    IF uSide = RED THEN
      IF ~isCursor & ~isSelected & ~isShootable THEN fg := TUI.Red ELSE fg := TUI.Black END;
      c0 := 'R'
    ELSE
      IF ~isCursor & ~isTargetable THEN fg := TUI.Cyan ELSE fg := TUI.Black END;
      c0 := 'B'
    END;
    c1 := unitGlyph[u.utype]
  ELSE
    IF isCursor OR isValidMove THEN fg := TUI.Black ELSE fg := TUI.White END;
    IF terrain[row][col] = TERR_HILL THEN c0 := '^'
    ELSIF terrain[row][col] = TERR_WOOD THEN c0 := 'T'
    ELSIF terrain[row][col] = TERR_ROAD THEN
      IF (col = CROSS_COL) & (row = CROSS_ROW) THEN c0 := '+' ELSE c0 := '#' END
    ELSIF terrain[row][col] = TERR_BRIDGE THEN c0 := '['
    ELSIF terrain[row][col] = TERR_FORD   THEN c0 := '='
    ELSIF (terrain[row][col] = TERR_RIVER) OR (terrain[row][col] = TERR_MARSH) THEN c0 := '~'
    ELSE c0 := '.'
    END;
    c1 := ' '
  END;

  TUI.PutCell(sx,     sy, c0, fg, bg);
  TUI.PutCell(sx + 1, sy, c1, fg, bg)
END DrawCell;

PROCEDURE DrawMap;
VAR c, r: INTEGER; label: CHAR;
BEGIN
  FOR c := 0 TO GRID_W - 1 DO
    IF c < 10 THEN label := CHR(ORD('0') + c) ELSE label := CHR(ORD('A') + c - 10) END;
    TUI.PutCell(MAPX + c*2,     MAPY - 1, label, TUI.Yellow, TUI.Black);
    TUI.PutCell(MAPX + c*2 + 1, MAPY - 1, ' ',   TUI.Yellow, TUI.Black)
  END;
  FOR r := 0 TO GRID_H - 1 DO
    IF r < 10 THEN label := CHR(ORD('0') + r) ELSE label := CHR(ORD('A') + r - 10) END;
    TUI.PutCell(MAPX - 2, MAPY + r, label, TUI.Yellow, TUI.Black);
    TUI.PutCell(MAPX - 1, MAPY + r, ' ',   TUI.Black,  TUI.Black);
    FOR c := 0 TO GRID_W - 1 DO DrawCell(c, r) END
  END
END DrawMap;

PROCEDURE DrawUnitList;
VAR i, sx, sy: INTEGER;
    u: Unit; fg: INTEGER;
    num: ARRAY 4 OF CHAR;
BEGIN
  sx := SIDEX;
  TUI.PutStr(sx, 2, "Unit         Figs", TUI.Yellow, TUI.Black);
  sy := 3;
  TUI.PutStr(sx, sy, "[Red]", TUI.Red, TUI.Black); INC(sy);
  FOR i := 0 TO red.count - 1 DO
    u := red.units[i];
    fg := TUI.White;
    TUI.PutStr(sx,      sy, unitName[u.utype], fg, TUI.Black);
    IntStr(u.figures, num);
    TUI.PutStr(sx + 14, sy, num, fg, TUI.Black);
    IF ~u.alive THEN TUI.PutStr(sx + 17, sy, "X", TUI.Red, TUI.Black) END;
    INC(sy)
  END;
  INC(sy);
  TUI.PutStr(sx, sy, "[Blue]", TUI.Cyan, TUI.Black); INC(sy);
  FOR i := 0 TO blue.count - 1 DO
    u := blue.units[i];
    fg := TUI.White;
    TUI.PutStr(sx,      sy, unitName[u.utype], fg, TUI.Black);
    IntStr(u.figures, num);
    TUI.PutStr(sx + 14, sy, num, fg, TUI.Black);
    IF ~u.alive THEN TUI.PutStr(sx + 17, sy, "X", TUI.Cyan, TUI.Black) END;
    INC(sy)
  END
END DrawUnitList;

PROCEDURE DrawLog;
VAR i, sy, nShow: INTEGER;
BEGIN
  sy := MAPY + GRID_H + 2;
  nShow := TUI.Rows - sy - 1;
  IF nShow > 8 THEN nShow := 8 END;
  IF nShow < 1 THEN RETURN END;
  TUI.PutStr(1, sy - 1, "--- Log ---", TUI.Yellow, TUI.Black);
  FOR i := 0 TO nShow - 1 DO
    TUI.PutStr(1, sy + i, msgLog[(logHead - nShow + i + 64) MOD 8], TUI.White, TUI.Black)
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
VAR uSide, uIdx: INTEGER; a: Army; u: Unit;
    s: ARRAY 20 OF CHAR; n: ARRAY 8 OF CHAR; fg: INTEGER;
BEGIN
  UnitAt(curCol, curRow, uSide, uIdx);
  IF uSide < 0 THEN
    IF curCol < 10 THEN s[0] := CHR(ORD('0') + curCol) ELSE s[0] := CHR(ORD('A') + curCol - 10) END;
    IF curRow < 10 THEN s[1] := CHR(ORD('0') + curRow) ELSE s[1] := CHR(ORD('A') + curRow - 10) END;
    s[2] := ' '; s[3] := 0X; AppendStr(s, "(empty)");
    PutPanel(PANY,   s, TUI.White);
    PutPanel(PANY+1, "", TUI.White); PutPanel(PANY+2, "", TUI.White);
    PutPanel(PANY+3, "", TUI.White); PutPanel(PANY+4, "", TUI.White);
    PutPanel(PANY+5, "", TUI.White);
    RETURN
  END;
  a := ArmyOf(uSide); u := a.units[uIdx];
  IF uSide = RED THEN fg := TUI.Red ELSE fg := TUI.Cyan END;

  COPY(unitName[u.utype], s); PutPanel(PANY, s, fg);

  IF uSide = RED THEN COPY("Red ", s) ELSE COPY("Blu ", s) END;
  IntStr(u.figures, n); AppendStr(s, n); AppendStr(s, "/10 figs  ");
  CASE u.facing OF NORTH: AppendStr(s, "N") | EAST: AppendStr(s, "E")
                 | SOUTH: AppendStr(s, "S") | WEST: AppendStr(s, "W") END;
  PutPanel(PANY+1, s, fg);

  COPY("mv:", s); IntStr(moveAllow[u.utype], n); AppendStr(s, n);
  PutPanel(PANY+2, s, TUI.White);

  IF u.utype = LF THEN COPY("sht:rng5", s)
  ELSE COPY("sht:none", s)
  END;
  PutPanel(PANY+3, s, TUI.White);

  COPY("m:", s); IntStr(meleeNum[u.utype][u.utype], n); AppendStr(s, n);
  AppendStr(s, "/"); IntStr(meleeMin[u.utype][u.utype], n); AppendStr(s, n);
  PutPanel(PANY+4, s, TUI.White);

  s[0] := 0X;
  IF u.charged THEN COPY("chg!", s) END;
  IF u.moraleChecked THEN
    IF s[0] # 0X THEN AppendStr(s, " ") END; AppendStr(s, "shaken")
  END;
  PutPanel(PANY+5, s, TUI.Yellow)
END DrawCursorInfo;

PROCEDURE DrawStatus;
VAR s: ARRAY 64 OF CHAR; n: ARRAY 8 OF CHAR;
BEGIN
  TUI.PutStr(1, 1, "CHAINMAIL — Medieval Miniatures (Gygax & Perren 1971)", TUI.Yellow, TUI.Black);
  IF activeSide = RED THEN COPY("[RED]  ", s) ELSE COPY("[BLUE] ", s) END;
  AppendStr(s, "Turn "); IntStr(turn, n); AppendStr(s, n);
  AppendStr(s, "/"); IntStr(TURNS, n); AppendStr(s, n); AppendStr(s, "  ");
  CASE phase OF
    PH_MOVE:   AppendStr(s, "Move Phase  ")
  | PH_SHOOT:  AppendStr(s, "Shoot Phase ")
  | PH_COMBAT: AppendStr(s, "Combat Phase")
  | PH_ELIM:   AppendStr(s, "Elim Phase  ")
  END;
  TUI.PutStr(1, 2, s, TUI.White, TUI.Black);

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
            "Magenta=archer  Enter=select  N=end shoot phase             ",
            TUI.White, TUI.Black)
        ELSE
          COPY("Shooter: ", s);
          AppendStr(s, unitName[red.units[selUnit].utype]);
          AppendStr(s, "  Green=target  Enter=shoot  Esc=cancel         ");
          TUI.PutStr(1, TUI.Rows - 1, s, TUI.Yellow, TUI.Black)
        END
    | PH_COMBAT:
        TUI.PutStr(1, TUI.Rows - 1,
          "Melee resolving... (press any key)                          ",
          TUI.White, TUI.Black)
    | PH_ELIM:
        TUI.PutStr(1, TUI.Rows - 1,
          "Press any key to continue to Blue turn.                     ",
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
  DrawStatus; DrawCursorInfo; DrawMap; DrawUnitList; DrawLog;
  TUI.Flush
END DrawScreen;

(* ═══════════════════════════════════════════════════════════════════════ *)
(*  Player Input                                                             *)
(* ═══════════════════════════════════════════════════════════════════════ *)

PROCEDURE HasShootTargets(side, idx: INTEGER): BOOLEAN;
VAR i: INTEGER; enemies: Army;
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

PROCEDURE HandleMovePhase(key: INTEGER);
VAR logMsg: ARRAY 64 OF CHAR;
    prevCol, prevRow, oSide, oIdx: INTEGER;
BEGIN
  IF    key = TUI.KUp    THEN IF curRow > 0 THEN DEC(curRow) END
  ELSIF key = TUI.KDown  THEN IF curRow < GRID_H - 1 THEN INC(curRow) END
  ELSIF key = TUI.KLeft  THEN IF curCol > 0 THEN DEC(curCol) END
  ELSIF key = TUI.KRight THEN IF curCol < GRID_W - 1 THEN INC(curCol) END
  ELSIF key = TUI.KEnter THEN
    IF selUnit < 0 THEN
      UnitAt(curCol, curRow, oSide, oIdx);
      IF (oSide = RED) & ~red.units[oIdx].moved THEN selUnit := oIdx END
    ELSE
      IF ~red.units[selUnit].moved & ValidMoveTarget(RED, selUnit, curCol, curRow) THEN
        IF undoTop < MAX_UNITS THEN
          undoIdx[undoTop]    := selUnit;
          undoCol[undoTop]    := red.units[selUnit].col;
          undoRow[undoTop]    := red.units[selUnit].row;
          undoFacing[undoTop] := red.units[selUnit].facing;
          undoMoved[undoTop]  := red.units[selUnit].moved;
          INC(undoTop)
        END;
        prevCol := red.units[selUnit].col; prevRow := red.units[selUnit].row;
        red.units[selUnit].facing := FaceToward(prevCol, prevRow, curCol, curRow);
        red.units[selUnit].col    := curCol;
        red.units[selUnit].row    := curRow;
        red.units[selUnit].moved  := TRUE;
        IF red.units[selUnit].utype >= LHT THEN
          red.units[selUnit].charged := TRUE  (* cavalry gets impetus flag *)
        END;
        COPY("Red ", logMsg);
        AppendStr(logMsg, unitName[red.units[selUnit].utype]);
        AppendStr(logMsg, " moves");
        AppendLog(logMsg);
        selUnit := -1
      END
    END
  ELSIF (key = ORD('f')) OR (key = ORD('F')) THEN
    IF selUnit >= 0 THEN
      IF undoTop < MAX_UNITS THEN
        undoIdx[undoTop]    := selUnit;
        undoCol[undoTop]    := red.units[selUnit].col;
        undoRow[undoTop]    := red.units[selUnit].row;
        undoFacing[undoTop] := red.units[selUnit].facing;
        undoMoved[undoTop]  := red.units[selUnit].moved;
        INC(undoTop)
      END;
      red.units[selUnit].facing := (red.units[selUnit].facing + 1) MOD 4;
      red.units[selUnit].moved  := TRUE
    END
  ELSIF (key = ORD('u')) OR (key = ORD('U')) THEN
    IF undoTop > 0 THEN
      DEC(undoTop);
      oIdx   := undoIdx[undoTop];
      curCol := undoCol[undoTop];
      curRow := undoRow[undoTop];
      red.units[oIdx].col     := undoCol[undoTop];
      red.units[oIdx].row     := undoRow[undoTop];
      red.units[oIdx].facing  := undoFacing[undoTop];
      red.units[oIdx].moved   := undoMoved[undoTop];
      red.units[oIdx].charged := FALSE;
      AppendLog("Undo move");
      selUnit := -1
    END
  ELSIF key = TUI.KEsc THEN
    selUnit := -1
  ELSIF (key = ORD('n')) OR (key = ORD('N')) THEN
    selUnit := -1   (* deselect so next N press ends the phase *)
  END
END HandleMovePhase;

PROCEDURE HandleShootPhase(key: INTEGER);
VAR oSide, oIdx: INTEGER; msg: ARRAY 64 OF CHAR;
    moraleMsg: ARRAY 64 OF CHAR;
BEGIN
  IF    key = TUI.KUp    THEN IF curRow > 0 THEN DEC(curRow) END
  ELSIF key = TUI.KDown  THEN IF curRow < GRID_H - 1 THEN INC(curRow) END
  ELSIF key = TUI.KLeft  THEN IF curCol > 0 THEN DEC(curCol) END
  ELSIF key = TUI.KRight THEN IF curCol < GRID_W - 1 THEN INC(curCol) END
  ELSIF key = TUI.KEnter THEN
    IF selUnit < 0 THEN
      UnitAt(curCol, curRow, oSide, oIdx);
      IF oSide = RED THEN
        IF red.units[oIdx].utype # LF THEN AppendLog("Only Light Foot can shoot.")
        ELSIF red.units[oIdx].shot   THEN AppendLog("Already shot this turn.")
        ELSIF red.units[oIdx].moved  THEN AppendLog("Moved this turn - no shooting.")
        ELSE
          selUnit := oIdx;
          IF ~HasShootTargets(RED, oIdx) THEN AppendLog("No targets in range/arc.") END
        END
      END
    ELSE
      UnitAt(curCol, curRow, oSide, oIdx);
      IF oSide = activeSide THEN
        selUnit := -1
      ELSIF oSide = BLUE THEN
        IF CanShootTarget(RED, selUnit, curCol, curRow) THEN
          ResolveShot(RED, selUnit, BLUE, oIdx, msg);
          AppendLog(msg);
          red.units[selUnit].shot := TRUE;
          CheckElimination;
          IF blue.units[oIdx].alive THEN
            IF ~CheckUnitMorale(BLUE, oIdx, moraleMsg) THEN AppendLog(moraleMsg) END
          END;
          selUnit := -1
        ELSE
          AppendLog("Target out of range or arc!")
        END
      END
    END
  ELSIF key = TUI.KEsc THEN selUnit := -1
  END
END HandleShootPhase;

(* ═══════════════════════════════════════════════════════════════════════ *)
(*  Phase Advancement                                                        *)
(* ═══════════════════════════════════════════════════════════════════════ *)

PROCEDURE ClearTurnFlags(side: INTEGER);
VAR a: Army; i: INTEGER;
BEGIN
  a := ArmyOf(side);
  FOR i := 0 TO a.count - 1 DO
    a.units[i].moved   := FALSE;
    a.units[i].shot    := FALSE;
    a.units[i].charged := FALSE
  END;
  SetArmy(side, a)
END ClearTurnFlags;

PROCEDURE AdvancePhase;
BEGIN
  selUnit := -1;
  CASE phase OF
    PH_MOVE:
      undoTop := 0;
      phase := PH_SHOOT
  | PH_SHOOT:
      phase := PH_COMBAT
  | PH_COMBAT:
      ResolveMeleeAll;
      phase := PH_ELIM;
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
(*  Setup                                                                    *)
(* ═══════════════════════════════════════════════════════════════════════ *)

PROCEDURE InitTerrain;
VAR r, c: INTEGER;
BEGIN
  FOR r := 0 TO GRID_H - 1 DO
    FOR c := 0 TO GRID_W - 1 DO terrain[r][c] := TERR_OPEN END
  END
END InitTerrain;

PROCEDURE InitScenario1;
VAR r, c: INTEGER;
BEGIN
  InitTerrain;
  FOR r := 1 TO 3 DO FOR c := 5 TO 8 DO terrain[r][c] := TERR_HILL END END;
  FOR r := 8 TO 10 DO FOR c := 5 TO 8 DO terrain[r][c] := TERR_HILL END END
END InitScenario1;

PROCEDURE InitScenario2;
VAR r, c: INTEGER;
BEGIN
  InitTerrain;
  FOR r := 1 TO 3 DO FOR c := 2 TO 5 DO terrain[r][c] := TERR_HILL END END;
  FOR r := 0 TO GRID_H - 1 DO terrain[r][CROSS_COL] := TERR_ROAD END;
  FOR c := 0 TO GRID_W - 1 DO terrain[CROSS_ROW][c] := TERR_ROAD END
END InitScenario2;

PROCEDURE InitScenario3;
VAR r, c: INTEGER;
BEGIN
  InitTerrain;
  FOR r := 1 TO 3 DO FOR c := 8 TO 10 DO terrain[r][c] := TERR_MARSH END END;
  FOR c := 0 TO GRID_W - 1 DO terrain[BRIDGE_ROW][c] := TERR_RIVER END;
  terrain[BRIDGE_ROW][BRIDGE1_COL] := TERR_BRIDGE;
  terrain[BRIDGE_ROW][BRIDGE2_COL] := TERR_BRIDGE;
  FOR r := 8 TO 10 DO FOR c := 1 TO 3 DO terrain[r][c] := TERR_HILL END END
END InitScenario3;

PROCEDURE InitScenarioRandom;
VAR r, c, i, n, cr, cc, size, dist, riverRow: INTEGER;
    hasRiver, hasRoad: BOOLEAN;
BEGIN
  InitTerrain;
  n := 1 + Random.Int(3);
  FOR i := 0 TO n - 1 DO
    cr := 2 + Random.Int(8); cc := Random.Int(GRID_W); size := 1 + Random.Int(3);
    FOR r := cr - size TO cr + size DO
      FOR c := cc - size TO cc + size DO
        IF (r >= 2) & (r <= GRID_H - 3) & (c >= 0) & (c < GRID_W) THEN
          dist := Abs(r - cr) + Abs(c - cc);
          IF (dist <= size) & (Random.Int(4) # 0) THEN terrain[r][c] := TERR_HILL END
        END
      END
    END
  END;
  n := Random.Int(3);
  FOR i := 0 TO n - 1 DO
    cr := 2 + Random.Int(8); cc := Random.Int(GRID_W); size := 1 + Random.Int(2);
    FOR r := cr - size TO cr + size DO
      FOR c := cc - size TO cc + size DO
        IF (r >= 2) & (r <= GRID_H - 3) & (c >= 0) & (c < GRID_W) THEN
          dist := Abs(r - cr) + Abs(c - cc);
          IF (dist <= size) & (Random.Int(3) # 0) THEN terrain[r][c] := TERR_WOOD END
        END
      END
    END
  END;
  hasRiver := Random.Int(3) = 0;
  riverRow := 4 + Random.Int(3);
  IF hasRiver THEN
    FOR c := 0 TO GRID_W - 1 DO terrain[riverRow][c] := TERR_RIVER END;
    c := 1 + Random.Int(4); terrain[riverRow][c] := TERR_BRIDGE;
    c := 7 + Random.Int(3); terrain[riverRow][c] := TERR_FORD
  END;
  hasRoad := Random.Int(2) = 0;
  IF hasRoad THEN
    c := 1 + Random.Int(GRID_W - 2);
    FOR r := 0 TO GRID_H - 1 DO
      IF terrain[r][c] = TERR_RIVER THEN terrain[r][c] := TERR_BRIDGE
      ELSE terrain[r][c] := TERR_ROAD
      END;
      IF (r > 0) & (r < GRID_H - 2) & (Random.Int(3) = 0) THEN
        IF (Random.Int(2) = 0) & (c > 1) THEN DEC(c)
        ELSIF c < GRID_W - 2 THEN INC(c)
        END
      END
    END
  END
END InitScenarioRandom;

PROCEDURE DeployArmy(VAR a: Army; side: INTEGER; roll: INTEGER);
VAR i, col, row, t: INTEGER; startRow: INTEGER;
BEGIN
  a.side  := side; a.count := MAX_UNITS;
  IF side = RED THEN startRow := 1 ELSE startRow := GRID_H - 2 END;
  FOR i := 0 TO MAX_UNITS - 1 DO
    a.units[i].utype         := compTable[roll][i];
    a.units[i].figures       := FIGS_START;
    col := 1 + i * 2; row := startRow;
    t := terrain[row][col];
    WHILE (t = TERR_MARSH) OR (t = TERR_RIVER) DO
      IF side = RED THEN DEC(row) ELSE INC(row) END;
      IF (row < 0) OR (row >= GRID_H) THEN row := startRow; t := TERR_OPEN
      ELSE t := terrain[row][col]
      END
    END;
    a.units[i].col          := col;
    a.units[i].row          := row;
    a.units[i].alive        := TRUE;
    a.units[i].moved        := FALSE;
    a.units[i].shot         := FALSE;
    a.units[i].charged      := FALSE;
    a.units[i].moraleChecked := FALSE;
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

PROCEDURE ChooseScenario;
VAR ev2: TUI.Event;
BEGIN
  TUI.ClearBack(TUI.White, TUI.Black);
  TUI.PutStr(2, 1, "CHAINMAIL — Choose Scenario", TUI.Yellow, TUI.Black);
  TUI.PutStr(2, 2, "─────────────────────────────────────────────────────", TUI.White, TUI.Black);
  TUI.PutCell(2, 4, '0', TUI.Cyan, TUI.Black);
  TUI.PutStr(4, 4, "Random terrain  (hills, woods, optional road/river)", TUI.White, TUI.Black);
  TUI.PutCell(2, 5, '1', TUI.Cyan, TUI.Black);
  TUI.PutStr(4, 5, "Pitched Battle  (two hill groups)", TUI.White, TUI.Black);
  TUI.PutCell(2, 6, '2', TUI.Cyan, TUI.Black);
  TUI.PutStr(4, 6, "Crossroads  (hold hill + road junction on turn 20)", TUI.White, TUI.Black);
  TUI.PutCell(2, 7, '3', TUI.Cyan, TUI.Black);
  TUI.PutStr(4, 7, "Control the River  (hold both bridges on turn 20)", TUI.White, TUI.Black);
  TUI.PutStr(2, 9, "Press 0-3:", TUI.White, TUI.Black);
  TUI.Flush;
  scenario := SCEN_RANDOM;
  LOOP
    TUI.WaitEvent(ev2);
    IF ev2.kind = TUI.EvKey THEN
      IF    ev2.key = ORD('0') THEN scenario := SCEN_RANDOM; EXIT
      ELSIF ev2.key = ORD('1') THEN scenario := SCEN_1;      EXIT
      ELSIF ev2.key = ORD('2') THEN scenario := SCEN_2;      EXIT
      ELSIF ev2.key = ORD('3') THEN scenario := SCEN_3;      EXIT
      ELSIF ev2.key = 17       THEN TUI.Done; HALT(0)
      END
    END
  END
END ChooseScenario;

PROCEDURE ShowRoll(side: INTEGER; roll: INTEGER);
VAR sx, sy, i: INTEGER; fg: INTEGER; a: Army; n: ARRAY 4 OF CHAR;
BEGIN
  sy := 0; sx := 2;
  IF side = BLUE THEN sy := 9 END;
  fg := TUI.Red; IF side = BLUE THEN fg := TUI.Cyan END;
  IF side = RED THEN TUI.PutStr(sx, sy, "Red army  (die: ", fg, TUI.Black)
  ELSE               TUI.PutStr(sx, sy, "Blue army (die: ", fg, TUI.Black)
  END;
  IntStr(roll + 1, n); TUI.PutStr(sx + 16, sy, n, TUI.White, TUI.Black);
  TUI.PutStr(sx + 17, sy, ")", TUI.White, TUI.Black);
  a := ArmyOf(side);
  FOR i := 0 TO MAX_UNITS - 1 DO
    TUI.PutStr(sx + 2, sy + 1 + i, unitName[a.units[i].utype], TUI.White, TUI.Black)
  END
END ShowRoll;

PROCEDURE SetupGame;
VAR rollR, rollB: INTEGER; ev2: TUI.Event;
BEGIN
  IF    scenario = SCEN_1 THEN InitScenario1
  ELSIF scenario = SCEN_2 THEN InitScenario2
  ELSIF scenario = SCEN_3 THEN InitScenario3
  ELSE  InitScenarioRandom
  END;

  rollR := Random.Int(6); rollB := Random.Int(6);
  WHILE rollR = rollB DO rollB := Random.Int(6) END;

  DeployArmy(red, RED, rollR);
  DeployArmy(blue, BLUE, rollB);

  TUI.ClearBack(TUI.White, TUI.Black);
  TUI.PutStr(2, 1, "Army Compositions", TUI.Yellow, TUI.Black);
  ShowRoll(RED, rollR); ShowRoll(BLUE, rollB);
  TUI.PutStr(2, 16, "Press any key to begin...", TUI.White, TUI.Black);
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
  IF    scenario = SCEN_2 THEN victoryType := VIC_HOLD
  ELSIF scenario = SCEN_3 THEN victoryType := VIC_BRIDGES
  ELSE                         victoryType := VIC_ELIM
  END;
  selUnit  := -1;
  undoTop  := 0;
  gameOver := FALSE;
  curCol   := 0; curRow := 5;
  AppendLog("Chainmail begins. Red moves first.")
END SetupGame;

(* ═══════════════════════════════════════════════════════════════════════ *)
(*  Main Game Loop                                                           *)
(* ═══════════════════════════════════════════════════════════════════════ *)

PROCEDURE RunGame;
VAR mc, mr: INTEGER;
BEGIN
  DrawScreen;
  LOOP
    TUI.WaitEvent(ev);
    IF ev.kind = TUI.EvResize THEN TUI.UpdateSize

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

      IF activeSide = RED THEN
        CASE phase OF
          PH_MOVE:
            IF ((ev.key = ORD('n')) OR (ev.key = ORD('N'))) & (selUnit < 0) THEN AdvancePhase
            ELSE HandleMovePhase(ev.key)
            END
        | PH_SHOOT:
            IF (ev.key = ORD('n')) OR (ev.key = ORD('N')) THEN AdvancePhase
            ELSE HandleShootPhase(ev.key)
            END
        | PH_COMBAT:
            AdvancePhase
        | PH_ELIM:
            AdvancePhase
        END
      END
    END;
    DrawScreen
  END
END RunGame;

(* ═══════════════════════════════════════════════════════════════════════ *)
(*  Entry Point                                                              *)
(* ═══════════════════════════════════════════════════════════════════════ *)

BEGIN
  InitTables;
  TUI.Init;
  TUI.UpdateSize;
  ChooseScenario;
  SetupGame;
  RunGame;
  TUI.Done
END Chainmail.
