MODULE ConstTest;
IMPORT Out;

PROCEDURE Run;
CONST
  Limit = 5;
  Greeting = "Hello";
  Pi = 3.14159;
BEGIN
  Out.String(Greeting); Out.Ln;
  Out.Int(Limit, 0); Out.Ln;
  Out.Real(Pi); Out.Ln;
END Run;

BEGIN
  Run
END ConstTest.