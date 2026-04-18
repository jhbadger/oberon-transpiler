MODULE IDE;
(*
 * Oberon IDE — Phase 5
 * Multi-window source editor built on TUI / Widgets / FileDialog.
 *
 * Each open file lives in an EditorWin (POINTER TO EditorWinRec which
 * extends TUI.WindowRec).  Multiple EditorWins coexist on the desktop.
 *
 * UTF-8 notes
 * ────────────
 *   Lines are stored as raw UTF-8 byte sequences (ARRAY LLEN OF CHAR).
 *   Cursor movement skips continuation bytes so cx always lands on a
 *   code-point boundary.  TUI.InvalidateLine + the consecutive-cell
 *   Flush optimisation ensure multi-byte glyphs render correctly.
 *
 * Keyboard shortcuts
 * ──────────────────
 *   Ctrl+N          New editor window
 *   Ctrl+O          Open file
 *   Ctrl+S          Save
 *   Ctrl+W          Close window
 *   Ctrl+Q          Quit
 *   Ctrl+Tab / F6   Next window
 *   F5              Compile current file
 *   F9              Compile & run
 *   Ctrl+F / F3     Find / find next
 *   Ctrl+G          Go to line
 *   Ctrl+K / Ctrl+Y Kill line / yank
 *   Ctrl+Left/Right Word left / right
 *)
IMPORT TUI, Widgets, FileDialog, Strings, Files, OS, Out, Args;

CONST
  MaxLines = 2000;
  LLEN     = 512;    (* bytes per line — wide enough for UTF-8 *)
  MaxWins  = 8;
  MaxUndo  = 100;    (* undo history depth per editor window *)

  (* ── Undo operation types ── *)
  UOpEdit  = 1;   (* one line modified in place *)
  UOpSplit = 2;   (* line split into two by Enter *)
  UOpJoin  = 3;   (* two lines joined into one by Backspace/Delete at boundary *)

  (* ── Menu command codes ── *)
  CmdNew     = 10;   CmdOpen    = 11;   CmdSave    = 12;
  CmdSaveAs  = 13;   CmdClose   = 14;   CmdQuit    = 15;
  CmdUndo    = 19;
  CmdFind    = 20;   CmdFindNext= 21;   CmdGoto    = 22;
  CmdCompile = 30;   CmdRun     = 31;   CmdCompRun = 32;
  CmdNextWin = 40;   CmdTile    = 41;

TYPE
  UndoEntry = RECORD
    op:       INTEGER;          (* UOpEdit / UOpSplit / UOpJoin *)
    cy, cx:   INTEGER;          (* cursor position before the edit *)
    fromLine: INTEGER;          (* first affected line index *)
    line0:    ARRAY LLEN OF CHAR;  (* saved content of fromLine *)
    line1:    ARRAY LLEN OF CHAR   (* saved content of fromLine+1 (UOpJoin only) *)
  END;

  EditorWin  = POINTER TO EditorWinRec;
  EditorWinRec = RECORD (TUI.WindowRec)
    (* text buffer *)
    lines:    ARRAY MaxLines, LLEN OF CHAR;
    nlines:   INTEGER;
    (* cursor: byte offset in line, line index *)
    cx, cy:   INTEGER;
    topLine:  INTEGER;   (* first visible line              *)
    leftCol:  INTEGER;   (* byte offset of left edge        *)
    modified: BOOLEAN;
    killBuf:  ARRAY LLEN OF CHAR;
    srchBuf:  ARRAY 128  OF CHAR;
    (* comment nesting depth at start of each line (for syntax colour) *)
    cmtDepth: ARRAY MaxLines + 1 OF INTEGER;
    (* undo stack (circular buffer) *)
    undo:      ARRAY MaxUndo OF UndoEntry;
    undoTop:   INTEGER;   (* next write slot *)
    undoCount: INTEGER    (* number of valid entries *)
  END;

(* ════════════════════════════════════════════════════════════════
   Module globals
   ════════════════════════════════════════════════════════════════ *)

VAR
  mbar:      Widgets.MenuBar;
  sline:     Widgets.StatusLine;
  running:   BOOLEAN;
  statusMsg: ARRAY 128 OF CHAR;
  wins:      ARRAY MaxWins OF EditorWin;
  winCount:  INTEGER;
  lastEditor: EditorWin;       (* last editor that held focus — used when menu is active *)
  pendingCloseWin: EditorWin; (* editor awaiting close confirmation *)
  (* inline prompt state *)
  promptMode: INTEGER;   (* 0=none 1=find 2=goto 3=confirmClose 4=confirmQuit *)
  promptBuf:  ARRAY 128 OF CHAR;
  promptPos:  INTEGER;

(* ════════════════════════════════════════════════════════════════
   UTF-8 helpers
   ════════════════════════════════════════════════════════════════ *)

PROCEDURE IsUtf8Cont(ch: CHAR): BOOLEAN;
BEGIN  RETURN (ORD(ch) >= 080H) & (ORD(ch) < 0C0H)  END IsUtf8Cont;

(* Advance byte index past one UTF-8 character. *)
PROCEDURE Utf8Fwd(VAR line: ARRAY OF CHAR; VAR i: INTEGER);
BEGIN
  INC(i);
  WHILE (i < LLEN) & (line[i] # 0X) & IsUtf8Cont(line[i]) DO  INC(i)  END
END Utf8Fwd;

(* Retreat byte index to start of previous UTF-8 character. *)
PROCEDURE Utf8Back(VAR line: ARRAY OF CHAR; VAR i: INTEGER);
BEGIN
  DEC(i);
  WHILE (i > 0) & IsUtf8Cont(line[i]) DO  DEC(i)  END
END Utf8Back;

(* Count display columns for bytes 0..byteOff-1 (non-continuation = 1 col). *)
PROCEDURE ByteToCol(VAR line: ARRAY OF CHAR; byteOff: INTEGER): INTEGER;
VAR i, col: INTEGER;
BEGIN
  i := 0;  col := 0;
  WHILE i < byteOff DO
    IF ~IsUtf8Cont(line[i]) THEN  INC(col)  END;
    INC(i)
  END;
  RETURN col
END ByteToCol;

(* ════════════════════════════════════════════════════════════════
   Buffer helpers
   ════════════════════════════════════════════════════════════════ *)

PROCEDURE LineLen(ew: EditorWin; li: INTEGER): INTEGER;
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (i < LLEN) & (ew.lines[li][i] # 0X) DO  INC(i)  END;
  RETURN i
END LineLen;

PROCEDURE ClearLine(ew: EditorWin; li: INTEGER);
BEGIN  ew.lines[li][0] := 0X  END ClearLine;

PROCEDURE CopyLine(ew: EditorWin; dst, src: INTEGER);
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO LLEN - 1 DO  ew.lines[dst][i] := ew.lines[src][i]  END
END CopyLine;

PROCEDURE InsertBytesAt(ew: EditorWin; li, col: INTEGER; VAR bytes: ARRAY OF CHAR; n: INTEGER);
VAR len, i: INTEGER;
BEGIN
  len := LineLen(ew, li);
  IF (len + n >= LLEN) OR (col > len) THEN  RETURN  END;
  i := len + n - 1;
  WHILE i >= col + n DO  ew.lines[li][i] := ew.lines[li][i - n];  DEC(i)  END;
  FOR i := 0 TO n - 1 DO  ew.lines[li][col + i] := bytes[i]  END;
  ew.lines[li][len + n] := 0X;
  ew.modified := TRUE
END InsertBytesAt;

PROCEDURE DeleteBytesAt(ew: EditorWin; li, col, n: INTEGER);
VAR len, i: INTEGER;
BEGIN
  len := LineLen(ew, li);
  IF (col < 0) OR (col + n > len) THEN  RETURN  END;
  i := col;
  WHILE i + n < len DO  ew.lines[li][i] := ew.lines[li][i + n];  INC(i)  END;
  ew.lines[li][len - n] := 0X;
  ew.modified := TRUE
END DeleteBytesAt;

PROCEDURE InsertLineAt(ew: EditorWin; pos: INTEGER);
VAR i: INTEGER;
BEGIN
  IF ew.nlines >= MaxLines THEN  RETURN  END;
  i := ew.nlines;
  WHILE i > pos DO  CopyLine(ew, i, i - 1);  DEC(i)  END;
  ClearLine(ew, pos);
  INC(ew.nlines);
  ew.modified := TRUE
END InsertLineAt;

PROCEDURE RemoveLine(ew: EditorWin; pos: INTEGER);
VAR i: INTEGER;
BEGIN
  IF ew.nlines <= 1 THEN  ClearLine(ew, 0);  ew.modified := TRUE;  RETURN  END;
  i := pos;
  WHILE i < ew.nlines - 1 DO  CopyLine(ew, i, i + 1);  INC(i)  END;
  DEC(ew.nlines);
  ew.modified := TRUE
END RemoveLine;

(* ════════════════════════════════════════════════════════════════
   Undo
   ════════════════════════════════════════════════════════════════ *)

(* Push an undo entry before performing an edit.
   op        — UOpEdit, UOpSplit, or UOpJoin
   fromLine  — first line affected (saves lines[fromLine] always;
               also saves lines[fromLine+1] for UOpJoin) *)
PROCEDURE PushUndo(ew: EditorWin; op, fromLine: INTEGER);
VAR e, i: INTEGER;
BEGIN
  e := ew.undoTop;
  ew.undo[e].op       := op;
  ew.undo[e].cy       := ew.cy;
  ew.undo[e].cx       := ew.cx;
  ew.undo[e].fromLine := fromLine;
  FOR i := 0 TO LLEN - 1 DO
    ew.undo[e].line0[i] := ew.lines[fromLine][i]
  END;
  IF (op = UOpJoin) & (fromLine + 1 < ew.nlines) THEN
    FOR i := 0 TO LLEN - 1 DO
      ew.undo[e].line1[i] := ew.lines[fromLine + 1][i]
    END
  END;
  ew.undoTop := (e + 1) MOD MaxUndo;
  IF ew.undoCount < MaxUndo THEN  INC(ew.undoCount)  END
END PushUndo;

PROCEDURE DoUndo(ew: EditorWin);
VAR e, i, fromLine: INTEGER;
BEGIN
  IF ew.undoCount = 0 THEN  RETURN  END;
  DEC(ew.undoCount);
  ew.undoTop := (ew.undoTop - 1 + MaxUndo) MOD MaxUndo;
  e        := ew.undoTop;
  fromLine := ew.undo[e].fromLine;
  IF ew.undo[e].op = UOpEdit THEN
    FOR i := 0 TO LLEN - 1 DO
      ew.lines[fromLine][i] := ew.undo[e].line0[i]
    END;
    ew.modified := TRUE
  ELSIF ew.undo[e].op = UOpSplit THEN
    (* Reverse a line split: remove the extra line, restore the original *)
    IF fromLine + 1 < ew.nlines THEN  RemoveLine(ew, fromLine + 1)  END;
    FOR i := 0 TO LLEN - 1 DO
      ew.lines[fromLine][i] := ew.undo[e].line0[i]
    END
  ELSE  (* UOpJoin *)
    (* Reverse a line join: restore original line, re-insert the removed one *)
    FOR i := 0 TO LLEN - 1 DO
      ew.lines[fromLine][i] := ew.undo[e].line0[i]
    END;
    InsertLineAt(ew, fromLine + 1);
    FOR i := 0 TO LLEN - 1 DO
      ew.lines[fromLine + 1][i] := ew.undo[e].line1[i]
    END
  END;
  ew.cy := ew.undo[e].cy;
  ew.cx := ew.undo[e].cx;
  ClampCursor(ew);
  ScrollToCursor(ew)
END DoUndo;

(* ════════════════════════════════════════════════════════════════
   Editing operations (take EditorWin, modify in place)
   ════════════════════════════════════════════════════════════════ *)

PROCEDURE DoEnter(ew: EditorWin);
VAR len, rest, baseIndent, extra, totalIndent, i: INTEGER;
BEGIN
  PushUndo(ew, UOpSplit, ew.cy);
  len  := LineLen(ew, ew.cy);
  rest := len - ew.cx;
  (* Measure leading whitespace on the current line for auto-indent.
     baseIndent = number of leading space/tab bytes in the current line,
     capped at the cursor position. *)
  baseIndent := 0;
  WHILE (baseIndent < ew.cx) &
        ((ew.lines[ew.cy][baseIndent] = ' ') OR (ew.lines[ew.cy][baseIndent] = 09X)) DO
    INC(baseIndent)
  END;
  (* Smart indent: opener keywords add one extra level *)
  extra := 0;
  IF LineEndsWithOpener(ew, ew.cy, ew.cx) THEN  extra := 4  END;
  totalIndent := baseIndent + extra;
  InsertLineAt(ew, ew.cy + 1);
  (* Copy the rest of the current line after the split point *)
  FOR i := 0 TO rest - 1 DO  ew.lines[ew.cy + 1][i] := ew.lines[ew.cy][ew.cx + i]  END;
  ew.lines[ew.cy + 1][rest] := 0X;
  ew.lines[ew.cy][ew.cx]   := 0X;
  INC(ew.cy);  ew.cx := 0;
  (* Prepend indentation onto the new line *)
  IF (totalIndent > 0) & (totalIndent + rest < LLEN) THEN
    FOR i := rest - 1 TO 0 BY -1 DO  (* shift existing content rightward *)
      ew.lines[ew.cy][totalIndent + i] := ew.lines[ew.cy][i]
    END;
    (* Copy base indent chars from the previous line (they may be tabs or spaces) *)
    FOR i := 0 TO baseIndent - 1 DO
      ew.lines[ew.cy][i] := ew.lines[ew.cy - 1][i]
    END;
    (* Fill the extra indent level with spaces *)
    FOR i := baseIndent TO totalIndent - 1 DO
      ew.lines[ew.cy][i] := ' '
    END;
    ew.cx := totalIndent
  END;
  ew.modified := TRUE
END DoEnter;

PROCEDURE DoBackspace(ew: EditorWin);
VAR len1, len2, prev, i: INTEGER;
BEGIN
  IF ew.cx > 0 THEN
    PushUndo(ew, UOpEdit, ew.cy);
    prev := ew.cx;
    Utf8Back(ew.lines[ew.cy], prev);
    DeleteBytesAt(ew, ew.cy, prev, ew.cx - prev);
    ew.cx := prev
  ELSIF ew.cy > 0 THEN
    PushUndo(ew, UOpJoin, ew.cy - 1);
    len1 := LineLen(ew, ew.cy - 1);
    len2 := LineLen(ew, ew.cy);
    IF len1 + len2 < LLEN THEN
      FOR i := 0 TO len2 - 1 DO  ew.lines[ew.cy - 1][len1 + i] := ew.lines[ew.cy][i]  END;
      ew.lines[ew.cy - 1][len1 + len2] := 0X;
      RemoveLine(ew, ew.cy);
      DEC(ew.cy);  ew.cx := len1
    END
  END
END DoBackspace;

PROCEDURE DoDelete(ew: EditorWin);
VAR len1, len2, next, i: INTEGER;
BEGIN
  len1 := LineLen(ew, ew.cy);
  IF ew.cx < len1 THEN
    PushUndo(ew, UOpEdit, ew.cy);
    next := ew.cx;
    Utf8Fwd(ew.lines[ew.cy], next);
    DeleteBytesAt(ew, ew.cy, ew.cx, next - ew.cx)
  ELSIF ew.cy < ew.nlines - 1 THEN
    PushUndo(ew, UOpJoin, ew.cy);
    len2 := LineLen(ew, ew.cy + 1);
    IF len1 + len2 < LLEN THEN
      FOR i := 0 TO len2 - 1 DO  ew.lines[ew.cy][len1 + i] := ew.lines[ew.cy + 1][i]  END;
      ew.lines[ew.cy][len1 + len2] := 0X;
      RemoveLine(ew, ew.cy + 1);
      ew.modified := TRUE
    END
  END
END DoDelete;

PROCEDURE DoKillLine(ew: EditorWin);
VAR len, i: INTEGER;
BEGIN
  len := LineLen(ew, ew.cy);
  IF ew.cx < len THEN
    PushUndo(ew, UOpEdit, ew.cy);
    i := 0;
    WHILE ew.cx + i < len DO  ew.killBuf[i] := ew.lines[ew.cy][ew.cx + i];  INC(i)  END;
    ew.killBuf[i] := 0X;
    ew.lines[ew.cy][ew.cx] := 0X;
    ew.modified := TRUE
  ELSIF ew.cy < ew.nlines - 1 THEN
    ew.killBuf[0] := 0X;
    DoDelete(ew)   (* DoDelete pushes its own undo *)
  END
END DoKillLine;

PROCEDURE DoYank(ew: EditorWin);
VAR klen: INTEGER;
BEGIN
  klen := Strings.Length(ew.killBuf);
  IF klen > 0 THEN
    PushUndo(ew, UOpEdit, ew.cy);
    InsertBytesAt(ew, ew.cy, ew.cx, ew.killBuf, klen);
    INC(ew.cx, klen)
  END
END DoYank;

PROCEDURE DoFind(ew: EditorWin): BOOLEAN;
VAR li, col, i, qlen, count: INTEGER;
    found: BOOLEAN;
BEGIN
  qlen := Strings.Length(ew.srchBuf);
  IF qlen = 0 THEN  RETURN FALSE  END;
  li := ew.cy;  col := ew.cx + 1;
  found := FALSE;  count := 0;
  LOOP
    IF col + qlen > LineLen(ew, li) THEN
      INC(li);  col := 0;
      IF li >= ew.nlines THEN  li := 0;  INC(count)  END;
      IF count > 1 THEN  EXIT  END
    ELSE
      i := 0;
      WHILE (i < qlen) & (ew.lines[li][col + i] = ew.srchBuf[i]) DO  INC(i)  END;
      IF i = qlen THEN
        ew.cy := li;  ew.cx := col;  found := TRUE;  EXIT
      ELSE
        INC(col)
      END
    END
  END;
  RETURN found
END DoFind;

(* ════════════════════════════════════════════════════════════════
   Cursor management
   ════════════════════════════════════════════════════════════════ *)

PROCEDURE ClampCursor(ew: EditorWin);
VAR len: INTEGER;
BEGIN
  IF ew.cy < 0 THEN  ew.cy := 0
  ELSIF ew.cy >= ew.nlines THEN  ew.cy := ew.nlines - 1
  END;
  len := LineLen(ew, ew.cy);
  IF ew.cx < 0 THEN  ew.cx := 0
  ELSIF ew.cx > len THEN  ew.cx := len
  END;
  WHILE (ew.cx > 0) & IsUtf8Cont(ew.lines[ew.cy][ew.cx]) DO  DEC(ew.cx)  END
END ClampCursor;

PROCEDURE ScrollToCursor(ew: EditorWin);
VAR innerH, innerW: INTEGER;
BEGIN
  innerH := ew.h - 2;
  innerW := ew.w - 2;
  IF ew.cy < ew.topLine THEN  ew.topLine := ew.cy  END;
  IF ew.cy >= ew.topLine + innerH THEN  ew.topLine := ew.cy - innerH + 1  END;
  IF ew.cx < ew.leftCol THEN  ew.leftCol := ew.cx  END;
  IF ew.cx >= ew.leftCol + innerW THEN  ew.leftCol := ew.cx - innerW + 1  END;
  (* Snap leftCol to a UTF-8 character boundary *)
  WHILE (ew.leftCol > 0) & IsUtf8Cont(ew.lines[ew.cy][ew.leftCol]) DO  DEC(ew.leftCol)  END
END ScrollToCursor;

PROCEDURE WordLeft(ew: EditorWin);
BEGIN
  IF ew.cx > 0 THEN  Utf8Back(ew.lines[ew.cy], ew.cx)  END;
  WHILE (ew.cx > 0) & (ew.lines[ew.cy][ew.cx] = ' ') DO  Utf8Back(ew.lines[ew.cy], ew.cx)  END;
  WHILE (ew.cx > 0) & (ew.lines[ew.cy][ew.cx - 1] # ' ') DO  Utf8Back(ew.lines[ew.cy], ew.cx)  END
END WordLeft;

PROCEDURE WordRight(ew: EditorWin);
VAR len: INTEGER;
BEGIN
  len := LineLen(ew, ew.cy);
  WHILE (ew.cx < len) & (ew.lines[ew.cy][ew.cx] # ' ') DO  Utf8Fwd(ew.lines[ew.cy], ew.cx)  END;
  WHILE (ew.cx < len) & (ew.lines[ew.cy][ew.cx] = ' ')  DO  Utf8Fwd(ew.lines[ew.cy], ew.cx)  END
END WordRight;

(* ════════════════════════════════════════════════════════════════
   Syntax highlighting helpers
   ════════════════════════════════════════════════════════════════ *)

PROCEDURE ComputeDepths(ew: EditorWin);
VAR li, i, depth, len: INTEGER;
BEGIN
  depth := 0;
  FOR li := 0 TO ew.nlines - 1 DO
    ew.cmtDepth[li] := depth;
    len := LineLen(ew, li);
    i := 0;
    WHILE i < len - 1 DO
      IF (ew.lines[li][i] = '(') & (ew.lines[li][i + 1] = '*') THEN
        INC(depth);  INC(i, 2)
      ELSIF (ew.lines[li][i] = '*') & (ew.lines[li][i + 1] = ')') THEN
        IF depth > 0 THEN  DEC(depth)  END;
        INC(i, 2)
      ELSE
        INC(i)
      END
    END
  END;
  ew.cmtDepth[ew.nlines] := depth
END ComputeDepths;

PROCEDURE IsKeyword(VAR line: ARRAY OF CHAR; from, len: INTEGER): BOOLEAN;
VAR kw: ARRAY 16 OF CHAR;
    i: INTEGER;
BEGIN
  IF (len <= 0) OR (len > 15) THEN  RETURN FALSE  END;
  FOR i := 0 TO len - 1 DO  kw[i] := line[from + i]  END;
  kw[len] := 0X;
  RETURN
    (Strings.Compare(kw, "MODULE")    = 0) OR (Strings.Compare(kw, "IMPORT")    = 0) OR
    (Strings.Compare(kw, "VAR")       = 0) OR (Strings.Compare(kw, "TYPE")      = 0) OR
    (Strings.Compare(kw, "CONST")     = 0) OR (Strings.Compare(kw, "BEGIN")     = 0) OR
    (Strings.Compare(kw, "END")       = 0) OR (Strings.Compare(kw, "PROCEDURE") = 0) OR
    (Strings.Compare(kw, "RECORD")    = 0) OR (Strings.Compare(kw, "ARRAY")     = 0) OR
    (Strings.Compare(kw, "OF")        = 0) OR (Strings.Compare(kw, "POINTER")   = 0) OR
    (Strings.Compare(kw, "TO")        = 0) OR (Strings.Compare(kw, "IF")        = 0) OR
    (Strings.Compare(kw, "THEN")      = 0) OR (Strings.Compare(kw, "ELSIF")     = 0) OR
    (Strings.Compare(kw, "ELSE")      = 0) OR (Strings.Compare(kw, "FOR")       = 0) OR
    (Strings.Compare(kw, "DO")        = 0) OR (Strings.Compare(kw, "WHILE")     = 0) OR
    (Strings.Compare(kw, "REPEAT")    = 0) OR (Strings.Compare(kw, "UNTIL")     = 0) OR
    (Strings.Compare(kw, "CASE")      = 0) OR (Strings.Compare(kw, "WITH")      = 0) OR
    (Strings.Compare(kw, "LOOP")      = 0) OR (Strings.Compare(kw, "EXIT")      = 0) OR
    (Strings.Compare(kw, "RETURN")    = 0) OR (Strings.Compare(kw, "NEW")       = 0) OR
    (Strings.Compare(kw, "NIL")       = 0) OR (Strings.Compare(kw, "TRUE")      = 0) OR
    (Strings.Compare(kw, "FALSE")     = 0) OR (Strings.Compare(kw, "DIV")       = 0) OR
    (Strings.Compare(kw, "MOD")       = 0) OR (Strings.Compare(kw, "IN")        = 0) OR
    (Strings.Compare(kw, "IS")        = 0) OR (Strings.Compare(kw, "OR")        = 0) OR
    (Strings.Compare(kw, "BY")        = 0) OR (Strings.Compare(kw, "CHAR")      = 0) OR
    (Strings.Compare(kw, "INTEGER")   = 0) OR (Strings.Compare(kw, "REAL")      = 0) OR
    (Strings.Compare(kw, "BOOLEAN")   = 0) OR (Strings.Compare(kw, "BYTE")      = 0) OR
    (Strings.Compare(kw, "SET")       = 0) OR (Strings.Compare(kw, "INC")       = 0) OR
    (Strings.Compare(kw, "DEC")       = 0) OR (Strings.Compare(kw, "CHR")       = 0) OR
    (Strings.Compare(kw, "ORD")       = 0) OR (Strings.Compare(kw, "LEN")       = 0) OR
    (Strings.Compare(kw, "ODD")       = 0) OR (Strings.Compare(kw, "ABS")       = 0) OR
    (Strings.Compare(kw, "MIN")       = 0) OR (Strings.Compare(kw, "MAX")       = 0) OR
    (Strings.Compare(kw, "COPY")      = 0) OR (Strings.Compare(kw, "ASSERT")    = 0) OR
    (Strings.Compare(kw, "EXCL")      = 0) OR (Strings.Compare(kw, "INCL")      = 0) OR
    (Strings.Compare(kw, "LSL")       = 0) OR (Strings.Compare(kw, "ASR")       = 0) OR
    (Strings.Compare(kw, "ROR")       = 0) OR (Strings.Compare(kw, "ASH")       = 0)
END IsKeyword;

(* Returns TRUE if the content of ew.lines[li] trimmed to the first atByte
   bytes ends (ignoring trailing spaces) with a block-opening keyword:
   BEGIN  THEN  ELSE  DO  REPEAT  RECORD  OF  WITH  LOOP *)
PROCEDURE LineEndsWithOpener(ew: EditorWin; li, atByte: INTEGER): BOOLEAN;
VAR i, wEnd, wStart, wLen, k: INTEGER;
    kw: ARRAY 10 OF CHAR;
BEGIN
  i := atByte - 1;
  WHILE (i >= 0) & (ew.lines[li][i] = ' ') DO  DEC(i)  END;
  wEnd := i + 1;   (* exclusive end of word *)
  WHILE (i >= 0) &
        (((ew.lines[li][i] >= 'A') & (ew.lines[li][i] <= 'Z')) OR
         ((ew.lines[li][i] >= 'a') & (ew.lines[li][i] <= 'z'))) DO
    DEC(i)
  END;
  wStart := i + 1;
  wLen   := wEnd - wStart;
  IF (wLen <= 0) OR (wLen > 9) THEN  RETURN FALSE  END;
  FOR k := 0 TO wLen - 1 DO  kw[k] := ew.lines[li][wStart + k]  END;
  kw[wLen] := 0X;
  RETURN
    (Strings.Compare(kw, "BEGIN")  = 0) OR
    (Strings.Compare(kw, "THEN")   = 0) OR
    (Strings.Compare(kw, "ELSE")   = 0) OR
    (Strings.Compare(kw, "DO")     = 0) OR
    (Strings.Compare(kw, "REPEAT") = 0) OR
    (Strings.Compare(kw, "RECORD") = 0) OR
    (Strings.Compare(kw, "OF")     = 0) OR
    (Strings.Compare(kw, "WITH")   = 0) OR
    (Strings.Compare(kw, "LOOP")   = 0)
END LineEndsWithOpener;

(* If the current line is of the form <spaces><END|UNTIL|ELSE|ELSIF> with
   nothing else, remove one indent level (4 spaces) from the front and
   adjust cx accordingly.  Called after each printable character is inserted. *)
PROCEDURE CheckAutoDeindent(ew: EditorWin);
VAR i, indent, len, kwLen, removed: INTEGER;
    kw: ARRAY 10 OF CHAR;
BEGIN
  len := LineLen(ew, ew.cy);
  indent := 0;
  WHILE (indent < len) & (ew.lines[ew.cy][indent] = ' ') DO  INC(indent)  END;
  IF indent = 0 THEN  RETURN  END;
  kwLen := 0;  i := indent;
  WHILE (i < len) &
        (((ew.lines[ew.cy][i] >= 'A') & (ew.lines[ew.cy][i] <= 'Z')) OR
         ((ew.lines[ew.cy][i] >= 'a') & (ew.lines[ew.cy][i] <= 'z'))) DO
    IF kwLen < 9 THEN  kw[kwLen] := ew.lines[ew.cy][i];  INC(kwLen)  END;
    INC(i)
  END;
  kw[kwLen] := 0X;
  (* Line must be exactly <spaces><keyword> — nothing more *)
  IF i # len THEN  RETURN  END;
  IF (Strings.Compare(kw, "END")   = 0) OR
     (Strings.Compare(kw, "UNTIL") = 0) OR
     (Strings.Compare(kw, "ELSE")  = 0) OR
     (Strings.Compare(kw, "ELSIF") = 0) THEN
    removed := 4;
    IF removed > indent THEN  removed := indent  END;
    DeleteBytesAt(ew, ew.cy, 0, removed);
    DEC(ew.cx, removed)
  END
END CheckAutoDeindent;

(* ════════════════════════════════════════════════════════════════
   Rendering
   ════════════════════════════════════════════════════════════════ *)

(* Render one editor line into the TUI back buffer.
   innerX, sy  : left column and row of the output cell.
   leftByte    : byte offset of the first visible column.
   innerW      : number of available cells (bytes wide).
   cmtD        : comment nesting depth at the start of this line. *)
PROCEDURE RenderEdLine(ew: EditorWin; li, innerX, sy, leftByte, innerW, cmtD: INTEGER);
VAR
  len, i, sc: INTEGER;
  ch, nextCh: CHAR;
  fg: INTEGER;
  depth: INTEGER;
  inStr: BOOLEAN;
  closingParen: BOOLEAN;
  kwEnd, kwFg, j, kwLen: INTEGER;
BEGIN
  len := LineLen(ew, li);
  (* InvalidateLine forces Flush to emit every cell in this row without
     skipping, keeping multi-byte UTF-8 sequences intact. *)
  TUI.InvalidateLine(sy);

  depth        := cmtD;
  inStr        := FALSE;
  closingParen := FALSE;
  kwEnd        := 0;
  kwFg         := TUI.White;

  i := 0;
  WHILE i < len DO
    ch := ew.lines[li][i];
    IF i + 1 < len THEN  nextCh := ew.lines[li][i + 1]  ELSE  nextCh := 0X  END;

    (* ── Determine colour ── *)
    IF closingParen THEN
      fg := TUI.Green;  closingParen := FALSE
    ELSIF depth > 0 THEN
      fg := TUI.Green;
      IF (ch = '*') & (nextCh = ')') THEN
        IF depth > 0 THEN  DEC(depth)  END;
        closingParen := TRUE
      END
    ELSIF inStr THEN
      fg := TUI.Yellow;
      IF ch = '"' THEN  inStr := FALSE  END
    ELSIF i < kwEnd THEN
      fg := kwFg
    ELSIF (ch = '(') & (nextCh = '*') THEN
      INC(depth);  fg := TUI.Green
    ELSIF ch = '"' THEN
      inStr := TRUE;  fg := TUI.Yellow
    ELSIF (ch >= 'A') & (ch <= 'Z') & ~IsUtf8Cont(ch) THEN
      (* Scan ahead for the full identifier *)
      j := i;
      WHILE (j < len) &
            (((ew.lines[li][j] >= 'A') & (ew.lines[li][j] <= 'Z')) OR
             ((ew.lines[li][j] >= 'a') & (ew.lines[li][j] <= 'z')) OR
             ((ew.lines[li][j] >= '0') & (ew.lines[li][j] <= '9')) OR
             (ew.lines[li][j] = '_')) DO
        INC(j)
      END;
      kwLen := j - i;
      IF IsKeyword(ew.lines[li], i, kwLen) THEN
        kwEnd := i + kwLen;  kwFg := TUI.Cyan;  fg := TUI.Cyan
      ELSE
        fg := TUI.White
      END
    ELSIF IsUtf8Cont(ch) THEN
      fg := TUI.White   (* continuation byte — inherits colour from start byte *)
    ELSE
      fg := TUI.White
    END;

    (* ── Output if in the visible range ── *)
    sc := i - leftByte;
    IF (sc >= 0) & (sc < innerW) THEN
      TUI.PutCell(innerX + sc, sy, ch, fg, TUI.Black)
    END;
    INC(i)
  END
  (* Cells beyond line length remain as spaces from DrawEditor's FillRect *)
END RenderEdLine;

(* Draw an editor window — called by TUI.DrawAll via the view's draw proc. *)
PROCEDURE DrawEditor(v: TUI.View);
VAR innerX, innerY, innerW, innerH, row, li: INTEGER;
    titleBuf: ARRAY 260 OF CHAR;
    tlen, tx, borderFg, borderBg, titleFg: INTEGER;
BEGIN
  WITH v: EditorWinRec DO
    innerX := v.x + 1;
    innerY := v.y + 1;
    innerW := v.w - 2;
    innerH := v.h - 2;

    (* ── Border colour depends on focus ── *)
    IF v.focused THEN
      borderFg := TUI.White;  borderBg := TUI.Blue;  titleFg := TUI.Yellow
    ELSE
      borderFg := TUI.White;  borderBg := TUI.Black;  titleFg := TUI.White
    END;

    (* ── Clear interior ── *)
    TUI.FillRect(innerX, innerY, innerW, innerH, ' ', TUI.White, TUI.Black);

    (* ── Border ── *)
    TUI.DrawBox(v.x, v.y, v.w, v.h, borderFg, borderBg);

    (* ── Title (filename + modified indicator) ── *)
    IF v.title[0] = 0X THEN  Strings.Copy("[untitled]", titleBuf)
    ELSE  Strings.Copy(v.title, titleBuf)
    END;
    IF v.modified THEN  Strings.Append(" *", titleBuf)  END;
    tlen := Strings.Length(titleBuf);
    IF tlen > v.w - 4 THEN  tlen := v.w - 4  END;
    titleBuf[tlen] := 0X;
    tx := v.x + (v.w - tlen) DIV 2;
    TUI.PutStr(tx, v.y, titleBuf, titleFg, borderBg);

    (* ── Editor content ── *)
    ComputeDepths(v);
    FOR row := 0 TO innerH - 1 DO
      li := v.topLine + row;
      IF li < v.nlines THEN
        RenderEdLine(v, li, innerX, innerY + row, v.leftCol, innerW, v.cmtDepth[li])
      END
    END
  END
END DrawEditor;

(* Handle keyboard and mouse events for an editor window. *)
PROCEDURE HandleEditor(v: TUI.View; ev: TUI.Event): BOOLEAN;
VAR ch: CHAR;
    bytes: ARRAY 4 OF CHAR;
BEGIN
  WITH v: EditorWinRec DO
    IF ev.kind = TUI.EvKey THEN
      ch := ev.key;

      IF    ch = TUI.KUp    THEN  DEC(v.cy);  ClampCursor(v)
      ELSIF ch = TUI.KDown  THEN  INC(v.cy);  ClampCursor(v)
      ELSIF ch = TUI.KLeft  THEN
        IF v.cx > 0 THEN  Utf8Back(v.lines[v.cy], v.cx)
        ELSIF v.cy > 0 THEN  DEC(v.cy);  v.cx := LineLen(v, v.cy)
        END
      ELSIF ch = TUI.KRight THEN
        IF v.cx < LineLen(v, v.cy) THEN  Utf8Fwd(v.lines[v.cy], v.cx)
        ELSIF v.cy < v.nlines - 1 THEN  INC(v.cy);  v.cx := 0
        END
      ELSIF ch = TUI.KHome   THEN  v.cy := 0;  v.cx := 0
      ELSIF ch = TUI.KEnd    THEN  v.cy := v.nlines - 1;  v.cx := LineLen(v, v.cy)
      ELSIF ch = TUI.KCtrlHome THEN  v.cx := 0
      ELSIF ch = TUI.KCtrlEnd  THEN  v.cx := LineLen(v, v.cy)
      ELSIF ch = TUI.KCtrlLeft  THEN  WordLeft(v)
      ELSIF ch = TUI.KCtrlRight THEN  WordRight(v)
      ELSIF ch = TUI.KPgUp   THEN  DEC(v.cy, v.h - 2);  ClampCursor(v)
      ELSIF ch = TUI.KPgDn   THEN  INC(v.cy, v.h - 2);  ClampCursor(v)
      ELSIF ch = TUI.KEnter  THEN  DoEnter(v)
      ELSIF ch = TUI.KBackspace THEN  DoBackspace(v)
      ELSIF ch = TUI.KDel    THEN  DoDelete(v)
      ELSIF ch = TUI.KTab    THEN
        (* Insert 4 spaces *)
        PushUndo(v, UOpEdit, v.cy);
        bytes[0] := ' ';  bytes[1] := ' ';  bytes[2] := ' ';  bytes[3] := ' ';
        InsertBytesAt(v, v.cy, v.cx, bytes, 4);
        INC(v.cx, 4)
      ELSIF ORD(ch) = 11 THEN  DoKillLine(v)   (* Ctrl+K *)
      ELSIF ORD(ch) = 25 THEN  DoYank(v)       (* Ctrl+Y *)
      ELSIF ORD(ch) = 26 THEN  DoUndo(v)       (* Ctrl+Z *)
      ELSIF ORD(ch) = 6  THEN                  (* Ctrl+F *)
        promptMode := 1;
        promptBuf[0] := 0X;  promptPos := 0;
        Strings.Copy("Find: ", statusMsg)
      ELSIF ORD(ch) = 7  THEN                  (* Ctrl+G *)
        promptMode := 2;
        promptBuf[0] := 0X;  promptPos := 0;
        Strings.Copy("Go to line: ", statusMsg)
      ELSIF (ORD(ch) >= 32) & (ORD(ch) < 127) THEN
        PushUndo(v, UOpEdit, v.cy);
        bytes[0] := ch;
        InsertBytesAt(v, v.cy, v.cx, bytes, 1);
        INC(v.cx);
        CheckAutoDeindent(v)
      END;
      ScrollToCursor(v);
      RETURN TRUE

    ELSIF ev.kind = TUI.EvMouse THEN
      IF ev.mb = 64 THEN       (* wheel up *)
        IF v.topLine > 0 THEN  DEC(v.topLine, 3) END;
        IF v.topLine < 0 THEN  v.topLine := 0 END
      ELSIF ev.mb = 65 THEN    (* wheel down *)
        INC(v.topLine, 3);
        IF v.topLine > v.nlines - 1 THEN  v.topLine := v.nlines - 1 END
      ELSIF (ev.mb # 32) & (ev.mb # 3) &
         (ev.mx >= v.x + 1) & (ev.mx <= v.x + v.w - 2) &
         (ev.my >= v.y + 1) & (ev.my <= v.y + v.h - 2) THEN
        (* Click inside inner area → move cursor *)
        v.cy := v.topLine + (ev.my - v.y - 1);
        v.cx := v.leftCol + (ev.mx - v.x - 1);
        ClampCursor(v);
        ScrollToCursor(v)
      END;
      RETURN TRUE
    END
  END;
  RETURN FALSE
END HandleEditor;

(* ════════════════════════════════════════════════════════════════
   Window management
   ════════════════════════════════════════════════════════════════ *)

(* Tile all EditorWins across the desktop interior
   (between menubar row 1 and statusline row TUI.Rows). *)
PROCEDURE TileEditorWins;
VAR i, n, row, col, cellW, cellH, x, y: INTEGER;
    ewArr: ARRAY MaxWins OF EditorWin;
    ew: EditorWin;
    v: TUI.View;
BEGIN
  (* Collect living EditorWins — scan the full array, not just 0..winCount-1,
     because closing a window can leave NIL gaps below live entries. *)
  n := 0;
  FOR i := 0 TO MaxWins - 1 DO
    IF wins[i] # NIL THEN
      ewArr[n] := wins[i];  INC(n)
    END
  END;
  IF n = 0 THEN  RETURN  END;

  (* Simple tiling: up to 2 columns *)
  IF n = 1 THEN
    col := 1;  row := 1
  ELSE
    col := 2;  row := (n + 1) DIV 2
  END;
  cellW := TUI.Cols DIV col;
  cellH := (TUI.Rows - 2) DIV row;  (* rows 2..Rows-1 *)

  FOR i := 0 TO n - 1 DO
    x := (i MOD col) * cellW + 1;
    y := (i DIV col) * cellH + 2;
    ewArr[i].x := x;
    ewArr[i].y := y;
    ewArr[i].w := cellW;
    ewArr[i].h := cellH
  END
END TileEditorWins;

PROCEDURE NewEditorWin(): EditorWin;
VAR ew: EditorWin;
    i: INTEGER;
BEGIN
  IF winCount >= MaxWins THEN  RETURN NIL  END;
  NEW(ew);
  (* geometry: leave row 1 for menu, row TUI.Rows for status *)
  ew.x := 1;  ew.y := 2;
  ew.w := TUI.Cols;  ew.h := TUI.Rows - 2;
  ew.title[0]   := 0X;
  ew.moveable   := FALSE;
  ew.draw       := DrawEditor;
  ew.handle     := HandleEditor;
  ew.next       := NIL;  ew.child := NIL;
  ew.focused    := FALSE;
  ew.alwaysOnTop := FALSE;
  ew.nlines     := 1;
  ew.cx := 0;  ew.cy := 0;
  ew.topLine := 0;  ew.leftCol := 0;
  ew.modified := FALSE;
  ew.killBuf[0] := 0X;
  ew.srchBuf[0] := 0X;
  ew.undoTop := 0;  ew.undoCount := 0;
  (* Find a free slot *)
  i := 0;
  WHILE (i < MaxWins) & (wins[i] # NIL) DO  INC(i)  END;
  IF i < MaxWins THEN  wins[i] := ew  END;
  INC(winCount);
  TUI.AddView(ew);
  TUI.SetFocus(ew);
  TileEditorWins;
  RETURN ew
END NewEditorWin;

PROCEDURE CloseEditorWin(ew: EditorWin);
VAR i: INTEGER;
BEGIN
  IF ew = NIL THEN  RETURN  END;
  TUI.RemoveView(ew);
  FOR i := 0 TO MaxWins - 1 DO
    IF wins[i] = ew THEN  wins[i] := NIL  END
  END;
  IF winCount > 0 THEN  DEC(winCount)  END;
  (* Focus the next available window *)
  i := 0;
  WHILE (i < MaxWins) & (wins[i] = NIL) DO  INC(i)  END;
  IF i < MaxWins THEN
    TUI.SetFocus(wins[i]);
    TileEditorWins
  END
END CloseEditorWin;

PROCEDURE FocusedEditor(): EditorWin;
VAR v: TUI.View;
BEGIN
  v := TUI.Focused;
  IF (v # NIL) & (v IS EditorWinRec) THEN
    WITH v: EditorWinRec DO  RETURN v  END
  END;
  RETURN NIL
END FocusedEditor;

PROCEDURE NextEditorWin;
VAR i, cur, next: INTEGER;
    ew: EditorWin;
BEGIN
  ew := FocusedEditor();
  IF ew = NIL THEN  ew := lastEditor  END;
  cur := -1;
  FOR i := 0 TO MaxWins - 1 DO
    IF wins[i] = ew THEN  cur := i  END
  END;
  next := (cur + 1) MOD MaxWins;
  WHILE (next # cur) & (wins[next] = NIL) DO
    next := (next + 1) MOD MaxWins
  END;
  IF (wins[next] # NIL) & (wins[next] # ew) THEN
    TUI.SetFocus(wins[next])
  END
END NextEditorWin;

(* ════════════════════════════════════════════════════════════════
   File I/O
   ════════════════════════════════════════════════════════════════ *)

PROCEDURE LoadFile(ew: EditorWin; name: ARRAY OF CHAR): BOOLEAN;
VAR f: Files.File;
    r: Files.Rider;
    b: BYTE;
    li, col: INTEGER;
BEGIN
  f := Files.Old(name);
  IF f = NIL THEN  RETURN FALSE  END;
  li := 0;  col := 0;
  ew.lines[0][0] := 0X;
  Files.Set(r, f, 0);
  Files.Read(r, b);
  WHILE ~r.eof DO
    IF b = 10 THEN   (* newline *)
      ew.lines[li][col] := 0X;
      INC(li);
      IF li >= MaxLines THEN
        li := MaxLines - 1;
        WHILE ~r.eof DO  Files.Read(r, b)  END
      ELSE
        col := 0;  ew.lines[li][0] := 0X
      END
    ELSIF b # 13 THEN  (* skip CR *)
      IF col < LLEN - 1 THEN
        IF b = 9 THEN   (* tab → 4 spaces *)
          WHILE (col < LLEN - 1) & (col MOD 4 # 0) DO
            ew.lines[li][col] := ' ';  INC(col)
          END;
          ew.lines[li][col] := ' ';  INC(col)
        ELSE
          ew.lines[li][col] := CHR(b);  INC(col)
        END
      END
    END;
    Files.Read(r, b)
  END;
  ew.lines[li][col] := 0X;
  ew.nlines := li + 1;
  Files.Close(f);
  Strings.Copy(name, ew.title);
  ew.cx := 0;  ew.cy := 0;
  ew.topLine := 0;  ew.leftCol := 0;
  ew.modified := FALSE;
  ew.undoTop := 0;  ew.undoCount := 0;
  RETURN TRUE
END LoadFile;

PROCEDURE SaveFile(ew: EditorWin): BOOLEAN;
VAR f: Files.File;
    r: Files.Rider;
    b: BYTE;
    li, col, len: INTEGER;
BEGIN
  IF ew.title[0] = 0X THEN  RETURN FALSE  END;
  f := Files.New(ew.title);
  IF f = NIL THEN  RETURN FALSE  END;
  Files.Set(r, f, 0);
  FOR li := 0 TO ew.nlines - 1 DO
    len := LineLen(ew, li);
    FOR col := 0 TO len - 1 DO
      b := ORD(ew.lines[li][col]);
      Files.Write(r, b)
    END;
    b := 10;  Files.Write(r, b)
  END;
  Files.Register(f);
  Files.Close(f);
  ew.modified := FALSE;
  RETURN TRUE
END SaveFile;

(* ════════════════════════════════════════════════════════════════
   Build integration
   ════════════════════════════════════════════════════════════════ *)

(* BinName — derive executable path from a .mod title.
   "examples/foo.mod" → "examples/foo" *)
PROCEDURE BinName(title: ARRAY OF CHAR; VAR bin: ARRAY OF CHAR);
VAR i: INTEGER;
    hasSlash: BOOLEAN;
    tmp: ARRAY 516 OF CHAR;
BEGIN
  Strings.Copy(title, bin);
  i := Strings.Length(bin);
  (* strip ".mod" suffix *)
  IF (i >= 4) & (bin[i-4] = '.') &
     (bin[i-3] = 'm') & (bin[i-2] = 'o') & (bin[i-1] = 'd') THEN
    bin[i-4] := 0X
  END;
  (* If path has no '/' it won't execute without a prefix; prepend "./" *)
  hasSlash := FALSE;
  i := 0;
  WHILE bin[i] # 0X DO
    IF bin[i] = '/' THEN  hasSlash := TRUE  END;
    INC(i)
  END;
  IF ~hasSlash THEN
    Strings.Copy("./", tmp);
    Strings.Append(bin, tmp);
    Strings.Copy(tmp, bin)
  END
END BinName;

PROCEDURE Compile(ew: EditorWin);
VAR cmd: ARRAY 512 OF CHAR;
    f: Files.File;
    r: Files.Rider;
    b: BYTE;
    outBuf: ARRAY 200 OF CHAR;
    i, rc: INTEGER;
BEGIN
  IF ew = NIL THEN
    Strings.Copy("No file open.", statusMsg);  RETURN
  END;
  IF ew.title[0] = 0X THEN
    Strings.Copy("Save file first.", statusMsg);  RETURN
  END;
  Strings.Copy("obc ", cmd);
  Strings.Append(ew.title, cmd);
  Strings.Append(" > .obc_errors 2>&1", cmd);
  rc := OS.Exec(cmd);
  IF rc = 0 THEN
    Strings.Copy("Compiled OK.", statusMsg)
  ELSE
    f := Files.Old(".obc_errors");
    IF f # NIL THEN
      Files.Set(r, f, 0);
      i := 0;
      Files.Read(r, b);
      WHILE ~r.eof & (CHR(b) # 0AX) & (i < 199) DO
        outBuf[i] := CHR(b);  INC(i);
        Files.Read(r, b)
      END;
      outBuf[i] := 0X;
      Files.Close(f);
      Strings.Copy(outBuf, statusMsg)
    ELSE
      Strings.Copy("Compile failed.", statusMsg)
    END
  END
END Compile;

(* RunInTerminal — suspend TUI, run cmd with full terminal access,
   then wait for Enter before returning to the IDE. *)
PROCEDURE RunInTerminal(cmd: ARRAY OF CHAR);
VAR fullCmd: ARRAY 640 OF CHAR;
BEGIN
  TUI.Suspend();
  Out.Ln();
  Strings.Copy(cmd, fullCmd);
  (* Read from /dev/tty so stale mouse-event bytes in stdin don't fool read *)
  Strings.Append("; echo; printf 'Press Enter to return to IDE...'; read x < /dev/tty", fullCmd);
  OS.Exec(fullCmd);
  TUI.Resume()
END RunInTerminal;

PROCEDURE CompileAndRun(ew: EditorWin);
VAR bin: ARRAY 512 OF CHAR;
BEGIN
  Compile(ew);
  (* Only run if compile succeeded ("Compiled OK." starts with 'C') *)
  IF (ew = NIL) OR (statusMsg[0] # 'C') THEN
    RETURN
  END;
  BinName(ew.title, bin);
  RunInTerminal(bin)
END CompileAndRun;

(* ════════════════════════════════════════════════════════════════
   Prompt handling (inline find / goto in status line)
   ════════════════════════════════════════════════════════════════ *)

PROCEDURE HandlePrompt(ev: TUI.Event);
VAR ch: CHAR;
    n, i: INTEGER;
    ew: EditorWin;
BEGIN
  IF ev.kind # TUI.EvKey THEN  RETURN  END;
  ch := ev.key;

  (* Confirm-close / confirm-quit prompts — single key Y or anything-else *)
  IF (promptMode = 3) OR (promptMode = 4) THEN
    IF (ch = 'Y') OR (ch = 'y') THEN
      IF promptMode = 3 THEN
        CloseEditorWin(pendingCloseWin);
        pendingCloseWin := NIL
      ELSE
        running := FALSE
      END
    END;
    promptMode := 0;  promptBuf[0] := 0X;  statusMsg[0] := 0X;
    IF (promptMode = 0) & (lastEditor # NIL) THEN  TUI.SetFocus(lastEditor)  END;
    RETURN
  END;

  ew := FocusedEditor();
  IF ew = NIL THEN  ew := lastEditor  END;
  IF ch = TUI.KEsc THEN
    promptMode := 0;  promptBuf[0] := 0X;  statusMsg[0] := 0X;
    IF lastEditor # NIL THEN  TUI.SetFocus(lastEditor)  END;
    RETURN
  END;
  IF ch = TUI.KEnter THEN
    IF promptMode = 1 THEN       (* find *)
      IF ew # NIL THEN
        Strings.Copy(promptBuf, ew.srchBuf);
        IF DoFind(ew) THEN
          Strings.Copy("Found.", statusMsg)
        ELSE
          Strings.Copy("Not found.", statusMsg)
        END
      END
    ELSIF promptMode = 2 THEN    (* goto line *)
      n := 0;  i := 0;
      WHILE (promptBuf[i] >= '0') & (promptBuf[i] <= '9') DO
        n := n * 10 + (ORD(promptBuf[i]) - ORD('0'));  INC(i)
      END;
      IF ew # NIL THEN
        DEC(n);
        IF n < 0 THEN  n := 0  END;
        IF n >= ew.nlines THEN  n := ew.nlines - 1  END;
        ew.cy := n;  ew.cx := 0;
        ScrollToCursor(ew)
      END;
      statusMsg[0] := 0X
    END;
    promptMode := 0;  promptBuf[0] := 0X;
    IF lastEditor # NIL THEN  TUI.SetFocus(lastEditor)  END;
    RETURN
  END;
  IF (ch = TUI.KBackspace) OR (ORD(ch) = 127) THEN
    IF promptPos > 0 THEN
      DEC(promptPos);  promptBuf[promptPos] := 0X
    END
  ELSIF (ORD(ch) >= 32) & (ORD(ch) < 127) & (promptPos < 127) THEN
    promptBuf[promptPos] := ch;  INC(promptPos);
    promptBuf[promptPos] := 0X
  END;
  IF promptMode = 1 THEN
    Strings.Copy("Find: ", statusMsg);  Strings.Append(promptBuf, statusMsg)
  ELSIF promptMode = 2 THEN
    Strings.Copy("Go to line: ", statusMsg);  Strings.Append(promptBuf, statusMsg)
  END
END HandlePrompt;

(* ════════════════════════════════════════════════════════════════
   Menu command handler
   ════════════════════════════════════════════════════════════════ *)

PROCEDURE AnyModified(): BOOLEAN;
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO MaxWins - 1 DO
    IF (wins[i] # NIL) & wins[i].modified THEN  RETURN TRUE  END
  END;
  RETURN FALSE
END AnyModified;

PROCEDURE OnMenuCmd(cmd: INTEGER);
VAR ew: EditorWin;
    path: ARRAY 512 OF CHAR;
    ok: BOOLEAN;
    cwd: ARRAY 512 OF CHAR;
BEGIN
  ew := FocusedEditor();
  IF ew = NIL THEN  ew := lastEditor  END;

  IF cmd = CmdNew THEN
    IF NewEditorWin() = NIL THEN
      Strings.Copy("Too many windows.", statusMsg)
    END

  ELSIF cmd = CmdOpen THEN
    OS.GetCwd(cwd);
    ok := FileDialog.Show("Open File", cwd, ".mod", path);
    IF ok THEN
      (* Always open in a new window so multiple files can be open at once *)
      ew := NewEditorWin();
      IF ew # NIL THEN
        IF ~LoadFile(ew, path) THEN
          Strings.Copy("Could not open file.", statusMsg)
        END
      ELSE
        Strings.Copy("Too many windows.", statusMsg)
      END
    END

  ELSIF cmd = CmdSave THEN
    IF ew # NIL THEN
      IF ew.title[0] = 0X THEN
        OS.GetCwd(cwd);
        ok := FileDialog.Show("Save As", cwd, ".mod", path);
        IF ok THEN
          Strings.Copy(path, ew.title);
          IF ~SaveFile(ew) THEN
            Strings.Copy("Save failed.", statusMsg)
          ELSE
            Strings.Copy("Saved.", statusMsg)
          END
        END
      ELSE
        IF ~SaveFile(ew) THEN
          Strings.Copy("Save failed.", statusMsg)
        ELSE
          Strings.Copy("Saved.", statusMsg)
        END
      END
    END

  ELSIF cmd = CmdSaveAs THEN
    IF ew # NIL THEN
      OS.GetCwd(cwd);
      ok := FileDialog.Show("Save As", cwd, ".mod", path);
      IF ok THEN
        Strings.Copy(path, ew.title);
        IF ~SaveFile(ew) THEN
          Strings.Copy("Save failed.", statusMsg)
        ELSE
          Strings.Copy("Saved.", statusMsg)
        END
      END
    END

  ELSIF cmd = CmdClose THEN
    IF ew # NIL THEN
      IF ew.modified THEN
        pendingCloseWin := ew;
        promptMode := 3;
        Strings.Copy("Modified. Close without saving? (Y/N)", statusMsg)
      ELSE
        CloseEditorWin(ew)
      END
    END

  ELSIF cmd = CmdQuit THEN
    IF AnyModified() THEN
      promptMode := 4;
      Strings.Copy("Unsaved changes. Quit without saving? (Y/N)", statusMsg)
    ELSE
      running := FALSE
    END

  ELSIF cmd = CmdUndo THEN
    IF ew # NIL THEN  DoUndo(ew)  END

  ELSIF cmd = CmdFind THEN
    promptMode := 1;
    promptBuf[0] := 0X;  promptPos := 0;
    Strings.Copy("Find: ", statusMsg)

  ELSIF cmd = CmdFindNext THEN
    IF ew # NIL THEN
      IF DoFind(ew) THEN
        Strings.Copy("Found.", statusMsg)
      ELSE
        Strings.Copy("Not found.", statusMsg)
      END
    END

  ELSIF cmd = CmdGoto THEN
    promptMode := 2;
    promptBuf[0] := 0X;  promptPos := 0;
    Strings.Copy("Go to line: ", statusMsg)

  ELSIF cmd = CmdCompile THEN
    Compile(ew)

  ELSIF cmd = CmdRun THEN
    IF ew = NIL THEN
      Strings.Copy("No file open.", statusMsg)
    ELSIF ew.title[0] = 0X THEN
      Strings.Copy("Save file first.", statusMsg)
    ELSE
      BinName(ew.title, path);
      RunInTerminal(path)
    END

  ELSIF cmd = CmdCompRun THEN
    CompileAndRun(ew)

  ELSIF cmd = CmdNextWin THEN
    NextEditorWin

  ELSIF cmd = CmdTile THEN
    TileEditorWins
  END;
  (* Return focus to the editor (menus steal it; prompts restore it themselves) *)
  IF (promptMode = 0) & (FocusedEditor() = NIL) & (lastEditor # NIL) THEN
    TUI.SetFocus(lastEditor)
  END
END OnMenuCmd;

(* ════════════════════════════════════════════════════════════════
   Status line update
   ════════════════════════════════════════════════════════════════ *)

PROCEDURE UpdateStatus;
VAR ew: EditorWin;
    buf: ARRAY 256 OF CHAR;
    tmp: ARRAY 32 OF CHAR;
    ln, col: INTEGER;
BEGIN
  ew := FocusedEditor();
  IF promptMode # 0 THEN
    Strings.Copy(statusMsg, buf)
  ELSIF statusMsg[0] # 0X THEN
    Strings.Copy(statusMsg, buf)
  ELSIF ew # NIL THEN
    ln  := ew.cy + 1;
    col := ByteToCol(ew.lines[ew.cy], ew.cx) + 1;
    Strings.Copy("  Ln:", buf);
    Strings.IntToStr(ln, tmp);   Strings.Append(tmp, buf);
    Strings.Append(" Col:", buf);
    Strings.IntToStr(col, tmp);  Strings.Append(tmp, buf);
    Strings.Append("  ", buf);
    IF ew.title[0] # 0X THEN  Strings.Append(ew.title, buf)
    ELSE  Strings.Append("[untitled]", buf)
    END;
    IF ew.modified THEN  Strings.Append(" [+]", buf)  END
  ELSE
    Strings.Copy("  No file open", buf)
  END;
  Strings.Copy(buf, sline.text)
END UpdateStatus;

(* ════════════════════════════════════════════════════════════════
   Setup
   ════════════════════════════════════════════════════════════════ *)

PROCEDURE BuildMenus;
BEGIN
  mbar := Widgets.NewMenuBar(1, 1, TUI.Cols);

  (* File menu *)
  Widgets.MenuBarAddMenu(mbar, "File");
  Widgets.MenuBarAddItem(mbar, 0, "New           Ctrl+N", CmdNew);
  Widgets.MenuBarAddItem(mbar, 0, "Open...       Ctrl+O", CmdOpen);
  Widgets.MenuBarAddItem(mbar, 0, "Save          Ctrl+S", CmdSave);
  Widgets.MenuBarAddItem(mbar, 0, "Save As...", CmdSaveAs);
  Widgets.MenuBarAddSep (mbar, 0);
  Widgets.MenuBarAddItem(mbar, 0, "Close         Ctrl+W", CmdClose);
  Widgets.MenuBarAddSep (mbar, 0);
  Widgets.MenuBarAddItem(mbar, 0, "Quit          Ctrl+Q", CmdQuit);

  (* Edit menu *)
  Widgets.MenuBarAddMenu(mbar, "Edit");
  Widgets.MenuBarAddItem(mbar, 1, "Undo          Ctrl+Z", CmdUndo);
  Widgets.MenuBarAddSep (mbar, 1);
  Widgets.MenuBarAddItem(mbar, 1, "Find...       Ctrl+F", CmdFind);
  Widgets.MenuBarAddItem(mbar, 1, "Find Next     F3",     CmdFindNext);
  Widgets.MenuBarAddItem(mbar, 1, "Go to Line... Ctrl+G", CmdGoto);

  (* Build menu *)
  Widgets.MenuBarAddMenu(mbar, "Build");
  Widgets.MenuBarAddItem(mbar, 2, "Compile       F5",  CmdCompile);
  Widgets.MenuBarAddItem(mbar, 2, "Run           F6",  CmdRun);
  Widgets.MenuBarAddItem(mbar, 2, "Compile & Run F9",  CmdCompRun);

  (* Window menu *)
  Widgets.MenuBarAddMenu(mbar, "Window");
  Widgets.MenuBarAddItem(mbar, 3, "Next Window   Ctrl+Tab", CmdNextWin);
  Widgets.MenuBarAddItem(mbar, 3, "Tile Windows",           CmdTile);

  mbar.onCmd := OnMenuCmd;
  TUI.AddView(mbar);

  (* Status line *)
  sline := Widgets.NewStatusLine(1, TUI.Rows, TUI.Cols, "");
  sline.alwaysOnTop := TRUE;
  TUI.AddView(sline)
END BuildMenus;

(* ════════════════════════════════════════════════════════════════
   Main
   ════════════════════════════════════════════════════════════════ *)

PROCEDURE CursorScreenPos(ew: EditorWin; VAR sx, sy: INTEGER);
BEGIN
  sx := ew.x + 1 + ByteToCol(ew.lines[ew.cy], ew.cx) - ByteToCol(ew.lines[ew.cy], ew.leftCol);
  sy := ew.y + 1 + ew.cy - ew.topLine
END CursorScreenPos;

VAR
  ev:    TUI.Event;
  ew:    EditorWin;
  sx, sy: INTEGER;
  fn:    ARRAY 512 OF CHAR;
  ch:    CHAR;

BEGIN
  TUI.Init();

  winCount  := 0;
  lastEditor := NIL;
  running   := TRUE;
  promptMode := 0;
  statusMsg[0] := 0X;
  promptBuf[0] := 0X;
  promptPos := 0;

  BuildMenus();

  (* Open file from command line, or start with empty window *)
  ew := NewEditorWin();
  lastEditor := ew;   (* prime lastEditor so menu commands work before any mouse motion *)
  IF Args.Count() > 0 THEN
    Args.Get(1, fn);
    IF ~LoadFile(ew, fn) THEN
      Strings.Copy("New file: ", statusMsg);  Strings.Append(fn, statusMsg);
      Strings.Copy(fn, ew.title)
    END
  END;

  WHILE running DO
    UpdateStatus();
    TUI.ClearBack(TUI.White, TUI.Black);
    TUI.DrawAll();
    TUI.Flush();

    (* Position blinking cursor in the focused editor *)
    ew := FocusedEditor();
    IF ew # NIL THEN
      CursorScreenPos(ew, sx, sy);
      TUI.SetCursor(sx, sy)
    END;

    TUI.WaitEvent(ev);

    (* Clear status message only on significant input (key or real click, not motion) *)
    IF (ev.kind = TUI.EvKey) OR
       ((ev.kind = TUI.EvMouse) & (ev.mb # 32) & (ev.mb # 3)) THEN
      statusMsg[0] := 0X
    END;

    (* Track the last editor that had focus so menu commands can use it *)
    ew := FocusedEditor();
    IF ew # NIL THEN  lastEditor := ew  END;

    IF promptMode # 0 THEN
      HandlePrompt(ev)
    ELSIF ev.kind = TUI.EvKey THEN
      ch := ev.key;

      (* Global hotkeys *)
      IF ORD(ch) = 14 THEN       (* Ctrl+N *)
        IF NewEditorWin() = NIL THEN  Strings.Copy("Too many windows.", statusMsg)  END
      ELSIF ORD(ch) = 15 THEN    (* Ctrl+O *)
        OnMenuCmd(CmdOpen)
      ELSIF ORD(ch) = 19 THEN    (* Ctrl+S *)
        OnMenuCmd(CmdSave)
      ELSIF ORD(ch) = 23 THEN    (* Ctrl+W *)
        OnMenuCmd(CmdClose)
      ELSIF ORD(ch) = 17 THEN    (* Ctrl+Q *)
        OnMenuCmd(CmdQuit)
      ELSIF ORD(ch) = 9  THEN    (* Ctrl+Tab — ORD(TUI.KTab)=9, handled below *)
        (* actually Tab goes to editor; Ctrl+Tab would be different... *)
        (* Route Tab to the focused view via dispatch *)
        IF ~TUI.Dispatch(ev) THEN  END
      ELSIF ch = TUI.KF5  THEN   OnMenuCmd(CmdCompile)
      ELSIF ch = TUI.KF6  THEN   OnMenuCmd(CmdRun)
      ELSIF ch = TUI.KF9  THEN   OnMenuCmd(CmdCompRun)
      ELSIF ch = TUI.KF3  THEN   OnMenuCmd(CmdFindNext)
      ELSE
        IF ~TUI.Dispatch(ev) THEN  END
      END

    ELSIF ev.kind = TUI.EvMouse THEN
      IF ~TUI.Dispatch(ev) THEN  END

    ELSIF ev.kind = TUI.EvResize THEN
      sline.y := TUI.Rows;
      sline.w := TUI.Cols;
      mbar.w  := TUI.Cols;
      TileEditorWins();
      TUI.InvalidateFront()
    END
  END;

  TUI.Done()
END IDE.
