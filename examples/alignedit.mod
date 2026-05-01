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
  cmdname:  ARRAY 256 OF CHAR;
  showDots: BOOLEAN;

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
  i, j, k, viewW, viewH, screenRow, colIndex: INTEGER;
  sub: ARRAY 512 OF CHAR;
  ch, refCh: CHAR;
  isIdentical: BOOLEAN;
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
  Out.String(" | .: Toggle Dots | G: Gap | DEL: Rem | S: Save");

  FOR i := 0 TO viewH - 1 DO
    screenRow := i + scrollY;
    IF screenRow < numSeqs THEN
      Terminal.Color(2, 0);
      Terminal.Goto(1, i + 2);
      Strings.Extract(seqs[screenRow].header, 1, HeaderWidth, sub);
      Out.String(sub);

      Terminal.Goto(HeaderWidth + 1, i + 2);
      Strings.Extract(seqs[screenRow].data^, scrollX, viewW, sub);
      
      (* Draw sequence with colors *)
      FOR j := 0 TO Strings.Length(sub) - 1 DO
        ch := sub[j];
        colIndex := scrollX + j;

        (* NEW LOGIC: Check if the column is identical across all sequences *)
        IF showDots & (numSeqs > 1) THEN
          isIdentical := TRUE;
          IF colIndex < Strings.Length(seqs[0].data^) THEN
            refCh := seqs[0].data^[colIndex];
            FOR k := 1 TO numSeqs - 1 DO
              IF (colIndex >= Strings.Length(seqs[k].data^)) OR (seqs[k].data^[colIndex] # refCh) THEN
                isIdentical := FALSE;
              END;
            END;
          ELSE
            isIdentical := FALSE;
          END;

          (* If identical (and not a gap), replace the character with a dot *)
          IF isIdentical & (ch # "-") & (ch # 0X) THEN
            ch := ".";
          END;
        END;

        CASE ch OF
          "A", "a": Terminal.Color(1, 0) (* Red *)
          |"T", "t", "U", "u": Terminal.Color(4, 0) (* Blue *)
          |"G", "g": Terminal.Color(3, 0) (* Yellow *)
          |"C", "c": Terminal.Color(2, 0) (* Green *)
          
          |"V", "v", "I", "i", "L", "l", "M", "m", "F", "f", "Y", "y", "W", "w": Terminal.Color(7, 0) 
          |"S", "s", "P", "p", "Q", "q", "N", "n": Terminal.Color(6, 0) 
          |"D", "d", "E", "e", "K", "k", "R", "r", "H", "h": Terminal.Color(5, 0) 
          
        ELSE
          Terminal.Color(7, 0) (* Default: White, also used for our new "." characters *)
        END;
        Out.Char(ch);
      END;
    END;
  END;

  Terminal.Color(0, 7);
  Terminal.Goto(1, Terminal.Rows());
  Out.String("X:"); Out.Int(cursorX, 0);
  Out.String(" Y:"); Out.Int(cursorY, 0);
  Out.String(" | Up/Dn/PgUp/PgDn/Home/End | Q: Quit");

  Terminal.Goto((HeaderWidth + 1) + (cursorX - scrollX), (cursorY - scrollY) + 2);
  Terminal.ShowCursor();
END Draw;

PROCEDURE Run;
VAR
  ch: CHAR;
  looping: BOOLEAN;
  viewW, viewH, actualMax, i: INTEGER;
  gapStr: ARRAY 2 OF CHAR;
BEGIN
  showDots := FALSE;
  looping := TRUE;
  cursorX := 0; cursorY := 0; scrollX := 0; scrollY := 0;
  gapStr[0] := "-"; gapStr[1] := 0X;

  WHILE looping DO
    viewW := Terminal.Cols() - (HeaderWidth + 1);
    viewH := Terminal.Rows() - 2;
    Draw();
    ch := Terminal.ReadKey();

    (* Calculate the actual max length of the current alignment *)
    actualMax := 0;
    FOR i := 0 TO numSeqs - 1 DO
      IF Strings.Length(seqs[i].data^) > actualMax THEN
        actualMax := Strings.Length(seqs[i].data^)
      END;
    END;
    IF actualMax = 0 THEN actualMax := 1 END; (* Prevent underflow if empty *)

    CASE ch OF
      ".": showDots := ~showDots
      | 0A0X: IF cursorY > 0 THEN DEC(cursorY) END
      | 0A1X: IF cursorY < numSeqs - 1 THEN INC(cursorY) END
      | 0A2X: IF cursorX > 0 THEN DEC(cursorX) END
      | 0A3X: IF cursorX < actualMax THEN INC(cursorX) END
      
      | 80X: (* PgUp *)
          IF cursorX > viewW THEN DEC(cursorX, viewW) ELSE cursorX := 0 END
      | 81X: (* PgDn *)
          IF cursorX + viewW < actualMax THEN 
            INC(cursorX, viewW) 
          ELSE 
            cursorX := actualMax - 1 
          END
      | 82X: (* Home *)
          cursorX := 0
      | 83X: (* End *)
          cursorX := actualMax - 1

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

    (* Clamp cursorX to ensure it never goes out of valid bounds *)
    IF cursorX < 0 THEN cursorX := 0 END;
    IF cursorX > actualMax THEN cursorX := actualMax END;

    IF cursorY < scrollY THEN scrollY := cursorY
    ELSIF cursorY >= scrollY + viewH THEN scrollY := cursorY - viewH + 1
    END;

    IF cursorX < scrollX THEN scrollX := cursorX
    ELSIF cursorX >= scrollX + viewW THEN scrollX := cursorX - viewW + 1
    END;

  END;
END Run;
BEGIN
  Args.Get(0, cmdname);
  IF Args.Count() < 1 THEN
    Out.String("Usage: ");
    Out.String(cmdname);
    Out.String(" <file.fasta>"); 
    Out.Ln;
  ELSE
    Args.Get(1, filename);
    Load(filename);
    Run();
    Terminal.Reset();
    Terminal.Clear();
  END;
END FastaEditor.



