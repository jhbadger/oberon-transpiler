MODULE Sixel;

(* DEC Sixel graphics allowing higher res than Graphics Module *)

IMPORT Out, Math;

CONST
  Width* = 640;
  Height* = 480;
  MaxColors = 256;

TYPE
  PaletteColor = RECORD r, g, b: INTEGER END;

VAR
  (* The pixel buffer stores color indices (0-255) *)
  pixels: ARRAY Width, Height OF BYTE;
  palette: ARRAY MaxColors OF PaletteColor;
  changed: ARRAY MaxColors OF BOOLEAN;

PROCEDURE Init*(w, h: INTEGER);
  VAR x, y: INTEGER;
BEGIN
  (* Initialize buffer and default palette *)
  FOR x := 0 TO Width - 1 DO
    FOR y := 0 TO Height - 1 DO pixels[x, y] := 0 END
  END;
  FOR x := 0 TO MaxColors - 1 DO
    palette[x].r := 0; palette[x].g := 0; palette[x].b := 0;
    changed[x] := FALSE
  END
END Init;

PROCEDURE SetPalette*(idx, r, g, b: INTEGER);
BEGIN
  IF (idx >= 0) & (idx < MaxColors) THEN
    (* Sixel RGB expects 0-100; we convert from 0-255 *)
    palette[idx].r := (r * 100) DIV 255;
    palette[idx].g := (g * 100) DIV 255;
    palette[idx].b := (b * 100) DIV 255;
    changed[idx] := TRUE
  END
END SetPalette;

PROCEDURE Plot*(x, y, color: INTEGER);
BEGIN
  IF (x >= 0) & (x < Width) & (y >= 0) & (y < Height) THEN
    pixels[x, y] := CHR(color)
  END
END Plot;

PROCEDURE ClearBuf*;
  VAR x, y: INTEGER;
BEGIN
  FOR x := 0 TO Width - 1 DO
    FOR y := 0 TO Height - 1 DO pixels[x, y] := 0 END
  END
END ClearBuf;

PROCEDURE Flush*;
  VAR x, y, sy, col, sixel: INTEGER;
BEGIN
  (* DCS Introducer for Sixel: ESC P q *)
  Out.Char(CHR(27)); Out.Char("P"); Out.Char("q");
  
  (* Define dynamic palette *)
  FOR col := 0 TO MaxColors - 1 DO
    IF changed[col] THEN
      Out.Char("#"); Out.Int(col); Out.String(";2;");
      Out.Int(palette[col].r); Out.Char(";");
      Out.Int(palette[col].g); Out.Char(";");
      Out.Int(palette[col].b)
    END
  END;

  (* Encode Pixels: Sixel processes 6 vertical pixels at a time *)
  FOR sy := 0 TO (Height DIV 6) - 1 DO
    FOR col := 0 TO MaxColors - 1 DO
      Out.Char("#"); Out.Int(col);
      FOR x := 0 TO Width - 1 DO
        sixel := 0;
        FOR y := 0 TO 5 DO
          IF ORD(pixels[x, sy * 6 + y]) = col THEN
            (* Use LSL(value, amount) instead of << *)
            sixel := sixel + LSL(1, y)
          END
        END;
        Out.Char(CHR(sixel + 63))
      END;
      Out.Char("$") (* Carriage return to start of line for next color *)
    END;
    Out.Char("-") (* New line (next 6-pixel strip) *)
  END;

  (* ST: String Terminator: ESC \ *)
  Out.Char(CHR(27)); Out.Char("\")
END Flush;

(* Drawing primitives using Plot *)

PROCEDURE Line*(x0, y0, x1, y1, color: INTEGER);
  VAR dx, dy, sx, sy, err, e2: INTEGER;
BEGIN
  dx := ABS(x1 - x0); dy := ABS(y1 - y0);
  IF x0 < x1 THEN sx := 1 ELSE sx := -1 END;
  IF y0 < y1 THEN sy := 1 ELSE sy := -1 END;
  err := dx - dy;
  LOOP
    Plot(x0, y0, color);
    IF (x0 = x1) & (y0 = y1) THEN EXIT END;
    e2 := 2 * err;
    IF e2 > -dy THEN err := err - dy; x0 := x0 + sx END;
    IF e2 < dx THEN err := err + dx; y0 := y0 + sy END
  END
END Line;

BEGIN
  Init(Width, Height)
END Sixel.