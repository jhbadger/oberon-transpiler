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
 *   Ctrl+F             freeze/unfreeze top row
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
  CLR_FRZ   = 15;   BG_FRZ  = 22;   (* white on dark green — frozen row *)

  KEY_UP    = 0A0X;   KEY_DOWN  = 0A1X;
  KEY_LEFT  = 0A2X;   KEY_RIGHT = 0A3X;
  KEY_MOUSE = 0A4X;
  KEY_BS    = 07FX;   KEY_TAB   = 09X;
  KEY_ENTER = 0DX; KEY_ESC  = 1BX;
  KEY_PGUP  = 80X; KEY_PGDN  = 81X;
  KEY_HOME  = 82X; KEY_END   = 83X;
  KEY_DEL   = 84X;
  KEY_F2    = 8AX;
  KEY_CTRL_O = 15;
  KEY_CTRL_S = 19;
  KEY_CTRL_L = 12;
  KEY_CTRL_N = 14;
  KEY_CTRL_Q = 17;
  KEY_CTRL_F = 6;
  KEY_SLASH = 47;
  
VAR
  df        : DataFrame.DataFrame;
  fname     : ARRAY 256 OF CHAR;
  colWidths : ARRAY DataFrame.MAXCOLS OF INTEGER;
  dirty     : BOOLEAN;
  freezeTop : BOOLEAN;
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

PROCEDURE FindBelowInColumn();
VAR
  query: ARRAY 256 OF CHAR;
  cell : ARRAY DataFrame.CELLLEN OF CHAR;
  addr : ARRAY 8 OF CHAR;
  r, nr: INTEGER;
BEGIN
  IF ~Prompt("Find: ", query) THEN RETURN END;

  nr := DataFrame.NRows(df);
  FOR r := curRow + 1 TO nr - 1 DO
    CellDisplay(r, curCol, cell);
    IF Strings.Pos(query, cell, 0) >= 0 THEN
      MoveTo(r, curCol);
      CellAddr(r, curCol, addr);
      COPY("Found at ", statusMsg);
      Strings.Append(addr, statusMsg);
      RETURN
    END
  END;

  COPY("Not found below cursor.", statusMsg)
END FindBelowInColumn;

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
  DEC(r1);
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
      IF (kind = 3) & (v > acc) THEN acc := v END
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
    ni := 0;
    WHILE (FmPeek() >= 'A') & (FmPeek() <= 'Z') & (ni < 14) DO
      name[ni] := FmGet(); INC(ni)
    END;
    name[ni] := 0X;
    FmSkipWS();
    IF FmPeek() = '(' THEN
      v := RangeFunc(name)
    ELSIF (FmPeek() >= '0') & (FmPeek() <= '9') THEN
      IF (ni = 1) THEN col := ORD(name[0]) - ORD('A')
      ELSIF (ni = 2) THEN
        col := (ORD(name[0]) - ORD('A') + 1) * 26 + ORD(name[1]) - ORD('A')
      ELSE col := -1
      END;
      row := 0;
      WHILE (FmPeek() >= '0') & (FmPeek() <= '9') DO
        row := row * 10 + ORD(FmGet()) - ORD('0')
      END;
      DEC(row);
      v := EvalCell(row, col, fmDepth)
    ELSE
      v := 0.0
    END
  ELSIF ((FmPeek() >= '0') & (FmPeek() <= '9')) OR (FmPeek() = '.') THEN
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
VAR x, c: INTEGER;
BEGIN
  tCols := Terminal.Cols();
  tRows := Terminal.Rows();

  (* Rows: 1 formula bar + 1 col header + data rows + 1 help bar *)
  (* When frozen, row 0 occupies one extra screen line              *)
  visRows := tRows - 3;
  IF freezeTop THEN DEC(visRows) END;
  IF visRows < 1 THEN visRows := 1 END;

  x := ROWW + 1;
  visCols := 0;
  c := scrCol;
  WHILE (x < tCols) & (c < DataFrame.MAXCOLS) DO
    IF (x + colWidths[c] + 1) <= tCols THEN
      x := x + colWidths[c] + 1;
      INC(visCols); INC(c)
    ELSE
      x := tCols + 1
    END
  END;
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
  IF scrCol < 0 THEN scrCol := 0 END;
  (* when top row is frozen it is drawn separately — don't scroll to it *)
  IF freezeTop & (scrRow < 1) THEN scrRow := 1 END
END ClampScroll;

(* ── screen y of data row r ─────────────────────────────────────── *)
PROCEDURE RowY(r: INTEGER): INTEGER;
BEGIN
  IF freezeTop THEN RETURN (r - scrRow) + 4
  ELSE RETURN (r - scrRow) + 3
  END
END RowY;

(* ── draw one padded cell ───────────────────────────────────────── *)
PROCEDURE PadPrint(s: ARRAY OF CHAR; w: INTEGER);
VAR i, len: INTEGER;
BEGIN
  len := Strings.Length(s);
  IF len > w THEN len := w; s[len] := 0X END;
  Out.String(s);
  FOR i := len TO w - 1 DO Out.Char(' ') END
END PadPrint;

(* ── recalc one column's display width from its data ────────────── *)
PROCEDURE RecalcColWidth(c: INTEGER);
VAR
  r, total, count, avg, nr, hdrLen: INTEGER;
  val: ARRAY DataFrame.CELLLEN OF CHAR;
  lbl: ARRAY 4 OF CHAR;
BEGIN
  nr    := DataFrame.NRows(df);
  total := 0;
  count := 0;
  FOR r := 0 TO nr - 1 DO
    CellDisplay(r, c, val);
    total := total + Strings.Length(val);
    INC(count)
  END;
  IF count > 0 THEN avg := total DIV count ELSE avg := 8 END;

  (* clamp average to reasonable bounds *)
  IF avg < 5  THEN avg := 5  END;
  IF avg > 30 THEN avg := 30 END;

  (* floor: never narrower than the first-row (header) string,
     applied after the general clamp so headers always show fully *)
  IF nr > 0 THEN
    CellDisplay(0, c, val);
    hdrLen := Strings.Length(val);
    IF hdrLen > 40 THEN hdrLen := 40 END;
    IF avg < hdrLen THEN avg := hdrLen END
  END;

  (* also never narrower than the column letter label *)
  ColLabel(c, lbl);
  IF avg < Strings.Length(lbl) THEN avg := Strings.Length(lbl) END;

  colWidths[c] := avg + 2
END RecalcColWidth;

(* ── recalc all columns ─────────────────────────────────────────── *)
PROCEDURE RecalcAllColWidths();
VAR c: INTEGER;
BEGIN
  FOR c := 0 TO DataFrame.NCols(df) - 1 DO
    RecalcColWidth(c)
  END
END RecalcAllColWidths;

PROCEDURE ColX(targetCol: INTEGER): INTEGER;
VAR c, x: INTEGER;
BEGIN
  x := ROWW + 1;
  FOR c := scrCol TO targetCol - 1 DO
    x := x + colWidths[c] + 1
  END;
  RETURN x + 1
END ColX;

(* ── draw column-header row ─────────────────────────────────────── *)
PROCEDURE DrawColHeaders();
VAR
  c, x, i, pad, llen: INTEGER;
  lbl: ARRAY 4 OF CHAR;
BEGIN
  Graphics.Goto(1, 2);
  Graphics.Color256(CLR_HDR, BG_HDR);
  FOR i := 1 TO ROWW DO Out.Char(' ') END;
  Out.Char('|');
  x := ROWW + 1;
  FOR c := scrCol TO scrCol + visCols - 1 DO
    ColLabel(c, lbl);
    llen := Strings.Length(lbl);
    pad  := (colWidths[c] - llen) DIV 2;
    FOR i := 0 TO pad - 1 DO Out.Char(' ') END;
    Out.String(lbl);
    FOR i := llen + pad TO colWidths[c] - 1 DO Out.Char(' ') END;
    Out.Char('|');
    x := x + colWidths[c] + 1
  END;
  WHILE x <= tCols DO Out.Char(' '); INC(x) END;
  Graphics.Reset
END DrawColHeaders;

(* ── draw one data row ──────────────────────────────────────────── *)
PROCEDURE DrawDataRow(r: INTEGER);
VAR
  c, y, x, i: INTEGER;
  val: ARRAY DataFrame.CELLLEN OF CHAR;
  raw: ARRAY DataFrame.CELLLEN OF CHAR;
  rn:  ARRAY 8 OF CHAR;
  isFormula, isSel: BOOLEAN;
  fgNorm, bgNorm: INTEGER;
BEGIN
  y := RowY(r);
  (* frozen row is always at screen line 3, override RowY result *)
  IF freezeTop & (r = 0) THEN y := 3 END;
  IF (y < 3) OR (y > tRows - 1) THEN RETURN END;

  Graphics.Goto(1, y);

  (* choose colours for frozen vs normal rows *)
  IF freezeTop & (r = 0) THEN
    fgNorm := CLR_FRZ; bgNorm := BG_FRZ
  ELSE
    fgNorm := CLR_NORM; bgNorm := BG_NORM
  END;

  (* 1. Row number gutter — exactly ROWW chars before '|' *)
  Graphics.Color256(CLR_ROW, BG_ROW);
  Strings.IntToStr(r + 1, rn);
  FOR i := Strings.Length(rn) TO ROWW - 1 DO Out.Char(' ') END;
  Out.String(rn);
  Out.Char('|');
  x := ROWW + 1;

  (* 2. Visible cells *)
  FOR c := scrCol TO scrCol + visCols - 1 DO
    isSel     := (r = curRow) & (c = curCol);
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
      Graphics.Color256(fgNorm, bgNorm)
    END;
    PadPrint(val, colWidths[c]);
    Graphics.Color256(CLR_HDR, BG_HDR);
    Out.Char('|');
    x := x + colWidths[c] + 1
  END;

  (* 3. Clear rest of line *)
  Graphics.Color256(fgNorm, bgNorm);
  WHILE x <= tCols DO Out.Char(' '); INC(x) END;
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
    Graphics.Goto(tCols - Strings.Length(statusMsg) - 1, 1);
    Out.String(statusMsg)
  END;
  Graphics.Reset
END DrawFormulaBar;

(* ── help bar (last row) ────────────────────────────────────────── *)
PROCEDURE DrawHelp();
VAR s: ARRAY 128 OF CHAR;
BEGIN
  Graphics.Goto(1, tRows);
  Graphics.Color256(CLR_HELP, BG_HELP);
  IF mode = EDIT THEN
    s := "Enter:confirm  Esc:cancel  Backspace:delete"
  ELSE
    s := "Arrows:nav  Enter:edit  Del:clear  ^O:open  ^S:save  ^L:reload  ^F:freeze  /:search ^Q:quit"
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
  (* draw frozen row at screen line 3 before the scrollable region *)
  IF freezeTop THEN
    DrawDataRow(0)
  END;
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
VAR 
  f: Files.File; 
  r: Files.Rider;
  row, col, nr, nc, i: INTEGER;
  cell: ARRAY DataFrame.CELLLEN OF CHAR;
  needsQuotes: BOOLEAN;
BEGIN
  f := Files.New(fn);
  IF f = NIL THEN RETURN FALSE END;
  Files.Set(r, f, 0);

  nc := DataFrame.NCols(df); 
  nr := DataFrame.NRows(df);

  FOR row := 0 TO nr - 1 DO
    FOR col := 0 TO nc - 1 DO
      IF col > 0 THEN Files.Write(r, ',') END; (* Separator *)

      DataFrame.GetStr(df, row, col, cell);
      
      (* Check if quoting is required for this specific cell *)
      needsQuotes := FALSE;
      i := 0;
      WHILE cell[i] # 0X DO
        (* Quote if cell contains comma, double-quote, or newline *)
        IF (cell[i] = ',') OR (cell[i] = 022X) OR (cell[i] = 0AX) OR (cell[i] = 0DX) THEN
          needsQuotes := TRUE
        END;
        INC(i)
      END;

      IF needsQuotes THEN
        Files.Write(r, 022X); (* Opening Quote [cite: 165] *)
        i := 0;
        WHILE cell[i] # 0X DO
          IF cell[i] = 022X THEN 
            Files.Write(r, 022X) (* Escape internal quote by doubling it *)
          END;
          Files.Write(r, cell[i]);
          INC(i)
        END;
        Files.Write(r, 022X) (* Closing Quote [cite: 166] *)
      ELSE
        Files.WriteString(r, cell) (* Raw write for simple cells [cite: 166] *)
      END
    END;
    Files.Write(r, 0AX) (* End of row [cite: 167] *)
  END;

  Files.Register(f); 
  Files.Close(f);
  RETURN TRUE
END SaveCSV;

(* ── save to TSV ─────────────────────────────────────────────────── *)
PROCEDURE SaveTSV(fn: ARRAY OF CHAR): BOOLEAN;
VAR 
  f: Files.File; 
  r: Files.Rider;
  row, col, nr, nc, i: INTEGER;
  cell: ARRAY DataFrame.CELLLEN OF CHAR;
BEGIN
  f := Files.New(fn);
  IF f = NIL THEN RETURN FALSE END;
  Files.Set(r, f, 0);

  (* Ensure we get the full count of rows and columns *)
  nc := DataFrame.NCols(df); 
  nr := DataFrame.NRows(df);

  FOR row := 0 TO nr - 1 DO
    FOR col := 0 TO nc - 1 DO
      IF col > 0 THEN Files.Write(r, 09X) END; (* Write Tab separator *)

      DataFrame.GetStr(df, row, col, cell);
      
      (* Sanitize: If the data contains a tab or newline, 
         we must handle it to prevent corrupting the TSV structure. *)
      i := 0;
      WHILE cell[i] # 0X DO
        IF cell[i] = 09X THEN 
          Files.Write(r, ' ') (* Replace internal tabs with space *)
        ELSIF (cell[i] = 0AX) OR (cell[i] = 0DX) THEN
          Files.Write(r, ' ') (* Replace newlines with space *)
        ELSE
          Files.Write(r, cell[i])
        END;
        INC(i)
      END
    END;
    Files.Write(r, 0AX) (* End of row *)
  END;

  Files.Register(f); 
  Files.Close(f);
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
BEGIN
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
  RecalcColWidth(curCol);
  dirty := TRUE;
  mode  := NORMAL
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
  result[0] := 0X; i := 0;
  plen := Strings.Length(prompt);
  LOOP
    Graphics.Goto(1, 1);
    Graphics.Color256(CLR_SEL, BG_SEL);
    x := 1;
    WHILE x <= tCols DO Out.Char(' '); INC(x) END;
    Graphics.Goto(1, 1);
    Out.String(prompt); Out.String(result);
    Graphics.Reset;
    Graphics.Goto(plen + i + 1, 1);
    j := Terminal.ReadKey();
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
      DataFrame.SetStr(df, curRow, curCol, "");
      RecalcColWidth(curCol);
      dirty := TRUE
    END
  ELSIF k = KEY_CTRL_F THEN
    freezeTop := ~freezeTop;
    IF freezeTop THEN
      (* if cursor is on row 0, push it down so it isn't hidden behind freeze *)
      IF curRow = 0 THEN MoveTo(1, curCol) END;
      ClampScroll();
      COPY("Row 1 frozen.", statusMsg)
    ELSE
      COPY("Unfrozen.", statusMsg)
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
      RecalcAllColWidths();
      COPY("Reloaded.", statusMsg)
    END
  ELSIF k = KEY_CTRL_N THEN
    df := DataFrame.Create();
    fname[0] := 0X; dirty := FALSE; freezeTop := FALSE;
    curRow := 0; curCol := 0; scrRow := 0; scrCol := 0;
    COPY("New sheet.", statusMsg)
  ELSIF k = KEY_CTRL_O THEN
    IF Prompt("Open: ", fname) THEN
      IF IsTSV(fname) THEN
        df := DataFrame.LoadTSV(fname, FALSE, nc)
      ELSE
        df := DataFrame.LoadCSV(fname, FALSE, nc)
      END;
      IF df = NIL THEN
        df := DataFrame.Create(); COPY("New file.", statusMsg)
      ELSE
        dirty := FALSE; curRow := 0; curCol := 0;
        scrRow := 0; scrCol := 0;
        RecalcAllColWidths();
        COPY("Opened.", statusMsg)
      END
    ELSE
      fname[0] := 0X
    END
  ELSIF (k = KEY_CTRL_Q) OR (k = KEY_ESC) THEN
    running := FALSE
  ELSIF k = KEY_SLASH THEN
    FindBelowInColumn()
  ELSIF (k >= 32) & (k < 127) THEN
    StartEdit(TRUE);
    HandleEdit(k)
  END
END HandleNormal;

(* ── handle mouse click ─────────────────────────────────────────── *)
PROCEDURE HandleMouse();
VAR
  mx, my, btn, c, r, x: INTEGER;
  found: BOOLEAN;
BEGIN
  mx  := Terminal.MouseX();
  my  := Terminal.MouseY();
  btn := Terminal.MouseBtn();

  IF (btn # 0 & btn # 3 & btn # 64 & btn # 65) THEN RETURN END;
  DrawAll();

  IF my = 1 THEN
    IF mode = NORMAL THEN StartEdit(FALSE) END;
    RETURN
  END;

  (* screen line 3 is the frozen header row when freeze is on *)
  IF freezeTop & (my = 3) THEN
    IF mode = EDIT THEN CommitEdit() END;
    (* find column clicked *)
    x := ROWW + 2; c := scrCol; found := FALSE;
    WHILE (c < scrCol + visCols) & (~found) DO
      IF (mx >= x) & (mx < x + colWidths[c] + 1) THEN found := TRUE
      ELSE x := x + colWidths[c] + 1; INC(c)
      END
    END;
    MoveTo(0, c);
    RETURN
  END;

  (* data area starts at screen line 3 (unfrozen) or 4 (frozen) *)
  IF freezeTop THEN
    IF my < 4 THEN RETURN END;
    r := scrRow + (my - 4)
  ELSE
    IF my < 3 THEN RETURN END;
    r := scrRow + (my - 3)
  END;

  x := ROWW + 2; c := scrCol; found := FALSE;
  WHILE (c < scrCol + visCols) & (~found) DO
    IF (mx >= x) & (mx < x + colWidths[c] + 1) THEN found := TRUE
    ELSE x := x + colWidths[c] + 1; INC(c)
    END
  END;
  IF ~found THEN
    IF mx < ROWW + 2 THEN c := 0 ELSE c := curCol END
  END;
  IF r < 0 THEN r := 0 END;

  IF mode = EDIT THEN CommitEdit() END;

  IF btn = 64 THEN MoveTo(curRow - 3, curCol)
  ELSIF btn = 65 THEN MoveTo(curRow + 3, curCol)
  ELSE MoveTo(r, c)
  END
END HandleMouse;

PROCEDURE SortCurrentColumn;
VAR
  i, j, maxRow: INTEGER;
  valI, valJ: REAL;
  strI, strJ: ARRAY DataFrame.CELLLEN OF CHAR;

  (* Helper to swap two full rows *)
  PROCEDURE SwapRows(r1, r2: INTEGER);
  VAR col: INTEGER;
      t, u: ARRAY DataFrame.CELLLEN OF CHAR;
  BEGIN
    FOR col := 0 TO DataFrame.NCols(df) - 1 DO
      DataFrame.GetStr(df, r1, col, t);
      DataFrame.GetStr(df, r2, col, u);
      DataFrame.SetStr(df, r1, col, u);
      DataFrame.SetStr(df, r2, col, t)
    END
  END SwapRows;

BEGIN
  maxRow := DataFrame.NRows(df);
  IF maxRow < 2 THEN RETURN END;

  statusMsg := "Sorting...";
  DrawAll(); (* Show status *)

  (* Simple Selection Sort *)
  FOR i := 1 TO maxRow - 2 DO
    FOR j := i + 1 TO maxRow - 1 DO
      DataFrame.GetStr(df, i, curCol, strI);
      DataFrame.GetStr(df, j, curCol, strJ);

      (* Try to compare as numbers first *)
      IF Strings.StrToReal(strI, valI) & Strings.StrToReal(strJ, valJ) THEN
        IF valI > valJ THEN SwapRows(i, j) END
      ELSE
        (* Fallback to alphabetical comparison *)
        IF Strings.Compare(strI, strJ) > 0 THEN SwapRows(i, j) END
      END
    END
  END;

  dirty := TRUE;
  statusMsg := "Sort complete.";
  DrawAll()
END SortCurrentColumn;

(* ── main ────────────────────────────────────────────────────────── *)
VAR
  k, err: INTEGER;
  prevRow, prevCol, prevScrRow, prevScrCol: INTEGER;

BEGIN
  fname[0] := 0X;
  freezeTop := FALSE;
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

  FOR k := 0 TO DataFrame.MAXCOLS - 1 DO
    colWidths[k] := 10
  END;
  curRow := 0; curCol := 0; scrRow := 0; scrCol := 0;
  RecalcAllColWidths();
  mode := NORMAL; dirty := FALSE; running := TRUE;
  Terminal.MouseOn();
  CalcVis();
  DrawAll();

  WHILE running DO
    prevRow := curRow; prevCol := curCol;
    prevScrRow := scrRow; prevScrCol := scrCol;
    k := Terminal.ReadKey();
    statusMsg[0] := 0X;

    IF k = KEY_MOUSE THEN
      HandleMouse()
    ELSIF k = 14X THEN (* Ctrl+T: sort current column *)
      SortCurrentColumn()
    ELSIF mode = EDIT THEN
      HandleEdit(k);
      IF (curRow # prevRow) OR (curCol # prevCol) THEN
        DrawAll()
      ELSE
        DrawFormulaBar();
        DrawDataRow(curRow)
      END
    ELSE
      HandleNormal(k);
      IF (scrRow # prevScrRow) OR (scrCol # prevScrCol) THEN
        DrawAll()
      ELSIF (curRow # prevRow) OR (curCol # prevCol) THEN
        DrawDataRow(prevRow);
        RedrawCur()
      ELSE
        DrawAll()
      END
    END
  END;

  Terminal.MouseOff()
END sheet.







