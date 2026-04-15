MODULE RetroGui;

IMPORT Out, Strings, Base64; (* Assumes a Base64 encoder helper *)

CONST
  ESC = 1BX;
  ST  = 07X; (* Bell used by iTerm2 to terminate sequences *)

TYPE
  Window* = RECORD
    x*, y*, w*, h*: INTEGER;
    title*: ARRAY 64 OF CHAR;
  END;

(** Move the terminal cursor to a specific pixel-cell coordinate **)
PROCEDURE MoveCursor(x, y: INTEGER);
BEGIN
  Out.Char(ESC); Out.String("["); Out.Int(y, 0); Out.Char(";"); Out.Int(x, 0); Out.Char("H");
END MoveCursor;

(** Helper: In a real implementation, you would use a bitmap buffer.
  Here, we wrap the iTerm2 File Transfer Protocol.
**)
PROCEDURE DrawBitmap*(x, y: INTEGER; VAR b64Data: ARRAY OF CHAR);
BEGIN
  MoveCursor(x, y);
  Out.Char(ESC); Out.String("]1337;File=inline=1:");
  Out.String(b64Data);
  Out.Char(ST);
END DrawBitmap;

(** Draw a classic 'Chicago' styled title bar **)
PROCEDURE DrawWindow*(VAR w: Window);
VAR
  i: INTEGER;
BEGIN
  (* Draw Title Bar Background (Striped pattern) *)
  MoveCursor(w.x, w.y);
  Out.String("╔"); 
  FOR i := 0 TO w.w - 2 DO Out.String("═") END; 
  Out.String("╗");
  
  (* Draw Title Text *)
  MoveCursor(w.x + (w.w DIV 2) - (Strings.Length(w.title) DIV 2), w.y);
  Out.Char(" "); Out.String(w.title); Out.Char(" ");

  (* Body of Window (Empty space) *)
  FOR i := 1 TO w.h DO
    MoveCursor(w.x, w.y + i);
    Out.String("║"); 
    (* In a full GUI, you'd put an iTerm2 image here *)
    MoveCursor(w.x + w.w, w.y + i);
    Out.String("║");
  END;

  MoveCursor(w.x, w.y + w.h + 1);
  Out.String("╚");
  FOR i := 0 TO w.w - 2 DO Out.String("═") END;
  Out.String("╝");
END DrawWindow;

(** Simple Button with 1984-style shadow **)
PROCEDURE DrawButton*(x, y: INTEGER; label: ARRAY OF CHAR);
BEGIN
  MoveCursor(x, y);
  Out.String("[ "); Out.String(label); Out.String(" ]");
  (* Drop shadow using block character *)
  MoveCursor(x + 1, y + 1);
  FOR x := 0 TO Strings.Length(label) + 3 DO Out.String("▀") END;
END DrawButton;

END RetroGui.