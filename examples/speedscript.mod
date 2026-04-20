MODULE SpeedScript;

IMPORT Terminal, Graphics, Files, Out, Strings, Args;

CONST
  MaxText = 65536;
  BufSize = 4096;
  MaxName = 256;
  RetChar = 1FX;   (* hard paragraph break, displayed as < *)

  (* Integer key codes *)
  KEY_UP    = 0A0X;   KEY_DOWN  = 0A1X;
  KEY_LEFT  = 0A2X;   KEY_RIGHT = 0A3X;
  KEY_MOUSE = 0A4X;
  KEY_BS    = 8;   KEY_TAB   = 09X;
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
  KEY_PGUP   = 80X; KEY_PGDN   = 81X;
  KEY_HOME   = 82X; KEY_END    = 83X;
  KEY_DEL    = 84X;
  KEY_WLEFT  = 261; KEY_WRIGHT = 262;
  KEY_FHOME  = 263; KEY_FEND   = 264;
  KEY_F1     = 265; KEY_F2     = 266;
  KEY_F3     = 267; KEY_F4     = 268;
  KEY_F5     = 269; KEY_F6     = 270;
  KEY_F7     = 271; KEY_F8     = 272;
  KEY_F9     = 273; KEY_F10    = 274;
  KEY_F11    = 275; KEY_F12    = 276;

VAR
  text:    ARRAY MaxText OF CHAR;
  cutBuf:  ARRAY BufSize OF CHAR;
  cutLen:  INTEGER;

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
  IF mb # 0 & mb # 3 THEN RETURN;
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
  END
END HandleMouse;

(* ── Display ────────────────────────────────────────────────────────── *)

PROCEDURE ShowStatus(s: ARRAY OF CHAR);
VAR i, w: INTEGER;
BEGIN
  w := Terminal.Cols();
  Graphics.Color(0, 15);
  Terminal.Goto(1, 1);
  Out.String(s);
  i := Strings.Length(s);
  WHILE i < w DO Out.Char(" "); INC(i) END;
  Graphics.Reset
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
  i := topLin;
  WHILE (i <= lastLine) & (y <= rows) DO
    IF x > w THEN x := 1; INC(y) END;
    IF i = curr THEN cx := x; cy := y END;
    IF i = lastLine THEN (* end of text, stop *)
      i := lastLine + 1
    ELSIF y <= rows THEN
      Terminal.Goto(x, y);
      IF text[i] = RetChar THEN
        Graphics.Color(8, 0); Out.Char("<"); Graphics.Reset;
        x := 1; INC(y); INC(i)
      ELSE
        Out.Char(text[i]); INC(i); INC(x)
      END
    ELSE
      INC(i)  (* off-screen, just advance *)
    END
  END;
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
    ELSIF (k = KEY_BS) OR (k = 127) THEN
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
  text[curr] := ch; INC(curr);
  IF curr > lastLine THEN lastLine := curr END;
  modified := TRUE
END Insert;

PROCEDURE Backspace;
BEGIN
  IF curr > 0 THEN
    DEC(curr); DEC(lastLine);
    MoveText(curr + 1, curr, lastLine - curr);
    modified := TRUE
  END
END Backspace;

PROCEDURE DeleteFwd;
BEGIN
  IF curr < lastLine THEN
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
  curr := start;
  MoveText(curr + n, curr, lastLine - (curr + n));
  DEC(lastLine, n);
  modified := TRUE
END KillWordBack;

PROCEDURE Paste;
VAR i: INTEGER;
BEGIN
  IF cutLen = 0 THEN RETURN END;
  IF lastLine + cutLen >= MaxText THEN RETURN END;
  MoveText(curr, curr + cutLen, lastLine - curr);
  FOR i := 0 TO cutLen - 1 DO text[curr + i] := cutBuf[i] END;
  INC(lastLine, cutLen);
  INC(curr, cutLen);
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
  ComputeVis(curr, cx, cy)
END PageDown;

PROCEDURE PageUp;
VAR rows, i: INTEGER;
BEGIN
  rows := Terminal.Rows() - 2;
  FOR i := 1 TO rows DO
    IF topLin > 0 THEN topLin := PrevVisLine(topLin) END
  END;
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
      COPY(tmpname, fname)
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
        IF b = ORD(0AX) THEN text[count] := RetChar   (* LF → RetChar *)
        ELSIF b = ORD(0DX) THEN (* skip CR *)
        ELSE text[count] := CHR(b)
        END;
        INC(count)
      END
    END;
    Files.Close(f);
    COPY(tmpname, fname);
    curr := 0; lastLine := count; topLin := 0;
    modified := FALSE;
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
BEGIN
  IF ReadStr("Find: ", searchStr) THEN
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
  Graphics.Color(8, 0);
  FOR i := 1 TO w DO Out.Char("-") END;
  Graphics.Reset;

  (* ── Left column ────────────────────────────────────── *)
  row := 3;
  Terminal.Goto(1, row); Graphics.Color(14, 0); Out.String("Navigation");     Graphics.Reset; INC(row);
  Terminal.Goto(1, row); Graphics.Color(11, 0); Out.String("Arrow keys  ");   Graphics.Color(7, 0); Out.String("Move cursor");          Graphics.Reset; INC(row);
  Terminal.Goto(1, row); Graphics.Color(11, 0); Out.String("Ctrl-Left/Rt");   Graphics.Color(7, 0); Out.String("  Word left / right");  Graphics.Reset; INC(row);
  Terminal.Goto(1, row); Graphics.Color(11, 0); Out.String("Home / End  ");   Graphics.Color(7, 0); Out.String("  Start / end of doc"); Graphics.Reset; INC(row);
  Terminal.Goto(1, row); Graphics.Color(11, 0); Out.String("PgUp / PgDn ");   Graphics.Color(7, 0); Out.String("  Page up / down");     Graphics.Reset; INC(row);
  INC(row);
  Terminal.Goto(1, row); Graphics.Color(14, 0); Out.String("Editing");        Graphics.Reset; INC(row);
  Terminal.Goto(1, row); Graphics.Color(11, 0); Out.String("Backspace   ");   Graphics.Color(7, 0); Out.String("  Delete char left");       Graphics.Reset; INC(row);
  Terminal.Goto(1, row); Graphics.Color(11, 0); Out.String("Del         ");   Graphics.Color(7, 0); Out.String("  Delete char at cursor");   Graphics.Reset; INC(row);
  Terminal.Goto(1, row); Graphics.Color(11, 0); Out.String("Enter       ");   Graphics.Color(7, 0); Out.String("  Insert paragraph break");  Graphics.Reset; INC(row);
  Terminal.Goto(1, row); Graphics.Color(11, 0); Out.String("Tab         ");   Graphics.Color(7, 0); Out.String("  Toggle insert/overwrite"); Graphics.Reset; INC(row);
  Terminal.Goto(1, row); Graphics.Color(11, 0); Out.String("Ctrl-T      ");   Graphics.Color(7, 0); Out.String("  Transpose chars");         Graphics.Reset; INC(row);
  Terminal.Goto(1, row); Graphics.Color(11, 0); Out.String("Ctrl-X      ");   Graphics.Color(7, 0); Out.String("  Toggle case");             Graphics.Reset; INC(row);
  INC(row);
  Terminal.Goto(1, row); Graphics.Color(14, 0); Out.String("Other");          Graphics.Reset; INC(row);
  Terminal.Goto(1, row); Graphics.Color(11, 0); Out.String("F1          ");   Graphics.Color(7, 0); Out.String("  This help screen");        Graphics.Reset; INC(row);
  Terminal.Goto(1, row); Graphics.Color(11, 0); Out.String("Esc         ");   Graphics.Color(7, 0); Out.String("  Quit");                    Graphics.Reset;

  (* ── Right column ───────────────────────────────────── *)
  row := 3;
  Terminal.Goto(c2, row); Graphics.Color(14, 0); Out.String("Cut & Paste");    Graphics.Reset; INC(row);
  Terminal.Goto(c2, row); Graphics.Color(11, 0); Out.String("Ctrl-K  ");       Graphics.Color(7, 0); Out.String("Kill to end of line");    Graphics.Reset; INC(row);
  Terminal.Goto(c2, row); Graphics.Color(11, 0); Out.String("Ctrl-W  ");       Graphics.Color(7, 0); Out.String("Delete word backward");   Graphics.Reset; INC(row);
  Terminal.Goto(c2, row); Graphics.Color(11, 0); Out.String("Ctrl-R  ");       Graphics.Color(7, 0); Out.String("Paste (restore) buffer"); Graphics.Reset; INC(row);
  INC(row);
  Terminal.Goto(c2, row); Graphics.Color(14, 0); Out.String("Search");         Graphics.Reset; INC(row);
  Terminal.Goto(c2, row); Graphics.Color(11, 0); Out.String("Ctrl-F  ");       Graphics.Color(7, 0); Out.String("Find");                   Graphics.Reset; INC(row);
  Terminal.Goto(c2, row); Graphics.Color(11, 0); Out.String("Ctrl-G  ");       Graphics.Color(7, 0); Out.String("Find and replace all");   Graphics.Reset; INC(row);
  INC(row);
  Terminal.Goto(c2, row); Graphics.Color(14, 0); Out.String("File");           Graphics.Reset; INC(row);
  Terminal.Goto(c2, row); Graphics.Color(11, 0); Out.String("Ctrl-S  ");       Graphics.Color(7, 0); Out.String("Save (prompts filename)");Graphics.Reset; INC(row);
  Terminal.Goto(c2, row); Graphics.Color(11, 0); Out.String("Ctrl-L  ");       Graphics.Color(7, 0); Out.String("Load file");              Graphics.Reset; INC(row);
  Terminal.Goto(c2, row); Graphics.Color(11, 0); Out.String("Ctrl-N  ");       Graphics.Color(7, 0); Out.String("New document");           Graphics.Reset; INC(row);
  INC(row);
  Terminal.Goto(c2, row); Graphics.Color(14, 0); Out.String("Text symbols");   Graphics.Reset; INC(row);
  Terminal.Goto(c2, row); Graphics.Color(11, 0); Out.String("<       ");        Graphics.Color(7, 0); Out.String("Hard paragraph break");   Graphics.Reset;

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
  insMode := TRUE; modified := FALSE; running := TRUE;

  (* Load filename from command line if given *)
  IF Args.Count() > 0 THEN
    Args.Get(1, fname);
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
    | KEY_F1:    ShowHelp
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


