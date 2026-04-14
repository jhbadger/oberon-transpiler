MODULE types;

IMPORT Out;

VAR
    name : STRING;
    age : INTEGER;
    pi : REAL;
BEGIN
    name := "Gemini";
    age := 1;
    pi := 3.14159;

    Out.String("Name: ");
    Out.String(name);
		Out.Ln;
    Out.String("Age: ");
    Out.Int(age);
		Out.Ln;
    Out.String("Pi: ");
    Out.Real(pi);
		Out.Ln;
END types.
