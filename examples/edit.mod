MODULE Edit;

IMPORT Terminal, Graphics, Out, Files, Args, Strings;

CONST
  MAXLINES = 2000;
  LLEN     = 256;

  (* Key codes *)
  KEY_UP     = 1;    KEY_DOWN  = 2;
  KEY_LEFT   = 3;    KEY_RIGHT = 4;
  KEY_MOUSE  = 5;
  KEY_BS     = 8;    KEY_TAB   = 9;
  KEY_ENTER  = 13;   KEY_ESC   = 27;
  KEY_CTRL_F = 6;
  KEY_CTRL_O = 15;
  KEY_CTRL_Q = 17;
  KEY_CTRL_W = 23;
  KEY_HOME   = 256;  KEY_END   = 257;
  KEY_PGUP   = 258;  KEY_PGDN  = 259;
  KEY_DEL    = 260;

VAR
  ROWS, EROWS, COLS : INTEGER;
  buf      : ARRAY MAXLINES, LLEN OF CHAR;
  nlines   : INTEGER;
  cx, cy   : INTEGER;   (* 0-based *)
  topLine  : INTEGER;
  leftCol  : INTEGER;
  filename : ARRAY 256 OF CHAR;
  tmpname  : ARRAY 256 OF CHAR;
  statusMsg: ARRAY 60  OF CHAR;
  modified    : BOOLEAN;
  running     : BOOLEAN;
  k, mx, my  : INTEGER;
  searchQuery : ARRAY 128 OF CHAR;

(*  Key input  *)

PROCEDURE GetKey() : INTEGER;
VAR c : CHAR;
BEGIN
  c := Terminal.ReadKey();
  IF    ORD(c) =  1 THEN  RETURN KEY_UP
  ELSIF ORD(c) =  2 THEN  RETURN KEY_DOWN
  ELSIF ORD(c) =  3 THEN  RETURN KEY_LEFT
  ELSIF ORD(c) =  4 THEN  RETURN KEY_RIGHT
  ELSIF ORD(c) =  5 THEN  RETURN KEY_MOUSE
  ELSIF ORD(c) = 128 THEN  RETURN KEY_PGUP
  ELSIF ORD(c) = 129 THEN  RETURN KEY_PGDN
  ELSIF ORD(c) = 130 THEN  RETURN KEY_HOME
  ELSIF ORD(c) = 131 THEN  RETURN KEY_END
  ELSIF ORD(c) = 132 THEN  RETURN KEY_DEL
  ELSIF ORD(c) = 127 THEN RETURN KEY_BS
  ELSE  RETURN ORD(c)
  END
END GetKey;

(*  Buffer helpers  *)

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

(*  Edit actions  *)

PROCEDURE DoEnter;
VAR len, rest, i : INTEGER;
BEGIN
  IF nlines >= MAXLINES THEN 
    COPY("Buffer full!", statusMsg); RETURN 
  END;
  len  := LineLen(cy);
  rest := len - cx;
  InsertLineAt(cy + 1);
  FOR i := 0 TO rest-1 DO  buf[cy+1][i] := buf[cy][cx+i]  END;
  buf[cy+1][rest] := 0X;
  buf[cy][cx]     := 0X;
  INC(cy);  cx := 0
END DoEnter;

PROCEDURE DoBackspace;
VAR len1, len2, i : INTEGER;
BEGIN
  IF cx > 0 THEN
    DeleteCharAt(cy, cx-1);  DEC(cx)
  ELSIF cy > 0 THEN
    len1 := LineLen(cy-1);  len2 := LineLen(cy);
    IF len1 + len2 < LLEN THEN
      FOR i := 0 TO len2-1 DO  buf[cy-1][len1+i] := buf[cy][i]  END;
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
  ELSIF cy < nlines-1 THEN
    len2 := LineLen(cy+1);
    IF len1 + len2 < LLEN THEN
      FOR i := 0 TO len2-1 DO  buf[cy][len1+i] := buf[cy+1][i]  END;
      buf[cy][len1+len2] := 0X;
      RemoveLine(cy+1)
    ELSE
      COPY("Line too long to merge!", statusMsg)
    END
  END
END DoDelete;

(*  Cursor / scroll  *)

PROCEDURE ClampCursor;
VAR len : INTEGER;
BEGIN
  IF cy < 0  THEN  cy := 0  ELSIF cy >= nlines  THEN  cy := nlines - 1  END;
  len := LineLen(cy);
  IF cx < 0  THEN  cx := 0  ELSIF cx > len  THEN  cx := len  END
END ClampCursor;

PROCEDURE ScrollToCursor;
BEGIN
  IF cy < topLine           THEN  topLine := cy  END;
  IF cy >= topLine + EROWS    THEN  topLine := cy - EROWS + 1  END;
  IF cx < leftCol           THEN  leftCol := cx  END;
  IF cx >= leftCol + COLS     THEN  leftCol := cx - COLS + 1  END
END ScrollToCursor;

(*  File I/O  *)

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
    IF bi = 10 THEN           (* LF *)
      buf[li][col] := 0X;
      INC(li);
      IF li >= MAXLINES THEN  li := MAXLINES - 1;  WHILE ~r.eof DO Files.Read(r, b) END;  (* Truncate *)
      ELSE  col := 0; ClearLine(li)
      END
    ELSIF bi # 13 THEN        (* Ignore CR *)
      IF col < LLEN - 1 THEN
        IF bi = 9 THEN        (* Handle TAB during load *)
          FOR bi := 1 TO 4 DO 
            IF col < LLEN - 1 THEN buf[li][col] := ' '; INC(col) END 
          END
        ELSE
          buf[li][col] := CHR(bi); INC(col)
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
  FOR li := 0 TO nlines-1 DO
    len := LineLen(li);
    FOR col := 0 TO len-1 DO
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
    j := GetKey();
    IF j = KEY_ENTER THEN  RETURN i > 0
    ELSIF j = KEY_ESC THEN  result[0] := 0X;  RETURN FALSE
    ELSIF j = KEY_BS  THEN  IF i > 0 THEN  DEC(i);  result[i] := 0X  END
    ELSIF (j >= 32) & (j < 127) & (i < LEN(result) - 1) THEN
      result[i] := CHR(j);  INC(i);  result[i] := 0X
    END
  END
END Prompt;

(*  Rendering  *)

PROCEDURE Render;
VAR row, li, col, sc, len : INTEGER;
    c : CHAR;
BEGIN
  FOR row := 0 TO EROWS-1 DO
    li := topLine + row;
    Terminal.Goto(1, row + 2);
    IF li < nlines THEN
      Graphics.Color256(255, 0);
      sc  := 0; col := leftCol;
      len := LineLen(li);
      WHILE sc < COLS DO
        IF col < len THEN
          c := buf[li][col];
          IF ORD(c) < 32 THEN  Out.Char(' ')  ELSE  Out.Char(c)  END
        ELSE  Out.Char(' ')
        END;
        INC(col);  INC(sc)
      END
    ELSE
      Graphics.Color256(240, 0);
      Out.Char('~');
      Graphics.Color256(0, 0);
      FOR col := 1 TO COLS-1 DO  Out.Char(' ')  END
    END
  END;

  Terminal.Goto(1, 1);
  Graphics.Color256(15, 4);
  FOR col := 1 TO COLS DO  Out.Char(' ')  END;
  Terminal.Goto(1, 1);
  IF filename[0] = 0X THEN Out.String("  [No Name]") ELSE Out.String("  "); Out.String(filename) END;
  IF modified THEN  Out.String(" [+]")  END;
  IF statusMsg[0] # 0X THEN Out.String("  |  "); Out.String(statusMsg) END;
  
  Terminal.Goto(COLS - 17, 1);
  Out.String("Ln:"); Out.Int(cy+1, 4);
  Out.String(" Col:"); Out.Int(cx+1, 3);

  Terminal.Goto(1, ROWS);
  Graphics.Color256(15, 239);
  FOR col := 1 TO COLS DO  Out.Char(' ')  END;
  Terminal.Goto(1, ROWS);
  Out.String(" ^O Open  ^W Save  ^Q Quit  ^F Find | Arrows/PgUp/PgDn/Home/End | Mouse");

  Graphics.Reset;
  Terminal.Goto(cx - leftCol + 1, cy - topLine + 2)
END Render;

(*  Main  *)

BEGIN
  COLS  := Terminal.Cols();
  ROWS  := Terminal.Rows();
  EROWS := ROWS - 2;
  Terminal.Clear;
  Terminal.MouseOn();
  Terminal.ShowCursor;
  nlines := 1; ClearLine(0);
  cx := 0; cy := 0; topLine := 0; leftCol := 0;
  filename[0] := 0X; statusMsg[0] := 0X;
  modified := FALSE; running := TRUE;  searchQuery[0] := 0X;

  IF Args.Count() > 0 THEN
    Args.Get(1, filename);
    IF ~LoadFile(filename) THEN COPY("New file.", statusMsg) END
  END;

  WHILE running DO
    ScrollToCursor;
    Render;
    statusMsg[0] := 0X;
    k := GetKey();

    IF    k = KEY_UP    THEN  DEC(cy);  ClampCursor
    ELSIF k = KEY_DOWN  THEN  INC(cy);  ClampCursor
    ELSIF k = KEY_LEFT  THEN
      IF cx > 0 THEN  DEC(cx)
      ELSIF cy > 0 THEN  DEC(cy);  cx := LineLen(cy)
      END
    ELSIF k = KEY_RIGHT THEN
      IF cx < LineLen(cy) THEN  INC(cx)
      ELSIF cy < nlines-1  THEN  INC(cy);  cx := 0
      END
    ELSIF k = KEY_HOME  THEN  cy := 0;  cx := 0
    ELSIF k = KEY_END   THEN  cy := nlines - 1;  cx := LineLen(cy)
    ELSIF k = KEY_PGUP  THEN  DEC(cy, EROWS); ClampCursor
    ELSIF k = KEY_PGDN  THEN  INC(cy, EROWS); ClampCursor
    ELSIF k = KEY_MOUSE THEN
      mx := Terminal.MouseX();  my := Terminal.MouseY();
      IF (my >= 2) & (my <= EROWS+1) THEN
        cy := topLine + my - 2; cx := leftCol + mx - 1; ClampCursor
      END
    ELSIF k = KEY_ENTER THEN  DoEnter
    ELSIF k = KEY_BS    THEN  DoBackspace
    ELSIF k = KEY_DEL   THEN  DoDelete
    ELSIF k = KEY_TAB   THEN
      FOR mx := 1 TO 4 DO InsertCharAt(cy, cx, ' '); INC(cx) END
    ELSIF k = KEY_CTRL_F THEN
      IF Prompt("Find: ", searchQuery) THEN  DoFind  END
    ELSIF k = KEY_CTRL_W THEN
      IF (filename[0] = 0X) & Prompt("Save as: ", tmpname) THEN COPY(tmpname, filename) END;
      IF (filename[0] # 0X) & SaveFile() THEN COPY("Saved.", statusMsg) END
    ELSIF k = KEY_CTRL_O THEN
      IF Prompt("Open: ", tmpname) THEN
        COPY(tmpname, filename);
        IF LoadFile(filename) THEN cx:=0; cy:=0; modified:=FALSE; COPY("Loaded.", statusMsg) END
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