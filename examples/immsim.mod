MODULE ImmSim;
(* Simplified Celada-Seiden / IMMSIM Cellular Automaton — Oberon port.
   Output: immsim_results.csv plus an in-terminal pixel plot. *)

IMPORT Out, Files, Strings, Random, Terminal;

CONST
  GridSize        = 20;
  BitLen          = 16;
  NSteps          = 300;
  Challenge2      = 150;
  AntigenDose     = 20;

  EncounterProb   = 0.6;
  AffinityThresh  = 0.55;
  CloneThreshold  = 2;
  MemoryThreshold = 1;
  PlasmaLifetime  = 30;
  MemoryFraction  = 0.4;
  AbLifetime      = 25;
  AgLifetime      = 60;
  PresentDuration = 25;

  InitialB        = 60;
  InitialTh       = 50;
  InitialTc       = 20;
  InitialMac      = 25;
  InitialEC       = 60;
  PrecursorB      = 4;
  PrecursorTh     = 4;

  MaxAntigens     = 8000;
  MaxAntibodies   = 8000;
  MaxBCells       = 4000;
  MaxTHelpers     = 1000;
  MaxTCytos       = 1000;
  MaxMacrophages  = 500;
  MaxEpithelial   = 500;
  MaxHistory      = 400;

  BitMask         = 65535;

  (* Plot constants *)
  PlotW   = 240;
  PlotH   = 100;
  MarginL =  20;
  MarginR =   4;
  MarginT =   4;
  MarginB =   8;

  ColAxis     = 244;
  ColGrid     = 238;
  ColMarker   = 245;
  ColAntigen  = 196;
  ColAntibody =  39;

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

  Record = RECORD
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
  history:     ARRAY MaxHistory     OF Record;

  nAg, nAb, nB, nTh, nTc, nMac, nEC, nHist: INTEGER;

(* ----------------------------------------------------------------- *)
(* Bit-string utilities                                               *)
(* ----------------------------------------------------------------- *)

PROCEDURE RandU(): INTEGER;
BEGIN
  RETURN Random.Int(65536)
END RandU;

PROCEDURE PopCount(x: INTEGER): INTEGER;
  VAR n, v: INTEGER;
BEGIN
  n := 0;
  v := x;
  WHILE v # 0 DO
    IF ODD(v) THEN INC(n) END;
    v := v DIV 2
  END;
  RETURN n
END PopCount;

PROCEDURE Xor(a, b: INTEGER): INTEGER;
  VAR i, r, ba, bb: INTEGER;
BEGIN
  r := 0;
  i := 0;
  WHILE i < BitLen DO
    ba := a MOD 2;  bb := b MOD 2;
    IF ba # bb THEN r := r + LSL(1, i) END;
    a := a DIV 2;   b := b DIV 2;
    INC(i)
  END;
  RETURN r
END Xor;

PROCEDURE Comp(a, b: INTEGER): REAL;
BEGIN
  RETURN FLT(PopCount(Xor(a, b))) / FLT(BitLen)
END Comp;

PROCEDURE Recognises(receptor, epitope: INTEGER): BOOLEAN;
BEGIN
  RETURN Comp(receptor, epitope) >= AffinityThresh
END Recognises;

PROCEDURE BitNot(x: INTEGER): INTEGER;
  VAR i, r: INTEGER;
BEGIN
  r := 0;
  i := 0;
  WHILE i < BitLen DO
    IF ~ODD(x) THEN r := r + LSL(1, i) END;
    x := x DIV 2;
    INC(i)
  END;
  RETURN r
END BitNot;

PROCEDURE MakeMatchedReceptor(epitope: INTEGER): INTEGER;
  VAR best, r, i: INTEGER;
      bestScore, s: REAL;
BEGIN
  best := RandU();
  bestScore := Comp(best, epitope);
  i := 0;
  WHILE i < 200 DO
    r := RandU();
    s := Comp(r, epitope);
    IF s > bestScore THEN
      best := r;
      bestScore := s;
      IF s >= AffinityThresh THEN i := 200 END
    END;
    INC(i)
  END;
  RETURN best
END MakeMatchedReceptor;

(* ----------------------------------------------------------------- *)
(* Spatial helpers                                                    *)
(* ----------------------------------------------------------------- *)

PROCEDURE RandPos(VAR x, y: INTEGER);
BEGIN
  x := Random.Int(GridSize);
  y := Random.Int(GridSize)
END RandPos;

PROCEDURE Coloc(ax, ay, bx, by: INTEGER): BOOLEAN;
BEGIN
  RETURN (ax = bx) & (ay = by)
END Coloc;

PROCEDURE Near(ax, ay, bx, by, d: INTEGER): BOOLEAN;
  VAR dx, dy: INTEGER;
BEGIN
  dx := ax - bx;  IF dx < 0 THEN dx := -dx END;
  dy := ay - by;  IF dy < 0 THEN dy := -dy END;
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

(* ----------------------------------------------------------------- *)
(* Initialisation                                                     *)
(* ----------------------------------------------------------------- *)

PROCEDURE InjectAntigen(n: INTEGER);
  VAR i, x, y: INTEGER;
BEGIN
  i := 0;
  WHILE (i < n) & (nAg < MaxAntigens) DO
    RandPos(x, y);
    antigens[nAg].x := x;          antigens[nAg].y := y;
    antigens[nAg].age := 0;
    antigens[nAg].epitope := sharedEpitope;
    antigens[nAg].cleared := FALSE;
    INC(nAg);
    INC(i)
  END
END InjectAntigen;

PROCEDURE Initialise;
  VAR i, x, y, r: INTEGER;
BEGIN
  nAg := 0; nAb := 0; nB := 0; nTh := 0;
  nTc := 0; nMac := 0; nEC := 0; nHist := 0;
  sharedEpitope := RandU();

  FOR i := 0 TO InitialEC - 1 DO
    RandPos(x, y);
    epithelial[nEC].x := x;  epithelial[nEC].y := y;
    epithelial[nEC].age := 0;
    epithelial[nEC].infected := FALSE;
    epithelial[nEC].burstCountdown := 0;
    INC(nEC)
  END;

  FOR i := 0 TO InitialB - 1 DO
    RandPos(x, y);  r := RandU();
    bcells[nB].x := x; bcells[nB].y := y; bcells[nB].age := 0;
    bcells[nB].receptor := r;
    bcells[nB].activationCount := 0;
    bcells[nB].isMemory := FALSE;
    bcells[nB].hasPresented := FALSE;
    bcells[nB].presentedEpitope := 0;
    bcells[nB].plasma := FALSE;
    bcells[nB].plasmaAge := 0;
    INC(nB)
  END;

  FOR i := 0 TO InitialTh - 1 DO
    RandPos(x, y);  r := RandU();
    thelpers[nTh].x := x; thelpers[nTh].y := y; thelpers[nTh].age := 0;
    thelpers[nTh].receptor := r;
    thelpers[nTh].activationCount := 0;
    thelpers[nTh].hasPresented := FALSE;
    thelpers[nTh].presentedEpitope := 0;
    INC(nTh)
  END;

  FOR i := 0 TO InitialTc - 1 DO
    RandPos(x, y);  r := RandU();
    tcytos[nTc].x := x; tcytos[nTc].y := y; tcytos[nTc].age := 0;
    tcytos[nTc].receptor := r;
    tcytos[nTc].activationCount := 0;
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
      RandPos(x, y);
      r := MakeMatchedReceptor(sharedEpitope);
      bcells[nB].x := x; bcells[nB].y := y; bcells[nB].age := 0;
      bcells[nB].receptor := r;
      bcells[nB].activationCount := 0;
      bcells[nB].isMemory := FALSE;
      bcells[nB].hasPresented := FALSE;
      bcells[nB].presentedEpitope := 0;
      bcells[nB].plasma := FALSE;
      bcells[nB].plasmaAge := 0;
      INC(nB)
    END
  END;

  FOR i := 0 TO PrecursorTh - 1 DO
    IF nTh < MaxTHelpers THEN
      RandPos(x, y);
      r := MakeMatchedReceptor(sharedEpitope);
      thelpers[nTh].x := x; thelpers[nTh].y := y; thelpers[nTh].age := 0;
      thelpers[nTh].receptor := r;
      thelpers[nTh].activationCount := 0;
      thelpers[nTh].hasPresented := TRUE;
      thelpers[nTh].presentedEpitope := sharedEpitope;
      INC(nTh)
    END
  END;

  InjectAntigen(AntigenDose)
END Initialise;

(* ----------------------------------------------------------------- *)
(* Movement                                                           *)
(* ----------------------------------------------------------------- *)

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

(* ----------------------------------------------------------------- *)
(* Encounters                                                         *)
(* ----------------------------------------------------------------- *)

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
  VAR i, j: INTEGER;
      done: BOOLEAN;
BEGIN
  FOR i := 0 TO nMac - 1 DO
    IF ~macrophages[i].presenting THEN
      done := FALSE;
      j := 0;
      WHILE (j < nAg) & ~done DO
        IF ~antigens[j].cleared
           & Coloc(macrophages[i].x, macrophages[i].y,
                   antigens[j].x,    antigens[j].y)
           & (Random.Real() < EncounterProb) THEN
          antigens[j].cleared := TRUE;
          macrophages[i].presenting := TRUE;
          macrophages[i].presentEpitope := antigens[j].epitope;
          macrophages[i].presentCountdown := PresentDuration;
          done := TRUE
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
              bcells[nB].x := bcells[j].x;
              bcells[nB].y := bcells[j].y;
              bcells[nB].age := 0;
              bcells[nB].receptor := bcells[j].receptor;
              bcells[nB].presentedEpitope := bcells[j].presentedEpitope;
              bcells[nB].hasPresented := bcells[j].hasPresented;
              bcells[nB].activationCount := 0;
              bcells[nB].isMemory := FALSE;
              bcells[nB].plasma := FALSE;
              bcells[nB].plasmaAge := 0;
              IF Random.Real() < MemoryFraction THEN
                bcells[nB].isMemory := TRUE;
                bcells[nB].activationCount := thresh - 1
              END;
              bcells[nB].plasma := TRUE;
              bcells[nB].plasmaAge := 0;
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
      antibodies[nAb].x := bcells[i].x;
      antibodies[nAb].y := bcells[i].y;
      antibodies[nAb].age := 0;
      antibodies[nAb].paratope := paratope;
      INC(nAb)
    END
  END
END PlasmaSecretion;

PROCEDURE AntigenInfectsEpithelial;
  VAR i, j: INTEGER;
      done: BOOLEAN;
BEGIN
  FOR i := 0 TO nAg - 1 DO
    IF ~antigens[i].cleared THEN
      done := FALSE;
      j := 0;
      WHILE (j < nEC) & ~done DO
        IF ~epithelial[j].infected
           & Coloc(antigens[i].x, antigens[i].y,
                   epithelial[j].x, epithelial[j].y)
           & (Random.Real() < 0.15) THEN
          epithelial[j].infected := TRUE;
          epithelial[j].burstCountdown := 10;
          antigens[i].cleared := TRUE;
          done := TRUE
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

(* ----------------------------------------------------------------- *)
(* Age and prune                                                      *)
(* ----------------------------------------------------------------- *)

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
      IF w # i THEN antigens[w] := antigens[i] END;
      INC(w)
    END
  END;
  nAg := w;

  w := 0;
  FOR i := 0 TO nAb - 1 DO
    IF antibodies[i].age <= AbLifetime THEN
      IF w # i THEN antibodies[w] := antibodies[i] END;
      INC(w)
    END
  END;
  nAb := w;

  w := 0;
  FOR i := 0 TO nB - 1 DO
    IF ~(bcells[i].plasma & ~bcells[i].isMemory
         & (bcells[i].plasmaAge > PlasmaLifetime)) THEN
      IF w # i THEN bcells[w] := bcells[i] END;
      INC(w)
    END
  END;
  nB := w;

  w := 0;
  FOR i := 0 TO nEC - 1 DO
    IF ~(epithelial[i].infected & (epithelial[i].burstCountdown <= 0)) THEN
      IF w # i THEN epithelial[w] := epithelial[i] END;
      INC(w)
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

(* ----------------------------------------------------------------- *)
(* Recording and reporting                                            *)
(* ----------------------------------------------------------------- *)

PROCEDURE CountPlasma(): INTEGER;
  VAR i, n: INTEGER;
BEGIN
  n := 0;
  FOR i := 0 TO nB - 1 DO
    IF bcells[i].plasma THEN INC(n) END
  END;
  RETURN n
END CountPlasma;

PROCEDURE CountMemory(): INTEGER;
  VAR i, n: INTEGER;
BEGIN
  n := 0;
  FOR i := 0 TO nB - 1 DO
    IF bcells[i].isMemory THEN INC(n) END
  END;
  RETURN n
END CountMemory;

PROCEDURE CountInfected(): INTEGER;
  VAR i, n: INTEGER;
BEGIN
  n := 0;
  FOR i := 0 TO nEC - 1 DO
    IF epithelial[i].infected THEN INC(n) END
  END;
  RETURN n
END CountInfected;

PROCEDURE RecordStep(t: INTEGER);
BEGIN
  IF nHist < MaxHistory THEN
    history[nHist].t := t;
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

PROCEDURE PadInt(n, w: INTEGER);
  VAR s: ARRAY 16 OF CHAR;
      i, len: INTEGER;
BEGIN
  Strings.IntToStr(n, s);
  len := Strings.Length(s);
  FOR i := len TO w - 1 DO Out.Char(' ') END;
  Out.String(s)
END PadInt;

PROCEDURE PrintStatus(t: INTEGER);
BEGIN
  Out.String("t=");  PadInt(t, 3);
  Out.String(" | AG=");  PadInt(nAg, 4);
  Out.String(" AB=");    PadInt(nAb, 4);
  Out.String(" B=");     PadInt(nB,  3);
  Out.String(" Plasma="); PadInt(CountPlasma(), 3);
  Out.String(" MemB=");  PadInt(CountMemory(), 3);
  Out.String(" EC=");    PadInt(nEC, 3);
  Out.String(" Inf=");   PadInt(CountInfected(), 3);
  Out.Ln
END PrintStatus;

(* ----------------------------------------------------------------- *)
(* Main loop                                                          *)
(* ----------------------------------------------------------------- *)

PROCEDURE Run;
  VAR t: INTEGER;
BEGIN
  FOR t := 0 TO NSteps - 1 DO
    IF t = Challenge2 THEN
      InjectAntigen(AntigenDose);
      Out.Ln;
      Out.String("*** 2nd challenge t="); Out.Int(t, 0);
      Out.String(" | Memory B cells: "); Out.Int(CountMemory(), 0);
      Out.String(" ***"); Out.Ln; Out.Ln
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
    RecordStep(t);

    IF t MOD 20 = 0 THEN PrintStatus(t) END
  END
END Run;

(* ----------------------------------------------------------------- *)
(* CSV output                                                         *)
(* ----------------------------------------------------------------- *)

PROCEDURE WriteByte(VAR r: Files.Rider; n: INTEGER);
  VAR b: BYTE;
BEGIN
  b := n;
  Files.Write(r, b)
END WriteByte;

PROCEDURE WriteIntField(VAR r: Files.Rider; n: INTEGER; sep: CHAR);
  VAR s: ARRAY 16 OF CHAR;
      i: INTEGER;
BEGIN
  Strings.IntToStr(n, s);
  i := 0;
  WHILE s[i] # 0X DO WriteByte(r, ORD(s[i])); INC(i) END;
  WriteByte(r, ORD(sep))
END WriteIntField;

PROCEDURE WriteCSV(path: ARRAY OF CHAR);
  VAR f: Files.File;
      r: Files.Rider;
      header: ARRAY 80 OF CHAR;
      i, k: INTEGER;
BEGIN
  f := Files.New(path);
  IF f = NIL THEN
    Out.String("Failed to create "); Out.String(path); Out.Ln;
    RETURN
  END;
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
  Files.Close(f);
  Out.String("Results written to "); Out.String(path); Out.Ln
END WriteCSV;

(* ----------------------------------------------------------------- *)
(* Terminal plot: Antigen load vs. Antibody response                  *)
(* ----------------------------------------------------------------- *)

PROCEDURE MapPlot(t, v, tMax, vMax: INTEGER; VAR px, py: INTEGER);
  VAR plotW, plotH: INTEGER;
BEGIN
  plotW := PlotW - MarginL - MarginR;
  plotH := PlotH - MarginT - MarginB;
  px := MarginL + (t * plotW) DIV tMax;
  py := (MarginT + plotH) - (v * plotH) DIV vMax
END MapPlot;

PROCEDURE DrawAxes(tMax, vMax: INTEGER);
  VAR x0, y0, x1, y1, dummy, i, gx, gy: INTEGER;
BEGIN
  MapPlot(0,    0,    tMax, vMax, x0, y0);
  MapPlot(tMax, 0,    tMax, vMax, x1, dummy);
  MapPlot(0,    vMax, tMax, vMax, dummy, y1);

  FOR i := 1 TO 4 DO
    MapPlot(0, (vMax * i) DIV 4, tMax, vMax, dummy, gy);
    Terminal.Line(x0, gy, x1, gy, ColGrid)
  END;

  i := 50;
  WHILE i < tMax DO
    MapPlot(i, 0, tMax, vMax, gx, dummy);
    Terminal.Line(gx, y1, gx, y0, ColGrid);
    i := i + 50
  END;

  Terminal.Line(x0, y0, x1, y0, ColAxis);
  Terminal.Line(x0, y0, x0, y1, ColAxis)
END DrawAxes;

PROCEDURE DrawChallengeMarker(tMax, vMax: INTEGER);
  VAR px, yTop, yBot, dummy, y: INTEGER;
BEGIN
  MapPlot(Challenge2, 0,    tMax, vMax, px, yBot);
  MapPlot(Challenge2, vMax, tMax, vMax, dummy, yTop);
  y := yTop;
  WHILE y <= yBot DO
    Terminal.Plot(px, y,     ColMarker);
    Terminal.Plot(px, y + 1, ColMarker);
    y := y + 4
  END
END DrawChallengeMarker;

PROCEDURE DrawSeries(field, color, tMax, vMax: INTEGER);
  VAR i, v, prevV, px, py, ppx, ppy: INTEGER;
BEGIN
  IF nHist < 2 THEN RETURN END;
  IF field = 0 THEN prevV := history[0].antigens
  ELSE prevV := history[0].antibodies END;
  MapPlot(history[0].t, prevV, tMax, vMax, ppx, ppy);
  FOR i := 1 TO nHist - 1 DO
    IF field = 0 THEN v := history[i].antigens
    ELSE v := history[i].antibodies END;
    MapPlot(history[i].t, v, tMax, vMax, px, py);
    Terminal.Line(ppx, ppy, px, py, color);
    ppx := px; ppy := py
  END
END DrawSeries;

PROCEDURE DrawPlot;
  VAR i, tMax, vMax, maxAg, maxAb, plotRows: INTEGER;
      buf: ARRAY 16 OF CHAR;
      key: CHAR;
BEGIN
  IF nHist > 0 THEN tMax := history[nHist - 1].t ELSE tMax := NSteps END;
  IF tMax < 1 THEN tMax := 1 END;
  maxAg := 1; maxAb := 1;
  FOR i := 0 TO nHist - 1 DO
    IF history[i].antigens   > maxAg THEN maxAg := history[i].antigens   END;
    IF history[i].antibodies > maxAb THEN maxAb := history[i].antibodies END
  END;
  IF maxAg > maxAb THEN vMax := maxAg ELSE vMax := maxAb END;
  vMax := ((vMax + 9) DIV 10) * 10;
  IF vMax < 10 THEN vMax := 10 END;

  Terminal.Clear;
  Terminal.ClearBuf;

  Terminal.Goto(1, 1);
  Terminal.Color(7, 0);
  Out.String("Antigen load vs. Antibody response");

  DrawAxes(tMax, vMax);
  DrawChallengeMarker(tMax, vMax);
  DrawSeries(0, ColAntigen,  tMax, vMax);
  DrawSeries(1, ColAntibody, tMax, vMax);
  Terminal.Flush;

  plotRows := PlotH DIV 2;

  Terminal.Goto(1, 2);
  Strings.IntToStr(vMax, buf);  Out.String(buf);
  Terminal.Goto(1, 1 + plotRows DIV 2);
  Strings.IntToStr(vMax DIV 2, buf);  Out.String(buf);
  Terminal.Goto(1, plotRows);
  Out.String("0");

  Terminal.Goto(MarginL, plotRows + 1);
  Out.String("0");
  Terminal.Goto(MarginL + (PlotW - MarginL - MarginR) DIV 2 - 1,
               plotRows + 1);
  Strings.IntToStr(tMax DIV 2, buf);  Out.String(buf);
  Terminal.Goto(PlotW - MarginR - 3, plotRows + 1);
  Strings.IntToStr(tMax, buf);  Out.String(buf);
  Terminal.Goto(PlotW DIV 2 - 4, plotRows + 2);
  Out.String("Time step");

  Terminal.Goto(2, plotRows + 4);
  Terminal.Color256(ColAntigen, 0);
  Out.String("--- Antigens   ");
  Terminal.Color256(ColAntibody, 0);
  Out.String("--- Antibodies   ");
  Terminal.Color256(ColMarker, 0);
  Out.String("- - 2nd challenge (t=");
  Strings.IntToStr(Challenge2, buf);  Out.String(buf);
  Out.String(")");
  Terminal.Reset;
  Out.Ln;
  Out.String("Press any key to exit...");
  key := Terminal.ReadKey()
END DrawPlot;

BEGIN
  Initialise;
  Run;
  WriteCSV("immsim_results.csv");
  DrawPlot
END ImmSim.
