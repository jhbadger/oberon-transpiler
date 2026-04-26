/* SDL2Sound.c -- Oberon FFI wrappers for SDL2_sound.
 *
 * Load decodes the entire file into a plain PCM buffer immediately; the
 * Sound_Sample is then freed.  Play just calls SDL_QueueAudio on the cached
 * buffer, so it is safe to call repeatedly with no seek/re-decode overhead.
 */

#include "SDL2Sound.h"
#include <math.h>

static SDL_AudioDeviceID audio_dev = 0;

/* ── System ──────────────────────────────────────────────────────────────── */

int SDL2Sound_Init(void) {
    if (SDL_InitSubSystem(SDL_INIT_AUDIO) < 0) return 0;

    SDL_AudioSpec want, got;
    SDL_memset(&want, 0, sizeof(want));
    want.freq     = 44100;
    want.format   = AUDIO_S16SYS;
    want.channels = 2;
    want.samples  = 4096;

    audio_dev = SDL_OpenAudioDevice(NULL, 0, &want, &got, 0);
    if (!audio_dev) return 0;

    SDL_PauseAudioDevice(audio_dev, 0);
    return Sound_Init();
}

void SDL2Sound_Quit(void) {
    Sound_Quit();
    if (audio_dev) {
        SDL_CloseAudioDevice(audio_dev);
        audio_dev = 0;
    }
}

void SDL2Sound_GetError(char *buf) {
    if (!buf) return;
    const char *e = SDL_GetError();
    if (!e || !*e) e = Sound_GetError();
    strncpy(buf, e ? e : "", 255);
    buf[255] = '\0';
}

/* ── Sample management ───────────────────────────────────────────────────── */

SDL2Sound_Sample SDL2Sound_Load(char *path) {
    if (!path) return NULL;

    Sound_AudioInfo di;
    di.format   = AUDIO_S16SYS;
    di.channels = 2;
    di.rate     = 44100;

    Sound_Sample *s = Sound_NewSampleFromFile(path, &di, 65536);
    if (!s) return NULL;

    Sint32 dur = Sound_GetDuration(s);   /* query before DecodeAll moves cursor */

    Uint32 n = Sound_DecodeAll(s);
    if (n == 0) { Sound_FreeSample(s); return NULL; }

    /* calculate duration from bytes if SDL_sound couldn't determine it */
    if (dur < 0) dur = (Sint32)((Uint64)n * 1000 / (44100 * 2 * 2));

    SDL2Sound_SampleRec *rec = (SDL2Sound_SampleRec *)SDL_malloc(sizeof(*rec));
    if (!rec) { Sound_FreeSample(s); return NULL; }

    rec->pcm = SDL_malloc(n);
    if (!rec->pcm) { SDL_free(rec); Sound_FreeSample(s); return NULL; }

    rec->_tag     = _TAG_SDL2Sound_SampleRec;
    rec->bytes    = (int)n;
    rec->duration = (int)dur;
    SDL_memcpy(rec->pcm, s->buffer, n);
    Sound_FreeSample(s);   /* no longer needed */

    return rec;
}

void SDL2Sound_Free(SDL2Sound_Sample sample) {
    if (sample) {
        SDL_free(sample->pcm);
        SDL_free(sample);
    }
}

int SDL2Sound_Duration(SDL2Sound_Sample sample) {
    return sample ? sample->duration : -1;
}

/* ── Playback ────────────────────────────────────────────────────────────── */

int SDL2Sound_Play(SDL2Sound_Sample sample) {
    if (!sample || !audio_dev || !sample->pcm) return 0;
    return SDL_QueueAudio(audio_dev, sample->pcm, (Uint32)sample->bytes) == 0 ? 1 : 0;
}

void SDL2Sound_Stop(void) {
    if (audio_dev) SDL_ClearQueuedAudio(audio_dev);
}

int SDL2Sound_Queued(void) {
    if (!audio_dev) return 0;
    return (int)SDL_GetQueuedAudioSize(audio_dev);
}

/* ── Utility ─────────────────────────────────────────────────────────────── */

int SDL2Sound_WriteSineWAV(char *path, int hz, int ms) {
    if (!path || hz <= 0 || ms <= 0) return 0;

    const int rate      = 44100;
    const int channels  = 2;
    const int nframes   = rate * ms / 1000;
    const int nsamples  = nframes * channels;
    const int data_bytes = nsamples * 2;

    Sint16 *buf = (Sint16 *)SDL_malloc((size_t)data_bytes);
    if (!buf) return 0;

    for (int i = 0; i < nframes; i++) {
        double t   = (double)i / rate;
        double env = (i < nframes * 9 / 10) ? 1.0
                     : (double)(nframes - i) / (nframes / 10.0);
        Sint16 v = (Sint16)(SDL_sin(2.0 * M_PI * hz * t) * 16383.0 * env);
        buf[i * channels]     = v;
        buf[i * channels + 1] = v;
    }

    SDL_RWops *rw = SDL_RWFromFile(path, "wb");
    if (!rw) { SDL_free(buf); return 0; }

    Uint32 chunk_size  = (Uint32)(36 + data_bytes);
    Uint32 subchunk2   = (Uint32)data_bytes;
    Uint32 byte_rate   = (Uint32)(rate * channels * 2);
    Uint16 block_align = (Uint16)(channels * 2);
    Uint16 fmt_size    = 16;
    Uint16 audio_fmt   = 1;   /* PCM */
    Uint16 bits        = 16;
    Uint16 ch16        = (Uint16)channels;
    Uint32 rate32      = (Uint32)rate;

#define WR16(v) { Uint16 _v = SDL_SwapLE16(v); SDL_RWwrite(rw, &_v, 2, 1); }
#define WR32(v) { Uint32 _v = SDL_SwapLE32(v); SDL_RWwrite(rw, &_v, 4, 1); }
    SDL_RWwrite(rw, "RIFF", 4, 1); WR32(chunk_size);
    SDL_RWwrite(rw, "WAVE", 4, 1);
    SDL_RWwrite(rw, "fmt ", 4, 1); WR32(fmt_size);
    WR16(audio_fmt); WR16(ch16); WR32(rate32);
    WR32(byte_rate); WR16(block_align); WR16(bits);
    SDL_RWwrite(rw, "data", 4, 1); WR32(subchunk2);
#undef WR16
#undef WR32

    for (int i = 0; i < nsamples; i++) {
        Uint16 v = SDL_SwapLE16((Uint16)buf[i]);
        SDL_RWwrite(rw, &v, 2, 1);
    }

    SDL_RWclose(rw);
    SDL_free(buf);
    return 1;
}

/* ── Module init ─────────────────────────────────────────────────────────── */
void SDL2Sound_init(void) { }
