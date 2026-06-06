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
 *   V           – toggle verbose AI (step through each Blue move)
 *   Q / Ctrl-Q  – quit
 *)

IMPORT TUI, Random;

CONST
  GRID_W = 12;  GRID_H = 12;
  MAX_UNITS = 6;
  TURNS = 20;

  RED = 0;  BLUE = 1;

  NORTH = 0;  EAST = 1;  SOUTH = 2;  WEST = 3;

  PH_MOVE = 0;  PH_SHOOT = 1;  PH_JOIN = 2;  PH_COMBAT = 3;  PH_ELIM = 4;

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
  FT_LYCAN  = 8;  FT_ROC    = 9;  FT_WIGHT  = 10; FT_ELEM   = 11;
  FT_ENT    = 12;
  NFTYPES   = 13;

  FIGS_START = 10;  (* figures per fresh unit *)

  (* Terrain *)
  TERR_OPEN   = 0;  TERR_HILL  = 1;  TERR_WOOD  = 2;
  TERR_TOWN   = 3;  TERR_MARSH = 4;  TERR_RIVER = 5;
  TERR_FORD   = 6;  TERR_BRIDGE = 7; TERR_ROAD  = 8;

  (* Victory *)
  VIC_ELIM    = 0;  VIC_HOLD  = 1;  VIC_BRIDGES = 2;

  (* Scenarios *)
  SCEN_RANDOM = 0;  SCEN_1 = 1;  SCEN_2 = 2;  SCEN_3 = 3;

  CMD_MOVE = 4;   (* commander movement allowance *)
  CMD_RANGE = 4;  (* radius for commander morale bonus *)

  CROSS_COL  = 10;  CROSS_ROW   = 9;
  BRIDGE_ROW =  6;  BRIDGE1_COL = 1;  BRIDGE2_COL = 9;

  MAPX = 3;   MAPY = 3;   SIDEX = 46;
  PANX = 29;  PANY = 4;   PANW = 16;

  POINT_BUDGET_SM = 24;   (* 12 pts — skirmish *)
  POINT_BUDGET_MD = 30;   (* 15 pts — standard *)
  POINT_BUDGET_LG = 40;   (* 20 pts — lords of war *)

TYPE
  CompArray = ARRAY MAX_UNITS OF INTEGER;  (* unit-type list for an army *)

  Unit = RECORD
    utype         : INTEGER;  (* LF..HH *)
    figures       : INTEGER;  (* current count, 0 = dead *)
    col, row      : INTEGER;
    facing        : INTEGER;
    alive         : BOOLEAN;
    moved         : BOOLEAN;
    shotsLeft     : INTEGER;  (* shots remaining this shoot phase; 0 = done *)
    charged       : BOOLEAN;  (* cavalry: moved this turn — impetus in melee *)
    moraleChecked : BOOLEAN;  (* TRUE once first threshold check done *)
    fantasy       : BOOLEAN;  (* TRUE if this is a fantasy creature *)
    ftype         : INTEGER;  (* FT_HERO..FT_DRAGON when fantasy=TRUE *)
    frozen        : BOOLEAN;  (* paralyzed by Wraith — cannot move next turn *)
    fatigued      : BOOLEAN;  (* sustained exertion — attacks as next lower class *)
    consMovs      : INTEGER;  (* consecutive turns moved *)
    meleeRounds   : INTEGER;  (* consecutive turns in melee *)
    inMelee       : BOOLEAN;  (* engaged in melee this turn *)
    wasAttacked   : BOOLEAN;  (* in melee last turn — first-turn auto-rally *)
    retreatTurns  : INTEGER;  (* 0=active; 1=1st retreat(auto if not attacked); 2=need 3+; 3=need 6; 4+=removed *)
    hasPikes      : BOOLEAN;  (* Swiss/Landsknecht: pike-charge morale + hedgehog eligible *)
    hedgehog      : BOOLEAN;  (* hedgehog formation: half speed, pike-only attackable *)
    isKnight      : BOOLEAN;  (* feudal knight: auto-charges when enemy in range *)
    isMercenary   : BOOLEAN;  (* obedience die each turn *)
    isReligious   : BOOLEAN;  (* +1 to all morale dice, never surrenders *)
    stationaryTurns: INTEGER; (* consecutive turns unmoved *)
  END;

  Army = RECORD
    units    : ARRAY MAX_UNITS OF Unit;
    count    : INTEGER;
    side     : INTEGER;
    cmdCol   : INTEGER;  (* army commander position *)
    cmdRow   : INTEGER;
    cmdAlive : BOOLEAN;
    cmdMoved : BOOLEAN;
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
  cmdSelected    : BOOLEAN;  (* TRUE when Red player has selected their commander *)

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
  moraleThresh  : ARRAY NTYPES OF INTEGER;  (* check when figures <= this *)
  moraleScore   : ARRAY NTYPES OF INTEGER;  (* 2d6 needed to stand *)
  moraleRating  : ARRAY NTYPES OF INTEGER;  (* post-melee morale rating *)

  (* Charge morale [defType][cavClass], cavClass = utype-LHT *)
  chargeTarget : ARRAY NTYPES OF ARRAY 3 OF INTEGER;

  (* Army composition [die 0..5][slot 0..5] *)
  compTable : ARRAY 6 OF ARRAY MAX_UNITS OF INTEGER;

  unitName  : ARRAY NTYPES OF ARRAY 14 OF CHAR;
  unitGlyph : ARRAY NTYPES OF CHAR;
  unitCost  : ARRAY NTYPES OF INTEGER;  (* cost in half-points; AF=5 means 2.5 pts *)
  unitDesc  : ARRAY NTYPES OF ARRAY 30 OF CHAR;

  pointBuyBudget : INTEGER;  (* 0 = random roll; else half-point budget *)

  fantasyMode  : BOOLEAN;  (* game-wide: fantasy supplement enabled *)
  verboseAI    : BOOLEAN;  (* step-through mode: redraw + wait for key after each Blue action *)

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
  ftNoMorale      : ARRAY NFTYPES OF BOOLEAN;
  ftMoraleRating  : ARRAY NFTYPES OF INTEGER;
  fct             : ARRAY NFTYPES OF ARRAY NFTYPES OF INTEGER;

(* ═══════════════════════════════════════════════════════════════════════ *)
(*  Table Initialisation                                                    *)
(* ═══════════════════════════════════════════════════════════════════════ *)

PROCEDURE SetFCT(a, h, sh, wz, wr, og, ba, gi, dr,
                 ly, rc, wi, el, en: INTEGER);
BEGIN
  fct[a][FT_HERO]  := h;  fct[a][FT_SHERO] := sh; fct[a][FT_WIZARD]:= wz;
  fct[a][FT_WRAITH]:= wr; fct[a][FT_OGRE]  := og; fct[a][FT_BALROG]:= ba;
  fct[a][FT_GIANT] := gi; fct[a][FT_DRAGON]:= dr;
  fct[a][FT_LYCAN] := ly; fct[a][FT_ROC]   := rc; fct[a][FT_WIGHT] := wi;
  fct[a][FT_ELEM]  := el; fct[a][FT_ENT]   := en
END SetFCT;

PROCEDURE InitFantasyTables;
BEGIN
  COPY("Hero",      ftName[FT_HERO]);   ftGlyph[FT_HERO]   := '@';
  COPY("SuperHero", ftName[FT_SHERO]);  ftGlyph[FT_SHERO]  := 'S';
  COPY("Wizard",    ftName[FT_WIZARD]); ftGlyph[FT_WIZARD] := 'W';
  COPY("Wraith",    ftName[FT_WRAITH]); ftGlyph[FT_WRAITH] := 'G';
  COPY("Ogre",      ftName[FT_OGRE]);   ftGlyph[FT_OGRE]   := 'O';
  COPY("Balrog",    ftName[FT_BALROG]); ftGlyph[FT_BALROG] := '!';
  COPY("Giant",     ftName[FT_GIANT]);  ftGlyph[FT_GIANT]  := 'J';
  COPY("Dragon",    ftName[FT_DRAGON]); ftGlyph[FT_DRAGON] := 'D';
  COPY("Lycanthrpe",ftName[FT_LYCAN]);  ftGlyph[FT_LYCAN]  := 'Y';
  COPY("Roc",       ftName[FT_ROC]);    ftGlyph[FT_ROC]    := 'R';
  COPY("Wight",     ftName[FT_WIGHT]);  ftGlyph[FT_WIGHT]  := 'V';
  COPY("Elemental", ftName[FT_ELEM]);   ftGlyph[FT_ELEM]   := 'E';
  COPY("Ent",       ftName[FT_ENT]);    ftGlyph[FT_ENT]    := 'N';

  ftFigsStart[FT_HERO]  := 4;  ftMoveAllow[FT_HERO]  := 4;
  ftFigsStart[FT_SHERO] := 8;  ftMoveAllow[FT_SHERO] := 4;
  ftFigsStart[FT_WIZARD]:= 3;  ftMoveAllow[FT_WIZARD]:= 4;
  ftFigsStart[FT_WRAITH]:= 3;  ftMoveAllow[FT_WRAITH]:= 6;
  ftFigsStart[FT_OGRE]  := 6;  ftMoveAllow[FT_OGRE]  := 3;
  ftFigsStart[FT_BALROG]:= 10; ftMoveAllow[FT_BALROG]:= 5;
  ftFigsStart[FT_GIANT] := 12; ftMoveAllow[FT_GIANT] := 4;
  ftFigsStart[FT_DRAGON]:= 8;  ftMoveAllow[FT_DRAGON]:= 6;
  ftFigsStart[FT_LYCAN] := 4;  ftMoveAllow[FT_LYCAN] := 3;
  ftFigsStart[FT_ROC]   := 4;  ftMoveAllow[FT_ROC]   := 6;
  ftFigsStart[FT_WIGHT] := 4;  ftMoveAllow[FT_WIGHT] := 3;
  ftFigsStart[FT_ELEM]  := 4;  ftMoveAllow[FT_ELEM]  := 3;
  ftFigsStart[FT_ENT]   := 6;  ftMoveAllow[FT_ENT]   := 2;

  ftCanFly[FT_HERO]  := FALSE; ftCanFly[FT_SHERO] := FALSE;
  ftCanFly[FT_WIZARD]:= FALSE; ftCanFly[FT_WRAITH]:= TRUE;
  ftCanFly[FT_OGRE]  := FALSE; ftCanFly[FT_BALROG]:= TRUE;
  ftCanFly[FT_GIANT] := FALSE; ftCanFly[FT_DRAGON]:= TRUE;
  ftCanFly[FT_LYCAN] := FALSE; ftCanFly[FT_ROC]   := TRUE;
  ftCanFly[FT_WIGHT] := FALSE; ftCanFly[FT_ELEM]  := FALSE;
  ftCanFly[FT_ENT]   := FALSE;

  (* Effective attack class/multiplier for fantasy vs normal troops *)
  ftAttType[FT_HERO]  := HF;  ftAttMult[FT_HERO]  := 4;
  ftAttType[FT_SHERO] := HF;  ftAttMult[FT_SHERO] := 8;
  ftAttType[FT_WIZARD]:= AF;  ftAttMult[FT_WIZARD]:= 2;
  ftAttType[FT_WRAITH]:= MH;  ftAttMult[FT_WRAITH]:= 2;
  ftAttType[FT_OGRE]  := HF;  ftAttMult[FT_OGRE]  := 6;
  ftAttType[FT_BALROG]:= HH;  ftAttMult[FT_BALROG]:= 2;
  ftAttType[FT_GIANT] := HF;  ftAttMult[FT_GIANT] := 12;
  ftAttType[FT_DRAGON]:= HH;  ftAttMult[FT_DRAGON]:= 4;
  ftAttType[FT_LYCAN] := AF;  ftAttMult[FT_LYCAN] := 4;
  ftAttType[FT_ROC]   := LHT; ftAttMult[FT_ROC]   := 4;
  ftAttType[FT_WIGHT] := LHT; ftAttMult[FT_WIGHT] := 1;
  ftAttType[FT_ELEM]  := HH;  ftAttMult[FT_ELEM]  := 4;
  ftAttType[FT_ENT]   := AF;  ftAttMult[FT_ENT]   := 6;

  (* Effective defence class for normal troops attacking fantasy *)
  ftDefType[FT_HERO]  := HF;  ftDefType[FT_SHERO] := HH;
  ftDefType[FT_WIZARD]:= AF;  ftDefType[FT_WRAITH]:= HH;
  ftDefType[FT_OGRE]  := HF;  ftDefType[FT_BALROG]:= HH;
  ftDefType[FT_GIANT] := HF;  ftDefType[FT_DRAGON]:= HH;
  ftDefType[FT_LYCAN] := HF;  ftDefType[FT_ROC]   := HH;
  ftDefType[FT_WIGHT] := HH;  ftDefType[FT_ELEM]  := HH;
  ftDefType[FT_ENT]   := HH;

  (* Ranged special abilities *)
  ftHasShoot[FT_HERO]  := FALSE; ftShootRange[FT_HERO]  := 0;
  ftHasShoot[FT_SHERO] := FALSE; ftShootRange[FT_SHERO] := 0;
  ftHasShoot[FT_WIZARD]:= TRUE;  ftShootRange[FT_WIZARD]:= 6;
  ftHasShoot[FT_WRAITH]:= FALSE; ftShootRange[FT_WRAITH]:= 0;
  ftHasShoot[FT_OGRE]  := FALSE; ftShootRange[FT_OGRE]  := 0;
  ftHasShoot[FT_BALROG]:= TRUE;  ftShootRange[FT_BALROG]:= 3;
  ftHasShoot[FT_GIANT] := TRUE;  ftShootRange[FT_GIANT] := 5;
  ftHasShoot[FT_DRAGON]:= TRUE;  ftShootRange[FT_DRAGON]:= 4;
  ftHasShoot[FT_LYCAN] := FALSE; ftShootRange[FT_LYCAN] := 0;
  ftHasShoot[FT_ROC]   := FALSE; ftShootRange[FT_ROC]   := 0;
  ftHasShoot[FT_WIGHT] := FALSE; ftShootRange[FT_WIGHT] := 0;
  ftHasShoot[FT_ELEM]  := FALSE; ftShootRange[FT_ELEM]  := 0;
  ftHasShoot[FT_ENT]   := FALSE; ftShootRange[FT_ENT]   := 0;

  ftShootDice[FT_HERO]  := 0; ftShootMin[FT_HERO]  := 6;
  ftShootDice[FT_SHERO] := 0; ftShootMin[FT_SHERO] := 6;
  ftShootDice[FT_WIZARD]:= 4; ftShootMin[FT_WIZARD]:= 4;
  ftShootDice[FT_WRAITH]:= 0; ftShootMin[FT_WRAITH]:= 6;
  ftShootDice[FT_OGRE]  := 0; ftShootMin[FT_OGRE]  := 6;
  ftShootDice[FT_BALROG]:= 2; ftShootMin[FT_BALROG]:= 4;
  ftShootDice[FT_GIANT] := 3; ftShootMin[FT_GIANT] := 4;
  ftShootDice[FT_DRAGON]:= 3; ftShootMin[FT_DRAGON]:= 3;
  ftShootDice[FT_LYCAN] := 0; ftShootMin[FT_LYCAN] := 6;
  ftShootDice[FT_ROC]   := 0; ftShootMin[FT_ROC]   := 6;
  ftShootDice[FT_WIGHT] := 0; ftShootMin[FT_WIGHT] := 6;
  ftShootDice[FT_ELEM]  := 0; ftShootMin[FT_ELEM]  := 6;
  ftShootDice[FT_ENT]   := 0; ftShootMin[FT_ENT]   := 6;

  (* Morale immunity (ftNoMorale=TRUE means never checks morale) *)
  ftNoMorale[FT_HERO]  := TRUE;  ftNoMorale[FT_SHERO] := TRUE;
  ftNoMorale[FT_WIZARD]:= FALSE; ftNoMorale[FT_WRAITH]:= TRUE;
  ftNoMorale[FT_OGRE]  := FALSE; ftNoMorale[FT_BALROG]:= TRUE;
  ftNoMorale[FT_GIANT] := TRUE;  ftNoMorale[FT_DRAGON]:= FALSE;
  ftNoMorale[FT_LYCAN] := FALSE; ftNoMorale[FT_ROC]   := TRUE;
  ftNoMorale[FT_WIGHT] := FALSE; ftNoMorale[FT_ELEM]  := TRUE;
  ftNoMorale[FT_ENT]   := FALSE;

  (* Post-melee morale ratings (from Appendix D rules text) *)
  ftMoraleRating[FT_HERO]  := 20; ftMoraleRating[FT_SHERO] := 40;
  ftMoraleRating[FT_WIZARD]:= 50; ftMoraleRating[FT_WRAITH]:= 10;
  ftMoraleRating[FT_OGRE]  :=  8; ftMoraleRating[FT_BALROG]:= 50;
  ftMoraleRating[FT_GIANT] := 40; ftMoraleRating[FT_DRAGON]:= 50;
  ftMoraleRating[FT_LYCAN] := 20; ftMoraleRating[FT_ROC]   := 40;
  ftMoraleRating[FT_WIGHT] := 10; ftMoraleRating[FT_ELEM]  := 40;
  ftMoraleRating[FT_ENT]   := 20;

  (*
   * Fantasy Combat Table [attacker][defender]: roll 2d6 >=.
   * OVER = defender killed; EQUAL = defender falls back; UNDER = no effect.
   * Full 13-type table from Appendix E (Chainmail 3rd ed.).
   * Col order: HERO SHERO WIZ WRAITH OGRE BALROG GIANT DRAGON LYCAN ROC WIGHT ELEM ENT
   *)
  SetFCT(FT_HERO,   7, 10, 11, 11,  9, 11, 11, 12,  8, 10,  6, 10, 12);
  SetFCT(FT_SHERO,  5,  8,  9,  8,  5,  9,  9, 10,  6,  8,  4,  8, 11);
  SetFCT(FT_WIZARD, 8, 10, 10,  5,  8,  7, 11,  9,  7,  9,  6,  6, 10);
  SetFCT(FT_WRAITH, 8, 10, 12,  7,  9, 10, 12, 12,  9, 10, 11,  7, 12);
  SetFCT(FT_OGRE,   8, 11, 11, 12,  7, 10,  9, 12,  8,  9, 10, 11, 10);
  SetFCT(FT_BALROG, 4,  7,  8, 11,  6,  7,  8, 11,  6,  1,  4, 11,  8);
  SetFCT(FT_GIANT,  6,  9, 10, 10,  6,  9,  9,  9,  5,  7,  4, 10,  7);
  SetFCT(FT_DRAGON, 5,  8, 10,  7,  5,  6,  9,  8,  4,  8,  2, 10,  6);
  SetFCT(FT_LYCAN,  7, 10, 10, 12,  8, 10, 10, 12,  9, 10,  6, 12, 12);
  SetFCT(FT_ROC,    5,  8, 10,  9,  6, 12, 10, 12,  6,  9,  5, 12,  9);
  SetFCT(FT_WIGHT,  9, 12, 10,  7,  9, 12, 11, 12,  8, 11,  8, 12, 12);
  SetFCT(FT_ELEM,   4,  7,  8, 10,  7, 10,  9, 10,  4,  7,  2, 11,  7);
  SetFCT(FT_ENT,    4,  7, 10, 10,  7, 12,  8, 12,  4, 11,  3, 12,  7)
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
  COPY("Lt.Foot",  unitName[LF]);  unitGlyph[LF]  := 'L';
  COPY("Hv.Foot",  unitName[HF]);  unitGlyph[HF]  := 'H';
  COPY("Arm.Foot", unitName[AF]);  unitGlyph[AF]  := 'A';
  COPY("Lt.Horse", unitName[LHT]); unitGlyph[LHT] := 'h';
  COPY("Md.Horse", unitName[MH]);  unitGlyph[MH]  := 'm';
  COPY("Hv.Horse", unitName[HH]);  unitGlyph[HH]  := 'K';

  (* Point costs in half-points (×2 to avoid fractions) *)
  unitCost[LF]  := 2;   (* 1 pt   *)
  unitCost[HF]  := 4;   (* 2 pts  *)
  unitCost[AF]  := 5;   (* 2½ pts *)
  unitCost[LHT] := 6;   (* 3 pts  *)
  unitCost[MH]  := 8;   (* 4 pts  *)
  unitCost[HH]  := 10;  (* 5 pts  *)

  COPY("Archers / levy, range 5",    unitDesc[LF]);
  COPY("Solid melee foot",           unitDesc[HF]);
  COPY("Armored foot / Mil. Orders", unitDesc[AF]);
  COPY("Fast cavalry",               unitDesc[LHT]);
  COPY("Balanced horse",             unitDesc[MH]);
  COPY("Knights (auto-charge)",      unitDesc[HH]);

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

  (* Post-melee morale ratings (§Post Melee Morale table) *)
  moraleRating[LF] := 4;  moraleRating[HF] := 5;
  moraleRating[AF] := 7;  moraleRating[LHT]:= 6;
  moraleRating[MH] := 8;  moraleRating[HH] := 9;

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
  IF logScroll > 0 THEN INC(logScroll) END  (* keep window on same messages when scrolled back *)
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
(*  Commander Helpers                                                        *)
(* ═══════════════════════════════════════════════════════════════════════ *)

(* TRUE if the side's commander is alive and in the same cell as (col,row) *)
PROCEDURE CmdCombatBonus(side, col, row: INTEGER): BOOLEAN;
VAR a: Army;
BEGIN
  a := ArmyOf(side);
  RETURN a.cmdAlive & (a.cmdCol = col) & (a.cmdRow = row)
END CmdCombatBonus;

(* +2 bonus to 2d6 morale roll when commander is within CMD_RANGE cells *)
PROCEDURE CmdMoraleBonus(side, col, row: INTEGER): INTEGER;
VAR a: Army;
BEGIN
  a := ArmyOf(side);
  IF a.cmdAlive & (CDist(a.cmdCol, a.cmdRow, col, row) <= CMD_RANGE) THEN RETURN 2 END;
  RETURN 0
END CmdMoraleBonus;

(* Valid destination for a commander move *)
PROCEDURE ValidCmdMove(side, dstCol, dstRow: INTEGER): BOOLEAN;
VAR a: Army;
BEGIN
  a := ArmyOf(side);
  IF ~a.cmdAlive THEN RETURN FALSE END;
  IF (dstCol < 0) OR (dstCol >= GRID_W) OR (dstRow < 0) OR (dstRow >= GRID_H) THEN RETURN FALSE END;
  IF CDist(a.cmdCol, a.cmdRow, dstCol, dstRow) > CMD_MOVE THEN RETURN FALSE END;
  IF (dstCol = a.cmdCol) & (dstRow = a.cmdRow) THEN RETURN FALSE END;
  (* Cannot enter a cell with an enemy unit or the enemy commander *)
  IF side = RED THEN
    IF OccupiedBy(dstCol, dstRow, BLUE) THEN RETURN FALSE END;
    RETURN ~(blue.cmdAlive & (blue.cmdCol = dstCol) & (blue.cmdRow = dstRow))
  ELSE
    IF OccupiedBy(dstCol, dstRow, RED) THEN RETURN FALSE END;
    RETURN ~(red.cmdAlive & (red.cmdCol = dstCol) & (red.cmdRow = dstRow))
  END
END ValidCmdMove;

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
  IF u.retreatTurns > 0 THEN RETURN FALSE END;  (* retreating units cannot move voluntarily *)
  ut := u.utype;
  IF u.fantasy THEN
    mv := ftMoveAllow[u.ftype]; canFly := ftCanFly[u.ftype]
  ELSE
    mv := moveAllow[ut]; canFly := FALSE
  END;
  IF u.hedgehog THEN mv := mv DIV 2; IF mv < 1 THEN mv := 1 END END;
  srcCol := u.col; srcRow := u.row;

  IF ~u.fantasy &
     (terrain[srcRow][srcCol] = TERR_ROAD) &
     (terrain[dstRow][dstCol] = TERR_ROAD) &
     ((srcRow = dstRow) OR (srcCol = dstCol)) THEN INC(mv) END;

  IF (dstCol < 0) OR (dstCol >= GRID_W) OR (dstRow < 0) OR (dstRow >= GRID_H) THEN
    RETURN FALSE
  END;
  (* Hill halves movement to enter (§Terrain Effects) *)
  IF ~canFly & (terrain[dstRow][dstCol] = TERR_HILL) THEN
    mv := mv DIV 2; IF mv < 1 THEN mv := 1 END
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
    IF u.shotsLeft <= 0 THEN RETURN FALSE END;
    IF CDist(u.col, u.row, tCol, tRow) > ftShootRange[u.ftype] THEN RETURN FALSE END;
    RETURN TRUE
  END;
  IF u.utype # LF THEN RETURN FALSE END;
  IF u.shotsLeft <= 0 THEN RETURN FALSE END;
  (* moved LF may fire once; stationary LF may fire twice — shotsLeft encodes the difference *)
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
    effAtype, effDtype, defAttType, attFigs: INTEGER;
    nd, i, d, kills1, kills2, roll1, roll2: INTEGER;
    attND, attMin, defND, defMin: INTEGER;
    flanked, rearAtt, fb1, fb2: BOOLEAN;
    numStr: ARRAY 8 OF CHAR;
    attLabel, defLabel: ARRAY 16 OF CHAR;
BEGIN
  aArmy := ArmyOf(attSide); att := aArmy.units[attIdx];
  dArmy := ArmyOf(defSide); def := dArmy.units[defIdx];
  defND := 0; defMin := 0;
  (* Mark both units as in melee this turn *)
  IF attSide = RED THEN red.units[attIdx].inMelee := TRUE
  ELSE blue.units[attIdx].inMelee := TRUE END;
  IF defSide = RED THEN red.units[defIdx].inMelee := TRUE
  ELSE blue.units[defIdx].inMelee := TRUE END;
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
    (* Fatigue: sustained exertion reduces attack effectiveness one class *)
    IF att.fatigued & (effAtype > LF) THEN DEC(effAtype) END;
    attFigs := att.figures
  END;

  (* ── Determine effective defender type ── *)
  IF def.fantasy THEN effDtype := ftDefType[def.ftype]
  ELSE effDtype := def.utype
  END;

  (* ── Attacker rolls ── *)
  nd := meleeNum[effAtype][effDtype] * attFigs DIV meleeDen[effAtype][effDtype];
  IF nd < 1 THEN nd := 1 END;
  (* Impetus bonus: HF/AF/all Horse get extra die when charging (§Melee Optionals) *)
  IF ~att.fantasy & att.charged & (att.utype >= HF) THEN INC(nd) END;
  IF ~att.fantasy & ~def.fantasy & (terrain[def.row][def.col] = TERR_HILL) THEN
    nd := nd DIV 2; IF nd < 1 THEN nd := 1 END
  END;
  attND := nd; attMin := meleeMin[effAtype][effDtype];
  (* Commander co-located: -1 to kill threshold (easier to kill) *)
  IF CmdCombatBonus(attSide, att.col, att.row) THEN
    DEC(attMin); IF attMin < 2 THEN attMin := 2 END
  END;
  kills1 := 0;
  FOR i := 1 TO nd DO
    d := D6(); IF d >= attMin THEN INC(kills1) END
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
      IF CmdCombatBonus(defSide, def.col, def.row) THEN
        DEC(defMin); IF defMin < 2 THEN defMin := 2 END
      END;
      FOR i := 1 TO nd DO
        d := D6(); IF d >= defMin THEN INC(kills2) END
      END
    ELSIF ~def.fantasy & att.fantasy THEN
      (* Normal unit counter-attacks a fantasy attacker, using ftDefType *)
      defAttType := def.utype;
      IF def.fatigued & (defAttType > LF) THEN DEC(defAttType) END;
      nd := meleeNum[defAttType][ftDefType[att.ftype]] * def.figures
            DIV meleeDen[defAttType][ftDefType[att.ftype]];
      IF nd < 1 THEN nd := 1 END;
      defND := nd; defMin := meleeMin[defAttType][ftDefType[att.ftype]];
      IF CmdCombatBonus(defSide, def.col, def.row) THEN
        DEC(defMin); IF defMin < 2 THEN defMin := 2 END
      END;
      FOR i := 1 TO nd DO
        d := D6(); IF d >= defMin THEN INC(kills2) END
      END
    ELSE
      (* Both normal *)
      (* Standing cavalry return blows at next lower class — first round only *)
      defAttType := effDtype;
      IF (def.utype >= LHT) & ~def.moved THEN
        IF defAttType > LHT THEN DEC(defAttType)
        ELSE defAttType := AF  (* LHT standing → AF *)
        END
      END;
      (* Fatigue: reduce defender's attack class one step *)
      IF def.fatigued & (defAttType > LF) THEN DEC(defAttType) END;
      nd := meleeNum[defAttType][effAtype] * def.figures DIV meleeDen[defAttType][effAtype];
      IF nd < 1 THEN nd := 1 END;
      defND := nd; defMin := meleeMin[defAttType][effAtype];
      IF CmdCombatBonus(defSide, def.col, def.row) THEN
        DEC(defMin); IF defMin < 2 THEN defMin := 2 END
      END;
      FOR i := 1 TO nd DO
        d := D6(); IF d >= defMin THEN INC(kills2) END
      END
    END
  END;

  ReduceFigures(defSide, defIdx, kills1);
  ReduceFigures(attSide, attIdx, kills2);

  (* WRAITH / WIGHT: paralyze the normal enemy touched *)
  IF att.fantasy & ~def.fantasy &
     ((att.ftype = FT_WRAITH) OR (att.ftype = FT_WIGHT)) THEN
    IF defSide = RED THEN red.units[defIdx].frozen := TRUE
    ELSE blue.units[defIdx].frozen := TRUE
    END
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
  IF att.fantasy & ~def.fantasy &
     ((att.ftype = FT_WRAITH) OR (att.ftype = FT_WIGHT)) THEN
    AppendStr(msg, " PARALYZE")
  END
END ResolveMelee;

(* ═══════════════════════════════════════════════════════════════════════ *)
(*  Morale                                                                   *)
(* ═══════════════════════════════════════════════════════════════════════ *)

(* Retreat unit toward own baseline (Red north, Blue south) *)
PROCEDURE RetreatUnit(side, idx, steps: INTEGER);
VAR nc, nr, prevNr, t: INTEGER;
    a: Army; i: INTEGER;
BEGIN
  a := ArmyOf(side);
  nc := a.units[idx].col;
  nr := a.units[idx].row;
  i := 0;
  WHILE i < steps DO
    INC(i);
    prevNr := nr;
    IF side = RED THEN
      IF nr > 0 THEN DEC(nr) END
    ELSE
      IF nr < GRID_H - 1 THEN INC(nr) END
    END;
    (* don't retreat into occupied or impassable cell; stop at last valid row *)
    t := terrain[nr][nc];
    IF (t = TERR_MARSH) OR (t = TERR_RIVER) OR
       OccupiedBy(nc, nr, RED) OR OccupiedBy(nc, nr, BLUE) THEN
      nr := prevNr;
      i := steps  (* stop *)
    END
  END;
  a := ArmyOf(side);
  a.units[idx].col := nc;
  a.units[idx].row := nr;
  IF a.units[idx].retreatTurns = 0 THEN a.units[idx].retreatTurns := 1 END;
  SetArmy(side, a)
END RetreatUnit;

(* Mass morale check for all units of a side when their commander is lost *)
PROCEDURE CommanderKilledCheck(side: INTEGER);
VAR a: Army; u: Unit; i, roll, needScore: INTEGER;
    msg: ARRAY 64 OF CHAR; numStr: ARRAY 8 OF CHAR;
BEGIN
  AppendLog("Commander lost! Mass morale (-2)!");
  a := ArmyOf(side);
  FOR i := 0 TO a.count - 1 DO
    IF a.units[i].alive THEN
      u := a.units[i];
      IF u.fantasy & ftNoMorale[u.ftype] THEN (* immune *)
      ELSE
        IF u.fantasy THEN needScore := 7
        ELSE needScore := moraleScore[u.utype]
        END;
        roll := D6D6() - 2;
        msg[0] := 0X;
        IF side = RED THEN COPY("R.", msg) ELSE COPY("B.", msg) END;
        IF u.fantasy THEN AppendStr(msg, ftName[u.ftype])
        ELSE AppendStr(msg, unitName[u.utype])
        END;
        AppendStr(msg, " cmd-2:");
        IntStr(roll, numStr); AppendStr(msg, numStr);
        IF roll >= needScore THEN AppendStr(msg, " stands")
        ELSE AppendStr(msg, " flees!"); RetreatUnit(side, i, 2)
        END;
        AppendLog(msg)
      END
    END
  END
END CommanderKilledCheck;

(*
 * Post-melee morale resolution (§Post Melee Morale, Chainmail).
 * kills1 = casualties inflicted ON the defender; kills2 = on the attacker.
 * Formula: winner gets killDiff×die + MR×survivors;
 *   side with more survivors adds the positive difference in counts;
 *   loser gets MR×survivors. Double totals if <20 per side.
 *)
PROCEDURE PostMeleeMorale(attSide, attIdx, defSide, defIdx,
                           kills1, kills2: INTEGER;
                           VAR msg: ARRAY OF CHAR);
VAR attSurv, defSurv: INTEGER;
    killDiff, survivDiff, die: INTEGER;
    winScore, loseScore, diff: INTEGER;
    loserSide, loserIdx: INTEGER;
    numStr: ARRAY 8 OF CHAR;
    attMR, defMR, prevRT: INTEGER;
    aArmy, dArmy: Army;
    attU, defU, loserU: Unit;
BEGIN
  msg[0] := 0X;
  IF kills1 = kills2 THEN RETURN END;
  aArmy := ArmyOf(attSide); attU := aArmy.units[attIdx];
  dArmy := ArmyOf(defSide); defU := dArmy.units[defIdx];
  attSurv := attU.figures;
  defSurv := defU.figures;
  IF (attSurv <= 0) OR (defSurv <= 0) THEN RETURN END;

  IF attU.fantasy THEN attMR := ftMoraleRating[attU.ftype]
  ELSE attMR := moraleRating[attU.utype]
  END;
  IF defU.fantasy THEN defMR := ftMoraleRating[defU.ftype]
  ELSE defMR := moraleRating[defU.utype]
  END;

  die := D6();
  IF kills1 > kills2 THEN
    loserSide := defSide; loserIdx := defIdx;
    killDiff  := kills1 - kills2;
    winScore  := killDiff * die + attMR * attSurv;
    loseScore := defMR * defSurv;
    survivDiff := attSurv - defSurv;
    IF survivDiff > 0 THEN winScore  := winScore  + survivDiff
    ELSIF survivDiff < 0 THEN loseScore := loseScore - survivDiff
    END
  ELSE
    loserSide := attSide; loserIdx := attIdx;
    killDiff  := kills2 - kills1;
    winScore  := killDiff * die + defMR * defSurv;
    loseScore := attMR * attSurv;
    survivDiff := defSurv - attSurv;
    IF survivDiff > 0 THEN winScore  := winScore  + survivDiff
    ELSIF survivDiff < 0 THEN loseScore := loseScore - survivDiff
    END
  END;

  (* Small melee (<20 survivors per side): double all totals *)
  IF (attSurv < 20) & (defSurv < 20) THEN
    diff := (winScore - loseScore) * 2
  ELSE
    diff := winScore - loseScore
  END;
  IF diff < 20 THEN RETURN END;

  IF loserSide = RED THEN COPY("R.", msg) ELSE COPY("B.", msg) END;
  aArmy := ArmyOf(loserSide); loserU := aArmy.units[loserIdx];
  IF loserU.fantasy THEN AppendStr(msg, ftName[loserU.ftype])
  ELSE AppendStr(msg, unitName[loserU.utype])
  END;
  AppendStr(msg, " pstMel(");
  IntStr(diff, numStr); AppendStr(msg, numStr); AppendStr(msg, "):");

  (*
   * Six-band reaction table (§Post Melee Morale):
   *   0-19   melee continues (already filtered above)
   *   20-39  back 2, good order  — move without disruption
   *   40-59  back 1, good order  — move without disruption
   *   60-79  retreat 1           — disrupted
   *   80-99  rout 2              — disrupted
   *   100+   surrender           — eliminated (religious: rout instead)
   *)
  IF loserSide = RED THEN prevRT := red.units[loserIdx].retreatTurns
  ELSE prevRT := blue.units[loserIdx].retreatTurns END;

  IF diff >= 100 THEN
    IF ~loserU.fantasy & loserU.isReligious THEN
      AppendStr(msg, "rout!(relig)");
      RetreatUnit(loserSide, loserIdx, 2)
    ELSE
      AppendStr(msg, "surr!");
      IF loserSide = RED THEN red.units[loserIdx].figures := 0
      ELSE blue.units[loserIdx].figures := 0
      END
    END
  ELSIF diff >= 80 THEN
    AppendStr(msg, "rout!");
    RetreatUnit(loserSide, loserIdx, 2)
  ELSIF diff >= 60 THEN
    AppendStr(msg, "retreat!");
    RetreatUnit(loserSide, loserIdx, 1)
  ELSIF diff >= 40 THEN
    AppendStr(msg, "back1(ord)");
    RetreatUnit(loserSide, loserIdx, 1);
    IF prevRT = 0 THEN  (* good order: undo the retreat flag *)
      IF loserSide = RED THEN red.units[loserIdx].retreatTurns := 0
      ELSE blue.units[loserIdx].retreatTurns := 0 END
    END
  ELSE  (* 20-39 *)
    AppendStr(msg, "back2(ord)");
    RetreatUnit(loserSide, loserIdx, 2);
    IF prevRT = 0 THEN
      IF loserSide = RED THEN red.units[loserIdx].retreatTurns := 0
      ELSE blue.units[loserIdx].retreatTurns := 0 END
    END
  END
END PostMeleeMorale;

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
  IF u.fatigued THEN DEC(roll) END;
  INC(roll, CmdMoraleBonus(side, u.col, u.row));
  IF ~u.fantasy & u.isReligious THEN INC(roll) END;
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
PROCEDURE CheckChargeMorale(defSide, defIdx, cavUtype, attCol, attRow: INTEGER;
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
  INC(roll, CmdMoraleBonus(defSide, def.col, def.row));  (* commander steadies the line *)
  (* Flank/rear charge: defender is harder pressed (§Cavalry Charge) *)
  IF IsRearAttack(attCol, attRow, def) THEN DEC(roll, 2)
  ELSIF IsFlankOrRear(attCol, attRow, def) THEN DEC(roll, 1)
  END;

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
  END;
  (* Commander capture: enemy unit occupies commander's cell *)
  IF red.cmdAlive THEN
    FOR i := 0 TO blue.count - 1 DO
      IF blue.units[i].alive &
         (blue.units[i].col = red.cmdCol) & (blue.units[i].row = red.cmdRow) THEN
        red.cmdAlive := FALSE;
        AppendLog("Red commander CAPTURED!");
        CommanderKilledCheck(RED)
      END
    END
  END;
  IF blue.cmdAlive THEN
    FOR i := 0 TO red.count - 1 DO
      IF red.units[i].alive &
         (red.units[i].col = blue.cmdCol) & (red.units[i].row = blue.cmdRow) THEN
        blue.cmdAlive := FALSE;
        AppendLog("Blue commander CAPTURED!");
        CommanderKilledCheck(BLUE)
      END
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

(* Set shotsLeft for each unit of a side at the start of the shoot phase.
   Stationary LF get 2 shots; moved LF get 1; fantasy shooters get 1. *)
PROCEDURE SetShotsForTurn(side: INTEGER);
VAR a: Army; i: INTEGER;
BEGIN
  a := ArmyOf(side);
  FOR i := 0 TO a.count - 1 DO
    IF ~a.units[i].alive THEN a.units[i].shotsLeft := 0
    ELSIF a.units[i].fantasy THEN
      IF ftHasShoot[a.units[i].ftype] THEN a.units[i].shotsLeft := 1
      ELSE a.units[i].shotsLeft := 0
      END
    ELSIF a.units[i].utype = LF THEN
      IF ~a.units[i].moved THEN a.units[i].shotsLeft := 2
      ELSE a.units[i].shotsLeft := 1
      END
    ELSE a.units[i].shotsLeft := 0
    END
  END;
  SetArmy(side, a)
END SetShotsForTurn;

(* Rally check at the start of each side's move phase.
   retreatTurns=1 and not attacked last turn: auto-rally.
   retreatTurns=2: need d6 >= 3. retreatTurns=3: need d6 >= 6.
   retreatTurns >= 4: remove from play. *)
PROCEDURE CheckRally(side: INTEGER);
VAR i, roll, needScore: INTEGER;
    msg: ARRAY 64 OF CHAR; numStr: ARRAY 8 OF CHAR;
    a: Army;
BEGIN
  FOR i := 0 TO MAX_UNITS - 1 DO
    a := ArmyOf(side);
    IF (i < a.count) & a.units[i].alive & (a.units[i].retreatTurns > 0) THEN
      msg[0] := 0X;
      IF side = RED THEN COPY("R.", msg) ELSE COPY("B.", msg) END;
      IF a.units[i].fantasy THEN AppendStr(msg, ftName[a.units[i].ftype])
      ELSE AppendStr(msg, unitName[a.units[i].utype]) END;

      IF a.units[i].retreatTurns >= 4 THEN
        a.units[i].alive := FALSE;
        SetArmy(side, a);
        AppendStr(msg, " fled!"); AppendLog(msg)
      ELSIF (a.units[i].retreatTurns = 1) & ~a.units[i].wasAttacked THEN
        a.units[i].retreatTurns := 0;
        SetArmy(side, a);
        AppendStr(msg, " auto-rallies."); AppendLog(msg)
      ELSE
        IF a.units[i].retreatTurns <= 2 THEN needScore := 3 ELSE needScore := 6 END;
        roll := D6();
        AppendStr(msg, " rally>="); IntStr(needScore, numStr); AppendStr(msg, numStr);
        AppendStr(msg, ":"); IntStr(roll, numStr); AppendStr(msg, numStr);
        IF roll >= needScore THEN
          a.units[i].retreatTurns := 0;
          SetArmy(side, a);
          AppendStr(msg, " ok!"); AppendLog(msg)
        ELSE
          INC(a.units[i].retreatTurns);
          SetArmy(side, a);
          AppendStr(msg, " routing!"); AppendLog(msg);
          RetreatUnit(side, i, 1)
        END
      END
    END
  END
END CheckRally;

(* Pike charge morale: Swiss/Landsknecht charging forces defending unit to check
   morale using the Loss Table thresholds. Returns FALSE if defender flees. *)
PROCEDURE CheckPikeChargeMorale(defSide, defIdx: INTEGER;
                                 VAR msg: ARRAY OF CHAR): BOOLEAN;
VAR a: Army; def: Unit; roll, needScore: INTEGER;
    numStr: ARRAY 8 OF CHAR;
BEGIN
  a := ArmyOf(defSide); def := a.units[defIdx];
  IF def.fantasy & ftNoMorale[def.ftype] THEN RETURN TRUE END;
  IF def.hasPikes THEN RETURN TRUE END;  (* pike vs pike: auto-stand *)
  IF def.fantasy THEN needScore := 7
  ELSE needScore := moraleScore[def.utype]
  END;
  roll := D6D6();
  INC(roll, CmdMoraleBonus(defSide, def.col, def.row));
  IF ~def.fantasy & def.isReligious THEN INC(roll) END;
  IF defSide = RED THEN COPY("R.", msg) ELSE COPY("B.", msg) END;
  IF def.fantasy THEN AppendStr(msg, ftName[def.ftype])
  ELSE AppendStr(msg, unitName[def.utype]) END;
  AppendStr(msg, " pike-chg>="); IntStr(needScore, numStr); AppendStr(msg, numStr);
  AppendStr(msg, ":"); IntStr(roll, numStr); AppendStr(msg, numStr);
  IF roll >= needScore THEN
    AppendStr(msg, " stands"); RETURN TRUE
  ELSE
    AppendStr(msg, " flees!"); RetreatUnit(defSide, defIdx, 2); RETURN FALSE
  END
END CheckPikeChargeMorale;

(* ═══════════════════════════════════════════════════════════════════════ *)
(*  Combat Phase — all adjacent pairs fight simultaneously                  *)
(* ═══════════════════════════════════════════════════════════════════════ *)

PROCEDURE ResolveMeleeAll;
VAR i, j, k: INTEGER;
    att, def: Unit;
    msg: ARRAY 64 OF CHAR;
    moraleMsg: ARRAY 64 OF CHAR;
    noCounter, skip: BOOLEAN;
    prevAttFigs, prevDefFigs, kills1pm, kills2pm: INTEGER;
    (* join-melee: count additional supporting figures within 2 cells *)
    redSupport, blueSupport: INTEGER;
BEGIN
  FOR i := 0 TO red.count - 1 DO
    IF red.units[i].alive THEN
      att := red.units[i];
      FOR j := 0 TO blue.count - 1 DO
        IF blue.units[j].alive &
           (CDist(att.col, att.row, blue.units[j].col, blue.units[j].row) = 1) THEN
          def := blue.units[j];
          noCounter := FALSE;
          skip := FALSE;

          (* Hedgehog: only pike units can attack *)
          IF def.hedgehog & ~att.hasPikes & ~att.fantasy THEN
            AppendLog("Hedgehog holds — non-pike repelled!");
            skip := TRUE
          END;

          IF ~skip THEN
            (* Pike charge morale: forces defender check before melee *)
            IF ~att.fantasy & att.hasPikes & att.charged THEN
              IF ~CheckPikeChargeMorale(BLUE, j, msg) THEN
                AppendLog(msg); noCounter := TRUE
              ELSE AppendLog(msg)
              END
            END;

            (* Cavalry charge morale for Blue defender *)
            IF ~noCounter & att.charged & ~att.fantasy & (att.utype >= LHT) & ~def.fantasy & (def.utype < LHT) THEN
              IF ~CheckChargeMorale(BLUE, j, att.utype, att.col, att.row, msg) THEN
                AppendLog(msg); noCounter := TRUE
              ELSE AppendLog(msg)
              END
            END;

            (* Join-melee: tally supporting figures within 2 cells not already fighting *)
            redSupport := 0; blueSupport := 0;
            FOR k := 0 TO red.count - 1 DO
              IF (k # i) & red.units[k].alive & ~red.units[k].inMelee &
                 (CDist(red.units[k].col, red.units[k].row, blue.units[j].col, blue.units[j].row) <= 2) THEN
                INC(redSupport, red.units[k].figures DIV 2)
              END
            END;
            FOR k := 0 TO blue.count - 1 DO
              IF (k # j) & blue.units[k].alive & ~blue.units[k].inMelee &
                 (CDist(blue.units[k].col, blue.units[k].row, att.col, att.row) <= 2) THEN
                INC(blueSupport, blue.units[k].figures DIV 2)
              END
            END;
            IF (redSupport > 0) OR (blueSupport > 0) THEN
              COPY("join R:", msg);
              IntStr(redSupport, moraleMsg); AppendStr(msg, moraleMsg);
              AppendStr(msg, " B:"); IntStr(blueSupport, moraleMsg); AppendStr(msg, moraleMsg);
              AppendLog(msg)
            END;
            (* Temporarily boost attacker figure count with supporters for this melee *)
            red.units[i].figures := red.units[i].figures + redSupport;
            blue.units[j].figures := blue.units[j].figures + blueSupport;

            prevAttFigs := red.units[i].figures - redSupport;
            prevDefFigs := blue.units[j].figures - blueSupport;
            ResolveMelee(RED, i, BLUE, j, noCounter, msg);
            AppendLog(msg);

            (* Restore base figures; support figures don't take casualties *)
            red.units[i].figures := red.units[i].figures - redSupport;
            IF red.units[i].figures < 0 THEN red.units[i].figures := 0 END;
            blue.units[j].figures := blue.units[j].figures - blueSupport;
            IF blue.units[j].figures < 0 THEN blue.units[j].figures := 0 END;

            kills1pm := prevDefFigs - blue.units[j].figures;
            kills2pm := prevAttFigs - red.units[i].figures;

            IF red.units[i].alive & blue.units[j].alive THEN
              PostMeleeMorale(RED, i, BLUE, j, kills1pm, kills2pm, moraleMsg);
              IF moraleMsg[0] # 0X THEN AppendLog(moraleMsg) END
            END;

            IF blue.units[j].alive THEN
              IF ~CheckUnitMorale(BLUE, j, moraleMsg) THEN AppendLog(moraleMsg) END
            END;
            IF red.units[i].alive THEN
              IF ~CheckUnitMorale(RED, i, moraleMsg) THEN AppendLog(moraleMsg) END
            END
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
VAR i, score, bestScore, nd, denType: INTEGER;
    att: Unit;
BEGIN
  tSide := -1; tIdx := -1; bestScore := 9999;
  att := blue.units[bIdx];
  FOR i := 0 TO red.count - 1 DO
    IF red.units[i].alive &
       CanShootTarget(BLUE, bIdx, red.units[i].col, red.units[i].row) THEN
      IF att.fantasy THEN nd := ftShootDice[att.ftype]
      ELSE
        IF red.units[i].fantasy THEN denType := ftDefType[red.units[i].ftype]
        ELSE denType := red.units[i].utype
        END;
        nd := att.figures DIV shotDen[denType];
        IF nd < 1 THEN nd := 1 END
      END;
      (* score = figures remaining after expected volley; lowest = closest to elimination *)
      score := red.units[i].figures - nd;
      IF score < bestScore THEN
        bestScore := score; tSide := RED; tIdx := i
      END
    END
  END
END AIFindShotTarget;

PROCEDURE AIMoveUnit(bIdx: INTEGER);
VAR tCol, tRow, bestCol, bestRow, bestDist, dc, dr, nc, nr, newDist: INTEGER;
    ut, mv: INTEGER;
    msg: ARRAY 64 OF CHAR;
BEGIN
  IF blue.units[bIdx].retreatTurns > 0 THEN RETURN END;  (* retreating: no voluntary move *)
  ut := blue.units[bIdx].utype;
  IF blue.units[bIdx].fantasy THEN mv := ftMoveAllow[blue.units[bIdx].ftype]
  ELSE mv := moveAllow[ut]
  END;

  (* Self-preservation: fall back when down to 2 or fewer figures *)
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
      blue.units[bIdx].facing := FaceToward(blue.units[bIdx].col, blue.units[bIdx].row,
                                             bestCol, bestRow);
      blue.units[bIdx].col   := bestCol;
      blue.units[bIdx].row   := bestRow;
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
    IF blue.units[bIdx].utype >= HF THEN blue.units[bIdx].charged := TRUE END
  END
END AIMoveUnit;

PROCEDURE AIMoveCmd;
VAR i, weakFigs, tCol, tRow, dc, dr, nc, nr, bestCol, bestRow, bestDist, newDist: INTEGER;
BEGIN
  IF ~blue.cmdAlive OR blue.cmdMoved THEN RETURN END;
  (* Move toward the weakest (most battered) Blue unit to provide cover *)
  weakFigs := 9999; tCol := -1; tRow := -1;
  FOR i := 0 TO blue.count - 1 DO
    IF blue.units[i].alive & (blue.units[i].figures < weakFigs) THEN
      weakFigs := blue.units[i].figures;
      tCol     := blue.units[i].col;
      tRow     := blue.units[i].row
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

(* ═══════════════════════════════════════════════════════════════════════ *)
(*  Display                                                                 *)
(* ═══════════════════════════════════════════════════════════════════════ *)

PROCEDURE DrawCell(col, row: INTEGER);
VAR sx, sy, uSide, uIdx: INTEGER;
    u: Unit; tmpArmy: Army;
    fg, bg: INTEGER;
    c0, c1: CHAR;
    isCursor, isSelected, isValidMove, isShootable, isTargetable: BOOLEAN;
    isValidCmdMove, isCmdSelected: BOOLEAN;
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
      isShootable := ftHasShoot[red.units[uIdx].ftype] & (red.units[uIdx].shotsLeft > 0)
    ELSE
      isShootable := (red.units[uIdx].utype = LF) & (red.units[uIdx].shotsLeft > 0)
    END
  END;

  isTargetable := FALSE;
  IF (selUnit >= 0) & (phase = PH_SHOOT) & (uSide = BLUE) THEN
    isTargetable := CanShootTarget(activeSide, selUnit, col, row)
  END;

  isCmdSelected  := cmdSelected & red.cmdAlive & (red.cmdCol = col) & (red.cmdRow = row);
  isValidCmdMove := FALSE;
  IF cmdSelected & (phase = PH_MOVE) & ~isCmdSelected THEN
    isValidCmdMove := ValidCmdMove(RED, col, row)
  END;

  IF isCursor THEN              bg := TUI.Cyan;    fg := TUI.Black
  ELSIF isSelected OR isCmdSelected THEN bg := TUI.Yellow; fg := TUI.Black
  ELSIF isValidMove OR isTargetable OR isValidCmdMove THEN bg := TUI.Green; fg := TUI.Black
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
      (* '*' prefix when Red commander shares this cell *)
      IF red.cmdAlive & (red.cmdCol = col) & (red.cmdRow = row) THEN c0 := '*'
      ELSE c0 := 'R' END
    ELSE
      IF ~isCursor & ~isTargetable THEN fg := TUI.Cyan ELSE fg := TUI.Black END;
      (* '*' prefix when Blue commander shares this cell *)
      IF blue.cmdAlive & (blue.cmdCol = col) & (blue.cmdRow = row) THEN c0 := '*'
      ELSE c0 := 'B' END
    END;
    IF u.fantasy THEN c1 := ftGlyph[u.ftype] ELSE c1 := unitGlyph[u.utype] END
  ELSIF red.cmdAlive & (red.cmdCol = col) & (red.cmdRow = row) THEN
    (* Red commander alone on this cell *)
    IF ~isCursor & ~isCmdSelected THEN fg := TUI.Red ELSE fg := TUI.Black END;
    c0 := 'R'; c1 := 'C'
  ELSIF blue.cmdAlive & (blue.cmdCol = col) & (blue.cmdRow = row) THEN
    (* Blue commander alone on this cell *)
    IF ~isCursor THEN fg := TUI.Cyan ELSE fg := TUI.Black END;
    c0 := 'B'; c1 := 'C'
  ELSE
    IF isCursor OR isValidMove OR isValidCmdMove THEN fg := TUI.Black ELSE fg := TUI.White END;
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
  TUI.PutCell(MAPX - 2, MAPY - 1, ' ', TUI.Black, TUI.Black);
  TUI.PutCell(MAPX - 1, MAPY - 1, ' ', TUI.Black, TUI.Black);
  FOR c := 0 TO GRID_W - 1 DO
    IF c < 10 THEN label := CHR(ORD('0') + c) ELSE label := CHR(ORD('A') + c - 10) END;
    TUI.PutCell(MAPX + c*2,     MAPY - 1, label, TUI.Yellow, TUI.Black);
    TUI.PutCell(MAPX + c*2 + 1, MAPY - 1, ' ',   TUI.Yellow, TUI.Black)
  END;
  TUI.PutCell(MAPX + GRID_W*2,     MAPY - 1, ' ', TUI.Black, TUI.Black);
  TUI.PutCell(MAPX + GRID_W*2 + 1, MAPY - 1, ' ', TUI.Black, TUI.Black);
  TUI.PutCell(MAPX + GRID_W*2 + 2, MAPY - 1, ' ', TUI.Black, TUI.Black);
  TUI.PutCell(MAPX + GRID_W*2 + 3, MAPY - 1, ' ', TUI.Black, TUI.Black);
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
  IF red.cmdAlive THEN TUI.PutStr(sx, sy, "Cmdr:alive", TUI.Red, TUI.Black)
  ELSE                 TUI.PutStr(sx, sy, "Cmdr:gone ", TUI.White, TUI.Black) END;
  INC(sy);
  FOR i := 0 TO red.count - 1 DO
    u := red.units[i];
    fg := TUI.White;
    IF u.fantasy THEN TUI.PutStr(sx, sy, ftName[u.ftype],   fg, TUI.Black)
    ELSE              TUI.PutStr(sx, sy, unitName[u.utype], fg, TUI.Black)
    END;
    IntStr(u.figures, num);
    TUI.PutStr(sx + 14, sy, num, fg, TUI.Black);
    IF ~u.alive THEN TUI.PutStr(sx + 17, sy, "X", TUI.Red, TUI.Black)
    ELSIF u.fatigued THEN TUI.PutStr(sx + 17, sy, "!", TUI.Yellow, TUI.Black)
    END;
    INC(sy)
  END;
  INC(sy);
  TUI.PutStr(sx, sy, "[Blue]", TUI.Cyan, TUI.Black); INC(sy);
  IF blue.cmdAlive THEN TUI.PutStr(sx, sy, "Cmdr:alive", TUI.Cyan, TUI.Black)
  ELSE                  TUI.PutStr(sx, sy, "Cmdr:gone ", TUI.White, TUI.Black) END;
  INC(sy);
  FOR i := 0 TO blue.count - 1 DO
    u := blue.units[i];
    fg := TUI.White;
    IF u.fantasy THEN TUI.PutStr(sx, sy, ftName[u.ftype],   fg, TUI.Black)
    ELSE              TUI.PutStr(sx, sy, unitName[u.utype], fg, TUI.Black)
    END;
    IntStr(u.figures, num);
    TUI.PutStr(sx + 14, sy, num, fg, TUI.Black);
    IF ~u.alive THEN TUI.PutStr(sx + 17, sy, "X", TUI.Cyan, TUI.Black)
    ELSIF u.fatigued THEN TUI.PutStr(sx + 17, sy, "!", TUI.Yellow, TUI.Black)
    END;
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
  IF u.retreatTurns > 0 THEN
    COPY("ROUT(", s); IntStr(u.retreatTurns, n); AppendStr(s, n); AppendStr(s, ")")
  ELSIF u.frozen THEN COPY("FROZEN", s)
  ELSE
    IF u.hedgehog THEN COPY("HEDGEHOG", s)
    ELSIF u.charged THEN COPY("chg!", s)
    END;
    IF u.moraleChecked THEN
      IF s[0] # 0X THEN AppendStr(s, " ") END; AppendStr(s, "shaken")
    END;
    IF u.hasPikes & ~u.hedgehog THEN
      IF s[0] # 0X THEN AppendStr(s, " ") END; AppendStr(s, "pike")
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
  | PH_JOIN:   AppendStr(s, "Join Phase  ")
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
          IF red.units[selUnit].fantasy THEN AppendStr(s, ftName[red.units[selUnit].ftype])
          ELSE AppendStr(s, unitName[red.units[selUnit].utype]) END;
          AppendStr(s, "  Green=target  Enter=shoot  Esc=cancel         ");
          TUI.PutStr(1, TUI.Rows - 1, s, TUI.Yellow, TUI.Black)
        END
    | PH_JOIN:
        TUI.PutStr(1, TUI.Rows - 1,
          "Join Phase: move unmoved units within 2 of enemy to join melee. N=done",
          TUI.White, TUI.Black)
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
    IF verboseAI THEN
      TUI.PutStr(1, TUI.Rows - 1,
        "Blue moving — press any key to step  [V=toggle verbose]       ",
        TUI.Cyan, TUI.Black)
    ELSE
      TUI.PutStr(1, TUI.Rows - 1,
        "Blue (computer) is playing...  [V=verbose step-through]       ",
        TUI.Cyan, TUI.Black)
    END
  END
END DrawStatus;

PROCEDURE DrawScreen;
BEGIN
  TUI.ClearBack(TUI.White, TUI.Black);
  DrawStatus; DrawCursorInfo; DrawMap; DrawUnitList; DrawLog;
  TUI.Flush
END DrawScreen;

(* ═══════════════════════════════════════════════════════════════════════ *)
(*  AI (Blue)                                                               *)
(* ═══════════════════════════════════════════════════════════════════════ *)

PROCEDURE WaitKeyIfVerbose;
VAR ev2: TUI.Event;
BEGIN
  IF ~verboseAI THEN RETURN END;
  DrawScreen;
  LOOP
    TUI.WaitEvent(ev2);
    IF ev2.kind = TUI.EvKey THEN EXIT
    ELSIF ev2.kind = TUI.EvResize THEN TUI.UpdateSize
    END
  END
END WaitKeyIfVerbose;

PROCEDURE AIJoinPhase;
VAR i, j, dc, dr, nc, nr, bestCol, bestRow: INTEGER;
    found: BOOLEAN;
    msg: ARRAY 64 OF CHAR;
BEGIN
  FOR i := 0 TO blue.count - 1 DO
    IF blue.units[i].alive & ~blue.units[i].moved & (blue.units[i].retreatTurns = 0) THEN
      (* Skip units already adjacent to an enemy — they'll fight in place *)
      found := FALSE;
      FOR j := 0 TO red.count - 1 DO
        IF red.units[j].alive &
           (CDist(blue.units[i].col, blue.units[i].row,
                  red.units[j].col, red.units[j].row) = 1) THEN
          found := TRUE
        END
      END;
      IF ~found THEN
        bestCol := -1; bestRow := -1;
        FOR dc := -2 TO 2 DO
          FOR dr := -2 TO 2 DO
            nc := blue.units[i].col + dc;
            nr := blue.units[i].row + dr;
            IF (bestCol < 0) & ValidMoveTarget(BLUE, i, nc, nr) &
               (CDist(blue.units[i].col, blue.units[i].row, nc, nr) <= 2) THEN
              FOR j := 0 TO red.count - 1 DO
                IF (bestCol < 0) & red.units[j].alive &
                   (CDist(nc, nr, red.units[j].col, red.units[j].row) = 1) THEN
                  bestCol := nc; bestRow := nr
                END
              END
            END
          END
        END;
        IF bestCol >= 0 THEN
          blue.units[i].facing  := FaceToward(blue.units[i].col, blue.units[i].row,
                                              bestCol, bestRow);
          blue.units[i].col     := bestCol;
          blue.units[i].row     := bestRow;
          blue.units[i].moved   := TRUE;
          blue.units[i].charged := TRUE;
          COPY("B.", msg);
          IF blue.units[i].fantasy THEN AppendStr(msg, ftName[blue.units[i].ftype])
          ELSE AppendStr(msg, unitName[blue.units[i].utype]) END;
          AppendStr(msg, " joins melee!"); AppendLog(msg);
          IF verboseAI THEN
            curCol := blue.units[i].col; curRow := blue.units[i].row;
            WaitKeyIfVerbose
          END
        END
      END
    END
  END
END AIJoinPhase;

PROCEDURE DoAITurn;
VAR i, tSide, tIdx: INTEGER;
    msg: ARRAY 64 OF CHAR;
    moraleMsg: ARRAY 64 OF CHAR;
    noCounter, skip: BOOLEAN;
    prevAttFigs, prevDefFigs, kills1pm, kills2pm: INTEGER;
    prevCol, prevRow, merRoll: INTEGER;
BEGIN
  (* Mercenary obedience check: 1=stand, 2-5=obey, 6=special *)
  FOR i := 0 TO blue.count - 1 DO
    IF blue.units[i].alive & blue.units[i].isMercenary THEN
      merRoll := D6();
      IF merRoll = 1 THEN
        blue.units[i].moved := TRUE;  (* counts as "did nothing" this turn *)
        AppendLog("B.Mercenary: no pay! Stands.")
      ELSIF merRoll = 6 THEN
        (* Bribed: march off toward Red side *)
        IF blue.units[i].row > 0 THEN DEC(blue.units[i].row) END;
        blue.units[i].moved := TRUE;
        AppendLog("B.Mercenary: bribed! Moving toward enemy.")
      END
      (* 2-5: obey normally — no action needed *)
    END
  END;

  (* Move Blue commander toward weakest unit *)
  prevCol := blue.cmdCol; prevRow := blue.cmdRow;
  AIMoveCmd;
  IF verboseAI & blue.cmdAlive &
     ((blue.cmdCol # prevCol) OR (blue.cmdRow # prevRow)) THEN
    curCol := blue.cmdCol; curRow := blue.cmdRow;
    WaitKeyIfVerbose
  END;
  (* Knight auto-charges happen before voluntary moves *)
  DoKnightCharges(BLUE);
  (* Move — frozen/retreating units skip voluntary movement *)
  FOR i := 0 TO blue.count - 1 DO
    IF blue.units[i].alive & ~blue.units[i].moved THEN
      prevCol := blue.units[i].col; prevRow := blue.units[i].row;
      AIMoveUnit(i);
      IF verboseAI & blue.units[i].alive &
         ((blue.units[i].col # prevCol) OR (blue.units[i].row # prevRow)) THEN
        curCol := blue.units[i].col; curRow := blue.units[i].row;
        WaitKeyIfVerbose
      END
    END
  END;

  (* Set shots for each Blue unit based on whether it moved *)
  SetShotsForTurn(BLUE);

  (* Shoot: fire all available shots (double-fire for stationary LF) *)
  FOR i := 0 TO blue.count - 1 DO
    WHILE blue.units[i].alive & (blue.units[i].shotsLeft > 0) DO
      AIFindShotTarget(i, tSide, tIdx);
      IF tIdx >= 0 THEN
        ResolveShot(BLUE, i, tSide, tIdx, msg);
        AppendLog(msg);
        DEC(blue.units[i].shotsLeft);
        IF verboseAI THEN
          curCol := blue.units[i].col; curRow := blue.units[i].row;
          WaitKeyIfVerbose
        END;
        IF tSide = RED THEN
          IF red.units[tIdx].alive THEN
            IF ~CheckUnitMorale(RED, tIdx, moraleMsg) THEN AppendLog(moraleMsg) END
          END
        ELSE
          IF blue.units[tIdx].alive THEN
            IF ~CheckUnitMorale(BLUE, tIdx, moraleMsg) THEN AppendLog(moraleMsg) END
          END
        END
      ELSE
        blue.units[i].shotsLeft := 0  (* no targets — stop trying *)
      END
    END
  END;

  (* Join: unmoved Blue units within 2 cells of a Red unit step into contact *)
  AIJoinPhase;

  (* Melee: each Blue unit adjacent to Red *)
  FOR i := 0 TO blue.count - 1 DO
    IF blue.units[i].alive THEN
      FOR tIdx := 0 TO red.count - 1 DO
        IF red.units[tIdx].alive &
           (CDist(blue.units[i].col, blue.units[i].row,
                  red.units[tIdx].col, red.units[tIdx].row) = 1) THEN
          noCounter := FALSE; skip := FALSE;
          (* Hedgehog: only pike units can attack *)
          IF red.units[tIdx].hedgehog & ~blue.units[i].hasPikes & ~blue.units[i].fantasy THEN
            AppendLog("Hedgehog holds — non-pike repelled!"); skip := TRUE
          END;
          IF ~skip THEN
          (* Pike charge morale: Blue pike charging forces Red defender to check *)
          IF ~blue.units[i].fantasy & blue.units[i].hasPikes & blue.units[i].charged THEN
            IF ~CheckPikeChargeMorale(RED, tIdx, msg) THEN
              AppendLog(msg); noCounter := TRUE
            ELSE AppendLog(msg)
            END
          END;
          (* Cavalry charge morale for Red defender *)
          IF blue.units[i].charged & ~blue.units[i].fantasy & (blue.units[i].utype >= LHT) &
             ~red.units[tIdx].fantasy & (red.units[tIdx].utype < LHT) THEN
            IF ~CheckChargeMorale(RED, tIdx, blue.units[i].utype,
                                   blue.units[i].col, blue.units[i].row, msg) THEN
              AppendLog(msg); noCounter := TRUE
            ELSE AppendLog(msg)
            END
          END;
          prevAttFigs := blue.units[i].figures;
          prevDefFigs := red.units[tIdx].figures;
          ResolveMelee(BLUE, i, RED, tIdx, noCounter, msg);
          AppendLog(msg);
          IF verboseAI THEN
            curCol := blue.units[i].col; curRow := blue.units[i].row;
            WaitKeyIfVerbose
          END;
          kills1pm := prevDefFigs - red.units[tIdx].figures;
          kills2pm := prevAttFigs - blue.units[i].figures;

          IF blue.units[i].alive & red.units[tIdx].alive THEN
            PostMeleeMorale(BLUE, i, RED, tIdx, kills1pm, kills2pm, moraleMsg);
            IF moraleMsg[0] # 0X THEN AppendLog(moraleMsg) END
          END;

          IF red.units[tIdx].alive THEN
            IF ~CheckUnitMorale(RED, tIdx, moraleMsg) THEN AppendLog(moraleMsg) END
          END;
          IF blue.units[i].alive THEN
            IF ~CheckUnitMorale(BLUE, i, moraleMsg) THEN AppendLog(moraleMsg) END
          END
          END  (* ~skip *)
        END
      END
    END
  END;
  CheckElimination
END DoAITurn;

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

(* Join phase: unmoved Red units within 2 cells of a Blue unit may be moved
   up to 2 cells toward that enemy to join the coming melee. *)
PROCEDURE HandleJoinPhase(key: INTEGER);
VAR logMsg: ARRAY 64 OF CHAR;
    prevCol, prevRow, oSide, oIdx, k: INTEGER;
    nearEnemy: BOOLEAN;
BEGIN
  IF    key = TUI.KUp    THEN IF curRow > 0 THEN DEC(curRow) END
  ELSIF key = TUI.KDown  THEN IF curRow < GRID_H - 1 THEN INC(curRow) END
  ELSIF key = TUI.KLeft  THEN IF curCol > 0 THEN DEC(curCol) END
  ELSIF key = TUI.KRight THEN IF curCol < GRID_W - 1 THEN INC(curCol) END
  ELSIF key = TUI.KEnter THEN
    IF selUnit >= 0 THEN
      (* Move selected unit to cursor — must end adjacent to a Blue unit *)
      nearEnemy := FALSE;
      FOR k := 0 TO blue.count - 1 DO
        IF blue.units[k].alive &
           (CDist(curCol, curRow, blue.units[k].col, blue.units[k].row) = 1) THEN
          nearEnemy := TRUE
        END
      END;
      IF nearEnemy & ValidMoveTarget(RED, selUnit, curCol, curRow) &
         (CDist(red.units[selUnit].col, red.units[selUnit].row, curCol, curRow) <= 2) THEN
        prevCol := red.units[selUnit].col; prevRow := red.units[selUnit].row;
        red.units[selUnit].facing := FaceToward(prevCol, prevRow, curCol, curRow);
        red.units[selUnit].col    := curCol;
        red.units[selUnit].row    := curRow;
        red.units[selUnit].moved  := TRUE;
        red.units[selUnit].charged := TRUE;
        COPY("Red ", logMsg); AppendStr(logMsg, unitName[red.units[selUnit].utype]);
        AppendStr(logMsg, " joins melee!"); AppendLog(logMsg);
        selUnit := -1
      ELSE AppendLog("Must end adjacent to an enemy (within 2 cells).")
      END
    ELSE
      UnitAt(curCol, curRow, oSide, oIdx);
      IF (oSide = RED) & ~red.units[oIdx].moved & (red.units[oIdx].retreatTurns = 0) THEN
        (* Check it is within 2 cells of an enemy *)
        nearEnemy := FALSE;
        FOR k := 0 TO blue.count - 1 DO
          IF blue.units[k].alive &
             (CDist(red.units[oIdx].col, red.units[oIdx].row,
                    blue.units[k].col, blue.units[k].row) <= 2) THEN
            nearEnemy := TRUE
          END
        END;
        IF nearEnemy THEN selUnit := oIdx
        ELSE AppendLog("Unit not within join range of any enemy.")
        END
      END
    END
  ELSIF key = TUI.KEsc THEN selUnit := -1
  END
END HandleJoinPhase;

PROCEDURE HandleMovePhase(key: INTEGER);
VAR logMsg: ARRAY 64 OF CHAR;
    prevCol, prevRow, oSide, oIdx: INTEGER;
BEGIN
  IF    key = TUI.KUp    THEN IF curRow > 0 THEN DEC(curRow) END
  ELSIF key = TUI.KDown  THEN IF curRow < GRID_H - 1 THEN INC(curRow) END
  ELSIF key = TUI.KLeft  THEN IF curCol > 0 THEN DEC(curCol) END
  ELSIF key = TUI.KRight THEN IF curCol < GRID_W - 1 THEN INC(curCol) END
  ELSIF key = TUI.KEnter THEN
    IF selUnit >= 0 THEN
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
        IF red.units[selUnit].utype >= HF THEN
          red.units[selUnit].charged := TRUE  (* HF/AF/cav get impetus flag *)
        END;
        COPY("Red ", logMsg);
        AppendStr(logMsg, unitName[red.units[selUnit].utype]);
        AppendStr(logMsg, " moves");
        AppendLog(logMsg);
        selUnit := -1
      END
    ELSIF cmdSelected THEN
      IF ValidCmdMove(RED, curCol, curRow) THEN
        red.cmdCol := curCol; red.cmdRow := curRow; red.cmdMoved := TRUE;
        AppendLog("Red commander moves");
        cmdSelected := FALSE
      END
    ELSE
      UnitAt(curCol, curRow, oSide, oIdx);
      IF (oSide = RED) & ~red.units[oIdx].moved & ~red.units[oIdx].frozen &
         (red.units[oIdx].retreatTurns = 0) THEN
        selUnit := oIdx
      ELSIF red.cmdAlive & ~red.cmdMoved &
            (red.cmdCol = curCol) & (red.cmdRow = curRow) THEN
        cmdSelected := TRUE
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
  ELSIF (key = ORD('h')) OR (key = ORD('H')) THEN
    IF selUnit >= 0 THEN
      IF red.units[selUnit].hasPikes THEN
        red.units[selUnit].hedgehog := ~red.units[selUnit].hedgehog;
        IF red.units[selUnit].hedgehog THEN AppendLog("Hedgehog formed!")
        ELSE AppendLog("Hedgehog dissolved.")
        END
      ELSE AppendLog("Only pike units can form hedgehog.")
      END
    END
  ELSIF key = TUI.KEsc THEN
    selUnit := -1; cmdSelected := FALSE
  ELSIF (key = ORD('n')) OR (key = ORD('N')) THEN
    selUnit := -1; cmdSelected := FALSE
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
          ELSIF red.units[oIdx].shotsLeft <= 0 THEN
            AppendLog("Already shot this turn.")
          ELSE
            selUnit := oIdx;
            IF ~HasShootTargets(RED, oIdx) THEN AppendLog("No targets in range.") END
          END
        ELSIF red.units[oIdx].utype # LF THEN AppendLog("Only Light Foot can shoot.")
        ELSIF red.units[oIdx].shotsLeft <= 0 THEN AppendLog("Already shot this turn.")
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
          DEC(red.units[selUnit].shotsLeft);
          CheckElimination;
          IF blue.units[oIdx].alive THEN
            IF ~CheckUnitMorale(BLUE, oIdx, moraleMsg) THEN AppendLog(moraleMsg) END
          END;
          (* Keep unit selected if it has shots remaining (double-fire) *)
          IF red.units[selUnit].shotsLeft <= 0 THEN selUnit := -1 END
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
    IF a.units[i].moved THEN
      INC(a.units[i].consMovs); a.units[i].stationaryTurns := 0
    ELSE
      a.units[i].consMovs := 0; INC(a.units[i].stationaryTurns)
    END;
    IF a.units[i].inMelee THEN INC(a.units[i].meleeRounds)
    ELSE a.units[i].meleeRounds := 0
    END;
    a.units[i].fatigued :=
      (a.units[i].consMovs >= 5) OR
      (a.units[i].meleeRounds >= 3) OR
      (a.units[i].charged & a.units[i].inMelee & (a.units[i].consMovs >= 2));
    a.units[i].wasAttacked := a.units[i].inMelee;
    a.units[i].moved    := FALSE;
    a.units[i].shotsLeft := 0;   (* set properly by SetShotsForTurn at PH_SHOOT *)
    a.units[i].charged  := FALSE;
    a.units[i].frozen   := FALSE;
    a.units[i].inMelee  := FALSE
  END;
  a.cmdMoved := FALSE;
  SetArmy(side, a)
END ClearTurnFlags;

(*
 * Auto-charge for feudal Knights (§Historical Characteristics — Knights).
 * Any alive HH unit with isKnight=TRUE that has an enemy within its move
 * allowance must charge (move toward the nearest enemy) unless a 6 is rolled
 * on the obedience die.  Sets moved=TRUE and charged=TRUE on the unit.
 *)
PROCEDURE DoKnightCharges(side: INTEGER);
VAR cnt, eCnt, mv, i, j: INTEGER;
    uCol, uRow, tCol, tRow: INTEGER;
    bestCol, bestRow, bestDist, dc, dr, nc, nr, dist: INTEGER;
    inRange: BOOLEAN;
    msg: ARRAY 64 OF CHAR;
BEGIN
  IF side = RED THEN cnt := red.count; eCnt := blue.count
  ELSE cnt := blue.count; eCnt := red.count END;
  mv := moveAllow[HH];
  FOR i := 0 TO cnt - 1 DO
    (* Eligibility check *)
    IF side = RED THEN
      IF ~(red.units[i].alive & red.units[i].isKnight &
           ~red.units[i].moved & ~red.units[i].frozen &
           (red.units[i].retreatTurns = 0)) THEN
        inRange := FALSE  (* sentinel: skip *)
      ELSE
        uCol := red.units[i].col; uRow := red.units[i].row;
        inRange := FALSE;
        FOR j := 0 TO eCnt - 1 DO
          IF blue.units[j].alive &
             (CDist(uCol, uRow, blue.units[j].col, blue.units[j].row) <= mv) THEN
            inRange := TRUE
          END
        END
      END
    ELSE
      IF ~(blue.units[i].alive & blue.units[i].isKnight &
           ~blue.units[i].moved & ~blue.units[i].frozen &
           (blue.units[i].retreatTurns = 0)) THEN
        inRange := FALSE
      ELSE
        uCol := blue.units[i].col; uRow := blue.units[i].row;
        inRange := FALSE;
        FOR j := 0 TO eCnt - 1 DO
          IF red.units[j].alive &
             (CDist(uCol, uRow, red.units[j].col, red.units[j].row) <= mv) THEN
            inRange := TRUE
          END
        END
      END
    END;

    IF inRange THEN
      IF D6() = 6 THEN
        IF side = RED THEN COPY("R.Knight: obey-6, holds.", msg)
        ELSE COPY("B.Knight: obey-6, holds.", msg) END;
        AppendLog(msg)
      ELSE
        (* Find nearest enemy *)
        tCol := -1; tRow := -1; bestDist := 9999;
        FOR j := 0 TO eCnt - 1 DO
          IF (side = RED) & blue.units[j].alive THEN
            dist := CDist(uCol, uRow, blue.units[j].col, blue.units[j].row);
            IF dist < bestDist THEN bestDist := dist; tCol := blue.units[j].col; tRow := blue.units[j].row END
          END;
          IF (side = BLUE) & red.units[j].alive THEN
            dist := CDist(uCol, uRow, red.units[j].col, red.units[j].row);
            IF dist < bestDist THEN bestDist := dist; tCol := red.units[j].col; tRow := red.units[j].row END
          END
        END;
        IF tCol >= 0 THEN
          bestCol := uCol; bestRow := uRow;
          bestDist := CDist(uCol, uRow, tCol, tRow);
          FOR dc := -mv TO mv DO
            FOR dr := -mv TO mv DO
              nc := uCol + dc; nr := uRow + dr;
              IF ValidMoveTarget(side, i, nc, nr) THEN
                dist := CDist(nc, nr, tCol, tRow);
                IF dist < bestDist THEN bestDist := dist; bestCol := nc; bestRow := nr END
              END
            END
          END;
          IF (bestCol # uCol) OR (bestRow # uRow) THEN
            IF side = RED THEN
              red.units[i].facing  := FaceToward(uCol, uRow, bestCol, bestRow);
              red.units[i].col     := bestCol; red.units[i].row     := bestRow;
              red.units[i].moved   := TRUE;    red.units[i].charged := TRUE;
              COPY("R.Knight charges!", msg)
            ELSE
              blue.units[i].facing  := FaceToward(uCol, uRow, bestCol, bestRow);
              blue.units[i].col     := bestCol; blue.units[i].row     := bestRow;
              blue.units[i].moved   := TRUE;    blue.units[i].charged := TRUE;
              COPY("B.Knight charges!", msg)
            END;
            AppendLog(msg)
          END
        END
      END
    END
  END
END DoKnightCharges;

PROCEDURE AdvancePhase;
BEGIN
  selUnit := -1;
  CASE phase OF
    PH_MOVE:
      undoTop := 0;
      SetShotsForTurn(RED);
      phase := PH_SHOOT
  | PH_SHOOT:
      phase := PH_JOIN
  | PH_JOIN:
      phase := PH_COMBAT
  | PH_COMBAT:
      ResolveMeleeAll;
      phase := PH_ELIM;
      CheckVictory
  | PH_ELIM:
      IF activeSide = RED THEN
        activeSide := BLUE;
        ClearTurnFlags(BLUE);
        CheckRally(BLUE);
        phase := PH_MOVE;
        DrawScreen;
        DoAITurn;
        CheckVictory;
        activeSide := RED;
        INC(turn);
        ClearTurnFlags(RED);
        CheckRally(RED);
        DoKnightCharges(RED);
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

PROCEDURE DeployArmy(VAR a: Army; side, count: INTEGER; comp: CompArray);
VAR i, col, row, t, last, ft: INTEGER; startRow: INTEGER;
BEGIN
  a.side  := side; a.count := count;
  IF side = RED THEN startRow := 1 ELSE startRow := GRID_H - 2 END;
  FOR i := 0 TO count - 1 DO
    a.units[i].utype         := comp[i];
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
    a.units[i].alive          := TRUE;
    a.units[i].moved          := FALSE;
    a.units[i].shotsLeft      := 0;
    a.units[i].charged        := FALSE;
    a.units[i].moraleChecked  := FALSE;
    a.units[i].fatigued       := FALSE;
    a.units[i].consMovs       := 0;
    a.units[i].meleeRounds    := 0;
    a.units[i].inMelee        := FALSE;
    a.units[i].wasAttacked    := FALSE;
    a.units[i].retreatTurns   := 0;
    a.units[i].hasPikes       := FALSE;
    a.units[i].hedgehog       := FALSE;
    a.units[i].isKnight       := FALSE;
    a.units[i].isMercenary    := FALSE;
    a.units[i].isReligious    := FALSE;
    a.units[i].stationaryTurns := 0;
    (* Historical unit flags based on type *)
    IF a.units[i].utype = HH THEN a.units[i].isKnight := TRUE END;
    IF a.units[i].utype = AF THEN a.units[i].isReligious := TRUE END;  (* Armored Foot = Military Orders *)
    IF a.units[i].utype = HF THEN a.units[i].hasPikes := (i MOD 3 = 0) END;  (* 1-in-3 HF are pike *)
    IF side = RED THEN a.units[i].facing := SOUTH
    ELSE               a.units[i].facing := NORTH
    END
  END;
  IF fantasyMode THEN
    (* Replace last unit with a random fantasy creature *)
    last := count - 1;
    ft   := Random.Int(NFTYPES);
    a.units[last].utype         := 0;
    a.units[last].fantasy       := TRUE;
    a.units[last].ftype         := ft;
    a.units[last].figures       := ftFigsStart[ft];
    a.units[last].moraleChecked := FALSE
  END;
  (* Place army commander at back-centre row *)
  a.cmdCol   := GRID_W DIV 2;
  IF side = RED THEN a.cmdRow := 0 ELSE a.cmdRow := GRID_H - 1 END;
  a.cmdAlive := TRUE;
  a.cmdMoved := FALSE
END DeployArmy;

(* Convert a half-point cost to a display string: 4 -> "2", 5 -> "2.5" *)
PROCEDURE HalfPtStr(hp: INTEGER; VAR s: ARRAY OF CHAR);
VAR n: ARRAY 8 OF CHAR;
BEGIN
  IntStr(hp DIV 2, n); COPY(n, s);
  IF (hp MOD 2) = 1 THEN AppendStr(s, ".5") END
END HalfPtStr;

(* Interactive point-buy screen for one side.
   Returns the chosen composition in comp[0..count-1]. *)
PROCEDURE SelectArmyByPoints(side: INTEGER;
                              VAR comp: CompArray; VAR count: INTEGER);
VAR ev2: TUI.Event;
    budget, spent, t, i: INTEGER;
    fg: INTEGER;
    hpStr, cStr: ARRAY 8 OF CHAR;
    label: ARRAY 40 OF CHAR;
BEGIN
  budget := pointBuyBudget;
  count  := 0; spent := 0;
  FOR i := 0 TO MAX_UNITS - 1 DO comp[i] := 0 END;

  LOOP
    TUI.ClearBack(TUI.White, TUI.Black);
    IF side = RED THEN
      TUI.PutStr(2, 0, "CHAINMAIL — Red Army (Point Buy)", TUI.Red, TUI.Black)
    ELSE
      TUI.PutStr(2, 0, "CHAINMAIL — Blue Army (Point Buy)", TUI.Cyan, TUI.Black)
    END;
    TUI.PutStr(2, 1, "────────────────────────────────────────────────────────", TUI.White, TUI.Black);

    (* Budget line *)
    COPY("Budget: ", label); HalfPtStr(budget, hpStr); AppendStr(label, hpStr);
    AppendStr(label, " pts   Used: "); HalfPtStr(spent, hpStr); AppendStr(label, hpStr);
    AppendStr(label, " pts   Left: "); HalfPtStr(budget - spent, hpStr); AppendStr(label, hpStr);
    AppendStr(label, " pts   Slots: "); IntStr(count, hpStr); AppendStr(label, hpStr);
    AppendStr(label, "/"); IntStr(MAX_UNITS, hpStr); AppendStr(label, hpStr);
    TUI.PutStr(2, 2, label, TUI.Yellow, TUI.Black);

    (* Current army *)
    TUI.PutStr(2, 4, "Your army:", TUI.White, TUI.Black);
    IF count = 0 THEN
      TUI.PutStr(4, 5, "(empty)", TUI.White, TUI.Black)
    ELSE
      FOR i := 0 TO count - 1 DO
        COPY("  ", label); AppendStr(label, unitName[comp[i]]);
        TUI.PutStr(4, 5 + i, label, TUI.White, TUI.Black)
      END
    END;

    (* Unit menu *)
    TUI.PutStr(2, 12, "Add unit (key 1-6), D=remove last, N=confirm:", TUI.White, TUI.Black);
    FOR t := 0 TO NTYPES - 1 DO
      fg := TUI.White;
      IF (unitCost[t] > budget - spent) OR (count >= MAX_UNITS) THEN fg := TUI.White END;
      IntStr(t + 1, cStr);
      COPY("  ", label); label[0] := '['; label[1] := 0X;
      AppendStr(label, cStr); AppendStr(label, "] ");
      AppendStr(label, unitName[t]); AppendStr(label, "   ");
      HalfPtStr(unitCost[t], hpStr); AppendStr(label, hpStr); AppendStr(label, " pt   ");
      AppendStr(label, unitDesc[t]);
      IF unitCost[t] > budget - spent THEN fg := TUI.White
      ELSIF count >= MAX_UNITS         THEN fg := TUI.White
      ELSE                                  fg := TUI.Cyan
      END;
      TUI.PutStr(4, 13 + t, label, fg, TUI.Black)
    END;
    TUI.Flush;

    TUI.WaitEvent(ev2);
    IF ev2.kind = TUI.EvKey THEN
      IF ev2.key = 17 THEN TUI.Done; HALT(0)
      ELSIF ev2.key = ORD('N') OR ev2.key = ORD('n') THEN
        IF count > 0 THEN EXIT END
      ELSIF (ev2.key = ORD('D')) OR (ev2.key = ORD('d')) THEN
        IF count > 0 THEN
          DEC(count);
          DEC(spent, unitCost[comp[count]])
        END
      ELSIF (ev2.key >= ORD('1')) & (ev2.key <= ORD('6')) THEN
        t := ev2.key - ORD('1');
        IF (t >= 0) & (t < NTYPES) &
           (unitCost[t] <= budget - spent) & (count < MAX_UNITS) THEN
          comp[count] := t;
          INC(spent, unitCost[t]);
          INC(count)
        END
      END
    END
  END
END SelectArmyByPoints;

(* AI fills its army greedily: randomly pick affordable units until budget or slots run out. *)
PROCEDURE AISelectArmyByPoints(VAR comp: CompArray; VAR count: INTEGER);
VAR budget, spent, t, tries, i: INTEGER;
BEGIN
  budget := pointBuyBudget;
  count := 0; spent := 0;
  FOR i := 0 TO MAX_UNITS - 1 DO comp[i] := 0 END;
  WHILE (count < MAX_UNITS) & (spent < budget) DO
    tries := 0;
    REPEAT
      t := Random.Int(NTYPES);
      INC(tries)
    UNTIL (unitCost[t] <= budget - spent) OR (tries > 30);
    IF unitCost[t] <= budget - spent THEN
      comp[count] := t;
      INC(spent, unitCost[t]);
      INC(count)
    ELSE
      (* can't fit anything more *)
      spent := budget
    END
  END
END AISelectArmyByPoints;

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
  TUI.PutStr(4, 14, "Hero @ / SHero S / Wizard W / Wraith G", TUI.White, TUI.Black);
  TUI.PutStr(4, 15, "Ogre O / Balrog ! / Giant J / Dragon D", TUI.White, TUI.Black);
  TUI.PutStr(4, 16, "Lycan Y / Roc R / Wight V / Elem E / Ent N", TUI.White, TUI.Black);
  TUI.PutStr(2, 17, "FCT, fly, breath, paralyze.", TUI.White, TUI.Black);
  TUI.PutStr(2, 18, "Press Y / N:", TUI.White, TUI.Black);
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

PROCEDURE ShowArmy(side: INTEGER; label: ARRAY OF CHAR);
VAR sx, sy, i: INTEGER; fg: INTEGER; a: Army; u: Unit;
    hpStr, costStr: ARRAY 12 OF CHAR;
    pts: INTEGER;
BEGIN
  sy := 0; sx := 2;
  IF side = BLUE THEN sy := 9 END;
  fg := TUI.Red; IF side = BLUE THEN fg := TUI.Cyan END;
  TUI.PutStr(sx, sy, label, fg, TUI.Black);
  a := ArmyOf(side);
  pts := 0;
  FOR i := 0 TO a.count - 1 DO
    u := a.units[i];
    IF u.fantasy THEN
      TUI.PutStr(sx + 2, sy + 1 + i, ftName[u.ftype], TUI.Magenta, TUI.Black)
    ELSE
      TUI.PutStr(sx + 2, sy + 1 + i, unitName[u.utype], TUI.White, TUI.Black);
      INC(pts, unitCost[u.utype])
    END
  END;
  IF pointBuyBudget > 0 THEN
    COPY("Total: ", costStr); HalfPtStr(pts, hpStr); AppendStr(costStr, hpStr);
    AppendStr(costStr, " pts");
    TUI.PutStr(sx + 2, sy + 1 + a.count, costStr, TUI.Yellow, TUI.Black)
  END
END ShowArmy;

PROCEDURE SetupGame;
VAR rollR, rollB: INTEGER; ev2: TUI.Event;
    redComp, blueComp: CompArray;
    redCount, blueCount, i: INTEGER;
    hdr: ARRAY 48 OF CHAR;
BEGIN
  IF    scenario = SCEN_1 THEN InitScenario1
  ELSIF scenario = SCEN_2 THEN InitScenario2
  ELSIF scenario = SCEN_3 THEN InitScenario3
  ELSE  InitScenarioRandom
  END;

  (* ── Army selection mode ── *)
  TUI.ClearBack(TUI.White, TUI.Black);
  TUI.PutStr(2, 1, "CHAINMAIL — Army Selection", TUI.Yellow, TUI.Black);
  TUI.PutStr(2, 2, "────────────────────────────────────────────────────────", TUI.White, TUI.Black);
  TUI.PutStr(2, 4, "R  Random roll  (classic composition tables)", TUI.White, TUI.Black);
  TUI.PutStr(2, 5, "1  Point Buy — Skirmish  (12 pts)", TUI.White, TUI.Black);
  TUI.PutStr(2, 6, "2  Point Buy — Standard  (15 pts)", TUI.White, TUI.Black);
  TUI.PutStr(2, 7, "3  Point Buy — Lords of War  (20 pts)", TUI.White, TUI.Black);
  TUI.PutStr(2, 9, "Press R / 1 / 2 / 3:", TUI.White, TUI.Black);
  TUI.Flush;
  pointBuyBudget := 0;
  LOOP
    TUI.WaitEvent(ev2);
    IF ev2.kind = TUI.EvKey THEN
      IF    (ev2.key = ORD('r')) OR (ev2.key = ORD('R')) THEN pointBuyBudget := 0;                EXIT
      ELSIF ev2.key = ORD('1') THEN pointBuyBudget := POINT_BUDGET_SM; EXIT
      ELSIF ev2.key = ORD('2') THEN pointBuyBudget := POINT_BUDGET_MD; EXIT
      ELSIF ev2.key = ORD('3') THEN pointBuyBudget := POINT_BUDGET_LG; EXIT
      ELSIF ev2.key = 17       THEN TUI.Done; HALT(0)
      END
    END
  END;

  IF pointBuyBudget > 0 THEN
    (* Point buy: player selects Red, AI selects Blue *)
    SelectArmyByPoints(RED,  redComp,  redCount);
    AISelectArmyByPoints(blueComp, blueCount);
    DeployArmy(red,  RED,  redCount,  redComp);
    DeployArmy(blue, BLUE, blueCount, blueComp)
  ELSE
    (* Classic random roll — build comp arrays from compTable *)
    rollR := Random.Int(6); rollB := Random.Int(6);
    WHILE rollR = rollB DO rollB := Random.Int(6) END;
    FOR i := 0 TO MAX_UNITS - 1 DO
      redComp[i]  := compTable[rollR][i];
      blueComp[i] := compTable[rollB][i]
    END;
    DeployArmy(red,  RED,  MAX_UNITS, redComp);
    DeployArmy(blue, BLUE, MAX_UNITS, blueComp)
  END;

  TUI.ClearBack(TUI.White, TUI.Black);
  IF pointBuyBudget > 0 THEN
    COPY("Army Compositions (Point Buy)", hdr)
  ELSE
    COPY("Army Compositions (Random Roll)", hdr)
  END;
  TUI.PutStr(2, 1, hdr, TUI.Yellow, TUI.Black);
  ShowArmy(RED,  "Red army:");
  ShowArmy(BLUE, "Blue army:");
  TUI.PutStr(2, 19, "Press any key to begin...", TUI.White, TUI.Black);
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
  selUnit     := -1;
  cmdSelected := FALSE;
  undoTop     := 0;
  gameOver    := FALSE;
  verboseAI   := FALSE;
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
      ELSIF (ev.key = ORD('v')) OR (ev.key = ORD('V')) THEN
        verboseAI := ~verboseAI
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
        | PH_JOIN:
            IF ((ev.key = ORD('n')) OR (ev.key = ORD('N'))) & (selUnit < 0) THEN AdvancePhase
            ELSE HandleJoinPhase(ev.key)
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
