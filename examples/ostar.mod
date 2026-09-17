MODULE OStar;
(*
 * OStar - a WordStar/WordPerfect-style text editor for the Oberon system.
 * Ported from PerfectStar 2k (Rust) by Jonathan Badger.
 *
 * Movement: ^E/S/D/X (diamond), ^A/F word, ^W/Z scroll, ^R/C page.
 * Prefix ^K  — Block & File: ^KB/KK marks, ^KC copy, ^KV move, ^KY del,
 *              ^KP put, ^KD/KS save, ^KX save+quit, ^KQ quit.
 * Prefix ^Q  — Quick: ^QS/QD line start/end, ^QR/QC doc start/end,
 *              ^QE/QX screen top/bot, ^QB/QK jump block, ^QP prev pos,
 *              ^QF find, ^QA replace, ^Q,/. sentence, ^Q[/] para,
 *              ^QO next heading, ^QG transpose chars, ^QT transpose words.
 * Prefix ^O  — Onscreen: ^OB cycle theme, ^OH cycle help, ^OW wrap,
 *              ^OS spellcheck, ^OT typewriter scroll, ^OC word count,
 *              ^OF focus mode, ^OL style check.
 * ^QI — next style issue (adverb/filler/passive/long sentence).
 * Prefix ^P  — Project: ^PN new, ^PP open, ^PA add, ^PR remove,
 *              ^PE prev doc, ^PX next doc, ^PL list.
 * Other: ^G delete, ^H backspace, ^T del-word, ^Y del-line,
 *        ^N insert line, ^U undo, ^L find next, ^V overtype toggle,
 *        F1 command palette (shows key list).
 *)
IMPORT TUI, Terminal, Files, Strings, Args, Dict, OS, Env, Time, Markdown, ZipWriter;

(* ── Constants ───────────────────────────────────────────────────── *)
CONST
  MaxLines   = 65536;
  MaxLineLen = 4095;

  (* EPUB export/compile: one chapterN.xhtml ZIP entry per top-level
     heading, plus mimetype/container.xml/package.opf/nav.xhtml —
     capped so the total never exceeds ZipWriter.MaxEntries. *)
  EpubMaxChapters = ZipWriter.MaxEntries - 4;

  KRSlots    = 8;    (* kill ring capacity        *)
  KRLines    = 128;  (* max lines per kill entry  *)

  MaxUndo    = 400;

  (* Themes *)
  ThWP  = 0;   (* WordPerfect 5.1 — white on blue *)
  ThWS  = 1;   (* WordStar — white on black       *)
  ThDef = 2;   (* Terminal default                *)

  (* Modes *)
  ModeNormal  = 0;
  ModeSearch  = 1;   (* incremental find (^QF)  *)
  ModeReplace = 2;   (* confirm replace step    *)
  ModeInput   = 3;   (* generic text prompt     *)
  ModeConfirm = 4;   (* yes/no confirmation     *)
  ModePalette = 5;   (* F1 key list             *)
  ModeBinder  = 6;   (* binder panel navigation *)
  ModeOutline = 7;   (* outline panel           *)
  ModeRevisions = 8; (* snapshot browser (^KO)  *)

  (* Prefix keys *)
  PrefNone = 0;  PrefK = 1;  PrefQ = 2;  PrefO = 3;  PrefP = 4;

  (* Input-prompt actions *)
  ActSaveAs  = 1;
  ActOpen    = 2;
  ActWBlk    = 3;  (* write block to file *)
  ActRFile   = 4;  (* read file at cursor *)
  ActMargin  = 5;  (* set wrap margin     *)
  ActProjNew = 6;  (* create project      *)
  ActProjOpen= 7;  (* open project file   *)
  ActProjReplFind = 8;  (* project-wide replace: find string  *)
  ActProjReplWith = 9;  (* project-wide replace: replacement  *)
  ActSynopsis     = 10; (* edit a project doc's synopsis      *)
  ActOtherOpen    = 11; (* open a file into the other window  *)
  ActAnnotate     = 12; (* insert a ".." comment line (^PC)   *)

  (* Undo record kinds *)
  UKLine  = 0;   (* one line's content changed  *)
  UKBreak = 1;   (* Enter: line split; line1 = original *)
  UKJoin  = 2;   (* BS/Del join; line1 = joined-away line, col = split pt *)
  UKIns   = 3;   (* blank line inserted at row  *)
  UKDel   = 4;   (* line deleted; line1 = deleted content *)

  (* Project *)
  MaxProjDocs = 128;   (* documents per project *)
  MaxRevisions = 200;  (* snapshots listed per document (^KO) *)

  (* Key codes — use TUI.Kxxx qualifiers in code to avoid C macro collisions *)

  (* Style-check kinds *)
  StNone    = 0;
  StAdverb  = 1;   (* -ly adverb                 *)
  StFiller  = 2;   (* intensifier / filter word  *)
  StPassive = 3;   (* passive-voice construction *)
  StLong    = 4;   (* very long sentence         *)
  StyleSentWords = 30;  (* sentence-word threshold *)

  (* Max words per line for style scan (1 word per ~4 chars is realistic) *)
  MaxStyleWords = 1024;

(* ── Types ───────────────────────────────────────────────────────── *)
TYPE
  LineRec = RECORD s: ARRAY (MaxLineLen + 1) OF CHAR END;
  Line    = POINTER TO LineRec;
  LineBuf = ARRAY (MaxLineLen + 1) OF CHAR;

  UndoEntry = RECORD
    kind              : INTEGER;
    row, col          : INTEGER;   (* edit position *)
    curRow, curCol    : INTEGER;   (* cursor before op *)
    line1             : Line;      (* heap-allocated; NIL = unused *)
    line2             : Line;
  END;

  (* A snapshot of everything that makes up "the document being edited",
     used for the other window (^OK) — its content lives here while it
     isn't focused, and swaps into the live globals when it is. Undo
     history is intentionally not part of this: switching panes resets
     undo rather than trying to keep two histories consistent. *)
  PaneSnap = RECORD
    lines    : ARRAY MaxLines OF Line;
    numLines : INTEGER;
    filePath : ARRAY 512 OF CHAR;
    dirty    : BOOLEAN;
    curRow, curCol, goalCol, topLine, leftCol : INTEGER;
    hasBlkB, hasBlkE                          : BOOLEAN;
    blkBRow, blkBCol, blkERow, blkECol        : INTEGER;
  END;

  KillBlock = RECORD
    n    : INTEGER;
    data : ARRAY KRLines OF Line;
  END;

(* ── Globals ─────────────────────────────────────────────────────── *)
VAR
  (* Text buffer *)
  lines    : ARRAY MaxLines OF Line;
  numLines : INTEGER;
  filePath : ARRAY 512 OF CHAR;
  dirty    : BOOLEAN;
  expRider : Files.Rider;  (* current Markdown.mod export target (RTF/HTML) *)

  (* Cursor & view *)
  curRow, curCol  : INTEGER;
  goalCol         : INTEGER;    (* sticky column; -1 = use curCol *)
  topLine         : INTEGER;
  leftCol         : INTEGER;

  (* Block marks *)
  hasBlkB, hasBlkE : BOOLEAN;
  blkBRow, blkBCol : INTEGER;
  blkERow, blkECol : INTEGER;
  hasPrevBlk       : BOOLEAN;   (* the block mark just overwritten by BlockBegin, for ^KU *)
  prevBlkBRow, prevBlkBCol : INTEGER;
  prevBlkERow, prevBlkECol : INTEGER;

  (* Kill ring *)
  killRing   : ARRAY KRSlots OF KillBlock;
  killHead   : INTEGER;
  killCount  : INTEGER;
  putIndex   : INTEGER;   (* cycles on repeated ^KP *)

  (* Undo *)
  undoStack  : ARRAY MaxUndo OF UndoEntry;
  undoTop    : INTEGER;

  (* Editor state *)
  mode       : INTEGER;
  prefix     : INTEGER;
  theme      : INTEGER;
  helpLevel  : INTEGER;    (* 0=clean 1=menus shown 2=menus+hints *)
  wrap       : BOOLEAN;
  wrapMargin : INTEGER;
  overtype   : BOOLEAN;
  typewriter : BOOLEAN;
  running    : BOOLEAN;
  showSplash : BOOLEAN;

  (* Status message *)
  statusMsg  : ARRAY 256 OF CHAR;

  (* Search state *)
  searchStr  : ARRAY 256 OF CHAR;
  searchRow  : INTEGER;    (* row of last found match *)
  searchCol  : INTEGER;    (* col of last found match *)
  searchLen  : INTEGER;    (* length of last match    *)
  caseSens   : BOOLEAN;

  (* Replace state *)
  replSearch : ARRAY 256 OF CHAR;  (* find pattern for replace *)
  replWith   : ARRAY 256 OF CHAR;
  inReplace  : BOOLEAN;    (* a replace step is pending *)
  replNextR  : INTEGER;    (* where to resume after a replace *)
  replNextC  : INTEGER;

  (* Input prompt *)
  inpLabel   : ARRAY 64 OF CHAR;
  inpValue   : ARRAY 512 OF CHAR;
  inpAction  : INTEGER;
  inpCursor  : INTEGER;

  (* Spell check *)
  spellEnabled : BOOLEAN;
  misspelled   : Dict.Table;   (* words hunspell flagged as wrong  *)
  personalDict : Dict.Table;   (* personal word list (always OK)   *)
  personalPath : ARRAY 512 OF CHAR;

  (* Previous position (^QP) *)
  prevRow, prevCol : INTEGER;
  hasPrev          : BOOLEAN;

  (* Misc *)
  needRedraw  : BOOLEAN;

  (* Focus mode *)
  focusMode   : BOOLEAN;
  focusParaS  : INTEGER;
  focusParaE  : INTEGER;

  (* Style check *)
  styleEnabled : BOOLEAN;
  styleCurKind : INTEGER;   (* kind at cursor position, set during DrawTextLine/DrawSegment *)

  (* Project *)
  projPath     : ARRAY 512 OF CHAR;               (* path of open .ostarproj file, or empty *)
  projDocs     : ARRAY MaxProjDocs OF ARRAY 512 OF CHAR;
  projIsNote   : ARRAY MaxProjDocs OF BOOLEAN;    (* doc excluded from compile (^PM) *)
  projDocCount : INTEGER;
  projCurDoc   : INTEGER;   (* index of currently open doc in projDocs, or -1 *)
  binderSel    : INTEGER;   (* highlighted entry in the binder popup *)
  binderScroll : INTEGER;   (* first visible entry in the binder popup *)
  showSynopsis : BOOLEAN;   (* ^PY: show each binder entry's synopsis line *)
  synopsisTarget     : ARRAY 512 OF CHAR;  (* doc path being edited by ^PI *)
  synopsisFromBinder : BOOLEAN;            (* re-open the binder after ^PI's prompt *)

  (* Other window (^OK / ^KA / ^QV / ^PO / ^PV) *)
  otherPane     : PaneSnap;
  otherPaneOpen : BOOLEAN;
  focusOther    : BOOLEAN;   (* TRUE = the active globals are the *bottom* pane *)
  swapTmp       : PaneSnap;  (* scratch space for pane swaps — kept global; a
                                PaneSnap is too large to put on the C stack *)

  (* Reveal codes (^OD) *)
  revealCodes : BOOLEAN;

  (* Revisions browser (^KO) *)
  revNames  : ARRAY MaxRevisions OF ARRAY 512 OF CHAR;
  revCount  : INTEGER;
  revSel    : INTEGER;
  revScroll : INTEGER;
  revDir    : ARRAY 512 OF CHAR;  (* directory the snapshots live in *)

  (* Palette scroll *)
  palScroll   : INTEGER;

  (* Outline panel *)
  outlineScroll : INTEGER;
  outlineSel    : INTEGER;

  (* Main loop event *)
  ev          : TUI.Event;

(* ── Theme Colours ───────────────────────────────────────────────── *)
(*
 * WP Blue uses xterm-256 indices so the background matches DOS CGA #0000AA:
 *   19 = #0000af  — text background  (nearest to CGA blue #0000AA)
 *   17 = #00005f  — block-highlight fg on white (dark enough for contrast)
 * The status bar stays ANSI cyan (TUI.Cyan = 6) — the lighter band is correct.
 *)
CONST WPBlueBg = 19;  (* xterm-256 #0000af, closest to CGA #0000AA *)
      WPBlueBlkFg = 17; (* xterm-256 #00005f for block highlight *)

PROCEDURE ThFg(): INTEGER;
BEGIN
  IF theme = ThWP THEN RETURN TUI.White ELSE RETURN TUI.White END
END ThFg;

PROCEDURE ThBg(): INTEGER;
BEGIN
  IF theme = ThWP THEN RETURN WPBlueBg ELSE RETURN TUI.Black END
END ThBg;

PROCEDURE ThDimFg(): INTEGER;
BEGIN
  RETURN 245  (* xterm-256 medium gray — recedes against either theme's dark
                 background, unlike full-saturation Cyan *)
END ThDimFg;

PROCEDURE ThStFg(): INTEGER;
BEGIN
  IF theme = ThWP THEN RETURN TUI.Black ELSE RETURN TUI.Black END
END ThStFg;

PROCEDURE ThStBg(): INTEGER;
BEGIN
  IF theme = ThWP THEN RETURN TUI.Cyan ELSE RETURN TUI.White END
END ThStBg;

PROCEDURE ThBlkFg(): INTEGER;
BEGIN
  IF theme = ThWP THEN RETURN WPBlueBlkFg ELSE RETURN TUI.Black END
END ThBlkFg;

PROCEDURE ThBlkBg(): INTEGER;
BEGIN
  IF theme = ThWP THEN RETURN TUI.White ELSE RETURN TUI.White END
END ThBlkBg;

(* Search-match highlight: yellow background for all themes *)
PROCEDURE ThHlFg(): INTEGER; BEGIN RETURN TUI.Black END ThHlFg;
PROCEDURE ThHlBg(): INTEGER; BEGIN RETURN TUI.Yellow END ThHlBg;

(* Spell-error: bright red foreground, same background as theme *)
PROCEDURE ThSpFg(): INTEGER; BEGIN RETURN 9 END ThSpFg;   (* xterm bright-red *)

(* Style-issue foreground by kind. Uses explicit xterm-256 corner colors
   (max saturation) rather than the ANSI "bright" 8-15 slots — those get
   remapped to muted tones (e.g. 11 renders as a dim orange, not yellow)
   by this terminal's 16-color theme, which made them too dim to read. *)
PROCEDURE ThStylFg(kind: INTEGER): INTEGER;
BEGIN
  IF kind = StAdverb  THEN RETURN 226  (* vivid yellow  *)
  ELSIF kind = StFiller  THEN RETURN 201 (* vivid magenta *)
  ELSIF kind = StPassive THEN RETURN 51  (* vivid cyan    *)
  ELSE RETURN 46                         (* vivid green for long sentence *)
  END
END ThStylFg;

(* ── Text-area layout ────────────────────────────────────────────── *)
(* The binder is a popup (like PerfectStar's), not a sidebar, so the
   text area always spans the full width. *)

PROCEDURE TextX0(): INTEGER;
BEGIN RETURN 1 END TextX0;

PROCEDURE TextW(): INTEGER;
BEGIN RETURN TUI.Cols END TextW;

(* ── Utility ─────────────────────────────────────────────────────── *)

PROCEDURE SetStatus(s: ARRAY OF CHAR);
BEGIN COPY(s, statusMsg) END SetStatus;

PROCEDURE Max(a, b: INTEGER): INTEGER;
BEGIN IF a > b THEN RETURN a ELSE RETURN b END END Max;

PROCEDURE Min(a, b: INTEGER): INTEGER;
BEGIN IF a < b THEN RETURN a ELSE RETURN b END END Min;

PROCEDURE Clamp(v, lo, hi: INTEGER): INTEGER;
BEGIN
  IF v < lo THEN RETURN lo ELSIF v > hi THEN RETURN hi ELSE RETURN v END
END Clamp;

PROCEDURE LineLen(row: INTEGER): INTEGER;
BEGIN
  IF (row >= 0) & (row < numLines) & (lines[row] # NIL) THEN
    RETURN Strings.Length(lines[row].s)
  ELSE RETURN 0
  END
END LineLen;

PROCEDURE IsWordChar(c: CHAR): BOOLEAN;
BEGIN
  RETURN ((c >= 'a') & (c <= 'z')) OR ((c >= 'A') & (c <= 'Z'))
      OR ((c >= '0') & (c <= '9')) OR (c = '_')
END IsWordChar;

(* ── UTF-8 helpers ───────────────────────────────────────────────── *)
(* Lines are stored as raw UTF-8 bytes; curCol/leftCol/etc are byte
   offsets. These keep multi-byte characters (em dash, curly quotes,
   accented letters) treated as one screen cell / one edit unit instead
   of being split byte-by-byte, which is what made Backspace and cursor
   placement land on the wrong byte after such a character. *)

PROCEDURE UTF8SeqLen(c: CHAR): INTEGER;
(* Length in bytes of the UTF-8 sequence starting with lead byte c *)
BEGIN
  IF ORD(c) < 128 THEN RETURN 1
  ELSIF (ORD(c) >= 192) & (ORD(c) <= 223) THEN RETURN 2
  ELSIF (ORD(c) >= 224) & (ORD(c) <= 239) THEN RETURN 3
  ELSIF (ORD(c) >= 240) & (ORD(c) <= 247) THEN RETURN 4
  ELSE RETURN 1  (* stray continuation byte or invalid lead byte *)
  END
END UTF8SeqLen;

PROCEDURE IsContByte(c: CHAR): BOOLEAN;
BEGIN RETURN (ORD(c) >= 128) & (ORD(c) <= 191) END IsContByte;

PROCEDURE ReadUTF8Seq(lead: CHAR; VAR seq: ARRAY OF CHAR): INTEGER;
(* `lead` was already read from the terminal as a UTF-8 lead byte (its
   value is guaranteed to fall outside TUI's special-key code range, so
   it can never be a real Home/PgUp/F-key/etc). Its continuation bytes,
   though, land in the same byte range TUI uses for those special keys
   (0x80-0xBF overlaps 0x80-0x94/0xA0-0xA8) — reading them straight from
   Terminal (bypassing TUI's event classification) instead of through
   another TUI.WaitEvent is what stops e.g. a typed em dash's middle
   byte from being read back as PageUp. Fills seq (NUL-terminated) and
   returns the sequence length. *)
VAR n, i: INTEGER;
BEGIN
  n := UTF8SeqLen(lead);
  seq[0] := lead;
  FOR i := 1 TO n - 1 DO seq[i] := Terminal.ReadKey() END;
  seq[n] := 0X;
  RETURN n
END ReadUTF8Seq;

PROCEDURE TrimLastUTF8Char(VAR buf: ARRAY OF CHAR);
(* Strip the last character (1-4 bytes) from a NUL-terminated byte
   buffer, e.g. a search string or input prompt value. *)
VAR slen, p: INTEGER;
BEGIN
  slen := Strings.Length(buf);
  IF slen > 0 THEN
    p := slen - 1;
    WHILE (p > 0) & IsContByte(buf[p]) DO DEC(p) END;
    buf[p] := 0X
  END
END TrimLastUTF8Char;

PROCEDURE AppendUTF8(VAR buf: ARRAY OF CHAR; maxLen: INTEGER; seq: ARRAY OF CHAR; n: INTEGER);
(* Append n raw bytes (from ReadUTF8Seq) to a NUL-terminated buffer. *)
VAR slen, i: INTEGER;
BEGIN
  slen := Strings.Length(buf);
  IF slen + n <= maxLen THEN
    FOR i := 0 TO n - 1 DO buf[slen + i] := seq[i] END;
    buf[slen + n] := 0X
  END
END AppendUTF8;

PROCEDURE CellCount(row, fromCol, toCol: INTEGER): INTEGER;
(* Number of screen cells (UTF-8 characters) between byte columns
   fromCol and toCol on row. Both must be on character boundaries. *)
VAR col, n: INTEGER;
BEGIN
  col := fromCol; n := 0;
  WHILE col < toCol DO
    INC(col, UTF8SeqLen(lines[row].s[col]));
    INC(n)
  END;
  RETURN n
END CellCount;

PROCEDURE ColAtCells(row, fromCol, cells: INTEGER): INTEGER;
(* Byte column reached after advancing `cells` screen cells from fromCol *)
VAR col, n, len: INTEGER;
BEGIN
  col := fromCol; n := 0; len := LineLen(row);
  WHILE (n < cells) & (col < len) DO
    INC(col, UTF8SeqLen(lines[row].s[col]));
    INC(n)
  END;
  RETURN col
END ColAtCells;

PROCEDURE PutLineCell(row, col, len, screenX, screenY, fg, bg: INTEGER): INTEGER;
(* Draw the character at byte column col (row) into one screen cell,
   gathering the full UTF-8 sequence if it is multi-byte.
   Returns the number of bytes consumed (>= 1). *)
VAR c, b2, b3, b4: CHAR; n: INTEGER;
BEGIN
  c := lines[row].s[col];
  IF c = 0X THEN c := ' ' END;
  n := UTF8SeqLen(c);
  IF col + n > len THEN n := 1 END;  (* truncated/invalid sequence *)
  IF n = 1 THEN
    TUI.PutCell(screenX, screenY, c, fg, bg)
  ELSE
    b2 := lines[row].s[col + 1];
    IF n >= 3 THEN b3 := lines[row].s[col + 2] ELSE b3 := 0X END;
    IF n >= 4 THEN b4 := lines[row].s[col + 3] ELSE b4 := 0X END;
    TUI.PutCellMB(screenX, screenY, c, b2, b3, b4, fg, bg)
  END;
  RETURN n
END PutLineCell;

(* Is position (row, col) inside the marked block? *)
PROCEDURE InBlock(row, col: INTEGER): BOOLEAN;
VAR r1, c1, r2, c2: INTEGER;
BEGIN
  IF ~hasBlkB OR ~hasBlkE THEN RETURN FALSE END;
  IF (blkBRow < blkERow) OR ((blkBRow = blkERow) & (blkBCol <= blkECol)) THEN
    r1 := blkBRow; c1 := blkBCol; r2 := blkERow; c2 := blkECol
  ELSE
    r1 := blkERow; c1 := blkECol; r2 := blkBRow; c2 := blkBCol
  END;
  IF (row < r1) OR (row > r2) THEN RETURN FALSE END;
  IF row = r1 THEN
    IF row = r2 THEN RETURN (col >= c1) & (col < c2)
    ELSE RETURN col >= c1
    END
  ELSIF row = r2 THEN RETURN col < c2
  ELSE RETURN TRUE
  END
END InBlock;

(* Normalise block so r1/c1 < r2/c2 *)
PROCEDURE NormBlock(VAR r1, c1, r2, c2: INTEGER);
BEGIN
  IF (blkBRow < blkERow) OR ((blkBRow = blkERow) & (blkBCol <= blkECol)) THEN
    r1 := blkBRow; c1 := blkBCol; r2 := blkERow; c2 := blkECol
  ELSE
    r1 := blkERow; c1 := blkECol; r2 := blkBRow; c2 := blkBCol
  END
END NormBlock;

(* ── Line-array helpers ──────────────────────────────────────────── *)

PROCEDURE ShiftLinesDown(from: INTEGER);
(* Insert a blank slot at `from'; existing lines at from.. shift to from+1.. *)
VAR i: INTEGER;
BEGIN
  IF numLines >= MaxLines THEN RETURN END;
  i := numLines;
  WHILE i > from DO
    lines[i] := lines[i - 1];
    DEC(i)
  END;
  NEW(lines[from]);
  lines[from].s[0] := 0X;
  INC(numLines)
END ShiftLinesDown;

PROCEDURE ShiftLinesUp(from: INTEGER);
(* Delete line at `from'; lines above shift down. *)
VAR i: INTEGER;
BEGIN
  IF numLines <= 1 THEN lines[0].s[0] := 0X; RETURN END;
  FREE(lines[from]);
  i := from;
  WHILE i < numLines - 1 DO
    lines[i] := lines[i + 1];
    INC(i)
  END;
  lines[numLines - 1] := NIL;
  DEC(numLines)
END ShiftLinesUp;

(* ── Undo ────────────────────────────────────────────────────────── *)

PROCEDURE UndoSaveLine;
(* Call before any single-line char-level edit. *)
VAR e: UndoEntry;
BEGIN
  IF undoTop >= MaxUndo THEN
    DEC(undoTop);
    IF undoStack[undoTop].line1 # NIL THEN FREE(undoStack[undoTop].line1) END;
    IF undoStack[undoTop].line2 # NIL THEN FREE(undoStack[undoTop].line2) END
  END;
  e.kind   := UKLine;
  e.row    := curRow;
  e.col    := curCol;
  e.curRow := curRow;
  e.curCol := curCol;
  NEW(e.line1); COPY(lines[curRow].s, e.line1.s);
  e.line2  := NIL;
  undoStack[undoTop] := e;
  INC(undoTop)
END UndoSaveLine;

PROCEDURE UndoSaveBreak;
(* Call before splitting a line (Enter). Saves original combined line. *)
VAR e: UndoEntry;
BEGIN
  IF undoTop >= MaxUndo THEN
    DEC(undoTop);
    IF undoStack[undoTop].line1 # NIL THEN FREE(undoStack[undoTop].line1) END;
    IF undoStack[undoTop].line2 # NIL THEN FREE(undoStack[undoTop].line2) END
  END;
  e.kind   := UKBreak;
  e.row    := curRow;
  e.col    := curCol;
  e.curRow := curRow;
  e.curCol := curCol;
  NEW(e.line1); COPY(lines[curRow].s, e.line1.s);
  e.line2  := NIL;
  undoStack[undoTop] := e;
  INC(undoTop)
END UndoSaveBreak;

PROCEDURE UndoSaveJoin(upperRow, splitCol: INTEGER);
(* Call before joining `upperRow` with `upperRow+1'. Saves the removed line. *)
VAR e: UndoEntry;
BEGIN
  IF undoTop >= MaxUndo THEN
    DEC(undoTop);
    IF undoStack[undoTop].line1 # NIL THEN FREE(undoStack[undoTop].line1) END;
    IF undoStack[undoTop].line2 # NIL THEN FREE(undoStack[undoTop].line2) END
  END;
  e.kind   := UKJoin;
  e.row    := upperRow;
  e.col    := splitCol;    (* length of upper line = where the split was *)
  e.curRow := curRow;
  e.curCol := curCol;
  (* Save the line that will be deleted (the lower one) *)
  NEW(e.line1);
  IF upperRow + 1 < numLines THEN
    COPY(lines[upperRow + 1].s, e.line1.s)
  ELSE
    e.line1.s[0] := 0X
  END;
  e.line2  := NIL;
  undoStack[undoTop] := e;
  INC(undoTop)
END UndoSaveJoin;

PROCEDURE UndoSaveInsLine(row: INTEGER);
(* Call after inserting blank line at `row' so we record what was inserted. *)
VAR e: UndoEntry;
BEGIN
  IF undoTop >= MaxUndo THEN
    DEC(undoTop);
    IF undoStack[undoTop].line1 # NIL THEN FREE(undoStack[undoTop].line1) END;
    IF undoStack[undoTop].line2 # NIL THEN FREE(undoStack[undoTop].line2) END
  END;
  e.kind   := UKIns;
  e.row    := row;
  e.col    := 0;
  e.curRow := curRow;
  e.curCol := curCol;
  e.line1  := NIL;
  e.line2  := NIL;
  undoStack[undoTop] := e;
  INC(undoTop)
END UndoSaveInsLine;

PROCEDURE UndoSaveDelLine(row: INTEGER);
(* Call before deleting line `row'. Saves its content. *)
VAR e: UndoEntry;
BEGIN
  IF undoTop >= MaxUndo THEN
    DEC(undoTop);
    IF undoStack[undoTop].line1 # NIL THEN FREE(undoStack[undoTop].line1) END;
    IF undoStack[undoTop].line2 # NIL THEN FREE(undoStack[undoTop].line2) END
  END;
  e.kind   := UKDel;
  e.row    := row;
  e.col    := 0;
  e.curRow := curRow;
  e.curCol := curCol;
  NEW(e.line1); COPY(lines[row].s, e.line1.s);
  e.line2  := NIL;
  undoStack[undoTop] := e;
  INC(undoTop)
END UndoSaveDelLine;

PROCEDURE DoUndo;
VAR e: UndoEntry; restBuf: LineBuf;
BEGIN
  IF undoTop = 0 THEN SetStatus("Nothing to undo"); RETURN END;
  DEC(undoTop);
  e := undoStack[undoTop];
  undoStack[undoTop].line1 := NIL;
  undoStack[undoTop].line2 := NIL;
  CASE e.kind OF
    UKLine:
      COPY(e.line1.s, lines[e.row].s);
      curRow := e.curRow;
      curCol := e.curCol
  | UKBreak:
      (* Undo Enter: restore original line, remove the split-off line *)
      COPY(e.line1.s, lines[e.row].s);
      ShiftLinesUp(e.row + 1);
      curRow := e.curRow;
      curCol := e.curCol
  | UKJoin:
      (* Undo join: re-split lines[e.row] at e.col, restore removed line *)
      Strings.Extract(lines[e.row].s, e.col, MaxLineLen, restBuf);
      lines[e.row].s[e.col] := 0X;
      ShiftLinesDown(e.row + 1);
      COPY(restBuf, lines[e.row + 1].s);
      curRow := e.curRow;
      curCol := e.curCol
  | UKIns:
      (* Undo insert-blank-line: delete it *)
      ShiftLinesUp(e.row);
      curRow := e.curRow;
      curCol := e.curCol
  | UKDel:
      (* Undo delete-line: re-insert it *)
      ShiftLinesDown(e.row);
      COPY(e.line1.s, lines[e.row].s);
      curRow := e.curRow;
      curCol := e.curCol
  END;
  IF e.line1 # NIL THEN FREE(e.line1) END;
  IF e.line2 # NIL THEN FREE(e.line2) END;
  dirty := TRUE;
  needRedraw := TRUE
END DoUndo;

(* ── File I/O ────────────────────────────────────────────────────── *)

PROCEDURE LoadFile(path: ARRAY OF CHAR): BOOLEAN;
VAR f: Files.File; r: Files.Rider; i: INTEGER;
BEGIN
  (* Free existing lines *)
  FOR i := 0 TO numLines - 1 DO
    IF lines[i] # NIL THEN FREE(lines[i]) END
  END;
  numLines := 0;
  f := Files.Old(path);
  IF f = NIL THEN
    (* New / non-existent file *)
    NEW(lines[0]); lines[0].s[0] := 0X;
    numLines := 1;
    COPY(path, filePath);
    dirty := FALSE;
    RETURN TRUE
  END;
  Files.Set(r, f, 0);
  WHILE ~r.eof & (numLines < MaxLines) DO
    NEW(lines[numLines]);
    Files.ReadLine(r, lines[numLines].s);
    IF ~r.eof OR (lines[numLines].s[0] # 0X) THEN
      INC(numLines)
    ELSE
      FREE(lines[numLines])
    END
  END;
  Files.Close(f);
  IF numLines = 0 THEN NEW(lines[0]); lines[0].s[0] := 0X; numLines := 1 END;
  COPY(path, filePath);
  dirty := FALSE;
  RETURN TRUE
END LoadFile;

PROCEDURE SaveFile(): BOOLEAN;
VAR f: Files.File; r: Files.Rider; i: INTEGER;
BEGIN
  IF filePath[0] = 0X THEN
    SetStatus("No filename — use ^KD after entering a name");
    RETURN FALSE
  END;
  f := Files.New(filePath);
  IF f = NIL THEN SetStatus("Save failed"); RETURN FALSE END;
  Files.Set(r, f, 0);
  FOR i := 0 TO numLines - 1 DO
    Files.WriteLine(r, lines[i].s)
  END;
  Files.Register(f);
  Files.Close(f);
  dirty := FALSE;
  SetStatus("Saved");
  RETURN TRUE
END SaveFile;

(* ── RTF Export (^KM) ────────────────────────────────────────────── *)

PROCEDURE MdSink(c: CHAR);
(* Markdown.WriteProc callback: writes wherever expRider currently
   points. Only one export runs at a time, so one shared rider is
   enough (see ExportRTF/ExportHtml/CompileRTF/CompileClean's HTML/RTF
   siblings). *)
BEGIN Files.Write(expRider, c) END MdSink;

PROCEDURE ExportRTF;
(* ^KM — Standard-manuscript-format RTF, matching pstar's ^KM output:
   12pt Times New Roman, double-spaced, 1-inch margins, first-line
   indent, chapter headings on new pages, *italic*/**bold** emphasis,
   smart typography (curly quotes, em dash, ellipsis), note lines
   stripped. Rendered via Markdown.mod's manuscript-mode RTF renderer. *)
VAR f: Files.File;
    rtfPath: ARRAY 512 OF CHAR;
    i, j: INTEGER;
BEGIN
  IF filePath[0] = 0X THEN SetStatus("Save file first (^KD)"); RETURN END;

  (* Derive output path: replace extension with .rtf *)
  COPY(filePath, rtfPath);
  j := Strings.Length(rtfPath) - 1;
  WHILE (j > 0) & (rtfPath[j] # '.') & (rtfPath[j] # '/') DO DEC(j) END;
  IF (j > 0) & (rtfPath[j] = '.') THEN rtfPath[j] := 0X END;
  Strings.Append(".rtf", rtfPath);

  f := Files.New(rtfPath);
  IF f = NIL THEN SetStatus("RTF export: cannot create file"); RETURN END;
  Files.Set(expRider, f, 0);

  Markdown.Reset;
  Markdown.RtfManuscriptHeader;
  FOR i := 0 TO numLines - 1 DO
    Markdown.RtfManuscriptLine(lines[i].s)
  END;
  Markdown.RtfManuscriptFooter;

  Files.Register(f);
  Files.Close(f);

  COPY("RTF exported: ", statusMsg);
  Strings.Append(rtfPath, statusMsg);
  needRedraw := TRUE
END ExportRTF;

PROCEDURE ExportHtml;
(* ^KJ — export this document as HTML via Markdown.mod's generic
   markdown-to-HTML renderer (headings, emphasis, links, lists, tables,
   blockquotes, code fences). Unlike ^K M this is plain single-spaced
   HTML, not manuscript format — Markdown.mod's HTML renderer has no
   manuscript mode. Note lines (".."), same convention as ^K M/^K E,
   are stripped before rendering since Markdown.mod doesn't know about
   them. *)
VAR f: Files.File;
    htmlPath: ARRAY 512 OF CHAR;
    i, j: INTEGER;
BEGIN
  IF filePath[0] = 0X THEN SetStatus("Save file first (^KD)"); RETURN END;

  COPY(filePath, htmlPath);
  j := Strings.Length(htmlPath) - 1;
  WHILE (j > 0) & (htmlPath[j] # '.') & (htmlPath[j] # '/') DO DEC(j) END;
  IF (j > 0) & (htmlPath[j] = '.') THEN htmlPath[j] := 0X END;
  Strings.Append(".html", htmlPath);

  f := Files.New(htmlPath);
  IF f = NIL THEN SetStatus("HTML export: cannot create file"); RETURN END;
  Files.Set(expRider, f, 0);

  Markdown.Reset;
  Markdown.HtmlHeader;
  FOR i := 0 TO numLines - 1 DO
    IF ~((lines[i].s[0] = '.') & (lines[i].s[1] = '.')) THEN
      Markdown.HtmlLine(lines[i].s)
    END
  END;
  Markdown.HtmlFooter;

  Files.Register(f);
  Files.Close(f);

  COPY("HTML exported: ", statusMsg);
  Strings.Append(htmlPath, statusMsg);
  needRedraw := TRUE
END ExportHtml;

PROCEDURE MakeTempPath(base, suffix: ARRAY OF CHAR; VAR out: ARRAY OF CHAR);
BEGIN COPY(base, out); Strings.Append(suffix, out) END MakeTempPath;

PROCEDURE EpubChapterTempPath(base: ARRAY OF CHAR; n: INTEGER; VAR out: ARRAY OF CHAR);
VAR num: ARRAY 16 OF CHAR;
BEGIN
  Strings.IntToStr(n, num);
  COPY(base, out); Strings.Append(".chapter", out); Strings.Append(num, out);
  Strings.Append(".tmp", out)
END EpubChapterTempPath;

PROCEDURE EpubChapterEntryName(n: INTEGER; VAR out: ARRAY OF CHAR);
VAR num: ARRAY 16 OF CHAR;
BEGIN
  Strings.IntToStr(n, num);
  COPY("OEBPS/chapter", out); Strings.Append(num, out); Strings.Append(".xhtml", out)
END EpubChapterEntryName;

PROCEDURE ExportEpub;
(* ^KG — EPUB export via Markdown.mod's Epub* renderer (one
   chapterN.xhtml per top-level heading + nav.xhtml, modeled on
   pstar's epub.rs — see Markdown.mod), packed into a real .epub
   archive by ZipWriter. Each member is built in its own temp file
   next to the source (removed afterward), the same way Markdown.mod's
   own doc comment describes layering ZIP bookkeeping atop its sink. *)
VAR f: Files.File;
    epubPath, tmpMime, tmpContainer, tmpOpf, tmpNav, tmpContent, entryName: ARRAY 512 OF CHAR;
    i, j, chapters: INTEGER; ok: BOOLEAN;
BEGIN
  IF filePath[0] = 0X THEN SetStatus("Save file first (^KD)"); RETURN END;

  COPY(filePath, epubPath);
  j := Strings.Length(epubPath) - 1;
  WHILE (j > 0) & (epubPath[j] # '.') & (epubPath[j] # '/') DO DEC(j) END;
  IF (j > 0) & (epubPath[j] = '.') THEN epubPath[j] := 0X END;
  Strings.Append(".epub", epubPath);

  MakeTempPath(epubPath, ".mime.tmp", tmpMime);
  MakeTempPath(epubPath, ".container.tmp", tmpContainer);
  MakeTempPath(epubPath, ".opf.tmp", tmpOpf);
  MakeTempPath(epubPath, ".nav.tmp", tmpNav);

  Markdown.Reset;

  f := Files.New(tmpMime);
  IF f = NIL THEN SetStatus("EPUB export: cannot create temp file"); RETURN END;
  Files.Set(expRider, f, 0);
  Markdown.EpubMimetype;
  Files.Register(f); Files.Close(f);

  f := Files.New(tmpContainer);
  Files.Set(expRider, f, 0);
  Markdown.EpubContainerXml;
  Files.Register(f); Files.Close(f);

  (* Each chapter's temp path is a deterministic function of epubPath
     and its chapter number, so it's recomputed on demand below rather
     than kept in a (potentially very large) array of paths. *)
  EpubChapterTempPath(epubPath, 1, tmpContent);
  f := Files.New(tmpContent);
  Files.Set(expRider, f, 0);
  Markdown.EpubContentHeader;
  FOR i := 0 TO numLines - 1 DO
    IF (Markdown.EpubChapterNum() < EpubMaxChapters) & Markdown.EpubStartsChapter(lines[i].s) THEN
      Markdown.EpubContentFooter;
      Files.Register(f); Files.Close(f);
      Markdown.EpubBeginChapter;
      EpubChapterTempPath(epubPath, Markdown.EpubChapterNum(), tmpContent);
      f := Files.New(tmpContent);
      Files.Set(expRider, f, 0);
      Markdown.EpubContentHeader
    END;
    Markdown.EpubLine(lines[i].s)
  END;
  Markdown.EpubContentFooter;
  Files.Register(f); Files.Close(f);
  chapters := Markdown.EpubChapterNum();

  f := Files.New(tmpOpf);
  Files.Set(expRider, f, 0);
  Markdown.EpubPackageOpf(chapters);
  Files.Register(f); Files.Close(f);

  f := Files.New(tmpNav);
  Files.Set(expRider, f, 0);
  Markdown.EpubNavXhtml;
  Files.Register(f); Files.Close(f);

  ok := ZipWriter.Begin(epubPath);
  ok := ZipWriter.Add("mimetype", tmpMime) & ok;
  ok := ZipWriter.Add("META-INF/container.xml", tmpContainer) & ok;
  ok := ZipWriter.Add("OEBPS/package.opf", tmpOpf) & ok;
  i := 1;
  WHILE i <= chapters DO
    EpubChapterTempPath(epubPath, i, tmpContent);
    EpubChapterEntryName(i, entryName);
    ok := ZipWriter.Add(entryName, tmpContent) & ok;
    INC(i)
  END;
  ok := ZipWriter.Add("OEBPS/nav.xhtml", tmpNav) & ok;
  ok := ZipWriter.Finish() & ok;

  Files.Delete(tmpMime); Files.Delete(tmpContainer); Files.Delete(tmpOpf);
  i := 1;
  WHILE i <= chapters DO
    EpubChapterTempPath(epubPath, i, tmpContent); Files.Delete(tmpContent); INC(i)
  END;
  Files.Delete(tmpNav);

  IF ok THEN
    COPY("EPUB exported: ", statusMsg); Strings.Append(epubPath, statusMsg)
  ELSE
    SetStatus("EPUB export failed")
  END;
  needRedraw := TRUE
END ExportEpub;

(* ── Clean Export (^KE) ─────────────────────────────────────────── *)

PROCEDURE ExportClean;
(* Write all non-note lines to <basename>.txt, stripping .. note lines. *)
VAR f: Files.File; r: Files.Rider;
    txtPath: ARRAY 512 OF CHAR;
    i, j: INTEGER;
BEGIN
  IF filePath[0] = 0X THEN SetStatus("Save file first (^KD)"); RETURN END;
  COPY(filePath, txtPath);
  j := Strings.Length(txtPath) - 1;
  WHILE (j > 0) & (txtPath[j] # '.') & (txtPath[j] # '/') DO DEC(j) END;
  IF (j > 0) & (txtPath[j] = '.') THEN txtPath[j] := 0X END;
  Strings.Append(".txt", txtPath);
  f := Files.New(txtPath);
  IF f = NIL THEN SetStatus("Clean export: cannot create file"); RETURN END;
  Files.Set(r, f, 0);
  FOR i := 0 TO numLines - 1 DO
    IF ~((lines[i].s[0] = '.') & (lines[i].s[1] = '.')) THEN
      Files.WriteLine(r, lines[i].s)
    END
  END;
  Files.Register(f);
  Files.Close(f);
  SetStatus("Exported: ");
  Strings.Append(txtPath, statusMsg);
  needRedraw := TRUE
END ExportClean;

(* ── Snapshot / Backup (^KN) ─────────────────────────────────────── *)

PROCEDURE SaveSnapshot;
(* Save a dated copy of the file as <basename>.YYYYMMDD-HHMMSS.bak *)
VAR f: Files.File; r: Files.Rider;
    bakPath, stamp: ARRAY 512 OF CHAR;
    i, j: INTEGER;
BEGIN
  IF filePath[0] = 0X THEN SetStatus("Save file first (^KD)"); RETURN END;
  COPY(filePath, bakPath);
  j := Strings.Length(bakPath) - 1;
  WHILE (j > 0) & (bakPath[j] # '.') & (bakPath[j] # '/') DO DEC(j) END;
  IF (j > 0) & (bakPath[j] = '.') THEN bakPath[j] := 0X END;
  Time.Format(Time.Now(), "%Y%m%d-%H%M%S", stamp);
  Strings.Append(".", bakPath);
  Strings.Append(stamp, bakPath);
  Strings.Append(".bak", bakPath);
  f := Files.New(bakPath);
  IF f = NIL THEN SetStatus("Snapshot: cannot create file"); RETURN END;
  Files.Set(r, f, 0);
  FOR i := 0 TO numLines - 1 DO
    Files.WriteLine(r, lines[i].s)
  END;
  Files.Register(f);
  Files.Close(f);
  SetStatus("Snapshot: ");
  Strings.Append(bakPath, statusMsg);
  needRedraw := TRUE
END SaveSnapshot;

PROCEDURE ListRevisions;
(* ^KO — browse the snapshots ^KN has taken of this document. *)
VAR base, prefix, name: ARRAY 512 OF CHAR; j, i, n: INTEGER;
BEGIN
  IF filePath[0] = 0X THEN SetStatus("Save this file first"); needRedraw := TRUE; RETURN END;
  COPY(filePath, base);
  j := Strings.Length(base) - 1;
  WHILE (j > 0) & (base[j] # '/') DO DEC(j) END;
  IF base[j] = '/' THEN
    Strings.Extract(base, 0, j, revDir);
    Strings.Extract(base, j + 1, Strings.Length(base) - j - 1, prefix)
  ELSE
    revDir[0] := 0X;
    COPY(base, prefix)
  END;
  (* Strip the basename's own extension, matching SaveSnapshot's naming *)
  j := Strings.Length(prefix) - 1;
  WHILE (j > 0) & (prefix[j] # '.') DO DEC(j) END;
  IF (j > 0) & (prefix[j] = '.') THEN prefix[j] := 0X END;
  Strings.Append(".", prefix);

  OS.DirOpen(revDir, ".bak");
  n := OS.DirCount();
  revCount := 0;
  FOR i := 0 TO n - 1 DO
    IF (revCount < MaxRevisions) & ~OS.DirIsDir(i) THEN
      OS.DirName(i, name);
      IF Strings.StartsWith(name, prefix) THEN
        COPY(name, revNames[revCount]);
        INC(revCount)
      END
    END
  END;
  IF revCount = 0 THEN
    SetStatus("No snapshots for this file (^KN to make one)"); needRedraw := TRUE; RETURN
  END;
  revSel := revCount - 1;  (* timestamps sort ascending, so this is most recent *)
  revScroll := 0;
  mode := ModeRevisions;
  needRedraw := TRUE
END ListRevisions;

(* ── Text Editing ────────────────────────────────────────────────── *)

PROCEDURE InsChar(c: CHAR);
VAR tmp: ARRAY 2 OF CHAR;
BEGIN
  IF LineLen(curRow) >= MaxLineLen THEN RETURN END;
  UndoSaveLine;
  tmp[0] := c; tmp[1] := 0X;
  IF overtype & (curCol < LineLen(curRow)) THEN
    lines[curRow].s[curCol] := c
  ELSE
    Strings.Insert(tmp, curCol, lines[curRow].s)
  END;
  INC(curCol);
  dirty := TRUE;
  needRedraw := TRUE
END InsChar;

PROCEDURE InsUTF8(seq: ARRAY OF CHAR; n: INTEGER);
(* Insert a full multi-byte UTF-8 character (n bytes, from ReadUTF8Seq)
   as one unit. Always inserts (rather than overtyping) since replacing
   exactly one prior on-screen cell isn't well defined when the byte
   widths differ. *)
BEGIN
  IF LineLen(curRow) + n > MaxLineLen THEN RETURN END;
  UndoSaveLine;
  Strings.Insert(seq, curCol, lines[curRow].s);
  INC(curCol, n);
  dirty := TRUE;
  needRedraw := TRUE
END InsUTF8;

PROCEDURE InsTab;
VAR spaces: INTEGER; tmp: ARRAY 2 OF CHAR; i: INTEGER;
BEGIN
  (* Expand tab to the next 4-column tab stop *)
  spaces := 4 - (curCol MOD 4);
  FOR i := 1 TO spaces DO InsChar(' ') END
END InsTab;

PROCEDURE DelChar;
(* Delete char under cursor (^G / Del) *)
VAR len, n: INTEGER;
BEGIN
  len := LineLen(curRow);
  IF curCol < len THEN
    UndoSaveLine;
    n := UTF8SeqLen(lines[curRow].s[curCol]);
    IF curCol + n > len THEN n := 1 END;  (* truncated/invalid sequence *)
    Strings.Delete(lines[curRow].s, curCol, n);
    dirty := TRUE; needRedraw := TRUE
  ELSIF curRow < numLines - 1 THEN
    UndoSaveJoin(curRow, len);
    IF LineLen(curRow) + LineLen(curRow + 1) <= MaxLineLen THEN
      Strings.Append(lines[curRow + 1].s, lines[curRow].s);
      ShiftLinesUp(curRow + 1)
    END;
    dirty := TRUE; needRedraw := TRUE
  END
END DelChar;

PROCEDURE BackspaceChar;
(* Delete char before cursor (^H / Backspace) *)
VAR upperLen, delFrom, n: INTEGER;
BEGIN
  IF curCol > 0 THEN
    UndoSaveLine;
    delFrom := curCol - 1;
    WHILE (delFrom > 0) & IsContByte(lines[curRow].s[delFrom]) DO DEC(delFrom) END;
    n := curCol - delFrom;
    Strings.Delete(lines[curRow].s, delFrom, n);
    curCol := delFrom;
    dirty := TRUE; needRedraw := TRUE
  ELSIF curRow > 0 THEN
    upperLen := LineLen(curRow - 1);
    UndoSaveJoin(curRow - 1, upperLen);
    IF upperLen + LineLen(curRow) <= MaxLineLen THEN
      Strings.Append(lines[curRow].s, lines[curRow - 1].s);
      ShiftLinesUp(curRow);
      DEC(curRow);
      curCol := upperLen
    END;
    dirty := TRUE; needRedraw := TRUE
  END
END BackspaceChar;

PROCEDURE BreakLine;
(* Insert newline at cursor (Enter) *)
VAR restBuf: LineBuf;
BEGIN
  UndoSaveBreak;
  Strings.Extract(lines[curRow].s, curCol, MaxLineLen, restBuf);
  lines[curRow].s[curCol] := 0X;
  ShiftLinesDown(curRow + 1);
  COPY(restBuf, lines[curRow + 1].s);
  INC(curRow); curCol := 0;
  dirty := TRUE; needRedraw := TRUE
END BreakLine;

PROCEDURE DeleteWordRight;
(* ^T — delete word to the right of cursor *)
VAR len, i: INTEGER;
BEGIN
  len := LineLen(curRow);
  IF curCol >= len THEN
    (* At end of line: join with next (same as Del at EOL) *)
    DelChar; RETURN
  END;
  UndoSaveLine;
  i := curCol;
  (* Skip any non-word chars first, then word chars *)
  WHILE (i < len) & ~IsWordChar(lines[curRow].s[i]) DO INC(i) END;
  WHILE (i < len) & IsWordChar(lines[curRow].s[i]) DO INC(i) END;
  Strings.Delete(lines[curRow].s, curCol, i - curCol);
  dirty := TRUE; needRedraw := TRUE
END DeleteWordRight;

PROCEDURE DeleteLine;
(* ^Y — delete current line to kill ring, leave cursor on same row *)
VAR slot, i: INTEGER;
BEGIN
  UndoSaveDelLine(curRow);
  (* Put the line in the kill ring *)
  slot := killHead MOD KRSlots;
  FOR i := 0 TO killRing[slot].n - 1 DO
    IF killRing[slot].data[i] # NIL THEN FREE(killRing[slot].data[i]) END
  END;
  killRing[slot].n := 1;
  killRing[slot].data[0] := NIL;
  NEW(killRing[slot].data[0]);
  COPY(lines[curRow].s, killRing[slot].data[0].s);
  killHead := (killHead + 1) MOD KRSlots;
  IF killCount < KRSlots THEN INC(killCount) END;
  putIndex := 0;
  ShiftLinesUp(curRow);
  IF curRow >= numLines THEN curRow := numLines - 1 END;
  curCol := 0;
  dirty := TRUE; needRedraw := TRUE
END DeleteLine;

PROCEDURE DeleteToEOL;
(* ^QY — delete from cursor to end of line *)
VAR len: INTEGER;
BEGIN
  len := LineLen(curRow);
  IF curCol < len THEN
    UndoSaveLine;
    lines[curRow].s[curCol] := 0X;
    dirty := TRUE; needRedraw := TRUE
  END
END DeleteToEOL;

PROCEDURE InsertBlankLine;
(* ^N — insert blank line before cursor *)
BEGIN
  ShiftLinesDown(curRow);
  UndoSaveInsLine(curRow);
  dirty := TRUE; needRedraw := TRUE
END InsertBlankLine;

(* ── Cursor Movement ─────────────────────────────────────────────── *)

PROCEDURE ClampCursor;
(* Ensure curRow/curCol are within buffer bounds *)
BEGIN
  IF curRow < 0 THEN curRow := 0 END;
  IF curRow >= numLines THEN curRow := numLines - 1 END;
  IF curCol < 0 THEN curCol := 0 END;
  IF curCol > LineLen(curRow) THEN curCol := LineLen(curRow) END
END ClampCursor;

(* ── Soft-wrap segment helpers ──────────────────────────────────────── *)

PROCEDURE SegEnd(row, from: INTEGER): INTEGER;
(* One-past-end column of the wrap segment starting at 'from'. *)
VAR len, bp: INTEGER;
BEGIN
  len := LineLen(row);
  IF ~wrap OR (len - from <= wrapMargin) THEN RETURN len END;
  bp := from + wrapMargin;
  WHILE (bp > from) & (lines[row].s[bp] # ' ') DO DEC(bp) END;
  IF bp = from THEN RETURN from + wrapMargin END;
  RETURN bp
END SegEnd;

PROCEDURE SegNext(row, from: INTEGER): INTEGER;
(* Start column of the next segment after the segment beginning at 'from'. *)
VAR e: INTEGER;
BEGIN
  e := SegEnd(row, from);
  IF (e < LineLen(row)) & (lines[row].s[e] = ' ') THEN RETURN e + 1 END;
  RETURN e
END SegNext;

PROCEDURE NumSegs(row: INTEGER): INTEGER;
(* Number of visual screen rows that buffer line 'row' occupies. *)
VAR n, from: INTEGER;
BEGIN
  n := 0; from := 0;
  LOOP
    INC(n);
    IF SegEnd(row, from) >= LineLen(row) THEN EXIT END;
    from := SegNext(row, from)
  END;
  RETURN n
END NumSegs;

PROCEDURE CurSeg(VAR segFrom: INTEGER);
(* Set segFrom to the start column of the wrap segment containing curCol. *)
VAR from, e: INTEGER;
BEGIN
  from := 0;
  LOOP
    e := SegEnd(curRow, from);
    segFrom := from;
    IF e >= LineLen(curRow) THEN EXIT END;
    IF curCol < e THEN EXIT END;
    from := SegNext(curRow, from)
  END
END CurSeg;

PROCEDURE MoveUp;
VAR sf, from, prevSF: INTEGER;
BEGIN
  IF wrap THEN
    CurSeg(sf);
    IF goalCol < 0 THEN goalCol := curCol - sf END;
    IF sf > 0 THEN
      (* Previous visual row is previous segment of same buffer line *)
      from := 0; prevSF := 0;
      WHILE from < sf DO prevSF := from; from := SegNext(curRow, from) END;
      curCol := prevSF + goalCol;
      IF curCol > LineLen(curRow) THEN curCol := LineLen(curRow) END
    ELSIF curRow > 0 THEN
      DEC(curRow);
      (* Find last segment of new curRow *)
      from := 0;
      WHILE SegEnd(curRow, from) < LineLen(curRow) DO
        from := SegNext(curRow, from)
      END;
      curCol := from + goalCol;
      IF curCol > LineLen(curRow) THEN curCol := LineLen(curRow) END
    END
  ELSE
    IF goalCol < 0 THEN goalCol := curCol END;
    IF curRow > 0 THEN
      DEC(curRow);
      curCol := Min(goalCol, LineLen(curRow))
    END
  END;
  needRedraw := TRUE
END MoveUp;

PROCEDURE MoveDown;
VAR sf, e, nf: INTEGER;
BEGIN
  IF wrap THEN
    CurSeg(sf);
    IF goalCol < 0 THEN goalCol := curCol - sf END;
    e := SegEnd(curRow, sf);
    IF e < LineLen(curRow) THEN
      (* Next visual row is next segment in same buffer line *)
      nf := SegNext(curRow, sf);
      curCol := nf + goalCol;
      IF curCol > LineLen(curRow) THEN curCol := LineLen(curRow) END
    ELSIF curRow < numLines - 1 THEN
      INC(curRow);
      curCol := goalCol;
      IF curCol > LineLen(curRow) THEN curCol := LineLen(curRow) END
    END
  ELSE
    IF goalCol < 0 THEN goalCol := curCol END;
    IF curRow < numLines - 1 THEN
      INC(curRow);
      curCol := Min(goalCol, LineLen(curRow))
    END
  END;
  needRedraw := TRUE
END MoveDown;

PROCEDURE MoveLeft;
BEGIN
  goalCol := -1;
  IF curCol > 0 THEN
    DEC(curCol);
    WHILE (curCol > 0) & IsContByte(lines[curRow].s[curCol]) DO DEC(curCol) END
  ELSIF curRow > 0 THEN DEC(curRow); curCol := LineLen(curRow)
  END;
  needRedraw := TRUE
END MoveLeft;

PROCEDURE MoveRight;
VAR len: INTEGER;
BEGIN
  goalCol := -1;
  len := LineLen(curRow);
  IF curCol < len THEN
    INC(curCol, UTF8SeqLen(lines[curRow].s[curCol]));
    IF curCol > len THEN curCol := len END
  ELSIF curRow < numLines - 1 THEN INC(curRow); curCol := 0
  END;
  needRedraw := TRUE
END MoveRight;

PROCEDURE MoveWordLeft;
(* ^A — move one word to the left *)
BEGIN
  goalCol := -1;
  IF curCol = 0 THEN
    IF curRow > 0 THEN DEC(curRow); curCol := LineLen(curRow) END
  ELSE
    DEC(curCol);
    WHILE (curCol > 0) & ~IsWordChar(lines[curRow].s[curCol]) DO DEC(curCol) END;
    WHILE (curCol > 0) & IsWordChar(lines[curRow].s[curCol - 1]) DO DEC(curCol) END
  END;
  needRedraw := TRUE
END MoveWordLeft;

PROCEDURE MoveWordRight;
(* ^F — move one word to the right *)
VAR len: INTEGER;
BEGIN
  goalCol := -1;
  len := LineLen(curRow);
  IF curCol >= len THEN
    IF curRow < numLines - 1 THEN INC(curRow); curCol := 0 END
  ELSE
    WHILE (curCol < len) & ~IsWordChar(lines[curRow].s[curCol]) DO INC(curCol) END;
    WHILE (curCol < len) & IsWordChar(lines[curRow].s[curCol]) DO INC(curCol) END
  END;
  needRedraw := TRUE
END MoveWordRight;

PROCEDURE MoveLineStart;
(* ^QS *)
BEGIN goalCol := -1; curCol := 0; needRedraw := TRUE END MoveLineStart;

PROCEDURE MoveLineEnd;
(* ^QD *)
BEGIN goalCol := -1; curCol := LineLen(curRow); needRedraw := TRUE END MoveLineEnd;

PROCEDURE MoveDocStart;
(* ^QR *)
BEGIN SavePrev; goalCol := -1; curRow := 0; curCol := 0; needRedraw := TRUE END MoveDocStart;

PROCEDURE MoveDocEnd;
(* ^QC *)
BEGIN
  SavePrev; goalCol := -1;
  curRow := numLines - 1;
  curCol := LineLen(curRow);
  needRedraw := TRUE
END MoveDocEnd;

PROCEDURE ScrollUp;
(* ^W — scroll view up (cursor follows) *)
BEGIN
  IF topLine > 0 THEN
    DEC(topLine);
    IF curRow > topLine + TUI.Rows - 2 THEN
      curRow := topLine + TUI.Rows - 2
    END;
    ClampCursor
  END;
  needRedraw := TRUE
END ScrollUp;

PROCEDURE ScrollDown;
(* ^Z — scroll view down *)
BEGIN
  INC(topLine);
  IF topLine >= numLines THEN topLine := numLines - 1 END;
  IF curRow < topLine THEN curRow := topLine END;
  ClampCursor;
  needRedraw := TRUE
END ScrollDown;

PROCEDURE PageUp;
(* ^R *)
VAR h: INTEGER;
BEGIN
  goalCol := -1;
  h := Max(1, TUI.Rows - 1);
  DEC(curRow, h); DEC(topLine, h);
  IF topLine < 0 THEN topLine := 0 END;
  ClampCursor;
  needRedraw := TRUE
END PageUp;

PROCEDURE PageDown;
(* ^C *)
VAR h: INTEGER;
BEGIN
  goalCol := -1;
  h := Max(1, TUI.Rows - 1);
  INC(curRow, h); INC(topLine, h);
  IF topLine >= numLines THEN topLine := numLines - 1 END;
  ClampCursor;
  needRedraw := TRUE
END PageDown;

PROCEDURE ScreenTop;
(* ^QE *)
BEGIN
  goalCol := -1;
  curRow := topLine;
  curCol := Min(curCol, LineLen(curRow));
  needRedraw := TRUE
END ScreenTop;

PROCEDURE ScreenBottom;
(* ^QX *)
VAR h: INTEGER;
BEGIN
  goalCol := -1;
  h := Max(1, TUI.Rows - 1);
  curRow := Min(topLine + h - 1, numLines - 1);
  curCol := Min(curCol, LineLen(curRow));
  needRedraw := TRUE
END ScreenBottom;

PROCEDURE SavePrev;
BEGIN prevRow := curRow; prevCol := curCol; hasPrev := TRUE END SavePrev;

PROCEDURE JumpPrev;
(* ^QP — jump to position before last large move *)
VAR r, c: INTEGER;
BEGIN
  IF ~hasPrev THEN SetStatus("No previous position"); RETURN END;
  r := prevRow; c := prevCol;
  SavePrev;
  curRow := r; curCol := c;
  goalCol := -1; needRedraw := TRUE
END JumpPrev;

PROCEDURE JumpBlockBegin;
(* ^QB *)
BEGIN
  IF ~hasBlkB THEN SetStatus("No block begin marked"); RETURN END;
  SavePrev;
  curRow := blkBRow; curCol := blkBCol;
  goalCol := -1; needRedraw := TRUE
END JumpBlockBegin;

PROCEDURE JumpBlockEnd;
(* ^QK *)
BEGIN
  IF ~hasBlkE THEN SetStatus("No block end marked"); RETURN END;
  SavePrev;
  curRow := blkERow; curCol := blkECol;
  goalCol := -1; needRedraw := TRUE
END JumpBlockEnd;

PROCEDURE MoveSentBack;
(* ^Q, — move to start of previous sentence (. ! ? followed by space/newline) *)
VAR r, c: INTEGER; ch: CHAR;
BEGIN
  SavePrev;
  r := curRow; c := curCol - 1;
  LOOP
    IF c < 0 THEN
      IF r = 0 THEN EXIT END;
      DEC(r); c := LineLen(r)
    END;
    IF c > 0 THEN
      ch := lines[r].s[c - 1];
      IF (ch = '.') OR (ch = '!') OR (ch = '?') THEN
        (* skip whitespace after the punctuation *)
        INC(c);
        WHILE (c < LineLen(r)) & (lines[r].s[c] = ' ') DO INC(c) END;
        curRow := r; curCol := c; goalCol := -1; needRedraw := TRUE;
        RETURN
      END
    END;
    DEC(c)
  END;
  curRow := 0; curCol := 0; goalCol := -1; needRedraw := TRUE
END MoveSentBack;

PROCEDURE MoveSentForward;
(* ^Q. — move to start of next sentence *)
VAR r, c, len: INTEGER; ch: CHAR;
BEGIN
  SavePrev;
  r := curRow; c := curCol;
  LOOP
    len := LineLen(r);
    WHILE c < len DO
      ch := lines[r].s[c];
      IF (ch = '.') OR (ch = '!') OR (ch = '?') THEN
        INC(c);
        WHILE (c < len) & (lines[r].s[c] = ' ') DO INC(c) END;
        IF c < len THEN
          curRow := r; curCol := c; goalCol := -1; needRedraw := TRUE; RETURN
        END
      END;
      INC(c)
    END;
    INC(r);
    IF r >= numLines THEN
      curRow := numLines - 1; curCol := LineLen(curRow);
      goalCol := -1; needRedraw := TRUE; RETURN
    END;
    c := 0
  END
END MoveSentForward;

PROCEDURE MoveParaBack;
(* ^Q[ — move to start of previous paragraph (blank-line delimited) *)
VAR r: INTEGER;
BEGIN
  SavePrev;
  r := curRow;
  (* If already on a blank line, step off it first *)
  IF LineLen(r) = 0 THEN DEC(r) END;
  (* Skip back over non-blank lines *)
  WHILE (r > 0) & (LineLen(r) > 0) DO DEC(r) END;
  (* Skip back over blank lines *)
  WHILE (r > 0) & (LineLen(r) = 0) DO DEC(r) END;
  (* Now find start of this paragraph *)
  WHILE (r > 0) & (LineLen(r - 1) > 0) DO DEC(r) END;
  curRow := r; curCol := 0; goalCol := -1; needRedraw := TRUE
END MoveParaBack;

PROCEDURE MoveParaForward;
(* ^Q] — move to start of next paragraph *)
VAR r: INTEGER;
BEGIN
  SavePrev;
  r := curRow;
  (* Skip over current non-blank lines *)
  WHILE (r < numLines) & (LineLen(r) > 0) DO INC(r) END;
  (* Skip blank lines *)
  WHILE (r < numLines) & (LineLen(r) = 0) DO INC(r) END;
  IF r >= numLines THEN r := numLines - 1 END;
  curRow := r; curCol := 0; goalCol := -1; needRedraw := TRUE
END MoveParaForward;

PROCEDURE MoveNextHeading;
(* ^QO — jump to next Markdown heading (line starting with #) *)
VAR r: INTEGER;
BEGIN
  r := curRow + 1;
  WHILE (r < numLines) & (lines[r].s[0] # '#') DO INC(r) END;
  IF r < numLines THEN
    SavePrev;
    curRow := r; curCol := 0; goalCol := -1; needRedraw := TRUE
  ELSE SetStatus("No next heading")
  END
END MoveNextHeading;

PROCEDURE NextComment;
(* ^QM — jump to next line starting with .. *)
VAR r: INTEGER;
BEGIN
  r := curRow + 1;
  WHILE (r < numLines) & ~((lines[r].s[0] = '.') & (lines[r].s[1] = '.')) DO INC(r) END;
  IF r < numLines THEN
    SavePrev; curRow := r; curCol := 0; goalCol := -1; needRedraw := TRUE
  ELSE SetStatus("No next comment")
  END
END NextComment;

PROCEDURE PrevComment;
(* ^QU — jump to previous line starting with .. *)
VAR r: INTEGER;
BEGIN
  r := curRow - 1;
  WHILE (r >= 0) & ~((lines[r].s[0] = '.') & (lines[r].s[1] = '.')) DO DEC(r) END;
  IF r >= 0 THEN
    SavePrev; curRow := r; curCol := 0; goalCol := -1; needRedraw := TRUE
  ELSE SetStatus("No previous comment")
  END
END PrevComment;

PROCEDURE TransposeChars;
(* ^QG — swap char at cursor with char to its left *)
VAR tmp: CHAR; len: INTEGER;
BEGIN
  len := LineLen(curRow);
  IF (curCol = 0) OR (len = 0) THEN SetStatus("Nothing to transpose"); RETURN END;
  IF curCol >= len THEN curCol := len END;
  UndoSaveLine;
  tmp := lines[curRow].s[curCol - 1];
  lines[curRow].s[curCol - 1] := lines[curRow].s[curCol];
  lines[curRow].s[curCol] := tmp;
  IF curCol < len THEN INC(curCol) END;
  dirty := TRUE; needRedraw := TRUE
END TransposeChars;

PROCEDURE TransposeWords;
(* ^QT — swap word at/after cursor with the following word on same line *)
VAR w1s, w1e, w2s, w2e: INTEGER;
    prefix, word1, gap, word2, suffix: LineBuf;
BEGIN
  w1s := curCol;
  WHILE (w1s < LineLen(curRow)) & ~IsWordChar(lines[curRow].s[w1s]) DO INC(w1s) END;
  IF w1s >= LineLen(curRow) THEN SetStatus("No word to transpose"); RETURN END;
  w1e := w1s;
  WHILE (w1e < LineLen(curRow)) & IsWordChar(lines[curRow].s[w1e]) DO INC(w1e) END;
  w2s := w1e;
  WHILE (w2s < LineLen(curRow)) & ~IsWordChar(lines[curRow].s[w2s]) DO INC(w2s) END;
  IF w2s >= LineLen(curRow) THEN SetStatus("No second word to transpose"); RETURN END;
  w2e := w2s;
  WHILE (w2e < LineLen(curRow)) & IsWordChar(lines[curRow].s[w2e]) DO INC(w2e) END;
  UndoSaveLine;
  Strings.Extract(lines[curRow].s, 0,   w1s,       prefix);
  Strings.Extract(lines[curRow].s, w1s, w1e - w1s, word1);
  Strings.Extract(lines[curRow].s, w1e, w2s - w1e, gap);
  Strings.Extract(lines[curRow].s, w2s, w2e - w2s, word2);
  Strings.Extract(lines[curRow].s, w2e, MaxLineLen, suffix);
  COPY(prefix, lines[curRow].s);
  Strings.Append(word2, lines[curRow].s);
  Strings.Append(gap,   lines[curRow].s);
  Strings.Append(word1, lines[curRow].s);
  Strings.Append(suffix,lines[curRow].s);
  curCol := w1s + Strings.Length(word2);
  dirty := TRUE; needRedraw := TRUE
END TransposeWords;

PROCEDURE EnsureVisible;
VAR h, vrow, row, from, e, segF: INTEGER;
BEGIN
  h := Max(1, TUI.Rows - 1);
  IF typewriter THEN
    topLine := curRow - h DIV 2;
    IF topLine < 0 THEN topLine := 0 END
  ELSIF ~wrap THEN
    IF curRow < topLine THEN topLine := curRow END;
    IF curRow >= topLine + h THEN topLine := curRow - h + 1 END
  ELSE
    (* Scroll up if cursor is above top *)
    IF curRow < topLine THEN topLine := curRow; RETURN END;
    (* Count visual rows from topLine to cursor's segment *)
    CurSeg(segF);
    vrow := 0;
    FOR row := topLine TO curRow - 1 DO vrow := vrow + NumSegs(row) END;
    (* Add segment offset within curRow *)
    from := 0;
    WHILE from < segF DO INC(vrow); from := SegNext(curRow, from) END;
    IF vrow < h THEN RETURN END;  (* cursor already visible *)
    (* Cursor below screen: advance topLine until cursor fits *)
    WHILE (vrow >= h) & (topLine < curRow) DO
      vrow := vrow - NumSegs(topLine);
      INC(topLine)
    END;
    IF vrow >= h THEN topLine := curRow END
  END
END EnsureVisible;

(* ── Block Marks & Kill Ring ─────────────────────────────────────── *)

PROCEDURE BlockBegin;
(* ^KB *)
BEGIN
  (* Remember the block we're about to replace, if it was a complete one,
     so ^KU (BlockPrev) can jump back to it. *)
  IF hasBlkB & hasBlkE THEN
    prevBlkBRow := blkBRow; prevBlkBCol := blkBCol;
    prevBlkERow := blkERow; prevBlkECol := blkECol;
    hasPrevBlk := TRUE
  END;
  hasBlkB := TRUE; hasBlkE := FALSE;
  blkBRow := curRow; blkBCol := curCol;
  SetStatus("Block begin marked");
  needRedraw := TRUE
END BlockBegin;

PROCEDURE BlockPrev;
(* ^KU — jump to the previously-marked block, so re-marking a block
   elsewhere doesn't lose track of the last one. *)
BEGIN
  IF ~hasPrevBlk THEN SetStatus("No previous block"); RETURN END;
  SavePrev;
  curRow := prevBlkBRow; curCol := prevBlkBCol;
  goalCol := -1; needRedraw := TRUE
END BlockPrev;

PROCEDURE BlockEnd;
(* ^KK *)
BEGIN
  IF ~hasBlkB THEN SetStatus("No block begin — use ^KB first"); RETURN END;
  hasBlkE := TRUE;
  blkERow := curRow; blkECol := curCol;
  SetStatus("Block end marked");
  needRedraw := TRUE
END BlockEnd;

PROCEDURE BlockHide;
(* ^KH — toggle block visibility *)
BEGIN
  IF hasBlkB OR hasBlkE THEN
    hasBlkB := FALSE; hasBlkE := FALSE;
    SetStatus("Block hidden")
  ELSE
    SetStatus("No block marked")
  END;
  needRedraw := TRUE
END BlockHide;

PROCEDURE KillPushBlock(r1, c1, r2, c2: INTEGER);
(* Copy lines[r1,c1 .. r2,c2) into the kill ring. *)
VAR slot, i: INTEGER; kb: KillBlock;
BEGIN
  slot := killHead MOD KRSlots;
  FOR i := 0 TO killRing[slot].n - 1 DO
    IF killRing[slot].data[i] # NIL THEN FREE(killRing[slot].data[i]) END
  END;
  kb.n := 0;
  IF r1 = r2 THEN
    (* Single partial line *)
    NEW(kb.data[0]);
    Strings.Extract(lines[r1].s, c1, c2 - c1, kb.data[0].s);
    kb.n := 1
  ELSE
    (* First (partial) line *)
    NEW(kb.data[kb.n]);
    Strings.Extract(lines[r1].s, c1, MaxLineLen, kb.data[kb.n].s);
    INC(kb.n);
    (* Middle lines *)
    i := r1 + 1;
    WHILE (i < r2) & (kb.n < KRLines) DO
      NEW(kb.data[kb.n]);
      COPY(lines[i].s, kb.data[kb.n].s);
      INC(kb.n); INC(i)
    END;
    (* Last partial line *)
    IF kb.n < KRLines THEN
      NEW(kb.data[kb.n]);
      Strings.Extract(lines[r2].s, 0, c2, kb.data[kb.n].s);
      INC(kb.n)
    END
  END;
  killRing[slot] := kb;
  killHead := (killHead + 1) MOD KRSlots;
  IF killCount < KRSlots THEN INC(killCount) END;
  putIndex := 0
END KillPushBlock;

PROCEDURE KillPut;
(* ^KP — paste most-recent kill ring entry at cursor, cycling on repeats *)
VAR kb: KillBlock; slot, i, insertRow: INTEGER; afterBuf: LineBuf;
BEGIN
  IF killCount = 0 THEN SetStatus("Kill ring empty"); RETURN END;
  slot := (killHead - 1 - putIndex + KRSlots * 2) MOD KRSlots;
  IF putIndex >= killCount THEN putIndex := 0; slot := (killHead - 1 + KRSlots) MOD KRSlots END;
  kb := killRing[slot];
  IF kb.n = 0 THEN SetStatus("Empty clipping"); RETURN END;
  (* Insert kb at cursor position *)
  IF kb.n = 1 THEN
    UndoSaveLine;
    IF LineLen(curRow) + Strings.Length(kb.data[0].s) <= MaxLineLen THEN
      Strings.Insert(kb.data[0].s, curCol, lines[curRow].s);
      INC(curCol, Strings.Length(kb.data[0].s))
    END
  ELSE
    (* Multi-line paste: split current line, insert lines, rejoin last *)
    UndoSaveBreak;
    Strings.Extract(lines[curRow].s, curCol, MaxLineLen, afterBuf);
    lines[curRow].s[curCol] := 0X;
    Strings.Append(kb.data[0].s, lines[curRow].s);
    insertRow := curRow + 1;
    FOR i := 1 TO kb.n - 1 DO
      ShiftLinesDown(insertRow);
      COPY(kb.data[i].s, lines[insertRow].s);
      INC(insertRow)
    END;
    curRow := insertRow - 1;
    curCol := Strings.Length(lines[curRow].s);
    IF LineLen(curRow) + Strings.Length(afterBuf) <= MaxLineLen THEN
      Strings.Append(afterBuf, lines[curRow].s)
    END
  END;
  dirty := TRUE; needRedraw := TRUE
END KillPut;

PROCEDURE BlockCopy;
(* ^KC — copy marked block to cursor *)
VAR r1, c1, r2, c2: INTEGER; before, after: Line; i, insertAt: INTEGER;
    kb: KillBlock;
BEGIN
  IF ~hasBlkB OR ~hasBlkE THEN SetStatus("No block marked"); RETURN END;
  NormBlock(r1, c1, r2, c2);
  KillPushBlock(r1, c1, r2, c2);
  (* Now paste at cursor *)
  KillPut;
  SetStatus("Block copied")
END BlockCopy;

PROCEDURE BlockDelete;
(* ^KY — delete marked block *)
VAR r1, c1, r2, c2, i: INTEGER; restBuf: LineBuf;
BEGIN
  IF ~hasBlkB OR ~hasBlkE THEN SetStatus("No block marked"); RETURN END;
  NormBlock(r1, c1, r2, c2);
  KillPushBlock(r1, c1, r2, c2);
  IF r1 = r2 THEN
    UndoSaveLine;
    Strings.Delete(lines[r1].s, c1, c2 - c1);
    curRow := r1; curCol := c1
  ELSE
    (* Keep text before c1 on r1, text after c2 on r2; join them *)
    UndoSaveBreak;  (* approximation *)
    Strings.Extract(lines[r2].s, c2, MaxLineLen, restBuf);
    lines[r1].s[c1] := 0X;
    Strings.Append(restBuf, lines[r1].s);
    (* Delete lines r1+1 .. r2 *)
    FOR i := r1 + 1 TO r2 DO ShiftLinesUp(r1 + 1) END;
    curRow := r1; curCol := c1
  END;
  hasBlkB := FALSE; hasBlkE := FALSE;
  dirty := TRUE; needRedraw := TRUE;
  SetStatus("Block deleted")
END BlockDelete;

PROCEDURE BlockMove;
(* ^KV — move marked block to cursor *)
BEGIN
  BlockCopy;
  (* After copy the block was re-pasted, now delete the original.
     Simple approach: copy first, adjust marks, delete original. *)
  (* For now just warn if block overlaps cursor — full move is complex *)
  SetStatus("Block moved (copied; delete original with ^KY)")
END BlockMove;

(* ── Other window (^OK) ─────────────────────────────────────────────
   A second, independently-scrolled document beside the active one.
   Rather than duplicating every editing procedure for a second buffer,
   the "other" document's state lives in a PaneSnap when it isn't
   focused; focusing it means swapping its fields with the live globals,
   so all the normal editing code keeps working unmodified on "whichever
   buffer is active right now". Undo history is not preserved across a
   focus swap (see PaneSnap's declaration). *)

PROCEDURE SnapFromActive(VAR snap: PaneSnap);
BEGIN
  snap.lines := lines; snap.numLines := numLines; COPY(filePath, snap.filePath);
  snap.dirty := dirty;
  snap.curRow := curRow; snap.curCol := curCol; snap.goalCol := goalCol;
  snap.topLine := topLine; snap.leftCol := leftCol;
  snap.hasBlkB := hasBlkB; snap.hasBlkE := hasBlkE;
  snap.blkBRow := blkBRow; snap.blkBCol := blkBCol;
  snap.blkERow := blkERow; snap.blkECol := blkECol
END SnapFromActive;

PROCEDURE CopySnapToActive(VAR snap: PaneSnap);
(* Bring a snapshot's content into the live globals. Does NOT touch undo
   history — callers doing a real focus switch reset undoTop themselves;
   callers just peeking (to render the other pane) restore the real
   active buffer afterward instead. *)
BEGIN
  lines := snap.lines; numLines := snap.numLines; COPY(snap.filePath, filePath);
  dirty := snap.dirty;
  curRow := snap.curRow; curCol := snap.curCol; goalCol := snap.goalCol;
  topLine := snap.topLine; leftCol := snap.leftCol;
  hasBlkB := snap.hasBlkB; hasBlkE := snap.hasBlkE;
  blkBRow := snap.blkBRow; blkBCol := snap.blkBCol;
  blkERow := snap.blkERow; blkECol := snap.blkECol
END CopySnapToActive;

PROCEDURE LoadFileIntoSnap(path: ARRAY OF CHAR; VAR snap: PaneSnap): BOOLEAN;
(* Like LoadFile, but into a PaneSnap instead of the live globals — for
   opening a second document without disturbing the active one. Like
   LoadFile, a non-existent path just starts a fresh empty document
   there rather than failing (this always returns TRUE; the result is
   kept for symmetry with LoadFile and in case that ever changes). *)
VAR f: Files.File; r: Files.Rider;
BEGIN
  f := Files.Old(path);
  snap.numLines := 0;
  IF f # NIL THEN
    Files.Set(r, f, 0);
    WHILE ~r.eof & (snap.numLines < MaxLines) DO
      NEW(snap.lines[snap.numLines]);
      Files.ReadLine(r, snap.lines[snap.numLines].s);
      IF ~r.eof OR (snap.lines[snap.numLines].s[0] # 0X) THEN
        INC(snap.numLines)
      ELSE
        FREE(snap.lines[snap.numLines])
      END
    END;
    Files.Close(f)
  END;
  IF snap.numLines = 0 THEN NEW(snap.lines[0]); snap.lines[0].s[0] := 0X; snap.numLines := 1 END;
  COPY(path, snap.filePath);
  snap.dirty := FALSE;
  snap.curRow := 0; snap.curCol := 0; snap.goalCol := -1;
  snap.topLine := 0; snap.leftCol := 0;
  snap.hasBlkB := FALSE; snap.hasBlkE := FALSE;
  RETURN TRUE
END LoadFileIntoSnap;

PROCEDURE SwapWithOther;
(* Exchange the active globals and otherPane's content, leaving undo and
   focusOther untouched — the raw swap primitive used both for a real
   focus switch (SwapPaneFocus) and for briefly viewing the other pane's
   buffer to reuse single-buffer logic on it (CopyFromOther, rendering). *)
BEGIN
  swapTmp := otherPane;
  SnapFromActive(otherPane);
  CopySnapToActive(swapTmp)
END SwapWithOther;

PROCEDURE SwapPaneFocus;
(* Move keyboard focus to the other pane. Resets undo (see PaneSnap). *)
BEGIN
  SwapWithOther;
  undoTop := 0;
  focusOther := ~focusOther;
  needRedraw := TRUE
END SwapPaneFocus;

PROCEDURE ToggleOtherWindow;
(* ^OK — open a second pane, or switch focus between the two open ones.
   Esc closes it (see CloseOtherWindow). *)
BEGIN
  IF ~otherPaneOpen THEN
    StartInput("Open in other window", ActOtherOpen)
  ELSE
    SwapPaneFocus
  END
END ToggleOtherWindow;

PROCEDURE CloseOtherWindow;
(* Esc, while the other window is open — collapse back to a single pane.
   focusOther tracks parity: an odd number of focus swaps since opening
   means the active globals currently hold the *other* pane's content,
   so swap once more first to land back on the original document. *)
BEGIN
  IF focusOther THEN SwapPaneFocus END;
  otherPaneOpen := FALSE;
  focusOther := FALSE;
  SetStatus("Other window closed");
  needRedraw := TRUE
END CloseOtherWindow;

PROCEDURE CopyFromOther;
(* ^KA — copy the block marked in the other window into this one, at
   the cursor. Reuses BlockCopy's own machinery (NormBlock/KillPushBlock/
   KillPut) by briefly viewing the other pane's buffer through the
   active globals — see CopySnapToActive. *)
VAR r1, c1, r2, c2: INTEGER;
BEGIN
  IF ~otherPaneOpen THEN SetStatus("No other window — ^OK to open one"); RETURN END;
  IF ~(otherPane.hasBlkB & otherPane.hasBlkE) THEN
    SetStatus("No block marked in the other window"); RETURN
  END;
  SwapWithOther;
  NormBlock(r1, c1, r2, c2);
  KillPushBlock(r1, c1, r2, c2);
  SwapWithOther;
  KillPut;
  SetStatus("Copied block from other window")
END CopyFromOther;

PROCEDURE JumpBlockSource;
(* ^QV — jump to wherever the marked block actually is: in this pane if
   it's marked here, otherwise switch focus to the other pane if it's
   marked there. *)
BEGIN
  IF hasBlkB THEN
    curRow := blkBRow; curCol := blkBCol; goalCol := -1; needRedraw := TRUE
  ELSIF otherPaneOpen & otherPane.hasBlkB THEN
    SwapPaneFocus;
    curRow := blkBRow; curCol := blkBCol; goalCol := -1; needRedraw := TRUE
  ELSE
    SetStatus("No block marked")
  END
END JumpBlockSource;

(* ── Search ──────────────────────────────────────────────────────── *)

PROCEDURE CaseChar(c: CHAR): CHAR;
BEGIN
  IF caseSens THEN RETURN c END;
  IF (c >= 'A') & (c <= 'Z') THEN RETURN CHR(ORD(c) + 32) END;
  RETURN c
END CaseChar;

(* Search forward from (startRow, startCol). Returns TRUE if found,
   sets searchRow/searchCol/searchLen. *)
PROCEDURE SearchForward(startRow, startCol: INTEGER): BOOLEAN;
VAR slen, llen, r, c, i: INTEGER; match: BOOLEAN;
BEGIN
  slen := Strings.Length(searchStr);
  IF slen = 0 THEN RETURN FALSE END;
  r := startRow; c := startCol;
  WHILE r < numLines DO
    llen := LineLen(r);
    WHILE c <= llen - slen DO
      match := TRUE;
      FOR i := 0 TO slen - 1 DO
        IF CaseChar(lines[r].s[c + i]) # CaseChar(searchStr[i]) THEN
          match := FALSE
        END
      END;
      IF match THEN
        searchRow := r; searchCol := c; searchLen := slen;
        RETURN TRUE
      END;
      INC(c)
    END;
    INC(r); c := 0
  END;
  RETURN FALSE
END SearchForward;

PROCEDURE FindNext;
(* ^L *)
VAR r, c: INTEGER;
BEGIN
  IF searchStr[0] = 0X THEN SetStatus("No search string"); RETURN END;
  r := curRow; c := curCol + 1;
  IF c > LineLen(curRow) THEN INC(r); c := 0 END;
  IF SearchForward(r, c) THEN
    curRow := searchRow; curCol := searchCol;
    SetStatus("Found");
    needRedraw := TRUE
  ELSE
    SetStatus("Not found")
  END
END FindNext;

PROCEDURE DoReplace;
(* Replace the current match (searchRow/Col) with replWith *)
VAR replen, i: INTEGER;
BEGIN
  UndoSaveLine;
  Strings.Delete(lines[searchRow].s, searchCol, searchLen);
  replen := Strings.Length(replWith);
  IF replen > 0 THEN
    Strings.Insert(replWith, searchCol, lines[searchRow].s)
  END;
  curRow := searchRow;
  curCol := searchCol + replen;
  dirty := TRUE; needRedraw := TRUE
END DoReplace;

(* ── Word Count ──────────────────────────────────────────────────── *)

PROCEDURE WordCount(): INTEGER;
VAR row, col, n: INTEGER; inWord: BOOLEAN; c: CHAR;
BEGIN
  n := 0; inWord := FALSE;
  FOR row := 0 TO numLines - 1 DO
    col := 0;
    WHILE lines[row].s[col] # 0X DO
      c := lines[row].s[col];
      IF IsWordChar(c) THEN
        IF ~inWord THEN INC(n); inWord := TRUE END
      ELSE
        inWord := FALSE
      END;
      INC(col)
    END;
    inWord := FALSE   (* words don't span lines *)
  END;
  RETURN n
END WordCount;

(* ── Palette (F1 key list) ───────────────────────────────────────── *)

(* Palette entries: chord string + description, terminated by empty pair *)
PROCEDURE PaletteEntry(i: INTEGER; VAR chord, desc: ARRAY OF CHAR);
BEGIN
  chord[0] := 0X; desc[0] := 0X;
  CASE i OF
    0:  COPY("^E",   chord); COPY("cursor up",             desc)
  | 1:  COPY("^X",   chord); COPY("cursor down",           desc)
  | 2:  COPY("^S",   chord); COPY("cursor left",           desc)
  | 3:  COPY("^D",   chord); COPY("cursor right",          desc)
  | 4:  COPY("^A",   chord); COPY("word left",             desc)
  | 5:  COPY("^F",   chord); COPY("word right",            desc)
  | 6:  COPY("^W",   chord); COPY("scroll up",             desc)
  | 7:  COPY("^Z",   chord); COPY("scroll down",           desc)
  | 8:  COPY("^R",   chord); COPY("page up",               desc)
  | 9:  COPY("^C",   chord); COPY("page down",             desc)
  | 10: COPY("^QS",  chord); COPY("line start",            desc)
  | 11: COPY("^QD",  chord); COPY("line end",              desc)
  | 12: COPY("^QE",  chord); COPY("screen top",            desc)
  | 13: COPY("^QX",  chord); COPY("screen bottom",         desc)
  | 14: COPY("^QR",  chord); COPY("document top",          desc)
  | 15: COPY("^QC",  chord); COPY("document end",          desc)
  | 16: COPY("^QF",  chord); COPY("find",                  desc)
  | 17: COPY("^QA",  chord); COPY("find & replace",        desc)
  | 18: COPY("^L",   chord); COPY("find next",             desc)
  | 19: COPY("^G",   chord); COPY("delete char",           desc)
  | 20: COPY("^H",   chord); COPY("backspace",             desc)
  | 21: COPY("^T",   chord); COPY("delete word right",     desc)
  | 22: COPY("^Y",   chord); COPY("delete line",           desc)
  | 23: COPY("^QY",  chord); COPY("delete to line end",    desc)
  | 24: COPY("^N",   chord); COPY("insert blank line",     desc)
  | 25: COPY("^U",   chord); COPY("undo",                  desc)
  | 26: COPY("^V",   chord); COPY("insert / overtype",     desc)
  | 27: COPY("^KB",  chord); COPY("mark block begin",      desc)
  | 28: COPY("^KK",  chord); COPY("mark block end",        desc)
  | 29: COPY("^KC",  chord); COPY("copy block",            desc)
  | 30: COPY("^KV",  chord); COPY("move block",            desc)
  | 31: COPY("^KY",  chord); COPY("delete block",          desc)
  | 32: COPY("^KH",  chord); COPY("hide / show block",     desc)
  | 33: COPY("^KP",  chord); COPY("put (paste)",           desc)
  | 34: COPY("^KD",  chord); COPY("save",                  desc)
  | 35: COPY("^KX",  chord); COPY("save and exit",         desc)
  | 36: COPY("^KQ",  chord); COPY("quit",                  desc)
  | 37: COPY("^OB",  chord); COPY("cycle theme",           desc)
  | 38: COPY("^OH",  chord); COPY("cycle help level",      desc)
  | 39: COPY("^OW",  chord); COPY("word wrap on/off",      desc)
  | 40: COPY("^OT",  chord); COPY("typewriter scroll",     desc)
  | 41: COPY("^OS",  chord); COPY("spell check on/off",    desc)
  | 42: COPY("^OA",  chord); COPY("add word to dict",      desc)
  | 43: COPY("^QN",  chord); COPY("next misspelling",      desc)
  | 44: COPY("^QP",  chord); COPY("previous position",     desc)
  | 45: COPY("^QB",  chord); COPY("jump to block begin",   desc)
  | 46: COPY("^QK",  chord); COPY("jump to block end",     desc)
  | 47: COPY("^Q,",  chord); COPY("sentence back",         desc)
  | 48: COPY("^Q.",  chord); COPY("sentence forward",      desc)
  | 49: COPY("^Q[",  chord); COPY("paragraph back",        desc)
  | 50: COPY("^Q]",  chord); COPY("paragraph forward",     desc)
  | 51: COPY("^QO",  chord); COPY("next heading",          desc)
  | 52: COPY("^QG",  chord); COPY("transpose chars",       desc)
  | 53: COPY("^QT",  chord); COPY("transpose words",       desc)
  | 54: COPY("F1",   chord); COPY("this key list",         desc)
  | 55: COPY("^KM",  chord); COPY("export RTF manuscript",  desc)
  | 56: COPY("^KE",  chord); COPY("clean export (strip notes)", desc)
  | 57: COPY("^KN",  chord); COPY("snapshot/backup",        desc)
  | 58: COPY("^OC",  chord); COPY("word count",             desc)
  | 59: COPY("^OF",  chord); COPY("focus mode toggle",      desc)
  | 60: COPY("^OL",  chord); COPY("style check toggle",     desc)
  | 61: COPY("^QI",  chord); COPY("next style issue",        desc)
  | 62: COPY("^PN",  chord); COPY("new project",             desc)
  | 63: COPY("^PP",  chord); COPY("open project",            desc)
  | 64: COPY("^PA",  chord); COPY("add doc to project",      desc)
  | 65: COPY("^PR",  chord); COPY("remove doc from project", desc)
  | 66: COPY("^PE",  chord); COPY("project: prev doc",       desc)
  | 67: COPY("^PX",  chord); COPY("project: next doc",       desc)
  | 68: COPY("^PL",  chord); COPY("project: list docs",      desc)
  | 69: COPY("^PK",  chord); COPY("project: compile RTF",    desc)
  | 70: COPY("^PT",  chord); COPY("project: compile text",   desc)
  | 71: COPY("^PS",  chord); COPY("project: find in all",    desc)
  | 72: COPY("^PB",  chord); COPY("binder popup",            desc)
  | 73: COPY("^QM", chord); COPY("next comment",            desc)
  | 74: COPY("^QU", chord); COPY("prev comment",            desc)
  | 75: COPY("^QH", chord); COPY("outline panel",           desc)
  | 76: COPY("^KW",  chord); COPY("write block to file",     desc)
  | 77: COPY("^KR",  chord); COPY("read file at cursor",     desc)
  | 78: COPY("^OR",  chord); COPY("set wrap margin",         desc)
  | 79: COPY("^OK",  chord); COPY("other window (open/switch)", desc)
  | 80: COPY("^KA",  chord); COPY("copy block from other window", desc)
  | 81: COPY("^QV",  chord); COPY("jump to block's pane",    desc)
  | 82: COPY("^OD",  chord); COPY("reveal codes toggle",     desc)
  | 83: COPY("^KU",  chord); COPY("jump to previous block",  desc)
  | 84: COPY("^KO",  chord); COPY("browse snapshots",        desc)
  | 85: COPY("^PI",  chord); COPY("edit doc synopsis",       desc)
  | 86: COPY("^PY",  chord); COPY("toggle synopsis in binder", desc)
  | 87: COPY("^PW",  chord); COPY("replace across project",  desc)
  | 88: COPY("^PM",  chord); COPY("toggle doc as note",      desc)
  | 89: COPY("^PC",  chord); COPY("insert comment",          desc)
  | 90: COPY("^PO",  chord); COPY("open doc's notes file",   desc)
  | 91: COPY("^PV",  chord); COPY("open binder doc in split", desc)
  | 92: COPY("^KJ",  chord); COPY("export HTML",              desc)
  | 93: COPY("^KG",  chord); COPY("export EPUB",              desc)
  | 94: COPY("^PG",  chord); COPY("project: compile EPUB",    desc)
  ELSE (* end *)
  END
END PaletteEntry;

PROCEDURE PaletteCount(): INTEGER;
BEGIN RETURN 95 END PaletteCount;

(* ── Splash Screen ───────────────────────────────────────────────── *)

(* 5-row block-letter glyph data for characters needed in "OSTAR" *)
PROCEDURE Glyph(c: CHAR; row: INTEGER; VAR s: ARRAY OF CHAR);
BEGIN
  CASE c OF
    'O': CASE row OF 0: COPY(".###.", s) | 1: COPY("#...#", s)
                   | 2: COPY("#...#", s) | 3: COPY("#...#", s)
                   | 4: COPY(".###.", s) END
  | 'S': CASE row OF 0: COPY(".####", s) | 1: COPY("#....", s)
                   | 2: COPY(".###.", s) | 3: COPY("....#", s)
                   | 4: COPY("####.", s) END
  | 'T': CASE row OF 0: COPY("#####", s) | 1: COPY("..#..", s)
                   | 2: COPY("..#..", s) | 3: COPY("..#..", s)
                   | 4: COPY("..#..", s) END
  | 'A': CASE row OF 0: COPY(".###.", s) | 1: COPY("#...#", s)
                   | 2: COPY("#####", s) | 3: COPY("#...#", s)
                   | 4: COPY("#...#", s) END
  | 'R': CASE row OF 0: COPY("####.", s) | 1: COPY("#...#", s)
                   | 2: COPY("####.", s) | 3: COPY("#..#.", s)
                   | 4: COPY("#...#", s) END
  ELSE   COPY(".....", s)
  END
END Glyph;

PROCEDURE DrawSplash;
CONST Word = "OSTAR";
VAR cx, cy, x, y, g, col: INTEGER; pix: ARRAY 6 OF CHAR; fg, bg: INTEGER;
BEGIN
  fg := ThFg(); bg := ThBg();
  TUI.ClearBack(fg, bg);
  cx := TUI.Cols DIV 2 - 17;  (* 5 chars × 6 wide (5+gap) = 30, centre *)
  cy := TUI.Rows DIV 2 - 4;
  (* Draw each of the 5 banner rows *)
  FOR y := 0 TO 4 DO
    x := cx;
    FOR g := 0 TO 4 DO          (* 5 letters *)
      Glyph(Word[g], y, pix);
      FOR col := 0 TO 4 DO
        IF pix[col] = '#' THEN
          TUI.PutCell(x + col, cy + y, 0DBX, TUI.Yellow, bg)
        END
      END;
      INC(x, 6)
    END
  END;
  (* Subtitle *)
  TUI.PutStr(TUI.Cols DIV 2 - 16, cy + 6, "WordStar / WordPerfect style editor", TUI.Cyan, bg);
  TUI.PutStr(TUI.Cols DIV 2 - 12, cy + 7, "Press any key to begin...",            ThDimFg(), bg);
  TUI.Flush
END DrawSplash;

(* ── Display ─────────────────────────────────────────────────────── *)

(* ── Spell Check ─────────────────────────────────────────────────── *)

PROCEDURE IsAllCaps(w: ARRAY OF CHAR): BOOLEAN;
(* TRUE for acronyms like "NASA" — skip spell check *)
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE w[i] # 0X DO
    IF (w[i] >= 'a') & (w[i] <= 'z') THEN RETURN FALSE END;
    INC(i)
  END;
  RETURN w[0] # 0X
END IsAllCaps;

PROCEDURE HasDigit(w: ARRAY OF CHAR): BOOLEAN;
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE w[i] # 0X DO
    IF (w[i] >= '0') & (w[i] <= '9') THEN RETURN TRUE END;
    INC(i)
  END;
  RETURN FALSE
END HasDigit;

(* ── Style-check word lists and helpers ─────────────────────────── *)

PROCEDURE IsFiller(w: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN (Strings.Compare(w,"very")=0) OR (Strings.Compare(w,"really")=0)
      OR (Strings.Compare(w,"quite")=0) OR (Strings.Compare(w,"rather")=0)
      OR (Strings.Compare(w,"somewhat")=0) OR (Strings.Compare(w,"actually")=0)
      OR (Strings.Compare(w,"basically")=0) OR (Strings.Compare(w,"literally")=0)
      OR (Strings.Compare(w,"simply")=0) OR (Strings.Compare(w,"totally")=0)
      OR (Strings.Compare(w,"utterly")=0) OR (Strings.Compare(w,"certainly")=0)
      OR (Strings.Compare(w,"definitely")=0) OR (Strings.Compare(w,"probably")=0)
      OR (Strings.Compare(w,"perhaps")=0) OR (Strings.Compare(w,"maybe")=0)
      OR (Strings.Compare(w,"just")=0) OR (Strings.Compare(w,"even")=0)
      OR (Strings.Compare(w,"suddenly")=0) OR (Strings.Compare(w,"somehow")=0)
      OR (Strings.Compare(w,"seemed")=0) OR (Strings.Compare(w,"felt")=0)
      OR (Strings.Compare(w,"saw")=0) OR (Strings.Compare(w,"heard")=0)
      OR (Strings.Compare(w,"noticed")=0) OR (Strings.Compare(w,"watched")=0)
      OR (Strings.Compare(w,"realized")=0) OR (Strings.Compare(w,"realised")=0)
      OR (Strings.Compare(w,"wondered")=0) OR (Strings.Compare(w,"thought")=0)
      OR (Strings.Compare(w,"decided")=0) OR (Strings.Compare(w,"knew")=0)
END IsFiller;

PROCEDURE IsBeForm(w: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN (Strings.Compare(w,"am")=0) OR (Strings.Compare(w,"is")=0)
      OR (Strings.Compare(w,"are")=0) OR (Strings.Compare(w,"was")=0)
      OR (Strings.Compare(w,"were")=0) OR (Strings.Compare(w,"be")=0)
      OR (Strings.Compare(w,"been")=0) OR (Strings.Compare(w,"being")=0)
      OR (Strings.Compare(w,"get")=0) OR (Strings.Compare(w,"gets")=0)
      OR (Strings.Compare(w,"got")=0)
END IsBeForm;

PROCEDURE IsNotAdverb(w: ARRAY OF CHAR): BOOLEAN;
(* Words ending in -ly that are NOT adverbs — exclude from adverb flagging *)
BEGIN
  RETURN (Strings.Compare(w,"ally")=0) OR (Strings.Compare(w,"apply")=0)
      OR (Strings.Compare(w,"belly")=0) OR (Strings.Compare(w,"bully")=0)
      OR (Strings.Compare(w,"comply")=0) OR (Strings.Compare(w,"family")=0)
      OR (Strings.Compare(w,"folly")=0) OR (Strings.Compare(w,"holy")=0)
      OR (Strings.Compare(w,"imply")=0) OR (Strings.Compare(w,"italy")=0)
      OR (Strings.Compare(w,"jelly")=0) OR (Strings.Compare(w,"jolly")=0)
      OR (Strings.Compare(w,"july")=0) OR (Strings.Compare(w,"lily")=0)
      OR (Strings.Compare(w,"melancholy")=0) OR (Strings.Compare(w,"multiply")=0)
      OR (Strings.Compare(w,"only")=0) OR (Strings.Compare(w,"rally")=0)
      OR (Strings.Compare(w,"rely")=0) OR (Strings.Compare(w,"reply")=0)
      OR (Strings.Compare(w,"silly")=0) OR (Strings.Compare(w,"supply")=0)
      OR (Strings.Compare(w,"tally")=0) OR (Strings.Compare(w,"ugly")=0)
END IsNotAdverb;

PROCEDURE IsStyleLyAdverb(w: ARRAY OF CHAR): BOOLEAN;
VAR len, i: INTEGER;
BEGIN
  len := Strings.Length(w);
  IF len < 4 THEN RETURN FALSE END;
  IF (w[len-2] # 'l') OR (w[len-1] # 'y') THEN RETURN FALSE END;
  FOR i := 0 TO len - 1 DO
    IF ~((w[i] >= 'a') & (w[i] <= 'z')) THEN RETURN FALSE END
  END;
  RETURN ~IsNotAdverb(w)
END IsStyleLyAdverb;

PROCEDURE IsAdjectivalEd(w: ARRAY OF CHAR): BOOLEAN;
(* -ed words that are adjectives after "to be", not passive constructions *)
BEGIN
  RETURN (Strings.Compare(w,"aged")=0) OR (Strings.Compare(w,"annoyed")=0)
      OR (Strings.Compare(w,"ashamed")=0) OR (Strings.Compare(w,"blessed")=0)
      OR (Strings.Compare(w,"bored")=0) OR (Strings.Compare(w,"confused")=0)
      OR (Strings.Compare(w,"crooked")=0) OR (Strings.Compare(w,"crowded")=0)
      OR (Strings.Compare(w,"delighted")=0) OR (Strings.Compare(w,"disappointed")=0)
      OR (Strings.Compare(w,"dressed")=0) OR (Strings.Compare(w,"embarrassed")=0)
      OR (Strings.Compare(w,"excited")=0) OR (Strings.Compare(w,"exhausted")=0)
      OR (Strings.Compare(w,"frustrated")=0) OR (Strings.Compare(w,"interested")=0)
      OR (Strings.Compare(w,"learned")=0) OR (Strings.Compare(w,"married")=0)
      OR (Strings.Compare(w,"naked")=0) OR (Strings.Compare(w,"pleased")=0)
      OR (Strings.Compare(w,"sacred")=0) OR (Strings.Compare(w,"satisfied")=0)
      OR (Strings.Compare(w,"scared")=0) OR (Strings.Compare(w,"tired")=0)
      OR (Strings.Compare(w,"wicked")=0) OR (Strings.Compare(w,"worried")=0)
END IsAdjectivalEd;

PROCEDURE IsIrregularParticiple(w: ARRAY OF CHAR): BOOLEAN;
BEGIN
  IF w[0] = 0X THEN RETURN FALSE END;
  CASE w[0] OF
    'b': RETURN (Strings.Compare(w,"beaten")=0) OR (Strings.Compare(w,"become")=0)
             OR (Strings.Compare(w,"begun")=0) OR (Strings.Compare(w,"bent")=0)
             OR (Strings.Compare(w,"bitten")=0) OR (Strings.Compare(w,"blown")=0)
             OR (Strings.Compare(w,"born")=0) OR (Strings.Compare(w,"borne")=0)
             OR (Strings.Compare(w,"bought")=0) OR (Strings.Compare(w,"bound")=0)
             OR (Strings.Compare(w,"broken")=0) OR (Strings.Compare(w,"brought")=0)
             OR (Strings.Compare(w,"built")=0) OR (Strings.Compare(w,"burnt")=0)
             OR (Strings.Compare(w,"burst")=0) OR (Strings.Compare(w,"bust")=0)
  | 'c': RETURN (Strings.Compare(w,"caught")=0) OR (Strings.Compare(w,"chosen")=0)
             OR (Strings.Compare(w,"clung")=0) OR (Strings.Compare(w,"come")=0)
             OR (Strings.Compare(w,"cut")=0)
  | 'd': RETURN (Strings.Compare(w,"dealt")=0) OR (Strings.Compare(w,"done")=0)
             OR (Strings.Compare(w,"drawn")=0) OR (Strings.Compare(w,"driven")=0)
             OR (Strings.Compare(w,"drunk")=0)
  | 'e': RETURN Strings.Compare(w,"eaten")=0
  | 'f': RETURN (Strings.Compare(w,"fallen")=0) OR (Strings.Compare(w,"fed")=0)
             OR (Strings.Compare(w,"felt")=0) OR (Strings.Compare(w,"fought")=0)
             OR (Strings.Compare(w,"found")=0) OR (Strings.Compare(w,"flown")=0)
             OR (Strings.Compare(w,"flung")=0) OR (Strings.Compare(w,"forgiven")=0)
             OR (Strings.Compare(w,"forgotten")=0) OR (Strings.Compare(w,"frozen")=0)
  | 'g': RETURN (Strings.Compare(w,"given")=0) OR (Strings.Compare(w,"gone")=0)
             OR (Strings.Compare(w,"grown")=0)
  | 'h': RETURN (Strings.Compare(w,"heard")=0) OR (Strings.Compare(w,"held")=0)
             OR (Strings.Compare(w,"hidden")=0) OR (Strings.Compare(w,"hit")=0)
             OR (Strings.Compare(w,"hung")=0) OR (Strings.Compare(w,"hurt")=0)
  | 'k': RETURN (Strings.Compare(w,"kept")=0) OR (Strings.Compare(w,"known")=0)
  | 'l': RETURN (Strings.Compare(w,"laid")=0) OR (Strings.Compare(w,"led")=0)
             OR (Strings.Compare(w,"left")=0) OR (Strings.Compare(w,"lent")=0)
             OR (Strings.Compare(w,"let")=0) OR (Strings.Compare(w,"lit")=0)
             OR (Strings.Compare(w,"lost")=0)
  | 'm': RETURN (Strings.Compare(w,"made")=0) OR (Strings.Compare(w,"meant")=0)
             OR (Strings.Compare(w,"met")=0)
  | 'p': RETURN (Strings.Compare(w,"paid")=0) OR (Strings.Compare(w,"put")=0)
  | 'r': RETURN (Strings.Compare(w,"read")=0) OR (Strings.Compare(w,"ridden")=0)
             OR (Strings.Compare(w,"risen")=0) OR (Strings.Compare(w,"run")=0)
  | 's': RETURN (Strings.Compare(w,"said")=0) OR (Strings.Compare(w,"seen")=0)
             OR (Strings.Compare(w,"sent")=0) OR (Strings.Compare(w,"set")=0)
             OR (Strings.Compare(w,"sewn")=0) OR (Strings.Compare(w,"shaken")=0)
             OR (Strings.Compare(w,"shot")=0) OR (Strings.Compare(w,"shown")=0)
             OR (Strings.Compare(w,"shut")=0) OR (Strings.Compare(w,"slept")=0)
             OR (Strings.Compare(w,"slid")=0) OR (Strings.Compare(w,"sold")=0)
             OR (Strings.Compare(w,"sought")=0) OR (Strings.Compare(w,"sown")=0)
             OR (Strings.Compare(w,"spent")=0) OR (Strings.Compare(w,"spoken")=0)
             OR (Strings.Compare(w,"spun")=0) OR (Strings.Compare(w,"stolen")=0)
             OR (Strings.Compare(w,"struck")=0) OR (Strings.Compare(w,"stuck")=0)
             OR (Strings.Compare(w,"stung")=0) OR (Strings.Compare(w,"sung")=0)
             OR (Strings.Compare(w,"sunk")=0) OR (Strings.Compare(w,"swept")=0)
             OR (Strings.Compare(w,"swum")=0) OR (Strings.Compare(w,"swung")=0)
  | 't': RETURN (Strings.Compare(w,"taken")=0) OR (Strings.Compare(w,"taught")=0)
             OR (Strings.Compare(w,"thrown")=0) OR (Strings.Compare(w,"told")=0)
             OR (Strings.Compare(w,"torn")=0)
  | 'u': RETURN Strings.Compare(w,"understood")=0
  | 'w': RETURN (Strings.Compare(w,"woken")=0) OR (Strings.Compare(w,"won")=0)
             OR (Strings.Compare(w,"worn")=0) OR (Strings.Compare(w,"woven")=0)
             OR (Strings.Compare(w,"written")=0) OR (Strings.Compare(w,"wrung")=0)
  ELSE RETURN FALSE
  END
END IsIrregularParticiple;

PROCEDURE IsParticiple(w: ARRAY OF CHAR): BOOLEAN;
VAR len: INTEGER;
BEGIN
  IF IsAdjectivalEd(w) THEN RETURN FALSE END;
  len := Strings.Length(w);
  IF (len >= 4) & (w[len-2] = 'e') & (w[len-1] = 'd') THEN RETURN TRUE END;
  RETURN IsIrregularParticiple(w)
END IsParticiple;

(* Build a style mask for one line: mask[col] = StXxx for each char of a
   flagged word or span (adverb, filler, passive, long sentence).
   Words are lowercased before matching; note lines are skipped. *)
PROCEDURE BuildStyleMask(row: INTEGER; VAR mask: ARRAY OF INTEGER);
VAR col, len, i, j, k, nw, ws, we, nextPos, sentStart, sentWC: INTEGER;
    wordBuf: LineBuf; c: CHAR;
    wstart, wend: ARRAY MaxStyleWords OF INTEGER;
BEGIN
  len := LineLen(row);
  FOR col := 0 TO len DO mask[col] := StNone END;
  IF len = 0 THEN RETURN END;
  IF (lines[row].s[0] = '.') & (lines[row].s[1] = '.') THEN RETURN END;

  (* Collect word spans *)
  nw := 0; col := 0;
  WHILE (col < len) & (nw < MaxStyleWords) DO
    IF IsWordChar(lines[row].s[col]) THEN
      ws := col;
      WHILE (col < len) & IsWordChar(lines[row].s[col]) DO INC(col) END;
      wstart[nw] := ws; wend[nw] := col; INC(nw)
    ELSE INC(col)
    END
  END;

  (* Adverb and filler checks *)
  FOR i := 0 TO nw - 1 DO
    Strings.Extract(lines[row].s, wstart[i], wend[i] - wstart[i], wordBuf);
    Strings.ToLower(wordBuf);
    IF IsStyleLyAdverb(wordBuf) THEN
      FOR j := wstart[i] TO wend[i] - 1 DO mask[j] := StAdverb END
    END;
    IF IsFiller(wordBuf) THEN
      FOR j := wstart[i] TO wend[i] - 1 DO mask[j] := StFiller END
    END
  END;

  (* Passive voice: be-form [optional adverb] participle *)
  i := 0;
  WHILE i < nw DO
    Strings.Extract(lines[row].s, wstart[i], wend[i] - wstart[i], wordBuf);
    Strings.ToLower(wordBuf);
    IF IsBeForm(wordBuf) THEN
      IF i + 1 < nw THEN
        Strings.Extract(lines[row].s, wstart[i+1], wend[i+1] - wstart[i+1], wordBuf);
        Strings.ToLower(wordBuf);
        IF IsParticiple(wordBuf) THEN
          FOR j := wstart[i] TO wend[i+1] - 1 DO
            IF mask[j] = StNone THEN mask[j] := StPassive END
          END
        ELSIF IsStyleLyAdverb(wordBuf) & (i + 2 < nw) THEN
          Strings.Extract(lines[row].s, wstart[i+2], wend[i+2] - wstart[i+2], wordBuf);
          Strings.ToLower(wordBuf);
          IF IsParticiple(wordBuf) THEN
            FOR j := wstart[i] TO wend[i+2] - 1 DO
              IF mask[j] = StNone THEN mask[j] := StPassive END
            END
          END
        END
      END
    END;
    INC(i)
  END;

  (* Long sentence: mark word chars when sentence word-count > StyleSentWords *)
  sentStart := 0; sentWC := 0;
  i := 0;
  WHILE i <= nw DO
    IF i = nw THEN
      (* Flush final sentence (no terminal punctuation) *)
      IF (sentWC > StyleSentWords) & (sentStart < nw) THEN
        FOR j := wstart[sentStart] TO wend[nw - 1] - 1 DO
          IF mask[j] = StNone THEN mask[j] := StLong END
        END
      END
    ELSE
      INC(sentWC);
      IF i + 1 < nw THEN nextPos := wstart[i + 1] ELSE nextPos := len END;
      k := wend[i];
      WHILE k < nextPos DO
        c := lines[row].s[k];
        IF (c = '.') OR (c = '!') OR (c = '?') THEN
          IF (sentWC > StyleSentWords) & (sentStart < nw) THEN
            FOR j := wstart[sentStart] TO wend[i] - 1 DO
              IF mask[j] = StNone THEN mask[j] := StLong END
            END
          END;
          sentStart := i + 1; sentWC := 0;
          k := nextPos  (* break *)
        ELSE
          INC(k)
        END
      END
    END;
    INC(i)
  END
END BuildStyleMask;

(* ^QI — jump cursor to the next style-flagged position *)
PROCEDURE NextStyleIssue;
VAR row, col, len: INTEGER;
    smask: ARRAY (MaxLineLen + 1) OF INTEGER;
BEGIN
  IF ~styleEnabled THEN SetStatus("Style off — ^OL to enable"); RETURN END;
  row := curRow; col := curCol + 1;
  IF col > LineLen(row) THEN INC(row); col := 0 END;
  LOOP
    IF row >= numLines THEN SetStatus("No more style issues"); RETURN END;
    len := LineLen(row);
    BuildStyleMask(row, smask);
    WHILE col < len DO
      IF smask[col] # StNone THEN
        curRow := row; curCol := col;
        IF smask[col] = StAdverb  THEN SetStatus("Style: -ly adverb")
        ELSIF smask[col] = StFiller  THEN SetStatus("Style: filler word")
        ELSIF smask[col] = StPassive THEN SetStatus("Style: passive voice")
        ELSE SetStatus("Style: long sentence")
        END;
        goalCol := -1; needRedraw := TRUE; RETURN
      END;
      INC(col)
    END;
    INC(row); col := 0
  END
END NextStyleIssue;

(* Build a boolean mask for one line: mask[col] = TRUE iff that character
   is part of a word that hunspell flagged and is not in personalDict.    *)
PROCEDURE BuildSpellMask(row: INTEGER; VAR mask: ARRAY OF BOOLEAN);
VAR col, len, ws, we: INTEGER; wordBuf, lwordBuf: LineBuf;
BEGIN
  len := LineLen(row);
  FOR col := 0 TO len DO mask[col] := FALSE END;
  col := 0;
  WHILE col < len DO
    IF IsWordChar(lines[row].s[col]) THEN
      ws := col;
      WHILE (col < len) & IsWordChar(lines[row].s[col]) DO INC(col) END;
      we := col;
      IF we - ws > 1 THEN
        Strings.Extract(lines[row].s, ws, we - ws, wordBuf);
        IF ~IsAllCaps(wordBuf) & ~HasDigit(wordBuf) THEN
          COPY(wordBuf, lwordBuf); Strings.ToLower(lwordBuf);
          IF Dict.Has(misspelled, lwordBuf) & ~Dict.Has(personalDict, lwordBuf) THEN
            FOR col := ws TO we - 1 DO mask[col] := TRUE END
          END
        END;
        col := we
      END
    ELSE INC(col)
    END
  END
END BuildSpellMask;

(* Return the word that straddles curRow/curCol (empty if not on a word). *)
PROCEDURE WordUnderCursor(VAR word: ARRAY OF CHAR);
VAR c, len, ws: INTEGER;
BEGIN
  word[0] := 0X;
  len := LineLen(curRow);
  IF (curCol >= len) OR ~IsWordChar(lines[curRow].s[curCol]) THEN RETURN END;
  ws := curCol;
  WHILE (ws > 0) & IsWordChar(lines[curRow].s[ws - 1]) DO DEC(ws) END;
  c := ws;
  WHILE (c < len) & IsWordChar(lines[curRow].s[c]) DO INC(c) END;
  Strings.Extract(lines[curRow].s, ws, c - ws, word)
END WordUnderCursor;

PROCEDURE LoadPersonalDict;
VAR f: Files.File; r: Files.Rider; wordBuf: LineBuf;
BEGIN
  Dict.Init(personalDict);
  IF personalPath[0] = 0X THEN RETURN END;
  f := Files.Old(personalPath);
  IF f = NIL THEN RETURN END;
  Files.Set(r, f, 0);
  WHILE ~r.eof DO
    Files.ReadLine(r, wordBuf);
    IF wordBuf[0] # 0X THEN Strings.ToLower(wordBuf); Dict.Put(personalDict, wordBuf, "") END
  END;
  Files.Close(f)
END LoadPersonalDict;

(* Batch-check every word in the document via `hunspell -l`.
   Results land in `misspelled`; highlights appear on the next redraw. *)
PROCEDURE RunSpellCheck;
VAR f: Files.File; r: Files.Rider; row, col, len, ws: INTEGER;
    wordBuf, lwordBuf: LineBuf; cmd: ARRAY 768 OF CHAR;
    tmpDir, wordsFile, badFile: ARRAY 512 OF CHAR;
    seen: Dict.Table; cnt: INTEGER; tmp: ARRAY 32 OF CHAR;
BEGIN
  SetStatus("Spell checking...");

  (* Use $TMPDIR (Termux: /data/data/com.termux/files/usr/tmp) *)
  Env.Get("TMPDIR", tmpDir);
  IF tmpDir[0] = 0X THEN COPY("/tmp", tmpDir) END;
  COPY(tmpDir, wordsFile); Strings.Append("/ostar_words.txt",  wordsFile);
  COPY(tmpDir, badFile);   Strings.Append("/ostar_bad.txt",    badFile);

  Dict.Init(seen);
  f := Files.New(wordsFile);
  IF f = NIL THEN SetStatus("Spell check: cannot write temp file"); RETURN END;
  Files.Set(r, f, 0);
  cnt := 0;
  FOR row := 0 TO numLines - 1 DO
    col := 0; len := LineLen(row);
    WHILE col < len DO
      IF IsWordChar(lines[row].s[col]) THEN
        ws := col;
        WHILE (col < len) & IsWordChar(lines[row].s[col]) DO INC(col) END;
        IF col - ws > 1 THEN
          Strings.Extract(lines[row].s, ws, col - ws, wordBuf);
          IF ~IsAllCaps(wordBuf) & ~HasDigit(wordBuf) THEN
            COPY(wordBuf, lwordBuf); Strings.ToLower(lwordBuf);
            IF ~Dict.Has(seen, lwordBuf) THEN
              Files.WriteLine(r, lwordBuf);
              Dict.Put(seen, lwordBuf, "");
              INC(cnt)
            END
          END
        END
      ELSE INC(col)
      END
    END
  END;
  Files.Register(f); Files.Close(f);
  Dict.Clear(seen);

  IF cnt = 0 THEN Dict.Init(misspelled); SetStatus("Nothing to check"); RETURN END;

  COPY("hunspell -l < '", cmd);
  Strings.Append(wordsFile, cmd); Strings.Append("' > '", cmd);
  Strings.Append(badFile,   cmd); Strings.Append("' 2>/dev/null", cmd);
  OS.Exec(cmd);
  TUI.InvalidateFront;  (* shell subprocess may have disturbed the terminal *)

  Dict.Init(misspelled);
  cnt := 0;
  f := Files.Old(badFile);
  IF f # NIL THEN
    Files.Set(r, f, 0);
    WHILE ~r.eof DO
      Files.ReadLine(r, wordBuf);
      IF wordBuf[0] # 0X THEN
        Strings.ToLower(wordBuf);
        IF ~Dict.Has(personalDict, wordBuf) THEN
          Dict.Put(misspelled, wordBuf, "");
          INC(cnt)
        END
      END
    END;
    Files.Close(f)
  END;

  IF cnt = 0 THEN SetStatus("Spell check: no errors found")
  ELSE
    COPY("Misspellings: ", statusMsg);
    Strings.IntToStr(cnt, tmp); Strings.Append(tmp, statusMsg)
  END;
  needRedraw := TRUE
END RunSpellCheck;

(* ^QN — jump cursor to the next misspelled word *)
PROCEDURE NextMisspelling;
VAR row, col, len, ws, we: INTEGER; wordBuf, lwordBuf: LineBuf;
BEGIN
  IF ~spellEnabled THEN SetStatus("Spell off — ^OS to enable"); RETURN END;
  row := curRow; col := curCol + 1;
  IF col > LineLen(row) THEN INC(row); col := 0 END;
  LOOP
    IF row >= numLines THEN SetStatus("No more misspellings"); RETURN END;
    len := LineLen(row);
    WHILE col < len DO
      IF IsWordChar(lines[row].s[col]) THEN
        ws := col;
        WHILE (col < len) & IsWordChar(lines[row].s[col]) DO INC(col) END;
        we := col;
        IF we - ws > 1 THEN
          Strings.Extract(lines[row].s, ws, we - ws, wordBuf);
          IF ~IsAllCaps(wordBuf) & ~HasDigit(wordBuf) THEN
            COPY(wordBuf, lwordBuf); Strings.ToLower(lwordBuf);
            IF Dict.Has(misspelled, lwordBuf) & ~Dict.Has(personalDict, lwordBuf) THEN
              curRow := row; curCol := ws;
              COPY("Misspelling: ", statusMsg); Strings.Append(wordBuf, statusMsg);
              needRedraw := TRUE; RETURN
            END
          END
        END
      ELSE INC(col)
      END
    END;
    INC(row); col := 0
  END
END NextMisspelling;

(* ^OA — add the word under the cursor to the personal dictionary *)
PROCEDURE AddToPersonalDict;
(* Files.Old opens read-only ("rb") so we cannot write through it.
   Files.New truncates.  Shell append is the only safe option here. *)
VAR wordBuf, lwordBuf: LineBuf; cmd: ARRAY 700 OF CHAR;
    dirPath: ARRAY 512 OF CHAR; i: INTEGER;
BEGIN
  WordUnderCursor(wordBuf);
  IF wordBuf[0] = 0X THEN SetStatus("No word under cursor"); RETURN END;
  COPY(wordBuf, lwordBuf); Strings.ToLower(lwordBuf);
  Dict.Put(personalDict, lwordBuf, "");
  Dict.Remove(misspelled, lwordBuf);
  IF personalPath[0] # 0X THEN
    (* Ensure parent directory exists *)
    COPY(personalPath, dirPath);
    i := Strings.Length(dirPath) - 1;
    WHILE (i >= 0) & (dirPath[i] # '/') DO DEC(i) END;
    IF i > 0 THEN
      dirPath[i] := 0X;
      COPY("mkdir -p '", cmd);
      Strings.Append(dirPath, cmd);
      Strings.Append("' 2>/dev/null", cmd);
      OS.Exec(cmd)
    END;
    (* Append the word as a new line *)
    COPY("printf '%s\n' '", cmd);
    Strings.Append(lwordBuf, cmd);
    Strings.Append("' >> '", cmd);
    Strings.Append(personalPath, cmd);
    Strings.Append("'", cmd);
    OS.Exec(cmd)
  END;
  TUI.InvalidateFront;  (* shell subprocess may have disturbed the terminal *)
  COPY("Added to dictionary: ", statusMsg); Strings.Append(wordBuf, statusMsg);
  needRedraw := TRUE
END AddToPersonalDict;

PROCEDURE IsMarkupChar(row, col: INTEGER): BOOLEAN;
(* ^OD reveal codes: is the char at (row,col) a markdown marker —
   *emphasis*, a leading run of #s, or a leading ".." comment prefix? *)
VAR c: CHAR; lev: INTEGER;
BEGIN
  c := lines[row].s[col];
  IF c = '*' THEN RETURN TRUE END;
  IF ((col = 0) OR (col = 1)) & (lines[row].s[0] = '.') & (lines[row].s[1] = '.') THEN
    RETURN TRUE
  END;
  IF c = '#' THEN
    lev := 0;
    WHILE (lev < Strings.Length(lines[row].s)) & (lines[row].s[lev] = '#') DO INC(lev) END;
    RETURN col < lev
  END;
  RETURN FALSE
END IsMarkupChar;

PROCEDURE DrawTextLine(screenY, docRow: INTEGER);
VAR col, len, x, fg, bg, sk, swp: INTEGER; dimmed: BOOLEAN;
    mask: ARRAY (MaxLineLen + 1) OF BOOLEAN;
    smask: ARRAY (MaxLineLen + 1) OF INTEGER;
BEGIN
  len := LineLen(docRow);
  IF spellEnabled THEN BuildSpellMask(docRow, mask) END;
  IF styleEnabled THEN BuildStyleMask(docRow, smask) END;
  dimmed := focusMode & ((docRow < focusParaS) OR (docRow > focusParaE));
  x := TextX0();
  col := leftCol;
  WHILE (x <= TUI.Cols) & (col <= len) DO
    IF dimmed THEN
      fg := ThDimFg(); bg := ThBg()
    ELSIF InBlock(docRow, col) THEN
      fg := ThBlkFg(); bg := ThBlkBg()
    ELSIF (docRow = searchRow) & (col >= searchCol) & (col < searchCol + searchLen)
        & (mode = ModeSearch) THEN
      fg := ThHlFg(); bg := ThHlBg()
    ELSIF spellEnabled & (col < LEN(mask)) & mask[col] THEN
      fg := ThSpFg(); bg := ThBg()
    ELSIF styleEnabled & (col < LEN(smask)) & (smask[col] # StNone) THEN
      sk := smask[col];
      IF (docRow = curRow) & (col = curCol) THEN styleCurKind := sk END;
      fg := ThStylFg(sk); bg := ThBg()
    ELSE
      IF styleEnabled & (docRow = curRow) & (col = curCol) THEN styleCurKind := StNone END;
      fg := ThFg(); bg := ThBg()
    END;
    IF revealCodes & (col < len) & IsMarkupChar(docRow, col) THEN
      swp := fg; fg := bg; bg := swp
    END;
    INC(col, PutLineCell(docRow, col, len, x, screenY, fg, bg));
    INC(x)
  END;
  (* Fill remainder of line *)
  IF x <= TUI.Cols THEN
    IF dimmed THEN
      TUI.FillRect(x, screenY, TUI.Cols - x + 1, 1, ' ', ThDimFg(), ThBg())
    ELSE
      TUI.FillRect(x, screenY, TUI.Cols - x + 1, 1, ' ', ThFg(), ThBg())
    END
  END
END DrawTextLine;

PROCEDURE DrawStatus;
VAR s: ARRAY 256 OF CHAR; wc: INTEGER; tmp: ARRAY 32 OF CHAR;
    fg, bg, col, x: INTEGER;
BEGIN
  fg := ThStFg(); bg := ThStBg();
  TUI.FillRect(1, TUI.Rows, TUI.Cols, 1, ' ', fg, bg);
  (* Left: filename, modified marker, position *)
  IF filePath[0] = 0X THEN COPY("[No Name]", s)
  ELSE COPY(filePath, s)
  END;
  IF dirty THEN Strings.Append(" *", s) END;
  Strings.Append("  L:", s); Strings.IntToStr(curRow + 1, tmp); Strings.Append(tmp, s);
  Strings.Append(" C:", s); Strings.IntToStr(curCol + 1, tmp); Strings.Append(tmp, s);
  TUI.PutStr(1, TUI.Rows, s, fg, bg);
  (* Right side: mode / prefix indicator *)
  s[0] := 0X;
  IF prefix = PrefK THEN COPY("^K Block&File", s)
  ELSIF prefix = PrefQ THEN COPY("^Q Quick", s)
  ELSIF prefix = PrefO THEN COPY("^O Onscreen", s)
  ELSIF prefix = PrefP THEN COPY("^P Project", s)
  ELSIF mode = ModeReplace THEN
    COPY("REPLACE? (Y/N/A/Esc)", s)
  ELSIF mode = ModeConfirm THEN
    COPY("Quit without saving? (Y/N)", s)
  ELSIF overtype THEN COPY("OVR", s)
  ELSIF styleEnabled & (styleCurKind = StAdverb)  THEN COPY("-ly adverb",   s)
  ELSIF styleEnabled & (styleCurKind = StFiller)  THEN COPY("filler word",  s)
  ELSIF styleEnabled & (styleCurKind = StPassive) THEN COPY("passive voice", s)
  ELSIF styleEnabled & (styleCurKind = StLong)    THEN COPY("long sentence", s)
  ELSIF statusMsg[0] # 0X THEN COPY(statusMsg, s)
  END;
  (* Search and input prompts are left-aligned so the cursor lands right
     after the typed text (position is computable without measuring the line). *)
  IF mode = ModeSearch THEN
    s[0] := 0X;
    COPY("FIND: ", s); Strings.Append(searchStr, s);
    TUI.FillRect(1, TUI.Rows, TUI.Cols, 1, ' ', fg, bg);  (* the filename status drawn above may be longer *)
    TUI.PutStr(1, TUI.Rows, s, fg, bg)
  ELSIF mode = ModeInput THEN
    s[0] := 0X;
    COPY(inpLabel, s); Strings.Append(": ", s); Strings.Append(inpValue, s);
    TUI.FillRect(1, TUI.Rows, TUI.Cols, 1, ' ', fg, bg);  (* the filename status drawn above may be longer *)
    TUI.PutStr(1, TUI.Rows, s, fg, bg)
  ELSIF s[0] # 0X THEN
    col := TUI.Cols - Strings.Length(s);
    IF col < 1 THEN col := 1 END;
    TUI.PutStr(col, TUI.Rows, s, fg, bg)
  END
END DrawStatus;

PROCEDURE DrawPrefixMenu(pref: INTEGER);
(* Draw the prefix menu box when a prefix key was pressed *)
CONST MenuW = 28;
VAR chord: ARRAY 8 OF CHAR; desc: ARRAY 64 OF CHAR;
    i, n, x, y, mh: INTEGER; title: ARRAY 32 OF CHAR; line: ARRAY 48 OF CHAR;
    fg, bg, mfg, mbg: INTEGER;
BEGIN
  (* Collect entries for this prefix *)
  n := 0;
  i := 0;
  LOOP
    PaletteEntry(i, chord, desc);
    IF chord[0] = 0X THEN EXIT END;
    IF (pref = PrefK) & (chord[0] = '^') & (chord[1] = 'K') THEN INC(n)
    ELSIF (pref = PrefQ) & (chord[0] = '^') & (chord[1] = 'Q') THEN INC(n)
    ELSIF (pref = PrefO) & (chord[0] = '^') & (chord[1] = 'O') THEN INC(n)
    ELSIF (pref = PrefP) & (chord[0] = '^') & (chord[1] = 'P') THEN INC(n)
    END;
    INC(i)
  END;
  mh := n + 2;  (* border rows *)
  x := 2; y := TUI.Rows - mh - 2;  (* bottom-left corner *)
  IF y < 1 THEN y := 1 END;
  fg := ThStFg(); bg := ThStBg();
  mfg := ThFg(); mbg := ThBg();
  TUI.DrawBox(x, y, MenuW, mh, fg, bg);
  CASE pref OF
    PrefK: COPY("^K Block & File", title)
  | PrefQ: COPY("^Q Quick",        title)
  | PrefO: COPY("^O Onscreen",     title)
  | PrefP: COPY("^P Project",      title)
  ELSE     COPY("",                title)
  END;
  TUI.PutStr(x + 1, y, title, fg, bg);
  (* Fill entries *)
  n := 0; i := 0;
  LOOP
    PaletteEntry(i, chord, desc);
    IF chord[0] = 0X THEN EXIT END;
    IF ((pref = PrefK) & (chord[0] = '^') & (chord[1] = 'K'))
    OR ((pref = PrefQ) & (chord[0] = '^') & (chord[1] = 'Q'))
    OR ((pref = PrefO) & (chord[0] = '^') & (chord[1] = 'O'))
    OR ((pref = PrefP) & (chord[0] = '^') & (chord[1] = 'P')) THEN
      (* Format: "^Kx  description" *)
      line[0] := ' '; line[1] := 0X;
      Strings.Append(chord, line); Strings.Append("  ", line);
      Strings.Append(desc, line);
      TUI.PutStr(x + 1, y + 1 + n, line, mfg, mbg);
      (* Pad to menu width *)
      TUI.FillRect(x + 1 + Strings.Length(line), y + 1 + n,
                   MenuW - Strings.Length(line) - 2, 1, ' ', mfg, mbg);
      INC(n)
    END;
    INC(i)
  END
END DrawPrefixMenu;

PROCEDURE DrawPalette;
(* F1 — draw scrollable key list overlay *)
CONST PalW = 40; PalH = 20;
VAR chord: ARRAY 8 OF CHAR; desc: ARRAY 64 OF CHAR;
    i, n, px, py, maxScroll, vis: INTEGER; line: ARRAY 56 OF CHAR;
    fg, bg, hfg, hbg: INTEGER;
BEGIN
  n := PaletteCount();
  px := (TUI.Cols - PalW) DIV 2 + 1;
  py := (TUI.Rows - PalH) DIV 2;
  IF py < 1 THEN py := 1 END;
  fg := ThFg(); bg := ThBg();
  TUI.DrawBox(px - 1, py - 1, PalW + 2, PalH + 2, ThStFg(), ThStBg());
  TUI.PutStr(px, py - 1, "Key Reference  (Esc to close)", ThStFg(), ThStBg());
  maxScroll := n - PalH;
  IF maxScroll < 0 THEN maxScroll := 0 END;
  IF palScroll > maxScroll THEN palScroll := maxScroll END;
  FOR i := 0 TO PalH - 1 DO
    PaletteEntry(palScroll + i, chord, desc);
    IF chord[0] # 0X THEN
      line[0] := 0X;
      Strings.Append(chord, line); Strings.Append("  ", line);
      Strings.Append(desc, line);
      TUI.PutStr(px, py + i, line, ThDimFg(), bg);
      TUI.FillRect(px + Strings.Length(line), py + i,
                   PalW - Strings.Length(line), 1, ' ', fg, bg)
    ELSE
      TUI.FillRect(px, py + i, PalW, 1, ' ', fg, bg)
    END
  END
END DrawPalette;

PROCEDURE DrawSegment(screenY, docRow, segFrom: INTEGER);
(* Draw one visual wrap segment of docRow on screen row screenY. *)
VAR col, segEnd, x, fg, bg, sk, swp: INTEGER; dimmed: BOOLEAN;
    mask: ARRAY (MaxLineLen + 1) OF BOOLEAN;
    smask: ARRAY (MaxLineLen + 1) OF INTEGER;
BEGIN
  segEnd := SegEnd(docRow, segFrom);
  IF spellEnabled THEN BuildSpellMask(docRow, mask) END;
  IF styleEnabled THEN BuildStyleMask(docRow, smask) END;
  dimmed := focusMode & ((docRow < focusParaS) OR (docRow > focusParaE));
  x := TextX0(); col := segFrom;
  WHILE (x <= TUI.Cols) & (col < segEnd) DO
    IF dimmed THEN
      fg := ThDimFg(); bg := ThBg()
    ELSIF InBlock(docRow, col) THEN
      fg := ThBlkFg(); bg := ThBlkBg()
    ELSIF (docRow = searchRow) & (col >= searchCol) & (col < searchCol + searchLen)
        & (mode = ModeSearch) THEN
      fg := ThHlFg(); bg := ThHlBg()
    ELSIF spellEnabled & (col < LEN(mask)) & mask[col] THEN
      fg := ThSpFg(); bg := ThBg()
    ELSIF styleEnabled & (col < LEN(smask)) & (smask[col] # StNone) THEN
      sk := smask[col];
      IF (docRow = curRow) & (col = curCol) THEN styleCurKind := sk END;
      fg := ThStylFg(sk); bg := ThBg()
    ELSE
      IF styleEnabled & (docRow = curRow) & (col = curCol) THEN styleCurKind := StNone END;
      fg := ThFg(); bg := ThBg()
    END;
    IF revealCodes & IsMarkupChar(docRow, col) THEN
      swp := fg; fg := bg; bg := swp
    END;
    INC(col, PutLineCell(docRow, col, segEnd, x, screenY, fg, bg));
    INC(x)
  END;
  IF x <= TUI.Cols THEN
    IF dimmed THEN
      TUI.FillRect(x, screenY, TUI.Cols - x + 1, 1, ' ', ThDimFg(), ThBg())
    ELSE
      TUI.FillRect(x, screenY, TUI.Cols - x + 1, 1, ' ', ThFg(), ThBg())
    END
  END
END DrawSegment;

PROCEDURE RowsForEntry(i: INTEGER): INTEGER;
(* A binder entry takes a second row when its synopsis is shown (^PY). *)
VAR syn: ARRAY 256 OF CHAR;
BEGIN
  IF ~showSynopsis THEN RETURN 1 END;
  ReadSynopsis(projDocs[i], syn);
  IF syn[0] = 0X THEN RETURN 1 ELSE RETURN 2 END
END RowsForEntry;

PROCEDURE DrawBinder;
(* Draw the binder as a centered popup listing project documents,
   navigable with Up/Down/Enter/Esc (^PB) — matches PerfectStar's
   floating binder rather than a permanent sidebar. A doc with a
   synopsis (^PI) shown (^PY) takes a second, dimmed row. *)
CONST BW = 50; BH = 16;
VAR i, y, n, px, py, vis, first, used, totalRows, lineNo: INTEGER;
    nameStart, nameLen, room: INTEGER;
    name: ARRAY (BW + 1) OF CHAR;
    line: ARRAY (BW + 1) OF CHAR;
    syn: ARRAY 256 OF CHAR; synLine: ARRAY (BW + 1) OF CHAR;
    fg, bg, hfg, hbg: INTEGER;
BEGIN
  n := projDocCount;
  fg := ThFg(); bg := ThBg(); hfg := ThBg(); hbg := ThFg();

  IF n = 0 THEN
    px := (TUI.Cols - BW) DIV 2 + 1;
    py := (TUI.Rows - 1) DIV 2;
    IF py < 1 THEN py := 1 END;
    TUI.DrawBox(px - 1, py - 1, BW + 2, 3, ThStFg(), ThStBg());
    TUI.PutStr(px, py - 1, " Binder  (Enter=open  Esc=close) ", ThStFg(), ThStBg());
    TUI.FillRect(px, py, BW, 1, ' ', ThDimFg(), bg);
    TUI.PutStr(px, py, " (no documents in project)", ThDimFg(), bg);
    RETURN
  END;

  totalRows := 0;
  FOR i := 0 TO n - 1 DO totalRows := totalRows + RowsForEntry(i) END;
  vis := totalRows;
  IF vis > BH THEN vis := BH END;

  (* First visible entry: scan back from the selection so it, and its
     synopsis line if any, stay in view. *)
  first := binderSel; used := RowsForEntry(binderSel);
  WHILE (first > 0) & (used + RowsForEntry(first - 1) <= vis) DO
    DEC(first); used := used + RowsForEntry(first)
  END;

  px := (TUI.Cols - BW) DIV 2 + 1;
  py := (TUI.Rows - vis) DIV 2;
  IF py < 1 THEN py := 1 END;
  TUI.DrawBox(px - 1, py - 1, BW + 2, vis + 2, ThStFg(), ThStBg());
  TUI.PutStr(px, py - 1, " Binder  (Enter=open  Esc=close) ", ThStFg(), ThStBg());

  lineNo := 0;
  i := first;
  WHILE (i < n) & (lineNo < vis) DO
    y := py + lineNo;
    nameLen := Strings.Length(projDocs[i]);
    WHILE (nameLen > 0) & (projDocs[i][nameLen - 1] # '/') DO DEC(nameLen) END;
    nameStart := nameLen; nameLen := Strings.Length(projDocs[i]) - nameStart;
    IF nameLen > BW - 6 THEN nameLen := BW - 6 END;
    Strings.Extract(projDocs[i], nameStart, nameLen, name);
    line[0] := 0X;
    IF i = projCurDoc THEN Strings.Append("* ", line) ELSE Strings.Append("  ", line) END;
    Strings.Append(name, line);
    IF projIsNote[i] THEN Strings.Append(" [note]", line) END;
    IF i = binderSel THEN
      TUI.FillRect(px, y, BW, 1, ' ', hfg, hbg); TUI.PutStr(px, y, line, hfg, hbg)
    ELSE
      TUI.FillRect(px, y, BW, 1, ' ', fg, bg); TUI.PutStr(px, y, line, fg, bg)
    END;
    INC(lineNo);
    IF showSynopsis & (lineNo < vis) THEN
      ReadSynopsis(projDocs[i], syn);
      IF syn[0] # 0X THEN
        y := py + lineNo;
        synLine[0] := 0X; Strings.Append("   ", synLine);
        room := BW - 3;
        IF Strings.Length(syn) > room THEN syn[room] := 0X END;
        Strings.Append(syn, synLine);
        TUI.FillRect(px, y, BW, 1, ' ', ThDimFg(), bg);
        TUI.PutStr(px, y, synLine, ThDimFg(), bg);
        INC(lineNo)
      END
    END;
    INC(i)
  END;
  FOR y := py + lineNo TO py + vis - 1 DO
    TUI.FillRect(px, y, BW, 1, ' ', fg, bg)
  END
END DrawBinder;

PROCEDURE DrawRevisions;
(* Popup: this document's ^KN snapshots, navigable with Up/Down/Enter/Esc *)
CONST RW = 50; RH = 16;
VAR i, r, px, py, maxScroll: INTEGER; fg, bg, hfg, hbg: INTEGER;
    line: ARRAY (RW + 1) OF CHAR;
BEGIN
  fg := ThFg(); bg := ThBg(); hfg := ThBg(); hbg := ThFg();
  px := (TUI.Cols - RW) DIV 2 + 1;
  py := (TUI.Rows - RH) DIV 2;
  IF py < 1 THEN py := 1 END;
  TUI.DrawBox(px - 1, py - 1, RW + 2, RH + 2, ThStFg(), ThStBg());
  TUI.PutStr(px, py - 1, " Snapshots  (Enter=restore  Esc=close) ", ThStFg(), ThStBg());
  maxScroll := revCount - RH;
  IF maxScroll < 0 THEN maxScroll := 0 END;
  IF revScroll > maxScroll THEN revScroll := maxScroll END;
  IF revScroll < 0 THEN revScroll := 0 END;
  IF revSel < revScroll THEN revScroll := revSel END;
  IF revSel >= revScroll + RH THEN revScroll := revSel - RH + 1 END;
  FOR i := 0 TO RH - 1 DO
    r := revScroll + i;
    IF r < revCount THEN
      COPY(revNames[r], line);
      IF Strings.Length(line) > RW THEN line[RW] := 0X END;
      IF r = revSel THEN
        TUI.FillRect(px, py + i, RW, 1, ' ', hfg, hbg); TUI.PutStr(px, py + i, line, hfg, hbg)
      ELSE
        TUI.FillRect(px, py + i, RW, 1, ' ', fg, bg); TUI.PutStr(px, py + i, line, fg, bg)
      END
    ELSE
      TUI.FillRect(px, py + i, RW, 1, ' ', fg, bg)
    END
  END
END DrawRevisions;

PROCEDURE DrawOutline;
(* Draw overlay showing all # headings; navigable with Up/Down/Enter *)
CONST OW = 50; OH = 20;
VAR i, r, n, px, py, vis, maxScroll, lev: INTEGER;
    line: ARRAY 54 OF CHAR;
    fg, bg, hfg, hbg: INTEGER;
BEGIN
  fg := ThFg(); bg := ThBg();
  hfg := ThBg(); hbg := ThFg();
  px := (TUI.Cols - OW) DIV 2 + 1;
  py := (TUI.Rows - OH) DIV 2;
  IF py < 1 THEN py := 1 END;
  TUI.DrawBox(px - 1, py - 1, OW + 2, OH + 2, ThStFg(), ThStBg());
  TUI.PutStr(px, py - 1, "Outline  (Enter=jump  Esc=close)", ThStFg(), ThStBg());
  (* Count headings *)
  n := 0;
  FOR r := 0 TO numLines - 1 DO
    IF lines[r].s[0] = '#' THEN INC(n) END
  END;
  maxScroll := n - OH;
  IF maxScroll < 0 THEN maxScroll := 0 END;
  IF outlineScroll > maxScroll THEN outlineScroll := maxScroll END;
  IF outlineScroll < 0 THEN outlineScroll := 0 END;
  (* Draw OH entries starting at outlineScroll *)
  i := 0; vis := 0;
  FOR r := 0 TO numLines - 1 DO
    IF lines[r].s[0] = '#' THEN
      IF (i >= outlineScroll) & (vis < OH) THEN
        lev := 0;
        WHILE (lev < Strings.Length(lines[r].s)) & (lines[r].s[lev] = '#') DO INC(lev) END;
        line[0] := 0X;
        IF lev >= 2 THEN Strings.Append("  ", line) END;
        Strings.Append(lines[r].s, line);
        IF Strings.Length(line) > OW THEN line[OW] := 0X END;
        IF r = outlineSel THEN
          TUI.FillRect(px, py + vis, OW, 1, ' ', hfg, hbg);
          TUI.PutStr(px, py + vis, line, hfg, hbg)
        ELSE
          TUI.FillRect(px, py + vis, OW, 1, ' ', fg, bg);
          TUI.PutStr(px, py + vis, line, fg, bg)
        END;
        INC(vis)
      END;
      INC(i)
    END
  END;
  FOR i := vis TO OH - 1 DO
    TUI.FillRect(px, py + i, OW, 1, ' ', fg, bg)
  END
END DrawOutline;

PROCEDURE DrawPaneHeader(y: INTEGER; focused: BOOLEAN);
VAR s: ARRAY 256 OF CHAR; fg, bg: INTEGER;
BEGIN
  IF focused THEN fg := ThStFg(); bg := ThStBg() ELSE fg := ThDimFg(); bg := ThBg() END;
  IF filePath[0] = 0X THEN COPY("[No Name]", s) ELSE COPY(filePath, s) END;
  IF dirty THEN Strings.Append(" *", s) END;
  TUI.FillRect(TextX0(), y, TextW(), 1, ' ', fg, bg);
  TUI.PutStr(TextX0(), y, s, fg, bg)
END DrawPaneHeader;

PROCEDURE DrawPaneContent(y0, h: INTEGER);
(* Draw the active buffer's lines, unwrapped, into screen rows y0..y0+h-1.
   Used for both windows when split (see the "wrap disabled" note on
   ^OK in the manual). *)
VAR screenY, row: INTEGER;
BEGIN
  FOR screenY := 0 TO h - 1 DO
    row := topLine + screenY;
    IF row < numLines THEN DrawTextLine(y0 + screenY, row)
    ELSE TUI.FillRect(TextX0(), y0 + screenY, TextW(), 1, ' ', ThFg(), ThBg())
    END
  END
END DrawPaneContent;

PROCEDURE ClampTopLine(h: INTEGER);
(* Simple (non-wrap-aware) scroll clamp, used for split panes. *)
BEGIN
  IF curRow < topLine THEN topLine := curRow END;
  IF curRow >= topLine + h THEN topLine := curRow - h + 1 END;
  IF topLine < 0 THEN topLine := 0 END
END ClampTopLine;

PROCEDURE SplitPaneHeights(textH: INTEGER; VAR topH, botH: INTEGER);
VAR avail: INTEGER;
BEGIN
  avail := textH - 2;
  IF avail < 2 THEN avail := 2 END;
  topH := avail DIV 2; botH := avail - topH
END SplitPaneHeights;

PROCEDURE DrawSplitPanes(textH: INTEGER);
(* ^OK: two panes, one above the other, each with a one-line header
   showing its filename. Whichever pane is NOT focused is rendered by
   briefly swapping it into the active globals (SwapWithOther) so the
   normal single-buffer drawing code can be reused unmodified. *)
VAR topH, botH: INTEGER;
BEGIN
  SplitPaneHeights(textH, topH, botH);
  IF ~focusOther THEN
    ClampTopLine(topH);
    DrawPaneHeader(1, TRUE); DrawPaneContent(2, topH);
    SwapWithOther;
    DrawPaneHeader(2 + topH, FALSE); DrawPaneContent(3 + topH, botH);
    SwapWithOther
  ELSE
    SwapWithOther;
    DrawPaneHeader(1, FALSE); DrawPaneContent(2, topH);
    SwapWithOther;
    ClampTopLine(botH);
    DrawPaneHeader(2 + topH, TRUE); DrawPaneContent(3 + topH, botH)
  END
END DrawSplitPanes;

PROCEDURE DrawAll;
VAR row, screenY, textH: INTEGER;
    bufRow, segF, csf, screenX, screenRow, row2, sf2, e: INTEGER;
    topH2, botH2, y0: INTEGER;
BEGIN
  textH := TUI.Rows - 1;
  TUI.InvalidateFront;
  TUI.ClearBack(ThFg(), ThBg());
  IF ~otherPaneOpen THEN EnsureVisible END;
  styleCurKind := StNone;
  (* Compute focus paragraph bounds around curRow *)
  IF focusMode THEN
    focusParaS := curRow;
    WHILE (focusParaS > 0) & (LineLen(focusParaS - 1) > 0) DO DEC(focusParaS) END;
    focusParaE := curRow;
    WHILE (focusParaE < numLines - 1) & (LineLen(focusParaE + 1) > 0) DO INC(focusParaE) END
  END;
  (* Draw text lines *)
  IF otherPaneOpen THEN
    DrawSplitPanes(textH)
  ELSIF wrap THEN
    bufRow := topLine; segF := 0;
    FOR screenY := 1 TO textH DO
      IF bufRow < numLines THEN
        DrawSegment(screenY, bufRow, segF);
        IF SegEnd(bufRow, segF) >= LineLen(bufRow) THEN
          INC(bufRow); segF := 0
        ELSE
          segF := SegNext(bufRow, segF)
        END
      ELSE
        TUI.FillRect(TextX0(), screenY, TextW(), 1, ' ', ThFg(), ThBg())
      END
    END
  ELSE
    FOR screenY := 1 TO textH DO
      row := topLine + screenY - 1;
      IF row < numLines THEN
        DrawTextLine(screenY, row)
      ELSE
        TUI.FillRect(TextX0(), screenY, TextW(), 1, ' ', ThFg(), ThBg())
      END
    END
  END;
  DrawStatus;
  IF (helpLevel >= 1) & (prefix # PrefNone) THEN DrawPrefixMenu(prefix) END;
  IF mode = ModePalette THEN DrawPalette END;
  IF mode = ModeOutline THEN DrawOutline END;
  IF mode = ModeBinder THEN DrawBinder END;
  IF mode = ModeRevisions THEN DrawRevisions END;
  TUI.Flush;
  (* Place hardware cursor *)
  IF (mode = ModeBinder) OR (mode = ModeOutline) OR (mode = ModeRevisions) THEN
    TUI.SetCursor(1, TUI.Rows)
  ELSIF mode = ModeSearch THEN
    TUI.SetCursor(Min(7 + Strings.Length(searchStr), TUI.Cols), TUI.Rows)
  ELSIF mode = ModeInput THEN
    TUI.SetCursor(Min(Strings.Length(inpLabel) + 3 + Strings.Length(inpValue), TUI.Cols), TUI.Rows)
  ELSIF otherPaneOpen THEN
    SplitPaneHeights(textH, topH2, botH2);
    IF ~focusOther THEN y0 := 2 ELSE y0 := 3 + topH2 END;
    TUI.SetCursor(CellCount(curRow, leftCol, curCol) + TextX0(), curRow - topLine + y0)
  ELSIF wrap THEN
    CurSeg(csf);
    screenX := CellCount(curRow, csf, curCol) + 1;
    screenRow := 1;
    row2 := topLine; sf2 := 0;
    LOOP
      IF (row2 = curRow) & (sf2 = csf) THEN EXIT END;
      e := SegEnd(row2, sf2);
      IF e >= LineLen(row2) THEN INC(row2); sf2 := 0
      ELSE sf2 := SegNext(row2, sf2)
      END;
      INC(screenRow);
      IF screenRow > textH THEN screenRow := textH; EXIT END
    END;
    TUI.SetCursor(screenX + TextX0() - 1, screenRow)
  ELSE
    TUI.SetCursor(CellCount(curRow, leftCol, curCol) + TextX0(), curRow - topLine + 1)
  END
END DrawAll;

(* ── Input Prompt Helpers ────────────────────────────────────────── *)

PROCEDURE StartInput(label: ARRAY OF CHAR; action: INTEGER);
BEGIN
  COPY(label, inpLabel);
  inpValue[0] := 0X;
  inpCursor := 0;
  inpAction := action;
  mode := ModeInput;
  needRedraw := TRUE
END StartInput;

PROCEDURE CommitInput;
VAR tmp: ARRAY 16 OF CHAR; n: INTEGER; ok: BOOLEAN;
    r1, c1, r2, c2, i: INTEGER; f: Files.File; r: Files.Rider; tmpBuf: LineBuf;
    f2: Files.File; rr: Files.Rider;
BEGIN
  mode := ModeNormal;
  CASE inpAction OF
    ActSaveAs:
      COPY(inpValue, filePath);
      ok := SaveFile()
  | ActOpen:
      ok := LoadFile(inpValue);
      IF ok THEN
        curRow := 0; curCol := 0; topLine := 0; undoTop := 0;
        hasBlkB := FALSE; hasBlkE := FALSE;
        SetStatus("Opened")
      ELSE SetStatus("File not found")
      END
  | ActWBlk:
      IF hasBlkB & hasBlkE THEN
        NormBlock(r1, c1, r2, c2);
        f := Files.New(inpValue);
        IF f # NIL THEN
          Files.Set(r, f, 0);
          IF r1 = r2 THEN
            Strings.Extract(lines[r1].s, c1, c2 - c1, tmpBuf);
            Files.WriteLine(r, tmpBuf)
          ELSE
            Strings.Extract(lines[r1].s, c1, MaxLineLen, tmpBuf);
            Files.WriteLine(r, tmpBuf);
            FOR i := r1 + 1 TO r2 - 1 DO Files.WriteLine(r, lines[i].s) END;
            Strings.Extract(lines[r2].s, 0, c2, tmpBuf);
            Files.WriteLine(r, tmpBuf)
          END;
          Files.Register(f); Files.Close(f);
          SetStatus("Block written")
        ELSE SetStatus("Cannot create file")
        END
      END
  | ActRFile:
      f2 := Files.Old(inpValue);
      IF f2 # NIL THEN
        Files.Set(rr, f2, 0);
        WHILE ~rr.eof DO
          Files.ReadLine(rr, tmpBuf);
          IF ~rr.eof OR (tmpBuf[0] # 0X) THEN
            ShiftLinesDown(curRow + 1);
            COPY(tmpBuf, lines[curRow + 1].s);
            INC(curRow)
          END
        END;
        Files.Close(f2);
        dirty := TRUE;
        SetStatus("File inserted")
      ELSE SetStatus("File not found")
      END
  | ActMargin:
      IF Strings.StrToInt(inpValue, n) THEN
        wrapMargin := n;
        Strings.IntToStr(n, tmp);
        SetStatus("Wrap margin set to ");  (* will be overwritten below *)
        COPY("Wrap margin: ", statusMsg);
        Strings.Append(tmp, statusMsg)
      END
  | ActProjNew:
      IF inpValue[0] # 0X THEN ProjNew(inpValue) END
  | ActProjOpen:
      IF inpValue[0] # 0X THEN
        EnsureProjExt(inpValue);
        IF LoadProjFile(inpValue) THEN
          projCurDoc := ProjIndexOf(filePath);
          COPY("Project opened: ", statusMsg);
          Strings.Append(projPath, statusMsg)
        ELSE SetStatus("Cannot open project file")
        END
      END
  | ActProjReplFind:
      COPY(inpValue, replSearch);
      StartInput("Replace with (project-wide)", ActProjReplWith)
  | ActProjReplWith:
      ProjReplace(replSearch, inpValue)
  | ActSynopsis:
      WriteSynopsis(synopsisTarget, inpValue);
      IF synopsisFromBinder THEN mode := ModeBinder END
  | ActOtherOpen:
      IF inpValue[0] # 0X THEN
        ok := LoadFileIntoSnap(inpValue, otherPane);
        otherPaneOpen := TRUE; focusOther := FALSE;
        COPY("Opened in other window: ", statusMsg); Strings.Append(otherPane.filePath, statusMsg)
      END
  | ActAnnotate:
      IF inpValue[0] # 0X THEN
        ShiftLinesDown(curRow);
        UndoSaveInsLine(curRow);
        COPY(".. ", lines[curRow].s); Strings.Append(inpValue, lines[curRow].s);
        curCol := Strings.Length(lines[curRow].s);
        dirty := TRUE
      END
  ELSE
  END;
  needRedraw := TRUE
END CommitInput;

(* ── Key Dispatch ────────────────────────────────────────────────── *)

PROCEDURE HandlePaletteKey(k: CHAR);
BEGIN
  IF (k = TUI.KEsc) OR (k = TUI.KF1) THEN mode := ModeNormal
  ELSIF k = TUI.KUp THEN
    IF palScroll > 0 THEN DEC(palScroll) END
  ELSIF k = TUI.KDown THEN
    INC(palScroll)   (* clamped in DrawPalette *)
  END;
  needRedraw := TRUE
END HandlePaletteKey;

PROCEDURE HandleSearchKey(k: CHAR);
VAR slen: INTEGER;
BEGIN
  IF k = TUI.KEsc THEN
    mode := ModeNormal; searchLen := 0; inReplace := FALSE; needRedraw := TRUE
  ELSIF k = TUI.KEnter THEN
    (* Confirm search, stay in Normal and position on match *)
    IF SearchForward(curRow, curCol) THEN
      curRow := searchRow; curCol := searchCol
    ELSE SetStatus("Not found")
    END;
    mode := ModeNormal; needRedraw := TRUE
  ELSIF k = TUI.KBackspace THEN
    TrimLastUTF8Char(searchStr);
    (* Live search as you type *)
    IF SearchForward(0, 0) THEN curRow := searchRow; curCol := searchCol END;
    needRedraw := TRUE
  ELSIF (ORD(k) >= 32) & (ORD(k) < 127) THEN
    slen := Strings.Length(searchStr);
    IF slen < 255 THEN
      searchStr[slen] := k; searchStr[slen + 1] := 0X
    END;
    IF SearchForward(0, 0) THEN curRow := searchRow; curCol := searchCol END;
    needRedraw := TRUE
  END
END HandleSearchKey;

PROCEDURE HandleReplaceStep(k: CHAR);
BEGIN
  (* Waiting on Y/N/A/Esc for each replace instance *)
  IF (k = 'y') OR (k = 'Y') THEN
    DoReplace;
    IF SearchForward(curRow, curCol) THEN
      curRow := searchRow; curCol := searchCol
    ELSE mode := ModeNormal; SetStatus("Replace done")
    END
  ELSIF (k = 'a') OR (k = 'A') THEN
    (* Replace all remaining *)
    WHILE SearchForward(curRow, curCol) DO
      curRow := searchRow; curCol := searchCol;
      DoReplace
    END;
    mode := ModeNormal; SetStatus("All replaced")
  ELSIF (k = 'n') OR (k = 'N') THEN
    IF SearchForward(searchRow, searchCol + searchLen) THEN
      curRow := searchRow; curCol := searchCol
    ELSE mode := ModeNormal; SetStatus("No more matches")
    END
  ELSIF k = TUI.KEsc THEN
    mode := ModeNormal; SetStatus("Replace cancelled")
  END;
  needRedraw := TRUE
END HandleReplaceStep;

PROCEDURE HandleInputKey(k: CHAR);
VAR slen: INTEGER;
BEGIN
  IF k = TUI.KEsc THEN
    mode := ModeNormal; needRedraw := TRUE
  ELSIF k = TUI.KEnter THEN
    CommitInput
  ELSIF k = TUI.KBackspace THEN
    slen := Strings.Length(inpValue);
    TrimLastUTF8Char(inpValue);
    DEC(inpCursor, slen - Strings.Length(inpValue));
    needRedraw := TRUE
  ELSIF (ORD(k) >= 32) & (ORD(k) < 127) THEN
    slen := Strings.Length(inpValue);
    IF slen < 511 THEN inpValue[slen] := k; inpValue[slen + 1] := 0X; INC(inpCursor) END;
    needRedraw := TRUE
  END
END HandleInputKey;

PROCEDURE HandleConfirmKey(k: CHAR);
BEGIN
  IF (k = 'y') OR (k = 'Y') THEN running := FALSE
  ELSE mode := ModeNormal; SetStatus("")
  END;
  needRedraw := TRUE
END HandleConfirmKey;

PROCEDURE HandlePrefixK(k: CHAR);
BEGIN
  prefix := PrefNone;
  CASE k OF
    'b', 'B': BlockBegin
  | 'k', 'K': BlockEnd
  | 'c', 'C': BlockCopy
  | 'v', 'V': BlockMove
  | 'y', 'Y': BlockDelete
  | 'h', 'H': BlockHide
  | 'p', 'P': KillPut
  | 'd', 'D', 's', 'S':
      IF filePath[0] = 0X THEN StartInput("Save as", ActSaveAs)
      ELSE IF ~SaveFile() THEN SetStatus("Save failed") END
      END
  | 'x', 'X':
      IF ~dirty OR SaveFile() THEN running := FALSE END
  | 'q', 'Q':
      IF dirty THEN mode := ModeConfirm
      ELSE running := FALSE
      END
  | 'w', 'W': StartInput("Write block to file", ActWBlk)
  | 'r', 'R': StartInput("Read file", ActRFile)
  | 'm', 'M': ExportRTF
  | 'j', 'J': ExportHtml
  | 'g', 'G': ExportEpub
  | 'e', 'E': ExportClean
  | 'n', 'N': SaveSnapshot
  | 'a', 'A': CopyFromOther
  | 'u', 'U': BlockPrev
  | 'o', 'O': ListRevisions
  ELSE SetStatus("Unknown ^K command")
  END;
  needRedraw := TRUE
END HandlePrefixK;

PROCEDURE HandlePrefixQ(k: CHAR);
BEGIN
  prefix := PrefNone;
  CASE k OF
    's', 'S': MoveLineStart
  | 'd', 'D': MoveLineEnd
  | 'e', 'E': ScreenTop
  | 'x', 'X': ScreenBottom
  | 'r', 'R': MoveDocStart
  | 'c', 'C': MoveDocEnd
  | 'f', 'F':
      mode := ModeSearch;
      searchStr[0] := 0X; searchLen := 0;
      inReplace := FALSE;
      SetStatus("Find (type string, Enter to confirm)")
  | 'a', 'A':
      mode := ModeSearch;
      searchStr[0] := 0X; searchLen := 0;
      inReplace := TRUE;
      SetStatus("Find (for replace):")
  | 'y', 'Y': DeleteToEOL
  | 'p', 'P': JumpPrev
  | 'b', 'B': JumpBlockBegin
  | 'k', 'K': JumpBlockEnd
  | ',':      MoveSentBack
  | '.':      MoveSentForward
  | '[':      MoveParaBack
  | ']':      MoveParaForward
  | 'o', 'O': MoveNextHeading
  | 'g', 'G': TransposeChars
  | 't', 'T': TransposeWords
  | 'n', 'N': NextMisspelling
  | 'i', 'I': NextStyleIssue
  | 'm', 'M': NextComment
  | 'u', 'U': PrevComment
  | 'v', 'V': JumpBlockSource
  | 'h', 'H':
      outlineSel := curRow;
      WHILE (outlineSel < numLines) & (lines[outlineSel].s[0] # '#') DO INC(outlineSel) END;
      IF outlineSel >= numLines THEN outlineSel := 0 END;
      outlineScroll := 0; mode := ModeOutline
  ELSE SetStatus("Unknown ^Q command")
  END;
  needRedraw := TRUE
END HandlePrefixQ;

PROCEDURE HandlePrefixO(k: CHAR);
VAR tmp: ARRAY 32 OF CHAR; wc: INTEGER;
BEGIN
  prefix := PrefNone;
  CASE k OF
    'c', 'C':
      wc := WordCount();
      COPY("Words: ", statusMsg); Strings.IntToStr(wc, tmp); Strings.Append(tmp, statusMsg);
      Strings.Append("  Lines: ", statusMsg); Strings.IntToStr(numLines, tmp); Strings.Append(tmp, statusMsg)
  | 'f', 'F':
      focusMode := ~focusMode;
      IF focusMode THEN SetStatus("Focus mode ON") ELSE SetStatus("Focus mode OFF") END
  | 'b', 'B':
      IF theme = ThWP THEN theme := ThWS
      ELSIF theme = ThWS THEN theme := ThDef
      ELSE theme := ThWP
      END;
      SetStatus("Theme changed")
  | 'h', 'H':
      helpLevel := (helpLevel + 1) MOD 3;
      IF helpLevel = 0 THEN SetStatus("Help: clean screen")
      ELSIF helpLevel = 1 THEN SetStatus("Help: menus on")
      ELSE SetStatus("Help: menus + hints")
      END
  | 'w', 'W':
      wrap := ~wrap;
      IF wrap THEN SetStatus("Word wrap ON") ELSE SetStatus("Word wrap OFF") END
  | 't', 'T':
      typewriter := ~typewriter;
      IF typewriter THEN SetStatus("Typewriter scroll ON")
      ELSE SetStatus("Typewriter scroll OFF")
      END
  | 'v', 'V':
      overtype := ~overtype;
      IF overtype THEN SetStatus("Overtype ON") ELSE SetStatus("Insert ON") END
  | 'r', 'R': StartInput("Set wrap margin (columns)", ActMargin)
  | 's', 'S':
      spellEnabled := ~spellEnabled;
      IF spellEnabled THEN RunSpellCheck
      ELSE Dict.Init(misspelled); SetStatus("Spell check OFF")
      END
  | 'a', 'A': AddToPersonalDict
  | 'l', 'L':
      styleEnabled := ~styleEnabled;
      IF styleEnabled THEN SetStatus("Style check ON")
      ELSE styleCurKind := StNone; SetStatus("Style check OFF")
      END
  | 'k', 'K': ToggleOtherWindow
  | 'd', 'D':
      revealCodes := ~revealCodes;
      IF revealCodes THEN SetStatus("Reveal codes ON") ELSE SetStatus("Reveal codes OFF") END
  ELSE SetStatus("Unknown ^O command")
  END;
  needRedraw := TRUE
END HandlePrefixO;

(* ── Project system (^P) ─────────────────────────────────────────── *)

PROCEDURE SaveProjFile;
(* Write projDocs[0..projDocCount-1] to projPath, one path per line. A
   note doc (^PM) is written with a leading "!" so LoadProjFile can tell
   it apart from a plain manuscript doc. *)
VAR f: Files.File; r: Files.Rider; i: INTEGER; ln: ARRAY 512 OF CHAR;
BEGIN
  IF projPath[0] = 0X THEN RETURN END;
  f := Files.New(projPath);
  IF f = NIL THEN SetStatus("Project: cannot write manifest"); RETURN END;
  Files.Set(r, f, 0);
  FOR i := 0 TO projDocCount - 1 DO
    IF projIsNote[i] THEN
      COPY("!", ln); Strings.Append(projDocs[i], ln); Files.WriteLine(r, ln)
    ELSE
      Files.WriteLine(r, projDocs[i])
    END
  END;
  Files.Register(f);
  Files.Close(f)
END SaveProjFile;

PROCEDURE LoadProjFile(path: ARRAY OF CHAR): BOOLEAN;
(* Read a .ostarproj manifest into projDocs. Returns TRUE on success. *)
VAR f: Files.File; r: Files.Rider; buf: ARRAY 512 OF CHAR;
BEGIN
  f := Files.Old(path);
  IF f = NIL THEN RETURN FALSE END;
  projDocCount := 0;
  Files.Set(r, f, 0);
  WHILE ~r.eof & (projDocCount < MaxProjDocs) DO
    Files.ReadLine(r, buf);
    IF buf[0] # 0X THEN
      IF buf[0] = '!' THEN
        Strings.Extract(buf, 1, Strings.Length(buf) - 1, projDocs[projDocCount]);
        projIsNote[projDocCount] := TRUE
      ELSE
        COPY(buf, projDocs[projDocCount]);
        projIsNote[projDocCount] := FALSE
      END;
      INC(projDocCount)
    END
  END;
  Files.Close(f);
  COPY(path, projPath);
  RETURN projDocCount > 0
END LoadProjFile;

(* Find filePath in projDocs; returns index or -1. *)
PROCEDURE ProjIndexOf(path: ARRAY OF CHAR): INTEGER;
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO projDocCount - 1 DO
    IF Strings.Compare(projDocs[i], path) = 0 THEN RETURN i END
  END;
  RETURN -1
END ProjIndexOf;

(* Save current file and open projDocs[idx]. *)
PROCEDURE OpenProjDoc(idx: INTEGER);
VAR msg: ARRAY 64 OF CHAR;
BEGIN
  IF (idx < 0) OR (idx >= projDocCount) THEN RETURN END;
  IF dirty THEN
    IF ~SaveFile() THEN SetStatus("Save failed — not switching"); RETURN END
  END;
  IF LoadFile(projDocs[idx]) THEN
    projCurDoc := idx;
    curRow := 0; curCol := 0; topLine := 0; undoTop := 0;
    hasBlkB := FALSE; hasBlkE := FALSE;
    COPY("Project: opened ", msg); Strings.Append(projDocs[idx], msg);
    SetStatus(msg)
  ELSE
    SetStatus("Project: file not found")
  END;
  needRedraw := TRUE
END OpenProjDoc;

PROCEDURE EnsureProjExt(VAR path: ARRAY OF CHAR);
(* Append .ostarproj if it isn't already there, so "fred" and
   "fred.ostarproj" both refer to the same project file. *)
BEGIN
  IF ~Strings.EndsWith(path, ".ostarproj") THEN
    Strings.Append(".ostarproj", path)
  END
END EnsureProjExt;

PROCEDURE ProjNew(name: ARRAY OF CHAR);
(* Create a new project named <name>, manifest at <name>.ostarproj *)
VAR tmp: ARRAY 32 OF CHAR;
BEGIN
  COPY(name, projPath);
  EnsureProjExt(projPath);
  projDocCount := 0;
  projCurDoc := -1;
  (* Add current file if we have one *)
  IF filePath[0] # 0X THEN
    COPY(filePath, projDocs[0]);
    projIsNote[0] := FALSE;
    projDocCount := 1;
    projCurDoc := 0
  END;
  SaveProjFile;
  Strings.IntToStr(projDocCount, tmp);
  COPY("Project created: ", statusMsg);
  Strings.Append(projPath, statusMsg);
  needRedraw := TRUE
END ProjNew;

PROCEDURE ProjAdd;
(* Add current file to the open project (if not already present). *)
VAR tmp: ARRAY 32 OF CHAR;
BEGIN
  IF projPath[0] = 0X THEN SetStatus("No open project — ^PN to create"); RETURN END;
  IF filePath[0] = 0X THEN SetStatus("Save file first (^KD)"); RETURN END;
  IF ProjIndexOf(filePath) >= 0 THEN SetStatus("Already in project"); RETURN END;
  IF projDocCount >= MaxProjDocs THEN SetStatus("Project full"); RETURN END;
  COPY(filePath, projDocs[projDocCount]);
  projIsNote[projDocCount] := FALSE;
  projCurDoc := projDocCount;
  INC(projDocCount);
  SaveProjFile;
  COPY("Added to project: ", statusMsg);
  Strings.Append(filePath, statusMsg);
  needRedraw := TRUE
END ProjAdd;

PROCEDURE ProjRemove;
(* Remove current file from the project manifest. *)
VAR i, idx: INTEGER;
BEGIN
  IF projPath[0] = 0X THEN SetStatus("No open project"); RETURN END;
  idx := ProjIndexOf(filePath);
  IF idx < 0 THEN SetStatus("Current file not in project"); RETURN END;
  FOR i := idx TO projDocCount - 2 DO
    COPY(projDocs[i + 1], projDocs[i]);
    projIsNote[i] := projIsNote[i + 1]
  END;
  DEC(projDocCount);
  IF projCurDoc >= projDocCount THEN projCurDoc := projDocCount - 1 END;
  SaveProjFile;
  SetStatus("Removed from project")
END ProjRemove;

PROCEDURE ProjNext;
BEGIN
  IF projPath[0] = 0X THEN SetStatus("No open project — ^PN to create"); RETURN END;
  IF projDocCount = 0 THEN SetStatus("Project is empty"); RETURN END;
  projCurDoc := ProjIndexOf(filePath);
  IF projCurDoc < 0 THEN projCurDoc := 0
  ELSE projCurDoc := (projCurDoc + 1) MOD projDocCount
  END;
  OpenProjDoc(projCurDoc)
END ProjNext;

PROCEDURE ProjPrev;
BEGIN
  IF projPath[0] = 0X THEN SetStatus("No open project — ^PN to create"); RETURN END;
  IF projDocCount = 0 THEN SetStatus("Project is empty"); RETURN END;
  projCurDoc := ProjIndexOf(filePath);
  IF projCurDoc < 0 THEN projCurDoc := projDocCount - 1
  ELSIF projCurDoc = 0 THEN projCurDoc := projDocCount - 1
  ELSE DEC(projCurDoc)
  END;
  OpenProjDoc(projCurDoc)
END ProjPrev;

PROCEDURE ProjList;
(* Show project document list in the status message area. *)
VAR i: INTEGER; tmp: ARRAY 32 OF CHAR;
BEGIN
  IF projPath[0] = 0X THEN SetStatus("No open project — ^PN to create"); RETURN END;
  COPY("Project (", statusMsg);
  Strings.IntToStr(projDocCount, tmp); Strings.Append(tmp, statusMsg);
  Strings.Append(" docs): ", statusMsg);
  FOR i := 0 TO projDocCount - 1 DO
    IF i > 0 THEN Strings.Append(", ", statusMsg) END;
    IF i = projCurDoc THEN Strings.Append("[", statusMsg) END;
    Strings.Append(projDocs[i], statusMsg);
    IF i = projCurDoc THEN Strings.Append("]", statusMsg) END
  END;
  needRedraw := TRUE
END ProjList;

(* ── Project compile (^PK = RTF, ^PT = plain text) ──────────────── *)

PROCEDURE CompileRTF;
(* ^PK — concatenate every non-note project document, in manifest
   order, through Markdown.mod's manuscript-mode RTF renderer (same
   formatting as ^K M). *)
VAR f: Files.File; sf: Files.File; sr: Files.Rider;
    outPath: ARRAY 512 OF CHAR; lb: LineBuf;
    j, di: INTEGER;
BEGIN
  IF projPath[0] = 0X THEN SetStatus("No open project — ^PN to create"); RETURN END;
  IF projDocCount = 0   THEN SetStatus("Project is empty"); RETURN END;
  IF dirty THEN IF ~SaveFile() THEN SetStatus("Save failed"); RETURN END END;

  COPY(projPath, outPath);
  j := Strings.Length(outPath) - 1;
  WHILE (j > 0) & (outPath[j] # '.') & (outPath[j] # '/') DO DEC(j) END;
  IF (j > 0) & (outPath[j] = '.') THEN outPath[j] := 0X END;
  Strings.Append(".rtf", outPath);

  f := Files.New(outPath);
  IF f = NIL THEN SetStatus("Compile: cannot create RTF file"); RETURN END;
  Files.Set(expRider, f, 0);

  Markdown.Reset;
  Markdown.RtfManuscriptHeader;

  FOR di := 0 TO projDocCount - 1 DO
    IF ~projIsNote[di] THEN
      sf := Files.Old(projDocs[di]);
      IF sf # NIL THEN
        Files.Set(sr, sf, 0);
        WHILE ~sr.eof DO
          Files.ReadLine(sr, lb);
          IF ~sr.eof OR (lb[0] # 0X) THEN
            Markdown.RtfManuscriptLine(lb)
          END
        END;
        Files.Close(sf)
      END
    END
  END;

  Markdown.RtfManuscriptFooter;
  Files.Register(f); Files.Close(f);
  COPY("Compiled RTF: ", statusMsg); Strings.Append(outPath, statusMsg);
  needRedraw := TRUE
END CompileRTF;

PROCEDURE CompileEpub;
(* ^PG — concatenate every non-note project document, in manifest
   order, through Markdown.mod's Epub* renderer (same content as
   ^K G), then package via ZipWriter — the project-compile sibling of
   CompileRTF above. *)
VAR f: Files.File; sf: Files.File; sr: Files.Rider;
    outPath, tmpMime, tmpContainer, tmpOpf, tmpNav, tmpContent, entryName: ARRAY 512 OF CHAR;
    lb: LineBuf;
    j, di, i, chapters: INTEGER; ok: BOOLEAN;
BEGIN
  IF projPath[0] = 0X THEN SetStatus("No open project — ^PN to create"); RETURN END;
  IF projDocCount = 0   THEN SetStatus("Project is empty"); RETURN END;
  IF dirty THEN IF ~SaveFile() THEN SetStatus("Save failed"); RETURN END END;

  COPY(projPath, outPath);
  j := Strings.Length(outPath) - 1;
  WHILE (j > 0) & (outPath[j] # '.') & (outPath[j] # '/') DO DEC(j) END;
  IF (j > 0) & (outPath[j] = '.') THEN outPath[j] := 0X END;
  Strings.Append(".epub", outPath);

  MakeTempPath(outPath, ".mime.tmp", tmpMime);
  MakeTempPath(outPath, ".container.tmp", tmpContainer);
  MakeTempPath(outPath, ".opf.tmp", tmpOpf);
  MakeTempPath(outPath, ".nav.tmp", tmpNav);

  Markdown.Reset;

  f := Files.New(tmpMime);
  IF f = NIL THEN SetStatus("Compile: cannot create temp file"); RETURN END;
  Files.Set(expRider, f, 0);
  Markdown.EpubMimetype;
  Files.Register(f); Files.Close(f);

  f := Files.New(tmpContainer);
  Files.Set(expRider, f, 0);
  Markdown.EpubContainerXml;
  Files.Register(f); Files.Close(f);

  EpubChapterTempPath(outPath, 1, tmpContent);
  f := Files.New(tmpContent);
  Files.Set(expRider, f, 0);
  Markdown.EpubContentHeader;
  FOR di := 0 TO projDocCount - 1 DO
    IF ~projIsNote[di] THEN
      sf := Files.Old(projDocs[di]);
      IF sf # NIL THEN
        Files.Set(sr, sf, 0);
        WHILE ~sr.eof DO
          Files.ReadLine(sr, lb);
          IF ~sr.eof OR (lb[0] # 0X) THEN
            IF (Markdown.EpubChapterNum() < EpubMaxChapters) & Markdown.EpubStartsChapter(lb) THEN
              Markdown.EpubContentFooter;
              Files.Register(f); Files.Close(f);
              Markdown.EpubBeginChapter;
              EpubChapterTempPath(outPath, Markdown.EpubChapterNum(), tmpContent);
              f := Files.New(tmpContent);
              Files.Set(expRider, f, 0);
              Markdown.EpubContentHeader
            END;
            Markdown.EpubLine(lb)
          END
        END;
        Files.Close(sf)
      END
    END
  END;
  Markdown.EpubContentFooter;
  Files.Register(f); Files.Close(f);
  chapters := Markdown.EpubChapterNum();

  f := Files.New(tmpOpf);
  Files.Set(expRider, f, 0);
  Markdown.EpubPackageOpf(chapters);
  Files.Register(f); Files.Close(f);

  f := Files.New(tmpNav);
  Files.Set(expRider, f, 0);
  Markdown.EpubNavXhtml;
  Files.Register(f); Files.Close(f);

  ok := ZipWriter.Begin(outPath);
  ok := ZipWriter.Add("mimetype", tmpMime) & ok;
  ok := ZipWriter.Add("META-INF/container.xml", tmpContainer) & ok;
  ok := ZipWriter.Add("OEBPS/package.opf", tmpOpf) & ok;
  i := 1;
  WHILE i <= chapters DO
    EpubChapterTempPath(outPath, i, tmpContent);
    EpubChapterEntryName(i, entryName);
    ok := ZipWriter.Add(entryName, tmpContent) & ok;
    INC(i)
  END;
  ok := ZipWriter.Add("OEBPS/nav.xhtml", tmpNav) & ok;
  ok := ZipWriter.Finish() & ok;

  Files.Delete(tmpMime); Files.Delete(tmpContainer); Files.Delete(tmpOpf);
  i := 1;
  WHILE i <= chapters DO
    EpubChapterTempPath(outPath, i, tmpContent); Files.Delete(tmpContent); INC(i)
  END;
  Files.Delete(tmpNav);

  IF ok THEN
    COPY("Compiled EPUB: ", statusMsg); Strings.Append(outPath, statusMsg)
  ELSE
    SetStatus("EPUB compile failed")
  END;
  needRedraw := TRUE
END CompileEpub;

PROCEDURE CompileClean;
VAR f: Files.File; r: Files.Rider; sf: Files.File; sr: Files.Rider;
    outPath: ARRAY 512 OF CHAR; lb: LineBuf;
    j, di: INTEGER; firstDoc: BOOLEAN;
BEGIN
  IF projPath[0] = 0X THEN SetStatus("No open project — ^PN to create"); RETURN END;
  IF projDocCount = 0   THEN SetStatus("Project is empty"); RETURN END;
  IF dirty THEN IF ~SaveFile() THEN SetStatus("Save failed"); RETURN END END;

  COPY(projPath, outPath);
  j := Strings.Length(outPath) - 1;
  WHILE (j > 0) & (outPath[j] # '.') & (outPath[j] # '/') DO DEC(j) END;
  IF (j > 0) & (outPath[j] = '.') THEN outPath[j] := 0X END;
  Strings.Append(".txt", outPath);

  f := Files.New(outPath);
  IF f = NIL THEN SetStatus("Compile: cannot create text file"); RETURN END;
  Files.Set(r, f, 0);

  firstDoc := TRUE;
  FOR di := 0 TO projDocCount - 1 DO
    IF ~projIsNote[di] THEN
    sf := Files.Old(projDocs[di]);
    IF sf # NIL THEN
      IF ~firstDoc THEN lb[0] := 0X; Files.WriteLine(r, lb) END;
      Files.Set(sr, sf, 0);
      WHILE ~sr.eof DO
        Files.ReadLine(sr, lb);
        IF ~sr.eof OR (lb[0] # 0X) THEN
          IF ~((lb[0] = '.') & (lb[1] = '.')) THEN Files.WriteLine(r, lb) END
        END
      END;
      Files.Close(sf);
      firstDoc := FALSE
    END
    END
  END;

  Files.Register(f); Files.Close(f);
  COPY("Compiled text: ", statusMsg); Strings.Append(outPath, statusMsg);
  needRedraw := TRUE
END CompileClean;

(* ── Project-wide search (^PS) ───────────────────────────────────── *)

PROCEDURE ProjFind;
(* Search searchStr across all project docs, starting after current cursor. *)
VAR sf: Files.File; sr: Files.Rider; lb: LineBuf;
    startDi, di, row, pos, tryCol: INTEGER; found: BOOLEAN;
BEGIN
  IF projPath[0] = 0X THEN SetStatus("No open project"); RETURN END;
  IF searchStr[0] = 0X THEN
    SetStatus("No search string — use ^QF first"); RETURN
  END;

  startDi := ProjIndexOf(filePath);
  IF startDi < 0 THEN startDi := 0 END;
  found := FALSE;

  (* First: continue searching current in-memory doc from cursor forward *)
  row := curRow;
  WHILE (row < numLines) & ~found DO
    IF row = curRow THEN tryCol := curCol + 1 ELSE tryCol := 0 END;
    Strings.Extract(lines[row].s, tryCol, MaxLineLen, lb);
    pos := Strings.Pos(searchStr, lb);
    IF pos >= 0 THEN
      curRow := row; curCol := tryCol + pos;
      searchRow := row; searchCol := curCol; searchLen := Strings.Length(searchStr);
      goalCol := -1; found := TRUE
    END;
    INC(row)
  END;

  (* Then scan remaining project docs *)
  IF ~found THEN
    di := (startDi + 1) MOD projDocCount;
    WHILE ~found & (di # startDi) DO
      sf := Files.Old(projDocs[di]);
      IF sf # NIL THEN
        Files.Set(sr, sf, 0);
        row := 0;
        WHILE ~sr.eof & ~found DO
          Files.ReadLine(sr, lb);
          pos := Strings.Pos(searchStr, lb);
          IF (~sr.eof OR (lb[0] # 0X)) & (pos >= 0) THEN
            Files.Close(sf); sf := NIL;
            IF dirty & ~SaveFile() THEN
              SetStatus("Save failed — not switching"); found := TRUE
            ELSE
              IF LoadFile(projDocs[di]) THEN
                projCurDoc := di;
                curRow := row; curCol := pos; topLine := 0; undoTop := 0;
                hasBlkB := FALSE; hasBlkE := FALSE;
                searchRow := row; searchCol := pos;
                searchLen := Strings.Length(searchStr);
                goalCol := -1; found := TRUE
              END
            END
          END;
          IF ~found THEN INC(row) END
        END;
        IF sf # NIL THEN Files.Close(sf) END
      END;
      di := (di + 1) MOD projDocCount
    END
  END;

  IF found & (statusMsg[0] = 0X) THEN
    COPY("Found in ", statusMsg); Strings.Append(filePath, statusMsg)
  ELSIF ~found THEN
    SetStatus("Not found in project")
  END;
  needRedraw := TRUE
END ProjFind;

(* ── Project-wide replace (^PW) ──────────────────────────────────── *)

PROCEDURE ProjReplace(findStr, withStr: ARRAY OF CHAR);
(* Replace every occurrence of findStr with withStr in every project
   document (not just the open one). Each file is loaded, fully
   replaced, and saved in turn; the originally active document is
   reloaded afterward so the writer ends up back where they started. *)
VAR i, n, replCount, fileCount: INTEGER;
    savedPath: ARRAY 512 OF CHAR; tmp1, tmp2: ARRAY 16 OF CHAR;
BEGIN
  IF projPath[0] = 0X THEN SetStatus("No open project — ^PN to create"); RETURN END;
  IF projDocCount = 0 THEN SetStatus("Project is empty"); RETURN END;
  IF findStr[0] = 0X THEN SetStatus("No search string"); RETURN END;
  IF dirty & ~SaveFile() THEN SetStatus("Save failed — aborted"); RETURN END;
  COPY(filePath, savedPath);
  COPY(findStr, searchStr); COPY(withStr, replWith);
  replCount := 0; fileCount := 0;
  FOR i := 0 TO projDocCount - 1 DO
    IF LoadFile(projDocs[i]) THEN
      curRow := 0; curCol := 0; n := 0;
      WHILE SearchForward(curRow, curCol) DO
        curRow := searchRow; curCol := searchCol;
        DoReplace;
        INC(n)
      END;
      IF n > 0 THEN
        INC(replCount, n); INC(fileCount);
        IF ~SaveFile() THEN SetStatus("Save failed partway through — stopped"); RETURN END
      END
    END
  END;
  IF (savedPath[0] # 0X) & LoadFile(savedPath) THEN
    curRow := 0; curCol := 0; topLine := 0; undoTop := 0;
    hasBlkB := FALSE; hasBlkE := FALSE;
    projCurDoc := ProjIndexOf(filePath)
  END;
  Strings.IntToStr(replCount, tmp1); Strings.IntToStr(fileCount, tmp2);
  COPY("Replaced ", statusMsg); Strings.Append(tmp1, statusMsg);
  Strings.Append(" occurrence(s) in ", statusMsg); Strings.Append(tmp2, statusMsg);
  Strings.Append(" file(s)", statusMsg);
  needRedraw := TRUE
END ProjReplace;

PROCEDURE StartProjReplace;
(* ^PW *)
BEGIN
  IF projPath[0] = 0X THEN SetStatus("No open project — ^PN to create"); needRedraw := TRUE; RETURN END;
  StartInput("Replace across project — find", ActProjReplFind)
END StartProjReplace;

(* ── Per-document synopsis (^PI edit, ^PY toggle) ────────────────── *)

PROCEDURE SynopsisPath(docPath: ARRAY OF CHAR; VAR out: ARRAY OF CHAR);
BEGIN COPY(docPath, out); Strings.Append(".synopsis", out) END SynopsisPath;

PROCEDURE ReadSynopsis(docPath: ARRAY OF CHAR; VAR out: ARRAY OF CHAR);
VAR p: ARRAY 512 OF CHAR; f: Files.File; r: Files.Rider;
BEGIN
  out[0] := 0X;
  SynopsisPath(docPath, p);
  f := Files.Old(p);
  IF f # NIL THEN
    Files.Set(r, f, 0);
    Files.ReadLine(r, out);
    Files.Close(f)
  END
END ReadSynopsis;

PROCEDURE WriteSynopsis(docPath, text: ARRAY OF CHAR);
VAR p: ARRAY 512 OF CHAR; f: Files.File; r: Files.Rider;
BEGIN
  SynopsisPath(docPath, p);
  f := Files.New(p);
  IF f # NIL THEN
    Files.Set(r, f, 0);
    Files.WriteLine(r, text);
    Files.Register(f); Files.Close(f)
  END
END WriteSynopsis;

PROCEDURE EditSynopsis;
(* ^PI — edit a project doc's one-line synopsis (the binder-selected one
   if invoked from the binder, otherwise the currently-open document). *)
VAR existing: ARRAY 256 OF CHAR;
BEGIN
  IF mode = ModeBinder THEN
    IF (binderSel < 0) OR (binderSel >= projDocCount) THEN RETURN END;
    COPY(projDocs[binderSel], synopsisTarget);
    synopsisFromBinder := TRUE
  ELSE
    IF filePath[0] = 0X THEN SetStatus("Save this file first"); needRedraw := TRUE; RETURN END;
    COPY(filePath, synopsisTarget);
    synopsisFromBinder := FALSE
  END;
  ReadSynopsis(synopsisTarget, existing);
  StartInput("Synopsis", ActSynopsis);
  COPY(existing, inpValue); inpCursor := Strings.Length(inpValue)
END EditSynopsis;

PROCEDURE ToggleSynopsis;
(* ^PY *)
BEGIN
  showSynopsis := ~showSynopsis;
  IF showSynopsis THEN SetStatus("Binder synopses shown")
  ELSE SetStatus("Binder synopses hidden")
  END;
  needRedraw := TRUE
END ToggleSynopsis;

(* ── Doc role: manuscript vs. note (^PM) ──────────────────────────── *)

PROCEDURE ToggleDocNote;
(* ^PM — mark a project doc as a "note" so ^PK/^PT compile skip it
   (the binder-selected doc if invoked from the binder, otherwise the
   currently-open document). This is a whole-document flag, distinct
   from the ".."-prefixed comment *lines* ^QM/^QU navigate within a doc. *)
VAR idx: INTEGER;
BEGIN
  IF projPath[0] = 0X THEN SetStatus("No open project"); needRedraw := TRUE; RETURN END;
  IF mode = ModeBinder THEN idx := binderSel ELSE idx := ProjIndexOf(filePath) END;
  IF (idx < 0) OR (idx >= projDocCount) THEN
    SetStatus("Current file not in project"); needRedraw := TRUE; RETURN
  END;
  projIsNote[idx] := ~projIsNote[idx];
  SaveProjFile;
  IF projIsNote[idx] THEN SetStatus("Marked as note (excluded from compile)")
  ELSE SetStatus("Marked as manuscript (included in compile)")
  END;
  needRedraw := TRUE
END ToggleDocNote;

(* ── Annotation (^PC) ────────────────────────────────────────────── *)

PROCEDURE Annotate;
(* ^PC — insert a ".."-prefixed comment line above the cursor, using the
   same convention ^QM/^QU already navigate between. *)
BEGIN
  StartInput("Comment", ActAnnotate)
END Annotate;

(* ── Other-window helpers reachable from the binder (^PO, ^PV) ──── *)

PROCEDURE OpenNotes;
(* ^PO — open this document's free-form notes file in the other window
   (a longer scratch area, distinct from the one-line ^PI synopsis). *)
VAR notesPath: ARRAY 512 OF CHAR;
BEGIN
  IF filePath[0] = 0X THEN SetStatus("Save this file first"); needRedraw := TRUE; RETURN END;
  COPY(filePath, notesPath); Strings.Append(".notes", notesPath);
  IF LoadFileIntoSnap(notesPath, otherPane) THEN
    otherPaneOpen := TRUE; focusOther := FALSE;
    COPY("Notes: ", statusMsg); Strings.Append(notesPath, statusMsg)
  END;
  needRedraw := TRUE
END OpenNotes;

PROCEDURE OpenProjDocInOther;
(* ^PV — open the binder-selected document in the other window instead
   of replacing the active one. *)
BEGIN
  IF (binderSel < 0) OR (binderSel >= projDocCount) THEN RETURN END;
  IF LoadFileIntoSnap(projDocs[binderSel], otherPane) THEN
    otherPaneOpen := TRUE; focusOther := FALSE;
    mode := ModeNormal;
    COPY("Opened in other window: ", statusMsg); Strings.Append(otherPane.filePath, statusMsg)
  END;
  needRedraw := TRUE
END OpenProjDocInOther;

PROCEDURE HandlePrefixP(k: CHAR);
BEGIN
  prefix := PrefNone;
  CASE k OF
    'n', 'N': StartInput("New project name", ActProjNew)
  | 'p', 'P': StartInput("Open project (.ostarproj)", ActProjOpen)
  | 'a', 'A': ProjAdd
  | 'r', 'R': ProjRemove
  | 'e', 'E': ProjPrev
  | 'x', 'X': ProjNext
  | 'l', 'L': ProjList
  | 'k', 'K': CompileRTF
  | 'g', 'G': CompileEpub
  | 't', 'T': CompileClean
  | 's', 'S': ProjFind
  | 'b', 'B':
      IF mode = ModeBinder THEN
        mode := ModeNormal
      ELSE
        binderSel := projCurDoc;
        IF binderSel < 0 THEN binderSel := 0 END;
        binderScroll := 0;
        mode := ModeBinder
      END
  | 'i', 'I': EditSynopsis
  | 'y', 'Y': ToggleSynopsis
  | 'w', 'W': StartProjReplace
  | 'm', 'M': ToggleDocNote
  | 'c', 'C': Annotate
  | 'o', 'O': OpenNotes
  | 'v', 'V':
      IF mode = ModeBinder THEN OpenProjDocInOther
      ELSE SetStatus("^P V opens a binder-selected doc in the other window")
      END
  ELSE SetStatus("Unknown ^P command")
  END;
  needRedraw := TRUE
END HandlePrefixP;

PROCEDURE HandleNormalKey(k: CHAR);
VAR ctrl: BOOLEAN; base: CHAR;
BEGIN
  (* Map Ctrl+letter: control codes 1–26 map to ^A–^Z *)
  ctrl := (ORD(k) >= 1) & (ORD(k) <= 26) & (k # TUI.KTab) & (k # TUI.KEnter) & (k # TUI.KBackspace);
  IF ctrl THEN base := CHR(ORD(k) + ORD('a') - 1) ELSE base := k END;

  statusMsg[0] := 0X;  (* clear any previous status *)

  IF prefix = PrefK THEN HandlePrefixK(base); RETURN END;
  IF prefix = PrefQ THEN HandlePrefixQ(base); RETURN END;
  IF prefix = PrefO THEN HandlePrefixO(base); RETURN END;
  IF prefix = PrefP THEN HandlePrefixP(base); RETURN END;

  IF ctrl THEN
    CASE base OF
      'e': MoveUp        | 'x': MoveDown
    | 's': MoveLeft      | 'd': MoveRight
    | 'a': MoveWordLeft  | 'f': MoveWordRight
    | 'w': ScrollUp      | 'z': ScrollDown
    | 'r': PageUp        | 'c': PageDown
    | 'g': DelChar       | 'h': BackspaceChar
    | 't': DeleteWordRight
    | 'y': DeleteLine
    | 'n': InsertBlankLine
    | 'u': DoUndo
    | 'l': FindNext
    | 'v': overtype := ~overtype;
           IF overtype THEN SetStatus("Overtype") ELSE SetStatus("Insert") END
    | 'k': prefix := PrefK; IF helpLevel >= 1 THEN needRedraw := TRUE END
    | 'q': prefix := PrefQ; IF helpLevel >= 1 THEN needRedraw := TRUE END
    | 'o': prefix := PrefO; IF helpLevel >= 1 THEN needRedraw := TRUE END
    | 'p': prefix := PrefP; IF helpLevel >= 1 THEN needRedraw := TRUE END
    | 'b': (* ^B = reformat paragraph, stub *)
           SetStatus("^B paragraph reformat — not yet implemented")
    ELSE SetStatus("Unknown command")
    END
  ELSE
    (* Non-ctrl keys *)
    CASE k OF
      TUI.KUp:        MoveUp
    | TUI.KDown:      MoveDown
    | TUI.KLeft:      MoveLeft
    | TUI.KRight:     MoveRight
    | TUI.KPgUp:      PageUp
    | TUI.KPgDn:      PageDown
    | TUI.KHome:      MoveLineStart
    | TUI.KEnd:       MoveLineEnd
    | TUI.KCtrlLeft:  MoveWordLeft
    | TUI.KCtrlRight: MoveWordRight
    | TUI.KCtrlHome:  MoveDocStart
    | TUI.KCtrlEnd:   MoveDocEnd
    | TUI.KDel:       DelChar
    | TUI.KBackspace: BackspaceChar
    | TUI.KEnter:     BreakLine;  goalCol := -1
    | TUI.KTab: InsTab
    | TUI.KF1:        mode := ModePalette; palScroll := 0; needRedraw := TRUE
    | TUI.KEsc:       IF otherPaneOpen THEN CloseOtherWindow END
    ELSE
      IF (ORD(k) >= 32) & (ORD(k) < 127) THEN
        InsChar(k); goalCol := -1
      ELSIF ORD(k) >= 128 THEN
        (* High-byte keys: ignore unknown specials silently *)
      END
    END
  END
END HandleNormalKey;

PROCEDURE HandleMouse;
(* Translate a TUI mouse event into editor actions. *)
VAR sx, sy, btn: INTEGER;
    bufRow, segF, e, targetRow, targetCol: INTEGER;
BEGIN
  sx  := ev.mx;   (* 1-based screen column *)
  sy  := ev.my;   (* 1-based screen row    *)
  btn := ev.mb;

  IF btn = 64 THEN          (* wheel up *)
    ScrollUp; RETURN
  ELSIF btn = 65 THEN       (* wheel down *)
    ScrollDown; RETURN
  ELSIF btn # 0 THEN RETURN (* ignore middle, right, release, motion *)
  END;

  (* Left click: find document position from screen position *)
  IF sy >= TUI.Rows THEN RETURN END;  (* status bar — ignore *)
  DEC(sx, TextX0() - 1);  (* adjust for binder offset *)

  IF wrap THEN
    (* Walk visual rows from topLine until we reach screen row sy *)
    bufRow := topLine; segF := 0;
    WHILE sy > 1 DO
      e := SegEnd(bufRow, segF);
      IF e >= LineLen(bufRow) THEN INC(bufRow); segF := 0
      ELSE segF := SegNext(bufRow, segF)
      END;
      DEC(sy);
      IF bufRow >= numLines THEN bufRow := numLines - 1; segF := 0; sy := 0 END
    END;
    targetRow := bufRow;
    targetCol := ColAtCells(targetRow, segF, sx - 1);
  ELSE
    targetRow := topLine + (sy - 1);
    IF targetRow >= numLines THEN targetRow := numLines - 1 END;
    targetCol := ColAtCells(targetRow, leftCol, sx - 1);
  END;

  SavePrev;
  curRow := targetRow; curCol := targetCol;
  goalCol := -1;
  needRedraw := TRUE
END HandleMouse;

PROCEDURE HandleBinderKey(k: CHAR);
BEGIN
  IF prefix = PrefP THEN HandlePrefixP(k); RETURN END;
  IF (k = TUI.KUp) OR (k = CHR(5)) THEN   (* Up or ^E *)
    IF binderSel > 0 THEN DEC(binderSel) END
  ELSIF (k = TUI.KDown) OR (k = CHR(24)) THEN  (* Down or ^X *)
    IF binderSel < projDocCount - 1 THEN INC(binderSel) END
  ELSIF k = TUI.KEnter THEN
    IF (binderSel >= 0) & (binderSel < projDocCount) THEN
      OpenProjDoc(binderSel); mode := ModeNormal
    END
  ELSIF k = CHR(16) THEN  (* ^P: reach ^PI/^PM/^PV etc. from within the binder *)
    prefix := PrefP
  ELSIF (k = TUI.KEsc) OR (k = TUI.KTab) THEN
    mode := ModeNormal
  END;
  needRedraw := TRUE
END HandleBinderKey;

PROCEDURE HandleOutlineKey(k: CHAR);
VAR r, i: INTEGER;
BEGIN
  IF (k = TUI.KUp) OR (k = CHR(5)) THEN
    (* move to prev heading *)
    r := outlineSel - 1;
    WHILE (r >= 0) & (lines[r].s[0] # '#') DO DEC(r) END;
    IF r >= 0 THEN outlineSel := r END
  ELSIF (k = TUI.KDown) OR (k = CHR(24)) THEN
    (* move to next heading *)
    r := outlineSel + 1;
    WHILE (r < numLines) & (lines[r].s[0] # '#') DO INC(r) END;
    IF r < numLines THEN outlineSel := r END
  ELSIF k = TUI.KEnter THEN
    SavePrev; curRow := outlineSel; curCol := 0; goalCol := -1;
    mode := ModeNormal
  ELSIF (k = TUI.KEsc) OR (k = TUI.KF1) THEN
    mode := ModeNormal
  END;
  (* Adjust outlineScroll so outlineSel is visible — count heading ordinal *)
  i := 0; r := 0;
  WHILE r < outlineSel DO
    IF lines[r].s[0] = '#' THEN INC(i) END;
    INC(r)
  END;
  (* i is the ordinal of outlineSel; scroll so it's in the window *)
  IF i < outlineScroll THEN outlineScroll := i END;
  IF i >= outlineScroll + 20 THEN outlineScroll := i - 19 END;
  needRedraw := TRUE
END HandleOutlineKey;

PROCEDURE HandleRevisionsKey(k: CHAR);
VAR full, keepPath: ARRAY 512 OF CHAR;
BEGIN
  IF (k = TUI.KUp) OR (k = CHR(5)) THEN
    IF revSel > 0 THEN DEC(revSel) END
  ELSIF (k = TUI.KDown) OR (k = CHR(24)) THEN
    IF revSel < revCount - 1 THEN INC(revSel) END
  ELSIF k = TUI.KEnter THEN
    IF (revSel >= 0) & (revSel < revCount) THEN
      COPY(revDir, full);
      IF full[0] # 0X THEN Strings.Append("/", full) END;
      Strings.Append(revNames[revSel], full);
      COPY(filePath, keepPath);
      IF LoadFile(full) THEN
        COPY(keepPath, filePath);   (* restore content, but keep editing the real file *)
        dirty := TRUE;
        curRow := 0; curCol := 0; topLine := 0; undoTop := 0;
        hasBlkB := FALSE; hasBlkE := FALSE;
        COPY("Restored from ", statusMsg); Strings.Append(revNames[revSel], statusMsg);
        Strings.Append(" — ^KD to save", statusMsg)
      END;
      mode := ModeNormal
    END
  ELSIF k = TUI.KEsc THEN
    mode := ModeNormal
  END;
  needRedraw := TRUE
END HandleRevisionsKey;

PROCEDURE HandleKey(k: CHAR);
BEGIN
  CASE mode OF
    ModeNormal:  HandleNormalKey(k)
  | ModeSearch:
      IF (mode = ModeSearch) & inReplace THEN
        (* First pass: enter find string, then Enter triggers replace prompt *)
        IF k = TUI.KEnter THEN
          COPY(searchStr, replSearch);
          inReplace := FALSE;
          StartInput("Replace with", 0);  (* ActNone handled specially *)
          inpAction := 99 (* replace-step marker *)
        ELSE HandleSearchKey(k)
        END
      ELSE HandleSearchKey(k)
      END
  | ModeReplace: HandleReplaceStep(k)
  | ModeInput:
      IF inpAction = 99 THEN  (* completing replace *)
        HandleInputKey(k);
        IF (mode = ModeNormal) & (k = TUI.KEnter) THEN
          (* User confirmed the replace-with string *)
          COPY(inpValue, replWith);
          COPY(replSearch, searchStr);
          IF SearchForward(0, 0) THEN
            curRow := searchRow; curCol := searchCol;
            mode := ModeReplace
          ELSE SetStatus("Not found"); mode := ModeNormal
          END
        ELSIF (mode = ModeNormal) & (k = TUI.KEsc) THEN
          SetStatus("Replace cancelled")
        END
      ELSE HandleInputKey(k)
      END
  | ModeConfirm: HandleConfirmKey(k)
  | ModePalette: HandlePaletteKey(k)
  | ModeBinder:  HandleBinderKey(k)
  | ModeOutline: HandleOutlineKey(k)
  | ModeRevisions: HandleRevisionsKey(k)
  ELSE HandleNormalKey(k)
  END;
  needRedraw := TRUE
END HandleKey;

PROCEDURE HandleUTF8Key(lead: CHAR);
(* A UTF-8 multi-byte character's lead byte arrived as raw input. Read
   the rest of the sequence directly from the terminal (ReadUTF8Seq)
   and insert it as literal text if the current mode accepts typed
   text; otherwise the whole sequence is consumed and discarded. Either
   way this keeps its continuation bytes from ever being reinterpreted
   as a special key (see ReadUTF8Seq). *)
VAR seq: ARRAY 5 OF CHAR; n: INTEGER;
BEGIN
  n := ReadUTF8Seq(lead, seq);
  IF prefix # PrefNone THEN
    IF prefix = PrefK THEN HandlePrefixK(lead)
    ELSIF prefix = PrefQ THEN HandlePrefixQ(lead)
    ELSIF prefix = PrefO THEN HandlePrefixO(lead)
    ELSIF prefix = PrefP THEN HandlePrefixP(lead)
    END
  ELSIF mode = ModeNormal THEN
    InsUTF8(seq, n)
  ELSIF mode = ModeSearch THEN
    AppendUTF8(searchStr, 255, seq, n);
    IF SearchForward(0, 0) THEN curRow := searchRow; curCol := searchCol END
  ELSIF mode = ModeInput THEN
    AppendUTF8(inpValue, 511, seq, n);
    INC(inpCursor, n)
  END;
  needRedraw := TRUE
END HandleUTF8Key;

(* ── Main Program ────────────────────────────────────────────────── *)

BEGIN
  (* Initialise state *)
  NEW(lines[0]); lines[0].s[0] := 0X; numLines := 1;
  filePath[0] := 0X;
  dirty := FALSE;
  curRow := 0; curCol := 0; goalCol := -1;
  topLine := 0; leftCol := 0;
  hasBlkB := FALSE; hasBlkE := FALSE;
  hasPrev := FALSE; prevRow := 0; prevCol := 0;
  killHead := 0; killCount := 0; putIndex := 0;
  undoTop := 0;
  mode := ModeNormal; prefix := PrefNone;
  theme := ThWP;
  helpLevel := 1;
  wrap := TRUE; wrapMargin := 72;
  overtype := FALSE; typewriter := FALSE;
  running := TRUE; showSplash := TRUE;
  statusMsg[0] := 0X;
  searchStr[0] := 0X; searchLen := 0; caseSens := FALSE;
  inReplace := FALSE;
  needRedraw := TRUE;
  palScroll := 0;
  outlineScroll := 0; outlineSel := 0;
  focusMode := FALSE; focusParaS := 0; focusParaE := 0;
  styleEnabled := FALSE; styleCurKind := StNone;
  projPath[0] := 0X; projDocCount := 0; projCurDoc := -1;
  binderSel := 0; binderScroll := 0; showSynopsis := FALSE;
  synopsisFromBinder := FALSE;
  otherPaneOpen := FALSE; focusOther := FALSE;
  revealCodes := FALSE;
  hasPrevBlk := FALSE;
  revCount := 0; revSel := 0; revScroll := 0;
  spellEnabled := FALSE;
  Dict.Init(misspelled);
  Dict.Init(personalDict);

  (* Personal dictionary: ~/.config/ostar/personal.txt *)
  Env.Get("HOME", personalPath);
  IF personalPath[0] # 0X THEN
    Strings.Append("/.config/ostar/personal.txt", personalPath)
  END;
  LoadPersonalDict;

  (* Open file from command line if provided *)
  IF Args.Count() >= 1 THEN
    Args.Get(1, filePath);
    IF ~LoadFile(filePath) THEN filePath[0] := 0X END
  END;

  Markdown.SetSink(MdSink);

  TUI.Init;

  (* Splash *)
  DrawSplash;
  TUI.WaitEvent(ev);
  showSplash := FALSE;

  (* Main event loop *)
  LOOP
    IF needRedraw THEN
      DrawAll;
      needRedraw := FALSE
    END;
    TUI.WaitEvent(ev);
    IF ev.kind = TUI.EvResize THEN
      TUI.InvalidateFront;
      needRedraw := TRUE
    ELSIF ev.kind = TUI.EvKey THEN
      IF UTF8SeqLen(ev.key) > 1 THEN HandleUTF8Key(ev.key)
      ELSE HandleKey(ev.key)
      END
    ELSIF ev.kind = TUI.EvMouse THEN
      HandleMouse
    END;
    IF ~running THEN EXIT END
  END;

  TUI.Done
END OStar.


