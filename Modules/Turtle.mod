MODULE Turtle;

IMPORT Graphics, Math;

TYPE
  State* = RECORD
    x, y: REAL;
    angle: REAL;
  END;

VAR
  cur: State;
  penDown: BOOLEAN;
  penColor: INTEGER;

(** Returns the current X coordinate **)
PROCEDURE GetX*(): REAL; BEGIN RETURN cur.x END GetX;

(** Returns the current Y coordinate **)
PROCEDURE GetY*(): REAL; BEGIN RETURN cur.y END GetY;

(** Returns the current heading in degrees **)
PROCEDURE GetHeading*(): REAL; 
BEGIN RETURN cur.angle * 180.0 / Math.pi END GetHeading;

(** Teleports the turtle to (x, y) without drawing **)
PROCEDURE SetPos*(x, y: REAL);
BEGIN
  cur.x := x;
  cur.y := y;
END SetPos;

(** Sets the absolute heading in degrees (0 = East) **)
PROCEDURE Rotate*(degrees: REAL);
BEGIN
  cur.angle := degrees * Math.pi / 180.0;
END Rotate;

(** Turns the turtle right by 'degrees' relative to current heading **)
PROCEDURE Right*(degrees: REAL);
BEGIN
  cur.angle := cur.angle + (degrees * Math.pi / 180.0);
END Right;

(** Moves the turtle forward. Automatically clamps to screen bounds [0-239, 0-99] **)
PROCEDURE Forward*(dist: REAL);
VAR
  nextX, nextY: REAL;
BEGIN
  nextX := Math.clamp(cur.x + (dist * Math.cos(cur.angle)), 0.0, 239.0);
  nextY := Math.clamp(cur.y + (dist * Math.sin(cur.angle)), 0.0, 99.0);
  
  IF penDown THEN
    Graphics.Line(Math.entier(cur.x), Math.entier(cur.y), 
                  Math.entier(nextX), Math.entier(nextY), penColor);
  END;
  
  cur.x := nextX;
  cur.y := nextY;
END Forward;

(** Captures the current turtle state (pos and angle) into a RECORD **)
PROCEDURE GetState*(VAR s: State);
BEGIN
  s := cur;
END GetState;

(** Restores the turtle to a previously saved state **)
PROCEDURE RestoreState*(s: State);
BEGIN
  cur := s;
END RestoreState;

PROCEDURE Init*;
BEGIN
  Graphics.ClearBuf();
  cur.x := 120.0; cur.y := 50.0; cur.angle := 0.0;
  penDown := TRUE; penColor := 7;
END Init;

PROCEDURE SetColor*(c: INTEGER); BEGIN penColor := c END SetColor;
PROCEDURE PenUp*; BEGIN penDown := FALSE END PenUp;
PROCEDURE PenDown*; BEGIN penDown := TRUE END PenDown;
PROCEDURE Update*; BEGIN Graphics.Flush() END Update;

BEGIN
  Init;
END Turtle.