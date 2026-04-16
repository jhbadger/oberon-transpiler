MODULE XHTML;
(*
 * XHTML — lightweight XHTML/HTML parsing utilities.
 *
 * Two exported procedures:
 *
 *   XHTML.ToText(src, dst)
 *       Convert XHTML/HTML in src to plain text in dst.
 *       Tags are stripped; block-level elements (<p>, <br>, <h1>-<h6>,
 *       <div>, <li>, <tr>, <hr>, <ul>, <ol>, <blockquote>) become
 *       newlines; <script> and <style> bodies are removed entirely;
 *       HTML entities are decoded.  Consecutive whitespace collapses
 *       to one space; leading whitespace after a newline is suppressed.
 *
 *   XHTML.AttrValue(src, attr, val)
 *       Search src for an attribute named attr (case-insensitive).
 *       Copies the quoted value into val and returns TRUE, or returns
 *       FALSE if not found.  Useful for parsing OPF and container.xml
 *       fragments.  attr must be lowercase.
 *)

IMPORT Strings;

(* ── Lower: fold a character to lowercase ───────────────────────── *)
PROCEDURE Lower(c: CHAR): CHAR;
BEGIN
  IF (c >= 'A') & (c <= 'Z') THEN RETURN CHR(ORD(c) + 32) END;
  RETURN c
END Lower;

(* ── TagIs: does src[pos..] start with lowercase tag name 'tag'?
   The character immediately after the name must be a delimiter
   (space, tab, newline, '>', or '/') to avoid prefix-matching.     *)
PROCEDURE TagIs(src: ARRAY OF CHAR; pos: INTEGER;
                tag: ARRAY OF CHAR): BOOLEAN;
VAR i, tlen: INTEGER; term: CHAR;
BEGIN
  tlen := Strings.Length(tag);
  i := 0;
  WHILE (i < tlen) & (src[pos + i] # 0X) DO
    IF Lower(src[pos + i]) # tag[i] THEN RETURN FALSE END;
    INC(i)
  END;
  IF i < tlen THEN RETURN FALSE END;
  term := src[pos + i];
  RETURN (term = ' ') OR (term = '>') OR (term = '/') OR
         (term = 9X)  OR (term = 0AX) OR (term = 0DX)
END TagIs;

(* ── SkipTag: advance pos past the closing '>' of a tag.
   Handles attribute values containing '>' (quoted).              *)
PROCEDURE SkipTag(src: ARRAY OF CHAR; VAR pos: INTEGER);
VAR inq: BOOLEAN; q: CHAR;
BEGIN
  inq := FALSE; q := 0X;
  WHILE src[pos] # 0X DO
    IF inq THEN
      IF src[pos] = q THEN inq := FALSE END
    ELSIF (src[pos] = 22X) OR (src[pos] = 27X) THEN  (* " or ' *)
      inq := TRUE; q := src[pos]
    ELSIF src[pos] = '>' THEN
      INC(pos); RETURN
    END;
    INC(pos)
  END
END SkipTag;

(* ── SkipToClose: advance past the matching </tag> end element.   *)
PROCEDURE SkipToClose(src: ARRAY OF CHAR; VAR pos: INTEGER;
                      tag: ARRAY OF CHAR);
BEGIN
  WHILE src[pos] # 0X DO
    IF (src[pos] = '<') & (src[pos + 1] = '/') THEN
      IF TagIs(src, pos + 2, tag) THEN
        WHILE (src[pos] # 0X) & (src[pos] # '>') DO INC(pos) END;
        IF src[pos] = '>' THEN INC(pos) END;
        RETURN
      END
    END;
    INC(pos)
  END
END SkipToClose;

(* ── SkipComment: advance past --> (called after <!--).           *)
PROCEDURE SkipComment(src: ARRAY OF CHAR; VAR pos: INTEGER);
BEGIN
  WHILE src[pos] # 0X DO
    IF (src[pos] = '-') & (src[pos + 1] = '-') & (src[pos + 2] = '>') THEN
      INC(pos, 3); RETURN
    END;
    INC(pos)
  END
END SkipComment;

(* ── IsBlock: is the tag name at src[pos] a block-level element?  *)
PROCEDURE IsBlock(src: ARRAY OF CHAR; pos: INTEGER): BOOLEAN;
BEGIN
  RETURN TagIs(src, pos, "p")          OR TagIs(src, pos, "br")  OR
         TagIs(src, pos, "div")        OR TagIs(src, pos, "li")  OR
         TagIs(src, pos, "h1")         OR TagIs(src, pos, "h2")  OR
         TagIs(src, pos, "h3")         OR TagIs(src, pos, "h4")  OR
         TagIs(src, pos, "h5")         OR TagIs(src, pos, "h6")  OR
         TagIs(src, pos, "tr")         OR TagIs(src, pos, "hr")  OR
         TagIs(src, pos, "ul")         OR TagIs(src, pos, "ol")  OR
         TagIs(src, pos, "blockquote") OR TagIs(src, pos, "pre")
END IsBlock;

(* ── DecodeEntity: decode the HTML entity starting at src[pos].
   On entry  pos points to the character after '&'.
   On return pos is advanced past the entity and its ';'.
   Returns TRUE and sets c to the decoded character if successful.
   Returns FALSE (and still advances pos) for unknown entities.    *)
PROCEDURE DecodeEntity(src: ARRAY OF CHAR; VAR pos: INTEGER;
                       VAR c: CHAR): BOOLEAN;
VAR i, n: INTEGER; name: ARRAY 16 OF CHAR;
BEGIN
  IF src[pos] = '#' THEN
    (* numeric entity: &#nn; or &#xhh; *)
    INC(pos); n := 0;
    IF (src[pos] = 'x') OR (src[pos] = 'X') THEN
      INC(pos);
      WHILE ((src[pos] >= '0') & (src[pos] <= '9')) OR
            ((Lower(src[pos]) >= 'a') & (Lower(src[pos]) <= 'f')) DO
        IF (src[pos] >= '0') & (src[pos] <= '9') THEN
          n := n * 16 + ORD(src[pos]) - ORD('0')
        ELSE
          n := n * 16 + ORD(Lower(src[pos])) - ORD('a') + 10
        END;
        INC(pos)
      END
    ELSE
      WHILE (src[pos] >= '0') & (src[pos] <= '9') DO
        n := n * 10 + ORD(src[pos]) - ORD('0'); INC(pos)
      END
    END;
    IF src[pos] = ';' THEN INC(pos) END;
    IF (n > 32) & (n < 128) THEN c := CHR(n); RETURN TRUE END;
    IF (n = 9) OR (n = 10) OR (n = 13) OR (n = 32) OR (n = 160) THEN
      c := ' '; RETURN TRUE
    END;
    c := ' '; RETURN TRUE
  END;

  (* named entity: collect name up to ';' *)
  i := 0;
  WHILE (i < 15) & (src[pos] # ';') & (src[pos] # 0X) &
        (src[pos] # ' ') & (src[pos] # '<') DO
    name[i] := src[pos]; INC(pos); INC(i)
  END;
  name[i] := 0X;
  IF src[pos] = ';' THEN INC(pos) END;

  IF Strings.Compare(name, "amp")    = 0 THEN c := '&';  RETURN TRUE END;
  IF Strings.Compare(name, "lt")     = 0 THEN c := '<';  RETURN TRUE END;
  IF Strings.Compare(name, "gt")     = 0 THEN c := '>';  RETURN TRUE END;
  IF Strings.Compare(name, "quot")   = 0 THEN c := 22X;  RETURN TRUE END;
  IF Strings.Compare(name, "apos")   = 0 THEN c := 27X;  RETURN TRUE END;
  IF Strings.Compare(name, "nbsp")   = 0 THEN c := ' ';  RETURN TRUE END;
  IF Strings.Compare(name, "mdash")  = 0 THEN c := '-';  RETURN TRUE END;
  IF Strings.Compare(name, "ndash")  = 0 THEN c := '-';  RETURN TRUE END;
  IF Strings.Compare(name, "lsquo")  = 0 THEN c := 27X;  RETURN TRUE END;
  IF Strings.Compare(name, "rsquo")  = 0 THEN c := 27X;  RETURN TRUE END;
  IF Strings.Compare(name, "ldquo")  = 0 THEN c := 22X;  RETURN TRUE END;
  IF Strings.Compare(name, "rdquo")  = 0 THEN c := 22X;  RETURN TRUE END;
  IF Strings.Compare(name, "hellip") = 0 THEN c := '.';  RETURN TRUE END;
  IF Strings.Compare(name, "eacute") = 0 THEN c := 'e';  RETURN TRUE END;
  IF Strings.Compare(name, "egrave") = 0 THEN c := 'e';  RETURN TRUE END;
  IF Strings.Compare(name, "ecirc")  = 0 THEN c := 'e';  RETURN TRUE END;
  IF Strings.Compare(name, "agrave") = 0 THEN c := 'a';  RETURN TRUE END;
  IF Strings.Compare(name, "aacute") = 0 THEN c := 'a';  RETURN TRUE END;
  IF Strings.Compare(name, "oacute") = 0 THEN c := 'o';  RETURN TRUE END;
  IF Strings.Compare(name, "uacute") = 0 THEN c := 'u';  RETURN TRUE END;
  IF Strings.Compare(name, "ccedil") = 0 THEN c := 'c';  RETURN TRUE END;
  IF Strings.Compare(name, "ntilde") = 0 THEN c := 'n';  RETURN TRUE END;

  RETURN FALSE
END DecodeEntity;

(* ── ToText: convert XHTML/HTML to plain text ────────────────────
   Tags are stripped.  Block-level open/close tags emit a newline.
   <script> and <style> content is removed.  HTML entities are
   decoded to their nearest ASCII equivalent.  Runs of whitespace
   collapse to a single space; leading space after a newline is
   suppressed.                                                       *)
PROCEDURE ToText*(src: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR);
VAR sp, dp, dl: INTEGER; c: CHAR; lastNL: BOOLEAN;
    imgTag: ARRAY 512 OF CHAR;
    imgSrc: ARRAY 512 OF CHAR;
    i, j: INTEGER;
BEGIN
  sp := 0; dp := 0; dl := LEN(dst) - 1; lastNL := TRUE;
  WHILE src[sp] # 0X DO
    IF src[sp] = '<' THEN
      INC(sp);
      IF src[sp] = '!' THEN
        IF (src[sp + 1] = '-') & (src[sp + 2] = '-') THEN
          INC(sp, 3); SkipComment(src, sp)   (* <!-- comment --> *)
        ELSE
          SkipTag(src, sp)                    (* <!DOCTYPE ...>   *)
        END
      ELSIF src[sp] = '?' THEN
        (* <?xml ... ?> processing instruction *)
        WHILE (src[sp] # 0X) & (src[sp] # '>') DO INC(sp) END;
        IF src[sp] = '>' THEN INC(sp) END
      ELSIF src[sp] = '/' THEN
        (* closing tag: emit newline for block elements *)
        INC(sp);
        IF IsBlock(src, sp) THEN
          IF ~lastNL & (dp < dl) THEN dst[dp] := 0AX; INC(dp); lastNL := TRUE END
        END;
        DEC(sp); SkipTag(src, sp)
      ELSIF TagIs(src, sp, "script") THEN
        SkipTag(src, sp); SkipToClose(src, sp, "script")
      ELSIF TagIs(src, sp, "style") THEN
        SkipTag(src, sp); SkipToClose(src, sp, "style")
      ELSIF IsBlock(src, sp) THEN
        (* opening block tag: emit newline *)
        IF ~lastNL & (dp < dl) THEN dst[dp] := 0AX; INC(dp); lastNL := TRUE END;
        SkipTag(src, sp)
      ELSIF TagIs(src, sp, "img") THEN
        (* capture tag text to extract src attribute *)
        i := 0;
        WHILE (src[sp] # 0X) & (src[sp] # '>') & (i < 511) DO
          imgTag[i] := src[sp]; INC(i); INC(sp)
        END;
        imgTag[i] := 0X;
        IF src[sp] = '>' THEN INC(sp) END;
        IF AttrValue(imgTag, "src", imgSrc) THEN
          (* emit newline then [IMG:path] placeholder on its own line *)
          IF ~lastNL & (dp < dl) THEN dst[dp] := 0AX; INC(dp); lastNL := TRUE END;
          IF dp < dl THEN dst[dp] := '['; INC(dp) END;
          IF dp < dl THEN dst[dp] := 'I'; INC(dp) END;
          IF dp < dl THEN dst[dp] := 'M'; INC(dp) END;
          IF dp < dl THEN dst[dp] := 'G'; INC(dp) END;
          IF dp < dl THEN dst[dp] := ':'; INC(dp) END;
          j := 0;
          WHILE (imgSrc[j] # 0X) & (dp < dl) DO dst[dp] := imgSrc[j]; INC(dp); INC(j) END;
          IF dp < dl THEN dst[dp] := ']'; INC(dp) END;
          IF dp < dl THEN dst[dp] := 0AX; INC(dp) END;
          lastNL := TRUE
        END
      ELSE
        SkipTag(src, sp)                      (* inline tag: discard *)
      END

    ELSIF src[sp] = '&' THEN
      INC(sp);
      IF DecodeEntity(src, sp, c) THEN
        IF c = ' ' THEN
          IF ~lastNL & (dp < dl) THEN dst[dp] := ' '; INC(dp) END
        ELSE
          IF dp < dl THEN dst[dp] := c; INC(dp) END;
          lastNL := FALSE
        END
      END

    ELSIF (src[sp] = ' ') OR (src[sp] = 9X) OR
          (src[sp] = 0AX) OR (src[sp] = 0DX) THEN
      (* collapse any run of whitespace to one space *)
      WHILE (src[sp] = ' ')  OR (src[sp] = 9X) OR
            (src[sp] = 0AX) OR (src[sp] = 0DX) DO INC(sp) END;
      IF ~lastNL & (dp < dl) THEN dst[dp] := ' '; INC(dp) END

    ELSE
      IF dp < dl THEN dst[dp] := src[sp]; INC(dp) END;
      INC(sp); lastNL := FALSE
    END
  END;
  dst[dp] := 0X
END ToText;

(* ── AttrValue: find an attribute value anywhere in src ──────────
   Scans src for the pattern  attr="..."  or  attr='...'
   (case-insensitive match on the attribute name).
   attr must be supplied in lowercase.
   Copies the value into val and returns TRUE if found.            *)
PROCEDURE AttrValue*(src: ARRAY OF CHAR; attr: ARRAY OF CHAR;
                     VAR val: ARRAY OF CHAR): BOOLEAN;
VAR i, j, k, alen, slen, vl: INTEGER; q: CHAR;
BEGIN
  alen := Strings.Length(attr);
  slen := Strings.Length(src);
  val[0] := 0X;
  i := 0;
  WHILE i <= slen - alen - 1 DO
    (* try to match attr name at position i *)
    j := 0;
    WHILE (j < alen) & (Lower(src[i + j]) = attr[j]) DO INC(j) END;
    IF j = alen THEN
      (* name matched: skip spaces, expect '=' *)
      k := i + alen;
      WHILE src[k] = ' ' DO INC(k) END;
      IF src[k] = '=' THEN
        INC(k);
        WHILE src[k] = ' ' DO INC(k) END;
        IF (src[k] = 22X) OR (src[k] = 27X) THEN   (* " or ' *)
          q := src[k]; INC(k);
          vl := 0;
          WHILE (src[k] # 0X) & (src[k] # q) & (vl < LEN(val) - 1) DO
            val[vl] := src[k]; INC(vl); INC(k)
          END;
          val[vl] := 0X;
          RETURN TRUE
        END
      END
    END;
    INC(i)
  END;
  RETURN FALSE
END AttrValue;

END XHTML.
