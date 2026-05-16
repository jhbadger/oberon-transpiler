MODULE AntiClerical;

(*
 * Anti-Clerical Chess (Los Alamos Chess) — a 6×6 chess variant created
 * for early computers that eliminated bishops and simplified the rules.
 *
 * Differences from standard chess:
 *   • 6×6 board (files a–f, ranks 1–6)
 *   • No bishops — pieces are Rook, Knight, Queen, King, Knight, Rook
 *   • No castling
 *   • No en passant
 *   • Pawns may only move one square forward (no initial double push)
 *
 * Controls (same as chess.mod):
 *   Tab              – switch between board and move-list screens
 *   Arrow keys/mouse – move cursor
 *   Enter/click      – pick piece / confirm destination
 *   Ctrl-Q           – quit
 *)

IMPORT TUI;

CONST
  EMPTY  = 0; PAWN   = 1; ROOK  = 2; KNIGHT = 3;
  BISHOP = 4; QUEEN  = 5; KING  = 6; FRONTIER = 7;
  SIDE   = 32;

CONST
  LIST  = 0;  BOARD = 1;

  BOARDX = 6;  BOARDY = 2;
  CELLW  = 4;  CELLH  = 2;

  LIGHT_BG  = 3;
  DARK_BG   = 4;
  SEL_BG    = 2;
  CURSOR_BG = 6;

  MAXMOVES = 200;

TYPE
  MoveStr = ARRAY 10 OF CHAR;

VAR
  board       : ARRAY 128 OF INTEGER;
  pieceValues : ARRAY 7  OF INTEGER;
  maxDepth    : INTEGER;

  rookVec, bishopVec: ARRAY 4 OF INTEGER;
  knightVec         : ARRAY 8 OF INTEGER;

VAR
  screen              : INTEGER;
  humanSide, compSide : INTEGER;
  gameOver            : BOOLEAN;

  humanMoves : ARRAY MAXMOVES OF MoveStr;
  compMoves  : ARRAY MAXMOVES OF MoveStr;
  moveCount  : INTEGER;

  curCol, curRow : INTEGER;
  selSquare      : INTEGER;

  inputBuf : ARRAY 16 OF CHAR;
  inputLen : INTEGER;

  ev: TUI.Event;

(* ══════════════════════════════════════════════════════════════════ *)
(*  Chess engine                                                       *)
(* ══════════════════════════════════════════════════════════════════ *)

PROCEDURE IsOnBoard(pos: INTEGER): BOOLEAN;
BEGIN
  RETURN (pos >= 0) & (pos < 96) & (pos MOD 16 < 6)
END IsOnBoard;

PROCEDURE KingPos(side: INTEGER): INTEGER;
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO 95 DO
    IF IsOnBoard(i) & (board[i] MOD 8 = KING) &
       (((board[i] DIV SIDE) MOD 2) * SIDE = side) THEN RETURN i END
  END;
  RETURN -1
END KingPos;

PROCEDURE KingFound(side: INTEGER): BOOLEAN;
BEGIN RETURN KingPos(side) >= 0 END KingFound;

PROCEDURE IsAttacked(pos, bySide: INTEGER): BOOLEAN;
VAR i, sq: INTEGER;
BEGIN
  FOR i := 0 TO 7 DO
    sq := pos + knightVec[i];
    IF IsOnBoard(sq) & (board[sq] MOD 8 = KNIGHT) &
       (((board[sq] DIV SIDE) MOD 2) * SIDE = bySide) THEN RETURN TRUE END
  END;
  FOR i := 0 TO 3 DO
    sq := pos + rookVec[i];
    LOOP
      IF ~IsOnBoard(sq) THEN EXIT END;
      IF board[sq] # EMPTY THEN
        IF (((board[sq] DIV SIDE) MOD 2) * SIDE = bySide) &
           ((board[sq] MOD 8 = ROOK) OR (board[sq] MOD 8 = QUEEN)) THEN
          RETURN TRUE
        END;
        EXIT
      END;
      sq := sq + rookVec[i]
    END
  END;
  FOR i := 0 TO 3 DO
    sq := pos + bishopVec[i];
    LOOP
      IF ~IsOnBoard(sq) THEN EXIT END;
      IF board[sq] # EMPTY THEN
        IF (((board[sq] DIV SIDE) MOD 2) * SIDE = bySide) &
           (board[sq] MOD 8 = QUEEN) THEN
          RETURN TRUE
        END;
        EXIT
      END;
      sq := sq + bishopVec[i]
    END
  END;
  FOR i := 0 TO 3 DO
    sq := pos + rookVec[i];
    IF IsOnBoard(sq) & (board[sq] MOD 8 = KING) &
       (((board[sq] DIV SIDE) MOD 2) * SIDE = bySide) THEN RETURN TRUE END;
    sq := pos + bishopVec[i];
    IF IsOnBoard(sq) & (board[sq] MOD 8 = KING) &
       (((board[sq] DIV SIDE) MOD 2) * SIDE = bySide) THEN RETURN TRUE END;
  END;
  IF bySide = SIDE THEN
    sq := pos + 17;
    IF IsOnBoard(sq) & (board[sq] MOD 8 = PAWN) &
       (((board[sq] DIV SIDE) MOD 2) * SIDE = SIDE) THEN RETURN TRUE END;
    sq := pos + 15;
    IF IsOnBoard(sq) & (board[sq] MOD 8 = PAWN) &
       (((board[sq] DIV SIDE) MOD 2) * SIDE = SIDE) THEN RETURN TRUE END
  ELSE
    sq := pos - 17;
    IF IsOnBoard(sq) & (board[sq] MOD 8 = PAWN) &
       (((board[sq] DIV SIDE) MOD 2) * SIDE = 0) THEN RETURN TRUE END;
    sq := pos - 15;
    IF IsOnBoard(sq) & (board[sq] MOD 8 = PAWN) &
       (((board[sq] DIV SIDE) MOD 2) * SIDE = 0) THEN RETURN TRUE END
  END;
  RETURN FALSE
END IsAttacked;

PROCEDURE InCheck(side: INTEGER): BOOLEAN;
VAR kp: INTEGER;
BEGIN
  kp := KingPos(side);
  IF kp < 0 THEN RETURN FALSE END;
  RETURN IsAttacked(kp, SIDE - side)
END InCheck;

PROCEDURE InitBoard;
VAR i: INTEGER; rank: ARRAY 6 OF INTEGER;
BEGIN
  (* 6x6: RNQKNR — no bishops *)
  rank[0] := ROOK; rank[1] := KNIGHT; rank[2] := QUEEN;
  rank[3] := KING; rank[4] := KNIGHT; rank[5] := ROOK;
  FOR i := 0 TO 127 DO
    IF ~IsOnBoard(i) THEN board[i] := FRONTIER ELSE board[i] := EMPTY END
  END;
  FOR i := 0 TO 5 DO
    board[i]      := rank[i];          (* black back rank, row 0 *)
    board[i + 16] := PAWN;             (* black pawns,     row 1 *)
    board[i + 64] := PAWN + SIDE;      (* white pawns,     row 4 *)
    board[i + 80] := rank[i] + SIDE;   (* white back rank, row 5 *)
  END;
END InitBoard;

PROCEDURE ApplyMove(from, to, side: INTEGER; VAR promoted: BOOLEAN): BOOLEAN;
VAR movingP, savedTarget: INTEGER;
BEGIN
  promoted := FALSE;
  IF ~IsOnBoard(from) OR ~IsOnBoard(to) THEN RETURN FALSE END;
  movingP := board[from];
  IF (movingP = EMPTY) OR (((movingP DIV SIDE) MOD 2) * SIDE # side) THEN RETURN FALSE END;
  IF (board[to] # EMPTY) & (((board[to] DIV SIDE) MOD 2) * SIDE = side) THEN RETURN FALSE END;

  IF movingP MOD 8 = PAWN THEN
    IF side = SIDE THEN
      IF to = from - 16 THEN
        IF board[to] # EMPTY THEN RETURN FALSE END
      ELSIF (to = from - 17) OR (to = from - 15) THEN
        IF board[to] = EMPTY THEN RETURN FALSE END
      ELSE RETURN FALSE
      END
    ELSE
      IF to = from + 16 THEN
        IF board[to] # EMPTY THEN RETURN FALSE END
      ELSIF (to = from + 17) OR (to = from + 15) THEN
        IF board[to] = EMPTY THEN RETURN FALSE END
      ELSE RETURN FALSE
      END
    END
  END;

  savedTarget := board[to];
  board[to] := movingP; board[from] := EMPTY;

  IF InCheck(side) THEN
    board[from] := movingP; board[to] := savedTarget;
    RETURN FALSE
  END;

  (* White promotes reaching row 0 (to < 8), black reaching row 5 (to >= 80) *)
  IF (movingP MOD 8 = PAWN) &
     (((side = SIDE) & (to < 8)) OR ((side = 0) & (to >= 80))) THEN
    board[to] := QUEEN + side; promoted := TRUE;
  END;

  RETURN TRUE
END ApplyMove;

PROCEDURE Evaluate(turn, depth, alpha, beta: INTEGER; VAR bestF, bestT: INTEGER): INTEGER;
VAR f, p, i, step, target, score, bestScore, captured, movingP: INTEGER;
    dF, dT: INTEGER;
    isPawnDiag: BOOLEAN;
    captureValue: INTEGER;
BEGIN
  IF depth = 0 THEN RETURN 0 END;
  bestScore := alpha;
  FOR f := 0 TO 95 DO
    IF IsOnBoard(f) & (board[f] # EMPTY) & (((board[f] DIV SIDE) MOD 2) * SIDE = turn) THEN
      p := board[f] MOD 8;
      FOR i := 0 TO 7 DO
        step := 0; isPawnDiag := FALSE;
        IF p = ROOK THEN IF i < 4 THEN step := rookVec[i] END;
        ELSIF p = KNIGHT THEN step := knightVec[i];
        ELSIF (p = QUEEN) OR (p = KING) THEN
          IF i < 4 THEN step := rookVec[i] ELSE step := bishopVec[i-4] END;
        ELSIF p = PAWN THEN
          IF turn = SIDE THEN
            IF    i = 0 THEN step := -16
            ELSIF i = 2 THEN step := -17; isPawnDiag := TRUE
            ELSIF i = 3 THEN step := -15; isPawnDiag := TRUE
            END;
          ELSE
            IF    i = 0 THEN step := 16
            ELSIF i = 2 THEN step := 17; isPawnDiag := TRUE
            ELSIF i = 3 THEN step := 15; isPawnDiag := TRUE
            END;
          END;
        END;
        IF step # 0 THEN
          target := f;
          LOOP
            target := target + step;
            IF ~IsOnBoard(target) THEN EXIT END;
            captured := board[target];
            IF (captured # EMPTY) & (((captured DIV SIDE) MOD 2) * SIDE = turn) THEN EXIT END;
            IF p = PAWN THEN
              IF isPawnDiag THEN
                IF captured = EMPTY THEN EXIT END;
              ELSE
                IF captured # EMPTY THEN EXIT END;
              END;
            END;
            movingP := board[f];
            board[target] := movingP; board[f] := EMPTY;
            IF (p = PAWN) & ((target < 8) OR (target >= 80)) THEN
              IF turn = SIDE THEN board[target] := QUEEN + SIDE
              ELSE board[target] := QUEEN END;
            END;
            IF ~InCheck(turn) THEN
              captureValue := pieceValues[captured MOD 8];
              IF (p = PAWN) & ((target < 8) OR (target >= 80)) THEN
                captureValue := captureValue + pieceValues[QUEEN] - pieceValues[PAWN];
              END;
              score := captureValue - Evaluate(SIDE - turn, depth - 1,
                         captureValue - beta, captureValue - alpha, dF, dT);
              board[f] := movingP; board[target] := captured;
              IF score > bestScore THEN
                bestScore := score;
                IF depth = maxDepth THEN bestF := f; bestT := target END;
                alpha := bestScore;
                IF alpha >= beta THEN RETURN bestScore END;
              END;
            ELSE
              board[f] := movingP; board[target] := captured;
            END;
            IF (captured # EMPTY) OR (p = KNIGHT) OR (p = KING) OR (p = PAWN) THEN EXIT END;
          END;
        END;
      END;
    END;
  END;
  RETURN bestScore
END Evaluate;

PROCEDURE GetComputerMove(side: INTEGER; VAR from, to: INTEGER);
VAR score: INTEGER;
BEGIN
  from := -1; to := -1;
  score := Evaluate(side, maxDepth, -2000, 2000, from, to);
END GetComputerMove;

(* ══════════════════════════════════════════════════════════════════ *)
(*  Helpers                                                            *)
(* ══════════════════════════════════════════════════════════════════ *)

PROCEDURE MoveToStr(from, to: INTEGER; VAR s: MoveStr);
BEGIN
  s[0] := CHR(ORD("a") + (from MOD 16));
  s[1] := CHR(ORD("0") + 6 - (from DIV 16));
  s[2] := CHR(ORD("a") + (to   MOD 16));
  s[3] := CHR(ORD("0") + 6 - (to   DIV 16));
  s[4] := 0X;
END MoveToStr;

PROCEDURE ParseAlg(s: ARRAY OF CHAR; VAR from, to: INTEGER): BOOLEAN;
BEGIN
  IF (s[0] < "a") OR (s[0] > "f") THEN RETURN FALSE END;
  IF (s[1] < "1") OR (s[1] > "6") THEN RETURN FALSE END;
  IF (s[2] < "a") OR (s[2] > "f") THEN RETURN FALSE END;
  IF (s[3] < "1") OR (s[3] > "6") THEN RETURN FALSE END;
  from := (6 - (ORD(s[1]) - ORD("0"))) * 16 + (ORD(s[0]) - ORD("a"));
  to   := (6 - (ORD(s[3]) - ORD("0"))) * 16 + (ORD(s[2]) - ORD("a"));
  RETURN TRUE
END ParseAlg;

(* ══════════════════════════════════════════════════════════════════ *)
(*  Drawing                                                            *)
(* ══════════════════════════════════════════════════════════════════ *)

PROCEDURE DrawPiece(x, y, piece, bg: INTEGER);
VAR t, pfg: INTEGER; c0, c1, letter: CHAR;
BEGIN
  t := piece MOD 8;
  IF t = 0 THEN RETURN END;

  IF ((piece DIV SIDE) MOD 2) = 1 THEN pfg := TUI.White
  ELSE                                  pfg := TUI.Red
  END;

  IF    t = PAWN   THEN c0 := "("; c1 := ")"; letter := "P"
  ELSIF t = ROOK   THEN c0 := "["; c1 := "]"; letter := "R"
  ELSIF t = KNIGHT THEN c0 := "~"; c1 := "~"; letter := "N"
  ELSIF t = QUEEN  THEN c0 := "*"; c1 := "*"; letter := "Q"
  ELSE                   c0 := "+"; c1 := "+"; letter := "K"
  END;

  IF ((piece DIV SIDE) MOD 2) = 0 THEN letter := CHR(ORD(letter) + 32) END;

  TUI.PutCell(x,     y,     c0,     pfg, bg);
  TUI.PutCell(x + 1, y,     c1,     pfg, bg);
  TUI.PutCell(x,     y + 1, letter, pfg, bg);
  TUI.PutCell(x + 1, y + 1, letter, pfg, bg)
END DrawPiece;

PROCEDURE DrawBoardScreen;
VAR r, c, sq, piece, bg, fg, sx, sy: INTEGER; ch: CHAR;
BEGIN
  TUI.ClearBack(TUI.White, TUI.Black);
  TUI.PutStr(0, 0, "Anti-Clerical Chess  [Tab=Move list]  [Ctrl-Q=Quit]", TUI.Yellow, TUI.Black);

  FOR r := 0 TO 5 DO
    ch := CHR(ORD("6") - r);
    TUI.PutCell(BOARDX - 2, BOARDY + r * CELLH, ch, TUI.White, TUI.Black);
  END;
  FOR c := 0 TO 5 DO
    ch := CHR(ORD("a") + c);
    TUI.PutCell(BOARDX + c * CELLW + 1, BOARDY + 6 * CELLH, ch, TUI.White, TUI.Black);
  END;

  FOR r := 0 TO 5 DO
    FOR c := 0 TO 5 DO
      sq    := r * 16 + c;
      piece := board[sq];

      IF (c = curCol) & (r = curRow) THEN bg := CURSOR_BG; fg := TUI.Black
      ELSIF sq = selSquare             THEN bg := SEL_BG;    fg := TUI.Black
      ELSIF (r + c) MOD 2 = 0         THEN bg := LIGHT_BG;  fg := TUI.Black
      ELSE                                  bg := DARK_BG;   fg := TUI.White
      END;

      sx := BOARDX + c * CELLW;
      sy := BOARDY + r * CELLH;
      TUI.FillRect(sx, sy, CELLW, CELLH, " ", fg, bg);
      DrawPiece(sx + 1, sy, piece, bg);
    END
  END;

  IF gameOver THEN
    TUI.PutStr(0, TUI.Rows-1, "Game over. Press Ctrl-Q to quit.       ", TUI.Red,   TUI.Black);
  ELSIF selSquare >= 0 THEN
    TUI.PutStr(0, TUI.Rows-1, "Select destination (Enter/click).   ", TUI.Cyan,  TUI.Black);
  ELSE
    TUI.PutStr(0, TUI.Rows-1, "Select piece (Enter/click). Tab=list", TUI.White, TUI.Black);
  END;
  TUI.Flush
END DrawBoardScreen;

PROCEDURE DrawListScreen;
VAR i, row, startRow, maxVis, promptY: INTEGER;
    numBuf: ARRAY 8 OF CHAR;
BEGIN
  TUI.ClearBack(TUI.White, TUI.Black);
  TUI.PutStr(0, 0, "Anti-Clerical Chess  [Tab=Board view]  [Ctrl-Q=Quit]", TUI.Yellow, TUI.Black);
  TUI.PutStr(1, 1, "#    Your move  Computer", TUI.Cyan, TUI.Black);

  maxVis   := TUI.Rows - 5;
  startRow := moveCount - maxVis;
  IF startRow < 0 THEN startRow := 0 END;

  FOR i := startRow TO moveCount - 1 DO
    row := 2 + (i - startRow);
    numBuf[0] := CHR(ORD("0") + (i + 1) DIV 10);
    numBuf[1] := CHR(ORD("0") + (i + 1) MOD 10);
    numBuf[2] := "."; numBuf[3] := " "; numBuf[4] := 0X;
    TUI.PutStr(1,  row, numBuf,        TUI.White, TUI.Black);
    TUI.PutStr(5,  row, humanMoves[i], TUI.Green, TUI.Black);
    TUI.PutStr(17, row, compMoves[i],  TUI.Red,   TUI.Black);
  END;

  promptY := TUI.Rows - 3;
  TUI.PutStr(0, promptY, "Move: ",  TUI.White,  TUI.Black);
  TUI.PutStr(6, promptY, inputBuf,  TUI.Yellow, TUI.Black);
  TUI.SetCursor(6 + inputLen, promptY);

  IF gameOver THEN
    TUI.PutStr(0, TUI.Rows-1, "Game over. Press Ctrl-Q to quit.", TUI.Red, TUI.Black);
  ELSE
    TUI.PutStr(0, TUI.Rows-1, "Type move (e.g. a2a3) then Enter.", TUI.White, TUI.Black);
  END;
  TUI.Flush
END DrawListScreen;

PROCEDURE DrawScreen;
BEGIN
  IF screen = BOARD THEN DrawBoardScreen ELSE DrawListScreen END
END DrawScreen;

(* ══════════════════════════════════════════════════════════════════ *)
(*  Game logic                                                         *)
(* ══════════════════════════════════════════════════════════════════ *)

PROCEDURE DoComputerMove;
VAR bf, bt: INTEGER; promoted: BOOLEAN;
BEGIN
  TUI.PutStr(0, TUI.Rows-1, "Computer is thinking...             ", TUI.Yellow, TUI.Black);
  TUI.Flush;
  GetComputerMove(compSide, bf, bt);
  IF ~IsOnBoard(bf) OR ~IsOnBoard(bt) THEN gameOver := TRUE; RETURN END;
  IF ApplyMove(bf, bt, compSide, promoted) THEN
    IF moveCount > 0 THEN MoveToStr(bf, bt, compMoves[moveCount - 1]) END;
    IF ~KingFound(humanSide) THEN gameOver := TRUE END;
  ELSE
    gameOver := TRUE
  END
END DoComputerMove;

PROCEDURE TryHumanMove(from, to: INTEGER): BOOLEAN;
VAR promoted: BOOLEAN; s: MoveStr;
BEGIN
  IF ApplyMove(from, to, humanSide, promoted) THEN
    MoveToStr(from, to, s);
    IF promoted THEN s[4] := "="; s[5] := "Q"; s[6] := 0X END;
    IF moveCount < MAXMOVES THEN
      COPY(s, humanMoves[moveCount]);
      compMoves[moveCount][0] := 0X;
      INC(moveCount);
    END;
    IF ~KingFound(compSide) THEN gameOver := TRUE; RETURN TRUE END;
    DoComputerMove;
    RETURN TRUE
  END;
  RETURN FALSE
END TryHumanMove;

(* ══════════════════════════════════════════════════════════════════ *)
(*  Event handlers                                                     *)
(* ══════════════════════════════════════════════════════════════════ *)

PROCEDURE HandleBoardKey(key: CHAR);
VAR sq, from, to: INTEGER;
BEGIN
  IF    key = TUI.KUp    THEN IF curRow > 0 THEN DEC(curRow) END
  ELSIF key = TUI.KDown  THEN IF curRow < 5 THEN INC(curRow) END
  ELSIF key = TUI.KLeft  THEN IF curCol > 0 THEN DEC(curCol) END
  ELSIF key = TUI.KRight THEN IF curCol < 5 THEN INC(curCol) END
  ELSIF key = TUI.KEnter THEN
    sq := curRow * 16 + curCol;
    IF selSquare < 0 THEN
      IF (board[sq] # EMPTY) & (((board[sq] DIV SIDE) MOD 2) * SIDE = humanSide) THEN
        selSquare := sq
      END
    ELSIF (board[sq] # EMPTY) &
          (((board[sq] DIV SIDE) MOD 2) * SIDE = humanSide) THEN
      selSquare := sq
    ELSE
      from := selSquare; to := sq; selSquare := -1;
      IF ~TryHumanMove(from, to) THEN
        TUI.PutStr(0, TUI.Rows-1, "Illegal move.                       ", TUI.Red, TUI.Black);
        TUI.Flush
      END
    END
  END
END HandleBoardKey;

PROCEDURE HandleBoardMouse(mx, my, mb: INTEGER);
VAR col, row, sq, from, to: INTEGER;
BEGIN
  col := (mx - BOARDX) DIV CELLW;
  row := (my - BOARDY) DIV CELLH;
  IF (col < 0) OR (col > 5) OR (row < 0) OR (row > 5) THEN RETURN END;
  sq := row * 16 + col;
  curCol := col; curRow := row;
  IF mb = 0 THEN
    IF selSquare < 0 THEN
      IF (board[sq] # EMPTY) & (((board[sq] DIV SIDE) MOD 2) * SIDE = humanSide) THEN
        selSquare := sq
      END
    ELSIF (board[sq] # EMPTY) &
          (((board[sq] DIV SIDE) MOD 2) * SIDE = humanSide) THEN
      selSquare := sq
    ELSE
      from := selSquare; to := sq; selSquare := -1;
      IF ~TryHumanMove(from, to) THEN
        TUI.PutStr(0, TUI.Rows-1, "Illegal move.                       ", TUI.Red, TUI.Black);
        TUI.Flush
      END
    END
  END
END HandleBoardMouse;

PROCEDURE HandleListKey(key: CHAR);
VAR from, to: INTEGER;
BEGIN
  IF key = TUI.KEnter THEN
    IF inputLen = 0 THEN RETURN END;
    inputBuf[inputLen] := 0X;
    IF ParseAlg(inputBuf, from, to) THEN
      IF ~TryHumanMove(from, to) THEN
        TUI.PutStr(0, TUI.Rows-1, "Illegal move.                       ", TUI.Red, TUI.Black);
        TUI.Flush
      END
    ELSE
      TUI.PutStr(0, TUI.Rows-1, "Bad format — use a2a3.              ", TUI.Red, TUI.Black);
      TUI.Flush
    END;
    inputLen := 0; inputBuf[0] := 0X;
  ELSIF key = TUI.KBackspace THEN
    IF inputLen > 0 THEN DEC(inputLen); inputBuf[inputLen] := 0X END
  ELSIF ((key >= "a") & (key <= "f")) OR ((key >= "1") & (key <= "6")) THEN
    IF inputLen < 4 THEN inputBuf[inputLen] := key; INC(inputLen) END
  END
END HandleListKey;

(* ══════════════════════════════════════════════════════════════════ *)
(*  Startup                                                            *)
(* ══════════════════════════════════════════════════════════════════ *)

PROCEDURE ChooseSide;
VAR ev2: TUI.Event;
BEGIN
  TUI.ClearBack(TUI.White, TUI.Black);
  TUI.PutStr(4, 4,  "Anti-Clerical Chess (Los Alamos) — choose your side", TUI.Yellow, TUI.Black);
  TUI.PutStr(4, 6,  "W  Play White (you move first)",        TUI.White, TUI.Black);
  TUI.PutStr(4, 7,  "B  Play Black (computer moves first)",  TUI.White, TUI.Black);
  TUI.PutStr(4, 9,  "Search depth  1=easy  3=medium  5=hard", TUI.Cyan, TUI.Black);
  TUI.PutStr(4, 10, "Press 1, 3, or 5 then W or B:",         TUI.White, TUI.Black);
  TUI.Flush;

  maxDepth  := 3;
  humanSide := SIDE; compSide := 0;

  LOOP
    TUI.WaitEvent(ev2);
    IF ev2.kind = TUI.EvKey THEN
      IF    ev2.key = "1" THEN maxDepth := 1
      ELSIF ev2.key = "3" THEN maxDepth := 3
      ELSIF ev2.key = "5" THEN maxDepth := 5
      ELSIF (ev2.key = "w") OR (ev2.key = "W") THEN
        humanSide := SIDE; compSide := 0; EXIT
      ELSIF (ev2.key = "b") OR (ev2.key = "B") THEN
        humanSide := 0; compSide := SIDE; EXIT
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
  InitBoard;
  ChooseSide;

  screen    := BOARD;
  gameOver  := FALSE;
  moveCount := 0;
  curCol    := 0; curRow    := 0;
  selSquare := -1;
  inputLen  := 0; inputBuf[0] := 0X;

  IF compSide = SIDE THEN DoComputerMove END;
  DrawScreen;

  LOOP
    TUI.WaitEvent(ev);
    IF ev.kind = TUI.EvKey THEN
      IF ev.key = 17 THEN EXIT END;
      IF ev.key = TUI.KTab THEN
        IF screen = BOARD THEN screen := LIST ELSE screen := BOARD END
      ELSIF ~gameOver THEN
        IF screen = BOARD THEN HandleBoardKey(ev.key)
        ELSE HandleListKey(ev.key)
        END
      END;
      DrawScreen;
    ELSIF ev.kind = TUI.EvMouse THEN
      IF (screen = BOARD) & ~gameOver THEN HandleBoardMouse(ev.mx, ev.my, ev.mb) END;
      DrawScreen;
    ELSIF ev.kind = TUI.EvResize THEN
      TUI.UpdateSize; DrawScreen;
    END
  END;

  TUI.Done
END Play;

BEGIN
  pieceValues[EMPTY]  := 0;
  pieceValues[PAWN]   := 10;
  pieceValues[ROOK]   := 50;
  pieceValues[KNIGHT] := 30;
  pieceValues[BISHOP] := 0;   (* unused — no bishops in Los Alamos chess *)
  pieceValues[QUEEN]  := 90;
  pieceValues[KING]   := 999;
  rookVec[0]   := -16; rookVec[1]   := 16;  rookVec[2]   := -1; rookVec[3]   := 1;
  bishopVec[0] := -17; bishopVec[1] := -15; bishopVec[2] := 17; bishopVec[3] := 15;
  knightVec[0] := -33; knightVec[1] := -31; knightVec[2] := -18; knightVec[3] := -14;
  knightVec[4] :=  14; knightVec[5] :=  18; knightVec[6] :=  31; knightVec[7] :=  33;
  Play
END AntiClerical.

