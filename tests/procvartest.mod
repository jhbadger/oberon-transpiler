MODULE ProcVarTest;
IMPORT Out;
TYPE
  Data = RECORD  x, y: INTEGER  END;
  TransformProc = PROCEDURE(VAR d: Data);
VAR
  td: TransformProc;
  a, b: Data;
PROCEDURE Dbl(VAR d: Data);
BEGIN
  d.x := d.x * 2;
  d.y := d.y * 3
END Dbl;
PROCEDURE Apply(VAR d: Data; t: TransformProc);
BEGIN
  t(d)
END Apply;
BEGIN
  td := Dbl;
  a.x := 3;  a.y := 4;
  Apply(a, td);
  Out.String("Apply(3,4): ");
  Out.Int(a.x, 0); Out.Char(','); Out.Int(a.y, 0); Out.Ln;
  b.x := 5;  b.y := 7;
  td(b);
  Out.String("Direct(5,7): ");
  Out.Int(b.x, 0); Out.Char(','); Out.Int(b.y, 0); Out.Ln
END ProcVarTest.
