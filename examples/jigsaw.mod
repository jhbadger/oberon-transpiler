MODULE Jigsaw;
(*
 * Mouse-driven jigsaw puzzle.
 * Usage: jigsaw <image.jpg> [approx-pieces]
 *
 * Left-click and drag pieces into the outlined grid.
 * Release near the correct slot to snap it into place.
 * Press R to reshuffle all pieces.
 * Press H to toggle the faint hint image.
 *)

IMPORT Raylib, Args, Strings, Random, Out;

CONST
  MAXPIECES = 400;
  WIN_W     = 1100;
  WIN_H     = 750;
  BORDER    = 60;   (* margin around the solved-image area *)

VAR
  imgTex         : Raylib.Texture;
  imgW, imgH     : INTEGER;
  nCols, nRows   : INTEGER;
  nPieces        : INTEGER;
  pieceW, pieceH : INTEGER;   (* source pixels per piece in the texture *)
  dispW, dispH   : INTEGER;   (* display size of the full solved image *)
  dispX, dispY   : INTEGER;   (* screen top-left of the solved-image area *)
  dPW, dPH       : INTEGER;   (* display pixels per piece *)

  pieceX, pieceY : ARRAY MAXPIECES OF REAL;
  placed         : ARRAY MAXPIECES OF BOOLEAN;
  drawOrd        : ARRAY MAXPIECES OF INTEGER;  (* back-to-front draw order *)

  isDragging     : BOOLEAN;
  dragOffX       : REAL;
  dragOffY       : REAL;

  solvedCount    : INTEGER;
  won            : BOOLEAN;
  showGhost      : BOOLEAN;

  cWhite     : INTEGER;
  cBlack     : INTEGER;
  cGray      : INTEGER;
  cDarkGray  : INTEGER;
  cLightGray : INTEGER;
  cGreen     : INTEGER;
  cYellow    : INTEGER;

  filename : ARRAY 256 OF CHAR;
  numStr   : ARRAY 32 OF CHAR;
  nTarget  : INTEGER;

(* ── Helpers ──────────────────────────────────────────────────────────────── *)

PROCEDURE PieceCol(p : INTEGER) : INTEGER;
BEGIN RETURN p MOD nCols END PieceCol;

PROCEDURE PieceRow(p : INTEGER) : INTEGER;
BEGIN RETURN p DIV nCols END PieceRow;

PROCEDURE TargetX(p : INTEGER) : REAL;
BEGIN RETURN FLT(dispX + PieceCol(p) * dPW) END TargetX;

PROCEDURE TargetY(p : INTEGER) : REAL;
BEGIN RETURN FLT(dispY + PieceRow(p) * dPH) END TargetY;

(* ── Grid setup ───────────────────────────────────────────────────────────── *)

PROCEDURE ComputeGrid(n : INTEGER);
VAR
  c, r, diff, best : INTEGER;
  aspect : REAL;
BEGIN
  aspect := FLT(imgW) / FLT(imgH);
  best   := 2000000000;
  nCols  := 1;
  nRows  := 1;
  FOR c := 1 TO 30 DO
    r    := FLOOR(FLT(c) / aspect + 0.5);
    IF r < 1 THEN r := 1 END;
    diff := c * r - n;
    IF diff < 0 THEN diff := -diff END;
    IF diff < best THEN
      best  := diff;
      nCols := c;
      nRows := r
    END
  END;
  WHILE nCols * nRows > MAXPIECES DO
    IF nCols >= nRows THEN DEC(nCols) ELSE DEC(nRows) END;
    IF nCols < 1 THEN nCols := 1 END;
    IF nRows < 1 THEN nRows := 1 END
  END;
  nPieces := nCols * nRows
END ComputeGrid;

PROCEDURE InitLayout;
VAR ratio : REAL;
    maxW, maxH : INTEGER;
BEGIN
  maxW  := WIN_W - 2 * BORDER;
  maxH  := WIN_H - 2 * BORDER;
  ratio := FLT(imgW) / FLT(imgH);
  IF FLT(maxW) / FLT(maxH) > ratio THEN
    dispH := maxH;
    dispW := FLOOR(FLT(dispH) * ratio)
  ELSE
    dispW := maxW;
    dispH := FLOOR(FLT(dispW) / ratio)
  END;
  dispX := (WIN_W - dispW) DIV 2;
  dispY := (WIN_H - dispH) DIV 2;
  dPW   := dispW DIV nCols;
  dPH   := dispH DIV nRows
END InitLayout;

(* ── Piece state ──────────────────────────────────────────────────────────── *)

PROCEDURE Scatter;
VAR i, j, tmp : INTEGER;
BEGIN
  FOR i := 0 TO nPieces - 1 DO
    drawOrd[i] := i;
    placed[i]  := FALSE;
    pieceX[i]  := FLT(Random.Int(WIN_W - dPW));
    pieceY[i]  := FLT(Random.Int(WIN_H - dPH))
  END;
  FOR i := nPieces - 1 TO 1 BY -1 DO
    j          := Random.Int(i + 1);
    tmp        := drawOrd[i];
    drawOrd[i] := drawOrd[j];
    drawOrd[j] := tmp
  END;
  isDragging  := FALSE;
  solvedCount := 0;
  won         := FALSE
END Scatter;

PROCEDURE BringToFront(k : INTEGER);
VAR i, tmp : INTEGER;
BEGIN
  tmp := drawOrd[k];
  FOR i := k TO nPieces - 2 DO
    drawOrd[i] := drawOrd[i + 1]
  END;
  drawOrd[nPieces - 1] := tmp
END BringToFront;

(* ── Update ───────────────────────────────────────────────────────────────── *)

PROCEDURE Update;
VAR
  mx, my, i, p    : INTEGER;
  px, py, tx, ty  : REAL;
  dx, dy          : REAL;
  snapX, snapY    : INTEGER;
BEGIN
  mx := Raylib.GetMouseX();
  my := Raylib.GetMouseY();

  IF isDragging THEN
    p         := drawOrd[nPieces - 1];
    pieceX[p] := FLT(mx) - dragOffX;
    pieceY[p] := FLT(my) - dragOffY;

    IF Raylib.IsMouseButtonReleased(Raylib.BtnLeft) = 1 THEN
      tx    := TargetX(p);
      ty    := TargetY(p);
      dx    := pieceX[p] - tx;  IF dx < 0.0 THEN dx := -dx END;
      dy    := pieceY[p] - ty;  IF dy < 0.0 THEN dy := -dy END;
      snapX := dPW DIV 3;
      snapY := dPH DIV 3;
      IF (dx < FLT(snapX)) & (dy < FLT(snapY)) THEN
        pieceX[p] := tx;
        pieceY[p] := ty;
        placed[p]  := TRUE;
        INC(solvedCount);
        IF solvedCount = nPieces THEN won := TRUE END
      END;
      isDragging := FALSE
    END;
    RETURN
  END;

  IF Raylib.IsKeyPressed(ORD('R')) = 1 THEN
    Scatter;
    RETURN
  END;

  IF Raylib.IsKeyPressed(ORD('H')) = 1 THEN
    showGhost := ~showGhost;
    RETURN
  END;

  IF ~won & (Raylib.IsMouseButtonPressed(Raylib.BtnLeft) = 1) THEN
    i := nPieces - 1;
    WHILE i >= 0 DO
      p := drawOrd[i];
      IF ~placed[p] THEN
        px := pieceX[p];
        py := pieceY[p];
        IF (FLT(mx) >= px) & (FLT(mx) < px + FLT(dPW)) &
           (FLT(my) >= py) & (FLT(my) < py + FLT(dPH)) THEN
          BringToFront(i);
          isDragging := TRUE;
          dragOffX   := FLT(mx) - px;
          dragOffY   := FLT(my) - py;
          i          := -1   (* signal break *)
        END
      END;
      DEC(i)
    END
  END
END Update;

(* ── Drawing ──────────────────────────────────────────────────────────────── *)

PROCEDURE DrawPiece(p : INTEGER; lifted : BOOLEAN);
VAR sx, sy, dx, dy, col : INTEGER;
BEGIN
  sx := PieceCol(p) * pieceW;
  sy := PieceRow(p) * pieceH;
  dx := FLOOR(pieceX[p]);
  dy := FLOOR(pieceY[p]);
  IF lifted THEN col := Raylib.Fade(cWhite, 0.88)
  ELSE            col := cWhite
  END;
  Raylib.DrawTexturePro(imgTex, sx, sy, pieceW, pieceH, dx, dy, dPW, dPH, col);
  IF placed[p] THEN
    Raylib.DrawRectangleLines(dx, dy, dPW, dPH, Raylib.Fade(cGreen, 0.55))
  ELSE
    Raylib.DrawRectangleLines(dx, dy, dPW, dPH, cDarkGray)
  END
END DrawPiece;

PROCEDURE Draw;
VAR
  i, p, tw : INTEGER;
  dragged  : INTEGER;
  s, ns    : ARRAY 80 OF CHAR;
BEGIN
  Raylib.BeginDrawing;
  Raylib.ClearBackground(cGray);

  (* Faint reference image in the solved area, when enabled *)
  IF showGhost THEN
    Raylib.DrawTexturePro(imgTex, 0, 0, imgW, imgH,
                          dispX, dispY, dispW, dispH,
                          Raylib.Fade(cWhite, 0.18))
  END;

  (* Grid guide lines *)
  FOR i := 0 TO nCols DO
    Raylib.DrawLine(dispX + i * dPW, dispY,
                    dispX + i * dPW, dispY + dispH,
                    Raylib.Fade(cLightGray, 0.4))
  END;
  FOR i := 0 TO nRows DO
    Raylib.DrawLine(dispX, dispY + i * dPH,
                    dispX + dispW, dispY + i * dPH,
                    Raylib.Fade(cLightGray, 0.4))
  END;
  Raylib.DrawRectangleLines(dispX - 2, dispY - 2, dispW + 4, dispH + 4, cLightGray);

  (* Placed pieces fill their slots first *)
  FOR i := 0 TO nPieces - 1 DO
    IF placed[drawOrd[i]] THEN DrawPiece(drawOrd[i], FALSE) END
  END;

  (* Free pieces back-to-front; dragged piece always on top *)
  IF isDragging THEN dragged := drawOrd[nPieces - 1]
  ELSE               dragged := -1
  END;
  FOR i := 0 TO nPieces - 1 DO
    p := drawOrd[i];
    IF ~placed[p] & (p # dragged) THEN DrawPiece(p, FALSE) END
  END;
  IF isDragging THEN DrawPiece(dragged, TRUE) END;

  (* HUD *)
  s := "Pieces: ";
  Strings.IntToStr(solvedCount, ns);
  Strings.Append(ns, s);
  Strings.Append(" / ", s);
  Strings.IntToStr(nPieces, ns);
  Strings.Append(ns, s);
  Raylib.DrawText(s, 10, 10, 20, cWhite);

  s := "R = reshuffle   H = hint";
  Raylib.DrawText(s, WIN_W - Raylib.MeasureText(s, 16) - 10, 10, 16,
                  Raylib.Fade(cWhite, 0.7));

  IF won THEN
    s  := "Puzzle Complete!";
    tw := Raylib.MeasureText(s, 52);
    Raylib.DrawRectangle((WIN_W - tw - 40) DIV 2, WIN_H DIV 2 - 60,
                         tw + 40, 110, Raylib.Fade(cBlack, 0.75));
    Raylib.DrawText(s, (WIN_W - tw) DIV 2, WIN_H DIV 2 - 46, 52, cYellow);
    s  := "Press R to reshuffle";
    tw := Raylib.MeasureText(s, 24);
    Raylib.DrawText(s, (WIN_W - tw) DIV 2, WIN_H DIV 2 + 16, 24, cWhite)
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

  IF Args.Count() < 1 THEN
    Out.String("Usage: jigsaw <image.jpg> [approx-pieces]");
    Out.Ln;
    RETURN
  END;

  Args.Get(1, filename);
  nTarget := 20;
  IF Args.Count() >= 2 THEN
    Args.Get(2, numStr);
    IF ~Strings.StrToInt(numStr, nTarget) THEN nTarget := 20 END
  END;
  IF nTarget < 1 THEN nTarget := 1 END;
  IF nTarget > MAXPIECES THEN nTarget := MAXPIECES END;

  Raylib.InitWindow(WIN_W, WIN_H, "Jigsaw Puzzle");
  Raylib.SetTargetFPS(60);

  imgTex := Raylib.LoadTexture(filename);
  imgW   := Raylib.TextureWidth(imgTex);
  imgH   := Raylib.TextureHeight(imgTex);

  IF (imgW <= 0) OR (imgH <= 0) THEN
    Out.String("Error: could not load image: ");
    Out.String(filename);
    Out.Ln;
    Raylib.CloseWindow;
    RETURN
  END;

  showGhost := FALSE;
  ComputeGrid(nTarget);
  pieceW := imgW DIV nCols;
  pieceH := imgH DIV nRows;
  InitLayout;
  Scatter;

  WHILE Raylib.WindowShouldClose() = 0 DO
    Update;
    Draw
  END;

  Raylib.UnloadTexture(imgTex);
  Raylib.CloseWindow
END Jigsaw.
