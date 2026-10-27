MODULE OrthoFind;
(*
  OrthoFind — Reciprocal Best Hit ortholog finder for protein FASTA files.

  Algorithm:
    1. Load one protein FASTA file per organism.
    2. For each ordered pair (A, B) find the best-scoring hit for every
       protein in A among all proteins in B using exact 3-mer seeds
       extended with BLOSUM62-scored X-drop (same style as SeqBlast).
    3. A pair (a, b) is a Reciprocal Best Hit (RBH) iff a's best hit in
       B is b and b's best hit in A is a.
    4. For N >= 2 organisms a group {p_0,...,p_{N-1}} is valid iff every
       pair (p_i, p_j) is an RBH.  Groups are enumerated by anchoring on
       organism 0 and checking pairwise RBH for all other pairs.
    5. Output a TSV to stdout: columns "group", then one per organism.

  Limits: MaxOrgs organisms, MaxProts proteins per organism, sequences
  truncated to SeqBuf-1 amino acids.

  Implementation notes (performance):
    * All sequences are flattened once into a single residue-code pool
      (A..Z -> 0..25, anything else -> 26) so the inner loops never touch
      BioSeq chunk lists; BLOSUM62 is a flat 27x27 lookup table.
    * Each unordered pair {I, J} is scored once.  Seed + X-drop scoring
      is symmetric, so one pass over I's queries yields both I->J row
      maxima and J->I column maxima.  This halves the work.
    * Instead of scanning every subject position per query, a 3-mer
      inverted index of the subject proteome is built (per worker) and
      only true seed matches are visited.
    * Seed hits of one query are bucketed per subject protein.  Which
      seeds get the (comparatively expensive) X-drop extension depends on
      the mode:
        -x        every seed (exhaustive; exact max over seeds).
        default   seeds on a diagonal that carries >= 2 seeds (BLAST's
                  two-hit rule, any distance by default; -w limits it),
                  extended once per HSP (seeds inside the region a previous
                  extension covered are skipped); every seed of a protein
                  pair whose seed count is far above chance (-z); and
                  isolated seeds whose PreR-residue flanks score >= -t.
        -f        as default but isolated seeds are never extended.
      On synthetic orthologs (4 genomes x 1000 families + paralogs) the
      modes found, at ~52% / ~35% / ~23% pairwise identity:
        -x       1000 / 979 / 479 groups      (1x)
        default  1000 / 966 / 417 groups      (~5x faster than -x)
        -f       1000 / 946 / 368 groups      (~8x faster than -x)
      Above ~50% identity all modes agree exactly on every test set.
    * Work is split into units = (pair, chunk of I's queries).  The
      number of chunks per pair grows when there are few pairs, so two
      large proteomes still saturate all CPUs.  Each worker thread owns
      its scratch index and strides over the unit list.
    * Best-hit tables are heap-allocated to the actual input size:
      orgCount * orgCount * (largest protein count) integers, ~100 MB at
      the 50 x 5000 maximum.  Per-worker scratch is a few MB.
    * Measured on 10 cores: 2 x 5000 proteins ~2 s wall; the 50 x 5000
      maximum extrapolates to roughly 30-40 min (default mode).
*)

IMPORT BioIO, BioSeq, BioAlign, Out, Args, Strings, Parallel;

CONST
  MaxOrgs  = 50;
  MaxProts = 5000;
  SeqBuf   = 4096;
  W        = 3;      (* protein seed word size *)
  XDrop    = 30;     (* BLOSUM62 X-drop threshold *)
  MinScore = 40;     (* minimum raw score to record a hit *)
  NCodes   = 27;     (* residue codes: 0..25 = A..Z, 26 = other *)
  HashSz   = 17576;  (* 26^3: all 3-mers of letters *)
  MaxWorkers = 256;                           (* cap on worker threads *)
  MaxPairs   = 1225;                          (* MaxOrgs*(MaxOrgs-1)/2 unordered pairs *)
  OverSub    = 8;                             (* target work units per worker *)
  MaxUnits   = MaxPairs + OverSub * MaxWorkers;
  Window     = 0;       (* two-hit window (residues along the diagonal); 0 = any distance *)
  CountZ2    = 4.0;     (* seed-count test: excess^2 > CountZ2 * expected (z = 2) *)
  CountMin   = 3;       (* ... and excess > CountMin seeds *)
  PreR       = 6;       (* residues checked on each side of an isolated seed (PreCheck) *)
  InitHitCap = 65536;   (* initial per-worker seed-hit buffer size *)

TYPE
  IntVec  = POINTER TO ARRAY OF INTEGER;
  CharVec = POINTER TO ARRAY OF CHAR;

VAR
  twoHit   : BOOLEAN;  (* FALSE (-x) = extend every seed (exhaustive) *)
  sensitive: BOOLEAN;  (* FALSE (-f) = never extend isolated seeds; TRUE = extend those passing PreCheck *)
  window   : INTEGER;  (* -w: two-hit diagonal window (default Window) *)
  preT     : INTEGER;  (* -t: PreCheck score needed to extend an isolated seed *)
  countZ2  : REAL;     (* -z: squared z-score for the seed-count test (default CountZ2) *)
  dump     : BOOLEAN;  (* -dump: print best-hit tables (debug) *)
  orgCount : INTEGER;
  orgLabel : ARRAY MaxOrgs OF ARRAY 256 OF CHAR;
  protCnt  : ARRAY MaxOrgs OF INTEGER;
  protSeq  : ARRAY MaxOrgs OF ARRAY MaxProts OF BioSeq.Seq;  (* kept for names *)

  (* Flattened residue codes: protein (o, m) occupies pool[protOff[o][m] ..
     protOff[o][m] + protLen[o][m] - 1]. *)
  pool     : CharVec;
  poolLen  : INTEGER;
  protOff  : ARRAY MaxOrgs OF ARRAY MaxProts OF INTEGER;
  protLen  : ARRAY MaxOrgs OF ARRAY MaxProts OF INTEGER;
  orgRes   : ARRAY MaxOrgs OF INTEGER;  (* residues per organism *)
  maxRes   : INTEGER;                   (* largest orgRes *)

  scoreTab : ARRAY NCodes * NCodes OF INTEGER;  (* BLOSUM62 by residue code *)

  (* Best hit of protein k from org i in org j (-1 = none), stored flat at
     HitIdx(i, j, k).  hitStride = max protCnt over all loaded organisms. *)
  bestHit  : IntVec;
  bestScore: IntVec;
  hitStride: INTEGER;

(* Work units and per-worker scratch space. *)
VAR
  unitI, unitJ   : ARRAY MaxUnits OF INTEGER;  (* query org I < indexed org J *)
  unitQ0, unitQ1 : ARRAY MaxUnits OF INTEGER;  (* query range [Q0, Q1) in org I *)
  unitColIdx     : ARRAY MaxUnits OF IntVec;   (* J->I column best (index) *)
  unitColScr     : ARRAY MaxUnits OF IntVec;   (* J->I column best (score) *)
  unitCnt        : INTEGER;
  nWorkers       : INTEGER;

  wkIdxOrg : ARRAY MaxWorkers OF INTEGER;  (* org currently indexed; -1 = none *)
  wkStart  : ARRAY MaxWorkers OF IntVec;   (* HashSz + 1 bucket starts *)
  wkCur    : ARRAY MaxWorkers OF IntVec;   (* HashSz fill cursors *)
  wkPostP  : ARRAY MaxWorkers OF IntVec;   (* maxRes postings: subject protein *)
  wkPostS  : ARRAY MaxWorkers OF IntVec;   (* maxRes postings: position in it *)
  wkSumSq  : ARRAY MaxWorkers OF REAL;     (* P(two random 3-mers of the indexed org match) *)
  (* per-query seed-hit lists, bucketed by subject protein *)
  wkHead   : ARRAY MaxWorkers OF IntVec;   (* hitStride: first hit per subject, -1 *)
  wkTouched: ARRAY MaxWorkers OF IntVec;   (* hitStride: subjects with hits *)
  wkCnt    : ARRAY MaxWorkers OF IntVec;   (* hitStride: hits per subject *)
  wkHitQ   : ARRAY MaxWorkers OF IntVec;   (* query position of hit *)
  wkHitS   : ARRAY MaxWorkers OF IntVec;   (* subject position of hit *)
  wkNext   : ARRAY MaxWorkers OF IntVec;   (* next hit in the subject's list *)
  wkHitCap : ARRAY MaxWorkers OF INTEGER;
  (* per-(query, subject) diagonal state, validated by stamp *)
  wkDiagLast : ARRAY MaxWorkers OF IntVec; (* 2*SeqBuf: last seed qi on diagonal *)
  wkDiagPair : ARRAY MaxWorkers OF IntVec; (* 2*SeqBuf: 1 if two seeds within window *)
  wkDiagLo   : ARRAY MaxWorkers OF IntVec; (* 2*SeqBuf: left end of last extended HSP *)
  wkDiagStamp: ARRAY MaxWorkers OF IntVec; (* 2*SeqBuf *)
  wkStamp    : ARRAY MaxWorkers OF INTEGER;

PROCEDURE HitIdx(i, j, k: INTEGER): INTEGER;
BEGIN RETURN (i * orgCount + j) * hitStride + k END HitIdx;

PROCEDURE Min(a, b: INTEGER): INTEGER;
BEGIN IF a < b THEN RETURN a ELSE RETURN b END END Min;

(* ------------------------------------------------------------------ *)
(*  Residue codes, scoring, 3-mer keys                                  *)
(* ------------------------------------------------------------------ *)

PROCEDURE Code(c: CHAR): CHAR;
(* Map a residue character to its code 0..26 (stored as CHR). *)
BEGIN
  IF (c >= 'a') & (c <= 'z') THEN RETURN CHR(ORD(c) - ORD('a'))
  ELSIF (c >= 'A') & (c <= 'Z') THEN RETURN CHR(ORD(c) - ORD('A'))
  ELSE RETURN CHR(26)
  END
END Code;

PROCEDURE BuildScoreTab;
VAR a, b: INTEGER; ca, cb: CHAR; mat: BioAlign.ScoreMatrix;
BEGIN
  BioAlign.BLOSUM62(mat);
  FOR a := 0 TO NCodes - 1 DO
    IF a < 26 THEN ca := CHR(ORD('A') + a) ELSE ca := '*' END;
    FOR b := 0 TO NCodes - 1 DO
      IF b < 26 THEN cb := CHR(ORD('A') + b) ELSE cb := '*' END;
      scoreTab[a * NCodes + b] := BioAlign.PairScore(mat, ca, cb)
    END
  END
END BuildScoreTab;

PROCEDURE Key(off: INTEGER): INTEGER;
(* 3-mer key of pool[off..off+2]; -1 if any residue is not a letter. *)
VAR a, b, c: INTEGER;
BEGIN
  a := ORD(pool[off]); b := ORD(pool[off + 1]); c := ORD(pool[off + 2]);
  IF (a > 25) OR (b > 25) OR (c > 25) THEN RETURN -1 END;
  RETURN a * 676 + b * 26 + c
END Key;

(* ------------------------------------------------------------------ *)
(*  X-drop extension on the flat pool                                   *)
(* ------------------------------------------------------------------ *)

PROCEDURE ExtRight(a, b, n, drop: INTEGER): INTEGER;
(* Extend right from pool offsets a (query) and b (subject) for at most n
   residues with X-drop threshold drop; return the best cumulative score. *)
VAR best, cur, d: INTEGER;
BEGIN
  best := 0; cur := 0; d := 0;
  WHILE d < n DO
    INC(cur, scoreTab[ORD(pool[a + d]) * NCodes + ORD(pool[b + d])]);
    IF cur > best THEN best := cur END;
    IF best - cur >= drop THEN d := n ELSE INC(d) END
  END;
  RETURN best
END ExtRight;

(* ------------------------------------------------------------------ *)
(*  Subject index (per worker)                                          *)
(* ------------------------------------------------------------------ *)

PROCEDURE BuildIndex(wi, org: INTEGER);
(* Counting-sort all 3-mers of org into wkPostP/wkPostS[wi], bucketed by
   key.  Bucket k occupies entries wkStart[wi][k] .. wkStart[wi][k+1] - 1;
   postings are ordered by (protein, position). *)
VAR m, i, k, off, len: INTEGER;
    sum, b: REAL;
    start, cur, postP, postS: IntVec;
BEGIN
  start := wkStart[wi]; cur := wkCur[wi];
  postP := wkPostP[wi]; postS := wkPostS[wi];
  FOR k := 0 TO HashSz DO start[k] := 0 END;
  FOR m := 0 TO protCnt[org] - 1 DO
    off := protOff[org][m]; len := protLen[org][m];
    FOR i := 0 TO len - W DO
      k := Key(off + i);
      IF k >= 0 THEN INC(start[k + 1]) END
    END
  END;
  FOR k := 1 TO HashSz DO start[k] := start[k] + start[k - 1] END;
  FOR k := 0 TO HashSz - 1 DO cur[k] := start[k] END;
  (* probability that two random 3-mers (subject distribution) coincide *)
  sum := 0.0;
  FOR k := 0 TO HashSz - 1 DO
    b := FLT(start[k + 1] - start[k]); sum := sum + b * b
  END;
  b := FLT(start[HashSz]);
  IF b > 0.0 THEN wkSumSq[wi] := sum / (b * b) ELSE wkSumSq[wi] := 0.0 END;
  FOR m := 0 TO protCnt[org] - 1 DO
    off := protOff[org][m]; len := protLen[org][m];
    FOR i := 0 TO len - W DO
      k := Key(off + i);
      IF k >= 0 THEN postP[cur[k]] := m; postS[cur[k]] := i; INC(cur[k]) END
    END
  END;
  wkIdxOrg[wi] := org
END BuildIndex;

(* ------------------------------------------------------------------ *)
(*  Pair scoring                                                        *)
(* ------------------------------------------------------------------ *)

PROCEDURE GrowHits(wi: INTEGER);
(* Double worker wi's hit buffers, preserving contents. *)
VAR oq, os, on, nq, ns, nn: IntVec; i, cap: INTEGER;
BEGIN
  cap := wkHitCap[wi];
  oq := wkHitQ[wi]; os := wkHitS[wi]; on := wkNext[wi];
  NEW(nq, cap * 2); NEW(ns, cap * 2); NEW(nn, cap * 2);
  FOR i := 0 TO cap - 1 DO nq[i] := oq[i]; ns[i] := os[i]; nn[i] := on[i] END;
  FREE(oq); FREE(os); FREE(on);
  wkHitQ[wi] := nq; wkHitS[wi] := ns; wkNext[wi] := nn; wkHitCap[wi] := cap * 2
END GrowHits;

PROCEDURE Extend(qoff, qi, qlen, soff, sj, slen, drop: INTEGER; VAR ld: INTEGER): INTEGER;
(* Seed score of the exact 3-mer at (qi, sj) plus X-drop extensions both
   ways.  ld returns how far left (in residues) the best extension reached. *)
VAR t, best, cur, d, n: INTEGER;
BEGIN
  t := scoreTab[ORD(pool[qoff + qi])     * NCodes + ORD(pool[qoff + qi])]
     + scoreTab[ORD(pool[qoff + qi + 1]) * NCodes + ORD(pool[qoff + qi + 1])]
     + scoreTab[ORD(pool[qoff + qi + 2]) * NCodes + ORD(pool[qoff + qi + 2])];
  (* left *)
  n := Min(qi, sj); best := 0; cur := 0; d := 1; ld := 0;
  WHILE d <= n DO
    INC(cur, scoreTab[ORD(pool[qoff + qi - d]) * NCodes + ORD(pool[soff + sj - d])]);
    IF cur > best THEN best := cur; ld := d END;
    IF best - cur >= drop THEN d := n + 1 ELSE INC(d) END
  END;
  INC(t, best);
  INC(t, ExtRight(qoff + qi + W, soff + sj + W, Min(qlen - qi - W, slen - sj - W), drop));
  RETURN t
END Extend;

PROCEDURE Score(qoff, qi, qlen, soff, sj, slen, q, s: INTEGER;
                VAR rowScr, rowIdx: INTEGER; colScr, colIdx: IntVec; VAR ld: INTEGER);
(* Extend seed (qi, sj) of query q vs subject s and fold the score into the
   row (q's best subject) and column (s's best query) maxima.  Row ties
   keep the lowest subject index; column ties keep the lowest query index
   (queries arrive in ascending order). *)
VAR t: INTEGER;
BEGIN
  t := Extend(qoff, qi, qlen, soff, sj, slen, XDrop, ld);
  IF (t > rowScr) OR ((t = rowScr) & (s < rowIdx)) THEN rowScr := t; rowIdx := s END;
  IF t > colScr[s] THEN colScr[s] := t; colIdx[s] := q END
END Score;

PROCEDURE PreCheck(qoff, qi, qlen, soff, sj, slen: INTEGER): INTEGER;
(* Cheap context test for an isolated seed: summed BLOSUM62 score of the
   PreR residues on each side of the 3-mer (clipped at sequence ends).
   Homologous context averages about +1 per residue, random about -1. *)
VAR k, nl, nr, t: INTEGER;
BEGIN
  nl := Min(PreR, Min(qi, sj));
  nr := Min(PreR, Min(qlen - qi - W, slen - sj - W));
  t := 0;
  FOR k := 1 TO nl DO
    INC(t, scoreTab[ORD(pool[qoff + qi - k]) * NCodes + ORD(pool[soff + sj - k])])
  END;
  FOR k := 0 TO nr - 1 DO
    INC(t, scoreTab[ORD(pool[qoff + qi + W + k]) * NCodes + ORD(pool[soff + sj + W + k])])
  END;
  RETURN t
END PreCheck;

PROCEDURE RunUnit(wi, u: INTEGER);
(* Score queries [unitQ0, unitQ1) of org I against every protein of org J.
   Row maxima (I->J) go straight into bestHit/bestScore (each query index
   is owned by exactly one unit).  Column maxima (J->I) are collected in
   per-unit arrays and merged serially afterwards.

   Per query: (1) gather all seed hits from the subject index into
   per-subject linked lists, then (2) walk each subject's hits (descending
   query position).  Exhaustive mode (-x) extends every seed.  Otherwise
   pass A marks diagonals that carry two seeds (within -w residues, any
   distance by default) and pass B extends: seeds on marked diagonals,
   once per HSP; all seeds of pairs whose seed count is far above chance;
   and, unless -f, isolated seeds whose flanks pass PreCheck. *)
VAR
  orgI, orgJ, q, qi, qoff, qlen, key, p, s, sj, soff, slen: INTEGER;
  rowIdx, rowScr, nHit, nTouch, ti, h, d, ld, stamp: INTEGER;
  expect, excess: REAL;
  allSeeds: BOOLEAN;
  start, postP, postS, colIdx, colScr, head, touched, cnt, hitQ, hitS, next: IntVec;
  diagLast, diagPair, diagLo, diagStamp: IntVec;
BEGIN
  orgI := unitI[u]; orgJ := unitJ[u];
  IF wkIdxOrg[wi] # orgJ THEN BuildIndex(wi, orgJ) END;
  start := wkStart[wi]; postP := wkPostP[wi]; postS := wkPostS[wi];
  head := wkHead[wi]; touched := wkTouched[wi]; cnt := wkCnt[wi];
  hitQ := wkHitQ[wi]; hitS := wkHitS[wi]; next := wkNext[wi];
  diagLast := wkDiagLast[wi]; diagPair := wkDiagPair[wi];
  diagLo := wkDiagLo[wi]; diagStamp := wkDiagStamp[wi];
  stamp := wkStamp[wi];

  NEW(colIdx, protCnt[orgJ]); NEW(colScr, protCnt[orgJ]);
  FOR s := 0 TO protCnt[orgJ] - 1 DO colIdx[s] := -1; colScr[s] := MinScore - 1 END;

  FOR q := unitQ0[u] TO unitQ1[u] - 1 DO
    qoff := protOff[orgI][q]; qlen := protLen[orgI][q];

    (* (1) gather seed hits, bucketed by subject protein *)
    nHit := 0; nTouch := 0;
    FOR qi := 0 TO qlen - W DO
      key := Key(qoff + qi);
      IF key >= 0 THEN
        FOR p := start[key] TO start[key + 1] - 1 DO
          s := postP[p];
          IF nHit = wkHitCap[wi] THEN
            GrowHits(wi); hitQ := wkHitQ[wi]; hitS := wkHitS[wi]; next := wkNext[wi]
          END;
          hitQ[nHit] := qi; hitS[nHit] := postS[p];
          IF head[s] < 0 THEN touched[nTouch] := s; INC(nTouch) END;
          next[nHit] := head[s]; head[s] := nHit; INC(cnt[s]);
          INC(nHit)
        END
      END
    END;

    (* (2) extend per subject *)
    rowIdx := -1; rowScr := MinScore - 1;
    FOR ti := 0 TO nTouch - 1 DO
      s := touched[ti];
      soff := protOff[orgJ][s]; slen := protLen[orgJ][s];
      INC(stamp);
      IF stamp >= 1073741824 THEN
        FOR d := 0 TO 2 * SeqBuf - 1 DO diagStamp[d] := 0 END;
        stamp := 1
      END;
      h := head[s];
      IF ~twoHit THEN
        WHILE h >= 0 DO
          Score(qoff, hitQ[h], qlen, soff, hitS[h], slen, q, s, rowScr, rowIdx, colScr, colIdx, ld);
          h := next[h]
        END
      ELSE
        (* Pairs with far more seeds than chance predicts are probably
           homologous even without two seeds on one diagonal (indels break
           diagonals): extend all their seeds (still once per HSP). *)
        expect := FLT(qlen - W + 1) * FLT(slen - W + 1) * wkSumSq[wi];
        excess := FLT(cnt[s]) - expect - FLT(CountMin);
        allSeeds := (excess > 0.0) & (excess * excess > countZ2 * expect);
        (* pass A: mark diagonals carrying two seeds within the window *)
        WHILE h >= 0 DO
          qi := hitQ[h]; d := hitS[h] - qi + SeqBuf;
          IF diagStamp[d] = stamp THEN
            IF (window <= 0) OR (diagLast[d] - qi <= window) THEN diagPair[d] := 1 END
          ELSE
            diagStamp[d] := stamp; diagPair[d] := 0; diagLo[d] := 2 * SeqBuf
          END;
          diagLast[d] := qi;
          h := next[h]
        END;
        (* pass B: score seeds on paired diagonals once per HSP (seeds
           inside the region a previous extension covered are skipped);
           isolated seeds only if their flanks pass PreCheck (never with -f) *)
        h := head[s];
        WHILE h >= 0 DO
          qi := hitQ[h]; sj := hitS[h]; d := sj - qi + SeqBuf;
          IF allSeeds OR (diagPair[d] = 1) THEN
            IF qi < diagLo[d] THEN
              Score(qoff, qi, qlen, soff, sj, slen, q, s, rowScr, rowIdx, colScr, colIdx, ld);
              diagLo[d] := qi - ld
            END
          ELSIF sensitive & (PreCheck(qoff, qi, qlen, soff, sj, slen) >= preT) THEN
            Score(qoff, qi, qlen, soff, sj, slen, q, s, rowScr, rowIdx, colScr, colIdx, ld)
          END;
          h := next[h]
        END
      END;
      head[s] := -1; cnt[s] := 0
    END;

    bestHit  [HitIdx(orgI, orgJ, q)] := rowIdx;
    bestScore[HitIdx(orgI, orgJ, q)] := rowScr
  END;
  wkStamp[wi] := stamp;
  unitColIdx[u] := colIdx;
  unitColScr[u] := colScr
END RunUnit;

PROCEDURE WorkerBody(wi: INTEGER);
(* Parallel.For body: worker wi processes every nWorkers-th unit from wi. *)
VAR u: INTEGER;
BEGIN
  u := wi;
  WHILE u < unitCnt DO
    RunUnit(wi, u);
    INC(u, nWorkers)
  END
END WorkerBody;

PROCEDURE MergeColumns;
(* Fold the per-unit J->I column maxima into bestHit/bestScore.  Units of
   one pair are visited in ascending query order, and ties keep the first
   (lowest) query index, matching the row-side tie rule. *)
VAR u, s, orgI, orgJ, h: INTEGER; colIdx, colScr: IntVec;
BEGIN
  FOR u := 0 TO unitCnt - 1 DO
    orgI := unitI[u]; orgJ := unitJ[u];
    colIdx := unitColIdx[u]; colScr := unitColScr[u];
    FOR s := 0 TO protCnt[orgJ] - 1 DO
      h := HitIdx(orgJ, orgI, s);
      IF colScr[s] > bestScore[h] THEN
        bestScore[h] := colScr[s]; bestHit[h] := colIdx[s]
      END
    END;
    FREE(colIdx); FREE(colScr);
    unitColIdx[u] := NIL; unitColScr[u] := NIL
  END
END MergeColumns;

(* ------------------------------------------------------------------ *)
(*  I/O helpers                                                         *)
(* ------------------------------------------------------------------ *)

PROCEDURE LoadOrg(idx: INTEGER; path: ARRAY OF CHAR): BOOLEAN;
VAR
  rdr   : BioIO.FastaReader;
  rec   : BioIO.FastaRecord;
  cnt, total, len : INTEGER;
BEGIN
  IF ~BioIO.OpenFasta(rdr, path) THEN
    Out.String("Error: cannot open "); Out.String(path); Out.Ln;
    RETURN FALSE
  END;
  cnt := 0; total := 0; orgRes[idx] := 0;
  rec.seq := NIL;
  WHILE BioIO.ReadFasta(rdr, rec) DO
    IF cnt < MaxProts THEN
      protSeq[idx][cnt] := rec.seq;
      len := BioSeq.Length(rec.seq);
      IF len >= SeqBuf THEN len := SeqBuf - 1 END;
      protLen[idx][cnt] := len;
      INC(orgRes[idx], len);
      rec.seq := NIL;  (* detach; next ReadFasta allocates fresh *)
      INC(cnt)
    END;
    INC(total)
  END;
  BioIO.CloseFasta(rdr);
  IF total > MaxProts THEN
    Out.String("Warning: "); Out.String(path);
    Out.String(": "); Out.Int(total, 0);
    Out.String(" proteins, truncated to "); Out.Int(MaxProts, 0); Out.Ln
  END;
  protCnt[idx] := cnt;
  RETURN cnt > 0
END LoadOrg;

PROCEDURE BuildPool(): BOOLEAN;
(* Flatten every loaded protein into pool as residue codes. *)
VAR o, m, i, len, off: INTEGER; buf: ARRAY SeqBuf OF CHAR;
BEGIN
  poolLen := 0; maxRes := 0;
  FOR o := 0 TO orgCount - 1 DO
    INC(poolLen, orgRes[o]);
    IF orgRes[o] > maxRes THEN maxRes := orgRes[o] END
  END;
  NEW(pool, poolLen + 1);
  IF pool = NIL THEN RETURN FALSE END;
  off := 0;
  FOR o := 0 TO orgCount - 1 DO
    FOR m := 0 TO protCnt[o] - 1 DO
      len := protLen[o][m];
      BioSeq.Slice(protSeq[o][m], 0, len, buf);
      protOff[o][m] := off;
      FOR i := 0 TO len - 1 DO pool[off + i] := Code(buf[i]) END;
      INC(off, len)
    END
  END;
  RETURN TRUE
END BuildPool;

PROCEDURE BaseName(path: ARRAY OF CHAR; VAR label: ARRAY OF CHAR);
(* Derive a short label from a file path: strip directory and extensions. *)
VAR
  i, j, len, lastSlash, lastDot: INTEGER;
  buf: ARRAY 256 OF CHAR;
BEGIN
  len := Strings.Length(path);
  lastSlash := -1;
  FOR i := 0 TO len - 1 DO
    IF (path[i] = '/') OR (path[i] = '\') THEN lastSlash := i END
  END;
  (* copy basename *)
  j := 0;
  i := lastSlash + 1;
  WHILE (i < len) & (j < 254) DO
    buf[j] := path[i]; INC(j); INC(i)
  END;
  buf[j] := 0X;
  (* strip .gz *)
  len := Strings.Length(buf);
  IF Strings.EndsWith(buf, ".gz") THEN
    buf[len - 3] := 0X; len := len - 3
  END;
  (* strip last extension *)
  lastDot := -1;
  FOR i := 0 TO len - 1 DO
    IF buf[i] = '.' THEN lastDot := i END
  END;
  IF lastDot > 0 THEN buf[lastDot] := 0X END;
  COPY(buf, label)
END BaseName;

(* ------------------------------------------------------------------ *)
(*  Group output                                                        *)
(* ------------------------------------------------------------------ *)

PROCEDURE DumpHits;
(* Debug aid (-dump): print every best hit with its score. *)
VAR i, j, k, h: INTEGER;
BEGIN
  Out.String("#cfg"); Out.Char(9X);
  IF twoHit THEN Out.String("two-hit") ELSE Out.String("exhaustive") END;
  Out.Char(9X); Out.String("window="); Out.Int(window, 0);
  Out.Char(9X); Out.String("sensitive="); IF sensitive THEN Out.String("yes") ELSE Out.String("no") END;
  Out.Char(9X); Out.String("preT="); Out.Int(preT, 0);
  Out.Char(9X); Out.String("workers="); Out.Int(nWorkers, 0);
  Out.Char(9X); Out.String("units="); Out.Int(unitCnt, 0); Out.Ln;
  FOR i := 0 TO orgCount - 1 DO
    FOR j := 0 TO orgCount - 1 DO
      IF i # j THEN
        FOR k := 0 TO protCnt[i] - 1 DO
          h := HitIdx(i, j, k);
          Out.String("#hit"); Out.Char(9X); Out.String(protSeq[i][k].name); Out.Char(9X);
          IF bestHit[h] >= 0 THEN Out.String(protSeq[j][bestHit[h]].name) ELSE Out.String("-") END;
          Out.Char(9X); Out.Int(bestScore[h], 0); Out.Ln
        END
      END
    END
  END
END DumpHits;

PROCEDURE OutputGroups;
VAR
  i, j, p0, pj, pi, grpNum: INTEGER;
  partner: ARRAY MaxOrgs OF INTEGER;
  ok: BOOLEAN;
BEGIN
  (* Header *)
  Out.String("group");
  FOR i := 0 TO orgCount - 1 DO
    Out.Char(9X); Out.String(orgLabel[i])
  END;
  Out.Ln;

  grpNum := 0;
  FOR p0 := 0 TO protCnt[0] - 1 DO
    ok := TRUE;
    partner[0] := p0;

    (* Find RBH partners in orgs 1..N-1, anchoring on org 0 *)
    j := 1;
    WHILE ok & (j < orgCount) DO
      pj := bestHit[HitIdx(0, j, p0)];
      IF pj < 0 THEN
        ok := FALSE
      ELSIF bestHit[HitIdx(j, 0, pj)] # p0 THEN
        ok := FALSE
      END;
      partner[j] := pj;
      INC(j)
    END;

    (* For N > 2: also verify pairwise RBH among non-anchor orgs *)
    IF ok & (orgCount > 2) THEN
      i := 1;
      WHILE ok & (i < orgCount - 1) DO
        j := i + 1;
        WHILE ok & (j < orgCount) DO
          pi := partner[i]; pj := partner[j];
          IF bestHit[HitIdx(i, j, pi)] # pj THEN ok := FALSE
          ELSIF bestHit[HitIdx(j, i, pj)] # pi THEN ok := FALSE
          END;
          INC(j)
        END;
        INC(i)
      END
    END;

    IF ok THEN
      INC(grpNum);
      Out.String("OG");
      IF    grpNum < 10    THEN Out.String("0000")
      ELSIF grpNum < 100   THEN Out.String("000")
      ELSIF grpNum < 1000  THEN Out.String("00")
      ELSIF grpNum < 10000 THEN Out.String("0")
      END;
      Out.Int(grpNum, 0);
      FOR j := 0 TO orgCount - 1 DO
        Out.Char(9X); Out.String(protSeq[j][partner[j]].name)
      END;
      Out.Ln
    END
  END
END OutputGroups;

(* ------------------------------------------------------------------ *)
(*  Entry point                                                         *)
(* ------------------------------------------------------------------ *)

VAR
  i, j, jVal, nPairs, cpp, c, cs, q0, q1: INTEGER;
  v: IntVec;
  arg, tmp: ARRAY 1024 OF CHAR;

BEGIN
  orgCount := 0;
  twoHit := TRUE;
  sensitive := TRUE;
  window := Window;
  preT := 0;
  countZ2 := CountZ2;
  dump := FALSE;
  i := 1;
  WHILE i <= Args.Count() DO
    Args.Get(i, arg);
    IF Strings.Compare(arg, "-j") = 0 THEN
      INC(i);
      IF i <= Args.Count() THEN
        Args.Get(i, tmp);
        IF Strings.StrToInt(tmp, jVal) & (jVal > 0) THEN
          Parallel.SetMaxCPU(jVal)
        END
      END
    ELSIF Strings.Compare(arg, "-x") = 0 THEN
      twoHit := FALSE
    ELSIF Strings.Compare(arg, "-f") = 0 THEN
      sensitive := FALSE
    ELSIF Strings.Compare(arg, "-dump") = 0 THEN
      dump := TRUE
    ELSIF (Strings.Compare(arg, "-w") = 0) OR (Strings.Compare(arg, "-t") = 0)
       OR (Strings.Compare(arg, "-z") = 0) THEN
      (* tuning knobs for the two-hit filter *)
      INC(i);
      IF i <= Args.Count() THEN
        Args.Get(i, tmp);
        IF Strings.StrToInt(tmp, jVal) THEN
          IF    arg[1] = 'w' THEN window  := jVal
          ELSIF arg[1] = 'z' THEN countZ2 := FLT(jVal) * FLT(jVal) / 100.0  (* -z is z*10 *)
          ELSE                    preT    := jVal
          END
        END
      END
    ELSIF (arg[0] # '-') & (orgCount < MaxOrgs) THEN
      BaseName(arg, orgLabel[orgCount]);
      IF LoadOrg(orgCount, arg) THEN INC(orgCount) END
    END;
    INC(i)
  END;

  IF orgCount < 2 THEN
    Out.String("Usage: OrthoFind [options] <org1.faa> <org2.faa> [org3.faa ...]"); Out.Ln;
    Out.String("  -j <int>  max threads to use (default: all CPUs)"); Out.Ln;
    Out.String("  -f        fast: extend only seeds that share a diagonal with another"); Out.Ln;
    Out.String("            seed (BLAST two-hit).  Default additionally extends isolated"); Out.Ln;
    Out.String("            seeds whose "); Out.Int(PreR, 0);
    Out.String("-residue flanks score >= "); Out.Int(preT, 0); Out.String(" (see -t)."); Out.Ln;
    Out.String("  -x        exhaustive: extend every seed (exact; ~5x slower than default)"); Out.Ln;
    Out.String("  -t <int>  flank score threshold for isolated seeds (default 0; lower ="); Out.Ln;
    Out.String("            more sensitive, slower)"); Out.Ln;
    Out.String("  -w <int>  two-hit window in residues along the diagonal (default 0 = any)"); Out.Ln;
    Out.String("  -z <int>  10 x z-score above chance seed count at which a protein pair"); Out.Ln;
    Out.String("            is scored on all its seeds (default 20)"); Out.Ln;
    Out.String("  -dump     also print every best hit and score (debugging)"); Out.Ln;
    Out.String("  Finds orthologous protein groups via Reciprocal Best Hits."); Out.Ln;
    Out.String("  Input:  protein FASTA files, one per organism."); Out.Ln;
    Out.String("  Output: TSV on stdout (group + one column per organism)."); Out.Ln;
    Out.String("  Limits: "); Out.Int(MaxOrgs, 0); Out.String(" organisms, ");
    Out.Int(MaxProts, 0); Out.String(" proteins each, ");
    Out.Int(SeqBuf - 1, 0); Out.String(" AA max length."); Out.Ln;
    RETURN
  END;

  BuildScoreTab;
  IF ~BuildPool() THEN
    Out.String("Error: out of memory flattening sequences"); Out.Ln;
    RETURN
  END;

  (* Allocate the best-hit tables sized to the actual input. *)
  hitStride := 0;
  FOR i := 0 TO orgCount - 1 DO
    IF protCnt[i] > hitStride THEN hitStride := protCnt[i] END
  END;
  NEW(bestHit,   orgCount * orgCount * hitStride);
  NEW(bestScore, orgCount * orgCount * hitStride);
  IF (bestHit = NIL) OR (bestScore = NIL) THEN
    Out.String("Error: out of memory allocating best-hit tables"); Out.Ln;
    RETURN
  END;
  FOR i := 0 TO orgCount * orgCount * hitStride - 1 DO
    bestHit[i] := -1; bestScore[i] := MinScore - 1
  END;

  (* Build work units: every unordered pair {I < J}, with I's queries cut
     into chunks so that there are at least OverSub units per worker. *)
  nWorkers := Parallel.NumCPU();
  IF nWorkers > MaxWorkers THEN nWorkers := MaxWorkers END;
  IF nWorkers < 1 THEN nWorkers := 1 END;
  nPairs := orgCount * (orgCount - 1) DIV 2;
  cpp := (OverSub * nWorkers + nPairs - 1) DIV nPairs;
  IF cpp < 1 THEN cpp := 1 END;
  unitCnt := 0;
  FOR i := 0 TO orgCount - 2 DO
    FOR j := i + 1 TO orgCount - 1 DO
      c := Min(cpp, protCnt[i]);
      cs := (protCnt[i] + c - 1) DIV c;
      q0 := 0;
      WHILE q0 < protCnt[i] DO
        q1 := Min(q0 + cs, protCnt[i]);
        unitI[unitCnt] := i; unitJ[unitCnt] := j;
        unitQ0[unitCnt] := q0; unitQ1[unitCnt] := q1;
        INC(unitCnt);
        q0 := q1
      END
    END
  END;
  IF nWorkers > unitCnt THEN nWorkers := unitCnt END;

  (* Per-worker scratch: 3-mer index of one subject organism, seed-hit
     lists and diagonal state.  (NEW with a length needs a plain pointer
     variable, hence v.) *)
  FOR i := 0 TO nWorkers - 1 DO
    wkIdxOrg[i] := -1;
    NEW(v, HashSz + 1); wkStart[i] := v;
    NEW(v, HashSz);     wkCur[i]   := v;
    NEW(v, maxRes + 1); wkPostP[i] := v;
    NEW(v, maxRes + 1); wkPostS[i] := v;
    NEW(v, hitStride);  wkHead[i]  := v;
    FOR j := 0 TO hitStride - 1 DO v[j] := -1 END;
    NEW(v, hitStride);  wkTouched[i] := v;
    NEW(v, hitStride);  wkCnt[i] := v;            (* calloc: all zero *)
    NEW(v, InitHitCap); wkHitQ[i] := v;
    NEW(v, InitHitCap); wkHitS[i] := v;
    NEW(v, InitHitCap); wkNext[i] := v;
    wkHitCap[i] := InitHitCap;
    NEW(v, 2 * SeqBuf); wkDiagLast[i]  := v;
    NEW(v, 2 * SeqBuf); wkDiagPair[i]  := v;
    NEW(v, 2 * SeqBuf); wkDiagLo[i]    := v;
    NEW(v, 2 * SeqBuf); wkDiagStamp[i] := v;   (* calloc: all stamps 0 *)
    wkStamp[i] := 0
  END;

  Parallel.For(0, nWorkers, WorkerBody, nWorkers);
  MergeColumns;

  IF dump THEN DumpHits END;
  OutputGroups
END OrthoFind.
