MODULE filestest;
(*
 * Tests the standard Oberon Files API.
 * Writes binary strings and an integer, reads them back.
 *)

IMPORT Files, Out;

VAR
  f    : Files.File;
  r    : Files.Rider;
  s    : STRING;
  n    : INTEGER;

BEGIN
  (* ── Write a test file ─────────────────────────────────────────── *)
  f := Files.New("filestest.tmp");
  IF f = NIL THEN
    Out.String("Error: could not create filestest.tmp"); Out.Ln()
  ELSE
    Files.Set(r, f, 0);
    Files.WriteString(r, "Hello, Oberon!");
    Files.WriteString(r, "Second line.");
    Files.WriteString(r, "Third line.");
    Files.WriteInt(r, 42);
    Out.String("Written filestest.tmp, length = ");
    Out.Int(Files.Length(f)); Out.Ln();
    Files.Register(f);
    Files.Close(f)
  END;

  (* ── Read it back ─────────────────────────────────────────────── *)
  f := Files.Old("filestest.tmp");
  IF f = NIL THEN
    Out.String("Error: could not open filestest.tmp"); Out.Ln()
  ELSE
    Files.Set(r, f, 0);
    Files.ReadString(r, s); Out.String("  ["); Out.String(s); Out.String("]"); Out.Ln();
    Files.ReadString(r, s); Out.String("  ["); Out.String(s); Out.String("]"); Out.Ln();
    Files.ReadString(r, s); Out.String("  ["); Out.String(s); Out.String("]"); Out.Ln();
    Files.ReadInt(r, n);
    Out.String("  int: "); Out.Int(n); Out.Ln();
    Files.Close(f)
  END
END filestest.
