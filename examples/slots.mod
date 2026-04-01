MODULE Slots;
(*
 * Interactive slot machine with animated spinning reels.
 * Press ENTER or SPACE to spin, Q to quit.
 *
 * Layout (fits 80x24):
 *   Title   : row 1
 *   Box     : cols 2-51, rows 3-16
 *   Reels   : 3 reels each showing 3 rows (top / payline / bottom)
 *   Payline : middle row, marked by > < arrows and PAY LINE label
 *   Info    : rows 17-19
 *)

IMPORT Graphics, Terminal, Out;

CONST
  NSym   = 7;   (* number of symbols *)
  NCols  = 3;   (* number of reels   *)
  NRows  = 3;   (* visible rows/reel *)
  CellW  = 13;  (* cell width incl. padding *)
  CellH  = 3;   (* cell height in rows      *)

  (* reel left-edge X positions *)
  R0X = 5;
  R1X = 20;
  R2X = 35;

  (* reel top-edge Y position *)
  ReelY = 5;

  (* payline is the middle row (index 1) *)
  PayRow = 1;

VAR
  result : ARRAY 3 OF INTEGER;     (* final payline symbols after spin *)
  disp   : ARRAY 3, 3 OF INTEGER;  (* currently displayed symbols      *)
  reelX  : ARRAY 3 OF INTEGER;
  wins, spins : INTEGER;
  key : CHAR;
  i, j, r : INTEGER;

(* ------------------------------------------------------------------ *)

PROCEDURE Delay(ms : INTEGER);
VAR t : LONGINT;
BEGIN
  t := Terminal.GetTickCount() + ms;
  REPEAT UNTIL Terminal.GetTickCount() >= t
END Delay;

(* Return a 256-colour background index for each symbol *)
PROCEDURE SymBg(s : INTEGER) : INTEGER;
VAR c : INTEGER;
BEGIN
  IF    s = 0 THEN c := 196  (* 777 – bright red        *)
  ELSIF s = 1 THEN c := 130  (* BAR – dark gold         *)
  ELSIF s = 2 THEN c := 161  (* CHR – pink/cherry       *)
  ELSIF s = 3 THEN c := 226  (* BEL – bright yellow     *)
  ELSIF s = 4 THEN c := 28   (* LEM – dark green        *)
  ELSIF s = 5 THEN c := 208  (* ORG – orange            *)
  ELSE              c := 31  (* DIA – dark cyan         *)
  END;
  RETURN c
END SymBg;

(* Print the 3-character symbol name *)
PROCEDURE DrawSymStr(s : INTEGER);
BEGIN
  IF    s = 0 THEN Out.String("777")
  ELSIF s = 1 THEN Out.String("BAR")
  ELSIF s = 2 THEN Out.String("CHR")
  ELSIF s = 3 THEN Out.String("BEL")
  ELSIF s = 4 THEN Out.String("LEM")
  ELSIF s = 5 THEN Out.String("ORG")
  ELSE              Out.String("DIA")
  END
END DrawSymStr;

(*
 * Draw one symbol cell at (x,y).
 * bright=1 for the payline row (full colour), 0 for dim top/bottom rows.
 *)
PROCEDURE DrawCell(x, y, sym, bright : INTEGER);
VAR bg, fg : INTEGER;
BEGIN
  bg := SymBg(sym);
  IF bright = 1 THEN
    fg := 15
  ELSE
    fg := 8;
    bg := bg - 4;
    IF bg < 16 THEN bg := 16 END
  END;
  Graphics.Color256(fg, bg);
  Graphics.Goto(x,     y);     Out.String("             ");
  Graphics.Goto(x,     y + 1); Out.String("     "); DrawSymStr(sym); Out.String("     ");
  Graphics.Goto(x,     y + 2); Out.String("             ");
  Graphics.Reset
END DrawCell;

(* Draw the three cells of one reel column *)
PROCEDURE DrawReel(col : INTEGER);
VAR row, bright : INTEGER;
BEGIN
  FOR row := 0 TO NRows - 1 DO
    IF row = PayRow THEN bright := 1 ELSE bright := 0 END;
    DrawCell(reelX[col], ReelY + row * CellH, disp[col][row], bright)
  END
END DrawReel;

(* Draw all three reels *)
PROCEDURE DrawAllReels;
BEGIN
  FOR r := 0 TO NCols - 1 DO DrawReel(r) END
END DrawAllReels;

(* Brief flash when a reel locks in *)
PROCEDURE FlashReel(col, sym : INTEGER);
VAR f, bg, py : INTEGER;
BEGIN
  py := ReelY + PayRow * CellH + 1;
  bg := SymBg(sym);
  FOR f := 0 TO 3 DO
    Graphics.Color256(0, 226);
    Graphics.Goto(reelX[col], py);
    Out.String("     "); DrawSymStr(sym); Out.String("     ");
    Graphics.Reset;
    Delay(55);
    Graphics.Color256(15, bg);
    Graphics.Goto(reelX[col], py);
    Out.String("     "); DrawSymStr(sym); Out.String("     ");
    Graphics.Reset;
    Delay(55)
  END
END FlashReel;

(* Draw the static frame: box + payline arrows + labels *)
PROCEDURE DrawFrame;
VAR py : INTEGER;
BEGIN
  py := ReelY + PayRow * CellH + 1;

  Graphics.Box(2, 3, 50, 14);

  Graphics.Color256(11, 0);
  Graphics.Goto(1,  py); Out.Char('>');
  Graphics.Goto(52, py); Out.Char('<');
  Graphics.Reset;

  Graphics.Color256(14, 0);
  Graphics.Goto(1, py - 1); Out.String("PAY");
  Graphics.Goto(1, py + 1); Out.String("LNE");
  Graphics.Reset
END DrawFrame;

(* Redraw the wins/spins counters *)
PROCEDURE DrawStatus;
BEGIN
  Graphics.Color256(7, 0);
  Graphics.Goto(4, 18);
  Out.String("Spins: "); Out.Int(spins, 3);
  Out.String("   Wins: "); Out.Int(wins, 3);
  Graphics.Reset
END DrawStatus;

PROCEDURE ClearResult;
BEGIN
  Graphics.Color256(0, 0);
  Graphics.Goto(4, 17);
  Out.String("                                        ");
  Graphics.Reset
END ClearResult;

PROCEDURE ShowResult;
BEGIN
  Graphics.Goto(4, 17);
  IF (result[0] = result[1]) & (result[1] = result[2]) THEN
    Graphics.Color256(226, 0);
    Out.String("*** JACKPOT!  You win! ***              ");
    INC(wins)
  ELSE
    Graphics.Color256(8, 0);
    Out.String("No match.  Try again!                   ")
  END;
  Graphics.Reset
END ShowResult;

(*
 * Spin animation:
 *   – all 3 reels scramble rapidly
 *   – reels lock in left to right with a flash
 *   – delay gradually increases to simulate deceleration
 *)
PROCEDURE SpinReels;
VAR stopped : ARRAY 3 OF INTEGER;  (* 0=spinning  1=stopped *)
    f, delay, rr, row : INTEGER;
BEGIN
  stopped[0] := 0;  stopped[1] := 0;  stopped[2] := 0;
  f := 0;  delay := 45;

  FOR rr := 0 TO NCols - 1 DO result[rr] := Terminal.Random(NSym) END;

  LOOP
    INC(f);

    (* scramble spinning reels *)
    FOR rr := 0 TO NCols - 1 DO
      IF stopped[rr] = 0 THEN
        FOR row := 0 TO NRows - 1 DO
          disp[rr][row] := Terminal.Random(NSym)
        END
      END
    END;

    DrawAllReels;

    (* lock reels one by one *)
    IF (f = 22) & (stopped[0] = 0) THEN
      stopped[0] := 1;
      disp[0][0] := Terminal.Random(NSym);
      disp[0][1] := result[0];
      disp[0][2] := Terminal.Random(NSym);
      DrawReel(0);
      FlashReel(0, result[0])
    END;
    IF (f = 30) & (stopped[1] = 0) THEN
      stopped[1] := 1;
      disp[1][0] := Terminal.Random(NSym);
      disp[1][1] := result[1];
      disp[1][2] := Terminal.Random(NSym);
      DrawReel(1);
      FlashReel(1, result[1])
    END;
    IF (f = 38) & (stopped[2] = 0) THEN
      stopped[2] := 1;
      disp[2][0] := Terminal.Random(NSym);
      disp[2][1] := result[2];
      disp[2][2] := Terminal.Random(NSym);
      DrawReel(2);
      FlashReel(2, result[2])
    END;

    IF f < 10 THEN
      Delay(40)
    ELSIF f < 20 THEN
      Delay(60)
    ELSE
      delay := delay + 5;
      Delay(delay)
    END;

    IF (stopped[0] = 1) & (stopped[1] = 1) & (stopped[2] = 1) THEN EXIT END
  END
END SpinReels;

(* ------------------------------------------------------------------ *)

BEGIN
  reelX[0] := R0X;
  reelX[1] := R1X;
  reelX[2] := R2X;
  wins  := 0;
  spins := 0;

  Graphics.Clear;

  (* Title *)
  Graphics.Color256(226, 0);
  Graphics.Goto(12, 1);
  Out.String("S  L  O  T     M  A  C  H  I  N  E");
  Graphics.Reset;

  DrawFrame;

  (* Seed display with random symbols *)
  FOR i := 0 TO NCols - 1 DO
    FOR j := 0 TO NRows - 1 DO
      disp[i][j] := Terminal.Random(NSym)
    END
  END;

  DrawAllReels;
  DrawStatus;

  Graphics.Color256(7, 0);
  Graphics.Goto(4, 19);
  Out.String("[ENTER] or [SPACE] to spin     [Q] to quit");
  Graphics.Reset;

  (* Main loop *)
  LOOP
    key := Terminal.ReadKey();
    IF (key = 0DX) OR (key = " ") THEN
      INC(spins);
      ClearResult;
      DrawStatus;
      SpinReels;
      ShowResult;
      DrawStatus
    ELSIF (key = "q") OR (key = "Q") THEN
      EXIT
    END
  END;

  Graphics.Clear;
  Graphics.Goto(1, 1);
  Out.String("Thanks for playing!  Spins: ");
  Out.Int(spins, 0);
  Out.String("  Wins: ");
  Out.Int(wins, 0);
  Out.Ln
END Slots.
