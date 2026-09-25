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

IMPORT ZilObj, Strings, Out;

CONST
  OValue* = 0;
  OReturn* = 1;
  OAgain*  = 2;

  MaxArgs = 64;
  MaxBindings = 32;

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

PROCEDURE ApplySubr*(name: ARRAY OF CHAR; args: ARRAY OF ZilObj.Zo; n: INTEGER): ZResult;
VAR sum, i: INTEGER; s: ARRAY 4096 OF CHAR;
BEGIN
  IF (name = "SET") OR (name = "SETG") OR (name = "GLOBAL") THEN
    IF n < 2 THEN RETURN Err("SET/SETG: expected 2 args") END;
    IF args[0].kind # ZilObj.KAtom THEN RETURN Err("SET/SETG: first arg must be an ATOM") END;
    IF name = "SET" THEN args[0].localVal := args[1] ELSE args[0].globalVal := args[1] END;
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

  ELSIF name = "RETURN" THEN
    RETURN ApplyReturnOrAgain(TRUE, args, n)

  ELSIF name = "AGAIN" THEN
    RETURN ApplyReturnOrAgain(FALSE, args, n)

  ELSE
    RETURN Err("unrecognized or not-yet-implemented SUBR")
  END
END ApplySubr;

(* ------------------------------------------------------------------ *)
(* Eval — one self-recursive procedure (FORM/LIST handling, and the      *)
(* FSUBRs QUOTE/COND/AND/OR, are inlined here rather than factored into  *)
(* helpers, since they need to call Eval and this transpiler has no      *)
(* FORWARD declarations — see ZilRead.mod's ReadOne for the same pattern *)
(* and a longer explanation).                                            *)
(* ------------------------------------------------------------------ *)

PROCEDURE Eval*(z: ZilObj.Zo): ZResult;
VAR
  head, n, resultHead, resultTail, cell, clause, body: ZilObj.Zo;
  nFirst, zFirst, zRestFirst, clauseFirst: ZilObj.Zo;
  r, cr: ZResult;
  args: ARRAY MaxArgs OF ZilObj.Zo;
  nargs, i: INTEGER;
  name: ARRAY 64 OF CHAR;
  isFSubr: BOOLEAN;
  (* PROG / REPEAT / BIND (see the dedicated comment at that branch below) *)
  progArgs, progNameAtom, progBindings, progBody, progAct: ZilObj.Zo;
  progBindAtoms, progSavedVals: ARRAY MaxBindings OF ZilObj.Zo;
  progNBind, progI: INTEGER;
  progOneBind, progTarget, progInit, progBindFirst, progBP: ZilObj.Zo;
  progRepeat, progCatchy, progStop, progAgain: BOOLEAN;
BEGIN
  IF z = NIL THEN RETURN MkVal(NIL) END;

  IF (z.kind = ZilObj.KAtom) OR (z.kind = ZilObj.KFix) OR (z.kind = ZilObj.KString)
     OR (z.kind = ZilObj.KChar) OR (z.kind = ZilObj.KVector) OR (z.kind = ZilObj.KFalse)
     OR (z.kind = ZilObj.KSubr) OR (z.kind = ZilObj.KFSubr) OR (z.kind = ZilObj.KActivation) THEN
    RETURN MkVal(z)

  ELSIF z.kind = ZilObj.KAdecl THEN
    RETURN Eval(z.adFirst)  (* DECL check skipped *)

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
      r := Eval(nFirst);
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
      IF head = NIL THEN RETURN ErrAtom("calling unassigned atom:", zFirst) END
    ELSE
      r := Eval(zFirst);
      IF ShouldPass(r) THEN RETURN r END;
      head := r.value
    END;

    IF (head.kind # ZilObj.KSubr) & (head.kind # ZilObj.KFSubr) THEN
      RETURN Err("not an applicable type (only SUBR/FSUBR are callable so far)")
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
        cr := Eval(clause.first);
        IF ShouldPass(cr) THEN RETURN cr END;
        IF IsTrue(cr.value) THEN
          r := cr;
          body := clause.rest;
          WHILE (body # NIL) & (body.first # NIL) DO
            r := Eval(body.first);
            IF ShouldPass(r) THEN RETURN r END;
            body := body.rest
          END;
          RETURN r
        END;
        n := n.rest
      END;
      RETURN r

    ELSIF isFSubr & (name = "AND") THEN
      r := MkVal(TrueVal());
      n := z.rest;
      WHILE (n # NIL) & (n.first # NIL) DO
        r := Eval(n.first);
        IF ShouldPass(r) THEN RETURN r END;
        IF ~IsTrue(r.value) THEN RETURN r END;
        n := n.rest
      END;
      RETURN r

    ELSIF isFSubr & (name = "OR") THEN
      r := MkVal(FalseVal());
      n := z.rest;
      WHILE (n # NIL) & (n.first # NIL) DO
        r := Eval(n.first);
        IF ShouldPass(r) THEN RETURN r END;
        IF IsTrue(r.value) THEN RETURN r END;
        n := n.rest
      END;
      RETURN r

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
          r := Eval(progInit);
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
            r := Eval(progBP.first);
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

    ELSIF isFSubr THEN
      RETURN Err("unrecognized or not-yet-implemented FSUBR")

    ELSE
      (* plain SUBR: evaluate all args left-to-right, then dispatch *)
      nargs := 0;
      n := z.rest;
      WHILE (n # NIL) & (n.first # NIL) DO
        r := Eval(n.first);
        IF ShouldPass(r) THEN RETURN r END;
        IF nargs < MaxArgs THEN args[nargs] := r.value; INC(nargs) END;
        n := n.rest
      END;
      RETURN ApplySubr(name, args, nargs)
    END

  ELSE
    RETURN MkVal(z)
  END
END Eval;

(* ------------------------------------------------------------------ *)
(* builtin registration                                                  *)
(* ------------------------------------------------------------------ *)

PROCEDURE Register(name: ARRAY OF CHAR; isF: BOOLEAN);
VAR atom: ZilObj.Zo;
BEGIN
  atom := ZilObj.Intern(name);
  atom.globalVal := ZilObj.NewSubr(name, isF)
END Register;

PROCEDURE InitBuiltins*;
VAR tAtom: ZilObj.Zo;
BEGIN
  Register("QUOTE", TRUE); Register("COND", TRUE); Register("AND", TRUE); Register("OR", TRUE);
  Register("PROG", TRUE); Register("REPEAT", TRUE); Register("BIND", TRUE);
  Register("RETURN", FALSE); Register("AGAIN", FALSE);
  Register("SET", FALSE); Register("SETG", FALSE); Register("GLOBAL", FALSE);
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

  tAtom := ZilObj.Intern("T");
  tAtom.globalVal := tAtom;  (* T is self-valued *)

  enclosingProgAtom := ZilObj.Intern("LPROG ")
END InitBuiltins;

END ZilEval.
