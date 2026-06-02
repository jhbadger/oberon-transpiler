MODULE pdbview;
(*
  pdbview — Terminal PDB structure viewer built on TUI / Widgets / FileDialog.
  Renders protein structures as wireframe Cα backbone, ball-and-stick, or
  space-fill in the Terminal pixel buffer (240×100 half-block canvas).

  Keyboard shortcuts
  ──────────────────
    Arrow keys          Rotate around Y / X axis
    Shift+Up/Down       Rotate around Z axis
    +  /  -             Zoom in / out
    W A S D             Pan view
    R                   Reset view (clears pick too)
    M                   Cycle render mode (Backbone → Ball-and-Stick → Space Fill)
    H                   Toggle HETATM visibility
    B                   Toggle B-factor colouring
    C                   Cycle chain / element / B-factor colouring
    Esc                 Clear picked atom
    PgUp / PgDn         Previous / next model (NMR ensembles)
    F5                  Reload current file
    Ctrl+O              Open file
    Ctrl+Q / Q          Quit
    F1                  Help
    LMB click           Pick atom (details in status bar)
    RMB drag            Pan view
    Scroll wheel        Zoom
*)

IMPORT TUI, Widgets, FileDialog, Help,
       BioPDB, Math, Strings, Terminal, Time, Args, Out;

(* ════════════════════════════════════════════════════════════════
   Constants
   ════════════════════════════════════════════════════════════════ *)

CONST
  (* Render modes *)
  ModeBackbone  = 0;
  ModeBallStick = 1;
  ModeSpaceFill = 2;

  (* Colour schemes *)
  ColourChain   = 0;
  ColourElement = 1;
  ColourBfactor = 2;

  (* Rotation / zoom / inertia *)
  RotStep     = 0.08;
  ZoomStep    = 1.1;
  InertDecay  = 0.85;
  InertCutoff = 0.002;

  (* Atom pick radius in pixels *)
  MaxPickDist = 8;

  (* Menu command codes *)
  CmdOpen      = 10;
  CmdReload    = 11;
  CmdQuit      = 12;
  CmdModeBC    = 20;
  CmdModeBS    = 21;
  CmdModeSF    = 22;
  CmdColChain  = 30;
  CmdColElem   = 31;
  CmdColBfac   = 32;
  CmdTogHet    = 40;
  CmdReset     = 50;
  CmdHelp      = 60;
  CmdNextModel = 70;
  CmdPrevModel = 71;

  (* Pixel canvas dimensions (Terminal module) *)
  CanvasW = 240;
  CanvasH = 100;

  (* Painter sort buffer size *)
  MaxDraw = BioPDB.MaxAtoms;

(* ════════════════════════════════════════════════════════════════
   Types
   ════════════════════════════════════════════════════════════════ *)

TYPE
  (* 3×3 rotation matrix stored row-major *)
  Mat3 = ARRAY 9 OF REAL;

  (* One entry in the painter's-algorithm sort buffer *)
  DrawEntry = RECORD
    z     : REAL;
    idx   : INTEGER;
    projX : INTEGER;
    projY : INTEGER
  END;

  ViewerWin  = POINTER TO ViewerWinRec;
  ViewerWinRec = RECORD (TUI.WindowRec)
    (* loaded data *)
    model    : BioPDB.Model;
    loaded   : BOOLEAN;
    filePath : ARRAY 1024 OF CHAR;
    modelNo  : INTEGER;

    (* redraw flag — set by handlers, cleared after RenderScene *)
    sceneDirty : BOOLEAN;

    (* view transform *)
    rot        : Mat3;
    scale      : REAL;
    panX, panY : REAL;

    (* display options *)
    renderMode   : INTEGER;
    colourScheme : INTEGER;
    showHet      : BOOLEAN;

    (* inertial rotation *)
    inertDX : REAL;
    inertDY : REAL;
    inertOn : BOOLEAN;

    (* atom picking: index into model.atoms, -1 = none *)
    pickedAtom : INTEGER;

    (* mouse drag state *)
    dragActive : BOOLEAN;
    dragLastX  : INTEGER;
    dragLastY  : INTEGER;

    (* painter sort buffer *)
    drawBuf : ARRAY MaxDraw OF DrawEntry;
    drawN   : INTEGER
  END;

(* ════════════════════════════════════════════════════════════════
   Module globals
   ════════════════════════════════════════════════════════════════ *)

VAR
  vw        : ViewerWin;
  mbar      : Widgets.MenuBar;
  sline     : Widgets.StatusLine;
  running   : BOOLEAN;
  statusMsg : ARRAY 256 OF CHAR;

(* ════════════════════════════════════════════════════════════════
   Matrix helpers
   ════════════════════════════════════════════════════════════════ *)

PROCEDURE MatIdentity(VAR m: Mat3);
BEGIN
  m[0] := 1.0; m[1] := 0.0; m[2] := 0.0;
  m[3] := 0.0; m[4] := 1.0; m[5] := 0.0;
  m[6] := 0.0; m[7] := 0.0; m[8] := 1.0
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
  c := Math.cos(angle); s := Math.sin(angle);
  r[0] :=  c;   r[1] := 0.0; r[2] := s;
  r[3] := 0.0;  r[4] := 1.0; r[5] := 0.0;
  r[6] := -s;   r[7] := 0.0; r[8] := c;
  MatMul(r, m, tmp); m := tmp
END RotY;

PROCEDURE RotX(VAR m: Mat3; angle: REAL);
VAR r, tmp: Mat3; c, s: REAL;
BEGIN
  c := Math.cos(angle); s := Math.sin(angle);
  r[0] := 1.0; r[1] := 0.0; r[2] :=  0.0;
  r[3] := 0.0; r[4] :=  c;  r[5] := -s;
  r[6] := 0.0; r[7] :=  s;  r[8] :=  c;
  MatMul(r, m, tmp); m := tmp
END RotX;

PROCEDURE RotZ(VAR m: Mat3; angle: REAL);
VAR r, tmp: Mat3; c, s: REAL;
BEGIN
  c := Math.cos(angle); s := Math.sin(angle);
  r[0] :=  c;  r[1] := -s;  r[2] := 0.0;
  r[3] :=  s;  r[4] :=  c;  r[5] := 0.0;
  r[6] := 0.0; r[7] := 0.0; r[8] := 1.0;
  MatMul(r, m, tmp); m := tmp
END RotZ;

(* ════════════════════════════════════════════════════════════════
   Colour helpers
   ════════════════════════════════════════════════════════════════ *)

PROCEDURE ChainColor(ch: CHAR): INTEGER;
VAR i: INTEGER;
BEGIN
  i := ORD(ch) MOD 7;
  CASE i OF
    0: RETURN 196 | 1: RETURN  46 | 2: RETURN  21
  | 3: RETURN 226 | 4: RETURN 201 | 5: RETURN  51
  | 6: RETURN 255
  END;
  RETURN 255
END ChainColor;

PROCEDURE ElementColor(VAR elem: ARRAY OF CHAR): INTEGER;
BEGIN
  IF    (elem[0] = 'C') & (elem[1] = 0X) THEN RETURN 255
  ELSIF  elem[0] = 'N'                    THEN RETURN  21
  ELSIF  elem[0] = 'O'                    THEN RETURN 196
  ELSIF  elem[0] = 'S'                    THEN RETURN 226
  ELSIF  elem[0] = 'H'                    THEN RETURN 250
  ELSIF  elem[0] = 'P'                    THEN RETURN 208
  ELSE                                         RETURN  46
  END
END ElementColor;

PROCEDURE BfactorColor(b: REAL): INTEGER;
VAR t: INTEGER;
BEGIN
  IF b < 0.0   THEN b := 0.0   END;
  IF b > 100.0 THEN b := 100.0 END;
  t := FLOOR(b / 100.0 * 4.0);
  CASE t OF
    0: RETURN  21 | 1: RETURN  51 | 2: RETURN 255 | 3: RETURN 226
  ELSE RETURN 196
  END
END BfactorColor;

PROCEDURE AtomColor(v: ViewerWin; i: INTEGER): INTEGER;
BEGIN
  CASE v.colourScheme OF
    ColourChain   : RETURN ChainColor(v.model.atoms[i].chainID)
  | ColourElement : RETURN ElementColor(v.model.atoms[i].element)
  | ColourBfactor : RETURN BfactorColor(v.model.atoms[i].tempFactor)
  END;
  RETURN 255
END AtomColor;

(* ════════════════════════════════════════════════════════════════
   View reset
   ════════════════════════════════════════════════════════════════ *)

PROCEDURE ResetView(v: ViewerWin);
VAR spanX, spanY, spanZ, span, canW, canH: REAL;
BEGIN
  MatIdentity(v.rot);
  (* panX/panY are absolute pixel coords of the projected centroid.
     TUI columns are 1-based; pixel x = TUI_col - 1.
     Window interior: cols v.x+1 .. v.x+w-2  → pixels v.x .. v.x+w-3
                      rows v.y+1 .. v.y+h-2  → pixel y = (row-1)*2 *)
  canW := FLT(v.w - 2);
  canH := FLT((v.h - 2) * 2);
  IF canW > FLT(CanvasW) THEN canW := FLT(CanvasW) END;
  IF canH > FLT(CanvasH) THEN canH := FLT(CanvasH) END;
  v.panX := FLT(v.x) + canW / 2.0;
  v.panY := FLT(v.y * 2) + canH / 2.0;
  IF v.loaded THEN
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
   Painter sort
   ════════════════════════════════════════════════════════════════ *)

PROCEDURE SortDraw(VAR buf: ARRAY OF DrawEntry; n: INTEGER);
VAR i, j: INTEGER; tmp: DrawEntry;
BEGIN
  FOR i := 1 TO n - 1 DO
    tmp := buf[i]; j := i - 1;
    WHILE (j >= 0) & (buf[j].z < tmp.z) DO
      buf[j+1] := buf[j]; DEC(j)
    END;
    buf[j+1] := tmp
  END
END SortDraw;

(* ════════════════════════════════════════════════════════════════
   Atom picking
   ════════════════════════════════════════════════════════════════ *)

PROCEDURE PickAtom(v: ViewerWin; mx, my: INTEGER): INTEGER;
VAR i, best, dx, dy, dist, bestDist: INTEGER;
BEGIN
  best := -1; bestDist := MaxPickDist * MaxPickDist + 1;
  FOR i := 0 TO v.drawN - 1 DO
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

PROCEDURE RenderScene(v: ViewerWin);
VAR i, j, px, py, col, r: INTEGER;
    pz: REAL;
    a: BioPDB.Atom;
    prevChain: CHAR;
    prevPX, prevPY: INTEGER;
    prevOK, isCA: BOOLEAN;
    cx0, cy0, cx1, cy1: INTEGER;
BEGIN
  (* Window interior clip bounds in absolute pixel coords.
     TUI col v.x   = left border  → pixel v.x-1  (do not draw)
     TUI col v.x+1 = interior start → pixel v.x  (first safe pixel x)
     TUI col v.x+w-2 = interior end → pixel v.x+w-3 (last safe pixel x)
     TUI col v.x+w-1 = right border → pixel v.x+w-2 (do not draw)
     For Y: TUI row r → pixel rows (r-1)*2 and (r-1)*2+1 *)
  cx0 := v.x;
  cx1 := v.x + v.w - 3;
  cy0 := v.y * 2;
  cy1 := (v.y + v.h - 3) * 2 + 1;
  IF cx0 < 0        THEN cx0 := 0        END;
  IF cy0 < 0        THEN cy0 := 0        END;
  IF cx1 >= CanvasW THEN cx1 := CanvasW-1 END;
  IF cy1 >= CanvasH THEN cy1 := CanvasH-1 END;

  Terminal.ClearBuf();

  IF ~v.loaded OR (v.model.count = 0) THEN
    Terminal.Flush(); RETURN
  END;

  IF v.renderMode = ModeBackbone THEN
    prevOK := FALSE; prevChain := 0X; prevPX := 0; prevPY := 0;
    FOR i := 0 TO v.model.count - 1 DO
      a := v.model.atoms[i];
      IF ~(a.isHet & ~v.showHet) THEN
        isCA := (Strings.Pos("CA", a.name) >= 0) & ~a.isHet;
        IF isCA THEN
          col := AtomColor(v, i);
          IF Project(v, i, px, py, pz) &
             (px >= cx0) & (px <= cx1) & (py >= cy0) & (py <= cy1) THEN
            IF prevOK & (a.chainID = prevChain) THEN
              Terminal.Line(prevPX, prevPY, px, py, col)
            END;
            Terminal.Plot(px, py, col);
            prevPX := px; prevPY := py; prevChain := a.chainID; prevOK := TRUE
          ELSE
            prevOK := FALSE
          END
        END
      END
    END;
    (* Still populate drawBuf so picking works in backbone mode *)
    v.drawN := 0;
    FOR i := 0 TO v.model.count - 1 DO
      a := v.model.atoms[i];
      IF (~a.isHet OR v.showHet) & (v.drawN < MaxDraw) THEN
        IF Project(v, i, px, py, pz) &
           (px >= cx0) & (px <= cx1) & (py >= cy0) & (py <= cy1) THEN
          v.drawBuf[v.drawN].z     := pz;
          v.drawBuf[v.drawN].idx   := i;
          v.drawBuf[v.drawN].projX := px;
          v.drawBuf[v.drawN].projY := py;
          INC(v.drawN)
        END
      END
    END

  ELSIF v.renderMode = ModeBallStick THEN
    v.drawN := 0;
    FOR i := 0 TO v.model.count - 1 DO
      a := v.model.atoms[i];
      IF (~a.isHet OR v.showHet) & (v.drawN < MaxDraw) THEN
        IF Project(v, i, px, py, pz) &
           (px >= cx0) & (px <= cx1) & (py >= cy0) & (py <= cy1) THEN
          v.drawBuf[v.drawN].z     := pz;
          v.drawBuf[v.drawN].idx   := i;
          v.drawBuf[v.drawN].projX := px;
          v.drawBuf[v.drawN].projY := py;
          INC(v.drawN)
        END
      END
    END;
    SortDraw(v.drawBuf, v.drawN);
    (* Backbone lines under balls *)
    prevOK := FALSE; prevChain := 0X; prevPX := 0; prevPY := 0;
    FOR i := 0 TO v.model.count - 1 DO
      a := v.model.atoms[i];
      IF ~a.isHet THEN
        isCA := Strings.Pos("CA", a.name) >= 0;
        IF isCA & Project(v, i, px, py, pz) &
           (px >= cx0) & (px <= cx1) & (py >= cy0) & (py <= cy1) THEN
          IF prevOK & (a.chainID = prevChain) THEN
            Terminal.Line(prevPX, prevPY, px, py, 240)
          END;
          prevPX := px; prevPY := py; prevChain := a.chainID; prevOK := TRUE
        ELSIF isCA THEN
          prevOK := FALSE
        END
      END
    END;
    FOR j := 0 TO v.drawN - 1 DO
      i   := v.drawBuf[j].idx;
      px  := v.drawBuf[j].projX;
      py  := v.drawBuf[j].projY;
      col := AtomColor(v, i);
      a   := v.model.atoms[i];
      IF a.element[0] = 'H' THEN r := 1 ELSE r := 2 END;
      Terminal.FillCircle(px, py, r, col)
    END

  ELSE (* ModeSpaceFill *)
    v.drawN := 0;
    FOR i := 0 TO v.model.count - 1 DO
      a := v.model.atoms[i];
      IF (~a.isHet OR v.showHet) & (v.drawN < MaxDraw) THEN
        IF Project(v, i, px, py, pz) &
           (px >= cx0) & (px <= cx1) & (py >= cy0) & (py <= cy1) THEN
          v.drawBuf[v.drawN].z     := pz;
          v.drawBuf[v.drawN].idx   := i;
          v.drawBuf[v.drawN].projX := px;
          v.drawBuf[v.drawN].projY := py;
          INC(v.drawN)
        END
      END
    END;
    SortDraw(v.drawBuf, v.drawN);
    FOR j := v.drawN - 1 TO 0 BY -1 DO
      i   := v.drawBuf[j].idx;
      px  := v.drawBuf[j].projX;
      py  := v.drawBuf[j].projY;
      col := AtomColor(v, i);
      a   := v.model.atoms[i];
      IF    a.element[0] = 'H' THEN r := FLOOR(1.2  * v.scale)
      ELSIF a.element[0] = 'C' THEN r := FLOOR(1.7  * v.scale)
      ELSIF a.element[0] = 'N' THEN r := FLOOR(1.55 * v.scale)
      ELSIF a.element[0] = 'O' THEN r := FLOOR(1.52 * v.scale)
      ELSIF a.element[0] = 'S' THEN r := FLOOR(1.8  * v.scale)
      ELSE                          r := FLOOR(1.7  * v.scale)
      END;
      IF r < 2  THEN r := 2  END;
      IF r > 20 THEN r := 20 END;
      Terminal.FillCircle(px, py, r, col)
    END
  END;

  Terminal.Flush();

  (* Cyan ring around the picked atom, drawn on top *)
  IF v.pickedAtom >= 0 THEN
    IF Project(v, v.pickedAtom, px, py, pz) &
       (px >= cx0) & (px <= cx1) & (py >= cy0) & (py <= cy1) THEN
      Terminal.Circle(px, py, 5, 51);
      Terminal.Flush()
    END
  END
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

    (* Title: just the filename *)
    IF v.loaded THEN
      tlen := Strings.Length(v.filePath);
      WHILE (tlen > 0) & (v.filePath[tlen-1] # '/') DO DEC(tlen) END;
      Strings.Extract(v.filePath, tlen, Strings.Length(v.filePath)-tlen, titleBuf)
    ELSE
      Strings.Copy("[no file]", titleBuf)
    END;
    tlen := Strings.Length(titleBuf);
    IF tlen > v.w-4 THEN tlen := v.w-4 END;
    titleBuf[tlen] := 0X;
    tx := v.x + (v.w - tlen) DIV 2;
    TUI.PutStr(tx, v.y, titleBuf, TUI.Yellow, bbg);

    (* Bottom-left legend *)
    CASE v.renderMode OF
      ModeBackbone  : Strings.Copy(" Backbone ", titleBuf)
    | ModeBallStick : Strings.Copy(" Ball+Stk ", titleBuf)
    | ModeSpaceFill : Strings.Copy(" SpaceFill", titleBuf)
    END;
    TUI.PutStr(v.x+1, v.y+v.h-1, titleBuf, TUI.Cyan, bbg);
    CASE v.colourScheme OF
      ColourChain   : Strings.Copy(" Chain ", titleBuf)
    | ColourElement : Strings.Copy(" CPK   ", titleBuf)
    | ColourBfactor : Strings.Copy(" B-fac ", titleBuf)
    END;
    TUI.PutStr(v.x+11, v.y+v.h-1, titleBuf, TUI.Green, bbg);
    IF v.showHet THEN
      TUI.PutStr(v.x+19, v.y+v.h-1, " HET ", TUI.Yellow, bbg)
    END;
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
VAR ch: CHAR; dx, dy: INTEGER;
BEGIN
  WITH v: ViewerWinRec DO
    IF ev.kind = TUI.EvKey THEN
      ch := ev.key;
      v.inertOn := FALSE;   (* any keypress cancels inertia *)

      IF    ch = TUI.KLeft      THEN RotY(v.rot, -RotStep); v.inertDX := -RotStep
      ELSIF ch = TUI.KRight     THEN RotY(v.rot,  RotStep); v.inertDX :=  RotStep
      ELSIF ch = TUI.KUp        THEN RotX(v.rot, -RotStep); v.inertDY := -RotStep
      ELSIF ch = TUI.KDown      THEN RotX(v.rot,  RotStep); v.inertDY :=  RotStep
      ELSIF ch = TUI.KShiftUp   THEN RotZ(v.rot, -RotStep)
      ELSIF ch = TUI.KShiftDown THEN RotZ(v.rot,  RotStep)
      ELSIF (ch = '+') OR (ch = '=') THEN v.scale := v.scale * ZoomStep
      ELSIF  ch = '-'                 THEN v.scale := v.scale / ZoomStep
      ELSIF (ch = 'W') OR (ch = 'w') THEN v.panY := v.panY - 4.0
      ELSIF (ch = 'S') OR (ch = 's') THEN v.panY := v.panY + 4.0
      ELSIF (ch = 'A') OR (ch = 'a') THEN v.panX := v.panX - 4.0
      ELSIF (ch = 'D') OR (ch = 'd') THEN v.panX := v.panX + 4.0
      ELSIF (ch = 'R') OR (ch = 'r') THEN
        ResetView(v); v.inertDX := 0.0; v.inertDY := 0.0; v.pickedAtom := -1
      ELSIF (ch = 'M') OR (ch = 'm') THEN
        v.renderMode := (v.renderMode + 1) MOD 3
      ELSIF (ch = 'C') OR (ch = 'c') THEN
        v.colourScheme := (v.colourScheme + 1) MOD 3
      ELSIF (ch = 'H') OR (ch = 'h') THEN
        v.showHet := ~v.showHet
      ELSIF (ch = 'B') OR (ch = 'b') THEN
        IF v.colourScheme = ColourBfactor THEN v.colourScheme := ColourChain
        ELSE v.colourScheme := ColourBfactor
        END
      ELSIF ch = TUI.KEsc THEN
        v.pickedAtom := -1
      ELSIF ch = TUI.KPgUp THEN
        IF v.modelNo > 1 THEN
          v.modelNo := v.modelNo - 1; v.sceneDirty := TRUE
        END;
        RETURN TRUE
      ELSIF ch = TUI.KPgDn THEN
        v.modelNo := v.modelNo + 1; v.sceneDirty := TRUE;
        RETURN TRUE
      ELSE
        RETURN FALSE
      END;
      v.sceneDirty := TRUE;
      RETURN TRUE

    ELSIF ev.kind = TUI.EvMouse THEN
      IF ev.mb = 0 THEN
        (* Left click: pick atom.
           pixel x = char_col - 1; pixel y = (char_row - 1)*2 + 1 *)
        v.inertOn    := FALSE;
        v.pickedAtom := PickAtom(v, ev.mx - 1, (ev.my - 1) * 2 + 1);
        v.sceneDirty := TRUE
      ELSIF ev.mb = 2 THEN
        (* Right press: start pan drag *)
        v.dragActive := TRUE;
        v.dragLastX  := ev.mx;
        v.dragLastY  := ev.my
      ELSIF (ev.mb = 32) & v.dragActive THEN
        dx := ev.mx - v.dragLastX;
        dy := ev.my - v.dragLastY;
        v.panX := v.panX + FLT(dx);
        v.panY := v.panY + FLT(dy) * 2.0;
        v.dragLastX  := ev.mx;
        v.dragLastY  := ev.my;
        v.sceneDirty := TRUE
      ELSIF ev.mb = 3 THEN
        v.dragActive := FALSE;
        (* Engage inertia if we have enough velocity *)
        v.inertOn := (ABS(v.inertDX) > InertCutoff) OR (ABS(v.inertDY) > InertCutoff)
      ELSIF ev.mb = 64 THEN
        v.scale := v.scale * ZoomStep; v.sceneDirty := TRUE
      ELSIF ev.mb = 65 THEN
        v.scale := v.scale / ZoomStep; v.sceneDirty := TRUE
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
VAR buf, tmp: ARRAY 256 OF CHAR;
    a: BioPDB.Atom;
BEGIN
  IF statusMsg[0] # 0X THEN
    Strings.Copy(statusMsg, buf)
  ELSIF vw.pickedAtom >= 0 THEN
    a := vw.model.atoms[vw.pickedAtom];
    Strings.Copy("  Picked: ", buf);
    IF a.isHet THEN Strings.Append("HETATM ", buf)
    ELSE Strings.Append("ATOM ", buf) END;
    Strings.Append(a.name,    buf); Strings.Append(" ", buf);
    Strings.Append(a.resName, buf); Strings.Append(" ", buf);
    buf[Strings.Length(buf)] := a.chainID;
    buf[Strings.Length(buf)+1] := 0X;
    Strings.Append(" ", buf);
    Strings.IntToStr(a.resSeq, tmp);      Strings.Append(tmp, buf);
    Strings.Append("  elem:", buf);
    Strings.Append(a.element, buf);
    Strings.Append("  B:", buf);
    Strings.RealToStr(a.tempFactor, tmp); Strings.Append(tmp, buf);
    Strings.Append("  occ:", buf);
    Strings.RealToStr(a.occupancy,  tmp); Strings.Append(tmp, buf);
    Strings.Append("  [Esc to clear]", buf)
  ELSIF vw.loaded THEN
    Strings.Copy("  Atoms:", buf);
    Strings.IntToStr(vw.model.count, tmp); Strings.Append(tmp, buf);
    Strings.Append("  Model:", buf);
    Strings.IntToStr(vw.modelNo, tmp);     Strings.Append(tmp, buf);
    Strings.Append("  Arrows:rotate  WASD:pan  +/-:zoom  scroll:zoom  RMB:pan  LMB:pick  R:reset  M:mode  C:colour  H:het", buf)
  ELSE
    Strings.Copy("  No file loaded. Ctrl+O to open a PDB file.", buf)
  END;
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
    vw.modelNo     := modelNo;
    vw.loaded      := TRUE;
    vw.pickedAtom  := -1;
    ResetView(vw);
    Strings.Copy("Loaded.", statusMsg)
  ELSE
    vw.loaded := FALSE;
    Strings.Copy("Failed to load PDB (err=", statusMsg);
    Strings.IntToStr(err, tmp);
    Strings.Append(tmp, statusMsg);
    Strings.Append(").", statusMsg)
  END;
  vw.sceneDirty := TRUE
END LoadPDB;

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
    ELSE Strings.Copy("No file to reload.", statusMsg)
    END

  ELSIF cmd = CmdQuit THEN running := FALSE

  ELSIF cmd = CmdModeBC THEN vw.renderMode  := ModeBackbone;  vw.sceneDirty := TRUE
  ELSIF cmd = CmdModeBS THEN vw.renderMode  := ModeBallStick; vw.sceneDirty := TRUE
  ELSIF cmd = CmdModeSF THEN vw.renderMode  := ModeSpaceFill; vw.sceneDirty := TRUE

  ELSIF cmd = CmdColChain THEN vw.colourScheme := ColourChain;   vw.sceneDirty := TRUE
  ELSIF cmd = CmdColElem  THEN vw.colourScheme := ColourElement; vw.sceneDirty := TRUE
  ELSIF cmd = CmdColBfac  THEN vw.colourScheme := ColourBfactor; vw.sceneDirty := TRUE

  ELSIF cmd = CmdTogHet THEN vw.showHet := ~vw.showHet; vw.sceneDirty := TRUE

  ELSIF cmd = CmdReset THEN
    ResetView(vw); vw.inertDX := 0.0; vw.inertDY := 0.0;
    vw.pickedAtom := -1; vw.sceneDirty := TRUE

  ELSIF cmd = CmdNextModel THEN
    IF vw.loaded THEN LoadPDB(vw.filePath, vw.modelNo + 1) END

  ELSIF cmd = CmdPrevModel THEN
    IF vw.loaded & (vw.modelNo > 1) THEN LoadPDB(vw.filePath, vw.modelNo - 1) END

  ELSIF cmd = CmdHelp THEN Help.Show("BioPDB")
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
  Widgets.MenuBarAddSep (mbar, 0);
  Widgets.MenuBarAddItem(mbar, 0, "Quit       Ctrl+Q", CmdQuit);

  Widgets.MenuBarAddMenu(mbar, "View");
  Widgets.MenuBarAddItem(mbar, 1, "Backbone        (M)", CmdModeBC);
  Widgets.MenuBarAddItem(mbar, 1, "Ball+Stick      (M)", CmdModeBS);
  Widgets.MenuBarAddItem(mbar, 1, "Space Fill      (M)", CmdModeSF);
  Widgets.MenuBarAddSep (mbar, 1);
  Widgets.MenuBarAddItem(mbar, 1, "Colour: Chain   (C)", CmdColChain);
  Widgets.MenuBarAddItem(mbar, 1, "Colour: Element (C)", CmdColElem);
  Widgets.MenuBarAddItem(mbar, 1, "Colour: B-factor(B)", CmdColBfac);
  Widgets.MenuBarAddSep (mbar, 1);
  Widgets.MenuBarAddItem(mbar, 1, "Toggle HETATM   (H)", CmdTogHet);
  Widgets.MenuBarAddSep (mbar, 1);
  Widgets.MenuBarAddItem(mbar, 1, "Reset View      (R)", CmdReset);

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

VAR
  ev  : TUI.Event;
  ch  : CHAR;
  arg : ARRAY 1024 OF CHAR;

BEGIN
  TUI.Init();
  running := TRUE;
  statusMsg[0] := 0X;

  NEW(vw);
  vw.x := 1; vw.y := 2;
  vw.w := TUI.Cols; vw.h := TUI.Rows - 2;
  vw.title[0]    := 0X;
  vw.moveable    := FALSE;
  vw.draw        := DrawViewer;
  vw.handle      := HandleViewer;
  vw.next        := NIL; vw.child := NIL;
  vw.focused     := FALSE;
  vw.alwaysOnTop := FALSE;
  vw.loaded      := FALSE;
  vw.filePath[0] := 0X;
  vw.modelNo     := 1;
  vw.renderMode  := ModeBackbone;
  vw.colourScheme := ColourChain;
  vw.showHet     := FALSE;
  vw.drawN       := 0;
  vw.sceneDirty  := TRUE;
  vw.inertDX     := 0.0;
  vw.inertDY     := 0.0;
  vw.inertOn     := FALSE;
  vw.pickedAtom  := -1;
  vw.dragActive  := FALSE;
  vw.dragLastX   := 0;
  vw.dragLastY   := 0;
  MatIdentity(vw.rot);
  vw.scale := 4.0;
  vw.panX  := FLT(CanvasW) / 2.0;
  vw.panY  := FLT(CanvasH) / 2.0;

  BuildMenus();
  TUI.AddView(vw);
  TUI.SetFocus(vw);
  ResetView(vw);

  IF Args.Count() > 0 THEN
    Args.Get(1, arg);
    LoadPDB(arg, 1)
  END;

  (* ── Main event loop ── *)
  WHILE running DO
    (* Inertial rotation tick *)
    IF vw.inertOn THEN
      RotY(vw.rot, vw.inertDX);
      RotX(vw.rot, vw.inertDY);
      vw.inertDX := vw.inertDX * InertDecay;
      vw.inertDY := vw.inertDY * InertDecay;
      IF (ABS(vw.inertDX) < InertCutoff) & (ABS(vw.inertDY) < InertCutoff) THEN
        vw.inertOn := FALSE;
        vw.inertDX := 0.0; vw.inertDY := 0.0
      END;
      vw.sceneDirty := TRUE
    END;

    UpdateStatus();
    TUI.ClearBack(TUI.White, TUI.Black);
    TUI.DrawAll();
    TUI.InvalidateFront();
    TUI.Flush();
    IF vw.sceneDirty THEN
      RenderScene(vw);
      vw.sceneDirty := FALSE
    ELSE
      Terminal.Flush()
    END;
    Terminal.HideCursor();

    (* Non-blocking poll during inertia; blocking wait otherwise *)
    IF vw.inertOn THEN
      IF TUI.PollEvent(ev) = 0 THEN
        Time.Sleep(30);
        ev.kind := TUI.EvNone
      END
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
      ELSIF (ch = 'Q')   THEN running := FALSE
      ELSIF ch = TUI.KF1 THEN OnMenuCmd(CmdHelp)
      ELSIF ch = TUI.KF5 THEN OnMenuCmd(CmdReload)
      ELSE IF ~TUI.Dispatch(ev) THEN END
      END

    ELSIF ev.kind = TUI.EvMouse THEN
      IF ~TUI.Dispatch(ev) THEN END

    ELSIF ev.kind = TUI.EvResize THEN
      sline.y := TUI.Rows;
      sline.w := TUI.Cols;
      mbar.w  := TUI.Cols;
      vw.w    := TUI.Cols;
      vw.h    := TUI.Rows - 2;
      ResetView(vw);
      vw.sceneDirty := TRUE;
      TUI.InvalidateFront()
    END
  END;

  TUI.Done()
END pdbview.
