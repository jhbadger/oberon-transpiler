MODULE StarBurst;

IMPORT Turtle, Math;

PROCEDURE Draw*;
VAR
  angle: REAL;
  i: INTEGER;
BEGIN
  Turtle.Init;
  
  (* We iterate 360 degrees, but in steps to create a star pattern *)
  (* Using Rotate(angle) allows us to precisely set the heading regardless of the last move *)
  
  FOR i := 0 TO 71 DO
    angle := FLT(i) * 5.0;
    
    (* Change color based on the current angle for a rainbow effect *)
    Turtle.SetColor((i MOD 6) + 1); 
    
    (* Set absolute heading *)
    Turtle.Rotate(angle); 
    
    (* Draw a 'ray' out and back *)
    Turtle.Forward(30.0);
    Turtle.PenUp;
    Turtle.Forward(-30.0);
    Turtle.PenDown;
  END;

  Turtle.Update;
END Draw;

BEGIN
  Draw;
END StarBurst.
