MODULE ZilModel;
(*
  ZilModel — phase 3a of the zilf port (see Notes/zilf_port_plan.md).
  This is the Oberon equivalent of the original's Zilf.ZModel.ZEnvironment:
  a plain accumulator for ROUTINE/OBJECT/GLOBAL/CONSTANT registrations
  produced while evaluating real ZIL source.

  This module does NOT compile anything. Confirmed against the original
  before writing this (ZilRoutine.cs, ZilModelObject.cs, ZilGlobal.cs, all
  read in earlier phases/this phase): ROUTINE/OBJECT/GLOBAL are FSUBRs
  that, when evaluated, just capture their raw arguments (mostly
  unevaluated — an argspec and body list are stored exactly as read, to be
  macro-expanded and compiled later) into a plain value and append it to a
  list — exactly the same shape as this port's existing DEFINE/DEFMAC
  registering a KFunction/KMacro as an atom's globalVal. The real
  interpretation of an OBJECT's property lists (which is a flag list vs a
  normal property vs IN/LOC, etc.) happens later, during compilation
  (Compilation.Objects.cs in the original) — not at registration time, so
  this module only needs to store the raw, unprocessed data.

  A future (not yet built) compilation pass will walk these lists and
  emit .zap text for each — see the plan doc's phase 3b.
*)

IMPORT ZilObj;

CONST
  MaxRoutines* = 4096;
  MaxObjects*  = 4096;
  MaxGlobals*  = 2048;
  MaxConstants* = 2048;

TYPE
  RoutineRec* = RECORD
    name*: ZilObj.Zo;
    act*: ZilObj.Zo;      (* optional activation atom, or NIL *)
    argSpec*: ZilObj.Zo;  (* raw, unevaluated arg-spec list *)
    body*: ZilObj.Zo      (* raw, unevaluated body form-chain *)
  END;

  ObjectRec* = RECORD
    name*: ZilObj.Zo;
    isRoom*: BOOLEAN;
    props*: ZilObj.Zo     (* raw chain of property lists, unevaluated *)
  END;

  GlobalRec* = RECORD
    name*: ZilObj.Zo;
    value*: ZilObj.Zo     (* already-evaluated default value, or NIL *)
  END;

VAR
  routines*: ARRAY MaxRoutines OF RoutineRec;
  nRoutines*: INTEGER;

  objects*: ARRAY MaxObjects OF ObjectRec;
  nObjects*: INTEGER;

  globals*: ARRAY MaxGlobals OF GlobalRec;
  nGlobals*: INTEGER;

  constants*: ARRAY MaxConstants OF GlobalRec;
  nConstants*: INTEGER;

PROCEDURE AddRoutine*(name, act, argSpec, body: ZilObj.Zo);
BEGIN
  IF nRoutines < MaxRoutines THEN
    routines[nRoutines].name := name;
    routines[nRoutines].act := act;
    routines[nRoutines].argSpec := argSpec;
    routines[nRoutines].body := body;
    INC(nRoutines)
  END
END AddRoutine;

PROCEDURE AddObject*(name: ZilObj.Zo; isRoom: BOOLEAN; props: ZilObj.Zo);
BEGIN
  IF nObjects < MaxObjects THEN
    objects[nObjects].name := name;
    objects[nObjects].isRoom := isRoom;
    objects[nObjects].props := props;
    INC(nObjects)
  END
END AddObject;

PROCEDURE AddGlobal*(name, value: ZilObj.Zo);
BEGIN
  IF nGlobals < MaxGlobals THEN
    globals[nGlobals].name := name;
    globals[nGlobals].value := value;
    INC(nGlobals)
  END
END AddGlobal;

PROCEDURE AddConstant*(name, value: ZilObj.Zo);
BEGIN
  IF nConstants < MaxConstants THEN
    constants[nConstants].name := name;
    constants[nConstants].value := value;
    INC(nConstants)
  END
END AddConstant;

PROCEDURE Reset*;
BEGIN
  nRoutines := 0; nObjects := 0; nGlobals := 0; nConstants := 0
END Reset;

END ZilModel.
