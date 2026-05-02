MODULE Chatbot;
(*
 * Generic keyword-driven chatbot.
 * Loads personality, keywords, and responses from a config file.
 *
 * Config file format:
 *   # comment
 *   [name]        - bot display name (one line)
 *   [greeting]    - opening message (one line)
 *   [prompt]      - per-reply prefix, e.g. "Bot> " (one line, no trailing space needed)
 *   [farewell]    - message printed on quit (one line)
 *   [quit]        - one quit keyword per line (substring-matched)
 *   [random]      - one fallback response per line
 *   [keywords]    - keyword rules:
 *                     word1|word2 : response text
 *                     + alternative response for the previous rule
 *
 * Usage: chatbot [--talk] [--listen] <config-file>
 *   --talk    speak each bot reply via the system 'say' command
 *   --listen  record speech via sox + whisper instead of keyboard input
 *)

IMPORT Out, Strings, Random, History, Files, Args, OS;

CONST
  MAXRULES = 200;
  MAXKEYS  = 8;
  MAXALT   = 8;
  KEYLEN   = 64;
  BUFLEN   = 512;
  MAXRAND  = 32;
  MAXQUIT  = 16;

  STTAUDIO = "chatbot_stt.wav";
  STTTXT   = "chatbot_stt.txt";
  STTREC   = "rec -q -t wav chatbot_stt.wav silence 1 0.1 3% 1 1.0 3%";
  STTTRANS = "whisper chatbot_stt.wav --model tiny.en --output-format txt --output-dir . 2>/dev/null";

TYPE
  Rule = RECORD
    keys  : ARRAY MAXKEYS OF ARRAY KEYLEN OF CHAR;
    nkeys : INTEGER;
    resp  : ARRAY MAXALT OF ARRAY BUFLEN OF CHAR;
    nresp : INTEGER
  END;

VAR
  rules      : ARRAY MAXRULES OF Rule;
  nrules     : INTEGER;
  randResp   : ARRAY MAXRAND OF ARRAY BUFLEN OF CHAR;
  nrand      : INTEGER;
  quitKeys   : ARRAY MAXQUIT OF ARRAY KEYLEN OF CHAR;
  nquit      : INTEGER;
  botName    : ARRAY BUFLEN OF CHAR;
  greeting   : ARRAY BUFLEN OF CHAR;
  farewell   : ARRAY BUFLEN OF CHAR;
  prompt     : ARRAY BUFLEN OF CHAR;
  input      : ARRAY BUFLEN OF CHAR;
  configFile : ARRAY BUFLEN OF CHAR;
  arg        : ARRAY BUFLEN OF CHAR;
  talkMode   : BOOLEAN;
  listenMode : BOOLEAN;
  done       : BOOLEAN;

PROCEDURE StripCR(VAR s : ARRAY OF CHAR);
VAR n : INTEGER;
BEGIN
  n := Strings.Length(s);
  IF (n > 0) & (s[n-1] = 0DX) THEN s[n-1] := 0X END
END StripCR;

PROCEDURE ParseKeys(keysPart : ARRAY OF CHAR; VAR r : Rule);
VAR
  i, j, len : INTEGER;
  key : ARRAY KEYLEN OF CHAR;
BEGIN
  r.nkeys := 0;
  i := 0; j := 0;
  len := Strings.Length(keysPart);
  WHILE i <= len DO
    IF (keysPart[i] = '|') OR (keysPart[i] = 0X) THEN
      key[j] := 0X;
      Strings.Trim(key);
      Strings.ToLower(key);
      IF (Strings.Length(key) > 0) & (r.nkeys < MAXKEYS) THEN
        COPY(key, r.keys[r.nkeys]);
        INC(r.nkeys)
      END;
      j := 0
    ELSE
      IF j < KEYLEN - 1 THEN key[j] := keysPart[i]; INC(j) END
    END;
    INC(i)
  END
END ParseKeys;

PROCEDURE LoadConfig(fname : ARRAY OF CHAR) : BOOLEAN;
VAR
  f          : Files.File;
  r          : Files.Rider;
  line       : ARRAY BUFLEN OF CHAR;
  sect       : INTEGER;
  colon, len : INTEGER;
  keysPart   : ARRAY BUFLEN OF CHAR;
  respPart   : ARRAY BUFLEN OF CHAR;
BEGIN
  f := Files.Old(fname);
  IF f = NIL THEN RETURN FALSE END;
  Files.Set(r, f, 0);
  sect := 0;

  Files.ReadLine(r, line);
  WHILE ~r.eof DO
    StripCR(line);
    Strings.Trim(line);
    len := Strings.Length(line);

    IF (len = 0) OR (line[0] = '#') THEN
      (* skip blank lines and comments *)
    ELSIF Strings.Compare(line, "[name]") = 0 THEN      sect := 1
    ELSIF Strings.Compare(line, "[greeting]") = 0 THEN  sect := 2
    ELSIF Strings.Compare(line, "[farewell]") = 0 THEN  sect := 3
    ELSIF Strings.Compare(line, "[prompt]") = 0 THEN    sect := 4
    ELSIF Strings.Compare(line, "[quit]") = 0 THEN      sect := 5
    ELSIF Strings.Compare(line, "[random]") = 0 THEN    sect := 6
    ELSIF Strings.Compare(line, "[keywords]") = 0 THEN  sect := 7
    ELSIF sect = 1 THEN
      COPY(line, botName)
    ELSIF sect = 2 THEN
      COPY(line, greeting)
    ELSIF sect = 3 THEN
      COPY(line, farewell)
    ELSIF sect = 4 THEN
      COPY(line, prompt)
    ELSIF sect = 5 THEN
      IF nquit < MAXQUIT THEN
        Strings.ToLower(line);
        COPY(line, quitKeys[nquit]);
        INC(nquit)
      END
    ELSIF sect = 6 THEN
      IF nrand < MAXRAND THEN
        COPY(line, randResp[nrand]);
        INC(nrand)
      END
    ELSIF sect = 7 THEN
      IF (line[0] = '+') & (nrules > 0) THEN
        Strings.Extract(line, 1, len - 1, respPart);
        Strings.Trim(respPart);
        IF (Strings.Length(respPart) > 0) &
           (rules[nrules-1].nresp < MAXALT) THEN
          COPY(respPart, rules[nrules-1].resp[rules[nrules-1].nresp]);
          INC(rules[nrules-1].nresp)
        END
      ELSE
        colon := Strings.Pos(":", line);
        IF (colon > 0) & (nrules < MAXRULES) THEN
          Strings.Extract(line, 0, colon, keysPart);
          Strings.Trim(keysPart);
          Strings.Extract(line, colon + 1, len - colon - 1, respPart);
          Strings.Trim(respPart);
          IF (Strings.Length(keysPart) > 0) & (Strings.Length(respPart) > 0) THEN
            rules[nrules].nresp := 1;
            COPY(respPart, rules[nrules].resp[0]);
            ParseKeys(keysPart, rules[nrules]);
            IF rules[nrules].nkeys > 0 THEN INC(nrules) END
          END
        END
      END
    END;

    Files.ReadLine(r, line)
  END;

  Files.Close(f);
  RETURN TRUE
END LoadConfig;

PROCEDURE Say(text : ARRAY OF CHAR);
VAR
  cmd  : ARRAY 1024 OF CHAR;
  i, j, n : INTEGER;
  c    : CHAR;
  res  : INTEGER;
BEGIN
  COPY("say '", cmd);
  j := Strings.Length(cmd);
  n := Strings.Length(text);
  i := 0;
  WHILE i < n DO
    c := text[i];
    IF c = "'" THEN
      cmd[j] := "'";  INC(j);
      cmd[j] := "\"; INC(j);
      cmd[j] := "'";  INC(j);
      cmd[j] := "'";  INC(j)
    ELSE
      cmd[j] := c;  INC(j)
    END;
    INC(i)
  END;
  cmd[j] := "'";  INC(j);
  cmd[j] := 0X;
  res := OS.Exec(cmd)
END Say;

PROCEDURE Listen(VAR inp : ARRAY OF CHAR);
VAR
  f  : Files.File;
  r  : Files.Rider;
  ch : CHAR;
  n  : INTEGER;
BEGIN
  inp[0] := 0X;
  Out.String("  (listening...)"); Out.Ln;
  IF OS.Exec(STTREC) = 0 THEN
    IF OS.Exec(STTTRANS) = 0 THEN
      f := Files.Old(STTTXT);
      IF f # NIL THEN
        Files.Set(r, f, 0);
        n := 0;
        WHILE ~r.eof & (n < LEN(inp) - 1) DO
          Files.Read(r, ch);
          IF ~r.eof THEN
            IF (ch = 0AX) OR (ch = 0DX) THEN
              n := LEN(inp)   (* stop at first newline *)
            ELSE
              inp[n] := ch;  INC(n)
            END
          END
        END;
        IF n < LEN(inp) THEN inp[n] := 0X END;
        Files.Close(f);
        Strings.Trim(inp)
      END
    ELSE
      Out.String("  (transcription failed - is whisper installed?)"); Out.Ln
    END
  ELSE
    Out.String("  (recording failed - is sox installed?)"); Out.Ln
  END
END Listen;

PROCEDURE Reply;
VAR
  i, j    : INTEGER;
  matched : BOOLEAN;
  norm    : ARRAY BUFLEN OF CHAR;
  resp    : ARRAY BUFLEN OF CHAR;
BEGIN
  COPY(input, norm);
  Strings.ToLower(norm);

  i := 0;
  WHILE i < nquit DO
    IF Strings.Pos(quitKeys[i], norm) # -1 THEN
      IF farewell[0] # 0X THEN COPY(farewell, resp)
      ELSE COPY("Goodbye!", resp) END;
      Out.String(prompt); Out.Char(' '); Out.String(resp); Out.Ln;
      IF talkMode THEN Say(resp) END;
      done := TRUE;
      RETURN
    END;
    INC(i)
  END;

  matched := FALSE;
  i := 0;
  WHILE (i < nrules) & ~matched DO
    j := 0;
    WHILE (j < rules[i].nkeys) & ~matched DO
      IF Strings.Pos(rules[i].keys[j], norm) # -1 THEN
        IF rules[i].nresp = 1 THEN
          COPY(rules[i].resp[0], resp)
        ELSE
          COPY(rules[i].resp[Random.Int(rules[i].nresp)], resp)
        END;
        matched := TRUE
      END;
      INC(j)
    END;
    INC(i)
  END;

  IF ~matched THEN
    IF nrand > 0 THEN
      COPY(randResp[Random.Int(nrand)], resp)
    ELSE
      COPY("I see. Tell me more.", resp)
    END
  END;

  Out.String(prompt); Out.Char(' '); Out.String(resp); Out.Ln;
  IF talkMode THEN Say(resp) END
END Reply;

VAR i : INTEGER;

BEGIN
  nrules := 0; nrand := 0; nquit := 0;
  botName[0] := 0X; greeting[0] := 0X; farewell[0] := 0X;
  COPY("Bot>", prompt);
  configFile[0] := 0X;
  talkMode   := FALSE;
  listenMode := FALSE;
  done       := FALSE;

  i := 1;
  WHILE i <= Args.Count() DO
    Args.Get(i, arg);
    IF Strings.Compare(arg, "--talk") = 0 THEN
      talkMode := TRUE
    ELSIF Strings.Compare(arg, "--listen") = 0 THEN
      listenMode := TRUE
    ELSIF configFile[0] = 0X THEN
      COPY(arg, configFile)
    END;
    INC(i)
  END;

  IF configFile[0] = 0X THEN
    Out.String("Usage: chatbot [--talk] [--listen] <config-file>"); Out.Ln
  ELSIF ~LoadConfig(configFile) THEN
    Out.String("Error: cannot open '");
    Out.String(configFile);
    Out.String("'"); Out.Ln
  ELSE
    IF botName[0] # 0X THEN
      Out.String("--- "); Out.String(botName); Out.String(" ---"); Out.Ln
    END;
    IF listenMode THEN
      Out.String("(say a quit keyword to exit)"); Out.Ln
    ELSE
      Out.String("(type a quit keyword to exit)"); Out.Ln
    END;
    Out.Ln;
    IF greeting[0] # 0X THEN
      Out.String(prompt); Out.Char(' ');
      Out.String(greeting); Out.Ln;
      IF talkMode THEN Say(greeting) END
    END;

    REPEAT
      IF listenMode THEN
        Listen(input);
        IF input[0] # 0X THEN
          Out.String("You: "); Out.String(input); Out.Ln
        END
      ELSE
        History.ReadLine("You: ", input)
      END;
      Strings.Trim(input);
      IF input[0] # 0X THEN Reply END
    UNTIL done
  END
END Chatbot.
