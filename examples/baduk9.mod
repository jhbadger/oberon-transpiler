MODULE Baduk9;

(*
 * 9x9 Go game — human vs computer.
 *
 * Two screens (Tab to switch):
 *   Screen 0 – Move list
 *   Screen 1 – Board: yellow intersections, arrow/mouse navigation
 *
 * Board controls:
 *   Arrow keys  – move cursor
 *   Enter       – place stone
 *   P           – pass
 *   Mouse click – place stone on clicked intersection
 *   Tab         – switch screen     Ctrl-Q – quit
 *
 * Rules: captures, suicide forbidden, simple ko, area scoring.
 * AI: 1-ply lookahead with area score + positional bias.
 *)

IMPORT TUI;

CONST
  SIZE = 9;
  EMPTY = 0; BLACK = 1; WHITE = 2;

  LIST_VIEW  = 0;
  BOARD_VIEW = 1;

  BOARDX = 5; BOARDY = 2;
  CELLW  = 4; CELLH  = 2;

  MAXMOVES = 200;

TYPE
  MoveStr = ARRAY 8 OF CHAR;

VAR
  board             : ARRAY 81 OF INTEGER;
  prevBoard         : ARRAY 81 OF INTEGER;
  blackCaptures     : INTEGER;
  whiteCaptures     : INTEGER;
  lastMoveIdx       : INTEGER;
  humanColor        : INTEGER;
  compColor         : INTEGER;
  consecutivePasses : INTEGER;
  gameOver          : BOOLEAN;

  screen    : INTEGER;
  curCol    : INTEGER;
  curRow    : INTEGER;
  humanMoves: ARRAY MAXMOVES OF MoveStr;
  compMoves : ARRAY MAXMOVES OF MoveStr;
  moveCount : INTEGER;
  listTop   : INTEGER;  (* index of first visible row in list view *)
  ev        : TUI.Event;

  (* cardinal direction vectors *)
  dr : ARRAY 4 OF INTEGER;
  dc : ARRAY 4 OF INTEGER;

  (* scratch for FindGroup — only safe because nothing is reentrant *)
  ffStack  : ARRAY 81 OF INTEGER;
  ffVis    : ARRAY 81 OF BOOLEAN;
  ffStones : ARRAY 81 OF INTEGER;

  (* scratch for ScoreBoard *)
  scVis : ARRAY 81 OF BOOLEAN;
  scStk : ARRAY 81 OF INTEGER;

  (* scratch for GetComputerMove *)
  aiSave     : ARRAY 81 OF INTEGER;
  aiSavePrev : ARRAY 81 OF INTEGER;

  (* scratch for PlaceStone *)
  psSave : ARRAY 81 OF INTEGER;

  (* scratch for EvalForColor atari scan *)
  evalVis : ARRAY 81 OF BOOLEAN;

  (* scratch for NegaMax1 board save *)
  lvl1Board : ARRAY 81 OF INTEGER;
  lvl1Prev  : ARRAY 81 OF INTEGER;

(* ════════════════════════════════════════════════════════════════════ *)
(*  Board utilities                                                      *)
(* ════════════════════════════════════════════════════════════════════ *)

PROCEDURE Idx(r, c: INTEGER): INTEGER;
BEGIN RETURN r * SIZE + c END Idx;

PROCEDURE InBounds(r, c: INTEGER): BOOLEAN;
BEGIN RETURN (r >= 0) & (r < SIZE) & (c >= 0) & (c < SIZE) END InBounds;

(* ════════════════════════════════════════════════════════════════════ *)
(*  Group finding (BFS; fills ffStones, returns nStones + liberties)    *)
(* ════════════════════════════════════════════════════════════════════ *)

PROCEDURE FindGroup(startIdx, color: INTEGER; VAR nStones, liberties: INTEGER);
VAR top, i, idx, r, c, nr, nc, nidx: INTEGER;
BEGIN
  FOR i := 0 TO 80 DO ffVis[i] := FALSE END;
  nStones := 0; liberties := 0; top := 0;
  ffStack[0] := startIdx; top := 1; ffVis[startIdx] := TRUE;

  WHILE top > 0 DO
    DEC(top); idx := ffStack[top];
    ffStones[nStones] := idx; INC(nStones);
    r := idx DIV SIZE; c := idx MOD SIZE;

    FOR i := 0 TO 3 DO
      nr := r + dr[i]; nc := c + dc[i];
      IF InBounds(nr, nc) THEN
        nidx := Idx(nr, nc);
        IF ~ffVis[nidx] THEN
          IF board[nidx] = EMPTY THEN
            ffVis[nidx] := TRUE; INC(liberties)
          ELSIF board[nidx] = color THEN
            ffVis[nidx] := TRUE;
            ffStack[top] := nidx; INC(top)
          END
        END
      END
    END
  END
END FindGroup;

PROCEDURE HasLiberties(idx, color: INTEGER): BOOLEAN;
VAR n, lib: INTEGER;
BEGIN
  FindGroup(idx, color, n, lib);
  RETURN lib > 0
END HasLiberties;

PROCEDURE RemoveGroup(idx, color: INTEGER): INTEGER;
VAR n, lib, i: INTEGER;
BEGIN
  FindGroup(idx, color, n, lib);
  FOR i := 0 TO n - 1 DO board[ffStones[i]] := EMPTY END;
  RETURN n
END RemoveGroup;

(* ════════════════════════════════════════════════════════════════════ *)
(*  Ko detection                                                         *)
(* ════════════════════════════════════════════════════════════════════ *)

PROCEDURE BoardEqPrev(): BOOLEAN;
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO 80 DO
    IF board[i] # prevBoard[i] THEN RETURN FALSE END
  END;
  RETURN TRUE
END BoardEqPrev;

(* ════════════════════════════════════════════════════════════════════ *)
(*  Stone placement                                                      *)
(* ════════════════════════════════════════════════════════════════════ *)

PROCEDURE PlaceStone(r, c, color: INTEGER): BOOLEAN;
VAR idx, opp, i, nr, nc, nidx, captured: INTEGER;
BEGIN
  idx := Idx(r, c);
  IF board[idx] # EMPTY THEN RETURN FALSE END;
  opp := 3 - color;

  FOR i := 0 TO 80 DO psSave[i] := board[i] END;
  board[idx] := color;
  captured := 0;

  FOR i := 0 TO 3 DO
    nr := r + dr[i]; nc := c + dc[i];
    IF InBounds(nr, nc) THEN
      nidx := Idx(nr, nc);
      IF (board[nidx] = opp) & ~HasLiberties(nidx, opp) THEN
        captured := captured + RemoveGroup(nidx, opp)
      END
    END
  END;

  IF ~HasLiberties(idx, color) THEN
    FOR i := 0 TO 80 DO board[i] := psSave[i] END;
    RETURN FALSE
  END;

  IF BoardEqPrev() THEN
    FOR i := 0 TO 80 DO board[i] := psSave[i] END;
    RETURN FALSE
  END;

  FOR i := 0 TO 80 DO prevBoard[i] := psSave[i] END;
  IF color = BLACK THEN blackCaptures := blackCaptures + captured
  ELSE                  whiteCaptures := whiteCaptures + captured
  END;
  RETURN TRUE
END PlaceStone;

(* ════════════════════════════════════════════════════════════════════ *)
(*  Area scoring (stones on board + enclosed empty territory)           *)
(* ════════════════════════════════════════════════════════════════════ *)

PROCEDURE ScoreBoard(VAR blackScore, whiteScore: INTEGER);
VAR i, j, r, c, nr, nc, idx, nidx: INTEGER;
    top, nEmpty, touchB, touchW: INTEGER;
BEGIN
  FOR i := 0 TO 80 DO scVis[i] := FALSE END;
  blackScore := 0; whiteScore := 0;

  FOR i := 0 TO 80 DO
    IF board[i] = BLACK THEN INC(blackScore)
    ELSIF board[i] = WHITE THEN INC(whiteScore)
    END
  END;

  FOR i := 0 TO 80 DO
    IF (board[i] = EMPTY) & ~scVis[i] THEN
      nEmpty := 0; touchB := 0; touchW := 0;
      top := 0; scStk[0] := i; INC(top); scVis[i] := TRUE;

      WHILE top > 0 DO
        DEC(top); idx := scStk[top]; INC(nEmpty);
        r := idx DIV SIZE; c := idx MOD SIZE;

        FOR j := 0 TO 3 DO
          nr := r + dr[j]; nc := c + dc[j];
          IF InBounds(nr, nc) THEN
            nidx := Idx(nr, nc);
            IF board[nidx] = EMPTY THEN
              IF ~scVis[nidx] THEN
                scVis[nidx] := TRUE; scStk[top] := nidx; INC(top)
              END
            ELSIF board[nidx] = BLACK THEN INC(touchB)
            ELSE INC(touchW)
            END
          END
        END
      END;

      IF (touchB > 0) & (touchW = 0) THEN blackScore := blackScore + nEmpty
      ELSIF (touchW > 0) & (touchB = 0) THEN whiteScore := whiteScore + nEmpty
      END
    END
  END
END ScoreBoard;

(* ════════════════════════════════════════════════════════════════════ *)
(*  AI — 2-ply minimax, area score + atari detection + positional bias  *)
(* ════════════════════════════════════════════════════════════════════ *)

PROCEDURE IsSimpleEye(r, c, color: INTEGER): BOOLEAN;
VAR i, nr, nc, diagOpp: INTEGER;
    ddr, ddc: ARRAY 4 OF INTEGER;
BEGIN
  FOR i := 0 TO 3 DO
    nr := r + dr[i]; nc := c + dc[i];
    IF InBounds(nr, nc) THEN
      IF board[Idx(nr, nc)] # color THEN RETURN FALSE END
    END
  END;
  ddr[0] := -1; ddr[1] := -1; ddr[2] := 1; ddr[3] := 1;
  ddc[0] := -1; ddc[1] :=  1; ddc[2] := -1; ddc[3] := 1;
  diagOpp := 0;
  FOR i := 0 TO 3 DO
    nr := r + ddr[i]; nc := c + ddc[i];
    IF InBounds(nr, nc) THEN
      IF board[Idx(nr, nc)] # color THEN INC(diagOpp) END
    ELSE
      INC(diagOpp)
    END
  END;
  RETURN diagOpp <= 1
END IsSimpleEye;

PROCEDURE PosBonus(r, c: INTEGER): INTEGER;
VAR ar, ac: INTEGER;
BEGIN
  ar := r - 4; IF ar < 0 THEN ar := -ar END;
  ac := c - 4; IF ac < 0 THEN ac := -ac END;
  IF (ar <= 2) & (ac <= 2) THEN RETURN 2 ELSE RETURN 0 END
END PosBonus;

(* Area score × 4, then ±30 per group in atari (1 liberty). *)
PROCEDURE EvalForColor(color: INTEGER): INTEGER;
VAR i, j, n, lib, score, bs, ws: INTEGER;
BEGIN
  ScoreBoard(bs, ws);
  IF color = BLACK THEN score := (bs - ws) * 4 ELSE score := (ws - bs) * 4 END;

  FOR i := 0 TO 80 DO evalVis[i] := FALSE END;
  FOR i := 0 TO 80 DO
    IF (board[i] # EMPTY) & ~evalVis[i] THEN
      FindGroup(i, board[i], n, lib);
      FOR j := 0 TO n - 1 DO evalVis[ffStones[j]] := TRUE END;
      IF board[i] = color THEN
        IF lib = 1 THEN score := score - 30 END
      ELSE
        IF lib = 1 THEN score := score + 30 END
      END
    END
  END;
  RETURN score
END EvalForColor;

(* Try every legal move for color; return the best score achievable. *)
PROCEDURE NegaMax1(color: INTEGER): INTEGER;
VAR r, c, i, best, score, savedBCap, savedWCap: INTEGER;
BEGIN
  FOR i := 0 TO 80 DO lvl1Board[i] := board[i]; lvl1Prev[i] := prevBoard[i] END;
  savedBCap := blackCaptures; savedWCap := whiteCaptures;

  best := -9999;
  FOR r := 0 TO SIZE - 1 DO
    FOR c := 0 TO SIZE - 1 DO
      IF (board[Idx(r, c)] = EMPTY) & ~IsSimpleEye(r, c, color) THEN
        IF PlaceStone(r, c, color) THEN
          score := EvalForColor(color);
          IF score > best THEN best := score END;
          FOR i := 0 TO 80 DO board[i] := lvl1Board[i]; prevBoard[i] := lvl1Prev[i] END;
          blackCaptures := savedBCap; whiteCaptures := savedWCap
        END
      END
    END
  END;

  (* No legal moves means pass — evaluate the current position. *)
  IF best = -9999 THEN best := EvalForColor(color) END;
  RETURN best
END NegaMax1;

PROCEDURE GetComputerMove(color: INTEGER; VAR moveR, moveC: INTEGER);
VAR r, c, i, bestScore, score, savedBCap, savedWCap, opp: INTEGER;
BEGIN
  FOR i := 0 TO 80 DO
    aiSave[i] := board[i]; aiSavePrev[i] := prevBoard[i]
  END;
  savedBCap := blackCaptures; savedWCap := whiteCaptures;
  opp := 3 - color;

  moveR := -1; moveC := -1; bestScore := -9999;

  FOR r := 0 TO SIZE - 1 DO
    FOR c := 0 TO SIZE - 1 DO
      IF (board[Idx(r, c)] = EMPTY) & ~IsSimpleEye(r, c, color) THEN
        IF PlaceStone(r, c, color) THEN
          (* Opponent picks their best reply; negate → our score. *)
          score := -NegaMax1(opp) + PosBonus(r, c);

          IF score > bestScore THEN
            bestScore := score; moveR := r; moveC := c
          END;

          FOR i := 0 TO 80 DO
            board[i] := aiSave[i]; prevBoard[i] := aiSavePrev[i]
          END;
          blackCaptures := savedBCap; whiteCaptures := savedWCap
        END
      END
    END
  END
END GetComputerMove;

(* ════════════════════════════════════════════════════════════════════ *)
(*  String helpers                                                       *)
(* ════════════════════════════════════════════════════════════════════ *)

PROCEDURE MoveToStr(r, c: INTEGER; VAR s: MoveStr);
VAR col, n: INTEGER;
BEGIN
  IF r < 0 THEN
    s[0] := "p"; s[1] := "a"; s[2] := "s"; s[3] := "s"; s[4] := 0X; RETURN
  END;
  col := c; IF col >= 8 THEN INC(col) END;
  s[0] := CHR(ORD("a") + col);
  n := SIZE - r;
  IF n >= 10 THEN
    s[1] := CHR(ORD("0") + n DIV 10);
    s[2] := CHR(ORD("0") + n MOD 10); s[3] := 0X
  ELSE
    s[1] := CHR(ORD("0") + n); s[2] := 0X
  END
END MoveToStr;

(* ════════════════════════════════════════════════════════════════════ *)
(*  Drawing                                                              *)
(* ════════════════════════════════════════════════════════════════════ *)

PROCEDURE DrawStone(x, y, color: INTEGER);
VAR fg, bg: INTEGER; c0, c1: CHAR;
BEGIN
  IF color = BLACK THEN
    fg := TUI.White; bg := TUI.Black; c0 := "#"; c1 := "#"
  ELSE
    fg := TUI.Black; bg := TUI.White; c0 := "("; c1 := ")"
  END;
  TUI.PutCell(x,     y,     c0, fg, bg);
  TUI.PutCell(x + 1, y,     c1, fg, bg);
  TUI.PutCell(x,     y + 1, c0, fg, bg);
  TUI.PutCell(x + 1, y + 1, c1, fg, bg)
END DrawStone;

PROCEDURE DrawBoardScreen;
VAR r, c, idx, color, bg, sx, sy, bs, ws, col: INTEGER; ch: CHAR;
BEGIN
  TUI.ClearBack(TUI.White, TUI.Black);
  TUI.PutStr(1, 0, "Go 9x9  [Tab=Move list]  [P=Pass]  [Ctrl-Q=Quit]",
             TUI.Yellow, TUI.Black);

  FOR r := 0 TO SIZE - 1 DO
    TUI.PutInt(BOARDX - 3, BOARDY + r * CELLH, SIZE - r, TUI.White, TUI.Black)
  END;
  FOR c := 0 TO SIZE - 1 DO
    col := c; IF col >= 8 THEN INC(col) END;
    ch := CHR(ORD("a") + col);
    TUI.PutCell(BOARDX + c * CELLW + 1, BOARDY + SIZE * CELLH, ch, TUI.White, TUI.Black)
  END;

  FOR r := 0 TO SIZE - 1 DO
    FOR c := 0 TO SIZE - 1 DO
      idx := Idx(r, c); color := board[idx];

      IF (c = curCol) & (r = curRow) THEN bg := TUI.Cyan
      ELSIF idx = lastMoveIdx           THEN bg := TUI.Green
      ELSE                                   bg := TUI.Yellow
      END;

      sx := BOARDX + c * CELLW;
      sy := BOARDY + r * CELLH;
      TUI.FillRect(sx, sy, CELLW, CELLH, " ", TUI.Black, bg);

      IF color = EMPTY THEN
        IF ((r = 2) OR (r = 6)) & ((c = 2) OR (c = 6)) OR (r = 4) & (c = 4) THEN
          TUI.PutCell(sx + 1, sy, "*", TUI.Black, bg)
        ELSE
          TUI.PutCell(sx + 1, sy, ".", TUI.Black, bg)
        END
      ELSE
        DrawStone(sx + 1, sy, color)
      END
    END
  END;

  ScoreBoard(bs, ws);
  TUI.PutStr(BOARDX + SIZE * CELLW + 2, BOARDY,     "Blk:", TUI.Green,  TUI.Black);
  TUI.PutInt(BOARDX + SIZE * CELLW + 7, BOARDY,     bs,     TUI.White,  TUI.Black);
  TUI.PutStr(BOARDX + SIZE * CELLW + 2, BOARDY + 2, "Wht:", TUI.White,  TUI.Black);
  TUI.PutInt(BOARDX + SIZE * CELLW + 7, BOARDY + 2, ws,     TUI.White,  TUI.Black);
  TUI.PutStr(BOARDX + SIZE * CELLW + 2, BOARDY + 4, "BCp:", TUI.Green,  TUI.Black);
  TUI.PutInt(BOARDX + SIZE * CELLW + 7, BOARDY + 4, blackCaptures, TUI.White, TUI.Black);
  TUI.PutStr(BOARDX + SIZE * CELLW + 2, BOARDY + 6, "WCp:", TUI.White,  TUI.Black);
  TUI.PutInt(BOARDX + SIZE * CELLW + 7, BOARDY + 6, whiteCaptures, TUI.White, TUI.Black);

  IF gameOver THEN
    IF bs > ws THEN
      TUI.PutStr(1, TUI.Rows - 1, "Game over — Black wins! Ctrl-Q to quit.  ",
                 TUI.Green,  TUI.Black)
    ELSIF ws > bs THEN
      TUI.PutStr(1, TUI.Rows - 1, "Game over — White wins! Ctrl-Q to quit.  ",
                 TUI.White,  TUI.Black)
    ELSE
      TUI.PutStr(1, TUI.Rows - 1, "Game over — Tie!        Ctrl-Q to quit.  ",
                 TUI.Yellow, TUI.Black)
    END
  ELSE
    TUI.PutStr(1, TUI.Rows - 1, "Arrow=move  Enter=place  P=pass  Tab=list",
               TUI.White, TUI.Black)
  END;
  TUI.Flush
END DrawBoardScreen;

PROCEDURE DrawListScreen;
VAR i, row, maxVis, maxTop, bs, ws: INTEGER;
    numBuf: ARRAY 8 OF CHAR;
BEGIN
  maxVis := TUI.Rows - 5;

  (* Clamp listTop so we never scroll past the first or last visible move. *)
  maxTop := moveCount - maxVis;
  IF maxTop < 0 THEN maxTop := 0 END;
  IF listTop > maxTop THEN listTop := maxTop END;
  IF listTop < 0 THEN listTop := 0 END;

  TUI.ClearBack(TUI.White, TUI.Black);
  TUI.PutStr(1, 0, "Go 9x9  [Tab=Board]  [Ctrl-Q=Quit]", TUI.Yellow, TUI.Black);
  TUI.PutStr(1, 1, "#    You       Computer", TUI.Cyan, TUI.Black);

  i := listTop;
  WHILE (i < moveCount) & (i < listTop + maxVis) DO
    row := 2 + (i - listTop);
    numBuf[0] := CHR(ORD("0") + (i + 1) DIV 10);
    numBuf[1] := CHR(ORD("0") + (i + 1) MOD 10);
    numBuf[2] := "."; numBuf[3] := " "; numBuf[4] := 0X;
    TUI.PutStr(1,  row, numBuf,         TUI.White, TUI.Black);
    TUI.PutStr(5,  row, humanMoves[i],  TUI.Green, TUI.Black);
    TUI.PutStr(15, row, compMoves[i],   TUI.Red,   TUI.Black);
    INC(i)
  END;

  ScoreBoard(bs, ws);
  TUI.PutStr(1,  TUI.Rows - 3, "Score — Black:", TUI.White, TUI.Black);
  TUI.PutInt(16, TUI.Rows - 3, bs,               TUI.White, TUI.Black);
  TUI.PutStr(19, TUI.Rows - 3, "  White:",       TUI.White, TUI.Black);
  TUI.PutInt(27, TUI.Rows - 3, ws,               TUI.White, TUI.Black);

  IF gameOver THEN
    TUI.PutStr(1, TUI.Rows - 1, "Game over. Press Ctrl-Q to quit.            ",
               TUI.Red, TUI.Black)
  ELSIF moveCount > maxVis THEN
    TUI.PutStr(1, TUI.Rows - 1, "Up/Dn/PgUp/PgDn=scroll  End=latest  Tab=board",
               TUI.White, TUI.Black)
  ELSE
    TUI.PutStr(1, TUI.Rows - 1, "Tab=board view", TUI.White, TUI.Black)
  END;
  TUI.Flush
END DrawListScreen;

PROCEDURE DrawScreen;
BEGIN
  IF screen = BOARD_VIEW THEN DrawBoardScreen ELSE DrawListScreen END
END DrawScreen;

(* ════════════════════════════════════════════════════════════════════ *)
(*  Move recording                                                       *)
(* ════════════════════════════════════════════════════════════════════ *)

PROCEDURE RecordHumanMove(r, c: INTEGER);
VAR s: MoveStr;
BEGIN
  MoveToStr(r, c, s);
  IF moveCount < MAXMOVES THEN
    COPY(s, humanMoves[moveCount]); compMoves[moveCount][0] := 0X; INC(moveCount)
  END
END RecordHumanMove;

PROCEDURE RecordCompMove(r, c: INTEGER);
VAR s: MoveStr;
BEGIN
  MoveToStr(r, c, s);
  IF moveCount > 0 THEN COPY(s, compMoves[moveCount - 1]) END
END RecordCompMove;

(* ════════════════════════════════════════════════════════════════════ *)
(*  Game logic                                                           *)
(* ════════════════════════════════════════════════════════════════════ *)

PROCEDURE DoComputerMove;
VAR mr, mc: INTEGER;
BEGIN
  TUI.PutStr(1, TUI.Rows - 1, "Computer thinking...                       ",
             TUI.Yellow, TUI.Black);
  TUI.Flush;
  GetComputerMove(compColor, mr, mc);
  IF (mr >= 0) & PlaceStone(mr, mc, compColor) THEN
    lastMoveIdx := Idx(mr, mc);
    consecutivePasses := 0;
    RecordCompMove(mr, mc)
  ELSE
    INC(consecutivePasses);
    lastMoveIdx := -1;
    RecordCompMove(-1, -1);
    IF consecutivePasses >= 2 THEN gameOver := TRUE END
  END
END DoComputerMove;

PROCEDURE TryHumanMove(r, c: INTEGER): BOOLEAN;
BEGIN
  IF PlaceStone(r, c, humanColor) THEN
    consecutivePasses := 0;
    lastMoveIdx := Idx(r, c);
    RecordHumanMove(r, c);
    DoComputerMove;
    RETURN TRUE
  END;
  RETURN FALSE
END TryHumanMove;

PROCEDURE DoHumanPass;
BEGIN
  INC(consecutivePasses);
  lastMoveIdx := -1;
  RecordHumanMove(-1, -1);
  IF consecutivePasses >= 2 THEN gameOver := TRUE; RETURN END;
  DoComputerMove
END DoHumanPass;

(* ════════════════════════════════════════════════════════════════════ *)
(*  Event handlers                                                       *)
(* ════════════════════════════════════════════════════════════════════ *)

PROCEDURE HandleBoardKey(key: CHAR);
BEGIN
  IF    key = TUI.KUp    THEN IF curRow > 0        THEN DEC(curRow) END
  ELSIF key = TUI.KDown  THEN IF curRow < SIZE - 1  THEN INC(curRow) END
  ELSIF key = TUI.KLeft  THEN IF curCol > 0        THEN DEC(curCol) END
  ELSIF key = TUI.KRight THEN IF curCol < SIZE - 1  THEN INC(curCol) END
  ELSIF key = TUI.KEnter THEN
    IF ~TryHumanMove(curRow, curCol) THEN
      TUI.PutStr(1, TUI.Rows - 1, "Illegal move (occupied / suicide / ko).   ",
                 TUI.Red, TUI.Black);
      TUI.Flush
    END
  ELSIF (key = "p") OR (key = "P") THEN
    DoHumanPass
  END
END HandleBoardKey;

PROCEDURE HandleListKey(key: CHAR);
VAR maxVis: INTEGER;
BEGIN
  maxVis := TUI.Rows - 5;
  IF    key = TUI.KUp    THEN IF listTop > 0 THEN DEC(listTop) END
  ELSIF key = TUI.KDown  THEN INC(listTop)          (* clamped in DrawListScreen *)
  ELSIF key = TUI.KPgUp  THEN
    IF listTop > maxVis THEN listTop := listTop - maxVis ELSE listTop := 0 END
  ELSIF key = TUI.KPgDn  THEN listTop := listTop + maxVis  (* clamped in DrawListScreen *)
  ELSIF key = TUI.KHome  THEN listTop := 0
  ELSIF key = TUI.KEnd   THEN listTop := MAXMOVES          (* clamped to actual bottom *)
  END
END HandleListKey;

PROCEDURE HandleBoardMouse(mx, my, mb: INTEGER);
VAR col, row: INTEGER;
BEGIN
  col := (mx - BOARDX) DIV CELLW;
  row := (my - BOARDY) DIV CELLH;
  IF (col < 0) OR (col >= SIZE) OR (row < 0) OR (row >= SIZE) THEN RETURN END;
  curCol := col; curRow := row;
  IF mb = 0 THEN
    IF ~TryHumanMove(row, col) THEN
      TUI.PutStr(1, TUI.Rows - 1, "Illegal move (occupied / suicide / ko).   ",
                 TUI.Red, TUI.Black);
      TUI.Flush
    END
  END
END HandleBoardMouse;

(* ════════════════════════════════════════════════════════════════════ *)
(*  Startup                                                              *)
(* ════════════════════════════════════════════════════════════════════ *)

PROCEDURE InitGame;
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO 80 DO board[i] := EMPTY; prevBoard[i] := EMPTY END;
  blackCaptures := 0; whiteCaptures := 0;
  lastMoveIdx := -1; consecutivePasses := 0; gameOver := FALSE;
  moveCount := 0; listTop := 0; curCol := 4; curRow := 4;
  screen := BOARD_VIEW
END InitGame;

PROCEDURE ChooseSide;
VAR ev2: TUI.Event;
BEGIN
  TUI.ClearBack(TUI.White, TUI.Black);
  TUI.PutStr(4, 4, "Go 9x9 — choose your color",            TUI.Yellow, TUI.Black);
  TUI.PutStr(4, 6, "B  Play Black (you move first)",        TUI.Green,  TUI.Black);
  TUI.PutStr(4, 7, "W  Play White (computer moves first)",  TUI.White,  TUI.Black);
  TUI.PutStr(4, 9, "Press B or W:",                          TUI.Cyan,   TUI.Black);
  TUI.Flush;
  humanColor := BLACK; compColor := WHITE;
  LOOP
    TUI.WaitEvent(ev2);
    IF ev2.kind = TUI.EvKey THEN
      IF (ev2.key = "b") OR (ev2.key = "B") THEN
        humanColor := BLACK; compColor := WHITE; EXIT
      ELSIF (ev2.key = "w") OR (ev2.key = "W") THEN
        humanColor := WHITE; compColor := BLACK; EXIT
      ELSIF ev2.key = 17 THEN
        TUI.Done; HALT(0)
      END
    END
  END
END ChooseSide;

PROCEDURE Play;
BEGIN
  TUI.Init;
  TUI.UpdateSize;
  InitGame;
  ChooseSide;
  IF compColor = BLACK THEN DoComputerMove END;
  DrawScreen;

  LOOP
    TUI.WaitEvent(ev);
    IF ev.kind = TUI.EvKey THEN
      IF ev.key = 17 THEN EXIT END;
      IF ev.key = TUI.KTab THEN
        IF screen = BOARD_VIEW THEN
          screen := LIST_VIEW; listTop := MAXMOVES  (* show latest; clamped on draw *)
        ELSE
          screen := BOARD_VIEW
        END
      ELSE
        IF screen = BOARD_VIEW THEN
          IF ~gameOver THEN HandleBoardKey(ev.key) END
        ELSE
          HandleListKey(ev.key)
        END
      END;
      DrawScreen
    ELSIF ev.kind = TUI.EvMouse THEN
      IF (screen = BOARD_VIEW) & ~gameOver THEN HandleBoardMouse(ev.mx, ev.my, ev.mb) END;
      DrawScreen
    ELSIF ev.kind = TUI.EvResize THEN
      TUI.UpdateSize; DrawScreen
    END
  END;

  TUI.Done
END Play;

BEGIN
  dr[0] := -1; dr[1] := 1; dr[2] := 0; dr[3] := 0;
  dc[0] :=  0; dc[1] := 0; dc[2] := -1; dc[3] := 1;
  Play
END Baduk9.
