MODULE GLBViewer;

(*
 * GLB / GLTF model viewer.
 *
 * Usage:  glbviewer <model.glb>
 *
 * Controls:
 *   Left-drag / arrow keys : orbit
 *   Scroll                 : zoom in / out
 *   Esc / close            : quit
 *)

IMPORT Raylib, GLBLoad, Args, Strings, Math;

CONST
  W = 900;  H = 700;
  MOUSE_LEFT = 0;

VAR
  cam            : Raylib.Camera;
  mdl            : Raylib.Model;
  path           : ARRAY 512 OF CHAR;
  title          : ARRAY 512 OF CHAR;
  cWhite, cDark, cGray : INTEGER;
  cx, cy, cz, span    : REAL;
  minX, minY, minZ     : REAL;
  maxX, maxY, maxZ     : REAL;
  yaw, pitch, dist     : REAL;
  px, py, pz           : REAL;

BEGIN
  IF Args.Count() < 1 THEN
    WRITE("Usage: glbviewer <model.glb>");
    HALT(1)
  END;
  Args.Get(1, path);

  cWhite := Raylib.RayWhite();
  cDark  := Raylib.DarkGray();
  cGray  := Raylib.Gray();

  title := "GLB Viewer: ";
  Strings.Append(path, title);

  Raylib.InitWindow(W, H, title);
  Raylib.SetTargetFPS(60);

  mdl := GLBLoad.LoadModel(path);

  Raylib.QueryModelBounds(mdl);
  minX := Raylib.ModelBBMinX(); minY := Raylib.ModelBBMinY(); minZ := Raylib.ModelBBMinZ();
  maxX := Raylib.ModelBBMaxX(); maxY := Raylib.ModelBBMaxY(); maxZ := Raylib.ModelBBMaxZ();

  cx   := (minX + maxX) * 0.5;
  cy   := (minY + maxY) * 0.5;
  cz   := (minZ + maxZ) * 0.5;
  span := maxX - minX;
  IF maxY - minY > span THEN span := maxY - minY END;
  IF maxZ - minZ > span THEN span := maxZ - minZ END;
  IF span < 0.001 THEN span := 1.0 END;

  (* Spherical-coordinate orbit state *)
  yaw   := 0.0;
  pitch := 0.2;
  dist  := span * 2.5;

  px := cx + dist * Math.cos(pitch) * Math.sin(yaw);
  py := cy + dist * Math.sin(pitch);
  pz := cz + dist * Math.cos(pitch) * Math.cos(yaw);

  cam := Raylib.NewCamera(
    px, py, pz,
    cx, cy, cz,
    0.0, 1.0, 0.0,
    45.0, Raylib.CameraPerspective);

  WHILE Raylib.WindowShouldClose() = 0 DO

    (* Orbit on left-drag *)
    IF Raylib.IsMouseButtonDown(MOUSE_LEFT) # 0 THEN
      yaw   := yaw   - Raylib.GetMouseDeltaX() * 0.005;
      pitch := pitch - Raylib.GetMouseDeltaY() * 0.005;
      IF pitch >  1.4 THEN pitch :=  1.4 END;
      IF pitch < -1.4 THEN pitch := -1.4 END
    END;

    (* Orbit on arrow keys *)
    IF Raylib.IsKeyDown(Raylib.KeyLeft)  = 1 THEN yaw   := yaw   + 0.03 END;
    IF Raylib.IsKeyDown(Raylib.KeyRight) = 1 THEN yaw   := yaw   - 0.03 END;
    IF Raylib.IsKeyDown(Raylib.KeyUp)    = 1 THEN pitch := pitch + 0.03 END;
    IF Raylib.IsKeyDown(Raylib.KeyDown)  = 1 THEN pitch := pitch - 0.03 END;
    IF pitch >  1.4 THEN pitch :=  1.4 END;
    IF pitch < -1.4 THEN pitch := -1.4 END;

    (* Zoom on scroll *)
    dist := dist - Raylib.GetMouseWheelMove() * span * 0.15;
    IF dist < span * 0.3  THEN dist := span * 0.3  END;
    IF dist > span * 10.0 THEN dist := span * 10.0 END;

    (* Recompute camera position from spherical coords *)
    px := cx + dist * Math.cos(pitch) * Math.sin(yaw);
    py := cy + dist * Math.sin(pitch);
    pz := cz + dist * Math.cos(pitch) * Math.cos(yaw);
    Raylib.SetCameraPosition(cam, px, py, pz);

    Raylib.BeginDrawing;
    Raylib.ClearBackground(cDark);
    Raylib.BeginMode3D(cam);

    (* -90 deg around X to fix Z-up models standing upright *)
    Raylib.DrawModelEx(mdl,
      0.0, 0.0, 0.0,
      1.0, 0.0, 0.0, 90.0,
      1.0, 1.0, 1.0,
      cWhite);

    Raylib.EndMode3D;
    Raylib.DrawText("Drag/arrows: orbit  |  Scroll: zoom  |  Esc: quit",
                    10, H - 28, 18, cGray);
    Raylib.EndDrawing
  END;

  Raylib.UnloadModel(mdl);
  Raylib.FreeCamera(cam);
  Raylib.CloseWindow
END GLBViewer.
