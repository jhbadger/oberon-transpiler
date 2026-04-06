MODULE GameOfLife;

IMPORT Terminal, Graphics, Math;

(* --- Constants and Configuration --- *)
CONST GRID_WIDTH = 40;
CONST GRID_HEIGHT = 20;

(* 
 * Define colors for the simulation visualization.
 * Using ANSI colors (0-7) for simplicity in the pixel buffer.
 *)
CONST COLOR_DEAD = 0;    (* Background/Off *)
CONST COLOR_ALIVE = 1;   (* Foreground/On *)

(* --- Global State --- *)
(* grid[y][x] = TRUE if alive, FALSE if dead. *)
VAR GridState: ARRAY GRID_HEIGHT, GRID_WIDTH OF BOOLEAN;
key: CHAR;

(* 
 * Initializes the grid state.
 * The grid is initialized to all FALSE (dead).
 *)
PROCEDURE InitializeGrid;
BEGIN
  Graphics.ClearBuf();
  FOR y := 1 TO GRID_HEIGHT DO
    FOR x := 1 TO GRID_WIDTH DO
      GridState[y, x] := FALSE;
    END;
  END;
  WRITELN("Game of Life Initialized. Use the mouse to click cells to seed life.");
END;

(* 
 * Counts the number of living neighbors for a cell at (y, x).
 * Boundary checks are necessary.
 *)
PROCEDURE CountNeighbors(y, x: INTEGER; VAR count: INTEGER);
VAR i, nx, ny, y_n, x_n: INTEGER;
BEGIN
  count := 0; 
  (* Iterate over the 3x3 neighborhood centered at (y, x) *)
  FOR y_n := -1 TO 1 DO
    FOR x_n := -1 TO 1 DO
      (* Skip the center cell itself *)
      IF y_n = 0 & x_n = 0 THEN CONTINUE; END;
      ny := y + y_n;
      nx := x + x_n;
      
      (* Check boundaries *)
      IF ny >= 1 & ny <= GRID_HEIGHT & nx >= 1 & nx <= GRID_WIDTH THEN
        IF GridState[ny, nx] = TRUE THEN
          count := count + 1;
        END;
      END;
    END;
  END;
END;

(* 
 * Calculates the next state of the entire grid based on Conway's rules.
 * A temporary grid is used to ensure all updates are synchronous.
 *)
PROCEDURE CalculateNextState(VAR NextState: ARRAY OF BOOLEAN);
VAR y, x, neighbors: INTEGER;
BEGIN  
  FOR y := 1 TO GRID_HEIGHT DO
    FOR x := 1 TO GRID_WIDTH DO
      (* 1. Count neighbors *)
      CountNeighbors(y, x, neighbors);
      
      (* 2. Apply Conway's rules *)
      IF GridState[y, x] = TRUE THEN
        (* Live cell *)
        IF neighbors = 2 OR neighbors = 3 THEN
          NextState[y, x] := TRUE; (* Lives (2 or 3 neighbors) *)
        ELSE
          NextState[y, x] := FALSE; (* Dies (<2 or >3 neighbors) *)
        END;
      ELSE
        (* Dead cell *)
        IF neighbors = 3 THEN
          NextState[y, x] := TRUE; (* Becomes alive (exactly 3 neighbors) *)
        ELSE
          NextState[y, x] := FALSE; (* Stays dead *)
        END;
      END;
    END;
  END;
END;

(* 
 * Updates the global grid state with the new calculated state.
*)
PROCEDURE UpdateGrid(VAR NextState: ARRAY OF BOOLEAN);
BEGIN
  GridState := NextState;
END;


(* 
 * Draws the current state of the grid using the Graphics module.
*)
PROCEDURE DrawGrid();
BEGIN
  Graphics.ClearBuf();
  FOR y := 1 TO GRID_HEIGHT DO
    FOR x := 1 TO GRID_WIDTH DO
      IF GridState[y, x] = TRUE THEN
        Graphics.Plot(x, y, COLOR_ALIVE);
      ELSE
        Graphics.Plot(x, y, COLOR_DEAD);
      END;
    END;
  END;
  Graphics.Flush();
END;

(* 
 * Handles initial seeding via mouse input.
*)
PROCEDURE SeedFromMouse;
VAR x, y: INTEGER;
VAR running_seeding: BOOLEAN;
BEGIN
  WRITELN("--- Seeding Mode ---");
  WRITELN("Click anywhere in the terminal window (mouse required).");
  WRITELN("Left click places a cell. ESC or Enter to finish seeding.");

  running_seeding := TRUE;
  
  WHILE running_seeding DO
    key := Terminal.ReadKey();

    IF key = 03X THEN (* Left Arrow Key, used here as a simple signal key *)
      (* Do nothing, just acknowledge the key read *)
    ELSIF key = 05X THEN (* Mouse Event *)
      x := Terminal.MouseX();
      y := Terminal.MouseY();
      
      (* Check if the click coordinates are within the defined grid area *)
      IF x >= 1 & x <= GRID_WIDTH & y >= 1 & y <= GRID_HEIGHT THEN
        IF GridState[y, x] = FALSE THEN
          GridState[y, x] := TRUE; (* Seed a new life *)
          WRITELN("Cell lit at:", x, ",", y);
        ELSE
          WRITELN("Cell at (", x, ",", y, ") is already alive.");
        END;
        DrawGrid(); (* Update visualization immediately *)
      END;
    ELSE
      (* If the key is Enter or some other non-mouse key, stop seeding *)
      running_seeding := FALSE;
    END;
  END;
END;


(* 
 * Main simulation loop logic.
*)
PROCEDURE RunSimulation;
VAR NextState: ARRAY GRID_HEIGHT, GRID_WIDTH OF BOOLEAN;
running, all_dead: BOOLEAN;
turn: INTEGER;
BEGIN 
  running := TRUE;
  all_dead := TRUE;
  turn := 1;
  WRITELN("--- Simulation Running ---");
  WRITELN("Use [S] to step (single turn).");
  WRITELN("Use [R] to run automatically (Ctrl+C to stop).");
  WRITELN("Use [Q] to quit.");

  WHILE running DO
    DrawGrid();
    
    (* Wait for user input *)
    key := Terminal.ReadKey();
    
    IF key = 'q' THEN
      WRITELN("Simulation ended by user.");
      running := FALSE;
      
    ELSIF key = 's' THEN
      (* Single Step: Execute turn, update state, and repeat *)
      CalculateNextState(NextState);
      UpdateGrid(NextState);
      WRITELN("Turn", turn, " completed (Single Step).");
      turn := turn + 1;
      DrawGrid();
      
    ELSIF key = 'r' THEN
      (* Run Mode: Use a structured, finite loop instead of 'WHILE TRUE' *)
      all_dead := TRUE; (* Reset detection for the run mode turn *)
      
      WHILE running DO
        CalculateNextState(NextState);
        UpdateGrid(NextState);
        
        (* 1. Check for collapse *)
        all_dead := TRUE;
        FOR y := 1 TO GRID_HEIGHT DO
          FOR x := 1 TO GRID_WIDTH DO
            IF GridState[y, x] = TRUE THEN
              all_dead := FALSE;
            END;
          END;
        END;
        
        IF all_dead THEN
          WRITELN("Simulation detected collapse (all cells dead). Halting.");
          running := FALSE; (* Exit the outer WHILE loop by setting the flag *)
          EXIT; (* Exit the inner 'Run Mode' WHILE loop *)
        END;

        DrawGrid();
        turn := turn + 1;
        
        (* 2. Wait for keypress to continue the run mode *)
        key := Terminal.ReadKey();
        IF key = 'q' THEN
          WRITELN("Simulation stopped by user.");
          running := FALSE; (* Exit the outer WHILE loop by setting the flag *)
          EXIT; (* Exit the inner 'Run Mode' WHILE loop *)
        END;        
      END; (* End of Run Mode WHILE loop *)
   END; (* End of main WHILE loop *)
 END;
 
PROCEDURE Main;
BEGIN
  (* Setup Terminal & Graphics Environment *)
  Terminal.MouseOn(); 
  Graphics.Clear();
  
  InitializeGrid();
  
  (* PHASE 1: Seeding *)
  SeedFromMouse();
  
  (* PHASE 2: Simulation *)
  RunSimulation();
  
  (* Cleanup *)
  Terminal.MouseOff();
  Graphics.Reset();
END;

END GameOfLife.
