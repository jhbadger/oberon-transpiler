# SeqHMM — Pseudocode

Profile HMM builder and sequence-database searcher (simplified HMMER).

Two modes:
  SeqHMM build  <msa.afa> <model.hmm>   — build profile from MSA
  SeqHMM search <model.hmm> <db.fa> [-t bits]  — search FASTA, output TSV

Algorithm:
  Build:   Laplace-smoothed residue counts per column → log-odds vs background.
           Gap/non-gap patterns between adjacent columns → MM/MD/DM/DD transition
           probabilities. Insert-state transitions fixed (TMI=1%, TIM=90%, TII=10%).
  Search:  Local Viterbi in log space. Entry into any match state with logEntry =
           ln(1/L). Running max over all (j,k) gives the best local alignment score.
           Bit score = (vitScore - nullScore) / ln(2).

---

## Constants

```
CONST
  MaxLen  = 2000   (* max profile positions         *)
  MaxAlph = 20     (* max alphabet size (AA)         *)
  MaxSeqs = 256    (* max MSA sequences for build    *)
  NegInf  = -1e30  (* log-space negative infinity    *)
  Pseudo  = 1.0    (* Laplace pseudocount per residue *)

  (* Indices into logTrans[k][?] — transitions FROM profile position k *)
  TMM = 0   (* M_k  → M_{k+1} *)
  TMI = 1   (* M_k  → I_k     *)
  TMD = 2   (* M_k  → D_{k+1} *)
  TIM = 3   (* I_k  → M_{k+1} *)
  TII = 4   (* I_k  → I_k     *)
  TDM = 5   (* D_k  → M_{k+1} *)
  TDD = 6   (* D_k  → D_{k+1} *)
```

---

## Module-level storage

```
VAR
  hmmLen   : INTEGER          (* number of match columns in profile *)
  hmmAlph  : INTEGER          (* 4 = DNA, 20 = AA                   *)
  hmmName  : ARRAY 256 OF CHAR

  (* Log-odds match emissions: logEmitM[k][r] = ln(P(r|M_k)) - ln(P(r|bg)) *)
  logEmitM : ARRAY MaxLen OF ARRAY MaxAlph OF REAL
  (* Insert emissions = background (same for all positions and insert states) *)
  logEmitI : ARRAY MaxAlph OF REAL
  (* Transition log-probabilities: logTrans[k][TMM..TDD] *)
  logTrans : ARRAY MaxLen OF ARRAY 7 OF REAL
  (* Background log-probabilities logBg[r] = ln(P(r|null)) *)
  logBg    : ARRAY MaxAlph OF REAL

  (* Rolling Viterbi DP arrays (index 0..hmmLen-1) *)
  vM, vMprev : ARRAY MaxLen+2 OF REAL   (* match state scores      *)
  vI, vIprev : ARRAY MaxLen+2 OF REAL   (* insert state scores     *)
  vD         : ARRAY MaxLen+2 OF REAL   (* delete state (no emit)  *)

  seqs     : ARRAY MaxSeqs OF BioSeq.Seq
  seqCount : INTEGER

  (* Flat sequence buffer for fast access during Viterbi *)
  seqBuf   : ARRAY 100001 OF CHAR
```

---

## Alphabet utilities

```
FUNCTION ResIdx(c: CHAR): INTEGER
    (* Return 0-based residue index for hmmAlph=4 (DNA) or 20 (AA).
       Return -1 for gap characters ('-', '.') or unknowns. *)
    IF c = '-' OR c = '.' THEN RETURN -1 END
    u := CAP(c)
    IF hmmAlph = 4 THEN
        IF u = 'A' THEN RETURN 0
        ELSIF u = 'C' THEN RETURN 1
        ELSIF u = 'G' THEN RETURN 2
        ELSIF u = 'T' OR u = 'U' THEN RETURN 3
        ELSE RETURN -1
        END
    ELSE (* 20 AA in alphabetical order: ACDEFGHIKLMNPQRSTVWY *)
        IF u = 'A' THEN RETURN 0  ELSIF u = 'C' THEN RETURN 1
        ELSIF u = 'D' THEN RETURN 2  ELSIF u = 'E' THEN RETURN 3
        ELSIF u = 'F' THEN RETURN 4  ELSIF u = 'G' THEN RETURN 5
        ELSIF u = 'H' THEN RETURN 6  ELSIF u = 'I' THEN RETURN 7
        ELSIF u = 'K' THEN RETURN 8  ELSIF u = 'L' THEN RETURN 9
        ELSIF u = 'M' THEN RETURN 10 ELSIF u = 'N' THEN RETURN 11
        ELSIF u = 'P' THEN RETURN 12 ELSIF u = 'Q' THEN RETURN 13
        ELSIF u = 'R' THEN RETURN 14 ELSIF u = 'S' THEN RETURN 15
        ELSIF u = 'T' THEN RETURN 16 ELSIF u = 'V' THEN RETURN 17
        ELSIF u = 'W' THEN RETURN 18 ELSIF u = 'Y' THEN RETURN 19
        ELSE RETURN -1
        END
    END
END ResIdx

FUNCTION DetectAlph(): INTEGER
    (* Scan all loaded seqs. If any AA-exclusive residue found, return 20.
       AA-exclusive: D E F H I K L M N P Q R S V W Y *)
    FOR s := 0 TO seqCount-1 DO
        FOR i := 0 TO BioSeq.Length(seqs[s])-1 DO
            u := CAP(BioSeq.Get(seqs[s], i))
            IF u IN {'D','E','F','H','I','K','L','M','N','P','Q','R','S','V','W','Y'} THEN
                RETURN 20
            END
        END
    END
    RETURN 4
END DetectAlph

PROCEDURE SetBgFreqs
    (* Populate logBg[] and logEmitI[] = logBg[].
       DNA: uniform 0.25 each.
       AA:  SwissProt background (Krogh et al.):
            A=.073 C=.018 D=.053 E=.063 F=.040 G=.069 H=.022 I=.056
            K=.059 L=.091 M=.023 N=.046 P=.051 Q=.041 R=.052 S=.073
            T=.056 V=.064 W=.013 Y=.033                               *)
    IF hmmAlph = 4 THEN
        FOR r := 0 TO 3 DO logBg[r] := ln(0.25) END
    ELSE
        logBg[0..19] := ln(aaFreq[0..19])   (* as listed above *)
    END
    FOR r := 0 TO hmmAlph-1 DO logEmitI[r] := logBg[r] END
END SetBgFreqs
```

---

## Build — profile HMM from MSA

All sequences in `seqs[0..seqCount-1]` must have the same length `alnLen`.
Each alignment column becomes one match state (no column filtering).
Gaps within match columns represent delete states.

```
PROCEDURE BuildHMM(alnLen: INTEGER)
    (* For each column k, count residues and gap-pattern transitions.
       Transitions FROM column k TO k+1 are stored in logTrans[k]. *)

    VAR
        prevGap : ARRAY MaxSeqs OF BOOLEAN  (* gap state at previous column *)
        cnt     : ARRAY MaxAlph OF REAL
        total, nMM, nMD, nDM, nDD : REAL
        c : CHAR; curGap : BOOLEAN; r : INTEGER

    hmmLen := alnLen
    FOR s := 0 TO seqCount-1 DO prevGap[s] := TRUE END   (* sentinel *)

    FOR k := 0 TO alnLen-1 DO

        (* --- Emission counts at column k --- *)
        FOR r := 0 TO hmmAlph-1 DO cnt[r] := Pseudo END
        total := hmmAlph * Pseudo
        nMM := Pseudo;  nMD := Pseudo;  nDM := Pseudo;  nDD := Pseudo

        FOR s := 0 TO seqCount-1 DO
            c := BioSeq.Get(seqs[s], k)
            curGap := (c = '-') OR (c = '.')

            IF NOT curGap THEN
                r := ResIdx(c)
                IF r >= 0 THEN cnt[r] += 1.0;  total += 1.0 END
            END

            IF k > 0 THEN   (* count transition from column k-1 → k *)
                IF NOT prevGap[s] AND NOT curGap THEN nMM += 1.0
                ELSIF NOT prevGap[s] AND curGap     THEN nMD += 1.0
                ELSIF prevGap[s]     AND NOT curGap THEN nDM += 1.0
                ELSE                                     nDD += 1.0
                END
            END
            prevGap[s] := curGap
        END

        (* --- Log-odds match emissions --- *)
        FOR r := 0 TO hmmAlph-1 DO
            logEmitM[k][r] := ln(cnt[r] / total) - logBg[r]
        END

        (* --- Transition probabilities stored at logTrans[k-1] --- *)
        (* Transitions from position k-1 → k, computed once we've seen column k *)
        IF k > 0 THEN
            p := nMM + nMD   (* denominator for M-originating transitions *)
            q := nDM + nDD   (* denominator for D-originating transitions *)
            logTrans[k-1][TMM] := ln(nMM / p * 0.99)   (* 99% budget after reserving TMI *)
            logTrans[k-1][TMD] := ln(nMD / p * 0.99)
            logTrans[k-1][TMI] := ln(0.01)              (* fixed 1% insert probability    *)
            logTrans[k-1][TIM] := ln(0.90)
            logTrans[k-1][TII] := ln(0.10)
            logTrans[k-1][TDM] := ln(nDM / q)
            logTrans[k-1][TDD] := ln(nDD / q)
        END
    END

    (* Transitions at the last column (no successor match state) — set to safe defaults *)
    last := alnLen - 1
    logTrans[last][TMM] := ln(0.99);  logTrans[last][TMI] := ln(0.01)
    logTrans[last][TMD] := NegInf
    logTrans[last][TIM] := ln(0.90);  logTrans[last][TII] := ln(0.10)
    logTrans[last][TDM] := ln(1.0);   logTrans[last][TDD] := NegInf
END BuildHMM
```

---

## HMM file I/O (binary)

Format (all values written in C native binary):
```
4 bytes  WriteInt  hmmLen
4 bytes  WriteInt  hmmAlph
n bytes  WriteString hmmName (null-terminated)
8*alph   WriteReal  logBg[0..alph-1]
8*L*alph WriteReal  logEmitM[0..L-1][0..alph-1]  (row-major)
8*alph   WriteReal  logEmitI[0..alph-1]
8*L*7    WriteReal  logTrans[0..L-1][0..6]
```

ReadHMM validates: 1 <= hmmLen <= MaxLen, hmmAlph IN {4, 20}.

```
PROCEDURE WriteHMM(path: ARRAY OF CHAR): BOOLEAN
    f := Files.New(path);  Files.Set(r, f, 0)
    Files.WriteInt(r, hmmLen);  Files.WriteInt(r, hmmAlph)
    Files.WriteString(r, hmmName)
    FOR a := 0 TO hmmAlph-1 DO Files.WriteReal(r, logBg[a]) END
    FOR k := 0 TO hmmLen-1 DO
        FOR a := 0 TO hmmAlph-1 DO Files.WriteReal(r, logEmitM[k][a]) END
    END
    FOR a := 0 TO hmmAlph-1 DO Files.WriteReal(r, logEmitI[a]) END
    FOR k := 0 TO hmmLen-1 DO
        FOR t := 0 TO 6 DO Files.WriteReal(r, logTrans[k][t]) END
    END
    Files.Close(f);  RETURN TRUE
END WriteHMM

PROCEDURE ReadHMM(path: ARRAY OF CHAR): BOOLEAN
    f := Files.Old(path);  Files.Set(r, f, 0)
    Files.ReadInt(r, hmmLen);  Files.ReadInt(r, hmmAlph)
    IF hmmLen < 1 OR hmmLen > MaxLen OR (hmmAlph # 4 AND hmmAlph # 20) THEN
        Files.Close(f);  RETURN FALSE
    END
    Files.ReadString(r, hmmName)
    FOR a := 0 TO hmmAlph-1 DO Files.ReadReal(r, logBg[a]) END
    FOR k := 0 TO hmmLen-1 DO
        FOR a := 0 TO hmmAlph-1 DO Files.ReadReal(r, logEmitM[k][a]) END
    END
    FOR a := 0 TO hmmAlph-1 DO Files.ReadReal(r, logEmitI[a]) END
    FOR k := 0 TO hmmLen-1 DO
        FOR t := 0 TO 6 DO Files.ReadReal(r, logTrans[k][t]) END
    END
    Files.Close(f);  RETURN TRUE
END ReadHMM
```

---

## Viterbi — local alignment

Profile states: match M_k, insert I_k, delete D_k (k = 0..L-1, 0-indexed).
DP uses rolling arrays (only previous-j row kept); delete states computed
left-to-right within each j step (no residue consumed, safe to update in place).

Local alignment: entry into any M_k at any residue j with cost logEntry = ln(1/L).
Exit from any M_k to END with cost 0 (tracked as running maximum bestScore).

Null model score: sum of logBg[ri] for every non-gap residue in the sequence.
Bit score: (bestScore - nullScore) / ln(2).

```
FUNCTION Viterbi(seq: BioSeq.Seq): REAL
    T := BioSeq.Length(seq)
    IF T = 0 OR hmmLen = 0 THEN RETURN NegInf END

    (* Cache sequence into flat buffer for O(1) access *)
    BioSeq.Slice(seq, 0, MIN(T, 100000), seqBuf)
    IF T > 100000 THEN T := 100000 END

    logEntry := ln(1.0 / hmmLen)

    (* Initialise all DP cells to NegInf *)
    FOR k := 0 TO hmmLen+1 DO
        vMprev[k] := NegInf;  vIprev[k] := NegInf;  vD[k] := NegInf
    END
    bestScore := NegInf;  nullScore := 0.0

    FOR j := 0 TO T-1 DO
        c  := seqBuf[j]
        ri := ResIdx(c)
        IF ri >= 0 THEN nullScore += logBg[ri] END

        vD[0] := NegInf

        FOR k := 0 TO hmmLen-1 DO

            (* Delete state D_k: no residue consumed.
               Transition indices into logTrans[k-1]: TMD, TDD.
               Transition FROM position k-1, so index k-1 in 0-based array. *)
            IF k = 0 THEN
                vD[k] := NegInf
            ELSE
                vD[k] := MAX(vMprev[k-1] + logTrans[k-1][TMD],
                              vD[k-1]     + logTrans[k-1][TDD])
            END

            (* Match state M_k: emit seqBuf[j].
               Entered from M_{k-1}, I_{k-1}, D_{k-1} (prev j), or fresh local start. *)
            IF k = 0 THEN
                best := logEntry   (* only local entry possible at k=0 *)
            ELSE
                best := MAX3(vMprev[k-1] + logTrans[k-1][TMM],
                             vIprev[k-1] + logTrans[k-1][TIM],
                             vD[k-1]     + logTrans[k-1][TDM])
                best := MAX(best, logEntry)   (* allow local re-entry anywhere *)
            END
            IF ri >= 0 THEN vM[k] := logEmitM[k][ri] + best
            ELSE vM[k] := NegInf   (* unknown residue — no match *)
            END

            (* Insert state I_k: emit seqBuf[j] with background probability.
               Entered from M_k or I_k at same profile position, previous j. *)
            IF ri >= 0 THEN
                vI[k] := logEmitI[ri] + MAX(vMprev[k] + logTrans[k][TMI],
                                             vIprev[k] + logTrans[k][TII])
            ELSE
                vI[k] := NegInf
            END

            (* Local exit: record best match score seen at any (j, k) *)
            IF vM[k] > bestScore THEN bestScore := vM[k] END
        END

        (* Roll DP: current row becomes previous for next j *)
        FOR k := 0 TO hmmLen-1 DO
            vMprev[k] := vM[k];  vIprev[k] := vI[k]
        END
    END

    IF bestScore > NegInf / 2.0 THEN
        RETURN (bestScore - nullScore) / ln(2.0)
    ELSE
        RETURN NegInf
    END
END Viterbi
```

---

## Build mode

```
PROCEDURE DoBuild(msaPath, outPath: ARRAY OF CHAR)
    rdr := BioIO.OpenFasta(msaPath)
    seqCount := 0;  alnLen := 0
    WHILE BioIO.ReadFasta(rdr, rec) DO
        IF seqCount < MaxSeqs THEN
            seqs[seqCount] := rec.seq;  INC(seqCount)
            L := BioSeq.Length(rec.seq)
            IF seqCount = 1 THEN alnLen := L END
            (* All seqs should be the same length in an MSA; warn if not *)
        END
    END
    BioIO.CloseFasta(rdr)

    IF seqCount = 0 THEN error "Empty MSA" END
    IF alnLen > MaxLen THEN alnLen := MaxLen;  warn "Alignment truncated" END

    (* Extract model name from MSA filename basename, strip extension *)
    BaseName(msaPath, hmmName)

    hmmAlph := DetectAlph()
    SetBgFreqs
    BuildHMM(alnLen)

    IF WriteHMM(outPath) THEN
        Out.String("Built profile: ")
        Out.Int(hmmLen, 0); Out.String(" positions, ")
        Out.Int(hmmAlph, 0); Out.String(" residue alphabet")
        Out.String(" from "); Out.Int(seqCount, 0); Out.String(" sequences")
    END
END DoBuild
```

---

## Search mode

```
PROCEDURE DoSearch(hmmPath, dbPath: ARRAY OF CHAR; minBits: REAL)
    IF NOT ReadHMM(hmmPath) THEN error "Cannot read HMM" END

    Out.String("seq_name"); Out.Char(TAB)
    Out.String("model_name"); Out.Char(TAB)
    Out.String("bits"); Out.Char(TAB)
    Out.String("seq_len"); Out.Ln

    rdr := BioIO.OpenFasta(dbPath)
    WHILE BioIO.ReadFasta(rdr, rec) DO
        bits := Viterbi(rec.seq)
        IF bits >= minBits THEN
            Out.String(rec.name); Out.Char(TAB)
            Out.String(hmmName);  Out.Char(TAB)
            Out.Fixed(bits, 0, 1); Out.Char(TAB)
            Out.Int(BioSeq.Length(rec.seq), 0); Out.Ln
        END
    END
    BioIO.CloseFasta(rdr)
END DoSearch
```

---

## Entry point

```
BEGIN
    IF Args.Count() < 3 THEN
        Out.String("Usage:"); Out.Ln
        Out.String("  SeqHMM build  <msa.afa> <model.hmm>"); Out.Ln
        Out.String("  SeqHMM search <model.hmm> <db.fa> [-t <minBits>]"); Out.Ln
        RETURN
    END

    Args.Get(1, mode)     (* "build" or "search" *)
    Args.Get(2, arg1)     (* msa.afa  or model.hmm *)
    Args.Get(3, arg2)     (* model.hmm or db.fa    *)

    IF mode = "build" THEN
        DoBuild(arg1, arg2)

    ELSIF mode = "search" THEN
        minBits := 10.0   (* default threshold *)
        i := 4
        WHILE i <= Args.Count() DO
            Args.Get(i, opt)
            IF opt = "-t" THEN INC(i); Args.Get(i, s); Strings.StrToReal(s, minBits) END
            INC(i)
        END
        DoSearch(arg1, arg2, minBits)

    ELSE
        Out.String("Unknown mode: "); Out.String(mode); Out.Ln
    END
END SeqHMM.
```

---

## Algorithm notes

### Transition layout

logTrans[k] holds transitions **from** profile position k (0-indexed):

| Index | Symbol | Meaning                        |
|-------|--------|--------------------------------|
| 0 TMM | M→M    | match k → match k+1           |
| 1 TMI | M→I    | match k → insert k (stay)     |
| 2 TMD | M→D    | match k → delete k+1          |
| 3 TIM | I→M    | insert k → match k+1          |
| 4 TII | I→I    | insert k → insert k (extend)  |
| 5 TDM | D→M    | delete k → match k+1          |
| 6 TDD | D→D    | delete k → delete k+1         |

TMM + TMI + TMD = 1; TIM + TII = 1; TDM + TDD = 1 (in probability space).
Insert probabilities are fixed (TMI=0.01, TIM=0.90, TII=0.10).
MM and MD are estimated from the MSA gap pattern with Laplace pseudocounts,
then scaled to the remaining 99% budget: each × 0.99.

### Scoring summary

| Quantity | Formula |
|----------|---------|
| Match emission logEmitM[k][r] | ln(cnt[r]/total) − logBg[r] |
| Insert emission logEmitI[r]   | logBg[r]  (background = null) |
| Local entry cost logEntry     | ln(1/L)                        |
| Null score                    | Σ logBg[ri] over all residues  |
| Bit score                     | (vitScore − nullScore) / ln(2) |

### Complexity

Build: O(N × L) where N = sequence count, L = alignment length.
Search: O(T × L) per sequence where T = sequence length.
Memory: model arrays ≈ L × (20 + 7) × 8 bytes; DP rolling arrays ≈ 5 × L × 8 bytes.
