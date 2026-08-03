MODULE Student;
(*
 * STUDENT -- an algebra word-problem solver, after Daniel Bobrow's 1964
 * MIT thesis program of the same name.
 *
 * This version extends the small STUDENT with a number of features
 * closer in spirit to the 1964 original:
 *
 *   * Surface-string rewrites run before parsing:
 *       - "two times"        -> "twice"
 *       - "three times"      -> "thrice"
 *       - "per cent"         -> "percent"
 *       - "one half of"      -> "0.5 times"
 *       - "one third of"     -> a decimal times
 *       - "two thirds of", "three quarters of", "one quarter of", ...
 *       - "Mary's" (possessive) -> "mary"
 *       - trailing plurals stripped where safe ("ducks" ~ "duck")
 *
 *   * Comparative idioms:
 *       - "N more than X"     -> "X plus N"
 *       - "N less than X"     -> "X minus N"
 *       - "N times as many/much/... as X" -> "N times X"
 *       - "as many/much/old/... A as B"   -> "A is B"
 *
 *   * Simple age idiom:
 *       - "in N years"        -> "plus N"    (attached to the age phrase)
 *       - "N years ago"       -> "minus N"
 *     (Handled at the token level: "Mary's age in 5 years" becomes
 *      "( mary age plus 5 )".)
 *
 *   * Generic numeric unknowns: "the first number", "the second number",
 *     "the third number", "a number" all become named quantities.
 *
 *   * Rate/distance idiom generalised: "X travels N mph for M hours"
 *     produces  X_distance = N*M.  Multiple travellers are supported.
 *
 *   * Question handling:
 *       - "find ...", "what is/was/are the ... [of ...]",
 *         "how many/much/far/old ..."
 *       - "How old is Mary?"  asks for "mary age".
 *       - If the question names a quantity not seen in the facts but
 *         the facts have exactly one unnamed unknown, that is solved for.
 *
 *   * The derived equations are printed before the answer, in the style
 *     of the original STUDENT.
 *
 * Limitations still shared with (or new to) this version:
 *   - No general pronoun resolution.  Bobrow's hardest age puzzles
 *     ("Mary is twice as old as Ann was when Mary was as old as Ann is
 *     now") need discourse tracking that is well outside a small model.
 *   - Only linear systems: unknown*unknown is flagged, not solved.
 *   - The problem must be exactly determined.
 *)

IMPORT Out, Strings, History;

CONST
  MAXTOK   = 400;
  TOKLEN   = 32;
  MAXVARS  = 16;
  MAXEQS   = 16;
  AUGCOLS  = 17;   (* must be MAXVARS + 1 *)
  NAMELEN  = 256;

TYPE
  LinExpr = RECORD
    coef  : ARRAY MAXVARS OF REAL;
    cst   : REAL
  END;

VAR
  tok      : ARRAY MAXTOK OF ARRAY TOKLEN OF CHAR;
  ntok     : INTEGER;

  varName  : ARRAY MAXVARS OF ARRAY NAMELEN OF CHAR;
  nvars    : INTEGER;

  eqCoef   : ARRAY MAXEQS OF ARRAY MAXVARS OF REAL;
  eqConst  : ARRAY MAXEQS OF REAL;
  neq      : INTEGER;

  (* remembers which unknowns are named in the facts (used by
     the question-resolution fallback) *)
  usedInFacts : ARRAY MAXVARS OF BOOLEAN;

(* ---------------------------------------------------------------- *)
(* word classes                                                     *)
(* ---------------------------------------------------------------- *)

PROCEDURE IsFiller(w : ARRAY OF CHAR) : BOOLEAN;
BEGIN
  RETURN (Strings.Compare(w,"the")=0)    OR (Strings.Compare(w,"a")=0)
      OR (Strings.Compare(w,"an")=0)     OR (Strings.Compare(w,"of")=0)
      OR (Strings.Compare(w,"number")=0) OR (Strings.Compare(w,"amount")=0)
      OR (Strings.Compare(w,"value")=0)  OR (Strings.Compare(w,"is")=0)
      OR (Strings.Compare(w,"are")=0)    OR (Strings.Compare(w,"was")=0)
      OR (Strings.Compare(w,"were")=0)   OR (Strings.Compare(w,"there")=0)
      OR (Strings.Compare(w,"does")=0)   OR (Strings.Compare(w,"did")=0)
      OR (Strings.Compare(w,"do")=0)
      OR (Strings.Compare(w,"has")=0)    OR (Strings.Compare(w,"have")=0)
      OR (Strings.Compare(w,"had")=0)
      OR (Strings.Compare(w,"go")=0)     OR (Strings.Compare(w,"it")=0)
      OR (Strings.Compare(w,"he")=0)     OR (Strings.Compare(w,"she")=0)
      OR (Strings.Compare(w,"they")=0)   OR (Strings.Compare(w,"that")=0)
      OR (Strings.Compare(w,"between")=0)
END IsFiller;

PROCEDURE IsStopOp(w : ARRAY OF CHAR) : BOOLEAN;
BEGIN
  RETURN (Strings.Compare(w,"plus")=0)       OR (Strings.Compare(w,"minus")=0)
      OR (Strings.Compare(w,"times")=0)      OR (Strings.Compare(w,"multiplied")=0)
      OR (Strings.Compare(w,"divided")=0)    OR (Strings.Compare(w,"by")=0)
      OR (Strings.Compare(w,"percent")=0)    OR (Strings.Compare(w,"twice")=0)
      OR (Strings.Compare(w,"half")=0)       OR (Strings.Compare(w,"thrice")=0)
      OR (Strings.Compare(w,"double")=0)     OR (Strings.Compare(w,"triple")=0)
      OR (Strings.Compare(w,"and")=0)        OR (Strings.Compare(w,"sum")=0)
      OR (Strings.Compare(w,"difference")=0) OR (Strings.Compare(w,"product")=0)
      OR (Strings.Compare(w,"quotient")=0)
      OR (Strings.Compare(w,"(")=0) OR (Strings.Compare(w,")")=0)
      OR (Strings.Compare(w,"if")=0)
      OR (Strings.Compare(w,",")=0) OR (Strings.Compare(w,".")=0) OR (Strings.Compare(w,"?")=0)
END IsStopOp;

(* ---------------------------------------------------------------- *)
(* string helpers                                                   *)
(* ---------------------------------------------------------------- *)

PROCEDURE EndsWith(s, suf : ARRAY OF CHAR) : BOOLEAN;
VAR ls, lu, i : INTEGER;
BEGIN
  ls := Strings.Length(s); lu := Strings.Length(suf);
  IF lu > ls THEN RETURN FALSE END;
  FOR i := 0 TO lu - 1 DO
    IF s[ls - lu + i] # suf[i] THEN RETURN FALSE END
  END;
  RETURN TRUE
END EndsWith;

(* Strip a common English plural "s" where it is safe.  This is a
   heuristic: it lets "ducks" and "duck" name the same quantity, but
   avoids mangling "glass", "bus", "analysis", etc. *)
PROCEDURE Singularize(VAR s : ARRAY OF CHAR);
VAR n : INTEGER;
BEGIN
  n := Strings.Length(s);
  IF n < 4 THEN RETURN END;
  IF s[n-1] # 's' THEN RETURN END;
  IF s[n-2] = 's' THEN RETURN END;                   (* -ss *)
  IF (s[n-2] = 'u') & (s[n-3] = 'u') THEN RETURN END; (* rare *)
  IF (s[n-2] = 'u') & (s[n-3] = 'i') THEN RETURN END; (* -ius *)
  IF (s[n-2] = 'i') & (s[n-3] = 's') THEN RETURN END; (* -sis *)
  IF (s[n-2] = 'e') & (s[n-3] = 'i') THEN             (* -ies -> -y *)
    s[n-3] := 'y'; s[n-2] := 0X; RETURN
  END;
  s[n-1] := 0X
END Singularize;

(* ---------------------------------------------------------------- *)
(* lexer: lowercase, split off punctuation, drop possessives,       *)
(* split "%" -> " percent "                                         *)
(* ---------------------------------------------------------------- *)

PROCEDURE Lex(problem : ARRAY OF CHAR);
VAR
  i, j, n : INTEGER;
  c       : CHAR;
  outp    : ARRAY 2048 OF CHAR;
  pos     : INTEGER;
  word    : ARRAY TOKLEN OF CHAR;
  wl      : INTEGER;
BEGIN
  n := Strings.Length(problem);
  i := 0; j := 0;
  WHILE (i < n) & (j < 2040) DO
    c := problem[i];
    IF (c >= 'A') & (c <= 'Z') THEN c := CHR(ORD(c) + 32) END;
    IF (c = ',') OR (c = '.') OR (c = '?') OR (c = '!') OR (c = '(') OR (c = ')') THEN
      outp[j] := ' '; INC(j); outp[j] := c; INC(j); outp[j] := ' '; INC(j)
    ELSIF c = '%' THEN
      outp[j] := ' '; INC(j);
      outp[j] := 'p'; INC(j); outp[j] := 'e'; INC(j); outp[j] := 'r'; INC(j);
      outp[j] := 'c'; INC(j); outp[j] := 'e'; INC(j); outp[j] := 'n'; INC(j); outp[j] := 't'; INC(j);
      outp[j] := ' '; INC(j)
    ELSIF (c = 39X) OR (c = 27X) THEN
      (* apostrophe: eat it and the following 's' if present, turning
         "mary's" into "mary" and "students'" into "students" *)
      IF (i + 1 < n) & ((problem[i+1] = 's') OR (problem[i+1] = 'S')) THEN INC(i) END
    ELSE
      outp[j] := c; INC(j)
    END;
    INC(i)
  END;
  outp[j] := 0X;

  ntok := 0;
  pos := 0;
  Strings.NextWord(outp, pos, word);
  WHILE word[0] # 0X DO
    IF ntok < MAXTOK THEN
      wl := Strings.Length(word);
      (* don't strip plurals on function words / punctuation *)
      IF (wl >= 4) & ~IsStopOp(word) & ~IsFiller(word) THEN
        Singularize(word)
      END;
      COPY(word, tok[ntok]); INC(ntok)
    END;
    Strings.NextWord(outp, pos, word)
  END
END Lex;

PROCEDURE RemoveRange(from, upto : INTEGER);
VAR k : INTEGER;
BEGIN
  k := from;
  WHILE upto < ntok DO
    COPY(tok[upto], tok[k]);
    INC(k); INC(upto)
  END;
  ntok := k
END RemoveRange;

PROCEDURE InsertToken(at : INTEGER; word : ARRAY OF CHAR);
VAR k : INTEGER;
BEGIN
  IF ntok >= MAXTOK THEN RETURN END;
  k := ntok;
  WHILE k > at DO
    COPY(tok[k-1], tok[k]);
    DEC(k)
  END;
  COPY(word, tok[at]);
  INC(ntok)
END InsertToken;

PROCEDURE ReplaceToken(at : INTEGER; word : ARRAY OF CHAR);
BEGIN
  IF (at >= 0) & (at < ntok) THEN COPY(word, tok[at]) END
END ReplaceToken;

PROCEDURE Match2(i : INTEGER; a, b : ARRAY OF CHAR) : BOOLEAN;
BEGIN
  RETURN (i + 1 < ntok) & (Strings.Compare(tok[i], a) = 0) & (Strings.Compare(tok[i+1], b) = 0)
END Match2;

PROCEDURE Match3(i : INTEGER; a, b, c : ARRAY OF CHAR) : BOOLEAN;
BEGIN
  RETURN (i + 2 < ntok) & (Strings.Compare(tok[i], a) = 0)
       & (Strings.Compare(tok[i+1], b) = 0) & (Strings.Compare(tok[i+2], c) = 0)
END Match3;

(* ---------------------------------------------------------------- *)
(* pre-parse token rewrites                                         *)
(* ---------------------------------------------------------------- *)

(* rewrite one two-word phrase to a single word, throughout the tokens *)
PROCEDURE Collapse2(a, b, into : ARRAY OF CHAR);
VAR i : INTEGER;
BEGIN
  i := 0;
  WHILE i + 1 < ntok DO
    IF Match2(i, a, b) THEN
      ReplaceToken(i, into);
      RemoveRange(i+1, i+2)
    ELSE
      INC(i)
    END
  END
END Collapse2;

(* rewrite one two-word phrase to two given words (e.g. "0.5 times") *)
PROCEDURE Rewrite2To2(a, b, x, y : ARRAY OF CHAR);
VAR i : INTEGER;
BEGIN
  i := 0;
  WHILE i + 1 < ntok DO
    IF Match2(i, a, b) THEN
      ReplaceToken(i, x);
      ReplaceToken(i+1, y);
      INC(i, 2)
    ELSE
      INC(i)
    END
  END
END Rewrite2To2;

(* rewrite one three-word phrase to two words *)
PROCEDURE Rewrite3To2(a, b, c, x, y : ARRAY OF CHAR);
VAR i : INTEGER;
BEGIN
  i := 0;
  WHILE i + 2 < ntok DO
    IF Match3(i, a, b, c) THEN
      ReplaceToken(i, x);
      ReplaceToken(i+1, y);
      RemoveRange(i+2, i+3);
      INC(i, 2)
    ELSE
      INC(i)
    END
  END
END Rewrite3To2;

(* Comparative "more/less/fewer than" idioms.  Two shapes:
   (1) "<N> more <NOUN1...> than <NOUN2...>"   whole-clause shape
       -> "<NOUN1> is <NOUN2> plus <N>"        (or minus for less/fewer)
   (2) "<N> more/less than <X>"                 in-expression shape
       -> "<X> plus/minus <N>"
   We try shape (1) first; if it doesn't match, we fall through to (2). *)
PROCEDURE RewriteMoreLessThan;
VAR
  i, j, k, thanPos, saveI, endPhrase, n1Start, n1End : INTEGER;
  n     : REAL;
  op    : ARRAY 8 OF CHAR;
  phrase: ARRAY 16 OF ARRAY TOKLEN OF CHAR;
  plen  : INTEGER;
  noun1 : ARRAY 8 OF ARRAY TOKLEN OF CHAR;
  n1len : INTEGER;
  numTok: ARRAY TOKLEN OF CHAR;
  matched1 : BOOLEAN;
BEGIN
  i := 0;
  WHILE i < ntok DO
    IF Strings.StrToReal(tok[i], n)
       & (i + 2 < ntok)
       & ((Strings.Compare(tok[i+1], "more") = 0) OR (Strings.Compare(tok[i+1], "less") = 0)
          OR (Strings.Compare(tok[i+1], "fewer") = 0)) THEN

      IF Strings.Compare(tok[i+1], "more") = 0 THEN COPY("plus", op) ELSE COPY("minus", op) END;
      COPY(tok[i], numTok);

      (* Look for "than" -- either immediately (shape 2) or after a NOUN1 (shape 1). *)
      matched1 := FALSE;
      IF Strings.Compare(tok[i+2], "than") # 0 THEN
        (* shape (1) attempt: collect NOUN1 tokens up to "than" *)
        n1Start := i + 2;
        n1End := n1Start;
        WHILE (n1End < ntok) & (Strings.Compare(tok[n1End], "than") # 0) & ~IsStopOp(tok[n1End]) DO
          INC(n1End)
        END;
        IF (n1End < ntok) & (Strings.Compare(tok[n1End], "than") = 0) & (n1End > n1Start) THEN
          n1len := 0;
          FOR k := n1Start TO n1End - 1 DO
            IF (n1len < 8) & ~IsFiller(tok[k]) THEN
              COPY(tok[k], noun1[n1len]); INC(n1len)
            END
          END;
          IF n1len > 0 THEN
            thanPos := n1End;
            (* collect NOUN2 phrase after "than" *)
            j := thanPos + 1;
            plen := 0;
            WHILE (j < ntok) & ~IsStopOp(tok[j]) & (plen < 16) DO
              IF ~IsFiller(tok[j]) THEN
                COPY(tok[j], phrase[plen]); INC(plen)
              END;
              INC(j)
            END;
            IF plen > 0 THEN
              endPhrase := j;
              saveI := i;
              RemoveRange(saveI, endPhrase);
              (* build:  NOUN1... is NOUN2... op N *)
              k := 0;
              FOR j := 0 TO n1len - 1 DO
                InsertToken(saveI + k, noun1[j]); INC(k)
              END;
              InsertToken(saveI + k, "is"); INC(k);
              FOR j := 0 TO plen - 1 DO
                InsertToken(saveI + k, phrase[j]); INC(k)
              END;
              InsertToken(saveI + k, op); INC(k);
              InsertToken(saveI + k, numTok); INC(k);
              i := saveI + k;
              matched1 := TRUE
            END
          END
        END
      END;

      IF ~matched1 & (Strings.Compare(tok[i+2], "than") = 0) THEN
        (* shape (2): N more/less than X *)
        saveI := i;
        j := i + 3;
        plen := 0;
        WHILE (j < ntok) & ~IsStopOp(tok[j]) & (plen < 16) DO
          COPY(tok[j], phrase[plen]);
          INC(plen); INC(j)
        END;
        IF plen = 0 THEN INC(i)
        ELSE
          endPhrase := j;
          RemoveRange(saveI, endPhrase);
          FOR k := 0 TO plen - 1 DO InsertToken(saveI + k, phrase[k]) END;
          InsertToken(saveI + plen, op);
          InsertToken(saveI + plen + 1, numTok);
          i := saveI + plen + 2
        END
      ELSIF ~matched1 THEN
        INC(i)
      END
    ELSE
      INC(i)
    END
  END
END RewriteMoreLessThan;

(* "N times as many/much <W...> as <X...>" -> "N times <X...> <W...>".
   The "as many W as X" idiom is a multiplicative relation between two
   parallel counts, one of W possessed by the surrounding subject, the
   other of W possessed by X.  We copy the W-phrase so that it ends up
   after X, forming the compound quantity "X W". *)
PROCEDURE RewriteTimesAsAs;
VAR
  i, j, k, wStart, wEnd : INTEGER;
  n : REAL;
  wPhrase : ARRAY 8 OF ARRAY TOKLEN OF CHAR;
  wLen : INTEGER;
BEGIN
  i := 0;
  WHILE i + 3 < ntok DO
    IF Strings.StrToReal(tok[i], n)
       & (Strings.Compare(tok[i+1], "times") = 0)
       & (Strings.Compare(tok[i+2], "as") = 0) THEN
      (* W-phrase starts at i+3, up to but not including the next "as" *)
      wStart := i + 3;
      (* skip a leading "many"/"much"/"old"/"tall" quantifier *)
      IF (wStart < ntok)
         & ((Strings.Compare(tok[wStart], "many") = 0) OR (Strings.Compare(tok[wStart], "much") = 0)
            OR (Strings.Compare(tok[wStart], "old") = 0) OR (Strings.Compare(tok[wStart], "tall") = 0)
            OR (Strings.Compare(tok[wStart], "big") = 0) OR (Strings.Compare(tok[wStart], "large") = 0)) THEN
        INC(wStart)
      END;
      j := wStart;
      WHILE (j < ntok) & (Strings.Compare(tok[j], "as") # 0) & ~IsStopOp(tok[j]) DO INC(j) END;
      IF (j < ntok) & (Strings.Compare(tok[j], "as") = 0) THEN
        wEnd := j;
        wLen := 0;
        FOR k := wStart TO wEnd - 1 DO
          IF (wLen < 8) & ~IsFiller(tok[k]) THEN
            COPY(tok[k], wPhrase[wLen]); INC(wLen)
          END
        END;
        (* delete from tok[i+2] .. tok[j] inclusive:  "as many W as" *)
        RemoveRange(i+2, j+1);
        (* insert the W-phrase after whatever comes next (the name) --
           actually easier: insert W-phrase at end of the name phrase.
           The simplest correct place: right after the following name
           phrase, i.e. skip forward from i+2 past non-stop-op tokens. *)
        k := i + 2;
        WHILE (k < ntok) & ~IsStopOp(tok[k]) DO INC(k) END;
        FOR j := wLen - 1 TO 0 BY -1 DO
          InsertToken(k, wPhrase[j])
        END
      END
    END;
    INC(i)
  END
END RewriteTimesAsAs;

(* "as many/much/old <W...> as <X...>" (without a leading multiplier)
   -> "<X...> <W...>".  The surrounding "has" (or explicit "is") turns
   this into an equality.  Example: "Mary has as many books as John"
   becomes "Mary has John books", which RewriteHas turns into
   "Mary books is John books". *)
PROCEDURE RewriteAsAsEquality;
VAR
  i, j, k, wStart, wEnd, nameEnd : INTEGER;
  wPhrase : ARRAY 8 OF ARRAY TOKLEN OF CHAR;
  wLen : INTEGER;
BEGIN
  i := 0;
  WHILE i < ntok DO
    IF Strings.Compare(tok[i], "as") = 0 THEN
      wStart := i + 1;
      IF (wStart < ntok)
         & ((Strings.Compare(tok[wStart], "many") = 0) OR (Strings.Compare(tok[wStart], "much") = 0)
            OR (Strings.Compare(tok[wStart], "old") = 0) OR (Strings.Compare(tok[wStart], "tall") = 0)
            OR (Strings.Compare(tok[wStart], "big") = 0) OR (Strings.Compare(tok[wStart], "large") = 0)) THEN
        INC(wStart)
      END;
      j := wStart;
      WHILE (j < ntok) & (Strings.Compare(tok[j], "as") # 0) & ~IsStopOp(tok[j]) DO INC(j) END;
      IF (j < ntok) & (Strings.Compare(tok[j], "as") = 0) THEN
        wEnd := j;
        wLen := 0;
        FOR k := wStart TO wEnd - 1 DO
          IF (wLen < 8) & ~IsFiller(tok[k]) THEN
            COPY(tok[k], wPhrase[wLen]); INC(wLen)
          END
        END;
        (* remove "as <W...> as", keeping nothing where they were *)
        RemoveRange(i, j+1);
        (* insert W-phrase after the following name phrase *)
        nameEnd := i;
        WHILE (nameEnd < ntok) & ~IsStopOp(tok[nameEnd]) DO INC(nameEnd) END;
        FOR k := wLen - 1 TO 0 BY -1 DO
          InsertToken(nameEnd, wPhrase[k])
        END
      ELSE
        INC(i)
      END
    ELSE
      INC(i)
    END
  END
END RewriteAsAsEquality;

PROCEDURE IsClauseBoundary(w : ARRAY OF CHAR) : BOOLEAN;
BEGIN
  RETURN (Strings.Compare(w, ",") = 0) OR (Strings.Compare(w, ".") = 0)
      OR (Strings.Compare(w, "?") = 0) OR (Strings.Compare(w, "if") = 0)
END IsClauseBoundary;

PROCEDURE ClauseHasQuestionMarker(atIdx : INTEGER) : BOOLEAN;
VAR k : INTEGER;
BEGIN
  k := atIdx;
  WHILE (k >= 0) & ~IsClauseBoundary(tok[k]) DO
    IF (Strings.Compare(tok[k], "how") = 0) OR (Strings.Compare(tok[k], "what") = 0)
       OR (Strings.Compare(tok[k], "find") = 0) THEN RETURN TRUE END;
    DEC(k)
  END;
  RETURN FALSE
END ClauseHasQuestionMarker;

(* "<SUBJ> has/have/had <PHRASE>" -> "<SUBJ> <LASTNOUN> is <PHRASE>",
   where LASTNOUN is the final plain-word token of PHRASE (skipping
   numbers, fillers, operators, and stopping at clause boundaries).
   This turns "Mary has 24 books" into "Mary books is 24 books", and
   with the "as many" rewrites above, "Mary has 3 times as many books
   as John" becomes "Mary books is 3 times John books".  Not applied
   inside a question clause. *)
PROCEDURE RewriteHas;
VAR
  i, j, lastNoun, wl : INTEGER;
  noun : ARRAY TOKLEN OF CHAR;
  dummy : REAL;
BEGIN
  i := 0;
  WHILE i < ntok DO
    IF ((Strings.Compare(tok[i], "has") = 0) OR (Strings.Compare(tok[i], "have") = 0)
        OR (Strings.Compare(tok[i], "had") = 0))
       & ~ClauseHasQuestionMarker(i) THEN
      j := i + 1; lastNoun := -1;
      WHILE (j < ntok) & ~IsClauseBoundary(tok[j]) DO
        wl := Strings.Length(tok[j]);
        IF ~IsFiller(tok[j]) & ~IsStopOp(tok[j])
           & ~Strings.StrToReal(tok[j], dummy)
           & (wl > 0) & (tok[j][0] >= 'a') & (tok[j][0] <= 'z') THEN
          lastNoun := j
        END;
        INC(j)
      END;
      IF lastNoun >= 0 THEN
        COPY(tok[lastNoun], noun);
        ReplaceToken(i, "is");
        InsertToken(i, noun);
        INC(i, 2)
      ELSE
        INC(i)
      END
    ELSE
      INC(i)
    END
  END
END RewriteHas;

(* "there is/are <EXPR> <NOUN>" -> "<NOUN> is <EXPR>".  Handles the
   common existence statement.  We drop "there" and the copula, then
   move the trailing noun to the front, leaving a normal equation.
   Only fires when the region up to the next stop-op does NOT already
   contain another equality verb -- otherwise the "there are" is just
   vestigial scaffolding left over from an earlier rewrite. *)
PROCEDURE RewriteThereIs;
VAR
  i, j, lastNoun, exprStart : INTEGER;
  noun : ARRAY TOKLEN OF CHAR;
  dummy : REAL;
  hasEq : BOOLEAN;
BEGIN
  i := 0;
  WHILE i + 1 < ntok DO
    IF (Strings.Compare(tok[i], "there") = 0)
       & ((Strings.Compare(tok[i+1], "is") = 0) OR (Strings.Compare(tok[i+1], "are") = 0)
          OR (Strings.Compare(tok[i+1], "was") = 0) OR (Strings.Compare(tok[i+1], "were") = 0)) THEN
      exprStart := i + 2;
      hasEq := FALSE;
      j := exprStart; lastNoun := -1;
      WHILE (j < ntok) & ~IsStopOp(tok[j]) DO
        IF (Strings.Compare(tok[j], "is") = 0)     OR (Strings.Compare(tok[j], "are") = 0)
        OR (Strings.Compare(tok[j], "was") = 0)    OR (Strings.Compare(tok[j], "were") = 0)
        OR (Strings.Compare(tok[j], "equals") = 0) OR (Strings.Compare(tok[j], "equal") = 0) THEN
          hasEq := TRUE
        END;
        IF ~IsFiller(tok[j]) & ~Strings.StrToReal(tok[j], dummy) THEN
          lastNoun := j
        END;
        INC(j)
      END;
      IF hasEq THEN
        (* leave the real equation alone; delete the vestigial
           "there is/are" so it doesn't produce a spurious clause *)
        RemoveRange(i, i+2)
      ELSIF lastNoun >= 0 THEN
        COPY(tok[lastNoun], noun);
        RemoveRange(i, i+2);
        DEC(lastNoun, 2);
        RemoveRange(lastNoun, lastNoun + 1);
        InsertToken(i, "is");
        InsertToken(i, noun);
        INC(i, 2)
      ELSE
        INC(i)
      END
    ELSE
      INC(i)
    END
  END
END RewriteThereIs;

(* "in N years" -> "plus N", "N years ago" -> "minus N".  Requires
   surrounding context; we only rewrite when the surrounding tokens
   are compatible with attaching to a nearby age phrase. *)
PROCEDURE RewriteAgeShifts;
VAR i : INTEGER; n : REAL;
BEGIN
  i := 0;
  WHILE i + 2 < ntok DO
    IF (Strings.Compare(tok[i], "in") = 0)
       & Strings.StrToReal(tok[i+1], n)
       & ((Strings.Compare(tok[i+2], "year") = 0) OR (Strings.Compare(tok[i+2], "years") = 0)) THEN
      ReplaceToken(i, "plus");
      (* tok[i+1] already the number *)
      RemoveRange(i+2, i+3);
      INC(i, 2)
    ELSIF Strings.StrToReal(tok[i], n)
       & ((Strings.Compare(tok[i+1], "year") = 0) OR (Strings.Compare(tok[i+1], "years") = 0))
       & (Strings.Compare(tok[i+2], "ago") = 0) THEN
      (* transform  N years ago  ->  minus N *)
      ReplaceToken(i+2, "");            (* placeholder; RemoveRange next *)
      RemoveRange(i+1, i+3);            (* remove "years ago" *)
      InsertToken(i, "minus");          (* becomes "minus N" *)
      INC(i, 2)
    ELSE
      INC(i)
    END
  END
END RewriteAgeShifts;

(* generic numeric unknowns *)
PROCEDURE RewriteGenericNumbers;
BEGIN
  Rewrite3To2("the", "first",  "number", "first",  "number");
  Rewrite3To2("the", "second", "number", "second", "number");
  Rewrite3To2("the", "third",  "number", "third",  "number");
  Rewrite3To2("the", "fourth", "number", "fourth", "number");
  (* "a number" alone becomes "some number" so it becomes a var *)
  Rewrite2To2("a", "number", "some", "number")
END RewriteGenericNumbers;

PROCEDURE Preprocess;
BEGIN
  (* normalise multi-word idioms first *)
  Collapse2("per", "cent", "percent");
  Collapse2("two", "times", "twice");
  Collapse2("three", "times", "thrice");

  Rewrite3To2("one", "half",     "of", "0.5",     "times");
  Rewrite3To2("one", "third",    "of", "0.333333", "times");
  Rewrite3To2("two", "thirds",   "of", "0.666667", "times");
  Rewrite3To2("two", "third",    "of", "0.666667", "times");
  Rewrite3To2("one", "quarter",  "of", "0.25",    "times");
  Rewrite3To2("one", "fourth",   "of", "0.25",    "times");
  Rewrite3To2("three", "quarters","of","0.75",    "times");
  Rewrite3To2("three", "quarter", "of","0.75",    "times");
  Rewrite3To2("three", "fourths", "of","0.75",    "times");

  Collapse2("multiplied", "by", "times");
  Collapse2("divided",    "by", "over");    (* "over" ~ "divided by" *)

  RewriteGenericNumbers;

  (* comparative idioms first, since they may inject "is" tokens that
     later passes should treat as equalities *)
  RewriteMoreLessThan;
  RewriteTimesAsAs;
  RewriteAsAsEquality;

  (* "X has ..." and "there is ..." rewrites turn possessive/existence
     assertions into equations; must run after the "as many ... as ..."
     rewrites have already moved the compared noun into place *)
  RewriteHas;
  RewriteThereIs;

  RewriteAgeShifts
END Preprocess;

(* ---------------------------------------------------------------- *)
(* variable table                                                   *)
(* ---------------------------------------------------------------- *)

PROCEDURE FindOrAddVar(name : ARRAY OF CHAR) : INTEGER;
VAR i : INTEGER;
BEGIN
  FOR i := 0 TO nvars - 1 DO
    IF Strings.Compare(varName[i], name) = 0 THEN RETURN i END
  END;
  IF nvars < MAXVARS THEN
    COPY(name, varName[nvars]);
    INC(nvars);
    RETURN nvars - 1
  ELSE
    Out.String("  (warning: too many distinct quantities)"); Out.Ln;
    RETURN 0
  END
END FindOrAddVar;

PROCEDURE CapturePhrase(ce : INTEGER; VAR pos : INTEGER; VAR name : ARRAY OF CHAR);
BEGIN
  name[0] := 0X;
  WHILE (pos < ce) & ~IsStopOp(tok[pos]) DO
    IF ~IsFiller(tok[pos]) THEN
      IF name[0] # 0X THEN Strings.Append(" ", name) END;
      Strings.Append(tok[pos], name)
    END;
    INC(pos)
  END
END CapturePhrase;

(* ---------------------------------------------------------------- *)
(* linear-expression algebra                                        *)
(* ---------------------------------------------------------------- *)

PROCEDURE ConstExpr(k : REAL; VAR r : LinExpr);
VAR i : INTEGER;
BEGIN
  FOR i := 0 TO MAXVARS - 1 DO r.coef[i] := 0.0 END;
  r.cst := k
END ConstExpr;

PROCEDURE MakeVarExpr(vi : INTEGER; VAR r : LinExpr);
VAR i : INTEGER;
BEGIN
  FOR i := 0 TO MAXVARS - 1 DO r.coef[i] := 0.0 END;
  r.cst := 0.0;
  r.coef[vi] := 1.0
END MakeVarExpr;

PROCEDURE IsConstExpr(e : LinExpr) : BOOLEAN;
VAR i : INTEGER; c : BOOLEAN;
BEGIN
  c := TRUE;
  FOR i := 0 TO MAXVARS - 1 DO
    IF e.coef[i] # 0.0 THEN c := FALSE END
  END;
  RETURN c
END IsConstExpr;

PROCEDURE ScaleExpr(e : LinExpr; k : REAL; VAR r : LinExpr);
VAR i : INTEGER;
BEGIN
  FOR i := 0 TO MAXVARS - 1 DO r.coef[i] := e.coef[i] * k END;
  r.cst := e.cst * k
END ScaleExpr;

PROCEDURE AddExpr(a, b : LinExpr; VAR r : LinExpr);
VAR i : INTEGER;
BEGIN
  FOR i := 0 TO MAXVARS - 1 DO r.coef[i] := a.coef[i] + b.coef[i] END;
  r.cst := a.cst + b.cst
END AddExpr;

PROCEDURE SubExpr(a, b : LinExpr; VAR r : LinExpr);
VAR i : INTEGER;
BEGIN
  FOR i := 0 TO MAXVARS - 1 DO r.coef[i] := a.coef[i] - b.coef[i] END;
  r.cst := a.cst - b.cst
END SubExpr;

PROCEDURE MulExpr(a, b : LinExpr; VAR r : LinExpr);
BEGIN
  IF IsConstExpr(a) THEN ScaleExpr(b, a.cst, r)
  ELSIF IsConstExpr(b) THEN ScaleExpr(a, b.cst, r)
  ELSE
    Out.String("  (warning: unknown times unknown is not linear - approximating)"); Out.Ln;
    r := a
  END
END MulExpr;

PROCEDURE DivExpr(a, b : LinExpr; VAR r : LinExpr);
BEGIN
  IF IsConstExpr(b) & (b.cst # 0.0) THEN
    ScaleExpr(a, 1.0 / b.cst, r)
  ELSE
    Out.String("  (warning: division by an unknown is not supported)"); Out.Ln;
    r := a
  END
END DivExpr;

(* ---------------------------------------------------------------- *)
(* recursive-descent expression parser over tok[pos..ce)            *)
(* ---------------------------------------------------------------- *)

PROCEDURE ParseFactor(ce : INTEGER; VAR pos : INTEGER; VAR r : LinExpr);
VAR
  val   : REAL;
  a, b  : LinExpr;
  name  : ARRAY NAMELEN OF CHAR;
  vi    : INTEGER;
BEGIN
  WHILE (pos < ce) & IsFiller(tok[pos]) DO INC(pos) END;

  IF pos >= ce THEN
    ConstExpr(0.0, r);
    RETURN
  END;

  IF Strings.StrToReal(tok[pos], val) THEN
    INC(pos);
    IF (pos < ce) & (Strings.Compare(tok[pos], "percent") = 0) THEN
      INC(pos);
      val := val / 100.0;
      IF (pos < ce) & (Strings.Compare(tok[pos], "of") = 0) THEN
        INC(pos);
        ParseFactor(ce, pos, b);
        ScaleExpr(b, val, r)
      ELSE
        ConstExpr(val, r)
      END
    ELSE
      ConstExpr(val, r)
    END

  ELSIF (Strings.Compare(tok[pos], "twice") = 0) OR (Strings.Compare(tok[pos], "double") = 0) THEN
    INC(pos); ParseFactor(ce, pos, b); ScaleExpr(b, 2.0, r)

  ELSIF (Strings.Compare(tok[pos], "thrice") = 0) OR (Strings.Compare(tok[pos], "triple") = 0) THEN
    INC(pos); ParseFactor(ce, pos, b); ScaleExpr(b, 3.0, r)

  ELSIF Strings.Compare(tok[pos], "half") = 0 THEN
    INC(pos); ParseFactor(ce, pos, b); ScaleExpr(b, 0.5, r)

  ELSIF Strings.Compare(tok[pos], "sum") = 0 THEN
    INC(pos); ParseTerm(ce, pos, a);
    IF (pos < ce) & (Strings.Compare(tok[pos], "and") = 0) THEN INC(pos) END;
    ParseTerm(ce, pos, b);
    AddExpr(a, b, r)

  ELSIF Strings.Compare(tok[pos], "difference") = 0 THEN
    INC(pos); ParseTerm(ce, pos, a);
    IF (pos < ce) & (Strings.Compare(tok[pos], "and") = 0) THEN INC(pos) END;
    ParseTerm(ce, pos, b);
    SubExpr(a, b, r)

  ELSIF Strings.Compare(tok[pos], "product") = 0 THEN
    INC(pos); ParseTerm(ce, pos, a);
    IF (pos < ce) & (Strings.Compare(tok[pos], "and") = 0) THEN INC(pos) END;
    ParseTerm(ce, pos, b);
    MulExpr(a, b, r)

  ELSIF Strings.Compare(tok[pos], "quotient") = 0 THEN
    INC(pos); ParseTerm(ce, pos, a);
    IF (pos < ce) & (Strings.Compare(tok[pos], "and") = 0) THEN INC(pos) END;
    ParseTerm(ce, pos, b);
    DivExpr(a, b, r)

  ELSIF Strings.Compare(tok[pos], "(") = 0 THEN
    INC(pos);
    ParseExpr(ce, pos, r);
    IF (pos < ce) & (Strings.Compare(tok[pos], ")") = 0) THEN INC(pos) END

  ELSE
    CapturePhrase(ce, pos, name);
    IF name[0] = 0X THEN
      Out.String("  (warning: expected a quantity near '");
      IF pos < ce THEN Out.String(tok[pos]) END;
      Out.String("')"); Out.Ln;
      IF pos < ce THEN INC(pos) END;
      ConstExpr(0.0, r)
    ELSE
      vi := FindOrAddVar(name);
      MakeVarExpr(vi, r)
    END
  END
END ParseFactor;

PROCEDURE ParseTerm(ce : INTEGER; VAR pos : INTEGER; VAR r : LinExpr);
VAR f : LinExpr;
BEGIN
  ParseFactor(ce, pos, r);
  LOOP
    IF pos >= ce THEN EXIT END;
    IF (Strings.Compare(tok[pos], "times") = 0) OR (Strings.Compare(tok[pos], "multiplied") = 0) THEN
      INC(pos);
      IF (pos < ce) & (Strings.Compare(tok[pos], "by") = 0) THEN INC(pos) END;
      ParseFactor(ce, pos, f);
      MulExpr(r, f, r)
    ELSIF (Strings.Compare(tok[pos], "divided") = 0) OR (Strings.Compare(tok[pos], "over") = 0) THEN
      INC(pos);
      IF (pos < ce) & (Strings.Compare(tok[pos], "by") = 0) THEN INC(pos) END;
      ParseFactor(ce, pos, f);
      DivExpr(r, f, r)
    ELSE
      EXIT
    END
  END
END ParseTerm;

PROCEDURE ParseExpr(ce : INTEGER; VAR pos : INTEGER; VAR r : LinExpr);
VAR t : LinExpr;
BEGIN
  ParseTerm(ce, pos, r);
  WHILE (pos < ce) & ((Strings.Compare(tok[pos], "plus") = 0) OR (Strings.Compare(tok[pos], "minus") = 0)) DO
    IF Strings.Compare(tok[pos], "plus") = 0 THEN
      INC(pos); ParseTerm(ce, pos, t); AddExpr(r, t, r)
    ELSE
      INC(pos); ParseTerm(ce, pos, t); SubExpr(r, t, r)
    END
  END
END ParseExpr;

(* ---------------------------------------------------------------- *)
(* clause -> equation                                                *)
(* ---------------------------------------------------------------- *)

PROCEDURE MarkUsed(e : LinExpr);
VAR i : INTEGER;
BEGIN
  FOR i := 0 TO nvars - 1 DO
    IF e.coef[i] # 0.0 THEN usedInFacts[i] := TRUE END
  END
END MarkUsed;

PROCEDURE ParseClauseEquation(cs0, ce : INTEGER);
VAR
  cs, k, eqIdx, pos, v : INTEGER;
  lhs, rhs : LinExpr;
BEGIN
  cs := cs0;
  IF (cs < ce) & (Strings.Compare(tok[cs], "if") = 0) THEN INC(cs) END;
  IF cs >= ce THEN RETURN END;

  eqIdx := -1;
  k := cs;
  WHILE (k < ce) & (eqIdx = -1) DO
    IF (Strings.Compare(tok[k], "is") = 0)     OR (Strings.Compare(tok[k], "are") = 0)
    OR (Strings.Compare(tok[k], "was") = 0)    OR (Strings.Compare(tok[k], "were") = 0)
    OR (Strings.Compare(tok[k], "equals") = 0) OR (Strings.Compare(tok[k], "equal") = 0) THEN
      eqIdx := k
    END;
    INC(k)
  END;
  IF eqIdx = -1 THEN RETURN END;  (* not an equational clause; ignore *)

  pos := cs;      ParseExpr(eqIdx, pos, lhs);
  pos := eqIdx+1; ParseExpr(ce, pos, rhs);

  MarkUsed(lhs); MarkUsed(rhs);

  IF neq < MAXEQS THEN
    FOR v := 0 TO MAXVARS - 1 DO
      eqCoef[neq][v] := lhs.coef[v] - rhs.coef[v]
    END;
    eqConst[neq] := rhs.cst - lhs.cst;
    INC(neq)
  ELSE
    Out.String("  (warning: too many equations)"); Out.Ln
  END
END ParseClauseEquation;

(* ---------------------------------------------------------------- *)
(* travel idiom: "<subject> travels [at] N mph for M hours"          *)
(* generalised to multiple travellers, each getting <subj>_distance. *)
(* ---------------------------------------------------------------- *)

PROCEDURE ScanTravelIdiom;
VAR
  i, j, k, subjStart, subjEnd, vi, startSearch : INTEGER;
  speed, time : REAL;
  matched : BOOLEAN;
  subj  : ARRAY NAMELEN OF CHAR;
BEGIN
  startSearch := 0;
  LOOP
    (* find next "travels" (which the singularizer will have reduced
       to "travel") at or after startSearch *)
    i := startSearch;
    WHILE (i < ntok) & (Strings.Compare(tok[i], "travel") # 0)
                     & (Strings.Compare(tok[i], "travels") # 0) DO INC(i) END;
    IF i >= ntok THEN EXIT END;

    matched := FALSE;
    j := i + 1;
    IF (j < ntok) & (Strings.Compare(tok[j], "at") = 0) THEN INC(j) END;
    IF (j < ntok) & Strings.StrToReal(tok[j], speed) THEN
      INC(j);
      IF (j < ntok) & (Strings.Compare(tok[j], "mph") = 0) THEN
        INC(j);
        IF (j < ntok) & (Strings.Compare(tok[j], "for") = 0) THEN
          INC(j);
          IF (j < ntok) & Strings.StrToReal(tok[j], time) THEN
            INC(j);
            IF (j < ntok) & ((Strings.Compare(tok[j], "hours") = 0) OR (Strings.Compare(tok[j], "hour") = 0)) THEN
              INC(j)
            END;
            matched := TRUE
          END
        END
      END
    END;

    IF ~matched THEN
      startSearch := i + 1
    ELSE
      (* subject: the run of non-filler, non-stop-op tokens just before "travels" *)
      subjEnd := i;
      subjStart := i;
      WHILE (subjStart > 0) & ~IsStopOp(tok[subjStart-1]) & ~IsFiller(tok[subjStart-1]) DO
        DEC(subjStart)
      END;

      subj[0] := 0X;
      IF subjStart = subjEnd THEN
        COPY("distance", subj)
      ELSE
        FOR k := subjStart TO subjEnd - 1 DO
          IF subj[0] # 0X THEN Strings.Append(" ", subj) END;
          Strings.Append(tok[k], subj)
        END;
        Strings.Append(" distance", subj)
      END;

      vi := FindOrAddVar(subj);
      IF neq < MAXEQS THEN
        FOR k := 0 TO MAXVARS - 1 DO eqCoef[neq][k] := 0.0 END;
        eqCoef[neq][vi] := 1.0;
        eqConst[neq] := speed * time
        (* NB: intentionally do NOT set usedInFacts[vi].  The idiom
           defines this variable; a question like "how far does it go?"
           may want to fall back to it as the sole unnamed unknown. *)
        ;INC(neq)
      END;
      RemoveRange(subjStart, j);
      startSearch := subjStart   (* resume from where we spliced *)
    END
  END
END ScanTravelIdiom;

(* ---------------------------------------------------------------- *)
(* Gaussian elimination with partial pivoting                        *)
(* ---------------------------------------------------------------- *)

PROCEDURE SolveSystem(n : INTEGER; VAR x : ARRAY OF REAL) : BOOLEAN;
VAR
  a : ARRAY MAXVARS, AUGCOLS OF REAL;
  i, j, k, piv : INTEGER;
  maxval, factor, tmp, sum : REAL;
BEGIN
  FOR i := 0 TO n - 1 DO
    FOR j := 0 TO n - 1 DO a[i][j] := eqCoef[i][j] END;
    a[i][n] := eqConst[i]
  END;

  FOR k := 0 TO n - 1 DO
    piv := k;
    maxval := ABS(a[k][k]);
    FOR i := k + 1 TO n - 1 DO
      IF ABS(a[i][k]) > maxval THEN piv := i; maxval := ABS(a[i][k]) END
    END;
    IF maxval < 1.0E-9 THEN RETURN FALSE END;
    IF piv # k THEN
      FOR j := 0 TO n DO
        tmp := a[k][j]; a[k][j] := a[piv][j]; a[piv][j] := tmp
      END
    END;
    FOR i := k + 1 TO n - 1 DO
      factor := a[i][k] / a[k][k];
      FOR j := k TO n DO
        a[i][j] := a[i][j] - factor * a[k][j]
      END
    END
  END;

  FOR i := n - 1 TO 0 BY -1 DO
    sum := a[i][n];
    FOR j := i + 1 TO n - 1 DO sum := sum - a[i][j] * x[j] END;
    x[i] := sum / a[i][i]
  END;
  RETURN TRUE
END SolveSystem;

PROCEDURE PrintNumber(v : REAL);
VAR iv : INTEGER;
BEGIN
  IF v >= 0.0 THEN iv := FLOOR(v + 0.5) ELSE iv := -FLOOR(0.5 - v) END;
  IF ABS(v - FLT(iv)) < 1.0E-6 THEN
    Out.Int(iv)
  ELSE
    Out.Fixed(v, 0, 2)
  END
END PrintNumber;

(* pretty-print one derived equation *)
PROCEDURE PrintEquation(row : INTEGER);
VAR
  i, printed : INTEGER;
  c          : REAL;
  first      : BOOLEAN;
BEGIN
  Out.String("      ");
  first := TRUE; printed := 0;
  FOR i := 0 TO nvars - 1 DO
    c := eqCoef[row][i];
    IF c # 0.0 THEN
      IF first THEN
        IF c < 0.0 THEN Out.String("-"); c := -c END
      ELSE
        IF c < 0.0 THEN Out.String(" - "); c := -c ELSE Out.String(" + ") END
      END;
      IF ABS(c - 1.0) > 1.0E-9 THEN PrintNumber(c); Out.String("*") END;
      Out.String(varName[i]);
      first := FALSE; INC(printed)
    END
  END;
  IF first THEN Out.String("0") END;
  Out.String(" = ");
  PrintNumber(eqConst[row]);
  Out.Ln
END PrintEquation;

(* If name is "<first_word> <rest...>", rewrite it as "<rest...> <first_word>".
   Used to reorder question phrases like "book john" into "john book". *)
PROCEDURE SwapFirstWordToEnd(VAR name : ARRAY OF CHAR);
VAR
  firstWord : ARRAY TOKLEN OF CHAR;
  rest      : ARRAY NAMELEN OF CHAR;
  k, sp     : INTEGER;
BEGIN
  sp := 0;
  WHILE (name[sp] # 0X) & (name[sp] # ' ') DO INC(sp) END;
  IF name[sp] # ' ' THEN RETURN END;
  FOR k := 0 TO sp - 1 DO firstWord[k] := name[k] END;
  firstWord[sp] := 0X;
  k := 0;
  WHILE name[sp + 1 + k] # 0X DO
    rest[k] := name[sp + 1 + k]; INC(k)
  END;
  rest[k] := 0X;
  name[0] := 0X;
  Strings.Append(rest, name);
  Strings.Append(" ", name);
  Strings.Append(firstWord, name)
END SwapFirstWordToEnd;

(* ---------------------------------------------------------------- *)
(* top level: parse the whole problem, build equations, solve        *)
(* ---------------------------------------------------------------- *)

PROCEDURE Solve(problem : ARRAY OF CHAR);
VAR
  triggerIdx, qStart, i, cs, pos, vi, unnamed, unnamedIdx : INTEGER;
  protectAnd : BOOLEAN;
  qname : ARRAY NAMELEN OF CHAR;
  x     : ARRAY MAXVARS OF REAL;
  ok    : BOOLEAN;
BEGIN
  nvars := 0; neq := 0;
  FOR i := 0 TO MAXVARS - 1 DO usedInFacts[i] := FALSE END;

  Lex(problem);
  Preprocess;
  ScanTravelIdiom;

  (* locate the question *)
  triggerIdx := -1; qStart := -1;
  i := 0;
  WHILE (i < ntok) & (triggerIdx = -1) DO
    IF Strings.Compare(tok[i], "find") = 0 THEN
      triggerIdx := i; qStart := i + 1
    ELSIF (Strings.Compare(tok[i], "what") = 0) & (i + 1 < ntok) &
          ((Strings.Compare(tok[i+1], "is") = 0) OR (Strings.Compare(tok[i+1], "was") = 0)
           OR (Strings.Compare(tok[i+1], "are") = 0)) THEN
      triggerIdx := i; qStart := i + 2
    ELSIF (Strings.Compare(tok[i], "how") = 0) & (i + 1 < ntok) &
          ((Strings.Compare(tok[i+1], "many") = 0) OR (Strings.Compare(tok[i+1], "much") = 0)
           OR (Strings.Compare(tok[i+1], "far") = 0)) THEN
      triggerIdx := i; qStart := i + 2
    ELSIF (Strings.Compare(tok[i], "how") = 0) & (i + 2 < ntok) &
          (Strings.Compare(tok[i+1], "old") = 0) &
          ((Strings.Compare(tok[i+2], "is") = 0) OR (Strings.Compare(tok[i+2], "are") = 0)
           OR (Strings.Compare(tok[i+2], "was") = 0) OR (Strings.Compare(tok[i+2], "were") = 0)) THEN
      triggerIdx := i; qStart := i + 3   (* the following subject; we'll append "age" *)
    END;
    INC(i)
  END;

  IF triggerIdx = -1 THEN
    Out.String("  I could not find a question in that problem."); Out.Ln;
    RETURN
  END;

  (* split the facts into clauses on top-level ',', '.', 'and' *)
  cs := 0; protectAnd := FALSE; i := 0;
  WHILE i < triggerIdx DO
    IF (Strings.Compare(tok[i], "sum") = 0)        OR (Strings.Compare(tok[i], "difference") = 0)
    OR (Strings.Compare(tok[i], "product") = 0)    OR (Strings.Compare(tok[i], "quotient") = 0) THEN
      protectAnd := TRUE
    END;
    IF (Strings.Compare(tok[i], ",") = 0) OR (Strings.Compare(tok[i], ".") = 0) OR (Strings.Compare(tok[i], "and") = 0) THEN
      IF (Strings.Compare(tok[i], "and") = 0) & protectAnd THEN
        protectAnd := FALSE
      ELSE
        ParseClauseEquation(cs, i);
        cs := i + 1
      END
    END;
    INC(i)
  END;
  ParseClauseEquation(cs, triggerIdx);

  (* the question phrase *)
  pos := qStart;
  CapturePhrase(ntok, pos, qname);

  (* "how old is X" => qname should be "X age" *)
  IF (triggerIdx + 1 < ntok) & (Strings.Compare(tok[triggerIdx], "how") = 0)
     & (Strings.Compare(tok[triggerIdx+1], "old") = 0) THEN
    IF qname[0] # 0X THEN Strings.Append(" age", qname) END
  END;

  (* "how far ..." => append "distance" to whatever subject was named
     (e.g. "how far does the car go" -> qname "car" -> "car distance").
     If no subject was named, the fallback picks it up. *)
  IF (triggerIdx + 1 < ntok) & (Strings.Compare(tok[triggerIdx], "how") = 0)
     & (Strings.Compare(tok[triggerIdx+1], "far") = 0) THEN
    IF qname[0] # 0X THEN Strings.Append(" distance", qname) END
  END;

  (* "how many <NOUN> does <SUBJ>" produces a captured phrase in the
     wrong word order: "NOUN SUBJ" -- rebuild as "SUBJ NOUN" to match
     the compound quantity name RewriteHas would have created for a
     matching fact "<SUBJ> has ... <NOUN>". *)
  IF (triggerIdx + 1 < ntok) & (Strings.Compare(tok[triggerIdx], "how") = 0)
     & ((Strings.Compare(tok[triggerIdx+1], "many") = 0)
        OR (Strings.Compare(tok[triggerIdx+1], "much") = 0)) THEN
    SwapFirstWordToEnd(qname)
  END;

  IF (qname[0] = 0X) & (nvars = 1) THEN COPY(varName[0], qname) END;

  (* show what we derived *)
  IF neq > 0 THEN
    Out.String("  I derive:"); Out.Ln;
    FOR i := 0 TO neq - 1 DO PrintEquation(i) END
  END;

  vi := -1;
  i := 0;
  WHILE i < nvars DO
    IF Strings.Compare(varName[i], qname) = 0 THEN vi := i END;
    INC(i)
  END;

  (* fallback: if the question phrase doesn't match a known unknown but
     exactly one unknown was never used in the facts, that must be it. *)
  IF vi = -1 THEN
    unnamed := 0; unnamedIdx := -1;
    FOR i := 0 TO nvars - 1 DO
      IF ~usedInFacts[i] THEN INC(unnamed); unnamedIdx := i END
    END;
    IF unnamed = 1 THEN
      vi := unnamedIdx;
      COPY(varName[vi], qname)
    END
  END;

  IF vi = -1 THEN
    Out.String("  Sorry, I don't know what '"); Out.String(qname);
    Out.String("' refers to."); Out.Ln;
    RETURN
  END;

  IF neq # nvars THEN
    Out.String("  I could not derive enough equations to solve this uniquely (");
    Out.Int(neq); Out.String(" equation(s) for "); Out.Int(nvars); Out.String(" unknown(s))."); Out.Ln;
    RETURN
  END;

  ok := SolveSystem(nvars, x);
  IF ~ok THEN
    Out.String("  The equations are inconsistent or singular."); Out.Ln
  ELSE
    Out.String("  The "); Out.String(qname); Out.String(" is ");
    PrintNumber(x[vi]);
    Out.Ln
  END
END Solve;

(* ---------------------------------------------------------------- *)
(* demo + interactive loop                                           *)
(* ---------------------------------------------------------------- *)

VAR input : ARRAY 1024 OF CHAR;

BEGIN
  Out.String("STUDENT -- an algebra word-problem solver (after Bobrow, 1964)"); Out.Ln;
  Out.String("================================================================"); Out.Ln;
  Out.Ln;

  Out.String("> If a train travels 60 mph for 3 hours, how far does it go?"); Out.Ln;
  Solve("If a train travels 60 mph for 3 hours, how far does it go?");
  Out.Ln;

  Out.String("> If the number of pigs is 4 times the number of ducks, and the"); Out.Ln;
  Out.String("  number of pigs plus the number of ducks is 20, find the number of ducks."); Out.Ln;
  Solve("If the number of pigs is 4 times the number of ducks, and the number of pigs plus the number of ducks is 20, find the number of ducks.");
  Out.Ln;

  Out.String("> If the number of apples is 20 percent of the number of oranges,"); Out.Ln;
  Out.String("  and the number of oranges is 50, find the number of apples."); Out.Ln;
  Solve("If the number of apples is 20 percent of the number of oranges, and the number of oranges is 50, find the number of apples.");
  Out.Ln;

  Out.String("> If the sum of the father's age and the son's age is 66, and the"); Out.Ln;
  Out.String("  father's age is twice the son's age, find the son's age."); Out.Ln;
  Solve("If the sum of the father's age and the son's age is 66, and the father's age is twice the son's age, find the son's age.");
  Out.Ln;

  (* --- new demos exercising the extensions --- *)

  Out.String("> There are 5 more apples than oranges, and there are 12 oranges."); Out.Ln;
  Out.String("  How many apples are there?"); Out.Ln;
  Solve("There are 5 more apples than oranges, and there are 12 oranges. How many apples are there?");
  Out.Ln;

  Out.String("> Mary has 3 times as many books as John, and Mary has 24 books."); Out.Ln;
  Out.String("  How many books does John have?"); Out.Ln;
  Solve("Mary has 3 times as many books as John, and Mary has 24 books. How many books does John have?");
  Out.Ln;

  Out.String("> Mary's age is 3 times John's age, and Mary's age plus 6"); Out.Ln;
  Out.String("  is twice John's age plus 12.  How old is Mary?"); Out.Ln;
  Solve("Mary's age is 3 times John's age, and Mary's age plus 6 is twice John's age plus 12. How old is Mary?");
  Out.Ln;

  Out.String("> The sum of two thirds of the first number and one half of the"); Out.Ln;
  Out.String("  second number is 20, and the first number is 12.  What is the"); Out.Ln;
  Out.String("  second number?"); Out.Ln;
  Solve("The sum of two thirds of the first number and one half of the second number is 20, and the first number is 12. What is the second number?");
  Out.Ln;

  Out.String("> A train travels 60 mph for 3 hours and a car travels 40 mph"); Out.Ln;
  Out.String("  for 5 hours.  The total is the sum of the train distance"); Out.Ln;
  Out.String("  and the car distance.  What is the total?"); Out.Ln;
  Solve("A train travels 60 mph for 3 hours and a car travels 40 mph for 5 hours. The total is the sum of the train distance and the car distance. What is the total?");
  Out.Ln;

  Out.String("Enter your own problems below (use consistent wording for each"); Out.Ln;
  Out.String("quantity). Blank line or 'quit' to exit."); Out.Ln;
  Out.Ln;

  LOOP
    History.ReadLine("Problem> ", input);
    Strings.Trim(input);
    IF (input[0] = 0X) OR (Strings.Compare(input, "quit") = 0) OR (Strings.Compare(input, "exit") = 0) THEN
      EXIT
    END;
    Solve(input);
    Out.Ln
  END
END Student.
