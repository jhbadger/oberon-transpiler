MODULE shapes;

(*
  Demonstrates record inheritance, pointer allocation (NEW),
  the IS type test, and the WITH type guard.
*)

IMPORT Out;

TYPE
  ShapeRec  = RECORD
    color : ARRAY 16 OF CHAR;
  END;
  Shape = POINTER TO ShapeRec;

  CircleRec = RECORD (ShapeRec)
    radius : INTEGER;
  END;
  Circle = POINTER TO CircleRec;

  RectRec = RECORD (ShapeRec)
    width  : INTEGER;
    height : INTEGER;
  END;
  Rect = POINTER TO RectRec;


PROCEDURE Describe(s : Shape);
BEGIN
  Out.String("color="); Out.String(s.color); Out.String(" ");
  IF s IS CircleRec THEN
    WITH s : CircleRec DO
      Out.String("circle r="); Out.Int(s.radius, 0);
    END
  ELSIF s IS RectRec THEN
    WITH s : RectRec DO
      Out.String("rect "); Out.Int(s.width, 0);
      Out.String("x"); Out.Int(s.height, 0);
    END
  ELSE
    Out.String("unknown shape");
  END;
  Out.Ln;
END Describe;


VAR
  c : Circle;
  r : Rect;

BEGIN
  NEW(c); c.color := "red";  c.radius := 5;
  NEW(r); r.color := "blue"; r.width  := 10; r.height := 3;

  Describe(c);
  Describe(r);
END shapes.
