MODULE Slide16;
(*
 * Mouse-driven 4x4 sliding puzzle (15-puzzle).
 * Usage: slide16 [image.jpg|image.png]
 *
 * Click a tile adjacent to the empty space to slide it.
 * Press R to reshuffle.
 * Press S to save progress (number mode only).
 *)

IMPORT Raylib, Args, Strings, Random, Files, Out;

CONST
  WIN_W      = 600;
  WIN_H      = 720;
  N          = 4;
  N2         = N * N;   (* 16 *)
  BORDER     = 60;
  SAVE_MAGIC = 20260629;  (* bumped: format now includes imgFilename *)

VAR
  board      : ARRAY N2 OF INTEGER;  (* board[pos] = tile at that position; 0 = empty *)
  emptyPos   : INTEGER;              (* current position of the empty tile *)
  moves      : INTEGER;

  tileW, tileH : INTEGER;
  gridX, gridY : INTEGER;

  won          : BOOLEAN;
  showNumbers  : BOOLEAN;

  hasImage     : BOOLEAN;
  imgTex       : Raylib.Texture;
  imgW, imgH   : INTEGER;
  imgFilename  : ARRAY 256 OF CHAR;

  cWhite     : INTEGER;
  cBlack     : INTEGER;
  cGray      : INTEGER;
  cDarkGray  : INTEGER;
  cLightGray : INTEGER;
  cGreen     : INTEGER;
  cYellow    : INTEGER;
  cBlue      : INTEGER;

  numStr     : ARRAY 32 OF CHAR;
  saveMsgTimer : INTEGER;

(* ── Helpers ──────────────────────────────────────────────────────────────── *)

PROCEDURE PosToRow(p : INTEGER) : INTEGER;
BEGIN RETURN p DIV N END PosToRow;

PROCEDURE PosToCol(p : INTEGER) : INTEGER;
BEGIN RETURN p MOD N END PosToCol;

PROCEDURE TileX(p : INTEGER) : REAL;
BEGIN RETURN FLT(gridX + PosToCol(p) * tileW) END TileX;

PROCEDURE TileY(p : INTEGER) : REAL;
BEGIN RETURN FLT(gridY + PosToRow(p) * tileH) END TileY;

PROCEDURE IsAdjacent(a, b : INTEGER) : BOOLEAN;
VAR da, db : INTEGER;
BEGIN
  da := a - b;
  IF da < 0 THEN da := -da END;
  RETURN (da = 1) & (PosToRow(a) = PosToRow(b)) OR
         (da = N) & (PosToCol(a) = PosToCol(b))
END IsAdjacent;

PROCEDURE IsSolved() : BOOLEAN;
VAR i, v : INTEGER;
BEGIN
  FOR i := 0 TO N2 - 2 DO
    v := board[i];
    IF v # i + 1 THEN RETURN FALSE END
  END;
  RETURN board[N2 - 1] = 0
END IsSolved;

(* ── Grid setup ───────────────────────────────────────────────────────────── *)

PROCEDURE InitLayout;
VAR maxW, maxH, gap : INTEGER;
BEGIN
  gap := 4;
  maxW := WIN_W - 2 * BORDER;
  maxH := WIN_H - 2 * BORDER - 80;  (* leave room for HUD *)
  tileW := (maxW - gap * (N - 1)) DIV N;
  tileH := (maxH - gap * (N - 1)) DIV N;
  IF tileW > tileH THEN tileW := tileH ELSE tileH := tileW END;
  gridX := (WIN_W - N * tileW - (N - 1) * gap) DIV 2;
  gridY := (WIN_H - N * tileH - (N - 1) * gap) DIV 2 + 40
END InitLayout;

(* ── Shuffle ─────────────────────────────────────────────────────────────── *)

PROCEDURE Shuffle;
VAR i, j, tmp, k : INTEGER;
BEGIN
  FOR i := 0 TO N2 - 1 DO
    board[i] := i + 1
  END;
  board[N2 - 1] := 0;
  emptyPos := N2 - 1;

  (* Perform many random valid slides to guarantee solvability *)
  FOR k := 0 TO 500 DO
    (* find neighbors of emptyPos *)
    j := -1;
    IF PosToRow(emptyPos) > 0 THEN
      j := emptyPos - N  (* above *)
    ELSIF PosToRow(emptyPos) < N - 1 THEN
      j := emptyPos + N  (* below *)
    ELSIF PosToCol(emptyPos) > 0 THEN
      j := emptyPos - 1  (* left *)
    ELSE
      j := emptyPos + 1  (* right *)
    END;
    (* pick a random valid neighbor *)
    j := Random.Int(N2);
    WHILE ~IsAdjacent(emptyPos, j) DO
      j := Random.Int(N2)
    END;
    (* swap empty with neighbor *)
    tmp := board[emptyPos];
    board[emptyPos] := board[j];
    board[j] := tmp;
    emptyPos := j
  END;

  moves := 0;
  won := FALSE
END Shuffle;

(* ── Save / Load ─────────────────────────────────────────────────────────── *)

PROCEDURE SaveGame;
VAR f : Files.File;  r : Files.Rider;
    i : INTEGER;
BEGIN
  f := Files.New("slide16.sav");
  IF f = NIL THEN RETURN END;
  Files.Set(r, f, 0);
  Files.WriteInt(r, SAVE_MAGIC);
  Files.WriteString(r, imgFilename);
  FOR i := 0 TO N2 - 1 DO
    Files.WriteInt(r, board[i])
  END;
  Files.WriteInt(r, emptyPos);
  Files.WriteInt(r, moves);
  IF won       THEN Files.WriteInt(r, 1) ELSE Files.WriteInt(r, 0) END;
  IF showNumbers THEN Files.WriteInt(r, 1) ELSE Files.WriteInt(r, 0) END;
  Files.Register(f);
  Files.Close(f)
END SaveGame;

PROCEDURE LoadGame() : BOOLEAN;
VAR f : Files.File;  r : Files.Rider;
    n, i : INTEGER;
BEGIN
  f := Files.Old("slide16.sav");
  IF f = NIL THEN RETURN FALSE END;
  Files.Set(r, f, 0);
  Files.ReadInt(r, n);
  IF r.eof OR (n # SAVE_MAGIC) THEN Files.Close(f); RETURN FALSE END;
  Files.ReadString(r, imgFilename);
  hasImage := imgFilename[0] # 0X;
  FOR i := 0 TO N2 - 1 DO
    Files.ReadInt(r, board[i])
  END;
  Files.ReadInt(r, emptyPos);
  Files.ReadInt(r, moves);
  Files.ReadInt(r, n);  won       := n # 0;
  Files.ReadInt(r, n);  showNumbers := n # 0;
  Files.Close(f);
  RETURN TRUE
END LoadGame;

(* ── Update ───────────────────────────────────────────────────────────────── *)

PROCEDURE Update;
VAR
  mx, my, i, p, tmp : INTEGER;
  tx, ty            : REAL;
BEGIN
  mx := Raylib.GetMouseX();
  my := Raylib.GetMouseY();

  IF Raylib.IsKeyPressed(ORD('R')) = 1 THEN
    Shuffle;
    RETURN
  END;
  
  IF Raylib.IsKeyPressed(ORD('S')) = 1 THEN
    SaveGame;
    saveMsgTimer := 120;
    RETURN
  END;

  IF ~won & (Raylib.IsMouseButtonPressed(Raylib.BtnLeft) = 1) THEN
    (* find clicked tile *)
    i := 0;
    WHILE i < N2 DO
      tx := TileX(i);
      ty := TileY(i);
      IF (FLT(mx) >= tx) & (FLT(mx) < tx + FLT(tileW)) &
         (FLT(my) >= ty) & (FLT(my) < ty + FLT(tileH)) THEN
        p := i;
        IF board[p] # 0 THEN  (* clicked a numbered tile *)
          IF IsAdjacent(p, emptyPos) THEN
            (* slide: swap tile with empty *)
            tmp := board[emptyPos];
            board[emptyPos] := board[p];
            board[p] := tmp;
            emptyPos := p;
            INC(moves);
            IF IsSolved() THEN won := TRUE END;
            RETURN
          END
        END;
        RETURN
      END;
      INC(i)
    END
  END;

  IF saveMsgTimer > 0 THEN DEC(saveMsgTimer) END
END Update;

(* ── Drawing ──────────────────────────────────────────────────────────────── *)

PROCEDURE DrawTile(p : INTEGER);
VAR
  tile, x, y, tw, th, fs : INTEGER;
  col, tileRow, tileCol, sx, sy, sw, sh : INTEGER;
BEGIN
  tile := board[p];
  x    := FLOOR(TileX(p));
  y    := FLOOR(TileY(p));
  tw   := tileW;
  th   := tileH;

  IF tile = 0 THEN
    (* empty slot *)
    Raylib.DrawRectangle(x, y, tw, th, Raylib.Fade(cDarkGray, 0.6));
    Raylib.DrawRectangleLines(x, y, tw, th, Raylib.Fade(cLightGray, 0.25));
    RETURN
  END;

  IF hasImage THEN
    tileRow := (tile - 1) DIV N;
    tileCol := (tile - 1) MOD N;
    sx := tileCol * (imgW DIV N);
    sy := tileRow * (imgH DIV N);
    sw := imgW DIV N;
    sh := imgH DIV N;
    Raylib.DrawTexturePro(imgTex, sx, sy, sw, sh, x, y, tw, th, cWhite);
    Raylib.DrawRectangleLines(x, y, tw, th, Raylib.Fade(cWhite, 0.3))
  ELSE
    (* tile color: slightly different shade per tile for visual variety *)
    col := Raylib.Fade(cBlue, 0.35 + 0.02 * FLT(tile));
    Raylib.DrawRectangle(x, y, tw, th, col);
    Raylib.DrawRectangleLines(x, y, tw, th, cWhite);

    (* tile number *)
    IF showNumbers THEN
      Strings.IntToStr(tile, numStr);
      fs := FLOOR(FLT(tileW) * 0.45);
      Raylib.DrawText(numStr, x + (tw - Raylib.MeasureText(numStr, fs)) DIV 2,
                      y + (th - fs) DIV 2, fs, cWhite)
    END
  END
END DrawTile;

PROCEDURE Draw;
VAR
  i, tw : INTEGER;
  s : ARRAY 80 OF CHAR;
BEGIN
  Raylib.BeginDrawing;
  Raylib.ClearBackground(cGray);

  (* grid background *)
  Raylib.DrawRectangle(gridX - 4, gridY - 4,
                       N * tileW + (N - 1) * 4 + 8,
                       N * tileH + (N - 1) * 4 + 8,
                       Raylib.Fade(cDarkGray, 0.5));

  (* draw tiles *)
  FOR i := 0 TO N2 - 1 DO
    DrawTile(i)
  END;

  (* HUD *)
  s := "Moves: ";
  Strings.IntToStr(moves, numStr);
  Strings.Append(numStr, s);
  Raylib.DrawText(s, 10, 10, 18, cWhite);

  s := "R = reshuffle  S = save";
  Raylib.DrawText(s, WIN_W - Raylib.MeasureText(s, 14) - 10, 10, 14,
                  Raylib.Fade(cWhite, 0.6));

  IF saveMsgTimer > 0 THEN
    s := "Saved!";
    tw := Raylib.MeasureText(s, 20);
    Raylib.DrawText(s, (WIN_W - tw) DIV 2, WIN_H - 36, 20, cGreen);
  END;

  IF won THEN
    s  := "Puzzle Solved!";
    tw := Raylib.MeasureText(s, 48);
    Raylib.DrawRectangle((WIN_W - tw - 40) DIV 2, WIN_H DIV 2 - 60,
                         tw + 40, 110, Raylib.Fade(cBlack, 0.75));
    Raylib.DrawText(s, (WIN_W - tw) DIV 2, WIN_H DIV 2 - 46, 48, cYellow);
    s  := "Moves: ";
    Strings.IntToStr(moves, numStr);
    Strings.Append(numStr, s);
    tw := Raylib.MeasureText(s, 24);
    Raylib.DrawText(s, (WIN_W - tw) DIV 2, WIN_H DIV 2 + 16, 24, cWhite);
    s  := "Press R to play again";
    tw := Raylib.MeasureText(s, 18);
    Raylib.DrawText(s, (WIN_W - tw) DIV 2, WIN_H DIV 2 + 50, 18, cLightGray)
  END;

  Raylib.EndDrawing
END Draw;

(* ── Main ─────────────────────────────────────────────────────────────────── *)

BEGIN
  cWhite     := Raylib.White();
  cBlack     := Raylib.Black();
  cGray      := Raylib.Gray();
  cDarkGray  := Raylib.DarkGray();
  cLightGray := Raylib.LightGray();
  cGreen     := Raylib.Green();
  cYellow    := Raylib.Yellow();
  cBlue      := Raylib.Blue();

  IF Args.Count() >= 1 THEN
    Args.Get(1, imgFilename);
    hasImage := TRUE
  ELSE
    imgFilename := "";
    hasImage    := FALSE
  END;

  saveMsgTimer := 0;
  moves        := 0;
  won          := FALSE;
  showNumbers  := TRUE;

  InitLayout;

  IF hasImage THEN
    Shuffle
  ELSIF ~LoadGame() THEN
    Shuffle
  END;

  Raylib.InitWindow(WIN_W, WIN_H, "Sliding Puzzle 4x4");
  Raylib.SetTargetFPS(60);

  IF hasImage THEN
    imgTex := Raylib.LoadTexture(imgFilename);
    imgW   := Raylib.TextureWidth(imgTex);
    imgH   := Raylib.TextureHeight(imgTex);
    IF (imgW <= 0) OR (imgH <= 0) THEN
      Out.String("Error: could not load image: ");
      Out.String(imgFilename);
      Out.Ln;
      Raylib.CloseWindow;
      RETURN
    END
  END;

  WHILE Raylib.WindowShouldClose() = 0 DO
    Update;
    Draw
  END;

  IF hasImage THEN Raylib.UnloadTexture(imgTex) END;
  Raylib.CloseWindow
END Slide16.



