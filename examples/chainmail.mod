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

  (* Fantasy supplement types *)
  FT_HERO   = 0;  FT_SHERO  = 1;  FT_WIZARD = 2;  FT_WRAITH = 3;
  FT_OGRE   = 4;  FT_BALROG = 5;  FT_GIANT  = 6;  FT_DRAGON = 7;
  NFTYPES   = 8;

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
    fantasy       : BOOLEAN;  (* TRUE if this is a fantasy creature *)
    ftype         : INTEGER;  (* FT_HERO..FT_DRAGON when fantasy=TRUE *)
    frozen        : BOOLEAN;  (* paralyzed by Wraith — cannot move next turn *)
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

  msgLog     : ARRAY 64 OF ARRAY 64 OF CHAR;
  logHead    : INTEGER;
  logScroll  : INTEGER;

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

  fantasyMode  : BOOLEAN;  (* game-wide: fantasy supplement enabled *)

  ftName       : ARRAY NFTYPES OF ARRAY 12 OF CHAR;
  ftGlyph      : ARRAY NFTYPES OF CHAR;
  ftFigsStart  : ARRAY NFTYPES OF INTEGER;
  ftMoveAllow  : ARRAY NFTYPES OF INTEGER;
  ftCanFly     : ARRAY NFTYPES OF BOOLEAN;
  ftAttMult    : ARRAY NFTYPES OF INTEGER;
  ftAttType    : ARRAY NFTYPES OF INTEGER;
  ftDefType    : ARRAY NFTYPES OF INTEGER;
  ftHasShoot   : ARRAY NFTYPES OF BOOLEAN;
  ftShootRange : ARRAY NFTYPES OF INTEGER;
  ftShootDice  : ARRAY NFTYPES OF INTEGER;
  ftShootMin   : ARRAY NFTYPES OF INTEGER;
  ftNoMorale   : ARRAY NFTYPES OF BOOLEAN;
  fct          : ARRAY NFTYPES OF ARRAY NFTYPES OF INTEGER;

(* ═══════════════════════════════════════════════════════════════════════ *)
(*  Table Initialisation                                                    *)
(* ═══════════════════════════════════════════════════════════════════════ *)

PROCEDURE SetFCT(a, h, sh, wz, wr, og, ba, gi, dr: INTEGER);
BEGIN
  fct[a][FT_HERO]   := h;  fct[a][FT_SHERO]  := sh; fct[a][FT_WIZARD] := wz;
  fct[a][FT_WRAITH] := wr; fct[a][FT_OGRE]   := og; fct[a][FT_BALROG] := ba;
  fct[a][FT_GIANT]  := gi; fct[a][FT_DRAGON] := dr
END SetFCT;

PROCEDURE InitFantasyTables;
BEGIN
  COPY("Hero",     ftName[FT_HERO]);   ftGlyph[FT_HERO]   := '@';
  COPY("SuperHero",ftName[FT_SHERO]);  ftGlyph[FT_SHERO]  := 'S';
  COPY("Wizard",   ftName[FT_WIZARD]); ftGlyph[FT_WIZARD] := 'W';
  COPY("Wraith",   ftName[FT_WRAITH]); ftGlyph[FT_WRAITH] := 'G';
  COPY("Ogre",     ftName[FT_OGRE]);   ftGlyph[FT_OGRE]   := 'O';
  COPY("Balrog",   ftName[FT_BALROG]); ftGlyph[FT_BALROG] := '!';
  COPY("Giant",    ftName[FT_GIANT]);  ftGlyph[FT_GIANT]  := 'J';
  COPY("Dragon",   ftName[FT_DRAGON]); ftGlyph[FT_DRAGON] := 'D';

  ftFigsStart[FT_HERO]  := 4;   ftMoveAllow[FT_HERO]  := 4;
  ftFigsStart[FT_SHERO] := 8;   ftMoveAllow[FT_SHERO] := 4;
  ftFigsStart[FT_WIZARD]:= 3;   ftMoveAllow[FT_WIZARD]:= 4;
  ftFigsStart[FT_WRAITH]:= 3;   ftMoveAllow[FT_WRAITH]:= 6;
  ftFigsStart[FT_OGRE]  := 6;   ftMoveAllow[FT_OGRE]  := 3;
  ftFigsStart[FT_BALROG]:= 10;  ftMoveAllow[FT_BALROG]:= 5;
  ftFigsStart[FT_GIANT] := 12;  ftMoveAllow[FT_GIANT] := 4;
  ftFigsStart[FT_DRAGON]:= 8;   ftMoveAllow[FT_DRAGON]:= 8;

  ftCanFly[FT_HERO]  := FALSE; ftCanFly[FT_SHERO] := FALSE;
  ftCanFly[FT_WIZARD]:= FALSE; ftCanFly[FT_WRAITH]:= TRUE;
  ftCanFly[FT_OGRE]  := FALSE; ftCanFly[FT_BALROG]:= TRUE;
  ftCanFly[FT_GIANT] := FALSE; ftCanFly[FT_DRAGON]:= TRUE;

  (* Effective attack class/multiplier for fantasy vs normal troops *)
  ftAttType[FT_HERO]  := HF;  ftAttMult[FT_HERO]  := 4;
  ftAttType[FT_SHERO] := HF;  ftAttMult[FT_SHERO] := 8;
  ftAttType[FT_WIZARD]:= AF;  ftAttMult[FT_WIZARD]:= 2;
  ftAttType[FT_WRAITH]:= MH;  ftAttMult[FT_WRAITH]:= 2;
  ftAttType[FT_OGRE]  := HF;  ftAttMult[FT_OGRE]  := 6;
  ftAttType[FT_BALROG]:= HH;  ftAttMult[FT_BALROG]:= 2;
  ftAttType[FT_GIANT] := HF;  ftAttMult[FT_GIANT] := 12;
  ftAttType[FT_DRAGON]:= HH;  ftAttMult[FT_DRAGON]:= 4;

  (* Effective defence class for normal troops attacking fantasy *)
  ftDefType[FT_HERO]  := HF;  ftDefType[FT_SHERO] := HH;
  ftDefType[FT_WIZARD]:= AF;  ftDefType[FT_WRAITH]:= HH;
  ftDefType[FT_OGRE]  := HF;  ftDefType[FT_BALROG]:= HH;
  ftDefType[FT_GIANT] := HF;  ftDefType[FT_DRAGON]:= HH;

  (* Ranged special abilities *)
  ftHasShoot[FT_HERO]  := FALSE; ftShootRange[FT_HERO]  := 0;
  ftHasShoot[FT_SHERO] := FALSE; ftShootRange[FT_SHERO] := 0;
  ftHasShoot[FT_WIZARD]:= TRUE;  ftShootRange[FT_WIZARD]:= 6;
  ftHasShoot[FT_WRAITH]:= FALSE; ftShootRange[FT_WRAITH]:= 0;
  ftHasShoot[FT_OGRE]  := FALSE; ftShootRange[FT_OGRE]  := 0;
  ftHasShoot[FT_BALROG]:= TRUE;  ftShootRange[FT_BALROG]:= 3;
  ftHasShoot[FT_GIANT] := TRUE;  ftShootRange[FT_GIANT] := 5;
  ftHasShoot[FT_DRAGON]:= TRUE;  ftShootRange[FT_DRAGON]:= 4;

  ftShootDice[FT_HERO]  := 0; ftShootMin[FT_HERO]  := 6;
  ftShootDice[FT_SHERO] := 0; ftShootMin[FT_SHERO] := 6;
  ftShootDice[FT_WIZARD]:= 4; ftShootMin[FT_WIZARD]:= 4;
  ftShootDice[FT_WRAITH]:= 0; ftShootMin[FT_WRAITH]:= 6;
  ftShootDice[FT_OGRE]  := 0; ftShootMin[FT_OGRE]  := 6;
  ftShootDice[FT_BALROG]:= 2; ftShootMin[FT_BALROG]:= 4;
  ftShootDice[FT_GIANT] := 3; ftShootMin[FT_GIANT] := 4;
  ftShootDice[FT_DRAGON]:= 3; ftShootMin[FT_DRAGON]:= 3;

  (* Morale immunity *)
  ftNoMorale[FT_HERO]  := TRUE;  ftNoMorale[FT_SHERO] := TRUE;
  ftNoMorale[FT_WIZARD]:= FALSE; ftNoMorale[FT_WRAITH]:= TRUE;
  ftNoMorale[FT_OGRE]  := FALSE; ftNoMorale[FT_BALROG]:= TRUE;
  ftNoMorale[FT_GIANT] := TRUE;  ftNoMorale[FT_DRAGON]:= FALSE;

  (*
   * Fantasy Combat Table [attacker][defender]: roll 2d6.
   * OVER = defender killed; EQUAL = defender falls back; UNDER = no effect.
   * Rows/cols: FT_HERO, FT_SHERO, FT_WIZARD, FT_WRAITH, FT_OGRE,
   *            FT_BALROG, FT_GIANT, FT_DRAGON.
   * Extracted from Appendix E (Chainmail 3rd ed.) columns for those 8 types.
   *)
  (*                 HERO  SHERO  WIZ  WRAITH  OGRE BALROG GIANT DRAGON *)
  SetFCT(FT_HERO,    7,    10,   11,   11,    9,   11,   11,   12);
  SetFCT(FT_SHERO,   5,     8,    9,    8,    5,    9,    9,   10);
  SetFCT(FT_WIZARD,  8,    10,   10,    5,    8,    7,   11,    9);
  SetFCT(FT_WRAITH,  8,    10,   12,    7,    9,   10,   12,   12);
  SetFCT(FT_OGRE,    8,    11,   11,   12,    7,   10,    9,   12);
  SetFCT(FT_BALROG,  4,     7,    8,   11,    6,    7,    8,   11);
  SetFCT(FT_GIANT,   6,     9,   10,   10,    6,    9,    9,    9);
  SetFCT(FT_DRAGON,  5,     8,   10,    7,    5,    6,    9,    8)
END InitFantasyTables;

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
 * Also calls InitFantasyTables.
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
  SetComp(5, HF, HF, AF, AF, MH, HH);   (* no archers: all heavy troops *)
  InitFantasyTables
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
  COPY(msg, msgLog[logHead MOD 64]);
  INC(logHead);
  logScroll := 0
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
    u: Unit; a: Army; canFly: BOOLEAN;
BEGIN
  a := ArmyOf(side); u := a.units[idx];
  IF u.frozen THEN RETURN FALSE END;
  ut := u.utype;
  IF u.fantasy THEN
    mv := ftMoveAllow[u.ftype]; canFly := ftCanFly[u.ftype]
  ELSE
    mv := moveAllow[ut]; canFly := FALSE
  END;
  srcCol := u.col; srcRow := u.row;

  IF ~u.fantasy &
     (terrain[srcRow][srcCol] = TERR_ROAD) &
     (terrain[dstRow][dstCol] = TERR_ROAD) &
     ((srcRow = dstRow) OR (srcCol = dstCol)) THEN INC(mv) END;

  IF (dstCol < 0) OR (dstCol >= GRID_W) OR (dstRow < 0) OR (dstRow >= GRID_H) THEN
    RETURN FALSE
  END;
  IF CDist(srcCol, srcRow, dstCol, dstRow) > mv THEN RETURN FALSE END;
  IF (dstCol = srcCol) & (dstRow = srcRow) THEN RETURN FALSE END;

  UnitAt(dstCol, dstRow, oSide, oIdx);
  IF oSide >= 0 THEN RETURN FALSE END;

  IF ~canFly THEN
    IF terrain[dstRow][dstCol] = TERR_MARSH THEN RETURN FALSE END;
    IF terrain[dstRow][dstCol] = TERR_RIVER THEN RETURN FALSE END;
    IF RiverBlocked(srcCol, srcRow, dstCol, dstRow, mv) THEN RETURN FALSE END;
    IF (terrain[dstRow][dstCol] = TERR_WOOD) & (ut >= LHT) THEN RETURN FALSE END
  END;

  RETURN TRUE
END ValidMoveTarget;

(* ═══════════════════════════════════════════════════════════════════════ *)
(*  Shooting Validity (Light Foot only, range 5, 45-deg arc)               *)
(* ═══════════════════════════════════════════════════════════════════════ *)

PROCEDURE CanShootTarget(side, idx, tCol, tRow: INTEGER): BOOLEAN;
VAR u: Unit; a: Army;
BEGIN
  a := ArmyOf(side); u := a.units[idx];
  IF u.fantasy THEN
    IF ~ftHasShoot[u.ftype] THEN RETURN FALSE END;
    IF u.shot THEN RETURN FALSE END;
    IF CDist(u.col, u.row, tCol, tRow) > ftShootRange[u.ftype] THEN RETURN FALSE END;
    RETURN TRUE
  END;
  IF u.utype # LF THEN RETURN FALSE END;
  IF u.shot THEN RETURN FALSE END;
  IF u.moved THEN RETURN FALSE END;
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
    nd, i, d, kills, roll, minScore, denType: INTEGER;
    numStr: ARRAY 8 OF CHAR;
    attLabel, defLabel: ARRAY 16 OF CHAR;
BEGIN
  aArmy := ArmyOf(attSide); att := aArmy.units[attIdx];
  dArmy := ArmyOf(defSide); def := dArmy.units[defIdx];

  IF attSide = RED THEN COPY("R.", attLabel) ELSE COPY("B.", attLabel) END;
  IF att.fantasy THEN AppendStr(attLabel, ftName[att.ftype])
  ELSE AppendStr(attLabel, unitName[att.utype]) END;
  IF defSide = RED THEN COPY("R.", defLabel) ELSE COPY("B.", defLabel) END;
  IF def.fantasy THEN AppendStr(defLabel, ftName[def.ftype])
  ELSE AppendStr(defLabel, unitName[def.utype]) END;

  IF att.fantasy & def.fantasy THEN
    (* FCT ranged: attacker rolls once, no reply *)
    roll := D6D6();
    COPY(attLabel, msg); AppendStr(msg, "->"); AppendStr(msg, defLabel);
    AppendStr(msg, ": 2d6="); IntStr(roll, numStr); AppendStr(msg, numStr);
    IF roll > fct[att.ftype][def.ftype] THEN
      ReduceFigures(defSide, defIdx, 999);
      AppendStr(msg, " KILL")
    ELSIF roll = fct[att.ftype][def.ftype] THEN
      RetreatUnit(defSide, defIdx, 1);
      AppendStr(msg, " fallback")
    ELSE
      AppendStr(msg, " miss")
    END;
    RETURN
  END;

  IF att.fantasy THEN
    (* Fantasy creature fires at normal troops *)
    nd := ftShootDice[att.ftype];
    kills := 0;
    FOR i := 1 TO nd DO
      d := D6(); IF d >= ftShootMin[att.ftype] THEN INC(kills) END
    END;
    ReduceFigures(defSide, defIdx, kills);
    COPY(attLabel, msg); AppendStr(msg, "->"); AppendStr(msg, defLabel);
    AppendStr(msg, ": "); IntStr(nd, numStr); AppendStr(msg, numStr);
    AppendStr(msg, "d6(>="); IntStr(ftShootMin[att.ftype], numStr); AppendStr(msg, numStr);
    AppendStr(msg, ")->"); IntStr(kills, numStr); AppendStr(msg, numStr);
    AppendStr(msg, " kill(s)");
    RETURN
  END;

  (* Normal archer fires *)
  IF def.fantasy THEN denType := ftDefType[def.ftype]
  ELSE denType := def.utype
  END;
  nd := att.figures DIV shotDen[denType];
  IF nd < 1 THEN nd := 1 END;
  IF (terrain[def.row][def.col] = TERR_WOOD) OR
     (terrain[def.row][def.col] = TERR_TOWN) THEN
    nd := nd DIV 2; IF nd < 1 THEN nd := 1 END
  END;
  minScore := shotMin[denType];

  kills := 0;
  FOR i := 1 TO nd DO
    d := D6(); IF d >= minScore THEN INC(kills) END
  END;
  ReduceFigures(defSide, defIdx, kills);

  COPY(attLabel, msg); AppendStr(msg, "->"); AppendStr(msg, defLabel);
  AppendStr(msg, ": "); IntStr(nd, numStr); AppendStr(msg, numStr);
  AppendStr(msg, "d6(>="); IntStr(minScore, numStr); AppendStr(msg, numStr);
  AppendStr(msg, ")->"); IntStr(kills, numStr); AppendStr(msg, numStr);
  AppendStr(msg, " kill(s)")
END ResolveShot;

(*
 * ResolveMelee: simultaneous casualties (Chainmail §Melees).
 * Fantasy vs fantasy: Fantasy Combat Table (2d6, over=kill, equal=fall back).
 * Fantasy vs normal: effective class/multiplier from ft* tables.
 * Flank/rear, cavalry impetus, hill defence apply to normal-unit sides only.
 *)
PROCEDURE ResolveMelee(attSide, attIdx, defSide, defIdx: INTEGER;
                       noCounter: BOOLEAN; VAR msg: ARRAY OF CHAR);
VAR att, def: Unit;
    aArmy, dArmy: Army;
    effAtype, effDtype, attFigs: INTEGER;
    nd, i, d, kills1, kills2, roll1, roll2: INTEGER;
    attND, attMin, defND, defMin: INTEGER;
    flanked, rearAtt, fb1, fb2: BOOLEAN;
    numStr: ARRAY 8 OF CHAR;
    attLabel, defLabel: ARRAY 16 OF CHAR;
BEGIN
  aArmy := ArmyOf(attSide); att := aArmy.units[attIdx];
  dArmy := ArmyOf(defSide); def := dArmy.units[defIdx];
  defND := 0; defMin := 0;
  IF attSide = RED THEN COPY("R.", attLabel) ELSE COPY("B.", attLabel) END;
  IF att.fantasy THEN AppendStr(attLabel, ftName[att.ftype])
  ELSE AppendStr(attLabel, unitName[att.utype]) END;
  IF defSide = RED THEN COPY("R.", defLabel) ELSE COPY("B.", defLabel) END;
  IF def.fantasy THEN AppendStr(defLabel, ftName[def.ftype])
  ELSE AppendStr(defLabel, unitName[def.utype]) END;

  rearAtt := FALSE; flanked := FALSE;
  fb1 := FALSE; fb2 := FALSE;

  (* ── Fantasy vs Fantasy: use FCT ── *)
  IF att.fantasy & def.fantasy THEN
    kills1 := 0; kills2 := 0;
    roll1 := D6D6();
    IF    roll1 > fct[att.ftype][def.ftype] THEN kills1 := 999
    ELSIF roll1 = fct[att.ftype][def.ftype] THEN fb1 := TRUE
    END;
    roll2 := 0;
    IF ~noCounter THEN
      roll2 := D6D6();
      IF    roll2 > fct[def.ftype][att.ftype] THEN kills2 := 999
      ELSIF roll2 = fct[def.ftype][att.ftype] THEN fb2 := TRUE
      END
    END;
    IF kills1 > 0 THEN ReduceFigures(defSide, defIdx, kills1) END;
    IF kills2 > 0 THEN ReduceFigures(attSide, attIdx, kills2) END;
    aArmy := ArmyOf(attSide); dArmy := ArmyOf(defSide);
    IF fb1 & dArmy.units[defIdx].alive THEN RetreatUnit(defSide, defIdx, 1) END;
    IF fb2 & aArmy.units[attIdx].alive THEN RetreatUnit(attSide, attIdx, 1) END;
    COPY(attLabel, msg); AppendStr(msg, "->"); AppendStr(msg, defLabel);
    AppendStr(msg, ": FCT "); IntStr(roll1, numStr); AppendStr(msg, numStr);
    AppendStr(msg, "/"); IntStr(roll2, numStr); AppendStr(msg, numStr);
    IF    kills1 > 0 THEN AppendStr(msg, " DEF KILLED")
    ELSIF fb1        THEN AppendStr(msg, " def back")
    END;
    RETURN
  END;

  (* ── Determine effective attacker type and figure count ── *)
  IF att.fantasy THEN
    effAtype := ftAttType[att.ftype];
    attFigs  := ftAttMult[att.ftype]
  ELSE
    rearAtt := IsRearAttack(att.col, att.row, def);
    flanked := ~rearAtt & IsFlankOrRear(att.col, att.row, def);
    effAtype := att.utype;
    IF (flanked OR rearAtt) & (effAtype < HH) THEN INC(effAtype) END;
    attFigs := att.figures
  END;

  (* ── Determine effective defender type ── *)
  IF def.fantasy THEN effDtype := ftDefType[def.ftype]
  ELSE effDtype := def.utype
  END;

  (* ── Attacker rolls ── *)
  nd := meleeNum[effAtype][effDtype] * attFigs DIV meleeDen[effAtype][effDtype];
  IF nd < 1 THEN nd := 1 END;
  IF ~att.fantasy & att.charged & (att.utype >= LHT) THEN INC(nd) END;
  IF ~att.fantasy & ~def.fantasy & (terrain[def.row][def.col] = TERR_HILL) THEN
    nd := nd DIV 2; IF nd < 1 THEN nd := 1 END
  END;
  attND := nd; attMin := meleeMin[effAtype][effDtype];
  kills1 := 0;
  FOR i := 1 TO nd DO
    d := D6(); IF d >= meleeMin[effAtype][effDtype] THEN INC(kills1) END
  END;

  (* ── Defender counter-attacks ── *)
  kills2 := 0;
  IF ~rearAtt & ~noCounter THEN
    IF def.fantasy & ~att.fantasy THEN
      (* Fantasy creature counter-attacks a normal attacker *)
      nd := meleeNum[ftAttType[def.ftype]][effAtype] * ftAttMult[def.ftype]
            DIV meleeDen[ftAttType[def.ftype]][effAtype];
      IF nd < 1 THEN nd := 1 END;
      defND := nd; defMin := meleeMin[ftAttType[def.ftype]][effAtype];
      FOR i := 1 TO nd DO
        d := D6();
        IF d >= meleeMin[ftAttType[def.ftype]][effAtype] THEN INC(kills2) END
      END
    ELSIF ~def.fantasy & att.fantasy THEN
      (* Normal unit counter-attacks a fantasy attacker, using ftDefType *)
      nd := meleeNum[def.utype][ftDefType[att.ftype]] * def.figures
            DIV meleeDen[def.utype][ftDefType[att.ftype]];
      IF nd < 1 THEN nd := 1 END;
      defND := nd; defMin := meleeMin[def.utype][ftDefType[att.ftype]];
      FOR i := 1 TO nd DO
        d := D6();
        IF d >= meleeMin[def.utype][ftDefType[att.ftype]] THEN INC(kills2) END
      END
    ELSE
      (* Both normal *)
      nd := meleeNum[effDtype][effAtype] * def.figures DIV meleeDen[effDtype][effAtype];
      IF nd < 1 THEN nd := 1 END;
      defND := nd; defMin := meleeMin[effDtype][effAtype];
      FOR i := 1 TO nd DO
        d := D6(); IF d >= meleeMin[effDtype][effAtype] THEN INC(kills2) END
      END
    END
  END;

  ReduceFigures(defSide, defIdx, kills1);
  ReduceFigures(attSide, attIdx, kills2);

  (* WRAITH: paralyze the normal enemy it touches *)
  IF att.fantasy & (att.ftype = FT_WRAITH) & ~def.fantasy THEN
    IF defSide = RED THEN red.units[defIdx].frozen := TRUE
    ELSE blue.units[defIdx].frozen := TRUE
    END;
    AppendStr(msg, "")  (* placeholder so compiler doesn't optimise away *)
  END;

  COPY(attLabel, msg); AppendStr(msg, "->"); AppendStr(msg, defLabel);
  AppendStr(msg, ": "); IntStr(attND, numStr); AppendStr(msg, numStr);
  AppendStr(msg, "d6(>="); IntStr(attMin, numStr); AppendStr(msg, numStr);
  AppendStr(msg, ")->"); IntStr(kills1, numStr); AppendStr(msg, numStr); AppendStr(msg, "k");
  IF ~noCounter & ~rearAtt THEN
    AppendStr(msg, "/"); IntStr(defND, numStr); AppendStr(msg, numStr);
    AppendStr(msg, "d6(>="); IntStr(defMin, numStr); AppendStr(msg, numStr);
    AppendStr(msg, ")->"); IntStr(kills2, numStr); AppendStr(msg, numStr); AppendStr(msg, "k")
  END;
  IF rearAtt THEN AppendStr(msg, " REAR!")
  ELSIF flanked THEN AppendStr(msg, " flank")
  END;
  IF att.fantasy & (att.ftype = FT_WRAITH) & ~def.fantasy THEN
    AppendStr(msg, " PARALYZE")
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
VAR a: Army; u: Unit; roll, needScore: INTEGER;
    numStr: ARRAY 8 OF CHAR;
BEGIN
  a := ArmyOf(side); u := a.units[idx];
  IF u.fantasy & ftNoMorale[u.ftype] THEN RETURN TRUE END;
  IF u.moraleChecked THEN RETURN TRUE END;
  IF u.fantasy THEN
    IF u.figures > ftFigsStart[u.ftype] DIV 2 THEN RETURN TRUE END
  ELSE
    IF u.figures > moraleThresh[u.utype] THEN RETURN TRUE END
  END;

  (* Mark as checked so we only roll once per threshold crossing *)
  a.units[idx].moraleChecked := TRUE;
  SetArmy(side, a);

  roll := D6D6();
  IF side = RED THEN COPY("R.", msg) ELSE COPY("B.", msg) END;
  IF u.fantasy THEN
    AppendStr(msg, ftName[u.ftype]); needScore := 7
  ELSE
    AppendStr(msg, unitName[u.utype]); needScore := moraleScore[u.utype]
  END;
  AppendStr(msg, " 2d6>="); IntStr(needScore, numStr); AppendStr(msg, numStr);
  AppendStr(msg, ": "); IntStr(roll, numStr); AppendStr(msg, numStr);

  IF roll >= needScore THEN
    AppendStr(msg, " stands");
    RETURN TRUE
  ELSE
    AppendStr(msg, " retreats!");
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
    cavLabel, defLabel: ARRAY 16 OF CHAR;
BEGIN
  a := ArmyOf(defSide); def := a.units[defIdx];
  IF def.utype >= LHT THEN RETURN TRUE END;  (* cavalry vs cavalry: no check *)
  cavClass := cavUtype - LHT;
  IF (cavClass < 0) OR (cavClass > 2) THEN RETURN TRUE END;

  IF (1 - defSide) = RED THEN COPY("R.", cavLabel) ELSE COPY("B.", cavLabel) END;
  AppendStr(cavLabel, unitName[cavUtype]);
  IF defSide = RED THEN COPY("R.", defLabel) ELSE COPY("B.", defLabel) END;
  AppendStr(defLabel, unitName[def.utype]);

  need := chargeTarget[def.utype][cavClass];
  roll := D6D6();

  COPY(cavLabel, msg); AppendStr(msg, "->"); AppendStr(msg, defLabel);
  AppendStr(msg, ": 2d6>="); IntStr(need, numStr); AppendStr(msg, numStr);
  AppendStr(msg, ": "); IntStr(roll, numStr); AppendStr(msg, numStr);
  IF roll >= need THEN
    AppendStr(msg, " stands");
    RETURN TRUE
  ELSE
    AppendStr(msg, " flees!");
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
    noCounter, canShoot: BOOLEAN;
BEGIN
  (* Move — frozen units skip movement (ValidMoveTarget returns FALSE for frozen) *)
  FOR i := 0 TO blue.count - 1 DO
    IF blue.units[i].alive & ~blue.units[i].moved THEN AIMoveUnit(i) END
  END;

  (* Shoot: LF archers and fantasy creatures with ranged ability *)
  FOR i := 0 TO blue.count - 1 DO
    IF blue.units[i].alive & ~blue.units[i].shot THEN
      IF blue.units[i].fantasy THEN
        canShoot := ftHasShoot[blue.units[i].ftype]
      ELSE
        canShoot := (blue.units[i].utype = LF) & ~blue.units[i].moved
      END;
      IF canShoot THEN
        AIFindShotTarget(i, tSide, tIdx);
        IF tIdx >= 0 THEN
          ResolveShot(BLUE, i, tSide, tIdx, msg);
          AppendLog(msg);
          blue.units[i].shot := TRUE;
          (* Morale check for target *)
          IF tSide = RED THEN
            IF red.units[tIdx].alive THEN
              IF ~CheckUnitMorale(RED, tIdx, moraleMsg) THEN AppendLog(moraleMsg) END
            END
          ELSE
            IF blue.units[tIdx].alive THEN
              IF ~CheckUnitMorale(BLUE, tIdx, moraleMsg) THEN AppendLog(moraleMsg) END
            END
          END
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
  IF (selUnit < 0) & (phase = PH_SHOOT) & (uSide = RED) & (uIdx >= 0) THEN
    IF red.units[uIdx].fantasy THEN
      isShootable := ftHasShoot[red.units[uIdx].ftype] & ~red.units[uIdx].shot
    ELSE
      isShootable := (red.units[uIdx].utype = LF) &
                     ~red.units[uIdx].shot & ~red.units[uIdx].moved
    END
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
    IF u.fantasy THEN c1 := ftGlyph[u.ftype] ELSE c1 := unitGlyph[u.utype] END
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
    IF u.fantasy THEN TUI.PutStr(sx, sy, ftName[u.ftype],   fg, TUI.Black)
    ELSE              TUI.PutStr(sx, sy, unitName[u.utype], fg, TUI.Black)
    END;
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
    IF u.fantasy THEN TUI.PutStr(sx, sy, ftName[u.ftype],   fg, TUI.Black)
    ELSE              TUI.PutStr(sx, sy, unitName[u.utype], fg, TUI.Black)
    END;
    IntStr(u.figures, num);
    TUI.PutStr(sx + 14, sy, num, fg, TUI.Black);
    IF ~u.alive THEN TUI.PutStr(sx + 17, sy, "X", TUI.Cyan, TUI.Black) END;
    INC(sy)
  END
END DrawUnitList;

PROCEDURE DrawLog;
VAR i, sy, nShow, base, avail: INTEGER;
    hdr: ARRAY 24 OF CHAR; n: ARRAY 8 OF CHAR;
BEGIN
  sy := MAPY + GRID_H + 2;
  nShow := TUI.Rows - sy - 1;
  IF nShow > 8 THEN nShow := 8 END;
  IF nShow < 1 THEN RETURN END;
  (* clamp scroll: can't scroll past stored history or show empty slots *)
  avail := logHead - nShow;
  IF avail < 0 THEN avail := 0 END;
  IF logScroll > avail THEN logScroll := avail END;
  IF logScroll < 0 THEN logScroll := 0 END;
  IF logScroll = 0 THEN
    COPY("--- Log (PgUp) ---", hdr)
  ELSE
    COPY("--- Log +", hdr);
    IntStr(logScroll, n); AppendStr(hdr, n); AppendStr(hdr, " (PgDn) ---")
  END;
  TUI.PutStr(1, sy - 1, hdr, TUI.Yellow, TUI.Black);
  base := logHead - logScroll;
  FOR i := 0 TO nShow - 1 DO
    TUI.PutStr(1, sy + i,
      msgLog[(base - nShow + i + 256) MOD 64], TUI.White, TUI.Black)
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

  IF u.fantasy THEN COPY(ftName[u.ftype], s) ELSE COPY(unitName[u.utype], s) END;
  PutPanel(PANY, s, fg);

  IF uSide = RED THEN COPY("Red ", s) ELSE COPY("Blu ", s) END;
  IntStr(u.figures, n); AppendStr(s, n); AppendStr(s, " hp  ");
  CASE u.facing OF NORTH: AppendStr(s, "N") | EAST: AppendStr(s, "E")
                 | SOUTH: AppendStr(s, "S") | WEST: AppendStr(s, "W") END;
  PutPanel(PANY+1, s, fg);

  IF u.fantasy THEN
    COPY("mv:", s); IntStr(ftMoveAllow[u.ftype], n); AppendStr(s, n);
    IF ftCanFly[u.ftype] THEN AppendStr(s, " fly") END
  ELSE
    COPY("mv:", s); IntStr(moveAllow[u.utype], n); AppendStr(s, n)
  END;
  PutPanel(PANY+2, s, TUI.White);

  IF u.fantasy THEN
    IF ftHasShoot[u.ftype] THEN
      COPY("sht:rng", s); IntStr(ftShootRange[u.ftype], n); AppendStr(s, n)
    ELSE COPY("sht:none", s)
    END
  ELSE
    IF u.utype = LF THEN COPY("sht:rng5", s) ELSE COPY("sht:none", s) END
  END;
  PutPanel(PANY+3, s, TUI.White);

  IF u.fantasy THEN
    COPY("FCT:", s); IntStr(fct[u.ftype][u.ftype], n); AppendStr(s, n)
  ELSE
    COPY("m:", s); IntStr(meleeNum[u.utype][u.utype], n); AppendStr(s, n);
    AppendStr(s, "/"); IntStr(meleeMin[u.utype][u.utype], n); AppendStr(s, n)
  END;
  PutPanel(PANY+4, s, TUI.White);

  s[0] := 0X;
  IF u.frozen THEN COPY("FROZEN", s)
  ELSE
    IF u.charged THEN COPY("chg!", s) END;
    IF u.moraleChecked THEN
      IF s[0] # 0X THEN AppendStr(s, " ") END; AppendStr(s, "shaken")
    END
  END;
  PutPanel(PANY+5, s, TUI.Yellow)
END DrawCursorInfo;

PROCEDURE DrawStatus;
VAR s: ARRAY 64 OF CHAR; n: ARRAY 8 OF CHAR;
BEGIN
  IF fantasyMode THEN
    TUI.PutStr(1, 1, "CHAINMAIL — Medieval + Fantasy (Gygax & Perren 1971) ", TUI.Yellow, TUI.Black)
  ELSE
    TUI.PutStr(1, 1, "CHAINMAIL — Medieval Miniatures (Gygax & Perren 1971)", TUI.Yellow, TUI.Black)
  END;
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
      IF (oSide = RED) & ~red.units[oIdx].moved & ~red.units[oIdx].frozen THEN
        selUnit := oIdx
      END
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
        IF red.units[oIdx].fantasy THEN
          IF ~ftHasShoot[red.units[oIdx].ftype] THEN
            AppendLog("This creature cannot shoot.")
          ELSIF red.units[oIdx].shot THEN
            AppendLog("Already shot this turn.")
          ELSE
            selUnit := oIdx;
            IF ~HasShootTargets(RED, oIdx) THEN AppendLog("No targets in range.") END
          END
        ELSIF red.units[oIdx].utype # LF THEN AppendLog("Only Light Foot can shoot.")
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
    a.units[i].charged := FALSE;
    a.units[i].frozen  := FALSE
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
VAR i, col, row, t, last, ft: INTEGER; startRow: INTEGER;
BEGIN
  a.side  := side; a.count := MAX_UNITS;
  IF side = RED THEN startRow := 1 ELSE startRow := GRID_H - 2 END;
  FOR i := 0 TO MAX_UNITS - 1 DO
    a.units[i].utype         := compTable[roll][i];
    a.units[i].figures       := FIGS_START;
    a.units[i].fantasy       := FALSE;
    a.units[i].ftype         := 0;
    a.units[i].frozen        := FALSE;
    col := 1 + i * 2; row := startRow;
    t := terrain[row][col];
    WHILE (t = TERR_MARSH) OR (t = TERR_RIVER) DO
      IF side = RED THEN DEC(row) ELSE INC(row) END;
      IF (row < 0) OR (row >= GRID_H) THEN row := startRow; t := TERR_OPEN
      ELSE t := terrain[row][col]
      END
    END;
    a.units[i].col           := col;
    a.units[i].row           := row;
    a.units[i].alive         := TRUE;
    a.units[i].moved         := FALSE;
    a.units[i].shot          := FALSE;
    a.units[i].charged       := FALSE;
    a.units[i].moraleChecked := FALSE;
    IF side = RED THEN a.units[i].facing := SOUTH
    ELSE               a.units[i].facing := NORTH
    END
  END;
  IF fantasyMode THEN
    (* Replace last unit with a random fantasy creature *)
    last := MAX_UNITS - 1;
    ft   := Random.Int(NFTYPES);
    a.units[last].utype         := 0;
    a.units[last].fantasy       := TRUE;
    a.units[last].ftype         := ft;
    a.units[last].figures       := ftFigsStart[ft];
    a.units[last].moraleChecked := FALSE
  END
END DeployArmy;

PROCEDURE ClearLog;
VAR i: INTEGER;
BEGIN
  logHead := 0;
  logScroll := 0;
  FOR i := 0 TO 63 DO msgLog[i][0] := 0X END
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
  END;

  (* Fantasy supplement option *)
  TUI.PutStr(2, 11, "─────────────────────────────────────────────────────", TUI.White, TUI.Black);
  TUI.PutStr(2, 12, "Fantasy Supplement (Appendix D/E)?", TUI.Magenta, TUI.Black);
  TUI.PutStr(2, 13, "Each army gains 1 fantasy creature:", TUI.White, TUI.Black);
  TUI.PutStr(4, 14, "Hero @ / SuperHero S / Wizard W / Wraith G",        TUI.White, TUI.Black);
  TUI.PutStr(4, 15, "Ogre O / Balrog ! / Giant J / Dragon D",             TUI.White, TUI.Black);
  TUI.PutStr(2, 16, "FCT combat, fly, breath weapons, paralyze.", TUI.White, TUI.Black);
  TUI.PutStr(2, 17, "Press Y / N:", TUI.White, TUI.Black);
  TUI.Flush;
  fantasyMode := FALSE;
  LOOP
    TUI.WaitEvent(ev2);
    IF ev2.kind = TUI.EvKey THEN
      IF    (ev2.key = ORD('y')) OR (ev2.key = ORD('Y')) THEN fantasyMode := TRUE;  EXIT
      ELSIF (ev2.key = ORD('n')) OR (ev2.key = ORD('N')) THEN fantasyMode := FALSE; EXIT
      ELSIF ev2.key = 17                                  THEN TUI.Done; HALT(0)
      END
    END
  END
END ChooseScenario;

PROCEDURE ShowRoll(side: INTEGER; roll: INTEGER);
VAR sx, sy, i: INTEGER; fg: INTEGER; a: Army; u: Unit; n: ARRAY 4 OF CHAR;
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
    u := a.units[i];
    IF u.fantasy THEN TUI.PutStr(sx + 2, sy + 1 + i, ftName[u.ftype],   TUI.Magenta, TUI.Black)
    ELSE              TUI.PutStr(sx + 2, sy + 1 + i, unitName[u.utype], TUI.White,   TUI.Black)
    END
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

      IF ev.key = TUI.KPgUp THEN INC(logScroll)
      ELSIF ev.key = TUI.KPgDn THEN
        DEC(logScroll); IF logScroll < 0 THEN logScroll := 0 END
      ELSIF activeSide = RED THEN
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
