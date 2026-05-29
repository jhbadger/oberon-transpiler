MODULE BioStats;
(*
  BioStats — Log-probabilities, combinatorics, and Phred quality scores.

  Log values use natural logarithm (base e).
  LogZero is the sentinel for log(0) = -infinity.

  LogFactorial uses exact summation for n <= 20 and Stirling + correction
  term 1/(12n) for n > 20; relative error in n! is < 3e-5 for all n > 1.

  FisherExact returns a two-tailed hypergeometric p-value.
  NormalCDF uses the A&S 7.1.26 rational approximation (max error ~1.5e-7).
*)

IMPORT Math;

VAR
  LogZero* : REAL;   (* log-probability representing probability 0; initialised to -1.0E308 *)

(* ------------------------------------------------------------------ *)
(*  Phred quality scores                                                *)
(* ------------------------------------------------------------------ *)

PROCEDURE PhredToProb*(q: INTEGER): REAL;
(* Error probability for Phred score q: 10^(-q/10). *)
BEGIN
  RETURN Math.power(10.0, -FLT(q) / 10.0)
END PhredToProb;

PROCEDURE ProbToPhred*(p: REAL): INTEGER;
(* Phred score for error probability p: FLOOR(-10*log10(p)), clamped to [0,93]. *)
VAR q: INTEGER;
BEGIN
  IF p <= 0.0 THEN RETURN 93 END;
  IF p >= 1.0 THEN RETURN 0  END;
  q := Math.entier(-10.0 * Math.log(p));
  IF q < 0  THEN q := 0  END;
  IF q > 93 THEN q := 93 END;
  RETURN q
END ProbToPhred;

(* ------------------------------------------------------------------ *)
(*  Log-probability arithmetic                                          *)
(* ------------------------------------------------------------------ *)

PROCEDURE LogAdd*(a, b: REAL): REAL;
(* Numerically stable log(exp(a) + exp(b)). *)
BEGIN
  IF a <= LogZero THEN RETURN b END;
  IF b <= LogZero THEN RETURN a END;
  IF a >= b THEN RETURN a + Math.ln(1.0 + Math.exp(b - a))
  ELSE            RETURN b + Math.ln(1.0 + Math.exp(a - b))
  END
END LogAdd;

PROCEDURE LogSum*(arr: ARRAY OF REAL; n: INTEGER): REAL;
(* log(sum of exp(arr[0..n-1])). *)
VAR acc: REAL; i: INTEGER;
BEGIN
  IF n <= 0 THEN RETURN LogZero END;
  acc := arr[0];
  FOR i := 1 TO n - 1 DO acc := LogAdd(acc, arr[i]) END;
  RETURN acc
END LogSum;

(* ------------------------------------------------------------------ *)
(*  Combinatorics                                                       *)
(* ------------------------------------------------------------------ *)

PROCEDURE LogFactorial*(n: INTEGER): REAL;
(* ln(n!). Exact sum for n <= 20; Stirling + 1/(12n) correction for n > 20. *)
VAR i: INTEGER; r, fn: REAL;
BEGIN
  IF n <= 1 THEN RETURN 0.0 END;
  IF n <= 20 THEN
    r := 0.0;
    FOR i := 2 TO n DO r := r + Math.ln(FLT(i)) END;
    RETURN r
  END;
  fn := FLT(n);
  RETURN fn * Math.ln(fn) - fn + 0.5 * Math.ln(2.0 * Math.pi * fn) + 1.0 / (12.0 * fn)
END LogFactorial;

PROCEDURE Factorial*(n: INTEGER): REAL;
(* n! as REAL, computed via exp(LogFactorial(n)). *)
BEGIN
  RETURN Math.exp(LogFactorial(n))
END Factorial;

PROCEDURE LogBinomial*(n, k: INTEGER): REAL;
(* ln C(n,k); returns LogZero if k < 0 or k > n. *)
BEGIN
  IF (k < 0) OR (k > n) THEN RETURN LogZero END;
  IF (k = 0) OR (k = n) THEN RETURN 0.0   END;
  RETURN LogFactorial(n) - LogFactorial(k) - LogFactorial(n - k)
END LogBinomial;

PROCEDURE Binomial*(n, k: INTEGER): REAL;
(* C(n,k) as REAL. *)
VAR lb: REAL;
BEGIN
  lb := LogBinomial(n, k);
  IF lb <= LogZero THEN RETURN 0.0 END;
  RETURN Math.exp(lb)
END Binomial;

PROCEDURE BinomialProb*(n, k: INTEGER; p: REAL): REAL;
(* P(X=k) for X ~ Binomial(n, p). *)
VAR lp: REAL;
BEGIN
  IF (k < 0) OR (k > n) THEN RETURN 0.0 END;
  IF p <= 0.0 THEN
    IF k = 0 THEN RETURN 1.0 ELSE RETURN 0.0 END
  END;
  IF p >= 1.0 THEN
    IF k = n THEN RETURN 1.0 ELSE RETURN 0.0 END
  END;
  lp := LogBinomial(n, k);
  IF k > 0     THEN lp := lp + FLT(k)     * Math.ln(p)       END;
  IF k < n     THEN lp := lp + FLT(n - k) * Math.ln(1.0 - p) END;
  IF lp <= LogZero THEN RETURN 0.0 END;
  RETURN Math.exp(lp)
END BinomialProb;

PROCEDURE PoissonProb*(lambda: REAL; k: INTEGER): REAL;
(* P(X=k) for X ~ Poisson(lambda). *)
VAR lp: REAL;
BEGIN
  IF k < 0 THEN RETURN 0.0 END;
  IF lambda <= 0.0 THEN
    IF k = 0 THEN RETURN 1.0 ELSE RETURN 0.0 END
  END;
  lp := FLT(k) * Math.ln(lambda) - lambda - LogFactorial(k);
  IF lp <= LogZero THEN RETURN 0.0 END;
  RETURN Math.exp(lp)
END PoissonProb;

(* ------------------------------------------------------------------ *)
(*  Normal distribution                                                 *)
(* ------------------------------------------------------------------ *)

PROCEDURE Erf(x: REAL): REAL;
(* A&S 7.1.26 rational approximation; max |error| ≈ 1.5e-7. *)
VAR t, poly, ax, sign: REAL;
BEGIN
  IF x >= 0.0 THEN sign := 1.0; ax := x
  ELSE             sign := -1.0; ax := -x
  END;
  t    := 1.0 / (1.0 + 0.3275911 * ax);
  poly := t * (0.254829592 + t * (-0.284496736 + t * (1.421413741 +
          t * (-1.453152027 + t * 1.061405429))));
  RETURN sign * (1.0 - poly * Math.exp(-ax * ax))
END Erf;

PROCEDURE NormalPDF*(x, mu, sigma: REAL): REAL;
(* Probability density of N(mu, sigma^2) at x. *)
VAR z: REAL;
BEGIN
  IF sigma <= 0.0 THEN RETURN 0.0 END;
  z := (x - mu) / sigma;
  RETURN Math.exp(-0.5 * z * z) / (sigma * Math.sqrt(2.0 * Math.pi))
END NormalPDF;

PROCEDURE NormalCDF*(x, mu, sigma: REAL): REAL;
(* P(X <= x) for X ~ N(mu, sigma^2) via erf rational approximation. *)
VAR z: REAL;
BEGIN
  IF sigma <= 0.0 THEN
    IF x >= mu THEN RETURN 1.0 ELSE RETURN 0.0 END
  END;
  z := (x - mu) / (sigma * Math.sqrt(2.0));
  RETURN 0.5 * (1.0 + Erf(z))
END NormalCDF;

(* ------------------------------------------------------------------ *)
(*  Fisher's exact test                                                 *)
(* ------------------------------------------------------------------ *)

PROCEDURE FisherExact*(a, b, c, d: INTEGER): REAL;
(*
  Two-tailed hypergeometric p-value for a 2×2 contingency table:
    a  b | R1
    c  d | R2
    --------
    C1 C2   N
  Sums all hypergeometric probabilities <= P(observed table).
*)
VAR
  R1, R2, C1, N, kMin, kMax, k : INTEGER;
  logDenom, pTarget, pk, pTotal : REAL;
BEGIN
  R1 := a + b; R2 := c + d; C1 := a + c; N := R1 + R2;
  IF (N = 0) OR (C1 = 0) OR (C1 = N) THEN RETURN 1.0 END;

  kMin := C1 - R2; IF kMin < 0 THEN kMin := 0 END;
  kMax := R1;      IF kMax > C1 THEN kMax := C1 END;

  logDenom := LogBinomial(N, C1);
  IF logDenom <= LogZero THEN RETURN 1.0 END;

  pTarget := Math.exp(LogBinomial(R1, a) + LogBinomial(R2, C1 - a) - logDenom);

  pTotal := 0.0;
  FOR k := kMin TO kMax DO
    pk := Math.exp(LogBinomial(R1, k) + LogBinomial(R2, C1 - k) - logDenom);
    IF pk <= pTarget * (1.0 + 1.0E-9) THEN pTotal := pTotal + pk END
  END;
  IF pTotal > 1.0 THEN pTotal := 1.0 END;
  RETURN pTotal
END FisherExact;

BEGIN
  LogZero := -1.0E308
END BioStats.
