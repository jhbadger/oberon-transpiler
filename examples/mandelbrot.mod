MODULE Mandelbrot;
(*
 * Interactive Mandelbrot explorer.
 *
 * Controls:
 *   Arrow keys   — move cursor
 *   + / =        — zoom in  (2×, centred on cursor)
 *   -            — zoom out (2×, centred on cursor)
 *   r            — reset view
 *   q / Esc      — quit
 *
 * Display (80×24 terminal, pixel buffer via half-blocks):
 *   pixel cols  3..76  → terminal cols  3..76   (PW=74)
 *   pixel rows  2..43  → terminal rows  2..22   (PH=42, 21 half-block rows)
 *   status line: row 24
 *)

IMPORT Graphics, Terminal, Out;

CONST
  PW      = 74;   (* pixel width                           *)
  PH      = 42;   (* pixel height  (2 × 21 terminal rows) *)
  OX      = 3;    (* left pixel offset                     *)
  OY      = 2;    (* top  pixel offset                     *)
  MaxIter = 128;

  KUp    = 01X;
  KDown  = 02X;
  KLeft  = 03X;
  KRight = 04X;
  KEsc   = 1BX;

VAR
  px, py, n, color : INTEGER;
  curX, curY       : INTEGER;
  xMin, xMax       : REAL;
  yMin, yMax       : REAL;
  cre, cim         : REAL;
  hw, hh           : REAL;
  key              : CHAR;
  running          : BOOLEAN;

PROCEDURE Iterate(cx0, cy0 : REAL) : INTEGER;
VAR zx, zy, t : REAL;
    iter       : INTEGER;
BEGIN
  zx := 0.0;  zy := 0.0;  iter := 0;
  WHILE (zx * zx + zy * zy < 4.0) & (iter < MaxIter) DO
    t    := zx * zx - zy * zy + cx0;
    zy   := 2.0 * zx * zy + cy0;
    zx   := t;
    iter := iter + 1
  END;
  RETURN iter
END Iterate;

PROCEDURE Draw;
VAR w, h : REAL;
BEGIN
  Graphics.ClearBuf;
  w := xMax - xMin;
  h := yMax - yMin;

  FOR py := 0 TO PH - 1 DO
    FOR px := 0 TO PW - 1 DO
      cre := xMin + w * px / PW;
      cim := yMax - h * py / PH;
      n   := Iterate(cre, cim);
      IF n < MaxIter THEN
        color := (n MOD 215) + 17;
        Graphics.Plot(OX + px, OY + py, color)
      END
    END
  END;

  (* Cursor crosshair in white (colour 7) *)
  IF curX > 0 THEN
    Graphics.Plot(OX + curX - 1, OY + curY, 255)
  END;
  IF curX < PW - 1 THEN
    Graphics.Plot(OX + curX + 1, OY + curY, 255)
  END;
  IF curY > 0 THEN
    Graphics.Plot(OX + curX, OY + curY - 1, 255)
  END;
  IF curY < PH - 1 THEN
    Graphics.Plot(OX + curX, OY + curY + 1, 255)
  END;
  Graphics.Plot(OX + curX, OY + curY, 255);

  Graphics.Flush;
  Graphics.Reset;
  Graphics.Box(1, 1, 80, 23);

  (* Status bar *)
  cre := xMin + (xMax - xMin) * curX / PW;
  cim := yMax - (yMax - yMin) * curY / PH;
  Graphics.Goto(2, 24);
  Out.String(" Re:"); Out.Fixed(cre, 8, 5);
  Out.String(" Im:"); Out.Fixed(cim, 8, 5);
  Out.String("  +/-=zoom  arrows=move  r=reset  q=quit ")
END Draw;

PROCEDURE ZoomIn;
BEGIN
  cre := xMin + (xMax - xMin) * curX / PW;
  cim := yMax - (yMax - yMin) * curY / PH;
  hw  := (xMax - xMin) / 4.0;
  hh  := (yMax - yMin) / 4.0;
  xMin := cre - hw;  xMax := cre + hw;
  yMin := cim - hh;  yMax := cim + hh
END ZoomIn;

PROCEDURE ZoomOut;
BEGIN
  cre := xMin + (xMax - xMin) * curX / PW;
  cim := yMax - (yMax - yMin) * curY / PH;
  hw  := xMax - xMin;
  hh  := yMax - yMin;
  xMin := cre - hw;  xMax := cre + hw;
  yMin := cim - hh;  yMax := cim + hh
END ZoomOut;

PROCEDURE Reset;
BEGIN
  xMin := -2.5;  xMax := 1.0;
  yMin := -1.1;  yMax := 1.1;
  curX := PW DIV 2;
  curY := PH DIV 2
END Reset;

BEGIN
  Reset;
  running := TRUE;
  Graphics.Clear;

  WHILE running DO
    Draw;
    key := Terminal.ReadKey();
    IF    key = KUp    THEN  IF curY > 1         THEN DEC(curY, 2) END
    ELSIF key = KDown  THEN  IF curY < PH - 2    THEN INC(curY, 2) END
    ELSIF key = KLeft  THEN  IF curX > 1         THEN DEC(curX, 2) END
    ELSIF key = KRight THEN  IF curX < PW - 2    THEN INC(curX, 2) END
    ELSIF (key = '+') OR (key = '=') THEN  ZoomIn
    ELSIF  key = '-'                 THEN  ZoomOut
    ELSIF (key = 'r') OR (key = 'R') THEN  Reset
    ELSIF (key = 'q') OR (key = 'Q') OR (key = KEsc) THEN  running := FALSE
    END
  END;

  Graphics.Clear;
  Graphics.Reset
END Mandelbrot.
