MODULE Cloj;

IMPORT Out, Strings, Math, History, Files, Args;

CONST
  (* Value tags *)
  tNil*    = 0;
  tBool*   = 1;
  tInt*    = 2;
  tReal*   = 3;
  tStr*    = 4;
  tSym*    = 5;
  tKey*    = 6;
  tList*   = 7;
  tVec*    = 8;
  tMap*    = 9;
  tFn*     = 10;
  tBuiltin*= 11;
  tMacro*  = 12;

  MaxTok   = 65536;
  MaxStr   = 256;

TYPE
  Value*  = POINTER TO ValueDesc;
  Env*    = POINTER TO EnvDesc;
  Binding = POINTER TO BindingDesc;
  Builtin = PROCEDURE(args: Value; env: Env): Value;
  EvalProc = PROCEDURE(expr: Value; env: Env): Value;

  ValueDesc* = RECORD
    tag*: INTEGER;
    b*: BOOLEAN;
    i*: INTEGER;
    r*: REAL;
    s*: ARRAY MaxStr OF CHAR;
    head*, tail*: Value;
    params*: Value;
    body*: Value;
    closure*: Env;
    builtin*: Builtin;
    name*: ARRAY 32 OF CHAR;
  END;

  BindingDesc = RECORD
    name: ARRAY MaxStr OF CHAR;
    val: Value;
    next: Binding;
  END;

  EnvDesc* = RECORD
    bindings: Binding;
    parent: Env;
  END;

VAR
  GlobalEnv: Env;
  NilV*, TrueV*, FalseV*: Value;

  src: ARRAY MaxTok OF CHAR;
  srcLen, srcPos: INTEGER;
  tok: ARRAY MaxStr OF CHAR;
  tokKind: INTEGER;

  err*: BOOLEAN;
  errMsg*: ARRAY 256 OF CHAR;

  EvalRef: EvalProc;  (* forward indirection *)

(* ---------- Value constructors ---------- *)

PROCEDURE MkNil(): Value;
VAR v: Value;
BEGIN NEW(v); v.tag := tNil; RETURN v END MkNil;

PROCEDURE MkBool(b: BOOLEAN): Value;
BEGIN
  IF b THEN RETURN TrueV ELSE RETURN FalseV END
END MkBool;

PROCEDURE MkInt*(n: INTEGER): Value;
VAR v: Value;
BEGIN NEW(v); v.tag := tInt; v.i := n; RETURN v END MkInt;

PROCEDURE MkReal*(x: REAL): Value;
VAR v: Value;
BEGIN NEW(v); v.tag := tReal; v.r := x; RETURN v END MkReal;

PROCEDURE MkStr*(s: ARRAY OF CHAR): Value;
VAR v: Value;
BEGIN NEW(v); v.tag := tStr; Strings.Copy(s, v.s); RETURN v END MkStr;

PROCEDURE MkSym*(s: ARRAY OF CHAR): Value;
VAR v: Value;
BEGIN NEW(v); v.tag := tSym; Strings.Copy(s, v.s); RETURN v END MkSym;

PROCEDURE MkKey*(s: ARRAY OF CHAR): Value;
VAR v: Value;
BEGIN NEW(v); v.tag := tKey; Strings.Copy(s, v.s); RETURN v END MkKey;

PROCEDURE Cons*(h, t: Value): Value;
VAR v: Value;
BEGIN
  NEW(v); v.tag := tList; v.head := h; v.tail := t;
  RETURN v
END Cons;

PROCEDURE MkVec(h, t: Value): Value;
VAR v: Value;
BEGIN
  NEW(v); v.tag := tVec; v.head := h; v.tail := t;
  RETURN v
END MkVec;

PROCEDURE MkMap(keys, vals: Value): Value;
VAR v: Value;
BEGIN
  NEW(v); v.tag := tMap; v.head := keys; v.tail := vals;
  RETURN v
END MkMap;

PROCEDURE MkBuiltin(name: ARRAY OF CHAR; fn: Builtin): Value;
VAR v: Value;
BEGIN
  NEW(v); v.tag := tBuiltin; v.builtin := fn;
  Strings.Copy(name, v.name);
  RETURN v
END MkBuiltin;

PROCEDURE IsNil(v: Value): BOOLEAN;
BEGIN RETURN (v = NIL) OR (v.tag = tNil) END IsNil;

PROCEDURE IsTruthy(v: Value): BOOLEAN;
BEGIN
  IF IsNil(v) THEN RETURN FALSE END;
  IF (v.tag = tBool) & ~v.b THEN RETURN FALSE END;
  RETURN TRUE
END IsTruthy;

PROCEDURE ListLen(v: Value): INTEGER;
VAR n: INTEGER;
BEGIN
  n := 0;
  WHILE ~IsNil(v) & ((v.tag = tList) OR (v.tag = tVec)) DO
    INC(n); v := v.tail
  END;
  RETURN n
END ListLen;

(* ---------- Error reporting ---------- *)

PROCEDURE Error*(msg: ARRAY OF CHAR);
BEGIN
  err := TRUE;
  Strings.Copy(msg, errMsg)
END Error;

(* ---------- Environment ---------- *)

PROCEDURE NewEnv*(parent: Env): Env;
VAR e: Env;
BEGIN NEW(e); e.parent := parent; e.bindings := NIL; RETURN e END NewEnv;

PROCEDURE Define*(e: Env; name: ARRAY OF CHAR; v: Value);
VAR b: Binding;
BEGIN
  b := e.bindings;
  WHILE b # NIL DO
    IF b.name = name THEN b.val := v; RETURN END;
    b := b.next
  END;
  NEW(b); Strings.Copy(name, b.name); b.val := v;
  b.next := e.bindings; e.bindings := b
END Define;

PROCEDURE Lookup*(e: Env; name: ARRAY OF CHAR): Value;
VAR b: Binding;
BEGIN
  WHILE e # NIL DO
    b := e.bindings;
    WHILE b # NIL DO
      IF b.name = name THEN RETURN b.val END;
      b := b.next
    END;
    e := e.parent
  END;
  RETURN NIL
END Lookup;

(* ---------- Tokenizer ---------- *)

PROCEDURE IsSpace(c: CHAR): BOOLEAN;
BEGIN RETURN (c = ' ') OR (c = 09X) OR (c = 0AX) OR (c = 0DX) OR (c = ',') END IsSpace;

PROCEDURE IsDelim(c: CHAR): BOOLEAN;
BEGIN
  RETURN IsSpace(c) OR (c = '(') OR (c = ')') OR (c = '[') OR (c = ']')
      OR (c = '{') OR (c = '}') OR (c = '"') OR (c = 0X)
END IsDelim;

PROCEDURE SkipWS;
VAR c: CHAR;
BEGIN
  WHILE srcPos < srcLen DO
    c := src[srcPos];
    IF IsSpace(c) THEN INC(srcPos)
    ELSIF c = ';' THEN
      WHILE (srcPos < srcLen) & (src[srcPos] # 0AX) DO INC(srcPos) END
    ELSE RETURN END
  END
END SkipWS;

PROCEDURE NextTok;
VAR c: CHAR; i: INTEGER;
BEGIN
  SkipWS;
  IF srcPos >= srcLen THEN tokKind := 0; RETURN END;
  c := src[srcPos];
  IF c = '(' THEN tokKind := 1; INC(srcPos)
  ELSIF c = ')' THEN tokKind := 2; INC(srcPos)
  ELSIF c = '[' THEN tokKind := 3; INC(srcPos)
  ELSIF c = ']' THEN tokKind := 4; INC(srcPos)
  ELSIF c = '{' THEN tokKind := 5; INC(srcPos)
  ELSIF c = '}' THEN tokKind := 6; INC(srcPos)
  ELSIF c = "'" THEN tokKind := 7; INC(srcPos)
  ELSIF c = '"' THEN
    tokKind := 9; INC(srcPos); i := 0;
    WHILE (srcPos < srcLen) & (src[srcPos] # '"') & (i < MaxStr-1) DO
      IF (src[srcPos] = '\') & (srcPos+1 < srcLen) THEN
        INC(srcPos);
        IF src[srcPos] = 'n' THEN tok[i] := 0AX
        ELSIF src[srcPos] = 't' THEN tok[i] := 09X
        ELSIF src[srcPos] = '\' THEN tok[i] := '\'
        ELSIF src[srcPos] = '"' THEN tok[i] := '"'
        ELSE tok[i] := src[srcPos] END;
        INC(i); INC(srcPos)
      ELSE tok[i] := src[srcPos]; INC(i); INC(srcPos) END
    END;
    tok[i] := 0X;
    IF (srcPos < srcLen) & (src[srcPos] = '"') THEN INC(srcPos)
    ELSE Error("unterminated string") END
  ELSE
    tokKind := 8; i := 0;
    WHILE (srcPos < srcLen) & ~IsDelim(src[srcPos]) & (i < MaxStr-1) DO
      tok[i] := src[srcPos]; INC(i); INC(srcPos)
    END;
    tok[i] := 0X
  END
END NextTok;

(* ---------- Parser ---------- *)

PROCEDURE IsNumber(s: ARRAY OF CHAR; VAR hasDot: BOOLEAN): BOOLEAN;
VAR i: INTEGER; c: CHAR; sawDigit: BOOLEAN;
BEGIN
  hasDot := FALSE; sawDigit := FALSE; i := 0;
  IF (s[0] = '-') OR (s[0] = '+') THEN INC(i) END;
  WHILE s[i] # 0X DO
    c := s[i];
    IF (c >= '0') & (c <= '9') THEN sawDigit := TRUE
    ELSIF c = '.' THEN
      IF hasDot THEN RETURN FALSE END;
      hasDot := TRUE
    ELSE RETURN FALSE END;
    INC(i)
  END;
  RETURN sawDigit
END IsNumber;

PROCEDURE ParseAtom(): Value;
VAR hasDot, ok: BOOLEAN; n: INTEGER; x: REAL; sub: ARRAY MaxStr OF CHAR;
BEGIN
  IF tok = "nil" THEN RETURN NilV END;
  IF tok = "true" THEN RETURN TrueV END;
  IF tok = "false" THEN RETURN FalseV END;
  IF tok[0] = ':' THEN
    Strings.Extract(tok, 1, Strings.Length(tok)-1, sub);
    RETURN MkKey(sub)
  END;
  IF IsNumber(tok, hasDot) THEN
    IF hasDot THEN
      ok := Strings.StrToReal(tok, x);
      IF ok THEN RETURN MkReal(x) END
    ELSE
      ok := Strings.StrToInt(tok, n);
      IF ok THEN RETURN MkInt(n) END
    END
  END;
  RETURN MkSym(tok)
END ParseAtom;

PROCEDURE ParseExpr(): Value;

  PROCEDURE ParseSeq(closeKind: INTEGER): Value;
  VAR first, last, cell, v: Value;
  BEGIN
    first := NilV; last := NIL;
    NextTok;
    WHILE (tokKind # closeKind) & (tokKind # 0) & ~err DO
      v := ParseExpr();
      IF err THEN RETURN NilV END;
      IF closeKind = 4 THEN cell := MkVec(v, NilV)
      ELSE cell := Cons(v, NilV) END;
      IF last = NIL THEN first := cell ELSE last.tail := cell END;
      last := cell;
      NextTok
    END;
    IF tokKind # closeKind THEN Error("unbalanced delimiter") END;
    RETURN first
  END ParseSeq;

  PROCEDURE ParseMap(): Value;
  VAR keys, vals, kLast, vLast, k, v, c: Value;
  BEGIN
    keys := NilV; vals := NilV; kLast := NIL; vLast := NIL;
    NextTok;
    WHILE (tokKind # 6) & (tokKind # 0) & ~err DO
      k := ParseExpr();
      IF err THEN RETURN NilV END;
      NextTok;
      IF tokKind = 6 THEN Error("map missing value"); RETURN NilV END;
      v := ParseExpr();
      IF err THEN RETURN NilV END;
      c := Cons(k, NilV);
      IF kLast = NIL THEN keys := c ELSE kLast.tail := c END;
      kLast := c;
      c := Cons(v, NilV);
      IF vLast = NIL THEN vals := c ELSE vLast.tail := c END;
      vLast := c;
      NextTok
    END;
    IF tokKind # 6 THEN Error("unbalanced map") END;
    RETURN MkMap(keys, vals)
  END ParseMap;

VAR v, q: Value;
BEGIN
  CASE tokKind OF
    0: Error("unexpected eof"); RETURN NilV
  | 1: RETURN ParseSeq(2)
  | 3: RETURN ParseSeq(4)
  | 5: RETURN ParseMap()
  | 7: NextTok; v := ParseExpr();
       q := Cons(MkSym("quote"), Cons(v, NilV));
       RETURN q
  | 8: RETURN ParseAtom()
  | 9: RETURN MkStr(tok)
  ELSE Error("unexpected token"); RETURN NilV
  END
END ParseExpr;

PROCEDURE ReadStr*(s: ARRAY OF CHAR): Value;
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (s[i] # 0X) & (i < MaxTok-1) DO src[i] := s[i]; INC(i) END;
  srcLen := i; srcPos := 0; err := FALSE;
  NextTok;
  IF tokKind = 0 THEN RETURN NilV END;
  RETURN ParseExpr()
END ReadStr;

(* Set up the tokenizer to read from a buffer; caller then loops
   calling ReadNext until it returns NIL with no error. *)
PROCEDURE BeginRead*(s: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (s[i] # 0X) & (i < MaxTok-1) DO src[i] := s[i]; INC(i) END;
  srcLen := i; srcPos := 0; err := FALSE;
  NextTok
END BeginRead;

PROCEDURE ReadNext*(): Value;
VAR v: Value;
BEGIN
  IF (tokKind = 0) OR err THEN RETURN NIL END;
  v := ParseExpr();
  IF err THEN RETURN NIL END;
  NextTok;
  RETURN v
END ReadNext;

(* ---------- Printer ---------- *)

PROCEDURE WriteStr(s: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  i := 0; WHILE s[i] # 0X DO Out.Char(s[i]); INC(i) END
END WriteStr;

PROCEDURE PrintValue*(v: Value; readable: BOOLEAN);
VAR p, k, val: Value; first: BOOLEAN; buf: ARRAY 32 OF CHAR; i: INTEGER;
BEGIN
  IF IsNil(v) THEN WriteStr("nil"); RETURN END;
  CASE v.tag OF
    tBool:
      IF v.b THEN WriteStr("true") ELSE WriteStr("false") END
  | tInt:
      Strings.IntToStr(v.i, buf); WriteStr(buf)
  | tReal:
      Strings.RealToStr(v.r, buf); WriteStr(buf)
  | tStr:
      IF readable THEN
        Out.Char('"');
        i := 0;
        WHILE v.s[i] # 0X DO
          IF v.s[i] = '"' THEN Out.Char('\'); Out.Char('"')
          ELSIF v.s[i] = '\' THEN Out.Char('\'); Out.Char('\')
          ELSIF v.s[i] = 0AX THEN Out.Char('\'); Out.Char('n')
          ELSE Out.Char(v.s[i]) END;
          INC(i)
        END;
        Out.Char('"')
      ELSE WriteStr(v.s) END
  | tSym: WriteStr(v.s)
  | tKey: Out.Char(':'); WriteStr(v.s)
  | tList:
      Out.Char('('); p := v; first := TRUE;
      WHILE ~IsNil(p) & (p.tag = tList) DO
        IF ~first THEN Out.Char(' ') END;
        PrintValue(p.head, readable);
        first := FALSE; p := p.tail
      END;
      Out.Char(')')
  | tVec:
      Out.Char('['); p := v; first := TRUE;
      WHILE ~IsNil(p) & (p.tag = tVec) DO
        IF ~first THEN Out.Char(' ') END;
        PrintValue(p.head, readable);
        first := FALSE; p := p.tail
      END;
      Out.Char(']')
  | tMap:
      Out.Char('{'); k := v.head; val := v.tail; first := TRUE;
      WHILE ~IsNil(k) DO
        IF ~first THEN Out.Char(' ') END;
        PrintValue(k.head, readable); Out.Char(' '); PrintValue(val.head, readable);
        first := FALSE; k := k.tail; val := val.tail
      END;
      Out.Char('}')
  | tFn: WriteStr("#<fn>")
  | tBuiltin: WriteStr("#<builtin "); WriteStr(v.name); Out.Char('>')
  | tMacro: WriteStr("#<macro>")
  ELSE WriteStr("#<?>")
  END
END PrintValue;

(* ---------- Apply (used by Eval and by higher-order builtins) ---------- *)

PROCEDURE EvalList(lst: Value; env: Env): Value;
VAR first, last, cell, v: Value;
BEGIN
  first := NilV; last := NIL;
  WHILE ~IsNil(lst) & (lst.tag = tList) & ~err DO
    v := EvalRef(lst.head, env);
    IF err THEN RETURN NilV END;
    cell := Cons(v, NilV);
    IF last = NIL THEN first := cell ELSE last.tail := cell END;
    last := cell;
    lst := lst.tail
  END;
  RETURN first
END EvalList;

PROCEDURE Apply*(fn, args: Value; env: Env): Value;
VAR newEnv: Env; params, a: Value; isRest: BOOLEAN;
  restList, rLast, c, result, body: Value;
BEGIN
  IF IsNil(fn) THEN Error("cannot call nil"); RETURN NilV END;
  IF fn.tag = tBuiltin THEN RETURN fn.builtin(args, env) END;
  IF fn.tag # tFn THEN Error("not a function"); RETURN NilV END;
  newEnv := NewEnv(fn.closure);
  params := fn.params; a := args; isRest := FALSE;
  WHILE ~IsNil(params) & ~isRest DO
    IF (params.head # NIL) & (params.head.tag = tSym)
       & (params.head.s[0] = "&") & (params.head.s[1] = 0X) THEN
      isRest := TRUE; params := params.tail;
      IF IsNil(params) THEN Error("& without param"); RETURN NilV END;
      restList := NilV; rLast := NIL;
      WHILE ~IsNil(a) DO
        c := Cons(a.head, NilV);
        IF rLast = NIL THEN restList := c ELSE rLast.tail := c END;
        rLast := c; a := a.tail
      END;
      Define(newEnv, params.head.s, restList);
      params := NilV
    ELSE
      IF IsNil(a) THEN Error("too few args"); RETURN NilV END;
      Define(newEnv, params.head.s, a.head);
      params := params.tail; a := a.tail
    END
  END;
  IF ~isRest & ~IsNil(a) THEN Error("too many args"); RETURN NilV END;
  result := NilV; body := fn.body;
  WHILE ~IsNil(body) & ~err DO
    result := EvalRef(body.head, newEnv);
    body := body.tail
  END;
  RETURN result
END Apply;

(* ---------- Evaluator ---------- *)

PROCEDURE Eval*(expr: Value; env: Env): Value;

  PROCEDURE DoDef(args: Value): Value;
  VAR v: Value;
  BEGIN
    IF IsNil(args) OR (args.head.tag # tSym) THEN
      Error("def needs symbol"); RETURN NilV
    END;
    v := EvalRef(args.tail.head, env);
    IF err THEN RETURN NilV END;
    Define(GlobalEnv, args.head.s, v);
    RETURN v
  END DoDef;

  PROCEDURE DoIf(args: Value): Value;
  VAR cond: Value;
  BEGIN
    cond := EvalRef(args.head, env);
    IF err THEN RETURN NilV END;
    IF IsTruthy(cond) THEN RETURN EvalRef(args.tail.head, env)
    ELSIF ~IsNil(args.tail.tail) THEN RETURN EvalRef(args.tail.tail.head, env)
    ELSE RETURN NilV END
  END DoIf;

  PROCEDURE DoFn(args: Value): Value;
  VAR v: Value;
  BEGIN
    NEW(v); v.tag := tFn;
    v.params := args.head;
    v.body := args.tail;
    v.closure := env;
    RETURN v
  END DoFn;

  PROCEDURE DoLet(args: Value): Value;
  VAR bindings, body, result, sym, val: Value; newEnv: Env;
  BEGIN
    bindings := args.head;
    IF IsNil(bindings) OR ((bindings.tag # tVec) & (bindings.tag # tList)) THEN
      Error("let needs bindings vector"); RETURN NilV
    END;
    newEnv := NewEnv(env);
    WHILE ~IsNil(bindings) DO
      sym := bindings.head; bindings := bindings.tail;
      IF IsNil(bindings) THEN Error("let: odd bindings"); RETURN NilV END;
      val := EvalRef(bindings.head, newEnv);
      IF err THEN RETURN NilV END;
      IF sym.tag # tSym THEN Error("let: not a symbol"); RETURN NilV END;
      Define(newEnv, sym.s, val);
      bindings := bindings.tail
    END;
    body := args.tail; result := NilV;
    WHILE ~IsNil(body) & ~err DO
      result := EvalRef(body.head, newEnv); body := body.tail
    END;
    RETURN result
  END DoLet;

  PROCEDURE DoDo(args: Value): Value;
  VAR result: Value;
  BEGIN
    result := NilV;
    WHILE ~IsNil(args) & ~err DO
      result := EvalRef(args.head, env); args := args.tail
    END;
    RETURN result
  END DoDo;

  PROCEDURE DoAnd(args: Value): Value;
  VAR v: Value;
  BEGIN
    v := TrueV;
    WHILE ~IsNil(args) & ~err DO
      v := EvalRef(args.head, env);
      IF ~IsTruthy(v) THEN RETURN v END;
      args := args.tail
    END;
    RETURN v
  END DoAnd;

  PROCEDURE DoOr(args: Value): Value;
  VAR v: Value;
  BEGIN
    v := NilV;
    WHILE ~IsNil(args) & ~err DO
      v := EvalRef(args.head, env);
      IF IsTruthy(v) THEN RETURN v END;
      args := args.tail
    END;
    RETURN v
  END DoOr;

  PROCEDURE DoWhen(args: Value): Value;
  VAR cond, result, body: Value;
  BEGIN
    cond := EvalRef(args.head, env);
    IF err THEN RETURN NilV END;
    IF ~IsTruthy(cond) THEN RETURN NilV END;
    body := args.tail; result := NilV;
    WHILE ~IsNil(body) & ~err DO
      result := EvalRef(body.head, env); body := body.tail
    END;
    RETURN result
  END DoWhen;

  PROCEDURE DoDefn(args: Value): Value;
  VAR fnVal: Value;
  BEGIN
    IF IsNil(args) OR (args.head.tag # tSym) THEN
      Error("defn needs name"); RETURN NilV
    END;
    fnVal := DoFn(args.tail);
    IF err THEN RETURN NilV END;
    Define(GlobalEnv, args.head.s, fnVal);
    RETURN fnVal
  END DoDefn;

VAR head: Value; sym: ARRAY MaxStr OF CHAR; fn, evArgs, looked: Value;
  vec, first, last, cell, v: Value;
BEGIN
  IF err THEN RETURN NilV END;
  IF IsNil(expr) THEN RETURN NilV END;
  CASE expr.tag OF
    tBool, tInt, tReal, tStr, tKey, tFn, tBuiltin: RETURN expr
  | tSym:
      looked := Lookup(env, expr.s);
      IF looked = NIL THEN
        Strings.Copy("undefined symbol: ", errMsg);
        Strings.Append(expr.s, errMsg);
        err := TRUE;
        RETURN NilV
      END;
      RETURN looked
  | tVec:
      first := NilV; last := NIL; vec := expr;
      WHILE ~IsNil(vec) DO
        v := EvalRef(vec.head, env);
        IF err THEN RETURN NilV END;
        cell := MkVec(v, NilV);
        IF last = NIL THEN first := cell ELSE last.tail := cell END;
        last := cell; vec := vec.tail
      END;
      RETURN first
  | tMap: RETURN expr
  | tList:
      head := expr.head;
      IF ~IsNil(head) & (head.tag = tSym) THEN
        Strings.Copy(head.s, sym);
        IF sym = "def" THEN RETURN DoDef(expr.tail)
        ELSIF sym = "defn" THEN RETURN DoDefn(expr.tail)
        ELSIF sym = "if" THEN RETURN DoIf(expr.tail)
        ELSIF sym = "fn" THEN RETURN DoFn(expr.tail)
        ELSIF sym = "let" THEN RETURN DoLet(expr.tail)
        ELSIF sym = "do" THEN RETURN DoDo(expr.tail)
        ELSIF sym = "quote" THEN RETURN expr.tail.head
        ELSIF sym = "and" THEN RETURN DoAnd(expr.tail)
        ELSIF sym = "or" THEN RETURN DoOr(expr.tail)
        ELSIF sym = "when" THEN RETURN DoWhen(expr.tail)
        END
      END;
      fn := EvalRef(head, env);
      IF err THEN RETURN NilV END;
      evArgs := EvalList(expr.tail, env);
      IF err THEN RETURN NilV END;
      RETURN Apply(fn, evArgs, env)
  ELSE RETURN expr
  END
END Eval;

(* ---------- Numeric helpers ---------- *)

PROCEDURE IsNum(v: Value): BOOLEAN;
BEGIN RETURN ~IsNil(v) & ((v.tag = tInt) OR (v.tag = tReal)) END IsNum;

PROCEDURE NumReal(v: Value): REAL;
BEGIN
  IF v.tag = tInt THEN RETURN FLT(v.i) ELSE RETURN v.r END
END NumReal;

PROCEDURE NumsEqual(a, b: Value): BOOLEAN;
BEGIN
  IF (a.tag = tInt) & (b.tag = tInt) THEN RETURN a.i = b.i END;
  RETURN NumReal(a) = NumReal(b)
END NumsEqual;

(* ---------- Built-ins ---------- *)

PROCEDURE BAdd(args: Value; env: Env): Value;
VAR sumI: INTEGER; sumR: REAL; isReal: BOOLEAN; a: Value;
BEGIN
  sumI := 0; sumR := 0.0; isReal := FALSE;
  WHILE ~IsNil(args) DO
    a := args.head;
    IF ~IsNum(a) THEN Error("+ needs numbers"); RETURN NilV END;
    IF a.tag = tReal THEN
      IF ~isReal THEN sumR := FLT(sumI); isReal := TRUE END;
      sumR := sumR + a.r
    ELSIF isReal THEN sumR := sumR + FLT(a.i)
    ELSE sumI := sumI + a.i END;
    args := args.tail
  END;
  IF isReal THEN RETURN MkReal(sumR) ELSE RETURN MkInt(sumI) END
END BAdd;

PROCEDURE BSub(args: Value; env: Env): Value;
VAR resI: INTEGER; resR: REAL; isReal: BOOLEAN; a: Value;
BEGIN
  IF IsNil(args) THEN Error("- needs args"); RETURN NilV END;
  a := args.head;
  IF ~IsNum(a) THEN Error("- needs numbers"); RETURN NilV END;
  IF a.tag = tReal THEN resR := a.r; isReal := TRUE; resI := 0
  ELSE resI := a.i; resR := 0.0; isReal := FALSE END;
  args := args.tail;
  IF IsNil(args) THEN
    IF isReal THEN RETURN MkReal(-resR) ELSE RETURN MkInt(-resI) END
  END;
  WHILE ~IsNil(args) DO
    a := args.head;
    IF ~IsNum(a) THEN Error("- needs numbers"); RETURN NilV END;
    IF a.tag = tReal THEN
      IF ~isReal THEN resR := FLT(resI); isReal := TRUE END;
      resR := resR - a.r
    ELSIF isReal THEN resR := resR - FLT(a.i)
    ELSE resI := resI - a.i END;
    args := args.tail
  END;
  IF isReal THEN RETURN MkReal(resR) ELSE RETURN MkInt(resI) END
END BSub;

PROCEDURE BMul(args: Value; env: Env): Value;
VAR resI: INTEGER; resR: REAL; isReal: BOOLEAN; a: Value;
BEGIN
  resI := 1; resR := 1.0; isReal := FALSE;
  WHILE ~IsNil(args) DO
    a := args.head;
    IF ~IsNum(a) THEN Error("* needs numbers"); RETURN NilV END;
    IF a.tag = tReal THEN
      IF ~isReal THEN resR := FLT(resI); isReal := TRUE END;
      resR := resR * a.r
    ELSIF isReal THEN resR := resR * FLT(a.i)
    ELSE resI := resI * a.i END;
    args := args.tail
  END;
  IF isReal THEN RETURN MkReal(resR) ELSE RETURN MkInt(resI) END
END BMul;

PROCEDURE BDiv(args: Value; env: Env): Value;
VAR resR: REAL; a: Value;
BEGIN
  IF IsNil(args) THEN Error("/ needs args"); RETURN NilV END;
  a := args.head;
  IF ~IsNum(a) THEN Error("/ needs numbers"); RETURN NilV END;
  resR := NumReal(a);
  args := args.tail;
  IF IsNil(args) THEN RETURN MkReal(1.0 / resR) END;
  WHILE ~IsNil(args) DO
    a := args.head;
    IF ~IsNum(a) THEN Error("/ needs numbers"); RETURN NilV END;
    IF NumReal(a) = 0.0 THEN Error("division by zero"); RETURN NilV END;
    resR := resR / NumReal(a);
    args := args.tail
  END;
  RETURN MkReal(resR)
END BDiv;

PROCEDURE BMod(args: Value; env: Env): Value;
VAR a, b: Value;
BEGIN
  a := args.head; b := args.tail.head;
  IF (a.tag # tInt) OR (b.tag # tInt) THEN Error("mod needs ints"); RETURN NilV END;
  RETURN MkInt(a.i MOD b.i)
END BMod;

PROCEDURE BLT(args: Value; env: Env): Value;
VAR a, b: Value;
BEGIN
  a := args.head;
  args := args.tail;
  WHILE ~IsNil(args) DO
    b := args.head;
    IF NumReal(a) >= NumReal(b) THEN RETURN FalseV END;
    a := b; args := args.tail
  END;
  RETURN TrueV
END BLT;

PROCEDURE BGT(args: Value; env: Env): Value;
VAR a, b: Value;
BEGIN
  a := args.head; args := args.tail;
  WHILE ~IsNil(args) DO
    b := args.head;
    IF NumReal(a) <= NumReal(b) THEN RETURN FalseV END;
    a := b; args := args.tail
  END;
  RETURN TrueV
END BGT;

PROCEDURE BLE(args: Value; env: Env): Value;
VAR a, b: Value;
BEGIN
  a := args.head; args := args.tail;
  WHILE ~IsNil(args) DO
    b := args.head;
    IF NumReal(a) > NumReal(b) THEN RETURN FalseV END;
    a := b; args := args.tail
  END;
  RETURN TrueV
END BLE;

PROCEDURE BGE(args: Value; env: Env): Value;
VAR a, b: Value;
BEGIN
  a := args.head; args := args.tail;
  WHILE ~IsNil(args) DO
    b := args.head;
    IF NumReal(a) < NumReal(b) THEN RETURN FalseV END;
    a := b; args := args.tail
  END;
  RETURN TrueV
END BGE;

PROCEDURE ValueEqual(a, b: Value): BOOLEAN;
VAR pa, pb: Value;
BEGIN
  IF IsNil(a) & IsNil(b) THEN RETURN TRUE END;
  IF IsNil(a) OR IsNil(b) THEN RETURN FALSE END;
  IF IsNum(a) & IsNum(b) THEN RETURN NumsEqual(a, b) END;
  IF a.tag # b.tag THEN RETURN FALSE END;
  CASE a.tag OF
    tBool: RETURN a.b = b.b
  | tStr, tSym, tKey: RETURN a.s = b.s
  | tList, tVec:
      pa := a; pb := b;
      WHILE ~IsNil(pa) & ~IsNil(pb) DO
        IF ~ValueEqual(pa.head, pb.head) THEN RETURN FALSE END;
        pa := pa.tail; pb := pb.tail
      END;
      RETURN IsNil(pa) & IsNil(pb)
  ELSE RETURN FALSE
  END
END ValueEqual;

PROCEDURE BEq(args: Value; env: Env): Value;
VAR a: Value;
BEGIN
  a := args.head; args := args.tail;
  WHILE ~IsNil(args) DO
    IF ~ValueEqual(a, args.head) THEN RETURN FalseV END;
    args := args.tail
  END;
  RETURN TrueV
END BEq;

PROCEDURE BList(args: Value; env: Env): Value;
BEGIN RETURN args END BList;

PROCEDURE BVector(args: Value; env: Env): Value;
VAR first, last, cell: Value;
BEGIN
  first := NilV; last := NIL;
  WHILE ~IsNil(args) DO
    cell := MkVec(args.head, NilV);
    IF last = NIL THEN first := cell ELSE last.tail := cell END;
    last := cell; args := args.tail
  END;
  RETURN first
END BVector;

PROCEDURE BCons(args: Value; env: Env): Value;
BEGIN RETURN Cons(args.head, args.tail.head) END BCons;

PROCEDURE BFirst(args: Value; env: Env): Value;
VAR v: Value;
BEGIN
  v := args.head;
  IF IsNil(v) THEN RETURN NilV END;
  IF (v.tag = tList) OR (v.tag = tVec) THEN RETURN v.head END;
  Error("first: not a sequence"); RETURN NilV
END BFirst;

PROCEDURE BRest(args: Value; env: Env): Value;
VAR v: Value;
BEGIN
  v := args.head;
  IF IsNil(v) THEN RETURN NilV END;
  IF (v.tag = tList) OR (v.tag = tVec) THEN
    IF IsNil(v.tail) THEN RETURN NilV ELSE RETURN v.tail END
  END;
  Error("rest: not a sequence"); RETURN NilV
END BRest;

PROCEDURE BCount(args: Value; env: Env): Value;
VAR v: Value; n: INTEGER;
BEGIN
  v := args.head;
  IF IsNil(v) THEN RETURN MkInt(0) END;
  IF (v.tag = tList) OR (v.tag = tVec) THEN RETURN MkInt(ListLen(v)) END;
  IF v.tag = tMap THEN RETURN MkInt(ListLen(v.head)) END;
  IF v.tag = tStr THEN
    n := 0; WHILE v.s[n] # 0X DO INC(n) END;
    RETURN MkInt(n)
  END;
  RETURN MkInt(0)
END BCount;

PROCEDURE BNth(args: Value; env: Env): Value;
VAR v: Value; n: INTEGER;
BEGIN
  v := args.head; n := args.tail.head.i;
  WHILE (n > 0) & ~IsNil(v) DO v := v.tail; DEC(n) END;
  IF IsNil(v) THEN RETURN NilV END;
  RETURN v.head
END BNth;

PROCEDURE BConj(args: Value; env: Env): Value;
VAR coll, item, first, last, cell, p: Value;
BEGIN
  coll := args.head; item := args.tail.head;
  IF IsNil(coll) THEN RETURN Cons(item, NilV) END;
  IF coll.tag = tList THEN RETURN Cons(item, coll) END;
  IF coll.tag = tVec THEN
    first := NilV; last := NIL; p := coll;
    WHILE ~IsNil(p) DO
      cell := MkVec(p.head, NilV);
      IF last = NIL THEN first := cell ELSE last.tail := cell END;
      last := cell; p := p.tail
    END;
    cell := MkVec(item, NilV);
    IF last = NIL THEN first := cell ELSE last.tail := cell END;
    RETURN first
  END;
  Error("conj: unsupported collection"); RETURN NilV
END BConj;

PROCEDURE BMap(args: Value; env: Env): Value;
VAR fn, coll, first, last, cell, callArgs, result: Value;
BEGIN
  fn := args.head; coll := args.tail.head;
  first := NilV; last := NIL;
  WHILE ~IsNil(coll) & ~err DO
    callArgs := Cons(coll.head, NilV);
    result := Apply(fn, callArgs, env);
    IF err THEN RETURN NilV END;
    cell := Cons(result, NilV);
    IF last = NIL THEN first := cell ELSE last.tail := cell END;
    last := cell; coll := coll.tail
  END;
  RETURN first
END BMap;

PROCEDURE BFilter(args: Value; env: Env): Value;
VAR fn, coll, first, last, cell, callArgs, result: Value;
BEGIN
  fn := args.head; coll := args.tail.head;
  first := NilV; last := NIL;
  WHILE ~IsNil(coll) & ~err DO
    callArgs := Cons(coll.head, NilV);
    result := Apply(fn, callArgs, env);
    IF err THEN RETURN NilV END;
    IF IsTruthy(result) THEN
      cell := Cons(coll.head, NilV);
      IF last = NIL THEN first := cell ELSE last.tail := cell END;
      last := cell
    END;
    coll := coll.tail
  END;
  RETURN first
END BFilter;

PROCEDURE BReduce(args: Value; env: Env): Value;
VAR fn, coll, acc, callArgs: Value;
BEGIN
  fn := args.head;
  IF IsNil(args.tail.tail) THEN
    coll := args.tail.head;
    IF IsNil(coll) THEN RETURN NilV END;
    acc := coll.head; coll := coll.tail
  ELSE
    acc := args.tail.head; coll := args.tail.tail.head
  END;
  WHILE ~IsNil(coll) & ~err DO
    callArgs := Cons(acc, Cons(coll.head, NilV));
    acc := Apply(fn, callArgs, env);
    coll := coll.tail
  END;
  RETURN acc
END BReduce;

PROCEDURE BRange(args: Value; env: Env): Value;
VAR start, stop, step, n: INTEGER; first, last, cell: Value;
BEGIN
  IF IsNil(args) THEN Error("range: at least 1 arg"); RETURN NilV END;
  start := 0; step := 1;
  IF IsNil(args.tail) THEN
    stop := args.head.i
  ELSE
    start := args.head.i; stop := args.tail.head.i;
    IF ~IsNil(args.tail.tail) THEN step := args.tail.tail.head.i END
  END;
  first := NilV; last := NIL; n := start;
  WHILE ((step > 0) & (n < stop)) OR ((step < 0) & (n > stop)) DO
    cell := Cons(MkInt(n), NilV);
    IF last = NIL THEN first := cell ELSE last.tail := cell END;
    last := cell;
    n := n + step
  END;
  RETURN first
END BRange;

PROCEDURE BPrn(args: Value; env: Env): Value;
VAR first: BOOLEAN;
BEGIN
  first := TRUE;
  WHILE ~IsNil(args) DO
    IF ~first THEN Out.Char(' ') END;
    PrintValue(args.head, TRUE);
    first := FALSE; args := args.tail
  END;
  Out.Ln;
  RETURN NilV
END BPrn;

PROCEDURE BPrintln(args: Value; env: Env): Value;
VAR first: BOOLEAN;
BEGIN
  first := TRUE;
  WHILE ~IsNil(args) DO
    IF ~first THEN Out.Char(' ') END;
    PrintValue(args.head, FALSE);
    first := FALSE; args := args.tail
  END;
  Out.Ln;
  RETURN NilV
END BPrintln;

PROCEDURE AppendCStr(VAR buf: ARRAY OF CHAR; VAR n: INTEGER; src: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (src[i] # 0X) & (n < LEN(buf)-1) DO
    buf[n] := src[i]; INC(n); INC(i)
  END
END AppendCStr;

PROCEDURE BStr(args: Value; env: Env): Value;
VAR buf: ARRAY MaxStr OF CHAR; tmp: ARRAY 64 OF CHAR; n: INTEGER; v: Value;
BEGIN
  buf[0] := 0X; n := 0;
  WHILE ~IsNil(args) DO
    v := args.head;
    IF IsNil(v) THEN (* skip *)
    ELSIF (v.tag = tStr) OR (v.tag = tSym) THEN
      AppendCStr(buf, n, v.s)
    ELSIF v.tag = tInt THEN
      Strings.IntToStr(v.i, tmp); AppendCStr(buf, n, tmp)
    ELSIF v.tag = tReal THEN
      Strings.RealToStr(v.r, tmp); AppendCStr(buf, n, tmp)
    ELSIF v.tag = tBool THEN
      IF v.b THEN AppendCStr(buf, n, "true")
      ELSE AppendCStr(buf, n, "false") END
    ELSIF v.tag = tKey THEN
      IF n < LEN(buf)-1 THEN buf[n] := ':'; INC(n) END;
      AppendCStr(buf, n, v.s)
    END;
    args := args.tail
  END;
  buf[n] := 0X;
  RETURN MkStr(buf)
END BStr;

PROCEDURE BType(args: Value; env: Env): Value;
VAR v: Value;
BEGIN
  v := args.head;
  IF IsNil(v) THEN RETURN MkKey("nil") END;
  CASE v.tag OF
    tBool: RETURN MkKey("bool")
  | tInt: RETURN MkKey("int")
  | tReal: RETURN MkKey("real")
  | tStr: RETURN MkKey("string")
  | tSym: RETURN MkKey("symbol")
  | tKey: RETURN MkKey("keyword")
  | tList: RETURN MkKey("list")
  | tVec: RETURN MkKey("vector")
  | tMap: RETURN MkKey("map")
  | tFn: RETURN MkKey("fn")
  | tBuiltin: RETURN MkKey("builtin")
  ELSE RETURN MkKey("unknown")
  END
END BType;

PROCEDURE BNilQ(args: Value; env: Env): Value;
BEGIN RETURN MkBool(IsNil(args.head)) END BNilQ;

PROCEDURE BEmptyQ(args: Value; env: Env): Value;
VAR v: Value;
BEGIN
  v := args.head;
  IF IsNil(v) THEN RETURN TrueV END;
  IF (v.tag = tList) OR (v.tag = tVec) THEN
    RETURN MkBool(ListLen(v) = 0)
  END;
  RETURN FalseV
END BEmptyQ;

PROCEDURE BNot(args: Value; env: Env): Value;
BEGIN RETURN MkBool(~IsTruthy(args.head)) END BNot;

PROCEDURE BInc(args: Value; env: Env): Value;
VAR v: Value;
BEGIN
  v := args.head;
  IF v.tag = tInt THEN RETURN MkInt(v.i + 1) END;
  IF v.tag = tReal THEN RETURN MkReal(v.r + 1.0) END;
  Error("inc: needs number"); RETURN NilV
END BInc;

PROCEDURE BDec(args: Value; env: Env): Value;
VAR v: Value;
BEGIN
  v := args.head;
  IF v.tag = tInt THEN RETURN MkInt(v.i - 1) END;
  IF v.tag = tReal THEN RETURN MkReal(v.r - 1.0) END;
  Error("dec: needs number"); RETURN NilV
END BDec;

PROCEDURE BGet(args: Value; env: Env): Value;
VAR m, k, ks, vs: Value;
BEGIN
  m := args.head; k := args.tail.head;
  IF IsNil(m) THEN RETURN NilV END;
  IF m.tag = tMap THEN
    ks := m.head; vs := m.tail;
    WHILE ~IsNil(ks) DO
      IF ValueEqual(ks.head, k) THEN RETURN vs.head END;
      ks := ks.tail; vs := vs.tail
    END;
    IF ~IsNil(args.tail.tail) THEN RETURN args.tail.tail.head END;
    RETURN NilV
  END;
  IF (m.tag = tVec) & (k.tag = tInt) THEN
    RETURN BNth(args, env)
  END;
  RETURN NilV
END BGet;

PROCEDURE BAssoc(args: Value; env: Env): Value;
VAR m, k, v, ks, vs, nks, nvs, c: Value; nkLast, nvLast: Value; found: BOOLEAN;
BEGIN
  m := args.head; k := args.tail.head; v := args.tail.tail.head;
  IF IsNil(m) OR (m.tag # tMap) THEN
    RETURN MkMap(Cons(k, NilV), Cons(v, NilV))
  END;
  ks := m.head; vs := m.tail;
  nks := NilV; nvs := NilV; nkLast := NIL; nvLast := NIL; found := FALSE;
  WHILE ~IsNil(ks) DO
    c := Cons(ks.head, NilV);
    IF nkLast = NIL THEN nks := c ELSE nkLast.tail := c END;
    nkLast := c;
    IF ValueEqual(ks.head, k) THEN
      c := Cons(v, NilV); found := TRUE
    ELSE c := Cons(vs.head, NilV) END;
    IF nvLast = NIL THEN nvs := c ELSE nvLast.tail := c END;
    nvLast := c;
    ks := ks.tail; vs := vs.tail
  END;
  IF ~found THEN
    c := Cons(k, NilV);
    IF nkLast = NIL THEN nks := c ELSE nkLast.tail := c END;
    c := Cons(v, NilV);
    IF nvLast = NIL THEN nvs := c ELSE nvLast.tail := c END
  END;
  RETURN MkMap(nks, nvs)
END BAssoc;

PROCEDURE BKeys(args: Value; env: Env): Value;
VAR m: Value;
BEGIN
  m := args.head;
  IF IsNil(m) OR (m.tag # tMap) THEN RETURN NilV END;
  RETURN m.head
END BKeys;

PROCEDURE BVals(args: Value; env: Env): Value;
VAR m: Value;
BEGIN
  m := args.head;
  IF IsNil(m) OR (m.tag # tMap) THEN RETURN NilV END;
  RETURN m.tail
END BVals;

PROCEDURE BSqrt(args: Value; env: Env): Value;
BEGIN RETURN MkReal(Math.sqrt(NumReal(args.head))) END BSqrt;

PROCEDURE BApplyFn(args: Value; env: Env): Value;
VAR fn, allArgs, p, first, last, cell: Value;
BEGIN
  fn := args.head;
  args := args.tail;
  first := NilV; last := NIL;
  WHILE ~IsNil(args.tail) DO
    cell := Cons(args.head, NilV);
    IF last = NIL THEN first := cell ELSE last.tail := cell END;
    last := cell; args := args.tail
  END;
  p := args.head;
  WHILE ~IsNil(p) DO
    cell := Cons(p.head, NilV);
    IF last = NIL THEN first := cell ELSE last.tail := cell END;
    last := cell; p := p.tail
  END;
  allArgs := first;
  RETURN Apply(fn, allArgs, env)
END BApplyFn;

(* ---------- File loading ---------- *)

PROCEDURE LoadFile*(path: ARRAY OF CHAR; verbose: BOOLEAN): BOOLEAN;
VAR f: Files.File; r: Files.Rider;
  buf: ARRAY MaxTok OF CHAR;
  ch: CHAR; n: INTEGER;
  expr, result: Value;
BEGIN
  f := Files.Old(path);
  IF f = NIL THEN
    Out.String("load-file: cannot open '"); WriteStr(path); Out.String("'"); Out.Ln;
    RETURN FALSE
  END;
  Files.Set(r, f, 0);
  n := 0;
  Files.Read(r, ch);
  WHILE ~r.eof & (n < MaxTok-1) DO
    buf[n] := ch; INC(n);
    Files.Read(r, ch)
  END;
  buf[n] := 0X;
  Files.Close(f);

  BeginRead(buf);
  result := NilV;
  LOOP
    expr := ReadNext();
    IF expr = NIL THEN EXIT END;
    result := Eval(expr, GlobalEnv);
    IF err THEN
      Out.String("error in "); WriteStr(path); Out.String(": ");
      WriteStr(errMsg); Out.Ln;
      err := FALSE;
      RETURN FALSE
    END;
    IF verbose THEN
      PrintValue(result, TRUE); Out.Ln
    END
  END;
  RETURN TRUE
END LoadFile;

PROCEDURE BLoadFile(args: Value; env: Env): Value;
VAR path: Value; ok: BOOLEAN;
BEGIN
  path := args.head;
  IF IsNil(path) OR (path.tag # tStr) THEN
    Error("load-file: needs string path"); RETURN NilV
  END;
  ok := LoadFile(path.s, FALSE);
  RETURN MkBool(ok)
END BLoadFile;

(* ---------- Setup ---------- *)

PROCEDURE Register(name: ARRAY OF CHAR; fn: Builtin);
BEGIN Define(GlobalEnv, name, MkBuiltin(name, fn)) END Register;

PROCEDURE Init;
BEGIN
  NEW(NilV); NilV.tag := tNil;
  NEW(TrueV); TrueV.tag := tBool; TrueV.b := TRUE;
  NEW(FalseV); FalseV.tag := tBool; FalseV.b := FALSE;

  EvalRef := Eval;

  GlobalEnv := NewEnv(NIL);

  Register("+", BAdd);
  Register("-", BSub);
  Register("*", BMul);
  Register("/", BDiv);
  Register("mod", BMod);
  Register("<", BLT);
  Register(">", BGT);
  Register("<=", BLE);
  Register(">=", BGE);
  Register("=", BEq);
  Register("list", BList);
  Register("vector", BVector);
  Register("vec", BVector);
  Register("cons", BCons);
  Register("first", BFirst);
  Register("rest", BRest);
  Register("count", BCount);
  Register("nth", BNth);
  Register("conj", BConj);
  Register("map", BMap);
  Register("filter", BFilter);
  Register("reduce", BReduce);
  Register("range", BRange);
  Register("prn", BPrn);
  Register("println", BPrintln);
  Register("str", BStr);
  Register("type", BType);
  Register("nil?", BNilQ);
  Register("empty?", BEmptyQ);
  Register("not", BNot);
  Register("inc", BInc);
  Register("dec", BDec);
  Register("get", BGet);
  Register("assoc", BAssoc);
  Register("keys", BKeys);
  Register("vals", BVals);
  Register("sqrt", BSqrt);
  Register("apply", BApplyFn);
  Register("load-file", BLoadFile);
END Init;

(* ---------- REPL loop ---------- *)

PROCEDURE BalancedDelims(s: ARRAY OF CHAR): INTEGER;
VAR i, depth: INTEGER; inStr: BOOLEAN; c: CHAR;
BEGIN
  i := 0; depth := 0; inStr := FALSE;
  WHILE s[i] # 0X DO
    c := s[i];
    IF inStr THEN
      IF c = '\' THEN
        IF s[i+1] # 0X THEN INC(i) END
      ELSIF c = '"' THEN inStr := FALSE END
    ELSE
      IF c = '"' THEN inStr := TRUE
      ELSIF c = ';' THEN
        WHILE (s[i] # 0X) & (s[i] # 0AX) DO INC(i) END;
        IF s[i] = 0X THEN RETURN depth END
      ELSIF (c = '(') OR (c = '[') OR (c = '{') THEN INC(depth)
      ELSIF (c = ')') OR (c = ']') OR (c = '}') THEN DEC(depth)
      END
    END;
    INC(i)
  END;
  RETURN depth
END BalancedDelims;

PROCEDURE REPL*;
VAR line, buf: ARRAY MaxTok OF CHAR; expr, result: Value; i, n: INTEGER;
BEGIN
  Init;
  Out.String("Clojure-like REPL.  Empty line at => to exit."); Out.Ln;
  Out.String("Try: (+ 1 2 3)   (defn sq [x] (* x x))   (map sq (range 5))"); Out.Ln;
  LOOP
    buf[0] := 0X;
    LOOP
      IF buf[0] = 0X THEN
        History.ReadLine("=> ", line)
      ELSE
        History.ReadLine(".. ", line)
      END;
      IF (line[0] = 0X) & (buf[0] = 0X) THEN
        Out.String("bye."); Out.Ln; RETURN
      END;
      n := 0; WHILE buf[n] # 0X DO INC(n) END;
      i := 0;
      WHILE (line[i] # 0X) & (n < MaxTok-2) DO
        buf[n] := line[i]; INC(n); INC(i)
      END;
      buf[n] := ' '; buf[n+1] := 0X;
      IF BalancedDelims(buf) <= 0 THEN EXIT END
    END;

    err := FALSE;
    expr := ReadStr(buf);
    IF err THEN
      Out.String("read error: "); Out.String(errMsg); Out.Ln
    ELSE
      result := Eval(expr, GlobalEnv);
      IF err THEN
        Out.String("error: "); Out.String(errMsg); Out.Ln
      ELSE
        PrintValue(result, TRUE); Out.Ln
      END
    END
  END
END REPL;

PROCEDURE Main*;
VAR i, nFiles: INTEGER; arg: ARRAY 256 OF CHAR;
  interactive, ok: BOOLEAN;
BEGIN
  Init;
  interactive := FALSE; nFiles := 0;
  i := 1;
  WHILE i <= Args.Count() DO
    Args.Get(i, arg);
    IF (arg[0] = '-') & (arg[1] = 'i') & (arg[2] = 0X) THEN
      interactive := TRUE
    ELSIF (arg[0] = '-') & (arg[1] = 'h') & (arg[2] = 0X) THEN
      Out.String("usage: cloj [-i] [file.clj ...]"); Out.Ln;
      Out.String("  -i        drop into REPL after loading files"); Out.Ln;
      Out.String("  no args   start REPL"); Out.Ln;
      RETURN
    ELSE
      ok := LoadFile(arg, FALSE);
      INC(nFiles)
    END;
    INC(i)
  END;

  IF (nFiles = 0) OR interactive THEN REPL END
END Main;

BEGIN
  Main
END Cloj.
