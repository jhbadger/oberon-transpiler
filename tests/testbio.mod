MODULE TestBio;
(*
  Test suite for BioAlpha, BioSeq, BioIO, and BioAlign.
  Each ASSERT failure will abort with a C assert message identifying the line.
  All tests passing = silent exit with code 0.
*)
IMPORT BioSeq, BioAlpha, BioAlign, BioIO, BioPattern, Files, Strings, Out;

VAR
  a    : BioAlpha.Alphabet;
  s, t : BioSeq.Seq;
  pass : INTEGER;
  (* BioPattern module-level state: ACState (~2 MB) and HitList (~768 KB)
     are too large for the stack and must live here. *)
  hits : BioPattern.HitList;
  acSt : BioPattern.ACState;

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

(* ================================================================== *)
(*  BioIO helpers — write raw bytes to a rider                         *)
(* ================================================================== *)

PROCEDURE WriteRaw(VAR r: Files.Rider; str: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (i < LEN(str)) & (str[i] # 0X) DO Files.Write(r, ORD(str[i])); INC(i) END
END WriteRaw;

PROCEDURE WriteLF(VAR r: Files.Rider);
BEGIN Files.Write(r, 10) END WriteLF;

PROCEDURE WriteTab(VAR r: Files.Rider);
BEGIN Files.Write(r, 9) END WriteTab;

PROCEDURE WriteIntRaw(VAR r: Files.Rider; n: INTEGER);
VAR buf: ARRAY 16 OF CHAR;
BEGIN Strings.IntToStr(n, buf); WriteRaw(r, buf) END WriteIntRaw;

(* ================================================================== *)
(*  BioIO tests                                                         *)
(* ================================================================== *)

(* ------------------------------------------------------------------ *)
(*  B1. Open missing file                                               *)
(* ------------------------------------------------------------------ *)
PROCEDURE TestOpenMissing;
VAR fr: BioIO.FastaReader; qr: BioIO.FastqReader; br: BioIO.BedReader;
BEGIN
  Out.String("--- Open missing file ---"); Out.Ln();
  ASSERT(~BioIO.OpenFasta(fr, "__no_such_file__.fasta"));
  ASSERT(fr.done);
  Ok("OpenFasta missing -> FALSE");

  ASSERT(~BioIO.OpenFastq(qr, "__no_such_file__.fastq"));
  ASSERT(qr.done);
  Ok("OpenFastq missing -> FALSE");

  ASSERT(~BioIO.OpenBed(br, "__no_such_file__.bed"));
  ASSERT(br.done);
  Ok("OpenBed missing -> FALSE")
END TestOpenMissing;

(* ------------------------------------------------------------------ *)
(*  B2. FASTA round-trip: two records, one with description            *)
(* ------------------------------------------------------------------ *)
PROCEDURE TestFastaRoundTrip;
VAR
  f   : Files.File;
  wr  : Files.Rider;
  rdr : BioIO.FastaReader;
  wrec, rrec : BioIO.FastaRecord;
  buf : ARRAY 256 OF CHAR;
BEGIN
  Out.String("--- FASTA round-trip ---"); Out.Ln();

  (* Write two FASTA records *)
  f := Files.New("testbio_fasta.tmp");
  ASSERT(f # NIL);
  Files.Set(wr, f, 0);

  wrec.name := "seq1";
  wrec.desc := "first sequence";
  BioSeq.New(wrec.seq);
  BioSeq.FromStr(wrec.seq, "ACGTACGT");
  BioIO.WriteFasta(wr, wrec, 60);

  wrec.name := "seq2";
  wrec.desc := "";
  BioSeq.FromStr(wrec.seq, "TTTTAAAA");
  BioIO.WriteFasta(wr, wrec, 60);

  Files.Register(f);
  Files.Close(f);
  BioSeq.Free(wrec.seq);

  (* Read back *)
  ASSERT(BioIO.OpenFasta(rdr, "testbio_fasta.tmp"));
  Ok("OpenFasta succeeds");

  rrec.seq := NIL;
  ASSERT(BioIO.ReadFasta(rdr, rrec));
  ASSERT(rrec.name = "seq1");
  ASSERT(rrec.desc = "first sequence");
  ASSERT(BioSeq.Length(rrec.seq) = 8);
  BioSeq.ToStr(rrec.seq, buf);
  ASSERT(buf = "ACGTACGT");
  Ok("ReadFasta record 1 name/desc/seq");

  ASSERT(BioIO.ReadFasta(rdr, rrec));
  ASSERT(rrec.name = "seq2");
  ASSERT(rrec.desc[0] = 0X);   (* no description *)
  ASSERT(BioSeq.Length(rrec.seq) = 8);
  BioSeq.ToStr(rrec.seq, buf);
  ASSERT(buf = "TTTTAAAA");
  Ok("ReadFasta record 2 no-desc");

  ASSERT(~BioIO.ReadFasta(rdr, rrec));
  Ok("ReadFasta EOF returns FALSE");

  BioIO.CloseFasta(rdr);
  BioSeq.Free(rrec.seq)
END TestFastaRoundTrip;

(* ------------------------------------------------------------------ *)
(*  B3. FASTA multi-line sequence reconstruction                        *)
(* ------------------------------------------------------------------ *)
PROCEDURE TestFastaMultiLine;
VAR
  f   : Files.File;
  wr  : Files.Rider;
  rdr : BioIO.FastaReader;
  wrec, rrec : BioIO.FastaRecord;
  buf : ARRAY 32 OF CHAR;
BEGIN
  Out.String("--- FASTA multi-line ---"); Out.Ln();

  (* Build a 90-char sequence: 30 A + 30 C + 30 G *)
  BioSeq.New(wrec.seq);
  BioSeq.FromStr(wrec.seq, "");
  buf := "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";   (* 30 A *)
  BioSeq.Append(wrec.seq, buf, 30);
  buf := "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC";   (* 30 C *)
  BioSeq.Append(wrec.seq, buf, 30);
  buf := "GGGGGGGGGGGGGGGGGGGGGGGGGGGGGG";   (* 30 G *)
  BioSeq.Append(wrec.seq, buf, 30);
  ASSERT(BioSeq.Length(wrec.seq) = 90);

  wrec.name := "longseq";
  wrec.desc := "";

  (* Write with width=30 -> 3 lines in the file *)
  f := Files.New("testbio_fastaml.tmp");
  ASSERT(f # NIL);
  Files.Set(wr, f, 0);
  BioIO.WriteFasta(wr, wrec, 30);
  Files.Register(f);
  Files.Close(f);
  BioSeq.Free(wrec.seq);

  (* Read back: multi-line sequence must be reassembled *)
  ASSERT(BioIO.OpenFasta(rdr, "testbio_fastaml.tmp"));
  rrec.seq := NIL;
  ASSERT(BioIO.ReadFasta(rdr, rrec));
  ASSERT(rrec.name = "longseq");
  ASSERT(BioSeq.Length(rrec.seq) = 90);
  ASSERT(BioSeq.Get(rrec.seq, 0)  = 'A');
  ASSERT(BioSeq.Get(rrec.seq, 29) = 'A');
  ASSERT(BioSeq.Get(rrec.seq, 30) = 'C');
  ASSERT(BioSeq.Get(rrec.seq, 59) = 'C');
  ASSERT(BioSeq.Get(rrec.seq, 60) = 'G');
  ASSERT(BioSeq.Get(rrec.seq, 89) = 'G');
  Ok("multi-line FASTA length and spot chars");

  ASSERT(~BioIO.ReadFasta(rdr, rrec));
  Ok("multi-line FASTA EOF");

  BioIO.CloseFasta(rdr);
  BioSeq.Free(rrec.seq)
END TestFastaMultiLine;

(* ------------------------------------------------------------------ *)
(*  B4. FASTQ round-trip                                                *)
(* ------------------------------------------------------------------ *)
PROCEDURE TestFastqRoundTrip;
VAR
  f   : Files.File;
  wr  : Files.Rider;
  rdr : BioIO.FastqReader;
  wrec, rrec : BioIO.FastqRecord;
  buf : ARRAY 256 OF CHAR;
BEGIN
  Out.String("--- FASTQ round-trip ---"); Out.Ln();

  BioSeq.New(wrec.seq);
  BioSeq.New(wrec.qual);

  f := Files.New("testbio_fastq.tmp");
  ASSERT(f # NIL);
  Files.Set(wr, f, 0);

  wrec.name := "read1";
  BioSeq.FromStr(wrec.seq,  "ACGTACGT");
  BioSeq.FromStr(wrec.qual, "IIIIIIII");
  BioIO.WriteFastq(wr, wrec);

  wrec.name := "read2";
  BioSeq.FromStr(wrec.seq,  "TTTTAAAA");
  BioSeq.FromStr(wrec.qual, "JJJJJJJJ");
  BioIO.WriteFastq(wr, wrec);

  Files.Register(f);
  Files.Close(f);
  BioSeq.Free(wrec.seq);
  BioSeq.Free(wrec.qual);

  (* Read back *)
  ASSERT(BioIO.OpenFastq(rdr, "testbio_fastq.tmp"));
  Ok("OpenFastq succeeds");

  rrec.seq := NIL; rrec.qual := NIL;
  ASSERT(BioIO.ReadFastq(rdr, rrec));
  ASSERT(rrec.name = "read1");
  ASSERT(BioSeq.Length(rrec.seq) = 8);
  BioSeq.ToStr(rrec.seq, buf);  ASSERT(buf = "ACGTACGT");
  BioSeq.ToStr(rrec.qual, buf); ASSERT(buf = "IIIIIIII");
  Ok("ReadFastq record 1");

  ASSERT(BioIO.ReadFastq(rdr, rrec));
  ASSERT(rrec.name = "read2");
  BioSeq.ToStr(rrec.seq, buf);  ASSERT(buf = "TTTTAAAA");
  BioSeq.ToStr(rrec.qual, buf); ASSERT(buf = "JJJJJJJJ");
  Ok("ReadFastq record 2");

  ASSERT(~BioIO.ReadFastq(rdr, rrec));
  Ok("ReadFastq EOF returns FALSE");

  BioIO.CloseFastq(rdr);
  BioSeq.Free(rrec.seq);
  BioSeq.Free(rrec.qual)
END TestFastqRoundTrip;

(* ------------------------------------------------------------------ *)
(*  B5. BED round-trip — all six fields                                 *)
(* ------------------------------------------------------------------ *)
PROCEDURE TestBedRoundTrip;
VAR
  f   : Files.File;
  wr  : Files.Rider;
  rdr : BioIO.BedReader;
  wrec, rrec : BioIO.BedRecord;
BEGIN
  Out.String("--- BED round-trip ---"); Out.Ln();

  f := Files.New("testbio_bed.tmp");
  ASSERT(f # NIL);
  Files.Set(wr, f, 0);

  wrec.chrom  := "chr1"; wrec.start := 0;   wrec.end_ := 1000;
  wrec.name   := "gene1"; wrec.score := 750; wrec.strand := '+';
  BioIO.WriteBed(wr, wrec);

  wrec.chrom  := "chrX"; wrec.start := 500; wrec.end_ := 600;
  wrec.name   := "feat2"; wrec.score := 0;  wrec.strand := '-';
  BioIO.WriteBed(wr, wrec);

  wrec.chrom  := "chr2"; wrec.start := 100; wrec.end_ := 200;
  wrec.name   := ".";    wrec.score := 0;   wrec.strand := '.';
  BioIO.WriteBed(wr, wrec);

  Files.Register(f);
  Files.Close(f);

  ASSERT(BioIO.OpenBed(rdr, "testbio_bed.tmp"));
  Ok("OpenBed succeeds");

  ASSERT(BioIO.ReadBed(rdr, rrec));
  ASSERT(rrec.chrom = "chr1");
  ASSERT(rrec.start = 0);
  ASSERT(rrec.end_  = 1000);
  ASSERT(rrec.name  = "gene1");
  ASSERT(rrec.score = 750);
  ASSERT(rrec.strand = '+');
  Ok("ReadBed record 1 all fields");

  ASSERT(BioIO.ReadBed(rdr, rrec));
  ASSERT(rrec.chrom = "chrX");
  ASSERT(rrec.start = 500);
  ASSERT(rrec.end_  = 600);
  ASSERT(rrec.strand = '-');
  Ok("ReadBed record 2");

  ASSERT(BioIO.ReadBed(rdr, rrec));
  ASSERT(rrec.chrom = "chr2");
  ASSERT(rrec.strand = '.');
  Ok("ReadBed record 3");

  ASSERT(~BioIO.ReadBed(rdr, rrec));
  Ok("ReadBed EOF returns FALSE");

  BioIO.CloseBed(rdr)
END TestBedRoundTrip;

(* ------------------------------------------------------------------ *)
(*  B6. BED with only 3 fields — optional defaults                     *)
(* ------------------------------------------------------------------ *)
PROCEDURE TestBedDefaults;
VAR
  f   : Files.File;
  wr  : Files.Rider;
  rdr : BioIO.BedReader;
  rec : BioIO.BedRecord;
BEGIN
  Out.String("--- BED 3-field defaults ---"); Out.Ln();

  (* Write a minimal 3-field BED line: chrom TAB start TAB end LF *)
  f := Files.New("testbio_bedmin.tmp");
  ASSERT(f # NIL);
  Files.Set(wr, f, 0);
  WriteRaw(wr, "chr3");
  WriteTab(wr); WriteIntRaw(wr, 0);
  WriteTab(wr); WriteIntRaw(wr, 50);
  WriteLF(wr);

  (* 4-field line (no score or strand) *)
  WriteRaw(wr, "chr4");
  WriteTab(wr); WriteIntRaw(wr, 100);
  WriteTab(wr); WriteIntRaw(wr, 200);
  WriteTab(wr); WriteRaw(wr, "myFeat");
  WriteLF(wr);

  Files.Register(f);
  Files.Close(f);

  ASSERT(BioIO.OpenBed(rdr, "testbio_bedmin.tmp"));

  ASSERT(BioIO.ReadBed(rdr, rec));
  ASSERT(rec.chrom = "chr3");
  ASSERT(rec.start = 0);
  ASSERT(rec.end_  = 50);
  ASSERT(rec.name[0] = '.');   (* default *)
  ASSERT(rec.score = 0);       (* default *)
  ASSERT(rec.strand = '.');    (* default *)
  Ok("3-field BED: defaults for name/score/strand");

  ASSERT(BioIO.ReadBed(rdr, rec));
  ASSERT(rec.chrom = "chr4");
  ASSERT(rec.name  = "myFeat");
  ASSERT(rec.score = 0);    (* not present -> default *)
  ASSERT(rec.strand = '.'); (* not present -> default *)
  Ok("4-field BED: name present, score/strand default");

  ASSERT(~BioIO.ReadBed(rdr, rec));
  Ok("BED defaults file EOF");

  BioIO.CloseBed(rdr)
END TestBedDefaults;

(* ------------------------------------------------------------------ *)
(*  B7. BED comment and header lines are skipped                       *)
(* ------------------------------------------------------------------ *)
PROCEDURE TestBedComments;
VAR
  f   : Files.File;
  wr  : Files.Rider;
  rdr : BioIO.BedReader;
  wrec, rrec : BioIO.BedRecord;
BEGIN
  Out.String("--- BED comments/headers ---"); Out.Ln();

  f := Files.New("testbio_bedcom.tmp");
  ASSERT(f # NIL);
  Files.Set(wr, f, 0);

  (* Comment line *)
  WriteRaw(wr, "# genome assembly hg38"); WriteLF(wr);
  (* track header *)
  WriteRaw(wr, "track name=genes visibility=2"); WriteLF(wr);
  (* browser header *)
  WriteRaw(wr, "browser position chr1:1-1000"); WriteLF(wr);
  (* blank line *)
  WriteLF(wr);
  (* real data record *)
  wrec.chrom  := "chrY"; wrec.start := 5000; wrec.end_ := 6000;
  wrec.name   := "orf1"; wrec.score := 1000; wrec.strand := '+';
  BioIO.WriteBed(wr, wrec);
  (* second data record after another comment *)
  WriteRaw(wr, "# trailing comment"); WriteLF(wr);
  wrec.chrom  := "chrM"; wrec.start := 0; wrec.end_ := 100;
  wrec.name   := "mt1"; wrec.score := 0; wrec.strand := '.';
  BioIO.WriteBed(wr, wrec);

  Files.Register(f);
  Files.Close(f);

  ASSERT(BioIO.OpenBed(rdr, "testbio_bedcom.tmp"));

  ASSERT(BioIO.ReadBed(rdr, rrec));
  ASSERT(rrec.chrom  = "chrY");
  ASSERT(rrec.start  = 5000);
  ASSERT(rrec.end_   = 6000);
  ASSERT(rrec.name   = "orf1");
  ASSERT(rrec.strand = '+');
  Ok("BED skips #/track/browser/blank, reads data");

  ASSERT(BioIO.ReadBed(rdr, rrec));
  ASSERT(rrec.chrom = "chrM");
  Ok("BED second record after trailing comment");

  ASSERT(~BioIO.ReadBed(rdr, rrec));
  Ok("BED comments file EOF");

  BioIO.CloseBed(rdr)
END TestBedComments;

(* ================================================================== *)
(*  BioAlign tests                                                      *)
(* ================================================================== *)

(* ------------------------------------------------------------------ *)
(*  A1. DefaultScore                                                    *)
(* ------------------------------------------------------------------ *)
PROCEDURE TestDefaultScore;
VAR m: BioAlign.ScoreMatrix;
BEGIN
  Out.String("--- DefaultScore ---"); Out.Ln;
  BioAlign.DefaultScore(m);
  ASSERT(m.match_   =  1);
  ASSERT(m.mismatch = -1);
  ASSERT(m.gapOpen  = -5);
  ASSERT(m.gapExt   = -1);
  Ok("DefaultScore values")
END TestDefaultScore;

(* ------------------------------------------------------------------ *)
(*  A2. HammingDistance                                                 *)
(* ------------------------------------------------------------------ *)
PROCEDURE TestHammingDistance;
VAR q, r: BioSeq.Seq;
BEGIN
  Out.String("--- HammingDistance ---"); Out.Ln;
  BioSeq.New(q);  BioSeq.New(r);

  BioSeq.FromStr(q, "ACGT");
  BioSeq.FromStr(r, "ACGT");
  ASSERT(BioAlign.HammingDistance(q, r) = 0);
  Ok("Hamming identical = 0");

  BioSeq.FromStr(r, "ACGG");       (* last char differs *)
  ASSERT(BioAlign.HammingDistance(q, r) = 1);
  Ok("Hamming 1 mismatch = 1");

  BioSeq.FromStr(r, "TTTT");       (* A=T C=T G=T T=T → 3 mismatches *)
  ASSERT(BioAlign.HammingDistance(q, r) = 3);
  Ok("Hamming 3 mismatches");

  BioSeq.FromStr(r, "TGCA");       (* all differ *)
  ASSERT(BioAlign.HammingDistance(q, r) = 4);
  Ok("Hamming all mismatches = 4");

  BioSeq.FromStr(r, "ACGTA");      (* unequal length *)
  ASSERT(BioAlign.HammingDistance(q, r) = -1);
  Ok("Hamming unequal length = -1");

  BioSeq.Free(q);  BioSeq.Free(r)
END TestHammingDistance;

(* ------------------------------------------------------------------ *)
(*  A3. EditDistance                                                    *)
(* ------------------------------------------------------------------ *)
PROCEDURE TestEditDistance;
VAR q, r: BioSeq.Seq;
BEGIN
  Out.String("--- EditDistance ---"); Out.Ln;
  BioSeq.New(q);  BioSeq.New(r);

  BioSeq.FromStr(q, "ACGT");
  BioSeq.FromStr(r, "ACGT");
  ASSERT(BioAlign.EditDistance(q, r) = 0);
  Ok("EditDist identical = 0");

  BioSeq.FromStr(r, "ACGTT");      (* one insertion *)
  ASSERT(BioAlign.EditDistance(q, r) = 1);
  Ok("EditDist one insertion = 1");

  BioSeq.FromStr(q, "ACGTT");      (* swap: one deletion *)
  BioSeq.FromStr(r, "ACGT");
  ASSERT(BioAlign.EditDistance(q, r) = 1);
  Ok("EditDist one deletion = 1");

  BioSeq.FromStr(q, "ACGT");
  BioSeq.FromStr(r, "ACCT");       (* one substitution G→C *)
  ASSERT(BioAlign.EditDistance(q, r) = 1);
  Ok("EditDist one substitution = 1");

  BioSeq.FromStr(q, "ACGT");
  BioSeq.FromStr(r, "TGCA");       (* fully scrambled: 4 edits minimum *)
  ASSERT(BioAlign.EditDistance(q, r) = 4);
  Ok("EditDist fully scrambled = 4");

  BioSeq.FromStr(q, "");
  BioSeq.FromStr(r, "ACGT");
  ASSERT(BioAlign.EditDistance(q, r) = 4);
  Ok("EditDist empty vs 4-mer = 4");

  BioSeq.Free(q);  BioSeq.Free(r)
END TestEditDistance;

(* ------------------------------------------------------------------ *)
(*  A4. Global alignment — Needleman-Wunsch                            *)
(* ------------------------------------------------------------------ *)
PROCEDURE TestGlobal;
VAR
  q, r : BioSeq.Seq;
  m    : BioAlign.ScoreMatrix;
  aln  : BioAlign.Alignment;
BEGIN
  Out.String("--- Global alignment ---"); Out.Ln;
  BioSeq.New(q);  BioSeq.New(r);
  BioAlign.DefaultScore(m);

  (* --- identical sequences --- *)
  BioSeq.FromStr(q, "ACGT");
  BioSeq.FromStr(r, "ACGT");
  BioAlign.Global(q, r, m, aln);
  ASSERT(aln.score = 4);           (* 4 matches × 1 *)
  ASSERT(aln.qStart = 0);
  ASSERT(aln.qEnd   = 4);
  ASSERT(aln.rStart = 0);
  ASSERT(aln.rEnd   = 4);
  ASSERT(aln.nOps   = 1);
  ASSERT(aln.cigar[0].op  = BioAlign.opMatch);
  ASSERT(aln.cigar[0].len = 4);
  ASSERT(aln.identity > 0.999);
  Ok("Global identical: score/coords/cigar/identity");

  (* --- one substitution --- *)
  (* ACGT vs ACCT: 3 match + 1 subst → score = 3 - 1 = 2 *)
  BioSeq.FromStr(q, "ACGT");
  BioSeq.FromStr(r, "ACCT");
  BioAlign.Global(q, r, m, aln);
  ASSERT(aln.score = 2);
  ASSERT(aln.nOps  = 3);           (* opMatch(2) opSubst(1) opMatch(1) *)
  ASSERT(aln.cigar[0].op  = BioAlign.opMatch);  ASSERT(aln.cigar[0].len = 2);
  ASSERT(aln.cigar[1].op  = BioAlign.opSubst);  ASSERT(aln.cigar[1].len = 1);
  ASSERT(aln.cigar[2].op  = BioAlign.opMatch);  ASSERT(aln.cigar[2].len = 1);
  ASSERT((aln.identity > 0.749) & (aln.identity < 0.751));  (* 3/4 *)
  Ok("Global 1 substitution: score/cigar/identity");

  (* --- one gap in reference (query longer by 1) ---
     q = ACGT, r = AGT
     Best: A-match, C-inserted (opIns), G-match, T-match
     score = 3 matches + gapOpen = 3 - 5 = -2 *)
  BioSeq.FromStr(q, "ACGT");
  BioSeq.FromStr(r, "AGT");
  BioAlign.Global(q, r, m, aln);
  ASSERT(aln.score  = -2);
  ASSERT(aln.qStart = 0);  ASSERT(aln.qEnd = 4);
  ASSERT(aln.rStart = 0);  ASSERT(aln.rEnd = 3);
  ASSERT(aln.nOps   = 3);  (* opMatch(1) opIns(1) opMatch(2) *)
  ASSERT(aln.cigar[0].op  = BioAlign.opMatch);  ASSERT(aln.cigar[0].len = 1);
  ASSERT(aln.cigar[1].op  = BioAlign.opIns);    ASSERT(aln.cigar[1].len = 1);
  ASSERT(aln.cigar[2].op  = BioAlign.opMatch);  ASSERT(aln.cigar[2].len = 2);
  Ok("Global 1-base gap in ref: score/cigar");

  (* --- one gap in query (reference longer by 1) ---
     q = ACT, r = ACGT
     Best: A-match, C-match, G-deleted (opDel), T-match
     score = 3 + gapOpen = -2 *)
  BioSeq.FromStr(q, "ACT");
  BioSeq.FromStr(r, "ACGT");
  BioAlign.Global(q, r, m, aln);
  ASSERT(aln.score  = -2);
  ASSERT(aln.qEnd   = 3);
  ASSERT(aln.rEnd   = 4);
  ASSERT(aln.cigar[1].op  = BioAlign.opDel);  ASSERT(aln.cigar[1].len = 1);
  Ok("Global 1-base gap in query: score/cigar");

  (* --- length-2 gap: verify gapExt kicks in ---
     q = ACGT, r = AT (2 bases shorter)
     Best: A-match, CG-inserted (opIns×2), T-match
     score = 2 + gapOpen + gapExt = 2 - 5 - 1 = -4 *)
  BioSeq.FromStr(q, "ACGT");
  BioSeq.FromStr(r, "AT");
  BioAlign.Global(q, r, m, aln);
  ASSERT(aln.score = -4);
  ASSERT(aln.cigar[1].op  = BioAlign.opIns);  ASSERT(aln.cigar[1].len = 2);
  Ok("Global length-2 gap: gapExt applied");

  BioSeq.Free(q);  BioSeq.Free(r)
END TestGlobal;

(* ------------------------------------------------------------------ *)
(*  A5. Local alignment — Smith-Waterman                               *)
(* ------------------------------------------------------------------ *)
PROCEDURE TestLocal;
VAR
  q, r : BioSeq.Seq;
  m    : BioAlign.ScoreMatrix;
  aln  : BioAlign.Alignment;
BEGIN
  Out.String("--- Local alignment ---"); Out.Ln;
  BioSeq.New(q);  BioSeq.New(r);
  BioAlign.DefaultScore(m);

  (* --- perfect substring match ---
     q = AAACGTAAA, r = TTACGTTT
     ACGT appears at q[2..5] and r[2..5]
     Local score = 4 (4 exact matches) *)
  BioSeq.FromStr(q, "AAACGTAAA");
  BioSeq.FromStr(r, "TTACGTTT");
  BioAlign.Local(q, r, m, aln);
  ASSERT(aln.score  = 4);
  ASSERT(aln.qStart = 2);  ASSERT(aln.qEnd = 6);
  ASSERT(aln.rStart = 2);  ASSERT(aln.rEnd = 6);
  ASSERT(aln.nOps   = 1);
  ASSERT(aln.cigar[0].op  = BioAlign.opMatch);
  ASSERT(aln.cigar[0].len = 4);
  ASSERT(aln.identity > 0.999);
  Ok("Local substring match: score/coords/cigar/identity");

  (* --- query IS the reference: entire alignment is local best ---
     score = len × match *)
  BioSeq.FromStr(q, "ACGT");
  BioSeq.FromStr(r, "ACGT");
  BioAlign.Local(q, r, m, aln);
  ASSERT(aln.score = 4);
  ASSERT(aln.identity > 0.999);
  Ok("Local identical sequences: full match");

  (* --- no similarity: all mismatches, score = 0 ---
     The SW floors at 0, so best cell score should be 0 *)
  BioSeq.FromStr(q, "AAAA");
  BioSeq.FromStr(r, "TTTT");
  BioAlign.Local(q, r, m, aln);
  ASSERT(aln.score = 0);
  ASSERT(aln.nOps  = 0);
  Ok("Local all mismatches: score 0, no ops");

  (* --- local finds internal match, ignores flanking mismatches ---
     q = TTACGTTT, r = AAACGTAAA
     best match is ACGT at q[2..5], r[3..6] *)
  BioSeq.FromStr(q, "TTACGTTT");
  BioSeq.FromStr(r, "AAACGTAAA");
  BioAlign.Local(q, r, m, aln);
  ASSERT(aln.score = 4);
  ASSERT(aln.qEnd - aln.qStart = 4);  (* 4 bases aligned *)
  ASSERT(aln.rEnd - aln.rStart = 4);
  Ok("Local: correct window width for internal match");

  BioSeq.Free(q);  BioSeq.Free(r)
END TestLocal;

(* ------------------------------------------------------------------ *)
(*  A6. SemiGlobal alignment — free query end-gaps                     *)
(* ------------------------------------------------------------------ *)
PROCEDURE TestSemiGlobal;
VAR
  q, r : BioSeq.Seq;
  m    : BioAlign.ScoreMatrix;
  aln  : BioAlign.Alignment;
BEGIN
  Out.String("--- SemiGlobal alignment ---"); Out.Ln;
  BioSeq.New(q);  BioSeq.New(r);
  BioAlign.DefaultScore(m);

  (* --- query embedded in reference, free prefix and suffix ---
     q = ACGT, r = TTTTACGTTTTT
     Perfect ACGT match at r[4..7]; flanking Ts are free
     score = 4 *)
  BioSeq.FromStr(q, "ACGT");
  BioSeq.FromStr(r, "TTTTACGTTTTT");
  BioAlign.SemiGlobal(q, r, m, aln);
  ASSERT(aln.score  = 4);
  ASSERT(aln.qStart = 0);  ASSERT(aln.qEnd = 4);
  ASSERT(aln.rStart = 4);  ASSERT(aln.rEnd = 8);
  ASSERT(aln.nOps   = 1);
  ASSERT(aln.cigar[0].op  = BioAlign.opMatch);
  ASSERT(aln.cigar[0].len = 4);
  ASSERT(aln.identity > 0.999);
  Ok("SemiGlobal: query embedded in ref, free flanks");

  (* --- identical sequences: behaves like global ---
     no free gaps needed, score = length × match *)
  BioSeq.FromStr(q, "ACGT");
  BioSeq.FromStr(r, "ACGT");
  BioAlign.SemiGlobal(q, r, m, aln);
  ASSERT(aln.score = 4);
  ASSERT(aln.identity > 0.999);
  Ok("SemiGlobal identical = global score");

  (* --- query at start of reference, trailing ref bases are free ---
     q = ACGT, r = ACGTTTTTTTT
     ACGT matches at r[0..3]; trailing Ts carry no penalty
     score = 4 *)
  BioSeq.FromStr(q, "ACGT");
  BioSeq.FromStr(r, "ACGTTTTTTTT");
  BioAlign.SemiGlobal(q, r, m, aln);
  ASSERT(aln.score  = 4);
  ASSERT(aln.rStart = 0);
  ASSERT(aln.rEnd   = 4);
  Ok("SemiGlobal: query at ref start, trailing ref bases free");

  BioSeq.Free(q);  BioSeq.Free(r)
END TestSemiGlobal;

(* ------------------------------------------------------------------ *)
(*  A7. PrintAlignment — visual / no crash                             *)
(* ------------------------------------------------------------------ *)
PROCEDURE TestPrintAlignment;
VAR
  q, r : BioSeq.Seq;
  m    : BioAlign.ScoreMatrix;
  aln  : BioAlign.Alignment;
BEGIN
  Out.String("--- PrintAlignment (visual) ---"); Out.Ln;
  BioSeq.New(q);  BioSeq.New(r);
  BioAlign.DefaultScore(m);

  BioSeq.FromStr(q, "ACGTACGT");
  BioSeq.FromStr(r, "ACGTTACGT");
  BioAlign.Global(q, r, m, aln);
  BioAlign.PrintAlignment(aln, q, r);

  BioSeq.Free(q);  BioSeq.Free(r);
  Ok("PrintAlignment runs without crash")
END TestPrintAlignment;

(* ================================================================== *)
(*  BioPattern tests                                                   *)
(* ================================================================== *)

(* ------------------------------------------------------------------ *)
(*  P1. Boyer-Moore                                                     *)
(* ------------------------------------------------------------------ *)
PROCEDURE TestBMSearch;
VAR st: BioPattern.BMState; seq: BioSeq.Seq;
BEGIN
  Out.String("--- Boyer-Moore ---"); Out.Ln();
  BioSeq.New(seq);

  (* single exact match in the middle *)
  BioPattern.BMBuild(st, "ACGT");
  BioSeq.FromStr(seq, "TTTACGTAAA");
  BioPattern.BMSearch(st, seq, hits);
  ASSERT(hits.count = 1);
  ASSERT(hits.hits[0].pos = 3);
  ASSERT(hits.hits[0].len = 4);
  ASSERT(hits.hits[0].dist = 0);
  Ok("BM single match in middle");

  (* match at position 0 *)
  BioSeq.FromStr(seq, "ACGTAAA");
  BioPattern.BMSearch(st, seq, hits);
  ASSERT(hits.count = 1);
  ASSERT(hits.hits[0].pos = 0);
  Ok("BM match at start");

  (* match at very end *)
  BioPattern.BMBuild(st, "GT");
  BioSeq.FromStr(seq, "ACGT");
  BioPattern.BMSearch(st, seq, hits);
  ASSERT(hits.count = 1);
  ASSERT(hits.hits[0].pos = 2);
  Ok("BM match at end");

  (* no match *)
  BioPattern.BMBuild(st, "GGGG");
  BioSeq.FromStr(seq, "ACGTACGT");
  BioPattern.BMSearch(st, seq, hits);
  ASSERT(hits.count = 0);
  Ok("BM no match");

  (* three non-overlapping matches *)
  BioPattern.BMBuild(st, "AC");
  BioSeq.FromStr(seq, "ACACAC");
  BioPattern.BMSearch(st, seq, hits);
  ASSERT(hits.count = 3);
  ASSERT(hits.hits[0].pos = 0);
  ASSERT(hits.hits[1].pos = 2);
  ASSERT(hits.hits[2].pos = 4);
  Ok("BM three non-overlapping matches");

  (* overlapping: AA in AAAAA -> 4 hits *)
  BioPattern.BMBuild(st, "AA");
  BioSeq.FromStr(seq, "AAAAA");
  BioPattern.BMSearch(st, seq, hits);
  ASSERT(hits.count = 4);
  ASSERT(hits.hits[0].pos = 0);
  ASSERT(hits.hits[1].pos = 1);
  ASSERT(hits.hits[2].pos = 2);
  ASSERT(hits.hits[3].pos = 3);
  Ok("BM overlapping matches");

  (* pattern longer than text -> no hits *)
  BioPattern.BMBuild(st, "ACGTACGT");
  BioSeq.FromStr(seq, "ACG");
  BioPattern.BMSearch(st, seq, hits);
  ASSERT(hits.count = 0);
  Ok("BM pattern longer than text");

  (* pattern equals text exactly *)
  BioPattern.BMBuild(st, "ACGT");
  BioSeq.FromStr(seq, "ACGT");
  BioPattern.BMSearch(st, seq, hits);
  ASSERT(hits.count = 1);
  ASSERT(hits.hits[0].pos = 0);
  Ok("BM pattern equals text");

  BioSeq.Free(seq)
END TestBMSearch;

(* ------------------------------------------------------------------ *)
(*  P2. KMP                                                             *)
(* ------------------------------------------------------------------ *)
PROCEDURE TestKMPSearch;
VAR st: BioPattern.KMPState; seq: BioSeq.Seq;
BEGIN
  Out.String("--- KMP ---"); Out.Ln();
  BioSeq.New(seq);

  (* single exact match *)
  BioPattern.KMPBuild(st, "ACGT");
  BioSeq.FromStr(seq, "TTTACGTAAA");
  BioPattern.KMPSearch(st, seq, hits);
  ASSERT(hits.count = 1);
  ASSERT(hits.hits[0].pos = 3);
  ASSERT(hits.hits[0].len = 4);
  ASSERT(hits.hits[0].dist = 0);
  Ok("KMP single match");

  (* no match *)
  BioPattern.KMPBuild(st, "GGGG");
  BioSeq.FromStr(seq, "ACGTACGT");
  BioPattern.KMPSearch(st, seq, hits);
  ASSERT(hits.count = 0);
  Ok("KMP no match");

  (* three non-overlapping matches *)
  BioPattern.KMPBuild(st, "AC");
  BioSeq.FromStr(seq, "ACACAC");
  BioPattern.KMPSearch(st, seq, hits);
  ASSERT(hits.count = 3);
  ASSERT(hits.hits[0].pos = 0);
  ASSERT(hits.hits[1].pos = 2);
  ASSERT(hits.hits[2].pos = 4);
  Ok("KMP three non-overlapping matches");

  (* overlapping via failure function: ABA in ABABABA -> 3 hits at 0,2,4 *)
  BioPattern.KMPBuild(st, "ABA");
  BioSeq.FromStr(seq, "ABABABA");
  BioPattern.KMPSearch(st, seq, hits);
  ASSERT(hits.count = 3);
  ASSERT(hits.hits[0].pos = 0);
  ASSERT(hits.hits[1].pos = 2);
  ASSERT(hits.hits[2].pos = 4);
  Ok("KMP overlapping via failure function");

  (* repeating pattern: AAAA in AAAAAAAA -> 5 hits at 0..4 *)
  BioPattern.KMPBuild(st, "AAAA");
  BioSeq.FromStr(seq, "AAAAAAAA");
  BioPattern.KMPSearch(st, seq, hits);
  ASSERT(hits.count = 5);
  ASSERT(hits.hits[0].pos = 0);
  ASSERT(hits.hits[4].pos = 4);
  Ok("KMP repeating pattern overlapping");

  (* pattern longer than text -> no hits *)
  BioPattern.KMPBuild(st, "ACGTACGT");
  BioSeq.FromStr(seq, "ACG");
  BioPattern.KMPSearch(st, seq, hits);
  ASSERT(hits.count = 0);
  Ok("KMP pattern longer than text");

  BioSeq.Free(seq)
END TestKMPSearch;

(* ------------------------------------------------------------------ *)
(*  P3. Aho-Corasick                                                    *)
(* ------------------------------------------------------------------ *)
PROCEDURE TestACSearch;
VAR seq: BioSeq.Seq;
BEGIN
  Out.String("--- Aho-Corasick ---"); Out.Ln();
  BioSeq.New(seq);

  (* single pattern — same result as exact search *)
  BioPattern.ACBuild(acSt);
  BioPattern.ACAdd(acSt, "ACGT");
  BioPattern.ACFinalize(acSt);
  BioSeq.FromStr(seq, "TTTACGTAAA");
  BioPattern.ACSearch(acSt, seq, hits);
  ASSERT(hits.count = 1);
  ASSERT(hits.hits[0].pos = 3);
  ASSERT(hits.hits[0].len = 4);
  ASSERT(hits.hits[0].dist = 0);
  Ok("AC single pattern match");

  (* single pattern not in text -> 0 hits *)
  BioPattern.ACBuild(acSt);
  BioPattern.ACAdd(acSt, "NNNN");
  BioPattern.ACFinalize(acSt);
  BioSeq.FromStr(seq, "ACGTACGT");
  BioPattern.ACSearch(acSt, seq, hits);
  ASSERT(hits.count = 0);
  Ok("AC no match");

  (* two overlapping patterns: ACG at 0, CGT at 1 in ACGT *)
  BioPattern.ACBuild(acSt);
  BioPattern.ACAdd(acSt, "ACG");
  BioPattern.ACAdd(acSt, "CGT");
  BioPattern.ACFinalize(acSt);
  BioSeq.FromStr(seq, "ACGT");
  BioPattern.ACSearch(acSt, seq, hits);
  ASSERT(hits.count = 2);
  (* hits are reported in text order; ACG ends at i=2, CGT ends at i=3 *)
  ASSERT(hits.hits[0].pos = 0);  ASSERT(hits.hits[0].len = 3);
  ASSERT(hits.hits[1].pos = 1);  ASSERT(hits.hits[1].len = 3);
  Ok("AC two overlapping patterns");

  (* two non-overlapping patterns: AA at 0,4 and BB at 2 in AABBAA *)
  BioPattern.ACBuild(acSt);
  BioPattern.ACAdd(acSt, "AA");
  BioPattern.ACAdd(acSt, "BB");
  BioPattern.ACFinalize(acSt);
  BioSeq.FromStr(seq, "AABBAA");
  BioPattern.ACSearch(acSt, seq, hits);
  ASSERT(hits.count = 3);
  ASSERT(hits.hits[0].pos = 0);  (* AA *)
  ASSERT(hits.hits[1].pos = 2);  (* BB *)
  ASSERT(hits.hits[2].pos = 4);  (* AA *)
  Ok("AC two patterns: AA and BB");

  (* mix present and absent patterns *)
  BioPattern.ACBuild(acSt);
  BioPattern.ACAdd(acSt, "ACGT");
  BioPattern.ACAdd(acSt, "NNNN");  (* not in text *)
  BioPattern.ACAdd(acSt, "CGT");
  BioPattern.ACFinalize(acSt);
  BioSeq.FromStr(seq, "ACGT");
  BioPattern.ACSearch(acSt, seq, hits);
  ASSERT(hits.count = 2);  (* ACGT at 0 and CGT at 1 *)
  Ok("AC present and absent patterns mixed");

  BioSeq.Free(seq)
END TestACSearch;

(* ------------------------------------------------------------------ *)
(*  P4. Ukkonen approximate matching                                    *)
(* ------------------------------------------------------------------ *)
PROCEDURE TestUkkonen;
VAR seq: BioSeq.Seq;
BEGIN
  Out.String("--- Ukkonen ---"); Out.Ln();
  BioSeq.New(seq);

  (* exact match, maxDist=0 *)
  BioSeq.FromStr(seq, "XACGTX");
  BioPattern.Ukkonen("ACGT", seq, 0, hits);
  ASSERT(hits.count = 1);
  ASSERT(hits.hits[0].pos = 1);
  ASSERT(hits.hits[0].len = 4);
  ASSERT(hits.hits[0].dist = 0);
  Ok("Ukkonen exact match maxDist=0");

  (* one substitution: ACGT vs ACCT, maxDist=1 -> 1 hit *)
  BioSeq.FromStr(seq, "XACCTX");
  BioPattern.Ukkonen("ACGT", seq, 1, hits);
  ASSERT(hits.count = 1);
  ASSERT(hits.hits[0].pos = 1);
  ASSERT(hits.hits[0].dist = 1);
  Ok("Ukkonen 1 substitution maxDist=1");

  (* one substitution but maxDist=0 -> no hit *)
  BioSeq.FromStr(seq, "XACCTX");
  BioPattern.Ukkonen("ACGT", seq, 0, hits);
  ASSERT(hits.count = 0);
  Ok("Ukkonen 1-subst pattern excluded at maxDist=0");

  (* exact match also reported at maxDist=1 with dist=0;
     use text="ACGT" so no dist=1 partial match precedes the exact hit *)
  BioSeq.FromStr(seq, "ACGT");
  BioPattern.Ukkonen("ACGT", seq, 1, hits);
  ASSERT(hits.count = 1);
  ASSERT(hits.hits[0].pos  = 0);
  ASSERT(hits.hits[0].dist = 0);
  Ok("Ukkonen exact match has dist=0 at maxDist=1");

  (* no match at all: TTTT vs ACGT, maxDist=0 *)
  BioSeq.FromStr(seq, "TTTTTTTT");
  BioPattern.Ukkonen("ACGT", seq, 0, hits);
  ASSERT(hits.count = 0);
  Ok("Ukkonen no match");

  (* empty pattern -> 0 hits *)
  BioSeq.FromStr(seq, "ACGT");
  BioPattern.Ukkonen("", seq, 1, hits);
  ASSERT(hits.count = 0);
  Ok("Ukkonen empty pattern");

  (* negative maxDist -> 0 hits *)
  BioPattern.Ukkonen("ACGT", seq, -1, hits);
  ASSERT(hits.count = 0);
  Ok("Ukkonen negative maxDist");

  (* pattern = full text exact *)
  BioSeq.FromStr(seq, "ACGT");
  BioPattern.Ukkonen("ACGT", seq, 0, hits);
  ASSERT(hits.count = 1);
  ASSERT(hits.hits[0].pos = 0);
  ASSERT(hits.hits[0].dist = 0);
  Ok("Ukkonen pattern equals text");

  (* two exact occurrences: ACGT appears at 0 and 5 in ACGTXACGT *)
  BioSeq.FromStr(seq, "ACGTXACGT");
  BioPattern.Ukkonen("ACGT", seq, 0, hits);
  ASSERT(hits.count = 2);
  ASSERT(hits.hits[0].pos = 0);
  ASSERT(hits.hits[1].pos = 5);
  Ok("Ukkonen two exact occurrences");

  BioSeq.Free(seq)
END TestUkkonen;

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
  Out.String("=== BioIO tests ==="); Out.Ln();
  TestOpenMissing;
  TestFastaRoundTrip;
  TestFastaMultiLine;
  TestFastqRoundTrip;
  TestBedRoundTrip;
  TestBedDefaults;
  TestBedComments;
  Out.String("=== BioAlign tests ==="); Out.Ln();
  TestDefaultScore;
  TestHammingDistance;
  TestEditDistance;
  TestGlobal;
  TestLocal;
  TestSemiGlobal;
  TestPrintAlignment;
  Out.String("=== BioPattern tests ==="); Out.Ln();
  TestBMSearch;
  TestKMPSearch;
  TestACSearch;
  TestUkkonen;
  Out.Ln();
  Out.String("All "); Out.Int(pass); Out.String(" tests passed."); Out.Ln()
END TestBio.
