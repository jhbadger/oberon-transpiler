/* Raylib.c -- Oberon FFI wrappers for Raylib.
 *
 * Color encoding: all color parameters are packed ints: (a<<24)|(r<<16)|(g<<8)|b.
 * RL_C() unpacks to a raylib Color; RL_I() packs back.
 * Opaque types (Texture, Sound, Music, Font) are heap structs whose first field
 * is an int _tag (required by the obc type system).
 */

#include "OBCRaylib.h"

/* ── Window / Core ───────────────────────────────────────────────────────── */

void Raylib_InitWindow(int w, int h, char *title) {
    InitWindow(w, h, title);
}

void Raylib_CloseWindow(void) {
    CloseWindow();
}

static int _rl_quit = 0;
int Raylib_WindowShouldClose(void) {
    return (WindowShouldClose() || _rl_quit) ? 1 : 0;
}
void Raylib_SetWindowShouldClose(void) { _rl_quit = 1; }

void Raylib_SetTargetFPS(int fps) {
    SetTargetFPS(fps);
}

double Raylib_GetFrameTime(void) {
    return (double)GetFrameTime();
}

double Raylib_GetTime(void) {
    return GetTime();
}

int Raylib_GetScreenWidth(void) {
    return GetScreenWidth();
}

int Raylib_GetScreenHeight(void) {
    return GetScreenHeight();
}

int Raylib_IsWindowResized(void) {
    return IsWindowResized() ? 1 : 0;
}

void Raylib_ToggleFullscreen(void) {
    ToggleFullscreen();
}

void Raylib_SetWindowTitle(char *title) {
    SetWindowTitle(title);
}

void Raylib_SetWindowSize(int w, int h) {
    SetWindowSize(w, h);
}

/* ── Drawing ─────────────────────────────────────────────────────────────── */

void Raylib_BeginDrawing(void) {
    BeginDrawing();
}

void Raylib_EndDrawing(void) {
    EndDrawing();
}

void Raylib_ClearBackground(int color) {
    ClearBackground(RL_C(color));
}

/* ── 2D Shapes ───────────────────────────────────────────────────────────── */

void Raylib_DrawPixel(int x, int y, int color) {
    DrawPixel(x, y, RL_C(color));
}

void Raylib_DrawLine(int x1, int y1, int x2, int y2, int color) {
    DrawLine(x1, y1, x2, y2, RL_C(color));
}

void Raylib_DrawLineEx(double x1, double y1, double x2, double y2, double thick, int color) {
    DrawLineEx((Vector2){(float)x1, (float)y1},
               (Vector2){(float)x2, (float)y2},
               (float)thick, RL_C(color));
}

void Raylib_DrawCircle(int cx, int cy, double radius, int color) {
    DrawCircle(cx, cy, (float)radius, RL_C(color));
}

void Raylib_DrawCircleLines(int cx, int cy, double radius, int color) {
    DrawCircleLines(cx, cy, (float)radius, RL_C(color));
}

void Raylib_DrawEllipse(int cx, int cy, double rx, double ry, int color) {
    DrawEllipse(cx, cy, (float)rx, (float)ry, RL_C(color));
}

void Raylib_DrawRectangle(int x, int y, int w, int h, int color) {
    DrawRectangle(x, y, w, h, RL_C(color));
}

void Raylib_DrawRectangleLines(int x, int y, int w, int h, int color) {
    DrawRectangleLines(x, y, w, h, RL_C(color));
}

void Raylib_DrawRectangleRounded(double x, double y, double w, double h,
                                  double roundness, int segs, int color) {
    Rectangle r = {(float)x, (float)y, (float)w, (float)h};
    DrawRectangleRounded(r, (float)roundness, segs, RL_C(color));
}

void Raylib_DrawTriangle(double x1, double y1, double x2, double y2,
                          double x3, double y3, int color) {
    DrawTriangle((Vector2){(float)x1, (float)y1},
                 (Vector2){(float)x2, (float)y2},
                 (Vector2){(float)x3, (float)y3}, RL_C(color));
}

void Raylib_DrawPoly(double cx, double cy, int sides, double radius, double rot, int color) {
    DrawPoly((Vector2){(float)cx, (float)cy}, sides, (float)radius, (float)rot, RL_C(color));
}

/* ── Text ────────────────────────────────────────────────────────────────── */

void Raylib_DrawText(char *text, int x, int y, int size, int color) {
    DrawText(text, x, y, size, RL_C(color));
}

void Raylib_DrawTextEx(Raylib_Font font, char *text,
                        double x, double y, double size, double spacing, int color) {
    if (!font) return;
    DrawTextEx(font->fnt, text, (Vector2){(float)x, (float)y},
               (float)size, (float)spacing, RL_C(color));
}

int Raylib_MeasureText(char *text, int size) {
    return MeasureText(text, size);
}

/* ── Textures ────────────────────────────────────────────────────────────── */

Raylib_Texture Raylib_LoadTexture(char *path) {
    Raylib_Texture t = (Raylib_Texture)calloc(1, sizeof(Raylib_TextureRec));
    if (!t) return NULL;
    t->_tag = _TAG_Raylib_TextureRec;
    t->tex  = LoadTexture(path);
    return t;
}

void Raylib_UnloadTexture(Raylib_Texture tex) {
    if (!tex) return;
    UnloadTexture(tex->tex);
    free(tex);
}

void Raylib_DrawTexture(Raylib_Texture tex, int x, int y, int color) {
    if (!tex) return;
    DrawTexture(tex->tex, x, y, RL_C(color));
}

void Raylib_DrawTextureEx(Raylib_Texture tex, double x, double y,
                           double rot, double scale, int color) {
    if (!tex) return;
    DrawTextureEx(tex->tex, (Vector2){(float)x, (float)y},
                  (float)rot, (float)scale, RL_C(color));
}

void Raylib_DrawTextureRec(Raylib_Texture tex,
                            int sx, int sy, int sw, int sh,
                            double dx, double dy, int color) {
    if (!tex) return;
    Rectangle src = {(float)sx, (float)sy, (float)sw, (float)sh};
    DrawTextureRec(tex->tex, src, (Vector2){(float)dx, (float)dy}, RL_C(color));
}

void Raylib_DrawTexturePro(Raylib_Texture tex,
                            int sx, int sy, int sw, int sh,
                            int dx, int dy, int dw, int dh, int color) {
    if (!tex) return;
    Rectangle src = {(float)sx, (float)sy, (float)sw, (float)sh};
    Rectangle dst = {(float)dx, (float)dy, (float)dw, (float)dh};
    DrawTexturePro(tex->tex, src, dst, (Vector2){0.0f, 0.0f}, 0.0f, RL_C(color));
}

int Raylib_TextureWidth(Raylib_Texture tex) {
    return tex ? tex->tex.width : 0;
}

int Raylib_TextureHeight(Raylib_Texture tex) {
    return tex ? tex->tex.height : 0;
}

/* ── Fonts ───────────────────────────────────────────────────────────────── */

Raylib_Font Raylib_LoadFont(char *path) {
    Raylib_Font f = (Raylib_Font)calloc(1, sizeof(Raylib_FontRec));
    if (!f) return NULL;
    f->_tag = _TAG_Raylib_FontRec;
    f->fnt  = LoadFont(path);
    return f;
}

/* Load a TTF at a specific pixel size with nearest-neighbour filtering for crisp rendering. */
Raylib_Font Raylib_LoadFontSharp(char *path, int size) {
    Raylib_Font f = (Raylib_Font)calloc(1, sizeof(Raylib_FontRec));
    if (!f) return NULL;
    f->_tag = _TAG_Raylib_FontRec;
    f->fnt  = LoadFontEx(path, size, NULL, 0);
    SetTextureFilter(f->fnt.texture, TEXTURE_FILTER_POINT);
    return f;
}

Raylib_Font Raylib_LoadFontSharpAppDir(char *filename, int size) {
    const char *dir = GetApplicationDirectory();
    char path[4096];
    snprintf(path, sizeof(path), "%s%s", dir, filename);
    Raylib_Font f = (Raylib_Font)calloc(1, sizeof(Raylib_FontRec));
    if (!f) return NULL;
    f->_tag = _TAG_Raylib_FontRec;
    f->fnt  = LoadFontEx(path, size, NULL, 0);
    SetTextureFilter(f->fnt.texture, TEXTURE_FILTER_POINT);
    return f;
}

void Raylib_GetAppDir(char *buf, int buf_len) {
    const char *dir = GetApplicationDirectory();
    strncpy(buf, dir, buf_len - 1);
    buf[buf_len - 1] = '\0';
}

void Raylib_UnloadFont(Raylib_Font font) {
    if (!font) return;
    UnloadFont(font->fnt);
    free(font);
}

int Raylib_MeasureTextEx(Raylib_Font font, char *text, double size, double spacing) {
    if (!font) return 0;
    Vector2 v = MeasureTextEx(font->fnt, text, (float)size, (float)spacing);
    return (int)v.x;
}

/* ── Input — Keyboard ────────────────────────────────────────────────────── */

int Raylib_IsKeyDown(int key)     { return IsKeyDown(key)     ? 1 : 0; }
int Raylib_IsKeyPressed(int key)  { return IsKeyPressed(key)  ? 1 : 0; }
int Raylib_IsKeyReleased(int key) { return IsKeyReleased(key) ? 1 : 0; }
int Raylib_GetKeyPressed(void)    { return GetKeyPressed(); }

/* ── Input — Mouse ───────────────────────────────────────────────────────── */

int    Raylib_IsMouseButtonDown(int btn)     { return IsMouseButtonDown(btn)     ? 1 : 0; }
int    Raylib_IsMouseButtonPressed(int btn)  { return IsMouseButtonPressed(btn)  ? 1 : 0; }
int    Raylib_IsMouseButtonReleased(int btn) { return IsMouseButtonReleased(btn) ? 1 : 0; }
int    Raylib_GetMouseX(void)  { return GetMouseX(); }
int    Raylib_GetMouseY(void)  { return GetMouseY(); }
double Raylib_GetMouseWheelMove(void) { return (double)GetMouseWheelMove(); }

void Raylib_SetMousePosition(int x, int y) {
    SetMousePosition(x, y);
}

void Raylib_ShowCursor(void) { ShowCursor(); }
void Raylib_HideCursor(void) { HideCursor(); }

/* ── Audio ───────────────────────────────────────────────────────────────── */

void Raylib_InitAudioDevice(void)  { InitAudioDevice(); }
void Raylib_CloseAudioDevice(void) { CloseAudioDevice(); }

Raylib_Sound Raylib_LoadSound(char *path) {
    Raylib_Sound s = (Raylib_Sound)calloc(1, sizeof(Raylib_SoundRec));
    if (!s) return NULL;
    s->_tag = _TAG_Raylib_SoundRec;
    s->snd  = LoadSound(path);
    return s;
}

void Raylib_UnloadSound(Raylib_Sound snd) {
    if (!snd) return;
    UnloadSound(snd->snd);
    free(snd);
}

void Raylib_PlaySound(Raylib_Sound snd)   { if (snd) PlaySound(snd->snd); }
void Raylib_StopSound(Raylib_Sound snd)   { if (snd) StopSound(snd->snd); }
void Raylib_PauseSound(Raylib_Sound snd)  { if (snd) PauseSound(snd->snd); }
void Raylib_ResumeSound(Raylib_Sound snd) { if (snd) ResumeSound(snd->snd); }

int Raylib_IsSoundPlaying(Raylib_Sound snd) {
    return snd ? (IsSoundPlaying(snd->snd) ? 1 : 0) : 0;
}

void Raylib_SetSoundVolume(Raylib_Sound snd, double vol) {
    if (snd) SetSoundVolume(snd->snd, (float)vol);
}

Raylib_Music Raylib_LoadMusicStream(char *path) {
    Raylib_Music m = (Raylib_Music)calloc(1, sizeof(Raylib_MusicRec));
    if (!m) return NULL;
    m->_tag = _TAG_Raylib_MusicRec;
    m->mus  = LoadMusicStream(path);
    return m;
}

void Raylib_UnloadMusicStream(Raylib_Music mus) {
    if (!mus) return;
    UnloadMusicStream(mus->mus);
    free(mus);
}

void Raylib_PlayMusicStream(Raylib_Music mus)   { if (mus) PlayMusicStream(mus->mus); }
void Raylib_UpdateMusicStream(Raylib_Music mus) { if (mus) UpdateMusicStream(mus->mus); }
void Raylib_StopMusicStream(Raylib_Music mus)   { if (mus) StopMusicStream(mus->mus); }
void Raylib_PauseMusicStream(Raylib_Music mus)  { if (mus) PauseMusicStream(mus->mus); }
void Raylib_ResumeMusicStream(Raylib_Music mus) { if (mus) ResumeMusicStream(mus->mus); }

int Raylib_IsMusicStreamPlaying(Raylib_Music mus) {
    return mus ? (IsMusicStreamPlaying(mus->mus) ? 1 : 0) : 0;
}

void Raylib_SetMusicVolume(Raylib_Music mus, double vol) {
    if (mus) SetMusicVolume(mus->mus, (float)vol);
}

/* ── Color utilities ─────────────────────────────────────────────────────── */

int Raylib_RGBA(int r, int g, int b, int a) {
    Color c = {(unsigned char)r, (unsigned char)g,
               (unsigned char)b, (unsigned char)a};
    return RL_I(c);
}

int Raylib_Fade(int color, double alpha) {
    return RL_I(Fade(RL_C(color), (float)alpha));
}

/* ── Named colors ────────────────────────────────────────────────────────── */

int Raylib_Black(void)      { return RL_I(BLACK);      }
int Raylib_White(void)      { return RL_I(WHITE);      }
int Raylib_RayWhite(void)   { return RL_I(RAYWHITE);   }
int Raylib_Red(void)        { return RL_I(RED);        }
int Raylib_Green(void)      { return RL_I(GREEN);      }
int Raylib_Blue(void)       { return RL_I(BLUE);       }
int Raylib_Yellow(void)     { return RL_I(YELLOW);     }
int Raylib_Gold(void)       { return RL_I(GOLD);       }
int Raylib_Orange(void)     { return RL_I(ORANGE);     }
int Raylib_Pink(void)       { return RL_I(PINK);       }
int Raylib_Maroon(void)     { return RL_I(MAROON);     }
int Raylib_LightGray(void)  { return RL_I(LIGHTGRAY);  }
int Raylib_Gray(void)       { return RL_I(GRAY);       }
int Raylib_DarkGray(void)   { return RL_I(DARKGRAY);   }
int Raylib_SkyBlue(void)    { return RL_I(SKYBLUE);    }
int Raylib_DarkBlue(void)   { return RL_I(DARKBLUE);   }
int Raylib_DarkGreen(void)  { return RL_I(DARKGREEN);  }
int Raylib_Purple(void)     { return RL_I(VIOLET);     }
int Raylib_DarkPurple(void) { return RL_I(DARKPURPLE); }
int Raylib_Beige(void)      { return RL_I(BEIGE);      }
int Raylib_Brown(void)      { return RL_I(BROWN);      }
int Raylib_DarkBrown(void)  { return RL_I(DARKBROWN);  }
int Raylib_Magenta(void)    { return RL_I(MAGENTA);    }
int Raylib_Lime(void)       { return RL_I(LIME);       }
int Raylib_Violet(void)     { return RL_I(VIOLET);     }
int Raylib_Blank(void)      { return RL_I(BLANK);      }

/* ── RenderTexture ───────────────────────────────────────────────────────── */

Raylib_RenderTexture Raylib_LoadRenderTexture(int w, int h) {
    Raylib_RenderTexture rt = (Raylib_RenderTexture)calloc(1, sizeof(Raylib_RenderTextureRec));
    if (!rt) return NULL;
    rt->_tag = _TAG_Raylib_RenderTextureRec;
    rt->rt   = LoadRenderTexture(w, h);
    return rt;
}

void Raylib_UnloadRenderTexture(Raylib_RenderTexture rt) {
    if (!rt) return;
    UnloadRenderTexture(rt->rt);
    free(rt);
}

void Raylib_BeginTextureMode(Raylib_RenderTexture rt) {
    if (!rt) return;
    BeginTextureMode(rt->rt);
}

void Raylib_EndTextureMode(void) {
    EndTextureMode();
}

void Raylib_DrawRenderTexture(Raylib_RenderTexture rt, int x, int y, int w, int h, int color) {
    if (!rt) return;
    /* Negative source height flips the texture (RT is stored upside-down by OpenGL). */
    Rectangle src = {0, 0, (float)rt->rt.texture.width, (float)-rt->rt.texture.height};
    Rectangle dst = {(float)x, (float)y, (float)w, (float)h};
    DrawTexturePro(rt->rt.texture, src, dst, (Vector2){0, 0}, 0.0f, RL_C(color));
}

void Raylib_SaveRTPNG(Raylib_RenderTexture rt, char *filename) {
    if (!rt || !filename || filename[0] == '\0') return;
    Image img = LoadImageFromTexture(rt->rt.texture);
    ImageFlipVertical(&img);
    ExportImage(img, filename);
    UnloadImage(img);
}

void Raylib_LoadPNGIntoRT(Raylib_RenderTexture rt, char *filename) {
    if (!rt || !filename || filename[0] == '\0') return;
    Image img = LoadImage(filename);
    if (!img.data) return;
    Texture2D tex = LoadTextureFromImage(img);
    UnloadImage(img);
    BeginTextureMode(rt->rt);
    ClearBackground(WHITE);
    Rectangle src = {0, 0, (float)tex.width, (float)tex.height};
    Rectangle dst = {0, 0, (float)rt->rt.texture.width, (float)rt->rt.texture.height};
    DrawTexturePro(tex, src, dst, (Vector2){0, 0}, 0.0f, WHITE);
    EndTextureMode();
    UnloadTexture(tex);
}

void Raylib_FloodFillRT(Raylib_RenderTexture rt, int x, int y, int fillColor) {
    if (!rt) return;
    Image img = LoadImageFromTexture(rt->rt.texture);
    ImageFormat(&img, PIXELFORMAT_UNCOMPRESSED_R8G8B8A8);
    int w = img.width, h = img.height;
    int fy = h - 1 - y;  /* RT stored bottom-up */
    if (x < 0 || x >= w || fy < 0 || fy >= h) { UnloadImage(img); return; }

    unsigned char *data = (unsigned char *)img.data;
    int stride = w * 4;
    unsigned char *tp = data + fy * stride + x * 4;
    unsigned char tr = tp[0], tg = tp[1], tb = tp[2], ta = tp[3];
    Color fc = RL_C(fillColor);
    if (tr == fc.r && tg == fc.g && tb == fc.b && ta == fc.a) {
        UnloadImage(img); return;
    }

    int *sx = malloc(w * h * sizeof(int));
    int *sy = malloc(w * h * sizeof(int));
    if (!sx || !sy) { free(sx); free(sy); UnloadImage(img); return; }

    int sp = 0;
    tp[0] = fc.r; tp[1] = fc.g; tp[2] = fc.b; tp[3] = fc.a;
    sx[sp] = x; sy[sp] = fy; sp++;

    static const int dx[4] = {1, -1, 0, 0};
    static const int dy[4] = {0, 0, 1, -1};
    while (sp > 0) {
        sp--;
        int cx = sx[sp], cy = sy[sp];
        for (int d = 0; d < 4; d++) {
            int nx = cx + dx[d], ny = cy + dy[d];
            if (nx < 0 || nx >= w || ny < 0 || ny >= h) continue;
            unsigned char *np = data + ny * stride + nx * 4;
            if (np[0] == tr && np[1] == tg && np[2] == tb && np[3] == ta) {
                np[0] = fc.r; np[1] = fc.g; np[2] = fc.b; np[3] = fc.a;
                sx[sp] = nx; sy[sp] = ny; sp++;
            }
        }
    }
    free(sx); free(sy);
    UpdateTexture(rt->rt.texture, img.data);
    UnloadImage(img);
}

/* ── Additional shapes ───────────────────────────────────────────────────── */

void Raylib_DrawEllipseLines(int cx, int cy, double rx, double ry, int color) {
    DrawEllipseLines(cx, cy, (float)rx, (float)ry, RL_C(color));
}

void Raylib_DrawRectangleLinesEx(int x, int y, int w, int h, double thick, int color) {
    Rectangle r = {(float)x, (float)y, (float)w, (float)h};
    DrawRectangleLinesEx(r, (float)thick, RL_C(color));
}

/* ── Extended input ──────────────────────────────────────────────────────── */

int Raylib_GetCharPressed(void) {
    return GetCharPressed();
}

/* ── Module init ─────────────────────────────────────────────────────────── */
void Raylib_init(void) { }
