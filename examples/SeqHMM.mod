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

  Emit mode:    SeqHMM emit   <model.hmm> [-n <count>] [-c]
    -c: emit the consensus (argmax residue at each match state).
    Default: stochastically sample sequences by walking the HMM state machine
    (match -> emit from profile; insert -> emit from background; delete -> skip).
    Insert loops are capped at 100 per position to bound output length.

  Search mode:  SeqHMM search <model.hmm> <db.fa> [-t <minBits>]
    Reads profile and FASTA database.
    Scores each sequence with local Viterbi in log space.
    Local entry into any match state k costs logEntry = ln(1/L).
    Bit score = (best_viterbi - null_score) / ln(2).
    Outputs TSV of hits above threshold (default 10 bits):
      seq_name  model_name  bits  evalue  hit_start  hit_end  seq_len

  Align mode:   SeqHMM align  <model.hmm> <seqs.fa> [-t <minBits>] [-o <out.afa>]
    Aligns each sequence to the profile using Viterbi traceback.
    Outputs a gapped FASTA (MSA) where all rows share the same column layout:
      Match column k  -> upper-case residue or '-' if deleted
      Insert gap k    -> lower-case residues or '-' padding
    Sequences below the bit threshold are skipped with a comment line.

  Binary .hmm format:
    WriteInt  hmmLen
    WriteInt  hmmAlph        (4 = DNA, 20 = AA)
    WriteString hmmName
    WriteReal logBg[0..alph-1]
    WriteReal logEmitM[0..L-1][0..alph-1]   (row-major)
    WriteReal logEmitI[0..alph-1]
    WriteReal logTrans[0..L-1][0..6]         (TMM TMI TMD TIM TII TDM TDD)
*)

IMPORT BioIO, BioSeq, Files, Out, Args, Strings, Math, Random, Parallel;

CONST
  MaxLen  = 2000;
  MaxAlph = 20;
  MaxSeqs = 256;
  Pseudo  = 1.0;
  TMM = 0; TMI = 1; TMD = 2; TIM = 3; TII = 4; TDM = 5; TDD = 6;

  (* State codes used in path and traceback arrays. *)
  StateM   = 0;
  StateI   = 1;
  StateD   = 2;
  SrcEntry = 3;  (* local alignment entry, stored in traceback source field *)

  (* Maximum residues per sequence processed by Viterbi (scoring). *)
  MaxSeqLen = 100000;

  (* Maximum residues per sequence for traceback (align mode).
     Kept small to avoid multi-GB static arrays; sequences longer than
     this are truncated for alignment purposes only, not for scoring. *)
  MaxTraceLen = 1000;

  (* Maximum steps in a single aligned path (match+insert+delete). *)
  MaxPathLen = MaxLen * 2 + 2;

  (* Maximum parallel workers for DoSearch. *)
  MaxWorkers = 64;

VAR
  NegInf       : REAL;   (* initialised to -1.0E30 in BEGIN *)
  NegInfThresh : REAL;   (* initialised to -5.0E29 in BEGIN *)

  hmmLen  : INTEGER;
  hmmAlph : INTEGER;
  hmmName : ARRAY 256 OF CHAR;

  logEmitM : ARRAY MaxLen OF ARRAY MaxAlph OF REAL;
  logEmitI : ARRAY MaxAlph OF REAL;
  logTrans : ARRAY MaxLen OF ARRAY 7 OF REAL;
  logBg    : ARRAY MaxAlph OF REAL;

  (* Viterbi DP tables: current and previous residue rows. *)
  vM, vMprev : ARRAY MaxLen + 2 OF REAL;
  vI, vIprev : ARRAY MaxLen + 2 OF REAL;
  vD         : ARRAY MaxLen + 2 OF REAL;

  (* Traceback tables for ViterbiTrace (indexed [j][k]). *)
  (* Each cell packs: src*4 + arrivingState, all as plain INTEGER. *)
  tbM : ARRAY MaxTraceLen OF ARRAY MaxLen + 2 OF INTEGER;
  tbI : ARRAY MaxTraceLen OF ARRAY MaxLen + 2 OF INTEGER;
  tbD : ARRAY MaxTraceLen OF ARRAY MaxLen + 2 OF INTEGER;

  seqBuf   : ARRAY MaxSeqLen + 1 OF CHAR;

  seqs     : ARRAY MaxSeqs OF BioSeq.Seq;
  seqCount : INTEGER;

(* ------------------------------------------------------------------ *)
(*  Sentinel helpers                                                    *)
(* ------------------------------------------------------------------ *)

PROCEDURE IsNegInf(x: REAL): BOOLEAN;
BEGIN RETURN x < NegInfThresh END IsNegInf;

PROCEDURE SafeAdd(a, b: REAL): REAL;
BEGIN
  IF IsNegInf(a) OR IsNegInf(b) THEN RETURN NegInf END;
  RETURN a + b
END SafeAdd;

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

(* ------------------------------------------------------------------ *)
(*  Alphabet detection                                                  *)
(* ------------------------------------------------------------------ *)

PROCEDURE DetectAlphabet(): INTEGER;
(* Survey all sequences; amino acid if any sequence is non-nucleotide. *)
VAR s: INTEGER;
BEGIN
  FOR s := 0 TO seqCount - 1 DO
    IF ~BioSeq.IsNucleotide(seqs[s]) THEN RETURN 20 END
  END;
  RETURN 4
END DetectAlphabet;

PROCEDURE SetBgFreqs;
VAR i: INTEGER;
BEGIN
  IF hmmAlph = 4 THEN
    FOR i := 0 TO 3 DO logBg[i] := Math.ln(0.25) END
  ELSE
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
(*  Sequence buffer helper                                              *)
(* ------------------------------------------------------------------ *)

PROCEDURE LoadSeq(seq: BioSeq.Seq): INTEGER;
(* Slices seq into seqBuf, caps at MaxSeqLen, returns actual length used. *)
VAR T: INTEGER;
BEGIN
  T := BioSeq.Length(seq);
  IF T > MaxSeqLen THEN T := MaxSeqLen END;
  BioSeq.Slice(seq, 0, T, seqBuf);
  seqBuf[T] := 0X;
  RETURN T
END LoadSeq;

PROCEDURE LoadSeqW(seq: BioSeq.Seq; wi: INTEGER): INTEGER;
VAR T: INTEGER;
BEGIN
  T := BioSeq.Length(seq);
  IF T > MaxSeqLen THEN T := MaxSeqLen END;
  BioSeq.Slice(seq, 0, T, wkSeqBuf[wi]);
  wkSeqBuf[wi][T] := 0X;
  RETURN T
END LoadSeqW;

(* ------------------------------------------------------------------ *)
(*  Build                                                               *)
(* ------------------------------------------------------------------ *)

PROCEDURE BuildHMM(alnLen: INTEGER);
VAR
  k, s, r   : INTEGER;
  cnt        : ARRAY MaxAlph OF REAL;
  total, nMM, nMD, nDM, nDD, p, q : REAL;
  c          : CHAR;
  curGap     : ARRAY MaxSeqs OF BOOLEAN;
  prevGap    : ARRAY MaxSeqs OF BOOLEAN;
BEGIN
  hmmLen := alnLen;

  FOR k := 0 TO alnLen - 1 DO
    FOR r := 0 TO 6 DO logTrans[k][r] := NegInf END
  END;

  FOR s := 0 TO seqCount - 1 DO prevGap[s] := TRUE END;

  FOR k := 0 TO alnLen - 1 DO
    FOR r := 0 TO hmmAlph - 1 DO cnt[r] := Pseudo END;
    total := FLT(hmmAlph) * Pseudo;
    FOR s := 0 TO seqCount - 1 DO
      c := BioSeq.Get(seqs[s], k);
      curGap[s] := IsGap(c);
      IF ~curGap[s] THEN
        r := ResIdx(c);
        IF r >= 0 THEN cnt[r] := cnt[r] + 1.0; total := total + 1.0 END
      END
    END;
    FOR r := 0 TO hmmAlph - 1 DO
      logEmitM[k][r] := Math.ln(cnt[r] / total) - logBg[r]
    END;

    IF k > 0 THEN
      nMM := Pseudo; nMD := Pseudo; nDM := Pseudo; nDD := Pseudo;
      FOR s := 0 TO seqCount - 1 DO
        IF ~prevGap[s] & ~curGap[s] THEN      nMM := nMM + 1.0
        ELSIF ~prevGap[s] & curGap[s] THEN    nMD := nMD + 1.0
        ELSIF prevGap[s] & ~curGap[s] THEN    nDM := nDM + 1.0
        ELSE                                   nDD := nDD + 1.0
        END
      END;
      p := nMM + nMD;
      q := nDM + nDD;
      logTrans[k-1][TMM] := Math.ln(nMM / p * 0.99);
      logTrans[k-1][TMD] := Math.ln(nMD / p * 0.99);
      logTrans[k-1][TMI] := Math.ln(0.01);
      logTrans[k-1][TIM] := Math.ln(0.90);
      logTrans[k-1][TII] := Math.ln(0.10);
      logTrans[k-1][TDM] := Math.ln(nDM / q);
      logTrans[k-1][TDD] := Math.ln(nDD / q)
    END;

    FOR s := 0 TO seqCount - 1 DO prevGap[s] := curGap[s] END
  END;

  logTrans[alnLen-1][TMM] := Math.ln(0.99);
  logTrans[alnLen-1][TMI] := Math.ln(0.01);
  logTrans[alnLen-1][TMD] := NegInf;
  logTrans[alnLen-1][TIM] := Math.ln(0.90);
  logTrans[alnLen-1][TII] := Math.ln(0.10);
  logTrans[alnLen-1][TDM] := Math.ln(1.0);
  logTrans[alnLen-1][TDD] := NegInf
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
(*  Viterbi (scoring only)                                             *)
(* ------------------------------------------------------------------ *)

PROCEDURE Viterbi(seq: BioSeq.Seq; dbTotalRes: INTEGER): REAL;
VAR
  T, k, j, ri : INTEGER;
  best, logEntry, score : REAL;
  c : CHAR;
  mVal, iVal, dVal : REAL;
BEGIN
  T := LoadSeq(seq);
  IF (T = 0) OR (hmmLen = 0) THEN RETURN NegInf END;

  logEntry := Math.ln(1.0 / FLT(hmmLen));

  FOR k := 0 TO hmmLen + 1 DO
    vMprev[k] := NegInf; vIprev[k] := NegInf; vD[k] := NegInf
  END;
  score := NegInf;

  FOR j := 0 TO T - 1 DO
    c  := seqBuf[j];
    ri := ResIdx(c);
    FOR k := 0 TO hmmLen - 1 DO vM[k] := NegInf; vI[k] := NegInf END;
    vD[0] := NegInf;

    FOR k := 0 TO hmmLen - 1 DO
      IF k = 0 THEN vD[0] := NegInf
      ELSE
        dVal := Math.max(SafeAdd(vM[k-1], logTrans[k-1][TMD]),
                         SafeAdd(vD[k-1], logTrans[k-1][TDD]));
        vD[k] := dVal
      END;

      IF k = 0 THEN best := logEntry
      ELSE
        best := Math.max(SafeAdd(vMprev[k-1], logTrans[k-1][TMM]),
                Math.max(SafeAdd(vIprev[k-1], logTrans[k-1][TIM]),
                         SafeAdd(vD[k-1],     logTrans[k-1][TDM])));
        best := Math.max(best, logEntry)
      END;
      IF ri >= 0 THEN mVal := logEmitM[k][ri] + best ELSE mVal := NegInf END;
      vM[k] := mVal;

      IF ri >= 0 THEN
        iVal := logEmitI[ri] + Math.max(SafeAdd(vMprev[k], logTrans[k][TMI]),
                                         SafeAdd(vIprev[k], logTrans[k][TII]))
      ELSE iVal := NegInf
      END;
      vI[k] := iVal;

      IF vM[k] > score THEN score := vM[k] END
    END;

    FOR k := 0 TO hmmLen - 1 DO
      vMprev[k] := vM[k]; vIprev[k] := vI[k]
    END
  END;

  IF ~IsNegInf(score) THEN RETURN score / Math.ln(2.0)
  ELSE RETURN NegInf
  END
END Viterbi;

(* ------------------------------------------------------------------ *)
(*  Viterbi with hit-position tracking (no traceback tables needed)   *)
(* ------------------------------------------------------------------ *)

PROCEDURE ViterbiHitPos(seq: BioSeq.Seq; dbTotalRes: INTEGER;
                         VAR hitStart, hitEnd: INTEGER): REAL;
(*
  Same DP as Viterbi but also tracks the first and last sequence positions
  consumed by the best local alignment.  Returns bit score; sets hitStart
  and hitEnd to 0-based inclusive positions.
*)
VAR
  T, k, j, ri   : INTEGER;
  best, logEntry, score, v : REAL;
  c              : CHAR;
  mVal, iVal, dVal : REAL;
  sM, sI         : INTEGER;
  startM, startMprev : ARRAY MaxLen + 2 OF INTEGER;
  startI, startIprev : ARRAY MaxLen + 2 OF INTEGER;
  startD         : ARRAY MaxLen + 2 OF INTEGER;
BEGIN
  T := LoadSeq(seq);
  IF (T = 0) OR (hmmLen = 0) THEN
    hitStart := 0; hitEnd := 0; RETURN NegInf
  END;

  logEntry := Math.ln(1.0 / FLT(hmmLen));

  FOR k := 0 TO hmmLen + 1 DO
    vMprev[k] := NegInf; vIprev[k] := NegInf; vD[k] := NegInf;
    startMprev[k] := 0; startIprev[k] := 0; startD[k] := 0
  END;
  score := NegInf; hitStart := 0; hitEnd := 0;

  FOR j := 0 TO T - 1 DO
    c  := seqBuf[j];
    ri := ResIdx(c);
    FOR k := 0 TO hmmLen - 1 DO vM[k] := NegInf; vI[k] := NegInf END;
    vD[0] := NegInf; startD[0] := j;

    FOR k := 0 TO hmmLen - 1 DO
      (* Delete D_k: predecessors are M_{k-1} and D_{k-1} at current j *)
      IF k > 0 THEN
        IF SafeAdd(vM[k-1], logTrans[k-1][TMD]) >=
           SafeAdd(vD[k-1], logTrans[k-1][TDD]) THEN
          dVal    := SafeAdd(vM[k-1], logTrans[k-1][TMD]);
          startD[k] := startM[k-1]
        ELSE
          dVal    := SafeAdd(vD[k-1], logTrans[k-1][TDD]);
          startD[k] := startD[k-1]
        END;
        vD[k] := dVal
      END;

      (* Match M_k: best among {M_{k-1}, I_{k-1}, D_{k-1}} from prev row + logEntry *)
      IF k = 0 THEN
        best := logEntry; sM := j
      ELSE
        best := logEntry; sM := j;
        v := SafeAdd(vMprev[k-1], logTrans[k-1][TMM]);
        IF v > best THEN best := v; sM := startMprev[k-1] END;
        v := SafeAdd(vIprev[k-1], logTrans[k-1][TIM]);
        IF v > best THEN best := v; sM := startIprev[k-1] END;
        v := SafeAdd(vD[k-1], logTrans[k-1][TDM]);
        IF v > best THEN best := v; sM := startD[k-1] END
      END;
      IF ri >= 0 THEN mVal := logEmitM[k][ri] + best ELSE mVal := NegInf END;
      vM[k] := mVal; startM[k] := sM;

      (* Insert I_k: predecessors are M_k and I_k from prev row *)
      IF ri >= 0 THEN
        IF SafeAdd(vMprev[k], logTrans[k][TMI]) >=
           SafeAdd(vIprev[k], logTrans[k][TII]) THEN
          iVal := logEmitI[ri] + SafeAdd(vMprev[k], logTrans[k][TMI]);
          sI   := startMprev[k]
        ELSE
          iVal := logEmitI[ri] + SafeAdd(vIprev[k], logTrans[k][TII]);
          sI   := startIprev[k]
        END
      ELSE iVal := NegInf; sI := 0
      END;
      vI[k] := iVal; startI[k] := sI;

      IF vM[k] > score THEN
        score := vM[k]; hitEnd := j; hitStart := startM[k]
      END
    END;

    FOR k := 0 TO hmmLen - 1 DO
      vMprev[k] := vM[k]; vIprev[k] := vI[k];
      startMprev[k] := startM[k]; startIprev[k] := startI[k]
    END
  END;

  IF ~IsNegInf(score) THEN RETURN score / Math.ln(2.0)
  ELSE hitStart := 0; hitEnd := 0; RETURN NegInf
  END
END ViterbiHitPos;

(* ------------------------------------------------------------------ *)
(*  Parallel-safe Viterbi worker (for DoSearch)                       *)
(* ------------------------------------------------------------------ *)

PROCEDURE ViterbiHitPosW(wi: INTEGER);
(*
  Thread-safe version of ViterbiHitPos.  Scores wkSeqs[wi] using
  per-worker workspace arrays (wkVM/wkVMprev/wkVI/wkVIprev/wkVD/wkSeqBuf),
  writing bit score to wkBits[wi] and positions to wkStart[wi]/wkEnd[wi].
*)
VAR
  T, k, j, ri   : INTEGER;
  best, logEntry, score, v : REAL;
  c              : CHAR;
  mVal, iVal, dVal : REAL;
  sM, sI         : INTEGER;
  startM, startMprev : ARRAY MaxLen + 2 OF INTEGER;
  startI, startIprev : ARRAY MaxLen + 2 OF INTEGER;
  startD         : ARRAY MaxLen + 2 OF INTEGER;
BEGIN
  T := LoadSeqW(wkSeqs[wi], wi);
  IF (T = 0) OR (hmmLen = 0) THEN
    wkBits[wi] := NegInf; wkStart[wi] := 0; wkEnd[wi] := 0; RETURN
  END;

  logEntry := Math.ln(1.0 / FLT(hmmLen));

  FOR k := 0 TO hmmLen + 1 DO
    wkVMprev[wi][k] := NegInf; wkVIprev[wi][k] := NegInf; wkVD[wi][k] := NegInf;
    startMprev[k] := 0; startIprev[k] := 0; startD[k] := 0
  END;
  score := NegInf; wkStart[wi] := 0; wkEnd[wi] := 0;

  FOR j := 0 TO T - 1 DO
    c  := wkSeqBuf[wi][j];
    ri := ResIdx(c);
    FOR k := 0 TO hmmLen - 1 DO wkVM[wi][k] := NegInf; wkVI[wi][k] := NegInf END;
    wkVD[wi][0] := NegInf; startD[0] := j;

    FOR k := 0 TO hmmLen - 1 DO
      IF k > 0 THEN
        IF SafeAdd(wkVM[wi][k-1], logTrans[k-1][TMD]) >=
           SafeAdd(wkVD[wi][k-1], logTrans[k-1][TDD]) THEN
          dVal      := SafeAdd(wkVM[wi][k-1], logTrans[k-1][TMD]);
          startD[k] := startM[k-1]
        ELSE
          dVal      := SafeAdd(wkVD[wi][k-1], logTrans[k-1][TDD]);
          startD[k] := startD[k-1]
        END;
        wkVD[wi][k] := dVal
      END;

      IF k = 0 THEN
        best := logEntry; sM := j
      ELSE
        best := logEntry; sM := j;
        v := SafeAdd(wkVMprev[wi][k-1], logTrans[k-1][TMM]);
        IF v > best THEN best := v; sM := startMprev[k-1] END;
        v := SafeAdd(wkVIprev[wi][k-1], logTrans[k-1][TIM]);
        IF v > best THEN best := v; sM := startIprev[k-1] END;
        v := SafeAdd(wkVD[wi][k-1], logTrans[k-1][TDM]);
        IF v > best THEN best := v; sM := startD[k-1] END
      END;
      IF ri >= 0 THEN mVal := logEmitM[k][ri] + best ELSE mVal := NegInf END;
      wkVM[wi][k] := mVal; startM[k] := sM;

      IF ri >= 0 THEN
        IF SafeAdd(wkVMprev[wi][k], logTrans[k][TMI]) >=
           SafeAdd(wkVIprev[wi][k], logTrans[k][TII]) THEN
          iVal := logEmitI[ri] + SafeAdd(wkVMprev[wi][k], logTrans[k][TMI]);
          sI   := startMprev[k]
        ELSE
          iVal := logEmitI[ri] + SafeAdd(wkVIprev[wi][k], logTrans[k][TII]);
          sI   := startIprev[k]
        END
      ELSE iVal := NegInf; sI := 0
      END;
      wkVI[wi][k] := iVal; startI[k] := sI;

      IF wkVM[wi][k] > score THEN
        score := wkVM[wi][k]; wkEnd[wi] := j; wkStart[wi] := startM[k]
      END
    END;

    FOR k := 0 TO hmmLen - 1 DO
      wkVMprev[wi][k] := wkVM[wi][k]; wkVIprev[wi][k] := wkVI[wi][k];
      startMprev[k] := startM[k]; startIprev[k] := startI[k]
    END
  END;

  IF ~IsNegInf(score) THEN wkBits[wi] := score / Math.ln(2.0)
  ELSE wkBits[wi] := NegInf; wkStart[wi] := 0; wkEnd[wi] := 0
  END
END ViterbiHitPosW;

PROCEDURE ScoreWorker(wi: INTEGER);
BEGIN ViterbiHitPosW(wi) END ScoreWorker;

(* ------------------------------------------------------------------ *)
(*  Viterbi with traceback                                             *)
(* ------------------------------------------------------------------ *)

PROCEDURE ViterbiTrace(seq: BioSeq.Seq;
                        VAR T: INTEGER;
                        VAR bestJ, bestK: INTEGER): REAL;
(*
  Same DP as Viterbi but records per-cell traceback for M, I, and D states.
  Each cell stores src*4 + arrivingState.
  Returns bit score; sets T to the capped sequence length used,
  and bestJ/bestK to the best local-exit cell.
*)
VAR
  k, j, ri : INTEGER;
  best, logEntry, score : REAL;
  c : CHAR;
  mVal, iVal, dVal : REAL;
  src : INTEGER;
  fromMscore, fromDscore : REAL;
BEGIN
  T := LoadSeq(seq);
  IF T > MaxTraceLen THEN T := MaxTraceLen END;
  IF (T = 0) OR (hmmLen = 0) THEN
    bestJ := -1; bestK := -1; RETURN NegInf
  END;

  logEntry := Math.ln(1.0 / FLT(hmmLen));

  FOR k := 0 TO hmmLen + 1 DO
    vMprev[k] := NegInf; vIprev[k] := NegInf; vD[k] := NegInf
  END;
  score := NegInf; bestJ := -1; bestK := -1;

  FOR j := 0 TO T - 1 DO
    c  := seqBuf[j];
    ri := ResIdx(c);
    FOR k := 0 TO hmmLen - 1 DO vM[k] := NegInf; vI[k] := NegInf END;
    vD[0] := NegInf;

    FOR k := 0 TO hmmLen - 1 DO

      (* Delete D_k: predecessors from current step (no residue consumed). *)
      IF k = 0 THEN
        vD[0] := NegInf; tbD[j][0] := -1
      ELSE
        fromMscore := SafeAdd(vM[k-1], logTrans[k-1][TMD]);
        fromDscore := SafeAdd(vD[k-1], logTrans[k-1][TDD]);
        IF fromMscore >= fromDscore THEN
          vD[k] := fromMscore; tbD[j][k] := StateM * 4 + StateD
        ELSE
          vD[k] := fromDscore; tbD[j][k] := StateD * 4 + StateD
        END
      END;

      (* Match M_k. *)
      IF k = 0 THEN
        best := logEntry; src := SrcEntry
      ELSE
        best := logEntry; src := SrcEntry;
        IF SafeAdd(vMprev[k-1], logTrans[k-1][TMM]) > best THEN
          best := SafeAdd(vMprev[k-1], logTrans[k-1][TMM]); src := StateM
        END;
        IF SafeAdd(vIprev[k-1], logTrans[k-1][TIM]) > best THEN
          best := SafeAdd(vIprev[k-1], logTrans[k-1][TIM]); src := StateI
        END;
        IF SafeAdd(vD[k-1], logTrans[k-1][TDM]) > best THEN
          best := SafeAdd(vD[k-1], logTrans[k-1][TDM]); src := StateD
        END
      END;
      IF ri >= 0 THEN mVal := logEmitM[k][ri] + best ELSE mVal := NegInf END;
      vM[k] := mVal;
      tbM[j][k] := src * 4 + StateM;

      (* Insert I_k. *)
      IF ri >= 0 THEN
        IF SafeAdd(vMprev[k], logTrans[k][TMI]) >=
           SafeAdd(vIprev[k], logTrans[k][TII]) THEN
          iVal := logEmitI[ri] + SafeAdd(vMprev[k], logTrans[k][TMI]);
          tbI[j][k] := StateM * 4 + StateI
        ELSE
          iVal := logEmitI[ri] + SafeAdd(vIprev[k], logTrans[k][TII]);
          tbI[j][k] := StateI * 4 + StateI
        END
      ELSE
        iVal := NegInf; tbI[j][k] := 0
      END;
      vI[k] := iVal;

      IF vM[k] > score THEN
        score := vM[k]; bestJ := j; bestK := k
      END
    END;

    FOR k := 0 TO hmmLen - 1 DO
      vMprev[k] := vM[k]; vIprev[k] := vI[k]
    END
  END;

  IF ~IsNegInf(score) THEN RETURN score / Math.ln(2.0)
  ELSE bestJ := -1; bestK := -1; RETURN NegInf
  END
END ViterbiTrace;

(* ------------------------------------------------------------------ *)
(*  Path storage for align two-pass                                    *)
(* ------------------------------------------------------------------ *)

(*
  A path is a sequence of (state, profileK, seqJ) triples recording the
  Viterbi alignment of one sequence.  Stored compactly as three parallel
  arrays per sequence.  MaxPathLen covers all match+insert+delete steps.
*)
TYPE
  PathRec = RECORD
    state : ARRAY MaxPathLen OF INTEGER;  (* StateM / StateI / StateD *)
    profK : ARRAY MaxPathLen OF INTEGER;  (* profile position *)
    seqJ  : ARRAY MaxPathLen OF INTEGER;  (* sequence residue index, -1 for D *)
    len   : INTEGER;
    startK: INTEGER;  (* first profile column in local alignment *)
    endK  : INTEGER;  (* last profile column in local alignment *)
    bits  : REAL;
    seqT  : INTEGER;  (* capped sequence length used *)
    name  : ARRAY 256 OF CHAR;
  END;

VAR
  paths    : ARRAY MaxSeqs OF PathRec;
  nPaths   : INTEGER;
  maxIns   : ARRAY MaxLen + 1 OF INTEGER;  (* max insert count after column k *)

(* Per-worker workspace for parallel search scoring. *)
VAR
  wkSeqs   : ARRAY MaxWorkers OF BioSeq.Seq;
  wkNames  : ARRAY MaxWorkers OF ARRAY 256 OF CHAR;
  wkBits   : ARRAY MaxWorkers OF REAL;
  wkStart  : ARRAY MaxWorkers OF INTEGER;
  wkEnd    : ARRAY MaxWorkers OF INTEGER;
  wkLen    : ARRAY MaxWorkers OF INTEGER;
  wkSeqBuf : ARRAY MaxWorkers OF ARRAY MaxSeqLen + 1 OF CHAR;
  wkVM     : ARRAY MaxWorkers OF ARRAY MaxLen + 2 OF REAL;
  wkVMprev : ARRAY MaxWorkers OF ARRAY MaxLen + 2 OF REAL;
  wkVI     : ARRAY MaxWorkers OF ARRAY MaxLen + 2 OF REAL;
  wkVIprev : ARRAY MaxWorkers OF ARRAY MaxLen + 2 OF REAL;
  wkVD     : ARRAY MaxWorkers OF ARRAY MaxLen + 2 OF REAL;

PROCEDURE WalkTraceback(bestJ, bestK, seqT: INTEGER; VAR pr: PathRec);
(*
  Reconstructs the path by walking tbM/tbI/tbD backwards from (bestJ,bestK),
  then reverses it in place.
*)
VAR
  pLen, p, j, k, state, src, tb, tmp : INTEGER;
BEGIN
  pLen := 0;
  j := bestJ; k := bestK; state := StateM;

  LOOP
    pr.state[pLen] := state;
    pr.profK[pLen] := k;
    IF state = StateD THEN pr.seqJ[pLen] := -1
    ELSE pr.seqJ[pLen] := j
    END;
    INC(pLen);
    IF pLen >= MaxPathLen THEN EXIT END;

    IF state = StateM THEN
      tb  := tbM[j][k];
      src := tb DIV 4;
      IF (src = SrcEntry) OR (k = 0) THEN EXIT END;
      IF src = StateM THEN DEC(j); DEC(k); state := StateM
      ELSIF src = StateI THEN DEC(j); DEC(k); state := StateI
      ELSE (* src = StateD *) DEC(k); state := StateD
      END
    ELSIF state = StateI THEN
      tb  := tbI[j][k];
      src := tb DIV 4;
      DEC(j);
      IF src = StateM THEN state := StateM
      ELSE state := StateI
      END
      (* k stays the same: insert is at same profile position *)
    ELSE (* StateD *)
      tb  := tbD[j][k];
      src := tb DIV 4;
      IF (tb < 0) OR (k = 0) THEN EXIT END;
      DEC(k);
      IF src = StateM THEN state := StateM
      ELSE state := StateD
      END
      (* j stays same: delete consumes no residue *)
    END
  END;

  (* Reverse path in place. *)
  FOR p := 0 TO pLen DIV 2 - 1 DO
    tmp := pr.state[p]; pr.state[p] := pr.state[pLen-1-p]; pr.state[pLen-1-p] := tmp;
    tmp := pr.profK[p]; pr.profK[p] := pr.profK[pLen-1-p]; pr.profK[pLen-1-p] := tmp;
    tmp := pr.seqJ[p];  pr.seqJ[p]  := pr.seqJ[pLen-1-p];  pr.seqJ[pLen-1-p]  := tmp
  END;

  pr.len := pLen;
  IF pLen > 0 THEN
    pr.startK := pr.profK[0];
    pr.endK   := pr.profK[pLen-1]
  ELSE
    pr.startK := 0; pr.endK := 0
  END
END WalkTraceback;

PROCEDURE CountPathInserts(VAR pr: PathRec; VAR ins: ARRAY OF INTEGER);
(*
  Counts the number of insert steps after each profile column k in this path.
  ins[k] is incremented for each StateI step at profile position k.
  ins has size hmmLen+1 (inserts after the last match state use ins[hmmLen]).
*)
VAR p, k: INTEGER;
BEGIN
  FOR p := 0 TO pr.len - 1 DO
    IF pr.state[p] = StateI THEN
      k := pr.profK[p];
      IF k < hmmLen THEN ins[k] := ins[k] + 1 END
    END
  END
END CountPathInserts;

(* ------------------------------------------------------------------ *)
(*  Aligned row rendering                                              *)
(* ------------------------------------------------------------------ *)

PROCEDURE WriteAlignedRow(VAR pr: PathRec;
                           VAR ins: ARRAY OF INTEGER;
                           wr: Files.Rider; toFile: BOOLEAN);
(*
  Renders one aligned sequence row to either a Files.Rider or stdout.
  Column layout:
    For each profile column k (0..hmmLen-1):
      1. One match/delete character (upper-case residue or '-')
      2. ins[k] insert characters (lower-case residue or '-' padding)
*)
VAR
  p, k, col, insHere, insMax : INTEGER;
  bitsInt, bitsFrac : INTEGER;
  tmp : ARRAY 16 OF CHAR;
  c : CHAR;

  PROCEDURE Emit(ch: CHAR);
  BEGIN
    IF toFile THEN Files.Write(wr, ch)
    ELSE Out.Char(ch)
    END
  END Emit;

  PROCEDURE EmitLn;
  BEGIN
    IF toFile THEN Files.Write(wr, 0AX)
    ELSE Out.Ln
    END
  END EmitLn;

  PROCEDURE EmitStr(s: ARRAY OF CHAR);
  VAR i: INTEGER;
  BEGIN i := 0; WHILE s[i] # 0X DO Emit(s[i]); INC(i) END
  END EmitStr;

BEGIN
  (* Header *)
  Emit('>'); EmitStr(pr.name); EmitStr(" bits=");
  bitsInt  := FLOOR(pr.bits);
  bitsFrac := FLOOR((pr.bits - FLT(bitsInt)) * 100.0 + 0.5);
  IF bitsFrac >= 100 THEN INC(bitsInt); bitsFrac := 0 END;
  Strings.IntToStr(bitsInt, tmp);  EmitStr(tmp);
  Emit('.');
  IF bitsFrac < 10 THEN Emit('0') END;
  Strings.IntToStr(bitsFrac, tmp); EmitStr(tmp);
  EmitLn;

  col := 0; p := 0;

  (* Left-flank gap padding for profile columns before alignment starts. *)
  FOR k := 0 TO pr.startK - 1 DO
    Emit('-'); INC(col); IF col = 60 THEN EmitLn; col := 0 END;
    insMax := ins[k];
    WHILE insMax > 0 DO
      Emit('-'); INC(col); IF col = 60 THEN EmitLn; col := 0 END;
      DEC(insMax)
    END
  END;

  k := pr.startK;
  WHILE k <= pr.endK DO
    (* Match or delete character for column k. *)
    IF (p < pr.len) & (pr.profK[p] = k) & (pr.state[p] = StateM) THEN
      c := CAP(seqBuf[pr.seqJ[p]]);
      Emit(c); INC(p)
    ELSIF (p < pr.len) & (pr.profK[p] = k) & (pr.state[p] = StateD) THEN
      Emit('-'); INC(p)
    ELSE
      Emit('-')  (* column not reached by local alignment *)
    END;
    INC(col); IF col = 60 THEN EmitLn; col := 0 END;

    (* Insert characters after column k, padded to ins[k] width. *)
    insHere := 0;
    WHILE (p < pr.len) & (pr.profK[p] = k) & (pr.state[p] = StateI) DO
      c := seqBuf[pr.seqJ[p]];
      (* Lower-case: add 32 to upper-case ASCII if in A-Z range. *)
      IF (c >= 'A') & (c <= 'Z') THEN c := CHR(ORD(c) + 32) END;
      Emit(c); INC(col); IF col = 60 THEN EmitLn; col := 0 END;
      INC(insHere); INC(p)
    END;
    insMax := ins[k] - insHere;
    WHILE insMax > 0 DO
      Emit('-'); INC(col); IF col = 60 THEN EmitLn; col := 0 END;
      DEC(insMax)
    END;

    INC(k)
  END;

  (* Right-flank gap padding. *)
  FOR k := pr.endK + 1 TO hmmLen - 1 DO
    Emit('-'); INC(col); IF col = 60 THEN EmitLn; col := 0 END;
    insMax := ins[k];
    WHILE insMax > 0 DO
      Emit('-'); INC(col); IF col = 60 THEN EmitLn; col := 0 END;
      DEC(insMax)
    END
  END;

  IF col > 0 THEN EmitLn END
END WriteAlignedRow;

(* ------------------------------------------------------------------ *)
(*  Align mode                                                         *)
(* ------------------------------------------------------------------ *)

PROCEDURE DoAlign(hmmPath, faPath: ARRAY OF CHAR;
                  minBits: REAL; outPath: ARRAY OF CHAR);
(*
  Two-pass alignment:
    Pass 1: Run ViterbiTrace on every sequence, store paths in memory,
            accumulate maximum insert widths per gap position.
    Pass 2: Render all stored paths using the global insert widths,
            producing rows with identical column counts (valid MSA).

*)
VAR
  rdr         : BioIO.FastaReader;
  rec         : BioIO.FastaRecord;
  bits        : REAL;
  bestJ, bestK, seqT, i, k : INTEGER;
  outFile     : Files.File;
  wr          : Files.Rider;
  toFile      : BOOLEAN;
  localIns    : ARRAY MaxLen + 1 OF INTEGER;
  warned      : BOOLEAN;

  PROCEDURE EmitHeader(s: ARRAY OF CHAR);
  BEGIN
    IF toFile THEN
      WHILE s[0] # 0X DO Files.Write(wr, s[0]); s[0] := s[1] END;
      Files.Write(wr, 0AX)
    ELSE
      Out.String(s); Out.Ln
    END
  END EmitHeader;

BEGIN
  IF ~ReadHMM(hmmPath) THEN
    Out.String("Error: cannot read profile from "); Out.String(hmmPath); Out.Ln;
    RETURN
  END;
  IF ~BioIO.OpenFasta(rdr, faPath) THEN
    Out.String("Error: cannot open "); Out.String(faPath); Out.Ln;
    RETURN
  END;

  (* Determine output destination. *)
  toFile := (outPath[0] # 0X);
  IF toFile THEN
    outFile := Files.New(outPath);
    IF outFile = NIL THEN
      Out.String("Error: cannot create "); Out.String(outPath); Out.Ln;
      BioIO.CloseFasta(rdr); RETURN
    END;
    Files.Set(wr, outFile, 0)
  END;

  (* Initialise global max-insert counts. *)
  FOR k := 0 TO hmmLen DO maxIns[k] := 0 END;

  (* Pass 1: score, traceback, and accumulate insert widths. *)
  nPaths := 0; warned := FALSE;
  rec.seq := NIL;
  WHILE BioIO.ReadFasta(rdr, rec) DO
    bits := ViterbiTrace(rec.seq, seqT, bestJ, bestK);
    IF bits < minBits THEN
      Out.String("# skipping "); Out.String(rec.name);
      Out.String(" ("); Out.Fixed(bits, 0, 2);
      Out.String(" bits < threshold)"); Out.Ln
    ELSIF nPaths >= MaxSeqs THEN
      IF ~warned THEN
        Out.String("# Warning: more than "); Out.Int(MaxSeqs, 0);
        Out.String(" sequences; extras skipped."); Out.Ln;
        warned := TRUE
      END
    ELSE
      WalkTraceback(bestJ, bestK, seqT, paths[nPaths]);

      (* Save seqBuf contents for this sequence into path record's seqJ
         references -- seqBuf is reused each call so we must re-slice later.
         We store seqT so Pass 2 can reload the sequence. *)
      paths[nPaths].bits := bits;
      paths[nPaths].seqT := seqT;
      Strings.Copy(rec.name, paths[nPaths].name);

      FOR k := 0 TO hmmLen DO localIns[k] := 0 END;
      CountPathInserts(paths[nPaths], localIns);
      FOR k := 0 TO hmmLen - 1 DO
        IF localIns[k] > maxIns[k] THEN maxIns[k] := localIns[k] END
      END;
      INC(nPaths)
    END
  END;
  BioIO.CloseFasta(rdr);

  (*
    Pass 2: re-open the FASTA to reload sequences (seqBuf was overwritten),
    render each stored path with global insert widths.
    We match sequences to stored paths by order of appearance.
  *)
  IF ~BioIO.OpenFasta(rdr, faPath) THEN
    Out.String("Error: cannot reopen "); Out.String(faPath); Out.Ln;
    IF toFile THEN Files.Close(outFile) END;
    RETURN
  END;

  i := 0; rec.seq := NIL;
  WHILE BioIO.ReadFasta(rdr, rec) & (i < nPaths) DO
    (* Skip sequences that were rejected in pass 1. *)
    IF Strings.Compare(rec.name, paths[i].name) = 0 THEN
      (* Reload this sequence's residues into seqBuf. *)
      seqT := LoadSeq(rec.seq);
      WriteAlignedRow(paths[i], maxIns, wr, toFile);
      INC(i)
    END
  END;
  BioIO.CloseFasta(rdr);

  IF toFile THEN Files.Close(outFile) END
END DoAlign;

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

PROCEDURE CalcEvalue(dbTotalRes: INTEGER; bits: REAL): REAL;
VAR logE: REAL;
BEGIN
  logE := Math.ln(FLT(hmmLen)) + Math.ln(FLT(dbTotalRes))
          - bits * Math.ln(2.0);
  IF logE < -700.0 THEN RETURN 0.0 END;
  RETURN Math.exp(logE)
END CalcEvalue;

PROCEDURE PrintEvalue(e: REAL);
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
(*  Emit mode                                                           *)
(* ------------------------------------------------------------------ *)

PROCEDURE IdxToRes(idx: INTEGER): CHAR;
BEGIN
  IF hmmAlph = 4 THEN
    IF    idx = 0 THEN RETURN 'A' ELSIF idx = 1 THEN RETURN 'C'
    ELSIF idx = 2 THEN RETURN 'G' ELSE               RETURN 'T'
    END
  ELSE
    IF    idx =  0 THEN RETURN 'A' ELSIF idx =  1 THEN RETURN 'C'
    ELSIF idx =  2 THEN RETURN 'D' ELSIF idx =  3 THEN RETURN 'E'
    ELSIF idx =  4 THEN RETURN 'F' ELSIF idx =  5 THEN RETURN 'G'
    ELSIF idx =  6 THEN RETURN 'H' ELSIF idx =  7 THEN RETURN 'I'
    ELSIF idx =  8 THEN RETURN 'K' ELSIF idx =  9 THEN RETURN 'L'
    ELSIF idx = 10 THEN RETURN 'M' ELSIF idx = 11 THEN RETURN 'N'
    ELSIF idx = 12 THEN RETURN 'P' ELSIF idx = 13 THEN RETURN 'Q'
    ELSIF idx = 14 THEN RETURN 'R' ELSIF idx = 15 THEN RETURN 'S'
    ELSIF idx = 16 THEN RETURN 'T' ELSIF idx = 17 THEN RETURN 'V'
    ELSIF idx = 18 THEN RETURN 'W' ELSE               RETURN 'Y'
    END
  END
END IdxToRes;

PROCEDURE SampleMatchEmit(k: INTEGER): INTEGER;
VAR probs: ARRAY MaxAlph OF REAL; sum, u: REAL; r: INTEGER;
BEGIN
  sum := 0.0;
  FOR r := 0 TO hmmAlph - 1 DO
    probs[r] := Math.exp(logEmitM[k][r] + logBg[r]);
    sum := sum + probs[r]
  END;
  IF sum <= 0.0 THEN RETURN 0 END;
  u := Random.Real() * sum; r := 0;
  WHILE (r < hmmAlph - 1) & (u > probs[r]) DO u := u - probs[r]; INC(r) END;
  RETURN r
END SampleMatchEmit;

PROCEDURE SampleBgEmit(): INTEGER;
VAR probs: ARRAY MaxAlph OF REAL; sum, u: REAL; r: INTEGER;
BEGIN
  sum := 0.0;
  FOR r := 0 TO hmmAlph - 1 DO
    probs[r] := Math.exp(logBg[r]); sum := sum + probs[r]
  END;
  IF sum <= 0.0 THEN RETURN 0 END;
  u := Random.Real() * sum; r := 0;
  WHILE (r < hmmAlph - 1) & (u > probs[r]) DO u := u - probs[r]; INC(r) END;
  RETURN r
END SampleBgEmit;

PROCEDURE SampleTrans(l0, l1, l2: REAL): INTEGER;
VAR p0, p1, p2, sum, u: REAL;
BEGIN
  p0 := 0.0; p1 := 0.0; p2 := 0.0;
  IF ~IsNegInf(l0) THEN p0 := Math.exp(l0) END;
  IF ~IsNegInf(l1) THEN p1 := Math.exp(l1) END;
  IF ~IsNegInf(l2) THEN p2 := Math.exp(l2) END;
  sum := p0 + p1 + p2;
  IF sum <= 0.0 THEN RETURN -1 END;
  u := Random.Real() * sum;
  IF u < p0 THEN RETURN 0 END; u := u - p0;
  IF u < p1 THEN RETURN 1 END;
  RETURN 2
END SampleTrans;

PROCEDURE EmitConsensus;
VAR k, r, best, col: INTEGER; maxLP, lp: REAL;
BEGIN
  Out.Char('>'); Out.String(hmmName); Out.String("-consensus"); Out.Ln;
  col := 0;
  FOR k := 0 TO hmmLen - 1 DO
    best := 0; maxLP := logEmitM[k][0] + logBg[0];
    FOR r := 1 TO hmmAlph - 1 DO
      lp := logEmitM[k][r] + logBg[r];
      IF lp > maxLP THEN maxLP := lp; best := r END
    END;
    Out.Char(IdxToRes(best)); INC(col);
    IF col = 60 THEN Out.Ln; col := 0 END
  END;
  IF col > 0 THEN Out.Ln END
END EmitConsensus;

PROCEDURE EmitSample(seqNum: INTEGER);
CONST BufLen = 8001;
VAR
  buf      : ARRAY BufLen OF CHAR;
  blen, k, t, r, col, insCount : INTEGER;
  state    : INTEGER;
  truncated : BOOLEAN;
BEGIN
  blen := 0; k := 0; state := 0; truncated := FALSE;
  WHILE k < hmmLen DO
    IF state = 0 THEN
      r := SampleMatchEmit(k);
      IF blen < BufLen - 1 THEN buf[blen] := IdxToRes(r); INC(blen)
      ELSE truncated := TRUE
      END;
      t := SampleTrans(logTrans[k][TMM], logTrans[k][TMI], logTrans[k][TMD]);
      IF t < 0 THEN t := 0 END;
      IF    t = 0 THEN INC(k)
      ELSIF t = 1 THEN state := 1; insCount := 0
      ELSE               INC(k); state := 2
      END
    ELSIF state = 1 THEN
      r := SampleBgEmit();
      IF blen < BufLen - 1 THEN buf[blen] := IdxToRes(r); INC(blen)
      ELSE truncated := TRUE
      END;
      INC(insCount);
      t := SampleTrans(logTrans[k][TIM], logTrans[k][TII], NegInf);
      IF (t <= 0) OR (insCount >= 100) THEN INC(k); state := 0 END
    ELSE
      t := SampleTrans(logTrans[k][TDM], logTrans[k][TDD], NegInf);
      IF t < 0 THEN t := 0 END;
      INC(k);
      IF t = 1 THEN state := 2 ELSE state := 0 END
    END
  END;
  buf[blen] := 0X;
  Out.Char('>'); Out.String(hmmName); Out.Char('-'); Out.Int(seqNum, 0);
  IF truncated THEN Out.String(" [truncated]") END;
  Out.Ln;
  k := 0; col := 0;
  WHILE buf[k] # 0X DO
    Out.Char(buf[k]); INC(k); INC(col);
    IF col = 60 THEN Out.Ln; col := 0 END
  END;
  IF col > 0 THEN Out.Ln END
END EmitSample;

PROCEDURE DoEmit(hmmPath: ARRAY OF CHAR; nSeqs: INTEGER; consensus: BOOLEAN);
VAR n: INTEGER;
BEGIN
  IF ~ReadHMM(hmmPath) THEN
    Out.String("Error: cannot read profile from "); Out.String(hmmPath); Out.Ln;
    RETURN
  END;
  IF consensus THEN EmitConsensus
  ELSE FOR n := 1 TO nSeqs DO EmitSample(n) END
  END
END DoEmit;

(* ------------------------------------------------------------------ *)
(*  Build mode                                                          *)
(* ------------------------------------------------------------------ *)

PROCEDURE DoBuild(msaPath, outPath: ARRAY OF CHAR);
VAR
  rdr    : BioIO.FastaReader;
  rec    : BioIO.FastaRecord;
  alnLen : INTEGER;
  warned : BOOLEAN;
BEGIN
  IF ~BioIO.OpenFasta(rdr, msaPath) THEN
    Out.String("Error: cannot open "); Out.String(msaPath); Out.Ln;
    RETURN
  END;

  seqCount := 0; alnLen := 0; warned := FALSE;
  rec.seq := NIL;
  WHILE BioIO.ReadFasta(rdr, rec) DO
    IF seqCount >= MaxSeqs THEN
      IF ~warned THEN
        Out.String("Warning: more than "); Out.Int(MaxSeqs, 0);
        Out.String(" sequences; extras ignored."); Out.Ln;
        warned := TRUE
      END
    ELSE
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
  hmmAlph := DetectAlphabet();
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

PROCEDURE CountDbResidues(dbPath: ARRAY OF CHAR): INTEGER;
VAR rdr: BioIO.FastaReader; rec: BioIO.FastaRecord; total: INTEGER;
BEGIN
  total := 0;
  IF ~BioIO.OpenFasta(rdr, dbPath) THEN RETURN 0 END;
  rec.seq := NIL;
  WHILE BioIO.ReadFasta(rdr, rec) DO
    total := total + BioSeq.Length(rec.seq)
  END;
  BioIO.CloseFasta(rdr);
  RETURN total
END CountDbResidues;

PROCEDURE FlushBatch(wkCount, dbTotalRes: INTEGER; minBits: REAL;
                     VAR hits: INTEGER);
VAR wi: INTEGER; evalue: REAL;
BEGIN
  FOR wi := 0 TO wkCount - 1 DO
    IF wkBits[wi] >= minBits THEN
      evalue := CalcEvalue(dbTotalRes, wkBits[wi]);
      Out.String(wkNames[wi]); Out.Char(9X);
      Out.String(hmmName);     Out.Char(9X);
      Out.Fixed(wkBits[wi], 0, 2); Out.Char(9X);
      PrintEvalue(evalue);     Out.Char(9X);
      Out.Int(wkStart[wi] + 1, 0); Out.Char(9X);
      Out.Int(wkEnd[wi] + 1, 0);   Out.Char(9X);
      Out.Int(wkLen[wi], 0); Out.Ln;
      INC(hits)
    END
  END
END FlushBatch;

PROCEDURE DoSearch(hmmPath, dbPath: ARRAY OF CHAR; minBits: REAL);
(*
  Scores each database sequence against the loaded profile.
  Sequences are processed in batches of ncpu in parallel; output order
  matches the input order within each batch, and batches are sequential.
*)
VAR
  rdr        : BioIO.FastaReader;
  rec        : BioIO.FastaRecord;
  hits, wkCount, ncpu, dbTotalRes : INTEGER;
BEGIN
  IF ~ReadHMM(hmmPath) THEN
    Out.String("Error: cannot read profile from "); Out.String(hmmPath); Out.Ln;
    RETURN
  END;

  dbTotalRes := CountDbResidues(dbPath);
  IF dbTotalRes = 0 THEN
    Out.String("Error: cannot open or empty database "); Out.String(dbPath); Out.Ln;
    RETURN
  END;

  IF ~BioIO.OpenFasta(rdr, dbPath) THEN
    Out.String("Error: cannot open "); Out.String(dbPath); Out.Ln;
    RETURN
  END;

  ncpu := Parallel.NumCPU();
  IF ncpu > MaxWorkers THEN ncpu := MaxWorkers END;

  Out.String("seq_name"); Out.Char(9X);
  Out.String("model_name"); Out.Char(9X);
  Out.String("bits"); Out.Char(9X);
  Out.String("evalue"); Out.Char(9X);
  Out.String("hit_start"); Out.Char(9X);
  Out.String("hit_end"); Out.Char(9X);
  Out.String("seq_len"); Out.Ln;

  hits := 0; wkCount := 0; rec.seq := NIL;
  WHILE BioIO.ReadFasta(rdr, rec) DO
    Strings.Copy(rec.name, wkNames[wkCount]);
    wkSeqs[wkCount] := rec.seq;
    wkLen[wkCount]  := BioSeq.Length(rec.seq);
    rec.seq := NIL;
    INC(wkCount);
    IF wkCount = ncpu THEN
      Parallel.For(0, wkCount, ScoreWorker, ncpu);
      FlushBatch(wkCount, dbTotalRes, minBits, hits);
      wkCount := 0
    END
  END;
  IF wkCount > 0 THEN
    Parallel.For(0, wkCount, ScoreWorker, ncpu);
    FlushBatch(wkCount, dbTotalRes, minBits, hits)
  END;
  BioIO.CloseFasta(rdr);

  Out.String("# "); Out.Int(hits, 0);
  Out.String(" hit(s) >= "); Out.Fixed(minBits, 0, 1); Out.String(" bits"); Out.Ln
END DoSearch;

(* ------------------------------------------------------------------ *)
(*  Entry point                                                         *)
(* ------------------------------------------------------------------ *)

VAR
  mode, arg1, arg2, opt, sval, outPath : ARRAY 1024 OF CHAR;
  minBits  : REAL;
  nSeqs, jVal : INTEGER;
  consensus : BOOLEAN;
  i : INTEGER;

BEGIN
  NegInf       := -1.0E30;
  NegInfThresh := -5.0E29;

  IF Args.Count() < 2 THEN
    Out.String("Usage:"); Out.Ln;
    Out.String("  SeqHMM build  <msa.afa> <model.hmm>"); Out.Ln;
    Out.String("  SeqHMM align  <model.hmm> <seqs.fa> [-t <minBits>] [-o <out.afa>]"); Out.Ln;
    Out.String("  SeqHMM search <model.hmm> <db.fa> [-t <minBits>]"); Out.Ln;
    Out.String("  SeqHMM emit   <model.hmm> [-n <count>] [-c]"); Out.Ln;
    Out.String("Options:"); Out.Ln;
    Out.String("  -t <real>  bit-score threshold for search/align (default 10.0)"); Out.Ln;
    Out.String("  -n <int>   number of sequences to emit (default 1)"); Out.Ln;
    Out.String("  -c         emit consensus (most probable) sequence"); Out.Ln;
    Out.String("  -o <file>  output file for align (default: stdout)"); Out.Ln;
    Out.String("  -j <int>   max threads to use (default: all CPUs)"); Out.Ln;
    RETURN
  END;

  Args.Get(1, mode);
  Args.Get(2, arg1);
  IF Args.Count() >= 3 THEN Args.Get(3, arg2) ELSE arg2[0] := 0X END;

  i := 1;
  WHILE i <= Args.Count() DO
    Args.Get(i, opt);
    IF Strings.Compare(opt, "-j") = 0 THEN
      INC(i);
      IF i <= Args.Count() THEN
        Args.Get(i, sval);
        IF Strings.StrToInt(sval, jVal) & (jVal > 0) THEN
          Parallel.SetMaxCPU(jVal)
        END
      END
    END;
    INC(i)
  END;

  IF Strings.Compare(mode, "build") = 0 THEN
    DoBuild(arg1, arg2)

  ELSIF Strings.Compare(mode, "align") = 0 THEN
    minBits := 10.0; outPath[0] := 0X;
    i := 4;
    WHILE i <= Args.Count() DO
      Args.Get(i, opt);
      IF Strings.Compare(opt, "-t") = 0 THEN
        INC(i);
        IF i <= Args.Count() THEN
          Args.Get(i, sval);
          IF ~Strings.StrToReal(sval, minBits) THEN minBits := 10.0 END
        END
      ELSIF Strings.Compare(opt, "-o") = 0 THEN
        INC(i);
        IF i <= Args.Count() THEN Args.Get(i, outPath) END
      END;
      INC(i)
    END;
    DoAlign(arg1, arg2, minBits, outPath)

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

  ELSIF Strings.Compare(mode, "emit") = 0 THEN
    nSeqs := 1; consensus := FALSE;
    i := 3;
    WHILE i <= Args.Count() DO
      Args.Get(i, opt);
      IF Strings.Compare(opt, "-n") = 0 THEN
        INC(i);
        IF i <= Args.Count() THEN
          Args.Get(i, sval);
          IF ~Strings.StrToInt(sval, nSeqs) OR (nSeqs < 1) THEN nSeqs := 1 END
        END
      ELSIF Strings.Compare(opt, "-c") = 0 THEN
        consensus := TRUE
      END;
      INC(i)
    END;
    DoEmit(arg1, nSeqs, consensus)

  ELSE
    Out.String("Unknown mode: "); Out.String(mode); Out.Ln;
    Out.String("Use 'build', 'align', 'search', or 'emit'."); Out.Ln
  END
END SeqHMM.
