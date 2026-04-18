MODULE WidgetTest;
(*
 * Smoke test for Modules/Widgets.mod.
 *
 * Shows:  a Label, an InputLine, a ListBox, two Buttons (OK/Cancel),
 *         a CheckBox, a StatusLine, and a MenuBar.
 *
 * Keys:  Tab = cycle focus  |  Esc = quit  |  Enter on OK = quit
 *)
IMPORT TUI, Widgets;

VAR
  ev:       TUI.Event;
  running:  BOOLEAN;
  label:    Widgets.Label;
  input:    Widgets.InputLine;
  listbox:  Widgets.ListBox;
  btnOK:    Widgets.Button;
  btnCancel: Widgets.Button;
  check:    Widgets.CheckBox;
  status:   Widgets.StatusLine;
  menubar:  Widgets.MenuBar;

PROCEDURE OnQuit(cmd: INTEGER);
BEGIN
  running := FALSE
END OnQuit;

PROCEDURE OnList(idx: INTEGER);
BEGIN
  (* nothing — selection is visible via highlight *)
END OnList;

PROCEDURE HandleGlobal(v: TUI.View; ev: TUI.Event): BOOLEAN;
BEGIN
  IF ev.kind = TUI.EvKey THEN
    IF ev.key = TUI.KEsc THEN  running := FALSE;  RETURN TRUE  END
  END;
  RETURN FALSE
END HandleGlobal;

BEGIN
  TUI.Init();

  (* Menu bar at top *)
  menubar := Widgets.NewMenuBar(1, 1, TUI.Cols);
  Widgets.MenuBarAddMenu(menubar, "File");
  Widgets.MenuBarAddItem(menubar, 0, "New",    10);
  Widgets.MenuBarAddItem(menubar, 0, "Open",   11);
  Widgets.MenuBarAddSep (menubar, 0);
  Widgets.MenuBarAddItem(menubar, 0, "Quit",   Widgets.CmdCancel);
  Widgets.MenuBarAddMenu(menubar, "Edit");
  Widgets.MenuBarAddItem(menubar, 1, "Cut",    20);
  Widgets.MenuBarAddItem(menubar, 1, "Copy",   21);
  Widgets.MenuBarAddItem(menubar, 1, "Paste",  22);
  menubar.onCmd := OnQuit;

  (* Status line at bottom *)
  status := Widgets.NewStatusLine(1, TUI.Rows, TUI.Cols,
    "Tab=focus  Esc=quit  Enter=OK  F2=menu");

  (* Label *)
  label := Widgets.NewLabel(3, 3, 30, "Name:");

  (* Input line *)
  input := Widgets.NewInputLine(3, 4, 30);

  (* List box *)
  listbox := Widgets.NewListBox(3, 6, 30, 6);
  Widgets.ListBoxAdd(listbox, "Apple");
  Widgets.ListBoxAdd(listbox, "Banana");
  Widgets.ListBoxAdd(listbox, "Cherry");
  Widgets.ListBoxAdd(listbox, "Date");
  Widgets.ListBoxAdd(listbox, "Elderberry");
  Widgets.ListBoxAdd(listbox, "Fig");
  Widgets.ListBoxAdd(listbox, "Grape");
  Widgets.ListBoxAdd(listbox, "Honeydew");
  listbox.onClick := OnList;

  (* Buttons *)
  btnOK     := Widgets.NewButton(3,  13, 12, "OK",     Widgets.CmdOK);
  btnCancel := Widgets.NewButton(17, 13, 12, "Cancel", Widgets.CmdCancel);
  btnOK.onClick     := OnQuit;
  btnCancel.onClick := OnQuit;

  (* Check box *)
  check := Widgets.NewCheckBox(3, 15, "Enable feature", FALSE);

  (* Add views to desktop — added last = drawn first (back) *)
  TUI.AddView(status);
  TUI.AddView(menubar);
  TUI.AddView(check);
  TUI.AddView(btnCancel);
  TUI.AddView(btnOK);
  TUI.AddView(listbox);
  TUI.AddView(label);
  TUI.AddView(input);

  TUI.SetFocus(input);
  running := TRUE;

  REPEAT
    TUI.ClearBack(TUI.White, TUI.Black);
    TUI.DrawAll();
    TUI.Flush();
    TUI.WaitEvent(ev);
    IF TUI.Dispatch(ev) THEN END;
    IF ev.kind = TUI.EvKey THEN
      IF ev.key = TUI.KEsc THEN  running := FALSE  END
    END
  UNTIL ~running;

  TUI.Done()
END WidgetTest.
