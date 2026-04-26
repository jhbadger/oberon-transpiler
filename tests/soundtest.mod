MODULE SoundTest;
(*
 * SDL2Sound FFI test.
 *
 * Synthesises two WAV files into /tmp at startup so no external audio assets
 * are needed:
 *   /tmp/obc_sfx.wav    — short 440 Hz beep (sound effect)
 *   /tmp/obc_music.wav  — 4-second 220 Hz tone (background "music")
 *
 * Controls
 *   B          play beep (sound effect, stacks on queue)
 *   M          start / restart background music loop
 *   S          stop all audio (SDL2Sound.Stop)
 *   Esc / Q    quit
 *
 * The status line shows how many bytes are still queued for playback so you
 * can watch it drain after pressing S.
 *)

IMPORT SDL2, SDL2Sound, Out;

CONST
  W = 640; H = 200;

VAR
  win:     SDL2.Window;
  ren:     SDL2.Renderer;
  ev:      SDL2.Event;
  sfx:     SDL2Sound.Sample;
  music:   SDL2Sound.Sample;
  running: BOOLEAN;
  musicOn: BOOLEAN;
  k, q:   INTEGER;
  err:    ARRAY 256 OF CHAR;

(* ── Refresh the status line shown in the window title ──────────────────── *)

PROCEDURE UpdateTitle;
VAR q: INTEGER;
BEGIN
  q := SDL2Sound.Queued();
  IF musicOn THEN
    SDL2.SetWindowTitle(win, "SoundTest  [B=beep  M=music(on)  S=stop  Esc=quit]")
  ELSE
    SDL2.SetWindowTitle(win, "SoundTest  [B=beep  M=music(off) S=stop  Esc=quit]")
  END
END UpdateTitle;

(* ── Render a simple info screen ─────────────────────────────────────────── *)

PROCEDURE Draw;
BEGIN
  SDL2.SetDrawColor(ren, 20, 20, 40, 255);
  SDL2.Clear(ren);
  (* queued-bytes bar: max ~800 000 bytes ≈ 4 s of audio *)
  q := SDL2Sound.Queued();
  IF q > 800000 THEN q := 800000 END;
  SDL2.SetDrawColor(ren, 80, 180, 80, 255);
  SDL2.FillRect(ren, 20, 80, q * (W - 40) DIV 800000 + 1, 40);
  SDL2.SetDrawColor(ren, 100, 100, 140, 255);
  SDL2.DrawRect(ren, 20, 80, W - 40, 40);
  SDL2.Present(ren)
END Draw;

BEGIN
  (* ── Init SDL2 (video) and SDL2Sound (audio) ── *)
  IF SDL2.Init(SDL2.InitVideo) < 0 THEN
    Out.String("SDL2.Init failed"); Out.Ln; HALT(1)
  END;
  IF SDL2Sound.Init() = 0 THEN
    SDL2Sound.GetError(err);
    Out.String("SDL2Sound.Init failed: "); Out.String(err); Out.Ln;
    SDL2.Quit(); HALT(1)
  END;

  win := SDL2.CreateWindow("SoundTest", W, H, SDL2.WinShown);
  IF win = NIL THEN
    Out.String("CreateWindow failed"); Out.Ln;
    SDL2Sound.Quit(); SDL2.Quit(); HALT(1)
  END;
  ren := SDL2.CreateRenderer(win, SDL2.RendAccelerated);
  IF ren = NIL THEN ren := SDL2.CreateRenderer(win, SDL2.RendSoftware) END;
  NEW(ev);

  (* ── Synthesise WAV files into /tmp ── *)
  IF SDL2Sound.WriteSineWAV("/tmp/obc_sfx.wav",   440, 200) = 0 THEN
    Out.String("Warning: could not write /tmp/obc_sfx.wav"); Out.Ln
  END;
  IF SDL2Sound.WriteSineWAV("/tmp/obc_music.wav", 220, 4000) = 0 THEN
    Out.String("Warning: could not write /tmp/obc_music.wav"); Out.Ln
  END;

  (* ── Load synthesised WAV files ── *)
  sfx := SDL2Sound.Load("/tmp/obc_sfx.wav");
  IF sfx = NIL THEN
    Out.String("Warning: could not load /tmp/obc_sfx.wav"); Out.Ln
  ELSE
    Out.String("sfx loaded, duration=");
    Out.Int(SDL2Sound.Duration(sfx), 0); Out.String(" ms"); Out.Ln
  END;

  music := SDL2Sound.Load("/tmp/obc_music.wav");
  IF music = NIL THEN
    Out.String("Warning: could not load /tmp/obc_music.wav"); Out.Ln
  ELSE
    Out.String("music loaded, duration=");
    Out.Int(SDL2Sound.Duration(music), 0); Out.String(" ms"); Out.Ln
  END;

  musicOn := FALSE;
  running := TRUE;
  UpdateTitle;

  WHILE running DO

    (* ── Events ── *)
    WHILE SDL2.PollEvent(ev) > 0 DO
      k := SDL2.EventKind(ev);
      IF k = SDL2.EvQuit THEN
        running := FALSE
      ELSIF k = SDL2.EvKeyDown THEN
        IF (SDL2.EventKey(ev) = SDL2.KEsc) OR
           (SDL2.EventKey(ev) = ORD("q"))  OR
           (SDL2.EventKey(ev) = ORD("Q"))  THEN
          running := FALSE
        ELSIF (SDL2.EventKey(ev) = ORD("b")) OR
              (SDL2.EventKey(ev) = ORD("B")) THEN
          IF sfx # NIL THEN
            IF SDL2Sound.Play(sfx) = 0 THEN
              Out.String("sfx play failed"); Out.Ln
            END
          END
        ELSIF (SDL2.EventKey(ev) = ORD("m")) OR
              (SDL2.EventKey(ev) = ORD("M")) THEN
          musicOn := ~musicOn;
          IF ~musicOn THEN SDL2Sound.Stop END;
          UpdateTitle
        ELSIF (SDL2.EventKey(ev) = ORD("s")) OR
              (SDL2.EventKey(ev) = ORD("S")) THEN
          SDL2Sound.Stop;
          musicOn := FALSE;
          UpdateTitle
        END
      END
    END;

    (* ── Re-queue music when the buffer runs low (≈ 0.5 s remaining) ── *)
    IF musicOn & (music # NIL) THEN
      IF SDL2Sound.Queued() < 88200 THEN
        IF SDL2Sound.Play(music) = 0 THEN
          Out.String("music play failed"); Out.Ln;
          musicOn := FALSE
        END
      END
    END;

    Draw;
    SDL2.Delay(16)
  END;

  IF sfx   # NIL THEN SDL2Sound.Free(sfx)   END;
  IF music # NIL THEN SDL2Sound.Free(music) END;
  SDL2Sound.Quit;
  SDL2.DestroyRenderer(ren);
  SDL2.DestroyWindow(win);
  SDL2.Quit
END SoundTest.
