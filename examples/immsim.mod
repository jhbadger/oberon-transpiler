MODULE ImmSim;
(* Simplified Celada-Seiden / IMMSIM Cellular Automaton — Oberon port.
   Interactive: S = step, Tab = switch view, Q = quit.
   View 0: CA spatial grid.  View 1: Live B-cell / antigen chart. *)

IMPORT Out, Files, Strings, Random, Terminal;

CONST
  GridSize        = 50;
  BitLen          = 16;
  NSteps          = 1000;
  Challenge2      = 500;
  AntigenDose     = 100;

  EncounterProb   = 0.6;
  AffinityThresh  = 0.55;
  CloneThreshold  = 2;
  MemoryThreshold = 1;
  PlasmaLifetime  = 50;
  MemoryFraction  = 0.4;
  AbLifetime      = 40;
  AgLifetime      = 100;
  PresentDuration = 25;

  InitialB        = 250;
  InitialTh       = 200;
  InitialTc       = 100;
  InitialMac      = 120;
  InitialEC       = 300;
  PrecursorB      = 20;
  PrecursorTh     = 20;

  MaxAntigens     = 20000;
  MaxAntibodies   = 20000;
  MaxBCells       = 10000;
  MaxTHelpers     = 4000;
  MaxTCytos       = 4000;
  MaxMacrophages  = 2000;
  MaxEpithelial   = 2000;
  MaxHistory      = 1200;

  BitMask         = 65535;

  (* --- Display constants --- *)
  (* Pixel buffer is 240 x 100.
     CA grid: render the 50x50 CA in a 150x100 block (left side),
     each cell = 3x2 pixels.
     Chart: right panel 80 wide, full height.
     Separator at x=150.                                           *)

  CAPixW   = 150;   (* CA panel pixel width  *)
  CAPixH   = 100;   (* CA panel pixel height *)
  CellPW   =   3;   (* pixels per CA cell X  *)
  CellPH   =   2;   (* pixels per CA cell Y  *)

  ChartX0  =   2;   (* chart left edge pixel *)
  ChartX1  = 147;   (* chart right edge pixel *)
  ChartY0  =   2;   (* chart top pixel        *)
  ChartY1  =  97;   (* chart bottom pixel     *)

  (* xterm-256 colours *)
  ColBg       =   0;   (* transparent / black   *)
  ColSep      = 240;   (* dark grey separator   *)
  ColEC       =  22;   (* dark green – healthy epithelial *)
  ColInfEC    = 196;   (* red – infected epithelial       *)
  ColAg       = 196;   (* red – antigen                   *)
  ColAb       =  39;   (* blue – antibody                 *)
  ColBCell    = 226;   (* yellow – B cell                 *)
  ColPlasma   = 208;   (* orange – plasma cell            *)
  ColMemB     =  46;   (* bright green – memory B         *)
  ColTHelper  =  51;   (* cyan – T helper                 *)
  ColTCyto    = 201;   (* magenta – Tc                    *)
  ColMac      = 130;   (* brown – macrophage               *)
  ColAxis     = 244;
  ColGrid     = 238;
  ColMarker   = 245;
  ColChAg     = 196;
  ColChB      = 226;
  ColTitle    =   7;

TYPE
  Antigen = RECORD
    x, y, age: INTEGER;
    epitope: INTEGER;
    cleared: BOOLEAN
  END;

  Antibody = RECORD
    x, y, age: INTEGER;
    paratope: INTEGER
  END;

  EpithelialCell = RECORD
    x, y, age: INTEGER;
    infected: BOOLEAN;
    burstCountdown: INTEGER
  END;

  BCell = RECORD
    x, y, age: INTEGER;
    receptor: INTEGER;
    activationCount: INTEGER;
    isMemory: BOOLEAN;
    presentedEpitope: INTEGER;
    hasPresented: BOOLEAN;
    plasma: BOOLEAN;
    plasmaAge: INTEGER
  END;

  THelper = RECORD
    x, y, age: INTEGER;
    receptor: INTEGER;
    activationCount: INTEGER;
    presentedEpitope: INTEGER;
    hasPresented: BOOLEAN
  END;

  TCytotoxic = RECORD
    x, y, age: INTEGER;
    receptor: INTEGER;
    activationCount: INTEGER
  END;

  Macrophage = RECORD
    x, y, age: INTEGER;
    presenting: BOOLEAN;
    presentEpitope: INTEGER;
    presentCountdown: INTEGER
  END;

  HistRecord = RECORD
    t, antigens, antibodies, bcells, plasma, memoryB,
      infectedEC, epithelial: INTEGER
  END;

VAR
  sharedEpitope: INTEGER;

  antigens:    ARRAY MaxAntigens    OF Antigen;
  antibodies:  ARRAY MaxAntibodies  OF Antibody;
  bcells:      ARRAY MaxBCells      OF BCell;
  thelpers:    ARRAY MaxTHelpers    OF THelper;
  tcytos:      ARRAY MaxTCytos      OF TCytotoxic;
  macrophages: ARRAY MaxMacrophages OF Macrophage;
  epithelial:  ARRAY MaxEpithelial  OF EpithelialCell;
  history:     ARRAY MaxHistory     OF HistRecord;

  nAg, nAb, nB, nTh, nTc, nMac, nEC, nHist: INTEGER;
  currentT: INTEGER;
  activeView: INTEGER;   (* 0 = CA grid, 1 = chart *)
  done: BOOLEAN;

(* ================================================================= *)
(* Bit-string utilities                                               *)
(* ================================================================= *)

PROCEDURE RandU(): INTEGER;
BEGIN RETURN Random.Int(65536) END RandU;

PROCEDURE PopCount(x: INTEGER): INTEGER;
  VAR n, v: INTEGER;
BEGIN
  n := 0; v := x;
  WHILE v # 0 DO
    IF ODD(v) THEN INC(n) END;
    v := v DIV 2
  END;
  RETURN n
END PopCount;

PROCEDURE Xor(a, b: INTEGER): INTEGER;
  VAR i, r, ba, bb: INTEGER;
BEGIN
  r := 0; i := 0;
  WHILE i < BitLen DO
    ba := a MOD 2; bb := b MOD 2;
    IF ba # bb THEN r := r + LSL(1, i) END;
    a := a DIV 2; b := b DIV 2;
    INC(i)
  END;
  RETURN r
END Xor;

PROCEDURE Comp(a, b: INTEGER): REAL;
BEGIN RETURN FLT(PopCount(Xor(a, b))) / FLT(BitLen) END Comp;

PROCEDURE Recognises(receptor, epitope: INTEGER): BOOLEAN;
BEGIN RETURN Comp(receptor, epitope) >= AffinityThresh END Recognises;

PROCEDURE BitNot(x: INTEGER): INTEGER;
  VAR i, r: INTEGER;
BEGIN
  r := 0; i := 0;
  WHILE i < BitLen DO
    IF ~ODD(x) THEN r := r + LSL(1, i) END;
    x := x DIV 2;
    INC(i)
  END;
  RETURN r
END BitNot;

PROCEDURE MakeMatchedReceptor(epitope: INTEGER): INTEGER;
  VAR best, r, i: INTEGER; bestScore, s: REAL;
BEGIN
  best := RandU(); bestScore := Comp(best, epitope);
  i := 0;
  WHILE i < 200 DO
    r := RandU(); s := Comp(r, epitope);
    IF s > bestScore THEN
      best := r; bestScore := s;
      IF s >= AffinityThresh THEN i := 200 END
    END;
    INC(i)
  END;
  RETURN best
END MakeMatchedReceptor;

(* ================================================================= *)
(* Spatial helpers                                                    *)
(* ================================================================= *)

PROCEDURE RandPos(VAR x, y: INTEGER);
BEGIN x := Random.Int(GridSize); y := Random.Int(GridSize) END RandPos;

PROCEDURE Coloc(ax, ay, bx, by: INTEGER): BOOLEAN;
BEGIN RETURN (ax = bx) & (ay = by) END Coloc;

PROCEDURE Near(ax, ay, bx, by, d: INTEGER): BOOLEAN;
  VAR dx, dy: INTEGER;
BEGIN
  dx := ax - bx; IF dx < 0 THEN dx := -dx END;
  dy := ay - by; IF dy < 0 THEN dy := -dy END;
  RETURN (dx <= d) & (dy <= d)
END Near;

PROCEDURE StepPos(VAR x, y: INTEGER);
  VAR dir: INTEGER;
BEGIN
  dir := Random.Int(4);
  CASE dir OF
    0: x := (x + GridSize - 1) MOD GridSize
  | 1: x := (x + 1) MOD GridSize
  | 2: y := (y + GridSize - 1) MOD GridSize
  ELSE y := (y + 1) MOD GridSize
  END
END StepPos;

(* ================================================================= *)
(* Initialisation                                                     *)
(* ================================================================= *)

PROCEDURE InjectAntigen(n: INTEGER);
  VAR i, x, y: INTEGER;
BEGIN
  i := 0;
  WHILE (i < n) & (nAg < MaxAntigens) DO
    RandPos(x, y);
    antigens[nAg].x := x; antigens[nAg].y := y;
    antigens[nAg].age := 0;
    antigens[nAg].epitope := sharedEpitope;
    antigens[nAg].cleared := FALSE;
    INC(nAg); INC(i)
  END
END InjectAntigen;

PROCEDURE Initialise;
  VAR i, x, y, r: INTEGER;
BEGIN
  nAg := 0; nAb := 0; nB := 0; nTh := 0;
  nTc := 0; nMac := 0; nEC := 0; nHist := 0;
  currentT := 0; activeView := 0; done := FALSE;
  sharedEpitope := RandU();

  FOR i := 0 TO InitialEC - 1 DO
    RandPos(x, y);
    epithelial[nEC].x := x; epithelial[nEC].y := y;
    epithelial[nEC].age := 0;
    epithelial[nEC].infected := FALSE;
    epithelial[nEC].burstCountdown := 0;
    INC(nEC)
  END;

  FOR i := 0 TO InitialB - 1 DO
    RandPos(x, y); r := RandU();
    bcells[nB].x := x; bcells[nB].y := y; bcells[nB].age := 0;
    bcells[nB].receptor := r; bcells[nB].activationCount := 0;
    bcells[nB].isMemory := FALSE; bcells[nB].hasPresented := FALSE;
    bcells[nB].presentedEpitope := 0;
    bcells[nB].plasma := FALSE; bcells[nB].plasmaAge := 0;
    INC(nB)
  END;

  FOR i := 0 TO InitialTh - 1 DO
    RandPos(x, y); r := RandU();
    thelpers[nTh].x := x; thelpers[nTh].y := y; thelpers[nTh].age := 0;
    thelpers[nTh].receptor := r; thelpers[nTh].activationCount := 0;
    thelpers[nTh].hasPresented := FALSE; thelpers[nTh].presentedEpitope := 0;
    INC(nTh)
  END;

  FOR i := 0 TO InitialTc - 1 DO
    RandPos(x, y); r := RandU();
    tcytos[nTc].x := x; tcytos[nTc].y := y; tcytos[nTc].age := 0;
    tcytos[nTc].receptor := r; tcytos[nTc].activationCount := 0;
    INC(nTc)
  END;

  FOR i := 0 TO InitialMac - 1 DO
    RandPos(x, y);
    macrophages[nMac].x := x; macrophages[nMac].y := y;
    macrophages[nMac].age := 0;
    macrophages[nMac].presenting := FALSE;
    macrophages[nMac].presentEpitope := 0;
    macrophages[nMac].presentCountdown := 0;
    INC(nMac)
  END;

  FOR i := 0 TO PrecursorB - 1 DO
    IF nB < MaxBCells THEN
      RandPos(x, y); r := MakeMatchedReceptor(sharedEpitope);
      bcells[nB].x := x; bcells[nB].y := y; bcells[nB].age := 0;
      bcells[nB].receptor := r; bcells[nB].activationCount := 0;
      bcells[nB].isMemory := FALSE; bcells[nB].hasPresented := FALSE;
      bcells[nB].presentedEpitope := 0;
      bcells[nB].plasma := FALSE; bcells[nB].plasmaAge := 0;
      INC(nB)
    END
  END;

  FOR i := 0 TO PrecursorTh - 1 DO
    IF nTh < MaxTHelpers THEN
      RandPos(x, y); r := MakeMatchedReceptor(sharedEpitope);
      thelpers[nTh].x := x; thelpers[nTh].y := y; thelpers[nTh].age := 0;
      thelpers[nTh].receptor := r; thelpers[nTh].activationCount := 0;
      thelpers[nTh].hasPresented := TRUE;
      thelpers[nTh].presentedEpitope := sharedEpitope;
      INC(nTh)
    END
  END;

  InjectAntigen(AntigenDose)
END Initialise;

(* ================================================================= *)
(* Simulation step procedures (unchanged logic)                      *)
(* ================================================================= *)

PROCEDURE MoveAll;
  VAR i: INTEGER;
BEGIN
  FOR i := 0 TO nAg  - 1 DO StepPos(antigens[i].x,    antigens[i].y)    END;
  FOR i := 0 TO nAb  - 1 DO StepPos(antibodies[i].x,  antibodies[i].y)  END;
  FOR i := 0 TO nB   - 1 DO StepPos(bcells[i].x,      bcells[i].y)      END;
  FOR i := 0 TO nTh  - 1 DO StepPos(thelpers[i].x,    thelpers[i].y)    END;
  FOR i := 0 TO nTc  - 1 DO StepPos(tcytos[i].x,      tcytos[i].y)      END;
  FOR i := 0 TO nMac - 1 DO StepPos(macrophages[i].x, macrophages[i].y) END
END MoveAll;

PROCEDURE AntigenAntibodyEncounters;
  VAR i, j: INTEGER;
BEGIN
  FOR i := 0 TO nAb - 1 DO
    FOR j := 0 TO nAg - 1 DO
      IF ~antigens[j].cleared
         & Coloc(antibodies[i].x, antibodies[i].y,
                 antigens[j].x,   antigens[j].y)
         & (Random.Real() < EncounterProb)
         & Recognises(antibodies[i].paratope, antigens[j].epitope) THEN
        antigens[j].cleared := TRUE
      END
    END
  END
END AntigenAntibodyEncounters;

PROCEDURE MacrophageAntigenEncounters;
  VAR i, j: INTEGER; done2: BOOLEAN;
BEGIN
  FOR i := 0 TO nMac - 1 DO
    IF ~macrophages[i].presenting THEN
      done2 := FALSE; j := 0;
      WHILE (j < nAg) & ~done2 DO
        IF ~antigens[j].cleared
           & Coloc(macrophages[i].x, macrophages[i].y,
                   antigens[j].x,    antigens[j].y)
           & (Random.Real() < EncounterProb) THEN
          antigens[j].cleared := TRUE;
          macrophages[i].presenting := TRUE;
          macrophages[i].presentEpitope := antigens[j].epitope;
          macrophages[i].presentCountdown := PresentDuration;
          done2 := TRUE
        END;
        INC(j)
      END
    END
  END;
  FOR i := 0 TO nMac - 1 DO
    IF macrophages[i].presenting THEN
      FOR j := 0 TO nTh - 1 DO
        IF Near(macrophages[i].x, macrophages[i].y,
                thelpers[j].x,    thelpers[j].y, 1)
           & (Random.Real() < EncounterProb)
           & Recognises(thelpers[j].receptor, macrophages[i].presentEpitope) THEN
          INC(thelpers[j].activationCount);
          thelpers[j].presentedEpitope := macrophages[i].presentEpitope;
          thelpers[j].hasPresented := TRUE
        END
      END
    END
  END
END MacrophageAntigenEncounters;

PROCEDURE BCellDivideThreshold(i: INTEGER): INTEGER;
BEGIN
  IF bcells[i].isMemory THEN RETURN MemoryThreshold
  ELSE RETURN CloneThreshold END
END BCellDivideThreshold;

PROCEDURE THBCellEncounters;
  VAR i, j, ep, thresh: INTEGER;
BEGIN
  FOR i := 0 TO nTh - 1 DO
    IF (thelpers[i].activationCount > 0) & thelpers[i].hasPresented THEN
      ep := thelpers[i].presentedEpitope;
      FOR j := 0 TO nB - 1 DO
        IF ~bcells[j].plasma
           & Coloc(thelpers[i].x, thelpers[i].y,
                   bcells[j].x,   bcells[j].y)
           & (Random.Real() < EncounterProb)
           & Recognises(bcells[j].receptor, ep) THEN
          INC(bcells[j].activationCount);
          bcells[j].presentedEpitope := ep;
          bcells[j].hasPresented := TRUE;
          thresh := BCellDivideThreshold(j);
          IF bcells[j].activationCount >= thresh THEN
            IF nB < MaxBCells THEN
              bcells[nB].x := bcells[j].x; bcells[nB].y := bcells[j].y;
              bcells[nB].age := 0;
              bcells[nB].receptor := bcells[j].receptor;
              bcells[nB].presentedEpitope := bcells[j].presentedEpitope;
              bcells[nB].hasPresented := bcells[j].hasPresented;
              bcells[nB].activationCount := 0;
              bcells[nB].isMemory := FALSE;
              bcells[nB].plasma := FALSE; bcells[nB].plasmaAge := 0;
              IF Random.Real() < MemoryFraction THEN
                bcells[nB].isMemory := TRUE;
                bcells[nB].activationCount := thresh - 1
              END;
              bcells[nB].plasma := TRUE; bcells[nB].plasmaAge := 0;
              INC(nB)
            END;
            bcells[j].activationCount := 0
          END
        END
      END
    END
  END
END THBCellEncounters;

PROCEDURE PlasmaSecretion;
  VAR i, paratope: INTEGER;
BEGIN
  IF nAg = 0 THEN RETURN END;
  FOR i := 0 TO nB - 1 DO
    IF bcells[i].plasma & (Random.Real() < 0.6) & (nAb < MaxAntibodies) THEN
      paratope := BitNot(bcells[i].receptor);
      antibodies[nAb].x := bcells[i].x; antibodies[nAb].y := bcells[i].y;
      antibodies[nAb].age := 0; antibodies[nAb].paratope := paratope;
      INC(nAb)
    END
  END
END PlasmaSecretion;

PROCEDURE AntigenInfectsEpithelial;
  VAR i, j: INTEGER; done2: BOOLEAN;
BEGIN
  FOR i := 0 TO nAg - 1 DO
    IF ~antigens[i].cleared THEN
      done2 := FALSE; j := 0;
      WHILE (j < nEC) & ~done2 DO
        IF ~epithelial[j].infected
           & Coloc(antigens[i].x, antigens[i].y,
                   epithelial[j].x, epithelial[j].y)
           & (Random.Real() < 0.15) THEN
          epithelial[j].infected := TRUE;
          epithelial[j].burstCountdown := 10;
          antigens[i].cleared := TRUE;
          done2 := TRUE
        END;
        INC(j)
      END
    END
  END
END AntigenInfectsEpithelial;

PROCEDURE BurstRelease;
  VAR i, k, count, x, y: INTEGER;
BEGIN
  FOR i := 0 TO nEC - 1 DO
    IF epithelial[i].infected & (epithelial[i].burstCountdown <= 0) THEN
      count := 2 + Random.Int(4);
      FOR k := 0 TO count - 1 DO
        IF nAg < MaxAntigens THEN
          RandPos(x, y);
          antigens[nAg].x := x; antigens[nAg].y := y;
          antigens[nAg].age := 0;
          antigens[nAg].epitope := sharedEpitope;
          antigens[nAg].cleared := FALSE;
          INC(nAg)
        END
      END
    END
  END
END BurstRelease;

PROCEDURE TCEncounters;
  VAR i, j: INTEGER;
BEGIN
  FOR i := 0 TO nTc - 1 DO
    FOR j := 0 TO nEC - 1 DO
      IF Coloc(tcytos[i].x, tcytos[i].y, epithelial[j].x, epithelial[j].y)
         & (Random.Real() < EncounterProb)
         & epithelial[j].infected
         & (tcytos[i].activationCount > 0) THEN
        epithelial[j].burstCountdown := 0
      END
    END
  END
END TCEncounters;

PROCEDURE AgeAndPrune;
  VAR i, w: INTEGER;
BEGIN
  FOR i := 0 TO nAg  - 1 DO INC(antigens[i].age)    END;
  FOR i := 0 TO nAb  - 1 DO INC(antibodies[i].age)  END;
  FOR i := 0 TO nB   - 1 DO
    INC(bcells[i].age);
    IF bcells[i].plasma THEN INC(bcells[i].plasmaAge) END
  END;
  FOR i := 0 TO nTh  - 1 DO INC(thelpers[i].age)    END;
  FOR i := 0 TO nTc  - 1 DO INC(tcytos[i].age)      END;
  FOR i := 0 TO nMac - 1 DO
    INC(macrophages[i].age);
    IF macrophages[i].presenting THEN
      DEC(macrophages[i].presentCountdown);
      IF macrophages[i].presentCountdown <= 0 THEN
        macrophages[i].presenting := FALSE
      END
    END
  END;
  FOR i := 0 TO nEC - 1 DO
    INC(epithelial[i].age);
    IF epithelial[i].infected THEN DEC(epithelial[i].burstCountdown) END
  END;

  w := 0;
  FOR i := 0 TO nAg - 1 DO
    IF ~antigens[i].cleared & (antigens[i].age <= AgLifetime) THEN
      IF w # i THEN antigens[w] := antigens[i] END; INC(w)
    END
  END;
  nAg := w;

  w := 0;
  FOR i := 0 TO nAb - 1 DO
    IF antibodies[i].age <= AbLifetime THEN
      IF w # i THEN antibodies[w] := antibodies[i] END; INC(w)
    END
  END;
  nAb := w;

  w := 0;
  FOR i := 0 TO nB - 1 DO
    IF ~(bcells[i].plasma & ~bcells[i].isMemory
         & (bcells[i].plasmaAge > PlasmaLifetime)) THEN
      IF w # i THEN bcells[w] := bcells[i] END; INC(w)
    END
  END;
  nB := w;

  w := 0;
  FOR i := 0 TO nEC - 1 DO
    IF ~(epithelial[i].infected & (epithelial[i].burstCountdown <= 0)) THEN
      IF w # i THEN epithelial[w] := epithelial[i] END; INC(w)
    END
  END;
  nEC := w;

  IF nAg = 0 THEN
    FOR i := 0 TO nTh - 1 DO
      IF thelpers[i].activationCount > 0 THEN
        DEC(thelpers[i].activationCount)
      END
    END
  END
END AgeAndPrune;

(* ================================================================= *)
(* Counting helpers                                                   *)
(* ================================================================= *)

PROCEDURE CountPlasma(): INTEGER;
  VAR i, n: INTEGER;
BEGIN n := 0;
  FOR i := 0 TO nB - 1 DO IF bcells[i].plasma THEN INC(n) END END;
  RETURN n
END CountPlasma;

PROCEDURE CountMemory(): INTEGER;
  VAR i, n: INTEGER;
BEGIN n := 0;
  FOR i := 0 TO nB - 1 DO IF bcells[i].isMemory THEN INC(n) END END;
  RETURN n
END CountMemory;

PROCEDURE CountInfected(): INTEGER;
  VAR i, n: INTEGER;
BEGIN n := 0;
  FOR i := 0 TO nEC - 1 DO IF epithelial[i].infected THEN INC(n) END END;
  RETURN n
END CountInfected;

PROCEDURE RecordStep(t: INTEGER);
BEGIN
  IF nHist < MaxHistory THEN
    history[nHist].t          := t;
    history[nHist].antigens   := nAg;
    history[nHist].antibodies := nAb;
    history[nHist].bcells     := nB;
    history[nHist].plasma     := CountPlasma();
    history[nHist].memoryB    := CountMemory();
    history[nHist].infectedEC := CountInfected();
    history[nHist].epithelial := nEC;
    INC(nHist)
  END
END RecordStep;

(* ================================================================= *)
(* Single simulation tick                                             *)
(* ================================================================= *)

PROCEDURE Tick;
BEGIN
  IF currentT = Challenge2 THEN
    InjectAntigen(AntigenDose)
  END;
  MoveAll;
  AntigenInfectsEpithelial;
  BurstRelease;
  AntigenAntibodyEncounters;
  MacrophageAntigenEncounters;
  THBCellEncounters;
  PlasmaSecretion;
  TCEncounters;
  AgeAndPrune;
  RecordStep(currentT);
  INC(currentT)
END Tick;

(* ================================================================= *)
(* Rendering                                                          *)
(* ================================================================= *)

(* --- Helpers --- *)

PROCEDURE Max2(a, b: INTEGER): INTEGER;
BEGIN IF a > b THEN RETURN a ELSE RETURN b END END Max2;

PROCEDURE PlotPixel(px, py, col: INTEGER);
(* Safe plot: only draw if within pixel buffer 0..239, 0..99 *)
BEGIN
  IF (px >= 0) & (px < 240) & (py >= 0) & (py < 100) THEN
    Terminal.Plot(px, py, col)
  END
END PlotPixel;

(* --- CA Grid View --- *)

PROCEDURE DrawCAView;
  VAR i, px, py, cx, cy, col: INTEGER;
      (* overlay grid: one colour per cell, priority order *)
      (* We accumulate into a small colour-per-cell grid *)
      grid: ARRAY GridSize OF ARRAY GridSize OF INTEGER;
BEGIN
  (* Clear grid array to background *)
  FOR cx := 0 TO GridSize - 1 DO
    FOR cy := 0 TO GridSize - 1 DO
      grid[cx][cy] := 0
    END
  END;

  (* Paint layers lowest→highest priority into grid *)
  FOR i := 0 TO nEC - 1 DO
    cx := epithelial[i].x; cy := epithelial[i].y;
    IF epithelial[i].infected THEN
      grid[cx][cy] := ColInfEC
    ELSIF grid[cx][cy] = 0 THEN
      grid[cx][cy] := ColEC
    END
  END;
  FOR i := 0 TO nMac - 1 DO
    cx := macrophages[i].x; cy := macrophages[i].y;
    IF grid[cx][cy] = 0 THEN grid[cx][cy] := ColMac END
  END;
  FOR i := 0 TO nTh - 1 DO
    cx := thelpers[i].x; cy := thelpers[i].y;
    IF grid[cx][cy] = 0 THEN grid[cx][cy] := ColTHelper END
  END;
  FOR i := 0 TO nTc - 1 DO
    cx := tcytos[i].x; cy := tcytos[i].y;
    IF grid[cx][cy] = 0 THEN grid[cx][cy] := ColTCyto END
  END;
  FOR i := 0 TO nB - 1 DO
    cx := bcells[i].x; cy := bcells[i].y;
    IF bcells[i].isMemory THEN col := ColMemB
    ELSIF bcells[i].plasma THEN col := ColPlasma
    ELSE col := ColBCell
    END;
    (* B cells overwrite non-antigen background *)
    IF (grid[cx][cy] = 0) OR (grid[cx][cy] = ColEC) OR
       (grid[cx][cy] = ColMac) OR (grid[cx][cy] = ColTHelper) OR
       (grid[cx][cy] = ColTCyto) THEN
      grid[cx][cy] := col
    END
  END;
  FOR i := 0 TO nAb - 1 DO
    cx := antibodies[i].x; cy := antibodies[i].y;
    IF grid[cx][cy] = 0 THEN grid[cx][cy] := ColAb END
  END;
  (* Antigens highest priority *)
  FOR i := 0 TO nAg - 1 DO
    cx := antigens[i].x; cy := antigens[i].y;
    grid[cx][cy] := ColAg
  END;

  (* Render grid into pixel buffer *)
  FOR cx := 0 TO GridSize - 1 DO
    FOR cy := 0 TO GridSize - 1 DO
      col := grid[cx][cy];
      IF col = 0 THEN col := 235 END;  (* dark grey background fill *)
      px := cx * CellPW;
      py := cy * CellPH;
      PlotPixel(px,     py,     col);
      PlotPixel(px + 1, py,     col);
      PlotPixel(px + 2, py,     col);
      PlotPixel(px,     py + 1, col);
      PlotPixel(px + 1, py + 1, col);
      PlotPixel(px + 2, py + 1, col)
    END
  END
END DrawCAView;

(* --- Chart View --- *)

PROCEDURE ChartMap(t, v, tMax, vMax: INTEGER; VAR px, py: INTEGER);
  VAR w, h: INTEGER;
BEGIN
  w := ChartX1 - ChartX0;
  h := ChartY1 - ChartY0;
  IF tMax < 1 THEN tMax := 1 END;
  IF vMax < 1 THEN vMax := 1 END;
  px := ChartX0 + (t * w) DIV tMax;
  py := ChartY1 - (v * h) DIV vMax
END ChartMap;

PROCEDURE DrawChartView;
  VAR i, tMax, vMax, maxAg, maxB: INTEGER;
      px, py, ppx, ppy: INTEGER;
      v, prevV: INTEGER;
BEGIN
  (* Compute data ranges *)
  tMax := NSteps - 1;
  maxAg := 1; maxB := 1;
  FOR i := 0 TO nHist - 1 DO
    IF history[i].antigens > maxAg THEN maxAg := history[i].antigens END;
    IF history[i].bcells   > maxB  THEN maxB  := history[i].bcells   END
  END;
  vMax := Max2(maxAg, maxB);
  vMax := ((vMax + 9) DIV 10) * 10;
  IF vMax < 10 THEN vMax := 10 END;

  (* Draw chart background *)
  FOR px := ChartX0 TO ChartX1 DO
    FOR py := ChartY0 TO ChartY1 DO
      PlotPixel(px, py, 233)
    END
  END;

  (* Horizontal grid lines at 25%, 50%, 75%, 100% *)
  FOR i := 1 TO 4 DO
    ChartMap(0, (vMax * i) DIV 4, tMax, vMax, px, py);
    IF py >= ChartY0 THEN
      Terminal.Line(ChartX0, py, ChartX1, py, ColGrid)
    END
  END;

  (* Vertical marker at challenge2 *)
  ChartMap(Challenge2, 0,    tMax, vMax, px, ppy);
  ChartMap(Challenge2, vMax, tMax, vMax, px, py);
  Terminal.Line(px, py, px, ppy, ColMarker);

  (* Axes *)
  Terminal.Line(ChartX0, ChartY0, ChartX0, ChartY1, ColAxis);
  Terminal.Line(ChartX0, ChartY1, ChartX1, ChartY1, ColAxis);

  IF nHist < 2 THEN RETURN END;

  (* Antigen series *)
  prevV := history[0].antigens;
  ChartMap(history[0].t, prevV, tMax, vMax, ppx, ppy);
  FOR i := 1 TO nHist - 1 DO
    v := history[i].antigens;
    ChartMap(history[i].t, v, tMax, vMax, px, py);
    Terminal.Line(ppx, ppy, px, py, ColChAg);
    ppx := px; ppy := py
  END;

  (* B-cell series *)
  prevV := history[0].bcells;
  ChartMap(history[0].t, prevV, tMax, vMax, ppx, ppy);
  FOR i := 1 TO nHist - 1 DO
    v := history[i].bcells;
    ChartMap(history[i].t, v, tMax, vMax, px, py);
    Terminal.Line(ppx, ppy, px, py, ColChB);
    ppx := px; ppy := py
  END
END DrawChartView;

(* --- Separator and HUD --- *)

PROCEDURE DrawSeparator;
  VAR y: INTEGER;
BEGIN
  FOR y := 0 TO 99 DO
    PlotPixel(CAPixW,     y, ColSep);
    PlotPixel(CAPixW + 1, y, ColSep);
    PlotPixel(CAPixW + 2, y, ColSep);
    PlotPixel(CAPixW + 3, y, ColSep)
  END
END DrawSeparator;

PROCEDURE WriteHUD;
  (* Write text overlay via Terminal.Goto + Out after flushing pixel buf *)
  VAR s: ARRAY 32 OF CHAR;
      memB, inf: INTEGER;
BEGIN
  memB := CountMemory();
  inf  := CountInfected();

  (* Line 1: title + step *)
  Terminal.Goto(1, 1);
  Terminal.Color256(ColTitle, 0);
  IF currentT >= NSteps THEN
    Out.String("IMMSIM  [DONE t=")
  ELSE
    Out.String("IMMSIM  t=")
  END;
  Strings.IntToStr(currentT, s); Out.String(s);
  IF currentT >= NSteps THEN Out.String("]") END;
  Out.String("  AG="); Strings.IntToStr(nAg, s); Out.String(s);
  Out.String(" AB=");  Strings.IntToStr(nAb, s); Out.String(s);
  Out.String(" B=");   Strings.IntToStr(nB,  s); Out.String(s);
  Out.String(" Mem="); Strings.IntToStr(memB, s); Out.String(s);
  Out.String(" Inf="); Strings.IntToStr(inf,  s); Out.String(s);

  (* Line 2: key guide + view label *)
  Terminal.Goto(1, 2);
  IF activeView = 0 THEN
    Out.String("[S]=step  [Tab]=chart view  [Q]=quit  |  VIEW: CA Grid")
  ELSE
    Out.String("[S]=step  [Tab]=CA view     [Q]=quit  |  VIEW: B-cell / Antigen chart")
  END;

  (* Colour key — bottom row of terminal *)
  Terminal.Goto(1, 51);
  Terminal.Color256(ColAg,      0); Out.String(" AG ");
  Terminal.Color256(ColAb,      0); Out.String(" AB ");
  Terminal.Color256(ColBCell,   0); Out.String(" B  ");
  Terminal.Color256(ColPlasma,  0); Out.String(" Pl ");
  Terminal.Color256(ColMemB,    0); Out.String(" Mem");
  Terminal.Color256(ColTHelper, 0); Out.String(" Th ");
  Terminal.Color256(ColTCyto,   0); Out.String(" Tc ");
  Terminal.Color256(ColMac,     0); Out.String(" Mac");
  Terminal.Color256(ColEC,      0); Out.String(" EC ");
  Terminal.Color256(ColInfEC,   0); Out.String(" InfEC");
  Terminal.Reset
END WriteHUD;

PROCEDURE Redraw;
BEGIN
  Terminal.ClearBuf;
  IF activeView = 0 THEN
    DrawCAView
  ELSE
    DrawChartView
  END;
  Terminal.Flush;
  WriteHUD
END Redraw;

(* ================================================================= *)
(* CSV output                                                         *)
(* ================================================================= *)

PROCEDURE WriteByte(VAR r: Files.Rider; n: INTEGER);
  VAR b: BYTE;
BEGIN b := n; Files.Write(r, b) END WriteByte;

PROCEDURE WriteIntField(VAR r: Files.Rider; n: INTEGER; sep: CHAR);
  VAR s: ARRAY 16 OF CHAR; i: INTEGER;
BEGIN
  Strings.IntToStr(n, s); i := 0;
  WHILE s[i] # 0X DO WriteByte(r, ORD(s[i])); INC(i) END;
  WriteByte(r, ORD(sep))
END WriteIntField;

PROCEDURE WriteCSV(path: ARRAY OF CHAR);
  VAR f: Files.File; r: Files.Rider;
      header: ARRAY 80 OF CHAR; i, k: INTEGER;
BEGIN
  f := Files.New(path);
  IF f = NIL THEN RETURN END;
  Files.Set(r, f, 0);
  COPY("t,antigens,antibodies,bcells,plasma,memory_b,infected_ec,epithelial", header);
  i := 0;
  WHILE header[i] # 0X DO WriteByte(r, ORD(header[i])); INC(i) END;
  WriteByte(r, 0AH);
  FOR k := 0 TO nHist - 1 DO
    WriteIntField(r, history[k].t,          ',');
    WriteIntField(r, history[k].antigens,   ',');
    WriteIntField(r, history[k].antibodies, ',');
    WriteIntField(r, history[k].bcells,     ',');
    WriteIntField(r, history[k].plasma,     ',');
    WriteIntField(r, history[k].memoryB,    ',');
    WriteIntField(r, history[k].infectedEC, ',');
    WriteIntField(r, history[k].epithelial, 0AX)
  END;
  Files.Register(f);
  Files.Close(f)
END WriteCSV;

(* ================================================================= *)
(* Main                                                               *)
(* ================================================================= *)

PROCEDURE Run;
  VAR key: CHAR;
BEGIN
  Terminal.Clear;
  Redraw;

  REPEAT
    key := Terminal.ReadKey();
    IF (key = 's') OR (key = 'S') THEN
      IF currentT < NSteps THEN
        Tick;
        Redraw
      END
    ELSIF key = 09X THEN       (* Tab *)
      activeView := 1 - activeView;
      Redraw
    ELSIF (key = 'q') OR (key = 'Q') THEN
      done := TRUE
    END
  UNTIL done
END Run;

BEGIN
  Initialise;
  Run;
  Terminal.Restore;
  WriteCSV("immsim_results.csv");
  Out.String("Results written to immsim_results.csv"); Out.Ln
END ImmSim.
