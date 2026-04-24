MODULE Maze;

(* First-person wireframe maze — fits in a standard 80x24 terminal.
   Layout: 3D view cols 1-56, rows 1-20 | minimap cols 58-78 | HUD rows 22-23 *)

IMPORT Random, Terminal,  Out;

CONST
  MAZE_SIZE = 21;
  WALL      = '#';
  PATH      = '.';
  STOPCH    = 'E';
  MAX_DEPTH = 4;
  VIEW_W    = 56;   (* view area width  *)
  VIEW_H    = 20;   (* view area height *)
  MAP_COL   = 58;   (* minimap left column *)
  MAP_ROW   =  1;   (* minimap top row *)

VAR
  maze   : ARRAY MAZE_SIZE, MAZE_SIZE OF CHAR;
  seen   : ARRAY MAZE_SIZE, MAZE_SIZE OF BOOLEAN;
  px, py : INTEGER;
  pdir   : INTEGER;   (* 0=N  1=E  2=S  3=W *)
  ex, ey : INTEGER;
  key    : CHAR;
  won    : BOOLEAN;
  bslash : CHAR;      (* CHR(92) = '\' *)

(* ------------------------------------------------------------------ *)
(* Maze generation                                                      *)
(* ------------------------------------------------------------------ *)

PROCEDURE InitializeMaze;
VAR i, j : INTEGER;
BEGIN
  FOR i := 0 TO MAZE_SIZE-1 DO
    FOR j := 0 TO MAZE_SIZE-1 DO
      maze[i, j] := WALL;
      seen[i, j] := FALSE;
    END;
  END;
END InitializeMaze;

PROCEDURE IsValid(x, y : INTEGER) : BOOLEAN;
BEGIN
  RETURN (x > 0) & (x < MAZE_SIZE-1) & (y > 0) & (y < MAZE_SIZE-1)
       & (maze[y, x] = WALL);
END IsValid;

PROCEDURE GenerateMaze(x, y : INTEGER);
VAR k, r, temp, nx, ny, dx, dy : INTEGER;
    dirs : ARRAY 4 OF INTEGER;
BEGIN
  maze[y, x] := PATH;
  dirs[0] := 0; dirs[1] := 1; dirs[2] := 2; dirs[3] := 3;
  FOR k := 0 TO 3 DO
    r    := Random.Int(4);
    temp := dirs[k]; dirs[k] := dirs[r]; dirs[r] := temp;
  END;
  FOR k := 0 TO 3 DO
    dx := 0; dy := 0;
    IF    dirs[k] = 0 THEN dy := -2
    ELSIF dirs[k] = 1 THEN dy :=  2
    ELSIF dirs[k] = 2 THEN dx := -2
    ELSE                    dx :=  2
    END;
    nx := x + dx; ny := y + dy;
    IF IsValid(nx, ny) THEN
      maze[y + (dy DIV 2), x + (dx DIV 2)] := PATH;
      GenerateMaze(nx, ny);
    END;
  END;
END GenerateMaze;

(* ------------------------------------------------------------------ *)
(* Game helpers                                                         *)
(* ------------------------------------------------------------------ *)

PROCEDURE IsWall(x, y : INTEGER) : BOOLEAN;
BEGIN
  RETURN (x < 0) OR (x >= MAZE_SIZE) OR (y < 0) OR (y >= MAZE_SIZE)
       OR (maze[y, x] = WALL);
END IsWall;

PROCEDURE DirVecs(dir : INTEGER; VAR fdx, fdy, ldx, ldy : INTEGER);
BEGIN
  IF    dir = 0 THEN fdx :=  0; fdy := -1; ldx := -1; ldy :=  0
  ELSIF dir = 1 THEN fdx :=  1; fdy :=  0; ldx :=  0; ldy := -1
  ELSIF dir = 2 THEN fdx :=  0; fdy :=  1; ldx :=  1; ldy :=  0
  ELSE               fdx := -1; fdy :=  0; ldx :=  0; ldy :=  1
  END;
END DirVecs;

PROCEDURE MarkVisible;
VAR fdx, fdy, ldx, ldy, d, fx, fy : INTEGER;
BEGIN
  DirVecs(pdir, fdx, fdy, ldx, ldy);
  seen[py, px] := TRUE;
  IF px+1 < MAZE_SIZE THEN seen[py, px+1] := TRUE; END;
  IF px-1 >= 0        THEN seen[py, px-1] := TRUE; END;
  IF py+1 < MAZE_SIZE THEN seen[py+1, px] := TRUE; END;
  IF py-1 >= 0        THEN seen[py-1, px] := TRUE; END;
  d := 1;
  WHILE d <= MAX_DEPTH DO
    fx := px + fdx*d; fy := py + fdy*d;
    IF (fx >= 0) & (fx < MAZE_SIZE) & (fy >= 0) & (fy < MAZE_SIZE) THEN
      seen[fy, fx] := TRUE;
      IF (fx+ldx >= 0) & (fx+ldx < MAZE_SIZE) & (fy+ldy >= 0) & (fy+ldy < MAZE_SIZE) THEN
        seen[fy+ldy, fx+ldx] := TRUE;
      END;
      IF (fx-ldx >= 0) & (fx-ldx < MAZE_SIZE) & (fy-ldy >= 0) & (fy-ldy < MAZE_SIZE) THEN
        seen[fy-ldy, fx-ldx] := TRUE;
      END;
    END;
    IF IsWall(px+fdx*d, py+fdy*d) THEN d := MAX_DEPTH+1; ELSE INC(d); END;
  END;
END MarkVisible;

(* Perspective rectangles — vanishing point at centre of the view *)
PROCEDURE GetRect(d : INTEGER; VAR x1, y1, x2, y2 : INTEGER);
BEGIN
  IF    d = 0 THEN x1 :=  1; y1 :=  1; x2 := VIEW_W; y2 := VIEW_H
  ELSIF d = 1 THEN x1 :=  9; y1 :=  4; x2 := 48;     y2 := 17
  ELSIF d = 2 THEN x1 := 16; y1 :=  6; x2 := 41;     y2 := 14
  ELSIF d = 3 THEN x1 := 21; y1 :=  8; x2 := 36;     y2 := 12
  ELSE              x1 := 25; y1 :=  9; x2 := 32;     y2 := 11
  END;
END GetRect;

(* ------------------------------------------------------------------ *)
(* Drawing primitives (text-mode, 1-based terminal coords)             *)
(* ------------------------------------------------------------------ *)

PROCEDURE HLine(x1, x2, y : INTEGER; ch : CHAR);
VAR x : INTEGER;
BEGIN
  FOR x := x1 TO x2 DO Terminal.Goto(x, y); Out.Char(ch); END;
END HLine;

PROCEDURE VLine(x, y1, y2 : INTEGER; ch : CHAR);
VAR y : INTEGER;
BEGIN
  FOR y := y1 TO y2 DO Terminal.Goto(x, y); Out.Char(ch); END;
END VLine;

PROCEDURE DiagLine(x0, y0, x1, y1 : INTEGER; ch : CHAR);
VAR i, steps, x, y, dx, dy : INTEGER;
BEGIN
  dx := x1-x0; dy := y1-y0;
  IF ABS(dx) > ABS(dy) THEN steps := ABS(dx) ELSE steps := ABS(dy) END;
  IF steps = 0 THEN Terminal.Goto(x0, y0); Out.Char(ch); RETURN END;
  FOR i := 0 TO steps DO
    x := x0 + (dx*i) DIV steps;
    y := y0 + (dy*i) DIV steps;
    Terminal.Goto(x, y); Out.Char(ch);
  END;
END DiagLine;

PROCEDURE FillRect(x1, y1, x2, y2 : INTEGER; ch : CHAR);
VAR y : INTEGER;
BEGIN
  FOR y := y1 TO y2 DO HLine(x1, x2, y, ch); END;
END FillRect;

PROCEDURE WireRect(x1, y1, x2, y2 : INTEGER);
BEGIN
  HLine(x1+1, x2-1, y1, '-'); HLine(x1+1, x2-1, y2, '-');
  VLine(x1, y1+1, y2-1, '|'); VLine(x2, y1+1, y2-1, '|');
  Terminal.Goto(x1, y1); Out.Char('+');
  Terminal.Goto(x2, y1); Out.Char('+');
  Terminal.Goto(x1, y2); Out.Char('+');
  Terminal.Goto(x2, y2); Out.Char('+');
END WireRect;

(* ------------------------------------------------------------------ *)
(* Scene                                                                *)
(* ------------------------------------------------------------------ *)

PROCEDURE DrawScene;
VAR fdx, fdy, ldx, ldy    : INTEGER;
    d, fx, fy, maxd        : INTEGER;
    ax1, ay1, ax2, ay2     : INTEGER;
    bx1, by1, bx2, by2     : INTEGER;
    frontWall, leftWall, rightWall : BOOLEAN;
    mx, my                 : INTEGER;
BEGIN
  MarkVisible();
  DirVecs(pdir, fdx, fdy, ldx, ldy);
  Terminal.Clear();

  (* Floor dots in lower half of view *)
  Terminal.Color(3, 0);
  FillRect(2, VIEW_H DIV 2 + 1, VIEW_W-1, VIEW_H-1, '.');

  (* Find first front wall *)
  maxd := MAX_DEPTH;
  d := 1;
  WHILE d <= MAX_DEPTH DO
    IF IsWall(px + fdx*d, py + fdy*d) THEN
      maxd := d; d := MAX_DEPTH+1;
    ELSE
      INC(d);
    END;
  END;

  (* Render far-to-near *)
  d := maxd;
  WHILE d >= 1 DO
    fx := px + fdx*d; fy := py + fdy*d;
    frontWall := IsWall(fx, fy);
    leftWall  := IsWall(fx + ldx, fy + ldy);
    rightWall := IsWall(fx - ldx, fy - ldy);

    GetRect(d,   ax1, ay1, ax2, ay2);
    GetRect(d-1, bx1, by1, bx2, by2);

    (* Fill front wall solid, then outline *)
    IF frontWall THEN
      Terminal.Color(6, 0);
      FillRect(ax1+1, ay1+1, ax2-1, ay2-1, '#');
    END;

    Terminal.Color(7, 0);

    IF frontWall THEN WireRect(ax1, ay1, ax2, ay2); END;

    (* Perspective corner lines.
       Upper-left and lower-right slope '\'  (dx and dy same sign).
       Upper-right and lower-left slope '/'  (dx and dy opposite sign). *)
    DiagLine(bx1, by1, ax1, ay1, bslash);
    DiagLine(bx2, by1, ax2, ay1, '/');
    DiagLine(bx1, by2, ax1, ay2, '/');
    DiagLine(bx2, by2, ax2, ay2, bslash);

    (* Side wall edges *)
    IF leftWall THEN
      VLine(bx1, by1, by2, '|');
      VLine(ax1, ay1, ay2, '|');
    END;
    IF rightWall THEN
      VLine(bx2, by1, by2, '|');
      VLine(ax2, ay1, ay2, '|');
    END;

    DEC(d);
  END;

  (* Outer border *)
  Terminal.Color(7, 0);
  WireRect(1, 1, VIEW_W, VIEW_H);

  (* Minimap *)
  Terminal.Goto(MAP_COL, MAP_ROW); Out.String("    Minimap    ");
  FOR my := 0 TO MAZE_SIZE-1 DO
    Terminal.Goto(MAP_COL, MAP_ROW + 1 + my);
    FOR mx := 0 TO MAZE_SIZE-1 DO
      IF ~seen[my, mx] THEN
        Out.Char(' ');
      ELSIF (mx = px) & (my = py) THEN
        Terminal.Color(6, 0); Out.Char('@'); Terminal.Color(7, 0);
      ELSIF maze[my, mx] = WALL THEN
        Out.Char('#');
      ELSIF maze[my, mx] = STOPCH THEN
        Terminal.Color(2, 0); Out.Char('E'); Terminal.Color(7, 0);
      ELSE
        Out.Char(' ');
      END;
    END;
  END;

  (* HUD *)
  Terminal.Goto(1, VIEW_H+2);
  IF    pdir = 0 THEN Out.String("Facing: North")
  ELSIF pdir = 1 THEN Out.String("Facing: East ")
  ELSIF pdir = 2 THEN Out.String("Facing: South")
  ELSE                Out.String("Facing: West ")
  END;
  Terminal.Goto(1, VIEW_H+3);
  Out.String("Arrows: move / turn   Q: quit");
END DrawScene;

(* ------------------------------------------------------------------ *)
(* Movement                                                             *)
(* ------------------------------------------------------------------ *)

PROCEDURE MoveForward;
VAR fdx, fdy, ldx, ldy : INTEGER;
BEGIN
  DirVecs(pdir, fdx, fdy, ldx, ldy);
  IF ~IsWall(px+fdx, py+fdy) THEN px := px+fdx; py := py+fdy; END;
END MoveForward;

PROCEDURE MoveBackward;
VAR fdx, fdy, ldx, ldy : INTEGER;
BEGIN
  DirVecs(pdir, fdx, fdy, ldx, ldy);
  IF ~IsWall(px-fdx, py-fdy) THEN px := px-fdx; py := py-fdy; END;
END MoveBackward;

(* ------------------------------------------------------------------ *)
(* Main                                                                 *)
(* ------------------------------------------------------------------ *)

BEGIN
  bslash := CHR(92);

  Terminal.Clear();
  InitializeMaze();
  GenerateMaze(1, 1);

  ex := MAZE_SIZE-2; ey := MAZE_SIZE-2;
  maze[ey, ex] := STOPCH;

  px := 1; py := 1; pdir := 1;
  won := FALSE;

  DrawScene();

  WHILE ~won DO
    key := Terminal.ReadKey();
    IF (key = "q") OR (key = "Q") THEN
      won := TRUE;
    ELSIF key = 0A0X THEN               (* Up:    move forward  *)
      MoveForward();
    ELSIF key = 0A1X THEN               (* Down:  move backward *)
      MoveBackward();
    ELSIF key = 0A2X THEN               (* Left:  turn left     *)
      pdir := (pdir + 3) MOD 4;
    ELSIF key = 0A3X THEN               (* Right: turn right    *)
      pdir := (pdir + 1) MOD 4;
    END;

    IF maze[py, px] = STOPCH THEN
      won := TRUE;
      DrawScene();
      Terminal.Goto(1, VIEW_H+4);
      Terminal.Color(2, 0);
      Out.String("*** YOU FOUND THE EXIT! Congratulations! ***");
      Terminal.Reset();
      key := Terminal.ReadKey();
    ELSIF ~won THEN
      DrawScene();
    END;
  END;

  Terminal.Reset();
END Maze.

