MODULE Pacman;
(*
 * Pac-Man — Raylib edition.
 *
 * Controls:
 *   Arrow keys : move Pac-Man
 *   Enter      : restart after game over / win
 *   Esc        : quit
 *)

IMPORT Raylib, Strings, Math;

CONST
  W = 560;  H = 600;
  COLS = 21;  ROWS = 21;
  CELL = 24;
  OX = 28;   OY = 56;   (* maze pixel origin *)

  EMPTY  = 0;  DOT = 1;  WALL = 2;  PELLET = 3;

  RIGHT = 0;  DOWN = 1;  LEFT = 2;  UP = 3;  NONE = 4;

  CHASE = 0;  FRIGHTEN = 1;  EATEN = 2;

  NGHOST = 4;

  PAC_SPD      = 110.0;
  GHOST_SPD    = 80.0;
  FRIGHTEN_SPD = 55.0;
  FRIGHTEN_DUR = 8.0;
  EATEN_RESPAWN = 2.0;

  PHASE_PLAY  = 0;
  PHASE_OVER  = 1;
  PHASE_WIN   = 2;
  PHASE_READY = 3;
  READY_DUR   = 3.0;

VAR
  cBlack, cYellow, cWhite, cWall, cFright : INTEGER;
  cGhostCol : ARRAY NGHOST OF INTEGER;

  phase      : INTEGER;
  score      : INTEGER;
  lives      : INTEGER;
  dotLeft    : INTEGER;
  readyTimer : REAL;
  dt         : REAL;

  maze : ARRAY ROWS, COLS OF INTEGER;

  pacCol, pacRow : INTEGER;
  pacX,   pacY   : REAL;
  pacDir         : INTEGER;
  pacNextDir     : INTEGER;
  pacAnimTime    : REAL;

  gCol, gRow     : ARRAY NGHOST OF INTEGER;
  gX,   gY       : ARRAY NGHOST OF REAL;
  gDir           : ARRAY NGHOST OF INTEGER;
  gState         : ARRAY NGHOST OF INTEGER;
  gEatenTimer    : ARRAY NGHOST OF REAL;
  gSpawnC        : ARRAY NGHOST OF INTEGER;
  gSpawnR        : ARRAY NGHOST OF INTEGER;

  gFrightLeft : REAL;
  flashOn     : BOOLEAN;
  flashTimer  : REAL;

  sndEat : Raylib.Sound;
  sndDie : Raylib.Sound;

(* ── Helpers ─────────────────────────────────────────────── *)

PROCEDURE TileX(c : INTEGER) : REAL;
BEGIN RETURN FLT(OX + c * CELL + CELL DIV 2) END TileX;

PROCEDURE TileY(r : INTEGER) : REAL;
BEGIN RETURN FLT(OY + r * CELL + CELL DIV 2) END TileY;

PROCEDURE IsWall(c, r : INTEGER) : BOOLEAN;
BEGIN
  IF (c < 0) OR (c >= COLS) OR (r < 0) OR (r >= ROWS) THEN RETURN TRUE END;
  RETURN maze[r][c] = WALL
END IsWall;

PROCEDURE DC(d : INTEGER) : INTEGER;
BEGIN
  IF d = RIGHT THEN RETURN 1 ELSIF d = LEFT THEN RETURN -1 ELSE RETURN 0 END
END DC;

PROCEDURE DR(d : INTEGER) : INTEGER;
BEGIN
  IF d = DOWN THEN RETURN 1 ELSIF d = UP THEN RETURN -1 ELSE RETURN 0 END
END DR;

PROCEDURE Opp(d : INTEGER) : INTEGER;
BEGIN
  IF d = RIGHT THEN RETURN LEFT  ELSIF d = LEFT THEN RETURN RIGHT
  ELSIF d = UP  THEN RETURN DOWN ELSE RETURN UP
  END
END Opp;

PROCEDURE MDist(c1, r1, c2, r2 : INTEGER) : INTEGER;
VAR dc, dr : INTEGER;
BEGIN
  dc := c1 - c2;  IF dc < 0 THEN dc := -dc END;
  dr := r1 - r2;  IF dr < 0 THEN dr := -dr END;
  RETURN dc + dr
END MDist;

(* ── Maze init ───────────────────────────────────────────── *)

PROCEDURE SetRow(r : INTEGER; s : ARRAY OF CHAR);
VAR c : INTEGER;
BEGIN
  FOR c := 0 TO COLS - 1 DO
    IF    s[c] = '#' THEN maze[r][c] := WALL
    ELSIF s[c] = 'o' THEN maze[r][c] := PELLET;  INC(dotLeft)
    ELSIF s[c] = '.' THEN maze[r][c] := DOT;     INC(dotLeft)
    ELSE                   maze[r][c] := EMPTY
    END
  END
END SetRow;

PROCEDURE InitMaze;
BEGIN
  dotLeft := 0;
  SetRow( 0, "#####################");
  SetRow( 1, "#.........#.........#");
  SetRow( 2, "#.###.###.#.###.###.#");
  SetRow( 3, "#o###.###.#.###.###o#");
  SetRow( 4, "#.###.###.#.###.###.#");
  SetRow( 5, "#...................#");
  SetRow( 6, "#.###.#.#####.#.###.#");
  SetRow( 7, "#.#...#.......#...#.#");
  SetRow( 8, "#.#.###.#####.###.#.#");
  SetRow( 9, "#...#...........#...#");
  SetRow(10, "###.#.###.#.###.#.###");
  SetRow(11, "###.#.#.......#.#.###");
  SetRow(12, "###.#.###.#.###.#.###");
  SetRow(13, "#...#...........#...#");
  SetRow(14, "#.#.###.#####.###.#.#");
  SetRow(15, "#.#...#.......#...#.#");
  SetRow(16, "#.###.#.#####.#.###.#");
  SetRow(17, "#...................#");
  SetRow(18, "#.###.###.#.###.###.#");
  SetRow(19, "#o###.###.#.###.###o#");
  SetRow(20, "#####################")
END InitMaze;

PROCEDURE InitGame;
VAR i : INTEGER;
BEGIN
  InitMaze;
  score := 0;  lives := 3;
  phase := PHASE_READY;  readyTimer := READY_DUR;
  gFrightLeft := 0.0;  flashOn := FALSE;  flashTimer := 0.0;

  pacCol := 10;  pacRow := 17;
  pacX := TileX(10);  pacY := TileY(17);
  pacDir := NONE;  pacNextDir := NONE;
  pacAnimTime := 0.0;

  gSpawnC[0] :=  9;  gSpawnR[0] := 10;
  gSpawnC[1] := 11;  gSpawnR[1] := 10;
  gSpawnC[2] :=  9;  gSpawnR[2] := 11;
  gSpawnC[3] := 11;  gSpawnR[3] := 11;

  FOR i := 0 TO NGHOST - 1 DO
    gCol[i] := gSpawnC[i];
    gRow[i] := gSpawnR[i];
    gX[i]   := TileX(gCol[i]);
    gY[i]   := TileY(gRow[i]);
    gState[i] := CHASE;
    gEatenTimer[i] := 0.0
  END;
  gDir[0] := UP;   gDir[1] := DOWN;
  gDir[2] := LEFT; gDir[3] := RIGHT
END InitGame;

(* ── Pac-Man eating ──────────────────────────────────────── *)

PROCEDURE EatAt(col, row : INTEGER);
VAR j : INTEGER;
BEGIN
  IF phase # PHASE_PLAY THEN RETURN END;
  IF maze[row][col] = DOT THEN
    maze[row][col] := EMPTY;
    INC(score, 10);  DEC(dotLeft);
    Raylib.PlaySound(sndEat)
  ELSIF maze[row][col] = PELLET THEN
    maze[row][col] := EMPTY;
    INC(score, 50);  DEC(dotLeft);
    gFrightLeft := FRIGHTEN_DUR;
    FOR j := 0 TO NGHOST - 1 DO
      IF gState[j] # EATEN THEN gState[j] := FRIGHTEN END
    END;
    Raylib.PlaySound(sndEat)
  END;
  IF dotLeft <= 0 THEN phase := PHASE_WIN END
END EatAt;

(* ── Pac-Man movement ────────────────────────────────────── *)

PROCEDURE MovePac;
VAR
  nc, nr    : INTEGER;
  tx, ty, d : REAL;
BEGIN
  IF Raylib.IsKeyDown(Raylib.KeyRight) = 1 THEN pacNextDir := RIGHT END;
  IF Raylib.IsKeyDown(Raylib.KeyLeft)  = 1 THEN pacNextDir := LEFT  END;
  IF Raylib.IsKeyDown(Raylib.KeyDown)  = 1 THEN pacNextDir := DOWN  END;
  IF Raylib.IsKeyDown(Raylib.KeyUp)    = 1 THEN pacNextDir := UP    END;

  IF pacDir = NONE THEN
    IF pacNextDir # NONE THEN
      nc := pacCol + DC(pacNextDir);
      nr := pacRow + DR(pacNextDir);
      IF ~IsWall(nc, nr) THEN
        pacDir := pacNextDir;  pacNextDir := NONE
      END
    END;
    RETURN
  END;

  pacAnimTime := pacAnimTime + dt;

  pacX := pacX + FLT(DC(pacDir)) * PAC_SPD * dt;
  pacY := pacY + FLT(DR(pacDir)) * PAC_SPD * dt;

  nc := pacCol + DC(pacDir);
  nr := pacRow + DR(pacDir);
  tx := TileX(nc);  ty := TileY(nr);

  d := (pacX - tx) * FLT(DC(pacDir)) + (pacY - ty) * FLT(DR(pacDir));
  IF d >= 0.0 THEN
    pacX := tx;  pacY := ty;
    pacCol := nc;  pacRow := nr;
    EatAt(pacCol, pacRow);

    IF pacNextDir # NONE THEN
      nc := pacCol + DC(pacNextDir);
      nr := pacRow + DR(pacNextDir);
      IF ~IsWall(nc, nr) THEN
        pacDir := pacNextDir;  pacNextDir := NONE;
        RETURN
      END
    END;

    nc := pacCol + DC(pacDir);
    nr := pacRow + DR(pacDir);
    IF IsWall(nc, nr) THEN pacDir := NONE END
  END
END MovePac;

(* ── Ghost AI ────────────────────────────────────────────── *)

PROCEDURE ChooseGhostDir(i : INTEGER);
VAR
  d, best, bDist, dist : INTEGER;
  nc, nr, tc, tr       : INTEGER;
BEGIN
  IF gState[i] = EATEN THEN RETURN END;

  IF gState[i] = FRIGHTEN THEN
    tc := -99;  tr := -99
  ELSIF i = 1 THEN
    tc := pacCol + 4 * DC(pacDir);
    tr := pacRow + 4 * DR(pacDir)
  ELSIF (i = 3) & (MDist(gCol[i], gRow[i], pacCol, pacRow) <= 8) THEN
    tc := 0;  tr := 20
  ELSE
    tc := pacCol;  tr := pacRow
  END;

  best := -1;  bDist := -1;
  FOR d := 0 TO 3 DO
    IF d # Opp(gDir[i]) THEN
      nc := gCol[i] + DC(d);
      nr := gRow[i] + DR(d);
      IF ~IsWall(nc, nr) THEN
        IF gState[i] = FRIGHTEN THEN
          dist := MDist(nc, nr, pacCol, pacRow);
          IF (bDist < 0) OR (dist > bDist) THEN bDist := dist;  best := d END
        ELSE
          dist := MDist(nc, nr, tc, tr);
          IF (bDist < 0) OR (dist < bDist) THEN bDist := dist;  best := d END
        END
      END
    END
  END;

  IF best < 0 THEN
    d := Opp(gDir[i]);
    IF ~IsWall(gCol[i] + DC(d), gRow[i] + DR(d)) THEN best := d END
  END;

  IF best >= 0 THEN
    gDir[i] := best;
    gCol[i] := gCol[i] + DC(best);
    gRow[i] := gRow[i] + DR(best)
  END
END ChooseGhostDir;

PROCEDURE MoveGhost(i : INTEGER);
VAR
  tx, ty, d, spd : REAL;
BEGIN
  IF gState[i] = EATEN THEN RETURN END;

  IF gState[i] = FRIGHTEN THEN spd := FRIGHTEN_SPD ELSE spd := GHOST_SPD END;

  gX[i] := gX[i] + FLT(DC(gDir[i])) * spd * dt;
  gY[i] := gY[i] + FLT(DR(gDir[i])) * spd * dt;

  tx := TileX(gCol[i]);  ty := TileY(gRow[i]);
  d  := (gX[i] - tx) * FLT(DC(gDir[i])) + (gY[i] - ty) * FLT(DR(gDir[i]));

  IF d >= 0.0 THEN
    gX[i] := tx;  gY[i] := ty;
    ChooseGhostDir(i)
  END
END MoveGhost;

(* ── Collision ───────────────────────────────────────────── *)

PROCEDURE ResetPositions;
VAR j : INTEGER;
BEGIN
  pacCol := 10;  pacRow := 17;
  pacX := TileX(10);  pacY := TileY(17);
  pacDir := NONE;  pacNextDir := NONE;
  gFrightLeft := 0.0;
  FOR j := 0 TO NGHOST - 1 DO
    gCol[j] := gSpawnC[j];  gRow[j] := gSpawnR[j];
    gX[j] := TileX(gCol[j]);  gY[j] := TileY(gRow[j]);
    gState[j] := CHASE;  gEatenTimer[j] := 0.0
  END;
  gDir[0] := UP;   gDir[1] := DOWN;
  gDir[2] := LEFT; gDir[3] := RIGHT
END ResetPositions;

PROCEDURE CheckCollisions;
VAR
  i      : INTEGER;
  dx, dy : REAL;
BEGIN
  IF phase # PHASE_PLAY THEN RETURN END;
  FOR i := 0 TO NGHOST - 1 DO
    dx := pacX - gX[i];  IF dx < 0.0 THEN dx := -dx END;
    dy := pacY - gY[i];  IF dy < 0.0 THEN dy := -dy END;
    IF (dx < FLT(CELL) * 0.55) & (dy < FLT(CELL) * 0.55) THEN
      IF gState[i] = FRIGHTEN THEN
        gState[i] := EATEN;
        gEatenTimer[i] := EATEN_RESPAWN;
        INC(score, 200)
      ELSIF gState[i] = CHASE THEN
        DEC(lives);
        Raylib.PlaySound(sndDie);
        IF lives <= 0 THEN
          phase := PHASE_OVER
        ELSE
          phase := PHASE_READY;
          readyTimer := READY_DUR;
          ResetPositions
        END
      END
    END
  END
END CheckCollisions;

(* ── Update ──────────────────────────────────────────────── *)

PROCEDURE Update;
VAR i : INTEGER;
BEGIN
  dt := Raylib.GetFrameTime();

  IF phase = PHASE_READY THEN
    readyTimer := readyTimer - dt;
    IF readyTimer <= 0.0 THEN phase := PHASE_PLAY END;
    RETURN
  END;
  IF phase # PHASE_PLAY THEN RETURN END;

  MovePac;

  IF gFrightLeft > 0.0 THEN
    gFrightLeft := gFrightLeft - dt;
    flashTimer  := flashTimer  + dt;
    IF flashTimer >= 0.25 THEN flashTimer := 0.0;  flashOn := ~flashOn END;
    IF gFrightLeft <= 0.0 THEN
      gFrightLeft := 0.0;
      FOR i := 0 TO NGHOST - 1 DO
        IF gState[i] = FRIGHTEN THEN gState[i] := CHASE END
      END
    END
  END;

  FOR i := 0 TO NGHOST - 1 DO
    IF gState[i] = EATEN THEN
      gEatenTimer[i] := gEatenTimer[i] - dt;
      IF gEatenTimer[i] <= 0.0 THEN
        gState[i] := CHASE;
        gCol[i] := gSpawnC[i];  gRow[i] := gSpawnR[i];
        gX[i] := TileX(gCol[i]);  gY[i] := TileY(gRow[i]);
        gDir[i] := UP
      END
    ELSE
      MoveGhost(i)
    END
  END;

  CheckCollisions
END Update;

(* ── Drawing ─────────────────────────────────────────────── *)

PROCEDURE DrawMaze;
VAR
  r, c, px, py, cx, cy : INTEGER;
BEGIN
  FOR r := 0 TO ROWS - 1 DO
    FOR c := 0 TO COLS - 1 DO
      px := OX + c * CELL;
      py := OY + r * CELL;
      IF maze[r][c] = WALL THEN
        Raylib.DrawRectangle(px + 1, py + 1, CELL - 2, CELL - 2, cWall)
      ELSIF maze[r][c] = DOT THEN
        cx := px + CELL DIV 2;
        cy := py + CELL DIV 2;
        Raylib.DrawCircle(cx, cy, 2.0, cWhite)
      ELSIF maze[r][c] = PELLET THEN
        cx := px + CELL DIV 2;
        cy := py + CELL DIV 2;
        Raylib.DrawCircle(cx, cy, FLT(CELL DIV 4), cWhite)
      END
    END
  END
END DrawMaze;

PROCEDURE DrawPacman;
VAR
  cx, cy : INTEGER;
  r      : INTEGER;
  da, ma : REAL;
  x1, y1 : REAL;
  x2, y2 : REAL;
BEGIN
  cx := FLOOR(pacX);
  cy := FLOOR(pacY);
  r  := CELL DIV 2 - 1;

  IF    pacDir = RIGHT THEN da := 0.0
  ELSIF pacDir = DOWN  THEN da := Math.pi / 2.0
  ELSIF pacDir = LEFT  THEN da := Math.pi
  ELSE                      da := 3.0 * Math.pi / 2.0
  END;

  ma := 0.38 * Math.abs(Math.sin(pacAnimTime * 9.0));

  Raylib.DrawCircle(cx, cy, FLT(r), cYellow);

  IF ma > 0.04 THEN
    x1 := FLT(cx) + FLT(r) * Math.cos(da + ma);
    y1 := FLT(cy) + FLT(r) * Math.sin(da + ma);
    x2 := FLT(cx) + FLT(r) * Math.cos(da - ma);
    y2 := FLT(cy) + FLT(r) * Math.sin(da - ma);
    Raylib.DrawTriangle(FLT(cx), FLT(cy), x2, y2, x1, y1, cBlack)
  END
END DrawPacman;

PROCEDURE DrawGhost(i : INTEGER);
VAR
  cx, cy, r, hw : INTEGER;
  col           : INTEGER;
BEGIN
  cx := FLOOR(gX[i]);
  cy := FLOOR(gY[i]);
  r  := CELL DIV 2 - 1;
  hw := r;

  IF gState[i] = EATEN THEN
    Raylib.DrawCircle(cx - r DIV 3, cy - r DIV 4, FLT(r DIV 3 + 1), cWhite);
    Raylib.DrawCircle(cx + r DIV 3, cy - r DIV 4, FLT(r DIV 3 + 1), cWhite);
    Raylib.DrawCircle(cx - r DIV 3, cy - r DIV 4, FLT(r DIV 5 + 1), cBlack);
    Raylib.DrawCircle(cx + r DIV 3, cy - r DIV 4, FLT(r DIV 5 + 1), cBlack);
    RETURN
  END;

  IF gState[i] = FRIGHTEN THEN
    IF (gFrightLeft < 2.0) & flashOn THEN col := cWhite ELSE col := cFright END
  ELSE
    col := cGhostCol[i]
  END;

  Raylib.DrawCircle(cx, cy - r DIV 3, FLT(r), col);
  Raylib.DrawRectangle(cx - hw, cy - r DIV 3, hw * 2, r + r DIV 3, col);
  Raylib.DrawCircle(cx - hw DIV 2, cy + r DIV 2, FLT(r DIV 4 + 1), cBlack);
  Raylib.DrawCircle(cx,             cy + r DIV 2, FLT(r DIV 4 + 1), cBlack);
  Raylib.DrawCircle(cx + hw DIV 2, cy + r DIV 2, FLT(r DIV 4 + 1), cBlack);

  IF gState[i] # FRIGHTEN THEN
    Raylib.DrawCircle(cx - r DIV 3, cy - r DIV 3, FLT(r DIV 3 + 1), cWhite);
    Raylib.DrawCircle(cx + r DIV 3, cy - r DIV 3, FLT(r DIV 3 + 1), cWhite);
    Raylib.DrawCircle(cx - r DIV 3, cy - r DIV 3, FLT(r DIV 5 + 1), cBlack);
    Raylib.DrawCircle(cx + r DIV 3, cy - r DIV 3, FLT(r DIV 5 + 1), cBlack)
  END
END DrawGhost;

PROCEDURE DrawHUD;
VAR
  s, ns : ARRAY 32 OF CHAR;
  tw, i : INTEGER;
BEGIN
  s := "SCORE: ";
  Strings.IntToStr(score, ns);
  Strings.Append(ns, s);
  Raylib.DrawText(s, 10, 10, 20, cWhite);

  s := "LIVES: ";
  Strings.IntToStr(lives, ns);
  Strings.Append(ns, s);
  tw := Raylib.MeasureText(s, 20);
  Raylib.DrawText(s, W - tw - 10, 10, 20, cWhite);

  FOR i := 1 TO lives - 1 DO
    Raylib.DrawCircle(W - 20 - i * 18, 44, 7.0, cYellow)
  END
END DrawHUD;

PROCEDURE Draw;
VAR
  i, tw : INTEGER;
  s, ns : ARRAY 32 OF CHAR;
BEGIN
  Raylib.BeginDrawing;
  Raylib.ClearBackground(cBlack);
  DrawMaze;

  IF (phase = PHASE_PLAY) OR (phase = PHASE_READY) THEN
    DrawPacman;
    FOR i := 0 TO NGHOST - 1 DO DrawGhost(i) END;
    IF phase = PHASE_READY THEN
      s := "READY!";
      tw := Raylib.MeasureText(s, 28);
      Raylib.DrawText(s, W DIV 2 - tw DIV 2, OY + ROWS * CELL DIV 2 - 14, 28, cYellow)
    END

  ELSIF phase = PHASE_WIN THEN
    s := "YOU WIN!";
    tw := Raylib.MeasureText(s, 52);
    Raylib.DrawText(s, W DIV 2 - tw DIV 2, H DIV 2 - 50, 52, cYellow);
    s := "SCORE: ";
    Strings.IntToStr(score, ns);
    Strings.Append(ns, s);
    tw := Raylib.MeasureText(s, 26);
    Raylib.DrawText(s, W DIV 2 - tw DIV 2, H DIV 2 + 14, 26, cWhite);
    s := "Press ENTER to play again";
    tw := Raylib.MeasureText(s, 20);
    Raylib.DrawText(s, W DIV 2 - tw DIV 2, H DIV 2 + 54, 20, cWhite)

  ELSE
    s := "GAME OVER";
    tw := Raylib.MeasureText(s, 52);
    Raylib.DrawText(s, W DIV 2 - tw DIV 2, H DIV 2 - 50, 52, Raylib.Red());
    s := "SCORE: ";
    Strings.IntToStr(score, ns);
    Strings.Append(ns, s);
    tw := Raylib.MeasureText(s, 26);
    Raylib.DrawText(s, W DIV 2 - tw DIV 2, H DIV 2 + 14, 26, cWhite);
    s := "Press ENTER to play again";
    tw := Raylib.MeasureText(s, 20);
    Raylib.DrawText(s, W DIV 2 - tw DIV 2, H DIV 2 + 54, 20, cWhite)
  END;

  DrawHUD;
  Raylib.EndDrawing
END Draw;

BEGIN
  cBlack  := Raylib.Black();
  cYellow := Raylib.Yellow();
  cWhite  := Raylib.White();
  cWall   := Raylib.DarkBlue();
  cFright := Raylib.Blue();

  cGhostCol[0] := Raylib.Red();
  cGhostCol[1] := Raylib.Pink();
  cGhostCol[2] := Raylib.SkyBlue();
  cGhostCol[3] := Raylib.Orange();

  Raylib.InitWindow(W, H, "Pac-Man");
  Raylib.SetTargetFPS(60);
  Raylib.InitAudioDevice;
  sndEat := Raylib.GenShootSound();
  sndDie := Raylib.GenExplodeSound();

  InitGame;

  WHILE Raylib.WindowShouldClose() = 0 DO
    IF (phase = PHASE_OVER) OR (phase = PHASE_WIN) THEN
      IF Raylib.IsKeyPressed(Raylib.KeyEnter) = 1 THEN InitGame END
    ELSE
      Update
    END;
    Draw
  END;

  Raylib.UnloadSound(sndEat);
  Raylib.UnloadSound(sndDie);
  Raylib.CloseAudioDevice;
  Raylib.CloseWindow
END Pacman.
