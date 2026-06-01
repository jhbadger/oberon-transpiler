MODULE BioSeq;
IMPORT BioAlpha, Out;
(*
  BioSeq — Long biological sequence storage via a singly-linked chunk list.

  Sequences longer than 256 bytes cannot fit in a single Oberon STRING.
  Each Seq is a heap-allocated linked list of Chunk nodes, each holding
  up to ChunkSize characters.  The tail pointer gives O(1) append.

  All positions are 0-based.
  Procedures that write into caller-supplied buffers always null-terminate
  and never write beyond LEN(buf)-1 characters.
*)

CONST
ChunkSize* = 240;

TYPE
ChunkPtr* = POINTER TO Chunk;
Chunk = RECORD
  data : ARRAY ChunkSize OF CHAR;
  len  : INTEGER;
  next : ChunkPtr
END;

Seq* = POINTER TO SeqRec;
SeqRec* = RECORD
  head    : ChunkPtr;
  tail    : ChunkPtr;
  length* : INTEGER;
  name*   : ARRAY 128 OF CHAR
END;

(* ------------------------------------------------------------------ *)
(*  Internal helpers                                                    *)
(* ------------------------------------------------------------------ *)

PROCEDURE ClearChunks(s: Seq);
(* Free all chunks and reset the sequence to empty (header kept). *)
VAR c, nx: ChunkPtr;
BEGIN
  c := s.head;
  WHILE c # NIL DO nx := c.next; FREE(c); c := nx END;
  s.head := NIL; s.tail := NIL; s.length := 0
END ClearChunks;

(* ------------------------------------------------------------------ *)
(*  Lifecycle                                                           *)
(* ------------------------------------------------------------------ *)

PROCEDURE New*(VAR s: Seq);
(* Allocate a fresh empty sequence. *)
BEGIN
  NEW(s);
  s.head    := NIL;
  s.tail    := NIL;
  s.length  := 0;
  s.name[0] := 0X
END New;

PROCEDURE Free*(VAR s: Seq);
(* Release all chunks and the sequence header. *)
BEGIN
  IF s = NIL THEN RETURN END;
  ClearChunks(s);
  FREE(s)
END Free;

(* ------------------------------------------------------------------ *)
(*  Building sequences                                                  *)
(* ------------------------------------------------------------------ *)

PROCEDURE Append*(s: Seq; buf: ARRAY OF CHAR; n: INTEGER);
(*
    Append exactly n characters from buf to s.
    n is clamped to LEN(buf) to prevent overread.
    Splits across chunk boundaries automatically.
  *)
VAR c: ChunkPtr; i, room, take: INTEGER;
BEGIN
  IF n > LEN(buf) THEN n := LEN(buf) END;
  IF n <= 0 THEN RETURN END;
  i := 0;
  WHILE i < n DO
    (* Ensure there is a chunk with room *)
    IF (s.tail = NIL) OR (s.tail.len >= ChunkSize) THEN
      NEW(c);
      c.len  := 0;
      c.next := NIL;
      IF s.tail = NIL THEN s.head := c ELSE s.tail.next := c END;
      s.tail := c
    END;
    room := ChunkSize - s.tail.len;
    take := n - i;
    IF take > room THEN take := room END;
    WHILE take > 0 DO
      s.tail.data[s.tail.len] := buf[i];
      INC(s.tail.len);
      INC(i);
      INC(s.length);
      DEC(take)
    END
  END
END Append;

PROCEDURE FromStr*(s: Seq; str: ARRAY OF CHAR);
(*
    Load sequence from a null-terminated Oberon string.
    Clears any existing content first.
  *)
VAR i: INTEGER;
BEGIN
  ClearChunks(s);
  i := 0;
  WHILE (i < LEN(str)) & (str[i] # 0X) DO INC(i) END;
  Append(s, str, i)
END FromStr;

(* ------------------------------------------------------------------ *)
(*  Random access                                                       *)
(* ------------------------------------------------------------------ *)

PROCEDURE Get*(s: Seq; pos: INTEGER): CHAR;
(*
    Return the character at 0-based position pos.
    Returns 0X if pos is out of range.
  *)
VAR c: ChunkPtr; p: INTEGER;
BEGIN
  IF (s = NIL) OR (pos < 0) OR (pos >= s.length) THEN RETURN 0X END;
  c := s.head;
  p := pos;
  WHILE (c # NIL) & (p >= c.len) DO
    DEC(p, c.len);
    c := c.next
  END;
  IF c = NIL THEN RETURN 0X END;
  RETURN c.data[p]
END Get;

PROCEDURE Slice*(s: Seq; start, len: INTEGER; VAR buf: ARRAY OF CHAR);
(*
    Copy len characters starting at 0-based position start into buf.
    buf is always null-terminated.
    Copies at most LEN(buf)-1 characters.
    Characters beyond the end of s are not written.
  *)
VAR c: ChunkPtr; p, bufcap, i, avail, take: INTEGER;
BEGIN
  bufcap := LEN(buf) - 1;
  IF bufcap <= 0 THEN RETURN END;
  buf[0] := 0X;
  IF (s = NIL) OR (start < 0) OR (start >= s.length) OR (len <= 0) THEN RETURN END;
  IF len > bufcap         THEN len := bufcap END;
  IF start + len > s.length THEN len := s.length - start END;
  (* Seek to start position *)
  c := s.head; p := start;
  WHILE (c # NIL) & (p >= c.len) DO DEC(p, c.len); c := c.next END;
  (* Copy characters *)
  i := 0;
  WHILE (c # NIL) & (i < len) DO
    avail := c.len - p;
    take  := len - i;
    IF take > avail THEN take := avail END;
    WHILE take > 0 DO
      buf[i] := c.data[p];
      INC(i); INC(p); DEC(take)
    END;
    c := c.next; p := 0
  END;
  buf[i] := 0X
END Slice;

PROCEDURE Length*(s: Seq): INTEGER;
(* Return the number of characters in s. *)
BEGIN
  IF s = NIL THEN RETURN 0 END;
  RETURN s.length
END Length;

(* ------------------------------------------------------------------ *)
(*  In-place transformations                                            *)
(* ------------------------------------------------------------------ *)

PROCEDURE ToUpper*(s: Seq);
(* Convert all characters in s to uppercase in place. *)
VAR c: ChunkPtr; i: INTEGER;
BEGIN
  IF s = NIL THEN RETURN END;
  c := s.head;
  WHILE c # NIL DO
    FOR i := 0 TO c.len - 1 DO
      IF (c.data[i] >= 'a') & (c.data[i] <= 'z') THEN
        c.data[i] := CHR(ORD(c.data[i]) - 32)
      END
    END;
    c := c.next
  END
END ToUpper;

PROCEDURE ToLower*(s: Seq);
(* Convert all characters in s to lowercase in place. *)
VAR c: ChunkPtr; i: INTEGER;
BEGIN
  IF s = NIL THEN RETURN END;
  c := s.head;
  WHILE c # NIL DO
    FOR i := 0 TO c.len - 1 DO
      IF (c.data[i] >= 'A') & (c.data[i] <= 'Z') THEN
        c.data[i] := CHR(ORD(c.data[i]) + 32)
      END
    END;
    c := c.next
  END
END ToLower;

(* ------------------------------------------------------------------ *)
(*  Statistics                                                          *)
(* ------------------------------------------------------------------ *)

PROCEDURE Count*(s: Seq; ch: CHAR): INTEGER;
(* Count occurrences of ch in s. *)
VAR c: ChunkPtr; i, n: INTEGER;
BEGIN
  n := 0;
  IF s = NIL THEN RETURN 0 END;
  c := s.head;
  WHILE c # NIL DO
    FOR i := 0 TO c.len - 1 DO
      IF c.data[i] = ch THEN INC(n) END
    END;
    c := c.next
  END;
  RETURN n
END Count;

PROCEDURE IsNucleotide*(s: Seq): BOOLEAN;
(* Returns TRUE when >= 85% of residues are A/C/G/T/U/N (case-insensitive). *)
VAR total, nucl: INTEGER; c: ChunkPtr; i: INTEGER; ch: CHAR;
BEGIN
  IF (s = NIL) OR (s.length = 0) THEN RETURN TRUE END;
  total := 0; nucl := 0;
  c := s.head;
  WHILE c # NIL DO
    FOR i := 0 TO c.len - 1 DO
      ch := c.data[i];
      IF (ch >= 'a') & (ch <= 'z') THEN ch := CHR(ORD(ch) - 32) END;
      INC(total);
      IF (ch = 'A') OR (ch = 'C') OR (ch = 'G') OR (ch = 'T') OR
         (ch = 'U') OR (ch = 'N') THEN INC(nucl) END
    END;
    c := c.next
  END;
  RETURN nucl * 100 >= total * 85
END IsNucleotide;

PROCEDURE GCContent*(s: Seq): REAL;
(*
    Return the fraction of G and C bases (upper or lower case).
    Returns 0.0 for an empty sequence.
  *)
VAR gc: INTEGER;
BEGIN
  IF (s = NIL) OR (s.length = 0) THEN RETURN 0.0 END;
  gc := Count(s, 'G') + Count(s, 'C') +
  Count(s, 'g') + Count(s, 'c');
  RETURN FLT(gc) / FLT(s.length)
END GCContent;

(* ------------------------------------------------------------------ *)
(*  Reverse complement                                                  *)
(* ------------------------------------------------------------------ *)

PROCEDURE RevComp*(s: Seq; VAR a: BioAlpha.Alphabet; dst: Seq);
(*
    Write the reverse complement of s into dst using alphabet a.
    dst is cleared first.
    Characters with no complement defined are copied unchanged.
    Uses a ChunkSize-sized staging buffer to avoid single-char appends.
  *)
VAR buf: ARRAY ChunkSize OF CHAR;
pos, buflen: INTEGER;
ch, comp: CHAR;
BEGIN
  ClearChunks(dst);
  IF (s = NIL) OR (s.length = 0) THEN RETURN END;
  buflen := 0;
  pos    := s.length - 1;
  WHILE pos >= 0 DO
    ch   := Get(s, pos);
    comp := BioAlpha.Complement(a, ch);
    IF comp = 0X THEN comp := ch END;
    buf[buflen] := comp;
    INC(buflen);
    IF buflen = ChunkSize THEN
      Append(dst, buf, buflen);
      buflen := 0
    END;
    DEC(pos)
  END;
  IF buflen > 0 THEN Append(dst, buf, buflen) END
END RevComp;

(* ------------------------------------------------------------------ *)
(*  Conversion                                                          *)
(* ------------------------------------------------------------------ *)

PROCEDURE ToStr*(s: Seq; VAR str: ARRAY OF CHAR);
(*
    Copy up to LEN(str)-1 characters from s into str, null-terminated.
  *)
BEGIN
  Slice(s, 0, LEN(str) - 1, str)
END ToStr;

(* ------------------------------------------------------------------ *)
(*  Equality                                                            *)
(* ------------------------------------------------------------------ *)

PROCEDURE Equal*(a, b: Seq): BOOLEAN;
(*
    Return TRUE if a and b contain identical character sequences.
    Both NIL is considered equal.
  *)
VAR ca, cb: ChunkPtr; ia, ib: INTEGER;
BEGIN
  IF (a = NIL) & (b = NIL) THEN RETURN TRUE END;
  IF (a = NIL) OR (b = NIL) THEN RETURN FALSE END;
  IF a.length # b.length THEN RETURN FALSE END;
  ca := a.head; ia := 0;
  cb := b.head; ib := 0;
  WHILE (ca # NIL) & (cb # NIL) DO
    IF ca.data[ia] # cb.data[ib] THEN RETURN FALSE END;
    INC(ia); INC(ib);
    IF ia >= ca.len THEN ca := ca.next; ia := 0 END;
    IF ib >= cb.len THEN cb := cb.next; ib := 0 END
  END;
  RETURN TRUE
END Equal;

(* ------------------------------------------------------------------ *)
(*  Display                                                             *)
(* ------------------------------------------------------------------ *)

PROCEDURE Print*(s: Seq);
(*
    Print the sequence name (if set) and full content to stdout,
    wrapped at 60 characters per line (FASTA-style).
  *)
VAR c: ChunkPtr; i, col: INTEGER;
BEGIN
  IF s = NIL THEN Out.String("(nil seq)"); Out.Ln(); RETURN END;
  IF s.name[0] # 0X THEN
    Out.Char('>'); Out.String(s.name); Out.Ln()
  END;
  c := s.head; col := 0;
  WHILE c # NIL DO
    FOR i := 0 TO c.len - 1 DO
      Out.Char(c.data[i]);
      INC(col);
      IF col = 60 THEN Out.Ln(); col := 0 END
    END;
    c := c.next
  END;
  IF col > 0 THEN Out.Ln() END
END Print;

END BioSeq.
