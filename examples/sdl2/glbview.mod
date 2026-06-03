MODULE glbview;
(*
  glbview — SDL2 / OpenGL 3.3 GLB model viewer.

  Usage:  glbview <file.glb>

  Controls:
    Left-drag       Rotate (Y and X axes)
    Scroll wheel    Zoom in / out
    Arrow keys      Rotate (Left/Right = Y, Up/Down = X)
    R               Reset view
    +  /  -         Zoom in / out
    Esc / Q         Quit
*)

IMPORT SDL2, GLBView, Math, Args, Out;

CONST
  WinW = 900; WinH = 700;

  RotStep  = 0.04;
  ZoomStep = 1.1;

VAR
  win         : SDL2.Window;
  glctx       : SDL2.GLCtx;
  ev          : SDL2.Event;
  running     : BOOLEAN;
  rotX, rotY  : REAL;
  zoom        : REAL;
  dragActive  : BOOLEAN;
  dragLastX   : INTEGER;
  dragLastY   : INTEGER;
  winW, winH  : INTEGER;
  path        : ARRAY 1024 OF CHAR;
  errBuf      : ARRAY 512 OF CHAR;
  tmp         : ARRAY 32 OF CHAR;
  vtxCount    : INTEGER;
  triCount    : INTEGER;

PROCEDURE ResetView;
BEGIN
  rotX := 0.0; rotY := 0.0; zoom := 1.0
END ResetView;

BEGIN
  IF Args.Count() < 1 THEN
    Out.String("Usage: glbview <file.glb>"); Out.Ln; HALT(1)
  END;
  Args.Get(1, path);

  IF SDL2.Init(SDL2.InitVideo) < 0 THEN
    Out.String("SDL2.Init failed"); Out.Ln; HALT(1)
  END;

  GLBView.SetAttribs();

  win := SDL2.CreateWindow("GLB Viewer  [drag=rotate  scroll=zoom  R=reset  Q=quit]",
                            WinW, WinH,
                            SDL2.WinShown + SDL2.WinOpenGL + SDL2.WinResizable);
  IF win = NIL THEN
    Out.String("SDL2.CreateWindow failed"); Out.Ln;
    SDL2.Quit();
    HALT(1)
  END;

  glctx := SDL2.GL_CreateContext(win);
  IF glctx = NIL THEN
    Out.String("SDL2.GL_CreateContext failed"); Out.Ln;
    SDL2.DestroyWindow(win);
    SDL2.Quit();
    HALT(1)
  END;

  IF GLBView.Init() = 0 THEN
    GLBView.GetLastError(errBuf);
    Out.String("GLBView.Init failed: "); Out.String(errBuf); Out.Ln;
    SDL2.GL_DeleteContext(glctx);
    SDL2.DestroyWindow(win);
    SDL2.Quit();
    HALT(1)
  END;

  IF GLBView.Load(path) = 0 THEN
    GLBView.GetLastError(errBuf);
    Out.String("Load failed: "); Out.String(errBuf); Out.Ln;
    GLBView.Done();
    SDL2.GL_DeleteContext(glctx);
    SDL2.DestroyWindow(win);
    SDL2.Quit();
    HALT(1)
  END;

  vtxCount := GLBView.VertexCount();
  triCount := GLBView.TriangleCount();
  Out.String("Loaded "); Out.String(path); Out.Ln;
  Out.String("  Vertices: "); Out.Int(vtxCount, 0); Out.Ln;
  Out.String("  Triangles: "); Out.Int(triCount, 0); Out.Ln;

  ResetView();
  dragActive := FALSE; dragLastX := 0; dragLastY := 0;
  winW := WinW; winH := WinH;
  NEW(ev);
  running := TRUE;

  WHILE running DO
    WHILE SDL2.PollEvent(ev) > 0 DO
      IF SDL2.EventKind(ev) = SDL2.EvQuit THEN
        running := FALSE

      ELSIF SDL2.EventKind(ev) = SDL2.EvKeyDown THEN
        IF    (SDL2.EventKey(ev) = SDL2.KEsc)
           OR (SDL2.EventKey(ev) = ORD("Q"))
           OR (SDL2.EventKey(ev) = ORD("q")) THEN
          running := FALSE
        ELSIF (SDL2.EventKey(ev) = ORD("R"))
           OR (SDL2.EventKey(ev) = ORD("r")) THEN
          ResetView()
        ELSIF (SDL2.EventKey(ev) = ORD("+"))
           OR (SDL2.EventKey(ev) = ORD("=")) THEN
          zoom := zoom * ZoomStep
        ELSIF  SDL2.EventKey(ev) = ORD("-") THEN
          zoom := zoom / ZoomStep
        ELSIF  SDL2.EventKey(ev) = SDL2.KLeft  THEN rotY := rotY - RotStep
        ELSIF  SDL2.EventKey(ev) = SDL2.KRight THEN rotY := rotY + RotStep
        ELSIF  SDL2.EventKey(ev) = SDL2.KUp    THEN rotX := rotX - RotStep
        ELSIF  SDL2.EventKey(ev) = SDL2.KDown  THEN rotX := rotX + RotStep
        END

      ELSIF SDL2.EventKind(ev) = SDL2.EvMouseDown THEN
        IF SDL2.EventMouseBtn(ev) = SDL2.BtnLeft THEN
          dragActive := TRUE;
          dragLastX  := SDL2.EventMouseX(ev);
          dragLastY  := SDL2.EventMouseY(ev)
        END

      ELSIF SDL2.EventKind(ev) = SDL2.EvMouseUp THEN
        IF SDL2.EventMouseBtn(ev) = SDL2.BtnLeft THEN
          dragActive := FALSE
        END

      ELSIF SDL2.EventKind(ev) = SDL2.EvMouseMotion THEN
        IF dragActive THEN
          rotY := rotY + FLT(SDL2.EventMouseX(ev) - dragLastX) * 0.008;
          rotX := rotX + FLT(SDL2.EventMouseY(ev) - dragLastY) * 0.008;
          dragLastX := SDL2.EventMouseX(ev);
          dragLastY := SDL2.EventMouseY(ev)
        END

      ELSIF SDL2.EventKind(ev) = SDL2.EvMouseWheel THEN
        IF SDL2.EventWheelY(ev) > 0 THEN
          zoom := zoom * ZoomStep
        ELSIF SDL2.EventWheelY(ev) < 0 THEN
          zoom := zoom / ZoomStep
        END

      ELSIF SDL2.EventKind(ev) = SDL2.EvWindowEvent THEN
        IF SDL2.EventWinEv(ev) = SDL2.WinEvResized THEN
          winW := SDL2.WindowWidth(win);
          winH := SDL2.WindowHeight(win)
        END
      END
    END;

    GLBView.Render(winW, winH, rotX, rotY, zoom);
    SDL2.GL_SwapWindow(win);
    SDL2.Delay(8)   (* ~120 fps cap *)
  END;

  GLBView.Done();
  SDL2.GL_DeleteContext(glctx);
  SDL2.DestroyWindow(win);
  SDL2.Quit()
END glbview.
