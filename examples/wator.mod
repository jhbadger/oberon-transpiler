MODULE Wator;

IMPORT Out, Terminal, Random;

CONST
  GRID_WIDTH   = 80;
  GRID_HEIGHT  = 50;
  EMPTY        = 0;
  FISH         = 1;
  SHARK        = 2;
  FISH_BREED   = 5;
  SHARK_BREED  = 12;
  SHARK_STARVE = 4;
  FISH_INIT    = 25;
  SHARK_INIT   = 4;
  COLOR_FISH   = 2;
  COLOR_SHARK  = 1;
  PLOT_LEFT    = 3;
  PLOT_RIGHT   = GRID_WIDTH - 4;   (* = 196 *)
  PLOT_TOP     = 2;
  PLOT_BOTTOM  = GRID_HEIGHT - 5;  (* = 85, x-axis drawn here *)
  MAX_HISTORY  = PLOT_RIGHT - PLOT_LEFT;  (* = 193 data columns *)

TYPE
  StateGrid    = ARRAY GRID_HEIGHT, GRID_WIDTH OF INTEGER;
  NumGrid      = ARRAY GRID_HEIGHT, GRID_WIDTH OF INTEGER;
  FlagGrid     = ARRAY GRID_HEIGHT, GRID_WIDTH OF BOOLEAN;
  NeighborList = ARRAY 4 OF INTEGER;
  HistoryArr   = ARRAY MAX_HISTORY OF INTEGER;

VAR
  state:        StateGrid;
  age:          NumGrid;
  energy:       NumGrid;
  moved:        FlagGrid;
  fishHistory:  HistoryArr;
  sharkHistory: HistoryArr;
  historyLen:   INTEGER;
  showPlot:     BOOLEAN;
  key:          CHAR;
  turn:         INTEGER;

PROCEDURE Wrap(v, max: INTEGER): INTEGER;
BEGIN
  RETURN (v + max) MOD max
END Wrap;

PROCEDURE FindNeighbors(y, x, target: INTEGER;
                         VAR nys, nxs: NeighborList;
                         VAR count: INTEGER);
VAR i, ny, nx: INTEGER;
BEGIN
  count := 0;
  FOR i := 0 TO 3 DO
    CASE i OF
      0: ny := Wrap(y - 1, GRID_HEIGHT); nx := x
    | 1: ny := Wrap(y + 1, GRID_HEIGHT); nx := x
    | 2: ny := y; nx := Wrap(x - 1, GRID_WIDTH)
    | 3: ny := y; nx := Wrap(x + 1, GRID_WIDTH)
    END;
    IF state[ny, nx] = target THEN
      nys[count] := ny;
      nxs[count] := nx;
      INC(count);
    END;
  END;
END FindNeighbors;

PROCEDURE CountCreatures(kind: INTEGER): INTEGER;
VAR y, x, count: INTEGER;
BEGIN
  count := 0;
  FOR y := 0 TO GRID_HEIGHT - 1 DO
    FOR x := 0 TO GRID_WIDTH - 1 DO
      IF state[y, x] = kind THEN INC(count); END;
    END;
  END;
  RETURN count
END CountCreatures;

PROCEDURE RecordHistory;
VAR i, fish, sharks: INTEGER;
BEGIN
  fish   := CountCreatures(FISH);
  sharks := CountCreatures(SHARK);
  IF historyLen < MAX_HISTORY THEN
    fishHistory[historyLen]  := fish;
    sharkHistory[historyLen] := sharks;
    INC(historyLen);
  ELSE
    FOR i := 0 TO MAX_HISTORY - 2 DO
      fishHistory[i]  := fishHistory[i + 1];
      sharkHistory[i] := sharkHistory[i + 1];
    END;
    fishHistory[MAX_HISTORY - 1]  := fish;
    sharkHistory[MAX_HISTORY - 1] := sharks;
  END;
END RecordHistory;

PROCEDURE InitGrid;
VAR y, x, r: INTEGER;
BEGIN
  FOR y := 0 TO GRID_HEIGHT - 1 DO
    FOR x := 0 TO GRID_WIDTH - 1 DO
      r := Random.Int(100);
      IF r < FISH_INIT THEN
        state[y, x] := FISH;
        age[y, x] := Random.Int(FISH_BREED);
        energy[y, x] := 0;
      ELSIF r < FISH_INIT + SHARK_INIT THEN
        state[y, x] := SHARK;
        age[y, x] := Random.Int(SHARK_BREED);
        energy[y, x] := 1 + Random.Int(SHARK_STARVE);
      ELSE
        state[y, x] := EMPTY;
        age[y, x] := 0;
        energy[y, x] := 0;
      END;
      moved[y, x] := FALSE;
    END;
  END;
  turn := 0;
  historyLen := 0;
  RecordHistory();
END InitGrid;

PROCEDURE DrawGrid;
VAR x, y: INTEGER;
BEGIN
  Terminal.ClearBuf();
  FOR y := 0 TO GRID_HEIGHT - 1 DO
    FOR x := 0 TO GRID_WIDTH - 1 DO
      IF state[y, x] = FISH THEN
        Terminal.Plot(x, y, COLOR_FISH);
      ELSIF state[y, x] = SHARK THEN
        Terminal.Plot(x, y, COLOR_SHARK);
      END;
    END;
  END;
  Terminal.Flush();
END DrawGrid;

PROCEDURE DrawPlot;
VAR
  i, x, prevX, maxPop, fishY, sharkY, prevFishY, prevSharkY, dataH, plotBase: INTEGER;
BEGIN
  Terminal.ClearBuf();
  FOR i := PLOT_LEFT TO PLOT_RIGHT DO
    Terminal.Plot(i, PLOT_BOTTOM, 7);
  END;
  FOR i := PLOT_TOP TO PLOT_BOTTOM DO
    Terminal.Plot(PLOT_LEFT - 1, i, 7);
  END;
  IF historyLen < 2 THEN
    Terminal.Flush();
    RETURN;
  END;
  maxPop := 1;
  FOR i := 0 TO historyLen - 1 DO
    IF fishHistory[i]  > maxPop THEN maxPop := fishHistory[i];  END;
    IF sharkHistory[i] > maxPop THEN maxPop := sharkHistory[i]; END;
  END;
  dataH    := PLOT_BOTTOM - PLOT_TOP - 1;
  plotBase := PLOT_BOTTOM - 1;
  prevFishY := 0; prevSharkY := 0; prevX := 0;
  FOR i := 0 TO historyLen - 1 DO
    x      := PLOT_LEFT + i;
    fishY  := plotBase - (fishHistory[i]  * dataH DIV maxPop);
    sharkY := plotBase - (sharkHistory[i] * dataH DIV maxPop);
    IF i > 0 THEN
      Terminal.Line(prevX, prevFishY,  x, fishY,  COLOR_FISH);
      Terminal.Line(prevX, prevSharkY, x, sharkY, COLOR_SHARK);
    ELSE
      Terminal.Plot(x, fishY,  COLOR_FISH);
      Terminal.Plot(x, sharkY, COLOR_SHARK);
    END;
    prevFishY  := fishY;
    prevSharkY := sharkY;
    prevX      := x;
  END;
  Terminal.Flush();
END DrawPlot;

PROCEDURE ProcessFish(y, x: INTEGER);
VAR
  nys, nxs: NeighborList;
  count, choice, ny, nx: INTEGER;
BEGIN
  INC(age[y, x]);
  FindNeighbors(y, x, EMPTY, nys, nxs, count);
  IF count > 0 THEN
    choice := Random.Int(count);
    ny := nys[choice]; nx := nxs[choice];
    state[ny, nx] := FISH;
    moved[ny, nx] := TRUE;
    IF age[y, x] >= FISH_BREED THEN
      age[y, x] := 0;
      age[ny, nx] := 0;
    ELSE
      age[ny, nx] := age[y, x];
      state[y, x] := EMPTY;
      age[y, x] := 0;
    END;
  END;
END ProcessFish;

PROCEDURE ProcessShark(y, x: INTEGER);
VAR
  nys, nxs: NeighborList;
  count, choice, ny, nx: INTEGER;
  didMove: BOOLEAN;
BEGIN
  DEC(energy[y, x]);
  IF energy[y, x] <= 0 THEN
    state[y, x] := EMPTY;
    age[y, x] := 0;
    RETURN;
  END;
  INC(age[y, x]);
  ny := 0; nx := 0;
  didMove := FALSE;
  FindNeighbors(y, x, FISH, nys, nxs, count);
  IF count > 0 THEN
    choice := Random.Int(count);
    ny := nys[choice]; nx := nxs[choice];
    energy[ny, nx] := SHARK_STARVE;
    didMove := TRUE;
  ELSE
    FindNeighbors(y, x, EMPTY, nys, nxs, count);
    IF count > 0 THEN
      choice := Random.Int(count);
      ny := nys[choice]; nx := nxs[choice];
      energy[ny, nx] := energy[y, x];
      didMove := TRUE;
    END;
  END;
  IF didMove THEN
    state[ny, nx] := SHARK;
    moved[ny, nx] := TRUE;
    IF age[y, x] >= SHARK_BREED THEN
      state[y, x] := SHARK;
      age[y, x] := 0;
      energy[y, x] := SHARK_STARVE;
      age[ny, nx] := 0;
    ELSE
      age[ny, nx] := age[y, x];
      state[y, x] := EMPTY;
      age[y, x] := 0;
      energy[y, x] := 0;
    END;
  END;
END ProcessShark;

PROCEDURE SimStep;
VAR y, x: INTEGER;
BEGIN
  FOR y := 0 TO GRID_HEIGHT - 1 DO
    FOR x := 0 TO GRID_WIDTH - 1 DO
      moved[y, x] := FALSE;
    END;
  END;
  FOR y := 0 TO GRID_HEIGHT - 1 DO
    FOR x := 0 TO GRID_WIDTH - 1 DO
      IF (state[y, x] = FISH) & ~moved[y, x] THEN
        ProcessFish(y, x);
      END;
    END;
  END;
  FOR y := 0 TO GRID_HEIGHT - 1 DO
    FOR x := 0 TO GRID_WIDTH - 1 DO
      IF (state[y, x] = SHARK) & ~moved[y, x] THEN
        ProcessShark(y, x);
      END;
    END;
  END;
  INC(turn);
END SimStep;

PROCEDURE ShowStatus;
BEGIN
  Terminal.Goto(1, 47);
  IF showPlot THEN
    Out.String("PLOT  Tab=sim   ");
  ELSE
    Out.String("SIM   Tab=plot  ");
  END;
  Out.String("A=auto  S=step  R=reset  Q=quit  Turn: ");
  Out.Int(turn);
  Out.String("  Fish: ");
  Out.Int(fishHistory[historyLen - 1]);
  Out.String("  Sharks: ");
  Out.Int(sharkHistory[historyLen - 1]);
  Out.String("    ");
END ShowStatus;

PROCEDURE Draw;
BEGIN
  IF showPlot THEN DrawPlot(); ELSE DrawGrid(); END;
  ShowStatus();
END Draw;

BEGIN
  Terminal.Clear();
  showPlot := FALSE;
  InitGrid();
  LOOP
    Draw();
    key := Terminal.ReadKey();
    IF (key = "q") OR (key = "Q") THEN
      EXIT;
    ELSIF key = 09X THEN
      showPlot := ~showPlot;
    ELSIF (key = "r") OR (key = "R") THEN
      InitGrid();
    ELSIF (key = "s") OR (key = "S") THEN
      SimStep();
      RecordHistory();
    ELSIF (key = "a") OR (key = "A") THEN
      WHILE ~Terminal.KeyPressed() DO
        SimStep();
        RecordHistory();
        Draw();
      END;
      key := Terminal.ReadKey();
    END;
  END;
  Terminal.Reset();
END Wator.

