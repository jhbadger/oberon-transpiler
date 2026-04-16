MODULE epub;
(*
 * epub — terminal EPUB reader.
 *
 * Usage: epub <file.epub>
 *
 * Keys:
 *   Up / Down          scroll one line
 *   PgUp / PgDn        scroll one page
 *   Left / Right       previous / next chapter
 *   Ctrl+F             find (forward search)
 *   Ctrl+Q / Esc       quit (saves position)
 *
 * Position is saved in ~/.epub_positions so the book reopens
 * at the last-read line.
 *)

IMPORT Zip, XHTML, Terminal, Graphics, Strings, Files, Args, Dict, Out, Base64;

CONST
  MAXSPINE  = 256;
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

  CLR_STATUS = 0;  BG_STATUS = 24;   (* black on blue   *)
  CLR_FIND   = 0;  BG_FIND   = 226;  (* black on yellow *)
  CLR_TEXT   = 255; BG_TEXT  = 0;

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

  findStr   : ARRAY 128 OF CHAR;
  statusMsg : ARRAY 128 OF CHAR;
  running   : BOOLEAN;

  idMap     : Dict.Table;

  (* inline image buffers *)
  imgBuf  : ARRAY 524288 OF CHAR;  (* 512 KB raw binary image data  *)
  b64Buf  : ARRAY 720000 OF CHAR;  (* base64 output (~4/3 * 512 KB) *)

  (* position-file working storage — keeps up to 128 other books' positions *)
  posPaths  : ARRAY 128 OF ARRAY 512 OF CHAR;
  posChaps  : ARRAY 128 OF ARRAY 16  OF CHAR;
  posLines  : ARRAY 128 OF ARRAY 16  OF CHAR;
  nPosOther : INTEGER;

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

(* ── OPF parsing ────────────────────────────────────────────────── *)
PROCEDURE ParseManifest(buf: ARRAY OF CHAR);
VAR pos, epos: INTEGER;
    tag : ARRAY 1024 OF CHAR;
    id  : ARRAY 256 OF CHAR;
    href: ARRAY 512 OF CHAR;
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
      Dict.Put(idMap, id, href)
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
      IF Dict.Get(idMap, iref, href) & (nSpine < MAXSPINE) THEN
        COPY(opfDir, full); Strings.Append(href, full);
        COPY(full, spineHref[nSpine]); INC(nSpine)
      END
    END;
    pos := epos
  END
END ParseSpine;

PROCEDURE LoadOPF(): BOOLEAN;
VAR n, pos, epos: INTEGER;
BEGIN
  n := ReadEntry(opfPath, opfBuf);
  IF n < 0 THEN RETURN FALSE END;
  opfBuf[n] := 0X;

  pos := Strings.Pos("<dc:title", opfBuf, 0);
  IF pos >= 0 THEN
    WHILE (opfBuf[pos] # 0X) & (opfBuf[pos] # '>') DO INC(pos) END;
    IF opfBuf[pos] = '>' THEN INC(pos) END;
    epos := pos;
    WHILE (opfBuf[epos] # 0X) & (opfBuf[epos] # '<') DO INC(epos) END;
    Strings.Extract(opfBuf, pos, epos - pos, bookTitle);
    Strings.Trim(bookTitle)
  ELSE
    COPY("(no title)", bookTitle)
  END;

  ParseManifest(opfBuf);
  ParseSpine(opfBuf);
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

(* ── drawing ─────────────────────────────────────────────────── *)
PROCEDURE DrawLine(li, y: INTEGER);
VAR i, len, col, j: INTEGER;
    imgSrc: ARRAY 512 OF CHAR;
    imgFull: ARRAY 1024 OF CHAR;
    isImg: BOOLEAN;
BEGIN
  Terminal.Goto(1, y);
  isImg := FALSE;
  IF (li >= 0) & (li < nLines) & (lineLen[li] > 5) THEN
    i := lineOff[li];
    isImg := (wrapBuf[i]   = '[') & (wrapBuf[i+1] = 'I') &
             (wrapBuf[i+2] = 'M') & (wrapBuf[i+3] = 'G') & (wrapBuf[i+4] = ':')
  END;
  IF isImg THEN
    (* extract path from [IMG:path] and display via iTerm2 *)
    i := lineOff[li] + 5; j := 0;
    WHILE (wrapBuf[i] # ']') & (wrapBuf[i] # 0X) & (j < 511) DO
      imgSrc[j] := wrapBuf[i]; INC(i); INC(j)
    END;
    imgSrc[j] := 0X;
    ImgFullPath(imgSrc, imgFull);
    EmitImage(imgFull)
  ELSE
    Graphics.Color256(CLR_TEXT, BG_TEXT);
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
VAR pct, i: INTEGER;
BEGIN
  Terminal.Goto(1, tRows);
  Graphics.Color256(CLR_STATUS, BG_STATUS);
  i := 0; WHILE i < tCols DO Out.Char(' '); INC(i) END;
  Terminal.Goto(1, tRows);
  Out.String(bookTitle);
  Out.String("  ch "); Out.Int(curChap + 1); Out.String("/"); Out.Int(nSpine);
  IF nLines > 0 THEN
    pct := (topLine + visRows) * 100 DIV nLines;
    IF pct > 100 THEN pct := 100 END
  ELSE pct := 100
  END;
  Out.String("  "); Out.Int(pct); Out.String("%");
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

(* ── key handler ─────────────────────────────────────────────── *)
PROCEDURE HandleKey(k: INTEGER);
VAR found: INTEGER;
BEGIN
  statusMsg[0] := 0X;
  IF k = KEY_UP THEN
    DEC(topLine); ClampTop()
  ELSIF k = KEY_DOWN THEN
    INC(topLine); ClampTop()
  ELSIF k = KEY_PGUP THEN
    DEC(topLine, visRows); ClampTop(); SavePos()
  ELSIF k = KEY_PGDN THEN
    INC(topLine, visRows); ClampTop(); SavePos()
  ELSIF k = KEY_LEFT THEN
    IF curChap > 0 THEN
      DEC(curChap); topLine := 0; LoadChapter(); SavePos()
    END
  ELSIF k = KEY_RIGHT THEN
    IF curChap < nSpine - 1 THEN
      INC(curChap); topLine := 0; LoadChapter(); SavePos()
    END
  ELSIF k = KEY_CTRL_F THEN
    IF Prompt("Find: ", findStr) THEN
      found := FindNext(topLine + 1);
      IF found >= 0 THEN topLine := found; ClampTop()
      ELSE COPY("Not found.", statusMsg)
      END
    END
  ELSIF (k = KEY_CTRL_Q) OR (k = KEY_ESC) THEN
    SavePos(); running := FALSE
  END
END HandleKey;

(* ── main ──────────────────────────────────────────────────────── *)
VAR k: INTEGER;
BEGIN
  IF Args.Count() < 1 THEN
    Out.String("Usage: epub <file.epub>"); Out.Ln; HALT(1)
  END;
  Args.Get(1, epubPath);

  archive := Zip.Open(epubPath);
  IF archive = NIL THEN
    Out.String("Cannot open: "); Out.String(epubPath); Out.Ln; HALT(1)
  END;

  Dict.Init(idMap);
  nSpine := 0; curChap := 0; topLine := 0;
  bookTitle[0] := 0X; findStr[0] := 0X; statusMsg[0] := 0X;

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
  DrawAll();

  WHILE running DO
    k := ORD(Terminal.ReadKey());
    tCols := Terminal.Cols(); tRows := Terminal.Rows();
    visRows := tRows - 1;
    HandleKey(k);
    IF running THEN DrawAll() END
  END;

  Terminal.Clear()
END epub.
