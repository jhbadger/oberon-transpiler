MODULE BioORF;
(*
  BioORF — Open reading frame detection and translation.

  CodonToAA:    O(1) lookup via T=0/C=1/A=2/G=3 base encoding.
  FindForward:  Scans frames 0,1,2 of the forward strand.
  FindAll:      Forward frames + 3 reverse-complement frames.
                Reverse-strand ORF coordinates are reported in the
                original sequence's coordinate space.
  Translate:    Translates a whole frame, inserting '*' for stop codons.
  PrintORFs:    Summary table to stdout.

  Genetic codes (module-global, switched with UseStdCode / UseMitoCode):
    Standard (NCBI table 1):  default on module initialisation.
    Vertebrate mito (NCBI table 2): TGA → Trp, ATA → Met, AGA/AGG → Stop.
  Handles RNA (U treated identically to T).

  NOTE: ORFList (~96 KB) should be declared at module level, not locally.
  NOTE: module-level rcSeq scratch is not re-entrant across concurrent calls.
  NOTE: UseStdCode / UseMitoCode affect all subsequent calls in the same thread.
*)

IMPORT BioSeq, BioAlpha, Out;

CONST
  MaxORFs*     = 4096;
  CodonStr     = "FFLLSSSSYY**CC*WLLLLPPPPHHQQRRRRIIIMTTTTNNKKSSRRVVVVAAAADDEEGGGG";
  MitoCodonStr = "FFLLSSSSYY**CCWWLLLLPPPPHHQQRRRRIIMMTTTTNNKKSS**VVVVAAAADDEEGGGG";

TYPE
  ORF* = RECORD
    frame* : INTEGER;   (* 0,1,2 forward; -1,-2,-3 reverse complement *)
    start* : INTEGER;   (* 0-based start of ATG in original sequence   *)
    end_*  : INTEGER;   (* 0-based position just past stop codon       *)
    len*   : INTEGER;   (* nucleotide length: end_ - start             *)
    aa*    : BioSeq.Seq (* translated amino acids, stop codon omitted  *)
  END;

  ORFList* = RECORD
    orfs*  : ARRAY MaxORFs OF ORF;
    count* : INTEGER
  END;

VAR
  codonTable : ARRAY 65  OF CHAR;   (* indexed by T/C/A/G → 0/1/2/3 *)
  rcSeq      : BioSeq.Seq;          (* module-level RevComp scratch   *)
  dnaAlpha   : BioAlpha.Alphabet;   (* DNA alphabet for RevComp       *)

(* ------------------------------------------------------------------ *)
(*  Genetic code selection                                              *)
(* ------------------------------------------------------------------ *)

PROCEDURE UseStdCode*;
(* Switch to the standard genetic code (NCBI table 1). Default. *)
BEGIN
  COPY(CodonStr, codonTable)
END UseStdCode;

PROCEDURE UseMitoCode*;
(*
  Switch to the vertebrate mitochondrial genetic code (NCBI table 2).
  Differences from standard:
    TGA (pos 14) : Stop → Trp
    ATA (pos 34) : Ile  → Met
    AGA (pos 46) : Arg  → Stop
    AGG (pos 47) : Arg  → Stop
*)
BEGIN
  COPY(MitoCodonStr, codonTable)
END UseMitoCode;

(* ------------------------------------------------------------------ *)
(*  CodonToAA                                                           *)
(* ------------------------------------------------------------------ *)

PROCEDURE CodonToAA*(codon: ARRAY OF CHAR): CHAR;
(* Return single-letter amino-acid code for a DNA or RNA triplet.
   Unknown/ambiguous bases → '?'.  Stop codons → '*'. *)
VAR b1, b2, b3 : INTEGER;
BEGIN
  b1 := 0; b2 := 0; b3 := 0;
  CASE codon[0] OF
    'T','U': b1 := 0 | 'C': b1 := 1 | 'A': b1 := 2 | 'G': b1 := 3
  ELSE RETURN '?'
  END;
  CASE codon[1] OF
    'T','U': b2 := 0 | 'C': b2 := 1 | 'A': b2 := 2 | 'G': b2 := 3
  ELSE RETURN '?'
  END;
  CASE codon[2] OF
    'T','U': b3 := 0 | 'C': b3 := 1 | 'A': b3 := 2 | 'G': b3 := 3
  ELSE RETURN '?'
  END;
  RETURN codonTable[b1 * 16 + b2 * 4 + b3]
END CodonToAA;

(* ------------------------------------------------------------------ *)
(*  Private helpers                                                     *)
(* ------------------------------------------------------------------ *)

PROCEDURE FreeList(VAR result: ORFList);
(* Free all aa sequences in result and reset count to 0. *)
VAR i : INTEGER;
BEGIN
  FOR i := 0 TO result.count - 1 DO
    BioSeq.Free(result.orfs[i].aa)   (* safe if already NIL *)
  END;
  result.count := 0
END FreeList;

PROCEDURE TranslateRange(s: BioSeq.Seq; orfStart, orfEnd: INTEGER;
                         dst: BioSeq.Seq);
(* Translate codons s[orfStart .. orfEnd-4) into dst (stop codon excluded). *)
VAR
  pos, bufLen : INTEGER;
  codon       : ARRAY 4   OF CHAR;
  buf         : ARRAY 240 OF CHAR;
BEGIN
  pos    := orfStart;
  bufLen := 0;
  WHILE pos < orfEnd - 3 DO
    codon[0] := BioSeq.Get(s, pos);
    codon[1] := BioSeq.Get(s, pos + 1);
    codon[2] := BioSeq.Get(s, pos + 2);
    codon[3] := 0X;
    buf[bufLen] := CodonToAA(codon);
    INC(bufLen);
    IF bufLen = 240 THEN
      BioSeq.Append(dst, buf, bufLen);
      bufLen := 0
    END;
    INC(pos, 3)
  END;
  IF bufLen > 0 THEN BioSeq.Append(dst, buf, bufLen) END
END TranslateRange;

PROCEDURE ScanFrames(s: BioSeq.Seq; minLen: INTEGER; VAR result: ORFList);
(*
  Scan all 3 forward frames of s, appending found ORFs to result.
  Does NOT clear result first — callers must do that.
  The frame field in appended ORFs is set to 0, 1, or 2; callers
  adjust for reverse-strand ORFs.
*)
VAR
  f, pos, inner, orfStart, orfEnd, orfLen, seqLen : INTEGER;
  c0, c1, c2, aa                                   : CHAR;
  codon                                             : ARRAY 4 OF CHAR;
  stopFound                                         : BOOLEAN;
BEGIN
  seqLen := BioSeq.Length(s);
  FOR f := 0 TO 2 DO
    pos := f;
    WHILE pos + 3 <= seqLen DO
      c0 := BioSeq.Get(s, pos);
      c1 := BioSeq.Get(s, pos + 1);
      c2 := BioSeq.Get(s, pos + 2);
      IF (c0 = 'A') & (c1 = 'T') & (c2 = 'G') THEN
        orfStart  := pos;
        inner     := pos + 3;
        stopFound := FALSE;
        WHILE (inner + 3 <= seqLen) & ~stopFound DO
          codon[0] := BioSeq.Get(s, inner);
          codon[1] := BioSeq.Get(s, inner + 1);
          codon[2] := BioSeq.Get(s, inner + 2);
          codon[3] := 0X;
          aa := CodonToAA(codon);
          IF aa = '*' THEN
            stopFound := TRUE;
            orfEnd  := inner + 3;
            orfLen  := orfEnd - orfStart;
            IF (orfLen >= minLen) & (result.count < MaxORFs) THEN
              result.orfs[result.count].frame := f;
              result.orfs[result.count].start := orfStart;
              result.orfs[result.count].end_  := orfEnd;
              result.orfs[result.count].len   := orfLen;
              BioSeq.New(result.orfs[result.count].aa);
              TranslateRange(s, orfStart, orfEnd,
                             result.orfs[result.count].aa);
              INC(result.count)
            END
          ELSE
            INC(inner, 3)
          END
        END
      END;
      INC(pos, 3)
    END
  END
END ScanFrames;

(* ------------------------------------------------------------------ *)
(*  FindForward / FindAll                                               *)
(* ------------------------------------------------------------------ *)

PROCEDURE FindForward*(seq: BioSeq.Seq; minLen: INTEGER;
                       VAR result: ORFList);
(* Find all complete ORFs in the 3 forward frames of seq. *)
BEGIN
  FreeList(result);
  ScanFrames(seq, minLen, result)
END FindForward;

PROCEDURE FindAll*(seq: BioSeq.Seq; minLen: INTEGER; VAR result: ORFList);
(*
  Find all complete ORFs in all 6 reading frames.
  Reverse-strand ORFs use frame -1/-2/-3; their start/end_ are
  coordinates in the original (forward) sequence.
*)
VAR
  seqLen, savedCount, i, rs, re : INTEGER;
BEGIN
  FreeList(result);
  ScanFrames(seq, minLen, result);

  BioSeq.RevComp(seq, dnaAlpha, rcSeq);
  seqLen     := BioSeq.Length(seq);
  savedCount := result.count;
  ScanFrames(rcSeq, minLen, result);

  (* Convert revcomp coordinates to original-sequence coordinates
     and negate the frame to mark these as reverse-strand ORFs. *)
  FOR i := savedCount TO result.count - 1 DO
    rs := result.orfs[i].start;
    re := result.orfs[i].end_;
    result.orfs[i].start := seqLen - re;
    result.orfs[i].end_  := seqLen - rs;
    result.orfs[i].frame := -(result.orfs[i].frame + 1)
  END
END FindAll;

(* ------------------------------------------------------------------ *)
(*  Translate                                                           *)
(* ------------------------------------------------------------------ *)

PROCEDURE Translate*(seq: BioSeq.Seq; frame: INTEGER; VAR aa: BioSeq.Seq);
(*
  Translate the entire sequence in the given reading frame.
  frame 0,1,2:   forward, starting at the given offset.
  frame -1,-2,-3: reverse complement, offset 0,1,2 into the RevComp.
  Stop codons are included as '*'.  aa is allocated (or replaced) here.
*)
VAR
  s      : BioSeq.Seq;
  offset : INTEGER;
  pos, n, bufLen : INTEGER;
  codon  : ARRAY 4   OF CHAR;
  buf    : ARRAY 240 OF CHAR;
BEGIN
  BioSeq.Free(aa);
  BioSeq.New(aa);
  IF frame >= 0 THEN
    s      := seq;
    offset := frame
  ELSE
    BioSeq.RevComp(seq, dnaAlpha, rcSeq);
    s      := rcSeq;
    offset := (-frame) - 1   (* -1→0, -2→1, -3→2 *)
  END;
  n      := BioSeq.Length(s);
  pos    := offset;
  bufLen := 0;
  WHILE pos + 3 <= n DO
    codon[0] := BioSeq.Get(s, pos);
    codon[1] := BioSeq.Get(s, pos + 1);
    codon[2] := BioSeq.Get(s, pos + 2);
    codon[3] := 0X;
    buf[bufLen] := CodonToAA(codon);
    INC(bufLen);
    IF bufLen = 240 THEN
      BioSeq.Append(aa, buf, bufLen);
      bufLen := 0
    END;
    INC(pos, 3)
  END;
  IF bufLen > 0 THEN BioSeq.Append(aa, buf, bufLen) END
END Translate;

(* ------------------------------------------------------------------ *)
(*  PrintORFs                                                           *)
(* ------------------------------------------------------------------ *)

PROCEDURE PrintORFs*(VAR result: ORFList);
(*
  Print a summary table of all ORFs to stdout.
  Columns: index, frame, start, end, length (nt), length (aa), sequence.
*)
VAR
  i, n, j : INTEGER;
  c       : CHAR;
BEGIN
  Out.String("  #  frame  start    end     nt    aa  sequence"); Out.Ln();
  FOR i := 0 TO result.count - 1 DO
    Out.Int(i);
    IF i < 10 THEN Out.String("    ") ELSIF i < 100 THEN Out.String("   ") ELSE Out.String("  ") END;
    Out.Int(result.orfs[i].frame);
    IF result.orfs[i].frame >= 0 THEN Out.String("      ") ELSE Out.String("     ") END;
    Out.Int(result.orfs[i].start);  Out.String("  ");
    Out.Int(result.orfs[i].end_);   Out.String("  ");
    Out.Int(result.orfs[i].len);    Out.String("  ");
    n := BioSeq.Length(result.orfs[i].aa);
    Out.Int(n); Out.String("  ");
    j := 0;
    WHILE (j < n) & (j < 40) DO
      c := BioSeq.Get(result.orfs[i].aa, j);
      Out.Char(c);
      INC(j)
    END;
    IF n > 40 THEN Out.String("...") END;
    Out.Ln()
  END
END PrintORFs;

BEGIN
  COPY(CodonStr, codonTable);
  BioSeq.New(rcSeq);
  BioAlpha.DNA(dnaAlpha)
END BioORF.
