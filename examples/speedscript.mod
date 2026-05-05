MODULE SpeedScript;

IMPORT Terminal, Files, Out, Strings, Args, OS;

CONST
  MaxText = 65536*3;
  BufSize = 4096;
  MaxName = 256;
  RetChar  = 1FX;   (* hard paragraph break, displayed as < *)
  MaxUndo  = 32;
  UndoIns  = 0;
  UndoDel  = 1;

  HLANG_NONE  = 0; HLANG_C   = 1; HLANG_CPP = 2; HLANG_OBN  = 3;
  HLANG_R     = 4; HLANG_RUBY = 5; HLANG_SWIFT = 6;
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
  KEY_CTRL_Q = 17;
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

  (* Mouse buttons (Terminal.MouseBtn values) *)
  MB_LEFT    = 0;
  MB_MIDDLE  = 1;
  MB_RIGHT   = 2;
  MB_RELEASE = 3;
  MB_WLUP    = 64;   (* wheel up   = scroll up   *)
  MB_WLDOWN  = 65;   (* wheel down = scroll down *)

  (* Selection state *)
  SEL_NONE   = 0;
  SEL_ACTIVE = 1;   (* mouse button held, dragging *)
  SEL_DONE   = 2;   (* button released, region fixed *)

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

  (* ── Mouse selection ── *)
  selState:  INTEGER;          (* SEL_NONE / SEL_ACTIVE / SEL_DONE *)
  selAnchor: INTEGER;          (* buffer offset where drag began *)
  selEnd:    INTEGER;          (* buffer offset where drag ended *)

(* ════════════════════════════════════════════════════════════════════
   UTF-8 helpers
   The text buffer stores raw UTF-8 bytes.  All cursor arithmetic
   must step by codepoint rather than byte.
   ════════════════════════════════════════════════════════════════════ *)

(* Return the byte-length of the UTF-8 sequence starting at text[i].
   Sequences are 1–4 bytes.  Lone continuation bytes (10xxxxxx) and
   invalid lead bytes are treated as single bytes so the editor can
   still display and delete them. *)
PROCEDURE UTF8Len(i: INTEGER): INTEGER;
VAR b: INTEGER;
BEGIN
  b := ORD(text[i]);
  IF b < 80H THEN RETURN 1          (* 0xxxxxxx  ASCII *)
  ELSIF b < 0C0H THEN RETURN 1      (* 10xxxxxx  stray continuation *)
  ELSIF b < 0E0H THEN RETURN 2      (* 110xxxxx *)
  ELSIF b < 0F0H THEN RETURN 3      (* 1110xxxx *)
  ELSE RETURN 4                     (* 11110xxx *)
  END
END UTF8Len;

(* Byte-length of the sequence that ends just before text[i];
   i.e. step backward over one codepoint. *)
PROCEDURE UTF8LenBack(i: INTEGER): INTEGER;
VAR j, b: INTEGER;
BEGIN
  IF i <= 0 THEN RETURN 0 END;
  j := i - 1;
  (* skip continuation bytes *)
  WHILE (j > 0) & (ORD(text[j]) >= 80H) & (ORD(text[j]) < 0C0H) DO
    DEC(j)
  END;
  b := ORD(text[j]);
  IF b < 80H   THEN RETURN 1    (* ASCII *)
  ELSIF b < 0C0H THEN RETURN 1  (* stray continuation — treat as 1 *)
  ELSE RETURN i - j             (* normal multi-byte *)
  END
END UTF8LenBack;

(* Advance cursor by one codepoint to the right. *)
PROCEDURE CPRight(pos: INTEGER): INTEGER;
BEGIN
  IF pos >= lastLine THEN RETURN lastLine END;
  IF text[pos] = RetChar THEN RETURN pos + 1 END;
  RETURN pos + UTF8Len(pos)
END CPRight;

(* Step cursor by one codepoint to the left. *)
PROCEDURE CPLeft(pos: INTEGER): INTEGER;
BEGIN
  IF pos <= 0 THEN RETURN 0 END;
  IF (pos > 0) & (text[pos - 1] = RetChar) THEN RETURN pos - 1 END;
  RETURN pos - UTF8LenBack(pos)
END CPLeft;

(* Write one UTF-8 codepoint (1–4 bytes) from the buffer at position i
   to stdout.  Returns the number of bytes written. *)
PROCEDURE EmitCP(i: INTEGER): INTEGER;
VAR n, j: INTEGER;
BEGIN
  IF text[i] = RetChar THEN RETURN 1 END;   (* caller renders as '<' *)
  n := UTF8Len(i);
  FOR j := 0 TO n - 1 DO Out.Char(text[i + j]) END;
  RETURN n
END EmitCP;

(* Column width of the codepoint at text[i] for cursor-position math.
   We approximate CJK wide chars (U+1100 and above in common ranges)
   as width 2; everything else as 1.  This requires decoding the
   scalar value from the UTF-8 bytes. *)
PROCEDURE CPWidth(i: INTEGER): INTEGER;
VAR b0, b1, b2, cp: INTEGER;
BEGIN
  IF text[i] = RetChar THEN RETURN 1 END;
  b0 := ORD(text[i]);
  IF b0 < 80H THEN RETURN 1 END;
  IF b0 < 0E0H THEN
    (* 2-byte: 110xxxxx 10xxxxxx *)
    IF i + 1 >= lastLine THEN RETURN 1 END;
    b1 := ORD(text[i+1]);
    cp := LSL(b0 MOD 20H, 6) + (b1 MOD 40H);
    (* U+0080..U+07FF — almost all are width-1 *)
    RETURN 1
  ELSIF b0 < 0F0H THEN
    (* 3-byte: 1110xxxx 10xxxxxx 10xxxxxx *)
    IF i + 2 >= lastLine THEN RETURN 1 END;
    b1 := ORD(text[i+1]); b2 := ORD(text[i+2]);
    cp := LSL(b0 MOD 10H, 12) + LSL(b1 MOD 40H, 6) + (b2 MOD 40H);
    (* CJK Unified (4E00-9FFF), Hangul (AC00-D7AF),
       Fullwidth (FF01-FF60), CJK Compatibility (F900-FAFF),
       CJK Extension A (3400-4DBF), Hiragana/Katakana (3040-30FF) *)
    IF  (cp >= 01100H) & (cp <= 0115FH)  THEN RETURN 2 END;
    IF  (cp >= 02E80H) & (cp <= 0A4CFH)  THEN RETURN 2 END;
    IF  (cp >= 0AC00H) & (cp <= 0D7AFH)  THEN RETURN 2 END;
    IF  (cp >= 0F900H) & (cp <= 0FAFFH)  THEN RETURN 2 END;
    IF  (cp >= 0FE10H) & (cp <= 0FE19H)  THEN RETURN 2 END;
    IF  (cp >= 0FE30H) & (cp <= 0FE6FH)  THEN RETURN 2 END;
    IF  (cp >= 0FF00H) & (cp <= 0FF60H)  THEN RETURN 2 END;
    IF  (cp >= 0FFE0H) & (cp <= 0FFE6H)  THEN RETURN 2 END;
    RETURN 1
  END;
  RETURN 1   (* 4-byte sequences: treat as width-1 for now *)
END CPWidth;

(* ════════════════════════════════════════════════════════════════════
   Buffer helpers
   ════════════════════════════════════════════════════════════════════ *)

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
  (* For Unicode text we keep ASCII word-char semantics for word ops,
     but also treat any byte >= 0C0H (UTF-8 lead byte) as word-start. *)
  IF (ch # " ") & (ch # RetChar) THEN
    IF (ORD(ch) >= 33) & (ORD(ch) < 127) THEN RETURN TRUE END;
    IF ORD(ch) >= 0C0H THEN RETURN TRUE END   (* UTF-8 lead byte *)
  END;
  RETURN FALSE
END IsWord;

(* ════════════════════════════════════════════════════════════════════
   Undo
   ════════════════════════════════════════════════════════════════════ *)

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

(* ════════════════════════════════════════════════════════════════════
   Visual line helpers  (now codepoint-aware via CPWidth)
   ════════════════════════════════════════════════════════════════════ *)

(* Return the visual column width of the character/codepoint at
   buffer position i (1 for most things, 2 for wide CJK, 1 for RetChar). *)
PROCEDURE CellWidth(i: INTEGER): INTEGER;
BEGIN
  IF text[i] = RetChar THEN RETURN 1 END;
  RETURN CPWidth(i)
END CellWidth;

(* Step forward by one rendered cell column from buffer position i.
   Returns the new buffer position after the codepoint at i. *)
PROCEDURE StepFwd(i: INTEGER): INTEGER;
BEGIN
  IF text[i] = RetChar THEN RETURN i + 1 END;
  RETURN i + UTF8Len(i)
END StepFwd;

PROCEDURE LineStartFrom(scanFrom, pos: INTEGER): INTEGER;
VAR i, x, w, ls: INTEGER;
BEGIN
  w := Terminal.Cols();
  i := scanFrom; x := 1; ls := scanFrom;
  WHILE i < pos DO
    IF x > w THEN ls := i; x := 1
    ELSIF text[i] = RetChar THEN ls := i + 1; INC(i); x := 1
    ELSE
      INC(x, CellWidth(i));
      i := StepFwd(i)
    END
  END;
  IF x > w THEN ls := pos END;
  RETURN ls
END LineStartFrom;

PROCEDURE NextVisLine(lineStart: INTEGER): INTEGER;
VAR i, x, w: INTEGER;
BEGIN
  w := Terminal.Cols();
  i := lineStart; x := 1;
  WHILE i < lastLine DO
    IF x > w THEN RETURN i
    ELSIF text[i] = RetChar THEN RETURN i + 1
    ELSE
      INC(x, CellWidth(i));
      i := StepFwd(i)
    END
  END;
  RETURN lastLine
END NextVisLine;

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
    ELSE
      INC(x, CellWidth(i));
      i := StepFwd(i)
    END
  END;
  IF x > w THEN prev := cur; cur := pos END;
  IF cur = pos THEN RETURN prev END;
  RETURN cur
END PrevVisLine;

PROCEDURE AdvanceOnLine(lineStart, col: INTEGER): INTEGER;
VAR i, x, w: INTEGER;
BEGIN
  w := Terminal.Cols();
  i := lineStart; x := 1;
  WHILE i < lastLine DO
    IF x = col THEN RETURN i END;
    IF (x >= w) OR (text[i] = RetChar) THEN RETURN i END;
    INC(x, CellWidth(i));
    i := StepFwd(i)
  END;
  RETURN i
END AdvanceOnLine;

PROCEDURE ComputeVis(pos: INTEGER; VAR vx, vy: INTEGER);
VAR i, x, y, w: INTEGER;
BEGIN
  w := Terminal.Cols(); x := 1; y := 2; i := topLin;
  WHILE i < pos DO
    IF x > w THEN x := 1; INC(y)
    ELSIF text[i] = RetChar THEN x := 1; INC(y); INC(i)
    ELSE
      INC(x, CellWidth(i));
      i := StepFwd(i)
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

(* ════════════════════════════════════════════════════════════════════
   Selection helpers
   ════════════════════════════════════════════════════════════════════ *)

PROCEDURE SelLo(): INTEGER;
BEGIN
  IF selAnchor < selEnd THEN RETURN selAnchor ELSE RETURN selEnd END
END SelLo;

PROCEDURE SelHi(): INTEGER;
BEGIN
  IF selAnchor > selEnd THEN RETURN selAnchor ELSE RETURN selEnd END
END SelHi;

PROCEDURE ClearSel;
BEGIN selState := SEL_NONE; selAnchor := 0; selEnd := 0 END ClearSel;

(* Map terminal column/row (1-based) to the nearest buffer position.
   Used for click-to-cursor and mouse-drag selection. *)
PROCEDURE ScreenToPos(mx, my: INTEGER): INTEGER;
VAR i, x, y, w, rows, best: INTEGER;
BEGIN
  w := Terminal.Cols(); rows := Terminal.Rows() - 1;
  x := 1; y := 2; i := topLin; best := topLin;
  WHILE (i <= lastLine) & (y <= rows) DO
    IF x > w THEN x := 1; INC(y) END;
    IF (y = my) & (x <= mx) THEN best := i END;
    IF i = lastLine THEN
      i := lastLine + 1
    ELSIF text[i] = RetChar THEN
      IF y = my THEN best := i END;
      x := 1; INC(y); INC(i)
    ELSE
      INC(x, CellWidth(i));
      i := StepFwd(i)
    END
  END;
  RETURN best
END ScreenToPos;

(* Copy the selected region into cutBuf.  Does NOT delete it. *)
PROCEDURE YankSel;
VAR lo, hi, n, i: INTEGER;
BEGIN
  lo := SelLo(); hi := SelHi();
  n := hi - lo;
  IF n <= 0 THEN RETURN END;
  IF n > BufSize THEN n := BufSize END;
  cutLen := n;
  FOR i := 0 TO n - 1 DO cutBuf[i] := text[lo + i] END
END YankSel;

(* Delete the selected region and leave cursor at lo. *)
PROCEDURE DeleteSel;
VAR lo, hi, n: INTEGER;
BEGIN
  lo := SelLo(); hi := SelHi();
  n := hi - lo;
  IF n <= 0 THEN ClearSel; RETURN END;
  RecordDel(lo, n, text, lo);
  MoveText(hi, lo, lastLine - hi);
  DEC(lastLine, n);
  curr := lo;
  modified := TRUE;
  ClearSel
END DeleteSel;

(* ════════════════════════════════════════════════════════════════════
   Mouse handler  (left-click/drag, wheel scroll)
   ════════════════════════════════════════════════════════════════════ *)

PROCEDURE HandleMouse;
VAR mx, my, mb, pos, i: INTEGER;
BEGIN
  mx := Terminal.MouseX();
  my := Terminal.MouseY();
  mb := Terminal.MouseBtn();

  (* ── Wheel scroll ── *)
  IF mb = MB_WLUP THEN
    (* scroll up 3 visual lines *)
    FOR i := 1 TO 3 DO
      IF topLin > 0 THEN topLin := PrevVisLine(topLin) END
    END;
    RETURN
  END;
  IF mb = MB_WLDOWN THEN
    (* scroll down 3 visual lines *)
    FOR i := 1 TO 3 DO
      topLin := NextVisLine(topLin)
    END;
    RETURN
  END;

  (* ── Left-button press: start selection drag ── *)
  IF mb = MB_LEFT THEN
    pos := ScreenToPos(mx, my);
    curr := pos;
    selAnchor := pos;
    selEnd    := pos;
    selState  := SEL_ACTIVE;
    RETURN
  END;

  (* ── Drag (motion events also arrive as MB_LEFT while held; the
        Terminal module sends the button that was pressed, not a
        separate "motion" code, so we treat any in-range event while
        SEL_ACTIVE is set as a drag update) ── *)
  IF (mb = MB_LEFT) & (selState = SEL_ACTIVE) THEN
    pos := ScreenToPos(mx, my);
    selEnd := pos;
    curr   := pos;
    RETURN
  END;

  (* ── Release: finalise selection ── *)
  IF mb = MB_RELEASE THEN
    IF selState = SEL_ACTIVE THEN
      pos    := ScreenToPos(mx, my);
      selEnd := pos;
      IF selAnchor = selEnd THEN
        ClearSel       (* simple click with no drag — no selection *)
      ELSE
        selState := SEL_DONE
      END
    END;
    RETURN
  END;

  (* ── Right-click: paste selection (X11-style middle-click paste) ── *)
  IF mb = MB_RIGHT THEN
    IF selState = SEL_DONE THEN
      YankSel;
      DeleteSel;
    END;
    (* fall through to paste below, but we need curr set already *)
    pos  := ScreenToPos(mx, my);
    curr := pos;
    IF cutLen > 0 THEN
      (* inline paste — reuse Paste logic *)
      IF lastLine + cutLen < MaxText THEN
        MoveText(curr, curr + cutLen, lastLine - curr);
        FOR j := 0 TO cutLen - 1 DO text[curr + j] := cutBuf[j] END;
        INC(lastLine, cutLen);
        INC(curr, cutLen);
        RecordIns(curr - cutLen, cutLen);
        modified := TRUE
      END
    END;
    ClearSel;
    RETURN
  END;

  (* ── Middle-click: paste cutBuf at click position ── *)
  IF mb = MB_MIDDLE THEN
    pos  := ScreenToPos(mx, my);
    curr := pos;
    IF cutLen > 0 THEN
      IF lastLine + cutLen < MaxText THEN
        MoveText(curr, curr + cutLen, lastLine - curr);
        FOR j := 0 TO cutLen - 1 DO text[curr + j] := cutBuf[j] END;
        INC(lastLine, cutLen);
        INC(curr, cutLen);
        RecordIns(curr - cutLen, cutLen);
        modified := TRUE
      END
    END;
    ClearSel;
    RETURN
  END
END HandleMouse;

(* ════════════════════════════════════════════════════════════════════
   Syntax highlighting  (unchanged logic, just noting UTF-8 bytes
   flow through the byte array transparently — highlights apply to
   byte indices so multi-byte sequences all share state HNormal unless
   they happen to start a keyword, which won't happen for non-ASCII
   text in C/Oberon etc.)
   ════════════════════════════════════════════════════════════════════ *)

PROCEDURE DetectLang;
BEGIN
  IF    Strings.EndsWith(fname, ".c")     THEN lang := HLANG_C
  ELSIF Strings.EndsWith(fname, ".cpp")   THEN lang := HLANG_CPP
  ELSIF Strings.EndsWith(fname, ".mod")   THEN lang := HLANG_OBN
  ELSIF Strings.EndsWith(fname, ".r")     THEN lang := HLANG_R
  ELSIF Strings.EndsWith(fname, ".R")     THEN lang := HLANG_R
  ELSIF Strings.EndsWith(fname, ".rb")    THEN lang := HLANG_RUBY
  ELSIF Strings.EndsWith(fname, ".swift") THEN lang := HLANG_SWIFT
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
  IF lang = HLANG_R THEN
    COPY(" if else for while repeat break next return function ", kw);
    IF InList(word, kw) THEN RETURN TRUE END;
    COPY(" TRUE FALSE NULL NA Inf NaN NA_integer_ NA_real_ ", kw);
    IF InList(word, kw) THEN RETURN TRUE END;
    COPY(" NA_complex_ NA_character_ LETTERS letters month.abb ", kw);
    IF InList(word, kw) THEN RETURN TRUE END;
    COPY(" library require source print cat paste paste0 sprintf ", kw);
    IF InList(word, kw) THEN RETURN TRUE END;
    COPY(" c list vector matrix array data.frame read.csv write.csv ", kw);
    IF InList(word, kw) THEN RETURN TRUE END;
    COPY(" lapply sapply vapply tapply mapply apply which length ", kw);
    IF InList(word, kw) THEN RETURN TRUE END;
    COPY(" nrow ncol dim str summary head tail subset merge order ", kw);
    IF InList(word, kw) THEN RETURN TRUE END
  END;
  IF lang = HLANG_RUBY THEN
    COPY(" BEGIN END alias and begin break case class def defined ", kw);
    IF InList(word, kw) THEN RETURN TRUE END;
    COPY(" do else elsif end ensure false for if in module next nil ", kw);
    IF InList(word, kw) THEN RETURN TRUE END;
    COPY(" not or redo rescue retry return self super then true undef ", kw);
    IF InList(word, kw) THEN RETURN TRUE END;
    COPY(" unless until when while yield __FILE__ __LINE__ __method__ ", kw);
    IF InList(word, kw) THEN RETURN TRUE END;
    COPY(" attr_reader attr_writer attr_accessor include extend require ", kw);
    IF InList(word, kw) THEN RETURN TRUE END;
    COPY(" raise puts print p lambda proc frozen_string_literal ", kw);
    IF InList(word, kw) THEN RETURN TRUE END
  END;
  IF lang = HLANG_SWIFT THEN
    COPY(" associatedtype class deinit enum extension fileprivate func ", kw);
    IF InList(word, kw) THEN RETURN TRUE END;
    COPY(" import init inout internal let open operator private protocol ", kw);
    IF InList(word, kw) THEN RETURN TRUE END;
    COPY(" public rethrows static struct subscript typealias var break ", kw);
    IF InList(word, kw) THEN RETURN TRUE END;
    COPY(" case continue default defer do else fallthrough for guard if ", kw);
    IF InList(word, kw) THEN RETURN TRUE END;
    COPY(" in repeat return throw switch where while as catch false is ", kw);
    IF InList(word, kw) THEN RETURN TRUE END;
    COPY(" nil super self Self true try throws async await actor ", kw);
    IF InList(word, kw) THEN RETURN TRUE END;
    COPY(" Any AnyObject Bool Int Float Double String Character Optional ", kw);
    IF InList(word, kw) THEN RETURN TRUE END;
    COPY(" Array Dictionary Set Void Never UInt UInt8 Int8 Int32 Int64 ", kw);
    IF InList(word, kw) THEN RETURN TRUE END;
    COPY(" override final required convenience weak unowned mutating ", kw);
    IF InList(word, kw) THEN RETURN TRUE END;
    COPY(" nonmutating dynamic lazy some @escaping @objc @IBOutlet ", kw);
    IF InList(word, kw) THEN RETURN TRUE END
  END;
  RETURN FALSE
END IsKW;

PROCEDURE Highlight;
VAR
  i, state, wStart, wlen, j: INTEGER;
  atLineStart: BOOLEAN;
  word: ARRAY 64 OF CHAR;

  PROCEDURE AtWord(i: INTEGER; kw: ARRAY OF CHAR): BOOLEAN;
  VAR klen, jj: INTEGER;
  BEGIN
    klen := Strings.Length(kw);
    IF i + klen > lastLine THEN RETURN FALSE END;
    FOR jj := 0 TO klen - 1 DO
      IF text[i + jj] # kw[jj] THEN RETURN FALSE END
    END;
    IF (i + klen < lastLine) & IsIdChar(text[i + klen]) THEN RETURN FALSE END;
    RETURN TRUE
  END AtWord;

BEGIN
  FOR i := 0 TO lastLine - 1 DO hlColor[i] := HNormal END;
  IF lang = HLANG_NONE THEN RETURN END;

  i := 0; state := 0; atLineStart := TRUE;

  WHILE i < lastLine DO
    IF state = 0 THEN
      IF text[i] = RetChar THEN
        atLineStart := TRUE; INC(i)
      ELSIF ((lang = HLANG_C) OR (lang = HLANG_CPP) OR (lang = HLANG_SWIFT)) &
            (text[i] = "/") & (i+1 < lastLine) & (text[i+1] = "/") THEN
        hlColor[i] := HComment; hlColor[i+1] := HComment; INC(i, 2); state := 1
      ELSIF ((lang = HLANG_C) OR (lang = HLANG_CPP) OR (lang = HLANG_SWIFT)) &
            (text[i] = "/") & (i+1 < lastLine) & (text[i+1] = "*") THEN
        hlColor[i] := HComment; hlColor[i+1] := HComment; INC(i, 2); state := 2
      ELSIF (lang = HLANG_OBN) &
            (text[i] = "(") & (i+1 < lastLine) & (text[i+1] = "*") THEN
        hlColor[i] := HComment; hlColor[i+1] := HComment; INC(i, 2); state := 2
      ELSIF ((lang = HLANG_C) OR (lang = HLANG_CPP)) &
            (text[i] = "#") & atLineStart THEN
        hlColor[i] := HPrepro; INC(i); state := 5; atLineStart := FALSE
      ELSIF (lang = HLANG_R) & (text[i] = "#") THEN
        hlColor[i] := HComment; INC(i); state := 1
      ELSIF (lang = HLANG_RUBY) & (text[i] = "#") THEN
        hlColor[i] := HComment; INC(i); state := 1
      ELSIF (lang = HLANG_RUBY) & atLineStart & AtWord(i, "=begin") THEN
        j := i;
        WHILE j < i + 6 DO hlColor[j] := HComment; INC(j) END;
        INC(i, 6); state := 6
      ELSIF text[i] = CHR(34) THEN
        hlColor[i] := HString; INC(i); state := 3; atLineStart := FALSE
      ELSIF (lang # HLANG_SWIFT) & (text[i] = "'") THEN
        hlColor[i] := HString; INC(i); state := 4; atLineStart := FALSE
      ELSIF ((lang = HLANG_R) OR (lang = HLANG_RUBY)) & (text[i] = "`") THEN
        hlColor[i] := HString; INC(i); state := 7; atLineStart := FALSE
      ELSIF (text[i] >= "0") & (text[i] <= "9") THEN
        WHILE (i < lastLine) &
              (IsIdChar(text[i]) OR (text[i] = ".") OR (text[i] = "_")) DO
          hlColor[i] := HNumber; INC(i)
        END;
        atLineStart := FALSE
      ELSIF ((text[i] >= "a") & (text[i] <= "z")) OR
            ((text[i] >= "A") & (text[i] <= "Z")) OR
            (text[i] = "_") OR
            ((lang = HLANG_R) & (text[i] = ".")) THEN
        wStart := i;
        WHILE (i < lastLine) &
              (IsIdChar(text[i]) OR ((lang = HLANG_R) & (text[i] = "."))) DO
          INC(i)
        END;
        wlen := i - wStart;
        IF wlen > 63 THEN wlen := 63 END;
        FOR j := 0 TO wlen - 1 DO word[j] := text[wStart + j] END;
        word[wlen] := 0X;
        IF IsKW(word) THEN
          FOR j := wStart TO wStart + wlen - 1 DO hlColor[j] := HKeyword END
        END;
        atLineStart := FALSE
      ELSIF (lang = HLANG_RUBY) & (text[i] = ":") &
            (i+1 < lastLine) & IsIdChar(text[i+1]) THEN
        hlColor[i] := HString; INC(i);
        WHILE (i < lastLine) & IsIdChar(text[i]) DO
          hlColor[i] := HString; INC(i)
        END;
        atLineStart := FALSE
      ELSIF (lang = HLANG_SWIFT) & (text[i] = "@") &
            (i+1 < lastLine) & IsIdChar(text[i+1]) THEN
        hlColor[i] := HPrepro; INC(i);
        WHILE (i < lastLine) & IsIdChar(text[i]) DO
          hlColor[i] := HPrepro; INC(i)
        END;
        atLineStart := FALSE
      ELSE
        (* Skip over full UTF-8 codepoints in the default case so we
           don't accidentally misparse multi-byte sequences. *)
        IF text[i] # " " THEN atLineStart := FALSE END;
        i := StepFwd(i)
      END
    ELSIF state = 1 THEN
      IF text[i] = RetChar THEN state := 0; atLineStart := TRUE; INC(i)
      ELSE hlColor[i] := HComment; INC(i)
      END
    ELSIF state = 2 THEN
      hlColor[i] := HComment;
      IF (lang = HLANG_OBN) &
         (text[i] = "*") & (i+1 < lastLine) & (text[i+1] = ")") THEN
        hlColor[i+1] := HComment; INC(i, 2); state := 0
      ELSIF ((lang = HLANG_C) OR (lang = HLANG_CPP) OR (lang = HLANG_SWIFT)) &
            (text[i] = "*") & (i+1 < lastLine) & (text[i+1] = "/") THEN
        hlColor[i+1] := HComment; INC(i, 2); state := 0
      ELSE
        IF text[i] = RetChar THEN atLineStart := TRUE END;
        INC(i)
      END
    ELSIF state = 3 THEN
      hlColor[i] := HString;
      IF (lang # HLANG_OBN) & (text[i] = CHR(92)) THEN
        IF i+1 < lastLine THEN hlColor[i+1] := HString; INC(i, 2)
        ELSE INC(i)
        END
      ELSIF (text[i] = CHR(34)) OR (text[i] = RetChar) THEN
        INC(i); state := 0
      ELSE INC(i)
      END
    ELSIF state = 4 THEN
      hlColor[i] := HString;
      IF ((lang = HLANG_RUBY) OR (lang = HLANG_R)) & (text[i] = CHR(92)) THEN
        IF i+1 < lastLine THEN hlColor[i+1] := HString; INC(i, 2)
        ELSE INC(i)
        END
      ELSIF (text[i] = "'") OR (text[i] = RetChar) THEN
        INC(i); state := 0
      ELSE INC(i)
      END
    ELSIF state = 5 THEN
      IF text[i] = RetChar THEN state := 0; atLineStart := TRUE; INC(i)
      ELSE hlColor[i] := HPrepro; INC(i)
      END
    ELSIF state = 6 THEN
      hlColor[i] := HComment;
      IF atLineStart & AtWord(i, "=end") THEN
        j := i;
        WHILE (j < lastLine) & (text[j] # RetChar) DO
          hlColor[j] := HComment; INC(j)
        END;
        i := j; state := 0
      ELSE
        IF text[i] = RetChar THEN atLineStart := TRUE
        ELSE atLineStart := FALSE
        END;
        INC(i)
      END
    ELSIF state = 7 THEN
      hlColor[i] := HString;
      IF (text[i] = "`") OR (text[i] = RetChar) THEN INC(i); state := 0
      ELSE INC(i)
      END
    END
  END
END Highlight;

(* ════════════════════════════════════════════════════════════════════
   Color output helpers
   ════════════════════════════════════════════════════════════════════ *)

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

(* Emit ANSI reverse-video for selected text. *)
PROCEDURE SetReverse;
BEGIN Out.Char(CHR(27)); Out.String("[7m") END SetReverse;

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

(* ════════════════════════════════════════════════════════════════════
   Display / Refresh
   ════════════════════════════════════════════════════════════════════ *)

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
  IF selState = SEL_DONE THEN
    Strings.Append(" [SEL ", s);
    Strings.IntToStr(SelHi() - SelLo(), t); Strings.Append(t, s);
    Strings.Append("B]", s)
  END;
  ShowStatus(s)
END DrawStatus;

PROCEDURE Refresh;
VAR
  i, x, y, w, rows, cpBytes: INTEGER;
  inSel: BOOLEAN;
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

    (* Determine selection highlight for this position *)
    inSel := (selState = SEL_DONE) & (i >= SelLo()) & (i < SelHi());

    IF i = lastLine THEN
      i := lastLine + 1
    ELSIF y <= rows THEN
      Terminal.Goto(x, y);
      IF text[i] = RetChar THEN
        IF inSel THEN SetReverse; hlLast := -1 END;
        FGColor(8); Out.Char("<"); Terminal.Reset; hlLast := -1;
        x := 1; INC(y); INC(i)
      ELSE
        IF inSel THEN
          Terminal.Reset; SetReverse; hlLast := -1;
          cpBytes := EmitCP(i);
          INC(x, CellWidth(i));
          INC(i, cpBytes)
        ELSE
          SetHL(hlColor[i]);
          cpBytes := EmitCP(i);
          INC(x, CellWidth(i));
          INC(i, cpBytes)
        END
      END
    ELSE
      INC(i)
    END
  END;
  IF lang # HLANG_NONE THEN Terminal.Reset END;
  Terminal.Goto(cx, cy);
  Terminal.ShowCursor
END Refresh;

(* ════════════════════════════════════════════════════════════════════
   Status-line prompt and string input
   ════════════════════════════════════════════════════════════════════ *)

PROCEDURE Prompt(msg: ARRAY OF CHAR);
BEGIN ShowStatus(msg) END Prompt;

(* ReadStr now handles UTF-8 input: each keystroke in 32..126 is
   treated as a byte; the terminal will normally send composed UTF-8
   sequences one byte at a time via ReadKey, so we accumulate them. *)
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
    k := ORD(Terminal.ReadKey());
    IF k = ORD(KEY_ESC) THEN
      Terminal.HideCursor; RETURN FALSE
    ELSIF k = ORD(KEY_ENTER) THEN
      result[len] := 0X; Terminal.HideCursor; RETURN TRUE
    ELSIF k = ORD(KEY_BS) THEN
      IF len > 0 THEN
        (* Step back over a possible multi-byte sequence *)
        DEC(len);
        WHILE (len > 0) & (ORD(result[len]) >= 80H) & (ORD(result[len]) < 0C0H) DO
          DEC(len)
        END;
        result[len] := 0X;
        Terminal.Goto(plen + 1, 1);
        Out.String(result);
        Out.Char(" ");
        Terminal.Goto(plen + Strings.Length(result) + 1, 1)
      END
    ELSIF (k >= 32) & (k < 127) & (len < maxlen) THEN
      (* ASCII printable *)
      result[len] := CHR(k); INC(len); result[len] := 0X; Out.Char(CHR(k))
    ELSIF (k >= 0C0H) & (k <= 0FFH) & (len < maxlen) THEN
      (* UTF-8 lead byte *)
      result[len] := CHR(k); INC(len); result[len] := 0X; Out.Char(CHR(k))
    ELSIF (k >= 80H) & (k < 0C0H) & (len < maxlen) THEN
      (* UTF-8 continuation byte *)
      result[len] := CHR(k); INC(len); result[len] := 0X; Out.Char(CHR(k))
    END
  END
END ReadStr;

(* ════════════════════════════════════════════════════════════════════
   Edit operations  (now codepoint-aware)
   ════════════════════════════════════════════════════════════════════ *)

(* Insert a single byte into the buffer.  For multi-byte codepoints
   call this once per byte; the bytes arrive from ReadKey in order. *)
PROCEDURE InsertByte(b: CHAR);
BEGIN
  IF lastLine >= MaxText - 1 THEN RETURN END;
  IF insMode THEN
    MoveText(curr, curr + 1, lastLine - curr);
    INC(lastLine)
  END;
  text[curr] := b;
  RecordIns(curr, 1);
  INC(curr);
  IF curr > lastLine THEN lastLine := curr END;
  modified := TRUE
END InsertByte;

(* Insert a character/codepoint that may be multi-byte.
   For RetChar (paragraph break) we still use the single-byte path. *)
PROCEDURE Insert(ch: CHAR);
BEGIN InsertByte(ch) END Insert;

PROCEDURE Backspace;
VAR n: INTEGER;
BEGIN
  IF curr > 0 THEN
    (* Step back by one full codepoint *)
    n := UTF8LenBack(curr);
    IF n < 1 THEN n := 1 END;
    RecordDel(curr - n, n, text, curr - n);
    DEC(curr, n);
    DEC(lastLine, n);
    MoveText(curr + n, curr, lastLine - curr);
    modified := TRUE
  END
END Backspace;

PROCEDURE DeleteFwd;
VAR n: INTEGER;
BEGIN
  IF curr < lastLine THEN
    n := UTF8Len(curr);
    IF text[curr] = RetChar THEN n := 1 END;
    RecordDel(curr, n, text, curr);
    DEC(lastLine, n);
    MoveText(curr + n, curr, lastLine - curr);
    modified := TRUE
  END
END DeleteFwd;

PROCEDURE KillToEOL;
VAR ls, le, n, i: INTEGER;
BEGIN
  ls := LineStartFrom(topLin, curr);
  le := NextVisLine(ls);
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
  modified := TRUE;
  ClearSel
END KillToEOL;

PROCEDURE KillWordBack;
VAR start, n, i: INTEGER;
BEGIN
  IF curr = 0 THEN RETURN END;
  start := CPLeft(curr);
  WHILE (start > 0) & ~IsWord(text[start]) DO start := CPLeft(start) END;
  WHILE (start > 0) & IsWord(text[CPLeft(start)]) DO start := CPLeft(start) END;
  n := curr - start;
  IF n <= 0 THEN RETURN END;
  IF n > BufSize THEN n := BufSize END;
  cutLen := n;
  FOR i := 0 TO n - 1 DO cutBuf[i] := text[start + i] END;
  RecordDel(start, n, text, start);
  curr := start;
  MoveText(curr + n, curr, lastLine - (curr + n));
  DEC(lastLine, n);
  modified := TRUE;
  ClearSel
END KillWordBack;

(* Copy selection into cut buffer (keyboard Ctrl-K equivalent). *)
PROCEDURE CopySelection;
BEGIN
  IF selState = SEL_DONE THEN YankSel END
END CopySelection;

(* Cut selection: copy then delete. *)
PROCEDURE CutSelection;
BEGIN
  IF selState = SEL_DONE THEN
    YankSel;
    DeleteSel
  END
END CutSelection;

PROCEDURE Paste;
VAR i, old: INTEGER;
BEGIN
  IF cutLen = 0 THEN RETURN END;
  IF lastLine + cutLen >= MaxText THEN RETURN END;
  (* If there is an active selection, replace it with the paste. *)
  IF selState = SEL_DONE THEN DeleteSel END;
  old := curr;
  MoveText(curr, curr + cutLen, lastLine - curr);
  FOR i := 0 TO cutLen - 1 DO text[curr + i] := cutBuf[i] END;
  INC(lastLine, cutLen);
  INC(curr, cutLen);
  RecordIns(old, cutLen);
  modified := TRUE
END Paste;

PROCEDURE Transpose;
VAR tmp: CHAR; lo, hi: INTEGER;
BEGIN
  (* Swap the two codepoints on either side of cursor *)
  IF (curr > 0) & (curr < lastLine) THEN
    lo := CPLeft(curr);
    hi := CPRight(curr);
    (* simple byte swap only makes sense for single-byte chars;
       for multi-byte we fall back to swapping just single bytes
       like the original — full codepoint swap would require a
       temp buffer and is left as an exercise. *)
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

(* ════════════════════════════════════════════════════════════════════
   Navigation  (codepoint-aware)
   ════════════════════════════════════════════════════════════════════ *)

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
  WHILE (curr < lastLine) & IsWord(text[curr]) DO curr := CPRight(curr) END;
  WHILE (curr < lastLine) & ~IsWord(text[curr]) DO curr := CPRight(curr) END
END WordRight;

PROCEDURE WordLeft;
BEGIN
  curr := CPLeft(curr);
  WHILE (curr > 0) & ~IsWord(text[curr]) DO curr := CPLeft(curr) END;
  WHILE (curr > 0) & IsWord(text[CPLeft(curr)]) DO curr := CPLeft(curr) END
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

(* ════════════════════════════════════════════════════════════════════
   File I/O
   ════════════════════════════════════════════════════════════════════ *)

PROCEDURE SaveFile;
VAR
  f: Files.File; r: Files.Rider;
  tmpname: ARRAY MaxName OF CHAR;
  i: INTEGER;
BEGIN
  IF fname[0] = 0X THEN
    IF ReadStr("Save as: ", tmpname) THEN
      IF tmpname[0] = 0X THEN Prompt("No filename."); RETURN END;
      COPY(tmpname, fname); DetectLang
    ELSE RETURN
    END
  END;
  f := Files.New(fname);
  IF f = NIL THEN Prompt("Cannot create file."); RETURN END;
  Files.Set(r, f, 0);
  FOR i := 0 TO lastLine - 1 DO
    IF text[i] = RetChar THEN Files.Write(r, ORD(0AX))
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
        IF b = ORD(0AX) THEN text[count] := RetChar; INC(count)
        ELSIF b = ORD(0DX) THEN (* skip CR *)
        ELSE text[count] := CHR(b); INC(count)    (* raw UTF-8 byte *)
        END
      END
    END;
    Files.Close(f);
    COPY(tmpname, fname);
    curr := 0; lastLine := count; topLin := 0;
    modified := FALSE; undoHead := 0; undoCnt := 0;
    ClearSel;
    DetectLang;
    Prompt("Loaded.")
  END
END LoadFile;

(* ════════════════════════════════════════════════════════════════════
   Search & Replace
   ════════════════════════════════════════════════════════════════════ *)

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

(* ════════════════════════════════════════════════════════════════════
   Compile / Run (F5)
   ════════════════════════════════════════════════════════════════════ *)

PROCEDURE StripExt(src: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR);
VAR dot, i, slen: INTEGER;
BEGIN
  slen := Strings.Length(src);
  dot := -1;
  FOR i := 0 TO slen - 1 DO IF src[i] = "." THEN dot := i END END;
  IF dot > 0 THEN Strings.Extract(src, 0, dot, dst)
  ELSE COPY(src, dst)
  END
END StripExt;

PROCEDURE CompileRun;
VAR base, cmd: ARRAY 512 OF CHAR;
BEGIN
  IF fname[0] = 0X THEN Prompt("F5: save the file first."); RETURN END;
  IF modified THEN SaveFile END;
  StripExt(fname, base);
  CASE lang OF
    HLANG_C:
      Strings.Copy("cc -o ", cmd); Strings.Append(base, cmd);
      Strings.Append(" ", cmd);    Strings.Append(fname, cmd);
      Strings.Append(" 2>&1 && ./", cmd); Strings.Append(base, cmd)
  | HLANG_CPP:
      Strings.Copy("c++ -o ", cmd); Strings.Append(base, cmd);
      Strings.Append(" ", cmd);     Strings.Append(fname, cmd);
      Strings.Append(" 2>&1 && ./", cmd); Strings.Append(base, cmd)
  | HLANG_OBN:
      Strings.Copy("obc ", cmd); Strings.Append(fname, cmd);
      Strings.Append(" 2>&1 && ./", cmd); Strings.Append(base, cmd)
  | HLANG_R:
      Strings.Copy("Rscript ", cmd); Strings.Append(fname, cmd);
      Strings.Append(" 2>&1", cmd)
  | HLANG_RUBY:
      Strings.Copy("ruby ", cmd); Strings.Append(fname, cmd);
      Strings.Append(" 2>&1", cmd)
  | HLANG_SWIFT:
      Strings.Copy("swiftc -o ", cmd); Strings.Append(base, cmd);
      Strings.Append(" ", cmd); Strings.Append(fname, cmd);
      Strings.Append(" 2>&1 && ./", cmd); Strings.Append(base, cmd)
  ELSE
    Prompt("F5: no language detected — save with a known extension first.");
    RETURN
  END;
  Terminal.Clear;
  Terminal.Shell(cmd)
END CompileRun;

(* ════════════════════════════════════════════════════════════════════
   Help screen
   ════════════════════════════════════════════════════════════════════ *)

PROCEDURE ShowHelp;
VAR row, c2, w, i: INTEGER;
BEGIN
  w := Terminal.Cols(); c2 := w DIV 2 + 1;
  Terminal.HideCursor;
  Terminal.Clear;
  ShowStatus("  SpeedScript 3.1  Key Bindings  (press any key to return)  ");
  Terminal.Goto(1, 2); FGColor(8);
  FOR i := 1 TO w DO Out.Char("-") END;
  Terminal.Reset;
  row := 3;
  Terminal.Goto(1, row); FGColor(14); Out.String("Navigation");     Terminal.Reset; INC(row);
  Terminal.Goto(1, row); FGColor(11); Out.String("Arrow keys  ");   FGColor(7); Out.String("Move cursor (codepoint-aware)"); Terminal.Reset; INC(row);
  Terminal.Goto(1, row); FGColor(11); Out.String("Ctrl-Left/Rt");   FGColor(7); Out.String("  Word left / right");           Terminal.Reset; INC(row);
  Terminal.Goto(1, row); FGColor(11); Out.String("Home / End  ");   FGColor(7); Out.String("  Start / end of doc");          Terminal.Reset; INC(row);
  Terminal.Goto(1, row); FGColor(11); Out.String("PgUp / PgDn ");   FGColor(7); Out.String("  Page up / down");              Terminal.Reset; INC(row);
  INC(row);
  Terminal.Goto(1, row); FGColor(14); Out.String("Editing");        Terminal.Reset; INC(row);
  Terminal.Goto(1, row); FGColor(11); Out.String("Backspace   ");   FGColor(7); Out.String("  Delete codepoint left");       Terminal.Reset; INC(row);
  Terminal.Goto(1, row); FGColor(11); Out.String("Del         ");   FGColor(7); Out.String("  Delete codepoint at cursor");  Terminal.Reset; INC(row);
  Terminal.Goto(1, row); FGColor(11); Out.String("Enter       ");   FGColor(7); Out.String("  Insert paragraph break");      Terminal.Reset; INC(row);
  Terminal.Goto(1, row); FGColor(11); Out.String("Tab         ");   FGColor(7); Out.String("  Toggle insert/overwrite");     Terminal.Reset; INC(row);
  Terminal.Goto(1, row); FGColor(11); Out.String("Ctrl-T      ");   FGColor(7); Out.String("  Transpose chars");             Terminal.Reset; INC(row);
  Terminal.Goto(1, row); FGColor(11); Out.String("Ctrl-X      ");   FGColor(7); Out.String("  Toggle case");                 Terminal.Reset; INC(row);
  Terminal.Goto(1, row); FGColor(11); Out.String("Ctrl-Z      ");   FGColor(7); Out.String("  Undo");                        Terminal.Reset; INC(row);
  INC(row);
  Terminal.Goto(1, row); FGColor(14); Out.String("Other");          Terminal.Reset; INC(row);
  Terminal.Goto(1, row); FGColor(11); Out.String("F1          ");   FGColor(7); Out.String("  This help screen");            Terminal.Reset; INC(row);
  Terminal.Goto(1, row); FGColor(11); Out.String("F5          ");   FGColor(7); Out.String("  Compile / run");               Terminal.Reset; INC(row);
  Terminal.Goto(1, row); FGColor(11); Out.String("Esc         ");   FGColor(7); Out.String("  Quit");                        Terminal.Reset;
  row := 3;
  Terminal.Goto(c2, row); FGColor(14); Out.String("Cut & Paste");    Terminal.Reset; INC(row);
  Terminal.Goto(c2, row); FGColor(11); Out.String("Ctrl-K  ");       FGColor(7); Out.String("Kill to end of line");          Terminal.Reset; INC(row);
  Terminal.Goto(c2, row); FGColor(11); Out.String("Ctrl-W  ");       FGColor(7); Out.String("Delete word backward");         Terminal.Reset; INC(row);
  Terminal.Goto(c2, row); FGColor(11); Out.String("Ctrl-R  ");       FGColor(7); Out.String("Paste (replace sel if any)");   Terminal.Reset; INC(row);
  INC(row);
  Terminal.Goto(c2, row); FGColor(14); Out.String("Mouse");          Terminal.Reset; INC(row);
  Terminal.Goto(c2, row); FGColor(11); Out.String("Left drag");      FGColor(7); Out.String("  Select region");              Terminal.Reset; INC(row);
  Terminal.Goto(c2, row); FGColor(11); Out.String("Middle btn");     FGColor(7); Out.String("  Paste at click");             Terminal.Reset; INC(row);
  Terminal.Goto(c2, row); FGColor(11); Out.String("Right btn ");     FGColor(7); Out.String("  Cut sel then paste");         Terminal.Reset; INC(row);
  Terminal.Goto(c2, row); FGColor(11); Out.String("Wheel      ");    FGColor(7); Out.String("  Scroll 3 lines up/down");     Terminal.Reset; INC(row);
  INC(row);
  Terminal.Goto(c2, row); FGColor(14); Out.String("Search");         Terminal.Reset; INC(row);
  Terminal.Goto(c2, row); FGColor(11); Out.String("Ctrl-F  ");       FGColor(7); Out.String("Find (Enter=repeat)");          Terminal.Reset; INC(row);
  Terminal.Goto(c2, row); FGColor(11); Out.String("Ctrl-G  ");       FGColor(7); Out.String("Find and replace all");         Terminal.Reset; INC(row);
  INC(row);
  Terminal.Goto(c2, row); FGColor(14); Out.String("File");           Terminal.Reset; INC(row);
  Terminal.Goto(c2, row); FGColor(11); Out.String("Ctrl-S  ");       FGColor(7); Out.String("Save");                         Terminal.Reset; INC(row);
  Terminal.Goto(c2, row); FGColor(11); Out.String("F2      ");       FGColor(7); Out.String("Save as (new filename)");       Terminal.Reset; INC(row);
  Terminal.Goto(c2, row); FGColor(11); Out.String("Ctrl-L  ");       FGColor(7); Out.String("Load file");                    Terminal.Reset; INC(row);
  Terminal.Goto(c2, row); FGColor(11); Out.String("Ctrl-N  ");       FGColor(7); Out.String("New document");                 Terminal.Reset; INC(row);
  INC(row);
  Terminal.Goto(c2, row); FGColor(14); Out.String("Unicode");        Terminal.Reset; INC(row);
  Terminal.Goto(c2, row); FGColor(7);  Out.String("UTF-8 stored natively");                                                              Terminal.Reset; INC(row);
  Terminal.Goto(c2, row); FGColor(7);  Out.String("CJK wide-char column aware");                                                         Terminal.Reset;
  i := ORD(Terminal.ReadKey());
  Terminal.ShowCursor
END ShowHelp;

PROCEDURE NewDoc;
VAR k: INTEGER;
BEGIN
  Prompt("New document - lose changes? (y/n)");
  k := ORD(Terminal.ReadKey());
  IF (k = ORD("y")) OR (k = ORD("Y")) THEN
    curr := 0; lastLine := 0; topLin := 0;
    fname[0] := 0X; modified := FALSE;
    undoHead := 0; undoCnt := 0; lang := HLANG_NONE;
    ClearSel;
    Prompt("New document.")
  END
END NewDoc;

(* ════════════════════════════════════════════════════════════════════
   Main loop
   ════════════════════════════════════════════════════════════════════ *)

PROCEDURE Run*;
VAR k, b: INTEGER; f: Files.File; r: Files.Rider;
BEGIN
  curr := 0; lastLine := 0; topLin := 0;
  fname[0] := 0X;
  searchStr[0] := 0X; replStr[0] := 0X;
  cutLen := 0;
  undoHead := 0; undoCnt := 0; lang := HLANG_NONE;
  insMode := TRUE; modified := FALSE; running := TRUE;
  ClearSel;

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
          ELSE text[lastLine] := CHR(b); INC(lastLine)   (* raw UTF-8 *)
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
    k := ORD(Terminal.ReadKey());

    CASE CHR(k) OF
      KEY_ESC, KEY_CTRL_Q:
        IF modified THEN
          IF ReadStr("Unsaved changes. Exit? (y/n): ", searchStr) THEN
            IF (searchStr[0] = "y") OR (searchStr[0] = "Y") THEN
              running := FALSE
            END
          END;
          Refresh
        ELSE
          running := FALSE
        END
    | KEY_MOUSE:
        HandleMouse
    | KEY_BS:
        IF selState = SEL_DONE THEN DeleteSel ELSE Backspace END
    | KEY_DEL:
        IF selState = SEL_DONE THEN DeleteSel ELSE DeleteFwd END
    | KEY_ENTER:
        IF selState = SEL_DONE THEN DeleteSel END;
        Insert(RetChar)
    | KEY_TAB:
        insMode := ~insMode
    | KEY_UP:        ClearSel; MoveUp
    | KEY_DOWN:      ClearSel; MoveDown
    | KEY_LEFT:
        IF selState = SEL_DONE THEN curr := SelLo(); ClearSel
        ELSE ClearSel; curr := CPLeft(curr)
        END
    | KEY_RIGHT:
        IF selState = SEL_DONE THEN curr := SelHi(); ClearSel
        ELSE ClearSel; curr := CPRight(curr)
        END
    | KEY_WLEFT:     ClearSel; WordLeft
    | KEY_WRIGHT:    ClearSel; WordRight
    | KEY_HOME, KEY_FHOME:
        ClearSel; curr := 0; topLin := 0
    | KEY_END, KEY_FEND:
        ClearSel; curr := lastLine
    | KEY_PGUP:      ClearSel; PageUp
    | KEY_PGDN:      ClearSel; PageDown
    | KEY_CTRL_S:    SaveFile
    | KEY_CTRL_L:    LoadFile
    | KEY_CTRL_N:    NewDoc
    | KEY_CTRL_F:    DoFind
    | KEY_CTRL_G:    DoFindReplace
    | KEY_CTRL_K:    CopySelection; KillToEOL   (* Ctrl-K: copy sel first if any *)
    | KEY_CTRL_W:    KillWordBack
    | KEY_CTRL_R:    Paste
    | KEY_CTRL_T:    Transpose
    | KEY_CTRL_X:    ToggleCase
    | KEY_CTRL_Z:    DoUndo
    | KEY_F1:        ShowHelp
    | KEY_F2:        SaveFileAs
    | KEY_F5:        CompileRun
    ELSE
      (* Printable ASCII and raw UTF-8 bytes (multi-byte sequences
         arrive one byte at a time from Terminal.ReadKey). *)
      IF (k >= 32) & (k < 127) THEN
        IF selState = SEL_DONE THEN DeleteSel END;
        Insert(CHR(k))
      ELSIF (k >= 080H) & (k <= 0FFH) THEN
        (* UTF-8 lead or continuation byte *)
        IF selState = SEL_DONE THEN DeleteSel END;
        Insert(CHR(k))
      END
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

