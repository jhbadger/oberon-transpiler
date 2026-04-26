#ifndef OBC_SDL2SOUND_H_
#define OBC_SDL2SOUND_H_

#define SDL_MAIN_HANDLED
#include <SDL2/SDL.h>
#include <SDL2/SDL_sound.h>
#include <string.h>

/* ── Opaque handle type ──────────────────────────────────────────────────── */
/* PCM is decoded once at Load time; Play just queues the cached bytes. */
typedef struct SDL2Sound_SampleRec_s {
    int    _tag;
    void  *pcm;      /* decoded S16 stereo 44100 Hz data */
    int    bytes;    /* byte count of pcm */
    int    duration; /* milliseconds */
} SDL2Sound_SampleRec;
typedef SDL2Sound_SampleRec *SDL2Sound_Sample;

#define _TAG_SDL2Sound_SampleRec 1

/* ── System ──────────────────────────────────────────────────────────────── */
/* Opens the default audio device (44100 Hz, S16, stereo) and inits SDL_sound. */
int  SDL2Sound_Init(void);
void SDL2Sound_Quit(void);
void SDL2Sound_GetError(char *buf);   /* copies Sound_GetError() into buf */

/* ── Sample management ───────────────────────────────────────────────────── */
/* Load a sound file; returns NULL on error.
   The sample is decoded to 44100 Hz / S16 / stereo to match the audio device. */
SDL2Sound_Sample SDL2Sound_Load(char *path);
void             SDL2Sound_Free(SDL2Sound_Sample sample);

/* Duration in milliseconds (-1 if unknown). */
int  SDL2Sound_Duration(SDL2Sound_Sample sample);

/* ── Playback ────────────────────────────────────────────────────────────── */
/* Decode the entire sample and queue it for playback.
   Returns 1 on success, 0 on error. */
int  SDL2Sound_Play(SDL2Sound_Sample sample);

/* Stop all currently queued audio output. */
void SDL2Sound_Stop(void);

/* Approximate bytes still waiting to be played (0 = playback done). */
int  SDL2Sound_Queued(void);

/* ── Utility ─────────────────────────────────────────────────────────────── */
/* Write a sine-wave WAV to path (44100 Hz / S16 / stereo).
   hz = frequency in Hz, ms = duration in milliseconds.
   Returns 1 on success, 0 on error. */
int SDL2Sound_WriteSineWAV(char *path, int hz, int ms);

/* ── Module init (called by obc runtime) ─────────────────────────────────── */
void SDL2Sound_init(void);

#endif /* OBC_SDL2SOUND_H_ */
