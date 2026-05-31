MODULE BioAlign;
(*
  BioAlign — Pairwise sequence alignment.

  Implements Needleman-Wunsch (global), Smith-Waterman (local), semi-global,
  Levenshtein edit distance, and Hamming distance.

  All three DP-based aligners use affine gap penalties (gapOpen + gapExt) and
  three score layers (M = aligned pair, X = gap in reference, Y = gap in query).

  Score matrices:
    DefaultScore — simple +1/-1 for DNA/RNA; gapOpen=-5, gapExt=-1.
    BLOSUM62     — standard protein matrix; gapOpen=-11, gapExt=-1.
    PAM250       — Dayhoff protein matrix;  gapOpen=-12, gapExt=-2.
  When useTable=TRUE, PairScore looks up table[ORD(a)-ORD('A')][ORD(b)-ORD('A')]
  for uppercase letters; falls back to match_/mismatch for anything else.

  DP matrices are heap-allocated on first use and grown as needed; only one
  alignment may run at a time.  MaxSeqLen caps both query and reference length.
*)

IMPORT BioSeq, Math, Out;

CONST
  MaxSeqLen* = 10000;
  MaxCigar*  = 8192;
  MaxAligned  = 2 * MaxSeqLen + 2;
  PrintWidth  = 60;

  opMatch* = 0;
  opIns*   = 1;   (* gap in reference: query has extra base *)
  opDel*   = 2;   (* gap in query: reference has extra base *)
  opSubst* = 3;

  NEG_INF = -1000000;

  (* Traceback source codes stored in tb arrays *)
  tbFromM = 0;
  tbFromX = 1;
  tbFromY = 2;
  tbStart = -1;   (* SW local-alignment start sentinel *)

TYPE
  ScoreMatrix* = RECORD
    match_*   : INTEGER;
    mismatch* : INTEGER;
    gapOpen*  : INTEGER;
    gapExt*   : INTEGER;
    useTable* : BOOLEAN;
    table*    : ARRAY 26 OF ARRAY 26 OF INTEGER  (* indexed by ORD(c)-ORD('A') *)
  END;

  CigarEntry* = RECORD
    op*  : INTEGER;
    len* : INTEGER
  END;

  Alignment* = RECORD
    score*          : INTEGER;
    qStart*, qEnd*  : INTEGER;
    rStart*, rEnd*  : INTEGER;
    cigar*          : ARRAY MaxCigar OF CigarEntry;
    nOps*           : INTEGER;
    identity*       : REAL
  END;

(* Heap-allocated DP storage — shared across all alignment procedures.
   Grown on demand; dpStride = rLen+1 for the current call. *)
VAR
  dpM : POINTER TO ARRAY OF INTEGER;
  dpX : POINTER TO ARRAY OF INTEGER;
  dpY : POINTER TO ARRAY OF INTEGER;
  tbM : POINTER TO ARRAY OF INTEGER;
  tbX : POINTER TO ARRAY OF INTEGER;
  tbY : POINTER TO ARRAY OF INTEGER;
  dpStride       : INTEGER;
  dpAlloc        : INTEGER;
  edPrev, edCurr : ARRAY MaxSeqLen + 1 OF INTEGER;
  pqAln, prAln, pbar : ARRAY MaxAligned OF CHAR;   (* PrintAlignment buffers *)

(* ------------------------------------------------------------------ *)
(*  Internal: ensure DP matrices are large enough for qLen x rLen     *)
(* ------------------------------------------------------------------ *)

PROCEDURE EnsureDP(qLen, rLen: INTEGER);
VAR needed: INTEGER;
BEGIN
  dpStride := rLen + 1;
  needed   := (qLen + 1) * (rLen + 1);
  IF needed > dpAlloc THEN
    IF dpM # NIL THEN
      FREE(dpM); FREE(dpX); FREE(dpY);
      FREE(tbM); FREE(tbX); FREE(tbY)
    END;
    NEW(dpM, needed); NEW(dpX, needed); NEW(dpY, needed);
    NEW(tbM, needed); NEW(tbX, needed); NEW(tbY, needed);
    dpAlloc := needed
  END
END EnsureDP;

(* ------------------------------------------------------------------ *)
(*  Public: scoring setup                                               *)
(* ------------------------------------------------------------------ *)

PROCEDURE DefaultScore*(VAR m: ScoreMatrix);
BEGIN
  m.match_   :=  1;
  m.mismatch := -1;
  m.gapOpen  := -5;
  m.gapExt   := -1;
  m.useTable := FALSE
END DefaultScore;

(* ------------------------------------------------------------------ *)
(*  Substitution matrices — BLOSUM62 and PAM250                        *)
(* ------------------------------------------------------------------ *)

PROCEDURE Set2(VAR m: ScoreMatrix; a, b, s: INTEGER);
BEGIN m.table[a][b] := s; m.table[b][a] := s END Set2;

PROCEDURE FillTable(VAR m: ScoreMatrix);
(*
  Initialise all 26×26 cells to mismatch, then fill in BLOSUM62 or PAM250.
  Called at the start of each matrix initialiser.
*)
VAR i, j: INTEGER;
BEGIN
  FOR i := 0 TO 25 DO
    FOR j := 0 TO 25 DO m.table[i][j] := m.mismatch END
  END
END FillTable;

PROCEDURE BLOSUM62*(VAR m: ScoreMatrix);
(*
  Initialise m with the BLOSUM62 substitution matrix.
  Indices: A=0 C=2 D=3 E=4 F=5 G=6 H=7 I=8 K=10 L=11
           M=12 N=13 P=15 Q=16 R=17 S=18 T=19 V=21 W=22 Y=24
*)
BEGIN
  m.match_   :=  1;
  m.mismatch := -4;
  m.gapOpen  := -11;
  m.gapExt   := -1;
  m.useTable := TRUE;
  FillTable(m);
  (* Diagonal (self-match scores) *)
  m.table[ 0][ 0] :=  4;  (* A *)
  m.table[ 2][ 2] :=  9;  (* C *)
  m.table[ 3][ 3] :=  6;  (* D *)
  m.table[ 4][ 4] :=  5;  (* E *)
  m.table[ 5][ 5] :=  6;  (* F *)
  m.table[ 6][ 6] :=  6;  (* G *)
  m.table[ 7][ 7] :=  8;  (* H *)
  m.table[ 8][ 8] :=  4;  (* I *)
  m.table[10][10] :=  5;  (* K *)
  m.table[11][11] :=  4;  (* L *)
  m.table[12][12] :=  5;  (* M *)
  m.table[13][13] :=  6;  (* N *)
  m.table[15][15] :=  7;  (* P *)
  m.table[16][16] :=  5;  (* Q *)
  m.table[17][17] :=  5;  (* R *)
  m.table[18][18] :=  4;  (* S *)
  m.table[19][19] :=  5;  (* T *)
  m.table[21][21] :=  4;  (* V *)
  m.table[22][22] := 11;  (* W *)
  m.table[24][24] :=  7;  (* Y *)
  (* Off-diagonal pairs — A row *)
  Set2(m,  0,  2,  0);  Set2(m,  0,  3, -2);  Set2(m,  0,  4, -1);
  Set2(m,  0,  5, -2);  Set2(m,  0,  6,  0);  Set2(m,  0,  7, -2);
  Set2(m,  0,  8, -1);  Set2(m,  0, 10, -1);  Set2(m,  0, 11, -1);
  Set2(m,  0, 12, -1);  Set2(m,  0, 13, -2);  Set2(m,  0, 15, -1);
  Set2(m,  0, 16, -1);  Set2(m,  0, 17, -1);  Set2(m,  0, 18,  1);
  Set2(m,  0, 19,  0);  Set2(m,  0, 21,  0);  Set2(m,  0, 22, -3);
  Set2(m,  0, 24, -2);
  (* C row *)
  Set2(m,  2,  3, -3);  Set2(m,  2,  4, -4);  Set2(m,  2,  5, -2);
  Set2(m,  2,  6, -3);  Set2(m,  2,  7, -3);  Set2(m,  2,  8, -1);
  Set2(m,  2, 10, -3);  Set2(m,  2, 11, -1);  Set2(m,  2, 12, -1);
  Set2(m,  2, 13, -3);  Set2(m,  2, 15, -3);  Set2(m,  2, 16, -3);
  Set2(m,  2, 17, -3);  Set2(m,  2, 18, -1);  Set2(m,  2, 19, -1);
  Set2(m,  2, 21, -1);  Set2(m,  2, 22, -2);  Set2(m,  2, 24, -2);
  (* D row *)
  Set2(m,  3,  4,  2);  Set2(m,  3,  5, -3);  Set2(m,  3,  6, -1);
  Set2(m,  3,  7, -1);  Set2(m,  3,  8, -3);  Set2(m,  3, 10, -1);
  Set2(m,  3, 11, -4);  Set2(m,  3, 12, -3);  Set2(m,  3, 13,  1);
  Set2(m,  3, 15, -1);  Set2(m,  3, 16,  0);  Set2(m,  3, 17, -2);
  Set2(m,  3, 18,  0);  Set2(m,  3, 19, -1);  Set2(m,  3, 21, -3);
  Set2(m,  3, 22, -4);  Set2(m,  3, 24, -3);
  (* E row *)
  Set2(m,  4,  5, -3);  Set2(m,  4,  6, -2);  Set2(m,  4,  7,  0);
  Set2(m,  4,  8, -3);  Set2(m,  4, 10,  1);  Set2(m,  4, 11, -3);
  Set2(m,  4, 12, -2);  Set2(m,  4, 13,  0);  Set2(m,  4, 15, -1);
  Set2(m,  4, 16,  2);  Set2(m,  4, 17,  0);  Set2(m,  4, 18,  0);
  Set2(m,  4, 19, -1);  Set2(m,  4, 21, -2);  Set2(m,  4, 22, -3);
  Set2(m,  4, 24, -2);
  (* F row *)
  Set2(m,  5,  6, -3);  Set2(m,  5,  7, -1);  Set2(m,  5,  8,  0);
  Set2(m,  5, 10, -3);  Set2(m,  5, 11,  0);  Set2(m,  5, 12,  0);
  Set2(m,  5, 13, -3);  Set2(m,  5, 15, -4);  Set2(m,  5, 16, -3);
  Set2(m,  5, 17, -3);  Set2(m,  5, 18, -2);  Set2(m,  5, 19, -2);
  Set2(m,  5, 21, -1);  Set2(m,  5, 22,  1);  Set2(m,  5, 24,  3);
  (* G row *)
  Set2(m,  6,  7, -2);  Set2(m,  6,  8, -4);  Set2(m,  6, 10, -2);
  Set2(m,  6, 11, -4);  Set2(m,  6, 12, -3);  Set2(m,  6, 13,  0);
  Set2(m,  6, 15, -2);  Set2(m,  6, 16, -2);  Set2(m,  6, 17, -2);
  Set2(m,  6, 18,  0);  Set2(m,  6, 19, -2);  Set2(m,  6, 21, -3);
  Set2(m,  6, 22, -2);  Set2(m,  6, 24, -3);
  (* H row *)
  Set2(m,  7,  8, -3);  Set2(m,  7, 10, -1);  Set2(m,  7, 11, -3);
  Set2(m,  7, 12, -2);  Set2(m,  7, 13,  1);  Set2(m,  7, 15, -2);
  Set2(m,  7, 16,  0);  Set2(m,  7, 17,  0);  Set2(m,  7, 18, -1);
  Set2(m,  7, 19, -2);  Set2(m,  7, 21, -3);  Set2(m,  7, 22, -2);
  Set2(m,  7, 24,  2);
  (* I row *)
  Set2(m,  8, 10, -3);  Set2(m,  8, 11,  2);  Set2(m,  8, 12,  1);
  Set2(m,  8, 13, -3);  Set2(m,  8, 15, -3);  Set2(m,  8, 16, -3);
  Set2(m,  8, 17, -3);  Set2(m,  8, 18, -2);  Set2(m,  8, 19, -1);
  Set2(m,  8, 21,  3);  Set2(m,  8, 22, -3);  Set2(m,  8, 24, -1);
  (* K row *)
  Set2(m, 10, 11, -2);  Set2(m, 10, 12, -1);  Set2(m, 10, 13,  0);
  Set2(m, 10, 15, -1);  Set2(m, 10, 16,  1);  Set2(m, 10, 17,  2);
  Set2(m, 10, 18,  0);  Set2(m, 10, 19, -1);  Set2(m, 10, 21, -2);
  Set2(m, 10, 22, -3);  Set2(m, 10, 24, -2);
  (* L row *)
  Set2(m, 11, 12,  2);  Set2(m, 11, 13, -3);  Set2(m, 11, 15, -3);
  Set2(m, 11, 16, -2);  Set2(m, 11, 17, -2);  Set2(m, 11, 18, -2);
  Set2(m, 11, 19, -1);  Set2(m, 11, 21,  1);  Set2(m, 11, 22, -2);
  Set2(m, 11, 24, -1);
  (* M row *)
  Set2(m, 12, 13, -2);  Set2(m, 12, 15, -2);  Set2(m, 12, 16,  0);
  Set2(m, 12, 17, -1);  Set2(m, 12, 18, -1);  Set2(m, 12, 19, -1);
  Set2(m, 12, 21,  1);  Set2(m, 12, 22, -1);  Set2(m, 12, 24, -1);
  (* N row *)
  Set2(m, 13, 15, -2);  Set2(m, 13, 16,  0);  Set2(m, 13, 17,  0);
  Set2(m, 13, 18,  1);  Set2(m, 13, 19,  0);  Set2(m, 13, 21, -3);
  Set2(m, 13, 22, -4);  Set2(m, 13, 24, -2);
  (* P row *)
  Set2(m, 15, 16, -1);  Set2(m, 15, 17, -2);  Set2(m, 15, 18, -1);
  Set2(m, 15, 19, -1);  Set2(m, 15, 21, -2);  Set2(m, 15, 22, -4);
  Set2(m, 15, 24, -3);
  (* Q row *)
  Set2(m, 16, 17,  1);  Set2(m, 16, 18,  0);  Set2(m, 16, 19, -1);
  Set2(m, 16, 21, -2);  Set2(m, 16, 22, -2);  Set2(m, 16, 24, -1);
  (* R row *)
  Set2(m, 17, 18, -1);  Set2(m, 17, 19, -1);  Set2(m, 17, 21, -3);
  Set2(m, 17, 22, -3);  Set2(m, 17, 24, -2);
  (* S row *)
  Set2(m, 18, 19,  1);  Set2(m, 18, 21, -2);  Set2(m, 18, 22, -3);
  Set2(m, 18, 24, -2);
  (* T row *)
  Set2(m, 19, 21,  0);  Set2(m, 19, 22, -2);  Set2(m, 19, 24, -2);
  (* V, W rows *)
  Set2(m, 21, 22, -3);  Set2(m, 21, 24, -1);
  Set2(m, 22, 24,  2)
END BLOSUM62;

PROCEDURE PAM250*(VAR m: ScoreMatrix);
(*
  Initialise m with the PAM250 (Dayhoff) substitution matrix.
  Same index scheme as BLOSUM62.
*)
BEGIN
  m.match_   :=  1;
  m.mismatch := -8;
  m.gapOpen  := -12;
  m.gapExt   := -2;
  m.useTable := TRUE;
  FillTable(m);
  (* Diagonal *)
  m.table[ 0][ 0] :=  2;  (* A *)
  m.table[ 2][ 2] := 12;  (* C *)
  m.table[ 3][ 3] :=  4;  (* D *)
  m.table[ 4][ 4] :=  4;  (* E *)
  m.table[ 5][ 5] :=  9;  (* F *)
  m.table[ 6][ 6] :=  5;  (* G *)
  m.table[ 7][ 7] :=  6;  (* H *)
  m.table[ 8][ 8] :=  5;  (* I *)
  m.table[10][10] :=  5;  (* K *)
  m.table[11][11] :=  6;  (* L *)
  m.table[12][12] :=  6;  (* M *)
  m.table[13][13] :=  2;  (* N *)
  m.table[15][15] :=  6;  (* P *)
  m.table[16][16] :=  4;  (* Q *)
  m.table[17][17] :=  6;  (* R *)
  m.table[18][18] :=  2;  (* S *)
  m.table[19][19] :=  3;  (* T *)
  m.table[21][21] :=  4;  (* V *)
  m.table[22][22] := 17;  (* W *)
  m.table[24][24] := 10;  (* Y *)
  (* Off-diagonal pairs — A row *)
  Set2(m,  0,  2, -2);  Set2(m,  0,  3,  0);  Set2(m,  0,  4,  0);
  Set2(m,  0,  5, -3);  Set2(m,  0,  6,  1);  Set2(m,  0,  7, -1);
  Set2(m,  0,  8, -1);  Set2(m,  0, 10, -1);  Set2(m,  0, 11, -2);
  Set2(m,  0, 12, -1);  Set2(m,  0, 13,  0);  Set2(m,  0, 15,  1);
  Set2(m,  0, 16,  0);  Set2(m,  0, 17, -2);  Set2(m,  0, 18,  1);
  Set2(m,  0, 19,  1);  Set2(m,  0, 21,  0);  Set2(m,  0, 22, -6);
  Set2(m,  0, 24, -3);
  (* C row *)
  Set2(m,  2,  3, -5);  Set2(m,  2,  4, -5);  Set2(m,  2,  5, -4);
  Set2(m,  2,  6, -3);  Set2(m,  2,  7, -3);  Set2(m,  2,  8, -2);
  Set2(m,  2, 10, -5);  Set2(m,  2, 11, -6);  Set2(m,  2, 12, -5);
  Set2(m,  2, 13, -4);  Set2(m,  2, 15, -3);  Set2(m,  2, 16, -5);
  Set2(m,  2, 17, -4);  Set2(m,  2, 18,  0);  Set2(m,  2, 19, -2);
  Set2(m,  2, 21, -2);  Set2(m,  2, 22, -8);  Set2(m,  2, 24,  0);
  (* D row *)
  Set2(m,  3,  4,  3);  Set2(m,  3,  5, -6);  Set2(m,  3,  6,  1);
  Set2(m,  3,  7,  1);  Set2(m,  3,  8, -2);  Set2(m,  3, 10,  0);
  Set2(m,  3, 11, -4);  Set2(m,  3, 12, -3);  Set2(m,  3, 13,  2);
  Set2(m,  3, 15, -1);  Set2(m,  3, 16,  2);  Set2(m,  3, 17, -1);
  Set2(m,  3, 18,  0);  Set2(m,  3, 19,  0);  Set2(m,  3, 21, -2);
  Set2(m,  3, 22, -7);  Set2(m,  3, 24, -4);
  (* E row *)
  Set2(m,  4,  5, -5);  Set2(m,  4,  6,  0);  Set2(m,  4,  7,  1);
  Set2(m,  4,  8, -2);  Set2(m,  4, 10,  0);  Set2(m,  4, 11, -3);
  Set2(m,  4, 12, -2);  Set2(m,  4, 13,  1);  Set2(m,  4, 15, -1);
  Set2(m,  4, 16,  2);  Set2(m,  4, 17, -1);  Set2(m,  4, 18,  0);
  Set2(m,  4, 19,  0);  Set2(m,  4, 21, -2);  Set2(m,  4, 22, -7);
  Set2(m,  4, 24, -4);
  (* F row *)
  Set2(m,  5,  6, -5);  Set2(m,  5,  7, -2);  Set2(m,  5,  8,  1);
  Set2(m,  5, 10, -5);  Set2(m,  5, 11,  2);  Set2(m,  5, 12,  0);
  Set2(m,  5, 13, -3);  Set2(m,  5, 15, -5);  Set2(m,  5, 16, -5);
  Set2(m,  5, 17, -4);  Set2(m,  5, 18, -3);  Set2(m,  5, 19, -3);
  Set2(m,  5, 21, -1);  Set2(m,  5, 22,  0);  Set2(m,  5, 24,  7);
  (* G row *)
  Set2(m,  6,  7, -2);  Set2(m,  6,  8, -3);  Set2(m,  6, 10, -2);
  Set2(m,  6, 11, -4);  Set2(m,  6, 12, -3);  Set2(m,  6, 13,  0);
  Set2(m,  6, 15, -1);  Set2(m,  6, 16, -1);  Set2(m,  6, 17, -3);
  Set2(m,  6, 18,  1);  Set2(m,  6, 19,  0);  Set2(m,  6, 21, -1);
  Set2(m,  6, 22, -7);  Set2(m,  6, 24, -5);
  (* H row *)
  Set2(m,  7,  8, -2);  Set2(m,  7, 10,  0);  Set2(m,  7, 11, -2);
  Set2(m,  7, 12, -2);  Set2(m,  7, 13,  2);  Set2(m,  7, 15,  0);
  Set2(m,  7, 16,  3);  Set2(m,  7, 17,  2);  Set2(m,  7, 18, -1);
  Set2(m,  7, 19, -1);  Set2(m,  7, 21, -2);  Set2(m,  7, 22, -3);
  Set2(m,  7, 24,  0);
  (* I row *)
  Set2(m,  8, 10, -2);  Set2(m,  8, 11,  2);  Set2(m,  8, 12,  2);
  Set2(m,  8, 13, -2);  Set2(m,  8, 15, -2);  Set2(m,  8, 16, -2);
  Set2(m,  8, 17, -2);  Set2(m,  8, 18, -1);  Set2(m,  8, 19,  0);
  Set2(m,  8, 21,  4);  Set2(m,  8, 22, -5);  Set2(m,  8, 24, -1);
  (* K row *)
  Set2(m, 10, 11, -3);  Set2(m, 10, 12,  0);  Set2(m, 10, 13,  1);
  Set2(m, 10, 15, -1);  Set2(m, 10, 16,  1);  Set2(m, 10, 17,  3);
  Set2(m, 10, 18,  0);  Set2(m, 10, 19,  0);  Set2(m, 10, 21, -2);
  Set2(m, 10, 22, -3);  Set2(m, 10, 24, -4);
  (* L row *)
  Set2(m, 11, 12,  4);  Set2(m, 11, 13, -3);  Set2(m, 11, 15, -3);
  Set2(m, 11, 16, -2);  Set2(m, 11, 17, -3);  Set2(m, 11, 18, -3);
  Set2(m, 11, 19, -2);  Set2(m, 11, 21,  2);  Set2(m, 11, 22, -2);
  Set2(m, 11, 24, -1);
  (* M row *)
  Set2(m, 12, 13, -2);  Set2(m, 12, 15, -2);  Set2(m, 12, 16, -1);
  Set2(m, 12, 17, -1);  Set2(m, 12, 18, -2);  Set2(m, 12, 19, -1);
  Set2(m, 12, 21,  2);  Set2(m, 12, 22, -4);  Set2(m, 12, 24, -2);
  (* N row *)
  Set2(m, 13, 15,  0);  Set2(m, 13, 16,  1);  Set2(m, 13, 17,  0);
  Set2(m, 13, 18,  1);  Set2(m, 13, 19,  0);  Set2(m, 13, 21, -2);
  Set2(m, 13, 22, -4);  Set2(m, 13, 24, -2);
  (* P row *)
  Set2(m, 15, 16,  0);  Set2(m, 15, 17,  0);  Set2(m, 15, 18,  1);
  Set2(m, 15, 19,  0);  Set2(m, 15, 21, -1);  Set2(m, 15, 22, -6);
  Set2(m, 15, 24, -5);
  (* Q row *)
  Set2(m, 16, 17,  1);  Set2(m, 16, 18, -1);  Set2(m, 16, 19, -1);
  Set2(m, 16, 21, -2);  Set2(m, 16, 22, -5);  Set2(m, 16, 24, -4);
  (* R row *)
  Set2(m, 17, 18,  0);  Set2(m, 17, 19, -1);  Set2(m, 17, 21, -2);
  Set2(m, 17, 22,  2);  Set2(m, 17, 24, -4);
  (* S row *)
  Set2(m, 18, 19,  1);  Set2(m, 18, 21, -1);  Set2(m, 18, 22, -2);
  Set2(m, 18, 24, -3);
  (* T row *)
  Set2(m, 19, 21,  0);  Set2(m, 19, 22, -5);  Set2(m, 19, 24, -3);
  (* V, W rows *)
  Set2(m, 21, 22, -6);  Set2(m, 21, 24, -2);
  Set2(m, 22, 24,  0)
END PAM250;

(* ------------------------------------------------------------------ *)
(*  Internal helpers                                                    *)
(* ------------------------------------------------------------------ *)

PROCEDURE PairScore*(VAR m: ScoreMatrix; a, b: CHAR): INTEGER;
VAR ia, ib: INTEGER;
BEGIN
  IF m.useTable THEN
    IF (a >= 'a') & (a <= 'z') THEN a := CHR(ORD(a) - 32) END;
    IF (b >= 'a') & (b <= 'z') THEN b := CHR(ORD(b) - 32) END;
    ia := ORD(a) - ORD('A');
    ib := ORD(b) - ORD('A');
    IF (ia >= 0) & (ia <= 25) & (ib >= 0) & (ib <= 25) THEN
      RETURN m.table[ia][ib]
    END
  END;
  IF a = b THEN RETURN m.match_ ELSE RETURN m.mismatch END
END PairScore;

PROCEDURE AppendCigar(VAR aln: Alignment; op: INTEGER);
BEGIN
  IF (aln.nOps > 0) & (aln.cigar[aln.nOps - 1].op = op) THEN
    INC(aln.cigar[aln.nOps - 1].len)
  ELSE
    ASSERT(aln.nOps < MaxCigar);
    aln.cigar[aln.nOps].op  := op;
    aln.cigar[aln.nOps].len := 1;
    INC(aln.nOps)
  END
END AppendCigar;

PROCEDURE ReverseCigar(VAR aln: Alignment);
VAR lo, hi: INTEGER; tmp: CigarEntry;
BEGIN
  lo := 0;  hi := aln.nOps - 1;
  WHILE lo < hi DO
    tmp           := aln.cigar[lo];
    aln.cigar[lo] := aln.cigar[hi];
    aln.cigar[hi] := tmp;
    INC(lo);  DEC(hi)
  END
END ReverseCigar;

PROCEDURE CalcIdentity(VAR aln: Alignment; q, r: BioSeq.Seq);
VAR matches, aligned, k, p, qi, ri: INTEGER;
BEGIN
  matches := 0;  aligned := 0;
  qi := aln.qStart;  ri := aln.rStart;
  FOR k := 0 TO aln.nOps - 1 DO
    FOR p := 0 TO aln.cigar[k].len - 1 DO
      IF aln.cigar[k].op = opMatch THEN
        INC(matches);  INC(aligned);  INC(qi);  INC(ri)
      ELSIF aln.cigar[k].op = opSubst THEN
        INC(aligned);  INC(qi);  INC(ri)
      ELSIF aln.cigar[k].op = opIns THEN
        INC(aligned);  INC(qi)
      ELSE
        INC(aligned);  INC(ri)
      END
    END
  END;
  IF aligned > 0 THEN
    aln.identity := FLT(matches) / FLT(aligned)
  ELSE
    aln.identity := 0.0
  END
END CalcIdentity;

(* ------------------------------------------------------------------ *)
(*  Global — Needleman-Wunsch with affine gap penalties                *)
(* ------------------------------------------------------------------ *)

PROCEDURE Global*(q, r: BioSeq.Seq; VAR m: ScoreMatrix; VAR aln: Alignment);
VAR
  qLen, rLen     : INTEGER;
  i, j, best, s  : INTEGER;
  layer, r0, r1  : INTEGER;
BEGIN
  qLen := BioSeq.Length(q);
  rLen := BioSeq.Length(r);
  ASSERT(qLen <= MaxSeqLen);
  ASSERT(rLen <= MaxSeqLen);
  EnsureDP(qLen, rLen);

  (* --- Initialisation --- *)
  dpM^[0] := 0;  dpX^[0] := NEG_INF;  dpY^[0] := NEG_INF;

  FOR i := 1 TO qLen DO
    r1 := i * dpStride;
    dpM^[r1] := NEG_INF;
    dpX^[r1] := m.gapOpen + i * m.gapExt;
    dpY^[r1] := NEG_INF;
    tbX^[r1] := tbFromX
  END;

  FOR j := 1 TO rLen DO
    dpM^[j] := NEG_INF;
    dpX^[j] := NEG_INF;
    dpY^[j] := m.gapOpen + j * m.gapExt;
    tbY^[j] := tbFromY
  END;

  (* --- Fill --- *)
  FOR i := 1 TO qLen DO
    r0 := (i - 1) * dpStride;
    r1 := i * dpStride;
    FOR j := 1 TO rLen DO
      s := PairScore(m, BioSeq.Get(q, i - 1), BioSeq.Get(r, j - 1));

      (* M layer: align q[i-1] with r[j-1] *)
      best := dpM^[r0 + j - 1];  tbM^[r1 + j] := tbFromM;
      IF dpX^[r0 + j - 1] > best THEN best := dpX^[r0 + j - 1];  tbM^[r1 + j] := tbFromX END;
      IF dpY^[r0 + j - 1] > best THEN best := dpY^[r0 + j - 1];  tbM^[r1 + j] := tbFromY END;
      dpM^[r1 + j] := best + s;

      (* X layer: gap in reference (insert into query) *)
      IF dpM^[r0 + j] + m.gapOpen >= dpX^[r0 + j] + m.gapExt THEN
        dpX^[r1 + j] := dpM^[r0 + j] + m.gapOpen;  tbX^[r1 + j] := tbFromM
      ELSE
        dpX^[r1 + j] := dpX^[r0 + j] + m.gapExt;   tbX^[r1 + j] := tbFromX
      END;

      (* Y layer: gap in query (delete from query) *)
      IF dpM^[r1 + j - 1] + m.gapOpen >= dpY^[r1 + j - 1] + m.gapExt THEN
        dpY^[r1 + j] := dpM^[r1 + j - 1] + m.gapOpen;  tbY^[r1 + j] := tbFromM
      ELSE
        dpY^[r1 + j] := dpY^[r1 + j - 1] + m.gapExt;   tbY^[r1 + j] := tbFromY
      END
    END
  END;

  (* --- Pick best terminal layer --- *)
  r0 := qLen * dpStride;
  aln.score := dpM^[r0 + rLen];  layer := tbFromM;
  IF dpX^[r0 + rLen] > aln.score THEN aln.score := dpX^[r0 + rLen];  layer := tbFromX END;
  IF dpY^[r0 + rLen] > aln.score THEN aln.score := dpY^[r0 + rLen];  layer := tbFromY END;

  aln.qEnd   := qLen;  aln.rEnd   := rLen;
  aln.qStart := 0;     aln.rStart := 0;
  aln.nOps   := 0;

  (* --- Traceback from bottom-right corner --- *)
  i := qLen;  j := rLen;
  WHILE (i > 0) OR (j > 0) DO
    IF layer = tbFromM THEN
      IF BioSeq.Get(q, i - 1) = BioSeq.Get(r, j - 1) THEN
        AppendCigar(aln, opMatch)
      ELSE
        AppendCigar(aln, opSubst)
      END;
      layer := tbM^[i * dpStride + j];  DEC(i);  DEC(j)
    ELSIF layer = tbFromX THEN
      AppendCigar(aln, opIns);
      layer := tbX^[i * dpStride + j];  DEC(i)
    ELSE
      AppendCigar(aln, opDel);
      layer := tbY^[i * dpStride + j];  DEC(j)
    END
  END;

  ReverseCigar(aln);
  CalcIdentity(aln, q, r)
END Global;

(* ------------------------------------------------------------------ *)
(*  Local — Smith-Waterman with affine gap penalties                   *)
(* ------------------------------------------------------------------ *)

PROCEDURE Local*(q, r: BioSeq.Seq; VAR m: ScoreMatrix; VAR aln: Alignment);
VAR
  qLen, rLen       : INTEGER;
  i, j, best, s    : INTEGER;
  bestI, bestJ      : INTEGER;
  layer, r0, r1     : INTEGER;
BEGIN
  qLen := BioSeq.Length(q);
  rLen := BioSeq.Length(r);
  ASSERT(qLen <= MaxSeqLen);
  ASSERT(rLen <= MaxSeqLen);
  EnsureDP(qLen, rLen);

  (* --- Initialisation: zeros allow local alignment to start anywhere --- *)
  FOR i := 0 TO qLen DO
    r0 := i * dpStride;
    dpM^[r0] := 0;  dpX^[r0] := 0;  dpY^[r0] := 0
  END;
  FOR j := 0 TO rLen DO
    dpM^[j] := 0;  dpX^[j] := 0;  dpY^[j] := 0
  END;

  aln.score := 0;  bestI := 0;  bestJ := 0;

  (* --- Fill --- *)
  FOR i := 1 TO qLen DO
    r0 := (i - 1) * dpStride;
    r1 := i * dpStride;
    FOR j := 1 TO rLen DO
      s := PairScore(m, BioSeq.Get(q, i - 1), BioSeq.Get(r, j - 1));

      (* M layer *)
      best := dpM^[r0 + j - 1];  tbM^[r1 + j] := tbFromM;
      IF dpX^[r0 + j - 1] > best THEN best := dpX^[r0 + j - 1];  tbM^[r1 + j] := tbFromX END;
      IF dpY^[r0 + j - 1] > best THEN best := dpY^[r0 + j - 1];  tbM^[r1 + j] := tbFromY END;
      best := best + s;
      IF best <= 0 THEN
        dpM^[r1 + j] := 0;  tbM^[r1 + j] := tbStart
      ELSE
        dpM^[r1 + j] := best
      END;

      (* X layer: gap in reference *)
      best := dpM^[r0 + j] + m.gapOpen;
      IF dpX^[r0 + j] + m.gapExt > best THEN
        best := dpX^[r0 + j] + m.gapExt;  tbX^[r1 + j] := tbFromX
      ELSE
        tbX^[r1 + j] := tbFromM
      END;
      IF best < 0 THEN best := 0 END;
      dpX^[r1 + j] := best;

      (* Y layer: gap in query *)
      best := dpM^[r1 + j - 1] + m.gapOpen;
      IF dpY^[r1 + j - 1] + m.gapExt > best THEN
        best := dpY^[r1 + j - 1] + m.gapExt;  tbY^[r1 + j] := tbFromY
      ELSE
        tbY^[r1 + j] := tbFromM
      END;
      IF best < 0 THEN best := 0 END;
      dpY^[r1 + j] := best;

      IF dpM^[r1 + j] > aln.score THEN
        aln.score := dpM^[r1 + j];  bestI := i;  bestJ := j
      END
    END
  END;

  aln.qEnd := bestI;  aln.rEnd := bestJ;
  aln.nOps := 0;      layer := tbFromM;

  (* --- Traceback from best cell, stop at zero --- *)
  i := bestI;  j := bestJ;
  WHILE (i > 0) & (j > 0) & (dpM^[i * dpStride + j] > 0) DO
    IF layer = tbFromM THEN
      IF tbM^[i * dpStride + j] = tbStart THEN
        (* reached local start: consume this aligned pair then stop *)
        IF BioSeq.Get(q, i - 1) = BioSeq.Get(r, j - 1) THEN
          AppendCigar(aln, opMatch)
        ELSE
          AppendCigar(aln, opSubst)
        END;
        DEC(i);  DEC(j);
        (* force loop exit *)
        j := 0
      ELSE
        IF BioSeq.Get(q, i - 1) = BioSeq.Get(r, j - 1) THEN
          AppendCigar(aln, opMatch)
        ELSE
          AppendCigar(aln, opSubst)
        END;
        layer := tbM^[i * dpStride + j];  DEC(i);  DEC(j)
      END
    ELSIF layer = tbFromX THEN
      AppendCigar(aln, opIns);
      layer := tbX^[i * dpStride + j];  DEC(i)
    ELSE
      AppendCigar(aln, opDel);
      layer := tbY^[i * dpStride + j];  DEC(j)
    END
  END;

  aln.qStart := i;  aln.rStart := j;
  ReverseCigar(aln);
  CalcIdentity(aln, q, r)
END Local;

(* ------------------------------------------------------------------ *)
(*  SemiGlobal — query free end-gaps                                   *)
(*  Query may overhang either end of the reference at no penalty.      *)
(* ------------------------------------------------------------------ *)

PROCEDURE SemiGlobal*(q, r: BioSeq.Seq; VAR m: ScoreMatrix; VAR aln: Alignment);
VAR
  qLen, rLen      : INTEGER;
  i, j, best, s   : INTEGER;
  bestJ, layer     : INTEGER;
  r0, r1           : INTEGER;
BEGIN
  qLen := BioSeq.Length(q);
  rLen := BioSeq.Length(r);
  ASSERT(qLen <= MaxSeqLen);
  ASSERT(rLen <= MaxSeqLen);
  EnsureDP(qLen, rLen);

  (* --- Initialisation --- *)
  dpM^[0] := 0;  dpX^[0] := NEG_INF;  dpY^[0] := NEG_INF;

  FOR i := 1 TO qLen DO
    r1 := i * dpStride;
    dpM^[r1] := NEG_INF;
    dpX^[r1] := m.gapOpen + i * m.gapExt;
    dpY^[r1] := NEG_INF;
    tbX^[r1] := tbFromX
  END;

  (* First row free: no penalty for reference advancing before query starts *)
  FOR j := 1 TO rLen DO
    dpM^[j] := NEG_INF;
    dpX^[j] := NEG_INF;
    dpY^[j] := 0;
    tbY^[j] := tbFromY
  END;

  (* --- Fill: identical recurrence to Global --- *)
  FOR i := 1 TO qLen DO
    r0 := (i - 1) * dpStride;
    r1 := i * dpStride;
    FOR j := 1 TO rLen DO
      s := PairScore(m, BioSeq.Get(q, i - 1), BioSeq.Get(r, j - 1));

      best := dpM^[r0 + j - 1];  tbM^[r1 + j] := tbFromM;
      IF dpX^[r0 + j - 1] > best THEN best := dpX^[r0 + j - 1];  tbM^[r1 + j] := tbFromX END;
      IF dpY^[r0 + j - 1] > best THEN best := dpY^[r0 + j - 1];  tbM^[r1 + j] := tbFromY END;
      dpM^[r1 + j] := best + s;

      IF dpM^[r0 + j] + m.gapOpen >= dpX^[r0 + j] + m.gapExt THEN
        dpX^[r1 + j] := dpM^[r0 + j] + m.gapOpen;  tbX^[r1 + j] := tbFromM
      ELSE
        dpX^[r1 + j] := dpX^[r0 + j] + m.gapExt;   tbX^[r1 + j] := tbFromX
      END;

      IF dpM^[r1 + j - 1] + m.gapOpen >= dpY^[r1 + j - 1] + m.gapExt THEN
        dpY^[r1 + j] := dpM^[r1 + j - 1] + m.gapOpen;  tbY^[r1 + j] := tbFromM
      ELSE
        dpY^[r1 + j] := dpY^[r1 + j - 1] + m.gapExt;   tbY^[r1 + j] := tbFromY
      END
    END
  END;

  (* --- Best score in last row: free trailing gap in reference --- *)
  r0 := qLen * dpStride;
  aln.score := dpM^[r0 + 1];  bestJ := 1;  layer := tbFromM;
  FOR j := 2 TO rLen DO
    IF dpM^[r0 + j] > aln.score THEN
      aln.score := dpM^[r0 + j];  bestJ := j;  layer := tbFromM
    END
  END;
  FOR j := 1 TO rLen DO
    IF dpX^[r0 + j] > aln.score THEN
      aln.score := dpX^[r0 + j];  bestJ := j;  layer := tbFromX
    END
  END;

  aln.qEnd   := qLen;  aln.rEnd   := bestJ;
  aln.qStart := 0;     aln.rStart := 0;
  aln.nOps   := 0;

  (* --- Traceback --- *)
  i := qLen;  j := bestJ;
  WHILE (i > 0) OR (j > 0) DO
    IF i = 0 THEN
      (* remaining reference: free leading overhang, done *)
      aln.rStart := j;
      j := 0
    ELSIF layer = tbFromM THEN
      IF BioSeq.Get(q, i - 1) = BioSeq.Get(r, j - 1) THEN
        AppendCigar(aln, opMatch)
      ELSE
        AppendCigar(aln, opSubst)
      END;
      layer := tbM^[i * dpStride + j];  DEC(i);  DEC(j)
    ELSIF layer = tbFromX THEN
      AppendCigar(aln, opIns);
      layer := tbX^[i * dpStride + j];  DEC(i)
    ELSE
      AppendCigar(aln, opDel);
      layer := tbY^[i * dpStride + j];  DEC(j)
    END
  END;

  ReverseCigar(aln);
  CalcIdentity(aln, q, r)
END SemiGlobal;

(* ------------------------------------------------------------------ *)
(*  EditDistance — Levenshtein (unit costs, O(n) space)               *)
(* ------------------------------------------------------------------ *)

PROCEDURE EditDistance*(q, r: BioSeq.Seq): INTEGER;
VAR
  qLen, rLen     : INTEGER;
  i, j           : INTEGER;
  diag, del, ins : INTEGER;
BEGIN
  qLen := BioSeq.Length(q);
  rLen := BioSeq.Length(r);
  ASSERT(qLen <= MaxSeqLen);
  ASSERT(rLen <= MaxSeqLen);

  FOR j := 0 TO rLen DO edPrev[j] := j END;

  FOR i := 1 TO qLen DO
    edCurr[0] := i;
    FOR j := 1 TO rLen DO
      IF BioSeq.Get(q, i - 1) = BioSeq.Get(r, j - 1) THEN
        diag := edPrev[j - 1]
      ELSE
        diag := edPrev[j - 1] + 1
      END;
      del := edPrev[j] + 1;
      ins := edCurr[j - 1] + 1;
      edCurr[j] := Math.min(diag, Math.min(del, ins))
    END;
    FOR j := 0 TO rLen DO edPrev[j] := edCurr[j] END
  END;
  RETURN edPrev[rLen]
END EditDistance;

(* ------------------------------------------------------------------ *)
(*  HammingDistance — equal-length sequences only                      *)
(* ------------------------------------------------------------------ *)

PROCEDURE HammingDistance*(q, r: BioSeq.Seq): INTEGER;
VAR i, dist, qLen: INTEGER;
BEGIN
  qLen := BioSeq.Length(q);
  IF qLen # BioSeq.Length(r) THEN RETURN -1 END;
  dist := 0;
  FOR i := 0 TO qLen - 1 DO
    IF BioSeq.Get(q, i) # BioSeq.Get(r, i) THEN INC(dist) END
  END;
  RETURN dist
END HammingDistance;

(* ------------------------------------------------------------------ *)
(*  PrintAlignment — pretty-print to stdout in 60-column blocks        *)
(* ------------------------------------------------------------------ *)

PROCEDURE PrintAlignment*(VAR aln: Alignment; q, r: BioSeq.Seq);
VAR
  pos, k, p, qi, ri, alen, stop : INTEGER;
BEGIN
  qi  := aln.qStart;
  ri  := aln.rStart;
  pos := 0;

  FOR k := 0 TO aln.nOps - 1 DO
    FOR p := 0 TO aln.cigar[k].len - 1 DO
      IF aln.cigar[k].op = opMatch THEN
        pqAln[pos] := BioSeq.Get(q, qi);
        prAln[pos] := BioSeq.Get(r, ri);
        pbar[pos]  := '|';
        INC(qi);  INC(ri)
      ELSIF aln.cigar[k].op = opSubst THEN
        pqAln[pos] := BioSeq.Get(q, qi);
        prAln[pos] := BioSeq.Get(r, ri);
        pbar[pos]  := '.';
        INC(qi);  INC(ri)
      ELSIF aln.cigar[k].op = opIns THEN
        pqAln[pos] := BioSeq.Get(q, qi);
        prAln[pos] := '-';
        pbar[pos]  := ' ';
        INC(qi)
      ELSE
        pqAln[pos] := '-';
        prAln[pos] := BioSeq.Get(r, ri);
        pbar[pos]  := ' ';
        INC(ri)
      END;
      INC(pos)
    END
  END;
  alen := pos;

  Out.String("Score:    "); Out.Int(aln.score, 0);                  Out.Ln;
  Out.String("Identity: "); Out.Fixed(aln.identity * 100.0, 0, 2);
  Out.Char('%');                                                     Out.Ln;
  Out.String("Query:    "); Out.Int(aln.qStart, 0);
  Out.String(" - ");        Out.Int(aln.qEnd, 0);                   Out.Ln;
  Out.String("Target:   "); Out.Int(aln.rStart, 0);
  Out.String(" - ");        Out.Int(aln.rEnd, 0);                   Out.Ln;
  Out.Ln;

  pos := 0;
  WHILE pos < alen DO
    stop := pos + PrintWidth - 1;
    IF stop >= alen THEN stop := alen - 1 END;

    Out.String("Query  ");
    FOR k := pos TO stop DO Out.Char(pqAln[k]) END;
    Out.Ln;

    Out.String("       ");
    FOR k := pos TO stop DO Out.Char(pbar[k]) END;
    Out.Ln;

    Out.String("Target ");
    FOR k := pos TO stop DO Out.Char(prAln[k]) END;
    Out.Ln;
    Out.Ln;

    INC(pos, PrintWidth)
  END
END PrintAlignment;

BEGIN
  dpM := NIL;  dpX := NIL;  dpY := NIL;
  tbM := NIL;  tbX := NIL;  tbY := NIL;
  dpStride := 0;  dpAlloc := 0
END BioAlign.
