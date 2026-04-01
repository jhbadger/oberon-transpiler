MODULE filestest;
(*
 * Tests the Files and Strings modules.
 * Writes a small file, reads it back line by line,
 * then exercises Strings operations on the content.
 *)

IMPORT Files, Strings, Out;

VAR
  f         : INTEGER;
  line, buf : STRING;
  n, pos    : INTEGER;

BEGIN
  (* ── Write a test file ─────────────────────────────────────────── *)
  f := Files.Open("filestest.tmp", "w");
  IF f = 0 THEN
    Out.String("Error: could not create filestest.tmp"); Out.Ln()
  ELSE
    Files.WriteString(f, "Hello, Oberon!");  Files.WriteLn(f);
    Files.WriteString(f, "Second line.");    Files.WriteLn(f);
    Files.WriteString(f, "Third line.");     Files.WriteLn(f);
    Files.Close(f);
    Out.String("Written filestest.tmp"); Out.Ln()
  END;

  (* ── Read it back ─────────────────────────────────────────────── *)
  f := Files.Open("filestest.tmp", "r");
  IF f = 0 THEN
    Out.String("Error: could not open filestest.tmp"); Out.Ln()
  ELSE
    Out.String("Lines read back:"); Out.Ln();
    WHILE Files.EOF(f) = 0 DO
      Files.ReadLine(f, line);
      IF Strings.Length(line) > 0 THEN
        Out.String("  ["); Out.String(line); Out.String("]"); Out.Ln()
      END
    END;
    Files.Close(f)
  END;

  (* ── Strings operations ────────────────────────────────────────── *)
  Out.Ln();
  Out.String("Strings tests:"); Out.Ln();

  Strings.Copy("Hello", buf);
  Out.String("  Copy:    "); Out.String(buf); Out.Ln();

  Strings.Append(", world", buf);
  Out.String("  Append:  "); Out.String(buf); Out.Ln();

  Out.String("  Length:  "); Out.Int(Strings.Length(buf)); Out.Ln();

  Out.String("  Compare(Hello,Hello):  ");
  Out.Int(Strings.Compare("Hello", "Hello")); Out.Ln();

  Out.String("  Compare(abc,abd):      ");
  Out.Int(Strings.Compare("abc", "abd")); Out.Ln();

  pos := Strings.Pos("world", buf);
  Out.String("  Pos(world, buf):         "); Out.Int(pos); Out.Ln();

  pos := Strings.Pos("xyz", buf);
  Out.String("  Pos(xyz, buf):           "); Out.Int(pos); Out.Ln()
END filestest.
