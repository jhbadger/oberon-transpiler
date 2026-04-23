MODULE FileDialog;
(*
 * Modal file-open dialog built on TUI + Widgets.
 *
 *   ok := FileDialog.Show(title, startPath, filter, result)
 *
 *   title     — window title string (e.g. "Open File")
 *   startPath — initial directory; "" means current working directory
 *   filter    — filename suffix filter, e.g. ".mod"; "" = show all files
 *   result    — receives the full path on success (unchanged on cancel)
 *   returns TRUE if the user confirmed, FALSE if cancelled
 *
 * Navigation
 * ──────────
 *   Arrow keys / PgUp / PgDn   — move through the file list
 *   Enter on a directory        — navigate into it
 *   Enter on a file             — accept selection
 *   Tab                         — cycle focus: list → filename → OK → Cancel
 *   Esc                         — cancel
 *   OK button                   — accept (uses filename field if non-empty,
 *                                  otherwise uses selected list item)
 *   Cancel button               — cancel
 *)
IMPORT TUI, Widgets, Strings, OS;

CONST
  MaxPath = 512;
  MaxName = 256;

(* ── Module-level dialog state ─────────────────────────────────────────── *)

VAR
  fWin:       TUI.Window;
  fList:      Widgets.ListBox;
  fInput:     Widgets.InputLine;
  fBtnOK:     Widgets.Button;
  fBtnCancel: Widgets.Button;

  fFilter:  ARRAY 32 OF CHAR;
  fCurDir:  ARRAY MaxPath OF CHAR;
  fRunning: BOOLEAN;
  fOK:      BOOLEAN;

  (* geometry — set once per Show call *)
  fDX, fDY, fDW, fDH: INTEGER;

(* ── Helpers ────────────────────────────────────────────────────────────── *)

(* RefreshList — read the current directory and reload the ListBox. *)
PROCEDURE RefreshList;
VAR i, n: INTEGER;
    name: ARRAY MaxName OF CHAR;
    disp: ARRAY MaxName OF CHAR;
BEGIN
  Widgets.ListBoxClear(fList);
  OS.DirOpen(fCurDir, fFilter);
  n := OS.DirCount();
  FOR i := 0 TO n - 1 DO
    OS.DirName(i, name);
    IF OS.DirIsDir(i) THEN
      Strings.Copy(name, disp);
      Strings.Append("/", disp)
    ELSE
      Strings.Copy(name, disp)
    END;
    Widgets.ListBoxAdd(fList, disp)
  END
END RefreshList;

(* Navigate into a subdirectory and refresh. *)
PROCEDURE NavigateDir(sub: ARRAY OF CHAR);
VAR tmp: ARRAY MaxPath OF CHAR;
    slen: INTEGER;
BEGIN
  (* Strip trailing '/' if present *)
  slen := Strings.Length(sub);
  IF (slen > 0) & (sub[slen - 1] = '/') THEN
    Strings.Extract(sub, 0, slen - 1, tmp)
  ELSE
    Strings.Copy(sub, tmp)
  END;
  IF tmp[0] = '.' THEN
    IF tmp[1] = '.' THEN
      (* Go up: remove last path component *)
      slen := Strings.Length(fCurDir);
      WHILE (slen > 1) & (fCurDir[slen - 1] # '/') DO  DEC(slen)  END;
      IF slen > 1 THEN  DEC(slen)  END;   (* strip trailing slash unless root *)
      fCurDir[slen] := 0X
    END
    (* single dot: stay — do nothing *)
  ELSE
    IF fCurDir[Strings.Length(fCurDir) - 1] # '/' THEN
      Strings.Append("/", fCurDir)
    END;
    Strings.Append(tmp, fCurDir)
  END;
  RefreshList
END NavigateDir;

(* Accept — accept the current selection and close. *)
PROCEDURE Accept;
VAR name: ARRAY MaxName OF CHAR;
    full: ARRAY MaxPath OF CHAR;
    nlen: INTEGER;
BEGIN
  (* Prefer explicit filename field; fall back to list selection *)
  IF fInput.len > 0 THEN
    Strings.Copy(fInput.buf, name)
  ELSIF fList.count > 0 THEN
    Strings.Copy(fList.items[fList.sel], name);
    (* Strip trailing '/' — was a directory indicator *)
    nlen := Strings.Length(name);
    IF (nlen > 0) & (name[nlen - 1] = '/') THEN
      name[nlen - 1] := 0X;
      (* It's actually a dir — navigate instead *)
      NavigateDir(name);
      RETURN
    END
  ELSE
    RETURN
  END;
  (* Build full path *)
  Strings.Copy(fCurDir, full);
  IF full[Strings.Length(full) - 1] # '/' THEN  Strings.Append("/", full)  END;
  Strings.Append(name, full);
  Strings.Copy(full, fInput.buf);
  fInput.len := Strings.Length(fInput.buf);
  fInput.pos := fInput.len;
  fOK := TRUE;
  fRunning := FALSE
END Accept;

(* ── Button callbacks ───────────────────────────────────────────────────── *)

PROCEDURE OnOK(cmd: INTEGER);
BEGIN
  Accept
END OnOK;

PROCEDURE OnCancel(cmd: INTEGER);
BEGIN
  fRunning := FALSE
END OnCancel;

(* ── Focus cycling among dialog's 4 interactive widgets ────────────────── *)

PROCEDURE DialogFocusNext;
VAR cur: TUI.View;
BEGIN
  cur := TUI.Focused;
  IF cur = fList      THEN  TUI.SetFocus(fInput)
  ELSIF cur = fInput  THEN  TUI.SetFocus(fBtnOK)
  ELSIF cur = fBtnOK  THEN  TUI.SetFocus(fBtnCancel)
  ELSE                      TUI.SetFocus(fList)
  END
END DialogFocusNext;

(* ── Path-display draw proc for the Window ──────────────────────────────── *)
(* Draws the "Dir:" and "File:" label strings inside the Window border.    *)

PROCEDURE DrawFD(v: TUI.View);
VAR lx, dirRow, fileRow, dlen, maxw: INTEGER;
    disp: ARRAY MaxPath OF CHAR;
BEGIN
  WITH v: TUI.WindowRec DO
    lx      := v.x + 2;
    dirRow  := v.y + 2;
    fileRow := v.y + v.h - 4;
    maxw    := v.w - 10;

    TUI.PutStr(lx, dirRow, "Dir:", TUI.Yellow, TUI.Black);

    (* Truncate long paths from the left *)
    dlen := Strings.Length(fCurDir);
    IF dlen > maxw THEN
      Strings.Extract(fCurDir, dlen - maxw, maxw, disp)
    ELSE
      Strings.Copy(fCurDir, disp)
    END;
    TUI.PutStr(lx + 5, dirRow, disp, TUI.White, TUI.Black);

    TUI.PutStr(lx, fileRow, "File:", TUI.Yellow, TUI.Black)
  END
END DrawFD;

(* ── Public interface ───────────────────────────────────────────────────── *)

(**
 * Show — display the file dialog and return the selected path.
 * Returns TRUE if a file was chosen, FALSE if cancelled.
 * On TRUE, result contains the full absolute path.
 *)
PROCEDURE Show*(title, startPath, filter: ARRAY OF CHAR;
                VAR result: ARRAY OF CHAR): BOOLEAN;
VAR ev:          TUI.Event;
    savedDesktop: TUI.View;
    savedFocus:   TUI.View;
    lh, lx, ly:  INTEGER;
    consumed:     BOOLEAN;
    selName:      ARRAY MaxName OF CHAR;
    nlen:         INTEGER;
    hit:          TUI.View;
    foc:          TUI.View;
BEGIN
  (* ── Save current desktop ────────────────────────────────────────── *)
  savedDesktop := TUI.Desktop;
  savedFocus   := TUI.Focused;
  TUI.Desktop  := NIL;
  TUI.Focused  := NIL;

  (* ── Dialog geometry (centred, at least 40×16) ───────────────────── *)
  fDW := 62;  fDH := 20;
  IF TUI.Cols < fDW + 4 THEN  fDW := TUI.Cols - 4  END;
  IF TUI.Rows < fDH + 4 THEN  fDH := TUI.Rows - 4  END;
  IF fDW < 40 THEN  fDW := 40  END;
  IF fDH < 16 THEN  fDH := 16  END;
  fDX := (TUI.Cols - fDW) DIV 2 + 1;
  fDY := (TUI.Rows - fDH) DIV 2 + 1;

  lx := fDX + 1;              (* interior left edge  *)
  lh := fDH - 9;              (* list box height — leaves room for File: input below *)
  ly := fDY + 4;              (* list box top row    *)

  (* ── Initial directory ───────────────────────────────────────────── *)
  Strings.Copy(filter, fFilter);
  IF startPath[0] # 0X THEN
    Strings.Copy(startPath, fCurDir)
  ELSE
    OS.GetCwd(fCurDir)
  END;

  (* ── Create dialog Window ────────────────────────────────────────── *)
  NEW(fWin);
  fWin.x := fDX;  fWin.y := fDY;  fWin.w := fDW;  fWin.h := fDH;
  Strings.Copy(title, fWin.title);
  fWin.moveable    := FALSE;
  fWin.draw        := DrawFD;
  fWin.handle      := NIL;
  fWin.next        := NIL;
  fWin.child       := NIL;
  fWin.focused     := FALSE;
  fWin.alwaysOnTop := FALSE;

  (* ── List box ────────────────────────────────────────────────────── *)
  fList := Widgets.NewListBox(lx, ly, fDW - 2, lh);

  (* ── Filename input ──────────────────────────────────────────────── *)
  fInput := Widgets.NewInputLine(lx + 6, fDY + fDH - 4, fDW - 9);

  (* ── Buttons ─────────────────────────────────────────────────────── *)
  fBtnOK     := Widgets.NewButton(fDX + fDW DIV 2 - 13, fDY + fDH - 2,
                                  10, "OK",     Widgets.CmdOK);
  fBtnCancel := Widgets.NewButton(fDX + fDW DIV 2 -  1, fDY + fDH - 2,
                                  10, "Cancel", Widgets.CmdCancel);
  fBtnOK.onClick     := OnOK;
  fBtnCancel.onClick := OnCancel;

  (* ── Add to (clean) desktop: Window first (back), then widgets ───── *)
  TUI.AddView(fWin);
  TUI.AddView(fBtnCancel);
  TUI.AddView(fBtnOK);
  TUI.AddView(fInput);
  TUI.AddView(fList);

  (* Populate list; focus the filename input if it is empty (Save As),
     otherwise focus the list (Open, where browsing is the primary action) *)
  RefreshList;
  IF fInput.len = 0 THEN
    TUI.SetFocus(fInput)
  ELSE
    TUI.SetFocus(fList)
  END;

  (* ── Modal event loop ────────────────────────────────────────────── *)
  fRunning := TRUE;  fOK := FALSE;

  REPEAT
    TUI.ClearBack(TUI.White, TUI.Black);
    TUI.DrawAll();
    TUI.Flush();
    TUI.WaitEvent(ev);

    IF ev.kind = TUI.EvKey THEN
      IF ev.key = TUI.KEsc THEN
        fRunning := FALSE
      ELSIF ev.key = TUI.KTab THEN
        DialogFocusNext
      ELSIF ev.key = TUI.KEnter THEN
        foc := TUI.Focused;
        IF foc = fList THEN
          (* Enter on list: navigate if dir, accept if file *)
          IF fList.count > 0 THEN
            Strings.Copy(fList.items[fList.sel], selName);
            nlen := Strings.Length(selName);
            IF (nlen > 0) & (selName[nlen - 1] = '/') THEN
              NavigateDir(selName)
            ELSE
              Strings.Copy(selName, fInput.buf);
              fInput.len := nlen;
              fInput.pos := nlen;
              Accept
            END
          END
        ELSE
          (* Enter on other widgets: route to their handle proc *)
          IF (foc # NIL) & (foc.handle # NIL) THEN
            consumed := foc.handle(foc, ev)
          END
        END
      ELSE
        (* All other keys go to the focused widget *)
        foc := TUI.Focused;
        IF (foc # NIL) & (foc.handle # NIL) THEN
          consumed := foc.handle(foc, ev)
        END
      END
    ELSIF ev.kind = TUI.EvMouse THEN
      (* Ignore motion and release; only act on real clicks *)
      IF (ev.mb # 32) & (ev.mb # 3) THEN
        hit := TUI.HitTest(ev.mx, ev.my);
        IF hit # NIL THEN
          IF hit # TUI.Focused THEN  TUI.SetFocus(hit)  END;
          IF hit.handle # NIL THEN
            consumed := hit.handle(hit, ev)
          END
        END
      END
    ELSIF ev.kind = TUI.EvResize THEN
      TUI.InvalidateFront
    END
  UNTIL ~fRunning;

  (* ── Copy result before we tear down ────────────────────────────── *)
  IF fOK THEN  Strings.Copy(fInput.buf, result)  END;

  (* ── Restore desktop ─────────────────────────────────────────────── *)
  TUI.Desktop := savedDesktop;
  TUI.SetFocus(savedFocus);

  RETURN fOK
END Show;

END FileDialog.
