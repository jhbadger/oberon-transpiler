MODULE rltest;
IMPORT Raylib;
VAR black, white : INTEGER;
BEGIN
  Raylib.InitWindow(400, 300, "test");
  Raylib.SetTargetFPS(60);
  black := Raylib.Black();
  white := Raylib.White();
  Raylib.BeginDrawing();
  Raylib.ClearBackground(black);
  Raylib.DrawText("hello", 10, 10, 20, white);
  Raylib.EndDrawing();
  Raylib.CloseWindow()
END rltest.
