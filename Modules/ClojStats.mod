MODULE ClojStats;
(*
 * Example: wrapping Oberon procedures as Cloj builtins.
 *
 * Add to your clojrepl entry point:
 *   IMPORT Cloj, ClojStats;
 *   ...
 *   Cloj.AddOberonModule("stats", ClojStats.Export);
 *   Cloj.Main
 *
 * Then from Cloj:
 *   (import-oberon "stats")
 *   (stats/mean [1 2 3 4 5])       => 3.0
 *   (stats/variance [2 4 4 4 5 5 7 9])  => 4.0
 *   (stats/stddev [2 4 4 4 5 5 7 9])    => 2.0
 *)

IMPORT Cloj, Math;

PROCEDURE CollSum(coll: Cloj.Value; VAR sum: REAL; VAR n: INTEGER): BOOLEAN;
(* Sums a Cloj list/vector of numbers into sum; sets n. Returns FALSE on error. *)
VAR h: Cloj.Value;
BEGIN
  sum := 0.0; n := 0;
  WHILE ~Cloj.IsNil(coll) & ((coll.tag = Cloj.tList) OR (coll.tag = Cloj.tVec)) DO
    h := coll.head;
    IF h.tag = Cloj.tInt THEN sum := sum + FLT(h.i)
    ELSIF h.tag = Cloj.tReal THEN sum := sum + h.r
    ELSE Cloj.Error("non-numeric element"); RETURN FALSE
    END;
    INC(n); coll := coll.tail
  END;
  RETURN TRUE
END CollSum;

PROCEDURE BMean(args: Cloj.Value; env: Cloj.Env): Cloj.Value;
VAR sum: REAL; n: INTEGER;
BEGIN
  IF Cloj.IsNil(args.head) THEN RETURN Cloj.MkReal(0.0) END;
  IF ~CollSum(args.head, sum, n) THEN RETURN Cloj.NilV END;
  IF n = 0 THEN RETURN Cloj.MkReal(0.0) END;
  RETURN Cloj.MkReal(sum / FLT(n))
END BMean;

PROCEDURE BVariance(args: Cloj.Value; env: Cloj.Env): Cloj.Value;
VAR coll, h: Cloj.Value; sum, mean, diff: REAL; n: INTEGER;
BEGIN
  coll := args.head;
  IF Cloj.IsNil(coll) THEN RETURN Cloj.MkReal(0.0) END;
  IF ~CollSum(coll, sum, n) THEN RETURN Cloj.NilV END;
  IF n = 0 THEN RETURN Cloj.MkReal(0.0) END;
  mean := sum / FLT(n);
  sum := 0.0;
  WHILE ~Cloj.IsNil(coll) & ((coll.tag = Cloj.tList) OR (coll.tag = Cloj.tVec)) DO
    h := coll.head;
    IF h.tag = Cloj.tInt THEN diff := FLT(h.i) - mean
    ELSE diff := h.r - mean END;
    sum := sum + diff * diff;
    coll := coll.tail
  END;
  RETURN Cloj.MkReal(sum / FLT(n))
END BVariance;

PROCEDURE BStddev(args: Cloj.Value; env: Cloj.Env): Cloj.Value;
VAR v: Cloj.Value;
BEGIN
  v := BVariance(args, env);
  IF Cloj.err THEN RETURN Cloj.NilV END;
  RETURN Cloj.MkReal(Math.sqrt(v.r))
END BStddev;

PROCEDURE Export*(env: Cloj.Env);
BEGIN
  Cloj.RegisterBuiltin(env, "stats/mean",     BMean);
  Cloj.RegisterBuiltin(env, "stats/variance", BVariance);
  Cloj.RegisterBuiltin(env, "stats/stddev",   BStddev)
END Export;

END ClojStats.
