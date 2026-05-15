MODULE Chess;

(* Inspired by Oscar Toledo Gutierrez's Toledo Atomchess engine *)

IMPORT Out, In;

CONST
  EMPTY    = 0;
  PAWN     = 1;
  ROOK     = 2;
  KNIGHT   = 3;
  BISHOP   = 4;
  QUEEN    = 5;
  KING     = 6;
  FRONTIER = 7;
  SIDE     = 32; (* 0x20 *)

VAR
  board: ARRAY 128 OF INTEGER;
  pieceValues: ARRAY 7 OF INTEGER;
  pieceChars: ARRAY 8 OF CHAR;
  maxDepth: INTEGER;
  epSquare: INTEGER;      (* en passant target square, -1 if none *)
  castleRights: INTEGER;  (* bits: 1=WK, 2=WQ, 4=BK, 8=BQ *)

  (* Movement Vectors *)
  rookVec, bishopVec: ARRAY 4 OF INTEGER;
  knightVec: ARRAY 8 OF INTEGER;

PROCEDURE ClearCastle(bit: INTEGER);
BEGIN
  IF castleRights MOD (bit * 2) >= bit THEN castleRights := castleRights - bit END;
END ClearCastle;

PROCEDURE KingFound(side: INTEGER): BOOLEAN;
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO 127 DO
    IF IsOnBoard(i) & (board[i] MOD 8 = KING) &
       (((board[i] DIV SIDE) MOD 2) * SIDE = side) THEN
      RETURN TRUE
    END
  END;
  RETURN FALSE
END KingFound;

PROCEDURE InitBoard;
VAR i: INTEGER;
    rank: ARRAY 8 OF INTEGER;
BEGIN
  pieceValues[0] := 0; pieceValues[1] := 10; pieceValues[2] := 50;
  pieceValues[3] := 30; pieceValues[4] := 31; pieceValues[5] := 90;
  pieceValues[6] := 999;
  COPY(".prnbqk", pieceChars);

  rank[0] := ROOK; rank[1] := KNIGHT; rank[2] := BISHOP; rank[3] := QUEEN;
  rank[4] := KING; rank[5] := BISHOP; rank[6] := KNIGHT; rank[7] := ROOK;

  rookVec[0] := -16; rookVec[1] := 16; rookVec[2] := -1; rookVec[3] := 1;
  bishopVec[0] := -17; bishopVec[1] := -15; bishopVec[2] := 17; bishopVec[3] := 15;

  knightVec[0] := -33; knightVec[1] := -31; knightVec[2] := -18; knightVec[3] := -14;
  knightVec[4] := 14; knightVec[5] := 18; knightVec[6] := 31; knightVec[7] := 33;

  FOR i := 0 TO 127 DO
    IF (i DIV 8) MOD 2 = 1 THEN board[i] := FRONTIER ELSE board[i] := EMPTY END;
  END;

  FOR i := 0 TO 7 DO
    board[i] := rank[i];              (* Black Back Rank *)
    board[i + 16] := PAWN;            (* Black Pawns *)
    board[i + 96] := PAWN + SIDE;     (* White Pawns *)
    board[i + 112] := rank[i] + SIDE; (* White Back Rank *)
  END;
  epSquare := -1;
  castleRights := 15;
END InitBoard;

PROCEDURE IsOnBoard(pos: INTEGER): BOOLEAN;
BEGIN
  RETURN (pos >= 0) & (pos <= 127) & ((pos DIV 8) MOD 2 = 0) & ((pos DIV 128) = 0);
END IsOnBoard;

PROCEDURE Display;
VAR r, c, pos, p: INTEGER; ch: CHAR;
BEGIN
  Out.String("    a b c d e f g h"); Out.Ln;
  Out.String("  +-----------------"); Out.Ln;
  FOR r := 0 TO 7 DO
    Out.Int(8 - r, 1); Out.String(" | ");
    FOR c := 0 TO 7 DO
      pos := r * 16 + c;
      p := board[pos];
      ch := pieceChars[p MOD 8];
      IF p >= SIDE THEN Out.Char(CAP(ch)) ELSE Out.Char(ch) END;
      Out.Char(" ");
    END;
    Out.Ln;
  END;
END Display;

PROCEDURE KingPos(side: INTEGER): INTEGER;
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO 127 DO
    IF IsOnBoard(i) & (board[i] MOD 8 = KING) &
       (((board[i] DIV SIDE) MOD 2) * SIDE = side) THEN
      RETURN i
    END
  END;
  RETURN -1
END KingPos;

PROCEDURE IsAttacked(pos, bySide: INTEGER): BOOLEAN;
VAR i, sq: INTEGER;
BEGIN
  FOR i := 0 TO 7 DO
    sq := pos + knightVec[i];
    IF IsOnBoard(sq) & (board[sq] MOD 8 = KNIGHT) &
       (((board[sq] DIV SIDE) MOD 2) * SIDE = bySide) THEN
      RETURN TRUE
    END
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
           ((board[sq] MOD 8 = BISHOP) OR (board[sq] MOD 8 = QUEEN)) THEN
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
       (((board[sq] DIV SIDE) MOD 2) * SIDE = bySide) THEN
      RETURN TRUE
    END;
    sq := pos + bishopVec[i];
    IF IsOnBoard(sq) & (board[sq] MOD 8 = KING) &
       (((board[sq] DIV SIDE) MOD 2) * SIDE = bySide) THEN
      RETURN TRUE
    END
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
VAR kpos: INTEGER;
BEGIN
  kpos := KingPos(side);
  IF kpos < 0 THEN RETURN FALSE END;
  RETURN IsAttacked(kpos, SIDE - side)
END InCheck;

(* Alpha-beta minimax. score = captureValue - Evaluate(opponent).
   Window [alpha, beta] is from the current player's perspective.
   Recursive call uses the transformed window (cv-beta, cv-alpha). *)
PROCEDURE Evaluate(turn, depth, alpha, beta: INTEGER; VAR bestF, bestT: INTEGER): INTEGER;
VAR f, t, p, i, step, target, score, bestScore, captured, movingP: INTEGER;
    dummyF, dummyT: INTEGER;
    isPawnDiag, isEP: BOOLEAN;
    epCapturePos, savedEP, epCapturedPiece, captureValue: INTEGER;
    savedCastle: INTEGER;
BEGIN
  IF depth = 0 THEN RETURN 0 END;
  bestScore := alpha;  (* fail-low sentinel; any improvement updates alpha *)

  FOR f := 0 TO 127 DO
    IF IsOnBoard(f) & (board[f] # EMPTY) & (((board[f] DIV SIDE) MOD 2) * SIDE = turn) THEN
      p := board[f] MOD 8;
      FOR i := 0 TO 7 DO
        step := 0; isPawnDiag := FALSE; isEP := FALSE; epCapturePos := -1;
        IF p = ROOK THEN IF i < 4 THEN step := rookVec[i] END;
        ELSIF p = BISHOP THEN IF i < 4 THEN step := bishopVec[i] END;
        ELSIF p = KNIGHT THEN step := knightVec[i];
        ELSIF (p = QUEEN) OR (p = KING) THEN
          IF i < 4 THEN step := rookVec[i] ELSE step := bishopVec[i-4] END;
        ELSIF p = PAWN THEN
          IF turn = SIDE THEN
            IF i = 0 THEN step := -16
            ELSIF i = 1 THEN
              IF (f >= 96) & (f <= 103) & (board[f - 16] = EMPTY) THEN step := -32 END
            ELSIF i = 2 THEN step := -17; isPawnDiag := TRUE
            ELSIF i = 3 THEN step := -15; isPawnDiag := TRUE
            END;
          ELSE
            IF i = 0 THEN step := 16
            ELSIF i = 1 THEN
              IF (f >= 16) & (f <= 23) & (board[f + 16] = EMPTY) THEN step := 32 END
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
                IF (captured = EMPTY) & (target # epSquare) THEN EXIT END;
                IF target = epSquare THEN
                  isEP := TRUE;
                  IF turn = SIDE THEN epCapturePos := target + 16
                  ELSE epCapturePos := target - 16
                  END;
                END;
              ELSE
                IF captured # EMPTY THEN EXIT END;
              END;
            END;

            (* Make move *)
            movingP := board[f];
            board[target] := movingP; board[f] := EMPTY;

            (* Pawn promotion: replace with queen on last rank *)
            IF (p = PAWN) & ((target < 8) OR (target >= 112)) THEN
              IF turn = SIDE THEN board[target] := QUEEN + SIDE
              ELSE board[target] := QUEEN
              END;
            END;

            epCapturedPiece := EMPTY;
            IF isEP THEN
              epCapturedPiece := board[epCapturePos];
              board[epCapturePos] := EMPTY;
            END;

            savedEP := epSquare;
            IF (p = PAWN) & ((step = -32) OR (step = 32)) THEN
              IF turn = SIDE THEN epSquare := f - 16 ELSE epSquare := f + 16 END;
            ELSE
              epSquare := -1;
            END;

            savedCastle := castleRights;
            IF f = 116 THEN ClearCastle(1); ClearCastle(2)
            ELSIF f = 119 THEN ClearCastle(1)
            ELSIF f = 112 THEN ClearCastle(2)
            ELSIF f = 4   THEN ClearCastle(4); ClearCastle(8)
            ELSIF f = 7   THEN ClearCastle(4)
            ELSIF f = 0   THEN ClearCastle(8)
            END;
            IF target = 119 THEN ClearCastle(1) END;
            IF target = 112 THEN ClearCastle(2) END;
            IF target = 7   THEN ClearCastle(4) END;
            IF target = 0   THEN ClearCastle(8) END;

            IF ~InCheck(turn) THEN
              IF isEP THEN captureValue := pieceValues[epCapturedPiece MOD 8]
              ELSE captureValue := pieceValues[captured MOD 8]
              END;
              IF (p = PAWN) & ((target < 8) OR (target >= 112)) THEN
                captureValue := captureValue + pieceValues[QUEEN] - pieceValues[PAWN];
              END;

              score := captureValue - Evaluate(SIDE - turn, depth - 1,
                         captureValue - beta, captureValue - alpha, dummyF, dummyT);

              (* Unmake move *)
              board[f] := movingP; board[target] := captured;
              IF isEP THEN board[epCapturePos] := epCapturedPiece END;
              epSquare := savedEP;
              castleRights := savedCastle;

              IF score > bestScore THEN
                bestScore := score;
                IF depth = maxDepth THEN bestF := f; bestT := target END;
                alpha := bestScore;
                IF alpha >= beta THEN RETURN bestScore END;  (* beta cutoff *)
              END;
            ELSE
              board[f] := movingP; board[target] := captured;
              IF isEP THEN board[epCapturePos] := epCapturedPiece END;
              epSquare := savedEP;
              castleRights := savedCastle;
            END;

            IF (captured # EMPTY) OR (p = KNIGHT) OR (p = KING) OR (p = PAWN) THEN EXIT END;
          END;
        END;
      END;

      (* Castling *)
      IF p = KING THEN
        IF turn = SIDE THEN
          (* White kingside: e1(116)->g1(118), h1(119)->f1(117) *)
          IF (castleRights MOD 2 = 1) & (f = 116) &
             (board[117] = EMPTY) & (board[118] = EMPTY) THEN
            board[118] := KING + SIDE; board[116] := EMPTY;
            board[117] := ROOK + SIDE; board[119] := EMPTY;
            savedEP := epSquare; epSquare := -1;
            savedCastle := castleRights; ClearCastle(1); ClearCastle(2);
            score := -Evaluate(SIDE - turn, depth - 1, -beta, -alpha, dummyF, dummyT);
            board[116] := KING + SIDE; board[118] := EMPTY;
            board[119] := ROOK + SIDE; board[117] := EMPTY;
            epSquare := savedEP; castleRights := savedCastle;
            IF score > bestScore THEN
              bestScore := score;
              IF depth = maxDepth THEN bestF := 116; bestT := 118 END;
              alpha := bestScore;
              IF alpha >= beta THEN RETURN bestScore END;
            END;
          END;
          (* White queenside: e1(116)->c1(114), a1(112)->d1(115) *)
          IF (castleRights MOD 4 >= 2) & (f = 116) &
             (board[115] = EMPTY) & (board[114] = EMPTY) & (board[113] = EMPTY) THEN
            board[114] := KING + SIDE; board[116] := EMPTY;
            board[115] := ROOK + SIDE; board[112] := EMPTY;
            savedEP := epSquare; epSquare := -1;
            savedCastle := castleRights; ClearCastle(1); ClearCastle(2);
            score := -Evaluate(SIDE - turn, depth - 1, -beta, -alpha, dummyF, dummyT);
            board[116] := KING + SIDE; board[114] := EMPTY;
            board[112] := ROOK + SIDE; board[115] := EMPTY;
            epSquare := savedEP; castleRights := savedCastle;
            IF score > bestScore THEN
              bestScore := score;
              IF depth = maxDepth THEN bestF := 116; bestT := 114 END;
              alpha := bestScore;
              IF alpha >= beta THEN RETURN bestScore END;
            END;
          END;
        ELSE
          (* Black kingside: e8(4)->g8(6), h8(7)->f8(5) *)
          IF (castleRights MOD 8 >= 4) & (f = 4) &
             (board[5] = EMPTY) & (board[6] = EMPTY) THEN
            board[6] := KING; board[4] := EMPTY;
            board[5] := ROOK; board[7] := EMPTY;
            savedEP := epSquare; epSquare := -1;
            savedCastle := castleRights; ClearCastle(4); ClearCastle(8);
            score := -Evaluate(SIDE - turn, depth - 1, -beta, -alpha, dummyF, dummyT);
            board[4] := KING; board[6] := EMPTY;
            board[7] := ROOK; board[5] := EMPTY;
            epSquare := savedEP; castleRights := savedCastle;
            IF score > bestScore THEN
              bestScore := score;
              IF depth = maxDepth THEN bestF := 4; bestT := 6 END;
              alpha := bestScore;
              IF alpha >= beta THEN RETURN bestScore END;
            END;
          END;
          (* Black queenside: e8(4)->c8(2), a8(0)->d8(3) *)
          IF (castleRights MOD 16 >= 8) & (f = 4) &
             (board[3] = EMPTY) & (board[2] = EMPTY) & (board[1] = EMPTY) THEN
            board[2] := KING; board[4] := EMPTY;
            board[3] := ROOK; board[0] := EMPTY;
            savedEP := epSquare; epSquare := -1;
            savedCastle := castleRights; ClearCastle(4); ClearCastle(8);
            score := -Evaluate(SIDE - turn, depth - 1, -beta, -alpha, dummyF, dummyT);
            board[4] := KING; board[2] := EMPTY;
            board[0] := ROOK; board[3] := EMPTY;
            epSquare := savedEP; castleRights := savedCastle;
            IF score > bestScore THEN
              bestScore := score;
              IF depth = maxDepth THEN bestF := 4; bestT := 2 END;
              alpha := bestScore;
              IF alpha >= beta THEN RETURN bestScore END;
            END;
          END;
        END;
      END;

    END;
  END;
  RETURN bestScore;
END Evaluate;

PROCEDURE Run*;
VAR input: ARRAY 16 OF CHAR;
    choice: ARRAY 4 OF CHAR;
    from, to, bf, bt, res, movingP: INTEGER;
    isHumanEP, isComputerEP: BOOLEAN;
    isCastle, isComputerCastle: BOOLEAN;
    humanSide, computerSide: INTEGER;
    computerFirst: BOOLEAN;
BEGIN
  InitBoard;
  Out.String("Search depth (1=easy, 3=medium, 5=hard): ");
  In.Int(maxDepth);
  Out.String("Play as (w)hite or (b)lack? ");
  In.Line(choice);
  IF (choice[0] = "b") OR (choice[0] = "B") THEN
    humanSide := 0; computerSide := SIDE;
    Out.String("You play Black; computer plays White."); Out.Ln;
  ELSE
    humanSide := SIDE; computerSide := 0;
    Out.String("You play White; computer plays Black."); Out.Ln;
  END;
  computerFirst := computerSide = SIDE;

  LOOP
    Display;
    IF computerFirst THEN
      computerFirst := FALSE;
    ELSE
      Out.String("Your move (e.g. e2e4, e1g1 to castle): ");
      In.String(input);

      from := (8 - (ORD(input[1]) - ORD("0"))) * 16 + (ORD(input[0]) - ORD("a"));
      to   := (8 - (ORD(input[3]) - ORD("0"))) * 16 + (ORD(input[2]) - ORD("a"));

      IF IsOnBoard(from) & IsOnBoard(to) THEN
        movingP   := board[from];
        isHumanEP := (movingP MOD 8 = PAWN) & (to = epSquare);
        isCastle  := (movingP MOD 8 = KING) & ((to - from = 2) OR (to - from = -2));

        board[to] := movingP; board[from] := EMPTY;

        IF isHumanEP THEN
          IF humanSide = SIDE THEN board[to + 16] := EMPTY
          ELSE board[to - 16] := EMPTY
          END
        END;
        IF isCastle THEN
          IF to - from = 2 THEN
            board[to - 1] := board[to + 1]; board[to + 1] := EMPTY;
          ELSE
            board[to + 1] := board[to - 2]; board[to - 2] := EMPTY;
          END;
        END;
        IF (movingP MOD 8 = PAWN) &
           ((humanSide = SIDE) & (to < 8) OR (humanSide = 0) & (to >= 112)) THEN
          board[to] := QUEEN + humanSide;
          Out.String("Pawn promoted to queen."); Out.Ln;
        END;

        IF (movingP MOD 8 = PAWN) &
           ((humanSide = SIDE) & (to - from = -32) OR (humanSide = 0) & (to - from = 32)) THEN
          epSquare := (from + to) DIV 2;
        ELSE
          epSquare := -1;
        END;

        IF movingP MOD 8 = KING THEN
          IF humanSide = SIDE THEN ClearCastle(1); ClearCastle(2)
          ELSE ClearCastle(4); ClearCastle(8)
          END
        ELSIF humanSide = SIDE THEN
          IF from = 119 THEN ClearCastle(1) END;
          IF from = 112 THEN ClearCastle(2) END;
        ELSE
          IF from = 7 THEN ClearCastle(4) END;
          IF from = 0 THEN ClearCastle(8) END;
        END;
        IF to = 7   THEN ClearCastle(4) END;
        IF to = 0   THEN ClearCastle(8) END;
        IF to = 119 THEN ClearCastle(1) END;
        IF to = 112 THEN ClearCastle(2) END;

        IF ~KingFound(computerSide) THEN
          Display;
          Out.String("You win!"); Out.Ln;
          EXIT
        END;
      ELSE
        Out.String("Invalid move format."); Out.Ln;
      END;
    END;

    Out.String("Thinking..."); Out.Ln;
    bf := -1; bt := -1;
    res := Evaluate(computerSide, maxDepth, -2000, 2000, bf, bt);

    IF ~IsOnBoard(bf) OR ~IsOnBoard(bt) THEN
      Display;
      Out.String("Checkmate or stalemate — game over."); Out.Ln;
      EXIT
    END;

    isComputerEP     := (board[bf] MOD 8 = PAWN) & (bt = epSquare);
    isComputerCastle := (board[bf] MOD 8 = KING) & ((bt - bf = 2) OR (bt - bf = -2));

    Out.String("Computer plays: ");
    Out.Char(CHR(ORD("a") + (bf MOD 16)));
    Out.Char(CHR(ORD("0") + 8 - (bf DIV 16)));
    Out.Char(CHR(ORD("a") + (bt MOD 16)));
    Out.Char(CHR(ORD("0") + 8 - (bt DIV 16)));
    Out.Ln;

    board[bt] := board[bf]; board[bf] := EMPTY;

    IF isComputerEP THEN
      IF computerSide = 0 THEN board[bt - 16] := EMPTY
      ELSE board[bt + 16] := EMPTY
      END
    END;
    IF isComputerCastle THEN
      IF bt - bf = 2 THEN
        board[bt - 1] := board[bt + 1]; board[bt + 1] := EMPTY;
      ELSE
        board[bt + 1] := board[bt - 2]; board[bt - 2] := EMPTY;
      END;
    END;
    IF (board[bt] MOD 8 = PAWN) &
       ((computerSide = 0) & (bt >= 112) OR (computerSide = SIDE) & (bt < 8)) THEN
      board[bt] := QUEEN + computerSide;
      Out.String("Computer promotes to queen."); Out.Ln;
    END;

    IF (board[bt] MOD 8 = PAWN) &
       ((computerSide = 0) & (bt - bf = 32) OR (computerSide = SIDE) & (bt - bf = -32)) THEN
      epSquare := (bf + bt) DIV 2;
    ELSE
      epSquare := -1;
    END;

    IF board[bt] MOD 8 = KING THEN
      IF computerSide = 0 THEN ClearCastle(4); ClearCastle(8)
      ELSE ClearCastle(1); ClearCastle(2)
      END
    ELSIF computerSide = 0 THEN
      IF bf = 7   THEN ClearCastle(4) END;
      IF bf = 0   THEN ClearCastle(8) END;
    ELSE
      IF bf = 119 THEN ClearCastle(1) END;
      IF bf = 112 THEN ClearCastle(2) END;
    END;
    IF bt = 7   THEN ClearCastle(4) END;
    IF bt = 0   THEN ClearCastle(8) END;
    IF bt = 119 THEN ClearCastle(1) END;
    IF bt = 112 THEN ClearCastle(2) END;

    IF ~KingFound(humanSide) THEN
      Display;
      Out.String("Computer wins!"); Out.Ln;
      EXIT
    END;
  END;
END Run;

BEGIN
    Run;
END Chess.
