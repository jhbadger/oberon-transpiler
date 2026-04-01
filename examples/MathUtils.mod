MODULE MathUtils;

IMPORT Out;

CONST
    MaxVal* = 1000;

VAR
    CallCount* : INTEGER;

PROCEDURE Square*(n : INTEGER) : INTEGER;
BEGIN
    CallCount := CallCount + 1;
    RETURN n * n;
END Square;

PROCEDURE Cube*(n : INTEGER) : INTEGER;
BEGIN
    CallCount := CallCount + 1;
    RETURN n * n * n;
END Cube;

PROCEDURE PrintInfo*();
BEGIN
    Out.String("MathUtils loaded. MaxVal = ");
    Out.Int(MaxVal);
    Out.Ln();
END PrintInfo;

BEGIN
    CallCount := 0;
END MathUtils.
