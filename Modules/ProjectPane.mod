MODULE ProjectPane;
(*
 * ProjectPane — left-side file tree, Turbo-Vision style.
 *
 * A single TUI.View pinned to columns 1..PaneW that lists every editable
 * file under a project root.  Directories collapse/expand, files open in
 * a new EditorWin via a callback supplied by the IDE.
 *
 * Wiring (in IDE.mod, paraphrased)
 *   pane := ProjectPane.New(1, 2, PaneW, TUI.Rows - 2);
 *   pane.onOpenFile := OpenFileFromPane;
 *   ProjectPane.SetRoot(pane, projectRoot);
 *   TUI.AddView(pane);
 *)
IMPORT TUI, Strings, Files, OS, Out;

CONST
  MaxEntries = 2000;
  MaxDepth   = 16;
  PaneW*     = 28;

  KindDir*   = 0;
  KindFile*  = 1;

TYPE
  OpenFileProc* = PROCEDURE(path: ARRAY 512 OF CHAR);

  Entry* = RECORD
    name:     ARRAY 128 OF CHAR;
    path:     ARRAY 512 OF CHAR;
    kind:     INTEGER;
    depth:    INTEGER;
    expanded: BOOLEAN;
    scanned:  BOOLEAN;
    visible:  BOOLEAN
  END;

  Pane*    = POINTER TO PaneRec;
  PaneRec* = RECORD (TUI.ViewRec)
    root:       ARRAY 512 OF CHAR;
    entries:    ARRAY MaxEntries OF Entry;
    nEntries:   INTEGER;
    sel:        INTEGER;
    scroll:     INTEGER;
    onOpenFile: OpenFileProc
  END;

(* ── Filename filtering ─────────────────────────────────────────── *)

PROCEDURE EndsWith(name, suffix: ARRAY OF CHAR): BOOLEAN;
VAR nl, sl, i: INTEGER;
BEGIN
  sl := Strings.Length(suffix);
  IF sl = 0 THEN  RETURN TRUE  END;
  nl := Strings.Length(name);
  IF nl < sl THEN  RETURN FALSE  END;
  FOR i := 0 TO sl - 1 DO
    IF name[nl - sl + i] # suffix[i] THEN  RETURN FALSE  END
  END;
  RETURN TRUE
END EndsWith;

PROCEDURE IsSkipDir(name: ARRAY OF CHAR): BOOLEAN;
BEGIN
  IF name[0] = '.' THEN  RETURN TRUE  END;
  RETURN (Strings.Compare(name, "target")       = 0) OR
         (Strings.Compare(name, "build")        = 0) OR
         (Strings.Compare(name, "node_modules") = 0) OR
         (Strings.Compare(name, "__pycache__")  = 0)
END IsSkipDir;

PROCEDURE IsShownFile(name: ARRAY OF CHAR): BOOLEAN;
BEGIN
  IF name[0] = '.' THEN  RETURN FALSE  END;
  RETURN EndsWith(name, ".mod")  OR
         EndsWith(name, ".md")   OR
         EndsWith(name, ".txt")  OR
         EndsWith(name, "Makefile")
END IsShownFile;

(* ── Path utilities ─────────────────────────────────────────────── *)

PROCEDURE JoinPath(dir, name: ARRAY OF CHAR; VAR out: ARRAY OF CHAR);
VAR n: INTEGER;
BEGIN
  Strings.Copy(dir, out);
  n := Strings.Length(out);
  IF (n > 0) & (out[n - 1] # '/') THEN  Strings.Append("/", out)  END;
  Strings.Append(name, out)
END JoinPath;

PROCEDURE Basename(path: ARRAY OF CHAR; VAR name: ARRAY OF CHAR);
VAR i, len: INTEGER;
BEGIN
  len := Strings.Length(path);
  i   := len;
  WHILE (i > 0) & (path[i - 1] # '/') DO  DEC(i)  END;
  Strings.Extract(path, i, len - i, name)
END Basename;

(* ── Entry-list manipulation ────────────────────────────────────── *)

PROCEDURE InsertEntry(p: Pane; pos: INTEGER; VAR e: Entry);
VAR i: INTEGER;
BEGIN
  IF p.nEntries >= MaxEntries THEN  RETURN  END;
  i := p.nEntries;
  WHILE i > pos DO
    p.entries[i] := p.entries[i - 1];
    DEC(i)
  END;
  p.entries[pos] := e;
  INC(p.nEntries)
END InsertEntry;

PROCEDURE RemoveRange(p: Pane; from, count: INTEGER);
VAR i: INTEGER;
BEGIN
  IF count <= 0 THEN  RETURN  END;
  i := from;
  WHILE i + count < p.nEntries DO
    p.entries[i] := p.entries[i + count];
    INC(i)
  END;
  DEC(p.nEntries, count)
END RemoveRange;

(* Insert all children of entries[parentIdx] right after it. *)
PROCEDURE ExpandDir(p: Pane; parentIdx: INTEGER);
VAR names:     ARRAY 256 OF ARRAY 128 OF CHAR;
    kinds:     ARRAY 256 OF INTEGER;
    n, i, insertAt, childDepth: INTEGER;
    parentPath: ARRAY 512 OF CHAR;
    e: Entry;
    keep: BOOLEAN;
    cmd: ARRAY 1024 OF CHAR;
    f: Files.File;  r: Files.Rider;  b: BYTE;
    buf: ARRAY 128 OF CHAR;
    col, rc, nameLen: INTEGER;
BEGIN
  IF p.entries[parentIdx].kind # KindDir THEN  RETURN  END;
  Strings.Copy(p.entries[parentIdx].path, parentPath);
  childDepth := p.entries[parentIdx].depth + 1;
  IF childDepth >= MaxDepth THEN  RETURN  END;

  n := 0;
  Strings.Copy("ls -1Ap '", cmd);
  Strings.Append(parentPath, cmd);
  Strings.Append("' > .obc_dirlist 2>/dev/null", cmd);
  rc := OS.Exec(cmd);
  IF rc = 0 THEN
    f := Files.Old(".obc_dirlist");
    IF f # NIL THEN
      Files.Set(r, f, 0);
      col := 0;
      Files.Read(r, b);
      WHILE ~r.eof DO
        IF b = 10 THEN
          buf[col] := 0X;
          nameLen  := col;
          IF (nameLen > 0) & (n < 256) THEN
            IF buf[nameLen - 1] = '/' THEN
              buf[nameLen - 1] := 0X;
              kinds[n] := KindDir
            ELSE
              kinds[n] := KindFile
            END;
            Strings.Copy(buf, names[n]);
            INC(n)
          END;
          col := 0
        ELSIF col < 127 THEN
          buf[col] := CHR(b);  INC(col)
        END;
        Files.Read(r, b)
      END;
      Files.Close(f)
    END
  END;

  insertAt := parentIdx + 1;

  FOR i := n - 1 TO 0 BY -1 DO
    IF kinds[i] = KindFile THEN
      keep := IsShownFile(names[i])
    ELSE
      keep := ~IsSkipDir(names[i])
    END;
    IF keep & (kinds[i] = KindFile) THEN
      Strings.Copy(names[i], e.name);
      JoinPath(parentPath, names[i], e.path);
      e.kind     := KindFile;
      e.depth    := childDepth;
      e.expanded := FALSE;
      e.scanned  := FALSE;
      e.visible  := TRUE;
      InsertEntry(p, insertAt, e)
    END
  END;
  FOR i := n - 1 TO 0 BY -1 DO
    IF (kinds[i] = KindDir) & ~IsSkipDir(names[i]) THEN
      Strings.Copy(names[i], e.name);
      JoinPath(parentPath, names[i], e.path);
      e.kind     := KindDir;
      e.depth    := childDepth;
      e.expanded := FALSE;
      e.scanned  := FALSE;
      e.visible  := TRUE;
      InsertEntry(p, insertAt, e)
    END
  END;

  p.entries[parentIdx].expanded := TRUE;
  p.entries[parentIdx].scanned  := TRUE
END ExpandDir;

PROCEDURE CollapseDir(p: Pane; parentIdx: INTEGER);
VAR i, count, parentDepth: INTEGER;
BEGIN
  IF p.entries[parentIdx].kind # KindDir THEN  RETURN  END;
  parentDepth := p.entries[parentIdx].depth;
  i     := parentIdx + 1;
  count := 0;
  WHILE (i < p.nEntries) & (p.entries[i].depth > parentDepth) DO
    INC(i);  INC(count)
  END;
  RemoveRange(p, parentIdx + 1, count);
  p.entries[parentIdx].expanded := FALSE
END CollapseDir;

(* ── Public API ─────────────────────────────────────────────────── *)

PROCEDURE SetRoot*(p: Pane; root: ARRAY OF CHAR);
VAR e: Entry;
    absRoot: ARRAY 512 OF CHAR;
    cwd:     ARRAY 512 OF CHAR;
    n: INTEGER;
BEGIN
  IF root[0] = '/' THEN
    Strings.Copy(root, absRoot)
  ELSE
    OS.GetCwd(cwd);
    n := Strings.Length(cwd);
    IF (n > 0) & (cwd[n - 1] # '/') THEN  Strings.Append("/", cwd)  END;
    Strings.Copy(cwd, absRoot);
    Strings.Append(root, absRoot)
  END;

  Strings.Copy(absRoot, p.root);
  p.nEntries := 0;
  p.sel      := 0;
  p.scroll   := 0;

  Basename(absRoot, e.name);
  IF e.name[0] = 0X THEN  Strings.Copy("/", e.name)  END;
  Strings.Copy(absRoot, e.path);
  e.kind     := KindDir;
  e.depth    := 0;
  e.expanded := FALSE;
  e.scanned  := FALSE;
  e.visible  := TRUE;
  InsertEntry(p, 0, e);
  ExpandDir(p, 0)
END SetRoot;

PROCEDURE Refresh*(p: Pane);
VAR rootPath: ARRAY 512 OF CHAR;
BEGIN
  Strings.Copy(p.root, rootPath);
  SetRoot(p, rootPath)
END Refresh;

(* ── Rendering ──────────────────────────────────────────────────── *)

PROCEDURE DrawPane(v: TUI.View);
VAR p: Pane;
    innerX, innerY, innerW, innerH, row, idx, indentX, nameMax: INTEGER;
    borderFg, borderBg, fg, bg: INTEGER;
    glyph: CHAR;
    nameBuf: ARRAY 128 OF CHAR;
BEGIN
  WITH v: PaneRec DO  p := v  END;
  innerX := p.x + 1;
  innerY := p.y + 1;
  innerW := p.w - 2;
  innerH := p.h - 2;

  IF p.focused THEN
    borderFg := TUI.White;  borderBg := TUI.Blue
  ELSE
    borderFg := TUI.White;  borderBg := TUI.Black
  END;

  TUI.FillRect(innerX, innerY, innerW, innerH, ' ', TUI.White, TUI.Black);
  TUI.DrawBox(p.x, p.y, p.w, p.h, borderFg, borderBg);
  TUI.PutStr(p.x + 2, p.y, " Project ", TUI.Yellow, borderBg);

  FOR row := 0 TO innerH - 1 DO
    idx := p.scroll + row;
    IF idx < p.nEntries THEN
      IF idx = p.sel THEN
        fg := TUI.Black;  bg := TUI.Cyan
      ELSE
        fg := TUI.White;  bg := TUI.Black
      END;
      TUI.FillRect(innerX, innerY + row, innerW, 1, ' ', fg, bg);

      indentX := innerX + p.entries[idx].depth * 2;
      IF p.entries[idx].kind = KindDir THEN
        IF p.entries[idx].expanded THEN  glyph := '-'  ELSE  glyph := '+'  END
      ELSE
        glyph := ' '
      END;
      IF indentX < innerX + innerW THEN
        TUI.PutCell(indentX, innerY + row, glyph, fg, bg)
      END;

      nameMax := innerW - (indentX - innerX) - 2;
      IF nameMax > 0 THEN
        Strings.Extract(p.entries[idx].name, 0, nameMax, nameBuf);
        TUI.PutStr(indentX + 2, innerY + row, nameBuf, fg, bg)
      END
    END
  END
END DrawPane;

(* ── Event handling ─────────────────────────────────────────────── *)

PROCEDURE EnsureSelVisible(p: Pane);
VAR innerH: INTEGER;
BEGIN
  innerH := p.h - 2;
  IF p.sel < p.scroll THEN  p.scroll := p.sel  END;
  IF p.sel >= p.scroll + innerH THEN  p.scroll := p.sel - innerH + 1  END;
  IF p.scroll < 0 THEN  p.scroll := 0  END
END EnsureSelVisible;

PROCEDURE ActivateSel(p: Pane);
VAR pathCopy: ARRAY 512 OF CHAR;
BEGIN
  IF (p.sel < 0) OR (p.sel >= p.nEntries) THEN  RETURN  END;
  IF p.entries[p.sel].kind = KindDir THEN
    IF p.entries[p.sel].expanded THEN  CollapseDir(p, p.sel)
    ELSE  ExpandDir(p, p.sel)
    END
  ELSE
    IF p.onOpenFile # NIL THEN
      Strings.Copy(p.entries[p.sel].path, pathCopy);
      p.onOpenFile(pathCopy)
    END
  END
END ActivateSel;

PROCEDURE HandlePane(v: TUI.View; ev: TUI.Event): BOOLEAN;
VAR p: Pane;
    ch: CHAR;
    innerH, clickIdx: INTEGER;
BEGIN
  WITH v: PaneRec DO  p := v  END;

  IF ev.kind = TUI.EvKey THEN
    ch := ev.key;
    IF ch = TUI.KUp THEN
      IF p.sel > 0 THEN  DEC(p.sel);  EnsureSelVisible(p)  END
    ELSIF ch = TUI.KDown THEN
      IF p.sel < p.nEntries - 1 THEN  INC(p.sel);  EnsureSelVisible(p)  END
    ELSIF ch = TUI.KPgUp THEN
      innerH := p.h - 2;
      DEC(p.sel, innerH);  IF p.sel < 0 THEN  p.sel := 0  END;
      EnsureSelVisible(p)
    ELSIF ch = TUI.KPgDn THEN
      innerH := p.h - 2;
      INC(p.sel, innerH);
      IF p.sel >= p.nEntries THEN  p.sel := p.nEntries - 1  END;
      EnsureSelVisible(p)
    ELSIF ch = TUI.KHome THEN
      p.sel := 0;  EnsureSelVisible(p)
    ELSIF ch = TUI.KEnd THEN
      p.sel := p.nEntries - 1;  EnsureSelVisible(p)
    ELSIF (ch = TUI.KEnter) OR (ch = TUI.KRight) THEN
      ActivateSel(p)
    ELSIF ch = TUI.KLeft THEN
      IF (p.sel < p.nEntries) & (p.entries[p.sel].kind = KindDir) &
         p.entries[p.sel].expanded THEN
        CollapseDir(p, p.sel)
      ELSE
        WHILE (p.sel > 0) &
              (p.entries[p.sel - 1].depth >= p.entries[p.sel].depth) DO
          DEC(p.sel)
        END;
        IF p.sel > 0 THEN  DEC(p.sel)  END;
        EnsureSelVisible(p)
      END
    END;
    RETURN TRUE

  ELSIF ev.kind = TUI.EvMouse THEN
    IF ev.mb = 64 THEN
      IF p.scroll > 0 THEN  DEC(p.scroll, 3) END;
      IF p.scroll < 0 THEN  p.scroll := 0 END;
      RETURN TRUE
    ELSIF ev.mb = 65 THEN
      INC(p.scroll, 3);
      IF p.scroll > p.nEntries - 1 THEN  p.scroll := p.nEntries - 1 END;
      RETURN TRUE
    ELSIF (ev.mb = 0) &
          (ev.mx >= p.x + 1) & (ev.mx <= p.x + p.w - 2) &
          (ev.my >= p.y + 1) & (ev.my <= p.y + p.h - 2) THEN
      clickIdx := p.scroll + (ev.my - p.y - 1);
      IF (clickIdx >= 0) & (clickIdx < p.nEntries) THEN
        IF clickIdx = p.sel THEN
          ActivateSel(p)
        ELSE
          p.sel := clickIdx
        END
      END;
      RETURN TRUE
    END
  END;
  RETURN FALSE
END HandlePane;

(* ── Constructor ────────────────────────────────────────────────── *)

PROCEDURE New*(x, y, w, h: INTEGER): Pane;
VAR p: Pane;
BEGIN
  NEW(p);
  p.x := x;  p.y := y;  p.w := w;  p.h := h;
  p.draw         := DrawPane;
  p.handle       := HandlePane;
  p.next         := NIL;
  p.child        := NIL;
  p.focused      := FALSE;
  p.alwaysOnTop  := FALSE;
  p.nEntries     := 0;
  p.sel          := 0;
  p.scroll       := 0;
  p.root[0]      := 0X;
  p.onOpenFile   := NIL;
  RETURN p
END New;

END ProjectPane.
