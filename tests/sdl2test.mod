MODULE SDL2Demo;
(*
 * Multi-mode visual demonstration of the SDL2 FFI binding.
 *
 * Mode 0 — Starfield   200 stars flying toward the viewer (3-D warp)
 * Mode 1 — Balls       10 shaded circles bouncing off the walls
 * Mode 2 — Plasma      animated sine-wave colour field (8 × 8 pixel blocks)
 * Mode 3 — Paint       free-draw with the mouse; each click cycles the colour
 *
 * Controls
 *   Tab / Right   next mode
 *   Space         reset / clear current mode
 *   Esc           quit
 *
 * The window title always shows the active mode and key hints.
 *)

IMPORT SDL2, Math, Out;

CONST
  W = 800; H = 600;
  NStars = 200;
  NBalls = 10;

VAR
  win:  SDL2.Window;
  ren:  SDL2.Renderer;
  ev:   SDL2.Event;
  running: BOOLEAN;
  mode, frame: INTEGER;
  seed: INTEGER;

  (* Mode 0 — starfield *)
  starX, starY, starZ: ARRAY NStars OF REAL;

  (* Mode 1 — bouncing balls *)
  bx, by, bdx, bdy: ARRAY NBalls OF REAL;
  br, bg, bb:       ARRAY NBalls OF INTEGER;
  brad:             ARRAY NBalls OF INTEGER;

  (* Mode 3 — paint *)
  mouseDown: BOOLEAN;
  brushCol:  INTEGER;

  (* scratch variables used in the main loop *)
  k, mx, my, pr, pg, pb: INTEGER;

(* ── Pseudo-random helpers ───────────────────────────────────────────────── *)

PROCEDURE RandF(): REAL;
BEGIN
  seed := seed * 1664525 + 1013904223;
  RETURN FLT(ABS(seed) MOD 100000) * 0.00001
END RandF;

PROCEDURE RandN(n: INTEGER): INTEGER;
BEGIN
  seed := seed * 1664525 + 1013904223;
  IF n <= 0 THEN RETURN 0 END;
  RETURN ABS(seed) MOD n
END RandN;

(* ── Filled circle via Bresenham horizontal scan-fills ───────────────────── *)

PROCEDURE FilledCircle(cx, cy, r: INTEGER);
VAR x, y, d: INTEGER;
BEGIN
  IF r <= 0 THEN SDL2.DrawPoint(ren, cx, cy); RETURN END;
  x := 0; y := r; d := 3 - 2 * r;
  WHILE y >= x DO
    SDL2.DrawLine(ren, cx - x, cy + y, cx + x, cy + y);
    SDL2.DrawLine(ren, cx - x, cy - y, cx + x, cy - y);
    SDL2.DrawLine(ren, cx - y, cy + x, cx + y, cy + x);
    SDL2.DrawLine(ren, cx - y, cy - x, cx + y, cy - x);
    INC(x);
    IF d > 0 THEN
      DEC(y);
      d := d + 4 * (x - y) + 10
    ELSE
      d := d + 4 * x + 6
    END
  END
END FilledCircle;

(* ── Mode 0 — Starfield ──────────────────────────────────────────────────── *)

PROCEDURE InitStars;
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE i < NStars DO
    starX[i] := (RandF() - 0.5) * 2.0;
    starY[i] := (RandF() - 0.5) * 2.0;
    starZ[i] := RandF();
    INC(i)
  END
END InitStars;

PROCEDURE DrawStars;
VAR i, px, py, sz, bright: INTEGER;
    pxf, pyf: REAL;
BEGIN
  SDL2.SetDrawColor(ren, 0, 0, 0, 255);
  SDL2.Clear(ren);
  i := 0;
  WHILE i < NStars DO
    starZ[i] := starZ[i] - 0.006;
    IF starZ[i] < 0.01 THEN
      starX[i] := (RandF() - 0.5) * 2.0;
      starY[i] := (RandF() - 0.5) * 2.0;
      starZ[i] := 1.0
    END;
    pxf := starX[i] / starZ[i] * 400.0 + 400.0;
    pyf := starY[i] / starZ[i] * 300.0 + 300.0;
    px := Math.entier(pxf);
    py := Math.entier(pyf);
    IF (px >= 0) & (px < W) & (py >= 0) & (py < H) THEN
      bright := Math.entier((1.0 - starZ[i]) * 255.0);
      IF bright > 255 THEN bright := 255 END;
      sz := Math.entier((1.0 - starZ[i]) * 3.0) + 1;
      SDL2.SetDrawColor(ren, bright, bright, bright, 255);
      IF sz > 1 THEN
        SDL2.FillRect(ren, px - sz DIV 2, py - sz DIV 2, sz, sz)
      ELSE
        SDL2.DrawPoint(ren, px, py)
      END
    END;
    INC(i)
  END
END DrawStars;

(* ── Mode 1 — Bouncing balls ─────────────────────────────────────────────── *)

PROCEDURE InitBalls;
VAR i, rad: INTEGER;
BEGIN
  i := 0;
  WHILE i < NBalls DO
    rad     := RandN(22) + 14;
    brad[i] := rad;
    bx[i]   := FLT(RandN(W - 2 * rad) + rad);
    by[i]   := FLT(RandN(H - 2 * rad) + rad);
    bdx[i]  := (RandF() - 0.5) * 8.0;
    bdy[i]  := (RandF() - 0.5) * 8.0;
    IF (bdx[i] > -0.6) & (bdx[i] < 0.6) THEN bdx[i] := 1.5 END;
    IF (bdy[i] > -0.6) & (bdy[i] < 0.6) THEN bdy[i] := 1.5 END;
    br[i]   := RandN(156) + 100;
    bg[i]   := RandN(156) + 100;
    bb[i]   := RandN(156) + 100;
    INC(i)
  END
END InitBalls;

PROCEDURE DrawBalls;
VAR i, ix, iy, hl: INTEGER;
BEGIN
  SDL2.SetDrawColor(ren, 10, 10, 25, 255);
  SDL2.Clear(ren);
  i := 0;
  WHILE i < NBalls DO
    bx[i] := bx[i] + bdx[i];
    by[i] := by[i] + bdy[i];
    IF (bx[i] - FLT(brad[i]) < 0.0) OR (bx[i] + FLT(brad[i]) > FLT(W)) THEN
      bdx[i] := -bdx[i];
      bx[i]  := bx[i] + 2.0 * bdx[i]
    END;
    IF (by[i] - FLT(brad[i]) < 0.0) OR (by[i] + FLT(brad[i]) > FLT(H)) THEN
      bdy[i] := -bdy[i];
      by[i]  := by[i] + 2.0 * bdy[i]
    END;
    ix := Math.entier(bx[i]);
    iy := Math.entier(by[i]);
    (* drop shadow *)
    SDL2.SetDrawColor(ren, br[i] DIV 5, bg[i] DIV 5, bb[i] DIV 5, 255);
    FilledCircle(ix + 5, iy + 6, brad[i]);
    (* body *)
    SDL2.SetDrawColor(ren, br[i], bg[i], bb[i], 255);
    FilledCircle(ix, iy, brad[i]);
    (* specular highlight *)
    hl := brad[i] DIV 5 + 1;
    SDL2.SetDrawColor(ren, 255, 255, 255, 255);
    FilledCircle(ix - brad[i] DIV 3, iy - brad[i] DIV 3, hl);
    INC(i)
  END
END DrawBalls;

(* ── Mode 2 — Plasma ─────────────────────────────────────────────────────── *)

PROCEDURE DrawPlasma;
VAR x, y, r, g, b: INTEGER;
    t, v, fx, fy: REAL;
BEGIN
  t := FLT(frame) * 0.04;
  y := 0;
  WHILE y < H DO
    fy := FLT(y);
    x := 0;
    WHILE x < W DO
      fx := FLT(x);
      v := Math.sin(fx * 0.020 + t)
         + Math.sin(fy * 0.025 + t * 0.71)
         + Math.sin((fx + fy) * 0.015 + t * 1.30)
         + Math.cos((fx - fy) * 0.012 - t * 0.90);
      (* rotate through hue space using 120-degree-offset sines *)
      r := Math.entier((Math.sin(v * 1.4        ) * 0.5 + 0.5) * 255.0);
      g := Math.entier((Math.sin(v * 1.4 + 2.094) * 0.5 + 0.5) * 255.0);
      b := Math.entier((Math.sin(v * 1.4 + 4.189) * 0.5 + 0.5) * 255.0);
      SDL2.SetDrawColor(ren, r, g, b, 255);
      SDL2.FillRect(ren, x, y, 8, 8);
      x := x + 8
    END;
    y := y + 8
  END
END DrawPlasma;

(* ── Mode 3 — Paint ──────────────────────────────────────────────────────── *)

PROCEDURE BrushRGB(col: INTEGER; VAR r, g, b: INTEGER);
BEGIN
  IF    col = 0 THEN r := 255; g :=  70; b :=  70   (* red    *)
  ELSIF col = 1 THEN r :=  70; g := 255; b :=  70   (* green  *)
  ELSIF col = 2 THEN r :=  70; g :=  70; b := 255   (* blue   *)
  ELSIF col = 3 THEN r := 255; g := 220; b :=  50   (* yellow *)
  ELSIF col = 4 THEN r := 255; g :=  70; b := 220   (* pink   *)
  ELSE               r :=  70; g := 220; b := 255   (* cyan   *)
  END
END BrushRGB;

PROCEDURE ClearCanvas;
BEGIN
  SDL2.SetDrawColor(ren, 15, 15, 20, 255);
  SDL2.Clear(ren)
END ClearCanvas;

(* ── Window title ────────────────────────────────────────────────────────── *)

PROCEDURE SetTitle(m: INTEGER);
BEGIN
  IF    m = 0 THEN SDL2.SetWindowTitle(win, "Starfield  [Tab=next  Space=reset  Esc=quit]")
  ELSIF m = 1 THEN SDL2.SetWindowTitle(win, "Balls  [Tab=next  Space=reset  Esc=quit]")
  ELSIF m = 2 THEN SDL2.SetWindowTitle(win, "Plasma  [Tab=next  Esc=quit]")
  ELSE              SDL2.SetWindowTitle(win, "Paint  [Tab=next  Click=colour  Space=clear  Esc=quit]")
  END
END SetTitle;

(* ── Main ────────────────────────────────────────────────────────────────── *)

BEGIN
  IF SDL2.Init(SDL2.InitVideo) < 0 THEN
    Out.String("SDL2.Init failed"); Out.Ln;
    HALT(1)
  END;

  seed := SDL2.GetTicks() + 12345;

  win := SDL2.CreateWindow("SDL2 Demo", W, H, SDL2.WinShown);
  IF win = NIL THEN
    Out.String("CreateWindow failed"); Out.Ln;
    SDL2.Quit();
    HALT(1)
  END;

  ren := SDL2.CreateRenderer(win, SDL2.RendAccelerated);
  IF ren = NIL THEN
    ren := SDL2.CreateRenderer(win, SDL2.RendSoftware)
  END;

  NEW(ev);
  mode := 0; frame := 0;
  mouseDown := FALSE; brushCol := 0;

  InitStars;
  InitBalls;
  SetTitle(0);

  Out.String("Modes: Starfield / Balls / Plasma / Paint");
  Out.Ln;
  Out.String("Tab=next  Space=reset  Esc=quit  (click in Paint to change colour)");
  Out.Ln;

  running := TRUE;
  WHILE running DO

    (* ── Process all pending events ── *)
    WHILE SDL2.PollEvent(ev) > 0 DO
      k := SDL2.EventKind(ev);

      IF k = SDL2.EvQuit THEN
        running := FALSE

      ELSIF k = SDL2.EvKeyDown THEN
        IF    SDL2.EventKey(ev) = SDL2.KEsc THEN
          running := FALSE
        ELSIF (SDL2.EventKey(ev) = SDL2.KTab)   OR
              (SDL2.EventKey(ev) = SDL2.KRight)  THEN
          mode := (mode + 1) MOD 4;
          IF    mode = 0 THEN InitStars
          ELSIF mode = 1 THEN InitBalls
          ELSIF mode = 3 THEN ClearCanvas
          END;
          SetTitle(mode)
        ELSIF SDL2.EventKey(ev) = SDL2.KSpace THEN
          IF    mode = 0 THEN InitStars
          ELSIF mode = 1 THEN InitBalls
          ELSIF mode = 3 THEN ClearCanvas
          END
        END

      ELSIF k = SDL2.EvMouseDown THEN
        mouseDown := TRUE;
        IF mode = 3 THEN
          brushCol := (brushCol + 1) MOD 6
        END

      ELSIF k = SDL2.EvMouseUp THEN
        mouseDown := FALSE

      ELSIF k = SDL2.EvMouseMotion THEN
        IF mouseDown & (mode = 3) THEN
          mx := SDL2.EventMouseX(ev);
          my := SDL2.EventMouseY(ev);
          BrushRGB(brushCol, pr, pg, pb);
          SDL2.SetDrawColor(ren, pr, pg, pb, 255);
          FilledCircle(mx, my, 10)
        END
      END
    END;

    (* ── Render frame ── *)
    IF    mode = 0 THEN DrawStars
    ELSIF mode = 1 THEN DrawBalls
    ELSIF mode = 2 THEN DrawPlasma
    (* mode = 3: canvas is persistent — don't clear between frames *)
    END;

    SDL2.Present(ren);
    SDL2.Delay(16);
    INC(frame)
  END;

  SDL2.DestroyRenderer(ren);
  SDL2.DestroyWindow(win);
  SDL2.Quit()
END SDL2Demo.
