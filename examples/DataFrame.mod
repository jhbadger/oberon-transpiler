MODULE DataFrame;
(*
 * DataFrame — a tabular-data module for Oberon.
 *
 * Stores up to MAXCOLS columns and MAXROWS rows.  All cell values are kept
 * internally as NUL-terminated strings (up to CELLLEN-1 chars).  SetInt /
 * SetReal convert to string on write; GetInt / GetReal parse on the fly.
 *
 * Manual creation:
 *
 *   VAR df: DataFrame.DataFrame; row: INTEGER;
 *   df := DataFrame.Create();
 *   DataFrame.AddCol(df, "Name"); DataFrame.AddCol(df, "Score");
 *   row := DataFrame.AddRow(df);
 *   DataFrame.SetStr(df, row, 0, "Alice"); DataFrame.SetReal(df, row, 1, 9.5);
 *   DataFrame.Print(df);
 *
 * Loading from file:
 *
 *   VAR df: DataFrame.DataFrame; err: INTEGER;
 *   df := DataFrame.LoadCSV("data.csv", TRUE, err);   (* TRUE = has header row *)
 *   IF err = DataFrame.OK THEN DataFrame.Print(df) END;
 *)

IMPORT Files, Strings, Out;

CONST
  MAXCOLS*  = 32;    (* maximum number of columns              *)
  MAXROWS*  = 32768;  (* maximum number of rows                 *)
  CNAMELEN* = 64;    (* max column-name length in bytes        *)
  CELLLEN*  = 64;    (* max string cell length in bytes        *)
  SDATASZ   = 2097152; (* MAXROWS * CELLLEN — flat cell storage  *)

  OK*       = 0;   (* success                                  *)
  ERR_COL*  = 1;   (* column index out of range                *)
  ERR_ROW*  = 2;   (* row index out of range                   *)
  ERR_FULL* = 3;   (* table is full (columns or rows)          *)
  ERR_FILE* = 4;   (* file not found or I/O error              *)

  COLWIDTH  = 14;  (* display width for Print / Head / Tail    *)

TYPE
  DataFrameRec = RECORD
    ncols : INTEGER;
    nrows : INTEGER;
    cname : ARRAY MAXCOLS OF ARRAY CNAMELEN OF CHAR;
    data  : ARRAY MAXCOLS OF ARRAY SDATASZ  OF CHAR;
  END;
  DataFrame* = POINTER TO DataFrameRec;

(* ── internal cell helpers ──────────────────────────────────────────── *)

(* Write val into the flat per-column array at the slot for row r. *)
PROCEDURE CellSet(VAR col: ARRAY OF CHAR; row: INTEGER; val: ARRAY OF CHAR);
VAR i, off, vlen: INTEGER;
BEGIN
  off  := row * CELLLEN;
  vlen := Strings.Length(val);
  IF vlen >= CELLLEN THEN vlen := CELLLEN - 1 END;
  i := 0;
  WHILE i < vlen DO col[off + i] := val[i]; INC(i) END;
  col[off + i] := 0X
END CellSet;

(* Copy the cell at row r out of the flat column array into val. *)
PROCEDURE CellGet(VAR col: ARRAY OF CHAR; row: INTEGER; VAR val: ARRAY OF CHAR);
VAR i, off, mx: INTEGER;
BEGIN
  off := row * CELLLEN;
  mx  := LEN(val) - 1;
  i   := 0;
  WHILE (col[off + i] # 0X) & (i < mx) DO
    val[i] := col[off + i]; INC(i)
  END;
  val[i] := 0X
END CellGet;

(* ── construction ───────────────────────────────────────────────────── *)

(** Allocate and return an empty DataFrame. *)
PROCEDURE Create*(): DataFrame;
VAR df: DataFrame;
BEGIN
  NEW(df);
  df.ncols := 0;
  df.nrows := 0;
  RETURN df
END Create;

(** Add a column named `name`.  Returns the new column index, or -1 if
    the table already has MAXCOLS columns. *)
PROCEDURE AddCol*(df: DataFrame; name: ARRAY OF CHAR): INTEGER;
VAR c: INTEGER;
BEGIN
  IF df.ncols >= MAXCOLS THEN RETURN -1 END;
  c := df.ncols;
  COPY(name, df.cname[c]);
  INC(df.ncols);
  RETURN c
END AddCol;

(** Append a blank row.  Returns the new row index, or -1 if the table
    already has MAXROWS rows. *)
PROCEDURE AddRow*(df: DataFrame): INTEGER;
VAR r, c, off: INTEGER;
BEGIN
  IF df.nrows >= MAXROWS THEN RETURN -1 END;
  r   := df.nrows;
  off := r * CELLLEN;
  INC(df.nrows);
  FOR c := 0 TO df.ncols - 1 DO df.data[c][off] := 0X END;
  RETURN r
END AddRow;

(* ── dimension queries ──────────────────────────────────────────────── *)

PROCEDURE NCols*(df: DataFrame): INTEGER;
BEGIN RETURN df.ncols END NCols;

PROCEDURE NRows*(df: DataFrame): INTEGER;
BEGIN RETURN df.nrows END NRows;

(** Copy the name of column c into name.  name is set to "" for bad index. *)
PROCEDURE ColName*(df: DataFrame; c: INTEGER; VAR name: ARRAY OF CHAR);
BEGIN
  IF (c >= 0) & (c < df.ncols) THEN COPY(df.cname[c], name)
  ELSE name[0] := 0X
  END
END ColName;

(** Return the index of the column with the given name, or -1 if not found. *)
PROCEDURE FindCol*(df: DataFrame; name: ARRAY OF CHAR): INTEGER;
VAR c: INTEGER;
BEGIN
  c := 0;
  WHILE c < df.ncols DO
    IF Strings.Compare(df.cname[c], name) = 0 THEN RETURN c END;
    INC(c)
  END;
  RETURN -1
END FindCol;

(* ── cell setters ───────────────────────────────────────────────────── *)

(** Set cell (r, c) to a string value. *)
PROCEDURE SetStr*(df: DataFrame; r, c: INTEGER; val: ARRAY OF CHAR);
BEGIN
  IF (c >= 0) & (c < df.ncols) & (r >= 0) & (r < df.nrows) THEN
    CellSet(df.data[c], r, val)
  END
END SetStr;

(** Set cell (r, c) to an integer value (stored as a string). *)
PROCEDURE SetInt*(df: DataFrame; r, c, val: INTEGER);
VAR s: ARRAY 24 OF CHAR;
BEGIN
  Strings.IntToStr(val, s);
  IF (c >= 0) & (c < df.ncols) & (r >= 0) & (r < df.nrows) THEN
    CellSet(df.data[c], r, s)
  END
END SetInt;

(** Set cell (r, c) to a real value (stored as a string). *)
PROCEDURE SetReal*(df: DataFrame; r, c: INTEGER; val: REAL);
VAR s: ARRAY 32 OF CHAR;
BEGIN
  Strings.RealToStr(val, s);
  IF (c >= 0) & (c < df.ncols) & (r >= 0) & (r < df.nrows) THEN
    CellSet(df.data[c], r, s)
  END
END SetReal;

(* ── cell getters ───────────────────────────────────────────────────── *)

(** Copy cell (r, c) into val.  val is set to "" for bad indices. *)
PROCEDURE GetStr*(df: DataFrame; r, c: INTEGER; VAR val: ARRAY OF CHAR);
BEGIN
  IF (c >= 0) & (c < df.ncols) & (r >= 0) & (r < df.nrows) THEN
    CellGet(df.data[c], r, val)
  ELSE
    val[0] := 0X
  END
END GetStr;

(** Parse cell (r, c) as an integer into val.  Returns FALSE if the cell
    value cannot be parsed as an integer. *)
PROCEDURE GetInt*(df: DataFrame; r, c: INTEGER; VAR val: INTEGER): BOOLEAN;
VAR s: ARRAY CELLLEN OF CHAR;
BEGIN
  GetStr(df, r, c, s);
  RETURN Strings.StrToInt(s, val)
END GetInt;

(** Parse cell (r, c) as a real into val.  Returns FALSE if the cell
    value cannot be parsed as a number. *)
PROCEDURE GetReal*(df: DataFrame; r, c: INTEGER; VAR val: REAL): BOOLEAN;
VAR s: ARRAY CELLLEN OF CHAR;
BEGIN
  GetStr(df, r, c, s);
  RETURN Strings.StrToReal(s, val)
END GetReal;

(* ── file loading ───────────────────────────────────────────────────── *)

(* Build an auto-column name "V<n+1>" for the n-th column (0-based). *)
PROCEDURE AutoColName(n: INTEGER; VAR name: ARRAY OF CHAR);
VAR s: ARRAY 16 OF CHAR;
BEGIN
  name[0] := 'V'; name[1] := 0X;
  Strings.IntToStr(n + 1, s);
  Strings.Append(s, name)
END AutoColName;

(* Read one delimited field from rider r.
   Handles optional RFC-4180 quoting (double-quote escapes: "").
   Sets eol=TRUE at end of line, isEof=TRUE at end of file. *)
PROCEDURE ReadField(VAR r: Files.Rider; sep: CHAR;
                    VAR field: ARRAY OF CHAR;
                    VAR eol: BOOLEAN; VAR isEof: BOOLEAN);
VAR ch: CHAR; i, mx: INTEGER; quoted, done: BOOLEAN;
BEGIN
  mx := LEN(field) - 1; i := 0;
  eol := FALSE; isEof := FALSE; quoted := FALSE; done := FALSE;
  field[0] := 0X;

  Files.Read(r, ch);
  IF r.eof THEN isEof := TRUE; eol := TRUE; RETURN END;

  (* optional opening quote *)
  IF ch = '"' THEN
    quoted := TRUE;
    Files.Read(r, ch);
    IF r.eof THEN isEof := TRUE; eol := TRUE; RETURN END
  END;

  WHILE ~done DO
    IF r.eof THEN
      isEof := TRUE; eol := TRUE; done := TRUE

    ELSIF quoted THEN
      IF ch = '"' THEN
        (* closing quote or escaped "" *)
        Files.Read(r, ch);
        IF r.eof THEN
          isEof := TRUE; eol := TRUE; done := TRUE
        ELSIF ch = '"' THEN
          (* escaped double-quote: store one " *)
          IF i < mx THEN field[i] := '"'; INC(i) END;
          Files.Read(r, ch);
          IF r.eof THEN isEof := TRUE; eol := TRUE; done := TRUE END
        ELSE
          (* closing quote; ch is now the char after it *)
          IF ch = sep THEN eol := FALSE
          ELSIF ch = 0DX THEN
            Files.Read(r, ch);
            IF r.eof THEN isEof := TRUE END;
            eol := TRUE
          ELSE eol := (ch = 0AX)
          END;
          done := TRUE
        END
      ELSE
        IF i < mx THEN field[i] := ch; INC(i) END;
        Files.Read(r, ch);
        IF r.eof THEN isEof := TRUE; eol := TRUE; done := TRUE END
      END

    ELSE  (* unquoted field *)
      IF ch = sep THEN
        eol := FALSE; done := TRUE
      ELSIF ch = 0DX THEN
        Files.Read(r, ch);
        IF r.eof THEN isEof := TRUE END;
        eol := TRUE; done := TRUE
      ELSIF ch = 0AX THEN
        eol := TRUE; done := TRUE
      ELSE
        IF i < mx THEN field[i] := ch; INC(i) END;
        Files.Read(r, ch);
        IF r.eof THEN isEof := TRUE; eol := TRUE; done := TRUE END
      END
    END
  END;

  field[i] := 0X
END ReadField;

(** Load a delimited file into a new DataFrame.
    sep       — the field separator character (e.g. ',' for CSV, 09X for TSV).
    hasHeader — TRUE if the first row contains column names; FALSE to
                auto-name columns V1, V2, …
    err       — set to OK on success, ERR_FILE if the file cannot be opened,
                ERR_FULL if the row limit is reached before the file ends.
    Returns NIL on file error. *)
PROCEDURE LoadSep*(fname: ARRAY OF CHAR; sep: CHAR;
                   hasHeader: BOOLEAN; VAR err: INTEGER): DataFrame;
VAR
  f:       Files.File;
  r:       Files.Rider;
  df:      DataFrame;
  field:   ARRAY CELLLEN  OF CHAR;
  nameBuf: ARRAY CNAMELEN OF CHAR;
  eol, isEof: BOOLEAN;
  col, row, off, c: INTEGER;
BEGIN
  err   := OK;
  f     := Files.Old(fname);
  IF f = NIL THEN err := ERR_FILE; RETURN NIL END;
  df    := Create();
  Files.Set(r, f, 0);
  isEof := FALSE;

  (* ── optional header row → column names ─────────────────────────── *)
  IF hasHeader THEN
    eol := FALSE;
    WHILE ~eol & ~isEof DO
      ReadField(r, sep, field, eol, isEof);
      IF df.ncols < MAXCOLS THEN
        Strings.Trim(field);
        IF Strings.Length(field) = 0 THEN AutoColName(df.ncols, field) END;
        COPY(field, df.cname[df.ncols]);
        INC(df.ncols)
      END
    END
  END;

  (* ── data rows ───────────────────────────────────────────────────── *)
  WHILE ~isEof DO
    row := -1; col := 0; eol := FALSE;
    WHILE ~eol & ~isEof DO
      ReadField(r, sep, field, eol, isEof);

      (* Detect blank line: first field, empty, end-of-line *)
      IF (col = 0) & eol & (Strings.Length(field) = 0) THEN
        (* skip blank line — row stays -1, nothing added *)
      ELSE
        (* Create the row on first valid field *)
        IF row < 0 THEN
          IF df.nrows < MAXROWS THEN
            row := df.nrows; INC(df.nrows);
            off := row * CELLLEN;
            FOR c := 0 TO df.ncols - 1 DO df.data[c][off] := 0X END
          ELSE
            err := ERR_FULL; isEof := TRUE
          END
        END;

        IF row >= 0 THEN
          (* In no-header mode, auto-create columns on the first data row *)
          IF ~hasHeader & (col >= df.ncols) & (df.ncols < MAXCOLS) THEN
            AutoColName(df.ncols, nameBuf);
            COPY(nameBuf, df.cname[df.ncols]);
            INC(df.ncols);
            (* Zero this new column's cell for all previous rows *)
            FOR c := 0 TO row - 1 DO df.data[df.ncols - 1][c * CELLLEN] := 0X END
          END;

          IF col < df.ncols THEN
            Strings.Trim(field);
            CellSet(df.data[col], row, field)
          END;
          INC(col)
        END
      END
    END
  END;

  Files.Close(f);
  RETURN df
END LoadSep;

(** Load a CSV (comma-separated) file. *)
PROCEDURE LoadCSV*(fname: ARRAY OF CHAR; hasHeader: BOOLEAN;
                   VAR err: INTEGER): DataFrame;
BEGIN RETURN LoadSep(fname, ',', hasHeader, err) END LoadCSV;

(** Load a TSV (tab-separated) file. *)
PROCEDURE LoadTSV*(fname: ARRAY OF CHAR; hasHeader: BOOLEAN;
                   VAR err: INTEGER): DataFrame;
BEGIN RETURN LoadSep(fname, 09X, hasHeader, err) END LoadTSV;

(* ── display ────────────────────────────────────────────────────────── *)

(** Print a summary: column count, row count, and column names. *)
PROCEDURE Info*(df: DataFrame);
VAR c: INTEGER;
BEGIN
  Out.String("DataFrame: ");
  Out.Int(df.nrows, 0); Out.String(" rows x ");
  Out.Int(df.ncols, 0); Out.String(" cols");
  Out.Ln;
  Out.String("Columns: ");
  FOR c := 0 TO df.ncols - 1 DO
    IF c > 0 THEN Out.String(", ") END;
    Out.String(df.cname[c])
  END;
  Out.Ln
END Info;

(* Print n rows of df starting at row start, with a header. *)
PROCEDURE PrintRows(df: DataFrame; start, n: INTEGER);
VAR r, c, i, slen: INTEGER;
    cell: ARRAY CELLLEN  OF CHAR;
    name: ARRAY CNAMELEN OF CHAR;
BEGIN
  (* header *)
  FOR c := 0 TO df.ncols - 1 DO
    IF c > 0 THEN Out.String(" | ") END;
    COPY(df.cname[c], name);
    slen := Strings.Length(name);
    IF slen > COLWIDTH THEN slen := COLWIDTH; name[slen] := 0X END;
    Out.String(name);
    FOR i := slen TO COLWIDTH - 1 DO Out.Char(' ') END
  END;
  Out.Ln;
  (* separator *)
  FOR c := 0 TO df.ncols - 1 DO
    IF c > 0 THEN Out.String("-+-") END;
    FOR i := 0 TO COLWIDTH - 1 DO Out.Char('-') END
  END;
  Out.Ln;
  (* rows *)
  r := start;
  WHILE (r < df.nrows) & (r < start + n) DO
    FOR c := 0 TO df.ncols - 1 DO
      IF c > 0 THEN Out.String(" | ") END;
      CellGet(df.data[c], r, cell);
      slen := Strings.Length(cell);
      IF slen > COLWIDTH THEN slen := COLWIDTH; cell[slen] := 0X END;
      Out.String(cell);
      FOR i := slen TO COLWIDTH - 1 DO Out.Char(' ') END
    END;
    Out.Ln;
    INC(r)
  END
END PrintRows;

(** Print the first n rows (like pandas head()). *)
PROCEDURE Head*(df: DataFrame; n: INTEGER);
BEGIN
  Info(df); Out.Ln;
  PrintRows(df, 0, n)
END Head;

(** Print the last n rows (like pandas tail()). *)
PROCEDURE Tail*(df: DataFrame; n: INTEGER);
VAR start: INTEGER;
BEGIN
  Info(df); Out.Ln;
  start := df.nrows - n;
  IF start < 0 THEN start := 0 END;
  PrintRows(df, start, n)
END Tail;

(** Print all rows. *)
PROCEDURE Print*(df: DataFrame);
BEGIN
  Info(df); Out.Ln;
  PrintRows(df, 0, df.nrows)
END Print;

END DataFrame.
