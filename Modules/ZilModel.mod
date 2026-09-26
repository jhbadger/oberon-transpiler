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
  MaxBitSynonyms* = 64;
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
    (* the optional THIRD value after '=', which names the action explicitly
       instead of deriving it from the action routine. advent needs it:
       <SYNTAX WATER OBJECT (FIND SPONGEBIT) = V-POUR-LIQUID PRE-WATER WATER>
       shares one routine between several verbs but wants V?WATER, not
       V?POUR-LIQUID. Empty means "derive it". *)
    actionName*: ARRAY 64 OF CHAR;
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
    verbVal*, prepVal*, adjVal*, dirVal*, buzzVal*: INTEGER;
    (* A direction word's own "value" is not a number stored here — it is
       the PROPERTY NUMBER of the exit property registered under that
       word's TEXT (see ZilCompile.PartValue), which only exists once
       CompileObjects has run. A direction SYNONYM ("N" for "NORTH") needs
       the SAME property, which is registered under "NORTH", not "N" — so
       a merged-in direction records which word's text to look the
       property up under instead. Empty means "use my own text", the
       ordinary case. *)
    dirAlias*: ARRAY 64 OF CHAR;
    (* Set by ApplyVocabMerges when this word turns out to Z-CHARACTER-encode
       to the same dictionary key as an earlier-registered word (V3's 6
       significant characters can't tell "BOTTLE" from "BOTTLED" apart) - the
       index of the SURVIVING word this one was merged into, or -1 for an
       ordinary word (or the survivor itself). A merged word gets no
       .ZWORD row of its own; its W? symbol aliases the survivor's. *)
    mergedInto*: INTEGER
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

  (* <BIT-SYNONYM FIRST ALIAS...> makes each ALIAS another name for the
     object flag FIRST, sharing its bit rather than claiming a new one -
     which matters, because V3 has only 32 flags. Kept as two parallel name
     arrays rather than a map: there are never many. *)
  bitSynAlias*: ARRAY MaxBitSynonyms OF ARRAY 64 OF CHAR;
  bitSynTarget*: ARRAY MaxBitSynonyms OF ARRAY 64 OF CHAR;
  nBitSynonyms*: INTEGER;

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

(* A later <ROUTINE NAME ...> for an already-defined NAME replaces the
   earlier definition rather than adding a second one with the same name.
   MDL only allows this inside <BIND ((REDEFINE T)) ...> and throws
   otherwise; this port takes the same "redefinition is always silently
   allowed" simplification already used for SET/SETG/GLOBAL/CONSTANT and
   DEFINE/DEFMAC (see ZilEval's own SET/SETG/GLOBAL/CONSTANT comment) rather
   than tracking the REDEFINE local and rejecting an unguarded one.

   advent.zil relies on this for real: it wraps its own V-QUIT and
   V-THINK-ABOUT in <BIND ((REDEFINE T)) ...> to override zillib's. Without
   replacing in place, both definitions were emitted as two `.FUNCT` bodies
   under the same name, which zapf rejects as "function redefined". *)
PROCEDURE AddRoutine*(name, act, argSpec, body: ZilObj.Zo);
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE i < nRoutines DO
    IF routines[i].name = name THEN
      routines[i].act := act;
      routines[i].argSpec := argSpec;
      routines[i].body := body;
      RETURN
    END;
    INC(i)
  END;
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
  syntaxes[nSyntaxes].actionName[0] := 0X;
  syntaxes[nSyntaxes].actionIdx := -1;
  INC(nSyntaxes);
  RETURN nSyntaxes - 1
END AddSyntax;

(* Registers the synonym word's OWN vocab entry immediately, matching the
   original's timing: <SYNONYM ORIGINAL alias> looks up/creates the IWord
   for `alias` as soon as the form is evaluated, not deferred until
   ApplyVocabSynonyms actually copies ORIGINAL's data onto it. This matters
   for ApplyVocabMerges (ZilCompile.mod), which runs before
   ApplyVocabSynonyms and scans the vocab table for dictionary-key
   collisions: a synonym word created only at ApplyVocabSynonyms time (as
   this used to do, via AddVocab there) would still be missing from the
   table when ApplyVocabMerges looks, silently skipping any collision that
   only exists between two synonym words (advent's LUBRICANT/LUBRICATE:
   <SYNONYM OIL LUBRICANT> and <VERB-SYNONYM OIL GREASE LUBRICATE> both
   encode to the same V3 dictionary key). posBits=0 is safe to pass even if
   the atom already has vocab data (from being used directly elsewhere) —
   AddVocab only creates a fresh entry when one doesn't already exist. *)
PROCEDURE AddSynonym*(kind: INTEGER; original, synonym: ZilObj.Zo);
VAR ignore: INTEGER;
BEGIN
  IF nSynonyms < MaxSynonyms THEN
    synonyms[nSynonyms].kind := kind;
    synonyms[nSynonyms].original := original;
    synonyms[nSynonyms].synonym := synonym;
    INC(nSynonyms)
  END;
  ignore := AddVocab(synonym.atomText, 0)
END AddSynonym;

(* Copies EVERY part of speech `src`'s vocab entry has onto `dest`'s,
   reusing src's OWN values rather than allocating fresh ones. This is what
   <SYNONYM ORIGINAL alias...> (and VERB-/DIR-/PREP-/ADJ-SYNONYM, which this
   port treats identically — see the note below) needs: "N" must carry the
   EXACT SAME direction number as "NORTH", not a freshly allocated one,
   since exit tables and grammar conditions were built against NORTH's
   number specifically.

   Ported from OldParserWord.Merge, but flattened: the original clears and
   rebuilds the WHOLE word from scratch for every part it copies (so that
   each part's own SetXxx call re-triggers the First-flag logic in a fixed
   priority order); this does the same bookkeeping (ShouldSetFirst, and the
   unconditional clear a new Preposition/Buzzword registration causes) in
   one pass instead, which gives the same result for a freshly-created
   synonym word (the only case this port creates one for) without the
   clear-and-rebuild machinery.

   NOTE ON THE FIVE SYNONYM KINDS: the original's own MakeSynonym, for the
   OLD PARSER format this port targets (V1-3, which is the only format this
   port's vocabulary/syntax machinery implements), IGNORES the requested
   part of speech entirely and always does a full merge - so SYNONYM,
   VERB-SYNONYM, DIR-SYNONYM, PREP-SYNONYM and ADJ-SYNONYM are genuinely
   identical on V1-3, and treating them that way here is not a
   simplification, it is what the original does too. *)
PROCEDURE MergeVocabWord*(dest, src: INTEGER);
VAR firstBits: INTEGER; clearFirst: BOOLEAN;
BEGIN
  firstBits := 0; clearFirst := FALSE;
  IF (vocab[src].pos DIV PsVerb) MOD 2 = 1 THEN
    IF (vocab[dest].pos DIV PsVerb) MOD 2 = 0 THEN
      vocab[dest].verbVal := vocab[src].verbVal;
      IF ShouldSetFirst(dest) THEN firstBits := PsVerbFirst END
    END
  END;
  IF (vocab[src].pos DIV PsPreposition) MOD 2 = 1 THEN
    IF (vocab[dest].pos DIV PsPreposition) MOD 2 = 0 THEN
      vocab[dest].prepVal := vocab[src].prepVal;
      clearFirst := TRUE
    END
  END;
  IF (vocab[src].pos DIV PsAdjective) MOD 2 = 1 THEN
    IF (vocab[dest].pos DIV PsAdjective) MOD 2 = 0 THEN
      vocab[dest].adjVal := vocab[src].adjVal;
      IF (zversion < 4) & (firstBits = 0) & ShouldSetFirst(dest) THEN
        firstBits := PsAdjFirst
      END
    END
  END;
  IF (vocab[src].pos DIV PsDirection) MOD 2 = 1 THEN
    IF (vocab[dest].pos DIV PsDirection) MOD 2 = 0 THEN
      IF vocab[src].dirAlias[0] # 0X THEN
        Strings.Copy(vocab[src].dirAlias, vocab[dest].dirAlias)
      ELSE
        Strings.Copy(vocab[src].text, vocab[dest].dirAlias)
      END;
      IF (firstBits = 0) & ShouldSetFirst(dest) THEN firstBits := PsDirFirst END
    END
  END;
  IF (vocab[src].pos DIV PsBuzzword) MOD 2 = 1 THEN
    IF (vocab[dest].pos DIV PsBuzzword) MOD 2 = 0 THEN
      vocab[dest].buzzVal := vocab[src].buzzVal;
      clearFirst := TRUE
    END
  END;

  (* the part-of-speech bits merge in, but NOT src's own First-bits — dest
     computes its own from scratch, same as AddVocab does *)
  vocab[dest].pos := BitOr(vocab[dest].pos, vocab[src].pos - (vocab[src].pos MOD 4));
  IF clearFirst THEN
    vocab[dest].pos := vocab[dest].pos - (vocab[dest].pos MOD 4)
  ELSIF firstBits # 0 THEN
    vocab[dest].pos := vocab[dest].pos - (vocab[dest].pos MOD 4) + firstBits
  END
END MergeVocabWord;

(* DIRECTIONS replaces the whole set rather than adding to it, matching the
   original's Directions.Clear() — a game that redefines the library's list
   must not end up with both. *)
(* The flag an alias stands for, or an empty string when `name` is not an
   alias. Aliases are resolved transitively at registration time, so one hop
   is always enough here. *)
PROCEDURE BitSynonymOf*(name: ARRAY OF CHAR; VAR target: ARRAY OF CHAR): BOOLEAN;
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE i < nBitSynonyms DO
    IF bitSynAlias[i] = name THEN Strings.Copy(bitSynTarget[i], target); RETURN TRUE END;
    INC(i)
  END;
  target[0] := 0X;
  RETURN FALSE
END BitSynonymOf;

PROCEDURE AddBitSynonym*(alias, target: ARRAY OF CHAR): BOOLEAN;
VAR chase, t: ARRAY 64 OF CHAR;
BEGIN
  (* aliasing an alias collapses to the original, as AddBitSynonym does.
     NOTE: the resolved name goes in a LOCAL, not back into the `target`
     parameter - an open ARRAY OF CHAR value parameter is a pointer in the
     generated C, so writing to it would change the caller's string. *)
  Strings.Copy(target, t);
  IF BitSynonymOf(t, chase) THEN Strings.Copy(chase, t) END;
  IF BitSynonymOf(alias, chase) THEN RETURN TRUE END;   (* already known *)
  IF nBitSynonyms >= MaxBitSynonyms THEN RETURN FALSE END;
  Strings.Copy(alias, bitSynAlias[nBitSynonyms]);
  Strings.Copy(t, bitSynTarget[nBitSynonyms]);
  INC(nBitSynonyms);
  RETURN TRUE
END AddBitSynonym;

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
VAR i, firstBits: INTEGER; clearFirst: BOOLEAN;
BEGIN
  clearFirst := FALSE;
  i := FindVocab(text);
  IF i < 0 THEN
    IF nVocab >= MaxVocab THEN RETURN -1 END;
    i := nVocab; INC(nVocab);
    Strings.Copy(text, vocab[i].text);
    vocab[i].pos := 0;
    vocab[i].verbVal := 0; vocab[i].prepVal := 0; vocab[i].adjVal := 0;
    vocab[i].dirVal := 0; vocab[i].buzzVal := 0; vocab[i].dirAlias[0] := 0X;
    vocab[i].mergedInto := -1
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
      vocab[i].prepVal := nextPrep; DEC(nextPrep);
      (* a preposition's value is ALWAYS emitted first (EmitVocabTable's own
         priority order matches the original's WriteToBuilder exactly:
         Preposition wins over Verb/Adjective/Direction/Object regardless of
         which was registered first), so the original's SetPreposition
         unconditionally clears whatever First flag an earlier registration
         set, and so must this one. Skipping this left "INVENTORY" — a word
         that is BOTH a verb and a preposition in advent's grammar —
         flagged VerbFirst from its earlier <SYNTAX INVENTORY = V-INVENTORY>
         registration, so CHKWORD?'s "is this a verb?" query read the
         PREPOSITION's value out of V1 instead of the verb's own value out
         of V2, and "inventory" the command silently failed to parse as a
         verb at all. *)
      clearFirst := TRUE
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
      vocab[i].buzzVal := nextBuzz; DEC(nextBuzz);
      (* buzzword value comes before everything but preposition - same
         unconditional clear as preposition, for the same reason *)
      clearFirst := TRUE
    END
  END;

  (* the parts of speech are a bit set, so adding one is a union; the
     part-of-speech field is a single byte, hence bits 0..7. The First bits
     are not part of that union - they are a two-bit field, so they replace
     rather than accumulate, and only the first value-recording part of
     speech ever sets them. *)
  vocab[i].pos := BitOr(vocab[i].pos, posBits);
  IF clearFirst THEN
    vocab[i].pos := vocab[i].pos - (vocab[i].pos MOD 4)
  ELSIF firstBits # 0 THEN
    vocab[i].pos := vocab[i].pos - (vocab[i].pos MOD 4) + firstBits
  END;
  RETURN i
END AddVocab;

PROCEDURE Reset*;
BEGIN
  zversion := 3; timeStatusLine := FALSE;
  nRoutines := 0; nObjects := 0; nGlobals := 0; nConstants := 0; nTables := 0;
  nSyntaxes := 0; nSynonyms := 0; nDirections := 0; nBuzzwords := 0;
  nBitSynonyms := 0;
  nPropDefaults := 0; nPropDefSpecs := 0; nTellPatterns := 0;
  nVocab := 0;
  nextVerb := 255; nextPrep := 255; nextAdj := 255; nextBuzz := 255
END Reset;

BEGIN
  Reset
END ZilModel.
