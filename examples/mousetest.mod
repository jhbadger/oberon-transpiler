MODULE mousetest;
(*
 * Demonstrates mouse event handling.
 * Click anywhere; press 'q' to quit.
 *)
IMPORT Terminal, Out;

VAR
  key        : CHAR;
  x, y, btn : INTEGER;
  running    : BOOLEAN;

BEGIN
  Terminal.Clear();
  Terminal.MouseOn();
  Terminal.Goto(1, 1);
  Out.String("Click anywhere — press q to quit");

  running := TRUE;
  WHILE running DO
    key := Terminal.ReadKey();

    IF key = 05X THEN          (* mouse event *)
      x   := Terminal.MouseX();
      y   := Terminal.MouseY();
      btn := Terminal.MouseBtn();
      Terminal.Goto(1, 3);
      IF btn = 0 THEN Out.String("Left press   ")
      ELSIF btn = 1 THEN Out.String("Middle press ")
      ELSIF btn = 2 THEN Out.String("Right press  ")
      ELSIF btn = 3 THEN Out.String("Release      ")
      ELSIF btn = 64 THEN Out.String("Wheel up     ")
      ELSIF btn = 65 THEN Out.String("Wheel down   ")
      ELSE Out.String("Other        ")
      END;
      Out.String(" at (");
      Out.Int(x); Out.String(", "); Out.Int(y); Out.String(")   ")

    ELSIF key = 'q' THEN
      running := FALSE
    END
  END;

  Terminal.MouseOff();
  Terminal.Clear();
  Terminal.Goto(1,1)
END mousetest.
