MODULE Ollama;
(*
 * Ollama — REST client for a local Ollama server.
 *
 * Communicates via the Ollama HTTP API using curl (must be on PATH).
 * Default server: http://localhost:11434
 *
 * Generate : plain text generation  (POST /api/generate)
 * Chat     : single-turn chat       (POST /api/chat)
 * Models   : list available models  (GET  /api/tags)
 *
 * Responses are returned as Oberon strings.  MaxResp sets the ceiling;
 * truncation occurs silently if the server reply exceeds it.
 *)

IMPORT Strings, Files, OS;

CONST
  MaxBody*    = 4096;
  MaxResp*    = 32768;
  DefaultHost* = 'http://localhost:11434';

(* ── Private helpers ─────────────────────────────────────────────────── *)

PROCEDURE EscapeJSON(src: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR);
(* Copy src into dst with minimal JSON string escaping. *)
VAR i, j: INTEGER; c: CHAR;
BEGIN
  i := 0; j := 0;
  WHILE (i < LEN(src)) & (src[i] # 0X) & (j < LEN(dst) - 3) DO
    c := src[i];
    CASE ORD(c) OF
      34: dst[j] := CHR(92); INC(j); dst[j] := CHR(34); INC(j)  (* " → \" *)
    | 92: dst[j] := CHR(92); INC(j); dst[j] := CHR(92); INC(j)  (* \ → \\ *)
    | 10: dst[j] := CHR(92); INC(j); dst[j] := 'n';    INC(j)   (* LF → \n *)
    | 13: dst[j] := CHR(92); INC(j); dst[j] := 'r';    INC(j)   (* CR → \r *)
    |  9: dst[j] := CHR(92); INC(j); dst[j] := 't';    INC(j)   (* TAB → \t *)
    ELSE  dst[j] := c; INC(j)
    END;
    INC(i)
  END;
  dst[j] := 0X
END EscapeJSON;

PROCEDURE ExtractStr(json, key: ARRAY OF CHAR; VAR val: ARRAY OF CHAR): BOOLEAN;
(* Find key (including its trailing colon) in json, return the string value. *)
VAR pos, n: INTEGER; c: CHAR;
BEGIN
  val[0] := 0X;
  pos := Strings.Pos(key, json);
  IF pos = -1 THEN RETURN FALSE END;
  INC(pos, Strings.Length(key));
  WHILE (pos < LEN(json)) & (json[pos] # CHR(34)) & (json[pos] # 0X) DO INC(pos) END;
  IF (pos >= LEN(json)) OR (json[pos] = 0X) THEN RETURN FALSE END;
  INC(pos);  (* step past opening quote *)
  n := 0;
  LOOP
    IF (pos >= LEN(json)) OR (json[pos] = 0X) OR (n >= LEN(val) - 1) THEN EXIT END;
    c := json[pos];
    IF c = CHR(34) THEN          (* closing quote *)
      val[n] := 0X; RETURN TRUE
    ELSIF c = CHR(92) THEN       (* backslash escape *)
      INC(pos);
      IF pos < LEN(json) THEN
        c := json[pos];
        IF    c = 'n' THEN val[n] := CHR(10); INC(n)
        ELSIF c = 'r' THEN val[n] := CHR(13); INC(n)
        ELSIF c = 't' THEN val[n] := CHR( 9); INC(n)
        ELSE               val[n] := c;       INC(n)
        END
      END
    ELSE
      val[n] := c; INC(n)
    END;
    INC(pos)
  END;
  val[n] := 0X;
  RETURN n > 0
END ExtractStr;

PROCEDURE WriteReq(body: ARRAY OF CHAR): BOOLEAN;
VAR f: Files.File; r: Files.Rider;
BEGIN
  f := Files.New('/tmp/obc_ollama_req.json');
  IF f = NIL THEN RETURN FALSE END;
  Files.Set(r, f, 0);
  Files.WriteLine(r, body);
  Files.Close(f);
  RETURN TRUE
END WriteReq;

PROCEDURE ExecCurl(host, path: ARRAY OF CHAR; post: BOOLEAN): BOOLEAN;
VAR cmd: ARRAY 512 OF CHAR;
BEGIN
  IF post THEN cmd := "curl -s -X POST " ELSE cmd := "curl -s " END;
  Strings.Append(host, cmd);
  Strings.Append(path, cmd);
  IF post THEN
    Strings.Append(" -H 'Content-Type: application/json' -d @/tmp/obc_ollama_req.json", cmd)
  END;
  Strings.Append(" -o /tmp/obc_ollama_resp.json", cmd);
  RETURN OS.Exec(cmd) = 0
END ExecCurl;

PROCEDURE ReadResp(VAR buf: ARRAY OF CHAR): BOOLEAN;
(* Read response file byte-by-byte so we respect LEN(buf). *)
VAR f: Files.File; r: Files.Rider; i: INTEGER; b: BYTE;
BEGIN
  buf[0] := 0X;
  f := Files.Old('/tmp/obc_ollama_resp.json');
  IF f = NIL THEN RETURN FALSE END;
  Files.Set(r, f, 0);
  i := 0;
  WHILE ~r.eof & (i < LEN(buf) - 1) DO
    Files.Read(r, b);
    IF ~r.eof THEN buf[i] := CHR(b); INC(i) END
  END;
  buf[i] := 0X;
  Files.Close(f);
  RETURN i > 0
END ReadResp;

(* ── Public API ──────────────────────────────────────────────────────── *)

PROCEDURE Generate*(host, model, prompt: ARRAY OF CHAR; VAR response: ARRAY OF CHAR): BOOLEAN;
(* Send a plain-text prompt to /api/generate and return the model's reply. *)
VAR
  escaped : ARRAY MaxBody OF CHAR;
  body    : ARRAY MaxBody OF CHAR;
  buf     : ARRAY MaxResp OF CHAR;
BEGIN
  response[0] := 0X;
  EscapeJSON(prompt, escaped);
  body := '{"model":"';
  Strings.Append(model,   body);
  Strings.Append('","prompt":"', body);
  Strings.Append(escaped, body);
  Strings.Append('","stream":false}', body);
  RETURN WriteReq(body) & ExecCurl(host, '/api/generate', TRUE)
       & ReadResp(buf)  & ExtractStr(buf, '"response":', response)
END Generate;

PROCEDURE Chat*(host, model, userMsg: ARRAY OF CHAR; VAR response: ARRAY OF CHAR): BOOLEAN;
(* Send a user message to /api/chat and return the assistant's reply. *)
VAR
  escaped : ARRAY MaxBody OF CHAR;
  body    : ARRAY MaxBody OF CHAR;
  buf     : ARRAY MaxResp OF CHAR;
BEGIN
  response[0] := 0X;
  EscapeJSON(userMsg, escaped);
  body := '{"model":"';
  Strings.Append(model,   body);
  Strings.Append('","messages":[{"role":"user","content":"', body);
  Strings.Append(escaped, body);
  Strings.Append('"}],"stream":false}', body);
  RETURN WriteReq(body) & ExecCurl(host, '/v1/chat/completions', TRUE)
       & ReadResp(buf)  & ExtractStr(buf, '"content":', response)
END Chat;

PROCEDURE Models*(host: ARRAY OF CHAR; VAR list: ARRAY OF CHAR): BOOLEAN;
(* Populate list with a comma-separated set of model names from /api/tags. *)
VAR
  buf         : ARRAY MaxResp OF CHAR;
  pos, start  : INTEGER;
  first       : BOOLEAN;
BEGIN
  list[0] := 0X;
  IF ~ExecCurl(host, '/api/tags', FALSE) THEN RETURN FALSE END;
  IF ~ReadResp(buf) THEN RETURN FALSE END;
  pos := 0; first := TRUE;
  LOOP
    pos := Strings.Pos('"name":', buf, pos);
    IF pos = -1 THEN EXIT END;
    INC(pos, 7);
    WHILE (pos < LEN(buf)) & (buf[pos] # CHR(34)) & (buf[pos] # 0X) DO INC(pos) END;
    IF (pos >= LEN(buf)) OR (buf[pos] = 0X) THEN EXIT END;
    INC(pos);  (* step past opening quote *)
    IF ~first THEN Strings.Append(", ", list) END;
    first := FALSE;
    start := Strings.Length(list);
    WHILE (pos < LEN(buf)) & (buf[pos] # CHR(34)) & (buf[pos] # 0X)
        & (start < LEN(list) - 1) DO
      list[start] := buf[pos]; INC(start); INC(pos)
    END;
    list[start] := 0X
  END;
  RETURN ~first
END Models;

END Ollama.

