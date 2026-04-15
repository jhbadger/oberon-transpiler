MODULE Main;

IMPORT Menu, Graphics, In, Out, OS;

VAR
  m: Menu.MenuData;
  choice: INTEGER;
  buf: ARRAY 100 OF CHAR;

BEGIN
  Graphics.Clear();
  
  Menu.Init(m);
  m.bg := 4; (* Red Background for a "Warning" menu style *)
  m.fg := 7; (* White Text *)
  
  Menu.Add(m, "Open Database");
  Menu.Add(m, "Append Records");
  Menu.Add(m, "Generate Report");
  Menu.Add(m, "Exit to DOS");

  Graphics.Goto(5, 4);
  Out.String("--- FoxPro Style Menu ---");
  
  choice := Menu.Run(m, 5, 6);

  Graphics.Goto(1, 15);
  IF choice = 3 THEN
			 OS.Exit(0);
	ELSIF choice = 0 THEN
			Out.String("Name: ");
			In.Line(buf);			
  ELSE
    Out.String("You selected: "); Out.Int(choice + 1, 0); Out.Ln();
  END;
END Main.
