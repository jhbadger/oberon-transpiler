MODULE fact;

IMPORT Out, In;

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
    Out.String("Enter a number: ");
    In.Int(num);
    res := Fact(num);
    Out.String("Factorial is: ");
    Out.Int(res);
END fact.
