MODULE FastaParser;

IMPORT Files;

CONST
  MaxIdLen* = 128; 

TYPE
  Scanner* = RECORD
    r: Files.Rider; 
    ch: CHAR; 
    eof*: BOOLEAN; 
    headerProcessed: BOOLEAN; (* Prevents ReadChunk before NextRecord *) 
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

(** Locates the next record, copies the ID, and positions the rider. **)
PROCEDURE NextRecord*(VAR s: Scanner; VAR id: ARRAY OF CHAR): BOOLEAN;
VAR i, max: INTEGER;
BEGIN
  SkipToNextRecord(s); 
  IF s.eof THEN RETURN FALSE END; 

  (* Consume the '>' *)
  Files.Read(s.r, s.ch); 
  
  i := 0;
  max := LEN(id) - 1; 
  (* Read ID until newline or buffer limit *)
  WHILE ~s.eof & (s.ch >= ' ') & (i < max) DO 
    id[i] := s.ch; 
    INC(i); 
    Files.Read(s.r, s.ch); 
    s.eof := s.r.eof 
  END;
  id[i] := 0X; 

  (* Skip any remaining characters on the ID line (if buffer was too small) and the newline *)
  WHILE ~s.eof & (s.ch # 0DX) & (s.ch # 0AX) DO
    Files.Read(s.r, s.ch);
    s.eof := s.r.eof
  END;

  (* Advance to the first character that could be sequence data *)
  WHILE ~s.eof & (s.ch <= ' ') DO 
    Files.Read(s.r, s.ch); 
    s.eof := s.r.eof 
  END;

  s.headerProcessed := TRUE; 
  RETURN TRUE
END NextRecord;

(** Fills 'buffer' with sequence data. Returns the number of characters read. **)
PROCEDURE ReadChunk*(VAR s: Scanner; VAR buffer: ARRAY OF CHAR): INTEGER;
VAR i, max: INTEGER;
BEGIN
  i := 0;
  max := LEN(buffer) - 1;
  
  (* IMPORTANT: If we aren't ready to read, ensure the buffer is 'empty' *)
  IF ~s.headerProcessed THEN 
    buffer[0] := 0X; 
    RETURN 0 
  END;

  WHILE ~s.eof & (s.ch # '>') & (i < max) DO
    IF s.ch > ' ' THEN
      buffer[i] := s.ch;
      INC(i)
    END;
    Files.Read(s.r, s.ch);
    s.eof := s.r.eof
  END;
  
  buffer[i] := 0X;
  IF s.ch = '>' THEN s.headerProcessed := FALSE END;
  RETURN i
END ReadChunk;

END FastaParser.
