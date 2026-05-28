# BioAlign — Pseudocode

Pairwise alignment: Needleman-Wunsch (global), Smith-Waterman (local),
semi-global, edit distance, and Hamming distance.

All DP matrices are flat arrays indexed as `i*(MaxSeqLen+1)+j` to stay within
Oberon's static-array model. Pseudocode uses `M[i,j]` notation for clarity.

---

## Constants and Types

```oberon
CONST
  MaxSeqLen = 4096;
  MaxCigar  = 8192;

  (* OpKind values *)
  opMatch = 0;   (* aligned, same character   *)
  opSubst = 3;   (* aligned, different char   *)
  opIns   = 1;   (* gap in reference (query longer) *)
  opDel   = 2;   (* gap in query (ref longer)       *)

  NEG_INF = -1000000;   (* sentinel for unreachable DP cells *)

TYPE
  ScoreMatrix = RECORD
    match_   : INTEGER;   (* reward for identical characters  *)
    mismatch : INTEGER;   (* penalty for substitution         *)
    gapOpen  : INTEGER;   (* affine gap: cost to open a gap   *)
    gapExt   : INTEGER    (* affine gap: cost per extra base   *)
  END;

  CigarEntry = RECORD
    op  : INTEGER;   (* opMatch / opSubst / opIns / opDel *)
    len : INTEGER
  END;

  Alignment = RECORD
    score    : INTEGER;
    qStart, qEnd : INTEGER;   (* 0-based, half-open in query     *)
    rStart, rEnd : INTEGER;   (* 0-based, half-open in reference *)
    cigar    : ARRAY MaxCigar OF CigarEntry;
    nOps     : INTEGER;
    identity : REAL           (* matched positions / aligned length *)
  END;
```

---

## DefaultScore

```
PROCEDURE DefaultScore(VAR m: ScoreMatrix)
    m.match_   :=  1
    m.mismatch := -1
    m.gapOpen  := -5
    m.gapExt   := -1
END
```

---

## Internal helpers

```
(* Score for aligning character a against character b *)
FUNCTION PairScore(m: ScoreMatrix; a, b: CHAR): INTEGER
    IF a = b THEN RETURN m.match_ ELSE RETURN m.mismatch END
END

(* Append or extend the last CIGAR entry *)
PROCEDURE AppendCigar(VAR aln: Alignment; op: INTEGER)
    IF (aln.nOps > 0) AND (aln.cigar[aln.nOps-1].op = op) THEN
        INC(aln.cigar[aln.nOps-1].len)
    ELSE
        aln.cigar[aln.nOps].op  := op
        aln.cigar[aln.nOps].len := 1
        INC(aln.nOps)
    END
END

(* Reverse the cigar array in place (built back-to-front during traceback) *)
PROCEDURE ReverseCigar(VAR aln: Alignment)
    VAR lo, hi: INTEGER; tmp: CigarEntry
    lo := 0;  hi := aln.nOps - 1
    WHILE lo < hi DO
        tmp           := aln.cigar[lo]
        aln.cigar[lo] := aln.cigar[hi]
        aln.cigar[hi] := tmp
        INC(lo);  DEC(hi)
    END
END

(* Compute identity from a filled Alignment *)
PROCEDURE CalcIdentity(VAR aln: Alignment; q, r: BioSeq.Seq)
    VAR matches, aligned, k, p, qi, ri: INTEGER
    matches := 0;  aligned := 0
    qi := aln.qStart;  ri := aln.rStart
    FOR k := 0 TO aln.nOps-1 DO
        FOR p := 0 TO aln.cigar[k].len-1 DO
            IF aln.cigar[k].op = opMatch THEN
                INC(matches);  INC(aligned);  INC(qi);  INC(ri)
            ELSIF aln.cigar[k].op = opSubst THEN
                INC(aligned);  INC(qi);  INC(ri)
            ELSIF aln.cigar[k].op = opIns THEN
                INC(aligned);  INC(qi)
            ELSE (* opDel *)
                INC(aligned);  INC(ri)
            END
        END
    END
    IF aligned > 0 THEN
        aln.identity := FLT(matches) / FLT(aligned)
    ELSE
        aln.identity := 0.0
    END
END
```

---

## Global — Needleman-Wunsch with affine gaps

Three DP layers (M = aligned, X = gap-in-ref, Y = gap-in-query) stored as
flat arrays of size `(qLen+1) * (rLen+1)`.

```
PROCEDURE Global(q, r: BioSeq.Seq; VAR m: ScoreMatrix; VAR aln: Alignment)

    VAR
        qLen, rLen : INTEGER
        (* DP matrices — flat, row-major *)
        M, X, Y    : ARRAY (MaxSeqLen+1)*(MaxSeqLen+1) OF INTEGER
        (* traceback: which of M/X/Y was chosen at each cell, for each layer *)
        tbM, tbX, tbY : ARRAY (MaxSeqLen+1)*(MaxSeqLen+1) OF INTEGER
        i, j, best, s : INTEGER
        layer, qi, ri  : INTEGER

    qLen := BioSeq.Length(q)
    rLen := BioSeq.Length(r)
    ASSERT(qLen <= MaxSeqLen)
    ASSERT(rLen <= MaxSeqLen)

    (* ── Initialisation ── *)
    M[0,0] := 0;  X[0,0] := NEG_INF;  Y[0,0] := NEG_INF

    (* First column: gaps in reference *)
    FOR i := 1 TO qLen DO
        M[i,0] := NEG_INF
        X[i,0] := m.gapOpen + i * m.gapExt
        Y[i,0] := NEG_INF
    END

    (* First row: gaps in query *)
    FOR j := 1 TO rLen DO
        M[0,j] := NEG_INF
        X[0,j] := NEG_INF
        Y[0,j] := m.gapOpen + j * m.gapExt
    END

    (* ── Fill ── *)
    FOR i := 1 TO qLen DO
        FOR j := 1 TO rLen DO
            s := PairScore(m, BioSeq.Get(q, i-1), BioSeq.Get(r, j-1))

            (* M[i,j]: align q[i-1] with r[j-1] *)
            best := M[i-1,j-1];  tbM[i,j] := 0   (* came from M *)
            IF X[i-1,j-1] > best THEN best := X[i-1,j-1];  tbM[i,j] := 1 END
            IF Y[i-1,j-1] > best THEN best := Y[i-1,j-1];  tbM[i,j] := 2 END
            M[i,j] := best + s

            (* X[i,j]: gap in reference (insert into query) *)
            IF M[i-1,j] + m.gapOpen >= X[i-1,j] + m.gapExt THEN
                X[i,j] := M[i-1,j] + m.gapOpen;  tbX[i,j] := 0
            ELSE
                X[i,j] := X[i-1,j] + m.gapExt;   tbX[i,j] := 1
            END

            (* Y[i,j]: gap in query (delete from query) *)
            IF M[i,j-1] + m.gapOpen >= Y[i,j-1] + m.gapExt THEN
                Y[i,j] := M[i,j-1] + m.gapOpen;  tbY[i,j] := 0
            ELSE
                Y[i,j] := Y[i,j-1] + m.gapExt;   tbY[i,j] := 2
            END
        END
    END

    (* ── Pick best terminal score ── *)
    aln.score := M[qLen,rLen];  layer := 0   (* 0=M, 1=X, 2=Y *)
    IF X[qLen,rLen] > aln.score THEN aln.score := X[qLen,rLen];  layer := 1 END
    IF Y[qLen,rLen] > aln.score THEN aln.score := Y[qLen,rLen];  layer := 2 END

    aln.qEnd := qLen;  aln.rEnd := rLen
    aln.qStart := 0;   aln.rStart := 0
    aln.nOps := 0

    (* ── Traceback ── *)
    i := qLen;  j := rLen
    WHILE (i > 0) OR (j > 0) DO
        IF layer = 0 THEN           (* in M: characters were aligned *)
            IF BioSeq.Get(q,i-1) = BioSeq.Get(r,j-1) THEN
                AppendCigar(aln, opMatch)
            ELSE
                AppendCigar(aln, opSubst)
            END
            layer := tbM[i,j];  DEC(i);  DEC(j)
        ELSIF layer = 1 THEN        (* in X: gap in reference *)
            AppendCigar(aln, opIns)
            layer := tbX[i,j];  DEC(i)
        ELSE                        (* in Y: gap in query *)
            AppendCigar(aln, opDel)
            layer := tbY[i,j];  DEC(j)
        END
    END

    ReverseCigar(aln)
    CalcIdentity(aln, q, r)
END Global
```

---

## Local — Smith-Waterman with affine gaps

Same three-layer recurrence but cells are floored at 0, and traceback starts
from the cell with the highest score rather than the corner.

```
PROCEDURE Local(q, r: BioSeq.Seq; VAR m: ScoreMatrix; VAR aln: Alignment)

    VAR
        qLen, rLen      : INTEGER
        M, X, Y         : ARRAY (MaxSeqLen+1)*(MaxSeqLen+1) OF INTEGER
        tbM, tbX, tbY   : ARRAY (MaxSeqLen+1)*(MaxSeqLen+1) OF INTEGER
        i, j, best, s   : INTEGER
        bestI, bestJ     : INTEGER
        layer            : INTEGER

    qLen := BioSeq.Length(q)
    rLen := BioSeq.Length(r)
    ASSERT(qLen <= MaxSeqLen)
    ASSERT(rLen <= MaxSeqLen)

    (* ── Initialisation: all zeros (local alignment can start anywhere) ── *)
    FOR i := 0 TO qLen DO
        M[i,0] := 0;  X[i,0] := 0;  Y[i,0] := 0
    END
    FOR j := 0 TO rLen DO
        M[0,j] := 0;  X[0,j] := 0;  Y[0,j] := 0
    END

    aln.score := 0;  bestI := 0;  bestJ := 0

    (* ── Fill ── *)
    FOR i := 1 TO qLen DO
        FOR j := 1 TO rLen DO
            s := PairScore(m, BioSeq.Get(q, i-1), BioSeq.Get(r, j-1))

            (* M layer *)
            best := M[i-1,j-1];  tbM[i,j] := 0
            IF X[i-1,j-1] > best THEN best := X[i-1,j-1];  tbM[i,j] := 1 END
            IF Y[i-1,j-1] > best THEN best := Y[i-1,j-1];  tbM[i,j] := 2 END
            M[i,j] := MAX(0, best + s)
            IF M[i,j] = 0 THEN tbM[i,j] := -1 END   (* -1 = local start *)

            (* X layer: gap in reference *)
            IF M[i-1,j] + m.gapOpen >= X[i-1,j] + m.gapExt THEN
                X[i,j] := MAX(0, M[i-1,j] + m.gapOpen);  tbX[i,j] := 0
            ELSE
                X[i,j] := MAX(0, X[i-1,j] + m.gapExt);   tbX[i,j] := 1
            END

            (* Y layer: gap in query *)
            IF M[i,j-1] + m.gapOpen >= Y[i,j-1] + m.gapExt THEN
                Y[i,j] := MAX(0, M[i,j-1] + m.gapOpen);  tbY[i,j] := 0
            ELSE
                Y[i,j] := MAX(0, Y[i,j-1] + m.gapExt);   tbY[i,j] := 2
            END

            (* Track global best for local alignment *)
            IF M[i,j] > aln.score THEN
                aln.score := M[i,j];  bestI := i;  bestJ := j
            END
        END
    END

    aln.qEnd := bestI;  aln.rEnd := bestJ
    aln.nOps := 0;  layer := 0

    (* ── Traceback from best cell, stop at 0 or border ── *)
    i := bestI;  j := bestJ
    WHILE (i > 0) AND (j > 0) AND
          (M[i,j] > 0) OR (X[i,j] > 0) OR (Y[i,j] > 0) DO
        IF layer = 0 THEN
            IF tbM[i,j] = -1 THEN (* reached local-start cell *)
                (* consume the aligned pair then stop *)
                IF BioSeq.Get(q,i-1) = BioSeq.Get(r,j-1) THEN
                    AppendCigar(aln, opMatch)
                ELSE
                    AppendCigar(aln, opSubst)
                END
                DEC(i);  DEC(j);
                (* exit loop — this was the local alignment start *)
                i := 0;  j := 0
            ELSE
                IF BioSeq.Get(q,i-1) = BioSeq.Get(r,j-1) THEN
                    AppendCigar(aln, opMatch)
                ELSE
                    AppendCigar(aln, opSubst)
                END
                layer := tbM[i,j];  DEC(i);  DEC(j)
            END
        ELSIF layer = 1 THEN
            AppendCigar(aln, opIns)
            layer := tbX[i,j];  DEC(i)
        ELSE
            AppendCigar(aln, opDel)
            layer := tbY[i,j];  DEC(j)
        END
    END

    aln.qStart := i;  aln.rStart := j
    ReverseCigar(aln)
    CalcIdentity(aln, q, r)
END Local
```

---

## SemiGlobal — query free end-gaps

The query may overhang either end of the reference without penalty.
Implemented by initialising the first row (gap in query at start) to zero
and picking the best score in the last row (gap in query at end) rather than
the single bottom-right corner.

```
PROCEDURE SemiGlobal(q, r: BioSeq.Seq; VAR m: ScoreMatrix; VAR aln: Alignment)

    VAR
        qLen, rLen      : INTEGER
        M, X, Y         : ARRAY (MaxSeqLen+1)*(MaxSeqLen+1) OF INTEGER
        tbM, tbX, tbY   : ARRAY (MaxSeqLen+1)*(MaxSeqLen+1) OF INTEGER
        i, j, best, s   : INTEGER
        bestJ, layer     : INTEGER

    qLen := BioSeq.Length(q)
    rLen := BioSeq.Length(r)

    (* ── Initialisation ── *)
    M[0,0] := 0;  X[0,0] := NEG_INF;  Y[0,0] := NEG_INF

    (* First column: gaps in reference penalised normally *)
    FOR i := 1 TO qLen DO
        M[i,0] := NEG_INF
        X[i,0] := m.gapOpen + i * m.gapExt
        Y[i,0] := NEG_INF
    END

    (* First row: free — query hasn't started yet, no gap penalty *)
    FOR j := 1 TO rLen DO
        M[0,j] := NEG_INF
        X[0,j] := NEG_INF
        Y[0,j] := 0          (* no cost for reference advancing before query *)
    END

    (* ── Fill: same recurrence as Global ── *)
    FOR i := 1 TO qLen DO
        FOR j := 1 TO rLen DO
            s := PairScore(m, BioSeq.Get(q, i-1), BioSeq.Get(r, j-1))

            best := M[i-1,j-1];  tbM[i,j] := 0
            IF X[i-1,j-1] > best THEN best := X[i-1,j-1];  tbM[i,j] := 1 END
            IF Y[i-1,j-1] > best THEN best := Y[i-1,j-1];  tbM[i,j] := 2 END
            M[i,j] := best + s

            IF M[i-1,j] + m.gapOpen >= X[i-1,j] + m.gapExt THEN
                X[i,j] := M[i-1,j] + m.gapOpen;  tbX[i,j] := 0
            ELSE
                X[i,j] := X[i-1,j] + m.gapExt;   tbX[i,j] := 1
            END

            IF M[i,j-1] + m.gapOpen >= Y[i,j-1] + m.gapExt THEN
                Y[i,j] := M[i,j-1] + m.gapOpen;  tbY[i,j] := 0
            ELSE
                Y[i,j] := Y[i,j-1] + m.gapExt;   tbY[i,j] := 2
            END
        END
    END

    (* ── Best score in last row of M: free trailing gap in reference ── *)
    aln.score := M[qLen,1];  bestJ := 1
    FOR j := 2 TO rLen DO
        IF M[qLen,j] > aln.score THEN
            aln.score := M[qLen,j];  bestJ := j
        END
    END
    (* also check X layer (query ended with insertion) *)
    FOR j := 1 TO rLen DO
        IF X[qLen,j] > aln.score THEN
            aln.score := X[qLen,j];  bestJ := j;  layer := 1
        END
    END

    aln.qEnd := qLen;  aln.rEnd := bestJ
    aln.qStart := 0;   aln.rStart := 0
    aln.nOps := 0

    (* ── Traceback same as Global but stops at row 0 ── *)
    i := qLen;  j := bestJ
    WHILE (i > 0) OR (j > 0) DO
        IF i = 0 THEN
            (* remaining reference columns: free leading gap, stop *)
            aln.rStart := j;  j := 0
        ELSIF layer = 0 THEN
            IF BioSeq.Get(q,i-1) = BioSeq.Get(r,j-1) THEN
                AppendCigar(aln, opMatch)
            ELSE
                AppendCigar(aln, opSubst)
            END
            layer := tbM[i,j];  DEC(i);  DEC(j)
        ELSIF layer = 1 THEN
            AppendCigar(aln, opIns)
            layer := tbX[i,j];  DEC(i)
        ELSE
            AppendCigar(aln, opDel)
            layer := tbY[i,j];  DEC(j)
        END
    END

    ReverseCigar(aln)
    CalcIdentity(aln, q, r)
END SemiGlobal
```

---

## EditDistance — Levenshtein

Standard DP, no affine gaps, unit costs. Uses a single row update (O(min(m,n))
space) because we only need the final distance.

```
PROCEDURE EditDistance(q, r: BioSeq.Seq): INTEGER

    VAR
        qLen, rLen    : INTEGER
        prev, curr    : ARRAY MaxSeqLen+1 OF INTEGER
        i, j, diag, del, ins : INTEGER

    qLen := BioSeq.Length(q)
    rLen := BioSeq.Length(r)

    (* Initialise first row *)
    FOR j := 0 TO rLen DO prev[j] := j END

    FOR i := 1 TO qLen DO
        curr[0] := i
        FOR j := 1 TO rLen DO
            IF BioSeq.Get(q, i-1) = BioSeq.Get(r, j-1) THEN
                diag := prev[j-1]          (* match: no cost *)
            ELSE
                diag := prev[j-1] + 1      (* substitution   *)
            END
            del := prev[j] + 1             (* delete from q  *)
            ins := curr[j-1] + 1           (* insert into q  *)
            curr[j] := MIN(diag, MIN(del, ins))
        END
        (* swap rows *)
        FOR j := 0 TO rLen DO prev[j] := curr[j] END
    END

    RETURN prev[rLen]
END EditDistance
```

---

## HammingDistance

```
PROCEDURE HammingDistance(q, r: BioSeq.Seq): INTEGER

    VAR i, dist, qLen : INTEGER

    qLen := BioSeq.Length(q)
    IF qLen # BioSeq.Length(r) THEN RETURN -1 END   (* undefined for unequal lengths *)

    dist := 0
    FOR i := 0 TO qLen-1 DO
        IF BioSeq.Get(q, i) # BioSeq.Get(r, i) THEN INC(dist) END
    END
    RETURN dist
END HammingDistance
```

---

## PrintAlignment

Reconstructs the two aligned strings and a match bar from the CIGAR, then
prints them in blocks of `lineWidth` columns.

```
PROCEDURE PrintAlignment(VAR aln: Alignment; q, r: BioSeq.Seq)

    CONST lineWidth = 60

    VAR
        (* Build full aligned strings first, then print in blocks *)
        qAln, rAln, bar : ARRAY MaxCigar*2 OF CHAR
        pos, k, p, qi, ri, alen : INTEGER
        qc, rc : CHAR

    qi  := aln.qStart
    ri  := aln.rStart
    pos := 0

    FOR k := 0 TO aln.nOps-1 DO
        FOR p := 0 TO aln.cigar[k].len-1 DO
            IF aln.cigar[k].op = opMatch THEN
                qc := BioSeq.Get(q, qi);  rc := BioSeq.Get(r, ri)
                qAln[pos] := qc;  rAln[pos] := rc;  bar[pos] := '|'
                INC(qi);  INC(ri)
            ELSIF aln.cigar[k].op = opSubst THEN
                qAln[pos] := BioSeq.Get(q, qi)
                rAln[pos] := BioSeq.Get(r, ri)
                bar[pos]  := '.'
                INC(qi);  INC(ri)
            ELSIF aln.cigar[k].op = opIns THEN
                qAln[pos] := BioSeq.Get(q, qi)
                rAln[pos] := '-';  bar[pos] := ' '
                INC(qi)
            ELSE (* opDel *)
                qAln[pos] := '-'
                rAln[pos] := BioSeq.Get(r, ri)
                bar[pos]  := ' '
                INC(ri)
            END
            INC(pos)
        END
    END
    alen := pos

    (* Print header *)
    Out.String("Score: ");     Out.Int(aln.score, 0);    Out.Ln
    Out.String("Identity: ");  Out.Fixed(aln.identity * 100.0, 0, 2)
    Out.String("%");           Out.Ln
    Out.String("Query:  ");    Out.Int(aln.qStart, 0);
    Out.String(" - ");         Out.Int(aln.qEnd, 0);     Out.Ln
    Out.String("Target: ");    Out.Int(aln.rStart, 0);
    Out.String(" - ");         Out.Int(aln.rEnd, 0);     Out.Ln
    Out.Ln

    (* Print in blocks *)
    pos := 0
    WHILE pos < alen DO
        Out.String("Query  ")
        FOR k := pos TO MIN(pos + lineWidth - 1, alen-1) DO Out.Char(qAln[k]) END
        Out.Ln
        Out.String("       ")
        FOR k := pos TO MIN(pos + lineWidth - 1, alen-1) DO Out.Char(bar[k])  END
        Out.Ln
        Out.String("Target ")
        FOR k := pos TO MIN(pos + lineWidth - 1, alen-1) DO Out.Char(rAln[k]) END
        Out.Ln
        Out.Ln
        INC(pos, lineWidth)
    END
END PrintAlignment
```

---

## Algorithm Summary

| Procedure | Algorithm | Gap model | Time | Space |
|-----------|-----------|-----------|------|-------|
| `Global` | Needleman-Wunsch | Affine (open+ext) | O(mn) | O(mn) |
| `Local` | Smith-Waterman | Affine (open+ext) | O(mn) | O(mn) |
| `SemiGlobal` | NW, free query end-gaps | Affine (open+ext) | O(mn) | O(mn) |
| `EditDistance` | Wagner-Fischer | Unit (ins/del/subst=1) | O(mn) | O(n) |
| `HammingDistance` | Linear scan | — (equal length only) | O(n) | O(1) |

The three affine-gap procedures each maintain three DP matrices (M, X, Y)
plus three matching traceback matrices, for six arrays total per call.
At `MaxSeqLen = 4096` each INTEGER matrix is 4096 × 4096 × 4 bytes ≈ 64 MB —
declare them as module-level VAR (not local) to avoid stack overflow.
