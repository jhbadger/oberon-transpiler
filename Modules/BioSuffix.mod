MODULE BioSuffix;
(*
  BioSuffix — Suffix array, BWT, LCP, and binary search on BioSeq sequences.

  Build:       prefix-doubling O(n log n) with two-pass radix sort.
               Appends a sentinel (0X) at position n; sa.n = text length + 1.
  BWT:         derived from suffix array in O(n).
  InverseBWT:  LF-mapping via counting sort in O(n).
  LCP:         Kasai's algorithm O(n).
  Search:      binary search O(m log n); sets half-open interval [lo, hi).

  All procedures share module-level scratch arrays; not re-entrant.
*)

IMPORT BioSeq, Strings;

CONST
  MaxSALen* = 65536;

TYPE
  SuffixArray* = RECORD
    sa* : ARRAY MaxSALen OF INTEGER;
    n*  : INTEGER
  END;

  BWTResult* = RECORD
    bwt* : ARRAY MaxSALen OF CHAR;
    n*   : INTEGER;
    eof* : INTEGER
  END;

VAR
  rank  : ARRAY MaxSALen OF INTEGER;
  tmp   : ARRAY MaxSALen OF INTEGER;
  cnt   : ARRAY MaxSALen OF INTEGER;
  sa2   : ARRAY MaxSALen OF INTEGER;
  lf    : ARRAY MaxSALen OF INTEGER;
  invSA : ARRAY MaxSALen OF INTEGER;

(* ------------------------------------------------------------------ *)
(*  Build                                                               *)
(* ------------------------------------------------------------------ *)

PROCEDURE Build*(text: BioSeq.Seq; VAR sa: SuffixArray);
VAR
  i, k, n, L, r, maxR, rPrev, rCurr : INTEGER;
  eq                                   : BOOLEAN;
BEGIN
  L := BioSeq.Length(text);
  IF L >= MaxSALen THEN L := MaxSALen - 1 END;
  n    := L + 1;
  sa.n := n;

  FOR i := 0 TO L - 1 DO rank[i] := ORD(BioSeq.Get(text, i)) END;
  rank[L] := 0;

  (* Initial counting sort by ORD value [0..255] *)
  FOR i := 0 TO 255 DO cnt[i] := 0 END;
  FOR i := 0 TO n - 1 DO INC(cnt[rank[i]]) END;
  FOR i := 1 TO 255 DO cnt[i] := cnt[i] + cnt[i - 1] END;
  FOR i := n - 1 TO 0 BY -1 DO
    DEC(cnt[rank[i]]);
    sa.sa[cnt[rank[i]]] := i
  END;

  (* Compute dense ranks 0..r from sort order *)
  r := 0;
  tmp[sa.sa[0]] := 0;
  FOR i := 1 TO n - 1 DO
    IF rank[sa.sa[i]] # rank[sa.sa[i - 1]] THEN INC(r) END;
    tmp[sa.sa[i]] := r
  END;
  FOR i := 0 TO n - 1 DO rank[i] := tmp[i] END;
  maxR := r;

  k := 1;
  WHILE (k < n) & (maxR < n - 1) DO
    (* Pass 1: stable sort by second key rank[i+k] (0 if i+k >= n) *)
    FOR i := 0 TO maxR DO cnt[i] := 0 END;
    FOR i := 0 TO n - 1 DO
      IF sa.sa[i] + k < n THEN INC(cnt[rank[sa.sa[i] + k]])
      ELSE INC(cnt[0])
      END
    END;
    FOR i := 1 TO maxR DO cnt[i] := cnt[i] + cnt[i - 1] END;
    FOR i := n - 1 TO 0 BY -1 DO
      IF sa.sa[i] + k < n THEN rCurr := rank[sa.sa[i] + k] ELSE rCurr := 0 END;
      DEC(cnt[rCurr]);
      sa2[cnt[rCurr]] := sa.sa[i]
    END;

    (* Pass 2: stable sort by first key rank[i] *)
    FOR i := 0 TO maxR DO cnt[i] := 0 END;
    FOR i := 0 TO n - 1 DO INC(cnt[rank[sa2[i]]]) END;
    FOR i := 1 TO maxR DO cnt[i] := cnt[i] + cnt[i - 1] END;
    FOR i := n - 1 TO 0 BY -1 DO
      rCurr := rank[sa2[i]];
      DEC(cnt[rCurr]);
      sa.sa[cnt[rCurr]] := sa2[i]
    END;

    (* Recompute ranks: equal rank iff both key pairs are identical *)
    r := 0;
    tmp[sa.sa[0]] := 0;
    FOR i := 1 TO n - 1 DO
      eq := (rank[sa.sa[i]] = rank[sa.sa[i - 1]]);
      IF eq THEN
        IF sa.sa[i - 1] + k < n THEN rPrev := rank[sa.sa[i - 1] + k] ELSE rPrev := 0 END;
        IF sa.sa[i]     + k < n THEN rCurr := rank[sa.sa[i]     + k] ELSE rCurr := 0 END;
        eq := (rCurr = rPrev)
      END;
      IF ~eq THEN INC(r) END;
      tmp[sa.sa[i]] := r
    END;
    FOR i := 0 TO n - 1 DO rank[i] := tmp[i] END;
    maxR := r;
    k    := k * 2
  END
END Build;

(* ------------------------------------------------------------------ *)
(*  BWT                                                                 *)
(* ------------------------------------------------------------------ *)

PROCEDURE BWT*(text: BioSeq.Seq; VAR sa: SuffixArray; VAR bwt: BWTResult);
(*
  bwt[i] = character preceding suffix sa[i] in the extended text.
  sa[i] = 0 means the full-text suffix; its preceding char is the sentinel 0X.
*)
VAR i, pos : INTEGER;
BEGIN
  bwt.n   := sa.n;
  bwt.eof := -1;
  FOR i := 0 TO sa.n - 1 DO
    pos := sa.sa[i];
    IF pos = 0 THEN
      bwt.bwt[i] := 0X;
      bwt.eof    := i
    ELSE
      bwt.bwt[i] := BioSeq.Get(text, pos - 1)
    END
  END
END BWT;

(* ------------------------------------------------------------------ *)
(*  InverseBWT                                                          *)
(* ------------------------------------------------------------------ *)

PROCEDURE InverseBWT*(VAR bwt: BWTResult; VAR text: BioSeq.Seq);
(*
  Reconstruct text from BWT using the LF-mapping.
  Row 0 of the BWT matrix corresponds to the sentinel suffix (smallest).
*)
VAR
  i, n, cur, c, bufLen : INTEGER;
  buf                   : ARRAY 240 OF CHAR;
BEGIN
  n := bwt.n;

  (* C[c] = number of BWT chars with ORD < c; build in cnt[0..255] *)
  FOR i := 0 TO 255 DO cnt[i] := 0 END;
  FOR i := 0 TO n - 1 DO INC(cnt[ORD(bwt.bwt[i])]) END;
  FOR i := 1 TO 255 DO cnt[i] := cnt[i] + cnt[i - 1] END;
  FOR i := 255 TO 1 BY -1 DO cnt[i] := cnt[i - 1] END;
  cnt[0] := 0;

  (* LF[i] = C[BWT[i]] + rank of BWT[i] among BWT[0..i-1] *)
  FOR i := 0 TO 255 DO rank[i] := 0 END;
  FOR i := 0 TO n - 1 DO
    c     := ORD(bwt.bwt[i]);
    lf[i] := cnt[c] + rank[c];
    INC(rank[c])
  END;

  (* Follow LF from row 0 backward; row 0 is the sentinel suffix *)
  cur := 0;
  FOR i := n - 2 TO 0 BY -1 DO
    tmp[i] := ORD(bwt.bwt[cur]);
    cur    := lf[cur]
  END;

  BioSeq.Free(text);
  BioSeq.New(text);
  bufLen := 0;
  FOR i := 0 TO n - 2 DO
    buf[bufLen] := CHR(tmp[i]);
    INC(bufLen);
    IF bufLen = 240 THEN
      BioSeq.Append(text, buf, bufLen);
      bufLen := 0
    END
  END;
  IF bufLen > 0 THEN BioSeq.Append(text, buf, bufLen) END
END InverseBWT;

(* ------------------------------------------------------------------ *)
(*  LCP                                                                 *)
(* ------------------------------------------------------------------ *)

PROCEDURE LCP*(text: BioSeq.Seq; VAR sa: SuffixArray; VAR lcp: ARRAY OF INTEGER);
(*
  Compute the LCP array via Kasai's algorithm.
  lcp[i] = length of longest common prefix between sa[i] and sa[i-1].
  lcp[0] = 0 by convention.
  The caller's lcp array must have at least sa.n entries.
*)
VAR
  i, j, h, n, r : INTEGER;
BEGIN
  n := sa.n;
  FOR i := 0 TO n - 1 DO invSA[sa.sa[i]] := i END;
  h := 0;
  FOR i := 0 TO n - 1 DO
    r := invSA[i];
    IF r > 0 THEN
      j := sa.sa[r - 1];
      WHILE (i + h < n) & (j + h < n) &
            (BioSeq.Get(text, i + h) = BioSeq.Get(text, j + h)) DO
        INC(h)
      END;
      lcp[r] := h;
      IF h > 0 THEN DEC(h) END
    ELSE
      lcp[0] := 0
    END
  END
END LCP;

(* ------------------------------------------------------------------ *)
(*  Search                                                              *)
(* ------------------------------------------------------------------ *)

PROCEDURE Search*(text: BioSeq.Seq; VAR sa: SuffixArray; pat: ARRAY OF CHAR;
                  VAR lo, hi: INTEGER): BOOLEAN;
(*
  Binary search for all occurrences of pat as a prefix of a suffix.
  Sets [lo, hi) to the matching interval in the suffix array.
  Returns TRUE iff any match exists.
*)
VAR
  m, lo1, hi1, mid, i, cmp : INTEGER;
BEGIN
  m   := Strings.Length(pat);
  lo1 := 0;
  hi1 := sa.n;

  (* Lower bound: first index where suffix >= pat *)
  WHILE lo1 < hi1 DO
    mid := (lo1 + hi1) DIV 2;
    i   := 0;
    WHILE (i < m) & (BioSeq.Get(text, sa.sa[mid] + i) = pat[i]) DO INC(i) END;
    IF    i = m                                            THEN cmp :=  0
    ELSIF BioSeq.Get(text, sa.sa[mid] + i) < pat[i]       THEN cmp := -1
    ELSE                                                        cmp :=  1
    END;
    IF cmp < 0 THEN lo1 := mid + 1 ELSE hi1 := mid END
  END;
  lo := lo1;

  (* Upper bound: first index where suffix does not start with pat *)
  hi1 := sa.n;
  WHILE lo1 < hi1 DO
    mid := (lo1 + hi1) DIV 2;
    i   := 0;
    WHILE (i < m) & (BioSeq.Get(text, sa.sa[mid] + i) = pat[i]) DO INC(i) END;
    IF    i = m                                            THEN cmp :=  0
    ELSIF BioSeq.Get(text, sa.sa[mid] + i) < pat[i]       THEN cmp := -1
    ELSE                                                        cmp :=  1
    END;
    IF cmp <= 0 THEN lo1 := mid + 1 ELSE hi1 := mid END
  END;
  hi := hi1;

  RETURN lo < hi
END Search;

END BioSuffix.
