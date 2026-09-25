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
  OValue* = 0;
  OReturn* = 1;
  OAgain*  = 2;

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
  evalErrFlag := TRUE;
  Strings.Copy(msg, evalErrMsg);
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
    IF ZilObj.IsAtomNamed(args[idx], "BYTE") THEN flags := flags + ZilObj.TfByte END;
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

PROCEDURE ApplySubr*(name: ARRAY OF CHAR; args: ARRAY OF ZilObj.Zo; n: INTEGER): ZResult;
VAR sum, i, len, synKind: INTEGER; s: ARRAY 4096 OF CHAR; ind: ZilObj.Zo;
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
    IF name = "GLOBAL" THEN ZilModel.AddGlobal(args[0], args[1])
    ELSIF name = "CONSTANT" THEN ZilModel.AddConstant(args[0], args[1]) END;
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
      IF ValuesEqual(args[0], args[i]) THEN RETURN MkVal(TrueVal()) END
    END;
    RETURN MkVal(FalseVal())

  ELSIF (name = "N=?") OR (name = "N==?") THEN
    IF n < 2 THEN RETURN Err("N=?: expected at least 2 args") END;
    FOR i := 1 TO n - 1 DO
      IF ValuesEqual(args[0], args[i]) THEN RETURN MkVal(FalseVal()) END
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
    IF n < 1 THEN RETURN Err("FORM: expected at least 1 arg") END;
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
    (* Full semantic decomposition (verb/prep/object/scope-flags/action)
       deferred to phase 3b — see ZilModel.mod's SyntaxRec comment. Args
       arrive already-evaluated (SYNTAX is a plain SUBR in the original),
       but every element is self-evaluating (atoms and lists of atoms),
       so capturing them is transparent — same reasoning as GLOBAL/
       CONSTANT/TABLE. *)
    IF n < 3 THEN RETURN Err("SYNTAX: expected at least 3 args") END;
    ZilModel.AddSyntax(BuildConsChain(ZilObj.KList, args, n));
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

  ELSIF name = "DIRECTIONS" THEN
    FOR i := 0 TO n - 1 DO ZilModel.AddDirection(args[i]) END;
    RETURN MkVal(TrueVal())

  ELSIF name = "BUZZ" THEN
    FOR i := 0 TO n - 1 DO ZilModel.AddBuzzword(args[i]) END;
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
    (* Pragmatic subset: the original CHTYPEs the interned atom to a VOC
       pseudo-type and also registers it (by part-of-speech, an optional
       2nd arg) into ZEnvironment's vocabulary dictionary for later
       dictionary-table encoding (phase 3b). This just interns and returns
       the plain atom, ignoring the part-of-speech argument — VOC's main
       real-source use is as a self-evaluating-atom-producing building
       block inside other expressions, which this preserves. *)
    IF (n < 1) OR (args[0].kind # ZilObj.KString) THEN
      RETURN Err("VOC: expected a STRING")
    END;
    RETURN MkVal(ZilObj.Intern(args[0].strBuf^))

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
    RETURN Err("unrecognized or not-yet-implemented SUBR")
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
  IF (bodyList = NIL) OR (bodyList.first = NIL) THEN
    RETURN Err("ROUTINE: empty body")
  END;

  ZilModel.AddRoutine(nameAtom, actAtom, argSpecList, bodyList);
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

PROCEDURE EvalImpl(z: ZilObj.Zo; qq: BOOLEAN): ZResult;
VAR
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
  fnIsMacro, fnStop, fnUsedVarargs, fnQuoted: BOOLEAN;
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
            qqSpliceP := r.value;
            WHILE (qqSpliceP # NIL) & (qqSpliceP.first # NIL) DO
              qqCell := ZilObj.Cons(z.kind, qqSpliceP.first, NIL);
              IF qqResult = NIL THEN qqResult := qqCell ELSE qqTail.rest := qqCell END;
              qqTail := qqCell;
              qqSpliceP := qqSpliceP.rest
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
     OR (z.kind = ZilObj.KChar) OR (z.kind = ZilObj.KVector) OR (z.kind = ZilObj.KFalse)
     OR (z.kind = ZilObj.KSubr) OR (z.kind = ZilObj.KFSubr) OR (z.kind = ZilObj.KActivation)
     OR (z.kind = ZilObj.KFunction) OR (z.kind = ZilObj.KMacro) THEN
    RETURN MkVal(z)

  ELSIF z.kind = ZilObj.KAdecl THEN
    RETURN EvalImpl(z.adFirst, FALSE)  (* DECL check skipped *)

  ELSIF z.kind = ZilObj.KSegment THEN
    RETURN Err("a SEGMENT can only be evaluated inside a structure")

  ELSIF z.kind = ZilObj.KList THEN
    IF ZilObj.IsEmpty(z) THEN RETURN MkVal(z) END;
    resultHead := NIL; resultTail := NIL;
    n := z;
    WHILE (n # NIL) & (n.first # NIL) DO
      nFirst := n.first;
      IF nFirst.kind = ZilObj.KSegment THEN
        RETURN Err("SEGMENT splicing inside LIST is not implemented yet")
      END;
      r := EvalImpl(nFirst, FALSE);
      IF ShouldPass(r) THEN RETURN r END;
      cell := ZilObj.Cons(ZilObj.KList, r.value, NIL);
      IF resultHead = NIL THEN resultHead := cell ELSE resultTail.rest := cell END;
      resultTail := cell;
      n := n.rest
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
        IF flagVal = NIL THEN RETURN ErrAtom("calling unassigned atom:", zFirst) END;

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

        IF (fnOneSpec.kind = ZilObj.KString) & (fnOneSpec.strBuf^ = "OPT") THEN
          fnPhase := APOpt; fnSpecPos := fnSpecPos.rest

        ELSIF (fnOneSpec.kind = ZilObj.KString) & (fnOneSpec.strBuf^ = "AUX") THEN
          fnPhase := APAux; fnSpecPos := fnSpecPos.rest

        ELSIF (fnOneSpec.kind = ZilObj.KString)
              & ((fnOneSpec.strBuf^ = "ARGS") OR (fnOneSpec.strBuf^ = "TUPLE")) THEN
          fnSpecPos := fnSpecPos.rest;
          IF (fnSpecPos = NIL) OR (fnSpecPos.first = NIL) OR (fnSpecPos.first.kind # ZilObj.KAtom) THEN
            RETURN Err("FUNCTION/MACRO: ARGS/TUPLE must be followed by an atom")
          END;
          fnTarget := fnSpecPos.first;
          fnUsedVarargs := TRUE;
          resultHead := NIL; resultTail := NIL;
          WHILE (fnCallArgs # NIL) & (fnCallArgs.first # NIL) & ~fnStop DO
            r := EvalImpl(fnCallArgs.first, FALSE);
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
          r := MkVal(cond);
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
          r := MkVal(cond);
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
          ELSIF r.outcome # OValue THEN
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
            ELSIF r.outcome # OValue THEN
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

    ELSIF isFSubr & (name = "OBJECT") THEN
      RETURN ApplyObject(FALSE, z.rest)

    ELSIF isFSubr & (name = "ROOM") THEN
      RETURN ApplyObject(TRUE, z.rest)

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
        r := EvalImpl(n.first, FALSE);
        IF ShouldPass(r) THEN RETURN r END;
        IF nargs < MaxArgs THEN args[nargs] := r.value; INC(nargs) END;
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
VAR r: ZResult; head, tail, cell, p, item: ZilObj.Zo;
    savedErr: BOOLEAN; i: INTEGER; vec: ZilObj.Zo;
BEGIN
  IF z = NIL THEN RETURN NIL END;

  IF z.kind = ZilObj.KForm THEN
    IF IsExpandable(z) THEN
      savedErr := evalErrFlag;
      r := ExpandOnce(z);
      IF evalErrFlag OR (r.outcome # OValue) THEN
        evalErrFlag := savedErr;   (* leave it to the compiler to complain *)
        RETURN z
      END;
      IF r.value = z THEN RETURN z END;   (* expanded to itself: stop *)
      RETURN ExpandTree(r.value)
    END
  END;

  IF (z.kind = ZilObj.KForm) OR (z.kind = ZilObj.KList) THEN
    head := NIL; tail := NIL;
    p := z;
    WHILE (p # NIL) & (p.first # NIL) DO
      cell := ZilObj.Cons(z.kind, ExpandTree(p.first), NIL);
      IF head = NIL THEN head := cell ELSE tail.rest := cell END;
      tail := cell;
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
  Register("EVAL", FALSE); Register("EVAL-IN-SEGMENT", FALSE);
  Register("TABLE", FALSE); Register("LTABLE", FALSE); Register("PTABLE", FALSE);
  Register("PLTABLE", FALSE); Register("ITABLE", FALSE);
  Register("SYNTAX", FALSE);
  Register("SYNONYM", FALSE); Register("VERB-SYNONYM", FALSE); Register("PREP-SYNONYM", FALSE);
  Register("ADJ-SYNONYM", FALSE); Register("DIR-SYNONYM", FALSE);
  Register("DIRECTIONS", FALSE); Register("BUZZ", FALSE); Register("VOC", FALSE);
  Register("DELAY-DEFINITION", FALSE);
  Register("DEFAULT-DEFINITION", TRUE); Register("REPLACE-DEFINITION", TRUE);
  Register("VERSION", FALSE); Register("CHECK-VERSION?", FALSE); Register("FILE-FLAGS", FALSE);
  Register("PACKAGE", FALSE); Register("ZPACKAGE", FALSE); Register("ZZPACKAGE", FALSE);
  Register("DEFINITIONS", FALSE); Register("ZSECTION", FALSE); Register("ZZSECTION", FALSE);
  Register("ENDPACKAGE", FALSE); Register("END-DEFINITIONS", FALSE); Register("ENDSECTION", FALSE);
  Register("BLOCK", FALSE); Register("ENDBLOCK", FALSE);
  Register("ENTRY", FALSE); Register("RENTRY", FALSE); Register("COMPILING?", FALSE);
  Register("USE", FALSE); Register("INCLUDE", FALSE);
  Register("USE-WHEN", FALSE); Register("INCLUDE-WHEN", FALSE);
  Register("COMPILATION-FLAG", FALSE); Register("COMPILATION-FLAG-DEFAULT", FALSE);
  Register("COMPILATION-FLAG-VALUE", FALSE); Register("IFFLAG", TRUE);
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
