MODULE multitest;

IMPORT Out, MU := MathUtils;

VAR
    i : INTEGER;

BEGIN
    MU.PrintInfo();

    Out.String("Squares 1..5:"); Out.Ln();
    i := 1;
    WHILE i <= 5 DO
        Out.Int(i);
        Out.String("^2 = ");
        Out.Int(MU.Square(i));
        Out.Ln();
        i := i + 1;
    END;

    Out.String("Cubes 1..5:"); Out.Ln();
    i := 1;
    WHILE i <= 5 DO
        Out.Int(i);
        Out.String("^3 = ");
        Out.Int(MU.Cube(i));
        Out.Ln();
        i := i + 1;
    END;

    Out.String("Total calls: ");
    Out.Int(MU.CallCount);
    Out.Ln();

    Out.String("MaxVal from library: ");
    Out.Int(MU.MaxVal);
    Out.Ln();
END multitest.
