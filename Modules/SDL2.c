/* SDL2.c -- Oberon FFI wrappers for SDL2.
 *
 * Each function adapts the SDL2 C API to a form callable directly from
 * generated Oberon C code:
 *   - Opaque SDL_Window/SDL_Renderer/etc. pointers are cast through the
 *     thin stub types (SDL2_WindowRec* etc.) that Oberon uses as handles.
 *   - Events are accessed via SDL2_Event (a pointer to SDL2_EventRec which
 *     embeds a raw SDL_Event union), so callers never need address-of on
 *     plain records (which the FFI codegen path cannot insert automatically).
 *   - All integer parameters use plain int; Oberon INTEGER maps to long but
 *     every value used here fits in int.
 */

#include "SDL2.h"

/* ── Helpers ─────────────────────────────────────────────────────────────── */
static SDL_Window   *W(SDL2_Window   w) { return (SDL_Window   *)w; }
static SDL_Renderer *R(SDL2_Renderer r) { return (SDL_Renderer *)r; }
static SDL_Texture  *T(SDL2_Texture  t) { return (SDL_Texture  *)t; }
static SDL_Surface  *S(SDL2_Surface  s) { return (SDL_Surface  *)s; }

/* ── System ──────────────────────────────────────────────────────────────── */

int SDL2_Init(int flags) {
    SDL_SetMainReady();
    return SDL_Init((Uint32)flags);
}

void SDL2_Quit(void) {
    SDL_Quit();
}

void SDL2_GetError(char *buf) {
    if (!buf) return;
    const char *e = SDL_GetError();
    strncpy(buf, e ? e : "", 255);
    buf[255] = '\0';
}

/* ── Window ──────────────────────────────────────────────────────────────── */

SDL2_Window SDL2_CreateWindow(char *title, int w, int h, int flags) {
    return (SDL2_Window)SDL_CreateWindow(title,
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        w, h, (Uint32)flags);
}

SDL2_Window SDL2_CreateWindowAt(char *title, int x, int y, int w, int h, int flags) {
    return (SDL2_Window)SDL_CreateWindow(title, x, y, w, h, (Uint32)flags);
}

void SDL2_DestroyWindow(SDL2_Window win) {
    SDL_DestroyWindow(W(win));
}

void SDL2_SetWindowTitle(SDL2_Window win, char *title) {
    SDL_SetWindowTitle(W(win), title);
}

int SDL2_WindowWidth(SDL2_Window win) {
    int w = 0;
    SDL_GetWindowSize(W(win), &w, NULL);
    return w;
}

int SDL2_WindowHeight(SDL2_Window win) {
    int h = 0;
    SDL_GetWindowSize(W(win), NULL, &h);
    return h;
}

/* ── Renderer ────────────────────────────────────────────────────────────── */

SDL2_Renderer SDL2_CreateRenderer(SDL2_Window win, int flags) {
    return (SDL2_Renderer)SDL_CreateRenderer(W(win), -1, (Uint32)flags);
}

void SDL2_DestroyRenderer(SDL2_Renderer ren) {
    SDL_DestroyRenderer(R(ren));
}

void SDL2_SetDrawColor(SDL2_Renderer ren, int r, int g, int b, int a) {
    SDL_SetRenderDrawColor(R(ren),
        (Uint8)r, (Uint8)g, (Uint8)b, (Uint8)a);
}

void SDL2_Clear(SDL2_Renderer ren) {
    SDL_RenderClear(R(ren));
}

void SDL2_Present(SDL2_Renderer ren) {
    SDL_RenderPresent(R(ren));
}

void SDL2_DrawPoint(SDL2_Renderer ren, int x, int y) {
    SDL_RenderDrawPoint(R(ren), x, y);
}

void SDL2_DrawLine(SDL2_Renderer ren, int x1, int y1, int x2, int y2) {
    SDL_RenderDrawLine(R(ren), x1, y1, x2, y2);
}

void SDL2_DrawRect(SDL2_Renderer ren, int x, int y, int w, int h) {
    SDL_Rect r = { x, y, w, h };
    SDL_RenderDrawRect(R(ren), &r);
}

void SDL2_FillRect(SDL2_Renderer ren, int x, int y, int w, int h) {
    SDL_Rect r = { x, y, w, h };
    SDL_RenderFillRect(R(ren), &r);
}

void SDL2_SetBlendMode(SDL2_Renderer ren, int mode) {
    SDL_SetRenderDrawBlendMode(R(ren), (SDL_BlendMode)mode);
}

void SDL2_SetClipRect(SDL2_Renderer ren, int x, int y, int w, int h) {
    SDL_Rect r = { x, y, w, h };
    SDL_RenderSetClipRect(R(ren), &r);
}

void SDL2_ClearClipRect(SDL2_Renderer ren) {
    SDL_RenderSetClipRect(R(ren), NULL);
}

void SDL2_SetScale(SDL2_Renderer ren, double sx, double sy) {
    SDL_RenderSetScale(R(ren), (float)sx, (float)sy);
}

void SDL2_SetRenderTarget(SDL2_Renderer ren, SDL2_Texture tex) {
    SDL_SetRenderTarget(R(ren), T(tex));
}

void SDL2_ClearRenderTarget(SDL2_Renderer ren) {
    SDL_SetRenderTarget(R(ren), NULL);
}

/* ── Texture ─────────────────────────────────────────────────────────────── */

SDL2_Texture SDL2_CreateTexture(SDL2_Renderer ren, int w, int h) {
    return (SDL2_Texture)SDL_CreateTexture(R(ren),
        SDL_PIXELFORMAT_RGBA8888, SDL_TEXTUREACCESS_TARGET, w, h);
}

SDL2_Texture SDL2_CreateTextureFromSurface(SDL2_Renderer ren, SDL2_Surface surf) {
    return (SDL2_Texture)SDL_CreateTextureFromSurface(R(ren), S(surf));
}

void SDL2_DestroyTexture(SDL2_Texture tex) {
    SDL_DestroyTexture(T(tex));
}

void SDL2_RenderCopy(SDL2_Renderer ren, SDL2_Texture tex,
                     int dx, int dy, int dw, int dh)
{
    SDL_Rect dst = { dx, dy, dw, dh };
    SDL_RenderCopy(R(ren), T(tex), NULL, &dst);
}

void SDL2_RenderCopyRect(SDL2_Renderer ren, SDL2_Texture tex,
                          int sx, int sy, int sw, int sh,
                          int dx, int dy, int dw, int dh)
{
    SDL_Rect src = { sx, sy, sw, sh };
    SDL_Rect dst = { dx, dy, dw, dh };
    SDL_RenderCopy(R(ren), T(tex), &src, &dst);
}

void SDL2_RenderCopyEx(SDL2_Renderer ren, SDL2_Texture tex,
                        int dx, int dy, int dw, int dh,
                        double angle, int flip)
{
    SDL_Rect dst = { dx, dy, dw, dh };
    SDL_RenderCopyEx(R(ren), T(tex), NULL, &dst,
                     angle, NULL, (SDL_RendererFlip)flip);
}

void SDL2_SetTextureColor(SDL2_Texture tex, int r, int g, int b) {
    SDL_SetTextureColorMod(T(tex), (Uint8)r, (Uint8)g, (Uint8)b);
}

void SDL2_SetTextureAlpha(SDL2_Texture tex, int a) {
    SDL_SetTextureAlphaMod(T(tex), (Uint8)a);
}

void SDL2_SetTextureBlend(SDL2_Texture tex, int mode) {
    SDL_SetTextureBlendMode(T(tex), (SDL_BlendMode)mode);
}

int SDL2_TextureWidth(SDL2_Texture tex) {
    int w = 0;
    SDL_QueryTexture(T(tex), NULL, NULL, &w, NULL);
    return w;
}

int SDL2_TextureHeight(SDL2_Texture tex) {
    int h = 0;
    SDL_QueryTexture(T(tex), NULL, NULL, NULL, &h);
    return h;
}

/* ── Surface ─────────────────────────────────────────────────────────────── */

SDL2_Surface SDL2_LoadBMP(char *path) {
    return (SDL2_Surface)SDL_LoadBMP(path);
}

void SDL2_FreeSurface(SDL2_Surface surf) {
    SDL_FreeSurface(S(surf));
}

/* ── Events ──────────────────────────────────────────────────────────────── */

int SDL2_PollEvent(SDL2_Event ev) {
    if (!ev) return 0;
    return SDL_PollEvent(&ev->raw);
}

void SDL2_WaitEvent(SDL2_Event ev) {
    if (!ev) return;
    SDL_WaitEvent(&ev->raw);
}

int SDL2_EventKind(SDL2_Event ev) {
    return ev ? (int)ev->raw.type : 0;
}

int SDL2_EventKey(SDL2_Event ev) {
    return ev ? (int)ev->raw.key.keysym.sym : 0;
}

int SDL2_EventMod(SDL2_Event ev) {
    return ev ? (int)ev->raw.key.keysym.mod : 0;
}

int SDL2_EventMouseX(SDL2_Event ev) {
    if (!ev) return 0;
    switch (ev->raw.type) {
    case SDL_MOUSEMOTION:     return ev->raw.motion.x;
    case SDL_MOUSEBUTTONDOWN:
    case SDL_MOUSEBUTTONUP:   return ev->raw.button.x;
    default:                  return 0;
    }
}

int SDL2_EventMouseY(SDL2_Event ev) {
    if (!ev) return 0;
    switch (ev->raw.type) {
    case SDL_MOUSEMOTION:     return ev->raw.motion.y;
    case SDL_MOUSEBUTTONDOWN:
    case SDL_MOUSEBUTTONUP:   return ev->raw.button.y;
    default:                  return 0;
    }
}

int SDL2_EventMouseBtn(SDL2_Event ev) {
    if (!ev) return 0;
    switch (ev->raw.type) {
    case SDL_MOUSEBUTTONDOWN:
    case SDL_MOUSEBUTTONUP:   return (int)ev->raw.button.button;
    default:                  return 0;
    }
}

int SDL2_EventWheelX(SDL2_Event ev) {
    return (ev && ev->raw.type == SDL_MOUSEWHEEL) ? ev->raw.wheel.x : 0;
}

int SDL2_EventWheelY(SDL2_Event ev) {
    return (ev && ev->raw.type == SDL_MOUSEWHEEL) ? ev->raw.wheel.y : 0;
}

int SDL2_EventWinID(SDL2_Event ev) {
    return (ev && ev->raw.type == SDL_WINDOWEVENT)
           ? (int)ev->raw.window.windowID : 0;
}

int SDL2_EventWinEv(SDL2_Event ev) {
    return (ev && ev->raw.type == SDL_WINDOWEVENT)
           ? (int)ev->raw.window.event : 0;
}

int SDL2_EventWinW(SDL2_Event ev) {
    return (ev && ev->raw.type == SDL_WINDOWEVENT)
           ? (int)ev->raw.window.data1 : 0;
}

int SDL2_EventWinH(SDL2_Event ev) {
    return (ev && ev->raw.type == SDL_WINDOWEVENT)
           ? (int)ev->raw.window.data2 : 0;
}

int SDL2_EventTextChar(SDL2_Event ev) {
    return (ev && ev->raw.type == SDL_TEXTINPUT)
           ? (int)(unsigned char)ev->raw.text.text[0] : 0;
}

/* ── Timing ──────────────────────────────────────────────────────────────── */

void SDL2_Delay(int ms) {
    SDL_Delay((Uint32)ms);
}

int SDL2_GetTicks(void) {
    return (int)SDL_GetTicks();
}

/* ── Mouse / keyboard state ──────────────────────────────────────────────── */

void SDL2_ShowCursor(int show) {
    SDL_ShowCursor(show ? SDL_ENABLE : SDL_DISABLE);
}

int SDL2_MouseX(void) {
    int x = 0;
    SDL_GetMouseState(&x, NULL);
    return x;
}

int SDL2_MouseY(void) {
    int y = 0;
    SDL_GetMouseState(NULL, &y);
    return y;
}

int SDL2_MouseButtons(void) {
    return (int)SDL_GetMouseState(NULL, NULL);
}

int SDL2_IsKeyDown(int key) {
    const Uint8 *state = SDL_GetKeyboardState(NULL);
    SDL_Scancode sc = SDL_GetScancodeFromKey((SDL_Keycode)key);
    return (sc < SDL_NUM_SCANCODES) ? (int)state[sc] : 0;
}

/* ── Module init ─────────────────────────────────────────────────────────── */
void SDL2_init(void) { }
