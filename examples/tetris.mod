MODULE Tetris;
(*
 * Tetris — standard 7 tetrominoes, SRS-style wall kicks.
 *
 * Layout (80×24 terminal):
 *   Board  : 10×20 cells, 2 chars wide each → 20 chars + border
 *   Border : BX=1, BT=1
 *   Panel  : score/level/next piece at x=25
 *
 * Controls: ← → rotate=↑  soft-drop=↓  hard-drop=Space  Esc=quit
 *)

IMPORT Terminal, Graphics, Out;

CONST
  BW  = 10;    (* board width  in cells *)
  BH  = 20;    (* board height in cells *)
  CW  = 2;     (* terminal chars per cell *)
  BX  = 1;     (* board border left-x    *)
  BT  = 1;     (* board border top-y     *)
  NX  = 26;    (* info panel left-x      *)
  NY  = 2;     (* info panel top-y       *)

  KUp    = 01X;  KDown  = 02X;
  KLeft  = 03X;  KRight = 04X;
  KEsc   = 1BX;

VAR
  board    : ARRAY BH, BW OF INTEGER;   (* 0=empty, 1..7=color *)

  (* Piece cell offsets: pdx/pdy[ p*16 + r*4 + c ] *)
  pdx, pdy : ARRAY 112 OF INTEGER;

  px, py   : INTEGER;   (* piece origin on board *)
  ptype    : INTEGER;   (* 0..6  *)
  prot     : INTEGER;   (* 0..3  *)
  nextType : INTEGER;

  score    : INTEGER;
  level    : INTEGER;
  lines    : INTEGER;
  alive    : BOOLEAN;
  quitting : BOOLEAN;

  dropTime : LONGINT;
  dropInt  : LONGINT;
  now      : LONGINT;
  key      : CHAR;
  i, r, c  : INTEGER;


(* ── Piece data ────────────────────────────────────────────────── *)

PROCEDURE SetCell(p, rt, cl, x, y : INTEGER);
BEGIN
  pdx[p*16 + rt*4 + cl] := x;
  pdy[p*16 + rt*4 + cl] := y
END SetCell;

PROCEDURE InitPieces;
BEGIN
  (* I – piece 0 *)
  SetCell(0,0,0, 0,1); SetCell(0,0,1, 1,1); SetCell(0,0,2, 2,1); SetCell(0,0,3, 3,1);
  SetCell(0,1,0, 2,0); SetCell(0,1,1, 2,1); SetCell(0,1,2, 2,2); SetCell(0,1,3, 2,3);
  SetCell(0,2,0, 0,2); SetCell(0,2,1, 1,2); SetCell(0,2,2, 2,2); SetCell(0,2,3, 3,2);
  SetCell(0,3,0, 1,0); SetCell(0,3,1, 1,1); SetCell(0,3,2, 1,2); SetCell(0,3,3, 1,3);
  (* O – piece 1 *)
  SetCell(1,0,0, 1,0); SetCell(1,0,1, 2,0); SetCell(1,0,2, 1,1); SetCell(1,0,3, 2,1);
  SetCell(1,1,0, 1,0); SetCell(1,1,1, 2,0); SetCell(1,1,2, 1,1); SetCell(1,1,3, 2,1);
  SetCell(1,2,0, 1,0); SetCell(1,2,1, 2,0); SetCell(1,2,2, 1,1); SetCell(1,2,3, 2,1);
  SetCell(1,3,0, 1,0); SetCell(1,3,1, 2,0); SetCell(1,3,2, 1,1); SetCell(1,3,3, 2,1);
  (* T – piece 2 *)
  SetCell(2,0,0, 1,0); SetCell(2,0,1, 0,1); SetCell(2,0,2, 1,1); SetCell(2,0,3, 2,1);
  SetCell(2,1,0, 1,0); SetCell(2,1,1, 1,1); SetCell(2,1,2, 2,1); SetCell(2,1,3, 1,2);
  SetCell(2,2,0, 0,1); SetCell(2,2,1, 1,1); SetCell(2,2,2, 2,1); SetCell(2,2,3, 1,2);
  SetCell(2,3,0, 1,0); SetCell(2,3,1, 0,1); SetCell(2,3,2, 1,1); SetCell(2,3,3, 1,2);
  (* S – piece 3 *)
  SetCell(3,0,0, 1,0); SetCell(3,0,1, 2,0); SetCell(3,0,2, 0,1); SetCell(3,0,3, 1,1);
  SetCell(3,1,0, 0,0); SetCell(3,1,1, 0,1); SetCell(3,1,2, 1,1); SetCell(3,1,3, 1,2);
  SetCell(3,2,0, 1,0); SetCell(3,2,1, 2,0); SetCell(3,2,2, 0,1); SetCell(3,2,3, 1,1);
  SetCell(3,3,0, 0,0); SetCell(3,3,1, 0,1); SetCell(3,3,2, 1,1); SetCell(3,3,3, 1,2);
  (* Z – piece 4 *)
  SetCell(4,0,0, 0,0); SetCell(4,0,1, 1,0); SetCell(4,0,2, 1,1); SetCell(4,0,3, 2,1);
  SetCell(4,1,0, 1,0); SetCell(4,1,1, 0,1); SetCell(4,1,2, 1,1); SetCell(4,1,3, 0,2);
  SetCell(4,2,0, 0,0); SetCell(4,2,1, 1,0); SetCell(4,2,2, 1,1); SetCell(4,2,3, 2,1);
  SetCell(4,3,0, 1,0); SetCell(4,3,1, 0,1); SetCell(4,3,2, 1,1); SetCell(4,3,3, 0,2);
  (* J – piece 5 *)
  SetCell(5,0,0, 0,0); SetCell(5,0,1, 0,1); SetCell(5,0,2, 1,1); SetCell(5,0,3, 2,1);
  SetCell(5,1,0, 0,0); SetCell(5,1,1, 1,0); SetCell(5,1,2, 0,1); SetCell(5,1,3, 0,2);
  SetCell(5,2,0, 0,1); SetCell(5,2,1, 1,1); SetCell(5,2,2, 2,1); SetCell(5,2,3, 2,2);
  SetCell(5,3,0, 1,0); SetCell(5,3,1, 1,1); SetCell(5,3,2, 0,2); SetCell(5,3,3, 1,2);
  (* L – piece 6 *)
  SetCell(6,0,0, 2,0); SetCell(6,0,1, 0,1); SetCell(6,0,2, 1,1); SetCell(6,0,3, 2,1);
  SetCell(6,1,0, 0,0); SetCell(6,1,1, 0,1); SetCell(6,1,2, 0,2); SetCell(6,1,3, 1,2);
  SetCell(6,2,0, 0,1); SetCell(6,2,1, 1,1); SetCell(6,2,2, 2,1); SetCell(6,2,3, 0,2);
  SetCell(6,3,0, 0,0); SetCell(6,3,1, 1,0); SetCell(6,3,2, 1,1); SetCell(6,3,3, 1,2)
END InitPieces;


(* ── Drawing ───────────────────────────────────────────────────── *)

PROCEDURE DrawCell(bx, by, color : INTEGER);
BEGIN
  Terminal.Goto(BX + 1 + bx * CW, BT + 1 + by);
  IF color = 0 THEN
    Graphics.Reset;  Out.Char(' ');  Out.Char(' ')
  ELSE
    Graphics.Color(color, 0);
    Out.Char('[');  Out.Char(']')
  END;
  Graphics.Reset
END DrawCell;

PROCEDURE DrawBorder;
BEGIN
  Graphics.Color(7, 0);
  Graphics.Box(BX, BT, BW * CW + 2, BH + 2);
  Graphics.Reset
END DrawBorder;

PROCEDURE DrawStatus;
BEGIN
  Terminal.Goto(NX, NY);     Graphics.Color(7, 0);  Out.String("TETRIS");    Graphics.Reset;
  Terminal.Goto(NX, NY+2);   Out.String("Score:");
  Terminal.Goto(NX, NY+3);   Graphics.Color(3, 0);  Out.Int(score, 7);  Graphics.Reset;
  Terminal.Goto(NX, NY+5);   Out.String("Level:");
  Terminal.Goto(NX, NY+6);   Graphics.Color(3, 0);  Out.Int(level, 7);  Graphics.Reset;
  Terminal.Goto(NX, NY+8);   Out.String("Lines:");
  Terminal.Goto(NX, NY+9);   Graphics.Color(3, 0);  Out.Int(lines, 7);  Graphics.Reset;
  Terminal.Goto(NX, NY+11);  Out.String("Next:")
END DrawStatus;

PROCEDURE DrawNextPiece;
VAR cl, tx, ty : INTEGER;
BEGIN
  FOR ty := 0 TO 3 DO
    Terminal.Goto(NX, NY + 12 + ty);
    Out.String("        ")
  END;
  FOR cl := 0 TO 3 DO
    tx := NX + pdx[nextType * 16 + cl] * CW;
    ty := NY + 12 + pdy[nextType * 16 + cl];
    Terminal.Goto(tx, ty);
    Graphics.Color(nextType + 1, 0);
    Out.Char('[');  Out.Char(']')
  END;
  Graphics.Reset
END DrawNextPiece;


(* ── Collision ─────────────────────────────────────────────────── *)

PROCEDURE Fits(pt, pr, ox, oy : INTEGER) : BOOLEAN;
VAR cl, cx, cy : INTEGER;
BEGIN
  FOR cl := 0 TO 3 DO
    cx := ox + pdx[pt * 16 + pr * 4 + cl];
    cy := oy + pdy[pt * 16 + pr * 4 + cl];
    IF (cx < 0) OR (cx >= BW) OR (cy >= BH) THEN  RETURN FALSE  END;
    IF (cy >= 0) & (board[cy][cx] # 0)      THEN  RETURN FALSE  END
  END;
  RETURN TRUE
END Fits;


(* ── Active piece ──────────────────────────────────────────────── *)

PROCEDURE DrawPiece(show : BOOLEAN);
VAR cl, cx, cy, col : INTEGER;
BEGIN
  IF show THEN  col := ptype + 1  ELSE  col := 0  END;
  FOR cl := 0 TO 3 DO
    cx := px + pdx[ptype * 16 + prot * 4 + cl];
    cy := py + pdy[ptype * 16 + prot * 4 + cl];
    IF cy >= 0 THEN  DrawCell(cx, cy, col)  END
  END
END DrawPiece;

PROCEDURE Spawn(t : INTEGER);
BEGIN
  ptype := t;
  prot  := 0;
  px    := BW DIV 2 - 2;
  py    := 0;
  IF ~Fits(ptype, prot, px, py) THEN  alive := FALSE  END
END Spawn;


(* ── Lock and clear ────────────────────────────────────────────── *)

PROCEDURE LockAndClear;
VAR cl, cx, cy, row, col, cleared : INTEGER;
    full : BOOLEAN;
BEGIN
  (* Lock current piece into board *)
  FOR cl := 0 TO 3 DO
    cx := px + pdx[ptype * 16 + prot * 4 + cl];
    cy := py + pdy[ptype * 16 + prot * 4 + cl];
    IF cy >= 0 THEN  board[cy][cx] := ptype + 1  END
  END;

  (* Scan for full lines bottom-up *)
  cleared := 0;
  row     := BH - 1;
  WHILE row >= 0 DO
    full := TRUE;
    FOR col := 0 TO BW - 1 DO
      IF board[row][col] = 0 THEN  full := FALSE  END
    END;
    IF full THEN
      FOR r := row TO 1 BY -1 DO
        FOR c := 0 TO BW - 1 DO  board[r][c] := board[r-1][c]  END
      END;
      FOR c := 0 TO BW - 1 DO  board[0][c] := 0  END;
      cleared := cleared + 1
      (* row stays — recheck same index after shift *)
    ELSE
      row := row - 1
    END
  END;

  IF cleared > 0 THEN
    lines := lines + cleared;
    IF    cleared = 1 THEN  score := score + 100 * level
    ELSIF cleared = 2 THEN  score := score + 300 * level
    ELSIF cleared = 3 THEN  score := score + 500 * level
    ELSE                    score := score + 800 * level
    END;
    level   := lines DIV 10 + 1;
    dropInt := 800 - (level - 1) * 70;
    IF dropInt < 80 THEN  dropInt := 80  END;
    FOR r := 0 TO BH - 1 DO
      FOR c := 0 TO BW - 1 DO  DrawCell(c, r, board[r][c])  END
    END
  END;
  DrawStatus
END LockAndClear;


(* ── Moves ─────────────────────────────────────────────────────── *)

PROCEDURE MoveLeft;
BEGIN
  DrawPiece(FALSE);
  IF Fits(ptype, prot, px - 1, py) THEN  px := px - 1  END;
  DrawPiece(TRUE)
END MoveLeft;

PROCEDURE MoveRight;
BEGIN
  DrawPiece(FALSE);
  IF Fits(ptype, prot, px + 1, py) THEN  px := px + 1  END;
  DrawPiece(TRUE)
END MoveRight;

PROCEDURE Rotate;
VAR nr : INTEGER;
BEGIN
  nr := (prot + 1) MOD 4;
  DrawPiece(FALSE);
  IF    Fits(ptype, nr, px,     py) THEN  prot := nr
  ELSIF Fits(ptype, nr, px - 1, py) THEN  prot := nr;  px := px - 1
  ELSIF Fits(ptype, nr, px + 1, py) THEN  prot := nr;  px := px + 1
  ELSIF Fits(ptype, nr, px - 2, py) THEN  prot := nr;  px := px - 2
  ELSIF Fits(ptype, nr, px + 2, py) THEN  prot := nr;  px := px + 2
  END;
  DrawPiece(TRUE)
END Rotate;

PROCEDURE DropOne;
BEGIN
  IF Fits(ptype, prot, px, py + 1) THEN
    DrawPiece(FALSE);
    py := py + 1;
    DrawPiece(TRUE)
  ELSE
    LockAndClear;
    Spawn(nextType);
    nextType := Terminal.Random(7);
    DrawNextPiece;
    IF alive THEN  DrawPiece(TRUE)  END
  END
END DropOne;

PROCEDURE HardDrop;
BEGIN
  DrawPiece(FALSE);
  WHILE Fits(ptype, prot, px, py + 1) DO  py := py + 1  END;
  DrawPiece(TRUE);
  LockAndClear;
  Spawn(nextType);
  nextType := Terminal.Random(7);
  DrawNextPiece;
  IF alive THEN  DrawPiece(TRUE)  END
END HardDrop;


(* ── Init / GameOver ───────────────────────────────────────────── *)

PROCEDURE Init;
BEGIN
  FOR r := 0 TO BH - 1 DO
    FOR c := 0 TO BW - 1 DO  board[r][c] := 0  END
  END;
  score := 0;  level := 1;  lines := 0;
  dropInt := 800;
  alive   := TRUE;

  Terminal.Clear;
  DrawBorder;
  DrawStatus;

  nextType := Terminal.Random(7);
  Spawn(Terminal.Random(7));
  DrawNextPiece;
  DrawPiece(TRUE);

  dropTime := Terminal.GetTickCount() + dropInt
END Init;

PROCEDURE GameOver;
VAR cx, cy : INTEGER;
BEGIN
  cx := BX + 2;
  cy := BT + BH DIV 2;
  Terminal.Goto(cx, cy);
  Graphics.Color(1, 0);  Out.String("  ** GAME OVER **   ");
  Terminal.Goto(cx, cy + 1);
  Graphics.Color(3, 0);  Out.String("  Score: ");  Out.Int(score, 0);
  Terminal.Goto(cx, cy + 3);
  Graphics.Color(7, 0);  Out.String("  [Y] play again    ");
  Terminal.Goto(cx, cy + 4);
  Out.String("  [N] quit          ");
  Graphics.Reset;
  REPEAT  key := Terminal.ReadKey()
  UNTIL (key = 'y') OR (key = 'Y') OR (key = 'n') OR (key = 'N') OR (key = KEsc);
  quitting := (key = 'n') OR (key = 'N') OR (key = KEsc)
END GameOver;


(* ── Main ──────────────────────────────────────────────────────── *)

BEGIN
  InitPieces;
  quitting := FALSE;
  WHILE quitting = FALSE DO
    Init;

    WHILE alive DO
      IF Terminal.KeyPressed() THEN
        key := Terminal.ReadKey();
        IF    key = KLeft  THEN  MoveLeft
        ELSIF key = KRight THEN  MoveRight
        ELSIF key = KUp    THEN  Rotate
        ELSIF key = KDown  THEN
          DropOne;
          dropTime := Terminal.GetTickCount() + dropInt
        ELSIF key = ' '    THEN
          HardDrop;
          dropTime := Terminal.GetTickCount() + dropInt
        ELSIF key = KEsc   THEN
          alive := FALSE;  quitting := TRUE
        END
      END;

      now := Terminal.GetTickCount();
      IF now >= dropTime THEN
        DropOne;
        dropTime := now + dropInt
      END
    END;

    IF quitting = FALSE THEN  GameOver  END
  END;

  Terminal.Clear;
  Terminal.Goto(1, 1)
END Tetris.
