MODULE NQueens;
IMPORT Out; 

CONST 
    N = 8;
VAR 
    hist: ARRAY N OF INTEGER;
    count: INTEGER;

(** * Checks if a queen placed at (row, col) is under attack 
 * by any queens already placed in columns 0 to col-1.
 *)
PROCEDURE Attack(row, col: INTEGER; VAR h: ARRAY OF INTEGER): BOOLEAN;
    VAR 
        prevCol, rowDiff, colDiff: INTEGER;
BEGIN
    FOR prevCol := 0 TO col - 1 DO
        (* 1. Check if same row *)
        IF h[prevCol] = row THEN RETURN TRUE END;
        
        (* 2. Check diagonals: Row distance must not equal Column distance *)
        IF row > h[prevCol] THEN rowDiff := row - h[prevCol] 
        ELSE rowDiff := h[prevCol] - row 
        END;
        
        colDiff := col - prevCol;
        
        IF rowDiff = colDiff THEN RETURN TRUE END;
    END;
    RETURN FALSE
END Attack;

(**
 * Recursive solver using backtracking
 *)
PROCEDURE Solve(n, col: INTEGER);
    VAR i, j: INTEGER;
BEGIN
    IF col = n THEN
        (* All queens placed - Print solution *)
        INC(count);
        Out.Ln; Out.String("Solution No. "); Out.Int(count, 0); Out.Ln;
        Out.String("----------------"); Out.Ln;
        
        FOR i := 0 TO n-1 DO
            FOR j := 0 TO n-1 DO
                IF i = hist[j] THEN 
                    Out.String("Q ")
                ELSIF (i + j) MOD 2 = 1 THEN 
                    Out.String(". ")
                ELSE 
                    Out.String("  ")
                END;
            END;
            Out.Ln;
        END;
    ELSE
        (* Try placing a queen in each row of the current column *)
        FOR i := 0 TO n-1 DO
            IF ~Attack(i, col, hist) THEN
                hist[col] := i;   (* Record position *)
                Solve(n, col + 1); (* Move to next column *)
            END;
        END;
    END;
END Solve;

BEGIN
    count := 0;
    Out.String("Finding solutions for N="); Out.Int(N, 0); Out.Ln;
    Solve(N, 0);
    Out.Ln; Out.String("Total solutions: "); Out.Int(count, 0); Out.Ln;
END NQueens.