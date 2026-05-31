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
  truncated to SeqBuf amino acids.
*)

IMPORT BioIO, BioSeq, BioAlign, Out, Args, Strings;

CONST
  MaxOrgs  = 8;
  MaxProts = 4096;
  SeqBuf   = 4096;
  W        = 3;      (* protein seed word size *)
  XDrop    = 30;     (* BLOSUM62 X-drop threshold *)
  MinScore = 40;     (* minimum raw score to record a hit *)
  HashSz   = 17576;  (* 26^3: all 3-mers of uppercase letters *)

VAR
  orgCount : INTEGER;
  orgLabel : ARRAY MaxOrgs OF ARRAY 256 OF CHAR;
  protCnt  : ARRAY MaxOrgs OF INTEGER;
  protSeq  : ARRAY MaxOrgs OF ARRAY MaxProts OF BioSeq.Seq;

  (* bestHit[i][j][k] = index of best hit of protein k from org i in org j; -1 = none *)
  bestHit  : ARRAY MaxOrgs OF ARRAY MaxOrgs OF ARRAY MaxProts OF INTEGER;
  bestScore: ARRAY MaxOrgs OF ARRAY MaxOrgs OF ARRAY MaxProts OF INTEGER;

  mat  : BioAlign.ScoreMatrix;   (* BLOSUM62, initialised in main body *)
  qbuf : ARRAY SeqBuf OF CHAR;   (* flat query sequence buffer *)
  qlen : INTEGER;
  sbuf : ARRAY SeqBuf OF CHAR;   (* flat subject sequence buffer *)
  slen : INTEGER;
  qhash: ARRAY HashSz OF INTEGER; (* 3-mer → first position in qbuf; -1 = absent *)

(* ------------------------------------------------------------------ *)
(*  Scoring                                                             *)
(* ------------------------------------------------------------------ *)

PROCEDURE Score2(a, b: CHAR): INTEGER;
BEGIN RETURN BioAlign.PairScore(mat, a, b) END Score2;

(* ------------------------------------------------------------------ *)
(*  3-mer hash                                                          *)
(* ------------------------------------------------------------------ *)

PROCEDURE HashKey(a, b, c: CHAR): INTEGER;
VAR ia, ib, ic: INTEGER;
BEGIN
  IF (a >= 'a') & (a <= 'z') THEN a := CHR(ORD(a) - 32) END;
  IF (b >= 'a') & (b <= 'z') THEN b := CHR(ORD(b) - 32) END;
  IF (c >= 'a') & (c <= 'z') THEN c := CHR(ORD(c) - 32) END;
  ia := ORD(a) - ORD('A');
  ib := ORD(b) - ORD('A');
  ic := ORD(c) - ORD('A');
  IF (ia < 0) OR (ia > 25) OR (ib < 0) OR (ib > 25) OR (ic < 0) OR (ic > 25) THEN
    RETURN -1
  END;
  RETURN ia * 676 + ib * 26 + ic
END HashKey;

PROCEDURE BuildHash;
(* Populate qhash from the current qbuf/qlen.  Only the first occurrence
   of each 3-mer is stored; later repeats are silently skipped. *)
VAR i, k: INTEGER;
BEGIN
  FOR i := 0 TO HashSz - 1 DO qhash[i] := -1 END;
  i := 0;
  WHILE i + W <= qlen DO
    k := HashKey(qbuf[i], qbuf[i + 1], qbuf[i + 2]);
    IF (k >= 0) & (qhash[k] < 0) THEN qhash[k] := i END;
    INC(i)
  END
END BuildHash;

(* ------------------------------------------------------------------ *)
(*  X-drop extension                                                    *)
(* ------------------------------------------------------------------ *)

PROCEDURE ExtRight(qi0, si0: INTEGER; VAR rd, rs: INTEGER);
(* Extend right from position (qi0, si0) in (qbuf, sbuf) using X-drop.
   Returns: rd = number of residues added; rs = best score. *)
VAR best, cur, d: INTEGER;
BEGIN
  best := 0; cur := 0; rd := 0; d := 0;
  LOOP
    IF (qi0 + d >= qlen) OR (si0 + d >= slen) THEN EXIT END;
    INC(cur, Score2(qbuf[qi0 + d], sbuf[si0 + d]));
    IF cur > best THEN best := cur; rd := d + 1 END;
    IF best - cur >= XDrop THEN EXIT END;
    INC(d)
  END;
  rs := best
END ExtRight;

PROCEDURE ExtLeft(qi0, si0: INTEGER; VAR ld, ls: INTEGER);
(* Extend left from position (qi0-1, si0-1).  Returns ld residues, ls score. *)
VAR best, cur, d: INTEGER;
BEGIN
  best := 0; cur := 0; ld := 0; d := 1;
  LOOP
    IF (qi0 - d < 0) OR (si0 - d < 0) THEN EXIT END;
    INC(cur, Score2(qbuf[qi0 - d], sbuf[si0 - d]));
    IF cur > best THEN best := cur; ld := d END;
    IF best - cur >= XDrop THEN EXIT END;
    INC(d)
  END;
  ls := best
END ExtLeft;

(* ------------------------------------------------------------------ *)
(*  Search                                                              *)
(* ------------------------------------------------------------------ *)

PROCEDURE FindBest(sOrg: INTEGER; VAR bIdx, bScr: INTEGER);
(* Search all proteins of sOrg against the current query (qbuf/qlen/qhash).
   Returns index and raw score of the best-scoring hit. *)
VAR
  m, j, k, qi, seedScr, ld, ls, rd, rs, total: INTEGER;
BEGIN
  bIdx := -1; bScr := MinScore - 1;
  FOR m := 0 TO protCnt[sOrg] - 1 DO
    slen := BioSeq.Length(protSeq[sOrg][m]);
    IF slen >= SeqBuf THEN slen := SeqBuf - 1 END;
    BioSeq.Slice(protSeq[sOrg][m], 0, slen, sbuf);
    sbuf[slen] := 0X;
    j := 0;
    WHILE j + W <= slen DO
      k := HashKey(sbuf[j], sbuf[j + 1], sbuf[j + 2]);
      IF (k >= 0) & (qhash[k] >= 0) THEN
        qi := qhash[k];
        (* W-mer seed score *)
        seedScr := Score2(qbuf[qi],     sbuf[j])
                 + Score2(qbuf[qi + 1], sbuf[j + 1])
                 + Score2(qbuf[qi + 2], sbuf[j + 2]);
        ExtLeft (qi,     j,     ld, ls);
        ExtRight(qi + W, j + W, rd, rs);
        total := ls + seedScr + rs;
        IF total > bScr THEN bScr := total; bIdx := m END
      END;
      INC(j)
    END
  END
END FindBest;

PROCEDURE ComputePair(orgI, orgJ: INTEGER);
(* Fill bestHit[orgI][orgJ][*] and bestScore[orgI][orgJ][*]. *)
VAR k, bIdx, bScr: INTEGER;
BEGIN
  FOR k := 0 TO protCnt[orgI] - 1 DO
    qlen := BioSeq.Length(protSeq[orgI][k]);
    IF qlen >= SeqBuf THEN qlen := SeqBuf - 1 END;
    BioSeq.Slice(protSeq[orgI][k], 0, qlen, qbuf);
    qbuf[qlen] := 0X;
    BuildHash;
    FindBest(orgJ, bIdx, bScr);
    bestHit  [orgI][orgJ][k] := bIdx;
    bestScore[orgI][orgJ][k] := bScr
  END
END ComputePair;

(* ------------------------------------------------------------------ *)
(*  I/O helpers                                                         *)
(* ------------------------------------------------------------------ *)

PROCEDURE LoadOrg(idx: INTEGER; path: ARRAY OF CHAR): BOOLEAN;
VAR
  rdr   : BioIO.FastaReader;
  rec   : BioIO.FastaRecord;
  cnt, total : INTEGER;
BEGIN
  IF ~BioIO.OpenFasta(rdr, path) THEN
    Out.String("Error: cannot open "); Out.String(path); Out.Ln;
    RETURN FALSE
  END;
  cnt := 0; total := 0;
  rec.seq := NIL;
  WHILE BioIO.ReadFasta(rdr, rec) DO
    IF cnt < MaxProts THEN
      protSeq[idx][cnt] := rec.seq;
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
      pj := bestHit[0][j][p0];
      IF pj < 0 THEN
        ok := FALSE
      ELSIF bestHit[j][0][pj] # p0 THEN
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
          IF bestHit[i][j][pi] # pj THEN ok := FALSE
          ELSIF bestHit[j][i][pj] # pi THEN ok := FALSE
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

VAR i, j: INTEGER; arg: ARRAY 1024 OF CHAR;

BEGIN
  orgCount := 0;
  i := 1;
  WHILE i <= Args.Count() DO
    Args.Get(i, arg);
    IF (arg[0] # '-') & (orgCount < MaxOrgs) THEN
      BaseName(arg, orgLabel[orgCount]);
      IF LoadOrg(orgCount, arg) THEN INC(orgCount) END
    END;
    INC(i)
  END;

  IF orgCount < 2 THEN
    Out.String("Usage: OrthoFind <org1.faa> <org2.faa> [org3.faa ...]"); Out.Ln;
    Out.String("  Finds orthologous protein groups via Reciprocal Best Hits."); Out.Ln;
    Out.String("  Input:  protein FASTA files, one per organism."); Out.Ln;
    Out.String("  Output: TSV on stdout (group + one column per organism)."); Out.Ln;
    Out.String("  Limits: "); Out.Int(MaxOrgs, 0); Out.String(" organisms, ");
    Out.Int(MaxProts, 0); Out.String(" proteins each, ");
    Out.Int(SeqBuf - 1, 0); Out.String(" AA max length."); Out.Ln;
    RETURN
  END;

  BioAlign.BLOSUM62(mat);

  FOR i := 0 TO orgCount - 1 DO
    FOR j := 0 TO orgCount - 1 DO
      IF i # j THEN ComputePair(i, j) END
    END
  END;

  OutputGroups
END OrthoFind.
