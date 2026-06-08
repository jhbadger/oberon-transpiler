MODULE PeptideContext;

(*
  PeptideContext - Extract genomic neighbourhood context for protein IDs.

  Usage:
    PeptideContext <n> <ids_file> <fasta1> [<fasta2> ...]
*)

IMPORT Args, Out, Files, Strings;

CONST
  MAXPROT  = 65536;
  MAXIDS   = 4096;
  NAMELEN  = 128;
  ANNOTLEN = 256;
  LINELEN  = 1024;

TYPE
  ProtRec = RECORD
    id    : ARRAY NAMELEN  OF CHAR;
    annot : ARRAY ANNOTLEN OF CHAR;
  END;

VAR
  prots  : ARRAY MAXPROT OF ProtRec;
  nProt  : INTEGER;
  ids    : ARRAY MAXIDS  OF ARRAY NAMELEN OF CHAR;
  nIds   : INTEGER;
  radius : INTEGER;

(* ------------------------------------------------------------------ *)

PROCEDURE TrimRight(VAR s : ARRAY OF CHAR);
  VAR len : INTEGER; c : CHAR;
BEGIN
  len := Strings.Length(s);
  WHILE len > 0 DO
    c := s[len - 1];
    IF (c = 0DX) OR (c = 0AX) OR (c = ' ') OR (c = 09X) THEN
      s[len - 1] := 0X;
      DEC(len)
    ELSE
      len := 0   (* break *)
    END
  END
END TrimRight;

(* Copy at most dstLen-1 chars from src starting at pos into dst *)
PROCEDURE SafeExtract(src : ARRAY OF CHAR; pos, len : INTEGER;
                      VAR dst : ARRAY OF CHAR);
  VAR i, slen, dlim : INTEGER;
BEGIN
  slen := Strings.Length(src);
  dlim := LEN(dst) - 1;
  IF dlim < 0 THEN dlim := 0 END;
  i := 0;
  WHILE (i < len) & (i < dlim) & (pos + i < slen) DO
    dst[i] := src[pos + i];
    INC(i)
  END;
  dst[i] := 0X
END SafeExtract;

(* Copy first whitespace-delimited token from s into tok *)
PROCEDURE FirstToken(s : ARRAY OF CHAR; VAR tok : ARRAY OF CHAR);
  VAR i, j, slen, dlim : INTEGER;
BEGIN
  tok[0] := 0X;
  slen := Strings.Length(s);
  dlim := LEN(tok) - 1;
  i := 0; j := 0;
  WHILE (i < slen) & (s[i] # 0X) & (s[i] # ' ') & (s[i] # 09X) DO
    IF j < dlim THEN
      tok[j] := s[i];
      INC(j)
    END;
    INC(i)
  END;
  tok[j] := 0X
END FirstToken;

(* Extract text between first << and >> in src *)
PROCEDURE ExtractAnnot(src : ARRAY OF CHAR; VAR dst : ARRAY OF CHAR) : BOOLEAN;
  VAR i, lo, slen : INTEGER;
      found : BOOLEAN;
      tmp : ARRAY LINELEN OF CHAR;
BEGIN
  dst[0] := 0X;
  slen := Strings.Length(src);
  lo := -1;
  found := FALSE;
  i := 0;
  WHILE (i < slen) & ~found DO
    IF (i + 1 < slen) & (src[i] = '<') & (src[i+1] = '<') THEN
      lo := i + 2;
      INC(i, 2)
    ELSIF (i + 1 < slen) & (src[i] = '>') & (src[i+1] = '>') & (lo >= 0) THEN
      SafeExtract(src, lo, i - lo, tmp);
      SafeExtract(tmp, 0, Strings.Length(tmp), dst);
      found := TRUE
    ELSE
      INC(i)
    END
  END;
  RETURN found
END ExtractAnnot;

(* ------------------------------------------------------------------ *)

PROCEDURE LoadFasta(path : ARRAY OF CHAR);
  VAR
    f    : Files.File;
    r    : Files.Rider;
    line : ARRAY LINELEN OF CHAR;
    body : ARRAY LINELEN OF CHAR;  (* without '>' *)
    tok  : ARRAY NAMELEN  OF CHAR;
    ann  : ARRAY ANNOTLEN OF CHAR;
BEGIN
  f := Files.Old(path);
  IF f = NIL THEN
    Out.String("Warning: cannot open "); Out.String(path); Out.Ln;
    RETURN
  END;
  Files.Set(r, f, 0);

  WHILE ~r.eof DO
    Files.ReadLine(r, line);
    TrimRight(line);
    IF (Strings.Length(line) > 0) & (line[0] = '>') THEN
      IF nProt >= MAXPROT THEN
        Out.String("Warning: MAXPROT reached, truncating."); Out.Ln;
        Files.Close(f);
        RETURN
      END;
      (* strip leading '>' into body *)
      SafeExtract(line, 1, Strings.Length(line) - 1, body);
      (* first token = protein id *)
      FirstToken(body, tok);
      SafeExtract(tok, 0, Strings.Length(tok), prots[nProt].id);
      (* annotation between << >> *)
      IF ExtractAnnot(line, ann) THEN
        SafeExtract(ann, 0, Strings.Length(ann), prots[nProt].annot)
      ELSE
        prots[nProt].annot[0] := 0X
      END;
      INC(nProt)
    END
    (* sequence lines ignored *)
  END;
  Files.Close(f)
END LoadFasta;

(* ------------------------------------------------------------------ *)

PROCEDURE LoadIds(path : ARRAY OF CHAR);
  VAR
    f    : Files.File;
    r    : Files.Rider;
    line : ARRAY NAMELEN OF CHAR;
    len  : INTEGER;
BEGIN
  f := Files.Old(path);
  IF f = NIL THEN
    Out.String("Error: cannot open ids file: "); Out.String(path); Out.Ln;
    HALT(1)
  END;
  Files.Set(r, f, 0);
  WHILE ~r.eof DO
    Files.ReadLine(r, line);
    TrimRight(line);
    len := Strings.Length(line);
    IF (len > 0) & (nIds < MAXIDS) THEN
      SafeExtract(line, 0, len, ids[nIds]);
      INC(nIds)
    END
  END;
  Files.Close(f)
END LoadIds;

(* ------------------------------------------------------------------ *)

PROCEDURE WriteQuoted(VAR wr : Files.Rider; s : ARRAY OF CHAR);
  VAR i, len : INTEGER; c : CHAR;
BEGIN
  Files.Write(wr, ORD('"'));
  len := Strings.Length(s);
  i   := 0;
  WHILE i < len DO
    c := s[i];
    IF c = '"' THEN Files.Write(wr, ORD('"')) END;
    Files.Write(wr, ORD(c));
    INC(i)
  END;
  Files.Write(wr, ORD('"'))
END WriteQuoted;

PROCEDURE WriteComma(VAR wr : Files.Rider);
BEGIN Files.Write(wr, ORD(',')) END WriteComma;

PROCEDURE WriteNewline(VAR wr : Files.Rider);
BEGIN Files.Write(wr, ORD(0AX)) END WriteNewline;

(* ------------------------------------------------------------------ *)

PROCEDURE FindProt(id : ARRAY OF CHAR) : INTEGER;
  VAR i : INTEGER;
BEGIN
  i := 0;
  WHILE i < nProt DO
    IF Strings.Compare(prots[i].id, id) = 0 THEN RETURN i END;
    INC(i)
  END;
  RETURN -1
END FindProt;

(* ------------------------------------------------------------------ *)

VAR
  outFile : Files.File;
  wr      : Files.Rider;
  argBuf  : ARRAY 512 OF CHAR;
  nBuf    : ARRAY 16 OF CHAR;
  i, j, qi, col : INTEGER;
  ok      : BOOLEAN;
  empty   : ARRAY 2 OF CHAR;

BEGIN
  nProt := 0;
  nIds  := 0;
  empty[0] := 0X;

  IF Args.Count() < 3 THEN
    Out.String("Usage: PeptideContext <n> <ids_file> <fasta1> [<fasta2> ...]"); Out.Ln;
    HALT(1)
  END;

  Args.Get(1, argBuf);
  ok := Strings.StrToInt(argBuf, radius);
  IF ~ok OR (radius < 0) THEN
    Out.String("Error: n must be a non-negative integer"); Out.Ln;
    HALT(1)
  END;

  Args.Get(2, argBuf);
  LoadIds(argBuf);

  i := 3;
  WHILE i <= Args.Count() DO
    Args.Get(i, argBuf);
    LoadFasta(argBuf);
    INC(i)
  END;

  Out.String("Loaded "); Out.Int(nProt, 0);
  Out.String(" proteins, "); Out.Int(nIds, 0); Out.String(" query IDs."); Out.Ln;

  outFile := Files.New("peptide_context.csv");
  IF outFile = NIL THEN
    Out.String("Error: cannot create peptide_context.csv"); Out.Ln;
    HALT(1)
  END;
  Files.Set(wr, outFile, 0);

  (* header *)
  WriteQuoted(wr, "ID");
  col := -radius;
  WHILE col <= radius DO
    WriteComma(wr);
    IF col = 0 THEN
      WriteQuoted(wr, "0 (query)")
    ELSE
      Strings.IntToStr(col, nBuf);
      WriteQuoted(wr, nBuf)
    END;
    INC(col)
  END;
  WriteNewline(wr);

  (* rows *)
  i := 0;
  WHILE i < nIds DO
    WriteQuoted(wr, ids[i]);
    qi := FindProt(ids[i]);

    col := -radius;
    WHILE col <= radius DO
      WriteComma(wr);
      j := qi + col;
      IF (qi < 0) OR (j < 0) OR (j >= nProt) THEN
        WriteQuoted(wr, empty)
      ELSE
        WriteQuoted(wr, prots[j].annot)
      END;
      INC(col)
    END;
    WriteNewline(wr);
    INC(i)
  END;

  Files.Register(outFile);
  Files.Close(outFile);
  Out.String("Written: peptide_context.csv"); Out.Ln
END PeptideContext.
