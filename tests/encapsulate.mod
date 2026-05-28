MODULE Encapsulate;

IMPORT Out, Math;

(* Tests if transpiler supports functions with same name in different modules *)

PROCEDURE log(x: INTEGER) : INTEGER;
BEGIN
  Out.String("Log Message: ");
  Out.Int(x);
  Out.Ln;
  RETURN x;
END log;

BEGIN
  Out.Real(log(15));
  Out.Ln;
  log(15);
END Encapsulate.  
