MODULE SeqBlast;
(*
  SeqBlast — BLAST-like local alignment search with gapped extension.

  Algorithm:
    1. Load query; extract every W-mer (default W=11).
    2. For each subject in the database, build a BM index per W-mer
       and collect exact seed hits.
    3. Extend each seed left/right with ungapped X-drop scoring.
    4. Run affine-gap Needleman-Wunsch on each ungapped HSP region
       (capped at MaxAlnRegion per axis) to produce the gapped alignment.
    5. Filter by E-value <= threshold; deduplicate overlapping HSPs.
    6. Print tabular (-outfmt 6 style) or pairwise (-aln) output.

  E-value uses Karlin-Altschul statistics.
    Lambda = 0.318, K = 0.130 (match=1, mismatch=-3, DNA).
    K-A values are approximate; they assume ungapped statistics.
    Bit score = (Lambda * rawScore - ln(K)) / ln(2).
    E-value   = qLen * sLen * 2^(-bitScore).
*)

IMPORT BioIO, BioSeq, BioAlpha, BioPattern, Out, Args, Strings, Math, Parallel;

CONST
  MaxHSPs      = 512;
  MaxBlastWorkers = 8;  (* parallel subject sequences; each needs ~9 MB workspace *)
  MaxQLen      = 65536;
  MaxW         = 32;
  MaxAlnRegion = 512;               (* max region length per axis for gapped NW *)
  MaxAlnStr    = MaxAlnRegion * 2 + 2;  (* max alignment string (includes gaps) *)

  Lambda  = 0.318;
  KStat   = 0.130;

TYPE
  HSPRec = RECORD
    qStart, qEnd : INTEGER;
    sStart, sEnd : INTEGER;
    rawScore     : INTEGER;
    nIdent       : INTEGER;
    nMismatch    : INTEGER;
    nGapOpen     : INTEGER;
    aLen         : INTEGER;   (* total alignment length including gaps *)
    alnStr       : INTEGER;   (* length of qAln/sAln/mAln strings *)
    qAln         : ARRAY MaxAlnStr OF CHAR;
    sAln         : ARRAY MaxAlnStr OF CHAR;
    mAln         : ARRAY MaxAlnStr OF CHAR
  END;

VAR
  wordSize  : INTEGER;
  eThresh   : REAL;
  matchScr  : INTEGER;
  mmScr     : INTEGER;
  xDrop     : INTEGER;
  gapOpen   : INTEGER;   (* gap-open penalty, negative (default -5)  *)
  gapExt    : INTEGER;   (* gap-extend penalty, negative (default -2) *)
  alnMode   : BOOLEAN;
  queryFile : ARRAY 1024 OF CHAR;
  dbFile    : ARRAY 1024 OF CHAR;

  hspList   : ARRAY MaxHSPs OF HSPRec;
  hspCount  : INTEGER;

  queryBuf  : ARRAY MaxQLen OF CHAR;
  queryLen  : INTEGER;

  (* DP and traceback tables for GappedAlign — global to stay off the stack *)
  dpM, dpIX, dpIY : ARRAY MaxAlnRegion+1 OF ARRAY MaxAlnRegion+1 OF INTEGER;
  tbM, tbIX, tbIY : ARRAY MaxAlnRegion+1 OF ARRAY MaxAlnRegion+1 OF INTEGER;

(* Per-worker workspace for parallel database search. *)
VAR
  wkSubjSeq  : ARRAY MaxBlastWorkers OF BioSeq.Seq;
  wkSubjName : ARRAY MaxBlastWorkers OF ARRAY 256 OF CHAR;
  wkSubjLen  : ARRAY MaxBlastWorkers OF INTEGER;
  wkRcSeq    : ARRAY MaxBlastWorkers OF BioSeq.Seq;
  wkHspListP : ARRAY MaxBlastWorkers OF ARRAY MaxHSPs OF HSPRec;
  wkHspCntP  : ARRAY MaxBlastWorkers OF INTEGER;
  wkHspListM : ARRAY MaxBlastWorkers OF ARRAY MaxHSPs OF HSPRec;
  wkHspCntM  : ARRAY MaxBlastWorkers OF INTEGER;
  wkDpM, wkDpIX, wkDpIY : ARRAY MaxBlastWorkers OF ARRAY MaxAlnRegion+1 OF ARRAY MaxAlnRegion+1 OF INTEGER;
  wkTbM, wkTbIX, wkTbIY : ARRAY MaxBlastWorkers OF ARRAY MaxAlnRegion+1 OF ARRAY MaxAlnRegion+1 OF INTEGER;

(* ------------------------------------------------------------------ *)

PROCEDURE IntMin(a, b: INTEGER): INTEGER;
BEGIN IF a < b THEN RETURN a ELSE RETURN b END
END IntMin;

PROCEDURE IntMax(a, b: INTEGER): INTEGER;
BEGIN IF a > b THEN RETURN a ELSE RETURN b END
END IntMax;

PROCEDURE StrToReal(s: ARRAY OF CHAR; VAR v: REAL);
VAR
  i, len, esign, exp : INTEGER;
  neg                : BOOLEAN;
  intPart, frac, div : REAL;
BEGIN
  v := 0.0; i := 0;
  len := Strings.Length(s);
  neg := FALSE;
  IF (i < len) & (s[i] = '-') THEN neg := TRUE; INC(i)
  ELSIF (i < len) & (s[i] = '+') THEN INC(i)
  END;
  intPart := 0.0;
  WHILE (i < len) & (s[i] >= '0') & (s[i] <= '9') DO
    intPart := intPart * 10.0 + FLT(ORD(s[i]) - ORD('0'));
    INC(i)
  END;
  frac := 0.0; div := 1.0;
  IF (i < len) & (s[i] = '.') THEN
    INC(i);
    WHILE (i < len) & (s[i] >= '0') & (s[i] <= '9') DO
      frac := frac * 10.0 + FLT(ORD(s[i]) - ORD('0'));
      div  := div  * 10.0;
      INC(i)
    END
  END;
  v := intPart + frac / div;
  IF (i < len) & ((s[i] = 'e') OR (s[i] = 'E')) THEN
    INC(i);
    esign := 1;
    IF (i < len) & (s[i] = '-') THEN esign := -1; INC(i)
    ELSIF (i < len) & (s[i] = '+') THEN INC(i)
    END;
    exp := 0;
    WHILE (i < len) & (s[i] >= '0') & (s[i] <= '9') DO
      exp := exp * 10 + ORD(s[i]) - ORD('0');
      INC(i)
    END;
    IF esign > 0 THEN v := v * Math.power(10.0, FLT(exp))
    ELSE              v := v / Math.power(10.0, FLT(exp))
    END
  END;
  IF neg THEN v := -v END
END StrToReal;

(* ------------------------------------------------------------------ *)
(*  Scoring                                                             *)
(* ------------------------------------------------------------------ *)

PROCEDURE PairScore(qi, si: INTEGER; subj: BioSeq.Seq): INTEGER;
VAR qc, sc: CHAR;
BEGIN
  qc := queryBuf[qi];
  IF (qc >= 'a') & (qc <= 'z') THEN qc := CAP(qc) END;
  sc := BioSeq.Get(subj, si);
  IF (sc >= 'a') & (sc <= 'z') THEN sc := CAP(sc) END;
  IF qc = sc THEN RETURN matchScr ELSE RETURN mmScr END
END PairScore;


(* ------------------------------------------------------------------ *)
(*  X-drop extension                                                    *)
(* ------------------------------------------------------------------ *)

PROCEDURE ExtendRight(subj: BioSeq.Seq; qi, si: INTEGER;
                      VAR dist, score: INTEGER);
VAR sLen, qLen, best, cur, d: INTEGER;
BEGIN
  sLen := BioSeq.Length(subj);
  qLen := queryLen;
  best := 0; cur := 0; dist := 0; d := 0;
  LOOP
    IF (qi + d >= qLen) OR (si + d >= sLen) THEN EXIT END;
    INC(cur, PairScore(qi + d, si + d, subj));
    IF cur > best THEN best := cur; dist := d + 1 END;
    IF best - cur >= xDrop THEN EXIT END;
    INC(d)
  END;
  score := best
END ExtendRight;

PROCEDURE ExtendLeft(subj: BioSeq.Seq; qi, si: INTEGER;
                     VAR dist, score: INTEGER);
VAR best, cur, d: INTEGER;
BEGIN
  best := 0; cur := 0; dist := 0; d := 1;
  LOOP
    IF (qi - d < 0) OR (si - d < 0) THEN EXIT END;
    INC(cur, PairScore(qi - d, si - d, subj));
    IF cur > best THEN best := cur; dist := d END;
    IF best - cur >= xDrop THEN EXIT END;
    INC(d)
  END;
  score := best
END ExtendLeft;

(* ------------------------------------------------------------------ *)
(*  Gapped alignment (NW with affine gap penalties)                    *)
(* ------------------------------------------------------------------ *)

PROCEDURE GappedAlign(subj: BioSeq.Seq; VAR rec: HSPRec);
(*
  Needleman-Wunsch with affine gap penalties over the region
  [rec.qStart..rec.qEnd] x [rec.sStart..rec.sEnd], capped at
  MaxAlnRegion per axis.  Updates rec.rawScore, .nIdent, .nMismatch,
  .nGapOpen, .aLen, .alnStr, .qAln, .sAln, .mAln, .qEnd, .sEnd.
*)
CONST
  GapInf = -1000000;
  FromM  = 0; FromIX = 1; FromIY = 2;
  GapNew = 0; GapExt = 1;
VAR
  n, m, i, j, k  : INTEGER;
  go1             : INTEGER;
  v1, v2, v3, bst : INTEGER;
  state           : INTEGER;
  qc, sc, tmp     : CHAR;
  pos             : INTEGER;
BEGIN
  n := rec.qEnd - rec.qStart + 1;
  m := rec.sEnd - rec.sStart + 1;
  IF n > MaxAlnRegion THEN n := MaxAlnRegion; rec.qEnd := rec.qStart + n - 1 END;
  IF m > MaxAlnRegion THEN m := MaxAlnRegion; rec.sEnd := rec.sStart + m - 1 END;

  go1 := gapOpen + gapExt;   (* cost of a 1-residue gap *)

  (* Boundary: (0,0) *)
  dpM[0][0]  := 0;    dpIX[0][0] := GapInf; dpIY[0][0] := GapInf;
  tbM[0][0]  := FromM; tbIX[0][0] := GapNew; tbIY[0][0] := GapNew;

  (* Left edge: query advances, subject has gaps *)
  FOR i := 1 TO n DO
    dpM[i][0]  := GapInf;
    dpIX[i][0] := go1 + (i - 1) * gapExt;
    dpIY[i][0] := GapInf;
    tbM[i][0]  := FromIX;
    IF i = 1 THEN tbIX[i][0] := GapNew ELSE tbIX[i][0] := GapExt END;
    tbIY[i][0] := GapNew
  END;

  (* Top edge: subject advances, query has gaps *)
  FOR j := 1 TO m DO
    dpM[0][j]  := GapInf;
    dpIX[0][j] := GapInf;
    dpIY[0][j] := go1 + (j - 1) * gapExt;
    tbM[0][j]  := FromIY;
    tbIX[0][j] := GapNew;
    IF j = 1 THEN tbIY[0][j] := GapNew ELSE tbIY[0][j] := GapExt END
  END;

  (* Fill DP table *)
  FOR i := 1 TO n DO
    FOR j := 1 TO m DO
      (* Match/mismatch *)
      v1 := dpM[i-1][j-1]; v2 := dpIX[i-1][j-1]; v3 := dpIY[i-1][j-1];
      IF v1 >= v2 THEN
        IF v1 >= v3 THEN bst := v1; tbM[i][j] := FromM
        ELSE              bst := v3; tbM[i][j] := FromIY
        END
      ELSIF v2 >= v3 THEN bst := v2; tbM[i][j] := FromIX
      ELSE                bst := v3; tbM[i][j] := FromIY
      END;
      IF bst > GapInf THEN
        qc := queryBuf[rec.qStart + i - 1];
        sc := BioSeq.Get(subj, rec.sStart + j - 1);
        IF (qc >= 'a') & (qc <= 'z') THEN qc := CAP(qc) END;
        IF (sc >= 'a') & (sc <= 'z') THEN sc := CAP(sc) END;
        IF qc = sc THEN dpM[i][j] := bst + matchScr
        ELSE             dpM[i][j] := bst + mmScr
        END
      ELSE dpM[i][j] := GapInf
      END;

      (* IX: gap in subject, query[i] consumed *)
      v1 := dpM[i-1][j] + go1; v2 := dpIX[i-1][j] + gapExt;
      IF v1 >= v2 THEN dpIX[i][j] := v1; tbIX[i][j] := GapNew
      ELSE              dpIX[i][j] := v2; tbIX[i][j] := GapExt
      END;

      (* IY: gap in query, subj[j] consumed *)
      v1 := dpM[i][j-1] + go1; v2 := dpIY[i][j-1] + gapExt;
      IF v1 >= v2 THEN dpIY[i][j] := v1; tbIY[i][j] := GapNew
      ELSE              dpIY[i][j] := v2; tbIY[i][j] := GapExt
      END
    END
  END;

  (* Choose best final state *)
  bst := dpM[n][m]; state := FromM;
  IF dpIX[n][m] > bst THEN bst := dpIX[n][m]; state := FromIX END;
  IF dpIY[n][m] > bst THEN bst := dpIY[n][m]; state := FromIY END;
  rec.rawScore := bst;

  (* Traceback — build strings in reverse *)
  pos := 0; i := n; j := m;
  rec.nIdent := 0; rec.nMismatch := 0; rec.nGapOpen := 0;
  WHILE (i > 0) OR (j > 0) DO
    IF pos >= MaxAlnStr - 1 THEN EXIT END;
    IF state = FromM THEN
      qc := queryBuf[rec.qStart + i - 1];
      sc := BioSeq.Get(subj, rec.sStart + j - 1);
      IF (qc >= 'a') & (qc <= 'z') THEN qc := CAP(qc) END;
      IF (sc >= 'a') & (sc <= 'z') THEN sc := CAP(sc) END;
      rec.qAln[pos] := qc; rec.sAln[pos] := sc;
      IF qc = sc THEN rec.mAln[pos] := '|'; INC(rec.nIdent)
      ELSE             rec.mAln[pos] := ' '; INC(rec.nMismatch)
      END;
      INC(pos);
      state := tbM[i][j]; DEC(i); DEC(j)
    ELSIF state = FromIX THEN   (* gap in subject, query advances *)
      qc := queryBuf[rec.qStart + i - 1];
      rec.qAln[pos] := qc; rec.sAln[pos] := '-'; rec.mAln[pos] := ' ';
      INC(pos);
      IF tbIX[i][j] = GapNew THEN INC(rec.nGapOpen); state := FromM
      ELSE state := FromIX
      END;
      DEC(i)
    ELSE                        (* FromIY: gap in query, subject advances *)
      sc := BioSeq.Get(subj, rec.sStart + j - 1);
      IF (sc >= 'a') & (sc <= 'z') THEN sc := CAP(sc) END;
      rec.qAln[pos] := '-'; rec.sAln[pos] := sc; rec.mAln[pos] := ' ';
      INC(pos);
      IF tbIY[i][j] = GapNew THEN INC(rec.nGapOpen); state := FromM
      ELSE state := FromIY
      END;
      DEC(j)
    END
  END;
  rec.alnStr := pos; rec.aLen := pos;

  (* Reverse alignment strings in place *)
  FOR k := 0 TO pos DIV 2 - 1 DO
    tmp := rec.qAln[k]; rec.qAln[k] := rec.qAln[pos-1-k]; rec.qAln[pos-1-k] := tmp;
    tmp := rec.sAln[k]; rec.sAln[k] := rec.sAln[pos-1-k]; rec.sAln[pos-1-k] := tmp;
    tmp := rec.mAln[k]; rec.mAln[k] := rec.mAln[pos-1-k]; rec.mAln[pos-1-k] := tmp
  END;
  rec.qAln[pos] := 0X; rec.sAln[pos] := 0X; rec.mAln[pos] := 0X
END GappedAlign;

(* ------------------------------------------------------------------ *)
(*  E-value / bit-score                                                 *)
(* ------------------------------------------------------------------ *)

PROCEDURE BitScore(raw: INTEGER): REAL;
BEGIN
  RETURN (Lambda * FLT(raw) - Math.ln(KStat)) / Math.ln(2.0)
END BitScore;

PROCEDURE CalcEvalue(raw, qLen, sLen: INTEGER): REAL;
BEGIN
  RETURN FLT(qLen) * FLT(sLen) * Math.power(2.0, -BitScore(raw))
END CalcEvalue;

(* ------------------------------------------------------------------ *)
(*  HSP management                                                      *)
(* ------------------------------------------------------------------ *)

PROCEDURE Overlaps(i: INTEGER; VAR rec: HSPRec): BOOLEAN;
VAR qOvl, sOvl, qSpan, sSpan: INTEGER;
BEGIN
  qOvl  := IntMin(hspList[i].qEnd, rec.qEnd) - IntMax(hspList[i].qStart, rec.qStart) + 1;
  sOvl  := IntMin(hspList[i].sEnd, rec.sEnd) - IntMax(hspList[i].sStart, rec.sStart) + 1;
  IF (qOvl <= 0) OR (sOvl <= 0) THEN RETURN FALSE END;
  qSpan := IntMin(hspList[i].qEnd - hspList[i].qStart + 1, rec.qEnd - rec.qStart + 1);
  sSpan := IntMin(hspList[i].sEnd - hspList[i].sStart + 1, rec.sEnd - rec.sStart + 1);
  RETURN (qOvl * 2 > qSpan) & (sOvl * 2 > sSpan)
END Overlaps;

PROCEDURE AddHSP(VAR rec: HSPRec);
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO hspCount - 1 DO
    IF Overlaps(i, rec) THEN
      IF rec.rawScore > hspList[i].rawScore THEN hspList[i] := rec END;
      RETURN
    END
  END;
  IF hspCount < MaxHSPs THEN
    hspList[hspCount] := rec;
    INC(hspCount)
  END
END AddHSP;

(* ------------------------------------------------------------------ *)
(*  Parallel-safe search workers                                        *)
(* ------------------------------------------------------------------ *)

PROCEDURE OverlapsW(VAR ex: HSPRec; VAR rec: HSPRec): BOOLEAN;
VAR qOvl, sOvl, qSpan, sSpan: INTEGER;
BEGIN
  qOvl  := IntMin(ex.qEnd, rec.qEnd) - IntMax(ex.qStart, rec.qStart) + 1;
  sOvl  := IntMin(ex.sEnd, rec.sEnd) - IntMax(ex.sStart, rec.sStart) + 1;
  IF (qOvl <= 0) OR (sOvl <= 0) THEN RETURN FALSE END;
  qSpan := IntMin(ex.qEnd - ex.qStart + 1, rec.qEnd - rec.qStart + 1);
  sSpan := IntMin(ex.sEnd - ex.sStart + 1, rec.sEnd - rec.sStart + 1);
  RETURN (qOvl * 2 > qSpan) & (sOvl * 2 > sSpan)
END OverlapsW;

PROCEDURE AddHSPW(wi: INTEGER; isPlus: BOOLEAN; VAR rec: HSPRec);
VAR i: INTEGER;
BEGIN
  IF isPlus THEN
    FOR i := 0 TO wkHspCntP[wi] - 1 DO
      IF OverlapsW(wkHspListP[wi][i], rec) THEN
        IF rec.rawScore > wkHspListP[wi][i].rawScore THEN wkHspListP[wi][i] := rec END;
        RETURN
      END
    END;
    IF wkHspCntP[wi] < MaxHSPs THEN
      wkHspListP[wi][wkHspCntP[wi]] := rec; INC(wkHspCntP[wi])
    END
  ELSE
    FOR i := 0 TO wkHspCntM[wi] - 1 DO
      IF OverlapsW(wkHspListM[wi][i], rec) THEN
        IF rec.rawScore > wkHspListM[wi][i].rawScore THEN wkHspListM[wi][i] := rec END;
        RETURN
      END
    END;
    IF wkHspCntM[wi] < MaxHSPs THEN
      wkHspListM[wi][wkHspCntM[wi]] := rec; INC(wkHspCntM[wi])
    END
  END
END AddHSPW;

PROCEDURE GappedAlignW(wi: INTEGER; subj: BioSeq.Seq; VAR rec: HSPRec);
CONST
  GapInf = -1000000;
  FromM  = 0; FromIX = 1; FromIY = 2;
  GapNew = 0; GapExt = 1;
VAR
  n, m, i, j, k  : INTEGER;
  go1             : INTEGER;
  v1, v2, v3, bst : INTEGER;
  state           : INTEGER;
  qc, sc, tmp     : CHAR;
  pos             : INTEGER;
BEGIN
  n := rec.qEnd - rec.qStart + 1;
  m := rec.sEnd - rec.sStart + 1;
  IF n > MaxAlnRegion THEN n := MaxAlnRegion; rec.qEnd := rec.qStart + n - 1 END;
  IF m > MaxAlnRegion THEN m := MaxAlnRegion; rec.sEnd := rec.sStart + m - 1 END;

  go1 := gapOpen + gapExt;

  wkDpM[wi][0][0]  := 0;    wkDpIX[wi][0][0] := GapInf; wkDpIY[wi][0][0] := GapInf;
  wkTbM[wi][0][0]  := FromM; wkTbIX[wi][0][0] := GapNew; wkTbIY[wi][0][0] := GapNew;

  FOR i := 1 TO n DO
    wkDpM[wi][i][0]  := GapInf;
    wkDpIX[wi][i][0] := go1 + (i - 1) * gapExt;
    wkDpIY[wi][i][0] := GapInf;
    wkTbM[wi][i][0]  := FromIX;
    IF i = 1 THEN wkTbIX[wi][i][0] := GapNew ELSE wkTbIX[wi][i][0] := GapExt END;
    wkTbIY[wi][i][0] := GapNew
  END;

  FOR j := 1 TO m DO
    wkDpM[wi][0][j]  := GapInf;
    wkDpIX[wi][0][j] := GapInf;
    wkDpIY[wi][0][j] := go1 + (j - 1) * gapExt;
    wkTbM[wi][0][j]  := FromIY;
    wkTbIX[wi][0][j] := GapNew;
    IF j = 1 THEN wkTbIY[wi][0][j] := GapNew ELSE wkTbIY[wi][0][j] := GapExt END
  END;

  FOR i := 1 TO n DO
    FOR j := 1 TO m DO
      v1 := wkDpM[wi][i-1][j-1]; v2 := wkDpIX[wi][i-1][j-1]; v3 := wkDpIY[wi][i-1][j-1];
      IF v1 >= v2 THEN
        IF v1 >= v3 THEN bst := v1; wkTbM[wi][i][j] := FromM
        ELSE              bst := v3; wkTbM[wi][i][j] := FromIY
        END
      ELSIF v2 >= v3 THEN bst := v2; wkTbM[wi][i][j] := FromIX
      ELSE                bst := v3; wkTbM[wi][i][j] := FromIY
      END;
      IF bst > GapInf THEN
        qc := queryBuf[rec.qStart + i - 1];
        sc := BioSeq.Get(subj, rec.sStart + j - 1);
        IF (qc >= 'a') & (qc <= 'z') THEN qc := CAP(qc) END;
        IF (sc >= 'a') & (sc <= 'z') THEN sc := CAP(sc) END;
        IF qc = sc THEN wkDpM[wi][i][j] := bst + matchScr
        ELSE             wkDpM[wi][i][j] := bst + mmScr
        END
      ELSE wkDpM[wi][i][j] := GapInf
      END;

      v1 := wkDpM[wi][i-1][j] + go1; v2 := wkDpIX[wi][i-1][j] + gapExt;
      IF v1 >= v2 THEN wkDpIX[wi][i][j] := v1; wkTbIX[wi][i][j] := GapNew
      ELSE              wkDpIX[wi][i][j] := v2; wkTbIX[wi][i][j] := GapExt
      END;

      v1 := wkDpM[wi][i][j-1] + go1; v2 := wkDpIY[wi][i][j-1] + gapExt;
      IF v1 >= v2 THEN wkDpIY[wi][i][j] := v1; wkTbIY[wi][i][j] := GapNew
      ELSE              wkDpIY[wi][i][j] := v2; wkTbIY[wi][i][j] := GapExt
      END
    END
  END;

  bst := wkDpM[wi][n][m]; state := FromM;
  IF wkDpIX[wi][n][m] > bst THEN bst := wkDpIX[wi][n][m]; state := FromIX END;
  IF wkDpIY[wi][n][m] > bst THEN bst := wkDpIY[wi][n][m]; state := FromIY END;
  rec.rawScore := bst;

  pos := 0; i := n; j := m;
  rec.nIdent := 0; rec.nMismatch := 0; rec.nGapOpen := 0;
  WHILE (i > 0) OR (j > 0) DO
    IF pos >= MaxAlnStr - 1 THEN EXIT END;
    IF state = FromM THEN
      qc := queryBuf[rec.qStart + i - 1];
      sc := BioSeq.Get(subj, rec.sStart + j - 1);
      IF (qc >= 'a') & (qc <= 'z') THEN qc := CAP(qc) END;
      IF (sc >= 'a') & (sc <= 'z') THEN sc := CAP(sc) END;
      rec.qAln[pos] := qc; rec.sAln[pos] := sc;
      IF qc = sc THEN rec.mAln[pos] := '|'; INC(rec.nIdent)
      ELSE             rec.mAln[pos] := ' '; INC(rec.nMismatch)
      END;
      INC(pos);
      state := wkTbM[wi][i][j]; DEC(i); DEC(j)
    ELSIF state = FromIX THEN
      qc := queryBuf[rec.qStart + i - 1];
      rec.qAln[pos] := qc; rec.sAln[pos] := '-'; rec.mAln[pos] := ' ';
      INC(pos);
      IF wkTbIX[wi][i][j] = GapNew THEN INC(rec.nGapOpen); state := FromM
      ELSE state := FromIX
      END;
      DEC(i)
    ELSE
      sc := BioSeq.Get(subj, rec.sStart + j - 1);
      IF (sc >= 'a') & (sc <= 'z') THEN sc := CAP(sc) END;
      rec.qAln[pos] := '-'; rec.sAln[pos] := sc; rec.mAln[pos] := ' ';
      INC(pos);
      IF wkTbIY[wi][i][j] = GapNew THEN INC(rec.nGapOpen); state := FromM
      ELSE state := FromIY
      END;
      DEC(j)
    END
  END;
  rec.alnStr := pos; rec.aLen := pos;

  FOR k := 0 TO pos DIV 2 - 1 DO
    tmp := rec.qAln[k]; rec.qAln[k] := rec.qAln[pos-1-k]; rec.qAln[pos-1-k] := tmp;
    tmp := rec.sAln[k]; rec.sAln[k] := rec.sAln[pos-1-k]; rec.sAln[pos-1-k] := tmp;
    tmp := rec.mAln[k]; rec.mAln[k] := rec.mAln[pos-1-k]; rec.mAln[pos-1-k] := tmp
  END;
  rec.qAln[pos] := 0X; rec.sAln[pos] := 0X; rec.mAln[pos] := 0X
END GappedAlignW;

PROCEDURE FindHSPsW(wi: INTEGER; subj: BioSeq.Seq; sLen: INTEGER; isPlus: BOOLEAN);
VAR
  qi, k, W, h : INTEGER;
  wbuf        : ARRAY MaxW + 1 OF CHAR;
  bm          : BioPattern.BMState;
  hits        : BioPattern.HitList;
  qi0, si0    : INTEGER;
  ld, ls, rd, rs : INTEGER;
  ev          : REAL;
  rec         : HSPRec;
BEGIN
  IF isPlus THEN wkHspCntP[wi] := 0 ELSE wkHspCntM[wi] := 0 END;
  W := wordSize;
  qi := 0;
  WHILE qi <= queryLen - W DO
    FOR k := 0 TO W - 1 DO wbuf[k] := queryBuf[qi + k] END;
    wbuf[W] := 0X;
    BioPattern.BMBuild(bm, wbuf);
    BioPattern.BMSearch(bm, subj, hits);
    FOR h := 0 TO hits.count - 1 DO
      qi0 := qi; si0 := hits.hits[h].pos;
      ExtendLeft (subj, qi0,     si0,     ld, ls);
      ExtendRight(subj, qi0 + W, si0 + W, rd, rs);
      rec.qStart := qi0 - ld;   rec.qEnd := qi0 + W - 1 + rd;
      rec.sStart := si0 - ld;   rec.sEnd := si0 + W - 1 + rs;
      GappedAlignW(wi, subj, rec);
      IF rec.rawScore > 0 THEN
        ev := CalcEvalue(rec.rawScore, queryLen, sLen);
        IF ev <= eThresh THEN AddHSPW(wi, isPlus, rec) END
      END
    END;
    INC(qi)
  END
END FindHSPsW;

PROCEDURE PrintTabularW(wi: INTEGER; isPlus: BOOLEAN);
VAR i, ss, se, cnt, sLen: INTEGER; pct, ev, bs: REAL;
BEGIN
  sLen := wkSubjLen[wi];
  IF isPlus THEN cnt := wkHspCntP[wi] ELSE cnt := wkHspCntM[wi] END;
  FOR i := 0 TO cnt - 1 DO
    IF isPlus THEN
      ev  := CalcEvalue(wkHspListP[wi][i].rawScore, queryLen, sLen);
      bs  := BitScore(wkHspListP[wi][i].rawScore);
      pct := FLT(wkHspListP[wi][i].nIdent) / FLT(wkHspListP[wi][i].aLen) * 100.0;
      ss  := wkHspListP[wi][i].sStart + 1;
      se  := wkHspListP[wi][i].sEnd   + 1;
      Out.String("query"); Out.Char(9X); Out.String(wkSubjName[wi]); Out.Char(9X);
      Out.Fixed(pct, 0, 2); Out.Char(9X);
      Out.Int(wkHspListP[wi][i].aLen, 0); Out.Char(9X);
      Out.Int(wkHspListP[wi][i].nMismatch, 0); Out.Char(9X);
      Out.Int(wkHspListP[wi][i].nGapOpen, 0); Out.Char(9X);
      Out.Int(wkHspListP[wi][i].qStart + 1, 0); Out.Char(9X);
      Out.Int(wkHspListP[wi][i].qEnd   + 1, 0); Out.Char(9X)
    ELSE
      ev  := CalcEvalue(wkHspListM[wi][i].rawScore, queryLen, sLen);
      bs  := BitScore(wkHspListM[wi][i].rawScore);
      pct := FLT(wkHspListM[wi][i].nIdent) / FLT(wkHspListM[wi][i].aLen) * 100.0;
      ss  := sLen - wkHspListM[wi][i].sStart;
      se  := sLen - wkHspListM[wi][i].sEnd;
      Out.String("query"); Out.Char(9X); Out.String(wkSubjName[wi]); Out.Char(9X);
      Out.Fixed(pct, 0, 2); Out.Char(9X);
      Out.Int(wkHspListM[wi][i].aLen, 0); Out.Char(9X);
      Out.Int(wkHspListM[wi][i].nMismatch, 0); Out.Char(9X);
      Out.Int(wkHspListM[wi][i].nGapOpen, 0); Out.Char(9X);
      Out.Int(wkHspListM[wi][i].qStart + 1, 0); Out.Char(9X);
      Out.Int(wkHspListM[wi][i].qEnd   + 1, 0); Out.Char(9X)
    END;
    Out.Int(ss, 0); Out.Char(9X); Out.Int(se, 0); Out.Char(9X);
    PrintEvalue(ev); Out.Char(9X); Out.Fixed(bs, 0, 1); Out.Ln
  END
END PrintTabularW;

PROCEDURE PrintAlnFmtW(wi: INTEGER; isPlus: BOOLEAN);
CONST Width = 60;
VAR
  i, p, j, w, cnt, sLen : INTEGER;
  qPos, sPos            : INTEGER;
  qLo, sLo, qHi, sHi   : INTEGER;
  ev, bs, pct           : REAL;
  qline, sline, mline   : ARRAY 61 OF CHAR;
BEGIN
  sLen := wkSubjLen[wi];
  IF isPlus THEN cnt := wkHspCntP[wi] ELSE cnt := wkHspCntM[wi] END;
  FOR i := 0 TO cnt - 1 DO
    IF isPlus THEN
      ev  := CalcEvalue(wkHspListP[wi][i].rawScore, queryLen, sLen);
      bs  := BitScore(wkHspListP[wi][i].rawScore);
      pct := FLT(wkHspListP[wi][i].nIdent) / FLT(wkHspListP[wi][i].aLen) * 100.0
    ELSE
      ev  := CalcEvalue(wkHspListM[wi][i].rawScore, queryLen, sLen);
      bs  := BitScore(wkHspListM[wi][i].rawScore);
      pct := FLT(wkHspListM[wi][i].nIdent) / FLT(wkHspListM[wi][i].aLen) * 100.0
    END;
    Out.Ln;
    Out.String("> "); Out.String(wkSubjName[wi]); Out.Ln;
    Out.String("  Score = "); Out.Fixed(bs, 0, 1);
    Out.String(" bits (");
    IF isPlus THEN Out.Int(wkHspListP[wi][i].rawScore, 0)
    ELSE           Out.Int(wkHspListM[wi][i].rawScore, 0)
    END;
    Out.String("),  Expect = "); PrintEvalue(ev); Out.Ln;
    Out.String("  Identities = ");
    IF isPlus THEN Out.Int(wkHspListP[wi][i].nIdent, 0); Out.String("/"); Out.Int(wkHspListP[wi][i].aLen, 0)
    ELSE           Out.Int(wkHspListM[wi][i].nIdent, 0); Out.String("/"); Out.Int(wkHspListM[wi][i].aLen, 0)
    END;
    Out.String(" ("); Out.Fixed(pct, 0, 0); Out.String("%)");
    Out.String(",  Gaps = ");
    IF isPlus THEN Out.Int(wkHspListP[wi][i].nGapOpen, 0)
    ELSE           Out.Int(wkHspListM[wi][i].nGapOpen, 0)
    END;
    IF isPlus THEN Out.String("  Strand: Plus/Plus")
    ELSE           Out.String("  Strand: Plus/Minus")
    END;
    Out.Ln; Out.Ln;

    IF isPlus THEN
      qPos := wkHspListP[wi][i].qStart + 1;
      sPos := wkHspListP[wi][i].sStart + 1;
      p := 0;
      WHILE p < wkHspListP[wi][i].alnStr DO
        w := IntMin(Width, wkHspListP[wi][i].alnStr - p);
        qLo := qPos; sLo := sPos;
        FOR j := 0 TO w - 1 DO
          qline[j] := wkHspListP[wi][i].qAln[p + j];
          sline[j] := wkHspListP[wi][i].sAln[p + j];
          mline[j] := wkHspListP[wi][i].mAln[p + j];
          IF wkHspListP[wi][i].qAln[p + j] # '-' THEN INC(qPos) END;
          IF wkHspListP[wi][i].sAln[p + j] # '-' THEN INC(sPos) END
        END;
        qline[w] := 0X; sline[w] := 0X; mline[w] := 0X;
        qHi := qPos - 1; sHi := sPos - 1;
        Out.String("Query "); Out.Int(qLo, 6); Out.String("  "); Out.String(qline);
        Out.String("  "); Out.Int(qHi, 0); Out.Ln;
        Out.String("              "); Out.String(mline); Out.Ln;
        Out.String("Sbjct "); Out.Int(sLo, 6); Out.String("  "); Out.String(sline);
        Out.String("  "); Out.Int(sHi, 0); Out.Ln; Out.Ln;
        INC(p, w)
      END
    ELSE
      qPos := wkHspListM[wi][i].qStart + 1;
      sPos := sLen - wkHspListM[wi][i].sStart;
      p := 0;
      WHILE p < wkHspListM[wi][i].alnStr DO
        w := IntMin(Width, wkHspListM[wi][i].alnStr - p);
        qLo := qPos; sLo := sPos;
        FOR j := 0 TO w - 1 DO
          qline[j] := wkHspListM[wi][i].qAln[p + j];
          sline[j] := wkHspListM[wi][i].sAln[p + j];
          mline[j] := wkHspListM[wi][i].mAln[p + j];
          IF wkHspListM[wi][i].qAln[p + j] # '-' THEN INC(qPos) END;
          IF wkHspListM[wi][i].sAln[p + j] # '-' THEN DEC(sPos) END
        END;
        qline[w] := 0X; sline[w] := 0X; mline[w] := 0X;
        qHi := qPos - 1; sHi := sPos + 1;
        Out.String("Query "); Out.Int(qLo, 6); Out.String("  "); Out.String(qline);
        Out.String("  "); Out.Int(qHi, 0); Out.Ln;
        Out.String("              "); Out.String(mline); Out.Ln;
        Out.String("Sbjct "); Out.Int(sLo, 6); Out.String("  "); Out.String(sline);
        Out.String("  "); Out.Int(sHi, 0); Out.Ln; Out.Ln;
        INC(p, w)
      END
    END
  END
END PrintAlnFmtW;

PROCEDURE SearchWorker(wi: INTEGER);
VAR alpha: BioAlpha.Alphabet;
BEGIN
  BioAlpha.DNA(alpha);
  FindHSPsW(wi, wkSubjSeq[wi], wkSubjLen[wi], TRUE);
  BioSeq.RevComp(wkSubjSeq[wi], alpha, wkRcSeq[wi]);
  FindHSPsW(wi, wkRcSeq[wi], wkSubjLen[wi], FALSE)
END SearchWorker;

(* ------------------------------------------------------------------ *)
(*  Search one subject                                                  *)
(* ------------------------------------------------------------------ *)

PROCEDURE FindHSPs(subj: BioSeq.Seq; sLen: INTEGER);
VAR
  qi, k, W, h : INTEGER;
  wbuf        : ARRAY MaxW + 1 OF CHAR;
  bm          : BioPattern.BMState;
  hits        : BioPattern.HitList;
  qi0, si0    : INTEGER;
  ld, ls, rd, rs : INTEGER;
  ev          : REAL;
  rec         : HSPRec;
BEGIN
  hspCount := 0;
  W := wordSize;
  qi := 0;
  WHILE qi <= queryLen - W DO
    FOR k := 0 TO W - 1 DO wbuf[k] := queryBuf[qi + k] END;
    wbuf[W] := 0X;

    BioPattern.BMBuild(bm, wbuf);
    BioPattern.BMSearch(bm, subj, hits);

    FOR h := 0 TO hits.count - 1 DO
      qi0 := qi;
      si0 := hits.hits[h].pos;

      ExtendLeft (subj, qi0,     si0,     ld, ls);
      ExtendRight(subj, qi0 + W, si0 + W, rd, rs);

      rec.qStart := qi0 - ld;     rec.qEnd := qi0 + W - 1 + rd;
      rec.sStart := si0 - ld;     rec.sEnd := si0 + W - 1 + rs;

      GappedAlign(subj, rec);
      IF rec.rawScore > 0 THEN
        ev := CalcEvalue(rec.rawScore, queryLen, sLen);
        IF ev <= eThresh THEN AddHSP(rec) END
      END
    END;
    INC(qi)
  END
END FindHSPs;

(* ------------------------------------------------------------------ *)
(*  Output                                                              *)
(* ------------------------------------------------------------------ *)

PROCEDURE PrintEvalue(e: REAL);
VAR exp: INTEGER; m: REAL;
BEGIN
  IF e >= 0.001 THEN
    Out.Fixed(e, 0, 3)
  ELSE
    exp := 0; m := e;
    WHILE m < 1.0 DO m := m * 10.0; DEC(exp) END;
    Out.Fixed(m, 0, 2); Out.String("e"); Out.Int(exp, 0)
  END
END PrintEvalue;

PROCEDURE PrintTabular(subjName: ARRAY OF CHAR; sLen: INTEGER; minus: BOOLEAN);
(* Full -outfmt 6: qseqid sseqid pident length mismatch gapopen
                   qstart qend sstart send evalue bitscore
   For minus strand: sstart > send (BLAST convention). *)
VAR i, ss, se: INTEGER; pct, ev, bs: REAL;
BEGIN
  FOR i := 0 TO hspCount - 1 DO
    ev  := CalcEvalue(hspList[i].rawScore, queryLen, sLen);
    bs  := BitScore(hspList[i].rawScore);
    pct := FLT(hspList[i].nIdent) / FLT(hspList[i].aLen) * 100.0;
    IF minus THEN
      ss := sLen - hspList[i].sStart;
      se := sLen - hspList[i].sEnd
    ELSE
      ss := hspList[i].sStart + 1;
      se := hspList[i].sEnd   + 1
    END;
    Out.String("query"); Out.Char(9X);
    Out.String(subjName); Out.Char(9X);
    Out.Fixed(pct, 0, 2); Out.Char(9X);
    Out.Int(hspList[i].aLen, 0); Out.Char(9X);
    Out.Int(hspList[i].nMismatch, 0); Out.Char(9X);
    Out.Int(hspList[i].nGapOpen, 0); Out.Char(9X);
    Out.Int(hspList[i].qStart + 1, 0); Out.Char(9X);
    Out.Int(hspList[i].qEnd   + 1, 0); Out.Char(9X);
    Out.Int(ss, 0); Out.Char(9X);
    Out.Int(se, 0); Out.Char(9X);
    PrintEvalue(ev); Out.Char(9X);
    Out.Fixed(bs, 0, 1); Out.Ln
  END
END PrintTabular;

PROCEDURE PrintAlnFmt(subj: BioSeq.Seq; subjName: ARRAY OF CHAR;
                      sLen: INTEGER; minus: BOOLEAN);
(*
  Pairwise output using the pre-computed alignment strings in each HSPRec.
  Gap characters ('-') are included.  Query coords always increase; subject
  coords increase (plus) or decrease (minus strand).
*)
CONST Width = 60;
VAR
  i, p, j, w    : INTEGER;
  qPos, sPos    : INTEGER;   (* current 1-based position in query/subject *)
  qLo, sLo      : INTEGER;
  qHi, sHi      : INTEGER;
  ev, bs, pct   : REAL;
  qline, sline, mline : ARRAY 61 OF CHAR;
BEGIN
  FOR i := 0 TO hspCount - 1 DO
    ev  := CalcEvalue(hspList[i].rawScore, queryLen, sLen);
    bs  := BitScore(hspList[i].rawScore);
    pct := FLT(hspList[i].nIdent) / FLT(hspList[i].aLen) * 100.0;

    Out.Ln;
    Out.String("> "); Out.String(subjName); Out.Ln;
    Out.String("  Score = "); Out.Fixed(bs, 0, 1);
    Out.String(" bits ("); Out.Int(hspList[i].rawScore, 0); Out.String("),");
    Out.String("  Expect = "); PrintEvalue(ev); Out.Ln;
    Out.String("  Identities = "); Out.Int(hspList[i].nIdent, 0);
    Out.String("/"); Out.Int(hspList[i].aLen, 0);
    Out.String(" ("); Out.Fixed(pct, 0, 0); Out.String("%)");
    Out.String(",  Gaps = "); Out.Int(hspList[i].nGapOpen, 0);
    IF minus THEN Out.String("  Strand: Plus/Minus")
    ELSE          Out.String("  Strand: Plus/Plus")
    END;
    Out.Ln; Out.Ln;

    qPos := hspList[i].qStart + 1;
    IF minus THEN sPos := sLen - hspList[i].sStart
    ELSE          sPos := hspList[i].sStart + 1
    END;

    p := 0;
    WHILE p < hspList[i].alnStr DO
      w := IntMin(Width, hspList[i].alnStr - p);
      qLo := qPos; sLo := sPos;

      FOR j := 0 TO w - 1 DO
        qline[j] := hspList[i].qAln[p + j];
        sline[j] := hspList[i].sAln[p + j];
        mline[j] := hspList[i].mAln[p + j];
        IF hspList[i].qAln[p + j] # '-' THEN INC(qPos) END;
        IF hspList[i].sAln[p + j] # '-' THEN
          IF minus THEN DEC(sPos) ELSE INC(sPos) END
        END
      END;
      qline[w] := 0X; sline[w] := 0X; mline[w] := 0X;
      qHi := qPos - 1;
      IF minus THEN sHi := sPos + 1 ELSE sHi := sPos - 1 END;

      Out.String("Query "); Out.Int(qLo, 6);
      Out.String("  "); Out.String(qline);
      Out.String("  "); Out.Int(qHi, 0); Out.Ln;
      Out.String("              "); Out.String(mline); Out.Ln;
      Out.String("Sbjct "); Out.Int(sLo, 6);
      Out.String("  "); Out.String(sline);
      Out.String("  "); Out.Int(sHi, 0); Out.Ln;
      Out.Ln;

      INC(p, w)
    END
  END
END PrintAlnFmt;

(* ------------------------------------------------------------------ *)
(*  Query loading                                                       *)
(* ------------------------------------------------------------------ *)

PROCEDURE LoadQuery(path: ARRAY OF CHAR): BOOLEAN;
VAR rdr: BioIO.FastaReader; rec: BioIO.FastaRecord; len: INTEGER;
BEGIN
  IF ~BioIO.OpenFasta(rdr, path) THEN
    Out.String("Error: cannot open query: "); Out.String(path); Out.Ln;
    RETURN FALSE
  END;
  rec.seq := NIL;
  IF ~BioIO.ReadFasta(rdr, rec) THEN
    Out.String("Error: query file is empty."); Out.Ln;
    BioIO.CloseFasta(rdr);
    RETURN FALSE
  END;
  len := BioSeq.Length(rec.seq);
  IF len >= MaxQLen THEN len := MaxQLen - 1 END;
  BioSeq.Slice(rec.seq, 0, len, queryBuf);
  queryLen := len;
  BioIO.CloseFasta(rdr);
  RETURN TRUE
END LoadQuery;

(* ------------------------------------------------------------------ *)
(*  Main search loop                                                    *)
(* ------------------------------------------------------------------ *)

PROCEDURE SearchDB(dbPath: ARRAY OF CHAR);
VAR
  rdr      : BioIO.FastaReader;
  rec      : BioIO.FastaRecord;
  rcSeq    : BioSeq.Seq;
  alpha    : BioAlpha.Alphabet;
  sLen     : INTEGER;
  header   : BOOLEAN;
BEGIN
  IF ~BioIO.OpenFasta(rdr, dbPath) THEN
    Out.String("Error: cannot open DB: "); Out.String(dbPath); Out.Ln;
    RETURN
  END;
  BioAlpha.DNA(alpha);
  BioSeq.New(rcSeq);
  header := FALSE;
  rec.seq := NIL;
  WHILE BioIO.ReadFasta(rdr, rec) DO
    sLen := BioSeq.Length(rec.seq);

    (* Plus strand *)
    FindHSPs(rec.seq, sLen);
    IF hspCount > 0 THEN
      IF alnMode THEN
        IF ~header THEN
          Out.String("Query: query  Length="); Out.Int(queryLen, 0); Out.Ln;
          header := TRUE
        END;
        PrintAlnFmt(rec.seq, rec.name, sLen, FALSE)
      ELSE
        PrintTabular(rec.name, sLen, FALSE)
      END
    END;

    (* Minus strand: search RC of subject; convert coords on output *)
    BioSeq.RevComp(rec.seq, alpha, rcSeq);
    FindHSPs(rcSeq, sLen);
    IF hspCount > 0 THEN
      IF alnMode THEN
        IF ~header THEN
          Out.String("Query: query  Length="); Out.Int(queryLen, 0); Out.Ln;
          header := TRUE
        END;
        PrintAlnFmt(rcSeq, rec.name, sLen, TRUE)
      ELSE
        PrintTabular(rec.name, sLen, TRUE)
      END
    END
  END;
  BioSeq.Free(rcSeq);
  BioIO.CloseFasta(rdr)
END SearchDB;

(* ------------------------------------------------------------------ *)
(*  Argument parsing                                                    *)
(* ------------------------------------------------------------------ *)

PROCEDURE ParseArgs(): BOOLEAN;
VAR
  i, posCount : INTEGER;
  arg, next   : ARRAY 1024 OF CHAR;
BEGIN
  wordSize  := 11;
  eThresh   := 10.0;
  matchScr  := 1;
  mmScr     := -3;
  xDrop     := 20;
  gapOpen   := -5;
  gapExt    := -2;
  alnMode   := FALSE;
  queryFile := "";
  dbFile    := "";
  posCount  := 0;

  i := 1;
  WHILE i <= Args.Count() DO
    Args.Get(i, arg);
    IF Strings.Compare(arg, "-W") = 0 THEN
      INC(i); Args.Get(i, next); IF ~Strings.StrToInt(next, wordSize) THEN wordSize := 11 END
    ELSIF Strings.Compare(arg, "-e") = 0 THEN
      INC(i); Args.Get(i, next); StrToReal(next, eThresh)
    ELSIF Strings.Compare(arg, "-r") = 0 THEN
      INC(i); Args.Get(i, next); IF ~Strings.StrToInt(next, matchScr) THEN matchScr := 1 END
    ELSIF Strings.Compare(arg, "-q") = 0 THEN
      INC(i); Args.Get(i, next); IF ~Strings.StrToInt(next, mmScr) THEN mmScr := -3 END
    ELSIF Strings.Compare(arg, "-X") = 0 THEN
      INC(i); Args.Get(i, next); IF ~Strings.StrToInt(next, xDrop) THEN xDrop := 20 END
    ELSIF Strings.Compare(arg, "-G") = 0 THEN
      INC(i); Args.Get(i, next); IF ~Strings.StrToInt(next, gapOpen) THEN gapOpen := -5 END;
      IF gapOpen > 0 THEN gapOpen := -gapOpen END   (* accept positive or negative *)
    ELSIF Strings.Compare(arg, "-E") = 0 THEN
      INC(i); Args.Get(i, next); IF ~Strings.StrToInt(next, gapExt) THEN gapExt := -2 END;
      IF gapExt > 0 THEN gapExt := -gapExt END
    ELSIF Strings.Compare(arg, "-aln") = 0 THEN
      alnMode := TRUE
    ELSE
      IF posCount = 0 THEN COPY(arg, queryFile)
      ELSIF posCount = 1 THEN COPY(arg, dbFile)
      END;
      INC(posCount)
    END;
    INC(i)
  END;

  IF (queryFile = "") OR (dbFile = "") THEN
    Out.String("Usage: SeqBlast [options] <query.fa> <db.fa>"); Out.Ln;
    Out.String("  -W <int>   word size (default 11)"); Out.Ln;
    Out.String("  -e <real>  E-value threshold (default 10.0)"); Out.Ln;
    Out.String("  -r <int>   match reward (default 1)"); Out.Ln;
    Out.String("  -q <int>   mismatch penalty (default -3)"); Out.Ln;
    Out.String("  -X <int>   X-drop threshold for seed extension (default 20)"); Out.Ln;
    Out.String("  -G <int>   gap-open penalty (default 5)"); Out.Ln;
    Out.String("  -E <int>   gap-extend penalty (default 2)"); Out.Ln;
    Out.String("  -aln       pairwise alignment output"); Out.Ln;
    RETURN FALSE
  END;

  IF wordSize < 4   THEN wordSize := 4   END;
  IF wordSize > MaxW THEN wordSize := MaxW END;
  RETURN TRUE
END ParseArgs;

(* ------------------------------------------------------------------ *)
(*  Entry point                                                         *)
(* ------------------------------------------------------------------ *)

BEGIN
  IF ~ParseArgs() THEN RETURN END;

  IF ~LoadQuery(queryFile) THEN RETURN END;

  IF ~alnMode THEN
    Out.String("qseqid");   Out.Char(9X); Out.String("sseqid");   Out.Char(9X);
    Out.String("pident");   Out.Char(9X); Out.String("length");   Out.Char(9X);
    Out.String("mismatch"); Out.Char(9X); Out.String("gapopen");  Out.Char(9X);
    Out.String("qstart");   Out.Char(9X); Out.String("qend");     Out.Char(9X);
    Out.String("sstart");   Out.Char(9X); Out.String("send");     Out.Char(9X);
    Out.String("evalue");   Out.Char(9X); Out.String("bitscore"); Out.Ln
  END;

  SearchDB(dbFile)
END SeqBlast.
