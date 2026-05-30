MODULE DeBruijn;
(*
  DeBruijn — simple de Bruijn graph assembler for short reads.

  Usage: DeBruijn [-k <ksize>] [-m <minlen>] [-c <mincov>] <file.[fastq|fq|fasta|fa][.gz]>

  Reads FASTQ (or FASTA) input, plain or gzip-compressed.
  Builds a de Bruijn graph from k-mers and outputs assembled contigs
  as FASTA to stdout.

  Defaults: k=31, minlen=200, mincov=1 (no filter), rc=on.

  For real sequencing data use -c 2 or -c 3 to discard error-derived k-mers
  (sequencing errors create many unique k-mers each seen only once).  With
  -c > 1 the assembler does two passes: the first counts k-mers into a
  compact hash table; the second builds the graph only for k-mers that meet
  the threshold.  This keeps the graph small regardless of error rate.

  The -norc flag disables adding the reverse complement of each read.  Use it
  when the input already contains reads from both strands (e.g. reads_1.fastq
  from wgsim, or a combined paired-end file where each genomic position is
  covered in both orientations).  Without -norc the graph is doubled: every
  k-mer AND its RC are added, producing two parallel paths through the genome
  and roughly 2x more contigs than necessary.

  MaxNodes/MaxEdges/HashSize control memory.  At -c 2 the current values
  handle genomes up to ~250 kb at typical Illumina coverage.  Recompile with
  larger values for bigger genomes.
*)

IMPORT BioIO, BioSeq, BioAlpha, Out, Args, Strings, OS, Files;

CONST
  MaxK     = 31;        (* maximum supported k-mer size *)
  HashSize = 1048576;   (* 2^20, open-addressing hash tables for the graph *)
  MaxNodes = 500000;    (* max unique (k-1)-mers in the graph *)
  MaxEdges = 600000;    (* max unique k-mers in the graph *)
  MaxOut   = 4;         (* at most 4 out-edges per node (A/C/G/T) *)
  CntSize  = 1048576;   (* 2^20, k-mer count table for -c filter pass *)
  TmpPath  = "/tmp/_debruijn.tmp";
  LineWid  = 60;        (* FASTA output line width *)

TYPE
  NodeRec = RECORD
    kmer     : ARRAY MaxK OF CHAR;          (* (k-1)-mer, null-terminated *)
    inDeg    : INTEGER;
    outEdge  : ARRAY MaxOut OF INTEGER;     (* indices into edges[] *)
    outCount : INTEGER
  END;
  EdgeRec = RECORD
    from  : INTEGER;
    to    : INTEGER;
    count : INTEGER;
    used  : BOOLEAN
  END;

VAR
  nodes    : ARRAY MaxNodes OF NodeRec;
  nNodes   : INTEGER;
  edges    : ARRAY MaxEdges OF EdgeRec;
  nEdges   : INTEGER;
  nodeHash : ARRAY HashSize OF INTEGER;     (* -1 = empty *)
  edgeHash : ARRAY HashSize OF INTEGER;     (* -1 = empty *)
  cntTable : ARRAY CntSize  OF INTEGER;     (* k-mer count filter *)
  K        : INTEGER;
  KM1      : INTEGER;    (* K - 1 *)
  minLen   : INTEGER;
  minCov   : INTEGER;
  noRC     : BOOLEAN;    (* -norc: don't add RC of each read *)
  contigNum: INTEGER;
  overflow : BOOLEAN;
  alpha    : BioAlpha.Alphabet;
  fname    : ARRAY 1024 OF CHAR;
  arg      : ARRAY 1024 OF CHAR;
  tmp      : ARRAY 64 OF CHAR;
  mi       : INTEGER;

(* ------------------------------------------------------------------ *)
(*  File helpers                                                        *)
(* ------------------------------------------------------------------ *)

PROCEDURE IsGzipped(f: ARRAY OF CHAR): BOOLEAN;
BEGIN RETURN Strings.EndsWith(f, ".gz") END IsGzipped;

PROCEDURE IsFastq(f: ARRAY OF CHAR): BOOLEAN;
VAR base: ARRAY 1024 OF CHAR; len: INTEGER;
BEGIN
  COPY(f, base);
  len := Strings.Length(base);
  IF Strings.EndsWith(base, ".gz") THEN base[len - 3] := 0X END;
  RETURN Strings.EndsWith(base, ".fastq") OR Strings.EndsWith(base, ".fq")
END IsFastq;

PROCEDURE Decompress(f: ARRAY OF CHAR): BOOLEAN;
VAR cmd: ARRAY 2048 OF CHAR;
BEGIN
  COPY("gunzip -c ", cmd);
  Strings.Append(f, cmd);
  Strings.Append(" > ", cmd);
  Strings.Append(TmpPath, cmd);
  RETURN OS.Exec(cmd) = 0
END Decompress;

(* ------------------------------------------------------------------ *)
(*  Hash functions                                                      *)
(* ------------------------------------------------------------------ *)

PROCEDURE StrHash(s: ARRAY OF CHAR; len: INTEGER): INTEGER;
VAR h, i: INTEGER;
BEGIN
  h := 0;
  FOR i := 0 TO len - 1 DO
    h := (h * 31 + ORD(s[i])) MOD HashSize
  END;
  RETURN h
END StrHash;

PROCEDURE PairHash(a, b: INTEGER): INTEGER;
VAR h: INTEGER;
BEGIN
  h := ((a MOD HashSize) * 997 + b) MOD HashSize;
  IF h < 0 THEN h := -h MOD HashSize END;
  RETURN h
END PairHash;

(* Separate hash for the count table — different multiplier reduces the
   chance that a count-table collision causes a graph-table false positive. *)
PROCEDURE CntHash(buf: ARRAY OF CHAR): INTEGER;
VAR h, i: INTEGER;
BEGIN
  h := 0;
  FOR i := 0 TO K - 1 DO
    h := (h * 37 + ORD(buf[i])) MOD CntSize
  END;
  RETURN h
END CntHash;

(* ------------------------------------------------------------------ *)
(*  Graph node operations                                               *)
(* ------------------------------------------------------------------ *)

PROCEDURE FindNode(kmer: ARRAY OF CHAR): INTEGER;
VAR h, idx: INTEGER;
BEGIN
  h := StrHash(kmer, KM1);
  WHILE nodeHash[h] >= 0 DO
    idx := nodeHash[h];
    IF Strings.Compare(nodes[idx].kmer, kmer) = 0 THEN RETURN idx END;
    h := (h + 1) MOD HashSize
  END;
  RETURN -1
END FindNode;

PROCEDURE AddNode(kmer: ARRAY OF CHAR): INTEGER;
VAR h, idx: INTEGER;
BEGIN
  IF nNodes >= MaxNodes THEN overflow := TRUE; RETURN -1 END;
  idx := nNodes;
  COPY(kmer, nodes[idx].kmer);
  nodes[idx].inDeg    := 0;
  nodes[idx].outCount := 0;
  INC(nNodes);
  h := StrHash(kmer, KM1);
  WHILE nodeHash[h] >= 0 DO h := (h + 1) MOD HashSize END;
  nodeHash[h] := idx;
  RETURN idx
END AddNode;

PROCEDURE GetNode(kmer: ARRAY OF CHAR): INTEGER;
VAR idx: INTEGER;
BEGIN
  idx := FindNode(kmer);
  IF idx < 0 THEN idx := AddNode(kmer) END;
  RETURN idx
END GetNode;

(* ------------------------------------------------------------------ *)
(*  Graph edge operations                                               *)
(* ------------------------------------------------------------------ *)

PROCEDURE FindEdge(from, to: INTEGER): INTEGER;
VAR h, idx: INTEGER;
BEGIN
  h := PairHash(from, to);
  WHILE edgeHash[h] >= 0 DO
    idx := edgeHash[h];
    IF (edges[idx].from = from) & (edges[idx].to = to) THEN RETURN idx END;
    h := (h + 1) MOD HashSize
  END;
  RETURN -1
END FindEdge;

PROCEDURE AddEdge(from, to: INTEGER): INTEGER;
VAR h, idx: INTEGER;
BEGIN
  IF nEdges >= MaxEdges THEN overflow := TRUE; RETURN -1 END;
  idx := nEdges;
  edges[idx].from  := from;
  edges[idx].to    := to;
  edges[idx].count := 0;
  edges[idx].used  := FALSE;
  INC(nEdges);
  h := PairHash(from, to);
  WHILE edgeHash[h] >= 0 DO h := (h + 1) MOD HashSize END;
  edgeHash[h] := idx;
  IF nodes[from].outCount < MaxOut THEN
    nodes[from].outEdge[nodes[from].outCount] := idx;
    INC(nodes[from].outCount)
  END;
  INC(nodes[to].inDeg);
  RETURN idx
END AddEdge;

(* ------------------------------------------------------------------ *)
(*  Pass 1 — count k-mers into cntTable                                *)
(* ------------------------------------------------------------------ *)

PROCEDURE CountKmer(buf: ARRAY OF CHAR);
BEGIN INC(cntTable[CntHash(buf)]) END CountKmer;

PROCEDURE CountRead(seq: BioSeq.Seq);
VAR buf: ARRAY MaxK + 1 OF CHAR; rc: BioSeq.Seq; slen, i: INTEGER;
BEGIN
  slen := BioSeq.Length(seq);
  FOR i := 0 TO slen - K DO BioSeq.Slice(seq, i, K, buf); CountKmer(buf) END;
  IF ~noRC THEN
    BioSeq.New(rc);
    BioSeq.RevComp(seq, alpha, rc);
    FOR i := 0 TO slen - K DO BioSeq.Slice(rc, i, K, buf); CountKmer(buf) END;
    BioSeq.Free(rc)
  END
END CountRead;

PROCEDURE CountFastq(path: ARRAY OF CHAR);
VAR rdr: BioIO.FastqReader; rec: BioIO.FastqRecord;
BEGIN
  rec.seq := NIL; rec.qual := NIL;
  IF ~BioIO.OpenFastq(rdr, path) THEN RETURN END;
  WHILE BioIO.ReadFastq(rdr, rec) DO
    BioSeq.ToUpper(rec.seq); CountRead(rec.seq)
  END;
  BioIO.CloseFastq(rdr)
END CountFastq;

PROCEDURE CountFasta(path: ARRAY OF CHAR);
VAR rdr: BioIO.FastaReader; rec: BioIO.FastaRecord;
BEGIN
  rec.seq := NIL;
  IF ~BioIO.OpenFasta(rdr, path) THEN RETURN END;
  WHILE BioIO.ReadFasta(rdr, rec) DO
    BioSeq.ToUpper(rec.seq); CountRead(rec.seq)
  END;
  BioIO.CloseFasta(rdr)
END CountFasta;

(* ------------------------------------------------------------------ *)
(*  Pass 2 — build graph (filtered by cntTable when minCov > 1)        *)
(* ------------------------------------------------------------------ *)

PROCEDURE AddKmer(buf: ARRAY OF CHAR);
VAR left, right: ARRAY MaxK OF CHAR; fn, tn, ei, i: INTEGER;
BEGIN
  IF (minCov > 1) & (cntTable[CntHash(buf)] < minCov) THEN RETURN END;

  FOR i := 0 TO KM1 - 1 DO left[i]  := buf[i]     END;
  FOR i := 0 TO KM1 - 1 DO right[i] := buf[i + 1] END;
  left[KM1]  := 0X;
  right[KM1] := 0X;

  fn := GetNode(left);
  tn := GetNode(right);
  IF (fn < 0) OR (tn < 0) THEN RETURN END;

  ei := FindEdge(fn, tn);
  IF ei < 0 THEN
    ei := AddEdge(fn, tn);
    IF ei < 0 THEN RETURN END
  END;
  INC(edges[ei].count)
END AddKmer;

PROCEDURE ProcessRead(seq: BioSeq.Seq);
VAR buf: ARRAY MaxK + 1 OF CHAR; rc: BioSeq.Seq; slen, i: INTEGER;
BEGIN
  slen := BioSeq.Length(seq);
  FOR i := 0 TO slen - K DO BioSeq.Slice(seq, i, K, buf); AddKmer(buf) END;
  IF ~noRC THEN
    BioSeq.New(rc);
    BioSeq.RevComp(seq, alpha, rc);
    FOR i := 0 TO slen - K DO BioSeq.Slice(rc, i, K, buf); AddKmer(buf) END;
    BioSeq.Free(rc)
  END
END ProcessRead;

PROCEDURE RunFastq(path: ARRAY OF CHAR);
VAR rdr: BioIO.FastqReader; rec: BioIO.FastqRecord;
BEGIN
  rec.seq := NIL; rec.qual := NIL;
  IF ~BioIO.OpenFastq(rdr, path) THEN
    Out.String("Error: cannot open FASTQ: "); Out.String(path); Out.Ln;
    RETURN
  END;
  WHILE BioIO.ReadFastq(rdr, rec) DO
    BioSeq.ToUpper(rec.seq); ProcessRead(rec.seq)
  END;
  BioIO.CloseFastq(rdr)
END RunFastq;

PROCEDURE RunFasta(path: ARRAY OF CHAR);
VAR rdr: BioIO.FastaReader; rec: BioIO.FastaRecord;
BEGIN
  rec.seq := NIL;
  IF ~BioIO.OpenFasta(rdr, path) THEN
    Out.String("Error: cannot open FASTA: "); Out.String(path); Out.Ln;
    RETURN
  END;
  WHILE BioIO.ReadFasta(rdr, rec) DO
    BioSeq.ToUpper(rec.seq); ProcessRead(rec.seq)
  END;
  BioIO.CloseFasta(rdr)
END RunFasta;

(* ------------------------------------------------------------------ *)
(*  Contig traversal                                                    *)
(* ------------------------------------------------------------------ *)

PROCEDURE BestEdge(n: INTEGER): INTEGER;
VAR i, best, bestCnt, ei: INTEGER;
BEGIN
  best := -1; bestCnt := 0;
  FOR i := 0 TO nodes[n].outCount - 1 DO
    ei := nodes[n].outEdge[i];
    IF ~edges[ei].used & (edges[ei].count > bestCnt) THEN
      best := ei; bestCnt := edges[ei].count
    END
  END;
  RETURN best
END BestEdge;

PROCEDURE HasUnused(n: INTEGER): BOOLEAN;
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO nodes[n].outCount - 1 DO
    IF ~edges[nodes[n].outEdge[i]].used THEN RETURN TRUE END
  END;
  RETURN FALSE
END HasUnused;

PROCEDURE EmitContig(contig: BioSeq.Seq);
VAR buf: ARRAY LineWid + 1 OF CHAR; pos, chunk, clen: INTEGER;
BEGIN
  INC(contigNum);
  Out.Char('>'); Out.String("contig_"); Out.Int(contigNum, 0);
  Out.String(" len="); Out.Int(BioSeq.Length(contig), 0);
  Out.Ln;
  clen := BioSeq.Length(contig);
  pos  := 0;
  WHILE pos < clen DO
    chunk := clen - pos;
    IF chunk > LineWid THEN chunk := LineWid END;
    BioSeq.Slice(contig, pos, chunk, buf);
    Out.String(buf); Out.Ln;
    INC(pos, chunk)
  END
END EmitContig;

PROCEDURE ExtendContig(start: INTEGER);
VAR contig: BioSeq.Seq; cur, ei: INTEGER; cb: ARRAY 2 OF CHAR;
BEGIN
  BioSeq.New(contig);
  BioSeq.Append(contig, nodes[start].kmer, KM1);
  cur := start;
  LOOP
    ei := BestEdge(cur);
    IF ei < 0 THEN EXIT END;
    edges[ei].used := TRUE;
    cur := edges[ei].to;
    cb[0] := nodes[cur].kmer[KM1 - 1];
    cb[1] := 0X;
    BioSeq.Append(contig, cb, 1)
  END;
  IF BioSeq.Length(contig) >= minLen THEN EmitContig(contig) END;
  BioSeq.Free(contig)
END ExtendContig;

PROCEDURE TraverseGraph();
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO nNodes - 1 DO
    IF (nodes[i].inDeg = 0) & HasUnused(i) THEN ExtendContig(i) END
  END;
  FOR i := 0 TO nNodes - 1 DO
    IF HasUnused(i) THEN ExtendContig(i) END
  END
END TraverseGraph;

(* ------------------------------------------------------------------ *)
(*  Initialise tables                                                   *)
(* ------------------------------------------------------------------ *)

PROCEDURE InitGraph();
VAR i: INTEGER;
BEGIN
  nNodes := 0; nEdges := 0; contigNum := 0; overflow := FALSE;
  FOR i := 0 TO HashSize - 1 DO nodeHash[i] := -1; edgeHash[i] := -1 END
END InitGraph;

PROCEDURE InitCntTable();
VAR i: INTEGER;
BEGIN FOR i := 0 TO CntSize - 1 DO cntTable[i] := 0 END END InitCntTable;

(* ------------------------------------------------------------------ *)
(*  Top-level: orchestrate one or two passes over the input file        *)
(* ------------------------------------------------------------------ *)

PROCEDURE Run(f: ARRAY OF CHAR);
VAR workPath: ARRAY 1024 OF CHAR; gz, fq: BOOLEAN;
BEGIN
  gz := IsGzipped(f);
  fq := IsFastq(f);
  IF gz THEN
    IF ~Decompress(f) THEN
      Out.String("Error: gunzip failed for: "); Out.String(f); Out.Ln;
      RETURN
    END;
    COPY(TmpPath, workPath)
  ELSE
    COPY(f, workPath)
  END;

  IF minCov > 1 THEN
    (* Pass 1: fill count table *)
    InitCntTable();
    IF fq THEN CountFastq(workPath) ELSE CountFasta(workPath) END
  END;

  (* Pass 2 (or only pass when minCov = 1): build graph *)
  IF fq THEN RunFastq(workPath) ELSE RunFasta(workPath) END;

  IF gz THEN Files.Delete(TmpPath) END
END Run;

(* ------------------------------------------------------------------ *)
(*  Entry point                                                         *)
(* ------------------------------------------------------------------ *)

BEGIN
  K := 31; minLen := 200; minCov := 1; noRC := FALSE;
  fname := "";
  BioAlpha.DNA(alpha);

  mi := 1;
  WHILE mi <= Args.Count() DO
    Args.Get(mi, arg);
    IF Strings.Compare(arg, "-k") = 0 THEN
      INC(mi);
      IF mi <= Args.Count() THEN
        Args.Get(mi, tmp);
        IF ~Strings.StrToInt(tmp, K) THEN K := 31 END;
        IF K < 3    THEN K := 3    END;
        IF K > MaxK THEN K := MaxK END
      END
    ELSIF Strings.Compare(arg, "-m") = 0 THEN
      INC(mi);
      IF mi <= Args.Count() THEN
        Args.Get(mi, tmp);
        IF ~Strings.StrToInt(tmp, minLen) THEN minLen := 200 END;
        IF minLen < 1 THEN minLen := 1 END
      END
    ELSIF Strings.Compare(arg, "-c") = 0 THEN
      INC(mi);
      IF mi <= Args.Count() THEN
        Args.Get(mi, tmp);
        IF ~Strings.StrToInt(tmp, minCov) THEN minCov := 1 END;
        IF minCov < 1 THEN minCov := 1 END
      END
    ELSIF Strings.Compare(arg, "-norc") = 0 THEN
      noRC := TRUE
    ELSE
      COPY(arg, fname)
    END;
    INC(mi)
  END;

  IF fname = "" THEN
    Out.String("Usage: DeBruijn [-k <ksize>] [-m <minlen>] [-c <mincov>] <reads.[fastq|fq|fasta|fa][.gz]>"); Out.Ln;
    Out.String("  -k  k-mer size (3.."); Out.Int(MaxK, 0); Out.String(", default 31)"); Out.Ln;
    Out.String("  -m  minimum contig output length (default 200)"); Out.Ln;
    Out.String("  -c     minimum k-mer coverage to include (default 1; use 2-3 for real reads)"); Out.Ln;
    Out.String("  -norc  do not add reverse complement of each read"); Out.Ln;
    Out.String("         use with reads_1.fastq alone to avoid doubling the graph"); Out.Ln;
    HALT(1)
  END;

  KM1 := K - 1;
  InitGraph();
  Run(fname);

  IF overflow THEN
    Out.String("Warning: graph capacity exceeded (MaxNodes=");
    Out.Int(MaxNodes, 0); Out.String(", MaxEdges=");
    Out.Int(MaxEdges, 0); Out.String(")."); Out.Ln
  END;

  TraverseGraph()
END DeBruijn.
