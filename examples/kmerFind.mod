MODULE KmerFind;
(*
  KmerFind — Find k-mers that discriminate a target taxonomic group from
  the rest of a FASTA database.

  Usage:
    KmerFind -f <fasta> -t <taxonomy> [-k <int>] [-n <int>]
             [--min-target-frac <real>] [--ignore-case] [-j <int>]

  Options:
    -f <path>            Input FASTA (headers like ">ID Domain;Phylum;...;Species").
    -t <substr>          Taxonomy substring defining the target set (matched
                         against the FASTA record name+desc).
    -k <int>             K-mer length (1..32). Default 24.
                         Note: capped at 32 so a canonical k-mer fits in a LONGINT.
    -n <int>             Number of top k-mers to report. Default 20.
    --min-target-frac x  Minimum fraction of target sequences a k-mer must
                         appear in to be considered (0.0..1.0). Default 0.5.
    --ignore-case        Case-insensitive taxonomy matching.
    -j <int>             Maximum worker threads (default: all CPUs).

  Notes on hash tables:
    Hash tables use open-addressing with linear probing.  Capacity is
    per-table (not a global constant) and doubles when the load factor
    exceeds 0.75.  Every probe loop is bounded so a bug can never hang
    the process — it will HALT with a clear message instead.
*)

IMPORT BioIO, BioSeq, Args, Strings, Out, Math, Parallel;

CONST
  MaxK          = 32;
  MaxSeqs       = 400000;
  MaxSeqLen     = 5000;
  MaxWorkers    = 64;
  InitCap       = 4096;            (* initial per-table capacity; grows as needed *)
  SeenInitCap   = 8192;            (* per-sequence dedup table; ~2x max distinct k-mers per seq *)
  MaxTopReport  = 1000;
  EmptyKey      = -1;

TYPE
  HashTable = POINTER TO HashTableRec;
  HashTableRec = RECORD
    keys    : POINTER TO ARRAY OF LONGINT;
    counts  : POINTER TO ARRAY OF INTEGER;
    posSum  : POINTER TO ARRAY OF LONGINT;   (* NIL if not tracking positions *)
    cap     : INTEGER;                       (* current capacity, power of two *)
    mask    : INTEGER;                       (* cap - 1 *)
    used    : INTEGER;                       (* number of occupied slots *)
    hasPos  : BOOLEAN
  END;

VAR
  (* Command-line configuration *)
  fastaPath   : ARRAY 1024 OF CHAR;
  taxonomy    : ARRAY 512 OF CHAR;
  taxonomyLC  : ARRAY 512 OF CHAR;
  kSize       : INTEGER;
  topN        : INTEGER;
  minFrac     : REAL;
  ignoreCase  : BOOLEAN;

  (* Loaded records *)
  seqs      : ARRAY MaxSeqs OF BioSeq.Seq;
  headers   : ARRAY MaxSeqs OF ARRAY 512 OF CHAR;
  isTarget  : ARRAY MaxSeqs OF BOOLEAN;
  nSeqs     : INTEGER;
  nTarget   : INTEGER;
  nOffTgt   : INTEGER;

  (* Per-worker tables *)
  workerTgt  : ARRAY MaxWorkers OF HashTable;
  workerOff  : ARRAY MaxWorkers OF HashTable;
  workerSeen : ARRAY MaxWorkers OF HashTable;
  nWorkers   : INTEGER;

  (* Global merged tables *)
  globalTgt : HashTable;
  globalOff : HashTable;

  (* K-mer bit-arithmetic constants *)
  kmerMask : LONGINT;   (* 4^k - 1, or -1 for k=32 (natural wrap) *)
  kmerHi   : LONGINT;   (* 4^(k-1) *)

  (* Parallel slice bounds *)
  sliceLo, sliceHi : ARRAY MaxWorkers OF INTEGER;

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
(*  Base encoding                                                      *)
(* ------------------------------------------------------------------ *)

PROCEDURE EncodeBase(c: CHAR; VAR code: INTEGER): BOOLEAN;
BEGIN
  CASE c OF
    'A', 'a': code := 0; RETURN TRUE
  | 'C', 'c': code := 1; RETURN TRUE
  | 'G', 'g': code := 2; RETURN TRUE
  | 'T', 't', 'U', 'u': code := 3; RETURN TRUE
  ELSE RETURN FALSE
  END
END EncodeBase;

PROCEDURE DecodeKmer(kmer: LONGINT; k: INTEGER; VAR out: ARRAY OF CHAR);
VAR i, code: INTEGER;
BEGIN
  FOR i := k - 1 TO 0 BY -1 DO
    code := kmer MOD 4;
    IF code < 0 THEN code := code + 4 END;   (* guard k=32 wrap *)
    CASE code OF
      0: out[i] := 'A'
    | 1: out[i] := 'C'
    | 2: out[i] := 'G'
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
  t.mask := cap - 1
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
(* Multiplicative hash, returns a non-negative value robustly. *)
VAR h: LONGINT;
BEGIN
  h := x;
  IF h < 0 THEN h := h + 1; h := -h END;
  h := h * 2654435761;
  IF h < 0 THEN h := h + 1; h := -h END;
  RETURN h
END Mix64;

PROCEDURE SlotFor(t: HashTable; key: LONGINT): INTEGER;
VAR idx: INTEGER; h: LONGINT;
BEGIN
  h := Mix64(key);
  (* cap is a power of two, so mask is faster and always non-negative *)
  idx := h MOD t.cap;
  IF idx < 0 THEN idx := idx + t.cap END;
  RETURN idx
END SlotFor;

PROCEDURE Grow(t: HashTable);
(* Double the table capacity and rehash every entry.  Inserts are done
   inline (no call back to TablePutRaw) so there is no mutual recursion
   and no forward-declaration needed.  The new table is guaranteed to
   have room, so no load-factor check is required during rehash. *)
VAR
  oldKeys   : POINTER TO ARRAY OF LONGINT;
  oldCounts : POINTER TO ARRAY OF INTEGER;
  oldPos    : POINTER TO ARRAY OF LONGINT;
  oldCap, i, idx, probes : INTEGER;
  newCap    : INTEGER;
  key       : LONGINT;
  h         : LONGINT;
  copyPos   : BOOLEAN;
BEGIN
  oldKeys := t.keys; oldCounts := t.counts; oldPos := t.posSum;
  oldCap := t.cap;
  newCap := oldCap * 2;
  IF newCap <= 0 THEN
    Out.String("FATAL: hash table capacity overflow"); Out.Ln; HALT(1)
  END;
  t.used := 0;
  AllocSlots(t, newCap);
  copyPos := (oldPos # NIL) & (t.posSum # NIL);
  FOR i := 0 TO oldCap - 1 DO
    IF oldKeys[i] # EmptyKey THEN
      key := oldKeys[i];
      h := Mix64(key);
      idx := h MOD t.cap;
      IF idx < 0 THEN idx := idx + t.cap END;
      probes := 0;
      LOOP
        IF t.keys[idx] = EmptyKey THEN
          t.keys[idx] := key;
          t.counts[idx] := oldCounts[i];
          IF copyPos THEN t.posSum[idx] := oldPos[i] END;
          INC(t.used);
          EXIT
        ELSE
          idx := (idx + 1) MOD t.cap;
          INC(probes);
          IF probes >= t.cap THEN
            Out.String("FATAL: rehash wrapped completely"); Out.Ln; HALT(1)
          END
        END
      END
    END
  END
END Grow;

PROCEDURE TablePutRaw(t: HashTable; key: LONGINT; addCount: INTEGER;
                      addPos: LONGINT; recordPos: BOOLEAN);
(* Insert `key` adding `addCount` to its count and (if recordPos) `addPos`
   to its posSum.  Grows the table if load factor would exceed 3/4. *)
VAR idx, probes: INTEGER;
BEGIN
  (* Load factor check BEFORE insertion; may cause growth. *)
  IF (t.used + 1) * 4 > t.cap * 3 THEN
    Grow(t)
  END;
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
      idx := (idx + 1) MOD t.cap;
      INC(probes);
      IF probes >= t.cap THEN
        Out.String("FATAL: TablePutRaw wrapped completely (cap=");
        Out.Int(t.cap, 0); Out.String(", used="); Out.Int(t.used, 0);
        Out.String(")"); Out.Ln; HALT(1)
      END
    END
  END
END TablePutRaw;

PROCEDURE TablePut(t: HashTable; key: LONGINT; pos: LONGINT; recordPos: BOOLEAN);
(* Original API: increments count by 1. *)
BEGIN TablePutRaw(t, key, 1, pos, recordPos)
END TablePut;

PROCEDURE TableGet(t: HashTable; key: LONGINT): INTEGER;
VAR idx, probes: INTEGER;
BEGIN
  idx := SlotFor(t, key);
  probes := 0;
  LOOP
    IF t.keys[idx] = EmptyKey THEN RETURN 0
    ELSIF t.keys[idx] = key THEN RETURN t.counts[idx]
    ELSE
      idx := (idx + 1) MOD t.cap;
      INC(probes);
      IF probes >= t.cap THEN RETURN 0 END
    END
  END
END TableGet;

PROCEDURE TableGetPos(t: HashTable; key: LONGINT): LONGINT;
VAR idx, probes: INTEGER;
BEGIN
  idx := SlotFor(t, key);
  probes := 0;
  LOOP
    IF t.keys[idx] = EmptyKey THEN RETURN 0
    ELSIF t.keys[idx] = key THEN
      IF t.posSum # NIL THEN RETURN t.posSum[idx] ELSE RETURN 0 END
    ELSE
      idx := (idx + 1) MOD t.cap;
      INC(probes);
      IF probes >= t.cap THEN RETURN 0 END
    END
  END
END TableGetPos;

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

PROCEDURE ResetTable(t: HashTable);
VAR i: INTEGER;
BEGIN
  IF t.used = 0 THEN RETURN END;
  FOR i := 0 TO t.cap - 1 DO
    IF t.keys[i] # EmptyKey THEN
      t.keys[i] := EmptyKey;
      t.counts[i] := 0
    END
  END;
  t.used := 0
END ResetTable;

(* ------------------------------------------------------------------ *)
(*  K-mer extraction                                                   *)
(* ------------------------------------------------------------------ *)

PROCEDURE CountSeqKmers(seq: BioSeq.Seq; recordPos: BOOLEAN;
                        t: HashTable; seen: HashTable);
CONST
  ChunkSize = 65536;
VAR
  buf     : ARRAY 65537 OF CHAR;
  T, off, take, i, code, filled : INTEGER;
  fwd, rev, canon, complBits, kmMaskP1, hi : LONGINT;
  pos : LONGINT;
  useMask : BOOLEAN;
BEGIN
  T := BioSeq.Length(seq);
  IF T > MaxSeqLen THEN T := MaxSeqLen END;
  IF T < kSize THEN RETURN END;

  useMask := kmerMask # -1;
  IF useMask THEN kmMaskP1 := kmerMask + 1 ELSE kmMaskP1 := 0 END;
  hi := kmerHi;

  fwd := 0; rev := 0; filled := 0; off := 0;
  pos := 0;

  WHILE off < T DO
    take := T - off;
    IF take > ChunkSize THEN take := ChunkSize END;
    BioSeq.Slice(seq, off, take, buf);

    i := 0;
    WHILE i < take DO
      IF EncodeBase(buf[i], code) THEN
        IF useMask THEN
          fwd := (fwd * 4 + code) MOD kmMaskP1
        ELSE
          fwd := fwd * 4 + code
        END;
        complBits := 3 - code;
        rev := (rev DIV 4) + complBits * hi;
        INC(filled);
        IF filled >= kSize THEN
          IF fwd < rev THEN canon := fwd ELSE canon := rev END;
          IF TableGet(seen, canon) = 0 THEN
            TablePut(seen, canon, 0, FALSE);
            TablePut(t, canon, pos, recordPos)
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
  END
END CountSeqKmers;

(* ------------------------------------------------------------------ *)
(*  Parallel worker                                                    *)
(* ------------------------------------------------------------------ *)

PROCEDURE ScoreSlice(w: INTEGER);
VAR i: INTEGER;
BEGIN
  FOR i := sliceLo[w] TO sliceHi[w] - 1 DO
    ResetTable(workerSeen[w]);
    IF isTarget[i] THEN
      CountSeqKmers(seqs[i], TRUE, workerTgt[w], workerSeen[w])
    ELSE
      CountSeqKmers(seqs[i], FALSE, workerOff[w], workerSeen[w])
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
    workerTgt[w]  := NewTable(TRUE,  InitCap);
    workerOff[w]  := NewTable(FALSE, InitCap);
    workerSeen[w] := NewTable(FALSE, SeenInitCap)
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
(*  Mask setup                                                         *)
(* ------------------------------------------------------------------ *)

PROCEDURE SetupMask;
VAR i: INTEGER;
BEGIN
  IF kSize = 32 THEN
    kmerMask := -1
  ELSE
    kmerMask := 1;
    FOR i := 1 TO 2 * kSize DO kmerMask := kmerMask * 2 END;
    kmerMask := kmerMask - 1
  END;
  kmerHi := 1;
  FOR i := 1 TO kSize - 1 DO kmerHi := kmerHi * 4 END
END SetupMask;

(* ------------------------------------------------------------------ *)
(*  Entry point                                                        *)
(* ------------------------------------------------------------------ *)

BEGIN
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

