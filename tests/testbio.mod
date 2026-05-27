MODULE TestBio;
(*
  Test suite for BioAlpha, BioSeq.
  Each ASSERT failure will abort with a C assert message identifying the line.
  All tests passing = silent exit with code 0.
*)
IMPORT BioSeq, BioAlpha, Out;

VAR
a    : BioAlpha.Alphabet;
s, t : BioSeq.Seq;
pass: INTEGER;

PROCEDURE Ok(label: ARRAY OF CHAR);
BEGIN
  INC(pass);
  Out.String("  PASS  "); Out.String(label); Out.Ln()
END Ok;

(* ------------------------------------------------------------------ *)
(*  1. Empty / Clear                                                    *)
(* ------------------------------------------------------------------ *)
PROCEDURE TestClear;
BEGIN
  Out.String("--- Clear ---"); Out.Ln();
  BioAlpha.Clear(a);
  ASSERT(a.size = 0);
  ASSERT(~BioAlpha.IsValid(a, 'A'));
  ASSERT(BioAlpha.Rank(a, 'A') = -1);
  ASSERT(BioAlpha.Symbol(a, 0) = 0X);
  Ok("empty alphabet")
END TestClear;

(* ------------------------------------------------------------------ *)
(*  2. Add and IsValid                                                  *)
(* ------------------------------------------------------------------ *)
PROCEDURE TestAdd;
BEGIN
  Out.String("--- Add / IsValid ---"); Out.Ln();
  BioAlpha.Clear(a);
  BioAlpha.Add(a, 'X', 'Y');
  BioAlpha.Add(a, 'Y', 'X');

  ASSERT(a.size = 2);
  ASSERT(BioAlpha.IsValid(a, 'X'));
  ASSERT(BioAlpha.IsValid(a, 'Y'));
  ASSERT(~BioAlpha.IsValid(a, 'Z'));
  Ok("Add two symbols");

  (* Adding same symbol twice must be a no-op *)
  BioAlpha.Add(a, 'X', 'Y');
  ASSERT(a.size = 2);
  Ok("duplicate Add is no-op")
END TestAdd;

(* ------------------------------------------------------------------ *)
(*  3. Complement                                                       *)
(* ------------------------------------------------------------------ *)
PROCEDURE TestComplement;
BEGIN
  Out.String("--- Complement ---"); Out.Ln();
  BioAlpha.DNA(a);

  ASSERT(BioAlpha.Complement(a, 'A') = 'T');
  ASSERT(BioAlpha.Complement(a, 'T') = 'A');
  ASSERT(BioAlpha.Complement(a, 'C') = 'G');
  ASSERT(BioAlpha.Complement(a, 'G') = 'C');
  Ok("DNA complements");

  (* Symbol not in alphabet -> 0X *)
  ASSERT(BioAlpha.Complement(a, 'N') = 0X);
  Ok("unknown symbol returns 0X")
END TestComplement;

(* ------------------------------------------------------------------ *)
(*  4. Rank and Symbol (round-trip)                                    *)
(* ------------------------------------------------------------------ *)
PROCEDURE TestRankSymbol;
VAR i: INTEGER; c: CHAR;
BEGIN
  Out.String("--- Rank / Symbol ---"); Out.Ln();
  BioAlpha.DNA(a);

  (* DNA adds A=0 C=1 G=2 T=3 in that order *)
  ASSERT(BioAlpha.Rank(a, 'A') = 0);
  ASSERT(BioAlpha.Rank(a, 'C') = 1);
  ASSERT(BioAlpha.Rank(a, 'G') = 2);
  ASSERT(BioAlpha.Rank(a, 'T') = 3);
  Ok("DNA ranks");

  ASSERT(BioAlpha.Symbol(a, 0) = 'A');
  ASSERT(BioAlpha.Symbol(a, 3) = 'T');
  ASSERT(BioAlpha.Symbol(a, 4) = 0X);   (* out of range *)
  ASSERT(BioAlpha.Symbol(a, -1) = 0X);  (* negative *)
  Ok("DNA symbols");

  (* Full round-trip for all symbols *)
  FOR i := 0 TO a.size - 1 DO
    c := BioAlpha.Symbol(a, i);
    ASSERT(BioAlpha.Rank(a, c) = i)
  END;
  Ok("Rank/Symbol round-trip")
END TestRankSymbol;

(* ------------------------------------------------------------------ *)
(*  5. DNA alphabet                                                     *)
(* ------------------------------------------------------------------ *)
PROCEDURE TestDNA;
BEGIN
  Out.String("--- DNA ---"); Out.Ln();
  BioAlpha.DNA(a);
  ASSERT(a.size = 4);
  ASSERT(BioAlpha.IsValid(a, 'A'));
  ASSERT(BioAlpha.IsValid(a, 'C'));
  ASSERT(BioAlpha.IsValid(a, 'G'));
  ASSERT(BioAlpha.IsValid(a, 'T'));
  ASSERT(~BioAlpha.IsValid(a, 'U'));
  ASSERT(~BioAlpha.IsValid(a, 'N'));
  Ok("DNA valid set");
  ASSERT(BioAlpha.Complement(a, 'A') = 'T');
  ASSERT(BioAlpha.Complement(a, 'C') = 'G');
  Ok("DNA complements")
END TestDNA;

(* ------------------------------------------------------------------ *)
(*  6. IUPAC alphabet                                                   *)
(* ------------------------------------------------------------------ *)
PROCEDURE TestIUPAC;
BEGIN
  Out.String("--- IUPAC ---"); Out.Ln();
  BioAlpha.DNAIUPAC(a);
  ASSERT(a.size = 15);
  ASSERT(BioAlpha.IsValid(a, 'N'));
  ASSERT(BioAlpha.IsValid(a, 'R'));
  ASSERT(~BioAlpha.IsValid(a, 'U'));
  Ok("IUPAC size and membership");

  ASSERT(BioAlpha.Complement(a, 'R') = 'Y');
  ASSERT(BioAlpha.Complement(a, 'Y') = 'R');
  ASSERT(BioAlpha.Complement(a, 'S') = 'S');
  ASSERT(BioAlpha.Complement(a, 'N') = 'N');
  ASSERT(BioAlpha.Complement(a, 'B') = 'V');
  ASSERT(BioAlpha.Complement(a, 'V') = 'B');
  Ok("IUPAC complements")
END TestIUPAC;

(* ------------------------------------------------------------------ *)
(*  7. RNA alphabet                                                     *)
(* ------------------------------------------------------------------ *)
PROCEDURE TestRNA;
BEGIN
  Out.String("--- RNA ---"); Out.Ln();
  BioAlpha.RNA(a);
  ASSERT(a.size = 4);
  ASSERT(BioAlpha.IsValid(a, 'U'));
  ASSERT(~BioAlpha.IsValid(a, 'T'));
  ASSERT(BioAlpha.Complement(a, 'A') = 'U');
  ASSERT(BioAlpha.Complement(a, 'U') = 'A');
  Ok("RNA alphabet")
END TestRNA;

(* ------------------------------------------------------------------ *)
(*  8. Protein alphabet                                                 *)
(* ------------------------------------------------------------------ *)
PROCEDURE TestProtein;
BEGIN
  Out.String("--- Protein ---"); Out.Ln();
  BioAlpha.Protein(a);
  ASSERT(a.size = 21);  (* 20 AA + stop *)
  ASSERT(BioAlpha.IsValid(a, 'M'));
  ASSERT(BioAlpha.IsValid(a, '*'));
  ASSERT(~BioAlpha.IsValid(a, 'B'));  (* not a standard AA *)
  (* No complements *)
  ASSERT(BioAlpha.Complement(a, 'A') = 0X);
  Ok("Protein alphabet")
END TestProtein;

(* ------------------------------------------------------------------ *)
(*  9. Utility predicates                                               *)
(* ------------------------------------------------------------------ *)
PROCEDURE TestPredicates;
BEGIN
  Out.String("--- Predicates ---"); Out.Ln();
  ASSERT(BioAlpha.IsDNABase('A'));
  ASSERT(BioAlpha.IsDNABase('C'));
  ASSERT(~BioAlpha.IsDNABase('U'));
  ASSERT(~BioAlpha.IsDNABase('N'));
  Ok("IsDNABase");

  ASSERT(BioAlpha.IsRNABase('U'));
  ASSERT(~BioAlpha.IsRNABase('T'));
  Ok("IsRNABase");

  ASSERT(BioAlpha.IsAmbiguous('N'));
  ASSERT(BioAlpha.IsAmbiguous('R'));
  ASSERT(~BioAlpha.IsAmbiguous('A'));
  Ok("IsAmbiguous");

  ASSERT(BioAlpha.ToUpper('a') = 'A');
  ASSERT(BioAlpha.ToUpper('z') = 'Z');
  ASSERT(BioAlpha.ToUpper('A') = 'A');
  ASSERT(BioAlpha.ToUpper('1') = '1');
  Ok("ToUpper")
END TestPredicates;

(* ------------------------------------------------------------------ *)
(*  10. Matches — exact and IUPAC                                      *)
(* ------------------------------------------------------------------ *)
PROCEDURE TestMatches;
BEGIN
  Out.String("--- IUPACBits ---"); Out.Ln();
  ASSERT(BioAlpha.IUPACBits('A') = {0});
  ASSERT(BioAlpha.IUPACBits('R') = {0, 2});
  ASSERT(BioAlpha.IUPACBits('N') = {0, 1, 2, 3});
  ASSERT(BioAlpha.IUPACBits('B') = {1, 2, 3});
  ASSERT(BioAlpha.IUPACBits('?') = {});
  Ok("IUPACBits");

  Out.String("--- Matches ---"); Out.Ln();

  BioAlpha.DNA(a);
  ASSERT(BioAlpha.Matches(a, 'A', 'A'));
  ASSERT(~BioAlpha.Matches(a, 'A', 'C'));
  ASSERT(~BioAlpha.Matches(a, 'N', 'A'));  (* N not in plain DNA *)
  Ok("Matches exact DNA");

  BioAlpha.DNAIUPAC(a);
  ASSERT(BioAlpha.Matches(a, 'A', 'A'));
  ASSERT(BioAlpha.Matches(a, 'N', 'A'));   (* N matches anything *)
  ASSERT(BioAlpha.Matches(a, 'R', 'A'));   (* R = A|G, matches A *)
  ASSERT(BioAlpha.Matches(a, 'R', 'G'));   (* R = A|G, matches G *)
  ASSERT(~BioAlpha.Matches(a, 'R', 'C')); (* R = A|G, not C *)
  ASSERT(BioAlpha.Matches(a, 'S', 'G'));   (* S = G|C *)
  ASSERT(BioAlpha.Matches(a, 'B', 'C'));   (* B = C|G|T *)
  ASSERT(~BioAlpha.Matches(a, 'B', 'A')); (* B excludes A *)
  Ok("Matches IUPAC ambiguity")
END TestMatches;

(* ------------------------------------------------------------------ *)
(*  11. Print (visual check only)                                      *)
(* ------------------------------------------------------------------ *)
PROCEDURE TestPrint;
BEGIN
  Out.String("--- Print (visual) ---"); Out.Ln();
  BioAlpha.DNA(a);
  BioAlpha.Print(a);
  Ok("Print DNA")
END TestPrint;

(* ------------------------------------------------------------------ *)
(*  1. New / Free / Length                                              *)
(* ------------------------------------------------------------------ *)
PROCEDURE TestNew;
BEGIN
  Out.String("--- New / Free / Length ---"); Out.Ln();
  BioSeq.New(s);
  ASSERT(s # NIL);
  ASSERT(BioSeq.Length(s) = 0);
  ASSERT(BioSeq.Get(s, 0) = 0X);
  Ok("New gives empty seq");
  BioSeq.Free(s);
  ASSERT(s = NIL);
  Ok("Free sets pointer to NIL")
END TestNew;

(* ------------------------------------------------------------------ *)
(*  2. Append / Length / Get                                            *)
(* ------------------------------------------------------------------ *)
PROCEDURE TestAppend;
VAR buf: ARRAY 256 OF CHAR;
BEGIN
  Out.String("--- Append / Get ---"); Out.Ln();
  BioSeq.New(s);

  buf := "ACGT";
  BioSeq.Append(s, buf, 4);
  ASSERT(BioSeq.Length(s) = 4);
  ASSERT(BioSeq.Get(s, 0) = 'A');
  ASSERT(BioSeq.Get(s, 1) = 'C');
  ASSERT(BioSeq.Get(s, 2) = 'G');
  ASSERT(BioSeq.Get(s, 3) = 'T');
  ASSERT(BioSeq.Get(s, 4) = 0X);   (* out of range *)
  ASSERT(BioSeq.Get(s, -1) = 0X);  (* negative *)
  Ok("Append 4 chars, Get each");

  (* Append more to force chunk boundary crossing.
     ChunkSize = 240; fill past it. *)
  buf := "GGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGG"; (* 50 G *)
  WHILE BioSeq.Length(s) < 250 DO
    BioSeq.Append(s, buf, 50)
  END;
  ASSERT(BioSeq.Length(s) >= 250);
  ASSERT(BioSeq.Get(s, 240) # 0X);   (* crosses chunk boundary *)
  Ok("Append across chunk boundary");

  BioSeq.Free(s)
END TestAppend;

(* ------------------------------------------------------------------ *)
(*  3. FromStr / ToStr                                                  *)
(* ------------------------------------------------------------------ *)
PROCEDURE TestFromToStr;
VAR buf: ARRAY 256 OF CHAR;
BEGIN
  Out.String("--- FromStr / ToStr ---"); Out.Ln();
  BioSeq.New(s);

  BioSeq.FromStr(s, "ACGTAGCT");
  ASSERT(BioSeq.Length(s) = 8);
  BioSeq.ToStr(s, buf);
  ASSERT(buf = "ACGTAGCT");
  Ok("FromStr / ToStr round-trip");

  (* FromStr clears existing content *)
  BioSeq.FromStr(s, "TTTT");
  ASSERT(BioSeq.Length(s) = 4);
  BioSeq.ToStr(s, buf);
  ASSERT(buf = "TTTT");
  Ok("FromStr clears previous content");

  BioSeq.Free(s)
END TestFromToStr;

(* ------------------------------------------------------------------ *)
(*  4. Slice                                                            *)
(* ------------------------------------------------------------------ *)
PROCEDURE TestSlice;
VAR buf: ARRAY 32 OF CHAR;
BEGIN
  Out.String("--- Slice ---"); Out.Ln();
  BioSeq.New(s);
  BioSeq.FromStr(s, "ACGTACGT");

  BioSeq.Slice(s, 0, 4, buf);
  ASSERT(buf = "ACGT");
  Ok("Slice first 4");

  BioSeq.Slice(s, 4, 4, buf);
  ASSERT(buf = "ACGT");
  Ok("Slice last 4");

  BioSeq.Slice(s, 2, 4, buf);
  ASSERT(buf = "GTAC");
  Ok("Slice middle");

  (* Slice past end — should clamp *)
  BioSeq.Slice(s, 6, 10, buf);
  ASSERT(buf = "GT");
  Ok("Slice clamped to end");

  (* Out of range start *)
  BioSeq.Slice(s, 100, 4, buf);
  ASSERT(buf[0] = 0X);
  Ok("Slice out-of-range returns empty");

  BioSeq.Free(s)
END TestSlice;

(* ------------------------------------------------------------------ *)
(*  5. ToUpper / ToLower                                                *)
(* ------------------------------------------------------------------ *)
PROCEDURE TestCase;
VAR buf: ARRAY 32 OF CHAR;
BEGIN
  Out.String("--- ToUpper / ToLower ---"); Out.Ln();
  BioSeq.New(s);
  BioSeq.FromStr(s, "acgtACGT");
  BioSeq.ToUpper(s);
  BioSeq.ToStr(s, buf);
  ASSERT(buf = "ACGTACGT");
  Ok("ToUpper");

  BioSeq.ToLower(s);
  BioSeq.ToStr(s, buf);
  ASSERT(buf = "acgtacgt");
  Ok("ToLower");

  BioSeq.Free(s)
END TestCase;

(* ------------------------------------------------------------------ *)
(*  6. Count / GCContent                                                *)
(* ------------------------------------------------------------------ *)
PROCEDURE TestStats;
VAR gc: REAL;
BEGIN
  Out.String("--- Count / GCContent ---"); Out.Ln();
  BioSeq.New(s);
  BioSeq.FromStr(s, "AACGTT");   (* 2 G/C out of 6 *)

  ASSERT(BioSeq.Count(s, 'A') = 2);
  ASSERT(BioSeq.Count(s, 'C') = 1);
  ASSERT(BioSeq.Count(s, 'G') = 1);
  ASSERT(BioSeq.Count(s, 'T') = 2);
  ASSERT(BioSeq.Count(s, 'N') = 0);
  Ok("Count each base");

  gc := BioSeq.GCContent(s);
  (* 2/6 = 0.3333... allow small epsilon *)
  ASSERT((gc > 0.332) & (gc < 0.334));
  Ok("GCContent 2/6");

  BioSeq.Free(s)
END TestStats;

(* ------------------------------------------------------------------ *)
(*  7. Equal                                                            *)
(* ------------------------------------------------------------------ *)
PROCEDURE TestEqual;
BEGIN
  Out.String("--- Equal ---"); Out.Ln();
  BioSeq.New(s);
  BioSeq.New(t);

  BioSeq.FromStr(s, "ACGT");
  BioSeq.FromStr(t, "ACGT");
  ASSERT(BioSeq.Equal(s, t));
  Ok("Equal identical seqs");

  BioSeq.FromStr(t, "ACGG");
  ASSERT(~BioSeq.Equal(s, t));
  Ok("Not equal different last char");

  BioSeq.FromStr(t, "ACG");
  ASSERT(~BioSeq.Equal(s, t));
  Ok("Not equal different length");

  BioSeq.Free(s);
  BioSeq.Free(t)
END TestEqual;

(* ------------------------------------------------------------------ *)
(*  8. RevComp                                                          *)
(* ------------------------------------------------------------------ *)
PROCEDURE TestRevComp;
VAR a: BioAlpha.Alphabet;
buf: ARRAY 64 OF CHAR;
BEGIN
  Out.String("--- RevComp ---"); Out.Ln();
  BioAlpha.DNA(a);
  BioSeq.New(s);
  BioSeq.New(t);

  (* RevComp of ACGT = ACGT (palindrome) *)
  BioSeq.FromStr(s, "ACGT");
  BioSeq.RevComp(s, a, t);
  BioSeq.ToStr(t, buf);
  ASSERT(buf = "ACGT");
  Ok("RevComp of ACGT palindrome");

  (* RevComp of AAAA = TTTT *)
  BioSeq.FromStr(s, "AAAA");
  BioSeq.RevComp(s, a, t);
  BioSeq.ToStr(t, buf);
  ASSERT(buf = "TTTT");
  Ok("RevComp AAAA = TTTT");

  (* RevComp of AACCGGTT = AACCGGTT (palindrome) *)
  BioSeq.FromStr(s, "AACCGGTT");
  BioSeq.RevComp(s, a, t);
  BioSeq.ToStr(t, buf);
  ASSERT(buf = "AACCGGTT");
  Ok("RevComp AACCGGTT palindrome");

  (* RevComp of ATCG = CGAT *)
  BioSeq.FromStr(s, "ATCG");
  BioSeq.RevComp(s, a, t);
  BioSeq.ToStr(t, buf);
  ASSERT(buf = "CGAT");
  Ok("RevComp ATCG = CGAT");

  (* Length preserved *)
  ASSERT(BioSeq.Length(t) = BioSeq.Length(s));
  Ok("RevComp preserves length");

  BioSeq.Free(s);
  BioSeq.Free(t)
END TestRevComp;

(* ------------------------------------------------------------------ *)
(*  9. Print Seq (visual)                                             *)
(* ------------------------------------------------------------------ *)
PROCEDURE TestPrintSeq;
VAR buf: ARRAY 256 OF CHAR; i: INTEGER;
BEGIN
  Out.String("--- Print (visual) ---"); Out.Ln();
  BioSeq.New(s);
  s.name := "TestSeq";
  (* Build a 120-char sequence to test line wrapping *)
  buf := "ACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGT"; (* 60 *)
  BioSeq.Append(s, buf, 60);
  BioSeq.Append(s, buf, 60);
  BioSeq.Print(s);
  ASSERT(BioSeq.Length(s) = 120);
  BioSeq.Free(s);
  Out.String("  PASS  Print"); Out.Ln();
  INC(pass)
END TestPrintSeq;

(* ------------------------------------------------------------------ *)
(*  Main                                                                *)
(* ------------------------------------------------------------------ *)
BEGIN
  pass := 0;
  Out.String("=== BioAlpha tests ==="); Out.Ln();
  TestClear;
  TestAdd;
  TestComplement;
  TestRankSymbol;
  TestDNA;
  TestIUPAC;
  TestRNA;
  TestProtein;
  TestPredicates;
  TestMatches;
  TestPrint;
  Out.String("=== BioSeq tests ==="); Out.Ln();
  TestNew;
  TestAppend;
  TestFromToStr;
  TestSlice;
  TestCase;
  TestStats;
  TestEqual;
  TestRevComp;
  TestPrintSeq;
  Out.Ln();
  Out.String("All "); Out.Int(pass); Out.String(" tests passed."); Out.Ln()
END TestBio.

