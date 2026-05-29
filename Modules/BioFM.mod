MODULE BioFM;
(*
  BioFM — FM-Index: backward search, locate, and count.

  Build constructs the index from a BioSeq in O(n log n).
  BackwardSearch runs O(m) queries against the sampled Occ table.
  Locate converts an SA interval to text positions in O(hi-lo).
  Count returns the number of occurrences in O(m).

  OccTable.data is ARRAY 128 OF ARRAY 4096 OF INTEGER = 2 MB.
  FMIndex also embeds BWTResult (~64 KB) and SuffixArray (~256 KB).
  Total: ~2.3 MB — declare FMIndex at module level, not as a local.
*)

IMPORT BioSeq, BioAlpha, BioSuffix, Strings;

CONST
  OccSample*  = 16;
  MaxOccRows  = 4096;   (* BioSuffix.MaxSALen DIV OccSample = 65536 DIV 16 *)

TYPE
  LessTable* = RECORD
    val* : ARRAY 128 OF INTEGER
  END;

  OccTable* = RECORD
    nSymbols* : INTEGER;
    nRows*    : INTEGER;
    sample*   : INTEGER;
    data*     : ARRAY 128 OF ARRAY MaxOccRows OF INTEGER
    (* data[c][i] = occurrences of ORD c in bwt[0..i*sample) *)
  END;

  FMIndex* = RECORD
    bwt*  : BioSuffix.BWTResult;
    sa*   : BioSuffix.SuffixArray;
    less* : LessTable;
    occ*  : OccTable;
    n*    : INTEGER
  END;

(* ------------------------------------------------------------------ *)
(*  Internal: sampled occurrence count                                  *)
(* ------------------------------------------------------------------ *)

PROCEDURE OccCount(VAR idx: FMIndex; c, k: INTEGER): INTEGER;
(* Count occurrences of char code c in idx.bwt.bwt[0..k). *)
VAR base, count, j : INTEGER;
BEGIN
  IF k <= 0 THEN RETURN 0 END;
  base := k DIV OccSample;
  IF base >= idx.occ.nRows THEN base := idx.occ.nRows - 1 END;
  count := idx.occ.data[c][base];
  j := base * OccSample;
  WHILE j < k DO
    IF ORD(idx.bwt.bwt[j]) = c THEN INC(count) END;
    INC(j)
  END;
  RETURN count
END OccCount;

(* ------------------------------------------------------------------ *)
(*  Build                                                               *)
(* ------------------------------------------------------------------ *)

PROCEDURE Build*(text: BioSeq.Seq; VAR a: BioAlpha.Alphabet; VAR idx: FMIndex);
(*
  Construct the FM-Index for text.
  Calls BioSuffix.Build and BioSuffix.BWT internally, then builds
  the Less and sampled Occ tables.
  The alphabet parameter a is accepted for interface consistency;
  the index operates on raw ORD values 0..127.
*)
VAR
  i, c, ch, n, nRows, j : INTEGER;
  cnt                     : ARRAY 128 OF INTEGER;
BEGIN
  BioSuffix.Build(text, idx.sa);
  BioSuffix.BWT(text, idx.sa, idx.bwt);
  n     := idx.sa.n;
  idx.n := n;

  (* Less table: less.val[c] = # BWT chars with ORD strictly less than c *)
  FOR c := 0 TO 127 DO cnt[c] := 0 END;
  FOR i := 0 TO n - 1 DO
    ch := ORD(idx.bwt.bwt[i]);
    IF (ch >= 0) & (ch < 128) THEN INC(cnt[ch]) END
  END;
  idx.less.val[0] := 0;
  FOR c := 1 TO 127 DO idx.less.val[c] := idx.less.val[c - 1] + cnt[c - 1] END;

  (* Occ table: data[c][0] = 0; data[c][i] = count of c in bwt[0..i*OccSample) *)
  nRows := n DIV OccSample;
  IF nRows > MaxOccRows THEN nRows := MaxOccRows END;
  IF nRows < 1          THEN nRows := 1          END;
  idx.occ.nSymbols := 128;
  idx.occ.nRows    := nRows;
  idx.occ.sample   := OccSample;

  FOR c := 0 TO 127 DO idx.occ.data[c][0] := 0 END;
  FOR i := 1 TO nRows - 1 DO
    FOR c := 0 TO 127 DO idx.occ.data[c][i] := idx.occ.data[c][i - 1] END;
    j := (i - 1) * OccSample;
    WHILE j < i * OccSample DO
      IF j < n THEN
        ch := ORD(idx.bwt.bwt[j]);
        IF (ch >= 0) & (ch < 128) THEN INC(idx.occ.data[ch][i]) END
      END;
      INC(j)
    END
  END
END Build;

(* ------------------------------------------------------------------ *)
(*  BackwardSearch                                                      *)
(* ------------------------------------------------------------------ *)

PROCEDURE BackwardSearch*(VAR idx: FMIndex; pat: ARRAY OF CHAR;
                           VAR lo, hi: INTEGER): BOOLEAN;
(*
  Standard FM backward search: scan pat right-to-left, contracting
  the SA interval [lo, hi) at each step.
  Returns TRUE and sets [lo, hi) iff at least one occurrence exists.
*)
VAR
  i, m, c : INTEGER;
  ok       : BOOLEAN;
BEGIN
  m  := Strings.Length(pat);
  lo := 0;
  hi := idx.n;
  ok := TRUE;
  i  := m - 1;
  WHILE ok & (i >= 0) DO
    c := ORD(pat[i]);
    IF c >= 128 THEN
      ok := FALSE
    ELSE
      lo := idx.less.val[c] + OccCount(idx, c, lo);
      hi := idx.less.val[c] + OccCount(idx, c, hi);
      IF lo >= hi THEN ok := FALSE END
    END;
    DEC(i)
  END;
  RETURN ok & (lo < hi)
END BackwardSearch;

(* ------------------------------------------------------------------ *)
(*  Locate                                                              *)
(* ------------------------------------------------------------------ *)

PROCEDURE Locate*(VAR idx: FMIndex; lo, hi: INTEGER;
                  VAR positions: ARRAY OF INTEGER; VAR nPos: INTEGER);
(*
  Convert SA interval [lo, hi) to text positions.
  Writes at most LEN(positions) results; sets nPos to the count written.
*)
VAR i : INTEGER;
BEGIN
  nPos := 0;
  FOR i := lo TO hi - 1 DO
    IF nPos < LEN(positions) THEN
      positions[nPos] := idx.sa.sa[i];
      INC(nPos)
    END
  END
END Locate;

(* ------------------------------------------------------------------ *)
(*  Count                                                               *)
(* ------------------------------------------------------------------ *)

PROCEDURE Count*(VAR idx: FMIndex; pat: ARRAY OF CHAR): INTEGER;
(* Return the number of occurrences of pat in the indexed text. *)
VAR lo, hi : INTEGER;
BEGIN
  IF BackwardSearch(idx, pat, lo, hi) THEN
    RETURN hi - lo
  ELSE
    RETURN 0
  END
END Count;

END BioFM.
