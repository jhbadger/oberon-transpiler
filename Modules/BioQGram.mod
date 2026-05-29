MODULE BioQGram;
(*
  BioQGram — Q-gram index for exact and approximate sequence matching.

  Build:        O(n) two-pass counting sort over all q-grams in text.
  Query:        O(1) bucket lookup; returns positions sharing the q-gram hash.
                Hash collisions are rare but possible — callers verify if needed.
  ApproxSearch: Pigeonhole filter — if a pattern matches with ≤ maxDist edits,
                at least one of (maxDist+1) evenly-spaced q-grams occurs exactly
                in the text.  Returns candidate start positions (dist=0); callers
                verify exact edit distance with BioPattern.Ukkonen or similar.

  NOTE: QGramIndex is ~512 KB; declare it at module level, not as a local.
  NOTE: module-level scratch (cnt) is not re-entrant across concurrent Builds.
*)

IMPORT BioSeq, BioPattern, Strings;

CONST
  MaxQ*       = 8;
  MaxBuckets* = 65536;

TYPE
  QGramIndex* = RECORD
    q*       : INTEGER;
    buckets* : ARRAY MaxBuckets OF INTEGER;   (* start of each hash bucket in pos *)
    pos*     : ARRAY MaxBuckets OF INTEGER;   (* text positions, sorted by hash *)
    nPos*    : INTEGER;
    textLen* : INTEGER
  END;

VAR
  cnt : ARRAY MaxBuckets OF INTEGER;   (* scratch for Build *)

(* ------------------------------------------------------------------ *)
(*  Internal hash functions                                             *)
(* ------------------------------------------------------------------ *)

PROCEDURE HashSeq(text: BioSeq.Seq; p, q: INTEGER): INTEGER;
(* Polynomial hash of text[p..p+q-1] mod MaxBuckets. *)
VAR h, i : INTEGER;
BEGIN
  h := 0;
  FOR i := 0 TO q - 1 DO
    h := (h * 31 + ORD(BioSeq.Get(text, p + i))) MOD MaxBuckets
  END;
  RETURN h
END HashSeq;

PROCEDURE HashStr(str: ARRAY OF CHAR; q: INTEGER): INTEGER;
(* Polynomial hash of str[0..q-1] mod MaxBuckets. *)
VAR h, i : INTEGER;
BEGIN
  h := 0;
  FOR i := 0 TO q - 1 DO
    h := (h * 31 + ORD(str[i])) MOD MaxBuckets
  END;
  RETURN h
END HashStr;

(* ------------------------------------------------------------------ *)
(*  Build                                                               *)
(* ------------------------------------------------------------------ *)

PROCEDURE Build*(text: BioSeq.Seq; q: INTEGER; VAR idx: QGramIndex);
(*
  Index all q-grams of text.  q is clamped to [1, MaxQ].
  After Build, Query returns positions for any q-gram in O(1) + bucket size.
*)
VAR i, h, n : INTEGER;
BEGIN
  IF q < 1    THEN q := 1    END;
  IF q > MaxQ THEN q := MaxQ END;
  idx.q       := q;
  idx.textLen := BioSeq.Length(text);
  n           := idx.textLen - q + 1;   (* number of q-grams *)

  (* Pass 1: count q-grams per bucket *)
  FOR h := 0 TO MaxBuckets - 1 DO cnt[h] := 0 END;
  IF n > 0 THEN
    FOR i := 0 TO n - 1 DO INC(cnt[HashSeq(text, i, q)]) END
  END;

  (* Build bucket start positions (prefix sum) *)
  idx.buckets[0] := 0;
  FOR h := 1 TO MaxBuckets - 1 DO idx.buckets[h] := idx.buckets[h - 1] + cnt[h - 1] END;
  IF n > 0 THEN
    idx.nPos := idx.buckets[MaxBuckets - 1] + cnt[MaxBuckets - 1]
  ELSE
    idx.nPos := 0
  END;

  (* Pass 2: fill pos array; reuse cnt as per-bucket offset *)
  FOR h := 0 TO MaxBuckets - 1 DO cnt[h] := 0 END;
  IF n > 0 THEN
    FOR i := 0 TO n - 1 DO
      h := HashSeq(text, i, q);
      idx.pos[idx.buckets[h] + cnt[h]] := i;
      INC(cnt[h])
    END
  END
END Build;

(* ------------------------------------------------------------------ *)
(*  Query                                                               *)
(* ------------------------------------------------------------------ *)

PROCEDURE Query*(VAR idx: QGramIndex; qgram: ARRAY OF CHAR;
                 VAR positions: ARRAY OF INTEGER; VAR n: INTEGER);
(*
  Return all text positions where a q-gram with the same hash as qgram occurs.
  n is set to the count written into positions (capped at LEN(positions)).
  Caller must verify exact match if hash collisions are a concern.
*)
VAR h, start, count, i : INTEGER;
BEGIN
  n := 0;
  IF Strings.Length(qgram) # idx.q THEN RETURN END;
  h     := HashStr(qgram, idx.q);
  start := idx.buckets[h];
  IF h < MaxBuckets - 1 THEN count := idx.buckets[h + 1] - start
  ELSE count := idx.nPos - start
  END;
  i := 0;
  WHILE (i < count) & (n < LEN(positions)) DO
    positions[n] := idx.pos[start + i];
    INC(n); INC(i)
  END
END Query;

(* ------------------------------------------------------------------ *)
(*  ApproxSearch                                                        *)
(* ------------------------------------------------------------------ *)

PROCEDURE ApproxSearch*(VAR idx: QGramIndex; pat: ARRAY OF CHAR;
                        maxDist: INTEGER; VAR hits: BioPattern.HitList);
(*
  Pigeonhole filter: for ≤ maxDist errors one of (maxDist+1) evenly-spaced
  q-grams must occur exactly in the text.  Returns candidate start positions
  with dist=0; verify with BioPattern.Ukkonen for exact edit distances.
*)
VAR
  m, q, piece, offset, h, start, count, k, j, p, tStart, di : INTEGER;
  dup : BOOLEAN;
BEGIN
  hits.count := 0;
  m := Strings.Length(pat);
  q := idx.q;
  IF (m = 0) OR (maxDist < 0) OR (q = 0) OR (m < q) THEN RETURN END;

  FOR piece := 0 TO maxDist DO
    offset := piece * (m DIV (maxDist + 1));
    IF offset + q > m THEN offset := m - q END;

    (* Hash pat[offset..offset+q-1] *)
    h := 0;
    FOR k := 0 TO q - 1 DO h := (h * 31 + ORD(pat[offset + k])) MOD MaxBuckets END;

    start := idx.buckets[h];
    IF h < MaxBuckets - 1 THEN count := idx.buckets[h + 1] - start
    ELSE count := idx.nPos - start
    END;

    FOR j := 0 TO count - 1 DO
      p      := idx.pos[start + j];
      tStart := p - offset;
      IF (tStart >= 0) & (tStart + m <= idx.textLen) THEN
        dup := FALSE;
        di  := 0;
        WHILE (di < hits.count) & ~dup DO
          IF hits.hits[di].pos = tStart THEN dup := TRUE END;
          INC(di)
        END;
        IF ~dup & (hits.count < BioPattern.MaxHits) THEN
          hits.hits[hits.count].pos  := tStart;
          hits.hits[hits.count].len  := m;
          hits.hits[hits.count].dist := 0;
          INC(hits.count)
        END
      END
    END
  END
END ApproxSearch;

END BioQGram.
