MODULE BioAlign;
(*
  BioAlign — Pairwise sequence alignment.

  Implements Needleman-Wunsch (global), Smith-Waterman (local), semi-global,
  Levenshtein edit distance, and Hamming distance.

  All three DP-based aligners use affine gap penalties (gapOpen + gapExt) and
  three score layers (M = aligned pair, X = gap in reference, Y = gap in query).

  DP matrices are module-level to avoid stack overflow; only one alignment may
  run at a time.  MaxSeqLen caps both query and reference length.
*)

IMPORT BioSeq, Math, Out;

CONST
  MaxSeqLen* = 1024;
  MaxCigar*  = 8192;
  Stride     = MaxSeqLen + 1;
  MaxAligned  = 2 * MaxSeqLen + 2;
  PrintWidth  = 60;

  opMatch* = 0;
  opIns*   = 1;   (* gap in reference: query has extra base *)
  opDel*   = 2;   (* gap in query: reference has extra base *)
  opSubst* = 3;

  NEG_INF = -1000000;

  (* Traceback source codes stored in tb arrays *)
  tbFromM = 0;
  tbFromX = 1;
  tbFromY = 2;
  tbStart = -1;   (* SW local-alignment start sentinel *)

TYPE
  ScoreMatrix* = RECORD
    match_*   : INTEGER;
    mismatch* : INTEGER;
    gapOpen*  : INTEGER;
    gapExt*   : INTEGER
  END;

  CigarEntry* = RECORD
    op*  : INTEGER;
    len* : INTEGER
  END;

  Alignment* = RECORD
    score*          : INTEGER;
    qStart*, qEnd*  : INTEGER;
    rStart*, rEnd*  : INTEGER;
    cigar*          : ARRAY MaxCigar OF CigarEntry;
    nOps*           : INTEGER;
    identity*       : REAL
  END;

(* Module-level DP storage — shared across all alignment procedures. *)
VAR
  dpM, dpX, dpY  : ARRAY Stride, Stride OF INTEGER;
  tbM, tbX, tbY  : ARRAY Stride, Stride OF INTEGER;
  edPrev, edCurr : ARRAY Stride OF INTEGER;
  pqAln, prAln, pbar : ARRAY MaxAligned OF CHAR;   (* PrintAlignment buffers *)

(* ------------------------------------------------------------------ *)
(*  Public: scoring setup                                               *)
(* ------------------------------------------------------------------ *)

PROCEDURE DefaultScore*(VAR m: ScoreMatrix);
BEGIN
  m.match_   :=  1;
  m.mismatch := -1;
  m.gapOpen  := -5;
  m.gapExt   := -1
END DefaultScore;

(* ------------------------------------------------------------------ *)
(*  Internal helpers                                                    *)
(* ------------------------------------------------------------------ *)

PROCEDURE PairScore(VAR m: ScoreMatrix; a, b: CHAR): INTEGER;
BEGIN
  IF a = b THEN RETURN m.match_ ELSE RETURN m.mismatch END
END PairScore;

PROCEDURE AppendCigar(VAR aln: Alignment; op: INTEGER);
BEGIN
  IF (aln.nOps > 0) & (aln.cigar[aln.nOps - 1].op = op) THEN
    INC(aln.cigar[aln.nOps - 1].len)
  ELSE
    ASSERT(aln.nOps < MaxCigar);
    aln.cigar[aln.nOps].op  := op;
    aln.cigar[aln.nOps].len := 1;
    INC(aln.nOps)
  END
END AppendCigar;

PROCEDURE ReverseCigar(VAR aln: Alignment);
VAR lo, hi: INTEGER; tmp: CigarEntry;
BEGIN
  lo := 0;  hi := aln.nOps - 1;
  WHILE lo < hi DO
    tmp           := aln.cigar[lo];
    aln.cigar[lo] := aln.cigar[hi];
    aln.cigar[hi] := tmp;
    INC(lo);  DEC(hi)
  END
END ReverseCigar;

PROCEDURE CalcIdentity(VAR aln: Alignment; q, r: BioSeq.Seq);
VAR matches, aligned, k, p, qi, ri: INTEGER;
BEGIN
  matches := 0;  aligned := 0;
  qi := aln.qStart;  ri := aln.rStart;
  FOR k := 0 TO aln.nOps - 1 DO
    FOR p := 0 TO aln.cigar[k].len - 1 DO
      IF aln.cigar[k].op = opMatch THEN
        INC(matches);  INC(aligned);  INC(qi);  INC(ri)
      ELSIF aln.cigar[k].op = opSubst THEN
        INC(aligned);  INC(qi);  INC(ri)
      ELSIF aln.cigar[k].op = opIns THEN
        INC(aligned);  INC(qi)
      ELSE
        INC(aligned);  INC(ri)
      END
    END
  END;
  IF aligned > 0 THEN
    aln.identity := FLT(matches) / FLT(aligned)
  ELSE
    aln.identity := 0.0
  END
END CalcIdentity;

(* ------------------------------------------------------------------ *)
(*  Global — Needleman-Wunsch with affine gap penalties                *)
(* ------------------------------------------------------------------ *)

PROCEDURE Global*(q, r: BioSeq.Seq; VAR m: ScoreMatrix; VAR aln: Alignment);
VAR
  qLen, rLen     : INTEGER;
  i, j, best, s  : INTEGER;
  layer           : INTEGER;
BEGIN
  qLen := BioSeq.Length(q);
  rLen := BioSeq.Length(r);
  ASSERT(qLen <= MaxSeqLen);
  ASSERT(rLen <= MaxSeqLen);

  (* --- Initialisation --- *)
  dpM[0, 0] := 0;  dpX[0, 0] := NEG_INF;  dpY[0, 0] := NEG_INF;

  FOR i := 1 TO qLen DO
    dpM[i, 0] := NEG_INF;
    dpX[i, 0] := m.gapOpen + i * m.gapExt;
    dpY[i, 0] := NEG_INF;
    tbX[i, 0] := tbFromX
  END;

  FOR j := 1 TO rLen DO
    dpM[0, j] := NEG_INF;
    dpX[0, j] := NEG_INF;
    dpY[0, j] := m.gapOpen + j * m.gapExt;
    tbY[0, j] := tbFromY
  END;

  (* --- Fill --- *)
  FOR i := 1 TO qLen DO
    FOR j := 1 TO rLen DO
      s := PairScore(m, BioSeq.Get(q, i - 1), BioSeq.Get(r, j - 1));

      (* M layer: align q[i-1] with r[j-1] *)
      best := dpM[i - 1, j - 1];  tbM[i, j] := tbFromM;
      IF dpX[i - 1, j - 1] > best THEN best := dpX[i - 1, j - 1];  tbM[i, j] := tbFromX END;
      IF dpY[i - 1, j - 1] > best THEN best := dpY[i - 1, j - 1];  tbM[i, j] := tbFromY END;
      dpM[i, j] := best + s;

      (* X layer: gap in reference (insert into query) *)
      IF dpM[i - 1, j] + m.gapOpen >= dpX[i - 1, j] + m.gapExt THEN
        dpX[i, j] := dpM[i - 1, j] + m.gapOpen;  tbX[i, j] := tbFromM
      ELSE
        dpX[i, j] := dpX[i - 1, j] + m.gapExt;   tbX[i, j] := tbFromX
      END;

      (* Y layer: gap in query (delete from query) *)
      IF dpM[i, j - 1] + m.gapOpen >= dpY[i, j - 1] + m.gapExt THEN
        dpY[i, j] := dpM[i, j - 1] + m.gapOpen;  tbY[i, j] := tbFromM
      ELSE
        dpY[i, j] := dpY[i, j - 1] + m.gapExt;   tbY[i, j] := tbFromY
      END
    END
  END;

  (* --- Pick best terminal layer --- *)
  aln.score := dpM[qLen, rLen];  layer := tbFromM;
  IF dpX[qLen, rLen] > aln.score THEN aln.score := dpX[qLen, rLen];  layer := tbFromX END;
  IF dpY[qLen, rLen] > aln.score THEN aln.score := dpY[qLen, rLen];  layer := tbFromY END;

  aln.qEnd   := qLen;  aln.rEnd   := rLen;
  aln.qStart := 0;     aln.rStart := 0;
  aln.nOps   := 0;

  (* --- Traceback from bottom-right corner --- *)
  i := qLen;  j := rLen;
  WHILE (i > 0) OR (j > 0) DO
    IF layer = tbFromM THEN
      IF BioSeq.Get(q, i - 1) = BioSeq.Get(r, j - 1) THEN
        AppendCigar(aln, opMatch)
      ELSE
        AppendCigar(aln, opSubst)
      END;
      layer := tbM[i, j];  DEC(i);  DEC(j)
    ELSIF layer = tbFromX THEN
      AppendCigar(aln, opIns);
      layer := tbX[i, j];  DEC(i)
    ELSE
      AppendCigar(aln, opDel);
      layer := tbY[i, j];  DEC(j)
    END
  END;

  ReverseCigar(aln);
  CalcIdentity(aln, q, r)
END Global;

(* ------------------------------------------------------------------ *)
(*  Local — Smith-Waterman with affine gap penalties                   *)
(* ------------------------------------------------------------------ *)

PROCEDURE Local*(q, r: BioSeq.Seq; VAR m: ScoreMatrix; VAR aln: Alignment);
VAR
  qLen, rLen       : INTEGER;
  i, j, best, s    : INTEGER;
  bestI, bestJ      : INTEGER;
  layer             : INTEGER;
BEGIN
  qLen := BioSeq.Length(q);
  rLen := BioSeq.Length(r);
  ASSERT(qLen <= MaxSeqLen);
  ASSERT(rLen <= MaxSeqLen);

  (* --- Initialisation: zeros allow local alignment to start anywhere --- *)
  FOR i := 0 TO qLen DO
    dpM[i, 0] := 0;  dpX[i, 0] := 0;  dpY[i, 0] := 0
  END;
  FOR j := 0 TO rLen DO
    dpM[0, j] := 0;  dpX[0, j] := 0;  dpY[0, j] := 0
  END;

  aln.score := 0;  bestI := 0;  bestJ := 0;

  (* --- Fill --- *)
  FOR i := 1 TO qLen DO
    FOR j := 1 TO rLen DO
      s := PairScore(m, BioSeq.Get(q, i - 1), BioSeq.Get(r, j - 1));

      (* M layer *)
      best := dpM[i - 1, j - 1];  tbM[i, j] := tbFromM;
      IF dpX[i - 1, j - 1] > best THEN best := dpX[i - 1, j - 1];  tbM[i, j] := tbFromX END;
      IF dpY[i - 1, j - 1] > best THEN best := dpY[i - 1, j - 1];  tbM[i, j] := tbFromY END;
      best := best + s;
      IF best <= 0 THEN
        dpM[i, j] := 0;  tbM[i, j] := tbStart
      ELSE
        dpM[i, j] := best
      END;

      (* X layer: gap in reference *)
      best := dpM[i - 1, j] + m.gapOpen;
      IF dpX[i - 1, j] + m.gapExt > best THEN
        best := dpX[i - 1, j] + m.gapExt;  tbX[i, j] := tbFromX
      ELSE
        tbX[i, j] := tbFromM
      END;
      IF best < 0 THEN best := 0 END;
      dpX[i, j] := best;

      (* Y layer: gap in query *)
      best := dpM[i, j - 1] + m.gapOpen;
      IF dpY[i, j - 1] + m.gapExt > best THEN
        best := dpY[i, j - 1] + m.gapExt;  tbY[i, j] := tbFromY
      ELSE
        tbY[i, j] := tbFromM
      END;
      IF best < 0 THEN best := 0 END;
      dpY[i, j] := best;

      IF dpM[i, j] > aln.score THEN
        aln.score := dpM[i, j];  bestI := i;  bestJ := j
      END
    END
  END;

  aln.qEnd := bestI;  aln.rEnd := bestJ;
  aln.nOps := 0;      layer := tbFromM;

  (* --- Traceback from best cell, stop at zero --- *)
  i := bestI;  j := bestJ;
  WHILE (i > 0) & (j > 0) & (dpM[i, j] > 0) DO
    IF layer = tbFromM THEN
      IF tbM[i, j] = tbStart THEN
        (* reached local start: consume this aligned pair then stop *)
        IF BioSeq.Get(q, i - 1) = BioSeq.Get(r, j - 1) THEN
          AppendCigar(aln, opMatch)
        ELSE
          AppendCigar(aln, opSubst)
        END;
        DEC(i);  DEC(j);
        (* force loop exit *)
        j := 0
      ELSE
        IF BioSeq.Get(q, i - 1) = BioSeq.Get(r, j - 1) THEN
          AppendCigar(aln, opMatch)
        ELSE
          AppendCigar(aln, opSubst)
        END;
        layer := tbM[i, j];  DEC(i);  DEC(j)
      END
    ELSIF layer = tbFromX THEN
      AppendCigar(aln, opIns);
      layer := tbX[i, j];  DEC(i)
    ELSE
      AppendCigar(aln, opDel);
      layer := tbY[i, j];  DEC(j)
    END
  END;

  aln.qStart := i;  aln.rStart := j;
  ReverseCigar(aln);
  CalcIdentity(aln, q, r)
END Local;

(* ------------------------------------------------------------------ *)
(*  SemiGlobal — query free end-gaps                                   *)
(*  Query may overhang either end of the reference at no penalty.      *)
(* ------------------------------------------------------------------ *)

PROCEDURE SemiGlobal*(q, r: BioSeq.Seq; VAR m: ScoreMatrix; VAR aln: Alignment);
VAR
  qLen, rLen     : INTEGER;
  i, j, best, s  : INTEGER;
  bestJ, layer    : INTEGER;
BEGIN
  qLen := BioSeq.Length(q);
  rLen := BioSeq.Length(r);
  ASSERT(qLen <= MaxSeqLen);
  ASSERT(rLen <= MaxSeqLen);

  (* --- Initialisation --- *)
  dpM[0, 0] := 0;  dpX[0, 0] := NEG_INF;  dpY[0, 0] := NEG_INF;

  FOR i := 1 TO qLen DO
    dpM[i, 0] := NEG_INF;
    dpX[i, 0] := m.gapOpen + i * m.gapExt;
    dpY[i, 0] := NEG_INF;
    tbX[i, 0] := tbFromX
  END;

  (* First row free: no penalty for reference advancing before query starts *)
  FOR j := 1 TO rLen DO
    dpM[0, j] := NEG_INF;
    dpX[0, j] := NEG_INF;
    dpY[0, j] := 0;
    tbY[0, j] := tbFromY
  END;

  (* --- Fill: identical recurrence to Global --- *)
  FOR i := 1 TO qLen DO
    FOR j := 1 TO rLen DO
      s := PairScore(m, BioSeq.Get(q, i - 1), BioSeq.Get(r, j - 1));

      best := dpM[i - 1, j - 1];  tbM[i, j] := tbFromM;
      IF dpX[i - 1, j - 1] > best THEN best := dpX[i - 1, j - 1];  tbM[i, j] := tbFromX END;
      IF dpY[i - 1, j - 1] > best THEN best := dpY[i - 1, j - 1];  tbM[i, j] := tbFromY END;
      dpM[i, j] := best + s;

      IF dpM[i - 1, j] + m.gapOpen >= dpX[i - 1, j] + m.gapExt THEN
        dpX[i, j] := dpM[i - 1, j] + m.gapOpen;  tbX[i, j] := tbFromM
      ELSE
        dpX[i, j] := dpX[i - 1, j] + m.gapExt;   tbX[i, j] := tbFromX
      END;

      IF dpM[i, j - 1] + m.gapOpen >= dpY[i, j - 1] + m.gapExt THEN
        dpY[i, j] := dpM[i, j - 1] + m.gapOpen;  tbY[i, j] := tbFromM
      ELSE
        dpY[i, j] := dpY[i, j - 1] + m.gapExt;   tbY[i, j] := tbFromY
      END
    END
  END;

  (* --- Best score in last row: free trailing gap in reference --- *)
  aln.score := dpM[qLen, 1];  bestJ := 1;  layer := tbFromM;
  FOR j := 2 TO rLen DO
    IF dpM[qLen, j] > aln.score THEN
      aln.score := dpM[qLen, j];  bestJ := j;  layer := tbFromM
    END
  END;
  FOR j := 1 TO rLen DO
    IF dpX[qLen, j] > aln.score THEN
      aln.score := dpX[qLen, j];  bestJ := j;  layer := tbFromX
    END
  END;

  aln.qEnd   := qLen;  aln.rEnd   := bestJ;
  aln.qStart := 0;     aln.rStart := 0;
  aln.nOps   := 0;

  (* --- Traceback --- *)
  i := qLen;  j := bestJ;
  WHILE (i > 0) OR (j > 0) DO
    IF i = 0 THEN
      (* remaining reference: free leading overhang, done *)
      aln.rStart := j;
      j := 0
    ELSIF layer = tbFromM THEN
      IF BioSeq.Get(q, i - 1) = BioSeq.Get(r, j - 1) THEN
        AppendCigar(aln, opMatch)
      ELSE
        AppendCigar(aln, opSubst)
      END;
      layer := tbM[i, j];  DEC(i);  DEC(j)
    ELSIF layer = tbFromX THEN
      AppendCigar(aln, opIns);
      layer := tbX[i, j];  DEC(i)
    ELSE
      AppendCigar(aln, opDel);
      layer := tbY[i, j];  DEC(j)
    END
  END;

  ReverseCigar(aln);
  CalcIdentity(aln, q, r)
END SemiGlobal;

(* ------------------------------------------------------------------ *)
(*  EditDistance — Levenshtein (unit costs, O(n) space)               *)
(* ------------------------------------------------------------------ *)

PROCEDURE EditDistance*(q, r: BioSeq.Seq): INTEGER;
VAR
  qLen, rLen     : INTEGER;
  i, j           : INTEGER;
  diag, del, ins : INTEGER;
  tmp            : ARRAY Stride OF INTEGER;
BEGIN
  qLen := BioSeq.Length(q);
  rLen := BioSeq.Length(r);
  ASSERT(qLen <= MaxSeqLen);
  ASSERT(rLen <= MaxSeqLen);

  FOR j := 0 TO rLen DO edPrev[j] := j END;

  FOR i := 1 TO qLen DO
    edCurr[0] := i;
    FOR j := 1 TO rLen DO
      IF BioSeq.Get(q, i - 1) = BioSeq.Get(r, j - 1) THEN
        diag := edPrev[j - 1]
      ELSE
        diag := edPrev[j - 1] + 1
      END;
      del := edPrev[j] + 1;
      ins := edCurr[j - 1] + 1;
      edCurr[j] := Math.min(diag, Math.min(del, ins))
    END;
    FOR j := 0 TO rLen DO edPrev[j] := edCurr[j] END
  END;
  RETURN edPrev[rLen]
END EditDistance;

(* ------------------------------------------------------------------ *)
(*  HammingDistance — equal-length sequences only                      *)
(* ------------------------------------------------------------------ *)

PROCEDURE HammingDistance*(q, r: BioSeq.Seq): INTEGER;
VAR i, dist, qLen: INTEGER;
BEGIN
  qLen := BioSeq.Length(q);
  IF qLen # BioSeq.Length(r) THEN RETURN -1 END;
  dist := 0;
  FOR i := 0 TO qLen - 1 DO
    IF BioSeq.Get(q, i) # BioSeq.Get(r, i) THEN INC(dist) END
  END;
  RETURN dist
END HammingDistance;

(* ------------------------------------------------------------------ *)
(*  PrintAlignment — pretty-print to stdout in 60-column blocks        *)
(* ------------------------------------------------------------------ *)

PROCEDURE PrintAlignment*(VAR aln: Alignment; q, r: BioSeq.Seq);
VAR
  pos, k, p, qi, ri, alen, stop : INTEGER;
BEGIN
  qi  := aln.qStart;
  ri  := aln.rStart;
  pos := 0;

  FOR k := 0 TO aln.nOps - 1 DO
    FOR p := 0 TO aln.cigar[k].len - 1 DO
      IF aln.cigar[k].op = opMatch THEN
        pqAln[pos] := BioSeq.Get(q, qi);
        prAln[pos] := BioSeq.Get(r, ri);
        pbar[pos]  := '|';
        INC(qi);  INC(ri)
      ELSIF aln.cigar[k].op = opSubst THEN
        pqAln[pos] := BioSeq.Get(q, qi);
        prAln[pos] := BioSeq.Get(r, ri);
        pbar[pos]  := '.';
        INC(qi);  INC(ri)
      ELSIF aln.cigar[k].op = opIns THEN
        pqAln[pos] := BioSeq.Get(q, qi);
        prAln[pos] := '-';
        pbar[pos]  := ' ';
        INC(qi)
      ELSE
        pqAln[pos] := '-';
        prAln[pos] := BioSeq.Get(r, ri);
        pbar[pos]  := ' ';
        INC(ri)
      END;
      INC(pos)
    END
  END;
  alen := pos;

  Out.String("Score:    "); Out.Int(aln.score, 0);                  Out.Ln;
  Out.String("Identity: "); Out.Fixed(aln.identity * 100.0, 0, 2);
  Out.Char('%');                                                     Out.Ln;
  Out.String("Query:    "); Out.Int(aln.qStart, 0);
  Out.String(" - ");        Out.Int(aln.qEnd, 0);                   Out.Ln;
  Out.String("Target:   "); Out.Int(aln.rStart, 0);
  Out.String(" - ");        Out.Int(aln.rEnd, 0);                   Out.Ln;
  Out.Ln;

  pos := 0;
  WHILE pos < alen DO
    stop := pos + PrintWidth - 1;
    IF stop >= alen THEN stop := alen - 1 END;

    Out.String("Query  ");
    FOR k := pos TO stop DO Out.Char(pqAln[k]) END;
    Out.Ln;

    Out.String("       ");
    FOR k := pos TO stop DO Out.Char(pbar[k]) END;
    Out.Ln;

    Out.String("Target ");
    FOR k := pos TO stop DO Out.Char(prAln[k]) END;
    Out.Ln;
    Out.Ln;

    INC(pos, PrintWidth)
  END
END PrintAlignment;

END BioAlign.
