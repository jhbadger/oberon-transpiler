MODULE ziptest;
IMPORT Zip, Out, Args;

VAR
  z    : Zip.Archive;
  name : ARRAY 512 OF CHAR;
  path : ARRAY 256 OF CHAR;
  i, n : INTEGER;

BEGIN
  IF Args.Count() < 1 THEN
    Out.String("Usage: ziptest <file.zip>"); Out.Ln; HALT(1)
  END;
  Args.Get(1, path);
  z := Zip.Open(path);
  IF z = NIL THEN
    Out.String("Cannot open: "); Out.String(path); Out.Ln; HALT(1)
  END;
  n := Zip.Count(z);
  Out.String("Entries: "); Out.Int(n); Out.Ln;
  FOR i := 0 TO n - 1 DO
    Zip.EntryName(z, i, name);
    Out.Int(i); Out.String("  "); Out.String(name);
    Out.String("  ("); Out.Int(Zip.EntrySize(z, i)); Out.String(" bytes)");
    Out.Ln
  END;
  Zip.Close(z)
END ziptest.
