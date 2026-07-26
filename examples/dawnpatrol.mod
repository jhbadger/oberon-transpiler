MODULE DawnPatrol;
(*
 * DAWN PATROL -- WWI aerial combat, Raylib edition.
 * Adapted from Mike Carr's DAWN PATROL (TSR, 1982) Basic Rules: dice-based
 * movement order, altitude/throttle/turning movement on a 100ft-per-square
 * grid, five-angle attacks (head-on/side/tail/top/bottom) resolved against
 * the book's Hit Location Table, per-section damage, ammo, and pilot/
 * observer wound checks.  Two maneuvers beyond plain turning are modeled
 * (Immelmann, Loop); the physical maneuver-card tailing mini-game and the
 * full 16-maneuver roster are simplified into an automatic tail-position
 * check: end your move within tail range/arc of an enemy and you'll
 * automatically follow them next turn, as the book's tailing rules intend.
 *
 * Controls:
 *   Title screen      : Enter to choose your aircraft, T for the tutorial,
 *                       Esc quits.
 *   Tutorial          : Left/Right to page through, Enter also advances.
 *   Briefing          : Up/Down choose aircraft, Enter to fly, Esc quits.
 *   Altitude step     : Up/Down adjust climb(+)/dive(-) 50ft, Enter locks in.
 *   Throttle step     : Up/Down adjust +-10 mph, Enter locks in.
 *   Move step         : Left/Right turn 45 (once per square), Space/Enter
 *                       advance one square, I = Immelmann, L = Loop.
 *   Target step       : Up/Down cycle targets in your arc, Enter to fire,
 *                       Backspace to hold fire.
 *   Game over         : Enter restarts at the title screen.
 *)

IMPORT Raylib, Random, Strings, Math;

CONST
  W = 1040;  H = 720;
  PLAYW = 780;  PANELX = 784;  PANELW = W - PANELX;
  CELL = 26.0;

  (* compass facings, clockwise from north, 45 degree steps *)
  DIR_N=0; DIR_NE=1; DIR_E=2; DIR_SE=3; DIR_S=4; DIR_SW=5; DIR_W=6; DIR_NW=7;

  (* sides *)
  ALLIED = 0;  GERMAN = 1;

  (* nations -- flavour only *)
  NAT_BRITISH=0; NAT_FRENCH=1; NAT_AMERICAN=2; NAT_GERMAN=3; NAT_ITALIAN=4;

  (* aircraft type indices *)
  AC_SNIPE=0; AC_CAMEL=1; AC_DOLPHIN=2; AC_DH5=3; AC_SPAD7=4; AC_SPAD13=5;
  AC_NIEU17=6; AC_NIEU28=7; AC_MSAI=8; AC_HANRIOT=9; AC_DRI=10; AC_DVII=11;
  AC_BRISTOL=12; AC_DH4US=13; AC_STRUTTER=14; AC_DH4GB=15;
  NAIRCRAFT = 16;
  NSELECTABLE = 10;  (* single-seat Allied fighters the player may fly *)
  MAXVARIANT = 7;    (* most colour/squadron variants any one aircraft has on the counter sheets *)

  MAXPLANES = 4;
  NENEMIES = 2;

  (* top-level stages *)
  ST_TITLE=0; ST_BRIEF=1; ST_PLAY=2; ST_OVER=3; ST_TUTORIAL=4;

  NTUTPAGES   = 6;
  MAXTUTLINES = 6;

  (* per-turn sub-stages *)
  SUB_ORDER=0; SUB_ALT=1; SUB_THROTTLE=2; SUB_STEP=3; SUB_TARGET=4;
  SUB_NEXT=5; SUB_FIRE=6;

  MINSPEED = 60;
  THROTTLE_STEP = 20;  (* max change per turn *)

  (* attack angles *)
  ANG_HEAD=0; ANG_SIDE=1; ANG_TAIL=2; ANG_TOP=3; ANG_BOTTOM=4;

  (* hit locations *)
  LOC_E=0; LOC_FF=1; LOC_RF=2; LOC_T=3; LOC_LW=4; LOC_CW=5; LOC_RW=6; LOC_LWRW=7;

  STARTAMMO = 15;
  MAXLOG = 9;

TYPE
  AircraftType = RECORD
    name              : ARRAY 24 OF CHAR;
    side              : INTEGER;
    nation            : INTEGER;
    seats             : INTEGER;   (* 1 or 2 *)
    wings             : INTEGER;   (* 1=mono 2=bi 3=tri *)
    nonFighter        : BOOLEAN;   (* book's asterisked types: +1 to move-order roll *)
    top, turn, climb  : ARRAY 4 OF INTEGER;  (* per altitude band *)
    maxDive           : INTEGER;
    ceiling           : INTEGER;
    hitE, hitFF, hitRF, hitT, hitLW, hitCW, hitRW : INTEGER;
    texBase           : ARRAY 16 OF CHAR;  (* counter image filename prefix, e.g. "Camel" *)
    texCount          : INTEGER;           (* number of _N colour/squadron variants on disk *)
  END;

  Plane = RECORD
    kind      : INTEGER;
    side      : INTEGER;
    alive     : BOOLEAN;
    isPlayer  : BOOLEAN;
    gx, gy    : REAL;
    dir       : INTEGER;
    alt       : INTEGER;
    startAlt  : INTEGER;   (* altitude at start of this turn's move *)
    throttle  : INTEGER;
    ammo      : INTEGER;
    dmgE, dmgFF, dmgRF, dmgT, dmgLW, dmgCW, dmgRW : INTEGER;
    pilotHit  : BOOLEAN;
    obsHit    : BOOLEAN;
    tailing   : INTEGER;   (* plane index being tailed, -1 = none *)
    target    : INTEGER;   (* declared target this turn, -1 = none *)
    fired     : BOOLEAN;
    label     : ARRAY 16 OF CHAR;
    texVariant: INTEGER;   (* which _N counter-sheet colour variant this individual plane uses *)
  END;

VAR
  acTypes    : ARRAY NAIRCRAFT OF AircraftType;
  selectable : ARRAY NSELECTABLE OF INTEGER;

  dirDX, dirDY : ARRAY 8 OF INTEGER;

  hitLocTab  : ARRAY 5, 6 OF INTEGER;
  pilotStar  : ARRAY 5, 6 OF BOOLEAN;
  obsStar    : ARRAY 5, 6 OF BOOLEAN;

  planes    : ARRAY MAXPLANES OF Plane;
  nplanes   : INTEGER;
  playerIdx : INTEGER;

  stage, substage : INTEGER;
  moveOrder : ARRAY MAXPLANES OF INTEGER;
  curPos    : INTEGER;   (* position within moveOrder currently resolving *)
  activePlane : INTEGER; (* plane index whose move is in progress *)
  turnNum   : INTEGER;

  budget           : INTEGER;
  turnedThisSquare : BOOLEAN;
  usedSpecial      : BOOLEAN;
  pendingAltDelta  : INTEGER;
  pendingThrottle  : INTEGER;
  diveBonus        : INTEGER;
  curBand          : INTEGER;

  targetList  : ARRAY MAXPLANES OF INTEGER;
  targetCount : INTEGER;
  targetSel   : INTEGER;

  camX, camY : REAL;

  selType : INTEGER;   (* index into `selectable`, briefing screen cursor *)

  tutTitle     : ARRAY NTUTPAGES OF ARRAY 40 OF CHAR;
  tutLines     : ARRAY NTUTPAGES, MAXTUTLINES OF ARRAY 76 OF CHAR;
  tutLineCount : ARRAY NTUTPAGES OF INTEGER;
  tutPage      : INTEGER;

  msgLog   : ARRAY MAXLOG OF ARRAY 72 OF CHAR;
  msgCount : INTEGER;
  msgHead  : INTEGER;

  winMsg : ARRAY 40 OF CHAR;

  texCover, texSpad, texFokker, texAlbatros : Raylib.Texture;
  haveCover, haveSpad, haveFokker, haveAlbatros : BOOLEAN;

  (* real counter-sheet artwork: planeTex[kind][variant], up to MAXVARIANT colour/squadron
     variants per aircraft type (7 needed for the S.P.A.D. pool). *)
  planeTex   : ARRAY NAIRCRAFT, MAXVARIANT OF Raylib.Texture;
  planeTexOK : ARRAY NAIRCRAFT, MAXVARIANT OF BOOLEAN;

  cBlack, cWhite, cRed, cGreen, cBlue, cYellow, cLGray, cDGray, cSky,
    cBrown, cOrange, cGold : INTEGER;

  dt : REAL;

(* ════════════════════════════════════════════════════════════════════ *)
(*  Small helpers                                                        *)
(* ════════════════════════════════════════════════════════════════════ *)

PROCEDURE D6() : INTEGER;
BEGIN RETURN Random.Int(6) + 1 END D6;

PROCEDURE D2D6() : INTEGER;
BEGIN RETURN D6() + D6() END D2D6;

PROCEDURE Opposite(d : INTEGER) : INTEGER;
BEGIN RETURN (d + 4) MOD 8 END Opposite;

PROCEDURE AltBand(alt : INTEGER) : INTEGER;
BEGIN
  IF alt < 5000 THEN RETURN 0
  ELSIF alt < 10000 THEN RETURN 1
  ELSIF alt < 15000 THEN RETURN 2
  ELSE RETURN 3
  END
END AltBand;

PROCEDURE IMax(a, b : INTEGER) : INTEGER;
BEGIN IF a > b THEN RETURN a ELSE RETURN b END END IMax;

PROCEDURE IMin(a, b : INTEGER) : INTEGER;
BEGIN IF a < b THEN RETURN a ELSE RETURN b END END IMin;

PROCEDURE IClamp(x, lo, hi : INTEGER) : INTEGER;
BEGIN RETURN IMax(lo, IMin(hi, x)) END IClamp;

(* octant (0..7, same convention as facings) of the vector (dx,dy); -1 if zero *)
PROCEDURE OctantOf(dx, dy : REAL) : INTEGER;
VAR ang, step : REAL;
BEGIN
  IF (dx = 0.0) & (dy = 0.0) THEN RETURN -1 END;
  ang  := Math.arctan2(dy, dx);
  step := Math.round(ang / (Math.pi / 4.0));
  RETURN (FLOOR(step) + 2 + 800) MOD 8
END OctantOf;

PROCEDURE ChebDist(ax, ay, bx, by : REAL) : INTEGER;
VAR dx, dy : REAL;
BEGIN
  dx := ax - bx;  IF dx < 0.0 THEN dx := -dx END;
  dy := ay - by;  IF dy < 0.0 THEN dy := -dy END;
  IF dx > dy THEN RETURN FLOOR(dx + 0.5) ELSE RETURN FLOOR(dy + 0.5) END
END ChebDist;

PROCEDURE AppendLog(s : ARRAY OF CHAR);
BEGIN
  COPY(s, msgLog[msgHead]);
  msgHead := (msgHead + 1) MOD MAXLOG;
  IF msgCount < MAXLOG THEN INC(msgCount) END
END AppendLog;

(* ════════════════════════════════════════════════════════════════════ *)
(*  Aircraft data -- from the book's Aircraft Specifications cards        *)
(* ════════════════════════════════════════════════════════════════════ *)

PROCEDURE DefAC(idx, side, nation, seats, wings : INTEGER; nonFighter : BOOLEAN;
                ffg, flxg, dive, ceil : INTEGER;
                hE, hFF, hRF, hT, hLW, hCW, hRW : INTEGER; name : ARRAY OF CHAR);
BEGIN
  COPY(name, acTypes[idx].name);
  acTypes[idx].side       := side;
  acTypes[idx].nation     := nation;
  acTypes[idx].seats      := seats;
  acTypes[idx].wings      := wings;
  acTypes[idx].nonFighter := nonFighter;
  acTypes[idx].maxDive    := dive;
  acTypes[idx].ceiling    := ceil;
  acTypes[idx].hitE  := hE;  acTypes[idx].hitFF := hFF; acTypes[idx].hitRF := hRF;
  acTypes[idx].hitT  := hT;  acTypes[idx].hitLW := hLW; acTypes[idx].hitCW := hCW;
  acTypes[idx].hitRW := hRW
END DefAC;

PROCEDURE DefBand(idx, band, top, turn, climb : INTEGER);
BEGIN
  acTypes[idx].top[band]   := top;
  acTypes[idx].turn[band]  := turn;
  acTypes[idx].climb[band] := climb
END DefBand;

(* base: counter-sheet filename prefix, e.g. "Camel" for Camel_1.jpg..Camel_4.jpg *)
PROCEDURE DefTex(idx : INTEGER; base : ARRAY OF CHAR; count : INTEGER);
BEGIN
  COPY(base, acTypes[idx].texBase);
  acTypes[idx].texCount := count
END DefTex;

PROCEDURE InitAircraftTypes;
BEGIN
  DefAC(AC_SNIPE, ALLIED, NAT_BRITISH, 1, 2, FALSE, 2,0, 1500,19500, 6,11,15,11,12,12,12, "Sopwith 7F.1 Snipe");
  DefBand(AC_SNIPE,0, 120,110,350); DefBand(AC_SNIPE,1, 120,110,300);
  DefBand(AC_SNIPE,2, 110,100,250); DefBand(AC_SNIPE,3, 110,100,200);
  DefTex(AC_SNIPE, "Snipe", 2);

  DefAC(AC_CAMEL, ALLIED, NAT_BRITISH, 1, 2, FALSE, 2,0, 1500,22000, 6,11,15,11,12,12,12, "Sopwith F.1 Camel");
  DefBand(AC_CAMEL,0, 120,110,400); DefBand(AC_CAMEL,1, 110,110,350);
  DefBand(AC_CAMEL,2, 110,100,250); DefBand(AC_CAMEL,3, 100,90,200);
  DefTex(AC_CAMEL, "Camel", 4);

  DefAC(AC_DOLPHIN, ALLIED, NAT_BRITISH, 1, 2, FALSE, 2,1, 1500,21000, 6,11,15,12,12,12,12, "Sopwith 5F.1 Dolphin");
  DefBand(AC_DOLPHIN,0, 130,100,400); DefBand(AC_DOLPHIN,1, 120,90,300);
  DefBand(AC_DOLPHIN,2, 120,90,250); DefBand(AC_DOLPHIN,3, 110,80,150);
  DefTex(AC_DOLPHIN, "Dolphin", 2);

  DefAC(AC_DH5, ALLIED, NAT_BRITISH, 1, 2, FALSE, 1,0, 1550,16000, 6,10,15,10,11,11,11, "De Havilland 5");
  DefBand(AC_DH5,0, 110,90,300); DefBand(AC_DH5,1, 100,80,200);
  DefBand(AC_DH5,2, 90,70,100);  DefBand(AC_DH5,3, 80,60,50);
  DefTex(AC_DH5, "DH5", 2);

  DefAC(AC_SPAD7, ALLIED, NAT_FRENCH, 1, 2, FALSE, 1,0, 1550,18000, 6,11,16,12,12,12,12, "S.P.A.D. VII");
  DefBand(AC_SPAD7,0, 120,90,300); DefBand(AC_SPAD7,1, 110,80,250);
  DefBand(AC_SPAD7,2, 110,70,200); DefBand(AC_SPAD7,3, 100,60,100);
  DefTex(AC_SPAD7, "SPAD", 7);

  DefAC(AC_SPAD13, ALLIED, NAT_FRENCH, 1, 2, FALSE, 2,0, 1600,22300, 6,11,16,12,12,12,12, "S.P.A.D. XIII");
  DefBand(AC_SPAD13,0, 130,100,400); DefBand(AC_SPAD13,1, 120,90,300);
  DefBand(AC_SPAD13,2, 120,80,250); DefBand(AC_SPAD13,3, 110,70,150);
  DefTex(AC_SPAD13, "SPAD", 7);

  DefAC(AC_NIEU17, ALLIED, NAT_FRENCH, 1, 2, FALSE, 1,0, 1350,17500, 6,10,14,10,10,10,10, "Nieuport 17");
  DefBand(AC_NIEU17,0, 100,100,400); DefBand(AC_NIEU17,1, 100,90,350);
  DefBand(AC_NIEU17,2, 90,80,300);   DefBand(AC_NIEU17,3, 80,70,200);
  DefTex(AC_NIEU17, "Nieuport17", 4);

  DefAC(AC_NIEU28, ALLIED, NAT_AMERICAN, 1, 2, FALSE, 2,0, 1400,19000, 6,11,15,11,11,11,11, "Nieuport 28");
  DefBand(AC_NIEU28,0, 130,100,350); DefBand(AC_NIEU28,1, 120,100,300);
  DefBand(AC_NIEU28,2, 120,90,250);  DefBand(AC_NIEU28,3, 110,80,200);
  DefTex(AC_NIEU28, "Nieuport28", 2);

  DefAC(AC_MSAI, ALLIED, NAT_FRENCH, 1, 1, FALSE, 2,0, 1500,23000, 6,11,15,11,11,11,11, "Morane-Saulnier AI");
  DefBand(AC_MSAI,0, 130,100,450); DefBand(AC_MSAI,1, 130,90,350);
  DefBand(AC_MSAI,2, 120,80,250);  DefBand(AC_MSAI,3, 110,80,150);
  DefTex(AC_MSAI, "Morane", 2);

  DefAC(AC_HANRIOT, ALLIED, NAT_ITALIAN, 1, 2, FALSE, 1,0, 1500,21000, 6,10,15,10,11,11,11, "Hanriot HD-1");
  DefBand(AC_HANRIOT,0, 110,100,350); DefBand(AC_HANRIOT,1, 100,90,300);
  DefBand(AC_HANRIOT,2, 90,80,200);   DefBand(AC_HANRIOT,3, 80,70,150);
  DefTex(AC_HANRIOT, "HanriotHD1", 3);

  DefAC(AC_DRI, GERMAN, NAT_GERMAN, 1, 3, FALSE, 2,0, 1450,19600, 6,10,14,10,11,12,11, "Fokker Dr.I");
  DefBand(AC_DRI,0, 110,110,450); DefBand(AC_DRI,1, 100,100,400);
  DefBand(AC_DRI,2, 90,90,300);   DefBand(AC_DRI,3, 80,80,200);
  DefTex(AC_DRI, "FokkerDr1", 4);

  DefAC(AC_DVII, GERMAN, NAT_GERMAN, 1, 2, FALSE, 2,0, 1500,22900, 6,11,16,12,12,13,12, "Fokker D.VII");
  DefBand(AC_DVII,0, 120,110,400); DefBand(AC_DVII,1, 120,110,350);
  DefBand(AC_DVII,2, 110,100,300); DefBand(AC_DVII,3, 100,90,200);
  DefTex(AC_DVII, "FokkerDVII", 5);

  DefAC(AC_BRISTOL, ALLIED, NAT_BRITISH, 2, 2, FALSE, 1,1, 1500,20000, 6,11,16,11,12,12,12, "Bristol F.2B");
  DefBand(AC_BRISTOL,0, 110,90,300); DefBand(AC_BRISTOL,1, 100,80,250);
  DefBand(AC_BRISTOL,2, 90,70,200);  DefBand(AC_BRISTOL,3, 90,70,100);
  DefTex(AC_BRISTOL, "Bristol", 3);

  DefAC(AC_DH4US, ALLIED, NAT_AMERICAN, 2, 2, TRUE, 2,2, 1400,15800, 7,11,16,11,12,12,12, "American D.H.4");
  DefBand(AC_DH4US,0, 120,90,250); DefBand(AC_DH4US,1, 110,80,200);
  DefBand(AC_DH4US,2, 110,80,150); DefBand(AC_DH4US,3, 100,70,100);
  DefTex(AC_DH4US, "DH4", 3);

  DefAC(AC_STRUTTER, ALLIED, NAT_BRITISH, 2, 1, TRUE, 1,1, 1400,15500, 6,10,15,10,10,10,10, "Sopwith 1 1/2 Strutter");
  DefBand(AC_STRUTTER,0, 100,70,250); DefBand(AC_STRUTTER,1, 90,70,150);
  DefBand(AC_STRUTTER,2, 80,60,100);  DefBand(AC_STRUTTER,3, 70,60,50);
  DefTex(AC_STRUTTER, "Sopwith1_5", 2);

  DefAC(AC_DH4GB, ALLIED, NAT_BRITISH, 2, 2, TRUE, 1,1, 1400,16000, 6,11,16,11,12,12,12, "De Havilland 4");
  DefBand(AC_DH4GB,0, 120,80,250); DefBand(AC_DH4GB,1, 110,80,200);
  DefBand(AC_DH4GB,2, 100,70,100); DefBand(AC_DH4GB,3, 90,60,50);
  DefTex(AC_DH4GB, "DH4", 3);

  selectable[0] := AC_SNIPE;    selectable[1] := AC_CAMEL;
  selectable[2] := AC_DOLPHIN;  selectable[3] := AC_DH5;
  selectable[4] := AC_SPAD7;    selectable[5] := AC_SPAD13;
  selectable[6] := AC_NIEU17;   selectable[7] := AC_NIEU28;
  selectable[8] := AC_MSAI;     selectable[9] := AC_HANRIOT
END InitAircraftTypes;

PROCEDURE InitDirs;
BEGIN
  dirDX[DIR_N]:=0;  dirDY[DIR_N]:=-1;
  dirDX[DIR_NE]:=1; dirDY[DIR_NE]:=-1;
  dirDX[DIR_E]:=1;  dirDY[DIR_E]:=0;
  dirDX[DIR_SE]:=1; dirDY[DIR_SE]:=1;
  dirDX[DIR_S]:=0;  dirDY[DIR_S]:=1;
  dirDX[DIR_SW]:=-1;dirDY[DIR_SW]:=1;
  dirDX[DIR_W]:=-1; dirDY[DIR_W]:=0;
  dirDX[DIR_NW]:=-1;dirDY[DIR_NW]:=-1
END InitDirs;

(* Hit Location Table, columns HEAD/SIDE/TAIL/TOP/BOTTOM, rows die 1..6 *)
PROCEDURE SetHit(roll, angle, loc : INTEGER);
BEGIN hitLocTab[angle][roll-1] := loc END SetHit;

PROCEDURE InitHitTable;
VAR a, r : INTEGER;
BEGIN
  FOR a := 0 TO 4 DO FOR r := 0 TO 5 DO
    pilotStar[a][r] := FALSE;  obsStar[a][r] := FALSE
  END END;

  SetHit(1,ANG_HEAD,LOC_RW);  SetHit(1,ANG_SIDE,LOC_E);   SetHit(1,ANG_TAIL,LOC_LW);
  SetHit(1,ANG_TOP,LOC_E);    SetHit(1,ANG_BOTTOM,LOC_E);

  SetHit(2,ANG_HEAD,LOC_CW);  SetHit(2,ANG_SIDE,LOC_FF);  SetHit(2,ANG_TAIL,LOC_LW);
  SetHit(2,ANG_TOP,LOC_LW);   SetHit(2,ANG_BOTTOM,LOC_RW);
  pilotStar[ANG_SIDE][1] := TRUE;

  SetHit(3,ANG_HEAD,LOC_E);   SetHit(3,ANG_SIDE,LOC_LWRW); SetHit(3,ANG_TAIL,LOC_T);
  SetHit(3,ANG_TOP,LOC_CW);   SetHit(3,ANG_BOTTOM,LOC_FF);
  obsStar[ANG_TAIL][2]   := TRUE;
  pilotStar[ANG_TOP][2]  := TRUE;
  pilotStar[ANG_BOTTOM][2] := TRUE;

  SetHit(4,ANG_HEAD,LOC_E);   SetHit(4,ANG_SIDE,LOC_RF);  SetHit(4,ANG_TAIL,LOC_CW);
  SetHit(4,ANG_TOP,LOC_RW);   SetHit(4,ANG_BOTTOM,LOC_LW);
  obsStar[ANG_SIDE][3]   := TRUE;
  pilotStar[ANG_TAIL][3] := TRUE;

  SetHit(5,ANG_HEAD,LOC_E);   SetHit(5,ANG_SIDE,LOC_RF);  SetHit(5,ANG_TAIL,LOC_RW);
  SetHit(5,ANG_TOP,LOC_RF);   SetHit(5,ANG_BOTTOM,LOC_RF);
  obsStar[ANG_TOP][4]    := TRUE;
  obsStar[ANG_BOTTOM][4] := TRUE;

  SetHit(6,ANG_HEAD,LOC_LW);  SetHit(6,ANG_SIDE,LOC_T);   SetHit(6,ANG_TAIL,LOC_RW);
  SetHit(6,ANG_TOP,LOC_T);    SetHit(6,ANG_BOTTOM,LOC_T)
END InitHitTable;

(* ════════════════════════════════════════════════════════════════════ *)
(*  Tutorial content                                                      *)
(* ════════════════════════════════════════════════════════════════════ *)

PROCEDURE TT(page : INTEGER; title : ARRAY OF CHAR; count : INTEGER);
BEGIN
  COPY(title, tutTitle[page]);
  tutLineCount[page] := count
END TT;

PROCEDURE TL(page, line : INTEGER; text : ARRAY OF CHAR);
BEGIN COPY(text, tutLines[page][line]) END TL;

PROCEDURE InitTutorial;
BEGIN
  TT(0, "OBJECTIVE", 5);
  TL(0,0, "You fly one Allied fighter against a German patrol.");
  TL(0,1, "Shoot down every enemy plane to win; if you are shot down, you lose.");
  TL(0,2, "The game proceeds in turns. Each turn every plane moves once, in an");
  TL(0,3, "order rolled by dice, then all that turn's attacks are resolved together.");
  TL(0,4, "The right-hand panel always shows what the current stage wants from you.");

  TT(1, "MOVEMENT ORDER & ALTITUDE", 5);
  TL(1,0, "Each turn planes are ordered by a 2-dice roll (two-seaters add +1).");
  TL(1,1, "A plane 2000+ feet below every other plane always moves first.");
  TL(1,2, "A plane that ended last turn on an enemy's tail auto-follows them.");
  TL(1,3, "ALTITUDE step: Up/Down climb or dive in 50ft steps, Enter locks it in.");
  TL(1,4, "Diving grants bonus movement: one extra square per full 100ft dived.");

  TT(2, "THROTTLE & MOVING", 6);
  TL(2,0, "THROTTLE step: Up/Down adjust +-10mph (capped by your turn speed).");
  TL(2,1, "Your squares this turn = throttle/10, plus any dive bonus -- and you");
  TL(2,2, "must use all of it, so plan your speed before you commit to Enter.");
  TL(2,3, "MOVE step: Left/Right turn 45 (once per square), Space/Enter advances.");
  TL(2,4, "I = Immelmann: reverse facing in place, costs 3 squares.");
  TL(2,5, "L = Loop: reverse position and keep facing, costs 4 squares.");

  TT(3, "ATTACKS & TARGETS", 5);
  TL(3,0, "After moving, if an enemy is in your forward gun arc within 500ft,");
  TL(3,1, "you may declare it as your target (Up/Down choose, Enter fires).");
  TL(3,2, "Two-seaters can also fire backward at planes in their rear arc.");
  TL(3,3, "All declared shots are resolved together once everyone has moved.");
  TL(3,4, "Each attack costs one burst of ammunition -- 15 bursts per plane.");

  TT(4, "DAMAGE", 5);
  TL(4,0, "A hit roll depends on range, then 1-6 hits are rolled, each landing");
  TL(4,1, "on a random section: engine, fuselage, tail, or a wing.");
  TL(4,2, "A plane is shot down when any one section reaches its damage limit.");
  TL(4,3, "Unlucky hits can also wound the pilot (shot down outright) or the");
  TL(4,4, "observer on a two-seater (rear gun disabled for the rest of the fight).");

  TT(5, "TIPS", 5);
  TL(5,0, "Get on an enemy's tail for the best shot -- and watch your own tail.");
  TL(5,1, "Diving trades altitude for speed and extra movement squares.");
  TL(5,2, "Climbing costs you speed options next turn but gains a height edge.");
  TL(5,3, "Don't run out of ammo: 15 bursts must last the whole fight.");
  TL(5,4, "Good hunting!")
END InitTutorial;

(* ════════════════════════════════════════════════════════════════════ *)
(*  Plane accessors                                                      *)
(* ════════════════════════════════════════════════════════════════════ *)

PROCEDURE HitMax(kind, loc : INTEGER) : INTEGER;
BEGIN
  CASE loc OF
    LOC_E:  RETURN acTypes[kind].hitE
  | LOC_FF: RETURN acTypes[kind].hitFF
  | LOC_RF: RETURN acTypes[kind].hitRF
  | LOC_T:  RETURN acTypes[kind].hitT
  | LOC_LW: RETURN acTypes[kind].hitLW
  | LOC_CW: RETURN acTypes[kind].hitCW
  | LOC_RW: RETURN acTypes[kind].hitRW
  END;
  RETURN 99
END HitMax;

PROCEDURE AddDamage(pi, loc, amount : INTEGER);
BEGIN
  CASE loc OF
    LOC_E:  INC(planes[pi].dmgE,  amount)
  | LOC_FF: INC(planes[pi].dmgFF, amount)
  | LOC_RF: INC(planes[pi].dmgRF, amount)
  | LOC_T:  INC(planes[pi].dmgT,  amount)
  | LOC_LW: INC(planes[pi].dmgLW, amount)
  | LOC_CW: INC(planes[pi].dmgCW, amount)
  | LOC_RW: INC(planes[pi].dmgRW, amount)
  END
END AddDamage;

PROCEDURE DamageAt(pi, loc : INTEGER) : INTEGER;
BEGIN
  CASE loc OF
    LOC_E:  RETURN planes[pi].dmgE
  | LOC_FF: RETURN planes[pi].dmgFF
  | LOC_RF: RETURN planes[pi].dmgRF
  | LOC_T:  RETURN planes[pi].dmgT
  | LOC_LW: RETURN planes[pi].dmgLW
  | LOC_CW: RETURN planes[pi].dmgCW
  | LOC_RW: RETURN planes[pi].dmgRW
  END;
  RETURN 0
END DamageAt;

PROCEDURE IsShotDown(pi : INTEGER) : BOOLEAN;
BEGIN
  RETURN planes[pi].pilotHit
    OR (DamageAt(pi,LOC_E)  >= HitMax(planes[pi].kind,LOC_E))
    OR (DamageAt(pi,LOC_FF) >= HitMax(planes[pi].kind,LOC_FF))
    OR (DamageAt(pi,LOC_RF) >= HitMax(planes[pi].kind,LOC_RF))
    OR (DamageAt(pi,LOC_T)  >= HitMax(planes[pi].kind,LOC_T))
    OR (DamageAt(pi,LOC_LW) >= HitMax(planes[pi].kind,LOC_LW))
    OR (DamageAt(pi,LOC_CW) >= HitMax(planes[pi].kind,LOC_CW))
    OR (DamageAt(pi,LOC_RW) >= HitMax(planes[pi].kind,LOC_RW))
END IsShotDown;

(* ════════════════════════════════════════════════════════════════════ *)
(*  Geometry: range, field of fire, attack angle                         *)
(* ════════════════════════════════════════════════════════════════════ *)

PROCEDURE RangeFeet(a, b : INTEGER) : INTEGER;
VAR sq : INTEGER;
BEGIN
  sq := ChebDist(planes[a].gx, planes[a].gy, planes[b].gx, planes[b].gy);
  RETURN sq * 100 + ABS(planes[a].alt - planes[b].alt)
END RangeFeet;

(* TRUE if `b` lies in `a`'s forward firing cone *)
PROCEDURE InForwardArc(a, b : INTEGER) : BOOLEAN;
VAR oct, astep : INTEGER;
BEGIN
  IF (planes[a].gx = planes[b].gx) & (planes[a].gy = planes[b].gy) THEN RETURN TRUE END;
  oct := OctantOf(planes[b].gx - planes[a].gx, planes[b].gy - planes[a].gy);
  astep := (oct - planes[a].dir + 800) MOD 8;
  RETURN (astep = 0) OR (astep = 1) OR (astep = 7)
END InForwardArc;

(* TRUE if `b` lies in `a`'s rear/flexible-gun cone (two-seaters only) *)
PROCEDURE InRearArc(a, b : INTEGER) : BOOLEAN;
VAR oct, astep : INTEGER;
BEGIN
  IF acTypes[planes[a].kind].seats < 2 THEN RETURN FALSE END;
  IF planes[a].obsHit THEN RETURN FALSE END;
  IF (planes[a].gx = planes[b].gx) & (planes[a].gy = planes[b].gy) THEN RETURN TRUE END;
  oct := OctantOf(planes[b].gx - planes[a].gx, planes[b].gy - planes[a].gy);
  astep := (oct - planes[a].dir + 800) MOD 8;
  RETURN (astep = 3) OR (astep = 4) OR (astep = 5)
END InRearArc;

PROCEDURE CanShoot(a, b : INTEGER) : BOOLEAN;
BEGIN
  RETURN (RangeFeet(a,b) <= 500) & (InForwardArc(a,b) OR InRearArc(a,b))
END CanShoot;

(* attacker `a` firing on target `b`: classify the angle of attack *)
PROCEDURE AttackAngle(a, b : INTEGER; VAR bstep : INTEGER) : INTEGER;
VAR oct : INTEGER;
BEGIN
  IF (planes[a].gx = planes[b].gx) & (planes[a].gy = planes[b].gy) THEN
    bstep := -1;
    IF planes[a].alt > planes[b].alt THEN RETURN ANG_TOP ELSE RETURN ANG_BOTTOM END
  END;
  oct := OctantOf(planes[a].gx - planes[b].gx, planes[a].gy - planes[b].gy);
  bstep := (oct - planes[b].dir + 800) MOD 8;
  IF (bstep=7) OR (bstep=0) OR (bstep=1) THEN RETURN ANG_HEAD
  ELSIF (bstep=3) OR (bstep=4) OR (bstep=5) THEN RETURN ANG_TAIL
  ELSE RETURN ANG_SIDE
  END
END AttackAngle;

(* good rear position for tailing: |alt diff| <= horizontal separation *)
PROCEDURE GoodRearPosition(a, b : INTEGER) : BOOLEAN;
VAR sq : INTEGER;
BEGIN
  sq := ChebDist(planes[a].gx, planes[a].gy, planes[b].gx, planes[b].gy);
  RETURN ABS(planes[a].alt - planes[b].alt) <= sq * 100
END GoodRearPosition;

PROCEDURE CanTail(a, b : INTEGER) : BOOLEAN;
VAR bstep, ang : INTEGER;
BEGIN
  ang := AttackAngle(a, b, bstep);
  RETURN (ang = ANG_TAIL) & (RangeFeet(a,b) <= 400) & GoodRearPosition(a,b)
END CanTail;

(* ════════════════════════════════════════════════════════════════════ *)
(*  Combat resolution                                                    *)
(* ════════════════════════════════════════════════════════════════════ *)

PROCEDURE LocName(loc : INTEGER; VAR s : ARRAY OF CHAR);
BEGIN
  CASE loc OF
    LOC_E:  COPY("engine", s)
  | LOC_FF: COPY("fwd fuselage", s)
  | LOC_RF: COPY("rear fuselage", s)
  | LOC_T:  COPY("tail", s)
  | LOC_LW: COPY("left wing", s)
  | LOC_CW: COPY("center wing", s)
  | LOC_RW: COPY("right wing", s)
  ELSE COPY("?", s)
  END
END LocName;

PROCEDURE ResolveShot(a, b : INTEGER);
VAR
  rf, band, thresh, roll, hits, i, loc, bstep, ang : INTEGER;
  woundRoll1, woundRoll2 : INTEGER;
  msg, ns, loc1 : ARRAY 72 OF CHAR;
BEGIN
  DEC(planes[a].ammo);
  rf := RangeFeet(a,b);
  band := IClamp((rf - 50) DIV 100, 0, 4);
  thresh := 5 - band;
  roll := D6();

  msg := planes[a].label;  Strings.Append(" fires on ", msg);  Strings.Append(planes[b].label, msg);

  IF roll > thresh THEN
    Strings.Append(" -- miss.", msg);
    AppendLog(msg);
    RETURN
  END;

  hits := D6();
  Strings.Append(" -- hit! ", msg);
  Strings.IntToStr(hits, ns);  Strings.Append(ns, msg);  Strings.Append(" dmg", msg);
  AppendLog(msg);

  ang := AttackAngle(a, b, bstep);
  FOR i := 1 TO hits DO
    roll := D6();
    loc := hitLocTab[ang][roll-1];
    IF loc = LOC_LWRW THEN
      IF (bstep = 2) THEN loc := LOC_RW ELSE loc := LOC_LW END
    END;
    AddDamage(b, loc, 1);
    LocName(loc, loc1);
    msg := "  -> ";  Strings.Append(loc1, msg);
    AppendLog(msg);

    IF (ang = ANG_HEAD) & (loc = LOC_CW) THEN
      woundRoll1 := D6();
      IF woundRoll1 <= 2 THEN
        planes[b].pilotHit := TRUE;
        AppendLog("  PILOT HIT (head-on)!")
      END
    ELSIF pilotStar[ang][roll-1] THEN
      woundRoll1 := D6();  woundRoll2 := D6();
      IF (woundRoll1 = 1) & (woundRoll2 = 1) THEN
        planes[b].pilotHit := TRUE;
        AppendLog("  PILOT HIT!")
      END
    ELSIF obsStar[ang][roll-1] & (acTypes[planes[b].kind].seats = 2) THEN
      woundRoll1 := D6();  woundRoll2 := D6();
      IF (woundRoll1 = 1) & (woundRoll2 = 1) THEN
        planes[b].obsHit := TRUE;
        AppendLog("  Observer hit -- rear gun disabled")
      END
    END
  END
END ResolveShot;

PROCEDURE FireAllDeclared;
VAR i, tgt : INTEGER; msg : ARRAY 64 OF CHAR;
BEGIN
  FOR i := 0 TO nplanes - 1 DO
    IF planes[i].alive & (planes[i].target >= 0) & ~planes[i].fired & (planes[i].ammo > 0) THEN
      tgt := planes[i].target;
      IF planes[tgt].alive & CanShoot(i, tgt) THEN
        ResolveShot(i, tgt);
        planes[i].fired := TRUE
      END
    END
  END;

  FOR i := 0 TO nplanes - 1 DO
    IF planes[i].alive & IsShotDown(i) THEN
      planes[i].alive := FALSE;
      msg := planes[i].label;  Strings.Append(" is SHOT DOWN!", msg);
      AppendLog(msg)
    END
  END
END FireAllDeclared;

(* ════════════════════════════════════════════════════════════════════ *)
(*  Movement                                                             *)
(* ════════════════════════════════════════════════════════════════════ *)

PROCEDURE FindArcTarget(pi : INTEGER) : INTEGER;
VAR i, best, bestRange, rf : INTEGER;
BEGIN
  best := -1;  bestRange := 9999;
  FOR i := 0 TO nplanes - 1 DO
    IF (i # pi) & planes[i].alive & (planes[i].side # planes[pi].side) & CanShoot(pi, i) THEN
      rf := RangeFeet(pi, i);
      IF rf < bestRange THEN bestRange := rf; best := i END
    END
  END;
  RETURN best
END FindArcTarget;

PROCEDURE NearestEnemy(pi : INTEGER) : INTEGER;
VAR i, best, bestD, d : INTEGER;
BEGIN
  best := -1;  bestD := 99999;
  FOR i := 0 TO nplanes - 1 DO
    IF (i # pi) & planes[i].alive & (planes[i].side # planes[pi].side) THEN
      d := ChebDist(planes[pi].gx, planes[pi].gy, planes[i].gx, planes[i].gy);
      IF d < bestD THEN bestD := d; best := i END
    END
  END;
  RETURN best
END NearestEnemy;

PROCEDURE UpdateTailFlag(pi : INTEGER);
VAR i : INTEGER;
BEGIN
  planes[pi].tailing := -1;
  FOR i := 0 TO nplanes - 1 DO
    IF (i # pi) & planes[i].alive & (planes[i].side # planes[pi].side) & CanTail(pi, i) THEN
      planes[pi].tailing := i
    END
  END
END UpdateTailFlag;

(* Begin the movement-order phase for a fresh game turn. *)
PROCEDURE BeginTurn;
VAR i, j, n, best, bestRoll, tmp : INTEGER;
    used : ARRAY MAXPLANES OF BOOLEAN;
    roll : ARRAY MAXPLANES OF INTEGER;
    isLow : ARRAY MAXPLANES OF BOOLEAN;
BEGIN
  INC(turnNum);

  FOR i := 0 TO nplanes - 1 DO
    used[i] := ~planes[i].alive OR (planes[i].tailing >= 0);
    roll[i] := D2D6();
    IF acTypes[planes[i].kind].nonFighter THEN INC(roll[i]) END
  END;
  (* a plane is "low" if it is >= 2000ft below every other airborne plane *)
  FOR i := 0 TO nplanes - 1 DO
    isLow[i] := FALSE;
    IF planes[i].alive THEN
      isLow[i] := TRUE;
      FOR j := 0 TO nplanes - 1 DO
        IF (j # i) & planes[j].alive & (planes[i].alt > planes[j].alt - 2000) THEN
          isLow[i] := FALSE
        END
      END
    END
  END;

  n := 0;
  (* pass 1: low-altitude planes first, highest roll first *)
  WHILE TRUE DO
    best := -1;  bestRoll := -1;
    FOR i := 0 TO nplanes - 1 DO
      IF ~used[i] & isLow[i] & (roll[i] > bestRoll) THEN best := i; bestRoll := roll[i] END
    END;
    IF best < 0 THEN EXIT END;
    used[best] := TRUE;  moveOrder[n] := best;  INC(n)
  END;
  (* pass 2: everyone else, highest roll first *)
  WHILE TRUE DO
    best := -1;  bestRoll := -1;
    FOR i := 0 TO nplanes - 1 DO
      IF ~used[i] & planes[i].alive & (roll[i] > bestRoll) THEN best := i; bestRoll := roll[i] END
    END;
    IF best < 0 THEN EXIT END;
    used[best] := TRUE;  moveOrder[n] := best;  INC(n)
  END;
  (* splice tailing planes in immediately after their target *)
  FOR i := 0 TO nplanes - 1 DO
    IF planes[i].alive & (planes[i].tailing >= 0) & planes[planes[i].tailing].alive THEN
      j := 0;
      WHILE (j < n) & (moveOrder[j] # planes[i].tailing) DO INC(j) END;
      IF j < n THEN
        FOR tmp := n TO j + 2 BY -1 DO moveOrder[tmp] := moveOrder[tmp-1] END;
        moveOrder[j+1] := i;  INC(n)
      ELSE
        moveOrder[n] := i;  INC(n)
      END
    END
  END;

  FOR i := 0 TO nplanes - 1 DO
    planes[i].target := -1;  planes[i].fired := FALSE
  END;

  curPos := 0;
  substage := SUB_NEXT
END BeginTurn;

PROCEDURE StartPlaneMove(pi : INTEGER);
BEGIN
  planes[pi].startAlt := planes[pi].alt;
  curBand := AltBand(planes[pi].startAlt);
  pendingAltDelta := 0;
  substage := SUB_ALT
END StartPlaneMove;

PROCEDURE LockAltitude(pi : INTEGER);
BEGIN
  planes[pi].alt := planes[pi].alt + pendingAltDelta;
  IF pendingAltDelta < 0 THEN diveBonus := (-pendingAltDelta) DIV 100 ELSE diveBonus := 0 END;
  pendingThrottle := IClamp(planes[pi].throttle,
                            IMax(MINSPEED, planes[pi].throttle - THROTTLE_STEP),
                            IMin(acTypes[planes[pi].kind].turn[curBand], planes[pi].throttle + THROTTLE_STEP));
  substage := SUB_THROTTLE
END LockAltitude;

PROCEDURE LockThrottle(pi : INTEGER);
BEGIN
  planes[pi].throttle := pendingThrottle;
  budget := pendingThrottle DIV 10 + diveBonus;
  turnedThisSquare := FALSE;
  usedSpecial := FALSE;
  substage := SUB_STEP
END LockThrottle;

PROCEDURE StepForward(pi : INTEGER);
BEGIN
  planes[pi].gx := planes[pi].gx + FLT(dirDX[planes[pi].dir]);
  planes[pi].gy := planes[pi].gy + FLT(dirDY[planes[pi].dir]);
  DEC(budget);
  turnedThisSquare := FALSE
END StepForward;

PROCEDURE DoImmelmann(pi : INTEGER);
VAR nd : INTEGER;
BEGIN
  nd := Opposite(planes[pi].dir);
  planes[pi].gx := planes[pi].gx + FLT(dirDX[nd]);
  planes[pi].gy := planes[pi].gy + FLT(dirDY[nd]);
  planes[pi].dir := nd;
  DEC(budget, 3);
  usedSpecial := TRUE
END DoImmelmann;

PROCEDURE DoLoop(pi : INTEGER);
VAR od : INTEGER;
BEGIN
  od := Opposite(planes[pi].dir);
  planes[pi].gx := planes[pi].gx + FLT(dirDX[od]);
  planes[pi].gy := planes[pi].gy + FLT(dirDY[od]);
  DEC(budget, 4);
  usedSpecial := TRUE
END DoLoop;

PROCEDURE BeginTargetStage(pi : INTEGER);
VAR i : INTEGER;
BEGIN
  targetCount := 0;
  FOR i := 0 TO nplanes - 1 DO
    IF (i # pi) & planes[i].alive & (planes[i].side # planes[pi].side) & CanShoot(pi, i) THEN
      targetList[targetCount] := i;  INC(targetCount)
    END
  END;
  UpdateTailFlag(pi);
  IF (targetCount > 0) & planes[pi].isPlayer THEN
    targetSel := 0;
    substage := SUB_TARGET
  ELSE
    IF targetCount > 0 THEN planes[pi].target := targetList[0] END;
    substage := SUB_NEXT
  END
END BeginTargetStage;

(* Fully automatic move for an AI-controlled plane. *)
PROCEDURE AIMove(pi : INTEGER);
VAR
  tgt, band, wantDir, diff, step, delta, cap, lo, hi : INTEGER;
BEGIN
  planes[pi].startAlt := planes[pi].alt;
  band := AltBand(planes[pi].startAlt);
  tgt := NearestEnemy(pi);

  delta := 0;
  IF tgt >= 0 THEN
    IF planes[pi].alt < planes[tgt].alt - 100 THEN
      delta := IMin(acTypes[planes[pi].kind].climb[band], planes[tgt].alt - planes[pi].alt)
    ELSIF planes[pi].alt > planes[tgt].alt + 100 THEN
      delta := -IMin(acTypes[planes[pi].kind].maxDive, planes[pi].alt - planes[tgt].alt)
    END
  END;
  delta := (delta DIV 50) * 50;
  IF planes[pi].alt + delta > acTypes[planes[pi].kind].ceiling THEN delta := 0 END;
  planes[pi].alt := planes[pi].alt + delta;
  IF delta < 0 THEN diveBonus := (-delta) DIV 100 ELSE diveBonus := 0 END;

  cap := acTypes[planes[pi].kind].turn[band];
  lo := IMax(MINSPEED, planes[pi].throttle - THROTTLE_STEP);
  hi := IMin(cap, planes[pi].throttle + THROTTLE_STEP);
  planes[pi].throttle := IClamp(cap, lo, hi);
  budget := planes[pi].throttle DIV 10 + diveBonus;

  FOR step := 1 TO budget DO
    IF tgt >= 0 THEN
      wantDir := OctantOf(planes[tgt].gx - planes[pi].gx, planes[tgt].gy - planes[pi].gy);
      IF wantDir >= 0 THEN
        diff := (wantDir - planes[pi].dir + 800) MOD 8;
        IF (diff >= 1) & (diff <= 3) THEN planes[pi].dir := (planes[pi].dir + 1) MOD 8
        ELSIF (diff >= 5) & (diff <= 7) THEN planes[pi].dir := (planes[pi].dir + 7) MOD 8
        END
      END
    END;
    planes[pi].gx := planes[pi].gx + FLT(dirDX[planes[pi].dir]);
    planes[pi].gy := planes[pi].gy + FLT(dirDY[planes[pi].dir])
  END;

  BeginTargetStage(pi)
END AIMove;

PROCEDURE AdvanceToNextPlane;
VAR pi : INTEGER; done : BOOLEAN;
BEGIN
  done := FALSE;
  WHILE ~done DO
    IF curPos >= nplanes THEN
      substage := SUB_FIRE;
      done := TRUE
    ELSE
      pi := moveOrder[curPos];
      IF ~planes[pi].alive THEN
        INC(curPos)
      ELSIF planes[pi].isPlayer THEN
        activePlane := pi;
        INC(curPos);
        StartPlaneMove(pi);
        done := TRUE
      ELSE
        activePlane := pi;
        INC(curPos);
        AIMove(pi);
        done := TRUE
      END
    END
  END
END AdvanceToNextPlane;

(* ════════════════════════════════════════════════════════════════════ *)
(*  Game / scenario setup                                                *)
(* ════════════════════════════════════════════════════════════════════ *)

PROCEDURE MakePlane(pi, kind, side : INTEGER; gx, gy : REAL; dir, alt : INTEGER;
                     isPlayer : BOOLEAN; lbl : ARRAY OF CHAR);
BEGIN
  planes[pi].kind     := kind;
  planes[pi].side     := side;
  planes[pi].alive    := TRUE;
  planes[pi].isPlayer := isPlayer;
  planes[pi].gx       := gx;  planes[pi].gy := gy;
  planes[pi].dir      := dir;
  planes[pi].alt      := alt;
  planes[pi].throttle := acTypes[kind].turn[AltBand(alt)];
  planes[pi].ammo     := STARTAMMO;
  planes[pi].dmgE  := 0; planes[pi].dmgFF := 0; planes[pi].dmgRF := 0;
  planes[pi].dmgT  := 0; planes[pi].dmgLW := 0; planes[pi].dmgCW := 0; planes[pi].dmgRW := 0;
  planes[pi].pilotHit := FALSE;  planes[pi].obsHit := FALSE;
  planes[pi].tailing  := -1;     planes[pi].target := -1;  planes[pi].fired := FALSE;
  planes[pi].texVariant := Random.Int(acTypes[kind].texCount);
  COPY(lbl, planes[pi].label)
END MakePlane;

PROCEDURE InitBattle;
VAR i, ekind : INTEGER;
BEGIN
  nplanes := 1 + NENEMIES;
  playerIdx := 0;
  MakePlane(0, selectable[selType], ALLIED, 0.0, 0.0, DIR_N, 10000, TRUE, "You");

  FOR i := 1 TO NENEMIES DO
    IF ODD(Random.Int(2)) THEN ekind := AC_DRI ELSE ekind := AC_DVII END;
    MakePlane(i, ekind, GERMAN, FLT(i*4 - 6), -9.0, DIR_S, 10000 + i*50, FALSE, "Enemy")
  END;

  msgCount := 0;  msgHead := 0;
  AppendLog("Enemy patrol spotted -- good hunting!");
  camX := planes[0].gx;  camY := planes[0].gy;

  BeginTurn
END InitBattle;

(* ════════════════════════════════════════════════════════════════════ *)
(*  Input / update                                                       *)
(* ════════════════════════════════════════════════════════════════════ *)

PROCEDURE UpdateTitle;
BEGIN
  IF Raylib.IsKeyPressed(Raylib.KeyEnter) = 1 THEN
    stage := ST_BRIEF;  selType := 0
  ELSIF Raylib.IsKeyPressed(ORD("T")) = 1 THEN
    stage := ST_TUTORIAL;  tutPage := 0
  END
END UpdateTitle;

(* NOTE: raylib's default exit key is Esc, and this binding doesn't expose
   SetExitKey to change that -- pressing Esc always closes the whole window
   (see WindowShouldClose), so Esc is never used here as an in-screen
   "back"/"cancel" key, only Left/Right/Enter. *)
PROCEDURE UpdateTutorial;
BEGIN
  IF (Raylib.IsKeyPressed(Raylib.KeyRight) = 1) OR (Raylib.IsKeyPressed(Raylib.KeyEnter) = 1) THEN
    IF tutPage < NTUTPAGES - 1 THEN INC(tutPage) ELSE stage := ST_TITLE END
  ELSIF Raylib.IsKeyPressed(Raylib.KeyLeft) = 1 THEN
    IF tutPage > 0 THEN DEC(tutPage) ELSE stage := ST_TITLE END
  END
END UpdateTutorial;

PROCEDURE UpdateBrief;
BEGIN
  IF Raylib.IsKeyPressed(Raylib.KeyUp) = 1 THEN
    selType := (selType - 1 + NSELECTABLE) MOD NSELECTABLE
  ELSIF Raylib.IsKeyPressed(Raylib.KeyDown) = 1 THEN
    selType := (selType + 1) MOD NSELECTABLE
  ELSIF Raylib.IsKeyPressed(Raylib.KeyEnter) = 1 THEN
    InitBattle;
    stage := ST_PLAY
  END
END UpdateBrief;

PROCEDURE UpdateAlt(pi : INTEGER);
VAR band, maxAlt : INTEGER;
BEGIN
  band := curBand;
  IF Raylib.IsKeyPressed(Raylib.KeyUp) = 1 THEN
    IF pendingAltDelta + 50 <= acTypes[planes[pi].kind].climb[band] THEN
      maxAlt := acTypes[planes[pi].kind].ceiling;
      IF planes[pi].alt + pendingAltDelta + 50 <= maxAlt THEN INC(pendingAltDelta, 50) END
    END
  ELSIF Raylib.IsKeyPressed(Raylib.KeyDown) = 1 THEN
    IF pendingAltDelta - 50 >= -acTypes[planes[pi].kind].maxDive THEN
      IF planes[pi].alt + pendingAltDelta - 50 >= 0 THEN DEC(pendingAltDelta, 50) END
    END
  ELSIF Raylib.IsKeyPressed(Raylib.KeyEnter) = 1 THEN
    LockAltitude(pi)
  END
END UpdateAlt;

PROCEDURE UpdateThrottle(pi : INTEGER);
VAR lo, hi : INTEGER;
BEGIN
  lo := IMax(MINSPEED, planes[pi].throttle - THROTTLE_STEP);
  hi := IMin(acTypes[planes[pi].kind].turn[curBand], planes[pi].throttle + THROTTLE_STEP);
  IF Raylib.IsKeyPressed(Raylib.KeyUp) = 1 THEN
    pendingThrottle := IMin(hi, pendingThrottle + 10)
  ELSIF Raylib.IsKeyPressed(Raylib.KeyDown) = 1 THEN
    pendingThrottle := IMax(lo, pendingThrottle - 10)
  ELSIF Raylib.IsKeyPressed(Raylib.KeyEnter) = 1 THEN
    LockThrottle(pi)
  END
END UpdateThrottle;

PROCEDURE UpdateStep(pi : INTEGER);
BEGIN
  IF Raylib.IsKeyPressed(Raylib.KeyLeft) = 1 THEN
    IF ~turnedThisSquare THEN
      planes[pi].dir := (planes[pi].dir + 7) MOD 8;  turnedThisSquare := TRUE
    END
  ELSIF Raylib.IsKeyPressed(Raylib.KeyRight) = 1 THEN
    IF ~turnedThisSquare THEN
      planes[pi].dir := (planes[pi].dir + 1) MOD 8;  turnedThisSquare := TRUE
    END
  ELSIF (Raylib.IsKeyPressed(ORD("I")) = 1) & ~usedSpecial & (budget >= 3) THEN
    DoImmelmann(pi)
  ELSIF (Raylib.IsKeyPressed(ORD("L")) = 1) & ~usedSpecial & (budget >= 4) THEN
    DoLoop(pi)
  ELSIF (Raylib.IsKeyPressed(Raylib.KeySpace) = 1) OR (Raylib.IsKeyPressed(Raylib.KeyEnter) = 1) THEN
    IF budget > 0 THEN StepForward(pi) END
  END;
  IF budget <= 0 THEN BeginTargetStage(pi) END
END UpdateStep;

PROCEDURE UpdateTargetSel(pi : INTEGER);
BEGIN
  IF Raylib.IsKeyPressed(Raylib.KeyUp) = 1 THEN
    targetSel := (targetSel - 1 + targetCount) MOD targetCount
  ELSIF Raylib.IsKeyPressed(Raylib.KeyDown) = 1 THEN
    targetSel := (targetSel + 1) MOD targetCount
  ELSIF Raylib.IsKeyPressed(Raylib.KeyEnter) = 1 THEN
    planes[pi].target := targetList[targetSel];
    substage := SUB_NEXT
  ELSIF Raylib.IsKeyPressed(Raylib.KeyBackspace) = 1 THEN
    (* NOTE: not Esc -- raylib's default exit key is Esc and this binding
       can't change that, so Esc always closes the whole window rather
       than just declining to fire. *)
    substage := SUB_NEXT
  END
END UpdateTargetSel;

PROCEDURE CheckVictory;
VAR i : INTEGER; enemiesLeft : INTEGER;
BEGIN
  IF ~planes[playerIdx].alive THEN
    COPY("You were shot down.", winMsg);
    stage := ST_OVER;  RETURN
  END;
  enemiesLeft := 0;
  FOR i := 0 TO nplanes - 1 DO
    IF planes[i].alive & (planes[i].side # planes[playerIdx].side) THEN INC(enemiesLeft) END
  END;
  IF enemiesLeft = 0 THEN
    COPY("Enemy patrol destroyed -- you win!", winMsg);
    stage := ST_OVER
  END
END CheckVictory;

PROCEDURE UpdatePlay;
BEGIN
  CASE substage OF
    SUB_ORDER:
      BeginTurn
  | SUB_NEXT:
      AdvanceToNextPlane
  | SUB_ALT:
      UpdateAlt(activePlane)
  | SUB_THROTTLE:
      UpdateThrottle(activePlane)
  | SUB_STEP:
      UpdateStep(activePlane)
  | SUB_TARGET:
      UpdateTargetSel(activePlane)
  | SUB_FIRE:
      FireAllDeclared;
      CheckVictory;
      IF stage = ST_PLAY THEN
        curPos := 0;
        substage := SUB_ORDER
      END
  ELSE
  END;

  IF (stage = ST_PLAY) & planes[playerIdx].alive THEN
    camX := planes[playerIdx].gx;  camY := planes[playerIdx].gy
  END
END UpdatePlay;

PROCEDURE UpdateOver;
BEGIN
  IF Raylib.IsKeyPressed(Raylib.KeyEnter) = 1 THEN stage := ST_TITLE END
END UpdateOver;

(* ════════════════════════════════════════════════════════════════════ *)
(*  Rendering                                                            *)
(* ════════════════════════════════════════════════════════════════════ *)

PROCEDURE ScreenX(gx : REAL) : INTEGER;
BEGIN RETURN PLAYW DIV 2 + FLOOR((gx - camX) * CELL) END ScreenX;

PROCEDURE ScreenY(gy : REAL) : INTEGER;
BEGIN RETURN H DIV 2 + FLOOR((gy - camY) * CELL) END ScreenY;

PROCEDURE DrawGrid;
VAR i, gxi, gyi, sx, sy : INTEGER;
BEGIN
  gxi := FLOOR(camX) - 20;  gyi := FLOOR(camY) - 15;
  FOR i := 0 TO 40 DO
    sx := ScreenX(FLT(gxi + i));
    IF (sx >= 0) & (sx <= PLAYW) THEN Raylib.DrawLine(sx, 0, sx, H, cDGray) END
  END;
  FOR i := 0 TO 30 DO
    sy := ScreenY(FLT(gyi + i));
    IF (sy >= 0) & (sy <= H) THEN Raylib.DrawLine(0, sy, PLAYW, sy, cDGray) END
  END
END DrawGrid;

PROCEDURE DrawPlaneIcon(px, py, dir, wings, side : INTEGER; sizePx : REAL; dead : BOOLEAN);
VAR fx, fy, rx, ry, norm : REAL;
    nx, ny, tx, ty, wx1, wy1, wx2, wy2, wingPos : REAL;
    col, roundCol : INTEGER; i : INTEGER;
BEGIN
  fx := FLT(dirDX[dir]);  fy := FLT(dirDY[dir]);
  norm := Math.sqrt(fx*fx + fy*fy);
  fx := fx / norm;  fy := fy / norm;
  rx := fy;  ry := -fx;

  IF dead THEN col := cDGray
  ELSIF side = ALLIED THEN col := cLGray
  ELSE col := cOrange
  END;

  nx := FLT(px) + fx*sizePx;         ny := FLT(py) + fy*sizePx;
  tx := FLT(px) - fx*sizePx*0.9;     ty := FLT(py) - fy*sizePx*0.9;
  Raylib.DrawLineEx(tx, ty, nx, ny, 3.0, col);

  FOR i := 0 TO wings - 1 DO
    wingPos := sizePx*0.1 - (FLT(i) - FLT(wings-1)*0.5) * sizePx*0.55;
    wx1 := FLT(px) + fx*wingPos - rx*sizePx*0.85;
    wy1 := FLT(py) + fy*wingPos - ry*sizePx*0.85;
    wx2 := FLT(px) + fx*wingPos + rx*sizePx*0.85;
    wy2 := FLT(py) + fy*wingPos + ry*sizePx*0.85;
    Raylib.DrawLineEx(wx1, wy1, wx2, wy2, 3.0, col)
  END;

  IF ~dead THEN
    IF side = ALLIED THEN roundCol := cBlue ELSE roundCol := cRed END;
    Raylib.DrawCircle(px, py, sizePx*0.2, roundCol)
  END
END DrawPlaneIcon;

PROCEDURE NationLabel(nation : INTEGER; VAR s : ARRAY OF CHAR);
BEGIN
  CASE nation OF
    NAT_BRITISH:  COPY("British", s)
  | NAT_FRENCH:   COPY("French", s)
  | NAT_AMERICAN: COPY("American", s)
  | NAT_GERMAN:   COPY("German", s)
  | NAT_ITALIAN:  COPY("Italian", s)
  ELSE COPY("?", s)
  END
END NationLabel;

PROCEDURE DrawDamageBar(x, y, w : INTEGER; label : ARRAY OF CHAR; dmg, maxv : INTEGER);
VAR filled, fw, tw : INTEGER; col : INTEGER; s : ARRAY 8 OF CHAR;
BEGIN
  Raylib.DrawText(label, x, y, 12, cWhite);
  Raylib.DrawRectangleLines(x + 60, y, w, 12, cWhite);
  IF maxv > 0 THEN fw := (dmg * w) DIV maxv ELSE fw := 0 END;
  IF fw > w THEN fw := w END;
  IF dmg >= maxv THEN col := cRed ELSIF dmg > 0 THEN col := cYellow ELSE col := cGreen END;
  IF fw > 0 THEN Raylib.DrawRectangle(x + 60, y, fw, 12, col) END
END DrawDamageBar;

PROCEDURE DrawHUD;
VAR y, i : INTEGER; s, ns : ARRAY 80 OF CHAR; p : Plane; at : AircraftType;
BEGIN
  Raylib.DrawRectangle(PANELX, 0, PANELW, H, cBlack);
  Raylib.DrawLine(PANELX, 0, PANELX, H, cLGray);

  p := planes[playerIdx];  at := acTypes[p.kind];
  y := 10;
  Raylib.DrawText(at.name, PANELX + 8, y, 18, cGold);  INC(y, 26);

  s := "Turn "; Strings.IntToStr(turnNum, ns); Strings.Append(ns, s);
  Raylib.DrawText(s, PANELX + 8, y, 14, cWhite);  INC(y, 20);

  s := "Altitude: "; Strings.IntToStr(p.alt, ns); Strings.Append(ns, s); Strings.Append(" ft", s);
  Raylib.DrawText(s, PANELX + 8, y, 14, cWhite);  INC(y, 18);

  s := "Throttle: "; Strings.IntToStr(p.throttle, ns); Strings.Append(ns, s); Strings.Append(" mph", s);
  Raylib.DrawText(s, PANELX + 8, y, 14, cWhite);  INC(y, 18);

  s := "Ammo: "; Strings.IntToStr(p.ammo, ns); Strings.Append(ns, s); Strings.Append(" / 15", s);
  Raylib.DrawText(s, PANELX + 8, y, 14, cWhite);  INC(y, 24);

  IF p.pilotHit THEN Raylib.DrawText("PILOT WOUNDED", PANELX + 8, y, 14, cRed); INC(y, 20) END;
  IF p.obsHit THEN Raylib.DrawText("OBSERVER DOWN", PANELX + 8, y, 14, cRed); INC(y, 20) END;

  Raylib.DrawText("Damage:", PANELX + 8, y, 14, cWhite);  INC(y, 18);
  DrawDamageBar(PANELX+8, y, 130, "Engine", p.dmgE,  at.hitE);  INC(y, 16);
  DrawDamageBar(PANELX+8, y, 130, "FwdFus", p.dmgFF, at.hitFF); INC(y, 16);
  DrawDamageBar(PANELX+8, y, 130, "RearFu", p.dmgRF, at.hitRF); INC(y, 16);
  DrawDamageBar(PANELX+8, y, 130, "Tail",   p.dmgT,  at.hitT);  INC(y, 16);
  DrawDamageBar(PANELX+8, y, 130, "L.Wing", p.dmgLW, at.hitLW); INC(y, 16);
  DrawDamageBar(PANELX+8, y, 130, "C.Wing", p.dmgCW, at.hitCW); INC(y, 16);
  DrawDamageBar(PANELX+8, y, 130, "R.Wing", p.dmgRW, at.hitRW); INC(y, 22);

  CASE substage OF
    SUB_ALT:      s := "ALTITUDE: Up/Dn adjust, Enter locks"
  | SUB_THROTTLE: s := "THROTTLE: Up/Dn adjust, Enter locks"
  | SUB_STEP:     s := "MOVE: Left/Right turn, Space steps, I/L maneuvers"
  | SUB_TARGET:   s := "TARGET: Up/Dn choose, Enter fires, Backspace holds"
  ELSE s := ""
  END;
  IF (s[0] # 0X) & planes[activePlane].isPlayer THEN
    Raylib.DrawText(s, PANELX + 8, y, 12, cSky)
  END;
  INC(y, 24);

  IF substage = SUB_STEP THEN
    s := "Squares left: "; Strings.IntToStr(budget, ns); Strings.Append(ns, s);
    Raylib.DrawText(s, PANELX + 8, y, 14, cSky); INC(y, 20)
  END;

  IF substage = SUB_TARGET THEN
    FOR i := 0 TO targetCount - 1 DO
      s := "";
      IF i = targetSel THEN Strings.Append("> ", s) ELSE Strings.Append("  ", s) END;
      Strings.Append(planes[targetList[i]].label, s);
      Strings.Append(" (", s);
      Strings.IntToStr(RangeFeet(playerIdx, targetList[i]), ns);
      Strings.Append(ns, s); Strings.Append("ft)", s);
      Raylib.DrawText(s, PANELX + 8, y, 13, cYellow); INC(y, 16)
    END;
    INC(y, 8)
  END;

  Raylib.DrawLine(PANELX + 4, y, W - 4, y, cLGray);  INC(y, 10);
  Raylib.DrawText("Flight log:", PANELX + 8, y, 13, cLGray);  INC(y, 18);
  FOR i := 0 TO msgCount - 1 DO
    Raylib.DrawText(msgLog[(msgHead - msgCount + i + MAXLOG*4) MOD MAXLOG], PANELX + 8, y, 12, cWhite);
    INC(y, 15)
  END
END DrawHUD;

PROCEDURE DrawPlay;
VAR i, sx, sy, tint : INTEGER; p : Plane;
BEGIN
  Raylib.ClearBackground(cSky);
  DrawGrid;
  FOR i := 0 TO nplanes - 1 DO
    p := planes[i];
    IF p.alive OR (i = playerIdx) THEN
      sx := ScreenX(p.gx);  sy := ScreenY(p.gy);
      IF p.alive THEN tint := cWhite ELSE tint := cDGray END;
      IF ~DrawSprite(p.kind, p.texVariant, p.dir, sx, sy, 34.0, tint) THEN
        DrawPlaneIcon(sx, sy, p.dir, acTypes[p.kind].wings, p.side, 14.0, ~p.alive)
      END
    END
  END;
  DrawHUD
END DrawPlay;

PROCEDURE FitTexture(tex : Raylib.Texture; dx, dy, dw, dh : INTEGER);
BEGIN
  Raylib.DrawTexturePro(tex, 0, 0, Raylib.TextureWidth(tex), Raylib.TextureHeight(tex), dx, dy, dw, dh, cWhite)
END FitTexture;

PROCEDURE DrawTitle;
VAR tw : INTEGER;
BEGIN
  Raylib.ClearBackground(cBlack);
  IF haveCover THEN FitTexture(texCover, 0, 0, W, H) END;
  Raylib.DrawRectangle(0, H - 190, W, 190, Raylib.Fade(cBlack, 0.65));
  tw := Raylib.MeasureText("DAWN PATROL", 56);
  Raylib.DrawText("DAWN PATROL", W DIV 2 - tw DIV 2, H - 170, 56, cGold);
  tw := Raylib.MeasureText("WWI Aerial Combat -- Raylib Edition", 20);
  Raylib.DrawText("WWI Aerial Combat -- Raylib Edition", W DIV 2 - tw DIV 2, H - 106, 20, cWhite);
  tw := Raylib.MeasureText("Press ENTER to choose your aircraft", 18);
  Raylib.DrawText("Press ENTER to choose your aircraft", W DIV 2 - tw DIV 2, H - 66, 18, cLGray);
  tw := Raylib.MeasureText("Press T for a tutorial", 18);
  Raylib.DrawText("Press T for a tutorial", W DIV 2 - tw DIV 2, H - 40, 18, cSky)
END DrawTitle;

PROCEDURE DrawTutorial;
VAR i, y, tw : INTEGER; s, ns : ARRAY 40 OF CHAR;
BEGIN
  Raylib.ClearBackground(cBlack);
  Raylib.DrawText("HOW TO PLAY", 40, 30, 28, cGold);
  Raylib.DrawText(tutTitle[tutPage], 40, 76, 22, cYellow);

  y := 120;
  FOR i := 0 TO tutLineCount[tutPage] - 1 DO
    Raylib.DrawText(tutLines[tutPage][i], 40, y, 18, cWhite);
    INC(y, 28)
  END;

  s := "";  Strings.IntToStr(tutPage + 1, ns);  Strings.Append(ns, s);
  Strings.Append(" / ", s);  Strings.IntToStr(NTUTPAGES, ns);  Strings.Append(ns, s);
  tw := Raylib.MeasureText(s, 16);
  Raylib.DrawText(s, W - tw - 40, H - 40, 16, cLGray);

  Raylib.DrawText("Left/Right to page through -- Enter to continue", 40, H - 40, 16, cLGray)
END DrawTutorial;

PROCEDURE DrawBrief;
VAR i, y, kind : INTEGER; s, ns : ARRAY 80 OF CHAR; at : AircraftType;
BEGIN
  Raylib.ClearBackground(cBlack);
  Raylib.DrawText("CHOOSE YOUR AIRCRAFT", 40, 30, 28, cGold);

  y := 90;
  FOR i := 0 TO NSELECTABLE - 1 DO
    kind := selectable[i];
    s := "";
    IF i = selType THEN Strings.Append("> ", s) ELSE Strings.Append("  ", s) END;
    Strings.Append(acTypes[kind].name, s);
    IF i = selType THEN Raylib.DrawText(s, 40, y, 20, cYellow)
    ELSE Raylib.DrawText(s, 40, y, 20, cWhite)
    END;
    INC(y, 26)
  END;

  kind := selectable[selType];  at := acTypes[kind];
  IF ~DrawSprite(kind, 0, DIR_N, 760, 160, 90.0, cWhite) THEN
    DrawPlaneIcon(760, 160, DIR_N, at.wings, ALLIED, 40.0, FALSE)
  END;

  NationLabel(at.nation, s);
  Raylib.DrawText(s, 620, 260, 18, cSky);

  s := "Top speed: "; Strings.IntToStr(at.top[0], ns); Strings.Append(ns, s); Strings.Append(" mph", s);
  Raylib.DrawText(s, 620, 290, 16, cWhite);
  s := "Ceiling: "; Strings.IntToStr(at.ceiling, ns); Strings.Append(ns, s); Strings.Append(" ft", s);
  Raylib.DrawText(s, 620, 312, 16, cWhite);
  s := "Hit points (E/FF/RF/T/LW/CW/RW): ";
  Strings.IntToStr(at.hitE,ns); Strings.Append(ns,s); Strings.Append(" ",s);
  Strings.IntToStr(at.hitFF,ns); Strings.Append(ns,s); Strings.Append(" ",s);
  Strings.IntToStr(at.hitRF,ns); Strings.Append(ns,s); Strings.Append(" ",s);
  Strings.IntToStr(at.hitT,ns); Strings.Append(ns,s); Strings.Append(" ",s);
  Strings.IntToStr(at.hitLW,ns); Strings.Append(ns,s); Strings.Append(" ",s);
  Strings.IntToStr(at.hitCW,ns); Strings.Append(ns,s); Strings.Append(" ",s);
  Strings.IntToStr(at.hitRW,ns); Strings.Append(ns,s);
  Raylib.DrawText(s, 620, 340, 14, cLGray);

  IF (kind = AC_SPAD13) & haveSpad THEN
    FitTexture(texSpad, 620, 380, 200, 200 * Raylib.TextureHeight(texSpad) DIV Raylib.TextureWidth(texSpad));
    Raylib.DrawText("From the original 1982 rulebook", 620, 590, 12, cLGray)
  ELSIF (kind = AC_DVII) & haveFokker THEN
    FitTexture(texFokker, 620, 380, 220, 220 * Raylib.TextureHeight(texFokker) DIV Raylib.TextureWidth(texFokker));
    Raylib.DrawText("From the original 1982 rulebook", 620, 590, 12, cLGray)
  END;

  Raylib.DrawText("Up/Down choose - Enter to fly - Esc to quit", 40, H - 40, 16, cLGray)
END DrawBrief;

PROCEDURE DrawOver;
VAR tw : INTEGER;
BEGIN
  Raylib.ClearBackground(cBlack);
  IF haveAlbatros THEN FitTexture(texAlbatros, W DIV 2 - 150, 60, 300, 300 * Raylib.TextureHeight(texAlbatros) DIV Raylib.TextureWidth(texAlbatros)) END;
  tw := Raylib.MeasureText(winMsg, 26);
  Raylib.DrawText(winMsg, W DIV 2 - tw DIV 2, H - 140, 26, cGold);
  tw := Raylib.MeasureText("Press ENTER to return to the title screen", 16);
  Raylib.DrawText("Press ENTER to return to the title screen", W DIV 2 - tw DIV 2, H - 80, 16, cLGray)
END DrawOver;

PROCEDURE Draw;
BEGIN
  Raylib.BeginDrawing;
  CASE stage OF
    ST_TITLE:    DrawTitle
  | ST_TUTORIAL: DrawTutorial
  | ST_BRIEF:    DrawBrief
  | ST_PLAY:     DrawPlay
  | ST_OVER:     DrawOver
  ELSE
  END;
  Raylib.EndDrawing
END Draw;

(* ════════════════════════════════════════════════════════════════════ *)
(*  Main                                                                  *)
(* ════════════════════════════════════════════════════════════════════ *)

(* NOTE: stdlib.md documents Raylib.GetAppDir as a single-arg call, but it
   actually needs the buffer capacity too (it forwards straight to the C
   signature "buf, buf_len"); called that way it returns the directory
   holding the running executable, regardless of the caller's cwd -- exactly
   what we want so dawnpatrol_gfx/ is always found next to the binary.

   Raylib.LoadTexture also always returns a non-NIL wrapper, even when the
   file is missing (it only reports failure via TextureWidth = 0), so
   success has to be checked via the decoded width, not a NIL-check. *)
PROCEDURE FolderFor(side : INTEGER; VAR s : ARRAY OF CHAR);
BEGIN
  IF side = ALLIED THEN COPY("allied", s) ELSE COPY("central", s) END
END FolderFor;

PROCEDURE TryLoad(VAR tex : Raylib.Texture; relPath : ARRAY OF CHAR) : BOOLEAN;
VAR path : ARRAY 256 OF CHAR;
BEGIN
  Raylib.GetAppDir(path, 256);
  Strings.Append("dawnpatrol_gfx/", path);
  Strings.Append(relPath, path);
  tex := Raylib.LoadTexture(path);
  RETURN (tex # NIL) & (Raylib.TextureWidth(tex) > 0)
END TryLoad;

PROCEDURE LoadAssets;
BEGIN
  haveCover    := TryLoad(texCover, "cover.jpg");
  haveSpad     := TryLoad(texSpad, "spad_xiii.jpg");
  haveFokker   := TryLoad(texFokker, "fokker_dvii.jpg");
  haveAlbatros := TryLoad(texAlbatros, "albatros_cxii.jpg")
END LoadAssets;

(* Real counter-sheet artwork for every aircraft type/variant, cut from the
   two counter sheets into examples/dawnpatrol_gfx/counters/{allied,central}/. *)
PROCEDURE LoadCounterTextures;
VAR k, v : INTEGER; relPath, folder, ns : ARRAY 256 OF CHAR;
BEGIN
  FOR k := 0 TO NAIRCRAFT - 1 DO
    FolderFor(acTypes[k].side, folder);
    FOR v := 0 TO acTypes[k].texCount - 1 DO
      COPY("counters/", relPath);
      Strings.Append(folder, relPath);
      Strings.Append("/", relPath);
      Strings.Append(acTypes[k].texBase, relPath);
      Strings.Append("_", relPath);
      Strings.IntToStr(v + 1, ns);
      Strings.Append(ns, relPath);
      Strings.Append(".jpg", relPath);
      planeTexOK[k][v] := TryLoad(planeTex[k][v], relPath)
    END
  END
END LoadCounterTextures;

(* Draw aircraft type/variant `kind`/`variant`, facing `dir` (0..7, 0=N),
   centred at screen point (px,py), scaled so it is `targetW` pixels wide.
   Returns FALSE (no draw) if that counter image failed to load, so the
   caller can fall back to the vector silhouette. *)
PROCEDURE DrawSprite(kind, variant, dir, px, py : INTEGER; targetW : REAL; tint : INTEGER) : BOOLEAN;
VAR tex : Raylib.Texture; scale, ang, hw, hh, offx, offy, posx, posy : REAL;
BEGIN
  IF ~planeTexOK[kind][variant] THEN RETURN FALSE END;
  tex := planeTex[kind][variant];
  scale := targetW / FLT(Raylib.TextureWidth(tex));
  hw := FLT(Raylib.TextureWidth(tex))  * scale * 0.5;
  hh := FLT(Raylib.TextureHeight(tex)) * scale * 0.5;
  ang := FLT(dir) * (Math.pi / 4.0);
  offx := hw * Math.cos(ang) - hh * Math.sin(ang);
  offy := hw * Math.sin(ang) + hh * Math.cos(ang);
  posx := FLT(px) - offx;
  posy := FLT(py) - offy;
  Raylib.DrawTextureEx(tex, posx, posy, ang * 180.0 / Math.pi, scale, tint);
  RETURN TRUE
END DrawSprite;

BEGIN
  cBlack  := Raylib.Black();   cWhite := Raylib.White();  cRed    := Raylib.Red();
  cGreen  := Raylib.Green();   cBlue  := Raylib.DarkBlue(); cYellow := Raylib.Yellow();
  cLGray  := Raylib.LightGray(); cDGray := Raylib.DarkGray(); cSky  := Raylib.SkyBlue();
  cBrown  := Raylib.Brown();   cOrange := Raylib.Orange(); cGold  := Raylib.Gold();

  Raylib.InitWindow(W, H, "Dawn Patrol");
  Raylib.SetTargetFPS(60);

  InitDirs;
  InitAircraftTypes;
  InitHitTable;
  InitTutorial;
  LoadAssets;
  LoadCounterTextures;

  stage := ST_TITLE;
  turnNum := 0;

  WHILE Raylib.WindowShouldClose() = 0 DO
    dt := Raylib.GetFrameTime();
    CASE stage OF
      ST_TITLE:    UpdateTitle
    | ST_TUTORIAL: UpdateTutorial
    | ST_BRIEF:    UpdateBrief
    | ST_PLAY:     UpdatePlay
    | ST_OVER:     UpdateOver
    ELSE
    END;
    Draw
  END;

  IF haveCover THEN Raylib.UnloadTexture(texCover) END;
  IF haveSpad THEN Raylib.UnloadTexture(texSpad) END;
  IF haveFokker THEN Raylib.UnloadTexture(texFokker) END;
  IF haveAlbatros THEN Raylib.UnloadTexture(texAlbatros) END;
  Raylib.CloseWindow
END DawnPatrol.
