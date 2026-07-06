MODULE Jigsaw;
(*
 * Mouse-driven jigsaw puzzle with knob-and-slot pieces.
 * Usage: jigsaw <image.jpg|image.png|image.pdf> [approx-pieces]
 *        jigsaw <savefile.sav>
 *
 * Piece shapes (knobs/slots) are generated entirely in Oberon using the
 * generic Raylib.Image pixel-access API — no jigsaw-specific C code.
 *
 * Left-click and drag pieces into the outlined grid.
 * Release near the correct slot to snap it into place.
 * Press R to reshuffle all pieces.
 * Press H to toggle the faint hint image.
 * Press S to save progress.
 *)

IMPORT Raylib, Args, Strings, Random, Files, Out;

CONST
  MAXPIECES  = 400;
  WIN_W      = 1100;
  WIN_H      = 750;
  BORDER     = 60;   (* margin around the solved-image area *)
  SAVE_MAGIC = 20260704;

VAR
  imgTex         : Raylib.Texture;
  imgW, imgH     : INTEGER;
  nCols, nRows   : INTEGER;
  nPieces        : INTEGER;
  pieceW, pieceH : INTEGER;   (* source pixels per piece in the texture *)
  dispW, dispH   : INTEGER;   (* display size of the full solved image *)
  dispX, dispY   : INTEGER;   (* screen top-left of the solved-image area *)
  dPW, dPH       : INTEGER;   (* display pixels per piece *)
  scrW, scrH     : INTEGER;
  prevScrW, prevScrH : INTEGER;

  pieceX, pieceY : ARRAY MAXPIECES OF REAL;
  placed         : ARRAY MAXPIECES OF BOOLEAN;
  drawOrd        : ARRAY MAXPIECES OF INTEGER;  (* back-to-front draw order *)

  pieceTex  : ARRAY MAXPIECES OF Raylib.Texture;
  edgeTop   : ARRAY MAXPIECES OF INTEGER;
  edgeRight : ARRAY MAXPIECES OF INTEGER;
  edgeBot   : ARRAY MAXPIECES OF INTEGER;
  edgeLeft  : ARRAY MAXPIECES OF INTEGER;
  knobPad   : INTEGER;

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

  filename     : ARRAY 256 OF CHAR;
  saveName     : ARRAY 256 OF CHAR;
  numStr       : ARRAY 32 OF CHAR;
  nTarget      : INTEGER;
  pdfPage      : INTEGER;   (* -1 if not a PDF, otherwise the chosen page index *)
  saveMsgTimer : INTEGER;
  resuming     : BOOLEAN;

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
  maxW  := scrW - 2 * BORDER;
  maxH  := scrH - 2 * BORDER;
  ratio := FLT(imgW) / FLT(imgH);
  IF FLT(maxW) / FLT(maxH) > ratio THEN
    dispH := maxH;
    dispW := FLOOR(FLT(dispH) * ratio)
  ELSE
    dispW := maxW;
    dispH := FLOOR(FLT(dispW) / ratio)
  END;
  dispX := (scrW - dispW) DIV 2;
  dispY := (scrH - dispH) DIV 2;
  dPW   := dispW DIV nCols;
  dPH   := dispH DIV nRows
END InitLayout;

(* ── Piece edge generation ────────────────────────────────────────────────── *)

PROCEDURE GenEdges;
VAR p, col, row : INTEGER;
BEGIN
  FOR p := 0 TO nPieces - 1 DO
    col := PieceCol(p);
    row := PieceRow(p);
    (* Left edge mirrors the right edge of the piece to the left *)
    IF col = 0 THEN edgeLeft[p] := 0
    ELSE            edgeLeft[p] := -edgeRight[p - 1] END;
    (* Top edge mirrors the bottom edge of the piece above *)
    IF row = 0 THEN edgeTop[p] := 0
    ELSE            edgeTop[p] := -edgeBot[p - nCols] END;
    (* Right edge: flat on puzzle border, random +1/-1 internally *)
    IF col = nCols - 1 THEN edgeRight[p] := 0
    ELSIF Random.Int(2) = 0 THEN edgeRight[p] := 1
    ELSE                        edgeRight[p] := -1 END;
    (* Bottom edge: flat on puzzle border, random +1/-1 internally *)
    IF row = nRows - 1 THEN edgeBot[p] := 0
    ELSIF Random.Int(2) = 0 THEN edgeBot[p] := 1
    ELSE                         edgeBot[p] := -1 END
  END
END GenEdges;

(* ── Jigsaw piece texture generation (pure Oberon) ────────────────────────── *)

(* Returns TRUE if piece-display point (px, py) lies inside the jigsaw shape.
 * The shape is the core rectangle [0,dPW) x [0,dPH), plus circular knob
 * areas that extend outward, minus circular slot cutouts.
 * Knob centre offset: R/2 beyond the edge; radius R.
 * Uses module-level dPW/dPH. *)
PROCEDURE IsInside(px, py, R2,
                   tCX, tCY, bCX, bCY,
                   lCX, lCY, rCX, rCY : REAL;
                   te, re, be, le : INTEGER) : BOOLEAN;
VAR dT, dB, dL, dR : REAL;
BEGIN
  dT := (px-tCX)*(px-tCX) + (py-tCY)*(py-tCY);
  dB := (px-bCX)*(px-bCX) + (py-bCY)*(py-bCY);
  dL := (px-lCX)*(px-lCX) + (py-lCY)*(py-lCY);
  dR := (px-rCX)*(px-rCX) + (py-rCY)*(py-rCY);
  IF (px >= 0.0) & (px < FLT(dPW)) & (py >= 0.0) & (py < FLT(dPH)) THEN
    (* Inside core rectangle — subtract slot cutouts *)
    IF ((te < 0) & (dT < R2)) OR ((be < 0) & (dB < R2)) OR
       ((le < 0) & (dL < R2)) OR ((re < 0) & (dR < R2)) THEN
      RETURN FALSE
    END;
    RETURN TRUE
  END;
  (* Outside core — add knob bumps *)
  RETURN ((te > 0) & (dT < R2)) OR ((be > 0) & (dB < R2)) OR
         ((le > 0) & (dL < R2)) OR ((re > 0) & (dR < R2))
END IsInside;

PROCEDURE GenOnePiece(srcImg : Raylib.Image; p : INTEGER);
VAR
  tw, th, ox, oy : INTEGER;
  px, py         : REAL;
  R, R2          : REAL;
  tCX, tCY       : REAL;
  bCX, bCY       : REAL;
  lCX, lCY       : REAL;
  rCX, rCY       : REAL;
  inside, isEdge : BOOLEAN;
  srcX, srcY     : INTEGER;
  srcW, srcH     : INTEGER;
  pix, r, g, b   : INTEGER;
  outImg         : Raylib.Image;
  col, row       : INTEGER;
  te, re, be, le : INTEGER;
BEGIN
  col := PieceCol(p);  row := PieceRow(p);
  te  := edgeTop[p];   re  := edgeRight[p];
  be  := edgeBot[p];   le  := edgeLeft[p];

  tw := dPW + 2 * knobPad;
  th := dPH + 2 * knobPad;
  srcW := Raylib.ImageWidth(srcImg);
  srcH := Raylib.ImageHeight(srcImg);

  IF dPW < dPH THEN R := FLT(dPW) * 0.18
  ELSE              R := FLT(dPH) * 0.18 END;
  R2 := R * R;

  (* Knob/slot circle centres in piece display coords *)
  tCX := FLT(dPW) * 0.5;  tCY := -R * 0.5;
  bCX := FLT(dPW) * 0.5;  bCY :=  FLT(dPH) + R * 0.5;
  lCX := -R * 0.5;          lCY :=  FLT(dPH) * 0.5;
  rCX :=  FLT(dPW) + R * 0.5;  rCY := FLT(dPH) * 0.5;

  outImg := Raylib.NewImage(tw, th, Raylib.Blank());

  FOR oy := 0 TO th - 1 DO
    FOR ox := 0 TO tw - 1 DO
      px := FLT(ox - knobPad);
      py := FLT(oy - knobPad);

      inside := IsInside(px, py, R2, tCX, tCY, bCX, bCY, lCX, lCY, rCX, rCY,
                         te, re, be, le);
      IF inside THEN
        (* Nearest-neighbour map to source image coordinates *)
        srcX := col * pieceW + FLOOR(px * FLT(pieceW) / FLT(dPW));
        srcY := row * pieceH + FLOOR(py * FLT(pieceH) / FLT(dPH));
        IF srcX < 0 THEN srcX := 0 ELSIF srcX >= srcW THEN srcX := srcW - 1 END;
        IF srcY < 0 THEN srcY := 0 ELSIF srcY >= srcH THEN srcY := srcH - 1 END;

        pix := Raylib.GetImagePixel(srcImg, srcX, srcY);

        (* 1-pixel dark outline: check if any 4-neighbour is outside the shape *)
        isEdge := ~IsInside(px-1.0, py,     R2, tCX, tCY, bCX, bCY, lCX, lCY, rCX, rCY, te, re, be, le) OR
                  ~IsInside(px+1.0, py,     R2, tCX, tCY, bCX, bCY, lCX, lCY, rCX, rCY, te, re, be, le) OR
                  ~IsInside(px,     py-1.0, R2, tCX, tCY, bCX, bCY, lCX, lCY, rCX, rCY, te, re, be, le) OR
                  ~IsInside(px,     py+1.0, R2, tCX, tCY, bCX, bCY, lCX, lCY, rCX, rCY, te, re, be, le);

        (* Extract R,G,B from packed color (floor-safe for negative values) *)
        r := (pix DIV 65536) MOD 256;
        g := (pix DIV 256)   MOD 256;
        b :=  pix            MOD 256;

        IF isEdge THEN
          (* Darken by 45% *)
          r := r * 55 DIV 100;
          g := g * 55 DIV 100;
          b := b * 55 DIV 100
        END;

        (* Pack to (alpha=255, r, g, b) without overflow using signed arithmetic:
         * 255<<24 = 4278190080 which overflows int32, but -16777216 = -(256<<24)
         * is the same bit pattern and is representable. *)
        pix := -16777216 + r * 65536 + g * 256 + b;

        Raylib.SetImagePixel(outImg, ox, oy, pix)
      END
    END
  END;

  IF pieceTex[p] # NIL THEN Raylib.UnloadTexture(pieceTex[p]) END;
  pieceTex[p] := Raylib.TextureFromImage(outImg);
  Raylib.UnloadImage(outImg)
END GenOnePiece;

PROCEDURE FreePieceTex;
VAR p : INTEGER;
BEGIN
  FOR p := 0 TO nPieces - 1 DO
    IF pieceTex[p] # NIL THEN
      Raylib.UnloadTexture(pieceTex[p]);
      pieceTex[p] := NIL
    END
  END
END FreePieceTex;

PROCEDURE GenPieceTex;
VAR p : INTEGER;
    srcImg : Raylib.Image;
BEGIN
  (* knobPad = floor(R * 1.7) + 2 where R = 0.18 * min(dPW, dPH) *)
  IF dPW < dPH THEN knobPad := FLOOR(FLT(dPW) * 0.306) + 2
  ELSE              knobPad := FLOOR(FLT(dPH) * 0.306) + 2 END;

  srcImg := Raylib.LoadImageFromTexture(imgTex);
  FOR p := 0 TO nPieces - 1 DO
    GenOnePiece(srcImg, p)
  END;
  Raylib.UnloadImage(srcImg)
END GenPieceTex;

(* ── Piece state ──────────────────────────────────────────────────────────── *)

PROCEDURE Scatter;
VAR i, j, tmp : INTEGER;
BEGIN
  FOR i := 0 TO nPieces - 1 DO
    drawOrd[i] := i;
    placed[i]  := FALSE;
    pieceX[i]  := FLT(Random.Int(scrW - dPW));
    pieceY[i]  := FLT(Random.Int(scrH - dPH))
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

PROCEDURE RescalePieces(oldW, oldH, newW, newH : INTEGER);
VAR i : INTEGER;
BEGIN
  FOR i := 0 TO nPieces - 1 DO
    IF placed[i] THEN
      pieceX[i] := TargetX(i);
      pieceY[i] := TargetY(i)
    ELSE
      pieceX[i] := pieceX[i] * FLT(newW) / FLT(oldW);
      pieceY[i] := pieceY[i] * FLT(newH) / FLT(oldH)
    END
  END
END RescalePieces;

PROCEDURE BringToFront(k : INTEGER);
VAR i, tmp : INTEGER;
BEGIN
  tmp := drawOrd[k];
  FOR i := k TO nPieces - 2 DO
    drawOrd[i] := drawOrd[i + 1]
  END;
  drawOrd[nPieces - 1] := tmp
END BringToFront;

(* ── Save / Load ─────────────────────────────────────────────────────────── *)

PROCEDURE IsSaveFile(name : ARRAY OF CHAR) : BOOLEAN;
VAR len : INTEGER;
BEGIN
  len := Strings.Length(name);
  RETURN (len > 4) & (name[len-4] = '.') & (name[len-3] = 's') &
         (name[len-2] = 'a') & (name[len-1] = 'v')
END IsSaveFile;

PROCEDURE IsPDFFile(name : ARRAY OF CHAR) : BOOLEAN;
VAR len : INTEGER;
BEGIN
  len := Strings.Length(name);
  RETURN (len > 4) & (name[len-4] = '.') &
         ((name[len-3] = 'p') OR (name[len-3] = 'P')) &
         ((name[len-2] = 'd') OR (name[len-2] = 'D')) &
         ((name[len-1] = 'f') OR (name[len-1] = 'F'))
END IsPDFFile;

PROCEDURE MakeSaveName(img : ARRAY OF CHAR; VAR sav : ARRAY OF CHAR);
VAR i, dot : INTEGER;
BEGIN
  dot := 0;
  i   := 0;
  WHILE img[i] # 0X DO
    IF img[i] = '.' THEN dot := i END;
    INC(i)
  END;
  IF dot = 0 THEN dot := i END;
  COPY(img, sav);
  sav[dot]   := '.';
  sav[dot+1] := 's';
  sav[dot+2] := 'a';
  sav[dot+3] := 'v';
  sav[dot+4] := 0X
END MakeSaveName;

PROCEDURE SaveGame;
VAR f : Files.File;  r : Files.Rider;
    i : INTEGER;
BEGIN
  f := Files.New(saveName);
  IF f = NIL THEN RETURN END;
  Files.Set(r, f, 0);
  Files.WriteInt(r, SAVE_MAGIC);
  Files.WriteString(r, filename);
  Files.WriteInt(r, pdfPage);
  Files.WriteInt(r, nTarget);
  Files.WriteInt(r, nCols);
  Files.WriteInt(r, nRows);
  Files.WriteInt(r, nPieces);
  Files.WriteInt(r, pieceW);
  Files.WriteInt(r, pieceH);
  FOR i := 0 TO nPieces - 1 DO
    Files.WriteInt(r, FLOOR(pieceX[i]));
    Files.WriteInt(r, FLOOR(pieceY[i]));
    IF placed[i] THEN Files.WriteInt(r, 1) ELSE Files.WriteInt(r, 0) END;
    Files.WriteInt(r, drawOrd[i])
  END;
  FOR i := 0 TO nPieces - 1 DO
    Files.WriteInt(r, edgeTop[i]);
    Files.WriteInt(r, edgeRight[i]);
    Files.WriteInt(r, edgeBot[i]);
    Files.WriteInt(r, edgeLeft[i])
  END;
  Files.WriteInt(r, solvedCount);
  IF won       THEN Files.WriteInt(r, 1) ELSE Files.WriteInt(r, 0) END;
  IF showGhost THEN Files.WriteInt(r, 1) ELSE Files.WriteInt(r, 0) END;
  Files.Register(f);
  Files.Close(f)
END SaveGame;

PROCEDURE LoadGame(savefile : ARRAY OF CHAR) : BOOLEAN;
VAR f : Files.File;  r : Files.Rider;
    n, i : INTEGER;
BEGIN
  f := Files.Old(savefile);
  IF f = NIL THEN RETURN FALSE END;
  Files.Set(r, f, 0);
  Files.ReadInt(r, n);
  IF r.eof OR (n # SAVE_MAGIC) THEN Files.Close(f); RETURN FALSE END;
  Files.ReadString(r, filename);
  Files.ReadInt(r, pdfPage);
  Files.ReadInt(r, nTarget);
  Files.ReadInt(r, nCols);
  Files.ReadInt(r, nRows);
  Files.ReadInt(r, nPieces);
  Files.ReadInt(r, pieceW);
  Files.ReadInt(r, pieceH);
  FOR i := 0 TO nPieces - 1 DO
    Files.ReadInt(r, n);  pieceX[i] := FLT(n);
    Files.ReadInt(r, n);  pieceY[i] := FLT(n);
    Files.ReadInt(r, n);  placed[i] := n # 0;
    Files.ReadInt(r, drawOrd[i])
  END;
  FOR i := 0 TO nPieces - 1 DO
    Files.ReadInt(r, edgeTop[i]);
    Files.ReadInt(r, edgeRight[i]);
    Files.ReadInt(r, edgeBot[i]);
    Files.ReadInt(r, edgeLeft[i])
  END;
  Files.ReadInt(r, solvedCount);
  Files.ReadInt(r, n);  won       := n # 0;
  Files.ReadInt(r, n);  showGhost := n # 0;
  isDragging := FALSE;
  Files.Close(f);
  RETURN TRUE
END LoadGame;

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

  IF Raylib.IsKeyPressed(ORD('S')) = 1 THEN
    SaveGame;
    saveMsgTimer := 120;
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
VAR dx, dy : INTEGER;
    col    : INTEGER;
BEGIN
  dx := FLOOR(pieceX[p]) - knobPad;
  dy := FLOOR(pieceY[p]) - knobPad;
  IF pieceTex[p] # NIL THEN
    IF lifted THEN
      Raylib.DrawTexture(pieceTex[p], dx + 5, dy + 5, Raylib.Fade(cBlack, 0.35));
      col := Raylib.Fade(cWhite, 0.88)
    ELSIF placed[p] THEN
      col := cWhite   (* no shadow for settled pieces *)
    ELSE
      Raylib.DrawTexture(pieceTex[p], dx + 2, dy + 2, Raylib.Fade(cBlack, 0.25));
      col := cWhite
    END;
    Raylib.DrawTexture(pieceTex[p], dx, dy, col)
  ELSE
    (* fallback: plain rectangle if piece texture was not generated *)
    IF lifted THEN col := Raylib.Fade(cWhite, 0.88)
    ELSE           col := cWhite END;
    Raylib.DrawTexturePro(imgTex,
      PieceCol(p) * pieceW, PieceRow(p) * pieceH, pieceW, pieceH,
      FLOOR(pieceX[p]), FLOOR(pieceY[p]), dPW, dPH, col);
    IF placed[p] THEN
      Raylib.DrawRectangleLines(FLOOR(pieceX[p]), FLOOR(pieceY[p]),
                                dPW, dPH, Raylib.Fade(cGreen, 0.55))
    ELSE
      Raylib.DrawRectangleLines(FLOOR(pieceX[p]), FLOOR(pieceY[p]),
                                dPW, dPH, cDarkGray)
    END
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

  (* Faint reference image in the solved area *)
  IF showGhost THEN
    Raylib.DrawTexturePro(imgTex, 0, 0, imgW, imgH,
                          dispX, dispY, dispW, dispH,
                          Raylib.Fade(cWhite, 0.18))
  END;

  (* Grid guide lines *)
  FOR i := 0 TO nCols DO
    Raylib.DrawLine(dispX + i * dPW, dispY,
                    dispX + i * dPW, dispY + dispH,
                    Raylib.Fade(cLightGray, 0.35))
  END;
  FOR i := 0 TO nRows DO
    Raylib.DrawLine(dispX, dispY + i * dPH,
                    dispX + dispW, dispY + i * dPH,
                    Raylib.Fade(cLightGray, 0.35))
  END;
  Raylib.DrawRectangleLines(dispX - 2, dispY - 2, dispW + 4, dispH + 4, cLightGray);

  (* Placed pieces in natural order so knob/slot overlap renders correctly *)
  FOR i := 0 TO nPieces - 1 DO
    IF placed[i] THEN DrawPiece(i, FALSE) END
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

  s := "R = reshuffle   H = hint   S = save";
  Raylib.DrawText(s, scrW - Raylib.MeasureText(s, 16) - 10, 10, 16,
                  Raylib.Fade(cWhite, 0.7));

  IF saveMsgTimer > 0 THEN
    s := "Saved!";
    tw := Raylib.MeasureText(s, 20);
    Raylib.DrawText(s, (scrW - tw) DIV 2, scrH - 36, 20, cGreen);
    DEC(saveMsgTimer)
  END;

  IF won THEN
    s  := "Puzzle Complete!";
    tw := Raylib.MeasureText(s, 52);
    Raylib.DrawRectangle((scrW - tw - 40) DIV 2, scrH DIV 2 - 60,
                         tw + 40, 110, Raylib.Fade(cBlack, 0.75));
    Raylib.DrawText(s, (scrW - tw) DIV 2, scrH DIV 2 - 46, 52, cYellow);
    s  := "Press R to reshuffle";
    tw := Raylib.MeasureText(s, 24);
    Raylib.DrawText(s, (scrW - tw) DIV 2, scrH DIV 2 + 16, 24, cWhite)
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
    Out.String("Usage: jigsaw <image.jpg|image.png|image.pdf> [approx-pieces]");
    Out.Ln;
    Out.String("       jigsaw <savefile.sav>");
    Out.Ln;
    RETURN
  END;

  saveMsgTimer := 0;
  resuming     := FALSE;
  pdfPage      := -1;
  knobPad      := 0;
  scrW         := WIN_W;
  scrH         := WIN_H;
  Args.Get(1, filename);

  IF IsSaveFile(filename) THEN
    COPY(filename, saveName);
    IF ~LoadGame(saveName) THEN
      Out.String("Error: could not load save file: ");
      Out.String(saveName);
      Out.Ln;
      RETURN
    END;
    resuming := TRUE
  ELSE
    MakeSaveName(filename, saveName);
    nTarget := 20;
    IF Args.Count() >= 2 THEN
      Args.Get(2, numStr);
      IF ~Strings.StrToInt(numStr, nTarget) THEN nTarget := 20 END
    END;
    IF nTarget < 1 THEN nTarget := 1 END;
    IF nTarget > MAXPIECES THEN nTarget := MAXPIECES END;
    IF IsPDFFile(filename) THEN
      pdfPage := Raylib.CountPDFPages(filename);
      IF pdfPage < 1 THEN
        Out.String("Error: could not count PDF pages: ");
        Out.String(filename);
        Out.Ln;
        RETURN
      END;
      pdfPage := Random.Int(pdfPage)
    END
  END;

  Raylib.InitWindow(WIN_W, WIN_H, "Jigsaw Puzzle");
  Raylib.SetWindowResizable();
  Raylib.SetTargetFPS(60);

  IF pdfPage >= 0 THEN
    imgTex := Raylib.LoadTexturePDF(filename, pdfPage)
  ELSE
    imgTex := Raylib.LoadTexture(filename)
  END;
  imgW   := Raylib.TextureWidth(imgTex);
  imgH   := Raylib.TextureHeight(imgTex);

  IF (imgW <= 0) OR (imgH <= 0) THEN
    Out.String("Error: could not load image: ");
    Out.String(filename);
    Out.Ln;
    Raylib.CloseWindow;
    RETURN
  END;

  IF resuming THEN
    InitLayout;
    GenPieceTex
  ELSE
    showGhost := FALSE;
    ComputeGrid(nTarget);
    pieceW := imgW DIV nCols;
    pieceH := imgH DIV nRows;
    InitLayout;
    GenEdges;
    GenPieceTex;
    Scatter
  END;
  prevScrW := scrW;
  prevScrH := scrH;

  WHILE Raylib.WindowShouldClose() = 0 DO
    scrW := Raylib.GetScreenWidth();
    scrH := Raylib.GetScreenHeight();
    IF (scrW # prevScrW) OR (scrH # prevScrH) THEN
      InitLayout;
      RescalePieces(prevScrW, prevScrH, scrW, scrH);
      GenPieceTex;
      prevScrW := scrW;
      prevScrH := scrH
    END;
    Update;
    Draw
  END;

  FreePieceTex;
  Raylib.UnloadTexture(imgTex);
  Raylib.CloseWindow
END Jigsaw.
