MODULE TUI;
(*
 * TUI — text-user-interface framework built on Terminal and Graphics.
 *
 * Screen model
 * ─────────────
 *   Double-buffered cell grid (back vs front).  Call PutCell / PutStr /
 *   FillRect / DrawBox to write into the back buffer, then Flush to push
 *   only changed cells to the terminal.
 *
 *   Box characters are stored as byte codes 0xC0–0xC5 which Flush maps
 *   to the corresponding UTF-8 box-drawing glyphs:
 *     0xC0 ─   0xC1 │   0xC2 ┌   0xC3 ┐   0xC4 └   0xC5 ┘
 *
 * Event model
 * ────────────
 *   PollEvent: non-blocking; returns FALSE when no event is ready.
 *   WaitEvent: blocks until an event arrives.
 *   Dispatch:  routes a key/mouse event through the desktop view tree.
 *
 * View / Window
 * ──────────────
 *   View is the base drawable/interactive object.  It carries:
 *     - a bounding rectangle (x, y, w, h)
 *     - a draw procedure variable (called by DrawAll / DrawView)
 *     - a handle procedure variable (called by Dispatch; returns TRUE
 *       if the event was consumed)
 *     - next / child pointers for the sibling/child linked lists
 *
 *   Window extends View with a title bar and border drawn automatically
 *   by DrawWindow.  Set the draw field to draw the window's interior.
 *
 * Desktop
 * ────────
 *   The desktop is a z-ordered singly-linked list of View/Window pointers
 *   threaded through the `next` field.  The head is the front-most window.
 *   AddView / RemoveView / BringToFront manage the list.
 *
 * Focus
 * ──────
 *   A single module-level pointer `Focused` holds the currently focused
 *   view.  Tab cycles forward through the desktop list.
 *
 * Modal dialogs
 * ──────────────
 *   RunModal(w) pushes w to the front, runs a nested event loop, and
 *   returns when the dialog sets ModalResult to a non-zero command code.
 *)

IMPORT Terminal, Out, Strings;

(* ── Limits ───────────────────────────────────────────────────────────── *)

CONST
  MaxCols*   = 220;
  MaxRows*   = 60;
  MaxViews   = 64;    (* maximum views in the DrawAll stack *)

(* ── Special key codes (matching Terminal.ReadKey return values) ────────── *)

CONST
  KUp*        = 01X;   (* Up arrow    *)
  KDown*      = 02X;   (* Down arrow  *)
  KLeft*      = 03X;   (* Left arrow  *)
  KRight*     = 04X;   (* Right arrow *)
  KMouse*     = 05X;   (* Mouse event — read ev.mx/my/mb for details *)
  KBackspace* = 08X;
  KTab*       = 09X;
  KEnter*     = 0DX;
  KEsc*       = 1BX;

  KPgUp*      = 80X;   (* Page Up         *)
  KPgDn*      = 81X;   (* Page Down       *)
  KHome*      = 82X;   (* Home            *)
  KEnd*       = 83X;   (* End             *)
  KDel*       = 84X;   (* Delete          *)
  KCtrlLeft*  = 85X;   (* Ctrl+Left       *)
  KCtrlRight* = 86X;   (* Ctrl+Right      *)
  KCtrlHome*  = 87X;   (* Ctrl+Home       *)
  KCtrlEnd*   = 88X;   (* Ctrl+End        *)
  KF1*        = 89X;   (* F1              *)
  KF2*        = 8AX;   (* F2              *)
  KF3*        = 8BX;   (* F3              *)
  KF4*        = 8CX;   (* F4              *)
  KF5*        = 8DX;   (* F5              *)
  KF6*        = 8EX;   (* F6              *)
  KF7*        = 8FX;   (* F7              *)
  KF8*        = 90X;   (* F8              *)
  KF9*        = 91X;   (* F9              *)
  KF10*       = 92X;   (* F10             *)
  KF11*       = 93X;   (* F11             *)
  KF12*       = 94X;   (* F12             *)

(* ── Event kinds ──────────────────────────────────────────────────────── *)

CONST
  EvNone*   = 0;
  EvKey*    = 1;
  EvMouse*  = 2;
  EvResize* = 3;

(* ── Standard 16-color palette ──────────────────────────────────────────── *)

CONST
  Black*   = 0;  Red*     = 1;  Green*  = 2;  Yellow* = 3;
  Blue*    = 4;  Magenta* = 5;  Cyan*   = 6;  White*  = 7;

(* ── Box-drawing pseudo-characters stored in Cell.ch ───────────────────── *)
(* Flush maps these byte values to multi-byte UTF-8 sequences.             *)

CONST
  BoxH*  = 0C0X;  (* ─ horizontal line  *)
  BoxV*  = 0C1X;  (* │ vertical line    *)
  BoxTL* = 0C2X;  (* ┌ top-left corner  *)
  BoxTR* = 0C3X;  (* ┐ top-right corner *)
  BoxBL* = 0C4X;  (* └ bottom-left      *)
  BoxBR* = 0C5X;  (* ┘ bottom-right     *)

(* ── Types ────────────────────────────────────────────────────────────── *)

TYPE
  (* Screen cell: character + 16-color foreground/background *)
  Cell = RECORD
    ch: CHAR;
    fg, bg: INTEGER
  END;

  (* Input event *)
  Event* = RECORD
    kind*: INTEGER;    (* EvKey / EvMouse / EvResize / EvNone *)
    key*:  CHAR;       (* EvKey: character / special code     *)
    mx*:   INTEGER;    (* EvMouse: column (1-based)           *)
    my*:   INTEGER;    (* EvMouse: row    (1-based)           *)
    mb*:   INTEGER;    (* EvMouse: button 0=L 1=M 2=R 3=up 64=whl↑ 65=whl↓ *)
    cols*: INTEGER;    (* EvResize: new width                 *)
    rows*: INTEGER;    (* EvResize: new height                *)
  END;

  (* Base view — forward-declared pointer so procedures can use it *)
  View* = POINTER TO ViewRec;

  (* Procedure-type aliases for the draw and handle fields *)
  DrawProc*   = PROCEDURE(v: View);
  HandleProc* = PROCEDURE(v: View; ev: Event): BOOLEAN;

  ViewRec* = RECORD
    x*, y*, w*, h*: INTEGER;
    draw*:    DrawProc;    (* called to repaint the view into the back buffer *)
    handle*:  HandleProc;  (* called with key/mouse events; returns TRUE = consumed *)
    next*:    View;        (* next sibling (desktop list or child list) *)
    child*:   View;        (* first child view                         *)
    focused*: BOOLEAN
  END;

  (* Window — a View with a title bar and automatic border *)
  Window* = POINTER TO WindowRec;
  WindowRec* = RECORD (ViewRec)
    title*:    ARRAY 64 OF CHAR;
    moveable*: BOOLEAN
  END;

(* ── Module-level state ────────────────────────────────────────────────── *)

VAR
  back,  front: ARRAY MaxRows, MaxCols OF Cell;

  Cols*: INTEGER;   (* current terminal width  (≤ MaxCols) *)
  Rows*: INTEGER;   (* current terminal height (≤ MaxRows) *)

  Desktop*:    View;     (* front-most view is the list head *)
  Focused*:    View;     (* currently focused view           *)
  ModalResult*: INTEGER; (* non-zero = close the modal loop  *)

  prevCols, prevRows: INTEGER;

(* ════════════════════════════════════════════════════════════════════════
   Internal helpers
   ════════════════════════════════════════════════════════════════════════ *)

(* Emit the UTF-8 sequence for a box-drawing pseudo-character. *)
PROCEDURE EmitBoxChar(ch: CHAR);
BEGIN
  IF    ch = BoxH  THEN Out.Char(0E2X); Out.Char(094X); Out.Char(080X)  (* ─ *)
  ELSIF ch = BoxV  THEN Out.Char(0E2X); Out.Char(094X); Out.Char(082X)  (* │ *)
  ELSIF ch = BoxTL THEN Out.Char(0E2X); Out.Char(094X); Out.Char(08CX)  (* ┌ *)
  ELSIF ch = BoxTR THEN Out.Char(0E2X); Out.Char(094X); Out.Char(090X)  (* ┐ *)
  ELSIF ch = BoxBL THEN Out.Char(0E2X); Out.Char(094X); Out.Char(094X)  (* └ *)
  ELSIF ch = BoxBR THEN Out.Char(0E2X); Out.Char(094X); Out.Char(098X)  (* ┘ *)
  ELSE  Out.Char(ch)
  END
END EmitBoxChar;

(* Emit ANSI 16-color sequence: ESC [ 3fg ; 4bg m *)
PROCEDURE SetColor(fg, bg: INTEGER);
BEGIN
  Out.Char(01BX); Out.Char('[');
  Out.Int(30 + (fg MOD 8), 0);
  Out.Char(';');
  Out.Int(40 + (bg MOD 8), 0);
  Out.Char('m')
END SetColor;

(* Reset color *)
PROCEDURE ResetColor;
BEGIN
  Out.Char(01BX); Out.String("[0m")
END ResetColor;

(* ════════════════════════════════════════════════════════════════════════
   Screen buffer API
   ════════════════════════════════════════════════════════════════════════ *)

(** ClearBack — fill the entire back buffer with spaces using given colors. **)
PROCEDURE ClearBack*(fg, bg: INTEGER);
VAR r, c: INTEGER;
BEGIN
  FOR r := 0 TO Rows - 1 DO
    FOR c := 0 TO Cols - 1 DO
      back[r][c].ch := ' ';
      back[r][c].fg := fg;
      back[r][c].bg := bg
    END
  END
END ClearBack;

(** PutCell — write one cell into the back buffer (1-based coordinates). **)
PROCEDURE PutCell*(x, y: INTEGER; ch: CHAR; fg, bg: INTEGER);
VAR r, c: INTEGER;
BEGIN
  c := x - 1;  r := y - 1;
  IF (r >= 0) & (r < Rows) & (c >= 0) & (c < Cols) THEN
    back[r][c].ch := ch;
    back[r][c].fg := fg;
    back[r][c].bg := bg
  END
END PutCell;

(** PutStr — write a string left-to-right starting at (x, y). **)
PROCEDURE PutStr*(x, y: INTEGER; s: ARRAY OF CHAR; fg, bg: INTEGER);
VAR k, col, row: INTEGER;
BEGIN
  row := y - 1;  col := x - 1;  k := 0;
  WHILE (s[k] # 0X) & (col < Cols) DO
    IF (row >= 0) & (row < Rows) & (col >= 0) THEN
      back[row][col].ch := s[k];
      back[row][col].fg := fg;
      back[row][col].bg := bg
    END;
    INC(k);  INC(col)
  END
END PutStr;

(** PutInt — write an integer as decimal text at (x, y). **)
PROCEDURE PutInt*(x, y, n, fg, bg: INTEGER);
VAR buf: ARRAY 16 OF CHAR;
    neg: BOOLEAN;
    i, m: INTEGER;
BEGIN
  IF n < 0 THEN  neg := TRUE;  m := -n  ELSE  neg := FALSE;  m := n  END;
  i := 14;  buf[15] := 0X;
  IF m = 0 THEN  buf[i] := '0';  DEC(i)
  ELSE
    WHILE m > 0 DO
      buf[i] := CHR(ORD('0') + m MOD 10);  DEC(i);  m := m DIV 10
    END
  END;
  IF neg THEN  buf[i] := '-';  DEC(i)  END;
  PutStr(x, y, buf, fg, bg)
END PutInt;

(** FillRect — fill a rectangle with a character. **)
PROCEDURE FillRect*(x, y, w, h: INTEGER; ch: CHAR; fg, bg: INTEGER);
VAR r, c: INTEGER;
BEGIN
  FOR r := y TO y + h - 1 DO
    FOR c := x TO x + w - 1 DO
      PutCell(c, r, ch, fg, bg)
    END
  END
END FillRect;

(** DrawBox — draw a single-line border rectangle using box-drawing chars. **)
PROCEDURE DrawBox*(x, y, w, h, fg, bg: INTEGER);
VAR r, c, x2, y2: INTEGER;
BEGIN
  IF (w < 2) OR (h < 2) THEN RETURN END;
  x2 := x + w - 1;  y2 := y + h - 1;

  PutCell(x,  y,  BoxTL, fg, bg);
  PutCell(x2, y,  BoxTR, fg, bg);
  PutCell(x,  y2, BoxBL, fg, bg);
  PutCell(x2, y2, BoxBR, fg, bg);

  FOR c := x + 1 TO x2 - 1 DO
    PutCell(c, y,  BoxH, fg, bg);
    PutCell(c, y2, BoxH, fg, bg)
  END;

  FOR r := y + 1 TO y2 - 1 DO
    PutCell(x,  r, BoxV, fg, bg);
    PutCell(x2, r, BoxV, fg, bg)
  END
END DrawBox;

(** Flush — push changed back-buffer cells to the terminal.
    Only emits ANSI sequences for cells that differ from the front buffer. **)
PROCEDURE Flush*;
VAR r, c, curFg, curBg: INTEGER;
    isBox: BOOLEAN;
BEGIN
  curFg := -1;  curBg := -1;
  FOR r := 0 TO Rows - 1 DO
    FOR c := 0 TO Cols - 1 DO
      IF (back[r][c].ch # front[r][c].ch) OR
         (back[r][c].fg # front[r][c].fg) OR
         (back[r][c].bg # front[r][c].bg) THEN

        Terminal.Goto(c + 1, r + 1);

        IF (back[r][c].fg # curFg) OR (back[r][c].bg # curBg) THEN
          SetColor(back[r][c].fg, back[r][c].bg);
          curFg := back[r][c].fg;
          curBg := back[r][c].bg
        END;

        isBox := (back[r][c].ch >= BoxH) & (back[r][c].ch <= BoxBR);
        IF isBox THEN
          EmitBoxChar(back[r][c].ch)
        ELSE
          Out.Char(back[r][c].ch)
        END;

        front[r][c] := back[r][c]
      END
    END
  END;
  ResetColor
END Flush;

(** InvalidateFront — force the next Flush to repaint every cell.
    Call after Terminal.Clear or a resize. **)
PROCEDURE InvalidateFront*;
VAR r, c: INTEGER;
BEGIN
  FOR r := 0 TO MaxRows - 1 DO
    FOR c := 0 TO MaxCols - 1 DO
      front[r][c].ch := 0X;
      front[r][c].fg := -1;
      front[r][c].bg := -1
    END
  END
END InvalidateFront;

(* ════════════════════════════════════════════════════════════════════════
   Terminal size
   ════════════════════════════════════════════════════════════════════════ *)

(** UpdateSize — query terminal size; return TRUE if it changed. **)
PROCEDURE UpdateSize*(): BOOLEAN;
VAR nc, nr: INTEGER;
BEGIN
  nc := Terminal.Cols();  nr := Terminal.Rows();
  IF nc > MaxCols THEN nc := MaxCols END;
  IF nr > MaxRows THEN nr := MaxRows END;
  IF (nc # Cols) OR (nr # Rows) THEN
    Cols := nc;  Rows := nr;
    RETURN TRUE
  END;
  RETURN FALSE
END UpdateSize;

(* ════════════════════════════════════════════════════════════════════════
   Events
   ════════════════════════════════════════════════════════════════════════ *)

(** PollEvent — non-blocking: fill ev and return TRUE if an event is ready. **)
PROCEDURE PollEvent*(VAR ev: Event): BOOLEAN;
VAR nc, nr: INTEGER;
BEGIN
  ev.kind := EvNone;

  (* Detect resize *)
  nc := Terminal.Cols();  nr := Terminal.Rows();
  IF nc > MaxCols THEN nc := MaxCols END;
  IF nr > MaxRows THEN nr := MaxRows END;
  IF (nc # prevCols) OR (nr # prevRows) THEN
    prevCols := nc;  prevRows := nr;
    Cols := nc;  Rows := nr;
    ev.kind := EvResize;
    ev.cols  := nc;  ev.rows  := nr;
    RETURN TRUE
  END;

  (* Keyboard / mouse *)
  IF Terminal.KeyPressed() THEN
    ev.key := Terminal.ReadKey();
    IF ev.key = KMouse THEN
      ev.kind := EvMouse;
      ev.mx   := Terminal.MouseX();
      ev.my   := Terminal.MouseY();
      ev.mb   := Terminal.MouseBtn()
    ELSE
      ev.kind := EvKey
    END;
    RETURN TRUE
  END;
  RETURN FALSE
END PollEvent;

(** WaitEvent — block until an event is available. **)
PROCEDURE WaitEvent*(VAR ev: Event);
BEGIN
  REPEAT UNTIL PollEvent(ev)
END WaitEvent;

(* ════════════════════════════════════════════════════════════════════════
   View drawing
   ════════════════════════════════════════════════════════════════════════ *)

(** DrawView — invoke v's draw procedure if set. **)
PROCEDURE DrawView*(v: View);
BEGIN
  IF (v # NIL) & (v.draw # NIL) THEN  v.draw(v)  END
END DrawView;

(** DrawWindow — draw border + title bar for a Window, then its interior. **)
PROCEDURE DrawWindow*(w: Window);
VAR tlen, tx, borderFg, borderBg, titleFg: INTEGER;
    tBuf: ARRAY 66 OF CHAR;
BEGIN
  IF w = NIL THEN RETURN END;

  IF w.focused THEN
    borderFg := White;   borderBg := Blue;  titleFg := Yellow
  ELSE
    borderFg := White;   borderBg := Black; titleFg := White
  END;

  (* Clear interior *)
  FillRect(w.x + 1, w.y + 1, w.w - 2, w.h - 2, ' ', White, Black);

  (* Border *)
  DrawBox(w.x, w.y, w.w, w.h, borderFg, borderBg);

  (* Title *)
  tlen := Strings.Length(w.title);
  IF (tlen > 0) & (w.w > 4) THEN
    IF tlen > w.w - 4 THEN tlen := w.w - 4 END;
    tx := w.x + (w.w - tlen) DIV 2;
    Strings.Copy(w.title, tBuf);
    tBuf[tlen] := 0X;
    PutStr(tx, w.y, tBuf, titleFg, borderBg)
  END;

  (* Interior draw proc *)
  IF w.draw # NIL THEN  w.draw(w)  END
END DrawWindow;

(** DrawAll — redraw all views on the desktop from back to front.
    Collects up to MaxViews views into a local array and draws in reverse
    order so the front-most window paints last (on top). **)
PROCEDURE DrawAll*;
VAR stack: ARRAY MaxViews OF View;
    n: INTEGER;
    v: View;
BEGIN
  (* Collect desktop views into stack (head = front) *)
  n := 0;  v := Desktop;
  WHILE (v # NIL) & (n < MaxViews) DO
    stack[n] := v;  INC(n);  v := v.next
  END;

  (* Draw from back (n-1) to front (0) *)
  WHILE n > 0 DO
    DEC(n);
    v := stack[n];
    IF v IS WindowRec THEN
      WITH v: WindowRec DO  DrawWindow(v)  END
    ELSE
      DrawView(v)
    END
  END
END DrawAll;

(* ════════════════════════════════════════════════════════════════════════
   Desktop management
   ════════════════════════════════════════════════════════════════════════ *)

(** AddView — prepend v to the desktop list (makes it the front window). **)
PROCEDURE AddView*(v: View);
BEGIN
  IF v = NIL THEN RETURN END;
  v.next  := Desktop;
  Desktop := v
END AddView;

(** RemoveView — remove v from the desktop list. **)
PROCEDURE RemoveView*(v: View);
VAR cur, prev: View;
BEGIN
  IF v = NIL THEN RETURN END;
  IF Desktop = v THEN
    Desktop := v.next;  v.next := NIL;  RETURN
  END;
  prev := NIL;  cur := Desktop;
  WHILE (cur # NIL) & (cur # v) DO
    prev := cur;  cur := cur.next
  END;
  IF cur = v THEN
    prev.next := v.next;  v.next := NIL
  END
END RemoveView;

(** BringToFront — move v to the head of the desktop list. **)
PROCEDURE BringToFront*(v: View);
BEGIN
  RemoveView(v);
  AddView(v)
END BringToFront;

(** HitTest — return the front-most view whose bounds contain (x, y). **)
PROCEDURE HitTest*(x, y: INTEGER): View;
VAR v: View;
BEGIN
  v := Desktop;
  WHILE v # NIL DO
    IF (x >= v.x) & (x < v.x + v.w) &
       (y >= v.y) & (y < v.y + v.h) THEN
      RETURN v
    END;
    v := v.next
  END;
  RETURN NIL
END HitTest;

(** TileWindows — arrange all desktop views in an equal-size grid. **)
PROCEDURE TileWindows*;
VAR n, gridCols, gridRows, vw, vh, i: INTEGER;
    v: View;
BEGIN
  n := 0;  v := Desktop;
  WHILE v # NIL DO  INC(n);  v := v.next  END;
  IF n = 0 THEN RETURN END;

  (* Ceiling-sqrt gives the number of columns *)
  gridCols := 1;
  WHILE gridCols * gridCols < n DO  INC(gridCols)  END;
  gridRows := (n + gridCols - 1) DIV gridCols;

  vw := Cols DIV gridCols;
  vh := Rows DIV gridRows;
  IF vw < 4 THEN vw := 4 END;
  IF vh < 3 THEN vh := 3 END;

  i := 0;  v := Desktop;
  WHILE v # NIL DO
    v.x := (i MOD gridCols) * vw + 1;
    v.y := (i DIV gridCols) * vh + 1;
    v.w := vw;
    v.h := vh;
    INC(i);  v := v.next
  END
END TileWindows;

(* ════════════════════════════════════════════════════════════════════════
   Focus management
   ════════════════════════════════════════════════════════════════════════ *)

(** SetFocus — move focus to v, clearing the previously focused view. **)
PROCEDURE SetFocus*(v: View);
BEGIN
  IF Focused # NIL THEN  Focused.focused := FALSE  END;
  Focused := v;
  IF v # NIL THEN  v.focused := TRUE  END
END SetFocus;

(** FocusNext — cycle focus forward through the desktop list. **)
PROCEDURE FocusNext*;
VAR v: View;
BEGIN
  IF Desktop = NIL THEN RETURN END;
  IF Focused = NIL THEN  SetFocus(Desktop);  RETURN  END;
  v := Focused.next;
  IF v = NIL THEN  v := Desktop  END;
  SetFocus(v)
END FocusNext;

(* ════════════════════════════════════════════════════════════════════════
   Event dispatch
   ════════════════════════════════════════════════════════════════════════ *)

(** Dispatch — route ev through the desktop.
    Key events go to the focused view; mouse events use hit-testing.
    Tab transfers focus.  Returns TRUE if the event was consumed. **)
PROCEDURE Dispatch*(ev: Event): BOOLEAN;
VAR v: View;
    consumed: BOOLEAN;
BEGIN
  consumed := FALSE;
  IF ev.kind = EvKey THEN
    IF ev.key = KTab THEN
      FocusNext;  RETURN TRUE
    END;
    IF (Focused # NIL) & (Focused.handle # NIL) THEN
      consumed := Focused.handle(Focused, ev)
    END
  ELSIF ev.kind = EvMouse THEN
    v := HitTest(ev.mx, ev.my);
    IF v # NIL THEN
      IF v # Focused THEN  SetFocus(v)  END;
      IF v.handle # NIL THEN  consumed := v.handle(v, ev)  END
    END
  ELSIF ev.kind = EvResize THEN
    InvalidateFront
  END;
  RETURN consumed
END Dispatch;

(* ════════════════════════════════════════════════════════════════════════
   Modal dialog loop
   ════════════════════════════════════════════════════════════════════════ *)

(** RunModal — push w to the desktop, run a nested event loop, return the
    command code.  The handle proc signals completion by setting ModalResult
    to a non-zero value.  The window is removed from the desktop on exit. **)
PROCEDURE RunModal*(w: Window): INTEGER;
VAR ev: Event;
    savedFocus: View;
BEGIN
  IF w = NIL THEN RETURN 0 END;
  savedFocus  := Focused;
  ModalResult := 0;
  AddView(w);
  SetFocus(w);

  REPEAT
    DrawAll;
    Flush;
    WaitEvent(ev);
    IF Dispatch(ev) THEN END  (* result ignored; ModalResult signals exit *)
  UNTIL ModalResult # 0;

  RemoveView(w);
  SetFocus(savedFocus);
  RETURN ModalResult
END RunModal;

(* ════════════════════════════════════════════════════════════════════════
   Initialisation / shutdown
   ════════════════════════════════════════════════════════════════════════ *)

(** Init — set up raw terminal, double buffer, and module state. **)
PROCEDURE Init*;
BEGIN
  Terminal.Init();
  Terminal.MouseOn();
  Terminal.HideCursor();

  Cols := Terminal.Cols();
  Rows := Terminal.Rows();
  IF Cols > MaxCols THEN Cols := MaxCols END;
  IF Rows > MaxRows THEN Rows := MaxRows END;
  prevCols := Cols;  prevRows := Rows;

  InvalidateFront;
  ClearBack(White, Black);

  Desktop    := NIL;
  Focused    := NIL;
  ModalResult := 0
END Init;

(** Done — restore the terminal (cursor, mouse, cooked mode, clear screen). **)
PROCEDURE Done*;
BEGIN
  Terminal.ShowCursor();
  Terminal.MouseOff();
  Terminal.Restore();
  Terminal.Clear
END Done;

END TUI.
