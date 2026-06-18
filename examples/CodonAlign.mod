MODULE CodonAlign;
(*
  CodonAlign — Per-orthogroup codon-aware nucleotide alignment.

  Algorithm:
    1. Read the OrthoFind TSV; derive organism count from the header.
    2. For each organism load BOTH a nucleotide FASTA and a peptide FASTA.
       Records are matched by FASTA ID (the TSV cell points to one ID that
       must appear in both files).  A sequence pair is kept only if the
       nucleotide length is exactly 3*aaLen or 3*aaLen + 3 (trailing stop).
    3. For each orthogroup, star-align the N PROTEIN sequences anchored on
       organism 0 using Needleman-Wunsch with BLOSUM62.
    4. Project the protein alignment back onto the nucleotide sequences:
       every amino-acid column expands to 3 nucleotide columns (the codon),
       every gap column to 3 nucleotide gaps.  Frame is preserved by
       construction.
    5. Write <groupId>.afa containing, for each organism, two FASTA records:
         >OrgName     — aligned nucleotide sequence
         >OrgName_aa  — codon annotation; for each triplet of alignment
                        columns (0-indexed), position 0 and 2 are '-' and
                        position 1 holds the amino acid from the protein
                        alignment (or '-' for a gap column).

  Protein sequences longer than (SeqLenCap DIV 3) amino acids are truncated;
  groups where any organism is missing the pair or has mismatched lengths
  are skipped.
*)

IMPORT BioIO, BioSeq, BioAlign, Files, Out, Args, Strings, Parallel;

CONST
  MaxOrgs        = 8;
  MaxProts       = 4096;
  MaxNameLen     = 128;
  HashTabSz      = 8192;
  SeqLenCap      = 10000;            (* nt cap *)
  AaLenCap       = SeqLenCap / 3;  (* aa cap; 3333 *)
  MaxAlnAA       = AaLenCap * 2 + 2;
  MaxAlnNt       = MaxAlnAA * 3;
  MaxGapPos      = AaLenCap + 1;
  OutWidth       = 60;
  MaxAlignWorkers = MaxOrgs - 1;

VAR
  orgCount : INTEGER;
  orgLabel : ARRAY MaxOrgs OF ARRAY 256 OF CHAR;

  (* per-organism storage: nt and aa stay in lockstep at the same index *)
  seqCnt   : ARRAY MaxOrgs OF INTEGER;
  seqStoreNt : ARRAY MaxOrgs OF ARRAY MaxProts OF BioSeq.Seq;
  seqStoreAA : ARRAY MaxOrgs OF ARRAY MaxProts OF BioSeq.Seq;
  hashTab  : ARRAY MaxOrgs OF ARRAY HashTabSz OF INTEGER;

  mat      : BioAlign.ScoreMatrix;   (* BLOSUM62 — protein alignment *)
  tmpR     : BioSeq.Seq;             (* reference (org 0) protein *)

  wkState  : ARRAY MaxAlignWorkers OF BioAlign.DPState;
  wkTmpQ   : ARRAY MaxAlignWorkers OF BioSeq.Seq;
  wkAln    : ARRAY MaxAlignWorkers OF BioAlign.Alignment;
  wkFlatBuf: ARRAY MaxAlignWorkers OF ARRAY AaLenCap + 1 OF CHAR;

  (* per-organism aligned PROTEIN strings vs ref (org 0) and bookkeeping *)
  alnQry   : ARRAY MaxOrgs OF ARRAY MaxAlnAA OF CHAR;
  alnRef   : ARRAY MaxOrgs OF ARRAY MaxAlnAA OF CHAR;
  alnLen   : ARRAY MaxOrgs OF INTEGER;
  gapsBef  : ARRAY MaxOrgs OF ARRAY MaxGapPos OF INTEGER;
  extraGaps: ARRAY MaxGapPos OF INTEGER;

  (* current group, flat buffers *)
  groupSeqsNt: ARRAY MaxOrgs OF BioSeq.Seq;
  groupSeqsAA: ARRAY MaxOrgs OF BioSeq.Seq;
  ntBuf      : ARRAY MaxOrgs OF ARRAY SeqLenCap + 1 OF CHAR;
  ntLen      : ARRAY MaxOrgs OF INTEGER;
  aa0buf     : ARRAY AaLenCap + 1 OF CHAR;
  aa0len     : INTEGER;

  (* master-column aligned nucleotide output *)
  alignedNt: ARRAY MaxOrgs OF ARRAY MaxAlnNt OF CHAR;
  alnAaTotal : INTEGER;   (* total AA columns *)
  alnNtTotal : INTEGER;   (* = alnAaTotal * 3 *)
  aaBuf    : ARRAY MaxAlnNt OF CHAR;

  (* Main-body variables *)
  tsvPath  : ARRAY 1024 OF CHAR;
  tsvLine  : ARRAY 4096 OF CHAR;
  tsvField : ARRAY MaxNameLen OF CHAR;
  groupId  : ARRAY 128 OF CHAR;
  tsvFile  : Files.File;
  tsvRider : Files.Rider;
  mainArg  : ARRAY 1024 OF CHAR;
  mainArgNext : ARRAY 1024 OF CHAR;
  mainTmp  : ARRAY 32 OF CHAR;
  mainI, mainPos, mainIdx : INTEGER;
  mainCursor, mainHit, mainProcessed, mainSkipped : INTEGER;
  mainOk   : BOOLEAN;
  diagShown : BOOLEAN;

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
(*  Hash table (open addressing, linear probing) keyed on AA records,  *)
(*  index also addresses the parallel nucleotide store.                *)
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
  h := StrHash(seqStoreAA[org][idx].name);
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
    IF Strings.Compare(seqStoreAA[org][idx].name, name) = 0 THEN RETURN idx END;
    h := (h + 1) MOD HashTabSz;
    IF h = start THEN RETURN -1 END
  END
END HashLookup;

(* ------------------------------------------------------------------ *)
(*  Sequence loading: nt + aa, paired by FASTA ID                      *)
(* ------------------------------------------------------------------ *)

PROCEDURE FindByName(org: INTEGER; name: ARRAY OF CHAR; cnt: INTEGER): INTEGER;
(* Linear search in nt store while building it (hash not yet populated).
   Acceptable: nt files are loaded once per organism, cnt small enough. *)
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO cnt - 1 DO
    IF Strings.Compare(seqStoreNt[org][i].name, name) = 0 THEN RETURN i END
  END;
  RETURN -1
END FindByName;

PROCEDURE LoadOrg(org: INTEGER; ntPath, aaPath: ARRAY OF CHAR): BOOLEAN;
(* Load nucleotide FASTA, then peptide FASTA, pairing by record name.
   Only records present in BOTH files with compatible lengths are kept. *)
VAR
  rdr        : BioIO.FastaReader;
  rec        : BioIO.FastaRecord;
  ntCnt, kept, i, nti, ntL, aaL : INTEGER;
  aaTotal, badLen, unmatched : INTEGER;
  ntTmp      : ARRAY MaxProts OF BioSeq.Seq;
  ntTmpCnt   : INTEGER;
  used       : ARRAY MaxProts OF BOOLEAN;
  shownExample : BOOLEAN;
BEGIN
  FOR i := 0 TO HashTabSz - 1 DO hashTab[org][i] := -1 END;

  (* --- pass 1: load nt records into a scratch list ---------------- *)
  Out.String("Loading "); Out.String(ntPath); Out.String(" ... ");
  IF ~BioIO.OpenFasta(rdr, ntPath) THEN
    Out.Ln; Out.String("Error: cannot open "); Out.String(ntPath); Out.Ln;
    RETURN FALSE
  END;
  ntTmpCnt := 0; rec.seq := NIL;
  WHILE BioIO.ReadFasta(rdr, rec) DO
    IF ntTmpCnt < MaxProts THEN
      ntTmp[ntTmpCnt] := rec.seq;
      rec.seq := NIL;
      INC(ntTmpCnt)
    END
  END;
  BioIO.CloseFasta(rdr);
  Out.Int(ntTmpCnt, 0); Out.String(" records"); Out.Ln;
  FOR i := 0 TO ntTmpCnt - 1 DO used[i] := FALSE END;

  (* --- pass 2: load aa records and pair them up ------------------- *)
  Out.String("Loading "); Out.String(aaPath); Out.String(" ... ");
  IF ~BioIO.OpenFasta(rdr, aaPath) THEN
    Out.Ln; Out.String("Error: cannot open "); Out.String(aaPath); Out.Ln;
    RETURN FALSE
  END;
  kept := 0; aaTotal := 0; badLen := 0; unmatched := 0;
  shownExample := FALSE;
  rec.seq := NIL;
  WHILE BioIO.ReadFasta(rdr, rec) DO
    INC(aaTotal);
    nti := -1;
    IF kept < MaxProts THEN
      (* find matching nt record by name *)
      FOR i := 0 TO ntTmpCnt - 1 DO
        IF ~used[i] & (Strings.Compare(ntTmp[i].name, rec.name) = 0) THEN
          nti := i; i := ntTmpCnt   (* break *)
        END
      END;
      IF nti >= 0 THEN
        ntL := BioSeq.Length(ntTmp[nti]);
        aaL := BioSeq.Length(rec.seq);
        (* Accept if nt length == 3*aa or 3*aa + 3 (optional stop codon) *)
        IF (aaL > 0) & ((ntL = 3 * aaL) OR (ntL = 3 * aaL + 3)) THEN
          seqStoreNt[org][kept] := ntTmp[nti];
          seqStoreAA[org][kept] := rec.seq;
          used[nti] := TRUE;
          rec.seq := NIL;
          HashInsert(org, kept);
          INC(kept)
        ELSE
          INC(badLen);
          IF ~shownExample THEN
            shownExample := TRUE;
            Out.Ln;
            Out.String("  length mismatch example: id="); Out.String(rec.name);
            Out.String(" aa="); Out.Int(aaL, 0);
            Out.String(" nt="); Out.Int(ntL, 0);
            Out.String(" (expected "); Out.Int(3 * aaL, 0);
            Out.String(" or "); Out.Int(3 * aaL + 3, 0); Out.String(")")
          END
        END
      ELSE
        INC(unmatched);
        IF ~shownExample & (ntTmpCnt > 0) THEN
          shownExample := TRUE;
          Out.Ln;
          Out.String("  unmatched id example: aa-side='");
          Out.String(rec.name); Out.String("' (first nt-side id is '");
          Out.String(ntTmp[0].name); Out.String("')")
        END
      END
    END
  END;
  BioIO.CloseFasta(rdr);
  Out.Int(aaTotal, 0); Out.String(" records, ");
  Out.Int(kept, 0); Out.String(" paired");
  IF badLen > 0 THEN
    Out.String(", "); Out.Int(badLen, 0); Out.String(" length-mismatched")
  END;
  IF unmatched > 0 THEN
    Out.String(", "); Out.Int(unmatched, 0); Out.String(" unmatched ids")
  END;
  Out.Ln;

  (* free unused nt records *)
  FOR i := 0 TO ntTmpCnt - 1 DO
    IF ~used[i] THEN BioSeq.Free(ntTmp[i]) END
  END;

  ntCnt := kept;
  seqCnt[org] := ntCnt;
  RETURN ntCnt > 0
END LoadOrg;

(* ------------------------------------------------------------------ *)
(*  Alignment workspace helpers (protein space)                        *)
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

PROCEDURE AlignWorkerCA(wi: INTEGER);
VAR i: INTEGER;
BEGIN
  i := wi + 1;
  BioAlign.GlobalW(wkTmpQ[wi], tmpR, mat, wkAln[wi], wkState[wi]);
  BuildAlignedW(wi, i);
  CalcGapsBef(i)
END AlignWorkerCA;

PROCEDURE CalcExtraGaps(N: INTEGER);
(* extraGaps[j] = max(gapsBef[i][j]) over i=1..N-1. *)
VAR i, j, mx: INTEGER;
BEGIN
  FOR j := 0 TO aa0len DO
    mx := 0;
    FOR i := 1 TO N - 1 DO
      IF gapsBef[i][j] > mx THEN mx := gapsBef[i][j] END
    END;
    extraGaps[j] := mx
  END
END CalcExtraGaps;

(* ------------------------------------------------------------------ *)
(*  Back-projection: write nucleotides triplet-per-AA into alignedNt   *)
(* ------------------------------------------------------------------ *)

PROCEDURE EmitCodon(i, ntpos: INTEGER; nt: ARRAY OF CHAR; VAR ntCursor: INTEGER);
(* Copy codon at nt[ntCursor..ntCursor+2] into alignedNt[i][ntpos..ntpos+2]. *)
VAR k: INTEGER;
BEGIN
  FOR k := 0 TO 2 DO alignedNt[i][ntpos + k] := nt[ntCursor + k] END;
  INC(ntCursor, 3)
END EmitCodon;

PROCEDURE EmitGap3(i, ntpos: INTEGER);
VAR k: INTEGER;
BEGIN
  FOR k := 0 TO 2 DO alignedNt[i][ntpos + k] := '-' END
END EmitGap3;

PROCEDURE BuildNtOrg0(N: INTEGER);
(* Org 0's protein has no gaps from its own alignment, but the master
   layout may insert columns where other organisms required them.
   Emit extraGaps[j] gap-codons before each AA's codon. *)
VAR j, k, ntpos, aapos, ntCursor: INTEGER;
BEGIN
  aapos := 0; ntpos := 0; ntCursor := 0;
  FOR j := 0 TO aa0len - 1 DO
    FOR k := 0 TO extraGaps[j] - 1 DO
      EmitGap3(0, ntpos); INC(ntpos, 3); INC(aapos)
    END;
    EmitCodon(0, ntpos, ntBuf[0], ntCursor);
    INC(ntpos, 3); INC(aapos)
  END;
  FOR k := 0 TO extraGaps[aa0len] - 1 DO
    EmitGap3(0, ntpos); INC(ntpos, 3); INC(aapos)
  END;
  alnAaTotal := aapos;
  alnNtTotal := ntpos
END BuildNtOrg0;

PROCEDURE BuildNtOrgI(i: INTEGER);
(* Walk alnQry[i] (the protein star-alignment vs org 0).  For each ref
   position j we have gapsBef[i][j] inserted-AA columns sitting before
   the j-th ref AA; the master layout reserves extraGaps[j] columns
   there.  Emit codons for the AAs in alnQry[i] and gap-codons for any
   padding required to reach the master width. *)
VAR j, k, ap, gb, ntpos, ntCursor: INTEGER;
    c: CHAR;
BEGIN
  ntpos := 0; ap := 0; ntCursor := 0;
  FOR j := 0 TO aa0len - 1 DO
    gb := gapsBef[i][j];
    (* organism i's own inserted AAs: each is a real codon *)
    FOR k := 0 TO gb - 1 DO
      c := alnQry[i][ap]; INC(ap);
      IF c = '-' THEN EmitGap3(i, ntpos)
      ELSE EmitCodon(i, ntpos, ntBuf[i], ntCursor) END;
      INC(ntpos, 3)
    END;
    (* padding gap-codons up to the master width *)
    FOR k := gb TO extraGaps[j] - 1 DO
      EmitGap3(i, ntpos); INC(ntpos, 3)
    END;
    (* the column for the j-th ref AA: either a real codon or a gap *)
    c := alnQry[i][ap]; INC(ap);
    IF c = '-' THEN EmitGap3(i, ntpos)
    ELSE EmitCodon(i, ntpos, ntBuf[i], ntCursor) END;
    INC(ntpos, 3)
  END;
  (* trailing region: anything after the last ref AA *)
  gb := gapsBef[i][aa0len];
  FOR k := 0 TO gb - 1 DO
    c := alnQry[i][ap]; INC(ap);
    IF c = '-' THEN EmitGap3(i, ntpos)
    ELSE EmitCodon(i, ntpos, ntBuf[i], ntCursor) END;
    INC(ntpos, 3)
  END;
  FOR k := gb TO extraGaps[aa0len] - 1 DO
    EmitGap3(i, ntpos); INC(ntpos, 3)
  END
END BuildNtOrgI;

(* ------------------------------------------------------------------ *)
(*  Write one group's .afa file                                        *)
(* ------------------------------------------------------------------ *)

PROCEDURE WriteGroupFile(N: INTEGER; grpId: ARRAY OF CHAR);
VAR
  i, p, ntCursor : INTEGER;
  fname  : ARRAY 160 OF CHAR;
  f      : Files.File;
  r      : Files.Rider;
  c      : CHAR;
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
    WSeq(r, alignedNt[i], alnNtTotal);

    (* AA annotation: walk alignedNt in triplets; if center isn't a gap
       use the AA letter sourced from the original peptide sequence, in
       order.  This is robust to non-standard codons because the AA
       comes from the input file, not a translation table. *)
    ntCursor := 0;
    FOR p := 0 TO alnNtTotal - 1 DO
      aaBuf[p] := '-'
    END;
    p := 0;
    WHILE p < alnNtTotal DO
      IF (alignedNt[i][p] # '-') OR (alignedNt[i][p + 1] # '-')
         OR (alignedNt[i][p + 2] # '-') THEN
        IF ntCursor < BioSeq.Length(groupSeqsAA[i]) THEN
          c := BioSeq.Get(groupSeqsAA[i], ntCursor)
        ELSE
          c := 'X'
        END;
        aaBuf[p + 1] := c;
        INC(ntCursor)
      END;
      INC(p, 3)
    END;

    (* AA annotation record *)
    WChar(r, '>'); WStr(r, orgLabel[i]); WStr(r, "_aa"); Files.Write(r, 10);
    WSeq(r, aaBuf, alnNtTotal)
  END;

  Files.Close(f)
END WriteGroupFile;

(* ------------------------------------------------------------------ *)
(*  Star alignment for one orthogroup (protein space)                  *)
(* ------------------------------------------------------------------ *)

PROCEDURE AlignGroup(N: INTEGER; grpId: ARRAY OF CHAR);
VAR i, alen, nlen: INTEGER;
BEGIN
  (* ---- prepare reference (org 0) protein ---- *)
  aa0len := BioSeq.Length(groupSeqsAA[0]);
  IF aa0len > AaLenCap THEN aa0len := AaLenCap END;
  BioSeq.Slice(groupSeqsAA[0], 0, aa0len, aa0buf);
  aa0buf[aa0len] := 0X;
  BioSeq.FromStr(tmpR, "");
  BioSeq.Append(tmpR, aa0buf, aa0len);

  (* ---- copy each organism's nt + aa into flat buffers ---- *)
  FOR i := 0 TO N - 1 DO
    alen := BioSeq.Length(groupSeqsAA[i]);
    IF alen > AaLenCap THEN alen := AaLenCap END;
    nlen := alen * 3;
    IF nlen > BioSeq.Length(groupSeqsNt[i]) THEN
      nlen := BioSeq.Length(groupSeqsNt[i])
    END;
    BioSeq.Slice(groupSeqsNt[i], 0, nlen, ntBuf[i]);
    ntBuf[i][nlen] := 0X;
    ntLen[i] := nlen
  END;

  (* ---- queries 1..N-1 into worker buffers ---- *)
  FOR i := 1 TO N - 1 DO
    alen := BioSeq.Length(groupSeqsAA[i]);
    IF alen > AaLenCap THEN alen := AaLenCap END;
    BioSeq.Slice(groupSeqsAA[i], 0, alen, wkFlatBuf[i - 1]);
    wkFlatBuf[i - 1][alen] := 0X;
    BioSeq.FromStr(wkTmpQ[i - 1], "");
    BioSeq.Append(wkTmpQ[i - 1], wkFlatBuf[i - 1], alen)
  END;
  Parallel.For(0, N - 1, AlignWorkerCA, Parallel.NumCPU());

  CalcExtraGaps(N);
  BuildNtOrg0(N);
  FOR i := 1 TO N - 1 DO BuildNtOrgI(i) END;
  WriteGroupFile(N, grpId)
END AlignGroup;

(* ------------------------------------------------------------------ *)
(*  Entry point                                                         *)
(* ------------------------------------------------------------------ *)

BEGIN
  BioAlign.BLOSUM62(mat);
  orgCount := 0;
  tsvPath[0] := 0X;

  (* Command-line walk: positional args are
       <tsv> <org1.nt> <org1.aa> <org2.nt> <org2.aa> ...
     Flags: -j <threads>. *)
  mainI := 1;
  WHILE mainI <= Args.Count() DO
    Args.Get(mainI, mainArg);
    IF Strings.Compare(mainArg, "-j") = 0 THEN
      INC(mainI);
      IF mainI <= Args.Count() THEN
        Args.Get(mainI, mainTmp);
        IF Strings.StrToInt(mainTmp, mainPos) & (mainPos > 0) THEN
          Parallel.SetMaxCPU(mainPos)
        END
      END
    ELSIF mainArg[0] # '-' THEN
      IF tsvPath[0] = 0X THEN
        COPY(mainArg, tsvPath)
      ELSIF orgCount < MaxOrgs THEN
        (* this arg is the nt file; the next non-flag is the aa file *)
        INC(mainI);
        IF mainI <= Args.Count() THEN
          Args.Get(mainI, mainArgNext);
          IF mainArgNext[0] = '-' THEN
            Out.String("Error: expected peptide file after "); Out.String(mainArg); Out.Ln
          ELSE
            BaseName(mainArg, orgLabel[orgCount]);
            IF LoadOrg(orgCount, mainArg, mainArgNext) THEN INC(orgCount) END
          END
        ELSE
          Out.String("Error: nucleotide file "); Out.String(mainArg);
          Out.String(" has no matching peptide file"); Out.Ln
        END
      END
    END;
    INC(mainI)
  END;

  IF (tsvPath[0] = 0X) OR (orgCount < 2) THEN
    Out.String("Usage: CodonAlign [-j <threads>] <orthogroups.tsv> <org1.nt> <org1.aa> ..."); Out.Ln;
    Out.String("  -j <int>         max threads to use (default: all CPUs)"); Out.Ln;
    Out.String("  orthogroups.tsv  output from OrthoFind"); Out.Ln;
    Out.String("  per organism:    pass nucleotide FASTA followed by peptide FASTA"); Out.Ln;
    Out.String("                   (records paired by FASTA ID; the ID in the TSV"); Out.Ln;
    Out.String("                    must appear in both files of that organism)"); Out.Ln;
    Out.String("  Alignment is done on the proteins (BLOSUM62) and back-projected"); Out.Ln;
    Out.String("  onto the nucleotides, preserving reading frame."); Out.Ln;
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
  Out.String("Reading "); Out.String(tsvPath); Out.Ln;

  FOR mainI := 0 TO MaxAlignWorkers - 1 DO BioSeq.New(wkTmpQ[mainI]) END;
  BioSeq.New(tmpR);

  mainProcessed := 0;
  mainSkipped := 0;
  diagShown := FALSE;
  LOOP
    IF tsvRider.eof THEN EXIT END;
    Files.ReadLine(tsvRider, tsvLine);
    IF tsvRider.eof & (tsvLine[0] = 0X) THEN EXIT END;
    StripCR(tsvLine);
    IF tsvLine[0] # 0X THEN
      mainCursor := 0;
      NextField(tsvLine, mainCursor, groupId);  (* first field = group name *)
      mainOk := TRUE;
      FOR mainI := 0 TO orgCount - 1 DO
        NextField(tsvLine, mainCursor, tsvField);
        groupSeqsNt[mainI] := NIL;
        groupSeqsAA[mainI] := NIL;
        IF tsvField[0] = 0X THEN
          mainOk := FALSE
        ELSE
          mainHit := HashLookup(mainI, tsvField);
          IF mainHit >= 0 THEN
            groupSeqsNt[mainI] := seqStoreNt[mainI][mainHit];
            groupSeqsAA[mainI] := seqStoreAA[mainI][mainHit]
          ELSE
            mainOk := FALSE;
            IF ~diagShown THEN
              diagShown := TRUE;
              Out.String("  TSV lookup miss: group="); Out.String(groupId);
              Out.String(" org="); Out.Int(mainI, 0);
              Out.String(" tsv-id='"); Out.String(tsvField);
              Out.String("' (len="); Out.Int(Strings.Length(tsvField), 0);
              Out.String(") fasta-id-example='");
              IF seqCnt[mainI] > 0 THEN
                Out.String(seqStoreAA[mainI][0].name)
              END;
              Out.String("'"); Out.Ln
            END
          END
        END
      END;
      IF mainOk THEN
        AlignGroup(orgCount, groupId);
        INC(mainProcessed)
      ELSE
        INC(mainSkipped)
      END
    END
  END;

  Out.String("Done: "); Out.Int(mainProcessed, 0); Out.String(" groups aligned, ");
  Out.Int(mainSkipped, 0); Out.String(" skipped"); Out.Ln;
  Files.Close(tsvFile)
END CodonAlign.