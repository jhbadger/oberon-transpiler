MODULE pdbview;

(*
  pdbview — Terminal PDB structure viewer built on TUI / Widgets / FileDialog.
  Rendering:
    Terminal  half-block pixel buffer 240x100
  Colour schemes:
    Chain       one colour per chain ID
    CPK/Element C=white N=blue O=red S=yellow ...
    B-factor    blue (low) to red (high)
    Secondary   helix=red  sheet=yellow  coil=white
  Keyboard shortcuts
    Arrow keys        Rotate around Y / X axis
    Shift+Up/Down     Rotate around Z axis
    + / -             Zoom in / out
    W A S D           Pan view
    R                 Reset view (clears picks)
    F                 Center view on picked atom
    M                 Cycle render mode (Backbone -> Ball-and-Stick -> Space Fill)
    H                 Toggle HETATM visibility
    C                 Cycle colour scheme (Chain->CPK->B-factor->Secondary)
    B                 Jump to B-factor colouring
    V                 Save SVG snapshot of current view
    Esc               Clear picked atoms
    PgUp / PgDn       Previous / next model
    F5                Reload current file
    Ctrl+O            Open file
    Ctrl+Q / Q        Quit
    F1                Help
    LMB drag          Rotate view (with inertia)
    LMB click         Pick atom (1st click picks, 2nd measures distance)
    RMB drag          Pan view
    Scroll wheel      Zoom
*)

IMPORT TUI, Widgets, FileDialog, Parallel, Files,
       BioPDB, Strings, Math, Terminal, Time, Args, Out;

(* ════════════════════════════════════════════════════════════════
   Constants
   ════════════════════════════════════════════════════════════════ *)

CONST
  ModeBackbone  = 0;
  ModeBallStick = 1;
  ModeSpaceFill = 2;

  ColourChain   = 0;
  ColourElement = 1;
  ColourBfactor = 2;
  ColourSecStr  = 3;

  RotStep     = 0.08;
  ZoomStep    = 1.1;
  InertDecay  = 0.85;
  InertCutoff = 0.002;

  MaxPickDist = 8;

  CmdOpen      = 10;
  CmdReload    = 11;
  CmdQuit      = 12;

  CmdModeBC    = 20;
  CmdModeBS    = 21;
  CmdModeSF    = 22;

  CmdColChain  = 30;
  CmdColElem   = 31;
  CmdColBfac   = 32;
  CmdColSS     = 33;

  CmdTogHet    = 40;
  CmdSaveSVG   = 45;

  CmdReset     = 50;
  CmdHelp      = 60;

  CmdNextModel = 70;
  CmdPrevModel = 71;

  CanvasW = 240;
  CanvasH = 100;

  SvgW = 800;
  SvgH = 600;

  MaxDraw = BioPDB.MaxAtoms;

(* ════════════════════════════════════════════════════════════════
   Types
   ════════════════════════════════════════════════════════════════ *)

TYPE
  Mat3 = ARRAY 9 OF REAL;

  DrawEntry = RECORD
    z     : REAL;
    idx   : INTEGER;
    projX : INTEGER;
    projY : INTEGER
  END;

  ProjCacheEntry = RECORD
    onScreen : BOOLEAN;
    z        : REAL;
    projX    : INTEGER;
    projY    : INTEGER
  END;

  ViewerWin  = POINTER TO ViewerWinRec;
  ViewerWinRec = RECORD (TUI.WindowRec)
    model        : BioPDB.Model;
    loaded       : BOOLEAN;
    filePath     : ARRAY 1024 OF CHAR;
    modelNo      : INTEGER;
    sceneDirty   : BOOLEAN;
    rot          : Mat3;
    scale        : REAL;
    panX, panY   : REAL;
    renderMode   : INTEGER;
    colourScheme : INTEGER;
    showHet      : BOOLEAN;
    inertDX      : REAL;
    inertDY      : REAL;
    inertDZ      : REAL;
    inertOn      : BOOLEAN;
    pickedAtom   : INTEGER;
    pickedAtom2  : INTEGER;
    dragActive   : BOOLEAN;
    dragLastX    : INTEGER;
    dragLastY    : INTEGER;
    rotDragActive : BOOLEAN;
    rotLastX     : INTEGER;
    rotLastY     : INTEGER;
    lmbMoved     : BOOLEAN;
    chainCount   : INTEGER;
    residueCount : INTEGER;
    drawBuf      : ARRAY MaxDraw OF DrawEntry;
    drawN        : INTEGER
  END;

(* ════════════════════════════════════════════════════════════════
   Module globals
   ════════════════════════════════════════════════════════════════ *)

CONST
  HelpN = 38;

VAR
  vw         : ViewerWin;
  mbar       : Widgets.MenuBar;
  sline      : Widgets.StatusLine;
  running    : BOOLEAN;
  statusMsg  : ARRAY 256 OF CHAR;
  projCache  : ARRAY MaxDraw OF ProjCacheEntry;
  helpScroll : INTEGER;
  helpWin    : TUI.Window;

(* ════════════════════════════════════════════════════════════════
   Matrix helpers
   ════════════════════════════════════════════════════════════════ *)

PROCEDURE MatIdentity(VAR m: Mat3);
BEGIN
  m[0]:=1.0; m[1]:=0.0; m[2]:=0.0;
  m[3]:=0.0; m[4]:=1.0; m[5]:=0.0;
  m[6]:=0.0; m[7]:=0.0; m[8]:=1.0
END MatIdentity;

PROCEDURE MatMul(VAR a, b: Mat3; VAR result: Mat3);
VAR i, j, k: INTEGER; tmp: Mat3;
BEGIN
  FOR i := 0 TO 2 DO
    FOR j := 0 TO 2 DO
      tmp[i*3+j] := 0.0;
      FOR k := 0 TO 2 DO
        tmp[i*3+j] := tmp[i*3+j] + a[i*3+k] * b[k*3+j]
      END
    END
  END;
  FOR i := 0 TO 8 DO result[i] := tmp[i] END
END MatMul;

PROCEDURE MatApply(VAR m: Mat3; x, y, z: REAL; VAR rx, ry, rz: REAL);
BEGIN
  rx := m[0]*x + m[1]*y + m[2]*z;
  ry := m[3]*x + m[4]*y + m[5]*z;
  rz := m[6]*x + m[7]*y + m[8]*z
END MatApply;

PROCEDURE RotY(VAR m: Mat3; angle: REAL);
VAR r, tmp: Mat3; c, s: REAL;
BEGIN
  c:=Math.cos(angle); s:=Math.sin(angle);
  r[0]:= c;  r[1]:=0.0; r[2]:=s;
  r[3]:=0.0; r[4]:=1.0; r[5]:=0.0;
  r[6]:=-s;  r[7]:=0.0; r[8]:=c;
  MatMul(r,m,tmp); m:=tmp
END RotY;

PROCEDURE RotX(VAR m: Mat3; angle: REAL);
VAR r, tmp: Mat3; c, s: REAL;
BEGIN
  c:=Math.cos(angle); s:=Math.sin(angle);
  r[0]:=1.0; r[1]:=0.0; r[2]:= 0.0;
  r[3]:=0.0; r[4]:= c;  r[5]:=-s;
  r[6]:=0.0; r[7]:= s;  r[8]:= c;
  MatMul(r,m,tmp); m:=tmp
END RotX;

PROCEDURE RotZ(VAR m: Mat3; angle: REAL);
VAR r, tmp: Mat3; c, s: REAL;
BEGIN
  c:=Math.cos(angle); s:=Math.sin(angle);
  r[0]:= c;  r[1]:=-s;  r[2]:=0.0;
  r[3]:= s;  r[4]:= c;  r[5]:=0.0;
  r[6]:=0.0; r[7]:=0.0; r[8]:=1.0;
  MatMul(r,m,tmp); m:=tmp
END RotZ;

PROCEDURE AtomDistance(v: ViewerWin; i, j: INTEGER): REAL;
VAR dx, dy, dz: REAL;
BEGIN
  dx := v.model.atoms[i].x - v.model.atoms[j].x;
  dy := v.model.atoms[i].y - v.model.atoms[j].y;
  dz := v.model.atoms[i].z - v.model.atoms[j].z;
  RETURN Math.sqrt(dx*dx + dy*dy + dz*dz)
END AtomDistance;

PROCEDURE CenterOnAtom(v: ViewerWin; i: INTEGER);
VAR px, py, centX, centY: INTEGER; pz: REAL;
BEGIN
  IF ~Project(v, i, px, py, pz) THEN RETURN END;
  centX := v.x + (v.w - 2) DIV 2;
  centY := (v.y + (v.h - 2) DIV 2) * 2;
  v.panX := v.panX + FLT(centX - px);
  v.panY := v.panY + FLT(centY - py)
END CenterOnAtom;

PROCEDURE ComputeCounts(v: ViewerWin);
VAR i: INTEGER; seen: ARRAY 256 OF BOOLEAN;
    prevChain: CHAR; prevRes: INTEGER;
BEGIN
  FOR i := 0 TO 255 DO seen[i] := FALSE END;
  v.chainCount := 0; v.residueCount := 0;
  prevChain := 0X; prevRes := -1;
  FOR i := 0 TO v.model.count-1 DO
    IF ~v.model.atoms[i].isHet THEN
      IF ~seen[ORD(v.model.atoms[i].chainID)] THEN
        seen[ORD(v.model.atoms[i].chainID)] := TRUE;
        INC(v.chainCount)
      END;
      IF (v.model.atoms[i].chainID # prevChain) OR (v.model.atoms[i].resSeq # prevRes) THEN
        INC(v.residueCount);
        prevChain := v.model.atoms[i].chainID;
        prevRes   := v.model.atoms[i].resSeq
      END
    END
  END
END ComputeCounts;

(* ════════════════════════════════════════════════════════════════
   Terminal colour helpers
   ════════════════════════════════════════════════════════════════ *)

PROCEDURE ChainColorTerm(ch: CHAR): INTEGER;
VAR i: INTEGER;
BEGIN
  i := ORD(ch) MOD 7;
  CASE i OF
    0:RETURN 196 | 1:RETURN 46  | 2:RETURN 21
  | 3:RETURN 226 | 4:RETURN 201 | 5:RETURN 51
  | 6:RETURN 255
  END; RETURN 255
END ChainColorTerm;

PROCEDURE ElementColorTerm(VAR elem: ARRAY OF CHAR): INTEGER;
BEGIN
  IF (elem[0]='C') & (elem[1]=0X) THEN RETURN 255
  ELSIF elem[0]='N' THEN RETURN  21
  ELSIF elem[0]='O' THEN RETURN 196
  ELSIF elem[0]='S' THEN RETURN 226
  ELSIF elem[0]='H' THEN RETURN 250
  ELSIF elem[0]='P' THEN RETURN 208
  ELSE                   RETURN  46
  END
END ElementColorTerm;

PROCEDURE BfacStop(b: REAL): INTEGER;
VAR t: INTEGER;
BEGIN
  IF b <   0.0 THEN b :=   0.0 END;
  IF b > 100.0 THEN b := 100.0 END;
  t := FLOOR(b / 100.0 * 4.0);
  IF t > 4 THEN t := 4 END;
  RETURN t
END BfacStop;

PROCEDURE BfactorColorTerm(b: REAL): INTEGER;
BEGIN
  CASE BfacStop(b) OF
    0:RETURN  21 | 1:RETURN  51 | 2:RETURN 255 | 3:RETURN 226
  ELSE RETURN 196
  END
END BfactorColorTerm;

PROCEDURE SSColorTerm(ss: INTEGER): INTEGER;
BEGIN
  CASE ss OF
    BioPDB.SSHelix : RETURN 196
  | BioPDB.SSSheet : RETURN 226
  ELSE               RETURN 255
  END
END SSColorTerm;

PROCEDURE DepthFactor(z, zMin, zMax: REAL): REAL;
VAR t: REAL;
BEGIN
  IF zMax > zMin THEN
    t := (z - zMin) / (zMax - zMin);
    IF t < 0.0 THEN t := 0.0 END;
    IF t > 1.0 THEN t := 1.0 END;
    RETURN 0.25 + 0.75 * t
  END;
  RETURN 1.0
END DepthFactor;

PROCEDURE DimTermColor(col: INTEGER; t: REAL): INTEGER;
VAR r, g, b, idx: INTEGER;
BEGIN
  IF col >= 232 THEN
    r := (col - 232) * 10 + 8; g := r; b := r
  ELSIF col >= 16 THEN
    idx := col - 16;
    r := (idx DIV 36) * 51;
    g := ((idx MOD 36) DIV 6) * 51;
    b := (idx MOD 6) * 51
  ELSE
    r := 170; g := 170; b := 170
  END;
  r := FLOOR(FLT(r) * t);
  g := FLOOR(FLT(g) * t);
  b := FLOOR(FLT(b) * t);
  IF (r = g) & (g = b) THEN
    IF r < 4  THEN RETURN 16 END;
    IF r > 252 THEN RETURN 231 END;
    RETURN FLOOR(FLT(r - 8) / 247.0 * 24.0 + 0.5) + 232
  END;
  r := FLOOR(FLT(r) / 255.0 * 5.0 + 0.5);
  g := FLOOR(FLT(g) / 255.0 * 5.0 + 0.5);
  b := FLOOR(FLT(b) / 255.0 * 5.0 + 0.5);
  RETURN 16 + 36 * r + 6 * g + b
END DimTermColor;

PROCEDURE AtomColorTerm(v: ViewerWin; i: INTEGER): INTEGER;
VAR ss: INTEGER;
BEGIN
  CASE v.colourScheme OF
    ColourChain   : RETURN ChainColorTerm(v.model.atoms[i].chainID)
  | ColourElement : RETURN ElementColorTerm(v.model.atoms[i].element)
  | ColourBfactor : RETURN BfactorColorTerm(v.model.atoms[i].tempFactor)
  | ColourSecStr  :
      ss := BioPDB.LookupSS(v.model, v.model.atoms[i].chainID,
                             v.model.atoms[i].resSeq);
      RETURN SSColorTerm(ss)
  END; RETURN 255
END AtomColorTerm;

(* ════════════════════════════════════════════════════════════════
   SVG colour helpers — RGB values matching the terminal palette
   ════════════════════════════════════════════════════════════════ *)

PROCEDURE ChainColorRGB(ch: CHAR; VAR r, g, b: INTEGER);
VAR i: INTEGER;
BEGIN
  i := ORD(ch) MOD 7;
  CASE i OF
    0: r:=220; g:= 40; b:= 40
  | 1: r:= 40; g:=200; b:= 40
  | 2: r:= 40; g:= 40; b:=220
  | 3: r:=220; g:=220; b:= 40
  | 4: r:=200; g:= 40; b:=200
  | 5: r:= 40; g:=200; b:=220
  | 6: r:=240; g:=240; b:=240
  END
END ChainColorRGB;

PROCEDURE ElementColorRGB(VAR elem: ARRAY OF CHAR; VAR r, g, b: INTEGER);
BEGIN
  IF (elem[0]='C') & (elem[1]=0X) THEN r:=220; g:=220; b:=220
  ELSIF elem[0]='N' THEN r:= 40; g:= 40; b:=255
  ELSIF elem[0]='O' THEN r:=255; g:= 40; b:= 40
  ELSIF elem[0]='S' THEN r:=255; g:=220; b:= 40
  ELSIF elem[0]='H' THEN r:=180; g:=180; b:=180
  ELSIF elem[0]='P' THEN r:=255; g:=140; b:= 40
  ELSE                   r:= 40; g:=200; b:= 40
  END
END ElementColorRGB;

PROCEDURE BfactorColorRGB(b: REAL; VAR r, g, bl: INTEGER);
BEGIN
  CASE BfacStop(b) OF
    0: r:= 40; g:= 40; bl:=255
  | 1: r:= 40; g:=220; bl:=220
  | 2: r:=240; g:=240; bl:=240
  | 3: r:=240; g:=240; bl:= 40
  ELSE r:=255; g:= 40; bl:= 40
  END
END BfactorColorRGB;

PROCEDURE SSColorRGB(ss: INTEGER; VAR r, g, b: INTEGER);
BEGIN
  CASE ss OF
    BioPDB.SSHelix : r:=220; g:= 40; b:= 40
  | BioPDB.SSSheet : r:=220; g:=200; b:= 40
  ELSE               r:=200; g:=200; b:=200
  END
END SSColorRGB;

PROCEDURE AtomColorRGB(v: ViewerWin; i: INTEGER; VAR r, g, b: INTEGER);
VAR ss: INTEGER;
BEGIN
  CASE v.colourScheme OF
    ColourChain   : ChainColorRGB(v.model.atoms[i].chainID, r, g, b)
  | ColourElement : ElementColorRGB(v.model.atoms[i].element, r, g, b)
  | ColourBfactor : BfactorColorRGB(v.model.atoms[i].tempFactor, r, g, b)
  | ColourSecStr  :
      ss := BioPDB.LookupSS(v.model, v.model.atoms[i].chainID,
                             v.model.atoms[i].resSeq);
      SSColorRGB(ss, r, g, b)
  END
END AtomColorRGB;

PROCEDURE HexDigit(n: INTEGER): CHAR;
BEGIN
  IF n < 10 THEN RETURN CHR(ORD('0') + n)
  ELSE RETURN CHR(ORD('a') + n - 10)
  END
END HexDigit;

PROCEDURE RGBToHex(r, g, b: INTEGER; VAR hex: ARRAY OF CHAR);
BEGIN
  hex[0] := '#';
  hex[1] := HexDigit(r DIV 16); hex[2] := HexDigit(r MOD 16);
  hex[3] := HexDigit(g DIV 16); hex[4] := HexDigit(g MOD 16);
  hex[5] := HexDigit(b DIV 16); hex[6] := HexDigit(b MOD 16);
  hex[7] := 0X
END RGBToHex;

(* ════════════════════════════════════════════════════════════════
   View reset
   ════════════════════════════════════════════════════════════════ *)

PROCEDURE RecenterView(v: ViewerWin);
VAR canW, canH: REAL;
BEGIN
  canW := FLT(v.w - 2);
  canH := FLT((v.h - 2) * 2);
  IF canW > FLT(CanvasW) THEN canW := FLT(CanvasW) END;
  IF canH > FLT(CanvasH) THEN canH := FLT(CanvasH) END;
  v.panX := canW / 2.0 + FLT(v.x + 1);
  v.panY := canH / 2.0 + FLT((v.y + 1) * 2)
END RecenterView;

PROCEDURE ResetView(v: ViewerWin);
VAR spanX, spanY, spanZ, span, canW, canH: REAL;
BEGIN
  MatIdentity(v.rot);
  RecenterView(v);
  IF v.loaded THEN
    canW := FLT(v.w - 2);
    canH := FLT((v.h - 2) * 2);
    IF canW > FLT(CanvasW) THEN canW := FLT(CanvasW) END;
    IF canH > FLT(CanvasH) THEN canH := FLT(CanvasH) END;
    spanX := v.model.maxX - v.model.minX;
    spanY := v.model.maxY - v.model.minY;
    spanZ := v.model.maxZ - v.model.minZ;
    span  := spanX;
    IF spanY > span THEN span := spanY END;
    IF spanZ > span THEN span := spanZ END;
    IF span < 1.0 THEN span := 1.0 END;
    IF canW < canH THEN v.scale := canW * 0.8 / span
    ELSE                v.scale := canH * 0.8 / span
    END
  ELSE
    v.scale := 4.0
  END
END ResetView;

(* ════════════════════════════════════════════════════════════════
   Painter sort (Quicksort Implementation)
   ════════════════════════════════════════════════════════════════ *)

PROCEDURE Swap(VAR a, b: DrawEntry);
VAR tmp: DrawEntry;
BEGIN
  tmp := a; a := b; b := tmp
END Swap;

PROCEDURE QuickSortRecursive(VAR buf: ARRAY OF DrawEntry; low, high: INTEGER);
VAR i, j: INTEGER; pivot: DrawEntry;
BEGIN
  IF low < high THEN
    i := low; j := high;
    pivot := buf[(low + high) DIV 2];
    REPEAT
      WHILE buf[i].z > pivot.z DO INC(i) END;
      WHILE buf[j].z < pivot.z DO DEC(j) END;
      IF i <= j THEN
        Swap(buf[i], buf[j]);
        INC(i); DEC(j);
      END;
    UNTIL i > j;
    QuickSortRecursive(buf, low, j);
    QuickSortRecursive(buf, i, high);
  END;
END QuickSortRecursive;

PROCEDURE SortDraw(VAR buf: ARRAY OF DrawEntry; n: INTEGER);
BEGIN
  IF n > 1 THEN
    QuickSortRecursive(buf, 0, n - 1)
  END
END SortDraw;

(* ════════════════════════════════════════════════════════════════
   Atom picking
   ════════════════════════════════════════════════════════════════ *)

PROCEDURE PickAtom(v: ViewerWin; mx, my, maxDist: INTEGER): INTEGER;
VAR i, best, dx, dy, dist, bestDist: INTEGER;
BEGIN
  best := -1; bestDist := maxDist*maxDist+1;
  FOR i := 0 TO v.drawN-1 DO
    dx := v.drawBuf[i].projX - mx;
    dy := v.drawBuf[i].projY - my;
    dist := dx*dx + dy*dy;
    IF dist < bestDist THEN bestDist := dist; best := i END
  END;
  IF best >= 0 THEN RETURN v.drawBuf[best].idx END;
  RETURN -1
END PickAtom;

(* ════════════════════════════════════════════════════════════════
   Projection
   ════════════════════════════════════════════════════════════════ *)

PROCEDURE Project(v: ViewerWin; i: INTEGER;
                  VAR px, py: INTEGER; VAR pz: REAL): BOOLEAN;
VAR ax, ay, az, rx, ry, rz: REAL;
BEGIN
  ax := v.model.atoms[i].x - v.model.cx;
  ay := v.model.atoms[i].y - v.model.cy;
  az := v.model.atoms[i].z - v.model.cz;
  MatApply(v.rot, ax, ay, az, rx, ry, rz);
  px := FLOOR(rx * v.scale + v.panX);
  py := FLOOR(-ry * v.scale + v.panY);
  pz := rz;
  RETURN (px >= 0) & (px < CanvasW) & (py >= 0) & (py < CanvasH)
END Project;

(* ════════════════════════════════════════════════════════════════
   Rendering
   ════════════════════════════════════════════════════════════════ *)

PROCEDURE ProjectAtomWorker(i: INTEGER);
VAR px, py: INTEGER; pz: REAL; a: BioPDB.Atom;
BEGIN
  a := vw.model.atoms[i];
  IF (~a.isHet OR vw.showHet) THEN
    IF Project(vw, i, px, py, pz) THEN
      projCache[i].onScreen := TRUE;
      projCache[i].projX := px;
      projCache[i].projY := py;
      projCache[i].z := pz;
    ELSE
      projCache[i].onScreen := FALSE;
    END;
  ELSE
    projCache[i].onScreen := FALSE;
  END;
END ProjectAtomWorker;

PROCEDURE RenderScene(v: ViewerWin);
VAR i, j, px, py, col, r: INTEGER;
    pz: REAL;
    a: BioPDB.Atom;
    prevChain: CHAR;
    prevPX, prevPY: INTEGER;
    prevOK, isBackbone: BOOLEAN;
    cx0, cy0, cx1, cy1: INTEGER;
    nThreads: INTEGER;
    zMin, zMax: REAL;
BEGIN
  cx0 := v.x + 1;  cx1 := v.x + v.w - 2;
  cy0 := (v.y + 1) * 2;  cy1 := (v.y + v.h - 2) * 2 + 1;
  IF cx0 < 0        THEN cx0 := 0        END;
  IF cy0 < 0        THEN cy0 := 0        END;
  IF cx1 >= CanvasW THEN cx1 := CanvasW-1 END;
  IF cy1 >= CanvasH THEN cy1 := CanvasH-1 END;
  Terminal.ClearBuf();

  IF ~v.loaded OR (v.model.count = 0) THEN
    Terminal.Flush();
    RETURN
  END;

  v.drawN := 0;
  nThreads := Parallel.NumCPU();
  IF nThreads < 1 THEN nThreads := 1 END;

  IF v.renderMode # ModeBackbone THEN
    Parallel.For(0, v.model.count, ProjectAtomWorker, nThreads);
    FOR i := 0 TO v.model.count-1 DO
      IF projCache[i].onScreen THEN
        px := projCache[i].projX;
        py := projCache[i].projY;
        IF (v.drawN < MaxDraw) &
           (px >= cx0) & (px <= cx1) & (py >= cy0) & (py <= cy1) THEN
          v.drawBuf[v.drawN].z     := projCache[i].z;
          v.drawBuf[v.drawN].idx   := i;
          v.drawBuf[v.drawN].projX := px;
          v.drawBuf[v.drawN].projY := py;
          INC(v.drawN);
        END;
      END;
    END;
  END;

  IF v.renderMode = ModeBackbone THEN
    FOR i := 0 TO v.model.count-1 DO
      a := v.model.atoms[i];
      isBackbone := ((Strings.Pos("CA", a.name) >= 0) OR
                     ((a.name[0] = 'P') & (a.name[1] = 0X))) & ~a.isHet;
      IF isBackbone THEN
        IF Project(v, i, px, py, pz) THEN
          projCache[i].onScreen := TRUE;
          projCache[i].projX := px; projCache[i].projY := py; projCache[i].z := pz;
          IF (v.drawN < MaxDraw) &
             (px >= cx0) & (px <= cx1) & (py >= cy0) & (py <= cy1) THEN
            v.drawBuf[v.drawN].z := pz; v.drawBuf[v.drawN].idx := i;
            v.drawBuf[v.drawN].projX := px; v.drawBuf[v.drawN].projY := py;
            INC(v.drawN)
          END
        ELSE
          projCache[i].onScreen := FALSE
        END
      ELSE
        projCache[i].onScreen := FALSE
      END
    END;
    zMin := 1.0E30; zMax := -1.0E30;
    FOR j := 0 TO v.drawN-1 DO
      IF v.drawBuf[j].z < zMin THEN zMin := v.drawBuf[j].z END;
      IF v.drawBuf[j].z > zMax THEN zMax := v.drawBuf[j].z END
    END;
    IF zMin >= zMax THEN zMin := zMax - 1.0 END;
    prevOK := FALSE; prevChain := 0X; prevPX := 0; prevPY := 0;
    FOR i := 0 TO v.model.count-1 DO
      a := v.model.atoms[i];
      isBackbone := ((Strings.Pos("CA", a.name) >= 0) OR
                     ((a.name[0] = 'P') & (a.name[1] = 0X))) & ~a.isHet;
      IF isBackbone THEN
        col := DimTermColor(AtomColorTerm(v, i),
               DepthFactor(projCache[i].z, zMin, zMax));
        IF projCache[i].onScreen THEN
          px := projCache[i].projX; py := projCache[i].projY; pz := projCache[i].z;
          py := py DIV 2 * 2;
          IF (px >= cx0) & (px <= cx1) & (py >= cy0) & (py <= cy1) THEN
            IF prevOK & (a.chainID = prevChain) THEN
              Terminal.Line(prevPX, prevPY, px, py, col)
            END;
            Terminal.Plot(px, py, col);
            prevPX := px; prevPY := py; prevChain := a.chainID; prevOK := TRUE
          ELSE prevOK := FALSE
          END
        ELSE prevOK := FALSE
        END
      END
    END
  END;

  IF v.renderMode # ModeBackbone THEN
    SortDraw(v.drawBuf, v.drawN);
    IF v.drawN > 0 THEN
      zMax := v.drawBuf[0].z; zMin := v.drawBuf[v.drawN-1].z
    ELSE
      zMax := 1.0; zMin := 0.0
    END;
    IF zMin >= zMax THEN zMin := zMax - 1.0 END;

    IF v.renderMode = ModeBallStick THEN
      prevOK := FALSE; prevChain := 0X;
      FOR i := 0 TO v.model.count-1 DO
        a := v.model.atoms[i];
        IF ~a.isHet THEN
          isBackbone := (Strings.Pos("CA", a.name) >= 0) OR
                        ((a.name[0] = 'P') & (a.name[1] = 0X));
          IF isBackbone & Project(v, i, px, py, pz) &
             (px >= cx0) & (px <= cx1) & (py >= cy0) & (py <= cy1) THEN
            IF prevOK & (a.chainID = prevChain) THEN
              Terminal.Line(prevPX, prevPY, px, py, 240)
            END;
            prevPX := px; prevPY := py; prevChain := a.chainID; prevOK := TRUE
          ELSIF isBackbone THEN prevOK := FALSE
          END
        END
      END;
      FOR j := 0 TO v.drawN-1 DO
        i   := v.drawBuf[j].idx;
        px  := v.drawBuf[j].projX;
        py  := v.drawBuf[j].projY;
        col := DimTermColor(AtomColorTerm(v, i),
               DepthFactor(v.drawBuf[j].z, zMin, zMax));
        a := v.model.atoms[i];
        IF a.element[0] = 'H' THEN r := 1 ELSE r := 2 END;
        Terminal.FillCircle(px, py, r, col)
      END

    ELSE (* ModeSpaceFill *)
      FOR j := v.drawN-1 TO 0 BY -1 DO
        i   := v.drawBuf[j].idx;
        px  := v.drawBuf[j].projX;
        py  := v.drawBuf[j].projY;
        col := DimTermColor(AtomColorTerm(v, i),
               DepthFactor(v.drawBuf[j].z, zMin, zMax));
        a := v.model.atoms[i];
        IF    a.element[0]='H' THEN r := FLOOR(1.2  * v.scale)
        ELSIF a.element[0]='C' THEN r := FLOOR(1.7  * v.scale)
        ELSIF a.element[0]='N' THEN r := FLOOR(1.55 * v.scale)
        ELSIF a.element[0]='O' THEN r := FLOOR(1.52 * v.scale)
        ELSIF a.element[0]='S' THEN r := FLOOR(1.8  * v.scale)
        ELSE                        r := FLOOR(1.7  * v.scale)
        END;
        IF r < 2  THEN r := 2  END;
        IF r > 60 THEN r := 60 END;
        Terminal.FillCircle(px, py, r, col)
      END
    END
  END;

  IF v.pickedAtom >= 0 THEN
    IF Project(v, v.pickedAtom, px, py, pz) &
       (px >= cx0) & (px <= cx1) & (py >= cy0) & (py <= cy1) THEN
      Terminal.Circle(px, py, 5, 51)
    END
  END;
  IF v.pickedAtom2 >= 0 THEN
    IF Project(v, v.pickedAtom2, px, py, pz) &
       (px >= cx0) & (px <= cx1) & (py >= cy0) & (py <= cy1) THEN
      Terminal.Circle(px, py, 5, 226)
    END
  END;

  Terminal.Flush()
END RenderScene;

(* ════════════════════════════════════════════════════════════════
   TUI draw callback
   ════════════════════════════════════════════════════════════════ *)

PROCEDURE DrawViewer(v: TUI.View);
VAR bfg, bbg: INTEGER;
    titleBuf: ARRAY 64 OF CHAR;
    tlen, tx: INTEGER;
BEGIN
  WITH v: ViewerWinRec DO
    IF v.focused THEN bfg := TUI.White; bbg := TUI.Blue
    ELSE              bfg := TUI.White; bbg := TUI.Black
    END;
    TUI.FillRect(v.x+1, v.y+1, v.w-2, v.h-2, ' ', TUI.White, TUI.Black);
    TUI.DrawBox(v.x, v.y, v.w, v.h, bfg, bbg);

    IF v.loaded THEN
      tlen := Strings.Length(v.filePath);
      WHILE (tlen > 0) & (v.filePath[tlen-1] # '/') DO DEC(tlen) END;
      Strings.Extract(v.filePath, tlen, Strings.Length(v.filePath)-tlen, titleBuf)
    ELSE Strings.Copy("[no file]", titleBuf)
    END;
    tlen := Strings.Length(titleBuf);
    IF tlen > v.w-4 THEN tlen := v.w-4 END;
    titleBuf[tlen] := 0X;
    tx := v.x + (v.w-tlen) DIV 2;
    TUI.PutStr(tx, v.y, titleBuf, TUI.Yellow, bbg);

    CASE v.renderMode OF
      ModeBackbone  : Strings.Copy(" Backbone ", titleBuf)
    | ModeBallStick : Strings.Copy(" Ball+Stk ", titleBuf)
    | ModeSpaceFill : Strings.Copy(" SpaceFill", titleBuf)
    END;
    TUI.PutStr(v.x+1, v.y+v.h-1, titleBuf, TUI.Cyan, bbg);

    CASE v.colourScheme OF
      ColourChain   : Strings.Copy(" Chain  ", titleBuf)
    | ColourElement : Strings.Copy(" CPK    ", titleBuf)
    | ColourBfactor : Strings.Copy(" B-fac  ", titleBuf)
    | ColourSecStr  : Strings.Copy(" 2ndStr ", titleBuf)
    END;
    TUI.PutStr(v.x+11, v.y+v.h-1, titleBuf, TUI.Green, bbg);

    IF v.showHet THEN TUI.PutStr(v.x+20, v.y+v.h-1, " HET ", TUI.Yellow, bbg) END;

    IF v.loaded THEN
      Strings.IntToStr(v.model.count, titleBuf);
      Strings.Append(" atoms", titleBuf);
      TUI.PutStr(v.x+v.w-Strings.Length(titleBuf)-2, v.y+v.h-1,
                 titleBuf, TUI.White, bbg)
    END
  END
END DrawViewer;

(* ════════════════════════════════════════════════════════════════
   TUI handle callback
   ════════════════════════════════════════════════════════════════ *)

PROCEDURE HandleViewer(v: TUI.View; ev: TUI.Event): BOOLEAN;
VAR ch: CHAR; dx, dy, newPick: INTEGER;
BEGIN
  WITH v: ViewerWinRec DO
    IF ev.kind = TUI.EvKey THEN
      ch := ev.key;
      IF    ch = TUI.KLeft      THEN RotY(v.rot,-RotStep); v.inertDX := -RotStep; v.inertDY := 0.0; v.inertDZ := 0.0; v.inertOn := TRUE
      ELSIF ch = TUI.KRight     THEN RotY(v.rot, RotStep); v.inertDX :=  RotStep; v.inertDY := 0.0; v.inertDZ := 0.0; v.inertOn := TRUE
      ELSIF ch = TUI.KUp        THEN RotX(v.rot,-RotStep); v.inertDX := 0.0; v.inertDY := -RotStep; v.inertDZ := 0.0; v.inertOn := TRUE
      ELSIF ch = TUI.KDown      THEN RotX(v.rot, RotStep); v.inertDX := 0.0; v.inertDY :=  RotStep; v.inertDZ := 0.0; v.inertOn := TRUE
      ELSIF ch = TUI.KShiftUp   THEN RotZ(v.rot,-RotStep); v.inertDX := 0.0; v.inertDY := 0.0; v.inertDZ := -RotStep; v.inertOn := TRUE
      ELSIF ch = TUI.KShiftDown THEN RotZ(v.rot, RotStep); v.inertDX := 0.0; v.inertDY := 0.0; v.inertDZ :=  RotStep; v.inertOn := TRUE
      ELSE
        v.inertOn := FALSE; v.inertDX := 0.0; v.inertDY := 0.0; v.inertDZ := 0.0;
        IF    (ch='+') OR (ch='=') THEN v.scale := v.scale * ZoomStep
        ELSIF  ch='-'               THEN v.scale := v.scale / ZoomStep
        ELSIF (ch='W') OR (ch='w') THEN v.panY := v.panY - 4.0
        ELSIF (ch='S') OR (ch='s') THEN v.panY := v.panY + 4.0
        ELSIF (ch='A') OR (ch='a') THEN v.panX := v.panX - 4.0
        ELSIF (ch='D') OR (ch='d') THEN v.panX := v.panX + 4.0
        ELSIF (ch='R') OR (ch='r') THEN
          ResetView(v); v.pickedAtom := -1; v.pickedAtom2 := -1
        ELSIF (ch='F') OR (ch='f') THEN
          IF v.pickedAtom >= 0 THEN CenterOnAtom(v, v.pickedAtom) END
        ELSIF (ch='M') OR (ch='m') THEN v.renderMode := (v.renderMode+1) MOD 3
        ELSIF (ch='C') OR (ch='c') THEN v.colourScheme := (v.colourScheme+1) MOD 4
        ELSIF (ch='H') OR (ch='h') THEN v.showHet := ~v.showHet
        ELSIF (ch='B') OR (ch='b') THEN
          IF v.colourScheme = ColourBfactor THEN v.colourScheme := ColourChain
          ELSE v.colourScheme := ColourBfactor END
        ELSIF (ch='V') OR (ch='v') THEN OnMenuCmd(CmdSaveSVG)
        ELSIF ch = TUI.KEsc  THEN v.pickedAtom := -1; v.pickedAtom2 := -1
        ELSIF ch = TUI.KPgUp THEN
          IF v.modelNo > 1 THEN v.modelNo := v.modelNo-1 END
        ELSIF ch = TUI.KPgDn THEN v.modelNo := v.modelNo+1
        ELSE RETURN FALSE
        END
      END;
      v.sceneDirty := TRUE;
      RETURN TRUE

    ELSIF ev.kind = TUI.EvMouse THEN
      IF ev.mb = 0 THEN
        v.rotDragActive := TRUE; v.lmbMoved := FALSE;
        v.rotLastX := ev.mx; v.rotLastY := ev.my
      ELSIF ev.mb = 2 THEN
        v.dragActive := TRUE; v.dragLastX := ev.mx; v.dragLastY := ev.my
      ELSIF ev.mb = 32 THEN
        IF v.rotDragActive THEN
          dx := ev.mx - v.rotLastX; dy := ev.my - v.rotLastY;
          IF (dx # 0) OR (dy # 0) THEN
            v.lmbMoved := TRUE;
            RotY(v.rot, FLT(dx) * 0.03);
            RotX(v.rot, FLT(dy) * 0.03);
            v.inertDX := FLT(dx) * 0.03;
            v.inertDY := FLT(dy) * 0.03;
            v.inertDZ := 0.0;
            v.rotLastX := ev.mx; v.rotLastY := ev.my;
            v.sceneDirty := TRUE
          END
        ELSIF v.dragActive THEN
          dx := ev.mx - v.dragLastX; dy := ev.my - v.dragLastY;
          v.panX := v.panX + FLT(dx);
          v.panY := v.panY + FLT(dy) * 2.0;
          v.dragLastX := ev.mx; v.dragLastY := ev.my; v.sceneDirty := TRUE
        END
      ELSIF ev.mb = 3 THEN
        IF v.rotDragActive THEN
          IF ~v.lmbMoved THEN
            v.inertOn := FALSE;
            newPick := PickAtom(v, ev.mx-1, (ev.my-1)*2+1, MaxPickDist);
            IF v.pickedAtom < 0 THEN
              v.pickedAtom := newPick; v.pickedAtom2 := -1
            ELSIF v.pickedAtom2 < 0 THEN
              v.pickedAtom2 := newPick
            ELSE
              v.pickedAtom := newPick; v.pickedAtom2 := -1
            END
          ELSE
            v.inertOn := (ABS(v.inertDX) > InertCutoff) OR (ABS(v.inertDY) > InertCutoff) OR
                         (ABS(v.inertDZ) > InertCutoff)
          END;
          v.rotDragActive := FALSE; v.sceneDirty := TRUE
        END;
        v.dragActive := FALSE
      ELSIF ev.mb = 64 THEN v.scale := v.scale * ZoomStep; v.sceneDirty := TRUE
      ELSIF ev.mb = 65 THEN v.scale := v.scale / ZoomStep; v.sceneDirty := TRUE
      END;
      RETURN TRUE
    END
  END;
  RETURN FALSE
END HandleViewer;

(* ════════════════════════════════════════════════════════════════
   Status update
   ════════════════════════════════════════════════════════════════ *)

PROCEDURE UpdateStatus;
VAR buf, tmp: ARRAY 256 OF CHAR; a: BioPDB.Atom; ss: INTEGER; dist: REAL;
BEGIN
  IF statusMsg[0] # 0X THEN
    Strings.Copy(statusMsg, buf)
  ELSIF (vw.pickedAtom >= 0) & (vw.pickedAtom2 >= 0) THEN
    a := vw.model.atoms[vw.pickedAtom];
    Strings.Copy("  ", buf);
    Strings.Append(a.resName, buf); Strings.Append(" ", buf);
    buf[Strings.Length(buf)] := a.chainID; buf[Strings.Length(buf)+1] := 0X;
    Strings.Append(" ", buf);
    Strings.IntToStr(a.resSeq, tmp); Strings.Append(tmp, buf);
    Strings.Append(" ", buf); Strings.Append(a.name, buf);
    Strings.Append(" <-> ", buf);
    a := vw.model.atoms[vw.pickedAtom2];
    Strings.Append(a.resName, buf); Strings.Append(" ", buf);
    buf[Strings.Length(buf)] := a.chainID; buf[Strings.Length(buf)+1] := 0X;
    Strings.Append(" ", buf);
    Strings.IntToStr(a.resSeq, tmp); Strings.Append(tmp, buf);
    Strings.Append(" ", buf); Strings.Append(a.name, buf);
    dist := AtomDistance(vw, vw.pickedAtom, vw.pickedAtom2);
    Strings.Append("  dist:", buf);
    Strings.RealToStr(dist, tmp); Strings.Append(tmp, buf);
    Strings.Append(" A  [Esc=clear]", buf)
  ELSIF vw.pickedAtom >= 0 THEN
    a := vw.model.atoms[vw.pickedAtom];
    Strings.Copy("  Picked: ", buf);
    IF a.isHet THEN Strings.Append("HETATM ", buf)
    ELSE Strings.Append("ATOM ", buf) END;
    Strings.Append(a.name, buf); Strings.Append(" ", buf);
    Strings.Append(a.resName, buf); Strings.Append(" ", buf);
    buf[Strings.Length(buf)] := a.chainID; buf[Strings.Length(buf)+1] := 0X;
    Strings.Append(" ", buf);
    Strings.IntToStr(a.resSeq, tmp);      Strings.Append(tmp, buf);
    Strings.Append("  elem:", buf);       Strings.Append(a.element, buf);
    Strings.Append("  B:", buf);
    Strings.RealToStr(a.tempFactor, tmp); Strings.Append(tmp, buf);
    ss := BioPDB.LookupSS(vw.model, a.chainID, a.resSeq);
    Strings.Append("  ss:", buf);
    CASE ss OF
      BioPDB.SSHelix : Strings.Append("helix", buf)
    | BioPDB.SSSheet : Strings.Append("sheet", buf)
    ELSE               Strings.Append("coil",  buf)
    END;
    Strings.Append("  [click 2nd atom=dist  Esc=clear]", buf)
  ELSIF vw.loaded THEN
    Strings.Copy("  Atoms:", buf);
    Strings.IntToStr(vw.model.count, tmp); Strings.Append(tmp, buf);
    Strings.Append("  Res:", buf);
    Strings.IntToStr(vw.residueCount, tmp); Strings.Append(tmp, buf);
    Strings.Append("  Ch:", buf);
    Strings.IntToStr(vw.chainCount, tmp); Strings.Append(tmp, buf);
    Strings.Append("  SS:", buf);
    Strings.IntToStr(vw.model.ssCount, tmp); Strings.Append(tmp, buf);
    Strings.Append("  Mdl:", buf);
    Strings.IntToStr(vw.modelNo, tmp); Strings.Append(tmp, buf);
    Strings.Append("  LMBdrag:rot  WASD:pan  +/-:zoom  F:center  R:reset  M:mode  C:col  H:het  V:svg", buf)
  ELSE
    Strings.Copy("  No file loaded. Ctrl+O to open.", buf)
  END;
  IF Strings.Length(buf) > TUI.Cols - 1 THEN buf[TUI.Cols - 1] := 0X END;
  Strings.Copy(buf, sline.text);
  statusMsg[0] := 0X
END UpdateStatus;

(* ════════════════════════════════════════════════════════════════
   File loading
   ════════════════════════════════════════════════════════════════ *)

PROCEDURE LoadPDB(path: ARRAY OF CHAR; modelNo: INTEGER);
VAR err: INTEGER; tmp: ARRAY 16 OF CHAR;
BEGIN
  IF BioPDB.LoadModel(path, vw.model, modelNo, err) THEN
    Strings.Copy(path, vw.filePath);
    vw.modelNo    := modelNo;
    vw.loaded     := TRUE;
    vw.pickedAtom := -1; vw.pickedAtom2 := -1;
    ResetView(vw);
    ComputeCounts(vw);
    Strings.Copy("Loaded.", statusMsg)
  ELSE
    vw.loaded := FALSE;
    Strings.Copy("Failed to load PDB (err=", statusMsg);
    Strings.IntToStr(err, tmp); Strings.Append(tmp, statusMsg);
    Strings.Append(").", statusMsg)
  END;
  vw.sceneDirty := TRUE
END LoadPDB;

(* ════════════════════════════════════════════════════════════════
   SVG export
   ════════════════════════════════════════════════════════════════ *)

PROCEDURE WStr(VAR rd: Files.Rider; s: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  i := 0; WHILE s[i] # 0X DO Files.Write(rd, ORD(s[i])); INC(i) END
END WStr;

PROCEDURE WInt(VAR rd: Files.Rider; n: INTEGER);
VAR buf: ARRAY 16 OF CHAR;
BEGIN Strings.IntToStr(n, buf); WStr(rd, buf) END WInt;

PROCEDURE WReal1(VAR rd: Files.Rider; x: REAL);
VAR buf: ARRAY 24 OF CHAR;
BEGIN Strings.RealToStr(x, buf); WStr(rd, buf) END WReal1;

PROCEDURE SaveSVG(v: ViewerWin);
VAR f: Files.File; rd: Files.Rider;
    svgPath: ARRAY 1024 OF CHAR;
    i, j, px, py, r2: INTEGER;
    pz, ax, ay, az, rx, ry, rz: REAL;
    a: BioPDB.Atom;
    prevChain: CHAR;
    prevPX, prevPY: INTEGER;
    prevOK, isBackbone, firstSeg: BOOLEAN;
    cr, cg, cb: INTEGER;
    hex: ARRAY 8 OF CHAR;
    sc, panX, panY: REAL;
    spanX, spanY, spanZ, span: REAL;
    zMin, zMax, opac: REAL;
    drawBuf: ARRAY MaxDraw OF DrawEntry;
    drawN: INTEGER;
BEGIN
  IF ~v.loaded THEN
    Strings.Copy("No file loaded.", statusMsg); RETURN
  END;

  (* Build output path: strip extension, add .svg *)
  Strings.Copy(v.filePath, svgPath);
  i := Strings.Length(svgPath);
  WHILE (i > 0) & (svgPath[i-1] # '.') & (svgPath[i-1] # '/') DO DEC(i) END;
  IF (i > 0) & (svgPath[i-1] = '.') THEN DEC(i); svgPath[i] := 0X END;
  Strings.Append(".svg", svgPath);

  f := Files.New(svgPath);
  IF f = NIL THEN Strings.Copy("Cannot create SVG.", statusMsg); RETURN END;
  Files.Set(rd, f, 0);

  (* Auto-fit scale for SVG canvas using current rotation *)
  spanX := v.model.maxX - v.model.minX;
  spanY := v.model.maxY - v.model.minY;
  spanZ := v.model.maxZ - v.model.minZ;
  span  := spanX;
  IF spanY > span THEN span := spanY END;
  IF spanZ > span THEN span := spanZ END;
  IF span < 1.0 THEN span := 1.0 END;
  IF SvgW < SvgH THEN sc := FLT(SvgW) * 0.8 / span
  ELSE                sc := FLT(SvgH) * 0.8 / span
  END;
  panX := FLT(SvgW DIV 2);
  panY := FLT(SvgH DIV 2);

  WStr(rd, '<?xml version="1.0" encoding="UTF-8"?>');
  Files.Write(rd, 10);
  WStr(rd, '<svg xmlns="http://www.w3.org/2000/svg" width="');
  WInt(rd, SvgW); WStr(rd, '" height="'); WInt(rd, SvgH);
  WStr(rd, '" style="background:#111">'); Files.Write(rd, 10);

  (* Project all atoms for this export *)
  drawN := 0;
  FOR i := 0 TO v.model.count-1 DO
    a := v.model.atoms[i];
    IF ~a.isHet OR v.showHet THEN
      ax := a.x - v.model.cx; ay := a.y - v.model.cy; az := a.z - v.model.cz;
      MatApply(v.rot, ax, ay, az, rx, ry, rz);
      px := FLOOR(rx * sc + panX);
      py := FLOOR(-ry * sc + panY);
      IF (px >= 0) & (px < SvgW) & (py >= 0) & (py < SvgH) & (drawN < MaxDraw) THEN
        drawBuf[drawN].z := rz; drawBuf[drawN].idx := i;
        drawBuf[drawN].projX := px; drawBuf[drawN].projY := py;
        INC(drawN)
      END
    END
  END;

  IF v.renderMode # ModeBackbone THEN
    SortDraw(drawBuf, drawN);
    IF drawN > 0 THEN
      zMax := drawBuf[0].z; zMin := drawBuf[drawN-1].z
    ELSE
      zMax := 1.0; zMin := 0.0
    END;
    IF zMin >= zMax THEN zMin := zMax - 1.0 END
  END;

  IF v.renderMode = ModeBackbone THEN
    (* Collect z range over backbone atoms only *)
    zMin := 1.0E30; zMax := -1.0E30;
    FOR j := 0 TO drawN-1 DO
      i := drawBuf[j].idx; a := v.model.atoms[i];
      isBackbone := ((Strings.Pos("CA", a.name) >= 0) OR
                     ((a.name[0] = 'P') & (a.name[1] = 0X))) & ~a.isHet;
      IF isBackbone THEN
        IF drawBuf[j].z < zMin THEN zMin := drawBuf[j].z END;
        IF drawBuf[j].z > zMax THEN zMax := drawBuf[j].z END
      END
    END;
    IF zMin >= zMax THEN zMin := zMax - 1.0 END;

    (* Emit backbone polylines per chain, in atom order *)
    prevOK := FALSE; prevChain := 0X; prevPX := 0; prevPY := 0;
    FOR i := 0 TO v.model.count-1 DO
      a := v.model.atoms[i];
      IF ~a.isHet OR v.showHet THEN
        isBackbone := ((Strings.Pos("CA", a.name) >= 0) OR
                       ((a.name[0] = 'P') & (a.name[1] = 0X))) & ~a.isHet;
        IF isBackbone THEN
          ax := a.x - v.model.cx; ay := a.y - v.model.cy; az := a.z - v.model.cz;
          MatApply(v.rot, ax, ay, az, rx, ry, rz);
          px := FLOOR(rx * sc + panX);
          py := FLOOR(-ry * sc + panY);
          IF (px >= 0) & (px < SvgW) & (py >= 0) & (py < SvgH) THEN
            AtomColorRGB(v, i, cr, cg, cb);
            opac := 0.35 + 0.65 * DepthFactor(rz, zMin, zMax);
            RGBToHex(cr, cg, cb, hex);
            IF prevOK & (a.chainID = prevChain) THEN
              WStr(rd, '<line x1="'); WInt(rd, prevPX);
              WStr(rd, '" y1="'); WInt(rd, prevPY);
              WStr(rd, '" x2="'); WInt(rd, px);
              WStr(rd, '" y2="'); WInt(rd, py);
              WStr(rd, '" stroke="'); WStr(rd, hex);
              WStr(rd, '" stroke-width="1.5" opacity="');
              WReal1(rd, opac); WStr(rd, '"/>'); Files.Write(rd, 10)
            END;
            WStr(rd, '<circle cx="'); WInt(rd, px);
            WStr(rd, '" cy="'); WInt(rd, py);
            WStr(rd, '" r="2" fill="'); WStr(rd, hex);
            WStr(rd, '" opacity="'); WReal1(rd, opac);
            WStr(rd, '"/>'); Files.Write(rd, 10);
            prevPX := px; prevPY := py; prevChain := a.chainID; prevOK := TRUE
          ELSE prevOK := FALSE
          END
        END
      END
    END

  ELSIF v.renderMode = ModeBallStick THEN
    (* Backbone sticks first (grey), then atoms front-to-back *)
    prevOK := FALSE; prevChain := 0X;
    FOR i := 0 TO v.model.count-1 DO
      a := v.model.atoms[i];
      IF ~a.isHet THEN
        isBackbone := (Strings.Pos("CA", a.name) >= 0) OR
                      ((a.name[0] = 'P') & (a.name[1] = 0X));
        IF isBackbone THEN
          ax := a.x - v.model.cx; ay := a.y - v.model.cy; az := a.z - v.model.cz;
          MatApply(v.rot, ax, ay, az, rx, ry, rz);
          px := FLOOR(rx * sc + panX);
          py := FLOOR(-ry * sc + panY);
          IF (px >= 0) & (px < SvgW) & (py >= 0) & (py < SvgH) THEN
            IF prevOK & (a.chainID = prevChain) THEN
              WStr(rd, '<line x1="'); WInt(rd, prevPX);
              WStr(rd, '" y1="'); WInt(rd, prevPY);
              WStr(rd, '" x2="'); WInt(rd, px);
              WStr(rd, '" y2="'); WInt(rd, py);
              WStr(rd, '" stroke="#666" stroke-width="1"/>'); Files.Write(rd, 10)
            END;
            prevPX := px; prevPY := py; prevChain := a.chainID; prevOK := TRUE
          ELSE prevOK := FALSE
          END
        END
      END
    END;
    FOR j := drawN-1 TO 0 BY -1 DO
      i := drawBuf[j].idx; px := drawBuf[j].projX; py := drawBuf[j].projY;
      AtomColorRGB(v, i, cr, cg, cb);
      RGBToHex(cr, cg, cb, hex);
      opac := 0.4 + 0.6 * DepthFactor(drawBuf[j].z, zMin, zMax);
      a := v.model.atoms[i];
      IF a.element[0] = 'H' THEN r2 := 3 ELSE r2 := 5 END;
      WStr(rd, '<circle cx="'); WInt(rd, px);
      WStr(rd, '" cy="'); WInt(rd, py);
      WStr(rd, '" r="'); WInt(rd, r2);
      WStr(rd, '" fill="'); WStr(rd, hex);
      WStr(rd, '" opacity="'); WReal1(rd, opac);
      WStr(rd, '"/>'); Files.Write(rd, 10)
    END

  ELSE (* ModeSpaceFill — draw back-to-front *)
    FOR j := drawN-1 TO 0 BY -1 DO
      i := drawBuf[j].idx; px := drawBuf[j].projX; py := drawBuf[j].projY;
      AtomColorRGB(v, i, cr, cg, cb);
      RGBToHex(cr, cg, cb, hex);
      opac := 0.5 + 0.5 * DepthFactor(drawBuf[j].z, zMin, zMax);
      a := v.model.atoms[i];
      IF    a.element[0]='H' THEN r2 := FLOOR(1.2  * sc)
      ELSIF a.element[0]='C' THEN r2 := FLOOR(1.7  * sc)
      ELSIF a.element[0]='N' THEN r2 := FLOOR(1.55 * sc)
      ELSIF a.element[0]='O' THEN r2 := FLOOR(1.52 * sc)
      ELSIF a.element[0]='S' THEN r2 := FLOOR(1.8  * sc)
      ELSE                        r2 := FLOOR(1.7  * sc)
      END;
      IF r2 < 2 THEN r2 := 2 END;
      WStr(rd, '<circle cx="'); WInt(rd, px);
      WStr(rd, '" cy="'); WInt(rd, py);
      WStr(rd, '" r="'); WInt(rd, r2);
      WStr(rd, '" fill="'); WStr(rd, hex);
      WStr(rd, '" opacity="'); WReal1(rd, opac);
      WStr(rd, '"/>'); Files.Write(rd, 10)
    END
  END;

  WStr(rd, "</svg>"); Files.Write(rd, 10);
  Files.Register(f);
  Files.Close(f);
  Strings.Copy("SVG saved: ", statusMsg);
  Strings.Append(svgPath, statusMsg)
END SaveSVG;

(* ════════════════════════════════════════════════════════════════
   Built-in help popup
   ════════════════════════════════════════════════════════════════ *)

PROCEDURE HelpLine(i: INTEGER; VAR s: ARRAY OF CHAR);
BEGIN
  CASE i OF
    0: Strings.Copy("pdbview  —  Terminal PDB Structure Viewer", s)
  | 1: Strings.Copy("", s)
  | 2: Strings.Copy("# Rotation", s)
  | 3: Strings.Copy("  Arrow keys         Rotate around Y / X axis", s)
  | 4: Strings.Copy("  Shift+Up/Down      Rotate around Z axis", s)
  | 5: Strings.Copy("  LMB drag           Rotate (with inertia)", s)
  | 6: Strings.Copy("", s)
  | 7: Strings.Copy("# Zoom & Pan", s)
  | 8: Strings.Copy("  + / -              Zoom in / out", s)
  | 9: Strings.Copy("  Scroll wheel       Zoom in / out", s)
  | 10: Strings.Copy("  W A S D            Pan view", s)
  | 11: Strings.Copy("  RMB drag           Pan view", s)
  | 12: Strings.Copy("", s)
  | 13: Strings.Copy("# Render Mode  (M cycles)", s)
  | 14: Strings.Copy("  Backbone           CA / P trace", s)
  | 15: Strings.Copy("  Ball+Stick         Atoms + backbone sticks", s)
  | 16: Strings.Copy("  Space Fill         Van der Waals spheres", s)
  | 17: Strings.Copy("", s)
  | 18: Strings.Copy("# Colour Scheme  (C cycles)", s)
  | 19: Strings.Copy("  Chain              One colour per chain", s)
  | 20: Strings.Copy("  CPK / Element      C=grey N=blue O=red S=yellow", s)
  | 21: Strings.Copy("  B-factor           Blue (low) → Red (high)", s)
  | 22: Strings.Copy("  Secondary          Helix=red  Sheet=yellow  Coil=white", s)
  | 23: Strings.Copy("  B                  Toggle B-factor colouring", s)
  | 24: Strings.Copy("", s)
  | 25: Strings.Copy("# Picking", s)
  | 26: Strings.Copy("  LMB click          Pick atom (shows residue / B / SS)", s)
  | 27: Strings.Copy("  LMB click (2nd)    Measure distance to 2nd atom", s)
  | 28: Strings.Copy("  F                  Centre view on picked atom", s)
  | 29: Strings.Copy("  Esc                Clear picked atoms", s)
  | 30: Strings.Copy("", s)
  | 31: Strings.Copy("# Files & Models", s)
  | 32: Strings.Copy("  Ctrl+O             Open PDB file", s)
  | 33: Strings.Copy("  F5                 Reload current file", s)
  | 34: Strings.Copy("  H                  Toggle HETATM visibility", s)
  | 35: Strings.Copy("  V                  Save SVG snapshot", s)
  | 36: Strings.Copy("  PgUp / PgDn        Previous / next model", s)
  | 37: Strings.Copy("  R                  Reset view", s)
  | 38: Strings.Copy("  Ctrl+Q / Q         Quit", s)
  ELSE  s[0] := 0X
  END
END HelpLine;

PROCEDURE DrawHelpWin(v: TUI.View);
VAR row, contentH: INTEGER;
    line: ARRAY 64 OF CHAR;
    fg, li: INTEGER;
BEGIN
  WITH v: TUI.WindowRec DO
    TUI.FillRect(v.x+1, v.y+1, v.w-2, v.h-2, ' ', TUI.White, TUI.Black);
    TUI.DrawBox(v.x, v.y, v.w, v.h, TUI.White, TUI.Blue);
    TUI.PutStr(v.x + (v.w - 8) DIV 2, v.y, " Help ", TUI.Yellow, TUI.Blue);
    contentH := v.h - 3;
    FOR row := 0 TO contentH - 1 DO
      li := helpScroll + row;
      IF li <= HelpN THEN
        HelpLine(li, line);
        IF line[0] = '#' THEN
          fg := TUI.Cyan;
          Strings.Extract(line, 2, Strings.Length(line) - 2, line)
        ELSIF line[0] = 0X THEN
          fg := TUI.White
        ELSE
          fg := TUI.White
        END;
        IF line[0] # 0X THEN
          TUI.PutStr(v.x + 2, v.y + 1 + row, line, fg, TUI.Black)
        END
      END
    END;
    TUI.FillRect(v.x+1, v.y+v.h-2, v.w-2, 1, ' ', TUI.Black, TUI.White);
    TUI.PutStr(v.x+2, v.y+v.h-2,
      "Up/Dn/PgUp/PgDn: scroll   Esc/Q/Enter: close", TUI.Black, TUI.White)
  END
END DrawHelpWin;

PROCEDURE ShowHelp;
VAR ev: TUI.Event; ch: CHAR;
    savedDesktop: TUI.View; savedFocus: TUI.View;
    dw, dh, dx, dy, contentH, maxScroll: INTEGER;
BEGIN
  savedDesktop := TUI.Desktop;
  savedFocus   := TUI.Focused;
  TUI.Desktop  := NIL;
  TUI.Focused  := NIL;
  helpScroll   := 0;

  dw := 62; dh := 24;
  IF TUI.Cols - 4 < dw THEN dw := TUI.Cols - 4 END;
  IF TUI.Rows - 4 < dh THEN dh := TUI.Rows - 4 END;
  IF dw < 40 THEN dw := 40 END;
  IF dh < 10 THEN dh := 10 END;
  dx := (TUI.Cols - dw) DIV 2 + 1;
  dy := (TUI.Rows - dh) DIV 2 + 1;
  contentH := dh - 3;

  NEW(helpWin);
  helpWin.x := dx; helpWin.y := dy; helpWin.w := dw; helpWin.h := dh;
  helpWin.title[0] := 0X; helpWin.moveable := FALSE;
  helpWin.draw := DrawHelpWin; helpWin.handle := NIL;
  helpWin.next := NIL; helpWin.child := NIL;
  helpWin.focused := FALSE; helpWin.alwaysOnTop := FALSE;
  TUI.AddView(helpWin);

  REPEAT
    TUI.ClearBack(TUI.White, TUI.Black);
    TUI.DrawAll();
    TUI.Flush();
    TUI.WaitEvent(ev);
    IF ev.kind = TUI.EvKey THEN
      ch := ev.key;
      maxScroll := HelpN - contentH + 1;
      IF maxScroll < 0 THEN maxScroll := 0 END;
      IF (ch = TUI.KEsc) OR (ch = 'q') OR (ch = 'Q') OR
         (ch = TUI.KEnter) OR (ch = ' ') THEN
        helpScroll := -1   (* sentinel to exit *)
      ELSIF ch = TUI.KUp THEN
        IF helpScroll > 0 THEN DEC(helpScroll) END
      ELSIF ch = TUI.KDown THEN
        IF helpScroll < maxScroll THEN INC(helpScroll) END
      ELSIF ch = TUI.KPgUp THEN
        DEC(helpScroll, contentH);
        IF helpScroll < 0 THEN helpScroll := 0 END
      ELSIF ch = TUI.KPgDn THEN
        INC(helpScroll, contentH);
        IF helpScroll > maxScroll THEN helpScroll := maxScroll END
      END
    ELSIF ev.kind = TUI.EvMouse THEN
      maxScroll := HelpN - contentH + 1;
      IF maxScroll < 0 THEN maxScroll := 0 END;
      IF ev.mb = 64 THEN
        IF helpScroll > 0 THEN DEC(helpScroll) END
      ELSIF ev.mb = 65 THEN
        IF helpScroll < maxScroll THEN INC(helpScroll) END
      END
    ELSIF ev.kind = TUI.EvResize THEN
      TUI.InvalidateFront()
    END
  UNTIL helpScroll < 0;

  TUI.Desktop := savedDesktop;
  TUI.SetFocus(savedFocus)
END ShowHelp;

(* ════════════════════════════════════════════════════════════════
   Menu command handler
   ════════════════════════════════════════════════════════════════ *)

PROCEDURE OnMenuCmd(cmd: INTEGER);
VAR path: ARRAY 1024 OF CHAR; ok: BOOLEAN;
BEGIN
  IF cmd = CmdOpen THEN
    ok := FileDialog.Show("Open PDB File", "", ".pdb", path);
    IF ok THEN LoadPDB(path, 1) END
  ELSIF cmd = CmdReload THEN
    IF vw.loaded THEN LoadPDB(vw.filePath, vw.modelNo)
    ELSE Strings.Copy("No file to reload.", statusMsg) END
  ELSIF cmd = CmdQuit    THEN running := FALSE
  ELSIF cmd = CmdModeBC  THEN vw.renderMode  := ModeBackbone;  vw.sceneDirty := TRUE
  ELSIF cmd = CmdModeBS  THEN vw.renderMode  := ModeBallStick; vw.sceneDirty := TRUE
  ELSIF cmd = CmdModeSF  THEN vw.renderMode  := ModeSpaceFill; vw.sceneDirty := TRUE
  ELSIF cmd = CmdColChain THEN vw.colourScheme := ColourChain;   vw.sceneDirty := TRUE
  ELSIF cmd = CmdColElem  THEN vw.colourScheme := ColourElement; vw.sceneDirty := TRUE
  ELSIF cmd = CmdColBfac  THEN vw.colourScheme := ColourBfactor; vw.sceneDirty := TRUE
  ELSIF cmd = CmdColSS    THEN vw.colourScheme := ColourSecStr;  vw.sceneDirty := TRUE
  ELSIF cmd = CmdTogHet   THEN vw.showHet := ~vw.showHet; vw.sceneDirty := TRUE
  ELSIF cmd = CmdSaveSVG  THEN SaveSVG(vw)
  ELSIF cmd = CmdReset THEN
    ResetView(vw); vw.inertDX:=0.0; vw.inertDY:=0.0; vw.inertDZ:=0.0;
    vw.pickedAtom:=-1; vw.pickedAtom2:=-1; vw.sceneDirty:=TRUE
  ELSIF cmd = CmdNextModel THEN
    IF vw.loaded THEN LoadPDB(vw.filePath, vw.modelNo+1) END
  ELSIF cmd = CmdPrevModel THEN
    IF vw.loaded & (vw.modelNo > 1) THEN LoadPDB(vw.filePath, vw.modelNo-1) END
  ELSIF cmd = CmdHelp THEN ShowHelp()
  END;
  TUI.SetFocus(vw)
END OnMenuCmd;

(* ════════════════════════════════════════════════════════════════
   Menu construction
   ════════════════════════════════════════════════════════════════ *)

PROCEDURE BuildMenus;
BEGIN
  mbar := Widgets.NewMenuBar(1, 1, TUI.Cols);
  Widgets.MenuBarAddMenu(mbar, "File");
  Widgets.MenuBarAddItem(mbar, 0, "Open...    Ctrl+O", CmdOpen);
  Widgets.MenuBarAddItem(mbar, 0, "Reload     F5",     CmdReload);
  Widgets.MenuBarAddItem(mbar, 0, "Save SVG   V",      CmdSaveSVG);
  Widgets.MenuBarAddSep (mbar, 0);
  Widgets.MenuBarAddItem(mbar, 0, "Quit       Ctrl+Q", CmdQuit);
  Widgets.MenuBarAddMenu(mbar, "View");
  Widgets.MenuBarAddItem(mbar, 1, "Backbone          (M)", CmdModeBC);
  Widgets.MenuBarAddItem(mbar, 1, "Ball+Stick        (M)", CmdModeBS);
  Widgets.MenuBarAddItem(mbar, 1, "Space Fill        (M)", CmdModeSF);
  Widgets.MenuBarAddSep (mbar, 1);
  Widgets.MenuBarAddItem(mbar, 1, "Colour: Chain     (C)", CmdColChain);
  Widgets.MenuBarAddItem(mbar, 1, "Colour: Element   (C)", CmdColElem);
  Widgets.MenuBarAddItem(mbar, 1, "Colour: B-factor  (B)", CmdColBfac);
  Widgets.MenuBarAddItem(mbar, 1, "Colour: 2nd Str   (C)", CmdColSS);
  Widgets.MenuBarAddSep (mbar, 1);
  Widgets.MenuBarAddItem(mbar, 1, "Toggle HETATM     (H)", CmdTogHet);
  Widgets.MenuBarAddSep (mbar, 1);
  Widgets.MenuBarAddItem(mbar, 1, "Reset View        (R)", CmdReset);
  Widgets.MenuBarAddMenu(mbar, "Model");
  Widgets.MenuBarAddItem(mbar, 2, "Next Model  PgDn", CmdNextModel);
  Widgets.MenuBarAddItem(mbar, 2, "Prev Model  PgUp", CmdPrevModel);
  Widgets.MenuBarAddMenu(mbar, "Help");
  Widgets.MenuBarAddItem(mbar, 3, "Help  F1", CmdHelp);
  mbar.onCmd := OnMenuCmd;
  TUI.AddView(mbar);
  sline := Widgets.NewStatusLine(1, TUI.Rows, TUI.Cols, "");
  sline.alwaysOnTop := TRUE;
  TUI.AddView(sline)
END BuildMenus;

(* ════════════════════════════════════════════════════════════════
   Main
   ════════════════════════════════════════════════════════════════ *)

VAR ev: TUI.Event; ch: CHAR; arg, argTmp: ARRAY 1024 OF CHAR; argI, argJ: INTEGER;

BEGIN
  TUI.Init();
  running := TRUE; statusMsg[0] := 0X;

  NEW(vw);
  vw.x := 1; vw.y := 2; vw.w := TUI.Cols; vw.h := TUI.Rows-2;
  vw.title[0] := 0X; vw.moveable := FALSE;
  vw.draw := DrawViewer; vw.handle := HandleViewer;
  vw.next := NIL; vw.child := NIL;
  vw.focused := FALSE; vw.alwaysOnTop := FALSE;
  vw.loaded := FALSE; vw.filePath[0] := 0X; vw.modelNo := 1;
  vw.renderMode := ModeBackbone; vw.colourScheme := ColourChain;
  vw.showHet := FALSE;
  vw.drawN := 0; vw.sceneDirty := TRUE;
  vw.inertDX := 0.0; vw.inertDY := 0.0; vw.inertDZ := 0.0; vw.inertOn := FALSE;
  vw.pickedAtom := -1; vw.pickedAtom2 := -1;
  vw.dragActive := FALSE; vw.dragLastX := 0; vw.dragLastY := 0;
  vw.rotDragActive := FALSE; vw.rotLastX := 0; vw.rotLastY := 0; vw.lmbMoved := FALSE;
  vw.chainCount := 0; vw.residueCount := 0;
  MatIdentity(vw.rot);
  vw.scale := 4.0; vw.panX := FLT(CanvasW)/2.0; vw.panY := FLT(CanvasH)/2.0;

  BuildMenus();
  TUI.AddView(vw); TUI.SetFocus(vw);
  ResetView(vw);

  argI := 1;
  WHILE argI <= Args.Count() DO
    Args.Get(argI, arg);
    IF Strings.Compare(arg, "-j") = 0 THEN
      INC(argI);
      IF argI <= Args.Count() THEN
        Args.Get(argI, argTmp);
        IF Strings.StrToInt(argTmp, argJ) & (argJ > 0) THEN
          Parallel.SetMaxCPU(argJ)
        END
      END
    ELSIF arg[0] # '-' THEN
      LoadPDB(arg, 1)
    END;
    INC(argI)
  END;

  WHILE running DO
    IF vw.inertOn THEN
      RotY(vw.rot, vw.inertDX); RotX(vw.rot, vw.inertDY); RotZ(vw.rot, vw.inertDZ);
      vw.inertDX := vw.inertDX * InertDecay;
      vw.inertDY := vw.inertDY * InertDecay;
      vw.inertDZ := vw.inertDZ * InertDecay;
      IF (ABS(vw.inertDX) < InertCutoff) & (ABS(vw.inertDY) < InertCutoff) &
         (ABS(vw.inertDZ) < InertCutoff) THEN
        vw.inertOn := FALSE; vw.inertDX := 0.0; vw.inertDY := 0.0; vw.inertDZ := 0.0
      END;
      vw.sceneDirty := TRUE
    END;

    UpdateStatus();
    TUI.ClearBack(TUI.White, TUI.Black);
    TUI.DrawAll();
    TUI.InvalidateFront();
    TUI.Flush();

    IF vw.sceneDirty THEN
      RenderScene(vw); vw.sceneDirty := FALSE
    ELSE
      Terminal.Flush()
    END;

    Terminal.HideCursor();
    IF vw.inertOn THEN
      IF TUI.PollEvent(ev) = 0 THEN Time.Sleep(30); ev.kind := TUI.EvNone END
    ELSE
      TUI.WaitEvent(ev)
    END;

    IF (ev.kind = TUI.EvKey) OR
       ((ev.kind = TUI.EvMouse) & (ev.mb # 32) & (ev.mb # 3)) THEN
      statusMsg[0] := 0X
    END;

    IF ev.kind = TUI.EvKey THEN
      ch := ev.key;
      IF    ORD(ch) = 15 THEN OnMenuCmd(CmdOpen)
      ELSIF ORD(ch) = 17 THEN running := FALSE
      ELSIF ch = 'Q'     THEN running := FALSE
      ELSIF ch = TUI.KF1 THEN OnMenuCmd(CmdHelp)
      ELSIF ch = TUI.KF5 THEN OnMenuCmd(CmdReload)
      ELSE IF ~TUI.Dispatch(ev) THEN END
      END
    ELSIF ev.kind = TUI.EvMouse THEN
      IF ~TUI.Dispatch(ev) THEN END
    ELSIF ev.kind = TUI.EvResize THEN
      sline.y := TUI.Rows; sline.w := TUI.Cols; mbar.w := TUI.Cols;
      vw.w := TUI.Cols; vw.h := TUI.Rows-2;
      RecenterView(vw); vw.sceneDirty := TRUE; TUI.InvalidateFront()
    END
  END;

  TUI.Done()
END pdbview.
