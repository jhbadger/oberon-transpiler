MODULE gfxtest;

IMPORT Terminal;

VAR
    i : INTEGER;

BEGIN
    Terminal.Clear();
    Terminal.ClearBuf();

    (* Five concentric circles using 256-colour palette *)
    Terminal.Circle(60, 48, 40, 196);  (* red        *)
    Terminal.Circle(60, 48, 30,  46);  (* green      *)
    Terminal.Circle(60, 48, 20,  27);  (* blue       *)
    Terminal.Circle(60, 48, 12, 226);  (* yellow     *)
    Terminal.Circle(60, 48,  5, 201);  (* magenta    *)

    (* Gradient line across the full 256-colour cube *)
    i := 0;
    WHILE i < 120 DO
        Terminal.Plot(i, 48, 17 + (i * 215) DIV 120);
        i := i + 1;
    END;

    Terminal.Flush();

    (* Sprite drawn in the lower-right corner *)
    Terminal.Sprite(140, 8, " /\_/\ ", 3);
    Terminal.Sprite(140, 9, "( o.o )", 3);
    Terminal.Sprite(140, 10, " > ^ < ", 3);

    Terminal.Goto(1, 55);
END gfxtest.
