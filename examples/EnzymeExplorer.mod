MODULE EnzymeExplorer;

IMPORT DBF, Menu, Graphics, Out, In, Strings, Terminal;

VAR
  db: DBF.Database;
  dummy: CHAR;

(* Helper for case-insensitive search *)
PROCEDURE Contains(VAR haystack, needle: ARRAY OF CHAR): BOOLEAN;
VAR 
  h, n: ARRAY 256 OF CHAR;
BEGIN
  Strings.Copy(haystack, h);
  Strings.Copy(needle, n);
  Strings.ToUpper(h);
  Strings.ToUpper(n);
  RETURN Strings.Pos(n, h) # -1
END Contains;

PROCEDURE ListFirstTen;
VAR
		 i, limit: INTEGER;
  ec, name: ARRAY 128 OF CHAR;
												 BEGIN
  Graphics.Clear();
  limit := DBF.RecordCount(db);
  IF limit > 10 THEN limit := 10 END;
  
  IF limit = 0 THEN
    Out.String("Database is empty."); Out.Ln;
  ELSE
    FOR i := 0 TO limit - 1 DO
      DBF.GetField(db, i, 0, ec);
      DBF.GetField(db, i, 1, name);
      Out.Int(i + 1, 2); Out.String(". ["); Out.String(ec); 
      Out.String("] "); Out.String(name); Out.Ln;
    END;
  END;
  Out.Ln; Out.String("Press any key...");
  dummy := Terminal.ReadKey();
END ListFirstTen;

PROCEDURE SearchData;
VAR
  query, ec, name: ARRAY 64 OF CHAR;
  i, count, found: INTEGER;
  dummy: CHAR;
	BEGIN
    Graphics.Clear();
		Terminal.Restore();
  Out.String("Search (Case-Insensitive): ");
  In.Line(query);
  Strings.Trim(query);
  
  (* 3. If you just press Enter, return to menu *)
  IF query = "" THEN RETURN END;

  count := DBF.RecordCount(db);
  found := 0;
  Out.Ln;

  (* 4. Search through the DBF file *)
  FOR i := 0 TO count - 1 DO
    DBF.GetField(db, i, 0, ec);
    DBF.GetField(db, i, 1, name);
    
    IF Contains(ec, query) OR Contains(name, query) THEN
      Out.String("["); Out.String(ec); Out.String("] "); 
      Out.String(name); Out.Ln;
      INC(found);
      
      (* Pagination: Pause every 15 results *)
      IF (found > 0) & (found MOD 15 = 0) THEN
        Out.String("-- Press any key for more --");
        dummy := Terminal.ReadKey();
        Out.Ln;
      END
    END
  END;

  (* 5. Display results summary *)
  Out.Ln;
  IF found = 0 THEN 
    Out.String("No matches found for: "); Out.String(query);
  ELSE 
    Out.Int(found, 0); Out.String(" matches found.");
  END;
  
  Out.Ln; Out.String("Press any key to return to menu...");
  dummy := Terminal.ReadKey();
END SearchData;

VAR
  m: Menu.MenuData;
  choice: INTEGER;
BEGIN
  DBF.Open(db, "enzyme.dbf");
  IF db.f = NIL THEN
    Out.String("Error: enzyme.dbf not found."); Out.Ln;
    RETURN
  END;

  Menu.Init(m);
  Menu.Add(m, "Search Database");
  Menu.Add(m, "List First 10");
  Menu.Add(m, "Exit");

  LOOP
    Graphics.Clear();	
    choice := Menu.Run(m, 10, 5);
    IF choice = 0 THEN SearchData
    ELSIF choice = 1 THEN ListFirstTen
    ELSIF (choice = 2) OR (choice = -1) THEN EXIT
    END
  END;

  DBF.Close(db);
END EnzymeExplorer.
