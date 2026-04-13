MODULE gfxtest;

IMPORT Graphics;

VAR
    i : INTEGER;

BEGIN
    Graphics.Clear();
    Graphics.ClearBuf();

    (* Five concentric circles using 256-colour palette *)
    Graphics.Circle(60, 48, 40, 196);  (* red        *)
    Graphics.Circle(60, 48, 30,  46);  (* green      *)
    Graphics.Circle(60, 48, 20,  27);  (* blue       *)
    Graphics.Circle(60, 48, 12, 226);  (* yellow     *)
    Graphics.Circle(60, 48,  5, 201);  (* magenta    *)

    (* Gradient line across the full 256-colour cube *)
    i := 0;
    WHILE i < 120 DO
        Graphics.Plot(i, 48, 17 + (i * 215) DIV 120);
        i := i + 1;
    END;

    Graphics.Flush();

    (* Sprite drawn in the lower-right corner *)
    Graphics.Sprite(140, 8, " /\_/\ ", 3);
    Graphics.Sprite(140, 9, "( o.o )", 3);
    Graphics.Sprite(140, 10, " > ^ < ", 3);

    Graphics.Goto(1, 55);
END gfxtest.
