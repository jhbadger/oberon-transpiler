MODULE ZapfParser;
(*
  ZapfParser — ported from Zapf.Parsing.ZapParser (C#).

  Turns one ZAP source file into a ZapfAst.LineList. Errors are reported and
  recorded (errorCount) but parsing keeps going, skipping to a recovery point
  (end of line, or end of expression) exactly as the original does via
  SkipLine/SkipExpr. A raw lexical error (bad character, unterminated
  string) is unrecoverable for the *whole file*, matching the original where
  such an error is a thrown SeriousError that unwinds out of Parse() with no
  per-line catch: on that condition `Parse` sets fatal/fatalMsg and returns
  whatever it collected is discarded by the caller.
*)

IMPORT ZapfTok, ZapfExpr, ZapfAst, ZapfOpcodes, Strings, Out;

TYPE
  Parser* = RECORD
    tok: ZapfTok.Tokenizer;
    informMode*: BOOLEAN;
    effVersion*: INTEGER;     (* current opcode-selection version; updated by .NEW *)
    errorCount*: INTEGER;
    fatal*: BOOLEAN;
    fatalMsg*: ARRAY 256 OF CHAR;
    fatalFile*: ARRAY 256 OF CHAR;
    fatalLine*: INTEGER
  END;

PROCEDURE InitParser*(VAR p: Parser; informMode: BOOLEAN; startVersion: INTEGER);
BEGIN
  p.informMode := informMode;
  p.effVersion := startVersion;
  p.errorCount := 0;
  p.fatal := FALSE
END InitParser;

(* ---------------------------------------------------------------- *)
(* token access wrappers - check for lexer fatal errors uniformly    *)
(* ---------------------------------------------------------------- *)

PROCEDURE CheckLex(VAR p: Parser);
BEGIN
  IF p.tok.err & ~p.fatal THEN
    p.fatal := TRUE;
    Strings.Copy(p.tok.errMsg, p.fatalMsg);
    p.fatalLine := p.tok.errLine
  END
END CheckLex;

PROCEDURE NT(VAR p: Parser; VAR t: ZapfTok.Token);
BEGIN
  ZapfTok.NextToken(p.tok, t);
  CheckLex(p)
END NT;

PROCEDURE PT(VAR p: Parser; VAR t: ZapfTok.Token);
BEGIN
  ZapfTok.PeekToken(p.tok, t);
  CheckLex(p)
END PT;

(* ---------------------------------------------------------------- *)
(* error reporting / recovery                                        *)
(* ---------------------------------------------------------------- *)

PROCEDURE ReportErr(VAR p: Parser; t: ZapfTok.Token; msg: ARRAY OF CHAR);
BEGIN
  INC(p.errorCount);
  Out.String(t.filename); Out.String(":"); Out.Int(t.line, 0); Out.String(": error: ");
  Out.String(msg); Out.Ln
END ReportErr;

PROCEDURE SkipLine(VAR p: Parser);
VAR t: ZapfTok.Token; done: BOOLEAN;
BEGIN
  done := FALSE;
  WHILE ~done & ~p.fatal DO
    PT(p, t);
    IF t.kind = ZapfTok.TkEndOfFile THEN
      done := TRUE
    ELSIF t.kind = ZapfTok.TkEndOfLine THEN
      NT(p, t); done := TRUE
    ELSE
      NT(p, t)
    END
  END
END SkipLine;

PROCEDURE SkipExpr(VAR p: Parser);
VAR t: ZapfTok.Token; done: BOOLEAN;
BEGIN
  done := FALSE;
  WHILE ~done & ~p.fatal DO
    PT(p, t);
    CASE t.kind OF
      ZapfTok.TkEndOfFile, ZapfTok.TkSlash, ZapfTok.TkBackslash, ZapfTok.TkRAngle:
        done := TRUE
     |ZapfTok.TkEndOfLine, ZapfTok.TkComma:
        NT(p, t); done := TRUE
    ELSE
      NT(p, t)
    END
  END
END SkipExpr;

PROCEDURE ErrSkipLine(VAR p: Parser; t: ZapfTok.Token; msg: ARRAY OF CHAR);
BEGIN ReportErr(p, t, msg); SkipLine(p) END ErrSkipLine;

PROCEDURE ErrSkipExpr(VAR p: Parser; t: ZapfTok.Token; msg: ARRAY OF CHAR);
BEGIN ReportErr(p, t, msg); SkipExpr(p) END ErrSkipExpr;

(* ---------------------------------------------------------------- *)
(* expressions                                                       *)
(* ---------------------------------------------------------------- *)

PROCEDURE CanStartExpr(kind: INTEGER): BOOLEAN;
BEGIN
  RETURN (kind = ZapfTok.TkSymbol) OR (kind = ZapfTok.TkNumber)
       OR (kind = ZapfTok.TkString) OR (kind = ZapfTok.TkApostrophe)
END CanStartExpr;

PROCEDURE ParseExprOne(VAR p: Parser; head: ZapfTok.Token): ZapfExpr.Expr;
VAR inner: ZapfTok.Token; e: ZapfExpr.Expr;
BEGIN
  CASE head.kind OF
    ZapfTok.TkSymbol: RETURN ZapfExpr.NewSym(head.text)
   |ZapfTok.TkNumber: RETURN ZapfExpr.NewNumText(head.text)
   |ZapfTok.TkString: RETURN ZapfExpr.NewStr(head.text)
   |ZapfTok.TkApostrophe:
      NT(p, inner);
      e := ParseExprOne(p, inner);
      RETURN ZapfExpr.NewQuote(e)
  ELSE
    ErrSkipExpr(p, head, "unexpected expr token");
    RETURN ZapfExpr.NewNumVal(0)
  END
END ParseExprOne;

PROCEDURE ParseExpr(VAR p: Parser; head: ZapfTok.Token): ZapfExpr.Expr;
VAR result, right: ZapfExpr.Expr; pk, plus, rhead: ZapfTok.Token; more: BOOLEAN;
BEGIN
  result := ParseExprOne(p, head);
  more := TRUE;
  WHILE more & ~p.fatal DO
    PT(p, pk);
    IF pk.kind = ZapfTok.TkPlus THEN
      NT(p, plus);
      NT(p, rhead);
      right := ParseExprOne(p, rhead);
      result := ZapfExpr.NewAdd(result, right)
    ELSE
      more := FALSE
    END
  END;
  RETURN result
END ParseExpr;

PROCEDURE ParseExprNH(VAR p: Parser): ZapfExpr.Expr;
VAR h: ZapfTok.Token;
BEGIN
  NT(p, h);
  RETURN ParseExpr(p, h)
END ParseExprNH;

PROCEDURE TryParseExpr(VAR p: Parser; VAR e: ZapfExpr.Expr): BOOLEAN;
VAR pk: ZapfTok.Token;
BEGIN
  PT(p, pk);
  IF CanStartExpr(pk.kind) THEN
    e := ParseExprNH(p);
    RETURN TRUE
  ELSE
    e := NIL;
    RETURN FALSE
  END
END TryParseExpr;

(* ---------------------------------------------------------------- *)
(* token matching helpers                                            *)
(* ---------------------------------------------------------------- *)

PROCEDURE MatchEndOfDirective(VAR p: Parser);
VAR pk, t: ZapfTok.Token;
BEGIN
  PT(p, pk);
  IF pk.kind = ZapfTok.TkEndOfLine THEN
    NT(p, t)
  ELSIF pk.kind = ZapfTok.TkEndOfFile THEN
    (* leave it *)
  ELSE
    ErrSkipLine(p, pk, "expected EOL after directive")
  END
END MatchEndOfDirective;

PROCEDURE TryMatchComma(VAR p: Parser): BOOLEAN;
VAR pk, t: ZapfTok.Token;
BEGIN
  PT(p, pk);
  IF pk.kind = ZapfTok.TkComma THEN NT(p, t); RETURN TRUE ELSE RETURN FALSE END
END TryMatchComma;

PROCEDURE MatchComma(VAR p: Parser);
VAR pk: ZapfTok.Token;
BEGIN
  IF ~TryMatchComma(p) THEN PT(p, pk); ErrSkipExpr(p, pk, "expected ','") END
END MatchComma;

PROCEDURE TryMatchColon(VAR p: Parser): BOOLEAN;
VAR pk, t: ZapfTok.Token;
BEGIN
  PT(p, pk);
  IF pk.kind = ZapfTok.TkColon THEN NT(p, t); RETURN TRUE ELSE RETURN FALSE END
END TryMatchColon;

PROCEDURE MatchColon(VAR p: Parser);
VAR pk: ZapfTok.Token;
BEGIN
  IF ~TryMatchColon(p) THEN PT(p, pk); ErrSkipExpr(p, pk, "expected ':'") END
END MatchColon;

PROCEDURE TryMatchEquals(VAR p: Parser): BOOLEAN;
VAR pk, t: ZapfTok.Token;
BEGIN
  PT(p, pk);
  IF pk.kind = ZapfTok.TkEquals THEN NT(p, t); RETURN TRUE ELSE RETURN FALSE END
END TryMatchEquals;

PROCEDURE MatchSymbol(VAR p: Parser; VAR s: ARRAY OF CHAR);
VAR pk, t: ZapfTok.Token;
BEGIN
  PT(p, pk);
  IF pk.kind = ZapfTok.TkSymbol THEN
    NT(p, t); Strings.Copy(t.text, s)
  ELSE
    ErrSkipExpr(p, pk, "expected symbol"); Strings.Copy("???", s)
  END
END MatchSymbol;

PROCEDURE MatchString(VAR p: Parser; VAR s: ARRAY OF CHAR);
VAR pk, t: ZapfTok.Token;
BEGIN
  PT(p, pk);
  IF pk.kind = ZapfTok.TkString THEN
    NT(p, t); Strings.Copy(t.text, s)
  ELSE
    ErrSkipExpr(p, pk, "expected string"); Strings.Copy("???", s)
  END
END MatchString;

PROCEDURE MaybeSkipTypeFlag(VAR p: Parser);
VAR dummy: ARRAY 80 OF CHAR;
BEGIN
  IF TryMatchComma(p) THEN MatchSymbol(p, dummy) END
END MaybeSkipTypeFlag;

(* ---------------------------------------------------------------- *)
(* per-directive grammars                                            *)
(* ---------------------------------------------------------------- *)

PROCEDURE PAlign(VAR p: Parser): ZapfAst.Line;
VAR l: ZapfAst.Line;
BEGIN
  l := ZapfAst.NewLine(ZapfAst.LkAlign);
  l.exprA := ParseExprNH(p);
  MatchEndOfDirective(p);
  RETURN l
END PAlign;

PROCEDURE PByteOrWord(VAR p: Parser; kind: INTEGER): ZapfAst.Line;
VAR l: ZapfAst.Line;
BEGIN
  l := ZapfAst.NewLine(kind);
  ZapfAst.AddExpr(l.exprList, ParseExprNH(p));
  WHILE TryMatchComma(p) DO ZapfAst.AddExpr(l.exprList, ParseExprNH(p)) END;
  MatchEndOfDirective(p);
  RETURN l
END PByteOrWord;

PROCEDURE PChrset(VAR p: Parser): ZapfAst.Line;
VAR l: ZapfAst.Line;
BEGIN
  l := ZapfAst.NewLine(ZapfAst.LkChrset);
  l.exprA := ParseExprNH(p);
  WHILE TryMatchComma(p) DO ZapfAst.AddExpr(l.exprList, ParseExprNH(p)) END;
  MatchEndOfDirective(p);
  RETURN l
END PChrset;

PROCEDURE PTextOnly(VAR p: Parser; kind: INTEGER): ZapfAst.Line;
VAR l: ZapfAst.Line;
BEGIN
  l := ZapfAst.NewLine(kind);
  MatchString(p, l.text);
  MatchEndOfDirective(p);
  RETURN l
END PTextOnly;

PROCEDURE PNoArgs(kind: INTEGER; VAR p: Parser): ZapfAst.Line;
VAR l: ZapfAst.Line;
BEGIN
  l := ZapfAst.NewLine(kind);
  MatchEndOfDirective(p);
  RETURN l
END PNoArgs;

PROCEDURE PFstrOrGstr(VAR p: Parser; kind: INTEGER): ZapfAst.Line;
VAR l: ZapfAst.Line;
BEGIN
  l := ZapfAst.NewLine(kind);
  MatchSymbol(p, l.name);
  MatchComma(p);
  MatchString(p, l.text);
  MatchEndOfDirective(p);
  RETURN l
END PFstrOrGstr;

PROCEDURE PFunct(VAR p: Parser): ZapfAst.Line;
VAR l: ZapfAst.Line; junk: ARRAY 80 OF CHAR; discard: ZapfExpr.Expr;
    localName: ARRAY 80 OF CHAR; localDefault: ZapfExpr.Expr;
BEGIN
  l := ZapfAst.NewLine(ZapfAst.LkFunct);
  MatchSymbol(p, l.name);
  IF TryMatchColon(p) THEN
    MatchSymbol(p, junk);
    MatchColon(p);
    discard := ParseExprNH(p);
    MatchColon(p);
    discard := ParseExprNH(p)
  END;
  WHILE TryMatchComma(p) DO
    MatchSymbol(p, localName);
    IF TryMatchEquals(p) THEN localDefault := ParseExprNH(p) ELSE localDefault := NIL END;
    ZapfAst.AddLocal(l, localName, localDefault)
  END;
  MatchEndOfDirective(p);
  RETURN l
END PFunct;

PROCEDURE PGvar(VAR p: Parser): ZapfAst.Line;
VAR l: ZapfAst.Line; junk: ARRAY 80 OF CHAR;
BEGIN
  l := ZapfAst.NewLine(ZapfAst.LkGvar);
  MatchSymbol(p, l.name);
  IF TryMatchEquals(p) THEN
    l.exprA := ParseExprNH(p);
    IF TryMatchComma(p) THEN MatchSymbol(p, junk) END
  ELSE
    l.exprA := NIL
  END;
  MatchEndOfDirective(p);
  RETURN l
END PGvar;

PROCEDURE PLang(VAR p: Parser): ZapfAst.Line;
VAR l: ZapfAst.Line;
BEGIN
  l := ZapfAst.NewLine(ZapfAst.LkLang);
  l.exprA := ParseExprNH(p);
  MatchComma(p);
  l.exprB := ParseExprNH(p);
  MatchEndOfDirective(p);
  RETURN l
END PLang;

PROCEDURE PForm(VAR p: Parser): ZapfAst.Line;
VAR l: ZapfAst.Line; pk, t: ZapfTok.Token;
BEGIN
  PT(p, pk);
  IF pk.kind # ZapfTok.TkSymbol THEN
    ErrSkipLine(p, pk, ".FORM expects a form specifier");
    RETURN ZapfAst.NewLine(ZapfAst.LkNull)
  END;
  NT(p, t);
  MatchEndOfDirective(p);
  l := ZapfAst.NewLine(ZapfAst.LkForm);
  Strings.Copy(t.text, l.text);
  RETURN l
END PForm;

PROCEDURE POperand(VAR p: Parser): ZapfAst.Line;
VAR l: ZapfAst.Line; idx: ZapfExpr.Expr; pk, t: ZapfTok.Token;
BEGIN
  idx := ParseExprNH(p);
  IF ~TryMatchComma(p) THEN
    PT(p, pk);
    ErrSkipLine(p, pk, "expected ',' after operand index");
    RETURN ZapfAst.NewLine(ZapfAst.LkNull)
  END;
  PT(p, pk);
  IF pk.kind # ZapfTok.TkSymbol THEN
    ErrSkipLine(p, pk, ".OPERAND expects an encoding specifier");
    RETURN ZapfAst.NewLine(ZapfAst.LkNull)
  END;
  NT(p, t);
  MatchEndOfDirective(p);
  l := ZapfAst.NewLine(ZapfAst.LkOperand);
  l.exprA := idx;
  Strings.Copy(t.text, l.text);
  RETURN l
END POperand;

PROCEDURE PNew(VAR p: Parser): ZapfAst.Line;
VAR l: ZapfAst.Line; ver: ZapfExpr.Expr; have: BOOLEAN;
BEGIN
  l := ZapfAst.NewLine(ZapfAst.LkNew);
  have := TryParseExpr(p, ver);
  MatchEndOfDirective(p);
  l.exprA := ver;
  IF have & (ver # NIL) & (ver.kind = ZapfExpr.KindNum) & (ver.numVal >= 3) & (ver.numVal <= 8) THEN
    p.effVersion := ver.numVal
  END;
  RETURN l
END PNew;

PROCEDURE PObject(VAR p: Parser): ZapfAst.Line;
VAR l: ZapfAst.Line;
    e1, e2, e3, e4, e5, e6, e7: ZapfExpr.Expr;
BEGIN
  l := ZapfAst.NewLine(ZapfAst.LkObject);
  MatchSymbol(p, l.name); MatchComma(p);
  e1 := ParseExprNH(p); MatchComma(p);          (* flags1 *)
  e2 := ParseExprNH(p); MatchComma(p);          (* flags2 *)
  e3 := ParseExprNH(p); MatchComma(p);          (* parentOrFlags3 *)
  e4 := ParseExprNH(p); MatchComma(p);          (* siblingOrParent *)
  e5 := ParseExprNH(p); MatchComma(p);          (* childOrSibling *)
  e6 := ParseExprNH(p);                          (* propTableOrChild *)
  l.exprA := e1; l.exprB := e2;
  IF TryMatchComma(p) THEN
    e7 := ParseExprNH(p);                        (* 8th value -> real propTable *)
    l.exprC := e3;   (* flags3 *)
    l.exprD := e4;   (* parent *)
    l.exprE := e5;   (* sibling *)
    l.exprF := e6;   (* child *)
    l.exprG := e7    (* propTable *)
  ELSE
    l.exprC := NIL;  (* no flags3 *)
    l.exprD := e3;   (* parent *)
    l.exprE := e4;   (* sibling *)
    l.exprF := e5;   (* child *)
    l.exprG := e6    (* propTable *)
  END;
  MatchEndOfDirective(p);
  RETURN l
END PObject;

PROCEDURE PProp(VAR p: Parser): ZapfAst.Line;
VAR l: ZapfAst.Line;
BEGIN
  l := ZapfAst.NewLine(ZapfAst.LkProp);
  l.exprA := ParseExprNH(p);
  MatchComma(p);
  l.exprB := ParseExprNH(p);
  MatchEndOfDirective(p);
  RETURN l
END PProp;

PROCEDURE PTable(VAR p: Parser): ZapfAst.Line;
VAR l: ZapfAst.Line; sz: ZapfExpr.Expr;
BEGIN
  l := ZapfAst.NewLine(ZapfAst.LkTable);
  IF TryParseExpr(p, sz) THEN l.exprA := sz ELSE l.exprA := NIL END;
  MatchEndOfDirective(p);
  RETURN l
END PTable;

PROCEDURE PVocbeg(VAR p: Parser): ZapfAst.Line;
VAR l: ZapfAst.Line;
BEGIN
  l := ZapfAst.NewLine(ZapfAst.LkVocbeg);
  l.exprA := ParseExprNH(p);
  MatchComma(p);
  l.exprB := ParseExprNH(p);
  MatchEndOfDirective(p);
  RETURN l
END PVocbeg;

(* ---- debug directives: parse & discard, per scope decision ---- *)

PROCEDURE PDebugNumName(VAR p: Parser): ZapfAst.Line;
VAR e: ZapfExpr.Expr; s: ARRAY 1024 OF CHAR;
BEGIN
  e := ParseExprNH(p); MatchComma(p); MatchString(p, s);
  MatchEndOfDirective(p);
  RETURN ZapfAst.NewLine(ZapfAst.LkNull)
END PDebugNumName;

PROCEDURE PDebugFile(VAR p: Parser): ZapfAst.Line;
VAR e: ZapfExpr.Expr; s1, s2: ARRAY 1024 OF CHAR;
BEGIN
  e := ParseExprNH(p); MatchComma(p);
  MatchString(p, s1); MatchComma(p);
  MatchString(p, s2);
  MatchEndOfDirective(p);
  RETURN ZapfAst.NewLine(ZapfAst.LkNull)
END PDebugFile;

PROCEDURE PDebugLine3(VAR p: Parser): ZapfAst.Line;
VAR e: ZapfExpr.Expr;
BEGIN
  e := ParseExprNH(p); MatchComma(p);
  e := ParseExprNH(p); MatchComma(p);
  e := ParseExprNH(p);
  MatchEndOfDirective(p);
  RETURN ZapfAst.NewLine(ZapfAst.LkNull)
END PDebugLine3;

PROCEDURE PDebugMap(VAR p: Parser): ZapfAst.Line;
VAR s: ARRAY 1024 OF CHAR; e: ZapfExpr.Expr;
BEGIN
  MatchString(p, s);
  IF TryMatchEquals(p) THEN e := ParseExprNH(p) END;
  MatchEndOfDirective(p);
  RETURN ZapfAst.NewLine(ZapfAst.LkNull)
END PDebugMap;

PROCEDURE PDebugObject(VAR p: Parser): ZapfAst.Line;
VAR e: ZapfExpr.Expr; s: ARRAY 1024 OF CHAR; i: INTEGER;
BEGIN
  e := ParseExprNH(p); MatchComma(p);
  MatchString(p, s); MatchComma(p);
  FOR i := 1 TO 6 DO
    e := ParseExprNH(p);
    IF i < 6 THEN MatchComma(p) END
  END;
  MatchEndOfDirective(p);
  RETURN ZapfAst.NewLine(ZapfAst.LkNull)
END PDebugObject;

PROCEDURE PDebugRoutine(VAR p: Parser): ZapfAst.Line;
VAR e: ZapfExpr.Expr; s: ARRAY 1024 OF CHAR;
BEGIN
  e := ParseExprNH(p); MatchComma(p);
  e := ParseExprNH(p); MatchComma(p);
  e := ParseExprNH(p); MatchComma(p);
  MatchString(p, s);
  WHILE TryMatchComma(p) DO MatchString(p, s) END;
  MatchEndOfDirective(p);
  RETURN ZapfAst.NewLine(ZapfAst.LkNull)
END PDebugRoutine;

PROCEDURE PIgnore(VAR p: Parser): ZapfAst.Line;
BEGIN
  SkipLine(p);
  RETURN ZapfAst.NewLine(ZapfAst.LkNull)
END PIgnore;

(* ---------------------------------------------------------------- *)
(* directive dispatch by keyword                                     *)
(* ---------------------------------------------------------------- *)

PROCEDURE IsDirectiveKeyword(kw: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN (kw[0] = ".")
END IsDirectiveKeyword;

PROCEDURE DispatchDirective(VAR p: Parser; kw: ARRAY OF CHAR; VAR l: ZapfAst.Line): BOOLEAN;
BEGIN
  l := NIL;
  IF kw = ".ALIGN" THEN l := PAlign(p)
  ELSIF kw = ".BYTE" THEN l := PByteOrWord(p, ZapfAst.LkByte)
  ELSIF kw = ".WORD" THEN l := PByteOrWord(p, ZapfAst.LkWord)
  ELSIF kw = ".CHRSET" THEN l := PChrset(p)
  ELSIF kw = ".CREATOR" THEN l := PTextOnly(p, ZapfAst.LkCreator)
  ELSIF kw = ".END" THEN l := PNoArgs(ZapfAst.LkEnd, p)
  ELSIF kw = ".ENDI" THEN l := PNoArgs(ZapfAst.LkEndi, p)
  ELSIF kw = ".ENDT" THEN l := PNoArgs(ZapfAst.LkEndt, p)
  ELSIF kw = ".FSTR" THEN l := PFstrOrGstr(p, ZapfAst.LkFstr)
  ELSIF kw = ".GSTR" THEN l := PFstrOrGstr(p, ZapfAst.LkGstr)
  ELSIF kw = ".FUNCT" THEN l := PFunct(p)
  ELSIF kw = ".GVAR" THEN l := PGvar(p)
  ELSIF kw = ".INSERT" THEN l := PTextOnly(p, ZapfAst.LkInsert)
  ELSIF kw = ".LANG" THEN l := PLang(p)
  ELSIF kw = ".LEN" THEN l := PTextOnly(p, ZapfAst.LkLen)
  ELSIF kw = ".FORM" THEN l := PForm(p)
  ELSIF kw = ".OPERAND" THEN l := POperand(p)
  ELSIF kw = ".NEW" THEN l := PNew(p)
  ELSIF kw = ".OBJECT" THEN l := PObject(p)
  ELSIF kw = ".PROP" THEN l := PProp(p)
  ELSIF kw = ".SOUND" THEN l := PNoArgs(ZapfAst.LkSound, p)
  ELSIF kw = ".STR" THEN l := PTextOnly(p, ZapfAst.LkStr)
  ELSIF kw = ".STRL" THEN l := PTextOnly(p, ZapfAst.LkStrl)
  ELSIF kw = ".TABLE" THEN l := PTable(p)
  ELSIF kw = ".TIME" THEN l := PNoArgs(ZapfAst.LkTime, p)
  ELSIF kw = ".UNICHR" THEN l := PTextOnly(p, ZapfAst.LkUnichr)
  ELSIF kw = ".VOCBEG" THEN l := PVocbeg(p)
  ELSIF kw = ".VOCEND" THEN l := PNoArgs(ZapfAst.LkVocend, p)
  ELSIF kw = ".ZWORD" THEN l := PTextOnly(p, ZapfAst.LkZword)
  ELSIF kw = ".DEBUG-ACTION" THEN l := PDebugNumName(p)
  ELSIF kw = ".DEBUG-ARRAY" THEN l := PDebugNumName(p)
  ELSIF kw = ".DEBUG-ATTR" THEN l := PDebugNumName(p)
  ELSIF kw = ".DEBUG-FILE" THEN l := PDebugFile(p)
  ELSIF kw = ".DEBUG-GLOBAL" THEN l := PDebugNumName(p)
  ELSIF kw = ".DEBUG-LINE" THEN l := PDebugLine3(p)
  ELSIF kw = ".DEBUG-MAP" THEN l := PDebugMap(p)
  ELSIF kw = ".DEBUG-OBJECT" THEN l := PDebugObject(p)
  ELSIF kw = ".DEBUG-PROP" THEN l := PDebugNumName(p)
  ELSIF kw = ".DEBUG-ROUTINE" THEN l := PDebugRoutine(p)
  ELSIF kw = ".DEBUG-ROUTINE-END" THEN l := PDebugLine3(p)
  ELSIF kw = ".DEFSEG" THEN l := PIgnore(p)
  ELSIF kw = ".ENDSEG" THEN l := PIgnore(p)
  ELSIF kw = ".OPTIONS" THEN l := PIgnore(p)
  ELSIF kw = ".PICFILE" THEN l := PIgnore(p)
  ELSIF kw = ".SEGMENT" THEN l := PIgnore(p)
  ELSE RETURN FALSE
  END;
  RETURN TRUE
END DispatchDirective;

(* ---------------------------------------------------------------- *)
(* labels / instructions / bare lines                                 *)
(* ---------------------------------------------------------------- *)

PROCEDURE TryParseLabel(VAR p: Parser; head: ZapfTok.Token; VAR l: ZapfAst.Line): BOOLEAN;
VAR pk, t: ZapfTok.Token;
BEGIN
  l := NIL;
  IF head.kind = ZapfTok.TkSymbol THEN
    PT(p, pk);
    IF pk.kind = ZapfTok.TkColon THEN
      NT(p, t);
      l := ZapfAst.NewLine(ZapfAst.LkLocalLbl);
      Strings.Copy(head.text, l.name);
      RETURN TRUE
    ELSIF pk.kind = ZapfTok.TkDColon THEN
      NT(p, t);
      l := ZapfAst.NewLine(ZapfAst.LkGlobalLbl);
      Strings.Copy(head.text, l.name);
      RETURN TRUE
    END
  END;
  RETURN FALSE
END TryParseLabel;

PROCEDURE ParseUnrecognizedInstruction(VAR p: Parser; head: ZapfTok.Token): ZapfAst.Line;
VAR l: ZapfAst.Line; pk, t: ZapfTok.Token; betweenOperands, loopDone: BOOLEAN;
BEGIN
  l := ZapfAst.NewLine(ZapfAst.LkBareSym);
  Strings.Copy(head.text, l.name);
  betweenOperands := TRUE;
  loopDone := FALSE;
  WHILE ~loopDone & ~p.fatal DO
    PT(p, pk);
    CASE pk.kind OF
      ZapfTok.TkComma: betweenOperands := TRUE
     |ZapfTok.TkSlash, ZapfTok.TkBackslash: l.bareHasBranch := TRUE
     |ZapfTok.TkRAngle: l.bareHasStore := TRUE
     |ZapfTok.TkEndOfFile: loopDone := TRUE
     |ZapfTok.TkEndOfLine: NT(p, t); loopDone := TRUE
    ELSE
      IF betweenOperands THEN INC(l.bareOperandCount); betweenOperands := FALSE END
    END;
    IF ~loopDone THEN NT(p, t) END
  END;
  RETURN l
END ParseUnrecognizedInstruction;

PROCEDURE TryParseInstruction(VAR p: Parser; head: ZapfTok.Token; VAR l: ZapfAst.Line): BOOLEAN;
VAR idx, effVer: INTEGER; pk, t, labelTok, storeTok: ZapfTok.Token;
    polarity, loopDone: BOOLEAN; opExpr: ZapfExpr.Expr;
BEGIN
  l := NIL;
  IF head.kind # ZapfTok.TkSymbol THEN RETURN FALSE END;
  effVer := ZapfOpcodes.EffectiveVersion(p.effVersion);
  IF ~ZapfOpcodes.Lookup(head.text, effVer, p.informMode, idx) THEN RETURN FALSE END;

  l := ZapfAst.NewLine(ZapfAst.LkInstr);
  Strings.Copy(head.text, l.name);
  loopDone := FALSE;
  WHILE ~loopDone & ~p.fatal DO
    PT(p, pk);
    CASE pk.kind OF
      ZapfTok.TkEndOfLine: NT(p, t); loopDone := TRUE
     |ZapfTok.TkEndOfFile: loopDone := TRUE
     |ZapfTok.TkSlash, ZapfTok.TkBackslash:
        polarity := (pk.kind = ZapfTok.TkSlash);
        NT(p, t);
        PT(p, pk);
        IF pk.kind # ZapfTok.TkSymbol THEN
          ErrSkipLine(p, pk, "expected label or 'TRUE' or 'FALSE' after branch marker");
          loopDone := TRUE
        ELSE
          NT(p, labelTok);
          IF l.hasBranch THEN
            ErrSkipLine(p, labelTok, "multiple branch targets");
            loopDone := TRUE
          ELSE
            l.hasBranch := TRUE;
            l.branchPolarity := polarity;
            Strings.Copy(labelTok.text, l.branchTarget)
          END
        END
     |ZapfTok.TkRAngle:
        NT(p, t);
        PT(p, pk);
        IF pk.kind # ZapfTok.TkSymbol THEN
          ErrSkipLine(p, pk, "expected variable or 'STACK' after '>'");
          loopDone := TRUE
        ELSE
          NT(p, storeTok);
          IF l.storeTarget[0] # 0X THEN
            ErrSkipLine(p, storeTok, "multiple store targets");
            loopDone := TRUE
          ELSE
            Strings.Copy(storeTok.text, l.storeTarget)
          END
        END
    ELSE
      IF CanStartExpr(pk.kind) THEN
        NT(p, t);
        opExpr := ParseExpr(p, t);
        ZapfAst.AddExpr(l.exprList, opExpr);
        PT(p, pk);
        CASE pk.kind OF
          ZapfTok.TkComma: NT(p, t)
         |ZapfTok.TkSlash, ZapfTok.TkBackslash, ZapfTok.TkRAngle,
          ZapfTok.TkEndOfLine, ZapfTok.TkEndOfFile: (* handled next iteration *)
        ELSE
          ErrSkipLine(p, pk, "expected ',' or target or EOL after operand");
          loopDone := TRUE
        END
      ELSE
        ErrSkipLine(p, pk, "unexpected token");
        loopDone := TRUE
      END
    END
  END;
  RETURN TRUE
END TryParseInstruction;

PROCEDURE TryParseDirective(VAR p: Parser; head: ZapfTok.Token; VAR l: ZapfAst.Line): BOOLEAN;
VAR pk, t: ZapfTok.Token; val, first: ZapfExpr.Expr; handled: BOOLEAN;
BEGIN
  l := NIL;
  IF head.kind = ZapfTok.TkSymbol THEN
    PT(p, pk);
    IF pk.kind = ZapfTok.TkEquals THEN
      NT(p, t);
      val := ParseExprNH(p);
      MaybeSkipTypeFlag(p);
      MatchEndOfDirective(p);
      l := ZapfAst.NewLine(ZapfAst.LkEquals);
      Strings.Copy(head.text, l.name);
      l.exprA := val;
      RETURN TRUE
    END;
    IF IsDirectiveKeyword(head.text) THEN
      handled := DispatchDirective(p, head.text, l);
      IF handled THEN RETURN TRUE END
    END
  END;
  IF CanStartExpr(head.kind) THEN
    PT(p, pk);
    IF (pk.kind = ZapfTok.TkEndOfFile) OR (pk.kind = ZapfTok.TkEndOfLine)
       OR (pk.kind = ZapfTok.TkComma) OR (pk.kind = ZapfTok.TkPlus) THEN
      l := ZapfAst.NewLine(ZapfAst.LkWord);
      first := ParseExpr(p, head);
      ZapfAst.AddExpr(l.exprList, first);
      WHILE TryMatchComma(p) DO ZapfAst.AddExpr(l.exprList, ParseExprNH(p)) END;
      MatchEndOfDirective(p);
      RETURN TRUE
    ELSE
      l := ParseUnrecognizedInstruction(p, head);
      RETURN TRUE
    END
  END;
  RETURN FALSE
END TryParseDirective;

(* ---------------------------------------------------------------- *)
(* top-level entry                                                    *)
(* ---------------------------------------------------------------- *)

(* Parses one file into ll (appending). Returns FALSE iff a lexical (fatal)
   error occurred, in which case ll may be partially filled and the caller
   must treat the whole file as unusable (matching the original's exception
   unwind, which discards everything Parse() had collected so far). *)
PROCEDURE Parse*(VAR p: Parser; filename: ARRAY OF CHAR; VAR ll: ZapfAst.LineList): BOOLEAN;
VAR t: ZapfTok.Token; l, lbl: ZapfAst.Line; gotLabel: BOOLEAN;
BEGIN
  IF ~ZapfTok.Open(p.tok, filename) THEN
    Out.String("zapf: cannot open "); Out.String(filename); Out.Ln;
    RETURN FALSE
  END;
  LOOP
    NT(p, t);
    IF p.fatal THEN EXIT END;
    IF t.kind = ZapfTok.TkEndOfLine THEN
      (* blank line: loop again, i.e. C#'s "continue" *)
    ELSIF t.kind = ZapfTok.TkEndOfFile THEN
      EXIT
    ELSE
      gotLabel := TryParseLabel(p, t, lbl);
      IF p.fatal THEN EXIT END;

      IF gotLabel THEN
        Strings.Copy(filename, lbl.sourceFile);
        lbl.lineNum := t.line;
        ZapfAst.Append(ll, lbl);
        NT(p, t);
        IF p.fatal THEN EXIT END
      END;

      (* mirrors the original: after a label, EndOfLine/EndOfFile means
         "nothing more on this line" (continue); anything else falls
         through to instruction/directive parsing using this same t. *)
      IF gotLabel & ((t.kind = ZapfTok.TkEndOfLine) OR (t.kind = ZapfTok.TkEndOfFile)) THEN
        (* loop again *)
      ELSE
        l := NIL;
        IF ~TryParseInstruction(p, t, l) THEN
          IF p.fatal THEN EXIT END;
          IF ~TryParseDirective(p, t, l) THEN
            IF p.fatal THEN EXIT END;
            ErrSkipLine(p, t, "unexpected token");
            l := NIL
          END
        END;
        IF p.fatal THEN EXIT END;
        IF l # NIL THEN
          Strings.Copy(filename, l.sourceFile);
          l.lineNum := t.line;
          ZapfAst.Append(ll, l)
        END
      END
    END
  END;
  ZapfTok.Close(p.tok);
  RETURN ~p.fatal
END Parse;

END ZapfParser.
