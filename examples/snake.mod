MODULE Snake;
(*
 * Snake — ring-buffer body, colour, WASD + arrow keys, speed scaling.
 *
 * Layout (80×24 terminal):
 *   border  : (2,2) .. (41,21)  — 40 wide, 20 tall
 *   grid    : (3,3) .. (40,20)  — 38 × 18 cells
 *   status  : row 23
 *
 * Controls: W A S D  or  arrow keys.   Esc = quit.
 *)

IMPORT Terminal, Graphics, Out;

CONST
  GW   = 38;   (* grid columns *)
  GH   = 18;   (* grid rows    *)
  MAXB = 700;  (* ring-buffer capacity *)

  Right = 0;  Down = 1;  Left = 2;  Up = 3;

  KUp    = 01X;  KDown  = 02X;
  KLeft  = 03X;  KRight = 04X;
  KEsc   = 1BX;

  OX = 3;  OY = 3;   (* grid origin in terminal coords *)
  BL = 2;  BT = 2;   (* border top-left                *)

VAR
  bx, by    : ARRAY MAXB OF INTEGER;  (* ring buffer   *)
  bhead     : INTEGER;                (* head index    *)
  blen      : INTEGER;                (* snake length  *)

  grid      : ARRAY GH, GW OF INTEGER; (* 0=empty 1=body 3=food *)

  fx, fy    : INTEGER;   (* food position     *)
  dir       : INTEGER;   (* current direction *)
  ndir      : INTEGER;   (* queued direction  *)
  score     : INTEGER;
  delay     : INTEGER;   (* ms per step       *)
  alive     : BOOLEAN;
  quitting  : BOOLEAN;

  last, now : LONGINT;
  i, j      : INTEGER;
  hx, hy    : INTEGER;
  nx, ny    : INTEGER;
  tidx      : INTEGER;
  eating    : BOOLEAN;
  key       : CHAR;
  headch    : CHAR;


(* ── Drawing helpers ──────────────────────────────────────────────── *)

PROCEDURE DrawBorder;
BEGIN
  Graphics.Color(6, 0);
  Graphics.Box(BL, BT, GW + 2, GH + 2);
  Graphics.Reset
END DrawBorder;

PROCEDURE DrawScore;
BEGIN
  Terminal.Goto(BL + 2, BT);
  Graphics.Color(3, 0);
  Out.String(" Score:");  Out.Int(score, 4);
  Out.String("  Lvl:");   Out.Int(score DIV 5 + 1, 2);
  Out.String("  WASD / arrows  Esc:quit ");
  Graphics.Reset
END DrawScore;

PROCEDURE HeadChar() : CHAR;
BEGIN
  IF    dir = Right THEN  RETURN '>'
  ELSIF dir = Down  THEN  RETURN 'v'
  ELSIF dir = Left  THEN  RETURN '<'
  ELSE                    RETURN '^'
  END
END HeadChar;

PROCEDURE DrawCell(x, y, kind : INTEGER);
BEGIN
  Terminal.Goto(OX + x, OY + y);
  IF    kind = 1 THEN  Graphics.Color(2, 0);  Out.Char('o')
  ELSIF kind = 2 THEN  Graphics.Color(3, 0);  Out.Char(HeadChar())
  ELSIF kind = 3 THEN  Graphics.Color(1, 0);  Out.Char('*')
  ELSE                 Graphics.Reset;        Out.Char(' ')
  END;
  Graphics.Reset
END DrawCell;

(* ── Food ─────────────────────────────────────────────────────────── *)

PROCEDURE PlaceFood;
BEGIN
  REPEAT
    fx := Terminal.Random(GW);
    fy := Terminal.Random(GH)
  UNTIL grid[fy][fx] = 0;
  grid[fy][fx] := 3;
  DrawCell(fx, fy, 3)
END PlaceFood;

(* ── Initialise ───────────────────────────────────────────────────── *)

PROCEDURE Init;
BEGIN
  FOR i := 0 TO GH - 1 DO
    FOR j := 0 TO GW - 1 DO  grid[i][j] := 0  END
  END;

  blen := 5;  bhead := 4;
  FOR i := 0 TO 4 DO
    bx[i] := GW DIV 2 - 4 + i;
    by[i] := GH DIV 2;
    grid[by[i]][bx[i]] := 1
  END;
  grid[by[4]][bx[4]] := 2;

  dir := Right;  ndir := Right;
  score := 0;  delay := 160;
  alive := TRUE;

  Terminal.Clear;
  DrawBorder;
  DrawScore;

  FOR i := 0 TO 3 DO  DrawCell(bx[i], by[i], 1)  END;
  DrawCell(bx[4], by[4], 2);
  PlaceFood;

  (* "Ready?" prompt — wait for first keypress *)
  Terminal.Goto(OX + GW DIV 2 - 10, OY + GH DIV 2 - 1);
  Graphics.Color(7, 0);
  Out.String("  Press any arrow key  ");
  Graphics.Reset;
  REPEAT  key := Terminal.ReadKey()
  UNTIL (key = KUp) OR (key = KDown) OR (key = KLeft) OR (key = KRight)
        OR (key = 'w') OR (key = 'a') OR (key = 's') OR (key = 'd');

  (* Erase prompt *)
  Terminal.Goto(OX + GW DIV 2 - 10, OY + GH DIV 2 - 1);
  Out.String("                       ");

  IF    key = KRight THEN  ndir := Right  ELSIF key = KDown  THEN  ndir := Down
  ELSIF key = KLeft  THEN  ndir := Left   ELSIF key = KUp    THEN  ndir := Up
  ELSIF key = 'd'    THEN  ndir := Right  ELSIF key = 's'    THEN  ndir := Down
  ELSIF key = 'a'    THEN  ndir := Left   ELSIF key = 'w'    THEN  ndir := Up
  END
END Init;

(* ── One step ─────────────────────────────────────────────────────── *)

PROCEDURE Step;
BEGIN
  hx := bx[bhead];  hy := by[bhead];

  (* Apply queued turn, prevent 180° *)
  IF    (ndir = Right) & (dir # Left)  THEN  dir := Right
  ELSIF (ndir = Down)  & (dir # Up)    THEN  dir := Down
  ELSIF (ndir = Left)  & (dir # Right) THEN  dir := Left
  ELSIF (ndir = Up)    & (dir # Down)  THEN  dir := Up
  END;

  nx := hx;  ny := hy;
  IF    dir = Right THEN  nx := nx + 1
  ELSIF dir = Down  THEN  ny := ny + 1
  ELSIF dir = Left  THEN  nx := nx - 1
  ELSE                    ny := ny - 1
  END;

  IF (nx < 0) OR (nx >= GW) OR (ny < 0) OR (ny >= GH) THEN
    alive := FALSE;  RETURN
  END;
  IF grid[ny][nx] = 1 THEN
    alive := FALSE;  RETURN
  END;

  eating := grid[ny][nx] = 3;

  (* Remove tail unless growing *)
  IF eating = FALSE THEN
    tidx := (bhead - blen + 1 + MAXB) MOD MAXB;
    grid[by[tidx]][bx[tidx]] := 0;
    DrawCell(bx[tidx], by[tidx], 0)
  END;

  (* Old head → body *)
  grid[hy][hx] := 1;
  DrawCell(hx, hy, 1);

  (* Advance ring to new head *)
  bhead := (bhead + 1) MOD MAXB;
  bx[bhead] := nx;  by[bhead] := ny;
  grid[ny][nx] := 2;
  DrawCell(nx, ny, 2);

  IF eating THEN
    blen  := blen + 1;
    score := score + 1;
    IF score MOD 5 = 0 THEN
      delay := delay - 12;
      IF delay < 50 THEN  delay := 50  END
    END;
    DrawScore;
    PlaceFood
  END
END Step;

(* ── Game-over screen ─────────────────────────────────────────────── *)

PROCEDURE GameOver;
VAR cx, cy : INTEGER;
BEGIN
  cx := OX + GW DIV 2 - 8;
  cy := OY + GH DIV 2 - 1;

  (* flash the crash point *)
  FOR i := 1 TO 8 DO
    Terminal.Goto(OX + bx[bhead], OY + by[bhead]);
    IF i MOD 2 = 0 THEN  Graphics.Color(1,0); Out.Char('X')
    ELSE                 Graphics.Color(7,0); Out.Char('+')
    END;
    Graphics.Reset;
    last := Terminal.GetTickCount() + 80;
    REPEAT  now := Terminal.GetTickCount()  UNTIL now >= last
  END;

  Terminal.Goto(cx, cy);
  Graphics.Color(1, 0);  Out.String("    GAME  OVER    ");
  Terminal.Goto(cx, cy + 1);
  Graphics.Color(3, 0);  Out.String("  Final score: ");  Out.Int(score, 0);
  Terminal.Goto(cx, cy + 3);
  Graphics.Color(7, 0);  Out.String("  [Y] again   [N] quit  ");
  Graphics.Reset;

  REPEAT  key := Terminal.ReadKey()
  UNTIL (key = 'y') OR (key = 'n') OR (key = KEsc);

  quitting := (key = 'n') OR (key = KEsc)
END GameOver;


(* ── Main ─────────────────────────────────────────────────────────── *)

BEGIN
  quitting := FALSE;
  WHILE quitting = FALSE DO
    Init;
    last := Terminal.GetTickCount();

    WHILE alive DO
      IF Terminal.KeyPressed() THEN
        key := Terminal.ReadKey();
        IF    key = KRight THEN  ndir := Right
        ELSIF key = KDown  THEN  ndir := Down
        ELSIF key = KLeft  THEN  ndir := Left
        ELSIF key = KUp    THEN  ndir := Up
        ELSIF key = 'd'    THEN  ndir := Right
        ELSIF key = 's'    THEN  ndir := Down
        ELSIF key = 'a'    THEN  ndir := Left
        ELSIF key = 'w'    THEN  ndir := Up
        ELSIF key = KEsc   THEN  alive := FALSE;  quitting := TRUE
        END
      END;
      now := Terminal.GetTickCount();
      IF now - last >= delay THEN
        last := now;
        Step
      END
    END;

    IF quitting = FALSE THEN  GameOver  END
  END;

  Terminal.Clear;
  Terminal.Goto(1, 1)
END Snake.
