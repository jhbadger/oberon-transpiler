MODULE transpilertest;
(*
 * Transpiler regression test — each section prints PASS or FAIL.
 * Covers language features most likely to expose code-generation bugs.
 * Expected output: every line ends with "PASS".
 *)

IMPORT Out, Strings, Math;

(* ── Types for pointer / inheritance tests ─────────────────────────── *)
TYPE
  ShapeRec  = RECORD area: REAL END;
  Shape     = POINTER TO ShapeRec;

  RectRec   = RECORD (ShapeRec) w, h: INTEGER END;
  Rect      = POINTER TO RectRec;

  CircleRec = RECORD (ShapeRec) r: INTEGER END;
  Circle    = POINTER TO CircleRec;

(* ── Procedure-type variable ────────────────────────────────────────── *)
TYPE
  IntFn = PROCEDURE(x: INTEGER): INTEGER;

(* ── Global side-effect counter for short-circuit tests ────────────── *)
VAR
  sideCount: INTEGER;

PROCEDURE SideEffect(v: INTEGER): BOOLEAN;
BEGIN
  INC(sideCount);
  RETURN v > 0
END SideEffect;

(* ── VAR-parameter procedure ────────────────────────────────────────── *)
PROCEDURE Swap(VAR a, b: INTEGER);
  VAR t: INTEGER;
BEGIN t := a; a := b; b := t
END Swap;

(* ── Nested procedure accessing outer variable ──────────────────────── *)
PROCEDURE NestedOuter(): INTEGER;
  VAR n: INTEGER;
  PROCEDURE AddFive;
  BEGIN n := n + 5
  END AddFive;
BEGIN
  n := 10;
  AddFive;
  AddFive;
  RETURN n
END NestedOuter;

(* ── Recursive procedure ─────────────────────────────────────────────── *)
PROCEDURE Fib(n: INTEGER): INTEGER;
BEGIN
  IF n <= 1 THEN RETURN n END;
  RETURN Fib(n - 1) + Fib(n - 2)
END Fib;

(* ── Procedure accepting open array ─────────────────────────────────── *)
PROCEDURE SumArray(a: ARRAY OF INTEGER): INTEGER;
  VAR i, s: INTEGER;
BEGIN
  s := 0;
  FOR i := 0 TO LEN(a) - 1 DO INC(s, a[i]) END;
  RETURN s
END SumArray;

(* ── Procedure-type target ───────────────────────────────────────────── *)
PROCEDURE Double(x: INTEGER): INTEGER;
BEGIN RETURN x * 2
END Double;

PROCEDURE Triple(x: INTEGER): INTEGER;
BEGIN RETURN x * 3
END Triple;

(* ── Helper to print pass/fail ───────────────────────────────────────── *)
PROCEDURE Check(label: ARRAY OF CHAR; ok: BOOLEAN);
BEGIN
  Out.String(label);
  Out.String(": ");
  IF ok THEN Out.String("PASS") ELSE Out.String("FAIL") END;
  Out.Ln
END Check;

(* ═══════════════════════════════════════════════════════════════════════ *)
VAR
  i, j, k   : INTEGER;
  li, lj     : LONGINT;
  r          : REAL;
  ch         : CHAR;
  s, t       : ARRAY 64 OF CHAR;
  arr5       : ARRAY 5 OF INTEGER;
  mat        : ARRAY 3 OF ARRAY 3 OF INTEGER;
  b          : BOOLEAN;
  sx         : SET;
  p          : Shape;
  rc         : Rect;
  ci         : Circle;
  fn         : IntFn;

BEGIN
  (* ── 1. Integer arithmetic and DIV/MOD floor semantics ─────────────── *)
  Check("DIV positive",   7 DIV 3 = 2);
  Check("MOD positive",   7 MOD 3 = 1);
  Check("DIV neg floor", (-7) DIV 3 = -3);
  Check("MOD neg pos",   (-7) MOD 3 = 2);
  Check("DIV neg neg",   7 DIV (-3) = -3);
  Check("MOD neg neg",   7 MOD (-3) = -2);

  (* ── 2. Operator precedence ─────────────────────────────────────────── *)
  Check("Prec 2+3*4=14",  2 + 3 * 4 = 14);
  Check("Prec (2+3)*4=20",(2 + 3) * 4 = 20);
  Check("NOT TRUE=FALSE",  ~TRUE = FALSE);
  Check("NOT FALSE=TRUE",  ~FALSE = TRUE);
  Check("AND short FALSE", FALSE & SideEffect(1) = FALSE);  (* SideEffect must NOT run *)
  sideCount := 0;
  i := 0;
  b := FALSE & SideEffect(1);
  Check("AND no side-eff", sideCount = 0);
  sideCount := 0;
  b := TRUE OR SideEffect(1);
  Check("OR no side-eff",  sideCount = 0);

  (* ── 3. Bitwise / shift builtins ────────────────────────────────────── *)
  Check("LSL 1<<4=16",    LSL(1, 4) = 16);
  Check("ASR 16>>2=4",    ASR(16, 2) = 4);
  Check("ASR neg sign",   ASR(-8, 1) = -4);
  Check("ROR basic",      ROR(4, 1) = 2);
  Check("ROR by 4",       ROR(256, 4) = 16);

  (* ── 4. ABS / ODD / FLT / CHR / ORD ────────────────────────────────── *)
  Check("ABS int pos",    ABS(5) = 5);
  Check("ABS int neg",    ABS(-5) = 5);
  Check("ABS real",       ABS(-2.5) = 2.5);
  Check("ODD true",       ODD(7));
  Check("ODD false",      ~ODD(8));
  Check("FLT",            FLT(3) = 3.0);
  Check("CHR/ORD",        ORD(CHR(65)) = 65);
  Check("CHAR arith",     CHR(ORD('A') + 1) = 'B');

  (* ── 5. SET operations ──────────────────────────────────────────────── *)
  sx := {1, 3, 5};
  Check("SET IN true",    3 IN sx);
  Check("SET IN false",   ~(2 IN sx));
  sx := {1, 2, 3} + {3, 4, 5};
  Check("SET union",      sx = {1, 2, 3, 4, 5});
  sx := {1, 2, 3, 4} - {2, 4};
  Check("SET diff",       sx = {1, 3});
  sx := {1, 2, 3} * {2, 3, 4};
  Check("SET intersect",  sx = {2, 3});
  sx := {1, 2} / {2, 3};
  Check("SET sym-diff",   sx = {1, 3});

  (* ── 6. PACK / UNPK ─────────────────────────────────────────────────── *)
  r := 1.0;  PACK(r, 3);   Check("PACK *8",  r = 8.0);
  r := 8.0;  UNPK(r, i);   Check("UNPK mantissa", (r >= 1.0) & (r < 2.0));
  Check("UNPK exponent", i = 3);

  (* ── 7. FOR loop variants ───────────────────────────────────────────── *)
  j := 0;
  FOR i := 1 TO 5 DO INC(j, i) END;
  Check("FOR up sum=15",  j = 15);
  j := 0;
  FOR i := 5 TO 1 BY -1 DO INC(j, i) END;
  Check("FOR down sum=15", j = 15);
  j := 0;
  FOR i := 0 TO 8 BY 2 DO INC(j) END;
  Check("FOR step 2 cnt=5", j = 5);

  (* ── 8. WHILE / REPEAT / LOOP+EXIT ──────────────────────────────────── *)
  i := 1;  j := 0;
  WHILE i <= 10 DO INC(j, i); INC(i) END;
  Check("WHILE sum=55",   j = 55);

  i := 1;  j := 0;
  REPEAT INC(j, i); INC(i) UNTIL i > 10;
  Check("REPEAT sum=55",  j = 55);

  i := 0;
  LOOP INC(i); IF i = 7 THEN EXIT END END;
  Check("LOOP EXIT=7",    i = 7);

  (* ── 9. CASE on INTEGER ─────────────────────────────────────────────── *)
  j := 0;
  FOR i := 0 TO 4 DO
    CASE i OF
      0:     INC(j, 1)
    | 1, 2:  INC(j, 10)
    | 3:     INC(j, 100)
    ELSE     INC(j, 1000)
    END
  END;
  Check("CASE int",  j = 1121);

  (* ── 10. CASE on CHAR ───────────────────────────────────────────────── *)
  j := 0;
  s := "Hello";
  FOR i := 0 TO 4 DO
    CASE s[i] OF
      'H':      INC(j, 1)
    | 'e':      INC(j, 2)
    | 'l':      INC(j, 4)
    | 'o':      INC(j, 8)
    ELSE        INC(j, 16)
    END
  END;
  Check("CASE char",  j = 19);  (* 1+2+4+4+8 *)

  (* ── 11. VAR parameters ─────────────────────────────────────────────── *)
  i := 3;  j := 7;
  Swap(i, j);
  Check("VAR Swap",   (i = 7) & (j = 3));

  (* ── 12. Nested procedure / outer variable ──────────────────────────── *)
  Check("Nested outer var",  NestedOuter() = 20);

  (* ── 13. Recursion ──────────────────────────────────────────────────── *)
  Check("Fib(10)=55",  Fib(10) = 55);

  (* ── 14. Open array parameter ───────────────────────────────────────── *)
  arr5[0] := 1; arr5[1] := 2; arr5[2] := 3; arr5[3] := 4; arr5[4] := 5;
  Check("SumArray",  SumArray(arr5) = 15);

  (* ── 15. Multi-dimensional array / LEN ──────────────────────────────── *)
  k := 0;
  FOR i := 0 TO LEN(mat) - 1 DO
    FOR j := 0 TO LEN(mat[0]) - 1 DO
      mat[i][j] := k; INC(k)
    END
  END;
  Check("2-D array assign",  (mat[2][2] = 8) & (mat[0][0] = 0));
  Check("LEN 2-D",           LEN(mat) = 3);
  Check("LEN(a,0)",          LEN(mat, 0) = 3);
  Check("LEN(a,1)",          LEN(mat, 1) = 3);

  (* ── 16. Procedure-type variable ────────────────────────────────────── *)
  fn := Double;
  Check("ProcVar Double",  fn(5) = 10);
  fn := Triple;
  Check("ProcVar Triple",  fn(5) = 15);

  (* ── 17. Pointer / record inheritance / IS / WITH ───────────────────── *)
  NEW(rc);  rc.w := 4;  rc.h := 6;  rc.area := FLT(rc.w * rc.h);
  NEW(ci);  ci.r := 3;  ci.area := Math.pi * FLT(ci.r * ci.r);

  p := rc;
  Check("IS Rect",       p IS RectRec);
  Check("IS not Circle", ~(p IS CircleRec));
  WITH p: RectRec DO
    Check("WITH Rect w",   p.w = 4);
    Check("WITH Rect h",   p.h = 6);
  END;

  p := ci;
  Check("IS Circle",  p IS CircleRec);
  WITH p: CircleRec DO
    Check("WITH Circle r",  p.r = 3);
  END;

  (* ── 18. COPY builtin ───────────────────────────────────────────────── *)
  s := "original";
  COPY(s, t);
  t[0] := 'X';
  Check("COPY independent",  (s[0] = 'o') & (t[0] = 'X'));

  (* ── 19. INC / DEC variants ─────────────────────────────────────────── *)
  i := 5;
  INC(i);     Check("INC(i)",     i = 6);
  INC(i, 4);  Check("INC(i,4)",   i = 10);
  DEC(i);     Check("DEC(i)",     i = 9);
  DEC(i, 3);  Check("DEC(i,3)",   i = 6);

  (* ── 20. Strings module ─────────────────────────────────────────────── *)
  s := "Hello, World";
  Check("Strings.Length",    Strings.Length(s) = 12);
  Check("Strings.Pos found", Strings.Pos("World", s) = 7);
  Check("Strings.Pos miss",  Strings.Pos("xyz", s) = -1);
  Strings.Extract(s, 7, 5, t);
  Check("Strings.Extract",   t = "World");
  Strings.ToUpper(t);
  Check("Strings.ToUpper",   t = "WORLD");
  Strings.ToLower(t);
  Check("Strings.ToLower",   t = "world");
  s := "  trim me  ";
  Strings.Trim(s);
  Check("Strings.Trim",      s = "trim me");
  Strings.IntToStr(42, s);
  Check("Strings.IntToStr",  s = "42");
  Check("Strings.StrToInt",  Strings.StrToInt("123", i) & (i = 123));
  Check("Strings.StartsWith",Strings.StartsWith("foobar", "foo"));
  Check("Strings.EndsWith",  Strings.EndsWith("foobar", "bar"));
  s := "aa,bb,cc";
  Strings.Split(s, ',', 1, t);
  Check("Strings.Split",     t = "bb");

  (* ── 21. LONGINT arithmetic ─────────────────────────────────────────── *)
  li := 2000000;  li := li * 5000;   (* avoid 32-bit overflow in constant expr *)
  lj := li + 1;
  Check("LONGINT mul",  li = 10000000000);
  Check("LONGINT add",  lj = 10000000001);
  Check("LONGINT neg",  -li = -10000000000);

  (* ── 22. Boolean expression with mixed AND/OR/NOT ───────────────────── *)
  i := 5;
  Check("Bool mix 1",  (i > 3) & (i < 10) OR (i = 99));
  Check("Bool mix 2",  ~((i < 0) OR (i > 100)));

  (* ── 23. Real comparisons and Math module ───────────────────────────── *)
  Check("Math.sqrt",   ABS(Math.sqrt(2.0) - 1.41421356) < 0.0001);
  Check("Math.pi",     ABS(Math.pi - 3.14159265) < 0.0001);
  Check("Math.floor",  Math.floor(3.9) = 3.0);
  Check("Math.ceil",   Math.ceil(3.1) = 4.0);
  Check("Math.entier", Math.entier(-2.1) = -3);
  Check("Math.clamp",  Math.clamp(15.0, 0.0, 10.0) = 10.0);
  Check("Math.min",    Math.min(3.0, 7.0) = 3.0);
  Check("Math.max",    Math.max(3.0, 7.0) = 7.0);

  (* ── 24. String relational ordering ────────────────────────────────── *)
  s := "apple";  t := "banana";
  Check("str < true",   s < t);
  Check("str < false",  ~(t < s));
  Check("str > true",   t > s);
  Check("str > false",  ~(s > t));
  Check("str <= less",  s <= t);
  Check("str <= equal", s <= s);
  Check("str >= greater", t >= s);
  Check("str >= equal",   t >= t);
  Check("str lit <",    s < "cherry");
  Check("str lit >",    t > "aardvark");

  Out.Ln;
  Out.String("Done."); Out.Ln;
END transpilertest.
