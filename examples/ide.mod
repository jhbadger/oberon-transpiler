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
 *   Ctrl+W          Kill region (cut selection)
 *   Ctrl+X          Close window
 *   Ctrl+Q          Quit
 *   F4              Toggle project panel
 *   F7              Next window
 *   F8              Toggle full screen for current window
 *   F5              Compile current file
 *   F9              Compile & run
 *   F1              Help on word under cursor
 *   Ctrl+F / F3     Find / find next
 *   Ctrl+R          Find & replace
 *   Ctrl+G          Go to line
 *   Ctrl+K / Ctrl+Y Kill line / yank
 *   Ctrl+Left/Right Word left / right
 * Emacs-style (in editor)
 *   Ctrl+Space      Set mark (start region); second press cancels
 *   Ctrl+W          Kill region (cut) when mark is set
 *   Ctrl+X          Close window
 *   Ctrl+A          Beginning of line
 *   Ctrl+E          End of line
 *   Ctrl+B          Backward char
 *   Ctrl+P          Previous line
 *   Ctrl+D          Delete forward char
 *)
IMPORT TUI, Widgets, FileDialog, Help, Strings, Terminal, ProjectPane, Files, OS, Out, Args;

CONST
ProjPaneW = 28;
MaxLines = 10000;
LLEN     = 512;    (* bytes per line — wide enough for UTF-8 *)
MaxWins  = 8;
MaxUndo  = 100;    (* undo history depth per editor window *)

(* ── Undo operation types ── *)
UOpEdit  = 1;   (* one line modified in place *)
UOpSplit = 2;   (* line split into two by Enter *)
UOpJoin  = 3;   (* two lines joined into one by Backspace/Delete at boundary *)
UOpBlock = 4;   (* block cut/paste — saves/restores a region of lines *)

(* ── Block undo snapshot limit ── *)
MaxBlockLines = 20;   (* lines per UOpBlock snapshot *)
MaxClipLines  = 200;  (* clipboard capacity *)

(* ── Menu command codes ── *)
CmdNew     = 10;   CmdOpen    = 11;   CmdSave    = 12;
CmdSaveAs  = 13;   CmdClose   = 14;   CmdQuit    = 15;
CmdUndo    = 19;
CmdFind    = 20;   CmdFindNext= 21;   CmdGoto    = 22;   CmdReplace = 23;
CmdCompile = 30;   CmdRun     = 31;   CmdCompRun = 32;
CmdNextWin = 40;   CmdTile    = 41;   CmdFullScreen = 42;
CmdHelp    = 50;
CmdJumpError = 51;
CmdCopy    = 60;   CmdCut     = 61;   CmdPaste   = 62;   CmdSelAll  = 63;
CmdReindent = 80;
CmdFocusPane = 90;
CmdTogglePane = 91;

(* ── Recent files ── *)
MaxRecent      = 8;
CmdRecentBase  = 70;   (* CmdRecentBase+0 .. CmdRecentBase+MaxRecent-1 *)

(* ── Autocomplete ── *)
MaxAcItems   = 200;
MaxAcVisible = 8;

TYPE
UndoEntry = RECORD
  op:       INTEGER;          (* UOpEdit / UOpSplit / UOpJoin / UOpBlock *)
  cy, cx:   INTEGER;          (* cursor position before the edit *)
  fromLine: INTEGER;          (* first affected line index *)
  line0:    ARRAY LLEN OF CHAR;  (* saved content of fromLine *)
  line1:    ARRAY LLEN OF CHAR;  (* saved content of fromLine+1 (UOpJoin only) *)
  (* UOpBlock fields *)
  blockNLines:    INTEGER;    (* lines in pre-op snapshot (<=MaxBlockLines) *)
  blockPostNLines: INTEGER;   (* lines in region after the op *)
  blockLines: ARRAY MaxBlockLines, LLEN OF CHAR
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
undoCount: INTEGER;   (* number of valid entries *)
(* selection *)
selActive:      BOOLEAN;
markMode:       BOOLEAN;   (* TRUE when set via Ctrl+Space; plain arrows extend region *)
selAnchorLine:  INTEGER;
selAnchorCol:   INTEGER;
(* mouse drag tracking *)
mouseSelDrag:   BOOLEAN
END;

(* ════════════════════════════════════════════════════════════════
   Module globals
   ════════════════════════════════════════════════════════════════ *)

VAR
pane:      ProjectPane.Pane;
paneShown: BOOLEAN;
mbar:      Widgets.MenuBar;
pendingMenuRebuild: BOOLEAN;
sline:     Widgets.StatusLine;
running:   BOOLEAN;
statusMsg: ARRAY 128 OF CHAR;
wins:      ARRAY MaxWins OF EditorWin;
winCount:  INTEGER;
lastEditor: EditorWin;       (* last editor that held focus — used when menu is active *)
zoomedWin: EditorWin;        (* window currently zoomed full-screen, NIL = tiled mode *)
pendingCloseWin: EditorWin; (* editor awaiting close confirmation *)
pendingClose:    BOOLEAN;   (* close-box click — processed in main loop *)
(* inline prompt state *)
promptMode: INTEGER;   (* 0=none 1=find 2=goto 3=confirmClose 4=confirmQuit
                            5=replaceSearch 6=replaceWith 7=replaceStep *)
promptBuf:  ARRAY 128 OF CHAR;
promptPos:  INTEGER;
replaceBuf: ARRAY 128 OF CHAR;
replacePos: INTEGER;
(* clipboard (module-level, shared across windows) *)
clipLines:  ARRAY MaxClipLines, LLEN OF CHAR;
clipNLines: INTEGER;
(* recent files *)
recentFiles: ARRAY MaxRecent, 512 OF CHAR;
recentCount: INTEGER;
(* last compiler error location *)
errorFile: ARRAY 512 OF CHAR;
errorLine: INTEGER;
(* autocomplete popup *)
acActive:  BOOLEAN;
acItems:   ARRAY MaxAcItems, 64 OF CHAR;
acCount:   INTEGER;
acSel:     INTEGER;
acScroll:  INTEGER;
acX, acY:  INTEGER;
acPrefix:  ARRAY 64 OF CHAR;
acPrefLen: INTEGER;

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

(* Save a block region r1..r2 before a cut or paste operation.
   postNLines = how many lines that region will span after the op
   (1 for cut, clipNLines for multi-line paste). *)
PROCEDURE PushBlockUndo(ew: EditorWin; r1, r2, postNLines: INTEGER);
VAR e, b, i: INTEGER;
BEGIN
  e := ew.undoTop;
  ew.undo[e].op             := UOpBlock;
  ew.undo[e].cy             := ew.cy;
  ew.undo[e].cx             := ew.cx;
  ew.undo[e].fromLine       := r1;
  ew.undo[e].blockPostNLines := postNLines;
  ew.undo[e].blockNLines    := r2 - r1 + 1;
  IF ew.undo[e].blockNLines > MaxBlockLines THEN
    ew.undo[e].blockNLines := MaxBlockLines
  END;
  FOR b := 0 TO ew.undo[e].blockNLines - 1 DO
    FOR i := 0 TO LLEN - 1 DO
      ew.undo[e].blockLines[b][i] := ew.lines[r1 + b][i]
    END
  END;
  ew.undoTop := (e + 1) MOD MaxUndo;
  IF ew.undoCount < MaxUndo THEN  INC(ew.undoCount)  END
END PushBlockUndo;

PROCEDURE DoUndo(ew: EditorWin);
VAR e, b, i, fromLine, n, postN: INTEGER;
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
  ELSIF ew.undo[e].op = UOpJoin THEN
    (* Reverse a line join: restore original line, re-insert the removed one *)
    FOR i := 0 TO LLEN - 1 DO
      ew.lines[fromLine][i] := ew.undo[e].line0[i]
    END;
    InsertLineAt(ew, fromLine + 1);
    FOR i := 0 TO LLEN - 1 DO
      ew.lines[fromLine + 1][i] := ew.undo[e].line1[i]
    END
  ELSE  (* UOpBlock: restore the saved region *)
  n     := ew.undo[e].blockNLines;
  postN := ew.undo[e].blockPostNLines;
  (* Adjust line count: post had postN lines in region, pre had n *)
  IF postN > n THEN
    (* Post added lines (paste): remove the extra ones *)
    FOR b := 1 TO postN - n DO  RemoveLine(ew, fromLine + n)  END
  ELSIF postN < n THEN
    (* Post removed lines (cut): re-insert the missing ones *)
    FOR b := postN TO n - 1 DO  InsertLineAt(ew, fromLine + b)  END
  END;
  (* Restore all saved lines *)
  FOR b := 0 TO n - 1 DO
    FOR i := 0 TO LLEN - 1 DO
      ew.lines[fromLine + b][i] := ew.undo[e].blockLines[b][i]
    END
  END;
  ew.modified := TRUE
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

  (* Measure leading whitespace on the current line for auto-indent. *)
  baseIndent := 0;
  WHILE (baseIndent < ew.cx) &
  ((ew.lines[ew.cy][baseIndent] = ' ') OR (ew.lines[ew.cy][baseIndent] = 09X)) DO
    INC(baseIndent)
  END;

  (* Smart indent: opener keywords add one extra level *)
  extra := 0;
  IF LineEndsWithOpener(ew, ew.cy, ew.cx) THEN extra := 2 END;
  totalIndent := baseIndent + extra;

  InsertLineAt(ew, ew.cy + 1);

  (* Copy the rest of the current line (suffix) after the split point *)
  FOR i := 0 TO rest - 1 DO 
    ew.lines[ew.cy + 1][i] := ew.lines[ew.cy][ew.cx + i] 
  END;
  ew.lines[ew.cy + 1][rest] := 0X; (* Terminate the new line suffix [cite: 853] *)

  (* Truncate the original line at the cursor *)
  ew.lines[ew.cy][ew.cx] := 0X; 

  (* Move cursor to the new line *)
  INC(ew.cy); 
  ew.cx := 0;

  (* Prepend indentation onto the new line *)
  IF (totalIndent > 0) & (totalIndent + rest < LLEN) THEN
    (* Shift the suffix (rest) to the right to make room for indentation *)
    FOR i := rest - 1 TO 0 BY -1 DO
      ew.lines[ew.cy][totalIndent + i] := ew.lines[ew.cy][i]
    END;

    (* Copy base indent characters (tabs/spaces) from the previous line *)
    FOR i := 0 TO baseIndent - 1 DO
      ew.lines[ew.cy][i] := ew.lines[ew.cy - 1][i]
    END;

    (* Fill the extra indent level (4 spaces) *)
    FOR i := baseIndent TO totalIndent - 1 DO
      ew.lines[ew.cy][i] := ' '
    END;

    (* CRITICAL FIX: Explicitly terminate the line after indent + rest *)
    (* This prevents "ghost" text from the copied line from appearing  *)
    ew.lines[ew.cy][totalIndent + rest] := 0X;

    ew.cx := totalIndent
  ELSE
    (* If no indent, ensure the line is just the rest of the text *)
    ew.lines[ew.cy][rest] := 0X;
    ew.cx := 0
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
  ELSE
    DoPaste(ew)
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

(* Replace the match at (ew.cy, ew.cx) with replaceBuf, then find next.
   Assumes srchBuf is non-empty and the cursor is sitting on a match.
   Returns TRUE if another match was found after the replacement. *)
PROCEDURE DoReplaceOne(ew: EditorWin): BOOLEAN;
VAR qlen, rlen: INTEGER;
BEGIN
  qlen := Strings.Length(ew.srchBuf);
  rlen := Strings.Length(replaceBuf);
  PushUndo(ew, UOpEdit, ew.cy);
  DeleteBytesAt(ew, ew.cy, ew.cx, qlen);
  IF rlen > 0 THEN
    InsertBytesAt(ew, ew.cy, ew.cx, replaceBuf, rlen)
  END;
  INC(ew.cx, rlen);
  RETURN DoFind(ew)
END DoReplaceOne;

(* Replace every occurrence from the beginning of the file. *)
PROCEDURE DoReplaceAll(ew: EditorWin): INTEGER;
VAR count, qlen, rlen: INTEGER;
BEGIN
  qlen := Strings.Length(ew.srchBuf);
  rlen := Strings.Length(replaceBuf);
  IF qlen = 0 THEN  RETURN 0  END;
  count := 0;
  ew.cy := 0;  ew.cx := 0;
  WHILE DoFind(ew) DO
    PushUndo(ew, UOpEdit, ew.cy);
    DeleteBytesAt(ew, ew.cy, ew.cx, qlen);
    IF rlen > 0 THEN
      InsertBytesAt(ew, ew.cy, ew.cx, replaceBuf, rlen)
    END;
    INC(ew.cx, rlen);
    INC(count);
    IF count > 10000 THEN  EXIT  END  (* safety *)
  END;
  RETURN count
END DoReplaceAll;

(* ════════════════════════════════════════════════════════════════
   Cursor management
   ════════════════════════════════════════════════════════════════ *)

PROCEDURE WordAtCursor(ew: EditorWin; VAR word: ARRAY OF CHAR);
VAR i, wStart, wEnd, len: INTEGER;
ch: CHAR;
more: BOOLEAN;
BEGIN
  word[0] := 0X;
  IF ew = NIL THEN  RETURN  END;
  len := LineLen(ew, ew.cy);
  (* Walk left while identifier chars (include '.' for Mod.Proc forms) *)
  i := ew.cx;  more := TRUE;
  WHILE more & (i > 0) DO
    ch := ew.lines[ew.cy][i - 1];
    IF ((ch >= 'A') & (ch <= 'Z')) OR ((ch >= 'a') & (ch <= 'z')) OR
    ((ch >= '0') & (ch <= '9')) OR (ch = '_') OR (ch = '.') THEN
      DEC(i)
    ELSE
      more := FALSE
    END
  END;
  wStart := i;
  (* Walk right while identifier chars (no '.' — right side is always ident-only) *)
  i := ew.cx;  more := TRUE;
  WHILE more & (i < len) DO
    ch := ew.lines[ew.cy][i];
    IF ((ch >= 'A') & (ch <= 'Z')) OR ((ch >= 'a') & (ch <= 'z')) OR
    ((ch >= '0') & (ch <= '9')) OR (ch = '_') THEN
      INC(i)
    ELSE
      more := FALSE
    END
  END;
  wEnd := i;
  IF wEnd > wStart THEN
    Strings.Extract(ew.lines[ew.cy], wStart, wEnd - wStart, word)
  END
END WordAtCursor;

(* ════════════════════════════════════════════════════════════════
   Autocomplete
   ════════════════════════════════════════════════════════════════ *)

(* Case-insensitive: does item start with prefix? *)
PROCEDURE AcMatch(item, prefix: ARRAY OF CHAR): BOOLEAN;
VAR i, plen: INTEGER;
ic, pc: CHAR;
BEGIN
  plen := Strings.Length(prefix);
  IF plen = 0 THEN  RETURN TRUE  END;
  IF Strings.Length(item) < plen THEN  RETURN FALSE  END;
  i := 0;
  WHILE i < plen DO
    ic := item[i];  pc := prefix[i];
    IF (ic >= 'A') & (ic <= 'Z') THEN  ic := CHR(ORD(ic) + 32)  END;
    IF (pc >= 'A') & (pc <= 'Z') THEN  pc := CHR(ORD(pc) + 32)  END;
    IF ic # pc THEN  RETURN FALSE  END;
    INC(i)
  END;
  RETURN TRUE
END AcMatch;

PROCEDURE AcHas(s: ARRAY OF CHAR): BOOLEAN;
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO acCount - 1 DO
    IF Strings.Compare(acItems[i], s) = 0 THEN  RETURN TRUE  END
  END;
  RETURN FALSE
END AcHas;

PROCEDURE TryKw(kw: ARRAY OF CHAR);
BEGIN
  IF AcMatch(kw, acPrefix) & ~AcHas(kw) & (acCount < MaxAcItems) THEN
    Strings.Copy(kw, acItems[acCount]);  INC(acCount)
  END
END TryKw;

PROCEDURE CollectAC(ew: EditorWin);
VAR li, i, wStart, llen, wLen: INTEGER;
ch: CHAR;
word: ARRAY 64 OF CHAR;
more: BOOLEAN;
BEGIN
  acCount := 0;
  IF Strings.Length(acPrefix) = 0 THEN  RETURN  END;

  (* Oberon keywords *)
  TryKw("ABS");     TryKw("ARRAY");   TryKw("ASR");     TryKw("ASSERT");
  TryKw("BEGIN");   TryKw("BOOLEAN"); TryKw("BY");      TryKw("BYTE");
  TryKw("CASE");    TryKw("CHAR");    TryKw("CHR");     TryKw("CONST");
  TryKw("COPY");    TryKw("DEC");     TryKw("DIV");     TryKw("DO");
  TryKw("ELSE");    TryKw("ELSIF");   TryKw("END");     TryKw("EXCL");
  TryKw("EXIT");    TryKw("FALSE");   TryKw("FLT");     TryKw("FOR");
  TryKw("HALT");    TryKw("IF");      TryKw("IMPORT");  TryKw("IN");
  TryKw("INC");     TryKw("INCL");    TryKw("INTEGER"); TryKw("IS");
  TryKw("LEN");     TryKw("LONGINT"); TryKw("LOOP");    TryKw("LSL");
  TryKw("MAX");     TryKw("MIN");     TryKw("MOD");     TryKw("MODULE");
  TryKw("NEW");     TryKw("NIL");     TryKw("ODD");     TryKw("OF");
  TryKw("OR");      TryKw("ORD");     TryKw("PACK");    TryKw("POINTER");
  TryKw("PROCEDURE"); TryKw("REAL");  TryKw("RECORD");  TryKw("REPEAT");
  TryKw("RETURN");  TryKw("ROR");     TryKw("SET");     TryKw("STRING");
  TryKw("TRUE");    TryKw("TYPE");    TryKw("UNPK");    TryKw("UNTIL");
  TryKw("VAR");     TryKw("WITH");    TryKw("WHILE");

  (* Identifiers from the current file *)
  FOR li := 0 TO ew.nlines - 1 DO
    llen := LineLen(ew, li);
    i    := 0;
    WHILE i < llen DO
      ch := ew.lines[li][i];
      IF ((ch >= 'A') & (ch <= 'Z')) OR ((ch >= 'a') & (ch <= 'z')) OR (ch = '_') THEN
        wStart := i;
        more   := TRUE;
        WHILE more DO
          INC(i);
          IF i >= llen THEN  more := FALSE
        ELSE
          ch := ew.lines[li][i];
          IF ~(((ch >= 'A') & (ch <= 'Z')) OR ((ch >= 'a') & (ch <= 'z')) OR
          ((ch >= '0') & (ch <= '9')) OR (ch = '_')) THEN
            more := FALSE
          END
        END
      END;
      wLen := i - wStart;
      IF (wLen >= 2) & (wLen <= 62) THEN
        Strings.Extract(ew.lines[li], wStart, wLen, word);
        IF AcMatch(word, acPrefix) & ~AcHas(word) & (acCount < MaxAcItems) THEN
          Strings.Copy(word, acItems[acCount]);  INC(acCount)
        END
      END
    ELSE
      INC(i)
    END
  END
END
END CollectAC;

PROCEDURE TriggerAC(ew: EditorWin);
VAR i: INTEGER;
ch: CHAR;
more: BOOLEAN;
sx, sy, vis, popH: INTEGER;
BEGIN
  (* Extract partial word to the LEFT of cursor *)
  i := ew.cx;  more := TRUE;
  WHILE more & (i > 0) DO
    ch := ew.lines[ew.cy][i - 1];
    IF ((ch >= 'A') & (ch <= 'Z')) OR ((ch >= 'a') & (ch <= 'z')) OR
    ((ch >= '0') & (ch <= '9')) OR (ch = '_') THEN
      DEC(i)
    ELSE
      more := FALSE
    END
  END;
  acPrefLen := ew.cx - i;
  Strings.Extract(ew.lines[ew.cy], i, acPrefLen, acPrefix);

  CollectAC(ew);

  IF acCount = 0 THEN  acActive := FALSE;  RETURN  END;

  acSel    := 0;
  acScroll := 0;
  acActive := TRUE;

  (* Position popup just below the cursor *)
  CursorScreenPos(ew, sx, sy);
  acX := sx;
  acY := sy + 1;

  vis  := acCount;  IF vis > MaxAcVisible THEN  vis := MaxAcVisible  END;
  popH := vis + 2;
  IF acY + popH - 1 > TUI.Rows THEN  acY := sy - popH  END;
  IF acY < 1 THEN  acY := 1  END;
  IF acX + 18 > TUI.Cols THEN  acX := TUI.Cols - 18  END;
  IF acX < 1 THEN  acX := 1  END
END TriggerAC;

PROCEDURE AcceptAC(ew: EditorWin);
VAR suffix: ARRAY 64 OF CHAR;
suffLen: INTEGER;
BEGIN
  IF (acSel < 0) OR (acSel >= acCount) THEN  RETURN  END;
  suffLen := Strings.Length(acItems[acSel]) - acPrefLen;
  IF suffLen <= 0 THEN  RETURN  END;
  Strings.Extract(acItems[acSel], acPrefLen, suffLen, suffix);
  PushUndo(ew, UOpEdit, ew.cy);
  InsertBytesAt(ew, ew.cy, ew.cx, suffix, suffLen);
  INC(ew.cx, suffLen)
END AcceptAC;

PROCEDURE DrawAC;
VAR popW, popH, vis, i, row: INTEGER;
fg, bg: INTEGER;
item: ARRAY 64 OF CHAR;
BEGIN
  vis := acCount;
  IF vis > MaxAcVisible THEN  vis := MaxAcVisible  END;
  popH := vis + 2;

  (* Width: longest visible item + 2-char border, capped at 64 *)
  popW := 16;
  FOR i := acScroll TO acScroll + vis - 1 DO
    IF (i < acCount) & (Strings.Length(acItems[i]) + 2 > popW) THEN
      popW := Strings.Length(acItems[i]) + 2
    END
  END;
  IF popW > 64 THEN  popW := 64  END;
  IF acX + popW - 1 > TUI.Cols THEN  popW := TUI.Cols - acX + 1  END;
  IF popW < 4 THEN  popW := 4  END;

  TUI.DrawBox(acX, acY, popW, popH, TUI.Cyan, TUI.Black);

  FOR i := 0 TO vis - 1 DO
    row := acScroll + i;
    IF row < acCount THEN
      IF row = acSel THEN  fg := TUI.Black;  bg := TUI.White
    ELSE                 fg := TUI.White;  bg := TUI.Black
  END;
  TUI.FillRect(acX + 1, acY + 1 + i, popW - 2, 1, ' ', fg, bg);
  Strings.Extract(acItems[row], 0, popW - 2, item);
  TUI.PutStr(acX + 1, acY + 1 + i, item, fg, bg)
END
END
END DrawAC;

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
  innerW := ew.w - 2 - GutterW(ew);
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
   Selection and clipboard
   ════════════════════════════════════════════════════════════════ *)

PROCEDURE ClearSel(ew: EditorWin);
BEGIN  ew.selActive := FALSE;  ew.markMode := FALSE  END ClearSel;

PROCEDURE StartSel(ew: EditorWin);
BEGIN
  ew.selAnchorLine := ew.cy;
  ew.selAnchorCol  := ew.cx;
  ew.selActive     := TRUE
END StartSel;

(* Return selection start (r1,c1) and end (r2,c2) in document order. *)
PROCEDURE SelNorm(ew: EditorWin; VAR r1, c1, r2, c2: INTEGER);
BEGIN
  IF (ew.selAnchorLine < ew.cy) OR
  ((ew.selAnchorLine = ew.cy) & (ew.selAnchorCol <= ew.cx)) THEN
    r1 := ew.selAnchorLine;  c1 := ew.selAnchorCol;
    r2 := ew.cy;             c2 := ew.cx
  ELSE
    r1 := ew.cy;             c1 := ew.cx;
    r2 := ew.selAnchorLine;  c2 := ew.selAnchorCol
  END
END SelNorm;

(* Is byte byteI on line li inside the current selection? *)
PROCEDURE InSel(ew: EditorWin; li, byteI: INTEGER): BOOLEAN;
VAR r1, c1, r2, c2: INTEGER;
BEGIN
  IF ~ew.selActive THEN  RETURN FALSE  END;
  SelNorm(ew, r1, c1, r2, c2);
  IF (li < r1) OR (li > r2) THEN  RETURN FALSE  END;
  IF r1 = r2 THEN  RETURN (byteI >= c1) & (byteI < c2)  END;
  IF li = r1 THEN  RETURN byteI >= c1  END;
  IF li = r2 THEN  RETURN byteI < c2   END;
  RETURN TRUE   (* middle lines: fully selected *)
END InSel;

(* Delete the current selection; push undo; cursor moves to selection start. *)
PROCEDURE DeleteSel(ew: EditorWin);
VAR r1, c1, r2, c2, i, slen: INTEGER;
suffix: ARRAY LLEN OF CHAR;
BEGIN
  IF ~ew.selActive THEN  RETURN  END;
  SelNorm(ew, r1, c1, r2, c2);
  ew.cy := r1;  ew.cx := c1;
  IF r1 = r2 THEN
    PushUndo(ew, UOpEdit, r1);
    DeleteBytesAt(ew, r1, c1, c2 - c1)
  ELSE
    PushBlockUndo(ew, r1, r2, 1);
    slen := LineLen(ew, r2) - c2;
    FOR i := 0 TO slen - 1 DO  suffix[i] := ew.lines[r2][c2 + i]  END;
    suffix[slen] := 0X;
    ew.lines[r1][c1] := 0X;
    FOR i := 0 TO slen - 1 DO  ew.lines[r1][c1 + i] := suffix[i]  END;
    ew.lines[r1][c1 + slen] := 0X;
    FOR i := 1 TO r2 - r1 DO  RemoveLine(ew, r1 + 1)  END
  END;
  ClearSel(ew);
  ClampCursor(ew)
END DeleteSel;

(* Write internal clipboard to system clipboard via OSC 52 + command fallback. *)
PROCEDURE SysClipCopy;
VAR f: Files.File;  r: Files.Rider;
li, j: INTEGER;  ch: CHAR;
BEGIN
  f := Files.New(".obc_clipboard");
  IF f = NIL THEN  RETURN  END;
  Files.Set(r, f, 0);
  FOR li := 0 TO clipNLines - 1 DO
    j := 0;
    WHILE clipLines[li][j] # 0X DO
      Files.Write(r, clipLines[li][j]);
      INC(j)
    END;
    IF li < clipNLines - 1 THEN
      Files.Write(r, 0AX)   (* newline between lines *)
    END
  END;
  Files.Register(f);
  (* OSC 52 write — works in most terminals including over SSH *)
  OS.ClipWriteFile(".obc_clipboard");
  (* also try native clipboard commands as secondary path *)
  OS.Exec("pbcopy < .obc_clipboard 2>/dev/null; wl-copy < .obc_clipboard 2>/dev/null; xclip -selection clipboard < .obc_clipboard 2>/dev/null; true");
END SysClipCopy;

(* Try to load system clipboard into internal clipboard. *)
PROCEDURE SysClipPaste;
VAR f: Files.File;  r: Files.Rider;
ch: CHAR;  li, j: INTEGER;  done: BOOLEAN;
newLines: ARRAY MaxClipLines, LLEN OF CHAR;
newCount: INTEGER;
BEGIN
  OS.ClipPasteCmd(".obc_clipboard");
  f := Files.Old(".obc_clipboard");
  IF f = NIL THEN  RETURN  END;
  Files.Set(r, f, 0);
  li := 0;  j := 0;  newCount := 0;  done := FALSE;
  newLines[0][0] := 0X;
  WHILE ~done & (li < MaxClipLines) DO
    Files.Read(r, ch);
    IF r.eof THEN
      newLines[li][j] := 0X;
      IF j > 0 THEN  INC(li)  END;
      done := TRUE
    ELSIF ch = 0AX THEN
      newLines[li][j] := 0X;
      INC(li);  j := 0;
      IF li < MaxClipLines THEN  newLines[li][0] := 0X  END
    ELSIF j < LLEN - 1 THEN
      newLines[li][j] := ch;
      INC(j)
    END
  END;
  Files.Close(f);
  (* Only replace internal clipboard if we actually read something *)
  IF li > 0 THEN
    FOR j := 0 TO li - 1 DO
      newCount := 0;
      WHILE newCount < LLEN DO
        clipLines[j][newCount] := newLines[j][newCount];
        INC(newCount)
      END
    END;
    clipNLines := li
  END
END SysClipPaste;
                                                                                                                                                      

(* Copy selection into the module clipboard. *)
PROCEDURE DoCopy(ew: EditorWin);
VAR r1, c1, r2, c2, li, j, n: INTEGER;
BEGIN
  IF ~ew.selActive THEN  RETURN  END;
  SelNorm(ew, r1, c1, r2, c2);
  IF r1 = r2 THEN
    n := c2 - c1;
    FOR j := 0 TO n - 1 DO  clipLines[0][j] := ew.lines[r1][c1 + j]  END;
    clipLines[0][n] := 0X;
    clipNLines := 1
  ELSE
    clipNLines := r2 - r1 + 1;
    IF clipNLines > MaxClipLines THEN  clipNLines := MaxClipLines  END;
    (* First partial line *)
    n := LineLen(ew, r1) - c1;
    FOR j := 0 TO n - 1 DO  clipLines[0][j] := ew.lines[r1][c1 + j]  END;
    clipLines[0][n] := 0X;
    (* Middle lines: full copy *)
    FOR li := 1 TO clipNLines - 2 DO
      FOR j := 0 TO LLEN - 1 DO  clipLines[li][j] := ew.lines[r1 + li][j]  END
    END;
    (* Last partial line: bytes 0..c2-1 *)
    FOR j := 0 TO c2 - 1 DO  clipLines[clipNLines - 1][j] := ew.lines[r2][j]  END;
    clipLines[clipNLines - 1][c2] := 0X
  END;
  SysClipCopy
END DoCopy;

(* Cut: copy selection to clipboard then delete it. *)
PROCEDURE DoCut(ew: EditorWin);
BEGIN
  IF ~ew.selActive THEN  RETURN  END;
  DoCopy(ew);
  DeleteSel(ew)
END DoCut;

(* Paste clipboard at cursor; replaces selection if any. *)
PROCEDURE DoPaste(ew: EditorWin);
VAR clen, slen, j, b, lastLen: INTEGER;
suffix: ARRAY LLEN OF CHAR;
BEGIN
  SysClipPaste;  (* try to load from system clipboard first *)
  IF clipNLines = 0 THEN  RETURN  END;
  IF ew.selActive THEN  DeleteSel(ew)  END;
  IF clipNLines = 1 THEN
    clen := Strings.Length(clipLines[0]);
    IF clen > 0 THEN
      PushUndo(ew, UOpEdit, ew.cy);
      InsertBytesAt(ew, ew.cy, ew.cx, clipLines[0], clen);
      INC(ew.cx, clen)
    END
  ELSE
    (* Save the part of the current line after the cursor *)
    slen := LineLen(ew, ew.cy) - ew.cx;
    FOR j := 0 TO slen - 1 DO  suffix[j] := ew.lines[ew.cy][ew.cx + j]  END;
    suffix[slen] := 0X;
    PushBlockUndo(ew, ew.cy, ew.cy, clipNLines);
    (* First line: existing[0..cx-1] + clipLines[0] *)
    ew.lines[ew.cy][ew.cx] := 0X;
    clen := Strings.Length(clipLines[0]);
    FOR j := 0 TO clen - 1 DO
      IF ew.cx + j < LLEN - 1 THEN
        ew.lines[ew.cy][ew.cx + j] := clipLines[0][j]
      END
    END;
    ew.lines[ew.cy][ew.cx + clen] := 0X;
    (* Insert clipNLines-1 new lines after the current one *)
    FOR b := 1 TO clipNLines - 1 DO
      InsertLineAt(ew, ew.cy + b)
    END;
    (* Fill middle lines *)
    FOR b := 1 TO clipNLines - 2 DO
      FOR j := 0 TO LLEN - 1 DO  ew.lines[ew.cy + b][j] := clipLines[b][j]  END
    END;
    (* Last line: clipLines[clipNLines-1] + suffix *)
    b       := clipNLines - 1;
    lastLen := Strings.Length(clipLines[b]);
    FOR j := 0 TO lastLen - 1 DO  ew.lines[ew.cy + b][j] := clipLines[b][j]  END;
    FOR j := 0 TO slen - 1 DO
      IF lastLen + j < LLEN - 1 THEN
        ew.lines[ew.cy + b][lastLen + j] := suffix[j]
      END
    END;
    ew.lines[ew.cy + b][lastLen + slen] := 0X;
    INC(ew.cy, b);
    ew.cx := lastLen
  END;
  ew.modified := TRUE
END DoPaste;

(* Select the entire buffer. *)
PROCEDURE DoSelAll(ew: EditorWin);
BEGIN
  ew.selAnchorLine := 0;
  ew.selAnchorCol  := 0;
  ew.selActive     := TRUE;
  ew.cy := ew.nlines - 1;
  ew.cx := LineLen(ew, ew.cy)
END DoSelAll;

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
    removed := 2;
    IF removed > indent THEN  removed := indent  END;
    DeleteBytesAt(ew, ew.cy, 0, removed);
    DEC(ew.cx, removed)
  END
END CheckAutoDeindent;

(* Re-indent every line in the buffer using the same rules as auto-indent:
   dedent keywords (END UNTIL ELSE ELSIF) pull the line back one level;
   opener keywords (BEGIN THEN ELSE DO REPEAT RECORD OF WITH LOOP) push
   the next line forward one level.  Lines inside block comments are skipped. *)
PROCEDURE DoReindent(ew: EditorWin);
VAR li, indent, curIndent, newIndent, len, pos, wLen, k: INTEGER;
spaces: ARRAY LLEN OF CHAR;
w: ARRAY 16 OF CHAR;
BEGIN
  ComputeDepths(ew);
  indent := 0;
  FOR li := 0 TO ew.nlines - 1 DO
    IF ew.cmtDepth[li] = 0 THEN
      len := LineLen(ew, li);
      pos := 0;
      WHILE (pos < len) & (ew.lines[li][pos] = ' ') DO  INC(pos)  END;
      IF pos < len THEN
        wLen := 0;  k := pos;
        WHILE (k < len) & (wLen < 15) &
        (((ew.lines[li][k] >= 'A') & (ew.lines[li][k] <= 'Z')) OR
        ((ew.lines[li][k] >= 'a') & (ew.lines[li][k] <= 'z'))) DO
          w[wLen] := ew.lines[li][k];  INC(wLen);  INC(k)
        END;
        w[wLen] := 0X;
        newIndent := indent;
        IF (Strings.Compare(w, "END")   = 0) OR
        (Strings.Compare(w, "UNTIL") = 0) OR
        (Strings.Compare(w, "ELSE")  = 0) OR
        (Strings.Compare(w, "ELSIF") = 0) THEN
          IF newIndent >= 2 THEN  DEC(newIndent, 2)  ELSE  newIndent := 0  END
        END;
        curIndent := pos;
        IF curIndent # newIndent THEN
          PushUndo(ew, UOpEdit, li);
          DeleteBytesAt(ew, li, 0, curIndent);
          FOR k := 0 TO newIndent - 1 DO  spaces[k] := ' '  END;
          IF newIndent > 0 THEN
            InsertBytesAt(ew, li, 0, spaces, newIndent)
          END
        END;
        indent := newIndent;
        IF LineEndsWithOpener(ew, li, LineLen(ew, li)) THEN
          INC(indent, 2)
        END
      END
    END
  END;
  IF ew.cx > LineLen(ew, ew.cy) THEN  ew.cx := LineLen(ew, ew.cy)  END;
  ScrollToCursor(ew);
  Strings.Copy("Reindented.", statusMsg)
END DoReindent;

(* ════════════════════════════════════════════════════════════════
   Rendering
   ════════════════════════════════════════════════════════════════ *)

(* Width of the line-number gutter: digits needed for nlines + 1 separator. *)
PROCEDURE GutterW(ew: EditorWin): INTEGER;
VAR n, w: INTEGER;
BEGIN
  n := ew.nlines;  w := 1;
  WHILE n >= 10 DO  n := n DIV 10;  INC(w)  END;
  RETURN w + 1
END GutterW;

(* Draw the gutter cell for one editor row.
   gx = leftmost gutter column, gw = total gutter width,
   li = line index (0-based), currentLine = cursor line. *)
PROCEDURE DrawGutter(gx, y, gw, li, currentLine: INTEGER);
VAR numBuf: ARRAY 8 OF CHAR;
nlen, pad, i: INTEGER;
fg: INTEGER;
BEGIN
  Strings.IntToStr(li + 1, numBuf);
  nlen := Strings.Length(numBuf);
  pad  := gw - 1 - nlen;
  IF li = currentLine THEN  fg := TUI.Yellow  ELSE  fg := TUI.White  END;
  FOR i := 0 TO pad - 1 DO
    TUI.PutCell(gx + i, y, ' ', fg, TUI.Black)
  END;
  FOR i := 0 TO nlen - 1 DO
    TUI.PutCell(gx + pad + i, y, numBuf[i], fg, TUI.Black)
  END;
  TUI.PutCell(gx + gw - 1, y, TUI.BoxV, TUI.White, TUI.Black)
END DrawGutter;

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
vc, leftVcol, seqLen: INTEGER;
c2, c3, c4: CHAR;
bg: INTEGER;
BEGIN
  len      := LineLen(ew, li);
  leftVcol := ByteToCol(ew.lines[li], leftByte);

  depth        := cmtD;
  inStr        := FALSE;
  closingParen := FALSE;
  kwEnd        := 0;
  kwFg         := TUI.White;

  vc := 0;  (* visual column, one per logical character *)
  i  := 0;
  WHILE i < len DO
    ch := ew.lines[li][i];

    IF IsUtf8Cont(ch) THEN
      (* Unexpected bare continuation byte (malformed UTF-8): skip. *)
      INC(i)
    ELSE
      (* Determine byte-length of this UTF-8 sequence. *)
      IF    ORD(ch) >= 0F0H THEN  seqLen := 4
    ELSIF ORD(ch) >= 0E0H THEN  seqLen := 3
  ELSIF ORD(ch) >= 0C0H THEN  seqLen := 2
ELSE                        seqLen := 1
END;

(* nextCh: first byte of the following logical character. *)
IF i + seqLen < len THEN  nextCh := ew.lines[li][i + seqLen]
ELSE                      nextCh := 0X
END;

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
ELSIF (ch >= 'A') & (ch <= 'Z') THEN
  (* Scan ahead for the full identifier (ASCII only). *)
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
ELSE
  fg := TUI.White
END;

(* ── Output into the TUI back buffer if in the visible column range ── *)
sc := vc - leftVcol;
IF (sc >= 0) & (sc < innerW) THEN
  IF InSel(ew, li, i) THEN  bg := TUI.Blue  ELSE  bg := TUI.Black  END;
  (* Gather continuation bytes so the whole sequence lives in one cell. *)
  c2 := 0X;  c3 := 0X;  c4 := 0X;
  IF (seqLen >= 2) & (i + 1 < len) THEN  c2 := ew.lines[li][i + 1]  END;
  IF (seqLen >= 3) & (i + 2 < len) THEN  c3 := ew.lines[li][i + 2]  END;
  IF (seqLen >= 4) & (i + 3 < len) THEN  c4 := ew.lines[li][i + 3]  END;
  IF c2 = 0X THEN
    TUI.PutCell(innerX + sc, sy, ch, fg, bg)
  ELSE
    TUI.PutCellMB(innerX + sc, sy, ch, c2, c3, c4, fg, bg)
  END
END;

INC(vc);
i := i + seqLen
END
END
(* Cells beyond line length remain as spaces from DrawEditor's FillRect. *)
END RenderEdLine;

(* Draw an editor window — called by TUI.DrawAll via the view's draw proc. *)
PROCEDURE DrawEditor(v: TUI.View);
VAR innerX, innerY, innerW, innerH, row, li, gw: INTEGER;
titleBuf: ARRAY 260 OF CHAR;
tlen, tx, borderFg, borderBg, titleFg: INTEGER;
BEGIN
  WITH v: EditorWinRec DO
    gw     := GutterW(v);
    innerX := v.x + 1 + gw;
    innerY := v.y + 1;
    innerW := v.w - 2 - gw;
    innerH := v.h - 2;

    (* ── Border colour depends on focus ── *)
    IF v.focused THEN
      borderFg := TUI.White;  borderBg := TUI.Blue;  titleFg := TUI.Yellow
    ELSE
      borderFg := TUI.White;  borderBg := TUI.Black;  titleFg := TUI.White
    END;

    (* ── Clear interior (gutter + text area) ── *)
    TUI.FillRect(v.x + 1, innerY, v.w - 2, innerH, ' ', TUI.White, TUI.Black);

    (* ── Border ── *)
    TUI.DrawBox(v.x, v.y, v.w, v.h, borderFg, borderBg);

    (* ── Close box [×] on title bar ── *)
    TUI.PutStr(v.x + 1, v.y, "[x]", TUI.Red, borderBg);

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

(* ── Gutter + editor content ── *)
ComputeDepths(v);
FOR row := 0 TO innerH - 1 DO
  li := v.topLine + row;
  IF li < v.nlines THEN
    DrawGutter(v.x + 1, innerY + row, gw, li, v.cy);
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

      (* ── Plain movement: clear selection unless in mark mode ── *)
      IF ch = TUI.KUp THEN
        IF ~v.markMode THEN  ClearSel(v)  END;
        DEC(v.cy);  ClampCursor(v)
      ELSIF ch = TUI.KDown THEN
        IF ~v.markMode THEN  ClearSel(v)  END;
        INC(v.cy);  ClampCursor(v)
      ELSIF ch = TUI.KLeft THEN
        IF ~v.markMode THEN  ClearSel(v)  END;
        IF v.cx > 0 THEN  Utf8Back(v.lines[v.cy], v.cx)
      ELSIF v.cy > 0 THEN  DEC(v.cy);  v.cx := LineLen(v, v.cy)
    END
  ELSIF ch = TUI.KRight THEN
    IF ~v.markMode THEN  ClearSel(v)  END;
    IF v.cx < LineLen(v, v.cy) THEN  Utf8Fwd(v.lines[v.cy], v.cx)
  ELSIF v.cy < v.nlines - 1 THEN  INC(v.cy);  v.cx := 0
END
ELSIF ch = TUI.KHome THEN
  IF ~v.markMode THEN  ClearSel(v)  END;
  v.cy := 0;  v.cx := 0
ELSIF ch = TUI.KEnd THEN
  IF ~v.markMode THEN  ClearSel(v)  END;
  v.cy := v.nlines - 1;  v.cx := LineLen(v, v.cy)
ELSIF ch = TUI.KCtrlHome THEN
  IF ~v.markMode THEN  ClearSel(v)  END;
  v.cx := 0
ELSIF ch = TUI.KCtrlEnd THEN
  IF ~v.markMode THEN  ClearSel(v)  END;
  v.cx := LineLen(v, v.cy)
ELSIF ch = TUI.KCtrlLeft THEN
  IF ~v.markMode THEN  ClearSel(v)  END;
  WordLeft(v)
ELSIF ch = TUI.KCtrlRight THEN
  IF ~v.markMode THEN  ClearSel(v)  END;
  WordRight(v)
ELSIF ch = TUI.KPgUp THEN
  IF ~v.markMode THEN  ClearSel(v)  END;
  DEC(v.cy, v.h - 2);  ClampCursor(v)
ELSIF ch = TUI.KPgDn THEN
  IF ~v.markMode THEN  ClearSel(v)  END;
  INC(v.cy, v.h - 2);  ClampCursor(v)

  (* ── Shift+Arrow: extend selection ── *)
ELSIF ch = TUI.KShiftLeft THEN
  IF ~v.selActive THEN  StartSel(v)  END;
  IF v.cx > 0 THEN  Utf8Back(v.lines[v.cy], v.cx)
ELSIF v.cy > 0 THEN  DEC(v.cy);  v.cx := LineLen(v, v.cy)
END
ELSIF ch = TUI.KShiftRight THEN
  IF ~v.selActive THEN  StartSel(v)  END;
  IF v.cx < LineLen(v, v.cy) THEN  Utf8Fwd(v.lines[v.cy], v.cx)
ELSIF v.cy < v.nlines - 1 THEN  INC(v.cy);  v.cx := 0
END
ELSIF ch = TUI.KShiftUp THEN
  IF ~v.selActive THEN  StartSel(v)  END;
  DEC(v.cy);  ClampCursor(v)
ELSIF ch = TUI.KShiftDown THEN
  IF ~v.selActive THEN  StartSel(v)  END;
  INC(v.cy);  ClampCursor(v)

  (* ── Editing: delete selection first where applicable ── *)
ELSIF ch = TUI.KEnter THEN
  IF v.selActive THEN  DeleteSel(v)  END;
  DoEnter(v)
ELSIF ch = TUI.KBackspace THEN
  IF v.selActive THEN  DeleteSel(v)
ELSE  DoBackspace(v)
END
ELSIF ch = TUI.KDel THEN
  IF v.selActive THEN  DeleteSel(v)
ELSE  DoDelete(v)
END
ELSIF ch = TUI.KTab THEN
  IF v.selActive THEN  DeleteSel(v)  END;
  PushUndo(v, UOpEdit, v.cy);
  bytes[0] := ' ';  bytes[1] := ' ';  bytes[2] := ' ';  bytes[3] := ' ';
  InsertBytesAt(v, v.cy, v.cx, bytes, 4);
  INC(v.cx, 4)

  (* ── Control commands ── *)
ELSIF ORD(ch) = 1  THEN  ClearSel(v);  v.cx := 0  (* Ctrl+A: line beginning *)
ELSIF ORD(ch) = 2  THEN                            (* Ctrl+B: backward char  *)
ClearSel(v);
IF v.cx > 0 THEN  Utf8Back(v.lines[v.cy], v.cx)
ELSIF v.cy > 0 THEN  DEC(v.cy);  v.cx := LineLen(v, v.cy)
END
ELSIF ORD(ch) = 3  THEN  DoCopy(v)         (* Ctrl+C: copy        *)
ELSIF ORD(ch) = 4  THEN                    (* Ctrl+D: delete forward char *)
IF v.selActive THEN  DeleteSel(v)  ELSE  DoDelete(v)  END
ELSIF ORD(ch) = 5  THEN  ClearSel(v);  v.cx := LineLen(v, v.cy)  (* Ctrl+E: line end *)
ELSIF ORD(ch) = 16 THEN  ClearSel(v);  DEC(v.cy);  ClampCursor(v) (* Ctrl+P: prev line *)
ELSIF ORD(ch) = 22 THEN  DoPaste(v)        (* Ctrl+V: paste       *)
ELSIF ORD(ch) = 24 THEN  DoCut(v)          (* Ctrl+X: cut         *)
ELSIF ORD(ch) = 11 THEN  ClearSel(v);  DoKillLine(v)  (* Ctrl+K  *)
ELSIF ORD(ch) = 25 THEN  ClearSel(v);  DoYank(v)      (* Ctrl+Y  *)
ELSIF ORD(ch) = 26 THEN  ClearSel(v);  DoUndo(v)      (* Ctrl+Z  *)
ELSIF ORD(ch) = 6  THEN                    (* Ctrl+F: find        *)
promptMode := 1;
promptBuf[0] := 0X;  promptPos := 0;
Strings.Copy("Find: ", statusMsg)
ELSIF ORD(ch) = 7  THEN                    (* Ctrl+G: goto line   *)
promptMode := 2;
promptBuf[0] := 0X;  promptPos := 0;
Strings.Copy("Go to line: ", statusMsg)
ELSIF ORD(ch) = 18 THEN                    (* Ctrl+R: replace     *)
promptMode := 5;
promptBuf[0] := 0X;  promptPos := 0;
replaceBuf[0] := 0X;  replacePos := 0;
Strings.Copy("Find: ", statusMsg)

(* ── Printable characters ── *)
ELSIF (ORD(ch) >= 32) & (ORD(ch) < 127) THEN
  IF v.selActive THEN  DeleteSel(v)  END;
  PushUndo(v, UOpEdit, v.cy);
  bytes[0] := ch;
  InsertBytesAt(v, v.cy, v.cx, bytes, 1);
  INC(v.cx);
  CheckAutoDeindent(v)
END;
ScrollToCursor(v);
RETURN TRUE

ELSIF ev.kind = TUI.EvMouse THEN
  IF (ev.mb = 0) & (ev.my = v.y) &   (* close-box click *)
  (ev.mx >= v.x + 1) & (ev.mx <= v.x + 3) THEN
    pendingClose := TRUE;
    RETURN TRUE
  ELSIF ev.mb = 64 THEN       (* wheel up *)
  IF v.topLine > 0 THEN  DEC(v.topLine, 3) END;
  IF v.topLine < 0 THEN  v.topLine := 0 END
ELSIF ev.mb = 65 THEN    (* wheel down *)
INC(v.topLine, 3);
IF v.topLine > v.nlines - 1 THEN  v.topLine := v.nlines - 1 END
ELSIF (ev.mb = 0) &      (* left press inside content area *)
(ev.mx >= v.x + 1) & (ev.mx <= v.x + v.w - 2) &
(ev.my >= v.y + 1) & (ev.my <= v.y + v.h - 2) THEN
  ClearSel(v);
  v.cy := v.topLine + (ev.my - v.y - 1);
  IF ev.mx < v.x + 1 + GutterW(v) THEN
    v.cx := 0
  ELSE
    v.cx := v.leftCol + (ev.mx - v.x - 1 - GutterW(v))
  END;
  ClampCursor(v);  ScrollToCursor(v);
  (* Remember anchor for drag; selActive stays FALSE until drag moves *)
  v.selAnchorLine := v.cy;  v.selAnchorCol := v.cx;
  v.mouseSelDrag  := TRUE
ELSIF (ev.mb = 32) & v.mouseSelDrag &   (* drag with left button *)
(ev.mx >= v.x + 1) & (ev.mx <= v.x + v.w - 2) &
(ev.my >= v.y + 1) & (ev.my <= v.y + v.h - 2) THEN
  IF ~v.selActive THEN  v.selActive := TRUE  END;
  v.cy := v.topLine + (ev.my - v.y - 1);
  IF ev.mx < v.x + 1 + GutterW(v) THEN
    v.cx := 0
  ELSE
    v.cx := v.leftCol + (ev.mx - v.x - 1 - GutterW(v))
  END;
  ClampCursor(v)
ELSIF ev.mb = 3 THEN     (* any release *)
v.mouseSelDrag := FALSE
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
VAR i, n, row, col, cellW, cellH, x, y, edLeft, edCols: INTEGER;
ewArr: ARRAY MaxWins OF EditorWin;
BEGIN
  n := 0;
  FOR i := 0 TO MaxWins - 1 DO
    IF wins[i] # NIL THEN  ewArr[n] := wins[i];  INC(n)  END
  END;
  IF n = 0 THEN  RETURN  END;

  IF (pane # NIL) & paneShown THEN
    edLeft := ProjPaneW + 1;
    edCols := TUI.Cols - ProjPaneW
  ELSE
    edLeft := 1;
    edCols := TUI.Cols
  END;

  IF n = 1 THEN  col := 1;  row := 1
ELSE           col := 2;  row := (n + 1) DIV 2
END;
cellW := edCols DIV col;
cellH := (TUI.Rows - 2) DIV row;

FOR i := 0 TO n - 1 DO
  x := edLeft + (i MOD col) * cellW;
  y := (i DIV col) * cellH + 2;
  ewArr[i].x := x;       ewArr[i].y := y;
  ewArr[i].w := cellW;   ewArr[i].h := cellH
END;
zoomedWin := NIL;
TUI.InvalidateFront();
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
  ew.selActive    := FALSE;
  ew.markMode     := FALSE;
  ew.mouseSelDrag := FALSE;
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
  IF zoomedWin = ew THEN  zoomedWin := NIL  END;
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

(* Zoom the focused window to full desktop area, hiding others.
   Calling again (or Tile Windows) restores the tiled layout. *)
PROCEDURE ZoomCurrentWin;
VAR ew: EditorWin;
i: INTEGER;
BEGIN
  ew := FocusedEditor();
  IF ew = NIL THEN  ew := lastEditor  END;
  IF ew = NIL THEN  RETURN  END;

  IF zoomedWin # NIL THEN
    (* Un-zoom: restore tiled layout *)
    TileEditorWins;
    TUI.BringToFront(ew);
    TUI.SetFocus(ew);
    COPY("Tiled.", statusMsg)
  ELSE
    (* Zoom: expand ew to full desktop, push all others off-screen *)
    zoomedWin := ew;
    FOR i := 0 TO MaxWins - 1 DO
      IF (wins[i] # NIL) & (wins[i] # ew) THEN
        wins[i].x := TUI.Cols + 1;  (* off-screen — invisible but still in Desktop list *)
        wins[i].y := 2
      END
    END;
    IF (pane # NIL) & paneShown THEN
      ew.x := ProjPaneW + 1;  ew.w := TUI.Cols - ProjPaneW
    ELSE
      ew.x := 1;  ew.w := TUI.Cols
    END;
    ew.y := 2;
    ew.h := TUI.Rows - 2;
    TUI.BringToFront(ew);
    TUI.SetFocus(ew);
    TUI.InvalidateFront();
    COPY("Full screen.", statusMsg)
  END
END ZoomCurrentWin;

PROCEDURE TogglePane;
VAR ew: EditorWin;
BEGIN
  IF pane = NIL THEN  RETURN  END;
  IF paneShown THEN
    TUI.RemoveView(pane);
    paneShown := FALSE;
    ew := FocusedEditor();
    IF ew = NIL THEN  ew := lastEditor  END;
    IF ew # NIL THEN  TUI.SetFocus(ew)  END
  ELSE
    TUI.AddView(pane);
    paneShown := TRUE;
    TUI.SetFocus(pane)
  END;
  IF zoomedWin # NIL THEN
    IF (pane # NIL) & paneShown THEN
      zoomedWin.x := ProjPaneW + 1;  zoomedWin.w := TUI.Cols - ProjPaneW
    ELSE
      zoomedWin.x := 1;  zoomedWin.w := TUI.Cols
    END
  ELSE
    TileEditorWins
  END;
  TUI.InvalidateFront()
END TogglePane;

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
    IF zoomedWin # NIL THEN
      (* Stay in zoomed mode: expand the new window, push all others off-screen *)
      zoomedWin := wins[next];
      FOR i := 0 TO MaxWins - 1 DO
        IF (wins[i] # NIL) & (wins[i] # wins[next]) THEN
          wins[i].x := TUI.Cols + 1;
          wins[i].y := 2
        END
      END;
      wins[next].x := 1;  wins[next].y := 2;
      wins[next].w := TUI.Cols;  wins[next].h := TUI.Rows - 2
    END;
    TUI.BringToFront(wins[next]);
    TUI.SetFocus(wins[next]);
    TUI.InvalidateFront();
  END
END NextEditorWin;

(* ════════════════════════════════════════════════════════════════
   File I/O
   ════════════════════════════════════════════════════════════════ *)

(* Resolve a relative path to absolute by prepending the cwd. *)
PROCEDURE AbsPath(rel: ARRAY OF CHAR; VAR abs: ARRAY OF CHAR);
VAR cwd: ARRAY 512 OF CHAR;
n: INTEGER;
BEGIN
  IF rel[0] = '/' THEN
    Strings.Copy(rel, abs)
  ELSE
    OS.GetCwd(cwd);
    n := Strings.Length(cwd);
    IF (n > 0) & (cwd[n - 1] # '/') THEN  Strings.Append("/", cwd)  END;
    Strings.Copy(cwd, abs);
    Strings.Append(rel, abs)
  END
END AbsPath;

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
AbsPath(name, ew.title);
ew.cx := 0;  ew.cy := 0;
ew.topLine := 0;  ew.leftCol := 0;
ew.modified := FALSE;
ew.undoTop := 0;  ew.undoCount := 0;
ew.selActive := FALSE;
ew.markMode  := FALSE;
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

(* Parse "file:line:col: ..." and extract file and line number. *)
PROCEDURE ParseErrorLoc(msg: ARRAY OF CHAR; VAR fname: ARRAY OF CHAR; VAR lno: INTEGER);
VAR i, j, n, len: INTEGER;
BEGIN
  lno := 0;  fname[0] := 0X;
  len := Strings.Length(msg);
  i := 0;
  WHILE i < len DO
    IF msg[i] = ':' THEN
      j := i + 1;  n := 0;
      WHILE (j < len) & (msg[j] >= '0') & (msg[j] <= '9') DO
        n := n * 10 + ORD(msg[j]) - ORD('0');
        INC(j)
      END;
      IF (j > i + 1) & (j < len) & (msg[j] = ':') & (n > 0) THEN
        Strings.Extract(msg, 0, i, fname);
        lno := n;
        RETURN
      END
    END;
    INC(i)
  END
END ParseErrorLoc;

PROCEDURE JumpToError;
VAR ew: EditorWin;
i:  INTEGER;
base: ARRAY 512 OF CHAR;
elen: INTEGER;
BEGIN
  IF errorLine <= 0 THEN
    Strings.Copy("No error location.", statusMsg);  RETURN
  END;
  (* Find an editor whose title matches errorFile (exact or by basename) *)
  ew := NIL;
  elen := Strings.Length(errorFile);
  FOR i := 0 TO MaxWins - 1 DO
    IF (wins[i] # NIL) & (ew = NIL) THEN
      IF Strings.Compare(wins[i].title, errorFile) = 0 THEN
        ew := wins[i]
      ELSE
        (* match on basename: errorFile ends with title or title ends with errorFile *)
        IF Strings.Length(wins[i].title) <= elen THEN
          Strings.Extract(errorFile, elen - Strings.Length(wins[i].title),
          Strings.Length(wins[i].title), base);
          IF Strings.Compare(base, wins[i].title) = 0 THEN  ew := wins[i]  END
        END
      END
    END
  END;
  IF ew = NIL THEN  ew := FocusedEditor()  END;
  IF ew = NIL THEN  ew := lastEditor  END;
  IF ew = NIL THEN
    Strings.Copy("No editor open.", statusMsg);  RETURN
  END;
  i := errorLine - 1;
  IF i < 0 THEN  i := 0  END;
  IF i >= ew.nlines THEN  i := ew.nlines - 1  END;
  ew.cy := i;  ew.cx := 0;
  (* Scroll so the error line is visible *)
  IF ew.cy < ew.topLine THEN  ew.topLine := ew.cy
ELSIF ew.cy >= ew.topLine + (ew.h - 2) THEN
  ew.topLine := ew.cy - (ew.h - 2) DIV 2
END;
TUI.SetFocus(ew);
Strings.Copy("Error at line ", statusMsg);
Strings.IntToStr(errorLine, base);
Strings.Append(base, statusMsg)
END JumpToError;

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
      ParseErrorLoc(outBuf, errorFile, errorLine);
      IF errorFile[0] # 0X THEN
        (* skip "file:line:col: " prefix — show only the message part *)
        i := Strings.Length(errorFile) + 1;
        WHILE (outBuf[i] # 0X) & (outBuf[i] # ':') DO INC(i) END;  (* past line digits *)
        IF outBuf[i] = ':' THEN INC(i) END;
        WHILE (outBuf[i] # 0X) & (outBuf[i] # ':') DO INC(i) END;  (* past col digits *)
        IF outBuf[i] = ':' THEN INC(i) END;
        IF outBuf[i] = ' ' THEN INC(i) END;
        Strings.Extract(outBuf, i, Strings.Length(outBuf) - i, statusMsg)
      ELSE
        Strings.Copy(outBuf, statusMsg)
      END
    ELSE
      Strings.Copy("Compile failed.", statusMsg);
      errorLine := 0
    END
  END
END Compile;

(* RunInTerminal — suspend TUI, run cmd with full terminal access,
   then wait for Enter before returning to the IDE. *)
PROCEDURE RunInTerminal(cmd: ARRAY OF CHAR);
VAR fullCmd: ARRAY 640 OF CHAR;
BEGIN
  TUI.Suspend();
  Terminal.Restore();
  Terminal.Clear();
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

  (* Replace step mode: Y=replace this, N=skip, A=all, Esc already handled *)
  IF promptMode = 7 THEN
    IF (ch = 'Y') OR (ch = 'y') THEN
      IF ew # NIL THEN
        IF DoReplaceOne(ew) THEN
          ScrollToCursor(ew);
          Strings.Copy("Replace (Y/N/A/Esc): ", statusMsg);
          Strings.Append(ew.srchBuf, statusMsg)
        ELSE
          Strings.Copy("Done.", statusMsg);
          promptMode := 0
        END
      END
    ELSIF (ch = 'N') OR (ch = 'n') THEN
      IF ew # NIL THEN
        IF DoFind(ew) THEN
          ScrollToCursor(ew);
          Strings.Copy("Replace (Y/N/A/Esc): ", statusMsg);
          Strings.Append(ew.srchBuf, statusMsg)
        ELSE
          Strings.Copy("No more matches.", statusMsg);
          promptMode := 0
        END
      END
    ELSIF (ch = 'A') OR (ch = 'a') THEN
      IF ew # NIL THEN
        n := DoReplaceAll(ew);
        ScrollToCursor(ew);
        Strings.Copy("Replaced ", statusMsg);
        Strings.IntToStr(n, promptBuf);
        Strings.Append(promptBuf, statusMsg);
        Strings.Append(" occurrence(s).", statusMsg)
      END;
      promptMode := 0
    END;
    IF promptMode = 0 THEN
      promptBuf[0] := 0X;
      IF lastEditor # NIL THEN  TUI.SetFocus(lastEditor)  END
    END;
    RETURN
  END;

  IF ch = TUI.KEnter THEN
    IF promptMode = 1 THEN       (* find *)
    IF ew # NIL THEN
      Strings.Copy(promptBuf, ew.srchBuf);
      IF DoFind(ew) THEN
        ScrollToCursor(ew);
        Strings.Copy("Found.", statusMsg)
      ELSE
        Strings.Copy("Not found.", statusMsg)
      END
    END;
    promptMode := 0;  promptBuf[0] := 0X;
    IF lastEditor # NIL THEN  TUI.SetFocus(lastEditor)  END
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
  statusMsg[0] := 0X;
  promptMode := 0;  promptBuf[0] := 0X;
  IF lastEditor # NIL THEN  TUI.SetFocus(lastEditor)  END
ELSIF promptMode = 5 THEN    (* replace: Enter moves to With field *)
Strings.Copy(promptBuf, promptBuf);  (* keep search term in promptBuf *)
promptMode := 6;
replacePos := 0;  replaceBuf[0] := 0X;
Strings.Copy("Find: ", statusMsg);  Strings.Append(promptBuf, statusMsg);
Strings.Append("  With: ", statusMsg)
ELSIF promptMode = 6 THEN    (* replace: Enter starts replace *)
IF ew # NIL THEN
  Strings.Copy(promptBuf, ew.srchBuf);
  ew.cy := 0;  ew.cx := 0;
  IF DoFind(ew) THEN
    ScrollToCursor(ew);
    promptMode := 7;
    Strings.Copy("Replace (Y/N/A/Esc): ", statusMsg);
    Strings.Append(ew.srchBuf, statusMsg)
  ELSE
    Strings.Copy("Not found.", statusMsg);
    promptMode := 0;  promptBuf[0] := 0X;
    IF lastEditor # NIL THEN  TUI.SetFocus(lastEditor)  END
  END
END
END;
RETURN
END;

(* Tab in search field moves to With field *)
IF (ch = 9X) & (promptMode = 5) THEN
  promptMode := 6;
  replacePos := 0;  replaceBuf[0] := 0X;
  Strings.Copy("Find: ", statusMsg);  Strings.Append(promptBuf, statusMsg);
  Strings.Append("  With: ", statusMsg);
  RETURN
END;
(* Tab in With field moves back to search field *)
IF (ch = 9X) & (promptMode = 6) THEN
  promptMode := 5;
  promptPos := Strings.Length(promptBuf);
  Strings.Copy("Find: ", statusMsg);  Strings.Append(promptBuf, statusMsg);
  RETURN
END;

(* Edit the active field *)
IF promptMode = 6 THEN
  IF ch = TUI.KBackspace THEN
    IF replacePos > 0 THEN  DEC(replacePos);  replaceBuf[replacePos] := 0X  END
  ELSIF (ORD(ch) >= 32) & (ORD(ch) < 127) & (replacePos < 127) THEN
    replaceBuf[replacePos] := ch;  INC(replacePos);  replaceBuf[replacePos] := 0X
  END;
  Strings.Copy("Find: ", statusMsg);  Strings.Append(promptBuf, statusMsg);
  Strings.Append("  With: ", statusMsg);  Strings.Append(replaceBuf, statusMsg)
ELSE
  IF ch = TUI.KBackspace THEN
    IF promptPos > 0 THEN  DEC(promptPos);  promptBuf[promptPos] := 0X  END
  ELSIF (ORD(ch) >= 32) & (ORD(ch) < 127) & (promptPos < 127) THEN
    promptBuf[promptPos] := ch;  INC(promptPos);  promptBuf[promptPos] := 0X
  END;
  IF promptMode = 1 THEN
    Strings.Copy("Find: ", statusMsg);  Strings.Append(promptBuf, statusMsg)
  ELSIF promptMode = 2 THEN
    Strings.Copy("Go to line: ", statusMsg);  Strings.Append(promptBuf, statusMsg)
  ELSIF promptMode = 5 THEN
    Strings.Copy("Find: ", statusMsg);  Strings.Append(promptBuf, statusMsg)
  END
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

PROCEDURE OpenFromPane(path: ARRAY 512 OF CHAR);
VAR ew: EditorWin;
i:  INTEGER;
BEGIN
  (* If the file is already open, just focus it. *)
  FOR i := 0 TO MaxWins - 1 DO
    IF (wins[i] # NIL) & (Strings.Compare(wins[i].title, path) = 0) THEN
      TUI.SetFocus(wins[i]);
      TUI.BringToFront(wins[i]);
      RETURN
    END
  END;
  ew := NewEditorWin();
  IF ew # NIL THEN
    IF ~LoadFile(ew, path) THEN
      Strings.Copy("Could not open file.", statusMsg)
    ELSE
      AddRecentFile(path); pendingMenuRebuild := TRUE;
    END
  ELSE
    Strings.Copy("Too many windows.", statusMsg)
  END
END OpenFromPane;

PROCEDURE OnMenuCmd(cmd: INTEGER);
VAR ew: EditorWin;
path: ARRAY 512 OF CHAR;
ok: BOOLEAN;
cwd: ARRAY 512 OF CHAR;
i: INTEGER;
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
        ELSE
          AddRecentFile(path);
          pendingMenuRebuild := TRUE
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
            Strings.Copy("Saved.", statusMsg);
            AddRecentFile(path);  pendingMenuRebuild := TRUE;
          END
        END
      ELSE
        IF ~SaveFile(ew) THEN
          Strings.Copy("Save failed.", statusMsg)
        ELSE
          Strings.Copy("Saved.", statusMsg);
          AddRecentFile(ew.title); pendingMenuRebuild := TRUE;
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
          Strings.Copy("Saved.", statusMsg);
          AddRecentFile(path);  pendingMenuRebuild := TRUE;
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

  ELSIF cmd = CmdReplace THEN
    promptMode := 5;
    promptBuf[0] := 0X;  promptPos := 0;
    replaceBuf[0] := 0X;  replacePos := 0;
    Strings.Copy("Find: ", statusMsg)

  ELSIF cmd = CmdFindNext THEN
    IF ew # NIL THEN
      IF DoFind(ew) THEN
        ScrollToCursor(ew);
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

  ELSIF cmd = CmdJumpError THEN
    JumpToError

  ELSIF cmd = CmdNextWin THEN
    NextEditorWin

  ELSIF cmd = CmdTile THEN
    TileEditorWins

  ELSIF cmd = CmdFullScreen THEN
    ZoomCurrentWin

  ELSIF cmd = CmdCopy     THEN  IF ew # NIL THEN  DoCopy(ew)     END
ELSIF cmd = CmdCut      THEN  IF ew # NIL THEN  DoCut(ew)      END
ELSIF cmd = CmdPaste    THEN  IF ew # NIL THEN  DoPaste(ew)    END
ELSIF cmd = CmdSelAll   THEN  IF ew # NIL THEN  DoSelAll(ew)   END
ELSIF cmd = CmdReindent  THEN  IF ew # NIL THEN  DoReindent(ew) END
ELSIF cmd = CmdFocusPane THEN  IF pane # NIL THEN  TUI.SetFocus(pane) END
ELSIF cmd = CmdTogglePane THEN  TogglePane

ELSIF cmd = CmdHelp THEN
  (* F1: help on word under cursor; open dialog with empty query if no editor *)
  IF ew # NIL THEN  WordAtCursor(ew, path)
ELSE  path[0] := 0X
END;
Help.Show(path)

ELSIF (cmd >= CmdRecentBase) & (cmd < CmdRecentBase + MaxRecent) THEN
  i := cmd - CmdRecentBase;
  IF i < recentCount THEN
    ew := NewEditorWin();
    IF ew # NIL THEN
      IF ~LoadFile(ew, recentFiles[i]) THEN
        Strings.Copy("Could not open file.", statusMsg)
      ELSE
        AddRecentFile(recentFiles[i]);
        pendingMenuRebuild := TRUE;
      END
    ELSE
      Strings.Copy("Too many windows.", statusMsg)
    END
  END
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

(* ════════════════════════════════════════════════════════════════
   Recent files
   ════════════════════════════════════════════════════════════════ *)

(* Path to the recent-files list: ~/.oberon_recent *)
PROCEDURE RecentPath(VAR path: ARRAY OF CHAR);
VAR home: ARRAY 512 OF CHAR;
BEGIN
  Args.GetEnv("HOME", home);
  IF home[0] # 0X THEN
    Strings.Copy(home, path);
    Strings.Append("/.oberon_recent", path)
  ELSE
    Strings.Copy(".oberon_recent", path)
  END
END RecentPath;

PROCEDURE LoadRecentFiles;
VAR path: ARRAY 512 OF CHAR;
f:    Files.File;
r:    Files.Rider;
b:    BYTE;
buf:  ARRAY 512 OF CHAR;
col:  INTEGER;
BEGIN
  recentCount := 0;
  RecentPath(path);
  f := Files.Old(path);
  IF f = NIL THEN  RETURN  END;
  Files.Set(r, f, 0);
  col := 0;
  Files.Read(r, b);
  WHILE ~r.eof & (recentCount < MaxRecent) DO
    IF b = 10 THEN
      IF col > 0 THEN
        buf[col] := 0X;
        Strings.Copy(buf, recentFiles[recentCount]);
        INC(recentCount)
      END;
      col := 0
    ELSE
      IF col < 511 THEN  buf[col] := CHR(b);  INC(col)  END
    END;
    Files.Read(r, b)
  END;
  IF (col > 0) & (recentCount < MaxRecent) THEN
    buf[col] := 0X;
    Strings.Copy(buf, recentFiles[recentCount]);
    INC(recentCount)
  END;
  Files.Close(f)
END LoadRecentFiles;

PROCEDURE SaveRecentFiles;
VAR path: ARRAY 512 OF CHAR;
f:    Files.File;
r:    Files.Rider;
i, j: INTEGER;
b:    BYTE;
BEGIN
  RecentPath(path);
  f := Files.New(path);
  IF f = NIL THEN  RETURN  END;
  Files.Set(r, f, 0);
  FOR i := 0 TO recentCount - 1 DO
    j := 0;
    WHILE recentFiles[i][j] # 0X DO
      b := ORD(recentFiles[i][j]);  Files.Write(r, b);  INC(j)
    END;
    b := 10;  Files.Write(r, b)
  END;
  Files.Register(f);
  Files.Close(f)
END SaveRecentFiles;

(* Add path to front of recent list; deduplicate; rebuild menu. *)
PROCEDURE AddRecentFile(path: ARRAY OF CHAR);
VAR i, j: INTEGER;
tmp: ARRAY 512 OF CHAR;
BEGIN
  IF path[0] = 0X THEN  RETURN  END;
  (* Copy path before the dedup shift loop, which may overwrite recentFiles[i]
     when the caller passes recentFiles[i] directly (aliasing). *)
  Strings.Copy(path, tmp);
  (* Remove existing entry for this path *)
  i := 0;
  WHILE i < recentCount DO
    IF Strings.Compare(recentFiles[i], tmp) = 0 THEN
      FOR j := i TO recentCount - 2 DO
        Strings.Copy(recentFiles[j + 1], recentFiles[j])
      END;
      DEC(recentCount)
    ELSE
      INC(i)
    END
  END;
  (* Shift everything down and insert at front *)
  IF recentCount >= MaxRecent THEN  recentCount := MaxRecent - 1  END;
  FOR i := recentCount - 1 TO 0 BY -1 DO
    Strings.Copy(recentFiles[i], recentFiles[i + 1])
  END;
  Strings.Copy(tmp, recentFiles[0]);
  INC(recentCount);
  SaveRecentFiles
END AddRecentFile;

PROCEDURE RebuildMenuBar;
VAR i: INTEGER;
label: ARRAY 64 OF CHAR;
name:  ARRAY 512 OF CHAR;
slen, j: INTEGER;
BEGIN
  IF (TUI.Focused = mbar) OR (TUI.Focused = sline) THEN
    TUI.SetFocus(NIL);
  END;
  TUI.RemoveView(mbar);
  TUI.RemoveView(sline);

  mbar := Widgets.NewMenuBar(1, 1, TUI.Cols);

  (* File menu *)
  Widgets.MenuBarAddMenu(mbar, "File");
  Widgets.MenuBarAddItem(mbar, 0, "New           Ctrl+N", CmdNew);
  Widgets.MenuBarAddItem(mbar, 0, "Open...       Ctrl+O", CmdOpen);
  Widgets.MenuBarAddItem(mbar, 0, "Save          Ctrl+S", CmdSave);
  Widgets.MenuBarAddItem(mbar, 0, "Save As...", CmdSaveAs);
  Widgets.MenuBarAddSep (mbar, 0);
  Widgets.MenuBarAddItem(mbar, 0, "Close         Ctrl+X", CmdClose);
  Widgets.MenuBarAddSep (mbar, 0);
  Widgets.MenuBarAddItem(mbar, 0, "Quit          Ctrl+Q", CmdQuit);
  IF recentCount > 0 THEN
    Widgets.MenuBarAddSep(mbar, 0);
    FOR i := 0 TO recentCount - 1 DO
      (* Show just the filename (last path component) as the label *)
      slen := Strings.Length(recentFiles[i]);
      j := slen - 1;
      WHILE (j > 0) & (recentFiles[i][j - 1] # '/') DO  DEC(j)  END;
      Strings.Extract(recentFiles[i], j, slen - j, name);
      Strings.IntToStr(i + 1, label);
      Strings.Append("  ", label);
      Strings.Append(name, label);
      Widgets.MenuBarAddItem(mbar, 0, label, CmdRecentBase + i)
    END
  END;

  (* Edit menu *)
  Widgets.MenuBarAddMenu(mbar, "Edit");
  Widgets.MenuBarAddItem(mbar, 1, "Undo          Ctrl+Z", CmdUndo);
  Widgets.MenuBarAddSep (mbar, 1);
  Widgets.MenuBarAddItem(mbar, 1, "Cut           Ctrl+X", CmdCut);
  Widgets.MenuBarAddItem(mbar, 1, "Copy          Ctrl+C", CmdCopy);
  Widgets.MenuBarAddItem(mbar, 1, "Paste         Ctrl+V", CmdPaste);
  Widgets.MenuBarAddItem(mbar, 1, "Select All    Ctrl+A", CmdSelAll);
  Widgets.MenuBarAddSep (mbar, 1);
  Widgets.MenuBarAddItem(mbar, 1, "Find...       Ctrl+F", CmdFind);
  Widgets.MenuBarAddItem(mbar, 1, "Find Next     F3",     CmdFindNext);
  Widgets.MenuBarAddItem(mbar, 1, "Replace...    Ctrl+R", CmdReplace);
  Widgets.MenuBarAddItem(mbar, 1, "Go to Line... Ctrl+G", CmdGoto);
  Widgets.MenuBarAddSep (mbar, 1);
  Widgets.MenuBarAddItem(mbar, 1, "Reindent", CmdReindent);

  (* Build menu *)
  Widgets.MenuBarAddMenu(mbar, "Build");
  Widgets.MenuBarAddItem(mbar, 2, "Compile       F5",  CmdCompile);
  Widgets.MenuBarAddItem(mbar, 2, "Run           F6",  CmdRun);
  Widgets.MenuBarAddItem(mbar, 2, "Compile & Run F9",  CmdCompRun);
  Widgets.MenuBarAddItem(mbar, 2, "Jump to Error F2",  CmdJumpError);

  (* Window menu *)
  Widgets.MenuBarAddMenu(mbar, "Window");
  Widgets.MenuBarAddItem(mbar, 3, "Next Window   F7",       CmdNextWin);
  Widgets.MenuBarAddItem(mbar, 3, "Full Screen   F8",       CmdFullScreen);
  Widgets.MenuBarAddItem(mbar, 3, "Tile Windows",           CmdTile);
  Widgets.MenuBarAddSep (mbar, 3);
  Widgets.MenuBarAddItem(mbar, 3, "Toggle Panel  F4",       CmdTogglePane);

  (* Help menu *)
  Widgets.MenuBarAddMenu(mbar, "Help");
  Widgets.MenuBarAddItem(mbar, 4, "Help (word)   F1", CmdHelp);

  mbar.onCmd := OnMenuCmd;
  TUI.AddView(mbar);
  TUI.AddView(sline)
END RebuildMenuBar;

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
  Widgets.MenuBarAddItem(mbar, 0, "Close         Ctrl+X", CmdClose);
  Widgets.MenuBarAddSep (mbar, 0);
  Widgets.MenuBarAddItem(mbar, 0, "Quit          Ctrl+Q", CmdQuit);

  (* Edit menu *)
  Widgets.MenuBarAddMenu(mbar, "Edit");
  Widgets.MenuBarAddItem(mbar, 1, "Undo          Ctrl+Z", CmdUndo);
  Widgets.MenuBarAddSep (mbar, 1);
  Widgets.MenuBarAddItem(mbar, 1, "Cut           Ctrl+X", CmdCut);
  Widgets.MenuBarAddItem(mbar, 1, "Copy          Ctrl+C", CmdCopy);
  Widgets.MenuBarAddItem(mbar, 1, "Paste         Ctrl+V", CmdPaste);
  Widgets.MenuBarAddItem(mbar, 1, "Select All    Ctrl+A", CmdSelAll);
  Widgets.MenuBarAddSep (mbar, 1);
  Widgets.MenuBarAddItem(mbar, 1, "Find...       Ctrl+F", CmdFind);
  Widgets.MenuBarAddItem(mbar, 1, "Find Next     F3",     CmdFindNext);
  Widgets.MenuBarAddItem(mbar, 1, "Replace...    Ctrl+R", CmdReplace);
  Widgets.MenuBarAddItem(mbar, 1, "Go to Line... Ctrl+G", CmdGoto);
  Widgets.MenuBarAddSep (mbar, 1);
  Widgets.MenuBarAddItem(mbar, 1, "Reindent", CmdReindent);

  (* Build menu *)
  Widgets.MenuBarAddMenu(mbar, "Build");
  Widgets.MenuBarAddItem(mbar, 2, "Compile       F5",  CmdCompile);
  Widgets.MenuBarAddItem(mbar, 2, "Run           F6",  CmdRun);
  Widgets.MenuBarAddItem(mbar, 2, "Compile & Run F9",  CmdCompRun);
  Widgets.MenuBarAddItem(mbar, 2, "Jump to Error F2",  CmdJumpError);

  (* Window menu *)
  Widgets.MenuBarAddMenu(mbar, "Window");
  Widgets.MenuBarAddItem(mbar, 3, "Next Window   F7",       CmdNextWin);
  Widgets.MenuBarAddItem(mbar, 3, "Full Screen   F8",       CmdFullScreen);
  Widgets.MenuBarAddItem(mbar, 3, "Tile Windows",           CmdTile);
  Widgets.MenuBarAddSep (mbar, 3);
  Widgets.MenuBarAddItem(mbar, 3, "Toggle Panel  F4",       CmdTogglePane);

  (* Help menu *)
  Widgets.MenuBarAddMenu(mbar, "Help");
  Widgets.MenuBarAddItem(mbar, 4, "Help (word)   F1", CmdHelp);

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
  sx := ew.x + 1 + GutterW(ew) + ByteToCol(ew.lines[ew.cy], ew.cx) - ByteToCol(ew.lines[ew.cy], ew.leftCol);
  sy := ew.y + 1 + ew.cy - ew.topLine
END CursorScreenPos;

VAR
ev:        TUI.Event;
ew:        EditorWin;
sx, sy:    INTEGER;
fn:        ARRAY 512 OF CHAR;
ch:        CHAR;
acHandled: BOOLEAN;

BEGIN
  TUI.Init();

  winCount  := 0;
  lastEditor := NIL;
  zoomedWin  := NIL;
  pendingMenuRebuild := FALSE;
  running   := TRUE;
  promptMode := 0;
  statusMsg[0] := 0X;
  promptBuf[0] := 0X;
  promptPos := 0;
  replaceBuf[0] := 0X;
  replacePos := 0;
  acActive      := FALSE;
  acCount       := 0;
  pendingClose  := FALSE;
  clipNLines := 0;
  recentCount := 0;
  errorLine := 0;  errorFile[0] := 0X;

  LoadRecentFiles();
  BuildMenus();
  RebuildMenuBar();   (* re-adds mbar and sline with recent files populated *)


  (* Simple approach: always use cwd as the project root. *)
  pane := ProjectPane.New(1, 2, ProjPaneW, TUI.Rows - 2);
  pane.onOpenFile := OpenFromPane;
  OS.GetCwd(fn);
  ProjectPane.SetRoot(pane, fn);
  TUI.AddView(pane);
  paneShown := TRUE;
  (* Open file from command line, or start with empty window *)
  ew := NewEditorWin();
  lastEditor := ew;   (* prime lastEditor so menu commands work before any mouse motion *)
  IF Args.Count() > 0 THEN
    Args.Get(1, fn);
    IF ~LoadFile(ew, fn) THEN
      Strings.Copy("New file: ", statusMsg);  Strings.Append(fn, statusMsg);
      AbsPath(fn, ew.title)
    ELSE
      AddRecentFile(ew.title);  RebuildMenuBar()
    END
  END;

  WHILE running DO
    UpdateStatus();
    TUI.ClearBack(TUI.White, TUI.Black);
    TUI.DrawAll();
    IF acActive & (promptMode = 0) THEN  DrawAC()  END;
    TUI.Flush();

    (* Position blinking cursor in the focused editor *)
    ew := FocusedEditor();
    IF ew # NIL THEN
      CursorScreenPos(ew, sx, sy);
      TUI.SetCursor(sx, sy);
      Terminal.ShowCursor();
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
      acHandled := FALSE;

      (* Autocomplete popup navigation *)
      IF acActive THEN
        IF ch = TUI.KEsc THEN
          acActive  := FALSE;
          acHandled := TRUE
        ELSIF ch = TUI.KUp THEN
          IF acSel > 0 THEN  DEC(acSel) END;
          IF acSel < acScroll THEN  acScroll := acSel  END;
          acHandled := TRUE
        ELSIF ch = TUI.KDown THEN
          IF acSel < acCount - 1 THEN  INC(acSel)  END;
          IF acSel >= acScroll + MaxAcVisible THEN  acScroll := acSel - MaxAcVisible + 1  END;
          acHandled := TRUE
        ELSIF (ch = TUI.KEnter) OR (ORD(ch) = 9) THEN  (* Enter or Tab *)
        ew := FocusedEditor();
        IF ew # NIL THEN  AcceptAC(ew)  END;
        acActive  := FALSE;
        acHandled := TRUE
      ELSIF (ORD(ch) >= 32) & (ORD(ch) < 127) THEN
        (* Printable: let it fall through to normal handling, then re-trigger *)
        acHandled := FALSE
      ELSIF ORD(ch) = 8 THEN  (* Backspace: let through, then re-trigger *)
      acHandled := FALSE
    ELSE
      acActive  := FALSE;
      acHandled := FALSE
    END
  END;

  IF ~acHandled THEN
    (* Global hotkeys *)
    IF ORD(ch) = 14 THEN       (* Ctrl+N *)
    acActive := FALSE;
    IF NewEditorWin() = NIL THEN  Strings.Copy("Too many windows.", statusMsg)  END
  ELSIF ORD(ch) = 15 THEN    (* Ctrl+O *)
  acActive := FALSE;  OnMenuCmd(CmdOpen)
ELSIF ORD(ch) = 19 THEN    (* Ctrl+S *)
acActive := FALSE;  OnMenuCmd(CmdSave)
ELSIF ORD(ch) = 23 THEN    (* Ctrl+W: kill region *)
acActive := FALSE;
ew := FocusedEditor();
IF ew # NIL THEN  DoCut(ew)  END
ELSIF ORD(ch) = 24 THEN    (* Ctrl+X: close window *)
acActive := FALSE;  OnMenuCmd(CmdClose)
ELSIF ORD(ch) = 17 THEN    (* Ctrl+Q *)
acActive := FALSE;  OnMenuCmd(CmdQuit)
ELSIF ORD(ch) = 9  THEN    (* Tab — route to focused view *)
IF ~TUI.Dispatch(ev) THEN  END
ELSIF ORD(ch) = 0  THEN    (* Ctrl+Space: set mark / autocomplete *)
ew := FocusedEditor();
IF ew # NIL THEN
  IF ew.selActive & ew.markMode THEN  ClearSel(ew)  (* second press cancels mark *)
ELSE  StartSel(ew);  ew.markMode := TRUE           (* first press sets mark      *)
END;
TriggerAC(ew)
END
ELSIF ch = TUI.KF1  THEN   acActive := FALSE;  OnMenuCmd(CmdHelp)
ELSIF ch = TUI.KF2  THEN   acActive := FALSE;  OnMenuCmd(CmdJumpError)
ELSIF ch = TUI.KF4 THEN acActive := FALSE;  OnMenuCmd(CmdTogglePane)
ELSIF ch = TUI.KF5  THEN   acActive := FALSE;  OnMenuCmd(CmdCompile)
ELSIF ch = TUI.KF6  THEN   acActive := FALSE;  OnMenuCmd(CmdRun)
ELSIF ch = TUI.KF9  THEN   acActive := FALSE;  OnMenuCmd(CmdCompRun)
ELSIF ch = TUI.KF3  THEN   acActive := FALSE;  OnMenuCmd(CmdFindNext)
ELSIF ch = TUI.KF7  THEN   acActive := FALSE;  OnMenuCmd(CmdNextWin)
ELSIF ch = TUI.KF8  THEN   acActive := FALSE;  OnMenuCmd(CmdFullScreen)
ELSE
  IF ~TUI.Dispatch(ev) THEN  END;
  IF pendingMenuRebuild THEN  pendingMenuRebuild := FALSE;  RebuildMenuBar  END;
  (* After a printable char or backspace, re-filter if AC is active *)
  IF acActive & ((ORD(ch) >= 32) & (ORD(ch) < 127) OR (ORD(ch) = 8)) THEN
    ew := FocusedEditor();
    IF ew # NIL THEN  TriggerAC(ew)  END
  END
END
END

ELSIF ev.kind = TUI.EvMouse THEN
  (* Dismiss autocomplete on any real click *)
  IF (ev.mb # 32) & (ev.mb # 3) THEN  acActive := FALSE  END;
  IF ~TUI.Dispatch(ev) THEN  END;
  IF pendingClose THEN  pendingClose := FALSE;  OnMenuCmd(CmdClose);  END;
  IF pendingMenuRebuild THEN  pendingMenuRebuild := FALSE;  RebuildMenuBar  END
ELSIF ev.kind = TUI.EvResize THEN
  sline.y := TUI.Rows;
  sline.w := TUI.Cols;
  mbar.w  := TUI.Cols;
  IF zoomedWin # NIL THEN
    (* Re-apply full-screen geometry to the zoomed window *)
    zoomedWin.x := 1;  zoomedWin.y := 2;
    zoomedWin.w := TUI.Cols;  zoomedWin.h := TUI.Rows - 2;
  ELSE
    TileEditorWins();
  END;
  IF pane # NIL THEN
    pane.h := TUI.Rows - 2;
  END;
  TUI.InvalidateFront();
END
END;

TUI.Done()
END IDE.















