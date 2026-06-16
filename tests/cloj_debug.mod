MODULE cloj_debug;
IMPORT Cloj, Out, Args;
VAR v: Cloj.Value;
BEGIN
  Out.String("Init..."); Out.Ln;
  Cloj.Init;
  Out.String("Init done"); Out.Ln;
  v := Cloj.EvalStr("(+ 1 2)");
  Out.String("basic ok"); Out.Ln;
  v := Cloj.EvalStr("(count (range 5))");
  IF Cloj.err THEN Out.String("range 5 err: "); Out.String(Cloj.errMsg); Out.Ln; Cloj.err := FALSE
  ELSE Out.String("range 5 ok"); Out.Ln END;
  v := Cloj.EvalStr("(take 3 (range))");
  IF Cloj.err THEN Out.String("take range err: "); Out.String(Cloj.errMsg); Out.Ln; Cloj.err := FALSE
  ELSE Out.String("take range ok"); Out.Ln END;
  v := Cloj.EvalStr("(map inc [1 2 3])");
  IF Cloj.err THEN Out.String("map err: "); Out.String(Cloj.errMsg); Out.Ln; Cloj.err := FALSE
  ELSE Out.String("map ok"); Out.Ln END;
  v := Cloj.EvalStr("(filter even? [1 2 3 4])");
  IF Cloj.err THEN Out.String("filter err: "); Out.String(Cloj.errMsg); Out.Ln; Cloj.err := FALSE
  ELSE Out.String("filter ok"); Out.Ln END;
  v := Cloj.EvalStr("(take 3 (cycle [1 2]))");
  IF Cloj.err THEN Out.String("cycle err: "); Out.String(Cloj.errMsg); Out.Ln; Cloj.err := FALSE
  ELSE Out.String("cycle ok"); Out.Ln END;
  Out.String("test repeat-inf..."); Out.Ln;
  v := Cloj.EvalStr("(repeat :x)");
  IF Cloj.err THEN Out.String("repeat-inf err: "); Out.String(Cloj.errMsg); Out.Ln; Cloj.err := FALSE
  ELSE Out.String("repeat-inf lazy ok"); Out.Ln END;
  Out.String("test take repeat-inf..."); Out.Ln;
  v := Cloj.EvalStr("(take 3 (repeat :x))");
  IF Cloj.err THEN Out.String("take-repeat err: "); Out.String(Cloj.errMsg); Out.Ln; Cloj.err := FALSE
  ELSE Out.String("take-repeat lazy ok"); Out.Ln END;
  Out.String("test count take repeat-inf..."); Out.Ln;
  v := Cloj.EvalStr("(count (take 3 (repeat :x)))");
  IF Cloj.err THEN Out.String("count-take-repeat err: "); Out.String(Cloj.errMsg); Out.Ln; Cloj.err := FALSE
  ELSE Out.String("count-take-repeat ok="); Out.Int(v.i, 0); Out.Ln END;
  Out.String("test repeat 2-arg..."); Out.Ln;
  v := Cloj.EvalStr("(repeat 5 :x)");
  IF Cloj.err THEN Out.String("repeat5 lazy err: "); Out.String(Cloj.errMsg); Out.Ln; Cloj.err := FALSE
  ELSE Out.String("repeat5 lazy ok"); Out.Ln END;
  Out.String("test count repeat 5..."); Out.Ln;
  v := Cloj.EvalStr("(count (repeat 5 :x))");
  IF Cloj.err THEN Out.String("repeat err: "); Out.String(Cloj.errMsg); Out.Ln; Cloj.err := FALSE
  ELSE Out.String("repeat ok, count="); Out.Int(v.i, 0); Out.Ln END;
  v := Cloj.EvalStr("(count (repeatedly 3 (fn [] 1)))");
  IF Cloj.err THEN Out.String("repeatedly err: "); Out.String(Cloj.errMsg); Out.Ln; Cloj.err := FALSE
  ELSE Out.String("repeatedly ok, count="); Out.Int(v.i, 0); Out.Ln END;
  Out.String("done"); Out.Ln
END cloj_debug.
