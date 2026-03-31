MODULE fibonacci;

PROCEDURE fib(n: INTEGER): INTEGER;
BEGIN
  IF (n < 2) THEN RETURN n;
  ELSE RETURN fib(n-1) + fib(n-2);
  END;
END fib;

VAR
    num : INTEGER;
    res : INTEGER;
BEGIN
    Write("Enter a number: ");
    Read(num);
    res := fib(num);
    Write("Fibonacci is: ");
    Write(res);
END fibonacci.
