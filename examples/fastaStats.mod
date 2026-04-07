MODULE fastaStats;

IMPORT FastaParser, Strings, Files, Out, Args;

VAR
  f:       Files.File;
  s:       FastaParser.Scanner;
  chunk:   ARRAY 32768 OF CHAR;
  id:      ARRAY 64 OF CHAR;
  read:    LONGINT;
  count:   LONGINT;
  slen:    LONGINT;
  total:   LONGINT;
  minLen:  LONGINT;
  maxLen:  LONGINT;
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
  slen   := 0;
  total  := 0;
  minLen := -1;
  maxLen := 0;

  WHILE FastaParser.NextRecord(s, id) DO
    INC(count);
    slen := 0; 
    REPEAT
      read := FastaParser.ReadChunk(s, chunk);
      INC(slen, Strings.Length(chunk));
    UNTIL read = 0;
    INC(total, slen);
    IF minLen < 0 OR slen < minLen THEN minLen := slen END;
    IF slen > maxLen THEN maxLen := slen END
  END;

  Files.Close(f);

  IF count = 0 THEN
    Out.String("No sequences found."); Out.Ln
  ELSE
    Out.String("Sequences : "); Out.Int(count, 0); Out.Ln;
    Out.String("Min length: "); Out.Int(minLen, 0); Out.Ln;
    Out.String("Max length: "); Out.Int(maxLen, 0); Out.Ln;
    Out.String("Tot length: "); Out.Int(total, 0); Out.Ln;
    Out.String("Avg length: "); Out.Int(total DIV count, 0); Out.Ln
  END
END fastaStats.
