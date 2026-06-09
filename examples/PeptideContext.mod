MODULE PeptideContext;

(*
  PeptideContext - Extract genomic neighbourhood context for protein IDs.
  Uses BioIO for FASTA reading and BioSeq for sequence storage.

  Usage:
    PeptideContext <n> <ids_file> <fasta1> [<fasta2> ...]

  Output: peptide_context.csv
    Columns: ID, -n, ..., -1, 0 (query), +1, ..., +n
    Each cell contains the annotation extracted from between << >> in the
    FASTA header, or the bare header description if no << >> markers are found.
*)

IMPORT Args, Out, Files, Strings, BioIO, BioSeq, Dict;

CONST
  MAXPROT  = 65536;
  MAXIDS   = 4096;
  NAMELEN  = 128;
  ANNOTLEN = 256;

TYPE
  ProtRec = RECORD
    id    : ARRAY NAMELEN  OF CHAR;
    annot : ARRAY ANNOTLEN OF CHAR;
  END;

VAR
  prots  : ARRAY MAXPROT OF ProtRec;
  nProt  : INTEGER;
  ids    : ARRAY MAXIDS OF ARRAY NAMELEN OF CHAR;
  nIds   : INTEGER;
  radius : INTEGER;
  idIndex: Dict.Table;   (* id -> integer index in prots[], stored as decimal string *)

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
      len := 0
    END
  END
END TrimRight;

(* Extract text between first << and >> in src into dst.
   Returns TRUE if found, FALSE otherwise (dst set to desc fallback). *)
PROCEDURE ExtractAnnot(src : ARRAY OF CHAR; VAR dst : ARRAY OF CHAR) : BOOLEAN;
  VAR i, lo, slen, dlim : INTEGER; found : BOOLEAN;
BEGIN
  dst[0] := 0X;
  slen   := Strings.Length(src);
  lo     := -1;
  found  := FALSE;
  i      := 0;
  dlim   := LEN(dst) - 1;
  WHILE (i < slen) & ~found DO
    IF (i + 1 < slen) & (src[i] = '<') & (src[i+1] = '<') THEN
      lo := i + 2;
      INC(i, 2)
    ELSIF (i + 1 < slen) & (src[i] = '>') & (src[i+1] = '>') & (lo >= 0) THEN
      Strings.Extract(src, lo, i - lo, dst);
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
    rdr  : BioIO.FastaReader;
    rec  : BioIO.FastaRecord;
    ann  : ARRAY ANNOTLEN OF CHAR;
    desc : ARRAY ANNOTLEN OF CHAR;
    idxStr : ARRAY 16 OF CHAR;
BEGIN
  IF ~BioIO.OpenFasta(rdr, path) THEN
    Out.String("Warning: cannot open "); Out.String(path); Out.Ln;
    RETURN
  END;

  rec.seq   := NIL;
  rec.name[0] := 0X;
  rec.desc[0] := 0X;
  WHILE BioIO.ReadFasta(rdr, rec) DO
    IF nProt >= MAXPROT THEN
      Out.String("Warning: MAXPROT reached, truncating."); Out.Ln;
      BioIO.CloseFasta(rdr);
      RETURN
    END;

    (* rec.name is already the first whitespace-delimited token (no '>') *)
    Strings.Copy(rec.name, prots[nProt].id);

    (* Try to extract << >> annotation from desc; fall back to name if desc empty *)
    IF Strings.Length(rec.desc) > 0 THEN
      IF ExtractAnnot(rec.desc, ann) THEN
        Strings.Copy(ann, prots[nProt].annot)
      ELSE
        Strings.Copy(rec.desc, desc);
        TrimRight(desc);
        Strings.Copy(desc, prots[nProt].annot)
      END
    ELSE
      IF ExtractAnnot(rec.name, ann) THEN
        Strings.Copy(ann, prots[nProt].annot)
      ELSE
        prots[nProt].annot[0] := 0X
      END
    END;

    (* Index id -> position for O(1) lookup *)
    Strings.IntToStr(nProt, idxStr);
    Dict.Put(idIndex, prots[nProt].id, idxStr);

    INC(nProt)
  END;

  BioIO.CloseFasta(rdr)
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
      Strings.Copy(line, ids[nIds]);
      INC(nIds)
    END
  END;
  Files.Close(f)
END LoadIds;

(* ------------------------------------------------------------------ *)

PROCEDURE FindProt(id : ARRAY OF CHAR) : INTEGER;
  VAR val : ARRAY 16 OF CHAR; n : INTEGER; ok : BOOLEAN;
BEGIN
  IF Dict.Get(idIndex, id, val) THEN
    ok := Strings.StrToInt(val, n);
    IF ok THEN RETURN n END
  END;
  RETURN -1
END FindProt;

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
  Dict.Init(idIndex);

  IF Args.Count() < 3 THEN
    Out.String("Usage: PeptideContext <n> <ids_file> <fasta1> [<fasta2> ...]");
    Out.Ln;
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
  Out.String(" proteins, "); Out.Int(nIds, 0);
  Out.String(" query IDs."); Out.Ln;

  outFile := Files.New("peptide_context.csv");
  IF outFile = NIL THEN
    Out.String("Error: cannot create peptide_context.csv"); Out.Ln;
    HALT(1)
  END;
  Files.Set(wr, outFile, 0);

  (* header row *)
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

  (* data rows *)
  i := 0;
  WHILE i < nIds DO
    WriteQuoted(wr, ids[i]);
    qi := FindProt(ids[i]);

    IF qi < 0 THEN
      Out.String("Warning: ID '"); Out.String(ids[i]);
      Out.String("' not found."); Out.Ln
    END;

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
  Files.Close(outFile);
  Out.String("Written: peptide_context.csv"); Out.Ln
END PeptideContext.

