MODULE Memory;
(*
 * PDF page memory (concentration) game.
 * Usage: memory <file.pdf> [num-pairs]
 *
 * Randomly selected PDF pages appear as face-down cards, each page
 * twice.  Click two cards to flip them; matching pairs stay revealed.
 * A mismatch stays visible briefly — click anywhere to flip back.
 * Find all pairs to win.  Press R to restart with a fresh deal.
 *)

IMPORT Raylib, Args, Strings, Random, Out;

CONST
  MAXPAIRS      = 18;
  MAXCARDS      = 36;   (* 2 * MAXPAIRS *)
  WIN_W         = 1100;
  WIN_H         = 750;
  BORDER        = 40;
  GAP           = 8;
  DEFAULT_PAIRS = 8;
  FLIP_DELAY    = 90;   (* frames a mismatch stays visible before auto-flip *)

VAR
  filename : ARRAY 256 OF CHAR;
  numStr   : ARRAY 32 OF CHAR;
  numPages : INTEGER;
  numPairs : INTEGER;
  nCols    : INTEGER;
  nRows    : INTEGER;
  numCards : INTEGER;
  cardW    : INTEGER;
  cardH    : INTEGER;

  (* per-card state; card i corresponds to position in the shuffled deck *)
  cardIdx : ARRAY MAXCARDS OF INTEGER;   (* index 0..numPairs-1 into pages/tex *)
  flipped : ARRAY MAXCARDS OF BOOLEAN;
  matched : ARRAY MAXCARDS OF BOOLEAN;

  (* per-unique-page resources *)
  pages    : ARRAY MAXPAIRS OF INTEGER;
  textures : ARRAY MAXPAIRS OF Raylib.Texture;
  texW     : ARRAY MAXPAIRS OF INTEGER;
  texH     : ARRAY MAXPAIRS OF INTEGER;

  first      : INTEGER;   (* index of first flipped card, -1 if none *)
  second     : INTEGER;   (* index of second flipped card, -1 if none *)
  flipTimer  : INTEGER;   (* countdown after a mismatch *)
  matchCount : INTEGER;
  won        : BOOLEAN;

  cWhite     : INTEGER;
  cBlack     : INTEGER;
  cGray      : INTEGER;
  cDarkGray  : INTEGER;
  cLightGray : INTEGER;
  cGreen     : INTEGER;
  cYellow    : INTEGER;
  cBlue      : INTEGER;
  cDarkBlue  : INTEGER;

(* ── Helpers ─────────────────────────────────────────────────────────────── *)

PROCEDURE CardX(i : INTEGER) : INTEGER;
BEGIN RETURN BORDER + (i MOD nCols) * (cardW + GAP) END CardX;

PROCEDURE CardY(i : INTEGER) : INTEGER;
BEGIN RETURN BORDER + (i DIV nCols) * (cardH + GAP) END CardY;

PROCEDURE HitCard(mx, my : INTEGER) : INTEGER;
VAR i, cx, cy : INTEGER;
BEGIN
  FOR i := 0 TO numCards - 1 DO
    cx := CardX(i);
    cy := CardY(i);
    IF (mx >= cx) & (mx < cx + cardW) &
       (my >= cy) & (my < cy + cardH) THEN
      RETURN i
    END
  END;
  RETURN -1
END HitCard;

(* ── Choose pages & build deck ────────────────────────────────────────────── *)

PROCEDURE ChoosePages;
VAR i, j, p, tmp : INTEGER;
    used : ARRAY 1024 OF BOOLEAN;
BEGIN
  FOR i := 0 TO numPages - 1 DO used[i] := FALSE END;
  i := 0;
  WHILE i < numPairs DO
    p := Random.Int(numPages);
    IF ~used[p] THEN
      pages[i] := p;
      used[p]  := TRUE;
      INC(i)
    END
  END;
  (* Build paired, shuffled deck *)
  FOR i := 0 TO numPairs - 1 DO
    cardIdx[i]            := i;
    cardIdx[i + numPairs] := i
  END;
  (* Fisher-Yates shuffle *)
  FOR i := numCards - 1 TO 1 BY -1 DO
    j            := Random.Int(i + 1);
    tmp          := cardIdx[i];
    cardIdx[i]   := cardIdx[j];
    cardIdx[j]   := tmp
  END;
  FOR i := 0 TO numCards - 1 DO
    flipped[i] := FALSE;
    matched[i] := FALSE
  END;
  first      := -1;
  second     := -1;
  flipTimer  := 0;
  matchCount := 0;
  won        := FALSE
END ChoosePages;

PROCEDURE LoadTextures;
VAR i : INTEGER;
BEGIN
  FOR i := 0 TO numPairs - 1 DO
    textures[i] := Raylib.LoadTexturePDF(filename, pages[i]);
    texW[i]     := Raylib.TextureWidth(textures[i]);
    texH[i]     := Raylib.TextureHeight(textures[i])
  END
END LoadTextures;

PROCEDURE UnloadTextures;
VAR i : INTEGER;
BEGIN
  FOR i := 0 TO numPairs - 1 DO
    Raylib.UnloadTexture(textures[i])
  END
END UnloadTextures;

(* ── Restart (new deal, reload pages) ────────────────────────────────────── *)

PROCEDURE Restart;
BEGIN
  UnloadTextures;
  ChoosePages;
  LoadTextures
END Restart;

(* ── Layout ──────────────────────────────────────────────────────────────── *)

PROCEDURE ComputeLayout;
VAR c, r, best, diff : INTEGER;
    aspect, rat, brat : REAL;
    availW, availH : INTEGER;
BEGIN
  (* find nCols/nRows closest to window aspect ratio *)
  aspect := FLT(WIN_W) / FLT(WIN_H);
  best   := 2000000000;
  nCols  := 1;
  nRows  := numCards;
  FOR c := 1 TO numCards DO
    r    := (numCards + c - 1) DIV c;
    diff := c * r - numCards;
    IF diff < 0 THEN diff := -diff END;
    rat  := FLT(c) / FLT(r);
    IF rat > aspect THEN brat := rat - aspect
    ELSE                 brat := aspect - rat
    END;
    (* penalise wasted cells and aspect-ratio deviation *)
    IF (diff * 4 + FLOOR(brat * 10.0)) < best THEN
      best  := diff * 4 + FLOOR(brat * 10.0);
      nCols := c;
      nRows := r
    END
  END;
  availW := WIN_W - 2 * BORDER - (nCols - 1) * GAP;
  availH := WIN_H - 2 * BORDER - (nRows - 1) * GAP;
  cardW  := availW DIV nCols;
  cardH  := availH DIV nRows
END ComputeLayout;

(* ── Update ──────────────────────────────────────────────────────────────── *)

PROCEDURE Update;
VAR mx, my, hit, pi : INTEGER;
BEGIN
  IF Raylib.IsKeyPressed(ORD('R')) = 1 THEN
    Restart;
    RETURN
  END;

  IF flipTimer > 0 THEN
    DEC(flipTimer);
    IF (flipTimer = 0) OR (Raylib.IsMouseButtonPressed(Raylib.BtnLeft) = 1) THEN
      flipped[first]  := FALSE;
      flipped[second] := FALSE;
      first     := -1;
      second    := -1;
      flipTimer := 0
    END;
    RETURN
  END;

  IF won THEN RETURN END;

  IF Raylib.IsMouseButtonPressed(Raylib.BtnLeft) = 1 THEN
    mx  := Raylib.GetMouseX();
    my  := Raylib.GetMouseY();
    hit := HitCard(mx, my);
    IF (hit >= 0) & ~flipped[hit] & ~matched[hit] THEN
      flipped[hit] := TRUE;
      IF first < 0 THEN
        first := hit
      ELSE
        second := hit;
        pi     := cardIdx[first];
        IF cardIdx[second] = pi THEN
          matched[first]  := TRUE;
          matched[second] := TRUE;
          INC(matchCount);
          IF matchCount = numPairs THEN won := TRUE END;
          first  := -1;
          second := -1
        ELSE
          flipTimer := FLIP_DELAY
        END
      END
    END
  END
END Update;

(* ── Drawing ──────────────────────────────────────────────────────────────── *)

PROCEDURE DrawCardBack(x, y : INTEGER);
VAR cx, cy, r : INTEGER;
BEGIN
  Raylib.DrawRectangle(x, y, cardW, cardH, cDarkBlue);
  cx := x + cardW DIV 2;
  cy := y + cardH DIV 2;
  r  := cardW DIV 4;
  IF cardH DIV 4 < r THEN r := cardH DIV 4 END;
  Raylib.DrawCircle(cx, cy, FLT(r), Raylib.Fade(cBlue, 0.6));
  Raylib.DrawCircleLines(cx, cy, FLT(r), Raylib.Fade(cWhite, 0.35));
  Raylib.DrawRectangleLines(x + 4, y + 4, cardW - 8, cardH - 8,
                             Raylib.Fade(cWhite, 0.3));
  Raylib.DrawRectangleLines(x, y, cardW, cardH, cLightGray)
END DrawCardBack;

PROCEDURE DrawCardFace(i : INTEGER; highlight : BOOLEAN);
VAR x, y, pi, col : INTEGER;
BEGIN
  x  := CardX(i);
  y  := CardY(i);
  pi := cardIdx[i];
  IF texW[pi] > 0 THEN
    IF highlight THEN col := Raylib.Fade(cWhite, 0.85)
    ELSE              col := cWhite
    END;
    Raylib.DrawTexturePro(textures[pi], 0, 0, texW[pi], texH[pi],
                          x, y, cardW, cardH, col)
  ELSE
    Raylib.DrawRectangle(x, y, cardW, cardH, cGray)
  END;
  IF matched[i] THEN
    Raylib.DrawRectangleLines(x, y, cardW, cardH, cGreen)
  ELSE
    Raylib.DrawRectangleLines(x, y, cardW, cardH, cLightGray)
  END
END DrawCardFace;

PROCEDURE Draw;
VAR i, tw : INTEGER;
    s, ns : ARRAY 80 OF CHAR;
BEGIN
  Raylib.BeginDrawing;
  Raylib.ClearBackground(cGray);

  FOR i := 0 TO numCards - 1 DO
    IF flipped[i] OR matched[i] THEN
      DrawCardFace(i, (i = first) OR (i = second))
    ELSE
      DrawCardBack(CardX(i), CardY(i))
    END
  END;

  (* HUD *)
  s := "Pairs: ";
  Strings.IntToStr(matchCount, ns);
  Strings.Append(ns, s);
  Strings.Append(" / ", s);
  Strings.IntToStr(numPairs, ns);
  Strings.Append(ns, s);
  Raylib.DrawText(s, 10, WIN_H - 28, 20, cWhite);

  s := "R = new game";
  Raylib.DrawText(s, WIN_W - Raylib.MeasureText(s, 16) - 10,
                  WIN_H - 26, 16, Raylib.Fade(cWhite, 0.65));

  IF flipTimer > 0 THEN
    s := "No match — click to reset early";
    tw := Raylib.MeasureText(s, 18);
    Raylib.DrawText(s, (WIN_W - tw) DIV 2, WIN_H - 28, 18,
                    Raylib.Fade(cYellow, 0.9))
  END;

  IF won THEN
    s  := "You Win!";
    tw := Raylib.MeasureText(s, 60);
    Raylib.DrawRectangle((WIN_W - tw - 40) DIV 2, WIN_H DIV 2 - 60,
                         tw + 40, 110, Raylib.Fade(cBlack, 0.78));
    Raylib.DrawText(s, (WIN_W - tw) DIV 2, WIN_H DIV 2 - 44, 60, cYellow);
    s  := "Press R for a new game";
    tw := Raylib.MeasureText(s, 24);
    Raylib.DrawText(s, (WIN_W - tw) DIV 2, WIN_H DIV 2 + 22, 24, cWhite)
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
  cDarkBlue  := Raylib.DarkBlue();

  IF Args.Count() < 1 THEN
    Out.String("Usage: memory <file.pdf> [num-pairs]");
    Out.Ln;
    RETURN
  END;

  Args.Get(1, filename);
  numPairs := DEFAULT_PAIRS;
  IF Args.Count() >= 2 THEN
    Args.Get(2, numStr);
    IF ~Strings.StrToInt(numStr, numPairs) THEN numPairs := DEFAULT_PAIRS END
  END;
  IF numPairs < 2  THEN numPairs := 2 END;
  IF numPairs > MAXPAIRS THEN numPairs := MAXPAIRS END;

  numPages := Raylib.CountPDFPages(filename);
  IF numPages < 1 THEN
    Out.String("Error: could not open PDF: ");
    Out.String(filename);
    Out.Ln;
    RETURN
  END;
  IF numPages < numPairs THEN
    Out.String("Error: PDF has only ");
    Out.Int(numPages, 0);
    Out.String(" page(s) but ");
    Out.Int(numPairs, 0);
    Out.String(" pairs requested.");
    Out.Ln;
    RETURN
  END;

  numCards := 2 * numPairs;
  ComputeLayout;
  ChoosePages;

  Raylib.InitWindow(WIN_W, WIN_H, "Memory");
  Raylib.SetTargetFPS(60);

  LoadTextures;

  WHILE Raylib.WindowShouldClose() = 0 DO
    Update;
    Draw
  END;

  UnloadTextures;
  Raylib.CloseWindow
END Memory.
