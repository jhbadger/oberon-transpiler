MODULE Radio;

(*
 * Internet Radio - TUI-based station browser and player.
 *
 * Discovers stations via radio-browser.info (no account needed).
 * Audio is streamed by mpv running as a background process so music
 * continues playing after you exit to the prompt.  Run the program
 * again to change stations or stop playback.
 *
 * Requirements: mpv (pkg install mpv), curl, python3
 *
 * Controls:
 *   Type        – build search query
 *   Enter       – search (search focus) / play selected station (list focus)
 *   Up / Down   – navigate station list
 *   Tab         – toggle focus between search box and station list
 *   S           – stop playback
 *   Esc         – exit to prompt  (music keeps playing)
 *   Q           – stop music and quit
 *)

IMPORT TUI, Strings, Files, OS;

CONST
  MaxStations = 20;
  TmpDir     = '/data/data/com.termux/files/usr/tmp';
  PidFile    = '/data/data/com.termux/files/usr/tmp/radio.pid';
  StateFile  = '/data/data/com.termux/files/usr/tmp/radio.state';
  RawFile    = '/data/data/com.termux/files/usr/tmp/radio_raw.json';
  ResultFile = '/data/data/com.termux/files/usr/tmp/radio_results.txt';
  ParsePy    = '/data/data/com.termux/files/usr/tmp/radio_parse.py';
  API        = 'https://de1.api.radio-browser.info/json/stations/search';

  MODE_SEARCH  = 0;
  MODE_RESULTS = 1;

TYPE
  Station = RECORD
    name    : ARRAY 128 OF CHAR;
    url     : ARRAY 512 OF CHAR;
    codec   : ARRAY 16  OF CHAR;
    country : ARRAY 64  OF CHAR;
    bitrate : ARRAY 8   OF CHAR
  END;

VAR
  stations  : ARRAY MaxStations OF Station;
  stCount   : INTEGER;
  selIdx    : INTEGER;
  scrollOff : INTEGER;
  focusMode : INTEGER;
  searchBuf : ARRAY 128 OF CHAR;
  searchLen : INTEGER;
  nowName   : ARRAY 128 OF CHAR;
  isPlaying : BOOLEAN;
  statusMsg : ARRAY 256 OF CHAR;
  ev        : TUI.Event;
  done      : BOOLEAN;

(* ── I/O helpers ─────────────────────────────────────────────────────── *)

PROCEDURE ReadLine(VAR r: Files.Rider; VAR s: ARRAY OF CHAR);
VAR i: INTEGER; b: BYTE;
BEGIN
  i := 0;
  WHILE ~r.eof & (i < LEN(s) - 1) DO
    Files.Read(r, b);
    IF ~r.eof THEN
      IF b = 10 THEN
        IF (i > 0) & (ORD(s[i-1]) = 13) THEN DEC(i) END;
        s[i] := 0X; RETURN
      END;
      s[i] := CHR(b); INC(i)
    END
  END;
  s[i] := 0X
END ReadLine;

PROCEDURE ReadPid(VAR pid: ARRAY OF CHAR): BOOLEAN;
VAR f: Files.File; r: Files.Rider;
BEGIN
  pid[0] := 0X;
  f := Files.Old(PidFile);
  IF f = NIL THEN RETURN FALSE END;
  Files.Set(r, f, 0);
  ReadLine(r, pid);
  Files.Close(f);
  Strings.Trim(pid);
  RETURN pid[0] # 0X
END ReadPid;

PROCEDURE ProcAlive(pid: ARRAY OF CHAR): BOOLEAN;
VAR cmd: ARRAY 64 OF CHAR;
BEGIN
  cmd := 'kill -0 ';
  Strings.Append(pid, cmd);
  Strings.Append(' 2>/dev/null', cmd);
  RETURN OS.Exec(cmd) = 0
END ProcAlive;

PROCEDURE LoadState;
VAR f: Files.File; r: Files.Rider; pid: ARRAY 16 OF CHAR;
BEGIN
  isPlaying := FALSE; nowName[0] := 0X;
  IF ~ReadPid(pid) THEN RETURN END;
  IF ProcAlive(pid) THEN
    isPlaying := TRUE;
    f := Files.Old(StateFile);
    IF f # NIL THEN
      Files.Set(r, f, 0);
      ReadLine(r, nowName);
      Strings.Trim(nowName);
      Files.Close(f)
    END
  ELSE
    Files.Delete(PidFile); Files.Delete(StateFile)
  END
END LoadState;

PROCEDURE WriteParser;
(* Write a tiny Python script that converts radio-browser JSON to pipe-delimited lines. *)
VAR f: Files.File; r: Files.Rider;
BEGIN
  f := Files.New(ParsePy);
  IF f = NIL THEN RETURN END;
  Files.Set(r, f, 0);
  Files.WriteLine(r, 'import sys,json');
  Files.WriteLine(r, 'data=json.loads(open("/data/data/com.termux/files/usr/tmp/radio_raw.json").read())');
  Files.WriteLine(r, 'for s in data[:20]:');
  Files.WriteLine(r, '    name=s.get("name","").replace("|","").strip()[:80]');
  Files.WriteLine(r, '    url=s.get("url_resolved",s.get("url","")).strip()');
  Files.WriteLine(r, '    codec=s.get("codec","").replace("|","").strip()[:10]');
  Files.WriteLine(r, '    bitrate=str(s.get("bitrate",0))');
  Files.WriteLine(r, '    country=s.get("country","").replace("|","").strip()[:40]');
  Files.WriteLine(r, '    if url:');
  Files.WriteLine(r, '        print(name+"|"+url+"|"+codec+"|"+bitrate+"|"+country)');
  Files.Close(f)
END WriteParser;

PROCEDURE URLEncode(src: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR);
VAR i, j: INTEGER; c: CHAR;
BEGIN
  i := 0; j := 0;
  WHILE (i < LEN(src)) & (src[i] # 0X) & (j < LEN(dst) - 4) DO
    c := src[i];
    IF c = " " THEN dst[j] := "+"; INC(j) ELSE dst[j] := c; INC(j) END;
    INC(i)
  END;
  dst[j] := 0X
END URLEncode;

PROCEDURE Trunc(src: ARRAY OF CHAR; maxLen: INTEGER; VAR dst: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (i < maxLen) & (i < LEN(dst) - 1) & (src[i] # 0X) DO
    dst[i] := src[i]; INC(i)
  END;
  dst[i] := 0X
END Trunc;

(* ── drawing ─────────────────────────────────────────────────────────── *)

PROCEDURE Draw;
VAR i, y, listH, nameCols, col, fg, bg: INTEGER;
    buf: ARRAY 200 OF CHAR;
BEGIN
  TUI.ClearBack(TUI.White, TUI.Black);

  (* Header *)
  TUI.FillRect(1, 1, TUI.Cols, 1, " ", TUI.White, TUI.Blue);
  TUI.PutStr(2, 1, '* Internet Radio  [radio-browser.info]', TUI.White, TUI.Blue);

  (* Now-playing indicator *)
  IF isPlaying THEN
    TUI.FillRect(1, 2, TUI.Cols, 1, " ", TUI.Black, TUI.Green);
    buf := '> '; Strings.Append(nowName, buf);
    TUI.PutStr(2, 2, buf, TUI.Black, TUI.Green)
  ELSE
    TUI.FillRect(1, 2, TUI.Cols, 1, " ", TUI.White, TUI.Black);
    TUI.PutStr(2, 2, '(not playing)', TUI.White, TUI.Black)
  END;

  (* Search box *)
  TUI.PutStr(2, 3, 'Search:', TUI.Yellow, TUI.Black);
  IF focusMode = MODE_SEARCH THEN fg := TUI.Black; bg := TUI.White
  ELSE fg := TUI.White; bg := TUI.Black END;
  TUI.FillRect(10, 3, TUI.Cols - 10, 1, " ", fg, bg);
  TUI.PutStr(10, 3, searchBuf, fg, bg);

  (* Divider *)
  TUI.FillRect(1, 4, TUI.Cols, 1, "-", TUI.White, TUI.Black);

  (* Column headers *)
  nameCols := TUI.Cols - 30;
  col := nameCols + 3;
  TUI.PutStr(2, 5, 'Station', TUI.Yellow, TUI.Black);
  TUI.PutStr(col,      5, 'Codec',   TUI.Yellow, TUI.Black);
  TUI.PutStr(col + 7,  5, 'kbps',   TUI.Yellow, TUI.Black);
  TUI.PutStr(col + 13, 5, 'Country', TUI.Yellow, TUI.Black);

  (* Station list *)
  listH := TUI.Rows - 6;
  FOR i := 0 TO listH - 1 DO
    y := 6 + i;
    IF scrollOff + i < stCount THEN
      IF scrollOff + i = selIdx THEN fg := TUI.Black; bg := TUI.Cyan
      ELSE fg := TUI.White; bg := TUI.Black END;
      TUI.FillRect(1, y, TUI.Cols, 1, " ", fg, bg);
      Trunc(stations[scrollOff + i].name, nameCols, buf);
      TUI.PutStr(2, y, buf, fg, bg);
      TUI.PutStr(col,      y, stations[scrollOff + i].codec,   fg, bg);
      TUI.PutStr(col + 7,  y, stations[scrollOff + i].bitrate, fg, bg);
      Trunc(stations[scrollOff + i].country, 14, buf);
      TUI.PutStr(col + 13, y, buf, fg, bg)
    ELSE
      TUI.FillRect(1, y, TUI.Cols, 1, " ", TUI.White, TUI.Black)
    END
  END;

  (* Status / help bar *)
  TUI.FillRect(1, TUI.Rows, TUI.Cols, 1, " ", TUI.Black, TUI.White);
  IF statusMsg[0] # 0X THEN
    TUI.PutStr(2, TUI.Rows, statusMsg, TUI.Black, TUI.White)
  ELSIF focusMode = MODE_SEARCH THEN
    TUI.PutStr(2, TUI.Rows, 'Enter:Search  Tab:List  S:Stop  Esc:Exit(keep playing)  Q:Stop+Quit',
               TUI.Black, TUI.White)
  ELSE
    TUI.PutStr(2, TUI.Rows, 'Enter:Play  Tab:Search  S:Stop  Esc:Exit(keep playing)  Q:Stop+Quit',
               TUI.Black, TUI.White)
  END;

  TUI.Flush
END Draw;

(* ── station control ─────────────────────────────────────────────────── *)

PROCEDURE StopPlay;
VAR cmd: ARRAY 64 OF CHAR; pid: ARRAY 16 OF CHAR;
BEGIN
  IF ReadPid(pid) THEN
    cmd := 'kill '; Strings.Append(pid, cmd);
    OS.Exec(cmd);
    Files.Delete(PidFile); Files.Delete(StateFile)
  END;
  isPlaying := FALSE; nowName[0] := 0X;
  statusMsg := 'Stopped.'
END StopPlay;

PROCEDURE LoadResults;
VAR f: Files.File; r: Files.Rider; line: ARRAY 768 OF CHAR;
BEGIN
  stCount := 0; selIdx := 0; scrollOff := 0;
  f := Files.Old(ResultFile);
  IF f = NIL THEN statusMsg := 'No results (curl or API failed).'; RETURN END;
  Files.Set(r, f, 0);
  WHILE ~r.eof & (stCount < MaxStations) DO
    ReadLine(r, line);
    IF line[0] # 0X THEN
      stations[stCount].url[0] := 0X;
      Strings.Split(line, CHR(124), 0, stations[stCount].name);
      Strings.Split(line, CHR(124), 1, stations[stCount].url);
      Strings.Split(line, CHR(124), 2, stations[stCount].codec);
      Strings.Split(line, CHR(124), 3, stations[stCount].bitrate);
      Strings.Split(line, CHR(124), 4, stations[stCount].country);
      IF stations[stCount].url[0] # 0X THEN INC(stCount) END
    END
  END;
  Files.Close(f);
  IF stCount = 0 THEN
    statusMsg := 'No stations found.'
  ELSE
    Strings.IntToStr(stCount, statusMsg);
    Strings.Append(' stations. Tab to focus list, Enter to play.', statusMsg);
    focusMode := MODE_RESULTS
  END
END LoadResults;

PROCEDURE Play(idx: INTEGER);
VAR cmd: ARRAY 768 OF CHAR; f: Files.File; r: Files.Rider;
BEGIN
  IF isPlaying THEN StopPlay END;
  (* Start mpv in background; capture its PID for later control. *)
  cmd := 'mpv --no-video --really-quiet "';
  Strings.Append(stations[idx].url, cmd);
  Strings.Append('" >/dev/null 2>&1 & echo $! > ', cmd);
  Strings.Append(PidFile, cmd);
  OS.Exec(cmd);
  f := Files.New(StateFile);
  IF f # NIL THEN
    Files.Set(r, f, 0);
    Files.WriteLine(r, stations[idx].name);
    Files.Close(f)
  END;
  LoadState;
  IF isPlaying THEN
    statusMsg := 'Playing: '; Strings.Append(nowName, statusMsg)
  ELSE
    statusMsg := 'mpv failed to start. Install with: pkg install mpv'
  END
END Play;

PROCEDURE Search;
VAR cmd: ARRAY 512 OF CHAR; enc: ARRAY 128 OF CHAR;
BEGIN
  IF searchLen = 0 THEN statusMsg := 'Enter a search term first.'; RETURN END;
  statusMsg := 'Searching...';
  Draw;  (* show feedback before blocking network call *)
  TUI.Suspend;
  URLEncode(searchBuf, enc);
  cmd := 'curl -s --max-time 15 "';
  Strings.Append(API, cmd); Strings.Append('?name=', cmd);
  Strings.Append(enc, cmd);
  Strings.Append('&limit=20&hidebroken=true&order=votes" -o ', cmd);
  Strings.Append(RawFile, cmd);
  OS.Exec(cmd);
  cmd := 'python3 '; Strings.Append(ParsePy, cmd);
  Strings.Append(' > ', cmd); Strings.Append(ResultFile, cmd);
  OS.Exec(cmd);
  TUI.Resume;
  TUI.InvalidateFront;
  LoadResults
END Search;

(* ── main ─────────────────────────────────────────────────────────────── *)

BEGIN
  TUI.Init;
  WriteParser;
  LoadState;
  stCount := 0; selIdx := 0; scrollOff := 0;
  searchBuf[0] := 0X; searchLen := 0;
  focusMode := MODE_SEARCH;
  statusMsg[0] := 0X;
  done := FALSE;

  IF isPlaying THEN
    statusMsg := 'Music is playing. Search to change, S to stop, Esc to exit to prompt.'
  END;

  REPEAT
    Draw;
    TUI.WaitEvent(ev);
    IF ev.kind = TUI.EvKey THEN
      statusMsg[0] := 0X;
      IF ev.key = TUI.KEsc THEN
        (* Exit but leave mpv running *)
        done := TRUE
      ELSIF (ev.key = "Q") OR (ev.key = 17) THEN
        (* Stop music and quit *)
        IF isPlaying THEN StopPlay END;
        done := TRUE
      ELSIF (ev.key = "s") OR (ev.key = "S") THEN
        IF isPlaying THEN StopPlay
        ELSE statusMsg := 'Nothing is playing.' END
      ELSIF ev.key = TUI.KTab THEN
        IF focusMode = MODE_SEARCH THEN
          IF stCount > 0 THEN focusMode := MODE_RESULTS
          ELSE statusMsg := 'Search for stations first.' END
        ELSE
          focusMode := MODE_SEARCH
        END
      ELSIF focusMode = MODE_SEARCH THEN
        IF ev.key = TUI.KEnter THEN
          Search
        ELSIF (ev.key = TUI.KBackspace) OR (ORD(ev.key) = 127) THEN
          IF searchLen > 0 THEN DEC(searchLen); searchBuf[searchLen] := 0X END
        ELSIF (ORD(ev.key) >= 32) & (ORD(ev.key) < 127) THEN
          IF searchLen < LEN(searchBuf) - 1 THEN
            searchBuf[searchLen] := ev.key;
            INC(searchLen);
            searchBuf[searchLen] := 0X
          END
        END
      ELSE (* MODE_RESULTS *)
        IF ev.key = TUI.KEnter THEN
          IF stCount > 0 THEN Play(selIdx) END
        ELSIF ev.key = TUI.KUp THEN
          IF selIdx > 0 THEN DEC(selIdx) END;
          IF selIdx < scrollOff THEN scrollOff := selIdx END
        ELSIF ev.key = TUI.KDown THEN
          IF selIdx < stCount - 1 THEN INC(selIdx) END;
          IF selIdx >= scrollOff + (TUI.Rows - 6) THEN INC(scrollOff) END
        ELSIF (ORD(ev.key) >= 32) & (ORD(ev.key) < 127) THEN
          (* Typing while in list: switch back to search input *)
          focusMode := MODE_SEARCH;
          IF searchLen < LEN(searchBuf) - 1 THEN
            searchBuf[searchLen] := ev.key;
            INC(searchLen);
            searchBuf[searchLen] := 0X
          END
        END
      END
    ELSIF ev.kind = TUI.EvResize THEN
      TUI.UpdateSize; TUI.InvalidateFront
    END
  UNTIL done;

  TUI.Done
END Radio.
