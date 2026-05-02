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
  Terminal.Reset();
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
  Terminal.Fill(1, Terminal.Rows(), Terminal.Cols(), 1, " ");
  Terminal.Goto(1, Terminal.Rows());
  Out.String("X:"); Out.Int(cursorX + 1, 0);
  Out.String(" Y:"); Out.Int(cursorY + 1, 0);
  Out.String(" | G:Gap Del .:Dots S:Save J:Jump F:Find Q:Quit | ShArr:Reorder");

  Terminal.Goto((HeaderWidth + 1) + (cursorX - scrollX), (cursorY - scrollY) + 2);
  Terminal.ShowCursor();
END Draw;

PROCEDURE ReadInput(prompt: ARRAY OF CHAR; VAR res: ARRAY OF CHAR);
VAR
  ch: CHAR;
  idx: INTEGER;
BEGIN
  Terminal.Color(0, 7);
  (* Clear the bottom line for the prompt *)
  Terminal.Fill(1, Terminal.Rows(), Terminal.Cols(), 1, " "); 
  Terminal.Goto(1, Terminal.Rows());
  Out.String(prompt);
  Terminal.ShowCursor();
  
  idx := 0; res[0] := 0X;
  LOOP
    ch := Terminal.ReadKey();
    IF (ch = 0DX) OR (ch = 0AX) THEN 
      EXIT (* Enter pressed *)
    ELSIF (ch = 7FX) OR (ch = 08X) THEN 
      (* Backspace handling *)
      IF idx > 0 THEN
        DEC(idx); res[idx] := 0X;
        Terminal.Goto(Strings.Length(prompt) + 1 + idx, Terminal.Rows());
        Out.String(" ");
        Terminal.Goto(Strings.Length(prompt) + 1 + idx, Terminal.Rows());
      END
    ELSIF (ch >= " ") & (ch <= "~") & (idx < 255) THEN
      (* Standard characters *)
      res[idx] := ch; INC(idx); res[idx] := 0X;
      Out.Char(ch);
    END
  END;
  Terminal.HideCursor();
END ReadInput;

PROCEDURE Run;
VAR
  ch: CHAR;
  looping, match, found: BOOLEAN;
  viewW, viewH, actualMax, i, j, val, patLen: INTEGER;
  gapStr: ARRAY 2 OF CHAR;
  inputStr: ARRAY 256 OF CHAR;
  tempSeq: Sequence; (* For swapping sequences *)
BEGIN
  looping := TRUE;
  cursorX := 0; cursorY := 0; scrollX := 0; scrollY := 0;
  gapStr[0] := "-"; gapStr[1] := 0X;
  showDots := FALSE;

  WHILE looping DO
    viewW := Terminal.Cols() - (HeaderWidth + 1);
    viewH := Terminal.Rows() - 2;
    Draw();
    ch := Terminal.ReadKey();

    actualMax := 0;
    FOR i := 0 TO numSeqs - 1 DO
      IF Strings.Length(seqs[i].data^) > actualMax THEN
        actualMax := Strings.Length(seqs[i].data^)
      END;
    END;
    IF actualMax = 0 THEN actualMax := 1 END;

    CASE ch OF
      ".": showDots := ~showDots

      | 0A0X: IF cursorY > 0 THEN DEC(cursorY) END
      | 0A1X: IF cursorY < numSeqs - 1 THEN INC(cursorY) END
      | 0A2X: IF cursorX > 0 THEN DEC(cursorX) END
      | 0A3X: IF cursorX < actualMax THEN INC(cursorX) END
      
      (* --- NEW: Sequence Reordering --- *)
      | 0A5X: (* Shift+Up *)
          IF cursorY > 0 THEN
            tempSeq := seqs[cursorY];
            seqs[cursorY] := seqs[cursorY - 1];
            seqs[cursorY - 1] := tempSeq;
            DEC(cursorY);
          END
      | 0A6X: (* Shift+Down *)
          IF cursorY < numSeqs - 1 THEN
            tempSeq := seqs[cursorY];
            seqs[cursorY] := seqs[cursorY + 1];
            seqs[cursorY + 1] := tempSeq;
            INC(cursorY);
          END
      (* --- End Reordering --- *)

      | 80X: IF cursorX > viewW THEN DEC(cursorX, viewW) ELSE cursorX := 0 END
      | 81X: IF cursorX + viewW < actualMax THEN INC(cursorX, viewW) ELSE cursorX := actualMax - 1 END
      | 82X: cursorX := 0
      | 83X: cursorX := actualMax - 1

      | "j", "J":
          ReadInput("Jump to position (1-based): ", inputStr);
          val := 0; i := 0;
          WHILE (inputStr[i] >= "0") & (inputStr[i] <= "9") DO
            val := val * 10 + (ORD(inputStr[i]) - ORD("0"));
            INC(i);
          END;
          IF val > 0 THEN 
            cursorX := val - 1;
          END;

      | "f", "F":
          ReadInput("Find sequence: ", inputStr);
          patLen := Strings.Length(inputStr);
          IF patLen > 0 THEN
            i := cursorX + 1; found := FALSE;
            WHILE (i <= actualMax - patLen) & ~found DO
              match := TRUE; j := 0;
              WHILE (j < patLen) & match DO
                IF seqs[cursorY].data^[i + j] # inputStr[j] THEN match := FALSE END;
                INC(j);
              END;
              IF match THEN
                 cursorX := i; found := TRUE;
              ELSE
                 INC(i);
              END;
            END;
          END;

      | "g", "G":
          IF Strings.Length(seqs[cursorY].data^) < maxLen - 1 THEN
            Strings.Insert(gapStr, cursorX, seqs[cursorY].data^)
          END
      | 84X: Strings.Delete(seqs[cursorY].data^, cursorX, 1)
      | "s", "S": Save()
      | "q", "Q": looping := FALSE
    ELSE
    END;

    IF cursorX < 0 THEN cursorX := 0 END;
    IF cursorX > actualMax THEN cursorX := actualMax END;
    IF cursorY < 0 THEN cursorY := 0 END;
    IF cursorY > numSeqs - 1 THEN cursorY := numSeqs - 1 END;

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





