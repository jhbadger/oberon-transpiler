MODULE Sieve;

IMPORT Out;

CONST
  N = 3000;

PROCEDURE FindPrimes*;
VAR
  isPrime: ARRAY N + 1 OF BOOLEAN;
  i, j: INTEGER;
BEGIN
  (* Initialize the array *)
  FOR i := 2 TO N DO
    isPrime[i] := TRUE
  END;

  (* Start the Sieve *)
  i := 2;
  WHILE i * i <= N DO
    IF isPrime[i] THEN
      j := i * i;
      WHILE j <= N DO
        isPrime[j] := FALSE;
        j := j + i
      END
    END;
    INC(i)
  END;

  (* Output the results *)
  Out.String("Primes up to "); Out.Int(N, 0); Out.Ln;
  FOR i := 2 TO N DO
    IF isPrime[i] THEN
      Out.Int(i, 6)
    END
  END;
  Out.Ln
END FindPrimes;

BEGIN
  FindPrimes
END Sieve.