MODULE FastaParser;

IMPORT Files;

CONST
  MaxIdLen* = 128;

TYPE
  Scanner* = RECORD
    r: Files.Rider;
    ch: CHAR;
    eof*: BOOLEAN;
    headerProcessed: BOOLEAN; (* Internal state safety *)
  END;

(** Initializes the scanner and primes the first character **)
PROCEDURE InitScanner*(VAR s: Scanner; f: Files.File);
BEGIN
  Files.Set(s.r, f, 0);
  Files.Read(s.r, s.ch);
  s.eof := s.r.eof;
  s.headerProcessed := FALSE
END InitScanner;

(** Internal: Advances to the next '>' character **)
PROCEDURE SkipToNextRecord(VAR s: Scanner);
BEGIN
  WHILE ~s.eof & (s.ch # '>') DO
    Files.Read(s.r, s.ch);
    s.eof := s.r.eof
  END
END SkipToNextRecord;

(** Locates the next record, copies the ID, and positions the rider at the data.
    Returns FALSE if no more records are found. **)
PROCEDURE NextRecord*(VAR s: Scanner; VAR id: ARRAY OF CHAR): BOOLEAN;
VAR i: INTEGER;
BEGIN
  SkipToNextRecord(s);
  IF s.eof THEN RETURN FALSE END;

  (* Skip the '>' *)
  Files.Read(s.r, s.ch);
  
  (* Read ID until newline or buffer limit *)
  i := 0;
  WHILE ~s.eof & (s.ch >= ' ') & (i < LEN(id) - 1) DO
    id[i] := s.ch;
    INC(i);
    Files.Read(s.r, s.ch);
    s.eof := s.r.eof
  END;
  id[i] := 0X;

  (* Clean up any trailing header text/whitespace before data begins *)
  WHILE ~s.eof & (s.ch < '!') DO 
    Files.Read(s.r, s.ch);
    s.eof := s.r.eof
  END;

  s.headerProcessed := TRUE;
  RETURN TRUE
END NextRecord;

(** Fills 'buffer' with the next segment of sequence data. 
    Returns the number of characters read. Returns 0 when the record ends. **)
PROCEDURE ReadChunk*(VAR s: Scanner; VAR buffer: ARRAY OF CHAR): INTEGER;
VAR i, max: INTEGER;
BEGIN
  i := 0;
  max := LEN(buffer) - 1;
  WRITELN(LEN(buffer));
  IF ~s.headerProcessed THEN RETURN 0 END;

  (* Read until the next record starts, file ends, or buffer is full *)
  WHILE ~s.eof & (s.ch # '>') & (i < max) DO
    IF s.ch > ' ' THEN
      buffer[i] := s.ch;
      INC(i)
    END;
    Files.Read(s.r, s.ch);
    s.eof := s.r.eof
  END;
  
  buffer[i] := 0X;
  
  (* If we hit a new record, this sequence is done *)
  IF s.ch = '>' THEN s.headerProcessed := FALSE END;
  
  RETURN i
END ReadChunk;

END FastaParser.