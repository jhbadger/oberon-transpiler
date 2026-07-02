MODULE Mahjong;
(*
 * Solitaire Mahjong (Shanghai) using PDF page thumbnails as tiles.
 * Usage: mahjong <file.pdf> [num-types]
 *
 * num-types unique PDF pages are chosen at random; each appears 4 times.
 * Supported sizes: 9 (36 tiles), 12 (48 tiles), 18 (72 tiles, default).
 * Values in-between snap down; values above 18 clamp to 18.
 * Errors if the PDF has fewer pages than unique types needed.
 *
 * A tile is FREE when nothing sits on top AND at least one side is clear.
 * Click two free tiles with the same page to remove them.
 * R = new game (new random pages),  U = undo last pair.
 *)

IMPORT Raylib, Args, Strings, Random, Out;

CONST
  MAXTILES = 80;
  MAXTYPES = 18;
  WIN_W    = 1100;
  WIN_H    = 750;
  BORDER   = 30;
  DEPTH_X  = 10;
  DEPTH_Y  = 10;
  MAXUNDO  = 40;

VAR
  filename : ARRAY 256 OF CHAR;
  numStr   : ARRAY 32 OF CHAR;

  layoutC : ARRAY MAXTILES OF INTEGER;
  layoutR : ARRAY MAXTILES OF INTEGER;
  layoutL : ARRAY MAXTILES OF INTEGER;
  nLayout : INTEGER;
  maxCol, maxRow, maxLay : INTEGER;

  tileType    : ARRAY MAXTILES OF INTEGER;
  tileRemoved : ARRAY MAXTILES OF BOOLEAN;

  nTypes   : INTEGER;
  numPages : INTEGER;
  pages    : ARRAY MAXTYPES OF INTEGER;
  textures : ARRAY MAXTYPES OF Raylib.Texture;
  texW     : ARRAY MAXTYPES OF INTEGER;
  texH     : ARRAY MAXTYPES OF INTEGER;

  scrW, scrH : INTEGER;
  tileW, tileH : INTEGER;
  boardX, boardY : INTEGER;

  selected     : INTEGER;
  removedCount : INTEGER;
  won, stuck   : BOOLEAN;

  undoA, undoB : ARRAY MAXUNDO OF INTEGER;
  undoTop      : INTEGER;

  lastClickTime : REAL;
  lastClickTile : INTEGER;
  zoomTile      : INTEGER;

  cWhite, cBlack, cGray, cDarkGray, cLightGray : INTEGER;
  cYellow, cOrange, cRed : INTEGER;

(* ── Layout ────────────────────────────────────────────────────────────────── *)

PROCEDURE Add(c, r, l : INTEGER);
BEGIN
  layoutC[nLayout] := c;  layoutR[nLayout] := r;  layoutL[nLayout] := l;
  INC(nLayout);
  IF c > maxCol THEN maxCol := c END;
  IF r > maxRow THEN maxRow := r END;
  IF l > maxLay THEN maxLay := l END
END Add;

PROCEDURE Fill(c1, r1, c2, r2, l : INTEGER);
VAR c, r : INTEGER;
BEGIN
  FOR c := c1 TO c2 DO FOR r := r1 TO r2 DO Add(c, r, l) END END
END Fill;

PROCEDURE BuildLayout;
BEGIN
  nLayout := 0;  maxCol := 0;  maxRow := 0;  maxLay := 0;

  IF nTypes <= 9 THEN
    (* 36-tile (9 × 4) small pyramid *)
    Fill(0, 0, 4, 3, 0);    (* 20 *)
    Fill(1, 0, 3, 3, 1);    (* 12 *)
    Fill(1, 1, 2, 2, 2);    (*  4 *)
    nTypes := 9

  ELSIF nTypes <= 12 THEN
    (* 48-tile (12 × 4) medium pyramid *)
    Fill(0, 0, 6, 3, 0);    (* 28 *)
    Fill(2, 0, 5, 3, 1);    (* 16 *)
    Fill(3, 1, 4, 2, 2);    (*  4 *)
    nTypes := 12

  ELSE
    (* 72-tile (18 × 4) full pyramid — the default *)
    Fill(0, 0, 9, 3, 0);    (* 40 *)
    Fill(2, 0, 7, 3, 1);    (* 24 *)
    Fill(3, 1, 6, 2, 2);    (*  8 *)
    nTypes := 18

  END
END BuildLayout;

(* ── Freeness ──────────────────────────────────────────────────────────────── *)

PROCEDURE IsCovered(i : INTEGER) : BOOLEAN;
VAR j : INTEGER;
BEGIN
  FOR j := 0 TO nLayout - 1 DO
    IF ~tileRemoved[j] & (j # i) &
       (layoutL[j] = layoutL[i] + 1) &
       (layoutC[j] = layoutC[i]) &
       (layoutR[j] = layoutR[i]) THEN
      RETURN TRUE
    END
  END;
  RETURN FALSE
END IsCovered;

PROCEDURE HasLeft(i : INTEGER) : BOOLEAN;
VAR j : INTEGER;
BEGIN
  FOR j := 0 TO nLayout - 1 DO
    IF ~tileRemoved[j] & (j # i) &
       (layoutL[j] = layoutL[i]) &
       (layoutC[j] = layoutC[i] - 1) &
       (layoutR[j] = layoutR[i]) THEN
      RETURN TRUE
    END
  END;
  RETURN FALSE
END HasLeft;

PROCEDURE HasRight(i : INTEGER) : BOOLEAN;
VAR j : INTEGER;
BEGIN
  FOR j := 0 TO nLayout - 1 DO
    IF ~tileRemoved[j] & (j # i) &
       (layoutL[j] = layoutL[i]) &
       (layoutC[j] = layoutC[i] + 1) &
       (layoutR[j] = layoutR[i]) THEN
      RETURN TRUE
    END
  END;
  RETURN FALSE
END HasRight;

PROCEDURE IsFree(i : INTEGER) : BOOLEAN;
BEGIN
  IF tileRemoved[i] THEN RETURN FALSE END;
  IF IsCovered(i)   THEN RETURN FALSE END;
  RETURN ~HasLeft(i) OR ~HasRight(i)
END IsFree;

PROCEDURE IsStuck() : BOOLEAN;
VAR i, j : INTEGER;
BEGIN
  FOR i := 0 TO nLayout - 1 DO
    IF IsFree(i) THEN
      FOR j := i + 1 TO nLayout - 1 DO
        IF IsFree(j) & (tileType[j] = tileType[i]) THEN RETURN FALSE END
      END
    END
  END;
  RETURN TRUE
END IsStuck;

(* ── Resources ─────────────────────────────────────────────────────────────── *)

PROCEDURE ChoosePages;
VAR i, p : INTEGER;
    used : ARRAY 1024 OF BOOLEAN;
BEGIN
  FOR i := 0 TO numPages - 1 DO used[i] := FALSE END;
  i := 0;
  WHILE i < nTypes DO
    p := Random.Int(numPages);
    IF ~used[p] THEN pages[i] := p;  used[p] := TRUE;  INC(i) END
  END
END ChoosePages;

PROCEDURE LoadTextures;
VAR i : INTEGER;
BEGIN
  FOR i := 0 TO nTypes - 1 DO
    textures[i] := Raylib.LoadTexturePDF(filename, pages[i]);
    texW[i]     := Raylib.TextureWidth(textures[i]);
    texH[i]     := Raylib.TextureHeight(textures[i])
  END
END LoadTextures;

PROCEDURE UnloadTextures;
VAR i : INTEGER;
BEGIN
  FOR i := 0 TO nTypes - 1 DO Raylib.UnloadTexture(textures[i]) END
END UnloadTextures;

(* ── Shuffle ───────────────────────────────────────────────────────────────── *)

PROCEDURE ShuffleTiles;
VAR i, j, tmp : INTEGER;
    order : ARRAY MAXTILES OF INTEGER;
BEGIN
  FOR i := 0 TO nTypes - 1 DO
    order[i*4] := i;  order[i*4+1] := i;
    order[i*4+2] := i;  order[i*4+3] := i
  END;
  FOR i := nLayout - 1 TO 1 BY -1 DO
    j := Random.Int(i + 1);
    tmp := order[i];  order[i] := order[j];  order[j] := tmp
  END;
  FOR i := 0 TO nLayout - 1 DO
    tileType[i] := order[i];  tileRemoved[i] := FALSE
  END;
  selected := -1;  removedCount := 0;
  won := FALSE;  stuck := FALSE;  undoTop := 0
END ShuffleTiles;

PROCEDURE Restart;
BEGIN
  UnloadTextures;
  ChoosePages;
  LoadTextures;
  ShuffleTiles
END Restart;

(* ── Display ───────────────────────────────────────────────────────────────── *)

PROCEDURE ComputeDisplay;
VAR availW, availH, tw, th : INTEGER;
BEGIN
  availW := scrW - 2 * BORDER - maxLay * DEPTH_X;
  availH := scrH - 2 * BORDER - 44 - maxLay * DEPTH_Y;
  tw := availW DIV (maxCol + 1);
  th := availH DIV (maxRow + 1);
  IF tw * 14 < th * 10 THEN
    tileH := tw * 14 DIV 10
  ELSE
    tw := th * 10 DIV 14;
    tileH := th
  END;
  tileW  := tw;
  boardX := (scrW - ((maxCol + 1) * tileW + maxLay * DEPTH_X)) DIV 2;
  boardY := BORDER + maxLay * DEPTH_Y
END ComputeDisplay;

PROCEDURE TileX(i : INTEGER) : INTEGER;
BEGIN RETURN boardX + layoutC[i] * tileW + layoutL[i] * DEPTH_X END TileX;

PROCEDURE TileY(i : INTEGER) : INTEGER;
BEGIN RETURN boardY + layoutR[i] * tileH - layoutL[i] * DEPTH_Y END TileY;

(* ── Hit testing ───────────────────────────────────────────────────────────── *)

PROCEDURE HitTile(mx, my : INTEGER) : INTEGER;
VAR i, best, blay, sx, sy : INTEGER;
BEGIN
  best := -1;  blay := -1;
  FOR i := 0 TO nLayout - 1 DO
    IF ~tileRemoved[i] THEN
      sx := TileX(i);  sy := TileY(i);
      IF (mx >= sx) & (mx < sx + tileW) &
         (my >= sy) & (my < sy + tileH) THEN
        IF layoutL[i] > blay THEN  blay := layoutL[i];  best := i  END
      END
    END
  END;
  RETURN best
END HitTile;

(* ── Update ────────────────────────────────────────────────────────────────── *)

PROCEDURE Update;
VAR mx, my, hit : INTEGER;
    now : REAL;
BEGIN
  (* Dismiss zoom on any click or R/U key *)
  IF zoomTile >= 0 THEN
    IF Raylib.IsMouseButtonPressed(Raylib.BtnLeft) = 1 THEN
      zoomTile := -1
    END;
    RETURN
  END;

  IF Raylib.IsKeyPressed(ORD('R')) = 1 THEN Restart; RETURN END;

  IF Raylib.IsKeyPressed(ORD('U')) = 1 THEN
    IF undoTop > 0 THEN
      DEC(undoTop);
      tileRemoved[undoA[undoTop]] := FALSE;
      tileRemoved[undoB[undoTop]] := FALSE;
      DEC(removedCount, 2);
      selected := -1;  won := FALSE;  stuck := FALSE
    END;
    RETURN
  END;

  IF won OR stuck THEN RETURN END;

  IF Raylib.IsMouseButtonPressed(Raylib.BtnLeft) = 1 THEN
    mx := Raylib.GetMouseX();  my := Raylib.GetMouseY();
    hit := HitTile(mx, my);
    now := Raylib.GetTime();

    (* Double-click on same tile → zoom *)
    IF (hit >= 0) & (hit = lastClickTile) &
       (now - lastClickTime < 0.35) THEN
      zoomTile      := tileType[hit];
      lastClickTile := -1;
      RETURN
    END;
    lastClickTime := now;
    lastClickTile := hit;

    IF (hit >= 0) & IsFree(hit) THEN
      IF selected < 0 THEN
        selected := hit
      ELSIF hit = selected THEN
        selected := -1
      ELSIF tileType[hit] = tileType[selected] THEN
        tileRemoved[hit] := TRUE;  tileRemoved[selected] := TRUE;
        undoA[undoTop] := selected;  undoB[undoTop] := hit;
        IF undoTop < MAXUNDO - 1 THEN INC(undoTop) END;
        INC(removedCount, 2);
        selected := -1;
        IF removedCount = nLayout THEN won := TRUE
        ELSE stuck := IsStuck()
        END
      ELSE
        selected := hit
      END
    END
  END
END Update;

(* ── Drawing ───────────────────────────────────────────────────────────────── *)

PROCEDURE DrawTile(i : INTEGER);
VAR sx, sy, t, pad, bgCol : INTEGER;
    free : BOOLEAN;
BEGIN
  sx := TileX(i);  sy := TileY(i);  t := tileType[i];  pad := 4;
  free := IsFree(i);

  (* Drop shadow only for raised (free/selected) tiles *)
  IF free OR (i = selected) THEN
    Raylib.DrawRectangle(sx + 5, sy + 5, tileW, tileH, Raylib.Fade(cBlack, 0.50))
  END;

  IF i = selected THEN  bgCol := cYellow
  ELSIF free THEN        bgCol := cWhite
  ELSE                   bgCol := cLightGray
  END;
  Raylib.DrawRectangle(sx, sy, tileW, tileH, bgCol);

  (* Texture *)
  IF texW[t] > 0 THEN
    Raylib.DrawTexturePro(textures[t], 0, 0, texW[t], texH[t],
                          sx+pad, sy+pad, tileW-2*pad, tileH-2*pad, cWhite)
  END;

  (* Dark overlay dims covered tiles so free tiles stand out clearly *)
  IF ~free & (i # selected) THEN
    Raylib.DrawRectangle(sx, sy, tileW, tileH, Raylib.Fade(cBlack, 0.38))
  END;

  (* Raised bevel for free tiles: bright top/left, dark bottom/right *)
  IF free & (i # selected) THEN
    Raylib.DrawLine(sx,          sy,          sx + tileW - 1, sy,          cWhite);
    Raylib.DrawLine(sx + 1,      sy + 1,      sx + tileW - 2, sy + 1,      Raylib.Fade(cWhite, 0.55));
    Raylib.DrawLine(sx,          sy,          sx,             sy + tileH - 1, cWhite);
    Raylib.DrawLine(sx + 1,      sy + 1,      sx + 1,         sy + tileH - 2, Raylib.Fade(cWhite, 0.55));
    Raylib.DrawLine(sx + tileW - 1, sy,        sx + tileW - 1, sy + tileH - 1, cGray);
    Raylib.DrawLine(sx + tileW - 2, sy + 1,    sx + tileW - 2, sy + tileH - 2, Raylib.Fade(cGray, 0.55));
    Raylib.DrawLine(sx,          sy + tileH - 1, sx + tileW - 1, sy + tileH - 1, cGray);
    Raylib.DrawLine(sx + 1,      sy + tileH - 2, sx + tileW - 2, sy + tileH - 2, Raylib.Fade(cGray, 0.55))
  ELSIF i = selected THEN
    Raylib.DrawRectangleLines(sx,     sy,     tileW,     tileH,     cOrange);
    Raylib.DrawRectangleLines(sx + 1, sy + 1, tileW - 2, tileH - 2, cOrange)
  ELSE
    Raylib.DrawRectangleLines(sx, sy, tileW, tileH, cDarkGray)
  END
END DrawTile;

PROCEDURE DrawZoom;
VAR t, tw, th, dispW, dispH, dstX, dstY : INTEGER;
    s : ARRAY 80 OF CHAR;
BEGIN
  Raylib.DrawRectangle(0, 0, scrW, scrH, Raylib.Fade(cBlack, 0.85));
  t    := zoomTile;
  tw   := texW[t];  th := texH[t];
  dispW := scrW - 6 * BORDER;
  dispH := scrH - 6 * BORDER - 40;
  IF (tw > 0) & (th > 0) THEN
    IF tw * dispH > th * dispW THEN
      dispH := dispW * th DIV tw
    ELSE
      dispW := dispH * tw DIV th
    END
  END;
  dstX := (scrW - dispW) DIV 2;
  dstY := (scrH - dispH - 40) DIV 2;
  Raylib.DrawRectangle(dstX - 10, dstY - 10, dispW + 20, dispH + 20, cWhite);
  Raylib.DrawRectangleLines(dstX - 10, dstY - 10, dispW + 20, dispH + 20, cYellow);
  IF (tw > 0) & (th > 0) THEN
    Raylib.DrawTexturePro(textures[t], 0, 0, tw, th, dstX, dstY, dispW, dispH, cWhite)
  END;
  s := "Click anywhere to close";
  Raylib.DrawText(s, (scrW - Raylib.MeasureText(s, 18)) DIV 2,
                  dstY + dispH + 16, 18, Raylib.Fade(cWhite, 0.80))
END DrawZoom;

PROCEDURE Draw;
VAR i, l, tw : INTEGER;
    s, ns : ARRAY 80 OF CHAR;
BEGIN
  Raylib.BeginDrawing;
  Raylib.ClearBackground(cGray);

  FOR l := 0 TO maxLay DO
    FOR i := 0 TO nLayout - 1 DO
      IF ~tileRemoved[i] & (layoutL[i] = l) THEN DrawTile(i) END
    END
  END;

  s := "Tiles: ";
  Strings.IntToStr(nLayout - removedCount, ns);  Strings.Append(ns, s);
  Strings.Append(" / ", s);
  Strings.IntToStr(nLayout, ns);  Strings.Append(ns, s);
  Raylib.DrawText(s, 10, scrH - 32, 20, cWhite);

  s := "R = new game   U = undo";
  Raylib.DrawText(s, scrW - Raylib.MeasureText(s, 16) - 10,
                  scrH - 30, 16, Raylib.Fade(cWhite, 0.65));

  IF stuck & ~won THEN
    s  := "No moves — press R";
    tw := Raylib.MeasureText(s, 28);
    Raylib.DrawRectangle((scrW - tw - 30) DIV 2, scrH DIV 2 - 30,
                         tw + 30, 56, Raylib.Fade(cBlack, 0.78));
    Raylib.DrawText(s, (scrW - tw) DIV 2, scrH DIV 2 - 16, 28, cRed)
  END;

  IF won THEN
    s  := "You Win!";
    tw := Raylib.MeasureText(s, 60);
    Raylib.DrawRectangle((scrW - tw - 40) DIV 2, scrH DIV 2 - 60,
                         tw + 40, 110, Raylib.Fade(cBlack, 0.78));
    Raylib.DrawText(s, (scrW - tw) DIV 2, scrH DIV 2 - 44, 60, cYellow);
    s  := "Press R for a new game";
    tw := Raylib.MeasureText(s, 24);
    Raylib.DrawText(s, (scrW - tw) DIV 2, scrH DIV 2 + 22, 24, cWhite)
  END;

  IF zoomTile >= 0 THEN DrawZoom END;

  Raylib.EndDrawing
END Draw;

(* ── Main ──────────────────────────────────────────────────────────────────── *)

BEGIN
  cWhite     := Raylib.White();
  cBlack     := Raylib.Black();
  cGray      := Raylib.Gray();
  cDarkGray  := Raylib.DarkGray();
  cLightGray := Raylib.LightGray();
  cYellow    := Raylib.Yellow();
  cOrange    := Raylib.Orange();
  cRed       := Raylib.Red();

  lastClickTime := 0.0;
  lastClickTile := -1;
  zoomTile      := -1;

  IF Args.Count() < 1 THEN
    Out.String("Usage: mahjong <file.pdf> [num-types]");
    Out.Ln;
    RETURN
  END;

  Args.Get(1, filename);
  nTypes := MAXTYPES;
  IF Args.Count() >= 2 THEN
    Args.Get(2, numStr);
    IF ~Strings.StrToInt(numStr, nTypes) THEN nTypes := MAXTYPES END
  END;
  IF nTypes < 1 THEN nTypes := 1 END;

  BuildLayout;   (* snaps nTypes to 9, 12, or 18 and sets nLayout *)

  numPages := Raylib.CountPDFPages(filename);
  IF numPages < 1 THEN
    Out.String("Error: could not open PDF: ");
    Out.String(filename);
    Out.Ln;
    RETURN
  END;
  IF numPages < nTypes THEN
    Out.String("Error: PDF has only ");
    Out.Int(numPages, 0);
    Out.String(" page(s) but ");
    Out.Int(nTypes, 0);
    Out.String(" unique tile types required.");
    Out.Ln;
    RETURN
  END;

  scrW := WIN_W;  scrH := WIN_H;
  ComputeDisplay;
  ChoosePages;

  Raylib.InitWindow(WIN_W, WIN_H, "Mahjong Solitaire");
  Raylib.SetWindowResizable();
  Raylib.SetTargetFPS(60);

  LoadTextures;
  ShuffleTiles;

  WHILE Raylib.WindowShouldClose() = 0 DO
    scrW := Raylib.GetScreenWidth();
    scrH := Raylib.GetScreenHeight();
    ComputeDisplay;
    Update;
    Draw
  END;

  UnloadTextures;
  Raylib.CloseWindow
END Mahjong.
