MODULE SnakeGame;

IMPORT Out, In, Terminal, Strings; (* Terminal is a common abstraction for CRT *)

CONST
  KeyUp    = 01X;
  KeyDown  = 02X;
  KeyLeft  = 03X;
  KeyRight = 04X;
  KeyEnter = 0DX;
  KeyEsc   = 1BX;

VAR
  body, head, goc, wcc: CHAR;
  c, cc: CHAR;
  fx, fy: INTEGER;
  nr, nd1, k1: INTEGER;
  b, finish: BOOLEAN;
  i, j, k, x, y, cx, cy, cxp, cyp, nd2, ndp, s, slength, count: INTEGER;
  m: ARRAY 17, 62 OF CHAR;
  tx, ty: ARRAY 827 OF INTEGER;

PROCEDURE WriteIn(x1, y1: INTEGER; s1: ARRAY OF CHAR);
BEGIN
  Terminal.Goto(x1, y1);
  Out.String(s1)
END WriteIn;

PROCEDURE WriteChar(x1, y1: INTEGER; ch: CHAR);
BEGIN
  Terminal.Goto(x1, y1);
  Out.Char(ch)
END WriteChar;

PROCEDURE Delay(time: INTEGER);
VAR timer: LONGINT;
BEGIN
  timer := Terminal.GetTickCount() + time;
  REPEAT UNTIL Terminal.GetTickCount() >= timer
END Delay;

PROCEDURE Initialisations;
BEGIN
  nd1 := 1; nd2 := 370; ndp := 120; nr := 3
END Initialisations;

PROCEDURE Limits;
VAR i, k: INTEGER;
BEGIN
  Terminal.Clear;
  FOR k := 0 TO 16 DO
			 FOR i := 0 TO 61 DO
						m[k, i] := " "
			 END
  END;
  FOR i := 1 TO 61 DO
			 m[1, i] := "#"
	END;
  FOR i := 2 TO 16 DO
			 m[i, 1] := "#"
	END;
  FOR i := 2 TO 61 DO
			 m[16, i] := "#"
	END;
  FOR i := 2 TO 15 DO
			 m[i, 61] := "#"
	END;
  body := "O"; head := "@";
  FOR i := 3 TO 6 DO
			 m[8, i] := body
	END;
  m[8, 7] := head
END Limits;

PROCEDURE Display;
VAR i, k, j: INTEGER;
BEGIN
  j := 5;
  FOR k := 1 TO 16 DO
    j := j + 1;
    Terminal.Goto(10, j);
    FOR i := 1 TO 61 DO Out.Char(m[k, i]) END
  END
END Display;

PROCEDURE Food;
BEGIN
  REPEAT
    fy := Terminal.Random(13) + 2;
    fx := Terminal.Random(58) + 2
  UNTIL m[fy, fx] = " ";
  m[fy, fx] := "+";
  WriteChar(fx + 9, fy + 4, "+")
END Food;

PROCEDURE MoveBody;
BEGIN
  count := count + 1;
  m[ty[count], tx[count]] := " ";
  WriteChar(tx[count] + 9, ty[count] + 4, " ");
  ty[count] := y;
  tx[count] := x;
  IF count = slength THEN count := 0 END
END MoveBody;

PROCEDURE MoveSnake(nox, noy: INTEGER);
BEGIN
  x := x + nox; y := y + noy;
  MoveBody;
  m[y, x] := head;
  WriteChar(x + 9, y + 4, head);
  m[y - noy, x - nox] := body;
  WriteChar(x + 9 - nox, y + 4 - noy, body)
END MoveSnake;

PROCEDURE InWallOrHimself(): BOOLEAN;
VAR res: BOOLEAN;
    nx, ny: INTEGER;
BEGIN
  nx := 0; ny := 0;
  IF c = KeyRight THEN nx := 1 ELSIF c = KeyLeft THEN nx := -1
  ELSIF c = KeyUp THEN ny := -1 ELSIF c = KeyDown THEN ny := 1 END;
  
  IF (m[y + ny, x + nx] = "#") OR (m[y + ny, x + nx] = body) THEN
    res := TRUE
  ELSE
    res := FALSE
  END;
  RETURN res
END InWallOrHimself;

PROCEDURE Walk;
BEGIN
  IF c = KeyRight THEN MoveSnake(1, 0)
  ELSIF c = KeyLeft THEN MoveSnake(-1, 0)
  ELSIF c = KeyUp THEN MoveSnake(0, -1)
  ELSIF c = KeyDown THEN MoveSnake(0, 1)
  END;
  cc := c;
  IF Terminal.KeyPressed() THEN
    c := Terminal.ReadKey();
    IF (c # KeyUp) & (c # KeyDown) & (c # KeyLeft) & (c # KeyRight) & (c # "p") & (c # KeyEsc) THEN
      c := cc
    END;
    (* Directional Lock Logic *)
    IF (c = KeyRight) & (cc = KeyLeft) THEN c := cc END;
    IF (c = KeyLeft) & (cc = KeyRight) THEN c := cc END;
    IF (c = KeyUp) & (cc = KeyDown) THEN c := cc END;
    IF (c = KeyDown) & (cc = KeyUp) THEN c := cc END
  END;
  Delay(ndp)
END Walk;

PROCEDURE Score;
BEGIN
  s := s + nr + 1;
  Terminal.Goto(30, 2); Out.Int(s, 4);
  Terminal.Goto(59, 2); Out.Int(slength, 3)
END Score;

PROCEDURE GameOver;
BEGIN
  FOR i := 1 TO 9 DO
    WriteChar(x+9, y+4, "-"); Delay(25);
    WriteChar(x+9, y+4, "*"); Delay(25);
    WriteChar(x+9, y+4, "|"); Delay(25);
    WriteChar(x+9, y+4, "/"); Delay(25)
  END;
  WriteChar(x+9, y+4, "X");
  Delay(730);
  WriteIn(36, 11, "Game Over");
  WriteIn(33, 13, "Your score : ");
  Out.Int(s, 0);
  WriteIn(32, 14, "Replay? (Y/N)...< >");
  REPEAT Terminal.Goto(49, 14); goc := Terminal.ReadKey() UNTIL (goc = "y") OR (goc = "n")
END GameOver;

PROCEDURE Start;
BEGIN
  slength := 5; count := 0; s := 0; x := 7; y := 8; k := 3;
  FOR i := 1 TO slength DO tx[i] := k; ty[i] := 8; k := k + 1 END;
  WriteIn(22, 2, "Score : 0000");
  WriteIn(44, 2, "Snake length : 005");
  c := KeyRight;
  REPEAT
    WriteIn(24, 12, "Press any arrow key to start...");
    Delay(500);
    WriteIn(24, 12, "                                ");
    Delay(500);
    IF Terminal.KeyPressed() THEN c := Terminal.ReadKey() END
  UNTIL (c = KeyUp) OR (c = KeyDown) OR (c = KeyLeft) OR (c = KeyRight);
  c := KeyRight
END Start;

PROCEDURE FoodEaten(): BOOLEAN;
VAR i, k: INTEGER; eaten: BOOLEAN;
BEGIN
  eaten := TRUE;
  FOR k := 2 TO 15 DO
    FOR i := 2 TO 60 DO IF m[k, i] = "+" THEN eaten := FALSE END END
  END;
  RETURN eaten
END FoodEaten;

PROCEDURE RunGame(): BOOLEAN;
VAR restart: BOOLEAN;
BEGIN
  Limits; Display; Food; Start; Display;
  LOOP
    Walk;
    IF FoodEaten() THEN Food; slength := slength + 1; Score END;
    IF InWallOrHimself() THEN
      GameOver;
      IF goc = "y" THEN restart := TRUE ELSE restart := FALSE END;
      EXIT
    END
  END;
  RETURN restart
END RunGame;

BEGIN
  Initialisations;
  WHILE RunGame() DO END
END SnakeGame.
