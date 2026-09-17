MODULE ZipWriter;
(*
 * ZipWriter - minimal deterministic ZIP writer for stored (uncompressed)
 * entries, extracted from plume.mod's hand-rolled EPUB packaging so
 * ostar.mod and plume.mod (and any future EPUB/DOCX-style consumer of
 * Markdown.mod's text generators) share one archive writer instead of
 * each re-deriving CRC-32 by hand. No compression, no external
 * dependency: entries are stored verbatim, which every ZIP/EPUB
 * reader accepts.
 *
 * Usage:
 *   ok := ZipWriter.Begin(outPath);                 (* opens outPath        *)
 *   ok := ZipWriter.Add("mimetype", tmpPathA);       (* first entry: stored,
 *                                                  as EPUB requires    *)
 *   ok := ZipWriter.Add("META-INF/container.xml", tmpPathB);
 *   ...
 *   ok := ZipWriter.Finish();                        (* central directory,
 *                                                  EOCD, close        *)
 *
 * Each entry's bytes come from an existing file on disk — typically a
 * temp file a caller filled via Markdown.mod's WriteProc sink. Zip.mod
 * itself does no text generation.
 *)

IMPORT Files, Strings;

CONST
  MaxEntries* = 32;

VAR
  MININT   : INTEGER;
  crcTab   : ARRAY 256 OF INTEGER;
  crcReady : BOOLEAN;
  outF     : Files.File;
  outR     : Files.Rider;
  zNm      : ARRAY MaxEntries OF ARRAY 128 OF CHAR;
  zCrc     : ARRAY MaxEntries OF INTEGER;
  zSz      : ARRAY MaxEntries OF INTEGER;
  zOff     : ARRAY MaxEntries OF INTEGER;
  zCnt     : INTEGER;
  active   : BOOLEAN;

(* ── CRC-32 (reflected, polynomial 0xEDB88320) ──────────────────────
   This Oberon dialect has no bitwise XOR or logical-shift-right on
   INTEGER (only ASR/LSL/ROR — see stdlib), so CRC-32's XOR and
   unsigned shifts are built from MOD/DIV arithmetic instead. Ported
   from plume.mod's Xor32/Lsr1/Lsr8/CrcByte, proven correct there
   (matches the standard table-based CRC-32 algorithm; -306674912 is
   the reflected polynomial 0xEDB88320 as a signed 32-bit value). *)

PROCEDURE Lsr1(x: INTEGER): INTEGER;
BEGIN
  IF x < 0 THEN RETURN ASR(x, 1) - MININT ELSE RETURN ASR(x, 1) END
END Lsr1;

PROCEDURE Xor32(a, b: INTEGER): INTEGER;
VAR r, bit, ba, bb: INTEGER;
BEGIN
  r := 0; bit := 1;
  WHILE bit < 1073741824 DO
    ba := a MOD (bit + bit) DIV bit;
    bb := b MOD (bit + bit) DIV bit;
    IF ba # bb THEN r := r + bit END;
    bit := bit + bit
  END;
  IF ((a >= 0) & (a < 1073741824)) OR (a < -1073741824) THEN ba := 0 ELSE ba := 1 END;
  IF ((b >= 0) & (b < 1073741824)) OR (b < -1073741824) THEN bb := 0 ELSE bb := 1 END;
  IF ba # bb THEN r := r + 1073741824 END;
  IF (a < 0) # (b < 0) THEN r := r + MININT END;
  RETURN r
END Xor32;

PROCEDURE Lsr8(x: INTEGER): INTEGER;
VAR i: INTEGER;
BEGIN i := 8; WHILE i > 0 DO x := Lsr1(x); DEC(i) END; RETURN x END Lsr8;

PROCEDURE InitCrcTable;
VAR n, k, c: INTEGER;
BEGIN
  MININT := LSL(1, 31);
  n := 0;
  WHILE n < 256 DO
    c := n; k := 8;
    WHILE k > 0 DO
      IF c MOD 2 = 1 THEN c := Xor32(-306674912, Lsr1(c)) ELSE c := Lsr1(c) END;
      DEC(k)
    END;
    crcTab[n] := c; INC(n)
  END;
  crcReady := TRUE
END InitCrcTable;

PROCEDURE CrcOfFile(path: ARRAY OF CHAR; VAR crc, sz: INTEGER): BOOLEAN;
VAR f: Files.File; r: Files.Rider; b, idx: INTEGER;
BEGIN
  IF ~crcReady THEN InitCrcTable END;
  crc := -1; sz := 0;
  f := Files.Old(path);
  IF f = NIL THEN RETURN FALSE END;
  Files.Set(r, f, 0);
  Files.Read(r, b);
  WHILE ~r.eof DO
    idx := Xor32(crc MOD 256, b);
    crc := Xor32(crcTab[idx], Lsr8(crc));
    INC(sz);
    Files.Read(r, b)
  END;
  Files.Close(f);
  crc := Xor32(crc, -1);
  RETURN TRUE
END CrcOfFile;

(* ── little-endian primitives, straight to the archive rider ──────── *)

PROCEDURE WleU16(n: INTEGER);
BEGIN
  Files.Write(outR, CHR(n MOD 256)); Files.Write(outR, CHR(n DIV 256 MOD 256))
END WleU16;

PROCEDURE WleU32(n: INTEGER);
VAR b: INTEGER;
BEGIN
  b := n MOD 256; Files.Write(outR, CHR(b)); n := (n - b) DIV 256;
  b := n MOD 256; Files.Write(outR, CHR(b)); n := (n - b) DIV 256;
  b := n MOD 256; Files.Write(outR, CHR(b)); n := (n - b) DIV 256;
  Files.Write(outR, CHR(n MOD 256))
END WleU32;

PROCEDURE WRawStr(s: ARRAY OF CHAR);
(* Files.WriteString appends a NUL terminator — wrong for a ZIP name
   field, which must be exactly its declared length. *)
VAR i: INTEGER;
BEGIN i := 0; WHILE s[i] # 0X DO Files.Write(outR, s[i]); INC(i) END END WRawStr;

PROCEDURE CopyBytes(path: ARRAY OF CHAR);
VAR f: Files.File; r: Files.Rider; b: INTEGER;
BEGIN
  f := Files.Old(path);
  IF f # NIL THEN
    Files.Set(r, f, 0);
    Files.Read(r, b);
    WHILE ~r.eof DO Files.Write(outR, CHR(b)); Files.Read(r, b) END;
    Files.Close(f)
  END
END CopyBytes;

(* ── public API ──────────────────────────────────────────────────── *)

PROCEDURE Begin*(outPath: ARRAY OF CHAR): BOOLEAN;
(* Open outPath and start a fresh archive. *)
BEGIN
  outF := Files.New(outPath);
  active := outF # NIL;
  IF active THEN Files.Set(outR, outF, 0); zCnt := 0 END;
  RETURN active
END Begin;

PROCEDURE Add*(name, srcPath: ARRAY OF CHAR): BOOLEAN;
(* Append one stored entry, its bytes copied verbatim from srcPath.
   Entries land in the archive in Add call order — callers packing an
   EPUB must Add "mimetype" first. Returns FALSE (archive left as-is)
   if not Begin'd, srcPath can't be opened, or MaxEntries is full. *)
VAR crc, sz, off, nl: INTEGER;
BEGIN
  IF ~active OR (zCnt >= MaxEntries) THEN RETURN FALSE END;
  IF ~CrcOfFile(srcPath, crc, sz) THEN RETURN FALSE END;
  off := Files.Pos(outR);
  nl := Strings.Length(name);
  WleU32(67324752); WleU16(20); WleU16(2048); WleU16(0); WleU16(0); WleU16(33);
  WleU32(crc); WleU32(sz); WleU32(sz); WleU16(nl); WleU16(0);
  WRawStr(name);
  CopyBytes(srcPath);
  zOff[zCnt] := off; zCrc[zCnt] := crc; zSz[zCnt] := sz;
  COPY(name, zNm[zCnt]); INC(zCnt);
  RETURN TRUE
END Add;

PROCEDURE Finish*(): BOOLEAN;
(* Write the central directory and end-of-central-directory record,
   then close and register the archive. *)
VAR cdOff, cdSz, i: INTEGER;
BEGIN
  IF ~active THEN RETURN FALSE END;
  cdOff := Files.Pos(outR);
  i := 0;
  WHILE i < zCnt DO
    WleU32(33639248); WleU16(20); WleU16(20); WleU16(2048); WleU16(0); WleU16(0); WleU16(33);
    WleU32(zCrc[i]); WleU32(zSz[i]); WleU32(zSz[i]);
    WleU16(Strings.Length(zNm[i])); WleU16(0); WleU16(0);
    WleU16(0); WleU16(0); WleU32(0); WleU32(zOff[i]);
    WRawStr(zNm[i]);
    INC(i)
  END;
  cdSz := Files.Pos(outR) - cdOff;
  WleU32(101010256); WleU16(0); WleU16(0); WleU16(zCnt); WleU16(zCnt);
  WleU32(cdSz); WleU32(cdOff); WleU16(0);
  Files.Register(outF); Files.Close(outF);
  active := FALSE;
  RETURN TRUE
END Finish;

END ZipWriter.
