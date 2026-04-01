MODULE gfxtest;

IMPORT Graphics;

VAR
    i : INTEGER;

BEGIN
    Graphics.Clear();
    Graphics.ClearBuf();

    (* Five concentric circles, each a different colour *)
    Graphics.Circle(60, 48, 40, 1);
    Graphics.Circle(60, 48, 30, 2);
    Graphics.Circle(60, 48, 20, 3);
    Graphics.Circle(60, 48, 12, 4);
    Graphics.Circle(60, 48,  5, 5);

    (* A few individual pixels to check Plot *)
    i := 0;
    WHILE i < 120 DO
        Graphics.Plot(i, 48, 6);
        i := i + 1;
    END;

    Graphics.Flush();

    (* Sprite drawn in the lower-right corner *)
    Graphics.Sprite(140, 8, " /\_/\ ", 3);
    Graphics.Sprite(140, 9, "( o.o )", 3);
    Graphics.Sprite(140, 10, " > ^ < ", 3);

    Graphics.Goto(1, 55);
END gfxtest.
