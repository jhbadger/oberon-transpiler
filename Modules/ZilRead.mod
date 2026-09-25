MODULE ZilRead;
(*
  ZilRead — ZIL/MDL source reader, ported from Zilf.Language.Parsing.Parser
  and CharBuffer (C#). Phase 1 of the zilf port; see Notes/zilf_port_plan.md.

  Turns ZIL source text into ZilObj.Zo values: FORM <...>, LIST (...),
  VECTOR [...], ATOM, FIX (decimal/octal *N*/hex #16 N), STRING "...",
  CHARACTER (!\X), ADECL (X:Y), SEGMENT (!<...> / !.X / !,X / !'X), and
  ';'/';;' comments (discarded).

  ReadOne is written as ONE self-recursive procedure with the list/vector/
  adecl reading inlined, rather than factored into separate helper
  procedures — this transpiler has no FORWARD declarations, and the
  natural factoring (ReadOne calls ReadStructure calls ReadOne) is a
  mutual recursion Oberon can't express without one. Self-recursion
  (a procedure calling itself) is fine; that's not the restriction.

  Known simplifications vs. the original (see plan doc for the full list):
  - '%' (compile-time eval) and '#TYPE (...)' (CHTYPE) are parsed
    structurally (so they don't desync the rest of the file) but are NOT
    evaluated/retyped yet -- that needs the interpreter (phase 2). '%'
    currently just returns its argument unevaluated; '#TYPE (...)' returns
    the inner value with its ordinary parsed type, ignoring the requested
    type change. Both set rd.sawPercent/rd.sawChtype so callers can warn.
  - Mid-atom '!' escaping is approximated: '!-' is preserved literally
    (needed for the FOO!-BAR oblist-qualifier syntax), any other '!'
    mid-token is dropped and the following character is reprocessed
    normally.
  - No '{n}' template-parameter substitution (only meaningful when
    reading macro body templates via the interpreter) and no binary
    (#2 ...) literal support (rare); hex (#16 ...) IS supported.
*)

IMPORT ZilObj, Files, Strings;

CONST
  MaxTok = 4096;
  MaxStructItems = 1024;

TYPE
  (* Read-time evaluation hook. `%<...>` means "evaluate this NOW, while
     parsing" and `%%<...>` means "evaluate it now and discard the result"
     — so the reader needs the evaluator. ZilEval already imports this
     module, and Oberon has no circular imports, so the dependency is
     inverted through a procedure variable that ZilEval installs into
     `evalHook` when it initialises (the same pattern Cloj.mod already uses
     for its own EvalProc). While the hook is NIL — a driver that only
     wants to parse, e.g. a syntax check — the old behaviour stands: the
     argument comes back unevaluated and rd.sawPercent is set so the
     caller knows the result is not semantically faithful. *)
  EvalProc* = PROCEDURE(z: ZilObj.Zo): ZilObj.Zo;

  Reader* = RECORD
    f: Files.File;
    r: Files.Rider;
    filename*: ARRAY 512 OF CHAR;
    line*: INTEGER;
    (* A 2-deep pushback stack (heldChar is the top, returned first by
       NextChar). One slot isn't enough: SkipWhitespace's "! before
       non-whitespace" case must push back both the '!' and the character
       after it so the main dispatch's own bang-lookahead can re-read them
       in order — a single slot silently lost the second character,
       corrupting the stream (e.g. "!\B" mid-token would read '!', then
       skip straight past the already-consumed '\' to read whatever came
       after B instead) whenever a bang-prefixed token followed some
       whitespace. -1 = slot empty. *)
    heldChar, heldChar2: INTEGER;
    (* An in-memory source, used instead of the file when srcText # NIL.
       The original generates ZIL source as text and parses it —
       Program.Parse(ctx, template, ...) — which is how DEFSTRUCT builds
       its accessor macros; OpenString is the equivalent entry point. *)
    srcText: POINTER TO ARRAY OF CHAR;
    srcPos: INTEGER;
    err*: BOOLEAN;
    errMsg*: ARRAY 256 OF CHAR;
    sawPercent*: BOOLEAN;    (* set whenever a '%' construct was parsed but not evaluated *)
    sawChtype*: BOOLEAN      (* set whenever a '#atom (...)' construct was parsed but not retyped *)
  END;

VAR
  evalHook*: EvalProc;

PROCEDURE Open*(VAR rd: Reader; filename: ARRAY OF CHAR): BOOLEAN;
BEGIN
  rd.f := Files.Old(filename);
  IF rd.f = NIL THEN RETURN FALSE END;
  rd.srcText := NIL;
  Files.Set(rd.r, rd.f, 0);
  Strings.Copy(filename, rd.filename);
  rd.line := 1;
  rd.heldChar := -1; rd.heldChar2 := -1;
  rd.err := FALSE; rd.errMsg[0] := 0X;
  rd.sawPercent := FALSE; rd.sawChtype := FALSE;
  RETURN TRUE
END Open;

(* Reads from a string in memory instead of a file — the equivalent of the
   original's Program.Parse(ctx, "<source text>"), which is how it builds
   generated definitions such as DEFSTRUCT's accessor macros. *)
PROCEDURE OpenString*(VAR rd: Reader; text: ARRAY OF CHAR);
VAR i, n: INTEGER;
BEGIN
  rd.f := NIL;
  n := Strings.Length(text);
  NEW(rd.srcText, n + 1);
  FOR i := 0 TO n - 1 DO rd.srcText^[i] := text[i] END;
  rd.srcText^[n] := 0X;
  rd.srcPos := 0;
  Strings.Copy("<generated>", rd.filename);
  rd.line := 1;
  rd.heldChar := -1; rd.heldChar2 := -1;
  rd.err := FALSE; rd.errMsg[0] := 0X;
  rd.sawPercent := FALSE; rd.sawChtype := FALSE
END OpenString;

PROCEDURE Close*(VAR rd: Reader);
BEGIN
  IF rd.f # NIL THEN Files.Close(rd.f); rd.f := NIL END;
  rd.srcText := NIL
END Close;

PROCEDURE SetErr(VAR rd: Reader; msg: ARRAY OF CHAR);
BEGIN rd.err := TRUE; Strings.Copy(msg, rd.errMsg) END SetErr;

PROCEDURE NextChar(VAR rd: Reader): INTEGER;
VAR b: BYTE; c: INTEGER;
BEGIN
  IF rd.heldChar >= 0 THEN
    c := rd.heldChar; rd.heldChar := rd.heldChar2; rd.heldChar2 := -1; RETURN c
  END;
  IF rd.srcText # NIL THEN
    IF rd.srcText^[rd.srcPos] = 0X THEN RETURN -1 END;
    c := ORD(rd.srcText^[rd.srcPos]); INC(rd.srcPos);
    IF c = 10 THEN INC(rd.line) END;
    RETURN c
  END;
  IF rd.r.eof THEN RETURN -1 END;
  Files.Read(rd.r, b);
  IF rd.r.eof THEN RETURN -1 END;
  c := ORD(b);
  IF c = 10 THEN INC(rd.line) END;
  RETURN c
END NextChar;

(* Pushes onto a 2-deep stack (see the Reader record's own comment) — the
   most recently pushed-back character is the next one NextChar returns. *)
PROCEDURE PushBack(VAR rd: Reader; c: INTEGER);
BEGIN
  IF c = 10 THEN DEC(rd.line) END;
  rd.heldChar2 := rd.heldChar;
  rd.heldChar := c
END PushBack;

PROCEDURE IsSpace(c: INTEGER): BOOLEAN;
BEGIN RETURN (c = 32) OR (c = 9) OR (c = 13) OR (c = 12) OR (c = 10) END IsSpace;

PROCEDURE IsTerminator(c: INTEGER): BOOLEAN;
VAR u: INTEGER;
BEGIN
  u := c MOD 128;
  RETURN (u = ORD(")")) OR (u = ORD("]")) OR (u = ORD("}")) OR (u = ORD(">")) OR (u = ORD(":"))
END IsTerminator;

PROCEDURE IsNonAtomChar(c: INTEGER): BOOLEAN;
VAR u: INTEGER;
BEGIN
  u := c MOD 128;
  RETURN IsSpace(u) OR (u = ORD("<")) OR (u = ORD(">")) OR (u = ORD("(")) OR (u = ORD(")"))
       OR (u = ORD("{")) OR (u = ORD("}")) OR (u = ORD("[")) OR (u = ORD("]"))
       OR (u = ORD(":")) OR (u = ORD(";")) OR (u = ORD('"')) OR (u = ORD("'"))
       OR (u = ORD(",")) OR (u = ORD("%")) OR (u = ORD("#"))
       OR (u = ORD("`")) OR (u = ORD("~"))
END IsNonAtomChar;

(* Skips whitespace, including "! <ws>" (bang immediately before real
   whitespace is itself skipped as whitespace). Returns FALSE at EOF. *)
PROCEDURE SkipWhitespace(VAR rd: Reader): BOOLEAN;
VAR c, c2: INTEGER; done: BOOLEAN;
BEGIN
  done := FALSE;
  WHILE ~done DO
    c := NextChar(rd);
    IF c < 0 THEN RETURN FALSE END;
    IF IsSpace(c) THEN
      (* keep skipping *)
    ELSIF c = ORD("!") THEN
      c2 := NextChar(rd);
      IF c2 < 0 THEN SetErr(rd, "character expected after '!'"); RETURN FALSE END;
      IF IsSpace(c2) THEN
        (* both are whitespace, keep going *)
      ELSE
        PushBack(rd, c2);
        PushBack(rd, c);
        RETURN TRUE
      END
    ELSE
      PushBack(rd, c);
      RETURN TRUE
    END
  END;
  RETURN TRUE
END SkipWhitespace;

PROCEDURE ReadString(VAR rd: Reader; VAR ok: BOOLEAN): ZilObj.Zo;
VAR buf: ARRAY MaxTok OF CHAR; n, c: INTEGER; done: BOOLEAN;
BEGIN
  n := 0; ok := TRUE; done := FALSE;
  WHILE ~done DO
    c := NextChar(rd);
    IF c < 0 THEN SetErr(rd, "unterminated string"); ok := FALSE; done := TRUE
    ELSIF c = ORD('"') THEN done := TRUE
    ELSE
      IF c = ORD("\") THEN
        c := NextChar(rd);
        IF c < 0 THEN SetErr(rd, "character expected after '\\' in string"); ok := FALSE; done := TRUE END
      END;
      IF ok & ~done THEN
        IF n < MaxTok - 1 THEN buf[n] := CHR(c MOD 256); INC(n) END
      END
    END
  END;
  buf[n] := 0X;
  IF ok THEN RETURN ZilObj.NewStringN(buf, n) ELSE RETURN NIL END
END ReadString;

(* Reads an atom or a decimal/octal number. *)
PROCEDURE ReadAtomOrNumber(VAR rd: Reader; VAR ok: BOOLEAN): ZilObj.Zo;
VAR buf: ARRAY MaxTok OF CHAR; n, c, c2, digits, octalDigits: INTEGER;
    run: BOOLEAN; v: INTEGER;
BEGIN
  n := 0; digits := 0; octalDigits := 0; ok := TRUE; run := TRUE;
  c := NextChar(rd);
  WHILE run DO
    IF c < 0 THEN run := FALSE
    ELSIF IsNonAtomChar(c) OR IsTerminator(c) THEN
      PushBack(rd, c); run := FALSE
    ELSIF c = ORD("\") THEN
      c2 := NextChar(rd);
      IF c2 < 0 THEN SetErr(rd, "character expected after '\\'"); ok := FALSE; run := FALSE
      ELSE
        IF n < MaxTok - 1 THEN buf[n] := CHR(c2 MOD 256); INC(n) END;
        c := NextChar(rd)
      END
    ELSIF c = ORD("!") THEN
      c2 := NextChar(rd);
      IF c2 < 0 THEN SetErr(rd, "character expected after '!'"); ok := FALSE; run := FALSE
      ELSIF c2 = ORD("-") THEN
        IF n < MaxTok - 2 THEN buf[n] := "!"; buf[n+1] := "-"; n := n + 2 END;
        c := NextChar(rd)
      ELSE
        c := c2   (* drop the bang, reprocess c2 as the next raw char *)
      END
    ELSE
      IF n < MaxTok - 1 THEN
        buf[n] := CHR(c MOD 256); INC(n);
        IF (c >= ORD("0")) & (c <= ORD("9")) THEN
          INC(digits);
          IF c < ORD("8") THEN INC(octalDigits) END
        END
      END;
      c := NextChar(rd)
    END
  END;
  buf[n] := 0X;

  IF ~ok THEN RETURN NIL END;
  IF n = 0 THEN SetErr(rd, "empty atom"); ok := FALSE; RETURN NIL END;

  (* decimal? *)
  IF (digits > 0) & ((n = digits) OR ((n = digits + 1) & ((buf[0] = "-") OR (buf[0] = "+")))) THEN
    IF Strings.StrToInt(buf, v) THEN RETURN ZilObj.NewFix(v) END
  END;

  (* octal: *NNN* *)
  IF (n > 2) & (octalDigits = n - 2) & (buf[0] = "*") & (buf[n-1] = "*") THEN
    v := 0;
    FOR digits := 1 TO n - 2 DO v := v * 8 + (ORD(buf[digits]) - ORD("0")) END;
    RETURN ZilObj.NewFix(v)
  END;

  RETURN ZilObj.Intern(buf)
END ReadAtomOrNumber;

PROCEDURE ReadHex(VAR rd: Reader; VAR ok: BOOLEAN): ZilObj.Zo;
VAR c, v, d: INTEGER; run: BOOLEAN;
BEGIN
  ok := TRUE;
  IF ~SkipWhitespace(rd) THEN SetErr(rd, "hex number expected after '#16'"); ok := FALSE; RETURN NIL END;
  v := 0; d := 0; run := TRUE;
  WHILE run DO
    c := NextChar(rd);
    IF c < 0 THEN run := FALSE
    ELSIF (c >= ORD("0")) & (c <= ORD("9")) THEN v := v * 16 + (c - ORD("0")); INC(d)
    ELSIF (c >= ORD("a")) & (c <= ORD("f")) THEN v := v * 16 + (c - ORD("a") + 10); INC(d)
    ELSIF (c >= ORD("A")) & (c <= ORD("F")) THEN v := v * 16 + (c - ORD("A") + 10); INC(d)
    ELSIF IsTerminator(c) OR IsSpace(c) THEN PushBack(rd, c); run := FALSE
    ELSE SetErr(rd, "invalid hex digit"); ok := FALSE; run := FALSE
    END
  END;
  IF ok & (d = 0) THEN SetErr(rd, "hex number expected after '#16'"); ok := FALSE END;
  IF ok THEN RETURN ZilObj.NewFix(v) ELSE RETURN NIL END
END ReadHex;

(* Reads one ZIL object.
   - done=TRUE: clean EOF between objects (not inside a structure).
   - ok=FALSE: error; see rd.err/rd.errMsg.
   - isTerm=TRUE: the next thing was a closing bracket (returned in
     termChar), which the caller (an enclosing structure reader) should
     check and consume. *)
PROCEDURE ReadOne*(VAR rd: Reader; VAR ok, done, isTerm: BOOLEAN; VAR termChar: INTEGER): ZilObj.Zo;
VAR
  c, c2, n, i, innerTermCh: INTEGER;
  z, z2, inner, ty, result, v: ZilObj.Zo;
  okInner, innerDone, innerTerm, run: BOOLEAN;
  items: ARRAY MaxStructItems OF ZilObj.Zo;
  atomName: ARRAY 16 OF CHAR;
  banged: BOOLEAN;
BEGIN
  ok := TRUE; done := FALSE; isTerm := FALSE; termChar := 0;

  IF ~SkipWhitespace(rd) THEN done := TRUE; RETURN NIL END;

  c := NextChar(rd);

  IF c = ORD("!") THEN
    c2 := NextChar(rd);
    IF c2 < 0 THEN SetErr(rd, "character expected after '!'"); ok := FALSE; RETURN NIL END;
    IF c2 = ORD("!") THEN SetErr(rd, "'!' not expected after '!'"); ok := FALSE; RETURN NIL END;
    IF c2 < 128 THEN c := c2 + 128 ELSE c := c2 END
  END;

  IF (c = ORD("(")) OR (c = ORD("(") + 128) THEN
    (* LIST *)
    n := 0; run := TRUE;
    WHILE run DO
      inner := ReadOne(rd, okInner, innerDone, innerTerm, innerTermCh);
      IF ~okInner THEN ok := FALSE; RETURN NIL END;
      IF innerDone THEN SetErr(rd, "unexpected end of file in list"); ok := FALSE; RETURN NIL END;
      IF innerTerm THEN
        IF innerTermCh # ORD(")") THEN SetErr(rd, "mismatched closing bracket in list"); ok := FALSE; RETURN NIL END;
        run := FALSE
      ELSE
        IF n < MaxStructItems THEN items[n] := inner; INC(n) END
      END
    END;
    result := ZilObj.NewEmpty(ZilObj.KList);
    FOR i := n - 1 TO 0 BY -1 DO result := ZilObj.Cons(ZilObj.KList, items[i], result) END;
    RETURN result

  ELSIF (c = ORD("<")) OR (c = ORD("<") + 128) THEN
    (* FORM, or !< -- SEGMENT wrapping a FORM *)
    banged := c = ORD("<") + 128;
    n := 0; run := TRUE;
    WHILE run DO
      inner := ReadOne(rd, okInner, innerDone, innerTerm, innerTermCh);
      IF ~okInner THEN ok := FALSE; RETURN NIL END;
      IF innerDone THEN SetErr(rd, "unexpected end of file in form"); ok := FALSE; RETURN NIL END;
      IF innerTerm THEN
        IF innerTermCh # ORD(">") THEN SetErr(rd, "mismatched closing bracket in form"); ok := FALSE; RETURN NIL END;
        run := FALSE
      ELSE
        IF n < MaxStructItems THEN items[n] := inner; INC(n) END
      END
    END;
    result := ZilObj.NewEmpty(ZilObj.KForm);
    FOR i := n - 1 TO 0 BY -1 DO result := ZilObj.Cons(ZilObj.KForm, items[i], result) END;
    IF banged THEN RETURN ZilObj.NewSegment(result) ELSE RETURN result END

  ELSIF (c = ORD("[")) OR (c = ORD("[") + 128) THEN
    (* VECTOR *)
    n := 0; run := TRUE;
    WHILE run DO
      inner := ReadOne(rd, okInner, innerDone, innerTerm, innerTermCh);
      IF ~okInner THEN ok := FALSE; RETURN NIL END;
      IF innerDone THEN SetErr(rd, "unexpected end of file in vector"); ok := FALSE; RETURN NIL END;
      IF innerTerm THEN
        IF innerTermCh # ORD("]") THEN SetErr(rd, "mismatched closing bracket in vector"); ok := FALSE; RETURN NIL END;
        run := FALSE
      ELSE
        IF n < MaxStructItems THEN items[n] := inner; INC(n) END
      END
    END;
    v := ZilObj.NewVectorN(n);
    FOR i := 0 TO n - 1 DO v.vecItems[i] := items[i] END;
    RETURN v

  ELSIF (c = ORD(".")) OR (c = ORD(".") + 128) OR (c = ORD(",")) OR (c = ORD(",") + 128)
      OR (c = ORD("'")) OR (c = ORD("'") + 128)
      OR (c = ORD("`")) OR (c = ORD("`") + 128) OR (c = ORD("~")) OR (c = ORD("~") + 128) THEN
    (* .X -> <LVAL X>   ,X -> <GVAL X>   'X -> <QUOTE X>
       `X -> <QUASIQUOTE X>   ~X -> <UNQUOTE X>  (see ZilEval.mod's
       quasiquote-walk logic for how these two are actually used — the
       real zilf implements them as an ordinary library, zillib/qq.mud,
       registering `/~ as runtime-extensible reader-macro prefix chars via
       a MAKE-PREFIX-MACRO SUBR this port doesn't have; since `/~ turn out
       to be used pervasively by the CORE zillib files (not just as an
       opt-in extra), this port hardcodes their expansion natively here
       instead of porting the general extensible-prefix-macro mechanism
       and qq.mud's own CHTYPE/PACKAGE/MAPF-based implementation — same
       "replicate the observable behavior pragmatically" approach as
       PROG/REPEAT/BIND vs. the original's LocalEnvironment chain)
       banged forms (!., !, , !', !`, !~) wrap the result in a SEGMENT *)
    banged := c >= 128;
    IF (c MOD 128) = ORD(".") THEN Strings.Copy("LVAL", atomName)
    ELSIF (c MOD 128) = ORD(",") THEN Strings.Copy("GVAL", atomName)
    ELSIF (c MOD 128) = ORD("'") THEN Strings.Copy("QUOTE", atomName)
    ELSIF (c MOD 128) = ORD("`") THEN Strings.Copy("QUASIQUOTE", atomName)
    ELSE Strings.Copy("UNQUOTE", atomName)
    END;
    inner := ReadOne(rd, okInner, innerDone, innerTerm, innerTermCh);
    IF (~okInner) THEN ok := FALSE; RETURN NIL END;
    IF innerDone OR innerTerm THEN
      SetErr(rd, "object expected after prefix character"); ok := FALSE; RETURN NIL
    END;
    z2 := ZilObj.Cons(ZilObj.KForm, ZilObj.Intern(atomName), ZilObj.Cons(ZilObj.KForm, inner, NIL));
    IF banged THEN RETURN ZilObj.NewSegment(z2) ELSE RETURN z2 END

  ELSIF c = ORD('"') THEN
    RETURN ReadString(rd, ok)

  ELSIF (c = ORD("\") + 128) OR (c = ORD('"') + 128) THEN
    (* !\X or !"X -- character literal *)
    c2 := NextChar(rd);
    IF c2 < 0 THEN SetErr(rd, "character expected after '!\\'"); ok := FALSE; RETURN NIL END;
    RETURN ZilObj.NewChar(c2)

  ELSIF c = ORD(";") THEN
    c2 := NextChar(rd);
    IF c2 = ORD(";") THEN
      (* line comment: skip to end of line, then read the next real object *)
      run := TRUE;
      WHILE run DO
        c2 := NextChar(rd);
        IF (c2 < 0) OR (c2 = 10) THEN run := FALSE END
      END;
      z := ReadOne(rd, ok, done, isTerm, termChar);
      RETURN z
    END;
    IF c2 >= 0 THEN PushBack(rd, c2) END;
    (* ';X' is a datum comment: read and discard one object, then read
       the next real object *)
    inner := ReadOne(rd, okInner, innerDone, innerTerm, innerTermCh);
    IF ~okInner THEN ok := FALSE; RETURN NIL END;
    IF innerDone THEN SetErr(rd, "object expected after ';'"); ok := FALSE; RETURN NIL END;
    z := ReadOne(rd, ok, done, isTerm, termChar);
    RETURN z

  ELSIF (c = ORD("%")) OR (c = ORD("%") + 128) THEN
    c2 := NextChar(rd);
    IF c2 = ORD("%") THEN
      (* %%<...>: evaluate at read time purely for the side effect, then
         carry on and return the NEXT object — the value is discarded *)
      inner := ReadOne(rd, okInner, innerDone, innerTerm, innerTermCh);
      IF ~okInner THEN ok := FALSE; RETURN NIL END;
      IF evalHook # NIL THEN inner := evalHook(inner) ELSE rd.sawPercent := TRUE END;
      z := ReadOne(rd, ok, done, isTerm, termChar);
      RETURN z
    END;
    IF c2 >= 0 THEN PushBack(rd, c2) END;
    (* %<...>: evaluate at read time and read the result in place of the
       form. Real library source depends on this — zillib's parser.zil
       builds an OBJECT's property list with
       `%<VERSION? (ZIP <LIST DESC ...>) (ELSE ())>`, which is a FORM, not
       the LIST an OBJECT property has to be, until it is evaluated here. *)
    inner := ReadOne(rd, okInner, innerDone, innerTerm, innerTermCh);
    IF ~okInner THEN ok := FALSE; RETURN NIL END;
    IF innerDone OR innerTerm THEN SetErr(rd, "object expected after '%'"); ok := FALSE; RETURN NIL END;
    IF evalHook # NIL THEN
      inner := evalHook(inner);
      IF inner = NIL THEN SetErr(rd, "read-time evaluation of a '%' form failed"); ok := FALSE; RETURN NIL END
    ELSE
      rd.sawPercent := TRUE
    END;
    RETURN inner

  ELSIF (c = ORD("#")) OR (c = ORD("#") + 128) THEN
    (* #atom (...) CHTYPE, or #16 <hex>: no type system yet, so CHTYPE
       just returns the inner value unretyped (see header) *)
    ty := ReadOne(rd, okInner, innerDone, innerTerm, innerTermCh);
    IF ~okInner THEN ok := FALSE; RETURN NIL END;
    IF innerDone OR innerTerm THEN SetErr(rd, "atom or number expected after '#'"); ok := FALSE; RETURN NIL END;
    IF (ty.kind = ZilObj.KFix) & (ty.fixVal = 16) THEN
      RETURN ReadHex(rd, ok)
    END;
    rd.sawChtype := TRUE;
    inner := ReadOne(rd, okInner, innerDone, innerTerm, innerTermCh);
    IF ~okInner THEN ok := FALSE; RETURN NIL END;
    IF innerDone OR innerTerm THEN SetErr(rd, "value expected after '#TYPE'"); ok := FALSE; RETURN NIL END;
    RETURN inner

  ELSIF (c = ORD(")")) OR (c = ORD("]")) OR (c = ORD("}")) OR (c = ORD(">")) THEN
    isTerm := TRUE; termChar := c; RETURN NIL

  ELSE
    PushBack(rd, c);
    z := ReadAtomOrNumber(rd, ok);
    IF ~ok THEN RETURN NIL END;

    (* optional trailing ':TYPE' -> ADECL *)
    IF ~SkipWhitespace(rd) THEN RETURN z END;
    c2 := NextChar(rd);
    IF c2 # ORD(":") THEN PushBack(rd, c2); RETURN z END;
    ty := ReadOne(rd, okInner, innerDone, innerTerm, innerTermCh);
    IF ~okInner THEN ok := FALSE; RETURN NIL END;
    IF innerDone OR innerTerm THEN SetErr(rd, "object expected after ':'"); ok := FALSE; RETURN NIL END;
    RETURN ZilObj.NewAdecl(z, ty)
  END
END ReadOne;

END ZilRead.
