MODULE ZilObj;
(*
  ZilObj — core ZIL/MDL value types, ported from Zilf.Interpreter.Values (C#).

  This is phase 1 of a larger, multi-session port of zilf (the ZIL compiler)
  to Oberon; see Notes/zilf_port_plan.md for the overall plan, what's ported
  so far, and what's next.

  ZIL is a Lisp-like language (MDL dialect): every value is a "ZilObject".
  As with the zapf port, this uses one tagged record (ZObj) rather than a
  class hierarchy, since Oberon has no generic collections or inheritance-
  based dynamic dispatch beyond record extension + WITH (which would be
  far more verbose here for little benefit — the original hierarchy exists
  mainly to override a handful of virtual methods per type, which a CASE on
  `kind` does just as well).

  Types implemented (the "pragmatic subset" — see plan doc for what's
  deferred): ATOM, FIX, STRING, CHARACTER, FORM (<...>), LIST (...),
  VECTOR [...], ADECL (X:TYPE), SEGMENT (!<...> / !.X), FALSE.

  Deferred to a later phase (not yet needed by the reader):
  full EVAL/EXPAND semantics (needs the Interpreter/environment system),
  the OBLIST package hierarchy (this port uses one flat global table — see
  Oblist* below), ZilString's OffsetString sharing view (REST just copies),
  ZilVector's Grow/BaseOffset view tricks (Grow reallocates in place),
  PRINTTYPE/EVALTYPE customization hooks, circular-structure-safe printing.
*)

IMPORT Strings, Out;

CONST
  (* value kinds *)
  KAtom*    = 0;
  KFix*     = 1;
  KString*  = 2;
  KChar*    = 3;
  KForm*    = 4;
  KList*    = 5;
  KVector*  = 6;
  KAdecl*   = 7;
  KSegment* = 8;
  KFalse*   = 9;
  KSubr*    = 10;    (* native procedure, evaluated args *)
  KFSubr*   = 11;    (* native procedure, unevaluated args *)
  KActivation* = 12; (* PROG/REPEAT/BIND activation identity — see ZilEval.mod *)
  KFunction*   = 13; (* DEFINE/DEFINE20-defined interpreter function *)
  KMacro*      = 14; (* DEFMAC-defined macro: wraps an applicable value *)
  KTable*      = 15; (* TABLE/LTABLE/PTABLE/PLTABLE/ITABLE value *)
  KOblist*     = 16; (* an OBLIST, used as a compile-time hash map — see
                        ZilEval's MOBLIST/LOOKUP/INSERT for why one is
                        needed even though name RESOLUTION uses a single
                        flat table. Carries only its name, in atomText. *)

  (* KTable tabFlags bits — see NewTable's own comment *)
  TfByte*   = 1;
  TfLength* = 2;
  TfPure*   = 4;
  TfLexv*   = 8;
  TfTemp*   = 16;

  OblistBuckets = 2048;

TYPE
  Zo* = POINTER TO ZoDesc;

  (* A PUTPROP/GETPROP association list entry. Any Zo can carry properties
     (matches the original's generic two-key AssociationTable), but rather
     than a separate global table keyed by object identity, each value's
     property list hangs directly off that value's own record — simpler,
     and just as correct since Oberon pointers already give us identity. *)
  AssocNode* = POINTER TO AssocNodeDesc;
  AssocNodeDesc* = RECORD
    indicator*: Zo;
    value*: Zo;
    next*: AssocNode
  END;

  ZoDesc* = RECORD
    kind*: INTEGER;

    (* ATOM *)
    atomText*: ARRAY 64 OF CHAR;     (* also used to hold the name for KSubr/KFSubr *)
    atomNext: Zo;               (* oblist hash-bucket chain *)
    globalVal*: Zo;             (* GVAL; NIL = unassigned *)
    localVal*: Zo;              (* LVAL, shallow-bound — see ZilEval.mod's BindLocal/UnbindLocal *)

    (* FIX *)
    fixVal*: INTEGER;

    (* CHARACTER (ZSCII/char code, ZIL chars are byte-valued) *)
    charVal*: INTEGER;

    (* STRING: heap-allocated buffer, strLen chars, NUL-terminated for
       convenience with Strings.* calls when strLen < LEN(strBuf^)-1 *)
    strBuf*: POINTER TO ARRAY OF CHAR;
    strLen*: INTEGER;

    (* FORM / LIST / FALSE: singly-linked cons cell. Empty <=> first=NIL *)
    first*: Zo;
    rest*: Zo;                  (* another Zo of the SAME kind, or NIL *)

    (* VECTOR *)
    vecItems*: POINTER TO ARRAY OF Zo;
    vecLen*: INTEGER;

    (* ADECL: value:type *)
    adFirst*, adSecond*: Zo;

    (* SEGMENT: wraps a FORM *)
    segForm*: Zo;

    (* property list (PUTPROP/GETPROP), any kind *)
    assoc*: AssocNode;

    (* FUNCTION (DEFINE/DEFINE20): the arg-spec list is kept raw/unparsed
       and walked afresh on every call rather than pre-compiled into a
       separate structure — simpler, and call frequency at this level
       (macro expansion, small interpreter-only helpers) makes the
       re-walk cost irrelevant. See ZilEval.mod's function/macro apply
       logic (inlined in Eval, same forward-reference reason as PROG). *)
    funcArgSpec*: Zo;   (* raw LIST, e.g. (X "OPT" (Y 5) "AUX" Z) *)
    funcAct*: Zo;       (* optional leading activation atom, or NIL *)
    funcBody*: Zo;      (* LIST of body forms *)

    (* MACRO (DEFMAC): wraps an applicable value (a FUNCTION) *)
    macWrapped*: Zo;

    (* TABLE/LTABLE/PTABLE/PLTABLE/ITABLE: the (non-repeated) initializer
       values, reusing the VECTOR fields above (same flat-array shape,
       no need for a separate pair of fields) — vecItems/vecLen hold the
       values as given; tabRepCount is ITABLE's repetition count (1 for
       the plain [P][L]TABLE forms, which don't repeat); tabFlags is a
       bitmask of the TfXXX constants above. This is a much thinner
       representation than the original's ZilTable (no byte-level
       encoding yet — that's phase 3b's job once a real compilation pass
       exists to walk ZilModel's registered tables). *)
    tabRepCount*: INTEGER;
    tabFlags*: INTEGER
  END;

VAR
  oblist: ARRAY OblistBuckets OF Zo;

(* ------------------------------------------------------------------ *)
(* atoms (single flat OBLIST — see plan doc for the package hierarchy   *)
(* this simplifies away)                                                *)
(* ------------------------------------------------------------------ *)

PROCEDURE HashText(t: ARRAY OF CHAR): INTEGER;
VAR h, i: INTEGER;
BEGIN
  h := 0; i := 0;
  WHILE t[i] # 0X DO h := (h * 31 + ORD(t[i])) MOD OblistBuckets; INC(i) END;
  IF h < 0 THEN h := -h END;
  RETURN h
END HashText;

(* Interns an atom by name: returns the existing atom if one with this
   exact text already exists, else creates and registers a new one.
   Atom identity (pointer equality) is what ZIL's ==? / EQ? relies on. *)
PROCEDURE Intern*(text: ARRAY OF CHAR): Zo;
VAR z: Zo; b: INTEGER;
BEGIN
  b := HashText(text);
  z := oblist[b];
  WHILE (z # NIL) & (z.atomText # text) DO z := z.atomNext END;
  IF z = NIL THEN
    NEW(z);
    z.kind := KAtom;
    Strings.Copy(text, z.atomText);
    z.atomNext := oblist[b];
    oblist[b] := z
  END;
  RETURN z
END Intern;

(* ------------------------------------------------------------------ *)
(* constructors                                                         *)
(* ------------------------------------------------------------------ *)

PROCEDURE NewFix*(v: INTEGER): Zo;
VAR z: Zo;
BEGIN NEW(z); z.kind := KFix; z.fixVal := v; RETURN z END NewFix;

PROCEDURE NewChar*(v: INTEGER): Zo;
VAR z: Zo;
BEGIN NEW(z); z.kind := KChar; z.charVal := v; RETURN z END NewChar;

PROCEDURE NewStringN*(text: ARRAY OF CHAR; n: INTEGER): Zo;
VAR z: Zo; i: INTEGER;
BEGIN
  NEW(z);
  z.kind := KString;
  NEW(z.strBuf, n + 1);
  FOR i := 0 TO n - 1 DO z.strBuf[i] := text[i] END;
  z.strBuf[n] := 0X;
  z.strLen := n;
  RETURN z
END NewStringN;

PROCEDURE NewString*(text: ARRAY OF CHAR): Zo;
BEGIN RETURN NewStringN(text, Strings.Length(text)) END NewString;

(* Builds an empty cons-family value of the given kind (List/Form/False). *)
PROCEDURE NewEmpty*(kind: INTEGER): Zo;
VAR z: Zo;
BEGIN NEW(z); z.kind := kind; z.first := NIL; z.rest := NIL; RETURN z END NewEmpty;

(* Prepends `head` onto `tail` (tail must be NIL or the same kind);
   builds one cons cell of `kind`. *)
PROCEDURE Cons*(kind: INTEGER; head, tail: Zo): Zo;
VAR z: Zo;
BEGIN
  NEW(z);
  z.kind := kind;
  z.first := head;
  IF tail = NIL THEN z.rest := NewEmpty(kind) ELSE z.rest := tail END;
  RETURN z
END Cons;

PROCEDURE NewVectorN*(n: INTEGER): Zo;
VAR z: Zo;
BEGIN
  NEW(z);
  z.kind := KVector;
  NEW(z.vecItems, n);
  z.vecLen := n;
  RETURN z
END NewVectorN;

PROCEDURE NewAdecl*(first, second: Zo): Zo;
VAR z: Zo;
BEGIN NEW(z); z.kind := KAdecl; z.adFirst := first; z.adSecond := second; RETURN z END NewAdecl;

(* form must be a KForm value *)
PROCEDURE NewSegment*(form: Zo): Zo;
VAR z: Zo;
BEGIN NEW(z); z.kind := KSegment; z.segForm := form; RETURN z END NewSegment;

PROCEDURE NewSubr*(name: ARRAY OF CHAR; isF: BOOLEAN): Zo;
VAR z: Zo;
BEGIN
  NEW(z);
  IF isF THEN z.kind := KFSubr ELSE z.kind := KSubr END;
  Strings.Copy(name, z.atomText);
  RETURN z
END NewSubr;

(* A PROG/REPEAT/BIND activation. Identity is just the pointer itself
   (matches the original's C# reference-equality use of ZilActivation);
   `name` is only for display and for the optional named-activation-atom
   binding (see ZilEval.mod). *)
PROCEDURE NewActivation*(name: ARRAY OF CHAR): Zo;
VAR z: Zo;
BEGIN
  NEW(z);
  z.kind := KActivation;
  Strings.Copy(name, z.atomText);
  RETURN z
END NewActivation;

PROCEDURE NewFunction*(argSpec, act, body: Zo): Zo;
VAR z: Zo;
BEGIN
  NEW(z);
  z.kind := KFunction;
  z.funcArgSpec := argSpec; z.funcAct := act; z.funcBody := body;
  RETURN z
END NewFunction;

PROCEDURE NewMacro*(wrapped: Zo): Zo;
VAR z: Zo;
BEGIN NEW(z); z.kind := KMacro; z.macWrapped := wrapped; RETURN z END NewMacro;

(* values[0..n-1] become the table's (non-repeated) initializer;
   repCount > 1 is ITABLE's repetition count. *)
PROCEDURE NewTable*(values: ARRAY OF Zo; n, repCount, flags: INTEGER): Zo;
VAR z: Zo; i: INTEGER;
BEGIN
  NEW(z);
  z.kind := KTable;
  NEW(z.vecItems, n);
  FOR i := 0 TO n - 1 DO z.vecItems[i] := values[i] END;
  z.vecLen := n;
  z.tabRepCount := repCount;
  z.tabFlags := flags;
  RETURN z
END NewTable;

(* ------------------------------------------------------------------ *)
(* property lists (PUTPROP/GETPROP)                                     *)
(* ------------------------------------------------------------------ *)

(* Indicator-matching for property lists: atoms (the overwhelmingly common
   case) compare by identity (already correct thanks to interning); FIX
   compares by value; anything else falls back to identity. *)
PROCEDURE SameAtomOrEq(a, b: Zo): BOOLEAN;
BEGIN
  IF a = b THEN RETURN TRUE END;
  IF (a = NIL) OR (b = NIL) THEN RETURN FALSE END;
  IF (a.kind = KFix) & (b.kind = KFix) THEN RETURN a.fixVal = b.fixVal END;
  RETURN FALSE
END SameAtomOrEq;

(* NIL value removes the association, matching <PUTPROP obj ind> (no value). *)
PROCEDURE PutProp*(obj, indicator, value: Zo);
VAR n, prev: AssocNode;
BEGIN
  n := obj.assoc; prev := NIL;
  WHILE (n # NIL) & ~SameAtomOrEq(n.indicator, indicator) DO prev := n; n := n.next END;
  IF value = NIL THEN
    IF n # NIL THEN
      IF prev = NIL THEN obj.assoc := n.next ELSE prev.next := n.next END
    END
  ELSIF n # NIL THEN
    n.value := value
  ELSE
    NEW(n); n.indicator := indicator; n.value := value; n.next := obj.assoc; obj.assoc := n
  END
END PutProp;

PROCEDURE GetProp*(obj, indicator: Zo): Zo;
VAR n: AssocNode;
BEGIN
  n := obj.assoc;
  WHILE (n # NIL) & ~SameAtomOrEq(n.indicator, indicator) DO n := n.next END;
  IF n # NIL THEN RETURN n.value ELSE RETURN NIL END
END GetProp;

(* ------------------------------------------------------------------ *)
(* accessors / predicates                                               *)
(* ------------------------------------------------------------------ *)

PROCEDURE IsConsFamily(kind: INTEGER): BOOLEAN;
BEGIN RETURN (kind = KForm) OR (kind = KList) OR (kind = KFalse) END IsConsFamily;

PROCEDURE IsEmpty*(z: Zo): BOOLEAN;
BEGIN RETURN IsConsFamily(z.kind) & (z.first = NIL) END IsEmpty;

(* Length of a cons-family list (Form/List/False); -1 if not applicable. *)
PROCEDURE ListLength*(z: Zo): INTEGER;
VAR n: INTEGER; p: Zo;
BEGIN
  IF ~IsConsFamily(z.kind) THEN RETURN -1 END;
  n := 0; p := z;
  WHILE (p # NIL) & (p.first # NIL) DO INC(n); p := p.rest END;
  RETURN n
END ListLength;

(* Element at zero-based index of a cons-family list, or NIL. *)
PROCEDURE ListNth*(z: Zo; idx: INTEGER): Zo;
VAR p: Zo;
BEGIN
  p := z;
  WHILE (idx > 0) & (p # NIL) & (p.first # NIL) DO p := p.rest; DEC(idx) END;
  IF (p # NIL) & (p.first # NIL) & (idx = 0) THEN RETURN p.first ELSE RETURN NIL END
END ListNth;

(* True iff two atoms are the same interned atom (EQ / ==? for atoms). *)
PROCEDURE SameAtom*(a, b: Zo): BOOLEAN;
BEGIN RETURN a = b END SameAtom;

PROCEDURE IsAtomNamed*(z: Zo; name: ARRAY OF CHAR): BOOLEAN;
BEGIN RETURN (z # NIL) & (z.kind = KAtom) & (z.atomText = name) END IsAtomNamed;

(* ------------------------------------------------------------------ *)
(* printing (reparsable form, like ZilObject.ToString in the original;  *)
(* no PRINTTYPE/context-sensitive friendly mode yet — that needs Context) *)
(* ------------------------------------------------------------------ *)

PROCEDURE AppendInt(v: INTEGER; VAR s: ARRAY OF CHAR);
VAR buf: ARRAY 16 OF CHAR;
BEGIN Strings.IntToStr(v, buf); Strings.Append(buf, s) END AppendInt;

PROCEDURE AppendChar(c: CHAR; VAR s: ARRAY OF CHAR);
VAR n: INTEGER;
BEGIN n := Strings.Length(s); s[n] := c; s[n + 1] := 0X END AppendChar;

(* Recursive; self-recursion only (no mutual recursion, since this
   transpiler has no FORWARD declarations) — the cons-body loop is inlined
   at each of its three call sites below rather than factored into a
   separate mutually-recursive helper. *)
PROCEDURE PrintTo*(z: Zo; VAR s: ARRAY OF CHAR);
VAR tmp: ARRAY 4096 OF CHAR; i: INTEGER; p: Zo; first: BOOLEAN;
BEGIN
  IF z = NIL THEN Strings.Copy("<...>", s); RETURN END;
  CASE z.kind OF
    KAtom: Strings.Copy(z.atomText, s)
   |KFix: s[0] := 0X; AppendInt(z.fixVal, s)
   |KChar:
      Strings.Copy("!\", s); AppendChar(CHR(z.charVal), s)
   |KString:
      s[0] := 0X; Strings.Append('"', s);
      FOR i := 0 TO z.strLen - 1 DO
        IF (z.strBuf[i] = '"') OR (z.strBuf[i] = "\") THEN Strings.Append("\", s) END;
        AppendChar(z.strBuf[i], s)
      END;
      Strings.Append('"', s)
   |KForm:
      IF IsEmpty(z) THEN
        Strings.Copy("<>", s)
      ELSIF IsAtomNamed(z.first, "GVAL") & (ListLength(z) = 2) THEN
        Strings.Copy(",", s); PrintTo(z.rest.first, tmp); Strings.Append(tmp, s)
      ELSIF IsAtomNamed(z.first, "LVAL") & (ListLength(z) = 2) THEN
        Strings.Copy(".", s); PrintTo(z.rest.first, tmp); Strings.Append(tmp, s)
      ELSIF IsAtomNamed(z.first, "QUOTE") & (ListLength(z) = 2) THEN
        Strings.Copy("'", s); PrintTo(z.rest.first, tmp); Strings.Append(tmp, s)
      ELSE
        Strings.Copy("<", s);
        p := z; first := TRUE;
        WHILE (p # NIL) & (p.first # NIL) DO
          IF ~first THEN Strings.Append(" ", s) END;
          first := FALSE;
          PrintTo(p.first, tmp); Strings.Append(tmp, s);
          p := p.rest
        END;
        Strings.Append(">", s)
      END
   |KList:
      Strings.Copy("(", s);
      p := z; first := TRUE;
      WHILE (p # NIL) & (p.first # NIL) DO
        IF ~first THEN Strings.Append(" ", s) END;
        first := FALSE;
        PrintTo(p.first, tmp); Strings.Append(tmp, s);
        p := p.rest
      END;
      Strings.Append(")", s)
   |KFalse:
      Strings.Copy("#FALSE (", s);
      p := z; first := TRUE;
      WHILE (p # NIL) & (p.first # NIL) DO
        IF ~first THEN Strings.Append(" ", s) END;
        first := FALSE;
        PrintTo(p.first, tmp); Strings.Append(tmp, s);
        p := p.rest
      END;
      Strings.Append(")", s)
   |KVector:
      Strings.Copy("[", s);
      FOR i := 0 TO z.vecLen - 1 DO
        IF i > 0 THEN Strings.Append(" ", s) END;
        PrintTo(z.vecItems[i], tmp); Strings.Append(tmp, s)
      END;
      Strings.Append("]", s)
   |KAdecl:
      PrintTo(z.adFirst, s); Strings.Append(":", s);
      PrintTo(z.adSecond, tmp); Strings.Append(tmp, s)
   |KSegment:
      Strings.Copy("!", s); PrintTo(z.segForm, tmp); Strings.Append(tmp, s)
   |KSubr:
      Strings.Copy("#SUBR (", s); Strings.Append(z.atomText, s); Strings.Append(")", s)
   |KFSubr:
      Strings.Copy("#FSUBR (", s); Strings.Append(z.atomText, s); Strings.Append(")", s)
   |KActivation:
      Strings.Copy("#ACTIVATION ", s); Strings.Append(z.atomText, s)
   |KFunction:
      Strings.Copy("#FUNCTION (...)", s)
   |KMacro:
      Strings.Copy("#MACRO (...)", s)
   |KTable:
      Strings.Copy("#TABLE (", s);
      FOR i := 0 TO z.vecLen - 1 DO
        IF i > 0 THEN Strings.Append(" ", s) END;
        PrintTo(z.vecItems[i], tmp); Strings.Append(tmp, s)
      END;
      Strings.Append(")", s)
  ELSE
    Strings.Copy("#UNKNOWN", s)
  END
END PrintTo;

PROCEDURE Print*(z: Zo);
VAR s: ARRAY 4096 OF CHAR;
BEGIN PrintTo(z, s); Out.String(s) END Print;

END ZilObj.
