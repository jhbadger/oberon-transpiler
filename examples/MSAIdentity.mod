MODULE MSAIdentity;

IMPORT Args, Out, BioSeq, BioIO, BioAlign, Strings;

CONST
  MaxSeqs = 256;
  MaxLen  = 100000;

VAR
  names: ARRAY MaxSeqs OF ARRAY 128 OF CHAR;
  seqs:  ARRAY MaxSeqs OF BioSeq.Seq;
  nSeqs: INTEGER;
  isProtein: BOOLEAN;
  blosum: BioAlign.ScoreMatrix;

PROCEDURE ToUpperCh(c: CHAR): CHAR;
BEGIN
  IF (c >= 'a') & (c <= 'z') THEN
    RETURN CHR(ORD(c) - ORD('a') + ORD('A'))
  END;
  RETURN c
END ToUpperCh;

PROCEDURE IsGap(c: CHAR): BOOLEAN;
BEGIN
  RETURN (c = '-') OR (c = '.') OR (c = ' ')
END IsGap;

PROCEDURE LoadAlignment(path: ARRAY OF CHAR): BOOLEAN;
  VAR rdr: BioIO.FastaReader; rec: BioIO.FastaRecord;
BEGIN
  nSeqs := 0;
  IF ~BioIO.OpenFasta(rdr, path) THEN
    Out.String("Error: cannot open "); Out.String(path); Out.Ln;
    RETURN FALSE
  END;
  rec.seq := NIL;
  WHILE BioIO.ReadFasta(rdr, rec) DO
    IF nSeqs >= MaxSeqs THEN
      Out.String("Error: too many sequences (max "); Out.Int(MaxSeqs); Out.String(")"); Out.Ln;
      BioIO.CloseFasta(rdr);
      RETURN FALSE
    END;
    Strings.Copy(rec.name, names[nSeqs]);
    seqs[nSeqs] := rec.seq;
    BioSeq.ToUpper(seqs[nSeqs]);
    INC(nSeqs);
    rec.seq := NIL  (* force fresh allocation for next record *)
  END;
  BioIO.CloseFasta(rdr);
  RETURN nSeqs > 0
END LoadAlignment;

(* Heuristic: if any sequence contains characters that aren't valid DNA/RNA
   nucleotide/gap symbols, treat as protein. *)
PROCEDURE DetectProtein(): BOOLEAN;
  VAR i, j, n, nonNuc, total: INTEGER; c: CHAR;
BEGIN
  nonNuc := 0; total := 0;
  FOR i := 0 TO nSeqs - 1 DO
    n := BioSeq.Length(seqs[i]);
    FOR j := 0 TO n - 1 DO
      c := BioSeq.Get(seqs[i], j);
      IF ~IsGap(c) THEN
        INC(total);
        IF (c # 'A') & (c # 'C') & (c # 'G') & (c # 'T') & (c # 'U') & (c # 'N') THEN
          INC(nonNuc)
        END
      END
    END
  END;
  IF total = 0 THEN RETURN FALSE END;
  (* >10% non-nucleotide letters => protein *)
  RETURN (nonNuc * 10) > total
END DetectProtein;

PROCEDURE Similar(a, b: CHAR): BOOLEAN;
BEGIN
  (* Two residues are "similar" if the BLOSUM62 substitution score is > 0. *)
  RETURN BioAlign.PairScore(blosum, a, b) > 0
END Similar;

PROCEDURE Compare(refIdx, qIdx: INTEGER; VAR ident, simil, aligned: INTEGER);
  VAR i, n, nr, nq: INTEGER; a, b: CHAR;
BEGIN
  ident := 0; simil := 0; aligned := 0;
  nr := BioSeq.Length(seqs[refIdx]);
  nq := BioSeq.Length(seqs[qIdx]);
  IF nr < nq THEN n := nr ELSE n := nq END;
  FOR i := 0 TO n - 1 DO
    a := BioSeq.Get(seqs[refIdx], i);
    b := BioSeq.Get(seqs[qIdx], i);
    (* Skip positions that are gap in BOTH; count all other aligned positions. *)
    IF ~(IsGap(a) & IsGap(b)) THEN
      INC(aligned);
      IF ~IsGap(a) & ~IsGap(b) THEN
        IF a = b THEN
          INC(ident);
          INC(simil)
        ELSIF isProtein & Similar(a, b) THEN
          INC(simil)
        END
      END
    END
  END;
  (* If reference and query are different lengths, count overhang as aligned
     (gap vs residue) so the denominator reflects the full alignment width. *)
  IF nr > n THEN
    FOR i := n TO nr - 1 DO
      a := BioSeq.Get(seqs[refIdx], i);
      IF ~IsGap(a) THEN INC(aligned) END
    END
  ELSIF nq > n THEN
    FOR i := n TO nq - 1 DO
      b := BioSeq.Get(seqs[qIdx], i);
      IF ~IsGap(b) THEN INC(aligned) END
    END
  END
END Compare;

PROCEDURE PrintPct(num, den: INTEGER);
  VAR pct: REAL;
BEGIN
  IF den = 0 THEN
    Out.String("NA")
  ELSE
    pct := 100.0 * FLT(num) / FLT(den);
    Out.Fixed(pct, 7, 2)
  END
END PrintPct;

PROCEDURE Report;
  VAR i, ident, simil, aligned: INTEGER;
BEGIN
  (* Header *)
  Out.String("query"); Out.Char(09X);
  Out.String("reference"); Out.Char(09X);
  Out.String("aligned_positions"); Out.Char(09X);
  Out.String("identical"); Out.Char(09X);
  Out.String("pct_identity");
  IF isProtein THEN
    Out.Char(09X);
    Out.String("similar"); Out.Char(09X);
    Out.String("pct_similarity")
  END;
  Out.Ln;

  FOR i := 1 TO nSeqs - 1 DO
    Compare(0, i, ident, simil, aligned);
    Out.String(names[i]); Out.Char(09X);
    Out.String(names[0]); Out.Char(09X);
    Out.Int(aligned); Out.Char(09X);
    Out.Int(ident); Out.Char(09X);
    PrintPct(ident, aligned);
    IF isProtein THEN
      Out.Char(09X);
      Out.Int(simil); Out.Char(09X);
      PrintPct(simil, aligned)
    END;
    Out.Ln
  END
END Report;

VAR
  path: ARRAY 1024 OF CHAR;
BEGIN
  IF Args.Count() < 1 THEN
    Out.String("Usage: msaidentity <alignment.fasta>"); Out.Ln;
    HALT(1)
  END;
  Args.Get(1, path);

  (* BLOSUM62 is used for protein similarity scoring. *)
  BioAlign.BLOSUM62(blosum);

  IF ~LoadAlignment(path) THEN HALT(1) END;
  IF nSeqs < 2 THEN
    Out.String("Need at least 2 sequences in the alignment."); Out.Ln;
    HALT(1)
  END;

  isProtein := DetectProtein();
  Report
END MSAIdentity.