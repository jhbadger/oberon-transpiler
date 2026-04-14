MODULE SixelDemo;

IMPORT Sixel, Math, Out;

PROCEDURE Draw*;
  VAR 
    i, x, y, oldX, oldY: INTEGER;
    angle, radius: REAL;
BEGIN
  (* Initialize the 640x480 buffer *)
  Sixel.Init(Sixel.Width, Sixel.Height);
  Sixel.ClearBuf;

  (* 1. Define a Dynamic Palette *)
  (* Let's create a gradient of 100 colors from Blue to Red *)
  FOR i := 0 TO 99 DO
    (* SetPalette scales 0-255 inputs to Sixel 0-100 internally *)
    Sixel.SetPalette(i, i * 2, 50, 255 - (i * 2))
  END;

  (* 2. Draw a Spiral using the Line primitive *)
  angle := 0.0;
  radius := 10.0;
  oldX := Sixel.Width DIV 2;
  oldY := Sixel.Height DIV 2;

  FOR i := 0 TO 500 DO
    x := (Sixel.Width DIV 2) + Math.entier(radius * Math.cos(angle));
    y := (Sixel.Height DIV 2) + Math.entier(radius * Math.sin(angle));
    
    (* Cycle through our 100 dynamic palette indices *)
    Sixel.Line(oldX, oldY, x, y, i MOD 100);
    
    oldX := x;
    oldY := y;
    angle := angle + 0.1;
    radius := radius + 0.5
  END;

  (* 3. Draw a few simple shapes *)
  Sixel.SetPalette(200, 255, 255, 255); (* White *)
  Sixel.Line(10, 10, 100, 10, 200);
  Sixel.Line(10, 10, 10, 100, 200);

  (* 4. Output the result *)
  Sixel.Flush();
  Out.Ln;
  Out.String("Sixel Demo Complete.");
  Out.Ln
END Draw;

BEGIN
  Draw
END SixelDemo.