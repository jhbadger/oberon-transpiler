MODULE TestDB;

IMPORT DBF, Out, Strings;

PROCEDURE Run*;
VAR
  db: DBF.Database;
  fields: ARRAY 2 OF DBF.Field;
  recordData: ARRAY 256 OF CHAR;
  title, author: ARRAY 32 OF CHAR;
BEGIN
  (* 1. Define the Schema *)
  fields[0].name := "TITLE";
  fields[0].type := "C"; (* Character *)
  fields[0].len  := 30;
  
  fields[1].name := "AUTHOR";
  fields[1].type := "C";
  fields[1].len  := 20;

  (* 2. Create the Database *)
  Out.String("Creating library.dbf..."); Out.Ln;
  DBF.Create(db, "library.dbf", fields, 2);

  (* 3. Prepare and Append a Record *)
  (* DBF records are fixed-width. We pad the strings with spaces. *)
  title := "The Olymeron Guide";
  author := "N. Wirth";
  
  (* Clear buffer and copy data *)
  recordData := "";
  Strings.Append(title, recordData);
  (* Fill remaining field width with spaces manually or via helper *)
  (* For this example, we assume the data is correctly sized for simplicity *)
  Strings.Append("                ", recordData); 
  Strings.Append(author, recordData);

  DBF.AppendRecord(db, recordData);
  Out.String("Record added."); Out.Ln;

  (* 4. Close the file *)
  DBF.Close(db);
END Run;

BEGIN
  Run;
END TestDB.