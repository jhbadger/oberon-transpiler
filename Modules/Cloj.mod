MODULE Cloj;

IMPORT Out, Strings, Math, Random, History, Files, Args, Regex;

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
  tAtom*   = 13;
  tDelay*  = 14;
  tSet*    = 15;
  tRegex*  = 16;

  MaxTok     = 65536;
  MaxStr     = 256;
  MaxModules = 64;

TYPE
  Value*   = POINTER TO ValueDesc;
  Env*     = POINTER TO EnvDesc;
  Binding* = POINTER TO BindingDesc;
  Builtin* = PROCEDURE(args: Value; env: Env): Value;
  ModuleRegFn* = PROCEDURE(env: Env);
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
    doc*: ARRAY MaxStr OF CHAR;
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

  doRecur: BOOLEAN;
  recurArgs: Value;
  gensymCount: INTEGER;

  isThrown*: BOOLEAN;
  thrownVal*: Value;

  EvalRef: EvalProc;  (* forward indirection *)

  modNames: ARRAY MaxModules OF ARRAY 64 OF CHAR;
  modFns:   ARRAY MaxModules OF ModuleRegFn;
  nModules: INTEGER;

(* ---------- Value constructors ---------- *)

PROCEDURE MkNil(): Value;
VAR v: Value;
BEGIN NEW(v); v.tag := tNil; RETURN v END MkNil;

PROCEDURE MkBool*(b: BOOLEAN): Value;
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

PROCEDURE MkRegex*(s: ARRAY OF CHAR): Value;
VAR v: Value;
BEGIN NEW(v); v.tag := tRegex; Strings.Copy(s, v.s); RETURN v END MkRegex;

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

PROCEDURE MkMap*(keys, vals: Value): Value;
VAR v: Value;
BEGIN
  NEW(v); v.tag := tMap; v.head := keys; v.tail := vals;
  RETURN v
END MkMap;

(* Set: head = linked Cons list of elements, tail unused.
   b = TRUE marks a sorted-set (elements kept in ValLT order). *)
PROCEDURE MkSet(elems: Value): Value;
VAR v: Value;
BEGIN NEW(v); v.tag := tSet; v.b := FALSE; v.head := elems; RETURN v END MkSet;

PROCEDURE MkSortedSet(elems: Value): Value;
VAR v: Value;
BEGIN NEW(v); v.tag := tSet; v.b := TRUE; v.head := elems; RETURN v END MkSortedSet;

PROCEDURE SetContains(s, elem: Value): BOOLEAN;
VAR p: Value;
BEGIN
  p := s.head;
  WHILE ~IsNil(p) DO
    IF ValueEqual(p.head, elem) THEN RETURN TRUE END;
    p := p.tail
  END;
  RETURN FALSE
END SetContains;

(* Insert elem into sorted-set s in ValLT order; forward call to ValLT is ok. *)
PROCEDURE SortedSetConj(s, elem: Value): Value;
VAR first, last, p, cell: Value; inserted: BOOLEAN;
BEGIN
  IF SetContains(s, elem) THEN RETURN s END;
  first := NilV; last := NIL; inserted := FALSE; p := s.head;
  WHILE ~IsNil(p) DO
    IF ~inserted & ValLT(elem, p.head) THEN
      cell := Cons(elem, NilV);
      IF last = NIL THEN first := cell ELSE last.tail := cell END;
      last := cell; inserted := TRUE
    END;
    cell := Cons(p.head, NilV);
    IF last = NIL THEN first := cell ELSE last.tail := cell END;
    last := cell; p := p.tail
  END;
  IF ~inserted THEN
    cell := Cons(elem, NilV);
    IF last = NIL THEN first := cell ELSE last.tail := cell END
  END;
  RETURN MkSortedSet(first)
END SortedSetConj;

PROCEDURE SetConj(s, elem: Value): Value;
VAR first, last, p, cell: Value;
BEGIN
  IF s.b THEN RETURN SortedSetConj(s, elem) END;
  IF SetContains(s, elem) THEN RETURN s END;
  first := NilV; last := NIL; p := s.head;
  WHILE ~IsNil(p) DO
    cell := Cons(p.head, NilV);
    IF last = NIL THEN first := cell ELSE last.tail := cell END;
    last := cell; p := p.tail
  END;
  cell := Cons(elem, NilV);
  IF last = NIL THEN first := cell ELSE last.tail := cell END;
  RETURN MkSet(first)
END SetConj;

PROCEDURE MkBuiltin*(name: ARRAY OF CHAR; fn: Builtin): Value;
VAR v: Value;
BEGIN
  NEW(v); v.tag := tBuiltin; v.builtin := fn;
  Strings.Copy(name, v.name);
  RETURN v
END MkBuiltin;

PROCEDURE IsNil*(v: Value): BOOLEAN;
BEGIN RETURN (v = NIL) OR (v.tag = tNil) END IsNil;

PROCEDURE IsTruthy*(v: Value): BOOLEAN;
BEGIN
  IF IsNil(v) THEN RETURN FALSE END;
  IF (v.tag = tBool) & ~v.b THEN RETURN FALSE END;
  RETURN TRUE
END IsTruthy;

PROCEDURE ListLen*(v: Value): INTEGER;
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
    ELSIF (c = '#') & (srcPos + 1 < srcLen) & (src[srcPos + 1] = '!') THEN
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
  ELSIF c = '`' THEN tokKind := 10; INC(srcPos)
  ELSIF c = '~' THEN
    INC(srcPos);
    IF (srcPos < srcLen) & (src[srcPos] = '@') THEN tokKind := 12; INC(srcPos)
    ELSE tokKind := 11 END
  ELSIF c = '@' THEN tokKind := 13; INC(srcPos)
  ELSIF c = '#' THEN
    IF (srcPos + 1 < srcLen) & (src[srcPos + 1] = '{') THEN
      tokKind := 14; srcPos := srcPos + 2
    ELSIF (srcPos + 1 < srcLen) & (src[srcPos + 1] = '"') THEN
      tokKind := 15; srcPos := srcPos + 2; i := 0;
      WHILE (srcPos < srcLen) & (src[srcPos] # '"') & (i < MaxStr-1) DO
        IF (src[srcPos] = '\') & (srcPos+1 < srcLen) & (src[srcPos+1] = '"') THEN
          tok[i] := '"'; INC(i); INC(srcPos); INC(srcPos)
        ELSE tok[i] := src[srcPos]; INC(i); INC(srcPos) END
      END;
      tok[i] := 0X;
      IF (srcPos < srcLen) & (src[srcPos] = '"') THEN INC(srcPos)
      ELSE Error("unterminated regex literal") END
    ELSE
      tokKind := 8; i := 0;
      WHILE (srcPos < srcLen) & ~IsDelim(src[srcPos]) & (i < MaxStr-1) DO
        tok[i] := src[srcPos]; INC(i); INC(srcPos)
      END;
      tok[i] := 0X
    END
  ELSIF c = '"' THEN
    tokKind := 9; INC(srcPos); i := 0;
    WHILE (srcPos < srcLen) & (src[srcPos] # '"') & (i < MaxStr-1) DO
      IF (src[srcPos] = '\') & (srcPos+1 < srcLen) THEN
        INC(srcPos);
        IF src[srcPos] = 'n' THEN tok[i] := 0AX
        ELSIF src[srcPos] = 'r' THEN tok[i] := 0DX
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

  PROCEDURE ParseSet(): Value;
  VAR first, last, cell, elem: Value; s: Value;
  BEGIN
    first := NilV; last := NIL;
    s := MkSet(NilV);
    NextTok;
    WHILE (tokKind # 6) & (tokKind # 0) & ~err DO
      elem := ParseExpr();
      IF err THEN RETURN NilV END;
      IF ~SetContains(s, elem) THEN
        cell := Cons(elem, NilV);
        IF last = NIL THEN first := cell ELSE last.tail := cell END;
        last := cell;
        s.head := first
      END;
      NextTok
    END;
    IF tokKind # 6 THEN Error("unbalanced set") END;
    RETURN MkSet(first)
  END ParseSet;

VAR v, q: Value;
BEGIN
  CASE tokKind OF
    0: Error("unexpected eof"); RETURN NilV
  | 1: RETURN ParseSeq(2)
  | 3: RETURN ParseSeq(4)
  | 5: RETURN ParseMap()
  | 7:  NextTok; v := ParseExpr();
        q := Cons(MkSym("quote"), Cons(v, NilV)); RETURN q
  | 8:  RETURN ParseAtom()
  | 9:  RETURN MkStr(tok)
  | 10: NextTok; v := ParseExpr();
        q := Cons(MkSym("quasiquote"), Cons(v, NilV)); RETURN q
  | 11: NextTok; v := ParseExpr();
        q := Cons(MkSym("unquote"), Cons(v, NilV)); RETURN q
  | 12: NextTok; v := ParseExpr();
        q := Cons(MkSym("unquote-splicing"), Cons(v, NilV)); RETURN q
  | 13: NextTok; v := ParseExpr();
        q := Cons(MkSym("deref"), Cons(v, NilV)); RETURN q
  | 14: RETURN ParseSet()
  | 15: RETURN MkRegex(tok)
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
  | tSet:
      Out.Char('#'); Out.Char('{'); p := v.head; first := TRUE;
      WHILE ~IsNil(p) DO
        IF ~first THEN Out.Char(' ') END;
        PrintValue(p.head, readable);
        first := FALSE; p := p.tail
      END;
      Out.Char('}')
  | tRegex:
      Out.Char('#'); Out.Char('"');
      i := 0;
      WHILE v.s[i] # 0X DO
        IF v.s[i] = '"' THEN Out.Char('\'); Out.Char('"')
        ELSIF v.s[i] = '\' THEN Out.Char('\'); Out.Char('\')
        ELSE Out.Char(v.s[i]) END;
        INC(i)
      END;
      Out.Char('"')
  | tFn: WriteStr("#<fn>")
  | tBuiltin: WriteStr("#<builtin "); WriteStr(v.name); Out.Char('>')
  | tMacro: WriteStr("#<macro>")
  | tAtom: WriteStr("#<Atom: "); PrintValue(v.head, readable); Out.Char('>')
  | tDelay:
      IF v.head # NIL THEN WriteStr("#<Delay: "); PrintValue(v.head, readable); Out.Char('>')
      ELSE WriteStr("#<Delay (pending)>") END
  ELSE WriteStr("#<?>")
  END
END PrintValue;

(* ---------- Destructuring ---------- *)

PROCEDURE MapGet(m, k: Value): Value;
VAR ks, vs: Value;
BEGIN
  IF IsNil(m) OR (m.tag # tMap) THEN RETURN NilV END;
  ks := m.head; vs := m.tail;
  WHILE ~IsNil(ks) DO
    IF ValueEqual(ks.head, k) THEN RETURN vs.head END;
    ks := ks.tail; vs := vs.tail
  END;
  RETURN NilV
END MapGet;

PROCEDURE DestructureBind(pat, val: Value; e: Env);
VAR p, v, ks, vs: Value;
BEGIN
  IF pat = NIL THEN RETURN END;
  IF pat.tag = tSym THEN
    IF ~((pat.s[0] = "_") & (pat.s[1] = 0X)) THEN Define(e, pat.s, val) END
  ELSIF (pat.tag = tList) OR (pat.tag = tVec) THEN
    p := pat; v := val;
    WHILE ~IsNil(p) DO
      IF (p.head.tag = tKey) & (p.head.s = "as") THEN
        p := p.tail;
        IF ~IsNil(p) & (p.head.tag = tSym) THEN Define(e, p.head.s, val) END;
        p := p.tail
      ELSIF (p.head.tag = tSym) & (p.head.s[0] = "&") & (p.head.s[1] = 0X) THEN
        p := p.tail;
        IF ~IsNil(p) THEN DestructureBind(p.head, v, e) END;
        p := NilV
      ELSE
        IF IsNil(v) THEN DestructureBind(p.head, NilV, e)
        ELSE DestructureBind(p.head, v.head, e); v := v.tail END;
        p := p.tail
      END
    END
  ELSIF pat.tag = tMap THEN
    ks := pat.head; vs := pat.tail;
    WHILE ~IsNil(ks) DO
      IF (ks.head.tag = tKey) & (ks.head.s = "keys") THEN
        p := vs.head;
        WHILE ~IsNil(p) DO
          IF p.head.tag = tSym THEN
            Define(e, p.head.s, MapGet(val, MkKey(p.head.s)))
          END;
          p := p.tail
        END
      ELSIF (ks.head.tag = tKey) & (ks.head.s = "strs") THEN
        p := vs.head;
        WHILE ~IsNil(p) DO
          IF p.head.tag = tSym THEN
            Define(e, p.head.s, MapGet(val, MkStr(p.head.s)))
          END;
          p := p.tail
        END
      ELSIF (ks.head.tag = tKey) & (ks.head.s = "as") THEN
        IF ~IsNil(vs) & (vs.head.tag = tSym) THEN Define(e, vs.head.s, val) END
      ELSIF (ks.head.tag = tKey) & (ks.head.s = "or") THEN
        (* defaults not yet supported *)
      ELSIF ks.head.tag = tSym THEN
        Define(e, ks.head.s, MapGet(val, vs.head))
      END;
      ks := ks.tail;
      IF ~IsNil(vs) THEN vs := vs.tail END
    END
  END
END DestructureBind;

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
  restList, rLast, c, result, body, expanded: Value;
  nArgs, nParams: INTEGER; arities, clause, p: Value; clauseHasRest: BOOLEAN;
BEGIN
  IF IsNil(fn) THEN Error("cannot call nil"); RETURN NilV END;
  IF fn.tag = tBuiltin THEN RETURN fn.builtin(args, env) END;
  IF fn.tag = tMacro THEN
    fn.tag := tFn;
    expanded := Apply(fn, args, env);
    fn.tag := tMacro;
    IF err THEN RETURN NilV END;
    RETURN EvalRef(expanded, env)
  END;
  IF fn.tag = tMap THEN
    IF IsNil(args) THEN Error("map: needs key arg"); RETURN NilV END;
    RETURN MapGet(fn, args.head)
  END;
  IF fn.tag = tSet THEN
    IF IsNil(args) THEN Error("set: needs arg"); RETURN NilV END;
    IF SetContains(fn, args.head) THEN RETURN args.head ELSE RETURN NilV END
  END;
  IF fn.tag = tKey THEN
    IF IsNil(args) THEN Error("keyword: needs map arg"); RETURN NilV END;
    IF args.head.tag # tMap THEN RETURN NilV END;
    RETURN MapGet(args.head, fn)
  END;
  IF fn.tag # tFn THEN Error("not a function"); RETURN NilV END;
  (* multi-arity dispatch: fn.head holds a cons list of per-arity tFn clauses *)
  IF IsNil(fn.params) & (fn.head # NIL) THEN
    nArgs := 0; a := args;
    WHILE ~IsNil(a) DO INC(nArgs); a := a.tail END;
    arities := fn.head;
    WHILE ~IsNil(arities) DO
      clause := arities.head;
      nParams := 0; clauseHasRest := FALSE; p := clause.params;
      WHILE ~IsNil(p) DO
        IF (p.head # NIL) & (p.head.tag = tSym)
           & (p.head.s[0] = "&") & (p.head.s[1] = 0X) THEN
          clauseHasRest := TRUE; p := NilV
        ELSE
          INC(nParams); p := p.tail
        END
      END;
      IF (clauseHasRest & (nArgs >= nParams)) OR (~clauseHasRest & (nArgs = nParams)) THEN
        RETURN Apply(clause, args, env)
      END;
      arities := arities.tail
    END;
    Error("Wrong number of args"); RETURN NilV
  END;
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
      DestructureBind(params.head, a.head, newEnv);
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

(* ---------- for comprehension helper (recursive, needs EvalRef at runtime) ---------- *)

PROCEDURE ForExpand(binds, body: Value; env: Env): Value;
VAR sym, coll, sub, result, resLast, cell, letP, v, p: Value;
    newEnv: Env;
BEGIN
  IF IsNil(binds) THEN
    v := EvalRef(body, env);
    IF err THEN RETURN NilV END;
    RETURN Cons(v, NilV)
  END;
  IF binds.head.tag = tKey THEN
    IF (binds.head.s = "when") OR (binds.head.s = "while") THEN
      IF IsNil(binds.tail) THEN Error("for: modifier needs expr"); RETURN NilV END;
      v := EvalRef(binds.tail.head, env);
      IF err THEN RETURN NilV END;
      IF ~IsTruthy(v) THEN RETURN NilV END;
      RETURN ForExpand(binds.tail.tail, body, env)
    ELSIF binds.head.s = "let" THEN
      IF IsNil(binds.tail) THEN Error("for :let needs bindings"); RETURN NilV END;
      newEnv := NewEnv(env);
      letP := binds.tail.head;
      WHILE ~IsNil(letP) & ~err DO
        sym := letP.head; letP := letP.tail;
        IF IsNil(letP) THEN Error("for :let odd bindings"); RETURN NilV END;
        v := EvalRef(letP.head, newEnv);
        IF err THEN RETURN NilV END;
        DestructureBind(sym, v, newEnv);
        letP := letP.tail
      END;
      IF err THEN RETURN NilV END;
      RETURN ForExpand(binds.tail.tail, body, newEnv)
    END
  END;
  sym := binds.head;
  IF IsNil(binds.tail) THEN Error("for: missing collection"); RETURN NilV END;
  coll := EvalRef(binds.tail.head, env);
  IF err THEN RETURN NilV END;
  result := NilV; resLast := NIL;
  WHILE ~IsNil(coll) & ~err DO
    newEnv := NewEnv(env);
    DestructureBind(sym, coll.head, newEnv);
    sub := ForExpand(binds.tail.tail, body, newEnv);
    IF err THEN RETURN NilV END;
    p := sub;
    WHILE ~IsNil(p) DO
      cell := Cons(p.head, NilV);
      IF resLast = NIL THEN result := cell ELSE resLast.tail := cell END;
      resLast := cell; p := p.tail
    END;
    coll := coll.tail
  END;
  RETURN result
END ForExpand;

(* ---------- Protocol dispatch fn builder (module-level, no env capture) ---------- *)

PROCEDURE MakeDispatchFn(mname: ARRAY OF CHAR): Value;
VAR fnVal, params: Value;
    getDisp, getType, nameType, orExpr, getImpl: Value;
    letBinds, applyExpr, ifExpr, letExpr: Value;
BEGIN
  getDisp := Cons(MkSym("get"),
               Cons(MkSym("__proto_dispatch__"), Cons(MkStr(mname), NilV)));
  getType := Cons(MkSym("get"),
               Cons(MkSym("__this__"), Cons(MkKey("__type__"), NilV)));
  nameType := Cons(MkSym("name"),
                Cons(Cons(MkSym("type"), Cons(MkSym("__this__"), NilV)), NilV));
  orExpr := Cons(MkSym("or"), Cons(getType, Cons(nameType, NilV)));
  getImpl := Cons(MkSym("get"), Cons(getDisp, Cons(orExpr, NilV)));
  letBinds := MkVec(MkSym("__impl__"), MkVec(getImpl, NilV));
  applyExpr := Cons(MkSym("apply"),
                 Cons(MkSym("__impl__"),
                   Cons(MkSym("__this__"), Cons(MkSym("__args__"), NilV))));
  ifExpr := Cons(MkSym("if"),
              Cons(MkSym("__impl__"), Cons(applyExpr, Cons(NilV, NilV))));
  letExpr := Cons(MkSym("let"), Cons(letBinds, Cons(ifExpr, NilV)));
  params := MkVec(MkSym("__this__"),
              MkVec(MkSym("&"), MkVec(MkSym("__args__"), NilV)));
  NEW(fnVal); fnVal.tag := tFn;
  fnVal.params := params;
  fnVal.body := Cons(letExpr, NilV);
  fnVal.closure := GlobalEnv;
  RETURN fnVal
END MakeDispatchFn;

(* ---------- Quasiquote expansion (AST transform, no eval) ---------- *)

PROCEDURE ExpandQQ(form: Value): Value;
VAR p, parts, partsLast, cell, expanded: Value; hasSplice: BOOLEAN;
BEGIN
  IF IsNil(form) THEN RETURN Cons(MkSym("quote"), Cons(NilV, NilV)) END;
  IF form.tag = tSym THEN RETURN Cons(MkSym("quote"), Cons(form, NilV)) END;
  IF (form.tag # tList) & (form.tag # tVec) THEN RETURN form END;
  IF form.tag = tVec THEN
    (* Convert vec spine to list, expand as list, then unpack into (apply vector ...) *)
    p := form; parts := NilV; partsLast := NIL;
    WHILE ~IsNil(p) DO
      cell := Cons(p.head, NilV);
      IF partsLast = NIL THEN parts := cell ELSE partsLast.tail := cell END;
      partsLast := cell; p := p.tail
    END;
    RETURN Cons(MkSym("apply"),
             Cons(MkSym("vector"),
               Cons(ExpandQQ(parts), NilV)))
  END;
  IF ~IsNil(form.head) & (form.head.tag = tSym) & (form.head.s = "unquote") THEN
    IF IsNil(form.tail) THEN RETURN NilV END;
    RETURN form.tail.head
  END;
  hasSplice := FALSE; p := form;
  WHILE ~IsNil(p) DO
    IF (p.head # NIL) & (p.head.tag = tList) & ~IsNil(p.head.head)
       & (p.head.head.tag = tSym) & (p.head.head.s = "unquote-splicing") THEN
      hasSplice := TRUE
    END;
    p := p.tail
  END;
  IF ~hasSplice THEN
    parts := Cons(MkSym("list"), NilV); partsLast := parts; p := form;
    WHILE ~IsNil(p) DO
      cell := Cons(ExpandQQ(p.head), NilV);
      partsLast.tail := cell; partsLast := cell; p := p.tail
    END;
    RETURN parts
  ELSE
    parts := Cons(MkSym("concat"), NilV); partsLast := parts; p := form;
    WHILE ~IsNil(p) DO
      IF (p.head.tag = tList) & ~IsNil(p.head.head) & (p.head.head.tag = tSym)
         & (p.head.head.s = "unquote-splicing") THEN
        cell := Cons(p.head.tail.head, NilV)
      ELSE
        expanded := ExpandQQ(p.head);
        cell := Cons(Cons(MkSym("list"), Cons(expanded, NilV)), NilV)
      END;
      partsLast.tail := cell; partsLast := cell; p := p.tail
    END;
    RETURN parts
  END
END ExpandQQ;

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
  VAR v, clause, arList, arLast, c: Value;
  BEGIN
    NEW(v); v.tag := tFn;
    v.closure := env;
    (* multi-arity: (fn ([] body) ([x] body) ...) — first arg is a list, not a vector *)
    IF ~IsNil(args) & ~IsNil(args.head) & (args.head.tag = tList) THEN
      arList := NilV; arLast := NIL;
      WHILE ~IsNil(args) DO
        NEW(clause); clause.tag := tFn;
        clause.params := args.head.head;
        clause.body   := args.head.tail;
        clause.closure := env;
        c := Cons(clause, NilV);
        IF arLast = NIL THEN arList := c ELSE arLast.tail := c END;
        arLast := c;
        args := args.tail
      END;
      v.params := NilV;
      v.head := arList
    ELSE
      v.params := args.head;
      v.body := args.tail
    END;
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
      DestructureBind(sym, val, newEnv);
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
    (* support optional docstring: (defn name "doc" [params] body) *)
    IF ~IsNil(args.tail) & ~IsNil(args.tail.head) & (args.tail.head.tag = tStr) THEN
      fnVal := DoFn(args.tail.tail);
      IF err THEN RETURN NilV END;
      Strings.Copy(args.tail.head.s, fnVal.doc)
    ELSE
      fnVal := DoFn(args.tail);
      IF err THEN RETURN NilV END
    END;
    Define(GlobalEnv, args.head.s, fnVal);
    RETURN fnVal
  END DoDefn;

  PROCEDURE DoCond(args: Value): Value;
  VAR test, result: Value;
  BEGIN
    WHILE ~IsNil(args) & ~err DO
      test := args.head; args := args.tail;
      IF IsNil(args) THEN Error("cond: odd clauses"); RETURN NilV END;
      IF (test.tag = tSym) & (test.s = "else") OR IsTruthy(EvalRef(test, env)) THEN
        RETURN EvalRef(args.head, env)
      END;
      args := args.tail
    END;
    RETURN NilV
  END DoCond;

  PROCEDURE DoWhenNot(args: Value): Value;
  VAR cond, result, body: Value;
  BEGIN
    cond := EvalRef(args.head, env);
    IF err THEN RETURN NilV END;
    IF IsTruthy(cond) THEN RETURN NilV END;
    body := args.tail; result := NilV;
    WHILE ~IsNil(body) & ~err DO
      result := EvalRef(body.head, env); body := body.tail
    END;
    RETURN result
  END DoWhenNot;

  PROCEDURE DoCase(args: Value): Value;
  VAR val, clauses, test: Value;
  BEGIN
    val := EvalRef(args.head, env);
    IF err THEN RETURN NilV END;
    clauses := args.tail;
    WHILE ~IsNil(clauses) & ~err DO
      test := clauses.head; clauses := clauses.tail;
      IF IsNil(clauses) THEN RETURN EvalRef(test, env) END;
      IF ValueEqual(val, test) THEN RETURN EvalRef(clauses.head, env) END;
      clauses := clauses.tail
    END;
    RETURN NilV
  END DoCase;

  PROCEDURE DoDotimes(args: Value): Value;
  VAR bindVec, body, result, nameV, countV: Value; newEnv: Env; i, n: INTEGER;
  BEGIN
    bindVec := args.head; body := args.tail;
    IF IsNil(bindVec) OR (bindVec.tag # tVec) THEN
      Error("dotimes: needs binding vector"); RETURN NilV
    END;
    nameV := bindVec.head;
    countV := EvalRef(bindVec.tail.head, env);
    IF err THEN RETURN NilV END;
    IF nameV.tag # tSym THEN Error("dotimes: needs symbol"); RETURN NilV END;
    n := countV.i;
    newEnv := NewEnv(env);
    result := NilV; i := 0;
    WHILE (i < n) & ~err DO
      Define(newEnv, nameV.s, MkInt(i));
      result := NilV;
      body := args.tail;
      WHILE ~IsNil(body) & ~err DO
        result := EvalRef(body.head, newEnv); body := body.tail
      END;
      INC(i)
    END;
    RETURN NilV
  END DoDotimes;

  PROCEDURE DoDoseq(args: Value): Value;
  VAR bindVec, body, nameV, seqV, elem: Value; newEnv: Env;
  BEGIN
    bindVec := args.head; body := args.tail;
    IF IsNil(bindVec) OR (bindVec.tag # tVec) THEN
      Error("doseq: needs binding vector"); RETURN NilV
    END;
    nameV := bindVec.head;
    seqV := EvalRef(bindVec.tail.head, env);
    IF err THEN RETURN NilV END;
    WHILE ~IsNil(seqV) & ~err DO
      elem := seqV.head;
      newEnv := NewEnv(env);
      DestructureBind(nameV, elem, newEnv);
      body := args.tail;
      WHILE ~IsNil(body) & ~err DO
        EvalRef(body.head, newEnv); body := body.tail
      END;
      seqV := seqV.tail
    END;
    RETURN NilV
  END DoDoseq;

  PROCEDURE DoLoop(args: Value): Value;
  VAR bindVec, body, p, symV, valV, result, rp: Value;
    newEnv: Env; names: ARRAY 16 OF ARRAY MaxStr OF CHAR;
    numB, i: INTEGER;
  BEGIN
    bindVec := args.head; body := args.tail;
    IF IsNil(bindVec) OR ((bindVec.tag # tVec) & (bindVec.tag # tList)) THEN
      Error("loop: needs binding vector"); RETURN NilV
    END;
    newEnv := NewEnv(env);
    p := bindVec; numB := 0;
    WHILE ~IsNil(p) & (numB < 16) DO
      symV := p.head; p := p.tail;
      IF IsNil(p) THEN Error("loop: odd bindings"); RETURN NilV END;
      valV := EvalRef(p.head, newEnv);
      IF err THEN RETURN NilV END;
      IF symV.tag # tSym THEN Error("loop: not a symbol"); RETURN NilV END;
      Strings.Copy(symV.s, names[numB]); INC(numB);
      Define(newEnv, symV.s, valV);
      p := p.tail
    END;
    LOOP
      result := NilV; p := body;
      WHILE ~IsNil(p) & ~err & ~doRecur DO
        result := EvalRef(p.head, newEnv); p := p.tail
      END;
      IF err THEN RETURN NilV END;
      IF ~doRecur THEN EXIT END;
      doRecur := FALSE;
      rp := recurArgs; i := 0;
      WHILE (i < numB) & ~IsNil(rp) DO
        Define(newEnv, names[i], rp.head);
        rp := rp.tail; INC(i)
      END
    END;
    RETURN result
  END DoLoop;

  PROCEDURE DoRecur(args: Value): Value;
  VAR first, last, cell: Value;
  BEGIN
    first := NilV; last := NIL;
    WHILE ~IsNil(args) & ~err DO
      cell := Cons(EvalRef(args.head, env), NilV);
      IF err THEN RETURN NilV END;
      IF last = NIL THEN first := cell ELSE last.tail := cell END;
      last := cell; args := args.tail
    END;
    recurArgs := first; doRecur := TRUE;
    RETURN NilV
  END DoRecur;

  PROCEDURE DoDefmacro(args: Value): Value;
  VAR macV: Value;
  BEGIN
    IF IsNil(args) OR (args.head.tag # tSym) THEN
      Error("defmacro: needs name"); RETURN NilV
    END;
    NEW(macV); macV.tag := tMacro;
    macV.params := args.tail.head;
    macV.body := args.tail.tail;
    macV.closure := env;
    Define(GlobalEnv, args.head.s, macV);
    RETURN macV
  END DoDefmacro;

  PROCEDURE DoThrow(args: Value): Value;
  VAR v: Value;
  BEGIN
    v := EvalRef(args.head, env);
    IF err THEN RETURN NilV END;
    thrownVal := v; isThrown := TRUE; err := TRUE;
    RETURN NilV
  END DoThrow;

  PROCEDURE IsCatchOrFinally(v: Value): BOOLEAN;
  BEGIN
    RETURN (v.tag = tList) & ~IsNil(v.head) & (v.head.tag = tSym)
           & ((v.head.s = "catch") OR (v.head.s = "finally"))
  END IsCatchOrFinally;

  PROCEDURE DoTry(args: Value): Value;
  VAR clause, result, catchSym, catchBody, p, finallyForms: Value;
      hasCatch, hasFinally, wasErr, wasThrown: BOOLEAN;
      newEnv: Env; savedMsg: ARRAY 256 OF CHAR; savedThrown: Value;
  BEGIN
    hasCatch := FALSE; hasFinally := FALSE;
    catchSym := NilV; catchBody := NilV; finallyForms := NilV; result := NilV;
    wasErr := FALSE; wasThrown := FALSE; savedThrown := NilV;
    p := args;
    WHILE ~IsNil(p) DO
      IF IsCatchOrFinally(p.head) THEN EXIT END;
      IF ~err THEN result := EvalRef(p.head, env) END;
      p := p.tail
    END;
    WHILE ~IsNil(p) & ~IsCatchOrFinally(p.head) DO p := p.tail END;
    WHILE ~IsNil(p) DO
      clause := p.head;
      IF IsCatchOrFinally(clause) THEN
        IF clause.head.s = "catch" THEN
          hasCatch := TRUE;
          IF ~IsNil(clause.tail) & ~IsNil(clause.tail.tail) THEN
            catchSym := clause.tail.tail.head;
            catchBody := clause.tail.tail.tail
          END
        ELSIF clause.head.s = "finally" THEN
          hasFinally := TRUE; finallyForms := clause.tail
        END
      END;
      p := p.tail
    END;
    wasErr := err;
    IF wasErr THEN
      wasThrown := isThrown;
      IF wasThrown THEN savedThrown := thrownVal
      ELSE Strings.Copy(errMsg, savedMsg); savedThrown := MkStr(savedMsg) END
    END;
    IF wasErr & hasCatch THEN
      err := FALSE; isThrown := FALSE;
      newEnv := NewEnv(env);
      IF ~IsNil(catchSym) & (catchSym.tag = tSym) THEN
        Define(newEnv, catchSym.s, savedThrown)
      END;
      result := NilV;
      WHILE ~IsNil(catchBody) & ~err DO
        result := EvalRef(catchBody.head, newEnv); catchBody := catchBody.tail
      END
    END;
    IF hasFinally THEN
      wasErr := err; Strings.Copy(errMsg, savedMsg);
      wasThrown := isThrown; savedThrown := thrownVal;
      err := FALSE;
      WHILE ~IsNil(finallyForms) DO
        EvalRef(finallyForms.head, env); finallyForms := finallyForms.tail
      END;
      IF wasErr THEN
        err := TRUE; Strings.Copy(savedMsg, errMsg);
        isThrown := wasThrown; thrownVal := savedThrown
      ELSE err := FALSE END
    END;
    RETURN result
  END DoTry;

  PROCEDURE DoQuasiquote(args: Value): Value;
  VAR expanded: Value;
  BEGIN
    IF IsNil(args) THEN RETURN NilV END;
    expanded := ExpandQQ(args.head);
    RETURN EvalRef(expanded, env)
  END DoQuasiquote;

  PROCEDURE DoLetfn(args: Value): Value;
  VAR fnDefs, body, def, name, fnVal, result: Value; newEnv: Env;
  BEGIN
    fnDefs := args.head; body := args.tail;
    newEnv := NewEnv(env);
    def := fnDefs;
    WHILE ~IsNil(def) DO
      IF ~IsNil(def.head) & ~IsNil(def.head.head) & (def.head.head.tag = tSym) THEN
        Define(newEnv, def.head.head.s, NilV)
      END;
      def := def.tail
    END;
    def := fnDefs;
    WHILE ~IsNil(def) DO
      IF ~IsNil(def.head) & ~IsNil(def.head.head) & (def.head.head.tag = tSym) THEN
        name := def.head.head;
        NEW(fnVal); fnVal.tag := tFn;
        fnVal.params := def.head.tail.head;
        fnVal.body := def.head.tail.tail;
        fnVal.closure := newEnv;
        Define(newEnv, name.s, fnVal)
      END;
      def := def.tail
    END;
    result := NilV;
    WHILE ~IsNil(body) & ~err DO
      result := EvalRef(body.head, newEnv); body := body.tail
    END;
    RETURN result
  END DoLetfn;

  PROCEDURE DoDelay(args: Value): Value;
  VAR v: Value;
  BEGIN
    NEW(v); v.tag := tDelay; v.head := NIL;
    v.body := Cons(MkSym("do"), args);
    v.closure := env;
    RETURN v
  END DoDelay;

  PROCEDURE DoFuture(args: Value): Value;
  VAR v, result: Value;
  BEGIN
    result := EvalRef(args.head, env);
    IF err THEN RETURN NilV END;
    NEW(v); v.tag := tAtom; v.head := result;
    RETURN v
  END DoFuture;

  PROCEDURE DoDefrecord(args: Value): Value;
  VAR typeName, fields, p: Value;
      fnVal, mapKeys, mapVals, kLast, vLast, c: Value;
      buf: ARRAY MaxStr OF CHAR;
  BEGIN
    typeName := args.head; fields := args.tail.head;
    IF IsNil(typeName) OR (typeName.tag # tSym) THEN
      Error("defrecord: needs name"); RETURN NilV
    END;
    IF IsNil(fields) OR ((fields.tag # tVec) & (fields.tag # tList)) THEN
      Error("defrecord: needs fields vector"); RETURN NilV
    END;
    (* ->TypeName constructor — use (hash-map ...) so field syms get evaluated *)
    NEW(fnVal); fnVal.tag := tFn; fnVal.params := fields;
    mapKeys := Cons(MkSym("hash-map"), NilV); kLast := mapKeys;
    (* first pair: :__type__ "TypeName" *)
    c := Cons(MkKey("__type__"), NilV); kLast.tail := c; kLast := c;
    c := Cons(MkStr(typeName.s), NilV); kLast.tail := c; kLast := c;
    p := fields;
    WHILE ~IsNil(p) DO
      IF (p.head # NIL) & (p.head.tag = tSym) THEN
        c := Cons(MkKey(p.head.s), NilV); kLast.tail := c; kLast := c;
        c := Cons(MkSym(p.head.s), NilV); kLast.tail := c; kLast := c
      END;
      p := p.tail
    END;
    fnVal.body := Cons(mapKeys, NilV);  (* mapKeys is now the (hash-map ...) call *)
    fnVal.closure := GlobalEnv;
    Strings.Copy("->", buf); Strings.Append(typeName.s, buf);
    Define(GlobalEnv, buf, fnVal);
    (* TypeName? predicate: (fn [x] (= (get x :__type__) "TypeName")) *)
    NEW(fnVal); fnVal.tag := tFn;
    fnVal.params := Cons(MkSym("x"), NilV);
    fnVal.body := Cons(
      Cons(MkSym("="),
        Cons(Cons(MkSym("get"), Cons(MkSym("x"), Cons(MkKey("__type__"), NilV))),
             Cons(MkStr(typeName.s), NilV))), NilV);
    fnVal.closure := GlobalEnv;
    Strings.Copy(typeName.s, buf); Strings.Append("?", buf);
    Define(GlobalEnv, buf, fnVal);
    (* map->TypeName: (fn [m] (assoc m :__type__ "TypeName")) *)
    NEW(fnVal); fnVal.tag := tFn;
    fnVal.params := Cons(MkSym("m"), NilV);
    fnVal.body := Cons(
      Cons(MkSym("assoc"),
        Cons(MkSym("m"), Cons(MkKey("__type__"), Cons(MkStr(typeName.s), NilV)))), NilV);
    fnVal.closure := GlobalEnv;
    Strings.Copy("map->", buf); Strings.Append(typeName.s, buf);
    Define(GlobalEnv, buf, fnVal);
    RETURN MkSym(typeName.s)
  END DoDefrecord;

  PROCEDURE DoDefprotocol(args: Value): Value;
  VAR protoName, methods, method, p: Value;
      mname: ARRAY MaxStr OF CHAR;
      protoMethods, last, c: Value;
  BEGIN
    protoName := args.head; methods := args.tail;
    IF IsNil(protoName) OR (protoName.tag # tSym) THEN
      Error("defprotocol: needs name"); RETURN NilV
    END;
    p := Lookup(GlobalEnv, "__proto_dispatch__");
    IF p = NIL THEN Define(GlobalEnv, "__proto_dispatch__", MkMap(NilV, NilV)) END;
    p := Lookup(GlobalEnv, "__protocols__");
    IF p = NIL THEN Define(GlobalEnv, "__protocols__", MkMap(NilV, NilV)) END;
    protoMethods := NilV; last := NIL;
    WHILE ~IsNil(methods) DO
      method := methods.head;
      IF (method.tag = tList) & ~IsNil(method.head) & (method.head.tag = tSym) THEN
        Strings.Copy(method.head.s, mname);
        c := Cons(MkStr(mname), NilV);
        IF last = NIL THEN protoMethods := c ELSE last.tail := c END;
        last := c;
        Define(GlobalEnv, mname, MakeDispatchFn(mname))
      END;
      methods := methods.tail
    END;
    p := Lookup(GlobalEnv, "__protocols__");
    p := BAssoc(Cons(p, Cons(MkStr(protoName.s), Cons(protoMethods, NilV))), GlobalEnv);
    Define(GlobalEnv, "__protocols__", p);
    RETURN MkSym(protoName.s)
  END DoDefprotocol;

  PROCEDURE RegisterMethodImpl(tname, mname: ARRAY OF CHAR; fnVal: Value);
  VAR p: Value;
  BEGIN
    p := Lookup(GlobalEnv, "__proto_dispatch__");
    IF p = NIL THEN p := MkMap(NilV, NilV); Define(GlobalEnv, "__proto_dispatch__", p) END;
    p := BAssocIn(Cons(p,
      Cons(Cons(MkStr(mname), Cons(MkStr(tname), NilV)),
           Cons(fnVal, NilV))), GlobalEnv);
    Define(GlobalEnv, "__proto_dispatch__", p)
  END RegisterMethodImpl;

  PROCEDURE DoExtendType(args: Value): Value;
  VAR typeName, methods, method, fnVal: Value;
      tname, mname: ARRAY MaxStr OF CHAR;
  BEGIN
    typeName := args.head; methods := args.tail.tail; (* skip protocol name *)
    IF IsNil(typeName) OR (typeName.tag # tSym) THEN
      Error("extend-type: needs type name"); RETURN NilV
    END;
    Strings.Copy(typeName.s, tname);
    WHILE ~IsNil(methods) DO
      method := methods.head;
      IF (method.tag = tList) & ~IsNil(method.head) & (method.head.tag = tSym) THEN
        Strings.Copy(method.head.s, mname);
        NEW(fnVal); fnVal.tag := tFn;
        fnVal.params := method.tail.head;
        fnVal.body := method.tail.tail;
        fnVal.closure := env;
        RegisterMethodImpl(tname, mname, fnVal)
      END;
      methods := methods.tail
    END;
    RETURN NilV
  END DoExtendType;

  PROCEDURE DoExtendProtocol(args: Value): Value;
  VAR rest, typeName, method, fnVal: Value;
      tname, mname: ARRAY MaxStr OF CHAR;
  BEGIN
    rest := args.tail; (* skip protocol name *)
    WHILE ~IsNil(rest) DO
      typeName := rest.head; rest := rest.tail;
      IF IsNil(typeName) OR (typeName.tag # tSym) THEN EXIT END;
      Strings.Copy(typeName.s, tname);
      WHILE ~IsNil(rest) & (rest.head.tag = tList) DO
        method := rest.head;
        IF ~IsNil(method.head) & (method.head.tag = tSym) THEN
          Strings.Copy(method.head.s, mname);
          NEW(fnVal); fnVal.tag := tFn;
          fnVal.params := method.tail.head;
          fnVal.body := method.tail.tail;
          fnVal.closure := env;
          RegisterMethodImpl(tname, mname, fnVal)
        END;
        rest := rest.tail
      END
    END;
    RETURN NilV
  END DoExtendProtocol;

  PROCEDURE DoDocForm(args: Value): Value;
  VAR v: Value;
  BEGIN
    IF IsNil(args) OR (args.head.tag # tSym) THEN
      Error("doc: needs a symbol"); RETURN NilV
    END;
    v := Lookup(env, args.head.s);
    Out.String("-------------------------"); Out.Ln;
    Out.String(args.head.s); Out.Ln;
    IF v = NIL THEN
      Out.String("  Not found."); Out.Ln
    ELSIF (v.tag = tBuiltin) OR (v.tag = tFn) OR (v.tag = tMacro) THEN
      IF v.doc[0] # 0X THEN Out.String("  "); Out.String(v.doc); Out.Ln
      ELSE Out.String("  No documentation available."); Out.Ln END
    ELSE
      Out.String("  "); PrintValue(v, TRUE); Out.Ln
    END;
    RETURN NilV
  END DoDocForm;

  PROCEDURE DoThread(args: Value; threadFirst: BOOLEAN): Value;
  VAR acc, forms, form, fn, evArgs, callArgs, p, lst, cell: Value;
  BEGIN
    IF IsNil(args) THEN RETURN NilV END;
    acc := EvalRef(args.head, env);
    IF err THEN RETURN NilV END;
    forms := args.tail;
    WHILE ~IsNil(forms) & ~err DO
      form := forms.head;
      IF form.tag = tSym THEN
        fn := EvalRef(form, env);
        IF err THEN RETURN NilV END;
        acc := Apply(fn, Cons(acc, NilV), env)
      ELSIF (form.tag = tList) OR (form.tag = tVec) THEN
        fn := EvalRef(form.head, env);
        IF err THEN RETURN NilV END;
        evArgs := EvalList(form.tail, env);
        IF err THEN RETURN NilV END;
        IF threadFirst THEN
          callArgs := Cons(acc, evArgs)
        ELSE
          p := evArgs; lst := NIL; callArgs := NilV;
          WHILE ~IsNil(p) DO
            cell := Cons(p.head, NilV);
            IF lst = NIL THEN callArgs := cell ELSE lst.tail := cell END;
            lst := cell; p := p.tail
          END;
          cell := Cons(acc, NilV);
          IF lst = NIL THEN callArgs := cell ELSE lst.tail := cell END
        END;
        acc := Apply(fn, callArgs, env)
      ELSE
        Error("->: invalid threading form"); RETURN NilV
      END;
      IF err THEN RETURN NilV END;
      forms := forms.tail
    END;
    RETURN acc
  END DoThread;

  PROCEDURE DoFor(args: Value): Value;
  VAR bindVec, body: Value;
  BEGIN
    IF IsNil(args) OR IsNil(args.tail) THEN
      Error("for: needs bindings and body"); RETURN NilV
    END;
    bindVec := args.head; body := args.tail.head;
    IF IsNil(bindVec) OR ((bindVec.tag # tVec) & (bindVec.tag # tList)) THEN
      Error("for: needs binding vector"); RETURN NilV
    END;
    RETURN ForExpand(bindVec, body, env)
  END DoFor;

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
        ELSIF sym = "when-not" THEN RETURN DoWhenNot(expr.tail)
        ELSIF sym = "cond" THEN RETURN DoCond(expr.tail)
        ELSIF sym = "case" THEN RETURN DoCase(expr.tail)
        ELSIF sym = "dotimes" THEN RETURN DoDotimes(expr.tail)
        ELSIF sym = "doseq" THEN RETURN DoDoseq(expr.tail)
        ELSIF sym = "loop" THEN RETURN DoLoop(expr.tail)
        ELSIF sym = "recur" THEN RETURN DoRecur(expr.tail)
        ELSIF sym = "defmacro" THEN RETURN DoDefmacro(expr.tail)
        ELSIF sym = "throw" THEN RETURN DoThrow(expr.tail)
        ELSIF sym = "try" THEN RETURN DoTry(expr.tail)
        ELSIF sym = "quasiquote" THEN RETURN DoQuasiquote(expr.tail)
        ELSIF sym = "letfn" THEN RETURN DoLetfn(expr.tail)
        ELSIF sym = "delay" THEN RETURN DoDelay(expr.tail)
        ELSIF sym = "future" THEN RETURN DoFuture(expr.tail)
        ELSIF sym = "dosync" THEN RETURN DoDo(expr.tail)
        ELSIF sym = "defrecord" THEN RETURN DoDefrecord(expr.tail)
        ELSIF sym = "defprotocol" THEN RETURN DoDefprotocol(expr.tail)
        ELSIF sym = "extend-type" THEN RETURN DoExtendType(expr.tail)
        ELSIF sym = "extend-protocol" THEN RETURN DoExtendProtocol(expr.tail)
        ELSIF sym = "doc" THEN RETURN DoDocForm(expr.tail)
        ELSIF sym = "->" THEN RETURN DoThread(expr.tail, TRUE)
        ELSIF sym = "->>" THEN RETURN DoThread(expr.tail, FALSE)
        ELSIF sym = "for" THEN RETURN DoFor(expr.tail)
        END
      END;
      fn := EvalRef(head, env);
      IF err THEN RETURN NilV END;
      IF (fn # NIL) & (fn.tag = tMacro) THEN
        RETURN Apply(fn, expr.tail, env)
      END;
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

PROCEDURE ValueEqual*(a, b: Value): BOOLEAN;
VAR pa, pb: Value; isSeqA, isSeqB: BOOLEAN;
BEGIN
  IF IsNil(a) & IsNil(b) THEN RETURN TRUE END;
  IF IsNil(a) OR IsNil(b) THEN RETURN FALSE END;
  IF IsNum(a) & IsNum(b) THEN RETURN NumsEqual(a, b) END;
  isSeqA := (a.tag = tList) OR (a.tag = tVec);
  isSeqB := (b.tag = tList) OR (b.tag = tVec);
  IF isSeqA & isSeqB THEN
    pa := a; pb := b;
    WHILE ~IsNil(pa) & ~IsNil(pb) DO
      IF ~ValueEqual(pa.head, pb.head) THEN RETURN FALSE END;
      pa := pa.tail; pb := pb.tail
    END;
    RETURN IsNil(pa) & IsNil(pb)
  END;
  IF (a.tag = tSet) & (b.tag = tSet) THEN
    IF ListLen(a.head) # ListLen(b.head) THEN RETURN FALSE END;
    pa := a.head;
    WHILE ~IsNil(pa) DO
      IF ~SetContains(b, pa.head) THEN RETURN FALSE END;
      pa := pa.tail
    END;
    RETURN TRUE
  END;
  IF a.tag # b.tag THEN RETURN FALSE END;
  CASE a.tag OF
    tBool: RETURN a.b = b.b
  | tStr, tSym, tKey, tRegex: RETURN a.s = b.s
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
  IF v.tag = tSet THEN RETURN MkInt(ListLen(v.head)) END;
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
  IF coll.tag = tSet THEN RETURN SetConj(coll, item) END;
  Error("conj: unsupported collection"); RETURN NilV
END BConj;

PROCEDURE BMap(args: Value; env: Env): Value;
VAR fn, coll, first, last, cell, callArgs, result: Value;
BEGIN
  fn := args.head; coll := args.tail.head;
  IF ~IsNil(coll) & (coll.tag = tSet) THEN coll := coll.head END;
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
  IF ~IsNil(coll) & (coll.tag = tSet) THEN coll := coll.head END;
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
    IF ~IsNil(coll) & (coll.tag = tSet) THEN coll := coll.head END;
    IF IsNil(coll) THEN RETURN NilV END;
    acc := coll.head; coll := coll.tail
  ELSE
    acc := args.tail.head; coll := args.tail.tail.head;
    IF ~IsNil(coll) & (coll.tag = tSet) THEN coll := coll.head END
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
  | tSet: RETURN MkKey("set")
  | tRegex: RETURN MkKey("regex")
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
  IF v.tag = tSet THEN RETURN MkBool(IsNil(v.head)) END;
  IF v.tag = tMap THEN RETURN MkBool(IsNil(v.head)) END;
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

(* ---------- New builtins ---------- *)

(* Arithmetic *)
PROCEDURE BQuot(args: Value; env: Env): Value;
VAR a, b: Value;
BEGIN
  a := args.head; b := args.tail.head;
  IF (a.tag # tInt) OR (b.tag # tInt) THEN Error("quot: needs ints"); RETURN NilV END;
  IF b.i = 0 THEN Error("quot: division by zero"); RETURN NilV END;
  RETURN MkInt(a.i DIV b.i)
END BQuot;

PROCEDURE BRem(args: Value; env: Env): Value;
VAR a, b, r: Value; ri: INTEGER;
BEGIN
  a := args.head; b := args.tail.head;
  IF (a.tag # tInt) OR (b.tag # tInt) THEN Error("rem: needs ints"); RETURN NilV END;
  IF b.i = 0 THEN Error("rem: division by zero"); RETURN NilV END;
  ri := a.i - (a.i DIV b.i) * b.i;  (* floor remainder *)
  IF (ri # 0) & ((a.i < 0) # (b.i < 0)) THEN ri := ri - b.i END;  (* truncate toward zero *)
  RETURN MkInt(ri)
END BRem;

PROCEDURE BMax(args: Value; env: Env): Value;
VAR best, a: Value;
BEGIN
  IF IsNil(args) THEN Error("max: needs args"); RETURN NilV END;
  best := args.head; args := args.tail;
  WHILE ~IsNil(args) DO
    a := args.head;
    IF NumReal(a) > NumReal(best) THEN best := a END;
    args := args.tail
  END;
  RETURN best
END BMax;

PROCEDURE BMin(args: Value; env: Env): Value;
VAR best, a: Value;
BEGIN
  IF IsNil(args) THEN Error("min: needs args"); RETURN NilV END;
  best := args.head; args := args.tail;
  WHILE ~IsNil(args) DO
    a := args.head;
    IF NumReal(a) < NumReal(best) THEN best := a END;
    args := args.tail
  END;
  RETURN best
END BMin;

PROCEDURE BAbs(args: Value; env: Env): Value;
VAR v: Value;
BEGIN
  v := args.head;
  IF v.tag = tInt THEN
    IF v.i < 0 THEN RETURN MkInt(-v.i) ELSE RETURN v END
  END;
  IF v.tag = tReal THEN RETURN MkReal(Math.abs(v.r)) END;
  Error("abs: needs number"); RETURN NilV
END BAbs;

PROCEDURE BEvenQ(args: Value; env: Env): Value;
BEGIN
  IF args.head.tag # tInt THEN Error("even?: needs int"); RETURN NilV END;
  RETURN MkBool(args.head.i MOD 2 = 0)
END BEvenQ;

PROCEDURE BOddQ(args: Value; env: Env): Value;
BEGIN
  IF args.head.tag # tInt THEN Error("odd?: needs int"); RETURN NilV END;
  RETURN MkBool(args.head.i MOD 2 # 0)
END BOddQ;

PROCEDURE BZeroQ(args: Value; env: Env): Value;
BEGIN RETURN MkBool(IsNum(args.head) & (NumReal(args.head) = 0.0)) END BZeroQ;

PROCEDURE BPosQ(args: Value; env: Env): Value;
BEGIN RETURN MkBool(IsNum(args.head) & (NumReal(args.head) > 0.0)) END BPosQ;

PROCEDURE BNegQ(args: Value; env: Env): Value;
BEGIN RETURN MkBool(IsNum(args.head) & (NumReal(args.head) < 0.0)) END BNegQ;

(* Math *)
PROCEDURE BFloor(args: Value; env: Env): Value;
BEGIN RETURN MkInt(Math.entier(Math.floor(NumReal(args.head)))) END BFloor;

PROCEDURE BCeil(args: Value; env: Env): Value;
BEGIN RETURN MkInt(Math.entier(Math.ceil(NumReal(args.head)))) END BCeil;

PROCEDURE BRound(args: Value; env: Env): Value;
BEGIN RETURN MkInt(Math.entier(Math.round(NumReal(args.head)))) END BRound;

PROCEDURE BPow(args: Value; env: Env): Value;
BEGIN RETURN MkReal(Math.power(NumReal(args.head), NumReal(args.tail.head))) END BPow;

PROCEDURE BLog(args: Value; env: Env): Value;
BEGIN RETURN MkReal(Math.ln(NumReal(args.head))) END BLog;

PROCEDURE BExp(args: Value; env: Env): Value;
BEGIN RETURN MkReal(Math.exp(NumReal(args.head))) END BExp;

PROCEDURE BSin(args: Value; env: Env): Value;
BEGIN RETURN MkReal(Math.sin(NumReal(args.head))) END BSin;

PROCEDURE BCos(args: Value; env: Env): Value;
BEGIN RETURN MkReal(Math.cos(NumReal(args.head))) END BCos;

PROCEDURE BTan(args: Value; env: Env): Value;
BEGIN RETURN MkReal(Math.tan(NumReal(args.head))) END BTan;

PROCEDURE BAtan(args: Value; env: Env): Value;
BEGIN RETURN MkReal(Math.arctan(NumReal(args.head))) END BAtan;

PROCEDURE BAtan2(args: Value; env: Env): Value;
BEGIN RETURN MkReal(Math.arctan2(NumReal(args.head), NumReal(args.tail.head))) END BAtan2;

PROCEDURE BRand(args: Value; env: Env): Value;
BEGIN RETURN MkReal(Random.Real()) END BRand;

PROCEDURE BRandInt(args: Value; env: Env): Value;
VAR n: INTEGER;
BEGIN
  IF IsNil(args) THEN RETURN MkInt(Random.Int(1000000)) END;
  n := args.head.i;
  IF n <= 0 THEN Error("rand-int: needs positive n"); RETURN NilV END;
  RETURN MkInt(Random.Int(n))
END BRandInt;

(* Type predicates *)
PROCEDURE BNumberQ(args: Value; env: Env): Value;
BEGIN RETURN MkBool(IsNum(args.head)) END BNumberQ;

PROCEDURE BIntegerQ(args: Value; env: Env): Value;
BEGIN RETURN MkBool(~IsNil(args.head) & (args.head.tag = tInt)) END BIntegerQ;

PROCEDURE BFloatQ(args: Value; env: Env): Value;
BEGIN RETURN MkBool(~IsNil(args.head) & (args.head.tag = tReal)) END BFloatQ;

PROCEDURE BStringQ(args: Value; env: Env): Value;
BEGIN RETURN MkBool(~IsNil(args.head) & (args.head.tag = tStr)) END BStringQ;

PROCEDURE BBooleanQ(args: Value; env: Env): Value;
BEGIN RETURN MkBool(~IsNil(args.head) & (args.head.tag = tBool)) END BBooleanQ;

PROCEDURE BKeywordQ(args: Value; env: Env): Value;
BEGIN RETURN MkBool(~IsNil(args.head) & (args.head.tag = tKey)) END BKeywordQ;

PROCEDURE BSymbolQ(args: Value; env: Env): Value;
BEGIN RETURN MkBool(~IsNil(args.head) & (args.head.tag = tSym)) END BSymbolQ;

PROCEDURE BFnQ(args: Value; env: Env): Value;
VAR v: Value;
BEGIN
  v := args.head;
  RETURN MkBool(~IsNil(v) & ((v.tag = tFn) OR (v.tag = tBuiltin)))
END BFnQ;

PROCEDURE BCollQ(args: Value; env: Env): Value;
VAR v: Value;
BEGIN
  v := args.head;
  IF IsNil(v) THEN RETURN TrueV END;
  RETURN MkBool((v.tag = tList) OR (v.tag = tVec) OR (v.tag = tMap) OR (v.tag = tSet))
END BCollQ;

PROCEDURE BSeqQ(args: Value; env: Env): Value;
VAR v: Value;
BEGIN
  v := args.head;
  IF IsNil(v) THEN RETURN FalseV END;
  RETURN MkBool((v.tag = tList) OR (v.tag = tVec))
END BSeqQ;

PROCEDURE BListQ(args: Value; env: Env): Value;
BEGIN RETURN MkBool(IsNil(args.head) OR (~IsNil(args.head) & (args.head.tag = tList))) END BListQ;

PROCEDURE BVectorQ(args: Value; env: Env): Value;
BEGIN RETURN MkBool(~IsNil(args.head) & (args.head.tag = tVec)) END BVectorQ;

PROCEDURE BMapQ(args: Value; env: Env): Value;
BEGIN RETURN MkBool(~IsNil(args.head) & (args.head.tag = tMap)) END BMapQ;

PROCEDURE BTrueQ(args: Value; env: Env): Value;
BEGIN RETURN MkBool(~IsNil(args.head) & (args.head.tag = tBool) & args.head.b) END BTrueQ;

PROCEDURE BFalseQ(args: Value; env: Env): Value;
BEGIN RETURN MkBool(~IsNil(args.head) & (args.head.tag = tBool) & ~args.head.b) END BFalseQ;

(* Sequence operations *)
PROCEDURE BSecond(args: Value; env: Env): Value;
VAR v: Value;
BEGIN
  v := args.head;
  IF IsNil(v) OR IsNil(v.tail) THEN RETURN NilV END;
  RETURN v.tail.head
END BSecond;

PROCEDURE BLast(args: Value; env: Env): Value;
VAR v: Value;
BEGIN
  v := args.head;
  IF IsNil(v) THEN RETURN NilV END;
  WHILE ~IsNil(v.tail) DO v := v.tail END;
  RETURN v.head
END BLast;

PROCEDURE BNext(args: Value; env: Env): Value;
VAR v: Value;
BEGIN
  v := args.head;
  IF IsNil(v) OR IsNil(v.tail) THEN RETURN NilV END;
  RETURN v.tail
END BNext;

PROCEDURE BButlast(args: Value; env: Env): Value;
VAR v, first, last, cell: Value;
BEGIN
  v := args.head;
  IF IsNil(v) OR IsNil(v.tail) THEN RETURN NilV END;
  first := NilV; last := NIL;
  WHILE ~IsNil(v.tail) DO
    cell := Cons(v.head, NilV);
    IF last = NIL THEN first := cell ELSE last.tail := cell END;
    last := cell; v := v.tail
  END;
  RETURN first
END BButlast;

PROCEDURE BTake(args: Value; env: Env): Value;
VAR n: INTEGER; coll, first, last, cell: Value;
BEGIN
  n := args.head.i; coll := args.tail.head;
  first := NilV; last := NIL;
  WHILE (n > 0) & ~IsNil(coll) DO
    cell := Cons(coll.head, NilV);
    IF last = NIL THEN first := cell ELSE last.tail := cell END;
    last := cell; coll := coll.tail; DEC(n)
  END;
  RETURN first
END BTake;

PROCEDURE BDrop(args: Value; env: Env): Value;
VAR n: INTEGER; coll: Value;
BEGIN
  n := args.head.i; coll := args.tail.head;
  WHILE (n > 0) & ~IsNil(coll) DO coll := coll.tail; DEC(n) END;
  RETURN coll
END BDrop;

PROCEDURE BTakeWhile(args: Value; env: Env): Value;
VAR fn, coll, first, last, cell, callArgs, result: Value;
BEGIN
  fn := args.head; coll := args.tail.head;
  first := NilV; last := NIL;
  WHILE ~IsNil(coll) & ~err DO
    callArgs := Cons(coll.head, NilV);
    result := Apply(fn, callArgs, env);
    IF err OR ~IsTruthy(result) THEN EXIT END;
    cell := Cons(coll.head, NilV);
    IF last = NIL THEN first := cell ELSE last.tail := cell END;
    last := cell; coll := coll.tail
  END;
  RETURN first
END BTakeWhile;

PROCEDURE BDropWhile(args: Value; env: Env): Value;
VAR fn, coll, callArgs, result: Value;
BEGIN
  fn := args.head; coll := args.tail.head;
  WHILE ~IsNil(coll) & ~err DO
    callArgs := Cons(coll.head, NilV);
    result := Apply(fn, callArgs, env);
    IF err OR ~IsTruthy(result) THEN EXIT END;
    coll := coll.tail
  END;
  IF err THEN RETURN NilV END;
  RETURN coll
END BDropWhile;

PROCEDURE BConcat(args: Value; env: Env): Value;
VAR first, last, cell, coll: Value;
BEGIN
  first := NilV; last := NIL;
  WHILE ~IsNil(args) DO
    coll := args.head;
    WHILE ~IsNil(coll) DO
      cell := Cons(coll.head, NilV);
      IF last = NIL THEN first := cell ELSE last.tail := cell END;
      last := cell; coll := coll.tail
    END;
    args := args.tail
  END;
  RETURN first
END BConcat;

PROCEDURE BReverse(args: Value; env: Env): Value;
VAR v, result: Value;
BEGIN
  v := args.head; result := NilV;
  WHILE ~IsNil(v) DO result := Cons(v.head, result); v := v.tail END;
  RETURN result
END BReverse;

PROCEDURE ValLT(a, b: Value): BOOLEAN;
BEGIN
  IF IsNum(a) & IsNum(b) THEN RETURN NumReal(a) < NumReal(b) END;
  IF (a.tag = tStr) & (b.tag = tStr) THEN RETURN Strings.Compare(a.s, b.s) < 0 END;
  IF (a.tag = tKey) & (b.tag = tKey) THEN RETURN Strings.Compare(a.s, b.s) < 0 END;
  RETURN FALSE
END ValLT;

PROCEDURE BSort(args: Value; env: Env): Value;
VAR coll, tmp: Value; n, i, j: INTEGER;
  arr: ARRAY 1024 OF Value;
BEGIN
  coll := args.head;
  IF ~IsNil(coll) & (coll.tag = tSet) THEN coll := coll.head END;
  n := 0;
  WHILE ~IsNil(coll) & (n < 1024) DO arr[n] := coll.head; INC(n); coll := coll.tail END;
  i := 1;
  WHILE i < n DO
    tmp := arr[i]; j := i - 1;
    WHILE (j >= 0) & ValLT(tmp, arr[j]) DO
      arr[j+1] := arr[j]; DEC(j)
    END;
    arr[j+1] := tmp; INC(i)
  END;
  coll := NilV; i := n - 1;
  WHILE i >= 0 DO coll := Cons(arr[i], coll); DEC(i) END;
  RETURN coll
END BSort;

PROCEDURE BSortBy(args: Value; env: Env): Value;
VAR fn, coll: Value; n, i, j: INTEGER;
  arr: ARRAY 1024 OF Value; tmp, ka, kb: Value; cont: BOOLEAN;
BEGIN
  fn := args.head; coll := args.tail.head;
  IF ~IsNil(coll) & (coll.tag = tSet) THEN coll := coll.head END;
  n := 0;
  WHILE ~IsNil(coll) & (n < 1024) DO arr[n] := coll.head; INC(n); coll := coll.tail END;
  i := 1;
  WHILE i < n DO
    tmp := arr[i]; j := i - 1; cont := TRUE;
    WHILE (j >= 0) & cont DO
      ka := Apply(fn, Cons(arr[j], NilV), env);
      kb := Apply(fn, Cons(tmp, NilV), env);
      IF err THEN RETURN NilV END;
      IF ValLT(kb, ka) THEN arr[j+1] := arr[j]; DEC(j)
      ELSE cont := FALSE END
    END;
    arr[j+1] := tmp; INC(i)
  END;
  coll := NilV; i := n - 1;
  WHILE i >= 0 DO coll := Cons(arr[i], coll); DEC(i) END;
  RETURN coll
END BSortBy;

PROCEDURE BEveryQ(args: Value; env: Env): Value;
VAR fn, coll, result: Value;
BEGIN
  fn := args.head; coll := args.tail.head;
  IF ~IsNil(coll) & (coll.tag = tSet) THEN coll := coll.head END;
  WHILE ~IsNil(coll) & ~err DO
    result := Apply(fn, Cons(coll.head, NilV), env);
    IF err THEN RETURN NilV END;
    IF ~IsTruthy(result) THEN RETURN FalseV END;
    coll := coll.tail
  END;
  RETURN TrueV
END BEveryQ;

PROCEDURE BSome(args: Value; env: Env): Value;
VAR fn, coll, result: Value;
BEGIN
  fn := args.head; coll := args.tail.head;
  IF ~IsNil(coll) & (coll.tag = tSet) THEN coll := coll.head END;
  WHILE ~IsNil(coll) & ~err DO
    result := Apply(fn, Cons(coll.head, NilV), env);
    IF err THEN RETURN NilV END;
    IF IsTruthy(result) THEN RETURN result END;
    coll := coll.tail
  END;
  RETURN NilV
END BSome;

PROCEDURE BNotAnyQ(args: Value; env: Env): Value;
VAR fn, coll, result: Value;
BEGIN
  fn := args.head; coll := args.tail.head;
  IF ~IsNil(coll) & (coll.tag = tSet) THEN coll := coll.head END;
  WHILE ~IsNil(coll) & ~err DO
    result := Apply(fn, Cons(coll.head, NilV), env);
    IF err THEN RETURN NilV END;
    IF IsTruthy(result) THEN RETURN FalseV END;
    coll := coll.tail
  END;
  RETURN TrueV
END BNotAnyQ;

PROCEDURE BNotEveryQ(args: Value; env: Env): Value;
VAR fn, coll, result: Value;
BEGIN
  fn := args.head; coll := args.tail.head;
  IF ~IsNil(coll) & (coll.tag = tSet) THEN coll := coll.head END;
  WHILE ~IsNil(coll) & ~err DO
    result := Apply(fn, Cons(coll.head, NilV), env);
    IF err THEN RETURN NilV END;
    IF ~IsTruthy(result) THEN RETURN TrueV END;
    coll := coll.tail
  END;
  RETURN FalseV
END BNotEveryQ;

PROCEDURE BInto(args: Value; env: Env): Value;
VAR dst, src, p, cell, first, last: Value; isVec: BOOLEAN; s: Value;
BEGIN
  dst := args.head; src := args.tail.head;
  IF ~IsNil(dst) & (dst.tag = tSet) THEN
    s := dst; p := src;
    WHILE ~IsNil(p) DO s := SetConj(s, p.head); p := p.tail END;
    RETURN s
  END;
  isVec := ~IsNil(dst) & (dst.tag = tVec);
  first := NilV; last := NIL;
  (* copy dst *)
  p := dst;
  WHILE ~IsNil(p) DO
    IF isVec THEN cell := MkVec(p.head, NilV) ELSE cell := Cons(p.head, NilV) END;
    IF last = NIL THEN first := cell ELSE last.tail := cell END;
    last := cell; p := p.tail
  END;
  (* append src *)
  p := src;
  WHILE ~IsNil(p) DO
    IF isVec THEN cell := MkVec(p.head, NilV) ELSE cell := Cons(p.head, NilV) END;
    IF last = NIL THEN first := cell ELSE last.tail := cell END;
    last := cell; p := p.tail
  END;
  RETURN first
END BInto;

PROCEDURE BSeq(args: Value; env: Env): Value;
VAR v: Value; i: INTEGER; first, last, cell: Value; buf: ARRAY 2 OF CHAR;
BEGIN
  v := args.head;
  IF IsNil(v) THEN RETURN NilV END;
  IF v.tag = tList THEN
    IF ListLen(v) = 0 THEN RETURN NilV END;
    RETURN v
  END;
  IF v.tag = tVec THEN
    IF ListLen(v) = 0 THEN RETURN NilV END;
    first := NilV; last := NIL;
    WHILE ~IsNil(v) DO
      cell := Cons(v.head, NilV);
      IF last = NIL THEN first := cell ELSE last.tail := cell END;
      last := cell; v := v.tail
    END;
    RETURN first
  END;
  IF v.tag = tStr THEN
    i := 0; first := NilV; last := NIL; buf[1] := 0X;
    WHILE v.s[i] # 0X DO
      buf[0] := v.s[i];
      cell := Cons(MkStr(buf), NilV);
      IF last = NIL THEN first := cell ELSE last.tail := cell END;
      last := cell; INC(i)
    END;
    RETURN first
  END;
  IF v.tag = tSet THEN
    IF IsNil(v.head) THEN RETURN NilV END;
    RETURN v.head
  END;
  RETURN NilV
END BSeq;

PROCEDURE FlattenInto(v: Value; VAR first, last: Value);
VAR cell: Value;
BEGIN
  IF IsNil(v) THEN RETURN END;
  IF (v.tag = tList) OR (v.tag = tVec) THEN
    WHILE ~IsNil(v) DO FlattenInto(v.head, first, last); v := v.tail END
  ELSE
    cell := Cons(v, NilV);
    IF last = NIL THEN first := cell ELSE last.tail := cell END;
    last := cell
  END
END FlattenInto;

PROCEDURE BFlatten(args: Value; env: Env): Value;
VAR first, last: Value;
BEGIN
  first := NilV; last := NIL;
  FlattenInto(args.head, first, last);
  RETURN first
END BFlatten;

PROCEDURE BDistinct(args: Value; env: Env): Value;
VAR coll, p, first, last, cell: Value; found: BOOLEAN;
BEGIN
  coll := args.head; first := NilV; last := NIL;
  WHILE ~IsNil(coll) DO
    (* check if already in result *)
    p := first; found := FALSE;
    WHILE ~IsNil(p) DO
      IF ValueEqual(p.head, coll.head) THEN found := TRUE END;
      p := p.tail
    END;
    IF ~found THEN
      cell := Cons(coll.head, NilV);
      IF last = NIL THEN first := cell ELSE last.tail := cell END;
      last := cell
    END;
    coll := coll.tail
  END;
  RETURN first
END BDistinct;

PROCEDURE BMapcat(args: Value; env: Env): Value;
VAR fn, coll, first, last, cell, subList, callArgs: Value;
BEGIN
  fn := args.head; coll := args.tail.head;
  first := NilV; last := NIL;
  WHILE ~IsNil(coll) & ~err DO
    callArgs := Cons(coll.head, NilV);
    subList := Apply(fn, callArgs, env);
    IF err THEN RETURN NilV END;
    WHILE ~IsNil(subList) DO
      cell := Cons(subList.head, NilV);
      IF last = NIL THEN first := cell ELSE last.tail := cell END;
      last := cell; subList := subList.tail
    END;
    coll := coll.tail
  END;
  RETURN first
END BMapcat;

PROCEDURE BKeep(args: Value; env: Env): Value;
VAR fn, coll, first, last, cell, callArgs, result: Value;
BEGIN
  fn := args.head; coll := args.tail.head;
  first := NilV; last := NIL;
  WHILE ~IsNil(coll) & ~err DO
    callArgs := Cons(coll.head, NilV);
    result := Apply(fn, callArgs, env);
    IF err THEN RETURN NilV END;
    IF ~IsNil(result) & IsTruthy(result) THEN
      cell := Cons(result, NilV);
      IF last = NIL THEN first := cell ELSE last.tail := cell END;
      last := cell
    END;
    coll := coll.tail
  END;
  RETURN first
END BKeep;

PROCEDURE BRemove(args: Value; env: Env): Value;
VAR fn, coll, first, last, cell, callArgs, result: Value;
BEGIN
  fn := args.head; coll := args.tail.head;
  first := NilV; last := NIL;
  WHILE ~IsNil(coll) & ~err DO
    callArgs := Cons(coll.head, NilV);
    result := Apply(fn, callArgs, env);
    IF err THEN RETURN NilV END;
    IF ~IsTruthy(result) THEN
      cell := Cons(coll.head, NilV);
      IF last = NIL THEN first := cell ELSE last.tail := cell END;
      last := cell
    END;
    coll := coll.tail
  END;
  RETURN first
END BRemove;

PROCEDURE BPartition(args: Value; env: Env): Value;
VAR n: INTEGER; coll, first, last, grpFirst, grpLast, cell, group: Value; count: INTEGER;
BEGIN
  n := args.head.i; coll := args.tail.head;
  first := NilV; last := NIL;
  WHILE ~IsNil(coll) DO
    grpFirst := NilV; grpLast := NIL; count := 0;
    WHILE (count < n) & ~IsNil(coll) DO
      cell := Cons(coll.head, NilV);
      IF grpLast = NIL THEN grpFirst := cell ELSE grpLast.tail := cell END;
      grpLast := cell; INC(count); coll := coll.tail
    END;
    IF count = n THEN
      group := Cons(grpFirst, NilV);
      IF last = NIL THEN first := group ELSE last.tail := group END;
      last := group
    END
  END;
  RETURN first
END BPartition;

PROCEDURE BInterpose(args: Value; env: Env): Value;
VAR sep, coll, first, last, cell: Value;
BEGIN
  sep := args.head; coll := args.tail.head;
  first := NilV; last := NIL;
  WHILE ~IsNil(coll) DO
    cell := Cons(coll.head, NilV);
    IF last = NIL THEN first := cell ELSE last.tail := cell END;
    last := cell; coll := coll.tail;
    IF ~IsNil(coll) THEN
      cell := Cons(sep, NilV); last.tail := cell; last := cell
    END
  END;
  RETURN first
END BInterpose;

PROCEDURE BFrequencies(args: Value; env: Env): Value;
VAR coll, ks, vs, kp, vp, c: Value; found: BOOLEAN;
BEGIN
  coll := args.head;
  ks := NilV; vs := NilV;
  WHILE ~IsNil(coll) DO
    kp := ks; vp := vs; found := FALSE;
    WHILE ~IsNil(kp) DO
      IF ValueEqual(kp.head, coll.head) THEN
        vp.head := MkInt(vp.head.i + 1); found := TRUE
      END;
      kp := kp.tail; vp := vp.tail
    END;
    IF ~found THEN
      c := Cons(coll.head, NilV); ks := Cons(c.head, ks);
      vs := Cons(MkInt(1), vs)
    END;
    coll := coll.tail
  END;
  RETURN MkMap(ks, vs)
END BFrequencies;

PROCEDURE BZipmap(args: Value; env: Env): Value;
VAR keys, vals: Value;
BEGIN
  keys := args.head; vals := args.tail.head;
  RETURN MkMap(keys, vals)
END BZipmap;

PROCEDURE BShuffle(args: Value; env: Env): Value;
VAR coll: Value; n, i, j: INTEGER;
  arr: ARRAY 1024 OF Value; tmp: Value;
BEGIN
  coll := args.head; n := 0;
  WHILE ~IsNil(coll) & (n < 1024) DO arr[n] := coll.head; INC(n); coll := coll.tail END;
  i := n - 1;
  WHILE i > 0 DO
    j := Random.Int(i + 1);
    tmp := arr[i]; arr[i] := arr[j]; arr[j] := tmp;
    DEC(i)
  END;
  coll := NilV; i := n - 1;
  WHILE i >= 0 DO coll := Cons(arr[i], coll); DEC(i) END;
  RETURN coll
END BShuffle;

(* Map operations *)
PROCEDURE BDissoc(args: Value; env: Env): Value;
VAR m, k, ks, vs, nks, nvs, c: Value; nkLast, nvLast: Value;
BEGIN
  m := args.head; k := args.tail.head;
  IF IsNil(m) OR (m.tag # tMap) THEN RETURN m END;
  ks := m.head; vs := m.tail;
  nks := NilV; nvs := NilV; nkLast := NIL; nvLast := NIL;
  WHILE ~IsNil(ks) DO
    IF ~ValueEqual(ks.head, k) THEN
      c := Cons(ks.head, NilV);
      IF nkLast = NIL THEN nks := c ELSE nkLast.tail := c END;
      nkLast := c;
      c := Cons(vs.head, NilV);
      IF nvLast = NIL THEN nvs := c ELSE nvLast.tail := c END;
      nvLast := c
    END;
    ks := ks.tail; vs := vs.tail
  END;
  RETURN MkMap(nks, nvs)
END BDissoc;

PROCEDURE BMerge(args: Value; env: Env): Value;
VAR result, m, ks, vs: Value;
BEGIN
  result := NilV;
  WHILE ~IsNil(args) DO
    m := args.head;
    IF ~IsNil(m) & (m.tag = tMap) THEN
      ks := m.head; vs := m.tail;
      WHILE ~IsNil(ks) DO
        result := BAssoc(Cons(result, Cons(ks.head, Cons(vs.head, NilV))), env);
        ks := ks.tail; vs := vs.tail
      END
    END;
    args := args.tail
  END;
  RETURN result
END BMerge;

PROCEDURE BContainsQ(args: Value; env: Env): Value;
VAR m, k, ks: Value;
BEGIN
  m := args.head; k := args.tail.head;
  IF IsNil(m) THEN RETURN FalseV END;
  IF m.tag = tMap THEN
    ks := m.head;
    WHILE ~IsNil(ks) DO
      IF ValueEqual(ks.head, k) THEN RETURN TrueV END;
      ks := ks.tail
    END;
    RETURN FalseV
  END;
  IF m.tag = tSet THEN RETURN MkBool(SetContains(m, k)) END;
  IF (m.tag = tVec) & (k.tag = tInt) THEN
    RETURN MkBool((k.i >= 0) & (k.i < ListLen(m)))
  END;
  RETURN FalseV
END BContainsQ;

PROCEDURE BHashMap(args: Value; env: Env): Value;
VAR ks, vs, kLast, vLast, c: Value;
BEGIN
  ks := NilV; vs := NilV; kLast := NIL; vLast := NIL;
  WHILE ~IsNil(args) & ~IsNil(args.tail) DO
    c := Cons(args.head, NilV);
    IF kLast = NIL THEN ks := c ELSE kLast.tail := c END;
    kLast := c;
    c := Cons(args.tail.head, NilV);
    IF vLast = NIL THEN vs := c ELSE vLast.tail := c END;
    vLast := c;
    args := args.tail.tail
  END;
  RETURN MkMap(ks, vs)
END BHashMap;

PROCEDURE BUpdate(args: Value; env: Env): Value;
VAR m, k, fn, oldVal, newVal: Value;
BEGIN
  m := args.head; k := args.tail.head; fn := args.tail.tail.head;
  oldVal := BGet(Cons(m, Cons(k, NilV)), env);
  newVal := Apply(fn, Cons(oldVal, NilV), env);
  IF err THEN RETURN NilV END;
  RETURN BAssoc(Cons(m, Cons(k, Cons(newVal, NilV))), env)
END BUpdate;

PROCEDURE BSelectKeys(args: Value; env: Env): Value;
VAR m, keyList, ks, vs, nks, nvs, c, v: Value; nkLast, nvLast: Value;
BEGIN
  m := args.head; keyList := args.tail.head;
  IF IsNil(m) OR (m.tag # tMap) THEN RETURN MkMap(NilV, NilV) END;
  nks := NilV; nvs := NilV; nkLast := NIL; nvLast := NIL;
  WHILE ~IsNil(keyList) DO
    v := BGet(Cons(m, Cons(keyList.head, NilV)), env);
    IF ~IsNil(v) THEN
      c := Cons(keyList.head, NilV);
      IF nkLast = NIL THEN nks := c ELSE nkLast.tail := c END; nkLast := c;
      c := Cons(v, NilV);
      IF nvLast = NIL THEN nvs := c ELSE nvLast.tail := c END; nvLast := c
    END;
    keyList := keyList.tail
  END;
  RETURN MkMap(nks, nvs)
END BSelectKeys;

(* Set operations *)
PROCEDURE BHashSet(args: Value; env: Env): Value;
VAR s, p: Value;
BEGIN
  s := MkSet(NilV); p := args;
  WHILE ~IsNil(p) DO s := SetConj(s, p.head); p := p.tail END;
  RETURN s
END BHashSet;

PROCEDURE BSortedSet(args: Value; env: Env): Value;
VAR s, p: Value;
BEGIN
  s := MkSortedSet(NilV); p := args;
  WHILE ~IsNil(p) DO s := SetConj(s, p.head); p := p.tail END;
  RETURN s
END BSortedSet;

PROCEDURE BSortedSetQ(args: Value; env: Env): Value;
VAR v: Value;
BEGIN
  v := args.head;
  RETURN MkBool((v # NIL) & (v.tag = tSet) & v.b)
END BSortedSetQ;

PROCEDURE BSetFn(args: Value; env: Env): Value;
VAR coll, s, p: Value;
BEGIN
  coll := args.head;
  IF IsNil(coll) THEN RETURN MkSet(NilV) END;
  IF coll.tag = tSet THEN RETURN coll END;
  IF coll.tag = tMap THEN coll := coll.head END;
  s := MkSet(NilV); p := coll;
  WHILE ~IsNil(p) DO s := SetConj(s, p.head); p := p.tail END;
  RETURN s
END BSetFn;

PROCEDURE BSetQ(args: Value; env: Env): Value;
BEGIN RETURN MkBool(~IsNil(args.head) & (args.head.tag = tSet)) END BSetQ;

PROCEDURE BDisj(args: Value; env: Env): Value;
VAR s, elem, p, first, last, cell: Value; sorted: BOOLEAN;
BEGIN
  s := args.head;
  IF IsNil(s) OR (s.tag # tSet) THEN Error("disj: needs a set"); RETURN NilV END;
  sorted := s.b;
  args := args.tail;
  WHILE ~IsNil(args) DO
    elem := args.head;
    first := NilV; last := NIL; p := s.head;
    WHILE ~IsNil(p) DO
      IF ~ValueEqual(p.head, elem) THEN
        cell := Cons(p.head, NilV);
        IF last = NIL THEN first := cell ELSE last.tail := cell END;
        last := cell
      END;
      p := p.tail
    END;
    IF sorted THEN s := MkSortedSet(first) ELSE s := MkSet(first) END;
    args := args.tail
  END;
  RETURN s
END BDisj;

PROCEDURE BUnion(args: Value; env: Env): Value;
VAR s, p: Value;
BEGIN
  s := MkSet(NilV);
  WHILE ~IsNil(args) DO
    IF ~IsNil(args.head) & (args.head.tag = tSet) THEN
      p := args.head.head;
      WHILE ~IsNil(p) DO s := SetConj(s, p.head); p := p.tail END
    END;
    args := args.tail
  END;
  RETURN s
END BUnion;

PROCEDURE BIntersection(args: Value; env: Env): Value;
VAR s, other, p: Value;
BEGIN
  IF IsNil(args) OR (args.head.tag # tSet) THEN RETURN MkSet(NilV) END;
  s := args.head; args := args.tail;
  WHILE ~IsNil(args) DO
    other := args.head;
    IF IsNil(other) OR (other.tag # tSet) THEN
      Error("intersection: needs sets"); RETURN NilV
    END;
    p := s.head; s := MkSet(NilV);
    WHILE ~IsNil(p) DO
      IF SetContains(other, p.head) THEN s := SetConj(s, p.head) END;
      p := p.tail
    END;
    args := args.tail
  END;
  RETURN s
END BIntersection;

PROCEDURE BDifference(args: Value; env: Env): Value;
VAR s, other, p: Value; keep: BOOLEAN;
BEGIN
  IF IsNil(args) OR (args.head.tag # tSet) THEN RETURN MkSet(NilV) END;
  s := args.head; args := args.tail;
  WHILE ~IsNil(args) DO
    other := args.head;
    IF IsNil(other) OR (other.tag # tSet) THEN
      Error("difference: needs sets"); RETURN NilV
    END;
    p := s.head; s := MkSet(NilV);
    WHILE ~IsNil(p) DO
      IF ~SetContains(other, p.head) THEN s := SetConj(s, p.head) END;
      p := p.tail
    END;
    args := args.tail
  END;
  RETURN s
END BDifference;

PROCEDURE BSubsetQ(args: Value; env: Env): Value;
VAR s1, s2, p: Value;
BEGIN
  s1 := args.head; s2 := args.tail.head;
  IF IsNil(s1) OR (s1.tag # tSet) OR IsNil(s2) OR (s2.tag # tSet) THEN
    Error("subset?: needs two sets"); RETURN NilV
  END;
  p := s1.head;
  WHILE ~IsNil(p) DO
    IF ~SetContains(s2, p.head) THEN RETURN FalseV END;
    p := p.tail
  END;
  RETURN TrueV
END BSubsetQ;

PROCEDURE BSupersetQ(args: Value; env: Env): Value;
VAR s1, s2: Value;
BEGIN
  s1 := args.head; s2 := args.tail.head;
  RETURN BSubsetQ(Cons(s2, Cons(s1, NilV)), env)
END BSupersetQ;

(* String operations *)
PROCEDURE BSubs(args: Value; env: Env): Value;
VAR s, start, end_: Value; buf: ARRAY MaxStr OF CHAR; len: INTEGER;
BEGIN
  s := args.head; start := args.tail.head;
  IF s.tag # tStr THEN Error("subs: needs string"); RETURN NilV END;
  len := Strings.Length(s.s);
  IF IsNil(args.tail.tail) THEN
    Strings.Extract(s.s, start.i, len - start.i, buf)
  ELSE
    end_ := args.tail.tail.head;
    Strings.Extract(s.s, start.i, end_.i - start.i, buf)
  END;
  RETURN MkStr(buf)
END BSubs;

PROCEDURE BSplit(args: Value; env: Env): Value;
VAR s, sep: Value; first, last, cell: Value; part: ARRAY MaxStr OF CHAR; n: INTEGER;
BEGIN
  s := args.head; sep := args.tail.head;
  IF (s.tag # tStr) OR (sep.tag # tStr) THEN Error("split: needs strings"); RETURN NilV END;
  first := NilV; last := NIL; n := 0;
  WHILE Strings.Split(s.s, sep.s[0], n, part) DO
    cell := Cons(MkStr(part), NilV);
    IF last = NIL THEN first := cell ELSE last.tail := cell END;
    last := cell; INC(n)
  END;
  RETURN first
END BSplit;

PROCEDURE BJoin(args: Value; env: Env): Value;
VAR sep, coll: Value; buf: ARRAY MaxStr OF CHAR; n: INTEGER; first: BOOLEAN;
    tmp: ARRAY 64 OF CHAR;
BEGIN
  sep := args.head; coll := args.tail.head;
  buf[0] := 0X; n := 0; first := TRUE;
  WHILE ~IsNil(coll) DO
    IF ~first & (sep.tag = tStr) THEN AppendCStr(buf, n, sep.s) END;
    IF coll.head.tag = tStr THEN AppendCStr(buf, n, coll.head.s)
    ELSIF coll.head.tag = tInt THEN
      Strings.IntToStr(coll.head.i, tmp); AppendCStr(buf, n, tmp)
    ELSIF coll.head.tag = tReal THEN
      Strings.RealToStr(coll.head.r, tmp); AppendCStr(buf, n, tmp)
    END;
    first := FALSE; coll := coll.tail
  END;
  buf[n] := 0X;
  RETURN MkStr(buf)
END BJoin;

PROCEDURE BUpperCase(args: Value; env: Env): Value;
VAR v: Value; buf: ARRAY MaxStr OF CHAR;
BEGIN
  v := args.head;
  IF v.tag # tStr THEN Error("upper-case: needs string"); RETURN NilV END;
  Strings.Copy(v.s, buf); Strings.ToUpper(buf);
  RETURN MkStr(buf)
END BUpperCase;

PROCEDURE BLowerCase(args: Value; env: Env): Value;
VAR v: Value; buf: ARRAY MaxStr OF CHAR;
BEGIN
  v := args.head;
  IF v.tag # tStr THEN Error("lower-case: needs string"); RETURN NilV END;
  Strings.Copy(v.s, buf); Strings.ToLower(buf);
  RETURN MkStr(buf)
END BLowerCase;

PROCEDURE BTrim(args: Value; env: Env): Value;
VAR v: Value; buf: ARRAY MaxStr OF CHAR;
BEGIN
  v := args.head;
  IF v.tag # tStr THEN Error("trim: needs string"); RETURN NilV END;
  Strings.Copy(v.s, buf); Strings.Trim(buf);
  RETURN MkStr(buf)
END BTrim;

PROCEDURE BStartsWithQ(args: Value; env: Env): Value;
VAR s, pre: Value;
BEGIN
  s := args.head; pre := args.tail.head;
  IF (s.tag # tStr) OR (pre.tag # tStr) THEN Error("starts-with?: needs strings"); RETURN NilV END;
  RETURN MkBool(Strings.StartsWith(s.s, pre.s))
END BStartsWithQ;

PROCEDURE BEndsWithQ(args: Value; env: Env): Value;
VAR s, suf: Value;
BEGIN
  s := args.head; suf := args.tail.head;
  IF (s.tag # tStr) OR (suf.tag # tStr) THEN Error("ends-with?: needs strings"); RETURN NilV END;
  RETURN MkBool(Strings.EndsWith(s.s, suf.s))
END BEndsWithQ;

PROCEDURE BIncludesQ(args: Value; env: Env): Value;
VAR s, sub: Value;
BEGIN
  s := args.head; sub := args.tail.head;
  IF (s.tag # tStr) OR (sub.tag # tStr) THEN Error("includes?: needs strings"); RETURN NilV END;
  RETURN MkBool(Strings.Pos(sub.s, s.s) >= 0)
END BIncludesQ;

PROCEDURE BStrlen(args: Value; env: Env): Value;
VAR v: Value;
BEGIN
  v := args.head;
  IF v.tag # tStr THEN Error("string-length: needs string"); RETURN NilV END;
  RETURN MkInt(Strings.Length(v.s))
END BStrlen;

PROCEDURE BStrCompare(args: Value; env: Env): Value;
VAR a, b: Value;
BEGIN
  a := args.head; b := args.tail.head;
  IF (a.tag # tStr) OR (b.tag # tStr) THEN Error("compare: needs strings"); RETURN NilV END;
  RETURN MkInt(Strings.Compare(a.s, b.s))
END BStrCompare;

(* Functional *)
(* ── clojure.string extensions ──────────────────────────────────────────── *)

PROCEDURE BStrBlankQ(args: Value; env: Env): Value;
VAR s: Value; i: INTEGER;
BEGIN
  s := args.head;
  IF IsNil(s) THEN RETURN TrueV END;
  IF s.tag # tStr THEN RETURN FalseV END;
  i := 0;
  WHILE s.s[i] # 0X DO
    IF (s.s[i] # ' ') & (s.s[i] # 09X) & (s.s[i] # 0AX) & (s.s[i] # 0DX) THEN
      RETURN FalseV
    END;
    INC(i)
  END;
  RETURN TrueV
END BStrBlankQ;

PROCEDURE BStrCapitalize(args: Value; env: Env): Value;
VAR s: Value; buf: ARRAY MaxStr OF CHAR;
BEGIN
  s := args.head;
  IF s.tag # tStr THEN Error("capitalize: needs string"); RETURN NilV END;
  Strings.Copy(s.s, buf); Strings.ToLower(buf);
  IF (buf[0] >= 'a') & (buf[0] <= 'z') THEN buf[0] := CHR(ORD(buf[0]) - 32) END;
  RETURN MkStr(buf)
END BStrCapitalize;

PROCEDURE BStrReverse(args: Value; env: Env): Value;
VAR s: Value; buf: ARRAY MaxStr OF CHAR; i, j, n: INTEGER; tmp: CHAR;
BEGIN
  s := args.head;
  IF s.tag # tStr THEN Error("string/reverse: needs string"); RETURN NilV END;
  Strings.Copy(s.s, buf);
  n := Strings.Length(buf); i := 0; j := n - 1;
  WHILE i < j DO
    tmp := buf[i]; buf[i] := buf[j]; buf[j] := tmp; INC(i); DEC(j)
  END;
  RETURN MkStr(buf)
END BStrReverse;

PROCEDURE BStrTrimL(args: Value; env: Env): Value;
VAR s: Value; buf: ARRAY MaxStr OF CHAR; i, j: INTEGER;
BEGIN
  s := args.head;
  IF s.tag # tStr THEN Error("triml: needs string"); RETURN NilV END;
  i := 0;
  WHILE (s.s[i] = ' ') OR (s.s[i] = 09X) OR (s.s[i] = 0AX) OR (s.s[i] = 0DX) DO INC(i) END;
  j := 0; WHILE s.s[i] # 0X DO buf[j] := s.s[i]; INC(i); INC(j) END;
  buf[j] := 0X;
  RETURN MkStr(buf)
END BStrTrimL;

PROCEDURE BStrTrimR(args: Value; env: Env): Value;
VAR s: Value; buf: ARRAY MaxStr OF CHAR; n: INTEGER;
BEGIN
  s := args.head;
  IF s.tag # tStr THEN Error("trimr: needs string"); RETURN NilV END;
  Strings.Copy(s.s, buf);
  n := Strings.Length(buf) - 1;
  WHILE (n >= 0) & ((buf[n] = ' ') OR (buf[n] = 09X) OR (buf[n] = 0AX) OR (buf[n] = 0DX)) DO
    DEC(n)
  END;
  buf[n+1] := 0X;
  RETURN MkStr(buf)
END BStrTrimR;

PROCEDURE BStrTrimNewline(args: Value; env: Env): Value;
VAR s: Value; buf: ARRAY MaxStr OF CHAR; n: INTEGER;
BEGIN
  s := args.head;
  IF s.tag # tStr THEN Error("trim-newline: needs string"); RETURN NilV END;
  Strings.Copy(s.s, buf);
  n := Strings.Length(buf) - 1;
  WHILE (n >= 0) & ((buf[n] = 0AX) OR (buf[n] = 0DX)) DO DEC(n) END;
  buf[n+1] := 0X;
  RETURN MkStr(buf)
END BStrTrimNewline;

PROCEDURE BStrSplitLines(args: Value; env: Env): Value;
VAR s: Value; first, last, cell: Value; buf: ARRAY MaxStr OF CHAR; i, j: INTEGER;
BEGIN
  s := args.head;
  IF s.tag # tStr THEN Error("split-lines: needs string"); RETURN NilV END;
  first := NilV; last := NIL; i := 0; j := 0;
  LOOP
    IF (s.s[i] = 0AX) OR (s.s[i] = 0X) THEN
      buf[j] := 0X;
      cell := Cons(MkStr(buf), NilV);
      IF last = NIL THEN first := cell ELSE last.tail := cell END;
      last := cell; j := 0;
      IF s.s[i] = 0X THEN EXIT END
    ELSIF s.s[i] # 0DX THEN
      IF j < MaxStr - 1 THEN buf[j] := s.s[i]; INC(j) END
    END;
    INC(i)
  END;
  RETURN first
END BStrSplitLines;

PROCEDURE BStrIndexOf(args: Value; env: Env): Value;
VAR s, sub, fromv: Value; from, pos: INTEGER; tail: ARRAY MaxStr OF CHAR;
BEGIN
  s := args.head; sub := args.tail.head;
  IF (s.tag # tStr) OR (sub.tag # tStr) THEN Error("index-of: needs strings"); RETURN NilV END;
  from := 0;
  IF ~IsNil(args.tail.tail) & ~IsNil(args.tail.tail.head) THEN
    fromv := args.tail.tail.head;
    IF fromv.tag = tInt THEN from := fromv.i END
  END;
  Strings.Extract(s.s, from, Strings.Length(s.s), tail);
  pos := Strings.Pos(sub.s, tail);
  IF pos < 0 THEN RETURN NilV END;
  RETURN MkInt(pos + from)
END BStrIndexOf;

PROCEDURE BStrLastIndexOf(args: Value; env: Env): Value;
VAR s, sub: Value; last, pos, cur, slen: INTEGER; tail: ARRAY MaxStr OF CHAR;
BEGIN
  s := args.head; sub := args.tail.head;
  IF (s.tag # tStr) OR (sub.tag # tStr) THEN Error("last-index-of: needs strings"); RETURN NilV END;
  last := -1; cur := 0; pos := 0; slen := Strings.Length(s.s);
  WHILE (cur <= slen) & (pos >= 0) DO
    Strings.Extract(s.s, cur, slen - cur, tail);
    pos := Strings.Pos(sub.s, tail);
    IF pos >= 0 THEN last := cur + pos; cur := last + 1 END
  END;
  IF last < 0 THEN RETURN NilV END;
  RETURN MkInt(last)
END BStrLastIndexOf;

PROCEDURE BStrReplace(args: Value; env: Env): Value;
VAR s, match, repl: Value; buf: ARRAY MaxStr OF CHAR;
    n, pos, start, mlen, i, j: INTEGER; found: BOOLEAN;
BEGIN
  s := args.head; match := args.tail.head; repl := args.tail.tail.head;
  IF s.tag # tStr THEN Error("string/replace: needs string first arg"); RETURN NilV END;
  IF repl.tag # tStr THEN Error("string/replace: replacement must be string"); RETURN NilV END;
  n := 0; pos := 0; buf[0] := 0X;
  IF match.tag = tRegex THEN
    LOOP
      start := Regex.FindAt(match.s, s.s, pos);
      IF start < 0 THEN
        j := pos; WHILE (s.s[j] # 0X) & (n < MaxStr-1) DO buf[n] := s.s[j]; INC(n); INC(j) END;
        EXIT
      END;
      mlen := Regex.MatchLen();
      j := pos; WHILE (j < start) & (n < MaxStr-1) DO buf[n] := s.s[j]; INC(n); INC(j) END;
      AppendCStr(buf, n, repl.s);
      IF mlen = 0 THEN
        IF s.s[pos] # 0X THEN
          IF n < MaxStr-1 THEN buf[n] := s.s[pos]; INC(n) END; INC(pos)
        ELSE EXIT END
      ELSE pos := start + mlen END
    END
  ELSIF match.tag = tStr THEN
    mlen := Strings.Length(match.s);
    IF mlen = 0 THEN Strings.Copy(s.s, buf)
    ELSE
      WHILE s.s[pos] # 0X DO
        found := TRUE; i := 0;
        WHILE (i < mlen) & found DO
          IF s.s[pos + i] # match.s[i] THEN found := FALSE END; INC(i)
        END;
        IF found THEN
          AppendCStr(buf, n, repl.s); pos := pos + mlen
        ELSE
          IF n < MaxStr-1 THEN buf[n] := s.s[pos]; INC(n) END; INC(pos)
        END
      END;
      buf[n] := 0X
    END
  ELSE
    Error("string/replace: match must be string or regex"); RETURN NilV
  END;
  RETURN MkStr(buf)
END BStrReplace;

PROCEDURE BStrReplaceFirst(args: Value; env: Env): Value;
VAR s, match, repl: Value; buf: ARRAY MaxStr OF CHAR;
    n, pos, start, mlen, i, j: INTEGER; found: BOOLEAN;
BEGIN
  s := args.head; match := args.tail.head; repl := args.tail.tail.head;
  IF s.tag # tStr THEN Error("string/replace-first: needs string"); RETURN NilV END;
  IF repl.tag # tStr THEN Error("string/replace-first: replacement must be string"); RETURN NilV END;
  n := 0; pos := 0; buf[0] := 0X;
  IF match.tag = tRegex THEN
    start := Regex.FindAt(match.s, s.s, 0);
    IF start >= 0 THEN
      mlen := Regex.MatchLen();
      j := 0; WHILE (j < start) & (n < MaxStr-1) DO buf[n] := s.s[j]; INC(n); INC(j) END;
      AppendCStr(buf, n, repl.s);
      j := start + mlen; WHILE (s.s[j] # 0X) & (n < MaxStr-1) DO buf[n] := s.s[j]; INC(n); INC(j) END;
      buf[n] := 0X
    ELSE Strings.Copy(s.s, buf) END
  ELSIF match.tag = tStr THEN
    mlen := Strings.Length(match.s);
    IF mlen = 0 THEN Strings.Copy(s.s, buf)
    ELSE
      found := FALSE;
      WHILE (s.s[pos] # 0X) & ~found DO
        found := TRUE; i := 0;
        WHILE (i < mlen) & found DO
          IF s.s[pos + i] # match.s[i] THEN found := FALSE END; INC(i)
        END;
        IF found THEN
          AppendCStr(buf, n, repl.s); pos := pos + mlen;
          WHILE (s.s[pos] # 0X) & (n < MaxStr-1) DO buf[n] := s.s[pos]; INC(n); INC(pos) END
        ELSE
          IF n < MaxStr-1 THEN buf[n] := s.s[pos]; INC(n) END; INC(pos)
        END
      END;
      buf[n] := 0X
    END
  ELSE
    Error("string/replace-first: match must be string or regex"); RETURN NilV
  END;
  RETURN MkStr(buf)
END BStrReplaceFirst;

PROCEDURE BIdentity(args: Value; env: Env): Value;
BEGIN RETURN args.head END BIdentity;

(* Atoms and concurrency *)
PROCEDURE BAtom(args: Value; env: Env): Value;
VAR v: Value;
BEGIN
  NEW(v); v.tag := tAtom;
  IF IsNil(args) THEN v.head := NilV ELSE v.head := args.head END;
  RETURN v
END BAtom;

PROCEDURE BAtomQ(args: Value; env: Env): Value;
BEGIN RETURN MkBool(~IsNil(args.head) & (args.head.tag = tAtom)) END BAtomQ;

PROCEDURE BDeref(args: Value; env: Env): Value;
VAR v: Value;
BEGIN
  v := args.head;
  IF IsNil(v) THEN Error("deref: nil"); RETURN NilV END;
  IF v.tag = tAtom THEN RETURN v.head END;
  IF v.tag = tDelay THEN
    IF v.head = NIL THEN
      v.head := EvalRef(v.body, v.closure);
      IF err THEN v.head := NIL; RETURN NilV END
    END;
    RETURN v.head
  END;
  Error("deref: not an atom or delay"); RETURN NilV
END BDeref;

PROCEDURE BResetBang(args: Value; env: Env): Value;
VAR atom, newVal: Value;
BEGIN
  atom := args.head; newVal := args.tail.head;
  IF IsNil(atom) OR (atom.tag # tAtom) THEN Error("reset!: not an atom"); RETURN NilV END;
  atom.head := newVal;
  RETURN newVal
END BResetBang;

PROCEDURE BSwapBang(args: Value; env: Env): Value;
VAR atom, fn, newVal, fnArgs: Value;
BEGIN
  atom := args.head; fn := args.tail.head;
  IF IsNil(atom) OR (atom.tag # tAtom) THEN Error("swap!: not an atom"); RETURN NilV END;
  fnArgs := Cons(atom.head, args.tail.tail);
  newVal := Apply(fn, fnArgs, env);
  IF err THEN RETURN NilV END;
  atom.head := newVal;
  RETURN newVal
END BSwapBang;

PROCEDURE BForce(args: Value; env: Env): Value;
VAR v: Value;
BEGIN
  v := args.head;
  IF IsNil(v) THEN RETURN NilV END;
  IF v.tag = tDelay THEN
    IF v.head = NIL THEN
      v.head := EvalRef(v.body, v.closure);
      IF err THEN v.head := NIL; RETURN NilV END
    END;
    RETURN v.head
  END;
  RETURN v
END BForce;

PROCEDURE BPromise(args: Value; env: Env): Value;
VAR v: Value;
BEGIN NEW(v); v.tag := tAtom; v.head := NilV; RETURN v END BPromise;

PROCEDURE BDeliver(args: Value; env: Env): Value;
VAR promise, val: Value;
BEGIN
  promise := args.head; val := args.tail.head;
  IF IsNil(promise) OR (promise.tag # tAtom) THEN Error("deliver: not a promise"); RETURN NilV END;
  promise.head := val;
  RETURN promise
END BDeliver;

PROCEDURE BFutureQ(args: Value; env: Env): Value;
BEGIN RETURN MkBool(~IsNil(args.head) & (args.head.tag = tAtom)) END BFutureQ;

PROCEDURE BFutureDoneQ(args: Value; env: Env): Value;
BEGIN RETURN TrueV END BFutureDoneQ;

PROCEDURE BSatisfiesQ(args: Value; env: Env): Value;
VAR proto, obj, methods, p, tname, disp, impl: Value;
BEGIN
  proto := args.head; obj := args.tail.head;
  IF IsNil(proto) THEN RETURN FalseV END;
  tname := MapGet(obj, MkKey("__type__"));
  IF IsNil(tname) THEN RETURN FalseV END;
  p := Lookup(GlobalEnv, "__protocols__");
  IF p = NIL THEN RETURN FalseV END;
  methods := MapGet(p, MkStr(proto.s));
  IF IsNil(methods) THEN RETURN FalseV END;
  disp := Lookup(GlobalEnv, "__proto_dispatch__");
  IF disp = NIL THEN RETURN FalseV END;
  WHILE ~IsNil(methods) DO
    impl := MapGet(MapGet(disp, methods.head), tname);
    IF IsNil(impl) THEN RETURN FalseV END;
    methods := methods.tail
  END;
  RETURN TrueV
END BSatisfiesQ;

PROCEDURE BInstanceQ(args: Value; env: Env): Value;
VAR typeName, obj, t: Value;
BEGIN
  typeName := args.head; obj := args.tail.head;
  IF IsNil(typeName) OR (typeName.tag # tSym) THEN RETURN FalseV END;
  t := MapGet(obj, MkKey("__type__"));
  IF IsNil(t) THEN RETURN FalseV END;
  RETURN MkBool(t.s = typeName.s)
END BInstanceQ;

PROCEDURE BThrow(args: Value; env: Env): Value;
VAR v: Value;
BEGIN
  v := args.head;
  thrownVal := v; isThrown := TRUE; err := TRUE;
  RETURN NilV
END BThrow;

(* I/O *)
PROCEDURE BPrint(args: Value; env: Env): Value;
VAR first: BOOLEAN;
BEGIN
  first := TRUE;
  WHILE ~IsNil(args) DO
    IF ~first THEN Out.Char(' ') END;
    PrintValue(args.head, FALSE);
    first := FALSE; args := args.tail
  END;
  RETURN NilV
END BPrint;

PROCEDURE BPr(args: Value; env: Env): Value;
VAR first: BOOLEAN;
BEGIN
  first := TRUE;
  WHILE ~IsNil(args) DO
    IF ~first THEN Out.Char(' ') END;
    PrintValue(args.head, TRUE);
    first := FALSE; args := args.tail
  END;
  RETURN NilV
END BPr;

PROCEDURE BNewline(args: Value; env: Env): Value;
BEGIN Out.Ln; RETURN NilV END BNewline;

PROCEDURE BFlush(args: Value; env: Env): Value;
BEGIN RETURN NilV END BFlush;

(* Misc *)
PROCEDURE BGensym(args: Value; env: Env): Value;
VAR buf: ARRAY MaxStr OF CHAR; n: ARRAY 16 OF CHAR;
BEGIN
  INC(gensymCount);
  Strings.Copy("G__", buf);
  Strings.IntToStr(gensymCount, n);
  Strings.Append(n, buf);
  RETURN MkSym(buf)
END BGensym;

PROCEDURE BReadString(args: Value; env: Env): Value;
VAR v: Value;
BEGIN
  v := args.head;
  IF v.tag # tStr THEN Error("read-string: needs string"); RETURN NilV END;
  RETURN ReadStr(v.s)
END BReadString;

PROCEDURE BPrintStr(args: Value; env: Env): Value;
VAR buf: ARRAY MaxStr OF CHAR; n: INTEGER;
    tmp: ARRAY 64 OF CHAR; first: BOOLEAN; v: Value;
BEGIN
  buf[0] := 0X; n := 0; first := TRUE;
  WHILE ~IsNil(args) DO
    IF ~first THEN
      IF n < LEN(buf)-1 THEN buf[n] := ' '; INC(n) END
    END;
    v := args.head;
    IF IsNil(v) THEN (* skip *)
    ELSIF v.tag = tStr THEN AppendCStr(buf, n, v.s)
    ELSIF v.tag = tInt THEN Strings.IntToStr(v.i, tmp); AppendCStr(buf, n, tmp)
    ELSIF v.tag = tReal THEN Strings.RealToStr(v.r, tmp); AppendCStr(buf, n, tmp)
    ELSIF v.tag = tBool THEN
      IF v.b THEN AppendCStr(buf, n, "true") ELSE AppendCStr(buf, n, "false") END
    ELSIF v.tag = tKey THEN
      IF n < LEN(buf)-1 THEN buf[n] := ':'; INC(n) END;
      AppendCStr(buf, n, v.s)
    END;
    first := FALSE; args := args.tail
  END;
  buf[n] := 0X;
  RETURN MkStr(buf)
END BPrintStr;

PROCEDURE BName(args: Value; env: Env): Value;
VAR v: Value;
BEGIN
  v := args.head;
  IF v.tag = tKey THEN RETURN MkStr(v.s) END;
  IF v.tag = tSym THEN RETURN MkStr(v.s) END;
  IF v.tag = tStr THEN RETURN v END;
  Error("name: needs keyword, symbol, or string"); RETURN NilV
END BName;

PROCEDURE BKeyword(args: Value; env: Env): Value;
VAR v: Value;
BEGIN
  v := args.head;
  IF v.tag = tKey THEN RETURN v END;
  IF (v.tag = tStr) OR (v.tag = tSym) THEN RETURN MkKey(v.s) END;
  Error("keyword: needs string or symbol"); RETURN NilV
END BKeyword;

PROCEDURE BSymbol(args: Value; env: Env): Value;
VAR v: Value;
BEGIN
  v := args.head;
  IF v.tag = tSym THEN RETURN v END;
  IF (v.tag = tStr) OR (v.tag = tKey) THEN RETURN MkSym(v.s) END;
  Error("symbol: needs string or keyword"); RETURN NilV
END BSymbol;

PROCEDURE BInt(args: Value; env: Env): Value;
VAR v: Value; n: INTEGER; ok: BOOLEAN;
BEGIN
  v := args.head;
  IF v.tag = tInt THEN RETURN v END;
  IF v.tag = tReal THEN RETURN MkInt(Math.entier(v.r)) END;
  IF v.tag = tStr THEN
    ok := Strings.StrToInt(v.s, n);
    IF ok THEN RETURN MkInt(n) END
  END;
  Error("int: cannot convert"); RETURN NilV
END BInt;

PROCEDURE BFloat(args: Value; env: Env): Value;
VAR v: Value; x: REAL; ok: BOOLEAN;
BEGIN
  v := args.head;
  IF v.tag = tReal THEN RETURN v END;
  IF v.tag = tInt THEN RETURN MkReal(FLT(v.i)) END;
  IF v.tag = tStr THEN
    ok := Strings.StrToReal(v.s, x);
    IF ok THEN RETURN MkReal(x) END
  END;
  Error("float: cannot convert"); RETURN NilV
END BFloat;

PROCEDURE BChar(args: Value; env: Env): Value;
VAR v: Value; buf: ARRAY 2 OF CHAR;
BEGIN
  v := args.head;
  IF v.tag = tInt THEN
    buf[0] := CHR(v.i); buf[1] := 0X;
    RETURN MkStr(buf)
  END;
  Error("char: needs int"); RETURN NilV
END BChar;

PROCEDURE BCharCode(args: Value; env: Env): Value;
VAR v: Value;
BEGIN
  v := args.head;
  IF v.tag = tStr THEN RETURN MkInt(ORD(v.s[0])) END;
  Error("char-code: needs string"); RETURN NilV
END BCharCode;

PROCEDURE BMapIndexed(args: Value; env: Env): Value;
VAR fn, coll, first, last, cell, callArgs, result: Value; i: INTEGER;
BEGIN
  fn := args.head; coll := args.tail.head;
  first := NilV; last := NIL; i := 0;
  WHILE ~IsNil(coll) & ~err DO
    callArgs := Cons(MkInt(i), Cons(coll.head, NilV));
    result := Apply(fn, callArgs, env);
    IF err THEN RETURN NilV END;
    cell := Cons(result, NilV);
    IF last = NIL THEN first := cell ELSE last.tail := cell END;
    last := cell; coll := coll.tail; INC(i)
  END;
  RETURN first
END BMapIndexed;

PROCEDURE BGroupBy(args: Value; env: Env): Value;
VAR fn, coll, k, ks, vs, kp, vp, c, existing, newList: Value; found: BOOLEAN;
BEGIN
  fn := args.head; coll := args.tail.head;
  ks := NilV; vs := NilV;
  WHILE ~IsNil(coll) & ~err DO
    k := Apply(fn, Cons(coll.head, NilV), env);
    IF err THEN RETURN NilV END;
    kp := ks; vp := vs; found := FALSE;
    WHILE ~IsNil(kp) DO
      IF ValueEqual(kp.head, k) THEN
        vp.head := Cons(coll.head, vp.head); found := TRUE
      END;
      kp := kp.tail; vp := vp.tail
    END;
    IF ~found THEN
      ks := Cons(k, ks);
      vs := Cons(Cons(coll.head, NilV), vs)
    END;
    coll := coll.tail
  END;
  RETURN MkMap(ks, vs)
END BGroupBy;


PROCEDURE BAssocIn(args: Value; env: Env): Value;
VAR m, path, v, sub: Value;
BEGIN
  m := args.head; path := args.tail.head; v := args.tail.tail.head;
  IF IsNil(path) THEN RETURN v END;
  IF IsNil(path.tail) THEN
    RETURN BAssoc(Cons(m, Cons(path.head, Cons(v, NilV))), env)
  END;
  sub := BGet(Cons(m, Cons(path.head, NilV)), env);
  sub := BAssocIn(Cons(sub, Cons(path.tail, Cons(v, NilV))), env);
  RETURN BAssoc(Cons(m, Cons(path.head, Cons(sub, NilV))), env)
END BAssocIn;

PROCEDURE BGetIn(args: Value; env: Env): Value;
VAR m, path, notFound: Value;
BEGIN
  m := args.head; path := args.tail.head;
  IF ~IsNil(args.tail.tail) THEN notFound := args.tail.tail.head ELSE notFound := NilV END;
  WHILE ~IsNil(path) & ~IsNil(m) DO
    m := BGet(Cons(m, Cons(path.head, NilV)), env);
    path := path.tail
  END;
  IF IsNil(m) THEN RETURN notFound END;
  RETURN m
END BGetIn;

(* ---------- Oberon module integration ---------- *)

PROCEDURE AddOberonModule*(name: ARRAY OF CHAR; fn: ModuleRegFn);
BEGIN
  IF nModules < MaxModules THEN
    Strings.Copy(name, modNames[nModules]);
    modFns[nModules] := fn;
    INC(nModules)
  END
END AddOberonModule;

PROCEDURE RegisterBuiltin*(env: Env; name: ARRAY OF CHAR; fn: Builtin);
BEGIN Define(env, name, MkBuiltin(name, fn)) END RegisterBuiltin;

PROCEDURE BImportOberon(args: Value; env: Env): Value;
VAR nameV: Value; i: INTEGER; buf: ARRAY 256 OF CHAR;
BEGIN
  nameV := args.head;
  IF IsNil(nameV) OR (nameV.tag # tStr) THEN
    Error("import-oberon: needs a string module name"); RETURN NilV
  END;
  i := 0;
  WHILE i < nModules DO
    IF modNames[i] = nameV.s THEN
      modFns[i](GlobalEnv); RETURN NilV
    END;
    INC(i)
  END;
  Strings.Copy("import-oberon: module not registered: ", buf);
  Strings.Append(nameV.s, buf);
  Error(buf); RETURN NilV
END BImportOberon;

(* ---------- Regex operations ---------- *)

PROCEDURE BRePattern(args: Value; env: Env): Value;
VAR v, r: Value;
BEGIN
  v := args.head;
  IF v.tag = tRegex THEN RETURN v END;
  IF v.tag = tStr THEN
    NEW(r); r.tag := tRegex; Strings.Copy(v.s, r.s); RETURN r
  END;
  Error("re-pattern: needs string or regex"); RETURN NilV
END BRePattern;

PROCEDURE BReFind(args: Value; env: Env): Value;
VAR re, str, first, last, cell: Value;
    start, mlen, ng, i, gs: INTEGER;
    buf: ARRAY MaxStr OF CHAR;
BEGIN
  re := args.head; str := args.tail.head;
  IF (re.tag # tRegex) OR (str.tag # tStr) THEN
    Error("re-find: needs regex and string"); RETURN NilV
  END;
  start := Regex.FindAt(re.s, str.s, 0);
  IF start < 0 THEN RETURN NilV END;
  mlen := Regex.MatchLen();
  ng := Regex.NumGroups(re.s);
  IF ng = 0 THEN
    Strings.Extract(str.s, start, mlen, buf);
    RETURN MkStr(buf)
  ELSE
    first := NilV; last := NIL;
    Strings.Extract(str.s, start, mlen, buf);
    cell := MkVec(MkStr(buf), NilV); first := cell; last := cell;
    i := 1;
    WHILE i <= ng DO
      gs := Regex.GroupStart(i);
      IF gs >= 0 THEN
        Regex.GetGroup(i, buf); cell := MkVec(MkStr(buf), NilV)
      ELSE
        cell := MkVec(NilV, NilV)
      END;
      last.tail := cell; last := cell; INC(i)
    END;
    RETURN first
  END
END BReFind;

PROCEDURE BReMatches(args: Value; env: Env): Value;
VAR re, str, first, last, cell: Value;
    start, mlen, ng, i, gs, slen: INTEGER;
    buf: ARRAY MaxStr OF CHAR;
BEGIN
  re := args.head; str := args.tail.head;
  IF (re.tag # tRegex) OR (str.tag # tStr) THEN
    Error("re-matches: needs regex and string"); RETURN NilV
  END;
  slen := Strings.Length(str.s);
  start := Regex.FindAt(re.s, str.s, 0);
  IF (start # 0) OR (Regex.MatchLen() # slen) THEN RETURN NilV END;
  ng := Regex.NumGroups(re.s);
  IF ng = 0 THEN RETURN MkStr(str.s) END;
  first := NilV; last := NIL;
  cell := MkVec(MkStr(str.s), NilV); first := cell; last := cell;
  i := 1;
  WHILE i <= ng DO
    gs := Regex.GroupStart(i);
    IF gs >= 0 THEN
      Regex.GetGroup(i, buf); cell := MkVec(MkStr(buf), NilV)
    ELSE
      cell := MkVec(NilV, NilV)
    END;
    last.tail := cell; last := cell; INC(i)
  END;
  RETURN first
END BReMatches;

PROCEDURE BReSeq(args: Value; env: Env): Value;
VAR re, str, result, rlast, item, itemLast, cell: Value;
    start, mlen, ng, i, gs, pos, slen: INTEGER;
    buf: ARRAY MaxStr OF CHAR;
BEGIN
  re := args.head; str := args.tail.head;
  IF (re.tag # tRegex) OR (str.tag # tStr) THEN
    Error("re-seq: needs regex and string"); RETURN NilV
  END;
  ng := Regex.NumGroups(re.s);
  pos := 0; slen := Strings.Length(str.s);
  result := NilV; rlast := NIL;
  WHILE pos <= slen DO
    start := Regex.FindAt(re.s, str.s, pos);
    IF start < 0 THEN EXIT END;
    mlen := Regex.MatchLen();
    IF ng = 0 THEN
      Strings.Extract(str.s, start, mlen, buf);
      cell := Cons(MkStr(buf), NilV)
    ELSE
      item := NilV; itemLast := NIL;
      Strings.Extract(str.s, start, mlen, buf);
      cell := MkVec(MkStr(buf), NilV); item := cell; itemLast := cell;
      i := 1;
      WHILE i <= ng DO
        gs := Regex.GroupStart(i);
        IF gs >= 0 THEN
          Regex.GetGroup(i, buf); cell := MkVec(MkStr(buf), NilV)
        ELSE
          cell := MkVec(NilV, NilV)
        END;
        itemLast.tail := cell; itemLast := cell; INC(i)
      END;
      cell := Cons(item, NilV)
    END;
    IF rlast = NIL THEN result := cell ELSE rlast.tail := cell END;
    rlast := cell;
    IF mlen = 0 THEN INC(pos) ELSE pos := start + mlen END
  END;
  RETURN result
END BReSeq;

PROCEDURE BReReplace(args: Value; env: Env): Value;
VAR str, re, repl: Value;
    result: ARRAY MaxStr OF CHAR;
    pos, start, mlen, n, j: INTEGER;
BEGIN
  str := args.head; re := args.tail.head; repl := args.tail.tail.head;
  IF (str.tag # tStr) OR (re.tag # tRegex) OR (repl.tag # tStr) THEN
    Error("re-replace: needs string, regex, string"); RETURN NilV
  END;
  pos := 0; n := 0;
  LOOP
    start := Regex.FindAt(re.s, str.s, pos);
    IF start < 0 THEN
      j := pos;
      WHILE (str.s[j] # 0X) & (n < LEN(result)-1) DO
        result[n] := str.s[j]; INC(n); INC(j)
      END;
      EXIT
    END;
    mlen := Regex.MatchLen();
    j := pos;
    WHILE (j < start) & (n < LEN(result)-1) DO
      result[n] := str.s[j]; INC(n); INC(j)
    END;
    AppendCStr(result, n, repl.s);
    IF mlen = 0 THEN
      IF str.s[pos] # 0X THEN
        IF n < LEN(result)-1 THEN result[n] := str.s[pos]; INC(n) END;
        INC(pos)
      ELSE EXIT END
    ELSE pos := start + mlen END
  END;
  result[n] := 0X;
  RETURN MkStr(result)
END BReReplace;

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

PROCEDURE EvalStr*(s: ARRAY OF CHAR): Value;
VAR v: Value;
BEGIN
  v := ReadStr(s);
  IF err THEN RETURN NilV END;
  RETURN Eval(v, GlobalEnv)
END EvalStr;

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

PROCEDURE RegisterDoc(name: ARRAY OF CHAR; fn: Builtin; doc: ARRAY OF CHAR);
VAR v: Value;
BEGIN
  v := MkBuiltin(name, fn);
  Strings.Copy(doc, v.doc);
  Define(GlobalEnv, name, v)
END RegisterDoc;

PROCEDURE Eval1(s: ARRAY OF CHAR);
VAR expr: Value;
BEGIN
  expr := ReadStr(s);
  IF ~err THEN expr := Eval(expr, GlobalEnv) END;
  err := FALSE
END Eval1;

PROCEDURE Init*;
BEGIN
  NEW(NilV); NilV.tag := tNil;
  NEW(TrueV); TrueV.tag := tBool; TrueV.b := TRUE;
  NEW(FalseV); FalseV.tag := tBool; FalseV.b := FALSE;
  doRecur := FALSE; recurArgs := NIL; gensymCount := 0;
  isThrown := FALSE; thrownVal := NIL;

  EvalRef := Eval;
  GlobalEnv := NewEnv(NIL);

  (* Core arithmetic *)
  RegisterDoc("+", BAdd, "Returns the sum of nums. (+) returns 0.");
  RegisterDoc("-", BSub, "If one arg, negates. Otherwise subtracts the rest from first.");
  RegisterDoc("*", BMul, "Returns the product of nums. (*) returns 1.");
  RegisterDoc("/", BDiv, "Divides. (/ x) returns 1/x.");
  RegisterDoc("mod", BMod, "Modulus of num and div. Truncates toward negative infinity.");
  RegisterDoc("quot", BQuot, "Quotient of dividing num by div. Truncates toward zero.");
  RegisterDoc("rem", BRem, "Remainder of dividing num by div. Sign matches numerator.");
  RegisterDoc("inc", BInc, "Returns a number one greater than num.");
  RegisterDoc("dec", BDec, "Returns a number one less than num.");
  RegisterDoc("max", BMax, "Returns the greatest of its arguments.");
  RegisterDoc("min", BMin, "Returns the least of its arguments.");
  RegisterDoc("abs", BAbs, "Returns the absolute value of a.");
  RegisterDoc("even?", BEvenQ, "Returns true if n is even.");
  RegisterDoc("odd?", BOddQ, "Returns true if n is odd.");
  RegisterDoc("zero?", BZeroQ, "Returns true if num is zero.");
  RegisterDoc("pos?", BPosQ, "Returns true if num is greater than zero.");
  RegisterDoc("neg?", BNegQ, "Returns true if num is less than zero.");

  (* Comparison *)
  RegisterDoc("<", BLT, "Returns true if nums are in monotonically increasing order.");
  RegisterDoc(">", BGT, "Returns true if nums are in monotonically decreasing order.");
  RegisterDoc("<=", BLE, "Returns true if nums are in monotonically non-decreasing order.");
  RegisterDoc(">=", BGE, "Returns true if nums are in monotonically non-increasing order.");
  RegisterDoc("=", BEq, "Equality. Returns true if all args are equal.");
  RegisterDoc("not=", BEq, "Returns true if args are not all equal."); (* overridden below *)
  RegisterDoc("compare", BStrCompare, "Comparator. Returns neg, zero, or pos.");

  (* Math *)
  RegisterDoc("sqrt", BSqrt, "Returns the square root of num.");
  RegisterDoc("floor", BFloor, "Returns the floor of num.");
  RegisterDoc("ceil", BCeil, "Returns the ceiling of num.");
  RegisterDoc("round", BRound, "Rounds to nearest integer.");
  RegisterDoc("pow", BPow, "Returns base raised to exponent.");
  RegisterDoc("log", BLog, "Returns the natural logarithm of num.");
  RegisterDoc("exp", BExp, "Returns e raised to the power of num.");
  RegisterDoc("sin", BSin, "Returns the sine of angle in radians.");
  RegisterDoc("cos", BCos, "Returns the cosine of angle in radians.");
  RegisterDoc("tan", BTan, "Returns the tangent of angle in radians.");
  RegisterDoc("atan", BAtan, "Returns the arc tangent of x.");
  RegisterDoc("atan2", BAtan2, "Returns the angle theta from polar coordinates.");
  RegisterDoc("rand", BRand, "Returns a random float between 0 and 1.");
  RegisterDoc("rand-int", BRandInt, "Returns a random integer between 0 (inclusive) and n (exclusive).");

  (* Type predicates *)
  RegisterDoc("nil?", BNilQ, "Returns true if x is nil.");
  RegisterDoc("true?", BTrueQ, "Returns true if x is exactly true.");
  RegisterDoc("false?", BFalseQ, "Returns true if x is exactly false.");
  RegisterDoc("boolean?", BBooleanQ, "Returns true if x is a boolean.");
  RegisterDoc("number?", BNumberQ, "Returns true if x is a number.");
  RegisterDoc("integer?", BIntegerQ, "Returns true if x is an integer.");
  RegisterDoc("int?", BIntegerQ, "Returns true if x is an integer.");
  RegisterDoc("float?", BFloatQ, "Returns true if x is a floating-point number.");
  RegisterDoc("string?", BStringQ, "Returns true if x is a string.");
  RegisterDoc("keyword?", BKeywordQ, "Returns true if x is a keyword.");
  RegisterDoc("symbol?", BSymbolQ, "Returns true if x is a symbol.");
  RegisterDoc("fn?", BFnQ, "Returns true if x is a function.");
  RegisterDoc("coll?", BCollQ, "Returns true if x is a collection.");
  RegisterDoc("seq?", BSeqQ, "Returns true if x is a sequential collection.");
  RegisterDoc("list?", BListQ, "Returns true if x is a list.");
  RegisterDoc("vector?", BVectorQ, "Returns true if x is a vector.");
  RegisterDoc("map?", BMapQ, "Returns true if x is a map.");
  RegisterDoc("empty?", BEmptyQ, "Returns true if coll has no items.");
  RegisterDoc("not", BNot, "Returns true if x is logical false.");

  (* Sequence constructors *)
  RegisterDoc("list", BList, "Creates a list with supplied items.");
  RegisterDoc("vector", BVector, "Creates a vector with supplied items.");
  RegisterDoc("vec", BVector, "Creates a vector from a collection.");
  RegisterDoc("hash-map", BHashMap, "Creates a hash map with supplied key/value pairs.");
  RegisterDoc("seq", BSeq, "Returns a seq on the collection. Returns nil if empty.");

  (* Sequence operations *)
  RegisterDoc("cons", BCons, "Returns a new seq where x is the first item and seq is the rest.");
  RegisterDoc("first", BFirst, "Returns the first item in a collection.");
  RegisterDoc("second", BSecond, "Returns the second item in a collection.");
  RegisterDoc("last", BLast, "Returns the last item in a collection.");
  RegisterDoc("rest", BRest, "Returns items after the first. Returns nil if empty.");
  RegisterDoc("next", BNext, "Returns items after first, or nil if only one.");
  RegisterDoc("butlast", BButlast, "Returns all but the last item in coll.");
  RegisterDoc("count", BCount, "Returns the number of items in the collection.");
  RegisterDoc("nth", BNth, "Returns the value at index. 0-indexed.");
  RegisterDoc("get", BGet, "Returns value mapped to key, or not-found if absent.");
  RegisterDoc("conj", BConj, "Conjoins item onto collection.");
  RegisterDoc("concat", BConcat, "Returns lazy seq of concatenation of colls.");
  RegisterDoc("reverse", BReverse, "Returns seq of items in reversed order.");
  RegisterDoc("flatten", BFlatten, "Takes nested collections and returns flat seq.");
  RegisterDoc("distinct", BDistinct, "Returns seq with duplicates removed.");
  RegisterDoc("sort", BSort, "Returns sorted sequence of items.");
  RegisterDoc("sort-by", BSortBy, "Returns sorted sequence of items, using keyfn.");
  RegisterDoc("shuffle", BShuffle, "Returns a random permutation of coll.");
  RegisterDoc("take", BTake, "Returns the first n items in coll.");
  RegisterDoc("drop", BDrop, "Returns all but the first n items in coll.");
  RegisterDoc("take-while", BTakeWhile, "Returns items while pred returns logical true.");
  RegisterDoc("drop-while", BDropWhile, "Drops items while pred returns logical true.");
  RegisterDoc("into", BInto, "Returns coll with all items of from conjoined.");
  RegisterDoc("map", BMap, "Returns a list of applying f to each item in coll.");
  RegisterDoc("map-indexed", BMapIndexed, "Returns map(fn [idx item]) over indexed collection.");
  RegisterDoc("mapcat", BMapcat, "Applies f to each value of coll, concatenates results.");
  RegisterDoc("filter", BFilter, "Returns items of coll for which pred is true.");
  RegisterDoc("remove", BRemove, "Returns items of coll for which pred is false.");
  RegisterDoc("keep", BKeep, "Returns non-nil results of applying f to items in coll.");
  RegisterDoc("reduce", BReduce, "Reduces coll using f. Optional initial value.");
  RegisterDoc("every?", BEveryQ, "Returns true if pred is true for all items in coll.");
  RegisterDoc("some", BSome, "Returns first true value of pred applied to items.");
  RegisterDoc("not-any?", BNotAnyQ, "Returns true if pred is false for all items in coll.");
  RegisterDoc("not-every?", BNotEveryQ, "Returns true if pred is false for some item.");
  RegisterDoc("partition", BPartition, "Returns list of lists of n items each.");
  RegisterDoc("interpose", BInterpose, "Returns seq with sep between each item in coll.");
  RegisterDoc("frequencies", BFrequencies, "Returns map of item to frequency count.");
  RegisterDoc("group-by", BGroupBy, "Returns map of keyfn(item) to list of items.");
  RegisterDoc("zipmap", BZipmap, "Returns map with keys and corresponding vals.");
  RegisterDoc("range", BRange, "Returns lazy seq of integers from start to end.");

  (* Map operations *)
  RegisterDoc("assoc", BAssoc, "Returns map with key associated to val.");
  RegisterDoc("assoc-in", BAssocIn, "Associates a value in a nested map at path.");
  RegisterDoc("dissoc", BDissoc, "Returns map without key.");
  RegisterDoc("merge", BMerge, "Returns map that is the merge of maps. Right wins.");
  RegisterDoc("keys", BKeys, "Returns a sequence of the map's keys.");
  RegisterDoc("vals", BVals, "Returns a sequence of the map's values.");
  RegisterDoc("contains?", BContainsQ, "Returns true if key is present in coll.");
  RegisterDoc("get-in", BGetIn, "Returns value in nested map via sequence of keys.");
  RegisterDoc("select-keys", BSelectKeys, "Returns map with only the selected keys.");
  RegisterDoc("update", BUpdate, "Updates a key in map by applying fn to its old value.");

  (* Set operations *)
  RegisterDoc("hash-set", BHashSet, "Returns a set with supplied items.");
  RegisterDoc("sorted-set", BSortedSet, "Returns a sorted set with supplied items.");
  RegisterDoc("sorted-set?", BSortedSetQ, "Returns true if x is a sorted set.");
  RegisterDoc("set", BSetFn, "Returns a set of the distinct elements of coll.");
  RegisterDoc("set?", BSetQ, "Returns true if x is a set.");
  RegisterDoc("disj", BDisj, "Returns a set with items removed.");
  RegisterDoc("union", BUnion, "Returns the union of the sets.");
  RegisterDoc("intersection", BIntersection, "Returns the intersection of the sets.");
  RegisterDoc("difference", BDifference, "Returns the set of elements in s1 not in s2.");
  RegisterDoc("subset?", BSubsetQ, "Returns true if s1 is a subset of s2.");
  RegisterDoc("superset?", BSupersetQ, "Returns true if s1 is a superset of s2.");

  (* String operations *)
  RegisterDoc("str", BStr, "Converts args to strings and concatenates them.");
  RegisterDoc("subs", BSubs, "Returns substring from start to end (exclusive).");
  RegisterDoc("split", BSplit, "Splits string on delimiter char.");
  RegisterDoc("join", BJoin, "Joins collection with separator.");
  RegisterDoc("upper-case", BUpperCase, "Converts string to upper case.");
  RegisterDoc("lower-case", BLowerCase, "Converts string to lower case.");
  RegisterDoc("trim", BTrim, "Removes whitespace from both ends of string.");
  RegisterDoc("starts-with?", BStartsWithQ, "True if s starts with prefix.");
  RegisterDoc("ends-with?", BEndsWithQ, "True if s ends with suffix.");
  RegisterDoc("includes?", BIncludesQ, "True if s includes substr.");
  RegisterDoc("string-length", BStrlen, "Returns the length of string s.");
  RegisterDoc("string/blank?", BStrBlankQ, "True if s is nil, empty, or whitespace only.");
  RegisterDoc("string/capitalize", BStrCapitalize, "First char upper-case, rest lower-case.");
  RegisterDoc("string/reverse", BStrReverse, "Returns s with chars in reverse order.");
  RegisterDoc("string/triml", BStrTrimL, "Removes whitespace from left end of s.");
  RegisterDoc("string/trimr", BStrTrimR, "Removes whitespace from right end of s.");
  RegisterDoc("string/trim-newline", BStrTrimNewline, "Removes trailing newline characters from s.");
  RegisterDoc("string/split-lines", BStrSplitLines, "Splits s on newlines, returns list of lines.");
  RegisterDoc("string/index-of", BStrIndexOf, "Index of first occurrence of value in s, or nil.");
  RegisterDoc("string/last-index-of", BStrLastIndexOf, "Index of last occurrence of value in s, or nil.");
  RegisterDoc("string/replace", BStrReplace, "Replaces all occurrences of match (string or regex) in s.");
  RegisterDoc("string/replace-first", BStrReplaceFirst, "Replaces first occurrence of match in s.");

  (* Regex *)
  RegisterDoc("re-pattern", BRePattern, "Returns a regex for the given string.");
  RegisterDoc("re-find", BReFind, "Returns first regex match in s, or nil. With groups, returns vector.");
  RegisterDoc("re-matches", BReMatches, "Returns match only if regex matches entire string.");
  RegisterDoc("re-seq", BReSeq, "Returns lazy seq of successive matches of pattern in string.");
  RegisterDoc("re-replace", BReReplace, "Replaces all regex matches in string with replacement.");

  (* Conversion *)
  RegisterDoc("int", BInt, "Converts to integer.");
  RegisterDoc("float", BFloat, "Converts to floating-point.");
  RegisterDoc("char", BChar, "Returns single-char string for integer codepoint.");
  RegisterDoc("char-code", BCharCode, "Returns integer codepoint of first char.");
  RegisterDoc("name", BName, "Returns string name of keyword, symbol, or string.");
  RegisterDoc("keyword", BKeyword, "Returns keyword from string or symbol.");
  RegisterDoc("symbol", BSymbol, "Returns symbol from string or keyword.");
  RegisterDoc("type", BType, "Returns keyword describing the type of x.");

  (* I/O *)
  RegisterDoc("prn", BPrn, "Prints args, separated by spaces, with newline (readable).");
  RegisterDoc("pr", BPr, "Prints args, separated by spaces (readable).");
  RegisterDoc("println", BPrintln, "Prints args, separated by spaces, with newline.");
  RegisterDoc("print", BPrint, "Prints args, separated by spaces, without newline.");
  RegisterDoc("newline", BNewline, "Prints a newline.");
  RegisterDoc("flush", BFlush, "Flushes output (no-op).");
  RegisterDoc("pr-str", BPrintStr, "Returns string of printed representation.");
  RegisterDoc("print-str", BPrintStr, "Returns string of printed representation.");
  RegisterDoc("read-string", BReadString, "Reads one object from a string.");

  (* Functional *)
  RegisterDoc("identity", BIdentity, "Returns its argument.");
  RegisterDoc("apply", BApplyFn, "Applies fn to args, with last arg as a seq.");
  RegisterDoc("gensym", BGensym, "Returns a unique symbol.");
  RegisterDoc("load-file", BLoadFile, "Loads Clojure source from a file.");
  RegisterDoc("import-oberon", BImportOberon, "Import a registered Oberon module into the Cloj environment.");

  (* Atoms and concurrency *)
  RegisterDoc("atom", BAtom, "Creates an atom with initial value.");
  RegisterDoc("atom?", BAtomQ, "Returns true if x is an atom.");
  RegisterDoc("deref", BDeref, "Returns the current value of an atom or forces a delay.");
  RegisterDoc("reset!", BResetBang, "Sets the value of atom to newval without applying a fn.");
  RegisterDoc("swap!", BSwapBang, "Atomically swaps value of atom to (f current-val & args).");
  RegisterDoc("force", BForce, "Forces a delay. If not a delay, returns the value.");
  RegisterDoc("promise", BPromise, "Returns a promise object that can be set once with deliver.");
  RegisterDoc("deliver", BDeliver, "Delivers the supplied value to the promise.");
  RegisterDoc("future?", BFutureQ, "Returns true if x is a future.");
  RegisterDoc("future-done?", BFutureDoneQ, "Returns true if future f has a value (always true here).");
  RegisterDoc("satisfies?", BSatisfiesQ, "Returns true if x satisfies the protocol.");
  RegisterDoc("instance?", BInstanceQ, "Returns true if x is an instance of the named record type.");
  RegisterDoc("throw", BThrow, "Throws an exception (builtin form; prefer (throw x) special form).");

  (* Single-threaded STM stubs *)
  Eval1("(def ref atom)");
  Eval1("(defn alter [r f & args] (apply swap! r f args))");
  Eval1("(defn commute [r f & args] (apply swap! r f args))");
  Eval1("(defn ref-set [r v] (reset! r v))");

  (* Define PI and E as constants *)
  Define(GlobalEnv, "PI", MkReal(Math.pi));
  Define(GlobalEnv, "E", MkReal(Math.e));

  (* Fix not= *)
  Eval1("(defn not= [& args] (not (apply = args)))");

  (* Higher-order functions as Clojure *)
  Eval1("(defn constantly [x] (fn [& _] x))");
  Eval1("(defn complement [f] (fn [& args] (not (apply f args))))");
  Eval1("(defn comp [& fns] (fn [& args] (reduce (fn [v f] (f v)) (apply (last fns) args) (butlast fns))))");
  Eval1("(defn partial [f & pargs] (fn [& args] (apply f (concat pargs args))))");
  Eval1("(defn juxt [& fns] (fn [& args] (map (fn [f] (apply f args)) fns)))");
  Eval1("(defn max-key [f & xs] (reduce (fn [a b] (if (> (f a) (f b)) a b)) xs))");
  Eval1("(defn min-key [f & xs] (reduce (fn [a b] (if (< (f a) (f b)) a b)) xs))");

  (* Convenience aliases and standard predicates *)
  Eval1("(defn pos-int? [x] (and (integer? x) (pos? x)))");
  Eval1("(defn neg-int? [x] (and (integer? x) (neg? x)))");
  Eval1("(defn nat-int? [x] (and (integer? x) (not (neg? x))))");
  Eval1("(defn string/split [s re] (split s re))");
  Eval1('(defn string/join ([sep coll] (join sep coll)) ([coll] (join "" coll)))');
  Eval1("(defn string/upper-case [s] (upper-case s))");
  Eval1("(defn string/lower-case [s] (lower-case s))");
  Eval1("(defn string/trim [s] (trim s))");
  Eval1("(defn string/starts-with? [s prefix] (starts-with? s prefix))");
  Eval1("(defn string/ends-with? [s suffix] (ends-with? s suffix))");
  Eval1("(defn string/includes? [s sub] (includes? s sub))");
  Eval1("(defn update-in [m path f & args] (assoc-in m path (apply f (get-in m path) args)))");
  Eval1("(defn merge-with [f & maps] (reduce (fn [acc m] (reduce (fn [a [k v]] (assoc a k (if (contains? a k) (f (get a k) v) v))) acc (map (fn [k] [k (get m k)]) (keys m)))) {} maps))");
  Eval1("(defn take-last [n coll] (drop (- (count coll) n) coll))");
  Eval1("(defn drop-last [n coll] (take (- (count coll) n) coll))");
  Eval1("(defn split-at [n coll] [(take n coll) (drop n coll)])");
  Eval1("(defn split-with [f coll] [(take-while f coll) (drop-while f coll)])");
  Eval1("(defn interleave [& colls] (loop [cs colls acc []] (if (some empty? cs) (seq acc) (recur (map rest cs) (into acc (map first cs))))))");
  Eval1("(defn repeat [n x] (map (fn [_] x) (range n)))");
  Eval1("(defn repeatedly [n f] (map (fn [_] (f)) (range n)))");
  Eval1("(defn iterate [f x] (loop [cur x acc [] n 0] (if (>= n 1000) acc (recur (f cur) (conj acc cur) (+ n 1)))))");
  Eval1("(defn cycle [coll] (loop [c coll acc [] n 0] (if (>= n 1000) (seq acc) (if (empty? c) (recur coll acc n) (recur (rest c) (conj acc (first c)) (+ n 1))))))");
  Eval1("(defn flatten-1 [coll] (apply concat coll))");
  Eval1("(defn indexed [coll] (map list (range (count coll)) coll))");
  Eval1("(defn any? [pred coll] (not (nil? (some pred coll))))");
  Eval1("(defn every-pred [& preds] (fn [x] (every? (fn [p] (p x)) preds)))");
  Eval1("(defn some-fn [& preds] (fn [x] (some (fn [p] (p x)) preds)))");
  Eval1("(defn fnil [f default] (fn [x & args] (apply f (if (nil? x) default x) args)))");
  Eval1("(defn nil-safe [f default] (fn [x] (if (nil? x) default (f x))))");
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
VAR i, scriptIdx: INTEGER; arg: ARRAY 256 OF CHAR;
  interactive, ok: BOOLEAN;
  argsV, argsLast, cell: Value;
BEGIN
  Init;
  interactive := FALSE; scriptIdx := 0;
  i := 1;
  WHILE i <= Args.Count() DO
    Args.Get(i, arg);
    IF (arg[0] = '-') & (arg[1] = 'i') & (arg[2] = 0X) THEN
      interactive := TRUE
    ELSIF (arg[0] = '-') & (arg[1] = 'h') & (arg[2] = 0X) THEN
      Out.String("usage: cloj [-i] [script.clj [args...]]"); Out.Ln;
      Out.String("  -i        drop into REPL after running script"); Out.Ln;
      Out.String("  no args   start REPL"); Out.Ln;
      Out.String("  *args*    bound to the args after the script name"); Out.Ln;
      RETURN
    ELSIF scriptIdx = 0 THEN
      scriptIdx := i
    END;
    INC(i)
  END;
  (* Bind *args* to arguments after the script file *)
  argsV := NilV; argsLast := NIL;
  IF scriptIdx > 0 THEN
    i := scriptIdx + 1;
    WHILE i <= Args.Count() DO
      Args.Get(i, arg);
      cell := Cons(MkStr(arg), NilV);
      IF argsLast = NIL THEN argsV := cell ELSE argsLast.tail := cell END;
      argsLast := cell; INC(i)
    END
  END;
  Define(GlobalEnv, "*args*", argsV);
  IF scriptIdx > 0 THEN
    Args.Get(scriptIdx, arg);
    ok := LoadFile(arg, FALSE);
    IF ok & interactive THEN REPL() END
  ELSE
    REPL()
  END
END Main;

BEGIN
  nModules := 0;
  Init
END Cloj.
