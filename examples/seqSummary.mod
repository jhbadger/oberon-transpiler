MODULE SeqSummary;

IMPORT BioIO, BioSeq, Out, Args, Strings, OS, Files;

(* -----------------------------------------------------------------------
   Gzip strategy: if the file ends with ".gz", decompress to a temp file
   via "gunzip -c <src> > <tmp>", process the temp file, then delete it.
   This avoids any external library dependency while being transparent to
   the rest of the module.
   ----------------------------------------------------------------------- *)

CONST
  TmpPath = "/tmp/_fastastats_decomp.tmp";

TYPE
  FileFormat = INTEGER;   (* 0 = FASTA, 1 = FASTQ *)

VAR
  total_size:     INTEGER;
  num_sequences:  INTEGER;
  min_size:       INTEGER;
  max_size:       INTEGER;
  total_gc_count: INTEGER;
  min_gc_percent: REAL;
  max_gc_percent: REAL;
  is_nucl:        BOOLEAN;
  type_known:     BOOLEAN;

(* ---- helpers --------------------------------------------------------- *)

(* Detect format from file extension, ignoring a trailing ".gz". *)
PROCEDURE DetectFormat(fname: ARRAY OF CHAR): FileFormat;
VAR base: ARRAY 1024 OF CHAR; len: INTEGER;
BEGIN
  COPY(fname, base);
  len := Strings.Length(base);
  (* strip .gz *)
  IF Strings.EndsWith(base, ".gz") THEN
    base[len - 3] := 0X
  END;
  IF Strings.EndsWith(base, ".fastq") OR Strings.EndsWith(base, ".fq") THEN
    RETURN 1
  END;
  RETURN 0   (* default to FASTA *)
END DetectFormat;

(* Returns TRUE if fname ends with ".gz". *)
PROCEDURE IsGzipped(fname: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN Strings.EndsWith(fname, ".gz")
END IsGzipped;

(* Decompress fname to TmpPath. Returns TRUE on success. *)
PROCEDURE Decompress(fname: ARRAY OF CHAR): BOOLEAN;
VAR cmd: ARRAY 2048 OF CHAR; rc: INTEGER;
BEGIN
  COPY("gunzip -c ", cmd);
  Strings.Append(fname, cmd);
  Strings.Append(" > ", cmd);
  Strings.Append(TmpPath, cmd);
  rc := OS.Exec(cmd);
  RETURN rc = 0
END Decompress;

(* ---- stats accumulator ---------------------------------------------- *)

PROCEDURE UpdateStats(size, gc_count: INTEGER);
VAR pct: REAL;
BEGIN
  INC(total_size, size);
  INC(num_sequences);
  INC(total_gc_count, gc_count);
  IF num_sequences = 1 THEN
    min_size       := size;
    max_size       := size;
    min_gc_percent := 101.0;
    max_gc_percent := 0.0
  END;
  IF size < min_size THEN min_size := size END;
  IF size > max_size THEN max_size := size END;
  IF is_nucl & (size > 0) THEN
    pct := (FLT(gc_count) / FLT(size)) * 100.0;
    IF pct < min_gc_percent THEN min_gc_percent := pct END;
    IF pct > max_gc_percent THEN max_gc_percent := pct END
  END
END UpdateStats;

(* ---- per-sequence output --------------------------------------------- *)

CONST
  AminoAcids = "ACDEFGHIKLMNPQRSTVWY";  (* 20 standard, alpha order *)
  NumAA      = 20;

(* Per-sequence amino acid counts, accumulated across all sequences *)
VAR
  total_aa_count: ARRAY NumAA OF INTEGER;  (* global totals for summary *)

PROCEDURE AAIndex(c: CHAR): INTEGER;
(* Returns 0-based index into AminoAcids string, or -1 if not found. *)
VAR i: INTEGER;
BEGIN
  (* toupper *)
  IF (c >= 'a') & (c <= 'z') THEN c := CAP(c) END;
  i := 0;
  WHILE i < NumAA DO
    IF AminoAcids[i] = c THEN RETURN i END;
    INC(i)
  END;
  RETURN -1
END AAIndex;

PROCEDURE CountAA(seq: BioSeq.Seq; VAR counts: ARRAY OF INTEGER);
VAR i, idx, len: INTEGER; c: CHAR;
BEGIN
  FOR i := 0 TO NumAA - 1 DO counts[i] := 0 END;
  len := BioSeq.Length(seq);
  FOR i := 0 TO len - 1 DO
    c   := BioSeq.Get(seq, i);
    idx := AAIndex(c);
    IF idx >= 0 THEN INC(counts[idx]) END
  END
END CountAA;

PROCEDURE PrintHeader(nucl: BOOLEAN);
VAR i: INTEGER;
BEGIN
  Out.String("name"); Out.Char(9X);
  IF nucl THEN
    Out.String("length"); Out.Char(9X);
    Out.String("gc_percent")
  ELSE
    Out.String("residues");
    FOR i := 0 TO NumAA - 1 DO
      Out.Char(9X); Out.Char(AminoAcids[i]); Out.String("_pct")
    END
  END;
  Out.Ln
END PrintHeader;

PROCEDURE PrintSeqLine(name: ARRAY OF CHAR; size, gc_count: INTEGER;
                        VAR aa: ARRAY OF INTEGER);
VAR pct: REAL; i: INTEGER;
BEGIN
  Out.String(name); Out.Char(9X);
  Out.Int(size, 0);
  IF is_nucl THEN
    IF size > 0 THEN pct := (FLT(gc_count) / FLT(size)) * 100.0
    ELSE pct := 0.0 END;
    Out.Char(9X); Out.Fixed(pct, 0, 2)
  ELSE
    FOR i := 0 TO NumAA - 1 DO
      Out.Char(9X);
      IF size > 0 THEN pct := (FLT(aa[i]) / FLT(size)) * 100.0
      ELSE pct := 0.0 END;
      Out.Fixed(pct, 0, 2)
    END
  END;
  Out.Ln
END PrintSeqLine;

(* Called for each sequence regardless of format *)
PROCEDURE ProcessSeq(name: ARRAY OF CHAR; seq: BioSeq.Seq; summary: BOOLEAN);
VAR size, gc, i: INTEGER; aa: ARRAY NumAA OF INTEGER;
BEGIN
  IF ~type_known THEN
    is_nucl    := BioSeq.IsNucleotide(seq);
    type_known := TRUE;
    FOR i := 0 TO NumAA - 1 DO total_aa_count[i] := 0 END;
    IF ~summary THEN PrintHeader(is_nucl) END
  END;
  size := BioSeq.Length(seq);
  gc   := 0;
  IF is_nucl THEN
    gc := BioSeq.Count(seq, 'G') + BioSeq.Count(seq, 'C') +
          BioSeq.Count(seq, 'g') + BioSeq.Count(seq, 'c')
  ELSE
    CountAA(seq, aa);
    FOR i := 0 TO NumAA - 1 DO INC(total_aa_count[i], aa[i]) END
  END;
  UpdateStats(size, gc);
  IF ~summary THEN PrintSeqLine(name, size, gc, aa) END
END ProcessSeq;

(* ---- format-specific readers ---------------------------------------- *)

PROCEDURE ProcessFasta(path: ARRAY OF CHAR; summary: BOOLEAN);
VAR rdr: BioIO.FastaReader; rec: BioIO.FastaRecord;
BEGIN
  IF ~BioIO.OpenFasta(rdr, path) THEN
    Out.String("Error: cannot open FASTA: "); Out.String(path); Out.Ln;
    RETURN
  END;
  rec.seq := NIL;
  WHILE BioIO.ReadFasta(rdr, rec) DO
    ProcessSeq(rec.name, rec.seq, summary)
  END;
  BioIO.CloseFasta(rdr)
END ProcessFasta;

PROCEDURE ProcessFastq(path: ARRAY OF CHAR; summary: BOOLEAN);
VAR rdr: BioIO.FastqReader; rec: BioIO.FastqRecord;
BEGIN
  IF ~BioIO.OpenFastq(rdr, path) THEN
    Out.String("Error: cannot open FASTQ: "); Out.String(path); Out.Ln;
    RETURN
  END;
  rec.seq := NIL; rec.qual := NIL;
  WHILE BioIO.ReadFastq(rdr, rec) DO
    ProcessSeq(rec.name, rec.seq, summary)
  END;
  BioIO.CloseFastq(rdr)
END ProcessFastq;

(* ---- top-level dispatcher ------------------------------------------- *)

PROCEDURE ProcessFile(filename: ARRAY OF CHAR; summary: BOOLEAN);
VAR
  fmt:      FileFormat;
  workPath: ARRAY 1024 OF CHAR;
  gz:       BOOLEAN;
BEGIN
  (* reset global accumulators *)
  total_size := 0; num_sequences := 0;
  min_size := 1500000000; max_size := 0;
  total_gc_count := 0;
  min_gc_percent := 101.0; max_gc_percent := 0.0;
  type_known := FALSE;

  fmt := DetectFormat(filename);
  gz  := IsGzipped(filename);

  IF gz THEN
    IF ~Decompress(filename) THEN
      Out.String("Error: gunzip failed for: "); Out.String(filename); Out.Ln;
      RETURN
    END;
    COPY(TmpPath, workPath)
  ELSE
    COPY(filename, workPath)
  END;

  IF fmt = 1 THEN
    ProcessFastq(workPath, summary)
  ELSE
    ProcessFasta(workPath, summary)
  END;

  IF gz THEN Files.Delete(TmpPath) END
END ProcessFile;

(* ---- summary output -------------------------------------------------- *)

PROCEDURE OutputSummary();
VAR avg_size, avg_gc: REAL; unit: ARRAY 9 OF CHAR; i: INTEGER;
BEGIN
  IF num_sequences = 0 THEN
    Out.String("No sequences found."); Out.Ln;
    RETURN
  END;
  IF is_nucl THEN unit := "Bases" ELSE unit := "Residues" END;
  avg_size := FLT(total_size) / FLT(num_sequences);

  Out.String("=========================================="); Out.Ln;
  Out.String("FASTA/FASTQ File Analysis Statistics");     Out.Ln;
  Out.String("=========================================="); Out.Ln;
  Out.String("Total Sequences Processed: "); Out.Int(num_sequences, 0); Out.Ln;
  Out.String("Total "); Out.String(unit); Out.String(" Counted:      ");
  Out.Int(total_size, 0); Out.Ln;
  Out.String("------------------------------------------"); Out.Ln;
  Out.String("Sequence Length ("); Out.String(unit); Out.String("):"); Out.Ln;
  Out.String("  Average:  "); Out.Fixed(avg_size, 0, 2); Out.Ln;
  Out.String("  Minimum:  "); Out.Int(min_size, 0);      Out.Ln;
  Out.String("  Maximum:  "); Out.Int(max_size, 0);      Out.Ln;
  IF is_nucl THEN
    avg_gc := (FLT(total_gc_count) / FLT(total_size)) * 100.0;
    Out.Ln;
    Out.String("GC Content (%GC):"); Out.Ln;
    Out.String("  Average:  "); Out.Fixed(avg_gc, 0, 2);         Out.Ln;
    Out.String("  Minimum:  "); Out.Fixed(min_gc_percent, 0, 2); Out.Ln;
    Out.String("  Maximum:  "); Out.Fixed(max_gc_percent, 0, 2); Out.Ln
  ELSE
    Out.Ln;
    Out.String("Amino Acid Composition (% of total residues):"); Out.Ln;
    FOR i := 0 TO NumAA - 1 DO
      Out.String("  "); Out.Char(AminoAcids[i]); Out.String(":        ");
      Out.Fixed((FLT(total_aa_count[i]) / FLT(total_size)) * 100.0, 0, 2);
      Out.Ln
    END
  END
END OutputSummary;

(* ---- entry point ----------------------------------------------------- *)

VAR
  filename: ARRAY 1024 OF CHAR;
  arg:      ARRAY 64 OF CHAR;
  summary:  BOOLEAN;
  i:        INTEGER;
BEGIN
  summary  := FALSE;
  filename := "";
  i := 1;
  WHILE i <= Args.Count() DO
    Args.Get(i, arg);
    IF Strings.Compare(arg, "-t") = 0 THEN
      summary := TRUE
    ELSE
      COPY(arg, filename)
    END;
    INC(i)
  END;

  IF filename = "" THEN
    Out.String("Usage: seqSummary [-t] <file>"); Out.Ln;
    Out.String("  Accepts .fasta .fa .fastq .fq and .gz variants thereof"); Out.Ln;
    Out.String("  -t   print summary statistics instead of per-sequence TSV"); Out.Ln
  ELSE
    ProcessFile(filename, summary);
    IF summary THEN OutputSummary() END
  END
END SeqSummary.

