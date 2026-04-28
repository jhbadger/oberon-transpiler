MODULE OllamaChat;
(*
 * OllamaChat — interactive chat client for a local Ollama server.
 *
 * Usage: ./ollamachat [model]
 *   model defaults to "gemma4:e4b" if not specified.
 *
 * Requires Ollama running at http://localhost:11434 and curl on PATH.
 * Type a message and press Enter.  Empty line or "quit" exits.
 *)

IMPORT Out, Args, Strings, History, Ollama;

CONST
  Host = 'http://localhost:11434';

VAR
  model    : ARRAY 64 OF CHAR;
  input    : ARRAY 1024 OF CHAR;
  response : ARRAY 32768 OF CHAR;
  models   : ARRAY 1024 OF CHAR;

BEGIN
  IF Args.Count() >= 1 THEN
    Args.Get(1, model)
  ELSE
    model := "gemma4:e4b"
  END;

  Out.String("Ollama Chat  [model: "); Out.String(model); Out.String("]"); Out.Ln;
  IF Ollama.Models(Host, models) THEN
    Out.String("Available: "); Out.String(models); Out.Ln
  END;
  Out.String("Type your message, or empty line / 'quit' to exit."); Out.Ln;
  Out.Ln;

  REPEAT
    History.ReadLine("> ", input);
    Strings.Trim(input);
    IF (input # "") & (input # "quit") THEN
      Out.String("[thinking...]"); Out.Ln;
      IF Ollama.Chat(Host, model, input, response) THEN
        Out.Ln;
        Out.String(response); Out.Ln; Out.Ln
      ELSE
        Out.String("[Error: could not reach Ollama at "); Out.String(Host);
        Out.String("]"); Out.Ln
      END
    END
  UNTIL (input = "") OR (input = "quit");

  Out.Ln; Out.String("Goodbye."); Out.Ln
END OllamaChat.

