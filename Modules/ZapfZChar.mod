MODULE ZapfZChar;
(*
  ZapfZChar — Z-machine text (Z-character) encoder, ported from
  Zilf.Common.StringEncoding.{StringEncoder,Horspool,UnicodeTranslation} (C#).

  Module-level (singleton) state, since zapf only ever needs one encoder
  for the whole assembly run; Init resets it (called once at startup, and
  again at the top of each measuring pass, matching Context.ResetBetweenPasses
  doing `StringEncoder = new StringEncoder()`).

  Includes abbreviation substitution (Horspool search + Wagner's optimal-
  parse DP), since ZILF-generated .zap for a full-size game relies on
  .FSTR abbreviations to fit under the platform's file-size limit -- without
  it, some real games would fail to assemble at all, not just produce a
  larger-than-necessary file.

  Input strings are read as raw bytes by the tokenizer (see ZapfTok), so a
  UTF-8 multi-byte sequence appears as consecutive CHAR values here. This
  module decodes 2-byte UTF-8 sequences (covering the Latin-1 Supplement
  range used by the original's default accented-character table) back into
  a codepoint before doing the ZSCII lookup; anything wider than 2 bytes
  falls back to passing the raw byte through unchanged (matches the
  original's fallback for an unmapped character, `zscii := ORD(c)`).
  Abbreviation patterns are matched against decoded codepoints too, which
  works for the plain-ASCII patterns .FSTR abbreviations actually use.
*)

IMPORT Strings;

CONST
  ModeNormal* = 0;
  ModeNoAbbrev* = 1;

  MaxTemp = 8192;
  MaxAbbrevs* = 96;
  MaxAbbrevLen = 256;

  (* ---- abbreviation FINDER (frequency analysis over the whole corpus of
     strings a game will print) ---- these bounds are separate from the
     encoder's own MaxAbbrevs/MaxAbbrevLen above, which apply to whatever
     the finder (or a hand-written .FSTR) actually registers. *)
  MaxCorpus = 600000;        (* total corpus characters, incl. 1 separator/string *)
  MinCandLen = 2;
  MaxCandLen = 14;           (* longest abbreviation candidate considered *)
  CompareDepth = MaxCandLen + 4;
  MaxTopCandidates = 4 * MaxAbbrevs;
  Boundary = 1X;             (* separates accumulated strings; never real text *)

TYPE
  (* Named fixed-size type, not an inline `ARRAY OF ARRAY OF CHAR` parameter
     — this dialect silently degrades that to a single CHAR per element
     (see ZilCompile.mod's LineText/ArgList comment for the same gotcha). *)
  AbbrevTextArr* = ARRAY MaxAbbrevs OF ARRAY MaxCandLen + 1 OF CHAR;

VAR
  charset0, charset1: ARRAY 26 OF INTEGER;
  charset2: ARRAY 26 OF INTEGER;
  n2: INTEGER;

  ucChars, ucZscii: ARRAY 80 OF INTEGER;
  ucCount: INTEGER;

  customUnicode: BOOLEAN;
  customChars, customZscii: ARRAY 97 OF INTEGER;
  customCount: INTEGER;

  abbrevText: ARRAY MaxAbbrevs, MaxAbbrevLen OF CHAR;
  abbrevLen: ARRAY MaxAbbrevs OF INTEGER;
  abbrevNum: ARRAY MaxAbbrevs OF INTEGER;
  abbrevSkip: ARRAY MaxAbbrevs, 256 OF INTEGER;
  abbrevCount*: INTEGER;
  frozen*: BOOLEAN;

  corpus: ARRAY MaxCorpus OF CHAR;
  corpusLen: INTEGER;
  suffPos: ARRAY MaxCorpus OF INTEGER;

  candText: ARRAY MaxTopCandidates OF ARRAY MaxCandLen + 1 OF CHAR;
  candScore: ARRAY MaxTopCandidates OF INTEGER;
  nCand: INTEGER;

PROCEDURE ResetAbbrevs*;
BEGIN
  abbrevCount := 0;
  frozen := FALSE
END ResetAbbrevs;

PROCEDURE ResetUnicodeTable*;
BEGIN
  customUnicode := FALSE;
  customCount := 0
END ResetUnicodeTable;

PROCEDURE StartCustomUnicodeTable*;
BEGIN
  customUnicode := TRUE;
  customCount := 0
END StartCustomUnicodeTable;

PROCEDURE AddUnicodeMapping*(codepoint, indexZeroBased: INTEGER);
BEGIN
  IF ~customUnicode THEN StartCustomUnicodeTable END;
  IF customCount < LEN(customChars) THEN
    customChars[customCount] := codepoint;
    customZscii[customCount] := 155 + indexZeroBased;
    INC(customCount)
  END
END AddUnicodeMapping;

PROCEDURE AddUC(c, z: INTEGER);
BEGIN ucChars[ucCount] := c; ucZscii[ucCount] := z; INC(ucCount) END AddUC;

PROCEDURE Init*;
  VAR i: INTEGER;
BEGIN
  FOR i := 0 TO 25 DO charset0[i] := ORD("a") + i END;
  FOR i := 0 TO 25 DO charset1[i] := ORD("A") + i END;

  (* default alphabet-2 punctuation row: 0-9 . , ! ? _ # ' " / \ - : ( )   (24 chars) *)
  n2 := 24;
  FOR i := 0 TO 9 DO charset2[i] := ORD("0") + i END;
  charset2[10] := 46;  (* . *)
  charset2[11] := 44;  (* , *)
  charset2[12] := 33;  (* ! *)
  charset2[13] := 63;  (* ? *)
  charset2[14] := 95;  (* _ *)
  charset2[15] := 35;  (* # *)
  charset2[16] := 39;  (* ' *)
  charset2[17] := 34;  (* " *)
  charset2[18] := 47;  (* / *)
  charset2[19] := 92;  (* \ *)
  charset2[20] := 45;  (* - *)
  charset2[21] := 58;  (* : *)
  charset2[22] := 40;  (* ( *)
  charset2[23] := 41;  (* ) *)

  (* default extended (accented) character table -> ZSCII 155..223, matching
     UnicodeTranslation.MakeDefaultUnicodeTable's SExtraChars string exactly *)
  ucCount := 0;
  AddUC(228, 155); (* a-umlaut *)
  AddUC(246, 156); (* o-umlaut *)
  AddUC(252, 157); (* u-umlaut *)
  AddUC(196, 158); (* A-umlaut *)
  AddUC(214, 159); (* O-umlaut *)
  AddUC(220, 160); (* U-umlaut *)
  AddUC(223, 161); (* sharp s *)
  AddUC(187, 162); (* right guillemet *)
  AddUC(171, 163); (* left guillemet *)
  AddUC(235, 164); (* e-umlaut *)
  AddUC(239, 165); (* i-umlaut *)
  AddUC(255, 166); (* y-umlaut *)
  AddUC(203, 167); (* E-umlaut *)
  AddUC(207, 168); (* I-umlaut *)
  AddUC(225, 169); (* a-acute *)
  AddUC(233, 170); (* e-acute *)
  AddUC(237, 171); (* i-acute *)
  AddUC(243, 172); (* o-acute *)
  AddUC(250, 173); (* u-acute *)
  AddUC(253, 174); (* y-acute *)
  AddUC(193, 175); (* A-acute *)
  AddUC(201, 176); (* E-acute *)
  AddUC(205, 177); (* I-acute *)
  AddUC(211, 178); (* O-acute *)
  AddUC(218, 179); (* U-acute *)
  AddUC(221, 180); (* Y-acute *)
  AddUC(224, 181); (* a-grave *)
  AddUC(232, 182); (* e-grave *)
  AddUC(236, 183); (* i-grave *)
  AddUC(242, 184); (* o-grave *)
  AddUC(249, 185); (* u-grave *)
  AddUC(192, 186); (* A-grave *)
  AddUC(200, 187); (* E-grave *)
  AddUC(204, 188); (* I-grave *)
  AddUC(210, 189); (* O-grave *)
  AddUC(217, 190); (* U-grave *)
  AddUC(226, 191); (* a-circumflex *)
  AddUC(234, 192); (* e-circumflex *)
  AddUC(238, 193); (* i-circumflex *)
  AddUC(244, 194); (* o-circumflex *)
  AddUC(251, 195); (* u-circumflex *)
  AddUC(194, 196); (* A-circumflex *)
  AddUC(202, 197); (* E-circumflex *)
  AddUC(206, 198); (* I-circumflex *)
  AddUC(212, 199); (* O-circumflex *)
  AddUC(219, 200); (* U-circumflex *)
  AddUC(229, 201); (* a-ring *)
  AddUC(197, 202); (* A-ring *)
  AddUC(248, 203); (* o-slash *)
  AddUC(216, 204); (* O-slash *)
  AddUC(227, 205); (* a-tilde *)
  AddUC(241, 206); (* n-tilde *)
  AddUC(245, 207); (* o-tilde *)
  AddUC(195, 208); (* A-tilde *)
  AddUC(209, 209); (* N-tilde *)
  AddUC(213, 210); (* O-tilde *)
  AddUC(230, 211); (* ae *)
  AddUC(198, 212); (* AE *)
  AddUC(231, 213); (* c-cedilla *)
  AddUC(199, 214); (* C-cedilla *)
  AddUC(254, 215); (* thorn *)
  AddUC(240, 216); (* eth *)
  AddUC(222, 217); (* THORN *)
  AddUC(208, 218); (* ETH *)
  AddUC(163, 219); (* pound sign *)
  AddUC(339, 220); (* oe ligature (U+0153) *)
  AddUC(338, 221); (* OE ligature (U+0152) *)
  AddUC(161, 222); (* inverted exclamation *)
  AddUC(191, 223); (* inverted question *)

  ResetUnicodeTable;

  ResetAbbrevs
END Init;

PROCEDURE FindInt(VAR arr: ARRAY OF INTEGER; n, v: INTEGER): INTEGER;
  VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (i < n) & (arr[i] # v) DO INC(i) END;
  IF i < n THEN RETURN i ELSE RETURN -1 END
END FindInt;

PROCEDURE TryGetZscii(cp: INTEGER; VAR z: INTEGER): BOOLEAN;
  VAR idx: INTEGER;
BEGIN
  IF customUnicode THEN
    idx := FindInt(customChars, customCount, cp);
    IF idx >= 0 THEN z := customZscii[idx]; RETURN TRUE END;
    IF cp > 127 THEN RETURN FALSE END;
    z := cp; RETURN TRUE
  ELSE
    idx := FindInt(ucChars, ucCount, cp);
    IF idx >= 0 THEN z := ucZscii[idx]; RETURN TRUE END;
    z := cp MOD 256; RETURN TRUE
  END
END TryGetZscii;

(* Decode one Unicode codepoint from s starting at index i (0-based);
   advances i past the bytes consumed. Handles ASCII and 2-byte UTF-8;
   anything else (3+ byte sequences, stray continuation bytes) is passed
   through as its raw byte value. *)
PROCEDURE DecodeNext(s: ARRAY OF CHAR; slen: INTEGER; VAR i: INTEGER): INTEGER;
  VAR b0, b1, cp: INTEGER;
BEGIN
  b0 := ORD(s[i]);
  IF b0 < 128 THEN
    INC(i); RETURN b0
  ELSIF (b0 >= 0C2H) & (b0 <= 0DFH) & (i + 1 < slen) THEN
    b1 := ORD(s[i + 1]);
    IF (b1 >= 080H) & (b1 <= 0BFH) THEN
      cp := (b0 - 0C0H) * 64 + (b1 - 080H);
      i := i + 2;
      RETURN cp
    ELSE
      INC(i); RETURN b0
    END
  ELSE
    INC(i); RETURN b0
  END
END DecodeNext;

PROCEDURE DecodeAll(s: ARRAY OF CHAR; slen: INTEGER; VAR cps: ARRAY OF INTEGER; VAR n: INTEGER);
  VAR i: INTEGER;
BEGIN
  n := 0; i := 0;
  WHILE (i < slen) & (n < MaxTemp) DO
    cps[n] := DecodeNext(s, slen, i);
    INC(n)
  END
END DecodeAll;

PROCEDURE SetCharset*(csNum: INTEGER; chars: ARRAY OF INTEGER; nChars: INTEGER);
  VAR pad, i, j: INTEGER; tmp: ARRAY 26 OF INTEGER;
BEGIN
  pad := 26 - nChars;
  IF csNum = 2 THEN pad := pad - 2 END;
  IF pad < 0 THEN pad := 0 END;
  FOR i := 0 TO pad - 1 DO tmp[i] := ORD(" ") END;
  j := pad;
  FOR i := 0 TO nChars - 1 DO
    IF j < 26 THEN tmp[j] := chars[i]; INC(j) END
  END;
  WHILE j < 26 DO tmp[j] := ORD(" "); INC(j) END;
  IF csNum = 0 THEN
    FOR i := 0 TO 25 DO charset0[i] := tmp[i] END
  ELSIF csNum = 1 THEN
    FOR i := 0 TO 25 DO charset1[i] := tmp[i] END
  ELSE
    FOR i := 0 TO 25 DO charset2[i] := tmp[i] END;
    n2 := 26
  END
END SetCharset;

(* ---- abbreviations ---- *)

(* Longest-first, then lexical: abbreviations must be tried longest-first
   when matching, exactly like the original's AbbrevComparer. *)
PROCEDURE AddAbbreviation*(text: ARRAY OF CHAR): BOOLEAN;
  VAR n, last, i, j: INTEGER; longer: BOOLEAN;
BEGIN
  IF frozen THEN RETURN FALSE END;
  IF abbrevCount >= MaxAbbrevs THEN RETURN FALSE END;
  n := Strings.Length(text);
  IF n >= MaxAbbrevLen THEN n := MaxAbbrevLen - 1 END;

  j := abbrevCount;
  WHILE (j > 0) & ((abbrevLen[j-1] < n) OR
        ((abbrevLen[j-1] = n) & (Strings.Compare(abbrevText[j-1], text) > 0))) DO
    abbrevText[j] := abbrevText[j-1];
    abbrevLen[j] := abbrevLen[j-1];
    abbrevNum[j] := abbrevNum[j-1];
    FOR i := 0 TO 255 DO abbrevSkip[j][i] := abbrevSkip[j-1][i] END;
    DEC(j)
  END;

  Strings.Copy(text, abbrevText[j]);
  abbrevLen[j] := n;
  abbrevNum[j] := abbrevCount;
  last := n - 1;
  FOR i := 0 TO 255 DO abbrevSkip[j][i] := n END;
  FOR i := 0 TO last - 1 DO abbrevSkip[j][ORD(text[i])] := last - i END;

  INC(abbrevCount);
  RETURN TRUE
END AddAbbreviation;

(* Horspool search for abbreviation `a` within cps[0..clen-1], starting at
   or after `from`; returns the match index, or -1. *)
PROCEDURE FindAbbrevAt(a: INTEGER; VAR cps: ARRAY OF INTEGER; clen, from: INTEGER): INTEGER;
  VAR hstart, hlen, nlen, last, i, sc: INTEGER; matched: BOOLEAN;
BEGIN
  nlen := abbrevLen[a];
  last := nlen - 1;
  hstart := from;
  hlen := clen - from;
  WHILE hlen >= nlen DO
    i := last;
    matched := TRUE;
    WHILE matched & (i >= 0) DO
      IF (cps[hstart+i] < 0) OR (cps[hstart+i] > 255) OR (CHR(cps[hstart+i]) # abbrevText[a][i]) THEN
        matched := FALSE
      ELSE
        DEC(i)
      END
    END;
    IF matched THEN RETURN hstart END;
    sc := cps[hstart+last];
    IF (sc < 0) OR (sc > 255) THEN sc := 0 END;
    hlen := hlen - abbrevSkip[a][sc];
    hstart := hstart + abbrevSkip[a][sc]
  END;
  RETURN -1
END FindAbbrevAt;

PROCEDURE CharCost(cp: INTEGER): INTEGER;
  VAR z: INTEGER;
BEGIN
  IF cp = ORD(" ") THEN RETURN 1 END;
  IF cp = 10 THEN RETURN 2 END;
  IF ~TryGetZscii(cp, z) THEN RETURN 4 END;
  IF FindInt(charset0, 26, z) >= 0 THEN RETURN 1 END;
  IF (FindInt(charset1, 26, z) >= 0) OR (FindInt(charset2, n2, z) >= 0) THEN RETURN 2 END;
  RETURN 4
END CharCost;

(* Wagner's optimal parse: rewrites cps[0..n-1] in place, replacing each
   chosen abbreviation occurrence with a single sentinel code
   0E000H + abbrevNum. *)
PROCEDURE Abbreviate(VAR cps: ARRAY OF INTEGER; VAR n: INTEGER);
  VAR
    minCost: ARRAY MaxTemp + 1 OF INTEGER;
    chosen: ARRAY MaxTemp OF INTEGER;
    outCp: ARRAY MaxTemp OF INTEGER;
    idx, i, abbrLen, costWith, found, outN, srcIdx: INTEGER;
BEGIN
  minCost[n] := 0;
  FOR idx := n - 1 TO 0 BY -1 DO
    minCost[idx] := minCost[idx+1] + CharCost(cps[idx]);
    chosen[idx] := -1;
    FOR i := 0 TO abbrevCount - 1 DO
      IF idx + abbrevLen[i] <= n THEN
        found := FindAbbrevAt(i, cps, idx + abbrevLen[i], idx);
        IF found = idx THEN
          abbrLen := abbrevLen[i];
          costWith := 2 + minCost[idx + abbrLen];
          IF costWith < minCost[idx] THEN
            chosen[idx] := i;
            minCost[idx] := costWith
          END
        END
      END
    END
  END;

  outN := 0;
  srcIdx := 0;
  WHILE srcIdx < n DO
    IF chosen[srcIdx] = -1 THEN
      outCp[outN] := cps[srcIdx]; INC(outN); INC(srcIdx)
    ELSE
      outCp[outN] := 0E000H + abbrevNum[chosen[srcIdx]]; INC(outN);
      srcIdx := srcIdx + abbrevLen[chosen[srcIdx]]
    END
  END;

  FOR i := 0 TO outN - 1 DO cps[i] := outCp[i] END;
  n := outN
END Abbreviate;

(* ---- abbreviation FINDER ----

   A from-scratch, self-contained frequency analysis choosing which
   substrings to register as .FSTR abbreviations, since without it the
   machinery above never gets anything to work with. Not a port of the
   original's AbbrevFinder/IndexedStringCollection (a full generalized
   suffix-array with LCP-based substring enumeration and an overlap-aware
   selection pass) - that is a lot more machinery than a "pragmatic subset"
   needs. Instead: concatenate every string the game will print into one
   corpus (with a separator between strings so a candidate can never span
   two of them), sort every starting position by its leading characters (a
   poor man's suffix array - one sort serves every candidate length, since
   positions sharing an L-character prefix end up contiguous in it for
   every L), and for each candidate length scan that sorted order for runs
   of matching positions, scoring each run with the original's own
   formula (`(count-1)*(cost-2) - 2`, cost in the SAME z-char units
   CharCost already computes for real encoding) so a candidate only
   survives if replacing it with a 2-z-char abbreviation reference
   actually saves space. The result isn't the original's OPTIMAL abbreviation
   set, just a good one - real games "fit or don't" on total byte count, and
   this is a self-contained, testable piece of that rather than a byte-exact
   port. *)

PROCEDURE ResetCorpus*;
BEGIN corpusLen := 0 END ResetCorpus;

(* Accumulates one more string's text into the corpus, terminated by a
   separator so no candidate can span into the next string added. Silently
   stops accumulating once the corpus is full (best-effort: a huge game
   still assembles, it just stops gaining new abbreviation candidates from
   whatever text didn't fit). *)
PROCEDURE AddCorpusText*(text: ARRAY OF CHAR);
VAR i, n: INTEGER;
BEGIN
  n := Strings.Length(text);
  IF corpusLen + n + 1 >= MaxCorpus THEN RETURN END;
  FOR i := 0 TO n - 1 DO corpus[corpusLen] := text[i]; INC(corpusLen) END;
  corpus[corpusLen] := Boundary; INC(corpusLen)
END AddCorpusText;

(* Lexical compare of the corpus starting at a vs at b, up to CompareDepth
   characters (more than MaxCandLen, so every candidate length's prefix is
   fully decided within that depth) or the corpus end, whichever is first.
   Past the corpus end reads as 0X, which sorts below every real character
   and below Boundary too (0X < 1X), so a short suffix near the very end of
   the corpus still sorts consistently instead of reading out of bounds. *)
PROCEDURE ComparePos(a, b: INTEGER): INTEGER;
VAR i: INTEGER; ca, cb: CHAR;
BEGIN
  FOR i := 0 TO CompareDepth - 1 DO
    IF a + i < corpusLen THEN ca := corpus[a + i] ELSE ca := 0X END;
    IF b + i < corpusLen THEN cb := corpus[b + i] ELSE cb := 0X END;
    IF ca # cb THEN
      IF ca < cb THEN RETURN -1 ELSE RETURN 1 END
    END
  END;
  RETURN 0
END ComparePos;

(* Hoare-partition quicksort of suffPos[lo..hi] by ComparePos. Corpus text
   is natural-language prose, not adversarial input, so the classic
   worst case (already-sorted input driving a fixed first/last-element
   pivot to quadratic behaviour) isn't a real concern here - median-of-
   three would guard against it too, but isn't needed for this input. *)
PROCEDURE QSort(lo, hi: INTEGER);
VAR i, j, pivot, tmp: INTEGER;
BEGIN
  IF lo >= hi THEN RETURN END;
  i := lo; j := hi;
  pivot := suffPos[(lo + hi) DIV 2];
  WHILE i <= j DO
    WHILE ComparePos(suffPos[i], pivot) < 0 DO INC(i) END;
    WHILE ComparePos(suffPos[j], pivot) > 0 DO DEC(j) END;
    IF i <= j THEN
      tmp := suffPos[i]; suffPos[i] := suffPos[j]; suffPos[j] := tmp;
      INC(i); DEC(j)
    END
  END;
  IF lo < j THEN QSort(lo, j) END;
  IF i < hi THEN QSort(i, hi) END
END QSort;

(* Do positions a and b share the same L-character prefix? *)
PROCEDURE SamePrefix(a, b, l: INTEGER): BOOLEAN;
VAR i: INTEGER;
BEGIN
  IF (a + l > corpusLen) OR (b + l > corpusLen) THEN RETURN FALSE END;
  i := 0;
  WHILE (i < l) & (corpus[a + i] = corpus[b + i]) DO INC(i) END;
  RETURN i = l
END SamePrefix;

(* An L-character run starting at `pos` is only a real candidate if it
   doesn't cross a separator - otherwise it isn't text that ever actually
   appears together in any one string. *)
PROCEDURE ValidCandidate(pos, l: INTEGER): BOOLEAN;
VAR i: INTEGER;
BEGIN
  IF pos + l > corpusLen THEN RETURN FALSE END;
  FOR i := 0 TO l - 1 DO
    IF corpus[pos + i] = Boundary THEN RETURN FALSE END
  END;
  RETURN TRUE
END ValidCandidate;

(* Cost of encoding text[0..l-1] as ordinary z-chars, in the same units
   CharCost already uses for real encoding (1/2/4 per character depending
   on which alphabet, if any, it falls in). Treats each CHAR as its own
   codepoint - true for the plain-ASCII prose these candidates are drawn
   from, matching CharCost's own real-encoding behavior for that text. *)
PROCEDURE CandidateCost(pos, l: INTEGER): INTEGER;
VAR i, cost: INTEGER;
BEGIN
  cost := 0;
  FOR i := 0 TO l - 1 DO cost := cost + CharCost(ORD(corpus[pos + i])) END;
  RETURN cost
END CandidateCost;

(* Keeps the MaxTopCandidates best-scoring candidates seen so far, sorted
   descending by score (an insertion sort over a bounded array - cheap
   since MaxTopCandidates is small and this is only called once per
   surviving (length, run) pair, not per corpus position). *)
PROCEDURE InsertCandidate(text: ARRAY OF CHAR; score: INTEGER);
VAR i: INTEGER;
BEGIN
  IF (nCand >= MaxTopCandidates) & (score <= candScore[MaxTopCandidates - 1]) THEN RETURN END;
  IF nCand < MaxTopCandidates THEN i := nCand; INC(nCand) ELSE i := MaxTopCandidates - 1 END;
  WHILE (i > 0) & (candScore[i - 1] < score) DO
    candScore[i] := candScore[i - 1];
    Strings.Copy(candText[i - 1], candText[i]);
    DEC(i)
  END;
  candScore[i] := score;
  Strings.Copy(text, candText[i])
END InsertCandidate;

(* Does `big` contain `small` anywhere? Both are short (<= MaxCandLen), so
   the naive O(|big|*|small|) search is plenty fast for the handful of
   candidates this gets called on (see FindAbbreviations's own overlap
   check below). *)
PROCEDURE ContainsSub(big, small: ARRAY OF CHAR): BOOLEAN;
VAR bl, sl, i, j: INTEGER; matched: BOOLEAN;
BEGIN
  bl := Strings.Length(big); sl := Strings.Length(small);
  IF sl > bl THEN RETURN FALSE END;
  FOR i := 0 TO bl - sl DO
    matched := TRUE; j := 0;
    WHILE matched & (j < sl) DO
      IF big[i + j] # small[j] THEN matched := FALSE END;
      INC(j)
    END;
    IF matched THEN RETURN TRUE END
  END;
  RETURN FALSE
END ContainsSub;

(* Runs the frequency analysis over whatever text AddCorpusText has
   accumulated and returns up to `maxCount` candidate abbreviation texts in
   outText[0..outCount-1], best (highest-scoring) first. Pure analysis: does
   not touch abbrevCount/frozen or call AddAbbreviation itself, so the
   caller decides how (and whether) to actually register and emit each one
   - this module has no notion of the .zap source lines / global symbols
   that requires. *)
PROCEDURE FindAbbreviations*(maxCount: INTEGER; VAR outText: AbbrevTextArr; VAR outCount: INTEGER);
VAR i, j, l, run, cost, score: INTEGER; redundant: BOOLEAN; buf: ARRAY MaxCandLen + 1 OF CHAR;
BEGIN
  nCand := 0;
  outCount := 0;
  IF corpusLen = 0 THEN RETURN END;

  FOR i := 0 TO corpusLen - 1 DO suffPos[i] := i END;
  QSort(0, corpusLen - 1);

  FOR l := MinCandLen TO MaxCandLen DO
    i := 0;
    WHILE i < corpusLen DO
      j := i + 1;
      WHILE (j < corpusLen) & SamePrefix(suffPos[i], suffPos[j], l) DO INC(j) END;
      run := j - i;
      IF (run >= 2) & ValidCandidate(suffPos[i], l) THEN
        cost := CandidateCost(suffPos[i], l);
        score := (run - 1) * (cost - 2) - 2;
        IF score >= 1 THEN
          FOR j := 0 TO l - 1 DO buf[j] := corpus[suffPos[i] + j] END;
          buf[l] := 0X;
          InsertCandidate(buf, score)
        END
      END;
      i := j
    END
  END;

  (* Greedy overlap elimination: highest-scoring candidates first (candText
     is already sorted that way), skipping any candidate that is a
     substring of - or a superstring containing - an ALREADY-chosen one.
     Without this, the top of the list is dominated by near-duplicates of
     the single best pattern (e.g. "the", " the", "the ", " the ", "he ",
     " th" all scoring well independently), burning many of the scarce 96
     table slots on trivial variations of ONE idea instead of covering 96
     DIFFERENT ones - confirmed against a real zilf build's own choices for
     the same game, which are far more varied. Wagner's DP in Abbreviate
     would still work fine without this (it just picks whichever abbrev
     fits best at each position), so this is purely about spending the
     limited table well, not correctness. *)
  i := 0;
  WHILE (i < nCand) & (outCount < maxCount) & (outCount < LEN(outText)) DO
    redundant := FALSE;
    j := 0;
    WHILE (j < outCount) & ~redundant DO
      IF ContainsSub(candText[i], outText[j]) OR ContainsSub(outText[j], candText[i]) THEN
        redundant := TRUE
      END;
      INC(j)
    END;
    IF ~redundant THEN
      Strings.Copy(candText[i], outText[outCount]);
      INC(outCount)
    END;
    INC(i)
  END
END FindAbbreviations;

(* Emits 5-bit z-char codes for the (possibly abbreviated) codepoint
   stream cps[0..n-1] into temp[0..*], returning the count. *)
PROCEDURE EmitZChars(VAR cps: ARRAY OF INTEGER; n: INTEGER; noAbbrevs: BOOLEAN; VAR temp: ARRAY OF INTEGER; VAR nzc: INTEGER);
  VAR i, cp, zscii, idx: INTEGER;
BEGIN
  nzc := 0; i := 0;
  WHILE i < n DO
    cp := cps[i];
    IF cp = ORD(" ") THEN
      temp[nzc] := 0; INC(nzc)
    ELSIF cp = 10 THEN
      temp[nzc] := 5; temp[nzc+1] := 7; nzc := nzc + 2
    ELSIF (~noAbbrevs) & (cp >= 0E000H) & (cp < 0E060H) THEN
      temp[nzc] := 1 + (cp - 0E000H) DIV 32;
      temp[nzc+1] := (cp - 0E000H) MOD 32;
      nzc := nzc + 2
    ELSE
      IF ~TryGetZscii(cp, zscii) THEN zscii := ORD("?") END;
      idx := FindInt(charset0, 26, zscii);
      IF idx >= 0 THEN
        temp[nzc] := idx + 6; INC(nzc)
      ELSE
        idx := FindInt(charset1, 26, zscii);
        IF idx >= 0 THEN
          temp[nzc] := 4; temp[nzc+1] := idx + 6; nzc := nzc + 2
        ELSE
          idx := FindInt(charset2, n2, zscii);
          IF idx >= 0 THEN
            temp[nzc] := 5; temp[nzc+1] := idx + 8; nzc := nzc + 2
          ELSE
            temp[nzc] := 5; temp[nzc+1] := 6;
            temp[nzc+2] := (zscii DIV 32) MOD 32;
            temp[nzc+3] := zscii MOD 32;
            nzc := nzc + 4
          END
        END
      END
    END;
    INC(i);
    IF nzc > MaxTemp - 8 THEN i := n END  (* safety cutoff on pathological input *)
  END
END EmitZChars;

(* Encodes s.  mode = ModeNoAbbrev skips abbreviation substitution (used
   when encoding an abbreviation's own definition text) and treats
   0xE000-range codepoints as ordinary characters rather than abbreviation
   references. hasSize/size: FALSE produces the natural (padded to a
   multiple of 3 z-chars) length; TRUE pads/truncates to exactly `size`
   z-chars (dictionary-word semantics: longer input is silently
   truncated). outBuf receives outLen bytes (always even); zchars receives
   the z-character count before padding (used by .LEN). *)
PROCEDURE Encode*(s: ARRAY OF CHAR; mode: INTEGER; hasSize: BOOLEAN; size: INTEGER;
                   VAR outBuf: ARRAY OF INTEGER; VAR outLen: INTEGER; VAR zchars: INTEGER);
  VAR
    cps: ARRAY MaxTemp OF INTEGER;
    temp: ARRAY MaxTemp OF INTEGER;
    ncp, n, resultSize, finalLen, i, t, a, b, c, word: INTEGER;
    noAbbrevs: BOOLEAN;
BEGIN
  noAbbrevs := mode = ModeNoAbbrev;
  IF ~noAbbrevs THEN frozen := TRUE END;

  DecodeAll(s, Strings.Length(s), cps, ncp);
  IF ~noAbbrevs THEN Abbreviate(cps, ncp) END;
  EmitZChars(cps, ncp, noAbbrevs, temp, n);
  zchars := n;

  IF ~hasSize THEN
    IF n = 0 THEN temp[n] := 5; INC(n) END;
    WHILE n MOD 3 # 0 DO temp[n] := 5; INC(n) END;
    resultSize := (n * 2) DIV 3
  ELSE
    WHILE n < size DO temp[n] := 5; INC(n) END;
    resultSize := (size * 2) DIV 3
  END;
  finalLen := resultSize;
  IF (n * 2) DIV 3 < finalLen THEN finalLen := (n * 2) DIV 3 END;

  i := 0; t := 0;
  WHILE i < finalLen DO
    a := temp[t]; b := temp[t+1]; c := temp[t+2]; t := t + 3;
    word := a * 1024 + b * 32 + c;
    outBuf[i] := word DIV 256; INC(i);
    outBuf[i] := word MOD 256; INC(i)
  END;
  IF finalLen >= 2 THEN
    IF outBuf[finalLen - 2] < 128 THEN outBuf[finalLen - 2] := outBuf[finalLen - 2] + 128 END
  END;
  outLen := finalLen
END Encode;

END ZapfZChar.
