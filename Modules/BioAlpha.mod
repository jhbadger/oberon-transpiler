MODULE BioAlpha;

IMPORT Out;
(*
  BioAlpha — Alphabet definitions for bioinformatics sequences.
  Supports DNA, RNA, Protein, and IUPAC alphabets.
  All other Bio modules that need alphabet awareness import this one.

  Design notes:
    - validArr[ORD(c)] = TRUE  means c is in the alphabet.
    - comp[ORD(c)] holds the complement of c (0X = no complement defined).
    - symbols[] lists valid chars in rank order (populated by Add).
    - Rank() returns the 0-based index of c within symbols[]; -1 if invalid.
    - Symbol() is the inverse of Rank().
    - All character comparisons are case-sensitive; constructors use uppercase.
      Call BioAlpha.ToUpper before querying if your input may be mixed case.
*)

CONST
MaxAlpha* = 128;   (* covers full 7-bit ASCII *)

TYPE
Alphabet* = RECORD
  validArr : ARRAY MaxAlpha OF BOOLEAN;
  comp     : ARRAY MaxAlpha OF CHAR;
  symbols  : ARRAY MaxAlpha OF CHAR;   (* valid chars in insertion order *)
  size*    : INTEGER                   (* number of valid symbols *)
END;

(* ------------------------------------------------------------------ *)
(*  Internal helpers                                                    *)
(* ------------------------------------------------------------------ *)

PROCEDURE Clear*(VAR a: Alphabet);
(* Reset to an empty alphabet. *)
VAR i: INTEGER;
BEGIN
  a.size := 0;
  FOR i := 0 TO MaxAlpha - 1 DO
    a.validArr[i] := FALSE;
    a.comp[i]     := 0X;
    a.symbols[i]  := 0X
  END
END Clear;

(* ------------------------------------------------------------------ *)
(*  Core operations                                                     *)
(* ------------------------------------------------------------------ *)

PROCEDURE Add*(VAR a: Alphabet; c, complement: CHAR);
(*
    Add character c to the alphabet with the given complement.
    Pass 0X as complement if c has no complement (e.g. amino acids).
    No-op if c is already present or ORD(c) >= MaxAlpha.
  *)
VAR k: INTEGER;
BEGIN
  k := ORD(c);
  IF (k < MaxAlpha) & ~a.validArr[k] THEN
    a.validArr[k]       := TRUE;
    a.comp[k]           := complement;
    a.symbols[a.size]   := c;
    INC(a.size)
  END
END Add;

PROCEDURE IsValid*(VAR a: Alphabet; c: CHAR): BOOLEAN;
BEGIN
  RETURN (ORD(c) < MaxAlpha) & a.validArr[ORD(c)]
END IsValid;

PROCEDURE Complement*(VAR a: Alphabet; c: CHAR): CHAR;
(* Returns the complement of c, or 0X if none is defined. *)
BEGIN
  IF (ORD(c) < MaxAlpha) & a.validArr[ORD(c)] THEN
    RETURN a.comp[ORD(c)]
  ELSE
    RETURN 0X
  END
END Complement;

PROCEDURE Rank*(VAR a: Alphabet; c: CHAR): INTEGER;
(*
    Returns the 0-based rank of c within the alphabet's symbol list,
    i.e. the order in which it was added via Add().
    Returns -1 if c is not in the alphabet.
  *)
VAR i: INTEGER;
BEGIN
  IF (ORD(c) >= MaxAlpha) OR ~a.validArr[ORD(c)] THEN
    RETURN -1
  END;
  i := 0;
  WHILE (i < a.size) & (a.symbols[i] # c) DO INC(i) END;
  IF i < a.size THEN RETURN i ELSE RETURN -1 END
END Rank;

PROCEDURE Symbol*(VAR a: Alphabet; rank: INTEGER): CHAR;
(*
    Returns the symbol at position rank (0-based).
    Returns 0X if rank is out of range.
  *)
BEGIN
  IF (rank >= 0) & (rank < a.size) THEN
    RETURN a.symbols[rank]
  ELSE
    RETURN 0X
  END
END Symbol;

PROCEDURE ToUpper*(c: CHAR): CHAR;
(* Convenience: uppercase a single character. *)
BEGIN
  IF (c >= 'a') & (c <= 'z') THEN
    RETURN CHR(ORD(c) - 32)
  ELSE
    RETURN c
  END
END ToUpper;

(* ------------------------------------------------------------------ *)
(*  Predefined alphabet constructors                                    *)
(* ------------------------------------------------------------------ *)

PROCEDURE DNA*(VAR a: Alphabet);
(*
    Standard unambiguous DNA alphabet: A C G T
    Complements: A<->T, C<->G
  *)
BEGIN
  Clear(a);
  Add(a, 'A', 'T');
  Add(a, 'C', 'G');
  Add(a, 'G', 'C');
  Add(a, 'T', 'A')
END DNA;

PROCEDURE DNAIUPAC*(VAR a: Alphabet);
(*
    IUPAC ambiguity codes for DNA.
    A C G T R Y S W K M B D H V N
    Complements follow IUPAC convention:
      A<->T  C<->G  R<->Y  S<->S  W<->W
      K<->M  B<->V  D<->H  N<->N
  *)
BEGIN
  Clear(a);
  (* Unambiguous *)
  Add(a, 'A', 'T');
  Add(a, 'C', 'G');
  Add(a, 'G', 'C');
  Add(a, 'T', 'A');
  (* Two-symbol codes *)
  Add(a, 'R', 'Y');   (* A or G  <->  C or T *)
  Add(a, 'Y', 'R');   (* C or T  <->  A or G *)
  Add(a, 'S', 'S');   (* G or C  <->  G or C *)
  Add(a, 'W', 'W');   (* A or T  <->  A or T *)
  Add(a, 'K', 'M');   (* G or T  <->  A or C *)
  Add(a, 'M', 'K');   (* A or C  <->  G or T *)
  (* Three-symbol codes *)
  Add(a, 'B', 'V');   (* C G T   <->  A C G  *)
  Add(a, 'D', 'H');   (* A G T   <->  A C T  *)
  Add(a, 'H', 'D');   (* A C T   <->  A G T  *)
  Add(a, 'V', 'B');   (* A C G   <->  C G T  *)
  (* Any *)
  Add(a, 'N', 'N')    (* any     <->  any    *)
END DNAIUPAC;

PROCEDURE RNA*(VAR a: Alphabet);
(*
    Standard RNA alphabet: A C G U
    Complements: A<->U, C<->G
  *)
BEGIN
  Clear(a);
  Add(a, 'A', 'U');
  Add(a, 'C', 'G');
  Add(a, 'G', 'C');
  Add(a, 'U', 'A')
END RNA;

PROCEDURE Protein*(VAR a: Alphabet);
(*
    Standard protein alphabet: 20 canonical amino acids + stop codon *.
    No complements defined (all set to 0X).
    Symbols in standard single-letter code order.
  *)
BEGIN
  Clear(a);
  Add(a, 'A', 0X);   (* Alanine        *)
  Add(a, 'C', 0X);   (* Cysteine       *)
  Add(a, 'D', 0X);   (* Aspartate      *)
  Add(a, 'E', 0X);   (* Glutamate      *)
  Add(a, 'F', 0X);   (* Phenylalanine  *)
  Add(a, 'G', 0X);   (* Glycine        *)
  Add(a, 'H', 0X);   (* Histidine      *)
  Add(a, 'I', 0X);   (* Isoleucine     *)
  Add(a, 'K', 0X);   (* Lysine         *)
  Add(a, 'L', 0X);   (* Leucine        *)
  Add(a, 'M', 0X);   (* Methionine     *)
  Add(a, 'N', 0X);   (* Asparagine     *)
  Add(a, 'P', 0X);   (* Proline        *)
  Add(a, 'Q', 0X);   (* Glutamine      *)
  Add(a, 'R', 0X);   (* Arginine       *)
  Add(a, 'S', 0X);   (* Serine         *)
  Add(a, 'T', 0X);   (* Threonine      *)
  Add(a, 'V', 0X);   (* Valine         *)
  Add(a, 'W', 0X);   (* Tryptophan     *)
  Add(a, 'Y', 0X);   (* Tyrosine       *)
  Add(a, '*', 0X)    (* Stop codon symbol *)
END Protein;

(* ------------------------------------------------------------------ *)
(*  Utility predicates                                                  *)
(* ------------------------------------------------------------------ *)

PROCEDURE IsDNABase*(c: CHAR): BOOLEAN;
(* Quick test without constructing an alphabet record. *)
BEGIN
  RETURN (c = 'A') OR (c = 'C') OR (c = 'G') OR (c = 'T')
END IsDNABase;

PROCEDURE IsRNABase*(c: CHAR): BOOLEAN;
BEGIN
  RETURN (c = 'A') OR (c = 'C') OR (c = 'G') OR (c = 'U')
END IsRNABase;

PROCEDURE IsAmbiguous*(c: CHAR): BOOLEAN;
(* TRUE for IUPAC codes that represent more than one base. *)
BEGIN
  RETURN (c = 'R') OR (c = 'Y') OR (c = 'S') OR (c = 'W') OR
  (c = 'K') OR (c = 'M') OR (c = 'B') OR (c = 'D') OR
  (c = 'H') OR (c = 'V') OR (c = 'N')
END IsAmbiguous;

(* Expand an IUPAC code to a 4-bit SET: bit 0=A  1=C  2=G  3=T/U
     Used by Matches; defined at module level to avoid nested-proc issues. *)
(* Return a bitmask for an IUPAC base code as INTEGER.
     bit 0 = A, bit 1 = C, bit 2 = G, bit 3 = T/U.
     Using INTEGER instead of SET avoids a transpiler type-inference bug
     where SET return values are mishandled on assignment. *)
PROCEDURE IUPACBits*(c: CHAR): INTEGER;
BEGIN
  CASE c OF
    'A':           RETURN 1
    | 'C':           RETURN 2
    | 'G':           RETURN 4
    | 'T', 'U':      RETURN 8
    | 'R':           RETURN 5    (* A|G *)
    | 'Y':           RETURN 10   (* C|T *)
    | 'S':           RETURN 6    (* G|C *)
    | 'W':           RETURN 9    (* A|T *)
    | 'K':           RETURN 12   (* G|T *)
    | 'M':           RETURN 3    (* A|C *)
    | 'B':           RETURN 14   (* C|G|T *)
    | 'D':           RETURN 13   (* A|G|T *)
    | 'H':           RETURN 11   (* A|C|T *)
    | 'V':           RETURN 7    (* A|C|G *)
    | 'N':           RETURN 15   (* all *)
  ELSE             RETURN 0
END
END IUPACBits;

PROCEDURE Matches*(VAR a: Alphabet; query, ref: CHAR): BOOLEAN;
(*
    Returns TRUE if query is consistent with ref under the alphabet.
    For unambiguous alphabets this is just equality.
    For IUPAC codes, expands both to INTEGER bitmasks and tests for
    non-zero intersection using plain integer arithmetic.
  *)
BEGIN
  IF ~IsValid(a, query) OR ~IsValid(a, ref) THEN RETURN FALSE END;
  IF IsAmbiguous(query) OR IsAmbiguous(ref) THEN
    RETURN (IUPACBits(query) MOD 2 = 1) & (IUPACBits(ref) MOD 2 = 1) OR    (* A *)
    (IUPACBits(query) DIV 2 MOD 2 = 1) & (IUPACBits(ref) DIV 2 MOD 2 = 1) OR  (* C *)
    (IUPACBits(query) DIV 4 MOD 2 = 1) & (IUPACBits(ref) DIV 4 MOD 2 = 1) OR  (* G *)
    (IUPACBits(query) DIV 8 MOD 2 = 1) & (IUPACBits(ref) DIV 8 MOD 2 = 1)     (* T *)
  ELSE
    RETURN query = ref
  END
END Matches;

(* ------------------------------------------------------------------ *)
(*  Debugging / display                                                 *)
(* ------------------------------------------------------------------ *)

PROCEDURE Print*(VAR a: Alphabet);
(*
    Print the alphabet's symbols and their complements to stdout.
    Useful during development and testing.
  *)
VAR i: INTEGER; c, k: CHAR;
BEGIN
  Out.String("Alphabet ("); Out.Int(a.size); Out.String(" symbols):"); Out.Ln();
  FOR i := 0 TO a.size - 1 DO
    c := a.symbols[i];
    k := a.comp[ORD(c)];
    Out.String("  ");
    Out.Char(c);
    Out.String("  comp=");
    IF k = 0X THEN Out.String("none") ELSE Out.Char(k) END;
    Out.String("  rank="); Out.Int(i);
    Out.Ln()
  END
END Print;
END BioAlpha.


