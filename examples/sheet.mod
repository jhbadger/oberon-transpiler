MODULE sheet;
(*
 * sheet — a terminal spreadsheet using DataFrame for storage.
 *
 * Keys:
 *   Arrows / mouse     navigate
 *   Enter / F2         edit current cell
 *   Delete             clear current cell
 *   Ctrl+O             open a CSV/TSV file
 *   Ctrl+S             save CSV or TSV (by extension; prompts if no filename)
 *   Ctrl+L             reload from disk
 *   Ctrl+N             new empty sheet
 *   Esc / Ctrl+Q       quit
 *
 * Formulas (start with =):
 *   =A1               cell reference
 *   =A1+B2*3.14       arithmetic  (+  -  *  /)
 *   =SUM(A1:A10)      range functions: SUM AVG MIN MAX COUNT
 *   =(A1+B1)/2        parentheses
 *)

IMPORT DataFrame, Terminal, Graphics, Strings, Files, Args, Out;

CONST
  COLW     = 12;   (* data-column display width *)
  ROWW     = 5;    (* row-number field width *)
  MAXDEPTH = 16;   (* formula recursion depth limit *)

  NORMAL = 0;  EDIT = 1;

  (* 256-colour palette *)
  CLR_TEXT  = 255;
  CLR_HDR   = 15;   BG_HDR  = 24;   (* white on blue *)
  CLR_SEL   = 0;    BG_SEL  = 226;  (* black on yellow *)
  CLR_FML   = 51;   BG_FML  = 0;    (* cyan on black *)
  CLR_NORM  = 255;  BG_NORM = 0;    (* white on black *)
  CLR_ROW   = 244;  BG_ROW  = 0;    (* grey row numbers *)
  CLR_BAR   = 15;   BG_BAR  = 236;  (* white on dark *)
  CLR_HELP  = 250;  BG_HELP = 238;  (* light grey on dark *)

  KEY_UP    = 1;   KEY_DOWN  = 2;
  KEY_LEFT  = 3;   KEY_RIGHT = 4;
  KEY_MOUSE = 5;
  KEY_BS    = 8;   KEY_TAB   = 9;
  KEY_ENTER = 13;  KEY_ESC   = 27;
  KEY_PGUP  = 258; KEY_PGDN  = 259;
  KEY_HOME  = 256; KEY_END   = 257;
  KEY_DEL   = 260;
  KEY_F2    = 265; (* mapped below from ORD 265 … handled via terminal *)
  KEY_CTRL_O = 15;
  KEY_CTRL_S = 19;
  KEY_CTRL_L = 12;
  KEY_CTRL_N = 14;
  KEY_CTRL_Q = 17;

VAR
  df        : DataFrame.DataFrame;
  fname     : ARRAY 256 OF CHAR;
  dirty     : BOOLEAN;
  curRow    : INTEGER;  (* 0-based cursor *)
  curCol    : INTEGER;
  scrRow    : INTEGER;  (* 0-based scroll offset *)
  scrCol    : INTEGER;
  tCols     : INTEGER;  (* terminal dimensions *)
  tRows     : INTEGER;
  visRows   : INTEGER;  (* data rows visible in pane *)
  visCols   : INTEGER;  (* data cols visible *)
  mode      : INTEGER;
  editBuf   : ARRAY 256 OF CHAR;
  editPos   : INTEGER;
  statusMsg : ARRAY 128 OF CHAR;
  running   : BOOLEAN;
  (* formula parser state (module-level for mutual calls) *)
  fmStr     : ARRAY 256 OF CHAR;
  fmPos     : INTEGER;
  fmErr     : BOOLEAN;
  fmDepth   : INTEGER;

(* ── column label: 0→"A", 25→"Z", 26→"AA" ─────────────────────── *)
PROCEDURE ColLabel(c: INTEGER; VAR s: ARRAY OF CHAR);
BEGIN
  IF c < 26 THEN
    s[0] := CHR(ORD('A') + c); s[1] := 0X
  ELSE
    s[0] := CHR(ORD('A') + c DIV 26 - 1);
    s[1] := CHR(ORD('A') + c MOD 26);
    s[2] := 0X
  END
END ColLabel;

(* ── cell address: (0,0)→"A1" ──────────────────────────────────── *)
PROCEDURE CellAddr(r, c: INTEGER; VAR s: ARRAY OF CHAR);
VAR col: ARRAY 4 OF CHAR; n: ARRAY 8 OF CHAR;
BEGIN
  ColLabel(c, col);
  Strings.IntToStr(r + 1, n);
  COPY(col, s); Strings.Append(n, s)
END CellAddr;

(* ── parse "A"/"AB" from fmStr at fmPos, return 0-based index ──── *)
PROCEDURE ParseColLabel(): INTEGER;
VAR c: INTEGER;
BEGIN
  c := -1;
  IF (fmStr[fmPos] >= 'A') & (fmStr[fmPos] <= 'Z') THEN
    c := ORD(fmStr[fmPos]) - ORD('A'); INC(fmPos);
    IF (fmStr[fmPos] >= 'A') & (fmStr[fmPos] <= 'Z') THEN
      c := (c + 1) * 26 + ORD(fmStr[fmPos]) - ORD('A'); INC(fmPos)
    END
  END;
  RETURN c
END ParseColLabel;

(* ── formula: parser helpers ────────────────────────────────────── *)
PROCEDURE FmPeek(): CHAR; BEGIN RETURN fmStr[fmPos] END FmPeek;

PROCEDURE FmGet(): CHAR;
VAR c: CHAR;
BEGIN c := fmStr[fmPos]; IF c # 0X THEN INC(fmPos) END; RETURN c END FmGet;

PROCEDURE FmSkipWS();
BEGIN WHILE fmStr[fmPos] = ' ' DO INC(fmPos) END END FmSkipWS;

(* ── get numeric value of cell (r,c), evaluating formulas ───────── *)
PROCEDURE EvalCell(r, c, depth: INTEGER): REAL;
VAR raw: ARRAY DataFrame.CELLLEN OF CHAR;
    val: REAL; ok: BOOLEAN;
    saved: ARRAY 256 OF CHAR; savedPos: INTEGER; savedErr: BOOLEAN;
BEGIN
  IF depth > MAXDEPTH THEN RETURN 0.0 END;
  IF (r < 0) OR (r >= DataFrame.NRows(df)) OR
     (c < 0) OR (c >= DataFrame.NCols(df)) THEN RETURN 0.0 END;
  DataFrame.GetStr(df, r, c, raw);
  IF raw[0] = '=' THEN
    (* save parser state — formulas can be nested *)
    COPY(fmStr, saved); savedPos := fmPos; savedErr := fmErr;
    COPY(raw, fmStr); fmPos := 1; fmErr := FALSE;
    INC(fmDepth);
    val := ParseAdd();
    DEC(fmDepth);
    COPY(saved, fmStr); fmPos := savedPos; fmErr := savedErr;
    RETURN val
  ELSE
    ok := Strings.StrToReal(raw, val);
    IF ok THEN RETURN val END;
    ok := DataFrame.GetReal(df, r, c, val);
    IF ok THEN RETURN val END;
    RETURN 0.0
  END
END EvalCell;

(* ── range: collect cells A1:B3 into a result ───────────────────── *)
PROCEDURE RangeFunc(fname2: ARRAY OF CHAR): REAL;
VAR r1, c1, r2, c2, r, c: INTEGER;
    v, acc: REAL; n: INTEGER;
    kind: INTEGER;  (* 0=SUM 1=AVG 2=MIN 3=MAX 4=COUNT *)
BEGIN
  kind := -1;
  IF Strings.Compare(fname2, "SUM")   = 0 THEN kind := 0
  ELSIF Strings.Compare(fname2, "AVG") = 0 THEN kind := 1
  ELSIF Strings.Compare(fname2, "MIN") = 0 THEN kind := 2
  ELSIF Strings.Compare(fname2, "MAX") = 0 THEN kind := 3
  ELSIF Strings.Compare(fname2, "COUNT") = 0 THEN kind := 4
  END;
  IF kind < 0 THEN fmErr := TRUE; RETURN 0.0 END;
  IF FmGet() # '(' THEN fmErr := TRUE; RETURN 0.0 END;
  FmSkipWS();
  c1 := ParseColLabel();
  r1 := 0;
  WHILE (fmStr[fmPos] >= '0') & (fmStr[fmPos] <= '9') DO
    r1 := r1 * 10 + ORD(fmStr[fmPos]) - ORD('0'); INC(fmPos)
  END;
  DEC(r1);  (* 1-based → 0-based *)
  FmSkipWS();
  IF FmGet() # ':' THEN fmErr := TRUE; RETURN 0.0 END;
  FmSkipWS();
  c2 := ParseColLabel();
  r2 := 0;
  WHILE (fmStr[fmPos] >= '0') & (fmStr[fmPos] <= '9') DO
    r2 := r2 * 10 + ORD(fmStr[fmPos]) - ORD('0'); INC(fmPos)
  END;
  DEC(r2);
  FmSkipWS();
  IF FmGet() # ')' THEN fmErr := TRUE; RETURN 0.0 END;
  (* evaluate range *)
  acc := 0.0; n := 0;
  IF kind = 2 THEN acc := 1.0E30  END;
  IF kind = 3 THEN acc := -1.0E30 END;
  FOR r := r1 TO r2 DO
    FOR c := c1 TO c2 DO
      v := EvalCell(r, c, fmDepth);
      INC(n);
      IF kind = 0 THEN acc := acc + v END;
      IF kind = 1 THEN acc := acc + v END;
      IF (kind = 2) & (v < acc) THEN acc := v END;
      IF (kind = 3) & (v > acc) THEN acc := v END;
      IF kind = 4 THEN (* n counts *) END
    END
  END;
  IF kind = 1 THEN IF n > 0 THEN acc := acc / n ELSE acc := 0.0 END END;
  IF kind = 4 THEN acc := n END;
  RETURN acc
END RangeFunc;

(* ── recursive descent formula parser ──────────────────────────── *)
PROCEDURE ParsePrimary(): REAL;
VAR v: REAL; neg: BOOLEAN;
    name: ARRAY 16 OF CHAR; ni: INTEGER;
    col, row: INTEGER;
    ok: BOOLEAN; s: ARRAY 32 OF CHAR;
BEGIN
  FmSkipWS();
  v := 0.0; neg := FALSE;
  IF FmPeek() = '-' THEN neg := TRUE; FmGet() ELSIF FmPeek() = '+' THEN FmGet() END;
  FmSkipWS();
  IF FmPeek() = '(' THEN
    FmGet();
    v := ParseAdd();
    FmSkipWS();
    IF FmPeek() = ')' THEN FmGet() ELSE fmErr := TRUE END
  ELSIF (FmPeek() >= 'A') & (FmPeek() <= 'Z') THEN
    (* function name or cell reference *)
    ni := 0;
    WHILE (FmPeek() >= 'A') & (FmPeek() <= 'Z') & (ni < 14) DO
      name[ni] := FmGet(); INC(ni)
    END;
    name[ni] := 0X;
    FmSkipWS();
    IF FmPeek() = '(' THEN
      (* function call *)
      v := RangeFunc(name)
    ELSIF (FmPeek() >= '0') & (FmPeek() <= '9') THEN
      (* looks like a cell ref — reparse the column from name *)
      (* col is encoded in name (1 or 2 chars already parsed) *)
      IF (ni = 1) THEN col := ORD(name[0]) - ORD('A')
      ELSIF (ni = 2) THEN
        col := (ORD(name[0]) - ORD('A') + 1) * 26 + ORD(name[1]) - ORD('A')
      ELSE col := -1
      END;
      row := 0;
      WHILE (FmPeek() >= '0') & (FmPeek() <= '9') DO
        row := row * 10 + ORD(FmGet()) - ORD('0')
      END;
      DEC(row);  (* 1-based → 0-based *)
      v := EvalCell(row, col, fmDepth)
    ELSE
      v := 0.0  (* unknown identifier *)
    END
  ELSIF ((FmPeek() >= '0') & (FmPeek() <= '9')) OR (FmPeek() = '.') THEN
    (* numeric literal *)
    ni := 0;
    WHILE (ni < 30) & ((FmPeek() >= '0') & (FmPeek() <= '9') OR
          (FmPeek() = '.') OR (FmPeek() = 'e') OR (FmPeek() = 'E') OR
          ((FmPeek() = '-') OR (FmPeek() = '+')) &
          ((ni > 0) & ((s[ni-1] = 'e') OR (s[ni-1] = 'E')))) DO
      s[ni] := FmGet(); INC(ni)
    END;
    s[ni] := 0X;
    ok := Strings.StrToReal(s, v);
    IF ~ok THEN v := 0.0 END
  END;
  IF neg THEN v := -v END;
  RETURN v
END ParsePrimary;

PROCEDURE ParseMul(): REAL;
VAR v, r: REAL; op: CHAR;
BEGIN
  v := ParsePrimary();
  FmSkipWS();
  WHILE (FmPeek() = '*') OR (FmPeek() = '/') DO
    op := FmGet(); FmSkipWS();
    r := ParsePrimary(); FmSkipWS();
    IF op = '*' THEN v := v * r
    ELSIF r # 0.0 THEN v := v / r
    END
  END;
  RETURN v
END ParseMul;

PROCEDURE ParseAdd(): REAL;
VAR v, r: REAL; op: CHAR;
BEGIN
  v := ParseMul();
  FmSkipWS();
  WHILE (FmPeek() = '+') OR (FmPeek() = '-') DO
    op := FmGet(); FmSkipWS();
    r := ParseMul(); FmSkipWS();
    IF op = '+' THEN v := v + r ELSE v := v - r END
  END;
  RETURN v
END ParseAdd;

(* ── evaluate formula/cell to a display string ──────────────────── *)
PROCEDURE CellDisplay(r, c: INTEGER; VAR out: ARRAY OF CHAR);
VAR raw: ARRAY DataFrame.CELLLEN OF CHAR;
    val: REAL;
    ns: ARRAY 32 OF CHAR;
BEGIN
  IF (r < 0) OR (r >= DataFrame.NRows(df)) OR
     (c < 0) OR (c >= DataFrame.NCols(df)) THEN
    out[0] := 0X; RETURN
  END;
  DataFrame.GetStr(df, r, c, raw);
  IF raw[0] # '=' THEN
    COPY(raw, out); RETURN
  END;
  (* evaluate *)
  COPY(raw, fmStr); fmPos := 1; fmErr := FALSE; fmDepth := 1;
  val := ParseAdd();
  IF fmErr THEN COPY("#ERR", out)
  ELSE
    Strings.RealToStr(val, ns);
    COPY(ns, out)
  END
END CellDisplay;

(* ── ensure df has at least r rows and c cols ───────────────────── *)
PROCEDURE EnsureSize(r, c: INTEGER);
VAR i: INTEGER;
BEGIN
  WHILE DataFrame.NCols(df) <= c DO
    i := DataFrame.AddCol(df, "")
  END;
  WHILE DataFrame.NRows(df) <= r DO
    i := DataFrame.AddRow(df)
  END
END EnsureSize;

(* ── set visible dimensions from terminal size ───────────────────── *)
PROCEDURE CalcVis();
BEGIN
  tCols := Terminal.Cols();
  tRows := Terminal.Rows();
  (* rows: 1 formula bar + 1 col header + data rows + 1 help bar *)
  visRows := tRows - 3;
  IF visRows < 1 THEN visRows := 1 END;
  (* cols: ROWW+1 for row number, then (COLW+1) per data col *)
  visCols := (tCols - ROWW - 1) DIV (COLW + 1);
  IF visCols < 1 THEN visCols := 1 END
END CalcVis;

(* ── clamp scroll so cursor is visible ──────────────────────────── *)
PROCEDURE ClampScroll();
BEGIN
  IF curRow < scrRow THEN scrRow := curRow END;
  IF curRow >= scrRow + visRows THEN scrRow := curRow - visRows + 1 END;
  IF curCol < scrCol THEN scrCol := curCol END;
  IF curCol >= scrCol + visCols THEN scrCol := curCol - visCols + 1 END;
  IF scrRow < 0 THEN scrRow := 0 END;
  IF scrCol < 0 THEN scrCol := 0 END
END ClampScroll;

(* ── screen: x position of left edge of data column c (0-based abs) *)
PROCEDURE ColX(c: INTEGER): INTEGER;
BEGIN RETURN ROWW + 1 + (c - scrCol) * (COLW + 1) + 1 END ColX;

(* ── screen: y position of data row r (0-based abs) ─────────────── *)
PROCEDURE RowY(r: INTEGER): INTEGER;
BEGIN RETURN (r - scrRow) + 3 END RowY;

(* ── draw one padded cell ───────────────────────────────────────── *)
PROCEDURE PadPrint(s: ARRAY OF CHAR; w: INTEGER);
VAR i, len: INTEGER;
BEGIN
  len := Strings.Length(s);
  IF len > w THEN len := w; s[len] := 0X END;
  Out.String(s);
  FOR i := len TO w - 1 DO Out.Char(' ') END
END PadPrint;

(* ── draw column-header row ─────────────────────────────────────── *)
PROCEDURE DrawColHeaders();
VAR c, x: INTEGER; lbl: ARRAY 4 OF CHAR;
BEGIN
  Graphics.Goto(1, 2);
  Graphics.Color256(CLR_HDR, BG_HDR);
  (* row-number gutter *)
  FOR x := 1 TO ROWW DO Out.Char(' ') END;
  Out.Char('|');
  FOR c := scrCol TO scrCol + visCols - 1 DO
    ColLabel(c, lbl);
    PadPrint(lbl, COLW);
    Out.Char('|')
  END;
  (* pad to edge *)
  x := ROWW + 1 + visCols * (COLW + 1) + 1;
  WHILE x <= tCols DO Out.Char(' '); INC(x) END;
  Graphics.Reset
END DrawColHeaders;

(* ── draw one data row ──────────────────────────────────────────── *)
PROCEDURE DrawDataRow(r: INTEGER);
VAR c, y: INTEGER;
    val: ARRAY DataFrame.CELLLEN OF CHAR;
    raw: ARRAY DataFrame.CELLLEN OF CHAR;
    rn:  ARRAY 8 OF CHAR;
    isFormula, isSel: BOOLEAN;
BEGIN
  y := RowY(r);
  IF (y < 3) OR (y > tRows - 1) THEN RETURN END;
  Graphics.Goto(1, y);
  (* row number *)
  Graphics.Color256(CLR_ROW, BG_ROW);
  Strings.IntToStr(r + 1, rn);
  FOR c := Strings.Length(rn) TO ROWW - 2 DO Out.Char(' ') END;
  Out.String(rn); Out.Char('|');
  (* cells *)
  FOR c := scrCol TO scrCol + visCols - 1 DO
    isSel := (r = curRow) & (c = curCol);
    isFormula := FALSE;
    IF (r < DataFrame.NRows(df)) & (c < DataFrame.NCols(df)) THEN
      DataFrame.GetStr(df, r, c, raw);
      isFormula := (raw[0] = '=');
      CellDisplay(r, c, val)
    ELSE
      val[0] := 0X
    END;
    IF isSel THEN
      Graphics.Color256(CLR_SEL, BG_SEL)
    ELSIF isFormula THEN
      Graphics.Color256(CLR_FML, BG_FML)
    ELSE
      Graphics.Color256(CLR_NORM, BG_NORM)
    END;
    PadPrint(val, COLW);
    Graphics.Color256(CLR_HDR, BG_HDR);
    Out.Char('|')
  END;
  (* pad remainder of line *)
  Graphics.Color256(CLR_NORM, BG_NORM);
  c := ROWW + 1 + visCols * (COLW + 1) + 1;
  WHILE c <= tCols DO Out.Char(' '); INC(c) END;
  Graphics.Reset
END DrawDataRow;

(* ── formula / edit bar (row 1) ─────────────────────────────────── *)
PROCEDURE DrawFormulaBar();
VAR addr: ARRAY 8 OF CHAR; raw: ARRAY DataFrame.CELLLEN OF CHAR;
    i, x: INTEGER;
BEGIN
  Graphics.Goto(1, 1);
  Graphics.Color256(CLR_BAR, BG_BAR);
  CellAddr(curRow, curCol, addr);
  Out.String(addr); Out.String(": ");
  x := Strings.Length(addr) + 3;
  IF mode = EDIT THEN
    (* show edit buffer with cursor *)
    FOR i := 0 TO editPos - 1 DO Out.Char(editBuf[i]); INC(x) END;
    Out.Char('_'); INC(x);
    i := editPos;
    WHILE editBuf[i] # 0X DO Out.Char(editBuf[i]); INC(i); INC(x) END
  ELSE
    IF (curRow < DataFrame.NRows(df)) & (curCol < DataFrame.NCols(df)) THEN
      DataFrame.GetStr(df, curRow, curCol, raw);
      Out.String(raw); INC(x, Strings.Length(raw))
    END
  END;
  WHILE x <= tCols DO Out.Char(' '); INC(x) END;
  IF statusMsg[0] # 0X THEN
    (* right-aligned status in formula bar *)
    Graphics.Goto(tCols - Strings.Length(statusMsg) - 1, 1);
    Out.String(statusMsg)
  END;
  Graphics.Reset
END DrawFormulaBar;

(* ── help bar (last row) ────────────────────────────────────────── *)
PROCEDURE DrawHelp();
VAR x: INTEGER; s: ARRAY 128 OF CHAR;
BEGIN
  Graphics.Goto(1, tRows);
  Graphics.Color256(CLR_HELP, BG_HELP);
  IF mode = EDIT THEN
    s := "Enter:confirm  Esc:cancel  Backspace:delete"
  ELSE
    s := "Arrows/Mouse:nav  Enter:edit  Del:clear  ^O:open  ^S:save  ^L:reload  ^Q:quit"
  END;
  PadPrint(s, tCols - 1);
  Graphics.Reset
END DrawHelp;

(* ── full redraw ─────────────────────────────────────────────────── *)
PROCEDURE DrawAll();
VAR r: INTEGER;
BEGIN
  CalcVis();
  Graphics.Clear();
  DrawFormulaBar();
  DrawColHeaders();
  FOR r := scrRow TO scrRow + visRows - 1 DO
    DrawDataRow(r)
  END;
  DrawHelp()
END DrawAll;

(* ── partial redraw: just current cell (after move) ─────────────── *)
PROCEDURE RedrawCur();
BEGIN
  DrawFormulaBar();
  DrawDataRow(curRow)
END RedrawCur;

(* ── save to CSV ─────────────────────────────────────────────────── *)
PROCEDURE SaveCSV(fn: ARRAY OF CHAR): BOOLEAN;
VAR f: Files.File; r2: Files.Rider;
    r, c, nr, nc: INTEGER;
    cell: ARRAY DataFrame.CELLLEN OF CHAR;
BEGIN
  f := Files.New(fn);
  IF f = NIL THEN RETURN FALSE END;
  Files.Set(r2, f, 0);
  nc := DataFrame.NCols(df); nr := DataFrame.NRows(df);
  FOR r := 0 TO nr - 1 DO
    FOR c := 0 TO nc - 1 DO
      IF c > 0 THEN Files.Write(r2, ',') END;
      DataFrame.GetStr(df, r, c, cell);
      (* quote field if it contains comma *)
      IF Strings.Pos(",", cell, 0) >= 0 THEN
        Files.Write(r2, 022X);  (* " *)
        Files.WriteString(r2, cell);
        Files.Write(r2, 022X)  (* " *)
      ELSE
        Files.WriteString(r2, cell)
      END
    END;
    Files.Write(r2, 0AX)
  END;
  Files.Register(f); Files.Close(f);
  RETURN TRUE
END SaveCSV;

(* ── save to TSV ─────────────────────────────────────────────────── *)
PROCEDURE SaveTSV(fn: ARRAY OF CHAR): BOOLEAN;
VAR f: Files.File; r2: Files.Rider;
    r, c, nr, nc: INTEGER;
    cell: ARRAY DataFrame.CELLLEN OF CHAR;
BEGIN
  f := Files.New(fn);
  IF f = NIL THEN RETURN FALSE END;
  Files.Set(r2, f, 0);
  nc := DataFrame.NCols(df); nr := DataFrame.NRows(df);
  FOR r := 0 TO nr - 1 DO
    FOR c := 0 TO nc - 1 DO
      IF c > 0 THEN Files.Write(r2, 09X) END;
      DataFrame.GetStr(df, r, c, cell);
      Files.WriteString(r2, cell)
    END;
    Files.Write(r2, 0AX)
  END;
  Files.Register(f); Files.Close(f);
  RETURN TRUE
END SaveTSV;

(* ── true if filename has .tsv extension ────────────────────────── *)
PROCEDURE IsTSV(fn: ARRAY OF CHAR): BOOLEAN;
VAR n: INTEGER;
BEGIN
  n := Strings.Length(fn) - 4;
  RETURN (n >= 0) & (fn[n] = '.') & (fn[n+1] = 't') &
         (fn[n+2] = 's') & (fn[n+3] = 'v')
END IsTSV;

(* ── move cursor, keeping it in sheet bounds ────────────────────── *)
PROCEDURE MoveTo(r, c: INTEGER);
VAR prevRow, prevCol: INTEGER;
BEGIN
  prevRow := curRow; prevCol := curCol;
  IF r < 0 THEN r := 0 END;
  IF c < 0 THEN c := 0 END;
  IF r >= DataFrame.MAXROWS THEN r := DataFrame.MAXROWS - 1 END;
  IF c >= DataFrame.MAXCOLS THEN c := DataFrame.MAXCOLS - 1 END;
  curRow := r; curCol := c;
  ClampScroll()
END MoveTo;

(* ── commit edit buffer to cell ─────────────────────────────────── *)
PROCEDURE CommitEdit();
BEGIN
  EnsureSize(curRow, curCol);
  DataFrame.SetStr(df, curRow, curCol, editBuf);
  dirty := TRUE;
  mode := NORMAL
END CommitEdit;

(* ── enter edit mode ─────────────────────────────────────────────── *)
PROCEDURE StartEdit(replaceContent: BOOLEAN);
VAR raw: ARRAY DataFrame.CELLLEN OF CHAR;
BEGIN
  mode := EDIT;
  IF replaceContent THEN
    editBuf[0] := 0X; editPos := 0
  ELSE
    IF (curRow < DataFrame.NRows(df)) & (curCol < DataFrame.NCols(df)) THEN
      DataFrame.GetStr(df, curRow, curCol, raw);
      COPY(raw, editBuf)
    ELSE
      editBuf[0] := 0X
    END;
    editPos := Strings.Length(editBuf)
  END
END StartEdit;

(* ── handle a key in EDIT mode ──────────────────────────────────── *)
PROCEDURE HandleEdit(k: INTEGER);
VAR i, len: INTEGER;
BEGIN
  IF k = KEY_ENTER THEN
    CommitEdit();
    MoveTo(curRow + 1, curCol)
  ELSIF k = KEY_ESC THEN
    mode := NORMAL
  ELSIF k = KEY_BS THEN
    IF editPos > 0 THEN
      DEC(editPos); len := Strings.Length(editBuf);
      i := editPos;
      WHILE i < len DO editBuf[i] := editBuf[i+1]; INC(i) END;
      editBuf[len-1] := 0X
    END
  ELSIF k = KEY_DEL THEN
    len := Strings.Length(editBuf);
    IF editPos < len THEN
      i := editPos;
      WHILE i < len DO editBuf[i] := editBuf[i+1]; INC(i) END;
      editBuf[len-1] := 0X
    END
  ELSIF k = KEY_LEFT THEN
    IF editPos > 0 THEN DEC(editPos) END
  ELSIF k = KEY_RIGHT THEN
    IF editBuf[editPos] # 0X THEN INC(editPos) END
  ELSIF k = KEY_HOME THEN
    editPos := 0
  ELSIF k = KEY_END THEN
    editPos := Strings.Length(editBuf)
  ELSIF (k >= 32) & (k < 127) THEN
    (* insert printable character *)
    len := Strings.Length(editBuf);
    IF len < 254 THEN
      i := len;
      WHILE i > editPos DO editBuf[i] := editBuf[i-1]; DEC(i) END;
      editBuf[editPos] := CHR(k); INC(editPos);
      editBuf[len+1] := 0X
    END
  END
END HandleEdit;

(* ── prompt user for a string (displayed in formula bar) ─────────── *)
PROCEDURE Prompt(prompt: ARRAY OF CHAR; VAR result: ARRAY OF CHAR): BOOLEAN;
VAR i, j, plen, x: INTEGER;
BEGIN
  result[0] := 0X;  i := 0;
  plen := Strings.Length(prompt);
  LOOP
    Graphics.Goto(1, 1);
    Graphics.Color256(CLR_SEL, BG_SEL);
    x := 1;
    WHILE x <= tCols DO Out.Char(' '); INC(x) END;
    Graphics.Goto(1, 1);
    Out.String(prompt);  Out.String(result);
    Graphics.Reset;
    Graphics.Goto(plen + i + 1, 1);
    j := GetKey();
    IF j = KEY_ENTER THEN RETURN i > 0
    ELSIF j = KEY_ESC THEN result[0] := 0X; RETURN FALSE
    ELSIF j = KEY_BS THEN IF i > 0 THEN DEC(i); result[i] := 0X END
    ELSIF (j >= 32) & (j < 127) & (i < LEN(result) - 1) THEN
      result[i] := CHR(j); INC(i); result[i] := 0X
    END
  END
END Prompt;

(* ── handle a key in NORMAL mode ───────────────────────────────── *)
PROCEDURE HandleNormal(k: INTEGER);
VAR nr, nc: INTEGER;
    s: ARRAY DataFrame.CELLLEN OF CHAR;
    ok: BOOLEAN;
BEGIN
  nr := DataFrame.NRows(df); nc := DataFrame.NCols(df);
  IF k = KEY_UP    THEN MoveTo(curRow - 1, curCol)
  ELSIF k = KEY_DOWN  THEN MoveTo(curRow + 1, curCol)
  ELSIF k = KEY_LEFT  THEN MoveTo(curRow, curCol - 1)
  ELSIF k = KEY_RIGHT THEN MoveTo(curRow, curCol + 1)
  ELSIF k = KEY_TAB   THEN MoveTo(curRow, curCol + 1)
  ELSIF k = KEY_PGUP  THEN MoveTo(curRow - visRows, curCol)
  ELSIF k = KEY_PGDN  THEN MoveTo(curRow + visRows, curCol)
  ELSIF k = KEY_HOME  THEN MoveTo(curRow, 0)
  ELSIF k = KEY_END   THEN MoveTo(curRow, nc - 1)
  ELSIF k = KEY_ENTER THEN StartEdit(FALSE)
  ELSIF k = KEY_DEL   THEN
    IF (curRow < nr) & (curCol < nc) THEN
      DataFrame.SetStr(df, curRow, curCol, ""); dirty := TRUE
    END
  ELSIF k = KEY_CTRL_S THEN
    IF fname[0] = 0X THEN
      IF ~Prompt("Save as: ", fname) THEN fname[0] := 0X END
    END;
    IF fname[0] # 0X THEN
      IF IsTSV(fname) THEN ok := SaveTSV(fname)
      ELSE ok := SaveCSV(fname)
      END;
      IF ok THEN COPY("Saved.", statusMsg); dirty := FALSE
      ELSE COPY("Save failed!", statusMsg)
      END
    END
  ELSIF k = KEY_CTRL_L THEN
    IF fname[0] # 0X THEN
      IF IsTSV(fname) THEN
        df := DataFrame.LoadTSV(fname, FALSE, nc)
      ELSE
        df := DataFrame.LoadCSV(fname, FALSE, nc)
      END;
      IF df = NIL THEN df := DataFrame.Create() END;
      dirty := FALSE; curRow := 0; curCol := 0;
      scrRow := 0; scrCol := 0;
      COPY("Reloaded.", statusMsg)
    END
  ELSIF k = KEY_CTRL_N THEN
    df := DataFrame.Create();
    fname[0] := 0X; dirty := FALSE;
    curRow := 0; curCol := 0; scrRow := 0; scrCol := 0;
    COPY("New sheet.", statusMsg)
  ELSIF k = KEY_CTRL_O THEN
    IF Prompt("Open: ", fname) THEN
      IF IsTSV(fname) THEN
        df := DataFrame.LoadTSV(fname, FALSE, nc)
      ELSE
        df := DataFrame.LoadCSV(fname, FALSE, nc)
      END;
      IF df = NIL THEN df := DataFrame.Create(); COPY("New file.", statusMsg)
      ELSE dirty := FALSE; curRow := 0; curCol := 0;
        scrRow := 0; scrCol := 0; COPY("Opened.", statusMsg)
      END
    ELSE
      fname[0] := 0X
    END
  ELSIF (k = KEY_CTRL_Q) OR (k = KEY_ESC) THEN
    running := FALSE
  ELSIF (k >= 32) & (k < 127) THEN
    (* start editing with typed char *)
    StartEdit(TRUE);
    HandleEdit(k)
  END
END HandleNormal;

(* ── handle mouse click ─────────────────────────────────────────── *)
PROCEDURE HandleMouse();
VAR mx, my, btn, c, r: INTEGER;
BEGIN
  mx  := Terminal.MouseX();
  my  := Terminal.MouseY();
  btn := Terminal.MouseBtn();
  IF btn = 3 THEN RETURN END;  (* release *)
  IF my = 1 THEN  (* click on formula bar → enter edit mode *)
    IF mode = NORMAL THEN StartEdit(FALSE) END;
    RETURN
  END;
  IF my < 3 THEN RETURN END;  (* column header or formula bar *)
  (* map terminal coords → data row/col *)
  r := scrRow + (my - 3);
  c := scrCol + (mx - ROWW - 2) DIV (COLW + 1);
  IF c < 0 THEN c := 0 END;
  IF r < 0 THEN r := 0 END;
  IF mode = EDIT THEN CommitEdit() END;
  MoveTo(r, c);
  IF btn = 64 THEN MoveTo(curRow - 3, curCol)  (* scroll up *)
  ELSIF btn = 65 THEN MoveTo(curRow + 3, curCol) (* scroll down *)
  END
END HandleMouse;

(* ── GetKey: maps raw terminal bytes to logical keys ──────────────── *)
PROCEDURE GetKey(): INTEGER;
VAR c: CHAR;
BEGIN
  c := Terminal.ReadKey();
  IF    ORD(c) = 1   THEN RETURN KEY_UP
  ELSIF ORD(c) = 2   THEN RETURN KEY_DOWN
  ELSIF ORD(c) = 3   THEN RETURN KEY_LEFT
  ELSIF ORD(c) = 4   THEN RETURN KEY_RIGHT
  ELSIF ORD(c) = 5   THEN RETURN KEY_MOUSE
  ELSIF ORD(c) = 127 THEN RETURN KEY_BS
  ELSIF ORD(c) = 128 THEN RETURN KEY_PGUP
  ELSIF ORD(c) = 129 THEN RETURN KEY_PGDN
  ELSIF ORD(c) = 130 THEN RETURN KEY_HOME
  ELSIF ORD(c) = 131 THEN RETURN KEY_END
  ELSIF ORD(c) = 132 THEN RETURN KEY_DEL
  ELSE RETURN ORD(c)
  END
END GetKey;

(* ── main ────────────────────────────────────────────────────────── *)
VAR
  k, err: INTEGER;
  prevRow, prevCol, prevScrRow, prevScrCol: INTEGER;

BEGIN
  (* load file if given on command line, else new empty sheet *)
  fname[0] := 0X;
  IF Args.Count() >= 1 THEN
    Args.Get(1, fname);
    IF IsTSV(fname) THEN
      df := DataFrame.LoadTSV(fname, FALSE, err)
    ELSE
      df := DataFrame.LoadCSV(fname, FALSE, err)
    END;
    IF (df = NIL) OR (err # DataFrame.OK) THEN
      df := DataFrame.Create();
      statusMsg := "New file."
    END
  ELSE
    df := DataFrame.Create()
  END;

  (* sheet starts empty — EnsureSize expands on first edit *)

  curRow := 0; curCol := 0; scrRow := 0; scrCol := 0;
  mode := NORMAL; dirty := FALSE; running := TRUE;
  Terminal.MouseOn();
  CalcVis();
  DrawAll();

  WHILE running DO
    prevRow := curRow; prevCol := curCol;
    prevScrRow := scrRow; prevScrCol := scrCol;
    k := GetKey();
    statusMsg[0] := 0X;

    IF k = KEY_MOUSE THEN
      HandleMouse();
      DrawAll()
    ELSIF mode = EDIT THEN
      HandleEdit(k);
      (* Enter commits and moves the cursor — full redraw so every formula
         cell that depends on the changed value updates immediately.
         For in-progress typing the cursor stays put, so cheap partial draw. *)
      IF (curRow # prevRow) OR (curCol # prevCol) THEN
        DrawAll()
      ELSE
        DrawFormulaBar();
        DrawDataRow(curRow)
      END
    ELSE
      HandleNormal(k);
      (* full redraw if scroll changed, otherwise just repaint affected rows *)
      IF (scrRow # prevScrRow) OR (scrCol # prevScrCol) THEN
        DrawAll()
      ELSIF (curRow # prevRow) OR (curCol # prevCol) THEN
        DrawDataRow(prevRow);   (* un-highlight old cell *)
        RedrawCur()             (* highlight new cell + formula bar *)
      ELSE
        DrawAll()               (* data changed or status updated *)
      END
    END
  END;

  Terminal.MouseOff()
END sheet.
