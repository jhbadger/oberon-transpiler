MODULE fibonacci;

IMPORT Out;

PROCEDURE fib(n: INTEGER): INTEGER;
BEGIN
  IF n < 2 THEN RETURN n;
  ELSE RETURN fib(n-1) + fib(n-2);
  END;
END fib;

VAR
   i : INTEGER;
BEGIN
  FOR i := 1 TO 30 DO
    Out.Int(fib(i));
    Out.Ln;
  END;             
END fibonacci.
