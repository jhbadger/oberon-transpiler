MODULE SeqHMM;
(*
  SeqHMM — Profile HMM builder and sequence-database searcher.

  Build mode:   SeqHMM build  <msa.afa> <model.hmm>
    Reads a multiple sequence alignment (FASTA + gap chars '-'/'.').
    Every column becomes one match state (no column filtering).
    Counts residues per column with Laplace pseudocounts.
    Counts MM/MD/DM/DD transitions from gap patterns between adjacent columns.
    Insert-state transitions are fixed: TMI=1%, TIM=90%, TII=10%.
    Writes a binary .hmm profile.

  Search mode:  SeqHMM search <model.hmm> <db.fa> [-t <minBits>]
    Reads profile and FASTA database.
    Scores each sequence with local Viterbi in log space.
    Local entry into any match state k costs logEntry = ln(1/L).
    Bit score = (best_viterbi - null_score) / ln(2).
    Outputs TSV of hits above threshold (default 10 bits):
      seq_name  model_name  bits  seq_len

  Binary .hmm format:
    WriteInt  hmmLen
    WriteInt  hmmAlph        (4 = DNA, 20 = AA)
    WriteString hmmName
    WriteReal logBg[0..alph-1]
    WriteReal logEmitM[0..L-1][0..alph-1]   (row-major)
    WriteReal logEmitI[0..alph-1]
    WriteReal logTrans[0..L-1][0..6]         (TMM TMI TMD TIM TII TDM TDD)
*)

IMPORT BioIO, BioSeq, Files, Out, Args, Strings, Math;

CONST
  MaxLen  = 2000;
  MaxAlph = 20;
  MaxSeqs = 256;
  Pseudo  = 1.0;
  TMM = 0; TMI = 1; TMD = 2; TIM = 3; TII = 4; TDM = 5; TDD = 6;

VAR
  hmmLen  : INTEGER;
  hmmAlph : INTEGER;
  hmmName : ARRAY 256 OF CHAR;

  logEmitM : ARRAY MaxLen OF ARRAY MaxAlph OF REAL;
  logEmitI : ARRAY MaxAlph OF REAL;
  logTrans : ARRAY MaxLen OF ARRAY 7 OF REAL;
  logBg    : ARRAY MaxAlph OF REAL;

  vM, vMprev : ARRAY MaxLen + 2 OF REAL;
  vI, vIprev : ARRAY MaxLen + 2 OF REAL;
  vD         : ARRAY MaxLen + 2 OF REAL;

  NegInf   : REAL;

  seqBuf   : ARRAY 100001 OF CHAR;
  seqs     : ARRAY MaxSeqs OF BioSeq.Seq;
  seqCount : INTEGER;

(* ------------------------------------------------------------------ *)
(*  Alphabet                                                            *)
(* ------------------------------------------------------------------ *)

PROCEDURE IsGap(c: CHAR): BOOLEAN;
BEGIN RETURN (c = '-') OR (c = '.') END IsGap;

PROCEDURE ResIdx(c: CHAR): INTEGER;
VAR u: CHAR;
BEGIN
  IF IsGap(c) THEN RETURN -1 END;
  u := CAP(c);
  IF hmmAlph = 4 THEN
    IF u = 'A' THEN RETURN 0
    ELSIF u = 'C' THEN RETURN 1
    ELSIF u = 'G' THEN RETURN 2
    ELSIF (u = 'T') OR (u = 'U') THEN RETURN 3
    ELSE RETURN -1
    END
  ELSE
    IF u = 'A' THEN RETURN 0
    ELSIF u = 'C' THEN RETURN 1
    ELSIF u = 'D' THEN RETURN 2
    ELSIF u = 'E' THEN RETURN 3
    ELSIF u = 'F' THEN RETURN 4
    ELSIF u = 'G' THEN RETURN 5
    ELSIF u = 'H' THEN RETURN 6
    ELSIF u = 'I' THEN RETURN 7
    ELSIF u = 'K' THEN RETURN 8
    ELSIF u = 'L' THEN RETURN 9
    ELSIF u = 'M' THEN RETURN 10
    ELSIF u = 'N' THEN RETURN 11
    ELSIF u = 'P' THEN RETURN 12
    ELSIF u = 'Q' THEN RETURN 13
    ELSIF u = 'R' THEN RETURN 14
    ELSIF u = 'S' THEN RETURN 15
    ELSIF u = 'T' THEN RETURN 16
    ELSIF u = 'V' THEN RETURN 17
    ELSIF u = 'W' THEN RETURN 18
    ELSIF u = 'Y' THEN RETURN 19
    ELSE RETURN -1
    END
  END
END ResIdx;

PROCEDURE DetectAlph(): INTEGER;
VAR s, i, len: INTEGER; c: CHAR;
BEGIN
  FOR s := 0 TO seqCount - 1 DO
    len := BioSeq.Length(seqs[s]);
    FOR i := 0 TO len - 1 DO
      c := CAP(BioSeq.Get(seqs[s], i));
      IF (c = 'D') OR (c = 'E') OR (c = 'F') OR (c = 'H') OR
         (c = 'I') OR (c = 'K') OR (c = 'L') OR (c = 'M') OR
         (c = 'N') OR (c = 'P') OR (c = 'Q') OR (c = 'R') OR
         (c = 'S') OR (c = 'V') OR (c = 'W') OR (c = 'Y') THEN
        RETURN 20
      END
    END
  END;
  RETURN 4
END DetectAlph;

PROCEDURE SetBgFreqs;
VAR i: INTEGER;
BEGIN
  IF hmmAlph = 4 THEN
    FOR i := 0 TO 3 DO logBg[i] := Math.ln(0.25) END
  ELSE
    (* SwissProt amino acid background frequencies *)
    logBg[0]  := Math.ln(0.073); logBg[1]  := Math.ln(0.018);
    logBg[2]  := Math.ln(0.053); logBg[3]  := Math.ln(0.063);
    logBg[4]  := Math.ln(0.040); logBg[5]  := Math.ln(0.069);
    logBg[6]  := Math.ln(0.022); logBg[7]  := Math.ln(0.056);
    logBg[8]  := Math.ln(0.059); logBg[9]  := Math.ln(0.091);
    logBg[10] := Math.ln(0.023); logBg[11] := Math.ln(0.046);
    logBg[12] := Math.ln(0.051); logBg[13] := Math.ln(0.041);
    logBg[14] := Math.ln(0.052); logBg[15] := Math.ln(0.073);
    logBg[16] := Math.ln(0.056); logBg[17] := Math.ln(0.064);
    logBg[18] := Math.ln(0.013); logBg[19] := Math.ln(0.033)
  END;
  FOR i := 0 TO hmmAlph - 1 DO logEmitI[i] := logBg[i] END
END SetBgFreqs;

(* ------------------------------------------------------------------ *)
(*  Build                                                               *)
(* ------------------------------------------------------------------ *)

PROCEDURE BuildHMM(alnLen: INTEGER);
VAR
  k, s, r, last : INTEGER;
  cnt            : ARRAY MaxAlph OF REAL;
  total, nMM, nMD, nDM, nDD, p, q : REAL;
  c              : CHAR;
  curGap         : BOOLEAN;
  prevGap        : ARRAY MaxSeqs OF BOOLEAN;
BEGIN
  hmmLen := alnLen;
  FOR s := 0 TO seqCount - 1 DO prevGap[s] := TRUE END;

  FOR k := 0 TO alnLen - 1 DO
    FOR r := 0 TO hmmAlph - 1 DO cnt[r] := Pseudo END;
    total := FLT(hmmAlph) * Pseudo;
    nMM := Pseudo; nMD := Pseudo; nDM := Pseudo; nDD := Pseudo;

    FOR s := 0 TO seqCount - 1 DO
      c := BioSeq.Get(seqs[s], k);
      curGap := IsGap(c);

      IF ~curGap THEN
        r := ResIdx(c);
        IF r >= 0 THEN cnt[r] := cnt[r] + 1.0; total := total + 1.0 END
      END;

      IF k > 0 THEN
        IF ~prevGap[s] & ~curGap THEN      nMM := nMM + 1.0
        ELSIF ~prevGap[s] & curGap THEN    nMD := nMD + 1.0
        ELSIF prevGap[s] & ~curGap THEN    nDM := nDM + 1.0
        ELSE                               nDD := nDD + 1.0
        END
      END;
      prevGap[s] := curGap
    END;

    FOR r := 0 TO hmmAlph - 1 DO
      logEmitM[k][r] := Math.ln(cnt[r] / total) - logBg[r]
    END;

    IF k > 0 THEN
      p := nMM + nMD;
      q := nDM + nDD;
      (* 99% budget for MM and MD; 1% reserved for insert *)
      logTrans[k-1][TMM] := Math.ln(nMM / p * 0.99);
      logTrans[k-1][TMD] := Math.ln(nMD / p * 0.99);
      logTrans[k-1][TMI] := Math.ln(0.01);
      logTrans[k-1][TIM] := Math.ln(0.90);
      logTrans[k-1][TII] := Math.ln(0.10);
      logTrans[k-1][TDM] := Math.ln(nDM / q);
      logTrans[k-1][TDD] := Math.ln(nDD / q)
    END
  END;

  (* Default transitions at last position (no successor match state) *)
  IF alnLen > 0 THEN
    last := alnLen - 1;
    logTrans[last][TMM] := Math.ln(0.99);
    logTrans[last][TMI] := Math.ln(0.01);
    logTrans[last][TMD] := NegInf;
    logTrans[last][TIM] := Math.ln(0.90);
    logTrans[last][TII] := Math.ln(0.10);
    logTrans[last][TDM] := Math.ln(1.0);
    logTrans[last][TDD] := NegInf
  END
END BuildHMM;

(* ------------------------------------------------------------------ *)
(*  File I/O                                                            *)
(* ------------------------------------------------------------------ *)

PROCEDURE WriteHMM(path: ARRAY OF CHAR): BOOLEAN;
VAR f: Files.File; r: Files.Rider; k, a: INTEGER;
BEGIN
  f := Files.New(path);
  IF f = NIL THEN RETURN FALSE END;
  Files.Set(r, f, 0);
  Files.WriteInt(r, hmmLen);
  Files.WriteInt(r, hmmAlph);
  Files.WriteString(r, hmmName);
  FOR a := 0 TO hmmAlph - 1 DO Files.WriteReal(r, logBg[a]) END;
  FOR k := 0 TO hmmLen - 1 DO
    FOR a := 0 TO hmmAlph - 1 DO Files.WriteReal(r, logEmitM[k][a]) END
  END;
  FOR a := 0 TO hmmAlph - 1 DO Files.WriteReal(r, logEmitI[a]) END;
  FOR k := 0 TO hmmLen - 1 DO
    FOR a := 0 TO 6 DO Files.WriteReal(r, logTrans[k][a]) END
  END;
  Files.Close(f);
  RETURN TRUE
END WriteHMM;

PROCEDURE ReadHMM(path: ARRAY OF CHAR): BOOLEAN;
VAR f: Files.File; r: Files.Rider; k, a: INTEGER;
BEGIN
  f := Files.Old(path);
  IF f = NIL THEN RETURN FALSE END;
  Files.Set(r, f, 0);
  Files.ReadInt(r, hmmLen);
  Files.ReadInt(r, hmmAlph);
  IF (hmmLen < 1) OR (hmmLen > MaxLen) OR
     ((hmmAlph # 4) & (hmmAlph # 20)) THEN
    Files.Close(f); RETURN FALSE
  END;
  Files.ReadString(r, hmmName);
  FOR a := 0 TO hmmAlph - 1 DO Files.ReadReal(r, logBg[a]) END;
  FOR k := 0 TO hmmLen - 1 DO
    FOR a := 0 TO hmmAlph - 1 DO Files.ReadReal(r, logEmitM[k][a]) END
  END;
  FOR a := 0 TO hmmAlph - 1 DO Files.ReadReal(r, logEmitI[a]) END;
  FOR k := 0 TO hmmLen - 1 DO
    FOR a := 0 TO 6 DO Files.ReadReal(r, logTrans[k][a]) END
  END;
  Files.Close(f);
  RETURN hmmLen > 0
END ReadHMM;

(* ------------------------------------------------------------------ *)
(*  Viterbi local alignment                                             *)
(* ------------------------------------------------------------------ *)

PROCEDURE Viterbi(seq: BioSeq.Seq): REAL;
(*
  Local Viterbi in log space.
  States at profile position k (0-indexed): M_k (match), I_k (insert), D_k (delete).
  logTrans[k][t] = transition log-prob FROM position k.
  Delete states are computed left-to-right within each residue step (no emission).
  logEntry = ln(1/L): cost to start a local alignment at any match state.
  Returns the bit score relative to the null (background frequency) model,
  or NegInf if no valid alignment was found.
*)
VAR
  T, k, j, ri : INTEGER;
  best, logEntry, score : REAL;
  c : CHAR;
BEGIN
  T := BioSeq.Length(seq);
  IF (T = 0) OR (hmmLen = 0) THEN RETURN NegInf END;
  IF T > 100000 THEN T := 100000 END;
  BioSeq.Slice(seq, 0, T, seqBuf);
  seqBuf[T] := 0X;

  logEntry := Math.ln(1.0 / FLT(hmmLen));

  FOR k := 0 TO hmmLen + 1 DO
    vMprev[k] := NegInf; vIprev[k] := NegInf; vD[k] := NegInf
  END;
  score := NegInf;

  FOR j := 0 TO T - 1 DO
    c  := seqBuf[j];
    ri := ResIdx(c);

    vD[0] := NegInf;

    FOR k := 0 TO hmmLen - 1 DO

      (* Delete state D_k: no emission; chained left-to-right within this j step.
         Transitions FROM k-1: logTrans[k-1][TMD] and logTrans[k-1][TDD]. *)
      IF k = 0 THEN
        vD[k] := NegInf
      ELSE
        vD[k] := Math.max(vMprev[k-1] + logTrans[k-1][TMD],
                           vD[k-1]     + logTrans[k-1][TDD])
      END;

      (* Match state M_k: emits seqBuf[j].
         Predecessor states at profile position k-1 (previous j row),
         or fresh local entry at any (j,k). *)
      IF k = 0 THEN
        best := logEntry
      ELSE
        best := Math.max(vMprev[k-1] + logTrans[k-1][TMM],
                Math.max(vIprev[k-1] + logTrans[k-1][TIM],
                         vD[k-1]     + logTrans[k-1][TDM]));
        best := Math.max(best, logEntry)
      END;
      IF ri >= 0 THEN vM[k] := logEmitM[k][ri] + best
      ELSE vM[k] := NegInf
      END;

      (* Insert state I_k: emits seqBuf[j] with background probability.
         Predecessor M_k or I_k at same profile position, previous j row. *)
      IF ri >= 0 THEN
        vI[k] := logEmitI[ri] + Math.max(vMprev[k] + logTrans[k][TMI],
                                           vIprev[k] + logTrans[k][TII])
      ELSE
        vI[k] := NegInf
      END;

      (* Local exit: any M_k can end the alignment; track running best. *)
      IF vM[k] > score THEN score := vM[k] END
    END;

    FOR k := 0 TO hmmLen - 1 DO
      vMprev[k] := vM[k]; vIprev[k] := vI[k]
    END
  END;

  (* Emissions are already log-odds vs background, so the per-residue null
     cancels algebraically for unaligned flanking regions.  Just scale to bits. *)
  IF score > NegInf / 2.0 THEN
    RETURN score / Math.ln(2.0)
  ELSE
    RETURN NegInf
  END
END Viterbi;

(* ------------------------------------------------------------------ *)
(*  Helpers                                                             *)
(* ------------------------------------------------------------------ *)

PROCEDURE BaseName(path: ARRAY OF CHAR; VAR name: ARRAY OF CHAR);
VAR i, j, len, lastSlash, lastDot: INTEGER;
BEGIN
  len := Strings.Length(path);
  lastSlash := -1;
  FOR i := 0 TO len - 1 DO
    IF (path[i] = '/') OR (path[i] = '\') THEN lastSlash := i END
  END;
  j := 0; i := lastSlash + 1;
  WHILE (i < len) & (j < LEN(name) - 1) DO
    name[j] := path[i]; INC(i); INC(j)
  END;
  name[j] := 0X;
  len := Strings.Length(name);
  IF Strings.EndsWith(name, ".gz") THEN name[len - 3] := 0X; len := len - 3 END;
  lastDot := -1;
  FOR i := 0 TO len - 1 DO IF name[i] = '.' THEN lastDot := i END END;
  IF lastDot > 0 THEN name[lastDot] := 0X END
END BaseName;

PROCEDURE CalcEvalue(seqLen: INTEGER; bits: REAL): REAL;
(* E = hmmLen * seqLen * 2^(-bits), computed in log space to avoid underflow. *)
VAR logE: REAL;
BEGIN
  logE := Math.ln(FLT(hmmLen)) + Math.ln(FLT(seqLen)) - bits * Math.ln(2.0);
  IF logE < -700.0 THEN RETURN 0.0 END;
  RETURN Math.exp(logE)
END CalcEvalue;

PROCEDURE PrintEvalue(e: REAL);
(* Scientific notation for small values; fixed 3 d.p. otherwise. *)
VAR log10e: REAL; exp: INTEGER; m: REAL;
BEGIN
  IF e <= 0.0 THEN
    Out.String("0")
  ELSIF e >= 0.001 THEN
    Out.Fixed(e, 0, 3)
  ELSE
    log10e := Math.log(e);
    exp := FLOOR(log10e);
    m   := Math.power(10.0, log10e - FLT(exp));
    Out.Fixed(m, 0, 2); Out.String("e"); Out.Int(exp, 0)
  END
END PrintEvalue;

(* ------------------------------------------------------------------ *)
(*  Build mode                                                          *)
(* ------------------------------------------------------------------ *)

PROCEDURE DoBuild(msaPath, outPath: ARRAY OF CHAR);
VAR
  rdr    : BioIO.FastaReader;
  rec    : BioIO.FastaRecord;
  alnLen : INTEGER;
BEGIN
  IF ~BioIO.OpenFasta(rdr, msaPath) THEN
    Out.String("Error: cannot open "); Out.String(msaPath); Out.Ln;
    RETURN
  END;

  seqCount := 0; alnLen := 0;
  rec.seq := NIL;
  WHILE BioIO.ReadFasta(rdr, rec) DO
    IF seqCount < MaxSeqs THEN
      seqs[seqCount] := rec.seq;
      rec.seq := NIL;
      IF seqCount = 0 THEN
        alnLen := BioSeq.Length(seqs[0]);
        IF alnLen > MaxLen THEN
          Out.String("Warning: alignment truncated to "); Out.Int(MaxLen, 0);
          Out.String(" columns."); Out.Ln;
          alnLen := MaxLen
        END
      END;
      INC(seqCount)
    END
  END;
  BioIO.CloseFasta(rdr);

  IF seqCount = 0 THEN
    Out.String("Error: empty alignment file."); Out.Ln; RETURN
  END;
  IF alnLen = 0 THEN
    Out.String("Error: zero-length alignment."); Out.Ln; RETURN
  END;

  BaseName(msaPath, hmmName);
  hmmAlph := DetectAlph();
  SetBgFreqs;
  BuildHMM(alnLen);

  IF WriteHMM(outPath) THEN
    Out.String("Built profile '"); Out.String(hmmName); Out.String("': ");
    Out.Int(hmmLen, 0); Out.String(" positions, ");
    IF hmmAlph = 4 THEN Out.String("DNA") ELSE Out.String("amino acid") END;
    Out.String(", "); Out.Int(seqCount, 0); Out.String(" sequences."); Out.Ln
  ELSE
    Out.String("Error: cannot write "); Out.String(outPath); Out.Ln
  END
END DoBuild;

(* ------------------------------------------------------------------ *)
(*  Search mode                                                         *)
(* ------------------------------------------------------------------ *)

PROCEDURE DoSearch(hmmPath, dbPath: ARRAY OF CHAR; minBits: REAL);
VAR
  rdr    : BioIO.FastaReader;
  rec    : BioIO.FastaRecord;
  bits   : REAL;
  evalue : REAL;
  seqLen : INTEGER;
  hits   : INTEGER;
BEGIN
  IF ~ReadHMM(hmmPath) THEN
    Out.String("Error: cannot read profile from "); Out.String(hmmPath); Out.Ln;
    RETURN
  END;

  IF ~BioIO.OpenFasta(rdr, dbPath) THEN
    Out.String("Error: cannot open "); Out.String(dbPath); Out.Ln;
    RETURN
  END;

  Out.String("seq_name"); Out.Char(9X);
  Out.String("model_name"); Out.Char(9X);
  Out.String("bits"); Out.Char(9X);
  Out.String("evalue"); Out.Char(9X);
  Out.String("seq_len"); Out.Ln;

  hits := 0; rec.seq := NIL;
  WHILE BioIO.ReadFasta(rdr, rec) DO
    bits := Viterbi(rec.seq);
    IF bits >= minBits THEN
      seqLen := BioSeq.Length(rec.seq);
      evalue := CalcEvalue(seqLen, bits);
      Out.String(rec.name); Out.Char(9X);
      Out.String(hmmName);  Out.Char(9X);
      Out.Fixed(bits, 0, 2); Out.Char(9X);
      PrintEvalue(evalue);   Out.Char(9X);
      Out.Int(seqLen, 0); Out.Ln;
      INC(hits)
    END
  END;
  BioIO.CloseFasta(rdr);

  Out.String("# "); Out.Int(hits, 0);
  Out.String(" hit(s) >= "); Out.Fixed(minBits, 0, 1); Out.String(" bits"); Out.Ln
END DoSearch;

(* ------------------------------------------------------------------ *)
(*  Entry point                                                         *)
(* ------------------------------------------------------------------ *)

VAR
  mode, arg1, arg2, opt, sval : ARRAY 1024 OF CHAR;
  minBits : REAL;
  i : INTEGER;

BEGIN
  NegInf := -1.0E30;

  IF Args.Count() < 3 THEN
    Out.String("Usage:"); Out.Ln;
    Out.String("  SeqHMM build  <msa.afa> <model.hmm>"); Out.Ln;
    Out.String("  SeqHMM search <model.hmm> <db.fa> [-t <minBits>]"); Out.Ln;
    Out.String("Options:"); Out.Ln;
    Out.String("  -t <real>  bit-score threshold (default 10.0)"); Out.Ln;
    RETURN
  END;

  Args.Get(1, mode);
  Args.Get(2, arg1);
  Args.Get(3, arg2);

  IF Strings.Compare(mode, "build") = 0 THEN
    DoBuild(arg1, arg2)

  ELSIF Strings.Compare(mode, "search") = 0 THEN
    minBits := 10.0;
    i := 4;
    WHILE i <= Args.Count() DO
      Args.Get(i, opt);
      IF Strings.Compare(opt, "-t") = 0 THEN
        INC(i);
        IF i <= Args.Count() THEN
          Args.Get(i, sval);
          IF ~Strings.StrToReal(sval, minBits) THEN minBits := 10.0 END
        END
      END;
      INC(i)
    END;
    DoSearch(arg1, arg2, minBits)

  ELSE
    Out.String("Unknown mode: "); Out.String(mode); Out.Ln;
    Out.String("Use 'build' or 'search'."); Out.Ln
  END
END SeqHMM.
