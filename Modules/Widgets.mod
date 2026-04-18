MODULE Widgets;
(*
 * Standard TUI widgets built on TUI.ViewRec.
 *
 * Label      — static single-line text
 * Button     — focusable; Enter/Space fires cmd via TUI.ModalResult or onClick
 * InputLine  — single-line text entry with cursor and horizontal scroll
 * ListBox    — scrollable item list with keyboard + mouse navigation
 * CheckBox   — togglable boolean
 * StaticText — multi-line read-only text (newline-delimited)
 * StatusLine — bottom hint bar
 * MenuBar    — top menu bar with dropdown menus
 *
 * All widgets are POINTER TO RECORD (TUI.ViewRec), so they can be
 * added to TUI.Desktop directly.  Use the New* constructors to allocate
 * and wire up the draw/handle proc variables.
 *
 * Command-code convention
 * ────────────────────────
 *   Button.cmd and MenuBar item cmd values are application-defined integers.
 *   The standard codes CmdOK / CmdCancel / CmdYes / CmdNo are provided as
 *   a starting point.  When an onClick / onCmd callback is NIL the widget
 *   writes the cmd into TUI.ModalResult so RunModal can return it.
 *)
IMPORT TUI, Strings;

CONST
  MaxItemText*  = 64;
  MaxItems*     = 256;
  MaxMenus*     = 8;
  MaxMenuItems* = 16;

  (* Standard dialog command codes *)
  CmdOK*     = 1;
  CmdCancel* = 2;
  CmdYes*    = 3;
  CmdNo*     = 4;

TYPE
  CmdProc* = PROCEDURE(cmd: INTEGER);

  (* ── Label ───────────────────────────────────────────────────────────── *)
  Label* = POINTER TO LabelRec;
  LabelRec* = RECORD (TUI.ViewRec)
    text*: ARRAY 128 OF CHAR;
    fg*, bg*: INTEGER
  END;

  (* ── Button ──────────────────────────────────────────────────────────── *)
  Button* = POINTER TO ButtonRec;
  ButtonRec* = RECORD (TUI.ViewRec)
    text*:    ARRAY 64 OF CHAR;
    cmd*:     INTEGER;
    onClick*: CmdProc   (* if NIL, sets TUI.ModalResult := cmd *)
  END;

  (* ── InputLine ───────────────────────────────────────────────────────── *)
  InputLine* = POINTER TO InputLineRec;
  InputLineRec* = RECORD (TUI.ViewRec)
    buf*:    ARRAY 256 OF CHAR;
    len*:    INTEGER;   (* number of chars in buf          *)
    pos*:    INTEGER;   (* cursor position 0..len          *)
    scroll*: INTEGER    (* first visible column            *)
  END;

  (* ── ListBox ─────────────────────────────────────────────────────────── *)
  ListBox* = POINTER TO ListBoxRec;
  ListBoxRec* = RECORD (TUI.ViewRec)
    items*:   ARRAY MaxItems OF ARRAY MaxItemText OF CHAR;
    count*:   INTEGER;
    sel*:     INTEGER;   (* selected index          *)
    scroll*:  INTEGER;   (* index of top visible row *)
    onClick*: CmdProc    (* called with sel when Enter is pressed *)
  END;

  (* ── CheckBox ────────────────────────────────────────────────────────── *)
  CheckBox* = POINTER TO CheckBoxRec;
  CheckBoxRec* = RECORD (TUI.ViewRec)
    text*:    ARRAY 64 OF CHAR;
    checked*: BOOLEAN
  END;

  (* ── StaticText ──────────────────────────────────────────────────────── *)
  StaticText* = POINTER TO StaticTextRec;
  StaticTextRec* = RECORD (TUI.ViewRec)
    text*: ARRAY 1024 OF CHAR;
    fg*, bg*: INTEGER
  END;

  (* ── StatusLine ──────────────────────────────────────────────────────── *)
  StatusLine* = POINTER TO StatusLineRec;
  StatusLineRec* = RECORD (TUI.ViewRec)
    text*: ARRAY 256 OF CHAR
  END;

  (* ── MenuBar ─────────────────────────────────────────────────────────── *)
  MenuItemRec* = RECORD
    text*: ARRAY 32 OF CHAR;
    cmd*:  INTEGER;
    sep*:  BOOLEAN         (* separator line when TRUE *)
  END;

  MenuBar* = POINTER TO MenuBarRec;
  MenuBarRec* = RECORD (TUI.ViewRec)
    titles*:  ARRAY MaxMenus OF ARRAY 16 OF CHAR;
    items*:   ARRAY MaxMenus OF ARRAY MaxMenuItems OF MenuItemRec;
    nMenus*:  INTEGER;
    nItems*:  ARRAY MaxMenus OF INTEGER;
    active*:  INTEGER;     (* index of highlighted menu title; -1 = none *)
    open*:    BOOLEAN;     (* TRUE = dropdown is visible *)
    hotSel*:  INTEGER;     (* highlighted item in open dropdown *)
    titleX*:  ARRAY MaxMenus OF INTEGER;   (* x-start of each title, set by draw *)
    onCmd*:   CmdProc
  END;

(* ════════════════════════════════════════════════════════════════════════
   Helpers
   ════════════════════════════════════════════════════════════════════════ *)

(* InputLineAdjust — keep cursor visible inside the field. *)
PROCEDURE InputLineAdjust(VAR il: InputLineRec);
BEGIN
  IF il.pos < il.scroll THEN
    il.scroll := il.pos
  ELSIF il.pos >= il.scroll + il.w THEN
    il.scroll := il.pos - il.w + 1
  END
END InputLineAdjust;

(* MenuDropWidth — compute the dropdown width for menu m. *)
PROCEDURE MenuDropWidth(VAR mb: MenuBarRec; m: INTEGER): INTEGER;
VAR i, w, tl: INTEGER;
BEGIN
  w := 8;
  FOR i := 0 TO mb.nItems[m] - 1 DO
    tl := Strings.Length(mb.items[m][i].text) + 4;
    IF tl > w THEN w := tl END
  END;
  RETURN w
END MenuDropWidth;

(* ════════════════════════════════════════════════════════════════════════
   Draw procedures
   ════════════════════════════════════════════════════════════════════════ *)

PROCEDURE DrawLabel(v: TUI.View);
BEGIN
  WITH v: LabelRec DO
    TUI.FillRect(v.x, v.y, v.w, 1, ' ', v.fg, v.bg);
    TUI.PutStr(v.x, v.y, v.text, v.fg, v.bg)
  END
END DrawLabel;

PROCEDURE DrawButton(v: TUI.View);
VAR fg, bg, tx, tl: INTEGER;
BEGIN
  WITH v: ButtonRec DO
    IF v.focused THEN fg := TUI.Black;  bg := TUI.White
    ELSE              fg := TUI.White;  bg := TUI.Black
    END;
    TUI.FillRect(v.x, v.y, v.w, 1, ' ', fg, bg);
    TUI.PutCell(v.x,          v.y, '[', TUI.White, bg);
    TUI.PutCell(v.x + v.w - 1, v.y, ']', TUI.White, bg);
    tl := Strings.Length(v.text);
    tx := v.x + (v.w - tl) DIV 2;
    IF tx < v.x + 2 THEN tx := v.x + 2 END;
    TUI.PutStr(tx, v.y, v.text, fg, bg)
  END
END DrawButton;

PROCEDURE DrawInputLine(v: TUI.View);
VAR i, cx, fg, bg: INTEGER;
    ch: CHAR;
BEGIN
  WITH v: InputLineRec DO
    IF v.focused THEN fg := TUI.Black; bg := TUI.Cyan
    ELSE              fg := TUI.White; bg := TUI.Black
    END;
    TUI.FillRect(v.x, v.y, v.w, 1, ' ', fg, bg);
    i  := v.scroll;
    cx := v.x;
    WHILE (i < v.len) & (cx < v.x + v.w) DO
      TUI.PutCell(cx, v.y, v.buf[i], fg, bg);
      INC(i);  INC(cx)
    END;
    (* Cursor block when focused *)
    IF v.focused THEN
      cx := v.x + v.pos - v.scroll;
      IF (cx >= v.x) & (cx < v.x + v.w) THEN
        IF v.pos < v.len THEN ch := v.buf[v.pos]
        ELSE ch := ' '
        END;
        TUI.PutCell(cx, v.y, ch, TUI.White, TUI.Blue)
      END
    END
  END
END DrawInputLine;

PROCEDURE DrawListBox(v: TUI.View);
VAR i, row, fg, bg: INTEGER;
BEGIN
  WITH v: ListBoxRec DO
    TUI.FillRect(v.x, v.y, v.w, v.h, ' ', TUI.White, TUI.Black);
    FOR i := 0 TO v.h - 1 DO
      row := v.scroll + i;
      IF row < v.count THEN
        IF row = v.sel THEN
          fg := TUI.Black;  bg := TUI.Cyan
        ELSE
          fg := TUI.White;  bg := TUI.Black
        END;
        TUI.FillRect(v.x, v.y + i, v.w, 1, ' ', fg, bg);
        TUI.PutStr(v.x + 1, v.y + i, v.items[row], fg, bg)
      END
    END
  END
END DrawListBox;

PROCEDURE DrawCheckBox(v: TUI.View);
VAR fg, bg: INTEGER;
BEGIN
  WITH v: CheckBoxRec DO
    IF v.focused THEN fg := TUI.Yellow; bg := TUI.Black
    ELSE              fg := TUI.White;  bg := TUI.Black
    END;
    TUI.PutCell(v.x,     v.y, '[', fg, bg);
    IF v.checked THEN
      TUI.PutCell(v.x + 1, v.y, 'X', TUI.Green, bg)
    ELSE
      TUI.PutCell(v.x + 1, v.y, ' ', fg, bg)
    END;
    TUI.PutCell(v.x + 2, v.y, ']', fg, bg);
    TUI.PutCell(v.x + 3, v.y, ' ', fg, bg);
    TUI.PutStr(v.x + 4,  v.y, v.text, fg, bg)
  END
END DrawCheckBox;

PROCEDURE DrawStaticText(v: TUI.View);
VAR i, row, col: INTEGER;
    ch: CHAR;
BEGIN
  WITH v: StaticTextRec DO
    TUI.FillRect(v.x, v.y, v.w, v.h, ' ', v.fg, v.bg);
    i := 0;  row := 0;  col := 0;
    WHILE (v.text[i] # 0X) & (row < v.h) DO
      ch := v.text[i];
      IF ch = 0AX THEN       (* newline — advance to next row *)
        INC(row);  col := 0
      ELSE
        IF col < v.w THEN
          TUI.PutCell(v.x + col, v.y + row, ch, v.fg, v.bg)
        END;
        INC(col)
      END;
      INC(i)
    END
  END
END DrawStaticText;

PROCEDURE DrawStatusLine(v: TUI.View);
BEGIN
  WITH v: StatusLineRec DO
    TUI.FillRect(v.x, v.y, v.w, 1, ' ', TUI.Black, TUI.White);
    TUI.PutStr(v.x + 1, v.y, v.text, TUI.Black, TUI.White)
  END
END DrawStatusLine;

PROCEDURE DrawMenuBar(v: TUI.View);
VAR i, j, x, tl, dw, dh, di, itemY: INTEGER;
BEGIN
  WITH v: MenuBarRec DO
    (* ── Menu bar row ─────────────────────────────────────────────── *)
    TUI.FillRect(v.x, v.y, v.w, 1, ' ', TUI.Black, TUI.Cyan);
    x := v.x + 1;
    FOR i := 0 TO v.nMenus - 1 DO
      v.titleX[i] := x;
      tl := Strings.Length(v.titles[i]);
      IF i = v.active THEN
        TUI.PutCell(x - 1,      v.y, ' ', TUI.White, TUI.Blue);
        TUI.PutStr (x,          v.y, v.titles[i], TUI.White, TUI.Blue);
        TUI.PutCell(x + tl,     v.y, ' ', TUI.White, TUI.Blue)
      ELSE
        TUI.PutCell(x - 1,      v.y, ' ', TUI.Black, TUI.Cyan);
        TUI.PutStr (x,          v.y, v.titles[i], TUI.Black, TUI.Cyan);
        TUI.PutCell(x + tl,     v.y, ' ', TUI.Black, TUI.Cyan)
      END;
      x := x + tl + 2
    END;
    (* ── Dropdown ─────────────────────────────────────────────────── *)
    IF v.open & (v.active >= 0) & (v.active < v.nMenus) THEN
      dw := MenuDropWidth(v, v.active);
      dh := v.nItems[v.active] + 2;
      x  := v.titleX[v.active];
      TUI.DrawBox(x, v.y + 1, dw, dh, TUI.White, TUI.Black);
      TUI.FillRect(x + 1, v.y + 2, dw - 2, dh - 2, ' ', TUI.White, TUI.Black);
      FOR di := 0 TO v.nItems[v.active] - 1 DO
        itemY := v.y + 2 + di;
        IF v.items[v.active][di].sep THEN
          (* Separator line *)
          FOR j := x + 1 TO x + dw - 2 DO
            TUI.PutCell(j, itemY, TUI.BoxH, TUI.White, TUI.Black)
          END
        ELSIF di = v.hotSel THEN
          TUI.FillRect(x + 1, itemY, dw - 2, 1, ' ', TUI.Black, TUI.Cyan);
          TUI.PutStr(x + 2, itemY, v.items[v.active][di].text, TUI.Black, TUI.Cyan)
        ELSE
          TUI.PutStr(x + 2, itemY, v.items[v.active][di].text, TUI.White, TUI.Black)
        END
      END
    END
  END
END DrawMenuBar;

(* ════════════════════════════════════════════════════════════════════════
   Handle procedures
   ════════════════════════════════════════════════════════════════════════ *)

PROCEDURE HandleButton(v: TUI.View; ev: TUI.Event): BOOLEAN;
BEGIN
  WITH v: ButtonRec DO
    IF ev.kind = TUI.EvKey THEN
      IF (ev.key = TUI.KEnter) OR (ev.key = ' ') THEN
        IF v.onClick # NIL THEN
          v.onClick(v.cmd)
        ELSE
          TUI.ModalResult := v.cmd
        END;
        RETURN TRUE
      END
    ELSIF ev.kind = TUI.EvMouse THEN
      IF (ev.my = v.y) & (ev.mx >= v.x) & (ev.mx < v.x + v.w) THEN
        IF v.onClick # NIL THEN
          v.onClick(v.cmd)
        ELSE
          TUI.ModalResult := v.cmd
        END;
        RETURN TRUE
      END
    END
  END;
  RETURN FALSE
END HandleButton;

PROCEDURE HandleInputLine(v: TUI.View; ev: TUI.Event): BOOLEAN;
VAR i, k: INTEGER;
BEGIN
  WITH v: InputLineRec DO
    IF ev.kind = TUI.EvKey THEN
      k := ORD(ev.key);
      IF (k >= 32) & (k < 127) THEN
        IF v.len < 255 THEN
          i := v.len;
          WHILE i > v.pos DO v.buf[i] := v.buf[i - 1];  DEC(i) END;
          v.buf[v.pos]      := ev.key;
          v.buf[v.len + 1]  := 0X;
          INC(v.len);  INC(v.pos);
          InputLineAdjust(v)
        END;
        RETURN TRUE
      ELSIF ev.key = TUI.KBackspace THEN
        IF v.pos > 0 THEN
          i := v.pos - 1;
          WHILE i < v.len - 1 DO v.buf[i] := v.buf[i + 1];  INC(i) END;
          DEC(v.len);  v.buf[v.len] := 0X;  DEC(v.pos);
          InputLineAdjust(v)
        END;
        RETURN TRUE
      ELSIF ev.key = TUI.KDel THEN
        IF v.pos < v.len THEN
          i := v.pos;
          WHILE i < v.len - 1 DO v.buf[i] := v.buf[i + 1];  INC(i) END;
          DEC(v.len);  v.buf[v.len] := 0X;
          InputLineAdjust(v)
        END;
        RETURN TRUE
      ELSIF ev.key = TUI.KLeft THEN
        IF v.pos > 0 THEN  DEC(v.pos);  InputLineAdjust(v)  END;
        RETURN TRUE
      ELSIF ev.key = TUI.KRight THEN
        IF v.pos < v.len THEN  INC(v.pos);  InputLineAdjust(v)  END;
        RETURN TRUE
      ELSIF ev.key = TUI.KHome THEN
        v.pos := 0;  v.scroll := 0;
        RETURN TRUE
      ELSIF ev.key = TUI.KEnd THEN
        v.pos := v.len;  InputLineAdjust(v);
        RETURN TRUE
      END
    END
  END;
  RETURN FALSE
END HandleInputLine;

PROCEDURE HandleListBox(v: TUI.View; ev: TUI.Event): BOOLEAN;
VAR row: INTEGER;
BEGIN
  WITH v: ListBoxRec DO
    IF ev.kind = TUI.EvKey THEN
      IF ev.key = TUI.KUp THEN
        IF v.sel > 0 THEN
          DEC(v.sel);
          IF v.sel < v.scroll THEN  v.scroll := v.sel  END
        END;
        RETURN TRUE
      ELSIF ev.key = TUI.KDown THEN
        IF v.sel < v.count - 1 THEN
          INC(v.sel);
          IF v.sel >= v.scroll + v.h THEN  v.scroll := v.sel - v.h + 1  END
        END;
        RETURN TRUE
      ELSIF ev.key = TUI.KPgUp THEN
        v.sel := v.sel - v.h;
        IF v.sel < 0 THEN  v.sel := 0  END;
        IF v.sel < v.scroll THEN  v.scroll := v.sel  END;
        RETURN TRUE
      ELSIF ev.key = TUI.KPgDn THEN
        v.sel := v.sel + v.h;
        IF v.sel >= v.count THEN  v.sel := v.count - 1  END;
        IF v.sel < 0 THEN v.sel := 0 END;
        IF v.sel >= v.scroll + v.h THEN  v.scroll := v.sel - v.h + 1  END;
        RETURN TRUE
      ELSIF ev.key = TUI.KHome THEN
        v.sel := 0;  v.scroll := 0;
        RETURN TRUE
      ELSIF ev.key = TUI.KEnd THEN
        IF v.count > 0 THEN
          v.sel := v.count - 1;
          IF v.sel >= v.scroll + v.h THEN  v.scroll := v.sel - v.h + 1  END
        END;
        RETURN TRUE
      ELSIF ev.key = TUI.KEnter THEN
        IF (v.count > 0) & (v.onClick # NIL) THEN  v.onClick(v.sel)  END;
        RETURN TRUE
      END
    ELSIF ev.kind = TUI.EvMouse THEN
      IF (ev.my >= v.y) & (ev.my < v.y + v.h) &
         (ev.mx >= v.x) & (ev.mx < v.x + v.w) THEN
        row := v.scroll + (ev.my - v.y);
        IF row >= v.count THEN  row := v.count - 1  END;
        IF row >= 0 THEN  v.sel := row  END;
        RETURN TRUE
      END
    END
  END;
  RETURN FALSE
END HandleListBox;

PROCEDURE HandleCheckBox(v: TUI.View; ev: TUI.Event): BOOLEAN;
BEGIN
  WITH v: CheckBoxRec DO
    IF ev.kind = TUI.EvKey THEN
      IF (ev.key = TUI.KEnter) OR (ev.key = ' ') THEN
        v.checked := ~v.checked;
        RETURN TRUE
      END
    ELSIF ev.kind = TUI.EvMouse THEN
      IF (ev.my = v.y) & (ev.mx >= v.x) & (ev.mx < v.x + v.w) THEN
        v.checked := ~v.checked;
        RETURN TRUE
      END
    END
  END;
  RETURN FALSE
END HandleCheckBox;

PROCEDURE HandleMenuBar(v: TUI.View; ev: TUI.Event): BOOLEAN;
VAR i, tl, cmd: INTEGER;
BEGIN
  WITH v: MenuBarRec DO
    IF ev.kind = TUI.EvKey THEN
      IF ev.key = TUI.KEsc THEN
        v.open := FALSE;  v.active := -1;
        RETURN TRUE
      ELSIF ev.key = TUI.KLeft THEN
        IF v.active > 0 THEN
          DEC(v.active);  v.hotSel := 0
        ELSIF v.active = 0 THEN
          v.active := v.nMenus - 1;  v.hotSel := 0
        END;
        RETURN TRUE
      ELSIF ev.key = TUI.KRight THEN
        IF (v.active >= 0) & (v.active < v.nMenus - 1) THEN
          INC(v.active);  v.hotSel := 0
        ELSIF v.active = v.nMenus - 1 THEN
          v.active := 0;  v.hotSel := 0
        END;
        RETURN TRUE
      ELSIF ev.key = TUI.KDown THEN
        IF v.active >= 0 THEN
          IF ~v.open THEN
            v.open := TRUE;  v.hotSel := 0
          ELSIF v.hotSel < v.nItems[v.active] - 1 THEN
            INC(v.hotSel)
          END
        END;
        RETURN TRUE
      ELSIF ev.key = TUI.KUp THEN
        IF v.open & (v.hotSel > 0) THEN  DEC(v.hotSel)  END;
        RETURN TRUE
      ELSIF ev.key = TUI.KEnter THEN
        IF v.open & (v.active >= 0) THEN
          IF ~v.items[v.active][v.hotSel].sep THEN
            cmd := v.items[v.active][v.hotSel].cmd;
            v.open := FALSE;  v.active := -1;
            IF v.onCmd # NIL THEN  v.onCmd(cmd)
            ELSE  TUI.ModalResult := cmd
            END
          END
        ELSIF v.active >= 0 THEN
          v.open := TRUE;  v.hotSel := 0
        END;
        RETURN TRUE
      END
    ELSIF ev.kind = TUI.EvMouse THEN
      IF ev.my = v.y THEN
        (* Click on bar row — open / close menu *)
        FOR i := 0 TO v.nMenus - 1 DO
          tl := Strings.Length(v.titles[i]);
          IF (ev.mx >= v.titleX[i] - 1) & (ev.mx <= v.titleX[i] + tl) THEN
            IF (v.active = i) & v.open THEN
              v.open := FALSE;  v.active := -1
            ELSE
              v.active := i;  v.open := TRUE;  v.hotSel := 0
            END;
            RETURN TRUE
          END
        END
      ELSIF v.open & (v.active >= 0) THEN
        (* Click inside dropdown *)
        i := ev.my - (v.y + 2);
        IF (i >= 0) & (i < v.nItems[v.active]) THEN
          IF ~v.items[v.active][i].sep THEN
            v.hotSel := i;
            cmd := v.items[v.active][i].cmd;
            v.open := FALSE;  v.active := -1;
            IF v.onCmd # NIL THEN  v.onCmd(cmd)
            ELSE  TUI.ModalResult := cmd
            END
          END;
          RETURN TRUE
        END
      END
    END
  END;
  RETURN FALSE
END HandleMenuBar;

(* ════════════════════════════════════════════════════════════════════════
   Constructors
   ════════════════════════════════════════════════════════════════════════ *)

PROCEDURE NewLabel*(x, y, w: INTEGER; text: ARRAY OF CHAR): Label;
VAR l: Label;
BEGIN
  NEW(l);
  l.x := x;  l.y := y;  l.w := w;  l.h := 1;
  Strings.Copy(text, l.text);
  l.fg := TUI.White;  l.bg := TUI.Black;
  l.draw := DrawLabel;  l.handle := NIL;
  l.next := NIL;  l.child := NIL;  l.focused := FALSE;
  RETURN l
END NewLabel;

PROCEDURE NewButton*(x, y, w: INTEGER; text: ARRAY OF CHAR; cmd: INTEGER): Button;
VAR b: Button;
BEGIN
  NEW(b);
  b.x := x;  b.y := y;  b.w := w;  b.h := 1;
  Strings.Copy(text, b.text);
  b.cmd := cmd;  b.onClick := NIL;
  b.draw := DrawButton;  b.handle := HandleButton;
  b.next := NIL;  b.child := NIL;  b.focused := FALSE;
  RETURN b
END NewButton;

PROCEDURE NewInputLine*(x, y, w: INTEGER): InputLine;
VAR il: InputLine;
BEGIN
  NEW(il);
  il.x := x;  il.y := y;  il.w := w;  il.h := 1;
  il.buf[0] := 0X;  il.len := 0;  il.pos := 0;  il.scroll := 0;
  il.draw := DrawInputLine;  il.handle := HandleInputLine;
  il.next := NIL;  il.child := NIL;  il.focused := FALSE;
  RETURN il
END NewInputLine;

PROCEDURE NewListBox*(x, y, w, h: INTEGER): ListBox;
VAR lb: ListBox;
BEGIN
  NEW(lb);
  lb.x := x;  lb.y := y;  lb.w := w;  lb.h := h;
  lb.count := 0;  lb.sel := 0;  lb.scroll := 0;  lb.onClick := NIL;
  lb.draw := DrawListBox;  lb.handle := HandleListBox;
  lb.next := NIL;  lb.child := NIL;  lb.focused := FALSE;
  RETURN lb
END NewListBox;

(** ListBoxAdd — append an item string to a ListBox. **)
PROCEDURE ListBoxAdd*(lb: ListBox; item: ARRAY OF CHAR);
BEGIN
  IF lb.count < MaxItems THEN
    Strings.Copy(item, lb.items[lb.count]);
    INC(lb.count)
  END
END ListBoxAdd;

(** ListBoxClear — remove all items and reset selection. **)
PROCEDURE ListBoxClear*(lb: ListBox);
BEGIN
  lb.count := 0;  lb.sel := 0;  lb.scroll := 0
END ListBoxClear;

PROCEDURE NewCheckBox*(x, y: INTEGER; text: ARRAY OF CHAR; checked: BOOLEAN): CheckBox;
VAR cb: CheckBox;
BEGIN
  NEW(cb);
  cb.x := x;  cb.y := y;  cb.w := Strings.Length(text) + 4;  cb.h := 1;
  Strings.Copy(text, cb.text);
  cb.checked := checked;
  cb.draw := DrawCheckBox;  cb.handle := HandleCheckBox;
  cb.next := NIL;  cb.child := NIL;  cb.focused := FALSE;
  RETURN cb
END NewCheckBox;

PROCEDURE NewStaticText*(x, y, w, h: INTEGER; text: ARRAY OF CHAR): StaticText;
VAR st: StaticText;
BEGIN
  NEW(st);
  st.x := x;  st.y := y;  st.w := w;  st.h := h;
  Strings.Copy(text, st.text);
  st.fg := TUI.White;  st.bg := TUI.Black;
  st.draw := DrawStaticText;  st.handle := NIL;
  st.next := NIL;  st.child := NIL;  st.focused := FALSE;
  RETURN st
END NewStaticText;

PROCEDURE NewStatusLine*(x, y, w: INTEGER; text: ARRAY OF CHAR): StatusLine;
VAR sl: StatusLine;
BEGIN
  NEW(sl);
  sl.x := x;  sl.y := y;  sl.w := w;  sl.h := 1;
  Strings.Copy(text, sl.text);
  sl.draw := DrawStatusLine;  sl.handle := NIL;
  sl.next := NIL;  sl.child := NIL;  sl.focused := FALSE;
  RETURN sl
END NewStatusLine;

PROCEDURE NewMenuBar*(x, y, w: INTEGER): MenuBar;
VAR mb: MenuBar;
BEGIN
  NEW(mb);
  mb.x := x;  mb.y := y;  mb.w := w;  mb.h := 1;
  mb.nMenus := 0;  mb.active := -1;  mb.open := FALSE;
  mb.hotSel := 0;  mb.onCmd := NIL;
  mb.draw := DrawMenuBar;  mb.handle := HandleMenuBar;
  mb.next := NIL;  mb.child := NIL;  mb.focused := FALSE;
  mb.alwaysOnTop := TRUE;
  RETURN mb
END NewMenuBar;

(** MenuBarAddMenu — add a top-level menu title to the menu bar. **)
PROCEDURE MenuBarAddMenu*(mb: MenuBar; title: ARRAY OF CHAR);
BEGIN
  IF mb.nMenus < MaxMenus THEN
    Strings.Copy(title, mb.titles[mb.nMenus]);
    mb.nItems[mb.nMenus] := 0;
    INC(mb.nMenus)
  END
END MenuBarAddMenu;

(** MenuBarAddItem — add a command item to menu index `menu`. **)
PROCEDURE MenuBarAddItem*(mb: MenuBar; menu: INTEGER; text: ARRAY OF CHAR; cmd: INTEGER);
VAR n: INTEGER;
BEGIN
  IF (menu >= 0) & (menu < mb.nMenus) & (mb.nItems[menu] < MaxMenuItems) THEN
    n := mb.nItems[menu];
    Strings.Copy(text, mb.items[menu][n].text);
    mb.items[menu][n].cmd := cmd;
    mb.items[menu][n].sep := FALSE;
    INC(mb.nItems[menu])
  END
END MenuBarAddItem;

(** MenuBarAddSep — add a separator line to menu index `menu`. **)
PROCEDURE MenuBarAddSep*(mb: MenuBar; menu: INTEGER);
VAR n: INTEGER;
BEGIN
  IF (menu >= 0) & (menu < mb.nMenus) & (mb.nItems[menu] < MaxMenuItems) THEN
    n := mb.nItems[menu];
    mb.items[menu][n].text[0] := 0X;
    mb.items[menu][n].cmd := 0;
    mb.items[menu][n].sep := TRUE;
    INC(mb.nItems[menu])
  END
END MenuBarAddSep;

END Widgets.
