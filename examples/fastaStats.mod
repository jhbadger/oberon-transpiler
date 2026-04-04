MODULE fastaStats;

IMPORT FastaParser, Files, Out, Args;

VAR
  f:       Files.File;
  s:       FastaParser.Scanner;
  seq:     FastaParser.Sequence;
  count:   INTEGER;
  total:   INTEGER;
  minLen:  INTEGER;
  maxLen:  INTEGER;
  fname:   ARRAY 512 OF CHAR;

BEGIN
  IF Args.Count() < 1 THEN
    Out.String("Usage: fastaStats <file.fasta>"); Out.Ln;
    RETURN
  END;
  Args.Get(1, fname);
  f := Files.Old(fname);
  IF f = NIL THEN
    Out.String("Error: cannot open "); Out.String(fname); Out.Ln;
    RETURN
  END;

  FastaParser.InitScanner(s, f);

  count  := 0;
  total  := 0;
  minLen := 2147483647;
  maxLen := 0;

  WHILE FastaParser.ReadNext(s, seq) DO
    INC(count);
    INC(total, seq.len);
    IF seq.len < minLen THEN minLen := seq.len END;
    IF seq.len > maxLen THEN maxLen := seq.len END
  END;

  Files.Close(f);

  IF count = 0 THEN
    Out.String("No sequences found."); Out.Ln
  ELSE
    Out.String("Sequences : "); Out.Int(count, 0); Out.Ln;
    Out.String("Min length: "); Out.Int(minLen, 0); Out.Ln;
    Out.String("Max length: "); Out.Int(maxLen, 0); Out.Ln;
    Out.String("Avg length: "); Out.Int(total DIV count, 0); Out.Ln
  END
END fastaStats.
