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

  Deliberately minimal (get ONE trivial routine compiling correctly
  end-to-end before widening, then widen one builtin at a time — same
  discipline used throughout every earlier phase of this port): handles a
  required-args-only ROUTINE with a multi-statement body, where each
  statement is a FIX/STRING literal, an LVAL reference to one of the
  routine's own parameters, the four arithmetic BinaryOps (+, -, *, /), or
  one of SET/PRINTI/PRINTN/CRLF. Every other ZBuiltins.cs builtin (237 of
  them in the original), COND/loops, OBJECT/property/table emission, and
  vocabulary/dictionary encoding are NOT implemented yet — this is phase
  3b's starting slice, not its completion.

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

(* Emits an unconditional branch to `label` — matches the original's
   `rb.Branch(label)`. *)
PROCEDURE EmitBranch(label: ARRAY OF CHAR);
BEGIN Out.String("	JUMP "); Out.String(label); Out.Ln END EmitBranch;

(* Emits a predicate instruction (op1[,op2]) branching to `label` when the
   condition holds and `polarity` is TRUE, or when it does NOT hold and
   `polarity` is FALSE — i.e. always: "go to label iff (condition-holds) =
   polarity". Matches zapf's own branch-marker convention confirmed
   earlier from ZapfParser.mod: "/label" branches on true, "\label" on
   false. Pass an empty `op2` for a 1-operand predicate like ZERO?. *)
PROCEDURE EmitPredInstr(opcode, op1, op2, label: ARRAY OF CHAR; polarity: BOOLEAN);
BEGIN
  Out.String("	"); Out.String(opcode); Out.String(" "); Out.String(op1);
  IF op2[0] # 0X THEN Out.String(","); Out.String(op2) END;
  IF polarity THEN Out.String(" /") ELSE Out.String(" \") END;
  Out.String(label); Out.Ln
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
   original's own generic `BranchIfNonZero` fallback path. Only calls
   CompileOperand, never CompileStmt, so — unlike CompileStmt below — this
   has no forward-reference concern and doesn't need to be self-recursive
   itself (though it does recurse into CompileOperand, which is already
   self-recursive on its own). *)
PROCEDURE CompileCondition(z: ZilObj.Zo; label: ARRAY OF CHAR; polarity: BOOLEAN): BOOLEAN;
VAR headName: ARRAY 64 OF CHAR; leftText, rightText, opText, empty: ARRAY 64 OF CHAR; ok: BOOLEAN;
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
      ok := CompileOperand(z.rest.rest.first, rightText);
      IF ~ok THEN RETURN FALSE END;
      IF headName = "L?" THEN EmitPredInstr("LESS?", leftText, rightText, label, polarity)
      ELSIF headName = "G?" THEN EmitPredInstr("GRTR?", leftText, rightText, label, polarity)
      ELSE EmitPredInstr("EQUAL?", leftText, rightText, label, polarity)
      END;
      RETURN TRUE

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
   arbitrary statements, including nested CONDs) rather than factored into
   a separate procedure — same forward-reference reason as everywhere else
   in this port that ended up as one self-recursive procedure (ZilRead.
   ReadOne, ZilEval.EvalImpl): CompileStmt calling a separate CompileCOND
   which itself calls back into CompileStmt would be mutual recursion,
   which this transpiler's lack of FORWARD declarations can't express.
   CompileCondition, by contrast, only ever calls CompileOperand — never
   CompileStmt — so it has no such issue and stays its own procedure.

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
VAR headName: ARRAY 64 OF CHAR; opText: ARRAY 64 OF CHAR; strText: ARRAY 4096 OF CHAR;
    targetAtom: ZilObj.Zo; ok: BOOLEAN;
    (* COND *)
    nextLabel, endLabel: ARRAY 16 OF CHAR; elsePart, isLastClauseStmt, hasMoreClauses: BOOLEAN;
    c, cond, body, bp: ZilObj.Zo; clauseResult: ARRAY 64 OF CHAR;
BEGIN
  IF z = NIL THEN Err("CompileStmt: NIL statement"); RETURN FALSE END;

  IF (z.kind = ZilObj.KForm) & (z.first # NIL) & (z.first.kind = ZilObj.KAtom) THEN
    Strings.Copy(z.first.atomText, headName);

    IF headName = "SET" THEN
      IF (z.rest = NIL) OR (z.rest.first = NIL) OR (z.rest.first.kind # ZilObj.KAtom)
         OR (z.rest.rest = NIL) OR (z.rest.rest.first = NIL) THEN
        Err("CompileStmt: SET expects a local atom and a value"); RETURN FALSE
      END;
      targetAtom := z.rest.first;
      ok := CompileOperand(z.rest.rest.first, opText);
      IF ~ok THEN RETURN FALSE END;
      Out.String("	SET '"); Out.String(targetAtom.atomText); Out.String(","); Out.String(opText); Out.Ln;
      Strings.Copy(targetAtom.atomText, resultText);
      RETURN TRUE

    ELSIF headName = "PRINTI" THEN
      IF (z.rest = NIL) OR (z.rest.first = NIL) OR (z.rest.first.kind # ZilObj.KString) THEN
        Err("CompileStmt: PRINTI expects a literal STRING"); RETURN FALSE
      END;
      CompileZapString(z.rest.first.strBuf^, strText);
      Out.String("	PRINTI "); Out.String(strText); Out.Ln;
      Strings.Copy("1", resultText);
      RETURN TRUE

    ELSIF headName = "CRLF" THEN
      Out.String("	CRLF"); Out.Ln;
      Strings.Copy("1", resultText);
      RETURN TRUE

    ELSIF headName = "PRINTN" THEN
      IF (z.rest = NIL) OR (z.rest.first = NIL) THEN
        Err("CompileStmt: PRINTN expects 1 arg"); RETURN FALSE
      END;
      ok := CompileOperand(z.rest.first, opText);
      IF ~ok THEN RETURN FALSE END;
      Out.String("	PRINTN "); Out.String(opText); Out.Ln;
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
          Strings.Copy("1", clauseResult)
        ELSE
          bp := body;
          WHILE (bp # NIL) & (bp.first # NIL) DO
            isLastClauseStmt := (bp.rest = NIL) OR (bp.rest.first = NIL);
            ok := CompileStmt(bp.first, wantResult & isLastClauseStmt, clauseResult);
            IF ~ok THEN RETURN FALSE END;
            bp := bp.rest
          END
        END;

        IF wantResult & (clauseResult # "STACK") THEN
          Out.String("	PUSH "); Out.String(clauseResult); Out.Ln
        END;

        hasMoreClauses := (c.rest # NIL) & (c.rest.first # NIL);
        IF hasMoreClauses OR (wantResult & ~elsePart) THEN
          EmitBranch(endLabel)
        END;

        Out.String(nextLabel); Out.String(":"); Out.Ln;
        IF ~elsePart THEN NewLabel(nextLabel) END;
        c := c.rest
      END;

      IF wantResult & ~elsePart THEN
        Out.String("	PUSH 0"); Out.Ln
      END;
      Out.String(endLabel); Out.String(":"); Out.Ln;
      IF wantResult THEN Strings.Copy("STACK", resultText) END;
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
PROCEDURE CompileRoutine*(idx: INTEGER): BOOLEAN;
VAR rt: ZilModel.RoutineRec; opText: ARRAY 64 OF CHAR; a: ZilObj.Zo;
    bp: ZilObj.Zo; ok, isLast: BOOLEAN;
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

  WHILE (bp # NIL) & (bp.first # NIL) DO
    isLast := (bp.rest = NIL) OR (bp.rest.first = NIL);
    ok := CompileStmt(bp.first, isLast, opText);
    IF ~ok THEN RETURN FALSE END;
    IF isLast THEN
      Out.String("	RETURN "); Out.String(opText); Out.Ln
    END;
    bp := bp.rest
  END;
  Out.Ln;
  RETURN TRUE
END CompileRoutine;

END ZilCompile.
