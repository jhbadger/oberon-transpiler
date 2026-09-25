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
  MaxTables*   = 2048;
  MaxSyntaxes* = 2048;
  MaxSynonyms* = 2048;
  MaxDirections* = 64;
  MaxBuzzwords*  = 512;
  MaxPropDefaults* = 512;
  MaxPropDefSpecs* = 128;

  (* SynonymRec.kind values *)
  SynPlain* = 0; SynVerb* = 1; SynPrep* = 2; SynAdj* = 3; SynDir* = 4;

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

  (* SYNTAX's real shape (Syntax.cs, ~400 lines of parsing: verb, up to
     two OBJECT/TOPIC clauses each with an optional preposition/FIND-flag/
     scope-bits, an action/preaction/action-name, and verb synonyms) is
     deferred to phase 3b — this just captures the raw, already-evaluated
     argument list (self-evaluating atoms/lists make evaluating them
     transparent, same reasoning as GLOBAL/CONSTANT/TABLE) exactly as
     given, the same "register now, really interpret later" pattern used
     for ROUTINE/OBJECT's raw property lists. *)
  SyntaxRec* = RECORD
    rawArgs*: ZilObj.Zo   (* raw chain of the SYNTAX call's own arguments *)
  END;

  (* SYNONYM/VERB-SYNONYM/PREP-SYNONYM/ADJ-SYNONYM/DIR-SYNONYM all share
     this one shape in the original (PerformSynonym): an original atom and
     one atom it's a synonym of; `kind` distinguishes which SYNONYM
     variant registered it (SynPlain/SynVerb/SynPrep/SynAdj/SynDir). *)
  SynonymRec* = RECORD
    kind*: INTEGER;
    original*: ZilObj.Zo;
    synonym*: ZilObj.Zo
  END;

  (* PROPDEF's simple case (<PROPDEF NAME default-value>, by far the most
     common in real source — e.g. zork1.zil's own <PROPDEF SIZE 5>) just
     needs a name and an already-evaluated default value. The rarer
     complex-pattern case (<PROPDEF DIRECTIONS <> (DIR TO R:ROOM = ...)>,
     used to define direction-property syntax) is captured as raw,
     unevaluated spec forms — real parsing (ComplexPropDef.Parse in the
     original, 1,021 lines, not ported) is deferred to phase 3b, same
     "register now, interpret later" pattern as OBJECT/SYNTAX. *)
  PropDefaultRec* = RECORD
    name*: ZilObj.Zo;
    value*: ZilObj.Zo
  END;

  PropDefSpecRec* = RECORD
    name*: ZilObj.Zo;
    rawSpec*: ZilObj.Zo
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

  (* TABLE/LTABLE/PTABLE/PLTABLE/ITABLE values (a KTable Zo — see
     ZilObj.mod's own comment on that kind) that weren't flagged
     TEMP-TABLE — matches the original's ZEnvironment.Tables, which is
     just a List<ZilTable> for the same reason (a TEMP-TABLE is
     compiler-internal scratch space, never part of the final output). *)
  tables*: ARRAY MaxTables OF ZilObj.Zo;
  nTables*: INTEGER;

  syntaxes*: ARRAY MaxSyntaxes OF SyntaxRec;
  nSyntaxes*: INTEGER;

  synonyms*: ARRAY MaxSynonyms OF SynonymRec;
  nSynonyms*: INTEGER;

  directions*: ARRAY MaxDirections OF ZilObj.Zo;
  nDirections*: INTEGER;

  buzzwords*: ARRAY MaxBuzzwords OF ZilObj.Zo;
  nBuzzwords*: INTEGER;

  propDefaults*: ARRAY MaxPropDefaults OF PropDefaultRec;
  nPropDefaults*: INTEGER;

  propDefSpecs*: ARRAY MaxPropDefSpecs OF PropDefSpecRec;
  nPropDefSpecs*: INTEGER;

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

PROCEDURE AddTable*(t: ZilObj.Zo);
BEGIN
  IF nTables < MaxTables THEN
    tables[nTables] := t;
    INC(nTables)
  END
END AddTable;

PROCEDURE AddSyntax*(rawArgs: ZilObj.Zo);
BEGIN
  IF nSyntaxes < MaxSyntaxes THEN
    syntaxes[nSyntaxes].rawArgs := rawArgs;
    INC(nSyntaxes)
  END
END AddSyntax;

PROCEDURE AddSynonym*(kind: INTEGER; original, synonym: ZilObj.Zo);
BEGIN
  IF nSynonyms < MaxSynonyms THEN
    synonyms[nSynonyms].kind := kind;
    synonyms[nSynonyms].original := original;
    synonyms[nSynonyms].synonym := synonym;
    INC(nSynonyms)
  END
END AddSynonym;

PROCEDURE AddDirection*(atom: ZilObj.Zo);
BEGIN
  IF nDirections < MaxDirections THEN
    directions[nDirections] := atom;
    INC(nDirections)
  END
END AddDirection;

PROCEDURE AddBuzzword*(atom: ZilObj.Zo);
BEGIN
  IF nBuzzwords < MaxBuzzwords THEN
    buzzwords[nBuzzwords] := atom;
    INC(nBuzzwords)
  END
END AddBuzzword;

PROCEDURE AddPropDefault*(name, value: ZilObj.Zo);
BEGIN
  IF nPropDefaults < MaxPropDefaults THEN
    propDefaults[nPropDefaults].name := name;
    propDefaults[nPropDefaults].value := value;
    INC(nPropDefaults)
  END
END AddPropDefault;

PROCEDURE AddPropDefSpec*(name, rawSpec: ZilObj.Zo);
BEGIN
  IF nPropDefSpecs < MaxPropDefSpecs THEN
    propDefSpecs[nPropDefSpecs].name := name;
    propDefSpecs[nPropDefSpecs].rawSpec := rawSpec;
    INC(nPropDefSpecs)
  END
END AddPropDefSpec;

PROCEDURE Reset*;
BEGIN
  nRoutines := 0; nObjects := 0; nGlobals := 0; nConstants := 0; nTables := 0;
  nSyntaxes := 0; nSynonyms := 0; nDirections := 0; nBuzzwords := 0;
  nPropDefaults := 0; nPropDefSpecs := 0
END Reset;

END ZilModel.
