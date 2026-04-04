MODULE FastaParser;

IMPORT Files, Strings;

CONST
  MaxIdLen = 64;
  MaxSeqLen = 10000;

TYPE
  Sequence* = RECORD
    id*: ARRAY MaxIdLen OF CHAR;
    data*: ARRAY MaxSeqLen OF CHAR;
    len*: INTEGER;
  END;

  Scanner* = RECORD
    r: Files.Rider;
    ch: CHAR;
    eof: BOOLEAN;
  END;

(** Initializes the scanner with an open file **)
PROCEDURE InitScanner*(VAR s: Scanner; f: Files.File);
BEGIN
  Files.Set(s.r, f, 0);
  Files.Read(s.r, s.ch);
  s.eof := s.r.eof;
END InitScanner;

(** Internal: Skips whitespace and reads until the next header or EOF **)
PROCEDURE SkipToHeader(VAR s: Scanner);
BEGIN
  WHILE ~s.eof & (s.ch # '>') DO
    Files.Read(s.r, s.ch);
    s.eof := s.r.eof
  END
END SkipToHeader;

(** Reads the next sequence from the file. Returns FALSE if no more sequences. **)
PROCEDURE ReadNext*(VAR s: Scanner; VAR seq: Sequence): BOOLEAN;
VAR i: INTEGER;
BEGIN
  SkipToHeader(s);
  IF s.eof THEN RETURN FALSE END;

  (* 1. Read ID (everything after '>' until newline) *)
  Files.Read(s.r, s.ch); (* skip '>' *)
  i := 0;
  WHILE ~s.eof & (s.ch # 0AX) & (s.ch # 0DX) & (i < MaxIdLen - 1) DO
    seq.id[i] := s.ch;
    INC(i);
    Files.Read(s.r, s.ch)
  END;
  seq.id[i] := 0X;

  (* 2. Read Sequence Data (lines until next '>' or EOF) *)
  i := 0;
  WHILE ~s.eof DO
    Files.Read(s.r, s.ch);
    s.eof := s.r.eof;
    IF s.eof OR (s.ch = '>') THEN
      (* Stay on '>' so the next call finds it *)
      EXIT 
    END;
    
    (* Filter out newlines and whitespace *)
    IF (s.ch > ' ') & (i < MaxSeqLen - 1) THEN
      seq.data[i] := s.ch;
      INC(i)
    END
  END;
  seq.data[i] := 0X;
  seq.len := i;

  RETURN TRUE
END ReadNext;

END FastaParser.