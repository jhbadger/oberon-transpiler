MODULE GLBViewer;

(*
 * GLB / GLTF model viewer.
 *
 * Usage:  glbviewer <model.glb>
 *
 * Controls:
 *   Left-drag / arrow keys : orbit (trackball, all axes)
 *   Scroll / + -           : zoom in / out
 *   W A S D                : pan in camera space
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
  dist                 : REAL;
  px, py, pz           : REAL;
  panSpeed             : REAL;
  scrW, scrH           : INTEGER;
  frameCount           : INTEGER;
  (* Trackball rotation matrix stored as column vectors:
     rx = camera right, ry = camera up, rz = back (camera pos = target + dist*rz) *)
  rx0, rx1, rx2        : REAL;
  ry0, ry1, ry2        : REAL;
  rz0, rz1, rz2        : REAL;

(* Rotate ry and rz around the right axis (rx) by angle in radians. *)
PROCEDURE RotateAroundRight(angle: REAL);
VAR lc, ls, ty0, ty1, ty2, tz0, tz1, tz2: REAL;
BEGIN
  lc := Math.cos(angle);  ls := Math.sin(angle);
  ty0 := ry0*lc + rz0*ls;  ty1 := ry1*lc + rz1*ls;  ty2 := ry2*lc + rz2*ls;
  tz0 := rz0*lc - ry0*ls;  tz1 := rz1*lc - ry1*ls;  tz2 := rz2*lc - ry2*ls;
  ry0 := ty0;  ry1 := ty1;  ry2 := ty2;
  rz0 := tz0;  rz1 := tz1;  rz2 := tz2
END RotateAroundRight;

(* Rotate rx and rz around the up axis (ry) by angle in radians. *)
PROCEDURE RotateAroundUp(angle: REAL);
VAR lc, ls, tx0, tx1, tx2, tz0, tz1, tz2: REAL;
BEGIN
  lc := Math.cos(angle);  ls := Math.sin(angle);
  tx0 := rx0*lc - rz0*ls;  tx1 := rx1*lc - rz1*ls;  tx2 := rx2*lc - rz2*ls;
  tz0 := rz0*lc + rx0*ls;  tz1 := rz1*lc + rx1*ls;  tz2 := rz2*lc + rx2*ls;
  rx0 := tx0;  rx1 := tx1;  rx2 := tx2;
  rz0 := tz0;  rz1 := tz1;  rz2 := tz2
END RotateAroundUp;

(* Gram-Schmidt reorthogonalization to prevent floating-point drift. *)
PROCEDURE Reorthogonalize;
VAR llen, ldot: REAL;
BEGIN
  llen := Math.sqrt(rx0*rx0 + rx1*rx1 + rx2*rx2);
  IF llen > 0.0 THEN rx0 := rx0/llen;  rx1 := rx1/llen;  rx2 := rx2/llen END;
  ldot := ry0*rx0 + ry1*rx1 + ry2*rx2;
  ry0 := ry0 - ldot*rx0;  ry1 := ry1 - ldot*rx1;  ry2 := ry2 - ldot*rx2;
  llen := Math.sqrt(ry0*ry0 + ry1*ry1 + ry2*ry2);
  IF llen > 0.0 THEN ry0 := ry0/llen;  ry1 := ry1/llen;  ry2 := ry2/llen END;
  rz0 := rx1*ry2 - rx2*ry1;
  rz1 := rx2*ry0 - rx0*ry2;
  rz2 := rx0*ry1 - rx1*ry0
END Reorthogonalize;

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
  Raylib.SetWindowResizable();
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

  dist := span * 2.5;

  (* Initialise trackball to identity (camera behind model on +Z), then tilt slightly *)
  rx0 := 1.0;  rx1 := 0.0;  rx2 := 0.0;
  ry0 := 0.0;  ry1 := 1.0;  ry2 := 0.0;
  rz0 := 0.0;  rz1 := 0.0;  rz2 := 1.0;
  RotateAroundRight(-0.2);

  px := cx + dist * rz0;
  py := cy + dist * rz1;
  pz := cz + dist * rz2;

  cam := Raylib.NewCamera(
    px, py, pz,
    cx, cy, cz,
    ry0, ry1, ry2,
    45.0, Raylib.CameraPerspective);

  frameCount := 0;

  WHILE Raylib.WindowShouldClose() = 0 DO
    panSpeed := dist * 0.01;

    (* Trackball orbit on left-drag: mouse axes map to camera axes *)
    IF Raylib.IsMouseButtonDown(MOUSE_LEFT) # 0 THEN
      RotateAroundUp(   -Raylib.GetMouseDeltaX() * 0.005);
      RotateAroundRight( Raylib.GetMouseDeltaY() * 0.005)
    END;

    (* Orbit on arrow keys *)
    IF Raylib.IsKeyDown(Raylib.KeyLeft)  = 1 THEN RotateAroundUp(  0.03) END;
    IF Raylib.IsKeyDown(Raylib.KeyRight) = 1 THEN RotateAroundUp( -0.03) END;
    IF Raylib.IsKeyDown(Raylib.KeyUp)    = 1 THEN RotateAroundRight(-0.03) END;
    IF Raylib.IsKeyDown(Raylib.KeyDown)  = 1 THEN RotateAroundRight( 0.03) END;

    (* Zoom *)
    dist := dist - Raylib.GetMouseWheelMove() * span * 0.15;
    IF Raylib.IsKeyDown(ORD('=')) = 1 THEN dist := dist * 0.99 END;
    IF Raylib.IsKeyDown(ORD('-')) = 1 THEN dist := dist * 1.01 END;
    IF dist < span * 0.3  THEN dist := span * 0.3  END;
    IF dist > span * 10.0 THEN dist := span * 10.0 END;

    (* WASD pan in camera space: A/D along right, W/S along up *)
    IF Raylib.IsKeyDown(ORD('W')) = 1 THEN
      cx := cx + panSpeed*ry0;  cy := cy + panSpeed*ry1;  cz := cz + panSpeed*ry2
    END;
    IF Raylib.IsKeyDown(ORD('S')) = 1 THEN
      cx := cx - panSpeed*ry0;  cy := cy - panSpeed*ry1;  cz := cz - panSpeed*ry2
    END;
    IF Raylib.IsKeyDown(ORD('A')) = 1 THEN
      cx := cx - panSpeed*rx0;  cy := cy - panSpeed*rx1;  cz := cz - panSpeed*rx2
    END;
    IF Raylib.IsKeyDown(ORD('D')) = 1 THEN
      cx := cx + panSpeed*rx0;  cy := cy + panSpeed*rx1;  cz := cz + panSpeed*rx2
    END;

    (* Reorthogonalize every 60 frames to prevent floating-point drift *)
    frameCount := frameCount + 1;
    IF frameCount >= 60 THEN
      Reorthogonalize;
      frameCount := 0
    END;

    px := cx + dist * rz0;
    py := cy + dist * rz1;
    pz := cz + dist * rz2;
    Raylib.SetCameraPosition(cam, px, py, pz);
    Raylib.SetCameraTarget(cam, cx, cy, cz);
    Raylib.SetCameraUp(cam, ry0, ry1, ry2);

    scrW := Raylib.GetScreenWidth();
    scrH := Raylib.GetScreenHeight();

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
    Raylib.DrawText("Drag/arrows: orbit  |  Scroll/+/-: zoom  |  WASD: pan  |  Esc: quit",
                    10, scrH - 28, 18, cGray);
    Raylib.EndDrawing
  END;

  Raylib.UnloadModel(mdl);
  Raylib.FreeCamera(cam);
  Raylib.CloseWindow
END GLBViewer.
