MODULE Example;

IMPORT In, Out;

VAR
    x, res : INTEGER;  (* These must be here to be global *)

PROCEDURE Calc(n : INTEGER) : INTEGER;
BEGIN
    RETURN n * 2;
END Calc;

BEGIN
    In.Int(x);
    res := Calc(x);
    Out.Int(res);
END Example.
