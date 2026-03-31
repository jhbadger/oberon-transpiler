MODULE fibonacci;

PROCEDURE fib(n: INTEGER): INTEGER;
BEGIN
		 IF n < 2 THEN RETURN n;
		 ELSE RETURN fib(n-1) + fib(n-2);
		 END;
END fib;

VAR
     i : INTEGER;
BEGIN
		 i := 1;
		 WHILE i < 31 DO
					Write(fib(i));
					i := i + 1;
		 END;												 
END fibonacci.
