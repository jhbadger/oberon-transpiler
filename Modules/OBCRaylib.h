#ifndef OBC_RAYLIB_H_
#define OBC_RAYLIB_H_

/* Rename raylib's 'Model' typedef before including raylib.h so it doesn't clash
 * with other Oberon modules (e.g. BioPDB) that export their own 'Model' type.
 * All internal OBCRaylib code uses _Raylib_3DModel; the macro is undefined at
 * the end of this header so downstream includes see an unoccupied 'Model' name. */
#define Model _Raylib_3DModel

#include <raylib.h>
#include <stdlib.h>
#include <string.h>

/*
 * Color encoding: (a<<24)|(r<<16)|(g<<8)|b packed into a C int.
 * Fully-opaque colors have the high bit set and are negative in Oberon INTEGER.
 * Use Raylib_RGBA() or the named Raylib_Black() etc. procedures to get values.
 */
static inline Color RL_C(int c) {
    unsigned u = (unsigned)c;
    Color col;
    col.r = (unsigned char)((u >> 16) & 0xFF);
    col.g = (unsigned char)((u >>  8) & 0xFF);
    col.b = (unsigned char)( u        & 0xFF);
    col.a = (unsigned char)((u >> 24) & 0xFF);
    return col;
}
static inline int RL_I(Color c) {
    return (int)(((unsigned)c.a << 24) | ((unsigned)c.r << 16) |
                 ((unsigned)c.g <<  8) |  (unsigned)c.b);
}

/* ── Opaque handle types ─────────────────────────────────────────────────── */
typedef struct Raylib_TextureRec_s { int _tag; Texture2D tex; } Raylib_TextureRec;
typedef struct Raylib_SoundRec_s   { int _tag; Sound     snd; } Raylib_SoundRec;
typedef struct Raylib_MusicRec_s   { int _tag; Music     mus; } Raylib_MusicRec;
typedef struct Raylib_FontRec_s    { int _tag; Font      fnt; } Raylib_FontRec;

typedef Raylib_TextureRec *Raylib_Texture;
typedef Raylib_SoundRec   *Raylib_Sound;
typedef Raylib_MusicRec   *Raylib_Music;
typedef Raylib_FontRec    *Raylib_Font;

#define _TAG_Raylib_TextureRec 1
#define _TAG_Raylib_SoundRec   2
#define _TAG_Raylib_MusicRec   3
#define _TAG_Raylib_FontRec    4

/* ── Key codes (special keys; printable chars use their ASCII value) ──────── */
enum { Raylib_KeySpace     = KEY_SPACE       };
enum { Raylib_KeyEsc       = KEY_ESCAPE      };
enum { Raylib_KeyEnter     = KEY_ENTER       };
enum { Raylib_KeyTab       = KEY_TAB         };
enum { Raylib_KeyBackspace = KEY_BACKSPACE   };
enum { Raylib_KeyInsert    = KEY_INSERT      };
enum { Raylib_KeyDelete    = KEY_DELETE      };
enum { Raylib_KeyRight     = KEY_RIGHT       };
enum { Raylib_KeyLeft      = KEY_LEFT        };
enum { Raylib_KeyDown      = KEY_DOWN        };
enum { Raylib_KeyUp        = KEY_UP          };
enum { Raylib_KeyPgUp      = KEY_PAGE_UP     };
enum { Raylib_KeyPgDn      = KEY_PAGE_DOWN   };
enum { Raylib_KeyHome      = KEY_HOME        };
enum { Raylib_KeyEnd       = KEY_END         };
enum { Raylib_KeyF1        = KEY_F1          };
enum { Raylib_KeyF2        = KEY_F2          };
enum { Raylib_KeyF3        = KEY_F3          };
enum { Raylib_KeyF4        = KEY_F4          };
enum { Raylib_KeyF5        = KEY_F5          };
enum { Raylib_KeyF6        = KEY_F6          };
enum { Raylib_KeyF7        = KEY_F7          };
enum { Raylib_KeyF8        = KEY_F8          };
enum { Raylib_KeyF9        = KEY_F9          };
enum { Raylib_KeyF10       = KEY_F10         };
enum { Raylib_KeyF11       = KEY_F11         };
enum { Raylib_KeyF12       = KEY_F12         };
enum { Raylib_KeyLShift    = KEY_LEFT_SHIFT  };
enum { Raylib_KeyRShift    = KEY_RIGHT_SHIFT };
enum { Raylib_KeyLCtrl     = KEY_LEFT_CONTROL  };
enum { Raylib_KeyRCtrl     = KEY_RIGHT_CONTROL };
enum { Raylib_KeyLAlt      = KEY_LEFT_ALT    };
enum { Raylib_KeyRAlt      = KEY_RIGHT_ALT   };

/* ── Mouse button indices ────────────────────────────────────────────────── */
enum { Raylib_BtnLeft   = MOUSE_BUTTON_LEFT   };
enum { Raylib_BtnRight  = MOUSE_BUTTON_RIGHT  };
enum { Raylib_BtnMiddle = MOUSE_BUTTON_MIDDLE };

/* ── Window / Core ───────────────────────────────────────────────────────── */
void   Raylib_InitWindow(int w, int h, char *title);
void   Raylib_CloseWindow(void);
int    Raylib_WindowShouldClose(void);
void   Raylib_SetWindowShouldClose(void);
void   Raylib_SetTargetFPS(int fps);
double Raylib_GetFrameTime(void);
double Raylib_GetTime(void);
int    Raylib_GetScreenWidth(void);
int    Raylib_GetScreenHeight(void);
int    Raylib_IsWindowResized(void);
void   Raylib_ToggleFullscreen(void);
void   Raylib_SetWindowTitle(char *title);
void   Raylib_SetWindowSize(int w, int h);

/* ── Drawing ─────────────────────────────────────────────────────────────── */
void Raylib_BeginDrawing(void);
void Raylib_EndDrawing(void);
void Raylib_ClearBackground(int color);

/* ── 2D Shapes ───────────────────────────────────────────────────────────── */
void Raylib_DrawPixel(int x, int y, int color);
void Raylib_DrawLine(int x1, int y1, int x2, int y2, int color);
void Raylib_DrawLineEx(double x1, double y1, double x2, double y2, double thick, int color);
void Raylib_DrawCircle(int cx, int cy, double radius, int color);
void Raylib_DrawCircleLines(int cx, int cy, double radius, int color);
void Raylib_DrawEllipse(int cx, int cy, double rx, double ry, int color);
void Raylib_DrawRectangle(int x, int y, int w, int h, int color);
void Raylib_DrawRectangleLines(int x, int y, int w, int h, int color);
void Raylib_DrawRectangleRounded(double x, double y, double w, double h, double roundness, int segs, int color);
void Raylib_DrawTriangle(double x1, double y1, double x2, double y2, double x3, double y3, int color);
void Raylib_DrawPoly(double cx, double cy, int sides, double radius, double rot, int color);

/* ── Text ────────────────────────────────────────────────────────────────── */
void Raylib_DrawText(char *text, int x, int y, int size, int color);
void Raylib_DrawTextEx(Raylib_Font font, char *text, double x, double y, double size, double spacing, int color);
int  Raylib_MeasureText(char *text, int size);

/* ── Textures ────────────────────────────────────────────────────────────── */
Raylib_Texture Raylib_LoadTexture(char *path);
void           Raylib_UnloadTexture(Raylib_Texture tex);
void           Raylib_DrawTexture(Raylib_Texture tex, int x, int y, int color);
void           Raylib_DrawTextureEx(Raylib_Texture tex, double x, double y, double rot, double scale, int color);
void           Raylib_DrawTextureRec(Raylib_Texture tex, int sx, int sy, int sw, int sh, double dx, double dy, int color);
void           Raylib_DrawTexturePro(Raylib_Texture tex, int sx, int sy, int sw, int sh, int dx, int dy, int dw, int dh, int color);
int            Raylib_TextureWidth(Raylib_Texture tex);
int            Raylib_TextureHeight(Raylib_Texture tex);

/* ── Fonts ───────────────────────────────────────────────────────────────── */
Raylib_Font Raylib_LoadFont(char *path);
Raylib_Font Raylib_LoadFontSharp(char *path, int size);
Raylib_Font Raylib_LoadFontSharpAppDir(char *filename, int size);
void        Raylib_UnloadFont(Raylib_Font font);
int         Raylib_MeasureTextEx(Raylib_Font font, char *text, double size, double spacing);

/* ── Filesystem ──────────────────────────────────────────────────────────── */
void Raylib_GetAppDir(char *buf, int buf_len);

/* ── Input — Keyboard ────────────────────────────────────────────────────── */
int Raylib_IsKeyDown(int key);
int Raylib_IsKeyPressed(int key);
int Raylib_IsKeyReleased(int key);
int Raylib_GetKeyPressed(void);

/* ── Input — Mouse ───────────────────────────────────────────────────────── */
int    Raylib_IsMouseButtonDown(int btn);
int    Raylib_IsMouseButtonPressed(int btn);
int    Raylib_IsMouseButtonReleased(int btn);
int    Raylib_GetMouseX(void);
int    Raylib_GetMouseY(void);
double Raylib_GetMouseWheelMove(void);
double Raylib_GetMouseDeltaX(void);
double Raylib_GetMouseDeltaY(void);
void   Raylib_SetMousePosition(int x, int y);
void   Raylib_ShowCursor(void);
void   Raylib_HideCursor(void);

/* ── Audio ───────────────────────────────────────────────────────────────── */
void         Raylib_InitAudioDevice(void);
void         Raylib_CloseAudioDevice(void);
Raylib_Sound Raylib_LoadSound(char *path);
Raylib_Sound Raylib_GenShootSound(void);
Raylib_Sound Raylib_GenMarchSound(int phase);
Raylib_Sound Raylib_GenExplodeSound(void);
void         Raylib_UnloadSound(Raylib_Sound snd);
void         Raylib_PlaySound(Raylib_Sound snd);
void         Raylib_StopSound(Raylib_Sound snd);
void         Raylib_PauseSound(Raylib_Sound snd);
void         Raylib_ResumeSound(Raylib_Sound snd);
int          Raylib_IsSoundPlaying(Raylib_Sound snd);
void         Raylib_SetSoundVolume(Raylib_Sound snd, double vol);
Raylib_Music Raylib_LoadMusicStream(char *path);
void         Raylib_UnloadMusicStream(Raylib_Music mus);
void         Raylib_PlayMusicStream(Raylib_Music mus);
void         Raylib_UpdateMusicStream(Raylib_Music mus);
void         Raylib_StopMusicStream(Raylib_Music mus);
void         Raylib_PauseMusicStream(Raylib_Music mus);
void         Raylib_ResumeMusicStream(Raylib_Music mus);
int          Raylib_IsMusicStreamPlaying(Raylib_Music mus);
void         Raylib_SetMusicVolume(Raylib_Music mus, double vol);

/* ── Color utilities ─────────────────────────────────────────────────────── */
int Raylib_RGBA(int r, int g, int b, int a);
int Raylib_Fade(int color, double alpha);

/* ── Named colors ────────────────────────────────────────────────────────── */
int Raylib_Black(void);
int Raylib_White(void);
int Raylib_RayWhite(void);
int Raylib_Red(void);
int Raylib_Green(void);
int Raylib_Blue(void);
int Raylib_Yellow(void);
int Raylib_Gold(void);
int Raylib_Orange(void);
int Raylib_Pink(void);
int Raylib_Maroon(void);
int Raylib_LightGray(void);
int Raylib_Gray(void);
int Raylib_DarkGray(void);
int Raylib_SkyBlue(void);
int Raylib_DarkBlue(void);
int Raylib_DarkGreen(void);
int Raylib_Purple(void);
int Raylib_DarkPurple(void);
int Raylib_Beige(void);
int Raylib_Brown(void);
int Raylib_DarkBrown(void);
int Raylib_Magenta(void);
int Raylib_Lime(void);
int Raylib_Violet(void);
int Raylib_Blank(void);

/* ── RenderTexture ───────────────────────────────────────────────────────── */
typedef struct Raylib_RenderTextureRec_s { int _tag; RenderTexture2D rt; } Raylib_RenderTextureRec;
typedef Raylib_RenderTextureRec *Raylib_RenderTexture;
#define _TAG_Raylib_RenderTextureRec 5

/* ── 3D: Camera and Model ────────────────────────────────────────────────── */
typedef struct Raylib_CameraRec_s { int _tag; Camera3D cam; } Raylib_CameraRec;
typedef struct Raylib_ModelRec_s  { int _tag; Model    mdl; } Raylib_ModelRec;

typedef Raylib_CameraRec *Raylib_Camera;
typedef Raylib_ModelRec  *Raylib_Model;

#define _TAG_Raylib_CameraRec 6
#define _TAG_Raylib_ModelRec  7

/* Camera projection types */
enum { Raylib_CameraPerspective  = CAMERA_PERSPECTIVE  };
enum { Raylib_CameraOrthographic = CAMERA_ORTHOGRAPHIC };

/* Camera update modes */
enum { Raylib_CameraCustom      = CAMERA_CUSTOM       };
enum { Raylib_CameraFree        = CAMERA_FREE         };
enum { Raylib_CameraOrbital     = CAMERA_ORBITAL      };
enum { Raylib_CameraFirstPerson = CAMERA_FIRST_PERSON };
enum { Raylib_CameraThirdPerson = CAMERA_THIRD_PERSON };

Raylib_RenderTexture Raylib_LoadRenderTexture(int w, int h);
void Raylib_UnloadRenderTexture(Raylib_RenderTexture rt);
void Raylib_BeginTextureMode(Raylib_RenderTexture rt);
void Raylib_EndTextureMode(void);
void Raylib_DrawRenderTexture(Raylib_RenderTexture rt, int x, int y, int w, int h, int color);
void Raylib_SaveRTPNG(Raylib_RenderTexture rt, char *filename);
void Raylib_LoadPNGIntoRT(Raylib_RenderTexture rt, char *filename);
void Raylib_FloodFillRT(Raylib_RenderTexture rt, int x, int y, int color);

/* ── 3D Camera ───────────────────────────────────────────────────────────── */
Raylib_Camera Raylib_NewCamera(double posX, double posY, double posZ,
                               double tarX, double tarY, double tarZ,
                               double upX,  double upY,  double upZ,
                               double fovy, int projType);
void Raylib_FreeCamera(Raylib_Camera cam);
void Raylib_UpdateCamera(Raylib_Camera cam, int mode);
void Raylib_SetCameraPosition(Raylib_Camera cam, double x, double y, double z);
void Raylib_SetCameraTarget(Raylib_Camera cam, double x, double y, double z);
void Raylib_BeginMode3D(Raylib_Camera cam);
void Raylib_EndMode3D(void);

/* ── 3D Model ────────────────────────────────────────────────────────────── */
Raylib_Model Raylib_LoadModel(char *path);
void         Raylib_UnloadModel(Raylib_Model mdl);
void         Raylib_DrawModel(Raylib_Model mdl, double x, double y, double z,
                              double scale, int color);
void         Raylib_DrawModelEx(Raylib_Model mdl,
                                double posX, double posY, double posZ,
                                double axisX, double axisY, double axisZ,
                                double angle,
                                double scaleX, double scaleY, double scaleZ,
                                int color);
void   Raylib_QueryModelBounds(Raylib_Model mdl);
double Raylib_ModelBBMinX(void);
double Raylib_ModelBBMinY(void);
double Raylib_ModelBBMinZ(void);
double Raylib_ModelBBMaxX(void);
double Raylib_ModelBBMaxY(void);
double Raylib_ModelBBMaxZ(void);

/* ── 3D Shapes ───────────────────────────────────────────────────────────── */
void Raylib_DrawGrid(int slices, double spacing);
void Raylib_DrawCube(double x, double y, double z,
                     double w, double h, double len, int color);
void Raylib_DrawCubeWires(double x, double y, double z,
                          double w, double h, double len, int color);
void Raylib_DrawSphere(double x, double y, double z, double radius, int color);
void Raylib_DrawCylinder(double x, double y, double z,
                         double radTop, double radBot, double height,
                         int slices, int color);
void Raylib_DrawPlane(double x, double y, double z, double w, double len, int color);

/* ── 3D Picking ──────────────────────────────────────────────────────────── */
void Raylib_GetMouseRay(int mx, int my, Raylib_Camera cam,
                        double *ox, double *oy, double *oz,
                        double *dx, double *dy, double *dz);
int  Raylib_GetRayCollisionBox(double rox, double roy, double roz,
                               double rdx, double rdy, double rdz,
                               double minX, double minY, double minZ,
                               double maxX, double maxY, double maxZ,
                               double *dist, double *hx, double *hy, double *hz);

/* ── Additional shapes ───────────────────────────────────────────────────── */
void Raylib_DrawEllipseLines(int cx, int cy, double rx, double ry, int color);
void Raylib_DrawRectangleLinesEx(int x, int y, int w, int h, double thick, int color);

/* ── Extended input ──────────────────────────────────────────────────────── */
int Raylib_GetCharPressed(void);

/* ── Module init (no-op — called by obc runtime) ─────────────────────────── */
void Raylib_init(void);

/* Release the 'Model' macro so subsequent headers can use that name freely. */
#undef Model

#endif /* OBC_RAYLIB_H_ */
