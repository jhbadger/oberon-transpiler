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
  
  (* Movement Vectors *)
  rookVec, bishopVec: ARRAY 4 OF INTEGER;
  knightVec: ARRAY 8 OF INTEGER;

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
    (* Check bit 3 (value 8) - this is the 0x88 test *)
    IF (i DIV 8) MOD 2 = 1 THEN board[i] := FRONTIER ELSE board[i] := EMPTY END;
  END;

  FOR i := 0 TO 7 DO
    board[i] := rank[i];                 (* Black Back Rank *)
    board[i + 16] := PAWN;               (* Black Pawns *)
    board[i + 96] := PAWN + SIDE;        (* White Pawns *)
    board[i + 112] := rank[i] + SIDE;    (* White Back Rank *)
  END;
END InitBoard;

PROCEDURE IsOnBoard(pos: INTEGER): BOOLEAN;
BEGIN
  (* A square is on board if (pos AND 0x88) == 0 *)
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

PROCEDURE Evaluate(turn, depth: INTEGER; VAR bestF, bestT: INTEGER): INTEGER;
VAR f, t, p, i, step, target, score, bestScore, captured, movingP: INTEGER;
    dummyF, dummyT: INTEGER;
BEGIN
  IF depth = 0 THEN RETURN 0 END;
  bestScore := -2000;

  FOR f := 0 TO 127 DO
    IF IsOnBoard(f) & (board[f] # EMPTY) & (((board[f] DIV SIDE) MOD 2) * SIDE = turn) THEN
      p := board[f] MOD 8;
      FOR i := 0 TO 7 DO
        step := 0;
        IF p = ROOK THEN IF i < 4 THEN step := rookVec[i] END;
        ELSIF p = BISHOP THEN IF i < 4 THEN step := bishopVec[i] END;
        ELSIF p = KNIGHT THEN step := knightVec[i];
        ELSIF (p = QUEEN) OR (p = KING) THEN 
          IF i < 4 THEN step := rookVec[i] ELSE step := bishopVec[i-4] END;
        ELSIF p = PAWN THEN
          IF turn = SIDE THEN 
             IF i = 0 THEN step := -16 END; (* Forward only for now *)
          ELSE 
             IF i = 0 THEN step := 16 END;
          END;
        END;

        IF step # 0 THEN
          target := f;
          LOOP
            target := target + step;
            IF ~IsOnBoard(target) THEN EXIT END;
            captured := board[target];
            IF (captured # EMPTY) & (((captured DIV SIDE) MOD 2) * SIDE = turn) THEN EXIT END;

            movingP := board[f];
            board[target] := movingP; board[f] := EMPTY;
            score := pieceValues[captured MOD 8] - Evaluate(SIDE - turn, depth - 1, dummyF, dummyT);
            board[f] := movingP; board[target] := captured;

            IF score > bestScore THEN
              bestScore := score;
              IF depth = 3 THEN bestF := f; bestT := target END;
            END;

            IF (captured # EMPTY) OR (p = KNIGHT) OR (p = KING) OR (p = PAWN) THEN EXIT END;
          END;
        END;
      END;
    END;
  END;
  RETURN bestScore;
END Evaluate;

PROCEDURE Run*;
VAR input: ARRAY 16 OF CHAR;
    from, to, bf, bt, res: INTEGER;
BEGIN
  InitBoard;
  LOOP
    Display;
    Out.String("Your move (e.g. e2e4): ");
    In.String(input);
    
    (* Simple algebraic to index conversion *)
    from := (8 - (ORD(input[1]) - ORD("0"))) * 16 + (ORD(input[0]) - ORD("a"));
    to := (8 - (ORD(input[3]) - ORD("0"))) * 16 + (ORD(input[2]) - ORD("a"));
    
    IF IsOnBoard(from) & IsOnBoard(to) THEN
      board[to] := board[from]; board[from] := EMPTY;
      Out.String("Thinking..."); Out.Ln;
      res := Evaluate(0, 3, bf, bt); 
      IF IsOnBoard(bf) & IsOnBoard(bt) THEN
        board[bt] := board[bf]; board[bf] := EMPTY;
      END;
    ELSE
      Out.String("Invalid move format."); Out.Ln;
    END;
  END;
END Run;

BEGIN
    Run;
END Chess.

