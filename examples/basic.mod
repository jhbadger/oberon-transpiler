MODULE Basic;
(*
 * A line-numbered BASIC interpreter (GW-BASIC / Applesoft flavor) with
 * Raylib-backed graphics and sound statements bolted on.
 *
 * Internal design: a small bytecode VM. Each program line is tokenized
 * and compiled to bytecode exactly once (whenever the program is edited),
 * instead of being re-tokenized and re-parsed by a recursive-descent
 * evaluator on every single execution. GOTO/GOSUB/FOR-NEXT/IF are all
 * compiled to direct jumps within one flat instruction stream (main
 * program lines, DEFN function bodies, and the current immediate-mode
 * line all share one instruction array, in different regions), so loops
 * run as tight PC-based jumps with no re-lexing and no re-parsing of
 * expressions. Variable/array storage is unchanged from the original
 * design (linear-scan symbol tables) since that was not the bottleneck.
 *
 * User-defined functions:
 *   DEFN name[$](p1[,p2...])
 *     <statements>
 *     RETURN expr        (optional; last one wins, or fall off end)
 *   ENDFN
 *
 * Call as an expression:   y = square(5)
 * Or as a statement:       greet("world")   (result, if any, discarded)
 *
 * DEFN blocks may be placed anywhere in the program (they are compiled
 * separately from the main-line code and skipped over by it) or entered
 * directly at the REPL (define across several prompt lines; you'll be
 * re-prompted until ENDFN closes the definition).
 *)

IMPORT Out, Strings, Random, Math, Time, Files, Args, Raylib, History, OS;

CONST
  MaxLines      = 4000;
  MaxLineLen    = 240;
  MaxTok        = 160;
  MaxScalarNum  = 800;
  MaxScalarStr  = 400;
  MaxArrays     = 100;
  MaxArrNumCap  = 40000;
  MaxStrArrCap  = 2000;
  MaxForStack   = 40;
  MaxGosubStack = 60;
  MaxDataVals   = 4000;

  MaxFuncs      = 128;
  MaxFuncParams = 8;
  MaxCallDepth  = 32;

  MaxWhileStack   = 40;
  MaxOpenFiles    = 16;
  MaxAppendLines  = 4000;

  (* token kinds *)
  TkEOL = 0; TkNum = 1; TkStr = 2; TkIdent = 3; TkOp = 4;
  TkLP = 5; TkRP = 6; TkComma = 7; TkColon = 8; TkSemi = 9;
  TkHash = 10;

  (* bytecode: one flat instruction stream. [0,MainCodeCap) holds the
   * compiled main program (and DEFN function bodies, appended after the
   * main lines); [MainCodeCap,MaxCode) is scratch space recompiled fresh
   * for each immediate-mode ("direct") command, so GOTO/GOSUB from an
   * immediate-mode line can still jump into real program lines by PC. *)
  ScratchCap  = 4000;
  MaxCode     = 240000;
  MainCodeCap = MaxCode - ScratchCap;

  MaxNames         = 3000;
  MaxNumPool       = 20000;
  MaxStrPool       = 4000;
  MaxOnTargets     = 2000;
  MaxGotoBackpatch = 8000;
  MaxLineFixups    = 64;
  MaxValStack      = 512;

  (* opcodes *)
  opPushNum = 0; opPushStr = 1; opLoadVar = 2; opLoadArr = 3;
  opStoreVar = 4; opStoreArr = 5; opPop = 6;
  opNeg = 7; opNot = 8; opAdd = 9; opSub = 10; opMul = 11; opDiv = 12;
  opMod = 13; opPow = 14;
  opEq = 15; opNe = 16; opLt = 17; opLe = 18; opGt = 19; opGe = 20;
  opAndOp = 21; opOrOp = 22;
  opCallBuiltinFunc = 23; opCallUserFuncExpr = 24; opCallUserFuncStmt = 25;
  opJump = 26; opJumpIfFalse = 27;
  opGoto = 28; opGotoDyn = 29; opGosub = 30; opGosubDyn = 31;
  opGosubReturn = 32; opFuncReturn = 33;
  opForInit = 34; opForNext = 35; opOnGoto = 36; opOnGosub = 37;
  opEnd = 38; opLine = 39;
  opPrintVal = 40; opPrintTab = 41; opPrintComma = 42; opPrintNL = 43;
  opInputBegin = 44; opInputVar = 45; opInputArr = 46;
  opDim = 47; opReadVar = 48; opReadArr = 49; opRestore = 50;
  opCls = 51; opLocate = 52; opRandomize = 53; opScreen = 54; opColor = 55;
  opPset = 56; opDrawLine = 57; opCircle = 58; opRect = 59; opText = 60;
  opSound = 61; opBeep = 62; opDelay = 63;
  opOpen = 64; opCloseFile = 65; opPrintFileBegin = 66; opInputFileBegin = 67;
  opLineInputFile = 68; opFiles = 69;

  (* builtin function ids *)
  bfAbs=0; bfInt=1; bfSgn=2; bfSqr=3; bfSin=4; bfCos=5; bfTan=6; bfAtn=7;
  bfLog=8; bfExp=9; bfPi=10; bfRnd=11; bfTimer=12; bfLen=13; bfVal=14;
  bfAsc=15; bfChr=16; bfStr=17; bfLeft=18; bfRight=19; bfMid=20;
  bfInstr=21; bfInkey=22; bfScrw=23; bfScrh=24; bfMousex=25; bfMousey=26;
  bfMouseb=27; bfEof=28;

TYPE
  Token = RECORD
    kind : INTEGER;
    num  : REAL;
    s    : STRING
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
    dims    : INTEGER;
    d1, d2  : INTEGER;
    numData : NumArrPtr;
    strData : StrArrData
  END;

  ForEntry = RECORD
    varName  : STRING;
    limit    : REAL;
    step     : REAL;
    loopTopPc: INTEGER
  END;

  GosubEntry = RECORD
    returnPc : INTEGER
  END;

  WhileEntry = RECORD
    condPc : INTEGER;
    jfPc   : INTEGER
  END;

  FileSlot = RECORD
    inUse   : BOOLEAN;
    isInput : BOOLEAN;
    f       : Files.File;
    r       : Files.Rider
  END;

  FuncDef = POINTER TO FuncDefRec;
  FuncDefRec = RECORD
    name      : STRING;             (* uppercased, includes trailing $ if str *)
    isStr     : BOOLEAN;
    nParams   : INTEGER;
    params    : ARRAY MaxFuncParams OF STRING;
    paramIsStr: ARRAY MaxFuncParams OF BOOLEAN;
    entryPc   : INTEGER;
    bodyStart : INTEGER;             (* prog[] index range of the body *)
    bodyEnd   : INTEGER
  END;

  NumSnap = POINTER TO NumSnapRec;
  NumSnapRec = RECORD n: INTEGER; e: ARRAY MaxScalarNum OF ScalarNum END;
  StrSnap = POINTER TO StrSnapRec;
  StrSnapRec = RECORD n: INTEGER; e: ARRAY MaxScalarStr OF ScalarStr END;

  CallFrame = RECORD
    returnPc      : INTEGER;
    savedForTop   : INTEGER;
    savedGosubTop : INTEGER;
    funcIdx       : INTEGER;
    ns            : NumSnap;
    ss            : StrSnap;
    wantValue     : BOOLEAN
  END;

  Instr = RECORD op, a, b: INTEGER END;

VAR
  prog     : ARRAY MaxLines OF ProgLine;
  nLines   : INTEGER;

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

  whileStack : ARRAY MaxWhileStack OF WhileEntry;
  whileTop   : INTEGER;

  fileSlots       : ARRAY MaxOpenFiles + 1 OF FileSlot;
  filePrintTarget : INTEGER;
  filePrintBuf    : STRING;
  appendBuf       : ARRAY MaxAppendLines OF STRING;

  dataVals    : ARRAY MaxDataVals OF Value;
  dataLineOf  : ARRAY MaxDataVals OF INTEGER;
  nDataVals   : INTEGER;
  dataPtr     : INTEGER;

  funcs   : ARRAY MaxFuncs OF FuncDef;
  nFuncs  : INTEGER;

  callStack : ARRAY MaxCallDepth OF CallFrame;
  callTop   : INTEGER;

  errFlag : BOOLEAN;
  errMsg  : STRING;

  progRunning : BOOLEAN;
  appRunning  : BOOLEAN;
  fname       : STRING;

  outCol : INTEGER;

  gfxMode    : BOOLEAN;
  audioReady : BOOLEAN;
  canvas     : Raylib.RenderTexture;
  winW, winH : INTEGER;
  palette    : ARRAY 16 OF INTEGER;
  curColorIx : INTEGER;
  bgColorIx  : INTEGER;
  startTime  : LONGINT;

  (* ---- compiler + VM state ---- *)
  code       : ARRAY MaxCode OF Instr;
  codeLen    : INTEGER;
  codeLimit  : INTEGER;
  lineStartPc: ARRAY MaxLines OF INTEGER;

  namePool  : ARRAY MaxNames OF STRING; nNames  : INTEGER;
  numPool   : ARRAY MaxNumPool OF REAL; nNumPool: INTEGER;
  strPool   : ARRAY MaxStrPool OF STRING; nStrPool: INTEGER;

  onTargets      : ARRAY MaxOnTargets OF INTEGER; nOnTargets: INTEGER;
  gotoBackpatch  : ARRAY MaxGotoBackpatch OF INTEGER; nGotoBackpatch: INTEGER;
  lineFixups     : ARRAY MaxLineFixups OF INTEGER; nLineFixups: INTEGER;

  compInFunc : BOOLEAN;
  firstCompileErrMsg  : STRING;
  firstCompileErrLine : INTEGER;

  valStack : ARRAY MaxValStack OF Value;
  sp       : INTEGER;

  currentLineNum : INTEGER;

  inputLine    : STRING;
  inputFieldN  : INTEGER;

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
    ELSIF c = "'" THEN EXIT
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
    ELSIF c = '#' THEN AddTok(tb, TkHash); INC(i)
    ELSE INC(i)
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

PROCEDURE PeekIsBareLineNumber(VAR tb: TokBuf): BOOLEAN;
BEGIN
  RETURN (CurKind(tb) = TkNum) &
         ((tb.t[tb.pos+1].kind = TkColon) OR (tb.t[tb.pos+1].kind = TkEOL))
END PeekIsBareLineNumber;

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

(* ========================== user function table ========================= *)

PROCEDURE FindFunc(name: ARRAY OF CHAR): INTEGER;
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE i < nFuncs DO
    IF funcs[i].name = name THEN RETURN i END;
    INC(i)
  END;
  RETURN -1
END FindFunc;

PROCEDURE ClearFuncs;
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO nFuncs - 1 DO funcs[i] := NIL END;
  nFuncs := 0
END ClearFuncs;

PROCEDURE ParseDefnHeader(header: ARRAY OF CHAR; fd: FuncDef): BOOLEAN;
VAR tb: TokBuf; pname: STRING;
BEGIN
  Tokenize(header, tb);
  IF ~IsIdent(tb, "DEFN") THEN RETURN FALSE END;
  INC(tb.pos);
  IF CurKind(tb) # TkIdent THEN RtErr("DEFN: EXPECTED NAME"); RETURN FALSE END;
  Strings.Copy(tb.t[tb.pos].s, fd.name); INC(tb.pos);
  fd.isStr := IsStrName(fd.name);
  fd.nParams := 0;
  IF CurKind(tb) = TkLP THEN
    INC(tb.pos);
    IF CurKind(tb) # TkRP THEN
      LOOP
        IF CurKind(tb) # TkIdent THEN RtErr("DEFN: BAD PARAM"); RETURN FALSE END;
        IF fd.nParams >= MaxFuncParams THEN RtErr("DEFN: TOO MANY PARAMS"); RETURN FALSE END;
        Strings.Copy(tb.t[tb.pos].s, pname);
        Strings.Copy(pname, fd.params[fd.nParams]);
        fd.paramIsStr[fd.nParams] := IsStrName(pname);
        INC(fd.nParams);
        INC(tb.pos);
        IF CurKind(tb) = TkComma THEN INC(tb.pos) ELSE EXIT END
      END
    END;
    IF CurKind(tb) = TkRP THEN INC(tb.pos) ELSE RtErr("DEFN: MISSING )"); RETURN FALSE END
  END;
  fd.entryPc := -1;
  RETURN TRUE
END ParseDefnHeader;

PROCEDURE FirstWord(s: ARRAY OF CHAR; VAR w: ARRAY OF CHAR);
VAR i, j: INTEGER;
BEGIN
  i := 0; j := 0;
  WHILE (s[i] = ' ') OR (s[i] = 09X) DO INC(i) END;
  WHILE IsAlnum(s[i]) & (j < 15) DO w[j] := s[i]; INC(i); INC(j) END;
  w[j] := 0X;
  Upper(w)
END FirstWord;

PROCEDURE IsDefnLine(s: ARRAY OF CHAR): BOOLEAN;
VAR w: STRING;
BEGIN FirstWord(s, w); RETURN w = "DEFN" END IsDefnLine;

PROCEDURE IsEndfnLine(s: ARRAY OF CHAR): BOOLEAN;
VAR w: STRING;
BEGIN FirstWord(s, w); RETURN w = "ENDFN" END IsEndfnLine;

(* Return TRUE if line i in the program is inside (or is) a DEFN/ENDFN
 * pair, and set skipTo to the index just past ENDFN. Used to skip over
 * embedded function bodies during main-line compilation / DATA scanning. *)
PROCEDURE IsFuncBodyLine(i: INTEGER; VAR skipTo: INTEGER): BOOLEAN;
VAR k: INTEGER;
BEGIN
  IF (i < 0) OR (i >= nLines) THEN RETURN FALSE END;
  IF IsDefnLine(prog[i].text) THEN
    k := i + 1;
    WHILE (k < nLines) & ~IsEndfnLine(prog[k].text) DO INC(k) END;
    IF k < nLines THEN skipTo := k + 1 ELSE skipTo := nLines END;
    RETURN TRUE
  END;
  RETURN FALSE
END IsFuncBodyLine;

(* ============================ value helpers ============================== *)

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
       OR (name = "EOF")
END IsFuncName;

PROCEDURE NameToBuiltinId(name: ARRAY OF CHAR): INTEGER;
BEGIN
  IF name = "ABS" THEN RETURN bfAbs
  ELSIF name = "INT" THEN RETURN bfInt
  ELSIF name = "SGN" THEN RETURN bfSgn
  ELSIF name = "SQR" THEN RETURN bfSqr
  ELSIF name = "SIN" THEN RETURN bfSin
  ELSIF name = "COS" THEN RETURN bfCos
  ELSIF name = "TAN" THEN RETURN bfTan
  ELSIF name = "ATN" THEN RETURN bfAtn
  ELSIF name = "LOG" THEN RETURN bfLog
  ELSIF name = "EXP" THEN RETURN bfExp
  ELSIF name = "PI" THEN RETURN bfPi
  ELSIF name = "RND" THEN RETURN bfRnd
  ELSIF name = "TIMER" THEN RETURN bfTimer
  ELSIF name = "LEN" THEN RETURN bfLen
  ELSIF name = "VAL" THEN RETURN bfVal
  ELSIF name = "ASC" THEN RETURN bfAsc
  ELSIF name = "CHR$" THEN RETURN bfChr
  ELSIF name = "STR$" THEN RETURN bfStr
  ELSIF name = "LEFT$" THEN RETURN bfLeft
  ELSIF name = "RIGHT$" THEN RETURN bfRight
  ELSIF name = "MID$" THEN RETURN bfMid
  ELSIF name = "INSTR" THEN RETURN bfInstr
  ELSIF name = "INKEY$" THEN RETURN bfInkey
  ELSIF name = "SCRW" THEN RETURN bfScrw
  ELSIF name = "SCRH" THEN RETURN bfScrh
  ELSIF name = "MOUSEX" THEN RETURN bfMousex
  ELSIF name = "MOUSEY" THEN RETURN bfMousey
  ELSIF name = "MOUSEB" THEN RETURN bfMouseb
  ELSIF name = "EOF" THEN RETURN bfEof
  ELSE RETURN -1
  END
END NameToBuiltinId;

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

(* ============================ value stack ================================ *)

PROCEDURE Push(v: Value);
BEGIN
  IF sp < MaxValStack THEN valStack[sp] := v; INC(sp) ELSE RtErr("EXPRESSION TOO COMPLEX") END
END Push;

PROCEDURE Pop(VAR v: Value);
BEGIN
  IF sp > 0 THEN DEC(sp); v := valStack[sp] ELSE RtErr("STACK UNDERFLOW"); v := MkNum(0.0) END
END Pop;

(* ====================== snapshot / restore of scalars ==================== *)

PROCEDURE SnapshotScalars(VAR ns: NumSnap; VAR ss: StrSnap);
VAR i: INTEGER;
BEGIN
  NEW(ns); NEW(ss);
  ns.n := nNumVars; ss.n := nStrVars;
  FOR i := 0 TO nNumVars - 1 DO ns.e[i] := numVars[i] END;
  FOR i := 0 TO nStrVars - 1 DO ss.e[i] := strVars[i] END
END SnapshotScalars;

PROCEDURE RestoreScalars(ns: NumSnap; ss: StrSnap);
VAR i: INTEGER;
BEGIN
  nNumVars := ns.n; nStrVars := ss.n;
  FOR i := 0 TO nNumVars - 1 DO numVars[i] := ns.e[i] END;
  FOR i := 0 TO nStrVars - 1 DO strVars[i] := ss.e[i] END
END RestoreScalars;

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

(* =============================== builtins ================================ *)

PROCEDURE RunBuiltinFunc(bf, argc: INTEGER);
VAR a1, a2, a3, v: Value; n: INTEGER; buf: STRING; hasA3: BOOLEAN;
BEGIN
  a1 := MkNum(0.0); a2 := MkNum(0.0); a3 := MkNum(0.0); hasA3 := FALSE;
  IF argc >= 3 THEN Pop(a3); hasA3 := TRUE END;
  IF argc >= 2 THEN Pop(a2) END;
  IF argc >= 1 THEN Pop(a1) END;

  IF bf = bfAbs THEN v := MkNum(ABS(a1.num))
  ELSIF bf = bfInt THEN v := MkNum(FLT(FLOOR(a1.num)))
  ELSIF bf = bfSgn THEN
    IF a1.num > 0.0 THEN v := MkNum(1.0)
    ELSIF a1.num < 0.0 THEN v := MkNum(-1.0)
    ELSE v := MkNum(0.0) END
  ELSIF bf = bfSqr THEN v := MkNum(Math.sqrt(a1.num))
  ELSIF bf = bfSin THEN v := MkNum(Math.sin(a1.num))
  ELSIF bf = bfCos THEN v := MkNum(Math.cos(a1.num))
  ELSIF bf = bfTan THEN v := MkNum(Math.tan(a1.num))
  ELSIF bf = bfAtn THEN v := MkNum(Math.arctan(a1.num))
  ELSIF bf = bfLog THEN v := MkNum(Math.ln(a1.num))
  ELSIF bf = bfExp THEN v := MkNum(Math.exp(a1.num))
  ELSIF bf = bfPi THEN v := MkNum(Math.pi)
  ELSIF bf = bfRnd THEN v := MkNum(Random.Real())
  ELSIF bf = bfTimer THEN v := MkNum(ElapsedSecs())
  ELSIF bf = bfLen THEN v := MkNum(FLT(Strings.Length(a1.s)))
  ELSIF bf = bfVal THEN
    IF ~Strings.StrToReal(a1.s, v.num) THEN v.num := 0.0 END;
    v.isStr := FALSE; v.s := ""
  ELSIF bf = bfAsc THEN
    IF Strings.Length(a1.s) > 0 THEN v := MkNum(FLT(ORD(a1.s[0]))) ELSE v := MkNum(0.0) END
  ELSIF bf = bfChr THEN
    buf[0] := CHR(FLOOR(a1.num)); buf[1] := 0X; v := MkStr(buf)
  ELSIF bf = bfStr THEN
    NumToStr(a1.num, buf); v := MkStr(buf)
  ELSIF bf = bfLeft THEN
    n := FLOOR(a2.num); IF n < 0 THEN n := 0 END;
    IF n > Strings.Length(a1.s) THEN n := Strings.Length(a1.s) END;
    Strings.Extract(a1.s, 0, n, buf); v := MkStr(buf)
  ELSIF bf = bfRight THEN
    n := FLOOR(a2.num); IF n < 0 THEN n := 0 END;
    IF n > Strings.Length(a1.s) THEN n := Strings.Length(a1.s) END;
    Strings.Extract(a1.s, Strings.Length(a1.s) - n, n, buf); v := MkStr(buf)
  ELSIF bf = bfMid THEN
    n := FLOOR(a2.num) - 1; IF n < 0 THEN n := 0 END;
    IF ~hasA3 THEN a3.num := FLT(Strings.Length(a1.s)) END;
    IF n > Strings.Length(a1.s) THEN n := Strings.Length(a1.s) END;
    IF n + FLOOR(a3.num) > Strings.Length(a1.s) THEN a3.num := FLT(Strings.Length(a1.s) - n) END;
    IF a3.num < 0.0 THEN a3.num := 0.0 END;
    Strings.Extract(a1.s, n, FLOOR(a3.num), buf); v := MkStr(buf)
  ELSIF bf = bfInstr THEN
    IF hasA3 THEN v := MkNum(FLT(Strings.Pos(a3.s, a1.s, FLOOR(a2.num) - 1) + 1))
    ELSE v := MkNum(FLT(Strings.Pos(a2.s, a1.s) + 1)) END
  ELSIF bf = bfInkey THEN
    ReadInkey(buf); v := MkStr(buf)
  ELSIF bf = bfScrw THEN v := MkNum(FLT(winW))
  ELSIF bf = bfScrh THEN v := MkNum(FLT(winH))
  ELSIF bf = bfMousex THEN
    IF gfxMode THEN v := MkNum(FLT(Raylib.GetMouseX())) ELSE v := MkNum(0.0) END
  ELSIF bf = bfMousey THEN
    IF gfxMode THEN v := MkNum(FLT(Raylib.GetMouseY())) ELSE v := MkNum(0.0) END
  ELSIF bf = bfMouseb THEN
    IF gfxMode & (Raylib.IsMouseButtonDown(Raylib.BtnLeft) = 1) THEN v := MkNum(-1.0) ELSE v := MkNum(0.0) END
  ELSIF bf = bfEof THEN
    n := FLOOR(a1.num);
    IF (n >= 1) & (n <= MaxOpenFiles) & fileSlots[n].inUse THEN
      (* Prospective check (pos vs length) rather than the rider's own .eof
       * flag, which only turns true after a read has already come back
       * empty -- using it here would make WHILE NOT EOF(n) ... WEND loops
       * process one spurious empty record at the end of every file. *)
      IF Files.Pos(fileSlots[n].r) >= Files.Length(fileSlots[n].f) THEN v := MkNum(-1.0)
      ELSE v := MkNum(0.0) END
    ELSE v := MkNum(-1.0) END
  ELSE
    RtErr("UNKNOWN FUNCTION"); v := MkNum(0.0)
  END;
  Push(v)
END RunBuiltinFunc;

(* ======================= graphics / sound state + ops ==================== *)

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

PROCEDURE MaybePresent;
BEGIN
  IF gfxMode THEN Present END
END MaybePresent;

PROCEDURE DoCls;
BEGIN
  IF gfxMode THEN
    Raylib.BeginTextureMode(canvas); Raylib.ClearBackground(palette[bgColorIx]); Raylib.EndTextureMode
  ELSE
    Out.Char(CHR(27)); Out.String("[2J"); Out.Char(CHR(27)); Out.String("[H"); outCol := 0
  END
END DoCls;

PROCEDURE VmLocate(row, col: INTEGER);
VAR buf: STRING;
BEGIN
  Out.Char(CHR(27)); Out.String("[");
  NumToStr(FLT(row), buf); Out.String(buf); Out.String(";");
  NumToStr(FLT(col), buf); Out.String(buf); Out.String("H")
END VmLocate;

PROCEDURE VmPset(x, y, c: INTEGER);
BEGIN
  EnsureGfx(640, 480);
  Raylib.BeginTextureMode(canvas); Raylib.DrawPixel(x, y, ColorOf(c)); Raylib.EndTextureMode
END VmPset;

PROCEDURE VmLine(x1, y1, x2, y2, c: INTEGER);
BEGIN
  EnsureGfx(640, 480);
  Raylib.BeginTextureMode(canvas); Raylib.DrawLine(x1, y1, x2, y2, ColorOf(c)); Raylib.EndTextureMode
END VmLine;

PROCEDURE VmCircle(x, y, c: INTEGER; r: REAL; filled: BOOLEAN);
BEGIN
  EnsureGfx(640, 480);
  Raylib.BeginTextureMode(canvas);
  IF filled THEN Raylib.DrawCircle(x, y, r, ColorOf(c)) ELSE Raylib.DrawCircleLines(x, y, r, ColorOf(c)) END;
  Raylib.EndTextureMode
END VmCircle;

PROCEDURE VmRect(x, y, w, h, c: INTEGER; filled: BOOLEAN);
BEGIN
  EnsureGfx(640, 480);
  Raylib.BeginTextureMode(canvas);
  IF filled THEN Raylib.DrawRectangle(x, y, w, h, ColorOf(c)) ELSE Raylib.DrawRectangleLines(x, y, w, h, ColorOf(c)) END;
  Raylib.EndTextureMode
END VmRect;

PROCEDURE VmText(x, y, sz, c: INTEGER; s: ARRAY OF CHAR);
BEGIN
  EnsureGfx(640, 480);
  Raylib.BeginTextureMode(canvas); Raylib.DrawText(s, x, y, sz, ColorOf(c)); Raylib.EndTextureMode
END VmText;

PROCEDURE VmSound(freq: REAL; ms: INTEGER);
VAR snd: Raylib.Sound;
BEGIN
  EnsureAudio;
  IF ms < 0 THEN ms := 0 END;
  snd := Raylib.GenToneSound(freq, ms);
  Raylib.PlaySound(snd);
  Time.Sleep(ms);
  Raylib.UnloadSound(snd)
END VmSound;

PROCEDURE VmBeep;
VAR snd: Raylib.Sound;
BEGIN
  EnsureAudio;
  snd := Raylib.GenToneSound(800.0, 150);
  Raylib.PlaySound(snd);
  Time.Sleep(150);
  Raylib.UnloadSound(snd)
END VmBeep;

PROCEDURE VmDelay(ms: INTEGER);
BEGIN
  IF ms > 0 THEN Time.Sleep(ms) END
END VmDelay;

(* =========================== compiler: pools ============================= *)

PROCEDURE InternName(s: ARRAY OF CHAR): INTEGER;
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO nNames - 1 DO
    IF namePool[i] = s THEN RETURN i END
  END;
  IF nNames >= MaxNames THEN RtErr("TOO MANY NAMES"); RETURN 0 END;
  Strings.Copy(s, namePool[nNames]);
  i := nNames; INC(nNames); RETURN i
END InternName;

PROCEDURE AddNumConst(x: REAL): INTEGER;
VAR i: INTEGER;
BEGIN
  IF nNumPool >= MaxNumPool THEN RtErr("PROGRAM TOO LARGE"); RETURN 0 END;
  numPool[nNumPool] := x; i := nNumPool; INC(nNumPool); RETURN i
END AddNumConst;

PROCEDURE AddStrConst(s: ARRAY OF CHAR): INTEGER;
VAR i: INTEGER;
BEGIN
  IF nStrPool >= MaxStrPool THEN RtErr("PROGRAM TOO LARGE"); RETURN 0 END;
  Strings.Copy(s, strPool[nStrPool]); i := nStrPool; INC(nStrPool); RETURN i
END AddStrConst;

PROCEDURE Emit(op, a, b: INTEGER);
BEGIN
  IF codeLen < codeLimit THEN
    code[codeLen].op := op; code[codeLen].a := a; code[codeLen].b := b;
    INC(codeLen)
  ELSE
    RtErr("PROGRAM TOO LARGE")
  END
END Emit;

PROCEDURE AddLineFixup(pcIdx: INTEGER);
BEGIN
  IF nLineFixups < MaxLineFixups THEN
    lineFixups[nLineFixups] := pcIdx; INC(nLineFixups)
  ELSE
    RtErr("STATEMENT TOO COMPLEX")
  END
END AddLineFixup;

PROCEDURE ResolveLineFixups(target: INTEGER);
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO nLineFixups - 1 DO code[lineFixups[i]].a := target END;
  nLineFixups := 0
END ResolveLineFixups;

PROCEDURE AddGotoBackpatch(pcIdx: INTEGER);
BEGIN
  IF nGotoBackpatch < MaxGotoBackpatch THEN
    gotoBackpatch[nGotoBackpatch] := pcIdx; INC(nGotoBackpatch)
  ELSE
    RtErr("PROGRAM TOO LARGE")
  END
END AddGotoBackpatch;

PROCEDURE BackpatchGotosFrom(start: INTEGER);
VAR i, pos: INTEGER;
BEGIN
  FOR i := start TO nGotoBackpatch - 1 DO
    IF FindLinePos(code[gotoBackpatch[i]].a, pos) THEN
      code[gotoBackpatch[i]].a := lineStartPc[pos]
    ELSE
      code[gotoBackpatch[i]].a := -1
    END
  END
END BackpatchGotosFrom;

PROCEDURE BackpatchOnTargetsFrom(start: INTEGER);
VAR i, pos: INTEGER;
BEGIN
  FOR i := start TO nOnTargets - 1 DO
    IF FindLinePos(onTargets[i], pos) THEN onTargets[i] := lineStartPc[pos] ELSE onTargets[i] := -1 END
  END
END BackpatchOnTargetsFrom;

(* ======================= compiler: expressions ============================ *)

PROCEDURE CompileExpr(VAR tb: TokBuf);
BEGIN CompileOr(tb) END CompileExpr;

PROCEDURE CompileOr(VAR tb: TokBuf);
BEGIN
  CompileAnd(tb);
  WHILE IsIdent(tb, "OR") DO INC(tb.pos); CompileAnd(tb); Emit(opOrOp, 0, 0) END
END CompileOr;

PROCEDURE CompileAnd(VAR tb: TokBuf);
BEGIN
  CompileNot(tb);
  WHILE IsIdent(tb, "AND") DO INC(tb.pos); CompileNot(tb); Emit(opAndOp, 0, 0) END
END CompileAnd;

PROCEDURE CompileNot(VAR tb: TokBuf);
BEGIN
  IF IsIdent(tb, "NOT") THEN INC(tb.pos); CompileNot(tb); Emit(opNot, 0, 0)
  ELSE CompileRel(tb) END
END CompileNot;

PROCEDURE CompileRel(VAR tb: TokBuf);
VAR opc: INTEGER; matched: BOOLEAN;
BEGIN
  CompileAdd(tb);
  matched := TRUE; opc := opEq;
  IF IsOp(tb, "=") THEN opc := opEq
  ELSIF IsOp(tb, "<>") THEN opc := opNe
  ELSIF IsOp(tb, "<=") THEN opc := opLe
  ELSIF IsOp(tb, ">=") THEN opc := opGe
  ELSIF IsOp(tb, "<") THEN opc := opLt
  ELSIF IsOp(tb, ">") THEN opc := opGt
  ELSE matched := FALSE
  END;
  IF matched THEN INC(tb.pos); CompileAdd(tb); Emit(opc, 0, 0) END
END CompileRel;

PROCEDURE CompileAdd(VAR tb: TokBuf);
BEGIN
  CompileMul(tb);
  LOOP
    IF IsOp(tb, "+") THEN INC(tb.pos); CompileMul(tb); Emit(opAdd, 0, 0)
    ELSIF IsOp(tb, "-") THEN INC(tb.pos); CompileMul(tb); Emit(opSub, 0, 0)
    ELSE EXIT END
  END
END CompileAdd;

PROCEDURE CompileMul(VAR tb: TokBuf);
BEGIN
  CompileUnary(tb);
  LOOP
    IF IsOp(tb, "*") THEN INC(tb.pos); CompileUnary(tb); Emit(opMul, 0, 0)
    ELSIF IsOp(tb, "/") THEN INC(tb.pos); CompileUnary(tb); Emit(opDiv, 0, 0)
    ELSIF IsIdent(tb, "MOD") THEN INC(tb.pos); CompileUnary(tb); Emit(opMod, 0, 0)
    ELSE EXIT END
  END
END CompileMul;

PROCEDURE CompileUnary(VAR tb: TokBuf);
BEGIN
  IF IsOp(tb, "-") THEN INC(tb.pos); CompileUnary(tb); Emit(opNeg, 0, 0)
  ELSIF IsOp(tb, "+") THEN INC(tb.pos); CompileUnary(tb)
  ELSE CompilePow(tb) END
END CompileUnary;

PROCEDURE CompilePow(VAR tb: TokBuf);
BEGIN
  CompilePrimary(tb);
  IF IsOp(tb, "^") THEN INC(tb.pos); CompileUnary(tb); Emit(opPow, 0, 0) END
END CompilePow;

PROCEDURE CompileBuiltinCall(name: ARRAY OF CHAR; VAR tb: TokBuf);
VAR bf, argc: INTEGER;
BEGIN
  bf := NameToBuiltinId(name); argc := 0;
  IF CurKind(tb) = TkLP THEN
    INC(tb.pos);
    IF CurKind(tb) # TkRP THEN
      CompileExpr(tb); argc := 1;
      IF CurKind(tb) = TkComma THEN
        INC(tb.pos); CompileExpr(tb); argc := 2;
        IF CurKind(tb) = TkComma THEN INC(tb.pos); CompileExpr(tb); argc := 3 END
      END
    END;
    IF CurKind(tb) = TkRP THEN INC(tb.pos) ELSE RtErr("MISSING )") END
  END;
  Emit(opCallBuiltinFunc, bf, argc)
END CompileBuiltinCall;

PROCEDURE CompileUserFuncCall(fi: INTEGER; wantValue: BOOLEAN; VAR tb: TokBuf);
VAR n: INTEGER; fd: FuncDef;
BEGIN
  fd := funcs[fi]; n := 0;
  IF CurKind(tb) = TkLP THEN
    INC(tb.pos);
    IF CurKind(tb) # TkRP THEN
      LOOP
        IF n >= fd.nParams THEN RtErr("TOO MANY ARGS"); RETURN END;
        CompileExpr(tb); INC(n);
        IF CurKind(tb) = TkComma THEN INC(tb.pos) ELSE EXIT END
      END
    END;
    IF CurKind(tb) = TkRP THEN INC(tb.pos) ELSE RtErr("MISSING )"); RETURN END
  END;
  IF n # fd.nParams THEN RtErr("WRONG ARG COUNT"); RETURN END;
  IF wantValue THEN Emit(opCallUserFuncExpr, fi, n) ELSE Emit(opCallUserFuncStmt, fi, n) END
END CompileUserFuncCall;

PROCEDURE CompilePrimary(VAR tb: TokBuf);
VAR name: STRING; fi, dims: INTEGER;
BEGIN
  IF CurKind(tb) = TkNum THEN
    Emit(opPushNum, AddNumConst(tb.t[tb.pos].num), 0); INC(tb.pos)
  ELSIF CurKind(tb) = TkStr THEN
    Emit(opPushStr, AddStrConst(tb.t[tb.pos].s), 0); INC(tb.pos)
  ELSIF CurKind(tb) = TkLP THEN
    INC(tb.pos); CompileExpr(tb);
    IF CurKind(tb) = TkRP THEN INC(tb.pos) ELSE RtErr("MISSING )") END
  ELSIF CurKind(tb) = TkIdent THEN
    Strings.Copy(tb.t[tb.pos].s, name); INC(tb.pos);
    IF IsFuncName(name) THEN
      CompileBuiltinCall(name, tb)
    ELSE
      fi := FindFunc(name);
      IF (fi >= 0) & (CurKind(tb) = TkLP) THEN
        CompileUserFuncCall(fi, TRUE, tb)
      ELSIF CurKind(tb) = TkLP THEN
        INC(tb.pos); CompileExpr(tb); dims := 1;
        IF CurKind(tb) = TkComma THEN INC(tb.pos); CompileExpr(tb); dims := 2 END;
        IF CurKind(tb) = TkRP THEN INC(tb.pos) ELSE RtErr("MISSING )") END;
        Emit(opLoadArr, InternName(name), dims)
      ELSE
        Emit(opLoadVar, InternName(name), 0)
      END
    END
  ELSE
    RtErr("SYNTAX ERROR")
  END
END CompilePrimary;

(* ========================= compiler: statements ============================ *)

PROCEDURE CompileAssign(VAR tb: TokBuf);
VAR name: STRING; dims: INTEGER;
BEGIN
  IF CurKind(tb) # TkIdent THEN RtErr("SYNTAX ERROR"); RETURN END;
  Strings.Copy(tb.t[tb.pos].s, name); INC(tb.pos);
  IF CurKind(tb) = TkLP THEN
    INC(tb.pos); CompileExpr(tb); dims := 1;
    IF CurKind(tb) = TkComma THEN INC(tb.pos); CompileExpr(tb); dims := 2 END;
    IF CurKind(tb) = TkRP THEN INC(tb.pos) ELSE RtErr("MISSING )"); RETURN END;
    IF IsOp(tb, "=") THEN INC(tb.pos) ELSE RtErr("MISSING ="); RETURN END;
    CompileExpr(tb);
    Emit(opStoreArr, InternName(name), dims)
  ELSE
    IF IsOp(tb, "=") THEN INC(tb.pos) ELSE RtErr("SYNTAX ERROR"); RETURN END;
    CompileExpr(tb);
    Emit(opStoreVar, InternName(name), 0)
  END
END CompileAssign;

PROCEDURE CompilePrint(VAR tb: TokBuf);
VAR trailing: BOOLEAN;
BEGIN
  trailing := FALSE;
  IF CurKind(tb) = TkHash THEN
    INC(tb.pos); CompileExpr(tb); Emit(opPrintFileBegin, 0, 0);
    IF CurKind(tb) = TkComma THEN INC(tb.pos) END
  END;
  LOOP
    IF (CurKind(tb) = TkEOL) OR (CurKind(tb) = TkColon) THEN EXIT END;
    IF IsIdent(tb, "TAB") THEN
      INC(tb.pos);
      IF CurKind(tb) = TkLP THEN INC(tb.pos) END;
      CompileExpr(tb);
      IF CurKind(tb) = TkRP THEN INC(tb.pos) END;
      Emit(opPrintTab, 0, 0)
    ELSE
      CompileExpr(tb);
      Emit(opPrintVal, 0, 0)
    END;
    IF CurKind(tb) = TkComma THEN
      INC(tb.pos); Emit(opPrintComma, 0, 0); trailing := TRUE
    ELSIF CurKind(tb) = TkSemi THEN
      INC(tb.pos); trailing := TRUE
    ELSE
      trailing := FALSE; EXIT
    END
  END;
  IF ~trailing THEN Emit(opPrintNL, 0, 0) END
END CompilePrint;

PROCEDURE CompileInput(VAR tb: TokBuf);
VAR name: STRING; promptIdx, dims: INTEGER;
BEGIN
  IF CurKind(tb) = TkHash THEN
    INC(tb.pos); CompileExpr(tb); Emit(opInputFileBegin, 0, 0);
    IF CurKind(tb) = TkComma THEN INC(tb.pos) END
  ELSE
    IF CurKind(tb) = TkStr THEN
      promptIdx := AddStrConst(tb.t[tb.pos].s); INC(tb.pos);
      IF (CurKind(tb) = TkSemi) OR (CurKind(tb) = TkComma) THEN INC(tb.pos) END
    ELSE
      promptIdx := -1
    END;
    Emit(opInputBegin, promptIdx, 0)
  END;
  LOOP
    IF CurKind(tb) # TkIdent THEN EXIT END;
    Strings.Copy(tb.t[tb.pos].s, name); INC(tb.pos);
    IF CurKind(tb) = TkLP THEN
      INC(tb.pos); CompileExpr(tb); dims := 1;
      IF CurKind(tb) = TkComma THEN INC(tb.pos); CompileExpr(tb); dims := 2 END;
      IF CurKind(tb) = TkRP THEN INC(tb.pos) ELSE RtErr("MISSING )") END;
      Emit(opInputArr, InternName(name), dims)
    ELSE
      Emit(opInputVar, InternName(name), 0)
    END;
    IF CurKind(tb) = TkComma THEN INC(tb.pos) ELSE EXIT END
  END
END CompileInput;

PROCEDURE CompileDim(VAR tb: TokBuf);
VAR name: STRING; dims: INTEGER;
BEGIN
  LOOP
    IF CurKind(tb) # TkIdent THEN RtErr("SYNTAX ERROR"); RETURN END;
    Strings.Copy(tb.t[tb.pos].s, name); INC(tb.pos);
    dims := 0;
    IF CurKind(tb) = TkLP THEN
      INC(tb.pos); CompileExpr(tb); dims := 1;
      IF CurKind(tb) = TkComma THEN INC(tb.pos); CompileExpr(tb); dims := 2 END;
      IF CurKind(tb) = TkRP THEN INC(tb.pos) ELSE RtErr("MISSING )") END
    END;
    Emit(opDim, InternName(name), dims);
    IF CurKind(tb) = TkComma THEN INC(tb.pos) ELSE EXIT END
  END
END CompileDim;

PROCEDURE CompileRead(VAR tb: TokBuf);
VAR name: STRING; dims: INTEGER;
BEGIN
  LOOP
    IF CurKind(tb) # TkIdent THEN EXIT END;
    Strings.Copy(tb.t[tb.pos].s, name); INC(tb.pos);
    IF CurKind(tb) = TkLP THEN
      INC(tb.pos); CompileExpr(tb); dims := 1;
      IF CurKind(tb) = TkComma THEN INC(tb.pos); CompileExpr(tb); dims := 2 END;
      IF CurKind(tb) = TkRP THEN INC(tb.pos) ELSE RtErr("MISSING )") END;
      Emit(opReadArr, InternName(name), dims)
    ELSE
      Emit(opReadVar, InternName(name), 0)
    END;
    IF CurKind(tb) = TkComma THEN INC(tb.pos) ELSE EXIT END
  END
END CompileRead;

PROCEDURE CompileRestore(VAR tb: TokBuf);
BEGIN
  IF CurKind(tb) = TkNum THEN
    CompileExpr(tb); Emit(opRestore, 1, 0)
  ELSE
    Emit(opRestore, 0, 0)
  END
END CompileRestore;

PROCEDURE CompileGoto(VAR tb: TokBuf);
VAR lineNum, pcIdx: INTEGER;
BEGIN
  IF PeekIsBareLineNumber(tb) THEN
    lineNum := FLOOR(tb.t[tb.pos].num); INC(tb.pos);
    IF ~compInFunc THEN
      pcIdx := codeLen; Emit(opGoto, lineNum, 0); AddGotoBackpatch(pcIdx)
    END
  ELSE
    CompileExpr(tb);
    IF compInFunc THEN Emit(opPop, 0, 0) ELSE Emit(opGotoDyn, 0, 0) END
  END
END CompileGoto;

PROCEDURE CompileGosub(VAR tb: TokBuf);
VAR lineNum, pcIdx: INTEGER;
BEGIN
  IF PeekIsBareLineNumber(tb) THEN
    lineNum := FLOOR(tb.t[tb.pos].num); INC(tb.pos);
    IF ~compInFunc THEN
      pcIdx := codeLen; Emit(opGosub, lineNum, 0); AddGotoBackpatch(pcIdx)
    END
  ELSE
    CompileExpr(tb);
    IF compInFunc THEN Emit(opPop, 0, 0) ELSE Emit(opGosubDyn, 0, 0) END
  END
END CompileGosub;

PROCEDURE CompileReturn(VAR tb: TokBuf);
VAR hasExpr: BOOLEAN;
BEGIN
  IF compInFunc THEN
    hasExpr := (CurKind(tb) # TkEOL) & (CurKind(tb) # TkColon);
    IF hasExpr THEN CompileExpr(tb); Emit(opFuncReturn, 1, 0)
    ELSE Emit(opFuncReturn, 0, 0) END
  ELSE
    Emit(opGosubReturn, 0, 0)
  END
END CompileReturn;

PROCEDURE CompileOn(VAR tb: TokBuf);
VAR isGosub: BOOLEAN; startIdx, count, lineNum: INTEGER;
BEGIN
  CompileExpr(tb);
  IF IsIdent(tb, "GOTO") THEN isGosub := FALSE; INC(tb.pos)
  ELSIF IsIdent(tb, "GOSUB") THEN isGosub := TRUE; INC(tb.pos)
  ELSE RtErr("SYNTAX ERROR"); RETURN END;
  IF compInFunc THEN
    Emit(opPop, 0, 0);
    LOOP
      IF CurKind(tb) # TkNum THEN EXIT END;
      INC(tb.pos);
      IF CurKind(tb) = TkComma THEN INC(tb.pos) ELSE EXIT END
    END
  ELSE
    startIdx := nOnTargets; count := 0;
    LOOP
      IF CurKind(tb) # TkNum THEN EXIT END;
      lineNum := FLOOR(tb.t[tb.pos].num); INC(tb.pos);
      IF nOnTargets < MaxOnTargets THEN
        onTargets[nOnTargets] := lineNum; INC(nOnTargets); INC(count)
      ELSE RtErr("PROGRAM TOO LARGE") END;
      IF CurKind(tb) = TkComma THEN INC(tb.pos) ELSE EXIT END
    END;
    IF isGosub THEN Emit(opOnGosub, startIdx, count) ELSE Emit(opOnGoto, startIdx, count) END
  END
END CompileOn;

PROCEDURE CompileFor(VAR tb: TokBuf);
VAR name: STRING;
BEGIN
  IF CurKind(tb) # TkIdent THEN RtErr("SYNTAX ERROR"); RETURN END;
  Strings.Copy(tb.t[tb.pos].s, name); INC(tb.pos);
  IF IsOp(tb, "=") THEN INC(tb.pos) ELSE RtErr("MISSING ="); RETURN END;
  CompileExpr(tb);
  IF IsIdent(tb, "TO") THEN INC(tb.pos) ELSE RtErr("MISSING TO"); RETURN END;
  CompileExpr(tb);
  IF IsIdent(tb, "STEP") THEN INC(tb.pos); CompileExpr(tb)
  ELSE Emit(opPushNum, AddNumConst(1.0), 0) END;
  Emit(opForInit, InternName(name), 0)
END CompileFor;

(* WHILE/WEND compile to a compile-time-matched pair of jumps (no runtime
 * stack needed, unlike FOR/NEXT): WHILE tests the condition and remembers
 * both the top-of-loop PC (for WEND's backward jump) and the PC of the
 * JumpIfFalse to backpatch once WEND's location is known. Matching is by
 * simple LIFO nesting order in source, since lines compile strictly in
 * program order. *)
PROCEDURE CompileWhile(VAR tb: TokBuf);
BEGIN
  IF whileTop >= MaxWhileStack THEN RtErr("WHILE TOO DEEP"); RETURN END;
  whileStack[whileTop].condPc := codeLen;
  CompileExpr(tb);
  whileStack[whileTop].jfPc := codeLen;
  Emit(opJumpIfFalse, 0, 0);
  INC(whileTop)
END CompileWhile;

PROCEDURE CompileWend(VAR tb: TokBuf);
BEGIN
  IF whileTop <= 0 THEN RtErr("WEND WITHOUT WHILE"); RETURN END;
  DEC(whileTop);
  Emit(opJump, whileStack[whileTop].condPc, 0);
  code[whileStack[whileTop].jfPc].a := codeLen
END CompileWend;

(* Compiles one branch (THEN or ELSE) of an IF: either a bare line number
 * (compiled to a GOTO, a no-op inside a function body since line-number
 * targets aren't meaningful there) or a colon-separated statement list
 * running to EOL or a following ELSE. *)
PROCEDURE CompileIfBranch(VAR tb: TokBuf);
VAR lineNum, gotoIdx: INTEGER;
BEGIN
  IF CurKind(tb) = TkNum THEN
    lineNum := FLOOR(tb.t[tb.pos].num); INC(tb.pos);
    IF ~compInFunc THEN
      gotoIdx := codeLen; Emit(opGoto, lineNum, 0); AddGotoBackpatch(gotoIdx)
    END
  ELSE
    CompileStmtSeq(tb)
  END
END CompileIfBranch;

PROCEDURE CompileIf(VAR tb: TokBuf);
VAR fixIdx, elseJumpIdx: INTEGER;
BEGIN
  INC(tb.pos);
  CompileExpr(tb);
  IF IsIdent(tb, "THEN") THEN INC(tb.pos) END;
  fixIdx := codeLen; Emit(opJumpIfFalse, 0, 0);
  CompileIfBranch(tb);
  IF IsIdent(tb, "ELSE") THEN
    INC(tb.pos);
    elseJumpIdx := codeLen; Emit(opJump, 0, 0);
    code[fixIdx].a := codeLen;
    CompileIfBranch(tb);
    code[elseJumpIdx].a := codeLen
  ELSE
    AddLineFixup(fixIdx)
  END
END CompileIf;

PROCEDURE CompileExpectComma(VAR tb: TokBuf);
BEGIN
  IF CurKind(tb) = TkComma THEN INC(tb.pos) ELSE RtErr("MISSING ,") END
END CompileExpectComma;

PROCEDURE CompileOptColor(VAR tb: TokBuf; VAR argc: INTEGER);
BEGIN
  IF CurKind(tb) = TkComma THEN INC(tb.pos); CompileExpr(tb); INC(argc) END
END CompileOptColor;

PROCEDURE CompileLocate(VAR tb: TokBuf);
VAR argc: INTEGER;
BEGIN
  CompileExpr(tb); argc := 1;
  IF CurKind(tb) = TkComma THEN INC(tb.pos); CompileExpr(tb); argc := 2 END;
  Emit(opLocate, argc, 0)
END CompileLocate;

PROCEDURE CompileRandomize(VAR tb: TokBuf);
BEGIN
  IF (CurKind(tb) # TkEOL) & (CurKind(tb) # TkColon) THEN
    CompileExpr(tb); Emit(opRandomize, 1, 0)
  ELSE
    Emit(opRandomize, 0, 0)
  END
END CompileRandomize;

PROCEDURE CompileScreen(VAR tb: TokBuf);
VAR argc: INTEGER;
BEGIN
  CompileExpr(tb); argc := 1;
  IF CurKind(tb) = TkComma THEN INC(tb.pos); CompileExpr(tb); argc := 2 END;
  Emit(opScreen, argc, 0)
END CompileScreen;

PROCEDURE CompileColor(VAR tb: TokBuf);
VAR argc: INTEGER;
BEGIN
  CompileExpr(tb); argc := 1;
  IF CurKind(tb) = TkComma THEN INC(tb.pos); CompileExpr(tb); argc := 2 END;
  Emit(opColor, argc, 0)
END CompileColor;

PROCEDURE CompilePset(VAR tb: TokBuf);
VAR argc: INTEGER;
BEGIN
  CompileExpr(tb); CompileExpectComma(tb); CompileExpr(tb); argc := 2;
  CompileOptColor(tb, argc);
  Emit(opPset, argc, 0)
END CompilePset;

PROCEDURE CompileDrawLine(VAR tb: TokBuf);
VAR argc: INTEGER;
BEGIN
  CompileExpr(tb); CompileExpectComma(tb); CompileExpr(tb); CompileExpectComma(tb);
  CompileExpr(tb); CompileExpectComma(tb); CompileExpr(tb); argc := 4;
  CompileOptColor(tb, argc);
  Emit(opDrawLine, argc, 0)
END CompileDrawLine;

PROCEDURE CompileCircle(VAR tb: TokBuf; filled: BOOLEAN);
VAR argc, f: INTEGER;
BEGIN
  CompileExpr(tb); CompileExpectComma(tb); CompileExpr(tb); CompileExpectComma(tb);
  CompileExpr(tb); argc := 3;
  CompileOptColor(tb, argc);
  IF filled THEN f := 1 ELSE f := 0 END;
  Emit(opCircle, f, argc)
END CompileCircle;

PROCEDURE CompileRect(VAR tb: TokBuf; filled: BOOLEAN);
VAR argc, f: INTEGER;
BEGIN
  CompileExpr(tb); CompileExpectComma(tb); CompileExpr(tb); CompileExpectComma(tb);
  CompileExpr(tb); CompileExpectComma(tb); CompileExpr(tb); argc := 4;
  CompileOptColor(tb, argc);
  IF filled THEN f := 1 ELSE f := 0 END;
  Emit(opRect, f, argc)
END CompileRect;

PROCEDURE CompileText(VAR tb: TokBuf);
VAR argc: INTEGER;
BEGIN
  CompileExpr(tb); CompileExpectComma(tb); CompileExpr(tb); CompileExpectComma(tb);
  CompileExpr(tb); argc := 3;
  IF CurKind(tb) = TkComma THEN
    INC(tb.pos); CompileExpr(tb); INC(argc);
    IF CurKind(tb) = TkComma THEN INC(tb.pos); CompileExpr(tb); INC(argc) END
  END;
  Emit(opText, argc, 0)
END CompileText;

PROCEDURE CompileSound(VAR tb: TokBuf);
BEGIN
  CompileExpr(tb); CompileExpectComma(tb); CompileExpr(tb);
  Emit(opSound, 0, 0)
END CompileSound;

PROCEDURE CompileDelay(VAR tb: TokBuf);
BEGIN
  CompileExpr(tb); Emit(opDelay, 0, 0)
END CompileDelay;

(* OPEN name$ FOR INPUT|OUTPUT|APPEND AS #n *)
PROCEDURE CompileOpen(VAR tb: TokBuf);
VAR mode: INTEGER;
BEGIN
  CompileExpr(tb);
  IF IsIdent(tb, "FOR") THEN INC(tb.pos) ELSE RtErr("MISSING FOR"); RETURN END;
  IF IsIdent(tb, "INPUT") THEN mode := 0; INC(tb.pos)
  ELSIF IsIdent(tb, "OUTPUT") THEN mode := 1; INC(tb.pos)
  ELSIF IsIdent(tb, "APPEND") THEN mode := 2; INC(tb.pos)
  ELSE RtErr("BAD OPEN MODE"); RETURN END;
  IF IsIdent(tb, "AS") THEN INC(tb.pos) ELSE RtErr("MISSING AS"); RETURN END;
  IF CurKind(tb) = TkHash THEN INC(tb.pos) END;
  CompileExpr(tb);
  Emit(opOpen, mode, 0)
END CompileOpen;

(* CLOSE [#]n[,[#]n...]   CLOSE (no args) closes every open file *)
PROCEDURE CompileClose(VAR tb: TokBuf);
VAR hasArg: BOOLEAN;
BEGIN
  hasArg := FALSE;
  IF CurKind(tb) = TkHash THEN INC(tb.pos) END;
  IF (CurKind(tb) # TkEOL) & (CurKind(tb) # TkColon) THEN
    CompileExpr(tb); hasArg := TRUE;
    WHILE CurKind(tb) = TkComma DO
      Emit(opCloseFile, 1, 0);
      INC(tb.pos);
      IF CurKind(tb) = TkHash THEN INC(tb.pos) END;
      CompileExpr(tb)
    END
  END;
  IF hasArg THEN Emit(opCloseFile, 1, 0) ELSE Emit(opCloseFile, 0, 0) END
END CompileClose;

(* LINE INPUT #n, var$  -- reads one whole line, no comma-splitting *)
PROCEDURE CompileLineInput(VAR tb: TokBuf);
VAR name: STRING;
BEGIN
  IF CurKind(tb) = TkHash THEN INC(tb.pos) ELSE RtErr("MISSING #"); RETURN END;
  CompileExpr(tb);
  IF CurKind(tb) = TkComma THEN INC(tb.pos) END;
  IF CurKind(tb) # TkIdent THEN RtErr("SYNTAX ERROR"); RETURN END;
  Strings.Copy(tb.t[tb.pos].s, name); INC(tb.pos);
  Emit(opLineInputFile, InternName(name), 0)
END CompileLineInput;

PROCEDURE CompileFiles(VAR tb: TokBuf);
BEGIN
  IF (CurKind(tb) # TkEOL) & (CurKind(tb) # TkColon) THEN
    CompileExpr(tb); Emit(opFiles, 1, 0)
  ELSE
    Emit(opFiles, 0, 0)
  END
END CompileFiles;

PROCEDURE CompileStmt(VAR tb: TokBuf);
VAR name: STRING; fi: INTEGER;
BEGIN
  IF CurKind(tb) # TkIdent THEN RtErr("SYNTAX ERROR"); RETURN END;
  Strings.Copy(tb.t[tb.pos].s, name);

  IF name = "PRINT" THEN INC(tb.pos); CompilePrint(tb)
  ELSIF name = "INPUT" THEN INC(tb.pos); CompileInput(tb)
  ELSIF name = "LET" THEN INC(tb.pos); CompileAssign(tb)
  ELSIF name = "DIM" THEN INC(tb.pos); CompileDim(tb)
  ELSIF name = "DATA" THEN tb.pos := tb.n
  ELSIF name = "READ" THEN INC(tb.pos); CompileRead(tb)
  ELSIF name = "RESTORE" THEN INC(tb.pos); CompileRestore(tb)
  ELSIF name = "GOTO" THEN INC(tb.pos); CompileGoto(tb)
  ELSIF name = "GOSUB" THEN INC(tb.pos); CompileGosub(tb)
  ELSIF name = "RETURN" THEN INC(tb.pos); CompileReturn(tb)
  ELSIF name = "ON" THEN INC(tb.pos); CompileOn(tb)
  ELSIF name = "FOR" THEN INC(tb.pos); CompileFor(tb)
  ELSIF name = "NEXT" THEN
    INC(tb.pos);
    IF CurKind(tb) = TkIdent THEN INC(tb.pos) END;
    Emit(opForNext, 0, 0)
  ELSIF name = "IF" THEN CompileIf(tb)
  ELSIF name = "WHILE" THEN INC(tb.pos); CompileWhile(tb)
  ELSIF name = "WEND" THEN INC(tb.pos); CompileWend(tb)
  ELSIF name = "END" THEN tb.pos := tb.n; Emit(opEnd, 0, 0)
  ELSIF name = "STOP" THEN tb.pos := tb.n; Emit(opEnd, 0, 0)
  ELSIF name = "CLS" THEN INC(tb.pos); Emit(opCls, 0, 0)
  ELSIF name = "HOME" THEN INC(tb.pos); Emit(opCls, 0, 0)
  ELSIF name = "LOCATE" THEN INC(tb.pos); CompileLocate(tb)
  ELSIF name = "RANDOMIZE" THEN INC(tb.pos); CompileRandomize(tb)
  ELSIF name = "SCREEN" THEN INC(tb.pos); CompileScreen(tb)
  ELSIF name = "COLOR" THEN INC(tb.pos); CompileColor(tb)
  ELSIF name = "PSET" THEN INC(tb.pos); CompilePset(tb)
  ELSIF name = "LINE" THEN
    INC(tb.pos);
    IF IsIdent(tb, "INPUT") THEN INC(tb.pos); CompileLineInput(tb)
    ELSE CompileDrawLine(tb) END
  ELSIF name = "CIRCLE" THEN INC(tb.pos); CompileCircle(tb, FALSE)
  ELSIF name = "FCIRCLE" THEN INC(tb.pos); CompileCircle(tb, TRUE)
  ELSIF name = "RECT" THEN INC(tb.pos); CompileRect(tb, FALSE)
  ELSIF name = "FRECT" THEN INC(tb.pos); CompileRect(tb, TRUE)
  ELSIF name = "TEXT" THEN INC(tb.pos); CompileText(tb)
  ELSIF name = "SOUND" THEN INC(tb.pos); CompileSound(tb)
  ELSIF name = "BEEP" THEN INC(tb.pos); Emit(opBeep, 0, 0)
  ELSIF name = "DELAY" THEN INC(tb.pos); CompileDelay(tb)
  ELSIF name = "OPEN" THEN INC(tb.pos); CompileOpen(tb)
  ELSIF name = "CLOSE" THEN INC(tb.pos); CompileClose(tb)
  ELSIF name = "FILES" THEN INC(tb.pos); CompileFiles(tb)
  ELSIF (name = "DEFN") OR (name = "ENDFN") THEN
    tb.pos := tb.n
  ELSE
    fi := FindFunc(name);
    IF (fi >= 0) & (tb.pos + 1 < tb.n) & (tb.t[tb.pos + 1].kind = TkLP) THEN
      INC(tb.pos); CompileUserFuncCall(fi, FALSE, tb)
    ELSE
      CompileAssign(tb)
    END
  END
END CompileStmt;

(* ===================== compiler: lines / program / functions ============== *)

(* Compiles a colon-separated run of statements up to EOL. Used both for a
 * whole program line and for the "then" part of "IF cond THEN stmt[:stmt]",
 * which is not itself preceded by a colon. *)
PROCEDURE CompileStmtSeq(VAR tb: TokBuf);
BEGIN
  WHILE (CurKind(tb) # TkEOL) & ~errFlag DO
    CompileStmt(tb);
    IF errFlag THEN EXIT END;
    IF CurKind(tb) = TkColon THEN INC(tb.pos) ELSE EXIT END
  END
END CompileStmtSeq;

PROCEDURE CompileLineBody(text: ARRAY OF CHAR; lineNum: INTEGER);
VAR tb: TokBuf; savedCodeLen, savedGBP, savedOT, savedWT: INTEGER;
BEGIN
  savedCodeLen := codeLen; savedGBP := nGotoBackpatch; savedOT := nOnTargets;
  savedWT := whileTop;
  nLineFixups := 0;
  Emit(opLine, lineNum, 0);
  Tokenize(text, tb); tb.pos := 0;
  CompileStmtSeq(tb);
  IF errFlag THEN
    IF Strings.Length(firstCompileErrMsg) = 0 THEN
      Strings.Copy(errMsg, firstCompileErrMsg); firstCompileErrLine := lineNum
    END;
    errFlag := FALSE;
    codeLen := savedCodeLen; nGotoBackpatch := savedGBP; nOnTargets := savedOT;
    whileTop := savedWT;
    nLineFixups := 0
  ELSE
    ResolveLineFixups(codeLen)
  END
END CompileLineBody;

PROCEDURE CompileFunctionBody(fd: FuncDef);
VAR i: INTEGER;
BEGIN
  compInFunc := TRUE;
  whileTop := 0;
  fd.entryPc := codeLen;
  FOR i := fd.bodyStart TO fd.bodyEnd - 1 DO
    CompileLineBody(prog[i].text, prog[i].num)
  END;
  Emit(opFuncReturn, 0, 0);
  compInFunc := FALSE
END CompileFunctionBody;

PROCEDURE CompileProgram;
VAR i, k, j, skipTo: INTEGER; fd: FuncDef; ok: BOOLEAN;
BEGIN
  codeLen := 0; codeLimit := MainCodeCap;
  nNames := 0; nNumPool := 0; nStrPool := 0; nOnTargets := 0; nGotoBackpatch := 0;
  errFlag := FALSE; errMsg := "";
  firstCompileErrMsg := ""; firstCompileErrLine := -1;
  compInFunc := FALSE;
  whileTop := 0;
  ClearFuncs;

  (* phase 1: register function headers (so forward references resolve) *)
  i := 0;
  WHILE i < nLines DO
    IF IsDefnLine(prog[i].text) THEN
      NEW(fd);
      ok := ParseDefnHeader(prog[i].text, fd);
      fd.bodyStart := i + 1;
      k := i + 1;
      WHILE (k < nLines) & ~IsEndfnLine(prog[k].text) DO INC(k) END;
      fd.bodyEnd := k;
      IF k >= nLines THEN RtErr("DEFN WITHOUT ENDFN"); ok := FALSE END;
      errFlag := FALSE;
      IF ok THEN
        j := FindFunc(fd.name);
        IF j >= 0 THEN funcs[j] := fd
        ELSIF nFuncs < MaxFuncs THEN funcs[nFuncs] := fd; INC(nFuncs)
        ELSE RtErr("TOO MANY FUNCTIONS"); errFlag := FALSE
        END
      END;
      IF k < nLines THEN i := k + 1 ELSE i := nLines END
    ELSE
      INC(i)
    END
  END;

  (* phase 2: compile main-line code, skipping DEFN..ENDFN spans *)
  i := 0;
  WHILE i < nLines DO
    IF IsFuncBodyLine(i, skipTo) THEN
      i := skipTo
    ELSE
      lineStartPc[i] := codeLen;
      CompileLineBody(prog[i].text, prog[i].num);
      INC(i)
    END
  END;
  Emit(opEnd, 0, 0);

  (* phase 3: compile each function body *)
  FOR i := 0 TO nFuncs - 1 DO CompileFunctionBody(funcs[i]) END;

  (* phase 4: resolve literal line-number jump targets to PCs *)
  BackpatchGotosFrom(0);
  BackpatchOnTargetsFrom(0);

  IF Strings.Length(firstCompileErrMsg) > 0 THEN
    errFlag := TRUE;
    Strings.Copy(firstCompileErrMsg, errMsg);
    currentLineNum := firstCompileErrLine
  ELSE
    errFlag := FALSE
  END
END CompileProgram;

PROCEDURE CompileImmediate(text: ARRAY OF CHAR; VAR startPc: INTEGER; VAR ok: BOOLEAN);
VAR tb: TokBuf; savedGBP, savedOT, savedWT: INTEGER;
BEGIN
  codeLen := MainCodeCap; codeLimit := MaxCode;
  compInFunc := FALSE;
  whileTop := 0;
  errFlag := FALSE; errMsg := "";
  savedGBP := nGotoBackpatch; savedOT := nOnTargets; savedWT := whileTop;
  nLineFixups := 0;
  startPc := codeLen;
  Tokenize(text, tb); tb.pos := 0;
  CompileStmtSeq(tb);
  IF errFlag THEN
    ok := FALSE;
    nGotoBackpatch := savedGBP; nOnTargets := savedOT; whileTop := savedWT
  ELSE
    ok := TRUE;
    ResolveLineFixups(codeLen);
    Emit(opEnd, 0, 0);
    BackpatchGotosFrom(savedGBP);
    BackpatchOnTargetsFrom(savedOT)
  END
END CompileImmediate;

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

PROCEDURE VMNextDataValue(name: ARRAY OF CHAR; VAR v: Value): BOOLEAN;
BEGIN
  IF dataPtr >= nDataVals THEN RtErr("OUT OF DATA"); RETURN FALSE END;
  v := dataVals[dataPtr]; INC(dataPtr);
  IF IsStrName(name) & ~v.isStr THEN NumToStr(v.num, v.s); v.isStr := TRUE
  ELSIF ~IsStrName(name) & v.isStr THEN
    IF ~Strings.StrToReal(v.s, v.num) THEN v.num := 0.0 END; v.isStr := FALSE
  END;
  RETURN TRUE
END VMNextDataValue;

PROCEDURE DoVmCall(funcIdx, argc: INTEGER; wantValue: BOOLEAN; VAR pc: INTEGER);
VAR fd: FuncDef; ns: NumSnap; ss: StrSnap; k: INTEGER;
    args: ARRAY MaxFuncParams OF Value; dummy: Value;
BEGIN
  IF callTop >= MaxCallDepth THEN
    RtErr("CALL DEPTH EXCEEDED");
    FOR k := 1 TO argc DO Pop(dummy) END;
    RETURN
  END;
  fd := funcs[funcIdx];
  FOR k := argc - 1 TO 0 BY -1 DO Pop(args[k]) END;
  SnapshotScalars(ns, ss); ClearVars;
  FOR k := 0 TO argc - 1 DO
    IF fd.paramIsStr[k] THEN
      IF ~args[k].isStr THEN NumToStr(args[k].num, args[k].s); args[k].isStr := TRUE END;
      SetStr(fd.params[k], args[k].s)
    ELSE
      IF args[k].isStr THEN
        IF ~Strings.StrToReal(args[k].s, args[k].num) THEN args[k].num := 0.0 END;
        args[k].isStr := FALSE
      END;
      SetNum(fd.params[k], args[k].num)
    END
  END;
  callStack[callTop].returnPc := pc;
  callStack[callTop].savedForTop := forTop;
  callStack[callTop].savedGosubTop := gosubTop;
  callStack[callTop].funcIdx := funcIdx;
  callStack[callTop].ns := ns; callStack[callTop].ss := ss;
  callStack[callTop].wantValue := wantValue;
  INC(callTop);
  pc := fd.entryPc
END DoVmCall;

PROCEDURE DoVmReturn(hasExpr: INTEGER; VAR pc: INTEGER);
VAR v, result: Value; frame: CallFrame; fd: FuncDef; tmp: STRING;
BEGIN
  IF callTop <= 0 THEN RETURN END;
  frame := callStack[callTop-1];
  fd := funcs[frame.funcIdx];
  IF hasExpr = 1 THEN
    Pop(v);
    IF fd.isStr THEN
      IF v.isStr THEN result := v ELSE NumToStr(v.num, tmp); result := MkStr(tmp) END
    ELSE
      IF v.isStr THEN
        IF ~Strings.StrToReal(v.s, v.num) THEN v.num := 0.0 END; result := MkNum(v.num)
      ELSE result := v END
    END
  ELSE
    IF fd.isStr THEN result := MkStr("") ELSE result := MkNum(0.0) END
  END;
  DEC(callTop);
  RestoreScalars(frame.ns, frame.ss);
  forTop := frame.savedForTop; gosubTop := frame.savedGosubTop;
  pc := frame.returnPc;
  IF frame.wantValue THEN Push(result) END
END DoVmReturn;

(* ============================ file I/O runtime ============================ *)

PROCEDURE CloseFileSlot(n: INTEGER);
BEGIN
  IF fileSlots[n].inUse THEN
    IF ~fileSlots[n].isInput THEN Files.Register(fileSlots[n].f) END;
    Files.Close(fileSlots[n].f);
    fileSlots[n].inUse := FALSE
  END
END CloseFileSlot;

PROCEDURE CloseAllFiles;
VAR i: INTEGER;
BEGIN
  FOR i := 1 TO MaxOpenFiles DO CloseFileSlot(i) END
END CloseAllFiles;

PROCEDURE InitFileSlots;
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO MaxOpenFiles DO fileSlots[i].inUse := FALSE END
END InitFileSlots;

(* APPEND mode: the runtime's Files.New always creates/truncates, and there's
 * no update-in-place open mode, so we drain any existing file into memory,
 * close it, then recreate it via Files.New and write the old content back
 * before handing the rider to the caller for further writes. Files are
 * capped at MaxAppendLines lines of pre-existing content. *)
PROCEDURE OpenAppend(n: INTEGER; name: ARRAY OF CHAR);
VAR oldf, newf: Files.File; r: Files.Rider; line: STRING; cnt, i: INTEGER;
BEGIN
  oldf := Files.Old(name);
  IF oldf = NIL THEN
    newf := Files.New(name);
    IF newf = NIL THEN RtErr("CANNOT OPEN FILE"); RETURN END;
    Files.Set(fileSlots[n].r, newf, 0);
    fileSlots[n].f := newf; fileSlots[n].inUse := TRUE; fileSlots[n].isInput := FALSE;
    RETURN
  END;
  Files.Set(r, oldf, 0);
  cnt := 0;
  WHILE ~r.eof & (cnt < MaxAppendLines) DO
    Files.ReadLine(r, line);
    IF ~r.eof THEN Strings.Copy(line, appendBuf[cnt]); INC(cnt) END
  END;
  Files.Close(oldf);
  newf := Files.New(name);
  IF newf = NIL THEN RtErr("CANNOT OPEN FILE"); RETURN END;
  Files.Set(fileSlots[n].r, newf, 0);
  FOR i := 0 TO cnt - 1 DO Files.WriteLine(fileSlots[n].r, appendBuf[i]) END;
  fileSlots[n].f := newf; fileSlots[n].inUse := TRUE; fileSlots[n].isInput := FALSE
END OpenAppend;

(* PRINT/PRINT# share one compiled opcode sequence; these two helpers
 * redirect character output and column tracking to a per-file line buffer
 * (flushed as one record on opPrintNL) instead of the terminal when a
 * PRINT# statement is active. *)
PROCEDURE PrintOut(s: ARRAY OF CHAR);
BEGIN
  IF filePrintTarget # 0 THEN Strings.Append(s, filePrintBuf) ELSE POut(s) END
END PrintOut;

PROCEDURE PrintCol(): INTEGER;
BEGIN
  IF filePrintTarget # 0 THEN RETURN Strings.Length(filePrintBuf) ELSE RETURN outCol END
END PrintCol;

(* Splits a FILES argument like "sub/*.bas" into a directory path and a
 * suffix filter (OS.DirOpen matches by filename suffix, not a glob). *)
PROCEDURE SplitFilesArg(arg: ARRAY OF CHAR; VAR path, filter: ARRAY OF CHAR);
VAR i, n, slash, star: INTEGER; rest: STRING;
BEGIN
  n := Strings.Length(arg);
  slash := -1;
  FOR i := 0 TO n - 1 DO IF arg[i] = '/' THEN slash := i END END;
  IF slash >= 0 THEN
    Strings.Extract(arg, 0, slash, path);
    Strings.Extract(arg, slash + 1, n - slash - 1, rest)
  ELSE
    path := ""; Strings.Copy(arg, rest)
  END;
  star := Strings.Pos("*", rest);
  IF star >= 0 THEN
    Strings.Extract(rest, star + 1, Strings.Length(rest) - star - 1, filter)
  ELSE
    Strings.Copy(rest, filter)
  END
END SplitFilesArg;

PROCEDURE DoFiles(arg: ARRAY OF CHAR);
VAR path, filter, name, buf: STRING; i, n, isdir: INTEGER;
BEGIN
  SplitFilesArg(arg, path, filter);
  OS.DirOpen(path, filter);
  n := OS.DirCount();
  FOR i := 0 TO n - 1 DO
    OS.DirName(i, name);
    isdir := OS.DirIsDir(i);
    POut(name); IF isdir = 1 THEN POut("/") END; PNL
  END;
  NumToStr(FLT(n), buf); POut(buf); POut(" File(s)"); PNL
END DoFiles;

PROCEDURE RunVM(startPc: INTEGER);
VAR pc, target, li, idx, ai, i1, i2, c2, n, x, y, x2, y2, w, h, sz, c, d1, d2: INTEGER;
    r, num: REAL;
    res, contd: BOOLEAN;
    v, rhs, idxv, idxv2: Value;
    buf, name, part, prompt: STRING;
    instr: Instr;
BEGIN
  pc := startPc; progRunning := TRUE;
  WHILE progRunning & ~errFlag DO
    instr := code[pc]; INC(pc);

    IF instr.op = opPushNum THEN Push(MkNum(numPool[instr.a]))
    ELSIF instr.op = opLoadVar THEN
      Strings.Copy(namePool[instr.a], name);
      IF IsStrName(name) THEN v.isStr := TRUE; v.num := 0.0; GetStr(name, v.s)
      ELSE v := MkNum(GetNum(name)) END;
      Push(v)
    ELSIF instr.op = opAdd THEN
      Pop(rhs); Pop(v);
      IF v.isStr OR rhs.isStr THEN
        Strings.Copy(v.s, buf); Strings.Append(rhs.s, buf); Push(MkStr(buf))
      ELSE Push(MkNum(v.num + rhs.num)) END
    ELSIF instr.op = opSub THEN Pop(rhs); Pop(v); Push(MkNum(v.num - rhs.num))
    ELSIF instr.op = opMul THEN Pop(rhs); Pop(v); Push(MkNum(v.num * rhs.num))
    ELSIF instr.op = opStoreVar THEN
      Pop(v); AssignScalar(namePool[instr.a], v)
    ELSIF (instr.op >= opEq) & (instr.op <= opGe) THEN
      Pop(rhs); Pop(v);
      IF v.isStr OR rhs.isStr THEN c2 := Strings.Compare(v.s, rhs.s)
      ELSE
        IF v.num < rhs.num THEN c2 := -1 ELSIF v.num > rhs.num THEN c2 := 1 ELSE c2 := 0 END
      END;
      IF instr.op = opEq THEN res := c2 = 0
      ELSIF instr.op = opNe THEN res := c2 # 0
      ELSIF instr.op = opLt THEN res := c2 < 0
      ELSIF instr.op = opGt THEN res := c2 > 0
      ELSIF instr.op = opLe THEN res := c2 <= 0
      ELSE res := c2 >= 0 END;
      Push(MkBool(res))
    ELSIF instr.op = opJumpIfFalse THEN
      Pop(v); IF ~Truthy(v) THEN pc := instr.a END
    ELSIF instr.op = opForNext THEN
      IF forTop <= 0 THEN RtErr("NEXT WITHOUT FOR")
      ELSE
        SetNum(forStack[forTop-1].varName, GetNum(forStack[forTop-1].varName) + forStack[forTop-1].step);
        IF forStack[forTop-1].step >= 0.0 THEN
          contd := GetNum(forStack[forTop-1].varName) <= forStack[forTop-1].limit + 1.0E-9
        ELSE
          contd := GetNum(forStack[forTop-1].varName) >= forStack[forTop-1].limit - 1.0E-9
        END;
        IF contd THEN pc := forStack[forTop-1].loopTopPc ELSE DEC(forTop) END
      END
    ELSIF instr.op = opLine THEN
      MaybePresent; currentLineNum := instr.a;
      IF filePrintTarget # 0 THEN filePrintTarget := 0; filePrintBuf := "" END
    ELSIF instr.op = opPushStr THEN Push(MkStr(strPool[instr.a]))
    ELSIF instr.op = opLoadArr THEN
      IF instr.b = 2 THEN Pop(idxv2); i2 := FLOOR(idxv2.num) ELSE i2 := -1 END;
      Pop(idxv); i1 := FLOOR(idxv.num);
      ai := EnsureArray(namePool[instr.a]);
      IF (ai >= 0) & ArrIndex(arrays[ai], i1, i2, idx) THEN
        IF arrays[ai].isStr THEN Push(MkStr(arrays[ai].strData.elems[idx]))
        ELSE Push(MkNum(arrays[ai].numData[idx])) END
      ELSE Push(MkNum(0.0)) END
    ELSIF instr.op = opStoreArr THEN
      Pop(v);
      IF instr.b = 2 THEN Pop(idxv2); i2 := FLOOR(idxv2.num) ELSE i2 := -1 END;
      Pop(idxv); i1 := FLOOR(idxv.num);
      AssignArrayElem(namePool[instr.a], i1, i2, v)
    ELSIF instr.op = opPop THEN Pop(v)
    ELSIF instr.op = opNeg THEN Pop(v); Push(MkNum(-v.num))
    ELSIF instr.op = opNot THEN Pop(v); Push(MkBool(~Truthy(v)))
    ELSIF instr.op = opDiv THEN
      Pop(rhs); Pop(v);
      IF rhs.num = 0.0 THEN RtErr("DIVISION BY ZERO"); Push(MkNum(0.0))
      ELSE Push(MkNum(v.num / rhs.num)) END
    ELSIF instr.op = opMod THEN
      Pop(rhs); Pop(v);
      IF FLOOR(rhs.num) = 0 THEN RtErr("DIVISION BY ZERO"); Push(MkNum(0.0))
      ELSE Push(MkNum(FLT(FLOOR(v.num) MOD FLOOR(rhs.num)))) END
    ELSIF instr.op = opPow THEN Pop(rhs); Pop(v); Push(MkNum(Math.power(v.num, rhs.num)))
    ELSIF instr.op = opAndOp THEN Pop(rhs); Pop(v); Push(MkBool(Truthy(v) & Truthy(rhs)))
    ELSIF instr.op = opOrOp THEN Pop(rhs); Pop(v); Push(MkBool(Truthy(v) OR Truthy(rhs)))
    ELSIF instr.op = opCallBuiltinFunc THEN RunBuiltinFunc(instr.a, instr.b)
    ELSIF instr.op = opCallUserFuncExpr THEN DoVmCall(instr.a, instr.b, TRUE, pc)
    ELSIF instr.op = opCallUserFuncStmt THEN DoVmCall(instr.a, instr.b, FALSE, pc)
    ELSIF instr.op = opFuncReturn THEN DoVmReturn(instr.a, pc)
    ELSIF instr.op = opJump THEN pc := instr.a
    ELSIF instr.op = opGoto THEN
      IF instr.a < 0 THEN RtErr("UNDEFINED LINE") ELSE pc := instr.a END
    ELSIF instr.op = opGotoDyn THEN
      Pop(v); target := FLOOR(v.num);
      IF FindLinePos(target, li) THEN pc := lineStartPc[li] ELSE RtErr("UNDEFINED LINE") END
    ELSIF instr.op = opGosub THEN
      IF instr.a < 0 THEN RtErr("UNDEFINED LINE")
      ELSIF gosubTop >= MaxGosubStack THEN RtErr("GOSUB TOO DEEP")
      ELSE gosubStack[gosubTop].returnPc := pc; INC(gosubTop); pc := instr.a END
    ELSIF instr.op = opGosubDyn THEN
      Pop(v); target := FLOOR(v.num);
      IF ~FindLinePos(target, li) THEN RtErr("UNDEFINED LINE")
      ELSIF gosubTop >= MaxGosubStack THEN RtErr("GOSUB TOO DEEP")
      ELSE gosubStack[gosubTop].returnPc := pc; INC(gosubTop); pc := lineStartPc[li] END
    ELSIF instr.op = opGosubReturn THEN
      IF gosubTop <= 0 THEN RtErr("RETURN WITHOUT GOSUB")
      ELSE DEC(gosubTop); pc := gosubStack[gosubTop].returnPc END
    ELSIF instr.op = opOnGoto THEN
      Pop(v); idx := FLOOR(v.num);
      IF (idx >= 1) & (idx <= instr.b) THEN
        target := onTargets[instr.a + idx - 1];
        IF target < 0 THEN RtErr("UNDEFINED LINE") ELSE pc := target END
      END
    ELSIF instr.op = opOnGosub THEN
      Pop(v); idx := FLOOR(v.num);
      IF (idx >= 1) & (idx <= instr.b) THEN
        target := onTargets[instr.a + idx - 1];
        IF target < 0 THEN RtErr("UNDEFINED LINE")
        ELSIF gosubTop >= MaxGosubStack THEN RtErr("GOSUB TOO DEEP")
        ELSE gosubStack[gosubTop].returnPc := pc; INC(gosubTop); pc := target END
      END
    ELSIF instr.op = opForInit THEN
      IF forTop >= MaxForStack THEN RtErr("FOR TOO DEEP")
      ELSE
        Pop(v); forStack[forTop].step := v.num;
        Pop(v); forStack[forTop].limit := v.num;
        Pop(v);
        Strings.Copy(namePool[instr.a], forStack[forTop].varName);
        SetNum(namePool[instr.a], v.num);
        forStack[forTop].loopTopPc := pc;
        INC(forTop)
      END
    ELSIF instr.op = opEnd THEN
      MaybePresent; progRunning := FALSE
    ELSIF instr.op = opPrintVal THEN
      Pop(v); IF v.isStr THEN PrintOut(v.s) ELSE NumToStr(v.num, buf); PrintOut(buf) END
    ELSIF instr.op = opPrintTab THEN
      Pop(v); n := FLOOR(v.num); WHILE PrintCol() < n DO PrintOut(" ") END
    ELSIF instr.op = opPrintComma THEN
      n := (PrintCol() DIV 14 + 1) * 14; WHILE PrintCol() < n DO PrintOut(" ") END
    ELSIF instr.op = opPrintNL THEN
      IF filePrintTarget # 0 THEN
        IF (filePrintTarget >= 1) & (filePrintTarget <= MaxOpenFiles) & fileSlots[filePrintTarget].inUse THEN
          Files.WriteLine(fileSlots[filePrintTarget].r, filePrintBuf)
        ELSE RtErr("FILE NOT OPEN") END;
        filePrintTarget := 0; filePrintBuf := ""
      ELSE PNL END
    ELSIF instr.op = opPrintFileBegin THEN
      Pop(v); filePrintTarget := FLOOR(v.num); filePrintBuf := ""
    ELSIF instr.op = opInputBegin THEN
      IF instr.a >= 0 THEN Strings.Copy(strPool[instr.a], prompt); Strings.Append("? ", prompt)
      ELSE Strings.Copy("? ", prompt) END;
      History.ReadLine(prompt, inputLine); outCol := 0;
      inputFieldN := 0
    ELSIF instr.op = opInputFileBegin THEN
      Pop(v); n := FLOOR(v.num);
      IF (n >= 1) & (n <= MaxOpenFiles) & fileSlots[n].inUse THEN
        Files.ReadLine(fileSlots[n].r, inputLine)
      ELSE RtErr("FILE NOT OPEN"); inputLine := "" END;
      inputFieldN := 0
    ELSIF instr.op = opLineInputFile THEN
      Pop(v); n := FLOOR(v.num);
      IF (n >= 1) & (n <= MaxOpenFiles) & fileSlots[n].inUse THEN
        Files.ReadLine(fileSlots[n].r, buf)
      ELSE RtErr("FILE NOT OPEN"); buf := "" END;
      v := MkStr(buf); AssignScalar(namePool[instr.a], v)
    ELSIF instr.op = opInputVar THEN
      IF ~Strings.Split(inputLine, ',', inputFieldN, part) THEN part := "" END;
      Strings.Trim(part); INC(inputFieldN);
      IF IsStrName(namePool[instr.a]) THEN v := MkStr(part)
      ELSE
        IF ~Strings.StrToReal(part, num) THEN num := 0.0 END; v := MkNum(num)
      END;
      AssignScalar(namePool[instr.a], v)
    ELSIF instr.op = opInputArr THEN
      IF instr.b = 2 THEN Pop(idxv2); i2 := FLOOR(idxv2.num) ELSE i2 := -1 END;
      Pop(idxv); i1 := FLOOR(idxv.num);
      IF ~Strings.Split(inputLine, ',', inputFieldN, part) THEN part := "" END;
      Strings.Trim(part); INC(inputFieldN);
      IF IsStrName(namePool[instr.a]) THEN v := MkStr(part)
      ELSE
        IF ~Strings.StrToReal(part, num) THEN num := 0.0 END; v := MkNum(num)
      END;
      AssignArrayElem(namePool[instr.a], i1, i2, v)
    ELSIF instr.op = opDim THEN
      IF instr.b = 0 THEN d1 := 10; d2 := -1
      ELSIF instr.b = 1 THEN Pop(v); d1 := FLOOR(v.num); d2 := -1
      ELSE Pop(v); d2 := FLOOR(v.num); Pop(idxv); d1 := FLOOR(idxv.num)
      END;
      ai := DimArray(namePool[instr.a], d1, d2)
    ELSIF instr.op = opReadVar THEN
      IF VMNextDataValue(namePool[instr.a], v) THEN AssignScalar(namePool[instr.a], v) END
    ELSIF instr.op = opReadArr THEN
      IF instr.b = 2 THEN Pop(idxv2); i2 := FLOOR(idxv2.num) ELSE i2 := -1 END;
      Pop(idxv); i1 := FLOOR(idxv.num);
      IF VMNextDataValue(namePool[instr.a], v) THEN AssignArrayElem(namePool[instr.a], i1, i2, v) END
    ELSIF instr.op = opRestore THEN
      IF instr.a = 1 THEN
        Pop(v); target := FLOOR(v.num);
        i1 := 0; WHILE (i1 < nDataVals) & (dataLineOf[i1] < target) DO INC(i1) END;
        dataPtr := i1
      ELSE dataPtr := 0 END
    ELSIF instr.op = opCls THEN DoCls
    ELSIF instr.op = opLocate THEN
      IF instr.a = 2 THEN Pop(v); y := FLOOR(v.num) ELSE y := 1 END;
      Pop(v); x := FLOOR(v.num);
      VmLocate(x, y)
    ELSIF instr.op = opRandomize THEN
      IF instr.a = 1 THEN Pop(v) END
    ELSIF instr.op = opScreen THEN
      IF instr.a = 2 THEN Pop(v); h := FLOOR(v.num) ELSE h := 480 END;
      Pop(v); w := FLOOR(v.num);
      EnsureGfx(w, h)
    ELSIF instr.op = opColor THEN
      IF instr.a = 2 THEN Pop(v); bgColorIx := FLOOR(v.num) END;
      Pop(v); curColorIx := FLOOR(v.num)
    ELSIF instr.op = opPset THEN
      IF instr.a = 3 THEN Pop(v); c := FLOOR(v.num) ELSE c := curColorIx END;
      Pop(v); y := FLOOR(v.num);
      Pop(v); x := FLOOR(v.num);
      VmPset(x, y, c)
    ELSIF instr.op = opDrawLine THEN
      IF instr.a = 5 THEN Pop(v); c := FLOOR(v.num) ELSE c := curColorIx END;
      Pop(v); y2 := FLOOR(v.num);
      Pop(v); x2 := FLOOR(v.num);
      Pop(v); y := FLOOR(v.num);
      Pop(v); x := FLOOR(v.num);
      VmLine(x, y, x2, y2, c)
    ELSIF instr.op = opCircle THEN
      IF instr.b = 4 THEN Pop(v); c := FLOOR(v.num) ELSE c := curColorIx END;
      Pop(v); r := v.num;
      Pop(v); y := FLOOR(v.num);
      Pop(v); x := FLOOR(v.num);
      VmCircle(x, y, c, r, instr.a = 1)
    ELSIF instr.op = opRect THEN
      IF instr.b = 5 THEN Pop(v); c := FLOOR(v.num) ELSE c := curColorIx END;
      Pop(v); h := FLOOR(v.num);
      Pop(v); w := FLOOR(v.num);
      Pop(v); y := FLOOR(v.num);
      Pop(v); x := FLOOR(v.num);
      VmRect(x, y, w, h, c, instr.a = 1)
    ELSIF instr.op = opText THEN
      IF instr.a = 5 THEN Pop(v); c := FLOOR(v.num) ELSE c := curColorIx END;
      IF instr.a >= 4 THEN Pop(v); sz := FLOOR(v.num) ELSE sz := 20 END;
      Pop(v); IF ~v.isStr THEN NumToStr(v.num, v.s) END; Strings.Copy(v.s, buf);
      Pop(v); y := FLOOR(v.num);
      Pop(v); x := FLOOR(v.num);
      VmText(x, y, sz, c, buf)
    ELSIF instr.op = opSound THEN
      Pop(v); n := FLOOR(v.num);
      Pop(v); r := v.num;
      VmSound(r, n)
    ELSIF instr.op = opBeep THEN VmBeep
    ELSIF instr.op = opDelay THEN
      Pop(v); VmDelay(FLOOR(v.num))
    ELSIF instr.op = opOpen THEN
      Pop(v); n := FLOOR(v.num);
      Pop(rhs); Strings.Copy(rhs.s, buf);
      IF (n < 1) OR (n > MaxOpenFiles) THEN RtErr("BAD FILE NUMBER")
      ELSE
        IF fileSlots[n].inUse THEN CloseFileSlot(n) END;
        IF instr.a = 0 THEN
          fileSlots[n].f := Files.Old(buf);
          IF fileSlots[n].f = NIL THEN RtErr("FILE NOT FOUND")
          ELSE
            Files.Set(fileSlots[n].r, fileSlots[n].f, 0);
            fileSlots[n].inUse := TRUE; fileSlots[n].isInput := TRUE
          END
        ELSIF instr.a = 1 THEN
          fileSlots[n].f := Files.New(buf);
          IF fileSlots[n].f = NIL THEN RtErr("CANNOT OPEN FILE")
          ELSE
            Files.Set(fileSlots[n].r, fileSlots[n].f, 0);
            fileSlots[n].inUse := TRUE; fileSlots[n].isInput := FALSE
          END
        ELSE
          OpenAppend(n, buf)
        END
      END
    ELSIF instr.op = opCloseFile THEN
      IF instr.a = 1 THEN
        Pop(v); n := FLOOR(v.num);
        IF (n >= 1) & (n <= MaxOpenFiles) THEN CloseFileSlot(n) END
      ELSE
        CloseAllFiles
      END
    ELSIF instr.op = opFiles THEN
      IF instr.a = 1 THEN Pop(v); Strings.Copy(v.s, buf) ELSE buf := "" END;
      DoFiles(buf)
    END
  END;
  IF errFlag THEN ReportError(currentLineNum) END
END RunVM;

PROCEDURE ScanData;
VAR i: INTEGER; tb: TokBuf; v: Value; neg: BOOLEAN; skipTo: INTEGER;
BEGIN
  nDataVals := 0; dataPtr := 0;
  i := 0;
  WHILE i < nLines DO
    IF IsFuncBodyLine(i, skipTo) THEN i := skipTo
    ELSE
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
      END;
      INC(i)
    END
  END
END ScanData;

PROCEDURE RunProgram;
BEGIN
  ClearVars; forTop := 0; gosubTop := 0; callTop := 0; sp := 0;
  CompileProgram;
  IF errFlag THEN ReportError(currentLineNum); RETURN END;
  ScanData;
  startTime := Time.Now();
  IF nLines > 0 THEN RunVM(lineStartPc[0]) END
END RunProgram;

(* ============================ file load / save ============================= *)

PROCEDURE StripQuotes(VAR s: ARRAY OF CHAR);
VAR n: INTEGER; tmp: STRING;
BEGIN
  n := Strings.Length(s);
  IF (n >= 2) & (s[0] = '"') & (s[n-1] = '"') THEN
    Strings.Extract(s, 1, n - 2, tmp); Strings.Copy(tmp, s)
  END
END StripQuotes;

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

PROCEDURE LoadFile(name: ARRAY OF CHAR): BOOLEAN;
VAR f: Files.File; r: Files.Rider; line, tok, rest: STRING;
    num, pos, autoNum: INTEGER; inDefn: BOOLEAN;
BEGIN
  f := Files.Old(name);
  IF f = NIL THEN POut("CANNOT OPEN "); POut(name); PNL; RETURN FALSE END;
  Files.Set(r, f, 0);
  nLines := 0;
  autoNum := 60000;   (* auto-number DEFN/body/ENDFN lines that have no line number *)
  inDefn := FALSE;
  WHILE ~r.eof DO
    Files.ReadLine(r, line);
    IF Strings.Length(line) > 0 THEN
      pos := 0;
      Strings.NextWord(line, pos, tok);
      IF Strings.StrToInt(tok, num) THEN
        Strings.Extract(line, pos, Strings.Length(line) - pos, rest);
        Strings.Trim(rest);
        ExpandQuestionMarks(rest);
        InsertLine(num, rest);
        IF IsDefnLine(rest) THEN inDefn := TRUE
        ELSIF IsEndfnLine(rest) THEN inDefn := FALSE
        END
      ELSE
        (* An unnumbered line: allowed only inside a DEFN block that
         * we're building (so users can write DEFN blocks without line
         * numbers in a source file). Auto-number using a high sequence. *)
        Strings.Copy(line, rest); Strings.Trim(rest);
        ExpandQuestionMarks(rest);
        IF IsDefnLine(rest) OR inDefn THEN
          InsertLine(autoNum, rest); INC(autoNum);
          IF IsDefnLine(rest) THEN inDefn := TRUE
          ELSIF IsEndfnLine(rest) THEN inDefn := FALSE
          END
        END
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

PROCEDURE ShowBanner;
BEGIN
  POut("BASIC -- Raylib graphics & sound, terminal otherwise."); PNL;
  POut("Type HELP for commands, HELP topic for details, BYE to quit."); PNL
END ShowBanner;

PROCEDURE ShowHelp;
BEGIN
  POut("Commands   : RUN  LIST  NEW  LOAD file  SAVE file  CLEAR  BYE"); PNL;
  POut("Statements : PRINT(?) INPUT LET IF/THEN/ELSE WHILE/WEND FOR/TO/STEP/NEXT"); PNL;
  POut("             GOTO GOSUB/RETURN ON..GOTO/GOSUB END STOP DIM DATA/READ/RESTORE"); PNL;
  POut("             CLS LOCATE DEFN/ENDFN (user functions)"); PNL;
  POut("Files      : OPEN/CLOSE PRINT# INPUT# LINE INPUT# EOF() FILES"); PNL;
  POut("Graphics   : SCREEN COLOR PSET LINE CIRCLE FCIRCLE RECT FRECT TEXT"); PNL;
  POut("Sound      : SOUND BEEP DELAY"); PNL;
  POut("Type a numbered line to add/replace/delete it; anything else runs"); PNL;
  POut("immediately, e.g. PRINT 2+2 (or ? 2+2)."); PNL;
  POut("Type HELP topic for details on one item, e.g. HELP DEFN, HELP FUNCTIONS."); PNL;
  POut("Up/Down arrows recall previous input lines."); PNL
END ShowHelp;

PROCEDURE ShowHelpTopic(topic: ARRAY OF CHAR);
VAR tmp: STRING;
BEGIN
  IF (topic = "PRINT") OR ((Strings.Length(topic) = 1) & (topic[0] = '?')) THEN
    POut("PRINT expr[,expr|;expr]...        (also spelled: ? expr...)"); PNL;
    POut("PRINT #n, expr[,expr|;expr]...    (writes one record to file #n)"); PNL;
    POut("  Prints values. ';' joins with no space; ',' pads to the next"); PNL;
    POut("  14-column zone. TAB(n) moves to column n. Ending in ',' or ';'"); PNL;
    POut("  suppresses the trailing newline. '?' is shorthand for PRINT and"); PNL;
    POut("  is rewritten to PRINT wherever it appears."); PNL
  ELSIF topic = "INPUT" THEN
    POut("INPUT [prompt$;] var[,var]...      INPUT #n, var[,var]..."); PNL;
    POut("  Reads a comma-separated line from the keyboard, or from open"); PNL;
    POut("  file #n. See also HELP LINE for LINE INPUT #n."); PNL
  ELSIF topic = "LET" THEN
    POut("[LET] var = expr          [LET] arr(i[,j]) = expr"); PNL
  ELSIF (topic = "IF") OR (topic = "THEN") OR (topic = "ELSE") THEN
    POut("IF expr THEN stmt[:stmt...] [ELSE stmt[:stmt...]]"); PNL;
    POut("IF expr THEN linenum [ELSE linenum]"); PNL;
    POut("  THEN/ELSE branches may each independently be a line number or a"); PNL;
    POut("  colon-separated statement list; the branch runs to EOL or ELSE."); PNL
  ELSIF (topic = "WHILE") OR (topic = "WEND") THEN
    POut("WHILE expr ... WEND  (loops while expr is true; may span lines)"); PNL
  ELSIF (topic = "FOR") OR (topic = "TO") OR (topic = "STEP") OR (topic = "NEXT") THEN
    POut("FOR var = start TO limit [STEP step] ... NEXT [var]"); PNL
  ELSIF topic = "GOTO" THEN POut("GOTO linenum"); PNL
  ELSIF (topic = "GOSUB") THEN POut("GOSUB linenum   ...   RETURN"); PNL
  ELSIF topic = "RETURN" THEN
    POut("RETURN            (in a GOSUB, jumps back to the caller)"); PNL;
    POut("RETURN [expr]     (inside DEFN..ENDFN, exits the function with a value)"); PNL
  ELSIF topic = "ON" THEN POut("ON expr GOTO n1[,n2...]        ON expr GOSUB n1[,n2...]"); PNL
  ELSIF (topic = "END") OR (topic = "STOP") THEN POut("END / STOP -- halt the program."); PNL
  ELSIF topic = "DIM" THEN POut("DIM name(d1[,d2])[, ...]"); PNL
  ELSIF (topic = "DATA") OR (topic = "READ") OR (topic = "RESTORE") THEN
    POut("DATA val[,...]      READ var[,...]      RESTORE [linenum]"); PNL
  ELSIF (topic = "CLS") OR (topic = "HOME") THEN POut("CLS / HOME -- clear the screen."); PNL
  ELSIF topic = "LOCATE" THEN POut("LOCATE row[,col]  (terminal only, 1-based)"); PNL
  ELSIF topic = "RANDOMIZE" THEN POut("RANDOMIZE [expr]  (reseed RND)"); PNL
  ELSIF topic = "SCREEN" THEN POut("SCREEN width[,height]  (open graphics window)"); PNL
  ELSIF topic = "COLOR" THEN POut("COLOR fg[,bg]  (0-15)"); PNL
  ELSIF topic = "PSET" THEN POut("PSET x,y[,color]"); PNL
  ELSIF topic = "LINE" THEN
    POut("LINE x1,y1,x2,y2[,color]"); PNL;
    POut("LINE INPUT #n, var$    (reads one whole line, no comma-splitting)"); PNL
  ELSIF (topic = "CIRCLE") OR (topic = "FCIRCLE") THEN POut("CIRCLE / FCIRCLE x,y,r[,color]"); PNL
  ELSIF (topic = "RECT") OR (topic = "FRECT") THEN POut("RECT / FRECT x,y,w,h[,color]"); PNL
  ELSIF topic = "TEXT" THEN POut("TEXT x,y,expr[,size[,color]]"); PNL
  ELSIF topic = "SOUND" THEN POut("SOUND freq,ms  (blocking tone)"); PNL
  ELSIF topic = "BEEP" THEN POut("BEEP  (short 800Hz tone)"); PNL
  ELSIF topic = "DELAY" THEN POut("DELAY ms"); PNL
  ELSIF topic = "OPEN" THEN
    NumToStr(FLT(MaxOpenFiles), tmp);
    POut('OPEN name$ FOR INPUT|OUTPUT|APPEND AS #n   (n = 1..'); POut(tmp); POut(")"); PNL
  ELSIF topic = "CLOSE" THEN POut("CLOSE [#n[,#n...]]   (no args closes every open file)"); PNL
  ELSIF topic = "EOF" THEN POut("EOF(n)  -- TRUE once file #n has no more lines to read"); PNL
  ELSIF topic = "FILES" THEN POut('FILES ["path"] ["*.ext"] ["path/*.ext"]  -- list a directory'); PNL
  ELSIF (topic = "DEFN") OR (topic = "ENDFN") OR (topic = "FUNCTION") OR (topic = "FUNCTIONS") THEN
    POut("DEFN name[$](p1[,p2,...])"); PNL;
    POut("  <statements>"); PNL;
    POut('  RETURN expr           (optional; falls through returns 0/"")'); PNL;
    POut("ENDFN"); PNL;
    POut(""); PNL;
    POut("  Defines a user function. Trailing $ in the name makes it a"); PNL;
    POut("  string function; otherwise numeric. Parameters are locals; the"); PNL;
    POut("  caller's scalars are saved and restored (arrays are global)."); PNL;
    POut("  Call as an expression:  y = square(5)  or as a statement:"); PNL;
    POut('  greet("world")  (return value, if any, is discarded).'); PNL;
    POut("  In a source file, body lines under DEFN may be unnumbered."); PNL;
    POut("  At the REPL, keep typing lines until ENDFN is entered."); PNL;
    POut(""); PNL;
    POut("Built-in functions:"); PNL;
    POut("  ABS INT SGN SQR SIN COS TAN ATN LOG EXP PI RND TIMER"); PNL;
    POut("  LEN VAL ASC CHR$ STR$ LEFT$ RIGHT$ MID$ INSTR INKEY$"); PNL;
    POut("  SCRW SCRH MOUSEX MOUSEY MOUSEB EOF"); PNL
  ELSIF topic = "RUN" THEN POut("RUN  (clears vars, scans DEFNs and DATA, runs from lowest line)"); PNL
  ELSIF topic = "LIST" THEN POut("LIST  (show the stored program)"); PNL
  ELSIF topic = "NEW" THEN POut("NEW  (erase program and variables)"); PNL
  ELSIF topic = "CLEAR" THEN POut("CLEAR  (erase variables, keep program)"); PNL
  ELSIF (topic = "LOAD") OR (topic = "SAVE") THEN POut("LOAD file        SAVE file  (plain text)"); PNL
  ELSIF (topic = "BYE") OR (topic = "QUIT") OR (topic = "EXIT") OR (topic = "SYSTEM") THEN
    POut("BYE / QUIT / EXIT / SYSTEM  (leave the interpreter)"); PNL
  ELSE
    POut("No help for "); POut(topic); POut(". Type HELP for the topic list."); PNL
  END
END ShowHelpTopic;

PROCEDURE Shutdown;
BEGIN
  CloseAllFiles;
  IF gfxMode THEN Raylib.UnloadRenderTexture(canvas); Raylib.CloseWindow END;
  IF audioReady THEN Raylib.CloseAudioDevice END
END Shutdown;

(* Read a DEFN block from the REPL, prompting for continuation lines
 * until an ENDFN line. Each line becomes a program line at an
 * auto-numbered slot in the high 6xxxx range. *)
PROCEDURE ReadReplDefn(firstLine: ARRAY OF CHAR);
VAR line: STRING; autoNum: INTEGER;
BEGIN
  autoNum := 60000;
  WHILE LineIndexOf(autoNum) >= 0 DO INC(autoNum) END;
  InsertLine(autoNum, firstLine); INC(autoNum);
  LOOP
    History.ReadLine(". ", line); outCol := 0;
    Strings.Trim(line);
    IF Strings.Length(line) = 0 THEN
      (* skip blank lines silently *)
    ELSE
      ExpandQuestionMarks(line);
      InsertLine(autoNum, line); INC(autoNum);
      IF IsEndfnLine(line) THEN EXIT END
    END
  END
END ReadReplDefn;

PROCEDURE Repl;
VAR line, cmd, arg, rest: STRING; num, pos, startPc: INTEGER; ok: BOOLEAN;
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
        ELSIF cmd = "NEW" THEN nLines := 0; ClearVars; ClearFuncs; CloseAllFiles
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
        ELSIF cmd = "DEFN" THEN
          (* Enter multi-line DEFN capture. *)
          ExpandQuestionMarks(line);
          ReadReplDefn(line)
        ELSE
          ExpandQuestionMarks(line);
          CompileProgram;
          IF errFlag THEN
            ReportError(currentLineNum)
          ELSE
            CompileImmediate(line, startPc, ok);
            IF ok THEN
              callTop := 0;
              currentLineNum := -1;
              startTime := Time.Now();
              RunVM(startPc)
            ELSE
              ReportError(-1)
            END
          END
        END
      END
    END
  END
END Repl;

BEGIN
  nLines := 0; nNumVars := 0; nStrVars := 0; nArrays := 0;
  forTop := 0; gosubTop := 0; nDataVals := 0; dataPtr := 0;
  nFuncs := 0; callTop := 0; sp := 0; codeLen := 0; codeLimit := MainCodeCap;
  nNames := 0; nNumPool := 0; nStrPool := 0; nOnTargets := 0; nGotoBackpatch := 0;
  errFlag := FALSE; gfxMode := FALSE; audioReady := FALSE; outCol := 0;
  progRunning := TRUE; appRunning := TRUE;
  whileTop := 0; filePrintTarget := 0; filePrintBuf := "";
  InitFileSlots;
  startTime := Time.Now();
  IF Args.Count() >= 1 THEN
    Args.Get(1, fname);
    IF LoadFile(fname) THEN RunProgram END
  ELSE
    Repl
  END;
  Shutdown
END Basic.
