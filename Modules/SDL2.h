#ifndef OBC_SDL2_H_
#define OBC_SDL2_H_

#define SDL_MAIN_HANDLED
#include <SDL2/SDL.h>
#include <stdlib.h>
#include <string.h>

/* ── Init flags ──────────────────────────────────────────────────────────── */
enum { SDL2_InitTimer    = SDL_INIT_TIMER    };
enum { SDL2_InitAudio    = SDL_INIT_AUDIO    };
enum { SDL2_InitVideo    = SDL_INIT_VIDEO    };
enum { SDL2_InitEvents   = SDL_INIT_EVENTS   };
enum { SDL2_InitAll      = SDL_INIT_EVERYTHING };

/* ── Window position sentinels ───────────────────────────────────────────── */
enum { SDL2_WinPosCentered  = SDL_WINDOWPOS_CENTERED  };
enum { SDL2_WinPosUndefined = SDL_WINDOWPOS_UNDEFINED };

/* ── Window creation flags ───────────────────────────────────────────────── */
enum { SDL2_WinShown       = SDL_WINDOW_SHOWN        };
enum { SDL2_WinFullscreen  = SDL_WINDOW_FULLSCREEN   };
enum { SDL2_WinFullDesktop = SDL_WINDOW_FULLSCREEN_DESKTOP };
enum { SDL2_WinBorderless  = SDL_WINDOW_BORDERLESS   };
enum { SDL2_WinResizable   = SDL_WINDOW_RESIZABLE    };
enum { SDL2_WinHighDPI     = SDL_WINDOW_ALLOW_HIGHDPI };

/* ── Renderer creation flags ─────────────────────────────────────────────── */
enum { SDL2_RendSoftware    = SDL_RENDERER_SOFTWARE    };
enum { SDL2_RendAccelerated = SDL_RENDERER_ACCELERATED };
enum { SDL2_RendVSync       = SDL_RENDERER_PRESENTVSYNC };

/* ── Event type codes ────────────────────────────────────────────────────── */
enum { SDL2_EvQuit          = SDL_QUIT             };
enum { SDL2_EvKeyDown       = SDL_KEYDOWN          };
enum { SDL2_EvKeyUp         = SDL_KEYUP            };
enum { SDL2_EvTextInput     = SDL_TEXTINPUT        };
enum { SDL2_EvMouseMotion   = SDL_MOUSEMOTION      };
enum { SDL2_EvMouseDown     = SDL_MOUSEBUTTONDOWN  };
enum { SDL2_EvMouseUp       = SDL_MOUSEBUTTONUP    };
enum { SDL2_EvMouseWheel    = SDL_MOUSEWHEEL       };
enum { SDL2_EvWindowEvent   = SDL_WINDOWEVENT      };

/* ── Window sub-event ids (used with EvWindowEvent) ──────────────────────── */
enum { SDL2_WinEvResized    = SDL_WINDOWEVENT_RESIZED    };
enum { SDL2_WinEvMinimized  = SDL_WINDOWEVENT_MINIMIZED  };
enum { SDL2_WinEvMaximized  = SDL_WINDOWEVENT_MAXIMIZED  };
enum { SDL2_WinEvRestored   = SDL_WINDOWEVENT_RESTORED   };
enum { SDL2_WinEvFocusGain  = SDL_WINDOWEVENT_FOCUS_GAINED };
enum { SDL2_WinEvFocusLost  = SDL_WINDOWEVENT_FOCUS_LOST   };

/* ── Key codes (printable chars are their ASCII value) ───────────────────── */
enum { SDL2_KReturn    = SDLK_RETURN    };
enum { SDL2_KEnter     = SDLK_KP_ENTER };
enum { SDL2_KEsc       = SDLK_ESCAPE   };
enum { SDL2_KBackspace = SDLK_BACKSPACE };
enum { SDL2_KTab       = SDLK_TAB      };
enum { SDL2_KSpace     = SDLK_SPACE    };
enum { SDL2_KDelete    = SDLK_DELETE   };
enum { SDL2_KInsert    = SDLK_INSERT   };
enum { SDL2_KHome      = SDLK_HOME     };
enum { SDL2_KEnd       = SDLK_END      };
enum { SDL2_KPgUp      = SDLK_PAGEUP   };
enum { SDL2_KPgDn      = SDLK_PAGEDOWN };
enum { SDL2_KUp        = SDLK_UP       };
enum { SDL2_KDown      = SDLK_DOWN     };
enum { SDL2_KLeft      = SDLK_LEFT     };
enum { SDL2_KRight     = SDLK_RIGHT    };
enum { SDL2_KF1        = SDLK_F1       };
enum { SDL2_KF2        = SDLK_F2       };
enum { SDL2_KF3        = SDLK_F3       };
enum { SDL2_KF4        = SDLK_F4       };
enum { SDL2_KF5        = SDLK_F5       };
enum { SDL2_KF6        = SDLK_F6       };
enum { SDL2_KF7        = SDLK_F7       };
enum { SDL2_KF8        = SDLK_F8       };
enum { SDL2_KF9        = SDLK_F9       };
enum { SDL2_KF10       = SDLK_F10      };
enum { SDL2_KF11       = SDLK_F11      };
enum { SDL2_KF12       = SDLK_F12      };
enum { SDL2_KLShift    = SDLK_LSHIFT   };
enum { SDL2_KRShift    = SDLK_RSHIFT   };
enum { SDL2_KLCtrl     = SDLK_LCTRL    };
enum { SDL2_KRCtrl     = SDLK_RCTRL    };
enum { SDL2_KLAlt      = SDLK_LALT     };
enum { SDL2_KRAlt      = SDLK_RALT     };
enum { SDL2_KCapsLock  = SDLK_CAPSLOCK };

/* ── Key modifier masks (for EventMod) ───────────────────────────────────── */
enum { SDL2_ModNone    = KMOD_NONE   };
enum { SDL2_ModLShift  = KMOD_LSHIFT };
enum { SDL2_ModRShift  = KMOD_RSHIFT };
enum { SDL2_ModShift   = KMOD_SHIFT  };
enum { SDL2_ModLCtrl   = KMOD_LCTRL  };
enum { SDL2_ModRCtrl   = KMOD_RCTRL  };
enum { SDL2_ModCtrl    = KMOD_CTRL   };
enum { SDL2_ModLAlt    = KMOD_LALT   };
enum { SDL2_ModRAlt    = KMOD_RALT   };
enum { SDL2_ModAlt     = KMOD_ALT    };

/* ── Mouse button numbers ────────────────────────────────────────────────── */
enum { SDL2_BtnLeft    = SDL_BUTTON_LEFT   };
enum { SDL2_BtnMiddle  = SDL_BUTTON_MIDDLE };
enum { SDL2_BtnRight   = SDL_BUTTON_RIGHT  };

/* ── Blend modes ─────────────────────────────────────────────────────────── */
enum { SDL2_BlendNone  = SDL_BLENDMODE_NONE  };
enum { SDL2_BlendAlpha = SDL_BLENDMODE_BLEND };
enum { SDL2_BlendAdd   = SDL_BLENDMODE_ADD   };
enum { SDL2_BlendMod   = SDL_BLENDMODE_MOD   };

/* ── Render flip flags ───────────────────────────────────────────────────── */
enum { SDL2_FlipNone = SDL_FLIP_NONE       };
enum { SDL2_FlipH    = SDL_FLIP_HORIZONTAL };
enum { SDL2_FlipV    = SDL_FLIP_VERTICAL   };

/* ── OpenGL window flag ──────────────────────────────────────────────────── */
enum { SDL2_WinOpenGL = SDL_WINDOW_OPENGL };

/* ── OpenGL context attribute constants (for SDL2_GL_SetAttribute) ───────── */
enum { SDL2_GLA_DepthSize    = SDL_GL_DEPTH_SIZE             };
enum { SDL2_GLA_Doublebuffer = SDL_GL_DOUBLEBUFFER           };
enum { SDL2_GLA_MajorVersion = SDL_GL_CONTEXT_MAJOR_VERSION  };
enum { SDL2_GLA_MinorVersion = SDL_GL_CONTEXT_MINOR_VERSION  };
enum { SDL2_GLA_ProfileMask  = SDL_GL_CONTEXT_PROFILE_MASK   };
enum { SDL2_GL_ProfileCore   = SDL_GL_CONTEXT_PROFILE_CORE   };

/* ── Opaque handle types ─────────────────────────────────────────────────── */
typedef struct SDL2_WindowRec_s   { int _tag; } SDL2_WindowRec;
typedef struct SDL2_RendererRec_s { int _tag; } SDL2_RendererRec;
typedef struct SDL2_TextureRec_s  { int _tag; } SDL2_TextureRec;
typedef struct SDL2_SurfaceRec_s  { int _tag; } SDL2_SurfaceRec;
typedef struct SDL2_GLCtxRec_s    { int _tag; } SDL2_GLCtxRec;

typedef SDL2_WindowRec   *SDL2_Window;
typedef SDL2_RendererRec *SDL2_Renderer;
typedef SDL2_TextureRec  *SDL2_Texture;
typedef SDL2_SurfaceRec  *SDL2_Surface;
typedef SDL2_GLCtxRec    *SDL2_GLCtx;

/* ── Event type: opaque pointer; access via SDL2_Event* functions ─────────── */
typedef struct SDL2_EventRec_s {
    int       _tag;
    SDL_Event raw;
} SDL2_EventRec;
typedef SDL2_EventRec *SDL2_Event;

/* ── Type tags ───────────────────────────────────────────────────────────── */
#define _TAG_SDL2_WindowRec   1
#define _TAG_SDL2_RendererRec 2
#define _TAG_SDL2_TextureRec  3
#define _TAG_SDL2_SurfaceRec  4
#define _TAG_SDL2_EventRec    5
#define _TAG_SDL2_GLCtxRec    6

/* ── System ──────────────────────────────────────────────────────────────── */
int   SDL2_Init(int flags);
void  SDL2_Quit(void);
void  SDL2_GetError(char *buf);   /* copies SDL_GetError() into buf */

/* ── Window ──────────────────────────────────────────────────────────────── */
SDL2_Window SDL2_CreateWindow(char *title, int w, int h, int flags);
SDL2_Window SDL2_CreateWindowAt(char *title, int x, int y, int w, int h, int flags);
void        SDL2_DestroyWindow(SDL2_Window win);
void        SDL2_SetWindowTitle(SDL2_Window win, char *title);
int         SDL2_WindowWidth(SDL2_Window win);
int         SDL2_WindowHeight(SDL2_Window win);

/* ── Renderer ────────────────────────────────────────────────────────────── */
SDL2_Renderer SDL2_CreateRenderer(SDL2_Window win, int flags);
void          SDL2_DestroyRenderer(SDL2_Renderer ren);
void          SDL2_SetDrawColor(SDL2_Renderer ren, int r, int g, int b, int a);
void          SDL2_Clear(SDL2_Renderer ren);
void          SDL2_Present(SDL2_Renderer ren);
void          SDL2_DrawPoint(SDL2_Renderer ren, int x, int y);
void          SDL2_DrawLine(SDL2_Renderer ren, int x1, int y1, int x2, int y2);
void          SDL2_DrawRect(SDL2_Renderer ren, int x, int y, int w, int h);
void          SDL2_FillRect(SDL2_Renderer ren, int x, int y, int w, int h);
void          SDL2_SetBlendMode(SDL2_Renderer ren, int mode);
void          SDL2_SetClipRect(SDL2_Renderer ren, int x, int y, int w, int h);
void          SDL2_ClearClipRect(SDL2_Renderer ren);
void          SDL2_SetScale(SDL2_Renderer ren, double sx, double sy);
void          SDL2_SetRenderTarget(SDL2_Renderer ren, SDL2_Texture tex);
void          SDL2_ClearRenderTarget(SDL2_Renderer ren);

/* ── Texture ─────────────────────────────────────────────────────────────── */
SDL2_Texture SDL2_CreateTexture(SDL2_Renderer ren, int w, int h);
SDL2_Texture SDL2_CreateTextureFromSurface(SDL2_Renderer ren, SDL2_Surface surf);
void         SDL2_DestroyTexture(SDL2_Texture tex);
void         SDL2_RenderCopy(SDL2_Renderer ren, SDL2_Texture tex,
                              int dx, int dy, int dw, int dh);
void         SDL2_RenderCopyRect(SDL2_Renderer ren, SDL2_Texture tex,
                                  int sx, int sy, int sw, int sh,
                                  int dx, int dy, int dw, int dh);
void         SDL2_RenderCopyEx(SDL2_Renderer ren, SDL2_Texture tex,
                                int dx, int dy, int dw, int dh,
                                double angle, int flip);
void         SDL2_SetTextureColor(SDL2_Texture tex, int r, int g, int b);
void         SDL2_SetTextureAlpha(SDL2_Texture tex, int a);
void         SDL2_SetTextureBlend(SDL2_Texture tex, int mode);
int          SDL2_TextureWidth(SDL2_Texture tex);
int          SDL2_TextureHeight(SDL2_Texture tex);

/* ── Surface ─────────────────────────────────────────────────────────────── */
SDL2_Surface SDL2_LoadBMP(char *path);
void         SDL2_FreeSurface(SDL2_Surface surf);

/* ── Events ──────────────────────────────────────────────────────────────── */
/* ev must point to a valid SDL2_EventRec (use NEW(ev) in Oberon).           */
int  SDL2_PollEvent(SDL2_Event ev);   /* returns 1 if event available        */
void SDL2_WaitEvent(SDL2_Event ev);   /* blocks until an event arrives        */
int  SDL2_EventKind(SDL2_Event ev);   /* event type (EvQuit, EvKeyDown, ...)  */
int  SDL2_EventKey(SDL2_Event ev);    /* key sym (for EvKeyDown / EvKeyUp)    */
int  SDL2_EventMod(SDL2_Event ev);    /* modifier mask (ModCtrl, ModShift, …) */
int  SDL2_EventMouseX(SDL2_Event ev); /* mouse x (motion / button events)     */
int  SDL2_EventMouseY(SDL2_Event ev); /* mouse y (motion / button events)     */
int  SDL2_EventMouseBtn(SDL2_Event ev); /* button number (EvMouseDown/Up)     */
int  SDL2_EventWheelX(SDL2_Event ev); /* horizontal scroll (EvMouseWheel)     */
int  SDL2_EventWheelY(SDL2_Event ev); /* vertical scroll   (EvMouseWheel)     */
int  SDL2_EventWinID(SDL2_Event ev);  /* window id (EvWindowEvent)            */
int  SDL2_EventWinEv(SDL2_Event ev);  /* window sub-event (WinEvResized, ...)  */
int  SDL2_EventWinW(SDL2_Event ev);   /* new width  after WinEvResized        */
int  SDL2_EventWinH(SDL2_Event ev);   /* new height after WinEvResized        */
int  SDL2_EventTextChar(SDL2_Event ev); /* first char of text input           */

/* ── Timing ──────────────────────────────────────────────────────────────── */
void SDL2_Delay(int ms);
int  SDL2_GetTicks(void);

/* ── Mouse / keyboard state ──────────────────────────────────────────────── */
void SDL2_ShowCursor(int show);
int  SDL2_MouseX(void);
int  SDL2_MouseY(void);
int  SDL2_MouseButtons(void);
int  SDL2_IsKeyDown(int key);         /* 1 if key currently held             */

/* ── OpenGL context ──────────────────────────────────────────────────────── */
int        SDL2_GL_SetAttribute(int attr, int value);
SDL2_GLCtx SDL2_GL_CreateContext(SDL2_Window win);
void       SDL2_GL_DeleteContext(SDL2_GLCtx ctx);
void       SDL2_GL_SwapWindow(SDL2_Window win);

/* ── Module init (no-op — called by obc runtime) ─────────────────────────── */
void SDL2_init(void);

#endif /* OBC_SDL2_H_ */
