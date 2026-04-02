MODULE Sudoku;
(*
 * Sudoku — interactive terminal puzzle.
 *
 * Controls: Arrow keys or Z/S/Q/D to move.
 *           1-9 to enter a digit, Space to erase, P to quit.
 *
 * Adapted from CrYmFoX 2016 (Pascal original).
 *
 * M stored column-major: M[(col-1)*9 + (row-1)], row/col are 1..9.
 * xy1/xy2 store terminal (x,y) of each fixed (given) cell, 0-based index.
 *)
IMPORT Terminal, Out;

CONST
  KUp    = 01X;
  KDown  = 02X;
  KLeft  = 03X;
  KRight = 04X;
  KEnter = 0DX;

VAR
  j, l, o, p, q             : INTEGER;
  limk1, limk2, limi1, limi2 : INTEGER;
  ch                         : CHAR;
  x, y, no1, no2, i, s, k   : INTEGER;
  nfixed                     : INTEGER;
  b, t, v, quit              : BOOLEAN;
  playAgain, boardOk         : BOOLEAN;
  key, yn                    : CHAR;
  M   : ARRAY 81 OF CHAR;      (* board cells                *)
  xy1 : ARRAY 81 OF INTEGER;   (* terminal x of fixed cells  *)
  xy2 : ARRAY 81 OF INTEGER;   (* terminal y of fixed cells  *)


(* ── Cell accessors ───────────────────────────────────────────────── *)

PROCEDURE MCell(row, col : INTEGER) : CHAR;
BEGIN
  RETURN M[(col - 1) * 9 + row - 1]
END MCell;

PROCEDURE SetCell(row, col : INTEGER; c : CHAR);
BEGIN
  M[(col - 1) * 9 + row - 1] := c
END SetCell;


(* ── Helpers ──────────────────────────────────────────────────────── *)

PROCEDURE BoxLo(val : INTEGER) : INTEGER;
BEGIN
  IF    val <= 3 THEN  RETURN 1
  ELSIF val <= 6 THEN  RETURN 4
  ELSE                 RETURN 7
  END
END BoxLo;

PROCEDURE BoxHi(val : INTEGER) : INTEGER;
BEGIN
  IF    val <= 3 THEN  RETURN 3
  ELSIF val <= 6 THEN  RETURN 6
  ELSE                 RETURN 9
  END
END BoxHi;

PROCEDURE IsFixed(cx, cy : INTEGER) : BOOLEAN;
VAR k2 : INTEGER;
BEGIN
  k2 := 0;
  WHILE k2 < nfixed DO
    IF (xy1[k2] = cx) & (xy2[k2] = cy) THEN  RETURN TRUE  END;
    k2 := k2 + 1
  END;
  RETURN FALSE
END IsFixed;

PROCEDURE ClearMsg;
BEGIN
  Terminal.Goto(2, 22);
  Out.String("                                                   ")
END ClearMsg;

PROCEDURE CurCol() : INTEGER;
BEGIN  RETURN ((x - 4) DIV 6) + 1  END CurCol;

PROCEDURE CurRow() : INTEGER;
BEGIN  RETURN ((y - 2) DIV 2) + 1  END CurRow;


(* ── Board generation ─────────────────────────────────────────────── *)

PROCEDURE GenerateBoard;
BEGIN
  boardOk := FALSE;
  WHILE ~boardOk DO
    FOR i := 0 TO 80 DO  M[i] := ' '  END;
    boardOk := TRUE;
    k := 1;
    WHILE (k <= 9) & boardOk DO
      limk1 := BoxLo(k);  limk2 := BoxHi(k);
      no2 := 0;
      i := 1;
      WHILE (i <= 9) & boardOk DO
        limi1 := BoxLo(i);  limi2 := BoxHi(i);
        no1 := 0;
        b := FALSE;
        WHILE ~b DO
          no1 := no1 + 1;
          ch := CHR(ORD('1') + Terminal.Random(9));
          b := TRUE;
          FOR j := 1 TO 9 DO
            IF ch = MCell(j, k) THEN  b := FALSE  END
          END;
          FOR l := 1 TO 9 DO
            IF ch = MCell(i, l) THEN  b := FALSE  END
          END;
          FOR p := limk1 TO limk2 DO
            FOR q := limi1 TO limi2 DO
              IF ch = MCell(q, p) THEN  b := FALSE  END
            END
          END;
          IF b THEN
            SetCell(i, k, ch)
          ELSIF no1 >= 100 THEN
            FOR o := 1 TO 9 DO  SetCell(o, k, ' ')  END;
            no2 := no2 + 1;
            IF no2 >= 100 THEN
              boardOk := FALSE
            ELSE
              i := 0
            END;
            b := TRUE
          END
        END;
        i := i + 1
      END;
      k := k + 1
    END
  END
END GenerateBoard;


(* ── Drawing ──────────────────────────────────────────────────────── *)

PROCEDURE DrawBoard;
BEGIN
  Terminal.Clear;
  Out.String(" _____________________________________________________ ");  Out.Ln;
  Out.String("|     |     |     |     |     |     |     |     |     |");  Out.Ln;
  Out.String("|_____|_____|_____|_____|_____|_____|_____|_____|_____|");  Out.Ln;
  Out.String("|     |     |     |     |     |     |     |     |     |");  Out.Ln;
  Out.String("|_____|_____|_____|_____|_____|_____|_____|_____|_____|");  Out.Ln;
  Out.String("|     |     |     |     |     |     |     |     |     |");  Out.Ln;
  Out.String("|_____|_____|_____|_____|_____|_____|_____|_____|_____|");  Out.Ln;
  Out.String("|     |     |     |     |     |     |     |     |     |");  Out.Ln;
  Out.String("|_____|_____|_____|_____|_____|_____|_____|_____|_____|");  Out.Ln;
  Out.String("|     |     |     |     |     |     |     |     |     |");  Out.Ln;
  Out.String("|_____|_____|_____|_____|_____|_____|_____|_____|_____|");  Out.Ln;
  Out.String("|     |     |     |     |     |     |     |     |     |");  Out.Ln;
  Out.String("|_____|_____|_____|_____|_____|_____|_____|_____|_____|");  Out.Ln;
  Out.String("|     |     |     |     |     |     |     |     |     |");  Out.Ln;
  Out.String("|_____|_____|_____|_____|_____|_____|_____|_____|_____|");  Out.Ln;
  Out.String("|     |     |     |     |     |     |     |     |     |");  Out.Ln;
  Out.String("|_____|_____|_____|_____|_____|_____|_____|_____|_____|");  Out.Ln;
  Out.String("|     |     |     |     |     |     |     |     |     |");  Out.Ln;
  Out.String("|_____|_____|_____|_____|_____|_____|_____|_____|_____|");  Out.Ln;

  Terminal.Goto(60, 3);   Out.String("+Instructions+");
  Terminal.Goto(57, 5);   Out.String("*Keys to move:");
  Terminal.Goto(58, 6);   Out.String("Arrow keys or Z/S/Q/D.");
  Terminal.Goto(57, 9);   Out.String("*Enter numbers 1-9.");
  Terminal.Goto(58, 10);  Out.Char('"');  Out.String("Space");
  Out.Char('"');           Out.String(" to erase.");
  Terminal.Goto(57, 13);  Out.String("-----------------------");
  Terminal.Goto(57, 15);  Out.String('*Press "P" to exit.');
  Terminal.Goto(57, 17);  Out.String("-----------------------");
  Terminal.Goto(63, 19);  Out.String("Enjoy! ^-^")
END DrawBoard;

PROCEDURE PlaceNumbers;
VAR cx, cy, pk, pi : INTEGER;
BEGIN
  cx := 4;
  FOR pk := 1 TO 9 DO
    cy := 2;
    FOR pi := 1 TO 9 DO
      Terminal.Goto(cx, cy);
      Out.Char(MCell(pi, pk));
      cy := cy + 2
    END;
    cx := cx + 6
  END
END PlaceNumbers;

PROCEDURE RecordFixed;
VAR rk, ri : INTEGER;
BEGIN
  nfixed := 0;
  FOR rk := 1 TO 9 DO
    FOR ri := 1 TO 9 DO
      IF MCell(ri, rk) # ' ' THEN
        xy1[nfixed] := (rk - 1) * 6 + 4;
        xy2[nfixed] := (ri - 1) * 2 + 2;
        nfixed := nfixed + 1
      END
    END
  END
END RecordFixed;


(* ── Game loop ────────────────────────────────────────────────────── *)

PROCEDURE RunGame;
BEGIN
  GenerateBoard;
  FOR i := 1 TO 38 DO
    limi1 := Terminal.Random(9) + 1;
    limi2 := Terminal.Random(9) + 1;
    SetCell(limi1, limi2, ' ')
  END;
  DrawBoard;
  PlaceNumbers;
  RecordFixed;

  x := 28;  y := 10;
  Terminal.ShowCursor;
  Terminal.Goto(x, y);
  quit := FALSE;
  v    := FALSE;

  WHILE ~quit DO
    key := Terminal.ReadKey();

    IF (key = KUp) OR (key = 'z') THEN
      ClearMsg;  y := y - 2
    ELSIF (key = KDown) OR (key = 's') THEN
      ClearMsg;  y := y + 2
    ELSIF (key = KLeft) OR (key = 'q') THEN
      ClearMsg;  x := x - 6
    ELSIF (key = KRight) OR (key = 'd') THEN
      ClearMsg;  x := x + 6
    ELSIF key = 'p' THEN
      quit := TRUE
    ELSIF key = ' ' THEN
      ClearMsg;
      IF ~IsFixed(x, y) THEN
        SetCell(CurRow(), CurCol(), ' ');
        Terminal.Goto(x, y);  Out.Char(' ')
      END
    ELSIF (key >= '1') & (key <= '9') THEN
      ClearMsg;
      IF ~IsFixed(x, y) THEN
        limk1 := BoxLo(CurCol());  limk2 := BoxHi(CurCol());
        limi1 := BoxLo(CurRow());  limi2 := BoxHi(CurRow());
        t := TRUE;
        FOR j := 1 TO 9 DO
          IF key = MCell(j, CurCol()) THEN  t := FALSE  END
        END;
        FOR l := 1 TO 9 DO
          IF key = MCell(CurRow(), l) THEN  t := FALSE  END
        END;
        FOR s := limk1 TO limk2 DO
          FOR o := limi1 TO limi2 DO
            IF key = MCell(o, s) THEN  t := FALSE  END
          END
        END;
        IF t THEN
          SetCell(CurRow(), CurCol(), key);
          Terminal.Goto(x, y);  Out.Char(key)
        ELSE
          IF key = MCell(CurRow(), CurCol()) THEN
            Terminal.Goto(2, 22);  Out.String("#Already entered!#")
          ELSE
            Terminal.Goto(2, 22);  Out.String("#Not valid here#")
          END
        END
      END
    END;

    IF ~quit THEN
      IF y < 2  THEN  y := 2   END;
      IF y > 18 THEN  y := 18  END;
      IF x < 4  THEN  x := 4   END;
      IF x > 52 THEN  x := 52  END;
      Terminal.Goto(x, y);
      v := TRUE;
      FOR k := 1 TO 9 DO
        FOR i := 1 TO 9 DO
          IF MCell(i, k) = ' ' THEN  v := FALSE  END
        END
      END;
      IF v THEN  quit := TRUE  END
    END
  END;

  Terminal.HideCursor;
  playAgain := FALSE;
  IF v THEN
    Terminal.Clear;
    Terminal.Goto(17, 11);  Out.String("Excellent! You solved the puzzle!");
    Terminal.Goto(17, 13);  Out.String("Play again? (Y/N)");
    REPEAT
      yn := Terminal.ReadKey()
    UNTIL (yn = 'Y') OR (yn = 'y') OR (yn = 'N') OR (yn = 'n');
    playAgain := (yn = 'Y') OR (yn = 'y')
  END
END RunGame;


(* ── Main ─────────────────────────────────────────────────────────── *)

BEGIN
  Terminal.Clear;
  Terminal.Goto(11, 11);  Out.String("*Welcome to Sudoku!*");
  Terminal.Goto(11, 12);  Out.String("Press ENTER to start...");
  Terminal.Goto(9,  24);  Out.String("Adapted from CrYmFoX 2016.");
  REPEAT
    yn := Terminal.ReadKey()
  UNTIL yn = KEnter;

  playAgain := TRUE;
  WHILE playAgain DO
    v := FALSE;
    RunGame
  END;

  Terminal.Clear;
  Terminal.Goto(20, 16);  Out.String("Thanks for playing! Press ENTER...");
  REPEAT  yn := Terminal.ReadKey()  UNTIL yn = KEnter
END Sudoku.
