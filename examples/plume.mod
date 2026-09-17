MODULE Plume;
(*
 * plume - simple markdown to PDF/HTML/DOCX converter
 * Usage: plume [-o outfile] [--html|--pdf|--docx] <input.md>
 *   --html   native HTML output
 *   --pdf    PDF via pdflatex (default)
 *   --docx   Word document via pandoc
 *)

IMPORT Args, Strings, Files, Out, OS, Markdown, ZipWriter;

CONST
  LLEN    = 4096;
  MAXPG   = 50;
  FMTPDF  = 0;
  FMTHTML = 1;
  FMTDOCX = 2;
  FMTEPUB = 3;
  (* One chapterN.xhtml ZIP entry per top-level heading, plus
     mimetype/container.xml/package.opf/nav.xhtml — capped so the
     total never exceeds ZipWriter.MaxEntries. *)
  EpubMaxChapters = ZipWriter.MaxEntries - 4;
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
  bold      : BOOLEAN;
  ital      : BOOLEAN;
  inTable   : BOOLEAN;
  inTableHead : BOOLEAN;
  tableHdr  : ARRAY LLEN OF CHAR;
  tableCols : INTEGER;

(* ── Output primitives ────────────────────────────────── *)

PROCEDURE Wch(c: CHAR);
BEGIN Files.Write(outR, c) END Wch;

PROCEDURE Wstr(s: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN i := 0; WHILE s[i] # 0X DO Wch(s[i]); INC(i) END END Wstr;

PROCEDURE Wln;
BEGIN Wch(0AX) END Wln;

PROCEDURE MdSink(c: CHAR);
(* Markdown.WriteProc callback: writes wherever outR currently points. *)
BEGIN Wch(c) END MdSink;

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


(* ── HTML and RTF rendering now live in Markdown.mod ─────
   (Markdown.HtmlHeader/HtmlLine/HtmlFooter, Markdown.RtfHeader/
   RtfLine/RtfFooter). IsHRule/IsTableSep/GetCell/CountCols also moved
   there — used below by the PDF and LaTeX renderers via Markdown.*. *)

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
VAR len, pgNum, pw, x: INTEGER; ns: ARRAY 16 OF CHAR;
BEGIN
  IF ~inBT OR (nPages >= MAXPG) THEN RETURN END;
  pgNum := nPages + 1;
  Strings.IntToStr(pgNum, ns);
  pw := (Strings.Length(ns) + 4) * 10 * 55 DIV 100;
  x := PG_W DIV 2 - pw DIV 2;
  Wstr("1 0 0 1 "); WpdfInt(x); Wch(' '); WpdfInt(36); Wstr(" Tm"); Wln;
  Wstr("/F1 10 Tf"); Wln;
  Wstr("(- "); Wstr(ns); Wstr(" -) Tj"); Wln;
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
BEGIN Wstr("1 0 0 1 "); WpdfInt(x); Wch(' '); WpdfInt(y); Wstr(" Tm"); Wln END PdfTm;

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

PROCEDURE EmitTableRowPdf(s: ARRAY OF CHAR; isHeader: BOOLEAN);
VAR pos, i, x, cw, k, fnt: INTEGER; cell: ARRAY 512 OF CHAR;
BEGIN
  IF tableCols < 1 THEN tableCols := 1 END;
  cw := TX_W DIV tableCols;
  CheckPdfRoom(16);
  Wstr("ET"); Wln;
  Wstr("0.5 w"); Wln;
  WpdfInt(PG_MAR); Wch(' '); WpdfInt(curY + 2); Wstr(" m ");
  WpdfInt(PG_MAR + TX_W); Wch(' '); WpdfInt(curY + 2); Wstr(" l S"); Wln;
  WpdfInt(PG_MAR); Wch(' '); WpdfInt(curY - 14); Wstr(" m ");
  WpdfInt(PG_MAR + TX_W); Wch(' '); WpdfInt(curY - 14); Wstr(" l S"); Wln;
  i := 0;
  WHILE i <= tableCols DO
    x := PG_MAR + i * cw;
    WpdfInt(x); Wch(' '); WpdfInt(curY + 2); Wstr(" m ");
    WpdfInt(x); Wch(' '); WpdfInt(curY - 14); Wstr(" l S"); Wln;
    INC(i)
  END;
  Wstr("BT"); Wln;
  IF isHeader THEN fnt := FN_B ELSE fnt := FN_R END;
  pos := 0; i := 0;
  WHILE Markdown.GetCell(s, pos, cell) DO
    x := PG_MAR + i * cw + 3;
    PdfTm(x, curY - 11); PdfSetFont(fnt, 10);
    Wch('('); k := 0;
    WHILE cell[k] # 0X DO PdfEscCh(cell[k]); INC(k) END;
    Wstr(") Tj"); Wln;
    INC(i)
  END;
  DEC(curY, 16)
END EmitTableRowPdf;

PROCEDURE EndTablePdf;
BEGIN
  IF inTable THEN
    IF inTableHead THEN
      tableCols := Markdown.CountCols(tableHdr);
      EmitTableRowPdf(tableHdr, TRUE);
      inTableHead := FALSE
    END;
    inTable := FALSE
  END
END EndTablePdf;

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

  IF Markdown.IsTableSep(s) THEN
    IF inTable & inTableHead THEN
      tableCols := Markdown.CountCols(tableHdr);
      EmitTableRowPdf(tableHdr, TRUE);
      inTableHead := FALSE
    END;
    RETURN
  END;

  IF s[0] = '|' THEN
    IF ~inTable THEN
      EndParaPdf;
      inTable := TRUE; inTableHead := TRUE; tableCols := 0;
      COPY(s, tableHdr)
    ELSIF inTableHead THEN
      tableCols := Markdown.CountCols(tableHdr);
      EmitTableRowPdf(tableHdr, TRUE);
      inTableHead := FALSE;
      EmitTableRowPdf(s, FALSE)
    ELSE
      EmitTableRowPdf(s, FALSE)
    END;
    RETURN
  END;

  IF inTable THEN EndTablePdf END;

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

  IF Markdown.IsHRule(s) THEN
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

PROCEDURE WriteTabularSpec(n: INTEGER);
VAR i: INTEGER;
BEGIN
  Wstr("\begin{tabular}{|");
  i := 0; WHILE i < n DO Wstr("l|"); INC(i) END;
  Wch('}'); Wln;
  Wstr("\hline"); Wln
END WriteTabularSpec;

PROCEDURE EmitTableRowTex(s: ARRAY OF CHAR; isHeader: BOOLEAN);
VAR pos: INTEGER; first: BOOLEAN; cell: ARRAY 512 OF CHAR;
BEGIN
  pos := 0; first := TRUE;
  WHILE Markdown.GetCell(s, pos, cell) DO
    IF ~first THEN Wstr(" & ") END;
    first := FALSE;
    IF isHeader THEN Wstr("\textbf{") END;
    WriteInlineTex(cell);
    IF isHeader THEN Wch('}') END
  END;
  Wstr(" \\"); Wln;
  Wstr("\hline"); Wln
END EmitTableRowTex;

PROCEDURE EndTableTex;
BEGIN
  IF inTable THEN
    IF inTableHead THEN
      tableCols := Markdown.CountCols(tableHdr);
      WriteTabularSpec(tableCols);
      EmitTableRowTex(tableHdr, FALSE);
      inTableHead := FALSE
    END;
    Wstr("\end{tabular}"); Wln; Wln;
    inTable := FALSE
  END
END EndTableTex;

PROCEDURE EndBlockTex;
BEGIN EndParaTex; EndListTex; EndBQTex; EndTableTex END EndBlockTex;

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

  IF Markdown.IsHRule(s) THEN EndBlockTex; Wstr("\hrule"); Wln; Wln; RETURN END;

  IF Markdown.IsTableSep(s) THEN
    IF inTable & inTableHead THEN
      tableCols := Markdown.CountCols(tableHdr);
      WriteTabularSpec(tableCols);
      EmitTableRowTex(tableHdr, TRUE);
      inTableHead := FALSE
    END;
    RETURN
  END;

  IF s[0] = '|' THEN
    IF ~inTable THEN
      EndBlockTex;
      inTable := TRUE; inTableHead := TRUE;
      COPY(s, tableHdr)
    ELSIF inTableHead THEN
      tableCols := Markdown.CountCols(tableHdr);
      WriteTabularSpec(tableCols);
      EmitTableRowTex(tableHdr, TRUE);
      inTableHead := FALSE;
      EmitTableRowTex(s, FALSE)
    ELSE
      EmitTableRowTex(s, FALSE)
    END;
    RETURN
  END;

  IF inTable THEN EndTableTex END;

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

(* ── EPUB ─────────────────────────────────────────────── *)
(* Built via Markdown.mod's Epub* renderer (content.xhtml + nav.xhtml,
   modeled on pstar's epub.rs) and ZipWriter for archive assembly --
   replaces plume's former hand-rolled EPUB2/toc.ncx packaging so
   plume and ostar.mod produce the same EPUB structure. *)

PROCEDURE MakeTempPath(base, suffix: ARRAY OF CHAR; VAR out: ARRAY OF CHAR);
BEGIN COPY(base, out); Strings.Append(suffix, out) END MakeTempPath;

PROCEDURE EpubChapterTempPath(base: ARRAY OF CHAR; n: INTEGER; VAR out: ARRAY OF CHAR);
VAR num: ARRAY 16 OF CHAR;
BEGIN
  Strings.IntToStr(n, num);
  COPY(base, out); Strings.Append(".chapter", out); Strings.Append(num, out);
  Strings.Append(".tmp", out)
END EpubChapterTempPath;

PROCEDURE EpubChapterEntryName(n: INTEGER; VAR out: ARRAY OF CHAR);
VAR num: ARRAY 16 OF CHAR;
BEGIN
  Strings.IntToStr(n, num);
  COPY("OEBPS/chapter", out); Strings.Append(num, out); Strings.Append(".xhtml", out)
END EpubChapterEntryName;

PROCEDURE DoEpub;
VAR f: Files.File;
    tmpMime, tmpContainer, tmpOpf, tmpNav, tmpContent, entryName: ARRAY LLEN OF CHAR;
    i, chapters: INTEGER; ok: BOOLEAN;
BEGIN
  MakeTempPath(outFile, ".mime.tmp", tmpMime);
  MakeTempPath(outFile, ".container.tmp", tmpContainer);
  MakeTempPath(outFile, ".opf.tmp", tmpOpf);
  MakeTempPath(outFile, ".nav.tmp", tmpNav);

  Markdown.Reset;

  f := Files.New(tmpMime);
  IF f = NIL THEN Out.String("plume: cannot create temp file"); Out.Ln; HALT(1) END;
  Files.Set(outR, f, 0);
  Markdown.EpubMimetype;
  Files.Register(f); Files.Close(f);

  f := Files.New(tmpContainer);
  Files.Set(outR, f, 0);
  Markdown.EpubContainerXml;
  Files.Register(f); Files.Close(f);

  (* Each chapter's temp path is a deterministic function of outFile
     and its chapter number, so it's recomputed on demand below rather
     than kept in a (potentially very large) array of paths. *)
  EpubChapterTempPath(outFile, 1, tmpContent);
  f := Files.New(tmpContent);
  Files.Set(outR, f, 0);
  Markdown.EpubContentHeader;
  Files.Set(inR, inF, 0);
  Files.ReadLine(inR, line);
  WHILE ~inR.eof DO
    StripCR(line);
    IF (Markdown.EpubChapterNum() < EpubMaxChapters) & Markdown.EpubStartsChapter(line) THEN
      Markdown.EpubContentFooter;
      Files.Register(f); Files.Close(f);
      Markdown.EpubBeginChapter;
      EpubChapterTempPath(outFile, Markdown.EpubChapterNum(), tmpContent);
      f := Files.New(tmpContent);
      Files.Set(outR, f, 0);
      Markdown.EpubContentHeader
    END;
    Markdown.EpubLine(line);
    Files.ReadLine(inR, line)
  END;
  Markdown.EpubContentFooter;
  Files.Register(f); Files.Close(f);
  chapters := Markdown.EpubChapterNum();

  f := Files.New(tmpOpf);
  Files.Set(outR, f, 0);
  Markdown.EpubPackageOpf(chapters);
  Files.Register(f); Files.Close(f);

  f := Files.New(tmpNav);
  Files.Set(outR, f, 0);
  Markdown.EpubNavXhtml;
  Files.Register(f); Files.Close(f);

  ok := ZipWriter.Begin(outFile);
  ok := ZipWriter.Add("mimetype", tmpMime) & ok;
  ok := ZipWriter.Add("META-INF/container.xml", tmpContainer) & ok;
  ok := ZipWriter.Add("OEBPS/package.opf", tmpOpf) & ok;
  i := 1;
  WHILE i <= chapters DO
    EpubChapterTempPath(outFile, i, tmpContent);
    EpubChapterEntryName(i, entryName);
    ok := ZipWriter.Add(entryName, tmpContent) & ok;
    INC(i)
  END;
  ok := ZipWriter.Add("OEBPS/nav.xhtml", tmpNav) & ok;
  ok := ZipWriter.Finish() & ok;

  Files.Delete(tmpMime); Files.Delete(tmpContainer); Files.Delete(tmpOpf);
  i := 1;
  WHILE i <= chapters DO
    EpubChapterTempPath(outFile, i, tmpContent); Files.Delete(tmpContent); INC(i)
  END;
  Files.Delete(tmpNav);

  IF ~ok THEN Out.String("plume: EPUB packaging failed"); Out.Ln; HALT(1) END
END DoEpub;


(* ── Main ─────────────────────────────────────────────── *)

PROCEDURE Usage;
BEGIN
  Out.String("Usage: plume [-o outfile] [--html|--pdf|--epub|--rtf] <input.md>"); Out.Ln;
  Out.String("  --html   HTML output (native)"); Out.Ln;
  Out.String("  --pdf    PDF output (native, no external tools)"); Out.Ln;
  Out.String("  --epub   EPUB 3 ebook (native, no external tools)"); Out.Ln;
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
    ELSIF Strings.Compare(arg, "--epub") = 0 THEN fmt := FMTEPUB
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
    ELSIF fmt = FMTEPUB THEN SetExt(inFile, ".epub", outFile)
    ELSE                     SetExt(inFile, ".pdf",  outFile)
    END
  END;

  inF := Files.Old(inFile);
  IF inF = NIL THEN
    Out.String("plume: cannot open '"); Out.String(inFile); Out.Char("'"); Out.Ln;
    HALT(1)
  END;
  Files.Set(inR, inF, 0);

  Markdown.SetSink(MdSink);

  IF fmt = FMTEPUB THEN
    (* Its own multi-file/ZIP pipeline — see DoEpub above. *)
    DoEpub;
    Files.Close(inF);
    Out.String("plume: wrote "); Out.String(outFile); Out.Ln;
    HALT(0)
  END;

  outF := Files.New(outFile);
  IF outF = NIL THEN Out.String("plume: cannot create output"); Out.Ln; HALT(1) END;
  Files.Set(outR, outF, 0);

  inPara := FALSE; inList := FALSE; listOrd := FALSE; listN := 1;
  inCode := FALSE; inBQ   := FALSE;
  bold   := FALSE; ital   := FALSE;
  inTable := FALSE; inTableHead := FALSE; tableCols := 0;
  Markdown.Reset;

  IF fmt = FMTHTML THEN Markdown.HtmlHeader
  ELSIF fmt = FMTDOCX THEN Markdown.RtfHeader
  ELSIF fmt = FMTPDF THEN
    nPages := 0; i := 0; WHILE i < 200 DO xref[i] := 0; INC(i) END;
    WritePdfHeader; BeginPdfPage
  ELSE WriteTexHeader
  END;

  Files.ReadLine(inR, line);
  WHILE ~inR.eof DO
    StripCR(line);
    IF fmt = FMTHTML THEN Markdown.HtmlLine(line)
    ELSIF fmt = FMTDOCX THEN Markdown.RtfLine(line)
    ELSIF fmt = FMTPDF  THEN ProcessLinePdf(line)
    ELSE ProcessLineTex(line)
    END;
    Files.ReadLine(inR, line)
  END;

  IF fmt = FMTHTML THEN Markdown.HtmlFooter
  ELSIF fmt = FMTDOCX THEN Markdown.RtfFooter
  ELSIF fmt = FMTPDF THEN EndPdfPage; WritePdfStructure
  ELSE WriteTexFooter
  END;

  Files.Register(outF);
  Files.Close(outF);
  Files.Close(inF);

  Out.String("plume: wrote "); Out.String(outFile); Out.Ln
END Plume.
