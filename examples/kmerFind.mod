MODULE KmerFind;
(*
  KmerFind — Find k-mers that discriminate a target taxonomic group from
  the rest of a FASTA database.  Performance-optimized version.

  Optimizations vs the original:
    * 256-byte lookup table for base encoding (single load, no CASE dispatch).
    * Per-sequence dedup uses a stack array + quicksort instead of a hash
      table (eliminates ~3 hash calls per k-mer in the hot loop).
    * Better mixing hash function (xorshift-style multiply-fold-multiply).
    * Load-factor bounded, growable hash tables (no more silent overflows).
    * Position-tracking branch hoisted out of the inner loop.
    * Table capacity kept as power-of-two so slot lookup uses MOD by a
      power of two, which C backends strength-reduce to bitwise AND.

  Note on bitwise ops: this compiler's LSL/ASR/ROR are INTEGER (32-bit)
  only, but k-mers require LONGINT.  We use LONGINT arithmetic with
  non-negative operands throughout; the C backend strength-reduces
  DIV/MOD by power-of-two constants to shifts on unsigned/positive
  values.  Keeping fwd/rev non-negative is what makes this work.
*)

IMPORT BioIO, BioSeq, Args, Strings, Out, Math, Parallel;

CONST
  MaxK          = 32;
  MaxSeqs       = 400000;
  MaxSeqLen     = 5000;
  MaxWorkers    = 64;
  InitCap       = 4096;
  MaxTopReport  = 1000;
  EmptyKey      = -1;
  MaxKmersPerSeq = MaxSeqLen;

TYPE
  HashTable = POINTER TO HashTableRec;
  HashTableRec = RECORD
    keys    : POINTER TO ARRAY OF LONGINT;
    counts  : POINTER TO ARRAY OF INTEGER;
    posSum  : POINTER TO ARRAY OF LONGINT;
    cap     : INTEGER;   (* power of two *)
    capL    : LONGINT;   (* cap as LONGINT for MOD *)
    used    : INTEGER;
    hasPos  : BOOLEAN
  END;

  KmerBuffer = POINTER TO KmerBufferRec;
  KmerBufferRec = RECORD
    keys : POINTER TO ARRAY OF LONGINT;
    pos  : POINTER TO ARRAY OF LONGINT;
    n    : INTEGER
  END;

  ChunkBuffer = POINTER TO ChunkBufferRec;
  ChunkBufferRec = RECORD
    data : ARRAY 65537 OF CHAR
  END;

VAR
  fastaPath   : ARRAY 1024 OF CHAR;
  taxonomy    : ARRAY 512 OF CHAR;
  taxonomyLC  : ARRAY 512 OF CHAR;
  kSize       : INTEGER;
  topN        : INTEGER;
  minFrac     : REAL;
  ignoreCase  : BOOLEAN;

  seqs      : ARRAY MaxSeqs OF BioSeq.Seq;
  headers   : ARRAY MaxSeqs OF ARRAY 512 OF CHAR;
  isTarget  : ARRAY MaxSeqs OF BOOLEAN;
  nSeqs     : INTEGER;
  nTarget   : INTEGER;
  nOffTgt   : INTEGER;

  workerTgt  : ARRAY MaxWorkers OF HashTable;
  workerOff  : ARRAY MaxWorkers OF HashTable;
  workerBuf  : ARRAY MaxWorkers OF KmerBuffer;
  workerRaw  : ARRAY MaxWorkers OF ChunkBuffer;
  nWorkers   : INTEGER;

  globalTgt : HashTable;
  globalOff : HashTable;

  (* K-mer arithmetic constants *)
  kmerModulus : LONGINT;   (* 4^k, used as the modulus for fwd; 0 for k=32 *)
  kmerHi      : LONGINT;   (* 4^(k-1) *)
  useMod      : BOOLEAN;   (* FALSE when k=32 (natural LONGINT wrap not needed - see note) *)

  (* Base LUT: valid base -> 0..3, invalid -> 255 *)
  baseLUT : ARRAY 256 OF INTEGER;

  sliceLo, sliceHi : ARRAY MaxWorkers OF INTEGER;

(* ------------------------------------------------------------------ *)
(*  Setup                                                              *)
(* ------------------------------------------------------------------ *)

PROCEDURE InitBaseLUT;
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO 255 DO baseLUT[i] := 255 END;
  baseLUT[ORD('A')] := 0; baseLUT[ORD('a')] := 0;
  baseLUT[ORD('C')] := 1; baseLUT[ORD('c')] := 1;
  baseLUT[ORD('G')] := 2; baseLUT[ORD('g')] := 2;
  baseLUT[ORD('T')] := 3; baseLUT[ORD('t')] := 3;
  baseLUT[ORD('U')] := 3; baseLUT[ORD('u')] := 3
END InitBaseLUT;

(* ------------------------------------------------------------------ *)
(*  String helpers                                                     *)
(* ------------------------------------------------------------------ *)

PROCEDURE ToLowerCopy(src: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR);
VAR i: INTEGER; c: CHAR;
BEGIN
  i := 0;
  WHILE (src[i] # 0X) & (i < LEN(dst) - 1) DO
    c := src[i];
    IF (c >= 'A') & (c <= 'Z') THEN c := CHR(ORD(c) + 32) END;
    dst[i] := c; INC(i)
  END;
  dst[i] := 0X
END ToLowerCopy;

PROCEDURE Contains(hay, needle: ARRAY OF CHAR): BOOLEAN;
BEGIN RETURN Strings.Pos(needle, hay) >= 0
END Contains;

(* ------------------------------------------------------------------ *)
(*  Decoding                                                           *)
(* ------------------------------------------------------------------ *)

PROCEDURE DecodeKmer(kmer: LONGINT; k: INTEGER; VAR out: ARRAY OF CHAR);
VAR i: INTEGER; code: LONGINT;
BEGIN
  FOR i := k - 1 TO 0 BY -1 DO
    code := kmer MOD 4;   (* kmer stays non-negative for k < 32 *)
    IF code = 0 THEN out[i] := 'A'
    ELSIF code = 1 THEN out[i] := 'C'
    ELSIF code = 2 THEN out[i] := 'G'
    ELSE out[i] := 'T'
    END;
    kmer := kmer DIV 4
  END;
  out[k] := 0X
END DecodeKmer;

(* ------------------------------------------------------------------ *)
(*  Hash table                                                         *)
(* ------------------------------------------------------------------ *)

PROCEDURE AllocSlots(t: HashTable; cap: INTEGER);
VAR i: INTEGER;
BEGIN
  NEW(t.keys, cap);
  NEW(t.counts, cap);
  IF t.hasPos THEN NEW(t.posSum, cap) ELSE t.posSum := NIL END;
  FOR i := 0 TO cap - 1 DO
    t.keys[i] := EmptyKey;
    t.counts[i] := 0
  END;
  IF t.hasPos THEN
    FOR i := 0 TO cap - 1 DO t.posSum[i] := 0 END
  END;
  t.cap := cap;
  t.capL := cap
END AllocSlots;

PROCEDURE NewTable(withPos: BOOLEAN; initCap: INTEGER): HashTable;
VAR t: HashTable;
BEGIN
  NEW(t);
  t.hasPos := withPos;
  t.used := 0;
  AllocSlots(t, initCap);
  RETURN t
END NewTable;

PROCEDURE Mix64(x: LONGINT): LONGINT;
(*
  Multiplicative hash using two smaller constants (safe to represent as
  LONGINT literals on any 64-bit compiler).  Not as strong as splitmix64
  but avoids the very large literal parsing risk.
*)
VAR h: LONGINT;
BEGIN
  h := x;
  h := h * 2654435761;
  h := h + (h DIV 4294967296);   (* fold high 32 bits down *)
  h := h * 2246822519;
  IF h < 0 THEN h := -(h + 1) END;
  RETURN h
END Mix64;

PROCEDURE SlotFor(t: HashTable; key: LONGINT): INTEGER;
(* Returns an INTEGER slot index.  capL is a power of two well under 2^31. *)
VAR h: LONGINT; idx: INTEGER;
BEGIN
  h := Mix64(key) MOD t.capL;
  IF h < 0 THEN h := h + t.capL END;
  idx := h;   (* implicit narrowing; h is in [0, capL) which fits INTEGER *)
  RETURN idx
END SlotFor;

PROCEDURE Grow(t: HashTable);
(*
  Allocate the NEW arrays into locals FIRST, iterate the old arrays which
  are still referenced by t.keys/t.counts/t.posSum, then swap into t at
  the end.  This avoids any possibility that NEW(t.keys, ...) invalidates
  the old array we're still reading from.
*)
VAR
  newKeys   : POINTER TO ARRAY OF LONGINT;
  newCounts : POINTER TO ARRAY OF INTEGER;
  newPos    : POINTER TO ARRAY OF LONGINT;
  oldCap, i, j, idx, probes, newCap : INTEGER;
  newCapL   : LONGINT;
  key, h    : LONGINT;
  copyPos   : BOOLEAN;
BEGIN
  oldCap := t.cap;
  newCap := oldCap * 2;
  IF newCap <= 0 THEN
    Out.String("FATAL: hash table capacity overflow"); Out.Ln; HALT(1)
  END;
  newCapL := newCap;

  NEW(newKeys, newCap);
  NEW(newCounts, newCap);
  copyPos := t.hasPos & (t.posSum # NIL);
  IF t.hasPos THEN NEW(newPos, newCap) ELSE newPos := NIL END;
  FOR j := 0 TO newCap - 1 DO
    newKeys[j] := EmptyKey;
    newCounts[j] := 0
  END;
  IF t.hasPos THEN
    FOR j := 0 TO newCap - 1 DO newPos[j] := 0 END
  END;

  (* Re-hash from the OLD arrays (still referenced by t) into the new ones. *)
  FOR i := 0 TO oldCap - 1 DO
    IF t.keys[i] # EmptyKey THEN
      key := t.keys[i];
      h := Mix64(key) MOD newCapL;
      IF h < 0 THEN h := h + newCapL END;
      idx := h;
      probes := 0;
      LOOP
        IF newKeys[idx] = EmptyKey THEN
          newKeys[idx] := key;
          newCounts[idx] := t.counts[i];
          IF copyPos THEN newPos[idx] := t.posSum[i] END;
          EXIT
        END;
        INC(idx); IF idx >= newCap THEN idx := 0 END;
        INC(probes);
        IF probes >= newCap THEN
          Out.String("FATAL: rehash wrapped"); Out.Ln; HALT(1)
        END
      END
    END
  END;

  (* Swap in the new arrays. *)
  t.keys := newKeys;
  t.counts := newCounts;
  t.posSum := newPos;
  t.cap := newCap;
  t.capL := newCapL
  (* t.used stays the same — every entry from old was re-inserted. *)
END Grow;

PROCEDURE TablePutRaw(t: HashTable; key: LONGINT; addCount: INTEGER;
                      addPos: LONGINT; recordPos: BOOLEAN);
VAR idx, probes: INTEGER;
BEGIN
  IF (t.used + 1) * 4 > t.cap * 3 THEN Grow(t) END;
  idx := SlotFor(t, key);
  probes := 0;
  LOOP
    IF t.keys[idx] = EmptyKey THEN
      t.keys[idx] := key;
      t.counts[idx] := addCount;
      IF recordPos & (t.posSum # NIL) THEN t.posSum[idx] := addPos END;
      INC(t.used);
      EXIT
    ELSIF t.keys[idx] = key THEN
      t.counts[idx] := t.counts[idx] + addCount;
      IF recordPos & (t.posSum # NIL) THEN
        t.posSum[idx] := t.posSum[idx] + addPos
      END;
      EXIT
    ELSE
      INC(idx); IF idx >= t.cap THEN idx := 0 END;
      INC(probes);
      IF probes >= t.cap THEN
        Out.String("FATAL: TablePutRaw wrapped"); Out.Ln; HALT(1)
      END
    END
  END
END TablePutRaw;

PROCEDURE TableGet(t: HashTable; key: LONGINT): INTEGER;
VAR idx, probes: INTEGER;
BEGIN
  idx := SlotFor(t, key);
  probes := 0;
  LOOP
    IF t.keys[idx] = EmptyKey THEN RETURN 0
    ELSIF t.keys[idx] = key THEN RETURN t.counts[idx]
    ELSE
      INC(idx); IF idx >= t.cap THEN idx := 0 END;
      INC(probes);
      IF probes >= t.cap THEN RETURN 0 END
    END
  END
END TableGet;

PROCEDURE MergeInto(dst, src: HashTable; mergePos: BOOLEAN);
VAR i: INTEGER; addP: LONGINT;
BEGIN
  FOR i := 0 TO src.cap - 1 DO
    IF src.keys[i] # EmptyKey THEN
      IF mergePos & (src.posSum # NIL) THEN addP := src.posSum[i] ELSE addP := 0 END;
      TablePutRaw(dst, src.keys[i], src.counts[i], addP, mergePos)
    END
  END
END MergeInto;

(* ------------------------------------------------------------------ *)
(*  Per-sequence k-mer buffer + dedup by sort                          *)
(* ------------------------------------------------------------------ *)

PROCEDURE NewKmerBuffer(): KmerBuffer;
VAR b: KmerBuffer;
BEGIN
  NEW(b);
  NEW(b.keys, MaxKmersPerSeq);
  NEW(b.pos,  MaxKmersPerSeq);
  b.n := 0;
  RETURN b
END NewKmerBuffer;

PROCEDURE SortBuffer(buf: KmerBuffer);
(* Iterative quicksort on buf.keys[0..n-1] with buf.pos moved in lockstep. *)
VAR
  stack : ARRAY 64 OF INTEGER;
  sp    : INTEGER;
  lo, hi, i, j : INTEGER;
  pivot, tk, tp : LONGINT;
BEGIN
  IF buf.n < 2 THEN RETURN END;
  sp := 0;
  stack[sp] := 0; INC(sp);
  stack[sp] := buf.n - 1; INC(sp);
  WHILE sp > 0 DO
    DEC(sp); hi := stack[sp];
    DEC(sp); lo := stack[sp];
    IF lo < hi THEN
      pivot := buf.keys[(lo + hi) DIV 2];
      i := lo; j := hi;
      LOOP
        WHILE buf.keys[i] < pivot DO INC(i) END;
        WHILE buf.keys[j] > pivot DO DEC(j) END;
        IF i > j THEN EXIT END;
        tk := buf.keys[i]; buf.keys[i] := buf.keys[j]; buf.keys[j] := tk;
        tp := buf.pos[i];  buf.pos[i]  := buf.pos[j];  buf.pos[j]  := tp;
        INC(i); DEC(j)
      END;
      IF lo < j THEN
        stack[sp] := lo; INC(sp);
        stack[sp] := j;  INC(sp)
      END;
      IF i < hi THEN
        stack[sp] := i;  INC(sp);
        stack[sp] := hi; INC(sp)
      END
    END
  END
END SortBuffer;

PROCEDURE FlushBufferToTable(buf: KmerBuffer; t: HashTable; recordPos: BOOLEAN);
VAR i, n: INTEGER; prev: LONGINT;
BEGIN
  n := buf.n;
  IF n = 0 THEN RETURN END;
  SortBuffer(buf);
  prev := buf.keys[0];
  TablePutRaw(t, prev, 1, buf.pos[0], recordPos);
  i := 1;
  WHILE i < n DO
    IF buf.keys[i] # prev THEN
      prev := buf.keys[i];
      TablePutRaw(t, prev, 1, buf.pos[i], recordPos)
    END;
    INC(i)
  END;
  buf.n := 0
END FlushBufferToTable;

(* ------------------------------------------------------------------ *)
(*  K-mer extraction (hot loop)                                        *)
(* ------------------------------------------------------------------ *)

PROCEDURE CountSeqKmers(seq: BioSeq.Seq; recordPos: BOOLEAN;
                        t: HashTable; buf: KmerBuffer; raw: ChunkBuffer);
CONST
  ChunkSize = 65536;
VAR
  T, off, take, i, code, filled : INTEGER;
  fwd, rev, canon, modulus : LONGINT;
  hi : LONGINT;
  pos : LONGINT;
  useModLocal : BOOLEAN;
  bufN : INTEGER;
BEGIN
  T := BioSeq.Length(seq);
  IF T > MaxSeqLen THEN T := MaxSeqLen END;
  IF T < kSize THEN RETURN END;

  modulus := kmerModulus;
  useModLocal := useMod;
  hi := kmerHi;

  bufN := buf.n;

  fwd := 0; rev := 0; filled := 0; off := 0;
  pos := 0;

  WHILE off < T DO
    take := T - off;
    IF take > ChunkSize THEN take := ChunkSize END;
    BioSeq.Slice(seq, off, take, raw.data);

    i := 0;
    WHILE i < take DO
      code := baseLUT[ORD(raw.data[i])];
      IF code # 255 THEN
        IF useModLocal THEN
          fwd := (fwd * 4 + code) MOD modulus
        ELSE
          fwd := fwd * 4 + code
        END;
        rev := rev DIV 4 + (3 - code) * hi;
        INC(filled);
        IF filled >= kSize THEN
          IF fwd < rev THEN canon := fwd ELSE canon := rev END;
          IF bufN < MaxKmersPerSeq THEN
            buf.keys[bufN] := canon;
            buf.pos[bufN]  := pos;
            INC(bufN)
          END
        END;
        pos := pos + 1
      ELSE
        fwd := 0; rev := 0; filled := 0;
        pos := pos + 1
      END;
      INC(i)
    END;
    off := off + take
  END;

  buf.n := bufN;
  FlushBufferToTable(buf, t, recordPos)
END CountSeqKmers;

(* ------------------------------------------------------------------ *)
(*  Parallel worker                                                    *)
(* ------------------------------------------------------------------ *)

PROCEDURE ScoreSlice(w: INTEGER);
VAR i: INTEGER;
BEGIN
  FOR i := sliceLo[w] TO sliceHi[w] - 1 DO
    workerBuf[w].n := 0;
    IF isTarget[i] THEN
      CountSeqKmers(seqs[i], TRUE, workerTgt[w], workerBuf[w], workerRaw[w])
    ELSE
      CountSeqKmers(seqs[i], FALSE, workerOff[w], workerBuf[w], workerRaw[w])
    END
  END
END ScoreSlice;

(* ------------------------------------------------------------------ *)
(*  Top-N selection                                                    *)
(* ------------------------------------------------------------------ *)

TYPE
  Hit = RECORD
    key    : LONGINT;
    tgt    : INTEGER;
    off    : INTEGER;
    score  : REAL;
    avgPos : LONGINT
  END;

VAR hits: ARRAY MaxTopReport + 1 OF Hit;

PROCEDURE InsertHit(VAR count: INTEGER; cap: INTEGER; VAR h: Hit);
VAR i: INTEGER;
BEGIN
  IF count < cap THEN
    i := count;
    WHILE (i > 0) & (h.score < hits[i-1].score) DO
      hits[i] := hits[i-1]; DEC(i)
    END;
    hits[i] := h; INC(count)
  ELSIF h.score > hits[0].score THEN
    i := 0;
    WHILE (i < count - 1) & (h.score > hits[i+1].score) DO
      hits[i] := hits[i+1]; INC(i)
    END;
    hits[i] := h
  END
END InsertHit;

(* ------------------------------------------------------------------ *)
(*  FASTA loading                                                      *)
(* ------------------------------------------------------------------ *)

PROCEDURE ClassifyHeader(header: ARRAY OF CHAR): BOOLEAN;
VAR lc: ARRAY 512 OF CHAR;
BEGIN
  IF ignoreCase THEN
    ToLowerCopy(header, lc);
    RETURN Contains(lc, taxonomyLC)
  ELSE
    RETURN Contains(header, taxonomy)
  END
END ClassifyHeader;

PROCEDURE LoadFasta(): BOOLEAN;
VAR
  rdr : BioIO.FastaReader;
  rec : BioIO.FastaRecord;
  hdr : ARRAY 512 OF CHAR;
  space : ARRAY 2 OF CHAR;
  warned : BOOLEAN;
BEGIN
  IF ~BioIO.OpenFasta(rdr, fastaPath) THEN
    Out.String("Error: cannot open FASTA "); Out.String(fastaPath); Out.Ln;
    RETURN FALSE
  END;
  nSeqs := 0; nTarget := 0; nOffTgt := 0;
  warned := FALSE;
  space[0] := ' '; space[1] := 0X;
  rec.seq := NIL;
  WHILE BioIO.ReadFasta(rdr, rec) DO
    IF nSeqs >= MaxSeqs THEN
      IF ~warned THEN
        Out.String("Warning: more than "); Out.Int(MaxSeqs, 0);
        Out.String(" sequences; extras ignored."); Out.Ln;
        warned := TRUE
      END
    ELSE
      seqs[nSeqs] := rec.seq;
      rec.seq := NIL;

      Strings.Copy(rec.name, hdr);
      IF rec.desc[0] # 0X THEN
        Strings.Append(space, hdr);
        Strings.Append(rec.desc, hdr)
      END;
      Strings.Copy(hdr, headers[nSeqs]);

      isTarget[nSeqs] := ClassifyHeader(hdr);
      IF isTarget[nSeqs] THEN INC(nTarget) ELSE INC(nOffTgt) END;
      INC(nSeqs)
    END
  END;
  BioIO.CloseFasta(rdr);
  RETURN TRUE
END LoadFasta;

(* ------------------------------------------------------------------ *)
(*  Counting orchestration                                             *)
(* ------------------------------------------------------------------ *)

PROCEDURE RunCounting;
VAR
  w, base, extra, cur : INTEGER;
BEGIN
  nWorkers := Parallel.NumCPU();
  IF nWorkers < 1 THEN nWorkers := 1 END;
  IF nWorkers > MaxWorkers THEN nWorkers := MaxWorkers END;
  IF nWorkers > nSeqs THEN nWorkers := nSeqs END;
  IF nWorkers < 1 THEN nWorkers := 1 END;

  Out.String("Using "); Out.Int(nWorkers, 0);
  Out.String(" worker thread(s)."); Out.Ln;

  FOR w := 0 TO nWorkers - 1 DO
    workerTgt[w] := NewTable(TRUE,  InitCap);
    workerOff[w] := NewTable(FALSE, InitCap);
    workerBuf[w] := NewKmerBuffer();
    NEW(workerRaw[w])
  END;

  base  := nSeqs DIV nWorkers;
  extra := nSeqs MOD nWorkers;
  cur   := 0;
  FOR w := 0 TO nWorkers - 1 DO
    sliceLo[w] := cur;
    IF w < extra THEN cur := cur + base + 1 ELSE cur := cur + base END;
    sliceHi[w] := cur
  END;

  Parallel.For(0, nWorkers, ScoreSlice, nWorkers);

  Out.String("Merging per-worker tables..."); Out.Ln;
  globalTgt := NewTable(TRUE,  InitCap);
  globalOff := NewTable(FALSE, InitCap);
  FOR w := 0 TO nWorkers - 1 DO
    MergeInto(globalTgt, workerTgt[w], TRUE);
    MergeInto(globalOff, workerOff[w], FALSE)
  END;

  Out.String("Unique k-mers - target: "); Out.Int(globalTgt.used, 0);
  Out.String(" (cap "); Out.Int(globalTgt.cap, 0); Out.String(")");
  Out.String(" | off-target: "); Out.Int(globalOff.used, 0);
  Out.String(" (cap "); Out.Int(globalOff.cap, 0); Out.String(")"); Out.Ln
END RunCounting;

(* ------------------------------------------------------------------ *)
(*  Reporting                                                          *)
(* ------------------------------------------------------------------ *)

PROCEDURE Report;
VAR
  i, cap, count, minTgtHits, t, o : INTEGER;
  score, nT, nO, tfrac, ofrac : REAL;
  key : LONGINT;
  h : Hit;
  kmerStr : ARRAY MaxK + 1 OF CHAR;
  avgPos : LONGINT;
BEGIN
  IF nTarget = 0 THEN
    Out.String("No target sequences matched; nothing to report."); Out.Ln; RETURN
  END;

  nT := FLT(nTarget);
  IF nOffTgt > 0 THEN nO := FLT(nOffTgt) ELSE nO := 1.0 END;

  minTgtHits := FLOOR(minFrac * nT + 0.9999);
  IF minTgtHits < 1 THEN minTgtHits := 1 END;

  cap := topN;
  IF cap > MaxTopReport THEN cap := MaxTopReport END;
  IF cap < 1 THEN cap := 1 END;

  count := 0;
  FOR i := 0 TO globalTgt.cap - 1 DO
    IF globalTgt.keys[i] # EmptyKey THEN
      t := globalTgt.counts[i];
      IF t >= minTgtHits THEN
        key := globalTgt.keys[i];
        o   := TableGet(globalOff, key);
        IF nOffTgt = 0 THEN
          score := FLT(t) / nT
        ELSE
          score := FLT(t) / nT - FLT(o) / nO
        END;
        IF globalTgt.posSum # NIL THEN
          avgPos := globalTgt.posSum[i] DIV t
        ELSE
          avgPos := 0
        END;
        h.key := key; h.tgt := t; h.off := o;
        h.score := score; h.avgPos := avgPos;
        InsertHit(count, cap, h)
      END
    END
  END;

  Out.String("rank"); Out.Char(9X);
  Out.String("kmer"); Out.Char(9X);
  Out.String("avg_pos"); Out.Char(9X);
  Out.String("target_hits"); Out.Char(9X);
  Out.String("target_frac"); Out.Char(9X);
  Out.String("off_hits"); Out.Char(9X);
  Out.String("off_frac"); Out.Char(9X);
  Out.String("discrimination"); Out.Ln;

  FOR i := count - 1 TO 0 BY -1 DO
    DecodeKmer(hits[i].key, kSize, kmerStr);
    tfrac := FLT(hits[i].tgt) / nT;
    IF nOffTgt > 0 THEN ofrac := FLT(hits[i].off) / nO ELSE ofrac := 0.0 END;
    Out.Int(count - i, 0); Out.Char(9X);
    Out.String(kmerStr); Out.Char(9X);
    Out.Int(hits[i].avgPos, 0); Out.Char(9X);
    Out.Int(hits[i].tgt, 0); Out.Char(9X);
    Out.Fixed(tfrac, 0, 4); Out.Char(9X);
    Out.Int(hits[i].off, 0); Out.Char(9X);
    Out.Fixed(ofrac, 0, 4); Out.Char(9X);
    Out.Fixed(hits[i].score, 0, 4); Out.Ln
  END;

  Out.String("# reported "); Out.Int(count, 0);
  Out.String(" k-mer(s) at k="); Out.Int(kSize, 0); Out.Ln
END Report;

(* ------------------------------------------------------------------ *)
(*  CLI parsing                                                        *)
(* ------------------------------------------------------------------ *)

PROCEDURE Usage;
BEGIN
  Out.String("Usage: KmerFind -f <fasta> -t <taxonomy> [options]"); Out.Ln;
  Out.String("  -f <path>            input FASTA"); Out.Ln;
  Out.String("  -t <substr>          taxonomy substring for target set"); Out.Ln;
  Out.String("  -k <int>             k-mer length (1..32, default 24)"); Out.Ln;
  Out.String("  -n <int>             top N to report (default 20)"); Out.Ln;
  Out.String("  --min-target-frac x  min target fraction (default 0.5)"); Out.Ln;
  Out.String("  --ignore-case        case-insensitive taxonomy match"); Out.Ln;
  Out.String("  -j <int>             max worker threads"); Out.Ln
END Usage;

PROCEDURE ParseArgs(): BOOLEAN;
VAR
  i, jVal, iVal : INTEGER;
  arg, val : ARRAY 1024 OF CHAR;
  rVal : REAL;
BEGIN
  fastaPath[0] := 0X; taxonomy[0] := 0X;
  kSize := 24; topN := 20; minFrac := 0.5; ignoreCase := FALSE;

  i := 1;
  WHILE i <= Args.Count() DO
    Args.Get(i, arg);
    IF (Strings.Compare(arg, "-f") = 0) OR (Strings.Compare(arg, "--fasta") = 0) THEN
      INC(i); IF i > Args.Count() THEN RETURN FALSE END;
      Args.Get(i, fastaPath)
    ELSIF (Strings.Compare(arg, "-t") = 0) OR (Strings.Compare(arg, "--taxonomy") = 0) THEN
      INC(i); IF i > Args.Count() THEN RETURN FALSE END;
      Args.Get(i, taxonomy)
    ELSIF Strings.Compare(arg, "-k") = 0 THEN
      INC(i); IF i > Args.Count() THEN RETURN FALSE END;
      Args.Get(i, val);
      IF ~Strings.StrToInt(val, iVal) THEN RETURN FALSE END;
      kSize := iVal
    ELSIF (Strings.Compare(arg, "-n") = 0) OR (Strings.Compare(arg, "--top") = 0) THEN
      INC(i); IF i > Args.Count() THEN RETURN FALSE END;
      Args.Get(i, val);
      IF ~Strings.StrToInt(val, iVal) THEN RETURN FALSE END;
      topN := iVal
    ELSIF Strings.Compare(arg, "--min-target-frac") = 0 THEN
      INC(i); IF i > Args.Count() THEN RETURN FALSE END;
      Args.Get(i, val);
      IF ~Strings.StrToReal(val, rVal) THEN RETURN FALSE END;
      minFrac := rVal
    ELSIF Strings.Compare(arg, "--ignore-case") = 0 THEN
      ignoreCase := TRUE
    ELSIF Strings.Compare(arg, "-j") = 0 THEN
      INC(i); IF i > Args.Count() THEN RETURN FALSE END;
      Args.Get(i, val);
      IF Strings.StrToInt(val, jVal) & (jVal > 0) THEN
        Parallel.SetMaxCPU(jVal)
      END
    ELSIF (Strings.Compare(arg, "-h") = 0) OR (Strings.Compare(arg, "--help") = 0) THEN
      RETURN FALSE
    ELSE
      Out.String("Unknown option: "); Out.String(arg); Out.Ln;
      RETURN FALSE
    END;
    INC(i)
  END;

  IF fastaPath[0] = 0X THEN
    Out.String("Error: -f <fasta> is required."); Out.Ln; RETURN FALSE
  END;
  IF taxonomy[0] = 0X THEN
    Out.String("Error: -t <taxonomy> is required."); Out.Ln; RETURN FALSE
  END;
  IF (kSize < 1) OR (kSize > MaxK) THEN
    Out.String("Error: k must be in 1..");  Out.Int(MaxK, 0); Out.Ln;
    RETURN FALSE
  END;
  IF (minFrac < 0.0) OR (minFrac > 1.0) THEN
    Out.String("Error: --min-target-frac must be in 0.0..1.0"); Out.Ln; RETURN FALSE
  END;

  IF ignoreCase THEN ToLowerCopy(taxonomy, taxonomyLC) END;

  RETURN TRUE
END ParseArgs;

(* ------------------------------------------------------------------ *)
(*  Mask/modulus setup                                                 *)
(* ------------------------------------------------------------------ *)

PROCEDURE SetupMask;
VAR i: INTEGER;
BEGIN
  IF kSize = 32 THEN
    kmerModulus := 0;   (* unused when useMod = FALSE *)
    useMod := FALSE
  ELSE
    kmerModulus := 1;
    FOR i := 1 TO kSize DO kmerModulus := kmerModulus * 4 END;
    useMod := TRUE
  END;
  kmerHi := 1;
  FOR i := 1 TO kSize - 1 DO kmerHi := kmerHi * 4 END
END SetupMask;

(* ------------------------------------------------------------------ *)
(*  Entry point                                                        *)
(* ------------------------------------------------------------------ *)

BEGIN
  InitBaseLUT;
  IF ~ParseArgs() THEN Usage; RETURN END;

  Out.String("Reading FASTA: "); Out.String(fastaPath); Out.Ln;
  IF ~LoadFasta() THEN RETURN END;
  Out.String("Loaded "); Out.Int(nSeqs, 0); Out.String(" sequences."); Out.Ln;
  Out.String("Target sequences: "); Out.Int(nTarget, 0);
  Out.String(" | Off-target: "); Out.Int(nOffTgt, 0); Out.Ln;

  IF nTarget = 0 THEN
    Out.String("No sequences match the taxonomy substring; nothing to do."); Out.Ln;
    RETURN
  END;

  SetupMask;

  Out.String("Counting k-mers (k="); Out.Int(kSize, 0);
  Out.String(") in parallel..."); Out.Ln;
  RunCounting;

  Report
END KmerFind.
