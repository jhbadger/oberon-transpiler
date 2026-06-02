MODULE OrthoAlign;
(*
  OrthoAlign — Build a concatenated supermatrix alignment from OrthoFind groups.

  Algorithm:
    1. Read the OrthoFind TSV; derive organism count from the header.
    2. Load all FASTA files (one per organism, in TSV column order).
       Sequences not referenced by the TSV are loaded but ignored.
    3. For each orthogroup row align the N sequences using star alignment
       anchored on organism 0:
         a. Align each seqi (i>0) against seq0 via Needleman-Wunsch (BLOSUM62
            for protein, DefaultScore for nucleotide, auto-detected).
         b. For each column position j in seq0, compute the maximum number of
            gap columns any pairwise alignment inserts before seq0[j].
         c. Expand every organism's aligned sequence to this master column
            layout, padding with '-' where needed.
    4. Append each organism's block to its per-organism accumulation buffer.
    5. Write the concatenated alignment as FASTA to stdout.

  Sequences longer than SeqLenCap residues are truncated before alignment.
  Groups where any organism's sequence is absent in its FASTA file are skipped.
*)

IMPORT BioIO, BioSeq, BioAlign, Files, Out, Args, Strings, Parallel;

CONST
  MaxOrgs        = 8;
  MaxProts       = 4096;
  MaxNameLen     = 128;
  HashTabSz      = 8192;   (* open-addressing hash, >= 2*MaxProts *)
  SeqLenCap      = 10000;  (* must be <= BioAlign.MaxSeqLen *)
  MaxAln         = 20002;  (* = 2*SeqLenCap + 2: max columns in pairwise alignment *)
  MaxGapPos      = 10001;  (* = SeqLenCap + 1: positions 0..len0 inclusive *)
  OutWidth       = 60;
  MaxAlignWorkers = MaxOrgs - 1;

VAR
  orgCount : INTEGER;
  orgLabel : ARRAY MaxOrgs OF ARRAY 256 OF CHAR;
  seqCnt   : ARRAY MaxOrgs OF INTEGER;
  seqStore : ARRAY MaxOrgs OF ARRAY MaxProts OF BioSeq.Seq;
  hashTab  : ARRAY MaxOrgs OF ARRAY HashTabSz OF INTEGER;  (* -1 = empty slot *)

  alignBuf : ARRAY MaxOrgs OF BioSeq.Seq;  (* growing concatenated alignment *)
  isProtein: BOOLEAN;
  mat      : BioAlign.ScoreMatrix;

  (* Alignment workspace — module-level to avoid stack overflow *)
  tmpR     : BioSeq.Seq;   (* reusable reference seq (seq0), set before Parallel.For *)

  wkState  : ARRAY MaxAlignWorkers OF BioAlign.DPState;
  wkTmpQ   : ARRAY MaxAlignWorkers OF BioSeq.Seq;
  wkAln    : ARRAY MaxAlignWorkers OF BioAlign.Alignment;
  wkFlatBuf: ARRAY MaxAlignWorkers OF ARRAY SeqLenCap + 1 OF CHAR;

  alnQry   : ARRAY MaxOrgs OF ARRAY MaxAln OF CHAR;  (* aligned query per org *)
  alnRef   : ARRAY MaxOrgs OF ARRAY MaxAln OF CHAR;  (* aligned ref (seq0) per org *)
  alnLen   : ARRAY MaxOrgs OF INTEGER;
  gapsBef  : ARRAY MaxOrgs OF ARRAY MaxGapPos OF INTEGER;  (* gaps before seq0[j] *)
  extraGaps: ARRAY MaxGapPos OF INTEGER;   (* max gaps required per seq0 position *)
  groupSeqs: ARRAY MaxOrgs OF BioSeq.Seq;  (* current group's sequences *)
  seq0buf  : ARRAY SeqLenCap + 1 OF CHAR;  (* seq0 as flat buffer *)
  seq0len  : INTEGER;
  workBuf  : ARRAY MaxAln OF CHAR;   (* character accumulator for BioSeq.Append *)
  workLen  : INTEGER;

  (* Main-body variables *)
  tsvPath  : ARRAY 1024 OF CHAR;
  tsvLine  : ARRAY 4096 OF CHAR;
  tsvField : ARRAY MaxNameLen OF CHAR;
  tsvFile  : Files.File;
  tsvRider : Files.Rider;
  mainArg  : ARRAY 1024 OF CHAR;
  mainTmp  : ARRAY 32 OF CHAR;
  mainI, mainPos, mainIdx : INTEGER;
  mainOk   : BOOLEAN;

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
(* Extract the next tab-delimited field from line starting at pos.
   Advances pos past the trailing tab (or to end of string). *)
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
(* Strip directory prefix and common sequence file extensions. *)
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

PROCEDURE WorkReset;
BEGIN workLen := 0 END WorkReset;

PROCEDURE WorkChar(c: CHAR);
BEGIN workBuf[workLen] := c; INC(workLen) END WorkChar;

PROCEDURE WorkFlush(org: INTEGER);
BEGIN
  IF workLen > 0 THEN
    BioSeq.Append(alignBuf[org], workBuf, workLen);
    workLen := 0
  END
END WorkFlush;

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

PROCEDURE AlignWorker(wi: INTEGER);
VAR i: INTEGER;
BEGIN
  i := wi + 1;
  BioAlign.GlobalW(wkTmpQ[wi], tmpR, mat, wkAln[wi], wkState[wi]);
  BuildAlignedW(wi, i);
  CalcGapsBef(i)
END AlignWorker;

PROCEDURE CalcGapsBef(i: INTEGER);
(* Fill gapsBef[i][0..seq0len]:
   gapsBef[i][j] = number of gap columns in alnRef[i] before the j-th
   non-gap character (i.e., before seq0[j]). *)
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
  gapsBef[i][refPos] := gaps  (* trailing gaps after last seq0 char *)
END CalcGapsBef;

PROCEDURE CalcExtraGaps(N: INTEGER);
(* extraGaps[j] = max(gapsBef[i][j]) for i = 1..N-1.
   j ranges 0..seq0len. *)
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

PROCEDURE AppendOrg0;
(* Append seq0 to alignBuf[0], inserting extraGaps '-' before each position. *)
VAR j, k: INTEGER;
BEGIN
  WorkReset;
  FOR j := 0 TO seq0len - 1 DO
    FOR k := 0 TO extraGaps[j] - 1 DO WorkChar('-') END;
    WorkChar(seq0buf[j])
  END;
  FOR k := 0 TO extraGaps[seq0len] - 1 DO WorkChar('-') END;
  WorkFlush(0)
END AppendOrg0;

PROCEDURE AppendOrgI(i: INTEGER);
(* Append organism i's aligned sequence to alignBuf[i].
   At each seq0 position j:
     - emit gapsBef[i][j] residues from alnQry[i]
     - pad to extraGaps[j] with '-'
     - emit the query char aligned with seq0[j] (residue or '-') *)
VAR j, k, ap, gb: INTEGER;
BEGIN
  WorkReset;
  ap := 0;
  FOR j := 0 TO seq0len - 1 DO
    gb := gapsBef[i][j];
    FOR k := 0 TO gb - 1 DO WorkChar(alnQry[i][ap]); INC(ap) END;
    FOR k := gb TO extraGaps[j] - 1 DO WorkChar('-') END;
    WorkChar(alnQry[i][ap]); INC(ap)   (* match / subst / del char *)
  END;
  (* Trailing insertion columns after last seq0 position *)
  gb := gapsBef[i][seq0len];
  FOR k := 0 TO gb - 1 DO WorkChar(alnQry[i][ap]); INC(ap) END;
  FOR k := gb TO extraGaps[seq0len] - 1 DO WorkChar('-') END;
  WorkFlush(i)
END AppendOrgI;

(* ------------------------------------------------------------------ *)
(*  Star alignment for one orthogroup                                  *)
(* ------------------------------------------------------------------ *)

PROCEDURE AlignGroup(N: INTEGER);
(* Aligns groupSeqs[0..N-1] and appends to alignBuf[0..N-1].
   All groupSeqs must be non-NIL.
   Sequences > SeqLenCap residues are truncated. *)
VAR i, len: INTEGER;
BEGIN
  (* Load seq0 into flat buffer and into tmpR *)
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
  Parallel.For(0, N - 1, AlignWorker, Parallel.NumCPU());

  CalcExtraGaps(N);
  AppendOrg0;
  FOR i := 1 TO N - 1 DO AppendOrgI(i) END
END AlignGroup;

(* ------------------------------------------------------------------ *)
(*  Output                                                              *)
(* ------------------------------------------------------------------ *)

PROCEDURE PrintFasta;
(* Write the concatenated alignment as FASTA to stdout, 60 chars per line. *)
VAR i, j, len, col: INTEGER; buf: ARRAY 241 OF CHAR; take, chunk: INTEGER;
BEGIN
  FOR i := 0 TO orgCount - 1 DO
    Out.Char('>'); Out.String(orgLabel[i]); Out.Ln;
    len := BioSeq.Length(alignBuf[i]);
    j := 0; col := 0;
    WHILE j < len DO
      take := len - j;
      IF take > 240 THEN take := 240 END;
      BioSeq.Slice(alignBuf[i], j, take, buf);
      chunk := 0;
      WHILE chunk < take DO
        Out.Char(buf[chunk]); INC(chunk); INC(col);
        IF col >= OutWidth THEN Out.Ln; col := 0 END
      END;
      INC(j, take)
    END;
    IF col > 0 THEN Out.Ln END
  END
END PrintFasta;

(* ------------------------------------------------------------------ *)
(*  Entry point                                                         *)
(* ------------------------------------------------------------------ *)

BEGIN
  tsvPath[0] := 0X;
  orgCount   := 0;

  (* Parse arguments: first positional = TSV, rest = FASTA files *)
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
        BaseName(mainArg, orgLabel[orgCount]);
        IF LoadOrg(orgCount, mainArg) THEN INC(orgCount) END
      END
    END;
    INC(mainI)
  END;

  IF (tsvPath[0] = 0X) OR (orgCount < 2) THEN
    Out.String("Usage: OrthoAlign [-j <threads>] <orthogroups.tsv> <org1.fa> <org2.fa> [...]"); Out.Ln;
    Out.String("  -j <int>         max threads to use (default: all CPUs)"); Out.Ln;
    Out.String("  orthogroups.tsv  output from OrthoFind"); Out.Ln;
    Out.String("  FASTA files      one per organism, in the same column order"); Out.Ln;
    Out.String("                   as the TSV (protein or nucleotide, auto-detected)"); Out.Ln;
    Out.String("  Output: concatenated alignment in FASTA format on stdout"); Out.Ln;
    Out.String("  Limits: "); Out.Int(MaxOrgs, 0); Out.String(" organisms, ");
    Out.Int(MaxProts, 0); Out.String(" seqs each, ");
    Out.Int(SeqLenCap, 0); Out.String(" residues max per sequence"); Out.Ln;
    RETURN
  END;

  (* Open the TSV *)
  tsvFile := Files.Old(tsvPath);
  IF tsvFile = NIL THEN
    Out.String("Error: cannot open "); Out.String(tsvPath); Out.Ln;
    RETURN
  END;
  Files.Set(tsvRider, tsvFile, 0);

  (* Read and discard the header line *)
  Files.ReadLine(tsvRider, tsvLine);

  (* Detect sequence type from first loaded sequence *)
  IF seqCnt[0] > 0 THEN
    isProtein := ~BioSeq.IsNucleotide(seqStore[0][0])
  ELSE
    isProtein := TRUE
  END;
  IF isProtein THEN BioAlign.BLOSUM62(mat)
  ELSE             BioAlign.DefaultScore(mat)
  END;

  (* Initialise per-organism alignment buffers and reusable seq objects *)
  FOR mainI := 0 TO orgCount - 1 DO BioSeq.New(alignBuf[mainI]) END;
  FOR mainI := 0 TO MaxAlignWorkers - 1 DO BioSeq.New(wkTmpQ[mainI]) END;
  BioSeq.New(tmpR);

  (* Process each orthogroup row *)
  LOOP
    IF tsvRider.eof THEN EXIT END;
    Files.ReadLine(tsvRider, tsvLine);
    IF tsvRider.eof & (tsvLine[0] = 0X) THEN EXIT END;
    StripCR(tsvLine);
    IF tsvLine[0] = 0X THEN (* skip empty lines *)
    ELSE
      mainPos := 0;
      NextField(tsvLine, mainPos, tsvField);  (* skip group-name column *)
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
      IF mainOk THEN AlignGroup(orgCount) END
    END
  END;

  PrintFasta
END OrthoAlign.
