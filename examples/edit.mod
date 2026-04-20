MODULE Edit;

IMPORT Terminal, Graphics, Out, Files, Args, Strings;

CONST
  MAXLINES = 2000;
  LLEN     = 256;

  KEY_UP     = 0A0X;
  KEY_DOWN   = 0A1X;
  KEY_LEFT   = 0A2X;
  KEY_RIGHT  = 0A3X;
  KEY_MOUSE  = 0A4X;
  KEY_BS     = 08X;
  KEY_TAB    = 09X;   
  KEY_ESC    = 1BX;
  KEY_ENTER  = 0DX;
  KEY_CTRL_G = 7;
  KEY_CTRL_K = 11;
  KEY_CTRL_F = 6;
  KEY_CTRL_O = 15;
  KEY_CTRL_Q = 17;
  KEY_CTRL_S = 19;
  KEY_CTRL_R = 18;
  KEY_CTRL_Y = 25;
  KEY_HOME   = 82X;  
  KEY_END    = 83X;
  KEY_PGUP   = 80X;
  KEY_PGDN   = 81X;
  KEY_DEL    = 84X;
  KEY_WLEFT  = 261;  
  KEY_WRIGHT = 262;  
  KEY_FHOME  = 263;  
  KEY_FEND   = 264;

  CLR_NORMAL   = 255;  BG_NORMAL  = 0;
  CLR_H1       = 214;
  CLR_H2       = 220;
  CLR_H3       = 226;
  CLR_BOLD     = 15;
  CLR_ITALIC   = 123;
  CLR_BOLDITA  = 213;
  CLR_CODE     = 156;  BG_CODE    = 236;
  CLR_FENCE    = 156;  BG_FENCE   = 17;
  CLR_MARKER   = 240;
  CLR_LINK     = 75;
  CLR_HR       = 242;
  CLR_QUOTE    = 147;
  CLR_LIST     = 215;
  CLR_STRIKE   = 244;
  CLR_TASKDONE = 238;

VAR
  ROWS, EROWS, COLS : INTEGER;
  buf      : ARRAY MAXLINES, LLEN OF CHAR;
  nlines   : INTEGER;
  cx, cy   : INTEGER;
  topLine  : INTEGER;
  leftCol  : INTEGER;
  filename : ARRAY 256 OF CHAR;
  tmpname  : ARRAY 256 OF CHAR;
  statusMsg: ARRAY 60  OF CHAR;
  modified    : BOOLEAN;
  running     : BOOLEAN;
  btn, k, mx, my  : INTEGER;
  searchQuery : ARRAY 128 OF CHAR;
  lineState : ARRAY MAXLINES OF INTEGER;
  killBuf   : ARRAY LLEN OF CHAR;
  shellCmd  : ARRAY 256 OF CHAR;

PROCEDURE LineLen(li : INTEGER) : INTEGER;
VAR i : INTEGER;
BEGIN
  i := 0;
  WHILE (i < LLEN) & (buf[li][i] # 0X) DO  INC(i)  END;
  RETURN i
END LineLen;

PROCEDURE ClearLine(li : INTEGER);
BEGIN  buf[li][0] := 0X  END ClearLine;

PROCEDURE CopyLine(dst, src : INTEGER);
VAR i : INTEGER;
BEGIN
  FOR i := 0 TO LLEN - 1 DO  buf[dst][i] := buf[src][i]  END
END CopyLine;

PROCEDURE InsertCharAt(li, col : INTEGER; ch : CHAR);
VAR len, i : INTEGER;
BEGIN
  len := LineLen(li);
  IF (len >= LLEN - 1) OR (col > len) THEN  RETURN  END;
  i := len;
  WHILE i > col DO  buf[li][i] := buf[li][i-1];  DEC(i)  END;
  buf[li][col] := ch;
  buf[li][len+1] := 0X;
  modified := TRUE
END InsertCharAt;

PROCEDURE DeleteCharAt(li, col : INTEGER);
VAR len, i : INTEGER;
BEGIN
  len := LineLen(li);
  IF (col < 0) OR (col >= len) THEN  RETURN  END;
  i := col;
  WHILE i < len - 1 DO  buf[li][i] := buf[li][i+1];  INC(i)  END;
  buf[li][len-1] := 0X;
  modified := TRUE
END DeleteCharAt;

PROCEDURE InsertLineAt(pos : INTEGER);
VAR i : INTEGER;
BEGIN
  IF nlines >= MAXLINES THEN  RETURN  END;
  i := nlines;
  WHILE i > pos DO  CopyLine(i, i-1);  DEC(i)  END;
  ClearLine(pos);
  INC(nlines);
  modified := TRUE
END InsertLineAt;

PROCEDURE RemoveLine(pos : INTEGER);
VAR i : INTEGER;
BEGIN
  IF nlines <= 1 THEN  ClearLine(0);  modified := TRUE;  RETURN  END;
  i := pos;
  WHILE i < nlines - 1 DO  CopyLine(i, i+1);  INC(i)  END;
  DEC(nlines);
  modified := TRUE
END RemoveLine;

(* ── String helpers ─────────────────────────────────────────────────── *)

PROCEDURE StrToInt(s : ARRAY OF CHAR) : INTEGER;
VAR i, n : INTEGER;
BEGIN
  i := 0;  n := 0;
  WHILE (i < LEN(s)) & (s[i] >= '0') & (s[i] <= '9') DO
    n := n * 10 + (ORD(s[i]) - ORD('0'));  INC(i)
  END;
  RETURN n
END StrToInt;

PROCEDURE IntStr(n : INTEGER; VAR s : ARRAY OF CHAR);
VAR tmp : ARRAY 12 OF CHAR;  i, j : INTEGER;
BEGIN
  IF n <= 0 THEN  s[0] := '0';  s[1] := 0X;  RETURN  END;
  i := 0;
  WHILE n > 0 DO
    tmp[i] := CHR(n MOD 10 + ORD('0'));  INC(i);  n := n DIV 10
  END;
  FOR j := 0 TO i - 1 DO  s[j] := tmp[i - 1 - j]  END;
  s[i] := 0X
END IntStr;

(* ── List prefix detection ──────────────────────────────────────────── *)

(* Returns the continuation prefix for the list item at line li.
   Numbered lists are incremented.  Empty string = not a list line. *)
PROCEDURE GetListPrefix(li : INTEGER; VAR prefix : ARRAY OF CHAR);
VAR col, len, num : INTEGER;  c : CHAR;
    ns : ARRAY 12 OF CHAR;  pi, ni : INTEGER;
BEGIN
  prefix[0] := 0X;
  len := LineLen(li);
  IF len = 0 THEN  RETURN  END;
  c := buf[li][0];
  IF ((c = '-') OR (c = '*') OR (c = '+')) & (len >= 2) & (buf[li][1] = ' ') THEN
    (* task list: - [ ] or - [x] *)
    IF (c = '-') & (len >= 6) & (buf[li][2] = '[') &
       ((buf[li][3] = ' ') OR (buf[li][3] = 'x')) &
       (buf[li][4] = ']') & (buf[li][5] = ' ') THEN
      prefix[0] := '-';  prefix[1] := ' ';
      prefix[2] := '[';  prefix[3] := ' ';
      prefix[4] := ']';  prefix[5] := ' ';
      prefix[6] := 0X
    ELSE
      prefix[0] := c;  prefix[1] := ' ';  prefix[2] := 0X
    END;
    RETURN
  END;
  (* numbered list: digits + '. ' *)
  IF (c >= '1') & (c <= '9') THEN
    num := 0;  col := 0;
    WHILE (col < len) & (buf[li][col] >= '0') & (buf[li][col] <= '9') DO
      num := num * 10 + (ORD(buf[li][col]) - ORD('0'));  INC(col)
    END;
    IF (col + 1 < len) & (buf[li][col] = '.') & (buf[li][col+1] = ' ') THEN
      INC(num);
      IntStr(num, ns);
      pi := 0;  ni := 0;
      WHILE ns[ni] # 0X DO  prefix[pi] := ns[ni];  INC(pi);  INC(ni)  END;
      prefix[pi] := '.';   INC(pi);
      prefix[pi] := ' ';   INC(pi);
      prefix[pi] := 0X
    END
  END
END GetListPrefix;

(* ── Editing operations ─────────────────────────────────────────────── *)

PROCEDURE DoEnter;
VAR len, rest, i : INTEGER;
    prefix : ARRAY 32 OF CHAR;
    plen   : INTEGER;
BEGIN
  IF nlines >= MAXLINES THEN
    COPY("Buffer full!", statusMsg);  RETURN
  END;
  len  := LineLen(cy);
  rest := len - cx;
  (* pressing Enter at end of an empty list item exits the list *)
  IF rest = 0 THEN
    GetListPrefix(cy, prefix);
    plen := Strings.Length(prefix);
    IF (plen > 0) & (len = plen) THEN
      ClearLine(cy);  modified := TRUE;  cx := 0;
      RETURN
    END
  END;
  InsertLineAt(cy + 1);
  FOR i := 0 TO rest - 1 DO  buf[cy+1][i] := buf[cy][cx+i]  END;
  buf[cy+1][rest] := 0X;
  buf[cy][cx]     := 0X;
  INC(cy);  cx := 0;
  (* auto-continue list prefix when Enter at end of line *)
  IF rest = 0 THEN
    GetListPrefix(cy - 1, prefix);
    plen := Strings.Length(prefix);
    IF plen > 0 THEN
      FOR i := plen - 1 TO 0 BY -1 DO
        InsertCharAt(cy, 0, prefix[i])
      END;
      cx := plen
    END
  END
END DoEnter;

PROCEDURE DoBackspace;
VAR len1, len2, i : INTEGER;
BEGIN
  IF cx > 0 THEN
    DeleteCharAt(cy, cx - 1);  DEC(cx)
  ELSIF cy > 0 THEN
    len1 := LineLen(cy - 1);  len2 := LineLen(cy);
    IF len1 + len2 < LLEN THEN
      FOR i := 0 TO len2 - 1 DO  buf[cy-1][len1+i] := buf[cy][i]  END;
      buf[cy-1][len1+len2] := 0X;
      RemoveLine(cy);
      DEC(cy);  cx := len1
    ELSE
      COPY("Line too long to merge!", statusMsg)
    END
  END
END DoBackspace;

PROCEDURE DoDelete;
VAR len1, len2, i : INTEGER;
BEGIN
  len1 := LineLen(cy);
  IF cx < len1 THEN
    DeleteCharAt(cy, cx)
  ELSIF cy < nlines - 1 THEN
    len2 := LineLen(cy + 1);
    IF len1 + len2 < LLEN THEN
      FOR i := 0 TO len2 - 1 DO  buf[cy][len1+i] := buf[cy+1][i]  END;
      buf[cy][len1+len2] := 0X;
      RemoveLine(cy + 1)
    ELSE
      COPY("Line too long to merge!", statusMsg)
    END
  END
END DoDelete;

PROCEDURE DoKillLine;
VAR len, i : INTEGER;
BEGIN
  len := LineLen(cy);
  IF cx < len THEN
    i := 0;
    WHILE cx + i < len DO  killBuf[i] := buf[cy][cx+i];  INC(i)  END;
    killBuf[i] := 0X;
    buf[cy][cx] := 0X;
    modified := TRUE
  ELSIF cy < nlines - 1 THEN
    killBuf[0] := 0X;
    DoDelete
  END
END DoKillLine;

PROCEDURE DoYank;
VAR klen, i : INTEGER;
BEGIN
  klen := Strings.Length(killBuf);
  IF klen = 0 THEN  RETURN  END;
  FOR i := klen - 1 TO 0 BY -1 DO
    InsertCharAt(cy, cx, killBuf[i])
  END;
  INC(cx, klen)
END DoYank;

(* ── Cursor ─────────────────────────────────────────────────────────── *)

PROCEDURE ClampCursor;
VAR len : INTEGER;
BEGIN
  IF cy < 0       THEN  cy := 0       ELSIF cy >= nlines  THEN  cy := nlines - 1  END;
  len := LineLen(cy);
  IF cx < 0       THEN  cx := 0       ELSIF cx > len      THEN  cx := len          END
END ClampCursor;

PROCEDURE ScrollToCursor;
BEGIN
  IF cy < topLine            THEN  topLine := cy               END;
  IF cy >= topLine + EROWS   THEN  topLine := cy - EROWS + 1   END;
  IF cx < leftCol            THEN  leftCol := cx               END;
  IF cx >= leftCol + COLS    THEN  leftCol := cx - COLS + 1    END
END ScrollToCursor;

PROCEDURE WordLeft;
BEGIN
  IF cx > 0 THEN  DEC(cx)  END;
  WHILE (cx > 0) & (buf[cy][cx] = ' ') DO  DEC(cx)  END;
  WHILE (cx > 0) & (buf[cy][cx-1] # ' ') DO  DEC(cx)  END
END WordLeft;

PROCEDURE WordRight;
VAR len : INTEGER;
BEGIN
  len := LineLen(cy);
  WHILE (cx < len) & (buf[cy][cx] # ' ') DO  INC(cx)  END;
  WHILE (cx < len) & (buf[cy][cx] = ' ')  DO  INC(cx)  END
END WordRight;

(* ── File I/O ───────────────────────────────────────────────────────── *)

PROCEDURE LoadFile(name : ARRAY OF CHAR) : BOOLEAN;
VAR f : Files.File;  r : Files.Rider;
    b : BYTE;  bi, li, col : INTEGER;
BEGIN
  f := Files.Old(name);
  IF f = NIL THEN  RETURN FALSE  END;
  li := 0;  col := 0;
  ClearLine(0);
  Files.Set(r, f, 0);
  Files.Read(r, b);
  WHILE ~r.eof DO
    bi := b;
    IF bi = 10 THEN
      buf[li][col] := 0X;
      INC(li);
      IF li >= MAXLINES THEN
        li := MAXLINES - 1;
        WHILE ~r.eof DO  Files.Read(r, b)  END
      ELSE
        col := 0;  ClearLine(li)
      END
    ELSIF bi # 13 THEN
      IF col < LLEN - 1 THEN
        IF bi = 9 THEN
          FOR bi := 1 TO 4 DO
            IF col < LLEN - 1 THEN  buf[li][col] := ' ';  INC(col)  END
          END
        ELSE
          buf[li][col] := CHR(bi);  INC(col)
        END
      END
    END;
    Files.Read(r, b)
  END;
  buf[li][col] := 0X;
  nlines := li + 1;
  Files.Close(f);
  RETURN TRUE
END LoadFile;

PROCEDURE SaveFile() : BOOLEAN;
VAR f : Files.File;  r : Files.Rider;
    b : BYTE;  li, col, len : INTEGER;
BEGIN
  IF filename[0] = 0X THEN  RETURN FALSE  END;
  f := Files.New(filename);
  IF f = NIL THEN  RETURN FALSE  END;
  Files.Set(r, f, 0);
  FOR li := 0 TO nlines - 1 DO
    len := LineLen(li);
    FOR col := 0 TO len - 1 DO
      b := ORD(buf[li][col]);
      Files.Write(r, b)
    END;
    b := 10;  Files.Write(r, b)
  END;
  Files.Register(f);
  Files.Close(f);
  modified := FALSE;
  RETURN TRUE
END SaveFile;

(* ── Markdown state ─────────────────────────────────────────────────── *)

PROCEDURE IsFence(li : INTEGER) : BOOLEAN;
VAR len : INTEGER;
BEGIN
  len := LineLen(li);
  RETURN (len >= 3) &
         (((buf[li][0] = '`') & (buf[li][1] = '`') & (buf[li][2] = '`')) OR
          ((buf[li][0] = '~') & (buf[li][1] = '~') & (buf[li][2] = '~')))
END IsFence;

PROCEDURE ComputeLineStates;
VAR li, st : INTEGER;
BEGIN
  st := 0;
  FOR li := 0 TO nlines - 1 DO
    lineState[li] := st;
    IF IsFence(li) THEN
      IF st = 0 THEN  st := 1  ELSE  st := 0  END
    END
  END;
  lineState[nlines] := st
END ComputeLineStates;

PROCEDURE IsHR(li : INTEGER) : BOOLEAN;
VAR len, i : INTEGER;  ch : CHAR;  ok : BOOLEAN;
BEGIN
  len := LineLen(li);
  IF len < 3 THEN  RETURN FALSE  END;
  ch := buf[li][0];
  IF (ch # '-') & (ch # '*') & (ch # '_') THEN  RETURN FALSE  END;
  ok := TRUE;  i := 0;
  WHILE ok & (i < len) DO
    IF buf[li][i] # ch THEN  ok := FALSE  END;
    INC(i)
  END;
  RETURN ok
END IsHR;

(* ── Find ───────────────────────────────────────────────────────────── *)

PROCEDURE DoFind;
VAR li, col, i, qlen, count : INTEGER;
    found : BOOLEAN;
BEGIN
  qlen := Strings.Length(searchQuery);
  IF qlen = 0 THEN  RETURN  END;
  li := cy;  col := cx + 1;
  found := FALSE;  count := 0;
  LOOP
    IF col + qlen > LineLen(li) THEN
      INC(li);  col := 0;
      IF li >= nlines THEN  li := 0;  INC(count)  END;
      IF count > 1 THEN  EXIT  END
    ELSE
      i := 0;
      WHILE (i < qlen) & (buf[li][col + i] = searchQuery[i]) DO  INC(i)  END;
      IF i = qlen THEN
        cy := li;  cx := col;  found := TRUE;  EXIT
      ELSE
        INC(col)
      END
    END
  END;
  IF ~found THEN  COPY("Not found.", statusMsg)  END
END DoFind;

(* ── Prompt ─────────────────────────────────────────────────────────── *)

PROCEDURE Prompt(prompt : ARRAY OF CHAR; VAR result : ARRAY OF CHAR) : BOOLEAN;
VAR i, j, plen : INTEGER;
BEGIN
  result[0] := 0X;  i := 0;
  plen := Strings.Length(prompt);
  LOOP
    Terminal.Goto(1, 1);
    Graphics.Color256(226, 4);
    FOR j := 1 TO COLS DO  Out.Char(' ')  END;
    Terminal.Goto(1, 1);
    Out.String(prompt);  Out.String(result);
    Graphics.Reset;
    Terminal.Goto(plen + i + 1, 1);
    j := Terminal.ReadKey();
    IF j = KEY_ENTER THEN  RETURN i > 0
    ELSIF j = KEY_ESC THEN  result[0] := 0X;  RETURN FALSE
    ELSIF j = KEY_BS  OR ORD(j) = 127 THEN  IF i > 0 THEN  DEC(i);  result[i] := 0X  END
    ELSIF (j >= 32) & (j < 127) & (i < LEN(result) - 1) THEN
      result[i] := CHR(j);  INC(i);  result[i] := 0X
    END
  END
END Prompt;

PROCEDURE GotoLine;
VAR s : ARRAY 16 OF CHAR;  n : INTEGER;
BEGIN
  IF Prompt("Go to line: ", s) THEN
    n := StrToInt(s);
    IF n < 1 THEN  n := 1  END;
    IF n > nlines THEN  n := nlines  END;
    cy := n - 1;  cx := 0;  ClampCursor
  END
END GotoLine;

(* ── Word count ─────────────────────────────────────────────────────── *)

PROCEDURE WordCount() : INTEGER;
VAR li, col, cnt : INTEGER;  inWord : BOOLEAN;  c : CHAR;
BEGIN
  cnt := 0;  inWord := FALSE;
  FOR li := 0 TO nlines - 1 DO
    col := 0;
    WHILE buf[li][col] # 0X DO
      c := buf[li][col];
      IF (c # ' ') & (ORD(c) # 9) THEN
        IF ~inWord THEN  INC(cnt);  inWord := TRUE  END
      ELSE
        inWord := FALSE
      END;
      INC(col)
    END;
    inWord := FALSE
  END;
  RETURN cnt
END WordCount;

(* ── Rendering ──────────────────────────────────────────────────────── *)

PROCEDURE RenderLine(li, leftCol, cols, carryIn : INTEGER);
VAR
  col, sc, len          : INTEGER;
  c                     : CHAR;
  headLevel             : INTEGER;
  isHR, isQuote         : BOOLEAN;
  isFenceLine           : BOOLEAN;
  listPfxLen            : INTEGER;
  isTaskChecked         : BOOLEAN;
  nBoldIta, nBold, nItalic, nStrike : INTEGER;
  inCode, inBold, inItalic, inBoldIta, inStrike : BOOLEAN;
  inLink, inUrl         : BOOLEAN;

  PROCEDURE ApplyState;
  BEGIN
    IF inCode THEN
      Graphics.Color256(CLR_CODE, BG_CODE)
    ELSIF carryIn = 1 THEN
      Graphics.Color256(CLR_FENCE, BG_FENCE)
    ELSIF inBoldIta THEN
      Graphics.Color256(CLR_BOLDITA, BG_NORMAL)
    ELSIF inBold THEN
      Graphics.Color256(CLR_BOLD, BG_NORMAL)
    ELSIF inItalic THEN
      Graphics.Color256(CLR_ITALIC, BG_NORMAL)
    ELSIF inStrike THEN
      Graphics.Color256(CLR_STRIKE, BG_NORMAL)
    ELSIF isTaskChecked THEN
      Graphics.Color256(CLR_TASKDONE, BG_NORMAL)
    ELSIF headLevel = 1 THEN
      Graphics.Color256(CLR_H1, BG_NORMAL)
    ELSIF headLevel = 2 THEN
      Graphics.Color256(CLR_H2, BG_NORMAL)
    ELSIF headLevel >= 3 THEN
      Graphics.Color256(CLR_H3, BG_NORMAL)
    ELSIF isHR THEN
      Graphics.Color256(CLR_HR, BG_NORMAL)
    ELSIF isQuote THEN
      Graphics.Color256(CLR_QUOTE, BG_NORMAL)
    ELSIF inLink OR inUrl THEN
      Graphics.Color256(CLR_LINK, BG_NORMAL)
    ELSE
      Graphics.Color256(CLR_NORMAL, BG_NORMAL)
    END
  END ApplyState;

  PROCEDURE Marker;
  BEGIN  Graphics.Color256(CLR_MARKER, BG_NORMAL)  END Marker;

  PROCEDURE At(pos : INTEGER; ch : CHAR) : BOOLEAN;
  BEGIN  RETURN (pos < len) & (buf[li][pos] = ch)  END At;

  PROCEDURE EmitChar(ch : CHAR);
  BEGIN
    IF ORD(ch) < 32 THEN  Out.Char(' ')  ELSE  Out.Char(ch)  END
  END EmitChar;

BEGIN
  len         := LineLen(li);
  isFenceLine := IsFence(li);

  (* heading level: count leading '#' chars *)
  headLevel := 0;
  IF (carryIn = 0) & ~isFenceLine & (len > 0) & (buf[li][0] = '#') THEN
    headLevel := 1;
    WHILE (headLevel < len) & (buf[li][headLevel] = '#') DO  INC(headLevel)  END;
    IF (headLevel >= len) OR (buf[li][headLevel] # ' ') THEN  headLevel := 0  END
  END;

  isHR    := (carryIn = 0) & ~isFenceLine & (headLevel = 0) & IsHR(li);
  isQuote := (carryIn = 0) & ~isFenceLine & (len > 0) & (buf[li][0] = '>');

  (* list prefix length *)
  listPfxLen    := 0;
  isTaskChecked := FALSE;
  IF (carryIn = 0) & ~isFenceLine & ~isQuote & (headLevel = 0) & ~isHR THEN
    c := buf[li][0];
    IF ((c = '-') OR (c = '*') OR (c = '+')) & (len >= 2) & (buf[li][1] = ' ') THEN
      IF (c = '-') & (len >= 6) & (buf[li][2] = '[') &
         ((buf[li][3] = ' ') OR (buf[li][3] = 'x')) &
         (buf[li][4] = ']') & (buf[li][5] = ' ') THEN
        listPfxLen    := 6;
        isTaskChecked := (buf[li][3] = 'x')
      ELSE
        listPfxLen := 2
      END
    ELSIF (c >= '1') & (c <= '9') THEN
      col := 0;
      WHILE (col < len) & (buf[li][col] >= '0') & (buf[li][col] <= '9') DO  INC(col)  END;
      IF (col + 1 < len) & (buf[li][col] = '.') & (buf[li][col+1] = ' ') THEN
        listPfxLen := col + 2
      END
    END
  END;

  (* count inline marker pairs (odd count = unmatched = render literally) *)
  nBoldIta := 0;  nBold := 0;  nItalic := 0;  nStrike := 0;
  IF (carryIn = 0) & ~isFenceLine THEN
    col := 0;
    WHILE col <= len - 3 DO
      IF At(col,'*') & At(col+1,'*') & At(col+2,'*') THEN
        INC(nBoldIta);  col := col + 3
      ELSE  INC(col)
      END
    END;
    col := 0;
    WHILE col <= len - 2 DO
      IF At(col,'*') & At(col+1,'*') THEN
        IF ~(At(col+2,'*') OR ((col > 0) & (buf[li][col-1] = '*'))) THEN
          INC(nBold)
        END;
        col := col + 2
      ELSE  INC(col)
      END
    END;
    col := 0;
    WHILE col < len DO
      IF At(col,'*') THEN
        IF ~At(col+1,'*') & ~((col > 0) & (buf[li][col-1] = '*')) THEN
          INC(nItalic)
        END
      END;
      INC(col)
    END;
    col := 0;
    WHILE col <= len - 2 DO
      IF At(col,'~') & At(col+1,'~') THEN
        (* skip ``` fences already handled; ~~ only when not triple *)
        IF ~At(col+2,'~') THEN  INC(nStrike)  END;
        col := col + 2
      ELSE  INC(col)
      END
    END
  END;

  inCode    := FALSE;  inBold    := FALSE;
  inItalic  := FALSE;  inBoldIta := FALSE;
  inStrike  := FALSE;
  inLink    := FALSE;  inUrl     := FALSE;

  IF isFenceLine THEN
    Marker;
    sc := 0;  col := leftCol;
    WHILE sc < cols DO
      IF col < len THEN  Out.Char(buf[li][col])  ELSE  Out.Char(' ')  END;
      INC(col);  INC(sc)
    END;
    RETURN
  END;

  ApplyState;
  sc := 0;  col := leftCol;

  WHILE sc < cols DO
    IF col >= len THEN
      Out.Char(' ');  INC(col);  INC(sc)
    ELSE
      c := buf[li][col];

      IF carryIn = 1 THEN
        EmitChar(c);  INC(col);  INC(sc)

      ELSIF col < listPfxLen THEN
        Graphics.Color256(CLR_LIST, BG_NORMAL);
        Out.Char(c);
        IF col = listPfxLen - 1 THEN  ApplyState  END;
        INC(col);  INC(sc)

      ELSIF c = '`' THEN
        Marker;  Out.Char(c);
        inCode := ~inCode;
        ApplyState;
        INC(col);  INC(sc)

      ELSIF inCode THEN
        EmitChar(c);  INC(col);  INC(sc)

      ELSIF At(col,'~') & At(col+1,'~') & ~At(col+2,'~') THEN
        IF ODD(nStrike) THEN
          Out.Char(c);  INC(col);  INC(sc)
        ELSE
          Marker;
          Out.Char('~');  INC(sc);
          IF sc < cols THEN  Out.Char('~')  END;
          INC(col, 2);  INC(sc);
          inStrike := ~inStrike;
          ApplyState
        END

      ELSIF At(col,'*') & At(col+1,'*') & At(col+2,'*') THEN
        IF ODD(nBoldIta) THEN
          Out.Char(c);  INC(col);  INC(sc)
        ELSE
          Marker;
          Out.Char('*');                         INC(sc);
          IF sc < cols THEN  Out.Char('*');  INC(sc)  END;
          IF sc < cols THEN  Out.Char('*')         END;
          INC(col, 3);  INC(sc);
          inBoldIta := ~inBoldIta;
          ApplyState
        END

      ELSIF At(col,'*') & At(col+1,'*') THEN
        IF ODD(nBold) THEN
          Out.Char(c);  INC(col);  INC(sc)
        ELSE
          Marker;
          Out.Char('*');                         INC(sc);
          IF sc < cols THEN  Out.Char('*')         END;
          INC(col, 2);  INC(sc);
          inBold := ~inBold;
          ApplyState
        END

      ELSIF c = '*' THEN
        IF ODD(nItalic) THEN
          Out.Char(c);  INC(col);  INC(sc)
        ELSE
          Marker;  Out.Char(c);
          INC(col);  INC(sc);
          inItalic := ~inItalic;
          ApplyState
        END

      ELSIF c = '[' THEN
        Marker;  Out.Char(c);
        inLink := TRUE;
        Graphics.Color256(CLR_LINK, BG_NORMAL);
        INC(col);  INC(sc)

      ELSIF (c = ']') & inLink THEN
        inLink := FALSE;
        Marker;  Out.Char(c);
        INC(col);  INC(sc);
        IF At(col,'(') THEN
          IF sc < cols THEN
            Marker;  Out.Char('(');  INC(sc)
          END;
          INC(col);
          inUrl := TRUE;
          ApplyState
        ELSE
          ApplyState
        END

      ELSIF (c = ')') & inUrl THEN
        inUrl := FALSE;
        Marker;  Out.Char(c);
        INC(col);  INC(sc);
        ApplyState

      ELSE
        EmitChar(c);  INC(col);  INC(sc)
      END
    END
  END
END RenderLine;

(* ── Screen ─────────────────────────────────────────────────────────── *)

PROCEDURE Render;
VAR row, li, col, wc : INTEGER;
BEGIN
  ComputeLineStates;

  FOR row := 0 TO EROWS - 1 DO
    li := topLine + row;
    Terminal.Goto(1, row + 1);
    IF li < nlines THEN
      RenderLine(li, leftCol, COLS, lineState[li])
    ELSE
      Graphics.Color256(240, 0);
      Out.Char('~');
      Graphics.Color256(0, 0);
      FOR col := 1 TO COLS - 1 DO  Out.Char(' ')  END
    END
  END;

  (* status bar *)
  Terminal.Goto(1, ROWS);
  Graphics.Color256(15, 239);
  FOR col := 1 TO COLS DO  Out.Char(' ')  END;
  Terminal.Goto(1, ROWS);
  IF filename[0] = 0X THEN  Out.String(" [No Name]")
  ELSE  Out.Char(' ');  Out.String(filename)
  END;
  IF modified THEN  Out.String(" [+]")  END;
  IF statusMsg[0] # 0X THEN
    Out.String("  ");  Out.String(statusMsg)
  ELSE
    wc := WordCount();
    Out.String("  Ln:");  Out.Int(cy + 1, 1);
    Out.String(" Col:");  Out.Int(cx + 1, 1);
    Out.String("  Words:");  Out.Int(wc, 1)
  END;
  Terminal.Goto(COLS - 42, ROWS);
  Out.String("^O ^S ^Q ^F ^K ^Y ^G ^R Shell");

  Graphics.Reset;
  Terminal.Goto(cx - leftCol + 1, cy - topLine + 1)
END Render;

BEGIN
  COLS  := Terminal.Cols();
  ROWS  := Terminal.Rows();
  EROWS := ROWS - 1;
  Terminal.Clear;
  Terminal.MouseOn();
  Terminal.ShowCursor;
  nlines := 1;  ClearLine(0);
  cx := 0;  cy := 0;  topLine := 0;  leftCol := 0;
  filename[0] := 0X;  statusMsg[0] := 0X;  killBuf[0] := 0X;  shellCmd[0] := 0X;
  modified := FALSE;  running := TRUE;  searchQuery[0] := 0X;

  IF Args.Count() > 0 THEN
    Args.Get(1, filename);
    IF ~LoadFile(filename) THEN  COPY("New file.", statusMsg)  END
  END;

  WHILE running DO
    ScrollToCursor;
    Render;
    statusMsg[0] := 0X;
    k := Terminal.ReadKey();

    IF    k = KEY_UP    THEN  DEC(cy);  ClampCursor
    ELSIF k = KEY_DOWN  THEN  INC(cy);  ClampCursor
    ELSIF k = KEY_LEFT  THEN
      IF cx > 0 THEN  DEC(cx)
      ELSIF cy > 0 THEN  DEC(cy);  cx := LineLen(cy)
      END
    ELSIF k = KEY_RIGHT THEN
      IF cx < LineLen(cy) THEN  INC(cx)
      ELSIF cy < nlines - 1  THEN  INC(cy);  cx := 0
      END
    ELSIF k = KEY_HOME  THEN  cy := 0;  cx := 0
    ELSIF k = KEY_END   THEN  cy := nlines - 1;  cx := LineLen(cy)
    ELSIF k = KEY_FHOME THEN  cx := 0
    ELSIF k = KEY_FEND  THEN  cx := LineLen(cy)
    ELSIF k = KEY_WLEFT THEN  WordLeft
    ELSIF k = KEY_WRIGHT THEN  WordRight
    ELSIF k = KEY_PGUP  THEN  DEC(cy, EROWS);  ClampCursor
    ELSIF k = KEY_PGDN  THEN  INC(cy, EROWS);  ClampCursor
    ELSIF k = KEY_MOUSE THEN
      btn := Terminal.MouseBtn();
      IF btn = 0 OR btn = 3 THEN
        mx := Terminal.MouseX();  my := Terminal.MouseY();
        IF (my >= 2) & (my <= EROWS + 1) THEN
          cy := topLine + my - 2;  cx := leftCol + mx - 1;  ClampCursor
        END;
      END
    ELSIF k = KEY_ENTER THEN  DoEnter
    ELSIF k = KEY_BS OR ORD(k) = 127 THEN  DoBackspace
    ELSIF k = KEY_DEL   THEN  DoDelete
    ELSIF k = KEY_TAB   THEN
      FOR mx := 1 TO 4 DO  InsertCharAt(cy, cx, ' ');  INC(cx)  END
    ELSIF k = KEY_CTRL_K THEN  DoKillLine
    ELSIF k = KEY_CTRL_Y THEN  DoYank
    ELSIF k = KEY_CTRL_R THEN
      IF Prompt("Shell: ", shellCmd) THEN  Terminal.Shell(shellCmd)  END
    ELSIF k = KEY_CTRL_G THEN  GotoLine
    ELSIF k = KEY_CTRL_F THEN
      IF Prompt("Find: ", searchQuery) THEN  DoFind  END
    ELSIF k = KEY_CTRL_S THEN
      IF (filename[0] = 0X) & Prompt("Save as: ", tmpname) THEN  COPY(tmpname, filename)  END;
      IF (filename[0] # 0X) & SaveFile() THEN  COPY("Saved.", statusMsg)  END
    ELSIF k = KEY_CTRL_O THEN
      IF Prompt("Open: ", tmpname) THEN
        COPY(tmpname, filename);
        IF LoadFile(filename) THEN
          cx := 0;  cy := 0;  modified := FALSE;  COPY("Loaded.", statusMsg)
        END
      END
    ELSIF k = KEY_CTRL_Q THEN  running := FALSE
    ELSIF (k >= 32) & (k <= 126) THEN
      InsertCharAt(cy, cx, CHR(k));  INC(cx)
    END
  END;

  Terminal.MouseOff();
  Terminal.Clear;
  Terminal.Goto(1, 1)
END Edit.



