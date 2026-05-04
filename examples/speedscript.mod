MODULE SpeedScript;

IMPORT Terminal, Files, Out, Strings, Args;

CONST
  MaxText = 65536*3;
  BufSize = 4096;
  MaxName = 256;
  RetChar  = 1FX;   (* hard paragraph break, displayed as < *)
  MaxUndo  = 32;
  UndoIns  = 0;
  UndoDel  = 1;

  HLANG_NONE = 0; HLANG_C = 1; HLANG_CPP = 2; HLANG_OBN = 3;
  HNormal  = 0; HKeyword = 1; HString  = 2;
  HComment = 3; HNumber  = 4; HPrepro  = 5;

  (* Integer key codes *)
  KEY_UP    = 0A0X;   KEY_DOWN  = 0A1X;
  KEY_LEFT  = 0A2X;   KEY_RIGHT = 0A3X;
  KEY_MOUSE = 0A4X;
  KEY_BS    = 07FX;   KEY_TAB   = 09X;
  KEY_ENTER = 0DX;  KEY_ESC   = 1BX;
  KEY_CTRL_F = 6;   (* Find *)
  KEY_CTRL_G = 7;   (* Find-and-replace *)
  KEY_CTRL_K = 11;  (* Kill to end of line *)
  KEY_CTRL_L = 12;  (* Load file *)
  KEY_CTRL_N = 14;  (* New document *)
  KEY_CTRL_R = 18;  (* Restore / paste buffer *)
  KEY_CTRL_S = 19;  (* Save *)
  KEY_CTRL_T = 20;  (* Transpose *)
  KEY_CTRL_W = 23;  (* Delete word backward *)
  KEY_CTRL_X = 24;  (* Toggle case *)
  KEY_CTRL_Z = 26;  (* Undo *)
  KEY_PGUP   = 80X; KEY_PGDN   = 81X;
  KEY_HOME   = 82X; KEY_END    = 83X;
  KEY_DEL    = 84X;
  KEY_WLEFT  = 085X; KEY_WRIGHT = 086X;
  KEY_FHOME  = 087X; KEY_FEND   = 088X;
  KEY_F1     = 089X; KEY_F2     = 08AX;
  KEY_F3     = 08BX; KEY_F4     = 08CX;
  KEY_F5     = 08DX; KEY_F6     = 08EX;
  KEY_F7     = 08FX; KEY_F8     = 090X;
  KEY_F9     = 091X; KEY_F10    = 092X;
  KEY_F11    = 093X; KEY_F12    = 094X;

TYPE
  UndoRec = RECORD
    kind: INTEGER;
    pos:  INTEGER;
    len:  INTEGER;
    data: ARRAY BufSize OF CHAR
  END;

VAR
  text:    ARRAY MaxText OF CHAR;
  cutBuf:  ARRAY BufSize OF CHAR;
  cutLen:  INTEGER;

  undoBuf:  ARRAY MaxUndo OF UndoRec;
  undoHead: INTEGER;
  undoCnt:  INTEGER;

  lang:    INTEGER;
  hlColor: ARRAY MaxText OF INTEGER;
  hlLast:  INTEGER;

  fname:     ARRAY MaxName OF CHAR;
  searchStr: ARRAY 128 OF CHAR;
  replStr:   ARRAY 128 OF CHAR;

  curr, lastLine, topLin: INTEGER;
  cx, cy: INTEGER;            (* visual pos of cursor, set by Refresh *)
  insMode, modified, running: BOOLEAN;

(* ── Buffer helpers ─────────────────────────────────────────────────── *)

PROCEDURE MoveText(src, dest, len: INTEGER);
VAR i: INTEGER;
BEGIN
  IF src > dest THEN
    FOR i := 0 TO len - 1 DO text[dest + i] := text[src + i] END
  ELSIF src < dest THEN
    FOR i := len - 1 TO 0 BY -1 DO text[dest + i] := text[src + i] END
  END
END MoveText;

PROCEDURE IsWord(ch: CHAR): BOOLEAN;
BEGIN
  RETURN (ch # " ") & (ch # RetChar) & (ORD(ch) >= 33) & (ORD(ch) < 127)
END IsWord;

(* ── Undo ───────────────────────────────────────────────────────────── *)

(* Record that len chars were inserted starting at pos.
   Consecutive single-char inserts are coalesced into one record. *)
PROCEDURE RecordIns(pos, len: INTEGER);
VAR tail: INTEGER;
BEGIN
  IF undoCnt > 0 THEN
    tail := (undoHead + undoCnt - 1) MOD MaxUndo;
    IF (undoBuf[tail].kind = UndoIns) &
       (undoBuf[tail].pos + undoBuf[tail].len = pos) THEN
      INC(undoBuf[tail].len); RETURN
    END
  END;
  tail := (undoHead + undoCnt) MOD MaxUndo;
  undoBuf[tail].kind := UndoIns;
  undoBuf[tail].pos  := pos;
  undoBuf[tail].len  := len;
  IF undoCnt < MaxUndo THEN INC(undoCnt)
  ELSE undoHead := (undoHead + 1) MOD MaxUndo
  END
END RecordIns;

(* Record that len chars starting at src[off] were deleted from pos. *)
PROCEDURE RecordDel(pos, len: INTEGER; VAR src: ARRAY OF CHAR; off: INTEGER);
VAR tail, i: INTEGER;
BEGIN
  IF len > BufSize THEN len := BufSize END;
  tail := (undoHead + undoCnt) MOD MaxUndo;
  undoBuf[tail].kind := UndoDel;
  undoBuf[tail].pos  := pos;
  undoBuf[tail].len  := len;
  FOR i := 0 TO len - 1 DO undoBuf[tail].data[i] := src[off + i] END;
  IF undoCnt < MaxUndo THEN INC(undoCnt)
  ELSE undoHead := (undoHead + 1) MOD MaxUndo
  END
END RecordDel;

PROCEDURE DoUndo;
VAR tail, i: INTEGER;
BEGIN
  IF undoCnt = 0 THEN Prompt("Nothing to undo."); RETURN END;
  DEC(undoCnt);
  tail := (undoHead + undoCnt) MOD MaxUndo;
  curr := undoBuf[tail].pos;
  IF undoBuf[tail].kind = UndoIns THEN
    MoveText(curr + undoBuf[tail].len, curr, lastLine - (curr + undoBuf[tail].len));
    DEC(lastLine, undoBuf[tail].len)
  ELSE
    MoveText(curr, curr + undoBuf[tail].len, lastLine - curr);
    FOR i := 0 TO undoBuf[tail].len - 1 DO text[curr + i] := undoBuf[tail].data[i] END;
    INC(lastLine, undoBuf[tail].len);
    INC(curr, undoBuf[tail].len)
  END;
  modified := TRUE
END DoUndo;

(* ── Visual line helpers ─────────────────────────────────────────────── *)

(* Start of visual line containing pos; scans forward from scanFrom *)
PROCEDURE LineStartFrom(scanFrom, pos: INTEGER): INTEGER;
VAR i, x, w, ls: INTEGER;
BEGIN
  w := Terminal.Cols();
  i := scanFrom; x := 1; ls := scanFrom;
  WHILE i < pos DO
    IF x > w THEN ls := i; x := 1
    ELSIF text[i] = RetChar THEN ls := i + 1; INC(i); x := 1
    ELSE INC(i); INC(x)
    END
  END;
  IF x > w THEN ls := pos END;
  RETURN ls
END LineStartFrom;

(* Given a visual line start, return the start of the next visual line *)
PROCEDURE NextVisLine(lineStart: INTEGER): INTEGER;
VAR i, x, w: INTEGER;
BEGIN
  w := Terminal.Cols();
  i := lineStart; x := 1;
  WHILE i < lastLine DO
    IF x > w THEN RETURN i
    ELSIF text[i] = RetChar THEN RETURN i + 1
    ELSE INC(i); INC(x)
    END
  END;
  RETURN lastLine
END NextVisLine;

(* Scan from 0 to find the start of the visual line BEFORE the line
   that contains pos. Returns 0 if pos is already on the first line. *)
PROCEDURE PrevVisLine(pos: INTEGER): INTEGER;
VAR i, x, w, prev, cur: INTEGER;
BEGIN
  IF pos = 0 THEN RETURN 0 END;
  w := Terminal.Cols();
  i := 0; x := 1; prev := 0; cur := 0;
  WHILE i < pos DO
    IF x > w THEN prev := cur; cur := i; x := 1
    ELSIF text[i] = RetChar THEN
      prev := cur; cur := i + 1; INC(i); x := 1
    ELSE INC(i); INC(x)
    END
  END;
  IF x > w THEN prev := cur; cur := pos END;
  IF cur = pos THEN RETURN prev END;
  RETURN cur
END PrevVisLine;

(* Advance at most (col-1) chars from lineStart, stopping at line end.
   Returns the buffer position for visual column col on that line. *)
PROCEDURE AdvanceOnLine(lineStart, col: INTEGER): INTEGER;
VAR i, x, w: INTEGER;
BEGIN
  w := Terminal.Cols();
  i := lineStart; x := 1;
  WHILE i < lastLine DO
    IF x = col THEN RETURN i END;
    IF (x >= w) OR (text[i] = RetChar) THEN RETURN i END;
    INC(i); INC(x)
  END;
  RETURN i
END AdvanceOnLine;

(* Compute visual pos (vx, vy) of buffer position pos from topLin *)
PROCEDURE ComputeVis(pos: INTEGER; VAR vx, vy: INTEGER);
VAR i, x, y, w: INTEGER;
BEGIN
  w := Terminal.Cols(); x := 1; y := 2; i := topLin;
  WHILE i < pos DO
    IF x > w THEN x := 1; INC(y)
    ELSIF text[i] = RetChar THEN x := 1; INC(y); INC(i)
    ELSE INC(i); INC(x)
    END
  END;
  vx := x; vy := y
END ComputeVis;

PROCEDURE AdjustScroll;
VAR vx, vy, rows: INTEGER;
BEGIN
  rows := Terminal.Rows() - 1;
  ComputeVis(curr, vx, vy);
  WHILE (vy < 2) & (topLin > 0) DO
    topLin := PrevVisLine(topLin);
    ComputeVis(curr, vx, vy)
  END;
  WHILE vy >= rows DO
    topLin := NextVisLine(topLin);
    ComputeVis(curr, vx, vy)
  END
END AdjustScroll;

PROCEDURE HandleMouse;
VAR mx, my, mb, i, tx, ty, w, rows: INTEGER;
BEGIN
  mx := Terminal.MouseX();
  my := Terminal.MouseY();
  mb := Terminal.MouseBtn();
  IF (mb # 0) & (mb # 3) THEN RETURN END;
  w := Terminal.Cols();
  rows := Terminal.Rows() - 1;
  tx := 1; ty := 2; (* Starting position of text area in Refresh *)
  i := topLin;

  (* Scan through visible text to find match for mx, my *)
  WHILE (i <= lastLine) & (ty <= rows) DO
    IF tx > w THEN tx := 1; INC(ty) END;

    IF (mx = tx) & (my = ty) THEN
      curr := i; RETURN
    END;

    IF i = lastLine THEN i := lastLine + 1
    ELSIF text[i] = RetChar THEN
      tx := 1; INC(ty); INC(i)
    ELSE
      INC(i); INC(tx)
    END
  END
END HandleMouse;

(* ── Syntax Highlighting ────────────────────────────────────────────── *)

PROCEDURE DetectLang;
BEGIN
  IF Strings.EndsWith(fname, ".c") THEN lang := HLANG_C
  ELSIF Strings.EndsWith(fname, ".cpp") THEN lang := HLANG_CPP
  ELSIF Strings.EndsWith(fname, ".mod") THEN lang := HLANG_OBN
  ELSE lang := HLANG_NONE
  END
END DetectLang;

PROCEDURE IsIdChar(ch: CHAR): BOOLEAN;
BEGIN
  RETURN ((ch >= "a") & (ch <= "z")) OR ((ch >= "A") & (ch <= "Z")) OR
         ((ch >= "0") & (ch <= "9")) OR (ch = "_")
END IsIdChar;

PROCEDURE InList(VAR word, list: ARRAY OF CHAR): BOOLEAN;
VAR w: ARRAY 66 OF CHAR; wlen, i: INTEGER;
BEGIN
  wlen := Strings.Length(word);
  IF (wlen = 0) OR (wlen > 63) THEN RETURN FALSE END;
  w[0] := " ";
  FOR i := 0 TO wlen - 1 DO w[i + 1] := word[i] END;
  w[wlen + 1] := " "; w[wlen + 2] := 0X;
  RETURN Strings.Pos(w, list) >= 0
END InList;

PROCEDURE IsKW(VAR word: ARRAY OF CHAR): BOOLEAN;
VAR kw: ARRAY 256 OF CHAR;
BEGIN
  IF (lang = HLANG_C) OR (lang = HLANG_CPP) THEN
    COPY(" auto break case char const continue default do double else ", kw);
    IF InList(word, kw) THEN RETURN TRUE END;
    COPY(" enum extern float for goto if inline int long register ", kw);
    IF InList(word, kw) THEN RETURN TRUE END;
    COPY(" return short signed sizeof static struct switch typedef ", kw);
    IF InList(word, kw) THEN RETURN TRUE END;
    COPY(" union unsigned void volatile while NULL true false ", kw);
    IF InList(word, kw) THEN RETURN TRUE END
  END;
  IF lang = HLANG_CPP THEN
    COPY(" bool catch class constexpr delete explicit export friend ", kw);
    IF InList(word, kw) THEN RETURN TRUE END;
    COPY(" mutable namespace new noexcept nullptr operator override ", kw);
    IF InList(word, kw) THEN RETURN TRUE END;
    COPY(" private protected public static_assert static_cast ", kw);
    IF InList(word, kw) THEN RETURN TRUE END;
    COPY(" template this throw try typeid typename using virtual ", kw);
    IF InList(word, kw) THEN RETURN TRUE END
  END;
  IF lang = HLANG_OBN THEN
    COPY(" MODULE IMPORT CONST TYPE VAR PROCEDURE BEGIN END RETURN ", kw);
    IF InList(word, kw) THEN RETURN TRUE END;
    COPY(" IF THEN ELSIF ELSE WHILE DO REPEAT UNTIL FOR BY TO LOOP ", kw);
    IF InList(word, kw) THEN RETURN TRUE END;
    COPY(" EXIT CASE OF WITH ARRAY RECORD POINTER BOOLEAN BYTE ", kw);
    IF InList(word, kw) THEN RETURN TRUE END;
    COPY(" SHORTINT INTEGER LONGINT REAL LONGREAL CHAR SET STRING ", kw);
    IF InList(word, kw) THEN RETURN TRUE END;
    COPY(" NIL DIV MOD OR IN IS TRUE FALSE NEW FREE HALT ASSERT ", kw);
    IF InList(word, kw) THEN RETURN TRUE END;
    COPY(" INCL EXCL COPY ABS ODD ORD CHR CAP FLOOR LEN FLT ", kw);
    IF InList(word, kw) THEN RETURN TRUE END;
    COPY(" ASR LSL ROR INC DEC PACK UNPK ", kw);
    IF InList(word, kw) THEN RETURN TRUE END
  END;
  RETURN FALSE
END IsKW;

PROCEDURE Highlight;
(* state: 0=normal 1=line-comment 2=block-comment 3=dbl-string 4=sgl-string 5=prepro *)
VAR
  i, state, wStart, wlen, j: INTEGER;
  atLineStart: BOOLEAN;
  word: ARRAY 64 OF CHAR;
BEGIN
  FOR i := 0 TO lastLine - 1 DO hlColor[i] := HNormal END;
  IF lang = HLANG_NONE THEN RETURN END;
  i := 0; state := 0; atLineStart := TRUE;
  WHILE i < lastLine DO
    IF state = 0 THEN (* normal *)
      IF text[i] = RetChar THEN
        atLineStart := TRUE; INC(i)
      ELSIF (lang # HLANG_OBN) & (text[i] = "/") & (i+1 < lastLine) & (text[i+1] = "/") THEN
        hlColor[i] := HComment; hlColor[i+1] := HComment; INC(i, 2); state := 1
      ELSIF (lang # HLANG_OBN) & (text[i] = "/") & (i+1 < lastLine) & (text[i+1] = "*") THEN
        hlColor[i] := HComment; hlColor[i+1] := HComment; INC(i, 2); state := 2
      ELSIF (lang = HLANG_OBN) & (text[i] = "(") & (i+1 < lastLine) & (text[i+1] = "*") THEN
        hlColor[i] := HComment; hlColor[i+1] := HComment; INC(i, 2); state := 2
      ELSIF (lang # HLANG_OBN) & (text[i] = "#") & atLineStart THEN
        hlColor[i] := HPrepro; INC(i); state := 5; atLineStart := FALSE
      ELSIF text[i] = CHR(34) THEN
        hlColor[i] := HString; INC(i); state := 3; atLineStart := FALSE
      ELSIF text[i] = "'" THEN
        hlColor[i] := HString; INC(i); state := 4; atLineStart := FALSE
      ELSIF (text[i] >= "0") & (text[i] <= "9") THEN
        WHILE (i < lastLine) & (IsIdChar(text[i]) OR (text[i] = ".")) DO
          hlColor[i] := HNumber; INC(i)
        END;
        atLineStart := FALSE
      ELSIF ((text[i] >= "a") & (text[i] <= "z")) OR
            ((text[i] >= "A") & (text[i] <= "Z")) OR (text[i] = "_") THEN
        wStart := i;
        WHILE (i < lastLine) & IsIdChar(text[i]) DO INC(i) END;
        wlen := i - wStart; IF wlen > 63 THEN wlen := 63 END;
        FOR j := 0 TO wlen - 1 DO word[j] := text[wStart + j] END;
        word[wlen] := 0X;
        IF IsKW(word) THEN
          FOR j := wStart TO wStart + wlen - 1 DO hlColor[j] := HKeyword END
        END;
        atLineStart := FALSE
      ELSE
        INC(i); atLineStart := FALSE
      END
    ELSIF state = 1 THEN (* C/C++ line comment *)
      IF text[i] = RetChar THEN state := 0; atLineStart := TRUE; INC(i)
      ELSE hlColor[i] := HComment; INC(i)
      END
    ELSIF state = 2 THEN (* block comment *)
      hlColor[i] := HComment;
      IF (lang = HLANG_OBN) & (text[i] = "*") & (i+1 < lastLine) & (text[i+1] = ")") THEN
        hlColor[i+1] := HComment; INC(i, 2); state := 0
      ELSIF (lang # HLANG_OBN) & (text[i] = "*") & (i+1 < lastLine) & (text[i+1] = "/") THEN
        hlColor[i+1] := HComment; INC(i, 2); state := 0
      ELSE INC(i)
      END
    ELSIF state = 3 THEN (* double-quoted string *)
      hlColor[i] := HString;
      IF (lang # HLANG_OBN) & (text[i] = CHR(92)) THEN
        IF i+1 < lastLine THEN hlColor[i+1] := HString; INC(i, 2) ELSE INC(i) END
      ELSIF (text[i] = CHR(34)) OR (text[i] = RetChar) THEN
        INC(i); state := 0
      ELSE INC(i)
      END
    ELSIF state = 4 THEN (* single-quoted string / char literal *)
      hlColor[i] := HString;
      IF (lang # HLANG_OBN) & (text[i] = CHR(92)) THEN
        IF i+1 < lastLine THEN hlColor[i+1] := HString; INC(i, 2) ELSE INC(i) END
      ELSIF (text[i] = "'") OR (text[i] = RetChar) THEN
        INC(i); state := 0
      ELSE INC(i)
      END
    ELSIF state = 5 THEN (* C/C++ preprocessor *)
      IF text[i] = RetChar THEN state := 0; atLineStart := TRUE; INC(i)
      ELSE hlColor[i] := HPrepro; INC(i)
      END
    END
  END
END Highlight;

PROCEDURE FGColor(n: INTEGER);
VAR s: ARRAY 8 OF CHAR; code: INTEGER;
BEGIN
  Out.Char(CHR(27)); Out.Char("[");
  IF n < 8 THEN code := 30 + n ELSE code := 82 + n END;
  Strings.IntToStr(code, s); Out.String(s); Out.Char("m")
END FGColor;

PROCEDURE FGColor256(n: INTEGER);
VAR s: ARRAY 8 OF CHAR;
BEGIN
  Out.Char(CHR(27)); Out.String("[38;5;");
  Strings.IntToStr(n, s); Out.String(s); Out.Char("m")
END FGColor256;

PROCEDURE SetHL(hl: INTEGER);
BEGIN
  IF hl # hlLast THEN
    hlLast := hl;
    CASE hl OF
      HKeyword: FGColor256(81)
    | HString:  FGColor256(114)
    | HComment: FGColor256(244)
    | HNumber:  FGColor256(215)
    | HPrepro:  FGColor256(183)
    ELSE Terminal.Reset
    END
  END
END SetHL;

(* ── Display ────────────────────────────────────────────────────────── *)

PROCEDURE ShowStatus(s: ARRAY OF CHAR);
VAR i, w: INTEGER;
BEGIN
  w := Terminal.Cols();
  Terminal.Color(0, 15);
  Terminal.Goto(1, 1);
  Out.String(s);
  i := Strings.Length(s);
  WHILE i < w DO Out.Char(" "); INC(i) END;
  Terminal.Reset
END ShowStatus;

PROCEDURE DrawStatus;
VAR s, t: ARRAY 256 OF CHAR;
BEGIN
  Strings.Copy(" SpeedScript | ", s);
  IF fname[0] # 0X THEN Strings.Append(fname, s)
  ELSE Strings.Append("[untitled]", s)
  END;
  IF modified THEN Strings.Append(" *", s) END;
  Strings.Append(" | ", s);
  Strings.IntToStr(curr, t); Strings.Append(t, s);
  Strings.Append("/", s);
  Strings.IntToStr(lastLine, t); Strings.Append(t, s);
  IF insMode THEN Strings.Append(" [INS]", s)
  ELSE Strings.Append(" [OVR]", s)
  END;
  ShowStatus(s)
END DrawStatus;

PROCEDURE Refresh;
VAR
  i, x, y, w, rows: INTEGER;
BEGIN
  Terminal.HideCursor;
  Terminal.Clear;
  w := Terminal.Cols(); rows := Terminal.Rows() - 1;
  DrawStatus;
  x := 1; y := 2; cx := 1; cy := 2;
  hlLast := -1;
  i := topLin;
  WHILE (i <= lastLine) & (y <= rows) DO
    IF x > w THEN x := 1; INC(y) END;
    IF i = curr THEN cx := x; cy := y END;
    IF i = lastLine THEN (* end of text, stop *)
      i := lastLine + 1
    ELSIF y <= rows THEN
      Terminal.Goto(x, y);
      IF text[i] = RetChar THEN
        FGColor(8); Out.Char("<"); Terminal.Reset; hlLast := -1;
        x := 1; INC(y); INC(i)
      ELSE
        SetHL(hlColor[i]);
        Out.Char(text[i]); INC(i); INC(x)
      END
    ELSE
      INC(i)  (* off-screen, just advance *)
    END
  END;
  IF lang # HLANG_NONE THEN Terminal.Reset END;
  Terminal.Goto(cx, cy);
  Terminal.ShowCursor
END Refresh;

(* ── Status-line prompt and string input ────────────────────────────── *)

PROCEDURE Prompt(msg: ARRAY OF CHAR);
BEGIN ShowStatus(msg) END Prompt;

(* Read a string at the status line.  Returns FALSE if ESC pressed. *)
PROCEDURE ReadStr(label: ARRAY OF CHAR; VAR result: ARRAY OF CHAR): BOOLEAN;
VAR
  len, k, plen, maxlen: INTEGER;
  s: ARRAY 256 OF CHAR;
BEGIN
  len := 0; result[0] := 0X;
  plen := Strings.Length(label);
  maxlen := LEN(result) - 1;
  Strings.Copy(label, s);
  ShowStatus(s);
  Terminal.Goto(plen + 1, 1);
  Terminal.ShowCursor;
  LOOP
    k := Terminal.ReadKey();
    IF k = KEY_ESC THEN
      Terminal.HideCursor; RETURN FALSE
    ELSIF k = KEY_ENTER THEN
      result[len] := 0X; Terminal.HideCursor; RETURN TRUE
    ELSIF k = KEY_BS THEN
      IF len > 0 THEN
        DEC(len); result[len] := 0X;
        Terminal.Goto(plen + len + 1, 1); Out.Char(" ");
        Terminal.Goto(plen + len + 1, 1)
      END
    ELSIF (k >= 32) & (k < 127) & (len < maxlen) THEN
      result[len] := CHR(k); INC(len); result[len] := 0X;
      Out.Char(CHR(k))
    END
  END
END ReadStr;

(* ── Edit operations ────────────────────────────────────────────────── *)

PROCEDURE Insert(ch: CHAR);
BEGIN
  IF lastLine >= MaxText - 1 THEN RETURN END;
  IF insMode THEN
    MoveText(curr, curr + 1, lastLine - curr);
    INC(lastLine)
  END;
  text[curr] := ch;
  RecordIns(curr, 1);
  INC(curr);
  IF curr > lastLine THEN lastLine := curr END;
  modified := TRUE
END Insert;

PROCEDURE Backspace;
BEGIN
  IF curr > 0 THEN
    RecordDel(curr - 1, 1, text, curr - 1);
    DEC(curr); DEC(lastLine);
    MoveText(curr + 1, curr, lastLine - curr);
    modified := TRUE
  END
END Backspace;

PROCEDURE DeleteFwd;
BEGIN
  IF curr < lastLine THEN
    RecordDel(curr, 1, text, curr);
    DEC(lastLine);
    MoveText(curr + 1, curr, lastLine - curr);
    modified := TRUE
  END
END DeleteFwd;

(* Kill from curr to end of visual line; if at line end, kill the break *)
PROCEDURE KillToEOL;
VAR ls, le, n, i: INTEGER;
BEGIN
  ls := LineStartFrom(topLin, curr);
  le := NextVisLine(ls);
  (* le = first char of next visual line.
     If line ends with RetChar (le-1 is the RetChar), kill up to but not
     including it — unless curr IS the RetChar, in which case kill it. *)
  n := le - curr;
  IF (le > 0) & (le - 1 < lastLine) & (text[le - 1] = RetChar) & (curr < le - 1) THEN
    n := le - 1 - curr
  END;
  IF n <= 0 THEN n := lastLine - curr END;
  IF n > BufSize THEN n := BufSize END;
  IF n <= 0 THEN RETURN END;
  cutLen := n;
  FOR i := 0 TO n - 1 DO cutBuf[i] := text[curr + i] END;
  RecordDel(curr, n, text, curr);
  MoveText(curr + n, curr, lastLine - (curr + n));
  DEC(lastLine, n);
  modified := TRUE
END KillToEOL;

(* Delete one word backward *)
PROCEDURE KillWordBack;
VAR start, n, i: INTEGER;
BEGIN
  IF curr = 0 THEN RETURN END;
  start := curr - 1;
  WHILE (start > 0) & ~IsWord(text[start]) DO DEC(start) END;
  WHILE (start > 0) & IsWord(text[start - 1]) DO DEC(start) END;
  n := curr - start;
  IF n <= 0 THEN RETURN END;
  IF n > BufSize THEN n := BufSize END;
  cutLen := n;
  FOR i := 0 TO n - 1 DO cutBuf[i] := text[start + i] END;
  RecordDel(start, n, text, start);
  curr := start;
  MoveText(curr + n, curr, lastLine - (curr + n));
  DEC(lastLine, n);
  modified := TRUE
END KillWordBack;

PROCEDURE Paste;
VAR i, old: INTEGER;
BEGIN
  IF cutLen = 0 THEN RETURN END;
  IF lastLine + cutLen >= MaxText THEN RETURN END;
  old := curr;
  MoveText(curr, curr + cutLen, lastLine - curr);
  FOR i := 0 TO cutLen - 1 DO text[curr + i] := cutBuf[i] END;
  INC(lastLine, cutLen);
  INC(curr, cutLen);
  RecordIns(old, cutLen);
  modified := TRUE
END Paste;

PROCEDURE Transpose;
VAR tmp: CHAR;
BEGIN
  IF (curr > 0) & (curr < lastLine) THEN
    tmp := text[curr - 1];
    text[curr - 1] := text[curr];
    text[curr] := tmp;
    INC(curr);
    modified := TRUE
  END
END Transpose;

PROCEDURE ToggleCase;
VAR ch: CHAR;
BEGIN
  IF curr < lastLine THEN
    ch := text[curr];
    IF (ch >= "a") & (ch <= "z") THEN text[curr] := CHR(ORD(ch) - 32)
    ELSIF (ch >= "A") & (ch <= "Z") THEN text[curr] := CHR(ORD(ch) + 32)
    END;
    modified := TRUE
  END
END ToggleCase;

(* ── Navigation ─────────────────────────────────────────────────────── *)

PROCEDURE MoveUp;
VAR ls, prev: INTEGER;
BEGIN
  ls := LineStartFrom(topLin, curr);
  IF ls <= topLin THEN
    IF topLin = 0 THEN RETURN END;
    topLin := PrevVisLine(topLin);
    ls := LineStartFrom(topLin, curr)
  END;
  prev := PrevVisLine(ls);
  curr := AdvanceOnLine(prev, cx)
END MoveUp;

PROCEDURE MoveDown;
VAR ls, nx: INTEGER;
BEGIN
  ls := LineStartFrom(topLin, curr);
  nx := NextVisLine(ls);
  IF nx >= lastLine THEN curr := lastLine; RETURN END;
  curr := AdvanceOnLine(nx, cx)
END MoveDown;

PROCEDURE WordRight;
BEGIN
  WHILE (curr < lastLine) & IsWord(text[curr]) DO INC(curr) END;
  WHILE (curr < lastLine) & ~IsWord(text[curr]) DO INC(curr) END
END WordRight;

PROCEDURE WordLeft;
BEGIN
  IF curr > 0 THEN DEC(curr) END;
  WHILE (curr > 0) & ~IsWord(text[curr]) DO DEC(curr) END;
  WHILE (curr > 0) & IsWord(text[curr - 1]) DO DEC(curr) END
END WordLeft;

PROCEDURE PageDown;
VAR rows, i: INTEGER;
BEGIN
  rows := Terminal.Rows() - 2;
  FOR i := 1 TO rows DO topLin := NextVisLine(topLin) END;
  IF curr < topLin THEN curr := topLin END;
  ComputeVis(curr, cx, cy)
END PageDown;

PROCEDURE PageUp;
VAR rows, i, bot: INTEGER;
BEGIN
  rows := Terminal.Rows() - 2;
  FOR i := 1 TO rows DO
    IF topLin > 0 THEN topLin := PrevVisLine(topLin) END
  END;
  bot := topLin;
  FOR i := 1 TO rows DO bot := NextVisLine(bot) END;
  IF curr > bot THEN curr := bot END;
  ComputeVis(curr, cx, cy)
END PageUp;

(* ── File I/O ───────────────────────────────────────────────────────── *)

PROCEDURE SaveFile;
VAR
  f: Files.File; r: Files.Rider;
  tmpname: ARRAY MaxName OF CHAR;
  i: INTEGER;
BEGIN
  (* Only prompt if fname is empty *)
  IF fname[0] = 0X THEN
    IF ReadStr("Save as: ", tmpname) THEN
      IF tmpname[0] = 0X THEN Prompt("No filename."); RETURN END;
      COPY(tmpname, fname); DetectLang
    ELSE
      RETURN (* User cancelled prompt *)
    END
  END;

  f := Files.New(fname);
  IF f = NIL THEN Prompt("Cannot create file."); RETURN END;
  
  Files.Set(r, f, 0);
  FOR i := 0 TO lastLine - 1 DO
    IF text[i] = RetChar THEN Files.Write(r, ORD(0AX))   (* LF *)
    ELSE Files.Write(r, ORD(text[i]))
    END
  END;
  Files.Register(f);
  modified := FALSE;
  Prompt("Saved.")
END SaveFile;

PROCEDURE SaveFileAs;
VAR
  f: Files.File; r: Files.Rider;
  newname: ARRAY MaxName OF CHAR;
  i: INTEGER;
BEGIN
  IF ~ReadStr("Save as: ", newname) THEN RETURN END;
  IF newname[0] = 0X THEN Prompt("No filename."); RETURN END;
  f := Files.New(newname);
  IF f = NIL THEN Prompt("Cannot create file."); RETURN END;
  Files.Set(r, f, 0);
  FOR i := 0 TO lastLine - 1 DO
    IF text[i] = RetChar THEN Files.Write(r, ORD(0AX))
    ELSE Files.Write(r, ORD(text[i]))
    END
  END;
  Files.Register(f);
  COPY(newname, fname);
  modified := FALSE; DetectLang;
  Prompt("Saved.")
END SaveFileAs;

PROCEDURE LoadFile;
VAR
  f: Files.File; r: Files.Rider;
  tmpname: ARRAY MaxName OF CHAR;
  b, count: INTEGER;
BEGIN
  IF ReadStr("Load: ", tmpname) THEN
    IF tmpname[0] = 0X THEN RETURN END;
    f := Files.Old(tmpname);
    IF f = NIL THEN Prompt("File not found."); RETURN END;
    Files.Set(r, f, 0);
    count := 0;
    WHILE ~r.eof & (count < MaxText - 1) DO
      Files.Read(r, b);
      IF ~r.eof THEN
        IF b = ORD(0AX) THEN text[count] := RetChar; INC(count)   (* LF → RetChar *)
        ELSIF b = ORD(0DX) THEN (* skip CR *)
        ELSE text[count] := CHR(b); INC(count)
        END
      END
    END;
    Files.Close(f);
    COPY(tmpname, fname);
    curr := 0; lastLine := count; topLin := 0;
    modified := FALSE; undoHead := 0; undoCnt := 0;
    DetectLang;
    Prompt("Loaded.")
  END
END LoadFile;

(* ── Search & Replace ───────────────────────────────────────────────── *)

PROCEDURE FindNext(): BOOLEAN;
VAR i, j, slen: INTEGER;
BEGIN
  slen := Strings.Length(searchStr);
  IF slen = 0 THEN RETURN FALSE END;
  i := curr + 1;
  WHILE i + slen <= lastLine DO
    j := 0;
    WHILE (j < slen) & (text[i + j] = searchStr[j]) DO INC(j) END;
    IF j = slen THEN curr := i; RETURN TRUE END;
    INC(i)
  END;
  RETURN FALSE
END FindNext;

PROCEDURE DoFind;
VAR s: ARRAY 128 OF CHAR;
BEGIN
  IF ReadStr("Find: ", s) THEN
    IF s[0] # 0X THEN COPY(s, searchStr) END;
    IF searchStr[0] = 0X THEN RETURN END;
    IF FindNext() THEN Prompt("Found.")
    ELSE Prompt("Not found.")
    END
  END
END DoFind;

PROCEDURE DoFindReplace;
VAR
  rlen, slen, diff, count, j: INTEGER;
  s: ARRAY 64 OF CHAR;
BEGIN
  IF ~ReadStr("Find: ", searchStr) THEN RETURN END;
  IF ~ReadStr("Replace: ", replStr) THEN RETURN END;
  slen := Strings.Length(searchStr);
  rlen := Strings.Length(replStr);
  IF slen = 0 THEN RETURN END;
  curr := 0; count := 0;
  WHILE FindNext() DO
    MoveText(curr + slen, curr + rlen, lastLine - (curr + slen));
    diff := rlen - slen;
    INC(lastLine, diff);
    FOR j := 0 TO rlen - 1 DO text[curr + j] := replStr[j] END;
    INC(curr, rlen);
    INC(count)
  END;
  Strings.IntToStr(count, s);
  Strings.Append(" replacement(s).", s);
  Prompt(s)
END DoFindReplace;

(* ── New document ───────────────────────────────────────────────────── *)

PROCEDURE ShowHelp;
VAR row, c2, w, h, i: INTEGER;
BEGIN
  w := Terminal.Cols(); h := Terminal.Rows(); c2 := w DIV 2 + 1;
  Terminal.HideCursor;
  Terminal.Clear;

  (* Title bar *)
  ShowStatus("  SpeedScript 3.0  Key Bindings  (press any key to return)  ");

  (* Horizontal rule row 2 *)
  Terminal.Goto(1, 2);
  FGColor(8);
  FOR i := 1 TO w DO Out.Char("-") END;
  Terminal.Reset;

  (* ── Left column ────────────────────────────────────── *)
  row := 3;
  Terminal.Goto(1, row); FGColor(14); Out.String("Navigation");     Terminal.Reset; INC(row);
  Terminal.Goto(1, row); FGColor(11); Out.String("Arrow keys  ");   FGColor(7); Out.String("Move cursor");          Terminal.Reset; INC(row);
  Terminal.Goto(1, row); FGColor(11); Out.String("Ctrl-Left/Rt");   FGColor(7); Out.String("  Word left / right");  Terminal.Reset; INC(row);
  Terminal.Goto(1, row); FGColor(11); Out.String("Home / End  ");   FGColor(7); Out.String("  Start / end of doc"); Terminal.Reset; INC(row);
  Terminal.Goto(1, row); FGColor(11); Out.String("PgUp / PgDn ");   FGColor(7); Out.String("  Page up / down");     Terminal.Reset; INC(row);
  INC(row);
  Terminal.Goto(1, row); FGColor(14); Out.String("Editing");        Terminal.Reset; INC(row);
  Terminal.Goto(1, row); FGColor(11); Out.String("Backspace   ");   FGColor(7); Out.String("  Delete char left");       Terminal.Reset; INC(row);
  Terminal.Goto(1, row); FGColor(11); Out.String("Del         ");   FGColor(7); Out.String("  Delete char at cursor");   Terminal.Reset; INC(row);
  Terminal.Goto(1, row); FGColor(11); Out.String("Enter       ");   FGColor(7); Out.String("  Insert paragraph break");  Terminal.Reset; INC(row);
  Terminal.Goto(1, row); FGColor(11); Out.String("Tab         ");   FGColor(7); Out.String("  Toggle insert/overwrite"); Terminal.Reset; INC(row);
  Terminal.Goto(1, row); FGColor(11); Out.String("Ctrl-T      ");   FGColor(7); Out.String("  Transpose chars");         Terminal.Reset; INC(row);
  Terminal.Goto(1, row); FGColor(11); Out.String("Ctrl-X      ");   FGColor(7); Out.String("  Toggle case");             Terminal.Reset; INC(row);
  Terminal.Goto(1, row); FGColor(11); Out.String("Ctrl-Z      ");   FGColor(7); Out.String("  Undo");                    Terminal.Reset; INC(row);
  INC(row);
  Terminal.Goto(1, row); FGColor(14); Out.String("Other");          Terminal.Reset; INC(row);
  Terminal.Goto(1, row); FGColor(11); Out.String("F1          ");   FGColor(7); Out.String("  This help screen");        Terminal.Reset; INC(row);
  Terminal.Goto(1, row); FGColor(11); Out.String("Esc         ");   FGColor(7); Out.String("  Quit");                    Terminal.Reset;

  (* ── Right column ───────────────────────────────────── *)
  row := 3;
  Terminal.Goto(c2, row); FGColor(14); Out.String("Cut & Paste");    Terminal.Reset; INC(row);
  Terminal.Goto(c2, row); FGColor(11); Out.String("Ctrl-K  ");       FGColor(7); Out.String("Kill to end of line");    Terminal.Reset; INC(row);
  Terminal.Goto(c2, row); FGColor(11); Out.String("Ctrl-W  ");       FGColor(7); Out.String("Delete word backward");   Terminal.Reset; INC(row);
  Terminal.Goto(c2, row); FGColor(11); Out.String("Ctrl-R  ");       FGColor(7); Out.String("Paste (restore) buffer"); Terminal.Reset; INC(row);
  INC(row);
  Terminal.Goto(c2, row); FGColor(14); Out.String("Search");         Terminal.Reset; INC(row);
  Terminal.Goto(c2, row); FGColor(11); Out.String("Ctrl-F  ");       FGColor(7); Out.String("Find (Enter=repeat)");    Terminal.Reset; INC(row);
  Terminal.Goto(c2, row); FGColor(11); Out.String("Ctrl-G  ");       FGColor(7); Out.String("Find and replace all");   Terminal.Reset; INC(row);
  INC(row);
  Terminal.Goto(c2, row); FGColor(14); Out.String("File");           Terminal.Reset; INC(row);
  Terminal.Goto(c2, row); FGColor(11); Out.String("Ctrl-S  ");       FGColor(7); Out.String("Save");                   Terminal.Reset; INC(row);
  Terminal.Goto(c2, row); FGColor(11); Out.String("F2      ");       FGColor(7); Out.String("Save as (new filename)"); Terminal.Reset; INC(row);
  Terminal.Goto(c2, row); FGColor(11); Out.String("Ctrl-L  ");       FGColor(7); Out.String("Load file");              Terminal.Reset; INC(row);
  Terminal.Goto(c2, row); FGColor(11); Out.String("Ctrl-N  ");       FGColor(7); Out.String("New document");           Terminal.Reset; INC(row);
  INC(row);
  Terminal.Goto(c2, row); FGColor(14); Out.String("Text symbols");   Terminal.Reset; INC(row);
  Terminal.Goto(c2, row); FGColor(11); Out.String("<       ");        FGColor(7); Out.String("Hard paragraph break");   Terminal.Reset;

  i := Terminal.ReadKey();
  Terminal.ShowCursor
END ShowHelp;

PROCEDURE NewDoc;
VAR k: INTEGER;
BEGIN
  Prompt("New document - lose changes? (y/n)");
  k := Terminal.ReadKey();
  IF (k = ORD("y")) OR (k = ORD("Y")) THEN
    curr := 0; lastLine := 0; topLin := 0;
    fname[0] := 0X; modified := FALSE;
    undoHead := 0; undoCnt := 0; lang := HLANG_NONE;
    Prompt("New document.")
  END
END NewDoc;

(* ── Main loop ──────────────────────────────────────────────────────── *)

PROCEDURE Run*;
VAR k, b: INTEGER; f: Files.File; r: Files.Rider;
BEGIN
  curr := 0; lastLine := 0; topLin := 0;
  fname[0] := 0X;
  searchStr[0] := 0X; replStr[0] := 0X;
  cutLen := 0;
  undoHead := 0; undoCnt := 0; lang := HLANG_NONE;
  insMode := TRUE; modified := FALSE; running := TRUE;

  (* Load filename from command line if given *)
  IF Args.Count() > 0 THEN
    Args.Get(1, fname);
    DetectLang;
    f := Files.Old(fname);
    IF f # NIL THEN
      Files.Set(r, f, 0);
      WHILE ~r.eof & (lastLine < MaxText - 1) DO
        Files.Read(r, b);
        IF ~r.eof THEN
          IF b = ORD(0AX) THEN text[lastLine] := RetChar; INC(lastLine)
          ELSIF b = ORD(0DX) THEN (* skip CR *)
          ELSE text[lastLine] := CHR(b); INC(lastLine)
          END
        END
      END;
      Files.Close(f)
    END
  END;

  WHILE running DO
    AdjustScroll;
    IF lang # HLANG_NONE THEN Highlight END;
    Refresh;
    k := Terminal.ReadKey();

    CASE k OF
      KEY_ESC:
      IF modified THEN
          IF ReadStr("Unsaved changes. Exit? (y/n): ", searchStr) THEN
            IF (searchStr[0] = "y") OR (searchStr[0] = "Y") THEN
              running := FALSE
            END
          END;
          Refresh (* Restore screen after prompt *)
        ELSE
          running := FALSE
        END
    | KEY_MOUSE:  HandleMouse
    | KEY_BS, 127:     Backspace
    | KEY_DEL:    DeleteFwd
    | KEY_ENTER:  Insert(RetChar)
    | KEY_TAB:    insMode := ~insMode
    | KEY_UP:     MoveUp
    | KEY_DOWN:   MoveDown
    | KEY_LEFT:
        IF curr > 0 THEN DEC(curr) END
    | KEY_RIGHT:
        IF curr < lastLine THEN INC(curr) END
    | KEY_WLEFT:  WordLeft
    | KEY_WRIGHT: WordRight
    | KEY_HOME, KEY_FHOME:
        curr := 0; topLin := 0
    | KEY_END, KEY_FEND:
        curr := lastLine
    | KEY_PGUP:   PageUp
    | KEY_PGDN:   PageDown
    | KEY_CTRL_S: SaveFile
    | KEY_CTRL_L: LoadFile
    | KEY_CTRL_N: NewDoc
    | KEY_CTRL_F: DoFind
    | KEY_CTRL_G: DoFindReplace
    | KEY_CTRL_K: KillToEOL
    | KEY_CTRL_W: KillWordBack
    | KEY_CTRL_R: Paste
    | KEY_CTRL_T: Transpose
    | KEY_CTRL_X: ToggleCase
    | KEY_CTRL_Z: DoUndo
    | KEY_F1:    ShowHelp
    | KEY_F2:    SaveFileAs
    ELSE
      IF (k >= 32) & (k < 127) THEN Insert(CHR(k)) END
    END
  END;

  Terminal.ShowCursor;
  Terminal.Clear
END Run;

BEGIN
  Terminal.MouseOn;
  Run;
  Terminal.MouseOff;
END SpeedScript.



