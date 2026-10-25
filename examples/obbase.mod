MODULE obbase;
(*
 * obbase -- a dBASE III PLUS work-alike, after the dBASE chapters
 * (18-23) of Tim Duffy's "Four Software Tools".
 *
 * Usage:
 *   obbase                 start at the dot prompt
 *   obbase prog            DO prog.prg at start-up (like "DBASE prog")
 *   obbase -b prog         batch mode: run prog.prg without the full-screen
 *                          interface, sending output to stdout
 *
 * Files are real dBASE III files: .DBF data, .DBT memo text and .NDX
 * B-tree indexes (via Modules/DBF).  Report forms (.FRM), label forms
 * (.LBL), queries (.QRY), views (.VUE) and memory files (.MEM) use small
 * text formats of obbase's own.
 *
 * Main pieces, in source order:
 *   screen/console model and line input
 *   expression compiler and evaluator (fields, memory variables,
 *     dBASE operators and ~70 functions)
 *   work areas, record navigation, index maintenance
 *   dot-prompt commands (USE, LIST, REPLACE, INDEX, SEEK, ...)
 *   full-screen APPEND/EDIT/BROWSE, CREATE/MODIFY STRUCTURE,
 *     report/label/query designers, text editor (MODIFY COMMAND, memos)
 *   report and label generation
 *   command files (.PRG): IF/DO WHILE/DO CASE/PROCEDURE/PARAMETERS
 *   the ASSIST menu system and HELP
 *)

IMPORT TUI, Terminal, Files, Strings, Math, Time, Args, OS, Out, DBF;

CONST
  Version = "obbase 1.0 (dBASE III PLUS work-alike)";

  MaxAreas   = 10;
  MaxIdx     = 7;     (* index files per work area *)
  MaxVars    = 256;   (* memory variables *)
  MaxHistLn  = 400;   (* console lines kept after scrolling off *)
  MaxCmdHist = 20;    (* command history (SET HISTORY) *)
  MaxGets    = 64;
  MaxRecBuf  = 4002;
  MaxMemo    = 8192;
  MaxTxtLn   = 2000;  (* lines in the text editor / a program *)
  MaxDepth   = 32;    (* DO nesting *)
  MaxPrgs    = 40;    (* cached programs *)
  MaxProcs   = 128;   (* procedures in SET PROCEDURE file *)
  MaxCols    = 64;    (* report columns *)
  MaxSR      = 60;    (* screen grid bounds = TUI limits *)
  MaxSC      = 220;

  (* value types *)
  TC = "C"; TN = "N"; TL = "L"; TD = "D"; TU = "U";

  (* tokens *)
  tEOF = 0; tIdent = 1; tNum = 2; tStr = 3; tLP = 4; tRP = 5; tComma = 6;
  tPlus = 7; tMinus = 8; tStar = 9; tSlash = 10; tPow = 11; tEq = 12;
  tNe = 13; tLt = 14; tGt = 15; tLe = 16; tGe = 17; tDollar = 18;
  tAnd = 19; tOr = 20; tNot = 21; tTrue = 22; tFalse = 23; tArrow = 24;
  tSemi = 25; tOther = 26; tPct = 27;

  (* expression node kinds *)
  nConst = 0; nField = 1; nVar = 2; nUnary = 3; nBinary = 4; nFunc = 5;

  (* attributes on the console grid *)
  aNorm = 0; aRev = 1; aBold = 2;

  (* scope kinds *)
  scDefault = 0; scAll = 1; scNext = 2; scRecord = 3; scRest = 4;

  (* colors (standard and enhanced pairs are variables: SET COLOR TO) *)
  cMenuFg = TUI.BrightWhite; cMenuBg = TUI.Blue;
  cBarFg = TUI.Black; cBarBg = TUI.Cyan;

  KCtrlA = 01X; KCtrlB = 02X; KCtrlC = 03X; KCtrlD = 04X; KCtrlE = 05X;
  KCtrlF = 06X; KCtrlG = 07X; KCtrlK = 0BX; KCtrlL = 0CX; KCtrlN = 0EX;
  KCtrlO = 0FX; KCtrlP = 10X; KCtrlQ = 11X; KCtrlR = 12X; KCtrlS = 13X;
  KCtrlT = 14X; KCtrlU = 15X; KCtrlV = 16X; KCtrlW = 17X; KCtrlX = 18X;
  KCtrlY = 19X; KCtrlZ = 1AX;

TYPE
  Str = ARRAY 256 OF CHAR;
  Name = ARRAY 12 OF CHAR;

  Value = RECORD
    t:   CHAR;      (* C N L D U *)
    s:   Str;       (* C *)
    n:   REAL;      (* N *)
    w, dec: INTEGER;(* N display width and decimals *)
    b:   BOOLEAN;   (* L *)
    d:   INTEGER    (* D: Julian day number, 0 = blank *)
  END;

  Node = POINTER TO NodeRec;
  NodeRec = RECORD
    kind, op: INTEGER;
    v: Value;
    area, fld: INTEGER;
    name: Name;
    nargs: INTEGER;
    arg: ARRAY 4 OF Node
  END;

  IdxInfo = RECORD
    fname: Str;
    ix: DBF.NdxIndex;
    key: Node;        (* compiled key expression *)
    dirty: BOOLEAN
  END;

  Area = RECORD
    used: BOOLEAN;
    db: DBF.Database;
    fname: Str;           (* path of the .DBF *)
    alias: Name;
    memo: Str;            (* .DBT path, "" if no memo fields *)
    rec: INTEGER;         (* 1-based; numRecs+1 = end of file *)
    eof, bof, found: BOOLEAN;
    buf: ARRAY MaxRecBuf OF CHAR;
    bufRec: INTEGER;      (* record held in buf, -1 = none *)
    offs: ARRAY DBF.MaxFields OF INTEGER;
    nIdx, order: INTEGER; (* order: master index 1..nIdx, 0 = natural *)
    idx: ARRAY MaxIdx OF IdxInfo;
    oldNum: ARRAY MaxIdx OF REAL;
    oldKey: ARRAY MaxIdx OF ARRAY DBF.MaxNdxKey + 1 OF CHAR;
    filter: Node; filterTxt: Str;
    relArea: INTEGER; relExpr: Node; relTxt: Str;
    locFor, locWhile: Node; locKind, locLeft: INTEGER; locOn: BOOLEAN
  END;

  MemVar = RECORD
    name: Name;
    v: Value;
    level: INTEGER;
    public: BOOLEAN
  END;

  TextBuf = POINTER TO TextRec;
  TextRec = RECORD
    n: INTEGER;
    l: ARRAY MaxTxtLn OF Str
  END;

  Prog = POINTER TO ProgRec;
  ProgRec = RECORD
    name: Str;
    n: INTEGER;
    line: ARRAY MaxTxtLn OF Str;
    verb, jmp, aux: ARRAY MaxTxtLn OF INTEGER
  END;

  Frame = RECORD
    p: Prog;
    pc: INTEGER;
    level: INTEGER;
    nParmRef: INTEGER;
    parmName: ARRAY 16 OF Name;   (* callee name -> caller variable *)
    parmRef: ARRAY 16 OF Name;
    callerArea: INTEGER;
    privMode: INTEGER;            (* PRIVATE ALL: 0 none, 1 all, 2 LIKE, 3 EXCEPT *)
    privSkel: ARRAY 64 OF CHAR
  END;

  Clauses = RECORD
    scope, n: INTEGER;
    forN, whileN: Node;
    off, toPrint, plain, noEject, summary, sample: BOOLEAN;
    toFile: Str;
    heading: Str
  END;

  ColDef = RECORD
    contents: Str;
    heading: Str;
    width, dec: INTEGER;
    total: BOOLEAN
  END;

  Report = RECORD
    title: ARRAY 4 OF Str;
    pageW, lMargin, rMargin, lines: INTEGER;
    dbl, ejectBefore, ejectAfter, plain: BOOLEAN;
    group, groupHead, subGroup, subHead: Str;
    summary, groupEject: BOOLEAN;
    nCols: INTEGER;
    col: ARRAY MaxCols OF ColDef
  END;

  LabelDef = RECORD
    width, height, lMargin, linesBetween, spacesBetween, across: INTEGER;
    remarks: Str;
    line: ARRAY 16 OF Str
  END;

  GetDef = RECORD
    row, col: INTEGER;
    var: Name;
    isField: BOOLEAN;
    area, fld: INTEGER;
    pic: Str;
    t: CHAR;
    width, dec: INTEGER;
    text: Str;
    rangeOn: BOOLEAN;
    lo, hi: Value
  END;

  FieldRef = RECORD area, fld: INTEGER END;

  (* single-line field editor state, shared by EDIT/BROWSE/GET *)
  FieldEd = RECORD
    text: Str;
    width, pos, scroll: INTEGER;
    t: CHAR;
    pic: Str;
    changed: BOOLEAN
  END;

VAR
  (* ---- settings (SET ...) ---- *)
  setTalk, setHeadings, setDeleted, setExact, setSafety, setConfirm,
  setBell, setStatus, setMenu, setPrint, setAlternate, setConsole,
  setCentury, setUnique, setCarry, setIntensity, setHelp, setEscape,
  setFieldsOn, setDevPrint, setDelimiters, setEcho, setFixed: BOOLEAN;
  delimL, delimR: CHAR;          (* SET DELIMITERS TO *)
  setDecimals, setMargin, setMemoWidth, setHistory, setDateFmt: INTEGER;
  defDrive: CHAR;
  defDir: Str;
  pathDirs: Str;
  fkeys: ARRAY 10 OF Str;
  fieldList: ARRAY DBF.MaxFields OF FieldRef;
  nFieldList: INTEGER;

  (* ---- work areas ---- *)
  areas: ARRAY MaxAreas OF Area;
  cur: INTEGER;                (* selected work area *)

  (* ---- memory variables ---- *)
  vars: ARRAY MaxVars OF MemVar;
  nVars: INTEGER;

  (* ---- errors ---- *)
  err: BOOLEAN;
  errMsg: Str;
  errCode: INTEGER;              (* III PLUS error number of errMsg *)
  lastErrCode: INTEGER;          (* ERROR() / MESSAGE() *)
  lastErrMsg: Str;
  errShown: INTEGER;             (* errors reported so far (ASSIST pauses after one) *)
  interrupted: BOOLEAN;

  (* ---- ON ERROR / ESCAPE / KEY, RETRY ---- *)
  onErrCmd, onEscCmd, onKeyCmd: Str;
  inOnErr, inOnEsc, inOnKey: BOOLEAN;
  retryFlag: BOOLEAN;            (* RETRY: re-execute the caller's current line *)

  (* ---- typeahead buffer ---- *)
  taBuf: ARRAY 32 OF CHAR;
  taN: INTEGER;
  onKeyN: INTEGER;               (* typeahead count when ON KEY last fired *)

  (* ---- colors ---- *)
  cFg, cBg, cRevFg, cRevBg, cHiFg: INTEGER;
  userMsg: Str;                  (* SET MESSAGE TO *)
  batchMid: BOOLEAN;             (* -b: stdout is in the middle of a line *)

  (* ---- EDIT scope: FOR acts as an extra filter while editing ---- *)
  editArea: INTEGER;             (* -1 when no EDIT scope is active *)
  editFor, editWhile: Node;
  editLeft: INTEGER;             (* NEXT n: records left, -1 = no limit *)

  (* ---- lexer ---- *)
  src: Str;
  sp, tk, tkStart, tkDec: INTEGER;
  tkStr: Str;
  tkNum: REAL;

  (* ---- console grid ---- *)
  scr: ARRAY MaxSR OF ARRAY MaxSC + 1 OF CHAR;
  att: ARRAY MaxSR OF ARRAY MaxSC OF CHAR;
  crow, ccol, scrW, scrH: INTEGER;
  histLn: ARRAY MaxHistLn OF Str;
  histN, histTop: INTEGER;
  pageCount: INTEGER;
  paging: BOOLEAN;
  lastDraw: LONGINT;
  batch: BOOLEAN;
  modeName: Str;               (* status bar mode, "Command Line" etc. *)
  msgLine, navLine: Str;
  insMode: BOOLEAN;

  (* ---- printer / alternate / TO FILE ---- *)
  prnF, altF, toF: Files.File;
  prnR, altR, toR: Files.Rider;
  prnName, altName: Str;
  toActive, prnActive: BOOLEAN; (* per-command TO FILE / TO PRINT *)
  prow, pcol: INTEGER;

  (* ---- command history ---- *)
  cmdHist: ARRAY MaxCmdHist OF Str;
  nCmdHist: INTEGER;

  (* ---- programs ---- *)
  frames: ARRAY MaxDepth OF Frame;
  depth: INTEGER;
  progs: ARRAY MaxPrgs OF Prog;
  nProgs: INTEGER;
  procFile: Prog;
  procName: ARRAY MaxProcs OF Name;
  procLine: ARRAY MaxProcs OF INTEGER;
  nProcs: INTEGER;
  cancelAll, quitting, resumeFlag: BOOLEAN;
  suspendLevel: INTEGER;
  lastKey: INTEGER;            (* READKEY/INKEY support *)
  readExit: INTEGER;           (* READKEY() code of the last READ *)
  getList: ARRAY MaxGets OF GetDef;
  nGets: INTEGER;
  inAssist: BOOLEAN;
  editBuf: TextBuf;


(* ====================================================================
   String helpers
   ==================================================================== *)

PROCEDURE SLen(s: ARRAY OF CHAR): INTEGER;
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (i < LEN(s)) & (s[i] # 0X) DO INC(i) END;
  RETURN i
END SLen;

PROCEDURE Cpy(src: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (i < LEN(src)) & (src[i] # 0X) & (i < LEN(dst) - 1) DO dst[i] := src[i]; INC(i) END;
  dst[i] := 0X
END Cpy;

PROCEDURE Append(extra: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR);
VAR i, j: INTEGER;
BEGIN
  i := SLen(dst); j := 0;
  WHILE (j < LEN(extra)) & (extra[j] # 0X) & (i < LEN(dst) - 1) DO
    dst[i] := extra[j]; INC(i); INC(j)
  END;
  dst[i] := 0X
END Append;

PROCEDURE AppendCh(c: CHAR; VAR dst: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  IF c = 0X THEN RETURN END;  (* refuse to embed a terminator *)
  i := SLen(dst);
  IF i < LEN(dst) - 1 THEN
    dst[i] := c; dst[i + 1] := 0X
  END
END AppendCh;

PROCEDURE AppendInt(n: INTEGER; VAR dst: ARRAY OF CHAR);
VAR t: Str;
BEGIN
  Strings.IntToStr(n, t); Append(t, dst)
END AppendInt;

PROCEDURE UpCh(c: CHAR): CHAR;
BEGIN
  IF (c >= "a") & (c <= "z") THEN c := CHR(ORD(c) - 32) END;
  RETURN c
END UpCh;

PROCEDURE LoCh(c: CHAR): CHAR;
BEGIN
  IF (c >= "A") & (c <= "Z") THEN c := CHR(ORD(c) + 32) END;
  RETURN c
END LoCh;

PROCEDURE Upper(VAR s: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (i < LEN(s)) & (s[i] # 0X) DO s[i] := UpCh(s[i]); INC(i) END
END Upper;

PROCEDURE Lower(VAR s: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (i < LEN(s)) & (s[i] # 0X) DO s[i] := LoCh(s[i]); INC(i) END
END Lower;

PROCEDURE Eq(a, b: ARRAY OF CHAR): BOOLEAN;
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (i < LEN(a)) & (i < LEN(b)) & (a[i] # 0X) & (a[i] = b[i]) DO INC(i) END;
  RETURN ((i >= LEN(a)) OR (a[i] = 0X)) & ((i >= LEN(b)) OR (b[i] = 0X))
END Eq;

(* case-insensitive equality *)
PROCEDURE EqI(a, b: ARRAY OF CHAR): BOOLEAN;
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (i < LEN(a)) & (i < LEN(b)) & (a[i] # 0X) & (UpCh(a[i]) = UpCh(b[i])) DO INC(i) END;
  RETURN ((i >= LEN(a)) OR (a[i] = 0X)) & ((i >= LEN(b)) OR (b[i] = 0X))
END EqI;

(* dBASE keyword match: word may abbreviate kw to four or more letters *)
PROCEDURE Kw(word, kw: ARRAY OF CHAR): BOOLEAN;
VAR i, n, m: INTEGER;
BEGIN
  n := SLen(word); m := SLen(kw);
  IF (n = 0) OR (n > m) THEN RETURN FALSE END;
  IF (n < 4) & (n < m) THEN RETURN FALSE END;
  FOR i := 0 TO n - 1 DO
    IF UpCh(word[i]) # kw[i] THEN RETURN FALSE END
  END;
  RETURN TRUE
END Kw;

PROCEDURE Cmp(a, b: ARRAY OF CHAR): INTEGER;
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (a[i] # 0X) & (a[i] = b[i]) DO INC(i) END;
  IF a[i] = b[i] THEN RETURN 0
  ELSIF ORD(a[i]) < ORD(b[i]) THEN RETURN -1
  ELSE RETURN 1
  END
END Cmp;

PROCEDURE StartsI(s, prefix: ARRAY OF CHAR): BOOLEAN;
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE prefix[i] # 0X DO
    IF UpCh(s[i]) # UpCh(prefix[i]) THEN RETURN FALSE END;
    INC(i)
  END;
  RETURN TRUE
END StartsI;

PROCEDURE RTrim(VAR s: ARRAY OF CHAR);
VAR n: INTEGER;
BEGIN
  n := SLen(s);
  WHILE (n > 0) & (s[n - 1] = " ") DO DEC(n) END;
  s[n] := 0X
END RTrim;

PROCEDURE LTrim(VAR s: ARRAY OF CHAR);
VAR i, j: INTEGER;
BEGIN
  i := 0;
  WHILE s[i] = " " DO INC(i) END;
  IF i > 0 THEN
    j := 0;
    WHILE s[i] # 0X DO s[j] := s[i]; INC(i); INC(j) END;
    s[j] := 0X
  END
END LTrim;

PROCEDURE Trim(VAR s: ARRAY OF CHAR);
BEGIN
  RTrim(s); LTrim(s)
END Trim;

PROCEDURE Sub(s: ARRAY OF CHAR; pos, n: INTEGER; VAR dst: ARRAY OF CHAR);
VAR i, l: INTEGER;
BEGIN
  l := SLen(s); i := 0;
  IF pos < 0 THEN pos := 0 END;
  WHILE (i < n) & (pos + i < l) & (i < LEN(dst) - 1) DO dst[i] := s[pos + i]; INC(i) END;
  dst[i] := 0X
END Sub;

PROCEDURE PadR(VAR s: ARRAY OF CHAR; w: INTEGER);
VAR n: INTEGER;
BEGIN
  n := SLen(s);
  IF w > LEN(s) - 1 THEN w := LEN(s) - 1 END;
  WHILE n < w DO s[n] := " "; INC(n) END;
  IF n > w THEN n := w END;
  s[n] := 0X
END PadR;

PROCEDURE PadL(VAR s: ARRAY OF CHAR; w: INTEGER);
VAR n, i, d: INTEGER;
BEGIN
  n := SLen(s);
  IF w > LEN(s) - 1 THEN w := LEN(s) - 1 END;
  IF n < w THEN
    d := w - n;
    FOR i := n TO 0 BY -1 DO s[i + d] := s[i] END;
    FOR i := 0 TO d - 1 DO s[i] := " " END
  END
END PadL;

PROCEDURE Spaces(n: INTEGER; VAR s: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  IF n > LEN(s) - 1 THEN n := LEN(s) - 1 END;
  IF n < 0 THEN n := 0 END;
  FOR i := 0 TO n - 1 DO s[i] := " " END;
  s[n] := 0X
END Spaces;

PROCEDURE Center(VAR s: ARRAY OF CHAR; w: INTEGER);
VAR n: INTEGER;
BEGIN
  n := SLen(s);
  IF n < w THEN PadL(s, n + (w - n) DIV 2) END
END Center;

PROCEDURE PosI(pat, s: ARRAY OF CHAR): INTEGER;
VAR i, j, n, m: INTEGER;
BEGIN
  n := SLen(s); m := SLen(pat);
  IF m = 0 THEN RETURN 0 END;
  FOR i := 0 TO n - m DO
    j := 0;
    WHILE (j < m) & (s[i + j] = pat[j]) DO INC(j) END;
    IF j = m THEN RETURN i END
  END;
  RETURN -1
END PosI;

PROCEDURE IsDigit(c: CHAR): BOOLEAN;
BEGIN RETURN (c >= "0") & (c <= "9") END IsDigit;

PROCEDURE IsAlpha(c: CHAR): BOOLEAN;
BEGIN RETURN ((c >= "A") & (c <= "Z")) OR ((c >= "a") & (c <= "z")) END IsAlpha;

PROCEDURE IsIdCh(c: CHAR): BOOLEAN;
BEGIN RETURN IsAlpha(c) OR IsDigit(c) OR (c = "_") END IsIdCh;

PROCEDURE IntStr(n: INTEGER; VAR s: ARRAY OF CHAR);
BEGIN Strings.IntToStr(n, s) END IntStr;

PROCEDURE IntStrW(n, w: INTEGER; VAR s: ARRAY OF CHAR);
BEGIN Strings.IntToStr(n, s); PadL(s, w) END IntStrW;

PROCEDURE StrInt(s: ARRAY OF CHAR; VAR n: INTEGER): BOOLEAN;
VAR t: Str;
BEGIN
  Cpy(s, t); Trim(t);
  IF t[0] = "+" THEN t[0] := " "; Trim(t) END;
  RETURN (t[0] # 0X) & Strings.StrToInt(t, n)
END StrInt;

(* VAL-style numeric scan: leading number, stops at first bad char *)
PROCEDURE ScanNum(s: ARRAY OF CHAR; VAR x: REAL; VAR dec: INTEGER);
VAR i, start: INTEGER; t: Str; seenDot: BOOLEAN;
BEGIN
  i := 0; x := 0.0; dec := 0;
  WHILE s[i] = " " DO INC(i) END;
  start := i;
  IF (s[i] = "-") OR (s[i] = "+") THEN INC(i) END;
  seenDot := FALSE;
  WHILE IsDigit(s[i]) OR ((s[i] = ".") & ~seenDot) DO
    IF s[i] = "." THEN seenDot := TRUE ELSIF seenDot THEN INC(dec) END;
    INC(i)
  END;
  IF (s[i] = "E") OR (s[i] = "e") THEN
    IF IsDigit(s[i + 1]) OR (((s[i + 1] = "-") OR (s[i + 1] = "+")) & IsDigit(s[i + 2])) THEN
      INC(i, 2);
      WHILE IsDigit(s[i]) DO INC(i) END
    END
  END;
  Sub(s, start, i - start, t);
  IF (t[0] = "+") THEN t[0] := "0" END;
  IF (SLen(t) > 0) & ~((SLen(t) = 1) & ((t[0] = "-") OR (t[0] = "."))) THEN
    IF t[0] = "." THEN Strings.Insert("0", 0, t) END;
    IF (t[0] = "-") & (t[1] = ".") THEN Strings.Insert("0", 1, t) END;
    IF ~Strings.StrToReal(t, x) THEN x := 0.0 END
  END
END ScanNum;

(* Round half away from zero to dec places *)
PROCEDURE RoundTo(x: REAL; dec: INTEGER): REAL;
VAR scale: REAL; i: INTEGER; neg: BOOLEAN;
BEGIN
  neg := x < 0.0; IF neg THEN x := -x END;
  scale := 1.0;
  IF dec >= 0 THEN
    FOR i := 1 TO dec DO scale := scale * 10.0 END;
    x := Math.floor(x * scale + 0.5 + 1.0E-9) / scale
  ELSE
    FOR i := 1 TO -dec DO scale := scale * 10.0 END;
    x := Math.floor(x / scale + 0.5) * scale
  END;
  IF neg THEN x := -x END;
  RETURN x
END RoundTo;

(* Fixed-point text for x with dec decimals, no padding *)
PROCEDURE FmtFixed(x: REAL; dec: INTEGER; VAR s: ARRAY OF CHAR);
VAR
  scale, v, q: REAL; i, d, n: INTEGER; neg: BOOLEAN;
  digits: ARRAY 64 OF CHAR;
BEGIN
  IF dec < 0 THEN dec := 0 END;
  IF dec > 15 THEN dec := 15 END;
  neg := x < 0.0; IF neg THEN x := -x END;
  scale := 1.0;
  FOR i := 1 TO dec DO scale := scale * 10.0 END;
  v := Math.floor(x * scale + 0.5);
  IF v > 1.0E17 THEN
    Strings.RealToStr(x, s);
    IF neg THEN Strings.Insert("-", 0, s) END;
    RETURN
  END;
  n := 0;
  REPEAT
    q := Math.floor(v / 10.0);
    d := FLOOR(v - q * 10.0 + 0.5);
    IF d > 9 THEN d := 9 END; IF d < 0 THEN d := 0 END;
    digits[n] := CHR(ORD("0") + d); INC(n);
    v := q
  UNTIL (v < 0.5) & (n > dec);
  i := 0;
  IF neg & ~((n = dec + 1) & (Math.floor(x * scale + 0.5) = 0.0)) THEN s[0] := "-"; i := 1 END;
  WHILE n > 0 DO
    DEC(n);
    s[i] := digits[n]; INC(i);
    IF (n = dec) & (dec > 0) THEN s[i] := "."; INC(i) END
  END;
  s[i] := 0X
END FmtFixed;

(* number in a field of width w; asterisks on overflow *)
PROCEDURE FmtNumW(x: REAL; w, dec: INTEGER; VAR s: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  FmtFixed(x, dec, s);
  IF SLen(s) > w THEN
    FOR i := 0 TO w - 1 DO s[i] := "*" END;
    s[w] := 0X
  ELSE
    PadL(s, w)
  END
END FmtNumW;

(* ====================================================================
   Dates (Julian day numbers)
   ==================================================================== *)

PROCEDURE Julian(y, m, d: INTEGER): INTEGER;
VAR a, yy, mm: INTEGER;
BEGIN
  a := (14 - m) DIV 12;
  yy := y + 4800 - a;
  mm := m + 12 * a - 3;
  RETURN d + (153 * mm + 2) DIV 5 + 365 * yy + yy DIV 4 - yy DIV 100 + yy DIV 400 - 32045
END Julian;

PROCEDURE FromJulian(j: INTEGER; VAR y, m, d: INTEGER);
VAR a, b, c, dd, e, mm: INTEGER;
BEGIN
  a := j + 32044;
  b := (4 * a + 3) DIV 146097;
  c := a - (146097 * b) DIV 4;
  dd := (4 * c + 3) DIV 1461;
  e := c - (1461 * dd) DIV 4;
  mm := (5 * e + 2) DIV 153;
  d := e - (153 * mm + 2) DIV 5 + 1;
  m := mm + 3 - 12 * (mm DIV 10);
  y := 100 * b + dd - 4800 + mm DIV 10
END FromJulian;

PROCEDURE ValidDate(y, m, d: INTEGER): BOOLEAN;
VAR yy, mm, dd: INTEGER;
BEGIN
  IF (m < 1) OR (m > 12) OR (d < 1) OR (d > 31) OR (y < 100) THEN RETURN FALSE END;
  FromJulian(Julian(y, m, d), yy, mm, dd);
  RETURN (yy = y) & (mm = m) & (dd = d)
END ValidDate;

PROCEDURE Today(): INTEGER;
VAR t: ARRAY 16 OF CHAR; y, m, d: INTEGER; now: LONGINT;
BEGIN
  now := Time.Now();
  Time.Format(now, "%Y", t); Strings.StrToInt(t, y);
  Time.Format(now, "%m", t); Strings.StrToInt(t, m);
  Time.Format(now, "%d", t); Strings.StrToInt(t, d);
  RETURN Julian(y, m, d)
END Today;

PROCEDURE Two(n: INTEGER; VAR s: ARRAY OF CHAR);
BEGIN
  s[0] := CHR(ORD("0") + (n DIV 10) MOD 10);
  s[1] := CHR(ORD("0") + n MOD 10);
  s[2] := 0X
END Two;

(* DTOC according to SET DATE and SET CENTURY *)
PROCEDURE DateStr(j: INTEGER; VAR s: ARRAY OF CHAR);
VAR y, m, d: INTEGER; a, b, c: ARRAY 8 OF CHAR; sep: CHAR;
BEGIN
  IF j <= 0 THEN
    IF setCentury THEN Cpy("  /  /    ", s) ELSE Cpy("  /  /  ", s) END;
    IF setDateFmt = 1 THEN
      IF setCentury THEN Cpy("    .  .  ", s) ELSE Cpy("  .  .  ", s) END
    ELSIF (setDateFmt = 3) THEN
      IF setCentury THEN Cpy("  -  -    ", s) ELSE Cpy("  -  -  ", s) END
    ELSIF setDateFmt = 5 THEN
      IF setCentury THEN Cpy("  .  .    ", s) ELSE Cpy("  .  .  ", s) END
    END;
    RETURN
  END;
  FromJulian(j, y, m, d);
  IF setCentury THEN IntStr(y, c) ELSE Two(y MOD 100, c) END;
  Two(m, a); Two(d, b);
  CASE setDateFmt OF
    0: sep := "/"; Cpy(a, s); AppendCh(sep, s); Append(b, s); AppendCh(sep, s); Append(c, s)
  | 1: sep := "."; Cpy(c, s); AppendCh(sep, s); Append(a, s); AppendCh(sep, s); Append(b, s)
  | 2, 4: sep := "/"; Cpy(b, s); AppendCh(sep, s); Append(a, s); AppendCh(sep, s); Append(c, s)
  | 3: sep := "-"; Cpy(b, s); AppendCh(sep, s); Append(a, s); AppendCh(sep, s); Append(c, s)
  | 5: sep := "."; Cpy(b, s); AppendCh(sep, s); Append(a, s); AppendCh(sep, s); Append(c, s)
  ELSE Cpy(a, s); AppendCh("/", s); Append(b, s); AppendCh("/", s); Append(c, s)
  END
END DateStr;

(* CTOD: parse a date in the SET DATE order; 0 if blank or invalid *)
PROCEDURE ParseDate(s: ARRAY OF CHAR): INTEGER;
VAR p: ARRAY 3 OF INTEGER; i, k, n: INTEGER; any: BOOLEAN; y, m, d: INTEGER;
BEGIN
  k := 0; i := 0; p[0] := 0; p[1] := 0; p[2] := 0; any := FALSE;
  WHILE (s[i] # 0X) & (k < 3) DO
    IF IsDigit(s[i]) THEN
      n := 0;
      WHILE IsDigit(s[i]) DO n := n * 10 + ORD(s[i]) - ORD("0"); INC(i) END;
      p[k] := n; INC(k); any := TRUE
    ELSE INC(i)
    END
  END;
  IF ~any OR (k < 3) THEN RETURN 0 END;
  CASE setDateFmt OF
    1: y := p[0]; m := p[1]; d := p[2]
  | 2, 3, 4, 5: d := p[0]; m := p[1]; y := p[2]
  ELSE m := p[0]; d := p[1]; y := p[2]
  END;
  IF y < 100 THEN INC(y, 1900) END;
  IF ~ValidDate(y, m, d) THEN RETURN 0 END;
  RETURN Julian(y, m, d)
END ParseDate;

(* field storage form YYYYMMDD <-> Julian *)
PROCEDURE DateFromDbf(s: ARRAY OF CHAR): INTEGER;
VAR y, m, d, i: INTEGER;
BEGIN
  FOR i := 0 TO 7 DO IF ~IsDigit(s[i]) THEN RETURN 0 END END;
  y := 0; m := 0; d := 0;
  FOR i := 0 TO 3 DO y := y * 10 + ORD(s[i]) - ORD("0") END;
  FOR i := 4 TO 5 DO m := m * 10 + ORD(s[i]) - ORD("0") END;
  FOR i := 6 TO 7 DO d := d * 10 + ORD(s[i]) - ORD("0") END;
  IF ~ValidDate(y, m, d) THEN RETURN 0 END;
  RETURN Julian(y, m, d)
END DateFromDbf;

PROCEDURE DateToDbf(j: INTEGER; VAR s: ARRAY OF CHAR);
VAR y, m, d: INTEGER; t: ARRAY 8 OF CHAR;
BEGIN
  IF j <= 0 THEN Cpy("        ", s); RETURN END;
  FromJulian(j, y, m, d);
  IntStr(y, s); WHILE SLen(s) < 4 DO Strings.Insert("0", 0, s) END;
  Two(m, t); Append(t, s); Two(d, t); Append(t, s)
END DateToDbf;

PROCEDURE DayOfWeek(j: INTEGER): INTEGER;   (* 1 = Sunday *)
BEGIN
  RETURN (j + 1) MOD 7 + 1
END DayOfWeek;

PROCEDURE DayName(n: INTEGER; VAR s: ARRAY OF CHAR);
BEGIN
  CASE n OF
    1: Cpy("Sunday", s) | 2: Cpy("Monday", s) | 3: Cpy("Tuesday", s)
  | 4: Cpy("Wednesday", s) | 5: Cpy("Thursday", s) | 6: Cpy("Friday", s)
  | 7: Cpy("Saturday", s)
  ELSE s[0] := 0X
  END
END DayName;

PROCEDURE MonthName(n: INTEGER; VAR s: ARRAY OF CHAR);
BEGIN
  CASE n OF
    1: Cpy("January", s) | 2: Cpy("February", s) | 3: Cpy("March", s)
  | 4: Cpy("April", s) | 5: Cpy("May", s) | 6: Cpy("June", s)
  | 7: Cpy("July", s) | 8: Cpy("August", s) | 9: Cpy("September", s)
  | 10: Cpy("October", s) | 11: Cpy("November", s) | 12: Cpy("December", s)
  ELSE s[0] := 0X
  END
END MonthName;

(* ====================================================================
   Values
   ==================================================================== *)

PROCEDURE SetNum(VAR v: Value; x: REAL; w, dec: INTEGER);
BEGIN
  v.t := TN; v.n := x; v.w := w; v.dec := dec; v.s[0] := 0X
END SetNum;

PROCEDURE SetInt(VAR v: Value; n: INTEGER);
BEGIN
  SetNum(v, FLT(n), 10, 0)
END SetInt;

PROCEDURE SetStr(VAR v: Value; s: ARRAY OF CHAR);
BEGIN
  v.t := TC; Cpy(s, v.s)
END SetStr;

PROCEDURE SetBool(VAR v: Value; b: BOOLEAN);
BEGIN
  v.t := TL; v.b := b; v.s[0] := 0X
END SetBool;

PROCEDURE SetDate(VAR v: Value; j: INTEGER);
BEGIN
  v.t := TD; v.d := j; v.s[0] := 0X
END SetDate;

(* dBASE III PLUS error number for a message (as kept by FoxBASE) *)
PROCEDURE ErrCodeOf(msg: ARRAY OF CHAR): INTEGER;
BEGIN
  IF Eq(msg, "File does not exist.") THEN RETURN 1
  ELSIF Eq(msg, "File is already open.") THEN RETURN 3
  ELSIF Eq(msg, "End of file encountered.") THEN RETURN 4
  ELSIF Eq(msg, "Record is out of range.") THEN RETURN 5
  ELSIF Eq(msg, "Too many indexes.") THEN RETURN 6
  ELSIF Eq(msg, "File already exists.") THEN RETURN 7
  ELSIF Eq(msg, "Data type mismatch.") THEN RETURN 9
  ELSIF Eq(msg, "Syntax error.") OR Eq(msg, "Missing expression.") OR Eq(msg, "Unbalanced parenthesis.")
     OR Eq(msg, "Unterminated string.") THEN RETURN 10
  ELSIF Eq(msg, "Invalid function argument.") THEN RETURN 11
  ELSIF Eq(msg, "Variable not found.") THEN RETURN 12
  ELSIF Eq(msg, "ALIAS not found.") THEN RETURN 13
  ELSIF Eq(msg, "Not a dBASE database.") THEN RETURN 15
  ELSIF Eq(msg, "Unrecognized command verb.") THEN RETURN 16
  ELSIF Eq(msg, "Line exceeds maximum of 254 characters.") THEN RETURN 18
  ELSIF Eq(msg, "Index file does not match database.") OR Eq(msg, "Not a dBASE index file.") THEN RETURN 19
  ELSIF Eq(msg, "Out of memory variable slots.") THEN RETURN 22
  ELSIF Eq(msg, "Invalid index expression.") THEN RETURN 23
  ELSIF Eq(msg, "ALIAS name already in use.") THEN RETURN 24
  ELSIF Eq(msg, "Database is not indexed.") THEN RETURN 26
  ELSIF Eq(msg, "Not a numeric expression.") THEN RETURN 27
  ELSIF Eq(msg, "Cannot sort on logical or memo fields.") THEN RETURN 34
  ELSIF Eq(msg, "Unrecognized phrase/keyword in command.") THEN RETURN 36
  ELSIF Eq(msg, "Not a Logical expression.") THEN RETURN 37
  ELSIF Eq(msg, "Beginning of file encountered.") THEN RETURN 38
  ELSIF Eq(msg, "Numeric overflow.") OR Eq(msg, "Division by zero.") THEN RETURN 39
  ELSIF Eq(msg, "CONTINUE without LOCATE.") THEN RETURN 42
  ELSIF Eq(msg, "Not a Character expression.") THEN RETURN 45
  ELSIF Eq(msg, "Not a valid report form.") THEN RETURN 50
  ELSIF Eq(msg, "No database is in USE.") THEN RETURN 52
  ELSIF Eq(msg, "Not a valid label form.") THEN RETURN 54
  ELSIF Eq(msg, "Binary (.BIN) modules are not supported.") THEN RETURN 91
  ELSIF Eq(msg, "Wrong number of parameters.") THEN RETURN 94
  ELSIF Eq(msg, "Valid only in programs.") OR Eq(msg, "PARAMETERS is only valid in a program.") THEN RETURN 95
  ELSIF Eq(msg, "IF without ENDIF.") OR Eq(msg, "DO WHILE without ENDDO.") THEN RETURN 96
  ELSIF Eq(msg, "Unable to create file.") THEN RETURN 102
  ELSIF Eq(msg, "Too many nested DO commands.") THEN RETURN 103
  ELSIF Eq(msg, "Invalid function key.") THEN RETURN 104
  ELSE RETURN 0
  END
END ErrCodeOf;

PROCEDURE Err(msg: ARRAY OF CHAR);
BEGIN
  IF ~err THEN err := TRUE; Cpy(msg, errMsg); errCode := ErrCodeOf(msg) END
END Err;

(* display text for a value, as ? shows it *)
PROCEDURE ValStr(VAR v: Value; VAR s: ARRAY OF CHAR);
VAR w: INTEGER;
BEGIN
  CASE v.t OF
    "C": Cpy(v.s, s)
  | "N":
      FmtFixed(v.n, v.dec, s);
      w := v.w; IF w < 1 THEN w := 10 END;
      IF SLen(s) < w THEN PadL(s, w) END
  | "L": IF v.b THEN Cpy(".T.", s) ELSE Cpy(".F.", s) END
  | "D": DateStr(v.d, s)
  ELSE Cpy("", s)
  END
END ValStr;

(* compact text form: numbers without leading blanks *)
PROCEDURE ValText(VAR v: Value; VAR s: ARRAY OF CHAR);
BEGIN
  IF v.t = TN THEN FmtFixed(v.n, v.dec, s) ELSE ValStr(v, s) END
END ValText;

(* ====================================================================
   Console grid
   The user area is a character grid like the PC text screen dBASE ran
   on.  ? and LIST output flow through it and scroll; @...SAY writes at
   fixed positions.  Lines scrolled off the top are kept for PgUp.
   ==================================================================== *)

PROCEDURE ScreenSize;
BEGIN
  IF batch THEN scrW := 80; scrH := 24; RETURN END;
  scrW := TUI.Cols; IF scrW > MaxSC THEN scrW := MaxSC END;
  IF setStatus THEN scrH := TUI.Rows - 3 ELSE scrH := TUI.Rows - 1 END;
  IF scrH > MaxSR THEN scrH := MaxSR END;
  IF scrH < 5 THEN scrH := 5 END;
  IF crow >= scrH THEN crow := scrH - 1 END;
  IF ccol >= scrW THEN ccol := scrW - 1 END
END ScreenSize;

PROCEDURE ClearRow(r: INTEGER);
VAR c: INTEGER;
BEGIN
  FOR c := 0 TO MaxSC - 1 DO scr[r][c] := " "; att[r][c] := CHR(aNorm) END;
  scr[r][MaxSC] := 0X
END ClearRow;

PROCEDURE ConClear;
VAR r: INTEGER;
BEGIN
  FOR r := 0 TO MaxSR - 1 DO ClearRow(r) END;
  crow := 0; ccol := 0
END ConClear;

PROCEDURE PushHist(r: INTEGER);
VAR t: Str; i: INTEGER;
BEGIN
  i := 0;
  WHILE (i < scrW) & (i < 255) DO t[i] := scr[r][i]; INC(i) END;
  t[i] := 0X; RTrim(t);
  Cpy(t, histLn[(histTop + histN) MOD MaxHistLn]);
  IF histN < MaxHistLn THEN INC(histN) ELSE histTop := (histTop + 1) MOD MaxHistLn END
END PushHist;

PROCEDURE ConScroll;
VAR r: INTEGER;
BEGIN
  PushHist(0);
  FOR r := 0 TO scrH - 2 DO scr[r] := scr[r + 1]; att[r] := att[r + 1] END;
  ClearRow(scrH - 1)
END ConScroll;

(* ---- status bar ---- *)

PROCEDURE StatusText(VAR s: ARRAY OF CHAR);
VAR t: Str; a: INTEGER;
BEGIN
  Cpy(" ", s); Append(modeName, s); PadR(s, 14);
  Append(" ", s); AppendCh(01X, s);
  Append("<", s); AppendCh(defDrive, s); Append(":>", s); AppendCh(01X, s);
  t[0] := 0X;
  IF areas[cur].used THEN Cpy(areas[cur].alias, t) END;
  PadR(t, 12); Append(t, s); AppendCh(01X, s);
  a := cur;
  IF areas[a].used THEN
    Cpy("Rec: ", t);
    IF areas[a].db.numRecs = 0 THEN Append("None", t)
    ELSIF areas[a].rec > areas[a].db.numRecs THEN
      Append("EOF/", t); AppendInt(areas[a].db.numRecs, t)
    ELSE
      AppendInt(areas[a].rec, t); Append("/", t); AppendInt(areas[a].db.numRecs, t)
    END
  ELSE t[0] := 0X
  END;
  PadR(t, 16); Append(t, s); AppendCh(01X, s);
  t[0] := 0X;
  IF areas[a].used & (areas[a].rec <= areas[a].db.numRecs) & (areas[a].buf[0] = "*")
     & (areas[a].bufRec = areas[a].rec) THEN Cpy("Del", t) END;
  PadR(t, 5); Append(t, s); AppendCh(01X, s);
  IF insMode THEN Append("Ins", s) ELSE Append("   ", s) END
END StatusText;

(* draw text cell by cell; 01X stands for the vertical bar glyph *)
PROCEDURE PutBar(x, y: INTEGER; s: ARRAY OF CHAR; fg, bg: INTEGER);
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE s[i] # 0X DO
    IF s[i] = 01X THEN TUI.PutCell(x + i, y, TUI.BoxV, fg, bg) ELSE TUI.PutCell(x + i, y, s[i], fg, bg) END;
    INC(i)
  END
END PutBar;

PROCEDURE DrawBars;
VAR s: Str; y: INTEGER;
BEGIN
  IF ~setStatus THEN RETURN END;
  y := scrH + 1;
  StatusText(s);
  TUI.FillRect(1, y, scrW, 1, " ", cRevFg, cRevBg);
  PutBar(1, y, s, cRevFg, cRevBg);
  TUI.PutStr(1, y + 1, navLine, cFg, cBg);
  TUI.PutStr(1, y + 2, msgLine, cHiFg, cBg)
END DrawBars;

(* Paint the console grid plus bars; cursor at (cx, cy) 0-based or hidden *)
PROCEDURE DrawConsoleAt(cx, cy: INTEGER; showCur: BOOLEAN);
VAR r, c: INTEGER; fg, bg: INTEGER;
BEGIN
  IF batch THEN RETURN END;
  TUI.ClearBack(cFg, cBg);
  FOR r := 0 TO scrH - 1 DO
    FOR c := 0 TO scrW - 1 DO
      fg := cFg; bg := cBg;
      IF att[r][c] = CHR(aRev) THEN fg := cRevFg; bg := cRevBg
      ELSIF att[r][c] = CHR(aBold) THEN fg := cHiFg
      END;
      TUI.PutCell(c + 1, r + 1, scr[r][c], fg, bg)
    END
  END;
  DrawBars;
  TUI.Flush;
  IF showCur THEN TUI.SetCursor(cx + 1, cy + 1) ELSE Terminal.HideCursor() END;
  lastDraw := Time.Now()
END DrawConsoleAt;

PROCEDURE DrawConsole;
BEGIN
  DrawConsoleAt(ccol, crow, FALSE)
END DrawConsole;

(* throttled redraw while output is streaming *)
PROCEDURE MaybeDraw;
BEGIN
  IF ~batch & (Time.Now() - lastDraw > 40) THEN DrawConsole END
END MaybeDraw;

(* ---- keyboard ---- *)

(* Next key; 0X after a resize or mouse event so callers can redraw *)
PROCEDURE PopTypeahead(): CHAR;
VAR c: CHAR; i: INTEGER;
BEGIN
  c := taBuf[0];
  FOR i := 1 TO taN - 1 DO taBuf[i - 1] := taBuf[i] END;
  DEC(taN);
  RETURN c
END PopTypeahead;

PROCEDURE PushTypeahead(c: CHAR);
BEGIN
  IF taN < LEN(taBuf) THEN taBuf[taN] := c; INC(taN) END
END PushTypeahead;

PROCEDURE GetKey(): CHAR;
VAR ev: TUI.Event; c: CHAR;
BEGIN
  IF batch THEN RETURN KCtrlW END;
  IF taN > 0 THEN c := PopTypeahead(); lastKey := ORD(c); RETURN c END;
  LOOP
    IF TUI.PollEvent(ev) THEN
      IF ev.kind = TUI.EvKey THEN
        c := ev.key; lastKey := ORD(c); RETURN c
      ELSIF ev.kind = TUI.EvResize THEN
        TUI.InvalidateFront; ScreenSize; RETURN 0X
      END
    ELSE
      Time.Sleep(8)
    END
  END
END GetKey;

(* Non-blocking: Esc pressed (with SET ESCAPE ON)?  Other keys go to
   the typeahead buffer for INKEY(), ON KEY and the next input. *)
PROCEDURE EscPressed(): BOOLEAN;
VAR ev: TUI.Event;
BEGIN
  IF batch THEN RETURN FALSE END;
  WHILE TUI.PollEvent(ev) DO
    IF ev.kind = TUI.EvKey THEN
      IF (ev.key = TUI.KEsc) & setEscape THEN lastKey := ORD(ev.key); RETURN TRUE END;
      PushTypeahead(ev.key)
    END
  END;
  RETURN FALSE
END EscPressed;

(* ---- output plumbing ---- *)

PROCEDURE OpenAppend(name: ARRAY OF CHAR; VAR f: Files.File; VAR r: Files.Rider);
BEGIN
  f := Files.Old(name);
  IF f = NIL THEN f := Files.New(name); IF f # NIL THEN Files.Set(r, f, 0) END
  ELSE Files.Set(r, f, Files.Length(f))
  END
END OpenAppend;

PROCEDURE WriteStr(VAR r: Files.Rider; s: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE s[i] # 0X DO Files.Write(r, ORD(s[i])); INC(i) END
END WriteStr;

PROCEDURE Printing(): BOOLEAN;
BEGIN RETURN setPrint OR prnActive END Printing;

PROCEDURE PrnStr(s: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  IF prnF = NIL THEN OpenAppend(prnName, prnF, prnR) END;
  IF prnF # NIL THEN
    IF (pcol = 0) & (setMargin > 0) THEN
      FOR i := 1 TO setMargin DO Files.Write(prnR, ORD(" ")) END
    END;
    WriteStr(prnR, s); INC(pcol, SLen(s))
  END
END PrnStr;

PROCEDURE PrnNL;
BEGIN
  IF prnF = NIL THEN OpenAppend(prnName, prnF, prnR) END;
  IF prnF # NIL THEN Files.Write(prnR, 10); Files.Register(prnF) END;
  pcol := 0; INC(prow)
END PrnNL;

PROCEDURE PrnEject;
BEGIN
  IF prnF = NIL THEN OpenAppend(prnName, prnF, prnR) END;
  IF prnF # NIL THEN Files.Write(prnR, 12); Files.Register(prnF) END;
  prow := 0; pcol := 0
END PrnEject;

PROCEDURE ConPut(s: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  IF batch THEN Out.String(s); IF s[0] # 0X THEN batchMid := TRUE END; RETURN END;
  i := 0;
  WHILE s[i] # 0X DO
    IF ccol >= scrW THEN
      ccol := 0; INC(crow);
      IF crow >= scrH THEN ConScroll; crow := scrH - 1 END
    END;
    IF s[i] < " " THEN scr[crow][ccol] := " " ELSE scr[crow][ccol] := s[i] END;
    att[crow][ccol] := CHR(aNorm);
    INC(ccol); INC(i)
  END
END ConPut;

PROCEDURE PauseKey(): BOOLEAN; (* TRUE = keep going *)
VAR k: CHAR; r, c: INTEGER; msg: Str;
BEGIN
  Cpy("Press any key to continue...", msg);
  IF inAssist THEN Cpy("Press any key to continue work in ASSIST...", msg) END;
  r := scrH - 1;
  ConScroll;
  FOR c := 0 TO SLen(msg) - 1 DO scr[r][c] := msg[c] END;
  DrawConsole;
  REPEAT k := GetKey() UNTIL k # 0X;
  ClearRow(r);
  crow := r; ccol := 0;
  IF k = TUI.KEsc THEN interrupted := TRUE; RETURN FALSE END;
  RETURN TRUE
END PauseKey;

PROCEDURE ConNL;
BEGIN
  IF batch THEN Out.Ln; batchMid := FALSE; RETURN END;
  ccol := 0; INC(crow);
  IF crow >= scrH THEN ConScroll; crow := scrH - 1 END;
  IF paging THEN
    INC(pageCount);
    IF pageCount >= scrH - 2 THEN
      pageCount := 0;
      IF ~PauseKey() THEN END
    END
  END;
  MaybeDraw
END ConNL;

PROCEDURE OutStr(s: ARRAY OF CHAR);
BEGIN
  IF setConsole THEN ConPut(s) END;
  IF Printing() THEN PrnStr(s) END;
  IF setAlternate & (altF # NIL) THEN WriteStr(altR, s) END;
  IF toActive & (toF # NIL) THEN WriteStr(toR, s) END
END OutStr;

PROCEDURE OutNL;
BEGIN
  IF setConsole THEN ConNL END;
  IF Printing() THEN PrnNL END;
  IF setAlternate & (altF # NIL) THEN Files.Write(altR, 10) END;
  IF toActive & (toF # NIL) THEN Files.Write(toR, 10) END
END OutNL;

(* the usual pattern: new line, then text *)
PROCEDURE Line(s: ARRAY OF CHAR);
BEGIN
  OutNL; OutStr(s)
END Line;

(* talk messages go to the screen only, and only with SET TALK ON *)
PROCEDURE Talk(s: ARRAY OF CHAR);
BEGIN
  IF setTalk & setConsole THEN ConNL; ConPut(s) END
END Talk;


(* "n record(s) <verb>" *)
PROCEDURE TalkCount(n: INTEGER; verb: ARRAY OF CHAR);
VAR t: Str;
BEGIN
  IntStrW(n, 6, t);
  IF n = 1 THEN Append(" record ", t) ELSE Append(" records ", t) END;
  Append(verb, t);
  Talk(t)
END TalkCount;

PROCEDURE SetMsg(s: ARRAY OF CHAR);
BEGIN Cpy(s, msgLine) END SetMsg;

PROCEDURE SetNav(s: ARRAY OF CHAR);
BEGIN Cpy(s, navLine) END SetNav;

PROCEDURE Bell;
BEGIN
  IF setBell & ~batch THEN Out.Char(07X); Out.Flush END
END Bell;

(* ---- scrollback viewer (PgUp at the dot prompt) ---- *)

PROCEDURE ViewHistory;
VAR total, top, r, i, c: INTEGER; k: CHAR; t: Str;
BEGIN
  total := histN + scrH;
  top := total - scrH - (scrH - 1);
  IF top < 0 THEN top := 0 END;
  LOOP
    TUI.ClearBack(cFg, cBg);
    FOR r := 0 TO scrH - 1 DO
      i := top + r;
      IF i < histN THEN
        TUI.PutStr(1, r + 1, histLn[(histTop + i) MOD MaxHistLn], cFg, cBg)
      ELSIF i < total THEN
        FOR c := 0 TO scrW - 1 DO t[c] := scr[i - histN][c] END; t[scrW] := 0X;
        TUI.PutStr(1, r + 1, t, cFg, cBg)
      END
    END;
    TUI.FillRect(1, scrH + 1, scrW, 1, " ", cRevFg, cRevBg);
    TUI.PutStr(2, scrH + 1, "Scrollback -- PgUp/PgDn/arrows to scroll, Esc to return", cRevFg, cRevBg);
    TUI.Flush; Terminal.HideCursor();
    k := GetKey();
    IF (k = TUI.KPgUp) OR (k = KCtrlR) THEN DEC(top, scrH - 1)
    ELSIF (k = TUI.KPgDn) OR (k = KCtrlC) THEN INC(top, scrH - 1)
    ELSIF (k = TUI.KUp) OR (k = KCtrlE) THEN DEC(top)
    ELSIF (k = TUI.KDown) OR (k = KCtrlX) THEN INC(top)
    ELSIF k = TUI.KHome THEN top := 0
    ELSIF (k = TUI.KEsc) OR (k = TUI.KEnter) OR (k = TUI.KEnd) THEN EXIT
    END;
    IF top > total - scrH THEN top := total - scrH END;
    IF top < 0 THEN top := 0 END;
    IF (k = TUI.KPgDn) & (top >= total - scrH) THEN EXIT END
  END;
  TUI.InvalidateFront
END ViewHistory;

(* ---- line input on the console ----
   Edits text at the cursor position after prompt.  Up/Down recall
   history when hist is TRUE.  Returns FALSE on Esc. *)
PROCEDURE ReadLine(prompt: ARRAY OF CHAR; VAR s: ARRAY OF CHAR; maxLen: INTEGER;
                   hist: BOOLEAN): BOOLEAN;
VAR
  pos, scroll, hpos, startCol, room, i, n: INTEGER;
  k: CHAR; ok: BOOLEAN; line: Str;
BEGIN
  IF batch THEN s[0] := 0X; RETURN FALSE END;
  IF maxLen > LEN(s) - 1 THEN maxLen := LEN(s) - 1 END;
  IF maxLen > 254 THEN maxLen := 254 END;
  ConPut(prompt);
  startCol := ccol;
  IF startCol >= scrW - 4 THEN ConNL; startCol := 0 END;
  room := scrW - startCol - 1;
  pos := SLen(s); scroll := 0; hpos := nCmdHist;
  LOOP
    n := SLen(s);
    IF pos > n THEN pos := n END;
    IF pos < scroll THEN scroll := pos END;
    IF pos - scroll > room THEN scroll := pos - room END;
    FOR i := 0 TO room DO
      IF scroll + i < n THEN scr[crow][startCol + i] := s[scroll + i]
      ELSE scr[crow][startCol + i] := " "
      END
    END;
    DrawConsoleAt(startCol + pos - scroll, crow, TRUE);
    k := GetKey();
    IF k = TUI.KEnter THEN ok := TRUE; EXIT
    ELSIF k = TUI.KEsc THEN ok := FALSE; EXIT
    ELSIF (k = TUI.KLeft) OR (k = KCtrlS) THEN IF pos > 0 THEN DEC(pos) END
    ELSIF (k = TUI.KRight) OR (k = KCtrlD) THEN IF pos < n THEN INC(pos) END
    ELSIF (k = TUI.KHome) OR (k = KCtrlA) THEN pos := 0
    ELSIF (k = TUI.KEnd) OR (k = KCtrlF) THEN pos := n
    ELSIF k = TUI.KBackspace THEN
      IF pos > 0 THEN Strings.Delete(s, pos - 1, 1); DEC(pos) END
    ELSIF (k = TUI.KDel) OR (k = KCtrlG) THEN
      IF pos < n THEN Strings.Delete(s, pos, 1) END
    ELSIF k = KCtrlY THEN s[0] := 0X; pos := 0
    ELSIF (k = TUI.KUp) OR (k = KCtrlE) THEN
      IF hist & (hpos > 0) THEN DEC(hpos); Cpy(cmdHist[hpos], s); pos := SLen(s) END
    ELSIF (k = TUI.KDown) OR (k = KCtrlX) THEN
      IF hist & (hpos < nCmdHist) THEN
        INC(hpos);
        IF hpos = nCmdHist THEN s[0] := 0X ELSE Cpy(cmdHist[hpos], s) END;
        pos := SLen(s)
      END
    ELSIF ((k = TUI.KPgUp) OR (k = KCtrlR)) & hist THEN
      ViewHistory
    ELSIF k = KCtrlV THEN insMode := ~insMode
    ELSIF hist & (k >= TUI.KF1) & (k <= TUI.KF10) & (n = 0) THEN
      Cpy(fkeys[ORD(k) - ORD(TUI.KF1)], line);
      n := SLen(line);
      IF (n > 0) & (line[n - 1] = ";") THEN
        line[n - 1] := 0X; Cpy(line, s); ok := TRUE; EXIT
      ELSE Cpy(line, s); pos := SLen(s)
      END
    ELSIF (k >= " ") & (k < 7FX) THEN
      IF insMode OR (pos >= n) THEN
        IF n < maxLen THEN
          line[0] := k; line[1] := 0X; Strings.Insert(line, pos, s); INC(pos)
        ELSE Bell
        END
      ELSE
        s[pos] := k; INC(pos)
      END
    END
  END;
  (* leave the final text on the grid *)
  n := SLen(s);
  FOR i := 0 TO room DO
    IF i < n THEN scr[crow][startCol + i] := s[i] ELSE scr[crow][startCol + i] := " " END
  END;
  ccol := startCol + n; IF ccol >= scrW THEN ccol := scrW - 1 END;
  Terminal.HideCursor();
  RETURN ok
END ReadLine;

PROCEDURE AddHistory(s: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  IF (s[0] = 0X) OR (setHistory = 0) THEN RETURN END;
  IF (nCmdHist > 0) & Eq(cmdHist[nCmdHist - 1], s) THEN RETURN END;
  IF nCmdHist >= MaxCmdHist THEN
    FOR i := 0 TO MaxCmdHist - 2 DO Cpy(cmdHist[i + 1], cmdHist[i]) END;
    DEC(nCmdHist)
  END;
  Cpy(s, cmdHist[nCmdHist]); INC(nCmdHist)
END AddHistory;

(* single-key Y/N question on the console *)
PROCEDURE AskYN(prompt: ARRAY OF CHAR): BOOLEAN;
VAR k: CHAR;
BEGIN
  IF batch THEN RETURN TRUE END;
  ConNL; ConPut(prompt); ConPut(" ");
  REPEAT
    DrawConsoleAt(ccol, crow, TRUE);
    k := UpCh(GetKey())
  UNTIL (k = "Y") OR (k = "N") OR (k = TUI.KEsc) OR (k = TUI.KEnter);
  IF k = "Y" THEN ConPut("Y") ELSE ConPut("N") END;
  Terminal.HideCursor();
  RETURN k = "Y"
END AskYN;

(* WAIT-style single key *)
PROCEDURE WaitKeyMsg(prompt: ARRAY OF CHAR): CHAR;
VAR k: CHAR;
BEGIN
  IF batch THEN RETURN " " END;
  ConNL; ConPut(prompt);
  REPEAT
    DrawConsoleAt(ccol, crow, TRUE);
    k := GetKey()
  UNTIL k # 0X;
  Terminal.HideCursor();
  RETURN k
END WaitKeyMsg;

(* ====================================================================
   Lexer -- shared by the command parser and the expression compiler
   ==================================================================== *)

TYPE
  LexState = RECORD
    src, str: Str;
    sp, tk, start, dec: INTEGER;
    num: REAL
  END;

PROCEDURE SaveLex(VAR l: LexState);
BEGIN
  Cpy(src, l.src); l.sp := sp; l.tk := tk; l.start := tkStart;
  Cpy(tkStr, l.str); l.num := tkNum; l.dec := tkDec
END SaveLex;

PROCEDURE RestoreLex(VAR l: LexState);
BEGIN
  Cpy(l.src, src); sp := l.sp; tk := l.tk; tkStart := l.start;
  Cpy(l.str, tkStr); tkNum := l.num; tkDec := l.dec
END RestoreLex;

PROCEDURE DotWord(w: ARRAY OF CHAR): BOOLEAN;  (* src[sp] = "." *)
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE w[i] # 0X DO
    IF UpCh(src[sp + 1 + i]) # w[i] THEN RETURN FALSE END;
    INC(i)
  END;
  RETURN src[sp + 1 + i] = "."
END DotWord;

PROCEDURE Next;
VAR c, q: CHAR; i: INTEGER; x: REAL;
BEGIN
  WHILE (src[sp] = " ") OR (src[sp] = 09X) DO INC(sp) END;
  tkStart := sp; tkStr[0] := 0X;
  c := src[sp];
  IF c = 0X THEN tk := tEOF
  ELSIF IsAlpha(c) OR (c = "_") THEN
    i := 0;
    WHILE IsIdCh(src[sp]) DO
      IF i < 255 THEN tkStr[i] := src[sp]; INC(i) END; INC(sp)
    END;
    tkStr[i] := 0X; tk := tIdent
  ELSIF IsDigit(c) OR ((c = ".") & IsDigit(src[sp + 1])) THEN
    i := 0;
    WHILE IsDigit(src[sp]) OR (src[sp] = ".") DO
      IF i < 255 THEN tkStr[i] := src[sp]; INC(i) END; INC(sp)
    END;
    tkStr[i] := 0X;
    ScanNum(tkStr, x, tkDec); tkNum := x; tk := tNum
  ELSIF (c = "'") OR (c = '"') OR (c = "[") THEN
    IF c = "[" THEN q := "]" ELSE q := c END;
    INC(sp); i := 0;
    WHILE (src[sp] # 0X) & (src[sp] # q) DO
      IF i < 255 THEN tkStr[i] := src[sp]; INC(i) END; INC(sp)
    END;
    tkStr[i] := 0X;
    IF src[sp] = q THEN INC(sp); tk := tStr ELSE tk := tOther; Err("Unterminated string.") END
  ELSIF c = "." THEN
    IF DotWord("AND") THEN tk := tAnd; INC(sp, 5)
    ELSIF DotWord("OR") THEN tk := tOr; INC(sp, 4)
    ELSIF DotWord("NOT") THEN tk := tNot; INC(sp, 5)
    ELSIF DotWord("T") OR DotWord("Y") THEN tk := tTrue; INC(sp, 3)
    ELSIF DotWord("F") OR DotWord("N") THEN tk := tFalse; INC(sp, 3)
    ELSE tk := tOther; tkStr[0] := c; tkStr[1] := 0X; INC(sp)
    END
  ELSE
    INC(sp);
    CASE c OF
      "(": tk := tLP
    | ")": tk := tRP
    | ",": tk := tComma
    | "+": tk := tPlus
    | "-": IF src[sp] = ">" THEN INC(sp); tk := tArrow ELSE tk := tMinus END
    | "*": IF src[sp] = "*" THEN INC(sp); tk := tPow ELSE tk := tStar END
    | "/": tk := tSlash
    | "^": tk := tPow
    | "%": tk := tPct
    | "=": IF src[sp] = "=" THEN INC(sp) END; tk := tEq
    | "#": tk := tNe
    | "!": IF src[sp] = "=" THEN INC(sp); tk := tNe ELSE tk := tNot END
    | "<": IF src[sp] = ">" THEN INC(sp); tk := tNe
           ELSIF src[sp] = "=" THEN INC(sp); tk := tLe
           ELSE tk := tLt END
    | ">": IF src[sp] = "=" THEN INC(sp); tk := tGe ELSE tk := tGt END
    | "$": tk := tDollar
    | ";": tk := tSemi
    ELSE tk := tOther; tkStr[0] := c; tkStr[1] := 0X
    END
  END
END Next;

PROCEDURE SetSrc(s: ARRAY OF CHAR);
BEGIN
  Cpy(s, src); sp := 0; Next
END SetSrc;

PROCEDURE IsKw(kw: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN (tk = tIdent) & Kw(tkStr, kw)
END IsKw;

(* raw text from the current token to end of line *)
PROCEDURE RawRest(VAR s: ARRAY OF CHAR);
BEGIN
  Sub(src, tkStart, 255, s); Trim(s);
  sp := SLen(src); tk := tEOF
END RawRest;

(* raw word (file name, skeleton...) up to a blank or comma *)
PROCEDURE RawWord(VAR s: ARRAY OF CHAR);
VAR i, j: INTEGER;
BEGIN
  i := tkStart; j := 0;
  IF (src[i] = "'") OR (src[i] = '"') THEN
    Cpy(tkStr, s); Next; RETURN
  END;
  WHILE (src[i] # 0X) & (src[i] # " ") & (src[i] # ",") DO
    IF j < LEN(s) - 1 THEN s[j] := src[i]; INC(j) END; INC(i)
  END;
  s[j] := 0X;
  sp := i; Next
END RawWord;

PROCEDURE AtEnd(): BOOLEAN;
BEGIN RETURN tk = tEOF END AtEnd;

(* ====================================================================
   Memory variables
   ==================================================================== *)

(* * and ? wildcards, case-insensitive *)
PROCEDURE WildMatch(p, s: ARRAY OF CHAR; pi, si: INTEGER): BOOLEAN;
BEGIN
  LOOP
    IF p[pi] = 0X THEN RETURN s[si] = 0X END;
    IF p[pi] = "*" THEN
      WHILE p[pi] = "*" DO INC(pi) END;
      IF p[pi] = 0X THEN RETURN TRUE END;
      WHILE s[si] # 0X DO
        IF WildMatch(p, s, pi, si) THEN RETURN TRUE END;
        INC(si)
      END;
      RETURN FALSE
    END;
    IF s[si] = 0X THEN RETURN FALSE END;
    IF (p[pi] # "?") & (UpCh(p[pi]) # UpCh(s[si])) THEN RETURN FALSE END;
    INC(pi); INC(si)
  END
END WildMatch;

(* does a PRIVATE ALL at some level above `level` hide this name? *)
PROCEDURE PrivHidden(name: ARRAY OF CHAR; level: INTEGER): BOOLEAN;
VAR lv, m: INTEGER;
BEGIN
  FOR lv := level + 1 TO depth DO
    m := frames[lv - 1].privMode;
    IF (m = 1) OR ((m = 2) & WildMatch(frames[lv - 1].privSkel, name, 0, 0))
       OR ((m = 3) & ~WildMatch(frames[lv - 1].privSkel, name, 0, 0)) THEN RETURN TRUE END
  END;
  RETURN FALSE
END PrivHidden;

PROCEDURE FindVar(name: ARRAY OF CHAR): INTEGER;
VAR i: INTEGER; n: Name;
BEGIN
  Cpy(name, n); Upper(n);
  IF SLen(n) > 10 THEN n[10] := 0X END;
  FOR i := nVars - 1 TO 0 BY -1 DO
    IF Eq(vars[i].name, n) THEN
      IF (vars[i].level < depth) & PrivHidden(n, vars[i].level) THEN RETURN -1 END;
      RETURN i
    END
  END;
  RETURN -1
END FindVar;

PROCEDURE NewVar(name: ARRAY OF CHAR): INTEGER;
VAR n: Name;
BEGIN
  IF nVars >= MaxVars THEN Err("Out of memory variable slots."); RETURN -1 END;
  Cpy(name, n); Upper(n); IF SLen(n) > 10 THEN n[10] := 0X END;
  Cpy(n, vars[nVars].name);
  vars[nVars].level := depth;
  vars[nVars].public := FALSE;
  vars[nVars].v.t := TL; vars[nVars].v.b := FALSE;
  INC(nVars);
  RETURN nVars - 1
END NewVar;

PROCEDURE StoreVar(name: ARRAY OF CHAR; VAR v: Value);
VAR i: INTEGER;
BEGIN
  i := FindVar(name);
  IF i < 0 THEN i := NewVar(name) END;
  IF i >= 0 THEN
    vars[i].v := v;
    IF v.t = TN THEN
      IF vars[i].v.w < 10 THEN vars[i].v.w := 10 END
    END
  END
END StoreVar;

PROCEDURE ReleaseVar(i: INTEGER);
VAR j: INTEGER;
BEGIN
  FOR j := i TO nVars - 2 DO vars[j] := vars[j + 1] END;
  DEC(nVars)
END ReleaseVar;

(* ====================================================================
   Expression compiler
   ==================================================================== *)

CONST
  (* function ids *)
  fABS = 1; fASC = 2; fAT = 3; fBOF = 4; fCDOW = 5; fCHR = 6; fCMONTH = 7;
  fCOL = 8; fCTOD = 9; fDATE = 10; fDAY = 11; fDBF = 12; fDELETED = 13;
  fDISKSPACE = 14; fDOW = 15; fDTOC = 16; fEOF = 17; fERROR = 18; fEXP = 19;
  fFIELD = 20; fFILE = 21; fFKLABEL = 22; fFKMAX = 23; fFOUND = 24;
  fGETENV = 25; fIIF = 26; fINKEY = 27; fINT = 28; fISALPHA = 29;
  fISCOLOR = 30; fISLOWER = 31; fISUPPER = 32; fLEFT = 33; fLEN = 34;
  fLOG = 35; fLOWER = 36; fLTRIM = 37; fLUPDATE = 38; fMAX = 39;
  fMESSAGE = 40; fMIN = 41; fMOD = 42; fMONTH = 43; fNDX = 44; fOS = 45;
  fPCOL = 46; fPROW = 47; fREADKEY = 48; fRECCOUNT = 49; fRECNO = 50;
  fRECSIZE = 51; fREPLICATE = 52; fRIGHT = 53; fROUND = 54; fROW = 55;
  fRTRIM = 56; fSPACE = 57; fSQRT = 58; fSTR = 59; fSTUFF = 60;
  fSUBSTR = 61; fTIME = 62; fTRANSFORM = 63; fTRIM = 64; fTYPE = 65;
  fUPPER = 66; fVAL = 67; fVERSION = 68; fYEAR = 69; fSELECT = 70;
  NFuncs = 70;

VAR
  fnName: ARRAY NFuncs + 1 OF Name;
  fnMin, fnMax: ARRAY NFuncs + 1 OF INTEGER;

PROCEDURE DefFn(id: INTEGER; name: ARRAY OF CHAR; mn, mx: INTEGER);
BEGIN
  Cpy(name, fnName[id]); fnMin[id] := mn; fnMax[id] := mx
END DefFn;

PROCEDURE InitFuncs;
BEGIN
  DefFn(fABS, "ABS", 1, 1); DefFn(fASC, "ASC", 1, 1); DefFn(fAT, "AT", 2, 2);
  DefFn(fBOF, "BOF", 0, 0); DefFn(fCDOW, "CDOW", 1, 1); DefFn(fCHR, "CHR", 1, 1);
  DefFn(fCMONTH, "CMONTH", 1, 1); DefFn(fCOL, "COL", 0, 0); DefFn(fCTOD, "CTOD", 1, 1);
  DefFn(fDATE, "DATE", 0, 0); DefFn(fDAY, "DAY", 1, 1); DefFn(fDBF, "DBF", 0, 0);
  DefFn(fDELETED, "DELETED", 0, 0); DefFn(fDISKSPACE, "DISKSPACE", 0, 0);
  DefFn(fDOW, "DOW", 1, 1); DefFn(fDTOC, "DTOC", 1, 1); DefFn(fEOF, "EOF", 0, 0);
  DefFn(fERROR, "ERROR", 0, 0); DefFn(fEXP, "EXP", 1, 1); DefFn(fFIELD, "FIELD", 1, 1);
  DefFn(fFILE, "FILE", 1, 1); DefFn(fFKLABEL, "FKLABEL", 1, 1); DefFn(fFKMAX, "FKMAX", 0, 0);
  DefFn(fFOUND, "FOUND", 0, 0); DefFn(fGETENV, "GETENV", 1, 1); DefFn(fIIF, "IIF", 3, 3);
  DefFn(fINKEY, "INKEY", 0, 0); DefFn(fINT, "INT", 1, 1); DefFn(fISALPHA, "ISALPHA", 1, 1);
  DefFn(fISCOLOR, "ISCOLOR", 0, 0); DefFn(fISLOWER, "ISLOWER", 1, 1);
  DefFn(fISUPPER, "ISUPPER", 1, 1); DefFn(fLEFT, "LEFT", 2, 2); DefFn(fLEN, "LEN", 1, 1);
  DefFn(fLOG, "LOG", 1, 1); DefFn(fLOWER, "LOWER", 1, 1); DefFn(fLTRIM, "LTRIM", 1, 1);
  DefFn(fLUPDATE, "LUPDATE", 0, 0); DefFn(fMAX, "MAX", 2, 2); DefFn(fMESSAGE, "MESSAGE", 0, 0);
  DefFn(fMIN, "MIN", 2, 2); DefFn(fMOD, "MOD", 2, 2); DefFn(fMONTH, "MONTH", 1, 1);
  DefFn(fNDX, "NDX", 1, 1); DefFn(fOS, "OS", 0, 0); DefFn(fPCOL, "PCOL", 0, 0);
  DefFn(fPROW, "PROW", 0, 0); DefFn(fREADKEY, "READKEY", 0, 0);
  DefFn(fRECCOUNT, "RECCOUNT", 0, 0); DefFn(fRECNO, "RECNO", 0, 0);
  DefFn(fRECSIZE, "RECSIZE", 0, 0); DefFn(fREPLICATE, "REPLICATE", 2, 2);
  DefFn(fRIGHT, "RIGHT", 2, 2); DefFn(fROUND, "ROUND", 2, 2); DefFn(fROW, "ROW", 0, 0);
  DefFn(fRTRIM, "RTRIM", 1, 1); DefFn(fSPACE, "SPACE", 1, 1); DefFn(fSQRT, "SQRT", 1, 1);
  DefFn(fSTR, "STR", 1, 3); DefFn(fSTUFF, "STUFF", 4, 4); DefFn(fSUBSTR, "SUBSTR", 2, 3);
  DefFn(fTIME, "TIME", 0, 0); DefFn(fTRANSFORM, "TRANSFORM", 2, 2); DefFn(fTRIM, "TRIM", 1, 1);
  DefFn(fTYPE, "TYPE", 1, 1); DefFn(fUPPER, "UPPER", 1, 1); DefFn(fVAL, "VAL", 1, 1);
  DefFn(fVERSION, "VERSION", 0, 0); DefFn(fYEAR, "YEAR", 1, 1); DefFn(fSELECT, "SELECT", 0, 0)
END InitFuncs;

PROCEDURE FuncId(name: ARRAY OF CHAR): INTEGER;
VAR i: INTEGER;
BEGIN
  FOR i := 1 TO NFuncs DO IF EqI(name, fnName[i]) THEN RETURN i END END;
  FOR i := 1 TO NFuncs DO IF Kw(name, fnName[i]) THEN RETURN i END END;
  RETURN 0
END FuncId;

PROCEDURE NewNode(kind: INTEGER): Node;
VAR n: Node;
BEGIN
  NEW(n); n.kind := kind; n.op := 0; n.nargs := 0; n.area := -1; n.fld := -1;
  n.v.t := TU; n.name[0] := 0X;
  n.arg[0] := NIL; n.arg[1] := NIL; n.arg[2] := NIL; n.arg[3] := NIL;
  RETURN n
END NewNode;

PROCEDURE Bin(op: INTEGER; a, b: Node): Node;
VAR n: Node;
BEGIN
  n := NewNode(nBinary); n.op := op; n.arg[0] := a; n.arg[1] := b; n.nargs := 2;
  RETURN n
END Bin;

(* Precedence, lowest first:
     .OR.  <  .AND.  <  .NOT.  <  relational  <  + -  <  * / %  <  ** ^
     <  unary + -  <  primary
   Each level only calls the next tighter one; parentheses recurse to
   ParseOr from Primary. *)

PROCEDURE ParsePrimary(): Node;
VAR n, a: Node; name, fname: Str; id, ar, f: INTEGER;
BEGIN
  n := NIL;
  IF err THEN RETURN NIL END;
  CASE tk OF
    tNum:
      n := NewNode(nConst); SetNum(n.v, tkNum, 10, tkDec);
      IF SLen(tkStr) > 10 THEN n.v.w := SLen(tkStr) END;
      Next
  | tStr:
      n := NewNode(nConst); SetStr(n.v, tkStr); Next
  | tTrue:
      n := NewNode(nConst); SetBool(n.v, TRUE); Next
  | tFalse:
      n := NewNode(nConst); SetBool(n.v, FALSE); Next
  | tLP:
      Next; n := ParseOr();
      IF tk = tRP THEN Next ELSE Err("Unbalanced parenthesis.") END
  | tIdent:
      Cpy(tkStr, name); Next;
      IF tk = tLP THEN
        id := FuncId(name);
        IF id = 0 THEN Err("Unrecognized function name."); RETURN NIL END;
        n := NewNode(nFunc); n.op := id;
        Next;
        IF tk # tRP THEN
          LOOP
            a := ParseOr();
            IF err THEN RETURN NIL END;
            IF n.nargs < 4 THEN n.arg[n.nargs] := a; INC(n.nargs) END;
            IF tk = tComma THEN Next ELSE EXIT END
          END
        END;
        IF tk = tRP THEN Next ELSE Err("Unbalanced parenthesis."); RETURN NIL END;
        IF (n.nargs < fnMin[id]) OR (n.nargs > fnMax[id]) THEN
          Err("Wrong number of parameters."); RETURN NIL
        END
      ELSIF tk = tArrow THEN
        Next;
        IF tk # tIdent THEN Err("Syntax error."); RETURN NIL END;
        Cpy(tkStr, fname); Next;
        IF EqI(name, "M") THEN
          n := NewNode(nVar); Cpy(fname, n.name); Upper(n.name)
        ELSE
          ar := AliasArea(name);
          IF ar < 0 THEN Err("ALIAS not found."); RETURN NIL END;
          f := FieldIdx(ar, fname);
          IF f < 0 THEN Err("Variable not found."); RETURN NIL END;
          n := NewNode(nField); n.area := ar; n.fld := f
        END
      ELSE
        f := -1;
        IF areas[cur].used THEN f := FieldIdx(cur, name) END;
        IF f >= 0 THEN
          n := NewNode(nField); n.area := cur; n.fld := f
        ELSE
          n := NewNode(nVar); Cpy(name, n.name); Upper(n.name);
          IF SLen(n.name) > 10 THEN n.name[10] := 0X END
        END
      END
  | tEOF:
      Err("Missing expression.")
  ELSE
    Err("Syntax error.")
  END;
  RETURN n
END ParsePrimary;

PROCEDURE ParseUnary(): Node;
VAR n: Node;
BEGIN
  IF tk = tMinus THEN
    Next; n := NewNode(nUnary); n.op := tMinus; n.arg[0] := ParseUnary(); RETURN n
  ELSIF tk = tPlus THEN
    Next; RETURN ParseUnary()
  END;
  RETURN ParsePrimary()
END ParseUnary;

PROCEDURE ParsePow(): Node;
VAR a: Node;
BEGIN
  a := ParseUnary();
  IF (tk = tPow) & ~err THEN Next; a := Bin(tPow, a, ParsePow()) END;
  RETURN a
END ParsePow;

PROCEDURE ParseMul(): Node;
VAR a: Node; op: INTEGER;
BEGIN
  a := ParsePow();
  WHILE ((tk = tStar) OR (tk = tSlash) OR (tk = tPct)) & ~err DO
    op := tk; Next; a := Bin(op, a, ParsePow())
  END;
  RETURN a
END ParseMul;

PROCEDURE ParseAdd(): Node;
VAR a: Node; op: INTEGER;
BEGIN
  a := ParseMul();
  WHILE ((tk = tPlus) OR (tk = tMinus)) & ~err DO
    op := tk; Next; a := Bin(op, a, ParseMul())
  END;
  RETURN a
END ParseAdd;

PROCEDURE ParseRel(): Node;
VAR a: Node; op: INTEGER;
BEGIN
  a := ParseAdd();
  WHILE ((tk >= tEq) & (tk <= tDollar)) & ~err DO
    op := tk; Next; a := Bin(op, a, ParseAdd())
  END;
  RETURN a
END ParseRel;

PROCEDURE ParseNot(): Node;
VAR n: Node;
BEGIN
  IF tk = tNot THEN
    Next; n := NewNode(nUnary); n.op := tNot; n.arg[0] := ParseNot(); RETURN n
  END;
  RETURN ParseRel()
END ParseNot;

PROCEDURE ParseAnd(): Node;
VAR a: Node;
BEGIN
  a := ParseNot();
  WHILE (tk = tAnd) & ~err DO Next; a := Bin(tAnd, a, ParseNot()) END;
  RETURN a
END ParseAnd;

PROCEDURE ParseOr(): Node;
VAR a: Node;
BEGIN
  a := ParseAnd();
  WHILE (tk = tOr) & ~err DO Next; a := Bin(tOr, a, ParseAnd()) END;
  RETURN a
END ParseOr;

(* Compile an expression from the current lexer position *)
PROCEDURE Expr(): Node;
VAR n: Node;
BEGIN
  n := ParseOr();
  IF err THEN n := NIL END;
  RETURN n
END Expr;

(* Compile a whole string as one expression *)
PROCEDURE CompileStr(s: ARRAY OF CHAR): Node;
VAR l: LexState; n: Node;
BEGIN
  SaveLex(l);
  SetSrc(s);
  n := Expr();
  IF ~err & (tk # tEOF) THEN Err("Syntax error."); n := NIL END;
  RestoreLex(l);
  RETURN n
END CompileStr;

(* ====================================================================
   Evaluation
   ==================================================================== *)

PROCEDURE Mismatch;
BEGIN Err("Data type mismatch.") END Mismatch;

PROCEDURE MaxI(a, b: INTEGER): INTEGER;
BEGIN IF a > b THEN RETURN a ELSE RETURN b END END MaxI;

PROCEDURE MinI(a, b: INTEGER): INTEGER;
BEGIN IF a < b THEN RETURN a ELSE RETURN b END END MinI;

(* string comparison honouring SET EXACT; returns -1/0/1 *)
PROCEDURE StrCmp(VAR a, b: ARRAY OF CHAR): INTEGER;
VAR i, lb: INTEGER;
BEGIN
  IF setExact THEN
    RETURN Cmp(a, b)
  END;
  lb := SLen(b);
  IF lb = 0 THEN RETURN 0 END;
  i := 0;
  WHILE (i < lb) & (a[i] = b[i]) & (a[i] # 0X) DO INC(i) END;
  IF i = lb THEN RETURN 0
  ELSIF ORD(a[i]) < ORD(b[i]) THEN RETURN -1
  ELSE RETURN 1
  END
END StrCmp;

PROCEDURE NumCmp(a, b: REAL): INTEGER;
BEGIN
  IF ABS(a - b) < 1.0E-9 * (1.0 + ABS(a) + ABS(b)) THEN RETURN 0
  ELSIF a < b THEN RETURN -1
  ELSE RETURN 1
  END
END NumCmp;

PROCEDURE RelResult(op, c: INTEGER): BOOLEAN;
BEGIN
  CASE op OF
    tEq: RETURN c = 0
  | tNe: RETURN c # 0
  | tLt: RETURN c < 0
  | tGt: RETURN c > 0
  | tLe: RETURN c <= 0
  | tGe: RETURN c >= 0
  ELSE RETURN FALSE
  END
END RelResult;

PROCEDURE EvalBinary(n: Node; VAR v: Value);
VAR a, b: Value; c, i, la: INTEGER; t: Str;
BEGIN
  Eval(n.arg[0], a);
  IF err THEN RETURN END;
  IF (n.op = tAnd) OR (n.op = tOr) THEN
    IF a.t # TL THEN Mismatch; RETURN END;
    IF (n.op = tAnd) & ~a.b THEN SetBool(v, FALSE); RETURN END;
    IF (n.op = tOr) & a.b THEN SetBool(v, TRUE); RETURN END;
    Eval(n.arg[1], b);
    IF err THEN RETURN END;
    IF b.t # TL THEN Mismatch; RETURN END;
    SetBool(v, b.b); RETURN
  END;
  Eval(n.arg[1], b);
  IF err THEN RETURN END;
  CASE n.op OF
    tPlus:
      IF (a.t = TN) & (b.t = TN) THEN
        SetNum(v, a.n + b.n, MaxI(a.w, b.w), MaxI(a.dec, b.dec))
      ELSIF (a.t = TC) & (b.t = TC) THEN
        v := a; Append(b.s, v.s)
      ELSIF (a.t = TD) & (b.t = TN) THEN
        IF a.d = 0 THEN SetDate(v, 0) ELSE SetDate(v, a.d + FLOOR(b.n)) END
      ELSIF (a.t = TN) & (b.t = TD) THEN
        IF b.d = 0 THEN SetDate(v, 0) ELSE SetDate(v, b.d + FLOOR(a.n)) END
      ELSE Mismatch
      END
  | tMinus:
      IF (a.t = TN) & (b.t = TN) THEN
        SetNum(v, a.n - b.n, MaxI(a.w, b.w), MaxI(a.dec, b.dec))
      ELSIF (a.t = TC) & (b.t = TC) THEN
        (* trailing blanks of the left operand move to the end *)
        Cpy(a.s, t); la := SLen(t); RTrim(t);
        c := la - SLen(t);
        Append(b.s, t);
        FOR i := 1 TO c DO AppendCh(" ", t) END;
        SetStr(v, t)
      ELSIF (a.t = TD) & (b.t = TN) THEN
        IF a.d = 0 THEN SetDate(v, 0) ELSE SetDate(v, a.d - FLOOR(b.n)) END
      ELSIF (a.t = TD) & (b.t = TD) THEN
        SetNum(v, FLT(a.d - b.d), 10, 0)
      ELSE Mismatch
      END
  | tStar:
      IF (a.t = TN) & (b.t = TN) THEN
        SetNum(v, a.n * b.n, MaxI(10, MaxI(a.w, b.w)), MinI(a.dec + b.dec, 15))
      ELSE Mismatch
      END
  | tSlash:
      IF (a.t = TN) & (b.t = TN) THEN
        IF b.n = 0.0 THEN Err("Division by zero."); RETURN END;
        SetNum(v, a.n / b.n, MaxI(10, a.w), MaxI(setDecimals, a.dec))
      ELSE Mismatch
      END
  | tPct:
      IF (a.t = TN) & (b.t = TN) THEN
        IF b.n = 0.0 THEN Err("Division by zero."); RETURN END;
        SetNum(v, a.n - b.n * Math.floor(a.n / b.n), MaxI(a.w, b.w), MaxI(a.dec, b.dec))
      ELSE Mismatch
      END
  | tPow:
      IF (a.t = TN) & (b.t = TN) THEN
        SetNum(v, Math.power(a.n, b.n), 10, MaxI(setDecimals, a.dec))
      ELSE Mismatch
      END
  | tDollar:
      IF (a.t = TC) & (b.t = TC) THEN SetBool(v, PosI(a.s, b.s) >= 0)
      ELSE Mismatch
      END
  ELSE (* relational *)
    IF a.t # b.t THEN Mismatch; RETURN END;
    CASE a.t OF
      "C": c := StrCmp(a.s, b.s)
    | "N": c := NumCmp(a.n, b.n)
    | "D": IF a.d < b.d THEN c := -1 ELSIF a.d > b.d THEN c := 1 ELSE c := 0 END
    | "L":
        IF a.b = b.b THEN c := 0 ELSIF b.b THEN c := -1 ELSE c := 1 END;
        IF (n.op # tEq) & (n.op # tNe) THEN Mismatch; RETURN END
    ELSE Mismatch; RETURN
    END;
    SetBool(v, RelResult(n.op, c))
  END
END EvalBinary;

PROCEDURE Eval(n: Node; VAR v: Value);
VAR i: INTEGER;
BEGIN
  IF err THEN v.t := TU; RETURN END;
  IF n = NIL THEN Err("Missing expression."); v.t := TU; RETURN END;
  CASE n.kind OF
    nConst: v := n.v
  | nField: GetFieldVal(n.area, n.fld, v)
  | nVar:
      i := FindVar(n.name);
      IF i < 0 THEN
        (* a field opened after compilation? *)
        IF areas[cur].used & (FieldIdx(cur, n.name) >= 0) THEN
          GetFieldVal(cur, FieldIdx(cur, n.name), v)
        ELSE
          Err("Variable not found."); v.t := TU
        END
      ELSE v := vars[i].v
      END
  | nUnary:
      Eval(n.arg[0], v);
      IF err THEN RETURN END;
      IF n.op = tMinus THEN
        IF v.t = TN THEN v.n := -v.n ELSE Mismatch END
      ELSIF n.op = tNot THEN
        IF v.t = TL THEN v.b := ~v.b ELSE Mismatch END
      END
  | nBinary: EvalBinary(n, v)
  | nFunc: CallFunc(n, v)
  END
END Eval;

PROCEDURE EvalStr(n: Node; VAR s: ARRAY OF CHAR);
VAR v: Value;
BEGIN
  Eval(n, v);
  IF err THEN s[0] := 0X; RETURN END;
  IF v.t # TC THEN Err("Not a Character expression."); s[0] := 0X; RETURN END;
  Cpy(v.s, s)
END EvalStr;

PROCEDURE EvalNum(n: Node): REAL;
VAR v: Value;
BEGIN
  Eval(n, v);
  IF err THEN RETURN 0.0 END;
  IF v.t # TN THEN Err("Not a numeric expression."); RETURN 0.0 END;
  RETURN v.n
END EvalNum;

PROCEDURE EvalInt(n: Node): INTEGER;
VAR x: REAL;
BEGIN
  x := EvalNum(n);
  IF err THEN RETURN 0 END;
  IF ABS(x) > 2.0E9 THEN Err("Numeric overflow."); RETURN 0 END;
  IF x >= 0.0 THEN RETURN FLOOR(x) ELSE RETURN -FLOOR(-x) END
END EvalInt;

PROCEDURE EvalBool(n: Node): BOOLEAN;
VAR v: Value;
BEGIN
  Eval(n, v);
  IF err THEN RETURN FALSE END;
  IF v.t # TL THEN Err("Not a Logical expression."); RETURN FALSE END;
  RETURN v.b
END EvalBool;

(* Evaluate s as an expression; err is left set on failure *)
PROCEDURE EvalString(s: ARRAY OF CHAR; VAR v: Value);
VAR n: Node; savedErr: BOOLEAN; savedMsg: Str;
BEGIN
  (* Save and clear the error state so compilation of a sub-
     expression doesn't inherit a prior error, and restore it
     if we succeed (so callers can detect fresh errors). *)
  savedErr := err; Cpy(errMsg, savedMsg);
  err := FALSE; errMsg[0] := 0X;
  n := CompileStr(s);
  IF ~err THEN
    Eval(n, v);
    IF ~err THEN
      (* restore prior error state *)
      err := savedErr; Cpy(savedMsg, errMsg)
    END
  ELSE v.t := TU
  END
END EvalString;

(* ---- PICTURE / TRANSFORM ---- *)

PROCEDURE SplitPicture(pic: ARRAY OF CHAR; VAR fn, tmpl: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  fn[0] := 0X; Cpy(pic, tmpl);
  IF pic[0] = "@" THEN
    i := 1;
    WHILE (pic[i] # 0X) & (pic[i] # " ") DO AppendCh(UpCh(pic[i]), fn); INC(i) END;
    WHILE pic[i] = " " DO INC(i) END;
    Sub(pic, i, 255, tmpl)
  END
END SplitPicture;

PROCEDURE HasFn(fn: ARRAY OF CHAR; c: CHAR): BOOLEAN;
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE fn[i] # 0X DO IF fn[i] = c THEN RETURN TRUE END; INC(i) END;
  RETURN FALSE
END HasFn;

PROCEDURE IsTmplDigit(c: CHAR): BOOLEAN;
BEGIN RETURN (c = "9") OR (c = "#") OR (c = "*") OR (c = "$") END IsTmplDigit;

PROCEDURE FmtPicture(VAR v: Value; pic: ARRAY OF CHAR; VAR out: ARRAY OF CHAR);
VAR
  fn, tmpl, num: Str; i, j, k, dec, nd, ti: INTEGER; neg, dot: BOOLEAN;
  c: CHAR;
BEGIN
  SplitPicture(pic, fn, tmpl);
  CASE v.t OF
    "N":
      neg := v.n < 0.0;
      IF tmpl[0] # 0X THEN
        dec := 0; dot := FALSE; nd := 0;
        i := 0;
        WHILE tmpl[i] # 0X DO
          IF tmpl[i] = "." THEN dot := TRUE
          ELSIF IsTmplDigit(tmpl[i]) THEN IF dot THEN INC(dec) ELSE INC(nd) END
          END;
          INC(i)
        END;
        FmtFixed(ABS(v.n), dec, num);
        IF HasFn(fn, "Z") & (RoundTo(v.n, dec) = 0.0) THEN
          Spaces(SLen(tmpl), out); RETURN
        END;
        (* fill template right to left *)
        Cpy(tmpl, out);
        k := SLen(num) - 1;
        (* skip the fraction: align the decimal point *)
        ti := SLen(tmpl) - 1;
        WHILE ti >= 0 DO
          c := tmpl[ti];
          IF IsTmplDigit(c) THEN
            IF (k >= 0) & (num[k] = ".") THEN DEC(k) END;
            IF k >= 0 THEN out[ti] := num[k]; DEC(k)
            ELSIF neg & ~HasFn(fn, "(") THEN out[ti] := "-"; neg := FALSE
            ELSIF c = "*" THEN out[ti] := "*"
            ELSIF c = "$" THEN out[ti] := "$"
            ELSE out[ti] := " "
            END
          ELSIF c = "." THEN
            out[ti] := "."; IF (k >= 0) & (num[k] = ".") THEN DEC(k) END
          ELSIF c = "," THEN
            IF (k >= 0) & (num[k] # ".") THEN out[ti] := "," ELSE out[ti] := " " END
          END;
          DEC(ti)
        END;
        IF k >= 0 THEN  (* overflow *)
          FOR i := 0 TO SLen(out) - 1 DO IF out[i] # "." THEN out[i] := "*" END END
        END
      ELSE
        ValStr(v, out); neg := FALSE;
        IF v.n < 0.0 THEN neg := TRUE END;
        IF HasFn(fn, "Z") & (v.n = 0.0) THEN Spaces(SLen(out), out) END;
        IF HasFn(fn, "(") & neg THEN
          j := 0; WHILE out[j] = " " DO INC(j) END;
          IF out[j] = "-" THEN out[j] := "(" END;
          Append(")", out); neg := FALSE
        END;
        neg := FALSE
      END;
      IF HasFn(fn, "(") & (v.n < 0.0) & (tmpl[0] # 0X) THEN
        Strings.Insert("(", 0, out); Append(")", out)
      END;
      IF HasFn(fn, "C") & (v.n > 0.0) THEN Append(" CR", out) END;
      IF HasFn(fn, "X") & (v.n < 0.0) THEN Append(" DB", out) END;
      IF HasFn(fn, "B") THEN LTrim(out) END
  | "C":
      IF tmpl[0] = 0X THEN
        Cpy(v.s, out)
      ELSE
        out[0] := 0X; i := 0; j := 0;
        WHILE tmpl[i] # 0X DO
          c := tmpl[i];
          IF (c = "!") OR (c = "X") OR (c = "A") OR (c = "N") OR (c = "9")
             OR (c = "#") OR (c = "L") OR (c = "Y") THEN
            IF v.s[j] # 0X THEN
              IF c = "!" THEN AppendCh(UpCh(v.s[j]), out) ELSE AppendCh(v.s[j], out) END;
              INC(j)
            ELSE AppendCh(" ", out)
            END
          ELSE
            AppendCh(c, out);
            IF HasFn(fn, "R") THEN ELSIF v.s[j] = c THEN INC(j) END
          END;
          INC(i)
        END
      END;
      IF HasFn(fn, "!") THEN Upper(out) END
  | "L":
      IF (tmpl[0] = "Y") OR HasFn(fn, "Y") THEN
        IF v.b THEN Cpy("Y", out) ELSE Cpy("N", out) END
      ELSE ValStr(v, out)
      END
  ELSE ValStr(v, out)
  END
END FmtPicture;

(* dBASE INKEY() codes for our key values *)
PROCEDURE KeyCode(c: CHAR): INTEGER;
BEGIN
  CASE c OF
    TUI.KUp: RETURN 5 | TUI.KDown: RETURN 24 | TUI.KLeft: RETURN 19
  | TUI.KRight: RETURN 4 | TUI.KHome: RETURN 1 | TUI.KEnd: RETURN 6
  | TUI.KPgUp: RETURN 18 | TUI.KPgDn: RETURN 3 | TUI.KDel: RETURN 7
  | TUI.KF1: RETURN 28
  | TUI.KF2 .. TUI.KF10: RETURN -(ORD(c) - ORD(TUI.KF2) + 1)
  | TUI.KCtrlEnd: RETURN 23 | TUI.KCtrlHome: RETURN 29
  | TUI.KBackspace: RETURN 127
  ELSE RETURN ORD(c)
  END
END KeyCode;

PROCEDURE ArgOf(n: Node; i: INTEGER; VAR r: Value);
BEGIN Eval(n.arg[i], r) END ArgOf;

PROCEDURE CallFunc(n: Node; VAR v: Value);
VAR
  a, b, c: Value; s, t: Str; i, j, k, y, m, d: INTEGER; x: REAL;
  ev: TUI.Event; now: LONGINT; ch: CHAR;

  PROCEDURE NeedC(VAR r: Value): BOOLEAN;
  BEGIN
    IF err THEN RETURN FALSE END;
    IF r.t # TC THEN Err("Invalid function argument."); RETURN FALSE END;
    RETURN TRUE
  END NeedC;

  PROCEDURE NeedN(VAR r: Value): BOOLEAN;
  BEGIN
    IF err THEN RETURN FALSE END;
    IF r.t # TN THEN Err("Invalid function argument."); RETURN FALSE END;
    RETURN TRUE
  END NeedN;

  PROCEDURE NeedD(VAR r: Value): BOOLEAN;
  BEGIN
    IF err THEN RETURN FALSE END;
    IF r.t # TD THEN Err("Invalid function argument."); RETURN FALSE END;
    RETURN TRUE
  END NeedD;

  PROCEDURE IntOf(VAR r: Value): INTEGER;
  BEGIN
    IF r.n >= 0.0 THEN RETURN FLOOR(r.n + 1.0E-9) ELSE RETURN -FLOOR(-r.n + 1.0E-9) END
  END IntOf;

BEGIN
  v.t := TU;
  CASE n.op OF
    fABS: ArgOf(n, 0, a); IF NeedN(a) THEN v := a; v.n := ABS(a.n) END
  | fASC: ArgOf(n, 0, a); IF NeedC(a) THEN SetInt(v, ORD(a.s[0])) END
  | fAT:
      ArgOf(n, 0, a); ArgOf(n, 1, b);
      IF NeedC(a) & NeedC(b) THEN
        IF a.s[0] = 0X THEN SetInt(v, 0) ELSE SetInt(v, PosI(a.s, b.s) + 1) END
      END
  | fBOF: SetBool(v, areas[cur].used & areas[cur].bof)
  | fCDOW: ArgOf(n, 0, a); IF NeedD(a) THEN
        IF a.d = 0 THEN SetStr(v, "") ELSE DayName(DayOfWeek(a.d), s); SetStr(v, s) END END
  | fCHR: ArgOf(n, 0, a); IF NeedN(a) THEN s[0] := CHR(IntOf(a) MOD 256); s[1] := 0X; SetStr(v, s) END
  | fCMONTH: ArgOf(n, 0, a); IF NeedD(a) THEN
        IF a.d = 0 THEN SetStr(v, "") ELSE FromJulian(a.d, y, m, d); MonthName(m, s); SetStr(v, s) END END
  | fCOL: SetInt(v, ccol)
  | fCTOD: ArgOf(n, 0, a); IF NeedC(a) THEN SetDate(v, ParseDate(a.s)) END
  | fDATE: SetDate(v, Today())
  | fDAY: ArgOf(n, 0, a); IF NeedD(a) THEN
        IF a.d = 0 THEN SetInt(v, 0) ELSE FromJulian(a.d, y, m, d); SetNum(v, FLT(d), 3, 0) END END
  | fDBF:
      IF areas[cur].used THEN
        s[0] := defDrive; s[1] := ":"; s[2] := 0X; Cpy(areas[cur].fname, t);
        Append(t, s); SetStr(v, s)
      ELSE SetStr(v, "")
      END
  | fDELETED:
      IF areas[cur].used THEN EnsureRec(cur); SetBool(v, areas[cur].buf[0] = "*")
      ELSE SetBool(v, FALSE) END
  | fDISKSPACE: SetNum(v, 99999999.0, 10, 0)
  | fDOW: ArgOf(n, 0, a); IF NeedD(a) THEN
        IF a.d = 0 THEN SetInt(v, 0) ELSE SetNum(v, FLT(DayOfWeek(a.d)), 3, 0) END END
  | fDTOC: ArgOf(n, 0, a); IF NeedD(a) THEN DateStr(a.d, s); SetStr(v, s) END
  | fEOF: SetBool(v, ~areas[cur].used OR areas[cur].eof)
  | fERROR: SetInt(v, lastErrCode)
  | fEXP: ArgOf(n, 0, a); IF NeedN(a) THEN SetNum(v, Math.exp(a.n), 10, MaxI(setDecimals, a.dec)) END
  | fFIELD:
      ArgOf(n, 0, a);
      IF NeedN(a) THEN
        i := IntOf(a);
        IF areas[cur].used & (i >= 1) & (i <= areas[cur].db.numFields) THEN
          SetStr(v, areas[cur].db.fields[i - 1].name)
        ELSE SetStr(v, "")
        END
      END
  | fFILE: ArgOf(n, 0, a); IF NeedC(a) THEN SetBool(v, FileExists(a.s)) END
  | fFKLABEL: ArgOf(n, 0, a); IF NeedN(a) THEN Cpy("F", s); AppendInt(IntOf(a) + 1, s); SetStr(v, s) END
  | fFKMAX: SetInt(v, 9)
  | fFOUND: SetBool(v, areas[cur].used & areas[cur].found)
  | fGETENV: ArgOf(n, 0, a); IF NeedC(a) THEN Args.GetEnv(a.s, s); SetStr(v, s) END
  | fIIF:
      ArgOf(n, 0, a);
      IF ~err THEN
        IF a.t # TL THEN Err("Not a Logical expression.")
        ELSIF a.b THEN ArgOf(n, 1, v) ELSE ArgOf(n, 2, v)
        END
      END
  | fINKEY:
      i := 0;
      IF taN > 0 THEN ch := PopTypeahead(); i := KeyCode(ch); lastKey := ORD(ch)
      ELSIF ~batch & TUI.PollEvent(ev) & (ev.kind = TUI.EvKey) THEN i := KeyCode(ev.key); lastKey := ORD(ev.key)
      END;
      SetInt(v, i)
  | fINT: ArgOf(n, 0, a); IF NeedN(a) THEN
        IF a.n >= 0.0 THEN x := Math.floor(a.n) ELSE x := -Math.floor(-a.n) END;
        SetNum(v, x, a.w, 0) END
  | fISALPHA: ArgOf(n, 0, a); IF NeedC(a) THEN SetBool(v, IsAlpha(a.s[0])) END
  | fISCOLOR: SetBool(v, TRUE)
  | fISLOWER: ArgOf(n, 0, a); IF NeedC(a) THEN SetBool(v, (a.s[0] >= "a") & (a.s[0] <= "z")) END
  | fISUPPER: ArgOf(n, 0, a); IF NeedC(a) THEN SetBool(v, (a.s[0] >= "A") & (a.s[0] <= "Z")) END
  | fLEFT:
      ArgOf(n, 0, a); ArgOf(n, 1, b);
      IF NeedC(a) & NeedN(b) THEN i := IntOf(b); IF i < 0 THEN i := 0 END;
        Sub(a.s, 0, i, s); SetStr(v, s) END
  | fLEN: ArgOf(n, 0, a); IF NeedC(a) THEN SetNum(v, FLT(SLen(a.s)), 10, 0) END
  | fLOG: ArgOf(n, 0, a); IF NeedN(a) THEN
        IF a.n <= 0.0 THEN Err("Invalid function argument.") ELSE
        SetNum(v, Math.ln(a.n), 10, MaxI(setDecimals, a.dec)) END END
  | fLOWER: ArgOf(n, 0, a); IF NeedC(a) THEN v := a; Lower(v.s) END
  | fLTRIM: ArgOf(n, 0, a); IF NeedC(a) THEN v := a; LTrim(v.s) END
  | fLUPDATE:
      IF areas[cur].used THEN
        SetDate(v, Julian(areas[cur].db.year, areas[cur].db.month, areas[cur].db.day))
      ELSE SetDate(v, 0) END
  | fMAX, fMIN:
      ArgOf(n, 0, a); ArgOf(n, 1, b);
      IF ~err THEN
        IF (a.t = TN) & (b.t = TN) THEN
          IF ((n.op = fMAX) & (a.n >= b.n)) OR ((n.op = fMIN) & (a.n <= b.n)) THEN v := a ELSE v := b END;
          v.dec := MaxI(a.dec, b.dec)
        ELSIF (a.t = TD) & (b.t = TD) THEN
          IF ((n.op = fMAX) & (a.d >= b.d)) OR ((n.op = fMIN) & (a.d <= b.d)) THEN v := a ELSE v := b END
        ELSE Mismatch
        END
      END
  | fMESSAGE: SetStr(v, lastErrMsg)
  | fMOD:
      ArgOf(n, 0, a); ArgOf(n, 1, b);
      IF NeedN(a) & NeedN(b) THEN
        IF b.n = 0.0 THEN Err("Division by zero.")
        ELSE SetNum(v, a.n - b.n * Math.floor(a.n / b.n), MaxI(a.w, b.w), MaxI(a.dec, b.dec))
        END
      END
  | fMONTH: ArgOf(n, 0, a); IF NeedD(a) THEN
        IF a.d = 0 THEN SetInt(v, 0) ELSE FromJulian(a.d, y, m, d); SetNum(v, FLT(m), 3, 0) END END
  | fNDX:
      ArgOf(n, 0, a);
      IF NeedN(a) THEN
        i := IntOf(a);
        IF areas[cur].used & (i >= 1) & (i <= areas[cur].nIdx) THEN
          SetStr(v, areas[cur].idx[i - 1].fname); Upper(v.s)
        ELSE SetStr(v, "")
        END
      END
  | fOS: SetStr(v, "Unix")
  | fPCOL: SetInt(v, pcol)
  | fPROW: SetInt(v, prow)
  | fREADKEY: SetInt(v, readExit)
  | fRECCOUNT: IF areas[cur].used THEN SetInt(v, areas[cur].db.numRecs) ELSE SetInt(v, 0) END
  | fRECNO:
      IF areas[cur].used THEN SetInt(v, areas[cur].rec) ELSE SetInt(v, 0) END
  | fRECSIZE: IF areas[cur].used THEN SetInt(v, areas[cur].db.recordLen) ELSE SetInt(v, 0) END
  | fREPLICATE:
      ArgOf(n, 0, a); ArgOf(n, 1, b);
      IF NeedC(a) & NeedN(b) THEN
        s[0] := 0X; k := IntOf(b);
        FOR i := 1 TO k DO
          IF SLen(s) + SLen(a.s) <= 254 THEN Append(a.s, s) END
        END;
        SetStr(v, s)
      END
  | fRIGHT:
      ArgOf(n, 0, a); ArgOf(n, 1, b);
      IF NeedC(a) & NeedN(b) THEN
        i := IntOf(b); j := SLen(a.s); IF i > j THEN i := j END; IF i < 0 THEN i := 0 END;
        Sub(a.s, j - i, i, s); SetStr(v, s)
      END
  | fROUND:
      ArgOf(n, 0, a); ArgOf(n, 1, b);
      IF NeedN(a) & NeedN(b) THEN
        i := IntOf(b); SetNum(v, RoundTo(a.n, i), a.w, MaxI(i, 0))
      END
  | fROW: SetInt(v, crow)
  | fRTRIM, fTRIM: ArgOf(n, 0, a); IF NeedC(a) THEN v := a; RTrim(v.s) END
  | fSPACE: ArgOf(n, 0, a); IF NeedN(a) THEN Spaces(IntOf(a), s); SetStr(v, s) END
  | fSQRT: ArgOf(n, 0, a); IF NeedN(a) THEN
        IF a.n < 0.0 THEN Err("Invalid function argument.") ELSE
        SetNum(v, Math.sqrt(a.n), 10, MaxI(setDecimals, a.dec)) END END
  | fSTR:
      ArgOf(n, 0, a); i := 10; j := 0;
      IF NeedN(a) THEN
        IF n.nargs > 1 THEN ArgOf(n, 1, b); IF NeedN(b) THEN i := IntOf(b) END END;
        IF n.nargs > 2 THEN ArgOf(n, 2, c); IF NeedN(c) THEN j := IntOf(c) END END;
        IF i < 1 THEN i := 1 END; IF i > 255 THEN i := 255 END;
        IF j > i - 2 THEN j := MaxI(i - 2, 0) END;
        IF ~err THEN FmtNumW(RoundTo(a.n, j), i, j, s); SetStr(v, s) END
      END
  | fSTUFF:
      ArgOf(n, 0, a); ArgOf(n, 1, b); ArgOf(n, 2, c);
      IF NeedC(a) & NeedN(b) & NeedN(c) THEN
        i := IntOf(b) - 1; IF i < 0 THEN i := 0 END; j := IntOf(c);
        Sub(a.s, 0, i, s);
        Eval(n.arg[3], b);
        IF NeedC(b) THEN
          Append(b.s, s); Sub(a.s, i + j, 255, t); Append(t, s); SetStr(v, s)
        END
      END
  | fSUBSTR:
      ArgOf(n, 0, a); ArgOf(n, 1, b);
      IF NeedC(a) & NeedN(b) THEN
        i := IntOf(b) - 1; j := 255;
        IF n.nargs > 2 THEN ArgOf(n, 2, c); IF NeedN(c) THEN j := IntOf(c) END END;
        IF (i < 0) OR (j < 0) THEN SetStr(v, "") ELSE Sub(a.s, i, j, s); SetStr(v, s) END
      END
  | fTIME:
      now := Time.Now(); Time.Format(now, "%H:%M:%S", s); SetStr(v, s)
  | fTRANSFORM:
      ArgOf(n, 0, a); ArgOf(n, 1, b);
      IF ~err & NeedC(b) THEN FmtPicture(a, b.s, s); SetStr(v, s) END
  | fTYPE:
      ArgOf(n, 0, a);
      IF NeedC(a) THEN
        EvalString(a.s, b);
        IF err THEN err := FALSE; errMsg[0] := 0X; SetStr(v, "U")
        ELSE s[0] := b.t; s[1] := 0X; SetStr(v, s)
        END
      END
  | fUPPER: ArgOf(n, 0, a); IF NeedC(a) THEN v := a; Upper(v.s) END
  | fVAL:
      ArgOf(n, 0, a);
      IF NeedC(a) THEN ScanNum(a.s, x, i); SetNum(v, x, 10, MaxI(i, setDecimals)) END
  | fVERSION: SetStr(v, Version)
  | fYEAR: ArgOf(n, 0, a); IF NeedD(a) THEN
        IF a.d = 0 THEN SetInt(v, 0) ELSE FromJulian(a.d, y, m, d); SetNum(v, FLT(y), 5, 0) END END
  | fSELECT: SetInt(v, cur + 1)
  END
END CallFunc;

(* ====================================================================
   File names
   DOS-style names ("B:CUSTOMER") are accepted: any drive letter is
   dropped and files live in the SET DEFAULT directory (or the cwd).
   Lookups try the name as typed, then lower and upper case.
   ==================================================================== *)

PROCEDURE StripDrive(VAR s: ARRAY OF CHAR);
BEGIN
  IF IsAlpha(s[0]) & (s[1] = ":") THEN Strings.Delete(s, 0, 2) END
END StripDrive;

PROCEDURE HasExt(s: ARRAY OF CHAR): BOOLEAN;
VAR i: INTEGER; dot: BOOLEAN;
BEGIN
  dot := FALSE; i := 0;
  WHILE s[i] # 0X DO
    IF s[i] = "." THEN dot := TRUE ELSIF s[i] = "/" THEN dot := FALSE END;
    INC(i)
  END;
  RETURN dot
END HasExt;

(* basename without directory or extension, upper case *)
PROCEDURE BaseName(path: ARRAY OF CHAR; VAR s: ARRAY OF CHAR);
VAR i, start, dot: INTEGER;
BEGIN
  start := 0; dot := -1; i := 0;
  WHILE path[i] # 0X DO
    IF path[i] = "/" THEN start := i + 1; dot := -1
    ELSIF path[i] = "." THEN dot := i
    END;
    INC(i)
  END;
  IF dot < 0 THEN dot := i END;
  Sub(path, start, dot - start, s); Upper(s)
END BaseName;

(* file name part with extension, as DOS would show it *)
PROCEDURE ShortName(path: ARRAY OF CHAR; VAR s: ARRAY OF CHAR);
VAR i, start: INTEGER;
BEGIN
  start := 0; i := 0;
  WHILE path[i] # 0X DO IF path[i] = "/" THEN start := i + 1 END; INC(i) END;
  Sub(path, start, 255, s); Upper(s)
END ShortName;

PROCEDURE WithDir(name: ARRAY OF CHAR; VAR path: ARRAY OF CHAR);
BEGIN
  IF (defDir[0] # 0X) & (name[0] # "/") THEN
    Cpy(defDir, path);
    IF path[SLen(path) - 1] # "/" THEN AppendCh("/", path) END;
    Append(name, path)
  ELSE Cpy(name, path)
  END
END WithDir;

(* Find an existing file; ext (".dbf") is added when name has none *)
PROCEDURE FindFile(name, ext: ARRAY OF CHAR; VAR path: ARRAY OF CHAR): BOOLEAN;
VAR n, t, p: Str; i, k: INTEGER;
BEGIN
  Cpy(name, n); Trim(n); StripDrive(n);
  IF n[0] = 0X THEN RETURN FALSE END;
  IF ~HasExt(n) THEN Append(ext, n) END;
  FOR k := 0 TO 2 DO
    Cpy(n, t);
    IF k = 1 THEN Lower(t) ELSIF k = 2 THEN Upper(t) END;
    WithDir(t, path);
    IF Files.Exists(path) THEN RETURN TRUE END
  END;
  (* SET PATH directories *)
  IF pathDirs[0] # 0X THEN
    i := 0;
    WHILE Strings.Split(pathDirs, ";", i, p) DO
      Trim(p); StripDrive(p);
      IF p[0] # 0X THEN
        FOR k := 0 TO 1 DO
          Cpy(p, path); IF path[SLen(path) - 1] # "/" THEN AppendCh("/", path) END;
          Cpy(n, t); IF k = 1 THEN Lower(t) END;
          Append(t, path);
          IF Files.Exists(path) THEN RETURN TRUE END
        END
      END;
      INC(i)
    END
  END;
  WithDir(n, path);
  RETURN FALSE
END FindFile;

(* Path for a file about to be created: as typed, lower case if no case given *)
PROCEDURE NewPath(name, ext: ARRAY OF CHAR; VAR path: ARRAY OF CHAR);
VAR n: Str;
BEGIN
  IF FindFile(name, ext, path) THEN RETURN END;
  Cpy(name, n); Trim(n); StripDrive(n);
  IF ~HasExt(n) THEN Append(ext, n) END;
  Lower(n);
  WithDir(n, path)
END NewPath;

PROCEDURE FileExists(name: ARRAY OF CHAR): BOOLEAN;
VAR p: Str;
BEGIN
  RETURN FindFile(name, "", p)
END FileExists;

(* SET SAFETY confirmation before overwriting *)
PROCEDURE OkToOverwrite(path: ARRAY OF CHAR): BOOLEAN;
VAR q, s: Str;
BEGIN
  IF ~setSafety OR ~Files.Exists(path) OR batch OR (depth > 0) & ~setTalk THEN RETURN TRUE END;
  ShortName(path, s);
  Cpy(s, q); Append(" already exists, overwrite it? (Y/N)", q);
  RETURN AskYN(q)
END OkToOverwrite;

(* ====================================================================
   Work areas, records and fields
   ==================================================================== *)

PROCEDURE FieldIdx(a: INTEGER; name: ARRAY OF CHAR): INTEGER;
VAR i: INTEGER;
BEGIN
  IF ~areas[a].used THEN RETURN -1 END;
  FOR i := 0 TO areas[a].db.numFields - 1 DO
    IF EqI(areas[a].db.fields[i].name, name) THEN RETURN i END
  END;
  RETURN -1
END FieldIdx;

PROCEDURE AliasArea(name: ARRAY OF CHAR): INTEGER;
VAR i, n: INTEGER;
BEGIN
  IF (SLen(name) = 1) & (UpCh(name[0]) >= "A") & (UpCh(name[0]) <= "J") THEN
    RETURN ORD(UpCh(name[0])) - ORD("A")
  END;
  IF StrInt(name, n) & (n >= 1) & (n <= MaxAreas) THEN RETURN n - 1 END;
  FOR i := 0 TO MaxAreas - 1 DO
    IF areas[i].used & EqI(areas[i].alias, name) THEN RETURN i END
  END;
  RETURN -1
END AliasArea;

PROCEDURE NeedDb(): BOOLEAN;
BEGIN
  IF ~areas[cur].used THEN Err("No database is in USE."); RETURN FALSE END;
  RETURN TRUE
END NeedDb;

PROCEDURE ComputeOffs(a: INTEGER);
VAR i, off: INTEGER;
BEGIN
  off := 1;
  FOR i := 0 TO areas[a].db.numFields - 1 DO
    areas[a].offs[i] := off; INC(off, areas[a].db.fields[i].len)
  END
END ComputeOffs;

PROCEDURE BlankBuf(a: INTEGER);
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO areas[a].db.recordLen - 1 DO areas[a].buf[i] := " " END;
  areas[a].buf[areas[a].db.recordLen] := 0X
END BlankBuf;

PROCEDURE EnsureRec(a: INTEGER);
BEGIN
  IF ~areas[a].used THEN RETURN END;
  IF areas[a].bufRec # areas[a].rec THEN
    IF (areas[a].rec >= 1) & (areas[a].rec <= areas[a].db.numRecs) THEN
      DBF.ReadRec(areas[a].db, areas[a].rec - 1, areas[a].buf)
    ELSE
      BlankBuf(a)
    END;
    areas[a].bufRec := areas[a].rec
  END
END EnsureRec;

PROCEDURE GetRaw(a, f: INTEGER; VAR s: ARRAY OF CHAR);
VAR i, off, n: INTEGER;
BEGIN
  EnsureRec(a);
  off := areas[a].offs[f]; n := areas[a].db.fields[f].len;
  IF n > LEN(s) - 1 THEN n := LEN(s) - 1 END;
  FOR i := 0 TO n - 1 DO s[i] := areas[a].buf[off + i] END;
  s[n] := 0X
END GetRaw;

PROCEDURE PutRaw(a, f: INTEGER; s: ARRAY OF CHAR);
VAR i, off, n: INTEGER; done: BOOLEAN;
BEGIN
  off := areas[a].offs[f]; n := areas[a].db.fields[f].len;
  done := FALSE;
  FOR i := 0 TO n - 1 DO
    IF ~done & ((i >= LEN(s)) OR (s[i] = 0X)) THEN done := TRUE END;
    IF done THEN areas[a].buf[off + i] := " " ELSE areas[a].buf[off + i] := s[i] END
  END
END PutRaw;

PROCEDURE MemoBlock(a, f: INTEGER): INTEGER;
VAR s: Str; n: INTEGER;
BEGIN
  GetRaw(a, f, s);
  IF StrInt(s, n) THEN RETURN n ELSE RETURN 0 END
END MemoBlock;

PROCEDURE ReadMemo(a, f: INTEGER; VAR text: ARRAY OF CHAR);
BEGIN
  text[0] := 0X;
  IF areas[a].memo[0] # 0X THEN DBF.MemoRead(areas[a].memo, MemoBlock(a, f), text) END
END ReadMemo;

PROCEDURE WriteMemo(a, f: INTEGER; text: ARRAY OF CHAR);
VAR blk: INTEGER; s: Str;
BEGIN
  IF areas[a].memo[0] = 0X THEN RETURN END;
  blk := MemoBlock(a, f);
  DBF.MemoWrite(areas[a].memo, blk, text);
  IF blk = 0 THEN s[0] := 0X ELSE IntStrW(blk, 10, s) END;
  PutRaw(a, f, s)
END WriteMemo;

PROCEDURE GetFieldVal(a, f: INTEGER; VAR v: Value);
VAR s: Str; c: CHAR; x: REAL; d: INTEGER; memo: ARRAY MaxMemo OF CHAR;
BEGIN
  IF ~areas[a].used OR (f < 0) THEN Err("Variable not found."); v.t := TU; RETURN END;
  c := areas[a].db.fields[f].type;
  IF c = DBF.TypeMemo THEN
    ReadMemo(a, f, memo); memo[255] := 0X; SetStr(v, memo); RETURN
  END;
  GetRaw(a, f, s);
  CASE c OF
    "N", "F":
      ScanNum(s, x, d);
      SetNum(v, x, areas[a].db.fields[f].len, areas[a].db.fields[f].dec)
  | "L": SetBool(v, (s[0] = "T") OR (s[0] = "t") OR (s[0] = "Y") OR (s[0] = "y"))
  | "D": SetDate(v, DateFromDbf(s))
  ELSE SetStr(v, s)
  END
END GetFieldVal;

(* Store v into field f of a's record buffer (not yet written) *)
PROCEDURE PutFieldVal(a, f: INTEGER; VAR v: Value);
VAR s: Str; c: CHAR; len, dec: INTEGER;
BEGIN
  c := areas[a].db.fields[f].type;
  len := areas[a].db.fields[f].len; dec := areas[a].db.fields[f].dec;
  EnsureRec(a);
  CASE c OF
    "C":
      IF v.t # TC THEN Mismatch; RETURN END;
      PutRaw(a, f, v.s)
  | "N", "F":
      IF v.t # TN THEN Mismatch; RETURN END;
      FmtNumW(RoundTo(v.n, dec), len, dec, s); PutRaw(a, f, s)
  | "D":
      IF v.t # TD THEN Mismatch; RETURN END;
      DateToDbf(v.d, s); PutRaw(a, f, s)
  | "L":
      IF v.t # TL THEN Mismatch; RETURN END;
      IF v.b THEN PutRaw(a, f, "T") ELSE PutRaw(a, f, "F") END
  | "M":
      IF v.t # TC THEN Mismatch; RETURN END;
      WriteMemo(a, f, v.s)
  ELSE
    IF v.t = TC THEN PutRaw(a, f, v.s) ELSE Mismatch END
  END
END PutFieldVal;

(* ---- index keys ---- *)

PROCEDURE IdxKey(a, k: INTEGER; VAR key: ARRAY OF CHAR; VAR num: REAL);
VAR v: Value; save: INTEGER; ix: DBF.NdxIndex;
BEGIN
  ix := areas[a].idx[k].ix;
  save := cur; cur := a;
  Eval(areas[a].idx[k].key, v);
  cur := save;
  key[0] := 0X; num := 0.0;
  IF err THEN RETURN END;
  CASE v.t OF
    "C": Cpy(v.s, key); PadR(key, ix.keyLen)
  | "N": num := v.n
  | "D": num := FLT(v.d)
  ELSE Err("Invalid index expression.")
  END
END IdxKey;

(* compare entry e with (key, num); char keys compare over n bytes *)
PROCEDURE KeyCmp(ix: DBF.NdxIndex; e: DBF.NdxEntry; VAR key: ARRAY OF CHAR;
                 num: REAL; n: INTEGER): INTEGER;
VAR i: INTEGER;
BEGIN
  IF ix.numeric THEN
    IF e.num < num THEN RETURN -1 ELSIF e.num > num THEN RETURN 1 ELSE RETURN 0 END
  END;
  i := 0;
  WHILE (i < n) & (e.key[i] = key[i]) & (key[i] # 0X) DO INC(i) END;
  IF (i >= n) OR ((key[i] = 0X) & (e.key[i] = 0X)) THEN RETURN 0
  ELSIF key[i] = 0X THEN RETURN 1
  ELSIF ORD(e.key[i]) < ORD(key[i]) THEN RETURN -1
  ELSE RETURN 1
  END
END KeyCmp;

(* first position whose key >= (key,num) over n bytes *)
PROCEDURE LowerBound(ix: DBF.NdxIndex; VAR key: ARRAY OF CHAR; num: REAL; n: INTEGER): INTEGER;
VAR lo, hi, mid: INTEGER;
BEGIN
  lo := 0; hi := ix.n;
  WHILE lo < hi DO
    mid := (lo + hi) DIV 2;
    IF KeyCmp(ix, ix.e[mid], key, num, n) < 0 THEN lo := mid + 1 ELSE hi := mid END
  END;
  RETURN lo
END LowerBound;

PROCEDURE FindEntry(ix: DBF.NdxIndex; VAR key: ARRAY OF CHAR; num: REAL; rec: INTEGER): INTEGER;
VAR p, i: INTEGER;
BEGIN
  p := LowerBound(ix, key, num, ix.keyLen);
  WHILE (p < ix.n) & (KeyCmp(ix, ix.e[p], key, num, ix.keyLen) = 0) DO
    IF ix.e[p].rec = rec THEN RETURN p END;
    INC(p)
  END;
  FOR i := 0 TO ix.n - 1 DO IF ix.e[i].rec = rec THEN RETURN i END END;
  RETURN -1
END FindEntry;

PROCEDURE RemoveAt(ix: DBF.NdxIndex; p: INTEGER);
VAR i: INTEGER;
BEGIN
  FOR i := p TO ix.n - 2 DO ix.e[i] := ix.e[i + 1] END;
  DEC(ix.n)
END RemoveAt;

PROCEDURE InsertKey(ix: DBF.NdxIndex; VAR key: ARRAY OF CHAR; num: REAL; rec: INTEGER);
VAR p, i: INTEGER; e: DBF.NdxEntry;
BEGIN
  IF ix.n >= DBF.MaxNdx THEN Err("Index file is full."); RETURN END;
  p := LowerBound(ix, key, num, ix.keyLen);
  IF ix.unique & (p < ix.n) & (KeyCmp(ix, ix.e[p], key, num, ix.keyLen) = 0) THEN RETURN END;
  WHILE (p < ix.n) & (KeyCmp(ix, ix.e[p], key, num, ix.keyLen) = 0) & (ix.e[p].rec < rec) DO INC(p) END;
  NEW(e); Cpy(key, e.key); e.num := num; e.rec := rec;
  FOR i := ix.n TO p + 1 BY -1 DO ix.e[i] := ix.e[i - 1] END;
  ix.e[p] := e; INC(ix.n)
END InsertKey;

(* Remember the current record's keys before it is changed *)
PROCEDURE BeginChange(a: INTEGER);
VAR k: INTEGER;
BEGIN
  EnsureRec(a);
  FOR k := 0 TO areas[a].nIdx - 1 DO
    IdxKey(a, k, areas[a].oldKey[k], areas[a].oldNum[k])
  END
END BeginChange;

(* Write the buffer back and repair every open index *)
PROCEDURE EndChange(a: INTEGER);
VAR k, p: INTEGER; key: ARRAY DBF.MaxNdxKey + 1 OF CHAR; num: REAL; ix: DBF.NdxIndex;
BEGIN
  IF (areas[a].rec < 1) OR (areas[a].rec > areas[a].db.numRecs) THEN RETURN END;
  DBF.WriteRec(areas[a].db, areas[a].rec - 1, areas[a].buf);
  FOR k := 0 TO areas[a].nIdx - 1 DO
    ix := areas[a].idx[k].ix;
    IdxKey(a, k, key, num);
    IF ix.numeric & (num # areas[a].oldNum[k]) OR ~ix.numeric & ~Eq(key, areas[a].oldKey[k]) THEN
      p := FindEntry(ix, areas[a].oldKey[k], areas[a].oldNum[k], areas[a].rec);
      IF p >= 0 THEN RemoveAt(ix, p) END;
      InsertKey(ix, key, num, areas[a].rec);
      areas[a].idx[k].dirty := TRUE
    END
  END
END EndChange;

(* Append the buffer as a new record (buffer already filled) *)
PROCEDURE AppendBuf(a: INTEGER);
VAR k: INTEGER; key: ARRAY DBF.MaxNdxKey + 1 OF CHAR; num: REAL;
BEGIN
  areas[a].buf[0] := " ";
  DBF.WriteRec(areas[a].db, areas[a].db.numRecs, areas[a].buf);
  areas[a].rec := areas[a].db.numRecs; areas[a].bufRec := areas[a].rec;
  areas[a].eof := FALSE; areas[a].bof := FALSE;
  FOR k := 0 TO areas[a].nIdx - 1 DO
    IdxKey(a, k, key, num);
    InsertKey(areas[a].idx[k].ix, key, num, areas[a].rec);
    areas[a].idx[k].dirty := TRUE
  END
END AppendBuf;

PROCEDURE AppendBlank(a: INTEGER);
BEGIN
  BlankBuf(a);
  AppendBuf(a)
END AppendBlank;

PROCEDURE FlushIndexes(a: INTEGER);
VAR k: INTEGER;
BEGIN
  FOR k := 0 TO areas[a].nIdx - 1 DO
    IF areas[a].idx[k].dirty THEN
      IF DBF.NdxWrite(areas[a].idx[k].ix, areas[a].idx[k].fname) THEN END;
      areas[a].idx[k].dirty := FALSE
    END
  END
END FlushIndexes;

PROCEDURE FlushAll;
VAR a: INTEGER;
BEGIN
  FOR a := 0 TO MaxAreas - 1 DO IF areas[a].used THEN FlushIndexes(a) END END
END FlushAll;

(* ---- navigation ---- *)

PROCEDURE Visible(a: INTEGER): BOOLEAN;
VAR save: INTEGER; ok: BOOLEAN;
BEGIN
  EnsureRec(a);
  IF setDeleted & (areas[a].buf[0] = "*") THEN RETURN FALSE END;
  IF areas[a].filter # NIL THEN
    save := cur; cur := a;
    ok := EvalBool(areas[a].filter);
    cur := save;
    IF err THEN RETURN FALSE END;
    IF ~ok THEN RETURN FALSE END
  END;
  IF (a = editArea) & (editFor # NIL) THEN
    save := cur; cur := a;
    ok := EvalBool(editFor);
    cur := save;
    IF err THEN RETURN FALSE END;
    RETURN ok
  END;
  RETURN TRUE
END Visible;

PROCEDURE SyncRel(a: INTEGER);
VAR c, save, p: INTEGER; v: Value; ix: DBF.NdxIndex; key: Str;
BEGIN
  c := areas[a].relArea;
  IF (c < 0) OR ~areas[c].used OR (areas[a].relExpr = NIL) THEN RETURN END;
  save := cur; cur := a;
  Eval(areas[a].relExpr, v);
  cur := save;
  IF err THEN RETURN END;
  areas[c].found := FALSE;
  IF areas[c].order > 0 THEN
    ix := areas[c].idx[areas[c].order - 1].ix;
    IF v.t = TC THEN Cpy(v.s, key); RTrim(key) ELSE key[0] := 0X END;
    IF v.t = TD THEN v.n := FLT(v.d) END;
    p := LowerBound(ix, key, v.n, MinI(SLen(key), ix.keyLen));
    IF (p < ix.n) & (KeyCmp(ix, ix.e[p], key, v.n, MinI(SLen(key), ix.keyLen)) = 0) THEN
      areas[c].rec := ix.e[p].rec; areas[c].found := TRUE
    ELSE areas[c].rec := areas[c].db.numRecs + 1
    END
  ELSIF v.t = TN THEN
    p := FLOOR(v.n);
    IF (p >= 1) & (p <= areas[c].db.numRecs) THEN areas[c].rec := p; areas[c].found := TRUE
    ELSE areas[c].rec := areas[c].db.numRecs + 1
    END
  END;
  areas[c].eof := areas[c].rec > areas[c].db.numRecs;
  areas[c].bof := FALSE;
  EnsureRec(c);
  SyncRel(c)
END SyncRel;

PROCEDURE SetRec(a, r: INTEGER);
BEGIN
  areas[a].rec := r;
  areas[a].eof := r > areas[a].db.numRecs;
  areas[a].bof := FALSE;
  EnsureRec(a);
  SyncRel(a)
END SetRec;

PROCEDURE SetEof(a: INTEGER);
BEGIN
  SetRec(a, areas[a].db.numRecs + 1);
  areas[a].eof := TRUE
END SetEof;

(* position of the current record in the master index *)
PROCEDURE IdxPos(a: INTEGER): INTEGER;
VAR ix: DBF.NdxIndex; k: INTEGER; key: ARRAY DBF.MaxNdxKey + 1 OF CHAR; num: REAL;
BEGIN
  k := areas[a].order - 1;
  ix := areas[a].idx[k].ix;
  IF areas[a].rec > areas[a].db.numRecs THEN RETURN ix.n END;
  EnsureRec(a);
  IdxKey(a, k, key, num);
  RETURN FindEntry(ix, key, num, areas[a].rec)
END IdxPos;

PROCEDURE GoTop(a: INTEGER);
VAR r, p: INTEGER; ix: DBF.NdxIndex;
BEGIN
  IF areas[a].order > 0 THEN
    ix := areas[a].idx[areas[a].order - 1].ix;
    p := 0;
    WHILE p < ix.n DO
      areas[a].rec := ix.e[p].rec;
      IF Visible(a) THEN SetRec(a, areas[a].rec); RETURN END;
      INC(p)
    END
  ELSE
    r := 1;
    WHILE r <= areas[a].db.numRecs DO
      areas[a].rec := r;
      IF Visible(a) THEN SetRec(a, r); RETURN END;
      INC(r)
    END
  END;
  SetEof(a); areas[a].bof := TRUE
END GoTop;

PROCEDURE GoBottom(a: INTEGER);
VAR r, p: INTEGER; ix: DBF.NdxIndex;
BEGIN
  IF areas[a].order > 0 THEN
    ix := areas[a].idx[areas[a].order - 1].ix;
    p := ix.n - 1;
    WHILE p >= 0 DO
      areas[a].rec := ix.e[p].rec;
      IF Visible(a) THEN SetRec(a, areas[a].rec); RETURN END;
      DEC(p)
    END
  ELSE
    r := areas[a].db.numRecs;
    WHILE r >= 1 DO
      areas[a].rec := r;
      IF Visible(a) THEN SetRec(a, r); RETURN END;
      DEC(r)
    END
  END;
  SetEof(a); areas[a].bof := TRUE
END GoBottom;

(* move one visible record forward (dir=1) or back (dir=-1);
   returns FALSE when it falls off an end *)
PROCEDURE Step(a, dir: INTEGER): BOOLEAN;
VAR r, p, start: INTEGER; ix: DBF.NdxIndex;
BEGIN
  start := areas[a].rec;
  IF areas[a].order > 0 THEN
    ix := areas[a].idx[areas[a].order - 1].ix;
    p := IdxPos(a);
    IF p < 0 THEN p := 0 END;
    LOOP
      INC(p, dir);
      IF (p < 0) OR (p >= ix.n) THEN EXIT END;
      areas[a].rec := ix.e[p].rec;
      IF Visible(a) THEN SetRec(a, areas[a].rec); RETURN TRUE END
    END
  ELSE
    r := start;
    IF r > areas[a].db.numRecs THEN r := areas[a].db.numRecs + 1 END;
    LOOP
      INC(r, dir);
      IF (r < 1) OR (r > areas[a].db.numRecs) THEN EXIT END;
      areas[a].rec := r;
      IF Visible(a) THEN SetRec(a, r); RETURN TRUE END
    END
  END;
  IF dir > 0 THEN SetEof(a)
  ELSE
    areas[a].rec := start; GoTop(a); areas[a].bof := TRUE
  END;
  RETURN FALSE
END Step;

PROCEDURE Skip(a, n: INTEGER);
VAR i: INTEGER;
BEGIN
  IF n > 0 THEN
    IF areas[a].eof THEN Err("End of file encountered."); RETURN END;
    FOR i := 1 TO n DO IF ~areas[a].eof THEN IF Step(a, 1) THEN END END END
  ELSIF n < 0 THEN
    IF areas[a].bof THEN Err("Beginning of file encountered."); RETURN END;
    IF areas[a].eof THEN
      GoBottom(a); INC(n)
    END;
    i := 0;
    WHILE (i > n) & ~areas[a].bof DO IF Step(a, -1) THEN END; DEC(i) END
  END
END Skip;

(* ---- opening and closing ---- *)
PROCEDURE OpenIndex(a: INTEGER; name: ARRAY OF CHAR): BOOLEAN;
VAR path: Str; ix: DBF.NdxIndex; save, k: INTEGER; priorErr: BOOLEAN;
BEGIN
  IF areas[a].nIdx >= MaxIdx THEN
    Err("Too many indexes."); RETURN FALSE
  END;
  IF ~FindFile(name, ".ndx", path) THEN
    Err("File does not exist."); RETURN FALSE
  END;
  IF ~DBF.NdxRead(path, ix) THEN
    Err("Not a dBASE index file."); RETURN FALSE
  END;
  k := areas[a].nIdx;
  Cpy(path, areas[a].idx[k].fname);
  areas[a].idx[k].ix := ix;
  areas[a].idx[k].dirty := FALSE;
  (* clear err around CompileStr so we only see fresh errors *)
  priorErr := err; err := FALSE;
  save := cur; cur := a;
  areas[a].idx[k].key := CompileStr(ix.expr);
  cur := save;
  IF err THEN
    Err("Index file does not match database.");
    RETURN FALSE
  END;
  err := priorErr;  (* restore caller's error state if we succeeded *)
  INC(areas[a].nIdx);
  IF areas[a].order = 0 THEN areas[a].order := 1 END;
  RETURN TRUE
END OpenIndex;
PROCEDURE CloseIndexes(a: INTEGER);
BEGIN
  FlushIndexes(a);
  areas[a].nIdx := 0; areas[a].order := 0
END CloseIndexes;

PROCEDURE CloseArea(a: INTEGER);
VAR i: INTEGER;
BEGIN
  IF ~areas[a].used THEN RETURN END;
  CloseIndexes(a);
  DBF.Close(areas[a].db);
  areas[a].used := FALSE;
  areas[a].filter := NIL; areas[a].filterTxt[0] := 0X;
  areas[a].relArea := -1; areas[a].relExpr := NIL; areas[a].relTxt[0] := 0X;
  areas[a].locOn := FALSE;
  (* relations into this area die with it *)
  FOR i := 0 TO MaxAreas - 1 DO
    IF areas[i].relArea = a THEN areas[i].relArea := -1; areas[i].relExpr := NIL; areas[i].relTxt[0] := 0X END
  END;
  IF a = cur THEN nFieldList := 0 END
END CloseArea;

PROCEDURE OpenArea(a: INTEGER; path, alias: ARRAY OF CHAR): BOOLEAN;
VAR i: INTEGER; hasMemo: BOOLEAN;
BEGIN
  CloseArea(a);
  DBF.Open(areas[a].db, path);
  IF areas[a].db.f = NIL THEN Err("File does not exist."); RETURN FALSE END;
  IF (areas[a].db.numFields = 0) OR (areas[a].db.recordLen > MaxRecBuf - 2) THEN
    DBF.Close(areas[a].db); Err("Not a dBASE database."); RETURN FALSE
  END;
  areas[a].used := TRUE;
  Cpy(path, areas[a].fname);
  IF alias[0] # 0X THEN Cpy(alias, areas[a].alias); Upper(areas[a].alias)
  ELSE BaseName(path, areas[a].alias); areas[a].alias[10] := 0X
  END;
  hasMemo := FALSE;
  FOR i := 0 TO areas[a].db.numFields - 1 DO
    IF areas[a].db.fields[i].type = DBF.TypeMemo THEN hasMemo := TRUE END
  END;
  IF hasMemo THEN DBF.MemoName(path, areas[a].memo) ELSE areas[a].memo[0] := 0X END;
  ComputeOffs(a);
  areas[a].nIdx := 0; areas[a].order := 0;
  areas[a].bufRec := -1;
  areas[a].filter := NIL; areas[a].filterTxt[0] := 0X;
  areas[a].relArea := -1; areas[a].relExpr := NIL; areas[a].relTxt[0] := 0X;
  areas[a].found := FALSE; areas[a].locOn := FALSE;
  areas[a].rec := 1;
  GoTop(a);
  RETURN TRUE
END OpenArea;

PROCEDURE CloseAll;
VAR a: INTEGER;
BEGIN
  FOR a := 0 TO MaxAreas - 1 DO CloseArea(a) END;
  cur := 0;
  nFieldList := 0
END CloseAll;

(* ====================================================================
   Command clauses:  <scope> FOR <cond> WHILE <cond> TO ... OFF ...
   ==================================================================== *)

CONST MaxExprs = 64;

TYPE
  ExprList = RECORD
    n: INTEGER;
    e: ARRAY MaxExprs OF Node;
    txt: ARRAY MaxExprs OF Str
  END;

PROCEDURE InitClauses(VAR c: Clauses);
BEGIN
  c.scope := scDefault; c.n := 0; c.forN := NIL; c.whileN := NIL;
  c.off := FALSE; c.toPrint := FALSE; c.plain := FALSE; c.noEject := FALSE;
  c.summary := FALSE; c.sample := FALSE; c.toFile[0] := 0X; c.heading[0] := 0X
END InitClauses;

(* text of src between two positions, trimmed *)
PROCEDURE SrcText(a, b: INTEGER; VAR s: ARRAY OF CHAR);
BEGIN
  Sub(src, a, b - a, s); Trim(s)
END SrcText;

(* Try to consume one clause; TRUE if one was recognised *)
PROCEDURE OneClause(VAR c: Clauses): BOOLEAN;
VAR n: Node; v: Value;
BEGIN
  IF tk # tIdent THEN RETURN FALSE END;
  IF IsKw("ALL") THEN Next; c.scope := scAll
  ELSIF IsKw("REST") THEN Next; c.scope := scRest
  ELSIF IsKw("NEXT") THEN
    Next; n := Expr(); c.scope := scNext; c.n := EvalInt(n)
  ELSIF IsKw("RECORD") THEN
    Next; n := Expr(); c.scope := scRecord; c.n := EvalInt(n)
  ELSIF IsKw("FOR") THEN Next; c.forN := Expr()
  ELSIF IsKw("WHILE") THEN Next; c.whileN := Expr()
  ELSIF IsKw("OFF") THEN Next; c.off := TRUE
  ELSIF IsKw("PLAIN") THEN Next; c.plain := TRUE
  ELSIF IsKw("NOEJECT") THEN Next; c.noEject := TRUE
  ELSIF IsKw("SUMMARY") THEN Next; c.summary := TRUE
  ELSIF IsKw("SAMPLE") THEN Next; c.sample := TRUE
  ELSIF IsKw("HEADING") THEN
    Next; n := Expr(); Eval(n, v);
    IF ~err THEN ValText(v, c.heading) END
  ELSIF IsKw("TO") THEN
    Next;
    IF IsKw("PRINT") THEN Next; c.toPrint := TRUE
    ELSIF IsKw("FILE") THEN Next; RawWord(c.toFile)
    ELSE RETURN FALSE
    END
  ELSE RETURN FALSE
  END;
  RETURN TRUE
END OneClause;

(* Expression list, separated by commas; stops at a clause keyword *)
PROCEDURE ParseExprList(VAR el: ExprList);
VAR start: INTEGER; n: Node;
BEGIN
  LOOP
    IF (tk = tEOF) OR err THEN EXIT END;
    IF IsKw("ALL") OR IsKw("REST") OR IsKw("NEXT") OR IsKw("RECORD") OR IsKw("FOR")
       OR IsKw("WHILE") OR IsKw("OFF") OR IsKw("TO") THEN EXIT END;
    start := tkStart;
    n := Expr();
    IF err THEN EXIT END;
    IF el.n < MaxExprs THEN
      el.e[el.n] := n; SrcText(start, tkStart, el.txt[el.n]); INC(el.n)
    END;
    IF tk = tComma THEN Next ELSE EXIT END
  END
END ParseExprList;

(* clauses in any order, with an optional expression list *)
PROCEDURE ParseClauses(VAR c: Clauses; VAR el: ExprList; allowExprs: BOOLEAN);
BEGIN
  InitClauses(c); el.n := 0;
  WHILE (tk # tEOF) & ~err DO
    IF OneClause(c) THEN
    ELSIF IsKw("FIELDS") & allowExprs THEN Next; ParseExprList(el)
    ELSIF allowExprs & (el.n = 0) THEN
      ParseExprList(el);
      IF (el.n = 0) & ~err THEN Err("Syntax error.") END
    ELSE
      Err("Unrecognized phrase/keyword in command.")
    END
  END
END ParseClauses;

(* ---- scope iteration ---- *)

TYPE
  Scope = RECORD
    kind, left: INTEGER;
    done: BOOLEAN;
    forN, whileN: Node;
    count: INTEGER
  END;

PROCEDURE ScopeStart(VAR s: Scope; VAR c: Clauses; defKind: INTEGER);
BEGIN
  s.kind := c.scope; s.forN := c.forN; s.whileN := c.whileN;
  s.done := FALSE; s.count := 0; s.left := c.n;
  IF s.kind = scDefault THEN
    IF c.forN # NIL THEN s.kind := scAll
    ELSIF c.whileN # NIL THEN s.kind := scRest
    ELSE s.kind := defKind; s.left := 1
    END
  END;
  CASE s.kind OF
    scAll: GoTop(cur)
  | scRecord:
      IF (c.n < 1) OR (c.n > areas[cur].db.numRecs) THEN Err("Record is out of range.")
      ELSE SetRec(cur, c.n)
      END
  ELSE
  END
END ScopeStart;

PROCEDURE ScopeOK(VAR s: Scope): BOOLEAN;
BEGIN
  LOOP
    IF err OR interrupted OR s.done OR areas[cur].eof THEN RETURN FALSE END;
    IF (s.kind = scNext) & (s.left <= 0) THEN RETURN FALSE END;
    IF (s.count MOD 16 = 15) & EscPressed() THEN interrupted := TRUE; RETURN FALSE END;
    INC(s.count);
    IF (s.whileN # NIL) & ~EvalBool(s.whileN) THEN RETURN FALSE END;
    IF err THEN RETURN FALSE END;
    IF (s.forN = NIL) OR EvalBool(s.forN) THEN RETURN ~err END;
    IF err THEN RETURN FALSE END;
    (* not selected: move on *)
    IF s.kind = scRecord THEN RETURN FALSE
    ELSIF s.kind = scNext THEN
      DEC(s.left);
      IF s.left <= 0 THEN RETURN FALSE END;
      IF ~Step(cur, 1) THEN RETURN FALSE END
    ELSE
      IF ~Step(cur, 1) THEN RETURN FALSE END
    END
  END
END ScopeOK;

PROCEDURE ScopeAdvance(VAR s: Scope);
BEGIN
  IF s.kind = scRecord THEN s.done := TRUE
  ELSIF s.kind = scNext THEN
    DEC(s.left);
    IF s.left > 0 THEN IF ~Step(cur, 1) THEN END END
  ELSE
    IF ~Step(cur, 1) THEN END
  END
END ScopeAdvance;

(* Start/finish TO PRINT / TO FILE output for one command *)
PROCEDURE BeginTo(VAR c: Clauses): BOOLEAN;
VAR path: Str;
BEGIN
  prnActive := c.toPrint;
  IF c.toFile[0] # 0X THEN
    NewPath(c.toFile, ".txt", path);
    toF := Files.New(path);
    IF toF = NIL THEN Err("Unable to create file."); RETURN FALSE END;
    Files.Set(toR, toF, 0); toActive := TRUE
  END;
  RETURN TRUE
END BeginTo;

PROCEDURE EndTo;
BEGIN
  IF toActive & (toF # NIL) THEN
    Files.Write(toR, 10);
    Files.Register(toF); Files.Close(toF); toF := NIL
  END;
  toActive := FALSE;
  IF prnActive & (prnF # NIL) THEN PrnNL; Files.Register(prnF) END;
  prnActive := FALSE
END EndTo;

(* ====================================================================
   LIST / DISPLAY
   ==================================================================== *)

PROCEDURE FieldWidth(a, f: INTEGER): INTEGER;
BEGIN
  CASE areas[a].db.fields[f].type OF
    "D": IF setCentury THEN RETURN 10 ELSE RETURN 8 END
  | "L": RETURN 3
  | "M": RETURN 4
  ELSE RETURN areas[a].db.fields[f].len
  END
END FieldWidth;

(* default field list: SET FIELDS if on, else all fields of current area *)
PROCEDURE DefaultFields(VAR el: ExprList);
VAR i: INTEGER; nd: Node;
BEGIN
  el.n := 0;
  IF setFieldsOn & (nFieldList > 0) THEN
    FOR i := 0 TO nFieldList - 1 DO
      nd := NewNode(nField); nd.area := fieldList[i].area; nd.fld := fieldList[i].fld;
      el.e[el.n] := nd;
      Cpy(areas[nd.area].db.fields[nd.fld].name, el.txt[el.n]);
      IF nd.area # cur THEN
        Cpy(areas[nd.area].alias, el.txt[el.n]); Append("->", el.txt[el.n]);
        Append(areas[nd.area].db.fields[nd.fld].name, el.txt[el.n])
      END;
      INC(el.n)
    END
  ELSE
    FOR i := 0 TO areas[cur].db.numFields - 1 DO
      IF el.n < MaxExprs THEN
        nd := NewNode(nField); nd.area := cur; nd.fld := i;
        el.e[el.n] := nd; Cpy(areas[cur].db.fields[i].name, el.txt[el.n]);
        INC(el.n)
      END
    END
  END
END DefaultFields;

(* line breaks in a memo become single blanks for one-line display *)
PROCEDURE FlattenMemo(VAR m: ARRAY OF CHAR);
VAR i, j: INTEGER;
BEGIN
  i := 0; j := 0;
  WHILE m[i] # 0X DO
    IF m[i] = 0DX THEN
    ELSIF (m[i] = 0AX) OR (m[i] = 8DX) THEN m[j] := " "; INC(j)
    ELSE m[j] := m[i]; INC(j)
    END;
    INC(i)
  END;
  m[j] := 0X
END FlattenMemo;

(* text of column i for the current record *)
PROCEDURE ColText(nd: Node; isDefault: BOOLEAN; VAR s: ARRAY OF CHAR);
VAR v: Value; memo: ARRAY MaxMemo OF CHAR;
BEGIN
  IF (nd.kind = nField) & (areas[nd.area].db.fields[nd.fld].type = "M") THEN
    IF isDefault THEN
      IF MemoBlock(nd.area, nd.fld) > 0 THEN Cpy("Memo", s) ELSE Cpy("memo", s) END
    ELSE
      ReadMemo(nd.area, nd.fld, memo); FlattenMemo(memo); memo[setMemoWidth] := 0X; Cpy(memo, s)
    END;
    RETURN
  END;
  Eval(nd, v);
  IF err THEN s[0] := 0X; RETURN END;
  ValStr(v, s)
END ColText;

PROCEDURE ColWidth(nd: Node; VAR txt: ARRAY OF CHAR; isDefault: BOOLEAN): INTEGER;
VAR w: INTEGER; s: Str;
BEGIN
  IF nd.kind = nField THEN
    w := FieldWidth(nd.area, nd.fld);
    IF ~isDefault & (areas[nd.area].db.fields[nd.fld].type = "M") THEN w := setMemoWidth END
  ELSE
    ColText(nd, isDefault, s); w := SLen(s)
  END;
  IF SLen(txt) > w THEN w := SLen(txt) END;
  RETURN w
END ColWidth;

PROCEDURE DoList(isDisplay: BOOLEAN);
VAR
  c: Clauses; el: ExprList; s: Scope; isDefault, header: BOOLEAN;
  i, cnt: INTEGER; line, t: Str; w: ARRAY MaxExprs OF INTEGER;
  nd: Node;
BEGIN
  ParseClauses(c, el, TRUE);
  IF err OR ~NeedDb() THEN RETURN END;
  isDefault := el.n = 0;
  IF isDefault THEN DefaultFields(el) END;
  IF ~BeginTo(c) THEN RETURN END;
  IF isDisplay THEN ScopeStart(s, c, scNext) ELSE ScopeStart(s, c, scAll) END;
  paging := isDisplay & (s.kind # scNext) & ~c.toPrint;
  pageCount := 0;
  header := setHeadings;
  cnt := 0;
  WHILE ScopeOK(s) DO
    IF header THEN
      FOR i := 0 TO el.n - 1 DO w[i] := ColWidth(el.e[i], el.txt[i], isDefault) END;
      IF c.off THEN line[0] := 0X ELSE Cpy("Record# ", line) END;
      FOR i := 0 TO el.n - 1 DO
        Cpy(el.txt[i], t);
        IF isDefault THEN Upper(t) END;
        nd := el.e[i];
        IF (nd.kind = nField) & (areas[nd.area].db.fields[nd.fld].type = "N") THEN PadL(t, w[i]) ELSE PadR(t, w[i]) END;
        IF i < el.n - 1 THEN Append(t, line); Append(" ", line) ELSE Append(t, line) END
      END;
      RTrim(line);
      Line(line);
      header := FALSE
    ELSIF cnt = 0 THEN
      FOR i := 0 TO el.n - 1 DO w[i] := ColWidth(el.e[i], el.txt[i], isDefault) END
    END;
    IF c.off THEN line[0] := 0X
    ELSE
      IntStrW(areas[cur].rec, 7, line);
      IF areas[cur].buf[0] = "*" THEN Append("*", line) ELSE Append(" ", line) END
    END;
    FOR i := 0 TO el.n - 1 DO
      ColText(el.e[i], isDefault, t);
      IF err THEN EXIT END;
      IF SLen(t) < w[i] THEN
        nd := el.e[i];
        IF (nd.kind # nField) & (SLen(t) > 0) & (t[0] = " ") THEN PadL(t, w[i]) ELSE PadR(t, w[i]) END
      END;
      Append(t, line);
      IF i < el.n - 1 THEN Append(" ", line) END
    END;
    RTrim(line);
    Line(line);
    INC(cnt);
    ScopeAdvance(s)
  END;
  IF header & ~err & (cnt = 0) & ~isDisplay THEN
    (* empty listing still shows its heading line *)
    IF c.off THEN line[0] := 0X ELSE Cpy("Record# ", line) END;
    FOR i := 0 TO el.n - 1 DO Cpy(el.txt[i], t); IF isDefault THEN Upper(t) END; Append(t, line); Append(" ", line) END;
    RTrim(line); Line(line)
  END;
  paging := FALSE;
  EndTo
END DoList;

PROCEDURE TypeName(c: CHAR; VAR s: ARRAY OF CHAR);
BEGIN
  CASE c OF
    "C": Cpy("Character", s) | "N": Cpy("Numeric", s) | "F": Cpy("Float", s)
  | "L": Cpy("Logical", s) | "D": Cpy("Date", s) | "M": Cpy("Memo", s)
  ELSE Cpy("Unknown", s)
  END
END TypeName;

PROCEDURE ListStructure(a: INTEGER);
VAR i, tot: INTEGER; line, t: Str;
BEGIN
  Cpy("Structure for database: ", line);
  AppendCh(defDrive, line); Append(":", line); ShortName(areas[a].fname, t); Append(t, line);
  Line(line);
  Cpy("Number of data records: ", line); IntStrW(areas[a].db.numRecs, 7, t); Append(t, line); Line(line);
  Cpy("Date of last update   : ", line);
  DateStr(Julian(areas[a].db.year, areas[a].db.month, areas[a].db.day), t); Append(t, line); Line(line);
  Line("Field  Field Name  Type       Width    Dec");
  tot := 1;
  FOR i := 0 TO areas[a].db.numFields - 1 DO
    IntStrW(i + 1, 5, line); Append("  ", line);
    Cpy(areas[a].db.fields[i].name, t); PadR(t, 12); Append(t, line);
    TypeName(areas[a].db.fields[i].type, t); PadR(t, 10); Append(t, line);
    IntStrW(areas[a].db.fields[i].len, 6, t); Append(t, line);
    IF (areas[a].db.fields[i].type = "N") OR (areas[a].db.fields[i].type = "F") THEN
      IntStrW(areas[a].db.fields[i].dec, 7, t); Append(t, line)
    END;
    Line(line);
    INC(tot, areas[a].db.fields[i].len)
  END;
  Cpy("** Total **", line); PadR(line, 29); IntStrW(tot, 6, t); Append(t, line);
  Line(line)
END ListStructure;

PROCEDURE OnOff(b: BOOLEAN; VAR s: ARRAY OF CHAR);
BEGIN IF b THEN Cpy("ON ", s) ELSE Cpy("OFF", s) END END OnOff;

PROCEDURE ListStatus;
VAR a, k: INTEGER; line, t: Str;
  PROCEDURE Opt(name: ARRAY OF CHAR; b: BOOLEAN);
  VAR u: Str;
  BEGIN
    Cpy(name, u); PadR(u, 11); Append("- ", u);
    IF b THEN Append("ON ", u) ELSE Append("OFF", u) END;
    Append("   ", u); Append(u, line)
  END Opt;
BEGIN
  FOR a := 0 TO MaxAreas - 1 DO
    IF areas[a].used THEN
      OutNL;
      Cpy("Currently Selected Database:", line);
      IF a # cur THEN line[0] := 0X END;
      IF line[0] # 0X THEN Line(line) END;
      Cpy("Select area: ", line); AppendInt(a + 1, line);
      Append(", Database in Use: ", line); AppendCh(defDrive, line); Append(":", line);
      ShortName(areas[a].fname, t); Append(t, line);
      Append("  Alias: ", line); Append(areas[a].alias, line);
      Line(line);
      FOR k := 0 TO areas[a].nIdx - 1 DO
        IF k + 1 = areas[a].order THEN Cpy("    Master index file: ", line)
        ELSE Cpy("           Index file: ", line) END;
        AppendCh(defDrive, line); Append(":", line);
        ShortName(areas[a].idx[k].fname, t); Append(t, line);
        Append(" Key: ", line); Append(areas[a].idx[k].ix.expr, line);
        Line(line)
      END;
      IF areas[a].memo[0] # 0X THEN
        Cpy("            Memo file: ", line); AppendCh(defDrive, line); Append(":", line);
        ShortName(areas[a].memo, t); Append(t, line); Line(line)
      END;
      IF areas[a].filterTxt[0] # 0X THEN
        Cpy("               Filter: ", line); Append(areas[a].filterTxt, line); Line(line)
      END;
      IF areas[a].relArea >= 0 THEN
        Cpy("     Related into: ", line); Append(areas[areas[a].relArea].alias, line);
        Line(line);
        Cpy("     Relation: ", line); Append(areas[a].relTxt, line); Line(line)
      END
    END
  END;
  OutNL;
  Cpy("File search path: ", line); Append(pathDirs, line); Line(line);
  Cpy("Default disk drive: ", line); AppendCh(defDrive, line); Append(":", line); Line(line);
  Cpy("Print destination: ", line); Append(prnName, line); Line(line);
  Cpy("Margin = ", line); AppendInt(setMargin, line); Line(line);
  OutNL;
  Line("Function key  Assignment");
  FOR k := 1 TO 9 DO
    Cpy("F", line); AppendInt(k + 1, line); PadR(line, 14);
    Append(fkeys[k], line); Line(line)
  END;
  OutNL;
  line[0] := 0X;
  Opt("ALTERNATE", setAlternate); Opt("BELL", setBell); Opt("CARRY", setCarry); Opt("CENTURY", setCentury);
  Line(line); line[0] := 0X;
  Opt("CONFIRM", setConfirm); Opt("CONSOLE", setConsole); Opt("DELETED", setDeleted); Opt("DELIMITERS", setDelimiters);
  Line(line); line[0] := 0X;
  Opt("ESCAPE", setEscape); Opt("EXACT", setExact); Opt("FIELDS", setFieldsOn); Opt("FIXED", setFixed);
  Line(line); line[0] := 0X;
  Opt("HEADINGS", setHeadings); Opt("HELP", setHelp); Opt("INTENSITY", setIntensity); Opt("MENU", setMenu);
  Line(line); line[0] := 0X;
  Opt("PRINT", setPrint); Opt("SAFETY", setSafety); Opt("STATUS", setStatus); Opt("TALK", setTalk);
  Line(line); line[0] := 0X;
  Opt("UNIQUE", setUnique); Opt("ECHO", setEcho);
  Line(line)
END ListStatus;

PROCEDURE ListMemory;
VAR i, bytes: INTEGER; line, t: Str;
BEGIN
  bytes := 0;
  FOR i := 0 TO nVars - 1 DO
    Cpy(vars[i].name, line); PadR(line, 11);
    IF vars[i].public THEN Append("pub   ", line) ELSE Append("priv  ", line) END;
    AppendCh(vars[i].v.t, line); Append("  ", line);
    CASE vars[i].v.t OF
      "C": Append('"', line); Append(vars[i].v.s, line); Append('"', line);
           INC(bytes, SLen(vars[i].v.s) + 2)
    | "N": FmtFixed(vars[i].v.n, vars[i].v.dec, t); PadL(t, 10); Append(t, line);
           Append("  (", line); FmtFixed(vars[i].v.n, 10, t);
           WHILE (SLen(t) > 1) & (t[SLen(t) - 1] = "0") DO t[SLen(t) - 1] := 0X END;
           IF t[SLen(t) - 1] = "." THEN t[SLen(t) - 1] := 0X END;
           Append(t, line); Append(")", line); INC(bytes, 9)
    ELSE ValStr(vars[i].v, t); Append(t, line); INC(bytes, 9)
    END;
    IF vars[i].level > 0 THEN
      Append("   ", line);
      IF (vars[i].level <= depth) & (frames[vars[i].level - 1].p # NIL) THEN
        ShortName(frames[vars[i].level - 1].p.name, t); Append(t, line)
      END
    END;
    Line(line)
  END;
  Cpy("   ", line); AppendInt(nVars, line); Append(" variables defined, ", line);
  IntStrW(bytes, 6, t); Append(t, line); Append(" bytes used", line); Line(line);
  Cpy("   ", line); AppendInt(MaxVars - nVars, line); Append(" variables available, ", line);
  IntStrW(6000 - bytes, 6, t); Append(t, line); Append(" bytes available", line); Line(line)
END ListMemory;

PROCEDURE ListHistory;
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO nCmdHist - 1 DO Line(cmdHist[i]) END
END ListHistory;


PROCEDURE FileSize(path: ARRAY OF CHAR): INTEGER;
VAR f: Files.File; n: INTEGER;
BEGIN
  f := Files.Old(path);
  IF f = NIL THEN RETURN 0 END;
  n := Files.Length(f); Files.Close(f);
  RETURN n
END FileSize;

PROCEDURE DoDir(skel: ARRAY OF CHAR);
VAR
  i, n, files, bytes, col, sz: INTEGER; name, path, line, t, dir: Str;
  db: DBF.Database; dbfMode: BOOLEAN;
BEGIN
  Cpy(skel, t); StripDrive(t);
  dbfMode := t[0] = 0X;
  IF dbfMode THEN Cpy("*.dbf", t) END;
  IF defDir[0] # 0X THEN Cpy(defDir, dir) ELSE dir[0] := 0X END;
  OS.DirOpen(dir, "");
  n := OS.DirCount();
  files := 0; bytes := 0; col := 0; line[0] := 0X;
  IF dbfMode THEN Line("Database Files    # Records    Last Update     Size") END;
  FOR i := 0 TO n - 1 DO
    OS.DirName(i, name);
    IF ~OS.DirIsDir(i) & WildMatch(t, name, 0, 0) THEN
      WithDir(name, path);
      sz := FileSize(path);
      INC(files); INC(bytes, sz);
      IF dbfMode THEN
        DBF.Open(db, path);
        Cpy(name, line); Upper(line); PadR(line, 16);
        IF db.f # NIL THEN
          IntStrW(db.numRecs, 11, t); Append(t, line); Append("    ", line);
          DateStr(Julian(db.year, db.month, db.day), t); Append(t, line);
          IntStrW(sz, 13, t); Append(t, line);
          Files.Close(db.f)
        END;
        Line(line)
      ELSE
        Cpy(name, t); Upper(t); PadR(t, 16);
        IF col = 0 THEN line[0] := 0X END;
        Append(t, line); INC(col);
        IF col = 4 THEN Line(line); col := 0 END
      END
    END
  END;
  IF ~dbfMode & (col > 0) THEN Line(line) END;
  OutNL;
  IntStrW(bytes, 8, line); Append(" bytes in ", line); IntStrW(files, 4, t); Append(t, line);
  Append(" files.", line); Line(line);
  OutNL
END DoDir;

(* ---- SUM / AVERAGE / COUNT ---- *)

PROCEDURE DoSum(avg: BOOLEAN);
VAR
  c: Clauses; el: ExprList; s: Scope; i, cnt: INTEGER; v: Value;
  tot: ARRAY MaxExprs OF REAL; dec, w: ARRAY MaxExprs OF INTEGER;
  line, t, vars: Str; nd: Node; vp: INTEGER;
BEGIN
  vars[0] := 0X;
  InitClauses(c); el.n := 0;
  WHILE (tk # tEOF) & ~err DO
    IF IsKw("TO") THEN
      Next;
      LOOP
        IF tk # tIdent THEN Err("Syntax error."); EXIT END;
        IF vars[0] # 0X THEN Append(",", vars) END;
        Append(tkStr, vars); Next;
        IF tk = tComma THEN Next ELSE EXIT END
      END
    ELSIF OneClause(c) THEN
    ELSIF el.n = 0 THEN ParseExprList(el)
    ELSE Err("Unrecognized phrase/keyword in command.")
    END
  END;
  IF err OR ~NeedDb() THEN RETURN END;
  IF el.n = 0 THEN
    FOR i := 0 TO areas[cur].db.numFields - 1 DO
      IF (areas[cur].db.fields[i].type = "N") OR (areas[cur].db.fields[i].type = "F") THEN
        nd := NewNode(nField); nd.area := cur; nd.fld := i;
        el.e[el.n] := nd; Cpy(areas[cur].db.fields[i].name, el.txt[el.n]); Lower(el.txt[el.n]);
        INC(el.n)
      END
    END
  END;
  FOR i := 0 TO el.n - 1 DO tot[i] := 0.0; dec[i] := 0; w[i] := 10 END;
  ScopeStart(s, c, scAll);
  cnt := 0;
  WHILE ScopeOK(s) DO
    FOR i := 0 TO el.n - 1 DO
      Eval(el.e[i], v);
      IF ~err & (v.t # TN) THEN Err("Not a numeric expression.") END;
      IF ~err THEN
        tot[i] := tot[i] + v.n; dec[i] := MaxI(dec[i], v.dec); w[i] := MaxI(w[i], v.w)
      END
    END;
    IF err THEN RETURN END;
    INC(cnt);
    ScopeAdvance(s)
  END;
  IF err THEN RETURN END;
  IF avg THEN TalkCount(cnt, "averaged") ELSE TalkCount(cnt, "summed") END;
  line[0] := 0X;
  FOR i := 0 TO el.n - 1 DO
    IF avg & (cnt > 0) THEN tot[i] := tot[i] / FLT(cnt); dec[i] := MaxI(dec[i], setDecimals) END;
    Cpy(el.txt[i], t); IF avg & (el.n = 1) THEN Cpy("average", t) END;
    w[i] := MaxI(w[i], SLen(t)); PadL(t, w[i]); Append(t, line); Append(" ", line)
  END;
  IF setTalk THEN Talk(line) END;
  line[0] := 0X;
  FOR i := 0 TO el.n - 1 DO
    FmtFixed(tot[i], dec[i], t); PadL(t, w[i]); Append(t, line); Append(" ", line)
  END;
  IF setTalk THEN Talk(line) END;
  (* TO <memvar list> *)
  IF vars[0] # 0X THEN
    i := 0; vp := 0;
    WHILE Strings.Split(vars, ",", vp, t) & (i < el.n) DO
      Trim(t);
      IF t[0] # 0X THEN SetNum(v, tot[i], w[i], dec[i]); StoreVar(t, v) END;
      INC(vp); INC(i)
    END
  END
END DoSum;

PROCEDURE DoCount;
VAR c: Clauses; s: Scope; cnt: INTEGER; v: Value; vname: Str;
BEGIN
  vname[0] := 0X;
  InitClauses(c);
  WHILE (tk # tEOF) & ~err DO
    IF IsKw("TO") THEN Next; RawWord(vname)
    ELSIF ~OneClause(c) THEN Err("Unrecognized phrase/keyword in command.")
    END
  END;
  IF err OR ~NeedDb() THEN RETURN END;
  ScopeStart(s, c, scAll);
  cnt := 0;
  WHILE ScopeOK(s) DO INC(cnt); ScopeAdvance(s) END;
  IF err THEN RETURN END;
  IF cnt = 1 THEN TalkCount(cnt, "") ELSE TalkCount(cnt, "") END;
  IF vname[0] # 0X THEN SetInt(v, cnt); StoreVar(vname, v) END
END DoCount;

(* ====================================================================
   Record-changing commands
   ==================================================================== *)
PROCEDURE DoReplace;
VAR
  c: Clauses; s: Scope; nf, i, cnt, ar: INTEGER;
  fa, ff: ARRAY 32 OF INTEGER; fe: ARRAY 32 OF Node; v: Value;
  name, fname: Str; touchesCur: BOOLEAN;
BEGIN
  InitClauses(c); nf := 0;
  IF ~NeedDb() THEN RETURN END;
  WHILE (tk # tEOF) & ~err DO
    IF OneClause(c) THEN
    ELSIF tk = tIdent THEN
      Cpy(tkStr, name); Next; ar := cur;
      IF tk = tArrow THEN
        Next; Cpy(tkStr, fname); Next;
        ar := AliasArea(name); Cpy(fname, name);
        IF ar < 0 THEN Err("ALIAS not found."); RETURN END
      END;
      i := FieldIdx(ar, name);
      IF i < 0 THEN Err("Variable not found."); RETURN END;
      IF ~IsKw("WITH") THEN Err("Syntax error."); RETURN END;
      Next;
      IF nf < 32 THEN
        fa[nf] := ar; ff[nf] := i; fe[nf] := Expr(); INC(nf)
      END;
      IF tk = tComma THEN Next END
    ELSE Err("Syntax error.")
    END
  END;
  IF err THEN RETURN END;
  IF nf = 0 THEN Err("Syntax error."); RETURN END;
  (* Does any assignment target the current area? *)
  touchesCur := FALSE;
  FOR i := 0 TO nf - 1 DO
    IF fa[i] = cur THEN touchesCur := TRUE END
  END;
  ScopeStart(s, c, scNext);
  cnt := 0;
  WHILE ScopeOK(s) DO
    IF touchesCur THEN BeginChange(cur) END;
    FOR i := 0 TO nf - 1 DO
      Eval(fe[i], v);
      IF ~err THEN
        IF fa[i] # cur THEN BeginChange(fa[i]) END;
        PutFieldVal(fa[i], ff[i], v);
        IF fa[i] # cur THEN EndChange(fa[i]) END
      END
    END;
    IF err THEN EXIT END;
    IF touchesCur THEN EndChange(cur) END;
    INC(cnt);
    ScopeAdvance(s)
  END;
  TalkCount(cnt, "replaced")
END DoReplace;
PROCEDURE DoDeleteRecall(del: BOOLEAN);
VAR c: Clauses; s: Scope; cnt: INTEGER;
BEGIN
  InitClauses(c);
  WHILE (tk # tEOF) & ~err DO
    IF ~OneClause(c) THEN Err("Unrecognized phrase/keyword in command.") END
  END;
  IF err OR ~NeedDb() THEN RETURN END;
  (* RECALL must see deleted records even with SET DELETED ON *)
  ScopeStart(s, c, scNext);
  cnt := 0;
  WHILE ScopeOK(s) DO
    EnsureRec(cur);
    IF del THEN areas[cur].buf[0] := "*" ELSE areas[cur].buf[0] := " " END;
    DBF.WriteRec(areas[cur].db, areas[cur].rec - 1, areas[cur].buf);
    INC(cnt);
    ScopeAdvance(s)
  END;
  IF del THEN TalkCount(cnt, "deleted") ELSE TalkCount(cnt, "recalled") END
END DoDeleteRecall;

(* Rebuild every open index of area a from its key expression *)
PROCEDURE Reindex(a: INTEGER);
VAR k, r: INTEGER; ix: DBF.NdxIndex; key: ARRAY DBF.MaxNdxKey + 1 OF CHAR; num: REAL;
  save: INTEGER; line: Str;
BEGIN
  save := areas[a].rec;
  FOR k := 0 TO areas[a].nIdx - 1 DO
    ix := areas[a].idx[k].ix; ix.n := 0;
    FOR r := 1 TO areas[a].db.numRecs DO
      areas[a].rec := r; EnsureRec(a);
      IdxKey(a, k, key, num);
      IF err THEN RETURN END;
      InsertKey(ix, key, num, r)
    END;
    areas[a].idx[k].dirty := TRUE;
    Cpy("Rebuilding index - ", line); ShortName(areas[a].idx[k].fname, key); Append(key, line);
    Talk(line);
    IntStrW(areas[a].db.numRecs, 7, line); Append(" Records indexed", line);
    Talk(line)
  END;
  FlushIndexes(a);
  areas[a].rec := save; areas[a].bufRec := -1
END Reindex;

PROCEDURE DoPack;
VAR n: INTEGER;
BEGIN
  IF ~NeedDb() THEN RETURN END;
  n := 0;
  DBF.Pack(areas[cur].db, areas[cur].fname);
  areas[cur].bufRec := -1;
  TalkCount(areas[cur].db.numRecs, "copied");
  Reindex(cur);
  GoTop(cur)
END DoPack;

PROCEDURE DoZap;
VAR q, t: Str;
BEGIN
  IF ~NeedDb() THEN RETURN END;
  IF setSafety & (depth = 0) THEN
    Cpy("Zap ", q); AppendCh(defDrive, q); Append(":", q);
    ShortName(areas[cur].fname, t); Append(t, q); Append("? (Y/N)", q);
    IF ~AskYN(q) THEN RETURN END
  END;
  DBF.Zap(areas[cur].db, areas[cur].fname);
  IF areas[cur].memo[0] # 0X THEN DBF.MemoCreate(areas[cur].memo) END;
  areas[cur].bufRec := -1;
  Reindex(cur);
  GoTop(cur)
END DoZap;

(* ---- pointer movement ---- *)

PROCEDURE DoGoto;
VAR n: Node; r: INTEGER;
BEGIN
  IF ~NeedDb() THEN RETURN END;
  IF IsKw("TOP") THEN Next; GoTop(cur)
  ELSIF IsKw("BOTTOM") THEN Next; GoBottom(cur)
  ELSE
    IF IsKw("RECORD") THEN Next END;
    n := Expr(); r := EvalInt(n);
    IF err THEN RETURN END;
    IF (r < 1) OR (r > areas[cur].db.numRecs) THEN Err("Record is out of range."); RETURN END;
    SetRec(cur, r)
  END
END DoGoto;

PROCEDURE DoSkip;
VAR n: Node; k: INTEGER; t: Str;
BEGIN
  IF ~NeedDb() THEN RETURN END;
  k := 1;
  IF tk # tEOF THEN n := Expr(); k := EvalInt(n) END;
  IF err THEN RETURN END;
  Skip(cur, k);
  IF ~err THEN
    Cpy("Record no. ", t); IntStrW(areas[cur].rec, 6, t);
    Strings.Insert("Record no. ", 0, t); Talk(t)
  END
END DoSkip;

PROCEDURE LocateRun(a: INTEGER);
VAR t: Str;
BEGIN
  areas[a].found := FALSE;
  LOOP
    IF areas[a].eof OR err THEN EXIT END;
    IF (areas[a].locKind = scNext) & (areas[a].locLeft <= 0) THEN EXIT END;
    IF (areas[a].locWhile # NIL) & ~EvalBool(areas[a].locWhile) THEN EXIT END;
    IF EvalBool(areas[a].locFor) THEN areas[a].found := TRUE; EXIT END;
    IF err THEN EXIT END;
    DEC(areas[a].locLeft);
    IF ~Step(a, 1) THEN EXIT END
  END;
  IF err THEN RETURN END;
  IF areas[a].found THEN
    Cpy("Record = ", t); IntStrW(areas[a].rec, 7, t); Strings.Insert("Record = ", 0, t); Talk(t)
  ELSE
    IF areas[a].locKind # scNext THEN SetEof(a) END;
    Talk("End of locate scope")
  END
END LocateRun;

PROCEDURE DoLocate;
VAR c: Clauses;
BEGIN
  InitClauses(c);
  WHILE (tk # tEOF) & ~err DO
    IF ~OneClause(c) THEN Err("Unrecognized phrase/keyword in command.") END
  END;
  IF err OR ~NeedDb() THEN RETURN END;
  IF c.forN = NIL THEN c.forN := NewNode(nConst); SetBool(c.forN.v, TRUE) END;
  areas[cur].locFor := c.forN; areas[cur].locWhile := c.whileN;
  areas[cur].locKind := c.scope; areas[cur].locLeft := c.n;
  IF c.scope = scDefault THEN
    IF c.whileN # NIL THEN areas[cur].locKind := scRest ELSE areas[cur].locKind := scAll END
  END;
  IF areas[cur].locKind = scAll THEN GoTop(cur)
  ELSIF areas[cur].locKind = scRecord THEN SetRec(cur, c.n); areas[cur].locKind := scNext; areas[cur].locLeft := 1
  END;
  areas[cur].locOn := TRUE;
  LocateRun(cur)
END DoLocate;

PROCEDURE DoContinue;
BEGIN
  IF ~NeedDb() THEN RETURN END;
  IF ~areas[cur].locOn THEN Err("CONTINUE without LOCATE."); RETURN END;
  IF areas[cur].eof THEN Talk("End of locate scope"); RETURN END;
  DEC(areas[cur].locLeft);
  IF Step(cur, 1) THEN LocateRun(cur)
  ELSE areas[cur].found := FALSE; Talk("End of locate scope")
  END
END DoContinue;

(* SEEK a value in the master index *)
PROCEDURE SeekValue(VAR v: Value);
VAR ix: DBF.NdxIndex; key: Str; p, n, a: INTEGER; num: REAL;
BEGIN
  a := cur;
  IF areas[a].order = 0 THEN Err("Database is not indexed."); RETURN END;
  ix := areas[a].idx[areas[a].order - 1].ix;
  num := 0.0; key[0] := 0X;
  IF ix.numeric THEN
    IF v.t = TN THEN num := v.n ELSIF v.t = TD THEN num := FLT(v.d) ELSE Mismatch; RETURN END
  ELSE
    IF v.t # TC THEN Mismatch; RETURN END;
    Cpy(v.s, key)
  END;
  n := SLen(key);
  IF setExact & ~ix.numeric THEN PadR(key, ix.keyLen); n := ix.keyLen END;
  IF n > ix.keyLen THEN n := ix.keyLen END;
  p := LowerBound(ix, key, num, n);
  (* skip hidden records with the same key *)
  WHILE (p < ix.n) & (KeyCmp(ix, ix.e[p], key, num, n) = 0) DO
    areas[a].rec := ix.e[p].rec;
    IF Visible(a) THEN
      SetRec(a, ix.e[p].rec); areas[a].found := TRUE; RETURN
    END;
    INC(p)
  END;
  areas[a].found := FALSE;
  SetEof(a);
  Talk("No find.")
END SeekValue;

PROCEDURE DoSeek;
VAR n: Node; v: Value;
BEGIN
  IF ~NeedDb() THEN RETURN END;
  n := Expr(); Eval(n, v);
  IF ~err THEN SeekValue(v) END
END DoSeek;

PROCEDURE DoFind;
VAR s: Str; v: Value;
BEGIN
  IF ~NeedDb() THEN RETURN END;
  IF tk = tStr THEN Cpy(tkStr, s); Next ELSE RawRest(s) END;
  IF areas[cur].order > 0 THEN
    IF areas[cur].idx[areas[cur].order - 1].ix.numeric THEN
      EvalString(s, v)
    ELSE SetStr(v, s)
    END
  ELSE SetStr(v, s)
  END;
  IF ~err THEN SeekValue(v) END
END DoFind;

(* ---- sorting helpers ---- *)

PROCEDURE EntryLess(ix: DBF.NdxIndex; a, b: DBF.NdxEntry): BOOLEAN;
VAR c: INTEGER;
BEGIN
  IF ix.numeric THEN
    IF a.num # b.num THEN RETURN a.num < b.num END
  ELSE
    c := Cmp(a.key, b.key);
    IF c # 0 THEN RETURN c < 0 END
  END;
  RETURN a.rec < b.rec
END EntryLess;

PROCEDURE SortEntries(ix: DBF.NdxIndex);
VAR tmp: POINTER TO ARRAY OF DBF.NdxEntry; width, lo, mid, hi, i, j, k: INTEGER;
BEGIN
  IF ix.n < 2 THEN RETURN END;
  NEW(tmp, ix.n);
  width := 1;
  WHILE width < ix.n DO
    lo := 0;
    WHILE lo < ix.n DO
      mid := MinI(lo + width, ix.n); hi := MinI(lo + 2 * width, ix.n);
      i := lo; j := mid; k := lo;
      WHILE (i < mid) & (j < hi) DO
        IF EntryLess(ix, ix.e[j], ix.e[i]) THEN tmp[k] := ix.e[j]; INC(j)
        ELSE tmp[k] := ix.e[i]; INC(i) END;
        INC(k)
      END;
      WHILE i < mid DO tmp[k] := ix.e[i]; INC(i); INC(k) END;
      WHILE j < hi DO tmp[k] := ix.e[j]; INC(j); INC(k) END;
      INC(lo, 2 * width)
    END;
    FOR i := 0 TO ix.n - 1 DO ix.e[i] := tmp[i] END;
    width := width * 2
  END
END SortEntries;

PROCEDURE DoIndex;
VAR
  start, r, k: INTEGER; exprTxt, name, path, line: Str; nd: Node; v: Value;
  ix: DBF.NdxIndex; e: DBF.NdxEntry; unique: BOOLEAN;
BEGIN
  IF ~NeedDb() THEN RETURN END;
  IF ~IsKw("ON") THEN Err("Syntax error."); RETURN END;
  Next; start := tkStart;
  nd := Expr();
  IF err THEN RETURN END;
  SrcText(start, tkStart, exprTxt);
  IF ~IsKw("TO") THEN Err("Syntax error."); RETURN END;
  Next; RawWord(name);
  unique := setUnique;
  IF IsKw("UNIQUE") THEN Next; unique := TRUE END;
  NewPath(name, ".ndx", path);
  IF ~OkToOverwrite(path) THEN RETURN END;
  ix := DBF.NdxNew();
  Cpy(exprTxt, ix.expr); Upper(ix.expr); ix.unique := unique;
  (* key type and width from the first record (or a blank one) *)
  areas[cur].rec := 1; areas[cur].bufRec := -1; EnsureRec(cur);
  Eval(nd, v);
  IF err THEN RETURN END;
  IF v.t = TC THEN
    ix.numeric := FALSE; ix.keyLen := SLen(v.s);
    IF ix.keyLen > DBF.MaxNdxKey THEN ix.keyLen := DBF.MaxNdxKey END;
    IF ix.keyLen = 0 THEN ix.keyLen := 1 END
  ELSIF (v.t = TN) OR (v.t = TD) THEN ix.numeric := TRUE; ix.keyLen := 8
  ELSE Err("Invalid index expression."); RETURN
  END;
  FOR r := 1 TO areas[cur].db.numRecs DO
    areas[cur].rec := r; EnsureRec(cur);
    Eval(nd, v);
    IF err THEN RETURN END;
    NEW(e); e.rec := r; e.num := 0.0; e.key[0] := 0X;
    IF v.t = TC THEN Cpy(v.s, e.key); e.key[ix.keyLen] := 0X; PadR(e.key, ix.keyLen)
    ELSIF v.t = TN THEN e.num := v.n
    ELSE e.num := FLT(v.d)
    END;
    IF ix.n < DBF.MaxNdx THEN ix.e[ix.n] := e; INC(ix.n) END;
    IF (r MOD 64 = 0) & EscPressed() THEN interrupted := TRUE; RETURN END
  END;
  SortEntries(ix);
  IF unique THEN
    k := 0;
    FOR r := 0 TO ix.n - 1 DO
      IF (k = 0) OR (KeyCmp(ix, ix.e[k - 1], ix.e[r].key, ix.e[r].num, ix.keyLen) # 0) THEN
        ix.e[k] := ix.e[r]; INC(k)
      END
    END;
    ix.n := k
  END;
  IF ~DBF.NdxWrite(ix, path) THEN Err("Unable to create file."); RETURN END;
  CloseIndexes(cur);
  IF OpenIndex(cur, path) THEN END;
  IntStrW(areas[cur].db.numRecs, 6, line); Append(" Records indexed", line);
  Strings.Insert("100% indexed  ", 0, line);
  Talk(line);
  GoTop(cur)
END DoIndex;

PROCEDURE DoSetIndex;
VAR name: Str;
BEGIN
  IF ~NeedDb() THEN RETURN END;
  CloseIndexes(cur);
  WHILE (tk # tEOF) & ~err DO
    RawWord(name);
    IF name[0] # 0X THEN
      IF ~OpenIndex(cur, name) THEN
        (* OpenIndex sets err; stop processing further indexes *)
        RETURN
      END
    END;
    IF tk = tComma THEN Next END
  END;
  IF ~err & (areas[cur].nIdx > 0) THEN GoTop(cur) END
END DoSetIndex;

(* ---- creating .DBF files ---- *)

PROCEDURE CreateDbf(path: ARRAY OF CHAR; VAR flds: ARRAY OF DBF.Field; n: INTEGER;
                    VAR db: DBF.Database): BOOLEAN;
VAR i: INTEGER; memo: Str;
BEGIN
  DBF.Create(db, path, flds, n);
  IF db.f = NIL THEN Err("Unable to create file."); RETURN FALSE END;
  FOR i := 0 TO n - 1 DO
    IF flds[i].type = DBF.TypeMemo THEN
      DBF.MemoName(path, memo); DBF.MemoCreate(memo); RETURN TRUE
    END
  END;
  RETURN TRUE
END CreateDbf;

PROCEDURE CopyFileRaw(from, to: ARRAY OF CHAR): INTEGER;
VAR f, g: Files.File; r, w: Files.Rider; b: BYTE; n: INTEGER;
BEGIN
  f := Files.Old(from);
  IF f = NIL THEN RETURN -1 END;
  g := Files.New(to);
  IF g = NIL THEN Files.Close(f); RETURN -1 END;
  Files.Set(r, f, 0); Files.Set(w, g, 0); n := 0;
  LOOP
    Files.Read(r, b);
    IF r.eof THEN EXIT END;
    Files.Write(w, b); INC(n)
  END;
  Files.Register(g); Files.Close(g); Files.Close(f);
  RETURN n
END CopyFileRaw;

(* memo files travel with copies: duplicate the whole .DBT *)
PROCEDURE CopyMemoFor(a: INTEGER; newDbf: ARRAY OF CHAR);
VAR m: Str;
BEGIN
  IF areas[a].memo[0] # 0X THEN
    DBF.MemoName(newDbf, m);
    IF CopyFileRaw(areas[a].memo, m) < 0 THEN END
  END
END CopyMemoFor;

(* field list (names) -> indexes in area a; all fields if none given *)
PROCEDURE FieldsFromList(a: INTEGER; VAR el: ExprList; VAR idx: ARRAY OF INTEGER; VAR n: INTEGER);
VAR i: INTEGER;
BEGIN
  n := 0;
  IF el.n = 0 THEN
    FOR i := 0 TO areas[a].db.numFields - 1 DO idx[n] := i; INC(n) END
  ELSE
    FOR i := 0 TO el.n - 1 DO
      IF (el.e[i].kind = nField) & (el.e[i].area = a) THEN idx[n] := el.e[i].fld; INC(n)
      ELSE Err("Field not found."); RETURN
      END
    END
  END
END FieldsFromList;

(* text form of a field for SDF / DELIMITED output *)
PROCEDURE FieldOut(a, f: INTEGER; delim: BOOLEAN; VAR s: ARRAY OF CHAR);
BEGIN
  GetRaw(a, f, s);
  IF delim THEN
    IF (areas[a].db.fields[f].type = "N") OR (areas[a].db.fields[f].type = "F") THEN Trim(s)
    ELSE RTrim(s)
    END
  END
END FieldOut;

PROCEDURE DoCopy;
VAR
  c: Clauses; el: ExprList; s: Scope; name, path, t, line: Str;
  sdf, delim, blankDelim, structOnly, extended: BOOLEAN; dch: CHAR;
  idx: ARRAY DBF.MaxFields OF INTEGER; nf, i, cnt, j, off: INTEGER;
  flds: ARRAY DBF.MaxFields OF DBF.Field; db: DBF.Database;
  buf: ARRAY MaxRecBuf OF CHAR; f: Files.File; r: Files.Rider; v: Value;
BEGIN
  IF IsKw("FILE") THEN
    Next; RawWord(name);
    IF ~IsKw("TO") THEN Err("Syntax error."); RETURN END;
    Next; RawWord(t);
    IF ~FindFile(name, "", path) THEN Err("File does not exist."); RETURN END;
    StripDrive(t); WithDir(t, line);
    IF ~OkToOverwrite(line) THEN RETURN END;
    cnt := CopyFileRaw(path, line);
    IF cnt < 0 THEN Err("Unable to create file.") ELSE TalkN2(cnt, " bytes copied") END;
    RETURN
  END;
  IF ~NeedDb() THEN RETURN END;
  structOnly := FALSE; extended := FALSE;
  IF IsKw("STRUCTURE") THEN
    Next; structOnly := TRUE;
    IF IsKw("EXTENDED") THEN Next; extended := TRUE END
  END;
  IF ~IsKw("TO") THEN Err("Syntax error."); RETURN END;
  Next; RawWord(name);
  sdf := FALSE; delim := FALSE; blankDelim := FALSE; dch := '"';
  InitClauses(c); el.n := 0;
  WHILE (tk # tEOF) & ~err DO
    IF OneClause(c) THEN
    ELSIF IsKw("FIELDS") OR IsKw("FIELD") THEN Next; ParseExprList(el)
    ELSIF IsKw("SDF") THEN Next; sdf := TRUE
    ELSIF IsKw("DELIMITED") THEN
      Next; delim := TRUE;
      IF IsKw("WITH") THEN
        Next;
        IF IsKw("BLANK") THEN Next; blankDelim := TRUE
        ELSIF tk = tStr THEN dch := tkStr[0]; Next
        ELSE dch := src[tkStart]; sp := tkStart + 1; Next
        END
      END
    ELSE Err("Unrecognized phrase/keyword in command.")
    END
  END;
  IF err THEN RETURN END;
  FieldsFromList(cur, el, idx, nf);
  IF err THEN RETURN END;
  IF sdf OR delim THEN NewPath(name, ".txt", path) ELSE NewPath(name, ".dbf", path) END;
  IF ~OkToOverwrite(path) THEN RETURN END;

  IF extended THEN
    DBF.MakeField(flds[0], "FIELD_NAME", "C", 10, 0);
    DBF.MakeField(flds[1], "FIELD_TYPE", "C", 1, 0);
    DBF.MakeField(flds[2], "FIELD_LEN", "N", 3, 0);
    DBF.MakeField(flds[3], "FIELD_DEC", "N", 3, 0);
    IF ~CreateDbf(path, flds, 4, db) THEN RETURN END;
    FOR i := 0 TO nf - 1 DO
      j := idx[i];
      Spaces(db.recordLen, buf);
      Cpy(areas[cur].db.fields[j].name, t); PadR(t, 10); FOR off := 0 TO 9 DO buf[1 + off] := t[off] END;
      buf[11] := areas[cur].db.fields[j].type;
      IntStrW(areas[cur].db.fields[j].len, 3, t); FOR off := 0 TO 2 DO buf[12 + off] := t[off] END;
      IntStrW(areas[cur].db.fields[j].dec, 3, t); FOR off := 0 TO 2 DO buf[15 + off] := t[off] END;
      DBF.WriteRec(db, db.numRecs, buf)
    END;
    DBF.Close(db);
    RETURN
  END;

  IF sdf OR delim THEN
    f := Files.New(path);
    IF f = NIL THEN Err("Unable to create file."); RETURN END;
    Files.Set(r, f, 0)
  ELSE
    FOR i := 0 TO nf - 1 DO flds[i] := areas[cur].db.fields[idx[i]] END;
    IF ~CreateDbf(path, flds, nf, db) THEN RETURN END;
    IF structOnly THEN DBF.Close(db); RETURN END;
    CopyMemoFor(cur, path)
  END;
  ScopeStart(s, c, scAll);
  cnt := 0;
  WHILE ScopeOK(s) DO
    EnsureRec(cur);
    IF sdf OR delim THEN
      line[0] := 0X;
      FOR i := 0 TO nf - 1 DO
        j := idx[i];
        FieldOut(cur, j, delim, t);
        IF delim & (i > 0) THEN IF blankDelim THEN AppendCh(" ", line) ELSE AppendCh(",", line) END END;
        IF delim & ~blankDelim & (areas[cur].db.fields[j].type = "C") THEN
          AppendCh(dch, line); Append(t, line); AppendCh(dch, line)
        ELSIF areas[cur].db.fields[j].type = "M" THEN
          IF ~delim THEN Append(t, line) END
        ELSE Append(t, line)
        END
      END;
      WriteStr(r, line); Files.Write(r, 13); Files.Write(r, 10)
    ELSE
      buf[0] := areas[cur].buf[0]; off := 1;
      FOR i := 0 TO nf - 1 DO
        FOR j := 0 TO areas[cur].db.fields[idx[i]].len - 1 DO
          buf[off + j] := areas[cur].buf[areas[cur].offs[idx[i]] + j]
        END;
        INC(off, areas[cur].db.fields[idx[i]].len)
      END;
      buf[off] := 0X;
      DBF.WriteRec(db, db.numRecs, buf)
    END;
    INC(cnt);
    ScopeAdvance(s)
  END;
  IF sdf OR delim THEN Files.Write(r, 1AH); Files.Register(f); Files.Close(f)
  ELSE DBF.Close(db)
  END;
  v.t := TU;
  TalkCount(cnt, "copied")
END DoCopy;

PROCEDURE TalkN2(n: INTEGER; s: ARRAY OF CHAR);
VAR t: Str;
BEGIN
  IntStrW(n, 8, t); Append(s, t); Talk(t)
END TalkN2;

(* ---- SORT ---- *)

TYPE
  SortRec = POINTER TO SortRecRec;
  SortRecRec = RECORD key: Str; rec: INTEGER END;

PROCEDURE SortKeyPart(a, f: INTEGER; fold, desc: BOOLEAN; VAR out: ARRAY OF CHAR);
VAR s: Str; v: Value; i, o: INTEGER;
BEGIN
  CASE areas[a].db.fields[f].type OF
    "N", "F":
      GetFieldVal(a, f, v);
      FmtFixed(v.n + 1.0E14, 6, s);
      WHILE SLen(s) < 24 DO Strings.Insert("0", 0, s) END
  ELSE
    GetRaw(a, f, s);
    IF fold THEN Upper(s) END
  END;
  IF desc THEN
    FOR i := 0 TO SLen(s) - 1 DO
      o := ORD(s[i]);
      IF o < 32 THEN o := 32 ELSIF o > 126 THEN o := 126 END;
      s[i] := CHR(158 - o)
    END
  END;
  Append(s, out)
END SortKeyPart;

PROCEDURE DoSort;
VAR
  c: Clauses; s: Scope; name, path, t, line: Str;
  nk, i, n, cnt, width, lo, mid, hi, j, k: INTEGER;
  kf: ARRAY 10 OF INTEGER; kfold, kdesc: ARRAY 10 OF BOOLEAN;
  arr, tmp: POINTER TO ARRAY OF SortRec; sr, sb: SortRec;
  db: DBF.Database; buf: ARRAY MaxRecBuf OF CHAR;
BEGIN
  IF ~NeedDb() THEN RETURN END;
  IF ~IsKw("ON") THEN Err("Syntax error."); RETURN END;
  Next; nk := 0;
  LOOP
    IF tk # tIdent THEN Err("Syntax error."); RETURN END;
    i := FieldIdx(cur, tkStr);
    IF i < 0 THEN Err("Field not found."); RETURN END;
    IF (areas[cur].db.fields[i].type = "L") OR (areas[cur].db.fields[i].type = "M") THEN
      Err("Cannot sort on logical or memo fields."); RETURN
    END;
    IF nk < 10 THEN kf[nk] := i; kfold[nk] := FALSE; kdesc[nk] := FALSE; INC(nk) END;
    Next;
    WHILE tk = tSlash DO
      Next;
      IF tk = tIdent THEN
        Cpy(tkStr, t); Upper(t);
        FOR j := 0 TO SLen(t) - 1 DO
          IF t[j] = "D" THEN kdesc[nk - 1] := TRUE
          ELSIF t[j] = "C" THEN kfold[nk - 1] := TRUE
          END
        END;
        Next
      END
    END;
    IF tk = tComma THEN Next ELSE EXIT END
  END;
  IF ~IsKw("TO") THEN Err("Syntax error."); RETURN END;
  Next; RawWord(name);
  InitClauses(c);
  WHILE (tk # tEOF) & ~err DO
    IF IsKw("ASCENDING") THEN Next
    ELSIF IsKw("DESCENDING") THEN Next; FOR j := 0 TO nk - 1 DO kdesc[j] := TRUE END
    ELSIF ~OneClause(c) THEN Err("Unrecognized phrase/keyword in command.")
    END
  END;
  IF err THEN RETURN END;
  NewPath(name, ".dbf", path);
  IF EqI(path, areas[cur].fname) THEN Err("Cannot sort a file onto itself."); RETURN END;
  IF ~OkToOverwrite(path) THEN RETURN END;
  n := areas[cur].db.numRecs;
  IF n = 0 THEN n := 1 END;
  NEW(arr, n);
  ScopeStart(s, c, scAll);
  cnt := 0;
  WHILE ScopeOK(s) DO
    NEW(sr); sr.rec := areas[cur].rec; sr.key[0] := 0X;
    FOR j := 0 TO nk - 1 DO SortKeyPart(cur, kf[j], kfold[j], kdesc[j], sr.key) END;
    IF cnt < n THEN arr[cnt] := sr; INC(cnt) END;
    ScopeAdvance(s)
  END;
  IF err OR interrupted THEN RETURN END;
  (* stable merge sort *)
  IF cnt > 1 THEN
    NEW(tmp, cnt);
    width := 1;
    WHILE width < cnt DO
      lo := 0;
      WHILE lo < cnt DO
        mid := MinI(lo + width, cnt); hi := MinI(lo + 2 * width, cnt);
        i := lo; j := mid; k := lo;
        WHILE (i < mid) & (j < hi) DO
          sr := arr[j]; sb := arr[i];
          IF Cmp(sr.key, sb.key) < 0 THEN tmp[k] := arr[j]; INC(j)
          ELSE tmp[k] := arr[i]; INC(i) END;
          INC(k)
        END;
        WHILE i < mid DO tmp[k] := arr[i]; INC(i); INC(k) END;
        WHILE j < hi DO tmp[k] := arr[j]; INC(j); INC(k) END;
        INC(lo, 2 * width)
      END;
      FOR i := 0 TO cnt - 1 DO arr[i] := tmp[i] END;
      width := width * 2
    END
  END;
  IF ~CreateDbf(path, areas[cur].db.fields, areas[cur].db.numFields, db) THEN RETURN END;
  CopyMemoFor(cur, path);
  FOR i := 0 TO cnt - 1 DO
    sr := arr[i]; DBF.ReadRec(areas[cur].db, sr.rec - 1, buf);
    DBF.WriteRec(db, db.numRecs, buf)
  END;
  DBF.Close(db);
  IntStrW(cnt, 6, line); Append(" Records sorted", line);
  Strings.Insert("100% Sorted  ", 0, line);
  Talk(line);
  GoTop(cur)
END DoSort;

(* ---- APPEND FROM / APPEND BLANK / INSERT ---- *)

(* value from a raw field image *)
PROCEDURE RawToVal(ftype: CHAR; len, dec: INTEGER; raw: ARRAY OF CHAR; VAR v: Value);
VAR x: REAL; d: INTEGER;
BEGIN
  CASE ftype OF
    "N", "F": ScanNum(raw, x, d); SetNum(v, x, len, dec)
  | "L": SetBool(v, (raw[0] = "T") OR (raw[0] = "t") OR (raw[0] = "Y") OR (raw[0] = "y"))
  | "D": SetDate(v, DateFromDbf(raw))
  ELSE SetStr(v, raw)
  END
END RawToVal;

(* text field -> value for the target field type *)
PROCEDURE TextToVal(a, f: INTEGER; txt: ARRAY OF CHAR; VAR v: Value);
VAR t: Str;
BEGIN
  Cpy(txt, t);
  IF areas[a].db.fields[f].type = "D" THEN
    Trim(t);
    IF DateFromDbf(t) > 0 THEN SetDate(v, DateFromDbf(t)) ELSE SetDate(v, ParseDate(t)) END
  ELSE
    RawToVal(areas[a].db.fields[f].type, areas[a].db.fields[f].len, areas[a].db.fields[f].dec, t, v);
    IF v.t = TC THEN RTrim(v.s) END
  END
END TextToVal;

PROCEDURE ForOK(forN: Node): BOOLEAN;
BEGIN
  IF forN = NIL THEN RETURN TRUE END;
  RETURN EvalBool(forN) & ~err
END ForOK;

(* prepare a phantom record at EOF to fill before appending *)
PROCEDURE StartNewRec(a: INTEGER);
BEGIN
  areas[a].rec := areas[a].db.numRecs + 1;
  BlankBuf(a); areas[a].bufRec := areas[a].rec
END StartNewRec;

PROCEDURE SplitDelimited(line: ARRAY OF CHAR; dch: CHAR; blank: BOOLEAN;
                         VAR parts: ARRAY OF Str; VAR n: INTEGER);
VAR i, j: INTEGER; sep: CHAR;
BEGIN
  n := 0; i := 0;
  IF blank THEN sep := " " ELSE sep := "," END;
  WHILE (line[i] # 0X) & (n < LEN(parts)) DO
    WHILE (line[i] = " ") & ~blank DO INC(i) END;
    j := 0;
    IF (line[i] = dch) & ~blank THEN
      INC(i);
      WHILE (line[i] # 0X) & (line[i] # dch) DO
        IF j < 255 THEN parts[n][j] := line[i]; INC(j) END; INC(i)
      END;
      IF line[i] = dch THEN INC(i) END;
      WHILE (line[i] # 0X) & (line[i] # sep) DO INC(i) END
    ELSE
      WHILE (line[i] # 0X) & (line[i] # sep) DO
        IF (j < 255) & (line[i] # 0DX) THEN parts[n][j] := line[i]; INC(j) END; INC(i)
      END
    END;
    parts[n][j] := 0X; INC(n);
    IF line[i] = sep THEN INC(i) END;
    IF blank THEN WHILE line[i] = " " DO INC(i) END END
  END
END SplitDelimited;

PROCEDURE DoAppendFrom;
VAR
  name, path, line, raw, memo: Str; c: Clauses; sdf, delim, blank: BOOLEAN; dch: CHAR;
  db: DBF.Database; buf: ARRAY MaxRecBuf OF CHAR; memoTxt: ARRAY MaxMemo OF CHAR;
  map: ARRAY DBF.MaxFields OF INTEGER; srcOff: ARRAY DBF.MaxFields OF INTEGER;
  i, j, r, cnt, off, n, a: INTEGER; v: Value; f: Files.File; rd: Files.Rider;
  parts: ARRAY DBF.MaxFields OF Str;
BEGIN
  IF ~NeedDb() THEN RETURN END;
  a := cur;
  RawWord(name);
  sdf := FALSE; delim := FALSE; blank := FALSE; dch := '"';
  InitClauses(c);
  WHILE (tk # tEOF) & ~err DO
    IF IsKw("SDF") THEN Next; sdf := TRUE
    ELSIF IsKw("TYPE") THEN Next;
      IF IsKw("SDF") THEN sdf := TRUE ELSIF IsKw("DELIMITED") THEN delim := TRUE END; Next
    ELSIF IsKw("DELIMITED") THEN
      Next; delim := TRUE;
      IF IsKw("WITH") THEN
        Next;
        IF IsKw("BLANK") THEN Next; blank := TRUE
        ELSIF tk = tStr THEN dch := tkStr[0]; Next
        ELSE dch := src[tkStart]; sp := tkStart + 1; Next
        END
      END
    ELSIF ~OneClause(c) THEN Err("Unrecognized phrase/keyword in command.")
    END
  END;
  IF err THEN RETURN END;
  cnt := 0;
  IF sdf OR delim THEN
    IF ~FindFile(name, ".txt", path) THEN Err("File does not exist."); RETURN END;
    f := Files.Old(path); Files.Set(rd, f, 0);
    LOOP
      Files.ReadLine(rd, line);
      IF rd.eof & (line[0] = 0X) THEN EXIT END;
      n := SLen(line); IF (n > 0) & (line[n - 1] = 0DX) THEN line[n - 1] := 0X END;
      IF (line[0] = 1AX) THEN EXIT END;
      IF line[0] # 0X THEN
        StartNewRec(a);
        IF sdf THEN
          off := 0;
          FOR i := 0 TO areas[a].db.numFields - 1 DO
            Sub(line, off, areas[a].db.fields[i].len, raw);
            INC(off, areas[a].db.fields[i].len);
            IF areas[a].db.fields[i].type # "M" THEN
              TextToVal(a, i, raw, v); PutFieldVal(a, i, v)
            END
          END
        ELSE
          SplitDelimited(line, dch, blank, parts, n);
          FOR i := 0 TO MinI(n, areas[a].db.numFields) - 1 DO
            IF areas[a].db.fields[i].type # "M" THEN
              TextToVal(a, i, parts[i], v); PutFieldVal(a, i, v)
            END
          END
        END;
        IF err THEN EXIT END;
        IF ForOK(c.forN) THEN AppendBuf(a); INC(cnt) END
      END;
      IF rd.eof THEN EXIT END
    END;
    Files.Close(f)
  ELSE
    IF ~FindFile(name, ".dbf", path) THEN Err("File does not exist."); RETURN END;
    DBF.Open(db, path);
    IF db.f = NIL THEN Err("File does not exist."); RETURN END;
    DBF.MemoName(path, memo);
    off := 1;
    FOR j := 0 TO db.numFields - 1 DO srcOff[j] := off; INC(off, db.fields[j].len) END;
    FOR i := 0 TO areas[a].db.numFields - 1 DO
      map[i] := -1;
      FOR j := 0 TO db.numFields - 1 DO
        IF EqI(db.fields[j].name, areas[a].db.fields[i].name) THEN map[i] := j END
      END
    END;
    FOR r := 0 TO db.numRecs - 1 DO
      DBF.ReadRec(db, r, buf);
      IF ~(setDeleted & (buf[0] = "*")) THEN
        StartNewRec(a);
        FOR i := 0 TO areas[a].db.numFields - 1 DO
          j := map[i];
          IF j >= 0 THEN
            Sub(buf, srcOff[j], db.fields[j].len, raw);
            IF db.fields[j].type = "M" THEN
              IF areas[a].db.fields[i].type = "M" THEN
                IF StrInt(raw, n) THEN
                  DBF.MemoRead(memo, n, memoTxt); WriteMemo(a, i, memoTxt)
                END
              END
            ELSIF (db.fields[j].type = areas[a].db.fields[i].type) OR
                  (areas[a].db.fields[i].type = "C") THEN
              IF areas[a].db.fields[i].type = "C" THEN SetStr(v, raw)
              ELSE RawToVal(db.fields[j].type, db.fields[j].len, db.fields[j].dec, raw, v)
              END;
              PutFieldVal(a, i, v)
            ELSIF (areas[a].db.fields[i].type = "N") & (db.fields[j].type = "C") THEN
              RawToVal("N", 10, 0, raw, v); PutFieldVal(a, i, v)
            END;
            err := FALSE
          END
        END;
        IF ForOK(c.forN) THEN AppendBuf(a); INC(cnt) END;
        IF err THEN EXIT END
      END
    END;
    Files.Close(db.f)
  END;
  TalkCount(cnt, "added");
  IF ~err THEN GoBottom(a) END
END DoAppendFrom;

PROCEDURE DoInsertBlank(before: BOOLEAN);
VAR at, r, k: INTEGER; buf: ARRAY MaxRecBuf OF CHAR;
BEGIN
  IF ~NeedDb() THEN RETURN END;
  at := areas[cur].rec;
  IF at > areas[cur].db.numRecs THEN AppendBlank(cur); RETURN END;
  IF ~before THEN INC(at) END;
  (* shift records up one place *)
  DBF.ReadRec(areas[cur].db, areas[cur].db.numRecs - 1, buf);
  DBF.WriteRec(areas[cur].db, areas[cur].db.numRecs, buf);
  FOR r := areas[cur].db.numRecs - 2 TO at - 1 BY -1 DO
    DBF.ReadRec(areas[cur].db, r, buf);
    DBF.WriteRec(areas[cur].db, r + 1, buf)
  END;
  FOR k := 0 TO areas[cur].db.recordLen - 1 DO buf[k] := " " END;
  DBF.WriteRec(areas[cur].db, at - 1, buf);
  areas[cur].bufRec := -1;
  Reindex(cur);
  SetRec(cur, at)
END DoInsertBlank;

(* ---- TOTAL ---- *)

PROCEDURE TotalFlush(VAR db: DBF.Database; VAR flds: ARRAY OF DBF.Field; nf: INTEGER;
                     VAR tot: ARRAY OF BOOLEAN; VAR sum: ARRAY OF REAL; VAR buf: ARRAY OF CHAR);
VAR q, o, i: INTEGER; u: Str;
BEGIN
  o := 1;
  FOR q := 0 TO nf - 1 DO
    IF tot[q] THEN
      FmtNumW(RoundTo(sum[q], flds[q].dec), flds[q].len, flds[q].dec, u);
      FOR i := 0 TO flds[q].len - 1 DO buf[o + i] := u[i] END
    END;
    INC(o, flds[q].len)
  END;
  buf[0] := " ";
  DBF.WriteRec(db, db.numRecs, buf)
END TotalFlush;

PROCEDURE DoTotal;
VAR
  c: Clauses; el: ExprList; s: Scope; keyN: Node; name, path, key, prevKey, t: Str;
  flds: ARRAY DBF.MaxFields OF DBF.Field; map: ARRAY DBF.MaxFields OF INTEGER;
  sum: ARRAY DBF.MaxFields OF REAL; tot: ARRAY DBF.MaxFields OF BOOLEAN;
  nf, i, j, cnt, off: INTEGER; db: DBF.Database; buf: ARRAY MaxRecBuf OF CHAR;
  have: BOOLEAN; v: Value;


BEGIN
  IF ~NeedDb() THEN RETURN END;
  IF ~IsKw("ON") THEN Err("Syntax error."); RETURN END;
  Next; keyN := Expr();
  IF err THEN RETURN END;
  IF ~IsKw("TO") THEN Err("Syntax error."); RETURN END;
  Next; RawWord(name);
  ParseClauses(c, el, TRUE);
  IF err THEN RETURN END;
  nf := 0;
  FOR i := 0 TO areas[cur].db.numFields - 1 DO
    IF areas[cur].db.fields[i].type # "M" THEN
      flds[nf] := areas[cur].db.fields[i]; map[nf] := i;
      tot[nf] := FALSE;
      IF (flds[nf].type = "N") OR (flds[nf].type = "F") THEN
        IF el.n = 0 THEN tot[nf] := TRUE
        ELSE
          FOR j := 0 TO el.n - 1 DO
            IF (el.e[j].kind = nField) & (el.e[j].fld = i) THEN tot[nf] := TRUE END
          END
        END
      END;
      INC(nf)
    END
  END;
  NewPath(name, ".dbf", path);
  IF ~OkToOverwrite(path) THEN RETURN END;
  IF ~CreateDbf(path, flds, nf, db) THEN RETURN END;
  ScopeStart(s, c, scAll);
  have := FALSE; cnt := 0;
  WHILE ScopeOK(s) DO
    Eval(keyN, v); ValText(v, key);
    IF err THEN EXIT END;
    IF ~have OR ~Eq(key, prevKey) THEN
      IF have THEN TotalFlush(db, flds, nf, tot, sum, buf); INC(cnt) END;
      off := 1;
      FOR i := 0 TO nf - 1 DO
        GetRaw(cur, map[i], t);
        FOR j := 0 TO flds[i].len - 1 DO buf[off + j] := t[j] END;
        INC(off, flds[i].len);
        sum[i] := 0.0
      END;
      buf[off] := 0X;
      Cpy(key, prevKey); have := TRUE
    END;
    FOR i := 0 TO nf - 1 DO
      IF tot[i] THEN GetFieldVal(cur, map[i], v); sum[i] := sum[i] + v.n END
    END;
    ScopeAdvance(s)
  END;
  IF have THEN TotalFlush(db, flds, nf, tot, sum, buf); INC(cnt) END;
  DBF.Close(db);
  TalkCount(cnt, "generated")
END DoTotal;

(* ---- JOIN ---- *)

PROCEDURE DoJoin;
VAR
  other, nf, i, j, r1, cnt, off, f: INTEGER; name, path, t: Str; forN: Node;
  el: ExprList; fa, ff: ARRAY DBF.MaxFields OF INTEGER;
  flds: ARRAY DBF.MaxFields OF DBF.Field; db: DBF.Database;
  buf: ARRAY MaxRecBuf OF CHAR; dup: BOOLEAN;
BEGIN
  IF ~NeedDb() THEN RETURN END;
  IF ~IsKw("WITH") THEN Err("Syntax error."); RETURN END;
  Next; RawWord(name);
  other := AliasArea(name);
  IF (other < 0) OR ~areas[other].used THEN Err("ALIAS not found."); RETURN END;
  IF ~IsKw("TO") THEN Err("Syntax error."); RETURN END;
  Next; RawWord(name);
  forN := NIL; el.n := 0;
  WHILE (tk # tEOF) & ~err DO
    IF IsKw("FOR") THEN Next; forN := Expr()
    ELSIF IsKw("FIELDS") THEN Next; ParseExprList(el)
    ELSE Err("Unrecognized phrase/keyword in command.")
    END
  END;
  IF err THEN RETURN END;
  nf := 0;
  IF el.n > 0 THEN
    FOR i := 0 TO el.n - 1 DO
      IF el.e[i].kind # nField THEN Err("Field not found."); RETURN END;
      fa[nf] := el.e[i].area; ff[nf] := el.e[i].fld; INC(nf)
    END
  ELSE
    FOR i := 0 TO areas[cur].db.numFields - 1 DO
      IF areas[cur].db.fields[i].type # "M" THEN fa[nf] := cur; ff[nf] := i; INC(nf) END
    END;
    FOR i := 0 TO areas[other].db.numFields - 1 DO
      dup := FieldIdx(cur, areas[other].db.fields[i].name) >= 0;
      IF ~dup & (areas[other].db.fields[i].type # "M") & (nf < DBF.MaxFields) THEN
        fa[nf] := other; ff[nf] := i; INC(nf)
      END
    END
  END;
  FOR i := 0 TO nf - 1 DO flds[i] := areas[fa[i]].db.fields[ff[i]] END;
  NewPath(name, ".dbf", path);
  IF ~OkToOverwrite(path) THEN RETURN END;
  IF ~CreateDbf(path, flds, nf, db) THEN RETURN END;
  cnt := 0;
  GoTop(cur);
  WHILE ~areas[cur].eof & ~err DO
    r1 := areas[cur].rec;
    GoTop(other);
    WHILE ~areas[other].eof & ~err DO
      IF ForOK(forN) THEN
        buf[0] := " "; off := 1;
        FOR i := 0 TO nf - 1 DO
          f := ff[i];
          GetRaw(fa[i], f, t);
          FOR j := 0 TO flds[i].len - 1 DO buf[off + j] := t[j] END;
          INC(off, flds[i].len)
        END;
        buf[off] := 0X;
        DBF.WriteRec(db, db.numRecs, buf); INC(cnt)
      END;
      IF ~Step(other, 1) THEN END
    END;
    IF ~Step(cur, 1) THEN END
  END;
  DBF.Close(db);
  TalkCount(cnt, "joined")
END DoJoin;

(* ---- UPDATE ON key FROM alias REPLACE ... [RANDOM] ---- *)
PROCEDURE DoUpdate;
VAR
  from, kf, kfFrom, nf, i, cnt: INTEGER;
  savedTalk: BOOLEAN;
  name: Str; random, found: BOOLEAN;
  ff: ARRAY 32 OF INTEGER; fe: ARRAY 32 OF Node; v, kv, tv: Value;
BEGIN
  IF ~NeedDb() THEN RETURN END;
  IF ~IsKw("ON") THEN Err("Syntax error."); RETURN END;
  Next; Cpy(tkStr, name); Next;
  kf := FieldIdx(cur, name);
  IF kf < 0 THEN Err("Field not found."); RETURN END;
  IF ~IsKw("FROM") THEN Err("Syntax error."); RETURN END;
  Next;
  from := AliasArea(tkStr); Next;
  IF (from < 0) OR ~areas[from].used THEN Err("ALIAS not found."); RETURN END;
  kfFrom := FieldIdx(from, name);
  IF kfFrom < 0 THEN Err("Field not found."); RETURN END;
  IF ~IsKw("REPLACE") THEN Err("Syntax error."); RETURN END;
  Next; nf := 0; random := FALSE;
  WHILE (tk # tEOF) & ~err DO
    IF IsKw("RANDOM") THEN Next; random := TRUE
    ELSIF tk = tIdent THEN
      i := FieldIdx(cur, tkStr);
      IF i < 0 THEN Err("Field not found."); RETURN END;
      Next;
      IF ~IsKw("WITH") THEN Err("Syntax error."); RETURN END;
      Next;
      IF nf < 32 THEN ff[nf] := i; fe[nf] := Expr(); INC(nf) END;
      IF tk = tComma THEN Next END
    ELSE Err("Syntax error.")
    END
  END;
  IF err THEN RETURN END;
  cnt := 0;
  (* Suppress talk ONCE for the whole loop *)
  savedTalk := setTalk;
  setTalk := FALSE;
  GoTop(from);
  WHILE ~areas[from].eof & ~err DO
    GetFieldVal(from, kfFrom, kv);
    found := FALSE;
    IF areas[cur].order > 0 THEN
      SeekValue(kv);
      found := areas[cur].found
    ELSE
      GoTop(cur);
      WHILE ~areas[cur].eof & ~found DO
        GetFieldVal(cur, kf, tv);
        IF (tv.t = kv.t) & (((tv.t = TC) & Eq(tv.s, kv.s)) OR ((tv.t = TN) & (tv.n = kv.n)) OR
           ((tv.t = TD) & (tv.d = kv.d))) THEN found := TRUE
        ELSIF ~Step(cur, 1) THEN
        END
      END
    END;
    IF found THEN
      BeginChange(cur);
      FOR i := 0 TO nf - 1 DO
        Eval(fe[i], v);
        IF ~err THEN PutFieldVal(cur, ff[i], v) END
      END;
      EndChange(cur);
      INC(cnt)
    END;
    IF ~Step(from, 1) THEN END
  END;
  (* Restore talk ONCE at the end, regardless of how we exited *)
  setTalk := savedTalk;
  TalkCount(cnt, "updated");
  GoTop(cur)
END DoUpdate;

(* setTalkSave is no longer needed, but leave it in case other
   code calls it.  It can be safely removed if nothing else uses it. *)
(* turn TALK off temporarily; returns 1 if it was on *)
PROCEDURE setTalkSave(): INTEGER;
VAR r: INTEGER;
BEGIN
  IF setTalk THEN r := 1 ELSE r := 0 END;
  setTalk := FALSE;
  RETURN r
END setTalkSave;

(* ====================================================================
   Miscellaneous commands
   ==================================================================== *)

(* SET FIXED ON: calculated numbers show SET DECIMALS places *)
PROCEDURE ApplyFixed(n: Node; VAR v: Value);
BEGIN
  IF setFixed & (v.t = TN) & (n.kind # nField) THEN v.dec := setDecimals END
END ApplyFixed;

PROCEDURE DoQuestion(newLine: BOOLEAN);
VAR n: Node; v: Value; items: ARRAY MaxExprs OF Str; ni, i: INTEGER;
BEGIN
  (* evaluate the whole list first: an error prints nothing *)
  ni := 0;
  WHILE (tk # tEOF) & ~err DO
    n := Expr();
    IF err THEN RETURN END;
    Eval(n, v);
    IF err THEN RETURN END;
    ApplyFixed(n, v);
    IF ni < MaxExprs THEN ValStr(v, items[ni]); INC(ni) END;
    IF tk = tComma THEN Next ELSIF tk # tEOF THEN Err("Syntax error."); RETURN END
  END;
  IF newLine THEN OutNL END;
  FOR i := 0 TO ni - 1 DO
    IF i > 0 THEN OutStr(" ") END;
    OutStr(items[i])
  END
END DoQuestion;

PROCEDURE DoUse;
VAR name, path, alias, t: Str; idx: ARRAY MaxIdx OF Str; ni, i: INTEGER;
BEGIN
  IF tk = tEOF THEN CloseArea(cur); RETURN END;
  IF (tk = tOther) & (tkStr[0] = "?") THEN
    Next;
    IF ~PickFile(".dbf", name) THEN RETURN END
  ELSE RawWord(name)
  END;
  ni := 0; alias[0] := 0X;
  WHILE (tk # tEOF) & ~err DO
    IF IsKw("INDEX") THEN
      Next;
      LOOP
        RawWord(t);
        IF (t[0] # 0X) & (ni < MaxIdx) THEN Cpy(t, idx[ni]); INC(ni) END;
        IF tk = tComma THEN Next ELSE EXIT END
      END
    ELSIF IsKw("ALIAS") THEN Next; RawWord(alias)
    ELSIF IsKw("EXCLUSIVE") THEN Next
    ELSE Err("Unrecognized phrase/keyword in command.")
    END
  END;
  IF err THEN RETURN END;
  IF ~FindFile(name, ".dbf", path) THEN Err("File does not exist."); RETURN END;
  FOR i := 0 TO MaxAreas - 1 DO
    IF (i # cur) & areas[i].used & EqI(areas[i].fname, path) THEN Err("File is already open."); RETURN END
  END;
  IF alias[0] # 0X THEN
    i := AliasArea(alias);
    IF (i >= 0) & (i # cur) & areas[i].used THEN Err("ALIAS name already in use."); RETURN END
  END;
  IF ~OpenArea(cur, path, alias) THEN RETURN END;
  FOR i := 0 TO ni - 1 DO
    IF ~err THEN IF OpenIndex(cur, idx[i]) THEN END END
  END;
  IF ~err THEN GoTop(cur) END
END DoUse;

PROCEDURE DoSelect;
VAR name: Str; a: INTEGER; n: Node;
BEGIN
  IF tk = tNum THEN a := FLOOR(tkNum) - 1; Next
  ELSIF tk = tIdent THEN Cpy(tkStr, name); Next; a := AliasArea(name)
  ELSE n := Expr(); a := EvalInt(n) - 1
  END;
  IF (a < 0) OR (a >= MaxAreas) THEN Err("ALIAS not found."); RETURN END;
  cur := a
END DoSelect;

PROCEDURE DoStore;
VAR n: Node; v: Value; name: Str;
BEGIN
  n := Expr();
  IF err THEN RETURN END;
  IF ~IsKw("TO") THEN Err("Syntax error."); RETURN END;
  Next;
  Eval(n, v);
  IF err THEN RETURN END;
  WHILE tk = tIdent DO
    Cpy(tkStr, name); Next;
    StoreVar(name, v);
    IF tk = tComma THEN Next END
  END
END DoStore;

PROCEDURE DoAssign(name: ARRAY OF CHAR);
VAR n: Node; v: Value;
BEGIN
  Next;  (* past = *)
  n := Expr();
  IF ~err & (tk # tEOF) THEN Err("Syntax error.") END;
  IF err THEN RETURN END;
  Eval(n, v);
  IF ~err THEN StoreVar(name, v) END
END DoAssign;

(* RELEASE <list> | ALL [LIKE|EXCEPT <skel>] -- also used by CLEAR MEMORY *)
PROCEDURE DoRelease;
VAR i: INTEGER; skel: Str; like, except, all: BOOLEAN;
BEGIN
  all := FALSE; like := FALSE; except := FALSE; skel[0] := 0X;
  IF IsKw("MODULE") THEN Next; RawRest(skel); Err("Binary (.BIN) modules are not supported."); RETURN END;
  IF IsKw("ALL") THEN
    Next; all := TRUE;
    IF IsKw("LIKE") THEN Next; like := TRUE; RawWord(skel)
    ELSIF IsKw("EXCEPT") THEN Next; except := TRUE; RawWord(skel)
    END;
    i := nVars - 1;
    WHILE i >= 0 DO
      IF ((depth = 0) OR (vars[i].level = depth)) &
         (~like OR WildMatch(skel, vars[i].name, 0, 0)) &
         (~except OR ~WildMatch(skel, vars[i].name, 0, 0)) THEN ReleaseVar(i) END;
      DEC(i)
    END
  ELSE
    WHILE tk = tIdent DO
      i := FindVar(tkStr);
      IF i >= 0 THEN ReleaseVar(i) END;
      Next;
      IF tk = tComma THEN Next END
    END
  END
END DoRelease;

PROCEDURE DoSaveMem;
VAR name, path, skel, line, t: Str; f: Files.File; r: Files.Rider; i: INTEGER;
  like, except: BOOLEAN;
BEGIN
  IF ~IsKw("TO") THEN Err("Syntax error."); RETURN END;
  Next; RawWord(name);
  like := FALSE; except := FALSE;
  IF IsKw("ALL") THEN
    Next;
    IF IsKw("LIKE") THEN Next; like := TRUE; RawWord(skel)
    ELSIF IsKw("EXCEPT") THEN Next; except := TRUE; RawWord(skel)
    END
  END;
  NewPath(name, ".mem", path);
  f := Files.New(path);
  IF f = NIL THEN Err("Unable to create file."); RETURN END;
  Files.Set(r, f, 0);
  WriteStr(r, "OBBASE MEMORY 1"); Files.Write(r, 10);
  FOR i := 0 TO nVars - 1 DO
    IF (~like OR WildMatch(skel, vars[i].name, 0, 0)) & (~except OR ~WildMatch(skel, vars[i].name, 0, 0)) THEN
      Cpy(vars[i].name, line); AppendCh("|", line); AppendCh(vars[i].v.t, line); AppendCh("|", line);
      CASE vars[i].v.t OF
        "C": Append(vars[i].v.s, line)
      | "N": FmtFixed(vars[i].v.n, 12, t); Append(t, line); AppendCh("|", line); AppendInt(vars[i].v.dec, line)
      | "L": IF vars[i].v.b THEN Append("T", line) ELSE Append("F", line) END
      | "D": AppendInt(vars[i].v.d, line)
      ELSE
      END;
      WriteStr(r, line); Files.Write(r, 10)
    END
  END;
  Files.Register(f); Files.Close(f)
END DoSaveMem;

PROCEDURE DoRestoreMem;
VAR name, path, line, nm, ty, val, dec: Str; f: Files.File; r: Files.Rider;
  v: Value; x: REAL; d, k: INTEGER;
BEGIN
  IF ~IsKw("FROM") THEN Err("Syntax error."); RETURN END;
  Next; RawWord(name);
  IF ~FindFile(name, ".mem", path) THEN Err("File does not exist."); RETURN END;
  IF ~IsKw("ADDITIVE") THEN
    k := nVars - 1;
    WHILE k >= 0 DO IF (depth = 0) OR (vars[k].level = depth) THEN ReleaseVar(k) END; DEC(k) END
  END;
  f := Files.Old(path); Files.Set(r, f, 0);
  Files.ReadLine(r, line);
  LOOP
    Files.ReadLine(r, line);
    IF r.eof & (line[0] = 0X) THEN EXIT END;
    IF Strings.Split(line, "|", 0, nm) & Strings.Split(line, "|", 1, ty) THEN
      k := SLen(nm) + SLen(ty) + 2;
      Sub(line, k, 255, val);
      CASE ty[0] OF
        "C": SetStr(v, val)
      | "N":
          IF Strings.Split(line, "|", 2, val) THEN ScanNum(val, x, d) ELSE x := 0.0 END;
          d := 0; IF Strings.Split(line, "|", 3, dec) THEN IF StrInt(dec, d) THEN END END;
          SetNum(v, x, 10, d)
      | "L": SetBool(v, val[0] = "T")
      | "D": IF StrInt(val, d) THEN SetDate(v, d) ELSE SetDate(v, 0) END
      ELSE v.t := TU
      END;
      IF v.t # TU THEN StoreVar(nm, v) END
    END;
    IF r.eof THEN EXIT END
  END;
  Files.Close(f)
END DoRestoreMem;

PROCEDURE DoType;
VAR name, path, line: Str; f: Files.File; r: Files.Rider; c: Clauses; n: INTEGER;
BEGIN
  RawWord(name);
  InitClauses(c);
  IF IsKw("TO") THEN Next; IF IsKw("PRINT") THEN Next; c.toPrint := TRUE END END;
  IF ~FindFile(name, "", path) THEN Err("File does not exist."); RETURN END;
  f := Files.Old(path); Files.Set(r, f, 0);
  IF ~BeginTo(c) THEN RETURN END;
  LOOP
    Files.ReadLine(r, line);
    IF r.eof & (line[0] = 0X) THEN EXIT END;
    n := SLen(line); IF (n > 0) & (line[n - 1] = 0DX) THEN line[n - 1] := 0X END;
    IF line[0] = 1AX THEN EXIT END;
    Line(line);
    IF r.eof OR interrupted THEN EXIT END;
    IF EscPressed() THEN interrupted := TRUE END
  END;
  Files.Close(f);
  EndTo
END DoType;

PROCEDURE DoErase;
VAR name, path: Str;
BEGIN
  IF (tk = tOther) & (tkStr[0] = "?") THEN Next; IF ~PickFile("", name) THEN RETURN END
  ELSE RawWord(name)
  END;
  IF ~FindFile(name, "", path) THEN Err("File does not exist."); RETURN END;
  Files.Delete(path);
  Talk("File has been deleted.")
END DoErase;

PROCEDURE DoRename;
VAR a, b, pa, pb: Str;
BEGIN
  RawWord(a);
  IF ~IsKw("TO") THEN Err("Syntax error."); RETURN END;
  Next; RawWord(b);
  IF ~FindFile(a, "", pa) THEN Err("File does not exist."); RETURN END;
  StripDrive(b); WithDir(b, pb);
  IF Files.Exists(pb) THEN Err("File already exists."); RETURN END;
  Files.Rename(pa, pb)
END DoRename;

PROCEDURE DoRun(cmd: ARRAY OF CHAR);
VAR rc: INTEGER; k: CHAR;
BEGIN
  IF batch THEN rc := OS.Exec(cmd); RETURN END;
  TUI.Suspend;
  Out.Ln;
  rc := OS.Exec(cmd);
  Out.String("Press any key to continue..."); Out.Flush;
  TUI.Resume;
  k := GetKey();
  TUI.InvalidateFront
END DoRun;

PROCEDURE DoWait;
VAR prompt, vname: Str; n: Node; v: Value; k: CHAR;
BEGIN
  Cpy("Press any key to continue...", prompt); vname[0] := 0X;
  IF (tk # tEOF) & ~IsKw("TO") THEN n := Expr(); EvalStr(n, prompt) END;
  IF IsKw("TO") THEN Next; Cpy(tkStr, vname); Next END;
  IF err THEN RETURN END;
  k := WaitKeyMsg(prompt);
  IF vname[0] # 0X THEN
    IF (k >= " ") & (k < 7FX) THEN v.s[0] := k; v.s[1] := 0X ELSE v.s[0] := 0X END;
    v.t := TC; StoreVar(vname, v)
  END;
  IF k = TUI.KEsc THEN interrupted := setEscape END
END DoWait;

PROCEDURE DoAcceptInput(isInput: BOOLEAN);
VAR prompt, vname, s: Str; n: Node; v: Value;
BEGIN
  prompt[0] := 0X;
  IF ~IsKw("TO") THEN n := Expr(); EvalStr(n, prompt) END;
  IF err THEN RETURN END;
  IF ~IsKw("TO") THEN Err("Syntax error."); RETURN END;
  Next; Cpy(tkStr, vname); Next;
  LOOP
    ConNL; s[0] := 0X;
    IF ~ReadLine(prompt, s, 254, FALSE) THEN
      IF setEscape THEN interrupted := TRUE; RETURN END
    END;
    IF ~isInput THEN SetStr(v, s); EXIT END;
    IF s[0] # 0X THEN
      EvalString(s, v);
      IF ~err THEN EXIT END;
      err := FALSE
    END
  END;
  StoreVar(vname, v)
END DoAcceptInput;

PROCEDURE DoClose;
BEGIN
  IF IsKw("ALL") THEN CloseAll; CloseProcedure; CloseAlternate
  ELSIF IsKw("DATABASES") THEN CloseAll
  ELSIF IsKw("INDEX") THEN IF areas[cur].used THEN CloseIndexes(cur) END
  ELSIF IsKw("ALTERNATE") THEN CloseAlternate
  ELSIF IsKw("PROCEDURE") THEN CloseProcedure
  ELSIF IsKw("FORMAT") THEN
  ELSE Err("Syntax error.")
  END;
  Next
END DoClose;

PROCEDURE CloseAlternate;
BEGIN
  IF altF # NIL THEN Files.Register(altF); Files.Close(altF); altF := NIL END;
  setAlternate := FALSE
END CloseAlternate;

PROCEDURE DoClear;
VAR k: INTEGER;
BEGIN
  IF IsKw("ALL") THEN
    CloseAll; nVars := 0; nGets := 0; CloseProcedure
  ELSIF IsKw("MEMORY") THEN
    k := nVars - 1;
    WHILE k >= 0 DO IF (depth = 0) OR (vars[k].level = depth) THEN ReleaseVar(k) END; DEC(k) END
  ELSIF IsKw("GETS") THEN nGets := 0
  ELSIF IsKw("TYPEAHEAD") THEN taN := 0
  ELSE ConClear; nGets := 0
  END
END DoClear;

(* ---- ON ERROR / ON ESCAPE / ON KEY <command> ---- *)

PROCEDURE DoOn;
VAR which: INTEGER; t: Str;
BEGIN
  IF IsKw("ERROR") THEN which := 0
  ELSIF IsKw("ESCAPE") THEN which := 1
  ELSIF IsKw("KEY") THEN which := 2
  ELSE Err("Syntax error."); RETURN
  END;
  Next;
  (* the rest of the line is the command; no command turns the trap off *)
  IF tk = tEOF THEN t[0] := 0X ELSE RawRest(t) END;
  CASE which OF
    0: Cpy(t, onErrCmd)
  | 1: Cpy(t, onEscCmd)
  | 2: Cpy(t, onKeyCmd)
  END
END DoOn;

(* ---- SET ---- *)

(* one color letter group (N B G BG R RB GR W, + bright) -> TUI color; -1 if none *)
PROCEDURE ColorOf(s: ARRAY OF CHAR): INTEGER;
VAR i, c: INTEGER; bright: BOOLEAN; t: Str;
BEGIN
  t[0] := 0X; bright := FALSE;
  FOR i := 0 TO SLen(s) - 1 DO
    IF s[i] = "+" THEN bright := TRUE
    ELSIF IsAlpha(s[i]) THEN AppendCh(UpCh(s[i]), t)
    END
  END;
  IF Eq(t, "N") OR Eq(t, "X") THEN c := TUI.Black
  ELSIF Eq(t, "B") OR Eq(t, "U") THEN c := TUI.Blue
  ELSIF Eq(t, "G") THEN c := TUI.Green
  ELSIF Eq(t, "BG") OR Eq(t, "GB") THEN c := TUI.Cyan
  ELSIF Eq(t, "R") THEN c := TUI.Red
  ELSIF Eq(t, "RB") OR Eq(t, "BR") THEN c := TUI.Magenta
  ELSIF Eq(t, "GR") OR Eq(t, "RG") THEN c := TUI.Yellow
  ELSIF Eq(t, "W") THEN c := TUI.White
  ELSIF Eq(t, "I") THEN c := -2   (* inverse *)
  ELSE RETURN -1
  END;
  IF bright & (c >= 0) THEN INC(c, 8) END;
  RETURN c
END ColorOf;

(* "fg/bg" -> colors; FALSE if it does not parse *)
PROCEDURE ColorPair(s: ARRAY OF CHAR; VAR fg, bg: INTEGER): BOOLEAN;
VAR a, b: Str; k: INTEGER;
BEGIN
  Trim(s);
  IF s[0] = 0X THEN RETURN FALSE END;
  k := Strings.Pos("/", s, 0);
  IF k < 0 THEN Cpy(s, a); b[0] := 0X ELSE Sub(s, 0, k, a); Sub(s, k + 1, 255, b) END;
  fg := ColorOf(a);
  IF b[0] = 0X THEN bg := cBg ELSE bg := ColorOf(b) END;
  IF fg = -2 THEN fg := cBg; bg := cFg END;
  RETURN (fg >= 0) & (bg >= 0)
END ColorPair;

(* SET COLOR TO [<standard>][,<enhanced>][,<border>]; empty resets *)
PROCEDURE SetColors(spec: ARRAY OF CHAR);
VAR part: Str; vp, fg, bg: INTEGER;
BEGIN
  IF spec[0] = 0X THEN
    cFg := TUI.White; cBg := TUI.Black; cRevFg := TUI.Black; cRevBg := TUI.White; cHiFg := TUI.BrightWhite
  ELSE
    vp := 0;
    IF Strings.Split(spec, ",", vp, part) & ColorPair(part, fg, bg) THEN
      cFg := fg; cBg := bg;
      IF fg < 8 THEN cHiFg := fg + 8 ELSE cHiFg := fg END
    END;
    INC(vp);
    IF Strings.Split(spec, ",", vp, part) & ColorPair(part, fg, bg) THEN cRevFg := fg; cRevBg := bg END
  END;
  IF ~batch THEN TUI.InvalidateFront END
END SetColors;

PROCEDURE OnOffArg(VAR b: BOOLEAN);
BEGIN
  IF IsKw("ON") THEN b := TRUE; Next
  ELSIF IsKw("OFF") THEN b := FALSE; Next
  ELSE Err("Syntax error.")
  END
END OnOffArg;

PROCEDURE NumArg(): INTEGER;
VAR n: Node;
BEGIN
  IF IsKw("TO") THEN Next END;
  n := Expr();
  RETURN EvalInt(n)
END NumArg;

PROCEDURE SetFilter(a: INTEGER; txt: ARRAY OF CHAR);
VAR save: INTEGER; n: Node;
BEGIN
  IF txt[0] = 0X THEN areas[a].filter := NIL; areas[a].filterTxt[0] := 0X; RETURN END;
  save := cur; cur := a;
  n := CompileStr(txt);
  cur := save;
  IF err THEN RETURN END;
  areas[a].filter := n; Cpy(txt, areas[a].filterTxt)
END SetFilter;

(* FILTER= line of a .QRY file *)
PROCEDURE ReadQueryFilter(name: ARRAY OF CHAR; VAR txt: ARRAY OF CHAR): BOOLEAN;
VAR path, line: Str; f: Files.File; r: Files.Rider;
BEGIN
  txt[0] := 0X;
  IF ~FindFile(name, ".qry", path) THEN Err("File does not exist."); RETURN FALSE END;
  f := Files.Old(path); Files.Set(r, f, 0);
  LOOP
    Files.ReadLine(r, line);
    IF StartsI(line, "FILTER=") THEN Sub(line, 7, 255, txt) END;
    IF r.eof THEN EXIT END
  END;
  Files.Close(f);
  RETURN TRUE
END ReadQueryFilter;

PROCEDURE DoSet;
VAR opt, t, path: Str; n: Node; v: Value; k, a: INTEGER; b: BOOLEAN;
BEGIN
  IF tk = tEOF THEN ListStatus; RETURN END;
  Cpy(tkStr, opt); Next;
  IF Kw(opt, "TALK") THEN OnOffArg(setTalk)
  ELSIF Kw(opt, "HEADINGS") THEN OnOffArg(setHeadings)
  ELSIF Kw(opt, "DELETED") THEN OnOffArg(setDeleted)
  ELSIF Kw(opt, "EXACT") THEN OnOffArg(setExact)
  ELSIF Kw(opt, "SAFETY") THEN OnOffArg(setSafety)
  ELSIF Kw(opt, "CONFIRM") THEN OnOffArg(setConfirm)
  ELSIF Kw(opt, "BELL") THEN OnOffArg(setBell)
  ELSIF Kw(opt, "STATUS") THEN OnOffArg(setStatus); ScreenSize
  ELSIF Kw(opt, "MENUS") OR Kw(opt, "MENU") THEN OnOffArg(setMenu)
  ELSIF Kw(opt, "CONSOLE") THEN OnOffArg(setConsole)
  ELSIF Kw(opt, "CENTURY") THEN OnOffArg(setCentury)
  ELSIF Kw(opt, "UNIQUE") THEN OnOffArg(setUnique)
  ELSIF Kw(opt, "CARRY") THEN OnOffArg(setCarry)
  ELSIF Kw(opt, "INTENSITY") THEN OnOffArg(setIntensity)
  ELSIF Kw(opt, "HELP") THEN OnOffArg(setHelp)
  ELSIF Kw(opt, "ESCAPE") THEN OnOffArg(setEscape)
  ELSIF Kw(opt, "ECHO") THEN OnOffArg(setEcho)
  ELSIF Kw(opt, "FIXED") THEN OnOffArg(setFixed)
  ELSIF Kw(opt, "STEP") OR Kw(opt, "DEBUG") OR Kw(opt, "SCOREBOARD") OR Kw(opt, "DOHISTORY")
     OR Kw(opt, "FORMAT") OR Kw(opt, "CATALOG") OR Kw(opt, "TYPEAHEAD")
     OR Kw(opt, "EXCLUSIVE") OR Kw(opt, "ENCRYPTION") OR Kw(opt, "TITLE") THEN
    RawRest(t)
  ELSIF Kw(opt, "COLOR") OR Kw(opt, "COLOUR") THEN
    IF IsKw("TO") THEN Next; RawRest(t); SetColors(t)
    ELSE OnOffArg(b)
    END
  ELSIF Kw(opt, "MESSAGE") THEN
    IF IsKw("TO") THEN Next END;
    IF tk = tEOF THEN userMsg[0] := 0X ELSE n := Expr(); EvalStr(n, userMsg) END;
    IF ~err THEN SetMsg(userMsg) END
  ELSIF Kw(opt, "PRINT") THEN
    OnOffArg(setPrint);
    IF ~setPrint & (prnF # NIL) THEN Files.Register(prnF) END
  ELSIF Kw(opt, "DELIMITERS") THEN
    IF IsKw("TO") THEN
      Next;
      IF IsKw("DEFAULT") THEN Next; delimL := ":"; delimR := ":"
      ELSE
        n := Expr(); EvalStr(n, t);
        IF ~err THEN
          IF t[0] = 0X THEN delimL := " "; delimR := " "
          ELSE delimL := t[0]; IF t[1] # 0X THEN delimR := t[1] ELSE delimR := t[0] END
          END
        END
      END
    ELSE OnOffArg(setDelimiters)
    END
  ELSIF Kw(opt, "HISTORY") THEN
    IF IsKw("TO") THEN setHistory := NumArg()
    ELSE OnOffArg(b); IF b THEN setHistory := MaxCmdHist ELSE setHistory := 0 END
    END
  ELSIF Kw(opt, "ALTERNATE") THEN
    IF IsKw("TO") THEN
      Next; CloseAlternate;
      IF tk # tEOF THEN
        RawWord(t); NewPath(t, ".txt", path);
        IF IsKw("ADDITIVE") THEN Next; OpenAppend(path, altF, altR)
        ELSE altF := Files.New(path); IF altF # NIL THEN Files.Set(altR, altF, 0) END
        END;
        Cpy(path, altName)
      END
    ELSE OnOffArg(setAlternate)
    END
  ELSIF Kw(opt, "FIELDS") THEN
    IF IsKw("TO") THEN
      Next;
      IF IsKw("ALL") THEN
        Next; nFieldList := 0;
        IF NeedDb() THEN
          FOR k := 0 TO areas[cur].db.numFields - 1 DO
            fieldList[k].area := cur; fieldList[k].fld := k
          END;
          nFieldList := areas[cur].db.numFields
        END
      ELSIF tk = tEOF THEN nFieldList := 0
      ELSE
        WHILE (tk # tEOF) & ~err DO
          n := Expr();
          IF ~err THEN
            IF (n.kind # nField) THEN Err("Field not found.")
            ELSIF nFieldList < DBF.MaxFields THEN
              fieldList[nFieldList].area := n.area; fieldList[nFieldList].fld := n.fld; INC(nFieldList)
            END
          END;
          IF tk = tComma THEN Next END
        END
      END;
      setFieldsOn := nFieldList > 0
    ELSE OnOffArg(setFieldsOn)
    END
  ELSIF Kw(opt, "DATE") THEN
    IF IsKw("TO") THEN Next END;
    IF IsKw("AMERICAN") THEN setDateFmt := 0 ELSIF IsKw("ANSI") THEN setDateFmt := 1
    ELSIF IsKw("BRITISH") THEN setDateFmt := 2 ELSIF IsKw("ITALIAN") THEN setDateFmt := 3
    ELSIF IsKw("FRENCH") THEN setDateFmt := 4 ELSIF IsKw("GERMAN") THEN setDateFmt := 5
    ELSE Err("Syntax error.")
    END;
    Next
  ELSIF Kw(opt, "DECIMALS") THEN setDecimals := NumArg()
  ELSIF Kw(opt, "MARGIN") THEN setMargin := NumArg()
  ELSIF Kw(opt, "MEMOWIDTH") THEN setMemoWidth := MinI(MaxI(NumArg(), 8), 250)
  ELSIF Kw(opt, "DEFAULT") THEN
    IF IsKw("TO") THEN Next END;
    RawWord(t);
    IF IsAlpha(t[0]) & (t[1] = ":") THEN defDrive := UpCh(t[0]); StripDrive(t) END;
    IF t[0] # 0X THEN Cpy(t, defDir) END
  ELSIF Kw(opt, "PATH") THEN
    IF IsKw("TO") THEN Next END;
    RawRest(pathDirs)
  ELSIF Kw(opt, "PRINTER") THEN
    IF IsKw("TO") THEN
      Next; RawWord(t);
      IF prnF # NIL THEN Files.Register(prnF); Files.Close(prnF); prnF := NIL END;
      IF t[0] # 0X THEN NewPath(t, ".prn", prnName) ELSE Cpy("obbase.prn", prnName) END
    ELSE RawRest(t)
    END
  ELSIF Kw(opt, "DEVICE") THEN
    IF IsKw("TO") THEN Next END;
    IF IsKw("PRINT") OR IsKw("PRINTER") THEN setDevPrint := TRUE ELSE setDevPrint := FALSE END;
    Next
  ELSIF Kw(opt, "FUNCTION") THEN
    n := Expr(); Eval(n, v);
    IF err THEN RETURN END;
    IF v.t = TN THEN k := FLOOR(v.n) - 1
    ELSE Cpy(v.s, t); Upper(t); IF t[0] = "F" THEN t[0] := " " END; IF StrInt(t, k) THEN DEC(k) ELSE k := -1 END
    END;
    IF ~IsKw("TO") THEN Err("Syntax error."); RETURN END;
    Next; n := Expr(); EvalStr(n, t);
    IF (k >= 1) & (k <= 9) & ~err THEN Cpy(t, fkeys[k]) ELSIF ~err THEN Err("Invalid function key.") END
  ELSIF Kw(opt, "FILTER") THEN
    IF ~NeedDb() THEN RETURN END;
    IF IsKw("TO") THEN Next END;
    IF IsKw("FILE") THEN
      Next; RawWord(t);
      IF ReadQueryFilter(t, path) THEN SetFilter(cur, path) END
    ELSE RawRest(t); SetFilter(cur, t)
    END
  ELSIF Kw(opt, "INDEX") THEN
    IF IsKw("TO") THEN Next END;
    DoSetIndex
  ELSIF Kw(opt, "ORDER") THEN
    IF ~NeedDb() THEN RETURN END;
    k := NumArg();
    IF ~err THEN
      IF (k < 0) OR (k > areas[cur].nIdx) THEN Err("Invalid index number.") ELSE areas[cur].order := k END
    END
  ELSIF Kw(opt, "RELATION") THEN
    IF ~NeedDb() THEN RETURN END;
    IF IsKw("TO") THEN Next END;
    IF tk = tEOF THEN
      areas[cur].relArea := -1; areas[cur].relExpr := NIL; areas[cur].relTxt[0] := 0X; RETURN
    END;
    k := tkStart;
    n := Expr();
    IF err THEN RETURN END;
    SrcText(k, tkStart, t);
    IF ~IsKw("INTO") THEN Err("Syntax error."); RETURN END;
    Next; a := AliasArea(tkStr); Next;
    IF (a < 0) OR ~areas[a].used OR (a = cur) THEN Err("ALIAS not found."); RETURN END;
    areas[cur].relArea := a; areas[cur].relExpr := n; Cpy(t, areas[cur].relTxt);
    SyncRel(cur)
  ELSIF Kw(opt, "PROCEDURE") THEN
    IF IsKw("TO") THEN Next END;
    IF tk = tEOF THEN CloseProcedure ELSE RawWord(t); OpenProcedure(t) END
  ELSIF Kw(opt, "VIEW") THEN
    IF IsKw("TO") THEN Next END;
    RawWord(t); SetView(t)
  ELSE
    Err("Unrecognized phrase/keyword in command.")
  END
END DoSet;

(* ---- views (.VUE): the environment saved as commands ---- *)

PROCEDURE DoCreateViewEnv(name: ARRAY OF CHAR);
VAR path, line, t: Str; f: Files.File; r: Files.Rider; a, k: INTEGER;
BEGIN
  NewPath(name, ".vue", path);
  IF ~OkToOverwrite(path) THEN RETURN END;
  f := Files.New(path);
  IF f = NIL THEN Err("Unable to create file."); RETURN END;
  Files.Set(r, f, 0);
  WriteStr(r, "* OBBASE VIEW 1"); Files.Write(r, 10);
  WriteStr(r, "CLOSE DATABASES"); Files.Write(r, 10);
  FOR a := 0 TO MaxAreas - 1 DO
    IF areas[a].used THEN
      Cpy("SELECT ", line); AppendInt(a + 1, line); WriteStr(r, line); Files.Write(r, 10);
      Cpy("USE ", line); Append(areas[a].fname, line);
      IF areas[a].nIdx > 0 THEN
        Append(" INDEX ", line);
        FOR k := 0 TO areas[a].nIdx - 1 DO
          IF k > 0 THEN Append(",", line) END;
          Append(areas[a].idx[k].fname, line)
        END
      END;
      Append(" ALIAS ", line); Append(areas[a].alias, line);
      WriteStr(r, line); Files.Write(r, 10);
      IF areas[a].filterTxt[0] # 0X THEN
        Cpy("SET FILTER TO ", line); Append(areas[a].filterTxt, line); WriteStr(r, line); Files.Write(r, 10)
      END
    END
  END;
  FOR a := 0 TO MaxAreas - 1 DO
    IF areas[a].used & (areas[a].relArea >= 0) THEN
      Cpy("SELECT ", line); AppendInt(a + 1, line); WriteStr(r, line); Files.Write(r, 10);
      Cpy("SET RELATION TO ", line); Append(areas[a].relTxt, line); Append(" INTO ", line);
      Append(areas[areas[a].relArea].alias, line); WriteStr(r, line); Files.Write(r, 10)
    END
  END;
  IF setFieldsOn & (nFieldList > 0) THEN
    Cpy("SET FIELDS TO ", line);
    FOR k := 0 TO nFieldList - 1 DO
      IF k > 0 THEN Append(",", line) END;
      Cpy(areas[fieldList[k].area].alias, t); Append("->", t);
      Append(areas[fieldList[k].area].db.fields[fieldList[k].fld].name, t);
      Append(t, line)
    END;
    WriteStr(r, line); Files.Write(r, 10)
  END;
  Cpy("SELECT ", line); AppendInt(cur + 1, line); WriteStr(r, line); Files.Write(r, 10);
  Files.Register(f); Files.Close(f)
END DoCreateViewEnv;

PROCEDURE SetView(name: ARRAY OF CHAR);
VAR path, line: Str; f: Files.File; r: Files.Rider; lines: TextBuf; i: INTEGER;
BEGIN
  IF ~FindFile(name, ".vue", path) THEN Err("File does not exist."); RETURN END;
  NEW(lines); lines.n := 0;
  f := Files.Old(path); Files.Set(r, f, 0);
  LOOP
    Files.ReadLine(r, line);
    IF r.eof & (line[0] = 0X) THEN EXIT END;
    IF lines.n < MaxTxtLn THEN Cpy(line, lines.l[lines.n]); INC(lines.n) END;
    IF r.eof THEN EXIT END
  END;
  Files.Close(f);
  FOR i := 0 TO lines.n - 1 DO
    IF ~err THEN ExecLine(lines.l[i]) END
  END
END SetView;

(* ====================================================================
   Line preprocessing and dispatch
   ==================================================================== *)

PROCEDURE StripComment(VAR s: ARRAY OF CHAR);
VAR i: INTEGER; q: CHAR;
BEGIN
  i := 0; q := 0X;
  WHILE s[i] # 0X DO
    IF q # 0X THEN
      IF s[i] = q THEN q := 0X END
    ELSIF (s[i] = "'") OR (s[i] = '"') THEN q := s[i]
    ELSIF (s[i] = "&") & (s[i + 1] = "&") THEN s[i] := 0X; RETURN
    END;
    INC(i)
  END
END StripComment;

(* &memvar macro substitution *)
PROCEDURE ExpandMacros(VAR s: ARRAY OF CHAR);
VAR i, j, k, guard: INTEGER; name: Str; out: Str;
BEGIN
  guard := 0;
  i := 0;
  WHILE (s[i] # 0X) & (guard < 50) DO
    IF (s[i] = "&") & IsAlpha(s[i + 1]) THEN
      j := i + 1; name[0] := 0X;
      WHILE IsIdCh(s[j]) DO AppendCh(s[j], name); INC(j) END;
      k := FindVar(name);
      IF (k >= 0) & (vars[k].v.t = TC) THEN
        IF s[j] = "." THEN INC(j) END;
        Sub(s, 0, i, out); Append(vars[k].v.s, out);
        Sub(s, j, 255, name); Append(name, out);
        Cpy(out, s); INC(guard)
      ELSE i := j
      END
    ELSE INC(i)
    END
  END;
  IF guard >= 50 THEN
    Err("Macro substitution recursion limit exceeded.")
  END
END ExpandMacros;
PROCEDURE ShowError(line: ARRAY OF CHAR);
VAR t: Str; k: CHAR;
BEGIN
  lastErrCode := errCode; Cpy(errMsg, lastErrMsg); INC(errShown);
  IF batch THEN
    IF batchMid THEN Out.Ln; batchMid := FALSE END;
    Out.String(errMsg); Out.Ln; Out.String("?"); Out.Ln; Out.String(line); Out.Ln;
    RETURN
  END;
  ConNL; ConPut(errMsg);
  ConNL; ConPut("?");
  Cpy(line, t); ConNL; ConPut(t);
  IF (depth = 0) & setHelp & ~inAssist & (Eq(errMsg, "Unrecognized command verb.") OR Eq(errMsg, "Syntax error.")) THEN
    IF AskYN("Do you want some help? (Y/N)") THEN
      SetSrc(line); Cpy(tkStr, t); ShowHelp(t)
    END
  END;
  k := 0X
END ShowError;

(* Execute one command line.  Errors are left in err/errMsg. *)
PROCEDURE ExecLine(line: ARRAY OF CHAR);
VAR s, word, t: Str; n: Node;
BEGIN
  Cpy(line, s);
  ExpandMacros(s);
  StripComment(s);
  Trim(s);
  IF (s[0] = 0X) OR (s[0] = "*") THEN RETURN END;
  SetSrc(s);
  IF tk = tNum THEN DoGoto; RETURN END;
  IF tk = tOther THEN
    IF tkStr[0] = "?" THEN
      IF src[sp] = "?" THEN INC(sp); Next; DoQuestion(FALSE)
      ELSE Next; DoQuestion(TRUE)
      END
    ELSIF tkStr[0] = "@" THEN Next; DoAt
    ELSE Err("Unrecognized command verb.")
    END;
    RETURN
  END;
  IF tk = tNot THEN Sub(src, sp, 255, t); DoRun(t); RETURN END;
  IF tk # tIdent THEN Err("Unrecognized command verb."); RETURN END;
  Cpy(tkStr, word); Next;
  IF (tk = tEq) & ~Kw(word, "STORE") THEN DoAssign(word); RETURN END;
  IF Kw(word, "LIST") OR Kw(word, "DISPLAY") THEN
    IF IsKw("STRUCTURE") THEN Next; IF NeedDb() THEN
        paging := Kw(word, "DISPLAY"); pageCount := 0; ListStructure(cur); paging := FALSE END
    ELSIF IsKw("STATUS") THEN Next; paging := Kw(word, "DISPLAY"); pageCount := 0; ListStatus; paging := FALSE
    ELSIF IsKw("MEMORY") THEN Next; paging := Kw(word, "DISPLAY"); pageCount := 0; ListMemory; paging := FALSE
    ELSIF IsKw("HISTORY") THEN Next; ListHistory
    ELSIF IsKw("FILES") THEN
      Next; t[0] := 0X;
      IF IsKw("LIKE") THEN Next; RawWord(t) END;
      IF IsKw("ON") THEN Next; RawWord(word) END;
      DoDir(t)
    ELSE DoList(Kw(word, "DISPLAY"))
    END
  ELSIF Kw(word, "USE") THEN DoUse
  ELSIF Kw(word, "SELECT") THEN DoSelect
  ELSIF Kw(word, "GOTO") OR EqI(word, "GO") THEN DoGoto
  ELSIF Kw(word, "SKIP") THEN DoSkip
  ELSIF Kw(word, "STORE") THEN DoStore
  ELSIF Kw(word, "SUM") THEN DoSum(FALSE)
  ELSIF Kw(word, "AVERAGE") THEN DoSum(TRUE)
  ELSIF Kw(word, "COUNT") THEN DoCount
  ELSIF Kw(word, "REPLACE") THEN DoReplace
  ELSIF Kw(word, "DELETE") THEN
    IF IsKw("FILE") THEN Next; DoErase ELSE DoDeleteRecall(TRUE) END
  ELSIF Kw(word, "RECALL") THEN DoDeleteRecall(FALSE)
  ELSIF Kw(word, "PACK") THEN DoPack
  ELSIF Kw(word, "ZAP") THEN DoZap
  ELSIF Kw(word, "INDEX") THEN DoIndex
  ELSIF Kw(word, "REINDEX") THEN IF NeedDb() THEN Reindex(cur); GoTop(cur) END
  ELSIF Kw(word, "SEEK") THEN DoSeek
  ELSIF Kw(word, "FIND") THEN DoFind
  ELSIF Kw(word, "LOCATE") THEN DoLocate
  ELSIF Kw(word, "CONTINUE") THEN DoContinue
  ELSIF Kw(word, "SORT") THEN DoSort
  ELSIF Kw(word, "COPY") THEN DoCopy
  ELSIF Kw(word, "APPEND") THEN
    IF IsKw("BLANK") THEN Next; IF NeedDb() THEN AppendBlank(cur) END
    ELSIF IsKw("FROM") THEN Next; DoAppendFrom
    ELSE DoAppend
    END
  ELSIF Kw(word, "INSERT") THEN
    IF IsKw("BLANK") THEN Next; DoInsertBlank(IsKw("BEFORE"))
    ELSE DoInsert(IsKw("BEFORE"))
    END
  ELSIF Kw(word, "TOTAL") THEN DoTotal
  ELSIF Kw(word, "JOIN") THEN DoJoin
  ELSIF Kw(word, "UPDATE") THEN DoUpdate
  ELSIF Kw(word, "EDIT") OR Kw(word, "CHANGE") THEN DoEdit
  ELSIF Kw(word, "BROWSE") THEN DoBrowse
  ELSIF Kw(word, "CREATE") THEN DoCreate
  ELSIF Kw(word, "MODIFY") THEN DoModify
  ELSIF Kw(word, "REPORT") THEN DoReportForm
  ELSIF Kw(word, "LABEL") THEN DoLabelForm
  ELSIF Kw(word, "SET") THEN DoSet
  ELSIF Kw(word, "CLOSE") THEN DoClose
  ELSIF Kw(word, "CLEAR") THEN DoClear
  ELSIF Kw(word, "RELEASE") THEN DoRelease
  ELSIF Kw(word, "SAVE") THEN DoSaveMem
  ELSIF Kw(word, "RESTORE") THEN DoRestoreMem
  ELSIF Kw(word, "DIR") THEN t[0] := 0X; IF tk # tEOF THEN RawWord(t) END; DoDir(t)
  ELSIF Kw(word, "TYPE") THEN DoType
  ELSIF Kw(word, "ERASE") THEN DoErase
  ELSIF Kw(word, "RENAME") THEN DoRename
  ELSIF Kw(word, "RUN") THEN RawRest(t); DoRun(t)
  ELSIF Kw(word, "QUIT") THEN quitting := TRUE
  ELSIF Kw(word, "EJECT") THEN PrnEject
  ELSIF Kw(word, "WAIT") THEN DoWait
  ELSIF Kw(word, "ACCEPT") THEN DoAcceptInput(FALSE)
  ELSIF Kw(word, "INPUT") THEN DoAcceptInput(TRUE)
  ELSIF Kw(word, "READ") THEN DoRead
  ELSIF Kw(word, "HELP") THEN t[0] := 0X; IF tk # tEOF THEN RawRest(t) END; ShowHelp(t)
  ELSIF Kw(word, "ASSIST") THEN DoAssist
  ELSIF Kw(word, "DO") THEN DoDo
  ELSIF Kw(word, "CANCEL") THEN cancelAll := TRUE
  ELSIF EqI(word, "ON") THEN DoOn
  ELSIF Kw(word, "RETRY") THEN Err("Valid only in programs.")
  ELSIF Kw(word, "CALL") OR Kw(word, "LOAD") THEN
    RawRest(t); Err("Binary (.BIN) modules are not supported.")
  ELSIF Kw(word, "RETURN") THEN
    IF depth = 0 THEN ELSE Err("RETURN outside program.") END
  ELSIF Kw(word, "SUSPEND") THEN
    IF depth > 0 THEN SuspendProgram END
  ELSIF Kw(word, "RESUME") THEN
    IF suspendLevel > 0 THEN resumeFlag := TRUE ELSE Err("No program is suspended.") END
  ELSIF Kw(word, "NOTE") THEN
  ELSIF Kw(word, "PUBLIC") THEN DoPublicPrivate(TRUE)
  ELSIF Kw(word, "PRIVATE") THEN DoPublicPrivate(FALSE)
  ELSIF Kw(word, "PARAMETERS") THEN Err("PARAMETERS is only valid in a program.")
  ELSIF Kw(word, "IMPORT") OR Kw(word, "EXPORT") THEN Err("IMPORT/EXPORT of PFS files is not supported.")
  ELSIF Kw(word, "IF") OR Kw(word, "ELSE") OR Kw(word, "ENDIF") OR Kw(word, "ENDDO")
     OR Kw(word, "CASE") OR Kw(word, "OTHERWISE") OR Kw(word, "ENDCASE") OR Kw(word, "LOOP")
     OR Kw(word, "EXIT") OR Kw(word, "TEXT") OR Kw(word, "ENDTEXT") OR Kw(word, "PROCEDURE") THEN
    Err("Valid only in programs.")
  ELSE
    n := NIL;
    Err("Unrecognized command verb.")
  END;
  IF ~err & (tk # tEOF) & ~(tk = tOther) THEN Err("Unrecognized phrase/keyword in command.") END
END ExecLine;

PROCEDURE DoPublicPrivate(public: BOOLEAN);
VAR k: INTEGER;
BEGIN
  IF IsKw("ALL") THEN
    Next;
    IF public THEN Err("Syntax error."); RETURN END;
    IF depth = 0 THEN RawRest(src); RETURN END;
    frames[depth - 1].privMode := 1; frames[depth - 1].privSkel[0] := 0X;
    IF IsKw("LIKE") THEN Next; frames[depth - 1].privMode := 2; RawWord(frames[depth - 1].privSkel)
    ELSIF IsKw("EXCEPT") THEN Next; frames[depth - 1].privMode := 3; RawWord(frames[depth - 1].privSkel)
    END;
    RETURN
  END;
  WHILE tk = tIdent DO
    IF public THEN
      k := FindVar(tkStr);
      IF k < 0 THEN k := NewVar(tkStr) END;
      IF k >= 0 THEN vars[k].public := TRUE; vars[k].level := 0 END
    ELSE
      k := FindVar(tkStr);
      IF (k < 0) OR (vars[k].level # depth) THEN k := NewVar(tkStr) END
    END;
    Next;
    IF tk = tComma THEN Next END
  END
END DoPublicPrivate;

(* ====================================================================
   Command files (.PRG)
   Lines are classified once at load time and every structured
   statement gets its partner line precomputed in jmp/aux:
     IF      -> ELSE or ENDIF        ELSE  -> ENDIF
     DO WHILE-> ENDDO                ENDDO -> DO WHILE
     LOOP/EXIT: aux = enclosing DO WHILE
     DO CASE -> first CASE; CASE/OTHERWISE -> next branch, aux = ENDCASE
     TEXT    -> ENDTEXT
   ==================================================================== *)

CONST
  vOther = 0; vIF = 1; vELSE = 2; vENDIF = 3; vDOWHILE = 4; vENDDO = 5;
  vDOCASE = 6; vCASE = 7; vOTHERWISE = 8; vENDCASE = 9; vLOOP = 10;
  vEXIT = 11; vRETURN = 12; vPROCEDURE = 13; vTEXT = 14; vENDTEXT = 15;
  vPARAMETERS = 16; vTEXTLINE = 17; vComment = 18; vTOOLONG = 19; vRETRY = 20;
  MaxArgs = 16;

VAR
  pendN: INTEGER;
  pendV: ARRAY MaxArgs OF Value;
  pendRef: ARRAY MaxArgs OF Name;
  returnMaster: BOOLEAN;

PROCEDURE ClassifyLine(s: ARRAY OF CHAR): INTEGER;
VAR w1, w2: Str; i: INTEGER;
BEGIN
  i := 0;
  WHILE (s[i] = " ") OR (s[i] = 09X) DO INC(i) END;
  IF (s[i] = "*") OR ((s[i] = "&") & (s[i + 1] = "&")) OR (s[i] = 0X) THEN RETURN vComment END;
  w1[0] := 0X;
  WHILE IsIdCh(s[i]) DO AppendCh(s[i], w1); INC(i) END;
  WHILE s[i] = " " DO INC(i) END;
  IF s[i] = "=" THEN RETURN vOther END;   (* assignment to a variable named like a verb *)
  w2[0] := 0X;
  WHILE IsIdCh(s[i]) DO AppendCh(s[i], w2); INC(i) END;
  IF EqI(w1, "IF") THEN RETURN vIF
  ELSIF Kw(w1, "ELSE") THEN RETURN vELSE
  ELSIF Kw(w1, "ENDIF") THEN RETURN vENDIF
  ELSIF EqI(w1, "DO") & Kw(w2, "WHILE") THEN RETURN vDOWHILE
  ELSIF EqI(w1, "DO") & EqI(w2, "CASE") THEN RETURN vDOCASE
  ELSIF Kw(w1, "ENDDO") THEN RETURN vENDDO
  ELSIF EqI(w1, "CASE") THEN RETURN vCASE
  ELSIF Kw(w1, "OTHERWISE") THEN RETURN vOTHERWISE
  ELSIF Kw(w1, "ENDCASE") THEN RETURN vENDCASE
  ELSIF Kw(w1, "LOOP") THEN RETURN vLOOP
  ELSIF Kw(w1, "EXIT") THEN RETURN vEXIT
  ELSIF Kw(w1, "RETURN") THEN RETURN vRETURN
  ELSIF Kw(w1, "PROCEDURE") THEN RETURN vPROCEDURE
  ELSIF Kw(w1, "TEXT") THEN RETURN vTEXT
  ELSIF Kw(w1, "ENDTEXT") THEN RETURN vENDTEXT
  ELSIF Kw(w1, "PARAMETERS") THEN RETURN vPARAMETERS
  ELSIF Kw(w1, "RETRY") THEN RETURN vRETRY
  ELSIF Kw(w1, "NOTE") THEN RETURN vComment
  END;
  RETURN vOther
END ClassifyLine;

PROCEDURE LoadProg(path: ARRAY OF CHAR): Prog;
VAR
  p: Prog; f: Files.File; r: Files.Rider; line, acc: Str; n, i, top, w: INTEGER;
  stk: ARRAY 64 OF INTEGER; inText, ovf, more: BOOLEAN; tooLong: ARRAY MaxTxtLn OF BOOLEAN;
BEGIN
  f := Files.Old(path);
  IF f = NIL THEN RETURN NIL END;
  NEW(p); Cpy(path, p.name); p.n := 0;
  Files.Set(r, f, 0);
  acc[0] := 0X; inText := FALSE;
  LOOP
    Files.ReadLine(r, line);
    IF r.eof & (line[0] = 0X) THEN EXIT END;
    n := SLen(line);
    IF (n > 0) & (line[n - 1] = 0DX) THEN line[n - 1] := 0X END;
    FOR i := 0 TO SLen(line) - 1 DO IF line[i] = 09X THEN line[i] := " " END END;
    IF line[0] = 1AX THEN EXIT END;
    IF inText THEN
      IF ClassifyLine(line) = vENDTEXT THEN inText := FALSE END;
      IF p.n < MaxTxtLn THEN Cpy(line, p.line[p.n]); tooLong[p.n] := FALSE; INC(p.n) END
    ELSE
      Cpy(line, acc);
      LTrim(acc); RTrim(acc);
      ovf := FALSE;
      (* ; at the end continues the command on the next line; once the
         joined line overflows, the rest of it is still read and dropped *)
      more := (SLen(acc) > 0) & (acc[SLen(acc) - 1] = ";");
      WHILE more & ~r.eof DO
        IF ~ovf THEN acc[SLen(acc) - 1] := " " END;
        Files.ReadLine(r, line);
        n := SLen(line); IF (n > 0) & (line[n - 1] = 0DX) THEN line[n - 1] := 0X END;
        FOR i := 0 TO SLen(line) - 1 DO IF line[i] = 09X THEN line[i] := " " END END;
        LTrim(line); RTrim(line);
        more := (SLen(line) > 0) & (line[SLen(line) - 1] = ";");
        IF ~ovf & (SLen(acc) + SLen(line) >= LEN(acc)) THEN ovf := TRUE END;
        IF ~ovf THEN Append(line, acc); RTrim(acc) END;
        IF p.n < MaxTxtLn THEN p.line[p.n][0] := 0X END
      END;
      IF ClassifyLine(acc) = vTEXT THEN inText := TRUE END;
      IF p.n < MaxTxtLn THEN Cpy(acc, p.line[p.n]); tooLong[p.n] := ovf; INC(p.n) END
    END;
    IF r.eof THEN EXIT END
  END;
  Files.Close(f);
  (* classify and match *)
  top := 0; inText := FALSE;
  FOR i := 0 TO p.n - 1 DO
    p.jmp[i] := -1; p.aux[i] := -1;
    IF inText THEN
      IF ClassifyLine(p.line[i]) = vENDTEXT THEN
        p.verb[i] := vENDTEXT; inText := FALSE;
        IF top > 0 THEN DEC(top); p.jmp[stk[top]] := i END
      ELSE p.verb[i] := vTEXTLINE
      END
    ELSE
      w := ClassifyLine(p.line[i]);
      IF tooLong[i] THEN w := vTOOLONG END;
      p.verb[i] := w;
      CASE w OF
        vIF, vDOWHILE, vDOCASE:
          IF top < 64 THEN stk[top] := i; INC(top) END
      | vTEXT:
          inText := TRUE;
          IF top < 64 THEN stk[top] := i; INC(top) END
      | vELSE:
          IF (top > 0) & (p.verb[stk[top - 1]] = vIF) THEN p.jmp[stk[top - 1]] := i; stk[top - 1] := i END
      | vENDIF:
          IF (top > 0) & ((p.verb[stk[top - 1]] = vIF) OR (p.verb[stk[top - 1]] = vELSE)) THEN
            DEC(top); p.jmp[stk[top]] := i
          END
      | vENDDO:
          IF (top > 0) & (p.verb[stk[top - 1]] = vDOWHILE) THEN
            DEC(top); p.jmp[stk[top]] := i; p.jmp[i] := stk[top]
          END
      | vLOOP, vEXIT:
          n := top - 1;
          WHILE (n >= 0) & (p.verb[stk[n]] # vDOWHILE) DO DEC(n) END;
          IF n >= 0 THEN p.aux[i] := stk[n] END
      | vCASE, vOTHERWISE:
          IF top > 0 THEN
            n := stk[top - 1];
            IF p.verb[n] = vDOCASE THEN p.jmp[n] := i; stk[top - 1] := i
            ELSIF (p.verb[n] = vCASE) OR (p.verb[n] = vOTHERWISE) THEN p.jmp[n] := i; stk[top - 1] := i
            END
          END
      | vENDCASE:
          IF top > 0 THEN
            DEC(top); n := stk[top];
            p.jmp[n] := i;
            (* every CASE of this block learns where the block ends *)
            WHILE n >= 0 DO
              IF (p.verb[n] = vCASE) OR (p.verb[n] = vOTHERWISE) THEN p.aux[n] := i END;
              IF p.verb[n] = vDOCASE THEN n := -1 ELSE
                (* walk back through the chain *)
                w := n - 1;
                WHILE (w >= 0) & (p.jmp[w] # n) DO DEC(w) END;
                n := w
              END
            END
          END
      ELSE
      END
    END
  END;
  RETURN p
END LoadProg;

PROCEDURE GetProg(name: ARRAY OF CHAR): Prog;
VAR path: Str; i: INTEGER; p: Prog;
BEGIN
  IF ~FindFile(name, ".prg", path) THEN RETURN NIL END;
  FOR i := 0 TO nProgs - 1 DO
    IF Eq(progs[i].name, path) THEN RETURN progs[i] END
  END;
  p := LoadProg(path);
  IF (p # NIL) & (nProgs < MaxPrgs) THEN progs[nProgs] := p; INC(nProgs) END;
  RETURN p
END GetProg;

PROCEDURE ForgetProg(path: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO nProgs - 1 DO
    IF Eq(progs[i].name, path) THEN progs[i] := progs[nProgs - 1]; DEC(nProgs); RETURN END
  END
END ForgetProg;

PROCEDURE ProcName(s: ARRAY OF CHAR; VAR name: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  i := 0; WHILE s[i] = " " DO INC(i) END;
  WHILE IsIdCh(s[i]) DO INC(i) END;
  WHILE s[i] = " " DO INC(i) END;
  name[0] := 0X;
  WHILE IsIdCh(s[i]) DO AppendCh(UpCh(s[i]), name); INC(i) END
END ProcName;

PROCEDURE OpenProcedure(name: ARRAY OF CHAR);
VAR path: Str; i: INTEGER; pn: Str;
BEGIN
  CloseProcedure;
  IF ~FindFile(name, ".prg", path) THEN Err("File does not exist."); RETURN END;
  procFile := LoadProg(path);
  IF procFile = NIL THEN RETURN END;
  FOR i := 0 TO procFile.n - 1 DO
    IF (procFile.verb[i] = vPROCEDURE) & (nProcs < MaxProcs) THEN
      ProcName(procFile.line[i], pn); Cpy(pn, procName[nProcs]); procLine[nProcs] := i + 1; INC(nProcs)
    END
  END
END OpenProcedure;

PROCEDURE CloseProcedure;
BEGIN
  procFile := NIL; nProcs := 0
END CloseProcedure;

(* text after the first word, or after "DO WHILE" / "CASE" *)
PROCEDURE AfterWords(s: ARRAY OF CHAR; words: INTEGER; VAR rest: ARRAY OF CHAR);
VAR i, k: INTEGER;
BEGIN
  i := 0;
  FOR k := 1 TO words DO
    WHILE s[i] = " " DO INC(i) END;
    WHILE IsIdCh(s[i]) DO INC(i) END
  END;
  Sub(s, i, 255, rest); Trim(rest)
END AfterWords;

PROCEDURE CondTrue(s: ARRAY OF CHAR; words: INTEGER): BOOLEAN;
VAR rest: Str; n: Node; b: BOOLEAN;
BEGIN
  AfterWords(s, words, rest);
  ExpandMacros(rest); StripComment(rest);
  n := CompileStr(rest);
  IF err THEN RETURN FALSE END;
  b := EvalBool(n);
  RETURN b & ~err
END CondTrue;

(* run an ON ERROR / ESCAPE / KEY command; busy blocks re-entry *)
PROCEDURE RunHook(cmd: ARRAY OF CHAR; VAR busy: BOOLEAN);
VAR t: Str;
BEGIN
  busy := TRUE; Cpy(cmd, t);
  err := FALSE; ExecLine(t);
  IF err THEN ShowError(t); err := FALSE END;
  busy := FALSE
END RunHook;

PROCEDURE ProgError(p: Prog; pc: INTEGER): BOOLEAN; (* TRUE = cancel *)
VAR t, nm: Str; k: CHAR; i: INTEGER;
BEGIN
  IF (onErrCmd[0] # 0X) & ~inOnErr THEN
    (* ON ERROR: run the trap; RETURN resumes after this line, RETRY repeats it *)
    lastErrCode := errCode; Cpy(errMsg, lastErrMsg);
    RunHook(onErrCmd, inOnErr);
    RETURN cancelAll
  END;
  ShowError(p.line[pc]);
  FOR i := depth - 1 TO 0 BY -1 DO
    ShortName(frames[i].p.name, nm);
    Cpy("Called from - ", t); Append(nm, t);
    IF batch THEN Out.String(t); Out.Ln ELSE ConNL; ConPut(t) END
  END;
  err := FALSE;
  IF batch THEN RETURN FALSE END;
  LOOP
    k := UpCh(WaitKeyMsg("Cancel, Ignore, or Suspend? (C, I, or S) "));
    IF (k = "C") OR (k = TUI.KEsc) THEN ConPut("C"); RETURN TRUE
    ELSIF k = "I" THEN ConPut("I"); RETURN FALSE
    ELSIF k = "S" THEN ConPut("S"); SuspendProgram; RETURN cancelAll
    END
  END
END ProgError;

PROCEDURE BindParams(line: ARRAY OF CHAR);
VAR rest, name: Str; i, k, fr: INTEGER;
BEGIN
  AfterWords(line, 1, rest);
  fr := depth - 1;
  i := 0;
  WHILE Strings.Split(rest, ",", i, name) DO
    Trim(name);
    IF name[0] # 0X THEN
      k := NewVar(name);
      IF (k >= 0) & (i < pendN) THEN
        vars[k].v := pendV[i];
        IF pendRef[i][0] # 0X THEN
          IF frames[fr].nParmRef >= 16 THEN
            Err("Too many reference parameters.")
          ELSE
            Cpy(name, frames[fr].parmName[frames[fr].nParmRef]);
            Upper(frames[fr].parmName[frames[fr].nParmRef]);
            Cpy(pendRef[i], frames[fr].parmRef[frames[fr].nParmRef]);
            INC(frames[fr].nParmRef)
          END
        END
      END
    END;
    INC(i)
  END;
  pendN := 0
END BindParams;

PROCEDURE PopFrame;
VAR i, k, j: INTEGER; v: Value; fr: INTEGER;
BEGIN
  fr := depth - 1;
  (* pass reference parameters back *)
  FOR i := 0 TO frames[fr].nParmRef - 1 DO
    k := FindVar(frames[fr].parmName[i]);
    IF k >= 0 THEN
      v := vars[k].v;
      FOR j := nVars - 1 TO 0 BY -1 DO
        IF (vars[j].level < depth) & Eq(vars[j].name, frames[fr].parmRef[i]) THEN vars[j].v := v; j := 0 END
      END
    END
  END;
  (* release this level's private variables *)
  i := nVars - 1;
  WHILE i >= 0 DO
    IF (vars[i].level = depth) & ~vars[i].public THEN ReleaseVar(i) END;
    DEC(i)
  END;
  DEC(depth)
END PopFrame;

PROCEDURE RunProg(p: Prog; start: INTEGER);
VAR pc, pc0, v, k, guard: INTEGER; line, t: Str; stop, retry: BOOLEAN;
BEGIN
  IF depth >= MaxDepth THEN Err("Too many nested DO commands."); RETURN END;
  frames[depth].p := p; frames[depth].pc := start; frames[depth].nParmRef := 0;
  frames[depth].callerArea := cur; frames[depth].privMode := 0;
  INC(depth);
  frames[depth - 1].level := depth;
  pc := start; stop := FALSE; retry := FALSE; guard := 0;
  WHILE (pc < p.n) & ~stop & ~cancelAll & ~quitting DO
    frames[depth - 1].pc := pc; pc0 := pc;
    INC(guard);
    IF ((guard MOD 32 = 0) OR (onKeyCmd[0] # 0X)) & EscPressed() THEN interrupted := TRUE END;
    IF interrupted & (onEscCmd[0] # 0X) & ~inOnEsc THEN
      interrupted := FALSE; RunHook(onEscCmd, inOnEsc)
    ELSIF interrupted THEN
      interrupted := FALSE;
      ConNL; ConPut("*** INTERRUPTED ***");
      cancelAll := TRUE; stop := TRUE
    ELSIF (taN > onKeyN) & (onKeyCmd[0] # 0X) & ~inOnKey THEN
      (* the key stays in the typeahead buffer; INKEY() takes it *)
      RunHook(onKeyCmd, inOnKey); onKeyN := taN
    ELSE
      IF taN < onKeyN THEN onKeyN := taN END;
      Cpy(p.line[pc], line);
      v := p.verb[pc];
      CASE v OF
        vComment, vTEXTLINE, vENDIF, vENDCASE, vENDTEXT: INC(pc)
      | vIF:
          IF CondTrue(line, 1) THEN INC(pc)
          ELSIF err THEN IF ProgError(p, pc) THEN cancelAll := TRUE END; INC(pc)
          ELSIF p.jmp[pc] < 0 THEN Err("IF without ENDIF."); stop := TRUE
          ELSE pc := p.jmp[pc] + 1
          END
      | vELSE:
          IF p.jmp[pc] < 0 THEN INC(pc) ELSE pc := p.jmp[pc] + 1 END
      | vDOWHILE:
          IF CondTrue(line, 2) THEN INC(pc)
          ELSIF err THEN IF ProgError(p, pc) THEN cancelAll := TRUE END; INC(pc)
          ELSIF p.jmp[pc] < 0 THEN Err("DO WHILE without ENDDO."); stop := TRUE
          ELSE pc := p.jmp[pc] + 1
          END
      | vENDDO:
          IF p.jmp[pc] >= 0 THEN pc := p.jmp[pc] ELSE INC(pc) END
      | vLOOP:
          IF p.aux[pc] >= 0 THEN pc := p.aux[pc] ELSE INC(pc) END
      | vEXIT:
          IF (p.aux[pc] >= 0) & (p.jmp[p.aux[pc]] >= 0) THEN pc := p.jmp[p.aux[pc]] + 1 ELSE INC(pc) END
      | vDOCASE:
          k := p.jmp[pc];
          LOOP
            IF k < 0 THEN pc := p.n; EXIT END;
            IF p.verb[k] = vCASE THEN
              IF CondTrue(p.line[k], 1) THEN pc := k + 1; EXIT END;
              IF err THEN IF ProgError(p, k) THEN cancelAll := TRUE END; pc := k + 1; EXIT END;
              k := p.jmp[k]
            ELSE pc := k + 1; EXIT   (* OTHERWISE or ENDCASE *)
            END
          END
      | vCASE, vOTHERWISE:
          IF p.aux[pc] >= 0 THEN pc := p.aux[pc] + 1 ELSE INC(pc) END
      | vTEXT:
          INC(pc);
          WHILE (pc < p.n) & (p.verb[pc] = vTEXTLINE) DO Line(p.line[pc]); INC(pc) END;
          INC(pc)
      | vPARAMETERS: BindParams(line); INC(pc)
      | vTOOLONG:
          Err("Line exceeds maximum of 254 characters.");
          IF ProgError(p, pc) THEN cancelAll := TRUE END;
          INC(pc)
      | vRETURN:
          AfterWords(line, 1, t);
          IF StartsI(t, "TO") THEN cancelAll := FALSE; quitting := FALSE; stop := TRUE; returnMaster := TRUE
          ELSE stop := TRUE
          END
      | vPROCEDURE: stop := TRUE
      | vRETRY: stop := TRUE; retry := TRUE
      ELSE
        IF setEcho & ~batch THEN ConNL; ConPut(line) END;
        ExecLine(line);
        IF err THEN
          IF ProgError(p, pc) THEN cancelAll := TRUE END
        END;
        INC(pc)
      END
    END;
    (* a RETRY in a called program or ON ERROR trap repeats this line *)
    IF retryFlag THEN retryFlag := FALSE; pc := pc0 END;
    IF returnMaster & (depth > 1) THEN stop := TRUE END
  END;
  PopFrame;
  IF retry & (depth > 0) THEN retryFlag := TRUE END;
  IF depth <= 1 THEN returnMaster := FALSE END;
  IF depth = 0 THEN FlushAll END
END RunProg;


PROCEDURE DoDo;
VAR name, t: Str; p: Prog; i, start, k: INTEGER; n: Node; isRef: BOOLEAN;
BEGIN
  IF IsKw("WHILE") OR IsKw("CASE") THEN Err("Valid only in programs."); RETURN END;
  RawWord(name);
  pendN := 0;
  IF IsKw("WITH") THEN
    Next;
    WHILE (tk # tEOF) & ~err & (pendN < MaxArgs) DO
      isRef := FALSE;
      IF tk = tIdent THEN
        Cpy(tkStr, t);
        k := sp;
        WHILE (src[k] = " ") DO INC(k) END;
        IF ((src[k] = ",") OR (src[k] = 0X)) & (FindVar(t) >= 0) THEN isRef := TRUE END
      END;
      n := Expr();
      IF ~err THEN
        Eval(n, pendV[pendN]);
        IF isRef THEN Cpy(t, pendRef[pendN]); Upper(pendRef[pendN]) ELSE pendRef[pendN][0] := 0X END;
        INC(pendN)
      END;
      IF tk = tComma THEN Next END
    END
  END;
  IF err THEN RETURN END;
  (* procedure in the SET PROCEDURE file? *)
  Cpy(name, t); Upper(t);
  FOR i := 0 TO nProcs - 1 DO
    IF Eq(procName[i], t) THEN RunProg(procFile, procLine[i]); tk := tEOF; RETURN END
  END;
  (* procedure inside the running program's own file *)
  IF depth > 0 THEN
    p := frames[depth - 1].p;
    FOR i := 0 TO p.n - 1 DO
      IF p.verb[i] = vPROCEDURE THEN
        ProcName(p.line[i], t);
        IF EqI(t, name) THEN RunProg(p, i + 1); tk := tEOF; RETURN END
      END
    END
  END;
  p := GetProg(name);
  IF p = NIL THEN Err("File does not exist."); RETURN END;
  start := 0;
  RunProg(p, start);
  tk := tEOF  (* the called program leaves the tokenizer on its last line *)
END DoDo;

(* ====================================================================
   Dot prompt
   ==================================================================== *)
PROCEDURE RunCommand(s: ARRAY OF CHAR);
BEGIN
  err := FALSE; errMsg[0] := 0X; interrupted := FALSE;
  (* Clear per-command state up front so a stale value from a
     previous command (that errored out) cannot bleed through. *)
  paging := FALSE; prnActive := FALSE; toActive := FALSE;
  retryFlag := FALSE;
  ExecLine(s);
  IF err THEN ShowError(s); err := FALSE END;
  IF interrupted THEN
    IF batch THEN Out.String("*** INTERRUPTED ***"); Out.Ln
    ELSE ConNL; ConPut("*** INTERRUPTED ***") END;
    interrupted := FALSE
  END;
  IF depth = 0 THEN cancelAll := FALSE END;
  (* Belt and braces: clear again on exit *)
  paging := FALSE; prnActive := FALSE; toActive := FALSE;
  (* Make sure any TO FILE rider was closed *)
  IF toF # NIL THEN
    Files.Register(toF); Files.Close(toF); toF := NIL
  END;
  FlushAll
END RunCommand;
PROCEDURE DotPrompt;
VAR s: Str;
BEGIN
  LOOP
    Cpy("Command Line", modeName);
    SetNav("");
    IF userMsg[0] # 0X THEN SetMsg(userMsg) ELSE SetMsg("Enter a dBASE III PLUS command.") END;
    IF suspendLevel > 0 THEN SetMsg("Program suspended -- RESUME to continue, CANCEL to stop.") END;
    ConNL;
    s[0] := 0X;
    IF ReadLine(". ", s, 254, TRUE) THEN
      Trim(s);
      IF s[0] # 0X THEN
        AddHistory(s);
        RunCommand(s)
      END
    END;
    IF quitting THEN EXIT END;
    IF (suspendLevel > 0) & (resumeFlag OR cancelAll) THEN EXIT END
  END
END DotPrompt;

PROCEDURE SuspendProgram;
BEGIN
  IF batch THEN RETURN END;
  INC(suspendLevel); resumeFlag := FALSE;
  ConNL; ConPut("Do suspended");
  DotPrompt;
  DEC(suspendLevel); resumeFlag := FALSE
END SuspendProgram;

(* ====================================================================
   Full-screen support
   ==================================================================== *)

CONST
  feStay = 0; feNext = 1; fePrev = 2; feOther = 3; feLeftOut = 4; feRightOut = 5;

PROCEDURE FSClear;
BEGIN
  TUI.ClearBack(cFg, cBg)
END FSClear;

PROCEDURE PutS(x, y: INTEGER; s: ARRAY OF CHAR; rev: BOOLEAN);
BEGIN
  IF rev THEN TUI.PutStr(x, y, s, cRevFg, cRevBg) ELSE TUI.PutStr(x, y, s, cFg, cBg) END
END PutS;

PROCEDURE PutHi(x, y: INTEGER; s: ARRAY OF CHAR);
BEGIN TUI.PutStr(x, y, s, cHiFg, cBg) END PutHi;

(* status bar, navigation and message lines at the bottom *)
PROCEDURE FSBars(mode: ARRAY OF CHAR);
VAR save, sm, sn: Str;
BEGIN
  Cpy(modeName, save); Cpy(mode, modeName);
  Cpy(msgLine, sm); Cpy(navLine, sn);
  Cpy(fsMsg, msgLine); Cpy(fsNav, navLine);
  ScreenSize;
  DrawBars;
  Cpy(save, modeName); Cpy(sm, msgLine); Cpy(sn, navLine)
END FSBars;

VAR fsMsg, fsNav: Str;   (* message and navigation lines for full-screen modes *)

PROCEDURE FSFlush(cx, cy: INTEGER; show: BOOLEAN);
BEGIN
  TUI.Flush;
  IF show THEN TUI.SetCursor(cx, cy) ELSE Terminal.HideCursor() END
END FSFlush;

PROCEDURE Box(x, y, w, h: INTEGER);
BEGIN
  TUI.FillRect(x, y, w, h, " ", cFg, cBg);
  TUI.DrawBox(x, y, w, h, cFg, cBg)
END Box;

(* centred one-line question in a box; TRUE for Y *)
PROCEDURE FSAsk(q: ARRAY OF CHAR): BOOLEAN;
VAR w, x, y: INTEGER; k: CHAR;
BEGIN
  IF batch THEN RETURN TRUE END;
  w := SLen(q) + 6; x := (TUI.Cols - w) DIV 2 + 1; y := TUI.Rows DIV 2;
  LOOP
    Box(x, y - 1, w, 3);
    PutHi(x + 3, y, q);
    FSFlush(x + 3 + SLen(q), y, TRUE);
    k := UpCh(GetKey());
    IF k = "Y" THEN RETURN TRUE END;
    IF (k = "N") OR (k = TUI.KEsc) THEN RETURN FALSE END
  END
END FSAsk;

PROCEDURE FSMessage(msg: ARRAY OF CHAR);
VAR w, x, y: INTEGER; k: CHAR;
BEGIN
  IF batch THEN Out.String(msg); Out.Ln; RETURN END;
  w := SLen(msg) + 6; IF w < 30 THEN w := 30 END;
  x := (TUI.Cols - w) DIV 2 + 1; y := TUI.Rows DIV 2;
  Box(x, y - 1, w, 4);
  PutHi(x + 3, y, msg);
  PutS(x + 3, y + 1, "Press any key to continue", FALSE);
  FSFlush(1, 1, FALSE);
  Bell;
  REPEAT k := GetKey() UNTIL k # 0X
END FSMessage;

(* ---- single field editor ---- *)

PROCEDURE IsTmplCh(c: CHAR): BOOLEAN;
BEGIN
  RETURN (c = "9") OR (c = "#") OR (c = "A") OR (c = "X") OR (c = "L") OR (c = "Y")
      OR (c = "N") OR (c = "!")
END IsTmplCh;

(* copy a character PICTURE's literals, like the ( ) - of "(999) 999-9999",
   into text: they are shown in the GET and stored in the value *)
PROCEDURE PutLiterals(pic: ARRAY OF CHAR; t: CHAR; VAR text: ARRAY OF CHAR);
VAR fn, tm: Str; i: INTEGER;
BEGIN
  IF (t # TC) OR (pic[0] = 0X) THEN RETURN END;
  SplitPicture(pic, fn, tm);
  i := 0;
  WHILE (tm[i] # 0X) & (text[i] # 0X) DO
    IF ~IsTmplCh(tm[i]) THEN text[i] := tm[i] END;
    INC(i)
  END
END PutLiterals;

(* is position p of the edit field a fixed literal? *)
PROCEDURE FixedPos(VAR fe: FieldEd; p: INTEGER): BOOLEAN;
VAR fn, tm: Str;
BEGIN
  IF fe.t = TD THEN RETURN (fe.text[p] = "/") OR (fe.text[p] = ".") OR (fe.text[p] = "-") END;
  IF fe.pic[0] = 0X THEN RETURN FALSE END;
  SplitPicture(fe.pic, fn, tm);
  IF (tm[0] = 0X) OR (p >= SLen(tm)) THEN RETURN FALSE END;
  RETURN ~IsTmplCh(tm[p])
END FixedPos;

PROCEDURE CharOK(VAR fe: FieldEd; p: INTEGER; VAR c: CHAR): BOOLEAN;
VAR fn, tm: Str; tc: CHAR;
BEGIN
  SplitPicture(fe.pic, fn, tm);
  IF HasFn(fn, "!") THEN c := UpCh(c) END;
  tc := 0X;
  IF (tm[0] # 0X) & (p < SLen(tm)) THEN tc := tm[p] END;
  CASE fe.t OF
    "N": IF ~(IsDigit(c) OR (c = ".") OR (c = "-") OR (c = " ") OR (c = "+")) THEN RETURN FALSE END
  | "D": IF ~IsDigit(c) THEN RETURN FALSE END
  | "L":
      c := UpCh(c);
      IF ~((c = "T") OR (c = "F") OR (c = "Y") OR (c = "N")) THEN RETURN FALSE END
  ELSE
  END;
  CASE tc OF
    "9": IF ~(IsDigit(c) OR (c = "-") OR (c = "+") OR ((fe.t = TN) & (c = "."))) THEN RETURN FALSE END
  | "#": IF ~(IsDigit(c) OR (c = " ") OR (c = "-") OR (c = "+") OR (c = ".")) THEN RETURN FALSE END
  | "A": IF ~IsAlpha(c) THEN RETURN FALSE END
  | "!": c := UpCh(c)
  | "L": c := UpCh(c); IF ~((c = "T") OR (c = "F") OR (c = "Y") OR (c = "N")) THEN RETURN FALSE END
  | "Y": c := UpCh(c); IF ~((c = "Y") OR (c = "N")) THEN RETURN FALSE END
  ELSE
  END;
  RETURN TRUE
END CharOK;

PROCEDURE FEInit(VAR fe: FieldEd; text: ARRAY OF CHAR; width: INTEGER; t: CHAR; pic: ARRAY OF CHAR);
BEGIN
  IF width > 254 THEN width := 254 END;
  IF width < 1 THEN width := 1 END;
  Cpy(text, fe.text); PadR(fe.text, width); PutLiterals(pic, t, fe.text);
  fe.width := width; fe.pos := 0; fe.scroll := 0; fe.t := t;
  Cpy(pic, fe.pic); fe.changed := FALSE;
  WHILE (fe.pos < width - 1) & FixedPos(fe, fe.pos) DO INC(fe.pos) END
END FEInit;

PROCEDURE FESkipFixed(VAR fe: FieldEd; dir: INTEGER);
BEGIN
  WHILE (fe.pos >= 0) & (fe.pos < fe.width) & FixedPos(fe, fe.pos) DO INC(fe.pos, dir) END;
  IF fe.pos < 0 THEN fe.pos := 0; WHILE (fe.pos < fe.width - 1) & FixedPos(fe, fe.pos) DO INC(fe.pos) END END;
  IF fe.pos >= fe.width THEN fe.pos := fe.width - 1 END
END FESkipFixed;

(* Handle one key; returns feStay, feNext, fePrev, feLeftOut, feRightOut
   or feOther for keys the caller must interpret. *)
PROCEDURE FEKey(VAR fe: FieldEd; k: CHAR): INTEGER;
VAR i: INTEGER; c: CHAR; fixed: BOOLEAN;
BEGIN
  fixed := (fe.t = TD) OR (fe.pic[0] # 0X);
  IF (k = TUI.KLeft) OR (k = KCtrlS) THEN
    IF fe.pos = 0 THEN RETURN feLeftOut END;
    DEC(fe.pos); FESkipFixed(fe, -1);
    RETURN feStay
  ELSIF (k = TUI.KRight) OR (k = KCtrlD) THEN
    IF fe.pos >= fe.width - 1 THEN RETURN feRightOut END;
    INC(fe.pos); FESkipFixed(fe, 1);
    RETURN feStay
  ELSIF (k = TUI.KHome) OR (k = KCtrlA) THEN
    (* start of previous word *)
    IF fe.pos = 0 THEN RETURN feStay END;
    DEC(fe.pos);
    WHILE (fe.pos > 0) & (fe.text[fe.pos] = " ") DO DEC(fe.pos) END;
    WHILE (fe.pos > 0) & (fe.text[fe.pos - 1] # " ") DO DEC(fe.pos) END;
    FESkipFixed(fe, 1);
    RETURN feStay
  ELSIF (k = TUI.KEnd) OR (k = KCtrlF) THEN
    WHILE (fe.pos < fe.width - 1) & (fe.text[fe.pos] # " ") DO INC(fe.pos) END;
    WHILE (fe.pos < fe.width - 1) & (fe.text[fe.pos] = " ") DO INC(fe.pos) END;
    RETURN feStay
  ELSIF (k = TUI.KDel) OR (k = KCtrlG) THEN
    IF fixed THEN fe.text[fe.pos] := " "
    ELSE
      FOR i := fe.pos TO fe.width - 2 DO fe.text[i] := fe.text[i + 1] END;
      fe.text[fe.width - 1] := " "
    END;
    fe.changed := TRUE; RETURN feStay
  ELSIF k = TUI.KBackspace THEN
    IF fe.pos > 0 THEN
      DEC(fe.pos); FESkipFixed(fe, -1);
      IF fixed OR ~insMode THEN fe.text[fe.pos] := " "
      ELSE
        FOR i := fe.pos TO fe.width - 2 DO fe.text[i] := fe.text[i + 1] END;
        fe.text[fe.width - 1] := " "
      END;
      fe.changed := TRUE
    END;
    RETURN feStay
  ELSIF k = KCtrlY THEN
    FOR i := 0 TO fe.width - 1 DO IF ~FixedPos(fe, i) THEN fe.text[i] := " " END END;
    fe.pos := 0; FESkipFixed(fe, 1); fe.changed := TRUE;
    RETURN feStay
  ELSIF k = KCtrlT THEN
    i := fe.pos;
    WHILE (i < fe.width) & (fe.text[i] # " ") DO INC(i) END;
    WHILE (i < fe.width) & (fe.text[i] = " ") DO INC(i) END;
    WHILE i > fe.pos DO
      Strings.Delete(fe.text, fe.pos, 1); DEC(i)
    END;
    PadR(fe.text, fe.width); fe.changed := TRUE;
    RETURN feStay
  ELSIF k = KCtrlV THEN insMode := ~insMode; RETURN feStay
  ELSIF (k = TUI.KEnter) OR (k = TUI.KDown) OR (k = KCtrlX) OR (k = TUI.KTab) THEN RETURN feNext
  ELSIF (k = TUI.KUp) OR (k = KCtrlE) THEN RETURN fePrev
  ELSIF (k >= " ") & (k < 7FX) THEN
    c := k;
    IF ~CharOK(fe, fe.pos, c) THEN Bell; RETURN feStay END;
    IF (fe.t = TN) & ~fe.changed & (fe.pos = 0) THEN
      (* first keystroke in a number replaces it *)
      FOR i := 0 TO fe.width - 1 DO fe.text[i] := " " END
    END;
    IF insMode & ~fixed THEN
      FOR i := fe.width - 1 TO fe.pos + 1 BY -1 DO fe.text[i] := fe.text[i - 1] END
    END;
    fe.text[fe.pos] := c; fe.changed := TRUE;
    IF fe.pos >= fe.width - 1 THEN
      IF setConfirm THEN Bell; RETURN feStay END;
      Bell; RETURN feNext
    END;
    INC(fe.pos); FESkipFixed(fe, 1);
    IF FixedPos(fe, fe.pos) & (fe.pos >= fe.width - 1) THEN RETURN feNext END;
    RETURN feStay
  END;
  RETURN feOther
END FEKey;

(* draw an edit field, horizontally scrolled to fit w cells *)
PROCEDURE FEDraw(VAR fe: FieldEd; x, y, w: INTEGER; active: BOOLEAN);
VAR s: Str; i: INTEGER;
BEGIN
  IF w > fe.width THEN w := fe.width END;
  IF fe.pos < fe.scroll THEN fe.scroll := fe.pos END;
  IF fe.pos >= fe.scroll + w THEN fe.scroll := fe.pos - w + 1 END;
  FOR i := 0 TO w - 1 DO s[i] := fe.text[fe.scroll + i] END;
  s[w] := 0X;
  IF setDelimiters THEN TUI.PutCell(x - 1, y, delimL, cFg, cBg); TUI.PutCell(x + w, y, delimR, cFg, cBg) END;
  IF setIntensity OR active THEN PutS(x, y, s, TRUE) ELSE PutS(x, y, s, FALSE) END
END FEDraw;

PROCEDURE FECursorX(VAR fe: FieldEd; x: INTEGER): INTEGER;
BEGIN RETURN x + fe.pos - fe.scroll END FECursorX;

(* ---- field <-> edit text ---- *)

PROCEDURE FieldEditWidth(a, f: INTEGER): INTEGER;
BEGIN
  CASE areas[a].db.fields[f].type OF
    "D": IF setCentury THEN RETURN 10 ELSE RETURN 8 END
  | "M": RETURN 4
  ELSE RETURN areas[a].db.fields[f].len
  END
END FieldEditWidth;

PROCEDURE FieldToText(a, f: INTEGER; VAR t: ARRAY OF CHAR);
VAR v: Value;
BEGIN
  CASE areas[a].db.fields[f].type OF
    "D": GetFieldVal(a, f, v); DateStr(v.d, t)
  | "L": GetRaw(a, f, t); t[0] := UpCh(t[0]); IF t[0] = "Y" THEN t[0] := "T" ELSIF t[0] = "N" THEN t[0] := "F" END
  | "M": IF MemoBlock(a, f) > 0 THEN Cpy("MEMO", t) ELSE Cpy("memo", t) END
  ELSE GetRaw(a, f, t)
  END
END FieldToText;

(* store edit text; FALSE (with message) when invalid *)
PROCEDURE TextToField(a, f: INTEGER; t: ARRAY OF CHAR): BOOLEAN;
VAR v: Value; x: REAL; d, j: INTEGER; s: Str;
BEGIN
  CASE areas[a].db.fields[f].type OF
    "N", "F":
      Cpy(t, s); Trim(s);
      ScanNum(s, x, d);
      SetNum(v, x, 10, 0); PutFieldVal(a, f, v)
  | "D":
      Cpy(t, s); j := 0;
      FOR d := 0 TO SLen(s) - 1 DO IF IsDigit(s[d]) THEN INC(j) END END;
      IF j = 0 THEN SetDate(v, 0); PutFieldVal(a, f, v)
      ELSE
        d := ParseDate(s);
        IF d = 0 THEN FSMessage("Invalid date. (Press SPACE)"); RETURN FALSE END;
        SetDate(v, d); PutFieldVal(a, f, v)
      END
  | "L":
      IF (UpCh(t[0]) = "T") OR (UpCh(t[0]) = "Y") THEN PutRaw(a, f, "T")
      ELSIF t[0] = " " THEN PutRaw(a, f, " ")
      ELSE PutRaw(a, f, "F")
      END
  | "M":
  ELSE PutRaw(a, f, t)
  END;
  err := FALSE;
  RETURN TRUE
END TextToField;

(* field list for EDIT/BROWSE/APPEND: FIELDS clause, SET FIELDS or all *)
PROCEDURE FormFields(VAR el: ExprList; VAR fr: ARRAY OF FieldRef; VAR n: INTEGER);
VAR i: INTEGER;
BEGIN
  n := 0;
  IF el.n > 0 THEN
    FOR i := 0 TO el.n - 1 DO
      IF el.e[i].kind = nField THEN fr[n].area := el.e[i].area; fr[n].fld := el.e[i].fld; INC(n) END
    END
  ELSIF setFieldsOn & (nFieldList > 0) THEN
    FOR i := 0 TO nFieldList - 1 DO fr[n] := fieldList[i]; INC(n) END
  ELSE
    FOR i := 0 TO areas[cur].db.numFields - 1 DO fr[n].area := cur; fr[n].fld := i; INC(n) END
  END
END FormFields;

(* ---- the cursor-movement help box shown at the top (SET MENU ON) ---- *)

PROCEDURE DrawEditMenu(browse: BOOLEAN): INTEGER;  (* rows used *)
VAR w: INTEGER;
BEGIN
  IF ~setMenu THEN RETURN 0 END;
  w := TUI.Cols; IF w > 80 THEN w := 80 END;
  TUI.DrawBox(1, 1, w, 6, cFg, cBg);
  PutHi(3, 2, "CURSOR  <-- -->");    PutHi(22, 2, "UP    DOWN");
  PutHi(37, 2, "DELETE");             PutHi(56, 2, "Insert Mode:  Ctrl-V");
  PutS(3, 3, "Char:  ^S  ^D", FALSE); PutS(22, 3, "Field: ^E  ^X", FALSE);
  PutS(37, 3, "Char:   Del ^G", FALSE); PutS(56, 3, "Exit/Save:    ^W", FALSE);
  PutS(3, 4, "Word:  ^A  ^F", FALSE);
  IF browse THEN PutS(22, 4, "Pan:  ^<- ^->", FALSE) ELSE PutS(22, 4, "Page:  PgUp PgDn", FALSE) END;
  PutS(37, 4, "Field:  ^Y", FALSE); PutS(56, 4, "Abort:        Esc", FALSE);
  PutS(3, 5, "Home/End: word", FALSE); PutS(22, 5, "Memo:  ^Home", FALSE);
  PutS(37, 5, "Record: ^U", FALSE);  PutS(56, 5, "Menu:         F1", FALSE);
  RETURN 6
END DrawEditMenu;

(* ====================================================================
   APPEND / EDIT / INSERT -- the record form
   ==================================================================== *)

CONST
  fmEdit = 0; fmAppend = 1;

VAR
  formFe: ARRAY DBF.MaxFields OF FieldEd;
  formRef: ARRAY DBF.MaxFields OF FieldRef;
  formN: INTEGER;

PROCEDURE FormLoad;
VAR i: INTEGER; t: Str;
BEGIN
  FOR i := 0 TO formN - 1 DO
    FieldToText(formRef[i].area, formRef[i].fld, t);
    FEInit(formFe[i], t, FieldEditWidth(formRef[i].area, formRef[i].fld),
           areas[formRef[i].area].db.fields[formRef[i].fld].type, "")
  END
END FormLoad;

PROCEDURE FormChanged(): BOOLEAN;
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO formN - 1 DO IF formFe[i].changed THEN RETURN TRUE END END;
  RETURN FALSE
END FormChanged;

(* write the form back into the record(s); isNew appends *)
PROCEDURE FormSave(isNew: BOOLEAN): BOOLEAN;
VAR i, a: INTEGER;
BEGIN
  IF ~isNew THEN BeginChange(cur) END;
  FOR i := 0 TO formN - 1 DO
    a := formRef[i].area;
    IF formFe[i].changed & (areas[a].db.fields[formRef[i].fld].type # "M") THEN
      IF (a # cur) & (areas[a].rec <= areas[a].db.numRecs) THEN BeginChange(a) END;
      IF ~TextToField(a, formRef[i].fld, formFe[i].text) THEN RETURN FALSE END;
      IF (a # cur) & (areas[a].rec <= areas[a].db.numRecs) THEN EndChange(a) END
    END
  END;
  IF isNew THEN AppendBuf(cur) ELSE EndChange(cur) END;
  RETURN TRUE
END FormSave;

PROCEDURE FormDraw(mode: ARRAY OF CHAR; cf: INTEGER; VAR top: INTEGER; isNew: BOOLEAN);
VAR y0, rows, i, y, x, w: INTEGER; name, t2: Str;
BEGIN
  FSClear;
  y0 := DrawEditMenu(FALSE) + 2;
  rows := scrH - y0;
  IF rows < 1 THEN rows := 1 END;
  IF cf < top THEN top := cf END;
  IF cf >= top + rows THEN top := cf - rows + 1 END;
  x := 13;
  FOR i := top TO formN - 1 DO
    y := y0 + i - top;
    IF y < y0 + rows THEN
      Cpy(areas[formRef[i].area].db.fields[formRef[i].fld].name, name);
      IF formRef[i].area # cur THEN
        Cpy(areas[formRef[i].area].alias, name); Append("->", name);
        Append(areas[formRef[i].area].db.fields[formRef[i].fld].name, name)
      END;
      IF SLen(name) > 11 THEN x := MaxI(x, SLen(name) + 2) END;
      PutS(2, y, name, FALSE)
    END
  END;
  FOR i := top TO formN - 1 DO
    y := y0 + i - top;
    IF y < y0 + rows THEN
      w := TUI.Cols - x - 2;
      FEDraw(formFe[i], x, y, w, i = cf)
    END
  END;
  ScreenSize;
  FSBars(mode);
  IF isNew THEN
    TUI.FillRect(1, scrH + 1, TUI.Cols, 1, " ", cRevFg, cRevBg);
    Cpy(modeName, t2); Cpy(mode, modeName);
    StatusText(name);
    Cpy(t2, modeName);
    PutBar(1, scrH + 1, name, cRevFg, cRevBg)
  END;
  w := TUI.Cols - x - 2;
  FSFlush(FECursorX(formFe[cf], x), y0 + cf - top, TRUE)
END FormDraw;

(* open the memo editor for field f of the current record *)
PROCEDURE EditMemoField(a, f: INTEGER);
VAR text: ARRAY MaxMemo OF CHAR; title, nm: Str; saved: BOOLEAN; tb: TextBuf;
BEGIN
  ReadMemo(a, f, text);
  TextToBuf(text, tb);
  Cpy("Edit: ", title); Cpy(areas[a].db.fields[f].name, nm); Append(nm, title);
  EditText(title, tb, saved);
  IF saved THEN
    BufToText(tb, text);
    IF areas[a].rec <= areas[a].db.numRecs THEN BeginChange(a) END;
    WriteMemo(a, f, text);
    IF areas[a].rec <= areas[a].db.numRecs THEN EndChange(a) END
  END
END EditMemoField;

PROCEDURE FormRun(mode: INTEGER; VAR el: ExprList);
VAR
  cf, top, r: INTEGER; k: CHAR; isNew, done, moved: BOOLEAN; title: Str;
  action: INTEGER;  (* 0 stay, 1 next rec, -1 prev rec, 2 exit save, 3 exit abandon *)
  carry: ARRAY MaxRecBuf OF CHAR;
BEGIN
  FormFields(el, formRef, formN);
  IF formN = 0 THEN RETURN END;
  isNew := mode = fmAppend;
  IF mode = fmAppend THEN Cpy("APPEND", title) ELSE Cpy("EDIT", title) END;
  IF isNew THEN
    EnsureRec(cur);
    Cpy(areas[cur].buf, carry);
    StartNewRec(cur);
    IF setCarry & (areas[cur].db.numRecs > 0) THEN Cpy(carry, areas[cur].buf); areas[cur].buf[0] := " " END
  ELSIF areas[cur].eof THEN
    GoBottom(cur);
    IF areas[cur].eof THEN RETURN END
  END;
  FormLoad;
  cf := 0; top := 0; done := FALSE;
  WHILE ~done DO
    FormDraw(title, cf, top, isNew);
    k := GetKey();
    action := 0;
    IF k = 0X THEN
    ELSIF k = TUI.KF1 THEN setMenu := ~setMenu
    ELSIF (k = KCtrlW) OR (k = TUI.KCtrlEnd) THEN action := 2
    ELSIF (k = TUI.KEsc) OR (k = KCtrlQ) THEN action := 3
    ELSIF (k = TUI.KPgDn) OR (k = KCtrlC) THEN action := 1
    ELSIF (k = TUI.KPgUp) OR (k = KCtrlR) THEN action := -1
    ELSIF k = KCtrlU THEN
      IF ~isNew THEN
        EnsureRec(cur);
        IF areas[cur].buf[0] = "*" THEN areas[cur].buf[0] := " " ELSE areas[cur].buf[0] := "*" END;
        DBF.WriteRec(areas[cur].db, areas[cur].rec - 1, areas[cur].buf)
      END
    ELSIF k = TUI.KCtrlHome THEN
      IF areas[formRef[cf].area].db.fields[formRef[cf].fld].type = "M" THEN
        EditMemoField(formRef[cf].area, formRef[cf].fld);
        FieldToText(formRef[cf].area, formRef[cf].fld, formFe[cf].text);
        IF isNew THEN formFe[cf].changed := TRUE END
      END
    ELSIF (k = TUI.KEnter) & isNew & (cf = 0) & ~FormChanged() THEN
      action := 3   (* Enter on an empty new record ends APPEND *)
    ELSE
      r := FEKey(formFe[cf], k);
      IF (r = feNext) OR (r = feRightOut) THEN
        IF cf < formN - 1 THEN INC(cf) ELSE action := 1 END
      ELSIF (r = fePrev) OR (r = feLeftOut) THEN
        IF cf > 0 THEN DEC(cf);
          IF r = feLeftOut THEN formFe[cf].pos := formFe[cf].width - 1 END
        ELSE action := -1 END
      END
    END;
    (* carry out record-level actions *)
    IF (action = 1) OR (action = -1) OR (action = 2) THEN
      IF FormChanged() OR (isNew & (action # 1) & FormChanged()) THEN
        IF ~FormSave(isNew) THEN action := 0
        ELSE isNew := FALSE
        END
      ELSIF isNew & (action = 1) THEN
        action := 3   (* leaving an untouched new record ends APPEND *)
      END
    END;
    CASE action OF
      1:
        IF mode = fmAppend THEN
          EnsureRec(cur); Cpy(areas[cur].buf, carry);
          StartNewRec(cur);
          IF setCarry THEN Cpy(carry, areas[cur].buf); areas[cur].buf[0] := " " END;
          isNew := TRUE; FormLoad; cf := 0; top := 0
        ELSIF (editArea = cur) & (editLeft >= 0) & (editLeft <= 1) THEN
          done := TRUE   (* NEXT n used up *)
        ELSE
          r := areas[cur].rec;
          moved := Step(cur, 1);
          IF moved & (editArea = cur) & (editWhile # NIL) & ~EvalBool(editWhile) THEN
            err := FALSE; SetRec(cur, r); done := TRUE
          ELSIF ~moved THEN
            GoBottom(cur); done := TRUE
          ELSE
            IF (editArea = cur) & (editLeft > 0) THEN DEC(editLeft) END;
            FormLoad; cf := 0; top := 0
          END
        END
    | -1:
        IF isNew THEN
          GoBottom(cur); isNew := FALSE;
          IF areas[cur].eof THEN done := TRUE ELSE FormLoad; cf := 0 END
        ELSE
          r := areas[cur].rec;
          moved := Step(cur, -1);
          IF moved & (editArea = cur) & (editWhile # NIL) & ~EvalBool(editWhile) THEN
            err := FALSE; SetRec(cur, r)
          ELSIF moved & (editArea = cur) & (editLeft >= 0) THEN INC(editLeft)
          END;
          FormLoad; cf := 0; top := 0
        END
    | 2: done := TRUE
    | 3:
        done := TRUE;
        IF isNew THEN GoBottom(cur) END
    ELSE
    END
  END;
  areas[cur].bufRec := -1; EnsureRec(cur);
  ConClear;
  TUI.InvalidateFront
END FormRun;

PROCEDURE DoEdit;
VAR c: Clauses; el: ExprList; n: Node; s: Scope;
BEGIN
  IF ~NeedDb() THEN RETURN END;
  IF batch THEN Err("Full-screen commands need the interactive mode."); RETURN END;
  InitClauses(c); el.n := 0;
  IF (tk = tNum) THEN n := Expr(); c.scope := scRecord; c.n := EvalInt(n) END;
  WHILE (tk # tEOF) & ~err DO
    IF IsKw("FIELDS") THEN Next; ParseExprList(el)
    ELSIF OneClause(c) THEN
    ELSE Err("Unrecognized phrase/keyword in command.")
    END
  END;
  IF err THEN RETURN END;
  IF c.scope = scRecord THEN
    IF (c.n < 1) OR (c.n > areas[cur].db.numRecs) THEN Err("Record is out of range."); RETURN END;
    SetRec(cur, c.n)
  END;
  IF areas[cur].db.numRecs = 0 THEN Err("End of file encountered."); RETURN END;
  IF (c.forN # NIL) OR (c.whileN # NIL) OR (c.scope = scNext) OR (c.scope = scAll) OR (c.scope = scRest) THEN
    (* position on the first record in scope, then let FormRun keep to it *)
    ScopeStart(s, c, scRest);
    IF err THEN RETURN END;
    IF ~ScopeOK(s) THEN RETURN END;   (* nothing in scope: back to the prompt *)
    editArea := cur; editFor := c.forN; editWhile := c.whileN;
    IF c.scope = scNext THEN editLeft := s.left ELSE editLeft := -1 END;
    FormRun(fmEdit, el);
    editArea := -1; editFor := NIL; editWhile := NIL; editLeft := -1
  ELSE
    FormRun(fmEdit, el)
  END
END DoEdit;

PROCEDURE DoAppend;
VAR el: ExprList;
BEGIN
  IF ~NeedDb() THEN RETURN END;
  IF batch THEN Err("Full-screen commands need the interactive mode."); RETURN END;
  el.n := 0;
  FormRun(fmAppend, el)
END DoAppend;

(* INSERT [BEFORE]: a new record placed after (or before) the current one *)
PROCEDURE DoInsert(before: BOOLEAN);
VAR el: ExprList;
BEGIN
  IF before THEN Next END;
  IF ~NeedDb() THEN RETURN END;
  IF batch THEN Err("Full-screen commands need the interactive mode."); RETURN END;
  DoInsertBlank(before);
  IF err THEN RETURN END;
  el.n := 0;
  FormRun(fmEdit, el)
END DoInsert;

(* ====================================================================
   BROWSE
   ==================================================================== *)

PROCEDURE StepMatch(a, dir: INTEGER; forN: Node): BOOLEAN;
BEGIN
  LOOP
    IF ~Step(a, dir) THEN RETURN FALSE END;
    IF (forN = NIL) OR EvalBool(forN) THEN RETURN TRUE END
  END
END StepMatch;

PROCEDURE DoBrowse;
VAR
  el: ExprList; fr: ARRAY DBF.MaxFields OF FieldRef; nf, i, j, k2, x, y, y0, rows, cw: INTEGER;
  colW: ARRAY DBF.MaxFields OF INTEGER;
  recs: ARRAY MaxSR OF INTEGER; nrec, cr, cc, left, freeze, topRec: INTEGER;
  fe: FieldEd; k: CHAR; done, editing, noAppend, ok: BOOLEAN; t, line: Str;
  r: INTEGER; n, forN: Node;
  lock, maxW, lockX, idx: INTEGER;

BEGIN
  IF ~NeedDb() THEN RETURN END;
  IF batch THEN Err("Full-screen commands need the interactive mode."); RETURN END;
  el.n := 0; noAppend := FALSE; freeze := -1; forN := NIL; lock := 0; maxW := 0;
  WHILE (tk # tEOF) & ~err DO
    IF IsKw("FIELDS") THEN Next; ParseExprList(el)
    ELSIF IsKw("NOAPPEND") THEN Next; noAppend := TRUE
    ELSIF IsKw("NOFOLLOW") OR IsKw("NOMENU") THEN Next
    ELSIF IsKw("LOCK") THEN Next; n := Expr(); lock := MaxI(EvalInt(n), 0)
    ELSIF IsKw("WIDTH") THEN Next; n := Expr(); maxW := MaxI(EvalInt(n), 0)
    ELSIF IsKw("FREEZE") THEN Next; freeze := FieldIdx(cur, tkStr); Next
    ELSIF IsKw("FOR") THEN Next; forN := Expr()
    ELSE Err("Unrecognized phrase/keyword in command.")
    END
  END;
  IF err THEN RETURN END;
  FormFields(el, fr, nf);
  IF nf = 0 THEN RETURN END;
  FOR i := 0 TO nf - 1 DO
    colW[i] := MaxI(FieldEditWidth(fr[i].area, fr[i].fld),
                    SLen(areas[fr[i].area].db.fields[fr[i].fld].name));
    IF colW[i] > TUI.Cols - 4 THEN colW[i] := TUI.Cols - 4 END;
    (* WIDTH n caps the displayed width; the cell scrolls while editing *)
    IF (maxW > 0) & (colW[i] > maxW) THEN colW[i] := maxW END
  END;
  (* LOCK n: the first n columns stay put while the rest scroll *)
  IF lock > nf - 1 THEN lock := nf - 1 END;
  lockX := 1;
  FOR i := 0 TO lock - 1 DO INC(lockX, colW[i] + 1) END;
  IF lockX > TUI.Cols DIV 2 THEN lock := 0; lockX := 1 END;
  IF freeze >= 0 THEN
    FOR i := 0 TO nf - 1 DO IF (fr[i].area = cur) & (fr[i].fld = freeze) THEN freeze := i END END
  END;
  IF areas[cur].eof THEN GoTop(cur) END;
  IF areas[cur].db.numRecs = 0 THEN
    IF noAppend THEN Err("End of file encountered."); RETURN END;
    AppendBlank(cur)
  END;
  IF (forN # NIL) & ~EvalBool(forN) THEN IF ~StepMatch(cur, 1, forN) THEN END END;
  topRec := areas[cur].rec;
  cr := 0; cc := 0; left := 0; done := FALSE; editing := FALSE;
  IF freeze >= 0 THEN cc := freeze END;
  WHILE ~done DO
    (* lay out the rows starting at topRec *)
    ScreenSize;
    y0 := DrawEditMenuRows();
    rows := scrH - y0 - 2;
    IF rows < 1 THEN rows := 1 END;
    r := areas[cur].rec;
    SetRec(cur, topRec);
    nrec := 0;
    WHILE (nrec < rows) & ~areas[cur].eof DO
      recs[nrec] := areas[cur].rec; INC(nrec);
      IF ~StepMatch(cur, 1, forN) THEN END
    END;
    IF cr >= nrec THEN cr := nrec - 1 END;
    IF cr < 0 THEN cr := 0 END;
    IF nrec = 0 THEN done := TRUE
    ELSE
      SetRec(cur, recs[cr]);
      IF ~editing THEN
        FieldToText(fr[cc].area, fr[cc].fld, t);
        FEInit(fe, t, FieldEditWidth(fr[cc].area, fr[cc].fld),
               areas[fr[cc].area].db.fields[fr[cc].fld].type, "");
        editing := TRUE
      END;
      (* make the current column visible *)
      IF left < lock THEN left := lock END;
      IF (cc >= lock) & (cc < left) THEN left := cc END;
      IF cc >= lock THEN
        LOOP
          x := lockX; i := left;
          WHILE (i <= cc) & (x + colW[i] <= TUI.Cols) DO INC(x, colW[i] + 1); INC(i) END;
          IF (i > cc) OR (left >= cc) THEN EXIT END;
          INC(left)
        END
      END;
      (* draw: locked columns, then the scrolled ones from left *)
      FSClear;
      IF DrawEditMenu(TRUE) > 0 THEN END;
      x := 1; idx := 0;
      LOOP
        IF idx < lock THEN i := idx ELSE i := left + idx - lock END;
        IF (i >= nf) OR (x > TUI.Cols) THEN EXIT END;
        INC(idx);
        Cpy(areas[fr[i].area].db.fields[fr[i].fld].name, t);
        IF fr[i].area # cur THEN Cpy(areas[fr[i].area].alias, line); Append("->", line); Append(t, line); Cpy(line, t) END;
        t[colW[i]] := 0X; PadR(t, colW[i]);
        PutHi(x, y0 + 1, t);
        FOR j := 0 TO nrec - 1 DO
          SetRec(cur, recs[j]);
          IF (j = cr) & (i = cc) THEN
            FEDraw(fe, x, y0 + 2 + j, colW[i], TRUE)
          ELSE
            FieldToText(fr[i].area, fr[i].fld, t);
            t[colW[i]] := 0X; PadR(t, colW[i]);
            PutS(x, y0 + 2 + j, t, j = cr)
          END;
          IF x + colW[i] <= TUI.Cols THEN TUI.PutCell(x + colW[i], y0 + 2 + j, TUI.BoxV, cFg, cBg) END
        END;
        IF x + colW[i] <= TUI.Cols THEN TUI.PutCell(x + colW[i], y0 + 1, TUI.BoxV, cFg, cBg) END;
        INC(x, colW[i] + 1)
      END;
      SetRec(cur, recs[cr]);
      FSBars("BROWSE");
      IF cc < lock THEN x := 1; FOR i := 0 TO cc - 1 DO INC(x, colW[i] + 1) END
      ELSE x := lockX; FOR i := left TO cc - 1 DO INC(x, colW[i] + 1) END
      END;
      FSFlush(FECursorX(fe, x), y0 + 2 + cr, TRUE);
      k := GetKey();
      (* commit the cell when leaving it *)
      k2 := FEKey(fe, k);
      IF (k2 = feOther) OR (k2 = feNext) OR (k2 = fePrev) OR (k2 = feLeftOut) OR (k2 = feRightOut) THEN
        IF fe.changed & (k # TUI.KEsc) & (areas[fr[cc].area].db.fields[fr[cc].fld].type # "M") THEN
          BeginChange(fr[cc].area);
          ok := TextToField(fr[cc].area, fr[cc].fld, fe.text);
          EndChange(fr[cc].area);
          topRec := recs[0];
          IF areas[cur].order > 0 THEN topRec := areas[cur].rec; cr := 0 END
        END;
        editing := FALSE
      END;
      IF (k2 = feNext) & (k = TUI.KEnter) OR (k2 = feRightOut) OR (k = TUI.KTab) & (k2 = feNext) THEN
        IF (cc < nf - 1) & (freeze < 0) THEN INC(cc) END   (* FREEZE keeps to one field *)
      ELSIF k2 = feLeftOut THEN
        IF (cc > 0) & (freeze < 0) THEN DEC(cc) END
      ELSIF (k2 = feNext) THEN   (* down *)
        IF cr < nrec - 1 THEN INC(cr)
        ELSE
          SetRec(cur, recs[cr]);
          IF StepMatch(cur, 1, forN) THEN
            topRec := recs[MinI(1, nrec - 1)]; IF nrec = 1 THEN topRec := areas[cur].rec END
          ELSIF ~noAppend THEN
            IF FSAsk("Add new records? (Y/N)") THEN
              AppendBlank(cur);
              IF nrec >= rows THEN topRec := recs[1] END;
              cr := MinI(nrec, rows - 1)
            END
          END
        END
      ELSIF k2 = fePrev THEN
        IF cr > 0 THEN DEC(cr)
        ELSE
          SetRec(cur, recs[0]);
          IF StepMatch(cur, -1, forN) THEN topRec := areas[cur].rec END
        END
      ELSIF k2 = feOther THEN
        IF (k = TUI.KEsc) OR (k = KCtrlQ) OR (k = KCtrlW) OR (k = TUI.KCtrlEnd) THEN done := TRUE
        ELSIF k = TUI.KF1 THEN setMenu := ~setMenu
        ELSIF (k = TUI.KCtrlRight) OR (k = KCtrlB) THEN IF (cc < nf - 1) & (freeze < 0) THEN INC(cc) END
        ELSIF (k = TUI.KCtrlLeft) OR (k = KCtrlZ) THEN IF (cc > 0) & (freeze < 0) THEN DEC(cc) END
        ELSIF (k = TUI.KPgDn) OR (k = KCtrlC) THEN
          SetRec(cur, recs[nrec - 1]);
          IF StepMatch(cur, 1, forN) THEN topRec := areas[cur].rec; cr := 0 ELSE cr := nrec - 1 END
        ELSIF (k = TUI.KPgUp) OR (k = KCtrlR) THEN
          SetRec(cur, recs[0]);
          FOR i := 1 TO rows DO IF ~areas[cur].bof THEN IF StepMatch(cur, -1, forN) THEN END END END;
          topRec := areas[cur].rec; cr := 0
        ELSIF k = KCtrlU THEN
          SetRec(cur, recs[cr]); EnsureRec(cur);
          IF areas[cur].buf[0] = "*" THEN areas[cur].buf[0] := " " ELSE areas[cur].buf[0] := "*" END;
          DBF.WriteRec(areas[cur].db, areas[cur].rec - 1, areas[cur].buf)
        ELSIF k = TUI.KCtrlHome THEN
          IF areas[fr[cc].area].db.fields[fr[cc].fld].type = "M" THEN
            SetRec(cur, recs[cr]); EditMemoField(fr[cc].area, fr[cc].fld)
          END
        END
      END;
      IF nrec > 0 THEN
        IF cr < nrec THEN SetRec(cur, recs[cr]) END
      END
    END
  END;
  areas[cur].bufRec := -1; EnsureRec(cur);
  ConClear;
  TUI.InvalidateFront
END DoBrowse;

PROCEDURE DrawEditMenuRows(): INTEGER;
BEGIN
  IF setMenu THEN RETURN 6 ELSE RETURN 0 END
END DrawEditMenuRows;

(* ====================================================================
   Text editor: MODIFY COMMAND / MODIFY FILE and memo fields
   WordStar-style keys as in the dBASE editor.
   ==================================================================== *)

PROCEDURE TextToBuf(text: ARRAY OF CHAR; VAR tb: TextBuf);
VAR i, j: INTEGER;
BEGIN
  NEW(tb); tb.n := 1; tb.l[0][0] := 0X;
  i := 0; j := 0;
  WHILE (i < LEN(text)) & (text[i] # 0X) DO
    IF text[i] = 0AX THEN
      tb.l[tb.n - 1][j] := 0X;
      IF tb.n < MaxTxtLn THEN INC(tb.n); j := 0; tb.l[tb.n - 1][0] := 0X END
    ELSIF (text[i] = 0DX) OR (text[i] = 8DX) THEN
    ELSIF j < 254 THEN
      tb.l[tb.n - 1][j] := text[i]; INC(j)
    END;
    INC(i)
  END;
  tb.l[tb.n - 1][j] := 0X
END TextToBuf;

PROCEDURE BufToText(tb: TextBuf; VAR text: ARRAY OF CHAR);
VAR i, j, k, n: INTEGER;
BEGIN
  n := tb.n;
  WHILE (n > 1) & (tb.l[n - 1][0] = 0X) DO DEC(n) END;
  k := 0;
  FOR i := 0 TO n - 1 DO
    j := 0;
    WHILE (tb.l[i][j] # 0X) & (k < LEN(text) - 3) DO text[k] := tb.l[i][j]; INC(k); INC(j) END;
    IF (i < n - 1) & (k < LEN(text) - 3) THEN text[k] := 0DX; text[k + 1] := 0AX; INC(k, 2) END
  END;
  text[k] := 0X;
  IF (n = 1) & (tb.l[0][0] = 0X) THEN text[0] := 0X END
END BufToText;

PROCEDURE LoadTextFile(path: ARRAY OF CHAR; VAR tb: TextBuf): BOOLEAN;
VAR f: Files.File; r: Files.Rider; line: Str; n, i: INTEGER;
BEGIN
  NEW(tb); tb.n := 0;
  f := Files.Old(path);
  IF f = NIL THEN tb.n := 1; tb.l[0][0] := 0X; RETURN FALSE END;
  Files.Set(r, f, 0);
  LOOP
    Files.ReadLine(r, line);
    IF r.eof & (line[0] = 0X) THEN EXIT END;
    n := SLen(line); IF (n > 0) & (line[n - 1] = 0DX) THEN line[n - 1] := 0X END;
    FOR i := 0 TO SLen(line) - 1 DO IF line[i] = 09X THEN line[i] := " " END END;
    IF line[0] = 1AX THEN EXIT END;
    IF tb.n < MaxTxtLn THEN Cpy(line, tb.l[tb.n]); INC(tb.n) END;
    IF r.eof THEN EXIT END
  END;
  Files.Close(f);
  IF tb.n = 0 THEN tb.n := 1; tb.l[0][0] := 0X END;
  RETURN TRUE
END LoadTextFile;

PROCEDURE SaveTextFile(path: ARRAY OF CHAR; tb: TextBuf): BOOLEAN;
VAR f: Files.File; r: Files.Rider; i, n: INTEGER;
BEGIN
  f := Files.New(path);
  IF f = NIL THEN RETURN FALSE END;
  Files.Set(r, f, 0);
  n := tb.n;
  WHILE (n > 1) & (tb.l[n - 1][0] = 0X) DO DEC(n) END;
  FOR i := 0 TO n - 1 DO WriteStr(r, tb.l[i]); Files.Write(r, 10) END;
  Files.Register(f); Files.Close(f);
  RETURN TRUE
END SaveTextFile;

(* one-line prompt on the message row of a full-screen mode *)
PROCEDURE FSPrompt(prompt: ARRAY OF CHAR; VAR s: ARRAY OF CHAR): BOOLEAN;
VAR fe: FieldEd; k: CHAR; r, y, x: INTEGER;
BEGIN
  y := TUI.Rows; x := SLen(prompt) + 2;
  FEInit(fe, s, MinI(60, TUI.Cols - x - 1), TC, "");
  fe.pos := SLen(s); IF fe.pos >= fe.width THEN fe.pos := fe.width - 1 END;
  LOOP
    TUI.FillRect(1, y, TUI.Cols, 1, " ", cFg, cBg);
    PutHi(1, y, prompt);
    FEDraw(fe, x, y, fe.width, TRUE);
    FSFlush(FECursorX(fe, x), y, TRUE);
    k := GetKey();
    IF k = TUI.KEsc THEN RETURN FALSE END;
    IF k = TUI.KEnter THEN Cpy(fe.text, s); RTrim(s); RETURN TRUE END;
    r := FEKey(fe, k)
  END
END FSPrompt;

PROCEDURE InsertLine(tb: TextBuf; at: INTEGER; s: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  IF tb.n >= MaxTxtLn THEN RETURN END;
  FOR i := tb.n TO at + 1 BY -1 DO Cpy(tb.l[i - 1], tb.l[i]) END;
  Cpy(s, tb.l[at]); INC(tb.n)
END InsertLine;

PROCEDURE DeleteLine(tb: TextBuf; at: INTEGER);
VAR i: INTEGER;
BEGIN
  IF tb.n <= 1 THEN tb.l[0][0] := 0X; RETURN END;
  FOR i := at TO tb.n - 2 DO Cpy(tb.l[i + 1], tb.l[i]) END;
  DEC(tb.n)
END DeleteLine;

VAR findStr: Str;

PROCEDURE FindIn(tb: TextBuf; VAR row, col: INTEGER; from: INTEGER): BOOLEAN;
VAR r, p: INTEGER; line, pat: Str;
BEGIN
  IF findStr[0] = 0X THEN RETURN FALSE END;
  Cpy(findStr, pat); Upper(pat);
  FOR r := row TO tb.n - 1 DO
    Cpy(tb.l[r], line); Upper(line);
    IF r = row THEN p := Strings.Pos(pat, line, from) ELSE p := Strings.Pos(pat, line) END;
    IF p >= 0 THEN row := r; col := p; RETURN TRUE END
  END;
  RETURN FALSE
END FindIn;

(* Edit tb full screen.  saved is TRUE if the user saved (^W / ^End). *)
PROCEDURE EditText(title: ARRAY OF CHAR; tb: TextBuf; VAR saved: BOOLEAN);
VAR
  row, col, top, left, y0, h, w, i, n, r, c: INTEGER; k, k2: CHAR;
  done, modified, prefixK: BOOLEAN; line, t, name, path: Str; other: TextBuf;
BEGIN
  saved := FALSE;
  IF batch THEN RETURN END;
  row := 0; col := 0; top := 0; left := 0; done := FALSE; modified := FALSE; prefixK := FALSE;
  WHILE ~done DO
    ScreenSize;
    FSClear;
    y0 := 1;
    IF setMenu THEN
      TUI.DrawBox(1, 1, MinI(TUI.Cols, 80), 5, cFg, cBg);
      PutHi(3, 2, "CURSOR  <-- -->     UP  DOWN      DELETE          Insert Mode:  ^V");
      PutS(3, 3, "Char:   ^S  ^D      Line: ^E ^X   Char:  Del ^G   Save:  ^W   Abort: Esc", FALSE);
      PutS(3, 4, "Word:   ^A  ^F      Page: PgUp/Dn Line:  ^Y  ^N   Find: ^KF ^KL  File: ^KR ^KW", FALSE);
      y0 := 6
    END;
    h := scrH - y0;
    IF h < 3 THEN h := 3 END;
    w := TUI.Cols;
    IF row >= tb.n THEN row := tb.n - 1 END;
    IF row < 0 THEN row := 0 END;
    n := SLen(tb.l[row]);
    IF col > n THEN col := n END;
    IF row < top THEN top := row END;
    IF row >= top + h THEN top := row - h + 1 END;
    IF col < left THEN left := col END;
    IF col >= left + w - 1 THEN left := col - w + 2 END;
    FOR i := 0 TO h - 1 DO
      IF top + i < tb.n THEN
        Sub(tb.l[top + i], left, w, line);
        PutS(1, y0 + i, line, FALSE)
      END
    END;
    Cpy(title, fsMsg);
    IF prefixK THEN Append("   ^K", fsMsg) END;
    Cpy("Line: ", fsNav); AppendInt(row + 1, fsNav); Append("  Col: ", fsNav); AppendInt(col + 1, fsNav);
    IF modified THEN Append("  (modified)", fsNav) END;
    FSBars("MODIFY");
    fsMsg[0] := 0X; fsNav[0] := 0X;
    FSFlush(col - left + 1, y0 + row - top, TRUE);
    k := GetKey();
    IF prefixK THEN
      prefixK := FALSE;
      k2 := UpCh(k);
      IF k2 < " " THEN k2 := CHR(ORD(k2) + 64) END;
      IF k2 = "F" THEN
        IF FSPrompt("Find:", findStr) THEN
          r := row; c := col;
          IF FindIn(tb, r, c, col + 1) THEN row := r; col := c ELSE FSMessage("Not found") END
        END
      ELSIF k2 = "L" THEN
        r := row; c := col;
        IF FindIn(tb, r, c, col + 1) THEN row := r; col := c ELSE FSMessage("Not found") END
      ELSIF k2 = "R" THEN
        name[0] := 0X;
        IF FSPrompt("Read file:", name) & (name[0] # 0X) THEN
          IF FindFile(name, "", path) & LoadTextFile(path, other) THEN
            FOR i := 0 TO other.n - 1 DO InsertLine(tb, row + 1 + i, other.l[i]) END;
            modified := TRUE
          ELSE FSMessage("File does not exist.")
          END
        END
      ELSIF k2 = "W" THEN
        name[0] := 0X;
        IF FSPrompt("Write to file:", name) & (name[0] # 0X) THEN
          NewPath(name, ".txt", path);
          IF ~SaveTextFile(path, tb) THEN FSMessage("Unable to create file.") END
        END
      ELSIF k2 = "Q" THEN
      END
    ELSIF k = 0X THEN
    ELSIF (k = TUI.KUp) OR (k = KCtrlE) THEN DEC(row)
    ELSIF (k = TUI.KDown) OR (k = KCtrlX) THEN INC(row)
    ELSIF (k = TUI.KLeft) OR (k = KCtrlS) THEN
      IF col > 0 THEN DEC(col) ELSIF row > 0 THEN DEC(row); col := SLen(tb.l[row]) END
    ELSIF (k = TUI.KRight) OR (k = KCtrlD) THEN
      IF col < n THEN INC(col) ELSIF row < tb.n - 1 THEN INC(row); col := 0 END
    ELSIF k = TUI.KHome THEN col := 0
    ELSIF k = TUI.KEnd THEN col := n
    ELSIF k = KCtrlA THEN
      IF col > 0 THEN DEC(col) END;
      WHILE (col > 0) & (tb.l[row][col] = " ") DO DEC(col) END;
      WHILE (col > 0) & (tb.l[row][col - 1] # " ") DO DEC(col) END
    ELSIF k = KCtrlF THEN
      WHILE (col < n) & (tb.l[row][col] # " ") DO INC(col) END;
      WHILE (col < n) & (tb.l[row][col] = " ") DO INC(col) END
    ELSIF (k = TUI.KPgUp) OR (k = KCtrlR) THEN DEC(row, h - 1); DEC(top, h - 1); IF top < 0 THEN top := 0 END
    ELSIF (k = TUI.KPgDn) OR (k = KCtrlC) THEN INC(row, h - 1); INC(top, h - 1)
    ELSIF k = TUI.KCtrlHome THEN row := 0; col := 0
    ELSIF k = KCtrlK THEN prefixK := TRUE
    ELSIF k = KCtrlV THEN insMode := ~insMode
    ELSIF k = TUI.KF1 THEN setMenu := ~setMenu
    ELSIF k = TUI.KEnter THEN
      IF insMode OR (row = tb.n - 1) THEN
        Sub(tb.l[row], col, 255, t); tb.l[row][col] := 0X;
        InsertLine(tb, row + 1, t); modified := TRUE
      END;
      INC(row); col := 0
    ELSIF k = KCtrlN THEN
      Sub(tb.l[row], col, 255, t); tb.l[row][col] := 0X;
      InsertLine(tb, row + 1, t); modified := TRUE
    ELSIF k = TUI.KBackspace THEN
      IF col > 0 THEN Strings.Delete(tb.l[row], col - 1, 1); DEC(col); modified := TRUE
      ELSIF row > 0 THEN
        col := SLen(tb.l[row - 1]);
        IF col + n < 255 THEN Append(tb.l[row], tb.l[row - 1]); DeleteLine(tb, row); DEC(row); modified := TRUE END
      END
    ELSIF (k = TUI.KDel) OR (k = KCtrlG) THEN
      IF col < n THEN Strings.Delete(tb.l[row], col, 1); modified := TRUE
      ELSIF row < tb.n - 1 THEN
        IF n + SLen(tb.l[row + 1]) < 255 THEN Append(tb.l[row + 1], tb.l[row]); DeleteLine(tb, row + 1); modified := TRUE END
      END
    ELSIF k = KCtrlY THEN DeleteLine(tb, row); col := 0; modified := TRUE
    ELSIF k = KCtrlT THEN
      i := col;
      WHILE (i < n) & (tb.l[row][i] # " ") DO INC(i) END;
      WHILE (i < n) & (tb.l[row][i] = " ") DO INC(i) END;
      IF i > col THEN Strings.Delete(tb.l[row], col, i - col); modified := TRUE END
    ELSIF (k = KCtrlW) OR (k = TUI.KCtrlEnd) THEN saved := TRUE; done := TRUE
    ELSIF (k = TUI.KEsc) OR (k = KCtrlQ) THEN
      IF ~modified OR FSAsk("Abandon changes? (Y/N)") THEN done := TRUE END
    ELSIF (k >= " ") & (k < 7FX) THEN
      IF n < 254 THEN
        IF insMode OR (col >= n) THEN
          t[0] := k; t[1] := 0X; Strings.Insert(t, col, tb.l[row])
        ELSE tb.l[row][col] := k
        END;
        INC(col); modified := TRUE
      ELSE Bell
      END
    END
  END;
  ConClear;
  TUI.InvalidateFront
END EditText;

PROCEDURE ModifyFile(name, ext: ARRAY OF CHAR);
VAR path, title, sn: Str; tb: TextBuf; saved: BOOLEAN;
BEGIN
  IF batch THEN Err("Full-screen commands need the interactive mode."); RETURN END;
  NewPath(name, ext, path);
  IF ~LoadTextFile(path, tb) THEN END;
  ShortName(path, sn);
  Cpy("Edit: ", title); Append(sn, title);
  EditText(title, tb, saved);
  IF saved THEN
    IF ~SaveTextFile(path, tb) THEN Err("Unable to create file.") END;
    ForgetProg(path)
  END
END ModifyFile;

(* ====================================================================
   File picker (USE ?, ASSIST)
   ==================================================================== *)

PROCEDURE PickFile(ext: ARRAY OF CHAR; VAR name: ARRAY OF CHAR): BOOLEAN;
VAR
  list: TextBuf; i, n, sel, top, x, y, w, h: INTEGER; nm, dir, pat: Str; k: CHAR;
BEGIN
  IF batch THEN RETURN FALSE END;
  NEW(list); list.n := 0;
  IF defDir[0] # 0X THEN Cpy(defDir, dir) ELSE dir[0] := 0X END;
  Cpy("*", pat); Append(ext, pat);
  OS.DirOpen(dir, "");
  n := OS.DirCount();
  FOR i := 0 TO n - 1 DO
    OS.DirName(i, nm);
    IF ~OS.DirIsDir(i) & WildMatch(pat, nm, 0, 0) & (list.n < MaxTxtLn) THEN
      Cpy(nm, list.l[list.n]); INC(list.n)
    END
  END;
  IF list.n = 0 THEN FSMessage("No files of that type"); RETURN FALSE END;
  sel := 0; top := 0;
  w := 24; h := MinI(list.n, TUI.Rows - 8);
  x := (TUI.Cols - w) DIV 2; y := 4;
  LOOP
    IF sel < top THEN top := sel END;
    IF sel >= top + h THEN top := sel - h + 1 END;
    Box(x, y - 1, w, h + 2);
    FOR i := 0 TO h - 1 DO
      IF top + i < list.n THEN
        Cpy(list.l[top + i], nm); Upper(nm); PadR(nm, w - 4);
        PutS(x + 2, y + i, nm, top + i = sel)
      END
    END;
    FSFlush(1, 1, FALSE);
    k := GetKey();
    IF (k = TUI.KUp) OR (k = KCtrlE) THEN IF sel > 0 THEN DEC(sel) END
    ELSIF (k = TUI.KDown) OR (k = KCtrlX) THEN IF sel < list.n - 1 THEN INC(sel) END
    ELSIF k = TUI.KPgUp THEN sel := MaxI(0, sel - h)
    ELSIF k = TUI.KPgDn THEN sel := MinI(list.n - 1, sel + h)
    ELSIF k = TUI.KEnter THEN Cpy(list.l[sel], name); TUI.InvalidateFront; RETURN TRUE
    ELSIF (k = TUI.KEsc) OR (k = TUI.KLeft) THEN TUI.InvalidateFront; RETURN FALSE
    END
  END
END PickFile;

(* ====================================================================
   @ row,col SAY ... GET ...   and READ
   ==================================================================== *)

PROCEDURE SayAt(r, c: INTEGER; s: ARRAY OF CHAR; rev: BOOLEAN);
VAR i: INTEGER;
BEGIN
  IF setDevPrint THEN
    IF r < prow THEN PrnEject END;
    WHILE prow < r DO PrnNL END;
    IF c < pcol THEN PrnNL; WHILE prow < r DO PrnNL END END;
    WHILE pcol < c DO PrnStr(" ") END;
    PrnStr(s);
    RETURN
  END;
  IF batch THEN Out.String(s); Out.Ln; RETURN END;
  IF (r < 0) OR (r >= scrH) THEN RETURN END;
  i := 0;
  WHILE (s[i] # 0X) & (c + i < scrW) DO
    IF c + i >= 0 THEN
      scr[r][c + i] := s[i];
      IF rev THEN att[r][c + i] := CHR(aRev) ELSE att[r][c + i] := CHR(aNorm) END
    END;
    INC(i)
  END;
  crow := r; ccol := MinI(c + i, scrW - 1)
END SayAt;

PROCEDURE GetText(VAR g: GetDef; VAR v: Value);
BEGIN
  IF g.isField THEN
    FieldToText(g.area, g.fld, g.text); g.t := areas[g.area].db.fields[g.fld].type;
    g.width := FieldEditWidth(g.area, g.fld)
  ELSE
    g.t := v.t;
    CASE v.t OF
      "C": Cpy(v.s, g.text); g.width := MaxI(SLen(v.s), 1)
    | "N": FmtFixed(v.n, v.dec, g.text); g.width := MaxI(v.w, SLen(g.text)); PadL(g.text, g.width)
    | "D": DateStr(v.d, g.text); g.width := SLen(g.text)
    | "L": IF v.b THEN Cpy("T", g.text) ELSE Cpy("F", g.text) END; g.width := 1
    ELSE g.text[0] := 0X; g.width := 1
    END;
    g.dec := v.dec
  END
END GetText;

PROCEDURE DoAt;
VAR
  r, c, r2, c2, i, k: INTEGER; n: Node; v: Value; s, pic: Str; dbl2: BOOLEAN;
  g: GetDef; name: Str;
BEGIN
  n := Expr(); r := EvalInt(n);
  IF tk # tComma THEN Err("Syntax error."); RETURN END;
  Next; n := Expr(); c := EvalInt(n);
  IF err THEN RETURN END;
  IF tk = tEOF THEN
    (* @ r,c alone clears the rest of the line *)
    IF ~batch & (r >= 0) & (r < scrH) THEN FOR i := MaxI(c, 0) TO MaxSC - 1 DO scr[r][i] := " "; att[r][i] := CHR(aNorm) END END;
    crow := MinI(MaxI(r, 0), scrH - 1); ccol := MinI(MaxI(c, 0), scrW - 1);
    RETURN
  END;
  IF IsKw("CLEAR") THEN
    Next; r2 := scrH - 1; c2 := scrW - 1;
    IF IsKw("TO") THEN Next; n := Expr(); r2 := EvalInt(n); Next; n := Expr(); c2 := EvalInt(n) END;
    IF ~batch THEN
      FOR i := MaxI(r, 0) TO MinI(r2, scrH - 1) DO
        FOR k := MaxI(c, 0) TO MinI(c2, MaxSC - 1) DO scr[i][k] := " "; att[i][k] := CHR(aNorm) END
      END
    END;
    RETURN
  END;
  IF IsKw("TO") THEN
    Next; n := Expr(); r2 := EvalInt(n);
    IF tk = tComma THEN Next END;
    n := Expr(); c2 := EvalInt(n);
    dbl2 := IsKw("DOUBLE"); IF dbl2 THEN Next END;
    IF ~batch & ~err THEN
      FOR i := c TO c2 DO
        IF (i >= 0) & (i < scrW) THEN
          IF (r >= 0) & (r < scrH) THEN scr[r][i] := "-" END;
          IF (r2 >= 0) & (r2 < scrH) THEN scr[r2][i] := "-" END
        END
      END;
      FOR i := r TO r2 DO
        IF (i >= 0) & (i < scrH) THEN
          IF (c >= 0) & (c < scrW) THEN scr[i][c] := "|" END;
          IF (c2 >= 0) & (c2 < scrW) THEN scr[i][c2] := "|" END
        END
      END;
      IF (r >= 0) & (r < scrH) & (c >= 0) & (c2 < scrW) THEN scr[r][c] := "+"; scr[r][c2] := "+" END;
      IF (r2 >= 0) & (r2 < scrH) & (c >= 0) & (c2 < scrW) THEN scr[r2][c] := "+"; scr[r2][c2] := "+" END
    END;
    RETURN
  END;
  IF IsKw("SAY") THEN
    Next; n := Expr(); Eval(n, v); ApplyFixed(n, v);
    pic[0] := 0X;
    IF IsKw("PICTURE") THEN Next; n := Expr(); EvalStr(n, pic) END;
    IF IsKw("FUNCTION") THEN Next; n := Expr(); EvalStr(n, s); Strings.Insert("@", 0, s); Append(" ", s); Append(pic, s); Cpy(s, pic) END;
    IF err THEN RETURN END;
    IF pic[0] # 0X THEN FmtPicture(v, pic, s) ELSE ValStr(v, s) END;
    SayAt(r, c, s, FALSE);
    c := c + SLen(s) + 1
  END;
  IF IsKw("GET") THEN
    Next;
    IF tk # tIdent THEN Err("Syntax error."); RETURN END;
    Cpy(tkStr, name); Next;
    g.row := r; g.col := c; g.isField := FALSE; g.area := cur; g.fld := -1;
    IF tk = tArrow THEN
      Next; g.area := AliasArea(name); Cpy(tkStr, name); Next;
      IF g.area < 0 THEN Err("ALIAS not found."); RETURN END
    END;
    i := -1;
    IF areas[g.area].used THEN i := FieldIdx(g.area, name) END;
    IF i >= 0 THEN g.isField := TRUE; g.fld := i
    ELSE
      k := FindVar(name);
      IF k < 0 THEN Err("Variable not found."); RETURN END;
      v := vars[k].v
    END;
    Cpy(name, g.var);
    g.pic[0] := 0X; g.rangeOn := FALSE;
    LOOP
      IF IsKw("PICTURE") THEN Next; n := Expr(); EvalStr(n, g.pic)
      ELSIF IsKw("FUNCTION") THEN Next; n := Expr(); EvalStr(n, s); Strings.Insert("@", 0, s); Cpy(s, g.pic)
      ELSIF IsKw("RANGE") THEN
        Next; n := Expr(); Eval(n, g.lo);
        IF tk = tComma THEN Next; n := Expr(); Eval(n, g.hi) END;
        g.rangeOn := TRUE
      ELSE EXIT
      END;
      IF err THEN RETURN END
    END;
    GetText(g, v);
    SplitPicture(g.pic, s, pic);
    IF pic[0] # 0X THEN g.width := SLen(pic); PadR(g.text, g.width); PutLiterals(g.pic, g.t, g.text) END;
    IF nGets < MaxGets THEN getList[nGets] := g; INC(nGets) END;
    Cpy(g.text, s); PadR(s, g.width);
    SayAt(g.row, g.col, s, setIntensity)
  END
END DoAt;

PROCEDURE GetStore(VAR g: GetDef; VAR fe: FieldEd): BOOLEAN;
VAR v: Value; x: REAL; d: INTEGER; s: Str;
BEGIN
  IF g.isField THEN
    IF areas[g.area].rec > areas[g.area].db.numRecs THEN RETURN TRUE END;
    BeginChange(g.area);
    IF ~TextToField(g.area, g.fld, fe.text) THEN RETURN FALSE END;
    EndChange(g.area);
    RETURN TRUE
  END;
  Cpy(fe.text, s);
  CASE g.t OF
    "C": RTrim(s); PadR(s, g.width); SetStr(v, s)
  | "N": ScanNum(s, x, d); SetNum(v, x, g.width, g.dec)
  | "D": SetDate(v, ParseDate(s))
  | "L": SetBool(v, (UpCh(s[0]) = "T") OR (UpCh(s[0]) = "Y"))
  ELSE SetStr(v, s)
  END;
  IF g.rangeOn & (v.t = TN) & (g.lo.t = TN) THEN
    IF (v.n < g.lo.n) OR ((g.hi.t = TN) & (v.n > g.hi.n)) THEN
      FSMessage("RANGE error"); RETURN FALSE
    END
  END;
  StoreVar(g.var, v);
  RETURN TRUE
END GetStore;

PROCEDURE DoRead;
VAR fe: ARRAY MaxGets OF FieldEd; i, cg, r, x: INTEGER; k: CHAR; done, abandon: BOOLEAN;
  s: Str;
BEGIN
  IF IsKw("SAVE") THEN Next END;
  IF batch OR (nGets = 0) THEN nGets := 0; RETURN END;
  FOR i := 0 TO nGets - 1 DO
    FEInit(fe[i], getList[i].text, getList[i].width, getList[i].t, getList[i].pic)
  END;
  cg := 0; done := FALSE; abandon := FALSE;
  WHILE ~done DO
    (* paint the console with the GET fields over it *)
    TUI.ClearBack(cFg, cBg);
    DrawConsoleAt(0, 0, FALSE);
    FOR i := 0 TO nGets - 1 DO
      FEDraw(fe[i], getList[i].col + 1, getList[i].row + 1, fe[i].width, i = cg)
    END;
    x := getList[cg].col + 1;
    FSFlush(FECursorX(fe[cg], x), getList[cg].row + 1, TRUE);
    k := GetKey();
    r := FEKey(fe[cg], k);
    IF (r = feNext) OR (r = feRightOut) THEN
      IF GetStore(getList[cg], fe[cg]) THEN
        IF cg < nGets - 1 THEN INC(cg) ELSE done := TRUE END
      END;
      IF r = feRightOut THEN readExit := 1
      ELSIF (k = TUI.KDown) OR (k = KCtrlX) THEN readExit := 5
      ELSE readExit := 15
      END
    ELSIF (r = fePrev) OR (r = feLeftOut) THEN
      IF GetStore(getList[cg], fe[cg]) & (cg > 0) THEN DEC(cg) END
    ELSIF r = feOther THEN
      IF (k = KCtrlW) OR (k = TUI.KCtrlEnd) OR (k = TUI.KPgDn) OR (k = TUI.KPgUp) THEN
        IF GetStore(getList[cg], fe[cg]) THEN done := TRUE END;
        IF k = TUI.KPgDn THEN readExit := 7 ELSIF k = TUI.KPgUp THEN readExit := 6 ELSE readExit := 14 END
      ELSIF (k = TUI.KEsc) OR (k = KCtrlQ) THEN done := TRUE; abandon := TRUE; readExit := 12
      END
    END
  END;
  (* dBASE III PLUS READKEY(): the exit key's code, plus 256 if any data changed *)
  i := 0; WHILE (i < nGets) & ~fe[i].changed DO INC(i) END;
  IF i < nGets THEN INC(readExit, 256) END;
  (* leave the final values on the console *)
  FOR i := 0 TO nGets - 1 DO
    Cpy(fe[i].text, s); SayAt(getList[i].row, getList[i].col, s, setIntensity)
  END;
  nGets := 0;
  IF abandon & setEscape THEN END;
  Terminal.HideCursor()
END DoRead;

(* ====================================================================
   CREATE / MODIFY STRUCTURE
   ==================================================================== *)

TYPE
  StructDef = RECORD
    n: INTEGER;
    name: ARRAY DBF.MaxFields + 1 OF Name;
    typ: ARRAY DBF.MaxFields + 1 OF CHAR;
    width, dec, orig: ARRAY DBF.MaxFields + 1 OF INTEGER
  END;

PROCEDURE TypeWord(c: CHAR; VAR s: ARRAY OF CHAR);
BEGIN
  IF c = " " THEN s[0] := 0X ELSE TypeName(c, s) END
END TypeWord;

PROCEDURE FixWidth(VAR sd: StructDef; i: INTEGER);
BEGIN
  CASE sd.typ[i] OF
    "D": sd.width[i] := 8; sd.dec[i] := 0
  | "L": sd.width[i] := 1; sd.dec[i] := 0
  | "M": sd.width[i] := 10; sd.dec[i] := 0
  | "C": sd.dec[i] := 0
  ELSE
  END
END FixWidth;

PROCEDURE ValidName(s: ARRAY OF CHAR): BOOLEAN;
VAR i: INTEGER;
BEGIN
  IF ~IsAlpha(s[0]) THEN RETURN FALSE END;
  i := 0;
  WHILE s[i] # 0X DO IF ~IsIdCh(s[i]) THEN RETURN FALSE END; INC(i) END;
  RETURN i <= 10
END ValidName;

(* check a structure; returns the offending row or -1 *)
PROCEDURE CheckStruct(VAR sd: StructDef; VAR msg: ARRAY OF CHAR): INTEGER;
VAR i, j: INTEGER;
BEGIN
  FOR i := 0 TO sd.n - 1 DO
    IF ~ValidName(sd.name[i]) THEN Cpy("Field names begin with a letter: A-Z, 0-9, _", msg); RETURN i END;
    FOR j := 0 TO i - 1 DO
      IF EqI(sd.name[i], sd.name[j]) THEN Cpy("Field name already exists", msg); RETURN i END
    END;
    IF sd.typ[i] = " " THEN Cpy("Field type must be C, N, D, L or M", msg); RETURN i END;
    IF (sd.typ[i] = "C") & ((sd.width[i] < 1) OR (sd.width[i] > 254)) THEN
      Cpy("Character fields are 1 to 254 wide", msg); RETURN i END;
    IF (sd.typ[i] = "N") & ((sd.width[i] < 1) OR (sd.width[i] > 19)) THEN
      Cpy("Numeric fields are 1 to 19 wide", msg); RETURN i END;
    IF (sd.typ[i] = "N") & (sd.dec[i] > 0) & (sd.dec[i] > sd.width[i] - 2) THEN
      Cpy("Too many decimal places for the width", msg); RETURN i END
  END;
  RETURN -1
END CheckStruct;

PROCEDURE RecBytes(VAR sd: StructDef): INTEGER;
VAR i, n: INTEGER;
BEGIN
  n := 1;
  FOR i := 0 TO sd.n - 1 DO INC(n, sd.width[i]) END;
  RETURN n
END RecBytes;

PROCEDURE SDLoadCell(VAR sd: StructDef; VAR fe: FieldEd; row, col: INTEGER);
VAR s: Str;
BEGIN
  IF col = 0 THEN FEInit(fe, sd.name[row], 10, TC, "@!")
  ELSIF col = 2 THEN IntStr(sd.width[row], s); FEInit(fe, s, 3, TN, "")
  ELSE IntStr(sd.dec[row], s); FEInit(fe, s, 3, TN, "")
  END
END SDLoadCell;

PROCEDURE SDStoreCell(VAR sd: StructDef; VAR fe: FieldEd; row, col: INTEGER);
VAR n: INTEGER;
BEGIN
  IF col = 0 THEN Cpy(fe.text, sd.name[row]); Trim(sd.name[row]); Upper(sd.name[row])
  ELSIF col = 2 THEN IF StrInt(fe.text, n) THEN sd.width[row] := n END; FixWidth(sd, row)
  ELSIF col = 3 THEN IF StrInt(fe.text, n) THEN sd.dec[row] := n END
  END
END SDStoreCell;

(* the structure screen; TRUE if saved *)
PROCEDURE EditStruct(title: ARRAY OF CHAR; VAR sd: StructDef): BOOLEAN;
VAR
  row, col, top, y0, h, i, y, r, bad: INTEGER; k: CHAR; fe: FieldEd; editing, done, ok: BOOLEAN;
  s, t, msg: Str;


BEGIN
  IF sd.n = 0 THEN sd.n := 1; sd.name[0][0] := 0X; sd.typ[0] := " "; sd.width[0] := 0; sd.dec[0] := 0; sd.orig[0] := -1 END;
  row := 0; col := 0; top := 0; done := FALSE; ok := FALSE;
  SDLoadCell(sd, fe, row, col);
  WHILE ~done DO
    ScreenSize;
    FSClear;
    y0 := 1;
    IF setMenu THEN
      TUI.DrawBox(1, 1, MinI(TUI.Cols, 80), 5, cFg, cBg);
      PutHi(3, 2, "CURSOR  <-- -->    UP  DOWN       DELETE           Insert field:  ^N");
      PutS(3, 3, "Char:   ^S  ^D     Field: ^E ^X   Char:  Del ^G    Delete field:  ^U", FALSE);
      PutS(3, 4, "Column: Enter      Page: PgUp/Dn  Field: ^Y        Save: ^W   Abort: Esc", FALSE);
      y0 := 6
    END;
    Cpy("Bytes remaining:  ", s); AppendInt(4000 - RecBytes(sd), s);
    PutHi(TUI.Cols - SLen(s) - 1, y0, s);
    PutHi(2, y0 + 1, "     Field Name  Type        Width   Dec");
    h := scrH - y0 - 2;
    IF h < 1 THEN h := 1 END;
    IF row < top THEN top := row END;
    IF row >= top + h THEN top := row - h + 1 END;
    FOR i := 0 TO h - 1 DO
      r := top + i;
      IF r < sd.n THEN
        y := y0 + 2 + i;
        IntStrW(r + 1, 5, s); PutS(1, y, s, FALSE);
        IF (r = row) & (col = 0) THEN FEDraw(fe, 8, y, 10, TRUE)
        ELSE Cpy(sd.name[r], t); PadR(t, 10); PutS(8, y, t, TRUE) END;
        TypeWord(sd.typ[r], t); PadR(t, 10); PutS(20, y, t, TRUE);
        IF (r = row) & (col = 2) THEN FEDraw(fe, 32, y, 3, TRUE)
        ELSE
          IF sd.typ[r] = " " THEN t[0] := 0X ELSE IntStrW(sd.width[r], 3, t) END;
          PadR(t, 3); PutS(32, y, t, TRUE)
        END;
        IF (r = row) & (col = 3) THEN FEDraw(fe, 39, y, 3, TRUE)
        ELSIF sd.typ[r] = "N" THEN IntStrW(sd.dec[r], 3, t); PutS(39, y, t, TRUE)
        END
      END
    END;
    Cpy("Enter the field name.", fsMsg);
    IF col = 1 THEN Cpy("Field type: C(haracter) N(umeric) D(ate) L(ogical) M(emo); space cycles.", fsMsg)
    ELSIF col = 2 THEN Cpy("Enter the field width.", fsMsg)
    ELSIF col = 3 THEN Cpy("Enter the number of decimal places.", fsMsg) END;
    Cpy("Field names begin with a letter and may contain letters, digits and underscores", fsNav);
    FSBars(title);
    fsMsg[0] := 0X; fsNav[0] := 0X;
    y := y0 + 2 + row - top;
    IF col = 0 THEN FSFlush(FECursorX(fe, 8), y, TRUE)
    ELSIF col = 1 THEN FSFlush(20, y, TRUE)
    ELSIF col = 2 THEN FSFlush(FECursorX(fe, 32), y, TRUE)
    ELSE FSFlush(FECursorX(fe, 39), y, TRUE)
    END;
    k := GetKey();
    IF k = 0X THEN
    ELSIF (k = KCtrlW) OR (k = TUI.KCtrlEnd) THEN
      IF col # 1 THEN SDStoreCell(sd, fe, row, col) END;
      WHILE (sd.n > 0) & (sd.name[sd.n - 1][0] = 0X) DO DEC(sd.n) END;
      bad := CheckStruct(sd, msg);
      IF sd.n = 0 THEN FSMessage("No fields defined"); sd.n := 1; sd.typ[0] := " "
      ELSIF bad >= 0 THEN FSMessage(msg); row := bad; col := 0; SDLoadCell(sd, fe, row, col)
      ELSE done := TRUE; ok := TRUE
      END
    ELSIF (k = TUI.KEsc) OR (k = KCtrlQ) THEN
      IF FSAsk("Abandon operation? (Y/N)") THEN done := TRUE END
    ELSIF k = TUI.KF1 THEN setMenu := ~setMenu
    ELSIF k = KCtrlN THEN
      IF col # 1 THEN SDStoreCell(sd, fe, row, col) END;
      IF sd.n < DBF.MaxFields THEN
        FOR i := sd.n TO row + 1 BY -1 DO
          Cpy(sd.name[i - 1], sd.name[i]); sd.typ[i] := sd.typ[i - 1];
          sd.width[i] := sd.width[i - 1]; sd.dec[i] := sd.dec[i - 1]; sd.orig[i] := sd.orig[i - 1]
        END;
        sd.name[row][0] := 0X; sd.typ[row] := "C"; sd.width[row] := 10; sd.dec[row] := 0; sd.orig[row] := -1;
        INC(sd.n); col := 0; SDLoadCell(sd, fe, row, col)
      END
    ELSIF k = KCtrlU THEN
      IF sd.n > 1 THEN
        FOR i := row TO sd.n - 2 DO
          Cpy(sd.name[i + 1], sd.name[i]); sd.typ[i] := sd.typ[i + 1];
          sd.width[i] := sd.width[i + 1]; sd.dec[i] := sd.dec[i + 1]; sd.orig[i] := sd.orig[i + 1]
        END;
        DEC(sd.n); IF row >= sd.n THEN row := sd.n - 1 END
      ELSE sd.name[0][0] := 0X; sd.typ[0] := " "
      END;
      col := 0; SDLoadCell(sd, fe, row, col)
    ELSIF col = 1 THEN
      (* type column *)
      k := UpCh(k);
      IF (k = "C") OR (k = "N") OR (k = "D") OR (k = "L") OR (k = "M") THEN
        sd.typ[row] := k; IF (k = "C") & (sd.width[row] = 0) THEN sd.width[row] := 10 END;
        IF (k = "N") & ((sd.width[row] = 0) OR (sd.width[row] > 19)) THEN sd.width[row] := 10 END;
        FixWidth(sd, row);
        IF (k = "C") OR (k = "N") THEN col := 2 ELSE INC(row); col := 0 END
      ELSIF k = " " THEN
        CASE sd.typ[row] OF
          "C": sd.typ[row] := "N" | "N": sd.typ[row] := "D" | "D": sd.typ[row] := "L"
        | "L": sd.typ[row] := "M" ELSE sd.typ[row] := "C"
        END;
        IF sd.typ[row] = "N" THEN sd.width[row] := MinI(MaxI(sd.width[row], 1), 19) END;
        IF (sd.typ[row] = "C") & (sd.width[row] < 1) THEN sd.width[row] := 10 END;
        FixWidth(sd, row)
      ELSIF (k = TUI.KEnter) OR (k = TUI.KRight) OR (k = KCtrlD) THEN
        IF (sd.typ[row] = "C") OR (sd.typ[row] = "N") THEN col := 2 ELSE INC(row); col := 0 END
      ELSIF (k = TUI.KLeft) OR (k = KCtrlS) THEN col := 0
      ELSIF (k = TUI.KUp) OR (k = KCtrlE) THEN DEC(row)
      ELSIF (k = TUI.KDown) OR (k = KCtrlX) THEN INC(row)
      END;
      IF row < 0 THEN row := 0 END;
      IF row >= sd.n THEN
        IF (sd.n < DBF.MaxFields) & (sd.name[sd.n - 1][0] # 0X) THEN
          sd.name[sd.n][0] := 0X; sd.typ[sd.n] := " "; sd.width[sd.n] := 0; sd.dec[sd.n] := 0; sd.orig[sd.n] := -1;
          INC(sd.n)
        END;
        row := sd.n - 1
      END;
      IF col # 1 THEN SDLoadCell(sd, fe, row, col) END
    ELSE
      r := FEKey(fe, k);
      IF (r = feNext) & (k # TUI.KDown) & (k # KCtrlX) OR (r = feRightOut) THEN
        SDStoreCell(sd, fe, row, col);
        IF (col = 0) & (sd.name[row][0] = 0X) THEN
          (* Enter on an empty field name finishes the definition *)
          IF k = TUI.KEnter THEN
            WHILE (sd.n > 0) & (sd.name[sd.n - 1][0] = 0X) DO DEC(sd.n) END;
            bad := CheckStruct(sd, msg);
            IF sd.n = 0 THEN sd.n := 1; sd.typ[0] := " "
            ELSIF bad >= 0 THEN FSMessage(msg); row := bad; col := 0
            ELSE
              FSClear; PutHi(2, TUI.Rows DIV 2, "Press ENTER to confirm. Any other key to resume.");
              FSFlush(1, 1, FALSE);
              REPEAT k := GetKey() UNTIL k # 0X;
              IF k = TUI.KEnter THEN done := TRUE; ok := TRUE
              ELSE
                sd.name[sd.n][0] := 0X; sd.typ[sd.n] := " "; sd.width[sd.n] := 0; sd.orig[sd.n] := -1;
                INC(sd.n); row := sd.n - 1
              END
            END
          END
        ELSIF col = 0 THEN
          IF sd.typ[row] = " " THEN sd.typ[row] := "C"; sd.width[row] := 10 END;
          col := 1
        ELSIF (col = 2) & (sd.typ[row] = "N") THEN col := 3
        ELSE
          INC(row); col := 0;
          IF row >= sd.n THEN
            IF sd.n < DBF.MaxFields THEN
              sd.name[sd.n][0] := 0X; sd.typ[sd.n] := " "; sd.width[sd.n] := 0; sd.dec[sd.n] := 0; sd.orig[sd.n] := -1;
              INC(sd.n)
            ELSE row := sd.n - 1
            END
          END
        END;
        IF ~done & (col # 1) THEN SDLoadCell(sd, fe, row, col) END
      ELSIF (r = feLeftOut) THEN
        SDStoreCell(sd, fe, row, col); IF col > 0 THEN DEC(col) END; IF col = 2 THEN END; IF col # 1 THEN SDLoadCell(sd, fe, row, col) END
      ELSIF (r = fePrev) OR (r = feNext) THEN
        SDStoreCell(sd, fe, row, col);
        IF r = fePrev THEN IF row > 0 THEN DEC(row) END
        ELSIF row < sd.n - 1 THEN INC(row)
        END;
        SDLoadCell(sd, fe, row, col)
      ELSIF r = feOther THEN
        IF (k = TUI.KPgUp) THEN SDStoreCell(sd, fe, row, col); row := MaxI(0, row - h); SDLoadCell(sd, fe, row, col)
        ELSIF (k = TUI.KPgDn) THEN SDStoreCell(sd, fe, row, col); row := MinI(sd.n - 1, row + h); SDLoadCell(sd, fe, row, col)
        END
      END
    END
  END;
  ConClear;
  TUI.InvalidateFront;
  RETURN ok
END EditStruct;

PROCEDURE StructToFields(VAR sd: StructDef; VAR flds: ARRAY OF DBF.Field);
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO sd.n - 1 DO
    DBF.MakeField(flds[i], sd.name[i], sd.typ[i], sd.width[i], sd.dec[i])
  END
END StructToFields;

(* CREATE <file> [FROM <structure-extended file>] *)
PROCEDURE DoCreateDbf(name: ARRAY OF CHAR);
VAR
  sd: StructDef; path, src2, t: Str; flds: ARRAY DBF.MaxFields OF DBF.Field; db: DBF.Database;
  sdb: DBF.Database; i, n: INTEGER; buf: ARRAY MaxRecBuf OF CHAR; el: ExprList;
BEGIN
  IF name[0] = 0X THEN Err("Syntax error."); RETURN END;
  NewPath(name, ".dbf", path);
  sd.n := 0;
  IF IsKw("FROM") THEN
    Next; RawWord(src2);
    IF ~FindFile(src2, ".dbf", t) THEN Err("File does not exist."); RETURN END;
    DBF.Open(sdb, t);
    IF sdb.f = NIL THEN Err("File does not exist."); RETURN END;
    FOR i := 0 TO sdb.numRecs - 1 DO
      DBF.ReadRec(sdb, i, buf);
      IF (buf[0] # "*") & (sd.n < DBF.MaxFields) THEN
        Sub(buf, 1, 10, t); Trim(t); Upper(t); Cpy(t, sd.name[sd.n]);
        sd.typ[sd.n] := UpCh(buf[11]);
        Sub(buf, 12, 3, t); IF StrInt(t, n) THEN sd.width[sd.n] := n ELSE sd.width[sd.n] := 10 END;
        Sub(buf, 15, 3, t); IF StrInt(t, n) THEN sd.dec[sd.n] := n ELSE sd.dec[sd.n] := 0 END;
        FixWidth(sd, sd.n);
        INC(sd.n)
      END
    END;
    Files.Close(sdb.f);
    IF CheckStruct(sd, t) >= 0 THEN Err("Invalid structure definition."); RETURN END
  ELSE
    IF batch THEN Err("Full-screen commands need the interactive mode."); RETURN END;
    IF ~OkToOverwrite(path) THEN RETURN END;
    IF ~EditStruct("CREATE", sd) THEN RETURN END
  END;
  StructToFields(sd, flds);
  IF ~CreateDbf(path, flds, sd.n, db) THEN RETURN END;
  DBF.Close(db);
  IF ~OpenArea(cur, path, "") THEN RETURN END;
  IF ~batch & (depth = 0) & AskYN("Input data records now? (Y/N)") THEN
    el.n := 0; FormRun(fmAppend, el)
  END
END DoCreateDbf;

PROCEDURE DoModifyStructure;
VAR
  sd: StructDef; i, j, r, a, ni: INTEGER; path, bak, memo, bakMemo, t: Str;
  flds: ARRAY DBF.MaxFields OF DBF.Field; old, db: DBF.Database;
  obuf, nbuf: ARRAY MaxRecBuf OF CHAR; ooff: ARRAY DBF.MaxFields OF INTEGER;
  off: INTEGER; v: Value; idxNames: ARRAY MaxIdx OF Str; hadMemo: BOOLEAN;
BEGIN
  IF ~NeedDb() THEN RETURN END;
  IF batch THEN Err("Full-screen commands need the interactive mode."); RETURN END;
  a := cur;
  sd.n := areas[a].db.numFields;
  FOR i := 0 TO sd.n - 1 DO
    Cpy(areas[a].db.fields[i].name, sd.name[i]); sd.typ[i] := areas[a].db.fields[i].type;
    IF sd.typ[i] = "F" THEN sd.typ[i] := "N" END;
    sd.width[i] := areas[a].db.fields[i].len; sd.dec[i] := areas[a].db.fields[i].dec; sd.orig[i] := i
  END;
  IF ~EditStruct("MODIFY STRUCTURE", sd) THEN RETURN END;
  (* remember open indexes, close the file, keep a .BAK copy *)
  Cpy(areas[a].fname, path); Cpy(areas[a].memo, memo); hadMemo := memo[0] # 0X;
  ni := areas[a].nIdx;
  FOR i := 0 TO ni - 1 DO Cpy(areas[a].idx[i].fname, idxNames[i]) END;
  CloseArea(a);
  Cpy(path, bak); i := SLen(bak) - 1;
  WHILE (i > 0) & (bak[i] # ".") DO DEC(i) END;
  IF bak[i] = "." THEN bak[i] := 0X END;
  Cpy(bak, bakMemo); Append(".bak", bak); Append(".tbk", bakMemo);
  Files.Delete(bak); Files.Rename(path, bak);
  IF hadMemo THEN Files.Delete(bakMemo); Files.Rename(memo, bakMemo) END;
  StructToFields(sd, flds);
  IF ~CreateDbf(path, flds, sd.n, db) THEN RETURN END;
  DBF.Open(old, bak);
  off := 1;
  FOR j := 0 TO old.numFields - 1 DO ooff[j] := off; INC(off, old.fields[j].len) END;
  (* match new fields to old ones: by original position, else by name *)
  FOR i := 0 TO sd.n - 1 DO
    IF sd.orig[i] < 0 THEN
      FOR j := 0 TO old.numFields - 1 DO IF EqI(old.fields[j].name, sd.name[i]) THEN sd.orig[i] := j END END
    END
  END;
  IF hadMemo THEN
    DBF.MemoName(path, t);
    IF CopyFileRaw(bakMemo, t) < 0 THEN END
  END;
  FOR r := 0 TO old.numRecs - 1 DO
    DBF.ReadRec(old, r, obuf);
    FOR i := 0 TO db.recordLen - 1 DO nbuf[i] := " " END;
    nbuf[0] := obuf[0]; off := 1;
    FOR i := 0 TO sd.n - 1 DO
      j := sd.orig[i];
      IF j >= 0 THEN
        Sub(obuf, ooff[j], old.fields[j].len, t);
        IF (old.fields[j].type = "N") OR (old.fields[j].type = "F") THEN
          RawToVal("N", old.fields[j].len, old.fields[j].dec, t, v);
          IF sd.typ[i] = "N" THEN FmtNumW(RoundTo(v.n, sd.dec[i]), sd.width[i], sd.dec[i], t)
          ELSIF sd.typ[i] = "C" THEN Trim(t)
          ELSE t[0] := 0X
          END
        ELSIF sd.typ[i] = "N" THEN
          IF old.fields[j].type = "C" THEN
            RawToVal("N", 10, 0, t, v); FmtNumW(RoundTo(v.n, sd.dec[i]), sd.width[i], sd.dec[i], t)
          ELSE t[0] := 0X
          END
        ELSIF (sd.typ[i] # old.fields[j].type) & (sd.typ[i] # "C") THEN t[0] := 0X
        END;
        FOR j := 0 TO sd.width[i] - 1 DO
          IF j < SLen(t) THEN nbuf[off + j] := t[j] END
        END
      END;
      INC(off, sd.width[i])
    END;
    nbuf[off] := 0X;
    DBF.WriteRec(db, db.numRecs, nbuf)
  END;
  Files.Close(old.f);
  DBF.Close(db);
  IF ~OpenArea(a, path, "") THEN RETURN END;
  FOR i := 0 TO ni - 1 DO
    IF OpenIndex(a, idxNames[i]) THEN END;
    err := FALSE
  END;
  IF areas[a].nIdx > 0 THEN Reindex(a) END;
  GoTop(a)
END DoModifyStructure;

PROCEDURE DoCreate;
VAR name: Str;
BEGIN
  IF IsKw("REPORT") THEN Next; RawWord(name); DesignReport(name)
  ELSIF IsKw("LABEL") THEN Next; RawWord(name); DesignLabel(name)
  ELSIF IsKw("QUERY") THEN Next; RawWord(name); DesignQuery(name)
  ELSIF IsKw("VIEW") THEN
    Next; RawWord(name);
    IF IsKw("FROM") THEN Next; IF IsKw("ENVIRONMENT") THEN Next END END;
    DoCreateViewEnv(name)
  ELSIF IsKw("SCREEN") OR IsKw("CATALOG") THEN Err("CREATE SCREEN and CATALOG are not supported.")
  ELSE
    IF tk = tEOF THEN
      name[0] := 0X;
      IF batch OR ~ReadLine("Enter the name of the new file: ", name, 60, FALSE) THEN RETURN END
    ELSE RawWord(name)
    END;
    DoCreateDbf(name)
  END
END DoCreate;

PROCEDURE DoModify;
VAR name: Str;
BEGIN
  IF IsKw("STRUCTURE") THEN Next; DoModifyStructure
  ELSIF IsKw("COMMAND") THEN Next; RawWord(name); ModifyFile(name, ".prg")
  ELSIF IsKw("FILE") THEN Next; RawWord(name); ModifyFile(name, "")
  ELSIF IsKw("REPORT") THEN Next; RawWord(name); DesignReport(name)
  ELSIF IsKw("LABEL") THEN Next; RawWord(name); DesignLabel(name)
  ELSIF IsKw("QUERY") THEN Next; RawWord(name); DesignQuery(name)
  ELSIF IsKw("VIEW") THEN Next; RawWord(name); ModifyFile(name, ".vue")
  ELSE Err("Unrecognized phrase/keyword in command.")
  END
END DoModify;

(* ====================================================================
   Report forms (.FRM)
   Stored as text, one KEY=value per line; columns between COLUMN
   and END lines.  Headings use ";" to break lines.
   ==================================================================== *)

PROCEDURE InitReport(VAR r: Report);
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO 3 DO r.title[i][0] := 0X END;
  r.pageW := 80; r.lMargin := 8; r.rMargin := 0; r.lines := 58;
  r.dbl := FALSE; r.ejectBefore := TRUE; r.ejectAfter := FALSE; r.plain := FALSE;
  r.group[0] := 0X; r.groupHead[0] := 0X; r.subGroup[0] := 0X; r.subHead[0] := 0X;
  r.summary := FALSE; r.groupEject := FALSE;
  r.nCols := 0
END InitReport;

PROCEDURE YN(b: BOOLEAN; VAR s: ARRAY OF CHAR);
BEGIN IF b THEN Cpy("Yes", s) ELSE Cpy("No", s) END END YN;

PROCEDURE PutKV(VAR w: Files.Rider; k, v: ARRAY OF CHAR);
BEGIN WriteStr(w, k); WriteStr(w, "="); WriteStr(w, v); Files.Write(w, 10) END PutKV;

PROCEDURE PutKI(VAR w: Files.Rider; k: ARRAY OF CHAR; n: INTEGER);
VAR s: Str;
BEGIN IntStr(n, s); PutKV(w, k, s) END PutKI;

PROCEDURE PutKB(VAR w: Files.Rider; k: ARRAY OF CHAR; b: BOOLEAN);
BEGIN IF b THEN PutKV(w, k, "Y") ELSE PutKV(w, k, "N") END END PutKB;

PROCEDURE SaveReport(VAR r: Report; path: ARRAY OF CHAR): BOOLEAN;
VAR f: Files.File; w: Files.Rider; i: INTEGER;
BEGIN
  f := Files.New(path);
  IF f = NIL THEN RETURN FALSE END;
  Files.Set(w, f, 0);
  WriteStr(w, "OBBASE REPORT 1"); Files.Write(w, 10);
  FOR i := 0 TO 3 DO PutKV(w, "TITLE", r.title[i]) END;
  PutKI(w, "WIDTH", r.pageW); PutKI(w, "LMARGIN", r.lMargin); PutKI(w, "RMARGIN", r.rMargin);
  PutKI(w, "LINES", r.lines); PutKB(w, "DOUBLE", r.dbl); PutKB(w, "EJECTBEFORE", r.ejectBefore);
  PutKB(w, "EJECTAFTER", r.ejectAfter); PutKB(w, "PLAIN", r.plain);
  PutKV(w, "GROUP", r.group); PutKV(w, "GROUPHEAD", r.groupHead);
  PutKB(w, "SUMMARY", r.summary); PutKB(w, "GROUPEJECT", r.groupEject);
  PutKV(w, "SUBGROUP", r.subGroup); PutKV(w, "SUBGROUPHEAD", r.subHead);
  FOR i := 0 TO r.nCols - 1 DO
    WriteStr(w, "COLUMN"); Files.Write(w, 10);
    PutKV(w, "CONTENTS", r.col[i].contents); PutKV(w, "HEADING", r.col[i].heading);
    PutKI(w, "WIDTH", r.col[i].width); PutKI(w, "DEC", r.col[i].dec);
    PutKB(w, "TOTAL", r.col[i].total);
    WriteStr(w, "END"); Files.Write(w, 10)
  END;
  Files.Register(f); Files.Close(f);
  RETURN TRUE
END SaveReport;

PROCEDURE LoadReport(VAR r: Report; path: ARRAY OF CHAR): BOOLEAN;
VAR f: Files.File; rd: Files.Rider; line, k, v: Str; p, nt, n: INTEGER; inCol: BOOLEAN;
BEGIN
  InitReport(r);
  f := Files.Old(path);
  IF f = NIL THEN RETURN FALSE END;
  Files.Set(rd, f, 0);
  nt := 0; inCol := FALSE;
  LOOP
    Files.ReadLine(rd, line);
    IF rd.eof & (line[0] = 0X) THEN EXIT END;
    n := SLen(line); IF (n > 0) & (line[n - 1] = 0DX) THEN line[n - 1] := 0X END;
    p := Strings.Pos("=", line);
    IF Eq(line, "COLUMN") THEN
      IF r.nCols < MaxCols THEN
        inCol := TRUE; INC(r.nCols);
        r.col[r.nCols - 1].contents[0] := 0X; r.col[r.nCols - 1].heading[0] := 0X;
        r.col[r.nCols - 1].width := 10; r.col[r.nCols - 1].dec := 0; r.col[r.nCols - 1].total := FALSE
      END
    ELSIF Eq(line, "END") THEN inCol := FALSE
    ELSIF p > 0 THEN
      Sub(line, 0, p, k); Sub(line, p + 1, 255, v);
      IF StrInt(v, n) THEN END;
      IF inCol THEN
        IF Eq(k, "CONTENTS") THEN Cpy(v, r.col[r.nCols - 1].contents)
        ELSIF Eq(k, "HEADING") THEN Cpy(v, r.col[r.nCols - 1].heading)
        ELSIF Eq(k, "WIDTH") THEN r.col[r.nCols - 1].width := n
        ELSIF Eq(k, "DEC") THEN r.col[r.nCols - 1].dec := n
        ELSIF Eq(k, "TOTAL") THEN r.col[r.nCols - 1].total := v[0] = "Y"
        END
      ELSIF Eq(k, "TITLE") THEN IF nt < 4 THEN Cpy(v, r.title[nt]); INC(nt) END
      ELSIF Eq(k, "WIDTH") THEN r.pageW := n
      ELSIF Eq(k, "LMARGIN") THEN r.lMargin := n
      ELSIF Eq(k, "RMARGIN") THEN r.rMargin := n
      ELSIF Eq(k, "LINES") THEN r.lines := n
      ELSIF Eq(k, "DOUBLE") THEN r.dbl := v[0] = "Y"
      ELSIF Eq(k, "EJECTBEFORE") THEN r.ejectBefore := v[0] = "Y"
      ELSIF Eq(k, "EJECTAFTER") THEN r.ejectAfter := v[0] = "Y"
      ELSIF Eq(k, "PLAIN") THEN r.plain := v[0] = "Y"
      ELSIF Eq(k, "GROUP") THEN Cpy(v, r.group)
      ELSIF Eq(k, "GROUPHEAD") THEN Cpy(v, r.groupHead)
      ELSIF Eq(k, "SUMMARY") THEN r.summary := v[0] = "Y"
      ELSIF Eq(k, "GROUPEJECT") THEN r.groupEject := v[0] = "Y"
      ELSIF Eq(k, "SUBGROUP") THEN Cpy(v, r.subGroup)
      ELSIF Eq(k, "SUBGROUPHEAD") THEN Cpy(v, r.subHead)
      END
    END;
    IF rd.eof THEN EXIT END
  END;
  Files.Close(f);
  RETURN TRUE
END LoadReport;

(* ---- generation ---- *)

VAR
  rpLine, rpPage: INTEGER;
  rpPrinting: BOOLEAN;

(* split s at ";" and wrap to w; returns lines in out *)
PROCEDURE WrapCol(s: ARRAY OF CHAR; w: INTEGER; VAR out: TextBuf);
VAR i, start, n, cut: INTEGER; seg, t: Str;
BEGIN
  out.n := 0;
  IF w < 1 THEN w := 1 END;
  i := 0;
  LOOP
    seg[0] := 0X;
    WHILE (s[i] # 0X) & (s[i] # ";") DO AppendCh(s[i], seg); INC(i) END;
    RTrim(seg);
    REPEAT
      n := SLen(seg);
      IF n <= w THEN Cpy(seg, t); seg[0] := 0X
      ELSE
        cut := w;
        WHILE (cut > 0) & (seg[cut] # " ") DO DEC(cut) END;
        IF cut = 0 THEN cut := w END;
        Sub(seg, 0, cut, t); Sub(seg, cut, 255, seg); LTrim(seg)
      END;
      IF out.n < 32 THEN Cpy(t, out.l[out.n]); INC(out.n) END
    UNTIL seg[0] = 0X;
    IF s[i] = ";" THEN INC(i) ELSE EXIT END
  END;
  start := 0
END WrapCol;

PROCEDURE RpEmit(s: ARRAY OF CHAR; lm: INTEGER);
VAR t: Str;
BEGIN
  Spaces(lm, t); Append(s, t); RTrim(t);
  Line(t);
  INC(rpLine)
END RpEmit;

PROCEDURE RpHeader(VAR r: Report; VAR c: Clauses; total: INTEGER);
VAR s, t: Str; i, j, maxh, w: INTEGER; hb: TextBuf;
BEGIN
  INC(rpPage); rpLine := 0;
  w := total; IF w < 1 THEN w := r.pageW - r.lMargin - r.rMargin END;
  IF ~(r.plain OR c.plain) OR (rpPage = 1) THEN
    IF ~(r.plain OR c.plain) THEN
      Cpy("Page No. ", s); IntStrW(rpPage, 5, t); Append(t, s); RpEmit(s, r.lMargin);
      DateStr(Today(), s); RpEmit(s, r.lMargin)
    END;
    OutNL; INC(rpLine);
    IF c.heading[0] # 0X THEN Cpy(c.heading, s); Center(s, w); RpEmit(s, r.lMargin) END;
    FOR i := 0 TO 3 DO
      IF r.title[i][0] # 0X THEN Cpy(r.title[i], s); Center(s, w); RpEmit(s, r.lMargin) END
    END;
    OutNL; INC(rpLine)
  END;
  (* column headings, bottom-aligned *)
  NEW(hb);
  maxh := 0;
  FOR j := 0 TO r.nCols - 1 DO WrapCol(r.col[j].heading, r.col[j].width, hb); maxh := MaxI(maxh, hb.n) END;
  IF (maxh = 1) THEN
    s[0] := 0X;
    FOR j := 0 TO r.nCols - 1 DO
      WrapCol(r.col[j].heading, r.col[j].width, hb);
      IF hb.l[0][0] = 0X THEN hb.l[0][0] := 0X END;
      Cpy(hb.l[0], t);
      IF r.col[j].dec > 0 THEN PadL(t, r.col[j].width) ELSE PadR(t, r.col[j].width) END;
      Append(t, s); Append(" ", s)
    END;
    RpEmit(s, r.lMargin)
  ELSE
    FOR i := 0 TO maxh - 1 DO
      s[0] := 0X;
      FOR j := 0 TO r.nCols - 1 DO
        WrapCol(r.col[j].heading, r.col[j].width, hb);
        IF i - (maxh - hb.n) >= 0 THEN Cpy(hb.l[i - (maxh - hb.n)], t) ELSE t[0] := 0X END;
        PadR(t, r.col[j].width); Append(t, s); Append(" ", s)
      END;
      RpEmit(s, r.lMargin)
    END
  END;
  OutNL; INC(rpLine)
END RpHeader;

PROCEDURE RpTotals(VAR r: Report; label: ARRAY OF CHAR; VAR tot: ARRAY OF REAL; any: BOOLEAN);
VAR s, t: Str; j: INTEGER;
BEGIN
  IF ~any THEN RETURN END;
  RpEmit(label, r.lMargin);
  s[0] := 0X;
  FOR j := 0 TO r.nCols - 1 DO
    IF r.col[j].total THEN FmtNumW(tot[j], r.col[j].width, r.col[j].dec, t)
    ELSE Spaces(r.col[j].width, t)
    END;
    Append(t, s); Append(" ", s)
  END;
  RpEmit(s, r.lMargin)
END RpTotals;

PROCEDURE RunReport(VAR r: Report; VAR c: Clauses);
VAR
  s: Scope; j, i, maxl, total, lm: INTEGER; v: Value; t, line, gval, sval, prevG, prevS: Str;
  cols: ARRAY MaxCols OF Node; gN, sN: Node; cell: ARRAY MaxCols OF TextBuf;
  gtot, stot, tot: ARRAY MaxCols OF REAL; anyTot, first: BOOLEAN;
BEGIN
  FOR j := 0 TO r.nCols - 1 DO
    cols[j] := CompileStr(r.col[j].contents);
    IF err THEN RETURN END;
    NEW(cell[j]);
    tot[j] := 0.0; gtot[j] := 0.0; stot[j] := 0.0
  END;
  gN := NIL; sN := NIL;
  IF r.group[0] # 0X THEN gN := CompileStr(r.group) END;
  IF r.subGroup[0] # 0X THEN sN := CompileStr(r.subGroup) END;
  IF err THEN RETURN END;
  anyTot := FALSE; total := 0;
  FOR j := 0 TO r.nCols - 1 DO
    IF r.col[j].total THEN anyTot := TRUE END;
    INC(total, r.col[j].width + 1)
  END;
  lm := r.lMargin;
  IF ~BeginTo(c) THEN RETURN END;
  rpPrinting := Printing() OR toActive;
  IF rpPrinting & r.ejectBefore & ~c.noEject & Printing() THEN PrnEject END;
  rpPage := 0;
  RpHeader(r, c, total);
  ScopeStart(s, c, scAll);
  first := TRUE;
  WHILE ScopeOK(s) DO
    (* group breaks *)
    IF gN # NIL THEN Eval(gN, v); ValText(v, gval) ELSE gval[0] := 0X END;
    IF sN # NIL THEN Eval(sN, v); ValText(v, sval) ELSE sval[0] := 0X END;
    IF err THEN EXIT END;
    IF (gN # NIL) & (first OR ~Eq(gval, prevG)) THEN
      IF ~first THEN
        IF sN # NIL THEN RpTotals(r, "** Subsubtotal **", stot, anyTot) END;
        RpTotals(r, "** Subtotal **", gtot, anyTot);
        OutNL; INC(rpLine);
        IF r.groupEject & Printing() THEN PrnEject; RpHeader(r, c, total) END
      END;
      FOR j := 0 TO r.nCols - 1 DO gtot[j] := 0.0; stot[j] := 0.0 END;
      Cpy("** ", line); Append(r.groupHead, line); Append(" ", line); Append(gval, line);
      RpEmit(line, lm);
      Cpy(gval, prevG); prevS[0] := 0X; first := TRUE
    END;
    IF (sN # NIL) & (first OR ~Eq(sval, prevS)) THEN
      IF ~first THEN RpTotals(r, "** Subsubtotal **", stot, anyTot) END;
      FOR j := 0 TO r.nCols - 1 DO stot[j] := 0.0 END;
      Cpy("* ", line); Append(r.subHead, line); Append(" ", line); Append(sval, line);
      RpEmit(line, lm);
      Cpy(sval, prevS)
    END;
    first := FALSE;
    (* detail line *)
    maxl := 1;
    FOR j := 0 TO r.nCols - 1 DO
      Eval(cols[j], v);
      IF err THEN EXIT END;
      IF v.t = TN THEN
        IF r.col[j].total THEN
          tot[j] := tot[j] + v.n; gtot[j] := gtot[j] + v.n; stot[j] := stot[j] + v.n
        END;
        FmtNumW(RoundTo(v.n, r.col[j].dec), r.col[j].width, r.col[j].dec, t);
        cell[j].n := 1; Cpy(t, cell[j].l[0])
      ELSE
        ValStr(v, t); WrapCol(t, r.col[j].width, cell[j])
      END;
      maxl := MaxI(maxl, cell[j].n)
    END;
    IF err THEN EXIT END;
    IF ~r.summary & ~c.summary THEN
      FOR i := 0 TO maxl - 1 DO
        line[0] := 0X;
        FOR j := 0 TO r.nCols - 1 DO
          IF i < cell[j].n THEN Cpy(cell[j].l[i], t) ELSE t[0] := 0X END;
          PadR(t, r.col[j].width); Append(t, line); Append(" ", line)
        END;
        RpEmit(line, lm)
      END;
      IF r.dbl THEN OutNL; INC(rpLine) END
    END;
    IF rpPrinting & (rpLine >= r.lines - 3) THEN
      IF Printing() THEN PrnEject END;
      RpHeader(r, c, total)
    END;
    ScopeAdvance(s)
  END;
  IF ~err THEN
    IF ~first THEN
      IF sN # NIL THEN RpTotals(r, "** Subsubtotal **", stot, anyTot) END;
      IF gN # NIL THEN RpTotals(r, "** Subtotal **", gtot, anyTot) END
    END;
    IF anyTot THEN OutNL; RpTotals(r, "*** Total ***", tot, TRUE) END;
    IF rpPrinting & r.ejectAfter & Printing() THEN PrnEject END
  END;
  EndTo
END RunReport;

PROCEDURE DoReportForm;
VAR name, path: Str; r: Report; c: Clauses; el: ExprList;
BEGIN
  IF ~IsKw("FORM") THEN Err("Syntax error."); RETURN END;
  Next;
  IF (tk = tOther) & (tkStr[0] = "?") THEN Next; IF ~PickFile(".frm", name) THEN RETURN END
  ELSE RawWord(name)
  END;
  ParseClauses(c, el, FALSE);
  IF err OR ~NeedDb() THEN RETURN END;
  IF ~FindFile(name, ".frm", path) THEN Err("File does not exist."); RETURN END;
  IF ~LoadReport(r, path) THEN Err("Not a valid report form."); RETURN END;
  paging := FALSE;
  RunReport(r, c)
END DoReportForm;

(* ---- report designer ---- *)

CONST nRMenus = 5;

PROCEDURE RptItem(VAR r: Report; m, i, cc: INTEGER; VAR label, val: ARRAY OF CHAR): BOOLEAN;
BEGIN
  val[0] := 0X;
  CASE m OF
    0:
      CASE i OF
        0: Cpy("Page title", label); Cpy(r.title[0], val);
           IF r.title[1][0] # 0X THEN Append(";", val); Append(r.title[1], val) END
      | 1: Cpy("Page width (positions)", label); IntStr(r.pageW, val)
      | 2: Cpy("Left margin", label); IntStr(r.lMargin, val)
      | 3: Cpy("Right margin", label); IntStr(r.rMargin, val)
      | 4: Cpy("Lines per page", label); IntStr(r.lines, val)
      | 5: Cpy("Double space report", label); YN(r.dbl, val)
      | 6: Cpy("Page eject before printing", label); YN(r.ejectBefore, val)
      | 7: Cpy("Page eject after printing", label); YN(r.ejectAfter, val)
      | 8: Cpy("Plain page", label); YN(r.plain, val)
      ELSE RETURN FALSE
      END
  | 1:
      CASE i OF
        0: Cpy("Group on expression", label); Cpy(r.group, val)
      | 1: Cpy("Group heading", label); Cpy(r.groupHead, val)
      | 2: Cpy("Summary report only", label); YN(r.summary, val)
      | 3: Cpy("Page eject after group", label); YN(r.groupEject, val)
      | 4: Cpy("Sub-group on expression", label); Cpy(r.subGroup, val)
      | 5: Cpy("Sub-group heading", label); Cpy(r.subHead, val)
      ELSE RETURN FALSE
      END
  | 2:
      IF cc >= r.nCols THEN
        IF i > 4 THEN RETURN FALSE END
      END;
      CASE i OF
        0: Cpy("Contents", label); IF cc < r.nCols THEN Cpy(r.col[cc].contents, val) END
      | 1: Cpy("Heading", label); IF cc < r.nCols THEN Cpy(r.col[cc].heading, val) END
      | 2: Cpy("Width", label); IF cc < r.nCols THEN IntStr(r.col[cc].width, val) END
      | 3: Cpy("Decimal places", label); IF cc < r.nCols THEN IntStr(r.col[cc].dec, val) END
      | 4: Cpy("Total this column", label); IF cc < r.nCols THEN YN(r.col[cc].total, val) END
      ELSE RETURN FALSE
      END
  | 3:
      IF i >= r.nCols THEN RETURN FALSE END;
      Cpy("Column ", label); AppendInt(i + 1, label); Cpy(r.col[i].contents, val)
  | 4:
      CASE i OF
        0: Cpy("Save", label) | 1: Cpy("Abandon", label)
      ELSE RETURN FALSE
      END
  END;
  RETURN TRUE
END RptItem;

(* default width for a column from its contents *)
PROCEDURE GuessWidth(contents: ARRAY OF CHAR; VAR w, dec: INTEGER; VAR isNum: BOOLEAN);
VAR v: Value; n: Node; s: Str;
BEGIN
  w := 10; dec := 0; isNum := FALSE;
  IF ~areas[cur].used THEN RETURN END;
  n := CompileStr(contents);
  IF err THEN err := FALSE; RETURN END;
  IF n.kind = nField THEN
    w := FieldWidth(n.area, n.fld); dec := areas[n.area].db.fields[n.fld].dec;
    isNum := areas[n.area].db.fields[n.fld].type = "N";
    RETURN
  END;
  EnsureRec(cur);
  Eval(n, v);
  IF err THEN err := FALSE; RETURN END;
  ValStr(v, s); w := MaxI(SLen(s), 1);
  IF v.t = TN THEN dec := v.dec; isNum := TRUE END
END GuessWidth;

PROCEDURE RptEdit(VAR r: Report; m, i: INTEGER; VAR cc: INTEGER; VAR leave, save: BOOLEAN);
VAR label, val, t: Str; n, w, d, k2: INTEGER; isNum: BOOLEAN;
BEGIN
  IF ~RptItem(r, m, i, cc, label, val) THEN RETURN END;
  IF m = 4 THEN leave := TRUE; save := i = 0; RETURN END;
  IF m = 3 THEN cc := i; RETURN END;
  IF (m = 2) & (cc >= r.nCols) THEN
    IF r.nCols >= MaxCols THEN RETURN END;
    cc := r.nCols; INC(r.nCols);
    r.col[cc].contents[0] := 0X; r.col[cc].heading[0] := 0X;
    r.col[cc].width := 10; r.col[cc].dec := 0; r.col[cc].total := FALSE
  END;
  IF (Eq(val, "Yes") OR Eq(val, "No")) & ((m # 2) OR (i = 4)) THEN
    CASE m OF
      0: CASE i OF 5: r.dbl := ~r.dbl | 6: r.ejectBefore := ~r.ejectBefore
         | 7: r.ejectAfter := ~r.ejectAfter | 8: r.plain := ~r.plain ELSE END
    | 1: IF i = 2 THEN r.summary := ~r.summary ELSE r.groupEject := ~r.groupEject END
    | 2: r.col[cc].total := ~r.col[cc].total
    ELSE
    END;
    RETURN
  END;
  Cpy(label, t); Append(":", t);
  IF ~FSPrompt(t, val) THEN RETURN END;
  k2 := 0;
  IF StrInt(val, n) THEN k2 := 1 END;
  CASE m OF
    0:
      CASE i OF
        0:
          FOR n := 0 TO 3 DO
            IF ~Strings.Split(val, ";", n, r.title[n]) THEN r.title[n][0] := 0X END
          END
      | 1: IF k2 = 1 THEN r.pageW := n END
      | 2: IF k2 = 1 THEN r.lMargin := n END
      | 3: IF k2 = 1 THEN r.rMargin := n END
      | 4: IF k2 = 1 THEN r.lines := n END
      ELSE
      END
  | 1:
      CASE i OF
        0: Cpy(val, r.group) | 1: Cpy(val, r.groupHead)
      | 4: Cpy(val, r.subGroup) | 5: Cpy(val, r.subHead)
      ELSE
      END
  | 2:
      CASE i OF
        0:
          Cpy(val, r.col[cc].contents);
          IF val[0] # 0X THEN
            IF areas[cur].used & (CompileStr(val) = NIL) THEN
              Cpy(errMsg, t); err := FALSE; FSMessage(t)
            END;
            err := FALSE;
            GuessWidth(val, w, d, isNum);
            r.col[cc].width := MaxI(w, SLen(r.col[cc].heading)); r.col[cc].dec := d;
            IF r.col[cc].heading[0] = 0X THEN Cpy(val, r.col[cc].heading); Upper(r.col[cc].heading) END
          END
      | 1: Cpy(val, r.col[cc].heading)
      | 2: IF k2 = 1 THEN r.col[cc].width := MaxI(1, n) END
      | 3: IF k2 = 1 THEN r.col[cc].dec := n END
      ELSE
      END
  ELSE
  END
END RptEdit;

PROCEDURE DesignReport(name: ARRAY OF CHAR);
VAR
  r: Report; path, s, label, val, t: Str; menu, item, cc, i, x, y, nItems, w: INTEGER;
  k: CHAR; leave, save: BOOLEAN; menus: ARRAY nRMenus OF Name; mx: ARRAY nRMenus OF INTEGER;
BEGIN
  IF batch THEN Err("Full-screen commands need the interactive mode."); RETURN END;
  IF name[0] = 0X THEN Err("Syntax error."); RETURN END;
  NewPath(name, ".frm", path);
  IF ~LoadReport(r, path) THEN InitReport(r) END;
  Cpy("Options", menus[0]); Cpy("Groups", menus[1]); Cpy("Columns", menus[2]);
  Cpy("Locate", menus[3]); Cpy("Exit", menus[4]);
  menu := 0; item := 0; cc := 0; leave := FALSE; save := FALSE;
  WHILE ~leave DO
    ScreenSize;
    FSClear;
    TUI.FillRect(1, 1, TUI.Cols, 1, " ", cRevFg, cRevBg);
    x := 2;
    FOR i := 0 TO nRMenus - 1 DO
      mx[i] := x;
      IF i = menu THEN TUI.PutStr(x, 1, menus[i], cMenuFg, cMenuBg) ELSE PutS(x, 1, menus[i], TRUE) END;
      INC(x, SLen(menus[i]) + 4)
    END;
    (* the pull-down for the current menu *)
    nItems := 0;
    WHILE RptItem(r, menu, nItems, cc, label, val) DO INC(nItems) END;
    IF item >= nItems THEN item := nItems - 1 END;
    IF item < 0 THEN item := 0 END;
    w := 60; IF mx[menu] + w > TUI.Cols THEN w := TUI.Cols - mx[menu] END;
    Box(mx[menu] - 1, 2, w, MaxI(nItems, 1) + 2 + ORD(menu = 2));
    y := 3;
    IF menu = 2 THEN
      Cpy("Column ", s); AppendInt(cc + 1, s); Append(" of ", s); AppendInt(MaxI(r.nCols, cc + 1), s);
      PutHi(mx[menu] + 1, y, s); INC(y)
    END;
    FOR i := 0 TO nItems - 1 DO
      IF RptItem(r, menu, i, cc, label, val) THEN
        PadR(label, 28); Append(val, label); label[w - 4] := 0X;
        PutS(mx[menu] + 1, y + i, label, i = item)
      END
    END;
    (* report format preview *)
    y := scrH - 3;
    PutHi(2, y, "Report Format");
    s[0] := 0X; t[0] := 0X;
    FOR i := 0 TO r.nCols - 1 DO
      Cpy(r.col[i].heading, val); IF Strings.Split(r.col[i].heading, ";", 0, val) THEN END;
      PadR(val, r.col[i].width); Append(val, s); Append(" ", s);
      Spaces(0, val);
      FOR x := 1 TO r.col[i].width DO IF r.col[i].dec > 0 THEN AppendCh("9", val) ELSE AppendCh("X", val) END END;
      Append(val, t); Append(" ", t)
    END;
    s[TUI.Cols - 4] := 0X; t[TUI.Cols - 4] := 0X;
    PutS(3, y + 1, s, FALSE); PutS(3, y + 2, t, FALSE);
    Cpy("Position selection bar - Up/Down.  Select - Enter.  Leave menu - Left/Right.", fsNav);
    IF menu = 2 THEN Append("  PgUp/PgDn column, ^N insert, ^U delete", fsNav) END;
    Cpy("Report: ", fsMsg); ShortName(path, s); Append(s, fsMsg);
    FSBars("CREATE REPORT");
    fsMsg[0] := 0X; fsNav[0] := 0X;
    FSFlush(1, 1, FALSE);
    k := GetKey();
    IF (k = TUI.KLeft) OR (k = KCtrlS) THEN menu := (menu + nRMenus - 1) MOD nRMenus; item := 0
    ELSIF (k = TUI.KRight) OR (k = KCtrlD) THEN menu := (menu + 1) MOD nRMenus; item := 0
    ELSIF (k = TUI.KUp) OR (k = KCtrlE) THEN DEC(item)
    ELSIF (k = TUI.KDown) OR (k = KCtrlX) THEN INC(item)
    ELSIF k = TUI.KEnter THEN
      RptEdit(r, menu, item, cc, leave, save);
      IF menu = 3 THEN menu := 2; item := 0 END
    ELSIF (menu = 2) & (k = TUI.KPgDn) THEN IF cc < r.nCols THEN INC(cc) END
    ELSIF (menu = 2) & (k = TUI.KPgUp) THEN IF cc > 0 THEN DEC(cc) END
    ELSIF (menu = 2) & (k = KCtrlN) THEN
      IF r.nCols < MaxCols THEN
        FOR i := r.nCols TO cc + 1 BY -1 DO r.col[i] := r.col[i - 1] END;
        r.col[cc].contents[0] := 0X; r.col[cc].heading[0] := 0X;
        r.col[cc].width := 10; r.col[cc].dec := 0; r.col[cc].total := FALSE;
        INC(r.nCols)
      END
    ELSIF (menu = 2) & (k = KCtrlU) THEN
      IF cc < r.nCols THEN
        FOR i := cc TO r.nCols - 2 DO r.col[i] := r.col[i + 1] END;
        DEC(r.nCols)
      END
    ELSIF (k = TUI.KEsc) THEN
      IF FSAsk("Abandon this report form? (Y/N)") THEN leave := TRUE; save := FALSE END
    ELSIF (k = KCtrlW) OR (k = TUI.KCtrlEnd) THEN leave := TRUE; save := TRUE
    END
  END;
  (* drop empty trailing columns *)
  WHILE (r.nCols > 0) & (r.col[r.nCols - 1].contents[0] = 0X) DO DEC(r.nCols) END;
  IF save & ~SaveReport(r, path) THEN Err("Unable to create file.") END;
  ConClear;
  TUI.InvalidateFront
END DesignReport;

(* ====================================================================
   Label forms (.LBL)
   ==================================================================== *)

PROCEDURE InitLabel(VAR l: LabelDef);
VAR i: INTEGER;
BEGIN
  l.width := 35; l.height := 5; l.lMargin := 0; l.linesBetween := 1;
  l.spacesBetween := 0; l.across := 1; Cpy("3 1/2 x 15/16 by 1", l.remarks);
  FOR i := 0 TO 15 DO l.line[i][0] := 0X END
END InitLabel;

PROCEDURE PresetLabel(VAR l: LabelDef; n: INTEGER);
BEGIN
  CASE n OF
    0: l.width := 35; l.height := 5; l.across := 1; l.spacesBetween := 0; l.linesBetween := 1; Cpy("3 1/2 x 15/16 by 1", l.remarks)
  | 1: l.width := 35; l.height := 5; l.across := 2; l.spacesBetween := 2; l.linesBetween := 1; Cpy("3 1/2 x 15/16 by 2", l.remarks)
  | 2: l.width := 35; l.height := 5; l.across := 3; l.spacesBetween := 2; l.linesBetween := 1; Cpy("3 1/2 x 15/16 by 3", l.remarks)
  | 3: l.width := 40; l.height := 8; l.across := 1; l.spacesBetween := 0; l.linesBetween := 1; Cpy("4 x 1 7/16 by 1", l.remarks)
  | 4: l.width := 32; l.height := 5; l.across := 3; l.spacesBetween := 2; l.linesBetween := 1; Cpy("3 2/10 x 11/12 by 3 (Cheshire)", l.remarks)
  | 5: l.width := 30; l.height := 10; l.across := 1; l.spacesBetween := 0; l.linesBetween := 2; Cpy("3 x 5/3 Rolodex", l.remarks)
  | 6: l.width := 50; l.height := 14; l.across := 1; l.spacesBetween := 0; l.linesBetween := 1; Cpy("4 x 2 1/4 Rolodex", l.remarks)
  ELSE
  END
END PresetLabel;

PROCEDURE SaveLabel(VAR l: LabelDef; path: ARRAY OF CHAR): BOOLEAN;
VAR f: Files.File; w: Files.Rider; i: INTEGER;
BEGIN
  f := Files.New(path);
  IF f = NIL THEN RETURN FALSE END;
  Files.Set(w, f, 0);
  WriteStr(w, "OBBASE LABEL 1"); Files.Write(w, 10);
  PutKI(w, "WIDTH", l.width); PutKI(w, "HEIGHT", l.height); PutKI(w, "LMARGIN", l.lMargin);
  PutKI(w, "LINESBETWEEN", l.linesBetween); PutKI(w, "SPACESBETWEEN", l.spacesBetween);
  PutKI(w, "ACROSS", l.across); PutKV(w, "REMARKS", l.remarks);
  FOR i := 0 TO l.height - 1 DO PutKV(w, "LINE", l.line[i]) END;
  Files.Register(f); Files.Close(f);
  RETURN TRUE
END SaveLabel;

PROCEDURE LoadLabel(VAR l: LabelDef; path: ARRAY OF CHAR): BOOLEAN;
VAR f: Files.File; rd: Files.Rider; line, k, v: Str; p, n, nl: INTEGER;
BEGIN
  InitLabel(l);
  f := Files.Old(path);
  IF f = NIL THEN RETURN FALSE END;
  Files.Set(rd, f, 0); nl := 0;
  LOOP
    Files.ReadLine(rd, line);
    IF rd.eof & (line[0] = 0X) THEN EXIT END;
    n := SLen(line); IF (n > 0) & (line[n - 1] = 0DX) THEN line[n - 1] := 0X END;
    p := Strings.Pos("=", line);
    IF p > 0 THEN
      Sub(line, 0, p, k); Sub(line, p + 1, 255, v);
      IF StrInt(v, n) THEN END;
      IF Eq(k, "WIDTH") THEN l.width := n
      ELSIF Eq(k, "HEIGHT") THEN l.height := MinI(MaxI(n, 1), 16)
      ELSIF Eq(k, "LMARGIN") THEN l.lMargin := n
      ELSIF Eq(k, "LINESBETWEEN") THEN l.linesBetween := n
      ELSIF Eq(k, "SPACESBETWEEN") THEN l.spacesBetween := n
      ELSIF Eq(k, "ACROSS") THEN l.across := MinI(MaxI(n, 1), 15)
      ELSIF Eq(k, "REMARKS") THEN Cpy(v, l.remarks)
      ELSIF Eq(k, "LINE") THEN IF nl < 16 THEN Cpy(v, l.line[nl]); INC(nl) END
      END
    END;
    IF rd.eof THEN EXIT END
  END;
  Files.Close(f);
  RETURN TRUE
END LoadLabel;

(* evaluate one label line: comma-separated expressions are trimmed
   and joined with single blanks *)
PROCEDURE LabelLine(src2: ARRAY OF CHAR; VAR out: ARRAY OF CHAR);
VAR i, depth2, start: INTEGER; q: CHAR; part, t: Str; v: Value;
BEGIN
  out[0] := 0X;
  IF src2[0] = 0X THEN RETURN END;
  i := 0; depth2 := 0; q := 0X; start := 0;
  LOOP
    IF (src2[i] = 0X) OR ((src2[i] = ",") & (depth2 = 0) & (q = 0X)) THEN
      Sub(src2, start, i - start, part); Trim(part);
      IF part[0] # 0X THEN
        EvalString(part, v);
        IF err THEN RETURN END;
        ValText(v, t); Trim(t);
        IF t[0] # 0X THEN
          IF out[0] # 0X THEN Append(" ", out) END;
          Append(t, out)
        END
      END;
      IF src2[i] = 0X THEN EXIT END;
      start := i + 1
    ELSIF q # 0X THEN IF src2[i] = q THEN q := 0X END
    ELSIF (src2[i] = "'") OR (src2[i] = '"') THEN q := src2[i]
    ELSIF src2[i] = "(" THEN INC(depth2)
    ELSIF src2[i] = ")" THEN DEC(depth2)
    END;
    INC(i)
  END
END LabelLine;

PROCEDURE RunLabels(VAR l: LabelDef; VAR c: Clauses);
VAR
  s: Scope; blk: TextBuf; nb, i, j, row, k: INTEGER; line, t: Str; ok: BOOLEAN;
BEGIN
  IF ~BeginTo(c) THEN RETURN END;
  NEW(blk);
  IF c.sample THEN
    LOOP
      FOR row := 0 TO l.height - 1 DO
        Spaces(l.lMargin, line);
        FOR k := 0 TO l.across - 1 DO
          FOR i := 1 TO l.width DO AppendCh("X", line) END;
          Spaces(l.spacesBetween, t); Append(t, line)
        END;
        Line(line)
      END;
      FOR i := 1 TO l.linesBetween DO OutNL END;
      IF batch OR ~AskYN("Do you want more samples? (Y/N)") THEN EXIT END
    END
  END;
  ScopeStart(s, c, scAll);
  nb := 0;
  ok := TRUE;
  WHILE ok DO
    ok := ScopeOK(s);
    IF ok THEN
      (* build one label, blank lines squeezed out *)
      j := 0;
      FOR i := 0 TO l.height - 1 DO
        LabelLine(l.line[i], t);
        IF err THEN RETURN END;
        t[l.width] := 0X;
        IF t[0] # 0X THEN Cpy(t, blk.l[nb * 16 + j]); INC(j) END
      END;
      WHILE j < l.height DO blk.l[nb * 16 + j][0] := 0X; INC(j) END;
      INC(nb);
      ScopeAdvance(s)
    END;
    IF (nb = l.across) OR (~ok & (nb > 0)) THEN
      FOR row := 0 TO l.height - 1 DO
        Spaces(l.lMargin, line);
        FOR k := 0 TO nb - 1 DO
          Cpy(blk.l[k * 16 + row], t);
          IF k < nb - 1 THEN PadR(t, l.width + l.spacesBetween) END;
          Append(t, line)
        END;
        RTrim(line);
        Line(line)
      END;
      FOR i := 1 TO l.linesBetween DO OutNL END;
      nb := 0
    END
  END;
  EndTo
END RunLabels;

PROCEDURE DoLabelForm;
VAR name, path: Str; l: LabelDef; c: Clauses; el: ExprList;
BEGIN
  IF ~IsKw("FORM") THEN Err("Syntax error."); RETURN END;
  Next;
  IF (tk = tOther) & (tkStr[0] = "?") THEN Next; IF ~PickFile(".lbl", name) THEN RETURN END
  ELSE RawWord(name)
  END;
  ParseClauses(c, el, FALSE);
  IF err OR ~NeedDb() THEN RETURN END;
  IF ~FindFile(name, ".lbl", path) THEN Err("File does not exist."); RETURN END;
  IF ~LoadLabel(l, path) THEN Err("Not a valid label form."); RETURN END;
  RunLabels(l, c)
END DoLabelForm;

PROCEDURE DesignLabel(name: ARRAY OF CHAR);
VAR
  l: LabelDef; path, s, t, label: Str; menu, item, i, preset, n, nItems, y: INTEGER; k: CHAR;
  leave, save: BOOLEAN;
BEGIN
  IF batch THEN Err("Full-screen commands need the interactive mode."); RETURN END;
  IF name[0] = 0X THEN Err("Syntax error."); RETURN END;
  NewPath(name, ".lbl", path);
  IF ~LoadLabel(l, path) THEN InitLabel(l) END;
  menu := 0; item := 0; preset := 0; leave := FALSE; save := FALSE;
  WHILE ~leave DO
    ScreenSize;
    FSClear;
    TUI.FillRect(1, 1, TUI.Cols, 1, " ", cRevFg, cRevBg);
    IF menu = 0 THEN TUI.PutStr(2, 1, "Options", cMenuFg, cMenuBg) ELSE PutS(2, 1, "Options", TRUE) END;
    IF menu = 1 THEN TUI.PutStr(13, 1, "Contents", cMenuFg, cMenuBg) ELSE PutS(13, 1, "Contents", TRUE) END;
    IF menu = 2 THEN TUI.PutStr(25, 1, "Exit", cMenuFg, cMenuBg) ELSE PutS(25, 1, "Exit", TRUE) END;
    IF menu = 0 THEN nItems := 8 ELSIF menu = 1 THEN nItems := l.height ELSE nItems := 2 END;
    IF item >= nItems THEN item := nItems - 1 END;
    IF item < 0 THEN item := 0 END;
    Box(2, 2, MinI(TUI.Cols - 2, 76), nItems + 2);
    FOR i := 0 TO nItems - 1 DO
      IF menu = 0 THEN
        CASE i OF
          0: Cpy("Predefined size:", label); Cpy(l.remarks, s)
        | 1: Cpy("Label width:", label); IntStr(l.width, s)
        | 2: Cpy("Label height:", label); IntStr(l.height, s)
        | 3: Cpy("Left margin:", label); IntStr(l.lMargin, s)
        | 4: Cpy("Lines between labels:", label); IntStr(l.linesBetween, s)
        | 5: Cpy("Spaces between labels:", label); IntStr(l.spacesBetween, s)
        | 6: Cpy("Labels across page:", label); IntStr(l.across, s)
        | 7: Cpy("Remarks:", label); Cpy(l.remarks, s)
        END
      ELSIF menu = 1 THEN Cpy("Label contents ", label); AppendInt(i + 1, label); Append(":", label); Cpy(l.line[i], s)
      ELSE IF i = 0 THEN Cpy("Save", label) ELSE Cpy("Abandon", label) END; s[0] := 0X
      END;
      PadR(label, 24); Append(s, label); label[MinI(TUI.Cols - 6, 72)] := 0X;
      PutS(4, 3 + i, label, i = item)
    END;
    (* preview of the label shape *)
    y := nItems + 5;
    IF (menu = 1) & (y + l.height < scrH) THEN
      FOR i := 0 TO l.height - 1 DO
        Spaces(0, t); FOR n := 1 TO MinI(l.width, TUI.Cols - 6) DO AppendCh(".", t) END;
        PutS(4, y + i, t, FALSE)
      END
    END;
    Cpy("Position selection bar - Up/Down.  Select - Enter.  Leave menu - Left/Right.", fsNav);
    Cpy("Label: ", fsMsg); ShortName(path, s); Append(s, fsMsg);
    FSBars("CREATE LABEL");
    fsMsg[0] := 0X; fsNav[0] := 0X;
    FSFlush(1, 1, FALSE);
    k := GetKey();
    IF (k = TUI.KLeft) OR (k = KCtrlS) THEN menu := (menu + 2) MOD 3; item := 0
    ELSIF (k = TUI.KRight) OR (k = KCtrlD) THEN menu := (menu + 1) MOD 3; item := 0
    ELSIF (k = TUI.KUp) OR (k = KCtrlE) THEN DEC(item)
    ELSIF (k = TUI.KDown) OR (k = KCtrlX) THEN INC(item)
    ELSIF (k = KCtrlW) OR (k = TUI.KCtrlEnd) THEN leave := TRUE; save := TRUE
    ELSIF k = TUI.KEsc THEN IF FSAsk("Abandon this label form? (Y/N)") THEN leave := TRUE END
    ELSIF k = TUI.KEnter THEN
      IF menu = 2 THEN leave := TRUE; save := item = 0
      ELSIF (menu = 0) & (item = 0) THEN preset := (preset + 1) MOD 7; PresetLabel(l, preset)
      ELSIF menu = 0 THEN
        CASE item OF
          1: IntStr(l.width, s) | 2: IntStr(l.height, s) | 3: IntStr(l.lMargin, s)
        | 4: IntStr(l.linesBetween, s) | 5: IntStr(l.spacesBetween, s) | 6: IntStr(l.across, s)
        | 7: Cpy(l.remarks, s)
        END;
        IF FSPrompt("Value:", s) THEN
          IF item = 7 THEN Cpy(s, l.remarks)
          ELSIF StrInt(s, n) THEN
            CASE item OF
              1: l.width := MinI(MaxI(n, 1), 120) | 2: l.height := MinI(MaxI(n, 1), 16)
            | 3: l.lMargin := MaxI(n, 0) | 4: l.linesBetween := MinI(MaxI(n, 0), 16)
            | 5: l.spacesBetween := MinI(MaxI(n, 0), 120) | 6: l.across := MinI(MaxI(n, 1), 15)
            END
          END
        END
      ELSE
        Cpy(l.line[item], s);
        IF FSPrompt("Contents:", s) THEN Cpy(s, l.line[item]) END
      END
    END
  END;
  IF save & ~SaveLabel(l, path) THEN Err("Unable to create file.") END;
  ConClear;
  TUI.InvalidateFront
END DesignLabel;

(* ====================================================================
   Query files (.QRY): the Set Filter screen
   ==================================================================== *)

CONST MaxQRows = 7; nOps = 7; nConn = 5;

TYPE
  QueryDef = RECORD
    n: INTEGER;
    fld: ARRAY MaxQRows OF Name;
    op, conn: ARRAY MaxQRows OF INTEGER;
    val: ARRAY MaxQRows OF Str
  END;

PROCEDURE OpName(i: INTEGER; VAR s, sym: ARRAY OF CHAR);
BEGIN
  CASE i OF
    0: Cpy("=  Matches", s); Cpy("=", sym)
  | 1: Cpy("<> Does not match", s); Cpy("<>", sym)
  | 2: Cpy(">  More than", s); Cpy(">", sym)
  | 3: Cpy("<  Less than", s); Cpy("<", sym)
  | 4: Cpy(">= More than or equal", s); Cpy(">=", sym)
  | 5: Cpy("<= Less than or equal", s); Cpy("<=", sym)
  | 6: Cpy("$  Contains", s); Cpy("$", sym)
  END
END OpName;

PROCEDURE ConnName(i: INTEGER; VAR s, sym: ARRAY OF CHAR);
BEGIN
  CASE i OF
    0: Cpy("No combination", s); sym[0] := 0X
  | 1: Cpy("Combine with .AND.", s); Cpy(".AND.", sym)
  | 2: Cpy("Combine with .OR.", s); Cpy(".OR.", sym)
  | 3: Cpy("Combine with .AND. .NOT.", s); Cpy(".AND. .NOT.", sym)
  | 4: Cpy("Combine with .OR. .NOT.", s); Cpy(".OR. .NOT.", sym)
  END
END ConnName;

PROCEDURE QueryExpr(VAR q: QueryDef; VAR out: ARRAY OF CHAR);
VAR i, f: INTEGER; t, sym, dummy, c: Str; ty: CHAR;
BEGIN
  out[0] := 0X;
  FOR i := 0 TO q.n - 1 DO
    IF q.fld[i][0] # 0X THEN
      f := FieldIdx(cur, q.fld[i]); ty := "C";
      IF f >= 0 THEN ty := areas[cur].db.fields[f].type END;
      Cpy(q.val[i], c); Trim(c);
      IF ty = "C" THEN
        IF (c[0] # "'") & (c[0] # '"') THEN Strings.Insert("'", 0, c); Append("'", c) END
      ELSIF ty = "D" THEN
        IF ~StartsI(c, "CTOD") THEN Strings.Insert("CTOD('", 0, c); Append("')", c) END
      ELSIF ty = "L" THEN
        IF c[0] # "." THEN Strings.Insert(".", 0, c); Append(".", c) END
      END;
      OpName(q.op[i], dummy, sym);
      IF q.op[i] = 6 THEN Cpy(c, t); Append(" $ ", t); Append(q.fld[i], t)
      ELSE Cpy(q.fld[i], t); Append(" ", t); Append(sym, t); Append(" ", t); Append(c, t)
      END;
      Append(t, out);
      ConnName(q.conn[i], dummy, sym);
      IF (sym[0] # 0X) & (i < q.n - 1) & (q.fld[i + 1][0] # 0X) THEN Append(" ", out); Append(sym, out); Append(" ", out) END
    END
  END
END QueryExpr;

PROCEDURE SaveQuery(VAR q: QueryDef; path: ARRAY OF CHAR): BOOLEAN;
VAR f: Files.File; w: Files.Rider; i: INTEGER; line, ex: Str;
BEGIN
  f := Files.New(path);
  IF f = NIL THEN RETURN FALSE END;
  Files.Set(w, f, 0);
  WriteStr(w, "OBBASE QUERY 1"); Files.Write(w, 10);
  FOR i := 0 TO q.n - 1 DO
    Cpy(q.fld[i], line); AppendCh("|", line); AppendInt(q.op[i], line); AppendCh("|", line);
    AppendInt(q.conn[i], line); AppendCh("|", line); Append(q.val[i], line);
    PutKV(w, "ROW", line)
  END;
  QueryExpr(q, ex);
  PutKV(w, "FILTER", ex);
  Files.Register(f); Files.Close(f);
  RETURN TRUE
END SaveQuery;

PROCEDURE LoadQuery(VAR q: QueryDef; path: ARRAY OF CHAR);
VAR f: Files.File; rd: Files.Rider; line, t: Str; n, k: INTEGER;
BEGIN
  q.n := 0;
  f := Files.Old(path);
  IF f = NIL THEN RETURN END;
  Files.Set(rd, f, 0);
  LOOP
    Files.ReadLine(rd, line);
    IF rd.eof & (line[0] = 0X) THEN EXIT END;
    IF StartsI(line, "ROW=") & (q.n < MaxQRows) THEN
      Sub(line, 4, 255, line);
      IF Strings.Split(line, "|", 0, t) THEN Cpy(t, q.fld[q.n]) END;
      IF Strings.Split(line, "|", 1, t) & StrInt(t, n) THEN q.op[q.n] := n ELSE q.op[q.n] := 0 END;
      IF Strings.Split(line, "|", 2, t) & StrInt(t, n) THEN q.conn[q.n] := n ELSE q.conn[q.n] := 0 END;
      k := 0; n := 0;
      WHILE (line[k] # 0X) & (n < 3) DO IF line[k] = "|" THEN INC(n) END; INC(k) END;
      Sub(line, k, 255, q.val[q.n]);
      INC(q.n)
    END;
    IF rd.eof THEN EXIT END
  END;
  Files.Close(f)
END LoadQuery;

PROCEDURE QueryPreview(VAR q: QueryDef);
VAR ex, line, t: Str; n: Node; i, f, y, shown: INTEGER; k: CHAR; ok: BOOLEAN;
BEGIN
  QueryExpr(q, ex);
  FSClear;
  PutHi(2, 1, "Filter: "); PutS(10, 1, ex, FALSE);
  y := 3; shown := 0;
  IF ex[0] # 0X THEN n := CompileStr(ex) ELSE n := NIL END;
  IF err THEN Cpy(errMsg, t); err := FALSE; PutS(2, y, t, FALSE)
  ELSE
    GoTop(cur);
    WHILE ~areas[cur].eof & (y < TUI.Rows - 4) DO
      ok := TRUE;
      IF n # NIL THEN ok := EvalBool(n); IF err THEN err := FALSE; ok := FALSE END END;
      IF ok THEN
        IntStrW(areas[cur].rec, 6, line); Append(" ", line);
        FOR f := 0 TO MinI(areas[cur].db.numFields, 8) - 1 DO
          FieldToText(cur, f, t); Append(t, line); Append(" ", line)
        END;
        line[TUI.Cols - 2] := 0X;
        PutS(1, y, line, FALSE); INC(y); INC(shown)
      END;
      IF ~Step(cur, 1) THEN END
    END
  END;
  PutHi(2, TUI.Rows - 2, "Press any key to continue");
  FSFlush(1, 1, FALSE);
  REPEAT k := GetKey() UNTIL k # 0X;
  GoTop(cur)
END QueryPreview;

PROCEDURE DesignQuery(name: ARRAY OF CHAR);
VAR
  q: QueryDef; path, s, sym, t: Str; row, col, i, y, f: INTEGER; k: CHAR; leave, save: BOOLEAN;
BEGIN
  IF batch THEN Err("Full-screen commands need the interactive mode."); RETURN END;
  IF ~NeedDb() THEN RETURN END;
  IF name[0] = 0X THEN Err("Syntax error."); RETURN END;
  NewPath(name, ".qry", path);
  LoadQuery(q, path);
  FOR i := q.n TO MaxQRows - 1 DO q.fld[i][0] := 0X; q.op[i] := 0; q.conn[i] := 0; q.val[i][0] := 0X END;
  q.n := MaxQRows;
  row := 0; col := 0; leave := FALSE; save := FALSE;
  WHILE ~leave DO
    ScreenSize;
    FSClear;
    TUI.FillRect(1, 1, TUI.Cols, 1, " ", cRevFg, cRevBg);
    PutS(2, 1, "Set Filter    Display: F2    Exit: ^W save, Esc abandon", TRUE);
    PutHi(2, 3, "Line  Field Name   Operator                Constant/Expression     Connect");
    FOR i := 0 TO MaxQRows - 1 DO
      y := 4 + i;
      IntStrW(i + 1, 4, s); PutS(1, y, s, FALSE);
      Cpy(q.fld[i], s); PadR(s, 11); PutS(7, y, s, (i = row) & (col = 0));
      IF q.fld[i][0] # 0X THEN OpName(q.op[i], s, sym) ELSE s[0] := 0X END;
      PadR(s, 22); PutS(20, y, s, (i = row) & (col = 1));
      Cpy(q.val[i], s); s[22] := 0X; PadR(s, 22); PutS(44, y, s, (i = row) & (col = 2));
      IF q.fld[i][0] # 0X THEN ConnName(q.conn[i], s, sym); IF q.conn[i] = 0 THEN s[0] := 0X END ELSE s[0] := 0X END;
      s[MaxI(TUI.Cols - 68, 1)] := 0X; PutS(68, y, s, (i = row) & (col = 3))
    END;
    QueryExpr(q, t);
    PutHi(2, 13, "Filter:"); t[TUI.Cols - 12] := 0X; PutS(10, 13, t, FALSE);
    CASE col OF
      0: Cpy("Field: Space/arrows cycle through the fields, or Enter to type a name.", fsMsg)
    | 1: Cpy("Operator: Space cycles; Enter moves on.", fsMsg)
    | 2: Cpy("Enter to type the constant or expression.", fsMsg)
    | 3: Cpy("Connect: Space cycles .AND./.OR. combinations.", fsMsg)
    END;
    Cpy("Move: arrows   Select: Enter   Delete line: ^U   Display matches: F2", fsNav);
    FSBars("CREATE QUERY");
    fsMsg[0] := 0X; fsNav[0] := 0X;
    FSFlush(1, 1, FALSE);
    k := GetKey();
    IF (k = TUI.KUp) OR (k = KCtrlE) THEN IF row > 0 THEN DEC(row) END
    ELSIF (k = TUI.KDown) OR (k = KCtrlX) THEN IF row < MaxQRows - 1 THEN INC(row) END
    ELSIF (k = TUI.KLeft) OR (k = KCtrlS) THEN IF col > 0 THEN DEC(col) END
    ELSIF (k = TUI.KRight) OR (k = KCtrlD) OR (k = TUI.KTab) THEN IF col < 3 THEN INC(col) END
    ELSIF (k = KCtrlW) OR (k = TUI.KCtrlEnd) THEN leave := TRUE; save := TRUE
    ELSIF k = TUI.KEsc THEN IF FSAsk("Abandon this query? (Y/N)") THEN leave := TRUE END
    ELSIF k = TUI.KF2 THEN QueryPreview(q)
    ELSIF k = KCtrlU THEN
      FOR i := row TO MaxQRows - 2 DO
        Cpy(q.fld[i + 1], q.fld[i]); q.op[i] := q.op[i + 1]; q.conn[i] := q.conn[i + 1]; Cpy(q.val[i + 1], q.val[i])
      END;
      q.fld[MaxQRows - 1][0] := 0X; q.val[MaxQRows - 1][0] := 0X
    ELSIF k = " " THEN
      CASE col OF
        0:
          f := FieldIdx(cur, q.fld[row]) + 1;
          IF f >= areas[cur].db.numFields THEN f := 0 END;
          Cpy(areas[cur].db.fields[f].name, q.fld[row])
      | 1: q.op[row] := (q.op[row] + 1) MOD nOps
      | 3: q.conn[row] := (q.conn[row] + 1) MOD nConn
      ELSE
      END
    ELSIF k = TUI.KEnter THEN
      IF col = 0 THEN
        Cpy(q.fld[row], s);
        IF FSPrompt("Field name:", s) THEN
          Upper(s);
          IF (s[0] = 0X) OR (FieldIdx(cur, s) >= 0) THEN Cpy(s, q.fld[row]); col := 1 ELSE FSMessage("Field not found") END
        END
      ELSIF col = 2 THEN
        Cpy(q.val[row], s);
        IF FSPrompt("Constant/Expression:", s) THEN Cpy(s, q.val[row]); col := 3 END
      ELSIF col = 1 THEN col := 2
      ELSE
        IF row < MaxQRows - 1 THEN INC(row) END; col := 0
      END
    END
  END;
  IF save THEN
    q.n := MaxQRows;
    WHILE (q.n > 0) & (q.fld[q.n - 1][0] = 0X) DO DEC(q.n) END;
    IF ~SaveQuery(q, path) THEN Err("Unable to create file.") END
  END;
  ConClear;
  TUI.InvalidateFront
END DesignQuery;

(* ====================================================================
   HELP
   ==================================================================== *)

CONST MaxHelp = 180;

VAR
  hName: ARRAY MaxHelp OF Name;
  hSyn, hDesc: ARRAY MaxHelp OF Str;
  nHelp: INTEGER;

PROCEDURE H(name, syn, desc: ARRAY OF CHAR);
BEGIN
  IF nHelp < MaxHelp THEN
    Cpy(name, hName[nHelp]); Cpy(syn, hSyn[nHelp]); Cpy(desc, hDesc[nHelp]); INC(nHelp)
  END
END H;

PROCEDURE InitHelp;
BEGIN
  nHelp := 0;
  H("?", "? [<expression list>]  /  ?? [<expression list>]", "Displays the values of expressions. ? starts a new line first; ?? continues on the current line.");
  H("@", "@ <row>,<col> [SAY <exp> [PICTURE <c>]] [GET <var> [PICTURE <c>] [RANGE <lo>,<hi>]] | CLEAR [TO r,c] | TO r,c [DOUBLE]", "Places output or an input field at a screen position.  GETs are edited by READ.");
  H("ACCEPT", "ACCEPT [<prompt>] TO <memvar>", "Waits for a line of text and stores it as a character string.");
  H("APPEND", "APPEND [BLANK]  /  APPEND FROM <file> [FOR <cond>] [SDF | DELIMITED [WITH <c>]]", "Adds records at the end of the database: full screen, a blank record, or copied from another file.  Press Enter on the first field of an empty record to finish.");
  H("ASSIST", "ASSIST", "Starts the menu-driven Assistant.  Esc leaves it for the dot prompt.");
  H("AVERAGE", "AVERAGE [<exp list>] [<scope>] [FOR <cond>] [WHILE <cond>] [TO <memvar list>]", "Computes the arithmetic mean of numeric expressions.");
  H("BROWSE", "BROWSE [FIELDS <field list>] [FOR <cond>] [LOCK <n>] [WIDTH <n>] [FREEZE <field>] [NOAPPEND]", "Full-screen table of records for quick editing.  FOR limits visible/navigable records; LOCK keeps the first n columns in place; WIDTH caps column widths; FREEZE edits one field only.  Ctrl-Left/Right pan, Ctrl-U deletes, Ctrl-W saves.");
  H("CANCEL", "CANCEL", "Stops all command files and returns to the dot prompt.");
  H("CHANGE", "CHANGE [<scope>] [FIELDS <list>]", "Same as EDIT.");
  H("CLEAR", "CLEAR [ALL | GETS | MEMORY | TYPEAHEAD]", "Clears the screen; ALL also closes files and releases memory variables.");
  H("CLOSE", "CLOSE ALL | DATABASES | INDEX | ALTERNATE | PROCEDURE | FORMAT", "Closes the named kind of file.");
  H("CONTINUE", "CONTINUE", "Finds the next record matching the last LOCATE condition.");
  H("COPY", "COPY TO <file> [<scope>] [FIELDS <list>] [FOR/WHILE] [SDF | DELIMITED [WITH <c>|BLANK]] / COPY STRUCTURE [EXTENDED] TO <file> / COPY FILE <a> TO <b>", "Copies records, the structure only, or any file.");
  H("COUNT", "COUNT [<scope>] [FOR <cond>] [WHILE <cond>] [TO <memvar>]", "Counts the records that match.");
  H("CREATE", "CREATE <file> [FROM <struct file>] / CREATE REPORT | LABEL | QUERY <file> / CREATE VIEW <file> FROM ENVIRONMENT", "Defines a new database file structure, report form, label form, query or view.");
  H("DELETE", "DELETE [<scope>] [FOR <cond>] [WHILE <cond>]  /  DELETE FILE <file>", "Marks records for deletion (PACK removes them), or erases a file.");
  H("DIR", "DIR [<drive>] [<skeleton>]", "Lists database files with record counts, or files matching a skeleton such as *.NDX.");
  H("DISPLAY", "DISPLAY [<scope>] [<exp list>] [FOR <cond>] [WHILE <cond>] [OFF] [TO PRINT]", "Shows records (default: the current record), pausing each screen.  Also DISPLAY STRUCTURE, STATUS, MEMORY, HISTORY.");
  H("DO", "DO <file | procedure> [WITH <parameter list>]", "Runs a command file (.PRG) or procedure.  Memory variables passed by name are passed by reference.");
  H("DO CASE", "DO CASE / CASE <cond> / ... / [OTHERWISE] / ENDCASE", "Executes the commands after the first true CASE.");
  H("DO WHILE", "DO WHILE <cond> / ... [LOOP] [EXIT] ... / ENDDO", "Repeats the enclosed commands while the condition is true.");
  H("EDIT", "EDIT [<rec no>] [<scope>] [FIELDS <list>] [FOR <cond>] [WHILE <cond>]", "Full-screen editing of records; with a scope, FOR or WHILE only those records are shown.  PgUp/PgDn move between records, Ctrl-W saves, Esc abandons.");
  H("EJECT", "EJECT", "Sends a form feed to the printer.");
  H("ERASE", "ERASE <file>", "Deletes a file.");
  H("FIND", "FIND <literal>", "Searches the master index for a key (no quotes needed).");
  H("GO", "GO[TO] TOP | BOTTOM | [RECORD] <n>   or just <n>", "Moves the record pointer.");
  H("HELP", "HELP [<command or function>]", "Shows help.  Without a topic, shows the topic list.");
  H("IF", "IF <cond> / ... / [ELSE] / ... / ENDIF", "Conditional execution in command files.");
  H("INDEX", "INDEX ON <key exp> TO <file> [UNIQUE]", "Builds a .NDX index and makes it the master index.");
  H("INPUT", "INPUT [<prompt>] TO <memvar>", "Waits for an expression, evaluates it and stores the result.");
  H("INSERT", "INSERT [BLANK] [BEFORE]", "Adds a record after (or before) the current one.");
  H("JOIN", "JOIN WITH <alias> TO <file> FOR <cond> [FIELDS <list>]", "Creates a file combining records of two databases.");
  H("LABEL", "LABEL FORM <file> [<scope>] [FOR/WHILE] [SAMPLE] [TO PRINT | TO FILE <file>]", "Prints mailing labels using a label form.");
  H("LIST", "LIST [<scope>] [<exp list>] [FOR <cond>] [WHILE <cond>] [OFF] [TO PRINT]", "Lists records (default: all).  Also LIST STRUCTURE, STATUS, MEMORY, HISTORY, FILES [LIKE <skel>].");
  H("LOCATE", "LOCATE [<scope>] FOR <cond> [WHILE <cond>]", "Finds the first record matching a condition; CONTINUE finds the next.");
  H("LOOP", "LOOP", "Jumps back to the DO WHILE of the enclosing loop.");
  H("MODIFY", "MODIFY STRUCTURE | COMMAND <file> | FILE <file> | REPORT <file> | LABEL <file> | QUERY <file> | VIEW <file>", "Changes a structure, edits a text or command file, or redesigns a form.");
  H("NOTE", "NOTE <text>   or   * <text>   or   && <text>", "Comments in command files.");
  H("PACK", "PACK", "Removes records marked for deletion and rebuilds open indexes.");
  H("PARAMETERS", "PARAMETERS <memvar list>", "Receives the values passed by DO ... WITH.");
  H("PRIVATE", "PRIVATE <memvar list> | ALL [LIKE | EXCEPT <skeleton>]", "Hides variables of the same name from calling programs.");
  H("ON", "ON ERROR | ESCAPE | KEY [<command>]", "Runs a command (usually DO <procedure>) when an error occurs, Esc is pressed, or any key is pressed in a program.  With no command the trap is turned off.  ON KEY leaves the key for INKEY().");
  H("RETRY", "RETRY", "Returns from a procedure and runs the calling line again; in an ON ERROR procedure, repeats the line that failed.");
  H("PROCEDURE", "PROCEDURE <name>", "Starts a procedure in a procedure file (SET PROCEDURE TO) or command file.");
  H("PUBLIC", "PUBLIC <memvar list>", "Makes variables global so they survive RETURN.");
  H("QUIT", "QUIT", "Closes all files and leaves obbase.");
  H("READ", "READ", "Edits the fields placed by @ ... GET.");
  H("RECALL", "RECALL [<scope>] [FOR <cond>] [WHILE <cond>]", "Removes deletion marks.");
  H("REINDEX", "REINDEX", "Rebuilds all open index files.");
  H("RELEASE", "RELEASE <memvar list> | ALL [LIKE | EXCEPT <skeleton>]", "Deletes memory variables.");
  H("RENAME", "RENAME <old file> TO <new file>", "Renames a file.");
  H("REPLACE", "REPLACE [<scope>] <field> WITH <exp> [, <field> WITH <exp> ...] [FOR/WHILE]", "Changes field contents (default: current record only).");
  H("REPORT", "REPORT FORM <file> [<scope>] [FOR/WHILE] [PLAIN] [HEADING <c>] [NOEJECT] [SUMMARY] [TO PRINT | TO FILE <f>]", "Prints a columnar report with totals using a report form.");
  H("RESTORE", "RESTORE FROM <file> [ADDITIVE]", "Loads memory variables saved with SAVE.");
  H("RESUME", "RESUME", "Continues a suspended command file.");
  H("RETURN", "RETURN [TO MASTER]", "Ends a command file or procedure.");
  H("RUN", "RUN <command>   or   ! <command>", "Runs an operating system command.");
  H("SAVE", "SAVE TO <file> [ALL LIKE | EXCEPT <skeleton>]", "Writes memory variables to a .MEM file.");
  H("SEEK", "SEEK <expression>", "Searches the master index for the value of an expression.");
  H("SELECT", "SELECT <work area 1-10 | A-J | alias>", "Chooses the current work area.");
  H("SET", "SET <option> ON | OFF  /  SET <option> TO <value>", "Options: ALTERNATE BELL CARRY CENTURY COLOR CONFIRM CONSOLE DATE DECIMALS DEFAULT DELETED DELIMITERS DEVICE ESCAPE EXACT FIELDS FILTER FIXED FUNCTION HEADINGS HELP HISTORY INDEX INTENSITY MARGIN MEMOWIDTH MENU MESSAGE ORDER PATH PRINT PROCEDURE RELATION SAFETY STATUS TALK UNIQUE VIEW");
  H("SET FILTER", "SET FILTER TO [<cond> | FILE <query file>]", "Hides records that do not match.");
  H("SET RELATION", "SET RELATION TO <key exp> INTO <alias>", "Links the current file to another; moving here repositions the other via its index (or record number).");
  H("SKIP", "SKIP [<n>]", "Moves the record pointer forward or (negative) back.");
  H("SORT", "SORT ON <field> [/A] [/C] [/D] [, ...] TO <file> [<scope>] [FOR/WHILE]", "Writes a physically sorted copy of the database.");
  H("STORE", "STORE <exp> TO <memvar list>   or   <memvar> = <exp>", "Assigns values to memory variables.");
  H("SUM", "SUM [<exp list>] [<scope>] [FOR <cond>] [WHILE <cond>] [TO <memvar list>]", "Totals numeric expressions.");
  H("SUSPEND", "SUSPEND", "Pauses a command file and goes to the dot prompt; RESUME continues.");
  H("TEXT", "TEXT / <lines> / ENDTEXT", "Outputs lines of text exactly as written.");
  H("TOTAL", "TOTAL ON <key> TO <file> [FIELDS <numeric list>] [<scope>] [FOR/WHILE]", "Summarises a sorted or indexed file into a file of totals.");
  H("TYPE", "TYPE <file> [TO PRINT]", "Displays a text file.");
  H("UPDATE", "UPDATE ON <key field> FROM <alias> REPLACE <field> WITH <exp> [, ...] [RANDOM]", "Updates the current file from a transaction file with matching keys.");
  H("USE", "USE [<file>] [INDEX <ndx list>] [ALIAS <name>]", "Opens a database file in the current work area (USE alone closes it).  USE ? shows a file list.");
  H("WAIT", "WAIT [<prompt>] [TO <memvar>]", "Pauses for one key.");
  H("ZAP", "ZAP", "Removes all records from the current file.");
  H("FUNCTIONS", "ABS ASC AT BOF CDOW CHR CMONTH COL CTOD DATE DAY DBF DELETED DISKSPACE DOW DTOC EOF ERROR EXP FIELD FILE FKLABEL FKMAX FOUND GETENV IIF INKEY INT ISALPHA ISCOLOR ISLOWER ISUPPER", "LEFT LEN LOG LOWER LTRIM LUPDATE MAX MESSAGE MIN MOD MONTH NDX OS PCOL PROW READKEY RECCOUNT RECNO RECSIZE REPLICATE RIGHT ROUND ROW RTRIM SPACE SQRT STR STUFF SUBSTR TIME TRANSFORM TRIM TYPE UPPER VAL VERSION YEAR");
  H("OPERATORS", "+ - * / ** ^  = <> # < > <= >= $  .AND. .OR. .NOT.  ( )", "Arithmetic, string (+ concatenates, - moves trailing blanks), relational ($ = is contained in) and logical operators.  Dates: date + n, date - date.");
  H("AT()", "AT(<c1>, <c2>)", "Position of c1 inside c2, 0 if absent.");
  H("CTOD()", "CTOD(<c>)", "Character to date, in the SET DATE format.");
  H("DATE()", "DATE()", "Today's date.");
  H("DTOC()", "DTOC(<d>)", "Date to character.");
  H("EOF()", "EOF()  /  BOF()", "True when the pointer is past the last / before the first record.");
  H("FOUND()", "FOUND()", "True if the last SEEK, FIND, LOCATE or CONTINUE succeeded.");
  H("IIF()", "IIF(<cond>, <exp1>, <exp2>)", "exp1 if the condition is true, else exp2.");
  H("RECNO()", "RECNO()  /  RECCOUNT()", "The current record number / number of records.");
  H("STR()", "STR(<n> [, <length> [, <decimals>]])", "Number to character, right justified (default length 10).");
  H("SUBSTR()", "SUBSTR(<c>, <start> [, <length>])", "Part of a character string.");
  H("TRANSFORM()", "TRANSFORM(<exp>, <picture>)", "Formats a value with a PICTURE: 9 # , . ! X and functions @! @( @B @Z @C @X.");
  H("TRIM()", "TRIM(<c>)  /  LTRIM(<c>)  /  RTRIM(<c>)", "Removes trailing (or leading) blanks.");
  H("TYPE()", "TYPE(<c>)", "Type of the expression held in c: C N L D M or U.");
  H("UPPER()", "UPPER(<c>)  /  LOWER(<c>)", "Case conversion.");
  H("VAL()", "VAL(<c>)", "Character to number.");
  H("KEYS", "F1 help  F2 assist  F3 list  F4 dir  F5 display structure  F6 display status  F7 display memory  F8 display  F9 append  F10 edit", "Function keys at the dot prompt (change with SET FUNCTION).  Up/Down recall earlier commands; PgUp shows scrolled-off output.")
END InitHelp;

PROCEDURE FindHelp(topic: ARRAY OF CHAR): INTEGER;
VAR i: INTEGER; t: Str;
BEGIN
  Cpy(topic, t); Trim(t); Upper(t);
  IF t[0] = 0X THEN RETURN -1 END;
  FOR i := 0 TO nHelp - 1 DO IF Eq(hName[i], t) THEN RETURN i END END;
  FOR i := 0 TO nHelp - 1 DO IF Kw(t, hName[i]) THEN RETURN i END END;
  Append("()", t);
  FOR i := 0 TO nHelp - 1 DO IF Eq(hName[i], t) THEN RETURN i END END;
  FOR i := 0 TO nHelp - 1 DO IF StartsI(hName[i], topic) THEN RETURN i END END;
  RETURN -1
END FindHelp;

PROCEDURE WrapText(s: ARRAY OF CHAR; w: INTEGER; VAR tb: TextBuf);
VAR seg: Str; i: INTEGER;
BEGIN
  WrapCol(s, w, tb);
  FOR i := 0 TO tb.n - 1 DO Cpy(tb.l[i], seg); Cpy(seg, tb.l[i]) END
END WrapText;

PROCEDURE HelpScreen(VAR i: INTEGER): BOOLEAN; (* FALSE = leave help *)
VAR tb: TextBuf; y, j, w: INTEGER; k: CHAR;
BEGIN
  NEW(tb);
  LOOP
    FSClear;
    w := MinI(TUI.Cols - 4, 76);
    TUI.DrawBox(2, 2, w + 2, TUI.Rows - 6, cFg, cBg);
    PutHi(5, 3, hName[i]);
    y := 5;
    PutHi(5, y, "Syntax:"); INC(y);
    WrapText(hSyn[i], w - 6, tb);
    FOR j := 0 TO tb.n - 1 DO PutS(7, y, tb.l[j], FALSE); INC(y) END;
    INC(y);
    PutHi(5, y, "Description:"); INC(y);
    WrapText(hDesc[i], w - 6, tb);
    FOR j := 0 TO tb.n - 1 DO PutS(7, y, tb.l[j], FALSE); INC(y) END;
    Cpy("Previous screen - PgUp.  Next screen - PgDn.  Help menu - F10.  Exit with Esc.", fsNav);
    fsMsg[0] := 0X;
    FSBars("HELP");
    fsNav[0] := 0X;
    FSFlush(1, 1, FALSE);
    k := GetKey();
    IF (k = TUI.KPgDn) & (i < nHelp - 1) THEN INC(i)
    ELSIF (k = TUI.KPgUp) & (i > 0) THEN DEC(i)
    ELSIF (k = TUI.KF10) OR (k = TUI.KF1) THEN RETURN TRUE
    ELSIF (k = TUI.KEsc) OR (k = TUI.KEnter) THEN RETURN FALSE
    END
  END
END HelpScreen;

PROCEDURE ShowHelp(topic: ARRAY OF CHAR);
VAR i, sel, top, h, y: INTEGER; k: CHAR; t: Str; again: BOOLEAN;
BEGIN
  IF nHelp = 0 THEN InitHelp END;
  i := FindHelp(topic);
  IF batch THEN
    IF i < 0 THEN
      FOR i := 0 TO nHelp - 1 DO Out.String(hName[i]); Out.String("  ") END; Out.Ln
    ELSE
      Out.String(hName[i]); Out.Ln; Out.String(hSyn[i]); Out.Ln; Out.String(hDesc[i]); Out.Ln
    END;
    RETURN
  END;
  again := TRUE;
  IF i >= 0 THEN again := HelpScreen(i) END;
  sel := MaxI(i, 0); top := 0;
  WHILE again DO
    FSClear;
    PutHi(3, 1, "obbase HELP -- choose a topic");
    h := TUI.Rows - 6;
    IF sel < top THEN top := sel END;
    IF sel >= top + h THEN top := sel - h + 1 END;
    FOR y := 0 TO h - 1 DO
      IF top + y < nHelp THEN
        Cpy(hName[top + y], t); PadR(t, 14);
        PutS(3, 3 + y, t, top + y = sel);
        Cpy(hSyn[top + y], t); t[MaxI(TUI.Cols - 20, 10)] := 0X;
        PutS(19, 3 + y, t, FALSE)
      END
    END;
    Cpy("Position selection bar - Up/Down.  Select - Enter.  Exit - Esc.", fsNav);
    FSBars("HELP");
    fsNav[0] := 0X;
    FSFlush(1, 1, FALSE);
    k := GetKey();
    IF (k = TUI.KUp) OR (k = KCtrlE) THEN IF sel > 0 THEN DEC(sel) END
    ELSIF (k = TUI.KDown) OR (k = KCtrlX) THEN IF sel < nHelp - 1 THEN INC(sel) END
    ELSIF k = TUI.KPgUp THEN sel := MaxI(0, sel - h)
    ELSIF k = TUI.KPgDn THEN sel := MinI(nHelp - 1, sel + h)
    ELSIF k = TUI.KEnter THEN again := HelpScreen(sel)
    ELSIF k = TUI.KEsc THEN again := FALSE
    ELSIF IsAlpha(k) THEN
      FOR i := nHelp - 1 TO 0 BY -1 DO IF UpCh(hName[i][0]) = UpCh(k) THEN sel := i END END
    END
  END;
  ConClear;
  TUI.InvalidateFront
END ShowHelp;

(* ====================================================================
   ASSIST -- the menu-driven Assistant
   ==================================================================== *)

CONST nAMenus = 8;

VAR
  amTitle: ARRAY nAMenus OF Name;
  amItem: ARRAY nAMenus, 10 OF Str;
  amDesc: ARRAY nAMenus, 10 OF Str;
  amN: ARRAY nAMenus OF INTEGER;
  asCmd: Str;          (* command being built on the action line *)
  asPullMenu, asPullItem: INTEGER;  (* pulldown kept on screen under popups; -1 none *)
  asInfo: BOOLEAN;     (* AsPop is listing field names: show the field box *)

PROCEDURE AI(m: INTEGER; item, desc: ARRAY OF CHAR);
BEGIN
  Cpy(item, amItem[m][amN[m]]); Cpy(desc, amDesc[m][amN[m]]); INC(amN[m])
END AI;

PROCEDURE InitAssist;
VAR m: INTEGER;
BEGIN
  FOR m := 0 TO nAMenus - 1 DO amN[m] := 0 END;
  Cpy("Set Up", amTitle[0]); Cpy("Create", amTitle[1]); Cpy("Update", amTitle[2]);
  Cpy("Position", amTitle[3]); Cpy("Retrieve", amTitle[4]); Cpy("Organize", amTitle[5]);
  Cpy("Modify", amTitle[6]); Cpy("Tools", amTitle[7]);
  AI(0, "Database file", "Select a database file and, optionally, its index files.");
  AI(0, "Format for Screen", "Custom screen formats are not available in obbase.");
  AI(0, "Query", "Apply the filter saved in a query file.");
  AI(0, "Catalog", "Catalogs are not available in obbase.");
  AI(0, "View", "Restore a saved view (files, indexes, relations).");
  AI(0, "Quit dBASE III PLUS", "Close all files and leave obbase.");
  AI(1, "Database file", "Define the structure of a new database file.");
  AI(1, "Format", "Custom screen formats are not available in obbase.");
  AI(1, "View", "Save the current files, indexes and relations as a view.");
  AI(1, "Query", "Build a filter condition and save it in a query file.");
  AI(1, "Report", "Design a columnar report form.");
  AI(1, "Label", "Design a mailing label form.");
  AI(2, "Append", "Add records at the end of the database file.");
  AI(2, "Edit", "Change the contents of records, one screen per record.");
  AI(2, "Display", "Display the current record or a selected group of records.");
  AI(2, "Browse", "Edit several records at a time in a table.");
  AI(2, "Replace", "Replace the contents of fields with the value of an expression.");
  AI(2, "Delete", "Mark records for deletion.");
  AI(2, "Recall", "Remove deletion marks from records.");
  AI(2, "Pack", "Physically remove records marked for deletion.");
  AI(3, "Seek", "Find the first record whose index key matches an expression.");
  AI(3, "Locate", "Find the first record that matches a search condition.");
  AI(3, "Continue", "Find the next record that matches the LOCATE condition.");
  AI(3, "Skip", "Move the record pointer forward or backward.");
  AI(3, "Goto Record", "Position the record pointer at the top, bottom or a record number.");
  AI(4, "List", "List the contents of the database file.");
  AI(4, "Display", "Display records, pausing at each screen.");
  AI(4, "Report", "Print a report using a report form.");
  AI(4, "Label", "Print labels using a label form.");
  AI(4, "Sum", "Total numeric fields.");
  AI(4, "Average", "Average numeric fields.");
  AI(4, "Count", "Count the records that match a condition.");
  AI(5, "Index", "Create an index file to order the database logically.");
  AI(5, "Sort", "Create a physically sorted copy of the database file.");
  AI(5, "Copy", "Copy records of the database file to a new file.");
  AI(6, "Database file", "Change the structure of the database file in use.");
  AI(6, "Format", "Custom screen formats are not available in obbase.");
  AI(6, "View", "Edit a saved view file.");
  AI(6, "Query", "Change a query file.");
  AI(6, "Report", "Change a report form.");
  AI(6, "Label", "Change a label form.");
  AI(7, "Set drive", "Set the default drive.");
  AI(7, "Copy file", "Duplicate the contents of a file in a new file.");
  AI(7, "Directory", "List the files of a given type.");
  AI(7, "Rename", "Change the name of a file.");
  AI(7, "Erase", "Delete a file.");
  AI(7, "List structure", "Show the structure of the database file in use.");
  AI(7, "Import", "PFS file import is not available in obbase.");
  AI(7, "Export", "PFS file export is not available in obbase.")
END InitAssist;

PROCEDURE AsDrawBar(menu: INTEGER);
VAR x, i: INTEGER; t: Str; now: LONGINT;
BEGIN
  TUI.FillRect(1, 1, TUI.Cols, 1, " ", cRevFg, cRevBg);
  x := 2;
  FOR i := 0 TO nAMenus - 1 DO
    IF i = menu THEN TUI.PutStr(x, 1, amTitle[i], cMenuFg, cMenuBg) ELSE PutS(x, 1, amTitle[i], TRUE) END;
    INC(x, SLen(amTitle[i]) + 2)
  END;
  now := Time.Now(); Time.Format(now, "%I:%M:%S %p", t);
  IF TUI.Cols > x + SLen(t) + 2 THEN PutS(TUI.Cols - SLen(t) - 1, 1, t, TRUE) END
END AsDrawBar;

PROCEDURE AsMenuX(menu: INTEGER): INTEGER;
VAR x, i: INTEGER;
BEGIN
  x := 2;
  FOR i := 0 TO menu - 1 DO INC(x, SLen(amTitle[i]) + 2) END;
  RETURN x
END AsMenuX;

(* can this item be chosen now?  As in dBASE, items that need an open
   database (or an index, for Seek) are dimmed and skipped. *)
PROCEDURE AsAvail(menu, item: INTEGER): BOOLEAN;
VAR needDb: BOOLEAN;
BEGIN
  CASE menu OF
    0: needDb := item = 2                          (* Query *)
  | 1: needDb := (item >= 3)                       (* Query, Report, Label *)
  | 2, 3, 4, 5: needDb := TRUE
  | 6: needDb := (item = 0) OR (item >= 3)         (* Database file, Query, Report, Label *)
  | 7: needDb := item = 5                          (* List structure *)
  ELSE needDb := FALSE
  END;
  IF needDb & ~areas[cur].used THEN RETURN FALSE END;
  IF (menu = 3) & (item = 0) & (areas[cur].order = 0) THEN RETURN FALSE END;
  RETURN TRUE
END AsAvail;

(* next available item from item in direction dir (item itself if none) *)
PROCEDURE AsNextItem(menu, item, dir: INTEGER): INTEGER;
VAR i, k: INTEGER;
BEGIN
  k := item;
  FOR i := 1 TO amN[menu] DO
    k := (k + dir + amN[menu]) MOD amN[menu];
    IF AsAvail(menu, k) THEN RETURN k END
  END;
  RETURN item
END AsNextItem;

PROCEDURE AsPullWidth(menu: INTEGER): INTEGER;
VAR i, w: INTEGER;
BEGIN
  w := 0;
  FOR i := 0 TO amN[menu] - 1 DO w := MaxI(w, SLen(amItem[menu][i])) END;
  RETURN w + 4
END AsPullWidth;

PROCEDURE AsDrawPull(menu, item: INTEGER);
VAR x, w, i: INTEGER; t: Str;
BEGIN
  x := AsMenuX(menu); w := AsPullWidth(menu);
  IF x + w > TUI.Cols THEN x := TUI.Cols - w END;
  Box(x - 1, 2, w, amN[menu] + 2);
  FOR i := 0 TO amN[menu] - 1 DO
    Cpy(" ", t); Append(amItem[menu][i], t); PadR(t, w - 2);
    IF ~AsAvail(menu, i) THEN TUI.PutStr(x, 3 + i, t, TUI.BrightBlack, cBg)
    ELSE PutS(x, 3 + i, t, i = item)
    END
  END
END AsDrawPull;

(* draw the Assistant frame: bar, pulldown, action line, status, nav, message *)
PROCEDURE AsFrame(menu: INTEGER; msg: ARRAY OF CHAR);
VAR t: Str;
BEGIN
  FSClear;
  AsDrawBar(menu);
  IF asPullMenu >= 0 THEN AsDrawPull(asPullMenu, asPullItem) END;
  ScreenSize;
  Cpy("Command: ", t); Append(asCmd, t);
  PutS(1, scrH, t, FALSE);
  Cpy("Position selection bar - Up/Down.  Select - Enter.  Leave menu - Left/Right.", fsNav);
  Cpy(msg, fsMsg);
  FSBars("ASSIST");
  fsNav[0] := 0X; fsMsg[0] := 0X
END AsFrame;

(* box describing a field, beside the field list *)
PROCEDURE AsFieldBox(px, py, pw: INTEGER; name: ARRAY OF CHAR);
VAR f, x, bw: INTEGER; t, u: Str; ty: CHAR;
BEGIN
  f := FieldIdx(cur, name);
  IF f < 0 THEN RETURN END;
  bw := 24; x := px + pw + 1;
  IF x + bw > TUI.Cols THEN x := MaxI(1, px - bw - 1) END;
  Box(x, py, bw, 6);
  ty := areas[cur].db.fields[f].type;
  Cpy("Field name: ", t); Append(areas[cur].db.fields[f].name, t); PutS(x + 1, py + 1, t, FALSE);
  Cpy("Type:       ", t);
  CASE ty OF
    "C": Append("Character", t) | "N", "F": Append("Numeric", t) | "D": Append("Date", t)
  | "L": Append("Logical", t) | "M": Append("Memo", t)
  ELSE AppendCh(ty, t)
  END;
  PutS(x + 1, py + 2, t, FALSE);
  Cpy("Width:      ", t); IntStr(areas[cur].db.fields[f].len, u); Append(u, t); PutS(x + 1, py + 3, t, FALSE);
  Cpy("Decimal:    ", t);
  IF (ty = "N") OR (ty = "F") THEN IntStr(areas[cur].db.fields[f].dec, u); Append(u, t) END;
  PutS(x + 1, py + 4, t, FALSE)
END AsFieldBox;

(* generic popup list; returns index, -1 for Esc/Left, -2 for Right *)
PROCEDURE AsPop(menu, x, y: INTEGER; VAR items: TextBuf; title, msg: ARRAY OF CHAR;
                VAR sel: INTEGER; marks: TextBuf): INTEGER;
VAR i, w, h, top: INTEGER; k: CHAR; t: Str;
BEGIN
  IF items.n = 0 THEN RETURN -1 END;
  w := SLen(title) + 4;
  FOR i := 0 TO items.n - 1 DO w := MaxI(w, SLen(items.l[i]) + 5) END;
  IF x + w > TUI.Cols THEN x := MaxI(1, TUI.Cols - w) END;
  h := MinI(items.n, scrH - y - 2);
  IF h < 1 THEN h := 1 END;
  top := 0;
  LOOP
    IF sel < 0 THEN sel := 0 END;
    IF sel >= items.n THEN sel := items.n - 1 END;
    IF sel < top THEN top := sel END;
    IF sel >= top + h THEN top := sel - h + 1 END;
    AsFrame(menu, msg);
    Box(x, y, w, h + 2);
    IF title[0] # 0X THEN PutHi(x + 2, y, title) END;
    IF asInfo THEN AsFieldBox(x, y, w, items.l[MaxI(sel, 0)]) END;
    FOR i := 0 TO h - 1 DO
      IF top + i < items.n THEN
        IF (marks # NIL) & (marks.l[top + i][0] = "*") THEN Cpy("> ", t) ELSE Cpy("  ", t) END;
        Append(items.l[top + i], t); PadR(t, w - 3);
        PutS(x + 1, y + 1 + i, t, top + i = sel)
      END
    END;
    FSFlush(1, 1, FALSE);
    k := GetKey();
    IF (k = TUI.KUp) OR (k = KCtrlE) THEN DEC(sel)
    ELSIF (k = TUI.KDown) OR (k = KCtrlX) THEN INC(sel)
    ELSIF k = TUI.KPgUp THEN DEC(sel, h)
    ELSIF k = TUI.KPgDn THEN INC(sel, h)
    ELSIF k = TUI.KEnter THEN RETURN sel
    ELSIF (k = TUI.KEsc) OR (k = TUI.KLeft) THEN RETURN -1
    ELSIF k = TUI.KRight THEN RETURN -2
    END
  END
END AsPop;

(* prompt on the line above the status bar *)
PROCEDURE AsPrompt(menu: INTEGER; prompt: ARRAY OF CHAR; VAR s: ARRAY OF CHAR): BOOLEAN;
VAR fe: FieldEd; k: CHAR; r, x, y: INTEGER;
BEGIN
  x := SLen(prompt) + 2;
  FEInit(fe, s, MinI(60, TUI.Cols - x - 2), TC, "");
  fe.pos := MinI(SLen(s), fe.width - 1);
  LOOP
    AsFrame(menu, "Enter new value. Finish with Enter.  Esc to cancel.");
    y := scrH - 1;
    TUI.FillRect(1, y, TUI.Cols, 1, " ", cFg, cBg);
    PutHi(1, y, prompt);
    FEDraw(fe, x, y, fe.width, TRUE);
    FSFlush(FECursorX(fe, x), y, TRUE);
    k := GetKey();
    IF k = TUI.KEsc THEN RETURN FALSE END;
    IF k = TUI.KEnter THEN Cpy(fe.text, s); Trim(s); RETURN TRUE END;
    r := FEKey(fe, k)
  END
END AsPrompt;

PROCEDURE AsYN(menu: INTEGER; prompt: ARRAY OF CHAR): BOOLEAN;
VAR k: CHAR;
BEGIN
  LOOP
    AsFrame(menu, "");
    PutHi(1, scrH - 1, prompt);
    FSFlush(SLen(prompt) + 2, scrH - 1, TRUE);
    k := UpCh(GetKey());
    IF k = "Y" THEN RETURN TRUE END;
    IF (k = "N") OR (k = TUI.KEnter) OR (k = TUI.KEsc) THEN RETURN FALSE END
  END
END AsYN;

(* list files of a type for picking *)
PROCEDURE AsFiles(ext: ARRAY OF CHAR; VAR tb: TextBuf);
VAR i, n: INTEGER; nm, dir, pat: Str;
BEGIN
  NEW(tb); tb.n := 0;
  IF defDir[0] # 0X THEN Cpy(defDir, dir) ELSE dir[0] := 0X END;
  Cpy("*", pat); Append(ext, pat);
  OS.DirOpen(dir, "");
  n := OS.DirCount();
  FOR i := 0 TO n - 1 DO
    OS.DirName(i, nm);
    IF ~OS.DirIsDir(i) & WildMatch(pat, nm, 0, 0) & (tb.n < MaxTxtLn) THEN
      Upper(nm); Cpy(nm, tb.l[tb.n]); INC(tb.n)
    END
  END
END AsFiles;

(* drive menu shown before file lists and names; d gets e.g. "C:" *)
PROCEDURE AsDrive(menu: INTEGER; VAR d: ARRAY OF CHAR): BOOLEAN;
VAR tb, nomarks: TextBuf; sel, r: INTEGER;
BEGIN
  NEW(tb); tb.n := 4; Cpy("A:", tb.l[0]); Cpy("B:", tb.l[1]); Cpy("C:", tb.l[2]); Cpy("D:", tb.l[3]);
  sel := ORD(defDrive) - ORD("A"); nomarks := NIL;
  IF (sel < 0) OR (sel > 3) THEN sel := 2 END;
  r := AsPop(menu, AsMenuX(menu) + 4, 3, tb, "", "Select a drive.", sel, nomarks);
  IF r < 0 THEN RETURN FALSE END;
  Cpy(tb.l[r], d);
  RETURN TRUE
END AsDrive;

(* drive, then a file name typed in *)
PROCEDURE AsPromptFile(menu: INTEGER; prompt: ARRAY OF CHAR; VAR name: ARRAY OF CHAR): BOOLEAN;
VAR d: Str;
BEGIN
  name[0] := 0X;
  IF ~AsDrive(menu, d) THEN RETURN FALSE END;
  IF ~AsPrompt(menu, prompt, name) OR (name[0] = 0X) THEN RETURN FALSE END;
  StripDrive(name); Strings.Insert(d, 0, name);
  RETURN TRUE
END AsPromptFile;

PROCEDURE AsPickFile(menu: INTEGER; ext: ARRAY OF CHAR; VAR name: ARRAY OF CHAR): BOOLEAN;
VAR tb: TextBuf; sel, r: INTEGER; nomarks: TextBuf; t, d: Str;
BEGIN
  IF ~AsDrive(menu, d) THEN RETURN FALSE END;
  AsFiles(ext, tb);
  IF tb.n = 0 THEN
    Cpy("There are no ", t); Append(ext, t); Append(" files.", t);
    FSMessage(t); RETURN FALSE
  END;
  sel := 0; nomarks := NIL;
  r := AsPop(menu, AsMenuX(menu) + 4, 4, tb, "", "Select a file.", sel, nomarks);
  IF r < 0 THEN RETURN FALSE END;
  Cpy(d, name); Append(tb.l[r], name);
  RETURN TRUE
END AsPickFile;

(* run a command built by the Assistant and show its output *)
PROCEDURE AsRun(cmd: ARRAY OF CHAR; wait: BOOLEAN);
VAR k: CHAR; errs0: INTEGER;
BEGIN
  errs0 := errShown;
  Cpy(cmd, asCmd);
  AddHistory(cmd);
  ConClear;
  inAssist := TRUE;
  Cpy("ASSIST", modeName); SetMsg("");
  RunCommand(cmd);
  IF (wait OR (errShown # errs0)) & ~quitting THEN   (* always let an error be read *)
    ConNL;
    ConPut("Press any key to continue work in ASSIST.");
    DrawConsole;
    REPEAT k := GetKey() UNTIL k # 0X
  END;
  inAssist := FALSE;
  ConClear;
  TUI.InvalidateFront
END AsRun;

(* choose fields; result is a comma list *)
PROCEDURE AsFieldList(menu: INTEGER; numericOnly, multi: BOOLEAN; VAR out: ARRAY OF CHAR): BOOLEAN;
VAR tb, marks: TextBuf; i, sel, r: INTEGER; info: Str;
BEGIN
  out[0] := 0X;
  IF ~areas[cur].used THEN FSMessage("No database is in use."); RETURN FALSE END;
  NEW(tb); NEW(marks); tb.n := 0; marks.n := 0;
  FOR i := 0 TO areas[cur].db.numFields - 1 DO
    IF ~numericOnly OR (areas[cur].db.fields[i].type = "N") THEN
      Cpy(areas[cur].db.fields[i].name, tb.l[tb.n]); marks.l[tb.n][0] := 0X; INC(tb.n)
    END
  END;
  IF tb.n = 0 THEN FSMessage("There are no suitable fields."); RETURN FALSE END;
  sel := 0;
  LOOP
    IF multi THEN Cpy("Enter selects a field; Left/Right arrow when done.", info)
    ELSE Cpy("Select a field.", info) END;
    asInfo := TRUE;
    r := AsPop(menu, AsMenuX(menu) + 4, 4, tb, "Fields", info, sel, marks);
    asInfo := FALSE;
    IF r = -1 THEN IF ~multi THEN RETURN FALSE END; EXIT END;
    IF r = -2 THEN EXIT END;
    IF ~multi THEN Cpy(tb.l[r], out); RETURN TRUE END;
    IF marks.l[r][0] = 0X THEN
      marks.l[r][0] := "*"; marks.l[r][1] := 0X;
      IF out[0] # 0X THEN Append(", ", out) END;
      Append(tb.l[r], out);
      Cpy(asCmd, info); Append(" ", info); Append(out, info)
    END;
    INC(sel)
  END;
  RETURN out[0] # 0X
END AsFieldList;

(* build "FIELD op value [connector ...]" *)
PROCEDURE AsCondition(menu: INTEGER; VAR out: ARRAY OF CHAR): BOOLEAN;
VAR
  fld, val, t: Str; ops, more: TextBuf; sel, r, f: INTEGER; nomarks: TextBuf; ty: CHAR;
BEGIN
  out[0] := 0X; nomarks := NIL;
  NEW(ops); ops.n := 6;
  Cpy("=  Equal To", ops.l[0]); Cpy("<= Less Than or Equal To", ops.l[1]);
  Cpy("<  Less Than", ops.l[2]); Cpy(">  Greater Than", ops.l[3]);
  Cpy(">= Greater Than or Equal To", ops.l[4]); Cpy("<> Not Equal To", ops.l[5]);
  NEW(more); more.n := 3;
  Cpy("No more conditions", more.l[0]); Cpy("Combine with .AND.", more.l[1]); Cpy("Combine with .OR.", more.l[2]);
  LOOP
    IF ~AsFieldList(menu, FALSE, FALSE, fld) THEN RETURN out[0] # 0X END;
    f := FieldIdx(cur, fld); ty := areas[cur].db.fields[f].type;
    IF ty = "L" THEN
      Append(fld, out)
    ELSE
      sel := 0;
      r := AsPop(menu, AsMenuX(menu) + 8, 6, ops, "", "Select a comparison operator.", sel, nomarks);
      IF r < 0 THEN RETURN FALSE END;
      Sub(ops.l[r], 0, 2, t); Trim(t);
      val[0] := 0X;
      IF ty = "N" THEN
        IF ~AsPrompt(menu, "Enter a numeric value:", val) THEN RETURN FALSE END
      ELSIF ty = "D" THEN
        IF ~AsPrompt(menu, "Enter a date (MM/DD/YY):", val) THEN RETURN FALSE END;
        Strings.Insert("CTOD('", 0, val); Append("')", val)
      ELSE
        IF ~AsPrompt(menu, "Enter a character string (without quotes):", val) THEN RETURN FALSE END;
        Strings.Insert("'", 0, val); Append("'", val)
      END;
      Append(fld, out); Append(" ", out); Append(t, out); Append(" ", out); Append(val, out)
    END;
    sel := 0;
    r := AsPop(menu, AsMenuX(menu) + 8, 6, more, "", "Select a logical connector.", sel, nomarks);
    IF r <= 0 THEN RETURN TRUE END;
    IF r = 1 THEN Append(" .AND. ", out) ELSE Append(" .OR. ", out) END
  END
END AsCondition;

(* the Execute/scope/fields/condition submenu shared by many commands *)
PROCEDURE AsOptions(menu: INTEGER; verb: ARRAY OF CHAR; fields, printer, wait: BOOLEAN; tail: ARRAY OF CHAR);
VAR
  items, sc: TextBuf; sel, r: INTEGER; scope, flds, forC, whileC, cmd, t: Str; nomarks: TextBuf;
BEGIN
  scope[0] := 0X; flds[0] := 0X; forC[0] := 0X; whileC[0] := 0X; nomarks := NIL;
  NEW(items); items.n := 0;
  Cpy("Execute the command", items.l[items.n]); INC(items.n);
  Cpy("Specify scope", items.l[items.n]); INC(items.n);
  IF fields THEN Cpy("Construct a field list", items.l[items.n]); INC(items.n) END;
  Cpy("Build a search condition", items.l[items.n]); INC(items.n);
  Cpy("Build a scope condition", items.l[items.n]); INC(items.n);
  NEW(sc); sc.n := 5;
  Cpy("Default scope", sc.l[0]); Cpy("ALL", sc.l[1]); Cpy("NEXT", sc.l[2]);
  Cpy("RECORD", sc.l[3]); Cpy("REST", sc.l[4]);
  sel := 0;
  LOOP
    Cpy(verb, cmd);
    IF scope[0] # 0X THEN Append(" ", cmd); Append(scope, cmd) END;
    IF flds[0] # 0X THEN Append(" ", cmd); Append(flds, cmd) END;
    IF forC[0] # 0X THEN Append(" FOR ", cmd); Append(forC, cmd) END;
    IF whileC[0] # 0X THEN Append(" WHILE ", cmd); Append(whileC, cmd) END;
    Append(tail, cmd);
    Cpy(cmd, asCmd);
    r := AsPop(menu, AsMenuX(menu) + 4, 3, items, "", "Choose an option, then Execute the command.", sel, nomarks);
    IF r < 0 THEN asCmd[0] := 0X; RETURN END;
    Cpy(items.l[r], t);
    IF StartsI(t, "Execute") THEN
      IF printer & AsYN(menu, "Direct the output to the printer? [Y/N]") THEN Append(" TO PRINT", cmd) END;
      AsRun(cmd, wait); RETURN
    ELSIF StartsI(t, "Specify") THEN
      r := 0;
      r := AsPop(menu, AsMenuX(menu) + 8, 5, sc, "", "Select the scope of the command.", r, nomarks);
      IF r = 0 THEN scope[0] := 0X
      ELSIF r = 1 THEN Cpy("ALL", scope)
      ELSIF r = 4 THEN Cpy("REST", scope)
      ELSIF r > 0 THEN
        t[0] := 0X;
        IF AsPrompt(menu, "Enter a numeric value:", t) & (t[0] # 0X) THEN
          Cpy(sc.l[r], scope); Append(" ", scope); Append(t, scope)
        END
      END
    ELSIF StartsI(t, "Construct") THEN
      IF AsFieldList(menu, Eq(verb, "SUM") OR Eq(verb, "AVERAGE"), TRUE, flds) THEN END
    ELSIF StartsI(t, "Build a search") THEN
      IF AsCondition(menu, forC) THEN END
    ELSIF StartsI(t, "Build a scope") THEN
      IF AsCondition(menu, whileC) THEN END
    END;
    sel := 0
  END
END AsOptions;

PROCEDURE AsAction(menu, item: INTEGER);
VAR
  name, t, cmd, idx, x2: Str; tb, nomarks: TextBuf; r, sel: INTEGER; repl: Str;
  fld: Str;
BEGIN
  asCmd[0] := 0X; nomarks := NIL;
  CASE menu OF
    0:
      CASE item OF
        0:
          Cpy("USE", asCmd);
          IF AsPickFile(menu, ".dbf", name) THEN
            Cpy("USE ", cmd); Append(name, cmd); Cpy(cmd, asCmd);
            AsFiles(".ndx", tb);
            IF (tb.n > 0) & AsYN(menu, "Is the file indexed? [Y/N]") THEN
              idx[0] := 0X;
              LOOP
                AsFiles(".ndx", tb);
                IF tb.n = 0 THEN EXIT END;
                sel := 0;
                r := AsPop(menu, AsMenuX(menu) + 20, 4, tb, "Index files",
                           "Enter selects an index file; Left/Right arrow when done.", sel, nomarks);
                IF r < 0 THEN EXIT END;
                IF idx[0] # 0X THEN Append(", ", idx) END;
                Append(tb.l[r], idx);
                Cpy(cmd, asCmd); Append(" INDEX ", asCmd); Append(idx, asCmd)
              END;
              IF idx[0] # 0X THEN Append(" INDEX ", cmd); Append(idx, cmd) END
            END;
            AsRun(cmd, FALSE)
          END
      | 2: IF AsPickFile(menu, ".qry", name) THEN Cpy("SET FILTER TO FILE ", cmd); Append(name, cmd); AsRun(cmd, FALSE) END
      | 4: IF AsPickFile(menu, ".vue", name) THEN Cpy("SET VIEW TO ", cmd); Append(name, cmd); AsRun(cmd, FALSE) END
      | 5: quitting := TRUE
      ELSE FSMessage(amDesc[menu][item])
      END
  | 1, 6:
      IF (item = 1) THEN FSMessage(amDesc[menu][item]); RETURN END;
      IF (menu = 6) & (item = 0) THEN AsRun("MODIFY STRUCTURE", FALSE); RETURN END;
      name[0] := 0X;
      CASE item OF
        0: Cpy("CREATE ", cmd); x2[0] := 0X
      | 2: IF menu = 1 THEN Cpy("CREATE VIEW ", cmd); Cpy(" FROM ENVIRONMENT", x2) ELSE Cpy("MODIFY VIEW ", cmd); x2[0] := 0X END
      | 3: IF menu = 1 THEN Cpy("CREATE QUERY ", cmd) ELSE Cpy("MODIFY QUERY ", cmd) END; x2[0] := 0X
      | 4: IF menu = 1 THEN Cpy("CREATE REPORT ", cmd) ELSE Cpy("MODIFY REPORT ", cmd) END; x2[0] := 0X
      | 5: IF menu = 1 THEN Cpy("CREATE LABEL ", cmd) ELSE Cpy("MODIFY LABEL ", cmd) END; x2[0] := 0X
      END;
      Cpy(cmd, asCmd);
      IF menu = 6 THEN
        (* Modify picks one of the existing files *)
        CASE item OF
          2: Cpy(".vue", t) | 3: Cpy(".qry", t) | 4: Cpy(".frm", t) | 5: Cpy(".lbl", t)
        END;
        IF AsPickFile(menu, t, name) THEN Append(name, cmd); AsRun(cmd, FALSE) END
      ELSIF AsPromptFile(menu, "Enter the name of the file:", name) THEN
        Append(name, cmd); Append(x2, cmd); AsRun(cmd, item = 2)
      END
  | 2:
      CASE item OF
        0: AsRun("APPEND", FALSE)
      | 1: AsRun("EDIT", FALSE)
      | 2: AsOptions(menu, "DISPLAY", TRUE, FALSE, TRUE, "")
      | 3: AsRun("BROWSE", FALSE)
      | 4:
          repl[0] := 0X;
          LOOP
            IF ~AsFieldList(menu, FALSE, FALSE, fld) THEN EXIT END;
            Cpy("REPLACE ", asCmd); Append(repl, asCmd);
            t[0] := 0X;
            IF ~AsPrompt(menu, "Enter an expression:", t) THEN EXIT END;
            IF repl[0] # 0X THEN Append(", ", repl) END;
            Append(fld, repl); Append(" WITH ", repl); Append(t, repl);
            Cpy("REPLACE ", asCmd); Append(repl, asCmd);
            IF ~AsYN(menu, "Replace another field? [Y/N]") THEN EXIT END
          END;
          IF repl[0] # 0X THEN Cpy("REPLACE ", cmd); Append(repl, cmd); AsOptions(menu, cmd, FALSE, FALSE, TRUE, "") END
      | 5: AsOptions(menu, "DELETE", FALSE, FALSE, TRUE, "")
      | 6: AsOptions(menu, "RECALL", FALSE, FALSE, TRUE, "")
      | 7: AsRun("PACK", TRUE)
      END
  | 3:
      CASE item OF
        0:
          Cpy("SEEK ", asCmd); t[0] := 0X;
          IF AsPrompt(menu, "Enter an expression:", t) & (t[0] # 0X) THEN Cpy("SEEK ", cmd); Append(t, cmd); AsRun(cmd, TRUE) END
      | 1: AsOptions(menu, "LOCATE", FALSE, FALSE, TRUE, "")
      | 2: AsRun("CONTINUE", TRUE)
      | 3:
          Cpy("SKIP ", asCmd); t[0] := 0X;
          IF AsPrompt(menu, "Enter a numeric value:", t) THEN Cpy("SKIP ", cmd); Append(t, cmd); AsRun(cmd, TRUE) END
      | 4:
          NEW(tb); tb.n := 3; Cpy("TOP", tb.l[0]); Cpy("BOTTOM", tb.l[1]); Cpy("RECORD", tb.l[2]);
          sel := 0; Cpy("GOTO", asCmd);
          r := AsPop(menu, AsMenuX(menu) + 8, 7, tb, "", "Select the position.", sel, nomarks);
          IF r = 0 THEN AsRun("GOTO TOP", FALSE)
          ELSIF r = 1 THEN AsRun("GOTO BOTTOM", FALSE)
          ELSIF r = 2 THEN
            t[0] := 0X;
            IF AsPrompt(menu, "Enter a numeric value:", t) & (t[0] # 0X) THEN Cpy("GOTO ", cmd); Append(t, cmd); AsRun(cmd, FALSE) END
          END
      END
  | 4:
      CASE item OF
        0: AsOptions(menu, "LIST", TRUE, TRUE, TRUE, "")
      | 1: AsOptions(menu, "DISPLAY", TRUE, TRUE, TRUE, "")
      | 2: IF AsPickFile(menu, ".frm", name) THEN Cpy("REPORT FORM ", cmd); Append(name, cmd); AsOptions(menu, cmd, FALSE, TRUE, TRUE, "") END
      | 3: IF AsPickFile(menu, ".lbl", name) THEN Cpy("LABEL FORM ", cmd); Append(name, cmd); AsOptions(menu, cmd, FALSE, TRUE, TRUE, "") END
      | 4: AsOptions(menu, "SUM", TRUE, FALSE, TRUE, "")
      | 5: AsOptions(menu, "AVERAGE", TRUE, FALSE, TRUE, "")
      | 6: AsOptions(menu, "COUNT", FALSE, FALSE, TRUE, "")
      END
  | 5:
      CASE item OF
        0:
          Cpy("INDEX ON ", asCmd); t[0] := 0X;
          IF AsPrompt(menu, "Enter an index key expression:", t) & (t[0] # 0X) THEN
            Cpy("INDEX ON ", cmd); Append(t, cmd); Append(" TO ", cmd); Cpy(cmd, asCmd);
            IF AsPromptFile(menu, "Enter the name of the file:", name) THEN
              Append(name, cmd); AsRun(cmd, TRUE)
            END
          END
      | 1:
          Cpy("SORT ON ", asCmd);
          IF AsFieldList(menu, FALSE, TRUE, t) THEN
            Cpy("SORT ON ", cmd); Append(t, cmd); Append(" TO ", cmd); Cpy(cmd, asCmd);
            IF AsPromptFile(menu, "Enter the name of the file:", name) THEN
              Append(name, cmd); AsRun(cmd, TRUE)
            END
          END
      | 2:
          Cpy("COPY TO ", asCmd);
          IF AsPromptFile(menu, "Enter the name of the file:", name) THEN
            Cpy("COPY TO ", cmd); Append(name, cmd); AsOptions(menu, cmd, TRUE, FALSE, TRUE, "")
          END
      END
  | 7:
      CASE item OF
        0:
          NEW(tb); tb.n := 4; Cpy("A:", tb.l[0]); Cpy("B:", tb.l[1]); Cpy("C:", tb.l[2]); Cpy("D:", tb.l[3]);
          sel := ORD(defDrive) - ORD("A");
          r := AsPop(menu, AsMenuX(menu) + 4, 3, tb, "", "Select the default drive.", sel, nomarks);
          IF r >= 0 THEN Cpy("SET DEFAULT TO ", cmd); Append(tb.l[r], cmd); AsRun(cmd, FALSE) END
      | 1:
          IF AsPickFile(menu, "", name) THEN
            Cpy("COPY FILE ", cmd); Append(name, cmd); Append(" TO ", cmd); Cpy(cmd, asCmd); t[0] := 0X;
            IF AsPromptFile(menu, "Enter the name of the new file:", t) THEN Append(t, cmd); AsRun(cmd, TRUE) END
          END
      | 2:
          NEW(tb); tb.n := 9;
          Cpy(".dbf Database Files", tb.l[0]); Cpy(".ndx Index Files", tb.l[1]); Cpy(".frm Report Forms", tb.l[2]);
          Cpy(".lbl Label Forms", tb.l[3]); Cpy(".qry Query Files", tb.l[4]); Cpy(".vue View Files", tb.l[5]);
          Cpy(".prg Command Files", tb.l[6]); Cpy(".txt Text Files", tb.l[7]); Cpy("All Files", tb.l[8]);
          sel := 0;
          IF AsDrive(menu, x2) THEN
            r := AsPop(menu, AsMenuX(menu) + 4, 4, tb, "", "Select a file type.", sel, nomarks);
            Cpy("DIR ", cmd); Append(x2, cmd);
            IF r = 0 THEN AsRun(cmd, TRUE)
            ELSIF r = 8 THEN Append("*.*", cmd); AsRun(cmd, TRUE)
            ELSIF r > 0 THEN Append("*", cmd); Sub(tb.l[r], 0, 4, t); Append(t, cmd); AsRun(cmd, TRUE)
            END
          END
      | 3:
          IF AsPickFile(menu, "", name) THEN
            Cpy("RENAME ", cmd); Append(name, cmd); Append(" TO ", cmd); Cpy(cmd, asCmd); t[0] := 0X;
            IF AsPromptFile(menu, "Enter the new name of the file:", t) THEN Append(t, cmd); AsRun(cmd, TRUE) END
          END
      | 4:
          IF AsPickFile(menu, "", name) THEN
            Cpy("ERASE ", cmd); Append(name, cmd); Cpy(cmd, asCmd);
            IF AsYN(menu, "Are you sure? [Y/N]") THEN AsRun(cmd, TRUE) END
          END
      | 5:
          IF AsYN(menu, "Direct the output to the printer? [Y/N]") THEN AsRun("LIST STRUCTURE TO PRINT", TRUE)
          ELSE AsRun("LIST STRUCTURE", TRUE)
          END
      ELSE FSMessage(amDesc[menu][item])
      END
  END;
  asCmd[0] := 0X
END AsAction;

PROCEDURE DoAssist;
VAR menu, item, i: INTEGER; k: CHAR; leave: BOOLEAN;

  PROCEDURE First(m: INTEGER): INTEGER;
  BEGIN
    IF AsAvail(m, 0) THEN RETURN 0 END;
    RETURN AsNextItem(m, 0, 1)
  END First;

BEGIN
  IF batch THEN Err("ASSIST needs the interactive mode."); RETURN END;
  IF amN[0] = 0 THEN InitAssist END;
  menu := 0; item := 0; leave := FALSE; asCmd[0] := 0X; asInfo := FALSE;
  WHILE ~leave & ~quitting DO
    (* an action may have closed the database: keep the bar on a live item *)
    IF ~AsAvail(menu, item) THEN item := First(menu) END;
    asPullMenu := menu; asPullItem := item;
    AsFrame(menu, amDesc[menu][item]);
    FSFlush(1, 1, FALSE);
    k := GetKey();
    IF k = 0X THEN
    ELSIF (k = TUI.KLeft) OR (k = KCtrlS) THEN menu := (menu + nAMenus - 1) MOD nAMenus; item := First(menu)
    ELSIF (k = TUI.KRight) OR (k = KCtrlD) THEN menu := (menu + 1) MOD nAMenus; item := First(menu)
    ELSIF (k = TUI.KUp) OR (k = KCtrlE) THEN item := AsNextItem(menu, item, -1)
    ELSIF (k = TUI.KDown) OR (k = KCtrlX) THEN item := AsNextItem(menu, item, 1)
    ELSIF k = TUI.KEnter THEN
      IF AsAvail(menu, item) THEN AsAction(menu, item) ELSE Bell END
    ELSIF k = TUI.KEsc THEN leave := TRUE
    ELSIF k = TUI.KF1 THEN ShowHelp(amItem[menu][item])
    ELSIF IsAlpha(k) THEN
      FOR i := 0 TO nAMenus - 1 DO IF UpCh(amTitle[i][0]) = UpCh(k) THEN menu := i; item := First(i) END END
    END
  END;
  asPullMenu := -1;
  ConClear;
  TUI.InvalidateFront
END DoAssist;

(* ====================================================================
   Start-up
   ==================================================================== *)

PROCEDURE InitSettings;
VAR i: INTEGER;
BEGIN
  setTalk := TRUE; setHeadings := TRUE; setDeleted := FALSE; setExact := FALSE;
  setSafety := TRUE; setConfirm := FALSE; setBell := TRUE; setStatus := TRUE;
  setMenu := TRUE; setPrint := FALSE; setAlternate := FALSE; setConsole := TRUE;
  setCentury := FALSE; setUnique := FALSE; setCarry := FALSE; setIntensity := TRUE;
  setHelp := TRUE; setEscape := TRUE; setFieldsOn := FALSE; setDevPrint := FALSE;
  setDelimiters := FALSE; setEcho := FALSE; setFixed := FALSE;
  SetColors(""); userMsg[0] := 0X; taN := 0; onKeyN := 0;
  onErrCmd[0] := 0X; onEscCmd[0] := 0X; onKeyCmd[0] := 0X;
  inOnErr := FALSE; inOnEsc := FALSE; inOnKey := FALSE; retryFlag := FALSE;
  lastErrCode := 0; lastErrMsg[0] := 0X; errCode := 0; batchMid := FALSE;
  editArea := -1; editFor := NIL; editWhile := NIL; editLeft := -1;
  asPullMenu := -1; asPullItem := 0; asInfo := FALSE; errShown := 0;
  delimL := ":"; delimR := ":";
  setDecimals := 2; setMargin := 0; setMemoWidth := 50; setHistory := MaxCmdHist;
  setDateFmt := 0;
  defDrive := "C"; defDir[0] := 0X; pathDirs[0] := 0X;
  Cpy("obbase.prn", prnName);
  Cpy("help;", fkeys[0]); Cpy("assist;", fkeys[1]); Cpy("list;", fkeys[2]);
  Cpy("dir;", fkeys[3]); Cpy("display structure;", fkeys[4]);
  Cpy("display status;", fkeys[5]); Cpy("display memory;", fkeys[6]);
  Cpy("display;", fkeys[7]); Cpy("append;", fkeys[8]); Cpy("edit;", fkeys[9]);
  FOR i := 0 TO MaxAreas - 1 DO
    areas[i].used := FALSE; areas[i].relArea := -1; areas[i].nIdx := 0
  END;
  cur := 0; nVars := 0; depth := 0; nProgs := 0; nProcs := 0; procFile := NIL;
  nCmdHist := 0; histN := 0; histTop := 0; nGets := 0; nFieldList := 0;
  insMode := FALSE;
  Cpy("Command Line", modeName);
  msgLine[0] := 0X; navLine[0] := 0X
END InitSettings;

PROCEDURE Main;
VAR arg, prog: Str; i: INTEGER;
BEGIN
  InitSettings;
  InitFuncs;
  batch := FALSE; prog[0] := 0X;
  FOR i := 1 TO Args.Count() DO
    Args.Get(i, arg);
    IF Eq(arg, "-b") THEN batch := TRUE
    ELSE Cpy(arg, prog)
    END
  END;
  ConClear;
  IF batch THEN
    ScreenSize;
    IF prog[0] # 0X THEN
      Cpy("DO ", arg); Append(prog, arg);
      RunCommand(arg)
    END;
    CloseAll;
    RETURN
  END;
  TUI.Init;
  ScreenSize;
  IF prog[0] # 0X THEN
    Cpy("DO ", arg); Append(prog, arg);
    RunCommand(arg)
  ELSE
    DoAssist
  END;
  IF ~quitting THEN DotPrompt END;
  CloseAll;
  TUI.Done;
  Out.String("*** END RUN obbase"); Out.Ln
END Main;

BEGIN
  Main
END obbase.


