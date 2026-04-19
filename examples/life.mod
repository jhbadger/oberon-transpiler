MODULE GameOfLife;

IMPORT Out, Terminal, Graphics;

CONST
  GRID_WIDTH  = 200;
  GRID_HEIGHT = 90;
  COLOR_DEAD  = 0;
  COLOR_ALIVE = 2;

TYPE
  Grid = ARRAY GRID_HEIGHT, GRID_WIDTH OF BOOLEAN;

VAR
  GridState: Grid;
  key: CHAR;
  goSeed: BOOLEAN;

PROCEDURE InitializeGrid;
VAR x, y: INTEGER;
BEGIN
  FOR y := 0 TO GRID_HEIGHT - 1 DO
    FOR x := 0 TO GRID_WIDTH - 1 DO
      GridState[y, x] := FALSE;
    END;
  END;
END InitializeGrid;

PROCEDURE CountNeighbors(y, x: INTEGER): INTEGER;
VAR nx, ny, y_n, x_n, count: INTEGER;
BEGIN
  count := 0;
  FOR y_n := -1 TO 1 DO
    FOR x_n := -1 TO 1 DO
      IF ~( (y_n = 0) & (x_n = 0) ) THEN
        ny := y + y_n;
        nx := x + x_n;
        IF (ny >= 0) & (ny < GRID_HEIGHT) & (nx >= 0) & (nx < GRID_WIDTH) THEN
          IF GridState[ny, nx] THEN
            INC(count);
          END;
        END;
      END;
    END;
  END;
  RETURN count
END CountNeighbors;

PROCEDURE CalculateNextState(VAR NextState: Grid);
VAR y, x, neighbors: INTEGER;
BEGIN
  FOR y := 0 TO GRID_HEIGHT - 1 DO
    FOR x := 0 TO GRID_WIDTH - 1 DO
      neighbors := CountNeighbors(y, x);
      IF GridState[y, x] THEN
        NextState[y, x] := (neighbors = 2) OR (neighbors = 3);
      ELSE
        NextState[y, x] := (neighbors = 3);
      END;
    END;
  END;
END CalculateNextState;

PROCEDURE DrawGrid;
VAR x, y: INTEGER;
BEGIN
  Graphics.ClearBuf();
  FOR y := 0 TO GRID_HEIGHT - 1 DO
    FOR x := 0 TO GRID_WIDTH - 1 DO
      IF GridState[y, x] THEN
        Graphics.Plot(x, y, COLOR_ALIVE);
      END;
    END;
  END;
  Graphics.Flush();
END DrawGrid;

PROCEDURE SeedFromMouse;
VAR x, y: INTEGER; running_seeding: BOOLEAN;
BEGIN
  running_seeding := TRUE;
  DrawGrid();
  Graphics.Goto(1, 47);
  Out.String("SEED MODE  Click to place cells   Enter or ESC to run");
  WHILE running_seeding DO
    key := Terminal.ReadKey();
    IF key = 04X THEN
      x := Terminal.MouseX() - 1;
      y := (Terminal.MouseY() - 1) * 2;
      IF (x >= 0) & (x < GRID_WIDTH) & (y >= 0) & (y < GRID_HEIGHT) THEN
        GridState[y, x] := TRUE;
        IF y + 1 < GRID_HEIGHT THEN GridState[y + 1, x] := TRUE; END;
        DrawGrid();
        Graphics.Goto(1, 47);
        Out.String("SEED MODE  Click to place cells   Enter or ESC to run");
      END;
    ELSIF (key = 0DX) OR (key = 1BX) THEN
      running_seeding := FALSE;
    END;
  END;
END SeedFromMouse;

PROCEDURE RunSimulation;
VAR
  NextState: Grid;
  running: BOOLEAN;
  turn: INTEGER;
BEGIN
  running := TRUE;
  turn := 1;
  WHILE running DO
    DrawGrid();
    Graphics.Goto(1, 47);
    Out.String("RUN MODE  S=step  E=seed  Q=quit  Turn: ");
    Out.Int(turn);
    key := Terminal.ReadKey();
    IF (key = "q") OR (key = "Q") THEN
      running := FALSE; goSeed := FALSE;
    ELSIF (key = "e") OR (key = "E") THEN
      running := FALSE; goSeed := TRUE;
    ELSIF (key = "s") OR (key = "S") THEN
      CalculateNextState(NextState);
      GridState := NextState;
      INC(turn);
    END;
  END;
END RunSimulation;

BEGIN
  Terminal.MouseOn();
  Graphics.Clear();
  InitializeGrid();
  goSeed := TRUE;
  WHILE goSeed DO
    SeedFromMouse();
    RunSimulation();
  END;
  Terminal.MouseOff();
  Graphics.Reset();
END GameOfLife.

