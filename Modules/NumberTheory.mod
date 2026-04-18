MODULE NumberTheory;

(* Module to handle various problems in number theory *)

IMPORT Math,Out;

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

PROCEDURE GCD*(a, b: LONGINT): LONGINT;
BEGIN
  IF b = 0 THEN RETURN a
  ELSE RETURN GCD(b, a MOD b);
  END;
END GCD;

END NumberTheory.

