MODULE obemacs;
(*
   obemacs - a small Emacs-style editor written in Oberon.

   Implements the core commands taught by the GNU Emacs TUTORIAL:

     Movement:   C-f C-b C-n C-p  M-f M-b  C-a C-e  M-a M-e
                 M-<  M->  arrows  C-v  M-v  C-l
                 C-u <n> <cmd>  (numeric prefix repeat count)
     Editing:    self-insert, <Return>, <DEL>, C-d
                 M-<DEL>  M-d  C-k  M-k
                 C-<SPC> set mark, C-w kill region, M-w copy region
                 C-y yank, M-y yank-pop
                 C-/  C-_  C-x u   undo
     Files:      C-x C-f find-file, C-x C-s save-buffer,
                 C-x s save-some-buffers
     Buffers:    C-x b switch-buffer, C-x C-b list-buffers
     Windows:    C-x 1 only-window, C-x 2 split-window,
                 C-x o other-window
     Search:     C-s isearch-forward, C-r isearch-backward
     Misc:       C-g keyboard-quit, C-x C-c save-buffers-kill-emacs
                 M-x execute-extended-command

   Syntax highlighting is selected by the buffer's file extension:
     .mod .obn .oberon         -> Oberon
     .rb                       -> Ruby
     .r .R                     -> R
*)

  IMPORT Terminal, Editor, Strings, Files, Args, Out;

  CONST
    MaxBuffers   = 32;
    MaxKillRing  = 32;
    MaxStr       = 256;

    (* Special keys -- ASCII codes for control characters. *)
    KCtrlA = 01X; KCtrlB = 02X; KCtrlC = 03X; KCtrlD = 04X;
    KCtrlE = 05X; KCtrlF = 06X; KCtrlG = 07X; KBackspace = 08X;
    KTab   = 09X; KCtrlK = 0BX; KCtrlL = 0CX; KEnter = 0DX;
    KCtrlN = 0EX; KCtrlO = 0FX; KCtrlP = 10X; KCtrlQ = 11X;
    KCtrlR = 12X; KCtrlS = 13X; KCtrlU = 15X; KCtrlV = 16X;
    KCtrlW = 17X; KCtrlX = 18X; KCtrlY = 19X; KCtrlSlash = 1FX;
    KEsc   = 1BX; KSpace = 20X; KDel = 7FX;
    KPgUp  = 80X; KPgDn = 81X; KHome = 82X; KEnd = 83X;
    KLeft  = 0A2X;  KRight = 0A3X;
    KUp    = 0A0X;  KDown  = 0A1X; 
    KNul   = 00X;  (* C-SPC / C-@ on many terminals *)

    (* Syntax modes *)
    SynNone   = 0;
    SynOberon = 1;
    SynRuby   = 2;
    SynR      = 3;

    (* ANSI colors used by the highlighter *)
    ColDefault = 7;   (* white   - identifier / default *)
    ColKeyword = 4;   (* blue    - keywords *)
    ColType    = 6;   (* cyan    - types *)
    ColString  = 2;   (* green   - strings *)
    ColComment = 1;   (* red     - comments *)
    ColNumber  = 3;   (* yellow  - numbers *)
    ColConst   = 5;   (* magenta - true/false/nil and friends *)

  TYPE
    Buffer = POINTER TO BufferRec;
    BufferRec = RECORD
      name:    ARRAY 64  OF CHAR;
      file:    ARRAY 256 OF CHAR;
      ed:      Editor.Handle;
      scroll:  INTEGER;          (* first visible line *)
      hasMark: BOOLEAN;
      markPos: INTEGER;
      syntax:  INTEGER;
    END;

    Window = POINTER TO WindowRec;
    WindowRec = RECORD
      buf:    Buffer;
      top:    INTEGER;          (* first screen row (1-based) *)
      height: INTEGER;          (* including mode line *)
      next:   Window;
    END;

  VAR
    buffers:    ARRAY MaxBuffers OF Buffer;
    nBuffers:   INTEGER;
    rootWin:    Window;
    curWin:     Window;
    curBuf:     Buffer;          (* alias for curWin.buf *)

    cols, rows: INTEGER;

    (* Kill ring: a circular list of strings. *)
    killRing:   ARRAY MaxKillRing OF ARRAY 1024 OF CHAR;
    killCount:  INTEGER;
    killHead:   INTEGER;
    yankIndex:  INTEGER;
    lastWasYank: BOOLEAN;
    lastWasKill: BOOLEAN;

    echoMsg:    ARRAY MaxStr OF CHAR;
    quitFlag:   BOOLEAN;
    prefixArg:  INTEGER;

    (* Cross-line highlighter state used while painting one window. *)
    inBlockComment: BOOLEAN;  (* Oberon  (* ... *)  spans lines *)
    blockDepth:     INTEGER;

  (* ===================================================================
     small helpers
     =================================================================== *)

  PROCEDURE Min(a, b: INTEGER): INTEGER;
  BEGIN
    IF a < b THEN RETURN a ELSE RETURN b END
  END Min;

  PROCEDURE Max(a, b: INTEGER): INTEGER;
  BEGIN
    IF a > b THEN RETURN a ELSE RETURN b END
  END Max;

  PROCEDURE SetEcho(s: ARRAY OF CHAR);
  BEGIN Strings.Copy(s, echoMsg)
  END SetEcho;

  PROCEDURE ClearEcho;
  BEGIN echoMsg[0] := 0X
  END ClearEcho;

  PROCEDURE IntToStr(n: INTEGER; VAR s: ARRAY OF CHAR);
  BEGIN Strings.IntToStr(n, s)
  END IntToStr;

  PROCEDURE EndsWithAny(s: ARRAY OF CHAR; a, b, c: ARRAY OF CHAR): BOOLEAN;
  BEGIN
    RETURN Strings.EndsWith(s, a)
        OR Strings.EndsWith(s, b)
        OR Strings.EndsWith(s, c)
  END EndsWithAny;

  PROCEDURE DetectSyntax(path: ARRAY OF CHAR): INTEGER;
  BEGIN
    IF EndsWithAny(path, ".mod", ".obn", ".oberon") THEN RETURN SynOberon END;
    IF Strings.EndsWith(path, ".rb") THEN RETURN SynRuby END;
    IF Strings.EndsWith(path, ".r") OR Strings.EndsWith(path, ".R") THEN
      RETURN SynR
    END;
    RETURN SynNone
  END DetectSyntax;

  (* ===================================================================
     buffer management
     =================================================================== *)

  PROCEDURE NewBuffer(name: ARRAY OF CHAR): Buffer;
    VAR b: Buffer;
  BEGIN
    NEW(b);
    Strings.Copy(name, b.name);
    b.file[0] := 0X;
    b.ed := Editor.New();
    b.scroll := 1;
    b.hasMark := FALSE;
    b.markPos := 0;
    b.syntax  := SynNone;
    IF nBuffers < MaxBuffers THEN
      buffers[nBuffers] := b; INC(nBuffers)
    END;
    RETURN b
  END NewBuffer;

  PROCEDURE FindBuffer(name: ARRAY OF CHAR): Buffer;
    VAR i: INTEGER;
  BEGIN
    i := 0;
    WHILE i < nBuffers DO
      IF Strings.Compare(buffers[i].name, name) = 0 THEN RETURN buffers[i] END;
      INC(i)
    END;
    RETURN NIL
  END FindBuffer;

  PROCEDURE BaseName(path: ARRAY OF CHAR; VAR name: ARRAY OF CHAR);
    VAR i, last, j: INTEGER;
  BEGIN
    last := -1; i := 0;
    WHILE path[i] # 0X DO
      IF (path[i] = "/") OR (path[i] = "\") THEN last := i END;
      INC(i)
    END;
    i := last + 1;
    j := 0;
    WHILE path[i] # 0X DO name[j] := path[i]; INC(i); INC(j) END;
    name[j] := 0X;
    IF j = 0 THEN Strings.Copy("untitled", name) END
  END BaseName;

  (* ===================================================================
     window management
     =================================================================== *)

  PROCEDURE LayoutWindows;
    VAR w: Window; n, used, share, top: INTEGER;
  BEGIN
    n := 0; w := rootWin;
    WHILE w # NIL DO INC(n); w := w.next END;
    IF n = 0 THEN RETURN END;
    used := rows - 1;             (* reserve row `rows` for echo area *)
    share := used DIV n;
    IF share < 3 THEN share := 3 END;
    top := 1;
    w := rootWin;
    WHILE w # NIL DO
      w.top := top;
      IF w.next = NIL THEN w.height := used - (top - 1)
      ELSE w.height := share END;
      IF w.height < 3 THEN w.height := 3 END;
      top := top + w.height;
      w := w.next
    END
  END LayoutWindows;

  PROCEDURE OnlyWindow;
  BEGIN
    rootWin := curWin;
    curWin.next := NIL;
    LayoutWindows
  END OnlyWindow;

  PROCEDURE SplitWindow;
    VAR nw: Window;
  BEGIN
    NEW(nw);
    nw.buf  := curWin.buf;
    nw.next := curWin.next;
    curWin.next := nw;
    LayoutWindows
  END SplitWindow;

  PROCEDURE OtherWindow;
  BEGIN
    IF curWin.next # NIL THEN curWin := curWin.next
    ELSE curWin := rootWin END;
    curBuf := curWin.buf
  END OtherWindow;

  PROCEDURE ShowBuffer(b: Buffer);
  BEGIN
    curWin.buf := b;
    curBuf := b
  END ShowBuffer;

  PROCEDURE TextHeight(w: Window): INTEGER;
  BEGIN RETURN w.height - 1
  END TextHeight;

  PROCEDURE EnsureCursorVisible(w: Window);
    VAR ln, h: INTEGER;
  BEGIN
    ln := Editor.CursorLine(w.buf.ed);
    h  := TextHeight(w);
    IF ln < w.buf.scroll THEN w.buf.scroll := ln END;
    IF ln >= w.buf.scroll + h THEN w.buf.scroll := ln - h + 1 END;
    IF w.buf.scroll < 1 THEN w.buf.scroll := 1 END
  END EnsureCursorVisible;

  (* ===================================================================
     syntax highlighting
     =================================================================== *)

  PROCEDURE IsAlpha(c: CHAR): BOOLEAN;
  BEGIN RETURN ((c >= "a") & (c <= "z")) OR ((c >= "A") & (c <= "Z")) OR (c = "_")
  END IsAlpha;

  PROCEDURE IsDigit(c: CHAR): BOOLEAN;
  BEGIN RETURN (c >= "0") & (c <= "9")
  END IsDigit;

  PROCEDURE IsIdent(c: CHAR): BOOLEAN;
  BEGIN RETURN IsAlpha(c) OR IsDigit(c)
  END IsIdent;

  PROCEDURE StrEq(VAR s: ARRAY OF CHAR; lit: ARRAY OF CHAR): BOOLEAN;
    VAR i: INTEGER;
  BEGIN
    i := 0;
    WHILE (s[i] # 0X) & (lit[i] # 0X) & (s[i] = lit[i]) DO INC(i) END;
    RETURN (s[i] = 0X) & (lit[i] = 0X)
  END StrEq;

  PROCEDURE OberonKeyword(VAR w: ARRAY OF CHAR): INTEGER;
    (* returns ColKeyword, ColType, ColConst, or -1 *)
  BEGIN
    IF StrEq(w, "MODULE")    OR StrEq(w, "IMPORT")    OR StrEq(w, "CONST")
    OR StrEq(w, "TYPE")      OR StrEq(w, "VAR")       OR StrEq(w, "PROCEDURE")
    OR StrEq(w, "BEGIN")     OR StrEq(w, "END")       OR StrEq(w, "RETURN")
    OR StrEq(w, "IF")        OR StrEq(w, "THEN")      OR StrEq(w, "ELSIF")
    OR StrEq(w, "ELSE")      OR StrEq(w, "WHILE")     OR StrEq(w, "DO")
    OR StrEq(w, "REPEAT")    OR StrEq(w, "UNTIL")     OR StrEq(w, "FOR")
    OR StrEq(w, "TO")        OR StrEq(w, "BY")        OR StrEq(w, "LOOP")
    OR StrEq(w, "EXIT")      OR StrEq(w, "CASE")      OR StrEq(w, "OF")
    OR StrEq(w, "WITH")      OR StrEq(w, "ARRAY")     OR StrEq(w, "RECORD")
    OR StrEq(w, "POINTER")   OR StrEq(w, "DIV")       OR StrEq(w, "MOD")
    OR StrEq(w, "OR")        OR StrEq(w, "IN")        OR StrEq(w, "IS")
    OR StrEq(w, "NEW")       OR StrEq(w, "FREE")      OR StrEq(w, "HALT")
    OR StrEq(w, "ASSERT")
    THEN RETURN ColKeyword END;
    IF StrEq(w, "INTEGER")   OR StrEq(w, "LONGINT")   OR StrEq(w, "SHORTINT")
    OR StrEq(w, "REAL")      OR StrEq(w, "LONGREAL")  OR StrEq(w, "BOOLEAN")
    OR StrEq(w, "CHAR")      OR StrEq(w, "BYTE")      OR StrEq(w, "SET")
    OR StrEq(w, "STRING")
    THEN RETURN ColType END;
    IF StrEq(w, "TRUE") OR StrEq(w, "FALSE") OR StrEq(w, "NIL")
    THEN RETURN ColConst END;
    RETURN -1
  END OberonKeyword;

  PROCEDURE RubyKeyword(VAR w: ARRAY OF CHAR): INTEGER;
  BEGIN
    IF StrEq(w, "def")    OR StrEq(w, "end")    OR StrEq(w, "if")
    OR StrEq(w, "elsif")  OR StrEq(w, "else")   OR StrEq(w, "unless")
    OR StrEq(w, "while")  OR StrEq(w, "until")  OR StrEq(w, "for")
    OR StrEq(w, "in")     OR StrEq(w, "do")     OR StrEq(w, "begin")
    OR StrEq(w, "rescue") OR StrEq(w, "ensure") OR StrEq(w, "raise")
    OR StrEq(w, "return") OR StrEq(w, "yield")  OR StrEq(w, "break")
    OR StrEq(w, "next")   OR StrEq(w, "redo")   OR StrEq(w, "retry")
    OR StrEq(w, "class")  OR StrEq(w, "module") OR StrEq(w, "require")
    OR StrEq(w, "require_relative") OR StrEq(w, "include")
    OR StrEq(w, "extend") OR StrEq(w, "attr_accessor")
    OR StrEq(w, "attr_reader") OR StrEq(w, "attr_writer")
    OR StrEq(w, "case")   OR StrEq(w, "when")   OR StrEq(w, "then")
    OR StrEq(w, "and")    OR StrEq(w, "or")     OR StrEq(w, "not")
    OR StrEq(w, "lambda") OR StrEq(w, "proc")   OR StrEq(w, "puts")
    OR StrEq(w, "print")  OR StrEq(w, "p")      OR StrEq(w, "self")
    OR StrEq(w, "super")  OR StrEq(w, "new")
    THEN RETURN ColKeyword END;
    IF StrEq(w, "true") OR StrEq(w, "false") OR StrEq(w, "nil")
    THEN RETURN ColConst END;
    IF StrEq(w, "Integer") OR StrEq(w, "Float")  OR StrEq(w, "String")
    OR StrEq(w, "Array")   OR StrEq(w, "Hash")   OR StrEq(w, "Symbol")
    OR StrEq(w, "Numeric") OR StrEq(w, "Object") OR StrEq(w, "Class")
    OR StrEq(w, "Module")  OR StrEq(w, "Proc")   OR StrEq(w, "Range")
    OR StrEq(w, "Regexp")
    THEN RETURN ColType END;
    RETURN -1
  END RubyKeyword;

  PROCEDURE RKeyword(VAR w: ARRAY OF CHAR): INTEGER;
  BEGIN
    IF StrEq(w, "if")       OR StrEq(w, "else")     OR StrEq(w, "for")
    OR StrEq(w, "while")    OR StrEq(w, "repeat")   OR StrEq(w, "break")
    OR StrEq(w, "next")     OR StrEq(w, "return")   OR StrEq(w, "function")
    OR StrEq(w, "in")       OR StrEq(w, "library")  OR StrEq(w, "require")
    OR StrEq(w, "source")   OR StrEq(w, "stop")     OR StrEq(w, "warning")
    OR StrEq(w, "message")  OR StrEq(w, "tryCatch") OR StrEq(w, "invisible")
    OR StrEq(w, "print")    OR StrEq(w, "cat")      OR StrEq(w, "paste")
    OR StrEq(w, "paste0")
    THEN RETURN ColKeyword END;
    IF StrEq(w, "TRUE")  OR StrEq(w, "FALSE") OR StrEq(w, "NULL")
    OR StrEq(w, "NA")    OR StrEq(w, "NA_integer_") OR StrEq(w, "NA_real_")
    OR StrEq(w, "NA_character_") OR StrEq(w, "Inf") OR StrEq(w, "NaN")
    OR StrEq(w, "T")     OR StrEq(w, "F")
    THEN RETURN ColConst END;
    IF StrEq(w, "numeric")   OR StrEq(w, "integer")  OR StrEq(w, "character")
    OR StrEq(w, "logical")   OR StrEq(w, "complex")  OR StrEq(w, "list")
    OR StrEq(w, "vector")    OR StrEq(w, "matrix")   OR StrEq(w, "array")
    OR StrEq(w, "data.frame") OR StrEq(w, "factor")
    THEN RETURN ColType END;
    RETURN -1
  END RKeyword;

  (* Look up a keyword for the active syntax mode. *)
  PROCEDURE LookupKeyword(syntax: INTEGER; VAR w: ARRAY OF CHAR): INTEGER;
  BEGIN
    CASE syntax OF
      SynOberon: RETURN OberonKeyword(w)
    | SynRuby:   RETURN RubyKeyword(w)
    | SynR:      RETURN RKeyword(w)
    ELSE RETURN -1
    END
  END LookupKeyword;

  (* Emit a single cell at (screenCol+1, row), advancing screenCol.
     Returns FALSE when the screen column would exceed `cols`. *)
  PROCEDURE Emit(VAR screenCol: INTEGER; row: INTEGER; ch: CHAR; color: INTEGER): BOOLEAN;
  BEGIN
    IF screenCol >= cols THEN RETURN FALSE END;
    Terminal.Color(color, 0);
    Terminal.Goto(screenCol + 1, row);
    IF ch = 09X THEN
      REPEAT
        Out.Char(" "); INC(screenCol)
      UNTIL (screenCol MOD 8 = 0) OR (screenCol >= cols)
    ELSIF (ch >= " ") & (ch < 7FX) THEN
      Out.Char(ch); INC(screenCol)
    ELSE
      Out.Char("?"); INC(screenCol)
    END;
    RETURN screenCol < cols
  END Emit;

  PROCEDURE EmitWord(VAR screenCol: INTEGER; row: INTEGER;
                     VAR word: ARRAY OF CHAR; color: INTEGER);
    VAR k: INTEGER; ok: BOOLEAN;
  BEGIN
    k := 0;
    WHILE word[k] # 0X DO
      ok := Emit(screenCol, row, word[k], color);
      IF ~ok THEN RETURN END;
      INC(k)
    END
  END EmitWord;

  (* Render `line` (the full text of one buffer line) to terminal row
     `row`, with syntax highlighting for the active mode. *)
  PROCEDURE RenderLine(syntax: INTEGER; VAR line: ARRAY OF CHAR;
                       len, row: INTEGER);
    VAR i, screenCol, kc: INTEGER;
        word: ARRAY 64 OF CHAR;
        wlen: INTEGER;
        ch, quote: CHAR;
        ok: BOOLEAN;
  BEGIN
    i := 0; screenCol := 0;

    (* Continue an Oberon (* ... *) block comment from a previous line. *)
    IF (syntax = SynOberon) & inBlockComment THEN
      WHILE (i < len) & (screenCol < cols) DO
        ch := line[i];
        IF (ch = "*") & (i + 1 < len) & (line[i+1] = ")") THEN
          ok := Emit(screenCol, row, "*", ColComment);
          IF ok THEN ok := Emit(screenCol, row, ")", ColComment) END;
          INC(i, 2);
          DEC(blockDepth);
          IF blockDepth <= 0 THEN
            blockDepth := 0; inBlockComment := FALSE;
            EXIT
          END
        ELSIF (ch = "(") & (i + 1 < len) & (line[i+1] = "*") THEN
          ok := Emit(screenCol, row, "(", ColComment);
          IF ok THEN ok := Emit(screenCol, row, "*", ColComment) END;
          INC(i, 2); INC(blockDepth)
        ELSE
          ok := Emit(screenCol, row, ch, ColComment);
          INC(i)
        END;
        IF ~ok THEN RETURN END
      END
    END;

    WHILE (i < len) & (screenCol < cols) DO
      ch := line[i];

      (* --- line comments --------------------------------------------- *)
      IF ((syntax = SynRuby) OR (syntax = SynR)) & (ch = "#") THEN
        WHILE (i < len) & (screenCol < cols) DO
          ok := Emit(screenCol, row, line[i], ColComment);
          INC(i);
          IF ~ok THEN RETURN END
        END;
        RETURN

      (* --- Oberon block comment (* ... *) --------------------------- *)
      ELSIF (syntax = SynOberon) & (ch = "(") & (i + 1 < len) & (line[i+1] = "*") THEN
        ok := Emit(screenCol, row, "(", ColComment);
        IF ok THEN ok := Emit(screenCol, row, "*", ColComment) END;
        INC(i, 2);
        inBlockComment := TRUE; blockDepth := 1;
        WHILE (i < len) & (screenCol < cols) & inBlockComment DO
          ch := line[i];
          IF (ch = "*") & (i + 1 < len) & (line[i+1] = ")") THEN
            ok := Emit(screenCol, row, "*", ColComment);
            IF ok THEN ok := Emit(screenCol, row, ")", ColComment) END;
            INC(i, 2); DEC(blockDepth);
            IF blockDepth <= 0 THEN
              blockDepth := 0; inBlockComment := FALSE
            END
          ELSIF (ch = "(") & (i + 1 < len) & (line[i+1] = "*") THEN
            ok := Emit(screenCol, row, "(", ColComment);
            IF ok THEN ok := Emit(screenCol, row, "*", ColComment) END;
            INC(i, 2); INC(blockDepth)
          ELSE
            ok := Emit(screenCol, row, ch, ColComment);
            INC(i)
          END;
          IF ~ok THEN RETURN END
        END

      (* --- strings --------------------------------------------------- *)
      ELSIF (ch = "'") OR (ch = 22X) THEN  (* 22X = double-quote *)
        quote := ch;
        ok := Emit(screenCol, row, ch, ColString);
        INC(i);
        IF ~ok THEN RETURN END;
        WHILE (i < len) & (line[i] # quote) DO
          IF (line[i] = "\") & (i + 1 < len)
             & ((syntax = SynRuby) OR (syntax = SynR)) THEN
            ok := Emit(screenCol, row, line[i], ColString);
            IF ok THEN ok := Emit(screenCol, row, line[i+1], ColString) END;
            INC(i, 2)
          ELSE
            ok := Emit(screenCol, row, line[i], ColString);
            INC(i)
          END;
          IF ~ok THEN RETURN END
        END;
        IF i < len THEN
          ok := Emit(screenCol, row, line[i], ColString);
          INC(i);
          IF ~ok THEN RETURN END
        END

      (* --- numbers --------------------------------------------------- *)
      ELSIF IsDigit(ch) THEN
        WHILE (i < len) & (IsDigit(line[i]) OR (line[i] = ".")
                            OR (line[i] = "e") OR (line[i] = "E")
                            OR (line[i] = "x") OR (line[i] = "X")
                            OR (line[i] = "L")) DO
          ok := Emit(screenCol, row, line[i], ColNumber);
          INC(i);
          IF ~ok THEN RETURN END
        END

      (* --- identifiers / keywords ------------------------------------ *)
      ELSIF IsAlpha(ch) THEN
        wlen := 0;
        WHILE (i < len) & IsIdent(line[i]) & (wlen < LEN(word) - 1) DO
          word[wlen] := line[i]; INC(wlen); INC(i)
        END;
        word[wlen] := 0X;
        kc := LookupKeyword(syntax, word);
        IF kc < 0 THEN kc := ColDefault END;
        EmitWord(screenCol, row, word, kc);
        IF screenCol >= cols THEN RETURN END;
        (* skip any remaining tail (e.g., colons after Ruby symbols) *)
        WHILE (i < len) & IsIdent(line[i]) DO
          ok := Emit(screenCol, row, line[i], ColDefault);
          INC(i);
          IF ~ok THEN RETURN END
        END

      ELSE
        ok := Emit(screenCol, row, ch, ColDefault);
        INC(i);
        IF ~ok THEN RETURN END
      END
    END
  END RenderLine;

  (* ===================================================================
     drawing
     =================================================================== *)

  PROCEDURE DrawWindow(w: Window);
    VAR line: ARRAY 4096 OF CHAR;
        rowIdx, lineNo, total, len, i: INTEGER;
        modeLine: ARRAY 256 OF CHAR;
        tmp: ARRAY 64 OF CHAR;
  BEGIN
    EnsureCursorVisible(w);
    total := Editor.LineCount(w.buf.ed);
    inBlockComment := FALSE; blockDepth := 0;

    (* Walk forward from the top of buffer to detect an already-open
       block comment at w.buf.scroll.  Cheap because we only inspect
       the first character pair of each line; that misses some edge
       cases but is good enough for live editing. *)
    IF w.buf.syntax = SynOberon THEN
      lineNo := 1;
      WHILE lineNo < w.buf.scroll DO
        len := Editor.GetLine(w.buf.ed, lineNo, LEN(line), line);
        i := 0;
        WHILE i < len - 1 DO
          IF inBlockComment THEN
            IF (line[i] = "*") & (line[i+1] = ")") THEN
              DEC(blockDepth);
              IF blockDepth <= 0 THEN inBlockComment := FALSE END;
              INC(i, 2)
            ELSIF (line[i] = "(") & (line[i+1] = "*") THEN
              INC(blockDepth); INC(i, 2)
            ELSE INC(i)
            END
          ELSE
            IF (line[i] = "(") & (line[i+1] = "*") THEN
              inBlockComment := TRUE; blockDepth := 1; INC(i, 2)
            ELSE INC(i)
            END
          END
        END;
        INC(lineNo)
      END
    END;

    rowIdx := 0;
    WHILE rowIdx < w.height - 1 DO
      lineNo := w.buf.scroll + rowIdx;
      Terminal.Color(ColDefault, 0);
      Terminal.Goto(1, w.top + rowIdx);
      Terminal.HLine(1, w.top + rowIdx, cols, " ");
      Terminal.Goto(1, w.top + rowIdx);
      IF lineNo <= total THEN
        len := Editor.GetLine(w.buf.ed, lineNo, LEN(line), line);
        RenderLine(w.buf.syntax, line, len, w.top + rowIdx)
      ELSE
        Terminal.Color(ColDefault, 0);
        Out.Char("~")
      END;
      Terminal.Reset;
      INC(rowIdx)
    END;

    (* Mode line *)
    Terminal.Goto(1, w.top + w.height - 1);
    Terminal.Color(0, 7);
    Terminal.HLine(1, w.top + w.height - 1, cols, " ");
    Terminal.Goto(1, w.top + w.height - 1);
    modeLine := " -:";
    IF Editor.IsModified(w.buf.ed) # 0 THEN Strings.Append("**", modeLine)
    ELSE Strings.Append("--", modeLine) END;
    Strings.Append("  ", modeLine);
    Strings.Append(w.buf.name, modeLine);
    Strings.Append("   L", modeLine);
    IntToStr(Editor.CursorLine(w.buf.ed), tmp);
    Strings.Append(tmp, modeLine);
    Strings.Append("  ", modeLine);
    IF total > 0 THEN
      i := (Editor.CursorLine(w.buf.ed) * 100) DIV total;
      IntToStr(i, tmp);
      Strings.Append(tmp, modeLine);
      Strings.Append("%", modeLine)
    END;
    Strings.Append("   (", modeLine);
    CASE w.buf.syntax OF
      SynOberon: Strings.Append("Oberon", modeLine)
    | SynRuby:   Strings.Append("Ruby", modeLine)
    | SynR:      Strings.Append("R", modeLine)
    ELSE         Strings.Append("Fundamental", modeLine)
    END;
    Strings.Append(")", modeLine);
    Out.String(modeLine);
    Terminal.Reset
  END DrawWindow;

  PROCEDURE DrawEchoArea;
  BEGIN
    Terminal.Color(ColDefault, 0);
    Terminal.Goto(1, rows);
    Terminal.HLine(1, rows, cols, " ");
    Terminal.Goto(1, rows);
    Out.String(echoMsg);
    Terminal.Reset
  END DrawEchoArea;

  PROCEDURE PlaceCursor;
    VAR w: Window;
        ln, col, screenRow, i, screenCol, lineLen: INTEGER;
        line: ARRAY 4096 OF CHAR;
  BEGIN
    w := curWin;
    ln := Editor.CursorLine(w.buf.ed);
    col := Editor.CursorCol(w.buf.ed);
    screenRow := w.top + (ln - w.buf.scroll);
    lineLen := Editor.GetLine(w.buf.ed, ln, LEN(line), line);
    screenCol := 0; i := 0;
    WHILE (i < col - 1) & (i < lineLen) DO
      IF line[i] = 09X THEN
        REPEAT INC(screenCol) UNTIL screenCol MOD 8 = 0
      ELSE INC(screenCol) END;
      INC(i)
    END;
    IF screenCol >= cols THEN screenCol := cols - 1 END;
    Terminal.Goto(screenCol + 1, screenRow)
  END PlaceCursor;

  PROCEDURE Redraw;
    VAR w: Window;
  BEGIN
    Terminal.HideCursor;
    Terminal.Clear;
    w := rootWin;
    WHILE w # NIL DO DrawWindow(w); w := w.next END;
    DrawEchoArea;
    PlaceCursor;
    Terminal.ShowCursor
  END Redraw;

  (* ===================================================================
     kill ring
     =================================================================== *)

  PROCEDURE KillRingPush(s: ARRAY OF CHAR);
  BEGIN
    killHead := (killHead + 1) MOD MaxKillRing;
    Strings.Copy(s, killRing[killHead]);
    IF killCount < MaxKillRing THEN INC(killCount) END;
    yankIndex := 0
  END KillRingPush;

  PROCEDURE KillRingAppend(s: ARRAY OF CHAR);
  BEGIN
    IF killCount = 0 THEN KillRingPush(s)
    ELSE Strings.Append(s, killRing[killHead])
    END
  END KillRingAppend;

  PROCEDURE KillRingCurrent(VAR dst: ARRAY OF CHAR);
    VAR idx: INTEGER;
  BEGIN
    IF killCount = 0 THEN dst[0] := 0X; RETURN END;
    idx := killHead - yankIndex;
    WHILE idx < 0 DO INC(idx, MaxKillRing) END;
    Strings.Copy(killRing[idx], dst)
  END KillRingCurrent;

  (* ===================================================================
     primitive editing helpers
     =================================================================== *)

  PROCEDURE PointPos(): INTEGER;
  BEGIN RETURN Editor.CursorPos(curBuf.ed)
  END PointPos;

  PROCEDURE GotoP(pos: INTEGER);
  BEGIN Editor.GotoPos(curBuf.ed, pos)
  END GotoP;

  PROCEDURE BufLen(): INTEGER;
  BEGIN RETURN Editor.Len(curBuf.ed)
  END BufLen;

  PROCEDURE CharAt(pos: INTEGER; VAR ch: CHAR): BOOLEAN;
    VAR save, ln, col, len: INTEGER;
        line: ARRAY 4096 OF CHAR;
  BEGIN
    IF (pos < 0) OR (pos >= BufLen()) THEN RETURN FALSE END;
    save := PointPos();
    Editor.GotoPos(curBuf.ed, pos);
    ln  := Editor.CursorLine(curBuf.ed);
    col := Editor.CursorCol(curBuf.ed);
    len := Editor.GetLine(curBuf.ed, ln, LEN(line), line);
    Editor.GotoPos(curBuf.ed, save);
    IF col - 1 >= len THEN ch := 0AX
    ELSE ch := line[col - 1] END;
    RETURN TRUE
  END CharAt;

  PROCEDURE KillRange(a, b: INTEGER);
    VAR lo, hi, i, n: INTEGER; ch: CHAR;
        buf: ARRAY 4096 OF CHAR;
  BEGIN
    IF a < b THEN lo := a; hi := b ELSE lo := b; hi := a END;
    n := 0; i := lo;
    WHILE (i < hi) & (n < LEN(buf) - 1) DO
      IF CharAt(i, ch) THEN buf[n] := ch; INC(n) END;
      INC(i)
    END;
    buf[n] := 0X;
    IF lastWasKill THEN KillRingAppend(buf) ELSE KillRingPush(buf) END;
    Editor.GotoPos(curBuf.ed, hi);
    i := hi - lo;
    WHILE i > 0 DO Editor.Backspace(curBuf.ed); DEC(i) END;
    lastWasKill := TRUE
  END KillRange;

  (* ===================================================================
     minibuffer
     =================================================================== *)

  PROCEDURE Prompt(promptStr: ARRAY OF CHAR; VAR result: ARRAY OF CHAR): BOOLEAN;
    VAR ch: CHAR; len: INTEGER; line: ARRAY MaxStr OF CHAR;
  BEGIN
    result[0] := 0X; len := 0;
    LOOP
      Terminal.Color(ColDefault, 0);
      Terminal.Goto(1, rows);
      Terminal.HLine(1, rows, cols, " ");
      Terminal.Goto(1, rows);
      Strings.Copy(promptStr, line);
      Strings.Append(result, line);
      Out.String(line);
      Terminal.ShowCursor;
      ch := Terminal.ReadKey();
      IF ch = KEnter THEN RETURN TRUE
      ELSIF ch = KCtrlG THEN
        result[0] := 0X; SetEcho("Quit"); RETURN FALSE
      ELSIF (ch = KBackspace) OR (ch = KDel) THEN
        IF len > 0 THEN DEC(len); result[len] := 0X END
      ELSIF (ch >= " ") & (ch < 7FX) & (len < LEN(result) - 1) THEN
        result[len] := ch; INC(len); result[len] := 0X
      END
    END;
    RETURN FALSE
  END Prompt;

  (* ===================================================================
     commands -- movement
     =================================================================== *)

  PROCEDURE CmdForwardChar;
  BEGIN Editor.MoveRight(curBuf.ed)
  END CmdForwardChar;

  PROCEDURE CmdBackwardChar;
  BEGIN Editor.MoveLeft(curBuf.ed)
  END CmdBackwardChar;

  PROCEDURE CmdNextLine;
  BEGIN Editor.MoveDown(curBuf.ed)
  END CmdNextLine;

  PROCEDURE CmdPreviousLine;
  BEGIN Editor.MoveUp(curBuf.ed)
  END CmdPreviousLine;

  PROCEDURE CmdBeginningOfLine;
  BEGIN Editor.MoveLineStart(curBuf.ed)
  END CmdBeginningOfLine;

  PROCEDURE CmdEndOfLine;
  BEGIN Editor.MoveLineEnd(curBuf.ed)
  END CmdEndOfLine;

  PROCEDURE IsWordChar(ch: CHAR): BOOLEAN;
  BEGIN
    RETURN ((ch >= "a") & (ch <= "z"))
        OR ((ch >= "A") & (ch <= "Z"))
        OR ((ch >= "0") & (ch <= "9"))
        OR (ch = "_")
  END IsWordChar;

  PROCEDURE CmdForwardWord;
    VAR p, len: INTEGER; ch: CHAR;
  BEGIN
    len := BufLen(); p := PointPos();
    WHILE (p < len) & CharAt(p, ch) & ~IsWordChar(ch) DO INC(p) END;
    WHILE (p < len) & CharAt(p, ch) &  IsWordChar(ch) DO INC(p) END;
    GotoP(p)
  END CmdForwardWord;

  PROCEDURE CmdBackwardWord;
    VAR p: INTEGER; ch: CHAR;
  BEGIN
    p := PointPos();
    WHILE (p > 0) & CharAt(p - 1, ch) & ~IsWordChar(ch) DO DEC(p) END;
    WHILE (p > 0) & CharAt(p - 1, ch) &  IsWordChar(ch) DO DEC(p) END;
    GotoP(p)
  END CmdBackwardWord;

  PROCEDURE CmdBeginningOfBuffer;
  BEGIN Editor.GotoPos(curBuf.ed, 0)
  END CmdBeginningOfBuffer;

  PROCEDURE CmdEndOfBuffer;
  BEGIN Editor.GotoPos(curBuf.ed, BufLen())
  END CmdEndOfBuffer;

  PROCEDURE CmdBackwardSentence;
    VAR p: INTEGER; ch: CHAR;
  BEGIN
    p := PointPos();
    IF p > 0 THEN DEC(p) END;
    WHILE (p > 0) & CharAt(p, ch)
        & (ch # ".") & (ch # "!") & (ch # "?") DO DEC(p) END;
    IF (p > 0) & CharAt(p, ch) & ((ch = ".") OR (ch = "!") OR (ch = "?")) THEN
      INC(p);
      WHILE (p < BufLen()) & CharAt(p, ch) & ((ch = " ") OR (ch = 0AX)) DO INC(p) END
    END;
    GotoP(p)
  END CmdBackwardSentence;

  PROCEDURE CmdForwardSentence;
    VAR p, len: INTEGER; ch: CHAR;
  BEGIN
    len := BufLen(); p := PointPos();
    WHILE (p < len) & CharAt(p, ch)
        & (ch # ".") & (ch # "!") & (ch # "?") DO INC(p) END;
    IF p < len THEN INC(p) END;
    GotoP(p)
  END CmdForwardSentence;

  (* ===================================================================
     commands -- scrolling and screen
     =================================================================== *)

  PROCEDURE CmdScrollUp;     (* C-v *)
    VAR i, h: INTEGER;
  BEGIN
    h := TextHeight(curWin) - 2;
    IF h < 1 THEN h := 1 END;
    curBuf.scroll := curBuf.scroll + h;
    i := 0;
    WHILE i < h DO Editor.MoveDown(curBuf.ed); INC(i) END
  END CmdScrollUp;

  PROCEDURE CmdScrollDown;   (* M-v *)
    VAR i, h: INTEGER;
  BEGIN
    h := TextHeight(curWin) - 2;
    IF h < 1 THEN h := 1 END;
    curBuf.scroll := curBuf.scroll - h;
    IF curBuf.scroll < 1 THEN curBuf.scroll := 1 END;
    i := 0;
    WHILE i < h DO Editor.MoveUp(curBuf.ed); INC(i) END
  END CmdScrollDown;

  PROCEDURE CmdRecenter;     (* C-l *)
    VAR ln, h: INTEGER;
  BEGIN
    ln := Editor.CursorLine(curBuf.ed);
    h  := TextHeight(curWin);
    curBuf.scroll := ln - (h DIV 2);
    IF curBuf.scroll < 1 THEN curBuf.scroll := 1 END
  END CmdRecenter;

  (* ===================================================================
     commands -- editing
     =================================================================== *)

  PROCEDURE CmdSelfInsert(ch: CHAR);
  BEGIN Editor.InsertChar(curBuf.ed, ch)
  END CmdSelfInsert;

  PROCEDURE CmdNewline;
  BEGIN Editor.InsertChar(curBuf.ed, 0AX)
  END CmdNewline;

  PROCEDURE CmdBackspace;
  BEGIN Editor.Backspace(curBuf.ed)
  END CmdBackspace;

  PROCEDURE CmdDeleteChar;
  BEGIN Editor.DeleteChar(curBuf.ed)
  END CmdDeleteChar;

  PROCEDURE CmdKillLine;     (* C-k *)
    VAR ln, col, len, start, finish: INTEGER;
        line: ARRAY 4096 OF CHAR;
  BEGIN
    start := PointPos();
    ln    := Editor.CursorLine(curBuf.ed);
    col   := Editor.CursorCol(curBuf.ed);
    len   := Editor.GetLine(curBuf.ed, ln, LEN(line), line);
    IF col - 1 >= len THEN
      IF start < BufLen() THEN finish := start + 1
      ELSE finish := start END
    ELSE
      finish := start + (len - (col - 1))
    END;
    IF finish > start THEN KillRange(start, finish) END
  END CmdKillLine;

  PROCEDURE CmdKillSentence;
    VAR start, finish: INTEGER;
  BEGIN
    start := PointPos();
    CmdForwardSentence;
    finish := PointPos();
    GotoP(start);
    IF finish > start THEN KillRange(start, finish) END
  END CmdKillSentence;

  PROCEDURE CmdKillWordForward;
    VAR start, finish: INTEGER;
  BEGIN
    start := PointPos();
    CmdForwardWord;
    finish := PointPos();
    GotoP(start);
    IF finish > start THEN KillRange(start, finish) END
  END CmdKillWordForward;

  PROCEDURE CmdKillWordBackward;
    VAR start, finish: INTEGER;
  BEGIN
    finish := PointPos();
    CmdBackwardWord;
    start := PointPos();
    IF finish > start THEN
      GotoP(finish);
      KillRange(start, finish)
    END
  END CmdKillWordBackward;

  PROCEDURE CmdSetMark;
  BEGIN
    curBuf.markPos := PointPos();
    curBuf.hasMark := TRUE;
    SetEcho("Mark set")
  END CmdSetMark;

  PROCEDURE CmdKillRegion;
  BEGIN
    IF ~curBuf.hasMark THEN SetEcho("The mark is not set"); RETURN END;
    KillRange(curBuf.markPos, PointPos());
    curBuf.hasMark := FALSE
  END CmdKillRegion;

  PROCEDURE CmdCopyRegion;
    VAR a, b, lo, hi, i, n: INTEGER; ch: CHAR;
        buf: ARRAY 4096 OF CHAR;
  BEGIN
    IF ~curBuf.hasMark THEN SetEcho("The mark is not set"); RETURN END;
    a := curBuf.markPos; b := PointPos();
    IF a < b THEN lo := a; hi := b ELSE lo := b; hi := a END;
    n := 0; i := lo;
    WHILE (i < hi) & (n < LEN(buf) - 1) DO
      IF CharAt(i, ch) THEN buf[n] := ch; INC(n) END;
      INC(i)
    END;
    buf[n] := 0X;
    KillRingPush(buf);
    SetEcho("Region copied");
    curBuf.hasMark := FALSE
  END CmdCopyRegion;

  PROCEDURE CmdYank;
    VAR s: ARRAY 1024 OF CHAR;
  BEGIN
    IF killCount = 0 THEN SetEcho("Kill ring is empty"); RETURN END;
    yankIndex := 0;
    KillRingCurrent(s);
    curBuf.markPos := PointPos();
    curBuf.hasMark := TRUE;
    Editor.InsertStr(curBuf.ed, s);
    lastWasYank := TRUE
  END CmdYank;

  PROCEDURE CmdYankPop;
    VAR s: ARRAY 1024 OF CHAR; i, n: INTEGER;
  BEGIN
    IF ~lastWasYank THEN SetEcho("Previous command was not a yank"); RETURN END;
    IF killCount = 0 THEN RETURN END;
    n := PointPos() - curBuf.markPos;
    IF n > 0 THEN
      i := 0;
      WHILE i < n DO Editor.Backspace(curBuf.ed); INC(i) END
    END;
    yankIndex := (yankIndex + 1) MOD killCount;
    KillRingCurrent(s);
    curBuf.markPos := PointPos();
    Editor.InsertStr(curBuf.ed, s);
    lastWasYank := TRUE
  END CmdYankPop;

  PROCEDURE CmdUndo;
  BEGIN Editor.Undo(curBuf.ed)
  END CmdUndo;

  (* ===================================================================
     commands -- files & buffers
     =================================================================== *)

  PROCEDURE FindFile;
    VAR path: ARRAY MaxStr OF CHAR; name: ARRAY 64 OF CHAR;
        b: Buffer; rc: INTEGER;
  BEGIN
    IF ~Prompt("Find file: ", path) THEN RETURN END;
    IF path[0] = 0X THEN SetEcho("Aborted"); RETURN END;
    BaseName(path, name);
    b := FindBuffer(name);
    IF b = NIL THEN
      b := NewBuffer(name);
      IF Files.Exists(path) THEN
        rc := Editor.Load(b.ed, path);
        IF rc # 0 THEN SetEcho("Error loading file") END
      END;
      Strings.Copy(path, b.file);
      b.syntax := DetectSyntax(path)
    END;
    ShowBuffer(b);
    SetEcho("Visited file")
  END FindFile;

  PROCEDURE SaveBuffer;
    VAR path: ARRAY MaxStr OF CHAR; rc: INTEGER;
        msg: ARRAY MaxStr OF CHAR;
  BEGIN
    IF curBuf.file[0] = 0X THEN
      IF ~Prompt("File to save in: ", path) THEN RETURN END;
      IF path[0] = 0X THEN RETURN END;
      Strings.Copy(path, curBuf.file);
      BaseName(path, curBuf.name);
      curBuf.syntax := DetectSyntax(path)
    END;
    rc := Editor.Save(curBuf.ed, curBuf.file);
    IF rc = 0 THEN
      Strings.Copy("Wrote ", msg);
      Strings.Append(curBuf.file, msg);
      SetEcho(msg)
    ELSE
      SetEcho("Error saving file")
    END
  END SaveBuffer;

  PROCEDURE SaveSomeBuffers;
    VAR i, rc: INTEGER; ch: CHAR;
        msg: ARRAY MaxStr OF CHAR;
  BEGIN
    i := 0;
    WHILE i < nBuffers DO
      IF (Editor.IsModified(buffers[i].ed) # 0) & (buffers[i].file[0] # 0X) THEN
        Terminal.Color(ColDefault, 0);
        Terminal.Goto(1, rows);
        Terminal.HLine(1, rows, cols, " ");
        Terminal.Goto(1, rows);
        Strings.Copy("Save file ", msg);
        Strings.Append(buffers[i].file, msg);
        Strings.Append("? (y or n) ", msg);
        Out.String(msg);
        ch := Terminal.ReadKey();
        IF (ch = "y") OR (ch = "Y") THEN
          rc := Editor.Save(buffers[i].ed, buffers[i].file);
          IF rc # 0 THEN SetEcho("Save failed") END
        END
      END;
      INC(i)
    END;
    SetEcho("Done")
  END SaveSomeBuffers;

  PROCEDURE SwitchBuffer;
    VAR name: ARRAY MaxStr OF CHAR; b: Buffer;
  BEGIN
    IF ~Prompt("Switch to buffer: ", name) THEN RETURN END;
    IF name[0] = 0X THEN RETURN END;
    b := FindBuffer(name);
    IF b = NIL THEN b := NewBuffer(name) END;
    ShowBuffer(b)
  END SwitchBuffer;

  PROCEDURE ListBuffers;
    VAR b: Buffer; i: INTEGER;
        text: ARRAY 4096 OF CHAR;
        line: ARRAY MaxStr OF CHAR;
        tmp:  ARRAY 32 OF CHAR;
        nl:   ARRAY 2 OF CHAR;
  BEGIN
    nl[0] := 0AX; nl[1] := 0X;
    Strings.Copy("CRM Buffer            Size  File", text);
    Strings.Append(nl, text);
    Strings.Append("--- ------            ----  ----", text);
    Strings.Append(nl, text);
    i := 0;
    WHILE i < nBuffers DO
      b := buffers[i];
      IF Editor.IsModified(b.ed) # 0 THEN
        Strings.Copy(" *  ", line)
      ELSE
        Strings.Copy("    ", line)
      END;
      Strings.Append(b.name, line);
      WHILE Strings.Length(line) < 22 DO Strings.Append(" ", line) END;
      IntToStr(Editor.Len(b.ed), tmp);
      Strings.Append(tmp, line);
      Strings.Append("  ", line);
      Strings.Append(b.file, line);
      Strings.Append(line, text);
      Strings.Append(nl, text);
      INC(i)
    END;
    b := FindBuffer("*Buffer List*");
    IF b = NIL THEN b := NewBuffer("*Buffer List*") END;
    Editor.Free(b.ed); b.ed := Editor.New();
    Editor.InsertStr(b.ed, text);
    Editor.GotoPos(b.ed, 0);
    ShowBuffer(b)
  END ListBuffers;

  (* ===================================================================
     incremental search
     =================================================================== *)

  PROCEDURE IsearchUpdate(direction: INTEGER; VAR needle: ARRAY OF CHAR;
                          startPos: INTEGER);
    VAR found, best: INTEGER;
  BEGIN
    Editor.GotoPos(curBuf.ed, startPos);
    IF needle[0] = 0X THEN RETURN END;
    IF direction >= 0 THEN
      found := Editor.Find(curBuf.ed, needle, 0, 0)
    ELSE
      best := -1;
      Editor.GotoPos(curBuf.ed, 0);
      WHILE Editor.Find(curBuf.ed, needle, 0, 0) = 1 DO
        IF Editor.CursorPos(curBuf.ed) <= startPos THEN
          best := Editor.CursorPos(curBuf.ed)
        ELSE
          IF best >= 0 THEN Editor.GotoPos(curBuf.ed, best) END;
          RETURN
        END;
        Editor.MoveRight(curBuf.ed)
      END;
      IF best >= 0 THEN Editor.GotoPos(curBuf.ed, best)
      ELSE Editor.GotoPos(curBuf.ed, startPos) END
    END
  END IsearchUpdate;

  PROCEDURE Isearch(direction: INTEGER);
    VAR needle: ARRAY MaxStr OF CHAR;
        prompt: ARRAY MaxStr OF CHAR;
        startPos, len, found: INTEGER;
        ch: CHAR;
  BEGIN
    startPos := PointPos();
    needle[0] := 0X; len := 0;
    LOOP
      Redraw;
      Terminal.Color(ColDefault, 0);
      Terminal.Goto(1, rows);
      Terminal.HLine(1, rows, cols, " ");
      Terminal.Goto(1, rows);
      IF direction >= 0 THEN Strings.Copy("I-search: ", prompt)
      ELSE Strings.Copy("I-search backward: ", prompt) END;
      Strings.Append(needle, prompt);
      Out.String(prompt);
      Terminal.ShowCursor;
      ch := Terminal.ReadKey();
      IF (ch = KEnter) OR (ch = KEsc) THEN
        SetEcho("Search done"); RETURN
      ELSIF ch = KCtrlG THEN
        Editor.GotoPos(curBuf.ed, startPos);
        SetEcho("Quit"); RETURN
      ELSIF ch = KCtrlS THEN
        direction := 1;
        IF len > 0 THEN
          Editor.MoveRight(curBuf.ed);
          found := Editor.FindAgain(curBuf.ed);
          IF found = 0 THEN
            Editor.GotoPos(curBuf.ed, 0);
            found := Editor.Find(curBuf.ed, needle, 0, 0)
          END
        END
      ELSIF ch = KCtrlR THEN
        direction := -1;
        IF len > 0 THEN IsearchUpdate(-1, needle, PointPos() - 1) END
      ELSIF (ch = KBackspace) OR (ch = KDel) THEN
        IF len > 0 THEN
          DEC(len); needle[len] := 0X;
          IsearchUpdate(direction, needle, startPos)
        END
      ELSIF (ch >= " ") & (ch < 7FX) & (len < LEN(needle) - 1) THEN
        needle[len] := ch; INC(len); needle[len] := 0X;
        IsearchUpdate(direction, needle, startPos)
      END
    END
  END Isearch;

  (* ===================================================================
     M-x: replace-string
     =================================================================== *)

  PROCEDURE DoReplaceString;
    VAR from, to_: ARRAY MaxStr OF CHAR;
        count, fl, i: INTEGER;
        msg, tmp: ARRAY MaxStr OF CHAR;
  BEGIN
    IF ~Prompt("Replace string: ", from) THEN RETURN END;
    IF from[0] = 0X THEN RETURN END;
    IF ~Prompt("Replace with: ", to_) THEN RETURN END;
    fl := Strings.Length(from);
    count := 0;
    WHILE Editor.Find(curBuf.ed, from, 0, 0) = 1 DO
      i := 0;
      WHILE i < fl DO Editor.DeleteChar(curBuf.ed); INC(i) END;
      Editor.InsertStr(curBuf.ed, to_);
      INC(count)
    END;
    Strings.Copy("Replaced ", msg);
    IntToStr(count, tmp);
    Strings.Append(tmp, msg);
    Strings.Append(" occurrence(s)", msg);
    SetEcho(msg)
  END DoReplaceString;

  PROCEDURE ExecuteExtended;
    VAR name: ARRAY MaxStr OF CHAR;
  BEGIN
    IF ~Prompt("M-x ", name) THEN RETURN END;
    IF (Strings.Compare(name, "replace-string") = 0)
       OR (Strings.Compare(name, "repl s") = 0)
    THEN DoReplaceString
    ELSIF Strings.Compare(name, "list-buffers")     = 0 THEN ListBuffers
    ELSIF Strings.Compare(name, "save-buffer")      = 0 THEN SaveBuffer
    ELSIF Strings.Compare(name, "find-file")        = 0 THEN FindFile
    ELSIF Strings.Compare(name, "switch-to-buffer") = 0 THEN SwitchBuffer
    ELSIF Strings.Compare(name, "isearch-forward")  = 0 THEN Isearch(1)
    ELSIF Strings.Compare(name, "isearch-backward") = 0 THEN Isearch(-1)
    ELSIF Strings.Compare(name, "oberon-mode")      = 0 THEN
        curBuf.syntax := SynOberon; SetEcho("Oberon mode")
    ELSIF Strings.Compare(name, "ruby-mode")        = 0 THEN
        curBuf.syntax := SynRuby; SetEcho("Ruby mode")
    ELSIF Strings.Compare(name, "r-mode")           = 0 THEN
        curBuf.syntax := SynR; SetEcho("R mode")
    ELSIF (Strings.Compare(name, "fundamental-mode") = 0)
       OR (Strings.Compare(name, "text-mode")        = 0) THEN
        curBuf.syntax := SynNone; SetEcho("Fundamental mode")
    ELSIF Strings.Compare(name, "auto-fill-mode")   = 0 THEN
        SetEcho("Auto-fill not implemented in obemacs")
    ELSIF Strings.Compare(name, "recover-this-file") = 0 THEN
        SetEcho("No auto-save in obemacs")
    ELSE
        SetEcho("No such command")
    END
  END ExecuteExtended;

  (* ===================================================================
     C-x prefix
     =================================================================== *)

  PROCEDURE HandleCtrlX;
    VAR ch: CHAR;
        msg: ARRAY MaxStr OF CHAR;
  BEGIN
    SetEcho("C-x-");
    Redraw;
    ch := Terminal.ReadKey();
    CASE ch OF
      KCtrlC: SaveSomeBuffers; quitFlag := TRUE
    | KCtrlF: FindFile
    | KCtrlS: SaveBuffer
    | KCtrlB: ListBuffers
    | "b":    SwitchBuffer
    | "s":    SaveSomeBuffers
    | "1":    OnlyWindow
    | "2":    SplitWindow
    | "o":    OtherWindow
    | "u":    CmdUndo
    | "k":
        IF Prompt("Kill buffer: ", msg) THEN
          SetEcho("Buffer kill not fully supported")
        END
    ELSE
      SetEcho("C-x: unknown sub-command")
    END
  END HandleCtrlX;

  (* ===================================================================
     Meta prefix (ESC ...)
     =================================================================== *)

  PROCEDURE HandleMeta;
    VAR ch: CHAR;
  BEGIN
    ch := Terminal.ReadKey();
    CASE ch OF
      "f":  CmdForwardWord
    | "b":  CmdBackwardWord
    | "a":  CmdBackwardSentence
    | "e":  CmdForwardSentence
    | "d":  CmdKillWordForward
    | "k":  CmdKillSentence
    | "v":  CmdScrollDown
    | "w":  CmdCopyRegion
    | "y":  CmdYankPop
    | "<":  CmdBeginningOfBuffer
    | ">":  CmdEndOfBuffer
    | "x":  ExecuteExtended
    | KBackspace, KDel: CmdKillWordBackward
    ELSE
      SetEcho("Unknown M-key")
    END
  END HandleMeta;

  (* ===================================================================
     main dispatch
     =================================================================== *)

  PROCEDURE Dispatch(ch: CHAR);
    VAR nextWasYank, nextWasKill: BOOLEAN;
  BEGIN
    nextWasYank := FALSE;
    nextWasKill := FALSE;
    CASE ch OF
      KCtrlF: CmdForwardChar
    | KCtrlB: CmdBackwardChar
    | KCtrlN: CmdNextLine
    | KCtrlP: CmdPreviousLine
    | KCtrlA: CmdBeginningOfLine
    | KCtrlE: CmdEndOfLine
    | KCtrlV: CmdScrollUp
    | KCtrlL: CmdRecenter
    | KCtrlD: CmdDeleteChar
    | KCtrlK: CmdKillLine; nextWasKill := TRUE
    | KCtrlY: CmdYank; nextWasYank := TRUE
    | KCtrlW: CmdKillRegion; nextWasKill := TRUE
    | KCtrlS: Isearch(1)
    | KCtrlR: Isearch(-1)
    | KCtrlSlash: CmdUndo
    | KCtrlX: HandleCtrlX
    | KEsc:   HandleMeta
    | KEnter: CmdNewline
    | KBackspace, KDel: CmdBackspace
    | KTab:   CmdSelfInsert(09X)
    | KNul:   CmdSetMark             (* C-SPC / C-@ *)
    | KCtrlG: SetEcho("Quit")
    | KUp:    CmdPreviousLine
    | KDown:  CmdNextLine
    | KLeft:  CmdBackwardChar
    | KRight: CmdForwardChar
    | KPgUp:  CmdScrollDown
    | KPgDn:  CmdScrollUp
    | KHome:  CmdBeginningOfLine
    | KEnd:   CmdEndOfLine
    | KDel:   CmdDeleteChar
    ELSE
      IF (ch >= " ") & (ch < 7FX) THEN CmdSelfInsert(ch) END
    END;
    lastWasYank := nextWasYank;
    lastWasKill := nextWasKill
  END Dispatch;

  PROCEDURE HandleCtrlU(VAR next: CHAR);
    VAR ch: CHAR; n: INTEGER; have: BOOLEAN;
        msg, tmp: ARRAY 32 OF CHAR;
  BEGIN
    n := 0; have := FALSE;
    LOOP
      Terminal.Color(ColDefault, 0);
      Terminal.Goto(1, rows);
      Terminal.HLine(1, rows, cols, " ");
      Terminal.Goto(1, rows);
      Strings.Copy("C-u ", msg);
      IF have THEN IntToStr(n, tmp); Strings.Append(tmp, msg) END;
      Strings.Append("-", msg);
      Out.String(msg);
      ch := Terminal.ReadKey();
      IF ch = KCtrlG THEN prefixArg := -1; next := KNul; RETURN END;
      IF (ch >= "0") & (ch <= "9") THEN
        n := n * 10 + (ORD(ch) - ORD("0"));
        have := TRUE
      ELSE
        IF have THEN prefixArg := n ELSE prefixArg := 4 END;
        next := ch; RETURN
      END
    END
  END HandleCtrlU;

  (* ===================================================================
     boot
     =================================================================== *)

  PROCEDURE InitialBuffer;
    VAR b: Buffer;
        argv: ARRAY MaxStr OF CHAR;
        rc: INTEGER;
        name: ARRAY 64 OF CHAR;
  BEGIN
    IF Args.Count() >= 1 THEN
      Args.Get(1, argv);
      BaseName(argv, name);
      b := NewBuffer(name);
      Strings.Copy(argv, b.file);
      b.syntax := DetectSyntax(argv);
      IF Files.Exists(argv) THEN
        rc := Editor.Load(b.ed, argv);
        IF rc # 0 THEN SetEcho("Could not load file") END
      END
    ELSE
      b := NewBuffer("*scratch*");
      Editor.InsertStr(b.ed,
        "Welcome to obemacs.  C-x C-f opens a file, C-x C-c quits.")
    END;
    NEW(rootWin);
    rootWin.buf  := b;
    rootWin.next := NIL;
    curWin := rootWin;
    curBuf := b;
    LayoutWindows
  END InitialBuffer;

  PROCEDURE MainLoop;
    VAR ch, repCh: CHAR; count, i: INTEGER;
  BEGIN
    quitFlag := FALSE;
    SetEcho("obemacs ready.  C-x C-c to quit.");
    WHILE ~quitFlag DO
      cols := Terminal.Cols();
      rows := Terminal.Rows();
      IF rows < 5 THEN rows := 5 END;
      LayoutWindows;
      Redraw;
      ClearEcho;
      ch := Terminal.ReadKey();
      IF ch = KCtrlU THEN
        HandleCtrlU(repCh);
        count := prefixArg;
        IF count <= 0 THEN count := 1 END;
        IF repCh # KNul THEN
          i := 0;
          WHILE i < count DO Dispatch(repCh); INC(i) END
        END;
        prefixArg := -1
      ELSE
        Dispatch(ch)
      END
    END
  END MainLoop;

BEGIN
  nBuffers    := 0;
  killCount   := 0;
  killHead    := -1;
  yankIndex   := 0;
  lastWasYank := FALSE;
  lastWasKill := FALSE;
  prefixArg   := -1;
  echoMsg[0]  := 0X;
  inBlockComment := FALSE;
  blockDepth  := 0;

  cols := Terminal.Cols();
  rows := Terminal.Rows();
  IF rows < 5 THEN rows := 5 END;

  InitialBuffer;
  MainLoop;

  Terminal.Restore;
  Out.String("Bye."); Out.Ln
END obemacs.





