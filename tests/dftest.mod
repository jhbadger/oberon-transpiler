MODULE dftest;
(*
 * Demo program for the DataFrame module.
 *
 * Shows:
 *   1. Building a DataFrame manually
 *   2. Typed getters (GetInt, GetReal)
 *   3. FindCol / ColName
 *   4. Loading a CSV from disk
 *)

IMPORT DataFrame, Strings, Out, Args, Files;

VAR
  df:   DataFrame.DataFrame;
  err:  INTEGER;
  row:  INTEGER;
  ival: INTEGER;
  rval: REAL;
  s:    ARRAY DataFrame.CELLLEN OF CHAR;
  fname: ARRAY 256 OF CHAR;

(* ── write a small CSV file for the load demo ── *)
PROCEDURE WriteTestCSV(name: ARRAY OF CHAR);
VAR f: Files.File; r: Files.Rider;
BEGIN
  f := Files.New(name);
  IF f = NIL THEN Out.String("Cannot create "); Out.String(name); Out.Ln; RETURN END;
  Files.Set(r, f, 0);
  Files.WriteString(r, "Name,Age,Score");
  Files.Write(r, 0AX);
  Files.WriteString(r, "Alice,30,9.5");
  Files.Write(r, 0AX);
  Files.WriteString(r, "Bob,25,8.1");
  Files.Write(r, 0AX);
  Files.WriteString(r, "Carol,28,7.9");
  Files.Write(r, 0AX);
  Files.WriteString(r, "Jane,22,9.9");
  Files.Write(r, 0AX);
  Files.Register(f);
  Files.Close(f);
  Out.String("Wrote "); Out.String(name); Out.Ln
END WriteTestCSV;

BEGIN
  (* ── 1. Manual DataFrame ───────────────────────────────────────── *)
  Out.String("=== Manual DataFrame ==="); Out.Ln;
  df := DataFrame.Create();
  DataFrame.AddCol(df, "City");
  DataFrame.AddCol(df, "Population");
  DataFrame.AddCol(df, "Area km2");

  row := DataFrame.AddRow(df); DataFrame.SetStr(df,  row, 0, "Tokyo");   DataFrame.SetInt(df,  row, 1, 13960000); DataFrame.SetReal(df, row, 2, 2194.0);
  row := DataFrame.AddRow(df); DataFrame.SetStr(df,  row, 0, "Delhi");   DataFrame.SetInt(df,  row, 1, 11034555); DataFrame.SetReal(df, row, 2, 1484.0);
  row := DataFrame.AddRow(df); DataFrame.SetStr(df,  row, 0, "Lagos");   DataFrame.SetInt(df,  row, 1,  9000000); DataFrame.SetReal(df, row, 2, 1171.3);
  row := DataFrame.AddRow(df); DataFrame.SetStr(df,  row, 0, "London");  DataFrame.SetInt(df,  row, 1,  8982000); DataFrame.SetReal(df, row, 2, 1572.0);
  row := DataFrame.AddRow(df); DataFrame.SetStr(df,  row, 0, "New York"); DataFrame.SetInt(df, row, 1,  8336817); DataFrame.SetReal(df, row, 2, 783.8);

  DataFrame.Print(df);
  Out.Ln;

  (* ── 2. Typed getters ─────────────────────────────────────────── *)
  Out.String("=== Typed Getters ==="); Out.Ln;
  IF DataFrame.GetInt(df, 0, 1, ival) THEN
    Out.String("Tokyo population (int): "); Out.Int(ival, 0); Out.Ln
  END;
  IF DataFrame.GetReal(df, 0, 2, rval) THEN
    Out.String("Tokyo area (real): "); Out.Real(rval); Out.Ln
  END;

  (* ── 3. FindCol / ColName ─────────────────────────────────────── *)
  Out.Ln;
  Out.String("=== FindCol / ColName ==="); Out.Ln;
  row := DataFrame.FindCol(df, "Population");
  Out.String("FindCol(Population) = "); Out.Int(row, 0); Out.Ln;
  DataFrame.ColName(df, 2, s);
  Out.String("ColName(2) = "); Out.String(s); Out.Ln;
  Out.Ln;

  (* ── 4. Head / Tail ───────────────────────────────────────────── *)
  Out.String("=== Head(3) ==="); Out.Ln;
  DataFrame.Head(df, 3);
  Out.Ln;
  Out.String("=== Tail(2) ==="); Out.Ln;
  DataFrame.Tail(df, 2);
  Out.Ln;

  (* ── 5. Load CSV ──────────────────────────────────────────────── *)
  Out.String("=== Load CSV ==="); Out.Ln;
  WriteTestCSV("dftest.csv");
  Out.Ln;
  df := DataFrame.LoadCSV("dftest.csv", TRUE, err);
  IF err # DataFrame.OK THEN
    Out.String("LoadCSV error: "); Out.Int(err, 0); Out.Ln
  ELSE
    DataFrame.Print(df);
    Out.Ln;
    (* Show that numeric columns parse correctly *)
    IF DataFrame.GetInt(df, 0, 1, ival) THEN
      Out.String("Alice age: "); Out.Int(ival, 0); Out.Ln
    END;
    IF DataFrame.GetReal(df, 0, 2, rval) THEN
      Out.String("Alice score: "); Out.Real(rval); Out.Ln
    END;
    Out.Ln;
    (* Verify last row *)
    DataFrame.GetStr(df, 3, 0, s);
    Out.String("Row 3 Name: ["); Out.String(s); Out.String("]"); Out.Ln
  END

END dftest.
