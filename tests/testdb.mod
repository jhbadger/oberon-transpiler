MODULE TestDB;

IMPORT DBF, Out;

PROCEDURE Run*;
VAR
  db:     DBF.Database;
  fields: ARRAY 2 OF DBF.Field;
  packed: ARRAY 256 OF CHAR;
  found:  INTEGER;
  vr:     DBF.ValidationResult;
BEGIN
  Out.String("Step 1: define schema"); Out.Ln;
  DBF.MakeField(fields[0], "TITLE",  DBF.TypeChar, 30, 0);
  DBF.MakeField(fields[1], "AUTHOR", DBF.TypeChar, 20, 0);

  Out.String("Step 2: create"); Out.Ln;
  DBF.Create(db, "library.dbf", fields, 2);
  IF db.f = NIL THEN
    Out.String("ERROR: could not create library.dbf"); Out.Ln;
    RETURN
  END;

  Out.String("Step 3: append"); Out.Ln;
  DBF.AppendFields(db, "The Olymeron Guide|N. Wirth");
  Out.String("  appended 1"); Out.Ln;
  DBF.AppendFields(db, "Programming in Oberon|M. Reiser");
  Out.String("  appended 2"); Out.Ln;
  DBF.AppendFields(db, "Compiler Construction|N. Wirth");
  Out.String("  appended 3"); Out.Ln;

  Out.String("Step 4: find"); Out.Ln;
  found := DBF.Find(db, 1, "N. Wirth");
  IF found >= 0 THEN
    DBF.GetRecord(db, found, packed);
    Out.String("First Wirth book: "); Out.String(packed); Out.Ln;
  END;

  Out.String("Step 5: update"); Out.Ln;
  DBF.UpdateField(db, 0, 0, "Programming with Oberon");

  Out.String("Step 6: delete"); Out.Ln;
  DBF.Delete(db, 1);

  Out.String("Step 7: validate"); Out.Ln;
  DBF.Validate(db, vr);
  IF vr.ok THEN
    Out.String("Validation passed."); Out.Ln;
  ELSE
    Out.String("Validation failed at record ");
    Out.Int(vr.recNum, 0); Out.String(": "); Out.String(vr.msg); Out.Ln;
  END;

  Out.String("Step 8: export CSV"); Out.Ln;
  DBF.ExportCSV(db, "library.csv");

  Out.String("Step 9: pack"); Out.Ln;
  DBF.Pack(db, "library.dbf");
  Out.String("Records remaining: "); Out.Int(DBF.RecordCount(db), 0); Out.Ln;

  Out.String("Step 10: close"); Out.Ln;
  DBF.Close(db);
  Out.String("Done."); Out.Ln;
END Run;

BEGIN
  Run;
END TestDB.