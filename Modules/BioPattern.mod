MODULE BioPattern;
(*
  BioPattern — Exact and approximate pattern matching on BioSeq sequences.

  Algorithms:
    Boyer-Moore    — exact, O(n/m) average via bad-char + good-suffix tables
    KMP            — exact, O(n+m) via failure function
    Aho-Corasick   — multi-pattern exact, O(n + total_pattern_len + hits)
    Ukkonen        — approximate (edit distance), O(nm) DP

  All searches populate a caller-supplied HitList.
  Hit.pos is the 0-based start of the match in the text.
  Hit.dist is 0 for exact algorithms; edit distance for Ukkonen.

  NOTE: ACState is ~2 MB; declare it at module level, not as a local variable.
*)

IMPORT BioSeq, Strings;

CONST
  MaxHits*    = 65536;
  MaxACNodes* = 4096;
  MaxACPat*   = 64;

TYPE
  Hit* = RECORD
    pos*  : INTEGER;
    len*  : INTEGER;
    dist* : INTEGER
  END;

  HitList* = RECORD
    hits*  : ARRAY MaxHits OF Hit;
    count* : INTEGER
  END;

  BMState* = RECORD
    pattern*    : ARRAY 256 OF CHAR;
    patLen*     : INTEGER;
    badChar*    : ARRAY 128 OF INTEGER;
    goodSuffix* : ARRAY 256 OF INTEGER
  END;

  KMPState* = RECORD
    pattern* : ARRAY 256 OF CHAR;
    patLen*  : INTEGER;
    fail*    : ARRAY 256 OF INTEGER
  END;

  ACNode* = RECORD
    go*     : ARRAY 128 OF INTEGER;
    fail*   : INTEGER;
    output* : INTEGER
  END;

  ACState* = RECORD
    nodes*    : ARRAY MaxACNodes OF ACNode;
    nNodes*   : INTEGER;
    patterns* : ARRAY MaxACPat OF ARRAY 256 OF CHAR;
    nPat*     : INTEGER
  END;

(* ------------------------------------------------------------------ *)
(*  Boyer-Moore                                                         *)
(* ------------------------------------------------------------------ *)

PROCEDURE BMBuild*(VAR st: BMState; pat: ARRAY OF CHAR);
(* Precompute bad-character and good-suffix shift tables for pat. *)
VAR
  i, j, len : INTEGER;
  suf        : ARRAY 256 OF INTEGER;
BEGIN
  len := Strings.Length(pat);
  st.patLen := len;
  COPY(pat, st.pattern);

  FOR i := 0 TO 127 DO st.badChar[i] := -1 END;
  FOR i := 0 TO len - 1 DO
    IF (ORD(st.pattern[i]) >= 0) & (ORD(st.pattern[i]) < 128) THEN
      st.badChar[ORD(st.pattern[i])] := i
    END
  END;

  FOR i := 0 TO len DO st.goodSuffix[i] := len END;

  (* suf[i] = length of longest suffix of pat[0..i] that is also a suffix of pat *)
  FOR i := 0 TO len - 1 DO
    j := 0;
    WHILE (j <= i) & (st.pattern[i - j] = st.pattern[len - 1 - j]) DO INC(j) END;
    suf[i] := j
  END;

  (* Phase 1: prefix of pat that is also a suffix (border positions) *)
  FOR i := len - 1 TO 0 BY -1 DO
    IF suf[i] = i + 1 THEN
      j := 0;
      WHILE j < len - 1 - i DO
        IF st.goodSuffix[j] = len THEN st.goodSuffix[j] := len - 1 - i END;
        INC(j)
      END
    END
  END;

  (* Phase 2: rightmost occurrence of matched suffix elsewhere in pat *)
  FOR i := 0 TO len - 2 DO
    st.goodSuffix[len - 1 - suf[i]] := len - 1 - i
  END
END BMBuild;

PROCEDURE BMSearch*(VAR st: BMState; text: BioSeq.Seq; VAR hits: HitList);
VAR
  i, j, tLen, shift, bc, gs, co : INTEGER;
  c                               : CHAR;
BEGIN
  hits.count := 0;
  IF st.patLen = 0 THEN RETURN END;
  tLen := BioSeq.Length(text);
  i := 0;
  WHILE i <= tLen - st.patLen DO
    j := st.patLen - 1;
    WHILE (j >= 0) & (st.pattern[j] = BioSeq.Get(text, i + j)) DO DEC(j) END;
    IF j < 0 THEN
      IF hits.count < MaxHits THEN
        hits.hits[hits.count].pos  := i;
        hits.hits[hits.count].len  := st.patLen;
        hits.hits[hits.count].dist := 0;
        INC(hits.count)
      END;
      INC(i, st.goodSuffix[0])
    ELSE
      c  := BioSeq.Get(text, i + j);
      co := ORD(c);
      IF (co >= 0) & (co < 128) THEN bc := j - st.badChar[co]
      ELSE bc := j + 1
      END;
      gs := st.goodSuffix[j];
      IF bc > gs THEN shift := bc ELSE shift := gs END;
      IF shift < 1 THEN shift := 1 END;
      INC(i, shift)
    END
  END
END BMSearch;

(* ------------------------------------------------------------------ *)
(*  KMP                                                                 *)
(* ------------------------------------------------------------------ *)

PROCEDURE KMPBuild*(VAR st: KMPState; pat: ARRAY OF CHAR);
(* Compute KMP failure function for pat. *)
VAR i, j, len : INTEGER;
BEGIN
  len := Strings.Length(pat);
  st.patLen := len;
  COPY(pat, st.pattern);
  IF len = 0 THEN RETURN END;
  st.fail[0] := 0;
  j := 0;
  FOR i := 1 TO len - 1 DO
    WHILE (j > 0) & (pat[i] # pat[j]) DO j := st.fail[j - 1] END;
    IF pat[i] = pat[j] THEN INC(j) END;
    st.fail[i] := j
  END
END KMPBuild;

PROCEDURE KMPSearch*(VAR st: KMPState; text: BioSeq.Seq; VAR hits: HitList);
VAR i, j, tLen : INTEGER; c : CHAR;
BEGIN
  hits.count := 0;
  IF st.patLen = 0 THEN RETURN END;
  tLen := BioSeq.Length(text);
  j := 0;
  FOR i := 0 TO tLen - 1 DO
    c := BioSeq.Get(text, i);
    WHILE (j > 0) & (c # st.pattern[j]) DO j := st.fail[j - 1] END;
    IF c = st.pattern[j] THEN INC(j) END;
    IF j = st.patLen THEN
      IF hits.count < MaxHits THEN
        hits.hits[hits.count].pos  := i - st.patLen + 1;
        hits.hits[hits.count].len  := st.patLen;
        hits.hits[hits.count].dist := 0;
        INC(hits.count)
      END;
      j := st.fail[j - 1]
    END
  END
END KMPSearch;

(* ------------------------------------------------------------------ *)
(*  Aho-Corasick                                                        *)
(* ------------------------------------------------------------------ *)

PROCEDURE ACBuild*(VAR st: ACState);
(* Initialise an empty automaton (root = node 0). Call before ACAdd. *)
VAR c : INTEGER;
BEGIN
  st.nNodes := 1;
  st.nPat   := 0;
  FOR c := 0 TO 127 DO st.nodes[0].go[c] := -1 END;
  st.nodes[0].fail   := 0;
  st.nodes[0].output := -1
END ACBuild;

PROCEDURE ACAdd*(VAR st: ACState; pat: ARRAY OF CHAR);
(* Insert pat into the trie.  Call ACFinalize after all patterns are added. *)
VAR cur, next, c, len, i, j : INTEGER;
BEGIN
  IF (st.nNodes >= MaxACNodes) OR (st.nPat >= MaxACPat) THEN RETURN END;
  len := Strings.Length(pat);
  COPY(pat, st.patterns[st.nPat]);
  cur := 0;
  FOR i := 0 TO len - 1 DO
    c := ORD(pat[i]);
    IF (c >= 0) & (c < 128) THEN
      next := st.nodes[cur].go[c];
      IF next = -1 THEN
        next := st.nNodes;
        INC(st.nNodes);
        FOR j := 0 TO 127 DO st.nodes[next].go[j] := -1 END;
        st.nodes[next].fail   := 0;
        st.nodes[next].output := -1;
        st.nodes[cur].go[c]   := next
      END;
      cur := next
    END
  END;
  st.nodes[cur].output := st.nPat;
  INC(st.nPat)
END ACAdd;

PROCEDURE ACFinalize*(VAR st: ACState);
(*
  BFS to build failure links and compress the goto function so that
  every transition is non-negative — no -1 entries remain after this call.
*)
VAR
  q               : ARRAY MaxACNodes OF INTEGER;
  head, tail      : INTEGER;
  cur, next, c, fs : INTEGER;
BEGIN
  head := 0; tail := 0;
  FOR c := 0 TO 127 DO
    next := st.nodes[0].go[c];
    IF next = -1 THEN
      st.nodes[0].go[c] := 0          (* missing root transitions loop to root *)
    ELSE
      st.nodes[next].fail := 0;
      q[tail] := next; INC(tail)
    END
  END;
  WHILE head < tail DO
    cur := q[head]; INC(head);
    FOR c := 0 TO 127 DO
      next := st.nodes[cur].go[c];
      fs   := st.nodes[cur].fail;
      IF next = -1 THEN
        st.nodes[cur].go[c] := st.nodes[fs].go[c]   (* compressed goto *)
      ELSE
        st.nodes[next].fail := st.nodes[fs].go[c];
        q[tail] := next; INC(tail)
      END
    END
  END
END ACFinalize;

PROCEDURE ACSearch*(VAR st: ACState; text: BioSeq.Seq; VAR hits: HitList);
(*
  Multi-pattern search.  Call ACFinalize before this.
  Reports one hit per (end-position, pattern) pair; follows fail links
  to catch all patterns that match as suffixes at each text position.
*)
VAR
  i, state, s, tLen, patLen, co : INTEGER;
  c                               : CHAR;
BEGIN
  hits.count := 0;
  tLen  := BioSeq.Length(text);
  state := 0;
  FOR i := 0 TO tLen - 1 DO
    c  := BioSeq.Get(text, i);
    co := ORD(c);
    IF (co >= 0) & (co < 128) THEN
      state := st.nodes[state].go[co]
    ELSE
      state := 0
    END;
    s := state;
    WHILE s # 0 DO
      IF st.nodes[s].output # -1 THEN
        IF hits.count < MaxHits THEN
          patLen := Strings.Length(st.patterns[st.nodes[s].output]);
          hits.hits[hits.count].pos  := i - patLen + 1;
          hits.hits[hits.count].len  := patLen;
          hits.hits[hits.count].dist := 0;
          INC(hits.count)
        END
      END;
      s := st.nodes[s].fail
    END
  END
END ACSearch;

(* ------------------------------------------------------------------ *)
(*  Ukkonen approximate matching — semi-global edit-distance DP        *)
(* ------------------------------------------------------------------ *)

PROCEDURE Ukkonen*(pat: ARRAY OF CHAR; text: BioSeq.Seq; maxDist: INTEGER; VAR hits: HitList);
(*
  Find all positions in text where pat matches with at most maxDist
  edit operations (substitutions, insertions, deletions).
  Uses a two-row O(nm) DP; semi-global (free start in text).
  hit.pos is an estimate: end_pos - patLen + 1.
*)
VAR
  m, n, i, j              : INTEGER;
  diag, del, ins, best    : INTEGER;
  ch                      : CHAR;
  dpPrev, dpCurr          : ARRAY 256 OF INTEGER;
BEGIN
  hits.count := 0;
  m := Strings.Length(pat);
  n := BioSeq.Length(text);
  IF (m = 0) OR (maxDist < 0) THEN RETURN END;

  (* First column: matching pat[0..j-1] against an empty text prefix = j insertions *)
  FOR j := 0 TO m DO dpPrev[j] := j END;

  FOR i := 0 TO n - 1 DO
    ch := BioSeq.Get(text, i);
    dpCurr[0] := 0;    (* free start anywhere in text *)
    FOR j := 1 TO m DO
      diag := dpPrev[j - 1];
      IF pat[j - 1] # ch THEN INC(diag) END;
      del  := dpPrev[j] + 1;
      ins  := dpCurr[j - 1] + 1;
      IF diag <= del THEN best := diag ELSE best := del END;
      IF ins < best  THEN best := ins END;
      dpCurr[j] := best
    END;
    IF (dpCurr[m] <= maxDist) & (i - m + 1 >= 0) THEN
      IF hits.count < MaxHits THEN
        hits.hits[hits.count].pos  := i - m + 1;
        hits.hits[hits.count].len  := m;
        hits.hits[hits.count].dist := dpCurr[m];
        INC(hits.count)
      END
    END;
    FOR j := 0 TO m DO dpPrev[j] := dpCurr[j] END
  END
END Ukkonen;

END BioPattern.
