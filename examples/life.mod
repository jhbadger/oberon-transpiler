MODULE GameOfLife;

IMPORT Out, Terminal, Graphics;

CONST 
  GRID_WIDTH = 40;
  GRID_HEIGHT = 20;
  COLOR_DEAD = 0;    
  COLOR_ALIVE = 1;   

TYPE
  Grid = ARRAY GRID_HEIGHT, GRID_WIDTH OF BOOLEAN;

VAR 
  GridState: Grid;
  key: CHAR;

PROCEDURE InitializeGrid;
VAR x, y: INTEGER;
BEGIN
  Graphics.ClearBuf();
  FOR y := 0 TO GRID_HEIGHT - 1 DO
    FOR x := 0 TO GRID_WIDTH - 1 DO
      GridState[y, x] := FALSE;
    END;
  END;
  Out.String("Game of Life Initialized."); Out.Ln;
END InitializeGrid;

PROCEDURE CountNeighbors(y, x: INTEGER): INTEGER;
VAR i, nx, ny, y_n, x_n, count: INTEGER;
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
      ELSE
        Graphics.Plot(x, y, COLOR_DEAD);
      END;
    END;
  END;
  Graphics.Flush();
END DrawGrid;

PROCEDURE SeedFromMouse;
VAR x, y: INTEGER; running_seeding: BOOLEAN;
BEGIN
  Out.String("--- Seeding Mode ---"); Out.Ln;
  running_seeding := TRUE;
  WHILE running_seeding DO
    key := Terminal.ReadKey();
    IF key = 05X THEN (* Mouse Event *)
      x := Terminal.MouseX();
      y := Terminal.MouseY();
      IF (x >= 0) & (x < GRID_WIDTH) & (y >= 0) & (y < GRID_HEIGHT) THEN
        GridState[y, x] := TRUE;
        DrawGrid();
      END;
    ELSIF (key = 0DX) OR (key = 1BX) THEN (* Enter or ESC *)
      running_seeding := FALSE;
    END;
  END;
END SeedFromMouse;

PROCEDURE RunSimulation;
VAR 
  NextState: Grid;
  running, all_dead: BOOLEAN;
  y, x, turn: INTEGER;
BEGIN 
  running := TRUE;
  turn := 1;
  WHILE running DO
    DrawGrid();
    key := Terminal.ReadKey();
    
    IF (key = "q") OR (key = "Q") THEN
      running := FALSE;
    ELSIF (key = "s") OR (key = "S") THEN
      CalculateNextState(NextState);
      GridState := NextState;
      INC(turn);
    END;
  END;
END RunSimulation;

BEGIN (* Main Body of Module *)
  Terminal.MouseOn(); 
  Graphics.Clear();
  InitializeGrid();
  SeedFromMouse();
  RunSimulation();
  Terminal.MouseOff();
  Graphics.Reset();
END GameOfLife.