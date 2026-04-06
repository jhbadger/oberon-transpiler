MODULE Maze;

IMPORT Random, Out;

CONST 
  MAZE_SIZE = 21; (* Odd numbers work best for the carving logic *)
  WALL = '#';
  PATH = '.';
  START = 'S';
  STOP = 'E';

VAR 
  maze : ARRAY MAZE_SIZE, MAZE_SIZE OF CHAR;

PROCEDURE InitializeMaze();
  VAR i, j : INTEGER;
  BEGIN
    FOR i := 0 TO MAZE_SIZE-1 DO
      FOR j := 0 TO MAZE_SIZE-1 DO
        maze[i, j] := WALL;
      END;
    END;
  END InitializeMaze;

PROCEDURE IsValid(x, y : INTEGER) : BOOLEAN;
  BEGIN
    (* Check if within bounds and specifically an unvisited wall *)
    RETURN (x > 0) & (x < MAZE_SIZE-1) & (y > 0) & (y < MAZE_SIZE-1) & (maze[y, x] = WALL);
  END IsValid;

PROCEDURE GenerateMaze(x, y : INTEGER);
  VAR 
    k, r, temp, nx, ny, dx, dy : INTEGER;
    dirs : ARRAY 4 OF INTEGER;
  BEGIN
    maze[y, x] := PATH;

    (* 1. Initialize directions: 0:Up, 1:Down, 2:Left, 3:Right *)
    dirs[0] := 0; dirs[1] := 1; dirs[2] := 2; dirs[3] := 3;

    (* 2. Shuffle directions using Random.Int to ensure a unique maze *)
    FOR k := 0 TO 3 DO
      r := Random.Int(4);
      temp := dirs[k];
      dirs[k] := dirs[r];
      dirs[r] := temp;
    END;

    (* 3. Attempt to move in the shuffled directions *)
    FOR k := 0 TO 3 DO
      dx := 0; dy := 0;
      IF dirs[k] = 0 THEN dy := -2 ELSIF dirs[k] = 1 THEN dy := 2 
      ELSIF dirs[k] = 2 THEN dx := -2 ELSIF dirs[k] = 3 THEN dx := 2 END;

      nx := x + dx;
      ny := y + dy;

      IF IsValid(nx, ny) THEN
        (* Carve a path through the wall between current and next cell *)
        maze[y + (dy DIV 2), x + (dx DIV 2)] := PATH;
        GenerateMaze(nx, ny);
      END;
    END;
  END GenerateMaze;

PROCEDURE SetEndpoints();
  BEGIN
    maze[Random.Int(MAZE_SIZE-1), 0] := START;
    maze[Random.Int(MAZE_SIZE-1), MAZE_SIZE-1] := STOP;
  END SetEndpoints;

PROCEDURE PrintMaze();
  VAR i, j : INTEGER;
  BEGIN
    FOR i := 0 TO MAZE_SIZE-1 DO
      FOR j := 0 TO MAZE_SIZE-1 DO
        (* Simple write character *)
        Out.Char(maze[i, j]);
      END;
      Out.Ln;
    END;
  END PrintMaze;

BEGIN
  InitializeMaze();
  (* Always start on an odd coordinate to align with 2-step carving *)
  GenerateMaze(1, 1);
  SetEndpoints();
  PrintMaze();
END Maze.