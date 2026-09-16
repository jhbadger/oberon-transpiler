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
 *)

IMPORT Strings;

CONST
  MaxLine* = 4096;

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
  msFirst := TRUE
END Reset;

PROCEDURE IsWordChar(c: CHAR): BOOLEAN;
BEGIN
  RETURN ((c >= 'a') & (c <= 'z')) OR ((c >= 'A') & (c <= 'Z'))
      OR ((c >= '0') & (c <= '9')) OR (c = '_')
END IsWordChar;

(* ── Generic markdown structure ──────────────────────────
   No output-format dependency; usable by any renderer. *)

PROCEDURE IsHRule*(s: ARRAY OF CHAR): BOOLEAN;
VAR i: INTEGER; c: CHAR;
BEGIN
  c := s[0];
  IF (c # '-') & (c # '*') & (c # '_') THEN RETURN FALSE END;
  i := 0;
  WHILE (s[i] = c) OR (s[i] = ' ') DO INC(i) END;
  RETURN (s[i] = 0X) & (i >= 3)
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

PROCEDURE WriteHex2(n: INTEGER);
VAR hi, lo: INTEGER;
BEGIN
  hi := n DIV 16; lo := n MOD 16;
  IF hi < 10 THEN Wch(CHR(ORD('0') + hi)) ELSE Wch(CHR(ORD('a') + hi - 10)) END;
  IF lo < 10 THEN Wch(CHR(ORD('0') + lo)) ELSE Wch(CHR(ORD('a') + lo - 10)) END
END WriteHex2;

PROCEDURE RtfEsc(c: CHAR);
BEGIN
  IF    c = '\' THEN Wstr("\\")
  ELSIF c = '{' THEN Wstr("\{")
  ELSIF c = '}' THEN Wstr("\}")
  ELSIF ORD(c) > 127 THEN Wstr("\'"); WriteHex2(ORD(c))
  ELSE  Wch(c)
  END
END RtfEsc;

PROCEDURE WriteInlineRtf(s: ARRAY OF CHAR);
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
      IF bold THEN Wstr("\b0 ") ELSE Wstr("\b ") END;
      bold := ~bold; INC(i, 2)
    ELSIF c = '*' THEN
      IF ital THEN Wstr("\i0 ") ELSE Wstr("\i ") END;
      ital := ~ital; INC(i)
    ELSIF c = '`' THEN
      Wstr("{\f1\fs20 "); INC(i);
      WHILE (i < n) & (s[i] # '`') DO RtfEsc(s[i]); INC(i) END;
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
        k := 0; WHILE txt[k] # 0X DO RtfEsc(txt[k]); INC(k) END;
        Wstr(" ("); k := 0; WHILE url[k] # 0X DO RtfEsc(url[k]); INC(k) END; Wch(')');
        i := j + 1
      ELSE
        RtfEsc(c); INC(i)
      END
    ELSE
      RtfEsc(c); INC(i)
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
      i := 0; WHILE s[i] # 0X DO RtfEsc(s[i]); INC(i) END;
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
  Wstr("\widowctrl\hyphauto\f0\fs24 "); Wln
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

PROCEDURE MsEsc(c: CHAR);
VAR tmp: ARRAY 16 OF CHAR;
BEGIN
  IF    c = 5CH THEN Wstr("\\\\")
  ELSIF c = 7BH THEN Wstr("\{")
  ELSIF c = 7DH THEN Wstr("\}")
  ELSIF c = 9X  THEN Wstr("\tab ")
  ELSIF ORD(c) >= 128 THEN
    Wstr("\u"); Strings.IntToStr(ORD(c) - 256, tmp); Wstr(tmp);
    Wch(' '); Wch('?')
  ELSE Wch(c)
  END
END MsEsc;

(* Render a heading title from byte `from` on: escape only, no emphasis
   or smart typography. *)
PROCEDURE MsTitle(s: ARRAY OF CHAR; from: INTEGER);
VAR k, len: INTEGER;
BEGIN
  len := Strings.Length(s);
  FOR k := from TO len - 1 DO MsEsc(s[k]) END
END MsTitle;

(* Render a body paragraph line with *italic*/**bold** and smart
   typography (em dash, ellipsis, curly quotes/apostrophes). *)
PROCEDURE MsBody(s: ARRAY OF CHAR);
VAR k, len: INTEGER; c, prev: CHAR; msBold, msItal: BOOLEAN;
BEGIN
  msBold := FALSE; msItal := FALSE;
  len := Strings.Length(s);
  k := 0; prev := ' ';
  WHILE k < len DO
    c := s[k];
    IF (c = '*') & (k + 1 < len) & (s[k + 1] = '*') THEN
      IF msBold THEN Wstr("\b0 ") ELSE Wstr("\b ") END;
      msBold := ~msBold; INC(k, 2)
    ELSIF c = '*' THEN
      IF msItal THEN Wstr("\i0 ") ELSE Wstr("\i ") END;
      msItal := ~msItal; INC(k)
    ELSIF (c = '-') & (k + 1 < len) & (s[k + 1] = '-') THEN
      MsUni(8212, '-'); INC(k, 2)   (* em dash *)
    ELSIF (c = '.') & (k + 1 < len) & (s[k + 1] = '.') &
          (k + 2 < len) & (s[k + 2] = '.') THEN
      MsUni(8230, '.'); INC(k, 3)   (* ellipsis *)
    ELSIF c = 22X THEN             (* " double quote *)
      IF IsWordChar(prev) OR (prev = '.') OR (prev = ',') OR
         (prev = '?') OR (prev = '!') OR (prev = 27X) OR (prev = ')') THEN
        MsUni(8221, 22X)            (* close " *)
      ELSE
        MsUni(8220, 22X)            (* open " *)
      END;
      prev := c; INC(k)
    ELSIF c = 27X THEN             (* ' apostrophe / single quote *)
      IF IsWordChar(prev) OR (prev = ',') OR (prev = '.') THEN
        MsUni(8217, 27X)            (* apostrophe / close ' *)
      ELSE
        MsUni(8216, 27X)            (* open ' *)
      END;
      prev := c; INC(k)
    ELSIF c = 5CH THEN Wstr("\\\\"); prev := c; INC(k)
    ELSIF c = 7BH THEN Wstr("\{");  prev := c; INC(k)
    ELSIF c = 7DH THEN Wstr("\}");  prev := c; INC(k)
    ELSE MsEsc(c); prev := c; INC(k)
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

END Markdown.
