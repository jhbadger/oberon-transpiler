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

  Deliberately minimal for this first cut (get ONE trivial routine
  compiling correctly end-to-end before widening — same discipline used
  throughout every earlier phase of this port): handles a required-args-
  only ROUTINE whose body is FIX/STRING literals, LVAL references to its
  own parameters, and the four arithmetic BinaryOps (+, -, *, /). Every
  other ZBuiltins.cs builtin (237 of them in the original), COND/loops,
  OBJECT/property/table emission, and vocabulary/dictionary encoding are
  NOT implemented yet — this is phase 3b's starting slice, not its
  completion.

  Compound sub-expressions always route their result through the
  Z-machine stack (STACK) rather than allocating temporary locals — a
  correct, if not maximally efficient, simplification consistent with
  this port's "correctness first, optimization never" philosophy
  (confirmed skippable: the original's own peephole optimizer is the
  only thing that would tighten this, and we've already decided not to
  port it).
*)

IMPORT ZilObj, ZilModel, Out, Strings;

VAR
  errFlag*: BOOLEAN;
  errMsg*: ARRAY 512 OF CHAR;

PROCEDURE Err(msg: ARRAY OF CHAR);
BEGIN errFlag := TRUE; Strings.Copy(msg, errMsg) END Err;

PROCEDURE ClearErr*;
BEGIN errFlag := FALSE; errMsg[0] := 0X END ClearErr;

(* Renders a FIX as decimal text (negative numbers included, matching ZAP
   expression syntax — zapf's own expression parser accepts a leading
   "-"). *)
PROCEDURE FixText(v: INTEGER; VAR s: ARRAY OF CHAR);
BEGIN Strings.IntToStr(v, s) END FixText;

(* Compiles `z` as a value-producing expression, emitting whatever
   instructions are needed and returning the ZAP operand text that holds
   the result (a literal number, a local variable's bare name, or
   "STACK" for a compound sub-expression). Self-recursive (calls itself
   for each operand of a nested arithmetic FORM) — this transpiler has no
   FORWARD declarations, same reason as every other self-recursive
   procedure throughout this port (ZilRead.ReadOne, ZilEval.EvalImpl). *)
PROCEDURE CompileOperand(z: ZilObj.Zo; VAR opText: ARRAY OF CHAR): BOOLEAN;
VAR leftText, rightText: ARRAY 64 OF CHAR; opcode: ARRAY 16 OF CHAR;
    headName: ARRAY 64 OF CHAR; ok: BOOLEAN;
BEGIN
  IF z = NIL THEN Err("CompileOperand: NIL expression"); RETURN FALSE END;

  IF z.kind = ZilObj.KFix THEN
    FixText(z.fixVal, opText); RETURN TRUE

  ELSIF (z.kind = ZilObj.KForm) & (ZilObj.ListLength(z) = 2)
        & ZilObj.IsAtomNamed(z.first, "LVAL") THEN
    (* .X -> the local variable named X, referenced by its bare ZAP name *)
    IF z.rest.first.kind # ZilObj.KAtom THEN
      Err("CompileOperand: LVAL target must be an ATOM"); RETURN FALSE
    END;
    Strings.Copy(z.rest.first.atomText, opText); RETURN TRUE

  ELSIF z.kind = ZilObj.KForm THEN
    IF (z.first = NIL) OR (z.first.kind # ZilObj.KAtom) THEN
      Err("CompileOperand: expected an operator atom in form head"); RETURN FALSE
    END;
    Strings.Copy(z.first.atomText, headName);
    IF (headName = "+") OR (headName = "-") OR (headName = "*") OR (headName = "/") THEN
      IF (z.rest = NIL) OR (z.rest.first = NIL) OR (z.rest.rest = NIL) OR (z.rest.rest.first = NIL) THEN
        Err("CompileOperand: arithmetic op expects 2 args"); RETURN FALSE
      END;
      ok := CompileOperand(z.rest.first, leftText);
      IF ~ok THEN RETURN FALSE END;
      ok := CompileOperand(z.rest.rest.first, rightText);
      IF ~ok THEN RETURN FALSE END;
      IF headName = "+" THEN Strings.Copy("ADD", opcode)
      ELSIF headName = "-" THEN Strings.Copy("SUB", opcode)
      ELSIF headName = "*" THEN Strings.Copy("MUL", opcode)
      ELSE Strings.Copy("DIV", opcode)
      END;
      Out.String("	"); Out.String(opcode); Out.String(" "); Out.String(leftText);
      Out.String(","); Out.String(rightText); Out.String(" >STACK"); Out.Ln;
      Strings.Copy("STACK", opText); RETURN TRUE
    ELSE
      Err("CompileOperand: unrecognized or not-yet-implemented builtin"); RETURN FALSE
    END

  ELSE
    Err("CompileOperand: expression of this kind cannot be compiled yet"); RETURN FALSE
  END
END CompileOperand;

(* Emits one required-args-only routine as `.FUNCT name,param...` followed
   by its body (only the LAST statement's value matters — matches the
   original's own CompileStmt: wantResult is true only for the routine's
   final statement) and a RETURN of that value. *)
PROCEDURE CompileRoutine*(idx: INTEGER): BOOLEAN;
VAR rt: ZilModel.RoutineRec; p, opText: ARRAY 64 OF CHAR; a: ZilObj.Zo;
    bp: ZilObj.Zo; ok: BOOLEAN;
BEGIN
  rt := ZilModel.routines[idx];
  Out.String(".FUNCT "); Out.String(rt.name.atomText);

  a := rt.argSpec;
  WHILE (a # NIL) & (a.first # NIL) DO
    IF a.first.kind # ZilObj.KAtom THEN
      Err("CompileRoutine: only plain required parameters are supported yet");
      RETURN FALSE
    END;
    Out.String(","); Out.String(a.first.atomText);
    a := a.rest
  END;
  Out.Ln;

  bp := rt.body;
  IF (bp = NIL) OR (bp.first = NIL) THEN
    Err("CompileRoutine: empty body"); RETURN FALSE
  END;
  WHILE (bp.rest # NIL) & (bp.rest.first # NIL) DO
    (* not the last statement: compiled for effect only — not implemented
       yet in this first slice, since the trivial test case has exactly
       one body form *)
    Err("CompileRoutine: multi-statement bodies are not implemented yet");
    RETURN FALSE
  END;

  ok := CompileOperand(bp.first, opText);
  IF ~ok THEN RETURN FALSE END;
  Out.String("	RETURN "); Out.String(opText); Out.Ln;
  Out.Ln;
  RETURN TRUE
END CompileRoutine;

END ZilCompile.
