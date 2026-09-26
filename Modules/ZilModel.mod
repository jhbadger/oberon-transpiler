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

IMPORT ZilObj, Strings;

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
  MaxTellPatterns* = 128;
  MaxVocab* = 2048;

  (* PartOfSpeech bits, copied from the original's own enum. The low two
     bits are the "First" mask, which says which part of speech a word's
     FIRST data byte describes when it has more than one. *)
  PsFirstMask*    = 3;
  PsVerbFirst*    = 1;
  PsAdjFirst*     = 2;
  PsDirFirst*     = 3;
  PsBuzzword*     = 4;
  PsPreposition*  = 8;
  PsDirection*    = 16;
  PsAdjective*    = 32;
  PsVerb*         = 64;
  PsObject*       = 128;

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
  (* A decomposed <SYNTAX VERB [prep] OBJECT [(FIND flag)] [(scope opts)]
     [prep OBJECT ...] = ACTION [PREACTION]> line. The raw arguments are
     kept too, for diagnostics. Scope option bits are the original's
     ScopeFlags.Original values; `opts` defaults to OnGround+InRoom+
     Carried+Held (240) when the line names none, as it does there. *)
  SyntaxRec* = RECORD
    rawArgs*: ZilObj.Zo;
    verb*: ARRAY 64 OF CHAR;
    (* NOTE: this field is `numObjects`, not `nObjects`, because this
       module already exports a VAR called nObjects (the object count).
       An exported top-level VAR becomes a bare, unscoped C #define in the
       generated code, so a RECORD FIELD of the same name is rewritten too
       and stops existing — `s.nObjects` compiles to `s.ZilModel_nObjects`.
       Record field names are safe in general; they are not safe when they
       collide with an exported VAR in the same module. *)
    numObjects*: INTEGER;
    prep1*, prep2*: ARRAY 64 OF CHAR;
    find1*, find2*: ARRAY 64 OF CHAR;
    opts1*, opts2*: INTEGER;
    action*, preAction*: ARRAY 64 OF CHAR;
    actionIdx*: INTEGER      (* index into the action table *)
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

  (* One TELL token pattern (the original's ZModel.TellPattern): a sequence
     of token specs to match against TELL's arguments, and the output FORM
     to compile in their place. `tokens` is a LIST of specs, each an atom
     (match that atom), a LIST of atoms (match any of them), the atom `*`
     (match anything and capture it), or a <GVAL atom> form (match that
     exact GVAL). `output` is a FORM whose <LVAL ...> elements are replaced
     by the captures, in order. Both are kept as ordinary Zo structures
     rather than a parsed representation — matching walks them directly,
     which is cheap at this scale and keeps ADD-TELL-TOKENS's job to almost
     nothing. *)
  TellPatternRec* = RECORD
    tokens*: ZilObj.Zo;
    output*: ZilObj.Zo
  END;

TYPE
  (* One dictionary word. `pos` is the set of PartOfSpeech bits it has, and
     the per-part values are the numbers the parser matches on — assigned
     counting DOWN from 255 in its own sequence per part of speech, exactly
     as the original's OldParserVocabFormat does. *)
  VocabRec* = RECORD
    text*: ARRAY 64 OF CHAR;
    pos*: INTEGER;
    verbVal*, prepVal*, adjVal*, dirVal*, buzzVal*: INTEGER
  END;

VAR
  (* The Z-machine version the program targets, set by <VERSION ...> (see
     ZilEval's VERSION subr) — the original's ZEnvironment.ZVersion, which
     likewise defaults to 3 when the source never says. Read by ZilCompile
     for every version-dependent emission decision. *)
  zversion*: INTEGER;

  (* Set by <VERSION ZIP TIME>: V3's optional "time" status line instead of
     the score/moves one. Recorded for completeness (the original's
     ZEnvironment.TimeStatusLine); nothing reads it yet. *)
  timeStatusLine*: BOOLEAN;

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

  tellPatterns*: ARRAY MaxTellPatterns OF TellPatternRec;
  nTellPatterns*: INTEGER;

  vocab*: ARRAY MaxVocab OF VocabRec;
  nVocab*: INTEGER;
  nextVerb*, nextPrep*, nextAdj*, nextBuzz*: INTEGER;

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

PROCEDURE AddSyntax*(rawArgs: ZilObj.Zo): INTEGER;
BEGIN
  IF nSyntaxes >= MaxSyntaxes THEN RETURN -1 END;
  syntaxes[nSyntaxes].rawArgs := rawArgs;
  syntaxes[nSyntaxes].verb[0] := 0X;
  syntaxes[nSyntaxes].numObjects := 0;
  syntaxes[nSyntaxes].prep1[0] := 0X; syntaxes[nSyntaxes].prep2[0] := 0X;
  syntaxes[nSyntaxes].find1[0] := 0X; syntaxes[nSyntaxes].find2[0] := 0X;
  syntaxes[nSyntaxes].opts1 := 240; syntaxes[nSyntaxes].opts2 := 240;
  syntaxes[nSyntaxes].action[0] := 0X; syntaxes[nSyntaxes].preAction[0] := 0X;
  syntaxes[nSyntaxes].actionIdx := -1;
  INC(nSyntaxes);
  RETURN nSyntaxes - 1
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

(* DIRECTIONS replaces the whole set rather than adding to it, matching the
   original's Directions.Clear() — a game that redefines the library's list
   must not end up with both. *)
PROCEDURE ClearDirections*;
BEGIN
  nDirections := 0
END ClearDirections;

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

PROCEDURE AddTellPattern*(tokens, output: ZilObj.Zo);
BEGIN
  IF nTellPatterns < MaxTellPatterns THEN
    tellPatterns[nTellPatterns].tokens := tokens;
    tellPatterns[nTellPatterns].output := output;
    INC(nTellPatterns)
  END
END AddTellPattern;

(* Bitwise OR over a byte. This dialect has no BITS/SET conversion for
   INTEGERs, and the part-of-speech field really is a byte of flags. *)
PROCEDURE BitOr*(a, b: INTEGER): INTEGER;
VAR r, bit: INTEGER;
BEGIN
  r := 0; bit := 1;
  WHILE bit <= 128 DO
    IF ((a DIV bit) MOD 2 = 1) OR ((b DIV bit) MOD 2 = 1) THEN r := r + bit END;
    bit := bit * 2
  END;
  RETURN r
END BitOr;

(* Finds a dictionary word by its text, or -1. *)
PROCEDURE FindVocab*(text: ARRAY OF CHAR): INTEGER;
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE i < nVocab DO
    IF vocab[i].text = text THEN RETURN i END;
    INC(i)
  END;
  RETURN -1
END FindVocab;

(* Adds `posBits` to the word's parts of speech, creating the word if it is
   new, and assigns it a number for that part if it doesn't have one yet.
   Returns its index. A word legitimately has several parts of speech at
   once — "north" is both a direction and a verb — which is why the parts
   accumulate rather than replace. *)
(* Whether adding a part of speech to this word should also set its "First"
   flag. Ported from OldParserWord.ShouldSetFirst: yes only when the word has
   no value-recording part of speech yet, and never for a buzzword.

   The First flags are the low two bits of the word's data byte, and they are
   what tells the library which of the two value bytes to read - zillib's
   CHKWORD? takes VOCAB-V1 when <BAND flags 3> matches the part of speech's
   P1? constant and VOCAB-V2 otherwise. Leaving them clear is quiet and
   fatal: every verb's number reads as 0, so the parser recognises every word
   and then does nothing with any command.

   This port has no NEW-VOC? or COMPACT-VOCABULARY?, both of which would
   exclude some parts of speech from the test, and in V4+ ADJECTIVE records
   no value so it would be excluded too. *)
PROCEDURE ShouldSetFirst(i: INTEGER): BOOLEAN;
VAR p: INTEGER;
BEGIN
  p := vocab[i].pos;
  IF (p DIV PsBuzzword) MOD 2 = 1 THEN RETURN FALSE END;
  IF zversion >= 4 THEN
    IF (p DIV PsAdjective) MOD 2 = 1 THEN p := p - PsAdjective END
  END;
  RETURN p = 0
END ShouldSetFirst;

PROCEDURE AddVocab*(text: ARRAY OF CHAR; posBits: INTEGER): INTEGER;
VAR i, firstBits: INTEGER;
BEGIN
  i := FindVocab(text);
  IF i < 0 THEN
    IF nVocab >= MaxVocab THEN RETURN -1 END;
    i := nVocab; INC(nVocab);
    Strings.Copy(text, vocab[i].text);
    vocab[i].pos := 0;
    vocab[i].verbVal := 0; vocab[i].prepVal := 0; vocab[i].adjVal := 0;
    vocab[i].dirVal := 0; vocab[i].buzzVal := 0
  END;

  firstBits := 0;
  IF (posBits DIV PsVerb) MOD 2 = 1 THEN
    IF (vocab[i].pos DIV PsVerb) MOD 2 = 0 THEN
      vocab[i].verbVal := nextVerb; DEC(nextVerb);
      IF ShouldSetFirst(i) THEN firstBits := PsVerbFirst END
    END
  END;
  IF (posBits DIV PsPreposition) MOD 2 = 1 THEN
    IF (vocab[i].pos DIV PsPreposition) MOD 2 = 0 THEN
      vocab[i].prepVal := nextPrep; DEC(nextPrep)
    END
  END;
  IF (posBits DIV PsAdjective) MOD 2 = 1 THEN
    IF (vocab[i].pos DIV PsAdjective) MOD 2 = 0 THEN
      vocab[i].adjVal := nextAdj; DEC(nextAdj);
      IF (zversion < 4) & (firstBits = 0) & ShouldSetFirst(i) THEN
        firstBits := PsAdjFirst
      END
    END
  END;
  IF (posBits DIV PsDirection) MOD 2 = 1 THEN
    IF (vocab[i].pos DIV PsDirection) MOD 2 = 0 THEN
      IF (firstBits = 0) & ShouldSetFirst(i) THEN firstBits := PsDirFirst END
    END
  END;
  IF (posBits DIV PsBuzzword) MOD 2 = 1 THEN
    IF (vocab[i].pos DIV PsBuzzword) MOD 2 = 0 THEN
      vocab[i].buzzVal := nextBuzz; DEC(nextBuzz)
    END
  END;

  (* the parts of speech are a bit set, so adding one is a union; the
     part-of-speech field is a single byte, hence bits 0..7. The First bits
     are not part of that union - they are a two-bit field, so they replace
     rather than accumulate, and only the first value-recording part of
     speech ever sets them. *)
  vocab[i].pos := BitOr(vocab[i].pos, posBits);
  IF firstBits # 0 THEN
    vocab[i].pos := vocab[i].pos - (vocab[i].pos MOD 4) + firstBits
  END;
  RETURN i
END AddVocab;

PROCEDURE Reset*;
BEGIN
  zversion := 3; timeStatusLine := FALSE;
  nRoutines := 0; nObjects := 0; nGlobals := 0; nConstants := 0; nTables := 0;
  nSyntaxes := 0; nSynonyms := 0; nDirections := 0; nBuzzwords := 0;
  nPropDefaults := 0; nPropDefSpecs := 0; nTellPatterns := 0;
  nVocab := 0;
  nextVerb := 255; nextPrep := 255; nextAdj := 255; nextBuzz := 255
END Reset;

BEGIN
  Reset
END ZilModel.
