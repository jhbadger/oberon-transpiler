MODULE RetroMacDemo;

IMPORT RetroGui, Terminal, Graphics, Out, Strings;

PROCEDURE DrawDesktop;
VAR x, y: INTEGER;
BEGIN
  Graphics.Clear;
  (* Fill background with the classic Mac 'grey' pattern using Unicode *)
  Graphics.Color(7, 0); (* Light grey on Black *)
  FOR y := 0 TO 24 DO
    Graphics.Goto(0, y);
    FOR x := 0 TO 79 DO Out.String("▒") END;
  END;
  
  (* Draw the Top Menu Bar *)
  Graphics.Goto(0, 0);
  Graphics.Color(0, 7); (* Black on White *)
  FOR x := 0 TO 79 DO Out.String(" ") END;
  Graphics.Goto(2, 0); Out.String("  File  Edit  View  Special");
END DrawDesktop;

PROCEDURE ShowEnzymeWindow;
VAR w: RetroGui.Window;
BEGIN
  w.x := 10; w.y := 5; w.w := 45; w.h := 10;
  Strings.Copy("Enzyme: 1.1.1.1", w.title);
  
  RetroGui.DrawWindow(w);
  
  (* Content inside the window *)
  Graphics.Color(0, 7);
  Graphics.Goto(w.x + 2, w.y + 2); Out.String("Name: Alcohol Dehydrogenase");
  Graphics.Goto(w.x + 2, w.y + 4); Out.String("Reaction:");
  Graphics.Goto(w.x + 4, w.y + 5); Out.String("Aldehyde + NADH + H+");
  Graphics.Goto(w.x + 10, w.y + 6); Out.String("<--->");
  Graphics.Goto(w.x + 4, w.y + 7); Out.String("Alcohol + NAD+");
  
  RetroGui.DrawButton(w.x + 30, w.y + 9, "OK");
END ShowEnzymeWindow;

PROCEDURE Run*;
VAR ch: CHAR;
BEGIN
  DrawDesktop;
  ShowEnzymeWindow;
  
  (* Status bar / Instructions at bottom *)
  Graphics.Goto(0, 24);
  Graphics.Color(0, 7);
  Out.String(" Retro-Oberon OS | Press 'M' for Menu, 'Q' to Quit ");
  
  REPEAT
    ch := Terminal.ReadKey();
    IF (ch = "m") OR (ch = "M") THEN
      Graphics.Goto(5, 1);
      Out.String("┌──────────────┐"); Graphics.Goto(5, 2);
      Out.String("│ New Search   │"); Graphics.Goto(5, 3);
      Out.String("│ Save Record  │"); Graphics.Goto(5, 4);
      Out.String("│──────────────│"); Graphics.Goto(5, 5);
      Out.String("│ Quit         │"); Graphics.Goto(5, 6);
      Out.String("└──────────────┘");
    END;
  UNTIL (ch = "q") OR (ch = "Q");
  
  Graphics.Clear;
  Terminal.ShowCursor;
END Run;

BEGIN
  Run;
END RetroMacDemo.