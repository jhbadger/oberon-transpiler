MODULE fact;

PROCEDURE Fact(n : INTEGER) : INTEGER;
BEGIN
    IF n = 0 THEN
        RETURN 1;
    ELSE
        RETURN n * Fact(n - 1);
    END;
END Fact;

VAR
    num : INTEGER;
    res : INTEGER;
BEGIN
    Write("Enter a number: ");
    Read(num);
    res := Fact(num);
    Write("Factorial is: ");
    Write(res);
END fact.
