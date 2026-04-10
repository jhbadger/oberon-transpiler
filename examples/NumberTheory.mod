MODULE NumberTheory;

(* Module to handle various problems in number theory *)

IMPORT Math;

PROCEDURE IsPrime*(N: INTEGER): BOOLEAN;
VAR
  i, limit: INTEGER;
  isPrime: BOOLEAN;
BEGIN
  isPrime := TRUE; 
  
  IF N <= 1 THEN
    isPrime := FALSE
  ELSIF N MOD 2 = 0 THEN
    IF N = 2 THEN
      isPrime := TRUE
    ELSE
      isPrime := FALSE
    END
  ELSE 
    limit := Math.floor(Math.sqrt(N));
    i := 3;
    WHILE (i <= limit) & isPrime DO
      IF N MOD i = 0 THEN
        isPrime := FALSE
      END;
      i := i + 2
    END
  END;

  RETURN isPrime
END IsPrime;

END NumberTheory.