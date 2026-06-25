MODULE MacPaint;

(*
 * MacPaint — a retro paint program in the spirit of the 1984 original.
 *
 * Controls:
 *   Left-click tool panel  : select tool or brush size or color
 *   Left-click "File" menu : New / Open... / Save... / Quit
 *   Left-click "Edit" menu : Clear Canvas
 *   Left-click canvas      : draw (pencil/eraser) or drag a shape
 *   File dialog            : type filename, Enter = OK, Esc = cancel
 *)

IMPORT Raylib;

CONST
  W = 800; H = 600;
  MENU_H  = 22;
  PANEL_W = 56;
  CX0     = PANEL_W;     (* canvas screen-left *)
  CY0     = MENU_H;      (* canvas screen-top  *)
  CW      = W - PANEL_W; (* 744 *)
  CH      = H - MENU_H;  (* 578 *)
  BTN     = 28;
  HALF    = 14;

  T_PENCIL = 0; T_ERASER = 1; T_LINE  = 2;
  T_RECT   = 3; T_RFILL  = 4; T_OVAL  = 5; T_OFILL = 6;

  MNU_NONE = 0; MNU_FILE = 1; MNU_EDIT = 2;
  DLG_NONE = 0; DLG_SAVE = 1; DLG_OPEN = 2;

  (* File menu item Y positions (relative to menu bar bottom) *)
  MI_H    = 20;
  MI_NEW  = 0;
  MI_OPEN = 1;
  MI_SAVE = 2;
  MI_QUIT = 3;
  MI_W    = 120;

VAR
  cBlack, cWhite, cGray, cDkGray, cLtGray : INTEGER;
  cRed, cGreen, cBlue, cYellow, cCyan, cMagenta : INTEGER;

  uiFont       : Raylib.Font;
  canvas       : Raylib.RenderTexture;
  curTool      : INTEGER;
  brushIdx     : INTEGER;
  brushPx      : INTEGER;
  drawColor    : INTEGER;

  mx, my         : INTEGER;
  prevCX, prevCY : INTEGER;  (* previous canvas coords while dragging *)
  startCX, startCY : INTEGER;
  shapeDragging  : BOOLEAN;

  menuOpen : INTEGER;
  dlgMode  : INTEGER;
  dlgText  : ARRAY 256 OF CHAR;
  dlgLen   : INTEGER;

  palette    : ARRAY 8 OF INTEGER;
  paletteIdx : INTEGER;

(* ─────────────────────────── Helpers ─────────────────────────────────── *)

PROCEDURE Min(a, b: INTEGER): INTEGER;
BEGIN IF a < b THEN RETURN a ELSE RETURN b END END Min;

PROCEDURE Max(a, b: INTEGER): INTEGER;
BEGIN IF a > b THEN RETURN a ELSE RETURN b END END Max;

PROCEDURE BrushPx(idx: INTEGER): INTEGER;
BEGIN
  IF idx = 0 THEN RETURN 1
  ELSIF idx = 1 THEN RETURN 2
  ELSIF idx = 2 THEN RETURN 4
  ELSE RETURN 8 END
END BrushPx;

PROCEDURE InCanvas(x, y: INTEGER): BOOLEAN;
BEGIN RETURN (x >= CX0) & (x < W) & (y >= CY0) & (y < H) END InCanvas;

(* Screen → canvas coordinate conversion *)
PROCEDURE CanX(sx: INTEGER): INTEGER; BEGIN RETURN sx - CX0 END CanX;
PROCEDURE CanY(sy: INTEGER): INTEGER; BEGIN RETURN sy - CY0 END CanY;
(* Canvas → screen *)
PROCEDURE ScrX(cx: INTEGER): INTEGER; BEGIN RETURN cx + CX0 END ScrX;
PROCEDURE ScrY(cy: INTEGER): INTEGER; BEGIN RETURN cy + CY0 END ScrY;

PROCEDURE Clicked(x, y, w, h: INTEGER): BOOLEAN;
BEGIN
  RETURN (Raylib.IsMouseButtonPressed(Raylib.BtnLeft) = 1) &
         (mx >= x) & (mx < x+w) & (my >= y) & (my < y+h)
END Clicked;

PROCEDURE Released(x, y, w, h: INTEGER): BOOLEAN;
BEGIN
  RETURN (Raylib.IsMouseButtonReleased(Raylib.BtnLeft) = 1) &
         (mx >= x) & (mx < x+w) & (my >= y) & (my < y+h)
END Released;

(* ─────────────────────────── Canvas ops ─────────────────────────────── *)

PROCEDURE ClearCanvas;
BEGIN
  Raylib.BeginTextureMode(canvas);
  Raylib.ClearBackground(cWhite);
  Raylib.EndTextureMode;
END ClearCanvas;

PROCEDURE PaintStroke(x1, y1, x2, y2: INTEGER; col: INTEGER; thick: REAL);
BEGIN
  Raylib.BeginTextureMode(canvas);
  IF thick <= 1.0 THEN
    Raylib.DrawLine(x1, y1, x2, y2, col)
  ELSE
    Raylib.DrawLineEx(FLT(x1), FLT(y1), FLT(x2), FLT(y2), thick, col);
    Raylib.DrawCircle(x1, y1, thick * 0.5, col);
    Raylib.DrawCircle(x2, y2, thick * 0.5, col)
  END;
  Raylib.EndTextureMode;
END PaintStroke;

PROCEDURE CommitShape(cx1, cy1, cx2, cy2: INTEGER);
VAR rx, ry, rw, rh, ecx, ecy : INTEGER;
    erx, ery, t : REAL;
BEGIN
  rx := Min(cx1, cx2);  ry := Min(cy1, cy2);
  rw := Max(cx1, cx2) - rx + 1;
  rh := Max(cy1, cy2) - ry + 1;
  ecx := (cx1 + cx2) DIV 2;
  ecy := (cy1 + cy2) DIV 2;
  erx := FLT(ABS(cx2 - cx1)) * 0.5 + 1.0;
  ery := FLT(ABS(cy2 - cy1)) * 0.5 + 1.0;
  t   := FLT(brushPx);
  Raylib.BeginTextureMode(canvas);
  IF curTool = T_LINE THEN
    Raylib.DrawLineEx(FLT(cx1), FLT(cy1), FLT(cx2), FLT(cy2), t, drawColor)
  ELSIF curTool = T_RECT THEN
    Raylib.DrawRectangleLinesEx(rx, ry, rw, rh, t, drawColor)
  ELSIF curTool = T_RFILL THEN
    Raylib.DrawRectangle(rx, ry, rw, rh, drawColor)
  ELSIF curTool = T_OVAL THEN
    Raylib.DrawEllipseLines(ecx, ecy, erx, ery, drawColor)
  ELSIF curTool = T_OFILL THEN
    Raylib.DrawEllipse(ecx, ecy, erx, ery, drawColor)
  END;
  Raylib.EndTextureMode;
END CommitShape;

(* ─────────────────────────── UI drawing ─────────────────────────────── *)

PROCEDURE Raised(x, y, w, h: INTEGER; pressed: BOOLEAN);
BEGIN
  IF pressed THEN
    Raylib.DrawRectangle(x, y, w, h, cDkGray);
    Raylib.DrawLine(x, y, x+w-1, y, cBlack);
    Raylib.DrawLine(x, y, x, y+h-1, cBlack)
  ELSE
    Raylib.DrawRectangle(x, y, w, h, cGray);
    Raylib.DrawLine(x, y, x+w-1, y, cLtGray);
    Raylib.DrawLine(x, y, x, y+h-1, cLtGray);
    Raylib.DrawLine(x+w-1, y, x+w-1, y+h-1, cDkGray);
    Raylib.DrawLine(x, y+h-1, x+w-1, y+h-1, cDkGray)
  END;
END Raised;

PROCEDURE DrawToolIcon(bx, by, tool: INTEGER; sel: BOOLEAN);
VAR cx, cy, ic : INTEGER;
BEGIN
  Raised(bx, by, BTN, BTN, sel);
  cx := bx + BTN DIV 2;
  cy := by + BTN DIV 2;
  IF sel THEN ic := cLtGray ELSE ic := cBlack END;
  IF tool = T_PENCIL THEN
    Raylib.DrawLineEx(FLT(bx+7), FLT(by+21), FLT(bx+21), FLT(by+7), 2.0, ic);
    Raylib.DrawTriangle(FLT(bx+5), FLT(by+23),
                        FLT(bx+9),  FLT(by+23),
                        FLT(bx+7),  FLT(by+19), ic)
  ELSIF tool = T_ERASER THEN
    Raylib.DrawRectangle(bx+5, by+9,  18, 12, ic);
    Raylib.DrawRectangle(bx+5, by+9,  18, 12, ic);
    Raylib.DrawLine(bx+4, by+22, bx+23, by+22, ic)
  ELSIF tool = T_LINE THEN
    Raylib.DrawLineEx(FLT(bx+6), FLT(by+22), FLT(bx+22), FLT(by+6), 2.0, ic)
  ELSIF tool = T_RECT THEN
    Raylib.DrawRectangleLines(bx+5, by+8, 18, 12, ic)
  ELSIF tool = T_RFILL THEN
    Raylib.DrawRectangle(bx+5, by+8, 18, 12, ic)
  ELSIF tool = T_OVAL THEN
    Raylib.DrawEllipseLines(cx, cy, 11.0, 8.0, ic)
  ELSIF tool = T_OFILL THEN
    Raylib.DrawEllipse(cx, cy, 11.0, 8.0, ic)
  END;
END DrawToolIcon;

PROCEDURE DrawToolPanel;
VAR i, bx, by, py : INTEGER;
BEGIN
  Raylib.DrawRectangle(0, MENU_H, PANEL_W, H - MENU_H, cGray);
  Raylib.DrawLine(PANEL_W-1, MENU_H, PANEL_W-1, H, cDkGray);

  (* 7 tool buttons in 2-column grid *)
  FOR i := 0 TO 6 DO
    bx := (i MOD 2) * BTN;
    by := MENU_H + (i DIV 2) * BTN;
    DrawToolIcon(bx, by, i, i = curTool)
  END;

  (* Separator *)
  py := MENU_H + 4*BTN + 2;
  Raylib.DrawLine(2, py, PANEL_W-3, py, cDkGray);

  (* Brush size row: 4 sizes × HALF wide *)
  py := py + 4;
  Raylib.DrawTextEx(uiFont, "SZ", 2.0, FLT(py), 13.0, 1.0, cDkGray);
  py := py + 10;
  FOR i := 0 TO 3 DO
    Raised(i*HALF, py, HALF, BTN, i = brushIdx);
    Raylib.DrawCircle(i*HALF + HALF DIV 2, py + BTN DIV 2,
                      FLT(BrushPx(i)) * 0.8 + 0.4, cBlack)
  END;

  (* Color palette: 8 swatches in 2 rows × 4 cols *)
  py := py + BTN + 6;
  Raylib.DrawTextEx(uiFont, "COL", 2.0, FLT(py), 13.0, 1.0, cDkGray);
  py := py + 10;
  FOR i := 0 TO 7 DO
    bx := (i MOD 4) * HALF;
    by := py + (i DIV 4) * HALF;
    Raylib.DrawRectangle(bx+1, by+1, HALF-2, HALF-2, palette[i]);
    IF i = paletteIdx THEN
      Raylib.DrawRectangleLines(bx, by, HALF, HALF, cWhite)
    ELSE
      Raylib.DrawRectangleLines(bx, by, HALF, HALF, cDkGray)
    END
  END;

  (* Active color swatch *)
  py := py + 2*HALF + 6;
  Raylib.DrawRectangle(4, py, PANEL_W-8, 16, drawColor);
  Raylib.DrawRectangleLines(3, py-1, PANEL_W-6, 18, cBlack);
END DrawToolPanel;

PROCEDURE DrawMenuBar;
VAR hilite : INTEGER;
BEGIN
  Raylib.DrawRectangle(0, 0, W, MENU_H, cBlack);
  (* App name - decorative *)
  Raylib.DrawTextEx(uiFont, "MacPaint", 6.0, 4.0, 13.0, 1.0, cLtGray);

  hilite := cBlack;
  IF menuOpen = MNU_FILE THEN hilite := cDkGray END;
  Raylib.DrawRectangle(100, 0, 56, MENU_H, hilite);
  Raylib.DrawTextEx(uiFont, "File", 108.0, 4.0, 13.0, 1.0, cWhite);

  hilite := cBlack;
  IF menuOpen = MNU_EDIT THEN hilite := cDkGray END;
  Raylib.DrawRectangle(156, 0, 56, MENU_H, hilite);
  Raylib.DrawTextEx(uiFont, "Edit", 164.0, 4.0, 13.0, 1.0, cWhite);
END DrawMenuBar;

PROCEDURE DrawMenuDropdown;
VAR y0 : INTEGER;
BEGIN
  IF menuOpen = MNU_FILE THEN
    y0 := MENU_H;
    Raylib.DrawRectangle(100, y0, MI_W, 4*MI_H+8, cLtGray);
    Raylib.DrawRectangleLines(100, y0, MI_W, 4*MI_H+8, cDkGray);
    Raylib.DrawTextEx(uiFont, "New",     110.0, FLT(y0 + 4 + 0*MI_H), 13.0, 1.0, cBlack);
    Raylib.DrawTextEx(uiFont, "Open...", 110.0, FLT(y0 + 4 + 1*MI_H), 13.0, 1.0, cBlack);
    Raylib.DrawTextEx(uiFont, "Save...", 110.0, FLT(y0 + 4 + 2*MI_H), 13.0, 1.0, cBlack);
    Raylib.DrawLine(104, y0 + 4 + 3*MI_H - 3, 218, y0 + 4 + 3*MI_H - 3, cGray);
    Raylib.DrawTextEx(uiFont, "Quit",    110.0, FLT(y0 + 4 + 3*MI_H), 13.0, 1.0, cBlack)
  ELSIF menuOpen = MNU_EDIT THEN
    y0 := MENU_H;
    Raylib.DrawRectangle(156, y0, MI_W, MI_H+8, cLtGray);
    Raylib.DrawRectangleLines(156, y0, MI_W, MI_H+8, cDkGray);
    Raylib.DrawTextEx(uiFont, "Clear Canvas", 164.0, FLT(y0+4), 13.0, 1.0, cBlack)
  END;
END DrawMenuDropdown;

PROCEDURE DrawPreview;
VAR sx1, sy1, rx, ry, rw, rh, ecx, ecy : INTEGER;
    erx, ery, t : REAL;
BEGIN
  IF ~shapeDragging THEN RETURN END;
  IF (curTool < T_LINE) OR (curTool > T_OFILL) THEN RETURN END;
  sx1 := ScrX(startCX); sy1 := ScrY(startCY);
  rx  := Min(sx1, mx);  ry  := Min(sy1, my);
  rw  := Max(sx1, mx) - rx + 1;
  rh  := Max(sy1, my) - ry + 1;
  ecx := (sx1 + mx) DIV 2;
  ecy := (sy1 + my) DIV 2;
  erx := FLT(ABS(mx - sx1)) * 0.5 + 1.0;
  ery := FLT(ABS(my - sy1)) * 0.5 + 1.0;
  t   := FLT(brushPx);
  IF curTool = T_LINE THEN
    Raylib.DrawLineEx(FLT(sx1), FLT(sy1), FLT(mx), FLT(my), t, drawColor)
  ELSIF curTool = T_RECT THEN
    Raylib.DrawRectangleLinesEx(rx, ry, rw, rh, t, drawColor)
  ELSIF curTool = T_RFILL THEN
    Raylib.DrawRectangle(rx, ry, rw, rh, drawColor)
  ELSIF curTool = T_OVAL THEN
    Raylib.DrawEllipseLines(ecx, ecy, erx, ery, drawColor)
  ELSIF curTool = T_OFILL THEN
    Raylib.DrawEllipse(ecx, ecy, erx, ery, drawColor)
  END;
END DrawPreview;

PROCEDURE DrawFileDialog;
CONST DW = 400; DH = 104;
VAR dx, dy, cw : INTEGER;
BEGIN
  IF dlgMode = DLG_NONE THEN RETURN END;
  dx := (W - DW) DIV 2;
  dy := (H - DH) DIV 2;
  (* Drop shadow *)
  Raylib.DrawRectangle(dx+5, dy+5, DW, DH, cDkGray);
  (* Box *)
  Raylib.DrawRectangle(dx, dy, DW, DH, cLtGray);
  Raylib.DrawRectangleLines(dx, dy, DW, DH, cBlack);
  (* Title bar *)
  Raylib.DrawRectangle(dx, dy, DW, 20, cBlack);
  IF dlgMode = DLG_SAVE THEN
    Raylib.DrawTextEx(uiFont, "Save As...", FLT(dx+6), FLT(dy+3), 13.0, 1.0, cWhite)
  ELSE
    Raylib.DrawTextEx(uiFont, "Open File...", FLT(dx+6), FLT(dy+3), 13.0, 1.0, cWhite)
  END;
  (* Input field *)
  Raylib.DrawRectangle(dx+8, dy+28, DW-16, 22, cWhite);
  Raylib.DrawRectangleLines(dx+8, dy+28, DW-16, 22, cBlack);
  Raylib.DrawTextEx(uiFont, dlgText, FLT(dx+11), FLT(dy+32), 13.0, 1.0, cBlack);
  (* Text cursor *)
  cw := Raylib.MeasureTextEx(uiFont, dlgText, 13.0, 1.0);
  Raylib.DrawLine(dx+11+cw, dy+31, dx+11+cw, dy+46, cBlack);
  (* Hint *)
  Raylib.DrawTextEx(uiFont, "Enter = confirm   Esc = cancel", FLT(dx+8), FLT(dy+58), 13.0, 1.0, cDkGray);
  (* OK button *)
  Raised(dx+DW-72, dy+DH-26, 64, 20, FALSE);
  Raylib.DrawTextEx(uiFont, "OK", FLT(dx+DW-52), FLT(dy+DH-20), 13.0, 1.0, cBlack);
END DrawFileDialog;

PROCEDURE Draw;
BEGIN
  Raylib.BeginDrawing;
  Raylib.ClearBackground(cDkGray);
  (* Canvas background *)
  Raylib.DrawRectangle(CX0, CY0, CW, CH, cWhite);
  (* Render texture → screen (flip handled in C) *)
  Raylib.DrawRenderTexture(canvas, CX0, CY0, CW, CH, cWhite);
  (* Canvas border *)
  Raylib.DrawRectangleLines(CX0-1, CY0-1, CW+2, CH+2, cBlack);
  (* Shape preview on top *)
  DrawPreview;
  (* UI panels *)
  DrawToolPanel;
  DrawMenuBar;
  DrawMenuDropdown;
  DrawFileDialog;
  Raylib.EndDrawing;
END Draw;

(* ─────────────────────────── Input handling ──────────────────────────── *)

PROCEDURE OpenDlg(mode: INTEGER);
BEGIN
  dlgMode := mode;
  dlgText[0] := 0X;
  dlgLen := 0;
  menuOpen := MNU_NONE;
END OpenDlg;

PROCEDURE UpdateDialog;
VAR ch : INTEGER;
BEGIN
  (* Collect typed characters *)
  ch := Raylib.GetCharPressed();
  WHILE ch # 0 DO
    IF (ch >= 32) & (ch < 127) & (dlgLen < 254) THEN
      dlgText[dlgLen] := CHR(ch);
      INC(dlgLen);
      dlgText[dlgLen] := 0X
    END;
    ch := Raylib.GetCharPressed()
  END;
  IF (Raylib.IsKeyPressed(Raylib.KeyBackspace) = 1) & (dlgLen > 0) THEN
    DEC(dlgLen);
    dlgText[dlgLen] := 0X
  END;
  IF Raylib.IsKeyPressed(Raylib.KeyEnter) = 1 THEN
    IF dlgMode = DLG_SAVE THEN
      Raylib.SaveRTPNG(canvas, dlgText)
    ELSIF dlgMode = DLG_OPEN THEN
      Raylib.LoadPNGIntoRT(canvas, dlgText)
    END;
    dlgMode := DLG_NONE
  END;
  IF Raylib.IsKeyPressed(Raylib.KeyEsc) = 1 THEN
    dlgMode := DLG_NONE
  END;
END UpdateDialog;

PROCEDURE HandleMenuClick;
VAR y0 : INTEGER;
BEGIN
  y0 := MENU_H;
  IF menuOpen = MNU_FILE THEN
    IF Clicked(100, y0+4+0*MI_H, MI_W, MI_H) THEN
      ClearCanvas; menuOpen := MNU_NONE
    ELSIF Clicked(100, y0+4+1*MI_H, MI_W, MI_H) THEN
      OpenDlg(DLG_OPEN)
    ELSIF Clicked(100, y0+4+2*MI_H, MI_W, MI_H) THEN
      OpenDlg(DLG_SAVE)
    ELSIF Clicked(100, y0+4+3*MI_H, MI_W, MI_H) THEN
      Raylib.CloseWindow; menuOpen := MNU_NONE
    ELSIF Clicked(0, 0, W, H) THEN
      menuOpen := MNU_NONE
    END
  ELSIF menuOpen = MNU_EDIT THEN
    IF Clicked(156, y0+4, MI_W, MI_H) THEN
      ClearCanvas; menuOpen := MNU_NONE
    ELSIF Clicked(0, 0, W, H) THEN
      menuOpen := MNU_NONE
    END
  END;
END HandleMenuClick;

PROCEDURE HandlePanelClick;
VAR i, bx, by, py : INTEGER;
BEGIN
  (* Tool buttons *)
  FOR i := 0 TO 6 DO
    bx := (i MOD 2) * BTN;
    by := MENU_H + (i DIV 2) * BTN;
    IF Clicked(bx, by, BTN, BTN) THEN
      curTool := i
    END
  END;
  (* Brush size *)
  py := MENU_H + 4*BTN + 2 + 4 + 10;
  FOR i := 0 TO 3 DO
    IF Clicked(i*HALF, py, HALF, BTN) THEN
      brushIdx := i; brushPx := BrushPx(i)
    END
  END;
  (* Color palette *)
  py := py + BTN + 16;
  FOR i := 0 TO 7 DO
    bx := (i MOD 4) * HALF;
    by := py + (i DIV 4) * HALF;
    IF Clicked(bx, by, HALF, HALF) THEN
      paletteIdx := i; drawColor := palette[i]
    END
  END;
END HandlePanelClick;

PROCEDURE HandleCanvasInput;
VAR cx, cy : INTEGER;
    thick : REAL;
BEGIN
  cx := CanX(mx); cy := CanY(my);
  thick := FLT(brushPx);

  IF Raylib.IsMouseButtonPressed(Raylib.BtnLeft) = 1 THEN
    IF InCanvas(mx, my) THEN
      IF (curTool = T_PENCIL) OR (curTool = T_ERASER) THEN
        (* First dot *)
        IF curTool = T_PENCIL THEN
          PaintStroke(cx, cy, cx, cy, drawColor, thick)
        ELSE
          PaintStroke(cx, cy, cx, cy, cWhite, thick * 3.0)
        END;
        prevCX := cx; prevCY := cy
      ELSE
        (* Begin shape drag *)
        startCX := cx; startCY := cy;
        shapeDragging := TRUE
      END
    END
  END;

  IF Raylib.IsMouseButtonDown(Raylib.BtnLeft) = 1 THEN
    IF InCanvas(mx, my) THEN
      IF (curTool = T_PENCIL) & ~shapeDragging THEN
        PaintStroke(prevCX, prevCY, cx, cy, drawColor, thick)
      ELSIF (curTool = T_ERASER) & ~shapeDragging THEN
        PaintStroke(prevCX, prevCY, cx, cy, cWhite, thick * 3.0)
      END
    END;
    prevCX := cx; prevCY := cy
  END;

  IF Raylib.IsMouseButtonReleased(Raylib.BtnLeft) = 1 THEN
    IF shapeDragging THEN
      CommitShape(startCX, startCY, cx, cy);
      shapeDragging := FALSE
    END
  END;
END HandleCanvasInput;

PROCEDURE Update;
BEGIN
  mx := Raylib.GetMouseX();
  my := Raylib.GetMouseY();

  IF dlgMode # DLG_NONE THEN
    UpdateDialog; RETURN
  END;

  (* Menu bar clicks *)
  IF Clicked(100, 0, 56, MENU_H) THEN
    IF menuOpen = MNU_FILE THEN menuOpen := MNU_NONE
    ELSE menuOpen := MNU_FILE END;
    RETURN
  ELSIF Clicked(156, 0, 56, MENU_H) THEN
    IF menuOpen = MNU_EDIT THEN menuOpen := MNU_NONE
    ELSE menuOpen := MNU_EDIT END;
    RETURN
  END;

  IF menuOpen # MNU_NONE THEN
    HandleMenuClick; RETURN
  END;

  (* Tool panel *)
  IF (mx >= 0) & (mx < PANEL_W) & (my >= MENU_H) THEN
    HandlePanelClick; RETURN
  END;

  (* Canvas *)
  HandleCanvasInput;
END Update;

(* ─────────────────────────── Initialisation ──────────────────────────── *)

PROCEDURE Init;
BEGIN
  cBlack   := Raylib.Black();
  cWhite   := Raylib.White();
  cGray    := Raylib.Gray();
  cDkGray  := Raylib.DarkGray();
  cLtGray  := Raylib.LightGray();
  cRed     := Raylib.Red();
  cGreen   := Raylib.Green();
  cBlue    := Raylib.Blue();
  cYellow  := Raylib.Yellow();
  cCyan    := Raylib.SkyBlue();
  cMagenta := Raylib.Magenta();

  palette[0] := cBlack;
  palette[1] := cWhite;
  palette[2] := cRed;
  palette[3] := cGreen;
  palette[4] := cBlue;
  palette[5] := cYellow;
  palette[6] := cCyan;
  palette[7] := cMagenta;

  paletteIdx := 0;
  drawColor  := cBlack;
  curTool    := T_PENCIL;
  brushIdx   := 0;
  brushPx    := 1;
  menuOpen   := MNU_NONE;
  dlgMode    := DLG_NONE;
  dlgText[0] := 0X;
  dlgLen     := 0;
  shapeDragging := FALSE;

  uiFont := Raylib.LoadFontSharpAppDir("Lato-Regular.ttf", 13);
  canvas := Raylib.LoadRenderTexture(CW, CH);
  ClearCanvas;
END Init;

BEGIN
  Raylib.InitWindow(W, H, "MacPaint");
  Raylib.SetTargetFPS(60);
  Init;
  WHILE Raylib.WindowShouldClose() = 0 DO
    Update;
    Draw
  END;
  Raylib.UnloadRenderTexture(canvas);
  Raylib.UnloadFont(uiFont);
  Raylib.CloseWindow;
END MacPaint.
