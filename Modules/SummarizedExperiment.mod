MODULE SummarizedExperiment;

IMPORT DataFrame, Dict, Strings, Out;

CONST
  MAXROWS*   = 4096;
  MAXCOLS*   = 256;
  MAXASSAYS* = 8;
  NAMELEN*   = 64;
  MAXCELLS   = MAXROWS * MAXCOLS;

  OK*        = 0;
  ERR_NIL*   = 1;
  ERR_DIM*   = 2;
  ERR_ROW*   = 3;
  ERR_COL*   = 4;
  ERR_ASSAY* = 5;
  ERR_FULL*  = 6;
  ERR_NAME*  = 7;

TYPE
  AssayRec = RECORD
    name: ARRAY NAMELEN OF CHAR;
    data: ARRAY MAXCELLS OF REAL
  END;
  Assay = POINTER TO AssayRec;

  SERec = RECORD
    nrows, ncols: INTEGER;
    nassays: INTEGER;

    assays: ARRAY MAXASSAYS OF Assay;

    rowNames: ARRAY MAXROWS OF ARRAY NAMELEN OF CHAR;
    colNames: ARRAY MAXCOLS OF ARRAY NAMELEN OF CHAR;

    rowData: DataFrame.DataFrame;
    colData: DataFrame.DataFrame;

    meta: Dict.Table
  END;

  SE* = POINTER TO SERec;

(* ---------- internal helpers ---------- *)

PROCEDURE AutoName(prefix: ARRAY OF CHAR; i: INTEGER; VAR name: ARRAY OF CHAR);
VAR s: ARRAY 16 OF CHAR;
BEGIN
  COPY(prefix, name);
  Strings.IntToStr(i + 1, s);
  Strings.Append(s, name)
END AutoName;

PROCEDURE CellIndex(se: SE; r, c: INTEGER): INTEGER;
BEGIN
  RETURN r * se.ncols + c
END CellIndex;

PROCEDURE GoodRow(se: SE; r: INTEGER): BOOLEAN;
BEGIN
  RETURN (se # NIL) & (r >= 0) & (r < se.nrows)
END GoodRow;

PROCEDURE GoodCol(se: SE; c: INTEGER): BOOLEAN;
BEGIN
  RETURN (se # NIL) & (c >= 0) & (c < se.ncols)
END GoodCol;

PROCEDURE GoodAssay(se: SE; a: INTEGER): BOOLEAN;
BEGIN
  RETURN (se # NIL) & (a >= 0) & (a < se.nassays) & (se.assays[a] # NIL)
END GoodAssay;

PROCEDURE ZeroAssay(a: Assay);
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO MAXCELLS - 1 DO
    a.data[i] := 0.0
  END
END ZeroAssay;

(* ---------- construction ---------- *)

PROCEDURE Create*(nrows, ncols: INTEGER; VAR err: INTEGER): SE;
VAR
  se: SE;
  i, r: INTEGER;
BEGIN
  err := OK;

  IF (nrows < 0) OR (nrows > MAXROWS) OR (ncols < 0) OR (ncols > MAXCOLS) THEN
    err := ERR_DIM;
    RETURN NIL
  END;

  NEW(se);
  se.nrows := nrows;
  se.ncols := ncols;
  se.nassays := 0;

  se.rowData := DataFrame.Create();
  se.colData := DataFrame.Create();
  Dict.Init(se.meta);

  FOR i := 0 TO nrows - 1 DO
    r := DataFrame.AddRow(se.rowData);
    AutoName("row", i, se.rowNames[i])
  END;

  FOR i := 0 TO ncols - 1 DO
    r := DataFrame.AddRow(se.colData);
    AutoName("col", i, se.colNames[i])
  END;

  RETURN se
END Create;

(* ---------- dimensions ---------- *)

PROCEDURE NRows*(se: SE): INTEGER;
BEGIN
  IF se = NIL THEN RETURN 0 END;
  RETURN se.nrows
END NRows;

PROCEDURE NCols*(se: SE): INTEGER;
BEGIN
  IF se = NIL THEN RETURN 0 END;
  RETURN se.ncols
END NCols;

PROCEDURE AssayCount*(se: SE): INTEGER;
BEGIN
  IF se = NIL THEN RETURN 0 END;
  RETURN se.nassays
END AssayCount;

(* ---------- assays ---------- *)

PROCEDURE FindAssay*(se: SE; name: ARRAY OF CHAR): INTEGER;
VAR i: INTEGER;
BEGIN
  IF se = NIL THEN RETURN -1 END;
  FOR i := 0 TO se.nassays - 1 DO
    IF (se.assays[i] # NIL) & (Strings.Compare(se.assays[i].name, name) = 0) THEN
      RETURN i
    END
  END;
  RETURN -1
END FindAssay;

PROCEDURE AssayName*(se: SE; a: INTEGER; VAR name: ARRAY OF CHAR);
BEGIN
  IF GoodAssay(se, a) THEN
    COPY(se.assays[a].name, name)
  ELSE
    name[0] := 0X
  END
END AssayName;

PROCEDURE AddAssay*(se: SE; name: ARRAY OF CHAR; VAR err: INTEGER): INTEGER;
VAR
  a: Assay;
  idx: INTEGER;
BEGIN
  err := OK;

  IF se = NIL THEN
    err := ERR_NIL;
    RETURN -1
  END;

  IF Strings.Length(name) = 0 THEN
    err := ERR_NAME;
    RETURN -1
  END;

  IF FindAssay(se, name) >= 0 THEN
    err := ERR_NAME;
    RETURN -1
  END;

  IF se.nassays >= MAXASSAYS THEN
    err := ERR_FULL;
    RETURN -1
  END;

  NEW(a);
  COPY(name, a.name);
  ZeroAssay(a);

  idx := se.nassays;
  se.assays[idx] := a;
  INC(se.nassays);

  RETURN idx
END AddAssay;

PROCEDURE SetAssay*(se: SE; a, r, c: INTEGER; x: REAL; VAR err: INTEGER);
BEGIN
  err := OK;

  IF se = NIL THEN err := ERR_NIL; RETURN END;
  IF ~GoodAssay(se, a) THEN err := ERR_ASSAY; RETURN END;
  IF ~GoodRow(se, r) THEN err := ERR_ROW; RETURN END;
  IF ~GoodCol(se, c) THEN err := ERR_COL; RETURN END;

  se.assays[a].data[CellIndex(se, r, c)] := x
END SetAssay;

PROCEDURE GetAssay*(se: SE; a, r, c: INTEGER; VAR x: REAL; VAR err: INTEGER);
BEGIN
  err := OK;
  x := 0.0;

  IF se = NIL THEN err := ERR_NIL; RETURN END;
  IF ~GoodAssay(se, a) THEN err := ERR_ASSAY; RETURN END;
  IF ~GoodRow(se, r) THEN err := ERR_ROW; RETURN END;
  IF ~GoodCol(se, c) THEN err := ERR_COL; RETURN END;

  x := se.assays[a].data[CellIndex(se, r, c)]
END GetAssay;

PROCEDURE SetAssayByName*(se: SE; assayName: ARRAY OF CHAR; r, c: INTEGER; x: REAL; VAR err: INTEGER);
VAR a: INTEGER;
BEGIN
  a := FindAssay(se, assayName);
  IF a < 0 THEN
    err := ERR_ASSAY;
    RETURN
  END;
  SetAssay(se, a, r, c, x, err)
END SetAssayByName;

PROCEDURE GetAssayByName*(se: SE; assayName: ARRAY OF CHAR; r, c: INTEGER; VAR x: REAL; VAR err: INTEGER);
VAR a: INTEGER;
BEGIN
  a := FindAssay(se, assayName);
  IF a < 0 THEN
    err := ERR_ASSAY;
    x := 0.0;
    RETURN
  END;
  GetAssay(se, a, r, c, x, err)
END GetAssayByName;

(* ---------- row / column names ---------- *)

PROCEDURE SetRowName*(se: SE; r: INTEGER; name: ARRAY OF CHAR; VAR err: INTEGER);
BEGIN
  err := OK;
  IF se = NIL THEN err := ERR_NIL; RETURN END;
  IF ~GoodRow(se, r) THEN err := ERR_ROW; RETURN END;
  COPY(name, se.rowNames[r])
END SetRowName;

PROCEDURE RowName*(se: SE; r: INTEGER; VAR name: ARRAY OF CHAR);
BEGIN
  IF GoodRow(se, r) THEN
    COPY(se.rowNames[r], name)
  ELSE
    name[0] := 0X
  END
END RowName;

PROCEDURE SetColName*(se: SE; c: INTEGER; name: ARRAY OF CHAR; VAR err: INTEGER);
BEGIN
  err := OK;
  IF se = NIL THEN err := ERR_NIL; RETURN END;
  IF ~GoodCol(se, c) THEN err := ERR_COL; RETURN END;
  COPY(name, se.colNames[c])
END SetColName;

PROCEDURE ColName*(se: SE; c: INTEGER; VAR name: ARRAY OF CHAR);
BEGIN
  IF GoodCol(se, c) THEN
    COPY(se.colNames[c], name)
  ELSE
    name[0] := 0X
  END
END ColName;

(* ---------- rowData ---------- *)

PROCEDURE AddRowDataCol*(se: SE; name: ARRAY OF CHAR; VAR err: INTEGER): INTEGER;
VAR c: INTEGER;
BEGIN
  err := OK;

  IF se = NIL THEN
    err := ERR_NIL;
    RETURN -1
  END;

  IF DataFrame.FindCol(se.rowData, name) >= 0 THEN
    err := ERR_NAME;
    RETURN -1
  END;

  c := DataFrame.AddCol(se.rowData, name);
  IF c < 0 THEN
    err := ERR_FULL;
    RETURN -1
  END;

  RETURN c
END AddRowDataCol;

PROCEDURE FindRowDataCol*(se: SE; name: ARRAY OF CHAR): INTEGER;
BEGIN
  IF se = NIL THEN RETURN -1 END;
  RETURN DataFrame.FindCol(se.rowData, name)
END FindRowDataCol;

PROCEDURE SetRowDataStr*(se: SE; r: INTEGER; colName: ARRAY OF CHAR; val: ARRAY OF CHAR; VAR err: INTEGER);
VAR c: INTEGER;
BEGIN
  err := OK;

  IF se = NIL THEN err := ERR_NIL; RETURN END;
  IF ~GoodRow(se, r) THEN err := ERR_ROW; RETURN END;

  c := DataFrame.FindCol(se.rowData, colName);
  IF c < 0 THEN err := ERR_COL; RETURN END;

  DataFrame.SetStr(se.rowData, r, c, val)
END SetRowDataStr;

PROCEDURE GetRowDataStr*(se: SE; r: INTEGER; colName: ARRAY OF CHAR; VAR val: ARRAY OF CHAR; VAR err: INTEGER);
VAR c: INTEGER;
BEGIN
  err := OK;
  val[0] := 0X;

  IF se = NIL THEN err := ERR_NIL; RETURN END;
  IF ~GoodRow(se, r) THEN err := ERR_ROW; RETURN END;

  c := DataFrame.FindCol(se.rowData, colName);
  IF c < 0 THEN err := ERR_COL; RETURN END;

  DataFrame.GetStr(se.rowData, r, c, val)
END GetRowDataStr;

PROCEDURE SetRowDataInt*(se: SE; r: INTEGER; colName: ARRAY OF CHAR; val: INTEGER; VAR err: INTEGER);
VAR c: INTEGER;
BEGIN
  err := OK;

  IF se = NIL THEN err := ERR_NIL; RETURN END;
  IF ~GoodRow(se, r) THEN err := ERR_ROW; RETURN END;

  c := DataFrame.FindCol(se.rowData, colName);
  IF c < 0 THEN err := ERR_COL; RETURN END;

  DataFrame.SetInt(se.rowData, r, c, val)
END SetRowDataInt;

PROCEDURE SetRowDataReal*(se: SE; r: INTEGER; colName: ARRAY OF CHAR; val: REAL; VAR err: INTEGER);
VAR c: INTEGER;
BEGIN
  err := OK;

  IF se = NIL THEN err := ERR_NIL; RETURN END;
  IF ~GoodRow(se, r) THEN err := ERR_ROW; RETURN END;

  c := DataFrame.FindCol(se.rowData, colName);
  IF c < 0 THEN err := ERR_COL; RETURN END;

  DataFrame.SetReal(se.rowData, r, c, val)
END SetRowDataReal;

(* ---------- colData ---------- *)

PROCEDURE AddColDataCol*(se: SE; name: ARRAY OF CHAR; VAR err: INTEGER): INTEGER;
VAR c: INTEGER;
BEGIN
  err := OK;

  IF se = NIL THEN
    err := ERR_NIL;
    RETURN -1
  END;

  IF DataFrame.FindCol(se.colData, name) >= 0 THEN
    err := ERR_NAME;
    RETURN -1
  END;

  c := DataFrame.AddCol(se.colData, name);
  IF c < 0 THEN
    err := ERR_FULL;
    RETURN -1
  END;

  RETURN c
END AddColDataCol;

PROCEDURE FindColDataCol*(se: SE; name: ARRAY OF CHAR): INTEGER;
BEGIN
  IF se = NIL THEN RETURN -1 END;
  RETURN DataFrame.FindCol(se.colData, name)
END FindColDataCol;

PROCEDURE SetColDataStr*(se: SE; cix: INTEGER; colName: ARRAY OF CHAR; val: ARRAY OF CHAR; VAR err: INTEGER);
VAR c: INTEGER;
BEGIN
  err := OK;

  IF se = NIL THEN err := ERR_NIL; RETURN END;
  IF ~GoodCol(se, cix) THEN err := ERR_COL; RETURN END;

  c := DataFrame.FindCol(se.colData, colName);
  IF c < 0 THEN err := ERR_COL; RETURN END;

  DataFrame.SetStr(se.colData, cix, c, val)
END SetColDataStr;

PROCEDURE GetColDataStr*(se: SE; cix: INTEGER; colName: ARRAY OF CHAR; VAR val: ARRAY OF CHAR; VAR err: INTEGER);
VAR c: INTEGER;
BEGIN
  err := OK;
  val[0] := 0X;

  IF se = NIL THEN err := ERR_NIL; RETURN END;
  IF ~GoodCol(se, cix) THEN err := ERR_COL; RETURN END;

  c := DataFrame.FindCol(se.colData, colName);
  IF c < 0 THEN err := ERR_COL; RETURN END;

  DataFrame.GetStr(se.colData, cix, c, val)
END GetColDataStr;

PROCEDURE SetColDataInt*(se: SE; cix: INTEGER; colName: ARRAY OF CHAR; val: INTEGER; VAR err: INTEGER);
VAR c: INTEGER;
BEGIN
  err := OK;

  IF se = NIL THEN err := ERR_NIL; RETURN END;
  IF ~GoodCol(se, cix) THEN err := ERR_COL; RETURN END;

  c := DataFrame.FindCol(se.colData, colName);
  IF c < 0 THEN err := ERR_COL; RETURN END;

  DataFrame.SetInt(se.colData, cix, c, val)
END SetColDataInt;

PROCEDURE SetColDataReal*(se: SE; cix: INTEGER; colName: ARRAY OF CHAR; val: REAL; VAR err: INTEGER);
VAR c: INTEGER;
BEGIN
  err := OK;

  IF se = NIL THEN err := ERR_NIL; RETURN END;
  IF ~GoodCol(se, cix) THEN err := ERR_COL; RETURN END;

  c := DataFrame.FindCol(se.colData, colName);
  IF c < 0 THEN err := ERR_COL; RETURN END;

  DataFrame.SetReal(se.colData, cix, c, val)
END SetColDataReal;

(* ---------- raw DataFrame access ---------- *)

PROCEDURE RowDataFrame*(se: SE): DataFrame.DataFrame;
BEGIN
  IF se = NIL THEN RETURN NIL END;
  RETURN se.rowData
END RowDataFrame;

PROCEDURE ColDataFrame*(se: SE): DataFrame.DataFrame;
BEGIN
  IF se = NIL THEN RETURN NIL END;
  RETURN se.colData
END ColDataFrame;

(* ---------- metadata ---------- *)

PROCEDURE MetadataPut*(se: SE; key, value: ARRAY OF CHAR; VAR err: INTEGER);
BEGIN
  err := OK;
  IF se = NIL THEN err := ERR_NIL; RETURN END;
  Dict.Put(se.meta, key, value)
END MetadataPut;

PROCEDURE MetadataGet*(se: SE; key: ARRAY OF CHAR; VAR value: ARRAY OF CHAR): BOOLEAN;
BEGIN
  IF se = NIL THEN
    value[0] := 0X;
    RETURN FALSE
  END;
  RETURN Dict.Get(se.meta, key, value)
END MetadataGet;

(* ---------- display ---------- *)

PROCEDURE Info*(se: SE);
VAR i: INTEGER;
BEGIN
  IF se = NIL THEN
    Out.String("SummarizedExperiment: NIL"); Out.Ln;
    RETURN
  END;

  Out.String("SummarizedExperiment: ");
  Out.Int(se.nrows, 0);
  Out.String(" rows x ");
  Out.Int(se.ncols, 0);
  Out.String(" cols"); Out.Ln;

  Out.String("assays: ");
  Out.Int(se.nassays, 0); Out.Ln;

  IF se.nassays > 0 THEN
    Out.String("assayNames: ");
    FOR i := 0 TO se.nassays - 1 DO
      IF i > 0 THEN Out.String(", ") END;
      Out.String(se.assays[i].name)
    END;
    Out.Ln
  END
END Info;

END SummarizedExperiment.
