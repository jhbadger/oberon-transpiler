MODULE BrazilianNumbers;
  IMPORT Out;

  VAR
    c, n: INTEGER;

  PROCEDURE SameDigits (n, b: INTEGER): BOOLEAN;
    VAR f: INTEGER;
  BEGIN
    f := n MOD b;
    n := n DIV b;
    WHILE n > 0 DO
      IF n MOD b # f THEN RETURN FALSE END;
      n := n DIV b
    END;
    RETURN TRUE
  END SameDigits;

  PROCEDURE IsBrazilian (n: INTEGER): BOOLEAN;
    VAR b: INTEGER;
  BEGIN
    IF n < 7 THEN
      RETURN FALSE
    ELSIF (n MOD 2 = 0) & (n >= 8) THEN
      RETURN TRUE
    ELSE
      b := 2;
      WHILE b <= n - 2 DO
        IF SameDigits(n, b) THEN RETURN TRUE END;
        INC(b)
      END;
      RETURN FALSE
    END
  END IsBrazilian;

  PROCEDURE IsPrime (n: INTEGER): BOOLEAN;
    VAR d: INTEGER;
  BEGIN
    IF n < 2 THEN RETURN FALSE
    ELSIF n MOD 2 = 0 THEN RETURN n = 2
    ELSIF n MOD 3 = 0 THEN RETURN n = 3
    ELSE
      d := 5;
      WHILE d * d <= n DO
        IF n MOD d = 0 THEN RETURN FALSE END;
        d := d + 2;
        IF n MOD d = 0 THEN RETURN FALSE END;
        d := d + 4
      END;
      RETURN TRUE
    END
  END IsPrime;

  PROCEDURE PrintBrazilian (count, start, step: INTEGER; onlyPrimes: BOOLEAN);
    VAR found, val: INTEGER;
  BEGIN
    found := 0; val := start;
    WHILE found < count DO
      IF IsBrazilian(val) THEN
        IF (~onlyPrimes) OR IsPrime(val) THEN
          Out.Int(val, 0); Out.Char(" ");
          INC(found)
        END
      END;
      IF onlyPrimes THEN
        (* When looking for primes, we skip even numbers after 2 *)
        IF val = 2 THEN INC(val) ELSE val := val + 2 END
      ELSE
        val := val + step
      END
    END;
    Out.Ln
  END PrintBrazilian;

BEGIN
  Out.String("First 20 Brazilian numbers:"); Out.Ln;
  PrintBrazilian(20, 7, 1, FALSE);
  Out.Ln;

  Out.String("First 20 odd Brazilian numbers:"); Out.Ln;
  PrintBrazilian(20, 7, 2, FALSE);
  Out.Ln;

  Out.String("First 20 prime Brazilian numbers:"); Out.Ln;
  PrintBrazilian(20, 7, 2, TRUE)
END BrazilianNumbers.