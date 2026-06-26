MODULE PDBViewer;

(*
 * Graphical PDB structure viewer using Raylib.
 *
 * Usage: pdbviewer <file.pdb|.cif|.sdf|.xyz[.gz]>
 *
 * Controls:
 *   Left-drag / arrow keys : rotate
 *   Right-drag             : pan
 *   Scroll                 : zoom
 *   + / -                  : zoom in / out
 *   W A S D                : pan
 *   M                      : cycle render mode (Backbone -> Ball+Stick -> Space Fill)
 *   C                      : cycle colour scheme (Chain -> CPK -> B-factor -> Secondary)
 *   H                      : toggle HETATM visibility
 *   R                      : reset view / clear pick
 *   PgUp / PgDn            : previous / next model
 *   LMB click              : pick atom
 *   Esc                    : clear picked atom
 *   close / Q              : quit
 *)

IMPORT Raylib, BioPDB, Args, Strings, Math, Out;

CONST
  W = 1200;  H = 820;
  StatusH = 28;
  ViewH = H - StatusH;

  ModeBackbone  = 0;
  ModeBallStick = 1;
  ModeSpaceFill = 2;

  ColourChain   = 0;
  ColourElement = 1;
  ColourBfactor = 2;
  ColourSecStr  = 3;

  RotStep  = 0.03;
  ZoomStep = 1.1;
  MouseLeft  = 0;
  MouseRight = 1;

TYPE
  Mat3 = ARRAY 9 OF REAL;

  DrawEntry = RECORD
    z     : REAL;
    idx   : INTEGER;
    projX : INTEGER;
    projY : INTEGER
  END;

VAR
  model        : BioPDB.Model;
  loaded       : BOOLEAN;
  filePath     : ARRAY 1024 OF CHAR;
  modelNo      : INTEGER;
  rot          : Mat3;
  scale        : REAL;
  panX, panY   : REAL;
  renderMode   : INTEGER;
  colourScheme : INTEGER;
  showHet      : BOOLEAN;
  pickedAtom   : INTEGER;
  drawBuf      : ARRAY BioPDB.MaxAtoms OF DrawEntry;
  drawN        : INTEGER;
  cBg, cGray, cWhite, cYellow, cCyan : INTEGER;

(* ── Matrix helpers ──────────────────────────────────────────────────── *)

PROCEDURE MatIdentity(VAR m: Mat3);
BEGIN
  m[0]:=1.0; m[1]:=0.0; m[2]:=0.0;
  m[3]:=0.0; m[4]:=1.0; m[5]:=0.0;
  m[6]:=0.0; m[7]:=0.0; m[8]:=1.0
END MatIdentity;

PROCEDURE MatMul(VAR a, b: Mat3; VAR res: Mat3);
VAR tmp: Mat3; i, j, k: INTEGER;
BEGIN
  FOR i := 0 TO 2 DO
    FOR j := 0 TO 2 DO
      tmp[i*3+j] := 0.0;
      FOR k := 0 TO 2 DO tmp[i*3+j] := tmp[i*3+j] + a[i*3+k]*b[k*3+j] END
    END
  END;
  FOR i := 0 TO 8 DO res[i] := tmp[i] END
END MatMul;

PROCEDURE MatApply(VAR m: Mat3; x, y, z: REAL; VAR rx, ry, rz: REAL);
BEGIN
  rx := m[0]*x + m[1]*y + m[2]*z;
  ry := m[3]*x + m[4]*y + m[5]*z;
  rz := m[6]*x + m[7]*y + m[8]*z
END MatApply;

PROCEDURE RotY(VAR m: Mat3; a: REAL);
VAR r, tmp: Mat3; c, s: REAL;
BEGIN
  c:=Math.cos(a); s:=Math.sin(a);
  r[0]:= c; r[1]:=0.0; r[2]:=s;
  r[3]:=0.0; r[4]:=1.0; r[5]:=0.0;
  r[6]:=-s; r[7]:=0.0; r[8]:=c;
  MatMul(r, m, tmp); m := tmp
END RotY;

PROCEDURE RotX(VAR m: Mat3; a: REAL);
VAR r, tmp: Mat3; c, s: REAL;
BEGIN
  c:=Math.cos(a); s:=Math.sin(a);
  r[0]:=1.0; r[1]:=0.0; r[2]:= 0.0;
  r[3]:=0.0; r[4]:= c;  r[5]:=-s;
  r[6]:=0.0; r[7]:= s;  r[8]:= c;
  MatMul(r, m, tmp); m := tmp
END RotX;

(* ── Projection ──────────────────────────────────────────────────────── *)

PROCEDURE Project(i: INTEGER; VAR px, py: INTEGER; VAR pz: REAL): BOOLEAN;
VAR ax, ay, az, rx, ry, rz: REAL;
BEGIN
  ax := model.atoms[i].x - model.cx;
  ay := model.atoms[i].y - model.cy;
  az := model.atoms[i].z - model.cz;
  MatApply(rot, ax, ay, az, rx, ry, rz);
  px := FLOOR(rx * scale + panX);
  py := FLOOR(-ry * scale + panY);
  pz := rz;
  RETURN (px >= -200) & (px < W+200) & (py >= -200) & (py < ViewH+200)
END Project;

(* ── Colour helpers ──────────────────────────────────────────────────── *)

PROCEDURE ChainRGB(ch: CHAR; VAR r, g, b: INTEGER);
VAR i: INTEGER;
BEGIN
  i := ORD(ch) MOD 7;
  CASE i OF
    0: r:=220; g:= 60; b:= 60
  | 1: r:= 60; g:=200; b:= 60
  | 2: r:= 60; g:= 60; b:=220
  | 3: r:=220; g:=220; b:= 60
  | 4: r:=200; g:= 60; b:=200
  | 5: r:= 60; g:=200; b:=220
  | 6: r:=220; g:=220; b:=220
  END
END ChainRGB;

PROCEDURE ElementRGB(VAR elem: ARRAY OF CHAR; VAR r, g, b: INTEGER);
BEGIN
  IF (elem[0]='C') & (elem[1]=0X) THEN r:=200; g:=200; b:=200
  ELSIF elem[0]='N' THEN r:= 60; g:= 60; b:=255
  ELSIF elem[0]='O' THEN r:=255; g:= 60; b:= 60
  ELSIF elem[0]='S' THEN r:=255; g:=220; b:= 40
  ELSIF elem[0]='H' THEN r:=160; g:=160; b:=160
  ELSIF elem[0]='P' THEN r:=255; g:=140; b:= 40
  ELSE                   r:= 60; g:=200; b:= 60
  END
END ElementRGB;

PROCEDURE BfacRGB(bv: REAL; VAR r, g, b: INTEGER);
VAR t: INTEGER;
BEGIN
  IF bv < 0.0   THEN bv :=   0.0 END;
  IF bv > 100.0 THEN bv := 100.0 END;
  t := FLOOR(bv / 100.0 * 4.0);
  IF t > 4 THEN t := 4 END;
  CASE t OF
    0: r:= 40; g:= 40; b:=255
  | 1: r:= 40; g:=220; b:=220
  | 2: r:=220; g:=220; b:=220
  | 3: r:=220; g:=220; b:= 40
  ELSE r:=255; g:= 40; b:= 40
  END
END BfacRGB;

PROCEDURE SSRGB(ss: INTEGER; VAR r, g, b: INTEGER);
BEGIN
  CASE ss OF
    BioPDB.SSHelix: r:=220; g:= 60; b:= 60
  | BioPDB.SSSheet: r:=220; g:=200; b:= 40
  ELSE              r:=180; g:=180; b:=180
  END
END SSRGB;

PROCEDURE AtomRGB(i: INTEGER; VAR r, g, b: INTEGER);
VAR ss: INTEGER;
BEGIN
  CASE colourScheme OF
    ColourChain  : ChainRGB(model.atoms[i].chainID, r, g, b)
  | ColourElement: ElementRGB(model.atoms[i].element, r, g, b)
  | ColourBfactor: BfacRGB(model.atoms[i].tempFactor, r, g, b)
  | ColourSecStr :
      ss := BioPDB.LookupSS(model, model.atoms[i].chainID, model.atoms[i].resSeq);
      SSRGB(ss, r, g, b)
  END
END AtomRGB;

PROCEDURE ShadedColor(r, g, b: INTEGER; pz, zMin, zMax: REAL): INTEGER;
VAR lum: REAL; ri, gi, bi: INTEGER;
BEGIN
  IF zMax > zMin THEN
    lum := (pz - zMin) / (zMax - zMin);
    IF lum < 0.0 THEN lum := 0.0 END;
    IF lum > 1.0 THEN lum := 1.0 END;
    lum := Math.sqrt(lum);
    lum := 0.18 + 0.82 * lum
  ELSE
    lum := 1.0
  END;
  ri := FLOOR(FLT(r) * lum);
  gi := FLOOR(FLT(g) * lum);
  bi := FLOOR(FLT(b) * lum);
  IF ri > 255 THEN ri := 255 END;
  IF gi > 255 THEN gi := 255 END;
  IF bi > 255 THEN bi := 255 END;
  RETURN Raylib.RGBA(ri, gi, bi, 255)
END ShadedColor;

(* ── Sort draw buffer descending by z (front first) ─────────────────── *)

PROCEDURE SwapDE(VAR a, b: DrawEntry);
VAR t: DrawEntry;
BEGIN t := a; a := b; b := t END SwapDE;

PROCEDURE QSortDE(VAR buf: ARRAY OF DrawEntry; lo, hi: INTEGER);
VAR i, j: INTEGER; piv: REAL;
BEGIN
  IF lo >= hi THEN RETURN END;
  i := lo; j := hi;
  piv := buf[(lo+hi) DIV 2].z;
  REPEAT
    WHILE buf[i].z > piv DO INC(i) END;
    WHILE buf[j].z < piv DO DEC(j) END;
    IF i <= j THEN SwapDE(buf[i], buf[j]); INC(i); DEC(j) END
  UNTIL i > j;
  QSortDE(buf, lo, j);
  QSortDE(buf, i, hi)
END QSortDE;

(* ── View reset ──────────────────────────────────────────────────────── *)

PROCEDURE ResetView;
VAR spanX, spanY, spanZ, span: REAL;
BEGIN
  MatIdentity(rot);
  panX := FLT(W) / 2.0;
  panY := FLT(ViewH) / 2.0;
  IF loaded THEN
    spanX := model.maxX - model.minX;
    spanY := model.maxY - model.minY;
    spanZ := model.maxZ - model.minZ;
    span  := spanX;
    IF spanY > span THEN span := spanY END;
    IF spanZ > span THEN span := spanZ END;
    IF span < 1.0 THEN span := 1.0 END;
    scale := FLT(ViewH) * 0.8 / span;
    IF FLT(W) * 0.8 / span < scale THEN scale := FLT(W) * 0.8 / span END
  ELSE
    scale := 10.0
  END
END ResetView;

(* ── Render scene ────────────────────────────────────────────────────── *)

PROCEDURE RenderScene;
VAR i, j, px, py, r2, cr, cg, cb, col: INTEGER;
    pz, zMin, zMax: REAL;
    a: BioPDB.Atom;
    prevChain: CHAR;
    prevPX, prevPY: INTEGER;
    prevOK, isBackbone: BOOLEAN;
BEGIN
  IF ~loaded OR (model.count = 0) THEN RETURN END;

  drawN := 0;
  FOR i := 0 TO model.count-1 DO
    a := model.atoms[i];
    IF ~a.isHet OR showHet THEN
      IF Project(i, px, py, pz) THEN
        IF drawN < BioPDB.MaxAtoms THEN
          drawBuf[drawN].z     := pz;
          drawBuf[drawN].idx   := i;
          drawBuf[drawN].projX := px;
          drawBuf[drawN].projY := py;
          INC(drawN)
        END
      END
    END
  END;

  IF drawN = 0 THEN RETURN END;

  IF renderMode = ModeBackbone THEN
    zMin := 1.0E30; zMax := -1.0E30;
    FOR j := 0 TO drawN-1 DO
      IF drawBuf[j].z < zMin THEN zMin := drawBuf[j].z END;
      IF drawBuf[j].z > zMax THEN zMax := drawBuf[j].z END
    END;
    IF zMin >= zMax THEN zMin := zMax - 1.0 END;

    prevOK := FALSE; prevChain := 0X; prevPX := 0; prevPY := 0;
    FOR i := 0 TO model.count-1 DO
      a := model.atoms[i];
      IF ~a.isHet THEN
        isBackbone := ((Strings.Pos("CA", a.name) >= 0) OR
                       ((a.name[0]='P') & (a.name[1]=0X)));
        IF isBackbone THEN
          IF Project(i, px, py, pz) &
             (px >= 0) & (px < W) & (py >= 0) & (py < ViewH) THEN
            AtomRGB(i, cr, cg, cb);
            col := ShadedColor(cr, cg, cb, pz, zMin, zMax);
            IF prevOK & (a.chainID = prevChain) THEN
              Raylib.DrawLineEx(FLT(prevPX), FLT(prevPY), FLT(px), FLT(py), 2.0, col)
            END;
            Raylib.DrawCircle(px, py, 3.0, col);
            prevPX := px; prevPY := py; prevChain := a.chainID; prevOK := TRUE
          ELSE prevOK := FALSE
          END
        END
      END
    END

  ELSE
    QSortDE(drawBuf, 0, drawN-1);
    zMax := drawBuf[0].z; zMin := drawBuf[drawN-1].z;
    IF zMin >= zMax THEN zMin := zMax - 1.0 END;

    IF renderMode = ModeBallStick THEN
      prevOK := FALSE; prevChain := 0X;
      FOR i := 0 TO model.count-1 DO
        a := model.atoms[i];
        IF ~a.isHet THEN
          isBackbone := (Strings.Pos("CA", a.name) >= 0) OR
                        ((a.name[0]='P') & (a.name[1]=0X));
          IF isBackbone THEN
            IF Project(i, px, py, pz) &
               (px >= 0) & (px < W) & (py >= 0) & (py < ViewH) THEN
              IF prevOK & (a.chainID = prevChain) THEN
                Raylib.DrawLineEx(FLT(prevPX), FLT(prevPY), FLT(px), FLT(py), 1.5, cGray)
              END;
              prevPX := px; prevPY := py; prevChain := a.chainID; prevOK := TRUE
            ELSE prevOK := FALSE
            END
          END
        END
      END;
      FOR j := 0 TO drawN-1 DO
        i  := drawBuf[j].idx;
        px := drawBuf[j].projX;
        py := drawBuf[j].projY;
        IF (px >= 0) & (px < W) & (py >= 0) & (py < ViewH) THEN
          AtomRGB(i, cr, cg, cb);
          col := ShadedColor(cr, cg, cb, drawBuf[j].z, zMin, zMax);
          IF model.atoms[i].element[0] = 'H' THEN r2 := 3 ELSE r2 := 5 END;
          Raylib.DrawCircle(px, py, FLT(r2), col)
        END
      END

    ELSE (* Space fill — painter's algorithm: back to front *)
      FOR j := drawN-1 TO 0 BY -1 DO
        i  := drawBuf[j].idx;
        px := drawBuf[j].projX;
        py := drawBuf[j].projY;
        IF (px >= -200) & (px < W+200) & (py >= -200) & (py < ViewH+200) THEN
          AtomRGB(i, cr, cg, cb);
          col := ShadedColor(cr, cg, cb, drawBuf[j].z, zMin, zMax);
          CASE model.atoms[i].element[0] OF
            'H': r2 := FLOOR(1.2  * scale)
          | 'C': r2 := FLOOR(1.7  * scale)
          | 'N': r2 := FLOOR(1.55 * scale)
          | 'O': r2 := FLOOR(1.52 * scale)
          | 'S': r2 := FLOOR(1.8  * scale)
          ELSE   r2 := FLOOR(1.7  * scale)
          END;
          IF r2 < 2   THEN r2 := 2   END;
          IF r2 > 300 THEN r2 := 300 END;
          Raylib.DrawCircle(px, py, FLT(r2), col)
        END
      END
    END
  END;

  IF pickedAtom >= 0 THEN
    IF Project(pickedAtom, px, py, pz) &
       (px >= 0) & (px < W) & (py >= 0) & (py < ViewH) THEN
      Raylib.DrawCircleLines(px, py, 14.0, cYellow);
      Raylib.DrawCircleLines(px, py, 15.5, cYellow)
    END
  END
END RenderScene;

(* ── Status bar ──────────────────────────────────────────────────────── *)

PROCEDURE DrawStatus;
VAR buf, tmp: ARRAY 512 OF CHAR; a: BioPDB.Atom; ss: INTEGER;
BEGIN
  Raylib.DrawRectangle(0, ViewH, W, StatusH, Raylib.RGBA(25, 25, 35, 255));
  Raylib.DrawLine(0, ViewH, W, ViewH, cGray);

  CASE renderMode OF
    ModeBackbone : Strings.Copy("Backbone", buf)
  | ModeBallStick: Strings.Copy("Ball+Stick", buf)
  | ModeSpaceFill: Strings.Copy("SpaceFill", buf)
  END;
  Raylib.DrawText(buf, 4, ViewH+6, 16, cCyan);

  CASE colourScheme OF
    ColourChain  : Strings.Copy("Chain", buf)
  | ColourElement: Strings.Copy("CPK", buf)
  | ColourBfactor: Strings.Copy("B-fac", buf)
  | ColourSecStr : Strings.Copy("2ndStr", buf)
  END;
  Raylib.DrawText(buf, 105, ViewH+6, 16, cYellow);

  IF showHet THEN Raylib.DrawText("HET", 175, ViewH+6, 16, Raylib.RGBA(255,180,60,255)) END;

  IF pickedAtom >= 0 THEN
    a := model.atoms[pickedAtom];
    Strings.Copy("Pick: ", buf);
    IF a.isHet THEN Strings.Append("HETATM ", buf) END;
    Strings.Append(a.name, buf); Strings.Append(" ", buf);
    Strings.Append(a.resName, buf); Strings.Append(" ", buf);
    buf[Strings.Length(buf)] := a.chainID; buf[Strings.Length(buf)+1] := 0X;
    Strings.Append(":", buf);
    Strings.IntToStr(a.resSeq, tmp); Strings.Append(tmp, buf);
    Strings.Append("  elem:", buf); Strings.Append(a.element, buf);
    Strings.Append("  B:", buf);
    Strings.RealToStr(a.tempFactor, tmp); Strings.Append(tmp, buf);
    ss := BioPDB.LookupSS(model, a.chainID, a.resSeq);
    Strings.Append("  ss:", buf);
    CASE ss OF
      BioPDB.SSHelix: Strings.Append("helix", buf)
    | BioPDB.SSSheet: Strings.Append("sheet", buf)
    ELSE              Strings.Append("coil",  buf)
    END;
    Strings.Append("  [Esc=clear]", buf)
  ELSIF loaded THEN
    Strings.Copy("Atoms:", buf);
    Strings.IntToStr(model.count, tmp); Strings.Append(tmp, buf);
    Strings.Append("  Mdl:", buf);
    Strings.IntToStr(modelNo, tmp); Strings.Append(tmp, buf);
    Strings.Append("  drag:rotate  scroll/+/-:zoom  WASD:pan  M:mode  C:colour  H:het  R:reset  Q:quit", buf)
  ELSE
    Strings.Copy("No file loaded.", buf)
  END;
  Raylib.DrawText(buf, 215, ViewH+6, 16, cWhite)
END DrawStatus;

(* ── Pick nearest projected atom ─────────────────────────────────────── *)

PROCEDURE PickNearest(mx, my: INTEGER): INTEGER;
VAR i, best, dx, dy, d, bestD: INTEGER;
BEGIN
  best := -1; bestD := 20*20;
  FOR i := 0 TO drawN-1 DO
    dx := drawBuf[i].projX - mx;
    dy := drawBuf[i].projY - my;
    d  := dx*dx + dy*dy;
    IF d < bestD THEN bestD := d; best := drawBuf[i].idx END
  END;
  RETURN best
END PickNearest;

(* ── Load helper ─────────────────────────────────────────────────────── *)

PROCEDURE LoadFile(path: ARRAY OF CHAR; mno: INTEGER);
VAR err: INTEGER; tmp: ARRAY 16 OF CHAR;
BEGIN
  IF BioPDB.LoadAny(path, model, mno, err) THEN
    loaded := TRUE; modelNo := mno;
    IF model.ssCount = 0 THEN renderMode := ModeBallStick
    ELSE renderMode := ModeBackbone
    END;
    ResetView; pickedAtom := -1
  ELSE
    Out.String("Load error: "); Out.Int(err, 0); Out.Ln
  END
END LoadFile;

(* ── Main ─────────────────────────────────────────────────────────────── *)

VAR
  title                    : ARRAY 1024 OF CHAR;
  dragStartX, dragStartY   : INTEGER;
  panStartX, panStartY     : INTEGER;
  panAnchorX, panAnchorY   : REAL;
  mx, my                   : INTEGER;
  dragged                  : BOOLEAN;

BEGIN
  IF Args.Count() < 1 THEN
    Out.String("Usage: pdbviewer <file.pdb>"); Out.Ln;
    HALT(1)
  END;
  Args.Get(1, filePath);

  title := "PDB Viewer: ";
  Strings.Append(filePath, title);

  Raylib.InitWindow(W, H, title);
  Raylib.SetTargetFPS(60);

  cBg     := Raylib.RGBA( 12,  12,  20, 255);
  cGray   := Raylib.RGBA(110, 110, 120, 255);
  cWhite  := Raylib.RGBA(220, 220, 220, 255);
  cYellow := Raylib.RGBA(255, 220,  50, 255);
  cCyan   := Raylib.RGBA( 50, 210, 210, 255);

  loaded := FALSE; pickedAtom := -1; modelNo := 1;
  renderMode := ModeBackbone; colourScheme := ColourChain; showHet := FALSE;
  dragged := FALSE;

  LoadFile(filePath, 1);

  WHILE Raylib.WindowShouldClose() = 0 DO

    (* Keyboard *)
    IF Raylib.IsKeyDown(Raylib.KeyLeft)  = 1 THEN RotY(rot, -RotStep) END;
    IF Raylib.IsKeyDown(Raylib.KeyRight) = 1 THEN RotY(rot,  RotStep) END;
    IF Raylib.IsKeyDown(Raylib.KeyUp)    = 1 THEN RotX(rot, -RotStep) END;
    IF Raylib.IsKeyDown(Raylib.KeyDown)  = 1 THEN RotX(rot,  RotStep) END;
    IF Raylib.IsKeyDown(ORD('W'))        = 1 THEN panY := panY - 5.0  END;
    IF Raylib.IsKeyDown(ORD('S'))        = 1 THEN panY := panY + 5.0  END;
    IF Raylib.IsKeyDown(ORD('A'))        = 1 THEN panX := panX - 5.0  END;
    IF Raylib.IsKeyDown(ORD('D'))        = 1 THEN panX := panX + 5.0  END;
    IF Raylib.IsKeyPressed(ORD('='))     = 1 THEN scale := scale * ZoomStep END;
    IF Raylib.IsKeyPressed(ORD('-'))     = 1 THEN scale := scale / ZoomStep END;
    IF Raylib.IsKeyPressed(ORD('M'))     = 1 THEN renderMode := (renderMode+1) MOD 3 END;
    IF Raylib.IsKeyPressed(ORD('C'))     = 1 THEN colourScheme := (colourScheme+1) MOD 4 END;
    IF Raylib.IsKeyPressed(ORD('H'))     = 1 THEN showHet := ~showHet END;
    IF Raylib.IsKeyPressed(ORD('R'))     = 1 THEN ResetView; pickedAtom := -1 END;
    IF Raylib.IsKeyPressed(ORD('Q'))     = 1 THEN Raylib.SetWindowShouldClose END;
    IF Raylib.IsKeyPressed(Raylib.KeyEsc) = 1 THEN pickedAtom := -1 END;
    IF Raylib.IsKeyPressed(Raylib.KeyPgUp) = 1 THEN
      IF modelNo > 1 THEN LoadFile(filePath, modelNo-1) END
    END;
    IF Raylib.IsKeyPressed(Raylib.KeyPgDn) = 1 THEN
      LoadFile(filePath, modelNo+1)
    END;

    (* Left drag: rotate *)
    IF Raylib.IsMouseButtonPressed(MouseLeft) # 0 THEN
      dragStartX := Raylib.GetMouseX();
      dragStartY := Raylib.GetMouseY();
      dragged    := FALSE
    END;
    IF Raylib.IsMouseButtonDown(MouseLeft) # 0 THEN
      RotY(rot, Raylib.GetMouseDeltaX() * 0.007);
      RotX(rot, Raylib.GetMouseDeltaY() * 0.007);
      mx := Raylib.GetMouseX(); my := Raylib.GetMouseY();
      IF (ABS(mx - dragStartX) > 3) OR (ABS(my - dragStartY) > 3) THEN
        dragged := TRUE
      END
    END;
    IF Raylib.IsMouseButtonReleased(MouseLeft) # 0 THEN
      IF ~dragged THEN
        mx := Raylib.GetMouseX(); my := Raylib.GetMouseY();
        IF my < ViewH THEN pickedAtom := PickNearest(mx, my) END
      END
    END;

    (* Right drag: pan *)
    IF Raylib.IsMouseButtonPressed(MouseRight) # 0 THEN
      panStartX  := Raylib.GetMouseX();
      panStartY  := Raylib.GetMouseY();
      panAnchorX := panX;
      panAnchorY := panY
    END;
    IF Raylib.IsMouseButtonDown(MouseRight) # 0 THEN
      mx := Raylib.GetMouseX(); my := Raylib.GetMouseY();
      panX := panAnchorX + FLT(mx - panStartX);
      panY := panAnchorY + FLT(my - panStartY)
    END;

    (* Scroll: zoom toward mouse *)
    scale := scale + Raylib.GetMouseWheelMove() * scale * 0.1;
    IF scale < 0.5 THEN scale := 0.5 END;

    Raylib.BeginDrawing;
    Raylib.ClearBackground(cBg);
    RenderScene;
    DrawStatus;
    Raylib.EndDrawing
  END;

  Raylib.CloseWindow
END PDBViewer.
