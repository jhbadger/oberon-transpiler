MODULE Markdown;
(*
 * Markdown - shared markdown parsing/rendering helpers.
 *
 * Extracted from plume.mod's --html and --rtf renderers so other tools
 * (and plume's own PDF/LaTeX/EPUB paths) can reuse the same markdown
 * structure recognition and inline-markup handling.
 *
 * Output goes through a caller-supplied WriteProc (see SetSink) rather
 * than a file directly, so a caller can layer its own bookkeeping (CRC
 * tracking for a ZIP entry, buffering, etc.) underneath.
 *
 * Usage:
 *   Markdown.SetSink(MyWriteChar);
 *   Markdown.Reset;
 *   Markdown.HtmlHeader;
 *   Markdown.HtmlLine(line);   (* once per input line *)
 *   Markdown.HtmlFooter;
 *
 * IsHRule/IsTableSep/GetCell/CountCols are generic markdown-structure
 * recognizers with no HTML/RTF dependency, exported for renderers (like
 * plume's PDF/LaTeX output) that build their own inline rendering.
 *
 * RtfManuscriptHeader/RtfManuscriptLine/RtfManuscriptFooter are a
 * separate, self-contained "Standard Manuscript Format" RTF renderer
 * (double-spaced, first-line indent, chapter page-breaks, smart
 * typography, ".."-prefixed note lines stripped) used by ostar.mod's
 * ^K M / ^P K — unrelated to the generic RtfHeader/RtfLine/RtfFooter
 * above beyond both producing RTF. Each input line becomes a complete
 * paragraph on its own (no cross-line accumulation), so it needs no
 * end-of-block flush the way the generic renderers do.
 *
 * EpubContentHeader/EpubLine/EpubContentFooter/EpubStartsChapter/
 * EpubBeginChapter/EpubNavXhtml/EpubContainerXml/EpubPackageOpf/
 * EpubMimetype generate the text members of a minimal EPUB 3 —
 * modeled on PerfectStar 2k's epub.rs, not on plume's own (separate,
 * EPUB 2/toc.ncx-style) --epub output: one unstyled chapterN.xhtml
 * per level-1 (#) heading (h1-h6 headings, paragraphs, smart
 * typography, *italic*/**bold**/`code` spans, ".."-notes stripped)
 * plus a flat nav.xhtml linking every heading. As with the renderers
 * above, only each member's *text* comes from here — packing them
 * into an actual .epub (ZIP local/central-directory headers,
 * per-entry CRC-32) is caller bookkeeping layered atop SetSink, same
 * as noted for RTF/HTML above. The caller drives one chapter file at
 * a time, checking EpubStartsChapter before each line to know when to
 * close the current chapter file and open the next:
 *   Markdown.EpubContentHeader;         (* -> chapter1.xhtml *)
 *   (* per input line: *)
 *     IF Markdown.EpubStartsChapter(line) THEN
 *       Markdown.EpubContentFooter;     (* close current chapter file *)
 *       (* register/close it, open the next chapter file, SetSink *)
 *       Markdown.EpubBeginChapter;
 *       Markdown.EpubContentHeader      (* -> chapterN.xhtml *)
 *     END;
 *     Markdown.EpubLine(line);
 *   Markdown.EpubContentFooter;         (* close the last chapter file *)
 *   Markdown.SetSink(...);              (* -> package.opf *)
 *   Markdown.EpubPackageOpf(Markdown.EpubChapterNum());
 *   Markdown.SetSink(...);              (* -> nav.xhtml *)
 *   Markdown.EpubNavXhtml;
 *)

IMPORT Strings;

CONST
  MaxLine* = 4096;
  EpubNavBufSize = 65536;  (* generous cap on total nav.xhtml TOC markup *)

TYPE
  WriteProc* = PROCEDURE(c: CHAR);

VAR
  sink : WriteProc;

  (* Shared block-level state for the HTML and RTF renderers below. Only
     one of the two is ever driven at a time (plume picks one output
     format per run), so there is no need to keep them separate. *)
  inPara, inList, listOrd : BOOLEAN;
  listN                    : INTEGER;
  inCode, inBQ             : BOOLEAN;
  bold, ital               : BOOLEAN;
  inTable, inTableHead     : BOOLEAN;
  tableHdr                 : ARRAY MaxLine OF CHAR;
  tableCols                : INTEGER;

  (* Manuscript-mode RTF state: just whether we've emitted a chapter
     yet (so the very first one skips the leading page break). *)
  msFirst                  : BOOLEAN;

  (* EPUB state: a heading counter shared between each chapter file's
     "heading-N" ids and nav.xhtml's matching links, and an internal
     accumulator for nav.xhtml's <li> markup, built up during the same
     single pass over the document that streams the chapter files (see
     EpubLine/EpubNavSink). epubChapterN/epubChapterHasContent track
     which chapterN.xhtml is current (see EpubStartsChapter/
     EpubBeginChapter) so nav links point at the right file. *)
  epubHeadingN             : INTEGER;
  epubNavBuf               : ARRAY EpubNavBufSize OF CHAR;
  epubNavLen               : INTEGER;
  epubChapterN             : INTEGER;
  epubChapterHasContent    : BOOLEAN;

(* ── Output primitives ────────────────────────────────── *)

PROCEDURE SetSink*(w: WriteProc);
BEGIN sink := w END SetSink;

PROCEDURE Wch(c: CHAR);
BEGIN IF sink # NIL THEN sink(c) END END Wch;

PROCEDURE Wstr(s: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN i := 0; WHILE s[i] # 0X DO Wch(s[i]); INC(i) END END Wstr;

PROCEDURE Wln;
BEGIN Wch(0AX) END Wln;

PROCEDURE Reset*;
(* Clear block-level state before rendering a fresh document. *)
BEGIN
  inPara := FALSE; inList := FALSE; listOrd := FALSE; listN := 1;
  inCode := FALSE; inBQ := FALSE;
  bold := FALSE; ital := FALSE;
  inTable := FALSE; inTableHead := FALSE; tableCols := 0;
  msFirst := TRUE;
  epubHeadingN := 0; epubNavLen := 0; epubNavBuf[0] := 0X;
  epubChapterN := 1; epubChapterHasContent := FALSE
END Reset;

(* ── UTF-8 / RTF character escaping ──────────────────────
   Shared by both RTF renderers below (generic and manuscript-mode).
   Lines come from UTF-8 source files, but RTF's \uN escape wants one
   Unicode code point at a time — so any non-ASCII byte run must be
   decoded to a code point first, never escaped byte-by-byte (a
   multi-byte UTF-8 character escaped one raw byte at a time comes out
   as mojibake in the RTF reader, each byte reinterpreted as its own
   \ansicpg1252 character). *)

(* Decode one Unicode code point starting at byte k of s (well-formed
   UTF-8). cp is the code point, nbytes how many bytes it occupied. A
   truncated/invalid lead byte at end-of-line degrades to its own raw
   byte value, 1 byte consumed. *)
PROCEDURE DecodeUtf8Cp(s: ARRAY OF CHAR; k, len: INTEGER; VAR cp, nbytes: INTEGER);
VAR b0, b1, b2, b3: INTEGER;
BEGIN
  b0 := ORD(s[k]);
  IF b0 < 80H THEN
    cp := b0; nbytes := 1
  ELSIF (b0 >= 0C0H) & (b0 < 0E0H) & (k + 1 < len) THEN
    b1 := ORD(s[k + 1]);
    cp := ((b0 - 0C0H) * 40H) + (b1 - 80H); nbytes := 2
  ELSIF (b0 >= 0E0H) & (b0 < 0F0H) & (k + 2 < len) THEN
    b1 := ORD(s[k + 1]); b2 := ORD(s[k + 2]);
    cp := ((b0 - 0E0H) * 1000H) + ((b1 - 80H) * 40H) + (b2 - 80H); nbytes := 3
  ELSIF (b0 >= 0F0H) & (k + 3 < len) THEN
    b1 := ORD(s[k + 1]); b2 := ORD(s[k + 2]); b3 := ORD(s[k + 3]);
    cp := ((b0 - 0F0H) * 40000H) + ((b1 - 80H) * 1000H) +
          ((b2 - 80H) * 40H) + (b3 - 80H);
    nbytes := 4
  ELSE
    cp := b0; nbytes := 1
  END
END DecodeUtf8Cp;

(* A single ASCII stand-in for a non-ASCII code point, read by \uc1
   readers that ignore \uN. Recognizes the handful of typographic
   substitutes the manuscript renderer produces; anything else (an
   already-Unicode character carried verbatim from a UTF-8 source, as
   the generic renderer never smartens ASCII into these) falls back to
   a bare '?'. *)
PROCEDURE RtfAsciiFallback(cp: INTEGER): CHAR;
BEGIN
  IF (cp = 8216) OR (cp = 8217) THEN RETURN 27X
  ELSIF (cp = 8220) OR (cp = 8221) THEN RETURN 22X
  ELSIF (cp = 8212) OR (cp = 8211) THEN RETURN '-'
  ELSIF cp = 8230 THEN RETURN '.'
  ELSE RETURN '?'
  END
END RtfAsciiFallback;

(* Escape one already-decoded code point for RTF output: backslash/
   braces/tab as control words, plain ASCII verbatim, astral code
   points degrade to '?' (no surrogate-pair support), and everything
   else as a single \uN escape (two's-complement above 0x7FFF) plus a
   one-character ASCII fallback. *)
PROCEDURE RtfEscCp(cp: INTEGER);
VAR tmp: ARRAY 16 OF CHAR; sgn: INTEGER;
BEGIN
  IF    cp = 5CH THEN Wstr("\\\\")
  ELSIF cp = 7BH THEN Wstr("\{")
  ELSIF cp = 7DH THEN Wstr("\}")
  ELSIF cp = 9  THEN Wstr("\tab ")
  ELSIF cp < 80H THEN Wch(CHR(cp))
  ELSIF cp >= 10000H THEN Wch('?')
  ELSE
    IF cp > 7FFFH THEN sgn := cp - 10000H ELSE sgn := cp END;
    Wstr("\u"); Strings.IntToStr(sgn, tmp); Wstr(tmp);
    Wch(' '); Wch(RtfAsciiFallback(cp))
  END
END RtfEscCp;

(* Escape a whole NUL-terminated string (used for the small txt/url
   scratch buffers pulled out of `[text](url)` links, and for code-
   block lines, which have no surrounding line-buffer length handy). *)
PROCEDURE RtfEscStr(buf: ARRAY OF CHAR);
VAR k, blen, cp, nbytes: INTEGER;
BEGIN
  blen := Strings.Length(buf); k := 0;
  WHILE k < blen DO
    DecodeUtf8Cp(buf, k, blen, cp, nbytes); RtfEscCp(cp); INC(k, nbytes)
  END
END RtfEscStr;

(* ── Generic markdown structure ──────────────────────────
   No output-format dependency; usable by any renderer. *)

PROCEDURE IsHRule*(s: ARRAY OF CHAR): BOOLEAN;
(* A line of only one marker char (-, *, _) and spaces, with at least
   three occurrences of the marker itself — e.g. "* * *" (5 chars, 3
   markers) qualifies, but "-  " (1 marker padded by trailing spaces)
   must not: count markers, not total line length. *)
VAR i, count: INTEGER; c: CHAR;
BEGIN
  c := s[0];
  IF (c # '-') & (c # '*') & (c # '_') THEN RETURN FALSE END;
  i := 0; count := 0;
  WHILE (s[i] = c) OR (s[i] = ' ') DO
    IF s[i] = c THEN INC(count) END;
    INC(i)
  END;
  RETURN (s[i] = 0X) & (count >= 3)
END IsHRule;

PROCEDURE IsTableSep*(s: ARRAY OF CHAR): BOOLEAN;
VAR i, n: INTEGER; hasD: BOOLEAN;
BEGIN
  IF s[0] # '|' THEN RETURN FALSE END;
  n := Strings.Length(s); hasD := FALSE; i := 0;
  WHILE i < n DO
    IF s[i] = '-' THEN hasD := TRUE
    ELSIF (s[i] # '|') & (s[i] # ' ') & (s[i] # ':') THEN RETURN FALSE
    END;
    INC(i)
  END;
  RETURN hasD
END IsTableSep;

PROCEDURE GetCell*(s: ARRAY OF CHAR; VAR pos: INTEGER; VAR cell: ARRAY OF CHAR): BOOLEAN;
VAR i, start, fin, n: INTEGER;
BEGIN
  n := Strings.Length(s);
  IF (pos < n) & (s[pos] = '|') THEN INC(pos) END;
  IF pos >= n THEN RETURN FALSE END;
  start := pos;
  WHILE (pos < n) & (s[pos] # '|') DO INC(pos) END;
  IF pos = start THEN RETURN FALSE END;
  i := start;
  WHILE (i < pos) & (s[i] = ' ') DO INC(i) END;
  fin := pos;
  WHILE (fin > i) & (s[fin-1] = ' ') DO DEC(fin) END;
  Strings.Extract(s, i, fin - i, cell);
  RETURN TRUE
END GetCell;

PROCEDURE CountCols*(s: ARRAY OF CHAR): INTEGER;
VAR pos, n: INTEGER; cell: ARRAY 512 OF CHAR;
BEGIN
  pos := 0; n := 0;
  WHILE GetCell(s, pos, cell) DO INC(n) END;
  RETURN n
END CountCols;

(* ── HTML ─────────────────────────────────────────────── *)

PROCEDURE HtmlEsc(c: CHAR);
BEGIN
  IF    c = '<' THEN Wstr("&lt;")
  ELSIF c = '>' THEN Wstr("&gt;")
  ELSIF c = '&' THEN Wstr("&amp;")
  ELSE  Wch(c)
  END
END HtmlEsc;

PROCEDURE WriteInlineHtml(s: ARRAY OF CHAR);
VAR
  i, n, j, k : INTEGER;
  c           : CHAR;
  txt, url    : ARRAY 512 OF CHAR;
BEGIN
  bold := FALSE; ital := FALSE;
  i := 0; n := Strings.Length(s);
  WHILE i < n DO
    c := s[i];
    IF (c = '*') & (i + 1 < n) & (s[i+1] = '*') THEN
      IF bold THEN Wstr("</b>") ELSE Wstr("<b>") END;
      bold := ~bold; INC(i, 2)
    ELSIF c = '*' THEN
      IF ital THEN Wstr("</em>") ELSE Wstr("<em>") END;
      ital := ~ital; INC(i)
    ELSIF c = '`' THEN
      Wstr("<code>"); INC(i);
      WHILE (i < n) & (s[i] # '`') DO HtmlEsc(s[i]); INC(i) END;
      Wstr("</code>");
      IF i < n THEN INC(i) END
    ELSIF c = '[' THEN
      j := i + 1; k := 0;
      WHILE (j < n) & (s[j] # ']') & (k < 511) DO
        txt[k] := s[j]; INC(j); INC(k)
      END;
      txt[k] := 0X;
      IF (j < n) & (s[j] = ']') & (j + 1 < n) & (s[j+1] = '(') THEN
        INC(j, 2); k := 0;
        WHILE (j < n) & (s[j] # ')') & (k < 511) DO
          url[k] := s[j]; INC(j); INC(k)
        END;
        url[k] := 0X;
        Wstr('<a href="'); Wstr(url); Wstr('">');
        k := 0; WHILE txt[k] # 0X DO HtmlEsc(txt[k]); INC(k) END;
        Wstr("</a>"); i := j + 1
      ELSE
        HtmlEsc(c); INC(i)
      END
    ELSE
      HtmlEsc(c); INC(i)
    END
  END;
  IF bold THEN Wstr("</b>") END;
  IF ital THEN Wstr("</em>") END
END WriteInlineHtml;

PROCEDURE EndPara;
BEGIN IF inPara THEN Wstr("</p>"); Wln; inPara := FALSE END END EndPara;

PROCEDURE EndList;
BEGIN
  IF inList THEN
    IF listOrd THEN Wstr("</ol>") ELSE Wstr("</ul>") END;
    Wln; inList := FALSE
  END
END EndList;

PROCEDURE EndBQ;
BEGIN IF inBQ THEN Wstr("</blockquote>"); Wln; inBQ := FALSE END END EndBQ;

PROCEDURE EmitTableRowHtml(s: ARRAY OF CHAR; isHeader: BOOLEAN);
VAR pos: INTEGER; cell: ARRAY 512 OF CHAR;
BEGIN
  Wstr("<tr>"); pos := 0;
  WHILE GetCell(s, pos, cell) DO
    IF isHeader THEN Wstr("<th>") ELSE Wstr("<td>") END;
    WriteInlineHtml(cell);
    IF isHeader THEN Wstr("</th>") ELSE Wstr("</td>") END
  END;
  Wstr("</tr>"); Wln
END EmitTableRowHtml;

PROCEDURE EndTableHtml;
BEGIN
  IF inTable THEN
    IF inTableHead THEN
      Wstr("<thead>"); Wln;
      EmitTableRowHtml(tableHdr, TRUE);
      Wstr("</thead>"); Wln;
      inTableHead := FALSE
    END;
    Wstr("</tbody></table>"); Wln;
    inTable := FALSE
  END
END EndTableHtml;

PROCEDURE EndBlock*;
(* End whatever HTML block is currently open. Exported so a caller that
   finishes a document body itself (plume's EPUB packaging, which emits
   its own closing tags) can flush any still-open paragraph/list/table. *)
BEGIN EndPara; EndList; EndBQ; EndTableHtml END EndBlock;

PROCEDURE HtmlLine*(s: ARRAY OF CHAR);
VAR lvl, i, n: INTEGER; arg: ARRAY MaxLine OF CHAR;
BEGIN
  IF inCode THEN
    IF Strings.StartsWith(s, "```") THEN
      Wstr("</code></pre>"); Wln; inCode := FALSE
    ELSE
      i := 0; WHILE s[i] # 0X DO HtmlEsc(s[i]); INC(i) END; Wln
    END;
    RETURN
  END;

  IF Strings.StartsWith(s, "```") THEN
    EndBlock; Wstr("<pre><code>"); Wln; inCode := TRUE; RETURN
  END;

  n := Strings.Length(s);
  IF n = 0 THEN EndBlock; RETURN END;

  lvl := 0;
  WHILE (lvl < 6) & (s[lvl] = '#') DO INC(lvl) END;
  IF (lvl > 0) & (s[lvl] = ' ') THEN
    EndBlock;
    Wstr("<h"); Wch(CHR(ORD('0') + lvl)); Wch('>');
    Strings.Extract(s, lvl + 1, n - lvl - 1, arg);
    WriteInlineHtml(arg);
    Wstr("</h"); Wch(CHR(ORD('0') + lvl)); Wch('>'); Wln;
    RETURN
  END;

  IF IsHRule(s) THEN EndBlock; Wstr("<hr>"); Wln; RETURN END;

  IF IsTableSep(s) THEN
    IF inTable & inTableHead THEN
      Wstr("<thead>"); Wln;
      EmitTableRowHtml(tableHdr, TRUE);
      Wstr("</thead><tbody>"); Wln;
      inTableHead := FALSE
    END;
    RETURN
  END;

  IF s[0] = '|' THEN
    IF ~inTable THEN
      EndBlock;
      Wstr("<table>"); Wln;
      inTable := TRUE; inTableHead := TRUE;
      COPY(s, tableHdr)
    ELSIF inTableHead THEN
      Wstr("<thead>"); Wln;
      EmitTableRowHtml(tableHdr, TRUE);
      Wstr("</thead><tbody>"); Wln;
      inTableHead := FALSE;
      EmitTableRowHtml(s, FALSE)
    ELSE
      EmitTableRowHtml(s, FALSE)
    END;
    RETURN
  END;

  IF inTable THEN EndTableHtml END;

  IF s[0] = '>' THEN
    EndPara; EndList;
    IF ~inBQ THEN Wstr("<blockquote>"); Wln; inBQ := TRUE END;
    IF (n > 1) & (s[1] = ' ') THEN Strings.Extract(s, 2, n - 2, arg)
    ELSE Strings.Extract(s, 1, n - 1, arg) END;
    Wstr("<p>"); WriteInlineHtml(arg); Wstr("</p>"); Wln;
    RETURN
  END;
  EndBQ;

  IF ((s[0] = '-') OR (s[0] = '*')) & (n > 1) & (s[1] = ' ') THEN
    EndPara;
    IF ~inList OR listOrd THEN EndList; Wstr("<ul>"); Wln; inList := TRUE; listOrd := FALSE END;
    Wstr("<li>"); Strings.Extract(s, 2, n - 2, arg);
    WriteInlineHtml(arg); Wstr("</li>"); Wln;
    RETURN
  END;

  i := 0;
  WHILE (i < n) & (s[i] >= '0') & (s[i] <= '9') DO INC(i) END;
  IF (i > 0) & (i < n) & (s[i] = '.') & (i + 1 < n) & (s[i+1] = ' ') THEN
    EndPara;
    IF ~inList OR ~listOrd THEN EndList; Wstr("<ol>"); Wln; inList := TRUE; listOrd := TRUE END;
    Wstr("<li>"); Strings.Extract(s, i + 2, n - i - 2, arg);
    WriteInlineHtml(arg); Wstr("</li>"); Wln;
    RETURN
  END;

  EndList;
  IF ~inPara THEN Wstr("<p>"); inPara := TRUE END;
  WriteInlineHtml(s); Wch(' ')
END HtmlLine;

PROCEDURE HtmlHeader*;
BEGIN
  Wstr("<!DOCTYPE html>"); Wln;
  Wstr('<html><head><meta charset="utf-8">'); Wln;
  Wstr("<style>"); Wln;
  Wstr("body{font-family:Georgia,serif;max-width:700px;margin:2em auto;"); Wln;
  Wstr("     line-height:1.6;color:#222;padding:0 1em}"); Wln;
  Wstr("h1,h2,h3,h4,h5,h6{line-height:1.2;margin-top:1.5em}"); Wln;
  Wstr("pre,code{background:#f4f4f4;font-family:monospace}"); Wln;
  Wstr("pre{padding:1em;overflow:auto;border-radius:4px}"); Wln;
  Wstr("code{padding:.1em .3em;border-radius:3px}"); Wln;
  Wstr("blockquote{border-left:4px solid #ccc;margin-left:0;padding-left:1em;color:#555}"); Wln;
  Wstr("a{color:#0066cc}hr{border:none;border-top:1px solid #ccc}"); Wln;
  Wstr("table{border-collapse:collapse;margin:1em 0}"); Wln;
  Wstr("th,td{border:1px solid #ccc;padding:5px 10px;text-align:left}"); Wln;
  Wstr("thead th{background:#f0f0f0;font-weight:bold}"); Wln;
  Wstr("</style></head><body>"); Wln
END HtmlHeader;

PROCEDURE HtmlFooter*;
BEGIN EndBlock; Wstr("</body></html>"); Wln END HtmlFooter;

(* ── RTF ──────────────────────────────────────────────── *)

PROCEDURE WriteInlineRtf(s: ARRAY OF CHAR);
VAR
  i, n, j, k, cp, nbytes : INTEGER;
  c           : CHAR;
  txt, url    : ARRAY 512 OF CHAR;
BEGIN
  bold := FALSE; ital := FALSE;
  i := 0; n := Strings.Length(s);
  WHILE i < n DO
    c := s[i];
    IF (c = '*') & (i + 1 < n) & (s[i+1] = '*') THEN
      IF bold THEN Wstr("\b0 ") ELSE Wstr("\b ") END;
      bold := ~bold; INC(i, 2)
    ELSIF c = '*' THEN
      IF ital THEN Wstr("\i0 ") ELSE Wstr("\i ") END;
      ital := ~ital; INC(i)
    ELSIF c = '`' THEN
      Wstr("{\f1\fs20 "); INC(i);
      WHILE (i < n) & (s[i] # '`') DO
        DecodeUtf8Cp(s, i, n, cp, nbytes); RtfEscCp(cp); INC(i, nbytes)
      END;
      Wch('}'); IF i < n THEN INC(i) END
    ELSIF c = '[' THEN
      j := i + 1; k := 0;
      WHILE (j < n) & (s[j] # ']') & (k < 511) DO
        txt[k] := s[j]; INC(j); INC(k)
      END;
      txt[k] := 0X;
      IF (j < n) & (s[j] = ']') & (j + 1 < n) & (s[j+1] = '(') THEN
        INC(j, 2); k := 0;
        WHILE (j < n) & (s[j] # ')') & (k < 511) DO
          url[k] := s[j]; INC(j); INC(k)
        END;
        url[k] := 0X;
        RtfEscStr(txt);
        Wstr(" ("); RtfEscStr(url); Wch(')');
        i := j + 1
      ELSE
        DecodeUtf8Cp(s, i, n, cp, nbytes); RtfEscCp(cp); INC(i, nbytes)
      END
    ELSE
      DecodeUtf8Cp(s, i, n, cp, nbytes); RtfEscCp(cp); INC(i, nbytes)
    END
  END;
  IF bold THEN Wstr("\b0 ") END;
  IF ital THEN Wstr("\i0 ") END
END WriteInlineRtf;

PROCEDURE EndParaRtf;
BEGIN IF inPara THEN Wstr("\par"); Wln; inPara := FALSE END END EndParaRtf;

PROCEDURE EndListRtf;
BEGIN inList := FALSE END EndListRtf;

PROCEDURE EndBQRtf;
BEGIN inBQ := FALSE END EndBQRtf;

PROCEDURE EmitTableRowRtf(s: ARRAY OF CHAR; isHeader: BOOLEAN);
VAR pos, i, cw: INTEGER; cell: ARRAY 512 OF CHAR; ns: ARRAY 16 OF CHAR;
BEGIN
  IF tableCols < 1 THEN tableCols := 1 END;
  cw := 9360 DIV tableCols;
  Wstr("\trowd\trgaph108\trleft0"); Wln;
  i := 1;
  WHILE i <= tableCols DO
    Wstr("\clbrdrt\brdrw10\brdrs\clbrdrl\brdrw10\brdrs\clbrdrb\brdrw10\brdrs\clbrdrr\brdrw10\brdrs\cellx");
    Strings.IntToStr(cw * i, ns); Wstr(ns); Wln;
    INC(i)
  END;
  pos := 0;
  WHILE GetCell(s, pos, cell) DO
    Wstr("\pard\intbl\f0\fs24 ");
    IF isHeader THEN Wstr("\b ") END;
    WriteInlineRtf(cell);
    IF isHeader THEN Wstr("\b0 ") END;
    Wstr("\cell"); Wln
  END;
  Wstr("\row"); Wln
END EmitTableRowRtf;

PROCEDURE EndTableRtf;
BEGIN
  IF inTable THEN
    IF inTableHead THEN
      tableCols := CountCols(tableHdr);
      EmitTableRowRtf(tableHdr, TRUE);
      inTableHead := FALSE
    END;
    inTable := FALSE
  END
END EndTableRtf;

PROCEDURE EndBlockRtf;
BEGIN EndParaRtf; EndListRtf; EndBQRtf; EndTableRtf END EndBlockRtf;

PROCEDURE RtfLine*(s: ARRAY OF CHAR);
VAR lvl, i, n: INTEGER; ns: ARRAY 8 OF CHAR; arg: ARRAY MaxLine OF CHAR;
BEGIN
  IF inCode THEN
    IF Strings.StartsWith(s, "```") THEN
      Wstr("\par\pard\f0\fs24\sb120 "); inCode := FALSE
    ELSE
      RtfEscStr(s);
      Wstr("\line ")
    END;
    RETURN
  END;

  IF Strings.StartsWith(s, "```") THEN
    EndBlockRtf;
    Wstr("\pard\f1\fs20\sb120\sa0 "); inCode := TRUE; RETURN
  END;

  n := Strings.Length(s);
  IF n = 0 THEN EndBlockRtf; RETURN END;

  lvl := 0;
  WHILE (lvl < 3) & (s[lvl] = '#') DO INC(lvl) END;
  IF (lvl > 0) & (s[lvl] = ' ') THEN
    EndBlockRtf;
    IF    lvl = 1 THEN Wstr("\pard\sb240\sa60\f2\fs40\b ")
    ELSIF lvl = 2 THEN Wstr("\pard\sb200\sa60\f2\fs32\b ")
    ELSE               Wstr("\pard\sb160\sa40\f2\fs26\b ")
    END;
    Strings.Extract(s, lvl + 1, n - lvl - 1, arg);
    WriteInlineRtf(arg);
    Wstr("\b0\par"); Wln; RETURN
  END;

  IF IsHRule(s) THEN
    EndBlockRtf;
    Wstr("\pard\brdrb\brdrs\brdrw10\brsp40\sb60\sa60 \par"); Wln; RETURN
  END;

  IF IsTableSep(s) THEN
    IF inTable & inTableHead THEN
      tableCols := CountCols(tableHdr);
      EmitTableRowRtf(tableHdr, TRUE);
      inTableHead := FALSE
    END;
    RETURN
  END;

  IF s[0] = '|' THEN
    IF ~inTable THEN
      EndBlockRtf;
      inTable := TRUE; inTableHead := TRUE;
      COPY(s, tableHdr)
    ELSIF inTableHead THEN
      tableCols := CountCols(tableHdr);
      EmitTableRowRtf(tableHdr, TRUE);
      inTableHead := FALSE;
      EmitTableRowRtf(s, FALSE)
    ELSE
      EmitTableRowRtf(s, FALSE)
    END;
    RETURN
  END;

  IF inTable THEN EndTableRtf END;

  IF s[0] = '>' THEN
    EndParaRtf; EndListRtf;
    IF ~inBQ THEN inBQ := TRUE END;
    IF (n > 1) & (s[1] = ' ') THEN Strings.Extract(s, 2, n - 2, arg)
    ELSE Strings.Extract(s, 1, n - 1, arg) END;
    Wstr("\pard\li720\sa60\f0\fs24\i "); WriteInlineRtf(arg);
    Wstr("\i0\par"); Wln; RETURN
  END;
  EndBQRtf;

  IF ((s[0] = '-') OR (s[0] = '*')) & (n > 1) & (s[1] = ' ') THEN
    EndParaRtf;
    IF ~inList OR listOrd THEN inList := TRUE; listOrd := FALSE END;
    Wstr("\pard\li360\fi-180\f0\fs24\sb0\sa60 -\tab ");
    Strings.Extract(s, 2, n - 2, arg); WriteInlineRtf(arg);
    Wstr("\par"); Wln; RETURN
  END;

  i := 0;
  WHILE (i < n) & (s[i] >= '0') & (s[i] <= '9') DO INC(i) END;
  IF (i > 0) & (i < n) & (s[i] = '.') & (i + 1 < n) & (s[i+1] = ' ') THEN
    EndParaRtf;
    IF ~inList OR ~listOrd THEN inList := TRUE; listOrd := TRUE; listN := 1 END;
    Wstr("\pard\li360\fi-180\f0\fs24\sb0\sa60 ");
    Strings.IntToStr(listN, ns); Wstr(ns); Wstr(".\tab ");
    INC(listN);
    Strings.Extract(s, i + 2, n - i - 2, arg); WriteInlineRtf(arg);
    Wstr("\par"); Wln; RETURN
  END;

  EndListRtf;
  IF ~inPara THEN Wstr("\pard\sb0\sa120\f0\fs24 "); inPara := TRUE END;
  WriteInlineRtf(s); Wch(' ')
END RtfLine;

PROCEDURE RtfHeader*;
BEGIN
  Wstr("{\rtf1\ansi\ansicpg1252\deff0"); Wln;
  Wstr("{\fonttbl"); Wln;
  Wstr("{\f0\froman\fcharset0 Times New Roman;}"); Wln;
  Wstr("{\f1\fmodern\fcharset0 Courier New;}"); Wln;
  Wstr("{\f2\fswiss\fcharset0 Arial;}}"); Wln;
  Wstr("\uc1\widowctrl\hyphauto\f0\fs24 "); Wln
END RtfHeader;

PROCEDURE RtfFooter*;
BEGIN EndBlockRtf; Wch('}'); Wln END RtfFooter;

(* ── RTF, manuscript mode ─────────────────────────────────
   Standard Manuscript Format: 12pt Times New Roman, double-spaced,
   1-inch margins, first-line indent, chapter headings (level-1 #) on
   their own page, *italic*/**bold** emphasis, smart typography (curly
   quotes, em dash, ellipsis), ".."-prefixed note lines stripped. Every
   non-blank, non-note line is its own complete paragraph. *)

PROCEDURE MsUni(codePoint: INTEGER; fallback: CHAR);
VAR tmp: ARRAY 16 OF CHAR;
BEGIN
  Wstr("\u"); Strings.IntToStr(codePoint, tmp); Wstr(tmp);
  Wch(' '); Wch(fallback)
END MsUni;

(* Whether a quote/apostrophe at this point opens (rather than closes),
   judged by the previous code point — matches pstar's normalize::
   opens_quote: start of text, whitespace, or an opening bracket/dash.
   prevCp < 0 is the start-of-text sentinel. *)
PROCEDURE MsOpensQuote(prevCp: INTEGER): BOOLEAN;
BEGIN
  RETURN (prevCp < 0) OR (prevCp = ORD(' ')) OR (prevCp = 9) OR (prevCp = 10) OR
         (prevCp = ORD('(')) OR (prevCp = ORD('[')) OR (prevCp = ORD('{')) OR
         (prevCp = 8212) OR (prevCp = 8211)
END MsOpensQuote;

(* Render a heading title from byte `from` on: smart typography (dash
   runs, ellipsis, curly quotes) but no *italic*/**bold** emphasis —
   matches pstar's heading path (normalize::smart_typography run over
   the title string, then escape_rtf; headings never scan for Markdown
   emphasis markers). Quote open/close here tracks the *substituted*
   previous character, not the raw source one — e.g. a quote right
   after a freshly-collapsed em dash opens — because pstar's heading
   renderer threads `prev` through the output stream, unlike its body
   renderer (see MsBody). *)
PROCEDURE MsTitle(s: ARRAY OF CHAR; from: INTEGER);
VAR k, len, n, run, cp, prevCp: INTEGER;
BEGIN
  len := Strings.Length(s);
  k := from; prevCp := -1;
  WHILE k < len DO
    IF s[k] = '-' THEN
      run := 0;
      WHILE (k + run < len) & (s[k + run] = '-') DO INC(run) END;
      IF run >= 2 THEN
        MsUni(8212, '-'); prevCp := 8212; INC(k, run)
      ELSE
        RtfEscCp(ORD('-')); prevCp := ORD('-'); INC(k)
      END
    ELSIF (s[k] = '.') & (k + 2 < len) & (s[k + 1] = '.') & (s[k + 2] = '.') THEN
      MsUni(8230, '.'); prevCp := 8230; INC(k, 3)
    ELSIF s[k] = 22X THEN
      IF MsOpensQuote(prevCp) THEN MsUni(8220, 22X); prevCp := 8220
      ELSE MsUni(8221, 22X); prevCp := 8221
      END;
      INC(k)
    ELSIF s[k] = 27X THEN
      IF MsOpensQuote(prevCp) THEN MsUni(8216, 27X); prevCp := 8216
      ELSE MsUni(8217, 27X); prevCp := 8217
      END;
      INC(k)
    ELSE
      DecodeUtf8Cp(s, k, len, cp, n);
      RtfEscCp(cp); prevCp := cp; INC(k, n)
    END
  END
END MsTitle;

(* Render a body paragraph line with *italic*/**bold** and smart
   typography (em dash, ellipsis, curly quotes/apostrophes). Quote
   open/close tracks the *raw source* previous character — matches
   pstar's body-paragraph renderer (normalize::smart_char is fed
   `source[i-1]`, the pre-substitution char, not the curly output —
   so e.g. a quote right after two raw hyphens still closes, since
   the immediate predecessor is a plain '-', not a curly em dash).
   Markdown emphasis markers (`*`, `**`) are transparent to this
   tracking, same as pstar's marker-stripped `source` array: they are
   consumed without updating prevCp. *)
PROCEDURE MsBody(s: ARRAY OF CHAR);
VAR k, len, n, run, cp, prevCp: INTEGER; msBold, msItal: BOOLEAN;
BEGIN
  msBold := FALSE; msItal := FALSE;
  len := Strings.Length(s);
  k := 0; prevCp := -1;
  WHILE k < len DO
    IF (s[k] = '*') & (k + 1 < len) & (s[k + 1] = '*') THEN
      IF msBold THEN Wstr("\b0 ") ELSE Wstr("\b ") END;
      msBold := ~msBold; INC(k, 2)
    ELSIF s[k] = '*' THEN
      IF msItal THEN Wstr("\i0 ") ELSE Wstr("\i ") END;
      msItal := ~msItal; INC(k)
    ELSIF s[k] = '-' THEN
      run := 0;
      WHILE (k + run < len) & (s[k + run] = '-') DO INC(run) END;
      IF run >= 2 THEN
        MsUni(8212, '-'); prevCp := ORD('-'); INC(k, run)
      ELSE
        RtfEscCp(ORD('-')); prevCp := ORD('-'); INC(k)
      END
    ELSIF (s[k] = '.') & (k + 2 < len) & (s[k + 1] = '.') & (s[k + 2] = '.') THEN
      MsUni(8230, '.'); prevCp := ORD('.'); INC(k, 3)   (* ellipsis *)
    ELSIF s[k] = 22X THEN             (* " double quote *)
      IF MsOpensQuote(prevCp) THEN MsUni(8220, 22X)     (* open " *)
      ELSE MsUni(8221, 22X)                             (* close " *)
      END;
      prevCp := ORD(22X); INC(k)
    ELSIF s[k] = 27X THEN             (* ' apostrophe / single quote *)
      IF MsOpensQuote(prevCp) THEN MsUni(8216, 27X)     (* open ' *)
      ELSE MsUni(8217, 27X)                             (* apostrophe / close ' *)
      END;
      prevCp := ORD(27X); INC(k)
    ELSE
      DecodeUtf8Cp(s, k, len, cp, n);
      RtfEscCp(cp); prevCp := cp; INC(k, n)
    END
  END;
  IF msBold THEN Wstr("\b0 ") END;
  IF msItal THEN Wstr("\i0 ") END
END MsBody;

PROCEDURE RtfManuscriptHeader*;
BEGIN
  Wstr("{\rtf1\ansi\ansicpg1252\deff0\deflang1033"); Wln;
  Wstr("{\fonttbl{\f0\froman\fcharset0 Times New Roman;}"); Wln;
  Wstr("{\f1\fmodern\fcharset0 Courier New;}}"); Wln;
  Wstr("\viewkind4\uc1"); Wln;
  Wstr("\margl1440\margr1440\margt1440\margb1440"); Wln
END RtfManuscriptHeader;

PROCEDURE RtfManuscriptLine*(s: ARRAY OF CHAR);
VAR lev, len, j: INTEGER;
BEGIN
  len := Strings.Length(s);
  IF (s[0] = '.') & (s[1] = '.') THEN
    (* note line: skip *)
  ELSIF len = 0 THEN
    (* blank line: skip — SMF uses first-line indent, not blank separators *)
  ELSE
    lev := 0;
    WHILE (lev < len) & (s[lev] = '#') DO INC(lev) END;
    IF (lev > 0) & (s[lev] = ' ') THEN
      IF lev = 1 THEN
        (* Chapter: page break (except first) + 9 blank lines + centred bold *)
        IF ~msFirst THEN Wstr("\page"); Wln END;
        FOR j := 1 TO 9 DO
          Wstr("\pard\plain\f0\fs24\sl480\slmult1\par"); Wln
        END;
        Wstr("\pard\plain\qc\b\f0\fs24 ");
        MsTitle(s, 2);
        Wstr("\b0\par"); Wln
      ELSE
        (* Sub-heading: bold body paragraph *)
        Wstr("\pard\plain\f0\fs24\ql\sl480\slmult1\fi720 \b ");
        MsTitle(s, lev + 1);
        Wstr("\b0\par"); Wln
      END
    ELSE
      (* Body paragraph *)
      Wstr("\pard\plain\f0\fs24\ql\sl480\slmult1\fi720 ");
      MsBody(s);
      Wstr("\par"); Wln
    END;
    msFirst := FALSE
  END
END RtfManuscriptLine;

PROCEDURE RtfManuscriptFooter*;
BEGIN Wstr("}"); Wln END RtfManuscriptFooter;

(* ── EPUB ─────────────────────────────────────────────────
   Minimal EPUB 3 content generation, modeled on PerfectStar 2k's
   epub.rs: an unstyled chapterN.xhtml per level-1 (#) heading (every
   heading level h1-h6, paragraphs, smart typography,
   *italic*/**bold**/`code` spans, ".."-notes stripped — the reading
   system supplies its own stylesheet) plus a flat nav.xhtml linking
   every heading by a shared "heading-N" counter. As documented at the
   top of the file, only the XML text comes from here; ZIP assembly
   (mimetype/META-INF/container.xml/OEBPS/package.opf/chapterN.xhtml/
   nav.xhtml, with per-entry CRC-32) is caller bookkeeping layered
   atop SetSink, the same as for the RTF/HTML renderers above. *)

PROCEDURE XmlEscCp(cp: INTEGER);
(* Escape one already-decoded code point for XML/XHTML text: the five
   predefined entities, plain ASCII verbatim, and everything else
   re-encoded as UTF-8 bytes — matches pstar's escape_xml, except XML
   has no RTF-style \uN fallback to carry, so a non-ASCII code point
   is simply its own UTF-8 sequence. *)
VAR b: INTEGER;
BEGIN
  IF    cp = ORD('&') THEN Wstr("&amp;")
  ELSIF cp = ORD('<') THEN Wstr("&lt;")
  ELSIF cp = ORD('>') THEN Wstr("&gt;")
  ELSIF cp = ORD('"') THEN Wstr("&quot;")
  ELSIF cp = ORD(27X) THEN Wstr("&apos;")
  ELSIF cp < 80H THEN Wch(CHR(cp))
  ELSIF cp < 800H THEN
    Wch(CHR(0C0H + cp DIV 40H)); Wch(CHR(80H + cp MOD 40H))
  ELSIF cp < 10000H THEN
    b := cp DIV 40H;
    Wch(CHR(0E0H + cp DIV 1000H));
    Wch(CHR(80H + b MOD 40H));
    Wch(CHR(80H + cp MOD 40H))
  ELSE
    b := cp DIV 40H;
    Wch(CHR(0F0H + cp DIV 40000H));
    Wch(CHR(80H + (b DIV 40H) MOD 40H));
    Wch(CHR(80H + b MOD 40H));
    Wch(CHR(80H + cp MOD 40H))
  END
END XmlEscCp;

PROCEDURE EpubEscStr(buf: ARRAY OF CHAR);
(* Escape a whole NUL-terminated string — used for the fixed <title>
   text the caller has no per-line context for. *)
VAR k, blen, cp, nbytes: INTEGER;
BEGIN
  blen := Strings.Length(buf); k := 0;
  WHILE k < blen DO
    DecodeUtf8Cp(buf, k, blen, cp, nbytes); XmlEscCp(cp); INC(k, nbytes)
  END
END EpubEscStr;

(* Render a heading title from byte `from` on: smart typography only,
   no *italic*/**bold**/`code` — matches pstar's heading path
   (normalize::smart_typography over the raw title; headings never
   scan for Markdown emphasis markers). Quote open/close tracks the
   *substituted* previous character, exactly like MsTitle. *)
PROCEDURE EpubTitle(s: ARRAY OF CHAR; from: INTEGER);
VAR k, len, n, run, cp, prevCp: INTEGER;
BEGIN
  len := Strings.Length(s);
  k := from; prevCp := -1;
  WHILE k < len DO
    IF s[k] = '-' THEN
      run := 0;
      WHILE (k + run < len) & (s[k + run] = '-') DO INC(run) END;
      IF run >= 2 THEN
        XmlEscCp(8212); prevCp := 8212; INC(k, run)
      ELSE
        XmlEscCp(ORD('-')); prevCp := ORD('-'); INC(k)
      END
    ELSIF (s[k] = '.') & (k + 2 < len) & (s[k + 1] = '.') & (s[k + 2] = '.') THEN
      XmlEscCp(8230); prevCp := 8230; INC(k, 3)
    ELSIF s[k] = 22X THEN
      IF MsOpensQuote(prevCp) THEN XmlEscCp(8220); prevCp := 8220
      ELSE XmlEscCp(8221); prevCp := 8221
      END;
      INC(k)
    ELSIF s[k] = 27X THEN
      IF MsOpensQuote(prevCp) THEN XmlEscCp(8216); prevCp := 8216
      ELSE XmlEscCp(8217); prevCp := 8217
      END;
      INC(k)
    ELSE
      DecodeUtf8Cp(s, k, len, cp, n);
      XmlEscCp(cp); prevCp := cp; INC(k, n)
    END
  END
END EpubTitle;

(* Render a body paragraph line: *italic*/**bold**/`code` spans plus
   smart typography (em dash, ellipsis, curly quotes/apostrophes),
   suppressed inside `code`. Quote open/close tracks the *raw source*
   previous character, exactly like MsBody. *)
PROCEDURE EpubBody(s: ARRAY OF CHAR);
VAR k, len, n, run, cp, prevCp: INTEGER; epBold, epItal: BOOLEAN;
BEGIN
  epBold := FALSE; epItal := FALSE;
  len := Strings.Length(s);
  k := 0; prevCp := -1;
  WHILE k < len DO
    IF (s[k] = '*') & (k + 1 < len) & (s[k + 1] = '*') THEN
      IF epBold THEN Wstr("</strong>") ELSE Wstr("<strong>") END;
      epBold := ~epBold; INC(k, 2)
    ELSIF s[k] = '*' THEN
      IF epItal THEN Wstr("</em>") ELSE Wstr("<em>") END;
      epItal := ~epItal; INC(k)
    ELSIF s[k] = '`' THEN
      Wstr("<code>"); INC(k);
      WHILE (k < len) & (s[k] # '`') DO
        DecodeUtf8Cp(s, k, len, cp, n); XmlEscCp(cp); INC(k, n)
      END;
      Wstr("</code>"); IF k < len THEN INC(k) END
    ELSIF s[k] = '-' THEN
      run := 0;
      WHILE (k + run < len) & (s[k + run] = '-') DO INC(run) END;
      IF run >= 2 THEN
        XmlEscCp(8212); prevCp := ORD('-'); INC(k, run)
      ELSE
        XmlEscCp(ORD('-')); prevCp := ORD('-'); INC(k)
      END
    ELSIF (s[k] = '.') & (k + 2 < len) & (s[k + 1] = '.') & (s[k + 2] = '.') THEN
      XmlEscCp(8230); prevCp := ORD('.'); INC(k, 3)
    ELSIF s[k] = 22X THEN
      IF MsOpensQuote(prevCp) THEN XmlEscCp(8220) ELSE XmlEscCp(8221) END;
      prevCp := ORD(22X); INC(k)
    ELSIF s[k] = 27X THEN
      IF MsOpensQuote(prevCp) THEN XmlEscCp(8216) ELSE XmlEscCp(8217) END;
      prevCp := ORD(27X); INC(k)
    ELSE
      DecodeUtf8Cp(s, k, len, cp, n);
      XmlEscCp(cp); prevCp := cp; INC(k, n)
    END
  END;
  IF epBold THEN Wstr("</strong>") END;
  IF epItal THEN Wstr("</em>") END
END EpubBody;

PROCEDURE EpubNavSink(c: CHAR);
(* WriteProc that appends to epubNavBuf instead of the real sink —
   temporarily installed by EpubLine (via SetSink) so a heading's
   <li> can be rendered into the accumulator with the exact same
   EpubTitle call used for its content.xhtml <hN>, then restored. *)
BEGIN
  IF epubNavLen < EpubNavBufSize - 1 THEN
    epubNavBuf[epubNavLen] := c; INC(epubNavLen);
    epubNavBuf[epubNavLen] := 0X
  END
END EpubNavSink;

PROCEDURE EpubXhtmlStart(title: ARRAY OF CHAR);
BEGIN
  Wstr('<?xml version="1.0" encoding="UTF-8"?>'); Wln;
  Wstr("<!DOCTYPE html>"); Wln;
  Wstr('<html xmlns="http://www.w3.org/1999/xhtml" ');
  Wstr('xmlns:epub="http://www.idpf.org/2007/ops" lang="en">'); Wln;
  Wstr('<head><meta charset="utf-8"/><title>');
  EpubEscStr(title);
  Wstr("</title></head><body>"); Wln
END EpubXhtmlStart;

PROCEDURE EpubMimetype*;
(* The ZIP entry name is "mimetype" (written by the caller); this is
   just its exact, unterminated content — no trailing newline. *)
BEGIN Wstr("application/epub+zip") END EpubMimetype;

PROCEDURE EpubContainerXml*;
BEGIN
  Wstr('<?xml version="1.0" encoding="UTF-8"?>'); Wln;
  Wstr('<container version="1.0" ');
  Wstr('xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'); Wln;
  Wstr("<rootfiles>"); Wln;
  Wstr('<rootfile full-path="OEBPS/package.opf" ');
  Wstr('media-type="application/oebps-package+xml"/>'); Wln;
  Wstr("</rootfiles>"); Wln;
  Wstr("</container>"); Wln
END EpubContainerXml;

PROCEDURE EpubPackageOpf*(chapterCount: INTEGER);
(* Fixed, non-derived metadata — same simplification as pstar's own
   package.opf (a static string, not filled in from the document) —
   except the manifest/spine, which list one chapterN.xhtml item per
   chapter the caller actually wrote (see EpubStartsChapter/
   EpubBeginChapter), in reading order. *)
VAR i: INTEGER; num: ARRAY 16 OF CHAR; n: INTEGER;
BEGIN
  n := chapterCount; IF n < 1 THEN n := 1 END;
  Wstr('<?xml version="1.0" encoding="UTF-8"?>'); Wln;
  Wstr('<package xmlns="http://www.idpf.org/2007/opf" version="3.0" ');
  Wstr('unique-identifier="book-id">'); Wln;
  Wstr('<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'); Wln;
  Wstr('<dc:identifier id="book-id">urn:uuid:markdown-export</dc:identifier>'); Wln;
  Wstr("<dc:title>Markdown Export</dc:title>"); Wln;
  Wstr("<dc:language>en</dc:language>"); Wln;
  Wstr('<meta property="dcterms:modified">1980-01-01T00:00:00Z</meta>'); Wln;
  Wstr("</metadata>"); Wln;
  Wstr("<manifest>"); Wln;
  i := 1;
  WHILE i <= n DO
    Strings.IntToStr(i, num);
    Wstr('<item id="chapter'); Wstr(num); Wstr('" href="chapter'); Wstr(num);
    Wstr('.xhtml" media-type="application/xhtml+xml"/>'); Wln;
    INC(i)
  END;
  Wstr('<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" ');
  Wstr('properties="nav"/>'); Wln;
  Wstr("</manifest>"); Wln;
  Wstr("<spine>"); Wln;
  i := 1;
  WHILE i <= n DO
    Strings.IntToStr(i, num);
    Wstr('<itemref idref="chapter'); Wstr(num); Wstr('"/>'); Wln;
    INC(i)
  END;
  Wstr("</spine>"); Wln;
  Wstr("</package>"); Wln
END EpubPackageOpf;

PROCEDURE EpubContentHeader*;
BEGIN EpubXhtmlStart("Markdown Export") END EpubContentHeader;

PROCEDURE EpubContentFooter*;
BEGIN Wstr("</body></html>"); Wln END EpubContentFooter;

PROCEDURE EpubStartsChapter*(s: ARRAY OF CHAR): BOOLEAN;
(* TRUE iff line s is a level-1 (#) heading that should begin a new
   chapter file — i.e. the current chapter file already holds some
   content, so this heading isn't just its opening line. A pure check
   (no state changes): the caller tests it before EpubLine so it can
   close the current chapter file and open the next one first, then
   call EpubBeginChapter and EpubLine for this same line. *)
VAR lev: INTEGER;
BEGIN
  lev := 0;
  WHILE (lev < 6) & (s[lev] = '#') DO INC(lev) END;
  RETURN (lev = 1) & (s[lev] = ' ') & epubChapterHasContent
END EpubStartsChapter;

PROCEDURE EpubBeginChapter*;
(* Advance to the next chapter file — call once, right after closing
   the previous chapterN.xhtml and opening/SetSink'ing the next one,
   and before the EpubContentHeader/EpubLine call for the heading that
   triggered EpubStartsChapter. *)
BEGIN
  INC(epubChapterN); epubChapterHasContent := FALSE
END EpubBeginChapter;

PROCEDURE EpubChapterNum*(): INTEGER;
(* The chapter file currently being written (1-based); once the whole
   document has been streamed through EpubLine, this is also the total
   chapter count, for EpubPackageOpf's manifest/spine. *)
BEGIN RETURN epubChapterN END EpubChapterNum;

PROCEDURE EpubLine*(s: ARRAY OF CHAR);
VAR lev, len, n: INTEGER; num, chNum: ARRAY 16 OF CHAR; savedSink: WriteProc;
BEGIN
  len := Strings.Length(s);
  IF (s[0] = '.') & (s[1] = '.') THEN
    (* note line: skip *)
  ELSIF len = 0 THEN
    (* blank line: skip *)
  ELSE
    epubChapterHasContent := TRUE;
    lev := 0;
    WHILE (lev < 6) & (s[lev] = '#') DO INC(lev) END;
    IF (lev > 0) & (s[lev] = ' ') THEN
      INC(epubHeadingN); Strings.IntToStr(epubHeadingN, num);
      Strings.IntToStr(epubChapterN, chNum);

      (* chapterN.xhtml: <hN id="heading-K">title</hN> *)
      Wch('<'); Wch('h'); Wch(CHR(ORD('0') + lev));
      Wstr(' id="heading-'); Wstr(num); Wstr('">');
      EpubTitle(s, lev + 1);
      Wch('<'); Wch('/'); Wch('h'); Wch(CHR(ORD('0') + lev)); Wch('>'); Wln;

      (* nav.xhtml <li>, rendered into the internal accumulator by
         swapping in EpubNavSink for the duration of this one entry *)
      savedSink := sink; SetSink(EpubNavSink);
      Wstr('<li><a href="chapter'); Wstr(chNum);
      Wstr('.xhtml#heading-'); Wstr(num); Wstr('">');
      EpubTitle(s, lev + 1);
      Wstr("</a></li>"); Wln;
      SetSink(savedSink)
    ELSE
      Wstr("<p>"); EpubBody(s); Wstr("</p>"); Wln
    END
  END
END EpubLine;

PROCEDURE EpubNavXhtml*;
(* Renders the complete nav.xhtml document — including the <li>
   entries EpubLine accumulated during the EpubContentHeader/EpubLine/
   EpubContentFooter pass — to whatever sink is current, so the
   caller should SetSink to the nav.xhtml destination first. *)
VAR i: INTEGER;
BEGIN
  EpubXhtmlStart("Contents");
  Wstr('<nav epub:type="toc" id="toc"><h1>Contents</h1><ol>'); Wln;
  i := 0; WHILE epubNavBuf[i] # 0X DO Wch(epubNavBuf[i]); INC(i) END;
  Wstr("</ol></nav>"); Wln;
  Wstr("</body></html>"); Wln
END EpubNavXhtml;

END Markdown.
