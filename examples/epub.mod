MODULE epub;
(*
 * epub — terminal EPUB reader.
 *
 * Usage: epub [--img] <file.epub>
 *
 * Options:
 *   --img              show inline images via iTerm2 protocol (off by default)
 *
 * Keys:
 *   Up / k             scroll one line up
 *   Down / j           scroll one line down
 *   PgUp               scroll one page up
 *   PgDn               scroll one page down
 *   Left / h           previous chapter
 *   Right / l          next chapter
 *   Mouse wheel        scroll three lines
 *   t                  table of contents browser
 *   r                  switch to a recently opened book
 *   i                  show book metadata (author, publisher, date, language)
 *   f                  show footnote for first [#ref] on screen
 *   n                  repeat last search forward
 *   N                  repeat last search backward
 *   v                  enter visual line-select mode
 *   (in visual)  j/k   move selection cursor
 *   (in visual)  Enter translate selection with trans(1)
 *   (in visual)  Esc/v cancel selection
 *   Ctrl+F             find (forward search)
 *   q / Ctrl+Q / Esc   quit (saves position)
 *
 * Options:
 *   --lang xx          translate into language code xx (e.g. ja, fr, de)
 *
 * Position is saved in ~/.epub_positions so the book reopens
 * at the last-read line.
 *)

IMPORT Zip, XHTML, Terminal, Graphics, Strings, Files, Args, Dict, Out, Base64, OS;

CONST
  MAXSPINE  = 256;
  MAXTOC    = 256;
  MAXLINES  = 6000;
  XHTMLSZ   = 131072;  (* 128 KB raw XHTML  *)
  TEXTSZ    = 131072;  (* 128 KB plain text *)
  WRAPSZ    = 131072;  (* 128 KB wrapped    *)
  OPFSZ     = 65536;   (* 64 KB OPF         *)

  KEY_UP    = 1;  KEY_DOWN  = 2;
  KEY_LEFT  = 3;  KEY_RIGHT = 4;
  KEY_PGUP  = 128; KEY_PGDN = 129;
  KEY_ESC   = 27;
  KEY_CTRL_Q = 17;
  KEY_CTRL_F = 6;
  KEY_MOUSE  = 5;   (* Terminal.ReadKey returns CHR(5) for mouse events *)

  MOUSE_WHEEL_UP   = 64;
  MOUSE_WHEEL_DOWN = 65;
  MOUSE_SCROLL_LINES = 3;

  CLR_STATUS = 0;   BG_STATUS = 24;   (* black on blue          *)
  CLR_FIND   = 0;   BG_FIND   = 226;  (* black on yellow        *)
  CLR_TEXT   = 255; BG_TEXT   = 0;
  CLR_SEL    = 0;   BG_SEL    = 75;   (* black on sky-blue      *)
  CLR_SELCUR = 0;   BG_SELCUR = 226;  (* black on yellow cursor *)
  CLR_POP    = 255; BG_POP    = 18;   (* white on dark blue     *)
  CLR_POPBDR = 226; BG_POPBDR = 18;   (* yellow on dark blue    *)
  CLR_POPFTR = 245; BG_POPFTR = 18;   (* grey on dark blue      *)

VAR
  archive   : Zip.Archive;
  epubPath  : ARRAY 512 OF CHAR;
  opfPath   : ARRAY 512 OF CHAR;
  opfDir    : ARRAY 512 OF CHAR;
  bookTitle : ARRAY 128 OF CHAR;

  spineHref : ARRAY MAXSPINE OF ARRAY 512 OF CHAR;
  nSpine    : INTEGER;
  curChap   : INTEGER;

  xhtmlBuf  : ARRAY XHTMLSZ OF CHAR;
  textBuf   : ARRAY TEXTSZ  OF CHAR;
  wrapBuf   : ARRAY WRAPSZ  OF CHAR;
  opfBuf    : ARRAY OPFSZ   OF CHAR;

  lineOff   : ARRAY MAXLINES OF INTEGER;
  lineLen   : ARRAY MAXLINES OF INTEGER;
  nLines    : INTEGER;

  topLine   : INTEGER;
  tCols     : INTEGER;
  tRows     : INTEGER;
  visRows   : INTEGER;

  findStr    : ARRAY 128 OF CHAR;
  statusMsg  : ARRAY 128 OF CHAR;
  running    : BOOLEAN;
  showImages : BOOLEAN;

  (* visual selection *)
  selMode    : BOOLEAN;
  selAnchor  : INTEGER;  (* line where 'v' was pressed *)
  selCursor  : INTEGER;  (* current cursor line        *)

  (* translation output buffers *)
  transOut   : ARRAY 16384 OF CHAR;
  cleanBuf   : ARRAY 16384 OF CHAR;
  transLang  : ARRAY 16 OF CHAR;   (* target language code, e.g. "ja" *)

  (* table of contents *)
  tocTitle   : ARRAY MAXTOC OF ARRAY 128 OF CHAR;
  tocHref    : ARRAY MAXTOC OF ARRAY 512 OF CHAR;
  nToc       : INTEGER;
  ncxHref    : ARRAY 512 OF CHAR;  (* path of NCX file in ZIP  *)
  navHref    : ARRAY 512 OF CHAR;  (* path of nav.xhtml in ZIP *)
  tocBuf     : ARRAY 65536 OF CHAR; (* 64 KB for ToC file      *)

  idMap     : Dict.Table;

  (* inline image buffers *)
  imgBuf  : ARRAY 524288 OF CHAR;  (* 512 KB raw binary image data  *)
  b64Buf  : ARRAY 720000 OF CHAR;  (* base64 output (~4/3 * 512 KB) *)

  (* position-file working storage — keeps up to 128 other books' positions *)
  posPaths  : ARRAY 128 OF ARRAY 512 OF CHAR;
  posChaps  : ARRAY 128 OF ARRAY 16  OF CHAR;
  posLines  : ARRAY 128 OF ARRAY 16  OF CHAR;
  nPosOther : INTEGER;

  (* book metadata from OPF dc: elements *)
  bookAuthor    : ARRAY 128 OF CHAR;
  bookPublisher : ARRAY 128 OF CHAR;
  bookDate      : ARRAY 32  OF CHAR;
  bookLang      : ARRAY 16  OF CHAR;

  (* word-wrap working state — module level so helpers can share *)
  wWp       : INTEGER;  (* write position in wrapBuf *)
  wLineStart: INTEGER;  (* wrapBuf offset of current line start *)
  wLineLen  : INTEGER;  (* chars in current line *)
  wWordStart: INTEGER;  (* textBuf offset of current word start *)
  wWordLen  : INTEGER;  (* length of current word *)
  wWidth    : INTEGER;  (* wrap column width *)

(* ── read ZIP entry into buf, return byte count or -1 ────────────── *)
PROCEDURE ReadEntry(path: ARRAY OF CHAR; VAR buf: ARRAY OF CHAR): INTEGER;
VAR idx: INTEGER;
BEGIN
  idx := Zip.Find(archive, path);
  IF idx < 0 THEN RETURN -1 END;
  RETURN Zip.Extract(archive, idx, buf)
END ReadEntry;

(* ── "a/b/c.xhtml" → "a/b/" ─────────────────────────────────────── *)
PROCEDURE DirOf(path: ARRAY OF CHAR; VAR dir: ARRAY OF CHAR);
VAR i, last: INTEGER;
BEGIN
  last := -1; i := 0;
  WHILE path[i] # 0X DO
    IF path[i] = '/' THEN last := i END;
    INC(i)
  END;
  IF last >= 0 THEN Strings.Extract(path, 0, last + 1, dir)
  ELSE dir[0] := 0X
  END
END DirOf;

(* ── strip ANSI escape sequences from src into dst ──────────────── *)
PROCEDURE StripAnsi(src: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR);
VAR i, j: INTEGER;
BEGIN
  i := 0; j := 0;
  WHILE (src[i] # 0X) & (j < LEN(dst) - 1) DO
    IF src[i] = 1BX THEN
      INC(i);
      IF src[i] = '[' THEN  (* CSI sequence: skip until final 0x40-0x7E *)
        INC(i);
        WHILE (src[i] # 0X) & ((src[i] < '@') OR (src[i] > '~')) DO INC(i) END;
        IF src[i] # 0X THEN INC(i) END
      END
    ELSIF src[i] = 0DX THEN  (* strip CR *)
      INC(i)
    ELSE
      dst[j] := src[i]; INC(j); INC(i)
    END
  END;
  dst[j] := 0X
END StripAnsi;

(* ── word-wrap helpers ──────────────────────────────────────────── *)
PROCEDURE WFlushLine();
BEGIN
  IF nLines < MAXLINES THEN
    lineOff[nLines] := wLineStart;
    lineLen[nLines] := wLineLen;
    INC(nLines)
  END;
  IF wWp < WRAPSZ - 1 THEN wrapBuf[wWp] := 0AX; INC(wWp) END;
  wLineStart := wWp; wLineLen := 0
END WFlushLine;

PROCEDURE WFlushWord();
VAR i: INTEGER;
BEGIN
  IF wWordLen = 0 THEN RETURN END;
  IF wLineLen > 0 THEN
    IF wLineLen + 1 + wWordLen > wWidth THEN
      WFlushLine()
    ELSE
      IF wWp < WRAPSZ - 1 THEN wrapBuf[wWp] := ' '; INC(wWp) END;
      INC(wLineLen)
    END
  END;
  i := 0;
  WHILE i < wWordLen DO
    IF wWp < WRAPSZ - 1 THEN wrapBuf[wWp] := textBuf[wWordStart + i]; INC(wWp) END;
    INC(i)
  END;
  INC(wLineLen, wWordLen);
  wWordLen := 0
END WFlushWord;

(* ── word-wrap textBuf → wrapBuf; fill lineOff/lineLen ──────────── *)
PROCEDURE WrapText();
VAR sp: INTEGER; c: CHAR;
BEGIN
  wWidth := tCols - 1;
  IF wWidth < 20 THEN wWidth := 20 END;
  sp := 0; wWp := 0; nLines := 0;
  wLineStart := 0; wLineLen := 0;
  wWordStart := 0; wWordLen := 0;

  WHILE textBuf[sp] # 0X DO
    c := textBuf[sp];
    IF c = 0AX THEN
      WFlushWord(); WFlushLine();
      WFlushLine();       (* blank line between paragraphs *)
      wWordStart := sp + 1
    ELSIF c = ' ' THEN
      WFlushWord();
      wWordStart := sp + 1
    ELSE
      IF wWordLen = 0 THEN wWordStart := sp END;
      INC(wWordLen)
    END;
    INC(sp)
  END;
  WFlushWord();
  IF wLineLen > 0 THEN WFlushLine() END;
  wrapBuf[wWp] := 0X
END WrapText;

(* ── ToC parsing ────────────────────────────────────────────────── *)

(* Parse EPUB 2 NCX (toc.ncx): extract navPoint titles and content srcs. *)
PROCEDURE ParseNCX(buf: ARRAY OF CHAR; dir: ARRAY OF CHAR);
VAR pos, epos, te, tp: INTEGER;
    tag: ARRAY 512 OF CHAR;
    title: ARRAY 128 OF CHAR;
    href: ARRAY 512 OF CHAR;
    full: ARRAY 512 OF CHAR;
    i: INTEGER; hasTitle: BOOLEAN;
BEGIN
  pos := 0;
  LOOP
    pos := Strings.Pos("<navPoint", buf, pos);
    IF pos < 0 THEN EXIT END;
    WHILE (buf[pos] # 0X) & (buf[pos] # '>') DO INC(pos) END;
    IF buf[pos] = '>' THEN INC(pos) END;

    hasTitle := FALSE; title[0] := 0X; href[0] := 0X;
    te := Strings.Pos("</navPoint>", buf, pos);
    IF te < 0 THEN te := Strings.Length(buf) END;

    tp := Strings.Pos("<text>", buf, pos);
    IF (tp >= 0) & (tp < te) THEN
      INC(tp, 6);  (* skip "<text>" *)
      i := 0;
      WHILE (buf[tp] # 0X) & (buf[tp] # '<') & (i < 127) DO
        title[i] := buf[tp]; INC(i); INC(tp)
      END;
      title[i] := 0X; Strings.Trim(title); hasTitle := TRUE
    END;

    tp := Strings.Pos("<content ", buf, pos);
    IF (tp >= 0) & (tp < te) THEN
      epos := tp; i := 0;
      WHILE (buf[epos] # 0X) & (buf[epos] # '>') & (i < 511) DO
        tag[i] := buf[epos]; INC(i); INC(epos)
      END;
      tag[i] := 0X;
      IF XHTML.AttrValue(tag, "src", href) THEN
        i := 0; WHILE (href[i] # 0X) & (href[i] # '#') DO INC(i) END;
        href[i] := 0X  (* strip fragment *)
      END
    END;

    IF hasTitle & (href[0] # 0X) & (nToc < MAXTOC) THEN
      COPY(dir, full); Strings.Append(href, full);
      COPY(title, tocTitle[nToc]); COPY(full, tocHref[nToc]); INC(nToc)
    END;
    pos := te
  END
END ParseNCX;

(* Parse EPUB 3 nav.xhtml: find <nav epub:type="toc"> and extract
   <a href>s within it.  Uses AttrValue so multi-token epub:type
   values like "toc chapter" work.  Scans only within the nav body
   so links in headers/footers before the TOC are not included.    *)
PROCEDURE ParseNav(buf: ARRAY OF CHAR; dir: ARRAY OF CHAR);
VAR pos, epos, navStart, navEnd: INTEGER;
    tag: ARRAY 512 OF CHAR;
    href: ARRAY 512 OF CHAR;
    full: ARRAY 512 OF CHAR;
    title: ARRAY 128 OF CHAR;
    val: ARRAY 64 OF CHAR;
    i: INTEGER;
BEGIN
  (* Find <nav epub:type="...toc..."> *)
  pos := 0; navStart := -1; navEnd := -1;
  LOOP
    pos := Strings.Pos("<nav", buf, pos);
    IF pos < 0 THEN EXIT END;
    (* Ensure it is really a <nav> tag, not e.g. <navigate> *)
    epos := pos + 4;
    IF (buf[epos] # ' ') & (buf[epos] # '>') & (buf[epos] # 9X) &
       (buf[epos] # 0AX) & (buf[epos] # '/') THEN
      pos := epos  (* not <nav>, skip *)
    ELSE
      i := 0;
      WHILE (buf[epos] # 0X) & (buf[epos] # '>') & (i < 511) DO
        tag[i] := buf[epos]; INC(i); INC(epos)
      END;
      tag[i] := 0X;
      IF buf[epos] = '>' THEN INC(epos) END;
      IF XHTML.AttrValue(tag, "epub:type", val) &
         (Strings.Pos("toc", val, 0) >= 0) THEN
        navStart := epos;
        navEnd := Strings.Pos("</nav>", buf, epos);
        IF navEnd < 0 THEN navEnd := Strings.Length(buf) END;
        EXIT
      END;
      pos := epos
    END
  END;
  IF navStart < 0 THEN RETURN END;

  (* Scan for <a href="..."> within the nav body only *)
  pos := navStart;
  WHILE pos < navEnd DO
    pos := Strings.Pos("<a ", buf, pos);
    IF (pos < 0) OR (pos >= navEnd) THEN EXIT END;
    epos := pos; i := 0;
    WHILE (buf[epos] # 0X) & (buf[epos] # '>') & (i < 511) DO
      tag[i] := buf[epos]; INC(i); INC(epos)
    END;
    tag[i] := 0X;
    IF buf[epos] = '>' THEN INC(epos) END;
    IF XHTML.AttrValue(tag, "href", href) THEN
      i := 0;
      WHILE (buf[epos] # 0X) & (buf[epos] # '<') & (i < 127) DO
        title[i] := buf[epos]; INC(i); INC(epos)
      END;
      title[i] := 0X; Strings.Trim(title);
      i := 0; WHILE (href[i] # 0X) & (href[i] # '#') DO INC(i) END;
      href[i] := 0X;  (* strip fragment *)
      IF (href[0] # 0X) & (title[0] # 0X) & (nToc < MAXTOC) THEN
        COPY(dir, full); Strings.Append(href, full);
        COPY(title, tocTitle[nToc]); COPY(full, tocHref[nToc]); INC(nToc)
      END
    END;
    pos := epos
  END
END ParseNav;

(* Load the ToC from whichever file the OPF points to. *)
PROCEDURE LoadTOC();
VAR n: INTEGER; dir: ARRAY 512 OF CHAR;
BEGIN
  nToc := 0;
  IF navHref[0] # 0X THEN  (* prefer EPUB 3 nav *)
    n := ReadEntry(navHref, tocBuf);
    IF n > 0 THEN
      tocBuf[n] := 0X; DirOf(navHref, dir); ParseNav(tocBuf, dir);
      IF nToc > 0 THEN RETURN END
    END
  END;
  IF ncxHref[0] # 0X THEN  (* fall back to NCX *)
    n := ReadEntry(ncxHref, tocBuf);
    IF n > 0 THEN
      tocBuf[n] := 0X; DirOf(ncxHref, dir); ParseNCX(tocBuf, dir)
    END
  END
END LoadTOC;

(* ── OPF parsing ────────────────────────────────────────────────── *)
PROCEDURE ParseManifest(buf: ARRAY OF CHAR);
VAR pos, epos: INTEGER;
    tag  : ARRAY 1024 OF CHAR;
    id   : ARRAY 256 OF CHAR;
    href : ARRAY 512 OF CHAR;
    mtype: ARRAY 64 OF CHAR;
    props: ARRAY 64 OF CHAR;
BEGIN
  pos := 0;
  LOOP
    pos := Strings.Pos("<item ", buf, pos);
    IF pos < 0 THEN EXIT END;
    epos := pos;
    WHILE (buf[epos] # 0X) & (buf[epos] # '>') DO INC(epos) END;
    IF buf[epos] = '>' THEN INC(epos) END;
    Strings.Extract(buf, pos, epos - pos, tag);
    IF XHTML.AttrValue(tag, "id", id) & XHTML.AttrValue(tag, "href", href) THEN
      Dict.Put(idMap, id, href);
      IF XHTML.AttrValue(tag, "media-type", mtype) THEN
        IF Strings.Pos("ncx", mtype, 0) >= 0 THEN
          COPY(opfDir, ncxHref); Strings.Append(href, ncxHref)
        END
      END;
      IF XHTML.AttrValue(tag, "properties", props) THEN
        IF Strings.Pos("nav", props, 0) >= 0 THEN
          COPY(opfDir, navHref); Strings.Append(href, navHref)
        END
      END
    END;
    pos := epos
  END
END ParseManifest;

PROCEDURE ParseSpine(buf: ARRAY OF CHAR);
VAR pos, epos: INTEGER;
    tag  : ARRAY 512 OF CHAR;
    iref : ARRAY 256 OF CHAR;
    href : ARRAY 512 OF CHAR;
    full : ARRAY 512 OF CHAR;
    lin  : ARRAY 16 OF CHAR;
BEGIN
  pos := 0;
  LOOP
    pos := Strings.Pos("<itemref ", buf, pos);
    IF pos < 0 THEN EXIT END;
    epos := pos;
    WHILE (buf[epos] # 0X) & (buf[epos] # '>') DO INC(epos) END;
    IF buf[epos] = '>' THEN INC(epos) END;
    Strings.Extract(buf, pos, epos - pos, tag);
    IF XHTML.AttrValue(tag, "idref", iref) THEN
      (* skip non-linear items — pop-up footnotes, cover pages, etc. *)
      IF ~(XHTML.AttrValue(tag, "linear", lin) &
           (Strings.Compare(lin, "no") = 0)) THEN
        IF Dict.Get(idMap, iref, href) & (nSpine < MAXSPINE) THEN
          COPY(opfDir, full); Strings.Append(href, full);
          COPY(full, spineHref[nSpine]); INC(nSpine)
        END
      END
    END;
    pos := epos
  END
END ParseSpine;

PROCEDURE LoadOPF(): BOOLEAN;
VAR n, pos, epos: INTEGER;

  (* Extract the text content of the first occurrence of <dc:tag ...>text</dc:tag> *)
  PROCEDURE DCField(tag: ARRAY OF CHAR; VAR val: ARRAY OF CHAR);
  VAR p, e: INTEGER; needle: ARRAY 32 OF CHAR;
  BEGIN
    val[0] := 0X;
    COPY("<dc:", needle); Strings.Append(tag, needle);
    p := Strings.Pos(needle, opfBuf, 0);
    IF p < 0 THEN RETURN END;
    WHILE (opfBuf[p] # 0X) & (opfBuf[p] # '>') DO INC(p) END;
    IF opfBuf[p] = '>' THEN INC(p) END;
    e := p;
    WHILE (opfBuf[e] # 0X) & (opfBuf[e] # '<') DO INC(e) END;
    Strings.Extract(opfBuf, p, e - p, val);
    Strings.Trim(val)
  END DCField;

BEGIN
  n := ReadEntry(opfPath, opfBuf);
  IF n < 0 THEN RETURN FALSE END;
  opfBuf[n] := 0X;

  DCField("title",     bookTitle);
  DCField("creator",   bookAuthor);
  DCField("publisher", bookPublisher);
  DCField("date",      bookDate);
  DCField("language",  bookLang);
  IF bookTitle[0] = 0X THEN COPY("(no title)", bookTitle) END;

  ParseManifest(opfBuf);
  ParseSpine(opfBuf);
  LoadTOC();
  RETURN nSpine > 0
END LoadOPF;

PROCEDURE LoadContainer(): BOOLEAN;
VAR n: INTEGER; buf: ARRAY 4096 OF CHAR;
BEGIN
  n := ReadEntry("META-INF/container.xml", buf);
  IF n < 0 THEN RETURN FALSE END;
  buf[n] := 0X;
  IF ~XHTML.AttrValue(buf, "full-path", opfPath) THEN RETURN FALSE END;
  DirOf(opfPath, opfDir);
  RETURN TRUE
END LoadContainer;

(* ── load chapter, convert, wrap ──────────────────────────────── *)
PROCEDURE LoadChapter();
VAR n: INTEGER;
BEGIN
  xhtmlBuf[0] := 0X; textBuf[0] := 0X; wrapBuf[0] := 0X;
  nLines := 0;
  IF (curChap < 0) OR (curChap >= nSpine) THEN RETURN END;
  n := ReadEntry(spineHref[curChap], xhtmlBuf);
  IF n < 0 THEN COPY("(could not load chapter)", textBuf)
  ELSE xhtmlBuf[n] := 0X; XHTML.ToText(xhtmlBuf, textBuf)
  END;
  WrapText()
END LoadChapter;

PROCEDURE ClampTop();
BEGIN
  IF topLine < 0 THEN topLine := 0 END;
  IF (nLines > 0) & (topLine > nLines - 1) THEN topLine := nLines - 1 END
END ClampTop;

(* ── inline image support (iTerm2 protocol) ─────────────────────
   NormalizePath removes /../ and /./ segments in-place.
   ImgFullPath builds the ZIP-relative path for an img src.
   EmitImage extracts the file, base64-encodes it, and emits the
   ESC]1337;File=inline=1;...<b64>BEL sequence to the terminal.  *)

PROCEDURE NormalizePath(VAR path: ARRAY OF CHAR);
VAR i, j, n: INTEGER;
BEGIN
  i := 0;
  WHILE path[i] # 0X DO
    IF (path[i] = '/') & (path[i+1] = '.') & (path[i+2] = '.') & (path[i+3] = '/') THEN
      (* resolve /../: remove previous component *)
      j := i - 1;
      WHILE (j > 0) & (path[j] # '/') DO DEC(j) END;
      n := i + 4;
      i := j + 1;
      WHILE path[n] # 0X DO path[i] := path[n]; INC(i); INC(n) END;
      path[i] := 0X;
      i := 0  (* restart *)
    ELSIF (path[i] = '/') & (path[i+1] = '.') & (path[i+2] = '/') THEN
      (* remove /./: just collapse the dot segment *)
      j := i; n := i + 2;
      WHILE path[n] # 0X DO path[j] := path[n]; INC(j); INC(n) END;
      path[j] := 0X;
      i := 0  (* restart *)
    ELSE
      INC(i)
    END
  END
END NormalizePath;

PROCEDURE ImgFullPath(imgSrc: ARRAY OF CHAR; VAR result: ARRAY OF CHAR);
VAR chapDir: ARRAY 512 OF CHAR;
BEGIN
  DirOf(spineHref[curChap], chapDir);
  COPY(chapDir, result);
  Strings.Append(imgSrc, result);
  NormalizePath(result)
END ImgFullPath;

PROCEDURE EmitImage(imgPath: ARRAY OF CHAR);
VAR idx, n: INTEGER;
BEGIN
  idx := Zip.Find(archive, imgPath);
  IF idx < 0 THEN RETURN END;
  n := Zip.Extract(archive, idx, imgBuf);
  IF n <= 0 THEN RETURN END;
  Base64.EncodeBin(imgBuf, n, b64Buf);
  Out.Char(1BX); Out.Char(']');
  Out.String("1337;File=inline=1;width=auto;height=auto;preserveAspectRatio=1:");
  Out.String(b64Buf);
  Out.Char(7X);  (* BEL *)
  Graphics.Reset  (* flushes stdout and resets any colour state *)
END EmitImage;

(* ── translation popup ───────────────────────────────────────────
   ShowPopup draws a centred box, renders text inside it (wrapping
   at the inner width), waits for any keypress, then returns so the
   caller's normal DrawAll() repaints the screen cleanly.           *)

PROCEDURE ShowPopup(text: ARRAY OF CHAR);
VAR
  popW, popH, popX, popY, maxCont: INTEGER;
  i, c, r, lc: INTEGER;
BEGIN
  (* inner width (content area, excluding border and 1-space padding) *)
  popW := tCols - 8;
  IF popW > 68 THEN popW := 68 END;
  IF popW < 20 THEN popW := 20 END;

  (* count content lines needed *)
  lc := 0; c := 0; i := 0;
  WHILE text[i] # 0X DO
    IF (text[i] = 0AX) OR (c = popW) THEN INC(lc); c := 0 END;
    IF text[i] # 0AX THEN INC(c) END;
    INC(i)
  END;
  IF c > 0 THEN INC(lc) END;  (* last partial line *)
  IF lc = 0 THEN lc := 1 END;

  maxCont := visRows - 6;
  IF maxCont < 3 THEN maxCont := 3 END;
  IF lc > maxCont THEN lc := maxCont END;

  popH := lc + 3;  (* top border + content + footer + bottom border *)
  popX := (tCols - popW - 4) DIV 2 + 1;
  popY := (visRows - popH) DIV 2 + 1;

  (* ── top border ── *)
  Terminal.Goto(popX, popY);
  Graphics.Color256(CLR_POPBDR, BG_POPBDR);
  Out.Char('+');
  c := 0; WHILE c < popW + 2 DO Out.Char('-'); INC(c) END;
  Out.Char('+');

  (* ── content lines ── *)
  i := 0;
  FOR r := 1 TO lc DO
    Terminal.Goto(popX, popY + r);
    Graphics.Color256(CLR_POPBDR, BG_POPBDR); Out.Char('|');
    Graphics.Color256(CLR_POP,    BG_POP);    Out.Char(' ');
    c := 0;
    WHILE (text[i] # 0X) & (text[i] # 0AX) & (c < popW) DO
      Out.Char(text[i]); INC(i); INC(c)
    END;
    IF text[i] = 0AX THEN INC(i) END;  (* consume newline *)
    WHILE c < popW DO Out.Char(' '); INC(c) END;
    Out.Char(' ');
    Graphics.Color256(CLR_POPBDR, BG_POPBDR); Out.Char('|')
  END;

  (* ── footer ── *)
  Terminal.Goto(popX, popY + lc + 1);
  Graphics.Color256(CLR_POPBDR, BG_POPBDR); Out.Char('|');
  Graphics.Color256(CLR_POPFTR, BG_POPFTR); Out.Char(' ');
  Out.String("Press any key to close");
  c := 22;
  WHILE c < popW DO Out.Char(' '); INC(c) END;
  Out.Char(' ');
  Graphics.Color256(CLR_POPBDR, BG_POPBDR); Out.Char('|');

  (* ── bottom border ── *)
  Terminal.Goto(popX, popY + popH - 1);
  Graphics.Color256(CLR_POPBDR, BG_POPBDR);
  Out.Char('+');
  c := 0; WHILE c < popW + 2 DO Out.Char('-'); INC(c) END;
  Out.Char('+');
  Graphics.Reset;

  (* wait for dismiss *)
  c := ORD(Terminal.ReadKey())
END ShowPopup;

(* ── run trans on selected lines, show result in popup ──────────── *)
PROCEDURE TranslateSelection();
VAR
  lo, hi, li: INTEGER;
  f: Files.File; r: Files.Rider;
  i, len: INTEGER;
  home, inPath, outPath, cmd: ARRAY 512 OF CHAR;
BEGIN
  lo := selAnchor; hi := selCursor;
  IF lo > hi THEN lo := selCursor; hi := selAnchor END;

  (* build paths under $HOME so they are writable everywhere *)
  Args.GetEnv("HOME", home);
  IF home[0] = 0X THEN home[0] := '.'; home[1] := 0X END;
  COPY(home, inPath);  Strings.Append("/.epub_trans_in.txt",  inPath);
  COPY(home, outPath); Strings.Append("/.epub_trans_out.txt", outPath);

  (* write selected text, skipping image placeholder lines *)
  f := Files.New(inPath);
  IF f = NIL THEN RETURN END;
  Files.Set(r, f, 0);
  li := lo;
  WHILE li <= hi DO
    IF (li >= 0) & (li < nLines) THEN
      i := lineOff[li];
      IF ~((lineLen[li] > 5) & (wrapBuf[i] = '[') & (wrapBuf[i+1] = 'I') &
           (wrapBuf[i+2] = 'M') & (wrapBuf[i+3] = 'G') & (wrapBuf[i+4] = ':')) THEN
        len := lineLen[li]; i := lineOff[li];
        WHILE len > 0 DO Files.Write(r, wrapBuf[i]); INC(i); DEC(len) END;
        Files.Write(r, 0AX)
      END
    END;
    INC(li)
  END;
  Files.Register(f); Files.Close(f);

  (* run trans, capture output *)
  COPY("trans -brief ", cmd);
  IF transLang[0] # 0X THEN
    Strings.Append(":", cmd); Strings.Append(transLang, cmd); Strings.Append(" ", cmd)
  END;
  Strings.Append("< ", cmd);    Strings.Append(inPath, cmd);
  Strings.Append(" > ", cmd);   Strings.Append(outPath, cmd);
  Strings.Append(" 2>&1", cmd);
  OS.Exec(cmd);

  (* read output into transOut *)
  transOut[0] := 0X;
  f := Files.Old(outPath);
  IF f # NIL THEN
    Files.Set(r, f, 0);
    i := 0;
    WHILE ~r.eof & (i < LEN(transOut) - 1) DO
      Files.Read(r, transOut[i]); INC(i)
    END;
    transOut[i] := 0X;
    Files.Close(f)
  END;
  IF transOut[0] = 0X THEN
    COPY("(no output — is translate-shell installed?)", transOut)
  END;

  selMode := FALSE;
  StripAnsi(transOut, cleanBuf);
  ShowPopup(cleanBuf)
END TranslateSelection;

(* ── drawing ─────────────────────────────────────────────────── *)
PROCEDURE DrawLine(li, y: INTEGER);
VAR i, len, col, j: INTEGER;
    imgSrc: ARRAY 512 OF CHAR;
    imgFull: ARRAY 1024 OF CHAR;
    isImg, isSel: BOOLEAN;
    lo, hi: INTEGER;
BEGIN
  Terminal.Goto(1, y);

  (* compute selection range *)
  lo := selAnchor; hi := selCursor;
  IF lo > hi THEN lo := selCursor; hi := selAnchor END;

  isSel := selMode & (li >= 0) & (li < nLines) & (li >= lo) & (li <= hi);

  isImg := FALSE;
  IF (li >= 0) & (li < nLines) & (lineLen[li] > 5) THEN
    i := lineOff[li];
    isImg := (wrapBuf[i]   = '[') & (wrapBuf[i+1] = 'I') &
             (wrapBuf[i+2] = 'M') & (wrapBuf[i+3] = 'G') & (wrapBuf[i+4] = ':')
  END;

  IF isImg THEN
    IF showImages THEN
      i := lineOff[li] + 5; j := 0;
      WHILE (wrapBuf[i] # ']') & (wrapBuf[i] # 0X) & (j < 511) DO
        imgSrc[j] := wrapBuf[i]; INC(i); INC(j)
      END;
      imgSrc[j] := 0X;
      ImgFullPath(imgSrc, imgFull);
      EmitImage(imgFull)
    ELSE
      IF isSel THEN Graphics.Color256(CLR_SEL, BG_SEL)
      ELSE Graphics.Color256(CLR_TEXT, BG_TEXT) END;
      col := 0;
      WHILE col < tCols DO Out.Char(' '); INC(col) END;
      Graphics.Reset
    END
  ELSE
    IF isSel THEN
      IF li = selCursor THEN Graphics.Color256(CLR_SELCUR, BG_SELCUR)
      ELSE Graphics.Color256(CLR_SEL, BG_SEL) END
    ELSE
      Graphics.Color256(CLR_TEXT, BG_TEXT)
    END;
    col := 0;
    IF (li >= 0) & (li < nLines) THEN
      len := lineLen[li]; i := lineOff[li];
      WHILE len > 0 DO Out.Char(wrapBuf[i]); INC(i); DEC(len); INC(col) END
    END;
    WHILE col < tCols DO Out.Char(' '); INC(col) END;
    Graphics.Reset
  END
END DrawLine;

PROCEDURE DrawStatus();
VAR pct, i, t: INTEGER; chapTitle: ARRAY 128 OF CHAR;
BEGIN
  (* Find the ToC title for the current chapter *)
  chapTitle[0] := 0X;
  FOR t := 0 TO nToc - 1 DO
    IF Strings.Compare(tocHref[t], spineHref[curChap]) = 0 THEN
      COPY(tocTitle[t], chapTitle)
    END
  END;

  Terminal.Goto(1, tRows);
  Graphics.Color256(CLR_STATUS, BG_STATUS);
  i := 0; WHILE i < tCols DO Out.Char(' '); INC(i) END;
  Terminal.Goto(1, tRows);
  Out.String(bookTitle);
  IF chapTitle[0] # 0X THEN Out.String(" \u2014 "); Out.String(chapTitle) END;
  Out.String("  ch "); Out.Int(curChap + 1); Out.String("/"); Out.Int(nSpine);
  IF nLines > 0 THEN
    pct := (topLine + visRows) * 100 DIV nLines;
    IF pct > 100 THEN pct := 100 END
  ELSE pct := 100
  END;
  Out.String("  "); Out.Int(pct); Out.String("%");
  IF selMode THEN Out.String("  [VISUAL]") END;
  IF statusMsg[0] # 0X THEN Out.String("  "); Out.String(statusMsg) END;
  Graphics.Reset
END DrawStatus;

PROCEDURE DrawAll();
VAR r, li: INTEGER;
BEGIN
  li := topLine;
  FOR r := 1 TO visRows DO
    DrawLine(li, r); INC(li)
  END;
  DrawStatus()
END DrawAll;

(* ── position file ───────────────────────────────────────────── *)
PROCEDURE PosFilePath(VAR path: ARRAY OF CHAR);
VAR home: ARRAY 256 OF CHAR;
BEGIN
  Args.GetEnv("HOME", home);
  IF home[0] = 0X THEN COPY("/tmp", home) END;
  COPY(home, path);
  Strings.Append("/.epub_positions", path)
END PosFilePath;

(* ── SavePos / RestorePos ─────────────────────────────────────────
   Format: three consecutive null-terminated strings per book record:
     path\0  chapterIndex\0  topLine\0
   Files.WriteString / Files.ReadString handle the null terminators.  *)

PROCEDURE SavePos();
VAR posFile: ARRAY 512 OF CHAR;
    f: Files.File; r: Files.Rider;
    p: ARRAY 512 OF CHAR;
    c, l, num: ARRAY 16 OF CHAR;
    i: INTEGER;
BEGIN
  PosFilePath(posFile);
  nPosOther := 0;

  (* read existing records, skip our own entry *)
  f := Files.Old(posFile);
  IF f # NIL THEN
    Files.Set(r, f, 0);
    WHILE ~r.eof DO
      Files.ReadString(r, p);
      IF r.eof THEN (* incomplete last record *) EXIT END;
      Files.ReadString(r, c);
      Files.ReadString(r, l);
      IF (Strings.Compare(p, epubPath) # 0) & (nPosOther < 128) THEN
        COPY(p, posPaths[nPosOther]);
        COPY(c, posChaps[nPosOther]);
        COPY(l, posLines[nPosOther]);
        INC(nPosOther)
      END
    END;
    Files.Close(f)
  END;

  (* write other books back, then our updated record *)
  f := Files.New(posFile);
  IF f = NIL THEN RETURN END;
  Files.Set(r, f, 0);
  FOR i := 0 TO nPosOther - 1 DO
    Files.WriteString(r, posPaths[i]);
    Files.WriteString(r, posChaps[i]);
    Files.WriteString(r, posLines[i])
  END;
  Files.WriteString(r, epubPath);
  Strings.IntToStr(curChap, num); Files.WriteString(r, num);
  Strings.IntToStr(topLine, num); Files.WriteString(r, num);
  Files.Register(f); Files.Close(f)
END SavePos;

PROCEDURE RestorePos();
VAR posFile: ARRAY 512 OF CHAR;
    f: Files.File; r: Files.Rider;
    p, c, l: ARRAY 512 OF CHAR;
    chap, ln: INTEGER; ok: BOOLEAN;
BEGIN
  PosFilePath(posFile);
  f := Files.Old(posFile);
  IF f = NIL THEN RETURN END;
  Files.Set(r, f, 0);
  WHILE ~r.eof DO
    Files.ReadString(r, p);
    IF r.eof THEN EXIT END;
    Files.ReadString(r, c);
    Files.ReadString(r, l);
    IF Strings.Compare(p, epubPath) = 0 THEN
      ok := Strings.StrToInt(c, chap);
      ok := Strings.StrToInt(l, ln);
      IF ok & (chap >= 0) & (chap < nSpine) THEN
        curChap := chap; topLine := ln
      END
    END
  END;
  Files.Close(f)
END RestorePos;

(* ── recent books list ───────────────────────────────────────────
   Reads all entries from ~/.epub_positions into posPaths/posChaps/
   posLines (reusing the pos working arrays) and returns the count.
   Entries are in file order: oldest first, current book last.      *)
PROCEDURE LoadRecentPaths(): INTEGER;
VAR posFile: ARRAY 512 OF CHAR;
    f: Files.File; r: Files.Rider;
    p, c, l: ARRAY 512 OF CHAR;
    n: INTEGER;
BEGIN
  PosFilePath(posFile);
  f := Files.Old(posFile);
  n := 0;
  IF f # NIL THEN
    Files.Set(r, f, 0);
    WHILE ~r.eof & (n < 128) DO
      Files.ReadString(r, p);
      IF r.eof THEN EXIT END;
      Files.ReadString(r, c);
      Files.ReadString(r, l);
      IF p[0] # 0X THEN
        COPY(p, posPaths[n]);
        COPY(c, posChaps[n]);
        COPY(l, posLines[n]);
        INC(n)
      END
    END;
    Files.Close(f)
  END;
  RETURN n
END LoadRecentPaths;

(* Extract filename component from a path. *)
PROCEDURE BaseName(path: ARRAY OF CHAR; VAR name: ARRAY OF CHAR);
VAR i, last: INTEGER;
BEGIN
  last := 0; i := 0;
  WHILE path[i] # 0X DO
    IF path[i] = '/' THEN last := i + 1 END;
    INC(i)
  END;
  i := 0;
  WHILE (path[last + i] # 0X) & (i < LEN(name) - 1) DO
    name[i] := path[last + i]; INC(i)
  END;
  name[i] := 0X
END BaseName;

(* Interactive recent-books picker.  Returns TRUE and sets chosen if
   the user selects an entry; returns FALSE on Esc/q or empty list.
   Display order: most-recent book at top (file entries reversed).
   sel  = posPaths index of highlighted entry (n-1 = most recent).
   top  = display offset: display row r shows posPaths[n-1-top-r].   *)
PROCEDURE ShowRecentBooks(VAR chosen: ARRAY OF CHAR): BOOLEAN;
VAR n, sel, top, visH, r, idx, c, j: INTEGER;
    bname: ARRAY 256 OF CHAR;
BEGIN
  n := LoadRecentPaths();
  IF n = 0 THEN RETURN FALSE END;

  visH := visRows - 2;
  sel := n - 1;   (* start on most-recent = highest index *)
  top := 0;       (* display row 0 → posPaths[n-1-top] *)

  LOOP
    Terminal.Clear();
    Terminal.Goto(1, 1);
    Graphics.Color256(CLR_POPBDR, BG_POPBDR);
    Out.String("Recent books  j/k:move  Enter:open  Esc/q:cancel");
    Graphics.Reset;

    FOR r := 0 TO visH - 1 DO
      idx := n - 1 - top - r;   (* posPaths index for this display row *)
      Terminal.Goto(1, r + 2);
      IF idx < 0 THEN
        (* past end of list: blank line *)
        Graphics.Color256(CLR_TEXT, BG_TEXT);
        j := 0; WHILE j < tCols DO Out.Char(' '); INC(j) END
      ELSE
        IF idx = sel THEN
          Graphics.Color256(CLR_SELCUR, BG_SELCUR)
        ELSIF Strings.Compare(posPaths[idx], epubPath) = 0 THEN
          Graphics.Color256(CLR_SEL, BG_SEL)
        ELSE
          Graphics.Color256(CLR_TEXT, BG_TEXT)
        END;
        IF Strings.Compare(posPaths[idx], epubPath) = 0 THEN
          Out.Char('*')
        ELSE
          Out.Char(' ')
        END;
        Out.Char(' ');
        BaseName(posPaths[idx], bname);
        j := 2;
        WHILE (bname[j-2] # 0X) & (j < tCols) DO
          Out.Char(bname[j-2]); INC(j)
        END;
        WHILE j < tCols DO Out.Char(' '); INC(j) END
      END;
      Graphics.Reset
    END;

    c := ORD(Terminal.ReadKey());
    IF (c = KEY_DOWN) OR (c = ORD('j')) THEN
      (* down in display = older entry = lower posPaths index *)
      IF sel > 0 THEN DEC(sel) END;
      (* scroll: display row for sel = n-1-top-sel; if >= visH, inc top *)
      IF n - 1 - top - sel >= visH THEN INC(top) END
    ELSIF (c = KEY_UP) OR (c = ORD('k')) THEN
      (* up in display = more recent = higher posPaths index *)
      IF sel < n - 1 THEN INC(sel) END;
      (* scroll: display row for sel = n-1-top-sel; if < 0, dec top *)
      IF n - 1 - top - sel < 0 THEN IF top > 0 THEN DEC(top) END END
    ELSIF c = 13 THEN  (* Enter *)
      Terminal.Clear();
      COPY(posPaths[sel], chosen);
      RETURN TRUE
    ELSIF (c = KEY_ESC) OR (c = ORD('q')) THEN
      Terminal.Clear(); RETURN FALSE
    END
  END
END ShowRecentBooks;

(* Save position, show recent-books picker, and reload if user picks one. *)
PROCEDURE SwitchBook();
VAR chosen: ARRAY 512 OF CHAR;
    newArchive: Zip.Archive;
BEGIN
  SavePos();
  IF ShowRecentBooks(chosen) THEN
    newArchive := Zip.Open(chosen);
    IF newArchive = NIL THEN
      COPY("Cannot open that book.", statusMsg); RETURN
    END;
    Zip.Close(archive);
    archive := newArchive;
    COPY(chosen, epubPath);
    Dict.Init(idMap);
    nSpine := 0; nToc := 0; curChap := 0; topLine := 0;
    ncxHref[0] := 0X; navHref[0] := 0X;
    bookTitle[0] := 0X; bookAuthor[0] := 0X; bookPublisher[0] := 0X;
    bookDate[0] := 0X; bookLang[0] := 0X;
    IF ~LoadContainer() OR ~LoadOPF() THEN
      COPY("Failed to load book.", statusMsg); RETURN
    END;
    RestorePos();
    Terminal.Clear();
    LoadChapter(); ClampTop()
  END
END SwitchBook;

(* ── prompt in status bar ─────────────────────────────────────── *)
PROCEDURE Prompt(prompt: ARRAY OF CHAR; VAR result: ARRAY OF CHAR): BOOLEAN;
VAR i, j, plen, k: INTEGER;
BEGIN
  result[0] := 0X; i := 0;
  plen := Strings.Length(prompt);
  LOOP
    Terminal.Goto(1, tRows);
    Graphics.Color256(CLR_FIND, BG_FIND);
    j := 1; WHILE j <= tCols DO Out.Char(' '); INC(j) END;
    Terminal.Goto(1, tRows);
    Out.String(prompt); Out.String(result);
    Graphics.Reset;
    Terminal.Goto(plen + i + 1, tRows);
    k := ORD(Terminal.ReadKey());
    IF k = 13 THEN RETURN i > 0
    ELSIF k = KEY_ESC THEN result[0] := 0X; RETURN FALSE
    ELSIF k = 127 THEN
      IF i > 0 THEN DEC(i); result[i] := 0X END
    ELSIF (k >= 32) & (k < 127) & (i < LEN(result) - 1) THEN
      result[i] := CHR(k); INC(i); result[i] := 0X
    END
  END
END Prompt;

(* ── search wrapBuf from line 'from' ─────────────────────────── *)
PROCEDURE FindNext(from: INTEGER): INTEGER;
VAR li, hit: INTEGER;
BEGIN
  IF findStr[0] = 0X THEN RETURN -1 END;
  li := from;
  WHILE li < nLines DO
    hit := Strings.Pos(findStr, wrapBuf, lineOff[li]);
    IF (hit >= lineOff[li]) & (hit < lineOff[li] + lineLen[li]) THEN
      RETURN li
    END;
    INC(li)
  END;
  RETURN -1
END FindNext;

(* ── search wrapBuf backwards from line 'from' ───────────────── *)
PROCEDURE FindPrev(from: INTEGER): INTEGER;
VAR li, hit: INTEGER;
BEGIN
  IF findStr[0] = 0X THEN RETURN -1 END;
  li := from;
  WHILE li >= 0 DO
    hit := Strings.Pos(findStr, wrapBuf, lineOff[li]);
    IF (hit >= lineOff[li]) & (hit < lineOff[li] + lineLen[li]) THEN
      RETURN li
    END;
    DEC(li)
  END;
  RETURN -1
END FindPrev;

(* ── ToC browser ─────────────────────────────────────────────── *)

(* Return the spine index for a given full ZIP path, or -1. *)
PROCEDURE HrefToSpine(href: ARRAY OF CHAR): INTEGER;
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO nSpine - 1 DO
    IF Strings.Compare(href, spineHref[i]) = 0 THEN RETURN i END
  END;
  RETURN -1
END HrefToSpine;

(* Interactive ToC list.  Returns the spine chapter to jump to, or -1. *)
PROCEDURE ShowTOC(): INTEGER;
VAR sel, top, visH, i, j, k, curMark: INTEGER;
BEGIN
  IF nToc = 0 THEN ShowPopup("No table of contents found."); RETURN -1 END;

  visH := visRows - 2;  (* rows available for entries *)
  sel := 0; top := 0;

  (* pre-select the entry that matches the current chapter *)
  FOR i := 0 TO nToc - 1 DO
    IF Strings.Compare(tocHref[i], spineHref[curChap]) = 0 THEN sel := i END
  END;
  IF sel >= visH THEN top := sel - visH DIV 2 END;

  LOOP
    Terminal.Clear();
    Terminal.Goto(1, 1);
    Graphics.Color256(CLR_POPBDR, BG_POPBDR);
    Out.String("Contents  j/k:move  Enter:open  Esc/q:cancel");
    Graphics.Reset;

    FOR i := 0 TO visH - 1 DO
      j := top + i;
      Terminal.Goto(1, i + 2);
      IF j >= nToc THEN
        Graphics.Color256(CLR_TEXT, BG_TEXT);
        k := 0; WHILE k < tCols DO Out.Char(' '); INC(k) END
      ELSE
        curMark := HrefToSpine(tocHref[j]);
        IF j = sel THEN
          Graphics.Color256(CLR_SELCUR, BG_SELCUR)
        ELSIF curMark = curChap THEN
          Graphics.Color256(CLR_SEL, BG_SEL)
        ELSE
          Graphics.Color256(CLR_TEXT, BG_TEXT)
        END;
        IF curMark = curChap THEN Out.Char('*') ELSE Out.Char(' ') END;
        Out.Char(' ');
        k := 2; j := top + i;
        WHILE (tocTitle[j][k-2] # 0X) & (k < tCols) DO
          Out.Char(tocTitle[j][k-2]); INC(k)
        END;
        WHILE k < tCols DO Out.Char(' '); INC(k) END
      END;
      Graphics.Reset
    END;

    k := ORD(Terminal.ReadKey());
    IF (k = KEY_DOWN) OR (k = ORD('j')) THEN
      IF sel < nToc - 1 THEN INC(sel) END;
      IF sel >= top + visH THEN INC(top) END
    ELSIF (k = KEY_UP) OR (k = ORD('k')) THEN
      IF sel > 0 THEN DEC(sel) END;
      IF sel < top THEN DEC(top) END
    ELSIF k = 13 THEN  (* Enter *)
      Terminal.Clear(); RETURN HrefToSpine(tocHref[sel])
    ELSIF (k = KEY_ESC) OR (k = ORD('q')) THEN
      Terminal.Clear(); RETURN -1
    END
  END
END ShowTOC;

(* ── footnote lookup ──────────────────────────────────────────── *)

(* Scan xhtmlBuf for the element with id=frag and ToText a snippet of it. *)
PROCEDURE FindFragment(frag: ARRAY OF CHAR; VAR text: ARRAY OF CHAR);
VAR pos, epos, i: INTEGER;
    idVal: ARRAY 128 OF CHAR;
    tagBuf: ARRAY 512 OF CHAR;
    snip: ARRAY 2048 OF CHAR;
BEGIN
  text[0] := 0X; pos := 0;
  WHILE xhtmlBuf[pos] # 0X DO
    IF xhtmlBuf[pos] = '<' THEN
      epos := pos + 1; i := 0;
      WHILE (xhtmlBuf[epos] # 0X) & (xhtmlBuf[epos] # '>') & (i < 511) DO
        tagBuf[i] := xhtmlBuf[epos]; INC(i); INC(epos)
      END;
      tagBuf[i] := 0X;
      IF XHTML.AttrValue(tagBuf, "id", idVal) &
         (Strings.Compare(idVal, frag) = 0) THEN
        IF xhtmlBuf[epos] = '>' THEN INC(epos) END;
        i := 0;
        WHILE (xhtmlBuf[epos] # 0X) & (i < 2047) DO
          snip[i] := xhtmlBuf[epos]; INC(i); INC(epos)
        END;
        snip[i] := 0X;
        XHTML.ToText(snip, text);
        RETURN
      END;
      pos := epos
    ELSE
      INC(pos)
    END
  END
END FindFragment;

(* Find the first [#frag] marker on the visible screen and show its content. *)
PROCEDURE ShowFootnote();
VAR li, i, len, j: INTEGER;
    frag: ARRAY 128 OF CHAR;
    fnText: ARRAY 4096 OF CHAR;
    found: BOOLEAN;
BEGIN
  found := FALSE;
  li := topLine;
  WHILE (li < topLine + visRows) & ~found DO
    IF (li >= 0) & (li < nLines) THEN
      i := lineOff[li]; len := lineLen[li];
      WHILE (len > 1) & ~found DO
        IF (wrapBuf[i] = '[') & (wrapBuf[i+1] = '#') THEN
          j := 0; INC(i, 2);
          WHILE (wrapBuf[i] # ']') & (wrapBuf[i] # 0X) & (j < 127) DO
            frag[j] := wrapBuf[i]; INC(j); INC(i)
          END;
          frag[j] := 0X; found := TRUE
        ELSE
          INC(i); DEC(len)
        END
      END
    END;
    INC(li)
  END;
  IF found THEN
    FindFragment(frag, fnText);
    IF fnText[0] = 0X THEN COPY("(footnote content not found in this chapter)", fnText) END;
    ShowPopup(fnText)
  ELSE
    COPY("No footnote references on this page.", statusMsg)
  END
END ShowFootnote;

(* ── metadata popup ──────────────────────────────────────────── *)
PROCEDURE ShowMeta();
VAR text: ARRAY 1024 OF CHAR;
BEGIN
  text[0] := 0X;
  IF bookTitle[0] # 0X THEN
    Strings.Append("Title:     ", text); Strings.Append(bookTitle, text);
    Strings.Append("\n", text)
  END;
  IF bookAuthor[0] # 0X THEN
    Strings.Append("Author:    ", text); Strings.Append(bookAuthor, text);
    Strings.Append("\n", text)
  END;
  IF bookPublisher[0] # 0X THEN
    Strings.Append("Publisher: ", text); Strings.Append(bookPublisher, text);
    Strings.Append("\n", text)
  END;
  IF bookDate[0] # 0X THEN
    Strings.Append("Date:      ", text); Strings.Append(bookDate, text);
    Strings.Append("\n", text)
  END;
  IF bookLang[0] # 0X THEN
    Strings.Append("Language:  ", text); Strings.Append(bookLang, text);
    Strings.Append("\n", text)
  END;
  IF text[0] = 0X THEN COPY("No metadata found.", text) END;
  ShowPopup(text)
END ShowMeta;

(* ── key handler ─────────────────────────────────────────────── *)
PROCEDURE HandleKey(k: INTEGER);
VAR found, chapIdx: INTEGER;
BEGIN
  statusMsg[0] := 0X;

  IF selMode THEN
    (* ── visual selection mode ── *)
    IF (k = KEY_UP) OR (k = ORD('k')) THEN
      IF selCursor > 0 THEN DEC(selCursor) END;
      IF selCursor < topLine THEN DEC(topLine); ClampTop() END
    ELSIF (k = KEY_DOWN) OR (k = ORD('j')) THEN
      IF selCursor < nLines - 1 THEN INC(selCursor) END;
      IF selCursor >= topLine + visRows THEN INC(topLine); ClampTop() END
    ELSIF k = 13 THEN  (* Enter/Return *)
      TranslateSelection()
    ELSIF (k = KEY_ESC) OR (k = ORD('v')) THEN
      selMode := FALSE
    END

  ELSE
    (* ── normal mode ── *)
    IF (k = KEY_UP) OR (k = ORD('k')) THEN
      DEC(topLine); ClampTop()
    ELSIF (k = KEY_DOWN) OR (k = ORD('j')) THEN
      INC(topLine); ClampTop()
    ELSIF k = KEY_PGUP THEN
      DEC(topLine, visRows);
      IF (topLine < 0) & (curChap > 0) THEN
        DEC(curChap); LoadChapter();
        topLine := nLines - visRows; ClampTop()
      ELSE
        ClampTop()
      END;
      SavePos()
    ELSIF k = KEY_PGDN THEN
      INC(topLine, visRows);
      IF (topLine >= nLines) & (curChap < nSpine - 1) THEN
        INC(curChap); topLine := 0; LoadChapter()
      ELSE
        ClampTop()
      END;
      SavePos()
    ELSIF (k = KEY_LEFT) OR (k = ORD('h')) THEN
      IF curChap > 0 THEN
        DEC(curChap); topLine := 0; LoadChapter(); SavePos()
      END
    ELSIF (k = KEY_RIGHT) OR (k = ORD('l')) THEN
      IF curChap < nSpine - 1 THEN
        INC(curChap); topLine := 0; LoadChapter(); SavePos()
      END
    ELSIF k = KEY_MOUSE THEN
      IF Terminal.MouseBtn() = MOUSE_WHEEL_UP THEN
        DEC(topLine, MOUSE_SCROLL_LINES); ClampTop()
      ELSIF Terminal.MouseBtn() = MOUSE_WHEEL_DOWN THEN
        INC(topLine, MOUSE_SCROLL_LINES); ClampTop()
      END
    ELSIF k = ORD('v') THEN
      selMode := TRUE; selAnchor := topLine; selCursor := topLine
    ELSIF k = ORD('t') THEN
      chapIdx := ShowTOC();
      IF chapIdx >= 0 THEN
        curChap := chapIdx; topLine := 0; LoadChapter(); SavePos()
      END
    ELSIF k = ORD('f') THEN
      ShowFootnote()
    ELSIF k = ORD('r') THEN
      SwitchBook()
    ELSIF k = ORD('i') THEN
      ShowMeta()
    ELSIF k = KEY_CTRL_F THEN
      IF Prompt("Find: ", findStr) THEN
        found := FindNext(topLine + 1);
        IF found >= 0 THEN topLine := found; ClampTop()
        ELSE COPY("Not found.", statusMsg)
        END
      END
    ELSIF k = ORD('n') THEN
      IF findStr[0] = 0X THEN
        COPY("No search active.", statusMsg)
      ELSE
        found := FindNext(topLine + 1);
        IF found >= 0 THEN topLine := found; ClampTop()
        ELSE COPY("Not found.", statusMsg)
        END
      END
    ELSIF k = ORD('N') THEN
      IF findStr[0] = 0X THEN
        COPY("No search active.", statusMsg)
      ELSE
        found := FindPrev(topLine - 1);
        IF found >= 0 THEN topLine := found; ClampTop()
        ELSE COPY("Not found.", statusMsg)
        END
      END
    ELSIF (k = ORD('q')) OR (k = KEY_CTRL_Q) OR (k = KEY_ESC) THEN
      SavePos(); running := FALSE
    END
  END
END HandleKey;

(* ── main ──────────────────────────────────────────────────────── *)
VAR k, argIdx: INTEGER; argTmp: ARRAY 512 OF CHAR;
BEGIN
  showImages := FALSE; epubPath[0] := 0X; transLang[0] := 0X;
  argIdx := 1;
  WHILE argIdx <= Args.Count() DO
    Args.Get(argIdx, argTmp);
    IF Strings.Compare(argTmp, "--img") = 0 THEN
      showImages := TRUE
    ELSIF Strings.Compare(argTmp, "--lang") = 0 THEN
      INC(argIdx);
      IF argIdx <= Args.Count() THEN Args.Get(argIdx, transLang) END
    ELSIF epubPath[0] = 0X THEN
      COPY(argTmp, epubPath)
    END;
    INC(argIdx)
  END;
  IF epubPath[0] = 0X THEN
    (* No file given — show recent-books picker if positions exist *)
    tCols := Terminal.Cols(); tRows := Terminal.Rows();
    visRows := tRows - 1;
    Terminal.Clear();
    IF ~ShowRecentBooks(epubPath) OR (epubPath[0] = 0X) THEN
      Terminal.Clear();
      Out.String("Usage: epub [--img] [--lang xx] <file.epub>"); Out.Ln;
      HALT(1)
    END
  END;

  archive := Zip.Open(epubPath);
  IF archive = NIL THEN
    Out.String("Cannot open: "); Out.String(epubPath); Out.Ln; HALT(1)
  END;

  Dict.Init(idMap);
  nSpine := 0; curChap := 0; topLine := 0;
  bookTitle[0] := 0X; bookAuthor[0] := 0X; bookPublisher[0] := 0X;
  bookDate[0] := 0X; bookLang[0] := 0X;
  findStr[0] := 0X; statusMsg[0] := 0X;
  selMode := FALSE; selAnchor := 0; selCursor := 0;
  nToc := 0; ncxHref[0] := 0X; navHref[0] := 0X;

  IF ~LoadContainer() THEN
    Out.String("Not a valid EPUB (missing container.xml)"); Out.Ln; HALT(1)
  END;
  IF ~LoadOPF() THEN
    Out.String("Could not parse OPF / empty spine"); Out.Ln; HALT(1)
  END;

  RestorePos();

  tCols := Terminal.Cols(); tRows := Terminal.Rows();
  visRows := tRows - 1;

  LoadChapter(); ClampTop();
  running := TRUE;
  Terminal.Clear();
  Terminal.MouseOn();
  DrawAll();

  WHILE running DO
    k := ORD(Terminal.ReadKey());
    tCols := Terminal.Cols(); tRows := Terminal.Rows();
    visRows := tRows - 1;
    HandleKey(k);
    IF running THEN DrawAll() END
  END;

  Terminal.MouseOff();
  Terminal.Clear()
END epub.
