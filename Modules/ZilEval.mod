MODULE ZilEval;
(*
  ZilEval — ZIL evaluator, phase 2 of the zilf port (see
  Notes/zilf_port_plan.md). Ported from Zilf.Interpreter.Context /
  ZilResult / the ZilObject.EvalImpl overrides (already read in phase 1)
  and a starter subset of Zilf.Interpreter.Subrs.*.cs.

  Key semantic point (easy to get wrong, verified against the original
  Subrs.Atoms.cs before writing this): a bare ATOM is SELF-EVALUATING in
  ZIL, not a variable reference — <SET X 5> works because X, evaluated,//
  just yields the atom X itself (which SET's native implementation then
  uses as the binding name), and ZilForm.EvalImpl only performs an actual
  variable-style lookup for the FORM's *head* position (deciding what
  function/macro to call). Real variable dereference is always explicit:
  .X / <LVAL X> for locals, ,X / <GVAL X> for globals. Get this backwards
  and nothing works right.

  Scope for this session (see plan doc for the "why" of each trim):
  - No PROG/ROUTINE application yet, so no environment push/pop is needed:
    SET/SETG just mutate the atom's current localVal/globalVal field
    directly (this is correct as far as it goes — it's exactly what SET
    does when there's no enclosing PROG/routine scope to shadow within;
    the push/pop "shallow binding" machinery is only needed once PROG or
    routine calls exist, and is deferred to that point).
  - No macro expansion (DEFMAC) — Expand is not implemented.
  - LIST evaluation does not yet splice SEGMENT values or MAPRET-family
    control values into the result; encountering a SEGMENT inside a LIST
    is an error for now (matches the "not needed for the starter slice"
    principle, not the original's actual splicing behavior).
  - RETURN/AGAIN (ZilResult.Outcome.Return/Again) are modeled (see OValue/
    OReturn/OAgain) but nothing in this session's SUBR set produces them
    yet, since that needs PROG/routine activations to target.
  - DECL checking (MaybeCheckDecl in the original) is skipped everywhere.
*)

IMPORT ZilObj, ZilRead, ZilModel, Strings, Out;

CONST
  MaxIncludePaths = 16;
  MaxPackages = 128;
  MaxFlags = 256;
  MaxOblists = 256;
  MaxStructs = 64;
  MaxStructFields = 32;
  OValue* = 0;
  OReturn* = 1;
  OAgain*  = 2;
  (* MAPF's own control flow. Each propagates out of the loop function the
     same way RETURN does — ShouldPass sends it up through any nesting until
     the MAPF that started the iteration catches it. `value` NIL means the
     form supplied no value at all (<MAPRET> with no arguments, which skips
     the element entirely). *)
  OMapRet*   = 3;
  OMapStop*  = 4;
  OMapLeave* = 5;

  MaxArgs = 64;
  MaxBindings = 32;
  MaxTableElems = 8192;

  APReq = 0; APOpt = 1; APAux = 2;

TYPE
  ZResult* = RECORD
    outcome*: INTEGER;
    value*: ZilObj.Zo;
    activation*: ZilObj.Zo
  END;

VAR
  evalErrFlag*: BOOLEAN;
  evalErrMsg*: ARRAY 512 OF CHAR;

  (* An internal, non-user-visible atom whose localVal is rebound (via the
     same save/restore-on-atom's-own-slot mechanism as every other PROG
     binding) to the innermost enclosing PROG/REPEAT's activation — matches
     the original's Context.EnclosingProgActivationAtom exactly, including
     the trailing-space name trick (a real ZIL atom can't easily be spelled
     with an embedded space, so this can't collide with user code). BIND
     does NOT rebind this (see PerformProg's `catchy` flag in the original),
     so RETURN/AGAIN with no explicit activation skip over an enclosing BIND
     and find the next real PROG/REPEAT outward, exactly as in the original. *)
  enclosingProgAtom: ZilObj.Zo;

  (* The directory INSERT-FILE resolves a relative filename against —
     matches the original's Context.CurrentFile / FindIncludeFile in
     spirit, but much simplified: just "the currently-including file's own
     directory", no configurable IncludePaths list (this port has no CLI
     yet to configure one from; add it if/when something needs it). The
     top-level driver (a test harness, or eventually a real CLI) should
     call SetCurrentDir once with the initial file's own directory before
     starting its read-eval loop; INSERT-FILE itself save/restores this
     around each nested file, so nested INSERT-FILEs resolve relative to
     whichever file is currently being read, not always the original. *)
  currentDir: ARRAY 512 OF CHAR;

  (* library search path — see AddIncludePath *)
  includePaths: ARRAY MaxIncludePaths OF ARRAY 512 OF CHAR;
  nIncludePaths: INTEGER;

  (* Names of packages that have been defined (by a <PACKAGE "NAME"> form)
     or are provided natively — see the PACKAGE/USE comments below for the
     whole story on how much of the original's OBLIST machinery this port
     does and doesn't need. *)
  packages: ARRAY MaxPackages OF ARRAY 64 OF CHAR;
  nPackages: INTEGER;

  (* Compilation flags (COMPILATION-FLAG and friends). The original keeps
     these on their own OBLIST so a flag named FOO can't collide with a
     global named FOO; with this port's flat atom table that isolation is
     the one thing a separate map still has to provide, so they live in
     their own little name-to-value table rather than as atom globals. *)
  (* Set by ExpandOnce immediately before a single EvalImpl call, and
     consumed by that call's own entry — see ExpandTree for what this is
     for. It deliberately does NOT propagate into nested EvalImpl calls: a
     macro's own body must evaluate completely normally, and only the
     macro's RESULT is what's being asked for unevaluated. *)
  expandOnlyPending: BOOLEAN;

  (* extra values from a <MAPRET a b c>, drained by the enclosing MAPF *)
  mapRetList: ZilObj.Zo;

  oblists: ARRAY MaxOblists OF ZilObj.Zo;
  nOblists: INTEGER;

  flagNames: ARRAY MaxFlags OF ARRAY 64 OF CHAR;
  flagValues: ARRAY MaxFlags OF ZilObj.Zo;
  nFlags: INTEGER;

PROCEDURE MkVal*(z: ZilObj.Zo): ZResult;
VAR r: ZResult;
BEGIN r.outcome := OValue; r.value := z; r.activation := NIL; RETURN r END MkVal;

PROCEDURE ShouldPass*(r: ZResult): BOOLEAN;
BEGIN RETURN r.outcome # OValue END ShouldPass;

PROCEDURE Err(msg: ARRAY OF CHAR): ZResult;
BEGIN
  (* The FIRST error wins. An error's result value is an ordinary OValue
     (the atom FALSE), not a distinct outcome, so a failure does not stop
     the surrounding evaluation by itself — callers keep going and often
     fail again on the bad value, overwriting the message that actually
     explained what went wrong. Keeping the first message is what turns
     "expected a structured value to splice, got FALSE" back into the real
     cause. *)
  IF ~evalErrFlag THEN
    evalErrFlag := TRUE;
    Strings.Copy(msg, evalErrMsg)
  END;
  RETURN MkVal(ZilObj.Intern("FALSE"))
END Err;

PROCEDURE ErrAtom(msg: ARRAY OF CHAR; atom: ZilObj.Zo): ZResult;
VAR full: ARRAY 512 OF CHAR; s: ARRAY 256 OF CHAR;
BEGIN
  Strings.Copy(msg, full);
  ZilObj.PrintTo(atom, s);
  Strings.Append(" ", full); Strings.Append(s, full);
  RETURN Err(full)
END ErrAtom;

PROCEDURE ClearErr*;
BEGIN evalErrFlag := FALSE; evalErrMsg[0] := 0X END ClearErr;

(* See currentDir's own comment above. Call once, before the first
   top-level ReadOne/Eval, with the directory of the file being read (or
   "" for the current working directory). *)
PROCEDURE SetCurrentDir*(dir: ARRAY OF CHAR);
BEGIN Strings.Copy(dir, currentDir) END SetCurrentDir;

(* Adds a directory to the library search path INSERT-FILE falls back on
   when a file isn't beside the file including it — the original's
   configurable include-path list (FindIncludeFile in Subrs.Meta.cs). Real
   games live in their own directory and `<INSERT-FILE "parser">` the
   shared library out of zillib/, so without this no real game's source can
   be read at all. A trailing "/" is added if the caller left it off, so
   the directory can be concatenated with a filename directly. *)
PROCEDURE AddIncludePath*(dir: ARRAY OF CHAR);
VAR k: INTEGER;
BEGIN
  IF (dir[0] = 0X) OR (nIncludePaths >= MaxIncludePaths) THEN RETURN END;
  Strings.Copy(dir, includePaths[nIncludePaths]);
  k := Strings.Length(includePaths[nIncludePaths]);
  IF includePaths[nIncludePaths][k - 1] # "/" THEN
    Strings.Append("/", includePaths[nIncludePaths])
  END;
  INC(nIncludePaths)
END AddIncludePath;

PROCEDURE ClearIncludePaths*;
BEGIN nIncludePaths := 0 END ClearIncludePaths;

PROCEDURE PackageDefined(pname: ARRAY OF CHAR): BOOLEAN;
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE i < nPackages DO
    IF packages[i] = pname THEN RETURN TRUE END;
    INC(i)
  END;
  RETURN FALSE
END PackageDefined;

PROCEDURE DefinePackage(pname: ARRAY OF CHAR);
BEGIN
  IF ~PackageDefined(pname) & (nPackages < MaxPackages) THEN
    Strings.Copy(pname, packages[nPackages]); INC(nPackages)
  END
END DefinePackage;

(* Packages this port provides natively, so <USE "..."> on one must NOT try
   to load a file. In the original these are either empty placeholder
   packages created by Context.InitPackages (NEWSTRUC, ZILCH, ZIL,
   READER-MACROS) or a real MDL implementation of something this port has
   built in: zillib/qq.mud implements QUASIQUOTE in MDL, using NEWTYPE/
   MAPF/CHTYPE/APPLY/MAKE-PREFIX-MACRO — none of which this port has —
   while phase 2d ported quasiquote directly into the evaluator instead. So
   <USE "QQ"> is satisfied, not skipped: the functionality really is
   present, just not via that file. *)
PROCEDURE BuiltinPackage(pname: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN (pname = "QQ") OR (pname = "READER-MACROS") OR (pname = "NEWSTRUC")
         OR (pname = "ZILCH") OR (pname = "ZIL")
END BuiltinPackage;

PROCEDURE FlagIdx(name: ARRAY OF CHAR): INTEGER;
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE i < nFlags DO
    IF flagNames[i] = name THEN RETURN i END;
    INC(i)
  END;
  RETURN -1
END FlagIdx;

(* The original's DefineCompilationFlag: defines the flag if it isn't
   already defined, or overwrites it when `redefine` is set (COMPILATION-FLAG
   redefines, COMPILATION-FLAG-DEFAULT doesn't). Defining a flag also makes
   the IF-<NAME>/IFN-<NAME> conditional forms usable — the original builds
   them as a pair of DEFMACs named IF-<NAME>!-/IFN-<NAME>!- on the root
   oblist; see EvalImpl's own handling for why this port recognizes the
   names directly instead of synthesizing macro bodies. *)
PROCEDURE DefineFlag(name: ARRAY OF CHAR; value: ZilObj.Zo; redefine: BOOLEAN);
VAR k: INTEGER;
BEGIN
  k := FlagIdx(name);
  IF k >= 0 THEN
    IF redefine THEN flagValues[k] := value END
  ELSIF nFlags < MaxFlags THEN
    Strings.Copy(name, flagNames[nFlags]);
    flagValues[nFlags] := value;
    INC(nFlags)
  END
END DefineFlag;

(* The flag's value, or NIL if it isn't defined at all — the original
   distinguishes "undefined" from "defined as false", and IFFLAG needs the
   difference (an undefined name in a clause condition is not a flag test). *)
PROCEDURE FlagValue(name: ARRAY OF CHAR): ZilObj.Zo;
VAR k: INTEGER;
BEGIN
  k := FlagIdx(name);
  IF k < 0 THEN RETURN NIL END;
  RETURN flagValues[k]
END FlagValue;

(* Extracts the directory portion of `path` (up to and including the last
   "/"), or "" if there is none. Doesn't call Eval, so — unlike the actual
   INSERT-FILE handling — this can be its own procedure. *)
PROCEDURE DirOf(path: ARRAY OF CHAR; VAR dir: ARRAY OF CHAR);
VAR i, lastSlash: INTEGER;
BEGIN
  lastSlash := -1; i := 0;
  WHILE path[i] # 0X DO
    IF path[i] = "/" THEN lastSlash := i END;
    INC(i)
  END;
  IF lastSlash >= 0 THEN
    FOR i := 0 TO lastSlash DO dir[i] := path[i] END;
    dir[lastSlash + 1] := 0X
  ELSE
    dir[0] := 0X
  END
END DirOf;

(* ------------------------------------------------------------------ *)
(* helpers                                                              *)
(* ------------------------------------------------------------------ *)

(* Marks an atom as having been given a Z-code meaning — a routine, object,
   global or constant. The original stores the ZRoutine/ZilModelObject/
   ZilGlobal/ZilConstant it built under the atom's ZVAL property and the
   library tests for it: zillib refuses to build its achievements table
   unless MAX-SCORE has a ZVAL, and its status line checks whether the game
   supplied a section routine the same way.

   This port stores the atom itself. Existence is all the corpus tests, and
   a constant whose value is 0 or <> must still read as defined, which
   storing the value would not give. KNOWN GAP: pronouns.zil's
   PRONOUN-PROPSPEC asks <TYPE? <GETPROP .R ZVAL> ROUTINE>, which needs the
   stored value to have type ROUTINE; that helper only runs for an object
   with a PRONOUN property, which no game this port compiles yet has. *)
PROCEDURE SetZVal*(atom: ZilObj.Zo);
BEGIN
  IF (atom # NIL) & (atom.kind = ZilObj.KAtom) THEN
    ZilObj.PutProp(atom, ZilObj.Intern("ZVAL"), atom)
  END
END SetZVal;

(* A ROUTINE's ZVAL is a value of type ROUTINE rather than the atom, because
   pronouns.zil's PRONOUN-PROPSPEC builds a name and then asks
   <TYPE? <GETPROP .R ZVAL> ROUTINE> to check that it really names one.
   Storing the atom made every <PRONOUN IT HIM> definition fail with
   NO-SUCH-PRONOUN. *)
PROCEDURE SetZValRoutine*(atom: ZilObj.Zo);
BEGIN
  IF (atom # NIL) & (atom.kind = ZilObj.KAtom) THEN
    ZilObj.PutProp(atom, ZilObj.Intern("ZVAL"), ZilObj.NewRoutineRef(atom))
  END
END SetZValRoutine;

PROCEDURE IsTrue*(z: ZilObj.Zo): BOOLEAN;
BEGIN RETURN (z # NIL) & (z.kind # ZilObj.KFalse) END IsTrue;

PROCEDURE TrueVal*(): ZilObj.Zo;
BEGIN RETURN ZilObj.Intern("T") END TrueVal;

PROCEDURE FalseVal*(): ZilObj.Zo;
BEGIN RETURN ZilObj.NewEmpty(ZilObj.KFalse) END FalseVal;

PROCEDURE BoolVal(b: BOOLEAN): ZilObj.Zo;
BEGIN IF b THEN RETURN TrueVal() ELSE RETURN FalseVal() END END BoolVal;

(* Exact/structural equality good enough for the starter set: same atom
   identity, same FIX value, same CHARACTER value, same STRING text.
   Lists/forms/vectors are not compared deeply yet (not needed by any
   SUBR implemented so far). *)
PROCEDURE ValuesEqual*(a, b: ZilObj.Zo): BOOLEAN;
BEGIN
  IF a = b THEN RETURN TRUE END;
  IF (a = NIL) OR (b = NIL) THEN RETURN FALSE END;
  IF a.kind # b.kind THEN RETURN FALSE END;
  CASE a.kind OF
    ZilObj.KFix: RETURN a.fixVal = b.fixVal
   |ZilObj.KChar: RETURN a.charVal = b.charVal
   |ZilObj.KString: RETURN (a.strLen = b.strLen) & (a.strBuf^ = b.strBuf^)
  ELSE
    RETURN FALSE
  END
END ValuesEqual;

(* MDL draws a distinction this port had collapsed: `==?` is EXACT equality
   (the same object, or the same primitive value) while `=?` compares
   STRUCTURE. Two separately built <QUOTE REPEATABLE> forms are `=?` but not
   `==?`, and zillib's SCORING-ACHIEVEMENTS relies on precisely that — it
   tests an unevaluated `'REPEATABLE` from its argument list against
   `''REPEATABLE`, and with only exact equality every achievement flag was
   rejected as UNRECOGNIZED-ACHIEVEMENT-FLAG.

   TABLEs are deliberately compared by identity only: a table is a thing with
   an address, not a value, and two tables with equal contents are not the
   same table. *)
PROCEDURE StructurallyEqual*(a, b: ZilObj.Zo): BOOLEAN;
VAR i: INTEGER; pa, pb: ZilObj.Zo;
BEGIN
  IF ValuesEqual(a, b) THEN RETURN TRUE END;
  IF (a = NIL) OR (b = NIL) THEN RETURN FALSE END;
  IF a.kind # b.kind THEN RETURN FALSE END;
  IF (a.kind = ZilObj.KList) OR (a.kind = ZilObj.KForm)
     OR (a.kind = ZilObj.KFalse) OR (a.kind = ZilObj.KSplice) THEN
    pa := a; pb := b;
    WHILE (pa # NIL) & (pa.first # NIL) & (pb # NIL) & (pb.first # NIL) DO
      IF ~StructurallyEqual(pa.first, pb.first) THEN RETURN FALSE END;
      pa := pa.rest; pb := pb.rest
    END;
    (* equal only if BOTH ran out at the same point *)
    RETURN ((pa = NIL) OR (pa.first = NIL)) & ((pb = NIL) OR (pb.first = NIL))
  END;
  IF a.kind = ZilObj.KVector THEN
    IF a.vecLen # b.vecLen THEN RETURN FALSE END;
    FOR i := 0 TO a.vecLen - 1 DO
      IF ~StructurallyEqual(a.vecItems[i], b.vecItems[i]) THEN RETURN FALSE END
    END;
    RETURN TRUE
  END;
  IF a.kind = ZilObj.KAdecl THEN
    RETURN StructurallyEqual(a.adFirst, b.adFirst)
         & StructurallyEqual(a.adSecond, b.adSecond)
  END;
  IF a.kind = ZilObj.KSegment THEN
    RETURN StructurallyEqual(a.segForm, b.segForm)
  END;
  RETURN FALSE
END StructurallyEqual;

(* ------------------------------------------------------------------ *)
(* SUBR dispatch (already-evaluated args) — does not itself call Eval,   *)
(* so it can be declared before Eval without a forward reference.       *)
(* ------------------------------------------------------------------ *)

(* A single-character string literal (e.g. "+") is inferred as CHAR by
   this transpiler, which breaks a direct `name = "+"` comparison against
   a string variable (it silently mistranslates to a raw-char strcmp
   argument and fails to compile) -- compare by length + first char
   instead, as this transpiler's own examples do for CHAR comparisons. *)
PROCEDURE IsOp(name: ARRAY OF CHAR; c: CHAR): BOOLEAN;
BEGIN RETURN (name[0] = c) & (name[1] = 0X) END IsOp;

(* RETURN and AGAIN are ordinary (evaluated-args) SUBRs — the activation
   argument, when given, is already a KActivation value by the time it gets
   here (it was fetched via .NAME / <LVAL NAME>, since PROG binds a named
   activation atom's localVal to the activation itself; see the PROG/REPEAT/
   BIND handling in Eval). Doesn't call Eval, so — unlike Eval itself — this
   can be declared as its own procedure ahead of ApplySubr with no
   forward-reference problem. *)
PROCEDURE ApplyReturnOrAgain(isReturn: BOOLEAN; args: ARRAY OF ZilObj.Zo; n: INTEGER): ZResult;
VAR r: ZResult; act: ZilObj.Zo; explicitIdx: INTEGER;
BEGIN
  IF isReturn THEN explicitIdx := 1 ELSE explicitIdx := 0 END;
  IF n > explicitIdx THEN
    act := args[explicitIdx];
    IF act.kind # ZilObj.KActivation THEN
      RETURN Err("RETURN/AGAIN: activation argument must be an ACTIVATION")
    END
  ELSE
    act := enclosingProgAtom.localVal;
    IF act = NIL THEN RETURN Err("RETURN/AGAIN: no enclosing PROG/REPEAT") END
  END;
  IF isReturn THEN
    r.outcome := OReturn;
    IF n >= 1 THEN r.value := args[0] ELSE r.value := TrueVal() END
  ELSE
    r.outcome := OAgain;
    r.value := NIL
  END;
  r.activation := act;
  RETURN r
END ApplyReturnOrAgain;

(* Shared by the FORM/LIST SUBRs below — doesn't call Eval, so (like
   ApplyReturnOrAgain) it can be its own procedure. *)
PROCEDURE BuildConsChain(kind: INTEGER; args: ARRAY OF ZilObj.Zo; n: INTEGER): ZilObj.Zo;
VAR head, tail, cell: ZilObj.Zo; i: INTEGER;
BEGIN
  head := NIL; tail := NIL;
  FOR i := 0 TO n - 1 DO
    cell := ZilObj.Cons(kind, args[i], NIL);
    IF head = NIL THEN head := cell ELSE tail.rest := cell END;
    tail := cell
  END;
  IF head = NIL THEN RETURN ZilObj.NewEmpty(kind) ELSE RETURN head END
END BuildConsChain;

(* Copies a raw cons-chain (e.g. a body form-chain) into a VECTOR —
   used by REPLACE-DEFINITION below to stash an unevaluated body for later
   (matches the original's own choice of ZilVector for exactly this
   "stored, pending" state). Doesn't call Eval, so this can be its own
   procedure. *)
PROCEDURE ChainToVector(chain: ZilObj.Zo): ZilObj.Zo;
VAR cnt, i: INTEGER; p, v: ZilObj.Zo;
BEGIN
  cnt := 0; p := chain;
  WHILE (p # NIL) & (p.first # NIL) DO INC(cnt); p := p.rest END;
  v := ZilObj.NewVectorN(cnt);
  p := chain; i := 0;
  WHILE (p # NIL) & (p.first # NIL) DO v.vecItems[i] := p.first; INC(i); p := p.rest END;
  RETURN v
END ChainToVector;

(* Scans a flag LIST (e.g. (BYTE LENGTH)) for the TABLE-family SUBRs
   below into a bitmask of ZilObj.TfXXX constants. Doesn't call Eval —
   flagList's elements are plain atoms, nothing to evaluate — so this can
   be its own procedure. Recognizes the common real-source flags (BYTE,
   LENGTH, PURE, PARSER-TABLE as an alias for PURE, LEXV, TEMP-TABLE);
   deliberately not recognizing PATTERN/SEGMENT/STRING/KERNEL/WORD yet —
   pragmatic subset, add on demand. *)
PROCEDURE TableFlagBits(flagList: ZilObj.Zo): INTEGER;
VAR bits: INTEGER; p: ZilObj.Zo;
BEGIN
  bits := 0;
  IF flagList # NIL THEN
    p := flagList;
    WHILE (p # NIL) & (p.first # NIL) DO
      IF p.first.kind = ZilObj.KAtom THEN
        IF ZilObj.IsAtomNamed(p.first, "BYTE") THEN bits := bits + ZilObj.TfByte
        ELSIF ZilObj.IsAtomNamed(p.first, "LENGTH") THEN bits := bits + ZilObj.TfLength
        ELSIF ZilObj.IsAtomNamed(p.first, "PURE") THEN bits := bits + ZilObj.TfPure
        ELSIF ZilObj.IsAtomNamed(p.first, "PARSER-TABLE") THEN bits := bits + ZilObj.TfPure
        ELSIF ZilObj.IsAtomNamed(p.first, "LEXV") THEN bits := bits + ZilObj.TfLexv
        ELSIF ZilObj.IsAtomNamed(p.first, "TEMP-TABLE") THEN bits := bits + ZilObj.TfTemp
        END
      END;
      p := p.rest
    END
  END;
  RETURN bits
END TableFlagBits;

(* Shared by TABLE/LTABLE/PTABLE/PLTABLE below: syntax is
   <[P][L]TABLE [(flags...)] values...> — an optional leading flag LIST,
   then the values themselves (repCount is always 1: unlike ITABLE, these
   don't repeat their initializer). Doesn't call Eval (args are already
   evaluated by the generic SUBR dispatch), so this can be its own
   procedure. Registers into ZilModel unless TEMP-TABLE was given, exactly
   matching the original's own exclusion (a TEMP-TABLE is compiler-
   internal scratch space, never part of the final output). *)
PROCEDURE PerformTable(pure, wantLength: BOOLEAN; args: ARRAY OF ZilObj.Zo; n: INTEGER): ZResult;
VAR flags, valStart, i: INTEGER; tab: ZilObj.Zo; vals: ARRAY MaxArgs OF ZilObj.Zo;
BEGIN
  flags := 0; valStart := 0;
  IF (n > 0) & (args[0].kind = ZilObj.KList) THEN
    flags := TableFlagBits(args[0]); valStart := 1
  END;
  IF pure THEN flags := flags + ZilObj.TfPure END;
  IF wantLength THEN flags := flags + ZilObj.TfLength END;
  FOR i := valStart TO n - 1 DO vals[i - valStart] := args[i] END;
  tab := ZilObj.NewTable(vals, n - valStart, 1, flags);
  IF (flags DIV ZilObj.TfTemp) MOD 2 = 0 THEN ZilModel.AddTable(tab) END;
  RETURN MkVal(tab)
END PerformTable;

(* <ITABLE [specifier] count [(flags...)] init...>: `count` repetitions of
   `init` (or of a single zero, if no init values given). `init` can
   exceed MaxArgs*count-many call-site arguments while still needing many
   more *expanded* elements (e.g. <ITABLE 100 0> has 2 call-site args but
   100 expanded elements), so this uses its own much larger buffer rather
   than the shared MaxArgs-bounded one. Doesn't call Eval, so — like
   PerformTable — this can be its own procedure. The specifier atom
   (NONE/BYTE/WORD) is a coarser approximation here than the original's
   separate "element type" vs "length-prefix type" distinction — pragmatic
   subset, only BYTE is distinguished (as ZilObj.TfByte), matching the
   overwhelmingly common real usage. *)
PROCEDURE PerformITable(args: ARRAY OF ZilObj.Zo; n: INTEGER): ZResult;
VAR idx, flags, count, i, initN, totalN: INTEGER; tab: ZilObj.Zo;
    vals: ARRAY MaxTableElems OF ZilObj.Zo;
BEGIN
  idx := 0; flags := 0;
  IF (n > idx) & (args[idx].kind = ZilObj.KAtom) THEN
    (* The original's own comment on this argument: "specifier controls the
       LENGTH MARKER. BYTE specifier makes the length marker a byte (but the
       table is still a word table unless changed with a flag)." NONE/BYTE/
       WORD, and only NONE means "no length prefix at all" - BYTE and WORD
       both mean "prepend one length word/byte, pre-filled with the element
       count", making the table ONE ELEMENT LARGER than `count`, not `count`
       elements exactly.

       Getting this wrong is silent and severe: zillib's SCOPE-CURRENT-STAGES
       is <ITABLE WORD ,SCOPE-CURRENT-STAGES-SIZE> - a table of N routine
       references PLUS a leading count word the scope-crawl machinery reads
       and writes directly (GET/PUT index 0). Treating WORD as a no-op (as
       this port used to) allocates a table with only N words total instead
       of N+1, so the library's own PUT of the count into "slot 0" is really
       overwriting DATA SLOT 0, and reading past the last data slot the
       library actually filled walks off the end of the table into whatever
       memory follows it in the story file - read there long enough (which
       "take" an out-of-scope object does, via the scope-stage fallback that
       widens to every stage) and eventually a CALL is made through a
       Z-machine-valid-looking but PACKED-ADDRESS-garbage value: "call to a
       non-routine". Confirmed against a real build of zilf's own compiler:
       it emits `SCOPE-CURRENT-STAGES:: .TABLE 16` for this exact call - 16
       bytes, i.e. 8 words for a table of 7 elements, one more than `count`.

       This port ties the length prefix's width to the same TfByte flag that
       governs element width by default (rather than tracking them as
       independent bits, as the original's TableFormat.ByteLength/WordLength
       do) - a simplification that happens to be exact for every real use in
       this corpus: the one BYTE-specifier table (verbs.zil's TREE-INDENT)
       tags every element with its own <BYTE n>, which overrides the table's
       default width regardless, and the one WORD-specifier table (this one)
       has no elements narrower than a word to begin with. *)
    IF ZilObj.IsAtomNamed(args[idx], "BYTE") THEN
      flags := flags + ZilObj.TfLength + ZilObj.TfByte
    ELSIF ZilObj.IsAtomNamed(args[idx], "WORD") THEN
      flags := flags + ZilObj.TfLength
    END;
    INC(idx)
  END;
  IF (n <= idx) OR (args[idx].kind # ZilObj.KFix) THEN
    RETURN Err("ITABLE: expected a repetition count")
  END;
  count := args[idx].fixVal;
  INC(idx);
  IF count < 1 THEN RETURN Err("ITABLE: invalid table size") END;

  IF (n > idx) & (args[idx].kind = ZilObj.KList) THEN
    flags := flags + TableFlagBits(args[idx]); INC(idx)
  END;

  initN := n - idx;
  IF initN = 0 THEN
    totalN := count;
    IF totalN > MaxTableElems THEN totalN := MaxTableElems END;
    FOR i := 0 TO totalN - 1 DO vals[i] := ZilObj.NewFix(0) END
  ELSE
    totalN := count * initN;
    IF totalN > MaxTableElems THEN totalN := MaxTableElems END;
    FOR i := 0 TO totalN - 1 DO vals[i] := args[idx + (i MOD initN)] END
  END;

  tab := ZilObj.NewTable(vals, totalN, count, flags);
  IF (flags DIV ZilObj.TfTemp) MOD 2 = 0 THEN ZilModel.AddTable(tab) END;
  RETURN MkVal(tab)
END PerformITable;

(* ---------------- DEFSTRUCT ----------------
   <DEFSTRUCT NAME BASE (FIELD DECL options...) ...> defines a record type
   over a TABLE or VECTOR: an accessor macro per field, and a MAKE-NAME
   constructor. Ported from Subrs.Defstruct.cs, which builds both by
   generating ZIL source and evaluating it — the same approach here, now
   that ZilRead can parse from a string.

   BASE is either a bare type atom or a list whose head is the type atom
   followed by option clauses: ('NTH fn) ('PUT fn) ('START-OFFSET n). Each
   field may override 'NTH/'PUT and give an explicit 'OFFSET; otherwise the
   offset auto-increments from the start offset.

   The original has three accessor templates, differing only in how much
   DECL checking they wrap around the access. This port skips DECL checking
   entirely (a phase-1 decision), so its SNoCheckTemplate — the one with no
   wrapping at all — is exactly right and the other two would only add
   machinery that does nothing:

       <DEFMAC FIELD ('S "OPT" 'NV)
           <COND (<ASSIGNED? NV> <FORM PUTFN .S OFFSET .NV>)
                 (T             <FORM NTHFN .S OFFSET>)>>

   Not ported: 'CONSTRUCTOR (a custom constructor argspec), 'INIT-ARGS,
   'PRINTTYPE, 'NODECL/'NOTYPE (no-ops here, since there is no DECL or type
   registry to suppress), and per-field default values — none is used by
   the corpus. *)

TYPE
  StructRec = RECORD
    name*: ARRAY 64 OF CHAR;
    baseIsVector*: BOOLEAN;
    startOffset*: INTEGER;
    nFields*: INTEGER;
    fieldName*: ARRAY MaxStructFields OF ARRAY 64 OF CHAR;
    fieldOffset*: ARRAY MaxStructFields OF INTEGER;
    (* the field's 'PUT accessor. It decides whether fieldOffset counts
       WORDS (PUT/ZPUT) or BYTES (PUTB), which matters as soon as a
       DEFSTRUCT over a TABLE is initialised at compile time. *)
    fieldPut*: ARRAY MaxStructFields OF ARRAY 16 OF CHAR
  END;

VAR
  structs: ARRAY MaxStructs OF StructRec;
  nStructs: INTEGER;

PROCEDURE FindStruct(name: ARRAY OF CHAR): INTEGER;
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE i < nStructs DO
    IF structs[i].name = name THEN RETURN i END;
    INC(i)
  END;
  RETURN -1
END FindStruct;

(* The scope-search bit a SYNTAX option name selects — the original's
   ScopeFlags.Original values. A line that names any options replaces the
   default set (ON-GROUND+IN-ROOM+CARRIED+HELD) rather than adding to it. *)
PROCEDURE ScopeFlagBits(name: ARRAY OF CHAR): INTEGER;
BEGIN
  IF name = "HAVE" THEN RETURN 2 END;
  IF name = "MANY" THEN RETURN 4 END;
  IF name = "TAKE" THEN RETURN 8 END;
  IF name = "ON-GROUND" THEN RETURN 16 END;
  IF name = "IN-ROOM" THEN RETURN 32 END;
  IF name = "CARRIED" THEN RETURN 64 END;
  IF name = "HELD" THEN RETURN 128 END;
  RETURN 0
END ScopeFlagBits;

(* x with every bit of `mask` cleared. Scope flags are one byte, so eight bits
   is the whole range; this dialect has no AND NOT for INTEGERs. *)
PROCEDURE ClearBits(x, mask: INTEGER): INTEGER;
VAR bit, res: INTEGER;
BEGIN
  res := 0; bit := 1;
  WHILE bit <= 128 DO
    IF ((x DIV bit) MOD 2 = 1) & ((mask DIV bit) MOD 2 = 0) THEN res := res + bit END;
    bit := bit * 2
  END;
  RETURN res
END ClearBits;

PROCEDURE GlobalFix(name: ARRAY OF CHAR; dflt: INTEGER): INTEGER;
VAR a: ZilObj.Zo;
BEGIN
  a := ZilObj.Intern(name);
  IF (a.globalVal # NIL) & (a.globalVal.kind = ZilObj.KFix) THEN
    RETURN a.globalVal.fixVal
  END;
  RETURN dflt
END GlobalFix;

(* A library may redefine what the scope-flag names in a SYNTAX line mean, by
   setting NEW-SFLAGS to a vector of name/value pairs. zillib does, because it
   has always treated ON-GROUND and IN-ROOM alike (and CARRIED and HELD
   alike), so it reuses the freed bits for EVERYWHERE and TOUCH.

   Ignoring this is quiet and total. zillib's SEARCH-ALL is 24, not the
   original default 240, and its parser tests the bits it defined; emitting
   the built-in values instead means every syntax line's scope byte names the
   wrong set, so no command ever finds its objects. *)
PROCEDURE NewSflags(): ZilObj.Zo;
VAR a: ZilObj.Zo;
BEGIN
  a := ZilObj.Intern("NEW-SFLAGS");
  IF (a.globalVal # NIL) & (a.globalVal.kind = ZilObj.KVector) THEN
    RETURN a.globalVal
  END;
  RETURN NIL
END NewSflags;

(* The bit value NEW-SFLAGS gives `name`, or -1 if it does not mention it.
   A value written (+ n) marks the flag ADDITIVE: it combines with the default
   set instead of replacing it. *)
PROCEDURE NewSflagValue(v: ZilObj.Zo; name: ARRAY OF CHAR;
                        VAR additive: BOOLEAN): INTEGER;
VAR i: INTEGER; nm, val: ZilObj.Zo; t: ARRAY 64 OF CHAR;
BEGIN
  additive := FALSE;
  i := 0;
  WHILE i + 1 < v.vecLen DO
    nm := v.vecItems[i]; val := v.vecItems[i + 1];
    t[0] := 0X;
    IF nm # NIL THEN
      IF nm.kind = ZilObj.KString THEN Strings.Copy(nm.strBuf^, t)
      ELSIF nm.kind = ZilObj.KAtom THEN Strings.Copy(nm.atomText, t)
      END
    END;
    IF t = name THEN
      (* The vector's elements are EVALUATED, so the `+` marking an additive
         flag arrives as the addition SUBR rather than as the atom - a bare
         atom evaluates to its global value, and `+` has one. The original
         looks for the atom; accept either spelling, since a KSubr keeps its
         name in the same field. *)
      IF (val # NIL) & (val.kind = ZilObj.KList) & (val.first # NIL)
         & (val.first.atomText = "+")
         & ((val.first.kind = ZilObj.KAtom) OR (val.first.kind = ZilObj.KSubr)
            OR (val.first.kind = ZilObj.KFSubr))
         & (val.rest # NIL) & (val.rest.first # NIL) THEN
        additive := TRUE; val := val.rest.first
      END;
      IF (val # NIL) & (val.kind = ZilObj.KFix) THEN RETURN val.fixVal END;
      RETURN -1
    END;
    i := i + 2
  END;
  RETURN -1
END NewSflagValue;

(* The scope byte for one object of a SYNTAX line. `list` is the option list
   as written, or NIL for "none given", which means the defaults. Ported from
   the original's ScopeFlags.Parse, including the rule that the first
   non-additive option clears the defaults. *)
PROCEDURE ScopeFlagsParse(list: ZilObj.Zo): INTEGER;
VAR v, p: ZilObj.Zo; res, val, dflt: INTEGER; cleared, additive: BOOLEAN;
    nm: ARRAY 64 OF CHAR;
BEGIN
  v := NewSflags();
  IF v = NIL THEN
    IF list = NIL THEN RETURN 240 END;
    res := 0; p := list;
    WHILE (p # NIL) & (p.first # NIL) DO
      IF p.first.kind = ZilObj.KAtom THEN
        res := ZilModel.BitOr(res, ScopeFlagBits(p.first.atomText))
      END;
      p := p.rest
    END;
    RETURN res
  END;

  dflt := GlobalFix("SEARCH-ALL", 240);
  IF list = NIL THEN RETURN dflt END;
  res := dflt; cleared := FALSE;
  p := list;
  WHILE (p # NIL) & (p.first # NIL) DO
    IF p.first.kind = ZilObj.KAtom THEN
      Strings.Copy(p.first.atomText, nm);
      additive := FALSE;
      IF nm = "HAVE" THEN val := GlobalFix("SEARCH-MUST-HAVE", 0); additive := TRUE
      ELSIF nm = "TAKE" THEN val := GlobalFix("SEARCH-DO-TAKE", 0); additive := TRUE
      ELSIF nm = "MANY" THEN val := GlobalFix("SEARCH-MANY", 0); additive := TRUE
      ELSE val := NewSflagValue(v, nm, additive)
      END;
      IF val >= 0 THEN
        IF ~cleared & ~additive THEN
          cleared := TRUE; res := ClearBits(res, dflt)
        END;
        res := ZilModel.BitOr(res, val)
      END
    END;
    p := p.rest
  END;
  RETURN res
END ScopeFlagsParse;

(* The PartOfSpeech bit a <VOC "x" TYPE> type name selects. The names come
   in pairs (ADJ/ADJECTIVE, NOUN/OBJECT) because real source uses both. *)
PROCEDURE PartOfSpeechBits(name: ARRAY OF CHAR): INTEGER;
BEGIN
  IF (name = "ADJ") OR (name = "ADJECTIVE") THEN RETURN ZilModel.PsAdjective END;
  IF (name = "NOUN") OR (name = "OBJECT") THEN RETURN ZilModel.PsObject END;
  IF name = "VERB" THEN RETURN ZilModel.PsVerb END;
  IF (name = "PREP") OR (name = "PREPOSITION") THEN RETURN ZilModel.PsPreposition END;
  IF (name = "DIR") OR (name = "DIRECTION") THEN RETURN ZilModel.PsDirection END;
  IF name = "BUZZ" THEN RETURN ZilModel.PsBuzzword END;
  RETURN 0
END PartOfSpeechBits;

(* ---------------- OBLISTs as compile-time data ----------------
   Name RESOLUTION in this port uses one flat atom table (phase 1's
   simplification, and the package work confirmed it is enough). But
   zillib/libmsg.zil uses OBLISTs for something else entirely: as hash maps
   built while compiling. It does

       <SETG LIBMSG-OL <MOBLIST LIBRARY-MESSAGES>>
       <MOBLIST <OR <LOOKUP .N ,LIBMSG-OL> <INSERT .N ,LIBMSG-OL>>>

   to get a per-category oblist, then interns each message name in it. The
   original stores the resulting atom under a qualified name —
   SUCCESS!-TAKE!-LIBRARY-MESSAGES — and that spelling is the whole trick
   this port needs: an OBLIST here carries nothing but its NAME, and
   INSERT/LOOKUP intern `NAME!-<oblist name>` in the one flat table. The
   qualified names come out identical to the original's, so source that
   spells one out literally still finds the same atom.

   Membership (what distinguishes "this oblist contains N" from "that atom
   merely exists") is recorded on the atom's own property list under an
   internal indicator, reusing PUTPROP/GETPROP rather than adding a table. *)

PROCEDURE OblistMarker(): ZilObj.Zo;
BEGIN RETURN ZilObj.Intern("OBLIST ") END OblistMarker;

PROCEDURE FindOrMakeOblist(name: ARRAY OF CHAR): ZilObj.Zo;
VAR i: INTEGER; o: ZilObj.Zo;
BEGIN
  i := 0;
  WHILE i < nOblists DO
    IF oblists[i].atomText = name THEN RETURN oblists[i] END;
    INC(i)
  END;
  NEW(o);
  o.kind := ZilObj.KOblist;
  Strings.Copy(name, o.atomText);
  IF nOblists < MaxOblists THEN oblists[nOblists] := o; INC(nOblists) END;
  RETURN o
END FindOrMakeOblist;

(* The flat-table name an entry called `pname` in `oblist` interns under. *)
PROCEDURE QualifiedName(pname: ARRAY OF CHAR; oblist: ZilObj.Zo; VAR out: ARRAY OF CHAR);
BEGIN
  Strings.Copy(pname, out);
  IF (oblist # NIL) & (oblist.atomText # "ROOT") THEN
    Strings.Append("!-", out); Strings.Append(oblist.atomText, out)
  END
END QualifiedName;

(* ---------------- MDL structure primitives ----------------
   NTH/REST/EMPTY?/LENGTH/TYPE/TYPE? and friends work on any "structured"
   value. The three shapes this port has are cons chains (LIST/FORM/FALSE),
   flat arrays (VECTOR/TABLE) and STRINGs, so each accessor branches once on
   the kind rather than going through the original's IStructure interface. *)

PROCEDURE IsStructured*(z: ZilObj.Zo): BOOLEAN;
BEGIN
  (* NIL is how this port spells "no value at all", which arises from
     evaluating an empty form; every operation that treats FALSE as an empty
     structure should treat it the same way, and StructLength/StructNth
     already do. *)
  IF z = NIL THEN RETURN TRUE END;
  RETURN (z.kind = ZilObj.KList) OR (z.kind = ZilObj.KForm) OR (z.kind = ZilObj.KVector)
         OR (z.kind = ZilObj.KString) OR (z.kind = ZilObj.KFalse) OR (z.kind = ZilObj.KTable)
         OR (z.kind = ZilObj.KSplice)
END IsStructured;

PROCEDURE StructLength*(z: ZilObj.Zo): INTEGER;
VAR n: INTEGER; p: ZilObj.Zo;
BEGIN
  IF z = NIL THEN RETURN 0 END;
  IF (z.kind = ZilObj.KVector) OR (z.kind = ZilObj.KTable) THEN RETURN z.vecLen END;
  IF z.kind = ZilObj.KString THEN RETURN z.strLen END;
  n := 0; p := z;
  WHILE (p # NIL) & (p.first # NIL) DO INC(n); p := p.rest END;
  RETURN n
END StructLength;

(* 1-based, as every MDL accessor is. Returns NIL when out of range. *)
PROCEDURE StructNth*(z: ZilObj.Zo; i: INTEGER): ZilObj.Zo;
VAR p: ZilObj.Zo;
BEGIN
  IF (z = NIL) OR (i < 1) THEN RETURN NIL END;
  IF (z.kind = ZilObj.KVector) OR (z.kind = ZilObj.KTable) THEN
    IF i > z.vecLen THEN RETURN NIL END;
    RETURN z.vecItems[i - 1]
  END;
  IF z.kind = ZilObj.KString THEN
    IF i > z.strLen THEN RETURN NIL END;
    RETURN ZilObj.NewChar(ORD(z.strBuf^[i - 1]))
  END;
  p := z;
  WHILE (i > 1) & (p # NIL) DO p := p.rest; DEC(i) END;
  IF (p = NIL) OR (p.first = NIL) THEN RETURN NIL END;
  RETURN p.first
END StructNth;

(* Drops the first `n` elements. A cons chain can share its own tail; a
   VECTOR or STRING has to be copied, since this port has no offset-view
   representation (an explicit phase-1 simplification). *)
PROCEDURE StructRest*(z: ZilObj.Zo; n: INTEGER): ZilObj.Zo;
VAR p, v: ZilObj.Zo; i, len: INTEGER; buf: ARRAY 4096 OF CHAR;
BEGIN
  IF z = NIL THEN RETURN NIL END;
  IF n <= 0 THEN RETURN z END;

  IF (z.kind = ZilObj.KVector) OR (z.kind = ZilObj.KTable) THEN
    len := z.vecLen - n;
    IF len < 0 THEN len := 0 END;
    v := ZilObj.NewVectorN(len);
    FOR i := 0 TO len - 1 DO v.vecItems[i] := z.vecItems[n + i] END;
    RETURN v
  END;

  IF z.kind = ZilObj.KString THEN
    len := z.strLen - n;
    IF len < 0 THEN len := 0 END;
    FOR i := 0 TO len - 1 DO buf[i] := z.strBuf^[n + i] END;
    buf[len] := 0X;
    RETURN ZilObj.NewString(buf)
  END;

  p := z;
  WHILE (n > 0) & (p # NIL) DO p := p.rest; DEC(n) END;
  IF p = NIL THEN RETURN ZilObj.NewEmpty(z.kind) END;
  RETURN p
END StructRest;

(* Replaces the i'th element (1-based) of a flat structure. Only the array
   shapes are mutable here, which is all DEFSTRUCT's constructor needs — a
   cons chain would need its cell rewritten in place and nothing asks for
   that. *)
(* ---------------- width-aware TABLE element access ----------------
   A TABLE's elements are not all the same width: the table has a default
   (word, or byte when it was declared BYTE) and any element may override it,
   which is how <BYTE n> works. So a byte OFFSET into a table is not an
   element index, and a WORD index is not either. The original keeps the
   distinction in ZilTable's GetWord/PutWord/GetByte/PutByte; these three
   helpers are the part of that this port needs, which is writing a word into
   a byte-wide table at compile time - exactly what zillib's PARSER-RESULT
   does, and what makes the parser work.

   Limitation: the byte offsets counted here are offsets into the ELEMENTS
   only. A table with a LENGTH prefix or the LEXV header would need those
   counted too; neither is ever written this way. *)

PROCEDURE TableElemWidth(t: ZilObj.Zo; i: INTEGER): INTEGER;
VAR w: ZilObj.Zo;
BEGIN
  w := ZilObj.GetProp(t.vecItems[i], ZilObj.Intern("WIDTH "));
  IF w # NIL THEN
    IF w.atomText = "BYTE" THEN RETURN 1 END;
    RETURN 2
  END;
  IF (t.tabFlags DIV ZilObj.TfByte) MOD 2 = 1 THEN RETURN 1 END;
  RETURN 2
END TableElemWidth;

(* the index of the element that STARTS at byte offset `off`, or -1 if the
   offset falls inside an element rather than on its boundary *)
PROCEDURE TableElemAt(t: ZilObj.Zo; off: INTEGER): INTEGER;
VAR i, cur: INTEGER;
BEGIN
  i := 0; cur := 0;
  WHILE (i < t.vecLen) & (cur < off) DO
    cur := cur + TableElemWidth(t, i);
    INC(i)
  END;
  IF (i < t.vecLen) & (cur = off) THEN RETURN i END;
  RETURN -1
END TableElemAt;

(* Tags a value with the element width it must be emitted at. A FIX is copied
   first: the tag lives on the value itself, so tagging a shared one would
   change its width everywhere it appears. *)
PROCEDURE WithWidth(v: ZilObj.Zo; isByte: BOOLEAN): ZilObj.Zo;
VAR w: ZilObj.Zo;
BEGIN
  IF v = NIL THEN v := ZilObj.NewFix(0)
  ELSIF v.kind = ZilObj.KFix THEN v := ZilObj.NewFix(v.fixVal)
  END;
  IF isByte THEN w := ZilObj.Intern("BYTE") ELSE w := ZilObj.Intern("WORD") END;
  ZilObj.PutProp(v, ZilObj.Intern("WIDTH "), w);
  RETURN v
END WithWidth;

(* The element at a word or byte offset, or NIL when the offset falls inside
   an element rather than on its boundary. *)
PROCEDURE TableGetWord*(t: ZilObj.Zo; wordIdx: INTEGER): ZilObj.Zo;
VAR i: INTEGER;
BEGIN
  IF (t = NIL) OR (t.kind # ZilObj.KTable) OR (wordIdx < 0) THEN RETURN NIL END;
  i := TableElemAt(t, wordIdx * 2);
  IF (i < 0) OR (TableElemWidth(t, i) # 2) THEN RETURN NIL END;
  RETURN t.vecItems[i]
END TableGetWord;

PROCEDURE TableGetByte*(t: ZilObj.Zo; byteIdx: INTEGER): ZilObj.Zo;
VAR i: INTEGER;
BEGIN
  IF (t = NIL) OR (t.kind # ZilObj.KTable) OR (byteIdx < 0) THEN RETURN NIL END;
  i := TableElemAt(t, byteIdx);
  IF (i < 0) OR (TableElemWidth(t, i) # 1) THEN RETURN NIL END;
  RETURN t.vecItems[i]
END TableGetByte;

PROCEDURE TablePutWord*(t: ZilObj.Zo; wordIdx: INTEGER; v: ZilObj.Zo): BOOLEAN;
VAR i, k: INTEGER;
BEGIN
  IF (t = NIL) OR (t.kind # ZilObj.KTable) OR (wordIdx < 0) THEN RETURN FALSE END;
  i := TableElemAt(t, wordIdx * 2);
  IF i < 0 THEN RETURN FALSE END;
  IF TableElemWidth(t, i) = 2 THEN
    t.vecItems[i] := WithWidth(v, FALSE); RETURN TRUE
  END;
  (* two byte slots together make up this word, so they become one element *)
  IF (i + 1 >= t.vecLen) OR (TableElemWidth(t, i + 1) # 1) THEN RETURN FALSE END;
  t.vecItems[i] := WithWidth(v, FALSE);
  k := i + 1;
  WHILE k < t.vecLen - 1 DO t.vecItems[k] := t.vecItems[k + 1]; INC(k) END;
  DEC(t.vecLen);
  RETURN TRUE
END TablePutWord;

PROCEDURE TablePutByte*(t: ZilObj.Zo; byteIdx: INTEGER; v: ZilObj.Zo): BOOLEAN;
VAR i, k: INTEGER;
BEGIN
  IF (t = NIL) OR (t.kind # ZilObj.KTable) OR (byteIdx < 0) THEN RETURN FALSE END;
  i := TableElemAt(t, byteIdx);
  IF i < 0 THEN RETURN FALSE END;
  IF TableElemWidth(t, i) = 1 THEN
    t.vecItems[i] := WithWidth(v, TRUE); RETURN TRUE
  END;
  (* splitting a word slot into two bytes needs room for one more element *)
  IF t.vecLen >= LEN(t.vecItems^) THEN RETURN FALSE END;
  k := t.vecLen;
  WHILE k > i DO t.vecItems[k] := t.vecItems[k - 1]; DEC(k) END;
  INC(t.vecLen);
  t.vecItems[i] := WithWidth(v, TRUE);
  t.vecItems[i + 1] := WithWidth(ZilObj.NewFix(0), TRUE);
  RETURN TRUE
END TablePutByte;

PROCEDURE StructPut*(z: ZilObj.Zo; i: INTEGER; v: ZilObj.Zo): BOOLEAN;
VAR p: ZilObj.Zo; k: INTEGER;
BEGIN
  IF (z = NIL) OR (i < 1) THEN RETURN FALSE END;
  IF (z.kind = ZilObj.KVector) OR (z.kind = ZilObj.KTable) THEN
    IF i > z.vecLen THEN RETURN FALSE END;
    z.vecItems[i - 1] := v;
    RETURN TRUE
  END;
  (* a cons chain: MDL's PUT works on a LIST as well as a VECTOR *)
  IF (z.kind = ZilObj.KList) OR (z.kind = ZilObj.KForm)
     OR (z.kind = ZilObj.KFalse) OR (z.kind = ZilObj.KSplice) THEN
    p := z; k := 1;
    WHILE (p # NIL) & (p.first # NIL) & (k < i) DO p := p.rest; INC(k) END;
    IF (p = NIL) OR (p.first = NIL) THEN RETURN FALSE END;
    p.first := v;
    RETURN TRUE
  END;
  RETURN FALSE
END StructPut;

(* The type NAME of a value, as TYPE returns it and TYPE? matches against. *)
PROCEDURE TypeName*(z: ZilObj.Zo; VAR s: ARRAY OF CHAR);
BEGIN
  IF z = NIL THEN Strings.Copy("FALSE", s); RETURN END;
  CASE z.kind OF
    ZilObj.KAtom:       Strings.Copy("ATOM", s)
   |ZilObj.KFix:        Strings.Copy("FIX", s)
   |ZilObj.KString:     Strings.Copy("STRING", s)
   |ZilObj.KChar:       Strings.Copy("CHARACTER", s)
   |ZilObj.KForm:       Strings.Copy("FORM", s)
   |ZilObj.KList:       Strings.Copy("LIST", s)
   |ZilObj.KVector:     Strings.Copy("VECTOR", s)
   |ZilObj.KAdecl:      Strings.Copy("ADECL", s)
   |ZilObj.KSegment:    Strings.Copy("SEGMENT", s)
   |ZilObj.KFalse:      Strings.Copy("FALSE", s)
   |ZilObj.KSubr:       Strings.Copy("SUBR", s)
   |ZilObj.KFSubr:      Strings.Copy("FSUBR", s)
   |ZilObj.KActivation: Strings.Copy("ACTIVATION", s)
   |ZilObj.KFunction:   Strings.Copy("FUNCTION", s)
   |ZilObj.KMacro:      Strings.Copy("MACRO", s)
   |ZilObj.KTable:      Strings.Copy("TABLE", s)
   |ZilObj.KRoutine:    Strings.Copy("ROUTINE", s)
   |ZilObj.KOblist:     Strings.Copy("OBLIST", s)
   |ZilObj.KSplice:     Strings.Copy("SPLICE", s)
  ELSE Strings.Copy("ANY", s)
  END
END TypeName;

(* Parses a Z-machine version specifier: one of the historical Infocom
   interpreter names (ZIP/EZIP/XZIP/YZIP), given either as an atom or a
   string, or a plain number 3..8. Direct port of the original's own
   ParseZVersion (Subrs.ZModel.cs). GLULX maps to 1000, the original's own
   ZEnvironment.GLULX_ZVERSION — it has to be RECOGNIZED even though this
   port will never emit for it, because real library source selects between
   Glulx and Z-machine with <VERSION? (GLULX ...) (ELSE ...)> and rejecting
   the specifier outright would kill the whole form rather than simply not
   matching it (zillib/parser.zil's WORD-SIZE definition is exactly this).
   Returns 0 for anything unrecognized. *)
PROCEDURE ParseZVersion*(z: ZilObj.Zo): INTEGER;
VAR text: ARRAY 64 OF CHAR;
BEGIN
  IF z = NIL THEN RETURN 0 END;
  IF z.kind = ZilObj.KFix THEN
    IF (z.fixVal >= 3) & (z.fixVal <= 8) THEN RETURN z.fixVal END;
    RETURN 0
  END;
  IF z.kind = ZilObj.KAtom THEN Strings.Copy(z.atomText, text)
  ELSIF z.kind = ZilObj.KString THEN Strings.Copy(z.strBuf^, text)
  ELSE RETURN 0
  END;
  IF text = "ZIP" THEN RETURN 3
  ELSIF text = "EZIP" THEN RETURN 4
  ELSIF text = "XZIP" THEN RETURN 5
  ELSIF text = "YZIP" THEN RETURN 6
  ELSIF text = "GLULX" THEN RETURN 1000
  END;
  RETURN 0
END ParseZVersion;

(* ---------------- SORT ----------------
   MDL's SORT rearranges a VECTOR in place and hands it back. zillib uses it
   once, to put the achievement definitions back into declaration order
   before building their table, but that one use is load-bearing: the
   achievements table and ACHIEVEMENT-COUNT both come out of it. *)

PROCEDURE TextGreater(a, b: ARRAY OF CHAR): BOOLEAN;
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (a[i] # 0X) & (a[i] = b[i]) DO INC(i) END;
  RETURN a[i] > b[i]
END TextGreater;

(* Answers the one question an insertion sort needs: is A greater than B?
   The original asks its predicate twice per comparison (A>B, then B>A) to
   build a three-way result for a general comparison sort; a stable
   insertion sort only needs the first question, and treats "not greater"
   as "already in order", which gives the same answer for equal keys. A
   FALSE predicate selects the built-in ordering on FIX/CHARACTER/ATOM/
   STRING keys, as in the original. *)
PROCEDURE SortGreater(pred, a, b: ZilObj.Zo; VAR err: BOOLEAN): BOOLEAN;
VAR pargs: ARRAY 2 OF ZilObj.Zo; r: ZResult;
BEGIN
  err := FALSE;
  IF (pred # NIL) & IsTrue(pred) THEN
    pargs[0] := a; pargs[1] := b;
    r := ApplyValue(pred, pargs, 2);
    IF evalErrFlag THEN err := TRUE; RETURN FALSE END;
    RETURN IsTrue(r.value)
  END;
  IF (a = NIL) OR (b = NIL) OR (a.kind # b.kind) THEN
    err := TRUE; RETURN FALSE
  END;
  IF a.kind = ZilObj.KFix THEN RETURN a.fixVal > b.fixVal
  ELSIF a.kind = ZilObj.KChar THEN RETURN a.charVal > b.charVal
  ELSIF a.kind = ZilObj.KAtom THEN RETURN TextGreater(a.atomText, b.atomText)
  ELSIF a.kind = ZilObj.KString THEN RETURN TextGreater(a.strBuf^, b.strBuf^)
  END;
  err := TRUE; RETURN FALSE
END SortGreater;

PROCEDURE SortVector(pred, vec: ZilObj.Zo; recSize, keyOff: INTEGER): BOOLEAN;
VAR nRec, i, j, k: INTEGER; err, gt: BOOLEAN; tmp: ZilObj.Zo;
BEGIN
  nRec := vec.vecLen DIV recSize;
  i := 1;
  WHILE i < nRec DO
    j := i;
    WHILE j > 0 DO
      gt := SortGreater(pred, vec.vecItems[(j - 1) * recSize + keyOff],
                              vec.vecItems[j * recSize + keyOff], err);
      IF err THEN RETURN FALSE END;
      IF ~gt THEN
        j := 0
      ELSE
        FOR k := 0 TO recSize - 1 DO
          tmp := vec.vecItems[(j - 1) * recSize + k];
          vec.vecItems[(j - 1) * recSize + k] := vec.vecItems[j * recSize + k];
          vec.vecItems[j * recSize + k] := tmp
        END;
        DEC(j)
      END
    END;
    INC(i)
  END;
  RETURN TRUE
END SortVector;

(* `.X` and `,X` read as the two-element FORMs <LVAL X> and <GVAL X>. TYPE
   still calls them FORMs, but TYPE? also answers LVAL/GVAL for them, and
   CHTYPE converts between such a form and a bare ATOM. The original marks
   these out as "hacky special cases for GVAL and LVAL"; they are
   load-bearing all the same. zillib's library-message substitution finds the
   placeholders in a message template with <TYPE? .STRUC LVAL> and reads the
   name back out with <CHTYPE .STRUC ATOM>, so without them every message's
   .OBJ / .WHOM / .POINTS survives into the generated code as a reference to
   a local variable that the calling routine does not have.

   Returns the named atom, or NIL when `z` is not a form of that shape. *)
PROCEDURE ValFormAtom(z: ZilObj.Zo; which: ARRAY OF CHAR): ZilObj.Zo;
BEGIN
  IF (z # NIL) & (z.kind = ZilObj.KForm) & (z.first # NIL)
     & (z.first.kind = ZilObj.KAtom) & (z.first.atomText = which)
     & (z.rest # NIL) & (z.rest.first # NIL)
     & (z.rest.first.kind = ZilObj.KAtom)
     & ((z.rest.rest = NIL) OR (z.rest.rest.first = NIL)) THEN
    RETURN z.rest.first
  END;
  RETURN NIL
END ValFormAtom;

PROCEDURE ApplySubr*(name: ARRAY OF CHAR; args: ARRAY OF ZilObj.Zo; n: INTEGER): ZResult;
VAR sum, i, len, synKind: INTEGER; s: ARRAY 4096 OF CHAR; ind: ZilObj.Zo;
    msgBuf: ARRAY 512 OF CHAR; opText: ARRAY 32 OF CHAR;
    resultHead, resultTail: ZilObj.Zo;
BEGIN
  IF (name = "SET") OR (name = "SETG") OR (name = "GLOBAL") OR (name = "CONSTANT") THEN
    (* The originals for GLOBAL/CONSTANT are FSUBRs (name unevaluated,
       value explicitly Eval'd inside the SUBR body) rather than plain
       evaluated-args SUBRs like this — but since a bare ATOM name (the
       overwhelmingly common case) or an ADECL name (Eval already reduces
       to the bare atom, decl discarded, matching this port's usual
       "DECL checking skipped" simplification) self-evaluate to exactly
       what the FSUBR form would have bound anyway, treating them as
       ordinary evaluated-args SUBRs here produces the same observable
       result for real source without needing a separate FSUBR case.
       Redefinition is always silently allowed, same simplification as
       DEFINE/DEFMAC. *)
    IF n < 2 THEN RETURN Err("SET/SETG/GLOBAL/CONSTANT: expected 2 args") END;
    IF args[0].kind # ZilObj.KAtom THEN RETURN Err("SET/SETG/GLOBAL/CONSTANT: first arg must be an ATOM") END;
    IF name = "SET" THEN args[0].localVal := args[1] ELSE args[0].globalVal := args[1] END;
    (* Also register into ZilModel — phase 3a — so a later compilation
       pass can allocate real Z-machine storage and emit a default value.
       Registering doesn't affect this SUBR's own observable behavior at
       all (SETG isn't registered, matching the original: only GLOBAL and
       CONSTANT go into ZEnvironment). *)
    IF name = "GLOBAL" THEN ZilModel.AddGlobal(args[0], args[1]); SetZVal(args[0])
    ELSIF name = "CONSTANT" THEN ZilModel.AddConstant(args[0], args[1]); SetZVal(args[0]) END;
    RETURN MkVal(args[1])

  ELSIF name = "LVAL" THEN
    IF (n < 1) OR (args[0].kind # ZilObj.KAtom) THEN RETURN Err("LVAL: expected an ATOM") END;
    IF args[0].localVal = NIL THEN RETURN ErrAtom("atom has no local value:", args[0]) END;
    RETURN MkVal(args[0].localVal)

  ELSIF name = "GVAL" THEN
    IF (n < 1) OR (args[0].kind # ZilObj.KAtom) THEN RETURN Err("GVAL: expected an ATOM") END;
    IF args[0].globalVal = NIL THEN RETURN ErrAtom("atom has no global value:", args[0]) END;
    RETURN MkVal(args[0].globalVal)

  ELSIF name = "GASSIGNED?" THEN
    RETURN MkVal(BoolVal((n >= 1) & (args[0].kind = ZilObj.KAtom) & (args[0].globalVal # NIL)))

  ELSIF name = "ASSIGNED?" THEN
    RETURN MkVal(BoolVal((n >= 1) & (args[0].kind = ZilObj.KAtom) & (args[0].localVal # NIL)))

  ELSIF name = "PUTPROP" THEN
    IF n < 2 THEN RETURN Err("PUTPROP: expected at least 2 args") END;
    IF n >= 3 THEN ZilObj.PutProp(args[0], args[1], args[2]) ELSE ZilObj.PutProp(args[0], args[1], NIL) END;
    IF n >= 3 THEN RETURN MkVal(args[2]) ELSE RETURN MkVal(args[0]) END

  ELSIF name = "GETPROP" THEN
    IF n < 2 THEN RETURN Err("GETPROP: expected 2 args") END;
    RETURN MkVal(ZilObj.GetProp(args[0], args[1]))

  ELSIF IsOp(name, "+") OR (name = "ADD") THEN
    sum := 0;
    FOR i := 0 TO n - 1 DO
      IF args[i].kind # ZilObj.KFix THEN RETURN Err("+: expected FIX args") END;
      sum := sum + args[i].fixVal
    END;
    RETURN MkVal(ZilObj.NewFix(sum))

  ELSIF IsOp(name, "*") OR (name = "MUL") THEN
    sum := 1;
    FOR i := 0 TO n - 1 DO
      IF args[i].kind # ZilObj.KFix THEN RETURN Err("*: expected FIX args") END;
      sum := sum * args[i].fixVal
    END;
    RETURN MkVal(ZilObj.NewFix(sum))

  ELSIF IsOp(name, "-") OR (name = "SUB") THEN
    IF n = 0 THEN RETURN Err("-: expected at least 1 arg") END;
    FOR i := 0 TO n - 1 DO
      IF args[i].kind # ZilObj.KFix THEN RETURN Err("-: expected FIX args") END
    END;
    IF n = 1 THEN RETURN MkVal(ZilObj.NewFix(-args[0].fixVal)) END;
    sum := args[0].fixVal;
    FOR i := 1 TO n - 1 DO sum := sum - args[i].fixVal END;
    RETURN MkVal(ZilObj.NewFix(sum))

  ELSIF IsOp(name, "/") OR (name = "DIV") THEN
    IF n = 0 THEN RETURN Err("/: expected at least 1 arg") END;
    FOR i := 0 TO n - 1 DO
      IF args[i].kind # ZilObj.KFix THEN RETURN Err("/: expected FIX args") END
    END;
    IF n = 1 THEN
      IF args[0].fixVal = 0 THEN RETURN Err("/: division by zero") END;
      RETURN MkVal(ZilObj.NewFix(1 DIV args[0].fixVal))
    END;
    sum := args[0].fixVal;
    FOR i := 1 TO n - 1 DO
      IF args[i].fixVal = 0 THEN RETURN Err("/: division by zero") END;
      sum := sum DIV args[i].fixVal
    END;
    RETURN MkVal(ZilObj.NewFix(sum))

  ELSIF name = "MOD" THEN
    IF n # 2 THEN RETURN Err("MOD: expected 2 args") END;
    IF (args[0].kind # ZilObj.KFix) OR (args[1].kind # ZilObj.KFix) THEN RETURN Err("MOD: expected FIX args") END;
    IF args[1].fixVal = 0 THEN RETURN Err("MOD: division by zero") END;
    RETURN MkVal(ZilObj.NewFix(args[0].fixVal MOD args[1].fixVal))

  ELSIF name = "1+" THEN
    IF (n # 1) OR (args[0].kind # ZilObj.KFix) THEN RETURN Err("1+: expected 1 FIX arg") END;
    RETURN MkVal(ZilObj.NewFix(args[0].fixVal + 1))

  ELSIF name = "1-" THEN
    IF (n # 1) OR (args[0].kind # ZilObj.KFix) THEN RETURN Err("1-: expected 1 FIX arg") END;
    RETURN MkVal(ZilObj.NewFix(args[0].fixVal - 1))

  ELSIF (name = "=?") OR (name = "EQUAL?") OR (name = "==?") THEN
    IF n < 2 THEN RETURN Err("=?/EQUAL?: expected at least 2 args") END;
    FOR i := 1 TO n - 1 DO
      IF name = "==?" THEN
        IF ValuesEqual(args[0], args[i]) THEN RETURN MkVal(TrueVal()) END
      ELSIF StructurallyEqual(args[0], args[i]) THEN RETURN MkVal(TrueVal())
      END
    END;
    RETURN MkVal(FalseVal())

  ELSIF (name = "N=?") OR (name = "N==?") THEN
    IF n < 2 THEN RETURN Err("N=?: expected at least 2 args") END;
    FOR i := 1 TO n - 1 DO
      IF name = "N==?" THEN
        IF ValuesEqual(args[0], args[i]) THEN RETURN MkVal(FalseVal()) END
      ELSIF StructurallyEqual(args[0], args[i]) THEN RETURN MkVal(FalseVal())
      END
    END;
    RETURN MkVal(TrueVal())

  ELSIF (name = "L?") OR (name = "G?") OR (name = "L=?") OR (name = "G=?") THEN
    IF (n # 2) OR (args[0].kind # ZilObj.KFix) OR (args[1].kind # ZilObj.KFix) THEN
      RETURN Err("comparison: expected 2 FIX args")
    END;
    IF name = "L?" THEN RETURN MkVal(BoolVal(args[0].fixVal < args[1].fixVal))
    ELSIF name = "G?" THEN RETURN MkVal(BoolVal(args[0].fixVal > args[1].fixVal))
    ELSIF name = "L=?" THEN RETURN MkVal(BoolVal(args[0].fixVal <= args[1].fixVal))
    ELSE RETURN MkVal(BoolVal(args[0].fixVal >= args[1].fixVal))
    END

  ELSIF name = "NOT" THEN
    IF n # 1 THEN RETURN Err("NOT: expected 1 arg") END;
    RETURN MkVal(BoolVal(~IsTrue(args[0])))

  ELSIF (name = "PRINC") OR (name = "PRIN1") OR (name = "PRINT") THEN
    IF n # 1 THEN RETURN Err("PRINC/PRIN1/PRINT: expected 1 arg") END;
    IF (name = "PRINC") & (args[0].kind = ZilObj.KString) THEN
      Out.String(args[0].strBuf^)
    ELSE
      ZilObj.PrintTo(args[0], s); Out.String(s)
    END;
    IF name = "PRINT" THEN Out.Ln END;
    RETURN MkVal(args[0])

  ELSIF name = "CRLF" THEN
    Out.Ln; RETURN MkVal(TrueVal())

  ELSIF name = "PRINTN" THEN
    IF (n # 1) OR (args[0].kind # ZilObj.KFix) THEN RETURN Err("PRINTN: expected 1 FIX arg") END;
    Out.Int(args[0].fixVal, 0); RETURN MkVal(args[0])

  ELSIF name = "PRINTC" THEN
    IF (n # 1) OR (args[0].kind # ZilObj.KChar) THEN RETURN Err("PRINTC: expected 1 CHARACTER arg") END;
    Out.Char(CHR(args[0].charVal MOD 256)); RETURN MkVal(args[0])

  ELSIF name = "RETURN" THEN
    RETURN ApplyReturnOrAgain(TRUE, args, n)

  ELSIF name = "AGAIN" THEN
    RETURN ApplyReturnOrAgain(FALSE, args, n)

  ELSIF name = "FORM" THEN
    (* <FORM> with no arguments is the empty FORM, i.e. FALSE — real source
       builds one when a conditional expansion has nothing to contribute. *)
    IF n < 1 THEN RETURN MkVal(ZilObj.NewEmpty(ZilObj.KForm)) END;
    RETURN MkVal(BuildConsChain(ZilObj.KForm, args, n))

  ELSIF name = "LIST" THEN
    RETURN MkVal(BuildConsChain(ZilObj.KList, args, n))

  ELSIF name = "TABLE" THEN
    RETURN PerformTable(FALSE, FALSE, args, n)

  ELSIF name = "LTABLE" THEN
    RETURN PerformTable(FALSE, TRUE, args, n)

  ELSIF name = "PTABLE" THEN
    RETURN PerformTable(TRUE, FALSE, args, n)

  ELSIF name = "PLTABLE" THEN
    RETURN PerformTable(TRUE, TRUE, args, n)

  ELSIF name = "ITABLE" THEN
    RETURN PerformITable(args, n)

  ELSIF name = "SYNTAX" THEN
    (* <SYNTAX VERB [prep] OBJECT [(FIND flag)] [(scope opts)]
               [prep OBJECT ...] = ACTION [PREACTION]>

       Every element is self-evaluating (atoms and lists of atoms), so the
       already-evaluated arguments a SUBR receives are exactly the source
       syntax — which is why this can be decomposed here rather than
       needing an FSUBR. A preposition is any atom before an OBJECT that
       isn't OBJECT or "="; it belongs to the object that follows it. *)
    IF n < 3 THEN RETURN Err("SYNTAX: expected at least 3 args") END;
    IF args[0].kind # ZilObj.KAtom THEN RETURN Err("SYNTAX: expected a verb atom") END;
    synKind := ZilModel.AddSyntax(BuildConsChain(ZilObj.KList, args, n));
    IF synKind < 0 THEN RETURN Err("SYNTAX: too many syntax lines") END;

    Strings.Copy(args[0].atomText, ZilModel.syntaxes[synKind].verb);
    len := ZilModel.AddVocab(args[0].atomText, ZilModel.PsVerb);
    (* the default scope byte, which AddSyntax cannot know: it depends on
       whether the library redefined the flags with NEW-SFLAGS *)
    ZilModel.syntaxes[synKind].opts1 := ScopeFlagsParse(NIL);
    ZilModel.syntaxes[synKind].opts2 := ZilModel.syntaxes[synKind].opts1;

    s[0] := 0X;          (* the preposition awaiting its object *)
    i := 1;
    WHILE (i < n) & ~((args[i].kind = ZilObj.KAtom) & (args[i].atomText = "=")) DO
      IF (args[i].kind = ZilObj.KAtom) & (args[i].atomText = "OBJECT") THEN
        INC(ZilModel.syntaxes[synKind].numObjects);
        IF ZilModel.syntaxes[synKind].numObjects = 1 THEN
          Strings.Copy(s, ZilModel.syntaxes[synKind].prep1)
        ELSE
          Strings.Copy(s, ZilModel.syntaxes[synKind].prep2)
        END;
        s[0] := 0X

      ELSIF args[i].kind = ZilObj.KList THEN
        IF ZilObj.IsAtomNamed(args[i].first, "FIND") THEN
          IF (args[i].rest # NIL) & (args[i].rest.first # NIL)
             & (args[i].rest.first.kind = ZilObj.KAtom) THEN
            IF ZilModel.syntaxes[synKind].numObjects <= 1 THEN
              Strings.Copy(args[i].rest.first.atomText, ZilModel.syntaxes[synKind].find1)
            ELSE
              Strings.Copy(args[i].rest.first.atomText, ZilModel.syntaxes[synKind].find2)
            END
          END
        ELSE
          sum := ScopeFlagsParse(args[i]);
          IF ZilModel.syntaxes[synKind].numObjects <= 1 THEN
            ZilModel.syntaxes[synKind].opts1 := sum
          ELSE
            ZilModel.syntaxes[synKind].opts2 := sum
          END
        END

      ELSIF args[i].kind = ZilObj.KAtom THEN
        (* a preposition, belonging to the object that follows it *)
        Strings.Copy(args[i].atomText, s);
        len := ZilModel.AddVocab(s, ZilModel.PsPreposition)
      END;
      INC(i)
    END;

    (* past the "=": the action, then an optional pre-action, then an optional
       explicit ACTION NAME. All three are in the original's Syntax.Parse. *)
    INC(i);
    IF (i < n) & (args[i].kind = ZilObj.KAtom) THEN
      Strings.Copy(args[i].atomText, ZilModel.syntaxes[synKind].action);
      INC(i);
      IF (i < n) & (args[i].kind = ZilObj.KAtom) THEN
        Strings.Copy(args[i].atomText, ZilModel.syntaxes[synKind].preAction);
        INC(i);
        IF (i < n) & (args[i].kind = ZilObj.KAtom) THEN
          Strings.Copy(args[i].atomText, ZilModel.syntaxes[synKind].actionName)
        END
      END
    ELSE
      RETURN Err("SYNTAX: expected an action routine name after '='")
    END;
    RETURN MkVal(args[0])

  ELSIF (name = "SYNONYM") OR (name = "VERB-SYNONYM") OR (name = "PREP-SYNONYM")
        OR (name = "ADJ-SYNONYM") OR (name = "DIR-SYNONYM") THEN
    IF n < 2 THEN RETURN Err("SYNONYM: expected an original atom and at least one synonym") END;
    IF name = "SYNONYM" THEN synKind := ZilModel.SynPlain
    ELSIF name = "VERB-SYNONYM" THEN synKind := ZilModel.SynVerb
    ELSIF name = "PREP-SYNONYM" THEN synKind := ZilModel.SynPrep
    ELSIF name = "ADJ-SYNONYM" THEN synKind := ZilModel.SynAdj
    ELSE synKind := ZilModel.SynDir END;
    FOR i := 1 TO n - 1 DO ZilModel.AddSynonym(synKind, args[0], args[i]) END;
    RETURN MkVal(args[0])

  ELSIF name = "BIT-SYNONYM" THEN
    (* <BIT-SYNONYM FIRST ALIAS...>: each ALIAS becomes another name for the
       object flag FIRST and shares its bit. V3 has only 32 flags, so this is
       how a game gives one bit several readable names (advent's SACREDBIT and
       TREASUREBIT). Returns FIRST, as the original does. *)
    IF n < 2 THEN RETURN Err("BIT-SYNONYM: expected a flag and at least one alias") END;
    IF args[0].kind # ZilObj.KAtom THEN
      RETURN Err("BIT-SYNONYM: the first argument must be an ATOM")
    END;
    FOR i := 1 TO n - 1 DO
      IF args[i].kind # ZilObj.KAtom THEN
        RETURN Err("BIT-SYNONYM: every alias must be an ATOM")
      END;
      IF ~ZilModel.AddBitSynonym(args[i].atomText, args[0].atomText) THEN
        RETURN Err("BIT-SYNONYM: too many flag synonyms")
      END
    END;
    RETURN MkVal(args[0])

  ELSIF name = "DIRECTIONS" THEN
    ZilModel.ClearDirections;
    FOR i := 0 TO n - 1 DO
      ZilModel.AddDirection(args[i]);
      IF args[i].kind = ZilObj.KAtom THEN
        len := ZilModel.AddVocab(args[i].atomText, ZilModel.PsDirection)
      END
    END;
    RETURN MkVal(TrueVal())

  ELSIF name = "BUZZ" THEN
    FOR i := 0 TO n - 1 DO
      ZilModel.AddBuzzword(args[i]);
      IF args[i].kind = ZilObj.KAtom THEN
        len := ZilModel.AddVocab(args[i].atomText, ZilModel.PsBuzzword)
      END
    END;
    RETURN MkVal(TrueVal())

  ELSIF name = "VERSION" THEN
    (* <VERSION ZIP> / <VERSION XZIP> / <VERSION 5>, optionally followed by
       the atom TIME (V3's alternative "time" status line). Sets the target
       Z-machine version for the whole program — the original's own VERSION
       subr, which likewise just calls ctx.SetZVersion and returns the
       number. A plain evaluated-args SUBR there and here: a bare atom
       self-evaluates, so the version name arrives intact. *)
    IF n < 1 THEN RETURN Err("VERSION: expected a version specifier") END;
    i := ParseZVersion(args[0]);
    IF i = 0 THEN
      RETURN ErrAtom("VERSION: unrecognized version specifier (want ZIP/EZIP/XZIP/YZIP or 3-8):", args[0])
    END;
    IF i = 1000 THEN
      RETURN Err("VERSION: GLULX is not a supported target for this port")
    END;
    ZilModel.zversion := i;
    (* the original's SetZVersion updates PLUS-MODE alongside the version,
       so source can test <COND (,PLUS-MODE ...)> for "V4 or later" *)
    ind := ZilObj.Intern("PLUS-MODE"); ind.globalVal := BoolVal(i > 3);
    IF (n >= 2) & (args[1].kind = ZilObj.KAtom) & (args[1].atomText = "TIME") THEN
      IF i # 3 THEN RETURN Err("VERSION: TIME is only meaningful in version 3") END;
      ZilModel.timeStatusLine := TRUE
    END;
    RETURN MkVal(ZilObj.NewFix(i))

  ELSIF name = "CHECK-VERSION?" THEN
    IF n < 1 THEN RETURN Err("CHECK-VERSION?: expected a version specifier") END;
    RETURN MkVal(BoolVal(ParseZVersion(args[0]) = ZilModel.zversion))

  ELSIF name = "FILE-FLAGS" THEN
    (* Per-file compiler flags (Subrs.Meta.cs): CLEAN-STACK?, MDL-ZIL?,
       SENTENCE-ENDS?, KEEP-ROUTINES?, UNUSED-ROUTINES? and the ignored
       ZAP-TO-SOURCE-DIRECTORY?. None of them changes anything this port
       does — the only one with downstream meaning for code generation is
       CLEAN-STACK?, and ZilCompile already pops every discarded call
       result unconditionally — so this validates the flag names (so a
       typo is still caught, as in the original) and otherwise does
       nothing. *)
    FOR i := 0 TO n - 1 DO
      IF args[i].kind # ZilObj.KAtom THEN
        RETURN Err("FILE-FLAGS: expected flag atoms")
      END;
      IF (args[i].atomText # "CLEAN-STACK?") & (args[i].atomText # "MDL-ZIL?")
         & (args[i].atomText # "ZAP-TO-SOURCE-DIRECTORY?") & (args[i].atomText # "SENTENCE-ENDS?")
         & (args[i].atomText # "KEEP-ROUTINES?") & (args[i].atomText # "UNUSED-ROUTINES?") THEN
        RETURN ErrAtom("FILE-FLAGS: unrecognized file flag:", args[i])
      END
    END;
    RETURN MkVal(TrueVal())

  ELSIF name = "ZIP-OPTIONS" THEN
    (* <ZIP-OPTIONS opt...>: each opt is one of COLOR/MOUSE/UNDO/DISPLAY/
       SOUND/MENU/BIG. Ported from Subrs.ZModel.cs's ZIP_OPTIONS: for each
       recognized option (BIG is accepted and silently ignored - the
       original's own `case StdAtom.BIG: continue`), defines a
       COMPILATION-FLAG under the option's OWN name (so <IFFLAG (UNDO ...)>
       works) and also sets a derived global to TRUE (USE-UNDO?, USE-COLOR?,
       USE-MOUSE?, DISPLAY-OPS?, USE-SOUND?, USE-MENUS? - the original's own
       StdAtom spellings), which is the flag library source actually tests
       via <GASSIGNED? USE-UNDO?> and friends. *)
    FOR i := 0 TO n - 1 DO
      IF args[i].kind # ZilObj.KAtom THEN RETURN Err("ZIP-OPTIONS: expected option atoms") END;
      Strings.Copy(args[i].atomText, s);
      IF s = "BIG" THEN
        (* ignored *)
      ELSE
        IF s = "COLOR" THEN Strings.Copy("USE-COLOR?", opText)
        ELSIF s = "MOUSE" THEN Strings.Copy("USE-MOUSE?", opText)
        ELSIF s = "UNDO" THEN Strings.Copy("USE-UNDO?", opText)
        ELSIF s = "DISPLAY" THEN Strings.Copy("DISPLAY-OPS?", opText)
        ELSIF s = "SOUND" THEN Strings.Copy("USE-SOUND?", opText)
        ELSIF s = "MENU" THEN Strings.Copy("USE-MENUS?", opText)
        ELSE RETURN ErrAtom("ZIP-OPTIONS: unrecognized ZIP option:", args[i])
        END;
        DefineFlag(s, TrueVal(), TRUE);
        ind := ZilObj.Intern(opText); ind.globalVal := TrueVal()
      END
    END;
    RETURN MkVal(TrueVal())

  ELSIF ((name[0] = "0") OR (name[0] = "1")) & (name[1] = "?") & (name[2] = 0X) THEN
    (* MDL's <0? x> and <1? x>: true only for that exact FIX, false for
       anything else including a non-FIX. Compile-time predicates, distinct
       from the compiler's own 0?/1? on Z-machine values.
       NOTE: compared character by character. A one-character double-quoted
       literal is a CHAR in this dialect, so `name = "0?"` would be a string
       compare against a two-char literal - fine - but IsOp is NOT usable
       here: it requires a one-character name and so never matches "0?". *)
    IF n < 1 THEN RETURN Err("0?/1?: expected a value") END;
    IF (args[0] # NIL) & (args[0].kind = ZilObj.KFix) THEN
      IF name[0] = "0" THEN RETURN MkVal(BoolVal(args[0].fixVal = 0)) END;
      RETURN MkVal(BoolVal(args[0].fixVal = 1))
    END;
    RETURN MkVal(FalseVal())

  ELSIF name = "UNPARSE" THEN
    (* <UNPARSE value> is a round-trippable printed form of the value — the
       inverse of PARSE, and what real source uses to build a name out of a
       number: advent writes <PARSE <STRING "ALIKE-MAZE-" <UNPARSE .DEST>>>.
       The original's optional radix argument is not supported, as it is not
       there either. *)
    IF n < 1 THEN RETURN Err("UNPARSE: expected a value") END;
    ZilObj.PrintTo(args[0], s);
    RETURN MkVal(ZilObj.NewString(s))

  ELSIF name = "PUT" THEN
    (* <PUT struc n value>: MDL's structure setter, 1-based, returning the
       structure. Needed at COMPILE time because a DEFSTRUCT accessor used as
       a setter expands straight to it — zillib's <ACH-REPEATABLE? .A T>
       becomes <PUT .A 4 T> and runs while the achievements are being
       defined. *)
    IF n < 3 THEN RETURN Err("PUT: expected a structure, an index and a value") END;
    IF (args[1] = NIL) OR (args[1].kind # ZilObj.KFix) THEN
      RETURN Err("PUT: the index must be a FIX")
    END;
    IF ~StructPut(args[0], args[1].fixVal, args[2]) THEN
      RETURN Err("PUT: writing past the end of the structure")
    END;
    RETURN MkVal(args[0])

  ELSIF (name = "ZGET") OR (name = "GETB") THEN
    (* the width-aware TABLE readers a DEFSTRUCT over a TABLE generates.
       ZGET counts words from the table's start, GETB counts bytes. *)
    IF (n < 2) OR (args[0] = NIL) OR (args[0].kind # ZilObj.KTable)
       OR (args[1] = NIL) OR (args[1].kind # ZilObj.KFix) THEN
      RETURN Err("ZGET/GETB: expected a TABLE and a FIX index")
    END;
    IF name = "ZGET" THEN ind := TableGetWord(args[0], args[1].fixVal)
    ELSE ind := TableGetByte(args[0], args[1].fixVal) END;
    IF ind = NIL THEN RETURN Err("ZGET/GETB: index does not line up with an element") END;
    RETURN MkVal(ind)

  ELSIF (name = "ZPUT") OR (name = "PUTB") THEN
    IF (n < 3) OR (args[0] = NIL) OR (args[0].kind # ZilObj.KTable)
       OR (args[1] = NIL) OR (args[1].kind # ZilObj.KFix) THEN
      RETURN Err("ZPUT/PUTB: expected a TABLE, a FIX index and a value")
    END;
    IF name = "ZPUT" THEN len := 0;
      IF ~TablePutWord(args[0], args[1].fixVal, args[2]) THEN len := 1 END
    ELSE len := 0;
      IF ~TablePutByte(args[0], args[1].fixVal, args[2]) THEN len := 1 END
    END;
    IF len # 0 THEN RETURN Err("ZPUT/PUTB: index does not line up with an element") END;
    RETURN MkVal(args[0])

  ELSIF (name = "NTH") OR (name = "GET-ELEMENT") THEN
    (* <NTH struct n>, 1-based. Also what <n struct> means when a FIX is
       applied as a function — see EvalImpl's head dispatch. *)
    IF (n < 2) OR (args[1].kind # ZilObj.KFix) THEN
      RETURN Err("NTH: expected a structure and a FIX index")
    END;
    ind := StructNth(args[0], args[1].fixVal);
    IF ind = NIL THEN RETURN Err("NTH: index out of range") END;
    RETURN MkVal(ind)

  ELSIF name = "REST" THEN
    IF n < 1 THEN RETURN Err("REST: expected a structure") END;
    IF n >= 2 THEN
      IF args[1].kind # ZilObj.KFix THEN RETURN Err("REST: count must be a FIX") END;
      RETURN MkVal(StructRest(args[0], args[1].fixVal))
    END;
    RETURN MkVal(StructRest(args[0], 1))

  ELSIF name = "PUTREST" THEN
    (* <PUTREST list newrest>: destructively replaces list's OWN tail
       pointer (its first cons cell's "rest") with newrest, and returns the
       (mutated) list. Ported from Subrs.Structures.cs's PUTREST: a bare
       LIST/FORM newrest becomes the tail directly; anything else is wrapped
       as a fresh one-element list first, matching the original's `list.Rest
       = newRest as ZilList ?? new ZilList(newRest)`. zork1's own
       gmacros.zil MULTIFROB (the compile-time helper behind VERB?/PRSO?/
       PRSI?/ROOM?) is the reason this port needs it: it grows a FORM one
       argument at a time by PUTREST-ing a fresh singleton list onto the
       tail it is walking, exactly the "build by mutation, walk a saved tail
       pointer" idiom PUTREST exists for. *)
    IF n < 2 THEN RETURN Err("PUTREST: expected a structure and a new rest") END;
    IF (args[0].kind # ZilObj.KList) & (args[0].kind # ZilObj.KForm) THEN
      RETURN Err("PUTREST: expected a LIST or FORM")
    END;
    IF args[0].first = NIL THEN
      RETURN Err("PUTREST: writing past end of structure")
    END;
    IF (args[1].kind = ZilObj.KList) OR (args[1].kind = ZilObj.KForm) THEN
      args[0].rest := args[1]
    ELSE
      args[0].rest := ZilObj.Cons(ZilObj.KList, args[1], NIL)
    END;
    RETURN MkVal(args[0])

  ELSIF name = "EMPTY?" THEN
    IF n < 1 THEN RETURN Err("EMPTY?: expected a structure") END;
    RETURN MkVal(BoolVal(StructLength(args[0]) = 0))

  ELSIF name = "LENGTH" THEN
    IF n < 1 THEN RETURN Err("LENGTH: expected a structure") END;
    RETURN MkVal(ZilObj.NewFix(StructLength(args[0])))

  ELSIF (name = "TYPE") OR (name = "PRIMTYPE") THEN
    IF n < 1 THEN RETURN Err("TYPE: expected a value") END;
    TypeName(args[0], s);
    RETURN MkVal(ZilObj.Intern(s))

  ELSIF name = "TYPE?" THEN
    (* <TYPE? value TYPE...> is true when the value has ANY of the named
       types, and returns that type atom rather than plain T — real source
       relies on the atom (e.g. <COND (<TYPE? .X ATOM LIST> ...)>). *)
    IF n < 2 THEN RETURN Err("TYPE?: expected a value and at least one type") END;
    TypeName(args[0], s);
    FOR i := 1 TO n - 1 DO
      IF (args[i].kind = ZilObj.KAtom) & (args[i].atomText = s) THEN RETURN MkVal(args[i]) END;
      IF (args[i].kind = ZilObj.KAtom)
         & ((args[i].atomText = "LVAL") OR (args[i].atomText = "GVAL"))
         & (ValFormAtom(args[0], args[i].atomText) # NIL) THEN
        RETURN MkVal(args[i])
      END
    END;
    RETURN MkVal(FalseVal())

  ELSIF name = "STRUCTURED?" THEN
    RETURN MkVal(BoolVal((n >= 1) & IsStructured(args[0])))

  ELSIF name = "APPLICABLE?" THEN
    RETURN MkVal(BoolVal((n >= 1) & (args[0] # NIL)
                 & ((args[0].kind = ZilObj.KSubr) OR (args[0].kind = ZilObj.KFSubr)
                    OR (args[0].kind = ZilObj.KFunction) OR (args[0].kind = ZilObj.KMacro))))

  ELSIF (name = "ORB") OR (name = "ANDB") OR (name = "XORB") THEN
    (* MDL's bitwise operators, as distinct from the logical OR/AND. Real
       source uses them at COMPILE time to fold flag masks — zillib's
       parser builds search-scope bytes this way — so they are needed here
       and not only as the BOR/BAND instructions the compiler emits. *)
    IF n < 1 THEN RETURN Err("ORB/ANDB/XORB: expected at least one FIX") END;
    FOR i := 0 TO n - 1 DO
      IF args[i].kind # ZilObj.KFix THEN RETURN Err("ORB/ANDB/XORB: expected FIX args") END
    END;
    sum := args[0].fixVal;
    FOR i := 1 TO n - 1 DO
      len := 0; synKind := 1;
      WHILE synKind # 0 DO
        IF ((sum DIV synKind) MOD 2 = 1) OR ((args[i].fixVal DIV synKind) MOD 2 = 1) THEN
          IF name = "ORB" THEN len := len + synKind END
        END;
        IF ((sum DIV synKind) MOD 2 = 1) & ((args[i].fixVal DIV synKind) MOD 2 = 1) THEN
          IF name = "ANDB" THEN len := len + synKind END
        END;
        IF ((sum DIV synKind) MOD 2) # ((args[i].fixVal DIV synKind) MOD 2) THEN
          IF name = "XORB" THEN len := len + synKind END
        END;
        IF synKind >= 16384 THEN synKind := 0 ELSE synKind := synKind * 2 END
      END;
      sum := len
    END;
    RETURN MkVal(ZilObj.NewFix(sum))

  ELSIF (name = "MEMQ") OR (name = "MEMBER") THEN
    (* <MEMQ x struct> finds x among the elements and returns the REST of
       the structure starting there (so it doubles as a predicate, being
       FALSE when absent). MEMQ compares by identity/value, MEMBER
       structurally; this port's ValuesEqual is the same test for both,
       since the values real source searches for are atoms and FIXes. *)
    IF n < 2 THEN RETURN Err("MEMQ/MEMBER: expected a value and a structure") END;
    len := StructLength(args[1]);
    FOR i := 1 TO len DO
      IF ValuesEqual(StructNth(args[1], i), args[0]) THEN
        RETURN MkVal(StructRest(args[1], i - 1))
      END
    END;
    RETURN MkVal(FalseVal())

  ELSIF name = "ASCII" THEN
    (* <ASCII n> is the CHARACTER with that code, and <ASCII !\c> is that
       character's code — MDL's one primitive converts both ways depending
       on what it is handed. *)
    IF n < 1 THEN RETURN Err("ASCII: expected a FIX or CHARACTER") END;
    IF args[0].kind = ZilObj.KFix THEN RETURN MkVal(ZilObj.NewChar(args[0].fixVal)) END;
    IF args[0].kind = ZilObj.KChar THEN RETURN MkVal(ZilObj.NewFix(args[0].charVal)) END;
    RETURN Err("ASCII: expected a FIX or CHARACTER")

  ELSIF (name = "MIN") OR (name = "MAX") THEN
    IF n < 1 THEN RETURN Err("MIN/MAX: expected at least one FIX") END;
    IF args[0].kind # ZilObj.KFix THEN RETURN Err("MIN/MAX: expected FIX args") END;
    sum := args[0].fixVal;
    FOR i := 1 TO n - 1 DO
      IF args[i].kind # ZilObj.KFix THEN RETURN Err("MIN/MAX: expected FIX args") END;
      IF name = "MIN" THEN
        IF args[i].fixVal < sum THEN sum := args[i].fixVal END
      ELSE
        IF args[i].fixVal > sum THEN sum := args[i].fixVal END
      END
    END;
    RETURN MkVal(ZilObj.NewFix(sum))

  ELSIF (name = "ABS") THEN
    IF (n < 1) OR (args[0].kind # ZilObj.KFix) THEN RETURN Err("ABS: expected a FIX") END;
    IF args[0].fixVal < 0 THEN RETURN MkVal(ZilObj.NewFix(-args[0].fixVal)) END;
    RETURN MkVal(args[0])

  ELSIF (name = "GBOUND?") OR (name = "BOUND?") THEN
    (* "is this atom's global (resp. local) value assigned" — the same
       question GASSIGNED?/ASSIGNED? answer, under the names MDL code tends
       to use when asking about a binding rather than a value. *)
    IF (n < 1) OR (args[0].kind # ZilObj.KAtom) THEN RETURN MkVal(FalseVal()) END;
    IF name = "GBOUND?" THEN RETURN MkVal(BoolVal(args[0].globalVal # NIL)) END;
    RETURN MkVal(BoolVal(args[0].localVal # NIL))

  ELSIF name = "SET-SOURCE-INFO" THEN
    (* Copies source-line information from one value to another and returns
       the first. This port tracks no source lines at all (diagnostics name
       the file, not the line), so there is nothing to copy — returning the
       value unchanged is the whole of its observable behaviour here. *)
    IF n < 1 THEN RETURN Err("SET-SOURCE-INFO: expected a value") END;
    RETURN MkVal(args[0])

  ELSIF name = "OFFSET" THEN
    (* <OFFSET n structure-decl [value-decl]>: a typed pointer combining an
       index with the DECLs a structure and its element at that index must
       match - Subrs.Structures.cs's own OFFSET. This port has no DECL
       checking (skipped everywhere, deliberately), and the real compiler's
       own NTH/PUT/GET/etc. always reduce an offset argument straight back
       to its plain integer index before doing anything with it - so an
       OFFSET value and the bare FIX index it wraps are interchangeable
       everywhere real source can use one, and returning the index itself
       is the whole of OFFSET's needed behavior here. zillib's status.zil
       (cloak_plus's fancier status line) builds several of these:
       `<SETG RSEC-RTN <OFFSET 1 RSEC ATOM>>`. *)
    IF (n < 2) OR (args[0].kind # ZilObj.KFix) THEN
      RETURN Err("OFFSET: expected an index FIX and a structure DECL")
    END;
    RETURN MkVal(args[0])

  ELSIF name = "NEWTYPE" THEN
    (* <NEWTYPE NAME PRIMTYPE [decl]>: registers NAME as a new type whose
       underlying representation is PRIMTYPE. This port has no type
       registry at all - TYPE?/TYPE/PRIMTYPE always report a value's
       actual PRIMITIVE kind (TypeName), never a user-registered name, and
       CHTYPE to anything but a structural LIST/FORM/VECTOR conversion
       already just returns the value unretyped (see CHTYPE's own comment)
       - so there is nothing for NEWTYPE to register that would ever be
       consulted. Returns the name atom, matching the original, and
       otherwise does nothing. *)
    IF (n < 2) OR (args[0].kind # ZilObj.KAtom) OR (args[1].kind # ZilObj.KAtom) THEN
      RETURN Err("NEWTYPE: expected a name ATOM and a primtype ATOM")
    END;
    RETURN MkVal(args[0])

  ELSIF name = "CHTYPE" THEN
    (* <CHTYPE value TYPE> reinterprets a value as another type. This port
       has no type system, so the only CHTYPEs that can mean anything are
       the STRUCTURAL ones — between the cons-chain kinds (LIST/FORM) and
       VECTOR — and those really are used: quasiquote's own implementation
       does <CHTYPE .X FORM> to turn a captured list into a callable form.
       Retyping to anything else (a DEFSTRUCT name, BYTE, ADECL) returns the
       value unchanged, which is the right answer here precisely because
       nothing downstream inspects a type tag. *)
    IF (n < 2) OR (args[1].kind # ZilObj.KAtom) THEN
      RETURN Err("CHTYPE: expected a value and a type ATOM")
    END;
    Strings.Copy(args[1].atomText, s);
    IF (s = "LVAL") OR (s = "GVAL") THEN
      (* <CHTYPE FOO LVAL> is the FORM .FOO, not a retagged atom *)
      IF ValFormAtom(args[0], s) # NIL THEN RETURN MkVal(args[0]) END;
      IF (args[0] = NIL) OR (args[0].kind # ZilObj.KAtom) THEN
        RETURN Err("CHTYPE: converting to LVAL or GVAL requires an ATOM")
      END;
      ind := ZilObj.Cons(ZilObj.KForm, args[0], NIL);
      RETURN MkVal(ZilObj.Cons(ZilObj.KForm, ZilObj.Intern(s), ind))
    END;
    IF s = "ATOM" THEN
      (* and <CHTYPE .FOO ATOM> is FOO again. Anything else already is an
         ATOM or has no ATOM to give, and falls through to the catch-all
         below that returns the value unchanged. *)
      ind := ValFormAtom(args[0], "LVAL");
      IF ind = NIL THEN ind := ValFormAtom(args[0], "GVAL") END;
      IF ind # NIL THEN RETURN MkVal(ind) END
    END;
    IF (s = "LIST") OR (s = "FORM") OR (s = "SPLICE") THEN
      IF s = "LIST" THEN i := ZilObj.KList
      ELSIF s = "FORM" THEN i := ZilObj.KForm
      ELSE i := ZilObj.KSplice END;
      IF (args[0] # NIL) & (args[0].kind = i) THEN RETURN MkVal(args[0]) END;
      IF ~IsStructured(args[0]) THEN RETURN Err("CHTYPE: expected a structured value") END;
      len := StructLength(args[0]);
      resultHead := NIL; resultTail := NIL;
      FOR sum := 1 TO len DO
        ind := ZilObj.Cons(i, StructNth(args[0], sum), NIL);
        IF resultHead = NIL THEN resultHead := ind ELSE resultTail.rest := ind END;
        resultTail := ind
      END;
      IF resultHead = NIL THEN RETURN MkVal(ZilObj.NewEmpty(i)) END;
      RETURN MkVal(resultHead)
    ELSIF s = "VECTOR" THEN
      IF (args[0] # NIL) & (args[0].kind = ZilObj.KVector) THEN RETURN MkVal(args[0]) END;
      IF ~IsStructured(args[0]) THEN RETURN Err("CHTYPE: expected a structured value") END;
      len := StructLength(args[0]);
      ind := ZilObj.NewVectorN(len);
      FOR sum := 1 TO len DO ind.vecItems[sum - 1] := StructNth(args[0], sum) END;
      RETURN MkVal(ind)
    ELSIF s = "FALSE" THEN
      (* Unlike a DEFSTRUCT name or BYTE/ADECL, FALSE is a real type this
         port already has its own genuine representation for (KFalse), and
         retyping to it is NOT a no-op: `#FALSE (...)` reads as a plain
         empty LIST via the generic "CHTYPE just passes the value through
         unretyped" rule above, but COND treats a clause that is truly the
         FALSE value as one to silently SKIP (real zilf's own CompileCOND:
         `case ZilFalse: continue;`), and a KList doesn't get that
         treatment. zillib's own meta.zil (JIGS-UP's RESTART/RESTORE/QUIT/
         UNDO prompt) writes exactly `#FALSE ()` as a COND clause, almost
         certainly a %eval placeholder for "no clause here" under some
         flag combination. *)
      RETURN MkVal(ZilObj.NewEmpty(ZilObj.KFalse))
    END;
    RETURN MkVal(args[0])

  ELSIF (name = "BYTE") OR (name = "WORD") THEN
    (* <BYTE n> inside a TABLE marks that element as one byte wide rather
       than a word (and <WORD n> says so explicitly). The original does it
       by CHTYPEing the value to the BYTE type; this port has no type
       system, so the width is recorded as a property on the value itself,
       which is where ZilCompile's table emitter looks for it. *)
    IF (n < 1) OR (args[0].kind # ZilObj.KFix) THEN
      RETURN Err("BYTE/WORD: expected a FIX")
    END;
    ind := ZilObj.NewFix(args[0].fixVal);
    ZilObj.PutProp(ind, ZilObj.Intern("WIDTH "), ZilObj.Intern(name));
    RETURN MkVal(ind)

  ELSIF name = "STRING" THEN
    (* <STRING a b ...> concatenates its arguments into one STRING: a
       STRING contributes its text and a CHARACTER its character, which is
       all real source uses it for (e.g. verbs.zil's
       <STRING " / " ,ZIL-VERSION>). *)
    s[0] := 0X;
    FOR i := 0 TO n - 1 DO
      IF args[i].kind = ZilObj.KString THEN Strings.Append(args[i].strBuf^, s)
      ELSIF args[i].kind = ZilObj.KChar THEN
        msgBuf[0] := CHR(args[i].charVal); msgBuf[1] := 0X;
        Strings.Append(msgBuf, s)
      ELSE
        RETURN Err("STRING: arguments must be STRINGs or CHARACTERs")
      END
    END;
    RETURN MkVal(ZilObj.NewString(s))

  ELSIF name = "SORT" THEN
    (* <SORT predicate vector [record-size [key-offset]]>. The original also
       accepts further vectors to be rearranged in step with the first; that
       is left out, since nothing in the corpus this port targets uses it and
       silently ignoring the extra arguments would corrupt them. *)
    IF (n < 2) OR (args[1] = NIL) OR (args[1].kind # ZilObj.KVector) THEN
      RETURN Err("SORT: expected a predicate and a VECTOR")
    END;
    len := 1; sum := 0;
    IF (n >= 3) & (args[2] # NIL) & (args[2].kind = ZilObj.KFix) THEN len := args[2].fixVal END;
    IF (n >= 4) & (args[3] # NIL) & (args[3].kind = ZilObj.KFix) THEN sum := args[3].fixVal END;
    IF (len < 1) OR (sum < 0) OR (sum >= len) THEN
      RETURN Err("SORT: expected 0 <= key offset < record size")
    END;
    IF args[1].vecLen MOD len # 0 THEN
      RETURN Err("SORT: vector length must be a multiple of the record size")
    END;
    IF n > 4 THEN
      RETURN Err("SORT: sorting several vectors together is not supported")
    END;
    IF ~SortVector(args[0], args[1], len, sum) THEN
      RETURN Err("SORT: could not compare two keys")
    END;
    RETURN MkVal(args[1])

  ELSIF name = "VECTOR" THEN
    ind := ZilObj.NewVectorN(n);
    FOR i := 0 TO n - 1 DO ind.vecItems[i] := args[i] END;
    RETURN MkVal(ind)

  ELSIF name = "MOBLIST" THEN
    (* <MOBLIST NAME> yields the oblist of that name, creating it the first
       time — "make oblist". The argument is an atom in every real use. *)
    IF n < 1 THEN RETURN Err("MOBLIST: expected a name") END;
    IF args[0].kind = ZilObj.KOblist THEN RETURN MkVal(args[0]) END;
    IF args[0].kind = ZilObj.KAtom THEN Strings.Copy(args[0].atomText, s)
    ELSIF args[0].kind = ZilObj.KString THEN Strings.Copy(args[0].strBuf^, s)
    ELSE RETURN Err("MOBLIST: expected an ATOM or STRING name")
    END;
    RETURN MkVal(FindOrMakeOblist(s))

  ELSIF name = "ROOT" THEN
    RETURN MkVal(FindOrMakeOblist("ROOT"))

  ELSIF name = "OBLIST?" THEN
    IF (n < 1) OR (args[0].kind # ZilObj.KAtom) THEN RETURN MkVal(FalseVal()) END;
    ind := ZilObj.GetProp(args[0], OblistMarker());
    IF ind = NIL THEN RETURN MkVal(FalseVal()) END;
    RETURN MkVal(ind)

  ELSIF (name = "LOOKUP") OR (name = "INSERT") THEN
    (* <LOOKUP "NAME" oblist> finds an existing entry and is FALSE when
       there is none; <INSERT "NAME" oblist> creates one. The pair is how
       real source interns a name exactly once — <OR <LOOKUP ...>
       <INSERT ...>> — so LOOKUP really must distinguish "absent" from
       "an atom of that name exists somewhere else". *)
    IF n < 2 THEN RETURN Err("LOOKUP/INSERT: expected a name and an OBLIST") END;
    IF args[0].kind = ZilObj.KString THEN Strings.Copy(args[0].strBuf^, s)
    ELSIF args[0].kind = ZilObj.KAtom THEN Strings.Copy(args[0].atomText, s)
    ELSE RETURN Err("LOOKUP/INSERT: the name must be a STRING or ATOM")
    END;
    IF args[1].kind # ZilObj.KOblist THEN
      RETURN Err("LOOKUP/INSERT: the second argument must be an OBLIST")
    END;
    QualifiedName(s, args[1], msgBuf);
    ind := ZilObj.Intern(msgBuf);
    IF name = "LOOKUP" THEN
      IF ZilObj.GetProp(ind, OblistMarker()) = NIL THEN RETURN MkVal(FalseVal()) END;
      RETURN MkVal(ind)
    END;
    ZilObj.PutProp(ind, OblistMarker(), args[1]);
    RETURN MkVal(ind)

  ELSIF (name = "SPNAME") OR (name = "PNAME") THEN
    IF (n < 1) OR (args[0].kind # ZilObj.KAtom) THEN
      RETURN Err("SPNAME: expected an ATOM")
    END;
    RETURN MkVal(ZilObj.NewString(args[0].atomText))

  ELSIF name = "PARSE" THEN
    (* <PARSE "TEXT"> yields the atom of that name — the inverse of SPNAME,
       and the only part of the original's reader-level PARSE that real
       source uses at compile time. *)
    IF (n < 1) OR (args[0].kind # ZilObj.KString) THEN
      RETURN Err("PARSE: expected a STRING")
    END;
    RETURN MkVal(ZilObj.Intern(args[0].strBuf^))

  ELSIF name = "ERROR" THEN
    (* Raises an interpreter error naming the arguments, which is all this
       port needs from it — the original's condition system (retry, catch)
       has no equivalent here. *)
    Strings.Copy("ERROR:", s);
    FOR i := 0 TO n - 1 DO
      ZilObj.PrintTo(args[i], msgBuf);
      Strings.Append(" ", s); Strings.Append(msgBuf, s)
    END;
    RETURN Err(s)

  ELSIF (name = "COMPILATION-FLAG") OR (name = "COMPILATION-FLAG-DEFAULT") THEN
    (* <COMPILATION-FLAG NAME [value]> defines (and redefines) a flag,
       defaulting to T; <COMPILATION-FLAG-DEFAULT NAME value> defines it
       only if it isn't defined already, which is how a game states its own
       defaults without overriding a value set on the command line. Both
       take the name as an ATOM or a STRING (the original's
       AtomParams.StringOrAtom) and return it. *)
    IF n < 1 THEN RETURN Err("COMPILATION-FLAG: expected a name") END;
    IF args[0].kind = ZilObj.KAtom THEN Strings.Copy(args[0].atomText, s)
    ELSIF args[0].kind = ZilObj.KString THEN Strings.Copy(args[0].strBuf^, s)
    ELSE RETURN Err("COMPILATION-FLAG: name must be an ATOM or a STRING")
    END;
    IF name = "COMPILATION-FLAG" THEN
      IF n >= 2 THEN DefineFlag(s, args[1], TRUE) ELSE DefineFlag(s, TrueVal(), TRUE) END
    ELSE
      IF n < 2 THEN RETURN Err("COMPILATION-FLAG-DEFAULT: expected a name and a value") END;
      DefineFlag(s, args[1], FALSE)
    END;
    RETURN MkVal(ZilObj.Intern(s))

  ELSIF name = "COMPILATION-FLAG-VALUE" THEN
    IF n < 1 THEN RETURN Err("COMPILATION-FLAG-VALUE: expected a name") END;
    IF args[0].kind = ZilObj.KAtom THEN Strings.Copy(args[0].atomText, s)
    ELSIF args[0].kind = ZilObj.KString THEN Strings.Copy(args[0].strBuf^, s)
    ELSE RETURN Err("COMPILATION-FLAG-VALUE: name must be an ATOM or a STRING")
    END;
    ind := FlagValue(s);
    IF ind = NIL THEN RETURN MkVal(FalseVal()) END;
    RETURN MkVal(ind)

  ELSIF (name = "GC-MON") OR (name = "BLOAT") OR (name = "ZSTR-ON")
        OR (name = "ZSTR-OFF") OR (name = "ENDLOAD") OR (name = "PUT-PURE-HERE")
        OR (name = "DEFAULTS-DEFINED") OR (name = "CHECKPOINT")
        OR (name = "BEGIN-SEGMENT") OR (name = "END-SEGMENT")
        OR (name = "DEFINE-SEGMENT") OR (name = "FREQUENT-WORDS?")
        OR (name = "NEVER-ZAP-TO-SOURCE-DIRECTORY?") OR (name = "ASK-FOR-PICTURE-FILE?")
        OR (name = "PICFILE") THEN
    (* SubrIgnored (Subrs.Meta.cs): a grab-bag of real-compiler knobs this
       port has no use for - memory/GC tuning (GC-MON, BLOAT), string-pool
       tuning (ZSTR-ON/OFF), the MDL file-loading protocol (ENDLOAD,
       PUT-PURE-HERE, DEFAULTS-DEFINED, CHECKPOINT), save-file segmentation
       (BEGIN-/END-/DEFINE-SEGMENT, used by V6 only), a Z-machine
       optimization hint (FREQUENT-WORDS?, zork1.zil calls this), and Inform/
       Blorb-era authoring conveniences this target format doesn't have
       (NEVER-ZAP-TO-SOURCE-DIRECTORY?, ASK-FOR-PICTURE-FILE?, PICFILE). The
       original always returns FALSE and does nothing else; so does this. *)
    RETURN MkVal(FalseVal())

  ELSIF (name = "PACKAGE") OR (name = "ZPACKAGE") OR (name = "ZZPACKAGE")
        OR (name = "DEFINITIONS") OR (name = "ZSECTION") OR (name = "ZZSECTION") THEN
    (* Ported from Subrs.Packages.cs, reduced to what a SINGLE FLAT OBLIST
       needs. The original gives each package an internal and an external
       OBLIST and pushes a three-deep lookup path (internal, external,
       root), so an unqualified name inside the package resolves to the
       package's own atom and only ENTRY'd names escape. This port has one
       global atom table (phase 1's deliberate simplification), which makes
       every name visible everywhere — strictly MORE permissive, so a name
       the original would have found is still found. What it gives up is
       isolation: two packages that each define a different FOO would
       collide here where the original keeps them apart. Real library and
       game source is written so that ENTRY'd names don't collide anyway,
       and the corpus confirms it (four packages in the whole of zillib,
       with disjoint exports).

       So all a package declaration has to do here is record that the
       package now exists, which is what USE checks before deciding to load
       a file. DEFINITIONS/ZSECTION differ from PACKAGE only in the oblist
       path they build, which is exactly the part that doesn't apply. *)
    IF (n < 1) OR (args[0].kind # ZilObj.KString) THEN
      RETURN Err("PACKAGE/DEFINITIONS: expected a STRING package name")
    END;
    DefinePackage(args[0].strBuf^);
    RETURN MkVal(ZilObj.Intern(args[0].strBuf^))

  ELSIF (name = "ENDPACKAGE") OR (name = "END-DEFINITIONS") OR (name = "ENDSECTION")
        OR (name = "ENDBLOCK") THEN
    (* Pops the oblist path the matching PACKAGE/BLOCK pushed. With one flat
       table there is no path to pop. *)
    RETURN MkVal(TrueVal())

  ELSIF name = "BLOCK" THEN
    RETURN MkVal(TrueVal())

  ELSIF (name = "ENTRY") OR (name = "RENTRY") THEN
    (* Moves the named atoms from the package's internal oblist to its
       external one (RENTRY: to the root oblist), i.e. exports them. With
       one flat table every atom is already globally visible, so there is
       nothing to move. The original also validates that the atoms really
       are on the internal oblist — a check that has no meaning here. *)
    RETURN MkVal(TrueVal())

  ELSIF name = "COMPILING?" THEN
    (* Always true in the original too — zilf is a compiler, never an
       interpreter running the game. *)
    RETURN MkVal(TrueVal())

  ELSIF name = "DELAY-DEFINITION" THEN
    (* Part of the "hooks" system (Subrs.Meta.cs) library files use to let
       a game override a default definition before it's ever encountered:
       marks a not-yet-seen DEFAULT-DEFINITION section so that, when it IS
       encountered, it won't insert its own body — it'll wait for a
       REPLACE-DEFINITION instead. Implemented directly with this port's
       existing PUTPROP/GETPROP (the original does exactly the same thing,
       just via ctx.PutProp/GetProp) — no new machinery needed. A plain
       evaluated-args SUBR in the original (name self-evaluates), so no
       Eval call needed here either. *)
    IF (n < 1) OR (args[0].kind # ZilObj.KAtom) THEN
      RETURN Err("DELAY-DEFINITION: expected a name atom")
    END;
    ind := ZilObj.Intern("REPLACE-DEFINITION");
    IF ZilObj.GetProp(args[0], ind) # NIL THEN
      RETURN ErrAtom("DELAY-DEFINITION: section has already been referenced:", args[0])
    END;
    ZilObj.PutProp(args[0], ind, ZilObj.Intern("DELAY-DEFINITION"));
    RETURN MkVal(args[0])

  ELSIF name = "VOC" THEN
    (* <VOC "text" [part-of-speech]> interns the word into the dictionary
       and returns the atom naming it. The original CHTYPEs that atom to a
       VOC pseudo-type; there is no type system here, so the plain atom is
       returned — which is what real source uses it as, a building block
       inside larger expressions. *)
    IF (n < 1) OR (args[0].kind # ZilObj.KString) THEN
      RETURN Err("VOC: expected a STRING")
    END;
    Strings.Copy(args[0].strBuf^, s);
    Strings.ToUpper(s);
    i := 0;
    IF (n >= 2) & (args[1].kind = ZilObj.KAtom) THEN i := PartOfSpeechBits(args[1].atomText) END;
    len := ZilModel.AddVocab(s, i);
    IF len < 0 THEN RETURN Err("VOC: too many vocabulary words") END;
    RETURN MkVal(ZilObj.Intern(s))

  ELSIF name = "CONS" THEN
    (* <CONS first rest>: prepends first onto rest, a LIST — or FALSE
       (<>), meaning "empty list", to build a 1-element list. *)
    IF n # 2 THEN RETURN Err("CONS: expected 2 args") END;
    IF args[1].kind = ZilObj.KFalse THEN
      RETURN MkVal(ZilObj.Cons(ZilObj.KList, args[0], ZilObj.NewEmpty(ZilObj.KList)))
    ELSIF args[1].kind = ZilObj.KList THEN
      RETURN MkVal(ZilObj.Cons(ZilObj.KList, args[0], args[1]))
    ELSE
      RETURN Err("CONS: second arg must be a LIST or FALSE")
    END

  ELSIF name = "LENGTH?" THEN
    IF (n # 2) OR (args[1].kind # ZilObj.KFix) THEN
      RETURN Err("LENGTH?: expected a structure and a FIX limit")
    END;
    len := ZilObj.ListLength(args[0]);
    IF (len >= 0) & (len <= args[1].fixVal) THEN RETURN MkVal(ZilObj.NewFix(len))
    ELSE RETURN MkVal(FalseVal()) END

  ELSE
    (* Name it. A bare "unrecognized SUBR" says nothing about which of the
       two hundred registered names fell through to here. *)
    Strings.Copy("unrecognized or not-yet-implemented SUBR: ", msgBuf);
    Strings.Append(name, msgBuf);
    RETURN Err(msgBuf)
  END
END ApplySubr;

(* DEFINE/DEFINE20/DEFMAC: <[DEFINE|DEFMAC] name [act] (argspec...) body...>.
   Ported from the original's shared PerformDefine — doesn't call Eval
   (just builds and stores a FUNCTION or MACRO-wrapping-a-FUNCTION value),
   so unlike Eval's inlined FSUBRs this can be its own procedure. The
   redefine-check the original has (AllowRedefine / already-defined error)
   is skipped — pragmatic subset, and re-running a test file repeatedly
   benefits from silently allowing redefinition. *)
PROCEDURE ApplyDefine(isMacro: BOOLEAN; restArgs: ZilObj.Zo): ZResult;
VAR nameAtom, actAtom, argSpecList, bodyList, rest, funcVal: ZilObj.Zo;
BEGIN
  IF (restArgs = NIL) OR (restArgs.first = NIL) OR (restArgs.first.kind # ZilObj.KAtom) THEN
    RETURN Err("DEFINE/DEFMAC: expected a name atom")
  END;
  nameAtom := restArgs.first;
  rest := restArgs.rest;

  actAtom := NIL;
  IF (rest # NIL) & (rest.first # NIL) & (rest.first.kind = ZilObj.KAtom) THEN
    actAtom := rest.first; rest := rest.rest
  END;

  IF (rest = NIL) OR (rest.first = NIL) OR (rest.first.kind # ZilObj.KList) THEN
    RETURN Err("DEFINE/DEFMAC: expected an argument list")
  END;
  argSpecList := rest.first;
  bodyList := rest.rest;
  IF (bodyList = NIL) OR (bodyList.first = NIL) THEN
    RETURN Err("DEFINE/DEFMAC: empty body")
  END;

  funcVal := ZilObj.NewFunction(argSpecList, actAtom, bodyList);
  IF isMacro THEN nameAtom.globalVal := ZilObj.NewMacro(funcVal)
  ELSE nameAtom.globalVal := funcVal END;
  RETURN MkVal(nameAtom)
END ApplyDefine;

(* ROUTINE: <ROUTINE name [act] (argspec...) body...>. Ported from
   ZilRoutine's own constructor (already read in phase 2c) — confirmed
   there that ROUTINE has no interpret-time Apply/Eval at all (it's
   compiled, never run directly), so this only needs to capture the raw,
   unevaluated pieces for a later compilation pass (phase 3b, not yet
   built) — same shape as ApplyDefine, and for the same reason (no Eval
   calls needed) this can be its own procedure. *)
PROCEDURE ApplyRoutine(restArgs: ZilObj.Zo): ZResult;
VAR nameAtom, actAtom, argSpecList, bodyList, rest: ZilObj.Zo;
BEGIN
  IF (restArgs = NIL) OR (restArgs.first = NIL) OR (restArgs.first.kind # ZilObj.KAtom) THEN
    RETURN Err("ROUTINE: expected a name atom")
  END;
  nameAtom := restArgs.first;
  rest := restArgs.rest;

  actAtom := NIL;
  IF (rest # NIL) & (rest.first # NIL) & (rest.first.kind = ZilObj.KAtom) THEN
    actAtom := rest.first; rest := rest.rest
  END;

  IF (rest = NIL) OR (rest.first = NIL) OR (rest.first.kind # ZilObj.KList) THEN
    RETURN Err("ROUTINE: expected an argument list")
  END;
  argSpecList := rest.first;
  bodyList := rest.rest;
  (* An empty body is legal: zillib generates routines whose whole body is
     spliced in from a MAPF, and that list is legitimately empty when the
     game defined none of whatever it enumerates (pronouns.zil's
     V-PRONOUNS, for a game with no <PRONOUN> definitions). The compiler
     emits RTRUE for such a routine. *)

  ZilModel.AddRoutine(nameAtom, actAtom, argSpecList, bodyList);
  SetZValRoutine(nameAtom);
  RETURN MkVal(nameAtom)
END ApplyRoutine;

(* OBJECT/ROOM: <[OBJECT|ROOM] name (prop...) (prop...) ...>. Ported from
   ZilModelObject's own constructor (read this phase) — confirmed there
   that a property list's real meaning (a flag list vs an ordinary
   property vs IN/LOC, etc.) is only interpreted later during compilation,
   not at registration time, so — like ROUTINE — this just captures the
   name, the ROOM-vs-OBJECT flag, and the raw chain of property lists
   as-is, with no Eval calls needed. *)
PROCEDURE ApplyObject(isRoom: BOOLEAN; restArgs: ZilObj.Zo): ZResult;
VAR nameAtom, p: ZilObj.Zo; objErr: ARRAY 256 OF CHAR;
BEGIN
  IF (restArgs = NIL) OR (restArgs.first = NIL) OR (restArgs.first.kind # ZilObj.KAtom) THEN
    RETURN Err("OBJECT/ROOM: expected a name atom")
  END;
  nameAtom := restArgs.first;

  p := restArgs.rest;
  WHILE (p # NIL) & (p.first # NIL) DO
    IF p.first.kind # ZilObj.KList THEN
      Strings.Copy("OBJECT/ROOM ", objErr);
      Strings.Append(nameAtom.atomText, objErr);
      Strings.Append(": each property must be a list, got", objErr);
      RETURN ErrAtom(objErr, p.first)
    END;
    p := p.rest
  END;

  ZilModel.AddObject(nameAtom, isRoom, restArgs.rest);
  SetZVal(nameAtom);
  RETURN MkVal(nameAtom)
END ApplyObject;

(* ------------------------------------------------------------------ *)
(* Eval — one self-recursive procedure (FORM/LIST handling, and the      *)
(* FSUBRs QUOTE/COND/AND/OR, are inlined here rather than factored into  *)
(* helpers, since they need to call Eval and this transpiler has no      *)
(* FORWARD declarations — see ZilRead.mod's ReadOne for the same pattern *)
(* and a longer explanation).                                            *)
(* ------------------------------------------------------------------ *)

(* EvalImpl(z, qq): the real self-recursive evaluator. `qq` is FALSE for
   ordinary evaluation and TRUE while walking inside a QUASIQUOTE template
   (see the dedicated comment inside the procedure body for what that mode
   does) — threaded as a parameter, rather than as a second self-recursive
   procedure, for the usual forward-reference reason: normal eval and
   quasiquote-walk each need to call the other (QUASIQUOTE's own FSUBR
   case switches INTO walk mode; an UNQUOTE'd spot switches back OUT to
   normal eval), so they have to be the same procedure. The exported
   `Eval*` below is a thin wrapper (`EvalImpl(z, FALSE)`) kept as the
   stable public entry point so every existing caller/test harness is
   unaffected. *)
(* Finds and loads a source file: the original's PerformLoadFile, shared by
   INSERT-FILE/FLOAD/XFLOAD and by USE/INCLUDE (which load a package's file
   when the package isn't defined yet). Resolves `fileName` against
   currentDir first, then each configured library path, trying the name as
   given, then with .zil/.mud appended, then the same three lowercased —
   real ZIL source (e.g. zilf's own sample/zork1/zork1.zil) commonly names
   an UPPERCASE file that is lowercase on disk, and the original's
   GetIncludeFileNameVariants does the same lowercase fallback for the same
   reason. Sets `found` FALSE, without touching the error state, when no
   candidate opened, so a caller like USE can report its own message.

   Calls EvalImpl on every form it reads, and EvalImpl calls back here —
   ordinary mutual recursion, which this transpiler supports (see the
   correction in Notes/zilf_port_plan.md; earlier phases of this port
   wrongly believed it didn't and inlined code like this into EvalImpl to
   avoid it). *)
PROCEDURE LoadFile(fileName: ARRAY OF CHAR; what: ARRAY OF CHAR; VAR found: BOOLEAN): ZResult;
VAR rd: ZilRead.Reader;
    z: ZilObj.Zo;
    r, result: ZResult;
    ok, done, isTerm, opened: BOOLEAN;
    termCh, base, try: INTEGER;
    nm, cand, savedDir, msg: ARRAY 512 OF CHAR;
BEGIN
  opened := FALSE;
  base := -1;   (* -1 means currentDir; 0.. index into includePaths *)
  WHILE ~opened & (base < nIncludePaths) DO
    Strings.Copy(fileName, nm);
    FOR try := 0 TO 5 DO
      IF ~opened THEN
        IF base < 0 THEN Strings.Copy(currentDir, cand)
        ELSE Strings.Copy(includePaths[base], cand) END;
        Strings.Append(nm, cand);
        IF try MOD 3 = 1 THEN Strings.Append(".zil", cand)
        ELSIF try MOD 3 = 2 THEN Strings.Append(".mud", cand) END;
        IF ZilRead.Open(rd, cand) THEN opened := TRUE END
      END;
      IF try = 2 THEN Strings.ToLower(nm) END
    END;
    INC(base)
  END;
  found := opened;
  IF ~opened THEN RETURN MkVal(FalseVal()) END;

  Strings.Copy(currentDir, savedDir);
  DirOf(cand, currentDir);

  result := MkVal(ZilObj.NewString("DONE"));
  LOOP
    z := ZilRead.ReadOne(rd, ok, done, isTerm, termCh);
    IF ~ok THEN
      Strings.Copy(what, msg); Strings.Append(": read error in ", msg);
      Strings.Append(cand, msg); Strings.Append(": ", msg);
      Strings.Append(rd.errMsg, msg);
      IF evalErrFlag THEN
        Strings.Append(" (", msg); Strings.Append(evalErrMsg, msg); Strings.Append(")", msg)
      END;
      result := Err(msg); EXIT
    END;
    IF done THEN EXIT END;
    IF isTerm THEN
      Strings.Copy(what, msg); Strings.Append(": stray terminator in included file", msg);
      result := Err(msg); EXIT
    END;
    r := EvalImpl(z, FALSE);
    IF r.outcome # OValue THEN result := r; EXIT END;
    (* An evaluation error is reported through evalErrFlag, not through the
       outcome (Err returns a FALSE value), so without this check an
       included file kept evaluating after its first error and every later
       form failed in some confusing derived way — e.g. a failed
       <CONSTANT WORD-SIZE ...> turning into "expected FIX args" hundreds of
       lines later. Stop where the error actually is. *)
    IF evalErrFlag THEN result := r; EXIT END
  END;
  ZilRead.Close(rd);
  Strings.Copy(savedDir, currentDir);
  RETURN result
END LoadFile;

(* Calls an already-evaluated applicable value with already-evaluated
   arguments — what MAPF and APPLY need, and what the ordinary FORM path
   can't give them (it starts from unevaluated argument FORMS).

   Rather than duplicating the whole argument-binding machinery, this builds
   the FORM <fn <QUOTE a0> <QUOTE a1> ...> and evaluates it: a function's
   arguments are evaluated by the callee, and QUOTE hands each value back
   unchanged, so the effect is exactly "apply fn to these values". A
   non-atom head self-evaluates, so the function value can sit in head
   position directly. *)
PROCEDURE ApplyValue(fn: ZilObj.Zo; args: ARRAY OF ZilObj.Zo; n: INTEGER): ZResult;
VAR head, tail, cell, q: ZilObj.Zo; i: INTEGER;
BEGIN
  head := ZilObj.Cons(ZilObj.KForm, fn, NIL);
  tail := head;
  FOR i := 0 TO n - 1 DO
    q := ZilObj.Cons(ZilObj.KForm, args[i], NIL);
    q := ZilObj.Cons(ZilObj.KForm, ZilObj.Intern("QUOTE"), q);
    cell := ZilObj.Cons(ZilObj.KForm, q, NIL);
    tail.rest := cell; tail := cell
  END;
  RETURN EvalImpl(head, FALSE)
END ApplyValue;

(* Runs a compiler hook: a global in the HOOKS package that the library
   installs an applicable value into, which the compiler calls by name at a
   fixed point. zillib's ADD-FINISHER chains onto the PRE-COMPILE hook this
   way, and the achievements table (ACHIEVEMENTS / ACHIEVEMENT-COUNT) only
   comes into existence when that hook runs.

   The original keeps hooks in a dedicated `hooks` OBLIST and looks the name
   up there; this port has one flat oblist in which an OBLIST-qualified name
   is interned under its full NAME!-OBLIST!-OBLIST spelling, so the lookup
   is simply the atom the library itself writes. An unset hook is not an
   error - most programs never install one. *)
PROCEDURE RunHook*(name: ARRAY OF CHAR): BOOLEAN;
VAR atom, fn: ZilObj.Zo; r: ZResult; noArgs: ARRAY 1 OF ZilObj.Zo;
    buf: ARRAY 128 OF CHAR;
BEGIN
  Strings.Copy(name, buf);
  Strings.Append("!-HOOKS!-ZILF", buf);
  atom := ZilObj.Intern(buf);
  fn := atom.globalVal;
  IF fn = NIL THEN RETURN TRUE END;
  ClearErr;
  noArgs[0] := NIL;
  r := ApplyValue(fn, noArgs, 0);
  RETURN ~evalErrFlag
END RunHook;

PROCEDURE EvalImpl(z: ZilObj.Zo; qq: BOOLEAN): ZResult;
VAR
  msgBuf2, s2: ARRAY 1024 OF CHAR;
  head, n, resultHead, resultTail, cell, clause, body: ZilObj.Zo;
  nFirst, zFirst, zRestFirst, clauseFirst: ZilObj.Zo;
  r, cr: ZResult;
  args: ARRAY MaxArgs OF ZilObj.Zo;
  nargs, i: INTEGER;
  name: ARRAY 64 OF CHAR;
  isFSubr: BOOLEAN;
  (* VERSION? / IFFLAG *)
  cond, flagVal: ZilObj.Zo; matched: BOOLEAN; ver: INTEGER;
  ifFlagName: ARRAY 64 OF CHAR; ifFlagNeg: BOOLEAN;
  (* ADD-TELL-TOKENS *)
  tellToks, tellTail: ZilObj.Zo;
  (* SEGMENT splicing *)
  segLen, segI, j: INTEGER;
  (* DEFSTRUCT *)
  dsName, dsBase, dsNth, dsPut, dsTag, dsFieldName, dsFNth, dsFPut: ARRAY 64 OF CHAR;
  dsNum, dsQ: ARRAY 16 OF CHAR;
  dsSrc: ARRAY 1024 OF CHAR;
  dsOffset, dsFOffset, dsIdx: INTEGER;
  dsGotOffset: BOOLEAN;
  dsOpt, dsClause, dsVal: ZilObj.Zo;
  (* OBJECT / ROOM *)
  objProps, objTail, splice: ZilObj.Zo;
  (* MAKE-<struct> *)
  mkName, mkField: ARRAY 64 OF CHAR;
  mkIdx, mkPos, mkI: INTEGER;
  mkByTag, mkIsByte, mkOk: BOOLEAN;
  mkRawOff: INTEGER;
  mkExisting, mkTarget: ZilObj.Zo;
  (* MAPF / MAPR / APPLY *)
  mapArgs: ARRAY MaxArgs OF ZilObj.Zo;
  mapStructs: ARRAY MaxArgs OF ZilObj.Zo;
  mapHead, mapTail, mapCell: ZilObj.Zo;
  mapI, mapNStruct, mapCount, mapLen, mapPos: INTEGER;
  mapIsMapR, mapStop: BOOLEAN;
  (* QUASIQUOTE walk mode (see the dedicated comment below) *)
  qqResult, qqTail, qqElem, qqInner, qqCell, qqSpliceP, qqVec: ZilObj.Zo;
  qqStop: BOOLEAN;
  qqVecIdx: INTEGER;
  (* PROG / REPEAT / BIND (see the dedicated comment at that branch below) *)
  progArgs, progNameAtom, progBindings, progBody, progAct: ZilObj.Zo;
  progBindAtoms, progSavedVals: ARRAY MaxBindings OF ZilObj.Zo;
  progNBind, progI: INTEGER;
  progOneBind, progTarget, progInit, progBindFirst, progBP: ZilObj.Zo;
  progRepeat, progCatchy, progStop, progAgain: BOOLEAN;
  (* FUNCTION / MACRO application (see the dedicated comment at that
     branch below) *)
  fnIsMacro, fnStop, fnUsedVarargs, fnQuoted, fnVarargsRaw: BOOLEAN;
  fnActualHead, fnCallArgs, fnSpecPos, fnOneSpec, fnTarget, fnDefault: ZilObj.Zo;
  fnSpecFirst, fnActivation, fnBP: ZilObj.Zo;
  fnBindAtoms, fnSavedVals: ARRAY MaxBindings OF ZilObj.Zo;
  fnNBind, fnI, fnPhase: INTEGER;
  (* INSERT-FILE (see the dedicated comment at that branch) *)
  insRd: ZilRead.Reader;
  insOk, insDone, insIsTerm, insOpened: BOOLEAN;
  insBase: INTEGER;
  insMsg: ARRAY 512 OF CHAR;
  (* USE / INCLUDE *)
  usePos: INTEGER; useFound: BOOLEAN; useName: ARRAY 64 OF CHAR;
  insTermCh: INTEGER;
  insZ: ZilObj.Zo;
  insResult: ZResult;
  insCand, insSavedDir: ARRAY 1024 OF CHAR;
  insName: ARRAY 512 OF CHAR;
  insTry: INTEGER;
  (* DEFAULT-DEFINITION / REPLACE-DEFINITION (see the dedicated comment
     at that branch) *)
  defName, defBody, defState, defInd, defP: ZilObj.Zo;
  defI: INTEGER;
  (* PROPDEF *)
  pdName, pdRest, pdSpec: ZilObj.Zo;
  (* expand-only mode — see expandOnlyPending *)
  myExpandOnly: BOOLEAN;
BEGIN
  myExpandOnly := expandOnlyPending;
  expandOnlyPending := FALSE;
  IF z = NIL THEN RETURN MkVal(NIL) END;

  IF qq THEN
    (* QUASIQUOTE walk mode. The real zilf implements `/~ as an ordinary
       library (zillib/qq.mud) built on CHTYPE/PACKAGE/MAPF/APPLY/PRIMTYPE
       reflection this port doesn't have; since `/~ turn out to be used
       pervasively across the CORE zillib files (not an opt-in extra —
       confirmed by grepping real library/game source before writing this),
       this implements the same OBSERVABLE behavior natively instead —
       same "pragmatic reimplementation over faithful port" approach as
       PROG/REPEAT/BIND vs. LocalEnvironment. A non-structured value (ATOM/
       FIX/STRING/etc.) passes through literally; a LIST/FORM/VECTOR is
       rebuilt recursively with the same shape; an UNQUOTE (`~X`, read as
       <UNQUOTE X>) evaluates X normally and substitutes the result; an
       UNQUOTE wrapping a SEGMENT (`~!.X` etc. — the original detects
       splicing this same way, via DECL? on a TILDE/SEGMENT combination)
       evaluates X normally and splices its elements into the surrounding
       LIST/FORM instead of inserting a single element — this needs to be
       special-cased in the rebuild loop below (peeking at each element's
       raw shape) rather than handled generically inside this procedure's
       own single-value return, since splicing must be able to contribute
       zero or many elements, not exactly one. ADECL bodies and top-level
       splice attempts (a bare `~!.X` with no surrounding LIST/FORM to
       splice into) are deliberately not specially handled — pragmatic
       subset; not needed by any real macro seen so far. *)
    IF (z.kind = ZilObj.KForm) & (ZilObj.ListLength(z) = 2) & ZilObj.IsAtomNamed(z.first, "UNQUOTE") THEN
      qqInner := z.rest.first;
      IF qqInner.kind = ZilObj.KSegment THEN RETURN EvalImpl(qqInner.segForm, FALSE)
      ELSE RETURN EvalImpl(qqInner, FALSE) END

    ELSIF (z.kind = ZilObj.KForm) OR (z.kind = ZilObj.KList) THEN
      qqResult := NIL; qqTail := NIL; qqStop := FALSE; r := MkVal(NIL);
      n := z;
      WHILE (n # NIL) & (n.first # NIL) & ~qqStop DO
        qqElem := n.first;
        IF (qqElem.kind = ZilObj.KForm) & (ZilObj.ListLength(qqElem) = 2)
           & ZilObj.IsAtomNamed(qqElem.first, "UNQUOTE") & (qqElem.rest.first.kind = ZilObj.KSegment) THEN
          qqInner := qqElem.rest.first;
          r := EvalImpl(qqInner.segForm, FALSE);
          IF r.outcome # OValue THEN
            qqStop := TRUE
          ELSE
            (* Splice through the generic structure accessors, not by walking
               .rest: the value may be a VECTOR, and a vector's elements are
               not a cons chain. zillib's THINGS-PROPSPEC hits this — a
               pseudo-object whose action is written ([READ EXAMINE] "text")
               splices a VECTOR of verbs, and walking .rest spliced NOTHING,
               leaving <VERB?> with no arguments and so <EQUAL? ,PRSA> with
               one operand. *)
            IF ~IsStructured(r.value) THEN
              RETURN ErrAtom("quasiquote: expected a structured value to splice, got", r.value)
            END;
            segLen := StructLength(r.value);
            FOR segI := 1 TO segLen DO
              qqCell := ZilObj.Cons(z.kind, StructNth(r.value, segI), NIL);
              IF qqResult = NIL THEN qqResult := qqCell ELSE qqTail.rest := qqCell END;
              qqTail := qqCell
            END
          END
        ELSE
          r := EvalImpl(qqElem, TRUE);
          IF r.outcome # OValue THEN
            qqStop := TRUE
          ELSE
            qqCell := ZilObj.Cons(z.kind, r.value, NIL);
            IF qqResult = NIL THEN qqResult := qqCell ELSE qqTail.rest := qqCell END;
            qqTail := qqCell
          END
        END;
        n := n.rest
      END;
      IF qqStop THEN RETURN r END;
      IF qqResult = NIL THEN RETURN MkVal(ZilObj.NewEmpty(z.kind)) ELSE RETURN MkVal(qqResult) END

    ELSIF z.kind = ZilObj.KVector THEN
      (* No splice support inside vector templates (pragmatic subset —
         real macros overwhelmingly quasiquote FORM/LIST, not VECTOR); an
         UNQUOTE-of-SEGMENT here just inserts the evaluated segment's whole
         value as one element rather than splicing it. *)
      qqVec := ZilObj.NewVectorN(z.vecLen);
      FOR qqVecIdx := 0 TO z.vecLen - 1 DO
        r := EvalImpl(z.vecItems[qqVecIdx], TRUE);
        IF r.outcome # OValue THEN RETURN r END;
        qqVec.vecItems[qqVecIdx] := r.value
      END;
      RETURN MkVal(qqVec)

    ELSE
      RETURN MkVal(z)   (* leaf: literal, unevaluated *)
    END
  END;

  IF (z.kind = ZilObj.KAtom) OR (z.kind = ZilObj.KFix) OR (z.kind = ZilObj.KString)
     OR (z.kind = ZilObj.KChar) OR (z.kind = ZilObj.KFalse)
     OR (z.kind = ZilObj.KSubr) OR (z.kind = ZilObj.KFSubr) OR (z.kind = ZilObj.KActivation)
     OR (z.kind = ZilObj.KFunction) OR (z.kind = ZilObj.KMacro)
     OR (z.kind = ZilObj.KRoutine) THEN
    RETURN MkVal(z)

  ELSIF z.kind = ZilObj.KVector THEN
    (* A VECTOR evaluates its elements, exactly as a LIST does. zillib's
       <SETG NEW-SFLAGS ["TOUCH" (+ ,SF-TOUCH) ...]> depends on it: leaving
       the elements alone puts unevaluated <GVAL SF-TOUCH> forms in the table
       where the scope-flag reader wants numbers, and every SYNTAX line then
       silently keeps the default scope byte. SEGMENTs splice, same as in a
       list, so the result can be longer than the source. *)
    resultHead := NIL; segI := 0;
    FOR i := 0 TO z.vecLen - 1 DO
      nFirst := z.vecItems[i];
      IF (nFirst # NIL) & (nFirst.kind = ZilObj.KSegment) THEN
        r := EvalImpl(nFirst.segForm, FALSE);
        IF ShouldPass(r) THEN RETURN r END;
        IF evalErrFlag THEN RETURN r END;
        IF ~IsStructured(r.value) THEN
          RETURN ErrAtom("SEGMENT: expected a structured value to splice, got", r.value)
        END;
        segI := segI + StructLength(r.value)
      ELSE
        INC(segI)
      END
    END;
    resultHead := ZilObj.NewVectorN(segI);
    segI := 0;
    FOR i := 0 TO z.vecLen - 1 DO
      nFirst := z.vecItems[i];
      IF (nFirst # NIL) & (nFirst.kind = ZilObj.KSegment) THEN
        r := EvalImpl(nFirst.segForm, FALSE);
        IF ShouldPass(r) THEN RETURN r END;
        segLen := StructLength(r.value);
        FOR j := 1 TO segLen DO
          resultHead.vecItems[segI] := StructNth(r.value, j); INC(segI)
        END
      ELSE
        r := EvalImpl(nFirst, FALSE);
        IF ShouldPass(r) THEN RETURN r END;
        resultHead.vecItems[segI] := r.value; INC(segI)
      END
    END;
    RETURN MkVal(resultHead)

  ELSIF z.kind = ZilObj.KAdecl THEN
    RETURN EvalImpl(z.adFirst, FALSE)  (* DECL check skipped *)

  ELSIF z.kind = ZilObj.KSegment THEN
    Strings.Copy("a SEGMENT can only be evaluated inside a structure: ", msgBuf2);
    ZilObj.PrintTo(z, s2); Strings.Append(s2, msgBuf2);
    RETURN Err(msgBuf2)

  ELSIF z.kind = ZilObj.KList THEN
    IF ZilObj.IsEmpty(z) THEN RETURN MkVal(z) END;
    resultHead := NIL; resultTail := NIL;
    n := z;
    WHILE (n # NIL) & (n.first # NIL) DO
      nFirst := n.first;
      IF nFirst.kind = ZilObj.KSegment THEN
        r := EvalImpl(nFirst.segForm, FALSE);
        IF ShouldPass(r) THEN RETURN r END;
        IF evalErrFlag THEN RETURN r END;
        IF ~IsStructured(r.value) THEN
          RETURN ErrAtom("SEGMENT: expected a structured value to splice, got", r.value)
        END;
        segLen := StructLength(r.value);
        FOR segI := 1 TO segLen DO
          cell := ZilObj.Cons(ZilObj.KList, StructNth(r.value, segI), NIL);
          IF resultHead = NIL THEN resultHead := cell ELSE resultTail.rest := cell END;
          resultTail := cell
        END;
        n := n.rest;
        cell := NIL
      ELSE
      r := EvalImpl(nFirst, FALSE);
      IF ShouldPass(r) THEN RETURN r END;
      cell := ZilObj.Cons(ZilObj.KList, r.value, NIL);
      IF resultHead = NIL THEN resultHead := cell ELSE resultTail.rest := cell END;
      resultTail := cell;
      n := n.rest
      END
    END;
    IF resultHead = NIL THEN RETURN MkVal(ZilObj.NewEmpty(ZilObj.KList)) END;
    RETURN MkVal(resultHead)

  ELSIF z.kind = ZilObj.KForm THEN
    IF ZilObj.IsEmpty(z) THEN RETURN MkVal(FalseVal()) END;

    (* head lookup: global first, then local (matches the original
       exactly — see module header note) *)
    zFirst := z.first;
    IF zFirst.kind = ZilObj.KAtom THEN
      head := zFirst.globalVal;
      IF head = NIL THEN head := zFirst.localVal END;
      IF head = NIL THEN
        (* Defining a compilation flag also makes <IF-NAME body...> and
           <IFN-NAME body...> usable. The original builds them as a pair of
           DEFMACs (IF-{0}!- / IFN-{0}!- on the root oblist) that expand to
           an IFFLAG; synthesizing those macro bodies as data here would be
           a lot of structure-building for no extra behaviour, so the names
           are recognized directly instead — matched only when the suffix
           really names a DEFINED flag, so an ordinary routine called
           IF-SOMETHING is unaffected. Equivalent to the original's
           expansion apart from the BIND wrapper it puts around a
           multi-statement body, which this port doesn't need since the
           statements are simply evaluated in order. *)
        ifFlagNeg := FALSE;
        Strings.Copy(zFirst.atomText, ifFlagName);
        IF (ifFlagName[0] = "I") & (ifFlagName[1] = "F") & (ifFlagName[2] = "-") THEN
          Strings.Delete(ifFlagName, 0, 3)
        ELSIF (ifFlagName[0] = "I") & (ifFlagName[1] = "F") & (ifFlagName[2] = "N")
              & (ifFlagName[3] = "-") THEN
          Strings.Delete(ifFlagName, 0, 4); ifFlagNeg := TRUE
        ELSE
          ifFlagName[0] := 0X
        END;
        flagVal := NIL;
        IF ifFlagName[0] # 0X THEN flagVal := FlagValue(ifFlagName) END;

        IF flagVal = NIL THEN
          (* <MAKE-FOO ...>, the constructor DEFSTRUCT defines for structure
             FOO. The original generates it as a (very large) macro; here it
             is recognized by name and built directly, which avoids needing
             CHTYPE, IVECTOR and SPLICE just to construct a record.

             Three call shapes, distinguished exactly as the original's
             macro does, by looking at the RAW first argument:
               <MAKE-FOO 'FOO obj 'FIELD v ...>  fill an existing object
               <MAKE-FOO 'FIELD v ...>           new object, by field name
               <MAKE-FOO v1 v2 ...>              new object, positionally *)
          Strings.Copy(zFirst.atomText, mkName);
          mkIdx := -1;
          IF (mkName[0] = "M") & (mkName[1] = "A") & (mkName[2] = "K")
             & (mkName[3] = "E") & (mkName[4] = "-") THEN
            Strings.Delete(mkName, 0, 5);
            mkIdx := FindStruct(mkName)
          END;
          IF mkIdx < 0 THEN
            (* Name the whole FORM, not just the head. "calling unassigned
               atom: PUT" could be any of hundreds of places in a library;
               the form itself usually identifies it on sight. *)
            Strings.Copy("calling unassigned atom: ", msgBuf2);
            Strings.Append(zFirst.atomText, msgBuf2);
            Strings.Append(" in ", msgBuf2);
            ZilObj.PrintTo(z, s2); Strings.Append(s2, msgBuf2);
            RETURN Err(msgBuf2)
          END;

          n := z.rest;
          mkExisting := NIL;
          (* a leading <QUOTE structname> means "fill this existing object" *)
          IF (n # NIL) & (n.first # NIL) & (n.first.kind = ZilObj.KForm)
             & (ZilObj.ListLength(n.first) = 2)
             & ZilObj.IsAtomNamed(n.first.first, "QUOTE")
             & (n.first.rest.first.kind = ZilObj.KAtom)
             & (n.first.rest.first.atomText = mkName) THEN
            n := n.rest;
            IF (n = NIL) OR (n.first = NIL) THEN
              RETURN Err("MAKE-: expected an object after the structure name")
            END;
            r := EvalImpl(n.first, FALSE);
            IF ShouldPass(r) THEN RETURN r END;
            mkExisting := r.value;
            n := n.rest
          END;

          mkByTag := (n # NIL) & (n.first # NIL) & (n.first.kind = ZilObj.KForm)
                     & (ZilObj.ListLength(n.first) = 2)
                     & ZilObj.IsAtomNamed(n.first.first, "QUOTE");

          IF mkExisting # NIL THEN
            mkTarget := mkExisting
          ELSE
            (* a fresh structure of the base type, one element per field *)
            mkTarget := ZilObj.NewVectorN(structs[mkIdx].nFields);
            IF ~structs[mkIdx].baseIsVector THEN mkTarget.kind := ZilObj.KTable END;
            FOR mkI := 0 TO structs[mkIdx].nFields - 1 DO
              mkTarget.vecItems[mkI] := ZilObj.NewFix(0)
            END
          END;

          mkPos := 0;
          WHILE (n # NIL) & (n.first # NIL) DO
            IF mkByTag THEN
              IF (n.first.kind # ZilObj.KForm) OR (ZilObj.ListLength(n.first) # 2)
                 OR ~ZilObj.IsAtomNamed(n.first.first, "QUOTE")
                 OR (n.first.rest.first.kind # ZilObj.KAtom) THEN
                RETURN Err("MAKE-: expected a quoted field name")
              END;
              Strings.Copy(n.first.rest.first.atomText, mkField);
              mkPos := -1;
              FOR mkI := 0 TO structs[mkIdx].nFields - 1 DO
                IF structs[mkIdx].fieldName[mkI] = mkField THEN mkPos := mkI END
              END;
              IF mkPos < 0 THEN RETURN Err("MAKE-: unknown field name") END;
              (* the field's RAW offset and the accessor that decides what it
                 counts, kept for the existing-TABLE path below *)
              mkRawOff := structs[mkIdx].fieldOffset[mkPos];
              mkIsByte := structs[mkIdx].fieldPut[mkPos] = "PUTB";
              (* the field's element index is its offset measured from the
                 structure's own start offset *)
              mkPos := structs[mkIdx].fieldOffset[mkPos] - structs[mkIdx].startOffset;
              n := n.rest;
              IF (n = NIL) OR (n.first = NIL) THEN
                RETURN Err("MAKE-: expected a value after a field name")
              END
            END;
            r := EvalImpl(n.first, FALSE);
            IF ShouldPass(r) THEN RETURN r END;
            IF mkByTag & (mkExisting # NIL) & (mkTarget # NIL)
               & (mkTarget.kind = ZilObj.KTable) THEN
              (* Writing into an EXISTING table goes through the field's own
                 PUT accessor at the field's raw offset, because the offset
                 is in the accessor's units: a ZPUT field counts words, a
                 PUTB field counts bytes. Treating it as an element index
                 instead is silently wrong for a byte-wide table -- zillib's
                 PARSER-RESULT is <ITABLE 26 (BYTE)> with word fields, so
                 PST-PRSOS (word 4) landed in byte slot 4 and the assembler
                 only warned that a table address will not fit in a byte.
                 The parser then read nonsense and answered "..." to every
                 command. *)
              IF mkIsByte THEN mkOk := TablePutByte(mkTarget, mkRawOff, r.value)
              ELSE mkOk := TablePutWord(mkTarget, mkRawOff, r.value)
              END;
              IF ~mkOk THEN
                RETURN Err("MAKE-: field does not line up with an element of this table")
              END
            ELSIF ~StructPut(mkTarget, mkPos + 1, r.value) THEN
              RETURN Err("MAKE-: field index is outside the structure")
            END;
            IF ~mkByTag THEN INC(mkPos) END;
            n := n.rest
          END;
          RETURN MkVal(mkTarget)
        END;

        IF IsTrue(flagVal) = ifFlagNeg THEN RETURN MkVal(FalseVal()) END;
        body := z.rest;
        IF myExpandOnly THEN
          (* Expanding rather than evaluating (a routine body being prepared
             for compilation): yield the guarded code itself. The original's
             generated macro expands to <1 .A> for a single statement and
             <BIND () !.A> for several — same here, so a multi-statement
             body needs the compiler to handle BIND. *)
          IF (body = NIL) OR (body.first = NIL) THEN RETURN MkVal(FalseVal()) END;
          IF (body.rest = NIL) OR (body.rest.first = NIL) THEN RETURN MkVal(body.first) END;
          cell := ZilObj.Cons(ZilObj.KForm, ZilObj.NewEmpty(ZilObj.KList), body);
          RETURN MkVal(ZilObj.Cons(ZilObj.KForm, ZilObj.Intern("BIND"), cell))
        END;
        r := MkVal(FalseVal());
        WHILE (body # NIL) & (body.first # NIL) DO
          r := EvalImpl(body.first, FALSE);
          IF ShouldPass(r) THEN RETURN r END;
          body := body.rest
        END;
        RETURN r
      END
    ELSE
      r := EvalImpl(zFirst, FALSE);
      IF ShouldPass(r) THEN RETURN r END;
      head := r.value
    END;

    IF head.kind = ZilObj.KFix THEN
      (* <1 .L> — a FIX applied as a function is MDL's element accessor,
         equivalent to <NTH .L 1>. Real source uses this spelling far more
         often than NTH itself. *)
      IF (z.rest = NIL) OR (z.rest.first = NIL) THEN
        RETURN Err("a FIX applied as a function expects a structure")
      END;
      r := EvalImpl(z.rest.first, FALSE);
      IF ShouldPass(r) THEN RETURN r END;
      nFirst := StructNth(r.value, head.fixVal);
      IF nFirst = NIL THEN RETURN Err("index out of range") END;
      RETURN MkVal(nFirst)
    END;

    IF (head.kind = ZilObj.KFunction) OR (head.kind = ZilObj.KMacro) THEN
      (* Calling a DEFINE/DEFINE20 FUNCTION, or a DEFMAC MACRO (which wraps
         one). Ported from ZilFunction.ApplyImpl + ZilEvalMacro.Apply's
         "expand, then Eval the expansion" two-phase design — verified
         against both before writing this: in ZilForm.EvalImpl, calling any
         IApplicable head passes UNEVALUATED args (`Rest.ToArray()`), and
         it's the callee's own job to evaluate them; a MACRO's *own*
         invocation still evaluates its call-site arguments completely
         normally as it binds them (this is what distinguishes a ZIL
         DEFMAC from a Lisp `defmacro` — the macro function body runs on
         already-evaluated argument VALUES, not on quoted syntax, and it's
         the macro's *return value* that gets treated as a new FORM to
         Eval again, not its arguments that are left unevaluated). Needs to
         call Eval (arg values, OPT/AUX defaults, body forms, and the
         self-recursive re-Eval of a macro's expansion), so — same
         forward-reference reason as PROG/REPEAT/BIND — this is inlined
         rather than factored into its own procedure. *)
      fnIsMacro := (head.kind = ZilObj.KMacro);
      IF fnIsMacro THEN fnActualHead := head.macWrapped ELSE fnActualHead := head END;
      IF (fnActualHead = NIL) OR (fnActualHead.kind # ZilObj.KFunction) THEN
        RETURN Err("MACRO wraps a non-FUNCTION value (not supported yet)")
      END;

      fnNBind := 0;
      fnStop := FALSE;
      fnUsedVarargs := FALSE;
      fnCallArgs := z.rest;
      fnSpecPos := fnActualHead.funcArgSpec;
      fnPhase := APReq;

      WHILE (fnSpecPos # NIL) & (fnSpecPos.first # NIL) & ~fnStop DO
        fnOneSpec := fnSpecPos.first;

        IF (fnOneSpec.kind = ZilObj.KString)
           & ((fnOneSpec.strBuf^ = "OPT") OR (fnOneSpec.strBuf^ = "OPTIONAL")) THEN
          fnPhase := APOpt; fnSpecPos := fnSpecPos.rest

        ELSIF (fnOneSpec.kind = ZilObj.KString)
              & ((fnOneSpec.strBuf^ = "AUX") OR (fnOneSpec.strBuf^ = "EXTRA")) THEN
          fnPhase := APAux; fnSpecPos := fnSpecPos.rest

        ELSIF (fnOneSpec.kind = ZilObj.KString)
              & ((fnOneSpec.strBuf^ = "ARGS") OR (fnOneSpec.strBuf^ = "TUPLE")) THEN
          fnSpecPos := fnSpecPos.rest;
          IF (fnSpecPos = NIL) OR (fnSpecPos.first = NIL) OR (fnSpecPos.first.kind # ZilObj.KAtom) THEN
            RETURN Err("FUNCTION/MACRO: ARGS/TUPLE must be followed by an atom")
          END;
          fnTarget := fnSpecPos.first;
          (* "ARGS" binds the remaining arguments UNEVALUATED; "TUPLE" binds
             them evaluated. That one bit is the whole difference between
             them (the original: `evaluator.GetRest(eval && !varargsQuoted)`
             in ArgSpec, with varargsQuoted set for "ARGS"), and it is what
             makes a DEFMAC written with ("ARGS" A) a real macro: it sees
             the call site's syntax rather than its values. Evaluating here
             instead silently constant-folds every macro argument — caught
             by sample/name printing "about 0" for
             <- ,CURYEAR ,BIRTHYEAR>, both globals still holding their
             declared 0 at expansion time. *)
          fnVarargsRaw := fnOneSpec.strBuf^ = "ARGS";
          fnUsedVarargs := TRUE;
          resultHead := NIL; resultTail := NIL;
          WHILE (fnCallArgs # NIL) & (fnCallArgs.first # NIL) & ~fnStop DO
            IF fnVarargsRaw THEN
              r := MkVal(fnCallArgs.first)
            ELSE
              r := EvalImpl(fnCallArgs.first, FALSE)
            END;
            IF r.outcome # OValue THEN
              fnStop := TRUE
            ELSE
              cell := ZilObj.Cons(ZilObj.KList, r.value, NIL);
              IF resultHead = NIL THEN resultHead := cell ELSE resultTail.rest := cell END;
              resultTail := cell;
              fnCallArgs := fnCallArgs.rest
            END
          END;
          IF ~fnStop THEN
            IF fnNBind >= MaxBindings THEN RETURN Err("FUNCTION/MACRO: too many bindings") END;
            fnBindAtoms[fnNBind] := fnTarget;
            fnSavedVals[fnNBind] := fnTarget.localVal;
            INC(fnNBind);
            IF resultHead = NIL THEN fnTarget.localVal := ZilObj.NewEmpty(ZilObj.KList)
            ELSE fnTarget.localVal := resultHead END
          END;
          fnSpecPos := fnSpecPos.rest

        ELSE
          fnTarget := NIL; fnDefault := NIL; fnQuoted := FALSE;
          IF fnOneSpec.kind = ZilObj.KAtom THEN
            fnTarget := fnOneSpec
          ELSIF fnOneSpec.kind = ZilObj.KAdecl THEN
            fnTarget := fnOneSpec.adFirst
          ELSIF fnOneSpec.kind = ZilObj.KForm THEN
            (* not a (atom default) pair — the only other legal shape is a
               bare quoted atom, e.g. 'N read as <QUOTE N>; the check just
               below confirms and unwraps it, erroring otherwise *)
            fnTarget := fnOneSpec
          ELSIF (fnOneSpec.kind = ZilObj.KList) & (ZilObj.ListLength(fnOneSpec) = 2) THEN
            fnSpecFirst := fnOneSpec.first;
            IF fnSpecFirst.kind = ZilObj.KAdecl THEN fnTarget := fnSpecFirst.adFirst
            ELSE fnTarget := fnSpecFirst END;
            fnDefault := fnOneSpec.rest.first
          ELSE
            RETURN Err("FUNCTION/MACRO: malformed argument-list entry")
          END;
          (* A target still shaped like <QUOTE atom> (from source '`X` — the
             original checks this after any ADECL-unwrap above, and this
             port matches that order rather than the reverse) means the
             call-site argument for this parameter should be bound as-is,
             without evaluating it — e.g. DEFMAC BOTTLES ('N) in zilf's own
             99-bottles sample: N is quoted so it captures the caller's
             *literal* `.N` reference, which the macro body's quasiquote
             template later splices back in with ~.N so the generated code
             evaluates it in the caller's own scope, not the macro's. *)
          IF (fnTarget # NIL) & (fnTarget.kind = ZilObj.KForm) & (ZilObj.ListLength(fnTarget) = 2)
             & ZilObj.IsAtomNamed(fnTarget.first, "QUOTE") THEN
            fnQuoted := TRUE; fnTarget := fnTarget.rest.first
          END;
          IF (fnTarget = NIL) OR (fnTarget.kind # ZilObj.KAtom) THEN
            RETURN Err("FUNCTION/MACRO: argument-list target must be an ATOM")
          END;
          IF fnNBind >= MaxBindings THEN RETURN Err("FUNCTION/MACRO: too many bindings") END;
          fnBindAtoms[fnNBind] := fnTarget;
          fnSavedVals[fnNBind] := fnTarget.localVal;
          INC(fnNBind);

          IF fnPhase = APReq THEN
            IF (fnCallArgs = NIL) OR (fnCallArgs.first = NIL) THEN
              RETURN Err("FUNCTION/MACRO: too few arguments")
            END;
            IF fnQuoted THEN r := MkVal(fnCallArgs.first) ELSE r := EvalImpl(fnCallArgs.first, FALSE) END;
            IF r.outcome # OValue THEN fnStop := TRUE ELSE fnTarget.localVal := r.value END;
            fnCallArgs := fnCallArgs.rest

          ELSIF fnPhase = APOpt THEN
            IF (fnCallArgs # NIL) & (fnCallArgs.first # NIL) THEN
              IF fnQuoted THEN r := MkVal(fnCallArgs.first) ELSE r := EvalImpl(fnCallArgs.first, FALSE) END;
              IF r.outcome # OValue THEN fnStop := TRUE ELSE fnTarget.localVal := r.value END;
              fnCallArgs := fnCallArgs.rest
            ELSIF fnDefault # NIL THEN
              r := EvalImpl(fnDefault, FALSE);
              IF r.outcome # OValue THEN fnStop := TRUE ELSE fnTarget.localVal := r.value END
            ELSE
              fnTarget.localVal := NIL
            END

          ELSE (* APAux: never consumes call-site args *)
            IF fnDefault # NIL THEN
              r := EvalImpl(fnDefault, FALSE);
              IF r.outcome # OValue THEN fnStop := TRUE ELSE fnTarget.localVal := r.value END
            ELSE
              fnTarget.localVal := NIL
            END
          END;

          fnSpecPos := fnSpecPos.rest
        END
      END;

      IF ~fnStop & ~fnUsedVarargs & (fnCallArgs # NIL) & (fnCallArgs.first # NIL) THEN
        RETURN Err("FUNCTION/MACRO: too many arguments")
      END;

      IF ~fnStop THEN
        (* entering any function/macro application is an opaque boundary
           for a bare RETURN/AGAIN: always clear enclosingProgAtom, whether
           or not this function has its own activation atom (matches the
           original's unconditional `innerEnv.Rebind(EnclosingProgActivationAtom)`
           in ArgSpec.BeginApply). *)
        fnBindAtoms[fnNBind] := enclosingProgAtom;
        fnSavedVals[fnNBind] := enclosingProgAtom.localVal;
        enclosingProgAtom.localVal := NIL;
        INC(fnNBind);

        IF fnActualHead.funcAct # NIL THEN
          fnActivation := ZilObj.NewActivation("FUNCTION");
          fnBindAtoms[fnNBind] := fnActualHead.funcAct;
          fnSavedVals[fnNBind] := fnActualHead.funcAct.localVal;
          fnActualHead.funcAct.localVal := fnActivation;
          INC(fnNBind)
        ELSE
          fnActivation := NIL
        END;

        LOOP
          fnBP := fnActualHead.funcBody;
          WHILE (fnBP # NIL) & (fnBP.first # NIL) DO
            r := EvalImpl(fnBP.first, FALSE);
            IF r.outcome # OValue THEN EXIT END;
            fnBP := fnBP.rest
          END;
          IF fnActivation = NIL THEN
            fnStop := TRUE
          ELSIF (r.outcome = OReturn) & (r.activation = fnActivation) THEN
            r := MkVal(r.value); fnStop := TRUE
          ELSIF (r.outcome = OAgain) & (r.activation = fnActivation) THEN
            fnStop := FALSE
          ELSE
            fnStop := TRUE
          END;
          IF fnStop THEN EXIT END
        END
      END;

      FOR fnI := 0 TO fnNBind - 1 DO
        fnBindAtoms[fnI].localVal := fnSavedVals[fnI]
      END;

      IF fnIsMacro & (r.outcome = OValue) THEN
        (* Normally a macro's result is immediately re-evaluated as a new
           FORM. In expand-only mode the caller wants exactly that result,
           unevaluated — which is what the original's ZilForm.Expand
           returns, as distinct from Eval. *)
        IF myExpandOnly THEN RETURN r END;
        RETURN EvalImpl(r.value, FALSE)
      ELSE
        RETURN r
      END
    END;

    IF (head.kind # ZilObj.KSubr) & (head.kind # ZilObj.KFSubr) THEN
      RETURN Err("not an applicable type (only SUBR/FSUBR/FUNCTION/MACRO are callable so far)")
    END;

    Strings.Copy(head.atomText, name);
    isFSubr := head.kind = ZilObj.KFSubr;

    IF isFSubr & (name = "QUOTE") THEN
      n := z.rest;
      zRestFirst := n.first;
      IF zRestFirst = NIL THEN RETURN MkVal(FalseVal()) END;
      RETURN MkVal(zRestFirst)

    ELSIF isFSubr & (name = "COND") THEN
      r := MkVal(FalseVal());
      n := z.rest;
      WHILE (n # NIL) & (n.first # NIL) DO
        clause := n.first;   (* a LIST: (condition body...) *)
        IF (clause.kind # ZilObj.KList) OR ZilObj.IsEmpty(clause) THEN
          RETURN Err("COND: each clause must be a non-empty list")
        END;
        cr := EvalImpl(clause.first, FALSE);
        IF ShouldPass(cr) THEN RETURN cr END;
        IF IsTrue(cr.value) THEN
          r := cr;
          body := clause.rest;
          WHILE (body # NIL) & (body.first # NIL) DO
            r := EvalImpl(body.first, FALSE);
            IF ShouldPass(r) THEN RETURN r END;
            body := body.rest
          END;
          RETURN r
        END;
        n := n.rest
      END;
      RETURN r

    ELSIF isFSubr & (name = "VERSION?") THEN
      (* Version-conditional compilation: COND-shaped, but each clause's
         condition is a version specifier (or T/ELSE) tested against the
         program's target version rather than evaluated. Direct port of the
         original's VERSION_P (Subrs.ZModel.cs), including its result rule:
         the matching clause's last body value, or the condition itself
         when the clause has no body, or FALSE when nothing matched. *)
      r := MkVal(FalseVal());
      n := z.rest;
      WHILE (n # NIL) & (n.first # NIL) DO
        clause := n.first;
        IF (clause.kind # ZilObj.KList) OR ZilObj.IsEmpty(clause) THEN
          RETURN Err("VERSION?: each clause must be a non-empty list")
        END;
        cond := clause.first;
        matched := (cond # NIL) & (cond.kind = ZilObj.KAtom)
                   & ((cond.atomText = "T") OR (cond.atomText = "ELSE"));
        IF ~matched THEN
          ver := ParseZVersion(cond);
          IF ver = 0 THEN
            RETURN Err("VERSION?: clause condition must be a version specifier, T or ELSE")
          END;
          matched := ver = ZilModel.zversion
        END;
        IF matched THEN
          body := clause.rest;
          IF myExpandOnly THEN
            cell := ClauseBodyValue(body);
            IF cell = NIL THEN RETURN MkVal(FalseVal()) END;
            RETURN MkVal(cell)
          END;
          r := MkVal(cond);
          WHILE (body # NIL) & (body.first # NIL) DO
            r := EvalImpl(body.first, FALSE);
            IF ShouldPass(r) THEN RETURN r END;
            body := body.rest
          END;
          RETURN r
        END;
        n := n.rest
      END;
      RETURN r

    ELSIF isFSubr & (name = "IFFLAG") THEN
      (* COND over compilation flags (Subrs.Meta.cs's IFFLAG). A clause's
         condition is matched, not evaluated, in three ways, exactly as in
         the original: a bare ATOM or STRING naming a DEFINED flag matches
         when that flag's value is true; a FORM is evaluated after
         substituting every flag name appearing in it with that flag's value
         (SubstituteIfflagForm — so <AND DEBUG COLOR> tests the flags, not
         globals of the same names); anything else always matches, which is
         what makes a trailing T or ELSE clause work without special
         handling. The result is the matching clause's last body value, or
         the condition itself if the clause has no body, or FALSE. *)
      r := MkVal(FalseVal());
      n := z.rest;
      WHILE (n # NIL) & (n.first # NIL) DO
        clause := n.first;
        IF (clause.kind # ZilObj.KList) OR ZilObj.IsEmpty(clause) THEN
          RETURN Err("IFFLAG: each clause must be a non-empty list")
        END;
        cond := clause.first;
        flagVal := NIL;
        IF cond.kind = ZilObj.KAtom THEN flagVal := FlagValue(cond.atomText)
        ELSIF cond.kind = ZilObj.KString THEN flagVal := FlagValue(cond.strBuf^)
        END;

        IF flagVal # NIL THEN
          matched := IsTrue(flagVal)
        ELSIF cond.kind = ZilObj.KForm THEN
          (* substitute flag names for their values, then evaluate *)
          resultHead := NIL; resultTail := NIL;
          nFirst := cond;
          WHILE (nFirst # NIL) & (nFirst.first # NIL) DO
            flagVal := NIL;
            IF nFirst.first.kind = ZilObj.KAtom THEN flagVal := FlagValue(nFirst.first.atomText) END;
            IF flagVal = NIL THEN cell := ZilObj.Cons(ZilObj.KForm, nFirst.first, NIL)
            ELSE cell := ZilObj.Cons(ZilObj.KForm, flagVal, NIL) END;
            IF resultHead = NIL THEN resultHead := cell ELSE resultTail.rest := cell END;
            resultTail := cell;
            nFirst := nFirst.rest
          END;
          cr := EvalImpl(resultHead, FALSE);
          IF ShouldPass(cr) THEN RETURN cr END;
          matched := IsTrue(cr.value)
        ELSE
          matched := TRUE
        END;

        IF matched THEN
          body := clause.rest;
          IF myExpandOnly THEN
            cell := ClauseBodyValue(body);
            IF cell = NIL THEN RETURN MkVal(FalseVal()) END;
            RETURN MkVal(cell)
          END;
          r := MkVal(cond);
          WHILE (body # NIL) & (body.first # NIL) DO
            r := EvalImpl(body.first, FALSE);
            IF ShouldPass(r) THEN RETURN r END;
            body := body.rest
          END;
          RETURN r
        END;
        n := n.rest
      END;
      RETURN r

    ELSIF isFSubr & ((name = "ADD-TELL-TOKENS") OR (name = "TELL-TOKENS")) THEN
      (* Ported from Subrs.ZModel.cs's ADD_TELL_TOKENS/TELL_TOKENS, plus
         ZModel/TellTokens.cs's TellPattern.Parse. A spec is a flat sequence
         of token specs and output FORMs: token specs accumulate until a
         FORM that is NOT a <GVAL ...> arrives, and that FORM is the output
         for everything accumulated so far. So

           <ADD-TELL-TOKENS  T * <PRINT-DEF .X>  A * <PRINT-INDEF .X>>

         is two patterns. TELL-TOKENS replaces the whole list (including the
         built-in defaults) rather than appending, which is the only
         difference between them. An FSUBR because the token specs are
         syntax, not values — a bare `D` or `*` must not be evaluated. *)
      IF name = "TELL-TOKENS" THEN ZilModel.nTellPatterns := 0 END;
      tellToks := NIL; tellTail := NIL;
      n := z.rest;
      WHILE (n # NIL) & (n.first # NIL) DO
        nFirst := n.first;
        IF (nFirst.kind = ZilObj.KForm) & ~((ZilObj.ListLength(nFirst) = 2)
           & ZilObj.IsAtomNamed(nFirst.first, "GVAL")) THEN
          IF tellToks = NIL THEN
            RETURN Err("ADD-TELL-TOKENS: an output form with no preceding token spec")
          END;
          ZilModel.AddTellPattern(tellToks, nFirst);
          tellToks := NIL; tellTail := NIL
        ELSE
          cell := ZilObj.Cons(ZilObj.KList, nFirst, NIL);
          IF tellToks = NIL THEN tellToks := cell ELSE tellTail.rest := cell END;
          tellTail := cell
        END;
        n := n.rest
      END;
      IF tellToks # NIL THEN
        RETURN Err("ADD-TELL-TOKENS: spec ends with an unterminated pattern")
      END;
      RETURN MkVal(TrueVal())

    ELSIF isFSubr & (name = "FUNCTION") THEN
      (* <FUNCTION (argspec) body...> is an anonymous DEFINE — the same
         KFunction value, just never bound to a name. Real source passes one
         straight to MAPF. An optional leading activation atom is accepted
         for the same reason DEFINE accepts one. *)
      n := z.rest;
      fnActivation := NIL;
      IF (n # NIL) & (n.first # NIL) & (n.first.kind = ZilObj.KAtom) THEN
        fnActivation := n.first; n := n.rest
      END;
      IF (n = NIL) OR (n.first = NIL) OR (n.first.kind # ZilObj.KList) THEN
        RETURN Err("FUNCTION: expected an argument-spec list")
      END;
      RETURN MkVal(ZilObj.NewFunction(n.first, fnActivation, n.rest))

    ELSIF isFSubr & (name = "DEFSTRUCT") THEN
      n := z.rest;
      IF (n = NIL) OR (n.first = NIL) OR (n.first.kind # ZilObj.KAtom) THEN
        RETURN Err("DEFSTRUCT: expected a structure name")
      END;
      Strings.Copy(n.first.atomText, dsName);
      n := n.rest;
      IF (n = NIL) OR (n.first = NIL) THEN
        RETURN Err("DEFSTRUCT: expected a base type")
      END;

      (* base type, plus the option clauses that may accompany it *)
      Strings.Copy("NTH", dsNth); Strings.Copy("PUT", dsPut); dsOffset := 1;
      IF n.first.kind = ZilObj.KAtom THEN
        Strings.Copy(n.first.atomText, dsBase)
      ELSIF n.first.kind = ZilObj.KList THEN
        IF (n.first.first = NIL) OR (n.first.first.kind # ZilObj.KAtom) THEN
          RETURN Err("DEFSTRUCT: the base-type list must start with a type atom")
        END;
        Strings.Copy(n.first.first.atomText, dsBase);
        dsOpt := n.first.rest;
        WHILE (dsOpt # NIL) & (dsOpt.first # NIL) DO
          IF (dsOpt.first.kind # ZilObj.KList) OR (dsOpt.first.first = NIL) THEN
            RETURN Err("DEFSTRUCT: base-type options must be lists")
          END;
          dsClause := dsOpt.first;
          (* each clause reads ('TAG value), i.e. <QUOTE TAG> then a value *)
          IF (dsClause.first.kind # ZilObj.KForm) OR (ZilObj.ListLength(dsClause.first) # 2)
             OR ~ZilObj.IsAtomNamed(dsClause.first.first, "QUOTE")
             OR (dsClause.first.rest.first.kind # ZilObj.KAtom) THEN
            RETURN Err("DEFSTRUCT: a base-type option must start with a quoted atom")
          END;
          Strings.Copy(dsClause.first.rest.first.atomText, dsTag);
          dsVal := NIL;
          IF dsClause.rest # NIL THEN dsVal := dsClause.rest.first END;
          IF dsTag = "NTH" THEN
            IF (dsVal = NIL) OR (dsVal.kind # ZilObj.KAtom) THEN
              RETURN Err("DEFSTRUCT: 'NTH expects an atom") END;
            Strings.Copy(dsVal.atomText, dsNth)
          ELSIF dsTag = "PUT" THEN
            IF (dsVal = NIL) OR (dsVal.kind # ZilObj.KAtom) THEN
              RETURN Err("DEFSTRUCT: 'PUT expects an atom") END;
            Strings.Copy(dsVal.atomText, dsPut)
          ELSIF dsTag = "START-OFFSET" THEN
            IF (dsVal = NIL) OR (dsVal.kind # ZilObj.KFix) THEN
              RETURN Err("DEFSTRUCT: 'START-OFFSET expects a FIX") END;
            dsOffset := dsVal.fixVal
          ELSIF (dsTag = "NODECL") OR (dsTag = "NOTYPE") THEN
            (* nothing to suppress: this port has no DECL checking or type
               registry in the first place *)
          ELSE
            RETURN Err("DEFSTRUCT: unsupported base-type option (only 'NTH/'PUT/'START-OFFSET)")
          END;
          dsOpt := dsOpt.rest
        END
      ELSE
        RETURN Err("DEFSTRUCT: expected a base type or a base-type list")
      END;

      IF nStructs >= MaxStructs THEN RETURN Err("DEFSTRUCT: too many structures") END;
      dsIdx := nStructs; INC(nStructs);
      Strings.Copy(dsName, structs[dsIdx].name);
      structs[dsIdx].baseIsVector := dsBase = "VECTOR";
      structs[dsIdx].startOffset := dsOffset;
      structs[dsIdx].nFields := 0;

      (* field definitions *)
      n := n.rest;
      WHILE (n # NIL) & (n.first # NIL) DO
        IF (n.first.kind # ZilObj.KList) OR (n.first.first = NIL)
           OR (n.first.first.kind # ZilObj.KAtom) THEN
          RETURN Err("DEFSTRUCT: each field must be a list starting with its name")
        END;
        Strings.Copy(n.first.first.atomText, dsFieldName);
        Strings.Copy(dsNth, dsFNth); Strings.Copy(dsPut, dsFPut);
        dsFOffset := dsOffset; dsGotOffset := FALSE;

        (* skip the field's DECL, then read its option clauses, which are a
           flat 'TAG value sequence rather than lists *)
        dsOpt := n.first.rest;
        IF (dsOpt # NIL) & (dsOpt.first # NIL) THEN dsOpt := dsOpt.rest END;
        WHILE (dsOpt # NIL) & (dsOpt.first # NIL) DO
          dsClause := dsOpt.first;
          IF (dsClause.kind = ZilObj.KForm) & (ZilObj.ListLength(dsClause) = 2)
             & ZilObj.IsAtomNamed(dsClause.first, "QUOTE")
             & (dsClause.rest.first.kind = ZilObj.KAtom) THEN
            Strings.Copy(dsClause.rest.first.atomText, dsTag);
            dsOpt := dsOpt.rest;
            dsVal := NIL;
            IF (dsOpt # NIL) & (dsOpt.first # NIL) THEN dsVal := dsOpt.first END;
            IF dsTag = "NTH" THEN
              IF (dsVal = NIL) OR (dsVal.kind # ZilObj.KAtom) THEN
                RETURN Err("DEFSTRUCT: 'NTH expects an atom") END;
              Strings.Copy(dsVal.atomText, dsFNth); dsOpt := dsOpt.rest
            ELSIF dsTag = "PUT" THEN
              IF (dsVal = NIL) OR (dsVal.kind # ZilObj.KAtom) THEN
                RETURN Err("DEFSTRUCT: 'PUT expects an atom") END;
              Strings.Copy(dsVal.atomText, dsFPut); dsOpt := dsOpt.rest
            ELSIF dsTag = "OFFSET" THEN
              IF (dsVal = NIL) OR (dsVal.kind # ZilObj.KFix) THEN
                RETURN Err("DEFSTRUCT: 'OFFSET expects a FIX") END;
              dsFOffset := dsVal.fixVal; dsGotOffset := TRUE; dsOpt := dsOpt.rest
            ELSIF dsTag = "NONE" THEN
              (* "this field has no default" — nothing to record, since
                 per-field defaults aren't ported *)
            ELSE
              RETURN Err("DEFSTRUCT: unsupported field option (only 'NTH/'PUT/'OFFSET/'NONE)")
            END
          ELSE
            (* a bare value is the field's default, which isn't ported *)
            dsOpt := dsOpt.rest
          END
        END;

        IF structs[dsIdx].nFields >= MaxStructFields THEN
          RETURN Err("DEFSTRUCT: too many fields")
        END;
        Strings.Copy(dsFieldName, structs[dsIdx].fieldName[structs[dsIdx].nFields]);
        structs[dsIdx].fieldOffset[structs[dsIdx].nFields] := dsFOffset;
        Strings.Copy(dsFPut, structs[dsIdx].fieldPut[structs[dsIdx].nFields]);
        INC(structs[dsIdx].nFields);

        IF ~dsGotOffset THEN INC(dsOffset) END;

        (* generate and evaluate this field's accessor macro *)
        Strings.Copy("<DEFMAC ", dsSrc);
        Strings.Append(dsFieldName, dsSrc);
        Strings.Append(" ('S ", dsSrc);
        dsQ[0] := '"'; dsQ[1] := 0X;
        Strings.Append(dsQ, dsSrc); Strings.Append("OPT", dsSrc); Strings.Append(dsQ, dsSrc);
        Strings.Append(" 'NV) <COND (<ASSIGNED? NV> <FORM ", dsSrc);
        Strings.Append(dsFPut, dsSrc); Strings.Append(" .S ", dsSrc);
        Strings.IntToStr(dsFOffset, dsNum); Strings.Append(dsNum, dsSrc);
        Strings.Append(" .NV>) (T <FORM ", dsSrc);
        Strings.Append(dsFNth, dsSrc); Strings.Append(" .S ", dsSrc);
        Strings.Append(dsNum, dsSrc); Strings.Append(">)>>", dsSrc);

        ZilRead.OpenString(insRd, dsSrc);
        insZ := ZilRead.ReadOne(insRd, insOk, insDone, insIsTerm, insTermCh);
        ZilRead.Close(insRd);
        IF ~insOk OR insDone THEN
          RETURN Err("DEFSTRUCT: could not parse a generated accessor macro")
        END;
        r := EvalImpl(insZ, FALSE);
        IF (r.outcome # OValue) OR evalErrFlag THEN RETURN r END;

        n := n.rest
      END;
      RETURN MkVal(ZilObj.Intern(dsName))

    ELSIF isFSubr & (name = "GDECL") THEN
      (* <GDECL (ATOM ATOM ...) decl ...> attaches DECL type constraints to
         globals. This port skips DECL checking entirely (an explicit
         simplification from phase 1 — see the plan doc), so the original's
         only effect here, storing the DECL on each global's binding, has
         nothing to store it for. An FSUBR that accepts and discards its
         arguments, returning T, is therefore the faithful reduction rather
         than a stub: source that uses GDECL compiles, and nothing that
         depends on the result is affected. *)
      RETURN MkVal(TrueVal())

    ELSIF isFSubr & (name = "AND") THEN
      r := MkVal(TrueVal());
      n := z.rest;
      WHILE (n # NIL) & (n.first # NIL) DO
        r := EvalImpl(n.first, FALSE);
        IF ShouldPass(r) THEN RETURN r END;
        IF ~IsTrue(r.value) THEN RETURN r END;
        n := n.rest
      END;
      RETURN r

    ELSIF isFSubr & (name = "OR") THEN
      r := MkVal(FalseVal());
      n := z.rest;
      WHILE (n # NIL) & (n.first # NIL) DO
        r := EvalImpl(n.first, FALSE);
        IF ShouldPass(r) THEN RETURN r END;
        IF IsTrue(r.value) THEN RETURN r END;
        n := n.rest
      END;
      RETURN r

    ELSIF isFSubr & (name = "QUASIQUOTE") THEN
      (* `X reads as <QUASIQUOTE X> (see ZilRead.mod) — switch into
         quasiquote-walk mode for X; see the dedicated comment at the top
         of this procedure's body for what that mode does. *)
      RETURN EvalImpl(z.rest.first, TRUE)

    ELSIF isFSubr & ((name = "PROG") OR (name = "REPEAT") OR (name = "BIND")) THEN
      (* <[PROG|REPEAT|BIND] [name] (binding...) body...>. A binding is an
         ATOM (starts unassigned), an ADECL atom:decl (decl ignored, same
         as elsewhere in this port), or a 2-element LIST (atom-or-adecl
         initializer). PROG/REPEAT rebind the internal `enclosingProgAtom`
         to this activation so a bare RETURN/AGAIN finds it (BIND does
         not — see the field's own comment); REPEAT always loops again
         after a full body pass unless something escapes (a bare RETURN
         is the normal way out). Every bound atom's PREVIOUS localVal
         (including the optional named-activation atom and, for PROG/
         REPEAT, enclosingProgAtom itself) is saved up front and restored
         in one pass right before this branch returns — Oberon has no
         try/finally, so this is done by falling through to a single
         shared restore-then-return tail (via `progStop`/EXIT) instead of
         returning early from inside the loops below. *)
      progRepeat := (name = "REPEAT");
      progCatchy := (name # "BIND");

      progArgs := z.rest;
      IF (progArgs = NIL) OR (progArgs.first = NIL) THEN
        RETURN Err("PROG/REPEAT/BIND: missing bindings list")
      END;

      progNameAtom := NIL;
      IF progArgs.first.kind = ZilObj.KAtom THEN
        progNameAtom := progArgs.first;
        progArgs := progArgs.rest
      END;

      IF (progArgs = NIL) OR (progArgs.first = NIL) OR (progArgs.first.kind # ZilObj.KList) THEN
        RETURN Err("PROG/REPEAT/BIND: expected a bindings list")
      END;
      progBindings := progArgs.first;
      progBody := progArgs.rest;
      IF (progBody = NIL) OR (progBody.first = NIL) THEN
        RETURN Err("PROG/REPEAT/BIND: empty body")
      END;

      progAct := ZilObj.NewActivation(name);
      progNBind := 0;
      progStop := FALSE;

      IF progNameAtom # NIL THEN
        progBindAtoms[progNBind] := progNameAtom;
        progSavedVals[progNBind] := progNameAtom.localVal;
        progNameAtom.localVal := progAct;
        INC(progNBind)
      END;

      progBP := progBindings;
      WHILE (progBP # NIL) & (progBP.first # NIL) & ~progStop DO
        progOneBind := progBP.first;
        progTarget := NIL; progInit := NIL;
        IF progOneBind.kind = ZilObj.KAtom THEN
          progTarget := progOneBind
        ELSIF progOneBind.kind = ZilObj.KAdecl THEN
          progTarget := progOneBind.adFirst
        ELSIF (progOneBind.kind = ZilObj.KList) & (ZilObj.ListLength(progOneBind) = 2) THEN
          progBindFirst := progOneBind.first;
          IF progBindFirst.kind = ZilObj.KAdecl THEN progTarget := progBindFirst.adFirst
          ELSE progTarget := progBindFirst END;
          progInit := progOneBind.rest.first
        ELSE
          RETURN Err("PROG/REPEAT/BIND: malformed binding")
        END;
        IF (progTarget = NIL) OR (progTarget.kind # ZilObj.KAtom) THEN
          RETURN Err("PROG/REPEAT/BIND: binding target must be an ATOM")
        END;
        IF progNBind >= MaxBindings THEN RETURN Err("PROG/REPEAT/BIND: too many bindings") END;

        progBindAtoms[progNBind] := progTarget;
        progSavedVals[progNBind] := progTarget.localVal;
        INC(progNBind);

        IF progInit # NIL THEN
          r := EvalImpl(progInit, FALSE);
          IF (r.outcome = OReturn) & (r.activation = progAct) THEN
            r := MkVal(r.value); progStop := TRUE
          ELSIF evalErrFlag OR (r.outcome # OValue) THEN
            progStop := TRUE
          ELSE
            progTarget.localVal := r.value
          END
        ELSE
          progTarget.localVal := NIL
        END;

        progBP := progBP.rest
      END;

      IF ~progStop THEN
        IF progCatchy THEN
          progBindAtoms[progNBind] := enclosingProgAtom;
          progSavedVals[progNBind] := enclosingProgAtom.localVal;
          enclosingProgAtom.localVal := progAct;
          INC(progNBind)
        END;

        LOOP
          progAgain := FALSE;
          progBP := progBody;
          WHILE (progBP # NIL) & (progBP.first # NIL) DO
            r := EvalImpl(progBP.first, FALSE);
            IF (r.outcome = OAgain) & (r.activation = progAct) THEN
              progAgain := TRUE
            ELSIF (r.outcome = OReturn) & (r.activation = progAct) THEN
              r := MkVal(r.value); progStop := TRUE; EXIT
            ELSIF evalErrFlag OR (r.outcome # OValue) THEN
              (* An evaluation error is reported through evalErrFlag, not
                 through the outcome (Err returns an ordinary OValue FALSE) -
                 see Err's own comment. Without this check, a REPEAT whose
                 body errors on every pass (zork1's MULTIFROB macro helper
                 hits this: its exit condition calls the not-yet-implemented
                 atom RETURN!- once ATMS is empty) never stops: progRepeat
                 is TRUE and the outcome always reads back as an ordinary
                 value, so the loop just re-runs the same failing statement
                 forever, burning CPU and growing memory without bound
                 instead of surfacing the error. *)
              progStop := TRUE; EXIT
            END;
            progBP := progBP.rest
          END;
          IF progStop THEN EXIT END;
          IF ~(progRepeat OR progAgain) THEN EXIT END
        END
      END;

      FOR progI := 0 TO progNBind - 1 DO
        progBindAtoms[progI].localVal := progSavedVals[progI]
      END;

      RETURN r

    ELSIF isFSubr & (name = "DEFMAC") THEN
      RETURN ApplyDefine(TRUE, z.rest)

    ELSIF isFSubr & ((name = "DEFINE") OR (name = "DEFINE20")) THEN
      RETURN ApplyDefine(FALSE, z.rest)

    ELSIF isFSubr & (name = "ROUTINE") THEN
      RETURN ApplyRoutine(z.rest)

    ELSIF isFSubr & ((name = "OBJECT") OR (name = "ROOM")) THEN
      (* The original registers OBJECT and ROOM as [Subr]s, i.e. with
         EVALUATED arguments, and that matters: zillib writes
         <OBJECT ROOMS ... (FLAGS !,KNOWN-FLAGS)>, and it is list evaluation
         that splices that segment into the flag list. Every other element
         of a property list (atoms, strings, numbers) self-evaluates, so
         evaluating them changes nothing else.

         They stay FSUBRs here only so the property lists can be evaluated
         one at a time, each as a LIST — which is exactly what a SUBR's
         argument evaluation would do, minus needing the arguments to fit in
         the fixed argument array. *)
      objProps := NIL; objTail := NIL;
      n := z.rest;
      IF (n = NIL) OR (n.first = NIL) THEN RETURN Err("OBJECT/ROOM: expected a name") END;
      cell := ZilObj.Cons(ZilObj.KList, n.first, NIL);
      objProps := cell; objTail := cell;
      n := n.rest;
      WHILE (n # NIL) & (n.first # NIL) DO
        r := EvalImpl(n.first, FALSE);
        IF ShouldPass(r) THEN RETURN r END;
        IF evalErrFlag THEN RETURN r END;
        IF (r.value # NIL) & (r.value.kind = ZilObj.KSplice) THEN
          (* A property-list position that evaluated to a SPLICE (real
             source: `%<VERSION? (ZIP <LIST DESC ...>) (ELSE #SPLICE ())>`
             as one whole property, not a value inside one — parser.zil's
             ROOMS object does exactly this) contributes its OWN members at
             this position, not the splice marker itself; an empty splice
             contributes none. Left unflattened, this cell held a KSplice
             where ApplyObject expects a KList and rejected it — the
             ADJACENT-to-a-value case (a segment spliced INTO a property's
             value list, e.g. `(FLAGS !,KNOWN-FLAGS)`) is unaffected, since
             that splice lives inside n.first's own evaluation, not at this
             top level. *)
          splice := r.value;
          WHILE (splice # NIL) & (splice.first # NIL) DO
            cell := ZilObj.Cons(ZilObj.KList, splice.first, NIL);
            objTail.rest := cell; objTail := cell;
            splice := splice.rest
          END
        ELSE
          cell := ZilObj.Cons(ZilObj.KList, r.value, NIL);
          objTail.rest := cell; objTail := cell
        END;
        n := n.rest
      END;
      RETURN ApplyObject(name = "ROOM", objProps)

    ELSIF isFSubr & (name = "PROPDEF") THEN
      (* <PROPDEF name default-value [complex-spec...]>. Ported from
         Subrs.ZModel.cs's PROPDEF: an FSUBR (name and the complex spec
         are raw/unevaluated; only default-value is explicitly Eval'd
         inside the SUBR body in the original, so this needs to call
         EvalImpl — same forward-reference reason as INSERT-FILE/
         DEFAULT-DEFINITION). By far the common real-source shape has no
         complex spec at all (e.g. zork1.zil's own <PROPDEF SIZE 5>) —
         see ZilModel.mod's PropDefaultRec/PropDefSpecRec comment for why
         the rarer complex-pattern case is just captured raw rather than
         parsed now. Replicates the original's one special case exactly:
         a <PROPDEF DIRECTIONS <> (DIR ...)> (FALSE default, a spec
         present) registers the complex pattern WITHOUT also registering
         DIRECTIONS as a real property default, since DIRECTIONS isn't a
         real property in that form. *)
      IF (z.rest = NIL) OR (z.rest.first = NIL) OR (z.rest.first.kind # ZilObj.KAtom) THEN
        RETURN Err("PROPDEF: expected a property-name atom")
      END;
      pdName := z.rest.first;
      pdRest := z.rest.rest;
      IF (pdRest = NIL) OR (pdRest.first = NIL) THEN
        RETURN Err("PROPDEF: expected a default value")
      END;
      r := EvalImpl(pdRest.first, FALSE);
      IF r.outcome # OValue THEN RETURN r END;
      pdSpec := pdRest.rest;

      IF ~(ZilObj.IsAtomNamed(pdName, "DIRECTIONS") & ~IsTrue(r.value)
           & (pdSpec # NIL) & (pdSpec.first # NIL)) THEN
        ZilModel.AddPropDefault(pdName, r.value)
      END;
      IF (pdSpec # NIL) & (pdSpec.first # NIL) THEN
        ZilModel.AddPropDefSpec(pdName, pdSpec)
      END;
      RETURN MkVal(pdName)

    ELSIF isFSubr & ((name = "DEFAULT-DEFINITION") OR (name = "REPLACE-DEFINITION")) THEN
      (* Ported from Subrs.Meta.cs's DEFAULT_DEFINITION/REPLACE_DEFINITION:
         a "hooks" mechanism library files use to let a game override a
         default definition before or after it's encountered. State is
         tracked via PUTPROP/GETPROP on `name`, using the indicator atom
         "REPLACE-DEFINITION" — the SAME atom is also one of the possible
         STATE VALUES (self-referential terminal marker for "already
         inserted"), exactly matching the original's own reuse of
         StdAtom.REPLACE_DEFINITION in both roles. A pending replacement
         body (from REPLACE-DEFINITION arriving before the matching
         DEFAULT-DEFINITION) is stashed as a VECTOR (ChainToVector),
         matching the original's own choice of ZilVector for this state.
         Needs to call EvalImpl on the body forms actually inserted, so —
         same forward-reference reason as INSERT-FILE/PROG — this is
         inlined here rather than a separate procedure. *)
      IF (z.rest = NIL) OR (z.rest.first = NIL) OR (z.rest.first.kind # ZilObj.KAtom) THEN
        RETURN Err("DEFAULT-DEFINITION/REPLACE-DEFINITION: expected a name atom")
      END;
      defName := z.rest.first;
      defBody := z.rest.rest;
      IF (defBody = NIL) OR (defBody.first = NIL) THEN
        RETURN Err("DEFAULT-DEFINITION/REPLACE-DEFINITION: empty body")
      END;
      defInd := ZilObj.Intern("REPLACE-DEFINITION");
      defState := ZilObj.GetProp(defName, defInd);

      IF name = "REPLACE-DEFINITION" THEN
        IF defState = NIL THEN
          ZilObj.PutProp(defName, defInd, ChainToVector(defBody));
          RETURN MkVal(defName)
        ELSIF defState = ZilObj.Intern("DELAY-DEFINITION") THEN
          ZilObj.PutProp(defName, defInd, defInd);
          r := MkVal(defName);
          defP := defBody;
          WHILE (defP # NIL) & (defP.first # NIL) DO
            r := EvalImpl(defP.first, FALSE);
            IF r.outcome # OValue THEN EXIT END;
            defP := defP.rest
          END;
          RETURN r
        ELSIF (defState = defInd) OR (defState = ZilObj.Intern("DEFAULT-DEFINITION")) THEN
          RETURN ErrAtom("REPLACE-DEFINITION: section has already been inserted:", defName)
        ELSIF defState.kind = ZilObj.KVector THEN
          RETURN ErrAtom("REPLACE-DEFINITION: duplicate replacement for section:", defName)
        ELSE
          RETURN ErrAtom("REPLACE-DEFINITION: bad state for section:", defName)
        END

      ELSE (* DEFAULT-DEFINITION *)
        IF defState = NIL THEN
          ZilObj.PutProp(defName, defInd, ZilObj.Intern("DEFAULT-DEFINITION"));
          r := MkVal(defName);
          defP := defBody;
          WHILE (defP # NIL) & (defP.first # NIL) DO
            r := EvalImpl(defP.first, FALSE);
            IF r.outcome # OValue THEN EXIT END;
            defP := defP.rest
          END;
          RETURN r
        ELSIF (defState = defInd) OR (defState = ZilObj.Intern("DELAY-DEFINITION")) THEN
          RETURN MkVal(defName)
        ELSIF defState.kind = ZilObj.KVector THEN
          ZilObj.PutProp(defName, defInd, defInd);
          r := MkVal(defName);
          FOR defI := 0 TO defState.vecLen - 1 DO
            r := EvalImpl(defState.vecItems[defI], FALSE);
            IF r.outcome # OValue THEN RETURN r END
          END;
          RETURN r
        ELSIF defState = ZilObj.Intern("DEFAULT-DEFINITION") THEN
          RETURN ErrAtom("DEFAULT-DEFINITION: duplicate default for section:", defName)
        ELSE
          RETURN ErrAtom("DEFAULT-DEFINITION: bad state for section:", defName)
        END
      END

    ELSIF isFSubr THEN
      RETURN Err("unrecognized or not-yet-implemented FSUBR")

    ELSE
      (* plain SUBR: evaluate all args left-to-right, then dispatch *)
      nargs := 0;
      n := z.rest;
      WHILE (n # NIL) & (n.first # NIL) DO
        IF n.first.kind = ZilObj.KSegment THEN
          (* !<...> / !.X splices a structure's elements in as separate
             arguments — <FORM PROG '() !.O> is the idiom real source uses
             to build a form from a computed list of body statements *)
          r := EvalImpl(n.first.segForm, FALSE);
          IF ShouldPass(r) THEN RETURN r END;
          IF evalErrFlag THEN RETURN r END;
          IF ~IsStructured(r.value) THEN
            RETURN ErrAtom("SEGMENT: expected a structured value to splice, got", r.value)
          END;
          segLen := StructLength(r.value);
          FOR segI := 1 TO segLen DO
            IF nargs < MaxArgs THEN args[nargs] := StructNth(r.value, segI); INC(nargs) END
          END
        ELSE
          r := EvalImpl(n.first, FALSE);
          IF ShouldPass(r) THEN RETURN r END;
          IF (r.value # NIL) & (r.value.kind = ZilObj.KSplice) THEN
            (* A macro whose result is a SPLICE contributes its ELEMENTS as
               separate arguments, not the splice itself - the same rule
               ExpandTree applies to a routine body, and the original's for
               any evaluated sequence. zillib relies on it outside a routine
               too: <CONSTANT TRY-REPHRASING-CMD <LIBRARY-MESSAGE ORPHANING
               TRY-REPHRASING>> is a STRING constant only because the
               message's one-element SPLICE collapses into CONSTANT's second
               argument. *)
            segLen := StructLength(r.value);
            FOR segI := 1 TO segLen DO
              IF nargs < MaxArgs THEN args[nargs] := StructNth(r.value, segI); INC(nargs) END
            END
          ELSIF nargs < MaxArgs THEN
            args[nargs] := r.value; INC(nargs)
          END
        END;
        n := n.rest
      END;

      IF (name = "INSERT-FILE") OR (name = "FLOAD") OR (name = "XFLOAD") THEN
        (* Ported from Subrs.Meta.cs's INSERT-FILE/PerformLoadFile — the
           finding-and-loading itself is LoadFile above, shared with
           USE/INCLUDE. Stays here rather than in ApplySubr only because
           ApplySubr is the "doesn't call Eval" half of the dispatch. *)
        IF (nargs < 1) OR (args[0].kind # ZilObj.KString) THEN
          RETURN Err("INSERT-FILE: expected a STRING filename")
        END;
        r := LoadFile(args[0].strBuf^, "INSERT-FILE", insOpened);
        IF ~insOpened THEN RETURN ErrAtom("INSERT-FILE: file not found:", args[0]) END;
        RETURN r

      ELSIF (name = "USE") OR (name = "INCLUDE") OR (name = "USE-WHEN") OR (name = "INCLUDE-WHEN") THEN
        (* Ported from Subrs.Packages.cs's PerformUse. The original adds each
           named package's external oblist to the current lookup path,
           loading the package from a file first if it isn't defined yet.
           With one flat atom table (see PACKAGE in ApplySubr for why) the
           path manipulation is a no-op and only the LOADING matters — which
           is the part real source actually depends on: <USE "LIBMSG"> is
           how zillib/parser.zil pulls in libmsg.zil at all.

           USE-WHEN/INCLUDE-WHEN take a leading condition and do nothing
           when it's false. INCLUDE differs from USE only in requiring a
           DEFINITIONS-type rather than PACKAGE-type package, a distinction
           that needs the per-oblist PACKAGE property this port doesn't
           keep; treated as a synonym. Has to live here rather than in
           ApplySubr because loading a package means evaluating its
           contents. *)
        usePos := 0;
        IF (name = "USE-WHEN") OR (name = "INCLUDE-WHEN") THEN
          IF nargs < 1 THEN RETURN Err("USE-WHEN: expected a condition") END;
          IF ~IsTrue(args[0]) THEN RETURN MkVal(args[0]) END;
          usePos := 1
        END;
        WHILE usePos < nargs DO
          IF args[usePos].kind # ZilObj.KString THEN
            RETURN Err("USE/INCLUDE: expected STRING package names")
          END;
          Strings.Copy(args[usePos].strBuf^, useName);
          IF ~PackageDefined(useName) & ~BuiltinPackage(useName) THEN
            r := LoadFile(useName, "USE", useFound);
            IF ~useFound THEN
              RETURN ErrAtom("USE: unrecognized package (no such package or file):", args[usePos])
            END;
            IF (r.outcome # OValue) OR evalErrFlag THEN RETURN r END;
            IF ~PackageDefined(useName) THEN
              (* the file loaded but never declared the package — the
                 original reports the same thing as "unrecognized package" *)
              RETURN ErrAtom("USE: file loaded but defines no such package:", args[usePos])
            END
          END;
          INC(usePos)
        END;
        RETURN MkVal(TrueVal())

      ELSIF (name = "APPLY") OR (name = "APPLY-MACRO") THEN
        IF nargs < 1 THEN RETURN Err("APPLY: expected an applicable value") END;
        FOR mapI := 1 TO nargs - 1 DO mapArgs[mapI - 1] := args[mapI] END;
        RETURN ApplyValue(args[0], mapArgs, nargs - 1)

      ELSIF (name = "MAPRET") OR (name = "MAPSTOP") OR (name = "MAPLEAVE") THEN
        (* MAPF's control flow. These propagate out of the loop function the
           way RETURN propagates out of a PROG; the enclosing MAPF catches
           them. More than one value isn't supported — the original lets
           MAPRET/MAPSTOP contribute any number, but real source only ever
           uses zero or one, and a ZResult carries one value. *)
        r.activation := NIL;
        mapRetList := NIL;
        IF nargs = 1 THEN
          r.value := args[0]
        ELSE
          r.value := NIL;
          IF nargs > 1 THEN
            (* more than one value: a ZResult carries one, so the rest ride
               in mapRetList, which the enclosing MAPF drains. zillib's
               pronouns.zil really does <MAPRET a b c> to contribute three
               statements per iteration. *)
            resultHead := NIL; resultTail := NIL;
            FOR mapI := 0 TO nargs - 1 DO
              cell := ZilObj.Cons(ZilObj.KList, args[mapI], NIL);
              IF resultHead = NIL THEN resultHead := cell ELSE resultTail.rest := cell END;
              resultTail := cell
            END;
            mapRetList := resultHead
          END
        END;
        IF name = "MAPRET" THEN r.outcome := OMapRet
        ELSIF name = "MAPSTOP" THEN r.outcome := OMapStop
        ELSE r.outcome := OMapLeave
        END;
        RETURN r

      ELSIF (name = "MAPF") OR (name = "MAPR") THEN
        (* <MAPF final loop struct...> applies `loop` to successive elements
           of the structures in parallel, collects the values it returns,
           and finally applies `final` to all of them at once. A FALSE
           `final` discards the results (the original's own <> case), and
           ,LIST is what makes <MAPF ,LIST ...> build a list.

           With NO structures at all, `loop` is called with no arguments
           until it says to stop — an idiom real source really uses as a
           generator (sample/name's TELL macro walks its own argument list
           that way). MAPR differs by passing the REST of each structure
           rather than the element; both share this code.

           Has to live here rather than in ApplySubr because it calls the
           loop function, which means evaluating. *)
        IF nargs < 2 THEN RETURN Err("MAPF: expected a final and a loop function") END;
        mapIsMapR := name = "MAPR";
        mapNStruct := nargs - 2;
        mapCount := -1;
        FOR mapI := 0 TO mapNStruct - 1 DO
          IF ~IsStructured(args[mapI + 2]) THEN
            RETURN Err("MAPF: arguments after the loop function must be structures")
          END;
          mapStructs[mapI] := args[mapI + 2];
          mapLen := StructLength(mapStructs[mapI]);
          IF (mapCount < 0) OR (mapLen < mapCount) THEN mapCount := mapLen END
        END;

        mapHead := NIL; mapTail := NIL; mapStop := FALSE; mapPos := 0;
        r := MkVal(FalseVal());
        WHILE ~mapStop & ((mapNStruct = 0) OR (mapPos < mapCount)) DO
          IF mapNStruct > 0 THEN
            FOR mapI := 0 TO mapNStruct - 1 DO
              IF mapIsMapR THEN mapArgs[mapI] := StructRest(mapStructs[mapI], mapPos)
              ELSE mapArgs[mapI] := StructNth(mapStructs[mapI], mapPos + 1) END
            END
          END;
          r := ApplyValue(args[1], mapArgs, mapNStruct);
          IF evalErrFlag THEN RETURN r END;

          IF (r.outcome = OMapRet) OR (r.outcome = OMapStop) THEN
            (* drain any extra values the map form supplied *)
            WHILE (mapRetList # NIL) & (mapRetList.first # NIL) DO
              cell := ZilObj.Cons(ZilObj.KList, mapRetList.first, NIL);
              IF mapHead = NIL THEN mapHead := cell ELSE mapTail.rest := cell END;
              mapTail := cell;
              mapRetList := mapRetList.rest
            END;
            mapRetList := NIL
          END;

          IF r.outcome = OMapLeave THEN
            IF r.value = NIL THEN RETURN MkVal(FalseVal()) END;
            RETURN MkVal(r.value)
          ELSIF r.outcome = OMapStop THEN
            IF r.value # NIL THEN
              cell := ZilObj.Cons(ZilObj.KList, r.value, NIL);
              IF mapHead = NIL THEN mapHead := cell ELSE mapTail.rest := cell END;
              mapTail := cell
            END;
            mapStop := TRUE
          ELSIF r.outcome = OMapRet THEN
            IF r.value # NIL THEN
              cell := ZilObj.Cons(ZilObj.KList, r.value, NIL);
              IF mapHead = NIL THEN mapHead := cell ELSE mapTail.rest := cell END;
              mapTail := cell
            END
          ELSIF r.outcome # OValue THEN
            RETURN r     (* a RETURN/AGAIN passing through *)
          ELSE
            cell := ZilObj.Cons(ZilObj.KList, r.value, NIL);
            IF mapHead = NIL THEN mapHead := cell ELSE mapTail.rest := cell END;
            mapTail := cell
          END;
          INC(mapPos)
        END;

        (* apply the final function to everything collected *)
        IF (args[0] = NIL) OR (args[0].kind = ZilObj.KFalse) THEN
          RETURN MkVal(FalseVal())
        END;
        mapI := 0;
        mapCell := mapHead;
        WHILE (mapCell # NIL) & (mapCell.first # NIL) & (mapI < MaxArgs) DO
          mapArgs[mapI] := mapCell.first; INC(mapI);
          mapCell := mapCell.rest
        END;
        RETURN ApplyValue(args[0], mapArgs, mapI)

      ELSIF name = "EXPAND" THEN
        (* <EXPAND form> expands a macro call one level and returns the
           expansion WITHOUT evaluating it — the same distinction
           ZilForm.Expand draws against Eval, and exactly what ExpandOnce
           provides for compiling routine bodies. *)
        IF nargs < 1 THEN RETURN Err("EXPAND: expected a form") END;
        RETURN ExpandOnce(args[0])

      ELSIF (name = "EVAL") OR (name = "EVAL-IN-SEGMENT") THEN
        (* <EVAL expr [environment]>: evaluates the (already-once-
           evaluated, since this is a SUBR) expr a second time — the
           common real-source pattern is building a FORM at runtime (e.g.
           via a quasiquote template or FORM/LIST) and then EVAL'ing it,
           exactly the same "expand, then evaluate the expansion" shape
           already used for macros. The original's EVAL takes an explicit
           LocalEnvironment argument; this port has no first-class
           environment objects (that concept was flattened away back in
           phase 2 — see ZilEval.mod's own header note), so a second
           argument, if given, is accepted but ignored — pragmatic
           subset, matches real usage (`<EVAL .RTN>` with no environment
           argument is by far the common case in real source). Has to be
           inlined here rather than an ApplySubr case since it needs to
           call EvalImpl — same forward-reference reason as INSERT-FILE. *)
        IF nargs < 1 THEN RETURN Err("EVAL: expected at least 1 arg") END;
        RETURN EvalImpl(args[0], FALSE)

      ELSE
        RETURN ApplySubr(name, args, nargs)
      END
    END

  ELSE
    RETURN MkVal(z)
  END
END EvalImpl;

(* ---------------- compile-time macro expansion ----------------
   A ROUTINE's body is captured raw and unevaluated at registration time,
   so any DEFMAC used inside it is still sitting there as an unexpanded
   FORM when the compiler comes to it. The original expands them as the
   first step of compiling a routine (ZilRoutine.ExpandInPlace, called from
   Compilation.Compile.cs); ExpandTree below is the same walk, and
   ZilCompile.CompileRoutine calls it before compiling anything.

   Expansion is NOT evaluation: <TELL "hi"> must turn into the code the
   macro produces, not run it. ExpandOnce gets that by setting
   expandOnlyPending for exactly one EvalImpl call, which makes the macro
   branch hand back its result instead of re-evaluating it. *)

(* In expand-only mode a conditional that selects source (VERSION?, IFFLAG,
   IF-<FLAG>) must yield the SELECTED CODE, not run it — a routine body is
   being prepared for compilation, not evaluated. The original's own
   generated macros expand to <1 .A> for a single statement and
   <BIND () !.A> for several; same here. *)
PROCEDURE ClauseBodyValue(body: ZilObj.Zo): ZilObj.Zo;
VAR cell: ZilObj.Zo;
BEGIN
  IF (body = NIL) OR (body.first = NIL) THEN RETURN NIL END;
  IF (body.rest = NIL) OR (body.rest.first = NIL) THEN RETURN body.first END;
  cell := ZilObj.Cons(ZilObj.KForm, ZilObj.NewEmpty(ZilObj.KList), body);
  RETURN ZilObj.Cons(ZilObj.KForm, ZilObj.Intern("BIND"), cell)
END ClauseBodyValue;

PROCEDURE ExpandOnce(z: ZilObj.Zo): ZResult;
BEGIN
  expandOnlyPending := TRUE;
  RETURN EvalImpl(z, FALSE)
END ExpandOnce;

(* True when `z` is a FORM whose head names something that expands: a DEFMAC
   macro, or one of the IF-<FLAG>/IFN-<FLAG> conditional forms a
   compilation flag brings with it (which the original really does define as
   macros — see EvalImpl's own handling of them). *)
PROCEDURE IsExpandable(z: ZilObj.Zo): BOOLEAN;
VAR head: ZilObj.Zo; nm: ARRAY 64 OF CHAR;
BEGIN
  IF (z = NIL) OR (z.kind # ZilObj.KForm) OR (z.first = NIL)
     OR (z.first.kind # ZilObj.KAtom) THEN RETURN FALSE END;
  head := z.first.globalVal;
  IF (head # NIL) & (head.kind = ZilObj.KMacro) THEN RETURN TRUE END;
  (* VERSION? and IFFLAG choose SOURCE at compile time, so a routine body
     containing one has to have it resolved before compilation, exactly
     like a macro call *)
  IF ZilObj.IsAtomNamed(z.first, "VERSION?") OR ZilObj.IsAtomNamed(z.first, "IFFLAG") THEN
    RETURN TRUE
  END;
  IF head # NIL THEN RETURN FALSE END;
  Strings.Copy(z.first.atomText, nm);
  IF (nm[0] = "I") & (nm[1] = "F") & (nm[2] = "-") THEN Strings.Delete(nm, 0, 3)
  ELSIF (nm[0] = "I") & (nm[1] = "F") & (nm[2] = "N") & (nm[3] = "-") THEN Strings.Delete(nm, 0, 4)
  ELSE RETURN FALSE
  END;
  RETURN FlagValue(nm) # NIL
END IsExpandable;

(* Expands every macro call anywhere inside `z`, returning the rewritten
   structure (a fresh one; the input is left alone). Mirrors the original's
   RecursiveExpandWithSplice: rebuild LISTs, VECTORs and FORMs element by
   element, and when a FORM's own head turns out to be a macro, expand it
   and then expand the RESULT again — a macro may expand into another macro
   call. Self-recursive.

   Two simplifications against the original, both deliberate: no `!.A`
   splicing of a macro result into its surrounding list (the original wraps
   results in ZilMacroResult and SelectMany's them; nothing in the corpus's
   routine bodies needs it yet), and an expansion error leaves the form
   as-is rather than substituting FALSE, so the compiler reports the real
   construct it couldn't handle instead of a mysterious 0. *)
PROCEDURE ExpandTree*(z: ZilObj.Zo): ZilObj.Zo;
VAR r: ZResult; head, tail, cell, p, item, sp: ZilObj.Zo;
    i: INTEGER; vec: ZilObj.Zo;
BEGIN
  IF z = NIL THEN RETURN NIL END;

  IF z.kind = ZilObj.KForm THEN
    IF IsExpandable(z) THEN
      r := ExpandOnce(z);
      IF evalErrFlag OR (r.outcome # OValue) THEN
        (* Report the expansion failure rather than leaving the unexpanded
           form for the compiler to reject: the compiler's complaint is
           "unrecognized builtin <name>", which points at the macro instead
           of at whatever went wrong inside it. *)
        RETURN z
      END;
      IF r.value = z THEN RETURN z END;   (* expanded to itself: stop *)
      IF (r.value # NIL) & (r.value.kind = ZilObj.KSplice) THEN
        (* expand the spliced elements individually, then hand the SPLICE
           back for the caller to splice in *)
        head := NIL; tail := NIL; sp := r.value;
        WHILE (sp # NIL) & (sp.first # NIL) DO
          cell := ZilObj.Cons(ZilObj.KSplice, ExpandTree(sp.first), NIL);
          IF head = NIL THEN head := cell ELSE tail.rest := cell END;
          tail := cell;
          sp := sp.rest
        END;
        IF head = NIL THEN RETURN ZilObj.NewEmpty(ZilObj.KSplice) END;
        RETURN head
      END;
      RETURN ExpandTree(r.value)
    END
  END;

  IF (z.kind = ZilObj.KForm) OR (z.kind = ZilObj.KList) THEN
    head := NIL; tail := NIL;
    p := z;
    WHILE (p # NIL) & (p.first # NIL) DO
      item := ExpandTree(p.first);
      IF (item # NIL) & (item.kind = ZilObj.KSplice) THEN
        (* the element expanded to a SPLICE: its elements take its place
           rather than the splice itself becoming one element. This is what
           lets zillib's LIBRARY-MESSAGE expand to several TELL tokens. *)
        sp := item;
        WHILE (sp # NIL) & (sp.first # NIL) DO
          cell := ZilObj.Cons(z.kind, sp.first, NIL);
          IF head = NIL THEN head := cell ELSE tail.rest := cell END;
          tail := cell;
          sp := sp.rest
        END
      ELSE
        cell := ZilObj.Cons(z.kind, item, NIL);
        IF head = NIL THEN head := cell ELSE tail.rest := cell END;
        tail := cell
      END;
      p := p.rest
    END;
    IF head = NIL THEN RETURN ZilObj.NewEmpty(z.kind) END;
    RETURN head

  ELSIF z.kind = ZilObj.KVector THEN
    vec := ZilObj.NewVectorN(z.vecLen);
    FOR i := 0 TO z.vecLen - 1 DO
      item := ExpandTree(z.vecItems[i]);
      vec.vecItems[i] := item
    END;
    RETURN vec

  ELSE
    RETURN z
  END
END ExpandTree;

(* Stable public entry point — see EvalImpl's own header comment for why
   the real self-recursive evaluator takes a second (quasiquote-mode)
   parameter internally while this wrapper keeps every existing caller
   unaffected. *)
PROCEDURE Eval*(z: ZilObj.Zo): ZResult;
BEGIN RETURN EvalImpl(z, FALSE) END Eval;

(* ------------------------------------------------------------------ *)
(* builtin registration                                                  *)
(* ------------------------------------------------------------------ *)

PROCEDURE Register(name: ARRAY OF CHAR; isF: BOOLEAN);
VAR atom: ZilObj.Zo;
BEGIN
  atom := ZilObj.Intern(name);
  atom.globalVal := ZilObj.NewSubr(name, isF)
END Register;

(* Installed into ZilRead.evalHook so the reader can evaluate `%<...>` /
   `%%<...>` forms at read time (see ZilRead's EvalProc comment for why the
   dependency has to be inverted this way). Returns NIL on an evaluation
   error, which the reader turns into a read error — the error text itself
   stays in evalErrMsg for the driver to report. *)
PROCEDURE ReadTimeEval(z: ZilObj.Zo): ZilObj.Zo;
VAR r: ZResult;
BEGIN
  r := EvalImpl(z, FALSE);
  IF evalErrFlag OR (r.outcome # OValue) THEN RETURN NIL END;
  RETURN r.value
END ReadTimeEval;

(* The globals and constants the interpreter itself provides before any
   source is read — the original's Context.InitConstants. Library source
   really reads these: zillib/parser.zil opens with
   <SETG ZILLIB-VERSION ,ZIL-VERSION>, and verbs.zil prints ,ZIL-VERSION in
   its VERSION verb, so without them the library can't even be loaded.

   The compile-time ones are plain globals; the three runtime ones
   (TRUE-VALUE/FALSE-VALUE/FATAL-VALUE) and the part-of-speech bit values
   are ZIL CONSTANTs in the original (AddZConstant), so they are registered
   with ZilModel too and will be emitted as assembly symbols by ZilCompile.
   The part-of-speech values are the PartOfSpeech enum's own bit values,
   copied exactly — the vocabulary tables that consume them aren't emitted
   yet, but the constants are referenced by library source long before
   that. GLK and CORNERSTONE are always false here: both are targets this
   port doesn't emit for. *)
PROCEDURE InitPredefined;
VAR tk, ou: ARRAY 4 OF ZilObj.Zo;

  (* builds a cons chain of `kind` from the first n items *)
  PROCEDURE MkChain(kind: INTEGER; items: ARRAY OF ZilObj.Zo; n: INTEGER): ZilObj.Zo;
  VAR head, tail, cell: ZilObj.Zo; k: INTEGER;
  BEGIN
    head := NIL; tail := NIL;
    FOR k := 0 TO n - 1 DO
      cell := ZilObj.Cons(kind, items[k], NIL);
      IF head = NIL THEN head := cell ELSE tail.rest := cell END;
      tail := cell
    END;
    IF head = NIL THEN RETURN ZilObj.NewEmpty(kind) END;
    RETURN head
  END MkChain;

  (* the "<TOKEN> * <OPCODE .X>" shape all four of the remaining built-in
     TELL patterns share *)
  PROCEDURE DefTell1(token, opcode: ARRAY OF CHAR);
  VAR t, o: ARRAY 4 OF ZilObj.Zo;
  BEGIN
    t[0] := ZilObj.Intern(token); t[1] := ZilObj.Intern("*");
    o[0] := ZilObj.Intern("LVAL"); o[1] := ZilObj.Intern("X");
    o[1] := MkChain(ZilObj.KForm, o, 2);
    o[0] := ZilObj.Intern(opcode);
    ZilModel.AddTellPattern(MkChain(ZilObj.KList, t, 2), MkChain(ZilObj.KForm, o, 2))
  END DefTell1;

  PROCEDURE DefGlobal(name: ARRAY OF CHAR; value: ZilObj.Zo);
  VAR atom: ZilObj.Zo;
  BEGIN atom := ZilObj.Intern(name); atom.globalVal := value END DefGlobal;

  PROCEDURE DefConst(name: ARRAY OF CHAR; value: INTEGER);
  VAR atom, v: ZilObj.Zo;
  BEGIN
    atom := ZilObj.Intern(name); v := ZilObj.NewFix(value);
    atom.globalVal := v;
    ZilModel.AddConstant(atom, v)
  END DefConst;

BEGIN
  DefGlobal("ZILCH", TrueVal());
  DefGlobal("ZILF", TrueVal());
  DefGlobal("ZIL-VERSION", ZilObj.NewString("ZILF 0.9 (Oberon port)"));
  DefGlobal("PREDGEN", TrueVal());
  DefGlobal("PLUS-MODE", BoolVal(ZilModel.zversion > 3));
  DefGlobal("SIBREAKS", ZilObj.NewString(',."'));
  DefGlobal("GLK", FalseVal());
  DefGlobal("CORNERSTONE", FalseVal());

  DefConst("TRUE-VALUE", 1);
  DefConst("FALSE-VALUE", 0);
  DefConst("FATAL-VALUE", 2);

  (* PartOfSpeech bit values, copied from the original's enum *)
  DefConst("P1?OBJECT", 0);      (* there is no ObjectFirst *)
  DefConst("P1?VERB", 1);
  DefConst("P1?ADJECTIVE", 2);
  DefConst("P1?DIRECTION", 3);
  DefConst("PS?BUZZ-WORD", 4);
  DefConst("PS?PREPOSITION", 8);
  DefConst("PS?DIRECTION", 16);
  DefConst("PS?ADJECTIVE", 32);
  DefConst("PS?VERB", 64);
  DefConst("PS?OBJECT", 128);

  (* The TELL token patterns the original predefines in InitTellPatterns.
     It writes them as ZIL source and parses it; there is no reader to hand
     a string to here, so they are built directly — five patterns is little
     enough that a parser would cost more than it saved.

         (CR CRLF) <CRLF>
         D * <PRINTD .X>
         N * <PRINTN .X>
         C * <PRINTC .X>
         B * <PRINTB .X>
  *)
  ZilModel.nTellPatterns := 0;
  tk[0] := ZilObj.Intern("CR"); tk[1] := ZilObj.Intern("CRLF");
  tk[0] := MkChain(ZilObj.KList, tk, 2);
  ou[0] := ZilObj.Intern("CRLF");
  ZilModel.AddTellPattern(MkChain(ZilObj.KList, tk, 1), MkChain(ZilObj.KForm, ou, 1));

  DefTell1("D", "PRINTD");
  DefTell1("N", "PRINTN");
  DefTell1("C", "PRINTC");
  DefTell1("B", "PRINTB");

  (* the compilation flags the original predefines in InitCompilationFlags *)
  nFlags := 0;
  DefineFlag("IN-ZILCH", FalseVal(), TRUE);
  DefineFlag("COLOR", FalseVal(), TRUE);
  DefineFlag("MOUSE", FalseVal(), TRUE);
  DefineFlag("UNDO", FalseVal(), TRUE);
  DefineFlag("DISPLAY", FalseVal(), TRUE);
  DefineFlag("SOUND", FalseVal(), TRUE);
  DefineFlag("MENU", FalseVal(), TRUE);
  DefineFlag("LONG-WORDS", FalseVal(), TRUE);
  DefineFlag("WORD-FLAGS-IN-TABLE", TrueVal(), TRUE)
END InitPredefined;

PROCEDURE InitBuiltins*;
VAR tAtom: ZilObj.Zo;
BEGIN
  ZilRead.evalHook := ReadTimeEval;
  nPackages := 0;
  Register("QUOTE", TRUE); Register("COND", TRUE); Register("AND", TRUE); Register("OR", TRUE);
  Register("QUASIQUOTE", TRUE);
  Register("PROG", TRUE); Register("REPEAT", TRUE); Register("BIND", TRUE);
  Register("RETURN", FALSE); Register("AGAIN", FALSE);
  Register("DEFINE", TRUE); Register("DEFINE20", TRUE); Register("DEFMAC", TRUE);
  Register("ROUTINE", TRUE); Register("OBJECT", TRUE); Register("ROOM", TRUE);
  Register("PROPDEF", TRUE);
  Register("FORM", FALSE); Register("LIST", FALSE); Register("LENGTH?", FALSE);
  Register("SET", FALSE); Register("SETG", FALSE); Register("GLOBAL", FALSE); Register("CONSTANT", FALSE);
  Register("LVAL", FALSE); Register("GVAL", FALSE);
  Register("GASSIGNED?", FALSE); Register("ASSIGNED?", FALSE);
  Register("PUTPROP", FALSE); Register("GETPROP", FALSE);
  Register("+", FALSE); Register("-", FALSE); Register("*", FALSE); Register("/", FALSE);
  Register("MOD", FALSE); Register("1+", FALSE); Register("1-", FALSE);
  Register("=?", FALSE); Register("EQUAL?", FALSE); Register("==?", FALSE);
  Register("N=?", FALSE); Register("N==?", FALSE);
  Register("L?", FALSE); Register("G?", FALSE); Register("L=?", FALSE); Register("G=?", FALSE);
  Register("NOT", FALSE);
  Register("PRINC", FALSE); Register("PRIN1", FALSE); Register("PRINT", FALSE); Register("CRLF", FALSE);
  Register("PRINTN", FALSE); Register("PRINTC", FALSE);
  Register("INSERT-FILE", FALSE); Register("FLOAD", FALSE); Register("XFLOAD", FALSE);
  Register("CONS", FALSE);
  Register("EVAL", FALSE); Register("EVAL-IN-SEGMENT", FALSE); Register("EXPAND", FALSE);
  Register("TABLE", FALSE); Register("LTABLE", FALSE); Register("PTABLE", FALSE);
  Register("PLTABLE", FALSE); Register("ITABLE", FALSE);
  Register("SYNTAX", FALSE);
  Register("SYNONYM", FALSE); Register("VERB-SYNONYM", FALSE); Register("PREP-SYNONYM", FALSE);
  Register("ADJ-SYNONYM", FALSE); Register("DIR-SYNONYM", FALSE);
  Register("DIRECTIONS", FALSE); Register("BUZZ", FALSE); Register("VOC", FALSE);
  Register("BIT-SYNONYM", FALSE);
  Register("DELAY-DEFINITION", FALSE);
  Register("DEFAULT-DEFINITION", TRUE); Register("REPLACE-DEFINITION", TRUE);
  Register("VERSION", FALSE); Register("CHECK-VERSION?", FALSE); Register("FILE-FLAGS", FALSE);
  Register("ZIP-OPTIONS", FALSE);
  Register("PACKAGE", FALSE); Register("ZPACKAGE", FALSE); Register("ZZPACKAGE", FALSE);
  Register("DEFINITIONS", FALSE); Register("ZSECTION", FALSE); Register("ZZSECTION", FALSE);
  Register("ENDPACKAGE", FALSE); Register("END-DEFINITIONS", FALSE); Register("ENDSECTION", FALSE);
  Register("BLOCK", FALSE); Register("ENDBLOCK", FALSE);
  Register("ENTRY", FALSE); Register("RENTRY", FALSE); Register("COMPILING?", FALSE);
  Register("USE", FALSE); Register("INCLUDE", FALSE);
  Register("USE-WHEN", FALSE); Register("INCLUDE-WHEN", FALSE);
  Register("COMPILATION-FLAG", FALSE); Register("COMPILATION-FLAG-DEFAULT", FALSE);
  Register("COMPILATION-FLAG-VALUE", FALSE); Register("IFFLAG", TRUE);
  Register("GC-MON", FALSE); Register("BLOAT", FALSE);
  Register("ZSTR-ON", FALSE); Register("ZSTR-OFF", FALSE);
  Register("ENDLOAD", FALSE); Register("PUT-PURE-HERE", FALSE);
  Register("DEFAULTS-DEFINED", FALSE); Register("CHECKPOINT", FALSE);
  Register("BEGIN-SEGMENT", FALSE); Register("END-SEGMENT", FALSE);
  Register("DEFINE-SEGMENT", FALSE); Register("FREQUENT-WORDS?", FALSE);
  Register("NEVER-ZAP-TO-SOURCE-DIRECTORY?", FALSE); Register("ASK-FOR-PICTURE-FILE?", FALSE);
  Register("PICFILE", FALSE);
  Register("ADD-TELL-TOKENS", TRUE); Register("TELL-TOKENS", TRUE);
  Register("NTH", FALSE); Register("GET-ELEMENT", FALSE); Register("REST", FALSE);
  Register("PUTREST", FALSE);
  Register("PUT", FALSE); Register("ZGET", FALSE); Register("ZPUT", FALSE);
  Register("UNPARSE", FALSE); Register("0?", FALSE); Register("1?", FALSE);
  Register("GETB", FALSE); Register("PUTB", FALSE);
  Register("EMPTY?", FALSE); Register("LENGTH", FALSE); Register("SORT", FALSE);
  Register("TYPE", FALSE); Register("PRIMTYPE", FALSE); Register("TYPE?", FALSE);
  Register("STRUCTURED?", FALSE); Register("APPLICABLE?", FALSE);
  Register("SPNAME", FALSE); Register("PNAME", FALSE); Register("PARSE", FALSE);
  Register("ERROR", FALSE);
  Register("STRING", FALSE); Register("VECTOR", FALSE);
  Register("BYTE", FALSE); Register("WORD", FALSE); Register("CHTYPE", FALSE); Register("SET-SOURCE-INFO", FALSE);
  Register("NEWTYPE", FALSE); Register("OFFSET", FALSE);
  Register("GBOUND?", FALSE); Register("BOUND?", FALSE);
  Register("MEMQ", FALSE); Register("MEMBER", FALSE); Register("ASCII", FALSE);
  Register("ORB", FALSE); Register("ANDB", FALSE); Register("XORB", FALSE); Register("MIN", FALSE); Register("MAX", FALSE);
  Register("ABS", FALSE);
  Register("MOBLIST", FALSE); Register("ROOT", FALSE); Register("OBLIST?", FALSE);
  Register("LOOKUP", FALSE); Register("INSERT", FALSE);
  Register("FUNCTION", TRUE); Register("DEFSTRUCT", TRUE);
  Register("APPLY", FALSE); Register("APPLY-MACRO", FALSE);
  Register("MAPF", FALSE); Register("MAPR", FALSE);
  Register("MAPRET", FALSE); Register("MAPSTOP", FALSE); Register("MAPLEAVE", FALSE);
  Register("VERSION?", TRUE); Register("GDECL", TRUE);

  tAtom := ZilObj.Intern("T");
  tAtom.globalVal := tAtom;  (* T is self-valued *)

  enclosingProgAtom := ZilObj.Intern("LPROG ");
  currentDir[0] := 0X;
  ZilModel.Reset;
  (* after the Reset, since InitPredefined registers ZIL CONSTANTs into
     ZilModel and the Reset would otherwise throw them straight away *)
  InitPredefined
END InitBuiltins;

END ZilEval.
