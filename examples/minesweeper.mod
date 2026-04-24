MODULE Minesweeper;
(*
 * Minesweeper — coloured grid, mouse support, mine counter.
 *
 * Layout (terminal):
 *   Header   : row 1  (title + mine counter)
 *   Border   : row 2  (Terminal.Box)
 *   Grid     : rows 3..Height+2, cols 2..Width*2+1  (2 chars per cell)
 *   Status   : row Height+4
 *
 * Controls: Arrows / WASD   Space=Reveal   F=Flag   Q=Quit
 *           Left-click=Reveal   Right-click=Flag
 *)

IMPORT Terminal, Random, Out;

CONST
  Width      = 10;
  Height     = 10;
  MinesCount = 15;

  (* Arrow keys *)
  KeyUp    = 0A0X;  KeyDown  = 0A1X;
  KeyLeft  = 0A2X;  KeyRight = 0A3X;
  KeyMouse = 0A4X;

  (* Grid origin in terminal coordinates *)
  OX = 2;   (* cells occupy cols OX .. OX + Width*2 - 1, 2 chars each *)
  OY = 3;   (* cells occupy rows OY .. OY + Height - 1                *)

TYPE
  Cell = RECORD
    isMine      : BOOLEAN;
    isRevealed  : BOOLEAN;
    isFlagged   : BOOLEAN;
    neighborMines : INTEGER;
  END;

VAR
  grid              : ARRAY Width, Height OF Cell;
  cursorX, cursorY  : INTEGER;
  gameOver, gameWon : BOOLEAN;
  ch                : CHAR;

(* grid initialisation *)

PROCEDURE InitGrid;
VAR x, y, m, nx, ny : INTEGER;
BEGIN
  FOR y := 0 TO Height - 1 DO
    FOR x := 0 TO Width - 1 DO
      grid[x, y].isMine      := FALSE;
      grid[x, y].isRevealed  := FALSE;
      grid[x, y].isFlagged   := FALSE;
      grid[x, y].neighborMines := 0;
    END;
  END;

  m := 0;
  WHILE m < MinesCount DO
    x := Random.Int(Width);
    y := Random.Int(Height);
    IF ~grid[x, y].isMine THEN
      grid[x, y].isMine := TRUE;
      INC(m);
    END;
  END;

  FOR y := 0 TO Height - 1 DO
    FOR x := 0 TO Width - 1 DO
      IF ~grid[x, y].isMine THEN
        FOR ny := y - 1 TO y + 1 DO
          FOR nx := x - 1 TO x + 1 DO
            IF (nx >= 0) & (nx < Width) & (ny >= 0) & (ny < Height) THEN
              IF grid[nx, ny].isMine THEN INC(grid[x, y].neighborMines) END;
            END;
          END;
        END;
      END;
    END;
  END;
END InitGrid;

(* Flood Fill reveal *)

PROCEDURE Reveal(x, y : INTEGER);
VAR nx, ny : INTEGER;
BEGIN
  IF (x < 0) OR (x >= Width) OR (y < 0) OR (y >= Height) THEN RETURN END;
  IF grid[x, y].isRevealed OR grid[x, y].isFlagged THEN RETURN END;
  grid[x, y].isRevealed := TRUE;
  IF (grid[x, y].neighborMines = 0) & (~grid[x, y].isMine) THEN
    FOR ny := y - 1 TO y + 1 DO
      FOR nx := x - 1 TO x + 1 DO
        Reveal(nx, ny);
      END;
    END;
  END;
END Reveal;

(* Draw one cell *)
PROCEDURE DrawCell(x, y : INTEGER; cursor : BOOLEAN);
VAR n : INTEGER;
BEGIN
  Terminal.Goto(OX + x * 2, OY + y);

  IF grid[x, y].isRevealed THEN
    IF grid[x, y].isMine THEN
      (* Exploded mine: white-on-red at cursor, red elsewhere *)
      IF cursor THEN Terminal.Color(7, 1) ELSE Terminal.Color(1, 0) END;
      Out.String("* ");
    ELSIF grid[x, y].neighborMines > 0 THEN
      n := grid[x, y].neighborMines;
      IF cursor THEN
        Terminal.Color(0, 6)     (* black on cyan for cursor *)
      ELSE
        (* Classic minesweeper number colours *)
        IF    n = 1 THEN Terminal.Color(4, 0)   (* blue    *)
        ELSIF n = 2 THEN Terminal.Color(2, 0)   (* green   *)
        ELSIF n = 3 THEN Terminal.Color(1, 0)   (* red     *)
        ELSIF n = 4 THEN Terminal.Color(5, 0)   (* magenta *)
        ELSIF n = 5 THEN Terminal.Color(3, 0)   (* yellow  *)
        ELSIF n = 6 THEN Terminal.Color(6, 0)   (* cyan    *)
        ELSE             Terminal.Color(7, 0)   (* white   *)
        END;
      END;
      Out.Int(n, 0);  Out.Char(' ');
    ELSE
      (* Empty revealed cell *)
      IF cursor THEN Terminal.Color(0, 6) ELSE Terminal.Color(0, 0) END;
      Out.String(". ");
    END;
  ELSIF grid[x, y].isFlagged THEN
    IF cursor THEN Terminal.Color(1, 3) ELSE Terminal.Color(1, 0) END;
    Out.String("F ");
  ELSE
    (* Unrevealed *)
    IF cursor THEN Terminal.Color(0, 3) ELSE Terminal.Color(7, 0) END;
    Out.String("# ");
  END;
  Terminal.Reset;
END DrawCell;

(* Draw full board *)

PROCEDURE DrawBoard;
VAR x, y, flags : INTEGER;
BEGIN
  (* Title *)
  Terminal.Goto(1, 1);
  Terminal.Color(3, 0);
  Out.String(" *** MINESWEEPER ***");
  Terminal.Reset;

  (* Remaining-mine counter *)
  flags := 0;
  FOR y := 0 TO Height - 1 DO
    FOR x := 0 TO Width - 1 DO
      IF grid[x, y].isFlagged THEN INC(flags) END;
    END;
  END;
  Terminal.Goto(22, 1);
  Terminal.Color(1, 0);
  Out.String("Mines:");  Out.Int(MinesCount - flags, 3);
  Terminal.Reset;

  (* Border box *)
  Terminal.Color(6, 0);
  Terminal.Box(1, 2, Width * 2 + 2, Height + 2);
  Terminal.Reset;

  (* Cells *)
  FOR y := 0 TO Height - 1 DO
    FOR x := 0 TO Width - 1 DO
      DrawCell(x, y, (x = cursorX) & (y = cursorY));
    END;
  END;

  (* Controls hint *)
  Terminal.Goto(1, OY + Height + 1);
  Terminal.Color(7, 0);
  Out.String("Arrows/Move  Space/Reveal  F/Flag  Q/Quit  Click=Reveal  RClick=Flag");
  Terminal.Reset;
END DrawBoard;

(* Win Check *)

PROCEDURE CheckWin;
VAR x, y : INTEGER;
BEGIN
  gameWon := TRUE;
  FOR y := 0 TO Height - 1 DO
    FOR x := 0 TO Width - 1 DO
      IF ~grid[x, y].isMine & ~grid[x, y].isRevealed THEN gameWon := FALSE END;
    END;
  END;
END CheckWin;

(* Reveal all mines at game end *)

PROCEDURE RevealMines;
VAR x, y : INTEGER;
BEGIN
  FOR y := 0 TO Height - 1 DO
    FOR x := 0 TO Width - 1 DO
      IF grid[x, y].isMine THEN grid[x, y].isRevealed := TRUE END;
    END;
  END;
END RevealMines;

(* Main game loop *)

PROCEDURE Play;
VAR gx, gy, btn : INTEGER;
BEGIN
  gameOver := FALSE;  gameWon := FALSE;
  cursorX  := Width DIV 2;  cursorY := Height DIV 2;

  Terminal.Clear;
  Terminal.HideCursor;
  Terminal.MouseOn();
  InitGrid;

  REPEAT
    DrawBoard;
    ch := Terminal.ReadKey();
    CASE ch OF
      KeyUp    : IF cursorY > 0          THEN DEC(cursorY) END
    | KeyDown  : IF cursorY < Height - 1 THEN INC(cursorY) END
    | KeyLeft  : IF cursorX > 0          THEN DEC(cursorX) END
    | KeyRight : IF cursorX < Width - 1  THEN INC(cursorX) END
    | 'w'      : IF cursorY > 0          THEN DEC(cursorY) END
    | 's'      : IF cursorY < Height - 1 THEN INC(cursorY) END
    | 'a'      : IF cursorX > 0          THEN DEC(cursorX) END
    | 'd'      : IF cursorX < Width - 1  THEN INC(cursorX) END
    | 'f', 'F' : IF ~grid[cursorX, cursorY].isRevealed THEN
                   grid[cursorX, cursorY].isFlagged := ~grid[cursorX, cursorY].isFlagged;
                 END
    | ' '      : IF ~grid[cursorX, cursorY].isFlagged THEN
                   IF grid[cursorX, cursorY].isMine THEN
                     gameOver := TRUE;
                   ELSE
                     Reveal(cursorX, cursorY);
                     CheckWin;
                   END;
                 END
    | KeyMouse :
                 gx  := (Terminal.MouseX() - OX) DIV 2;
                 gy  := Terminal.MouseY() - OY;
                 btn := Terminal.MouseBtn();
                 IF (gx >= 0) & (gx < Width) & (gy >= 0) & (gy < Height) THEN
                   cursorX := gx;  cursorY := gy;
                   IF btn = 0 THEN          (* left-click: reveal *)
                     IF ~grid[gx, gy].isFlagged THEN
                       IF grid[gx, gy].isMine THEN
                         gameOver := TRUE;
                       ELSE
                         Reveal(gx, gy);
                         CheckWin;
                       END;
                     END;
                   ELSIF btn = 2 THEN       (* right-click: flag *)
                     IF ~grid[gx, gy].isRevealed THEN
                       grid[gx, gy].isFlagged := ~grid[gx, gy].isFlagged;
                     END;
                   END;
                 END
    | 'q', 'Q' : gameOver := TRUE
    ELSE
    END;
  UNTIL gameOver OR gameWon;

  IF gameOver THEN RevealMines END;
  DrawBoard;

  Terminal.Goto(1, OY + Height + 2);
  IF gameWon THEN
    Terminal.Color(2, 0);
    Out.String("*** CONGRATULATIONS! YOU WON! ***");
  ELSE
    Terminal.Color(1, 0);
    Out.String("*** GAME OVER - BOOM! ***");
  END;
  Terminal.Reset;
  Out.Ln;

  Terminal.MouseOff();
END Play;

BEGIN
  Play;
END Minesweeper.

