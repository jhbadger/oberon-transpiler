MODULE ZapfTok;
(*
  ZapfTok — lexer for ZAP assembly source, ported from Zapf.Parsing.Tokenizer (C#).

  Reads one file at a time; .INSERT file-splicing is handled by the caller
  (ZapfParser), which opens a fresh Tokenizer per file and stitches the
  resulting line lists together.

  On a lexical error (bad character, unterminated string) NextToken sets
  err TRUE and errMsg to the message; the token returned in that case is
  meaningless and must not be used.  This mirrors the original's
  `throw Errors.MakeSerious(...)` from within NextToken/PeekToken, which
  propagates out of ZapParser.Parse entirely (no per-line recovery for
  lexical errors, only for grammar errors reported by the parser itself).
*)

IMPORT Files, Strings;

CONST
  (* token kinds *)
  TkEquals* = 0;
  TkComma* = 1;
  TkSlash* = 2;
  TkBackslash* = 3;
  TkRAngle* = 4;
  TkPlus* = 5;
  TkApostrophe* = 6;
  TkColon* = 7;
  TkDColon* = 8;
  TkNumber* = 9;
  TkSymbol* = 10;
  TkString* = 11;
  TkEndOfLine* = 12;
  TkEndOfFile* = 13;

  NoChar = -1;

TYPE
  Token* = RECORD
    kind*: INTEGER;
    text*: ARRAY 1024 OF CHAR;
    line*: INTEGER;
    filename*: ARRAY 256 OF CHAR
  END;

  Tokenizer* = POINTER TO TokenizerDesc;
  TokenizerDesc* = RECORD
    f: Files.File;
    r: Files.Rider;
    filename: ARRAY 256 OF CHAR;
    line: INTEGER;
    heldChar: INTEGER;
    haveHeldChar: BOOLEAN;
    heldTok: Token;
    haveHeldTok: BOOLEAN;
    err*: BOOLEAN;
    errMsg*: ARRAY 256 OF CHAR;
    errLine*: INTEGER
  END;

PROCEDURE Open*(VAR t: Tokenizer; filename: ARRAY OF CHAR): BOOLEAN;
BEGIN
  NEW(t);
  t.f := Files.Old(filename);
  IF t.f = NIL THEN RETURN FALSE END;
  Files.Set(t.r, t.f, 0);
  Strings.Copy(filename, t.filename);
  t.line := 1;
  t.haveHeldChar := FALSE;
  t.haveHeldTok := FALSE;
  t.err := FALSE;
  t.errMsg[0] := 0X;
  RETURN TRUE
END Open;

PROCEDURE Close*(VAR t: Tokenizer);
BEGIN
  IF t.f # NIL THEN Files.Close(t.f); t.f := NIL END
END Close;

PROCEDURE SetErr(t: Tokenizer; msg: ARRAY OF CHAR);
BEGIN
  t.err := TRUE;
  Strings.Copy(msg, t.errMsg);
  t.errLine := t.line
END SetErr;

PROCEDURE NextChar(t: Tokenizer): INTEGER;
VAR b: BYTE; c: INTEGER;
BEGIN
  IF t.haveHeldChar THEN
    c := t.heldChar;
    t.haveHeldChar := FALSE;
    RETURN c
  END;
  IF t.r.eof THEN RETURN NoChar END;
  Files.Read(t.r, b);
  IF t.r.eof THEN RETURN NoChar END;
  RETURN ORD(b)
END NextChar;

PROCEDURE PeekChar(t: Tokenizer): INTEGER;
BEGIN
  IF ~t.haveHeldChar THEN
    t.heldChar := NextChar(t);
    t.haveHeldChar := TRUE
  END;
  RETURN t.heldChar
END PeekChar;

PROCEDURE IsSpace(c: INTEGER): BOOLEAN;
BEGIN
  RETURN (c = 32) OR (c = 9) OR (c = 13) OR (c = 10) OR (c = 11) OR (c = 12)
END IsSpace;

PROCEDURE IsDigit(c: INTEGER): BOOLEAN;
BEGIN RETURN (c >= 48) & (c <= 57) END IsDigit;

PROCEDURE IsLetter(c: INTEGER): BOOLEAN;
BEGIN
  RETURN ((c >= 65) & (c <= 90)) OR ((c >= 97) & (c <= 122))
END IsLetter;

PROCEDURE CanStartSymbol(c: INTEGER): BOOLEAN;
BEGIN
  RETURN (c = ORD("-")) OR (c = ORD("?")) OR (c = ORD("$")) OR (c = ORD("#"))
       OR (c = ORD("&")) OR (c = ORD(".")) OR (c = ORD("%")) OR (c = ORD("!"))
       OR IsLetter(c) OR IsDigit(c)
END CanStartSymbol;

PROCEDURE CanContinueSymbol(c: INTEGER): BOOLEAN;
BEGIN
  RETURN (c = ORD("'")) OR (c = ORD("/")) OR CanStartSymbol(c)
END CanContinueSymbol;

PROCEDURE ReadSymbolOrNum(t: Tokenizer; VAR result: Token);
VAR buf: ARRAY 1024 OF CHAR; n, digits, c: INTEGER; allDigits: BOOLEAN;
BEGIN
  n := 0; digits := 0;
  c := PeekChar(t);
  WHILE (c # NoChar) & CanContinueSymbol(c) DO
    IF IsDigit(c) THEN INC(digits) END;
    IF n < LEN(buf) - 1 THEN buf[n] := CHR(c); INC(n) END;
    c := NextChar(t);
    c := PeekChar(t)
  END;
  buf[n] := 0X;
  Strings.Copy(buf, result.text);

  allDigits := (n = digits) OR ((n = digits + 1) & (n > 0) & (buf[0] = "-"));
  IF allDigits & (n > 0) THEN
    result.kind := TkNumber
  ELSE
    result.kind := TkSymbol
  END
END ReadSymbolOrNum;

PROCEDURE ReadString(t: Tokenizer; VAR result: Token);
VAR buf: ARRAY 1024 OF CHAR; n, c: INTEGER; done: BOOLEAN;
BEGIN
  n := 0;
  c := NextChar(t); (* skip opening quote *)
  done := FALSE;
  WHILE ~done DO
    c := NextChar(t);
    IF c = NoChar THEN
      SetErr(t, "unterminated string");
      done := TRUE
    ELSIF c = ORD('"') THEN
      IF PeekChar(t) = ORD('"') THEN
        c := NextChar(t);
        IF n < LEN(buf) - 1 THEN buf[n] := '"'; INC(n) END
      ELSE
        buf[n] := 0X;
        Strings.Copy(buf, result.text);
        result.kind := TkString;
        done := TRUE
      END
    ELSIF c = 13 THEN
      (* ignore CR *)
    ELSE
      IF c = 10 THEN INC(t.line) END;
      IF n < LEN(buf) - 1 THEN buf[n] := CHR(c); INC(n) END
    END
  END
END ReadString;

PROCEDURE NextTokenRaw(t: Tokenizer; VAR result: Token): Token;
VAR c: INTEGER;
BEGIN
  result.filename := t.filename;
  result.line := t.line;
  result.text[0] := 0X;

  c := PeekChar(t);
  WHILE (c # NoChar) & IsSpace(c) DO
    c := NextChar(t);
    IF c = 10 THEN
      INC(t.line);
      result.kind := TkEndOfLine;
      RETURN result
    END;
    c := PeekChar(t)
  END;

  IF c = NoChar THEN
    result.kind := TkEndOfFile
  ELSIF c = ORD(":") THEN
    c := NextChar(t);
    IF PeekChar(t) = ORD(":") THEN
      c := NextChar(t);
      result.kind := TkDColon
    ELSE
      result.kind := TkColon
    END
  ELSIF c = ORD('"') THEN
    ReadString(t, result)
  ELSIF c = ORD(";") THEN
    REPEAT c := NextChar(t) UNTIL (c = NoChar) OR (c = 10);
    INC(t.line);
    IF c = NoChar THEN result.kind := TkEndOfFile ELSE result.kind := TkEndOfLine END
  ELSIF c = ORD("=") THEN c := NextChar(t); result.kind := TkEquals
  ELSIF c = ORD(",") THEN c := NextChar(t); result.kind := TkComma
  ELSIF c = ORD("/") THEN c := NextChar(t); result.kind := TkSlash
  ELSIF c = ORD("\") THEN c := NextChar(t); result.kind := TkBackslash
  ELSIF c = ORD(">") THEN c := NextChar(t); result.kind := TkRAngle
  ELSIF c = ORD("+") THEN c := NextChar(t); result.kind := TkPlus
  ELSIF c = ORD("'") THEN c := NextChar(t); result.kind := TkApostrophe
  ELSIF CanStartSymbol(c) THEN
    ReadSymbolOrNum(t, result)
  ELSE
    SetErr(t, "unexpected character")
  END;
  RETURN result
END NextTokenRaw;

PROCEDURE NextToken*(t: Tokenizer; VAR result: Token);
BEGIN
  IF t.haveHeldTok THEN
    result := t.heldTok;
    t.haveHeldTok := FALSE
  ELSE
    result := NextTokenRaw(t, result)
  END
END NextToken;

PROCEDURE PeekToken*(t: Tokenizer; VAR result: Token);
BEGIN
  IF ~t.haveHeldTok THEN
    t.heldTok := NextTokenRaw(t, t.heldTok);
    t.haveHeldTok := TRUE
  END;
  result := t.heldTok
END PeekToken;

(* Render a token like C#'s Token.ToString() for error messages: *)
(*  {Type=Number, Text="123"}  or  {Type=EndOfLine}                *)
PROCEDURE KindName(kind: INTEGER; VAR s: ARRAY OF CHAR);
BEGIN
  CASE kind OF
    TkEquals: Strings.Copy("Equals", s)
   |TkComma: Strings.Copy("Comma", s)
   |TkSlash: Strings.Copy("Slash", s)
   |TkBackslash: Strings.Copy("Backslash", s)
   |TkRAngle: Strings.Copy("RAngle", s)
   |TkPlus: Strings.Copy("Plus", s)
   |TkApostrophe: Strings.Copy("Apostrophe", s)
   |TkColon: Strings.Copy("Colon", s)
   |TkDColon: Strings.Copy("DColon", s)
   |TkNumber: Strings.Copy("Number", s)
   |TkSymbol: Strings.Copy("Symbol", s)
   |TkString: Strings.Copy("String", s)
   |TkEndOfLine: Strings.Copy("EndOfLine", s)
   |TkEndOfFile: Strings.Copy("EndOfFile", s)
  ELSE
    Strings.Copy("?", s)
  END
END KindName;

PROCEDURE ToString*(tok: Token; VAR s: ARRAY OF CHAR);
VAR kn: ARRAY 16 OF CHAR;
BEGIN
  KindName(tok.kind, kn);
  Strings.Copy("{Type=", s);
  Strings.Append(kn, s);
  IF (tok.kind = TkNumber) OR (tok.kind = TkSymbol) OR (tok.kind = TkString) THEN
    Strings.Append(', Text="', s);
    Strings.Append(tok.text, s);
    Strings.Append('"', s)
  END;
  Strings.Append("}", s)
END ToString;

END ZapfTok.
