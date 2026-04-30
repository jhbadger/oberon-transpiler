MODULE FastaEditor;

IMPORT Terminal, Files, Strings, Args, Out;

CONST
  MaxSeqs = 64;
  MaxLen  = 1024;
  GapChar = "-";
  HeaderWidth = 14;

TYPE
  Sequence = RECORD
    header: ARRAY 128 OF CHAR;
    data: ARRAY MaxLen OF CHAR;
  END;

VAR
  seqs: ARRAY MaxSeqs OF Sequence;
  numSeqs, cursorX, cursorY, scrollX, scrollY: INTEGER;
  filename: ARRAY 256 OF CHAR;

PROCEDURE Load(name: ARRAY OF CHAR);
VAR
  f: Files.File;
  r: Files.Rider;
  line: ARRAY 256 OF CHAR;
BEGIN
  f := Files.Old(name);
  IF f = NIL THEN Out.String("Error opening file"); Out.Ln; HALT(1) END;
  
  Files.Set(r, f, 0);
  numSeqs := -1;
  Files.ReadLine(r, line);
  WHILE ~r.eof DO
    IF line[0] = ">" THEN
      INC(numSeqs);
      Strings.Copy(line, seqs[numSeqs].header);
      seqs[numSeqs].data[0] := 0X;
    ELSIF numSeqs >= 0 THEN
      Strings.Append(line, seqs[numSeqs].data);
    END;
    Files.ReadLine(r, line);
  END;
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
    Files.WriteLine(r, seqs[i].data);
  END;
  Files.Register(f);
  Files.Close(f);
END Save;

PROCEDURE Draw;
VAR
  i, viewW, viewH, screenRow: INTEGER;
  sub: ARRAY 256 OF CHAR;
BEGIN
  Terminal.HideCursor();
  Terminal.Clear();
  viewW := Terminal.Cols() - (HeaderWidth + 1);
  viewH := Terminal.Rows() - 2; (* Leave space for header and footer *)

  (* Header Bar *)
  Terminal.Color(7, 4); 
  Terminal.Fill(1, 1, Terminal.Cols(), 1, " ");
  Terminal.Goto(2, 1);
  Out.String("FILE: "); Out.String(filename);
  Out.String(" | ARROWS: Navigate | G: Gap | DEL: Remove");

  (* Draw Visible Sequences *)
  FOR i := 0 TO viewH - 1 DO
    screenRow := i + scrollY;
    IF screenRow < numSeqs THEN
      (* Draw Header names *)
      Terminal.Color(2, 0);
      Terminal.Goto(1, i + 2);
      Strings.Extract(seqs[screenRow].header, 1, HeaderWidth, sub);
      Out.String(sub);
      
      (* Draw Sequence data *)
      Terminal.Color(7, 0);
      Terminal.Goto(HeaderWidth + 1, i + 2);
      Strings.Extract(seqs[screenRow].data, scrollX, viewW, sub);
      Out.String(sub);
    END;
  END;

  (* Status bar *)
  Terminal.Color(0, 7);
  Terminal.Goto(1, Terminal.Rows());
  Out.String("X:"); Out.Int(cursorX, 0); 
  Out.String(" Y:"); Out.Int(cursorY, 0);
  Out.String(" | S: Save | Q: Quit");
  
  (* Restore cursor to active position *)
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
      0A0X: IF cursorY > 0 THEN DEC(cursorY) END (* Up *)
      | 0A1X: IF cursorY < numSeqs - 1 THEN INC(cursorY) END (* Down *)
      | 0A2X: IF cursorX > 0 THEN DEC(cursorX) END (* Left *)
      | 0A3X: INC(cursorX) (* Right *)
      | "g", "G": Strings.Insert(gapStr, cursorX, seqs[cursorY].data)
      | 84X: Strings.Delete(seqs[cursorY].data, cursorX, 1) (* Delete *)
      | "s", "S": Save()
      | "q", "Q": looping := FALSE
    ELSE
    END;

    (* Vertical Scrolling *)
    IF cursorY < scrollY THEN 
      scrollY := cursorY 
    ELSIF cursorY >= scrollY + viewH THEN 
      scrollY := cursorY - viewH + 1 
    END;

    (* Horizontal Scrolling *)
    IF cursorX < scrollX THEN 
      scrollX := cursorX
    ELSIF cursorX >= scrollX + viewW THEN
      scrollX := cursorX - viewW + 1
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
