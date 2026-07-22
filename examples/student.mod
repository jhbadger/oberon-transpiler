MODULE Student;
(*
 * STUDENT — an algebra word-problem solver, after Daniel Bobrow's 1964
 * MIT thesis program of the same name.
 *
 * The original STUDENT translated English algebra word problems into
 * simultaneous linear equations and solved them.  It worked by matching
 * the input against a few hundred hand-written pattern/template pairs.
 * This is a much smaller version of the same idea:
 *
 *   1. Lex     - lowercase the sentence, split off punctuation, and
 *                break it into words.
 *   2. Idiom   - recognise the "travels N mph for M hours" idiom and
 *                turn it directly into an equation (distance = rate*time).
 *   3. Clauses - split the remaining "facts" on top-level "and"/","/"."
 *                (protecting the "and" inside "sum of X and Y" etc.),
 *                strip a leading "if", and split each clause on an
 *                equality verb (is/are/was/were/equals) into a left and
 *                right side.
 *   4. Parse   - a small recursive-descent expression parser turns each
 *                side into a linear combination of unknowns (LinExpr):
 *                numbers, named quantities ("the number of pigs"),
 *                +, -, *, / (times/multiplied by/divided by), "twice",
 *                "half", "thrice", "N percent [of X]", and the phrases
 *                "sum of A and B", "difference between A and B",
 *                "product of A and B", "quotient of A and B".
 *   5. Solve   - the resulting square linear system is solved by
 *                Gaussian elimination with partial pivoting, and the
 *                value of the quantity named in the question
 *                ("find ...", "what is ...", "how many/much/far ...")
 *                is printed.
 *
 * Limitations (shared in spirit with the 1964 original, which also
 * relied on a fixed set of patterns rather than general understanding):
 *   - A quantity must be referred to with the *same* wording every time
 *     it appears (e.g. always "the number of ducks"); STUDENT-64 dealt
 *     with this via synonym dictionaries, which this version omits.
 *   - Only linear word problems are handled; "twice X" times "half Y"
 *     (unknown times unknown) is not solvable and is reported as such.
 *   - The problem must be exactly determined: as many independent
 *     equations as unknowns.
 *)

IMPORT Out, Strings, History;

CONST
  MAXTOK   = 400;
  TOKLEN   = 32;
  MAXVARS  = 12;
  MAXEQS   = 12;
  AUGCOLS  = 13;   (* must be MAXVARS + 1 *)
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
(* lexer: lowercase, split off punctuation, split "%" -> " percent " *)
(* ---------------------------------------------------------------- *)

PROCEDURE Lex(problem : ARRAY OF CHAR);
VAR
  i, j, n : INTEGER;
  c       : CHAR;
  outp    : ARRAY 2048 OF CHAR;
  pos     : INTEGER;
  word    : ARRAY TOKLEN OF CHAR;
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
    IF ntok < MAXTOK THEN COPY(word, tok[ntok]); INC(ntok) END;
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
    INC(pos); ParseFactor(ce, pos, a);
    IF (pos < ce) & (Strings.Compare(tok[pos], "and") = 0) THEN INC(pos) END;
    ParseFactor(ce, pos, b);
    AddExpr(a, b, r)

  ELSIF Strings.Compare(tok[pos], "difference") = 0 THEN
    INC(pos); ParseFactor(ce, pos, a);
    IF (pos < ce) & (Strings.Compare(tok[pos], "and") = 0) THEN INC(pos) END;
    ParseFactor(ce, pos, b);
    SubExpr(a, b, r)

  ELSIF Strings.Compare(tok[pos], "product") = 0 THEN
    INC(pos); ParseFactor(ce, pos, a);
    IF (pos < ce) & (Strings.Compare(tok[pos], "and") = 0) THEN INC(pos) END;
    ParseFactor(ce, pos, b);
    MulExpr(a, b, r)

  ELSIF Strings.Compare(tok[pos], "quotient") = 0 THEN
    INC(pos); ParseFactor(ce, pos, a);
    IF (pos < ce) & (Strings.Compare(tok[pos], "and") = 0) THEN INC(pos) END;
    ParseFactor(ce, pos, b);
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
    ELSIF Strings.Compare(tok[pos], "divided") = 0 THEN
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
(* "X travels N mph for M hours" idiom -> distance = N * M           *)
(* ---------------------------------------------------------------- *)

PROCEDURE ScanTravelIdiom;
VAR
  i, j, k, vi : INTEGER;
  speed, time : REAL;
  found : BOOLEAN;
BEGIN
  found := FALSE; i := 0;
  LOOP
    IF (i >= ntok) OR found THEN EXIT END;
    IF Strings.Compare(tok[i], "travels") = 0 THEN
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
                INC(j);
                found := TRUE
              END
            END
          END
        END
      END
    END;
    IF ~found THEN INC(i) END
  END;

  IF found THEN
    vi := FindOrAddVar("distance");
    IF neq < MAXEQS THEN
      FOR k := 0 TO MAXVARS - 1 DO eqCoef[neq][k] := 0.0 END;
      eqCoef[neq][vi] := 1.0;
      eqConst[neq] := speed * time;
      INC(neq)
    END;
    RemoveRange(i, j)
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

(* ---------------------------------------------------------------- *)
(* top level: parse the whole problem, build equations, solve        *)
(* ---------------------------------------------------------------- *)

PROCEDURE Solve(problem : ARRAY OF CHAR);
VAR
  triggerIdx, qStart, i, cs, pos, vi : INTEGER;
  protectAnd : BOOLEAN;
  qname : ARRAY NAMELEN OF CHAR;
  x     : ARRAY MAXVARS OF REAL;
  ok    : BOOLEAN;
BEGIN
  nvars := 0; neq := 0;
  Lex(problem);
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
  IF (qname[0] = 0X) & (nvars = 1) THEN COPY(varName[0], qname) END;

  vi := -1;
  i := 0;
  WHILE i < nvars DO
    IF Strings.Compare(varName[i], qname) = 0 THEN vi := i END;
    INC(i)
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
