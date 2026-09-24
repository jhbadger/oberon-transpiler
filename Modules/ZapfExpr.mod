MODULE ZapfExpr;
(* ZapfExpr — AsmExpr AST ported from Zapf.Parsing.Expressions (C#). *)

IMPORT Strings;

CONST
  KindNum* = 0;
  KindStr* = 1;
  KindSym* = 2;
  KindQuote* = 3;
  KindAdd* = 4;

TYPE
  Expr* = POINTER TO ExprDesc;
  ExprDesc* = RECORD
    kind*: INTEGER;
    text*: ARRAY 1024 OF CHAR;  (* Num: literal source text; Str: string content; Sym: name *)
    numVal*: INTEGER;          (* valid when kind = KindNum *)
    inner*: Expr;              (* valid when kind = KindQuote *)
    left*, right*: Expr        (* valid when kind = KindAdd *)
  END;

PROCEDURE NewNumVal*(v: INTEGER): Expr;
VAR e: Expr; s: ARRAY 16 OF CHAR;
BEGIN
  NEW(e);
  e.kind := KindNum;
  e.numVal := v;
  Strings.IntToStr(v, s);
  Strings.Copy(s, e.text);
  RETURN e
END NewNumVal;

PROCEDURE NewNumText*(t: ARRAY OF CHAR): Expr;
VAR e: Expr; v: INTEGER; ok: BOOLEAN;
BEGIN
  NEW(e);
  e.kind := KindNum;
  Strings.Copy(t, e.text);
  ok := Strings.StrToInt(t, v);
  IF ~ok THEN v := 0 END;
  e.numVal := v;
  RETURN e
END NewNumText;

PROCEDURE NewStr*(t: ARRAY OF CHAR): Expr;
VAR e: Expr;
BEGIN
  NEW(e);
  e.kind := KindStr;
  Strings.Copy(t, e.text);
  RETURN e
END NewStr;

PROCEDURE NewSym*(t: ARRAY OF CHAR): Expr;
VAR e: Expr;
BEGIN
  NEW(e);
  e.kind := KindSym;
  Strings.Copy(t, e.text);
  RETURN e
END NewSym;

PROCEDURE NewQuote*(inner: Expr): Expr;
VAR e: Expr;
BEGIN
  NEW(e);
  e.kind := KindQuote;
  e.inner := inner;
  RETURN e
END NewQuote;

PROCEDURE NewAdd*(l, r: Expr): Expr;
VAR e: Expr;
BEGIN
  NEW(e);
  e.kind := KindAdd;
  e.left := l;
  e.right := r;
  RETURN e
END NewAdd;

PROCEDURE ToString*(e: Expr; VAR s: ARRAY OF CHAR);
VAR tmp: ARRAY 1024 OF CHAR;
BEGIN
  IF e = NIL THEN
    s[0] := 0X;
    RETURN
  END;
  CASE e.kind OF
    KindNum: Strings.Copy(e.text, s)
   |KindStr: Strings.Copy(e.text, s)
   |KindSym: Strings.Copy(e.text, s)
   |KindQuote:
      Strings.Copy("'", s);
      ToString(e.inner, tmp);
      Strings.Append(tmp, s)
   |KindAdd:
      ToString(e.left, s);
      Strings.Append("+", s);
      ToString(e.right, tmp);
      Strings.Append(tmp, s)
  ELSE
    Strings.Copy("?", s)
  END
END ToString;

END ZapfExpr.
