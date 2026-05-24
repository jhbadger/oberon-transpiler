MODULE Xiangqi;

(*
 * Xiangqi (Chinese Chess) — self-contained engine and TUI front-end.
 *
 * Tab switches between two screens:
 *   Screen 0 – Move list: two-column history + coordinate-notation input
 *   Screen 1 – Board:     9×10 board, arrow/mouse navigation
 *
 * Board controls:
 *   Arrow keys  – move cursor
 *   Enter       – pick piece / confirm destination
 *   Mouse click – same as Enter on the clicked square
 *   Tab         – switch screen     Ctrl-Q – quit
 *
 * Notation: column a–i (left-right), row 0–9 (0=black back rank, 9=red back rank)
 *   e.g. "e9e8" moves the piece at e9 one step forward (red)
 *
 * Piece art (2×2 cells; Red=bright/uppercase, Black=red/lowercase):
 *   General  ++  G/g   Advisor  /\  A/a   Elephant <>  E/e
 *   Chariot  []  R/r   Horse    ^^  H/h   Cannon   !!  C/c
 *   Soldier  ()  S/s
 *
 * Special rules:
 *   General + Advisor confined to palace (cols d–f, rows 0–2 or 7–9)
 *   Elephant cannot cross river; blocked by piece at midpoint diagonal
 *   Horse leg blocked by orthogonally adjacent piece
 *   Cannon slides to empty squares; captures by jumping over exactly one piece
 *   Soldier advances forward; after crossing river, may also move sideways
 *   Flying General: generals may not face each other on an open file
 *)

IMPORT TUI;

CONST
  EMPTY    = 0; SOLDIER  = 1; CHARIOT  = 2; HORSE    = 3;
  ELEPHANT = 4; CANNON   = 5; GENERAL  = 6; ADVISOR  = 7;
  SIDE     = 32;

CONST
  LIST  = 0;  BOARD = 1;

  BOARDX = 4;  BOARDY = 2;
  CELLW  = 4;  CELLH  = 2;

  RED_BG    = 3;
  BLACK_BG  = 4;
  SEL_BG    = 2;
  CURSOR_BG = 6;

  MAXMOVES = 200;

TYPE
  MoveStr = ARRAY 10 OF CHAR;

VAR
  board        : ARRAY 160 OF INTEGER;
  pieceValues  : ARRAY 8   OF INTEGER;
  maxDepth     : INTEGER;

  rookVec      : ARRAY 4 OF INTEGER;
  bishopVec    : ARRAY 4 OF INTEGER;
  horseVec     : ARRAY 8 OF INTEGER;
  horseBlock   : ARRAY 8 OF INTEGER;
  elephantVec  : ARRAY 4 OF INTEGER;
  elephantBlock: ARRAY 4 OF INTEGER;

VAR
  screen              : INTEGER;
  humanSide, compSide : INTEGER;
  gameOver            : BOOLEAN;
  gameResult          : INTEGER;  (* 0=ongoing 1=comp wins 2=stalemate 3=human wins *)

  humanMoves : ARRAY MAXMOVES OF MoveStr;
  compMoves  : ARRAY MAXMOVES OF MoveStr;
  moveCount  : INTEGER;
  listTop    : INTEGER;

  curCol, curRow : INTEGER;
  selSquare      : INTEGER;

  inputBuf : ARRAY 16 OF CHAR;
  inputLen : INTEGER;

  ev : TUI.Event;

  boardHistory         : ARRAY MAXMOVES OF ARRAY 160 OF INTEGER;
  suggestFrom, suggestTo : INTEGER;

(* ══════════════════════════════════════════════════════════════════ *)
(*  Board geometry                                                     *)
(* ══════════════════════════════════════════════════════════════════ *)

PROCEDURE IsOnBoard(pos: INTEGER): BOOLEAN;
BEGIN
  RETURN (pos >= 0) & (pos < 160) & (pos MOD 16 <= 8)
END IsOnBoard;

(* cols 3-5, rows 0-2 (black) or 7-9 (red) *)
PROCEDURE InPalace(pos, side: INTEGER): BOOLEAN;
VAR col, row: INTEGER;
BEGIN
  col := pos MOD 16; row := pos DIV 16;
  IF (col < 3) OR (col > 5) THEN RETURN FALSE END;
  IF side = SIDE THEN RETURN (row >= 7) & (row <= 9)
  ELSE                RETURN (row >= 0) & (row <= 2) END
END InPalace;

(* Red stays in rows 5-9; Black stays in rows 0-4 *)
PROCEDURE OnOwnSide(pos, side: INTEGER): BOOLEAN;
BEGIN
  IF side = SIDE THEN RETURN pos DIV 16 >= 5
  ELSE                RETURN pos DIV 16 <= 4 END
END OnOwnSide;

PROCEDURE HasCrossed(pos, side: INTEGER): BOOLEAN;
BEGIN RETURN ~OnOwnSide(pos, side) END HasCrossed;

(* ══════════════════════════════════════════════════════════════════ *)
(*  Engine                                                             *)
(* ══════════════════════════════════════════════════════════════════ *)

PROCEDURE KingPos(side: INTEGER): INTEGER;
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO 159 DO
    IF IsOnBoard(i) & (board[i] MOD 8 = GENERAL) &
       (((board[i] DIV SIDE) MOD 2) * SIDE = side) THEN RETURN i END
  END;
  RETURN -1
END KingPos;

PROCEDURE KingFound(side: INTEGER): BOOLEAN;
BEGIN RETURN KingPos(side) >= 0 END KingFound;

PROCEDURE FlyingGeneral(): BOOLEAN;
VAR rp, bp, pos: INTEGER;
BEGIN
  rp := KingPos(SIDE); bp := KingPos(0);
  IF (rp < 0) OR (bp < 0) THEN RETURN FALSE END;
  IF rp MOD 16 # bp MOD 16 THEN RETURN FALSE END;
  pos := bp + 16;
  WHILE pos < rp DO
    IF board[pos] # EMPTY THEN RETURN FALSE END;
    INC(pos, 16)
  END;
  RETURN TRUE
END FlyingGeneral;

PROCEDURE IsAttacked(pos, bySide: INTEGER): BOOLEAN;
VAR i, sq, sc: INTEGER;
BEGIN
  (* Chariot – orthogonal slide *)
  FOR i := 0 TO 3 DO
    sq := pos + rookVec[i];
    LOOP
      IF ~IsOnBoard(sq) THEN EXIT END;
      IF board[sq] # EMPTY THEN
        IF (((board[sq] DIV SIDE) MOD 2) * SIDE = bySide) &
           (board[sq] MOD 8 = CHARIOT) THEN RETURN TRUE END;
        EXIT
      END;
      sq := sq + rookVec[i]
    END
  END;
  (* Cannon – exactly one screen between cannon and pos *)
  FOR i := 0 TO 3 DO
    sq := pos + rookVec[i]; sc := 0;
    LOOP
      IF ~IsOnBoard(sq) THEN EXIT END;
      IF board[sq] # EMPTY THEN
        INC(sc);
        IF sc = 2 THEN
          IF (((board[sq] DIV SIDE) MOD 2) * SIDE = bySide) &
             (board[sq] MOD 8 = CANNON) THEN RETURN TRUE END;
          EXIT
        END
      END;
      sq := sq + rookVec[i]
    END
  END;
  (* Horse – 8 L-moves; check that the leg square is empty *)
  FOR i := 0 TO 7 DO
    sq := pos + horseVec[i];
    IF IsOnBoard(sq) & (board[sq] MOD 8 = HORSE) &
       (((board[sq] DIV SIDE) MOD 2) * SIDE = bySide) THEN
      IF IsOnBoard(pos + horseBlock[i]) & (board[pos + horseBlock[i]] = EMPTY) THEN
        RETURN TRUE
      END
    END
  END;
  (* General – adjacent orthogonal *)
  FOR i := 0 TO 3 DO
    sq := pos + rookVec[i];
    IF IsOnBoard(sq) & (board[sq] MOD 8 = GENERAL) &
       (((board[sq] DIV SIDE) MOD 2) * SIDE = bySide) THEN RETURN TRUE END
  END;
  (* Advisor – adjacent diagonal *)
  FOR i := 0 TO 3 DO
    sq := pos + bishopVec[i];
    IF IsOnBoard(sq) & (board[sq] MOD 8 = ADVISOR) &
       (((board[sq] DIV SIDE) MOD 2) * SIDE = bySide) THEN RETURN TRUE END
  END;
  (* Soldier attacks *)
  IF bySide = SIDE THEN
    sq := pos + 16;
    IF IsOnBoard(sq) & (board[sq] MOD 8 = SOLDIER) &
       (((board[sq] DIV SIDE) MOD 2) * SIDE = SIDE) THEN RETURN TRUE END;
    IF pos DIV 16 <= 4 THEN
      sq := pos - 1;
      IF IsOnBoard(sq) & (board[sq] MOD 8 = SOLDIER) &
         (((board[sq] DIV SIDE) MOD 2) * SIDE = SIDE) THEN RETURN TRUE END;
      sq := pos + 1;
      IF IsOnBoard(sq) & (board[sq] MOD 8 = SOLDIER) &
         (((board[sq] DIV SIDE) MOD 2) * SIDE = SIDE) THEN RETURN TRUE END
    END
  ELSE
    sq := pos - 16;
    IF IsOnBoard(sq) & (board[sq] MOD 8 = SOLDIER) &
       (((board[sq] DIV SIDE) MOD 2) * SIDE = 0) THEN RETURN TRUE END;
    IF pos DIV 16 >= 5 THEN
      sq := pos - 1;
      IF IsOnBoard(sq) & (board[sq] MOD 8 = SOLDIER) &
         (((board[sq] DIV SIDE) MOD 2) * SIDE = 0) THEN RETURN TRUE END;
      sq := pos + 1;
      IF IsOnBoard(sq) & (board[sq] MOD 8 = SOLDIER) &
         (((board[sq] DIV SIDE) MOD 2) * SIDE = 0) THEN RETURN TRUE END
    END
  END;
  RETURN FALSE
END IsAttacked;

PROCEDURE InCheck(side: INTEGER): BOOLEAN;
VAR kp: INTEGER;
BEGIN
  kp := KingPos(side);
  IF kp < 0 THEN RETURN FALSE END;
  RETURN IsAttacked(kp, SIDE - side) OR FlyingGeneral()
END InCheck;

PROCEDURE InitBoard;
BEGIN
  board[0]   := CHARIOT;  board[1]   := HORSE;    board[2]   := ELEPHANT;
  board[3]   := ADVISOR;  board[4]   := GENERAL;  board[5]   := ADVISOR;
  board[6]   := ELEPHANT; board[7]   := HORSE;    board[8]   := CHARIOT;
  board[33]  := CANNON;   board[39]  := CANNON;
  board[48]  := SOLDIER;  board[50]  := SOLDIER;  board[52]  := SOLDIER;
  board[54]  := SOLDIER;  board[56]  := SOLDIER;
  board[96]  := SOLDIER + SIDE; board[98]  := SOLDIER + SIDE;
  board[100] := SOLDIER + SIDE; board[102] := SOLDIER + SIDE;
  board[104] := SOLDIER + SIDE;
  board[113] := CANNON + SIDE; board[119] := CANNON + SIDE;
  board[144] := CHARIOT + SIDE;  board[145] := HORSE + SIDE;
  board[146] := ELEPHANT + SIDE; board[147] := ADVISOR + SIDE;
  board[148] := GENERAL + SIDE;  board[149] := ADVISOR + SIDE;
  board[150] := ELEPHANT + SIDE; board[151] := HORSE + SIDE;
  board[152] := CHARIOT + SIDE;
END InitBoard;

(* Count occupied squares strictly between from and to stepping by step *)
PROCEDURE CountBetween(from, to, step: INTEGER): INTEGER;
VAR sq, cnt: INTEGER;
BEGIN
  cnt := 0; sq := from + step;
  WHILE sq # to DO
    IF board[sq] # EMPTY THEN INC(cnt) END;
    sq := sq + step
  END;
  RETURN cnt
END CountBetween;

PROCEDURE ApplyMove(from, to, side: INTEGER): BOOLEAN;
VAR movingP, savedTarget, p, df, dr, step, cnt, blk: INTEGER; valid: BOOLEAN;
BEGIN
  IF ~IsOnBoard(from) OR ~IsOnBoard(to) THEN RETURN FALSE END;
  movingP := board[from];
  IF (movingP = EMPTY) OR (((movingP DIV SIDE) MOD 2) * SIDE # side) THEN RETURN FALSE END;
  IF (board[to] # EMPTY) & (((board[to] DIV SIDE) MOD 2) * SIDE = side) THEN RETURN FALSE END;
  p   := movingP MOD 8;
  df  := (to MOD 16) - (from MOD 16);
  dr  := (to DIV 16) - (from DIV 16);
  valid := FALSE;

  IF p = CHARIOT THEN
    IF (df = 0) & (dr # 0) THEN
      IF dr > 0 THEN step := 16 ELSE step := -16 END;
      valid := CountBetween(from, to, step) = 0
    ELSIF (dr = 0) & (df # 0) THEN
      IF df > 0 THEN step := 1 ELSE step := -1 END;
      valid := CountBetween(from, to, step) = 0
    END

  ELSIF p = CANNON THEN
    IF (df = 0) & (dr # 0) THEN
      IF dr > 0 THEN step := 16 ELSE step := -16 END;
      cnt := CountBetween(from, to, step);
      IF board[to] = EMPTY THEN valid := cnt = 0 ELSE valid := cnt = 1 END
    ELSIF (dr = 0) & (df # 0) THEN
      IF df > 0 THEN step := 1 ELSE step := -1 END;
      cnt := CountBetween(from, to, step);
      IF board[to] = EMPTY THEN valid := cnt = 0 ELSE valid := cnt = 1 END
    END

  ELSIF p = HORSE THEN
    IF ((df = 1) OR (df = -1)) & ((dr = 2) OR (dr = -2)) THEN
      IF dr = -2 THEN valid := board[from - 16] = EMPTY
      ELSE             valid := board[from + 16] = EMPTY END
    ELSIF ((df = 2) OR (df = -2)) & ((dr = 1) OR (dr = -1)) THEN
      IF df = -2 THEN valid := board[from - 1] = EMPTY
      ELSE             valid := board[from + 1] = EMPTY END
    END

  ELSIF p = ELEPHANT THEN
    IF ((df = 2) OR (df = -2)) & ((dr = 2) OR (dr = -2)) & OnOwnSide(to, side) THEN
      blk := from + (dr DIV 2) * 16 + (df DIV 2);
      valid := board[blk] = EMPTY
    END

  ELSIF p = ADVISOR THEN
    IF ((df = 1) OR (df = -1)) & ((dr = 1) OR (dr = -1)) & InPalace(to, side) THEN
      valid := TRUE
    END

  ELSIF p = GENERAL THEN
    IF (((df = 1) OR (df = -1)) & (dr = 0) OR (df = 0) & ((dr = 1) OR (dr = -1))) &
       InPalace(to, side) THEN valid := TRUE END

  ELSIF p = SOLDIER THEN
    IF side = SIDE THEN
      IF (dr = -1) & (df = 0) THEN valid := TRUE
      ELSIF (dr = 0) & ((df = 1) OR (df = -1)) & HasCrossed(from, side) THEN valid := TRUE
      END
    ELSE
      IF (dr = 1) & (df = 0) THEN valid := TRUE
      ELSIF (dr = 0) & ((df = 1) OR (df = -1)) & HasCrossed(from, side) THEN valid := TRUE
      END
    END
  END;

  IF ~valid THEN RETURN FALSE END;

  savedTarget := board[to];
  board[to] := movingP; board[from] := EMPTY;
  IF InCheck(side) THEN
    board[from] := movingP; board[to] := savedTarget;
    RETURN FALSE
  END;
  RETURN TRUE
END ApplyMove;

PROCEDURE Evaluate(turn, depth, alpha, beta: INTEGER; VAR bestF, bestT: INTEGER): INTEGER;
VAR f, p, i, target, score, bestScore, captured, movingP: INTEGER;
    dF, dT, sc, blk, captureValue: INTEGER;
BEGIN
  IF depth = 0 THEN RETURN 0 END;
  bestScore := alpha;
  FOR f := 0 TO 159 DO
    IF IsOnBoard(f) & (board[f] # EMPTY) & (((board[f] DIV SIDE) MOD 2) * SIDE = turn) THEN
      p := board[f] MOD 8;

      IF p = CHARIOT THEN
        FOR i := 0 TO 3 DO
          target := f + rookVec[i];
          LOOP
            IF ~IsOnBoard(target) THEN EXIT END;
            captured := board[target];
            IF (captured # EMPTY) & (((captured DIV SIDE) MOD 2) * SIDE = turn) THEN EXIT END;
            movingP := board[f];
            board[target] := movingP; board[f] := EMPTY;
            IF ~InCheck(turn) THEN
              captureValue := pieceValues[captured MOD 8];
              score := captureValue - Evaluate(SIDE - turn, depth - 1,
                         captureValue - beta, captureValue - alpha, dF, dT);
              board[f] := movingP; board[target] := captured;
              IF score > bestScore THEN
                bestScore := score;
                IF depth = maxDepth THEN bestF := f; bestT := target END;
                alpha := bestScore;
                IF alpha >= beta THEN RETURN bestScore END
              END
            ELSE
              board[f] := movingP; board[target] := captured
            END;
            IF captured # EMPTY THEN EXIT END;
            target := target + rookVec[i]
          END
        END

      ELSIF p = CANNON THEN
        FOR i := 0 TO 3 DO
          target := f + rookVec[i]; sc := 0;
          LOOP
            IF ~IsOnBoard(target) THEN EXIT END;
            IF board[target] = EMPTY THEN
              IF sc = 0 THEN
                movingP := board[f];
                board[target] := movingP; board[f] := EMPTY;
                IF ~InCheck(turn) THEN
                  score := -Evaluate(SIDE - turn, depth - 1, -beta, -alpha, dF, dT);
                  board[f] := movingP; board[target] := EMPTY;
                  IF score > bestScore THEN
                    bestScore := score;
                    IF depth = maxDepth THEN bestF := f; bestT := target END;
                    alpha := bestScore;
                    IF alpha >= beta THEN RETURN bestScore END
                  END
                ELSE
                  board[f] := movingP; board[target] := EMPTY
                END
              END
            ELSE
              INC(sc);
              IF sc = 2 THEN
                captured := board[target];
                IF (((captured DIV SIDE) MOD 2) * SIDE # turn) THEN
                  movingP := board[f];
                  board[target] := movingP; board[f] := EMPTY;
                  IF ~InCheck(turn) THEN
                    captureValue := pieceValues[captured MOD 8];
                    score := captureValue - Evaluate(SIDE - turn, depth - 1,
                               captureValue - beta, captureValue - alpha, dF, dT);
                    board[f] := movingP; board[target] := captured;
                    IF score > bestScore THEN
                      bestScore := score;
                      IF depth = maxDepth THEN bestF := f; bestT := target END;
                      alpha := bestScore;
                      IF alpha >= beta THEN RETURN bestScore END
                    END
                  ELSE
                    board[f] := movingP; board[target] := captured
                  END
                END;
                EXIT
              END
            END;
            target := target + rookVec[i]
          END
        END

      ELSIF p = HORSE THEN
        FOR i := 0 TO 7 DO
          blk := f + horseBlock[i];
          IF IsOnBoard(blk) & (board[blk] = EMPTY) THEN
            target := f + horseVec[i];
            IF IsOnBoard(target) THEN
              captured := board[target];
              IF (captured = EMPTY) OR (((captured DIV SIDE) MOD 2) * SIDE # turn) THEN
                movingP := board[f];
                board[target] := movingP; board[f] := EMPTY;
                IF ~InCheck(turn) THEN
                  captureValue := pieceValues[captured MOD 8];
                  score := captureValue - Evaluate(SIDE - turn, depth - 1,
                             captureValue - beta, captureValue - alpha, dF, dT);
                  board[f] := movingP; board[target] := captured;
                  IF score > bestScore THEN
                    bestScore := score;
                    IF depth = maxDepth THEN bestF := f; bestT := target END;
                    alpha := bestScore;
                    IF alpha >= beta THEN RETURN bestScore END
                  END
                ELSE
                  board[f] := movingP; board[target] := captured
                END
              END
            END
          END
        END

      ELSIF p = ELEPHANT THEN
        FOR i := 0 TO 3 DO
          blk := f + elephantBlock[i];
          IF IsOnBoard(blk) & (board[blk] = EMPTY) THEN
            target := f + elephantVec[i];
            IF IsOnBoard(target) & OnOwnSide(target, turn) THEN
              captured := board[target];
              IF (captured = EMPTY) OR (((captured DIV SIDE) MOD 2) * SIDE # turn) THEN
                movingP := board[f];
                board[target] := movingP; board[f] := EMPTY;
                IF ~InCheck(turn) THEN
                  captureValue := pieceValues[captured MOD 8];
                  score := captureValue - Evaluate(SIDE - turn, depth - 1,
                             captureValue - beta, captureValue - alpha, dF, dT);
                  board[f] := movingP; board[target] := captured;
                  IF score > bestScore THEN
                    bestScore := score;
                    IF depth = maxDepth THEN bestF := f; bestT := target END;
                    alpha := bestScore;
                    IF alpha >= beta THEN RETURN bestScore END
                  END
                ELSE
                  board[f] := movingP; board[target] := captured
                END
              END
            END
          END
        END

      ELSIF p = ADVISOR THEN
        FOR i := 0 TO 3 DO
          target := f + bishopVec[i];
          IF IsOnBoard(target) & InPalace(target, turn) THEN
            captured := board[target];
            IF (captured = EMPTY) OR (((captured DIV SIDE) MOD 2) * SIDE # turn) THEN
              movingP := board[f];
              board[target] := movingP; board[f] := EMPTY;
              IF ~InCheck(turn) THEN
                captureValue := pieceValues[captured MOD 8];
                score := captureValue - Evaluate(SIDE - turn, depth - 1,
                           captureValue - beta, captureValue - alpha, dF, dT);
                board[f] := movingP; board[target] := captured;
                IF score > bestScore THEN
                  bestScore := score;
                  IF depth = maxDepth THEN bestF := f; bestT := target END;
                  alpha := bestScore;
                  IF alpha >= beta THEN RETURN bestScore END
                END
              ELSE
                board[f] := movingP; board[target] := captured
              END
            END
          END
        END

      ELSIF p = GENERAL THEN
        FOR i := 0 TO 3 DO
          target := f + rookVec[i];
          IF IsOnBoard(target) & InPalace(target, turn) THEN
            captured := board[target];
            IF (captured = EMPTY) OR (((captured DIV SIDE) MOD 2) * SIDE # turn) THEN
              movingP := board[f];
              board[target] := movingP; board[f] := EMPTY;
              IF ~InCheck(turn) THEN
                captureValue := pieceValues[captured MOD 8];
                score := captureValue - Evaluate(SIDE - turn, depth - 1,
                           captureValue - beta, captureValue - alpha, dF, dT);
                board[f] := movingP; board[target] := captured;
                IF score > bestScore THEN
                  bestScore := score;
                  IF depth = maxDepth THEN bestF := f; bestT := target END;
                  alpha := bestScore;
                  IF alpha >= beta THEN RETURN bestScore END
                END
              ELSE
                board[f] := movingP; board[target] := captured
              END
            END
          END
        END

      ELSIF p = SOLDIER THEN
        IF turn = SIDE THEN target := f - 16 ELSE target := f + 16 END;
        IF IsOnBoard(target) THEN
          captured := board[target];
          IF (captured = EMPTY) OR (((captured DIV SIDE) MOD 2) * SIDE # turn) THEN
            movingP := board[f];
            board[target] := movingP; board[f] := EMPTY;
            IF ~InCheck(turn) THEN
              captureValue := pieceValues[captured MOD 8];
              score := captureValue - Evaluate(SIDE - turn, depth - 1,
                         captureValue - beta, captureValue - alpha, dF, dT);
              board[f] := movingP; board[target] := captured;
              IF score > bestScore THEN
                bestScore := score;
                IF depth = maxDepth THEN bestF := f; bestT := target END;
                alpha := bestScore;
                IF alpha >= beta THEN RETURN bestScore END
              END
            ELSE
              board[f] := movingP; board[target] := captured
            END
          END
        END;
        IF HasCrossed(f, turn) THEN
          FOR i := 0 TO 1 DO
            IF i = 0 THEN target := f - 1 ELSE target := f + 1 END;
            IF IsOnBoard(target) THEN
              captured := board[target];
              IF (captured = EMPTY) OR (((captured DIV SIDE) MOD 2) * SIDE # turn) THEN
                movingP := board[f];
                board[target] := movingP; board[f] := EMPTY;
                IF ~InCheck(turn) THEN
                  captureValue := pieceValues[captured MOD 8];
                  score := captureValue - Evaluate(SIDE - turn, depth - 1,
                             captureValue - beta, captureValue - alpha, dF, dT);
                  board[f] := movingP; board[target] := captured;
                  IF score > bestScore THEN
                    bestScore := score;
                    IF depth = maxDepth THEN bestF := f; bestT := target END;
                    alpha := bestScore;
                    IF alpha >= beta THEN RETURN bestScore END
                  END
                ELSE
                  board[f] := movingP; board[target] := captured
                END
              END
            END
          END
        END
      END
    END
  END;
  RETURN bestScore
END Evaluate;

PROCEDURE GetComputerMove(side: INTEGER; VAR from, to: INTEGER);
VAR score: INTEGER;
BEGIN
  from := -1; to := -1;
  score := Evaluate(side, maxDepth, -32000, 2000, from, to)
END GetComputerMove;

PROCEDURE HasLegalMoves(side: INTEGER): BOOLEAN;
VAR f, t, score, savedDepth: INTEGER;
BEGIN
  f := -1; t := -1; savedDepth := maxDepth; maxDepth := 1;
  score := Evaluate(side, 1, -2000, 2000, f, t);
  maxDepth := savedDepth;
  RETURN f >= 0
END HasLegalMoves;

(* ══════════════════════════════════════════════════════════════════ *)
(*  Board history (undo)                                              *)
(* ══════════════════════════════════════════════════════════════════ *)

PROCEDURE SaveBoard(idx: INTEGER);
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO 159 DO boardHistory[idx][i] := board[i] END
END SaveBoard;

PROCEDURE RestoreBoard(idx: INTEGER);
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO 159 DO board[i] := boardHistory[idx][i] END
END RestoreBoard;

(* ══════════════════════════════════════════════════════════════════ *)
(*  Helpers                                                            *)
(* ══════════════════════════════════════════════════════════════════ *)

PROCEDURE MoveToStr(from, to: INTEGER; VAR s: MoveStr);
BEGIN
  s[0] := CHR(ORD("a") + (from MOD 16));
  s[1] := CHR(ORD("0") + (from DIV 16));
  s[2] := CHR(ORD("a") + (to   MOD 16));
  s[3] := CHR(ORD("0") + (to   DIV 16));
  s[4] := 0X
END MoveToStr;

PROCEDURE ParseAlg(s: ARRAY OF CHAR; VAR from, to: INTEGER): BOOLEAN;
BEGIN
  IF (s[0] < "a") OR (s[0] > "i") THEN RETURN FALSE END;
  IF (s[1] < "0") OR (s[1] > "9") THEN RETURN FALSE END;
  IF (s[2] < "a") OR (s[2] > "i") THEN RETURN FALSE END;
  IF (s[3] < "0") OR (s[3] > "9") THEN RETURN FALSE END;
  from := (ORD(s[1]) - ORD("0")) * 16 + (ORD(s[0]) - ORD("a"));
  to   := (ORD(s[3]) - ORD("0")) * 16 + (ORD(s[2]) - ORD("a"));
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
  IF ((piece DIV SIDE) MOD 2) = 1 THEN pfg := TUI.Red
  ELSE                                  pfg := TUI.Black END;

  IF    t = SOLDIER  THEN c0 := "("; c1 := ")"; letter := "S"
  ELSIF t = CHARIOT  THEN c0 := "["; c1 := "]"; letter := "R"
  ELSIF t = HORSE    THEN c0 := "^"; c1 := "^"; letter := "H"
  ELSIF t = ELEPHANT THEN c0 := "<"; c1 := ">"; letter := "E"
  ELSIF t = CANNON   THEN c0 := "!"; c1 := "!"; letter := "C"
  ELSIF t = GENERAL  THEN c0 := "+"; c1 := "+"; letter := "G"
  ELSE                    c0 := "/"; c1 := "\"; letter := "A"
  END;

  IF ((piece DIV SIDE) MOD 2) = 0 THEN letter := CHR(ORD(letter) + 32) END;

  TUI.PutCell(x,     y,     c0,     pfg, bg);
  TUI.PutCell(x + 1, y,     c1,     pfg, bg);
  TUI.PutCell(x,     y + 1, letter, pfg, bg);
  TUI.PutCell(x + 1, y + 1, letter, pfg, bg)
END DrawPiece;

PROCEDURE DrawBoardScreen;
VAR r, c, sq, piece, bg, fg, sx, sy, kingPos: INTEGER; ch: CHAR; inCheck: BOOLEAN;
BEGIN
  TUI.ClearBack(TUI.White, TUI.Black);
  TUI.PutStr(1, 0, "Xiangqi  [Tab=list] [u=Undo] [s=Suggest] [Ctrl-Q=Quit]", TUI.Yellow, TUI.Black);
  TUI.PutStr(1, 1, "Red=bottom(rows 5-9)  River between rows 4/5", TUI.Cyan, TUI.Black);

  FOR r := 0 TO 9 DO
    ch := CHR(ORD("0") + r);
    TUI.PutCell(BOARDX - 2, BOARDY + r * CELLH, ch, TUI.White, TUI.Black)
  END;
  FOR c := 0 TO 8 DO
    ch := CHR(ORD("a") + c);
    TUI.PutCell(BOARDX + c * CELLW + 1, BOARDY + 10 * CELLH, ch, TUI.White, TUI.Black)
  END;

  kingPos := KingPos(humanSide);
  inCheck := InCheck(humanSide);

  FOR r := 0 TO 9 DO
    FOR c := 0 TO 8 DO
      sq    := r * 16 + c;
      piece := board[sq];

      IF (c = curCol) & (r = curRow) THEN bg := CURSOR_BG;   fg := TUI.Black
      ELSIF sq = selSquare            THEN bg := SEL_BG;      fg := TUI.Black
      ELSIF inCheck & (sq = kingPos)  THEN bg := TUI.Magenta; fg := TUI.White
      ELSIF sq = suggestFrom           THEN bg := TUI.Green;    fg := TUI.Black
      ELSIF sq = suggestTo             THEN bg := TUI.Red;     fg := TUI.White
      ELSIF r < 5                     THEN bg := BLACK_BG;    fg := TUI.White
      ELSE                                 bg := RED_BG;      fg := TUI.Black
      END;

      sx := BOARDX + c * CELLW;
      sy := BOARDY + r * CELLH;
      TUI.FillRect(sx, sy, CELLW, CELLH, " ", fg, bg);
      DrawPiece(sx + 1, sy, piece, bg)
    END
  END;

  IF gameOver THEN
    IF gameResult = 1 THEN
      TUI.PutStr(1, TUI.Rows-1, "Checkmate! Computer wins.  u=Undo  Ctrl-Q=Quit  ", TUI.Red,    TUI.Black)
    ELSIF gameResult = 2 THEN
      TUI.PutStr(1, TUI.Rows-1, "Stalemate! Draw.  u=Undo  Ctrl-Q=Quit           ", TUI.Yellow, TUI.Black)
    ELSIF gameResult = 3 THEN
      TUI.PutStr(1, TUI.Rows-1, "Checkmate! You win!  u=Undo  Ctrl-Q=Quit        ", TUI.Green,  TUI.Black)
    ELSE
      TUI.PutStr(1, TUI.Rows-1, "Game over.  u=Undo  Ctrl-Q=Quit                 ", TUI.Red,    TUI.Black)
    END
  ELSIF inCheck & (selSquare >= 0) THEN
    TUI.PutStr(1, TUI.Rows-1, "CHECK! Select destination (Enter/click).", TUI.Magenta, TUI.Black)
  ELSIF inCheck THEN
    TUI.PutStr(1, TUI.Rows-1, "CHECK! Select piece to move.  Tab=list  ", TUI.Magenta, TUI.Black)
  ELSIF selSquare >= 0 THEN
    TUI.PutStr(1, TUI.Rows-1, "Select destination (Enter/click).       ", TUI.Cyan,    TUI.Black)
  ELSE
    TUI.PutStr(1, TUI.Rows-1, "Select piece (Enter/click).  Tab=list   ", TUI.White,   TUI.Black)
  END;
  TUI.Flush
END DrawBoardScreen;

PROCEDURE DrawListScreen;
VAR i, row, maxVis, maxTop, promptY: INTEGER; numBuf: ARRAY 8 OF CHAR;
BEGIN
  maxVis := TUI.Rows - 5;
  maxTop := moveCount - maxVis;
  IF maxTop < 0 THEN maxTop := 0 END;
  IF listTop > maxTop THEN listTop := maxTop END;
  IF listTop < 0      THEN listTop := 0      END;

  TUI.ClearBack(TUI.White, TUI.Black);
  TUI.PutStr(1, 0, "Xiangqi  [Tab=Board view]  [u=Undo]  [Ctrl-Q=Quit]", TUI.Yellow, TUI.Black);
  TUI.PutStr(1, 1, "#    Your move  Computer", TUI.Cyan, TUI.Black);

  i := listTop;
  WHILE (i < moveCount) & (i < listTop + maxVis) DO
    row := 2 + (i - listTop);
    numBuf[0] := CHR(ORD("0") + (i + 1) DIV 10);
    numBuf[1] := CHR(ORD("0") + (i + 1) MOD 10);
    numBuf[2] := "."; numBuf[3] := " "; numBuf[4] := 0X;
    TUI.PutStr(1,  row, numBuf,         TUI.White, TUI.Black);
    TUI.PutStr(5,  row, humanMoves[i],  TUI.Green, TUI.Black);
    TUI.PutStr(17, row, compMoves[i],   TUI.Red,   TUI.Black);
    INC(i)
  END;

  promptY := TUI.Rows - 3;
  TUI.PutStr(1, promptY, "Move: ",   TUI.White,  TUI.Black);
  TUI.PutStr(6, promptY, inputBuf,   TUI.Yellow, TUI.Black);
  TUI.SetCursor(6 + inputLen, promptY);

  IF gameOver THEN
    IF gameResult = 1 THEN
      TUI.PutStr(1, TUI.Rows-1, "Checkmate! Computer wins.  u=Undo  Ctrl-Q=Quit  ", TUI.Red,    TUI.Black)
    ELSIF gameResult = 2 THEN
      TUI.PutStr(1, TUI.Rows-1, "Stalemate! Draw.  u=Undo  Ctrl-Q=Quit           ", TUI.Yellow, TUI.Black)
    ELSIF gameResult = 3 THEN
      TUI.PutStr(1, TUI.Rows-1, "Checkmate! You win!  u=Undo  Ctrl-Q=Quit        ", TUI.Green,  TUI.Black)
    ELSE
      TUI.PutStr(1, TUI.Rows-1, "Game over.  u=Undo  Ctrl-Q=Quit                 ", TUI.Red,    TUI.Black)
    END
  ELSIF moveCount > maxVis THEN
    TUI.PutStr(1, TUI.Rows-1, "Up/Dn/PgUp/PgDn=scroll  End=latest    ", TUI.White, TUI.Black)
  ELSE
    TUI.PutStr(1, TUI.Rows-1, "Type move (e.g. e9e8) then Enter.      ", TUI.White, TUI.Black)
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
VAR bf, bt: INTEGER;
BEGIN
  TUI.PutStr(1, TUI.Rows-1, "Computer is thinking...                 ", TUI.Yellow, TUI.Black);
  TUI.Flush;
  GetComputerMove(compSide, bf, bt);
  IF ~IsOnBoard(bf) OR ~IsOnBoard(bt) THEN
    IF InCheck(compSide) THEN gameResult := 3 ELSE gameResult := 2 END;
    gameOver := TRUE; RETURN
  END;
  IF ApplyMove(bf, bt, compSide) THEN
    IF moveCount > 0 THEN MoveToStr(bf, bt, compMoves[moveCount - 1]) END;
    IF ~KingFound(humanSide) THEN gameResult := 1; gameOver := TRUE; RETURN END;
    IF ~HasLegalMoves(humanSide) THEN
      IF InCheck(humanSide) THEN gameResult := 1 ELSE gameResult := 2 END;
      gameOver := TRUE
    END
  ELSE
    gameOver := TRUE
  END
END DoComputerMove;

PROCEDURE TryHumanMove(from, to: INTEGER): BOOLEAN;
VAR s: MoveStr;
BEGIN
  IF moveCount < MAXMOVES THEN SaveBoard(moveCount) END;
  suggestFrom := -1; suggestTo := -1;
  IF ApplyMove(from, to, humanSide) THEN
    MoveToStr(from, to, s);
    IF moveCount < MAXMOVES THEN
      COPY(s, humanMoves[moveCount]);
      compMoves[moveCount][0] := 0X;
      INC(moveCount)
    END;
    IF ~KingFound(compSide) THEN gameResult := 3; gameOver := TRUE; RETURN TRUE END;
    DoComputerMove;
    RETURN TRUE
  END;
  RETURN FALSE
END TryHumanMove;

(* ══════════════════════════════════════════════════════════════════ *)
(*  Event handlers                                                     *)
(* ══════════════════════════════════════════════════════════════════ *)

PROCEDURE HandleUndo;
BEGIN
  IF moveCount > 0 THEN
    DEC(moveCount);
    RestoreBoard(moveCount);
    gameOver := FALSE; gameResult := 0;
    selSquare := -1;
    suggestFrom := -1; suggestTo := -1
  END
END HandleUndo;

PROCEDURE HandleSuggest;
BEGIN
  TUI.PutStr(1, TUI.Rows-1, "Thinking of suggestion...               ", TUI.Yellow, TUI.Black);
  TUI.Flush;
  GetComputerMove(humanSide, suggestFrom, suggestTo)
END HandleSuggest;

PROCEDURE HandleBoardKey(key: CHAR);
VAR sq, from, to: INTEGER;
BEGIN
  IF    key = TUI.KUp    THEN IF curRow > 0 THEN DEC(curRow) END
  ELSIF key = TUI.KDown  THEN IF curRow < 9 THEN INC(curRow) END
  ELSIF key = TUI.KLeft  THEN IF curCol > 0 THEN DEC(curCol) END
  ELSIF key = TUI.KRight THEN IF curCol < 8 THEN INC(curCol) END
  ELSIF key = "s" THEN HandleSuggest
  ELSIF key = TUI.KEnter THEN
    sq := curRow * 16 + curCol;
    IF selSquare < 0 THEN
      IF (board[sq] # EMPTY) & (((board[sq] DIV SIDE) MOD 2) * SIDE = humanSide) THEN
        selSquare := sq END
    ELSIF (board[sq] # EMPTY) & (((board[sq] DIV SIDE) MOD 2) * SIDE = humanSide) THEN
      selSquare := sq
    ELSE
      from := selSquare; to := sq; selSquare := -1;
      IF ~TryHumanMove(from, to) THEN
        TUI.PutStr(1, TUI.Rows-1, "Illegal move.                           ", TUI.Red, TUI.Black);
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
  IF (col < 0) OR (col > 8) OR (row < 0) OR (row > 9) THEN RETURN END;
  sq := row * 16 + col;
  curCol := col; curRow := row;
  IF mb = 0 THEN
    IF selSquare < 0 THEN
      IF (board[sq] # EMPTY) & (((board[sq] DIV SIDE) MOD 2) * SIDE = humanSide) THEN
        selSquare := sq END
    ELSIF (board[sq] # EMPTY) & (((board[sq] DIV SIDE) MOD 2) * SIDE = humanSide) THEN
      selSquare := sq
    ELSE
      from := selSquare; to := sq; selSquare := -1;
      IF ~TryHumanMove(from, to) THEN
        TUI.PutStr(1, TUI.Rows-1, "Illegal move.                           ", TUI.Red, TUI.Black);
        TUI.Flush
      END
    END
  END
END HandleBoardMouse;

PROCEDURE HandleListKey(key: CHAR);
VAR from, to, maxVis: INTEGER;
BEGIN
  maxVis := TUI.Rows - 5;
  IF    key = TUI.KUp   THEN IF listTop > 0 THEN DEC(listTop) END
  ELSIF key = TUI.KDown THEN INC(listTop)
  ELSIF key = TUI.KPgUp THEN
    IF listTop > maxVis THEN listTop := listTop - maxVis ELSE listTop := 0 END
  ELSIF key = TUI.KPgDn THEN listTop := listTop + maxVis
  ELSIF key = TUI.KHome THEN listTop := 0
  ELSIF key = TUI.KEnd  THEN listTop := MAXMOVES
  ELSIF key = TUI.KEnter THEN
    IF inputLen = 0 THEN RETURN END;
    inputBuf[inputLen] := 0X;
    IF ParseAlg(inputBuf, from, to) THEN
      IF ~TryHumanMove(from, to) THEN
        TUI.PutStr(1, TUI.Rows-1, "Illegal move.                           ", TUI.Red, TUI.Black);
        TUI.Flush
      END
    ELSE
      TUI.PutStr(1, TUI.Rows-1, "Bad format — use e.g. e9e8.             ", TUI.Red, TUI.Black);
      TUI.Flush
    END;
    inputLen := 0; inputBuf[0] := 0X
  ELSIF key = TUI.KBackspace THEN
    IF inputLen > 0 THEN DEC(inputLen); inputBuf[inputLen] := 0X END
  ELSIF ((key >= "a") & (key <= "i")) OR ((key >= "0") & (key <= "9")) THEN
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
  TUI.PutStr(4, 4,  "Xiangqi — choose your side",                  TUI.Yellow, TUI.Black);
  TUI.PutStr(4, 6,  "R  Play Red (you move first)",                TUI.White,  TUI.Black);
  TUI.PutStr(4, 7,  "B  Play Black (computer moves first)",        TUI.White,  TUI.Black);
  TUI.PutStr(4, 9,  "Search depth  1=easy  3=medium  5=hard",      TUI.Cyan,   TUI.Black);
  TUI.PutStr(4, 10, "Press 1, 3, or 5 then R or B:",               TUI.White,  TUI.Black);
  TUI.Flush;

  maxDepth  := 3;
  humanSide := SIDE; compSide := 0;

  LOOP
    TUI.WaitEvent(ev2);
    IF ev2.kind = TUI.EvKey THEN
      IF    ev2.key = "1" THEN maxDepth := 1
      ELSIF ev2.key = "3" THEN maxDepth := 3
      ELSIF ev2.key = "5" THEN maxDepth := 5
      ELSIF (ev2.key = "r") OR (ev2.key = "R") THEN
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
  gameOver  := FALSE; gameResult := 0;
  moveCount := 0; listTop := 0;
  curCol    := 4; curRow  := 9;
  selSquare := -1;
  suggestFrom := -1; suggestTo := -1;
  inputLen  := 0; inputBuf[0] := 0X;

  IF compSide = SIDE THEN DoComputerMove END;
  DrawScreen;

  LOOP
    TUI.WaitEvent(ev);
    IF ev.kind = TUI.EvKey THEN
      IF ev.key = 17 THEN EXIT END;
      IF ev.key = TUI.KTab THEN
        IF screen = BOARD THEN screen := LIST; listTop := MAXMOVES
        ELSE screen := BOARD END
      ELSIF ev.key = "u" THEN
        HandleUndo
      ELSIF ~gameOver THEN
        IF screen = BOARD THEN HandleBoardKey(ev.key) END
      END;
      IF (screen = LIST) & (ev.key # TUI.KTab) & (ev.key # "u") THEN HandleListKey(ev.key) END;
      DrawScreen
    ELSIF ev.kind = TUI.EvMouse THEN
      IF (screen = BOARD) & ~gameOver THEN HandleBoardMouse(ev.mx, ev.my, ev.mb) END;
      DrawScreen
    ELSIF ev.kind = TUI.EvResize THEN
      TUI.UpdateSize; DrawScreen
    END
  END;

  TUI.Done
END Play;

BEGIN
  pieceValues[0] := 0;   pieceValues[1] := 10;  pieceValues[2] := 90;
  pieceValues[3] := 40;  pieceValues[4] := 20;  pieceValues[5] := 45;
  pieceValues[6] := 999; pieceValues[7] := 20;
  rookVec[0] := -16; rookVec[1] := 16; rookVec[2] := -1; rookVec[3] := 1;
  bishopVec[0] := -17; bishopVec[1] := 17; bishopVec[2] := -15; bishopVec[3] := 15;
  (* horse: up-L, up-R, down-R, down-L, left-U, left-D, right-U, right-D *)
  horseVec[0] := -33; horseVec[1] := -31; horseVec[2] := 33;  horseVec[3] := 31;
  horseVec[4] := -18; horseVec[5] := 14;  horseVec[6] := -14; horseVec[7] := 18;
  horseBlock[0] := -16; horseBlock[1] := -16; horseBlock[2] := 16;  horseBlock[3] := 16;
  horseBlock[4] := -1;  horseBlock[5] := -1;  horseBlock[6] := 1;   horseBlock[7] := 1;
  (* elephant: NW, NE, SW, SE — two diagonal steps *)
  elephantVec[0] := -34; elephantVec[1] := -30; elephantVec[2] := 30;  elephantVec[3] := 34;
  elephantBlock[0] := -17; elephantBlock[1] := -15; elephantBlock[2] := 15; elephantBlock[3] := 17;
  Play
END Xiangqi.

