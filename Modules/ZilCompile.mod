MODULE ZilCompile;
(*
  ZilCompile — phase 3b of the zilf port (see Notes/zilf_port_plan.md):
  the first slice of actual Z-machine code generation, walking what
  ZilModel accumulated during evaluation (phase 3a) and emitting .zap
  TEXT for it — fed into the zapf assembler we already built, rather
  than any binary encoding of our own (see the plan doc's phase 3
  architecture reading pass for why: the original's whole Zilf.Emit
  abstraction/peephole-optimizer layer reduces, for our purposes, to
  "map an operator to a Z-machine mnemonic string and emit a line of
  text", which zapf already knows how to assemble).

  Still a pragmatic subset, widened one slice at a time (the discipline
  used throughout every earlier phase of this port). What compiles today:

    - a required-args-only ROUTINE with a multi-statement body, and
      CompileProgram to emit a whole assemblable .zap file around them
      (constants, the global table, an empty object table and dictionary,
      then the routines — in the memory-map order the Z-machine requires)
    - operands: FIX and CHARACTER literals, <> , LVAL (.X) and GVAL (,X)
      references, and bare atoms naming a CONSTANT / ROUTINE / OBJECT
    - GLOBAL and CONSTANT declarations, with the V3 HERE/SCORE/MOVES
      variable-order requirement honoured
    - arithmetic: + - * / MOD
    - statements: SET, SETG, INC, DEC, RETURN, RTRUE, RFALSE, QUIT,
      PRINTI, PRINTN, CRLF, and calls to routines this program defines
    - COND as a real branch tree, with the predicates ZERO?, EQUAL?/=?/
      ==?, L?, G?, IGRTR?, DLESS?, NOT/F?, T?

  NOT implemented: OBJECT/property/flag/table emission, the vocabulary and
  syntax tables, string packing (.GSTR/.STR), TELL, AND/OR short-circuit
  sequencing, the loop constructs (REPEAT/PROG/AGAIN in their compiled
  sense), and the bulk of ZBuiltins.cs's 237 builtin registrations. Each
  is reported as an explicit compile error rather than silently
  mis-compiled — see the plan doc for the intended order.

  Compound sub-expressions always route their result through the
  Z-machine stack (STACK) rather than allocating temporary locals — a
  correct, if not maximally efficient, simplification consistent with
  this port's "correctness first, optimization never" philosophy
  (confirmed skippable: the original's own peephole optimizer is the
  only thing that would tighten this, and we've already decided not to
  port it).
*)

IMPORT ZilObj, ZilModel, ZilEval, Out, Files, Strings, ZapfZChar;

VAR
  errFlag*: BOOLEAN;
  errMsg*: ARRAY 512 OF CHAR;

VAR curRoutine: ARRAY 64 OF CHAR;   (* for error messages *)
    (* the CURRENTLY COMPILING routine's own explicit activation atom name,
       e.g. the MSN in <ROUTINE MAP-SCOPE-NEXT MSN ("AUX" ...) ...> — empty
       when the routine has none. A <RETURN value .NAME> naming THIS atom
       means "return from the routine", the one case FindNamedBlock cannot
       answer since the routine itself is never pushed as a numbered block. *)
    curRoutineAct: ARRAY 64 OF CHAR;
    curStmt: ARRAY 512 OF CHAR;

PROCEDURE Err(msg: ARRAY OF CHAR);
BEGIN
  IF errFlag THEN RETURN END;         (* first error wins, as in ZilEval *)
  errFlag := TRUE;
  Strings.Copy(msg, errMsg);
  IF curRoutine[0] # 0X THEN
    Strings.Append(" [in routine ", errMsg);
    Strings.Append(curRoutine, errMsg);
    IF curStmt[0] # 0X THEN
      Strings.Append(", statement ", errMsg);
      Strings.Append(curStmt, errMsg)
    END;
    Strings.Append("]", errMsg)
  END
END Err;

PROCEDURE ClearErr*;
BEGIN errFlag := FALSE; errMsg[0] := 0X; curRoutine[0] := 0X END ClearErr;

(* ---------------- output ----------------
   All .zap text goes through W (append to the current line) and WLn (end
   it), so the whole emitter can target either stdout or a real file
   without every call site caring which. The line buffer exists because
   this system's Files.WriteString appends a NUL byte (it writes Oberon's
   own null-terminated string format, not plain text) — Files.WriteLine is
   the only text-clean file write available, and it writes a whole line at
   a time, so lines have to be assembled before they're written. *)
CONST
  MaxBufLines = 20000;
  MaxLocals = 15;   (* the Z-machine's own per-routine limit *)
  MaxBlocks = 32;
  MaxFlagNames = 64;
  MaxPropNames = 96;
  MaxRenames = 64;
  MaxStrings = 4096;
  MaxActions = 512;

TYPE
  LineText = POINTER TO ARRAY OF CHAR;
  (* An instruction's operand texts. A named fixed-size type, because this
     dialect cannot pass an open two-dimensional array as a parameter —
     `VAR a: ARRAY OF ARRAY OF CHAR` silently degrades a[i] to a single
     CHAR. Eight is the most operands any Z-machine instruction takes. *)
  ArgList = ARRAY 8 OF ARRAY 64 OF CHAR;

VAR
  outIsFile: BOOLEAN;
  outFile: Files.File;
  outRider: Files.Rider;
  lineBuf: ARRAY 8192 OF CHAR;

  (* routine-body buffering and compiler temporaries — see the block of
     procedures just after CloseOutput for what these are for *)
  buffering: BOOLEAN;
  bufLines: ARRAY MaxBufLines OF LineText;
  nBufLines: INTEGER;
  tempDepth, tempMax: INTEGER;
  tmpStack: ARRAY MaxRenames OF ARRAY 64 OF CHAR;
  nTmpStack: INTEGER;
  tmpWhy: ARRAY 64 OF CHAR;   (* which construct asked for the last temporary *)

  (* The stack of enclosing PROG/REPEAT blocks (the original's
     Compilation.Blocks). RETURN and AGAIN target the innermost one — that
     is the whole reason a stack is needed rather than a single current
     block: a RETURN inside a COND inside a PROG inside a REPEAT has to
     leave the PROG, not the REPEAT. `returned` records whether anything
     actually jumped to the block's return label, so an unreferenced label
     isn't emitted. *)
  (* ---- the current routine's locals ----
     Index 0..nParams-1 are the declared arguments, in source order; after
     them come the locals PROG/REPEAT bindings introduce. They all end up on
     one .FUNCT line, because that is all a ZAP routine has: the Z-machine
     knows nothing about inner scopes. The scoping is therefore entirely the
     compiler's job, which is what the rename stack below is for — the
     original does the same thing with PushInnerLocal/PopInnerLocal. *)
  locName: ARRAY MaxLocals OF ARRAY 64 OF CHAR;   (* the ZAP name *)
  locZil: ARRAY MaxLocals OF ARRAY 64 OF CHAR;    (* the ZIL name it stands for *)
  locInit: ARRAY MaxLocals OF ARRAY 64 OF CHAR;   (* constant default, or "" *)
  locExpr: ARRAY MaxLocals OF ZilObj.Zo;          (* non-constant default, or NIL *)
  locInScope: ARRAY MaxLocals OF BOOLEAN;
  nLocals, nParams: INTEGER;

  (* The innermost-first mapping from a ZIL local name to the ZAP local
     actually holding it. Pushed by a PROG/REPEAT binding, popped when that
     block ends, so a binding really does shadow an outer one of the same
     name and stops doing so afterwards. *)
  renZil, renZap: ARRAY MaxRenames OF ARRAY 64 OF CHAR;
  nRenames: INTEGER;

  (* The packed-string pool. A STRING used as a VALUE (in a table, as an
     operand, as TELL's packed-string fallback) needs an address to point
     at, which means the string has to be emitted separately and referred
     to by a symbol. zapf's .GSTR directive does exactly that: it encodes
     the text and defines the symbol as its packed address. *)
  strPool: ARRAY MaxStrings OF LineText;
  nStrings: INTEGER;

  (* Actions, numbered by CompileSyntax. An action has two names: the
     ROUTINE that implements it (V-TELL) and the CONSTANT that identifies
     it (V?TELL). The original derives the second from the first by turning
     a leading "V-" into "V?", or prefixing "V?" otherwise, and keys
     everything by the constant. *)
  actionRoutine: ARRAY MaxActions OF ARRAY 64 OF CHAR;
  actionConst: ARRAY MaxActions OF ARRAY 64 OF CHAR;
  nActions: INTEGER;

  (* object flags and properties, registered by CompileObjects *)
  flagNameTab: ARRAY MaxFlagNames OF ARRAY 64 OF CHAR;
  nFlagNames: INTEGER;
  propNameTab: ARRAY MaxPropNames OF ARRAY 64 OF CHAR;
  nPropNames: INTEGER;
  objParent, objSibling, objChild: ARRAY ZilModel.MaxObjects OF INTEGER;

  blockNames: ARRAY MaxBlocks OF ARRAY 64 OF CHAR;
  blockAgain, blockReturn: ARRAY MaxBlocks OF ARRAY 16 OF CHAR;
  blockWantResult, blockReturned, blockHasReturn: ARRAY MaxBlocks OF BOOLEAN;
  nBlocks: INTEGER;

PROCEDURE W(s: ARRAY OF CHAR);
BEGIN Strings.Append(s, lineBuf) END W;

(* Turns a ZIL name into a legal ZAP symbol, ported from the original's
   GameBuilder.SanitizeSymbol. ZAP symbols may contain letters, digits, `?`,
   `#` and `-`; every other character becomes `$` followed by its character
   code in four lower-case hex digits. The three characters the parser breaks
   words on, plus the apostrophe, get readable names of their own because
   each is a whole dictionary word in its own right - zillib really does
   define the one-character words `,` `.` and `"`, and <SYNTAX \,TELL ...>
   makes `,TELL` a verb, so without this the assembler is handed labels like
   `W?,::`. *)
PROCEDURE SanitizeSymbol(VAR s: ARRAY OF CHAR);
VAR out: ARRAY 256 OF CHAR; hex: ARRAY 20 OF CHAR;
    i, n, c, shift: INTEGER; ch: CHAR;
BEGIN
  (* NOTE: compared character by character on purpose. A one-character
     double-quoted literal is typed as a CHAR in this dialect, so `s = ","`
     would compile to a comparison against an integer. *)
  IF s[1] = 0X THEN
    IF s[0] = "." THEN Strings.Copy("$PERIOD", s); RETURN END;
    IF s[0] = "," THEN Strings.Copy("$COMMA", s); RETURN END;
    IF s[0] = '"' THEN Strings.Copy("$QUOTE", s); RETURN END;
    IF s[0] = "'" THEN Strings.Copy("$APOSTROPHE", s); RETURN END
  END;
  Strings.Copy("0123456789abcdef", hex);
  i := 0; n := 0;
  WHILE (s[i] # 0X) & (n < LEN(out) - 6) DO
    ch := s[i];
    IF ((ch >= "0") & (ch <= "9")) OR ((ch >= "A") & (ch <= "Z"))
       OR ((ch >= "a") & (ch <= "z")) OR (ch = "?") OR (ch = "#") OR (ch = "-") THEN
      out[n] := ch; INC(n)
    ELSE
      c := ORD(ch);
      out[n] := "$"; INC(n);
      shift := 4096;
      WHILE shift > 0 DO
        out[n] := hex[(c DIV shift) MOD 16]; INC(n);
        shift := shift DIV 16
      END
    END;
    INC(i)
  END;
  out[n] := 0X;
  Strings.Copy(out, s)
END SanitizeSymbol;

(* Sanitizes a symbol that already carries one of the compiler's own
   prefixes, leaving the prefix alone and sanitizing only the ZIL name after
   it. This distinction matters: the original builds a dictionary word's
   symbol as "W?" plus SanitizeSymbol(word), so the word `.` becomes
   W?$PERIOD - whereas sanitizing the whole string "W?." would give W?$002e
   and never match the label the vocabulary table defines. A name with no
   known prefix is sanitized whole. ACT? is tested before A? because it
   starts with one. *)
PROCEDURE SanitizePrefixed(VAR s: ARRAY OF CHAR);
VAR k: INTEGER; pre, rest: ARRAY 256 OF CHAR;
BEGIN
  k := 0;
  IF (s[0] = "A") & (s[1] = "C") & (s[2] = "T") & (s[3] = "?") THEN k := 4
  ELSIF (s[0] = "P") & (s[1] = "R") & (s[2] = "?") THEN k := 3
  ELSIF (s[0] = "S") & (s[1] = "T") & (s[2] = "?") THEN k := 3
  ELSIF (s[0] = "W") & (s[1] = "?") THEN k := 2
  ELSIF (s[0] = "A") & (s[1] = "?") THEN k := 2
  END;
  IF k = 0 THEN SanitizeSymbol(s); RETURN END;
  Strings.Copy(s, pre); pre[k] := 0X;
  Strings.Copy(s, rest); Strings.Delete(rest, 0, k);
  SanitizeSymbol(rest);
  Strings.Copy(pre, s); Strings.Append(rest, s)
END SanitizePrefixed;

(* Writes a name as a ZAP symbol. Every symbol this module emits, whether as
   a definition or as a reference, goes through here or through ConstantText
   so that the two spellings always agree. *)
PROCEDURE WSym(name: ARRAY OF CHAR);
VAR buf: ARRAY 256 OF CHAR;
BEGIN
  Strings.Copy(name, buf); SanitizePrefixed(buf); W(buf)
END WSym;

PROCEDURE WLn;
VAR t: LineText;
BEGIN
  IF buffering THEN
    IF nBufLines < MaxBufLines THEN
      NEW(t, Strings.Length(lineBuf) + 1);
      Strings.Copy(lineBuf, t^);
      bufLines[nBufLines] := t; INC(nBufLines)
    ELSE
      Err("routine body too long for the emission buffer")
    END
  ELSIF outIsFile THEN Files.WriteLine(outRider, lineBuf)
  ELSE Out.String(lineBuf); Out.Ln
  END;
  lineBuf[0] := 0X
END WLn;

(* Directs subsequent output to `name` instead of stdout. *)
PROCEDURE OpenOutput*(name: ARRAY OF CHAR): BOOLEAN;
BEGIN
  outFile := Files.New(name);
  IF outFile = NIL THEN RETURN FALSE END;
  Files.Set(outRider, outFile, 0);
  outIsFile := TRUE; lineBuf[0] := 0X;
  RETURN TRUE
END OpenOutput;

PROCEDURE CloseOutput*;
BEGIN
  IF outIsFile THEN
    Files.Register(outFile); Files.Close(outFile);
    outFile := NIL; outIsFile := FALSE
  END
END CloseOutput;

(* ---------------- routine body buffering, and compiler temporaries ----------------
   A routine's `.FUNCT NAME,local,...` line has to name every local the
   body uses, but which compiler temporaries a body needs is only known
   once it has been compiled. So a routine's body is compiled into a line
   buffer first; the .FUNCT line is written afterwards, with the temporary
   count the body turned out to need, and the buffer is then flushed
   underneath it.

   The temporaries exist to fix an operand-ordering bug: every compound
   sub-expression leaves its result on the Z-machine stack, so when two of
   them feed one instruction, the operands come off the stack in the
   opposite order to the one they went on. The original solves this the
   same way (PushInnerLocal with a "?TMP" atom, e.g. ZBuiltins.cs's
   SetValueOp) — spill the earlier value into a named local so the later
   one can have the stack to itself. `SET 'T-TMPn,STACK` is the spill: the
   Z-machine store instruction reads its value operand from the stack,
   popping it. Temporaries are allocated by nesting depth (T-TMP1, T-TMP2,
   ...) and released as each instruction consumes them, so a routine only
   declares as many as its deepest expression actually needed. Named
   "T-TMPn" rather than the original's own "?TMP" spelling — see
   AllocTemp's own comment on why a leading "?" doesn't survive this
   port's own ZAP text emission the way it does the original's binary
   emitter API. *)
PROCEDURE BeginBuffer;
BEGIN
  buffering := TRUE; nBufLines := 0; tempDepth := 0; tempMax := 0; nTmpStack := 0
END BeginBuffer;

PROCEDURE EndBuffer;
BEGIN buffering := FALSE END EndBuffer;

PROCEDURE FlushBuffer;
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE i < nBufLines DO
    IF outIsFile THEN Files.WriteLine(outRider, bufLines[i]^)
    ELSE Out.String(bufLines[i]^); Out.Ln
    END;
    bufLines[i] := NIL;
    INC(i)
  END;
  nBufLines := 0
END FlushBuffer;

(* Allocates a compiler temporary and yields its ZAP local name.
   Temporaries come from the SAME pool as PROG/REPEAT bindings rather than a
   separate TMP series, so a binding that has gone out of scope can serve
   as a temporary and vice versa. A routine has only fifteen locals and real
   library routines declare fourteen, so keeping two pools ran out on code
   the original compiles fine. Named by nesting depth, so a temporary at the
   same depth reuses the same slot.

   The fallback name (used when there is no out-of-scope PROG/REPEAT slot to
   reuse — a routine with no bindings of its own, like cloak_plus's
   SAVE-PARSER-RESULT) must not start with "?": ZAP's own syntax uses a
   leading "?" for LOCAL LABELS (the branch targets this port's own codegen
   writes as "?L4:"), and zapf's parser reads a "?"-prefixed token as one of
   those regardless of where it appears — including a plain variable
   position like `SET '?TMP1,x` or a .FUNCT's own local-name list. The
   result isn't a clean "duplicate label" error; it's zapf's function-scope
   tracking going wrong from that point on, reported many lines later as a
   cascade of "local labels not allowed outside a function" errors that
   don't obviously point back here. Confirmed by renaming and re-assembling:
   V1-4 games happened never to hit this exact shape (no bindings AND a
   spill needed), but V5's cloak_plus does the moment UNDO support compiles
   in real save/restore-state routines. *)
PROCEDURE AllocTemp(VAR name: ARRAY OF CHAR);
VAR n, zilName: ARRAY 32 OF CHAR;
BEGIN
  INC(tempDepth);
  IF tempDepth > tempMax THEN tempMax := tempDepth END;
  Strings.IntToStr(tempDepth, n);
  Strings.Copy("T-TMP", zilName); Strings.Append(n, zilName);
  IF AllocInnerLocal(zilName) THEN ResolveLocal(zilName, name)
  ELSE Strings.Copy(zilName, name) END;
  IF nTmpStack < MaxRenames THEN
    Strings.Copy(name, tmpStack[nTmpStack]); INC(nTmpStack)
  END
END AllocTemp;

(* Releases the most recently allocated temporary BY NAME rather than by
   position in the rename stack. Position is not reliable: a temporary's
   lifetime can straddle other allocations (a call spills several arguments
   while compiling the ones between), and popping "the top" then releases
   somebody else's slot and leaks this one. *)
PROCEDURE FreeTemp;
VAR i, j: INTEGER;
BEGIN
  IF nTmpStack = 0 THEN RETURN END;
  DEC(nTmpStack);
  i := nRenames - 1;
  WHILE (i >= 0) & (renZap[i] # tmpStack[nTmpStack]) DO DEC(i) END;
  IF i >= 0 THEN
    j := i;
    WHILE j < nRenames - 1 DO
      Strings.Copy(renZil[j + 1], renZil[j]);
      Strings.Copy(renZap[j + 1], renZap[j]);
      INC(j)
    END;
    DEC(nRenames)
  END;
  i := nParams;
  WHILE i < nLocals DO
    IF locName[i] = tmpStack[nTmpStack] THEN locInScope[i] := FALSE END;
    INC(i)
  END;
  DEC(tempDepth)
END FreeTemp;

(* Renders a FIX as decimal text (negative numbers included, matching ZAP
   expression syntax — zapf's own expression parser accepts a leading
   "-"). *)
PROCEDURE FixText(v: INTEGER; VAR s: ARRAY OF CHAR);
BEGIN Strings.IntToStr(v, s) END FixText;

VAR labelCounter: INTEGER;

(* Generates a fresh local label name, "?L1", "?L2", ... — matches the
   real compiler's own naming convention exactly (confirmed against
   ~/cloak_plus.zap's own "?L11:"-style labels). *)
PROCEDURE NewLabel(VAR s: ARRAY OF CHAR);
VAR n: ARRAY 16 OF CHAR;
BEGIN
  INC(labelCounter);
  Strings.IntToStr(labelCounter, n);
  Strings.Copy("?L", s); Strings.Append(n, s)
END NewLabel;

(* ---------------- name lookup over ZilModel's registrations ----------------
   The original resolves a bare/GVAL'd atom by consulting, in this order,
   Routines / Objects / Constants / Globals (see Compilation.Globals.cs's
   CompileConstant) — these four little searches are this port's equivalent
   of those four dictionaries. Linear scans: real games have a few hundred
   of each, and compilation happens once, so the dictionary the original
   uses would buy nothing here. Each returns an index, or -1. *)

PROCEDURE FindRoutineIdx*(name: ARRAY OF CHAR): INTEGER;
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE i < ZilModel.nRoutines DO
    IF ZilModel.routines[i].name.atomText = name THEN RETURN i END;
    INC(i)
  END;
  RETURN -1
END FindRoutineIdx;

PROCEDURE FindObjectIdx*(name: ARRAY OF CHAR): INTEGER;
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE i < ZilModel.nObjects DO
    IF ZilModel.objects[i].name.atomText = name THEN RETURN i END;
    INC(i)
  END;
  RETURN -1
END FindObjectIdx;

PROCEDURE FindConstantIdx*(name: ARRAY OF CHAR): INTEGER;
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE i < ZilModel.nConstants DO
    IF ZilModel.constants[i].name.atomText = name THEN RETURN i END;
    INC(i)
  END;
  RETURN -1
END FindConstantIdx;

(* Registered TABLE/LTABLE/ITABLE/... values are matched by IDENTITY, not by
   name or contents: a table has no name in the source at all — it is an
   anonymous value that a CONSTANT or GLOBAL happens to hold — and the same
   values could legitimately appear in two different tables. The original
   does the same thing (a Dictionary<ZilTable, ITableBuilder> keyed by
   reference). *)
(* Interns a string into the packed-string pool and yields the symbol that
   will stand for its address. Identical texts share one entry — the
   original pools strings the same way, and a game repeats short strings a
   lot. *)
PROCEDURE InternString(text: ARRAY OF CHAR; VAR sym: ARRAY OF CHAR): BOOLEAN;
VAR i: INTEGER; n: ARRAY 16 OF CHAR; t: LineText;
BEGIN
  i := 0;
  WHILE i < nStrings DO
    IF strPool[i]^ = text THEN
      Strings.IntToStr(i, n);
      Strings.Copy("STR?", sym); Strings.Append(n, sym);
      RETURN TRUE
    END;
    INC(i)
  END;
  IF nStrings >= MaxStrings THEN
    Err("too many distinct strings"); RETURN FALSE
  END;
  NEW(t, Strings.Length(text) + 1);
  Strings.Copy(text, t^);
  strPool[nStrings] := t;
  Strings.IntToStr(nStrings, n);
  Strings.Copy("STR?", sym); Strings.Append(n, sym);
  INC(nStrings);
  RETURN TRUE
END InternString;

PROCEDURE FindTableIdx*(t: ZilObj.Zo): INTEGER;
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE i < ZilModel.nTables DO
    IF ZilModel.tables[i] = t THEN RETURN i END;
    INC(i)
  END;
  RETURN -1
END FindTableIdx;

(* The ZAP label a registered table is emitted under. Matches the original's
   own generated naming (T?1, T?2, ...). *)
PROCEDURE TableLabel(i: INTEGER; VAR s: ARRAY OF CHAR);
VAR n: ARRAY 16 OF CHAR;
BEGIN
  Strings.IntToStr(i + 1, n);
  Strings.Copy("T?", s); Strings.Append(n, s)
END TableLabel;

(* An inline table constructor in a routine body — <PLTABLE "a" "b"> handed
   to PICK-ONE-R, for instance. The original evaluates that form at compile
   time, registers the ZilTable it produces so it is emitted with all the
   others, and uses its label as the operand.

   Here the evaluation cannot happen while the routine is being compiled,
   because tables are emitted into static memory BEFORE any routine body is
   looked at: a table discovered then would get a label but no data. So the
   evaluation happens in PrepareRoutines instead (see ScanInlineTables) and
   the resulting table is memoized on the FORM itself under this indicator,
   which is what CompileOperand reads back. *)
PROCEDURE InlineTableMarker(): ZilObj.Zo;
BEGIN RETURN ZilObj.Intern("ZILCOMPILE!-INLINE-TABLE") END InlineTableMarker;

PROCEDURE IsTableBuiltin(name: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN (name = "TABLE") OR (name = "LTABLE") OR (name = "PTABLE")
      OR (name = "PLTABLE") OR (name = "ITABLE")
END IsTableBuiltin;

PROCEDURE IsTableForm(z: ZilObj.Zo): BOOLEAN;
BEGIN
  RETURN (z # NIL) & (z.kind = ZilObj.KForm) & (z.first # NIL)
       & (z.first.kind = ZilObj.KAtom) & IsTableBuiltin(z.first.atomText)
END IsTableForm;

(* Object flags and properties are registered by CompileObjects; these two
   read that registration back, and are declared here because ConstantText
   (above the object code) needs them. *)
(* Looks a flag name up, following a <BIT-SYNONYM> alias to the flag it shares
   a bit with. Resolving here rather than at every call site is what keeps an
   alias from claiming a second bit — V3 has only 32. *)
PROCEDURE FindFlagIdx*(name: ARRAY OF CHAR): INTEGER;
VAR i: INTEGER; target: ARRAY 64 OF CHAR;
BEGIN
  i := 0;
  WHILE i < nFlagNames DO
    IF flagNameTab[i] = name THEN RETURN i END;
    INC(i)
  END;
  IF ZilModel.BitSynonymOf(name, target) THEN
    i := 0;
    WHILE i < nFlagNames DO
      IF flagNameTab[i] = target THEN RETURN i END;
      INC(i)
    END
  END;
  RETURN -1
END FindFlagIdx;

PROCEDURE FindPropIdx*(name: ARRAY OF CHAR): INTEGER;
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE i < nPropNames DO
    IF propNameTab[i] = name THEN RETURN i END;
    INC(i)
  END;
  RETURN -1
END FindPropIdx;

PROCEDURE FindGlobalIdx*(name: ARRAY OF CHAR): INTEGER;
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE i < ZilModel.nGlobals DO
    IF ZilModel.globals[i].name.atomText = name THEN RETURN i END;
    INC(i)
  END;
  RETURN -1
END FindGlobalIdx;

(* True if `z` names a VARIABLE, yielding its bare ZAP name in `name`.
   Mirrors the original's [Variable] parameter attribute (ZBuiltins.cs),
   which accepts the variable's bare atom as well as an <LVAL X>/<GVAL X>
   form naming it — real source writes <SET X ...>, <INC N> and <SETG
   SCORE ...> with bare atoms but also <INC .N>/<SETG ,FOO ...> in places,
   and all four spellings mean the same variable. Locals and globals share
   one ZAP namespace (a local declared by .FUNCT shadows a global of the
   same name within that routine), so the bare name alone is the right
   operand text either way and no scope decision is needed here. *)
PROCEDURE VarName(z: ZilObj.Zo; VAR name: ARRAY OF CHAR): BOOLEAN;
BEGIN
  IF z = NIL THEN RETURN FALSE END;
  IF z.kind = ZilObj.KAtom THEN
    Strings.Copy(z.atomText, name); RETURN TRUE
  ELSIF (z.kind = ZilObj.KForm) & (ZilObj.ListLength(z) = 2)
        & (ZilObj.IsAtomNamed(z.first, "LVAL") OR ZilObj.IsAtomNamed(z.first, "GVAL"))
        & (z.rest.first # NIL) & (z.rest.first.kind = ZilObj.KAtom) THEN
    Strings.Copy(z.rest.first.atomText, name); RETURN TRUE
  END;
  RETURN FALSE
END VarName;

(* Compiles `z` as a COMPILE-TIME CONSTANT, yielding the ZAP expression text
   for it — the original's CompileConstant (Compilation.Globals.cs), reduced
   to the value shapes this slice can actually emit. Used for a GLOBAL's or
   CONSTANT's declared default value, where no instructions may be emitted
   at all, and by CompileOperand for the atom-shaped operands.

   Resolution order follows the original's exactly: T is 1, then routine
   names, then object names, then constant names — each becoming a bare ZAP
   symbol, which zapf resolves to the routine's packed address / the object
   number / the constant's value respectively. A bare atom naming a GLOBAL
   is deliberately NOT accepted: the original only treats that as a constant
   the global variable index, in "optimistic" mode only and warns when it
   does, and zapf rejects a variable symbol in a constant expression anyway
   (only SymConstant/SymLabel/SymObject are addable), so accepting it here
   would just move the error later. STRING values need a .GSTR/.STR
   definition to point at and are left for the strings slice. *)
PROCEDURE ConstantTextRaw(z: ZilObj.Zo; VAR s: ARRAY OF CHAR): BOOLEAN;
VAR name, propNm: ARRAY 64 OF CHAR; strTmp: ARRAY 4096 OF CHAR; i: INTEGER;
BEGIN
  (* <GVAL X> in a constant position is just X — unwrap and retry, matching
     the original's own `form.IsGVAL(...) -> expr = globalAtom; continue`
     loop rather than a recursive call. *)
  WHILE (z # NIL) & (z.kind = ZilObj.KForm) & (ZilObj.ListLength(z) = 2)
        & ZilObj.IsAtomNamed(z.first, "GVAL") DO
    z := z.rest.first
  END;

  IF z = NIL THEN RETURN FALSE END;

  IF z.kind = ZilObj.KFix THEN FixText(z.fixVal, s); RETURN TRUE
  ELSIF z.kind = ZilObj.KChar THEN FixText(z.charVal, s); RETURN TRUE
  ELSIF z.kind = ZilObj.KTable THEN
    i := FindTableIdx(z);
    IF i < 0 THEN RETURN FALSE END;   (* a TEMP-TABLE: never emitted *)
    TableLabel(i, s); RETURN TRUE
  ELSIF (z.kind = ZilObj.KFalse) OR ((z.kind = ZilObj.KForm) & ZilObj.IsEmpty(z)) THEN
    (* `<>` is FALSE, and an object's property list and a table's contents
       are raw and never evaluated, so the literal really does arrive here
       shaped as an empty FORM — the same case CompileOperand handles for
       routine bodies. *)
    Strings.Copy("0", s); RETURN TRUE
  ELSIF z.kind = ZilObj.KString THEN
    TranslateZilString(z.strBuf^, strTmp);
    RETURN InternString(strTmp, s)
  ELSIF (z.kind = ZilObj.KRoutine) & (z.first # NIL) THEN
    (* a ROUTINE reference (an atom's ZVAL) used as an operand is its address,
       which is the routine's own label *)
    Strings.Copy(z.first.atomText, s); RETURN TRUE
  ELSIF z.kind = ZilObj.KAtom THEN
    Strings.Copy(z.atomText, name);
    IF name = "T" THEN Strings.Copy("1", s); RETURN TRUE END;
    (* LOW-DIRECTION is an assembler symbol EmitObjectTable always writes
       (guarded only by nPropNames > 0, true for any real game), not a
       user-registered routine/object/constant/flag/vocab word, so none of
       the lookups below it would ever find it - zork1's OTHER-SIDE and
       GLOBAL-CHECK both read it directly (`,LOW-DIRECTION`) to know where
       a room's direction properties stop and its ordinary ones begin. *)
    IF name = "LOW-DIRECTION" THEN Strings.Copy(name, s); RETURN TRUE END;
    IF FindRoutineIdx(name) >= 0 THEN Strings.Copy(name, s); RETURN TRUE END;
    IF FindObjectIdx(name) >= 0 THEN Strings.Copy(name, s); RETURN TRUE END;
    IF FindConstantIdx(name) >= 0 THEN Strings.Copy(name, s); RETURN TRUE END;
    (* An object flag's name, and a property's P?NAME, are assembly symbols
       emitted by CompileObjects — which runs before any routine is
       compiled, so by the time a routine body needs one it is known. The
       original reaches these the same way: DefineFlag/DefineProperty each
       add a Constants entry. *)
    IF FindFlagIdx(name) >= 0 THEN Strings.Copy(name, s); RETURN TRUE END;
    (* a dictionary word is referenced by its W?NAME symbol, which the
       vocabulary table defines *)
    IF ZilModel.FindVocab(name) >= 0 THEN
      Strings.Copy("W?", s); Strings.Append(name, s); RETURN TRUE
    END;
    IF (name[0] = "P") & (name[1] = "?") THEN
      Strings.Copy(name, propNm); Strings.Delete(propNm, 0, 2);
      IF FindPropIdx(propNm) >= 0 THEN Strings.Copy(name, s); RETURN TRUE END
    END;
    (* the symbols the syntax and vocabulary tables define: V?ACTION is an
       action number, PR?WORD a preposition number, A?WORD an adjective
       number, W?WORD a dictionary word's address *)
    IF (name[0] = "V") & (name[1] = "?") THEN
      i := 0;
      WHILE i < nActions DO
        IF actionConst[i] = name THEN Strings.Copy(name, s); RETURN TRUE END;
        INC(i)
      END
    END;
    IF ((name[0] = "P") & (name[1] = "R") & (name[2] = "?"))
       OR ((name[0] = "A") & (name[1] = "?"))
       OR ((name[0] = "W") & (name[1] = "?"))
       OR ((name[0] = "A") & (name[1] = "C") & (name[2] = "T") & (name[3] = "?")) THEN
      Strings.Copy(name, propNm);
      IF (name[0] = "A") & (name[1] = "C") THEN Strings.Delete(propNm, 0, 4)
      ELSIF name[1] = "R" THEN Strings.Delete(propNm, 0, 3)
      ELSE Strings.Delete(propNm, 0, 2) END;
      IF ZilModel.FindVocab(propNm) >= 0 THEN Strings.Copy(name, s); RETURN TRUE END
    END;
    (* A bare atom naming a GLOBAL whose OWN value is a table (<GLOBAL DEF1
       <TABLE ...>>) is a forward reference to that table's address - zork1's
       DEF1-RES table writes its first element as the plain atom DEF1 (no
       comma), meaning "DEF1's own table, wherever it ends up", exactly the
       KTable case just above but reached by name instead of by value. *)
    i := FindGlobalIdx(name);
    IF (i >= 0) & (ZilModel.globals[i].value # NIL)
       & (ZilModel.globals[i].value.kind = ZilObj.KTable) THEN
      RETURN ConstantTextRaw(ZilModel.globals[i].value, s)
    END;
    RETURN FALSE
  END;
  RETURN FALSE
END ConstantTextRaw;

(* Every constant/routine/object/word reference reaches the output through
   here, so this is where a name becomes a ZAP symbol. The raw spelling is
   what the registries are keyed by, so the sanitizing happens on the way
   out rather than on the way in. Sanitizing is idempotent for everything
   this returns that ISN'T a name (a decimal number, STR?n, T?n). *)
PROCEDURE ConstantText(z: ZilObj.Zo; VAR s: ARRAY OF CHAR): BOOLEAN;
BEGIN
  IF ~ConstantTextRaw(z, s) THEN RETURN FALSE END;
  SanitizePrefixed(s);
  RETURN TRUE
END ConstantText;

(* Set by CompileStmt when the statement it just compiled always leaves the
   routine (RETURN/RTRUE/RFALSE) — the original tracks the same thing on its
   IRoutineBuilder so it can skip emitting an unreachable trailing return.
   Read by CompileRoutine right after compiling the final statement. *)
VAR termFlag: BOOLEAN;

(* The ZIL builtins that are one Z-machine instruction with no special
   compilation behaviour — the bulk of ZBuiltins.cs's registrations, which
   are all just "emit this opcode with these operands". Returns the ZAP
   mnemonic, how many operands it takes, and whether it stores a result
   (which is what decides between the value path in CompileOperand and the
   void path in CompileStmt).

   Only names real source has actually needed are listed; adding one is a
   line. Builtins with genuine compilation behaviour — the predicates
   (CompileCondition), the variable ops, the print family, COND, the loop
   constructs, calls — are handled separately and are NOT here. *)
(* The smallest number of operands a builtin accepts, where that differs
   from the largest. Several Z-machine instructions are variadic —
   `output_stream` takes a stream and optionally a table, `read` takes two to
   four — so an exact arity check would reject valid source. Everything not
   listed here takes exactly as many as SimpleBuiltin reports. *)
PROCEDURE BuiltinMinArgs(name: ARRAY OF CHAR; maxN: INTEGER): INTEGER;
BEGIN
  IF (name = "DIROUT") OR (name = "DIRIN") OR (name = "INPUT")
     OR (name = "SOUND") OR (name = "CURSET") OR (name = "MARGIN")
     OR (name = "PRINTT") OR (name = "READ") THEN
    RETURN 1
  END;
  RETURN maxN
END BuiltinMinArgs;

(* FIRST? and NEXT? are the Z-machine's get_child/get_sibling, which both
   STORE a result and BRANCH — the original classes them as ValuePredCall,
   the one kind of builtin that is both. Used purely as a value the branch
   still has to be written, because a store-and-branch instruction's branch
   offset is part of its encoding, so these get a branch to the very next
   instruction. *)
PROCEDURE IsValuePredBuiltin(name: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN (name = "FIRST?") OR (name = "NEXT?") OR (name = "INTBL?")
END IsValuePredBuiltin;

(* Writes the ` \?Lnn` that follows such an instruction, plus the label line
   it jumps to. Reversed polarity ("branch when there is no child") purely
   for symmetry with how a failed FIRST? reads; either polarity lands on the
   next instruction. *)
PROCEDURE EmitDeadBranch;
VAR lbl: ARRAY 16 OF CHAR;
BEGIN
  NewLabel(lbl);
  W(" \"); W(lbl); WLn;
  W(lbl); W(":"); WLn
END EmitDeadBranch;

PROCEDURE SimpleBuiltin(name: ARRAY OF CHAR; VAR zap: ARRAY OF CHAR;
                        VAR nargs: INTEGER; VAR store: BOOLEAN): BOOLEAN;
BEGIN
  store := TRUE;
  (* value-producing *)
  (* ZGET/ZPUT are the word-indexed table accessors DEFSTRUCT generates for
     a TABLE-based record; they are GET/PUT under another name. *)
  IF (name = "GET") OR (name = "NTH") OR (name = "ZGET") THEN Strings.Copy("GET", zap); nargs := 2
  ELSIF (name = "GETB") OR (name = "ZGETB") THEN Strings.Copy("GETB", zap); nargs := 2
  ELSIF name = "GETP" THEN Strings.Copy("GETP", zap); nargs := 2
  ELSIF name = "GETPT" THEN Strings.Copy("GETPT", zap); nargs := 2
  ELSIF name = "NEXTP" THEN Strings.Copy("NEXTP", zap); nargs := 2
  ELSIF name = "BCOM" THEN Strings.Copy("BCOM", zap); nargs := 1
  ELSIF (name = "ASH") OR (name = "ASHIFT") THEN Strings.Copy("ASHIFT", zap); nargs := 2
  ELSIF name = "SHIFT" THEN Strings.Copy("SHIFT", zap); nargs := 2
  ELSIF name = "RANDOM" THEN Strings.Copy("RANDOM", zap); nargs := 1
  ELSIF name = "LOC" THEN Strings.Copy("LOC", zap); nargs := 1
    (* FIRST?/NEXT? both store AND branch; used as a value only the stored
       child/sibling matters (0 when there is none), and a ZAP branch marker
       is optional *)
  ELSIF name = "FIRST?" THEN Strings.Copy("FIRST?", zap); nargs := 1
  ELSIF name = "NEXT?" THEN Strings.Copy("NEXT?", zap); nargs := 1
  ELSIF name = "INTBL?" THEN Strings.Copy("INTBL?", zap); nargs := 3
  ELSIF name = "PTSIZE" THEN Strings.Copy("PTSIZE", zap); nargs := 1
    (* ISAVE/IRESTORE (save_undo/restore_undo, V5+): store a result - 2 if a
       save just succeeded and this is the continuation after IRESTORE
       resumes it, 1/0 for ordinary save success/failure - and take no
       operands at all. cloak_plus's PARSER routine uses ISAVE directly for
       its <UNDO> command, gated on the USE-UNDO? flag ZIP-OPTIONS sets. *)
  ELSIF name = "ISAVE" THEN Strings.Copy("ISAVE", zap); nargs := 0
  ELSIF name = "IRESTORE" THEN Strings.Copy("IRESTORE", zap); nargs := 0

  (* void *)
  ELSE
    store := FALSE;
    IF (name = "PUT") OR (name = "ZPUT") THEN Strings.Copy("PUT", zap); nargs := 3
    ELSIF (name = "PUTB") OR (name = "ZPUTB") THEN Strings.Copy("PUTB", zap); nargs := 3
    ELSIF name = "PUTP" THEN Strings.Copy("PUTP", zap); nargs := 3
    ELSIF name = "MOVE" THEN Strings.Copy("MOVE", zap); nargs := 2
    ELSIF name = "REMOVE" THEN Strings.Copy("REMOVE", zap); nargs := 1
    ELSIF name = "FSET" THEN Strings.Copy("FSET", zap); nargs := 2
    ELSIF name = "FCLEAR" THEN Strings.Copy("FCLEAR", zap); nargs := 2
    ELSIF name = "HLIGHT" THEN Strings.Copy("HLIGHT", zap); nargs := 1
    ELSIF name = "SCREEN" THEN Strings.Copy("SCREEN", zap); nargs := 1
    ELSIF name = "SPLIT" THEN Strings.Copy("SPLIT", zap); nargs := 1
    ELSIF name = "CLEAR" THEN Strings.Copy("CLEAR", zap); nargs := 1
    ELSIF name = "CURSET" THEN Strings.Copy("CURSET", zap); nargs := 3
    ELSIF name = "BUFOUT" THEN Strings.Copy("BUFOUT", zap); nargs := 1
    ELSIF name = "DIROUT" THEN Strings.Copy("DIROUT", zap); nargs := 2
    ELSIF name = "USL" THEN Strings.Copy("USL", zap); nargs := 0
    ELSIF name = "PRINT" THEN Strings.Copy("PRINT", zap); nargs := 1
    ELSIF name = "PRINTD" THEN Strings.Copy("PRINTD", zap); nargs := 1
    ELSIF name = "PRINTB" THEN Strings.Copy("PRINTB", zap); nargs := 1
    ELSIF name = "PRINTU" THEN Strings.Copy("PRINTU", zap); nargs := 1
    ELSIF name = "PUSH" THEN Strings.Copy("PUSH", zap); nargs := 1
    ELSIF name = "RESTART" THEN Strings.Copy("RESTART", zap); nargs := 0
    ELSIF name = "READ" THEN Strings.Copy("READ", zap); nargs := 4
      (* V1-4's read takes a text buffer and a parse buffer and stores
         nothing; V5's stores the terminating character, but CompileProgram
         refuses V5 anyway, so the void form is the only one reachable *)
    ELSIF name = "COPYT" THEN Strings.Copy("COPYT", zap); nargs := 3
    ELSIF name = "PRINTT" THEN Strings.Copy("PRINTT", zap); nargs := 4
    ELSIF name = "ZWSTR" THEN Strings.Copy("ZWSTR", zap); nargs := 4
    ELSIF name = "DIRIN" THEN Strings.Copy("DIRIN", zap); nargs := 2
    ELSIF name = "INPUT" THEN Strings.Copy("INPUT", zap); nargs := 3
    ELSIF name = "SOUND" THEN Strings.Copy("SOUND", zap); nargs := 4
    ELSIF name = "POP" THEN Strings.Copy("POP", zap); nargs := 0
    ELSIF name = "FSTACK" THEN Strings.Copy("FSTACK", zap); nargs := 0
    ELSIF name = "MARGIN" THEN Strings.Copy("MARGIN", zap); nargs := 3
    ELSE RETURN FALSE
    END
  END;
  RETURN TRUE
END SimpleBuiltin;

(* Maps a ZIL local name to the ZAP local currently holding it. Innermost
   binding wins; an unbound name stands for itself, which is what makes an
   ordinary parameter reference work with no bookkeeping at all. *)
PROCEDURE ResolveLocal(name: ARRAY OF CHAR; VAR out: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  i := nRenames - 1;
  WHILE i >= 0 DO
    IF renZil[i] = name THEN Strings.Copy(renZap[i], out); RETURN END;
    DEC(i)
  END;
  Strings.Copy(name, out)
END ResolveLocal;

(* Allocates a ZAP local for a PROG/REPEAT binding of `zilName` and pushes
   the rename that makes references to it resolve there. Reuses an
   out-of-scope local previously allocated for the same ZIL name, so sibling
   blocks binding the same name share one slot rather than each burning
   another of the routine's fifteen. Only when the name is genuinely in use
   does it get a distinct one (NAME?1, NAME?2, ...) — the original's
   MakeUniqueVariableName does the same, and it matters because a binding
   may legitimately shadow a parameter. *)
PROCEDURE AllocInnerLocal(zilName: ARRAY OF CHAR): BOOLEAN;
VAR i, k: INTEGER; cand: ARRAY 512 OF CHAR; num: ARRAY 64 OF CHAR; taken: BOOLEAN;
BEGIN
  IF nRenames >= MaxRenames THEN
    Err("CompileStmt: too many nested bindings"); RETURN FALSE
  END;

  (* Reuse an out-of-scope slot — preferring one created for this same ZIL
     name, so the generated code stays readable, but taking ANY free inner
     local otherwise. The ZAP name is arbitrary (the rename stack is what
     connects it to the ZIL name), and a routine only gets fifteen locals,
     so not reusing them runs out on real library routines. This is the
     original's SpareLocals. *)
  i := nParams;
  WHILE i < nLocals DO
    IF ~locInScope[i] & (locZil[i] = zilName) THEN
      locInScope[i] := TRUE;
      Strings.Copy(zilName, renZil[nRenames]);
      Strings.Copy(locName[i], renZap[nRenames]);
      INC(nRenames);
      RETURN TRUE
    END;
    INC(i)
  END;
  i := nParams;
  WHILE i < nLocals DO
    IF ~locInScope[i] THEN
      locInScope[i] := TRUE;
      Strings.Copy(zilName, locZil[i]);
      Strings.Copy(zilName, renZil[nRenames]);
      Strings.Copy(locName[i], renZap[nRenames]);
      INC(nRenames);
      RETURN TRUE
    END;
    INC(i)
  END;

  IF nLocals >= MaxLocals THEN
    (* Report what the routine is competing for: the Z-machine allows
       fifteen locals per routine, and a library routine can use all of
       them for its own variables and loop counters, leaving none for a
       compiler temporary. *)
    Strings.Copy("out of locals (15 max) allocating ", cand);
    Strings.Append(zilName, cand);
    Strings.Append(" for ", cand); Strings.Append(tmpWhy, cand);
    Strings.Append("; in use:", cand);
    i := 0;
    WHILE i < nLocals DO
      Strings.Append(" ", cand); Strings.Append(locName[i], cand);
      INC(i)
    END;
    Err(cand); RETURN FALSE
  END;

  Strings.Copy(zilName, cand);
  k := 0;
  LOOP
    taken := FALSE;
    i := 0;
    WHILE i < nLocals DO
      IF locName[i] = cand THEN taken := TRUE END;
      INC(i)
    END;
    IF ~taken THEN EXIT END;
    INC(k);
    Strings.IntToStr(k, num);
    Strings.Copy(zilName, cand); Strings.Append("?", cand); Strings.Append(num, cand)
  END;

  Strings.Copy(cand, locName[nLocals]);
  Strings.Copy(zilName, locZil[nLocals]);
  locInit[nLocals][0] := 0X;
  locExpr[nLocals] := NIL;
  locInScope[nLocals] := TRUE;
  INC(nLocals);

  Strings.Copy(zilName, renZil[nRenames]);
  Strings.Copy(cand, renZap[nRenames]);
  INC(nRenames);
  RETURN TRUE
END AllocInnerLocal;

(* Ends the scope of the innermost `count` bindings. *)
PROCEDURE PopInnerLocals(count: INTEGER);
VAR i, j: INTEGER;
BEGIN
  WHILE count > 0 DO
    DEC(nRenames);
    i := nParams;
    WHILE i < nLocals DO
      IF locName[i] = renZap[nRenames] THEN locInScope[i] := FALSE END;
      INC(i)
    END;
    DEC(count)
  END;
  j := 0
END PopInnerLocals;

(* True when compiling `z` as an operand is guaranteed to push nothing onto
   the Z-machine stack, so an earlier operand already sitting there is safe.
   Over-approximates slightly (<VALUE X>, <INC X> and a few others emit no
   push either but are not listed) — the cost of being wrong in this
   direction is one extra spill instruction, never wrong code. *)
PROCEDURE IsSimpleOperand(z: ZilObj.Zo): BOOLEAN;
BEGIN
  IF z = NIL THEN RETURN FALSE END;
  IF (z.kind = ZilObj.KFix) OR (z.kind = ZilObj.KChar)
     OR (z.kind = ZilObj.KFalse) OR (z.kind = ZilObj.KAtom) THEN RETURN TRUE END;
  RETURN (z.kind = ZilObj.KForm) & (ZilObj.ListLength(z) = 2)
         & (ZilObj.IsAtomNamed(z.first, "LVAL") OR ZilObj.IsAtomNamed(z.first, "GVAL"))
END IsSimpleOperand;

(* Called after BOTH operands of a binary instruction have been compiled and
   both turned out to be on the stack. They are in the wrong order there —
   the right one is on top — so popping it into a temporary leaves the left
   one on top and the pair usable.

   Doing the fix-up here rather than spilling the left operand speculatively
   before the right is compiled matters: this emitter has the invariant that
   a compiled operand leaves a value on the stack EXACTLY when it returns
   "STACK", so "would the right operand disturb the left" is knowable
   afterwards and only guessable before. Guessing cost a temporary on every
   compound right operand, and a routine has only fifteen locals. *)
PROCEDURE FixStackedPair(VAR leftText, rightText: ARRAY OF CHAR;
                         commutative: BOOLEAN): BOOLEAN;
VAR tmp: ARRAY 16 OF CHAR;
BEGIN
  IF (leftText # "STACK") OR (rightText # "STACK") THEN RETURN TRUE END;
  (* For a COMMUTATIVE operation the reversed order is the same answer, so
     no fix-up and no temporary is needed at all. That matters beyond
     tidiness: zillib's MATCH-NOUN-PHRASE already uses all fifteen locals
     for its own variables and two nested loop counters, so a temporary it
     doesn't need is the difference between compiling and not. *)
  IF commutative THEN RETURN TRUE END;
  Strings.Copy("a non-commutative op with both operands stacked", tmpWhy);
  AllocTemp(tmp);
  IF nLocals > MaxLocals THEN
    Err("out of locals: FixStackedPair");
    RETURN FALSE
  END;
  W("	SET '"); W(tmp); W(",STACK"); WLn;   (* pops the RIGHT operand *)
  Strings.Copy(tmp, rightText);
  FreeTemp;
  RETURN TRUE
END FixStackedPair;

(* True when compiling `z` cannot be observed except through its value: no
   assignment, no object-tree change, no output, no call (a call could do any
   of those), no RANDOM. Conservative — an unlisted head is assumed impure.

   This is what makes reordering an argument list legal. The original notes
   the same opportunity as a TODO in its own SetValueOp ("recognize when the
   evaluation order doesn't matter and swap them"). *)
PROCEDURE IsPureOperand(z: ZilObj.Zo): BOOLEAN;
VAR nm: ARRAY 64 OF CHAR; p: ZilObj.Zo;
BEGIN
  IF z = NIL THEN RETURN TRUE END;
  IF (z.kind = ZilObj.KFix) OR (z.kind = ZilObj.KChar) OR (z.kind = ZilObj.KFalse)
     OR (z.kind = ZilObj.KAtom) OR (z.kind = ZilObj.KString)
     OR (z.kind = ZilObj.KTable) THEN RETURN TRUE END;
  IF z.kind # ZilObj.KForm THEN RETURN FALSE END;
  IF ZilObj.IsEmpty(z) THEN RETURN TRUE END;
  IF (z.first = NIL) OR (z.first.kind # ZilObj.KAtom) THEN RETURN FALSE END;
  Strings.Copy(z.first.atomText, nm);

  IF ~((nm = "LVAL") OR (nm = "GVAL") OR (nm = "VALUE")
     OR (nm = "+") OR (nm = "-") OR (nm = "*") OR (nm = "/") OR (nm = "MOD")
     OR (nm = "ORB") OR (nm = "BOR") OR (nm = "ANDB") OR (nm = "BAND")
     OR (nm = "BCOM") OR (nm = "ASH") OR (nm = "ASHIFT") OR (nm = "SHIFT")
     OR (nm = "GET") OR (nm = "NTH") OR (nm = "ZGET") OR (nm = "GETB") OR (nm = "ZGETB")
     OR (nm = "GETP") OR (nm = "GETPT") OR (nm = "NEXTP") OR (nm = "PTSIZE")
     OR (nm = "LOC") OR (nm = "FIRST?") OR (nm = "NEXT?") OR (nm = "INTBL?")
     OR (nm = "REST") OR (nm = "ZREST") OR (nm = "BACK") OR (nm = "ZBACK")
     OR (nm = "ZERO?") OR (nm = "0?") OR (nm = "1?")
     OR (nm = "EQUAL?") OR (nm = "=?") OR (nm = "==?")
     OR (nm = "N==?") OR (nm = "N=?")
     OR (nm = "L?") OR (nm = "G?") OR (nm = "L=?") OR (nm = "G=?")
     OR (nm = "FSET?") OR (nm = "IN?") OR (nm = "BTST")
     OR (nm = "NOT") OR (nm = "F?") OR (nm = "T?")) THEN
    RETURN FALSE
  END;

  p := z.rest;
  WHILE (p # NIL) & (p.first # NIL) DO
    IF ~IsPureOperand(p.first) THEN RETURN FALSE END;
    p := p.rest
  END;
  RETURN TRUE
END IsPureOperand;

(* True when every one of an instruction's argument forms is side-effect-free
   AND at least two of them will end up on the stack — the case where
   compiling them in REVERSE order costs nothing and saves a temporary. The
   stack then holds them bottom-to-top as last..first, which is exactly the
   order the instruction pops them in. *)
PROCEDURE CanReverseArgs(args: ZilObj.Zo; maxN: INTEGER): BOOLEAN;
VAR p: ZilObj.Zo; nPush, n: INTEGER;
BEGIN
  nPush := 0; n := 0; p := args;
  WHILE (p # NIL) & (p.first # NIL) & (n < maxN) DO
    IF ~IsPureOperand(p.first) THEN RETURN FALSE END;
    IF ~IsSimpleOperand(p.first) THEN INC(nPush) END;
    INC(n); p := p.rest
  END;
  RETURN nPush >= 2
END CanReverseArgs;

(* Compiles an instruction's argument list into `a`, choosing the evaluation
   order that needs the fewest temporaries, and returns how many
   temporaries the caller must release after emitting the instruction.

   Every argument is compiled BEFORE the instruction line starts being
   written, because an argument can be a compound expression that emits
   instructions of its own. *)
PROCEDURE CompileArgs(args: ZilObj.Zo; maxN: INTEGER; VAR a: ArgList;
                      VAR nArgs, nTemps: INTEGER): BOOLEAN;
VAR p: ZilObj.Zo; i: INTEGER; ok: BOOLEAN;
    forms: ARRAY 8 OF ZilObj.Zo;
BEGIN
  nArgs := 0; nTemps := 0;
  p := args;
  WHILE (p # NIL) & (p.first # NIL) DO
    IF nArgs >= maxN THEN RETURN FALSE END;    (* caller reports the arity *)
    forms[nArgs] := p.first; INC(nArgs);
    p := p.rest
  END;

  IF CanReverseArgs(args, maxN) THEN
    (* all side-effect-free and at least two will push: compiling them
       backwards leaves the stack in exactly the order the instruction pops *)
    i := nArgs - 1;
    WHILE i >= 0 DO
      ok := CompileOperand(forms[i], a[i]);
      IF ~ok THEN RETURN FALSE END;
      DEC(i)
    END;
    RETURN TRUE
  END;

  i := 0;
  WHILE i < nArgs DO
    ok := CompileOperand(forms[i], a[i]);
    IF ~ok THEN RETURN FALSE END;
    INC(i)
  END;
  RETURN FixStackedArgs(a, nArgs, nTemps)
END CompileArgs;

(* Fixes up an instruction's argument list after all of it has been
   compiled. Arguments that ended up on the stack are there in the order
   they were pushed, so the LAST one is on top — the reverse of the order
   the instruction reads them in. Popping all but the deepest into
   temporaries puts them back in order, and the deepest can stay where it
   is.

   Like FixStackedPair, this runs AFTER the arguments are compiled rather
   than guessing beforehand, which matters for how many locals it costs: the
   old rule spilled an argument whenever a later one *might* push, and so
   took a temporary even when only one argument ended up stacked and none
   was needed. K stacked arguments now cost K-1 temporaries, and the common
   K=1 costs none. `nTemps` is how many the caller must release once the
   instruction is emitted. *)
PROCEDURE FixStackedArgs(VAR a: ArgList; nArgs: INTEGER;
                         VAR nTemps: INTEGER): BOOLEAN;
VAR i, firstStacked, nStacked: INTEGER; tmp: ARRAY 16 OF CHAR;
BEGIN
  nTemps := 0;
  nStacked := 0; firstStacked := -1;
  FOR i := 0 TO nArgs - 1 DO
    IF a[i] = "STACK" THEN
      INC(nStacked);
      IF firstStacked < 0 THEN firstStacked := i END
    END
  END;
  IF nStacked <= 1 THEN RETURN TRUE END;

  (* pop from the top down, i.e. from the last stacked argument backwards,
     leaving the first (deepest) one on the stack *)
  i := nArgs - 1;
  WHILE i > firstStacked DO
    IF a[i] = "STACK" THEN
      Strings.Copy("an argument spilled off the stack", tmpWhy);
      AllocTemp(tmp);
      IF nLocals > MaxLocals THEN
        Err("out of locals: FixStackedArgs"); RETURN FALSE
      END;
      W("	SET '"); W(tmp); W(",STACK"); WLn;
      Strings.Copy(tmp, a[i]);
      INC(nTemps)
    END;
    DEC(i)
  END;
  RETURN TRUE
END FixStackedArgs;

(* Moves an operand already sitting on the stack into a fresh temporary, so
   a later operand of the same instruction can use the stack without the two
   coming back off it in the wrong order. Returns FALSE (with the error set)
   only if the routine has run out of Z-machine locals. *)
PROCEDURE SpillToTemp(VAR text: ARRAY OF CHAR): BOOLEAN;
VAR tmp: ARRAY 16 OF CHAR;
BEGIN
  Strings.Copy("an argument spilled off the stack", tmpWhy);
  AllocTemp(tmp);
  IF nLocals > MaxLocals THEN
    Err("out of locals: SpillToTemp");
    RETURN FALSE
  END;
  W("	SET '"); W(tmp); W(",STACK"); WLn;
  Strings.Copy(tmp, text);
  RETURN TRUE
END SpillToTemp;

(* The builtins CompileStmt handles itself. CompileOperand delegates these
   to it rather than duplicating them, because they are perfectly usable as
   VALUES too — <SET X <COND ...>> and <+ <PROG () ...> 1> are ordinary ZIL
   — and CompileStmt already knows how to leave a result behind. The two
   procedures are mutually recursive as a result; the recursion terminates
   because CompileStmt only falls back to CompileOperand for heads that are
   NOT in this list. *)
(* The builtins that are BRANCH instructions — they answer a question and
   have no value of their own. Used as a value (`<SET X <FSET? .O ,BIT>>`),
   the branch has to be turned into a 1 or a 0, which is what
   CompileOperand does with them; used as a condition they compile to the
   branch directly, which is what CompileCondition does. The original draws
   the same distinction, as its PredCall vs ValueCall builtin classes. *)
PROCEDURE IsPredicateBuiltin(name: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN (name = "ZERO?") OR (name = "0?") OR (name = "1?")
      OR (name = "EQUAL?") OR (name = "=?") OR (name = "==?")
      OR (name = "N==?") OR (name = "N=?")
      OR (name = "L?") OR (name = "G?") OR (name = "L=?") OR (name = "G=?")
      OR (name = "FSET?") OR (name = "IN?") OR (name = "BTST")
      OR (name = "IGRTR?") OR (name = "DLESS?")
      OR (name = "NOT") OR (name = "F?") OR (name = "T?")
      OR (name = "SAVE") OR (name = "RESTORE") OR (name = "VERIFY")
      OR (name = "ORIGINAL?")
END IsPredicateBuiltin;

(* The header ("low core") fields LOWCORE and LOWCORE-TABLE can name,
   ported from the original's LowCoreField table. `offset` comes back as a
   WORD offset unless `isByte` is set, in which case it is a byte offset.
   `minVer`/`maxVer` bound the Z-machine versions the field exists in, with
   maxVer 0 meaning no upper bound.

   The V5+ header-EXTENSION fields (MSLOCX and the mouse/menu group) are
   deliberately absent: reading one needs EXTAB indirection plus a minimum
   extension length reserved in the header, and nothing in the corpus this
   port targets uses them. MEMSIZE is absent for the same reason it is
   absent from the original's table - it is a Glulx-only field. *)
PROCEDURE LowCoreField(name: ARRAY OF CHAR; VAR offset: INTEGER;
                       VAR isByte, writable: BOOLEAN;
                       VAR minVer, maxVer: INTEGER): BOOLEAN;
BEGIN
  isByte := FALSE; writable := FALSE; minVer := 3; maxVer := 0;
  IF name = "ZVERSION" THEN offset := 0
  ELSIF (name = "ZORKID") OR (name = "RELEASEID") THEN offset := 1
  ELSIF name = "ENDLOD" THEN offset := 2
  ELSIF name = "START" THEN offset := 3
  ELSIF name = "VOCAB" THEN offset := 4
  ELSIF name = "OBJECT" THEN offset := 5
  ELSIF name = "GLOBALS" THEN offset := 6
  ELSIF name = "PURBOT" THEN offset := 7
  ELSIF name = "FLAGS" THEN offset := 8; writable := TRUE
  ELSIF name = "SERIAL" THEN offset := 9
  ELSIF name = "SERI1" THEN offset := 10
  ELSIF name = "SERI2" THEN offset := 11
  ELSIF name = "FWORDS" THEN offset := 12
  ELSIF name = "PLENTH" THEN offset := 13
  ELSIF name = "PCHKSM" THEN offset := 14
  ELSIF name = "INTWRD" THEN offset := 15
  ELSIF name = "INTID" THEN offset := 30; isByte := TRUE
  ELSIF name = "INTVR" THEN offset := 31; isByte := TRUE
  ELSIF name = "SCRWRD" THEN offset := 16; minVer := 4
  ELSIF name = "SCRV" THEN offset := 32; isByte := TRUE; minVer := 4
  ELSIF name = "SCRH" THEN offset := 33; isByte := TRUE; minVer := 4
  ELSIF name = "HWRD" THEN offset := 17; minVer := 5
  ELSIF name = "VWRD" THEN offset := 18; minVer := 5
  ELSIF name = "FWRD" THEN offset := 19; minVer := 5
  ELSIF name = "LMRG" THEN offset := 20; minVer := 5; maxVer := 5
  ELSIF name = "FOFF" THEN offset := 20; minVer := 5
  ELSIF name = "RMRG" THEN offset := 21; minVer := 5; maxVer := 5
  ELSIF name = "SOFF" THEN offset := 21; minVer := 5
  ELSIF name = "CLRWRD" THEN offset := 22; minVer := 5
  ELSIF name = "TCHARS" THEN offset := 23; minVer := 5
  ELSIF name = "CRCNT" THEN offset := 24; writable := TRUE; minVer := 5; maxVer := 5
  ELSIF name = "TWID" THEN offset := 24; minVer := 6
  ELSIF name = "CRFUNC" THEN offset := 25; writable := TRUE; minVer := 5; maxVer := 5
  ELSIF name = "CHRSET" THEN offset := 26; minVer := 5
  ELSIF name = "EXTAB" THEN offset := 27; minVer := 5
  ELSIF name = "STDREV" THEN offset := 25
  ELSE RETURN FALSE
  END;
  RETURN TRUE
END LowCoreField;

(* Resolves a LOWCORE field specifier to a byte-or-word offset from address
   zero. The specifier is either a bare field atom, or a two-element list
   `(FIELD 0)` / `(FIELD 1)` naming the high or low BYTE of a word field -
   which is why the result always reports whether the access is byte-sized.
   `who` only names the caller in error messages. *)
PROCEDURE LowCoreSpec(who: ARRAY OF CHAR; spec: ZilObj.Zo; writing: BOOLEAN;
                      VAR offset: INTEGER; VAR isByte: BOOLEAN): BOOLEAN;
VAR name: ARRAY 64 OF CHAR; errBuf: ARRAY 256 OF CHAR;
    writable: BOOLEAN; minVer, maxVer, half: INTEGER;
BEGIN
  half := -1;
  IF (spec # NIL) & (spec.kind = ZilObj.KAtom) THEN
    Strings.Copy(spec.atomText, name)
  ELSIF (spec # NIL) & (spec.kind = ZilObj.KList) & (spec.first # NIL)
        & (spec.first.kind = ZilObj.KAtom) & (spec.rest # NIL)
        & (spec.rest.first # NIL) & (spec.rest.first.kind = ZilObj.KFix)
        & ((spec.rest.first.fixVal = 0) OR (spec.rest.first.fixVal = 1)) THEN
    Strings.Copy(spec.first.atomText, name);
    half := spec.rest.first.fixVal
  ELSE
    Strings.Copy(who, errBuf);
    Strings.Append(": field must be an atom or a (FIELD 0|1) list", errBuf);
    Err(errBuf); RETURN FALSE
  END;

  IF ~LowCoreField(name, offset, isByte, writable, minVer, maxVer) THEN
    Strings.Copy(who, errBuf);
    Strings.Append(": unrecognized header field: ", errBuf);
    Strings.Append(name, errBuf);
    Err(errBuf); RETURN FALSE
  END;
  IF (ZilModel.zversion < minVer) OR ((maxVer > 0) & (ZilModel.zversion > maxVer)) THEN
    Strings.Copy(who, errBuf);
    Strings.Append(": header field not available in this Z-machine version: ", errBuf);
    Strings.Append(name, errBuf);
    Err(errBuf); RETURN FALSE
  END;
  IF writing & ~writable THEN
    Strings.Copy(who, errBuf);
    Strings.Append(": header field is not writable: ", errBuf);
    Strings.Append(name, errBuf);
    Err(errBuf); RETURN FALSE
  END;
  IF half >= 0 THEN
    IF isByte THEN
      Strings.Copy(who, errBuf);
      Strings.Append(": header field is not a word field: ", errBuf);
      Strings.Append(name, errBuf);
      Err(errBuf); RETURN FALSE
    END;
    offset := offset * 2 + half;
    isByte := TRUE
  END;
  RETURN TRUE
END LowCoreSpec;

(* Rewrites <LOWCORE FIELD> into <GET 0 offset> / <GETB 0 offset> and
   <LOWCORE FIELD value> into <PUT 0 offset value> / <PUTB 0 offset value>,
   which the ordinary builtin paths already compile - including into a
   destination. The original does the same thing by emitting the binary or
   ternary op directly; going through a rewritten FORM here keeps LOWCORE
   out of every code path that already knows how to place a GET's result. *)
PROCEDURE LowCoreRewrite(z: ZilObj.Zo; VAR out: ZilObj.Zo): BOOLEAN;
VAR offset: INTEGER; isByte, writing: BOOLEAN;
    opcode: ARRAY 16 OF CHAR; args: ZilObj.Zo;
BEGIN
  out := NIL;
  IF (z.rest = NIL) OR (z.rest.first = NIL) THEN
    Err("LOWCORE: expected a header field name"); RETURN FALSE
  END;
  writing := (z.rest.rest # NIL) & (z.rest.rest.first # NIL);
  IF ~LowCoreSpec("LOWCORE", z.rest.first, writing, offset, isByte) THEN
    RETURN FALSE
  END;
  IF writing THEN
    IF isByte THEN Strings.Copy("PUTB", opcode) ELSE Strings.Copy("PUT", opcode) END;
    args := ZilObj.Cons(ZilObj.KForm, z.rest.rest.first, NIL)
  ELSE
    IF isByte THEN Strings.Copy("GETB", opcode) ELSE Strings.Copy("GET", opcode) END;
    args := NIL
  END;
  args := ZilObj.Cons(ZilObj.KForm, ZilObj.NewFix(offset), args);
  args := ZilObj.Cons(ZilObj.KForm, ZilObj.NewFix(0), args);
  out := ZilObj.Cons(ZilObj.KForm, ZilObj.Intern(opcode), args);
  RETURN TRUE
END LowCoreRewrite;

(* Whether `z` is a FORM that merely NAMES a variable - `.X` or `,X`, which
   read as <LVAL X> and <GVAL X>. The original calls the opposite of this
   IsNonVariableForm, and several places need the distinction: a DO loop's
   end is a PREDICATE when it is a real form but a VALUE to compare against
   when it is just a variable reference. Treating `<DO (I 0 .LEN) ...>`'s
   bound as a predicate compiles to "branch out while LEN is true", which
   runs the body zero times or forever - and zillib's COPY-TABLE is written
   exactly that way, so nothing the parser copies between buffers arrives. *)
PROCEDURE IsVarRefForm(z: ZilObj.Zo): BOOLEAN;
BEGIN
  RETURN (z # NIL) & (z.kind = ZilObj.KForm) & (ZilObj.ListLength(z) = 2)
       & (z.first # NIL) & (z.first.kind = ZilObj.KAtom)
       & ((z.first.atomText = "LVAL") OR (z.first.atomText = "GVAL"))
END IsVarRefForm;

(* Finds the innermost open block whose activation atom is `name`, for a
   named <AGAIN .NAME> / <RETURN value .NAME> — MDL's way of targeting an
   OUTER loop from inside a nested one, rather than the reflexive "innermost
   block" AGAIN/RETURN default to. Searches innermost-first, matching lexical
   shadowing: an inner block reusing an outer activation atom's name (legal,
   if unusual) should win. *)
PROCEDURE FindNamedBlock(name: ARRAY OF CHAR): INTEGER;
VAR i: INTEGER;
BEGIN
  i := nBlocks - 1;
  WHILE (i >= 0) & ((blockNames[i][0] = 0X) OR (blockNames[i] # name)) DO DEC(i) END;
  RETURN i
END FindNamedBlock;

(* The block-name argument AGAIN/RETURN accept, written `.NAME` (an LVAL of
   the activation atom) in real source. Returns "" (no target requested)
   when `z` isn't shaped like one, so the caller can fall back to "innermost"
   exactly as before. *)
PROCEDURE BlockTargetName(z: ZilObj.Zo; VAR name: ARRAY OF CHAR): BOOLEAN;
BEGIN
  name[0] := 0X;
  IF (z = NIL) OR (z.kind # ZilObj.KForm) OR (ZilObj.ListLength(z) # 2)
     OR (z.first = NIL) OR (z.first.kind # ZilObj.KAtom)
     OR (z.first.atomText # "LVAL") OR (z.rest.first = NIL)
     OR (z.rest.first.kind # ZilObj.KAtom) THEN
    RETURN FALSE
  END;
  Strings.Copy(z.rest.first.atomText, name);
  RETURN TRUE
END BlockTargetName;

PROCEDURE IsLowCore(z: ZilObj.Zo): BOOLEAN;
BEGIN
  RETURN (z # NIL) & (z.kind = ZilObj.KForm) & (z.first # NIL)
       & (z.first.kind = ZilObj.KAtom) & (z.first.atomText = "LOWCORE")
END IsLowCore;

PROCEDURE IsStatementBuiltin(name: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN (name = "COND") OR (name = "PROG") OR (name = "REPEAT") OR (name = "BIND")
      OR (name = "DO") OR (name = "MAP-CONTENTS") OR (name = "MAP-DIRECTIONS")
      OR (name = "TELL") OR (name = "SET") OR (name = "SETG")
      OR (name = "RETURN") OR (name = "AGAIN") OR (name = "QUIT")
      OR (name = "RTRUE") OR (name = "RFALSE") OR (name = "RSTACK")
      OR (name = "PRINTI") OR (name = "PRINTR") OR (name = "PRINTN")
      OR (name = "PRINTC") OR (name = "CRLF")
      OR (name = "LOWCORE") OR (name = "LOWCORE-TABLE") OR (name = "QUOTE")
END IsStatementBuiltin;

(* Compiles `z` as a value-producing expression, emitting whatever
   instructions are needed and returning the ZAP operand text that holds
   the result (a literal number, a local variable's bare name, or
   "STACK" for a compound sub-expression). Self-recursive (calls itself
   for each operand of a nested arithmetic FORM) — this transpiler has no
   FORWARD declarations, same reason as every other self-recursive
   procedure throughout this port (ZilRead.ReadOne, ZilEval.EvalImpl). *)
PROCEDURE CompileOperand(z: ZilObj.Zo; VAR opText: ARRAY OF CHAR): BOOLEAN;
VAR leftText, rightText: ARRAY 64 OF CHAR; opcode: ARRAY 16 OF CHAR;
    headName: ARRAY 64 OF CHAR; argTexts: ArgList; errBuf: ARRAY 256 OF CHAR;
    andTmp, andEnd: ARRAY 16 OF CHAR;
    ok, spilled, simpleStore, restDefault: BOOLEAN;
    nArgs, i, nSpills, maxArgs, simpleN: INTEGER; ap, ap2: ZilObj.Zo;
BEGIN
  IF z = NIL THEN Err("CompileOperand: NIL expression"); RETURN FALSE END;

  IF z.kind = ZilObj.KFix THEN
    FixText(z.fixVal, opText); RETURN TRUE

  ELSIF z.kind = ZilObj.KChar THEN
    (* the original's CompileConstant maps a CHARACTER straight to its ZSCII
       code (Game.MakeOperand(ch.Char)) — same here *)
    FixText(z.charVal, opText); RETURN TRUE

  ELSIF (z.kind = ZilObj.KFalse) OR ((z.kind = ZilObj.KForm) & ZilObj.IsEmpty(z)) THEN
    (* `<>` is FALSE. The evaluator turns an empty FORM into FALSE when it
       sees one, but a routine body is never evaluated, so the literal
       `<SET OK <>>` in real source arrives here still shaped as an empty
       FORM — both spellings have to compile to 0. *)
    Strings.Copy("0", opText); RETURN TRUE

  ELSIF z.kind = ZilObj.KString THEN
    (* a STRING used as an operand is its packed address — the pool gives
       it a symbol, and .GSTR gives that symbol a value *)
    IF ConstantText(z, opText) THEN RETURN TRUE END;
    Err("CompileOperand: could not intern a string constant"); RETURN FALSE

  ELSIF z.kind = ZilObj.KTable THEN
    (* a TABLE value used directly as an operand — which happens once macro
       expansion has substituted a global's value into a routine body —
       compiles to the label that table is emitted under *)
    IF ConstantText(z, opText) THEN RETURN TRUE END;
    Err("CompileOperand: a TEMP-TABLE has no address to take"); RETURN FALSE

  ELSIF z.kind = ZilObj.KAtom THEN
    (* A bare atom in operand position is a compile-time constant: T, a
       routine, an object, or a CONSTANT (never a variable — variables are
       always written .X or ,X in real source). *)
    IF ConstantText(z, opText) THEN RETURN TRUE END;
    Err("CompileOperand: unknown constant/routine/object name"); RETURN FALSE

  ELSIF (z.kind = ZilObj.KForm) & (ZilObj.ListLength(z) = 2)
        & ZilObj.IsAtomNamed(z.first, "LVAL") THEN
    (* .X -> the local variable named X, referenced by its bare ZAP name *)
    IF z.rest.first.kind # ZilObj.KAtom THEN
      Err("CompileOperand: LVAL target must be an ATOM"); RETURN FALSE
    END;
    ResolveLocal(z.rest.first.atomText, opText); RETURN TRUE

  ELSIF (z.kind = ZilObj.KForm) & (ZilObj.ListLength(z) = 2)
        & ZilObj.IsAtomNamed(z.first, "GVAL") THEN
    (* ,X -> a GLOBAL variable's value, or (exactly as in the original's
       GvalOp, which resolves "constant, global, object, or routine") the
       named constant/object/routine. Both are the bare ZAP name: zapf
       resolves a .GVAR-declared name to a variable reference and any other
       symbol to its constant value, so one spelling covers both. *)
    IF z.rest.first.kind # ZilObj.KAtom THEN
      Err("CompileOperand: GVAL target must be an ATOM"); RETURN FALSE
    END;
    Strings.Copy(z.rest.first.atomText, headName);
    IF FindGlobalIdx(headName) >= 0 THEN Strings.Copy(headName, opText); RETURN TRUE END;
    IF ConstantText(z.rest.first, opText) THEN RETURN TRUE END;
    (* Real zilf's own GvalOp doesn't error here either - it falls back to
       compiling ,NAME as if it had been written .NAME (a bare LVAL is never
       validated at this level anyway; see LVAL's own comment just above -
       both trust zapf to catch a name that turns out not to be a real
       local), with only a warning ("no such global variable 'X', using the
       local instead"). Real library source relies on this: zillib's own
       status.zil has a PROG-bound local H referenced as ,H instead of .H
       (STATUS-LINE-SECTION?TIME-12H, a copy-paste bug that's been there for
       years) - erroring here instead of warning would make every V4+ game
       that pulls in status.zil (anything inserting "parser") fail to
       compile over a mistake in the library, not the game. *)
    Out.ErrString("zilf: warning: no such global variable '"); Out.ErrString(headName);
    Out.ErrString("', using the local instead"); Out.ErrLn;
    ResolveLocal(headName, opText); RETURN TRUE

  ELSIF z.kind = ZilObj.KForm THEN
    IF (z.first = NIL) OR (z.first.kind # ZilObj.KAtom) THEN
      Strings.Copy("CompileOperand: expected an operator atom in form head: ", errBuf);
      ZilObj.PrintTo(z, headName);
      Strings.Append(headName, errBuf);
      Err(errBuf); RETURN FALSE
    END;
    Strings.Copy(z.first.atomText, headName);

    IF IsStatementBuiltin(headName) THEN
      RETURN CompileStmt(z, TRUE, opText)

    ELSIF IsPredicateBuiltin(headName) THEN
      (* Materialise the branch as a value ON THE STACK, the same shape
         COND uses, rather than in a temporary: a routine has only fifteen
         locals and real library routines declare fourteen, so a predicate
         in value position must not cost one. *)
      NewLabel(andTmp); NewLabel(andEnd);
      ok := CompileCondition(z, andTmp, TRUE);
      IF ~ok THEN RETURN FALSE END;
      W("	PUSH 0"); WLn;
      EmitBranch(andEnd);
      W(andTmp); W(":"); WLn;
      W("	PUSH 1"); WLn;
      W(andEnd); W(":"); WLn;
      Strings.Copy("STACK", opText);
      RETURN TRUE

    ELSIF (headName = "+") OR (headName = "-") OR (headName = "*") OR (headName = "/")
       OR (headName = "MOD") OR (headName = "REST") OR (headName = "ZREST")
       OR (headName = "BACK") OR (headName = "ZBACK")
       OR (headName = "ORB") OR (headName = "BOR")
       OR (headName = "ANDB") OR (headName = "BAND") THEN
      (* N-ARY, folded left: <+ a b c> is (a+b)+c, which is what real source
         expects and what the original produces. One argument is special in
         two ways — <- x> is negation, and <REST t>/<BACK t> default their
         offset to 1 — and anything else with one argument is just that
         argument. *)
      IF (z.rest = NIL) OR (z.rest.first = NIL) THEN
        Err("CompileOperand: arithmetic op expects at least 1 arg"); RETURN FALSE
      END;
      IF (headName = "+") OR (headName = "REST") OR (headName = "ZREST") THEN
        Strings.Copy("ADD", opcode)
      ELSIF (headName = "-") OR (headName = "BACK") OR (headName = "ZBACK") THEN
        Strings.Copy("SUB", opcode)
      ELSIF headName = "*" THEN Strings.Copy("MUL", opcode)
      ELSIF headName = "MOD" THEN Strings.Copy("MOD", opcode)
      ELSIF (headName = "ORB") OR (headName = "BOR") THEN Strings.Copy("BOR", opcode)
      ELSIF (headName = "ANDB") OR (headName = "BAND") THEN Strings.Copy("BAND", opcode)
      ELSE Strings.Copy("DIV", opcode)
      END;

      ok := CompileOperand(z.rest.first, leftText);
      IF ~ok THEN RETURN FALSE END;
      ap := z.rest.rest;

      IF (ap = NIL) OR (ap.first = NIL) THEN
        IF headName = "-" THEN
          W("	SUB 0,"); W(leftText); W(" >STACK"); WLn;
          Strings.Copy("STACK", opText); RETURN TRUE
        END;
        IF (headName = "REST") OR (headName = "ZREST")
           OR (headName = "BACK") OR (headName = "ZBACK") THEN
          W("	"); W(opcode); W(" "); W(leftText); W(",1 >STACK"); WLn;
          Strings.Copy("STACK", opText); RETURN TRUE
        END;
        Strings.Copy(leftText, opText); RETURN TRUE
      END;

      WHILE (ap # NIL) & (ap.first # NIL) DO
        ok := CompileOperand(ap.first, rightText);
        IF ~ok THEN RETURN FALSE END;
        ok := FixStackedPair(leftText, rightText,
                             (opcode = "ADD") OR (opcode = "MUL")
                             OR (opcode = "BOR") OR (opcode = "BAND"));
        IF ~ok THEN RETURN FALSE END;
        W("	"); W(opcode); W(" "); W(leftText);
        W(","); W(rightText); W(" >STACK"); WLn;
        Strings.Copy("STACK", leftText);
        ap := ap.rest
      END;
      Strings.Copy("STACK", opText); RETURN TRUE

    ELSIF (headName = "AND") OR (headName = "OR") THEN
      (* As a VALUE, <OR a b c> is the first of them that is true (or the
         last if none are), and <AND a b c> is the first that is false (or
         the last if none are). That needs somewhere to hold the value while
         it is being tested, since the test must not consume it — hence a
         compiler temporary rather than the stack. *)
      IF (z.rest = NIL) OR (z.rest.first = NIL) THEN
        IF headName = "AND" THEN Strings.Copy("1", opText) ELSE Strings.Copy("0", opText) END;
        RETURN TRUE
      END;
      Strings.Copy("AND/OR in value position", tmpWhy);
      AllocTemp(andTmp);
      IF nLocals > MaxLocals THEN
        Err("out of locals: AND/OR as a value");
        RETURN FALSE
      END;
      NewLabel(andEnd);
      ap := z.rest;
      WHILE (ap # NIL) & (ap.first # NIL) DO
        ok := CompileOperand(ap.first, argTexts[0]);
        IF ~ok THEN RETURN FALSE END;
        W("	SET '"); W(andTmp); W(","); W(argTexts[0]); WLn;
        IF (ap.rest # NIL) & (ap.rest.first # NIL) THEN
          (* stop early: OR stops on a non-zero value, AND on a zero one *)
          Strings.Copy("", argTexts[1]);
          W("	ZERO? "); W(andTmp);
          IF headName = "OR" THEN W(" \") ELSE W(" /") END;
          W(andEnd); WLn
        END;
        ap := ap.rest
      END;
      W(andEnd); W(":"); WLn;
      FreeTemp;
      Strings.Copy(andTmp, opText);
      RETURN TRUE

    ELSIF headName = "VALUE" THEN
      (* <VALUE X> is "read the variable named X" — the original's ValueOp;
         for a plain named variable that's just the variable itself as an
         operand, no instruction needed. *)
      IF z.rest = NIL THEN
        Err("CompileOperand: VALUE expects an argument"); RETURN FALSE
      END;
      IF VarName(z.rest.first, opText) THEN
        (* a plain named variable is just that variable as an operand *)
        ResolveLocal(opText, opText);
        RETURN TRUE
      END;
      (* otherwise the argument computes a variable NUMBER, which is the
         indirect form of the load instruction *)
      ok := CompileOperand(z.rest.first, leftText);
      IF ~ok THEN RETURN FALSE END;
      W("	VALUE "); W(leftText); W(" >STACK"); WLn;
      Strings.Copy("STACK", opText);
      RETURN TRUE

    ELSIF (headName = "INC") OR (headName = "DEC") THEN
      (* INC/DEC in VALUE position: the Z-machine's own INC/DEC don't store,
         so read the variable back afterwards, matching the original's
         IncValueOp returning `victim` (the variable) as its result. *)
      IF (z.rest = NIL) OR ~VarName(z.rest.first, opText) THEN
        Err("CompileOperand: INC/DEC expects a variable name"); RETURN FALSE
      END;
      ResolveLocal(opText, opText);
      W("	"); W(headName); W(" '"); W(opText); WLn;
      RETURN TRUE

    ELSIF SimpleBuiltin(headName, opcode, simpleN, simpleStore) & simpleStore THEN
      (* compile every operand first (one may emit instructions of its own,
         which must not land inside the half-written instruction line), and
         spill any that a later operand could push over *)
      ok := CompileArgs(z.rest, simpleN, argTexts, nArgs, nSpills);
      IF ~ok & ~errFlag THEN nArgs := simpleN + 1 END;
      IF ~ok OR (nArgs > simpleN) OR (nArgs < BuiltinMinArgs(headName, simpleN)) THEN
        Strings.Copy("CompileOperand: wrong number of arguments to ", errBuf);
        Strings.Append(headName, errBuf);
        Err(errBuf); RETURN FALSE
      END;
      W("	"); W(opcode);
      i := 0;
      WHILE i < nArgs DO
        IF i = 0 THEN W(" ") ELSE W(",") END;
        W(argTexts[i]); INC(i)
      END;
      W(" >STACK");
      IF IsValuePredBuiltin(headName) THEN EmitDeadBranch ELSE WLn END;
      WHILE nSpills > 0 DO FreeTemp; DEC(nSpills) END;
      Strings.Copy("STACK", opText); RETURN TRUE

    ELSIF (headName = "APPLY") OR (headName = "CALL") OR (headName = "ZAPPLY") THEN
      (* <APPLY routine-expr args...> calls a routine whose address is
         computed rather than named, which is the same CALL instruction with
         its first operand compiled like any other. *)
      IF (z.rest = NIL) OR (z.rest.first = NIL) THEN
        Err("CompileOperand: APPLY expects a routine"); RETURN FALSE
      END;
      IF ZilModel.zversion < 4 THEN maxArgs := 4 ELSE maxArgs := 8 END;
      IF maxArgs > 8 THEN maxArgs := 8 END;
      ok := CompileArgs(z.rest, maxArgs, argTexts, nArgs, nSpills);
      IF ~ok THEN
        IF ~errFlag THEN
          Err("CompileOperand: too many APPLY arguments for this Z-machine version")
        END;
        RETURN FALSE
      END;
      W("	CALL "); W(argTexts[0]);
      i := 1;
      WHILE i < nArgs DO W(","); W(argTexts[i]); INC(i) END;
      W(" >STACK"); WLn;
      WHILE nSpills > 0 DO FreeTemp; DEC(nSpills) END;
      Strings.Copy("STACK", opText); RETURN TRUE

    ELSIF FindRoutineIdx(headName) >= 0 THEN
      (* A call to a ROUTINE this program defines. V3 has only the storing
         CALL opcode (max 3 arguments) — confirmed against the original's own
         EmitCall, which for zversion < 4 always emits CALL and pops the
         result with FSTACK when it isn't wanted (see CompileStmt for that
         void case). *)
      IF ZilModel.zversion < 4 THEN maxArgs := 3 ELSE maxArgs := 7 END;
      IF maxArgs > 8 THEN maxArgs := 8 END;
      ok := CompileArgs(z.rest, maxArgs, argTexts, nArgs, nSpills);
      IF ~ok THEN
        IF ~errFlag THEN
          Err("CompileOperand: too many call arguments for this Z-machine version")
        END;
        RETURN FALSE
      END;
      (* V1-3 have only CALL; V4 splits it by argument count into
         CALL1/CALL2/CALL/XCALL — the same switch as the original's
         EmitCall. (V5+, which would also use the non-storing ICALL forms,
         isn't emitted yet; CompileProgram refuses those versions.) *)
      IF ZilModel.zversion < 4 THEN Strings.Copy("CALL", opcode)
      ELSIF nArgs = 0 THEN Strings.Copy("CALL1", opcode)
      ELSIF nArgs = 1 THEN Strings.Copy("CALL2", opcode)
      ELSIF nArgs <= 3 THEN Strings.Copy("CALL", opcode)
      ELSE Strings.Copy("XCALL", opcode)
      END;
      W("	"); W(opcode); W(" "); WSym(headName);
      i := 0;
      WHILE i < nArgs DO
        W(","); W(argTexts[i]); INC(i)
      END;
      W(" >STACK"); WLn;
      WHILE nSpills > 0 DO FreeTemp; DEC(nSpills) END;
      Strings.Copy("STACK", opText); RETURN TRUE

    ELSIF SimpleBuiltin(headName, opcode, simpleN, simpleStore) & ~simpleStore THEN
      (* A void-only builtin used as a VALUE — the library writes
         <AND <DIROUT 2> ...>. The original compiles the void call and then
         yields TRUE (Compilation.Expressions' `CompileVoidCall(...);
         return Game.One`), so the surrounding AND sees a true value and
         carries on. CompileStmt already knows how to emit the call. *)
      ok := CompileStmt(z, FALSE, errBuf);
      IF ~ok THEN RETURN FALSE END;
      Strings.Copy("1", opText); RETURN TRUE

    ELSIF IsTableBuiltin(headName) THEN
      (* the table itself was built in PrepareRoutines; all that is left is
         to name it *)
      ap := ZilObj.GetProp(z, InlineTableMarker());
      IF (ap = NIL) OR (ap.kind # ZilObj.KTable) THEN
        Err("CompileOperand: an inline table was not prepared"); RETURN FALSE
      END;
      i := FindTableIdx(ap);
      IF i < 0 THEN
        Err("CompileOperand: an inline table was not registered"); RETURN FALSE
      END;
      TableLabel(i, opText); RETURN TRUE

    ELSE
      Strings.Copy("CompileOperand: unrecognized or not-yet-implemented builtin: ", errBuf);
      Strings.Append(headName, errBuf);
      Err(errBuf); RETURN FALSE
    END

  ELSE
    Strings.Copy("CompileOperand: expression of this kind cannot be compiled yet: ", errBuf);
    ZilObj.PrintTo(z, headName);
    Strings.Append(headName, errBuf);
    Err(errBuf); RETURN FALSE
  END
END CompileOperand;

(* Emits an unconditional branch to `label` — matches the original's
   `rb.Branch(label)`. *)
PROCEDURE EmitBranch(label: ARRAY OF CHAR);
BEGIN W("	JUMP "); W(label); WLn END EmitBranch;

(* Emits a predicate instruction (op1[,op2]) branching to `label` when the
   condition holds and `polarity` is TRUE, or when it does NOT hold and
   `polarity` is FALSE — i.e. always: "go to label iff (condition-holds) =
   polarity". Matches zapf's own branch-marker convention confirmed
   earlier from ZapfParser.mod: "/label" branches on true, "\label" on
   false. Pass an empty `op2` for a 1-operand predicate like ZERO?. *)
PROCEDURE EmitPredInstr(opcode, op1, op2, label: ARRAY OF CHAR; polarity: BOOLEAN);
BEGIN
  W("	"); W(opcode);
  IF op1[0] # 0X THEN W(" "); W(op1) END;
  IF op2[0] # 0X THEN W(","); W(op2) END;
  IF polarity THEN W(" /") ELSE W(" \") END;
  W(label); WLn
END EmitPredInstr;

(* Compiles `z` as a CONDITION: emits whatever instructions are needed so
   that control reaches `label` exactly when z's truth value equals
   `polarity` (matches the original's own CompileCondition contract
   exactly — same name, same two-argument label+polarity shape). Ported
   the common real-source predicate builtins directly to their ZAP
   mnemonics (confirmed against ~/cloak_plus.zap's own usage): ZIL
   "ZERO?"/"EQUAL?"("=?"/"==?")/"L?"/"G?" are ZAP's own "ZERO?"/"EQUAL?"/
   "LESS?"/"GRTR?" — note L?/G? really do rename to LESS?/GRTR? in ZAP,
   they aren't the same spelling. EQUAL? here only supports exactly 2 args
   (the real EQUAL? accepts 2-4, matching the first against any of the
   rest) — pragmatic subset, widen on demand. Anything else (a bare LVAL,
   or a builtin without special predicate handling) falls back to
   compiling it as a plain VALUE and testing it against zero, matching the
   original's own generic `BranchIfNonZero` fallback path. Recurses into
   itself for NOT/F?/T? (a polarity flip, not an instruction) and into
   CompileOperand for everything else; it never calls CompileStmt, so a
   COND nested inside a *condition* isn't reachable from here. *)
PROCEDURE CompileCondition(z: ZilObj.Zo; label: ARRAY OF CHAR; polarity: BOOLEAN): BOOLEAN;
VAR headName: ARRAY 64 OF CHAR; leftText, rightText, opText, empty: ARRAY 64 OF CHAR;
    skipLabel: ARRAY 16 OF CHAR; c: ZilObj.Zo; ok, spilled, isLast, allSimple: BOOLEAN;
    extraText: ARRAY 3, 64 OF CHAR; nExtra, nE2, nCondBinds: INTEGER;
    condBody, condItem: ZilObj.Zo;
BEGIN
  empty[0] := 0X; skipLabel[0] := 0X; spilled := FALSE;
  IF z = NIL THEN Err("CompileCondition: NIL condition"); RETURN FALSE END;

  IF (z.kind = ZilObj.KAtom) & ((z.atomText = "T") OR (z.atomText = "ELSE")) THEN
    IF polarity THEN EmitBranch(label) END; RETURN TRUE

  ELSIF z.kind = ZilObj.KFalse THEN
    IF ~polarity THEN EmitBranch(label) END; RETURN TRUE

  ELSIF z.kind = ZilObj.KFix THEN
    IF (z.fixVal # 0) = polarity THEN EmitBranch(label) END; RETURN TRUE

  ELSIF (z.kind = ZilObj.KForm) & (z.first # NIL) & (z.first.kind = ZilObj.KAtom) THEN
    Strings.Copy(z.first.atomText, headName);

    IF (headName = "ZERO?") OR (headName = "0?") THEN
      IF (z.rest = NIL) OR (z.rest.first = NIL) THEN
        Err("CompileCondition: ZERO? expects 1 arg"); RETURN FALSE
      END;
      ok := CompileOperand(z.rest.first, opText);
      IF ~ok THEN RETURN FALSE END;
      EmitPredInstr("ZERO?", opText, empty, label, polarity); RETURN TRUE

    ELSIF (headName = "SAVE") OR (headName = "RESTORE") OR (headName = "VERIFY")
          OR (headName = "ORIGINAL?") OR (headName = "RESTART") THEN
      (* V1-3 branch instructions with no operands: save/restore report
         success by branching rather than by storing (V5 stores instead, and
         V5 isn't emitted). *)
      EmitPredInstr(headName, "", "", label, polarity);
      RETURN TRUE

    ELSIF headName = "BTST" THEN
      (* <BTST value mask> — "are all the mask's bits set in value". A
         branch instruction, like the comparisons. *)
      IF (z.rest = NIL) OR (z.rest.first = NIL) OR (z.rest.rest = NIL) OR (z.rest.rest.first = NIL) THEN
        Err("CompileCondition: BTST expects 2 args"); RETURN FALSE
      END;
      ok := CompileOperand(z.rest.first, leftText);
      IF ~ok THEN RETURN FALSE END;
      ok := CompileOperand(z.rest.rest.first, rightText);
      IF ~ok THEN RETURN FALSE END;
      ok := FixStackedPair(leftText, rightText,
                           (headName = "EQUAL?") OR (headName = "=?") OR (headName = "==?")
                           OR (headName = "N==?") OR (headName = "N=?") OR (headName = "BTST"));
      IF ~ok THEN RETURN FALSE END;
      EmitPredInstr("BTST", leftText, rightText, label, polarity);
      RETURN TRUE

    ELSIF (headName = "FSET?") OR (headName = "IN?") THEN
      (* object predicates: "does this object have this flag set" and "is
         this object directly inside that one". Both are single Z-machine
         branch instructions whose ZAP mnemonics match their ZIL spelling. *)
      IF (z.rest = NIL) OR (z.rest.first = NIL) OR (z.rest.rest = NIL) OR (z.rest.rest.first = NIL) THEN
        Err("CompileCondition: FSET?/IN? expect 2 args"); RETURN FALSE
      END;
      ok := CompileOperand(z.rest.first, leftText);
      IF ~ok THEN RETURN FALSE END;
      ok := CompileOperand(z.rest.rest.first, rightText);
      IF ~ok THEN RETURN FALSE END;
      ok := FixStackedPair(leftText, rightText,
                           (headName = "EQUAL?") OR (headName = "=?") OR (headName = "==?")
                           OR (headName = "N==?") OR (headName = "N=?") OR (headName = "BTST"));
      IF ~ok THEN RETURN FALSE END;
      EmitPredInstr(headName, leftText, rightText, label, polarity);
      RETURN TRUE

    ELSIF (headName = "FIRST?") OR (headName = "NEXT?") THEN
      (* these both store a value AND branch; in a pure condition position
         only the branch matters, and the value goes to the stack *)
      IF (z.rest = NIL) OR (z.rest.first = NIL) THEN
        Err("CompileCondition: FIRST?/NEXT? expect 1 arg"); RETURN FALSE
      END;
      ok := CompileOperand(z.rest.first, leftText);
      IF ~ok THEN RETURN FALSE END;
      W("	"); W(headName); W(" "); W(leftText); W(" >STACK");
      IF polarity THEN W(" /") ELSE W(" \") END;
      W(label); WLn;
      RETURN TRUE

    ELSIF headName = "INTBL?" THEN
      (* <INTBL? value table n> — the Z-machine's scan_table: searches the
         first n entries of table for value, storing the matching entry's
         address (or 0) and branching on whether it found one. Same
         store-AND-branch shape as FIRST?/NEXT?, just with three operands
         instead of one — this is cloak_plus's REFERS-PSEUDO?, the first
         game so far to need it (INTBL? is V4+ only). *)
      IF (z.rest = NIL) OR (z.rest.first = NIL) OR (z.rest.rest = NIL)
         OR (z.rest.rest.first = NIL) OR (z.rest.rest.rest = NIL)
         OR (z.rest.rest.rest.first = NIL) THEN
        Err("CompileCondition: INTBL? expects 3 args"); RETURN FALSE
      END;
      ok := CompileOperand(z.rest.first, leftText);
      IF ~ok THEN RETURN FALSE END;
      ok := CompileOperand(z.rest.rest.first, rightText);
      IF ~ok THEN RETURN FALSE END;
      ok := CompileOperand(z.rest.rest.rest.first, opText);
      IF ~ok THEN RETURN FALSE END;
      W("	INTBL? "); W(leftText); W(","); W(rightText); W(","); W(opText);
      W(" >STACK");
      IF polarity THEN W(" /") ELSE W(" \") END;
      W(label); WLn;
      RETURN TRUE

    ELSIF (headName = "G=?") OR (headName = "L=?") THEN
      (* >= is "not <" and <= is "not >" — no separate Z-machine
         instruction, just LESS?/GRTR? with the branch polarity flipped,
         which is how the original's own G=?/L=? are defined *)
      IF (z.rest = NIL) OR (z.rest.first = NIL) OR (z.rest.rest = NIL) OR (z.rest.rest.first = NIL) THEN
        Err("CompileCondition: G=?/L=? expect 2 args"); RETURN FALSE
      END;
      ok := CompileOperand(z.rest.first, leftText);
      IF ~ok THEN RETURN FALSE END;
      ok := CompileOperand(z.rest.rest.first, rightText);
      IF ~ok THEN RETURN FALSE END;
      ok := FixStackedPair(leftText, rightText,
                           (headName = "EQUAL?") OR (headName = "=?") OR (headName = "==?")
                           OR (headName = "N==?") OR (headName = "N=?") OR (headName = "BTST"));
      IF ~ok THEN RETURN FALSE END;
      IF headName = "G=?" THEN EmitPredInstr("LESS?", leftText, rightText, label, ~polarity)
      ELSE EmitPredInstr("GRTR?", leftText, rightText, label, ~polarity)
      END;
      RETURN TRUE

    ELSIF headName = "1?" THEN
      (* <1? x> is "does x equal 1" — one EQUAL? against a literal *)
      IF (z.rest = NIL) OR (z.rest.first = NIL) THEN
        Err("CompileCondition: 1? expects 1 arg"); RETURN FALSE
      END;
      ok := CompileOperand(z.rest.first, leftText);
      IF ~ok THEN RETURN FALSE END;
      EmitPredInstr("EQUAL?", leftText, "1", label, polarity);
      RETURN TRUE

    ELSIF (headName = "N==?") OR (headName = "N=?") THEN
      (* not-equal: the same EQUAL? instruction with the branch polarity
         flipped, which is what the original's own NotEqualOp does *)
      IF (z.rest = NIL) OR (z.rest.first = NIL) OR (z.rest.rest = NIL) OR (z.rest.rest.first = NIL) THEN
        Err("CompileCondition: N==? expects 2 args"); RETURN FALSE
      END;
      ok := CompileOperand(z.rest.first, leftText);
      IF ~ok THEN RETURN FALSE END;
      ok := CompileOperand(z.rest.rest.first, rightText);
      IF ~ok THEN RETURN FALSE END;
      ok := FixStackedPair(leftText, rightText,
                           (headName = "EQUAL?") OR (headName = "=?") OR (headName = "==?")
                           OR (headName = "N==?") OR (headName = "N=?") OR (headName = "BTST"));
      IF ~ok THEN RETURN FALSE END;
      EmitPredInstr("EQUAL?", leftText, rightText, label, ~polarity);
      RETURN TRUE

    ELSIF (headName = "EQUAL?") OR (headName = "=?") OR (headName = "==?") OR (headName = "L?") OR (headName = "G?") THEN
      IF (z.rest = NIL) OR (z.rest.first = NIL) OR (z.rest.rest = NIL) OR (z.rest.rest.first = NIL) THEN
        Err("CompileCondition: comparison expects 2 args"); RETURN FALSE
      END;
      ok := CompileOperand(z.rest.first, leftText);
      IF ~ok THEN RETURN FALSE END;
      IF (headName = "L?") OR (headName = "G?") THEN
        ok := CompileOperand(z.rest.rest.first, rightText);
        IF ~ok THEN RETURN FALSE END;
        ok := FixStackedPair(leftText, rightText, FALSE);
        IF ~ok THEN RETURN FALSE END;
        IF headName = "L?" THEN EmitPredInstr("LESS?", leftText, rightText, label, polarity)
        ELSE EmitPredInstr("GRTR?", leftText, rightText, label, polarity) END
      ELSE
        (* One EQUAL? instruction matches its first operand against up to
           THREE comparands. Real source goes well past that — zillib's
           MAIN-LOOP tests a word against a dozen — so the comparands are
           emitted in groups of three, chained:

             branch-if-any-match: every group branches to the label
             branch-if-none-match: every group branches PAST the label, and
               a jump to the label follows the last group

           With more than one group the left operand is used repeatedly, so
           it cannot be left on the stack. *)
        (* Count the comparands, and note whether any of them EMITS anything.
           The comparands are compiled below, one group at a time, so this
           must not compile them here as well: doing that emitted the first
           comparand's instructions twice, which pushed a value nothing ever
           popped. *)
        c := z.rest.rest;
        nExtra := 0; allSimple := TRUE;
        WHILE (c # NIL) & (c.first # NIL) DO
          INC(nExtra);
          IF ~IsSimpleOperand(c.first) THEN allSimple := FALSE END;
          c := c.rest
        END;
        (* The left operand is read by every group, and anything a comparand
           pushes would bury it, so it can only stay on the stack for a single
           group of operands that emit nothing. *)
        IF (leftText = "STACK") & ((nExtra > 3) OR ~allSimple) THEN
          ok := SpillToTemp(leftText);
          IF ~ok THEN RETURN FALSE END;
          spilled := TRUE
        END;
        IF ~polarity & (nExtra > 3) THEN NewLabel(skipLabel) END;

        c := z.rest.rest;
        WHILE (c # NIL) & (c.first # NIL) DO
          (* one instruction per group of three comparands *)
          nE2 := 0;
          WHILE (nE2 < 3) & (c # NIL) & (c.first # NIL) DO
            ok := CompileOperand(c.first, extraText[nE2]);
            IF ~ok THEN RETURN FALSE END;
            INC(nE2); c := c.rest
          END;
          W("	EQUAL? "); W(leftText);
          FOR nExtra := 0 TO nE2 - 1 DO W(","); W(extraText[nExtra]) END;
          IF polarity THEN
            W(" /"); W(label)
          ELSIF (c # NIL) & (c.first # NIL) THEN
            W(" /"); W(skipLabel)
          ELSIF skipLabel[0] # 0X THEN
            W(" /"); W(skipLabel)
          ELSE
            W(" \"); W(label)
          END;
          WLn
        END;
        IF ~polarity & (skipLabel[0] # 0X) THEN
          EmitBranch(label);
          W(skipLabel); W(":"); WLn
        END;
        IF spilled THEN FreeTemp END
      END;
      RETURN TRUE

    ELSIF (headName = "IGRTR?") OR (headName = "DLESS?") THEN
      (* <IGRTR? VAR LIMIT> increments VAR then branches if it is now greater
         than LIMIT (DLESS? decrements and tests less-than) — one Z-machine
         instruction each, taking the variable BY NUMBER, hence the leading
         quote on the first operand (confirmed against real usage in
         ~/cloak_plus.zap: "IGRTR? 'I,MAX \?L1"). *)
      IF (z.rest = NIL) OR ~VarName(z.rest.first, leftText)
         OR (z.rest.rest = NIL) OR (z.rest.rest.first = NIL) THEN
        Err("CompileCondition: IGRTR?/DLESS? expect a variable and a limit"); RETURN FALSE
      END;
      ResolveLocal(leftText, leftText);
      ok := CompileOperand(z.rest.rest.first, rightText);
      IF ~ok THEN RETURN FALSE END;
      Strings.Copy("'", opText); Strings.Append(leftText, opText);
      EmitPredInstr(headName, opText, rightText, label, polarity);
      RETURN TRUE

    ELSIF (headName = "PROG") OR (headName = "BIND") THEN
      (* A block in CONDITION position: compile its bindings, then all but
         the last body statement as statements, and the LAST as a condition.
         Compiling it as a value instead would materialise a 1/0 that is
         immediately tested away — and cost a compiler temporary, which real
         library routines cannot spare (zillib's MATCH-NOUN-PHRASE declares
         thirteen locals of its own). *)
      c := z.rest;
      IF (c # NIL) & (c.first # NIL) & (c.first.kind = ZilObj.KAtom) THEN c := c.rest END;
      IF (c = NIL) OR (c.first = NIL) OR (c.first.kind # ZilObj.KList) THEN
        Err("CompileCondition: PROG/BIND expects a binding list"); RETURN FALSE
      END;
      nCondBinds := 0;
      condBody := c.first;
      WHILE (condBody # NIL) & (condBody.first # NIL) DO
        condItem := condBody.first;
        IF condItem.kind = ZilObj.KAtom THEN
          IF ~AllocInnerLocal(condItem.atomText) THEN RETURN FALSE END;
          INC(nCondBinds)
        ELSIF (condItem.kind = ZilObj.KList) & (condItem.first # NIL)
              & (condItem.first.kind = ZilObj.KAtom) & (condItem.rest # NIL)
              & (condItem.rest.first # NIL) THEN
          ok := CompileOperand(condItem.rest.first, opText);
          IF ~ok THEN RETURN FALSE END;
          IF ~AllocInnerLocal(condItem.first.atomText) THEN RETURN FALSE END;
          INC(nCondBinds);
          ResolveLocal(condItem.first.atomText, leftText);
          W("	SET '"); W(leftText); W(","); W(opText); WLn
        ELSE
          Err("CompileCondition: a PROG binding must be an atom or (atom value)");
          RETURN FALSE
        END;
        condBody := condBody.rest
      END;

      condBody := c.rest;
      IF (condBody = NIL) OR (condBody.first = NIL) THEN
        PopInnerLocals(nCondBinds);
        IF polarity THEN EmitBranch(label) END;   (* an empty block is true *)
        RETURN TRUE
      END;
      WHILE (condBody.rest # NIL) & (condBody.rest.first # NIL) DO
        ok := CompileStmt(condBody.first, FALSE, opText);
        IF ~ok THEN PopInnerLocals(nCondBinds); RETURN FALSE END;
        condBody := condBody.rest
      END;
      ok := CompileCondition(condBody.first, label, polarity);
      PopInnerLocals(nCondBinds);
      RETURN ok

    ELSIF (headName = "AND") OR (headName = "OR") THEN
      (* Short-circuit branching, and no value is materialised at all — the
         whole point of handling AND/OR here rather than falling through to
         "compile it as a value and test against zero".

         Branching to `label` when <AND a b c> is TRUE means each of a, b
         must branch PAST the test when false, and c decides; when FALSE,
         any one of them failing is enough and they all branch to `label`
         directly. OR is the exact dual. *)
      IF (z.rest = NIL) OR (z.rest.first = NIL) THEN
        (* <AND> is true, <OR> is false *)
        IF (headName = "AND") = polarity THEN EmitBranch(label) END;
        RETURN TRUE
      END;
      IF (headName = "AND") = polarity THEN
        (* the short-circuit case needs a label to skip to *)
        NewLabel(skipLabel);
        c := z.rest;
        WHILE (c # NIL) & (c.first # NIL) DO
          isLast := (c.rest = NIL) OR (c.rest.first = NIL);
          IF isLast THEN
            ok := CompileCondition(c.first, label, polarity)
          ELSE
            ok := CompileCondition(c.first, skipLabel, ~polarity)
          END;
          IF ~ok THEN RETURN FALSE END;
          c := c.rest
        END;
        W(skipLabel); W(":"); WLn
      ELSE
        c := z.rest;
        WHILE (c # NIL) & (c.first # NIL) DO
          ok := CompileCondition(c.first, label, polarity);
          IF ~ok THEN RETURN FALSE END;
          c := c.rest
        END
      END;
      RETURN TRUE

    ELSIF (headName = "NOT") OR (headName = "F?") THEN
      (* Negation is a polarity flip, not an instruction — the original's
         CompileCondition does exactly the same thing for NOT/F?. *)
      IF (z.rest = NIL) OR (z.rest.first = NIL) THEN
        Err("CompileCondition: NOT/F? expects 1 arg"); RETURN FALSE
      END;
      RETURN CompileCondition(z.rest.first, label, ~polarity)

    ELSIF headName = "T?" THEN
      IF (z.rest = NIL) OR (z.rest.first = NIL) THEN
        Err("CompileCondition: T? expects 1 arg"); RETURN FALSE
      END;
      RETURN CompileCondition(z.rest.first, label, polarity)

    ELSE
      ok := CompileOperand(z, opText);
      IF ~ok THEN RETURN FALSE END;
      EmitPredInstr("ZERO?", opText, empty, label, ~polarity); RETURN TRUE
    END

  ELSE
    ok := CompileOperand(z, opText);
    IF ~ok THEN RETURN FALSE END;
    EmitPredInstr("ZERO?", opText, empty, label, ~polarity); RETURN TRUE
  END
END CompileCondition;

(* Translates a ZIL string literal's source text into the text the
   Z-machine should actually print — the original's
   Compilation.Strings.cs TranslateString. Three rules, and they matter:

     - the CRLF character (`|` by default, overridable by the
       CRLF-CHARACTER global) becomes a real newline. Without this a game
       prints a literal "|" everywhere it meant a line break, which is
       exactly what the first compiled run of sample/beer showed.
     - a source newline becomes a SPACE, so a long string can be wrapped
       across lines in the source — unless it directly follows a `|`, in
       which case it is dropped (so "...|" at end of line doesn't also
       emit the space).
     - a carriage return is dropped, and two spaces after a "." or a `|`
       collapse to one (the original's CollapseAfterPeriod mode, its
       default; the SENTENCE-ENDS? and PRESERVE-SPACES? variants are not
       ported).

   `last` deliberately tracks the SOURCE character, not the translated
   one, matching the original's own loop. *)
PROCEDURE TranslateZilString(text: ARRAY OF CHAR; VAR out: ARRAY OF CHAR);
VAR i, n: INTEGER; c, last, crlf: CHAR; sawDotSpace, drop: BOOLEAN; a: ZilObj.Zo;
BEGIN
  crlf := "|";
  a := ZilObj.Intern("CRLF-CHARACTER");
  IF (a.globalVal # NIL) & (a.globalVal.kind = ZilObj.KChar) THEN
    crlf := CHR(a.globalVal.charVal)
  END;

  n := 0; last := 0X; sawDotSpace := FALSE;
  i := 0;
  WHILE text[i] # 0X DO
    c := text[i];
    drop := FALSE;

    IF ((last = ".") OR (last = crlf)) & (c = " ") THEN
      sawDotSpace := TRUE
    ELSIF sawDotSpace & (c = " ") THEN
      sawDotSpace := FALSE; drop := TRUE
    ELSE
      sawDotSpace := FALSE
    END;

    IF ~drop THEN
      IF c = 0DX THEN
        (* a CR is dropped, and (as in the original) doesn't even count as
           the preceding character for the newline rule below — see the
           `last` update at the end of the loop *)
      ELSIF c = 0AX THEN
        IF last # crlf THEN out[n] := " "; INC(n) END
      ELSIF c = crlf THEN
        out[n] := 0AX; INC(n)
      ELSE
        out[n] := c; INC(n)
      END
    END;

    IF c # 0DX THEN last := c END;
    INC(i)
  END;
  out[n] := 0X
END TranslateZilString;

(* ZAP strings double an embedded '"' rather than backslash-escaping it
   (confirmed against zapf's own ZapfTok.ReadString, which has no
   backslash handling at all) — re-encode a ZIL string's already-decoded
   text into that convention. *)
PROCEDURE CompileZapString(text: ARRAY OF CHAR; VAR out: ARRAY OF CHAR);
VAR i, n: INTEGER;
BEGIN
  out[0] := '"'; n := 1;
  i := 0;
  WHILE text[i] # 0X DO
    IF text[i] = '"' THEN out[n] := '"'; INC(n) END;
    out[n] := text[i]; INC(n);
    INC(i)
  END;
  out[n] := '"'; INC(n);
  out[n] := 0X
END CompileZapString;

(* ---------------- TELL ----------------
   TELL is a variadic print statement driven by a table of token patterns
   (ZModel/TellTokens.cs + Compilation.Expressions.cs's CompileTell), not a
   fixed builtin: the library extends it with ADD-TELL-TOKENS, so <TELL "x"
   CR D ,HERE> and <TELL T .OBJ> go through the same matcher. *)

(* Tries pattern `pi` against the argument chain starting at `ap`. On a
   match, `consumed` is how many arguments it took and `output` is the
   pattern's output FORM with its <LVAL ...> placeholders replaced by the
   captured arguments, in order — ready to compile as an ordinary
   statement. *)
PROCEDURE MatchTellPattern(pi: INTEGER; ap: ZilObj.Zo;
                           VAR consumed: INTEGER; VAR output: ZilObj.Zo): BOOLEAN;
VAR tp, arg, spec, alt, capHead, capTail, cell: ZilObj.Zo;
    outHead, outTail, elem, capPos: ZilObj.Zo;
    matched: BOOLEAN;
BEGIN
  consumed := 0;
  capHead := NIL; capTail := NIL;
  tp := ZilModel.tellPatterns[pi].tokens;

  WHILE (tp # NIL) & (tp.first # NIL) DO
    IF (ap = NIL) OR (ap.first = NIL) THEN RETURN FALSE END;   (* ran out of args *)
    spec := tp.first;
    arg := ap.first;

    IF spec.kind = ZilObj.KList THEN
      (* a list of alternative introducer atoms *)
      matched := FALSE;
      alt := spec;
      WHILE (alt # NIL) & (alt.first # NIL) DO
        IF alt.first = arg THEN matched := TRUE END;
        alt := alt.rest
      END;
      IF ~matched THEN RETURN FALSE END

    ELSIF (spec.kind = ZilObj.KAtom) & (spec.atomText = "*") THEN
      (* capture anything *)
      cell := ZilObj.Cons(ZilObj.KList, arg, NIL);
      IF capHead = NIL THEN capHead := cell ELSE capTail.rest := cell END;
      capTail := cell

    ELSIF spec.kind = ZilObj.KAtom THEN
      IF spec # arg THEN RETURN FALSE END

    ELSIF (spec.kind = ZilObj.KForm) & (ZilObj.ListLength(spec) = 2)
          & ZilObj.IsAtomNamed(spec.first, "GVAL") THEN
      IF (arg.kind # ZilObj.KForm) OR (ZilObj.ListLength(arg) # 2)
         OR ~ZilObj.IsAtomNamed(arg.first, "GVAL")
         OR (arg.rest.first # spec.rest.first) THEN RETURN FALSE END

    ELSE
      RETURN FALSE   (* a token spec shape this port doesn't match (e.g. *:DECL) *)
    END;

    INC(consumed);
    tp := tp.rest;
    ap := ap.rest
  END;

  (* substitute the captures into the output template *)
  outHead := NIL; outTail := NIL; capPos := capHead;
  elem := ZilModel.tellPatterns[pi].output;
  WHILE (elem # NIL) & (elem.first # NIL) DO
    IF (elem.first.kind = ZilObj.KForm) & (ZilObj.ListLength(elem.first) = 2)
       & ZilObj.IsAtomNamed(elem.first.first, "LVAL") & (capPos # NIL) THEN
      cell := ZilObj.Cons(ZilObj.KForm, capPos.first, NIL);
      capPos := capPos.rest
    ELSE
      cell := ZilObj.Cons(ZilObj.KForm, elem.first, NIL)
    END;
    IF outHead = NIL THEN outHead := cell ELSE outTail.rest := cell END;
    outTail := cell;
    elem := elem.rest
  END;
  output := outHead;
  RETURN TRUE
END MatchTellPattern;

(* Compiles a whole <TELL ...> form. Walks the arguments, trying every
   registered pattern at each position first (so a library token like
   `T .OBJ` wins over the generic fallbacks), then falling back exactly as
   the original does: a literal STRING prints inline, a CHARACTER prints as
   a character, 'FOO prints an object's short description, `P?FOO expr`
   fetches and prints a property, and anything else is printed as a packed
   string address.

   Calls CompileStmt for a matched pattern's output form, and CompileStmt
   calls back here — ordinary mutual recursion, which this transpiler
   supports (see the correction section in Notes/zilf_port_plan.md). *)
PROCEDURE CompileTell(z: ZilObj.Zo): BOOLEAN;
VAR ap, output: ZilObj.Zo; consumed, pi, i: INTEGER; ok, handled: BOOLEAN;
    opText, propText, dummy: ARRAY 64 OF CHAR;
    strText, transText: ARRAY 4096 OF CHAR;
    errBuf: ARRAY 256 OF CHAR;
BEGIN
  ap := z.rest;
  WHILE (ap # NIL) & (ap.first # NIL) DO
    handled := FALSE;
    pi := 0;
    WHILE (pi < ZilModel.nTellPatterns) & ~handled DO
      IF MatchTellPattern(pi, ap, consumed, output) THEN
        (* A pattern's output can itself contain macro calls — zillib's
           IFELSE token expands to <PRINT-IF-ELSE ...>, a DEFMAC. The body
           was expanded before compilation began, but this form is being
           built now, so it needs expanding too. *)
        output := ZilEval.ExpandTree(output);
        ok := CompileStmt(output, FALSE, dummy);
        IF ~ok THEN RETURN FALSE END;
        FOR i := 1 TO consumed DO ap := ap.rest END;
        handled := TRUE
      END;
      INC(pi)
    END;

    IF ~handled THEN
      IF ap.first.kind = ZilObj.KString THEN
        TranslateZilString(ap.first.strBuf^, transText);
        CompileZapString(transText, strText);
        W("	PRINTI "); W(strText); WLn;
        ap := ap.rest

      ELSIF ap.first.kind = ZilObj.KChar THEN
        FixText(ap.first.charVal, opText);
        W("	PRINTC "); W(opText); WLn;
        ap := ap.rest

      ELSIF (ap.first.kind = ZilObj.KForm) & (ZilObj.ListLength(ap.first) = 2)
            & ZilObj.IsAtomNamed(ap.first.first, "QUOTE") THEN
        (* 'FOO names an object directly; the original retypes it to a GVAL
           and prints it with PRINTD *)
        ok := CompileOperand(ap.first.rest.first, opText);
        IF ~ok THEN RETURN FALSE END;
        W("	PRINTD "); W(opText); WLn;
        ap := ap.rest

      ELSIF (ap.first.kind = ZilObj.KAtom) & (ap.first.atomText[0] = "P")
            & (ap.first.atomText[1] = "?") & (ap.rest # NIL) & (ap.rest.first # NIL) THEN
        (* P?FOO expr -> fetch that property off expr and print it as a
           packed string *)
        ok := CompileOperand(ap.first, propText);
        IF ~ok THEN RETURN FALSE END;
        ok := CompileOperand(ap.rest.first, opText);
        IF ~ok THEN RETURN FALSE END;
        W("	GETP "); W(opText); W(","); W(propText); W(" >STACK"); WLn;
        W("	PRINT STACK"); WLn;
        ap := ap.rest.rest

      ELSIF ap.first.kind = ZilObj.KAtom THEN
        Strings.Copy("CompileTell: bare atom is not a TELL token or property: ", errBuf);
        Strings.Append(ap.first.atomText, errBuf);
        Err(errBuf); RETURN FALSE

      ELSE
        (* anything else is an operand holding a packed string address *)
        ok := CompileOperand(ap.first, opText);
        IF ~ok THEN RETURN FALSE END;
        W("	PRINT "); W(opText); WLn;
        ap := ap.rest
      END
    END
  END;
  RETURN TRUE
END CompileTell;

(* Compiles `z` and leaves its value in the VARIABLE `dest`, rather than on
   the stack. This is the original's `CompileAsOperand(rb, value, src,
   dest)` — a destination hint — and it matters for two reasons beyond
   tidier output:

     - it removes a whole instruction per assignment: <SET X <+ .A .B>>
       becomes `ADD A,B >X` instead of `ADD A,B >STACK` then `SET 'X,STACK`
     - AND/OR and predicates need somewhere to accumulate a value that a
       test won't consume, and with a destination they can use it instead
       of allocating a compiler temporary. A routine only has fifteen
       locals, and real library routines declare fourteen of them.

   Falls back to compiling normally and copying, so it is always correct;
   the special cases are purely an improvement. *)
PROCEDURE CompileOperandTo(z: ZilObj.Zo; dest: ARRAY OF CHAR): BOOLEAN;
VAR headName, opText, leftText, rightText: ARRAY 64 OF CHAR;
    opcode: ARRAY 16 OF CHAR; endLabel: ARRAY 16 OF CHAR;
    ok, spilled, sStore: BOOLEAN; sN, i, nA: INTEGER; ap, rw: ZilObj.Zo;
    argT: ArgList;
BEGIN
  (* a header read is a GET/GETB, so it can store straight into dest *)
  IF IsLowCore(z) THEN
    IF ~LowCoreRewrite(z, rw) THEN RETURN FALSE END;
    RETURN CompileOperandTo(rw, dest)
  END;

  IF (z # NIL) & (z.kind = ZilObj.KForm) & (z.first # NIL)
     & (z.first.kind = ZilObj.KAtom) THEN
    Strings.Copy(z.first.atomText, headName);

    (* AND/OR accumulate into the destination *)
    IF ((headName = "AND") OR (headName = "OR"))
       & (z.rest # NIL) & (z.rest.first # NIL) THEN
      NewLabel(endLabel);
      ap := z.rest;
      WHILE (ap # NIL) & (ap.first # NIL) DO
        ok := CompileOperandTo(ap.first, dest);
        IF ~ok THEN RETURN FALSE END;
        IF (ap.rest # NIL) & (ap.rest.first # NIL) THEN
          W("	ZERO? "); W(dest);
          IF headName = "OR" THEN W(" \") ELSE W(" /") END;
          W(endLabel); WLn
        END;
        ap := ap.rest
      END;
      W(endLabel); W(":"); WLn;
      RETURN TRUE
    END;

    (* a predicate materialises into the destination *)
    IF IsPredicateBuiltin(headName) THEN
      NewLabel(endLabel);
      W("	SET '"); W(dest); W(",1"); WLn;
      ok := CompileCondition(z, endLabel, TRUE);
      IF ~ok THEN RETURN FALSE END;
      W("	SET '"); W(dest); W(",0"); WLn;
      W(endLabel); W(":"); WLn;
      RETURN TRUE
    END;

    (* two-operand arithmetic stores straight into the destination *)
    IF ((headName = "+") OR (headName = "-") OR (headName = "*") OR (headName = "/")
        OR (headName = "MOD"))
       & (z.rest # NIL) & (z.rest.first # NIL)
       & (z.rest.rest # NIL) & (z.rest.rest.first # NIL)
       & ((z.rest.rest.rest = NIL) OR (z.rest.rest.rest.first = NIL)) THEN
      IF headName = "+" THEN Strings.Copy("ADD", opcode)
      ELSIF headName = "-" THEN Strings.Copy("SUB", opcode)
      ELSIF headName = "*" THEN Strings.Copy("MUL", opcode)
      ELSIF headName = "MOD" THEN Strings.Copy("MOD", opcode)
      ELSE Strings.Copy("DIV", opcode)
      END;
      ok := CompileOperand(z.rest.first, leftText);
      IF ~ok THEN RETURN FALSE END;
      ok := CompileOperand(z.rest.rest.first, rightText);
      IF ~ok THEN RETURN FALSE END;
      ok := FixStackedPair(leftText, rightText,
                           (opcode = "ADD") OR (opcode = "MUL"));
      IF ~ok THEN RETURN FALSE END;
      W("	"); W(opcode); W(" "); W(leftText); W(","); W(rightText);
      W(" >"); W(dest); WLn;
      RETURN TRUE
    END;

    (* a call to a routine this program defines, likewise *)
    IF FindRoutineIdx(headName) >= 0 THEN
      IF ZilModel.zversion < 4 THEN sN := 3 ELSE sN := 7 END;
      nA := 0; ap := z.rest;
      WHILE (ap # NIL) & (ap.first # NIL) & (nA < sN) DO
        ok := CompileOperand(ap.first, argT[nA]);
        IF ~ok THEN RETURN FALSE END;
        INC(nA); ap := ap.rest
      END;
      IF (ap = NIL) OR (ap.first = NIL) THEN
        IF ZilModel.zversion < 4 THEN Strings.Copy("CALL", opcode)
        ELSIF nA = 0 THEN Strings.Copy("CALL1", opcode)
        ELSIF nA = 1 THEN Strings.Copy("CALL2", opcode)
        ELSIF nA <= 3 THEN Strings.Copy("CALL", opcode)
        ELSE Strings.Copy("XCALL", opcode)
        END;
        W("	"); W(opcode); W(" "); WSym(headName);
        i := 0;
        WHILE i < nA DO W(","); W(argT[i]); INC(i) END;
        W(" >"); W(dest); WLn;
        RETURN TRUE
      END
      (* too many arguments: fall through so CompileOperand reports it *)
    END;

    (* a value-producing one-instruction builtin, likewise *)
    IF SimpleBuiltin(headName, opcode, sN, sStore) & sStore THEN
      nA := 0; ap := z.rest;
      WHILE (ap # NIL) & (ap.first # NIL) & (nA < sN) DO
        ok := CompileOperand(ap.first, argT[nA]);
        IF ~ok THEN RETURN FALSE END;
        INC(nA); ap := ap.rest
      END;
      IF (nA <= sN) & (nA >= BuiltinMinArgs(headName, sN)) THEN
        W("	"); W(opcode);
        i := 0;
        WHILE i < nA DO
          IF i = 0 THEN W(" ") ELSE W(",") END;
          W(argT[i]); INC(i)
        END;
        W(" >"); W(dest);
        IF IsValuePredBuiltin(headName) THEN EmitDeadBranch ELSE WLn END;
        RETURN TRUE
      END;
      (* wrong arity: fall through and let CompileOperand report it *)
    END
  END;

  ok := CompileOperand(z, opText);
  IF ~ok THEN RETURN FALSE END;
  IF opText # dest THEN
    W("	SET '"); W(dest); W(","); W(opText); WLn
  END;
  RETURN TRUE
END CompileOperandTo;

(* Compiles `z` as a routine BODY STATEMENT — as opposed to CompileOperand
   above, which compiles it as a value-producing EXPRESSION — mirroring
   the original's own CompileForm (statements) vs CompileAsOperand
   (expressions) split. Handles the statement-shaped builtins SET/PRINTI/
   PRINTN/CRLF directly (none of these make sense as a nested expression
   operand in the same way arithmetic does, so they don't belong in
   CompileOperand); anything else falls back to CompileOperand, so a bare
   value expression used as a statement (e.g. the trivial `<+ .X 1>` test
   case) still works. `resultText` is only meaningful when `wantResult` is
   set (the routine's final statement, or a COND clause's final
   statement); the void-only builtins (PRINTI/PRINTN/CRLF) return `"1"` —
   a safe stand-in for T, since none of them produce a real ZIL value but
   the calling convention still needs *something* returnable when one of
   them happens to be in that position.

   COND is inlined directly here (its own clause bodies need to compile
   arbitrary statements, including nested CONDs), making CompileStmt
   self-recursive. NOTE: earlier phases of this port believed a separate
   CompileCOND calling back into CompileStmt was impossible because this
   transpiler has no FORWARD declarations — that belief is wrong. codegen.c
   emits a C prototype for every top-level procedure before any body, so
   mutually-recursive top-level procedures work in either declaration
   order (verified directly). The inlining here is kept because it works
   and is tested, not because it is required.

   COND's result (when wanted) is always left on the Z-machine stack,
   matching the original's own default (`resultStorage ??= rb.Stack`):
   each matching clause's final value is pushed (via PUSH, unless it's
   already sitting on the stack from its own last instruction, in which
   case pushing again would double it), and since at most one clause's
   branch is ever taken, exactly one value ends up on the stack by the
   time control reaches the end label, regardless of which clause matched
   or whether none did (a bare 0 is pushed as the "no clause matched, no
   ELSE" default, matching the original's `EmitStore(resultStorage,
   Game.Zero)`). *)
PROCEDURE CompileStmt(z: ZilObj.Zo; wantResult: BOOLEAN; VAR resultText: ARRAY OF CHAR): BOOLEAN;
VAR headName: ARRAY 64 OF CHAR; opText, targetName: ARRAY 64 OF CHAR;
    strText, transText: ARRAY 4096 OF CHAR;
    ok: BOOLEAN;
    (* COND *)
    nextLabel, endLabel: ARRAY 16 OF CHAR;
    elsePart, isLastClauseStmt, hasMoreClauses, clauseTerminated: BOOLEAN;
    (* PROG / REPEAT / BIND *)
    againLabel, retLabel: ARRAY 16 OF CHAR; progResult: ARRAY 64 OF CHAR;
    progRepeat, progTerm: BOOLEAN; progArgs, item: ZilObj.Zo;
    blkIdx, nProgBinds: INTEGER; progActName, tgtName: ARRAY 64 OF CHAR;
    errBuf: ARRAY 256 OF CHAR;
    (* DO *)
    doStart, doEnd, doStep, endClause: ZilObj.Zo; doDown, doPre: BOOLEAN;
    exhLabel: ARRAY 16 OF CHAR;
    mapNextName: ARRAY 64 OF CHAR; numText: ARRAY 16 OF CHAR;
    (* LOWCORE / LOWCORE-TABLE *)
    lcForm, lcArg: ZilObj.Zo; lcOff, lcLen: INTEGER; lcByte: BOOLEAN;
    (* simple one-instruction builtins *)
    sbOpcode: ARRAY 16 OF CHAR; sbArgs: ArgList; sbErr: ARRAY 256 OF CHAR;
    sbStore, sbSpilled: BOOLEAN; sbN, sbCount, sbI, sbSpills: INTEGER; ap, ap2: ZilObj.Zo;
    c, cond, body, bp: ZilObj.Zo; clauseResult: ARRAY 64 OF CHAR;
BEGIN
  termFlag := FALSE;
  IF z = NIL THEN Err("CompileStmt: NIL statement"); RETURN FALSE END;

  IF (z.kind = ZilObj.KForm) & (z.first # NIL) & (z.first.kind = ZilObj.KAtom) THEN
    Strings.Copy(z.first.atomText, headName);

    IF headName = "QUOTE" THEN
      (* A #DECL (...) statement - a routine's own compile-time-only type
         declaration for its locals, e.g. gclock.zil's QUEUE:
         `#DECL ((RTN) ATOM (TICK) FIX (CINT) <PRIMTYPE VECTOR>)` as its
         first statement. ZilRead reads `#DECL (...)` as a literal
         <QUOTE (...)> FORM specifically so it self-evaluates correctly
         wherever a DECL can appear as a VALUE (see ZilRead's own comment on
         why); reaching here means one showed up in STATEMENT position
         instead, where the original just discards it - this port has no
         DECL checking to feed it to (ZilEval's file header lists that as a
         deliberate simplification), so it compiles to nothing at all. *)
      Strings.Copy("0", resultText); RETURN TRUE

    ELSIF (headName = "SET") OR (headName = "SETG") THEN
      (* SET and SETG differ only in which namespace the original resolves
         the target in (VariableScopeQuirks.Local vs .Global) — SetgValueOp
         in ZBuiltins.cs literally just calls SetValueOp. In ZAP text both
         are the one SET instruction naming the variable, and .FUNCT's own
         local list is what makes a local shadow a global of the same name,
         so a single branch handles both. *)
      IF (z.rest = NIL) OR ~VarName(z.rest.first, targetName)
         OR (z.rest.rest = NIL) OR (z.rest.rest.first = NIL) THEN
        Err("CompileStmt: SET/SETG expect a variable name and a value"); RETURN FALSE
      END;
      (* SET means the LOCAL of that name (the original's
         VariableScopeQuirks.Local), so a PROG binding shadowing an outer
         name is honoured; SETG always means the global, and must not be
         redirected by a binding that happens to share the name. *)
      IF headName = "SET" THEN ResolveLocal(targetName, targetName) END;
      ok := CompileOperandTo(z.rest.rest.first, targetName);
      IF ~ok THEN RETURN FALSE END;
      Strings.Copy(targetName, resultText);
      RETURN TRUE

    ELSIF (headName = "INC") OR (headName = "DEC") THEN
      IF (z.rest = NIL) OR ~VarName(z.rest.first, targetName) THEN
        Err("CompileStmt: INC/DEC expect a variable name"); RETURN FALSE
      END;
      ResolveLocal(targetName, targetName);
      W("	"); W(headName); W(" '"); W(targetName); WLn;
      Strings.Copy(targetName, resultText);
      RETURN TRUE

    ELSIF (headName = "PROG") OR (headName = "REPEAT") OR (headName = "BIND") THEN
      (* Ported from Compilation.Loops.cs's CompilePROG, which handles all
         three (REPEAT is PROG with `repeat` set, BIND is PROG with
         `catchy` clear — the flag that decides whether a RETURN with no
         explicit block name may target it; this port doesn't implement
         named activations yet, so that distinction has no effect and BIND
         is compiled as PROG).

         Shape: an optional leading activation atom, then a binding list,
         then the body. The body is bracketed by two labels — an "again"
         label before it that AGAIN jumps back to, and a "return" label
         after it that RETURN jumps forward to — and REPEAT additionally
         jumps back to the again label when the body falls off the end,
         which is what makes it a loop. *)
      progRepeat := headName = "REPEAT";
      progArgs := z.rest;
      IF (progArgs # NIL) & (progArgs.first # NIL) & (progArgs.first.kind = ZilObj.KAtom) THEN
        (* an activation atom naming the block, so a nested AGAIN/RETURN can
           target it explicitly instead of the innermost block — see
           FindNamedBlock. MATCH-NOUN-PHRASE's <PROG BITS-SET () ...> needs
           this: it is written so a nested MAP-SCOPE's own (unnamed) REPEAT
           can <AGAIN .BITS-SET> to restart the OUTER PROG, not itself. *)
        Strings.Copy(progArgs.first.atomText, progActName);
        progArgs := progArgs.rest
      ELSE
        progActName[0] := 0X
      END;
      IF (progArgs = NIL) OR (progArgs.first = NIL) OR (progArgs.first.kind # ZilObj.KList) THEN
        Err("CompileStmt: PROG/REPEAT/BIND expects a binding list"); RETURN FALSE
      END;
      (* Bindings become extra locals on the .FUNCT line, scoped by the
         rename stack (AllocInnerLocal). A binding is an atom, or a
         (atom initial-value) list; the initial value is compiled and
         assigned on entry, which is also what makes a REPEAT's binding
         reset each time the loop is entered — but NOT each time round,
         since the again label is emitted after these assignments, matching
         the original (it marks AgainLabel after the bindings are set up). *)
      nProgBinds := 0;
      bp := progArgs.first;
      WHILE (bp # NIL) & (bp.first # NIL) DO
        item := bp.first;
        IF item.kind = ZilObj.KAtom THEN
          IF ~AllocInnerLocal(item.atomText) THEN RETURN FALSE END;
          INC(nProgBinds)
        ELSIF (item.kind = ZilObj.KList) & (item.first # NIL) & (item.first.kind = ZilObj.KAtom) THEN
          (* compile the initial value BEFORE the binding takes effect, so
             <PROG ((X .X)) ...> initialises the new X from the outer one *)
          IF (item.rest = NIL) OR (item.rest.first = NIL) THEN
            Err("CompileStmt: a PROG binding list entry needs a value"); RETURN FALSE
          END;
          ok := CompileOperand(item.rest.first, opText);
          IF ~ok THEN RETURN FALSE END;
          IF ~AllocInnerLocal(item.first.atomText) THEN RETURN FALSE END;
          INC(nProgBinds);
          ResolveLocal(item.first.atomText, targetName);
          W("	SET '"); W(targetName); W(","); W(opText); WLn
        ELSE
          Err("CompileStmt: a PROG binding must be an atom or (atom value)"); RETURN FALSE
        END;
        bp := bp.rest
      END;

      IF nBlocks >= MaxBlocks THEN
        Err("CompileStmt: PROG/REPEAT nested too deeply"); RETURN FALSE
      END;

      NewLabel(againLabel); NewLabel(retLabel);
      Strings.Copy(againLabel, blockAgain[nBlocks]);
      Strings.Copy(retLabel, blockReturn[nBlocks]);
      Strings.Copy(progActName, blockNames[nBlocks]);
      blockWantResult[nBlocks] := wantResult;
      blockReturned[nBlocks] := FALSE;
      blockHasReturn[nBlocks] := TRUE;
      INC(nBlocks);

      W(againLabel); W(":"); WLn;

      (* A REPEAT's body value is always discarded — the loop only produces
         a value by way of a RETURN — so only a non-repeating PROG's last
         statement is compiled wanting a result (the original passes
         `!repeat` for exactly this). *)
      bp := progArgs.rest;
      Strings.Copy("1", progResult);
      progTerm := FALSE;
      WHILE (bp # NIL) & (bp.first # NIL) DO
        isLastClauseStmt := (bp.rest = NIL) OR (bp.rest.first = NIL);
        ok := CompileStmt(bp.first, wantResult & ~progRepeat & isLastClauseStmt, progResult);
        IF ~ok THEN DEC(nBlocks); PopInnerLocals(nProgBinds); RETURN FALSE END;
        progTerm := termFlag;
        bp := bp.rest
      END;

      IF progRepeat THEN
        EmitBranch(againLabel)
      ELSIF wantResult & ~progTerm & (progResult # "STACK") THEN
        (* a PROG's own value and a RETURN's both have to arrive at the end
           label the same way, and RETURN leaves its value on the stack *)
        W("	PUSH "); W(progResult); WLn
      END;

      DEC(nBlocks);
      PopInnerLocals(nProgBinds);
      IF blockReturned[nBlocks] THEN
        W(retLabel); W(":"); WLn;
        termFlag := FALSE
      ELSE
        (* Nothing jumped to the end label. For a REPEAT that means the loop
           has no exit at all, so control provably never leaves it and the
           caller must not emit a trailing return; for a PROG it means the
           body's own termination decides. *)
        IF progRepeat THEN termFlag := TRUE ELSE termFlag := progTerm END
      END;
      IF wantResult THEN Strings.Copy("STACK", resultText) END;
      RETURN TRUE

    ELSIF headName = "DO" THEN
      (* <DO (VAR start end [step]) body...> — a counted loop. Ported from
         Compilation.Loops.cs's DoLoop: the counter is an inner local; when
         `end` is a FORM it is a PREDICATE tested before the body, and
         otherwise it is a value the counter is compared against after the
         increment. The direction is taken from the step when there is one,
         and otherwise from whether a constant `end` is below a constant
         `start` — which is what makes <DO (I 10 1)> count down. *)
      IF (z.rest = NIL) OR (z.rest.first = NIL) OR (z.rest.first.kind # ZilObj.KList)
         OR (z.rest.first.first = NIL) OR (z.rest.first.first.kind # ZilObj.KAtom) THEN
        Err("CompileStmt: DO expects (VAR start end [step])"); RETURN FALSE
      END;
      progArgs := z.rest.first;          (* the spec list *)
      doStart := progArgs.rest;
      IF (doStart = NIL) OR (doStart.first = NIL) OR (doStart.rest = NIL)
         OR (doStart.rest.first = NIL) THEN
        Err("CompileStmt: DO expects a start and an end"); RETURN FALSE
      END;
      doEnd := doStart.rest.first;
      doStep := NIL;
      IF (doStart.rest.rest # NIL) & (doStart.rest.rest.first # NIL) THEN
        doStep := doStart.rest.rest.first
      END;

      (* the counter's initial value is computed BEFORE the binding exists *)
      ok := CompileOperand(doStart.first, opText);
      IF ~ok THEN RETURN FALSE END;
      IF ~AllocInnerLocal(progArgs.first.atomText) THEN RETURN FALSE END;
      ResolveLocal(progArgs.first.atomText, targetName);
      W("	SET '"); W(targetName); W(","); W(opText); WLn;

      (* counting down when the step says so, or when a constant end is
         below a constant start *)
      doDown := FALSE;
      IF doStep # NIL THEN
        doDown := (doStep.kind = ZilObj.KFix) & (doStep.fixVal < 0)
      ELSE
        doDown := (doStart.first.kind = ZilObj.KFix) & (doEnd.kind = ZilObj.KFix)
                  & (doEnd.fixVal < doStart.first.fixVal)
      END;

      IF nBlocks >= MaxBlocks THEN
        Err("CompileStmt: DO nested too deeply"); RETURN FALSE
      END;
      (* Two distinct labels: "exhausted" is where the loop ends NORMALLY,
         and an (END ...) clause runs there; the block's return label is
         where a RETURN inside the loop jumps, skipping the END clause. The
         original distinguishes them the same way. *)
      NewLabel(againLabel); NewLabel(retLabel); NewLabel(exhLabel);
      Strings.Copy(againLabel, blockAgain[nBlocks]);
      Strings.Copy(retLabel, blockReturn[nBlocks]);
      blockNames[nBlocks][0] := 0X;
      blockWantResult[nBlocks] := wantResult;
      blockReturned[nBlocks] := FALSE;
      blockHasReturn[nBlocks] := TRUE;
      INC(nBlocks);

      W(againLabel); W(":"); WLn;

      (* a FORM end is a predicate, tested before the body — but `.X` and
         `,X` are forms too, and those are values to compare against *)
      doPre := (doEnd.kind = ZilObj.KForm) & ~IsVarRefForm(doEnd);
      IF doPre THEN
        ok := CompileCondition(doEnd, exhLabel, TRUE);
        IF ~ok THEN DEC(nBlocks); PopInnerLocals(1); RETURN FALSE END
      END;

      (* an (END ...) clause, if present, is the last body element and is
         not part of the loop body *)
      endClause := NIL;
      bp := z.rest.rest;
      WHILE (bp # NIL) & (bp.first # NIL) DO
        IF (bp.first.kind = ZilObj.KList) & ZilObj.IsAtomNamed(bp.first.first, "END") THEN
          (* real source puts the END clause immediately after the spec —
             zillib's APPLY-GENERIC-FCN writes <DO (I 1 .MAX) (END <RFALSE>)
             ...body...> — so it is recognised anywhere in the body rather
             than only at the end *)
          endClause := bp.first.rest
        ELSE
          ok := CompileStmt(bp.first, FALSE, progResult);
          IF ~ok THEN DEC(nBlocks); PopInnerLocals(1); RETURN FALSE END
        END;
        bp := bp.rest
      END;

      (* the increment *)
      IF doStep # NIL THEN
        IF doDown & (doStep.kind = ZilObj.KFix) THEN
          FixText(-doStep.fixVal, opText);
          W("	SUB "); W(targetName); W(","); W(opText);
          W(" >"); W(targetName); WLn
        ELSIF (doStep.kind = ZilObj.KForm) & ~IsVarRefForm(doStep) THEN
          (* a FORM step computes the counter's NEXT VALUE rather than a
             delta, so it is stored into the counter, not added to it —
             the original's `inc.IsNonVariableForm()` branch *)
          ok := CompileOperandTo(doStep, targetName);
          IF ~ok THEN DEC(nBlocks); PopInnerLocals(1); RETURN FALSE END
        ELSE
          ok := CompileOperand(doStep, opText);
          IF ~ok THEN DEC(nBlocks); PopInnerLocals(1); RETURN FALSE END;
          W("	ADD "); W(targetName); W(","); W(opText);
          W(" >"); W(targetName); WLn
        END
      ELSIF doDown THEN
        W("	DEC '"); W(targetName); WLn
      ELSE
        W("	INC '"); W(targetName); WLn
      END;

      (* a value end is compared after the increment *)
      IF ~doPre THEN
        ok := CompileOperand(doEnd, opText);
        IF ~ok THEN DEC(nBlocks); PopInnerLocals(1); RETURN FALSE END;
        IF doDown THEN EmitPredInstr("LESS?", targetName, opText, exhLabel, TRUE)
        ELSE EmitPredInstr("GRTR?", targetName, opText, exhLabel, TRUE) END
      END;
      EmitBranch(againLabel);

      W(exhLabel); W(":"); WLn;
      WHILE (endClause # NIL) & (endClause.first # NIL) DO
        ok := CompileStmt(endClause.first, FALSE, progResult);
        IF ~ok THEN DEC(nBlocks); PopInnerLocals(1); RETURN FALSE END;
        endClause := endClause.rest
      END;
      IF wantResult THEN W("	PUSH 1"); WLn END;

      DEC(nBlocks);
      PopInnerLocals(1);
      IF blockReturned[nBlocks] THEN W(retLabel); W(":"); WLn END;
      IF wantResult THEN Strings.Copy("STACK", resultText) END;
      termFlag := FALSE;
      RETURN TRUE

    ELSIF headName = "MAP-CONTENTS" THEN
      (* <MAP-CONTENTS (VAR [NEXTVAR] container) body...> walks an object's
         children. The three-element form binds a second variable to the
         NEXT child before the body runs, so the body may safely move the
         current one out — which is the whole reason that form exists.

           SET VAR,<FIRST? container>   ; no children -> done
         again:
           [SET NEXT,<NEXT? VAR>]
           body
           [SET VAR,.NEXT / SET VAR,<NEXT? VAR>]  ; no more -> done
           JUMP again
         done: *)
      IF (z.rest = NIL) OR (z.rest.first = NIL) OR (z.rest.first.kind # ZilObj.KList) THEN
        Err("CompileStmt: MAP-CONTENTS expects (VAR [NEXT] container)"); RETURN FALSE
      END;
      progArgs := z.rest.first;
      IF (progArgs.first = NIL) OR (progArgs.first.kind # ZilObj.KAtom)
         OR (progArgs.rest = NIL) OR (progArgs.rest.first = NIL) THEN
        Err("CompileStmt: MAP-CONTENTS expects (VAR [NEXT] container)"); RETURN FALSE
      END;
      doStep := NIL;                      (* the optional NEXT variable *)
      doEnd := progArgs.rest.first;       (* the container, unless NEXT is present *)
      IF (progArgs.rest.rest # NIL) & (progArgs.rest.rest.first # NIL) THEN
        doStep := progArgs.rest.first;
        doEnd := progArgs.rest.rest.first
      END;

      ok := CompileOperand(doEnd, opText);
      IF ~ok THEN RETURN FALSE END;
      IF ~AllocInnerLocal(progArgs.first.atomText) THEN RETURN FALSE END;
      nProgBinds := 1;
      ResolveLocal(progArgs.first.atomText, targetName);
      IF doStep # NIL THEN
        IF ~AllocInnerLocal(doStep.atomText) THEN RETURN FALSE END;
        INC(nProgBinds);
        ResolveLocal(doStep.atomText, mapNextName)
      END;

      IF nBlocks >= MaxBlocks THEN
        Err("CompileStmt: MAP-CONTENTS nested too deeply"); RETURN FALSE
      END;
      NewLabel(againLabel); NewLabel(retLabel);
      Strings.Copy(againLabel, blockAgain[nBlocks]);
      Strings.Copy(retLabel, blockReturn[nBlocks]);
      blockNames[nBlocks][0] := 0X;
      blockWantResult[nBlocks] := wantResult;
      blockReturned[nBlocks] := FALSE;
      blockHasReturn[nBlocks] := TRUE;
      INC(nBlocks);

      W("	FIRST? "); W(opText); W(" >"); W(targetName);
      W(" \"); W(retLabel); WLn;
      W(againLabel); W(":"); WLn;
      IF doStep # NIL THEN
        W("	NEXT? "); W(targetName); W(" >"); W(mapNextName); W(" /");
        W(againLabel); W("X"); WLn;
        W("	SET '"); W(mapNextName); W(",0"); WLn;
        W(againLabel); W("X:"); WLn
      END;

      bp := z.rest.rest;
      WHILE (bp # NIL) & (bp.first # NIL) DO
        ok := CompileStmt(bp.first, FALSE, progResult);
        IF ~ok THEN DEC(nBlocks); PopInnerLocals(nProgBinds); RETURN FALSE END;
        bp := bp.rest
      END;

      IF doStep # NIL THEN
        W("	SET '"); W(targetName); W(","); W(mapNextName); WLn;
        W("	ZERO? "); W(targetName); W(" /"); W(retLabel); WLn
      ELSE
        W("	NEXT? "); W(targetName); W(" >"); W(targetName);
        W(" \"); W(retLabel); WLn
      END;
      EmitBranch(againLabel);

      DEC(nBlocks);
      PopInnerLocals(nProgBinds);
      W(retLabel); W(":"); WLn;
      IF wantResult THEN
        W("	PUSH 0"); WLn;
        Strings.Copy("STACK", resultText)
      END;
      termFlag := FALSE;
      RETURN TRUE

    ELSIF headName = "MAP-DIRECTIONS" THEN
      (* <MAP-DIRECTIONS (DIR PT room) body...> walks the room's direction
         properties from the highest-numbered direction down to the lowest,
         binding DIR to the property number and PT to the property's address,
         and skipping the directions the room does not have:

           SET 'DIR,<MaxProps+1>
         again:
           DLESS? 'DIR,LOW-DIRECTION /done
           GETPT room,DIR >PT
           ZERO? PT /again
           body
           JUMP again
         done:

         DLESS? decrements before it compares, which is why the counter
         starts one ABOVE the highest property number. *)
      IF (z.rest = NIL) OR (z.rest.first = NIL) OR (z.rest.first.kind # ZilObj.KList) THEN
        Err("CompileStmt: MAP-DIRECTIONS expects (DIR PT room)"); RETURN FALSE
      END;
      progArgs := z.rest.first;
      IF (progArgs.first = NIL) OR (progArgs.first.kind # ZilObj.KAtom)
         OR (progArgs.rest = NIL) OR (progArgs.rest.first = NIL)
         OR (progArgs.rest.first.kind # ZilObj.KAtom)
         OR (progArgs.rest.rest = NIL) OR (progArgs.rest.rest.first = NIL) THEN
        Err("CompileStmt: MAP-DIRECTIONS expects (DIR PT room)"); RETURN FALSE
      END;
      doStep := progArgs.rest.first;       (* the property-address variable *)
      doEnd := progArgs.rest.rest.first;   (* the room *)

      ok := CompileOperand(doEnd, opText);
      IF ~ok THEN RETURN FALSE END;
      (* the room is read once per iteration, so it cannot be left on the
         stack the way MAP-CONTENTS can leave its container *)
      IF opText = "STACK" THEN
        IF ~SpillToTemp(opText) THEN RETURN FALSE END
      END;

      IF ~AllocInnerLocal(progArgs.first.atomText) THEN RETURN FALSE END;
      IF ~AllocInnerLocal(doStep.atomText) THEN PopInnerLocals(1); RETURN FALSE END;
      nProgBinds := 2;
      ResolveLocal(progArgs.first.atomText, targetName);
      ResolveLocal(doStep.atomText, mapNextName);

      IF nBlocks >= MaxBlocks THEN
        Err("CompileStmt: MAP-DIRECTIONS nested too deeply"); RETURN FALSE
      END;
      NewLabel(againLabel); NewLabel(retLabel);
      Strings.Copy(againLabel, blockAgain[nBlocks]);
      Strings.Copy(retLabel, blockReturn[nBlocks]);
      blockNames[nBlocks][0] := 0X;
      blockWantResult[nBlocks] := wantResult;
      blockReturned[nBlocks] := FALSE;
      blockHasReturn[nBlocks] := TRUE;
      INC(nBlocks);

      FixText(MaxProps() + 1, numText);
      W("	SET '"); W(targetName); W(","); W(numText); WLn;
      W(againLabel); W(":"); WLn;
      W("	DLESS? '"); W(targetName); W(",LOW-DIRECTION /"); W(retLabel); WLn;
      W("	GETPT "); W(opText); W(","); W(targetName);
      W(" >"); W(mapNextName); WLn;
      W("	ZERO? "); W(mapNextName); W(" /"); W(againLabel); WLn;

      bp := z.rest.rest;
      WHILE (bp # NIL) & (bp.first # NIL) DO
        ok := CompileStmt(bp.first, FALSE, progResult);
        IF ~ok THEN DEC(nBlocks); PopInnerLocals(nProgBinds); RETURN FALSE END;
        bp := bp.rest
      END;
      EmitBranch(againLabel);

      DEC(nBlocks);
      PopInnerLocals(nProgBinds);
      W(retLabel); W(":"); WLn;
      IF wantResult THEN
        W("	PUSH 0"); WLn;
        Strings.Copy("STACK", resultText)
      END;
      termFlag := FALSE;
      RETURN TRUE

    ELSIF headName = "LOWCORE" THEN
      IF ~LowCoreRewrite(z, lcForm) THEN RETURN FALSE END;
      RETURN CompileStmt(lcForm, wantResult, resultText)

    ELSIF headName = "LOWCORE-TABLE" THEN
      (* <LOWCORE-TABLE FIELD length handler> calls <handler <GETB 0 .I>>
         once for each of `length` bytes starting at the field's address:

           SET '?LCT,offset
         again:
           <handler <GETB 0 .?LCT>>
           IGRTR? '?LCT,offset+length-1 \again

         IGRTR? increments the counter and branches when the result is
         GREATER than the limit, so the reversed-polarity branch above is
         what keeps the loop going while bytes remain. The handler may be a
         routine or a builtin (the library passes PRINTC), which is why the
         call is built as a FORM and handed back to the ordinary statement
         path rather than emitted as a CALL here. *)
      IF (z.rest = NIL) OR (z.rest.first = NIL)
         OR (z.rest.rest = NIL) OR (z.rest.rest.first = NIL)
         OR (z.rest.rest.first.kind # ZilObj.KFix)
         OR (z.rest.rest.rest = NIL) OR (z.rest.rest.rest.first = NIL)
         OR (z.rest.rest.rest.first.kind # ZilObj.KAtom) THEN
        Err("CompileStmt: LOWCORE-TABLE expects FIELD, a length, and a handler atom");
        RETURN FALSE
      END;
      IF ~LowCoreSpec("LOWCORE-TABLE", z.rest.first, FALSE, lcOff, lcByte) THEN
        RETURN FALSE
      END;
      IF ~lcByte THEN lcOff := lcOff * 2 END;
      lcLen := z.rest.rest.first.fixVal;
      IF lcLen < 1 THEN
        Err("CompileStmt: LOWCORE-TABLE length must be positive"); RETURN FALSE
      END;

      IF ~AllocInnerLocal("?LCT") THEN RETURN FALSE END;
      ResolveLocal("?LCT", targetName);

      FixText(lcOff, numText);
      W("	SET '"); W(targetName); W(","); W(numText); WLn;
      NewLabel(againLabel);
      W(againLabel); W(":"); WLn;

      lcArg := ZilObj.Cons(ZilObj.KForm, ZilObj.Intern("?LCT"), NIL);
      lcArg := ZilObj.Cons(ZilObj.KForm, ZilObj.Intern("LVAL"), lcArg);
      lcArg := ZilObj.Cons(ZilObj.KForm, lcArg, NIL);
      lcArg := ZilObj.Cons(ZilObj.KForm, ZilObj.NewFix(0), lcArg);
      lcArg := ZilObj.Cons(ZilObj.KForm, ZilObj.Intern("GETB"), lcArg);
      lcForm := ZilObj.Cons(ZilObj.KForm, z.rest.rest.rest.first,
                            ZilObj.Cons(ZilObj.KForm, lcArg, NIL));
      ok := CompileStmt(lcForm, FALSE, progResult);
      IF ~ok THEN PopInnerLocals(1); RETURN FALSE END;

      FixText(lcOff + lcLen - 1, numText);
      W("	IGRTR? '"); W(targetName); W(","); W(numText); W(" \");
      W(againLabel); WLn;
      PopInnerLocals(1);
      IF wantResult THEN Strings.Copy("1", resultText) END;
      termFlag := FALSE;
      RETURN TRUE

    ELSIF headName = "AGAIN" THEN
      IF nBlocks = 0 THEN
        Err("CompileStmt: AGAIN outside any PROG/REPEAT block"); RETURN FALSE
      END;
      (* <AGAIN .NAME> restarts a NAMED enclosing block, which need not be
         the innermost one — MATCH-NOUN-PHRASE's <PROG BITS-SET () ...>
         relies on this: a nested (unnamed) REPEAT from MAP-SCOPE's own
         expansion sits between the AGAIN and its real target, so defaulting
         to "innermost" would restart the wrong loop. *)
      blkIdx := nBlocks - 1;
      IF (z.rest # NIL) & (z.rest.first # NIL) & BlockTargetName(z.rest.first, tgtName) THEN
        IF (curRoutineAct[0] # 0X) & (tgtName = curRoutineAct) THEN
          Err("CompileStmt: AGAIN cannot target the routine itself"); RETURN FALSE
        END;
        blkIdx := FindNamedBlock(tgtName);
        IF blkIdx < 0 THEN
          Strings.Copy("CompileStmt: AGAIN target not found: ", errBuf);
          Strings.Append(tgtName, errBuf);
          Err(errBuf); RETURN FALSE
        END
      END;
      EmitBranch(blockAgain[blkIdx]);
      Strings.Copy("1", resultText); termFlag := TRUE;
      RETURN TRUE

    ELSIF headName = "RETURN" THEN
      (* <RETURN> with no argument yields T. Inside a PROG/REPEAT it leaves
         the BLOCK, not the routine — the original's ReturnOp picks the
         innermost block and branches to its return label, falling back to
         a real routine return only when there is no enclosing block.
         <RETURN value .NAME> targets a NAMED enclosing block instead of the
         innermost one — see AGAIN's identical mechanism and FindNamedBlock
         for why this matters (zillib's SCOPE-EXIT macro: <RETURN -1
         .SCOPE-STAGE-ACTIVATION> must leave the scope-stage ROUTINE even
         from inside a nested loop, not whatever loop happens to be
         innermost at the call site). *)
      IF (z.rest = NIL) OR (z.rest.first = NIL) THEN
        Strings.Copy("1", opText)
      ELSE
        ok := CompileOperand(z.rest.first, opText);
        IF ~ok THEN RETURN FALSE END
      END;
      (* The innermost block that can actually be returned FROM, unless a
         second argument names a specific one. The routine's own block has
         an again label but no return label — the original gives it
         ReturnLabel = null for exactly this reason, so a RETURN with no
         enclosing PROG/REPEAT (or one aimed past all of them) leaves the
         routine. *)
      blkIdx := nBlocks - 1;
      IF (z.rest # NIL) & (z.rest.rest # NIL) & (z.rest.rest.first # NIL)
         & BlockTargetName(z.rest.rest.first, tgtName) THEN
        IF (curRoutineAct[0] # 0X) & (tgtName = curRoutineAct) THEN
          (* the routine's OWN activation atom: leave the routine, exactly
             as an unqualified RETURN with no enclosing block would *)
          blkIdx := -1
        ELSE
          blkIdx := FindNamedBlock(tgtName);
          IF blkIdx < 0 THEN
            Strings.Copy("CompileStmt: RETURN target not found: ", errBuf);
            Strings.Append(tgtName, errBuf);
            Err(errBuf); RETURN FALSE
          END
        END
      ELSE
        WHILE (blkIdx >= 0) & ~blockHasReturn[blkIdx] DO DEC(blkIdx) END
      END;
      IF blkIdx >= 0 THEN
        IF blockWantResult[blkIdx] & (opText # "STACK") THEN
          W("	PUSH "); W(opText); WLn
        END;
        EmitBranch(blockReturn[blkIdx]);
        blockReturned[blkIdx] := TRUE
      ELSE
        W("	RETURN "); W(opText); WLn
      END;
      Strings.Copy(opText, resultText); termFlag := TRUE;
      RETURN TRUE

    ELSIF headName = "TELL" THEN
      ok := CompileTell(z);
      IF ~ok THEN RETURN FALSE END;
      Strings.Copy("1", resultText);
      RETURN TRUE

    ELSIF headName = "QUIT" THEN
      (* ends the program, so like RETURN it leaves nothing to fall through
         to — the entry routine of a real game ends this way *)
      W("	QUIT"); WLn;
      Strings.Copy("1", resultText); termFlag := TRUE;
      RETURN TRUE

    ELSIF (headName = "RTRUE") OR (headName = "RFALSE") THEN
      W("	"); W(headName); WLn;
      IF headName = "RTRUE" THEN Strings.Copy("1", resultText)
      ELSE Strings.Copy("0", resultText) END;
      termFlag := TRUE;
      RETURN TRUE

    ELSIF headName = "RSTACK" THEN
      (* Pops the Z-machine value stack and returns that value - the
         zap mnemonic RSTACK (ret_popped, opcode 184) ZapfOpcodes already
         knows about; this was just missing from CompileStmt's own dispatch.
         Takes no operands, like RTRUE/RFALSE, and terminates the routine the
         same way - gmacros.zil's RFATAL DEFMAC expands to `<PROG () <PUSH 2>
         <RSTACK>>` (push the "fatal" RSTACK code, then return whatever was
         just pushed). *)
      W("	RSTACK"); WLn;
      Strings.Copy("0", resultText);
      termFlag := TRUE;
      RETURN TRUE

    ELSIF headName = "PRINTI" THEN
      IF (z.rest = NIL) OR (z.rest.first = NIL) OR (z.rest.first.kind # ZilObj.KString) THEN
        Err("CompileStmt: PRINTI expects a literal STRING"); RETURN FALSE
      END;
      TranslateZilString(z.rest.first.strBuf^, transText);
      CompileZapString(transText, strText);
      W("	PRINTI "); W(strText); WLn;
      Strings.Copy("1", resultText);
      RETURN TRUE

    ELSIF headName = "CRLF" THEN
      W("	CRLF"); WLn;
      Strings.Copy("1", resultText);
      RETURN TRUE

    ELSIF headName = "PRINTC" THEN
      IF (z.rest = NIL) OR (z.rest.first = NIL) THEN
        Err("CompileStmt: PRINTC expects 1 arg"); RETURN FALSE
      END;
      ok := CompileOperand(z.rest.first, opText);
      IF ~ok THEN RETURN FALSE END;
      W("	PRINTC "); W(opText); WLn;
      Strings.Copy("1", resultText);
      RETURN TRUE

    ELSIF headName = "PRINTR" THEN
      (* print a literal string, then a newline, then return true — one
         Z-machine instruction (print_ret), and it leaves the routine, so
         like RETURN it terminates the statement sequence *)
      IF (z.rest = NIL) OR (z.rest.first = NIL) OR (z.rest.first.kind # ZilObj.KString) THEN
        Err("CompileStmt: PRINTR expects a literal STRING"); RETURN FALSE
      END;
      TranslateZilString(z.rest.first.strBuf^, transText);
      CompileZapString(transText, strText);
      W("	PRINTR "); W(strText); WLn;
      Strings.Copy("1", resultText); termFlag := TRUE;
      RETURN TRUE

    ELSIF headName = "PRINTN" THEN
      IF (z.rest = NIL) OR (z.rest.first = NIL) THEN
        Err("CompileStmt: PRINTN expects 1 arg"); RETURN FALSE
      END;
      ok := CompileOperand(z.rest.first, opText);
      IF ~ok THEN RETURN FALSE END;
      W("	PRINTN "); W(opText); WLn;
      Strings.Copy("1", resultText);
      RETURN TRUE

    ELSIF headName = "COND" THEN
      NewLabel(nextLabel); NewLabel(endLabel);
      elsePart := FALSE;
      c := z.rest;

      WHILE (c # NIL) & (c.first # NIL) & ~elsePart DO
        IF c.first.kind = ZilObj.KFalse THEN
          (* A clause that is ITSELF the FALSE value is never true and
             contributes nothing at all - matches real zilf's own
             CompileCOND exactly (`case ZilFalse: continue;`). Needed
             because #FALSE () now reads as a genuine FALSE-kind value
             (see ZilRead's own comment on why), and real zillib source
             (meta.zil's JIGS-UP, almost certainly a %eval placeholder for
             "no clause here" under some flag combination) puts one
             directly in a COND's own clause list. *)
          c := c.rest
        ELSE
        IF (c.first.kind # ZilObj.KList) OR (c.first.first = NIL) THEN
          Err("CompileStmt: each COND clause must be a non-empty list"); RETURN FALSE
        END;
        cond := c.first.first;
        body := c.first.rest;

        IF (cond.kind = ZilObj.KAtom) & ((cond.atomText = "T") OR (cond.atomText = "ELSE")) THEN
          elsePart := TRUE
        ELSE
          ok := CompileCondition(cond, nextLabel, FALSE);
          IF ~ok THEN RETURN FALSE END
        END;

        IF (body = NIL) OR (body.first = NIL) THEN
          Strings.Copy("1", clauseResult); termFlag := FALSE
        ELSE
          bp := body;
          WHILE (bp # NIL) & (bp.first # NIL) DO
            isLastClauseStmt := (bp.rest = NIL) OR (bp.rest.first = NIL);
            ok := CompileStmt(bp.first, wantResult & isLastClauseStmt, clauseResult);
            IF ~ok THEN RETURN FALSE END;
            bp := bp.rest
          END
        END;

        (* termFlag is now whatever the clause's LAST statement set, i.e.
           whether this clause already left the routine (RETURN/RTRUE/
           RFALSE/QUIT). If it did, the result push and the jump to the end
           label are both unreachable, so don't emit them. *)
        clauseTerminated := termFlag;

        IF wantResult & ~clauseTerminated & (clauseResult # "STACK") THEN
          W("	PUSH "); W(clauseResult); WLn
        END;

        hasMoreClauses := (c.rest # NIL) & (c.rest.first # NIL);
        IF ~clauseTerminated & (hasMoreClauses OR (wantResult & ~elsePart)) THEN
          EmitBranch(endLabel)
        END;

        W(nextLabel); W(":"); WLn;
        IF ~elsePart THEN NewLabel(nextLabel) END;
        c := c.rest
        END
      END;

      IF wantResult & ~elsePart THEN
        W("	PUSH 0"); WLn
      END;
      W(endLabel); W(":"); WLn;
      IF wantResult THEN Strings.Copy("STACK", resultText) END;
      (* A COND as a whole only leaves the routine if EVERY clause does, and
         (when there is no ELSE) only if a clause always matches — neither
         is worth proving here, so report "doesn't terminate" and let the
         caller emit a return that may turn out to be unreachable. The
         alternative error (claiming termination when some path falls
         through) would let control run off the end of a routine. *)
      termFlag := FALSE;
      RETURN TRUE

    ELSIF SimpleBuiltin(headName, sbOpcode, sbN, sbStore) & ~sbStore THEN
      (* a void-only instruction: same operand handling as the value path,
         but nothing is stored, so as a value-wanted statement it yields
         the same stand-in "1" the other void builtins do *)
      ok := CompileArgs(z.rest, sbN, sbArgs, sbCount, sbSpills);
      IF ~ok OR (sbCount > sbN) OR (sbCount < BuiltinMinArgs(headName, sbN)) THEN
        Strings.Copy("CompileStmt: wrong number of arguments to ", sbErr);
        Strings.Append(headName, sbErr);
        Err(sbErr); RETURN FALSE
      END;
      W("	"); W(sbOpcode);
      sbI := 0;
      WHILE sbI < sbCount DO
        IF sbI = 0 THEN W(" ") ELSE W(",") END;
        W(sbArgs[sbI]); INC(sbI)
      END;
      WLn;
      WHILE sbSpills > 0 DO FreeTemp; DEC(sbSpills) END;
      Strings.Copy("1", resultText);
      RETURN TRUE

    ELSIF ~wantResult & (FindRoutineIdx(headName) >= 0) THEN
      (* A routine call whose value is discarded. V1-4 have only storing
         CALL opcodes, so the original pops the unwanted result with
         FSTACK (EmitCall's zversion < 4 branch) rather than leaving it to
         accumulate on the stack. V5+ can't do that: FSTACK's own opcode
         (pop) was removed from the Z-machine at V5 (V6 replaces it with
         pop_stack, not emitted here either), so there is no way to
         discard a V5+ CALL's result other than never storing it — the
         real compiler's own EmitCall switches to the non-storing ICALL
         family (ICALL1/ICALL2/ICALL/IXCALL, the same 0/1/2-3/4+
         argument-count split as CALL1/CALL2/CALL/XCALL) for exactly this
         case, confirmed against a real V5 build of cloak_plus.zil. Found
         by bisecting an "outside a function" cascade all the way down to
         a single CALL+FSTACK pair — FSTACK, with no matching opcode for
         this version, wasn't cleanly rejected; it silently corrupted
         zapf's own function-scope tracking from that point on. *)
      IF ZilModel.zversion >= 5 THEN
        sbN := 7;
        ok := CompileArgs(z.rest, sbN, sbArgs, sbCount, sbSpills);
        IF ~ok THEN
          IF ~errFlag THEN Err("CompileStmt: too many call arguments for this Z-machine version") END;
          RETURN FALSE
        END;
        IF sbCount = 0 THEN Strings.Copy("ICALL1", sbOpcode)
        ELSIF sbCount = 1 THEN Strings.Copy("ICALL2", sbOpcode)
        ELSIF sbCount <= 3 THEN Strings.Copy("ICALL", sbOpcode)
        ELSE Strings.Copy("IXCALL", sbOpcode)
        END;
        W("	"); W(sbOpcode); W(" "); WSym(headName);
        sbI := 0;
        WHILE sbI < sbCount DO W(","); W(sbArgs[sbI]); INC(sbI) END;
        WLn;
        WHILE sbSpills > 0 DO FreeTemp; DEC(sbSpills) END;
        RETURN TRUE
      END;
      ok := CompileOperand(z, opText);
      IF ~ok THEN RETURN FALSE END;
      IF opText = "STACK" THEN W("	FSTACK"); WLn END;
      RETURN TRUE

    ELSE
      RETURN CompileOperand(z, resultText)
    END
  ELSE
    RETURN CompileOperand(z, resultText)
  END
END CompileStmt;

(* Emits one required-args-only routine as `.FUNCT name,param...` followed
   by its body — every statement is compiled via CompileStmt, wanting a
   result only for the last one (matches the original's own CompileStmt/
   BuildRoutine: wantResult is true only for the routine's final
   statement) — and a RETURN of that final value. *)
PROCEDURE CompileRoutine*(idx: INTEGER; isEntry: BOOLEAN): BOOLEAN;
VAR rt: ZilModel.RoutineRec; opText: ARRAY 64 OF CHAR; n, routineAgain: ARRAY 16 OF CHAR;
    a, bp, item, dflt: ZilObj.Zo; ok, isLast: BOOLEAN; i, phase: INTEGER;
BEGIN
  rt := ZilModel.routines[idx];
  Strings.Copy(rt.name.atomText, curRoutine); curStmt[0] := 0X;
  IF rt.act # NIL THEN Strings.Copy(rt.act.atomText, curRoutineAct)
  ELSE curRoutineAct[0] := 0X END;

  bp := rt.body;

  (* ---- the argument spec ----
     <ROUTINE NAME (REQ... "OPT" (O 1) O2 "AUX" (A <expr>) A2) body...>.
     A ZAP .FUNCT line doesn't distinguish the three kinds — they are all
     just the routine's locals, in order, and the Z-machine's own calling
     convention is what makes the leading ones parameters: the caller
     supplies some, and every local the caller didn't supply keeps its
     declared default. So all this has to do is collect them in source
     order and remember each one's default. (Mirrors the original's
     DefineLocalsFromArgSpec + SetOrEmitDefaultValue, minus the
     shadowing-rename logic, which needs the inner-local scoping this port
     doesn't have yet.) *)
  nParams := 0; nLocals := 0; nRenames := 0;
  phase := 0;   (* 0 = required, 1 = "OPT", 2 = "AUX" *)
  (* The ARGUMENT SPEC needs macro expansion as much as the body does — an
     "AUX" local's default value is ordinary code, and zillib really writes
     <ROUTINE R (SPEC "AUX" (A <OBJSPEC-ADJ .SPEC>))>, where that default
     is a DEFSTRUCT accessor macro. The original expands both, in this
     order: ZilRoutine.ExpandInPlace does the arg-spec defaults first and
     the body second. *)
  (* already expanded by PrepareRoutines *)
  a := rt.argSpec;
  WHILE (a # NIL) & (a.first # NIL) DO
    item := a.first;
    IF item.kind = ZilObj.KString THEN
      IF (item.strBuf^ = "OPT") OR (item.strBuf^ = "OPTIONAL") THEN phase := 1
      ELSIF (item.strBuf^ = "AUX") OR (item.strBuf^ = "EXTRA") THEN phase := 2
      ELSE
        Err("CompileRoutine: unsupported argument-spec keyword (only OPT/OPTIONAL/AUX/EXTRA)");
        RETURN FALSE
      END
    ELSE
      IF nParams >= MaxLocals THEN
        Err("CompileRoutine: too many locals"); RETURN FALSE
      END;
      dflt := NIL;
      IF item.kind = ZilObj.KAtom THEN
        Strings.Copy(item.atomText, locName[nParams])
      ELSIF (item.kind = ZilObj.KList) & (item.first # NIL) & (item.first.kind = ZilObj.KAtom) THEN
        Strings.Copy(item.first.atomText, locName[nParams]);
        IF item.rest # NIL THEN dflt := item.rest.first END
      ELSE
        Err("CompileRoutine: an argument must be an atom or (atom default)"); RETURN FALSE
      END;
      locInit[nParams][0] := 0X;
      locExpr[nParams] := NIL;
      IF dflt # NIL THEN
        IF phase = 0 THEN
          Err("CompileRoutine: a required argument cannot have a default value"); RETURN FALSE
        END;
        (* A constant default rides along on the .FUNCT line; anything else
           has to be computed, which for an AUX local is just an assignment
           at the top of the body. An OPT local would additionally need to
           run that assignment only when the caller DIDN'T supply the
           argument, which needs the argument-count test this port doesn't
           emit yet — so refuse that combination rather than silently
           overwriting a supplied value. *)
        IF ~ConstantText(dflt, locInit[nParams]) THEN
          IF phase = 1 THEN
            Err("CompileRoutine: an OPT argument's default must be a constant here");
            RETURN FALSE
          END;
          locInit[nParams][0] := 0X;
          locExpr[nParams] := dflt
        END
      END;
      Strings.Copy(locName[nParams], locZil[nParams]);
      locInScope[nParams] := TRUE;
      INC(nParams); nLocals := nParams
    END;
    a := a.rest
  END;

  (* The body is compiled into a buffer first, because the .FUNCT line has
     to name every local the body uses and the compiler temporaries it needs
     are only known once it has been compiled. *)
  BeginBuffer;

  (* A block for the routine itself, so a bare <AGAIN> in the body loops
     back to the start of the routine — the original pushes exactly this,
     with AgainLabel = rb.RoutineStart and no return label (see the RETURN
     handling in CompileStmt for what the missing return label means). *)
  NewLabel(routineAgain);
  Strings.Copy(routineAgain, blockAgain[0]);
  blockReturn[0][0] := 0X;
  blockNames[0][0] := 0X;
  blockWantResult[0] := FALSE;
  blockReturned[0] := FALSE;
  blockHasReturn[0] := FALSE;
  nBlocks := 1;
  W(routineAgain); W(":"); WLn;

  (* non-constant AUX defaults become assignments at the top of the body,
     before anything else runs *)
  i := 0;
  WHILE i < nParams DO
    IF locExpr[i] # NIL THEN
      ok := CompileOperand(locExpr[i], opText);
      IF ~ok THEN EndBuffer; FlushBuffer; RETURN FALSE END;
      W("	SET '"); W(locName[i]); W(","); W(opText); WLn
    END;
    INC(i)
  END;

  (* Expand every macro call in the body before compiling a single form.
     A ROUTINE's body is captured raw and unevaluated at registration time,
     so a DEFMAC used inside it (TELL above all, and the IF-<FLAG> forms a
     compilation flag brings with it) is still an unexpanded FORM here. The
     original does exactly this, as the first step of compiling a routine:
     ZilRoutine.ExpandInPlace, called from Compilation.Compile.cs. *)

  WHILE (bp # NIL) & (bp.first # NIL) DO
    isLast := (bp.rest = NIL) OR (bp.rest.first = NIL);
    (* The entry routine never wants a result: it has no caller to return
       one to. The original writes exactly this — CompileStmt(rb, stmt,
       !entryPoint && i == BodyLength) in BuildRoutine. *)
    ZilObj.PrintTo(bp.first, curStmt);
    ok := CompileStmt(bp.first, isLast & ~isEntry, opText);
    IF ~ok THEN EndBuffer; FlushBuffer; RETURN FALSE END;
    (* Every binding and temporary a statement allocates must be released by
       the time it finishes. A leak silently consumes one of the routine's
       fifteen local slots for the rest of the routine, which shows up much
       later as a confusing "out of locals" — so check it where it happens. *)
    IF (nRenames # 0) OR (tempDepth # 0) OR (nTmpStack # 0) THEN
      Strings.Copy("internal: leaked ", opText);
      Strings.IntToStr(nRenames, n); Strings.Append(n, opText);
      Strings.Append(" binding(s)/", opText);
      Strings.IntToStr(tempDepth, n); Strings.Append(n, opText);
      Strings.Append(" temp(s) compiling a statement", opText);
      Err(opText); EndBuffer; FlushBuffer; RETURN FALSE
    END;
    IF isLast & ~isEntry & ~termFlag THEN
      (* no implicit fall-through return exists anywhere in the original
         either — every routine explicitly returns its last value, unless
         that last statement already left the routine on its own *)
      W("	RETURN "); W(opText); WLn
    END;
    bp := bp.rest
  END;
  (* "the entry point has to quit instead of returning" (BuildRoutine's own
     comment): returning from the initial routine is undefined in the
     Z-machine, and really does abort — the first compiled run of
     sample/beer ended in frotz's "Fatal error: Illegal opcode" for exactly
     this reason. *)
  IF isEntry & ~termFlag THEN W("	QUIT"); WLn END;
  (* A routine with no statements at all still has to return something —
     see ZilEval's ROUTINE for why an empty body is legal in the first
     place. *)
  IF ~isEntry & ((rt.body = NIL) OR (rt.body.first = NIL)) THEN
    W("	RTRUE"); WLn
  END;
  nBlocks := 0;
  EndBuffer;
  IF errFlag THEN RETURN FALSE END;

  W(".FUNCT "); WSym(rt.name.atomText);
  i := 0;
  WHILE i < nLocals DO
    W(","); W(locName[i]);
    IF locInit[i][0] # 0X THEN W("="); W(locInit[i]) END;
    INC(i)
  END;
  IF nLocals > MaxLocals THEN
    Strings.Copy("CompileRoutine: too many locals: ", opText);
    Strings.IntToStr(nLocals, n); Strings.Append(n, opText);
    Strings.Append(" needed, 15 allowed", opText);
    Err(opText);
    RETURN FALSE
  END;
  WLn;

  (* The entry routine (GO unless the source said otherwise — see the
     original's ZEnvironment.EntryRoutineName, which defaults to the GO
     atom) carries the START:: label the Z-machine header's initial-PC
     field points at; confirmed against real zilf output, where .FUNCT GO
     is immediately followed by START:: and nothing else. *)
  IF isEntry THEN W("START::"); WLn END;

  FlushBuffer;
  WLn;
  curRoutine[0] := 0X;
  RETURN TRUE
END CompileRoutine;

(* ---------------- program-level emission ----------------
   The original splits its output across four files (main code, a data
   file, a strings file and a frequent-words file, stitched together with
   .INSERT — see Zilf.Emit/Zap/GameBuilder.cs's Finish()). This port emits
   one single stream instead, in the same ORDER those .INSERTs produce,
   because that order is what the Z-machine's memory map requires and not
   merely a file-organisation choice:

     assembly constants            (symbols only, no space)
     GLOBAL:: / OBJECT:: / tables  } dynamic memory (writable)
     IMPURE::                      -> header's static-memory base
     VOCAB:: , WORDS::             } static memory (read-only, addressable)
     ENDLOD::                      -> header's high-memory base
     .FUNCT ...                    } high memory (packed addresses only)

   Globals in particular MUST land below IMPURE or writing to them would
   be writing to static memory. *)

(* Emits the CONSTANT declarations as ZAP assembly-time symbol definitions
   ("NAME=value" — matching GameBuilder's own `writer.WriteLine(INDENT +
   "{0}={1}", ...)` for its constants dictionary). A constant whose value
   isn't something this slice can render (a TABLE, a STRING) is skipped with
   a comment rather than failing the whole compile: nothing referring to it
   will compile either, and that reference is the more useful error. *)
PROCEDURE CompileConstants*;
VAR i: INTEGER; text: ARRAY 64 OF CHAR;
BEGIN
  IF ZilModel.nConstants = 0 THEN RETURN END;
  W("	; constants"); WLn;
  i := 0;
  WHILE i < ZilModel.nConstants DO
    IF ConstantText(ZilModel.constants[i].value, text) THEN
      W("	"); WSym(ZilModel.constants[i].name.atomText);
      W("="); W(text); WLn
    ELSE
      W("	; (skipped constant "); W(ZilModel.constants[i].name.atomText);
      W(": value kind not compilable yet)"); WLn
    END;
    INC(i)
  END;
  WLn
END CompileConstants;

(* Emits the global-variable table. Each global becomes one .GVAR, which is
   what allocates its Z-machine variable number (zapf hands out 16, 17, ...
   in declaration order) — so the ORDER here is semantically significant in
   V3, where the interpreter's status line reads HERE, SCORE and MOVES from
   variables 16, 17 and 18 specifically. The original handles that with
   MoveGlobal("HERE", 0) / ("SCORE", 1) / ("MOVES", 2) in FinishGlobals,
   applied only for zversion < 4; `order` below is the same idea, emitting
   those three first (when they exist) and everything else after.

   The original's other job here, DoFunnyGlobals — spilling the overflow
   into a "soft globals" table once more than ~240 globals are defined — is
   deliberately not ported: it only triggers on games that exhaust the
   Z-machine's 240 variable slots, and it drags in indirect table load/store
   for every access to a spilled variable. Report the overflow instead. *)
PROCEDURE CompileGlobals*(): BOOLEAN;
VAR i, j, n: INTEGER; order: ARRAY ZilModel.MaxGlobals OF INTEGER;
    taken: ARRAY ZilModel.MaxGlobals OF BOOLEAN;
    text: ARRAY 64 OF CHAR; errBuf: ARRAY 256 OF CHAR;

  PROCEDURE TakeFirst(name: ARRAY OF CHAR);
  VAR k: INTEGER;
  BEGIN
    k := FindGlobalIdx(name);
    IF (k >= 0) & ~taken[k] THEN taken[k] := TRUE; order[n] := k; INC(n) END
  END TakeFirst;

BEGIN
  IF ZilModel.nGlobals > 240 THEN
    Err("CompileGlobals: more than 240 globals (the soft-globals spill table is not ported)");
    RETURN FALSE
  END;

  i := 0;
  WHILE i < ZilModel.nGlobals DO taken[i] := FALSE; INC(i) END;
  n := 0;
  (* V3 only, exactly as in the original's FinishGlobals: the V3 status line
     is drawn by the interpreter from variables 16/17/18, so HERE, SCORE and
     MOVES have to be the first three .GVARs declared. V4+ draws its status
     line from game code instead, so the order is free. *)
  IF ZilModel.zversion < 4 THEN
    TakeFirst("HERE"); TakeFirst("SCORE"); TakeFirst("MOVES")
  END;
  i := 0;
  WHILE i < ZilModel.nGlobals DO
    IF ~taken[i] THEN order[n] := i; INC(n) END;
    INC(i)
  END;

  W("GLOBAL:: .TABLE"); WLn;
  j := 0;
  WHILE j < n DO
    i := order[j];
    IF ZilModel.globals[i].name.atomText = "VERBS" THEN Strings.Copy("VTBL", text)
    ELSIF ZilModel.globals[i].name.atomText = "ACTIONS" THEN Strings.Copy("ATBL", text)
    ELSIF ZilModel.globals[i].name.atomText = "PREACTIONS" THEN Strings.Copy("PATBL", text)
    ELSIF ZilModel.globals[i].name.atomText = "PREPOSITIONS" THEN Strings.Copy("PRTBL", text)
    ELSIF ZilModel.globals[i].value = NIL THEN
      Strings.Copy("0", text)
    ELSIF ~ConstantText(ZilModel.globals[i].value, text) THEN
      Strings.Copy("CompileGlobals: non-constant initializer for global ", errBuf);
      Strings.Append(ZilModel.globals[i].name.atomText, errBuf);
      Err(errBuf);
      RETURN FALSE
    END;
    W("	.GVAR "); WSym(ZilModel.globals[i].name.atomText);
    W("="); W(text); WLn;
    INC(j)
  END;
  W("	.ENDT"); WLn; WLn;
  RETURN TRUE
END CompileGlobals;

(* Emits every registered TABLE/LTABLE/PTABLE/PLTABLE/ITABLE as a labelled
   ZAP table, so a CONSTANT or GLOBAL holding one has something to point at
   (ConstantText renders a table value as this label). Ported from
   Compilation.Tables.cs's BuildTable, reduced to the element shapes this
   port can render:

     - element width is a word unless the table was flagged BYTE
     - an LTABLE/PLTABLE (the LENGTH flag) is preceded by its element
       count, in the same width as its elements
     - ITABLE's repetition is already expanded when the table value is
       built (PerformITable materialises every element), so nothing extra
       is needed here

     - the LEXV format (a parser input buffer) is a count byte, a zero
       byte, and then triples of word/byte/byte, whatever the table's own
       default width says

   Tables are all emitted in DYNAMIC memory, before the IMPURE::
   marker, even the ones declared PURE: static memory is read-only, so
   putting a pure table there would be the optimisation, and putting it in
   dynamic memory is the safe direction — a game that writes to a table the
   compiler wrongly believed was pure still works. *)
PROCEDURE CompileTables(): BOOLEAN;
VAR i, j: INTEGER; label: ARRAY 512 OF CHAR; text, errBuf: ARRAY 512 OF CHAR;
    t, elemWidth: ZilObj.Zo; isByte, isLexv: BOOLEAN; width: ARRAY 8 OF CHAR;
BEGIN
  i := 0;
  WHILE i < ZilModel.nTables DO
    t := ZilModel.tables[i];
    isByte := (t.tabFlags DIV ZilObj.TfByte) MOD 2 = 1;
    IF isByte THEN Strings.Copy("	.BYTE ", width) ELSE Strings.Copy("	.WORD ", width) END;

    isLexv := (t.tabFlags DIV ZilObj.TfLexv) MOD 2 = 1;

    TableLabel(i, label);
    W(label); W(":: .TABLE"); WLn;

    IF isLexv THEN
      (* A LEXV table is the Z-machine's parse buffer: byte 0 holds how many
         word slots it has, byte 1 is the count the interpreter fills in, and
         each slot is a dictionary address followed by a length byte and an
         offset byte. Ported from the original's BuildTable LEXV branch,
         which likewise writes ElementCount/3 and a zero before the triples.
         Getting this wrong is quiet and total: the interpreter finds zero
         word slots, so every command parses as empty input and the game
         answers "..." to everything. *)
      IF t.vecLen MOD 3 # 0 THEN
        Strings.Copy("CompileTables: a LEXV table's element count must be a multiple of 3: ", errBuf);
        TableLabel(i, label); Strings.Append(label, errBuf);
        Err(errBuf); RETURN FALSE
      END;
      FixText(t.vecLen DIV 3, text);
      W("	.BYTE "); W(text); WLn;
      W("	.BYTE 0"); WLn
    ELSIF (t.tabFlags DIV ZilObj.TfLength) MOD 2 = 1 THEN
      FixText(t.vecLen, text);
      W(width); W(text); WLn
    END;

    j := 0;
    WHILE j < t.vecLen DO
      IF ~ConstantText(t.vecItems[j], text) THEN
        Strings.Copy("CompileTables: element ", errBuf);
        FixText(j, label); Strings.Append(label, errBuf);
        Strings.Append(" of table ", errBuf);
        TableLabel(i, label); Strings.Append(label, errBuf);
        Strings.Append(" is not a compilable constant: ", errBuf);
        ZilObj.PrintTo(t.vecItems[j], label);
        Strings.Append(label, errBuf);
        Err(errBuf); RETURN FALSE
      END;
      (* an element written <BYTE n> or <WORD n> overrides the table's own
         default width for that element alone — see ZilEval's BYTE/WORD *)
      elemWidth := ZilObj.GetProp(t.vecItems[j], ZilObj.Intern("WIDTH "));
      IF isLexv THEN
        (* the triple's shape fixes the widths, so neither the table's
           default nor a per-element <BYTE n> applies *)
        IF j MOD 3 = 0 THEN W("	.WORD ") ELSE W("	.BYTE ") END
      ELSIF elemWidth = NIL THEN W(width)
      ELSIF elemWidth.atomText = "BYTE" THEN W("	.BYTE ")
      ELSE W("	.WORD ")
      END;
      W(text); WLn;
      INC(j)
    END;

    W("	.ENDT"); WLn; WLn;
    INC(i)
  END;
  RETURN TRUE
END CompileTables;

(* ---------------- objects, properties and flags ----------------
   Ported from Compilation.Objects.cs + Zilf.Emit/Zap's ObjectBuilder and
   GameBuilder.FinishObjects. An OBJECT/ROOM's property list is raw and
   uninterpreted until now (ZilModel stores it exactly as read), so this is
   where DESC, IN/LOC, FLAGS and ordinary properties are finally told apart.

   Numbering follows the original exactly, and both count DOWNWARDS:
   property numbers start at the maximum (31 in V1-3, 63 in V4+) and
   descend in definition order, flag numbers start at the maximum minus one
   (31 / 47) and descend. Getting this backwards would still assemble and
   still run — it would just silently disagree with every property default
   slot — so it is worth stating.

   SYNONYM, ADJECTIVE, PSEUDO and direction properties (`(NORTH TO
   CELLAR)`) all need the vocabulary and/or complex-PROPDEF pattern
   machinery, so each gets its own dedicated handling below rather than
   going through the generic constant-value path every other property
   uses. *)

PROCEDURE MaxProps(): INTEGER;
BEGIN IF ZilModel.zversion < 4 THEN RETURN 31 ELSE RETURN 63 END END MaxProps;

PROCEDURE MaxFlags(): INTEGER;
BEGIN IF ZilModel.zversion < 4 THEN RETURN 32 ELSE RETURN 48 END END MaxFlags;

PROCEDURE RegisterFlag(name: ARRAY OF CHAR): INTEGER;
VAR i: INTEGER; real: ARRAY 64 OF CHAR;
BEGIN
  i := FindFlagIdx(name);
  IF i >= 0 THEN RETURN i END;
  (* an alias names its target's bit, so registering it registers the target *)
  IF ZilModel.BitSynonymOf(name, real) THEN
    Strings.Copy(real, name)
  END;
  IF nFlagNames >= MaxFlagNames THEN RETURN -1 END;
  Strings.Copy(name, flagNameTab[nFlagNames]);
  INC(nFlagNames);
  RETURN nFlagNames - 1
END RegisterFlag;

PROCEDURE RegisterProp(name: ARRAY OF CHAR): INTEGER;
VAR i: INTEGER;
BEGIN
  i := FindPropIdx(name);
  IF i >= 0 THEN RETURN i END;
  IF nPropNames >= MaxPropNames THEN RETURN -1 END;
  Strings.Copy(name, propNameTab[nPropNames]);
  INC(nPropNames);
  RETURN nPropNames - 1
END RegisterProp;

(* True for the property names this port interprets itself rather than
   emitting as ordinary properties. *)
PROCEDURE IsPseudoProperty(name: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN (name = "DESC") OR (name = "IN") OR (name = "LOC") OR (name = "FLAGS")
END IsPseudoProperty;

(* Whether this (IN ...) or (LOC ...) is the object's LOCATION rather than a
   property. IN is both a pseudo-property and one of zillib's directions, so
   the name alone cannot say which: (IN ROOMS) is a parent, (IN TO CAVE) and
   (IN SORRY "...") are exits. The original keeps the two uses apart the same
   way, by whether the body matches the direction pattern — and notes that IN
   is where this comes up in practice.

   Getting it wrong both ways round: treating (IN SORRY "...") as a location
   rejects it as a non-constant property value, and treating (IN ROOMS) as a
   property emits an IN exit on every object whose data is really its parent's
   object number. *)
PROCEDURE IsLocationProperty(name: ARRAY OF CHAR; body: ZilObj.Zo): BOOLEAN;
BEGIN
  RETURN ((name = "IN") OR (name = "LOC"))
       & (body # NIL) & (body.first # NIL) & (body.first.kind = ZilObj.KAtom)
       & ((body.rest = NIL) OR (body.rest.first = NIL))
       & (FindObjectIdx(body.first.atomText) >= 0)
END IsLocationProperty;

(* SYNONYM and ADJECTIVE are real properties, but their values are
   DICTIONARY WORDS rather than ordinary constants, so they are emitted by
   their own code below. PSEUDO (a list of word/routine pairs for scenery)
   is handled the same way, just further down (its STRING elements are
   vocabulary words too, but its ATOM elements are ordinary routine
   references, unlike SYNONYM/ADJECTIVE's all-atom shape). *)
PROCEDURE IsWordProperty(name: ARRAY OF CHAR): BOOLEAN;
BEGIN RETURN (name = "SYNONYM") OR (name = "ADJECTIVE") END IsWordProperty;

(* A direction property like (NORTH TO CELLAR) is a complex PROPDEF pattern,
   recognised here by the TO/PER/SORRY keywords real source uses. *)
PROCEDURE IsDirectionProperty(body: ZilObj.Zo): BOOLEAN;
VAR p: ZilObj.Zo;
BEGIN
  p := body;
  WHILE (p # NIL) & (p.first # NIL) DO
    IF p.first.kind = ZilObj.KAtom THEN
      IF (p.first.atomText = "TO") OR (p.first.atomText = "PER")
         OR (p.first.atomText = "SORRY") THEN RETURN TRUE END
    END;
    p := p.rest
  END;
  RETURN FALSE
END IsDirectionProperty;

(* Emits one direction property. Its byte layout comes from the built-in
   DIRECTIONS PROPDEF rather than from the property list, which is why it
   cannot go through the ordinary value path. Ported from
   Context.InitPropDefs's SDirectionsPropDef_V3, which spells out the shapes:

     (DIR TO R)                      UEXIT 1: room byte
     (DIR SORRY S)                   NEXIT 2: string word
     (DIR PER F)                     FEXIT 3: routine word, zero byte
     (DIR TO R IF G ["OPT"] ELSE S)  CEXIT 4: room, global, string word
     (DIR TO R IF D IS OPEN
                   ["OPT"] ELSE S)   DEXIT 5: room, door, string word, zero
     (DIR R) / (DIR S)               the bare forms of UEXIT and NEXIT

   The LENGTH is what identifies the kind at run time: zillib's V-WALK
   switches on <PTSIZE .PT> against its UEXIT/NEXIT/FEXIT/CEXIT/DEXIT
   constants, which are exactly 1..5 in V3.

   V3 layout only. V4+ widens object numbers to words and pads differently;
   CompileProgram already refuses every version above 4, and V4 rooms with
   exits are not covered yet. *)
PROCEDURE EmitDirectionProp(propName: ARRAY OF CHAR; body: ZilObj.Zo;
                            objName: ARRAY OF CHAR): BOOLEAN;
VAR p, toObj, sorryStr, perFcn, ifObj, elseStr: ZilObj.Zo;
    isOpen, isFirst: BOOLEAN;
    text, errBuf: ARRAY 512 OF CHAR;

  PROCEDURE Fail(what: ARRAY OF CHAR): BOOLEAN;
  BEGIN
    Strings.Copy("CompileObjects: ", errBuf);
    Strings.Append(objName, errBuf); Strings.Append("'s ", errBuf);
    Strings.Append(propName, errBuf); Strings.Append(" property ", errBuf);
    Strings.Append(what, errBuf);
    Err(errBuf); RETURN FALSE
  END Fail;

  PROCEDURE EmitPropHead(len: INTEGER);
  VAR n: ARRAY 16 OF CHAR;
  BEGIN
    FixText(len, n);
    W("	.PROP "); W(n); W(",P?"); WSym(propName); WLn
  END EmitPropHead;

  (* the message word of a CEXIT/DEXIT/NEXIT; an omitted "OPT" ELSE is 0 *)
  PROCEDURE EmitMsgWord(z: ZilObj.Zo): BOOLEAN;
  BEGIN
    IF z = NIL THEN W("	.WORD 0"); WLn; RETURN TRUE END;
    IF ~ConstantText(z, text) THEN
      RETURN Fail("has a message that is not a compilable constant")
    END;
    W("	.WORD "); W(text); WLn;
    RETURN TRUE
  END EmitMsgWord;

BEGIN
  toObj := NIL; sorryStr := NIL; perFcn := NIL; ifObj := NIL; elseStr := NIL;
  isOpen := FALSE; isFirst := TRUE;
  p := body;
  WHILE (p # NIL) & (p.first # NIL) DO
    IF (p.first.kind = ZilObj.KAtom) & (p.first.atomText = "TO") THEN
      p := p.rest;
      IF (p = NIL) OR (p.first = NIL) THEN RETURN Fail("has TO with no room") END;
      toObj := p.first
    ELSIF (p.first.kind = ZilObj.KAtom) & (p.first.atomText = "SORRY") THEN
      p := p.rest;
      IF (p = NIL) OR (p.first = NIL) THEN RETURN Fail("has SORRY with no message") END;
      sorryStr := p.first
    ELSIF (p.first.kind = ZilObj.KAtom) & (p.first.atomText = "PER") THEN
      p := p.rest;
      IF (p = NIL) OR (p.first = NIL) THEN RETURN Fail("has PER with no routine") END;
      perFcn := p.first
    ELSIF (p.first.kind = ZilObj.KAtom) & (p.first.atomText = "IF") THEN
      p := p.rest;
      IF (p = NIL) OR (p.first = NIL) THEN RETURN Fail("has IF with no condition") END;
      ifObj := p.first
    ELSIF (p.first.kind = ZilObj.KAtom) & (p.first.atomText = "IS") THEN
      p := p.rest;
      IF (p = NIL) OR (p.first = NIL) OR (p.first.kind # ZilObj.KAtom)
         OR (p.first.atomText # "OPEN") THEN
        RETURN Fail("has IS without OPEN")
      END;
      isOpen := TRUE
    ELSIF (p.first.kind = ZilObj.KAtom) & (p.first.atomText = "ELSE") THEN
      p := p.rest;
      IF (p = NIL) OR (p.first = NIL) THEN RETURN Fail("has ELSE with no message") END;
      elseStr := p.first
    ELSIF isFirst THEN
      (* the bare forms, which name a room or give a message directly *)
      IF p.first.kind = ZilObj.KString THEN sorryStr := p.first
      ELSE toObj := p.first END
    ELSE
      RETURN Fail("has a part this port does not recognise")
    END;
    isFirst := FALSE;
    p := p.rest
  END;

  IF perFcn # NIL THEN
    IF ~ConstantText(perFcn, text) THEN RETURN Fail("names an unknown routine") END;
    EmitPropHead(3);
    W("	.WORD "); W(text); WLn;
    W("	.BYTE 0"); WLn;
    RETURN TRUE
  END;

  IF toObj = NIL THEN
    IF sorryStr = NIL THEN RETURN Fail("has no destination") END;
    EmitPropHead(2);
    RETURN EmitMsgWord(sorryStr)
  END;

  IF ~ConstantText(toObj, text) THEN RETURN Fail("names an unknown room") END;
  IF ifObj = NIL THEN
    EmitPropHead(1);
    W("	.BYTE "); W(text); WLn;
    RETURN TRUE
  END;

  IF isOpen THEN EmitPropHead(5) ELSE EmitPropHead(4) END;
  W("	.BYTE "); W(text); WLn;
  (* a CEXIT's condition is a GLOBAL, whose byte is its Z-machine variable
     number - which is what the .GVAR-defined symbol evaluates to, and which
     ConstantText does not look up because a global is normally reached as
     `,NAME` instead *)
  IF (ifObj.kind = ZilObj.KAtom) & (FindGlobalIdx(ifObj.atomText) >= 0) THEN
    Strings.Copy(ifObj.atomText, text); SanitizePrefixed(text)
  ELSIF ~ConstantText(ifObj, text) THEN
    RETURN Fail("names an unknown door object or flag global")
  END;
  W("	.BYTE "); W(text); WLn;
  IF ~EmitMsgWord(elseStr) THEN RETURN FALSE END;
  IF isOpen THEN W("	.BYTE 0"); WLn END;
  RETURN TRUE
END EmitDirectionProp;

(* Emits the whole object table: the property-default words, one .OBJECT
   row per object, and a property table per object. *)
PROCEDURE CompileObjects(): BOOLEAN;
VAR i, j, k, num, nOwnProps: INTEGER;
    o: ZilModel.ObjectRec; p, body, v: ZilObj.Zo;
    nm, text, errBuf: ARRAY 256 OF CHAR;
    flagsWord: ARRAY 3, 256 OF CHAR;
    haveDesc: BOOLEAN;
BEGIN
  nFlagNames := 0; nPropNames := 0;

  (* --- pass 1: discover every flag and property name --- *)
  (* PROPDEF-declared names first, so a property with a declared default is
     certain to get a slot even if no object uses it *)
  i := 0;
  WHILE i < ZilModel.nPropDefaults DO
    k := RegisterProp(ZilModel.propDefaults[i].name.atomText);
    IF k < 0 THEN Err("CompileObjects: too many properties"); RETURN FALSE END;
    INC(i)
  END;

  (* Every DIRECTION is also a PROPERTY: a room's exits are stored as
     properties named after the directions, so <DIRECTIONS NORTH ... IN ...>
     implies P?NORTH ... P?IN. (This is also why IN and DESC can be both a
     pseudo-property and a real one — the original tracks the two uses
     separately for exactly this reason.) *)
  i := 0;
  WHILE i < ZilModel.nDirections DO
    IF ZilModel.directions[i].kind = ZilObj.KAtom THEN
      k := RegisterProp(ZilModel.directions[i].atomText);
      IF k < 0 THEN Err("CompileObjects: too many properties"); RETURN FALSE END
    END;
    INC(i)
  END;

  i := 0;
  WHILE i < ZilModel.nObjects DO
    objParent[i] := -1; objSibling[i] := -1; objChild[i] := -1;
    p := ZilModel.objects[i].props;
    WHILE (p # NIL) & (p.first # NIL) DO
      IF (p.first.kind = ZilObj.KList) & (p.first.first # NIL)
         & (p.first.first.kind = ZilObj.KAtom) THEN
        Strings.Copy(p.first.first.atomText, nm);
        IF nm = "FLAGS" THEN
          body := p.first.rest;
          WHILE (body # NIL) & (body.first # NIL) DO
            IF body.first.kind = ZilObj.KAtom THEN
              k := RegisterFlag(body.first.atomText);
              IF k < 0 THEN Err("CompileObjects: too many flags"); RETURN FALSE END
            END;
            body := body.rest
          END
        ELSIF IsWordProperty(nm) THEN
          (* an object's nouns and adjectives are dictionary words *)
          k := RegisterProp(nm);
          IF k < 0 THEN Err("CompileObjects: too many properties"); RETURN FALSE END;
          body := p.first.rest;
          WHILE (body # NIL) & (body.first # NIL) DO
            IF body.first.kind = ZilObj.KAtom THEN
              IF nm = "SYNONYM" THEN
                j := ZilModel.AddVocab(body.first.atomText, ZilModel.PsObject)
              ELSE
                j := ZilModel.AddVocab(body.first.atomText, ZilModel.PsAdjective)
              END;
              IF j < 0 THEN Err("CompileObjects: too many vocabulary words"); RETURN FALSE END
            END;
            body := body.rest
          END
        ELSIF nm = "PSEUDO" THEN
          (* (PSEUDO "WORD" ACTION-ROUTINE ...): scenery words that only
             exist so a room can react to them (zork1's rooms are full of
             these — "nails", "chasm", "gate"...). Each STRING element is a
             vocabulary NOUN, exactly like a SYNONYM atom is, just spelled
             as a string in source; the ATOM elements between them name
             action routines and need no registration of their own. *)
          k := RegisterProp(nm);
          IF k < 0 THEN Err("CompileObjects: too many properties"); RETURN FALSE END;
          body := p.first.rest;
          WHILE (body # NIL) & (body.first # NIL) DO
            IF body.first.kind = ZilObj.KString THEN
              j := ZilModel.AddVocab(body.first.strBuf^, ZilModel.PsObject);
              IF j < 0 THEN Err("CompileObjects: too many vocabulary words"); RETURN FALSE END
            END;
            body := body.rest
          END
        ELSIF ~IsPseudoProperty(nm) & ~IsDirectionProperty(p.first.rest) THEN
          k := RegisterProp(nm);
          IF k < 0 THEN Err("CompileObjects: too many properties"); RETURN FALSE END
        END
      END;
      p := p.rest
    END;
    INC(i)
  END;

  IF nFlagNames > MaxFlags() THEN
    Err("CompileObjects: too many flags for this Z-machine version"); RETURN FALSE
  END;
  IF nPropNames > MaxProps() THEN
    Err("CompileObjects: too many properties for this Z-machine version"); RETURN FALSE
  END;

  (* --- pass 2: the containment tree ---
     each child is pushed onto the front of its parent's child list, exactly
     as the original does (ob.Sibling = parent.Child; parent.Child = ob) *)
  i := 0;
  WHILE i < ZilModel.nObjects DO
    p := ZilModel.objects[i].props;
    WHILE (p # NIL) & (p.first # NIL) DO
      IF (p.first.kind = ZilObj.KList) & (p.first.first # NIL)
         & (p.first.first.kind = ZilObj.KAtom) THEN
        Strings.Copy(p.first.first.atomText, nm);
        IF ((nm = "IN") OR (nm = "LOC")) & (p.first.rest # NIL)
           & (p.first.rest.first # NIL) & (p.first.rest.first.kind = ZilObj.KAtom)
           & ((p.first.rest.rest = NIL) OR (p.first.rest.rest.first = NIL)) THEN
          j := FindObjectIdx(p.first.rest.first.atomText);
          IF j >= 0 THEN
            objParent[i] := j;
            objSibling[i] := objChild[j];
            objChild[j] := i
          ELSE
            Strings.Copy("CompileObjects: no such object: ", errBuf);
            Strings.Append(p.first.rest.first.atomText, errBuf);
            Err(errBuf); RETURN FALSE
          END
        END
      END;
      p := p.rest
    END;
    INC(i)
  END;

  (* --- flag and property symbols --- *)
  IF nFlagNames > 0 THEN
    W("	; object flags"); WLn;
    i := 0;
    WHILE i < nFlagNames DO
      num := MaxFlags() - 1 - i;
      FixText(num, text);
      W("	"); W(flagNameTab[i]); W("="); W(text); WLn;
      (* FX?NAME is the single-bit mask for the flag within its word, which
         is what an .OBJECT row's flag words are built from *)
      k := 1; j := 0;
      WHILE j < 15 - (num MOD 16) DO k := k * 2; INC(j) END;
      FixText(k, text);
      W("	FX?"); W(flagNameTab[i]); W("="); W(text); WLn;
      INC(i)
    END;
    (* A <BIT-SYNONYM> alias gets its own pair of symbols equal to the flag
       it shares, so code and object rows written with either name assemble.
       The original does the same, as DefineFlagAlias adding a Constants
       entry pointing at the original's flag builder. *)
    j := 0;
    WHILE j < ZilModel.nBitSynonyms DO
      IF FindFlagIdx(ZilModel.bitSynTarget[j]) >= 0 THEN
        W("	"); WSym(ZilModel.bitSynAlias[j]);
        W("="); WSym(ZilModel.bitSynTarget[j]); WLn;
        W("	FX?"); WSym(ZilModel.bitSynAlias[j]);
        W("=FX?"); WSym(ZilModel.bitSynTarget[j]); WLn
      END;
      INC(j)
    END;
    WLn
  END;

  IF nPropNames > 0 THEN
    W("	; object properties"); WLn;
    i := 0;
    WHILE i < nPropNames DO
      FixText(MaxProps() - i, text);
      W("	P?"); W(propNameTab[i]); W("="); W(text); WLn;
      INC(i)
    END;
    (* LOW-DIRECTION is the smallest property number used by a direction.
       MAP-DIRECTIONS walks property numbers downwards from the top and
       stops there, and the library reads it too. Property numbers count
       down from the maximum in registration order, so the last-registered
       direction has the smallest. *)
    num := MaxProps() + 1;
    j := 0;
    WHILE j < ZilModel.nDirections DO
      IF ZilModel.directions[j].kind = ZilObj.KAtom THEN
        k := FindPropIdx(ZilModel.directions[j].atomText);
        IF (k >= 0) & (MaxProps() - k < num) THEN num := MaxProps() - k END
      END;
      INC(j)
    END;
    IF num > MaxProps() THEN num := MaxProps() END;
    FixText(num, text);
    W("	LOW-DIRECTION="); W(text); WLn;
    WLn
  END;

  (* --- the object table itself --- *)
  W("OBJECT:: .TABLE"); WLn;

  (* property defaults, in property-number order 1..MaxProps *)
  num := 1;
  WHILE num <= MaxProps() DO
    i := MaxProps() - num;    (* the registration index with this number *)
    Strings.Copy("0", text);
    IF (i >= 0) & (i < nPropNames) THEN
      W("	; "); W(propNameTab[i]); WLn;
      j := 0;
      WHILE j < ZilModel.nPropDefaults DO
        IF ZilModel.propDefaults[j].name.atomText = propNameTab[i] THEN
          IF ~ConstantText(ZilModel.propDefaults[j].value, text) THEN
            Strings.Copy("0", text)
          END
        END;
        INC(j)
      END
    END;
    W("	.WORD "); W(text); WLn;
    INC(num)
  END;

  IF ZilModel.nObjects > 0 THEN WLn END;

  i := 0;
  WHILE i < ZilModel.nObjects DO
    o := ZilModel.objects[i];
    Strings.Copy("0", flagsWord[0]);
    Strings.Copy("0", flagsWord[1]);
    Strings.Copy("0", flagsWord[2]);

    p := o.props;
    WHILE (p # NIL) & (p.first # NIL) DO
      IF (p.first.kind = ZilObj.KList) & (p.first.first # NIL)
         & (p.first.first.kind = ZilObj.KAtom) & (p.first.first.atomText = "FLAGS") THEN
        body := p.first.rest;
        WHILE (body # NIL) & (body.first # NIL) DO
          IF body.first.kind = ZilObj.KAtom THEN
            k := RegisterFlag(body.first.atomText);
            num := MaxFlags() - 1 - k;
            j := num DIV 16;
            IF flagsWord[j] = "0" THEN flagsWord[j][0] := 0X
            ELSE Strings.Append("+", flagsWord[j]) END;
            Strings.Append("FX?", flagsWord[j]);
            Strings.Append(flagNameTab[k], flagsWord[j])
          END;
          body := body.rest
        END
      END;
      p := p.rest
    END;

    W("	.OBJECT "); WSym(o.name.atomText);
    W(","); W(flagsWord[0]);
    W(","); W(flagsWord[1]);
    IF ZilModel.zversion >= 4 THEN W(","); W(flagsWord[2]) END;
    (* Parent/sibling/child are object references and go through WSym just
       like the .OBJECT name itself - a name with a character ZAP disallows
       in a bare symbol (advent has IN-AWKWARD-SLOPING-E/W-CANYON) sanitizes
       to the SAME spelling wherever it is written, which is what makes the
       reference resolve. Leaving these three raw was a real bug: the row
       DEFINING that object sanitized its own name, but every OTHER row
       that named it as a sibling did not, so the two spellings disagreed
       and zapf reported "undefined symbol". *)
    IF objParent[i] >= 0 THEN W(","); WSym(ZilModel.objects[objParent[i]].name.atomText)
    ELSE W(",0") END;
    IF objSibling[i] >= 0 THEN W(","); WSym(ZilModel.objects[objSibling[i]].name.atomText)
    ELSE W(",0") END;
    IF objChild[i] >= 0 THEN W(","); WSym(ZilModel.objects[objChild[i]].name.atomText)
    ELSE W(",0") END;
    W(",?PTBL?"); WSym(o.name.atomText); WLn;
    INC(i)
  END;
  W("	.ENDT"); WLn; WLn;

  (* --- one property table per object ---
     properties must appear in DESCENDING property-number order, which the
     Z-machine's property lookup relies on *)
  i := 0;
  WHILE i < ZilModel.nObjects DO
    o := ZilModel.objects[i];
    W("?PTBL?"); WSym(o.name.atomText); W(":: .TABLE"); WLn;

    haveDesc := FALSE;
    p := o.props;
    WHILE (p # NIL) & (p.first # NIL) DO
      IF (p.first.kind = ZilObj.KList) & (p.first.first # NIL)
         & (p.first.first.kind = ZilObj.KAtom) & (p.first.first.atomText = "DESC")
         & (p.first.rest # NIL) & (p.first.rest.first # NIL)
         & (p.first.rest.first.kind = ZilObj.KString) THEN
        TranslateZilString(p.first.rest.first.strBuf^, text);
        CompileZapString(text, errBuf);
        W("	.STRL "); W(errBuf); WLn;
        haveDesc := TRUE
      END;
      p := p.rest
    END;
    IF ~haveDesc THEN W('	.STRL ""'); WLn END;

    (* walk the property table in descending number order, which means
       ascending registration index *)
    k := 0;
    WHILE k < nPropNames DO
      p := o.props;
      WHILE (p # NIL) & (p.first # NIL) DO
        IF (p.first.kind = ZilObj.KList) & (p.first.first # NIL)
           & (p.first.first.kind = ZilObj.KAtom)
           & (p.first.first.atomText = propNameTab[k]) THEN
        IF IsDirectionProperty(p.first.rest) THEN
          (* a direction property is laid out by the DIRECTIONS PROPDEF, not
             by its value list *)
          IF ~EmitDirectionProp(propNameTab[k], p.first.rest, o.name.atomText) THEN
            RETURN FALSE
          END
        ELSIF IsLocationProperty(propNameTab[k], p.first.rest) THEN
          (* the object's parent, already recorded in the .OBJECT row *)
        ELSE
          body := p.first.rest;
          nOwnProps := 0; v := body;
          WHILE (v # NIL) & (v.first # NIL) DO INC(nOwnProps); v := v.rest END;
          IF nOwnProps = 0 THEN
            Strings.Copy("CompileObjects: property has no value: ", errBuf);
            Strings.Append(propNameTab[k], errBuf);
            Err(errBuf); RETURN FALSE
          END;
          IF IsWordProperty(propNameTab[k]) THEN
            (* SYNONYM holds word addresses (two bytes each). ADJECTIVE
               holds the adjective NUMBER in V1-3 — one byte, via the
               A?NAME constant — and the word address in V4+, which is the
               original's own version split. *)
            IF (propNameTab[k] = "ADJECTIVE") & (ZilModel.zversion < 4) THEN
              FixText(nOwnProps, text);
              W("	.PROP "); W(text); W(",P?"); W(propNameTab[k]); WLn;
              v := body;
              WHILE (v # NIL) & (v.first # NIL) DO
                IF v.first.kind # ZilObj.KAtom THEN
                  Strings.Copy("CompileObjects: ADJECTIVE values must be atoms, in object ", errBuf);
                  Strings.Append(o.name.atomText, errBuf);
                  Strings.Append(": ", errBuf);
                  ZilObj.PrintTo(v.first, nm); Strings.Append(nm, errBuf);
                  Err(errBuf); RETURN FALSE
                END;
                (* the word part goes through WSym, matching how the A?WORD
                   constant itself is defined (EmitVocabTable's own A?
                   emission) - a word with a character ZAP disallows bare
                   (advent's "pirate's") needs the SAME sanitized spelling
                   on both sides or the reference does not resolve. *)
                W("	.BYTE A?"); WSym(v.first.atomText); WLn;
                v := v.rest
              END
            ELSE
              FixText(nOwnProps * 2, text);
              W("	.PROP "); W(text); W(",P?"); W(propNameTab[k]); WLn;
              v := body;
              WHILE (v # NIL) & (v.first # NIL) DO
                IF v.first.kind # ZilObj.KAtom THEN
                  Strings.Copy("CompileObjects: SYNONYM values must be atoms, in object ", errBuf);
                  Strings.Append(o.name.atomText, errBuf);
                  Strings.Append(": ", errBuf);
                  ZilObj.PrintTo(v.first, nm); Strings.Append(nm, errBuf);
                  Err(errBuf); RETURN FALSE
                END;
                W("	.WORD W?"); WSym(v.first.atomText); WLn;
                v := v.rest
              END
            END
          ELSIF (propNameTab[k] = "GLOBAL") & (ZilModel.zversion = 3) THEN
            (* On V3 an object number fits in one byte, and GLOBAL is a list
               of object references — so the original stores it one BYTE per
               object rather than the generic two. Without this, a room with
               five GLOBAL objects (advent has several) needs 10 bytes, over
               V3's 8-byte property limit; at one byte each it fits in 5. V4+
               widens object numbers to a word, so it just takes the generic
               path below like any other list-of-objects property. *)
            FixText(nOwnProps, text);
            W("	.PROP "); W(text); W(",P?"); W(propNameTab[k]); WLn;
            v := body;
            WHILE (v # NIL) & (v.first # NIL) DO
              IF (v.first.kind # ZilObj.KAtom) OR (FindObjectIdx(v.first.atomText) < 0) THEN
                Strings.Copy("CompileObjects: GLOBAL values must be objects, in object ", errBuf);
                Strings.Append(o.name.atomText, errBuf);
                Strings.Append(": ", errBuf);
                ZilObj.PrintTo(v.first, nm); Strings.Append(nm, errBuf);
                Err(errBuf); RETURN FALSE
              END;
              W("	.BYTE "); WSym(v.first.atomText); WLn;
              v := v.rest
            END
          ELSIF propNameTab[k] = "PSEUDO" THEN
            (* one WORD per element regardless of shape: a STRING is its
               vocabulary word's address (W?WORD, registered above in pass
               1), an ATOM is its action routine's address by the ordinary
               constant path - matching the original's own AddWord/
               CompileConstant split exactly. *)
            FixText(nOwnProps * 2, text);
            W("	.PROP "); W(text); W(",P?"); W(propNameTab[k]); WLn;
            v := body;
            WHILE (v # NIL) & (v.first # NIL) DO
              IF v.first.kind = ZilObj.KString THEN
                W("	.WORD W?"); WSym(v.first.strBuf^); WLn
              ELSIF ConstantText(v.first, text) THEN
                W("	.WORD "); W(text); WLn
              ELSE
                Strings.Copy("CompileObjects: PSEUDO value is not a string or a compilable constant, in object ", errBuf);
                Strings.Append(o.name.atomText, errBuf);
                Strings.Append(": ", errBuf);
                ZilObj.PrintTo(v.first, nm); Strings.Append(nm, errBuf);
                Err(errBuf); RETURN FALSE
              END;
              v := v.rest
            END
          ELSE
          FixText(nOwnProps * 2, text);
          W("	.PROP "); W(text); W(",P?"); W(propNameTab[k]); WLn;
          v := body;
          WHILE (v # NIL) & (v.first # NIL) DO
            IF ~ConstantText(v.first, text) THEN
              Strings.Copy("CompileObjects: non-constant value in property ", errBuf);
              Strings.Append(propNameTab[k], errBuf);
              Strings.Append(" of object ", errBuf);
              Strings.Append(o.name.atomText, errBuf);
              Strings.Append(": ", errBuf);
              ZilObj.PrintTo(v.first, nm); Strings.Append(nm, errBuf);
              Err(errBuf); RETURN FALSE
            END;
            W("	.WORD "); W(text); WLn;
            v := v.rest
          END
          END
        END
        END;
        p := p.rest
      END;
      INC(k)
    END;

    W("	.BYTE 0"); WLn;
    W("	.ENDT"); WLn; WLn;
    INC(i)
  END;
  RETURN TRUE
END CompileObjects;

(* Emits an empty-but-well-formed V3 object table and dictionary, so a
   program that doesn't use objects or the parser still produces a story
   file an interpreter will load. A V3 object table starts with 31 words of
   property defaults (the Z-machine spec's fixed size for V1-3) followed by
   the object entries — of which there are none yet; a dictionary is a
   count+list of word separators, then the entry length, then the entry
   count (zero here), matching the original's own empty-vocabulary case
   (".BYTE 7" / ".WORD 0" in FinishSyntax).

   Object and vocabulary emission proper are their own later slices (the
   original's Compilation.Objects.cs and Compilation.Syntax.cs); until then
   this keeps the header's OBJECT and VOCAB pointers valid rather than
   aiming them at whatever byte happens to follow. *)
(* ---------------- syntax, action and verb tables ----------------
   Ported from Compilation.Syntax.cs. Four tables, all read directly by the
   library's parser at run time (see zillib/parser.zil):

     VTBL   one word per possible verb value, indexed <- 255 verbValue>,
            pointing at that verb's syntax table
     ST?V   a verb's syntax table: a count byte, then one 8-byte line each
     ATBL   one word per action: the action routine
     PATBL  one word per action: the pre-action routine, or 0
     PRTBL  a count word, then (word address, PR? number) per preposition

   The 8-byte line is the original's "ZILF 1.1 extended syntax line
   format": nobj, prep1, prep2, find1, find2, opts1, opts2, action — where
   nobj's low two bits are the object count. Lines are emitted in REVERSE
   definition order within a verb, as the original does, because the parser
   matches them from the end. *)
(* Whether words `i` and `j` Z-CHARACTER-encode to the identical dictionary
   KEY - V3's 6 significant characters (9 in V4+) can't tell "BOTTLE" from
   "BOTTLED" apart, and the Z-machine's own dictionary lookup only ever
   compares those encoded bytes, never the original spelling. Reuses
   zapf's OWN encoder (ZapfZChar.Encode, the exact routine that turns
   `.ZWORD "text"` into dictionary bytes) rather than reimplementing Z-char
   packing here, so this can never disagree with what actually gets
   assembled. *)
PROCEDURE VocabKeyEqual(i, j, nChars: INTEGER): BOOLEAN;
VAR outBuf1, outBuf2: ARRAY 16 OF INTEGER; outLen1, outLen2, zch1, zch2, k: INTEGER;
    s1, s2: ARRAY 64 OF CHAR;
BEGIN
  Strings.Copy(ZilModel.vocab[i].text, s1); Strings.ToLower(s1);
  Strings.Copy(ZilModel.vocab[j].text, s2); Strings.ToLower(s2);
  ZapfZChar.Encode(s1, ZapfZChar.ModeNoAbbrev, TRUE, nChars, outBuf1, outLen1, zch1);
  ZapfZChar.Encode(s2, ZapfZChar.ModeNoAbbrev, TRUE, nChars, outBuf2, outLen2, zch2);
  IF outLen1 # outLen2 THEN RETURN FALSE END;
  k := 0;
  WHILE (k < outLen1) & (outBuf1[k] = outBuf2[k]) DO INC(k) END;
  RETURN k = outLen1
END VocabKeyEqual;

(* V3's 6-Z-character dictionary entries (9 in V4+) cannot always
   distinguish two different ZIL words - "BOULDER" and "BOULDERS" encode to
   the identical 4 bytes. Left alone, this port emitted BOTH as separate
   dictionary rows: harmless when their part-of-speech data happened to
   match too (a coincidence for a handful of plain object-synonym words),
   but WRONG whenever it didn't - advent's "examine bottled water" needs
   "bottled"'s ADJECTIVE data, and if the dictionary's binary search lands
   on "bottle"'s row instead (same key, different data, ambiguous which one
   a lookup finds), the word silently fails to parse as an adjective at
   all. The original detects this at compile time and MERGES every
   colliding group into its alphabetically-first member (Compilation.
   Compile's PlanVocabMerges/PerformVocabMerges); this does the same,
   using the shared MergeVocabWord this port's SYNONYM support already
   needed. Ordered before ApplyVocabSynonyms because the original runs its
   own equivalent that way too, though in practice it rarely matters (a
   SYNONYM alias is usually too short and too distinct a word to collide
   with anything). *)
PROCEDURE ApplyVocabMerges(): BOOLEAN;
VAR order: ARRAY ZilModel.MaxVocab OF INTEGER;
    i, j, k, nChars, groupStart: INTEGER;
    errBuf: ARRAY 256 OF CHAR;
BEGIN
  IF ZilModel.nVocab = 0 THEN RETURN TRUE END;
  IF ZilModel.zversion < 4 THEN nChars := 6 ELSE nChars := 9 END;
  ZapfZChar.Init;

  (* sort word indices alphabetically by TEXT - matches the original's own
     "orderby pair.Key.Text" before grouping by encoded key, which is what
     decides which member of a colliding group survives (the
     alphabetically first) *)
  FOR i := 0 TO ZilModel.nVocab - 1 DO order[i] := i END;
  FOR i := 1 TO ZilModel.nVocab - 1 DO
    k := order[i]; j := i - 1;
    WHILE (j >= 0) & (ZilModel.vocab[order[j]].text > ZilModel.vocab[k].text) DO
      order[j + 1] := order[j]; DEC(j)
    END;
    order[j + 1] := k
  END;

  (* a run of ADJACENT entries (in this alphabetical order) sharing the
     same encoded key is one collision group; everything after the first
     merges into it *)
  i := 1;
  WHILE i < ZilModel.nVocab DO
    IF VocabKeyEqual(order[i - 1], order[i], nChars) THEN
      groupStart := i - 1;
      WHILE (i < ZilModel.nVocab) & VocabKeyEqual(order[groupStart], order[i], nChars) DO
        ZilModel.MergeVocabWord(order[groupStart], order[i]);
        ZilModel.vocab[order[i]].mergedInto := order[groupStart];
        Strings.Copy("vocab collision: ", errBuf);
        Strings.Append(ZilModel.vocab[order[groupStart]].text, errBuf);
        Strings.Append(" and ", errBuf);
        Strings.Append(ZilModel.vocab[order[i]].text, errBuf);
        Strings.Append(
          " are indistinguishable in the dictionary and will be merged", errBuf);
        Out.ErrString("zilf: warning: "); Out.ErrString(errBuf); Out.ErrLn;
        INC(i)
      END
    ELSE
      INC(i)
    END
  END;
  RETURN TRUE
END ApplyVocabMerges;

(* <SYNONYM ORIGINAL alias...> (and VERB-/DIR-/PREP-/ADJ-SYNONYM, treated
   identically — see MergeVocabWord's own comment on why) were being
   recorded by ZilEval's ApplySubr and then never read anywhere: registering
   one had no effect on the compiled game at all. Applied here, after
   CompileSyntax has assigned every ORIGINAL word's verb/preposition numbers
   and CompileObjects has registered every direction property, so there is
   something for a synonym to copy. Must run before EmitVocab, which reads
   the final vocab table. zillib relies on this for the single-letter
   command abbreviations real players expect - <SYNONYM NORTH N>,
   <VERB-SYNONYM INVENTORY I>, <VERB-SYNONYM EXAMINE X>, and so on - none of
   which worked at all before this pass existed. *)
PROCEDURE ApplyVocabSynonyms(): BOOLEAN;
VAR i, oi, si: INTEGER; origName, synName: ARRAY 64 OF CHAR;
BEGIN
  i := 0;
  WHILE i < ZilModel.nSynonyms DO
    Strings.Copy(ZilModel.synonyms[i].original.atomText, origName);
    Strings.Copy(ZilModel.synonyms[i].synonym.atomText, synName);
    oi := ZilModel.FindVocab(origName);
    (* follow a merged-away original to whichever word actually carries its
       (now combined) data - ApplyVocabMerges runs first, but only touches
       the SURVIVOR's record *)
    WHILE (oi >= 0) & (ZilModel.vocab[oi].mergedInto >= 0) DO
      oi := ZilModel.vocab[oi].mergedInto
    END;
    IF oi >= 0 THEN
      (* AddSynonym (ZilModel.mod) already created this word's own vocab
         entry back when the SYNONYM/VERB-SYNONYM/etc. form was first read,
         specifically so ApplyVocabMerges could see it - so it normally
         exists here already. It can ALSO have been merged away by
         ApplyVocabMerges (advent: LUBRICANT and LUBRICATE, both synonyms of
         OIL, collide with each other in the dictionary too), in which case
         follow the same chain as above rather than re-declaring a dead
         duplicate row. *)
      si := ZilModel.FindVocab(synName);
      WHILE (si >= 0) & (ZilModel.vocab[si].mergedInto >= 0) DO
        si := ZilModel.vocab[si].mergedInto
      END;
      IF si < 0 THEN si := ZilModel.AddVocab(synName, 0) END;
      IF si < 0 THEN
        Err("ApplyVocabSynonyms: too many vocabulary words"); RETURN FALSE
      END;
      ZilModel.MergeVocabWord(si, oi)
    END;
    INC(i)
  END;
  RETURN TRUE
END ApplyVocabSynonyms;

PROCEDURE CompileSyntax(): BOOLEAN;
VAR i, j, k, n, act: INTEGER;
    verbDone: ARRAY ZilModel.MaxSyntaxes OF BOOLEAN;
    num, text: ARRAY 64 OF CHAR;

  (* V-TELL -> V?TELL; anything else gets a V? prefix *)
  PROCEDURE ConstNameOf(routine: ARRAY OF CHAR; VAR out: ARRAY OF CHAR);
  BEGIN
    Strings.Copy(routine, out);
    IF (Strings.Length(out) > 2) & (out[0] = "V") & (out[1] = "-") THEN
      out[1] := "?"
    ELSE
      Strings.Copy("V?", out); Strings.Append(routine, out)
    END
  END ConstNameOf;

  PROCEDURE ActionIdx(cname: ARRAY OF CHAR): INTEGER;
  VAR a: INTEGER;
  BEGIN
    a := 0;
    WHILE a < nActions DO
      IF actionConst[a] = cname THEN RETURN a END;
      INC(a)
    END;
    RETURN -1
  END ActionIdx;

BEGIN
  IF ZilModel.nSyntaxes = 0 THEN RETURN TRUE END;

  (* --- action numbering, in definition order --- *)
  nActions := 0;
  FOR i := 0 TO ZilModel.nSyntaxes - 1 DO
    IF ZilModel.syntaxes[i].action[0] # 0X THEN
      IF ZilModel.syntaxes[i].actionName[0] # 0X THEN
        (* an explicit action name: used as written, with V? prefixed unless
           it is already there *)
        Strings.Copy(ZilModel.syntaxes[i].actionName, text);
        IF ~((text[0] = "V") & (text[1] = "?")) THEN
          Strings.Copy("V?", text);
          Strings.Append(ZilModel.syntaxes[i].actionName, text)
        END
      ELSE
        ConstNameOf(ZilModel.syntaxes[i].action, text)
      END;
      act := ActionIdx(text);
      IF act < 0 THEN
        IF nActions >= MaxActions THEN
          Err("CompileSyntax: too many actions"); RETURN FALSE
        END;
        act := nActions;
        Strings.Copy(ZilModel.syntaxes[i].action, actionRoutine[nActions]);
        Strings.Copy(text, actionConst[nActions]);
        INC(nActions)
      END;
      ZilModel.syntaxes[i].actionIdx := act
    END
  END;

  (* --- V?NAME action constants --- *)
  W("	; actions"); WLn;
  FOR i := 0 TO nActions - 1 DO
    Strings.IntToStr(i, num);
    W("	"); WSym(actionConst[i]); W("="); W(num); WLn
  END;
  WLn;

  (* --- PR?NAME preposition constants --- *)
  W("	; prepositions"); WLn;
  FOR i := 0 TO ZilModel.nVocab - 1 DO
    IF (ZilModel.vocab[i].pos DIV ZilModel.PsPreposition) MOD 2 = 1 THEN
      Strings.IntToStr(ZilModel.vocab[i].prepVal, num);
      W("	PR?"); WSym(ZilModel.vocab[i].text); W("="); W(num); WLn
    END
  END;
  WLn;

  (* --- one syntax table per verb --- *)
  FOR i := 0 TO ZilModel.nSyntaxes - 1 DO verbDone[i] := FALSE END;
  FOR i := 0 TO ZilModel.nSyntaxes - 1 DO
    IF ~verbDone[i] THEN
      (* count this verb's lines *)
      n := 0;
      FOR j := i TO ZilModel.nSyntaxes - 1 DO
        IF ZilModel.syntaxes[j].verb = ZilModel.syntaxes[i].verb THEN
          verbDone[j] := TRUE; INC(n)
        END
      END;

      W("ST?"); WSym(ZilModel.syntaxes[i].verb); W(":: .TABLE"); WLn;
      Strings.IntToStr(n, num);
      W("	.BYTE "); W(num); WLn;

      (* reverse definition order, as the original emits them *)
      FOR j := ZilModel.nSyntaxes - 1 TO i BY -1 DO
        IF ZilModel.syntaxes[j].verb = ZilModel.syntaxes[i].verb THEN
          Strings.IntToStr(ZilModel.syntaxes[j].numObjects, num);
          W("	.BYTE "); W(num); WLn;

          IF ZilModel.syntaxes[j].prep1[0] # 0X THEN
            W("	.BYTE PR?"); W(ZilModel.syntaxes[j].prep1); WLn
          ELSE W("	.BYTE 0"); WLn END;
          IF ZilModel.syntaxes[j].prep2[0] # 0X THEN
            W("	.BYTE PR?"); W(ZilModel.syntaxes[j].prep2); WLn
          ELSE W("	.BYTE 0"); WLn END;

          IF ZilModel.syntaxes[j].find1[0] # 0X THEN
            W("	.BYTE "); W(ZilModel.syntaxes[j].find1); WLn
          ELSE W("	.BYTE 0"); WLn END;
          IF ZilModel.syntaxes[j].find2[0] # 0X THEN
            W("	.BYTE "); W(ZilModel.syntaxes[j].find2); WLn
          ELSE W("	.BYTE 0"); WLn END;

          Strings.IntToStr(ZilModel.syntaxes[j].opts1, num);
          W("	.BYTE "); W(num); WLn;
          Strings.IntToStr(ZilModel.syntaxes[j].opts2, num);
          W("	.BYTE "); W(num); WLn;

          IF ZilModel.syntaxes[j].actionIdx >= 0 THEN
            W("	.BYTE "); WSym(actionConst[ZilModel.syntaxes[j].actionIdx]); WLn
          ELSE W("	.BYTE 0"); WLn END
        END
      END;
      W("	.ENDT"); WLn; WLn
    END
  END;

  (* --- VTBL: one word per possible verb value, indexed 255-verbValue --- *)
  W("VTBL:: .TABLE"); WLn;
  FOR k := 255 TO 1 BY -1 DO
    (* find a verb whose value is k *)
    Strings.Copy("0", text);
    FOR i := 0 TO ZilModel.nSyntaxes - 1 DO
      j := ZilModel.FindVocab(ZilModel.syntaxes[i].verb);
      IF (j >= 0) & (ZilModel.vocab[j].verbVal = k) THEN
        Strings.Copy("ST?", text); Strings.Append(ZilModel.syntaxes[i].verb, text)
      END
    END;
    W("	.WORD "); WSym(text); WLn
  END;
  W("	.ENDT"); WLn; WLn;

  (* --- action and pre-action routine tables --- *)
  W("ATBL:: .TABLE"); WLn;
  FOR i := 0 TO nActions - 1 DO
    IF FindRoutineIdx(actionRoutine[i]) >= 0 THEN
      W("	.WORD "); WSym(actionRoutine[i]); WLn
    ELSE
      W("	.WORD 0"); WLn
    END
  END;
  W("	.ENDT"); WLn; WLn;

  W("PATBL:: .TABLE"); WLn;
  FOR i := 0 TO nActions - 1 DO
    Strings.Copy("0", text);
    FOR j := 0 TO ZilModel.nSyntaxes - 1 DO
      IF (ZilModel.syntaxes[j].actionIdx = i)
         & (ZilModel.syntaxes[j].preAction[0] # 0X)
         & (FindRoutineIdx(ZilModel.syntaxes[j].preAction) >= 0) THEN
        Strings.Copy(ZilModel.syntaxes[j].preAction, text)
      END
    END;
    W("	.WORD "); WSym(text); WLn
  END;
  W("	.ENDT"); WLn; WLn;

  (* --- preposition table: a count, then (word, number) pairs --- *)
  n := 0;
  FOR i := 0 TO ZilModel.nVocab - 1 DO
    IF (ZilModel.vocab[i].pos DIV ZilModel.PsPreposition) MOD 2 = 1 THEN INC(n) END
  END;
  W("PRTBL:: .TABLE"); WLn;
  Strings.IntToStr(n, num);
  W("	.WORD "); W(num); WLn;
  FOR i := 0 TO ZilModel.nVocab - 1 DO
    IF (ZilModel.vocab[i].pos DIV ZilModel.PsPreposition) MOD 2 = 1 THEN
      W("	.WORD W?"); WSym(ZilModel.vocab[i].text); WLn;
      W("	.WORD PR?"); W(ZilModel.vocab[i].text); WLn
    END
  END;
  W("	.ENDT"); WLn; WLn;
  RETURN TRUE
END CompileSyntax;

(* ---------------- discovering vocabulary words used only in code ----------------
   A routine can name a dictionary word that nothing else mentions —
   zillib compares a parsed word against W?COMMA without any object or
   SYNTAX line ever using "comma". The original creates the word on demand
   when the constant is referenced (DefineWord), which works there because
   its dictionary is written at Finish time, after the routines.

   Here the dictionary is emitted BEFORE the routines, because it lives in
   static memory and they live in high memory. So the routines are prepared
   first: each one's argument spec and body are macro-expanded (and stored
   back, so CompileRoutine doesn't repeat the work), then scanned for
   W?/ACT?/PR?/A? references, each of which registers its word. A word
   found only this way gets no part of speech, exactly as DefineWord's
   on-demand creation does. *)

PROCEDURE ScanVocabRefs(z: ZilObj.Zo);
VAR nm: ARRAY 64 OF CHAR; i, k: INTEGER;
BEGIN
  IF z = NIL THEN RETURN END;
  IF z.kind = ZilObj.KAtom THEN
    Strings.Copy(z.atomText, nm);
    k := 0;
    IF (nm[0] = "W") & (nm[1] = "?") THEN k := 2
    ELSIF (nm[0] = "A") & (nm[1] = "?") THEN k := 2
    ELSIF (nm[0] = "P") & (nm[1] = "R") & (nm[2] = "?") THEN k := 3
    ELSIF (nm[0] = "A") & (nm[1] = "C") & (nm[2] = "T") & (nm[3] = "?") THEN k := 4
    END;
    IF k > 0 THEN
      Strings.Delete(nm, 0, k);
      IF nm[0] # 0X THEN i := ZilModel.AddVocab(nm, 0) END
    END;
    RETURN
  END;
  IF (z.kind = ZilObj.KForm) OR (z.kind = ZilObj.KList) OR (z.kind = ZilObj.KSplice) THEN
    WHILE (z # NIL) & (z.first # NIL) DO
      ScanVocabRefs(z.first);
      z := z.rest
    END;
    RETURN
  END;
  IF z.kind = ZilObj.KVector THEN
    FOR i := 0 TO z.vecLen - 1 DO ScanVocabRefs(z.vecItems[i]) END
  END
END ScanVocabRefs;

(* Evaluates every inline table constructor in a routine body and memoizes
   the table on its FORM, so CompileOperand can name it later. Evaluating
   the form is also what registers the table with ZilModel (ZilEval's TABLE
   family calls AddTable), which is why this has to run before any data is
   emitted. The constructor's own arguments are deliberately NOT walked:
   evaluating the form already dealt with them, and a nested table there
   belongs to this table's contents, not to the routine. *)
PROCEDURE ScanInlineTables(z: ZilObj.Zo): BOOLEAN;
VAR i: INTEGER; r: ZilEval.ZResult;
BEGIN
  IF z = NIL THEN RETURN TRUE END;
  IF IsTableForm(z) THEN
    IF ZilObj.GetProp(z, InlineTableMarker()) # NIL THEN RETURN TRUE END;
    ZilEval.ClearErr;
    r := ZilEval.Eval(z);
    IF ZilEval.evalErrFlag THEN Err(ZilEval.evalErrMsg); RETURN FALSE END;
    IF (r.value = NIL) OR (r.value.kind # ZilObj.KTable) THEN
      Err("ScanInlineTables: a table constructor did not produce a table");
      RETURN FALSE
    END;
    IF FindTableIdx(r.value) < 0 THEN
      Err("ScanInlineTables: an inline TEMP-TABLE has no address to take");
      RETURN FALSE
    END;
    ZilObj.PutProp(z, InlineTableMarker(), r.value);
    RETURN TRUE
  END;
  IF (z.kind = ZilObj.KForm) OR (z.kind = ZilObj.KList) OR (z.kind = ZilObj.KSplice) THEN
    WHILE (z # NIL) & (z.first # NIL) DO
      IF ~ScanInlineTables(z.first) THEN RETURN FALSE END;
      z := z.rest
    END;
    RETURN TRUE
  END;
  IF z.kind = ZilObj.KVector THEN
    FOR i := 0 TO z.vecLen - 1 DO
      IF ~ScanInlineTables(z.vecItems[i]) THEN RETURN FALSE END
    END
  END;
  RETURN TRUE
END ScanInlineTables;

(* A property NAME can carry a PROPSPEC: a function that rewrites the whole
   property list before anything is compiled. zillib uses it for THINGS
   (pseudo-objects, in advent's scenery) and for PRONOUN. The function is
   called with the property list and returns a LIST whose REST replaces the
   property's body - the returned list's own first element is a placeholder
   standing in for the property name.

   It has to run before everything else, because a PROPSPEC may DEFINE new
   routines and build new tables as it goes (THINGS-PROPSPEC does both), and
   those have to be expanded, scanned and emitted with all the others. The
   original applies it in PreBuildObject for the same reason.

   The property list is passed QUOTEd. Handing it over bare would evaluate
   its elements, and a property list is data: (THINGS <> (HILL BUMP INCLINE)
   "...") names words, not values. *)
(* Splices any top-level SPLICE-typed member of a property's value list into
   that list, one level deep. `#SPLICE (...)` only ever reaches a property
   list this way: as the substituted result of a `%<VERSION? ...>` read-time
   clause, e.g. advent's
     (SYNONYM MAGAZINES ZINES ISSUES TODAY
         %<VERSION? (ZIP #SPLICE ()) (ELSE #SPLICE (MAGAZINE ZINE ...))>)
   `%<...>` substitutes its evaluated result in place of ONE list element at
   READ time (see ZilRead's own comment on why the READER must not do this
   flattening itself), so by the time a property list reaches here it may
   contain a raw SPLICE value sitting where several words, or none, belong.
   This is the one place that value gets consumed as real data, so this is
   where it gets flattened - mirroring ExpandTree's identical one-level
   splice-flatten for routine bodies. *)
PROCEDURE FlattenSpliceMembers(list: ZilObj.Zo): ZilObj.Zo;
VAR head, tail, cell, p, sp: ZilObj.Zo;
BEGIN
  head := NIL; tail := NIL;
  p := list;
  WHILE (p # NIL) & (p.first # NIL) DO
    IF p.first.kind = ZilObj.KSplice THEN
      sp := p.first;
      WHILE (sp # NIL) & (sp.first # NIL) DO
        cell := ZilObj.Cons(ZilObj.KList, sp.first, NIL);
        IF head = NIL THEN head := cell ELSE tail.rest := cell END;
        tail := cell;
        sp := sp.rest
      END
    ELSE
      cell := ZilObj.Cons(ZilObj.KList, p.first, NIL);
      IF head = NIL THEN head := cell ELSE tail.rest := cell END;
      tail := cell
    END;
    p := p.rest
  END;
  IF head = NIL THEN RETURN ZilObj.NewEmpty(ZilObj.KList) END;
  RETURN head
END FlattenSpliceMembers;

PROCEDURE ApplyPropSpecs(): BOOLEAN;
VAR i: INTEGER; p, spec, call, r: ZilObj.Zo; nm: ARRAY 64 OF CHAR;
    errBuf: ARRAY 512 OF CHAR; res: ZilEval.ZResult;
BEGIN
  i := 0;
  WHILE i < ZilModel.nObjects DO
    p := ZilModel.objects[i].props;
    WHILE (p # NIL) & (p.first # NIL) DO
      IF (p.first.kind = ZilObj.KList) & (p.first.first # NIL)
         & (p.first.first.kind = ZilObj.KAtom) THEN
        p.first.rest := FlattenSpliceMembers(p.first.rest);
        Strings.Copy(p.first.first.atomText, nm);
        spec := ZilObj.GetProp(p.first.first, ZilObj.Intern("PROPSPEC"));
        (* <PUTPROP THINGS PROPSPEC THINGS-PROPSPEC> stores the NAME here,
           because a bare atom self-evaluates in this port (see ZilEval's
           header note) where MDL would have yielded its GVAL. Follow it. *)
        IF (spec # NIL) & (spec.kind = ZilObj.KAtom) THEN
          spec := spec.globalVal
        END;
        IF (spec # NIL)
           & ((spec.kind = ZilObj.KFunction) OR (spec.kind = ZilObj.KMacro)
              OR (spec.kind = ZilObj.KSubr) OR (spec.kind = ZilObj.KFSubr)) THEN
          call := ZilObj.Cons(ZilObj.KForm, p.first, NIL);
          call := ZilObj.Cons(ZilObj.KForm, ZilObj.Intern("QUOTE"), call);
          call := ZilObj.Cons(ZilObj.KForm, call, NIL);
          call := ZilObj.Cons(ZilObj.KForm, spec, call);
          ZilEval.ClearErr;
          Strings.Copy(ZilModel.objects[i].name.atomText, curRoutine);
          res := ZilEval.Eval(call);
          curRoutine[0] := 0X;
          IF ZilEval.evalErrFlag THEN Err(ZilEval.evalErrMsg); RETURN FALSE END;
          r := res.value;
          IF (r = NIL) OR (r.kind # ZilObj.KList) OR (r.rest = NIL)
             OR (r.rest.first = NIL) THEN
            Strings.Copy("ApplyPropSpecs: the PROPSPEC for ", errBuf);
            Strings.Append(nm, errBuf);
            Strings.Append(" of object ", errBuf);
            Strings.Append(ZilModel.objects[i].name.atomText, errBuf);
            Strings.Append(" returned a bad value: ", errBuf);
            ZilObj.PrintTo(r, nm); Strings.Append(nm, errBuf);
            Err(errBuf); RETURN FALSE
          END;
          (* the rest of the returned list becomes the property's new body *)
          p.first.rest := r.rest
        END
      END;
      p := p.rest
    END;
    INC(i)
  END;
  RETURN TRUE
END ApplyPropSpecs;

PROCEDURE PrepareRoutines(): BOOLEAN;
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE i < ZilModel.nRoutines DO
    ZilEval.ClearErr;
    ZilModel.routines[i].argSpec := ZilEval.ExpandTree(ZilModel.routines[i].argSpec);
    IF ZilEval.evalErrFlag THEN
      Strings.Copy(ZilModel.routines[i].name.atomText, curRoutine);
      Err(ZilEval.evalErrMsg); RETURN FALSE
    END;
    ZilModel.routines[i].body := ZilEval.ExpandTree(ZilModel.routines[i].body);
    IF ZilEval.evalErrFlag THEN
      Strings.Copy(ZilModel.routines[i].name.atomText, curRoutine);
      Err(ZilEval.evalErrMsg); RETURN FALSE
    END;
    ScanVocabRefs(ZilModel.routines[i].argSpec);
    ScanVocabRefs(ZilModel.routines[i].body);
    Strings.Copy(ZilModel.routines[i].name.atomText, curRoutine);
    IF ~ScanInlineTables(ZilModel.routines[i].body) THEN RETURN FALSE END;
    curRoutine[0] := 0X;
    INC(i)
  END;
  curRoutine[0] := 0X;
  RETURN TRUE
END PrepareRoutines;

(* Emits the dictionary. Ported from GameBuilder.FinishSyntax plus
   OldParserWord.WriteToBuilder, which together define the V1-3 layout:

     VOCAB:: .TABLE
         .BYTE <count of self-inserting break characters>
         .BYTE <each break character>
         .BYTE <entry length>        ; z-word bytes + data bytes
         .WORD <word count>
         .VOCBEG <entry length>,<z-word bytes>
         W?FOO:: .ZWORD "foo"
         .BYTE <part-of-speech flags>,<value 1>,<value 2>
         ...
         .VOCEND
         .ENDT

   The Z-character encoding — by far the hardest part of a dictionary — is
   not done here at all: `zapf` already implements it and exposes it as the
   .ZWORD directive, so this only has to emit the structure around it.

   Two things that are not free choices. **Words must be sorted**, because
   dictionary lookup at run time is a binary search (the original sorts by
   ordinal string comparison, same here). And **each word carries two value
   bytes** chosen from its parts of speech in a fixed priority order, with
   the "First" flags able to promote one of them — that order is
   WriteToBuilder's, copied rather than reinvented. *)
PROCEDURE EmitVocabTable;
VAR i, j, k, entryLen, zwordBytes, pos, v1, v2, nParts, nEmit: INTEGER;
    order: ARRAY ZilModel.MaxVocab OF INTEGER;
    parts: ARRAY 4 OF INTEGER;
    text: ARRAY 64 OF CHAR; num: ARRAY 16 OF CHAR;
    strLit: ARRAY 160 OF CHAR;

  (* the value byte a given part of speech contributes *)
  PROCEDURE PartValue(w, part: INTEGER): INTEGER;
  VAR propNm: ARRAY 64 OF CHAR;
  BEGIN
    (* OBJECT has no per-word number of its own (a SYNONYM word's meaning
       comes from which OBJECTs list it, found by scanning, never by a
       value read out of the dictionary) - but the value slot still has to
       hold something other than 0, because a caller that treats a value
       lookup's result as a boolean (zork1's own gparser.zil: WT? returns
       exactly this byte, and <COND (<WT? .WRD ,PS?OBJECT ,P1?OBJECT> ...)>
       reads it as true/false) would silently treat every noun-only word as
       FALSE. Matches the real compiler's own OldParserWord.SetObject:
       `speechValues[PartOfSpeech.Object] = 1`, a fixed sentinel, never 0. *)
    IF part = ZilModel.PsObject THEN RETURN 1 END;
    IF part = ZilModel.PsVerb THEN RETURN ZilModel.vocab[w].verbVal END;
    IF part = ZilModel.PsPreposition THEN RETURN ZilModel.vocab[w].prepVal END;
    IF part = ZilModel.PsAdjective THEN RETURN ZilModel.vocab[w].adjVal END;
    IF part = ZilModel.PsBuzzword THEN RETURN ZilModel.vocab[w].buzzVal END;
    IF part = ZilModel.PsDirection THEN
      (* the parser reads a direction word's value as the PROPERTY number
         holding that exit, which is what dirIndexToPropertyOperand supplies
         in the original. A direction SYNONYM (dirAlias set by
         MergeVocabWord) looks the property up under the ORIGINAL word's
         text - "N"'s exit data is the NORTH property, not an "N" property,
         which was never registered. *)
      IF ZilModel.vocab[w].dirAlias[0] # 0X THEN
        Strings.Copy(ZilModel.vocab[w].dirAlias, propNm)
      ELSE
        Strings.Copy(ZilModel.vocab[w].text, propNm)
      END;
      IF FindPropIdx(propNm) >= 0 THEN
        RETURN MaxProps() - FindPropIdx(propNm)
      END;
      RETURN 0
    END;
    RETURN 0
  END PartValue;

  PROCEDURE Has(w, bit: INTEGER): BOOLEAN;
  BEGIN RETURN (ZilModel.vocab[w].pos DIV bit) MOD 2 = 1 END Has;

BEGIN
  IF ZilModel.zversion < 4 THEN zwordBytes := 4 ELSE zwordBytes := 6 END;
  entryLen := zwordBytes + 3;

  (* sort the word indices by text: run-time lookup is a binary search *)
  FOR i := 0 TO ZilModel.nVocab - 1 DO order[i] := i END;
  FOR i := 1 TO ZilModel.nVocab - 1 DO
    k := order[i]; j := i - 1;
    WHILE (j >= 0) & (ZilModel.vocab[order[j]].text > ZilModel.vocab[k].text) DO
      order[j + 1] := order[j]; DEC(j)
    END;
    order[j + 1] := k
  END;

  (* ACT?WORD is a verb word's own number — distinct from V?ACTION, which
     is an action index. zillib compares ,P-V against ACT?WALK. (The
     original yields all of A?/ACT?/PR? from GetVocabConstants.) *)
  W("	; verb word numbers"); WLn;
  FOR i := 0 TO ZilModel.nVocab - 1 DO
    IF (ZilModel.vocab[i].pos DIV ZilModel.PsVerb) MOD 2 = 1 THEN
      Strings.IntToStr(ZilModel.vocab[i].verbVal, num);
      W("	ACT?"); WSym(ZilModel.vocab[i].text); W("="); W(num); WLn
    END
  END;
  WLn;

  (* V1-3 refers to an adjective by NUMBER rather than by word address, via
     an A?NAME constant — see the ADJECTIVE property in CompileObjects *)
  IF ZilModel.zversion < 4 THEN
    FOR i := 0 TO ZilModel.nVocab - 1 DO
      IF (ZilModel.vocab[i].pos DIV ZilModel.PsAdjective) MOD 2 = 1 THEN
        Strings.IntToStr(ZilModel.vocab[i].adjVal, num);
        W("	A?"); WSym(ZilModel.vocab[i].text); W("="); W(num); WLn
      END
    END;
    WLn
  END;

  (* a word ApplyVocabMerges folded into another gets no row of its own -
     only the SURVIVORS are counted and emitted *)
  nEmit := 0;
  FOR i := 0 TO ZilModel.nVocab - 1 DO
    IF ZilModel.vocab[i].mergedInto < 0 THEN INC(nEmit) END
  END;

  W("VOCAB:: .TABLE"); WLn;
  W("	.BYTE 3"); WLn;        (* the SIBREAKS this port declares: , . " *)
  W("	.BYTE 44"); WLn;
  W("	.BYTE 46"); WLn;
  W("	.BYTE 34"); WLn;
  Strings.IntToStr(entryLen, num);
  W("	.BYTE "); W(num); WLn;
  Strings.IntToStr(nEmit, num);
  W("	.WORD "); W(num); WLn;

  IF nEmit > 0 THEN
    Strings.IntToStr(entryLen, num);
    W("	.VOCBEG "); W(num); W(",");
    Strings.IntToStr(zwordBytes, num); W(num); WLn;

    FOR i := 0 TO ZilModel.nVocab - 1 DO
      k := order[i];
      IF ZilModel.vocab[k].mergedInto < 0 THEN
      Strings.Copy(ZilModel.vocab[k].text, text);
      W("W?"); WSym(text); W(":: .ZWORD ");
      Strings.ToLower(text);
      (* the `"` word is itself a dictionary word, so the quote has to be
         doubled the way any other ZAP string literal's would be *)
      CompileZapString(text, strLit);
      W(strLit); WLn;

      (* the parts of speech that contribute a value byte, in the
         original's priority order, with the First flags promoting one *)
      pos := ZilModel.vocab[k].pos;
      nParts := 0;
      IF Has(k, ZilModel.PsAdjective) & (ZilModel.zversion < 4) THEN
        IF pos MOD 4 = ZilModel.PsAdjFirst THEN
          FOR j := nParts TO 1 BY -1 DO parts[j] := parts[j - 1] END;
          parts[0] := ZilModel.PsAdjective
        ELSE parts[nParts] := ZilModel.PsAdjective END;
        INC(nParts)
      END;
      IF Has(k, ZilModel.PsDirection) THEN
        IF pos MOD 4 = ZilModel.PsDirFirst THEN
          FOR j := nParts TO 1 BY -1 DO parts[j] := parts[j - 1] END;
          parts[0] := ZilModel.PsDirection
        ELSE parts[nParts] := ZilModel.PsDirection END;
        INC(nParts)
      END;
      IF Has(k, ZilModel.PsVerb) THEN
        IF pos MOD 4 = ZilModel.PsVerbFirst THEN
          FOR j := nParts TO 1 BY -1 DO parts[j] := parts[j - 1] END;
          parts[0] := ZilModel.PsVerb
        ELSE parts[nParts] := ZilModel.PsVerb END;
        INC(nParts)
      END;
      IF Has(k, ZilModel.PsObject) THEN
        (* there is no ObjectFirst, so it stays first only when no other
           First flag is set *)
        IF pos MOD 4 = 0 THEN
          FOR j := nParts TO 1 BY -1 DO parts[j] := parts[j - 1] END;
          parts[0] := ZilModel.PsObject
        ELSE parts[nParts] := ZilModel.PsObject END;
        INC(nParts)
      END;
      IF Has(k, ZilModel.PsBuzzword) THEN
        FOR j := nParts TO 1 BY -1 DO parts[j] := parts[j - 1] END;
        parts[0] := ZilModel.PsBuzzword; INC(nParts)
      END;
      IF Has(k, ZilModel.PsPreposition) THEN
        FOR j := nParts TO 1 BY -1 DO parts[j] := parts[j - 1] END;
        parts[0] := ZilModel.PsPreposition; INC(nParts)
      END;

      v1 := 0; v2 := 0;
      IF nParts > 0 THEN v1 := PartValue(k, parts[0]) END;
      IF nParts > 1 THEN v2 := PartValue(k, parts[1]) END;

      Strings.IntToStr(pos, num);       W("	.BYTE "); W(num);
      Strings.IntToStr(v1, num);        W(","); W(num);
      Strings.IntToStr(v2, num);        W(","); W(num); WLn
      END
    END;
    W("	.VOCEND"); WLn
  END;
  W("	.ENDT"); WLn; WLn;

  (* every merged-away word's W? symbol aliases the survivor's - a bare
     constant, so it goes OUTSIDE the .VOCBEG/.VOCEND table, matching where
     the ACT?/A? constants above are written rather than inside the fixed-
     record vocab section itself. Matches the original's own
     PerformVocabMerges, which copies the W?/A?/ACT?/PR? constants across
     rather than leaving the merged word's own symbols dangling. *)
  FOR i := 0 TO ZilModel.nVocab - 1 DO
    IF ZilModel.vocab[i].mergedInto >= 0 THEN
      W("	W?"); WSym(ZilModel.vocab[i].text); W("=W?");
      WSym(ZilModel.vocab[ZilModel.vocab[i].mergedInto].text); WLn
    END
  END
END EmitVocabTable;

PROCEDURE EmitVocab;
VAR entryLen: INTEGER; n: ARRAY 16 OF CHAR;
BEGIN
  (* dictionary entry: 4 z-word bytes in V1-3, 6 in V4+, plus 3 data bytes
     either way — the same numbers the original computes in FinishSyntax as
     `zversion < 4 ? 4 : 6` plus the entry data size. The dictionary itself
     is still empty: vocabulary and syntax emission is its own later slice,
     and this keeps the header's VOCAB pointer valid meanwhile. *)
  IF ZilModel.zversion < 4 THEN entryLen := 7 ELSE entryLen := 9 END;

  W("IMPURE::"); WLn; WLn;

  EmitVocabTable;

  W("WORDS::"); WLn; WLn;
  W("ENDLOD::"); WLn; WLn
END EmitVocab;

(* Emits a complete, assemblable .zap file for everything ZilModel has
   accumulated: the whole-program entry point this module previously
   lacked (CompileRoutine alone left the caller to hand-write a header and
   a GO routine around it). `entryName` names the routine the header's
   START:: label goes on — pass "GO" for the ZIL default. *)
PROCEDURE CompileProgram*(entryName: ARRAY OF CHAR): BOOLEAN;
VAR i, entryIdx: INTEGER; ok: BOOLEAN; verText: ARRAY 16 OF CHAR;
    strBuf: ARRAY 4096 OF CHAR;
BEGIN
  ClearErr;
  labelCounter := 0;
  nStrings := 0; nActions := 0;

  entryIdx := FindRoutineIdx(entryName);
  IF entryIdx < 0 THEN
    Err("CompileProgram: entry routine not defined"); RETURN FALSE
  END;

  (* zapf's own WriteHeader auto-generates the fixed 64-byte header
     (version/flags/release/ENDLOD/START/VOCAB/OBJECT/GLOBAL/IMPURE/
     FLAGS2/serial/WORDS/length/checksum, zero-padded to 64 bytes) the
     same way for every version - confirmed against a real compile of
     cloak_plus.zil (V5): the real compiler's own hand-written V5 header
     ALSO leaves every field past WORDS (the V5+-only terminating-
     characters/alphabet/header-extension-table pointers) as a
     zero-resolving symbol nothing in the game ever defines a table
     under, so the two headers come out byte-identical regardless of
     which one writes the zeros explicitly and which one just pads them.
     V5's other structural differences from V3 (63 properties/48
     attributes, the ×4 packed-address multiplier, 14-byte object rows,
     6-byte/9-Z-character dictionary keys, SAVE/RESTORE as a 0OP STORE
     instead of a 0OP branch) are already shared with V4, which already
     works, so V5 needed no separate codegen path at all - just this
     version-range check widened to admit it. *)
  IF (ZilModel.zversion < 3) OR (ZilModel.zversion > 5) THEN
    Err("CompileProgram: only Z-machine versions 3-5 are emitted yet");
    RETURN FALSE
  END;

  (* The parser reaches its tables through four globals that the COMPILER
     defines rather than the source (the original creates them on demand
     with GetGlobal). Registering them in ZilModel, rather than emitting
     four extra .GVAR lines directly, is what makes ,VERBS resolve in a
     routine body like any other global. *)
  IF ZilModel.nSyntaxes > 0 THEN
    IF FindGlobalIdx("VERBS") < 0 THEN
      ZilModel.AddGlobal(ZilObj.Intern("VERBS"), NIL);
      ZilModel.AddGlobal(ZilObj.Intern("ACTIONS"), NIL);
      ZilModel.AddGlobal(ZilObj.Intern("PREACTIONS"), NIL);
      ZilModel.AddGlobal(ZilObj.Intern("PREPOSITIONS"), NIL)
    END
  END;

  (* PROPSPECs first: they rewrite object properties and may define routines
     and tables that everything below has to see *)
  ok := ApplyPropSpecs();
  IF ~ok THEN RETURN FALSE END;

  (* expand and scan every routine before any data is emitted — see
     PrepareRoutines for why the order matters *)
  ok := PrepareRoutines();
  IF ~ok THEN RETURN FALSE END;

  W("	; compiled by ZilCompile (Oberon port of zilf)"); WLn;
  Strings.IntToStr(ZilModel.zversion, verText);
  W("	.NEW "); W(verText); WLn; WLn;

  CompileConstants;
  ok := CompileGlobals();
  IF ~ok THEN RETURN FALSE END;
  ok := CompileTables();
  IF ~ok THEN RETURN FALSE END;
  ok := CompileObjects();
  IF ~ok THEN RETURN FALSE END;
  ok := CompileSyntax();
  IF ~ok THEN RETURN FALSE END;
  ok := ApplyVocabMerges();
  IF ~ok THEN RETURN FALSE END;
  ok := ApplyVocabSynonyms();
  IF ~ok THEN RETURN FALSE END;
  EmitVocab;

  (* the entry routine first, so START:: is the lowest code address *)
  ok := CompileRoutine(entryIdx, TRUE);
  IF ~ok THEN RETURN FALSE END;

  i := 0;
  WHILE i < ZilModel.nRoutines DO
    IF i # entryIdx THEN
      ok := CompileRoutine(i, FALSE);
      IF ~ok THEN RETURN FALSE END
    END;
    INC(i)
  END;

  (* the packed strings, in high memory alongside the routines *)
  IF nStrings > 0 THEN
    WLn;
    W("	; packed strings"); WLn;
    i := 0;
    WHILE i < nStrings DO
      Strings.IntToStr(i, verText);
      W("	.GSTR STR?"); W(verText); W(",");
      CompileZapString(strPool[i]^, strBuf);
      W(strBuf); WLn;
      INC(i)
    END;
    WLn
  END;

  W("	.END"); WLn;
  RETURN TRUE
END CompileProgram;

BEGIN
  outIsFile := FALSE; buffering := FALSE; nBufLines := 0; nBlocks := 0;
  lineBuf[0] := 0X
END ZilCompile.
