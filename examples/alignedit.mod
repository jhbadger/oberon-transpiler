MODULE FastaEditor;

IMPORT Terminal, Files, Strings, Args, Out;

CONST
  MaxSeqs = 100;
  HeaderWidth = 25;

TYPE
  SeqData = POINTER TO ARRAY OF CHAR;

  Sequence = RECORD
    header: ARRAY 128 OF CHAR;
    data: SeqData;
  END;

VAR
  seqs: ARRAY MaxSeqs OF Sequence;
  numSeqs, cursorX, cursorY, scrollX, scrollY: INTEGER;
  maxLen: INTEGER;
  filename: ARRAY 256 OF CHAR;

PROCEDURE CalculateRequiredSize(name: ARRAY OF CHAR);
VAR
  f: Files.File;
  r: Files.Rider;
  line: ARRAY 512 OF CHAR;
  currentLen: INTEGER;
BEGIN
  f := Files.Old(name);
  IF f = NIL THEN RETURN END;
  Files.Set(r, f, 0);
  maxLen := 0; currentLen := 0;

  REPEAT
    Files.ReadLine(r, line);
    IF line[0] = ">" THEN
      IF currentLen > maxLen THEN maxLen := currentLen END;
      currentLen := 0;
    ELSIF line[0] # 0X THEN
      INC(currentLen, Strings.Length(line));
    END;
  UNTIL r.eof;
  (* Account for the very last sequence *)
  IF currentLen > maxLen THEN maxLen := currentLen END;

  Files.Close(f);
  maxLen := maxLen * 2;
  IF maxLen < 100 THEN maxLen := 100 END;
END CalculateRequiredSize;

PROCEDURE Load(name: ARRAY OF CHAR);
VAR
  f: Files.File;
  r: Files.Rider;
  line: ARRAY 512 OF CHAR;
BEGIN
  CalculateRequiredSize(name);
  f := Files.Old(name);
  IF f = NIL THEN Out.String("Error opening file"); Out.Ln; HALT(1) END;

  Files.Set(r, f, 0);
  numSeqs := -1;
  REPEAT
    Files.ReadLine(r, line);
    IF line[0] = ">" THEN
      INC(numSeqs);
      Strings.Copy(line, seqs[numSeqs].header);
      NEW(seqs[numSeqs].data, maxLen);
      Strings.Copy("", seqs[numSeqs].data^)
    ELSIF (numSeqs >= 0) & (line[0] # 0X) THEN
      Strings.Append(line, seqs[numSeqs].data^);
    END;
  UNTIL r.eof;
  INC(numSeqs);
  Files.Close(f);
END Load;

PROCEDURE Save;
VAR
  f: Files.File;
  r: Files.Rider;
  i: INTEGER;
BEGIN
  f := Files.New(filename);
  Files.Set(r, f, 0);
  FOR i := 0 TO numSeqs - 1 DO
    Files.WriteLine(r, seqs[i].header);
    Files.WriteLine(r, seqs[i].data^);
  END;
  Files.Register(f);
  Files.Close(f);
END Save;

PROCEDURE Draw;
VAR
  i, viewW, viewH, screenRow: INTEGER;
  sub: ARRAY 512 OF CHAR;
BEGIN
  Terminal.HideCursor();
  Terminal.Clear();
  viewW := Terminal.Cols() - (HeaderWidth + 1);
  viewH := Terminal.Rows() - 2;

  Terminal.Color(7, 4);
  Terminal.Fill(1, 1, Terminal.Cols(), 1, " ");
  Terminal.Goto(2, 1);
  Out.String("FILE: "); Out.String(filename);
  Out.String(" | Buf: "); Out.Int(maxLen, 0);
  Out.String(" | G: Gap | DEL: Rem | S: Save");

  FOR i := 0 TO viewH - 1 DO
    screenRow := i + scrollY;
    IF screenRow < numSeqs THEN
      Terminal.Color(2, 0);
      Terminal.Goto(1, i + 2);
      Strings.Extract(seqs[screenRow].header, 1, HeaderWidth, sub);
      Out.String(sub);

      Terminal.Color(7, 0);
      Terminal.Goto(HeaderWidth + 1, i + 2);
      Strings.Extract(seqs[screenRow].data^, scrollX, viewW, sub);
      Out.String(sub);
    END;
  END;

  Terminal.Color(0, 7);
  Terminal.Goto(1, Terminal.Rows());
  Out.String("X:"); Out.Int(cursorX, 0);
  Out.String(" Y:"); Out.Int(cursorY, 0);
  Out.String(" | Up/Dn to scroll seqs | Q: Quit");

  Terminal.Goto((HeaderWidth + 1) + (cursorX - scrollX), (cursorY - scrollY) + 2);
  Terminal.ShowCursor();
END Draw;

PROCEDURE Run;
VAR
  ch: CHAR;
  looping: BOOLEAN;
  viewW, viewH: INTEGER;
  gapStr: ARRAY 2 OF CHAR;
BEGIN
  looping := TRUE;
  cursorX := 0; cursorY := 0; scrollX := 0; scrollY := 0;
  gapStr[0] := "-"; gapStr[1] := 0X;

  WHILE looping DO
    viewW := Terminal.Cols() - (HeaderWidth + 1);
    viewH := Terminal.Rows() - 2;
    Draw();
    ch := Terminal.ReadKey();

    CASE ch OF
      0A0X: IF cursorY > 0 THEN DEC(cursorY) END
      | 0A1X: IF cursorY < numSeqs - 1 THEN INC(cursorY) END
      | 0A2X: IF cursorX > 0 THEN DEC(cursorX) END
      | 0A3X: IF cursorX < maxLen - 2 THEN INC(cursorX) END
      | "g", "G":
          IF Strings.Length(seqs[cursorY].data^) < maxLen - 1 THEN
            Strings.Insert(gapStr, cursorX, seqs[cursorY].data^)
          END
      | 84X:
          Strings.Delete(seqs[cursorY].data^, cursorX, 1)
      | "s", "S": Save()
      | "q", "Q": looping := FALSE
    ELSE
    END;

    IF cursorY < scrollY THEN scrollY := cursorY
    ELSIF cursorY >= scrollY + viewH THEN scrollY := cursorY - viewH + 1
    END;

    IF cursorX < scrollX THEN scrollX := cursorX
    ELSIF cursorX >= scrollX + viewW THEN scrollX := cursorX - viewW + 1
    END;
  END;
END Run;

BEGIN
  IF Args.Count() < 1 THEN
    Out.String("Usage: FastaEditor <file.fasta>"); Out.Ln;
  ELSE
    Args.Get(1, filename);
    Load(filename);
    Run();
    Terminal.Reset();
    Terminal.Clear();
  END;
END FastaEditor.



