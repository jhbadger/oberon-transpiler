MODULE paralleltest;
IMPORT Parallel, Out;

CONST N = 10000;

VAR
  input:    ARRAY N OF INTEGER;
  squares:  ARRAY N OF INTEGER;
  prefix:   ARRAY N OF INTEGER;
  ncpu, i, ok: INTEGER;
  expected: INTEGER;

(* Each element squared in parallel *)
PROCEDURE DoSquare(i: INTEGER);
BEGIN squares[i] := input[i] * input[i] END DoSquare;

(* Negate input in parallel — tests that a second call works correctly *)
PROCEDURE DoNegate(i: INTEGER);
BEGIN prefix[i] := -input[i] END DoNegate;

BEGIN
  ncpu := Parallel.NumCPU();
  Out.String("CPUs detected: "); Out.Int(ncpu); Out.Ln();
  IF ncpu > 0 THEN Out.String("PASS: NumCPU > 0") ELSE Out.String("FAIL: NumCPU = 0") END;
  Out.Ln();

  (* fill input 0..N-1 *)
  FOR i := 0 TO N - 1 DO input[i] := i END;

  (* parallel square *)
  Parallel.For(0, N, DoSquare, ncpu);

  ok := 1;
  FOR i := 0 TO N - 1 DO
    IF squares[i] # input[i] * input[i] THEN ok := 0 END
  END;
  IF ok = 1 THEN Out.String("PASS: parallel squares correct")
  ELSE Out.String("FAIL: parallel squares wrong") END;
  Out.Ln();

  (* parallel negate — second For call on same data *)
  Parallel.For(0, N, DoNegate, ncpu);

  ok := 1;
  FOR i := 0 TO N - 1 DO
    IF prefix[i] # -i THEN ok := 0 END
  END;
  IF ok = 1 THEN Out.String("PASS: parallel negate correct")
  ELSE Out.String("FAIL: parallel negate wrong") END;
  Out.Ln();

  (* single-threaded fallback path *)
  FOR i := 0 TO N - 1 DO squares[i] := 0 END;
  Parallel.For(0, N, DoSquare, 1);
  ok := 1;
  FOR i := 0 TO N - 1 DO
    IF squares[i] # input[i] * input[i] THEN ok := 0 END
  END;
  IF ok = 1 THEN Out.String("PASS: single-thread path correct")
  ELSE Out.String("FAIL: single-thread path wrong") END;
  Out.Ln();

  (* empty range — must not crash *)
  Parallel.For(5, 5, DoSquare, ncpu);
  Out.String("PASS: empty range did not crash"); Out.Ln();

  (* sum-of-squares formula check over a small range to avoid overflow:
     sum(i^2, 0..999) = 1000*999*1999/6 = 332833500 *)
  expected := 1000 * 999 * 1999 DIV 6;
  ok := 0;
  FOR i := 0 TO 999 DO INC(ok, squares[i]) END;
  IF ok = expected THEN Out.String("PASS: sum-of-squares formula matches")
  ELSE
    Out.String("FAIL: sum="); Out.Int(ok);
    Out.String(" expected="); Out.Int(expected)
  END;
  Out.Ln()
END paralleltest.
