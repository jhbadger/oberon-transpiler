MODULE Mandelbrot;
(*
 * Mandelbrot set plotted in the terminal using the Graphics module.
 * Colours are drawn using 256-colour ANSI backgrounds; each cell is
 * a space character so the background colour fills it completely.
 *
 * Layout (fits an 80x24 terminal):
 *   box  : columns 3-78, rows 1-23  (76 wide, 23 tall)
 *   plot : columns 4-77, rows 2-22  (74 wide, 21 tall)
 *   status line: row 24
 *)

IMPORT Graphics, Out;

CONST
  W       = 74;     (* plot width  in character columns *)
  H       = 21;     (* plot height in character rows    *)
  MaxIter = 64;     (* max Mandelbrot iterations        *)

VAR
  col, row, n : INTEGER;
  cx, cy      : REAL;
  ch          : CHAR;

(* ------------------------------------------------------------------ *)
(* Iterate z <- z^2 + c starting from z=0.                            *)
(* Returns the iteration count at which |z| > 2, or MaxIter if the   *)
(* point appears to be inside the set.                                *)
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

(* ------------------------------------------------------------------ *)
(* Map an iteration count to a 256-colour index.                      *)
(* Interior (n = MaxIter) -> colour 16 (very dark, near black).       *)
(* Exterior -> cycle through the 6x6x6 colour cube (indices 17-231). *)
(* The multiplier 7 is coprime with 215 so all 215 colours are hit    *)
(* before the pattern repeats.                                         *)
(* ------------------------------------------------------------------ *)
PROCEDURE PickColor(n : INTEGER) : INTEGER;
BEGIN
  IF n >= MaxIter THEN RETURN 16 END;
  RETURN 17 + (n * 7) MOD 215
END PickColor;

BEGIN
  Graphics.Clear;

  (* ── Plot ──────────────────────────────────────────────────────── *)
  FOR row := 0 TO H - 1 DO
    FOR col := 0 TO W - 1 DO
      (* Map (col, row) to a point in the complex plane.
         Real axis : -2.5 .. 1.0   (range 3.5)
         Imag axis :  1.1 .. -1.1  (range 2.2, top-to-bottom)
         The 2:1 char aspect ratio means 3.5/74 ~= 2.2/21 * 0.5,
         giving a reasonable approximation of a circular set. *)
      cx := -2.5 + 3.5 * col / W;
      cy :=  1.1 - 2.2 * row / H;
      n  := Iterate(cx, cy);
      Graphics.Color256(0, PickColor(n));
      Graphics.Goto(col + 4, row + 2);
      Out.Char(' ')
    END
  END;

  (* ── Border and status ─────────────────────────────────────────── *)
  Graphics.Reset;
  Graphics.Box(3, 1, 76, 23);
  Graphics.Goto(4, 24);
  Out.String("Mandelbrot set  [Re: -2.5 .. 1.0   Im: -1.1 .. 1.1]   press Enter");
  READ(ch)
END Mandelbrot.
