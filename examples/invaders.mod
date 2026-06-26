MODULE Invaders;

(*
 * Space Invaders — Raylib edition.
 *
 * Controls:
 *   Left / Right arrow : move ship
 *   Space              : fire
 *   Enter              : restart after game over / win
 *   Esc / close window : quit
 *)

IMPORT Raylib, Random, Strings;

CONST
  W = 800;  H = 600;
  ROWS = 5;  COLS = 11;
  NALIENS = 55;        (* ROWS * COLS *)

  CELL_W  = 55;  CELL_H  = 45;
  ALIEN_W = 36;  ALIEN_H = 28;

  GRID_X0   = 62;
  GRID_Y0   = 80;
  GRID_DROP = 20;

  PLAYER_W   = 44;  PLAYER_H = 20;
  PLAYER_Y   = 536;
  PLAYER_SPD = 280.0;

  PBUL_W   = 4;   PBUL_H   = 14;
  PBUL_SPD = 500.0;

  ABUL_W   = 5;  ABUL_H   = 12;
  ABUL_SPD = 180.0;
  MAX_ABUL = 3;

  ALIEN_SPD0    = 60.0;
  ABUL_INTERVAL = 1.5;

  PHASE_PLAY = 0;
  PHASE_OVER = 1;
  PHASE_WIN  = 2;

VAR
  cBlack, cWhite, cGreen, cRed, cYellow, cCyan, cMagenta : INTEGER;

  phase   : INTEGER;
  score   : INTEGER;
  lives   : INTEGER;

  playerX : REAL;

  pbActive : BOOLEAN;
  pbX, pbY : REAL;

  alienAlive : ARRAY NALIENS OF BOOLEAN;
  alienBaseX : REAL;
  alienBaseY : REAL;
  alienDX    : REAL;
  alienCount : INTEGER;

  abActive : ARRAY MAX_ABUL OF BOOLEAN;
  abX      : ARRAY MAX_ABUL OF REAL;
  abY      : ARRAY MAX_ABUL OF REAL;
  abTimer  : REAL;

  animTick  : INTEGER;
  animAccum : REAL;
  dt        : REAL;

  sndShoot   : Raylib.Sound;
  sndMarch0  : Raylib.Sound;
  sndMarch1  : Raylib.Sound;
  sndExplode : Raylib.Sound;

(* ── Index helpers ─────────────────────────────────────────── *)

PROCEDURE AlienRow(i : INTEGER) : INTEGER;
BEGIN RETURN i DIV COLS END AlienRow;

PROCEDURE AlienCol(i : INTEGER) : INTEGER;
BEGIN RETURN i MOD COLS END AlienCol;

PROCEDURE AlienCX(i : INTEGER) : REAL;
BEGIN
  RETURN alienBaseX + FLT(AlienCol(i) * CELL_W + CELL_W DIV 2)
END AlienCX;

PROCEDURE AlienCY(i : INTEGER) : REAL;
BEGIN
  RETURN alienBaseY + FLT(AlienRow(i) * CELL_H + CELL_H DIV 2)
END AlienCY;

(* ── Draw aliens (3 sprite types, 2-frame animation) ───────── *)

PROCEDURE DrawAlien(cx, cy : REAL; row, tick : INTEGER);
VAR x, y, hw, hh : INTEGER;
BEGIN
  x  := FLOOR(cx);  y  := FLOOR(cy);
  hw := ALIEN_W DIV 2;  hh := ALIEN_H DIV 2;

  IF row = 0 THEN
    (* top row: flying saucer *)
    Raylib.DrawEllipse(x, y, FLT(hw), FLT(hh) * 0.75, cMagenta);
    Raylib.DrawRectangle(x - hw + 8, y - hh - 2, ALIEN_W - 16, 6, cMagenta);
    IF tick = 0 THEN
      Raylib.DrawRectangle(x - hw,      y + hh - 4, 6, 8, cMagenta);
      Raylib.DrawRectangle(x - 4,       y + hh - 4, 8, 8, cMagenta);
      Raylib.DrawRectangle(x + hw - 6,  y + hh - 4, 6, 8, cMagenta)
    ELSE
      Raylib.DrawRectangle(x - hw + 4,  y + hh - 2, 6, 6, cMagenta);
      Raylib.DrawRectangle(x - 3,       y + hh - 2, 6, 6, cMagenta);
      Raylib.DrawRectangle(x + hw - 10, y + hh - 2, 6, 6, cMagenta)
    END

  ELSIF row < 3 THEN
    (* middle rows: crab *)
    Raylib.DrawRectangle(x - hw + 4, y - hh + 4, ALIEN_W - 8, ALIEN_H - 8, cCyan);
    Raylib.DrawRectangle(x - 8, y - 3, 6, 6, cBlack);
    Raylib.DrawRectangle(x + 2, y - 3, 6, 6, cBlack);
    IF tick = 0 THEN
      Raylib.DrawRectangle(x - hw,      y - hh,     6, 8, cCyan);
      Raylib.DrawRectangle(x + hw - 6,  y - hh,     6, 8, cCyan);
      Raylib.DrawRectangle(x - hw - 6,  y,           8, 6, cCyan);
      Raylib.DrawRectangle(x + hw - 2,  y,           8, 6, cCyan)
    ELSE
      Raylib.DrawRectangle(x - hw + 2,  y - hh - 4, 6, 8, cCyan);
      Raylib.DrawRectangle(x + hw - 8,  y - hh - 4, 6, 8, cCyan);
      Raylib.DrawRectangle(x - hw - 10, y + 2,       8, 6, cCyan);
      Raylib.DrawRectangle(x + hw + 2,  y + 2,       8, 6, cCyan)
    END

  ELSE
    (* bottom rows: simple bug *)
    Raylib.DrawRectangle(x - hw + 6, y - hh + 4, ALIEN_W - 12, ALIEN_H - 8, cGreen);
    Raylib.DrawRectangle(x - 7, y - 2, 5, 8, cBlack);
    Raylib.DrawRectangle(x + 2, y - 2, 5, 8, cBlack);
    IF tick = 0 THEN
      Raylib.DrawRectangle(x - hw,      y - 4, 10, 6, cGreen);
      Raylib.DrawRectangle(x + hw - 10, y - 4, 10, 6, cGreen);
      Raylib.DrawRectangle(x - hw + 2,  y + 6,  8, 6, cGreen);
      Raylib.DrawRectangle(x + hw - 10, y + 6,  8, 6, cGreen)
    ELSE
      Raylib.DrawRectangle(x - hw - 4,  y - 2, 10, 6, cGreen);
      Raylib.DrawRectangle(x + hw - 6,  y - 2, 10, 6, cGreen);
      Raylib.DrawRectangle(x - hw,      y + 8,  8, 5, cGreen);
      Raylib.DrawRectangle(x + hw - 8,  y + 8,  8, 5, cGreen)
    END
  END
END DrawAlien;

PROCEDURE DrawPlayer;
VAR cx, cy : INTEGER;
BEGIN
  cx := FLOOR(playerX);
  cy := PLAYER_Y;
  (* base *)
  Raylib.DrawRectangle(cx - PLAYER_W DIV 2, cy, PLAYER_W, PLAYER_H, cGreen);
  (* cannon *)
  Raylib.DrawRectangle(cx - 3, cy - 10, 6, 12, cGreen);
  (* feet *)
  Raylib.DrawRectangle(cx - PLAYER_W DIV 2 - 4, cy + PLAYER_H - 8, 10, 8, cGreen);
  Raylib.DrawRectangle(cx + PLAYER_W DIV 2 - 6, cy + PLAYER_H - 8, 10, 8, cGreen)
END DrawPlayer;

(* ── Axis-aligned rect overlap test ───────────────────────── *)

PROCEDURE Overlaps(ax, ay, aw, ah, bx, by, bw, bh : REAL) : BOOLEAN;
BEGIN
  RETURN (ax < bx + bw) & (ax + aw > bx) & (ay < by + bh) & (ay + ah > by)
END Overlaps;

(* ── Game init ─────────────────────────────────────────────── *)

PROCEDURE InitGame;
VAR i : INTEGER;
BEGIN
  phase      := PHASE_PLAY;
  score      := 0;
  lives      := 3;
  playerX    := FLT(W) / 2.0;
  pbActive   := FALSE;
  alienBaseX := FLT(GRID_X0);
  alienBaseY := FLT(GRID_Y0);
  alienDX    := ALIEN_SPD0;
  alienCount := NALIENS;
  FOR i := 0 TO NALIENS - 1 DO alienAlive[i] := TRUE END;
  FOR i := 0 TO MAX_ABUL - 1 DO abActive[i]  := FALSE END;
  abTimer   := ABUL_INTERVAL;
  animTick  := 0;
  animAccum := 0.0
END InitGame;

PROCEDURE AlienSpeed() : REAL;
VAR speed : REAL;
BEGIN
  speed := ALIEN_SPD0 + FLT(NALIENS - alienCount) * 3.0;
  IF alienDX < 0.0 THEN RETURN -speed ELSE RETURN speed END
END AlienSpeed;

(* ── Per-frame update ──────────────────────────────────────── *)

PROCEDURE Update;
VAR
  i, j, row, liveCol   : INTEGER;
  ax, ay, le, re       : REAL;
  found                : BOOLEAN;
BEGIN
  dt := Raylib.GetFrameTime();

  (* animate aliens *)
  animAccum := animAccum + dt;
  IF animAccum >= 0.5 THEN
    animAccum := animAccum - 0.5;
    animTick  := 1 - animTick;
    IF animTick = 0 THEN Raylib.PlaySound(sndMarch0)
    ELSE Raylib.PlaySound(sndMarch1) END
  END;

  (* move player *)
  IF Raylib.IsKeyDown(Raylib.KeyLeft) = 1 THEN
    playerX := playerX - PLAYER_SPD * dt;
    IF playerX < FLT(PLAYER_W DIV 2) THEN playerX := FLT(PLAYER_W DIV 2) END
  END;
  IF Raylib.IsKeyDown(Raylib.KeyRight) = 1 THEN
    playerX := playerX + PLAYER_SPD * dt;
    IF playerX > FLT(W - PLAYER_W DIV 2) THEN playerX := FLT(W - PLAYER_W DIV 2) END
  END;

  (* fire player bullet *)
  IF (Raylib.IsKeyPressed(Raylib.KeySpace) = 1) & ~pbActive THEN
    pbActive := TRUE;
    pbX      := playerX - FLT(PBUL_W DIV 2);
    pbY      := FLT(PLAYER_Y - PBUL_H);
    Raylib.PlaySound(sndShoot)
  END;

  (* move player bullet & check alien hits *)
  IF pbActive THEN
    pbY := pbY - PBUL_SPD * dt;
    IF pbY + FLT(PBUL_H) < 0.0 THEN
      pbActive := FALSE
    ELSE
      i := 0;
      WHILE (i < NALIENS) & pbActive DO
        IF alienAlive[i] THEN
          ax := AlienCX(i) - FLT(ALIEN_W DIV 2);
          ay := AlienCY(i) - FLT(ALIEN_H DIV 2);
          IF Overlaps(pbX, pbY, FLT(PBUL_W), FLT(PBUL_H),
                      ax, ay, FLT(ALIEN_W), FLT(ALIEN_H)) THEN
            alienAlive[i] := FALSE;
            pbActive      := FALSE;
            DEC(alienCount);
            Raylib.PlaySound(sndExplode);
            row := AlienRow(i);
            IF row = 0 THEN INC(score, 30)
            ELSIF row < 3 THEN INC(score, 20)
            ELSE INC(score, 10)
            END;
            IF alienCount = 0 THEN phase := PHASE_WIN END
          END
        END;
        INC(i)
      END
    END
  END;

  (* move alien grid horizontally *)
  alienBaseX := alienBaseX + AlienSpeed() * dt;

  (* find live bounding edges *)
  le :=  99999.0;  re := -99999.0;
  FOR i := 0 TO NALIENS - 1 DO
    IF alienAlive[i] THEN
      ax := AlienCX(i) - FLT(ALIEN_W DIV 2);
      IF ax < le THEN le := ax END;
      ax := ax + FLT(ALIEN_W);
      IF ax > re THEN re := ax END
    END
  END;

  (* reverse and drop when hitting a wall *)
  IF ((alienDX > 0.0) & (re >= FLT(W - 8))) OR
     ((alienDX < 0.0) & (le <= 8.0)) THEN
    alienDX    := -alienDX;
    alienBaseY := alienBaseY + FLT(GRID_DROP);
    FOR i := 0 TO NALIENS - 1 DO
      IF alienAlive[i] THEN
        ay := AlienCY(i) + FLT(ALIEN_H DIV 2);
        IF ay >= FLT(PLAYER_Y) THEN phase := PHASE_OVER END
      END
    END
  END;

  (* alien shooting *)
  abTimer := abTimer - dt;
  IF abTimer <= 0.0 THEN
    abTimer := ABUL_INTERVAL * (0.5 + Random.Real());
    liveCol := Random.Int(COLS);
    j       := -1;
    row     := ROWS - 1;
    WHILE (row >= 0) & (j < 0) DO
      i := row * COLS + liveCol;
      IF alienAlive[i] THEN j := i END;
      DEC(row)
    END;
    IF j < 0 THEN  (* column was empty — pick any live alien *)
      i := NALIENS - 1;
      WHILE (i >= 0) & (j < 0) DO
        IF alienAlive[i] THEN j := i END;
        DEC(i)
      END
    END;
    IF j >= 0 THEN
      found := FALSE;
      i     := 0;
      WHILE (i < MAX_ABUL) & ~found DO
        IF ~abActive[i] THEN
          found       := TRUE;
          abActive[i] := TRUE;
          abX[i]      := AlienCX(j) - FLT(ABUL_W DIV 2);
          abY[i]      := AlienCY(j) + FLT(ALIEN_H DIV 2)
        END;
        INC(i)
      END
    END
  END;

  (* move alien bullets & check player hit *)
  FOR i := 0 TO MAX_ABUL - 1 DO
    IF abActive[i] THEN
      abY[i] := abY[i] + ABUL_SPD * dt;
      IF abY[i] > FLT(H) THEN
        abActive[i] := FALSE
      ELSIF Overlaps(abX[i], abY[i], FLT(ABUL_W), FLT(ABUL_H),
                     playerX - FLT(PLAYER_W DIV 2), FLT(PLAYER_Y),
                     FLT(PLAYER_W), FLT(PLAYER_H)) THEN
        abActive[i] := FALSE;
        DEC(lives);
        IF lives <= 0 THEN phase := PHASE_OVER END
      END
    END
  END
END Update;

(* ── Per-frame draw ────────────────────────────────────────── *)

PROCEDURE Draw;
VAR
  i, tw : INTEGER;
  s, ns : ARRAY 32 OF CHAR;
BEGIN
  Raylib.BeginDrawing;
  Raylib.ClearBackground(cBlack);

  IF phase = PHASE_PLAY THEN
    DrawPlayer;

    FOR i := 0 TO NALIENS - 1 DO
      IF alienAlive[i] THEN
        DrawAlien(AlienCX(i), AlienCY(i), AlienRow(i), animTick)
      END
    END;

    IF pbActive THEN
      Raylib.DrawRectangle(FLOOR(pbX), FLOOR(pbY), PBUL_W, PBUL_H, cYellow)
    END;

    FOR i := 0 TO MAX_ABUL - 1 DO
      IF abActive[i] THEN
        Raylib.DrawRectangle(FLOOR(abX[i]), FLOOR(abY[i]), ABUL_W, ABUL_H, cRed)
      END
    END;

    Raylib.DrawLine(0, PLAYER_Y + PLAYER_H + 6, W, PLAYER_Y + PLAYER_H + 6, cGreen);

    (* title *)
    Raylib.DrawText("SPACE INVADERS", W DIV 2 - 130, 10, 24, cWhite);

    (* score *)
    s := "SCORE: ";
    Strings.IntToStr(score, ns);
    Strings.Append(ns, s);
    Raylib.DrawText(s, 10, 10, 20, cYellow);

    (* lives *)
    s := "LIVES: ";
    Strings.IntToStr(lives, ns);
    Strings.Append(ns, s);
    tw := Raylib.MeasureText(s, 20);
    Raylib.DrawText(s, W - tw - 10, 10, 20, cYellow)

  ELSIF phase = PHASE_WIN THEN
    s := "YOU WIN!";
    tw := Raylib.MeasureText(s, 52);
    Raylib.DrawText(s, W DIV 2 - tw DIV 2, H DIV 2 - 60, 52, cGreen);
    s := "SCORE: ";
    Strings.IntToStr(score, ns);
    Strings.Append(ns, s);
    tw := Raylib.MeasureText(s, 28);
    Raylib.DrawText(s, W DIV 2 - tw DIV 2, H DIV 2 + 10, 28, cYellow);
    s := "Press ENTER to play again";
    tw := Raylib.MeasureText(s, 22);
    Raylib.DrawText(s, W DIV 2 - tw DIV 2, H DIV 2 + 60, 22, cWhite)

  ELSE  (* PHASE_OVER *)
    s := "GAME OVER";
    tw := Raylib.MeasureText(s, 52);
    Raylib.DrawText(s, W DIV 2 - tw DIV 2, H DIV 2 - 60, 52, cRed);
    s := "SCORE: ";
    Strings.IntToStr(score, ns);
    Strings.Append(ns, s);
    tw := Raylib.MeasureText(s, 28);
    Raylib.DrawText(s, W DIV 2 - tw DIV 2, H DIV 2 + 10, 28, cYellow);
    s := "Press ENTER to play again";
    tw := Raylib.MeasureText(s, 22);
    Raylib.DrawText(s, W DIV 2 - tw DIV 2, H DIV 2 + 60, 22, cWhite)
  END;

  Raylib.EndDrawing
END Draw;

BEGIN
  cBlack   := Raylib.Black();
  cWhite   := Raylib.White();
  cGreen   := Raylib.Green();
  cRed     := Raylib.Red();
  cYellow  := Raylib.Yellow();
  cCyan    := Raylib.SkyBlue();
  cMagenta := Raylib.Magenta();

  Raylib.InitWindow(W, H, "Space Invaders");
  Raylib.SetTargetFPS(60);
  Raylib.InitAudioDevice;
  sndShoot   := Raylib.GenShootSound();
  sndMarch0  := Raylib.GenMarchSound(0);
  sndMarch1  := Raylib.GenMarchSound(1);
  sndExplode := Raylib.GenExplodeSound();
  InitGame;

  WHILE Raylib.WindowShouldClose() = 0 DO
    IF phase = PHASE_PLAY THEN
      Update
    ELSIF Raylib.IsKeyPressed(Raylib.KeyEnter) = 1 THEN
      InitGame
    END;
    Draw
  END;

  Raylib.UnloadSound(sndShoot);
  Raylib.UnloadSound(sndMarch0);
  Raylib.UnloadSound(sndMarch1);
  Raylib.UnloadSound(sndExplode);
  Raylib.CloseAudioDevice;
  Raylib.CloseWindow
END Invaders.
