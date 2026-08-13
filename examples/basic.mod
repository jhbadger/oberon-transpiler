MODULE Basic;
(*
 * A line-numbered BASIC interpreter (GW-BASIC / Applesoft flavor) with
 * Raylib-backed graphics and sound statements bolted on.
 *
 * A program that never uses a graphics or sound statement never touches
 * Raylib at all -- it runs as an ordinary terminal program reading/writing
 * stdin/stdout.  The first SCREEN/PSET/LINE/CIRCLE/... statement lazily
 * opens a Raylib window; the first SOUND/BEEP lazily opens the audio
 * device (independently -- sound alone does not require a window).
 *
 * Usage:
 *   basic program.bas      -- load and run program.bas, then exit
 *   basic                  -- interactive prompt (type numbered lines to
 *                              build a program; RUN/LIST/NEW/LOAD/SAVE/BYE
 *                              are immediate commands; anything else is
 *                              executed immediately, e.g. "PRINT 2+2")
 *
 * The interactive prompt and INPUT statement are read via the History
 * module, so Up/Down recall previous lines and left/right/backspace edit
 * in place (see History.mod). '?' is accepted everywhere PRINT is and is
 * rewritten to PRINT in the stored program text, Applesoft-style.
 *
 * Language summary (see ShowHelp(), printed by the interactive prompt's
 * HELP command; HELP topic, e.g. HELP SOUND, gives details on one item):
 *   Statements : PRINT(?) INPUT LET IF/THEN FOR/TO/STEP/NEXT GOTO GOSUB
 *                RETURN ON...GOTO/GOSUB END STOP DIM DATA READ RESTORE
 *                CLS/HOME LOCATE RANDOMIZE
 *   Graphics   : SCREEN COLOR PSET LINE CIRCLE FCIRCLE RECT FRECT TEXT
 *   Sound      : SOUND BEEP DELAY
 *   Functions  : ABS INT SGN SQR SIN COS TAN ATN LOG EXP RND PI TIMER
 *                LEN VAL ASC CHR$ STR$ LEFT$ RIGHT$ MID$ INSTR INKEY$
 *                SCRW SCRH MOUSEX MOUSEY MOUSEB
 *   Comments   : REM or '
 *)

IMPORT Out, Strings, Random, Math, Time, Files, Args, Raylib, History;

CONST
  MaxLines      = 4000;
  MaxLineLen    = 240;
  MaxTok        = 160;
  MaxScalarNum  = 800;
  MaxScalarStr  = 400;
  MaxArrays     = 100;
  MaxArrNumCap  = 40000;   (* total flattened elements across all numeric arrays combined is not capped; this is per-array *)
  MaxStrArrCap  = 2000;    (* per string array, flattened element cap *)
  MaxForStack   = 40;
  MaxGosubStack = 60;
  MaxDataVals   = 4000;

  (* token kinds *)
  TkEOL = 0; TkNum = 1; TkStr = 2; TkIdent = 3; TkOp = 4;
  TkLP = 5; TkRP = 6; TkComma = 7; TkColon = 8; TkSemi = 9;

TYPE
  Token = RECORD
    kind : INTEGER;
    num  : REAL;
    s    : STRING     (* IDENT text (uppercased) / STR literal content / OP text *)
  END;

  TokBuf = RECORD
    t   : ARRAY MaxTok OF Token;
    n   : INTEGER;
    pos : INTEGER
  END;

  Value = RECORD
    isStr : BOOLEAN;
    num   : REAL;
    s     : STRING
  END;

  ProgLine = RECORD
    num  : INTEGER;
    text : STRING
  END;

  ScalarNum = RECORD name : STRING; val : REAL END;
  ScalarStr = RECORD name : STRING; val : STRING END;

  NumArrPtr = POINTER TO ARRAY OF REAL;
  StrArrData = POINTER TO StrArrRec;
  StrArrRec  = RECORD elems : ARRAY MaxStrArrCap OF STRING END;

  ArrayEntry = RECORD
    name    : STRING;
    isStr   : BOOLEAN;
    dims    : INTEGER;      (* 1 or 2 *)
    d1, d2  : INTEGER;      (* upper bound per dim; size = d+1 *)
    numData : NumArrPtr;
    strData : StrArrData
  END;

  ForEntry = RECORD
    varName  : STRING;
    limit    : REAL;
    step     : REAL;
    lineIdx  : INTEGER;     (* -1 = immediate pseudo-line *)
    tokPos   : INTEGER
  END;

  GosubEntry = RECORD
    lineIdx : INTEGER;
    tokPos  : INTEGER
  END;

VAR
  prog     : ARRAY MaxLines OF ProgLine;
  nLines   : INTEGER;

  immText  : STRING;

  numVars  : ARRAY MaxScalarNum OF ScalarNum;
  nNumVars : INTEGER;
  strVars  : ARRAY MaxScalarStr OF ScalarStr;
  nStrVars : INTEGER;

  arrays   : ARRAY MaxArrays OF ArrayEntry;
  nArrays  : INTEGER;

  forStack   : ARRAY MaxForStack OF ForEntry;
  forTop     : INTEGER;
  gosubStack : ARRAY MaxGosubStack OF GosubEntry;
  gosubTop   : INTEGER;

  dataVals    : ARRAY MaxDataVals OF Value;
  dataLineOf  : ARRAY MaxDataVals OF INTEGER;
  nDataVals   : INTEGER;
  dataPtr     : INTEGER;

  errFlag : BOOLEAN;
  errMsg  : STRING;

  progRunning : BOOLEAN;   (* FALSE stops the current Execute() loop *)
  appRunning  : BOOLEAN;   (* FALSE stops the interactive REPL / app *)
  fname       : STRING;

  outCol : INTEGER;    (* current terminal output column, for PRINT zones *)

  (* graphics / audio state *)
  gfxMode    : BOOLEAN;
  audioReady : BOOLEAN;
  canvas     : Raylib.RenderTexture;
  winW, winH : INTEGER;
  palette    : ARRAY 16 OF INTEGER;
  curColorIx : INTEGER;
  bgColorIx  : INTEGER;
  startTime  : LONGINT;

(* ============================= utility ================================ *)

PROCEDURE Upper(VAR s: ARRAY OF CHAR);
BEGIN
  Strings.ToUpper(s)
END Upper;

PROCEDURE POut(s: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  Out.String(s);
  i := 0;
  WHILE s[i] # 0X DO
    IF s[i] = 0AX THEN outCol := 0 ELSE INC(outCol) END;
    INC(i)
  END
END POut;

PROCEDURE PNL;
BEGIN
  Out.Ln; outCol := 0
END PNL;

PROCEDURE RtErr(msg: ARRAY OF CHAR);
BEGIN
  IF ~errFlag THEN errFlag := TRUE; Strings.Copy(msg, errMsg) END
END RtErr;

PROCEDURE NumToStr(x: REAL; VAR s: ARRAY OF CHAR);
BEGIN
  Strings.RealToStr(x, s)
END NumToStr;

(* ============================ tokenizer ================================ *)

PROCEDURE IsDigit(c: CHAR): BOOLEAN;
BEGIN RETURN (c >= '0') & (c <= '9') END IsDigit;

PROCEDURE IsAlpha(c: CHAR): BOOLEAN;
BEGIN RETURN ((c >= 'A') & (c <= 'Z')) OR ((c >= 'a') & (c <= 'z')) OR (c = '_') END IsAlpha;

PROCEDURE IsAlnum(c: CHAR): BOOLEAN;
BEGIN RETURN IsAlpha(c) OR IsDigit(c) END IsAlnum;

PROCEDURE AddTok(VAR tb: TokBuf; kind: INTEGER);
BEGIN
  IF tb.n < MaxTok THEN
    tb.t[tb.n].kind := kind;
    tb.t[tb.n].num := 0.0;
    tb.t[tb.n].s := "";
    INC(tb.n)
  END
END AddTok;

PROCEDURE Tokenize(text: ARRAY OF CHAR; VAR tb: TokBuf);
VAR i, j: INTEGER; c: CHAR; buf: STRING; v: REAL;
BEGIN
  tb.n := 0; tb.pos := 0; i := 0;
  LOOP
    c := text[i];
    IF c = 0X THEN EXIT END;
    IF (c = ' ') OR (c = 09X) THEN INC(i)
    ELSIF c = "'" THEN EXIT   (* comment to end of line *)
    ELSIF IsDigit(c) OR ((c = '.') & IsDigit(text[i+1])) THEN
      j := 0;
      WHILE IsDigit(text[i]) DO buf[j] := text[i]; INC(j); INC(i) END;
      IF text[i] = '.' THEN
        buf[j] := text[i]; INC(j); INC(i);
        WHILE IsDigit(text[i]) DO buf[j] := text[i]; INC(j); INC(i) END
      END;
      IF (text[i] = 'E') OR (text[i] = 'e') THEN
        buf[j] := 'E'; INC(j); INC(i);
        IF (text[i] = '+') OR (text[i] = '-') THEN buf[j] := text[i]; INC(j); INC(i) END;
        WHILE IsDigit(text[i]) DO buf[j] := text[i]; INC(j); INC(i) END
      END;
      buf[j] := 0X;
      v := 0.0;
      IF ~Strings.StrToReal(buf, v) THEN v := 0.0 END;
      AddTok(tb, TkNum);
      tb.t[tb.n-1].num := v
    ELSIF IsAlpha(c) THEN
      j := 0;
      WHILE IsAlnum(text[i]) DO buf[j] := text[i]; INC(j); INC(i) END;
      IF text[i] = '$' THEN buf[j] := '$'; INC(j); INC(i) END;
      buf[j] := 0X;
      Upper(buf);
      IF buf = "REM" THEN EXIT END;
      AddTok(tb, TkIdent);
      Strings.Copy(buf, tb.t[tb.n-1].s)
    ELSIF c = '"' THEN
      INC(i); j := 0;
      WHILE (text[i] # '"') & (text[i] # 0X) DO buf[j] := text[i]; INC(j); INC(i) END;
      IF text[i] = '"' THEN INC(i) END;
      buf[j] := 0X;
      AddTok(tb, TkStr);
      Strings.Copy(buf, tb.t[tb.n-1].s)
    ELSIF c = '<' THEN
      IF text[i+1] = '>' THEN AddTok(tb, TkOp); Strings.Copy("<>", tb.t[tb.n-1].s); INC(i,2)
      ELSIF text[i+1] = '=' THEN AddTok(tb, TkOp); Strings.Copy("<=", tb.t[tb.n-1].s); INC(i,2)
      ELSE AddTok(tb, TkOp); Strings.Copy("<", tb.t[tb.n-1].s); INC(i) END
    ELSIF c = '>' THEN
      IF text[i+1] = '=' THEN AddTok(tb, TkOp); Strings.Copy(">=", tb.t[tb.n-1].s); INC(i,2)
      ELSE AddTok(tb, TkOp); Strings.Copy(">", tb.t[tb.n-1].s); INC(i) END
    ELSIF (c = '=') OR (c = '+') OR (c = '-') OR (c = '*') OR (c = '/') OR (c = '^') THEN
      AddTok(tb, TkOp);
      tb.t[tb.n-1].s[0] := c; tb.t[tb.n-1].s[1] := 0X;
      INC(i)
    ELSIF c = '(' THEN AddTok(tb, TkLP); INC(i)
    ELSIF c = ')' THEN AddTok(tb, TkRP); INC(i)
    ELSIF c = ',' THEN AddTok(tb, TkComma); INC(i)
    ELSIF c = ':' THEN AddTok(tb, TkColon); INC(i)
    ELSIF c = ';' THEN AddTok(tb, TkSemi); INC(i)
    ELSE INC(i)  (* skip unknown char *)
    END
  END;
  AddTok(tb, TkEOL)
END Tokenize;

PROCEDURE CurKind(VAR tb: TokBuf): INTEGER;
BEGIN
  IF tb.pos < tb.n THEN RETURN tb.t[tb.pos].kind ELSE RETURN TkEOL END
END CurKind;

PROCEDURE IsIdent(VAR tb: TokBuf; name: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN (CurKind(tb) = TkIdent) & (tb.t[tb.pos].s = name)
END IsIdent;

PROCEDURE IsOp(VAR tb: TokBuf; op: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN (CurKind(tb) = TkOp) & (tb.t[tb.pos].s = op)
END IsOp;

(* =========================== symbol table =============================== *)

PROCEDURE IsStrName(name: ARRAY OF CHAR): BOOLEAN;
VAR n: INTEGER;
BEGIN
  n := Strings.Length(name);
  RETURN (n > 0) & (name[n-1] = '$')
END IsStrName;

PROCEDURE FindNumVar(name: ARRAY OF CHAR): INTEGER;
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE i < nNumVars DO
    IF numVars[i].name = name THEN RETURN i END;
    INC(i)
  END;
  RETURN -1
END FindNumVar;

PROCEDURE FindStrVar(name: ARRAY OF CHAR): INTEGER;
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE i < nStrVars DO
    IF strVars[i].name = name THEN RETURN i END;
    INC(i)
  END;
  RETURN -1
END FindStrVar;

PROCEDURE GetNum(name: ARRAY OF CHAR): REAL;
VAR i: INTEGER;
BEGIN
  i := FindNumVar(name);
  IF i >= 0 THEN RETURN numVars[i].val ELSE RETURN 0.0 END
END GetNum;

PROCEDURE SetNum(name: ARRAY OF CHAR; v: REAL);
VAR i: INTEGER;
BEGIN
  i := FindNumVar(name);
  IF i < 0 THEN
    IF nNumVars >= MaxScalarNum THEN RtErr("TOO MANY VARIABLES"); RETURN END;
    i := nNumVars; INC(nNumVars);
    Strings.Copy(name, numVars[i].name)
  END;
  numVars[i].val := v
END SetNum;

PROCEDURE GetStr(name: ARRAY OF CHAR; VAR out: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  i := FindStrVar(name);
  IF i >= 0 THEN Strings.Copy(strVars[i].val, out) ELSE Strings.Copy("", out) END
END GetStr;

PROCEDURE SetStr(name: ARRAY OF CHAR; v: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  i := FindStrVar(name);
  IF i < 0 THEN
    IF nStrVars >= MaxScalarStr THEN RtErr("TOO MANY VARIABLES"); RETURN END;
    i := nStrVars; INC(nStrVars);
    Strings.Copy(name, strVars[i].name)
  END;
  Strings.Copy(v, strVars[i].val)
END SetStr;

PROCEDURE FindArray(name: ARRAY OF CHAR): INTEGER;
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE i < nArrays DO
    IF arrays[i].name = name THEN RETURN i END;
    INC(i)
  END;
  RETURN -1
END FindArray;

(* Create (or replace) an array named `name` with the given bounds. *)
PROCEDURE DimArray(name: ARRAY OF CHAR; d1, d2: INTEGER): INTEGER;
VAR i, total, sz1, sz2: INTEGER; isStr: BOOLEAN;
BEGIN
  isStr := IsStrName(name);
  sz1 := d1 + 1;
  IF d2 >= 0 THEN sz2 := d2 + 1 ELSE sz2 := 1 END;
  total := sz1 * sz2;
  i := FindArray(name);
  IF i < 0 THEN
    IF nArrays >= MaxArrays THEN RtErr("TOO MANY ARRAYS"); RETURN -1 END;
    i := nArrays; INC(nArrays);
    Strings.Copy(name, arrays[i].name)
  END;
  arrays[i].isStr := isStr;
  IF d2 >= 0 THEN arrays[i].dims := 2 ELSE arrays[i].dims := 1 END;
  arrays[i].d1 := d1; arrays[i].d2 := d2;
  IF isStr THEN
    IF total > MaxStrArrCap THEN RtErr("ARRAY TOO LARGE"); RETURN -1 END;
    NEW(arrays[i].strData)
  ELSE
    IF total > MaxArrNumCap THEN RtErr("ARRAY TOO LARGE"); RETURN -1 END;
    NEW(arrays[i].numData, total)
  END;
  RETURN i
END DimArray;

PROCEDURE EnsureArray(name: ARRAY OF CHAR): INTEGER;
VAR i: INTEGER;
BEGIN
  i := FindArray(name);
  IF i < 0 THEN i := DimArray(name, 10, -1) END;
  RETURN i
END EnsureArray;

PROCEDURE ArrIndex(VAR ae: ArrayEntry; i1, i2: INTEGER; VAR idx: INTEGER): BOOLEAN;
BEGIN
  IF (i1 < 0) OR (i1 > ae.d1) THEN RtErr("SUBSCRIPT OUT OF RANGE"); RETURN FALSE END;
  IF ae.dims = 1 THEN
    idx := i1
  ELSE
    IF (i2 < 0) OR (i2 > ae.d2) THEN RtErr("SUBSCRIPT OUT OF RANGE"); RETURN FALSE END;
    idx := i1 * (ae.d2 + 1) + i2
  END;
  RETURN TRUE
END ArrIndex;

PROCEDURE ClearVars;
BEGIN
  nNumVars := 0; nStrVars := 0; nArrays := 0
END ClearVars;

(* ============================ expressions =============================== *)
(* Recursive-descent evaluator; the module's procedures are all mutually
 * visible so EvalExpr .. EvalPrimary may call each other in any order. *)

PROCEDURE MkNum(x: REAL): Value;
VAR v: Value;
BEGIN v.isStr := FALSE; v.num := x; v.s := ""; RETURN v END MkNum;

PROCEDURE MkBool(b: BOOLEAN): Value;
BEGIN
  IF b THEN RETURN MkNum(-1.0) ELSE RETURN MkNum(0.0) END
END MkBool;

PROCEDURE MkStr(s: ARRAY OF CHAR): Value;
VAR v: Value;
BEGIN v.isStr := TRUE; v.num := 0.0; Strings.Copy(s, v.s); RETURN v END MkStr;

PROCEDURE Truthy(VAR v: Value): BOOLEAN;
BEGIN
  IF v.isStr THEN RETURN Strings.Length(v.s) > 0 ELSE RETURN v.num # 0.0 END
END Truthy;

PROCEDURE ElapsedSecs(): REAL;
VAR ms: LONGINT; r: REAL;
BEGIN ms := Time.Now() - startTime; r := ms; RETURN r / 1000.0 END ElapsedSecs;

PROCEDURE IsFuncName(name: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN (name = "ABS") OR (name = "INT") OR (name = "SGN") OR (name = "SQR")
       OR (name = "SIN") OR (name = "COS") OR (name = "TAN") OR (name = "ATN")
       OR (name = "LOG") OR (name = "EXP") OR (name = "PI") OR (name = "RND")
       OR (name = "TIMER") OR (name = "LEN") OR (name = "VAL") OR (name = "ASC")
       OR (name = "CHR$") OR (name = "STR$") OR (name = "LEFT$") OR (name = "RIGHT$")
       OR (name = "MID$") OR (name = "INSTR") OR (name = "INKEY$") OR (name = "SCRW")
       OR (name = "SCRH") OR (name = "MOUSEX") OR (name = "MOUSEY") OR (name = "MOUSEB")
END IsFuncName;

PROCEDURE ReadInkey(VAR out: ARRAY OF CHAR);
VAR k: INTEGER;
BEGIN
  out[0] := 0X;
  IF gfxMode THEN
    k := Raylib.GetCharPressed();
    IF k = 0 THEN
      IF Raylib.IsKeyPressed(Raylib.KeyEnter) = 1 THEN k := 13
      ELSIF Raylib.IsKeyPressed(Raylib.KeyBackspace) = 1 THEN k := 8
      ELSIF Raylib.IsKeyPressed(Raylib.KeySpace) = 1 THEN k := 32
      ELSIF Raylib.IsKeyPressed(Raylib.KeyEsc) = 1 THEN k := 27
      ELSIF Raylib.IsKeyPressed(Raylib.KeyUp) = 1 THEN k := 200
      ELSIF Raylib.IsKeyPressed(Raylib.KeyDown) = 1 THEN k := 201
      ELSIF Raylib.IsKeyPressed(Raylib.KeyLeft) = 1 THEN k := 202
      ELSIF Raylib.IsKeyPressed(Raylib.KeyRight) = 1 THEN k := 203
      END
    END;
    IF k # 0 THEN out[0] := CHR(k); out[1] := 0X END
  END
END ReadInkey;

PROCEDURE CallFunction(name: ARRAY OF CHAR; VAR tb: TokBuf; VAR v: Value);
VAR a1, a2, a3: Value; n: INTEGER; buf: STRING; hasA2, hasA3: BOOLEAN;
BEGIN
  hasA2 := FALSE; hasA3 := FALSE;
  a1 := MkNum(0.0); a2 := MkNum(0.0); a3 := MkNum(0.0);
  IF CurKind(tb) = TkLP THEN
    INC(tb.pos);
    IF CurKind(tb) # TkRP THEN
      EvalExpr(tb, a1);
      IF CurKind(tb) = TkComma THEN
        INC(tb.pos); EvalExpr(tb, a2); hasA2 := TRUE;
        IF CurKind(tb) = TkComma THEN
          INC(tb.pos); EvalExpr(tb, a3); hasA3 := TRUE
        END
      END
    END;
    IF CurKind(tb) = TkRP THEN INC(tb.pos) ELSE RtErr("MISSING )") END
  END;

  IF name = "ABS" THEN v := MkNum(ABS(a1.num))
  ELSIF name = "INT" THEN v := MkNum(FLT(FLOOR(a1.num)))
  ELSIF name = "SGN" THEN
    IF a1.num > 0.0 THEN v := MkNum(1.0)
    ELSIF a1.num < 0.0 THEN v := MkNum(-1.0)
    ELSE v := MkNum(0.0) END
  ELSIF name = "SQR" THEN v := MkNum(Math.sqrt(a1.num))
  ELSIF name = "SIN" THEN v := MkNum(Math.sin(a1.num))
  ELSIF name = "COS" THEN v := MkNum(Math.cos(a1.num))
  ELSIF name = "TAN" THEN v := MkNum(Math.tan(a1.num))
  ELSIF name = "ATN" THEN v := MkNum(Math.arctan(a1.num))
  ELSIF name = "LOG" THEN v := MkNum(Math.ln(a1.num))
  ELSIF name = "EXP" THEN v := MkNum(Math.exp(a1.num))
  ELSIF name = "PI" THEN v := MkNum(Math.pi)
  ELSIF name = "RND" THEN v := MkNum(Random.Real())
  ELSIF name = "TIMER" THEN v := MkNum(ElapsedSecs())
  ELSIF name = "LEN" THEN v := MkNum(FLT(Strings.Length(a1.s)))
  ELSIF name = "VAL" THEN
    IF ~Strings.StrToReal(a1.s, v.num) THEN v.num := 0.0 END;
    v.isStr := FALSE; v.s := ""
  ELSIF name = "ASC" THEN
    IF Strings.Length(a1.s) > 0 THEN v := MkNum(FLT(ORD(a1.s[0]))) ELSE v := MkNum(0.0) END
  ELSIF name = "CHR$" THEN
    buf[0] := CHR(FLOOR(a1.num)); buf[1] := 0X; v := MkStr(buf)
  ELSIF name = "STR$" THEN
    NumToStr(a1.num, buf); v := MkStr(buf)
  ELSIF name = "LEFT$" THEN
    n := FLOOR(a2.num); IF n < 0 THEN n := 0 END;
    IF n > Strings.Length(a1.s) THEN n := Strings.Length(a1.s) END;
    Strings.Extract(a1.s, 0, n, buf); v := MkStr(buf)
  ELSIF name = "RIGHT$" THEN
    n := FLOOR(a2.num); IF n < 0 THEN n := 0 END;
    IF n > Strings.Length(a1.s) THEN n := Strings.Length(a1.s) END;
    Strings.Extract(a1.s, Strings.Length(a1.s) - n, n, buf); v := MkStr(buf)
  ELSIF name = "MID$" THEN
    n := FLOOR(a2.num) - 1; IF n < 0 THEN n := 0 END;
    IF ~hasA3 THEN a3.num := FLT(Strings.Length(a1.s)) END;
    IF n > Strings.Length(a1.s) THEN n := Strings.Length(a1.s) END;
    IF n + FLOOR(a3.num) > Strings.Length(a1.s) THEN a3.num := FLT(Strings.Length(a1.s) - n) END;
    IF a3.num < 0.0 THEN a3.num := 0.0 END;
    Strings.Extract(a1.s, n, FLOOR(a3.num), buf); v := MkStr(buf)
  ELSIF name = "INSTR" THEN
    IF hasA3 THEN v := MkNum(FLT(Strings.Pos(a3.s, a1.s, FLOOR(a2.num) - 1) + 1))
    ELSE v := MkNum(FLT(Strings.Pos(a2.s, a1.s) + 1)) END
  ELSIF name = "INKEY$" THEN
    ReadInkey(buf); v := MkStr(buf)
  ELSIF name = "SCRW" THEN v := MkNum(FLT(winW))
  ELSIF name = "SCRH" THEN v := MkNum(FLT(winH))
  ELSIF name = "MOUSEX" THEN
    IF gfxMode THEN v := MkNum(FLT(Raylib.GetMouseX())) ELSE v := MkNum(0.0) END
  ELSIF name = "MOUSEY" THEN
    IF gfxMode THEN v := MkNum(FLT(Raylib.GetMouseY())) ELSE v := MkNum(0.0) END
  ELSIF name = "MOUSEB" THEN
    IF gfxMode & (Raylib.IsMouseButtonDown(Raylib.BtnLeft) = 1) THEN v := MkNum(-1.0) ELSE v := MkNum(0.0) END
  ELSE
    RtErr("UNKNOWN FUNCTION"); v := MkNum(0.0)
  END
END CallFunction;

PROCEDURE EvalPrimary(VAR tb: TokBuf; VAR v: Value);
VAR name: STRING; ai: INTEGER; i1, i2: INTEGER; idx: INTEGER; a2: Value;
BEGIN
  IF errFlag THEN v := MkNum(0.0); RETURN END;
  IF CurKind(tb) = TkNum THEN
    v := MkNum(tb.t[tb.pos].num); INC(tb.pos)
  ELSIF CurKind(tb) = TkStr THEN
    v := MkStr(tb.t[tb.pos].s); INC(tb.pos)
  ELSIF CurKind(tb) = TkLP THEN
    INC(tb.pos); EvalExpr(tb, v);
    IF CurKind(tb) = TkRP THEN INC(tb.pos) ELSE RtErr("MISSING )") END
  ELSIF CurKind(tb) = TkIdent THEN
    Strings.Copy(tb.t[tb.pos].s, name); INC(tb.pos);
    IF IsFuncName(name) THEN
      CallFunction(name, tb, v)
    ELSIF CurKind(tb) = TkLP THEN
      (* array reference *)
      INC(tb.pos);
      EvalExpr(tb, a2); i1 := FLOOR(a2.num); i2 := -1;
      IF CurKind(tb) = TkComma THEN
        INC(tb.pos); EvalExpr(tb, a2); i2 := FLOOR(a2.num)
      END;
      IF CurKind(tb) = TkRP THEN INC(tb.pos) ELSE RtErr("MISSING )") END;
      ai := EnsureArray(name);
      IF ai >= 0 THEN
        IF ArrIndex(arrays[ai], i1, i2, idx) THEN
          IF arrays[ai].isStr THEN v := MkStr(arrays[ai].strData.elems[idx])
          ELSE v := MkNum(arrays[ai].numData[idx]) END
        ELSE v := MkNum(0.0) END
      ELSE v := MkNum(0.0) END
    ELSE
      IF IsStrName(name) THEN
        v.isStr := TRUE; v.num := 0.0; GetStr(name, v.s)
      ELSE
        v := MkNum(GetNum(name))
      END
    END
  ELSE
    RtErr("SYNTAX ERROR"); v := MkNum(0.0)
  END
END EvalPrimary;

PROCEDURE EvalPow(VAR tb: TokBuf; VAR v: Value);
VAR rhs: Value;
BEGIN
  EvalPrimary(tb, v);
  IF IsOp(tb, "^") THEN
    INC(tb.pos); EvalUnary(tb, rhs);
    v := MkNum(Math.power(v.num, rhs.num))
  END
END EvalPow;

PROCEDURE EvalUnary(VAR tb: TokBuf; VAR v: Value);
BEGIN
  IF IsOp(tb, "-") THEN
    INC(tb.pos); EvalUnary(tb, v); v := MkNum(-v.num)
  ELSIF IsOp(tb, "+") THEN
    INC(tb.pos); EvalUnary(tb, v)
  ELSE
    EvalPow(tb, v)
  END
END EvalUnary;

PROCEDURE EvalMul(VAR tb: TokBuf; VAR v: Value);
VAR rhs: Value; opc: INTEGER;
BEGIN
  EvalUnary(tb, v);
  LOOP
    IF IsOp(tb, "*") THEN opc := 1
    ELSIF IsOp(tb, "/") THEN opc := 2
    ELSIF IsIdent(tb, "MOD") THEN opc := 3
    ELSE EXIT END;
    INC(tb.pos); EvalUnary(tb, rhs);
    IF opc = 1 THEN v := MkNum(v.num * rhs.num)
    ELSIF opc = 2 THEN
      IF rhs.num = 0.0 THEN RtErr("DIVISION BY ZERO"); v := MkNum(0.0)
      ELSE v := MkNum(v.num / rhs.num) END
    ELSE
      IF FLOOR(rhs.num) = 0 THEN RtErr("DIVISION BY ZERO"); v := MkNum(0.0)
      ELSE v := MkNum(FLT(FLOOR(v.num) MOD FLOOR(rhs.num))) END
    END
  END
END EvalMul;

PROCEDURE EvalAdd(VAR tb: TokBuf; VAR v: Value);
VAR rhs: Value; opc: INTEGER; res: STRING;
BEGIN
  EvalMul(tb, v);
  LOOP
    IF IsOp(tb, "+") THEN opc := 1
    ELSIF IsOp(tb, "-") THEN opc := 2
    ELSE EXIT END;
    INC(tb.pos); EvalMul(tb, rhs);
    IF opc = 1 THEN
      IF v.isStr OR rhs.isStr THEN
        Strings.Copy(v.s, res); Strings.Append(rhs.s, res); v := MkStr(res)
      ELSE
        v := MkNum(v.num + rhs.num)
      END
    ELSE
      v := MkNum(v.num - rhs.num)
    END
  END
END EvalAdd;

PROCEDURE EvalRel(VAR tb: TokBuf; VAR v: Value);
VAR rhs: Value; opc: INTEGER; c: INTEGER; res: BOOLEAN;
BEGIN
  EvalAdd(tb, v);
  IF IsOp(tb, "=") THEN opc := 1
  ELSIF IsOp(tb, "<>") THEN opc := 2
  ELSIF IsOp(tb, "<=") THEN opc := 5
  ELSIF IsOp(tb, ">=") THEN opc := 6
  ELSIF IsOp(tb, "<") THEN opc := 3
  ELSIF IsOp(tb, ">") THEN opc := 4
  ELSE RETURN END;
  INC(tb.pos); EvalAdd(tb, rhs);
  IF v.isStr OR rhs.isStr THEN
    c := Strings.Compare(v.s, rhs.s)
  ELSE
    IF v.num < rhs.num THEN c := -1 ELSIF v.num > rhs.num THEN c := 1 ELSE c := 0 END
  END;
  IF opc = 1 THEN res := c = 0
  ELSIF opc = 2 THEN res := c # 0
  ELSIF opc = 3 THEN res := c < 0
  ELSIF opc = 4 THEN res := c > 0
  ELSIF opc = 5 THEN res := c <= 0
  ELSE res := c >= 0 END;
  v := MkBool(res)
END EvalRel;

PROCEDURE EvalNot(VAR tb: TokBuf; VAR v: Value);
BEGIN
  IF IsIdent(tb, "NOT") THEN
    INC(tb.pos); EvalNot(tb, v); v := MkBool(~Truthy(v))
  ELSE
    EvalRel(tb, v)
  END
END EvalNot;

PROCEDURE EvalAnd(VAR tb: TokBuf; VAR v: Value);
VAR rhs: Value; r: BOOLEAN;
BEGIN
  EvalNot(tb, v);
  IF IsIdent(tb, "AND") THEN
    r := Truthy(v);
    WHILE IsIdent(tb, "AND") DO
      INC(tb.pos); EvalNot(tb, rhs); r := r & Truthy(rhs)
    END;
    v := MkBool(r)
  END
END EvalAnd;

PROCEDURE EvalOr(VAR tb: TokBuf; VAR v: Value);
VAR rhs: Value; r: BOOLEAN;
BEGIN
  EvalAnd(tb, v);
  IF IsIdent(tb, "OR") THEN
    r := Truthy(v);
    WHILE IsIdent(tb, "OR") DO
      INC(tb.pos); EvalAnd(tb, rhs); r := r OR Truthy(rhs)
    END;
    v := MkBool(r)
  END
END EvalOr;

PROCEDURE EvalExpr(VAR tb: TokBuf; VAR v: Value);
BEGIN
  EvalOr(tb, v)
END EvalExpr;

(* ========================== program line table =========================== *)

PROCEDURE FindLinePos(num: INTEGER; VAR pos: INTEGER): BOOLEAN;
VAR lo, hi, mid: INTEGER;
BEGIN
  lo := 0; hi := nLines;
  WHILE lo < hi DO
    mid := (lo + hi) DIV 2;
    IF prog[mid].num < num THEN lo := mid + 1 ELSE hi := mid END
  END;
  pos := lo;
  RETURN (lo < nLines) & (prog[lo].num = num)
END FindLinePos;

PROCEDURE LineIndexOf(num: INTEGER): INTEGER;
VAR pos: INTEGER;
BEGIN
  IF FindLinePos(num, pos) THEN RETURN pos ELSE RETURN -1 END
END LineIndexOf;

PROCEDURE InsertLine(num: INTEGER; text: ARRAY OF CHAR);
VAR pos, i: INTEGER; empty: BOOLEAN;
BEGIN
  empty := Strings.Length(text) = 0;
  IF FindLinePos(num, pos) THEN
    IF empty THEN
      FOR i := pos TO nLines - 2 DO prog[i] := prog[i+1] END;
      DEC(nLines)
    ELSE
      prog[pos].num := num; Strings.Copy(text, prog[pos].text)
    END
  ELSIF ~empty THEN
    IF nLines >= MaxLines THEN RtErr("PROGRAM TOO LARGE"); RETURN END;
    FOR i := nLines TO pos + 1 BY -1 DO prog[i] := prog[i-1] END;
    prog[pos].num := num; Strings.Copy(text, prog[pos].text);
    INC(nLines)
  END
END InsertLine;

(* ============================= assignment ================================ *)

PROCEDURE AssignScalar(name: ARRAY OF CHAR; VAR v: Value);
BEGIN
  IF IsStrName(name) THEN
    IF ~v.isStr THEN RtErr("TYPE MISMATCH"); RETURN END;
    SetStr(name, v.s)
  ELSE
    IF v.isStr THEN RtErr("TYPE MISMATCH"); RETURN END;
    SetNum(name, v.num)
  END
END AssignScalar;

PROCEDURE AssignArrayElem(name: ARRAY OF CHAR; i1, i2: INTEGER; VAR v: Value);
VAR ai, idx: INTEGER;
BEGIN
  ai := EnsureArray(name);
  IF ai < 0 THEN RETURN END;
  IF ~ArrIndex(arrays[ai], i1, i2, idx) THEN RETURN END;
  IF arrays[ai].isStr THEN
    IF ~v.isStr THEN RtErr("TYPE MISMATCH"); RETURN END;
    Strings.Copy(v.s, arrays[ai].strData.elems[idx])
  ELSE
    IF v.isStr THEN RtErr("TYPE MISMATCH"); RETURN END;
    arrays[ai].numData[idx] := v.num
  END
END AssignArrayElem;

PROCEDURE DoAssign(VAR tb: TokBuf);
VAR name: STRING; v, idxv: Value; i1, i2: INTEGER;
BEGIN
  IF CurKind(tb) # TkIdent THEN RtErr("SYNTAX ERROR"); RETURN END;
  Strings.Copy(tb.t[tb.pos].s, name); INC(tb.pos);
  IF CurKind(tb) = TkLP THEN
    INC(tb.pos); EvalExpr(tb, idxv); i1 := FLOOR(idxv.num); i2 := -1;
    IF CurKind(tb) = TkComma THEN INC(tb.pos); EvalExpr(tb, idxv); i2 := FLOOR(idxv.num) END;
    IF CurKind(tb) = TkRP THEN INC(tb.pos) ELSE RtErr("MISSING )"); RETURN END;
    IF IsOp(tb, "=") THEN INC(tb.pos) ELSE RtErr("MISSING ="); RETURN END;
    EvalExpr(tb, v);
    IF errFlag THEN RETURN END;
    AssignArrayElem(name, i1, i2, v)
  ELSE
    IF IsOp(tb, "=") THEN INC(tb.pos) ELSE RtErr("SYNTAX ERROR"); RETURN END;
    EvalExpr(tb, v);
    IF errFlag THEN RETURN END;
    AssignScalar(name, v)
  END
END DoAssign;

(* ================================ PRINT =================================== *)

PROCEDURE DoPrint(VAR tb: TokBuf);
VAR v: Value; buf: STRING; suppressNL: BOOLEAN; n, col: INTEGER;
BEGIN
  suppressNL := FALSE;
  LOOP
    IF (CurKind(tb) = TkEOL) OR (CurKind(tb) = TkColon) THEN EXIT END;
    IF IsIdent(tb, "TAB") THEN
      INC(tb.pos);
      IF CurKind(tb) = TkLP THEN INC(tb.pos) END;
      EvalExpr(tb, v); n := FLOOR(v.num);
      IF CurKind(tb) = TkRP THEN INC(tb.pos) END;
      WHILE outCol < n DO POut(" ") END
    ELSE
      EvalExpr(tb, v);
      IF errFlag THEN RETURN END;
      IF v.isStr THEN POut(v.s) ELSE NumToStr(v.num, buf); POut(buf) END
    END;
    IF CurKind(tb) = TkComma THEN
      INC(tb.pos);
      col := (outCol DIV 14 + 1) * 14;
      WHILE outCol < col DO POut(" ") END;
      suppressNL := TRUE
    ELSIF CurKind(tb) = TkSemi THEN
      INC(tb.pos); suppressNL := TRUE
    ELSE
      suppressNL := FALSE; EXIT
    END
  END;
  IF ~suppressNL THEN PNL END
END DoPrint;

(* ================================ INPUT ==================================== *)

PROCEDURE DoInput(VAR tb: TokBuf);
VAR prompt, line, name, part: STRING; fieldN: INTEGER; num: REAL; i1, i2: INTEGER; v: Value;
BEGIN
  prompt := "? ";
  IF CurKind(tb) = TkStr THEN
    Strings.Copy(tb.t[tb.pos].s, prompt); INC(tb.pos);
    Strings.Append("? ", prompt);
    IF (CurKind(tb) = TkSemi) OR (CurKind(tb) = TkComma) THEN INC(tb.pos) END
  END;
  History.ReadLine(prompt, line); outCol := 0;
  fieldN := 0;
  LOOP
    IF CurKind(tb) # TkIdent THEN EXIT END;
    Strings.Copy(tb.t[tb.pos].s, name); INC(tb.pos);
    IF ~Strings.Split(line, ',', fieldN, part) THEN part := "" END;
    Strings.Trim(part);
    INC(fieldN);
    IF CurKind(tb) = TkLP THEN
      INC(tb.pos); EvalExpr(tb, v); i1 := FLOOR(v.num); i2 := -1;
      IF CurKind(tb) = TkComma THEN INC(tb.pos); EvalExpr(tb, v); i2 := FLOOR(v.num) END;
      IF CurKind(tb) = TkRP THEN INC(tb.pos) END;
      IF IsStrName(name) THEN v := MkStr(part)
      ELSE
        IF ~Strings.StrToReal(part, num) THEN num := 0.0 END;
        v := MkNum(num)
      END;
      AssignArrayElem(name, i1, i2, v)
    ELSE
      IF IsStrName(name) THEN
        SetStr(name, part)
      ELSE
        IF ~Strings.StrToReal(part, num) THEN num := 0.0 END;
        SetNum(name, num)
      END
    END;
    IF CurKind(tb) = TkComma THEN INC(tb.pos) ELSE EXIT END
  END
END DoInput;

(* ============================== DIM / DATA ================================ *)

PROCEDURE DoDim(VAR tb: TokBuf);
VAR name: STRING; v: Value; d1, d2: INTEGER;
BEGIN
  LOOP
    IF CurKind(tb) # TkIdent THEN RtErr("SYNTAX ERROR"); RETURN END;
    Strings.Copy(tb.t[tb.pos].s, name); INC(tb.pos);
    d1 := 10; d2 := -1;
    IF CurKind(tb) = TkLP THEN
      INC(tb.pos); EvalExpr(tb, v); d1 := FLOOR(v.num);
      IF CurKind(tb) = TkComma THEN INC(tb.pos); EvalExpr(tb, v); d2 := FLOOR(v.num) END;
      IF CurKind(tb) = TkRP THEN INC(tb.pos) ELSE RtErr("MISSING )") END
    END;
    IF errFlag THEN RETURN END;
    IF DimArray(name, d1, d2) < 0 THEN RETURN END;
    IF CurKind(tb) = TkComma THEN INC(tb.pos) ELSE EXIT END
  END
END DoDim;

PROCEDURE ScanData;
VAR i: INTEGER; tb: TokBuf; v: Value; neg: BOOLEAN;
BEGIN
  nDataVals := 0; dataPtr := 0;
  FOR i := 0 TO nLines - 1 DO
    Tokenize(prog[i].text, tb);
    WHILE tb.pos < tb.n DO
      IF IsIdent(tb, "DATA") THEN
        INC(tb.pos);
        LOOP
          IF CurKind(tb) = TkStr THEN
            v := MkStr(tb.t[tb.pos].s); INC(tb.pos)
          ELSE
            neg := FALSE;
            IF IsOp(tb, "-") THEN neg := TRUE; INC(tb.pos) END;
            IF CurKind(tb) = TkNum THEN
              IF neg THEN v := MkNum(-tb.t[tb.pos].num) ELSE v := MkNum(tb.t[tb.pos].num) END;
              INC(tb.pos)
            ELSIF CurKind(tb) = TkIdent THEN
              v := MkStr(tb.t[tb.pos].s); INC(tb.pos)
            ELSE
              EXIT
            END
          END;
          IF nDataVals < MaxDataVals THEN
            dataVals[nDataVals] := v; dataLineOf[nDataVals] := prog[i].num; INC(nDataVals)
          END;
          IF CurKind(tb) = TkComma THEN INC(tb.pos) ELSE EXIT END
        END
      ELSE
        INC(tb.pos)
      END
    END
  END
END ScanData;

PROCEDURE DoRead(VAR tb: TokBuf);
VAR name: STRING; dv, idxv: Value; i1, i2: INTEGER;
BEGIN
  LOOP
    IF CurKind(tb) # TkIdent THEN EXIT END;
    Strings.Copy(tb.t[tb.pos].s, name); INC(tb.pos);
    IF dataPtr >= nDataVals THEN RtErr("OUT OF DATA"); RETURN END;
    dv := dataVals[dataPtr]; INC(dataPtr);
    IF IsStrName(name) & ~dv.isStr THEN NumToStr(dv.num, dv.s); dv.isStr := TRUE
    ELSIF ~IsStrName(name) & dv.isStr THEN
      IF ~Strings.StrToReal(dv.s, dv.num) THEN dv.num := 0.0 END; dv.isStr := FALSE
    END;
    IF CurKind(tb) = TkLP THEN
      INC(tb.pos); EvalExpr(tb, idxv); i1 := FLOOR(idxv.num); i2 := -1;
      IF CurKind(tb) = TkComma THEN INC(tb.pos); EvalExpr(tb, idxv); i2 := FLOOR(idxv.num) END;
      IF CurKind(tb) = TkRP THEN INC(tb.pos) ELSE RtErr("MISSING )") END;
      AssignArrayElem(name, i1, i2, dv)
    ELSE
      AssignScalar(name, dv)
    END;
    IF CurKind(tb) = TkComma THEN INC(tb.pos) ELSE EXIT END
  END
END DoRead;

PROCEDURE DoRestore(VAR tb: TokBuf);
VAR v: Value; target, i: INTEGER;
BEGIN
  IF CurKind(tb) = TkNum THEN
    EvalExpr(tb, v); target := FLOOR(v.num);
    i := 0;
    WHILE (i < nDataVals) & (dataLineOf[i] < target) DO INC(i) END;
    dataPtr := i
  ELSE
    dataPtr := 0
  END
END DoRestore;

(* ============================ FOR / NEXT / GOSUB ============================ *)

PROCEDURE DoFor(VAR tb: TokBuf; curLineIdx: INTEGER);
VAR name: STRING; v: Value; startv, limitv, stepv: REAL;
BEGIN
  IF CurKind(tb) # TkIdent THEN RtErr("SYNTAX ERROR"); RETURN END;
  Strings.Copy(tb.t[tb.pos].s, name); INC(tb.pos);
  IF IsOp(tb, "=") THEN INC(tb.pos) ELSE RtErr("MISSING ="); RETURN END;
  EvalExpr(tb, v); startv := v.num;
  IF IsIdent(tb, "TO") THEN INC(tb.pos) ELSE RtErr("MISSING TO"); RETURN END;
  EvalExpr(tb, v); limitv := v.num;
  stepv := 1.0;
  IF IsIdent(tb, "STEP") THEN INC(tb.pos); EvalExpr(tb, v); stepv := v.num END;
  IF errFlag THEN RETURN END;
  SetNum(name, startv);
  IF forTop >= MaxForStack THEN RtErr("FOR TOO DEEP"); RETURN END;
  Strings.Copy(name, forStack[forTop].varName);
  forStack[forTop].limit := limitv;
  forStack[forTop].step := stepv;
  forStack[forTop].lineIdx := curLineIdx;
  forStack[forTop].tokPos := tb.pos;
  INC(forTop)
END DoFor;

PROCEDURE PushGosub(lineIdx, tokPos: INTEGER);
BEGIN
  IF gosubTop >= MaxGosubStack THEN RtErr("GOSUB TOO DEEP"); RETURN END;
  gosubStack[gosubTop].lineIdx := lineIdx;
  gosubStack[gosubTop].tokPos := tokPos;
  INC(gosubTop)
END PushGosub;

PROCEDURE DoOn(VAR tb: TokBuf; curLineIdx: INTEGER; VAR jumped: BOOLEAN; VAR newLine, newTok: INTEGER);
VAR v: Value; idx, count, target, li: INTEGER; isGosub: BOOLEAN;
BEGIN
  EvalExpr(tb, v); idx := FLOOR(v.num);
  IF IsIdent(tb, "GOTO") THEN isGosub := FALSE; INC(tb.pos)
  ELSIF IsIdent(tb, "GOSUB") THEN isGosub := TRUE; INC(tb.pos)
  ELSE RtErr("SYNTAX ERROR"); RETURN END;
  count := 0; target := -1;
  LOOP
    IF CurKind(tb) # TkNum THEN EXIT END;
    count := count + 1;
    IF count = idx THEN target := FLOOR(tb.t[tb.pos].num) END;
    INC(tb.pos);
    IF CurKind(tb) = TkComma THEN INC(tb.pos) ELSE EXIT END
  END;
  IF target >= 0 THEN
    li := LineIndexOf(target);
    IF li < 0 THEN RtErr("UNDEFINED LINE"); RETURN END;
    IF isGosub THEN PushGosub(curLineIdx, tb.pos) END;
    jumped := TRUE; newLine := li; newTok := 0
  END
END DoOn;

(* ============================= CLS / LOCATE ================================ *)

PROCEDURE DoCls;
BEGIN
  IF gfxMode THEN
    Raylib.BeginTextureMode(canvas); Raylib.ClearBackground(palette[bgColorIx]); Raylib.EndTextureMode
  ELSE
    Out.Char(CHR(27)); Out.String("[2J"); Out.Char(CHR(27)); Out.String("[H"); outCol := 0
  END
END DoCls;

PROCEDURE DoLocate(VAR tb: TokBuf);
VAR v: Value; row, col: INTEGER; buf: STRING;
BEGIN
  EvalExpr(tb, v); row := FLOOR(v.num); col := 1;
  IF CurKind(tb) = TkComma THEN INC(tb.pos); EvalExpr(tb, v); col := FLOOR(v.num) END;
  IF errFlag THEN RETURN END;
  Out.Char(CHR(27)); Out.String("[");
  NumToStr(FLT(row), buf); Out.String(buf); Out.String(";");
  NumToStr(FLT(col), buf); Out.String(buf); Out.String("H")
END DoLocate;

(* ========================== graphics / sound state ========================= *)

PROCEDURE InitPalette;
BEGIN
  palette[0] := Raylib.Black();     palette[1] := Raylib.DarkBlue();
  palette[2] := Raylib.DarkGreen(); palette[3] := Raylib.DarkPurple();
  palette[4] := Raylib.Maroon();    palette[5] := Raylib.Purple();
  palette[6] := Raylib.Brown();     palette[7] := Raylib.LightGray();
  palette[8] := Raylib.Gray();      palette[9] := Raylib.Blue();
  palette[10] := Raylib.Lime();     palette[11] := Raylib.SkyBlue();
  palette[12] := Raylib.Red();      palette[13] := Raylib.Magenta();
  palette[14] := Raylib.Yellow();   palette[15] := Raylib.RayWhite()
END InitPalette;

PROCEDURE ColorOf(ix: INTEGER): INTEGER;
BEGIN
  IF ix < 0 THEN ix := 0 END;
  IF ix > 15 THEN ix := 15 END;
  RETURN palette[ix]
END ColorOf;

PROCEDURE EnsureGfx(w, h: INTEGER);
BEGIN
  IF ~gfxMode THEN
    Raylib.InitWindow(w, h, "BASIC");
    Raylib.SetTargetFPS(60);
    canvas := Raylib.LoadRenderTexture(w, h);
    winW := w; winH := h;
    InitPalette;
    curColorIx := 15; bgColorIx := 0;
    Raylib.BeginTextureMode(canvas); Raylib.ClearBackground(palette[0]); Raylib.EndTextureMode;
    gfxMode := TRUE
  END
END EnsureGfx;

PROCEDURE EnsureAudio;
BEGIN
  IF ~audioReady THEN Raylib.InitAudioDevice; audioReady := TRUE END
END EnsureAudio;

PROCEDURE Present;
BEGIN
  IF gfxMode THEN
    IF Raylib.WindowShouldClose() = 1 THEN
      progRunning := FALSE; appRunning := FALSE
    ELSE
      Raylib.BeginDrawing;
      Raylib.ClearBackground(Raylib.Black());
      Raylib.DrawRenderTexture(canvas, 0, 0, winW, winH, Raylib.White());
      Raylib.EndDrawing
    END
  END
END Present;

PROCEDURE NumArg(VAR tb: TokBuf): REAL;
VAR v: Value;
BEGIN EvalExpr(tb, v); RETURN v.num END NumArg;

PROCEDURE ExpectComma(VAR tb: TokBuf);
BEGIN
  IF CurKind(tb) = TkComma THEN INC(tb.pos) ELSE RtErr("MISSING ,") END
END ExpectComma;

PROCEDURE OptColorIx(VAR tb: TokBuf): INTEGER;
VAR v: Value;
BEGIN
  IF CurKind(tb) = TkComma THEN INC(tb.pos); EvalExpr(tb, v); RETURN FLOOR(v.num) END;
  RETURN curColorIx
END OptColorIx;

PROCEDURE DoScreen(VAR tb: TokBuf);
VAR w, h: INTEGER;
BEGIN
  w := FLOOR(NumArg(tb)); h := 480;
  IF CurKind(tb) = TkComma THEN INC(tb.pos); h := FLOOR(NumArg(tb)) END;
  IF errFlag THEN RETURN END;
  EnsureGfx(w, h)
END DoScreen;

PROCEDURE DoColor(VAR tb: TokBuf);
BEGIN
  curColorIx := FLOOR(NumArg(tb));
  IF CurKind(tb) = TkComma THEN INC(tb.pos); bgColorIx := FLOOR(NumArg(tb)) END
END DoColor;

PROCEDURE DoPset(VAR tb: TokBuf);
VAR x, y, c: INTEGER;
BEGIN
  EnsureGfx(640, 480);
  x := FLOOR(NumArg(tb)); ExpectComma(tb); y := FLOOR(NumArg(tb));
  c := OptColorIx(tb);
  IF errFlag THEN RETURN END;
  Raylib.BeginTextureMode(canvas); Raylib.DrawPixel(x, y, ColorOf(c)); Raylib.EndTextureMode
END DoPset;

PROCEDURE DoLine(VAR tb: TokBuf);
VAR x1, y1, x2, y2, c: INTEGER;
BEGIN
  EnsureGfx(640, 480);
  x1 := FLOOR(NumArg(tb)); ExpectComma(tb); y1 := FLOOR(NumArg(tb)); ExpectComma(tb);
  x2 := FLOOR(NumArg(tb)); ExpectComma(tb); y2 := FLOOR(NumArg(tb));
  c := OptColorIx(tb);
  IF errFlag THEN RETURN END;
  Raylib.BeginTextureMode(canvas); Raylib.DrawLine(x1, y1, x2, y2, ColorOf(c)); Raylib.EndTextureMode
END DoLine;

PROCEDURE DoCircle(VAR tb: TokBuf; filled: BOOLEAN);
VAR x, y, c: INTEGER; r: REAL;
BEGIN
  EnsureGfx(640, 480);
  x := FLOOR(NumArg(tb)); ExpectComma(tb); y := FLOOR(NumArg(tb)); ExpectComma(tb);
  r := NumArg(tb);
  c := OptColorIx(tb);
  IF errFlag THEN RETURN END;
  Raylib.BeginTextureMode(canvas);
  IF filled THEN Raylib.DrawCircle(x, y, r, ColorOf(c)) ELSE Raylib.DrawCircleLines(x, y, r, ColorOf(c)) END;
  Raylib.EndTextureMode
END DoCircle;

PROCEDURE DoRect(VAR tb: TokBuf; filled: BOOLEAN);
VAR x, y, w, h, c: INTEGER;
BEGIN
  EnsureGfx(640, 480);
  x := FLOOR(NumArg(tb)); ExpectComma(tb); y := FLOOR(NumArg(tb)); ExpectComma(tb);
  w := FLOOR(NumArg(tb)); ExpectComma(tb); h := FLOOR(NumArg(tb));
  c := OptColorIx(tb);
  IF errFlag THEN RETURN END;
  Raylib.BeginTextureMode(canvas);
  IF filled THEN Raylib.DrawRectangle(x, y, w, h, ColorOf(c)) ELSE Raylib.DrawRectangleLines(x, y, w, h, ColorOf(c)) END;
  Raylib.EndTextureMode
END DoRect;

PROCEDURE DoText(VAR tb: TokBuf);
VAR x, y, sz, c: INTEGER; v: Value;
BEGIN
  EnsureGfx(640, 480);
  x := FLOOR(NumArg(tb)); ExpectComma(tb); y := FLOOR(NumArg(tb)); ExpectComma(tb);
  EvalExpr(tb, v);
  IF ~v.isStr THEN NumToStr(v.num, v.s) END;
  sz := 20; c := curColorIx;
  IF CurKind(tb) = TkComma THEN INC(tb.pos); sz := FLOOR(NumArg(tb)) END;
  IF CurKind(tb) = TkComma THEN INC(tb.pos); c := FLOOR(NumArg(tb)) END;
  IF errFlag THEN RETURN END;
  Raylib.BeginTextureMode(canvas); Raylib.DrawText(v.s, x, y, sz, ColorOf(c)); Raylib.EndTextureMode
END DoText;

PROCEDURE DoSound(VAR tb: TokBuf);
VAR freq: REAL; ms: INTEGER; snd: Raylib.Sound;
BEGIN
  EnsureAudio;
  freq := NumArg(tb); ExpectComma(tb); ms := FLOOR(NumArg(tb));
  IF errFlag THEN RETURN END;
  IF ms < 0 THEN ms := 0 END;
  snd := Raylib.GenToneSound(freq, ms);
  Raylib.PlaySound(snd);
  Time.Sleep(ms);
  Raylib.UnloadSound(snd)
END DoSound;

PROCEDURE DoBeep;
VAR snd: Raylib.Sound;
BEGIN
  EnsureAudio;
  snd := Raylib.GenToneSound(800.0, 150);
  Raylib.PlaySound(snd);
  Time.Sleep(150);
  Raylib.UnloadSound(snd)
END DoBeep;

PROCEDURE DoDelay(VAR tb: TokBuf);
VAR ms: INTEGER;
BEGIN
  ms := FLOOR(NumArg(tb));
  IF errFlag THEN RETURN END;
  IF ms > 0 THEN Time.Sleep(ms) END
END DoDelay;

(* ============================ statement dispatch ============================ *)

PROCEDURE ExecStmt(VAR tb: TokBuf; curLineIdx, curLineNum: INTEGER;
                    VAR jumped: BOOLEAN; VAR newLine, newTok: INTEGER);
VAR name: STRING; v: Value; li, target: INTEGER; fe: ForEntry; ge: GosubEntry; contd: BOOLEAN;
BEGIN
  jumped := FALSE;
  IF CurKind(tb) # TkIdent THEN RtErr("SYNTAX ERROR"); RETURN END;
  Strings.Copy(tb.t[tb.pos].s, name);

  IF name = "PRINT" THEN INC(tb.pos); DoPrint(tb)
  ELSIF name = "INPUT" THEN INC(tb.pos); DoInput(tb)
  ELSIF name = "LET" THEN INC(tb.pos); DoAssign(tb)
  ELSIF name = "DIM" THEN INC(tb.pos); DoDim(tb)
  ELSIF name = "DATA" THEN tb.pos := tb.n
  ELSIF name = "READ" THEN INC(tb.pos); DoRead(tb)
  ELSIF name = "RESTORE" THEN INC(tb.pos); DoRestore(tb)
  ELSIF name = "GOTO" THEN
    INC(tb.pos); EvalExpr(tb, v); target := FLOOR(v.num);
    IF ~errFlag THEN
      li := LineIndexOf(target);
      IF li < 0 THEN RtErr("UNDEFINED LINE") ELSE jumped := TRUE; newLine := li; newTok := 0 END
    END
  ELSIF name = "GOSUB" THEN
    INC(tb.pos); EvalExpr(tb, v); target := FLOOR(v.num);
    IF ~errFlag THEN
      li := LineIndexOf(target);
      IF li < 0 THEN RtErr("UNDEFINED LINE")
      ELSE PushGosub(curLineIdx, tb.pos); jumped := TRUE; newLine := li; newTok := 0 END
    END
  ELSIF name = "RETURN" THEN
    INC(tb.pos);
    IF gosubTop <= 0 THEN RtErr("RETURN WITHOUT GOSUB")
    ELSE
      DEC(gosubTop); ge := gosubStack[gosubTop];
      jumped := TRUE; newLine := ge.lineIdx; newTok := ge.tokPos
    END
  ELSIF name = "ON" THEN INC(tb.pos); DoOn(tb, curLineIdx, jumped, newLine, newTok)
  ELSIF name = "FOR" THEN INC(tb.pos); DoFor(tb, curLineIdx)
  ELSIF name = "NEXT" THEN
    INC(tb.pos);
    IF CurKind(tb) = TkIdent THEN INC(tb.pos) END;
    IF forTop <= 0 THEN RtErr("NEXT WITHOUT FOR")
    ELSE
      fe := forStack[forTop-1];
      SetNum(fe.varName, GetNum(fe.varName) + fe.step);
      IF fe.step >= 0.0 THEN contd := GetNum(fe.varName) <= fe.limit + 1.0E-9
      ELSE contd := GetNum(fe.varName) >= fe.limit - 1.0E-9 END;
      IF contd THEN
        jumped := TRUE; newLine := fe.lineIdx; newTok := fe.tokPos
      ELSE
        DEC(forTop)
      END
    END
  ELSIF name = "IF" THEN
    INC(tb.pos); EvalExpr(tb, v);
    IF errFlag THEN RETURN END;
    IF IsIdent(tb, "THEN") THEN INC(tb.pos) END;
    IF Truthy(v) THEN
      IF CurKind(tb) = TkNum THEN
        target := FLOOR(tb.t[tb.pos].num);
        li := LineIndexOf(target);
        IF li < 0 THEN RtErr("UNDEFINED LINE") ELSE jumped := TRUE; newLine := li; newTok := 0 END
      ELSE
        ExecStmtList(tb, curLineIdx, curLineNum, jumped, newLine, newTok)
      END
    ELSE
      tb.pos := tb.n
    END
  ELSIF name = "END" THEN tb.pos := tb.n; progRunning := FALSE
  ELSIF name = "STOP" THEN tb.pos := tb.n; progRunning := FALSE
  ELSIF name = "CLS" THEN INC(tb.pos); DoCls
  ELSIF name = "HOME" THEN INC(tb.pos); DoCls
  ELSIF name = "LOCATE" THEN INC(tb.pos); DoLocate(tb)
  ELSIF name = "RANDOMIZE" THEN
    INC(tb.pos); IF CurKind(tb) # TkEOL THEN EvalExpr(tb, v) END
  ELSIF name = "SCREEN" THEN INC(tb.pos); DoScreen(tb)
  ELSIF name = "COLOR" THEN INC(tb.pos); DoColor(tb)
  ELSIF name = "PSET" THEN INC(tb.pos); DoPset(tb)
  ELSIF name = "LINE" THEN INC(tb.pos); DoLine(tb)
  ELSIF name = "CIRCLE" THEN INC(tb.pos); DoCircle(tb, FALSE)
  ELSIF name = "FCIRCLE" THEN INC(tb.pos); DoCircle(tb, TRUE)
  ELSIF name = "RECT" THEN INC(tb.pos); DoRect(tb, FALSE)
  ELSIF name = "FRECT" THEN INC(tb.pos); DoRect(tb, TRUE)
  ELSIF name = "TEXT" THEN INC(tb.pos); DoText(tb)
  ELSIF name = "SOUND" THEN INC(tb.pos); DoSound(tb)
  ELSIF name = "BEEP" THEN INC(tb.pos); DoBeep
  ELSIF name = "DELAY" THEN INC(tb.pos); DoDelay(tb)
  ELSE
    DoAssign(tb)
  END
END ExecStmt;

PROCEDURE ExecStmtList(VAR tb: TokBuf; curLineIdx, curLineNum: INTEGER;
                        VAR jumped: BOOLEAN; VAR newLine, newTok: INTEGER);
BEGIN
  jumped := FALSE;
  LOOP
    IF errFlag THEN RETURN END;
    IF CurKind(tb) = TkEOL THEN RETURN END;
    ExecStmt(tb, curLineIdx, curLineNum, jumped, newLine, newTok);
    IF errFlag OR jumped THEN RETURN END;
    IF CurKind(tb) = TkColon THEN INC(tb.pos) ELSE RETURN END
  END
END ExecStmtList;

(* =============================== run engine ================================ *)

PROCEDURE ReportError(lineNum: INTEGER);
VAR buf: STRING;
BEGIN
  PNL;
  POut("?"); POut(errMsg); POut(" ERROR");
  IF lineNum >= 0 THEN POut(" IN "); NumToStr(FLT(lineNum), buf); POut(buf) END;
  PNL;
  errFlag := FALSE
END ReportError;

PROCEDURE Execute(startLine, startTok: INTEGER);
VAR cur, tok, newLine, newTok: INTEGER; jumped: BOOLEAN; text: STRING; lineNum: INTEGER; tb: TokBuf;
BEGIN
  cur := startLine; tok := startTok; progRunning := TRUE;
  WHILE progRunning DO
    IF cur = -1 THEN
      text := immText; lineNum := -1
    ELSE
      IF (cur < 0) OR (cur >= nLines) THEN EXIT END;
      text := prog[cur].text; lineNum := prog[cur].num
    END;
    Tokenize(text, tb); tb.pos := tok;
    ExecStmtList(tb, cur, lineNum, jumped, newLine, newTok);
    IF errFlag THEN ReportError(lineNum); progRunning := FALSE; EXIT END;
    IF gfxMode THEN Present END;
    IF ~progRunning THEN EXIT END;
    IF jumped THEN cur := newLine; tok := newTok
    ELSIF cur = -1 THEN EXIT
    ELSE INC(cur); tok := 0
    END
  END
END Execute;

PROCEDURE RunProgram;
BEGIN
  ClearVars; forTop := 0; gosubTop := 0;
  ScanData;
  startTime := Time.Now();
  Execute(0, 0)
END RunProgram;

(* ============================ file load / save ============================= *)

PROCEDURE LoadFile(name: ARRAY OF CHAR): BOOLEAN;
VAR f: Files.File; r: Files.Rider; line, tok, rest: STRING; num, pos: INTEGER;
BEGIN
  f := Files.Old(name);
  IF f = NIL THEN POut("CANNOT OPEN "); POut(name); PNL; RETURN FALSE END;
  Files.Set(r, f, 0);
  nLines := 0;
  WHILE ~r.eof DO
    Files.ReadLine(r, line);
    IF Strings.Length(line) > 0 THEN
      pos := 0;
      Strings.NextWord(line, pos, tok);
      IF Strings.StrToInt(tok, num) THEN
        Strings.Extract(line, pos, Strings.Length(line) - pos, rest);
        Strings.Trim(rest);
        ExpandQuestionMarks(rest);
        InsertLine(num, rest)
      END
    END
  END;
  Files.Close(f);
  RETURN TRUE
END LoadFile;

PROCEDURE SaveFile(name: ARRAY OF CHAR): BOOLEAN;
VAR f: Files.File; r: Files.Rider; i: INTEGER; buf, line: STRING;
BEGIN
  f := Files.New(name);
  IF f = NIL THEN RETURN FALSE END;
  Files.Set(r, f, 0);
  FOR i := 0 TO nLines - 1 DO
    NumToStr(FLT(prog[i].num), buf);
    Strings.Copy(buf, line); Strings.Append(" ", line); Strings.Append(prog[i].text, line);
    Files.WriteLine(r, line)
  END;
  Files.Register(f);
  Files.Close(f);
  RETURN TRUE
END SaveFile;

PROCEDURE DoList;
VAR i: INTEGER; buf: STRING;
BEGIN
  FOR i := 0 TO nLines - 1 DO
    NumToStr(FLT(prog[i].num), buf);
    POut(buf); POut(" "); POut(prog[i].text); PNL
  END
END DoList;

(* ================================== REPL ==================================== *)

PROCEDURE StripQuotes(VAR s: ARRAY OF CHAR);
VAR n: INTEGER; tmp: STRING;
BEGIN
  n := Strings.Length(s);
  IF (n >= 2) & (s[0] = '"') & (s[n-1] = '"') THEN
    Strings.Extract(s, 1, n - 2, tmp); Strings.Copy(tmp, s)
  END
END StripQuotes;

(* '?' is shorthand for PRINT (Applesoft/GW-BASIC style). Rewrite every '?'
 * that appears outside a quoted string into "PRINT" (with a separating
 * space if it would otherwise fuse with the following identifier/number),
 * so the stored program text -- and LIST output -- always reads PRINT. *)
PROCEDURE ExpandQuestionMarks(VAR s: ARRAY OF CHAR);
VAR i, j: INTEGER; c: CHAR; inStr: BOOLEAN; buf: STRING;
BEGIN
  i := 0; j := 0; inStr := FALSE;
  WHILE (s[i] # 0X) & (j < MaxLineLen - 6) DO
    c := s[i];
    IF c = '"' THEN inStr := ~inStr END;
    IF (c = '?') & ~inStr THEN
      buf[j] := 'P'; INC(j); buf[j] := 'R'; INC(j); buf[j] := 'I'; INC(j);
      buf[j] := 'N'; INC(j); buf[j] := 'T'; INC(j);
      IF IsAlnum(s[i+1]) THEN buf[j] := ' '; INC(j) END
    ELSE
      buf[j] := c; INC(j)
    END;
    INC(i)
  END;
  buf[j] := 0X;
  Strings.Copy(buf, s)
END ExpandQuestionMarks;

PROCEDURE ShowBanner;
BEGIN
  POut("BASIC -- Raylib graphics & sound, terminal otherwise."); PNL;
  POut("Type HELP for commands, HELP topic for details, BYE to quit."); PNL
END ShowBanner;

PROCEDURE ShowHelp;
BEGIN
  POut("Commands   : RUN  LIST  NEW  LOAD file  SAVE file  CLEAR  BYE"); PNL;
  POut("Statements : PRINT(?) INPUT LET IF/THEN FOR/TO/STEP/NEXT GOTO GOSUB/RETURN"); PNL;
  POut("             ON..GOTO/GOSUB END STOP DIM DATA/READ/RESTORE CLS LOCATE"); PNL;
  POut("Graphics   : SCREEN COLOR PSET LINE CIRCLE FCIRCLE RECT FRECT TEXT"); PNL;
  POut("Sound      : SOUND BEEP DELAY"); PNL;
  POut("Type a numbered line to add/replace/delete it; anything else runs"); PNL;
  POut("immediately, e.g. PRINT 2+2 (or ? 2+2)."); PNL;
  POut("Type HELP topic for details on one item, e.g. HELP SOUND, HELP FUNCTIONS."); PNL;
  POut("Up/Down arrows recall previous input lines."); PNL
END ShowHelp;

PROCEDURE ShowHelpTopic(topic: ARRAY OF CHAR);
BEGIN
  IF (topic = "PRINT") OR ((Strings.Length(topic) = 1) & (topic[0] = '?')) THEN
    POut("PRINT expr[,expr|;expr]...        (also spelled: ? expr...)"); PNL;
    POut("  Prints values. ';' joins with no space; ',' pads to the next"); PNL;
    POut("  14-column zone. TAB(n) moves to column n. Ending in ',' or ';'"); PNL;
    POut("  suppresses the trailing newline. '?' is shorthand for PRINT and"); PNL;
    POut("  is rewritten to PRINT wherever it appears."); PNL
  ELSIF topic = "INPUT" THEN
    POut("INPUT [prompt$;] var[,var]...        (prompt$ is a quoted string)"); PNL;
    POut("  Reads a comma-separated line from the keyboard into the given"); PNL;
    POut("  variables (numeric, or string$). An optional quoted prompt is"); PNL;
    POut("  shown before the '?' prompt. Up/Down recall earlier input."); PNL
  ELSIF topic = "LET" THEN
    POut("[LET] var = expr          [LET] arr(i[,j]) = expr"); PNL;
    POut("  Assigns expr to a scalar or array variable. LET is optional."); PNL
  ELSIF (topic = "IF") OR (topic = "THEN") THEN
    POut("IF expr THEN stmt[:stmt...]        IF expr THEN linenum"); PNL;
    POut("  Runs the statement(s) after THEN, or jumps to linenum, only when"); PNL;
    POut("  expr is true (nonzero, or a non-empty string). No ELSE."); PNL
  ELSIF (topic = "FOR") OR (topic = "TO") OR (topic = "STEP") OR (topic = "NEXT") THEN
    POut("FOR var = start TO limit [STEP step]"); PNL;
    POut("  ... NEXT [var]"); PNL;
    POut("  Repeats the enclosed statements, counting var from start to"); PNL;
    POut("  limit (inclusive) by step (default 1; may be negative)."); PNL
  ELSIF topic = "GOTO" THEN
    POut("GOTO linenum"); PNL;
    POut("  Jumps to the statement at linenum."); PNL
  ELSIF (topic = "GOSUB") OR (topic = "RETURN") THEN
    POut("GOSUB linenum   ...   RETURN"); PNL;
    POut("  GOSUB jumps to linenum, remembering where it was called from;"); PNL;
    POut("  RETURN jumps back to the statement after that GOSUB."); PNL
  ELSIF topic = "ON" THEN
    POut("ON expr GOTO linenum[,linenum...]        ON expr GOSUB linenum[,...]"); PNL;
    POut("  Evaluates expr (1-based); jumps to (or GOSUBs) the linenum at"); PNL;
    POut("  that position in the list. Out-of-range values do nothing."); PNL
  ELSIF (topic = "END") OR (topic = "STOP") THEN
    POut("END        STOP"); PNL;
    POut("  Both halt the running program immediately (STOP is identical"); PNL;
    POut("  to END; it exists for compatibility)."); PNL
  ELSIF topic = "DIM" THEN
    POut("DIM name(d1[,d2])[, name(d1[,d2])...]"); PNL;
    POut("  Declares a 1- or 2-dimensional array, indices 0..d1 (and"); PNL;
    POut("  0..d2). A$ arrays hold strings; other names hold numbers."); PNL;
    POut("  Arrays are auto-created with bound 10 on first use if undimmed."); PNL
  ELSIF (topic = "DATA") OR (topic = "READ") OR (topic = "RESTORE") THEN
    POut("DATA val[,val...]      READ var[,var...]      RESTORE [linenum]"); PNL;
    POut("  DATA lists constants anywhere in the program; READ consumes"); PNL;
    POut("  them in order into variables. RESTORE resets the read pointer"); PNL;
    POut("  to the start, or to the first DATA at/after linenum."); PNL
  ELSIF (topic = "CLS") OR (topic = "HOME") THEN
    POut("CLS        HOME"); PNL;
    POut("  Clears the screen (the graphics canvas if SCREEN has been used,"); PNL;
    POut("  otherwise the terminal). CLS and HOME are identical."); PNL
  ELSIF topic = "LOCATE" THEN
    POut("LOCATE row[,col]"); PNL;
    POut("  Moves the terminal cursor to row,col (1-based) using ANSI"); PNL;
    POut("  escapes; has no effect once graphics mode is active."); PNL
  ELSIF topic = "RANDOMIZE" THEN
    POut("RANDOMIZE [expr]"); PNL;
    POut("  Reseeds the random-number generator used by RND."); PNL
  ELSIF topic = "SCREEN" THEN
    POut("SCREEN width[,height]"); PNL;
    POut("  Opens (or resizes) the graphics window, default height 480."); PNL;
    POut("  Any other graphics statement opens a 640x480 window if none"); PNL;
    POut("  is open yet, so SCREEN is only needed for a custom size."); PNL
  ELSIF topic = "COLOR" THEN
    POut("COLOR fg[,bg]"); PNL;
    POut("  Sets the current drawing color (0-15) and, optionally, the"); PNL;
    POut("  background color used by CLS."); PNL
  ELSIF topic = "PSET" THEN
    POut("PSET x,y[,color]"); PNL;
    POut("  Plots one pixel. color defaults to the current COLOR."); PNL
  ELSIF topic = "LINE" THEN
    POut("LINE x1,y1,x2,y2[,color]"); PNL;
    POut("  Draws a straight line between the two points."); PNL
  ELSIF (topic = "CIRCLE") OR (topic = "FCIRCLE") THEN
    POut("CIRCLE x,y,r[,color]        FCIRCLE x,y,r[,color]"); PNL;
    POut("  Draws a circle outline (CIRCLE) or filled disc (FCIRCLE) of"); PNL;
    POut("  radius r centered at x,y."); PNL
  ELSIF (topic = "RECT") OR (topic = "FRECT") THEN
    POut("RECT x,y,w,h[,color]        FRECT x,y,w,h[,color]"); PNL;
    POut("  Draws a rectangle outline (RECT) or filled box (FRECT), w wide"); PNL;
    POut("  and h tall, with x,y as the top-left corner."); PNL
  ELSIF topic = "TEXT" THEN
    POut("TEXT x,y,expr[,size[,color]]"); PNL;
    POut("  Draws expr (a string, or a number converted to one) at x,y."); PNL;
    POut("  size defaults to 20 pixels tall."); PNL
  ELSIF topic = "SOUND" THEN
    POut("SOUND freq,ms"); PNL;
    POut("  Plays a tone at freq Hz for ms milliseconds, blocking until it"); PNL;
    POut("  finishes. Opens the audio device on first use."); PNL
  ELSIF topic = "BEEP" THEN
    POut("BEEP"); PNL;
    POut("  Shorthand for SOUND 800,150 -- a short 800Hz beep."); PNL
  ELSIF topic = "DELAY" THEN
    POut("DELAY ms"); PNL;
    POut("  Pauses execution for ms milliseconds."); PNL
  ELSIF topic = "RUN" THEN
    POut("RUN"); PNL;
    POut("  Clears variables and runs the stored program from its lowest"); PNL;
    POut("  line number."); PNL
  ELSIF topic = "LIST" THEN
    POut("LIST"); PNL;
    POut("  Lists the stored program, in line-number order."); PNL
  ELSIF topic = "NEW" THEN
    POut("NEW"); PNL;
    POut("  Erases the stored program and all variables."); PNL
  ELSIF topic = "CLEAR" THEN
    POut("CLEAR"); PNL;
    POut("  Erases all variables and arrays, but keeps the stored program."); PNL
  ELSIF (topic = "LOAD") OR (topic = "SAVE") THEN
    POut("LOAD file        SAVE file"); PNL;
    POut("  Loads or saves the program as plain text (linenum, space,"); PNL;
    POut("  statement text per line). Quotes around file are optional."); PNL
  ELSIF (topic = "BYE") OR (topic = "QUIT") OR (topic = "EXIT") OR (topic = "SYSTEM") THEN
    POut("BYE   (aliases: QUIT, EXIT, SYSTEM)"); PNL;
    POut("  Leaves the interpreter."); PNL
  ELSIF (topic = "FUNCTIONS") OR (topic = "FUNCTION") THEN
    POut("ABS(x) INT(x) SGN(x) SQR(x) SIN/COS/TAN/ATN(x) LOG(x) EXP(x) PI"); PNL;
    POut("RND (0<=x<1) TIMER (secs since start) LEN(s$) VAL(s$) ASC(s$)"); PNL;
    POut("CHR$(n) STR$(x) LEFT$/RIGHT$(s$,n) MID$(s$,start[,len])"); PNL;
    POut("INSTR([start,]s$,find$) INKEY$ (last key pressed, or empty)"); PNL;
    POut("SCRW/SCRH (window size) MOUSEX/MOUSEY/MOUSEB (mouse state)"); PNL
  ELSE
    POut("No help for "); POut(topic); POut(". Type HELP for the topic list."); PNL
  END
END ShowHelpTopic;

PROCEDURE Shutdown;
BEGIN
  IF gfxMode THEN Raylib.UnloadRenderTexture(canvas); Raylib.CloseWindow END;
  IF audioReady THEN Raylib.CloseAudioDevice END
END Shutdown;

PROCEDURE Repl;
VAR line, cmd, arg, rest: STRING; num, pos: INTEGER;
BEGIN
  ShowBanner;
  appRunning := TRUE;
  WHILE appRunning DO
    History.ReadLine("> ", line); outCol := 0;
    Strings.Trim(line);
    IF Strings.Length(line) > 0 THEN
      pos := 0;
      Strings.NextWord(line, pos, cmd);
      IF Strings.StrToInt(cmd, num) & (num >= 0) THEN
        Strings.Extract(line, pos, Strings.Length(line) - pos, rest);
        Strings.Trim(rest);
        ExpandQuestionMarks(rest);
        InsertLine(num, rest)
      ELSE
        Upper(cmd);
        IF cmd = "RUN" THEN RunProgram
        ELSIF cmd = "LIST" THEN DoList
        ELSIF cmd = "NEW" THEN nLines := 0; ClearVars
        ELSIF cmd = "CLEAR" THEN ClearVars
        ELSIF cmd = "HELP" THEN
          Strings.Extract(line, pos, Strings.Length(line) - pos, arg); Strings.Trim(arg);
          Upper(arg);
          IF Strings.Length(arg) = 0 THEN ShowHelp ELSE ShowHelpTopic(arg) END
        ELSIF (cmd = "BYE") OR (cmd = "QUIT") OR (cmd = "EXIT") OR (cmd = "SYSTEM") THEN
          appRunning := FALSE
        ELSIF cmd = "LOAD" THEN
          Strings.Extract(line, pos, Strings.Length(line) - pos, arg); Strings.Trim(arg);
          StripQuotes(arg);
          IF LoadFile(arg) THEN POut("LOADED"); PNL END
        ELSIF cmd = "SAVE" THEN
          Strings.Extract(line, pos, Strings.Length(line) - pos, arg); Strings.Trim(arg);
          StripQuotes(arg);
          IF SaveFile(arg) THEN POut("SAVED"); PNL ELSE POut("SAVE FAILED"); PNL END
        ELSE
          ExpandQuestionMarks(line);
          Strings.Copy(line, immText);
          startTime := Time.Now();
          Execute(-1, 0)
        END
      END
    END
  END
END Repl;

BEGIN
  nLines := 0; nNumVars := 0; nStrVars := 0; nArrays := 0;
  forTop := 0; gosubTop := 0; nDataVals := 0; dataPtr := 0;
  errFlag := FALSE; gfxMode := FALSE; audioReady := FALSE; outCol := 0;
  progRunning := TRUE; appRunning := TRUE;
  startTime := Time.Now();
  IF Args.Count() >= 1 THEN
    Args.Get(1, fname);
    IF LoadFile(fname) THEN RunProgram END
  ELSE
    Repl
  END;
  Shutdown
END Basic.
