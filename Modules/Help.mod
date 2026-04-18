MODULE Help;
(*
 * Context-sensitive help dialog for the IDE.
 *
 *   Help.Show(query) — open a modal window that searches stdlib.md for query.
 *
 * F1 in the IDE calls Show with the word under the cursor pre-filled.
 * The user can retype the search term and press Enter to search again.
 * Up/Down/PgUp/PgDn scroll the results; ESC closes.
 *
 * stdlib.md is located by trying:
 *   ./stdlib.md     (when the IDE is run from the repo root)
 *   ../stdlib.md    (when run from the examples/ subdirectory)
 *)

IMPORT TUI, Widgets, Strings, Files;

CONST
  MaxHLines = 500;
  HLEN      = 256;   (* max bytes per stored result line *)

VAR
  hWin:      TUI.Window;
  hSearch:   Widgets.InputLine;
  hRunning:  BOOLEAN;
  hDX, hDY, hDW, hDH: INTEGER;
  hContentH: INTEGER;   (* visible content rows *)

  hLines:  ARRAY MaxHLines, HLEN OF CHAR;
  hNLines: INTEGER;
  hScroll: INTEGER;

(* ════════════════════════════════════════════════════════════════
   Utilities
   ════════════════════════════════════════════════════════════════ *)

(* Case-insensitive substring search: does line contain query? *)
PROCEDURE ContainsIC(line, query: ARRAY OF CHAR): BOOLEAN;
VAR qlen, llen, i, j: INTEGER;
    lc, qc: CHAR;
BEGIN
  qlen := Strings.Length(query);
  llen := Strings.Length(line);
  IF qlen = 0 THEN  RETURN TRUE  END;
  i := 0;
  WHILE i <= llen - qlen DO
    j := 0;
    WHILE j < qlen DO
      lc := line[i + j];  qc := query[j];
      IF (lc >= 'A') & (lc <= 'Z') THEN  lc := CHR(ORD(lc) + 32)  END;
      IF (qc >= 'A') & (qc <= 'Z') THEN  qc := CHR(ORD(qc) + 32)  END;
      IF lc # qc THEN  j := qlen + 1  ELSE  INC(j)  END
    END;
    IF j = qlen THEN  RETURN TRUE  END;
    INC(i)
  END;
  RETURN FALSE
END ContainsIC;

(* Try to locate stdlib.md and return its path. *)
PROCEDURE FindStdlib(VAR path: ARRAY OF CHAR): BOOLEAN;
BEGIN
  IF Files.Exists("stdlib.md") THEN
    Strings.Copy("stdlib.md", path);  RETURN TRUE
  END;
  IF Files.Exists("../stdlib.md") THEN
    Strings.Copy("../stdlib.md", path);  RETURN TRUE
  END;
  RETURN FALSE
END FindStdlib;

(* Append line to hLines[], word-wrapping at hDW-4 characters.
   Continuation chunks are not indented — caller formats headings separately. *)
PROCEDURE AddLine(line: ARRAY OF CHAR);
VAR len, pos, wrap, sp, n: INTEGER;
BEGIN
  len  := Strings.Length(line);
  wrap := hDW - 4;
  IF wrap < 40 THEN  wrap := 40  END;
  IF len = 0 THEN
    IF hNLines < MaxHLines THEN
      hLines[hNLines][0] := 0X;  INC(hNLines)
    END;
    RETURN
  END;
  pos := 0;
  WHILE (pos < len) & (hNLines < MaxHLines) DO
    n := len - pos;
    IF n > wrap THEN
      (* Find last space at or before the wrap column *)
      sp := pos + wrap;
      WHILE (sp > pos) & (line[sp] # ' ') DO  DEC(sp)  END;
      IF sp <= pos THEN  sp := pos + wrap  END;   (* hard break if no space *)
      n := sp - pos
    END;
    Strings.Extract(line, pos, n, hLines[hNLines]);
    INC(hNLines);
    INC(pos, n);
    WHILE (pos < len) & (line[pos] = ' ') DO  INC(pos)  END   (* skip break space *)
  END
END AddLine;

(* ════════════════════════════════════════════════════════════════
   Search engine
   ════════════════════════════════════════════════════════════════ *)

(* Process one line from stdlib.md: detect headings, check match, store. *)
PROCEDURE ProcessLine(query, line: ARRAY OF CHAR;
                      VAR section, lastSection: ARRAY OF CHAR);
VAR isSep: BOOLEAN;
    llen: INTEGER;
BEGIN
  llen := Strings.Length(line);
  (* Track section headings: lines starting with ## (includes ###) *)
  IF (llen >= 2) & (line[0] = '#') & (line[1] = '#') THEN
    Strings.Copy(line, section)
  END;
  (* Skip Markdown table separator rows: |---... or | ---... *)
  isSep := (llen >= 2) & (line[0] = '|') &
           ((line[1] = '-') OR ((line[1] = ' ') & (llen >= 3) & (line[2] = '-')));
  IF isSep THEN  RETURN  END;
  (* If the line contains the query, store it with section context *)
  IF ContainsIC(line, query) THEN
    IF Strings.Compare(section, lastSection) # 0 THEN
      (* Blank separator before each new section *)
      IF hNLines > 0 THEN
        IF hNLines < MaxHLines THEN
          hLines[hNLines][0] := 0X;  INC(hNLines)
        END
      END;
      AddLine(section);
      Strings.Copy(section, lastSection)
    END;
    AddLine(line)
  END
END ProcessLine;

PROCEDURE LoadResults(query: ARRAY OF CHAR);
VAR path:        ARRAY 600 OF CHAR;
    f:           Files.File;
    r:           Files.Rider;
    b:           BYTE;
    line:        ARRAY 600 OF CHAR;  (* big enough for long stdlib.md table rows *)
    col:         INTEGER;
    section:     ARRAY 256 OF CHAR;
    lastSection: ARRAY 256 OF CHAR;
BEGIN
  hNLines := 0;
  hScroll := 0;

  IF Strings.Length(query) = 0 THEN
    AddLine("Type a search term and press Enter.");
    RETURN
  END;

  IF ~FindStdlib(path) THEN
    AddLine("stdlib.md not found.  Searched:");
    AddLine("  ./stdlib.md   (run from repo root)");
    AddLine("  ../stdlib.md  (run from examples/)");
    RETURN
  END;

  f := Files.Old(path);
  IF f = NIL THEN
    AddLine("Cannot open stdlib.md");
    RETURN
  END;

  section[0]     := 0X;
  lastSection[0] := 0X;
  col            := 0;

  Files.Set(r, f, 0);
  Files.Read(r, b);
  WHILE ~r.eof DO
    IF b = 10 THEN   (* newline — flush line buffer *)
      line[col] := 0X;
      ProcessLine(query, line, section, lastSection);
      col := 0
    ELSIF b # 13 THEN   (* skip CR *)
      IF col < 599 THEN  line[col] := CHR(b);  INC(col)  END
    END;
    Files.Read(r, b)
  END;
  (* Handle final line that lacks a trailing newline *)
  IF col > 0 THEN
    line[col] := 0X;
    ProcessLine(query, line, section, lastSection)
  END;
  Files.Close(f);

  IF hNLines = 0 THEN
    AddLine("No matches found for:");
    AddLine(query)
  END
END LoadResults;

(* ════════════════════════════════════════════════════════════════
   Rendering
   ════════════════════════════════════════════════════════════════ *)

(* Draw the help window's interior content.
   DrawWindow has already cleared the interior and drawn the border+title. *)
PROCEDURE DrawHelp(v: TUI.View);
VAR row, li, sy, ix, contentW: INTEGER;
    fg: INTEGER;
    hint: ARRAY 64 OF CHAR;
    tmp:  ARRAY 16 OF CHAR;
BEGIN
  WITH v: TUI.WindowRec DO
    ix       := v.x + 2;
    contentW := v.w - 4;

    (* "Search:" label — the InputLine widget draws itself on top *)
    TUI.PutStr(ix, v.y + 1, "Search:", TUI.Yellow, TUI.Black);

    (* Separator line below the search row *)
    FOR row := 0 TO v.w - 2 DO
      TUI.PutCell(v.x + 1 + row, v.y + 2, TUI.BoxH, TUI.White, TUI.Black)
    END;

    (* Result lines *)
    FOR row := 0 TO hContentH - 1 DO
      sy := v.y + 3 + row;
      li := hScroll + row;
      IF li < hNLines THEN
        (* Section headings in cyan, code lines in yellow, rest in white *)
        IF (hLines[li][0] = '#') & (hLines[li][1] = '#') THEN
          fg := TUI.Cyan
        ELSIF hLines[li][0] = '`' THEN
          fg := TUI.Yellow
        ELSE
          fg := TUI.White
        END;
        TUI.PutStr(ix - 1, sy, hLines[li], fg, TUI.Black)
      END
    END;

    (* Hint line at the last interior row *)
    sy := v.y + v.h - 2;
    TUI.FillRect(v.x + 1, sy, v.w - 2, 1, ' ', TUI.Black, TUI.White);
    Strings.Copy(" ", hint);
    Strings.IntToStr(hNLines, tmp);  Strings.Append(tmp, hint);
    Strings.Append(" lines", hint);
    IF hNLines > hContentH THEN
      Strings.Append("  PgUp/PgDn scroll", hint)
    END;
    Strings.Append("  Enter=search  ESC=close", hint);
    TUI.PutStr(v.x + 1, sy, hint, TUI.Black, TUI.White)
  END
END DrawHelp;

(* ════════════════════════════════════════════════════════════════
   Public interface
   ════════════════════════════════════════════════════════════════ *)

(**
 * Show — display the help dialog for the given query string.
 * Searches stdlib.md and shows matching entries in a scrollable window.
 * Blocks until the user presses ESC.
 *)
PROCEDURE Show*(query: ARRAY OF CHAR);
VAR ev:           TUI.Event;
    savedDesktop: TUI.View;
    savedFocus:   TUI.View;
    ch:           CHAR;
    maxScroll:    INTEGER;
    consumed:     BOOLEAN;
    titleBuf:     ARRAY 64 OF CHAR;
BEGIN
  (* Save the current desktop and focus *)
  savedDesktop := TUI.Desktop;
  savedFocus   := TUI.Focused;
  TUI.Desktop  := NIL;
  TUI.Focused  := NIL;

  (* Geometry: centred, up to 80x28 *)
  hDW := 78;  hDH := 26;
  IF TUI.Cols - 4 < hDW THEN  hDW := TUI.Cols - 4  END;
  IF TUI.Rows - 4 < hDH THEN  hDH := TUI.Rows - 4  END;
  IF hDW < 40 THEN  hDW := 40  END;
  IF hDH < 12 THEN  hDH := 12  END;
  hDX := (TUI.Cols - hDW) DIV 2 + 1;
  hDY := (TUI.Rows - hDH) DIV 2 + 1;
  (* Rows: border-top search separator [content] hint border-bottom = hDH-5 content rows *)
  hContentH := hDH - 5;

  (* Build the window *)
  NEW(hWin);
  hWin.x := hDX;  hWin.y := hDY;  hWin.w := hDW;  hWin.h := hDH;
  Strings.Copy("Help", hWin.title);
  hWin.moveable    := FALSE;
  hWin.draw        := DrawHelp;
  hWin.handle      := NIL;
  hWin.next        := NIL;
  hWin.child       := NIL;
  hWin.focused     := FALSE;
  hWin.alwaysOnTop := FALSE;

  (* Search InputLine: after "Search: " label (9 chars including space) *)
  hSearch := Widgets.NewInputLine(hDX + 10, hDY + 1, hDW - 12);

  TUI.AddView(hWin);
  TUI.AddView(hSearch);
  TUI.SetFocus(hSearch);

  (* Pre-populate search field *)
  Strings.Copy(query, hSearch.buf);
  hSearch.len := Strings.Length(query);
  hSearch.pos := hSearch.len;

  (* Load initial results and update title *)
  LoadResults(query);
  Strings.Copy("Help: ", titleBuf);
  Strings.Append(query, titleBuf);
  Strings.Copy(titleBuf, hWin.title);

  (* Modal event loop *)
  hRunning := TRUE;
  REPEAT
    TUI.ClearBack(TUI.White, TUI.Black);
    TUI.DrawAll();
    TUI.Flush();
    TUI.WaitEvent(ev);

    IF ev.kind = TUI.EvKey THEN
      ch := ev.key;
      IF ch = TUI.KEsc THEN
        hRunning := FALSE
      ELSIF ch = TUI.KEnter THEN
        (* Re-search with current InputLine content *)
        LoadResults(hSearch.buf);
        Strings.Copy("Help: ", titleBuf);
        Strings.Append(hSearch.buf, titleBuf);
        Strings.Copy(titleBuf, hWin.title)
      ELSIF ch = TUI.KUp THEN
        IF hScroll > 0 THEN  DEC(hScroll)  END
      ELSIF ch = TUI.KDown THEN
        maxScroll := hNLines - hContentH;
        IF maxScroll < 0 THEN  maxScroll := 0  END;
        IF hScroll < maxScroll THEN  INC(hScroll)  END
      ELSIF ch = TUI.KPgUp THEN
        DEC(hScroll, hContentH);
        IF hScroll < 0 THEN  hScroll := 0  END
      ELSIF ch = TUI.KPgDn THEN
        INC(hScroll, hContentH);
        maxScroll := hNLines - hContentH;
        IF maxScroll < 0 THEN  maxScroll := 0  END;
        IF hScroll > maxScroll THEN  hScroll := maxScroll  END
      ELSIF ch = TUI.KHome THEN
        hScroll := 0
      ELSIF ch = TUI.KEnd THEN
        maxScroll := hNLines - hContentH;
        IF maxScroll < 0 THEN  maxScroll := 0  END;
        hScroll := maxScroll
      ELSE
        (* All other keys (printable, backspace, arrows in input) go to the InputLine *)
        IF hSearch.handle # NIL THEN
          consumed := hSearch.handle(hSearch, ev)
        END
      END
    ELSIF ev.kind = TUI.EvMouse THEN
      IF ev.mb = 64 THEN        (* wheel up *)
        IF hScroll > 0 THEN  DEC(hScroll)  END
      ELSIF ev.mb = 65 THEN     (* wheel down *)
        maxScroll := hNLines - hContentH;
        IF maxScroll < 0 THEN  maxScroll := 0  END;
        IF hScroll < maxScroll THEN  INC(hScroll)  END
      END
    ELSIF ev.kind = TUI.EvResize THEN
      TUI.InvalidateFront()
    END
  UNTIL ~hRunning;

  (* Restore previous desktop *)
  TUI.Desktop := savedDesktop;
  TUI.SetFocus(savedFocus)
END Show;

END Help.
