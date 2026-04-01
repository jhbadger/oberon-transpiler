MODULE smiley;
(*
 * Sprite demo: move a smiley face around with arrow keys.
 * The face changes colour depending on direction of travel.
 * Press Esc to quit.
 *)

IMPORT Graphics, Terminal, Out;

CONST
  KeyUp    = 01X;
  KeyDown  = 02X;
  KeyLeft  = 03X;
  KeyRight = 04X;
  KeyEsc   = 1BX;

  (* Play-area bounds (inside the box border) *)
  XMin = 2;   XMax = 72;   (* smiley is 7 wide  *)
  YMin = 2;   YMax = 20;   (* smiley is 3 tall  *)

VAR
  x, y, color : INTEGER;
  key         : CHAR;
  done        : BOOLEAN;

(* ------------------------------------------------------------------ *)
PROCEDURE DrawFace(px, py, c : INTEGER);
BEGIN
  Graphics.Sprite(px, py,   " .---. ", c);
  Graphics.Sprite(px, py+1, "(o   o)", c);
  Graphics.Sprite(px, py+2, " '---' ", c)
END DrawFace;

PROCEDURE EraseFace(px, py : INTEGER);
BEGIN
  Graphics.Sprite(px, py,   "       ", 7);
  Graphics.Sprite(px, py+1, "       ", 7);
  Graphics.Sprite(px, py+2, "       ", 7)
END EraseFace;

(* ------------------------------------------------------------------ *)
BEGIN
  Graphics.Clear;
  Graphics.Box(1, 1, 80, 23);

  Graphics.Goto(11, 24);
  Out.String("Arrow keys: move   Esc: quit");

  x := 37;  y := 11;  color := 3;
  DrawFace(x, y, color);

  done := FALSE;
  WHILE done = FALSE DO
    key := Terminal.ReadKey();

    IF key = KeyEsc THEN
      done := TRUE
    ELSE
      EraseFace(x, y);

      IF key = KeyUp THEN
        IF y > YMin THEN y := y - 1 END;
        color := 2   (* green: going up   *)
      ELSIF key = KeyDown THEN
        IF y < YMax THEN y := y + 1 END;
        color := 5   (* magenta: going down *)
      ELSIF key = KeyLeft THEN
        IF x > XMin THEN x := x - 1 END;
        color := 6   (* cyan: going left  *)
      ELSIF key = KeyRight THEN
        IF x < XMax THEN x := x + 1 END;
        color := 3   (* yellow: going right *)
      END;

      DrawFace(x, y, color)
    END
  END;

  Graphics.Goto(1, 25)
END smiley.
