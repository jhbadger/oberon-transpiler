MODULE Wireworld;

IMPORT Out, Terminal;

CONST
GRID_WIDTH  = 200;
GRID_HEIGHT = 90;
EMPTY  = 0;
CONDUCTOR = 3;
EHEAD = 4;
ETAIL = 1;

TYPE
Grid = ARRAY GRID_HEIGHT, GRID_WIDTH OF INTEGER;

VAR
GridState: Grid;
key: CHAR;
goSeed: BOOLEAN;

PROCEDURE InitializeGrid;
VAR x, y: INTEGER;
BEGIN
    FOR y := 0 TO GRID_HEIGHT - 1 DO
        FOR x := 0 TO GRID_WIDTH - 1 DO
            GridState[y, x] := EMPTY;
        END;
    END;
END InitializeGrid;

PROCEDURE CountEHeadNeighbors(y, x: INTEGER): INTEGER;
VAR nx, ny, y_n, x_n, count: INTEGER;
BEGIN
    count := 0;
    FOR y_n := -1 TO 1 DO
        FOR x_n := -1 TO 1 DO
            IF ~( (y_n = 0) & (x_n = 0) ) THEN
                ny := y + y_n;
                nx := x + x_n;
                IF (ny >= 0) & (ny < GRID_HEIGHT) & (nx >= 0) & (nx < GRID_WIDTH) THEN
                    IF GridState[ny, nx] = EHEAD THEN
                        INC(count);
                    END;
                END;
            END;
        END;
    END;
    RETURN count
END CountEHeadNeighbors;

PROCEDURE CalculateNextState(VAR NextState: Grid);
VAR y, x, neighbors: INTEGER;
BEGIN
    FOR y := 0 TO GRID_HEIGHT - 1 DO
        FOR x := 0 TO GRID_WIDTH - 1 DO
            IF GridState[y, x] = EHEAD THEN
                NextState[y, x] := ETAIL
            ELSIF GridState[y, x] = ETAIL THEN
                NextState[y, x] := CONDUCTOR
            ELSIF GridState[y, x] = CONDUCTOR THEN
                neighbors := CountEHeadNeighbors(y, x);
                IF (neighbors = 1) OR (neighbors = 2) THEN
                    NextState[y, x] := EHEAD
                ELSE
                    NextState[y, x] := CONDUCTOR
                END
            ELSE
                NextState[y, x] := EMPTY
            END
        END
    END
END CalculateNextState;
                    
PROCEDURE DrawGrid;
VAR x, y: INTEGER;
BEGIN
    Terminal.ClearBuf();
    FOR y := 0 TO GRID_HEIGHT - 1 DO
        FOR x := 0 TO GRID_WIDTH - 1 DO
            IF GridState[y, x] # EMPTY THEN
                Terminal.Plot(x, y, GridState[y, x]);
            END;
        END;
    END;
    Terminal.Flush();
END DrawGrid;

PROCEDURE SeedFromMouse;
VAR x, y, state: INTEGER; running_seeding: BOOLEAN;
BEGIN
    state := CONDUCTOR;
    running_seeding := TRUE;
    DrawGrid();
    Terminal.Goto(1, 47);
    Out.String("SEED MODE  C=conductor  H=e-head  T=e-tail  Click to place  Enter/ESC to run");
    WHILE running_seeding DO
        key := Terminal.ReadKey();
        IF key = 0A4X THEN
            IF Terminal.MouseBtn() = 0 THEN
                x := Terminal.MouseX() - 1;
                y := (Terminal.MouseY() - 1) * 2;
                IF (x >= 0) & (x < GRID_WIDTH) & (y >= 0) & (y < GRID_HEIGHT) THEN
                    GridState[y, x] := state;
                    IF y + 1 < GRID_HEIGHT THEN GridState[y + 1, x] := state; END;
                    DrawGrid();
                    Terminal.Goto(1, 47);
                    Out.String("SEED MODE  C=conductor  H=e-head  T=e-tail  Click to place  Enter/ESC to run");
                END;
            END;
        ELSIF (key = "C") OR (key = "c") THEN state := CONDUCTOR
    ELSIF (key = "H") OR (key = "h") THEN state := EHEAD
ELSIF (key = "T") OR (key = "t") THEN state := ETAIL
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
        Terminal.Goto(1, 47);
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
    Terminal.Clear();
    InitializeGrid();
    goSeed := TRUE;
    WHILE goSeed DO
        SeedFromMouse();
        RunSimulation();
    END;
    Terminal.MouseOff();
    Terminal.Reset();
END Wireworld.

