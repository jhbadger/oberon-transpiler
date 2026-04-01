MODULE Mandelbrot;
(*
 * Mandelbrot set — rendered into the pixel buffer with Plot/Flush so
 * each terminal cell carries two pixel rows (▀ / ▄ / █ half-blocks),
 * giving 2× vertical resolution over the old character-cell version.
 *
 * Fits an 80×24 terminal:
 *   pixel cols  3..76  → terminal cols  3..76   (74 wide)
 *   pixel rows  2..43  → terminal rows  2..22   (42 px = 21 rows via half-blocks)
 *   status line: row 24
 *)

IMPORT Graphics, Out;

CONST
  PW      = 74;     (* pixel width                            *)
  PH      = 42;     (* pixel height  (2 × 21 terminal rows)  *)
  OX      = 3;      (* left pixel offset                      *)
  OY      = 2;      (* top  pixel offset                      *)
  MaxIter = 128;

VAR
  px, py, n, color : INTEGER;
  cx, cy           : REAL;
  ch               : CHAR;

(* ------------------------------------------------------------------ *)
(* Mandelbrot iteration count for c = (cx0, cy0).                     *)
(* ------------------------------------------------------------------ *)
PROCEDURE Iterate(cx0, cy0 : REAL) : INTEGER;
VAR zx, zy, t : REAL;
    n          : INTEGER;
BEGIN
  zx := 0.0;  zy := 0.0;  n := 0;
  WHILE (zx * zx + zy * zy < 4.0) & (n < MaxIter) DO
    t  := zx * zx - zy * zy + cx0;
    zy := 2.0 * zx * zy + cy0;
    zx := t;
    n  := n + 1
  END;
  RETURN n
END Iterate;

BEGIN
  Graphics.Clear;
  Graphics.ClearBuf;

  (* ── Fill pixel buffer ─────────────────────────────────────────── *)
  FOR py := 0 TO PH - 1 DO
    FOR px := 0 TO PW - 1 DO
      cx := -2.5 + 3.5 * px / PW;
      cy :=  1.1 - 2.2 * py / PH;
      n  := Iterate(cx, cy);
      IF n < MaxIter THEN
        (* Cycle through colours 1-6; inner points (n=MaxIter) → black *)
        color := (n MOD 6) + 1;
        Graphics.Plot(OX + px, OY + py, color)
      END
    END
  END;

  (* ── Render buffer using half-block characters ─────────────────── *)
  Graphics.Flush;

  (* ── Border and status ─────────────────────────────────────────── *)
  Graphics.Reset;
  Graphics.Box(1, 1, 80, 23);
  Graphics.Goto(2, 24);
  Out.String(" Mandelbrot  Re[-2.5,1.0] Im[-1.1,1.1]  press Enter ");
  READ(ch)
END Mandelbrot.
