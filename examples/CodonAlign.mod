MODULE CodonAlign;
(*
  CodonAlign — Per-orthogroup nucleotide alignment with codon annotation.

  Algorithm:
    1. Read the OrthoFind TSV; derive organism count from the header.
    2. Load all nucleotide FASTA files (one per organism, in TSV column order).
    3. For each orthogroup, align the N sequences using star alignment
       anchored on organism 0 via Needleman-Wunsch (DefaultScore / DNA).
    4. Write <groupId>.afa containing, for each organism, two FASTA records:
         >OrgName     — aligned nucleotide sequence
         >OrgName_aa  — codon annotation; for each triplet of alignment columns
                        (0-indexed), position 0 and 2 are '-'; position 1 holds
                        the amino acid encoded by the triplet, or '-' if the
                        triplet contains a gap or N.

  Sequences longer than SeqLenCap nucleotides are truncated.
  Groups where any organism's sequence is absent are skipped.
*)

IMPORT BioIO, BioSeq, BioAlign, Files, Out, Args, Strings, Parallel;

CONST
  MaxOrgs        = 8;
  MaxProts       = 4096;
  MaxNameLen     = 128;
  HashTabSz      = 8192;
  SeqLenCap      = 10000;
  MaxAln         = 20002;
  MaxGapPos      = 10001;
  OutWidth       = 60;
  MaxAlignWorkers = MaxOrgs - 1;

VAR
  orgCount : INTEGER;
  orgLabel : ARRAY MaxOrgs OF ARRAY 256 OF CHAR;
  seqCnt   : ARRAY MaxOrgs OF INTEGER;
  seqStore : ARRAY MaxOrgs OF ARRAY MaxProts OF BioSeq.Seq;
  hashTab  : ARRAY MaxOrgs OF ARRAY HashTabSz OF INTEGER;

  mat      : BioAlign.ScoreMatrix;
  tmpR     : BioSeq.Seq;

  wkState  : ARRAY MaxAlignWorkers OF BioAlign.DPState;
  wkTmpQ   : ARRAY MaxAlignWorkers OF BioSeq.Seq;
  wkAln    : ARRAY MaxAlignWorkers OF BioAlign.Alignment;
  wkFlatBuf: ARRAY MaxAlignWorkers OF ARRAY SeqLenCap + 1 OF CHAR;

  alnQry   : ARRAY MaxOrgs OF ARRAY MaxAln OF CHAR;
  alnRef   : ARRAY MaxOrgs OF ARRAY MaxAln OF CHAR;
  alnLen   : ARRAY MaxOrgs OF INTEGER;
  gapsBef  : ARRAY MaxOrgs OF ARRAY MaxGapPos OF INTEGER;
  extraGaps: ARRAY MaxGapPos OF INTEGER;
  groupSeqs: ARRAY MaxOrgs OF BioSeq.Seq;
  seq0buf  : ARRAY SeqLenCap + 1 OF CHAR;
  seq0len  : INTEGER;

  alignedNt: ARRAY MaxOrgs OF ARRAY MaxAln OF CHAR;
  alnTotal : INTEGER;
  aaBuf    : ARRAY MaxAln OF CHAR;

  geneticCode : ARRAY 65 OF CHAR;

  (* Main-body variables *)
  tsvPath  : ARRAY 1024 OF CHAR;
  tsvLine  : ARRAY 4096 OF CHAR;
  tsvField : ARRAY MaxNameLen OF CHAR;
  groupId  : ARRAY 32 OF CHAR;
  tsvFile  : Files.File;
  tsvRider : Files.Rider;
  mainArg  : ARRAY 1024 OF CHAR;
  mainI, mainPos, mainIdx : INTEGER;
  mainOk   : BOOLEAN;

(* ------------------------------------------------------------------ *)
(*  Genetic code                                                        *)
(* ------------------------------------------------------------------ *)

PROCEDURE BaseIdx(c: CHAR): INTEGER;
(* Return TCAG index for c (T/U=0, C=1, A=2, G=3); -1 for gap or N. *)
BEGIN
  IF (c = 'T') OR (c = 't') OR (c = 'U') OR (c = 'u') THEN RETURN 0
  ELSIF (c = 'C') OR (c = 'c') THEN RETURN 1
  ELSIF (c = 'A') OR (c = 'a') THEN RETURN 2
  ELSIF (c = 'G') OR (c = 'g') THEN RETURN 3
  ELSE RETURN -1
  END
END BaseIdx;

PROCEDURE Translate(a, b, c: CHAR): CHAR;
(* Standard genetic code.  Returns '-' for any invalid base (gap, N, etc.). *)
VAR ia, ib, ic: INTEGER;
BEGIN
  ia := BaseIdx(a);  ib := BaseIdx(b);  ic := BaseIdx(c);
  IF (ia < 0) OR (ib < 0) OR (ic < 0) THEN RETURN '-' END;
  RETURN geneticCode[ia * 16 + ib * 4 + ic]
END Translate;

(* ------------------------------------------------------------------ *)
(*  File-writing helpers                                                *)
(* ------------------------------------------------------------------ *)

PROCEDURE WChar(VAR r: Files.Rider; c: CHAR);
BEGIN Files.Write(r, ORD(c)) END WChar;

PROCEDURE WStr(VAR r: Files.Rider; s: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (i < LEN(s)) & (s[i] # 0X) DO Files.Write(r, ORD(s[i])); INC(i) END
END WStr;

PROCEDURE WSeq(VAR r: Files.Rider; seq: ARRAY OF CHAR; len: INTEGER);
(* Write exactly len chars of seq, breaking at OutWidth. *)
VAR p, col: INTEGER;
BEGIN
  p := 0; col := 0;
  WHILE p < len DO
    Files.Write(r, ORD(seq[p]));
    INC(p); INC(col);
    IF col >= OutWidth THEN Files.Write(r, 10); col := 0 END
  END;
  IF col > 0 THEN Files.Write(r, 10) END
END WSeq;

(* ------------------------------------------------------------------ *)
(*  String utilities                                                    *)
(* ------------------------------------------------------------------ *)

PROCEDURE StripCR(VAR s: ARRAY OF CHAR);
VAR n: INTEGER;
BEGIN
  n := Strings.Length(s);
  IF (n > 0) & (s[n - 1] = 0DX) THEN s[n - 1] := 0X END
END StripCR;

PROCEDURE NextField(line: ARRAY OF CHAR; VAR pos: INTEGER;
                    VAR field: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (pos < LEN(line)) & (line[pos] # 0X) & (line[pos] # 9X)
      & (i < LEN(field) - 1) DO
    field[i] := line[pos]; INC(i); INC(pos)
  END;
  field[i] := 0X;
  IF (pos < LEN(line)) & (line[pos] = 9X) THEN INC(pos) END
END NextField;

PROCEDURE BaseName(path: ARRAY OF CHAR; VAR label: ARRAY OF CHAR);
VAR
  i, j, len, lastSlash, lastDot: INTEGER;
  buf: ARRAY 256 OF CHAR;
BEGIN
  len := Strings.Length(path);
  lastSlash := -1;
  FOR i := 0 TO len - 1 DO
    IF (path[i] = '/') OR (path[i] = '\') THEN lastSlash := i END
  END;
  j := 0; i := lastSlash + 1;
  WHILE (i < len) & (j < 254) DO buf[j] := path[i]; INC(j); INC(i) END;
  buf[j] := 0X;
  len := Strings.Length(buf);
  IF Strings.EndsWith(buf, ".gz") THEN buf[len - 3] := 0X; len := len - 3 END;
  lastDot := -1;
  FOR i := 0 TO len - 1 DO IF buf[i] = '.' THEN lastDot := i END END;
  IF lastDot > 0 THEN buf[lastDot] := 0X END;
  COPY(buf, label)
END BaseName;

(* ------------------------------------------------------------------ *)
(*  Hash table (open addressing, linear probing)                       *)
(* ------------------------------------------------------------------ *)

PROCEDURE StrHash(name: ARRAY OF CHAR): INTEGER;
VAR h, i: INTEGER;
BEGIN
  h := 5381; i := 0;
  WHILE (i < LEN(name)) & (name[i] # 0X) DO
    h := (h * 33 + ORD(name[i])) MOD HashTabSz;
    INC(i)
  END;
  RETURN h
END StrHash;

PROCEDURE HashInsert(org, idx: INTEGER);
VAR h: INTEGER;
BEGIN
  h := StrHash(seqStore[org][idx].name);
  WHILE hashTab[org][h] >= 0 DO h := (h + 1) MOD HashTabSz END;
  hashTab[org][h] := idx
END HashInsert;

PROCEDURE HashLookup(org: INTEGER; name: ARRAY OF CHAR): INTEGER;
VAR h, start, idx: INTEGER;
BEGIN
  IF name[0] = 0X THEN RETURN -1 END;
  h := StrHash(name); start := h;
  LOOP
    idx := hashTab[org][h];
    IF idx < 0 THEN RETURN -1 END;
    IF Strings.Compare(seqStore[org][idx].name, name) = 0 THEN RETURN idx END;
    h := (h + 1) MOD HashTabSz;
    IF h = start THEN RETURN -1 END
  END
END HashLookup;

(* ------------------------------------------------------------------ *)
(*  Sequence loading                                                    *)
(* ------------------------------------------------------------------ *)

PROCEDURE LoadOrg(org: INTEGER; path: ARRAY OF CHAR): BOOLEAN;
VAR rdr: BioIO.FastaReader; rec: BioIO.FastaRecord; cnt, i: INTEGER;
BEGIN
  FOR i := 0 TO HashTabSz - 1 DO hashTab[org][i] := -1 END;
  IF ~BioIO.OpenFasta(rdr, path) THEN
    Out.String("Error: cannot open "); Out.String(path); Out.Ln;
    RETURN FALSE
  END;
  cnt := 0; rec.seq := NIL;
  WHILE BioIO.ReadFasta(rdr, rec) DO
    IF cnt < MaxProts THEN
      seqStore[org][cnt] := rec.seq;
      rec.seq := NIL;
      HashInsert(org, cnt);
      INC(cnt)
    END
  END;
  BioIO.CloseFasta(rdr);
  seqCnt[org] := cnt;
  RETURN cnt > 0
END LoadOrg;

(* ------------------------------------------------------------------ *)
(*  Alignment workspace helpers                                         *)
(* ------------------------------------------------------------------ *)

PROCEDURE BuildAlignedW(wi, i: INTEGER);
VAR k, p, pos, qi, ri: INTEGER;
BEGIN
  qi := 0; ri := 0; pos := 0;
  FOR k := 0 TO wkAln[wi].nOps - 1 DO
    FOR p := 0 TO wkAln[wi].cigar[k].len - 1 DO
      IF wkAln[wi].cigar[k].op = BioAlign.opIns THEN
        alnQry[i][pos] := BioSeq.Get(wkTmpQ[wi], qi);
        alnRef[i][pos] := '-';
        INC(qi)
      ELSIF wkAln[wi].cigar[k].op = BioAlign.opDel THEN
        alnQry[i][pos] := '-';
        alnRef[i][pos] := BioSeq.Get(tmpR, ri);
        INC(ri)
      ELSE
        alnQry[i][pos] := BioSeq.Get(wkTmpQ[wi], qi);
        alnRef[i][pos] := BioSeq.Get(tmpR, ri);
        INC(qi); INC(ri)
      END;
      INC(pos)
    END
  END;
  alnLen[i] := pos
END BuildAlignedW;

PROCEDURE AlignWorkerCA(wi: INTEGER);
VAR i: INTEGER;
BEGIN
  i := wi + 1;
  BioAlign.GlobalW(wkTmpQ[wi], tmpR, mat, wkAln[wi], wkState[wi]);
  BuildAlignedW(wi, i);
  CalcGapsBef(i)
END AlignWorkerCA;

PROCEDURE CalcGapsBef(i: INTEGER);
(* gapsBef[i][j] = gap columns in alnRef[i] before the j-th non-gap char. *)
VAR p, refPos, gaps: INTEGER;
BEGIN
  refPos := 0; gaps := 0;
  FOR p := 0 TO alnLen[i] - 1 DO
    IF alnRef[i][p] = '-' THEN
      INC(gaps)
    ELSE
      gapsBef[i][refPos] := gaps;
      INC(refPos);
      gaps := 0
    END
  END;
  gapsBef[i][refPos] := gaps
END CalcGapsBef;

PROCEDURE CalcExtraGaps(N: INTEGER);
(* extraGaps[j] = max(gapsBef[i][j]) over i=1..N-1. *)
VAR i, j, mx: INTEGER;
BEGIN
  FOR j := 0 TO seq0len DO
    mx := 0;
    FOR i := 1 TO N - 1 DO
      IF gapsBef[i][j] > mx THEN mx := gapsBef[i][j] END
    END;
    extraGaps[j] := mx
  END
END CalcExtraGaps;

(* ------------------------------------------------------------------ *)
(*  Build aligned nucleotide strings into alignedNt[]                  *)
(* ------------------------------------------------------------------ *)

PROCEDURE BuildNtOrg0;
(* Fill alignedNt[0] from seq0buf, inserting extraGaps '-' before each pos. *)
VAR j, k, pos: INTEGER;
BEGIN
  pos := 0;
  FOR j := 0 TO seq0len - 1 DO
    FOR k := 0 TO extraGaps[j] - 1 DO alignedNt[0][pos] := '-'; INC(pos) END;
    alignedNt[0][pos] := seq0buf[j]; INC(pos)
  END;
  FOR k := 0 TO extraGaps[seq0len] - 1 DO alignedNt[0][pos] := '-'; INC(pos) END;
  alnTotal := pos
END BuildNtOrg0;

PROCEDURE BuildNtOrgI(i: INTEGER);
(* Fill alignedNt[i] from alnQry[i], aligning with the master column layout. *)
VAR j, k, ap, gb, pos: INTEGER;
BEGIN
  pos := 0; ap := 0;
  FOR j := 0 TO seq0len - 1 DO
    gb := gapsBef[i][j];
    FOR k := 0 TO gb - 1 DO alignedNt[i][pos] := alnQry[i][ap]; INC(ap); INC(pos) END;
    FOR k := gb TO extraGaps[j] - 1 DO alignedNt[i][pos] := '-'; INC(pos) END;
    alignedNt[i][pos] := alnQry[i][ap]; INC(ap); INC(pos)
  END;
  gb := gapsBef[i][seq0len];
  FOR k := 0 TO gb - 1 DO alignedNt[i][pos] := alnQry[i][ap]; INC(ap); INC(pos) END;
  FOR k := gb TO extraGaps[seq0len] - 1 DO alignedNt[i][pos] := '-'; INC(pos) END
END BuildNtOrgI;

(* ------------------------------------------------------------------ *)
(*  Write one group's .afa file                                        *)
(* ------------------------------------------------------------------ *)

PROCEDURE WriteGroupFile(N: INTEGER; grpId: ARRAY OF CHAR);
VAR
  i, p   : INTEGER;
  fname  : ARRAY 32 OF CHAR;
  f      : Files.File;
  r      : Files.Rider;
  aa, a, b, c : CHAR;
BEGIN
  fname[0] := 0X;
  Strings.Append(grpId, fname);
  Strings.Append(".afa", fname);

  f := Files.New(fname);
  IF f = NIL THEN
    Out.String("Error: cannot create "); Out.String(fname); Out.Ln;
    RETURN
  END;
  Files.Set(r, f, 0);

  FOR i := 0 TO N - 1 DO
    (* Nucleotide record *)
    WChar(r, '>'); WStr(r, orgLabel[i]); Files.Write(r, 10);
    WSeq(r, alignedNt[i], alnTotal);

    (* Build AA annotation for this organism *)
    FOR p := 0 TO alnTotal - 1 DO
      IF p MOD 3 = 1 THEN
        a := alignedNt[i][p - 1];
        b := alignedNt[i][p];
        IF p + 1 < alnTotal THEN c := alignedNt[i][p + 1]
        ELSE c := '-' END;
        aa := Translate(a, b, c)
      ELSE
        aa := '-'
      END;
      aaBuf[p] := aa
    END;

    (* AA annotation record *)
    WChar(r, '>'); WStr(r, orgLabel[i]); WStr(r, "_aa"); Files.Write(r, 10);
    WSeq(r, aaBuf, alnTotal)
  END;

  Files.Close(f)
END WriteGroupFile;

(* ------------------------------------------------------------------ *)
(*  Star alignment for one orthogroup                                  *)
(* ------------------------------------------------------------------ *)

PROCEDURE AlignGroup(N: INTEGER; grpId: ARRAY OF CHAR);
VAR i, len: INTEGER;
BEGIN
  seq0len := BioSeq.Length(groupSeqs[0]);
  IF seq0len > SeqLenCap THEN seq0len := SeqLenCap END;
  BioSeq.Slice(groupSeqs[0], 0, seq0len, seq0buf);
  seq0buf[seq0len] := 0X;
  BioSeq.FromStr(tmpR, "");
  BioSeq.Append(tmpR, seq0buf, seq0len);

  FOR i := 1 TO N - 1 DO
    len := BioSeq.Length(groupSeqs[i]);
    IF len > SeqLenCap THEN len := SeqLenCap END;
    BioSeq.Slice(groupSeqs[i], 0, len, wkFlatBuf[i - 1]);
    wkFlatBuf[i - 1][len] := 0X;
    BioSeq.FromStr(wkTmpQ[i - 1], "");
    BioSeq.Append(wkTmpQ[i - 1], wkFlatBuf[i - 1], len)
  END;
  Parallel.For(0, N - 1, AlignWorkerCA, Parallel.NumCPU());

  CalcExtraGaps(N);
  BuildNtOrg0;
  FOR i := 1 TO N - 1 DO BuildNtOrgI(i) END;
  WriteGroupFile(N, grpId)
END AlignGroup;

(* ------------------------------------------------------------------ *)
(*  Entry point                                                         *)
(* ------------------------------------------------------------------ *)

BEGIN
  (* Standard genetic code, TCAG ordering (T=0,C=1,A=2,G=3):
     index = base1*16 + base2*4 + base3 *)
  COPY("FFLLSSSSYY**CC*WLLLLPPPPHHQQRRRRIIIMTTTTNNKKSSRRVVVVAAAADDEEGGGG",
       geneticCode);

  BioAlign.DefaultScore(mat);
  orgCount := 0;
  tsvPath[0] := 0X;

  mainI := 1;
  WHILE mainI <= Args.Count() DO
    Args.Get(mainI, mainArg);
    IF mainArg[0] # '-' THEN
      IF tsvPath[0] = 0X THEN
        COPY(mainArg, tsvPath)
      ELSIF orgCount < MaxOrgs THEN
        BaseName(mainArg, orgLabel[orgCount]);
        IF LoadOrg(orgCount, mainArg) THEN INC(orgCount) END
      END
    END;
    INC(mainI)
  END;

  IF (tsvPath[0] = 0X) OR (orgCount < 2) THEN
    Out.String("Usage: CodonAlign <orthogroups.tsv> <org1.nt> <org2.nt> [...]"); Out.Ln;
    Out.String("  orthogroups.tsv  output from OrthoFind"); Out.Ln;
    Out.String("  nucleotide files one per organism, in TSV column order"); Out.Ln;
    Out.String("  Writes <groupId>.afa for each orthogroup."); Out.Ln;
    Out.String("  Limits: "); Out.Int(MaxOrgs, 0); Out.String(" organisms, ");
    Out.Int(MaxProts, 0); Out.String(" seqs each, ");
    Out.Int(SeqLenCap, 0); Out.String(" nt max per sequence"); Out.Ln;
    RETURN
  END;

  tsvFile := Files.Old(tsvPath);
  IF tsvFile = NIL THEN
    Out.String("Error: cannot open "); Out.String(tsvPath); Out.Ln;
    RETURN
  END;
  Files.Set(tsvRider, tsvFile, 0);
  Files.ReadLine(tsvRider, tsvLine);  (* discard header *)

  FOR mainI := 0 TO MaxAlignWorkers - 1 DO BioSeq.New(wkTmpQ[mainI]) END;
  BioSeq.New(tmpR);

  LOOP
    IF tsvRider.eof THEN EXIT END;
    Files.ReadLine(tsvRider, tsvLine);
    IF tsvRider.eof & (tsvLine[0] = 0X) THEN EXIT END;
    StripCR(tsvLine);
    IF tsvLine[0] # 0X THEN
      mainPos := 0;
      NextField(tsvLine, mainPos, groupId);  (* first field = group name *)
      mainOk := TRUE;
      FOR mainI := 0 TO orgCount - 1 DO
        NextField(tsvLine, mainPos, tsvField);
        groupSeqs[mainI] := NIL;
        IF tsvField[0] = 0X THEN
          mainOk := FALSE
        ELSE
          mainIdx := HashLookup(mainI, tsvField);
          IF mainIdx >= 0 THEN
            groupSeqs[mainI] := seqStore[mainI][mainIdx]
          ELSE
            mainOk := FALSE
          END
        END
      END;
      IF mainOk THEN AlignGroup(orgCount, groupId) END
    END
  END;

  Files.Close(tsvFile)
END CodonAlign.
