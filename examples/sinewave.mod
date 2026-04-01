MODULE SineWave;
(*
 * Plots sin(x), cos(x), and sin(x)+cos(x) across the terminal
 * using the Graphics and Math modules.
 *)
IMPORT Graphics, Math, Out;

CONST
  W = 76;   (* plot width  *)
  H = 20;   (* plot height *)

VAR
  col, row, mid, y : INTEGER;
  x, v             : REAL;
  ch               : CHAR;

BEGIN
  Graphics.Clear;

  mid := H DIV 2;

  (* axes *)
  Graphics.Color256(8, 0);
  Graphics.HLine(3, mid + 2, W, '-');
  Graphics.VLine(3 + W DIV 2, 1, H + 3, '|');
  Graphics.Reset;

  (* plot three curves *)
  FOR col := 0 TO W - 1 DO
    x := (col - W DIV 2) * Math.pi / (W DIV 4);

    (* sin(x) – red *)
    v   := Math.sin(x);
    row := mid - Math.entier(v * (H DIV 2 - 1) + 0.5);
    IF (row >= 1) & (row <= H) THEN
      Graphics.Color256(196, 0);
      Graphics.Goto(col + 3, row + 1);
      Out.Char('*')
    END;

    (* cos(x) – cyan *)
    v   := Math.cos(x);
    row := mid - Math.entier(v * (H DIV 2 - 1) + 0.5);
    IF (row >= 1) & (row <= H) THEN
      Graphics.Color256(51, 0);
      Graphics.Goto(col + 3, row + 1);
      Out.Char('+')
    END;

    (* sin+cos – yellow *)
    v   := (Math.sin(x) + Math.cos(x)) / Math.sqrt(2.0);
    row := mid - Math.entier(v * (H DIV 2 - 1) + 0.5);
    IF (row >= 1) & (row <= H) THEN
      Graphics.Color256(226, 0);
      Graphics.Goto(col + 3, row + 1);
      Out.Char('o')
    END
  END;

  Graphics.Reset;
  Graphics.Box(2, 1, W + 2, H + 3);

  Graphics.Color256(196, 0); Graphics.Goto(4, H + 4); Out.String("* sin(x)");
  Graphics.Color256(51,  0); Graphics.Goto(14, H + 4); Out.String("+ cos(x)");
  Graphics.Color256(226, 0); Graphics.Goto(24, H + 4); Out.String("o (sin+cos)/sqrt(2)");
  Graphics.Reset;
  Graphics.Goto(4, H + 5); Out.String("press Enter");

  READ(ch)
END SineWave.
