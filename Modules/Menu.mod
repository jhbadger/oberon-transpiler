MODULE Menu;

(* Retro dBASE III/FoxPro text-based menu *)

IMPORT Terminal, Out, Strings;

TYPE
  Option* = ARRAY 64 OF CHAR;
  MenuData* = RECORD
    count: INTEGER;
    options: ARRAY 32 OF Option;
    fg, bg: INTEGER;
    highlightFg, highlightBg: INTEGER;
    width: INTEGER;
  END;

(** Initialize a menu with default colors (White on Blue) **)
PROCEDURE Init*(VAR m: MenuData);
BEGIN
  m.count := 0;
  m.width := 20;      (* Default width *)
  m.fg := 7;          (* White *)
  m.bg := 1;          (* Blue *)
  m.highlightFg := 0; (* Black *)
  m.highlightBg := 7; (* White *)
END Init;

(** Add an option and track the widest string for the box size **)
PROCEDURE Add*(VAR m: MenuData; text: ARRAY OF CHAR);
VAR len: INTEGER;
BEGIN
  IF m.count < 32 THEN
    Strings.Copy(text, m.options[m.count]);
    len := Strings.Length(text);
    IF len + 6 > m.width THEN m.width := len + 6 END;
    INC(m.count);
  END;
END Add;

(** Internal: Draw the filled box and options **)
PROCEDURE Draw(VAR m: MenuData; x, y, selected: INTEGER);
VAR i: INTEGER;
BEGIN
  (* Fill the background area *)
  Terminal.Color(m.fg, m.bg);
  Terminal.Fill(x, y, m.width, m.count + 2, ' ');
  
  (* Draw the surrounding box *)
  Terminal.Box(x, y, m.width, m.count + 2);
  
  FOR i := 0 TO m.count - 1 DO
    Terminal.Goto(x + 2, y + i + 1);
    IF i = selected THEN
      Terminal.Color(m.highlightFg, m.highlightBg);
    ELSE
      Terminal.Color(m.fg, m.bg);
    END;
    
    (* Output selection number and text *)
    Out.Int(i + 1, 1); Out.String(". "); Out.String(m.options[i]);
  END;
  Terminal.Reset();
END Draw;

(** Execute the menu loop **)
PROCEDURE Run*(VAR m: MenuData; x, y: INTEGER): INTEGER;
VAR 
  ch: CHAR;
  current, keyVal: INTEGER;
  done: BOOLEAN;
BEGIN
  Terminal.Init();
  current := 0;
  done := FALSE;
  Terminal.HideCursor();
  
  REPEAT
    Draw(m, x, y, current);
    ch := Terminal.ReadKey();
    keyVal := ORD(ch);

    (* Direct Number Selection using Oberon '&' *)
    IF (keyVal >= ORD("1")) & (keyVal < ORD("1") + m.count) THEN
      current := keyVal - ORD("1");
      done := TRUE;
    
    (* Navigation Keys *)
    ELSIF ch = 0A0X THEN (* Up Arrow *)
      IF current > 0 THEN DEC(current) ELSE current := m.count - 1 END;
    ELSIF ch = 0A1X THEN (* Down Arrow *)
      IF current < m.count - 1 THEN INC(current) ELSE current := 0 END;
    ELSIF ch = 0DX THEN (* Enter Key *)
      done := TRUE;
    END;
  UNTIL done;
  
  Terminal.ShowCursor();
 Terminal.Restore();
  RETURN current;
END Run;

END Menu.

