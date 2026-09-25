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

IMPORT ZilObj, ZilModel, Out, Files, Strings;

VAR
  errFlag*: BOOLEAN;
  errMsg*: ARRAY 512 OF CHAR;

PROCEDURE Err(msg: ARRAY OF CHAR);
BEGIN errFlag := TRUE; Strings.Copy(msg, errMsg) END Err;

PROCEDURE ClearErr*;
BEGIN errFlag := FALSE; errMsg[0] := 0X END ClearErr;

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

TYPE
  LineText = POINTER TO ARRAY OF CHAR;

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

PROCEDURE W(s: ARRAY OF CHAR);
BEGIN Strings.Append(s, lineBuf) END W;

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
   same way (PushInnerLocal with a ?TMP atom, in ZBuiltins.cs's
   SetValueOp) — spill the earlier value into a named local so the later
   one can have the stack to itself. `SET '?TMPn,STACK` is the spill: the
   Z-machine store instruction reads its value operand from the stack,
   popping it. Temporaries are allocated by nesting depth (?TMP1, ?TMP2,
   ...) and released as each instruction consumes them, so a routine only
   declares as many as its deepest expression actually needed. *)
PROCEDURE BeginBuffer;
BEGIN buffering := TRUE; nBufLines := 0; tempDepth := 0; tempMax := 0 END BeginBuffer;

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

(* Allocates the next temporary and yields its ZAP local name. *)
PROCEDURE AllocTemp(VAR name: ARRAY OF CHAR);
VAR n: ARRAY 16 OF CHAR;
BEGIN
  INC(tempDepth);
  IF tempDepth > tempMax THEN tempMax := tempDepth END;
  Strings.IntToStr(tempDepth, n);
  Strings.Copy("?TMP", name); Strings.Append(n, name)
END AllocTemp;

PROCEDURE FreeTemp;
BEGIN DEC(tempDepth) END FreeTemp;

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
PROCEDURE ConstantText(z: ZilObj.Zo; VAR s: ARRAY OF CHAR): BOOLEAN;
VAR name: ARRAY 64 OF CHAR;
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
  ELSIF z.kind = ZilObj.KFalse THEN Strings.Copy("0", s); RETURN TRUE
  ELSIF z.kind = ZilObj.KAtom THEN
    Strings.Copy(z.atomText, name);
    IF name = "T" THEN Strings.Copy("1", s); RETURN TRUE END;
    IF FindRoutineIdx(name) >= 0 THEN Strings.Copy(name, s); RETURN TRUE END;
    IF FindObjectIdx(name) >= 0 THEN Strings.Copy(name, s); RETURN TRUE END;
    IF FindConstantIdx(name) >= 0 THEN Strings.Copy(name, s); RETURN TRUE END;
    RETURN FALSE
  END;
  RETURN FALSE
END ConstantText;

(* Set by CompileStmt when the statement it just compiled always leaves the
   routine (RETURN/RTRUE/RFALSE) — the original tracks the same thing on its
   IRoutineBuilder so it can skip emitting an unreachable trailing return.
   Read by CompileRoutine right after compiling the final statement. *)
VAR termFlag: BOOLEAN;

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

(* Moves an operand already sitting on the stack into a fresh temporary, so
   a later operand of the same instruction can use the stack without the two
   coming back off it in the wrong order. Returns FALSE (with the error set)
   only if the routine has run out of Z-machine locals. *)
PROCEDURE SpillToTemp(VAR text: ARRAY OF CHAR): BOOLEAN;
VAR tmp: ARRAY 16 OF CHAR;
BEGIN
  AllocTemp(tmp);
  IF tempMax > MaxLocals THEN
    Err("expression needs more compiler temporaries than a routine has locals");
    RETURN FALSE
  END;
  W("	SET '"); W(tmp); W(",STACK"); WLn;
  Strings.Copy(tmp, text);
  RETURN TRUE
END SpillToTemp;

(* Compiles `z` as a value-producing expression, emitting whatever
   instructions are needed and returning the ZAP operand text that holds
   the result (a literal number, a local variable's bare name, or
   "STACK" for a compound sub-expression). Self-recursive (calls itself
   for each operand of a nested arithmetic FORM) — this transpiler has no
   FORWARD declarations, same reason as every other self-recursive
   procedure throughout this port (ZilRead.ReadOne, ZilEval.EvalImpl). *)
PROCEDURE CompileOperand(z: ZilObj.Zo; VAR opText: ARRAY OF CHAR): BOOLEAN;
VAR leftText, rightText: ARRAY 64 OF CHAR; opcode: ARRAY 16 OF CHAR;
    headName: ARRAY 64 OF CHAR; argTexts: ARRAY 3, 64 OF CHAR;
    ok, spilled: BOOLEAN; nArgs, i, nSpills: INTEGER; ap, ap2: ZilObj.Zo;
BEGIN
  IF z = NIL THEN Err("CompileOperand: NIL expression"); RETURN FALSE END;

  IF z.kind = ZilObj.KFix THEN
    FixText(z.fixVal, opText); RETURN TRUE

  ELSIF z.kind = ZilObj.KChar THEN
    (* the original's CompileConstant maps a CHARACTER straight to its ZSCII
       code (Game.MakeOperand(ch.Char)) — same here *)
    FixText(z.charVal, opText); RETURN TRUE

  ELSIF z.kind = ZilObj.KFalse THEN
    Strings.Copy("0", opText); RETURN TRUE

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
    Strings.Copy(z.rest.first.atomText, opText); RETURN TRUE

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
    Err("CompileOperand: GVAL of an undefined global/constant/routine/object"); RETURN FALSE

  ELSIF z.kind = ZilObj.KForm THEN
    IF (z.first = NIL) OR (z.first.kind # ZilObj.KAtom) THEN
      Err("CompileOperand: expected an operator atom in form head"); RETURN FALSE
    END;
    Strings.Copy(z.first.atomText, headName);

    IF (headName = "+") OR (headName = "-") OR (headName = "*") OR (headName = "/")
       OR (headName = "MOD") THEN
      IF (z.rest = NIL) OR (z.rest.first = NIL) OR (z.rest.rest = NIL) OR (z.rest.rest.first = NIL) THEN
        Err("CompileOperand: arithmetic op expects 2 args"); RETURN FALSE
      END;
      ok := CompileOperand(z.rest.first, leftText);
      IF ~ok THEN RETURN FALSE END;
      spilled := (leftText = "STACK") & ~IsSimpleOperand(z.rest.rest.first);
      IF spilled THEN
        ok := SpillToTemp(leftText);
        IF ~ok THEN RETURN FALSE END
      END;
      ok := CompileOperand(z.rest.rest.first, rightText);
      IF ~ok THEN RETURN FALSE END;
      IF spilled THEN FreeTemp END;
      IF headName = "+" THEN Strings.Copy("ADD", opcode)
      ELSIF headName = "-" THEN Strings.Copy("SUB", opcode)
      ELSIF headName = "*" THEN Strings.Copy("MUL", opcode)
      ELSIF headName = "MOD" THEN Strings.Copy("MOD", opcode)
      ELSE Strings.Copy("DIV", opcode)
      END;
      W("	"); W(opcode); W(" "); W(leftText);
      W(","); W(rightText); W(" >STACK"); WLn;
      Strings.Copy("STACK", opText); RETURN TRUE

    ELSIF headName = "VALUE" THEN
      (* <VALUE X> is "read the variable named X" — the original's ValueOp;
         for a plain named variable that's just the variable itself as an
         operand, no instruction needed. *)
      IF (z.rest = NIL) OR ~VarName(z.rest.first, opText) THEN
        Err("CompileOperand: VALUE expects a variable name"); RETURN FALSE
      END;
      RETURN TRUE

    ELSIF (headName = "INC") OR (headName = "DEC") THEN
      (* INC/DEC in VALUE position: the Z-machine's own INC/DEC don't store,
         so read the variable back afterwards, matching the original's
         IncValueOp returning `victim` (the variable) as its result. *)
      IF (z.rest = NIL) OR ~VarName(z.rest.first, opText) THEN
        Err("CompileOperand: INC/DEC expects a variable name"); RETURN FALSE
      END;
      W("	"); W(headName); W(" '"); W(opText); WLn;
      RETURN TRUE

    ELSIF FindRoutineIdx(headName) >= 0 THEN
      (* A call to a ROUTINE this program defines. V3 has only the storing
         CALL opcode (max 3 arguments) — confirmed against the original's own
         EmitCall, which for zversion < 4 always emits CALL and pops the
         result with FSTACK when it isn't wanted (see CompileStmt for that
         void case). *)
      nArgs := 0; nSpills := 0; ap := z.rest;
      WHILE (ap # NIL) & (ap.first # NIL) DO
        IF nArgs >= 3 THEN
          Err("CompileOperand: V3 allows at most 3 call arguments"); RETURN FALSE
        END;
        (* every argument must be fully compiled BEFORE the CALL line starts
           being written: an argument can be a compound expression that emits
           instructions of its own, which would otherwise land in the middle
           of the half-written CALL line *)
        ok := CompileOperand(ap.first, argTexts[nArgs]);
        IF ~ok THEN RETURN FALSE END;
        (* and an argument left on the stack has to be spilled if anything
           still to be compiled might push over it *)
        IF argTexts[nArgs] = "STACK" THEN
          spilled := FALSE; ap2 := ap.rest;
          WHILE (ap2 # NIL) & (ap2.first # NIL) DO
            IF ~IsSimpleOperand(ap2.first) THEN spilled := TRUE END;
            ap2 := ap2.rest
          END;
          IF spilled THEN
            ok := SpillToTemp(argTexts[nArgs]);
            IF ~ok THEN RETURN FALSE END;
            INC(nSpills)
          END
        END;
        INC(nArgs); ap := ap.rest
      END;
      WHILE nSpills > 0 DO FreeTemp; DEC(nSpills) END;
      W("	CALL "); W(headName);
      i := 0;
      WHILE i < nArgs DO
        W(","); W(argTexts[i]); INC(i)
      END;
      W(" >STACK"); WLn;
      Strings.Copy("STACK", opText); RETURN TRUE

    ELSE
      Err("CompileOperand: unrecognized or not-yet-implemented builtin"); RETURN FALSE
    END

  ELSE
    Err("CompileOperand: expression of this kind cannot be compiled yet"); RETURN FALSE
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
  W("	"); W(opcode); W(" "); W(op1);
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
    ok, spilled: BOOLEAN;
BEGIN
  empty[0] := 0X;
  IF z = NIL THEN Err("CompileCondition: NIL condition"); RETURN FALSE END;

  IF (z.kind = ZilObj.KAtom) & ((z.atomText = "T") OR (z.atomText = "ELSE")) THEN
    IF polarity THEN EmitBranch(label) END; RETURN TRUE

  ELSIF z.kind = ZilObj.KFalse THEN
    IF ~polarity THEN EmitBranch(label) END; RETURN TRUE

  ELSIF z.kind = ZilObj.KFix THEN
    IF (z.fixVal # 0) = polarity THEN EmitBranch(label) END; RETURN TRUE

  ELSIF (z.kind = ZilObj.KForm) & (z.first # NIL) & (z.first.kind = ZilObj.KAtom) THEN
    Strings.Copy(z.first.atomText, headName);

    IF headName = "ZERO?" THEN
      IF (z.rest = NIL) OR (z.rest.first = NIL) THEN
        Err("CompileCondition: ZERO? expects 1 arg"); RETURN FALSE
      END;
      ok := CompileOperand(z.rest.first, opText);
      IF ~ok THEN RETURN FALSE END;
      EmitPredInstr("ZERO?", opText, empty, label, polarity); RETURN TRUE

    ELSIF (headName = "EQUAL?") OR (headName = "=?") OR (headName = "==?") OR (headName = "L?") OR (headName = "G?") THEN
      IF (z.rest = NIL) OR (z.rest.first = NIL) OR (z.rest.rest = NIL) OR (z.rest.rest.first = NIL) THEN
        Err("CompileCondition: comparison expects 2 args"); RETURN FALSE
      END;
      ok := CompileOperand(z.rest.first, leftText);
      IF ~ok THEN RETURN FALSE END;
      spilled := (leftText = "STACK") & ~IsSimpleOperand(z.rest.rest.first);
      IF spilled THEN
        ok := SpillToTemp(leftText);
        IF ~ok THEN RETURN FALSE END
      END;
      ok := CompileOperand(z.rest.rest.first, rightText);
      IF ~ok THEN RETURN FALSE END;
      IF spilled THEN FreeTemp END;
      IF headName = "L?" THEN EmitPredInstr("LESS?", leftText, rightText, label, polarity)
      ELSIF headName = "G?" THEN EmitPredInstr("GRTR?", leftText, rightText, label, polarity)
      ELSE EmitPredInstr("EQUAL?", leftText, rightText, label, polarity)
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
      ok := CompileOperand(z.rest.rest.first, rightText);
      IF ~ok THEN RETURN FALSE END;
      Strings.Copy("'", opText); Strings.Append(leftText, opText);
      EmitPredInstr(headName, opText, rightText, label, polarity);
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
VAR headName: ARRAY 64 OF CHAR; opText, targetName: ARRAY 64 OF CHAR; strText: ARRAY 4096 OF CHAR;
    ok: BOOLEAN;
    (* COND *)
    nextLabel, endLabel: ARRAY 16 OF CHAR;
    elsePart, isLastClauseStmt, hasMoreClauses, clauseTerminated: BOOLEAN;
    c, cond, body, bp: ZilObj.Zo; clauseResult: ARRAY 64 OF CHAR;
BEGIN
  termFlag := FALSE;
  IF z = NIL THEN Err("CompileStmt: NIL statement"); RETURN FALSE END;

  IF (z.kind = ZilObj.KForm) & (z.first # NIL) & (z.first.kind = ZilObj.KAtom) THEN
    Strings.Copy(z.first.atomText, headName);

    IF (headName = "SET") OR (headName = "SETG") THEN
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
      ok := CompileOperand(z.rest.rest.first, opText);
      IF ~ok THEN RETURN FALSE END;
      W("	SET '"); W(targetName); W(","); W(opText); WLn;
      Strings.Copy(targetName, resultText);
      RETURN TRUE

    ELSIF (headName = "INC") OR (headName = "DEC") THEN
      IF (z.rest = NIL) OR ~VarName(z.rest.first, targetName) THEN
        Err("CompileStmt: INC/DEC expect a variable name"); RETURN FALSE
      END;
      W("	"); W(headName); W(" '"); W(targetName); WLn;
      Strings.Copy(targetName, resultText);
      RETURN TRUE

    ELSIF headName = "RETURN" THEN
      (* <RETURN> with no argument returns T, matching the original (the
         no-argument RETURN is only really meaningful inside a PROG/REPEAT
         block, which this slice doesn't compile yet). *)
      IF (z.rest = NIL) OR (z.rest.first = NIL) THEN
        Strings.Copy("1", opText)
      ELSE
        ok := CompileOperand(z.rest.first, opText);
        IF ~ok THEN RETURN FALSE END
      END;
      W("	RETURN "); W(opText); WLn;
      Strings.Copy(opText, resultText); termFlag := TRUE;
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

    ELSIF headName = "PRINTI" THEN
      IF (z.rest = NIL) OR (z.rest.first = NIL) OR (z.rest.first.kind # ZilObj.KString) THEN
        Err("CompileStmt: PRINTI expects a literal STRING"); RETURN FALSE
      END;
      CompileZapString(z.rest.first.strBuf^, strText);
      W("	PRINTI "); W(strText); WLn;
      Strings.Copy("1", resultText);
      RETURN TRUE

    ELSIF headName = "CRLF" THEN
      W("	CRLF"); WLn;
      Strings.Copy("1", resultText);
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

    ELSIF ~wantResult & (FindRoutineIdx(headName) >= 0) THEN
      (* A routine call whose value is discarded. V3's only CALL opcode
         always stores, so the original pops the unwanted result with
         FSTACK (EmitCall, zversion < 4 branch) rather than leaving it to
         accumulate on the stack — do the same. *)
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
VAR rt: ZilModel.RoutineRec; opText: ARRAY 64 OF CHAR; n: ARRAY 16 OF CHAR;
    a, bp: ZilObj.Zo; ok, isLast: BOOLEAN; nParams, i: INTEGER;
BEGIN
  rt := ZilModel.routines[idx];

  bp := rt.body;
  IF (bp = NIL) OR (bp.first = NIL) THEN
    Err("CompileRoutine: empty body"); RETURN FALSE
  END;

  (* The body is compiled into a buffer first, because the .FUNCT line has
     to name every local the body uses and the compiler temporaries it needs
     are only known once it has been compiled. *)
  BeginBuffer;
  WHILE (bp # NIL) & (bp.first # NIL) DO
    isLast := (bp.rest = NIL) OR (bp.rest.first = NIL);
    ok := CompileStmt(bp.first, isLast, opText);
    IF ~ok THEN EndBuffer; FlushBuffer; RETURN FALSE END;
    IF isLast & ~termFlag THEN
      (* no implicit fall-through return exists anywhere in the original
         either — every routine explicitly returns its last value, unless
         that last statement already left the routine on its own *)
      W("	RETURN "); W(opText); WLn
    END;
    bp := bp.rest
  END;
  EndBuffer;
  IF errFlag THEN RETURN FALSE END;

  W(".FUNCT "); W(rt.name.atomText);
  nParams := 0;
  a := rt.argSpec;
  WHILE (a # NIL) & (a.first # NIL) DO
    IF a.first.kind # ZilObj.KAtom THEN
      Err("CompileRoutine: only plain required parameters are supported yet");
      RETURN FALSE
    END;
    W(","); W(a.first.atomText);
    INC(nParams);
    a := a.rest
  END;
  IF nParams + tempMax > MaxLocals THEN
    Err("CompileRoutine: too many locals (parameters plus compiler temporaries)");
    RETURN FALSE
  END;
  i := 1;
  WHILE i <= tempMax DO
    Strings.IntToStr(i, n);
    W(",?TMP"); W(n);
    INC(i)
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
      W("	"); W(ZilModel.constants[i].name.atomText);
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
    text: ARRAY 64 OF CHAR;

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
  TakeFirst("HERE"); TakeFirst("SCORE"); TakeFirst("MOVES");
  i := 0;
  WHILE i < ZilModel.nGlobals DO
    IF ~taken[i] THEN order[n] := i; INC(n) END;
    INC(i)
  END;

  W("GLOBAL:: .TABLE"); WLn;
  j := 0;
  WHILE j < n DO
    i := order[j];
    IF ZilModel.globals[i].value = NIL THEN
      Strings.Copy("0", text)
    ELSIF ~ConstantText(ZilModel.globals[i].value, text) THEN
      Err("CompileGlobals: non-constant initializer for a global");
      W("	; offending global: "); W(ZilModel.globals[i].name.atomText); WLn;
      RETURN FALSE
    END;
    W("	.GVAR "); W(ZilModel.globals[i].name.atomText);
    W("="); W(text); WLn;
    INC(j)
  END;
  W("	.ENDT"); WLn; WLn;
  RETURN TRUE
END CompileGlobals;

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
PROCEDURE EmitEmptyObjectAndVocab;
VAR i: INTEGER;
BEGIN
  W("OBJECT:: .TABLE"); WLn;
  i := 0;
  WHILE i < 31 DO W("	.WORD 0"); WLn; INC(i) END;
  W("	.ENDT"); WLn; WLn;

  W("IMPURE::"); WLn; WLn;

  W("VOCAB:: .TABLE"); WLn;
  W("	.BYTE 0"); WLn;      (* no self-inserting break characters *)
  W("	.BYTE 7"); WLn;      (* entry length: 4 z-word bytes + 3 data *)
  W("	.WORD 0"); WLn;      (* entry count *)
  W("	.ENDT"); WLn; WLn;

  W("WORDS::"); WLn; WLn;
  W("ENDLOD::"); WLn; WLn
END EmitEmptyObjectAndVocab;

(* Emits a complete, assemblable .zap file for everything ZilModel has
   accumulated: the whole-program entry point this module previously
   lacked (CompileRoutine alone left the caller to hand-write a header and
   a GO routine around it). `entryName` names the routine the header's
   START:: label goes on — pass "GO" for the ZIL default. *)
PROCEDURE CompileProgram*(entryName: ARRAY OF CHAR): BOOLEAN;
VAR i, entryIdx: INTEGER; ok: BOOLEAN;
BEGIN
  ClearErr;
  labelCounter := 0;

  entryIdx := FindRoutineIdx(entryName);
  IF entryIdx < 0 THEN
    Err("CompileProgram: entry routine not defined"); RETURN FALSE
  END;

  W("	; compiled by ZilCompile (Oberon port of zilf)"); WLn;
  W("	.NEW 3"); WLn; WLn;

  CompileConstants;
  ok := CompileGlobals();
  IF ~ok THEN RETURN FALSE END;
  EmitEmptyObjectAndVocab;

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

  W("	.END"); WLn;
  RETURN TRUE
END CompileProgram;

BEGIN
  outIsFile := FALSE; buffering := FALSE; nBufLines := 0; lineBuf[0] := 0X
END ZilCompile.
