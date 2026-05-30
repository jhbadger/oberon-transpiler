MODULE SeqBlast;
(*
  SeqBlast — BLAST-like ungapped local alignment search.

  Algorithm:
    1. Load query; extract every W-mer (default W=11).
    2. For each subject in the database, build a BM index per W-mer
       and collect exact seed hits.
    3. Extend each seed left/right with X-drop scoring.
    4. Filter by E-value <= threshold; deduplicate overlapping HSPs.
    5. Print tabular (-outfmt 6 style) or pairwise (-aln) output.

  E-value uses Karlin-Altschul statistics.
    Lambda = 0.318, K = 0.130 (match=1, mismatch=-3, ungapped DNA).
    Bit score = (Lambda * rawScore - ln(K)) / ln(2).
    E-value   = qLen * sLen * 2^(-bitScore).
*)

IMPORT BioIO, BioSeq, BioAlpha, BioPattern, Out, Args, Strings, OS, Files, Math;

CONST
  MaxHSPs = 512;
  MaxQLen = 65536;
  MaxW    = 32;

  TmpQ  = "/tmp/_seqblast_q.tmp";
  TmpDB = "/tmp/_seqblast_db.tmp";

  Lambda  = 0.318;
  KStat   = 0.130;

TYPE
  HSPRec = RECORD
    qStart, qEnd : INTEGER;
    sStart, sEnd : INTEGER;
    rawScore     : INTEGER;
    nIdent       : INTEGER;
    aLen         : INTEGER
  END;

VAR
  wordSize  : INTEGER;
  eThresh   : REAL;
  matchScr  : INTEGER;
  mmScr     : INTEGER;
  xDrop     : INTEGER;
  alnMode   : BOOLEAN;
  queryFile : ARRAY 1024 OF CHAR;
  dbFile    : ARRAY 1024 OF CHAR;

  hspList   : ARRAY MaxHSPs OF HSPRec;
  hspCount  : INTEGER;

  queryBuf  : ARRAY MaxQLen OF CHAR;
  queryLen  : INTEGER;

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

PROCEDURE ScoreRegion(subj: BioSeq.Seq; qi, si, len: INTEGER;
                      VAR raw, nIdent: INTEGER);
VAR i, s: INTEGER;
BEGIN
  raw := 0; nIdent := 0;
  FOR i := 0 TO len - 1 DO
    s := PairScore(qi + i, si + i, subj);
    INC(raw, s);
    IF s = matchScr THEN INC(nIdent) END
  END
END ScoreRegion;

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

PROCEDURE Overlaps(i, qS, qE, sS, sE: INTEGER): BOOLEAN;
VAR qOvl, sOvl, qSpan, sSpan: INTEGER;
BEGIN
  qOvl  := IntMin(hspList[i].qEnd, qE) - IntMax(hspList[i].qStart, qS) + 1;
  sOvl  := IntMin(hspList[i].sEnd, sE) - IntMax(hspList[i].sStart, sS) + 1;
  IF (qOvl <= 0) OR (sOvl <= 0) THEN RETURN FALSE END;
  qSpan := IntMin(hspList[i].qEnd - hspList[i].qStart + 1, qE - qS + 1);
  sSpan := IntMin(hspList[i].sEnd - hspList[i].sStart + 1, sE - sS + 1);
  RETURN (qOvl * 2 > qSpan) & (sOvl * 2 > sSpan)
END Overlaps;

PROCEDURE AddHSP(qS, qE, sS, sE, raw, nIdent, aLen: INTEGER);
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO hspCount - 1 DO
    IF Overlaps(i, qS, qE, sS, sE) THEN
      IF raw > hspList[i].rawScore THEN
        hspList[i].qStart   := qS;     hspList[i].qEnd   := qE;
        hspList[i].sStart   := sS;     hspList[i].sEnd   := sE;
        hspList[i].rawScore := raw;    hspList[i].nIdent := nIdent;
        hspList[i].aLen     := aLen
      END;
      RETURN
    END
  END;
  IF hspCount < MaxHSPs THEN
    hspList[hspCount].qStart   := qS;     hspList[hspCount].qEnd   := qE;
    hspList[hspCount].sStart   := sS;     hspList[hspCount].sEnd   := sE;
    hspList[hspCount].rawScore := raw;    hspList[hspCount].nIdent := nIdent;
    hspList[hspCount].aLen     := aLen;
    INC(hspCount)
  END
END AddHSP;

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
  qS, qE, sS, sE, raw, nIdent, aLen : INTEGER;
  ev          : REAL;
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

      qS   := qi0 - ld;       qE := qi0 + W - 1 + rd;
      sS   := si0 - ld;       sE := si0 + W - 1 + rs;
      aLen := qE - qS + 1;

      ScoreRegion(subj, qS, sS, aLen, raw, nIdent);
      IF raw > 0 THEN
        ev := CalcEvalue(raw, queryLen, sLen);
        IF ev <= eThresh THEN
          AddHSP(qS, qE, sS, sE, raw, nIdent, aLen)
        END
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
(* For minus strand: sstart > send (BLAST -outfmt 6 convention). *)
VAR i, ss, se: INTEGER; pct, ev, bs: REAL;
BEGIN
  FOR i := 0 TO hspCount - 1 DO
    ev  := CalcEvalue(hspList[i].rawScore, queryLen, sLen);
    bs  := BitScore(hspList[i].rawScore);
    pct := FLT(hspList[i].nIdent) / FLT(hspList[i].aLen) * 100.0;
    IF minus THEN
      ss := sLen - hspList[i].sStart;      (* 1-based, larger coord *)
      se := sLen - hspList[i].sEnd         (* 1-based, smaller coord *)
    ELSE
      ss := hspList[i].sStart + 1;
      se := hspList[i].sEnd   + 1
    END;
    Out.String("query"); Out.Char(9X);
    Out.String(subjName); Out.Char(9X);
    Out.Fixed(pct, 0, 2); Out.Char(9X);
    Out.Int(hspList[i].aLen, 0); Out.Char(9X);
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
CONST Width = 60;
VAR
  i, j, k, pos, sLo, sHi : INTEGER;
  ev, bs, pct              : REAL;
  qline, sline, mline      : ARRAY 61 OF CHAR;
  qc, sc                   : CHAR;
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
    IF minus THEN Out.String("  Strand: Plus/Minus")
    ELSE          Out.String("  Strand: Plus/Plus")
    END;
    Out.Ln; Out.Ln;

    pos := 0;
    WHILE pos < hspList[i].aLen DO
      k := IntMin(Width, hspList[i].aLen - pos);
      FOR j := 0 TO k - 1 DO
        qc := queryBuf[hspList[i].qStart + pos + j];
        sc := BioSeq.Get(subj, hspList[i].sStart + pos + j);
        IF (qc >= 'a') & (qc <= 'z') THEN qc := CAP(qc) END;
        IF (sc >= 'a') & (sc <= 'z') THEN sc := CAP(sc) END;
        qline[j] := qc; sline[j] := sc;
        IF qc = sc THEN mline[j] := '|' ELSE mline[j] := ' ' END
      END;
      qline[k] := 0X; sline[k] := 0X; mline[k] := 0X;

      (* Query coords: always increasing *)
      Out.String("Query "); Out.Int(hspList[i].qStart + pos + 1, 6);
      Out.String("  "); Out.String(qline);
      Out.String("  "); Out.Int(hspList[i].qStart + pos + k, 0); Out.Ln;
      Out.String("              "); Out.String(mline); Out.Ln;

      (* Sbjct coords: increasing (+) or decreasing (-) *)
      IF minus THEN
        sLo := sLen - hspList[i].sStart - pos;          (* start of block, 1-based *)
        sHi := sLen - hspList[i].sStart - pos - k + 1   (* end of block, 1-based *)
      ELSE
        sLo := hspList[i].sStart + pos + 1;
        sHi := hspList[i].sStart + pos + k
      END;
      Out.String("Sbjct "); Out.Int(sLo, 6);
      Out.String("  "); Out.String(sline);
      Out.String("  "); Out.Int(sHi, 0); Out.Ln;
      Out.Ln;
      INC(pos, k)
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
(*  Gzip helpers                                                        *)
(* ------------------------------------------------------------------ *)

PROCEDURE IsGzipped(fname: ARRAY OF CHAR): BOOLEAN;
BEGIN RETURN Strings.EndsWith(fname, ".gz") END IsGzipped;

PROCEDURE Decompress(fname, tmp: ARRAY OF CHAR): BOOLEAN;
VAR cmd: ARRAY 2048 OF CHAR;
BEGIN
  COPY("gunzip -c ", cmd);
  Strings.Append(fname, cmd);
  Strings.Append(" > ", cmd);
  Strings.Append(tmp, cmd);
  RETURN OS.Exec(cmd) = 0
END Decompress;

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
    Out.String("  -X <int>   X-drop threshold (default 20)"); Out.Ln;
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

VAR
  qGz, dbGz    : BOOLEAN;
  qPath, dbPath : ARRAY 1024 OF CHAR;

BEGIN
  IF ~ParseArgs() THEN RETURN END;

  qGz := IsGzipped(queryFile);
  IF qGz THEN
    IF ~Decompress(queryFile, TmpQ) THEN
      Out.String("Error: gunzip failed for query."); Out.Ln; RETURN
    END;
    COPY(TmpQ, qPath)
  ELSE
    COPY(queryFile, qPath)
  END;

  IF ~LoadQuery(qPath) THEN
    IF qGz THEN Files.Delete(TmpQ) END;
    RETURN
  END;

  dbGz := IsGzipped(dbFile);
  IF dbGz THEN
    IF ~Decompress(dbFile, TmpDB) THEN
      Out.String("Error: gunzip failed for DB."); Out.Ln;
      IF qGz THEN Files.Delete(TmpQ) END;
      RETURN
    END;
    COPY(TmpDB, dbPath)
  ELSE
    COPY(dbFile, dbPath)
  END;

  IF ~alnMode THEN
    Out.String("qseqid"); Out.Char(9X); Out.String("sseqid"); Out.Char(9X);
    Out.String("pident"); Out.Char(9X); Out.String("length"); Out.Char(9X);
    Out.String("qstart"); Out.Char(9X); Out.String("qend");   Out.Char(9X);
    Out.String("sstart"); Out.Char(9X); Out.String("send");   Out.Char(9X);
    Out.String("evalue"); Out.Char(9X); Out.String("bitscore"); Out.Ln
  END;

  SearchDB(dbPath);

  IF qGz  THEN Files.Delete(TmpQ)  END;
  IF dbGz THEN Files.Delete(TmpDB) END
END SeqBlast.
