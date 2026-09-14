MODULE Plume;
(*
 * plume - simple markdown to PDF/HTML/DOCX converter
 * Usage: plume [-o outfile] [--html|--pdf|--docx] <input.md>
 *   --html   native HTML output
 *   --pdf    PDF via pdflatex (default)
 *   --docx   Word document via pandoc
 *)

IMPORT Args, Strings, Files, Out, OS;

CONST
  LLEN    = 4096;
  MAXPG   = 50;
  FMTPDF  = 0;
  FMTHTML = 1;
  FMTDOCX = 2;
  PG_W    = 612;
  PG_H    = 792;
  PG_MAR  = 72;
  TX_W    = 468;
  TX_TOP  = 720;
  TX_BOT  = 72;
  FN_R    = 3;   (* Times-Roman object number *)
  FN_B    = 4;   (* Times-Bold *)
  FN_I    = 5;   (* Times-Italic *)
  FN_C    = 6;   (* Courier *)
  FN_H    = 7;   (* Helvetica-Bold *)

VAR
  inFile  : ARRAY LLEN OF CHAR;
  outFile : ARRAY LLEN OF CHAR;
  auxFile : ARRAY LLEN OF CHAR;
  fmt     : INTEGER;
  inF     : Files.File;
  outF    : Files.File;
  inR     : Files.Rider;
  outR    : Files.Rider;
  line    : ARRAY LLEN OF CHAR;
  arg     : ARRAY LLEN OF CHAR;
  cmd     : ARRAY LLEN OF CHAR;
  xref    : ARRAY 200 OF INTEGER;
  pgLen   : ARRAY MAXPG OF INTEGER;
  nPages  : INTEGER;
  curY    : INTEGER;
  pgBase  : INTEGER;
  inBT    : BOOLEAN;
  inPara  : BOOLEAN;
  inList  : BOOLEAN;
  listOrd : BOOLEAN;
  listN   : INTEGER;
  inCode  : BOOLEAN;
  inBQ    : BOOLEAN;
  bold    : BOOLEAN;
  ital    : BOOLEAN;

(* ── Output primitives ────────────────────────────────── *)

PROCEDURE Wch(c: CHAR);
BEGIN Files.Write(outR, c) END Wch;

PROCEDURE Wstr(s: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN i := 0; WHILE s[i] # 0X DO Files.Write(outR, s[i]); INC(i) END END Wstr;

PROCEDURE Wln;
BEGIN Wch(0AX) END Wln;

(* ── Utilities ────────────────────────────────────────── *)

PROCEDURE StripCR(VAR s: ARRAY OF CHAR);
VAR n: INTEGER;
BEGIN
  n := Strings.Length(s);
  IF (n > 0) & (s[n-1] = 0DX) THEN s[n-1] := 0X END
END StripCR;

PROCEDURE SetExt(base, ext: ARRAY OF CHAR; VAR out: ARRAY OF CHAR);
VAR i, dot: INTEGER;
BEGIN
  COPY(base, out);
  dot := -1;
  i := Strings.Length(out) - 1;
  WHILE i >= 0 DO
    IF out[i] = '.' THEN dot := i; i := -1
    ELSIF out[i] = '/' THEN i := -1
    ELSE DEC(i)
    END
  END;
  IF dot >= 0 THEN out[dot] := 0X END;
  Strings.Append(ext, out)
END SetExt;

(* ── HTML inline ──────────────────────────────────────── *)

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

PROCEDURE EndBlock;
BEGIN EndPara; EndList; EndBQ END EndBlock;

PROCEDURE IsHRule(s: ARRAY OF CHAR): BOOLEAN;
VAR i: INTEGER; c: CHAR;
BEGIN
  c := s[0];
  IF (c # '-') & (c # '*') & (c # '_') THEN RETURN FALSE END;
  i := 0;
  WHILE (s[i] = c) OR (s[i] = ' ') DO INC(i) END;
  RETURN (s[i] = 0X) & (i >= 3)
END IsHRule;

PROCEDURE ProcessLineHtml(s: ARRAY OF CHAR);
VAR lvl, i, n: INTEGER;
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
END ProcessLineHtml;

PROCEDURE WriteHtmlHeader;
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
  Wstr("</style></head><body>"); Wln
END WriteHtmlHeader;

PROCEDURE WriteHtmlFooter;
BEGIN EndBlock; Wstr("</body></html>"); Wln END WriteHtmlFooter;

(* ── RTF output ───────────────────────────────────────── *)

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

PROCEDURE EndBlockRtf;
BEGIN EndParaRtf; EndListRtf; EndBQRtf END EndBlockRtf;

PROCEDURE ProcessLineRtf(s: ARRAY OF CHAR);
VAR lvl, i, n: INTEGER; ns: ARRAY 8 OF CHAR;
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
END ProcessLineRtf;

PROCEDURE WriteRtfHeader;
BEGIN
  Wstr("{\rtf1\ansi\ansicpg1252\deff0"); Wln;
  Wstr("{\fonttbl"); Wln;
  Wstr("{\f0\froman\fcharset0 Times New Roman;}"); Wln;
  Wstr("{\f1\fmodern\fcharset0 Courier New;}"); Wln;
  Wstr("{\f2\fswiss\fcharset0 Arial;}}"); Wln;
  Wstr("\widowctrl\hyphauto\f0\fs24 "); Wln
END WriteRtfHeader;

PROCEDURE WriteRtfFooter;
BEGIN EndBlockRtf; Wch('}'); Wln END WriteRtfFooter;

(* ── PDF output ───────────────────────────────────────── *)
(*  Object layout:
    1=Catalog  2=Pages  3-7=Fonts
    8..8+MAXPG-1        = content streams (one per page)
    8+MAXPG..8+2*MAXPG-1 = stream length objects
    8+2*MAXPG..8+3*MAXPG-1 = page objects               *)

PROCEDURE WpdfInt(n: INTEGER);
VAR s: ARRAY 16 OF CHAR;
BEGIN Strings.IntToStr(n, s); Wstr(s) END WpdfInt;

PROCEDURE WobjStart(n: INTEGER);
BEGIN xref[n] := Files.Pos(outR); WpdfInt(n); Wstr(" 0 obj"); Wln END WobjStart;

PROCEDURE WobjEnd;
BEGIN Wstr("endobj"); Wln END WobjEnd;

PROCEDURE Wref(n: INTEGER);
BEGIN WpdfInt(n); Wstr(" 0 R") END Wref;

PROCEDURE PdfEscCh(c: CHAR);
BEGIN
  IF    c = '(' THEN Wstr("\(")
  ELSIF c = ')' THEN Wstr("\)")
  ELSIF c = '\' THEN Wstr("\\")
  ELSE  Wch(c)
  END
END PdfEscCh;

PROCEDURE BeginPdfPage;
VAR obj: INTEGER;
BEGIN
  IF nPages >= MAXPG THEN RETURN END;
  obj := 8 + nPages;
  WobjStart(obj);
  Wstr("<< /Length "); Wref(8 + MAXPG + nPages); Wstr(" >>"); Wln;
  Wstr("stream"); Wln;
  pgBase := Files.Pos(outR);
  Wstr("BT"); Wln; inBT := TRUE;
  curY := TX_TOP
END BeginPdfPage;

PROCEDURE EndPdfPage;
VAR len: INTEGER;
BEGIN
  IF ~inBT OR (nPages >= MAXPG) THEN RETURN END;
  Wstr("ET"); Wln; inBT := FALSE;
  len := Files.Pos(outR) - pgBase;
  Wstr("endstream"); Wln; WobjEnd;
  WobjStart(8 + MAXPG + nPages);
  WpdfInt(len); Wln; WobjEnd;
  pgLen[nPages] := len;
  INC(nPages)
END EndPdfPage;

PROCEDURE CheckPdfRoom(h: INTEGER);
BEGIN IF curY - h < TX_BOT THEN EndPdfPage; BeginPdfPage END END CheckPdfRoom;

PROCEDURE PdfSetFont(fontN, sz: INTEGER);
BEGIN Wstr("/F"); WpdfInt(fontN - 2); Wch(' '); WpdfInt(sz); Wstr(" Tf"); Wln END PdfSetFont;

PROCEDURE PdfTm(x, y: INTEGER);
BEGIN WpdfInt(x); Wch(' '); WpdfInt(y); Wstr(" Tm"); Wln END PdfTm;

PROCEDURE PdfApproxW(len, sz, fontN: INTEGER): INTEGER;
BEGIN
  IF fontN = FN_C THEN RETURN len * sz * 60 DIV 100
  ELSE RETURN len * sz * 55 DIV 100 END
END PdfApproxW;

(* Render inline markdown on current curY line, return approx end-x *)
PROCEDURE RenderPdfInline(s: ARRAY OF CHAR; baseFont, sz, indent: INTEGER);
VAR
  i, n, j, k, x : INTEGER;
  c, curF        : CHAR;
  fnt            : INTEGER;
  seg            : ARRAY 512 OF CHAR;

  PROCEDURE Flush;
  VAR m: INTEGER;
  BEGIN
    IF j = 0 THEN RETURN END;
    seg[j] := 0X;
    PdfTm(x, curY); PdfSetFont(fnt, sz);
    Wch('('); m := 0; WHILE seg[m] # 0X DO PdfEscCh(seg[m]); INC(m) END;
    Wstr(") Tj"); Wln;
    INC(x, PdfApproxW(j, sz, fnt));
    j := 0
  END Flush;

BEGIN
  x := PG_MAR + indent; fnt := baseFont; j := 0;
  i := 0; n := Strings.Length(s);
  WHILE i < n DO
    IF (s[i] = '*') & (i+1 < n) & (s[i+1] = '*') THEN
      Flush;
      IF fnt = FN_B THEN fnt := baseFont ELSE fnt := FN_B END;
      INC(i, 2)
    ELSIF s[i] = '*' THEN
      Flush;
      IF fnt = FN_I THEN fnt := baseFont ELSE fnt := FN_I END;
      INC(i)
    ELSIF s[i] = '`' THEN
      Flush; INC(i); k := 0;
      WHILE (i < n) & (s[i] # '`') & (k < 511) DO seg[k] := s[i]; INC(i); INC(k) END;
      seg[k] := 0X; IF i < n THEN INC(i) END;
      PdfTm(x, curY); PdfSetFont(FN_C, sz - 2);
      Wch('('); k := 0; WHILE seg[k] # 0X DO PdfEscCh(seg[k]); INC(k) END;
      Wstr(") Tj"); Wln;
      INC(x, PdfApproxW(k, sz - 2, FN_C))
    ELSIF s[i] = '[' THEN
      Flush; INC(i); k := 0;
      WHILE (i < n) & (s[i] # ']') & (k < 511) DO seg[k] := s[i]; INC(i); INC(k) END;
      seg[k] := 0X; IF i < n THEN INC(i) END;
      PdfTm(x, curY); PdfSetFont(fnt, sz);
      Wch('('); k := 0; WHILE seg[k] # 0X DO PdfEscCh(seg[k]); INC(k) END;
      Wstr(") Tj"); Wln;
      INC(x, PdfApproxW(k, sz, fnt));
      (* skip (url) *)
      IF (i < n) & (s[i] = '(') THEN
        WHILE (i < n) & (s[i] # ')') DO INC(i) END;
        IF i < n THEN INC(i) END
      END
    ELSE
      IF j < 511 THEN seg[j] := s[i]; INC(j) END;
      INC(i)
    END
  END;
  Flush
END RenderPdfInline;

PROCEDURE WrapPdf(s: ARRAY OF CHAR; baseFont, sz, indent, lineH: INTEGER);
VAR
  maxC, n, i, ls, lbase : INTEGER;
  frag : ARRAY LLEN OF CHAR;
BEGIN
  maxC := (TX_W - indent) * 100 DIV (sz * 55);
  n := Strings.Length(s); i := 0; lbase := 0; ls := -1;
  WHILE i < n DO
    IF s[i] = ' ' THEN ls := i END;
    IF i - lbase >= maxC THEN
      IF ls > lbase THEN
        Strings.Extract(s, lbase, ls - lbase, frag); lbase := ls + 1
      ELSE
        Strings.Extract(s, lbase, maxC, frag); lbase := i
      END;
      CheckPdfRoom(lineH);
      RenderPdfInline(frag, baseFont, sz, indent);
      DEC(curY, lineH); ls := -1
    END;
    INC(i)
  END;
  IF lbase < n THEN
    Strings.Extract(s, lbase, n - lbase, frag);
    CheckPdfRoom(lineH);
    RenderPdfInline(frag, baseFont, sz, indent);
    DEC(curY, lineH)
  END
END WrapPdf;

PROCEDURE RenderPdfRaw(s: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  PdfTm(PG_MAR, curY); PdfSetFont(FN_C, 10);
  Wch('('); i := 0; WHILE s[i] # 0X DO PdfEscCh(s[i]); INC(i) END;
  Wstr(") Tj"); Wln
END RenderPdfRaw;

PROCEDURE EndParaPdf;
BEGIN inPara := FALSE; inList := FALSE; inBQ := FALSE END EndParaPdf;

PROCEDURE ProcessLinePdf(s: ARRAY OF CHAR);
VAR lvl, i, n: INTEGER; ns: ARRAY 8 OF CHAR;
BEGIN
  IF inCode THEN
    IF Strings.StartsWith(s, "```") THEN inCode := FALSE
    ELSE
      CheckPdfRoom(12); RenderPdfRaw(s); DEC(curY, 12)
    END;
    RETURN
  END;

  IF Strings.StartsWith(s, "```") THEN
    EndParaPdf; inCode := TRUE; RETURN
  END;

  n := Strings.Length(s);
  IF n = 0 THEN EndParaPdf; RETURN END;

  lvl := 0;
  WHILE (lvl < 3) & (s[lvl] = '#') DO INC(lvl) END;
  IF (lvl > 0) & (s[lvl] = ' ') THEN
    EndParaPdf;
    Strings.Extract(s, lvl + 1, n - lvl - 1, arg);
    DEC(curY, 6);
    IF    lvl = 1 THEN CheckPdfRoom(26); RenderPdfInline(arg, FN_H, 20, 0); DEC(curY, 30)
    ELSIF lvl = 2 THEN CheckPdfRoom(22); RenderPdfInline(arg, FN_H, 16, 0); DEC(curY, 26)
    ELSE               CheckPdfRoom(18); RenderPdfInline(arg, FN_H, 14, 0); DEC(curY, 22)
    END;
    RETURN
  END;

  IF IsHRule(s) THEN
    EndParaPdf; DEC(curY, 6);
    Wstr("ET"); Wln;
    Wstr("0.5 w "); WpdfInt(PG_MAR); Wch(' '); WpdfInt(curY); Wstr(" m ");
    WpdfInt(PG_W - PG_MAR); Wch(' '); WpdfInt(curY); Wstr(" l S"); Wln;
    Wstr("BT"); Wln;
    DEC(curY, 10);
    RETURN
  END;

  IF s[0] = '>' THEN
    EndParaPdf; inBQ := TRUE;
    IF (n > 1) & (s[1] = ' ') THEN Strings.Extract(s, 2, n-2, arg)
    ELSE Strings.Extract(s, 1, n-1, arg) END;
    DEC(curY, 2);
    WrapPdf(arg, FN_I, 11, 36, 14);
    RETURN
  END;
  inBQ := FALSE;

  IF ((s[0] = '-') OR (s[0] = '*')) & (n > 1) & (s[1] = ' ') THEN
    IF inPara THEN inPara := FALSE END;
    inList := TRUE; listOrd := FALSE;
    CheckPdfRoom(14);
    PdfTm(PG_MAR + 6, curY); PdfSetFont(FN_R, 12);
    Wstr("(-) Tj"); Wln;
    Strings.Extract(s, 2, n - 2, arg);
    WrapPdf(arg, FN_R, 12, 24, 14);
    RETURN
  END;

  i := 0;
  WHILE (i < n) & (s[i] >= '0') & (s[i] <= '9') DO INC(i) END;
  IF (i > 0) & (i < n) & (s[i] = '.') & (i + 1 < n) & (s[i+1] = ' ') THEN
    IF inPara THEN inPara := FALSE END;
    inList := TRUE; listOrd := TRUE;
    CheckPdfRoom(14);
    Strings.IntToStr(listN, ns);
    PdfTm(PG_MAR + 4, curY); PdfSetFont(FN_R, 12);
    Wch('('); Wstr(ns); Wstr(".) Tj"); Wln;
    INC(listN);
    Strings.Extract(s, i + 2, n - i - 2, arg);
    WrapPdf(arg, FN_R, 12, 24, 14);
    RETURN
  END;

  IF inList THEN inList := FALSE; DEC(curY, 4) END;
  IF ~inPara THEN inPara := TRUE; DEC(curY, 2) END;
  WrapPdf(s, FN_R, 12, 0, 14)
END ProcessLinePdf;

PROCEDURE WritePdfHeader;
BEGIN Wstr("%PDF-1.4"); Wln END WritePdfHeader;

PROCEDURE WritePdfStructure;
VAR i, xrefStart, totalObj: INTEGER; s: ARRAY 16 OF CHAR;
BEGIN
  (* font objects 3-7 *)
  WobjStart(3); Wstr("<< /Type /Font /Subtype /Type1 /BaseFont /Times-Roman /Encoding /WinAnsiEncoding >>"); Wln; WobjEnd;
  WobjStart(4); Wstr("<< /Type /Font /Subtype /Type1 /BaseFont /Times-Bold /Encoding /WinAnsiEncoding >>"); Wln; WobjEnd;
  WobjStart(5); Wstr("<< /Type /Font /Subtype /Type1 /BaseFont /Times-Italic /Encoding /WinAnsiEncoding >>"); Wln; WobjEnd;
  WobjStart(6); Wstr("<< /Type /Font /Subtype /Type1 /BaseFont /Courier /Encoding /WinAnsiEncoding >>"); Wln; WobjEnd;
  WobjStart(7); Wstr("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>"); Wln; WobjEnd;

  (* page objects *)
  i := 0;
  WHILE i < nPages DO
    WobjStart(8 + 2*MAXPG + i);
    Wstr("<< /Type /Page /Parent 2 0 R"); Wln;
    Wstr("   /MediaBox [0 0 612 792]"); Wln;
    Wstr("   /Contents "); Wref(8 + i); Wln;
    Wstr("   /Resources << /Font <<"); Wln;
    Wstr("     /F1 3 0 R /F2 4 0 R /F3 5 0 R /F4 6 0 R /F5 7 0 R >> >> >>"); Wln;
    WobjEnd;
    INC(i)
  END;

  (* Pages object *)
  WobjStart(2);
  Wstr("<< /Type /Pages /Count "); WpdfInt(nPages); Wln;
  Wstr("   /Kids [");
  i := 0;
  WHILE i < nPages DO
    Wref(8 + 2*MAXPG + i); Wch(' '); INC(i)
  END;
  Wstr("] >>"); Wln; WobjEnd;

  (* Catalog *)
  WobjStart(1);
  Wstr("<< /Type /Catalog /Pages 2 0 R >>"); Wln;
  WobjEnd;

  (* xref *)
  xrefStart := Files.Pos(outR);
  totalObj := 8 + 3*MAXPG + 1;
  Wstr("xref"); Wln;
  Wstr("0 "); WpdfInt(totalObj); Wln;
  (* entry 0: free head *)
  Wstr("0000000000 65535 f "); Wch(0DX); Wch(0AX);
  i := 1;
  WHILE i < totalObj DO
    IF xref[i] > 0 THEN
      (* write 10-digit offset *)
      Strings.IntToStr(xref[i], s);
      cmd[0] := 0X;
      WHILE Strings.Length(cmd) + Strings.Length(s) < 10 DO Strings.Append("0", cmd) END;
      Strings.Append(s, cmd);
      Wstr(cmd);
      Wstr(" 00000 n "); Wch(0DX); Wch(0AX)
    ELSE
      Wstr("0000000000 65535 f "); Wch(0DX); Wch(0AX)
    END;
    INC(i)
  END;
  (* trailer *)
  Wstr("trailer"); Wln;
  Wstr("<< /Size "); WpdfInt(totalObj);
  Wstr(" /Root 1 0 R >>"); Wln;
  Wstr("startxref"); Wln;
  WpdfInt(xrefStart); Wln;
  Wstr("%%EOF"); Wln
END WritePdfStructure;

(* ── LaTeX inline ─────────────────────────────────────── *)

PROCEDURE TexEsc(c: CHAR);
BEGIN
  IF    c = '#'  THEN Wstr("\#")
  ELSIF c = '$'  THEN Wstr("\$")
  ELSIF c = '%'  THEN Wstr("\%")
  ELSIF c = '&'  THEN Wstr("\&")
  ELSIF c = '_'  THEN Wstr("\_")
  ELSIF c = '{'  THEN Wstr("\{")
  ELSIF c = '}'  THEN Wstr("\}")
  ELSIF c = '~'  THEN Wstr("\textasciitilde{}")
  ELSIF c = '^'  THEN Wstr("\textasciicircum{}")
  ELSIF c = '\'  THEN Wstr("\textbackslash{}")
  ELSE  Wch(c)
  END
END TexEsc;

PROCEDURE WriteInlineTex(s: ARRAY OF CHAR);
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
      IF bold THEN Wch('}') ELSE Wstr("\textbf{") END;
      bold := ~bold; INC(i, 2)
    ELSIF c = '*' THEN
      IF ital THEN Wch('}') ELSE Wstr("\textit{") END;
      ital := ~ital; INC(i)
    ELSIF c = '`' THEN
      Wstr("\texttt{"); INC(i);
      WHILE (i < n) & (s[i] # '`') DO TexEsc(s[i]); INC(i) END;
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
        Wstr("\href{"); Wstr(url); Wstr("}{");
        k := 0; WHILE txt[k] # 0X DO TexEsc(txt[k]); INC(k) END;
        Wch('}'); i := j + 1
      ELSE
        TexEsc(c); INC(i)
      END
    ELSE
      TexEsc(c); INC(i)
    END
  END;
  IF bold THEN Wch('}') END;
  IF ital THEN Wch('}') END
END WriteInlineTex;

PROCEDURE EndParaTex;
BEGIN IF inPara THEN Wln; Wln; inPara := FALSE END END EndParaTex;

PROCEDURE EndListTex;
BEGIN
  IF inList THEN
    IF listOrd THEN Wstr("\end{enumerate}") ELSE Wstr("\end{itemize}") END;
    Wln; inList := FALSE
  END
END EndListTex;

PROCEDURE EndBQTex;
BEGIN IF inBQ THEN Wstr("\end{quote}"); Wln; inBQ := FALSE END END EndBQTex;

PROCEDURE EndBlockTex;
BEGIN EndParaTex; EndListTex; EndBQTex END EndBlockTex;

PROCEDURE ProcessLineTex(s: ARRAY OF CHAR);
VAR lvl, i, n: INTEGER;
BEGIN
  IF inCode THEN
    IF Strings.StartsWith(s, "```") THEN
      Wstr("\end{verbatim}"); Wln; inCode := FALSE
    ELSE
      Wstr(s); Wln
    END;
    RETURN
  END;

  IF Strings.StartsWith(s, "```") THEN
    EndBlockTex; Wstr("\begin{verbatim}"); Wln; inCode := TRUE; RETURN
  END;

  n := Strings.Length(s);
  IF n = 0 THEN EndBlockTex; RETURN END;

  lvl := 0;
  WHILE (lvl < 3) & (s[lvl] = '#') DO INC(lvl) END;
  IF (lvl > 0) & (s[lvl] = ' ') THEN
    EndBlockTex;
    IF    lvl = 1 THEN Wstr("\section{")
    ELSIF lvl = 2 THEN Wstr("\subsection{")
    ELSE               Wstr("\subsubsection{")
    END;
    Strings.Extract(s, lvl + 1, n - lvl - 1, arg);
    WriteInlineTex(arg); Wch('}'); Wln;
    RETURN
  END;

  IF IsHRule(s) THEN EndBlockTex; Wstr("\hrule"); Wln; Wln; RETURN END;

  IF s[0] = '>' THEN
    EndParaTex; EndListTex;
    IF ~inBQ THEN Wstr("\begin{quote}"); Wln; inBQ := TRUE END;
    IF (n > 1) & (s[1] = ' ') THEN Strings.Extract(s, 2, n - 2, arg)
    ELSE Strings.Extract(s, 1, n - 1, arg) END;
    WriteInlineTex(arg); Wln; Wln;
    RETURN
  END;
  EndBQTex;

  IF ((s[0] = '-') OR (s[0] = '*')) & (n > 1) & (s[1] = ' ') THEN
    EndParaTex;
    IF ~inList OR listOrd THEN
      EndListTex; Wstr("\begin{itemize}"); Wln; inList := TRUE; listOrd := FALSE
    END;
    Wstr("\item ");
    Strings.Extract(s, 2, n - 2, arg); WriteInlineTex(arg); Wln;
    RETURN
  END;

  i := 0;
  WHILE (i < n) & (s[i] >= '0') & (s[i] <= '9') DO INC(i) END;
  IF (i > 0) & (i < n) & (s[i] = '.') & (i + 1 < n) & (s[i+1] = ' ') THEN
    EndParaTex;
    IF ~inList OR ~listOrd THEN
      EndListTex; Wstr("\begin{enumerate}"); Wln; inList := TRUE; listOrd := TRUE
    END;
    Wstr("\item ");
    Strings.Extract(s, i + 2, n - i - 2, arg); WriteInlineTex(arg); Wln;
    RETURN
  END;

  EndListTex;
  inPara := TRUE;
  WriteInlineTex(s); Wch(' ')
END ProcessLineTex;

PROCEDURE WriteTexHeader;
BEGIN
  Wstr("\documentclass[12pt]{article}"); Wln;
  Wstr("\usepackage[utf8]{inputenc}"); Wln;
  Wstr("\usepackage[T1]{fontenc}"); Wln;
  Wstr("\usepackage{hyperref}"); Wln;
  Wstr("\usepackage{parskip}"); Wln;
  Wstr("\usepackage{geometry}"); Wln;
  Wstr("\geometry{margin=1in}"); Wln;
  Wstr("\begin{document}"); Wln
END WriteTexHeader;

PROCEDURE WriteTexFooter;
BEGIN EndBlockTex; Wstr("\end{document}"); Wln END WriteTexFooter;

(* ── Main ─────────────────────────────────────────────── *)

PROCEDURE Usage;
BEGIN
  Out.String("Usage: plume [-o outfile] [--html|--pdf|--docx] <input.md>"); Out.Ln;
  Out.String("  --html   HTML output (native)"); Out.Ln;
  Out.String("  --pdf    PDF output (native, no external tools)"); Out.Ln;
  Out.String("  --rtf    RTF document (opens in Word/LibreOffice)"); Out.Ln;
  Out.String("  --docx   alias for --rtf"); Out.Ln
END Usage;

VAR
  i : INTEGER;

BEGIN
  fmt := FMTPDF;
  inFile[0] := 0X; outFile[0] := 0X;

  i := 1;
  WHILE i <= Args.Count() DO
    Args.Get(i, arg);
    IF    Strings.Compare(arg, "--html") = 0 THEN fmt := FMTHTML
    ELSIF Strings.Compare(arg, "--pdf")  = 0 THEN fmt := FMTPDF
    ELSIF Strings.Compare(arg, "--rtf")  = 0 THEN fmt := FMTDOCX
    ELSIF Strings.Compare(arg, "--docx") = 0 THEN fmt := FMTDOCX
    ELSIF Strings.Compare(arg, "-o") = 0 THEN
      INC(i); Args.Get(i, outFile)
    ELSIF inFile[0] = 0X THEN
      COPY(arg, inFile)
    END;
    INC(i)
  END;

  IF inFile[0] = 0X THEN Usage; HALT(1) END;

  IF outFile[0] = 0X THEN
    IF    fmt = FMTHTML THEN SetExt(inFile, ".html", outFile)
    ELSIF fmt = FMTDOCX THEN SetExt(inFile, ".rtf",  outFile)
    ELSE                     SetExt(inFile, ".pdf",  outFile)
    END
  END;

  inF := Files.Old(inFile);
  IF inF = NIL THEN
    Out.String("plume: cannot open '"); Out.String(inFile); Out.Char("'"); Out.Ln;
    HALT(1)
  END;
  Files.Set(inR, inF, 0);

  outF := Files.New(outFile);

  IF outF = NIL THEN
    Out.String("plume: cannot create output"); Out.Ln; HALT(1)
  END;
  Files.Set(outR, outF, 0);

  IF fmt = FMTHTML THEN WriteHtmlHeader
  ELSIF fmt = FMTDOCX THEN WriteRtfHeader
  ELSIF fmt = FMTPDF THEN
    nPages := 0; i := 0; WHILE i < 200 DO xref[i] := 0; INC(i) END;
    WritePdfHeader; BeginPdfPage
  ELSE WriteTexHeader
  END;

  inPara := FALSE; inList := FALSE; listOrd := FALSE; listN := 1;
  inCode := FALSE; inBQ   := FALSE;
  bold   := FALSE; ital   := FALSE;

  Files.ReadLine(inR, line);
  WHILE ~inR.eof DO
    StripCR(line);
    IF fmt = FMTHTML THEN ProcessLineHtml(line)
    ELSIF fmt = FMTDOCX THEN ProcessLineRtf(line)
    ELSIF fmt = FMTPDF THEN ProcessLinePdf(line)
    ELSE ProcessLineTex(line)
    END;
    Files.ReadLine(inR, line)
  END;

  IF fmt = FMTHTML THEN WriteHtmlFooter
  ELSIF fmt = FMTDOCX THEN WriteRtfFooter
  ELSIF fmt = FMTPDF THEN EndPdfPage; WritePdfStructure
  ELSE WriteTexFooter
  END;

  Files.Register(outF);
  Files.Close(outF);
  Files.Close(inF);


  Out.String("plume: wrote "); Out.String(outFile); Out.Ln
END Plume.
