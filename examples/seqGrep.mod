MODULE SeqGrep;
(*
  SeqGrep — pattern search across FASTA/FASTQ files (plain or .gz).
  Accepts nucleotide or protein sequences.

  Usage:
    SeqGrep [options] <pattern> <file> [file2 ...]

  Options:
    -e <n>    maximum edit distance for approximate matching (default 0 = exact)
    -r        also search reverse complement (nucleotide only)
    -o bed    output format: bed  (default: tsv)
    -o fasta  output format: matching sequences as FASTA
    -o fastq  output format: matching sequences as FASTQ (FASTQ input only)
    -m        report only sequence names that have at least one hit (grep -l style)
    -v        invert: report sequences with NO hits
    -c        report count of hits per sequence instead of hit coordinates

  TSV output columns (default):
    file  seqname  hit_start(0-based)  hit_end(exclusive)  edit_dist  strand

  BED output columns:
    chrom  start  end  pattern  edit_dist  strand

  Strand is '+' for forward, '-' for reverse complement hits, '.' for protein.
*)

IMPORT BioIO, BioSeq, BioPattern, BioAlpha, Args, Strings, Out;

CONST
  MaxFiles   = 64;
  MaxPattern = 256;

  FmtTSV   = 0;
  FmtBED   = 1;
  FmtFASTA = 2;
  FmtFASTQ = 3;

  FileFASTA = 0;
  FileFASTQ = 1;

TYPE
  (* Collects all options parsed from argv *)
  Options = RECORD
    pattern  : ARRAY MaxPattern OF CHAR;
    maxDist  : INTEGER;
    revComp  : BOOLEAN;
    outFmt   : INTEGER;
    namesOnly: BOOLEAN;   (* -m *)
    invert   : BOOLEAN;   (* -v *)
    countOnly: BOOLEAN;   (* -c *)
  END;

(* -----------------------------------------------------------------------
   Utility: format detection
   ----------------------------------------------------------------------- *)

PROCEDURE DetectFormat(fname: ARRAY OF CHAR): INTEGER;
VAR base: ARRAY 1024 OF CHAR; len: INTEGER;
BEGIN
  COPY(fname, base);
  len := Strings.Length(base);
  IF Strings.EndsWith(base, ".gz") THEN base[len - 3] := 0X END;
  IF Strings.EndsWith(base, ".fastq") OR Strings.EndsWith(base, ".fq") THEN
    RETURN FileFASTQ
  END;
  RETURN FileFASTA
END DetectFormat;

(* -----------------------------------------------------------------------
   Nucleotide detection (same heuristic as FastaStats)
   ----------------------------------------------------------------------- *)

(* -----------------------------------------------------------------------
   Search helpers
   ----------------------------------------------------------------------- *)

(* Build BM or Ukkonen state once and reuse across sequences.
   For exact search we use Boyer-Moore (fast for long texts).
   For approximate search we use Ukkonen's bit-vector DP. *)

PROCEDURE SearchForward(VAR bm: BioPattern.BMState;
                         pat: ARRAY OF CHAR;
                         seq: BioSeq.Seq;
                         maxDist: INTEGER;
                         VAR hits: BioPattern.HitList);
BEGIN
  hits.count := 0;
  IF maxDist = 0 THEN
    BioPattern.BMSearch(bm, seq, hits)
  ELSE
    BioPattern.Ukkonen(pat, seq, maxDist, hits)
  END
END SearchForward;

(* -----------------------------------------------------------------------
   Output routines
   ----------------------------------------------------------------------- *)

PROCEDURE WriteTSVHit(fname, seqname: ARRAY OF CHAR;
                       start, end_, dist: INTEGER; strand: CHAR);
BEGIN
  Out.String(fname);   Out.Char(9X);
  Out.String(seqname); Out.Char(9X);
  Out.Int(start, 0);   Out.Char(9X);
  Out.Int(end_,  0);   Out.Char(9X);
  Out.Int(dist,  0);   Out.Char(9X);
  Out.Char(strand);
  Out.Ln
END WriteTSVHit;

PROCEDURE WriteBEDHit(seqname, pattern: ARRAY OF CHAR;
                       start, end_, dist: INTEGER; strand: CHAR);
BEGIN
  Out.String(seqname); Out.Char(9X);
  Out.Int(start, 0);   Out.Char(9X);
  Out.Int(end_,  0);   Out.Char(9X);
  Out.String(pattern); Out.Char(9X);
  Out.Int(dist,  0);   Out.Char(9X);
  Out.Char(strand);
  Out.Ln
END WriteBEDHit;

PROCEDURE WriteFASTASeq(name, desc: ARRAY OF CHAR; seq: BioSeq.Seq);
CONST Width = 60;
VAR buf: ARRAY 256 OF CHAR; pos, chunk, slen: INTEGER;
BEGIN
  Out.Char('>'); Out.String(name);
  IF desc[0] # 0X THEN Out.Char(' '); Out.String(desc) END;
  Out.Ln;
  slen := BioSeq.Length(seq);
  pos  := 0;
  WHILE pos < slen DO
    chunk := slen - pos;
    IF chunk > Width THEN chunk := Width END;
    BioSeq.Slice(seq, pos, chunk, buf);
    Out.String(buf); Out.Ln;
    INC(pos, chunk)
  END
END WriteFASTASeq;

PROCEDURE WriteFASTQSeq(name: ARRAY OF CHAR; seq, qual: BioSeq.Seq);
CONST BufSz = 256;
VAR buf: ARRAY BufSz OF CHAR; pos, chunk, slen: INTEGER;
BEGIN
  Out.Char('@'); Out.String(name); Out.Ln;
  (* sequence — may be longer than one buffer *)
  slen := BioSeq.Length(seq); pos := 0;
  WHILE pos < slen DO
    chunk := slen - pos;
    IF chunk > BufSz - 1 THEN chunk := BufSz - 1 END;
    BioSeq.Slice(seq, pos, chunk, buf);
    Out.String(buf);
    INC(pos, chunk)
  END;
  Out.Ln;
  Out.String("+"); Out.Ln;
  slen := BioSeq.Length(qual); pos := 0;
  WHILE pos < slen DO
    chunk := slen - pos;
    IF chunk > BufSz - 1 THEN chunk := BufSz - 1 END;
    BioSeq.Slice(qual, pos, chunk, buf);
    Out.String(buf);
    INC(pos, chunk)
  END;
  Out.Ln
END WriteFASTQSeq;

(* -----------------------------------------------------------------------
   Per-sequence processing
   ----------------------------------------------------------------------- *)

PROCEDURE ProcessSeq(fname, seqname, desc: ARRAY OF CHAR;
                      seq, qual: BioSeq.Seq;   (* qual may be NIL *)
                      isNucl: BOOLEAN;
                      VAR bm: BioPattern.BMState;
                      VAR opt: Options;
                      VAR typeKnown: BOOLEAN);
VAR
  fwdHits, rcHits: BioPattern.HitList;
  rcSeq:           BioSeq.Seq;
  alpha:           BioAlpha.Alphabet;
  totalHits:       INTEGER;
  i:               INTEGER;
  hasHit:          BOOLEAN;
  strand:          CHAR;
  patLen:          INTEGER;
BEGIN
  patLen := Strings.Length(opt.pattern);

  (* forward search *)
  SearchForward(bm, opt.pattern, seq, opt.maxDist, fwdHits);

  (* reverse complement — nucleotide only and only when requested *)
  rcHits.count := 0;
  IF isNucl & opt.revComp THEN
    BioAlpha.DNA(alpha);
    BioSeq.New(rcSeq);
    BioSeq.RevComp(seq, alpha, rcSeq);
    SearchForward(bm, opt.pattern, rcSeq, opt.maxDist, rcHits);
    (* convert RC positions back to forward-strand coordinates:
       rc_pos -> (seqLen - rc_pos - patLen)  *)
    FOR i := 0 TO rcHits.count - 1 DO
      rcHits.hits[i].pos :=
        BioSeq.Length(seq) - rcHits.hits[i].pos - patLen
    END;
    BioSeq.Free(rcSeq)
  END;

  totalHits := fwdHits.count + rcHits.count;
  hasHit    := totalHits > 0;

  (* invert logic *)
  IF opt.invert THEN
    IF hasHit THEN RETURN END;   (* skip sequences WITH hits *)
    (* for -v we emit the whole sequence with no coordinate lines *)
    IF opt.outFmt = FmtFASTA THEN
      WriteFASTASeq(seqname, desc, seq)
    ELSIF opt.outFmt = FmtFASTQ THEN
      WriteFASTQSeq(seqname, seq, qual)
    ELSE
      (* TSV/BED: emit one line per sequence with a sentinel 0-hit entry *)
      IF opt.outFmt = FmtBED THEN
        WriteBEDHit(seqname, opt.pattern, 0, 0, 0, '.')
      ELSE
        WriteTSVHit(fname, seqname, 0, 0, 0, '.')
      END
    END;
    RETURN
  END;

  IF ~hasHit THEN RETURN END;

  (* -m: names only *)
  IF opt.namesOnly THEN
    Out.String(seqname); Out.Ln;
    RETURN
  END;

  (* -c: count only *)
  IF opt.countOnly THEN
    Out.String(fname);   Out.Char(9X);
    Out.String(seqname); Out.Char(9X);
    Out.Int(totalHits, 0); Out.Ln;
    RETURN
  END;

  (* full output *)
  IF opt.outFmt = FmtFASTA THEN
    WriteFASTASeq(seqname, desc, seq);
    RETURN
  END;
  IF opt.outFmt = FmtFASTQ THEN
    WriteFASTQSeq(seqname, seq, qual);
    RETURN
  END;

  (* TSV or BED: emit one line per hit *)
  IF isNucl THEN strand := '+' ELSE strand := '.' END;

  FOR i := 0 TO fwdHits.count - 1 DO
    IF opt.outFmt = FmtBED THEN
      WriteBEDHit(seqname, opt.pattern,
                  fwdHits.hits[i].pos,
                  fwdHits.hits[i].pos + fwdHits.hits[i].len,
                  fwdHits.hits[i].dist, strand)
    ELSE
      WriteTSVHit(fname, seqname,
                  fwdHits.hits[i].pos,
                  fwdHits.hits[i].pos + fwdHits.hits[i].len,
                  fwdHits.hits[i].dist, strand)
    END
  END;

  FOR i := 0 TO rcHits.count - 1 DO
    IF opt.outFmt = FmtBED THEN
      WriteBEDHit(seqname, opt.pattern,
                  rcHits.hits[i].pos,
                  rcHits.hits[i].pos + patLen,
                  rcHits.hits[i].dist, '-')
    ELSE
      WriteTSVHit(fname, seqname,
                  rcHits.hits[i].pos,
                  rcHits.hits[i].pos + patLen,
                  rcHits.hits[i].dist, '-')
    END
  END
END ProcessSeq;

(* -----------------------------------------------------------------------
   File-level drivers
   ----------------------------------------------------------------------- *)

PROCEDURE RunFasta(workPath, origName: ARRAY OF CHAR;
                   VAR bm: BioPattern.BMState;
                   VAR opt: Options);
VAR
  rdr:       BioIO.FastaReader;
  rec:       BioIO.FastaRecord;
  isNucl:    BOOLEAN;
  typeKnown: BOOLEAN;
BEGIN
  typeKnown := FALSE;
  IF ~BioIO.OpenFasta(rdr, workPath) THEN
    Out.String("Error: cannot open FASTA: "); Out.String(origName); Out.Ln;
    RETURN
  END;
  rec.seq := NIL;
  WHILE BioIO.ReadFasta(rdr, rec) DO
    IF ~typeKnown THEN
      isNucl    := BioSeq.IsNucleotide(rec.seq);
      typeKnown := TRUE
    END;
    ProcessSeq(origName, rec.name, rec.desc, rec.seq, NIL,
               isNucl, bm, opt, typeKnown)
  END;
  BioIO.CloseFasta(rdr)
END RunFasta;

PROCEDURE RunFastq(workPath, origName: ARRAY OF CHAR;
                   VAR bm: BioPattern.BMState;
                   VAR opt: Options);
VAR
  rdr:       BioIO.FastqReader;
  rec:       BioIO.FastqRecord;
  isNucl:    BOOLEAN;
  typeKnown: BOOLEAN;
BEGIN
  typeKnown := FALSE;
  IF ~BioIO.OpenFastq(rdr, workPath) THEN
    Out.String("Error: cannot open FASTQ: "); Out.String(origName); Out.Ln;
    RETURN
  END;
  rec.seq := NIL; rec.qual := NIL;
  WHILE BioIO.ReadFastq(rdr, rec) DO
    IF ~typeKnown THEN
      isNucl    := BioSeq.IsNucleotide(rec.seq);
      typeKnown := TRUE
    END;
    ProcessSeq(origName, rec.name, "", rec.seq, rec.qual,
               isNucl, bm, opt, typeKnown)
  END;
  BioIO.CloseFastq(rdr)
END RunFastq;

PROCEDURE ProcessFile(fname: ARRAY OF CHAR;
                      VAR bm: BioPattern.BMState;
                      VAR opt: Options);
VAR fmt: INTEGER;
BEGIN
  fmt := DetectFormat(fname);
  IF fmt = FileFASTQ THEN
    RunFastq(fname, fname, bm, opt)
  ELSE
    RunFasta(fname, fname, bm, opt)
  END
END ProcessFile;

(* -----------------------------------------------------------------------
   TSV header
   ----------------------------------------------------------------------- *)

PROCEDURE PrintTSVHeader();
BEGIN
  Out.String("file"); Out.Char(9X);
  Out.String("seqname"); Out.Char(9X);
  Out.String("start"); Out.Char(9X);
  Out.String("end"); Out.Char(9X);
  Out.String("edit_dist"); Out.Char(9X);
  Out.String("strand"); Out.Ln
END PrintTSVHeader;

(* -----------------------------------------------------------------------
   Argument parsing
   ----------------------------------------------------------------------- *)

PROCEDURE PrintUsage();
BEGIN
  Out.String("Usage: SeqGrep [options] <pattern> <file> [file2 ...]"); Out.Ln;
  Out.Ln;
  Out.String("Options:"); Out.Ln;
  Out.String("  -e <n>   max edit distance for approximate match (default 0)"); Out.Ln;
  Out.String("  -r       also search reverse complement (nucleotide only)"); Out.Ln;
  Out.String("  -o bed   output as BED (default: TSV)"); Out.Ln;
  Out.String("  -o fasta output matching sequences as FASTA"); Out.Ln;
  Out.String("  -o fastq output matching sequences as FASTQ"); Out.Ln;
  Out.String("  -m       print only names of sequences with hits"); Out.Ln;
  Out.String("  -v       invert: sequences with NO hits"); Out.Ln;
  Out.String("  -c       count hits per sequence (TSV: file, name, count)"); Out.Ln
END PrintUsage;

VAR
  opt:      Options;
  bm:       BioPattern.BMState;
  files:    ARRAY MaxFiles OF ARRAY 1024 OF CHAR;
  nFiles:   INTEGER;
  arg, tmp: ARRAY 1024 OF CHAR;
  i:        INTEGER;
  patSet:   BOOLEAN;
BEGIN
  (* defaults *)
  opt.pattern   := "";
  opt.maxDist   := 0;
  opt.revComp   := FALSE;
  opt.outFmt    := FmtTSV;
  opt.namesOnly := FALSE;
  opt.invert    := FALSE;
  opt.countOnly := FALSE;
  nFiles        := 0;
  patSet        := FALSE;

  i := 1;
  WHILE i <= Args.Count() DO
    Args.Get(i, arg);
    IF Strings.Compare(arg, "-e") = 0 THEN
      INC(i);
      IF i <= Args.Count() THEN
        Args.Get(i, tmp);
        IF ~Strings.StrToInt(tmp, opt.maxDist) THEN opt.maxDist := 0 END
      END
    ELSIF Strings.Compare(arg, "-r") = 0 THEN
      opt.revComp := TRUE
    ELSIF Strings.Compare(arg, "-m") = 0 THEN
      opt.namesOnly := TRUE
    ELSIF Strings.Compare(arg, "-v") = 0 THEN
      opt.invert := TRUE
    ELSIF Strings.Compare(arg, "-c") = 0 THEN
      opt.countOnly := TRUE
    ELSIF Strings.Compare(arg, "-o") = 0 THEN
      INC(i);
      IF i <= Args.Count() THEN
        Args.Get(i, tmp);
        IF Strings.Compare(tmp, "bed") = 0 THEN
          opt.outFmt := FmtBED
        ELSIF Strings.Compare(tmp, "fasta") = 0 THEN
          opt.outFmt := FmtFASTA
        ELSIF Strings.Compare(tmp, "fastq") = 0 THEN
          opt.outFmt := FmtFASTQ
        END
      END
    ELSIF ~patSet THEN
      COPY(arg, opt.pattern);
      patSet := TRUE
    ELSE
      IF nFiles < MaxFiles THEN
        COPY(arg, files[nFiles]);
        INC(nFiles)
      END
    END;
    INC(i)
  END;

  IF ~patSet OR (nFiles = 0) THEN
    PrintUsage();
    HALT(1)
  END;

  (* uppercase the pattern so it matches both cases in sequences;
     BioSeq.ToUpper handles the sequence side *)
  Strings.ToUpper(opt.pattern);

  (* precompute Boyer-Moore tables once for the pattern *)
  BioPattern.BMBuild(bm, opt.pattern);

  IF opt.outFmt = FmtTSV THEN PrintTSVHeader() END;

  FOR i := 0 TO nFiles - 1 DO
    ProcessFile(files[i], bm, opt)
  END
END SeqGrep.
