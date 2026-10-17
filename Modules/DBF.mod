MODULE DBF;

(* dBASE/FoxPro database file format *)

IMPORT Files, Strings, Math, Time;

CONST
  MaxFields*  = 128;
  MaxRecLen*  = 4000;
  HeaderBase  = 32;
  FieldDescSz = 32;

  TypeChar*    = "C";
  TypeNumeric* = "N";
  TypeLogical* = "L";
  TypeMemo*    = "M";
  TypeDate*    = "D";
  TypeFloat*   = "F";

  MaxNdx*      = 65536;  (* max keys held by one in-memory NDX index *)
  MaxNdxKey*   = 100;    (* longest character key dBASE III allows *)
  NdxPage      = 512;
  MemoBlock    = 512;

TYPE
  Field* = RECORD
    name*: ARRAY 11 OF CHAR;
    type*: CHAR;
    len*:  BYTE;
    dec*:  BYTE;
  END;

  Database* = RECORD
    f*:         Files.File;
    r:          Files.Rider;
    numFields*: INTEGER;
    recordLen*: INTEGER;
    numRecs*:   INTEGER;
    headerLen*: INTEGER;
    fields*:    ARRAY MaxFields OF Field;
    version*:   INTEGER;  (* header byte 0: 03H plain, 83H with memo file *)
    year*, month*, day*: INTEGER;  (* date of last update *)
    touched:    BOOLEAN;  (* header date already refreshed this session *)
  END;

  (* One key of a dBASE III .NDX index, kept in memory.  Character keys
     are space-padded to the index key length; numeric and date keys use
     num (dates as Julian day numbers, as dBASE does). *)
  NdxEntry*    = POINTER TO NdxEntryRec;
  NdxEntryRec* = RECORD
    key*: ARRAY MaxNdxKey + 1 OF CHAR;
    num*: REAL;
    rec*: INTEGER;   (* 1-based record number *)
  END;

  NdxIndex* = POINTER TO NdxRec;
  NdxRec*   = RECORD
    expr*:    ARRAY 256 OF CHAR;
    numeric*: BOOLEAN;
    keyLen*:  INTEGER;
    unique*:  BOOLEAN;
    n*:       INTEGER;
    e*:       ARRAY MaxNdx OF NdxEntry;
  END;

  IndexEntry* = RECORD
    key:    ARRAY 256 OF CHAR;
    recNum: INTEGER;
  END;

  Index* = RECORD
    entries:   ARRAY 4096 OF IndexEntry;
    count*:    INTEGER;
    fieldIdx*: INTEGER;
  END;

  ValidationResult* = RECORD
    ok*:       BOOLEAN;
    recNum*:   INTEGER;
    fieldIdx*: INTEGER;
    msg*:      ARRAY 64 OF CHAR;
  END;

(* ---------------------------------------------------------------
 * Field descriptor constructor
 * --------------------------------------------------------------- *)

(** Fill a Field record. Keeps name copy inside DBF where the type is known. **)
PROCEDURE MakeField*(VAR f: Field; name: ARRAY OF CHAR; ftype: CHAR;
                     len, dec: BYTE);
VAR i, n: INTEGER;
BEGIN
  n := Strings.Length(name);
  IF n > 10 THEN n := 10 END;
  FOR i := 0 TO n - 1 DO f.name[i] := name[i] END;
  FOR i := n TO 10    DO f.name[i] := 0X      END;
  f.type := ftype;
  f.len  := len;
  f.dec  := dec
END MakeField;

(* ---------------------------------------------------------------
 * Low-level I/O helpers
 * --------------------------------------------------------------- *)

PROCEDURE WriteFixed(VAR r: Files.Rider; s: ARRAY OF CHAR; width: INTEGER);
VAR i, slen: INTEGER;
BEGIN
  slen := Strings.Length(s);
  IF slen > width THEN slen := width END;
  FOR i := 0 TO slen - 1 DO Files.Write(r, ORD(s[i])) END;
  FOR i := slen TO width - 1 DO Files.Write(r, 0) END
END WriteFixed;

PROCEDURE WriteFixedSpc(VAR r: Files.Rider; s: ARRAY OF CHAR; width: INTEGER);
VAR i, slen: INTEGER;
BEGIN
  slen := Strings.Length(s);
  IF slen > width THEN slen := width END;
  FOR i := 0 TO slen - 1 DO Files.Write(r, ORD(s[i])) END;
  FOR i := slen TO width - 1 DO Files.Write(r, ORD(" ")) END
END WriteFixedSpc;

PROCEDURE WriteWord(VAR r: Files.Rider; v: INTEGER);
BEGIN
  Files.Write(r, v MOD 256);
  Files.Write(r, (v DIV 256) MOD 256)
END WriteWord;

PROCEDURE WriteDWord(VAR r: Files.Rider; v: INTEGER);
BEGIN
  Files.Write(r, v MOD 256);
  Files.Write(r, (v DIV 256) MOD 256);
  Files.Write(r, (v DIV 65536) MOD 256);
  Files.Write(r, (v DIV 16777216) MOD 256)
END WriteDWord;

PROCEDURE ReadWord(VAR r: Files.Rider): INTEGER;
VAR lo, hi: BYTE;
BEGIN
  Files.Read(r, lo);
  Files.Read(r, hi);
  RETURN lo + hi * 256
END ReadWord;

PROCEDURE ReadDWord(VAR r: Files.Rider): INTEGER;
VAR b0, b1, b2, b3: BYTE;
BEGIN
  Files.Read(r, b0);
  Files.Read(r, b1);
  Files.Read(r, b2);
  Files.Read(r, b3);
  RETURN b0 + b1 * 256 + b2 * 65536 + b3 * 16777216
END ReadDWord;

PROCEDURE WriteRecCount(VAR db: Database);
BEGIN
  Files.Set(db.r, db.f, 4);
  WriteDWord(db.r, db.numRecs)
END WriteRecCount;

PROCEDURE FieldOffset(VAR db: Database; fieldIdx: INTEGER): INTEGER;
VAR i, off: INTEGER;
BEGIN
  off := 1;
  FOR i := 0 TO fieldIdx - 1 DO INC(off, db.fields[i].len) END;
  RETURN off
END FieldOffset;

(* Right-align a numeric string in a field of exactly 'width' bytes. *)
PROCEDURE WriteNumStr(VAR r: Files.Rider; s: ARRAY OF CHAR; width: INTEGER);
VAR i, slen, pad: INTEGER;
BEGIN
  slen := Strings.Length(s);
  IF slen > width THEN slen := width END;
  pad := width - slen;
  FOR i := 0 TO pad - 1 DO Files.Write(r, ORD(" ")) END;
  FOR i := 0 TO slen - 1 DO Files.Write(r, ORD(s[i])) END
END WriteNumStr;

(* ---------------------------------------------------------------
 * Create / Open / Close
 * --------------------------------------------------------------- *)

PROCEDURE Create*(VAR db: Database; filename: ARRAY OF CHAR;
                  VAR flds: ARRAY OF Field; n: INTEGER);
VAR
  i, recLen, hdrLen, yy, mm, dd: INTEGER;
  now: LONGINT;
  tmp: ARRAY 8 OF CHAR;
BEGIN
  db.f := Files.New(filename);
  IF db.f = NIL THEN RETURN END;

  db.numFields := n;
  db.numRecs   := 0;
  FOR i := 0 TO n - 1 DO db.fields[i] := flds[i] END;

  recLen := 1;
  FOR i := 0 TO n - 1 DO INC(recLen, db.fields[i].len) END;
  db.recordLen := recLen;

  hdrLen := HeaderBase + n * FieldDescSz + 1;
  db.headerLen := hdrLen;

  now := Time.Now();
  Time.Format(now, "%Y", tmp); Strings.StrToInt(tmp, yy);
  Time.Format(now, "%m", tmp); Strings.StrToInt(tmp, mm);
  Time.Format(now, "%d", tmp); Strings.StrToInt(tmp, dd);
  db.year := yy; db.month := mm; db.day := dd; db.touched := TRUE;

  db.version := 03H;
  FOR i := 0 TO n - 1 DO
    IF db.fields[i].type = TypeMemo THEN db.version := 83H END
  END;

  Files.Set(db.r, db.f, 0);
  Files.Write(db.r, db.version);
  Files.Write(db.r, yy - 1900);
  Files.Write(db.r, mm);
  Files.Write(db.r, dd);
  WriteDWord(db.r, 0);
  WriteWord(db.r, hdrLen);
  WriteWord(db.r, recLen);
  FOR i := 12 TO 31 DO Files.Write(db.r, 0) END;

  FOR i := 0 TO n - 1 DO
    WriteFixed(db.r, db.fields[i].name, 11);
    Files.Write(db.r, ORD(db.fields[i].type));
    Files.Write(db.r, 0); Files.Write(db.r, 0);
    Files.Write(db.r, 0); Files.Write(db.r, 0);
    Files.Write(db.r, db.fields[i].len);
    Files.Write(db.r, db.fields[i].dec);
    Files.Write(db.r, 0); Files.Write(db.r, 0);
    Files.Write(db.r, 0); Files.Write(db.r, 0);
    Files.Write(db.r, 0); Files.Write(db.r, 0);
    Files.Write(db.r, 0); Files.Write(db.r, 0);
    Files.Write(db.r, 0); Files.Write(db.r, 0);
    Files.Write(db.r, 0); Files.Write(db.r, 0);
    Files.Write(db.r, 0); Files.Write(db.r, 0)
  END;

  Files.Write(db.r, 0DH);
  Files.Write(db.r, 1AH);
  Files.Register(db.f)
END Create;

PROCEDURE Open*(VAR db: Database; filename: ARRAY OF CHAR);
VAR i, j: INTEGER; b: BYTE;
BEGIN
  db.f := Files.Old(filename);
  IF db.f = NIL THEN RETURN END;

  Files.Set(db.r, db.f, 0);
  Files.Read(db.r, b); db.version := b;
  Files.Read(db.r, b); db.year := b + 1900;
  IF db.year < 1980 THEN INC(db.year, 100) END;
  Files.Read(db.r, b); db.month := b;
  Files.Read(db.r, b); db.day := b;
  db.touched := FALSE;

  db.numRecs   := ReadDWord(db.r);
  db.headerLen := ReadWord(db.r);
  db.recordLen := ReadWord(db.r);

  (* Count descriptors up to the 0DH terminator rather than trusting
     headerLen, which some writers pad (FoxPro adds a 263-byte backlink). *)
  db.numFields := 0;
  LOOP
    IF (db.numFields >= MaxFields) OR
       (HeaderBase + (db.numFields + 1) * FieldDescSz > db.headerLen) THEN EXIT END;
    Files.Set(db.r, db.f, HeaderBase + db.numFields * FieldDescSz);
    Files.Read(db.r, b);
    IF (b = 0DH) OR (b = 0) OR db.r.eof THEN EXIT END;
    INC(db.numFields)
  END;

  FOR i := 0 TO db.numFields - 1 DO
    Files.Set(db.r, db.f, HeaderBase + i * FieldDescSz);
    FOR j := 0 TO 10 DO
      Files.Read(db.r, b); db.fields[i].name[j] := CHR(b)
    END;
    db.fields[i].name[10] := 0X;
    Files.Set(db.r, db.f, HeaderBase + i * FieldDescSz + 11);
    Files.Read(db.r, b);
    db.fields[i].type := CHR(b);
    Files.Read(db.r, b); Files.Read(db.r, b);
    Files.Read(db.r, b); Files.Read(db.r, b);
    Files.Read(db.r, db.fields[i].len);
    Files.Read(db.r, db.fields[i].dec)
  END
END Open;

PROCEDURE Close*(VAR db: Database);
BEGIN
  IF db.f # NIL THEN
    Files.Set(db.r, db.f, db.headerLen + db.numRecs * db.recordLen);
    Files.Write(db.r, 1AH);
    Files.Register(db.f);
    Files.Close(db.f);
    db.f := NIL
  END
END Close;

(* ---------------------------------------------------------------
 * Navigation
 * --------------------------------------------------------------- *)

PROCEDURE RecordCount*(VAR db: Database): INTEGER;
BEGIN
  RETURN db.numRecs
END RecordCount;

PROCEDURE SeekRecord*(VAR db: Database; recNum: INTEGER);
BEGIN
  Files.Set(db.r, db.f, db.headerLen + recNum * db.recordLen)
END SeekRecord;

PROCEDURE IsDeleted*(VAR db: Database; recNum: INTEGER): BOOLEAN;
VAR b: BYTE;
BEGIN
  Files.Set(db.r, db.f, db.headerLen + recNum * db.recordLen);
  Files.Read(db.r, b);
  RETURN b = ORD("*")
END IsDeleted;

(* ---------------------------------------------------------------
 * Field read
 * --------------------------------------------------------------- *)

PROCEDURE GetField*(VAR db: Database; recNum, fieldIdx: INTEGER;
                    VAR dst: ARRAY OF CHAR);
VAR i, flen, dlen: INTEGER; b: BYTE;
BEGIN
  flen := db.fields[fieldIdx].len;
  Files.Set(db.r, db.f,
    db.headerLen + recNum * db.recordLen + FieldOffset(db, fieldIdx));
  IF flen >= LEN(dst) THEN flen := LEN(dst) - 1 END;
  FOR i := 0 TO flen - 1 DO
    Files.Read(db.r, b);
    dst[i] := CHR(b)
  END;
  dst[flen] := 0X;
  dlen := flen;
  WHILE (dlen > 0) & (dst[dlen - 1] = " ") DO DEC(dlen) END;
  dst[dlen] := 0X
END GetField;

PROCEDURE GetFieldInt*(VAR db: Database; recNum, fieldIdx: INTEGER;
                       VAR n: INTEGER): BOOLEAN;
VAR buf: ARRAY 32 OF CHAR;
BEGIN
  GetField(db, recNum, fieldIdx, buf);
  Strings.Trim(buf);
  RETURN Strings.StrToInt(buf, n)
END GetFieldInt;

PROCEDURE GetFieldReal*(VAR db: Database; recNum, fieldIdx: INTEGER;
                        VAR x: REAL): BOOLEAN;
VAR buf: ARRAY 32 OF CHAR;
BEGIN
  GetField(db, recNum, fieldIdx, buf);
  Strings.Trim(buf);
  RETURN Strings.StrToReal(buf, x)
END GetFieldReal;

PROCEDURE GetFieldBool*(VAR db: Database; recNum, fieldIdx: INTEGER): BOOLEAN;
VAR buf: ARRAY 4 OF CHAR;
BEGIN
  GetField(db, recNum, fieldIdx, buf);
  RETURN (buf[0] = "T") OR (buf[0] = "t") OR (buf[0] = "Y") OR (buf[0] = "y")
END GetFieldBool;

PROCEDURE GetRecord*(VAR db: Database; recNum: INTEGER; VAR packed: ARRAY OF CHAR);
VAR i, j, ppos: INTEGER; tmp: ARRAY 256 OF CHAR;
BEGIN
  ppos := 0;
  packed[0] := 0X;
  FOR i := 0 TO db.numFields - 1 DO
    GetField(db, recNum, i, tmp);
    IF i > 0 THEN packed[ppos] := "|"; INC(ppos) END;
    j := 0;
    WHILE (tmp[j] # 0X) & (ppos < LEN(packed) - 1) DO
      packed[ppos] := tmp[j]; INC(ppos); INC(j)
    END
  END;
  packed[ppos] := 0X
END GetRecord;

(* ---------------------------------------------------------------
 * Field write (internal shared logic)
 * --------------------------------------------------------------- *)

(* Format an integer into a right-aligned numeric field string. *)
PROCEDURE FmtInt(n: INTEGER; VAR buf: ARRAY OF CHAR);
BEGIN
  Strings.IntToStr(n, buf)
END FmtInt;

(* Format a real into a fixed-point string with 'dec' decimal places. *)
PROCEDURE FmtReal(x: REAL; dec: INTEGER; VAR buf: ARRAY OF CHAR);
VAR
  i, iv, whole, frac, denom: INTEGER;
  scale: REAL;
  neg: BOOLEAN;
  ibuf, fbuf: ARRAY 32 OF CHAR;
BEGIN
  neg := x < 0.0;
  IF neg THEN x := -x END;

  IF dec <= 0 THEN
    Strings.IntToStr(Math.round(x), buf)
  ELSE
    scale := 1.0;
    FOR i := 0 TO dec - 1 DO scale := scale * 10.0 END;
    iv    := Math.round(x * scale);
    (* Split into whole and fractional integer parts *)
    denom := 1;
    FOR i := 0 TO dec - 1 DO denom := denom * 10 END;
    whole := iv DIV denom;
    frac  := iv MOD denom;
    Strings.IntToStr(whole, ibuf);
    Strings.IntToStr(frac,  fbuf);
    (* Left-pad fractional part with zeros to exactly dec digits *)
    WHILE Strings.Length(fbuf) < dec DO Strings.Insert("0", 0, fbuf) END;
    Strings.Copy(ibuf, buf);
    Strings.Append(".", buf);
    Strings.Append(fbuf, buf)
  END;

  IF neg THEN Strings.Insert("-", 0, buf) END
END FmtReal;

(* ---------------------------------------------------------------
 * Append
 * --------------------------------------------------------------- *)

(* Shared record-writing kernel used by both Append and Update. *)
PROCEDURE WritePackedFields(VAR db: Database; packed: ARRAY OF CHAR);
VAR i, pos, flen, slen, j: INTEGER;
BEGIN
  pos := 0;
  FOR i := 0 TO db.numFields - 1 DO
    flen := db.fields[i].len;
    slen := 0;
    WHILE (packed[pos + slen] # 0X) & (packed[pos + slen] # "|") & (slen < flen) DO
      INC(slen)
    END;
    IF db.fields[i].type = TypeNumeric THEN
      (* Right-align *)
      FOR j := 0 TO flen - slen - 1 DO Files.Write(db.r, ORD(" ")) END;
      FOR j := 0 TO slen - 1 DO Files.Write(db.r, ORD(packed[pos + j])) END
    ELSE
      (* Left-align, space-pad *)
      FOR j := 0 TO slen - 1 DO Files.Write(db.r, ORD(packed[pos + j])) END;
      FOR j := slen TO flen - 1 DO Files.Write(db.r, ORD(" ")) END
    END;
    INC(pos, slen);
    IF packed[pos] = "|" THEN INC(pos) END
  END
END WritePackedFields;

PROCEDURE AppendFields*(VAR db: Database; packed: ARRAY OF CHAR);
BEGIN
  Files.Set(db.r, db.f, db.headerLen + db.numRecs * db.recordLen);
  Files.Write(db.r, ORD(" "));
  WritePackedFields(db, packed);
  INC(db.numRecs);
  WriteRecCount(db);
  Files.Register(db.f)
END AppendFields;

PROCEDURE AppendFieldInt*(VAR db: Database; fieldIdx, n: INTEGER);
VAR buf: ARRAY 32 OF CHAR;
BEGIN
  FmtInt(n, buf);
  Files.Set(db.r, db.f,
    db.headerLen + (db.numRecs - 1) * db.recordLen + FieldOffset(db, fieldIdx));
  WriteNumStr(db.r, buf, db.fields[fieldIdx].len);
  Files.Register(db.f)
END AppendFieldInt;

(* ---------------------------------------------------------------
 * Update
 * --------------------------------------------------------------- *)

PROCEDURE UpdateField*(VAR db: Database; recNum, fieldIdx: INTEGER;
                       value: ARRAY OF CHAR);
VAR flen: INTEGER;
BEGIN
  flen := db.fields[fieldIdx].len;
  Files.Set(db.r, db.f,
    db.headerLen + recNum * db.recordLen + FieldOffset(db, fieldIdx));
  IF db.fields[fieldIdx].type = TypeNumeric THEN
    WriteNumStr(db.r, value, flen)
  ELSE
    WriteFixedSpc(db.r, value, flen)
  END;
  Files.Register(db.f)
END UpdateField;

PROCEDURE UpdateFieldInt*(VAR db: Database; recNum, fieldIdx, n: INTEGER);
VAR buf: ARRAY 32 OF CHAR;
BEGIN
  FmtInt(n, buf);
  Files.Set(db.r, db.f,
    db.headerLen + recNum * db.recordLen + FieldOffset(db, fieldIdx));
  WriteNumStr(db.r, buf, db.fields[fieldIdx].len);
  Files.Register(db.f)
END UpdateFieldInt;

PROCEDURE UpdateFieldReal*(VAR db: Database; recNum, fieldIdx: INTEGER; x: REAL);
VAR buf: ARRAY 32 OF CHAR;
BEGIN
  FmtReal(x, db.fields[fieldIdx].dec, buf);
  Files.Set(db.r, db.f,
    db.headerLen + recNum * db.recordLen + FieldOffset(db, fieldIdx));
  WriteNumStr(db.r, buf, db.fields[fieldIdx].len);
  Files.Register(db.f)
END UpdateFieldReal;

PROCEDURE UpdateFieldBool*(VAR db: Database; recNum, fieldIdx: INTEGER; v: BOOLEAN);
BEGIN
  Files.Set(db.r, db.f,
    db.headerLen + recNum * db.recordLen + FieldOffset(db, fieldIdx));
  IF v THEN Files.Write(db.r, ORD("T")) ELSE Files.Write(db.r, ORD("F")) END;
  Files.Register(db.f)
END UpdateFieldBool;

PROCEDURE UpdateRecord*(VAR db: Database; recNum: INTEGER; packed: ARRAY OF CHAR);
BEGIN
  Files.Set(db.r, db.f, db.headerLen + recNum * db.recordLen + 1);
  WritePackedFields(db, packed);
  Files.Register(db.f)
END UpdateRecord;

(* ---------------------------------------------------------------
 * Delete / Undelete / Pack
 * --------------------------------------------------------------- *)

PROCEDURE Delete*(VAR db: Database; recNum: INTEGER);
BEGIN
  Files.Set(db.r, db.f, db.headerLen + recNum * db.recordLen);
  Files.Write(db.r, ORD("*"));
  Files.Register(db.f)
END Delete;

PROCEDURE Undelete*(VAR db: Database; recNum: INTEGER);
BEGIN
  Files.Set(db.r, db.f, db.headerLen + recNum * db.recordLen);
  Files.Write(db.r, ORD(" "));
  Files.Register(db.f)
END Undelete;

PROCEDURE Pack*(VAR db: Database; filename: ARRAY OF CHAR);
VAR
  tmp: Database;
  tmpname: ARRAY 512 OF CHAR;
  buf: ARRAY MaxRecLen + 2 OF CHAR;
  i: INTEGER;
BEGIN
  Strings.Copy(filename, tmpname);
  Strings.Append(".tmp", tmpname);

  Create(tmp, tmpname, db.fields, db.numFields);
  IF tmp.f = NIL THEN RETURN END;

  FOR i := 0 TO db.numRecs - 1 DO
    ReadRec(db, i, buf);
    IF buf[0] # "*" THEN WriteRec(tmp, tmp.numRecs, buf) END
  END;

  Close(tmp);
  Close(db);
  Files.Delete(filename);
  Files.Rename(tmpname, filename);
  Open(db, filename)
END Pack;

(* ---------------------------------------------------------------
 * Search
 * --------------------------------------------------------------- *)

PROCEDURE Find*(VAR db: Database; fieldIdx: INTEGER;
                value: ARRAY OF CHAR): INTEGER;
VAR i: INTEGER; buf: ARRAY 256 OF CHAR;
BEGIN
  FOR i := 0 TO db.numRecs - 1 DO
    IF ~IsDeleted(db, i) THEN
      GetField(db, i, fieldIdx, buf);
      IF Strings.Compare(buf, value) = 0 THEN RETURN i END
    END
  END;
  RETURN -1
END Find;

PROCEDURE FindNext*(VAR db: Database; fieldIdx, fromRec: INTEGER;
                    value: ARRAY OF CHAR): INTEGER;
VAR i: INTEGER; buf: ARRAY 256 OF CHAR;
BEGIN
  FOR i := fromRec TO db.numRecs - 1 DO
    IF ~IsDeleted(db, i) THEN
      GetField(db, i, fieldIdx, buf);
      IF Strings.Compare(buf, value) = 0 THEN RETURN i END
    END
  END;
  RETURN -1
END FindNext;

(* ---------------------------------------------------------------
 * Index
 * --------------------------------------------------------------- *)

PROCEDURE BuildIndex*(VAR db: Database; fieldIdx: INTEGER; VAR idx: Index);
VAR i, j: INTEGER; buf: ARRAY 256 OF CHAR; tmp: IndexEntry;
BEGIN
  idx.count    := 0;
  idx.fieldIdx := fieldIdx;

  FOR i := 0 TO db.numRecs - 1 DO
    IF ~IsDeleted(db, i) & (idx.count < 4096) THEN
      GetField(db, i, fieldIdx, buf);
      Strings.Copy(buf, idx.entries[idx.count].key);
      idx.entries[idx.count].recNum := i;
      INC(idx.count)
    END
  END;

  (* Insertion sort *)
  FOR i := 1 TO idx.count - 1 DO
    tmp := idx.entries[i];
    j := i - 1;
    WHILE (j >= 0) & (Strings.Compare(idx.entries[j].key, tmp.key) > 0) DO
      idx.entries[j + 1] := idx.entries[j];
      DEC(j)
    END;
    idx.entries[j + 1] := tmp
  END
END BuildIndex;

PROCEDURE IndexFind*(VAR idx: Index; value: ARRAY OF CHAR): INTEGER;
VAR lo, hi, mid, cmp: INTEGER;
BEGIN
  lo := 0; hi := idx.count - 1;
  WHILE lo <= hi DO
    mid := (lo + hi) DIV 2;
    cmp := Strings.Compare(idx.entries[mid].key, value);
    IF cmp = 0 THEN RETURN idx.entries[mid].recNum
    ELSIF cmp < 0 THEN lo := mid + 1
    ELSE hi := mid - 1
    END
  END;
  RETURN -1
END IndexFind;

(* ---------------------------------------------------------------
 * Export to CSV
 * --------------------------------------------------------------- *)

PROCEDURE ExportCSV*(VAR db: Database; csvfile: ARRAY OF CHAR);
VAR
  f: Files.File;
  r: Files.Rider;
  i, j, k: INTEGER;
  buf: ARRAY 256 OF CHAR;
  needsQuote: BOOLEAN;
BEGIN
  f := Files.New(csvfile);
  IF f = NIL THEN RETURN END;
  Files.Set(r, f, 0);

  (* Header row *)
  FOR i := 0 TO db.numFields - 1 DO
    IF i > 0 THEN Files.Write(r, ORD(",")) END;
    j := 0;
    WHILE db.fields[i].name[j] # 0X DO
      Files.Write(r, ORD(db.fields[i].name[j])); INC(j)
    END
  END;
  Files.Write(r, 0DH); Files.Write(r, 0AH);

  (* Data rows *)
  FOR i := 0 TO db.numRecs - 1 DO
    IF ~IsDeleted(db, i) THEN
      FOR j := 0 TO db.numFields - 1 DO
        IF j > 0 THEN Files.Write(r, ORD(",")) END;
        GetField(db, i, j, buf);
        (* Check for comma or double-quote requiring quoting *)
        needsQuote := FALSE;
        k := 0;
        WHILE (buf[k] # 0X) & ~needsQuote DO
          IF (buf[k] = ",") OR (buf[k] = '"') THEN needsQuote := TRUE END;
          INC(k)
        END;
        IF needsQuote THEN Files.Write(r, ORD('"')) END;
        k := 0;
        WHILE buf[k] # 0X DO
          (* Escape embedded double-quotes by doubling them (RFC 4180) *)
          IF buf[k] = '"' THEN Files.Write(r, ORD('"')) END;
          Files.Write(r, ORD(buf[k]));
          INC(k)
        END;
        IF needsQuote THEN Files.Write(r, ORD('"')) END
      END;
      Files.Write(r, 0DH); Files.Write(r, 0AH)
    END
  END;

  Files.Register(f);
  Files.Close(f)
END ExportCSV;

(* ---------------------------------------------------------------
 * Validate
 * --------------------------------------------------------------- *)

PROCEDURE Validate*(VAR db: Database; VAR result: ValidationResult);
VAR
  i, j, k: INTEGER;
  buf: ARRAY 256 OF CHAR;
  dummy: REAL;
  bad: BOOLEAN;
BEGIN
  result.ok       := TRUE;
  result.recNum   := -1;
  result.fieldIdx := -1;
  result.msg[0]   := 0X;

  FOR i := 0 TO db.numRecs - 1 DO
    IF ~IsDeleted(db, i) THEN
      FOR j := 0 TO db.numFields - 1 DO
        GetField(db, i, j, buf);

        IF db.fields[j].type = TypeNumeric THEN
          Strings.Trim(buf);
          IF (Strings.Length(buf) > 0) & ~Strings.StrToReal(buf, dummy) THEN
            result.ok       := FALSE;
            result.recNum   := i;
            result.fieldIdx := j;
            Strings.Copy("Numeric field is not a valid number", result.msg);
            RETURN
          END

        ELSIF db.fields[j].type = TypeLogical THEN
          IF (buf[0] # "T") & (buf[0] # "t") &
             (buf[0] # "F") & (buf[0] # "f") &
             (buf[0] # "Y") & (buf[0] # "y") &
             (buf[0] # "N") & (buf[0] # "n") &
             (buf[0] # "?") & (buf[0] # " ") &
             (buf[0] # 0X) THEN
            result.ok       := FALSE;
            result.recNum   := i;
            result.fieldIdx := j;
            Strings.Copy("Logical field has invalid value", result.msg);
            RETURN
          END

        ELSIF db.fields[j].type = TypeChar THEN
          bad := FALSE; k := 0;
          WHILE (buf[k] # 0X) & ~bad DO
            IF (ORD(buf[k]) < 32) & (buf[k] # 09X) THEN bad := TRUE END;
            INC(k)
          END;
          IF bad THEN
            result.ok       := FALSE;
            result.recNum   := i;
            result.fieldIdx := j;
            Strings.Copy("Char field contains non-printable bytes", result.msg);
            RETURN
          END
        END
      END
    END
  END
END Validate;

(* ---------------------------------------------------------------
 * Raw record access
 *
 * A raw record buffer holds recordLen bytes: byte 0 is the deletion
 * flag (" " or "*"), followed by every field's bytes in order.  The
 * buffer is 0X-terminated after the last byte for convenience.
 * --------------------------------------------------------------- *)

(** Read record recNum (0-based) into buf.  Past the end, buf is blank. **)
PROCEDURE ReadRec*(VAR db: Database; recNum: INTEGER; VAR buf: ARRAY OF CHAR);
VAR i, n: INTEGER; b: BYTE;
BEGIN
  n := db.recordLen;
  IF n >= LEN(buf) THEN n := LEN(buf) - 1 END;
  IF (recNum < 0) OR (recNum >= db.numRecs) THEN
    FOR i := 0 TO n - 1 DO buf[i] := " " END
  ELSE
    Files.Set(db.r, db.f, db.headerLen + recNum * db.recordLen);
    FOR i := 0 TO n - 1 DO
      Files.Read(db.r, b);
      IF b = 0 THEN buf[i] := " " ELSE buf[i] := CHR(b) END
    END
  END;
  buf[n] := 0X
END ReadRec;

(* Stamp today's date into the header the first time a file is changed. *)
PROCEDURE Touch(VAR db: Database);
VAR tmp: ARRAY 8 OF CHAR; now: LONGINT; yy, mm, dd: INTEGER;
BEGIN
  IF ~db.touched THEN
    now := Time.Now();
    Time.Format(now, "%Y", tmp); Strings.StrToInt(tmp, yy);
    Time.Format(now, "%m", tmp); Strings.StrToInt(tmp, mm);
    Time.Format(now, "%d", tmp); Strings.StrToInt(tmp, dd);
    db.year := yy; db.month := mm; db.day := dd;
    Files.Set(db.r, db.f, 1);
    Files.Write(db.r, yy - 1900); Files.Write(db.r, mm); Files.Write(db.r, dd);
    db.touched := TRUE
  END
END Touch;

(** Write buf as record recNum (0-based).  recNum = numRecs appends. **)
PROCEDURE WriteRec*(VAR db: Database; recNum: INTEGER; buf: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  IF (recNum < 0) OR (recNum > db.numRecs) THEN RETURN END;
  Touch(db);
  Files.Set(db.r, db.f, db.headerLen + recNum * db.recordLen);
  FOR i := 0 TO db.recordLen - 1 DO
    IF (i < LEN(buf)) & (buf[i] # 0X) THEN Files.Write(db.r, ORD(buf[i]))
    ELSE Files.Write(db.r, ORD(" "))
    END
  END;
  IF recNum = db.numRecs THEN
    Files.Write(db.r, 1AH);
    INC(db.numRecs);
    WriteRecCount(db)
  END;
  Files.Register(db.f)
END WriteRec;

(** Byte offset of field fieldIdx inside a raw record buffer. **)
PROCEDURE FieldPos*(VAR db: Database; fieldIdx: INTEGER): INTEGER;
BEGIN
  RETURN FieldOffset(db, fieldIdx)
END FieldPos;

(** Discard every record (dBASE ZAP). **)
PROCEDURE Zap*(VAR db: Database; filename: ARRAY OF CHAR);
VAR flds: ARRAY MaxFields OF Field; i, n: INTEGER;
BEGIN
  n := db.numFields;
  FOR i := 0 TO n - 1 DO flds[i] := db.fields[i] END;
  Files.Close(db.f);
  db.f := NIL;
  Files.Delete(filename);
  Create(db, filename, flds, n)
END Zap;

(* ---------------------------------------------------------------
 * .NDX index files (dBASE III B+-tree format)
 *
 * Header block 0: root page (0), page count (4), key length (12),
 * keys per page (14), key type (16: 0 char, 1 numeric), key record
 * size (18, 4 bytes), unique flag (23), key expression (24).  Each 512-byte page holds a key count then
 * key records of (left page, record number, key).  Interior pages carry
 * one extra trailing page pointer; leaves have left page = 0.
 * --------------------------------------------------------------- *)

(** Allocate an empty index. **)
PROCEDURE NdxNew*(): NdxIndex;
VAR ix: NdxIndex;
BEGIN
  NEW(ix);
  ix.expr[0] := 0X; ix.numeric := FALSE; ix.keyLen := 0;
  ix.unique := FALSE; ix.n := 0;
  RETURN ix
END NdxNew;

PROCEDURE NdxRecSize(ix: NdxIndex): INTEGER;
VAR kl: INTEGER;
BEGIN
  IF ix.numeric THEN kl := 8 ELSE kl := ix.keyLen END;
  RETURN ((kl + 8 + 3) DIV 4) * 4
END NdxRecSize;

PROCEDURE PadTo(VAR r: Files.Rider; pos: INTEGER);
BEGIN
  WHILE Files.Pos(r) < pos DO Files.Write(r, 0) END
END PadTo;

PROCEDURE NdxWriteKey(VAR r: Files.Rider; ix: NdxIndex; e: NdxEntry);
VAR i: INTEGER; done: BOOLEAN;
BEGIN
  IF ix.numeric THEN
    Files.WriteReal(r, e.num)
  ELSE
    done := FALSE;
    FOR i := 0 TO ix.keyLen - 1 DO
      IF ~done & (e.key[i] = 0X) THEN done := TRUE END;
      IF done THEN Files.Write(r, ORD(" ")) ELSE Files.Write(r, ORD(e.key[i])) END
    END
  END
END NdxWriteKey;

(** Write ix to filename as a dBASE III .NDX file.  Entries must be sorted. **)
PROCEDURE NdxWrite*(ix: NdxIndex; filename: ARRAY OF CHAR): BOOLEAN;
VAR
  f: Files.File; r: Files.Rider;
  recSize, maxKeys, page, i, j, k, nLevel, nNext, per, extra, cnt, base: INTEGER;
  lvlPage, lvlLast, nxtPage, nxtLast: POINTER TO ARRAY OF INTEGER;
BEGIN
  f := Files.New(filename);
  IF f = NIL THEN RETURN FALSE END;
  recSize := NdxRecSize(ix);
  maxKeys := (NdxPage - 8) DIV recSize;
  IF maxKeys < 2 THEN maxKeys := 2 END;
  NEW(lvlPage, ix.n DIV maxKeys + 2); NEW(lvlLast, ix.n DIV maxKeys + 2);
  NEW(nxtPage, ix.n DIV maxKeys + 2); NEW(nxtLast, ix.n DIV maxKeys + 2);

  (* Leaf pages, filled evenly *)
  page := 1; nLevel := 0;
  IF ix.n = 0 THEN
    Files.Set(r, f, page * NdxPage);
    WriteDWord(r, 0);
    PadTo(r, (page + 1) * NdxPage);
    lvlPage[0] := page; lvlLast[0] := -1; nLevel := 1; INC(page)
  ELSE
    cnt := (ix.n + maxKeys - 1) DIV maxKeys;
    per := ix.n DIV cnt; extra := ix.n MOD cnt;
    base := 0;
    FOR i := 0 TO cnt - 1 DO
      k := per; IF i < extra THEN INC(k) END;
      Files.Set(r, f, page * NdxPage);
      WriteDWord(r, k);
      FOR j := base TO base + k - 1 DO
        WriteDWord(r, 0);
        WriteDWord(r, ix.e[j].rec);
        NdxWriteKey(r, ix, ix.e[j]);
        PadTo(r, page * NdxPage + 4 + (j - base + 1) * recSize)
      END;
      PadTo(r, (page + 1) * NdxPage);
      lvlPage[nLevel] := page; lvlLast[nLevel] := base + k - 1;
      INC(nLevel); INC(page); INC(base, k)
    END
  END;

  (* Interior levels until a single root remains *)
  WHILE nLevel > 1 DO
    cnt := (nLevel + maxKeys) DIV (maxKeys + 1);
    per := nLevel DIV cnt; extra := nLevel MOD cnt;
    base := 0; nNext := 0;
    FOR i := 0 TO cnt - 1 DO
      k := per; IF i < extra THEN INC(k) END;   (* k children *)
      Files.Set(r, f, page * NdxPage);
      WriteDWord(r, k - 1);
      FOR j := base TO base + k - 2 DO
        WriteDWord(r, lvlPage[j]);
        WriteDWord(r, 0);
        NdxWriteKey(r, ix, ix.e[lvlLast[j]]);
        PadTo(r, page * NdxPage + 4 + (j - base + 1) * recSize)
      END;
      WriteDWord(r, lvlPage[base + k - 1]);
      PadTo(r, (page + 1) * NdxPage);
      nxtPage[nNext] := page; nxtLast[nNext] := lvlLast[base + k - 1];
      INC(nNext); INC(page); INC(base, k)
    END;
    FOR i := 0 TO nNext - 1 DO lvlPage[i] := nxtPage[i]; lvlLast[i] := nxtLast[i] END;
    nLevel := nNext
  END;

  (* Header *)
  Files.Set(r, f, 0);
  WriteDWord(r, lvlPage[0]);
  WriteDWord(r, page);
  WriteDWord(r, 0);
  IF ix.numeric THEN WriteWord(r, 8) ELSE WriteWord(r, ix.keyLen) END;
  WriteWord(r, maxKeys);
  IF ix.numeric THEN WriteWord(r, 1) ELSE WriteWord(r, 0) END;
  WriteDWord(r, recSize);
  Files.Write(r, 0);
  IF ix.unique THEN Files.Write(r, 1) ELSE Files.Write(r, 0) END;
  i := 0;
  WHILE (ix.expr[i] # 0X) & (i < 255) DO Files.Write(r, ORD(ix.expr[i])); INC(i) END;
  Files.Write(r, 0);
  PadTo(r, NdxPage);
  Files.Register(f);
  Files.Close(f);
  RETURN TRUE
END NdxWrite;

PROCEDURE NdxReadPage(VAR r: Files.Rider; f: Files.File; ix: NdxIndex;
                      page, recSize, depth: INTEGER);
VAR
  k, i, j, left, rec: INTEGER; b: BYTE;
  kids: ARRAY 128 OF INTEGER;
  e: NdxEntry;
BEGIN
  IF (depth > 32) OR (page <= 0) THEN RETURN END;
  Files.Set(r, f, page * NdxPage);
  k := ReadDWord(r);
  IF (k < 0) OR (k > 126) THEN RETURN END;
  Files.Set(r, f, page * NdxPage + 4);
  left := ReadDWord(r);
  IF left # 0 THEN
    (* interior: k keyed children plus the trailing pointer *)
    FOR i := 0 TO k - 1 DO
      Files.Set(r, f, page * NdxPage + 4 + i * recSize);
      kids[i] := ReadDWord(r)
    END;
    Files.Set(r, f, page * NdxPage + 4 + k * recSize);
    kids[k] := ReadDWord(r);
    FOR i := 0 TO k DO
      IF kids[i] # 0 THEN NdxReadPage(r, f, ix, kids[i], recSize, depth + 1) END
    END
  ELSE
    FOR i := 0 TO k - 1 DO
      IF ix.n < MaxNdx THEN
        Files.Set(r, f, page * NdxPage + 4 + i * recSize + 4);
        rec := ReadDWord(r);
        NEW(e); e.rec := rec; e.num := 0.0; e.key[0] := 0X;
        IF ix.numeric THEN
          Files.ReadReal(r, e.num)
        ELSE
          FOR j := 0 TO ix.keyLen - 1 DO Files.Read(r, b); e.key[j] := CHR(b) END;
          e.key[ix.keyLen] := 0X
        END;
        ix.e[ix.n] := e; INC(ix.n)
      END
    END
  END
END NdxReadPage;

(** Load a .NDX file into memory.  Returns FALSE if it cannot be read. **)
PROCEDURE NdxRead*(filename: ARRAY OF CHAR; VAR ix: NdxIndex): BOOLEAN;
VAR f: Files.File; r: Files.Rider; root, kl, ktype, recSize, i: INTEGER; b: BYTE;
BEGIN
  f := Files.Old(filename);
  IF f = NIL THEN RETURN FALSE END;
  ix := NdxNew();
  Files.Set(r, f, 0);
  root := ReadDWord(r);
  i := ReadDWord(r); i := ReadDWord(r);
  kl := ReadWord(r);
  i := ReadWord(r);
  ktype := ReadWord(r);
  recSize := ReadDWord(r);
  Files.Read(r, b);
  Files.Read(r, b); ix.unique := b # 0;
  i := 0;
  LOOP
    Files.Read(r, b);
    IF (b = 0) OR r.eof OR (i >= 255) THEN EXIT END;
    ix.expr[i] := CHR(b); INC(i)
  END;
  ix.expr[i] := 0X;
  ix.numeric := ktype # 0;
  IF ix.numeric THEN ix.keyLen := 8 ELSE ix.keyLen := kl END;
  IF (kl <= 0) OR (kl > MaxNdxKey) OR (recSize < kl + 8) THEN
    Files.Close(f); RETURN FALSE
  END;
  NdxReadPage(r, f, ix, root, recSize, 0);
  Files.Close(f);
  RETURN TRUE
END NdxRead;

(* ---------------------------------------------------------------
 * .DBT memo files (dBASE III)
 *
 * 512-byte blocks; block 0 holds the next free block number.  Each memo
 * starts on a block boundary and ends with two 1AH bytes.  The memo
 * field in the .DBF holds the starting block as a 10-digit number.
 * --------------------------------------------------------------- *)

(** Derive the .DBT name that goes with a .DBF file name. **)
PROCEDURE MemoName*(dbfName: ARRAY OF CHAR; VAR dbtName: ARRAY OF CHAR);
VAR i, dot: INTEGER; upper: BOOLEAN;
BEGIN
  Strings.Copy(dbfName, dbtName);
  dot := -1; i := 0;
  WHILE dbtName[i] # 0X DO
    IF dbtName[i] = "." THEN dot := i ELSIF dbtName[i] = "/" THEN dot := -1 END;
    INC(i)
  END;
  upper := (dot >= 0) & (dbtName[dot + 1] >= "A") & (dbtName[dot + 1] <= "Z");
  IF dot >= 0 THEN dbtName[dot] := 0X END;
  IF upper THEN Strings.Append(".DBT", dbtName) ELSE Strings.Append(".dbt", dbtName) END
END MemoName;

(** Create an empty memo file. **)
PROCEDURE MemoCreate*(dbtName: ARRAY OF CHAR);
VAR f: Files.File; r: Files.Rider; i: INTEGER;
BEGIN
  f := Files.New(dbtName);
  IF f = NIL THEN RETURN END;
  Files.Set(r, f, 0);
  WriteDWord(r, 1);
  FOR i := 4 TO 15 DO Files.Write(r, 0) END;
  Files.Write(r, 03H);
  FOR i := 17 TO MemoBlock - 1 DO Files.Write(r, 0) END;
  Files.Register(f);
  Files.Close(f)
END MemoCreate;

(** Read the memo starting at block into text (truncated to fit). **)
PROCEDURE MemoRead*(dbtName: ARRAY OF CHAR; block: INTEGER; VAR text: ARRAY OF CHAR);
VAR f: Files.File; r: Files.Rider; i: INTEGER; b: BYTE;
BEGIN
  text[0] := 0X;
  IF block <= 0 THEN RETURN END;
  f := Files.Old(dbtName);
  IF f = NIL THEN RETURN END;
  Files.Set(r, f, block * MemoBlock);
  i := 0;
  LOOP
    Files.Read(r, b);
    IF r.eof OR (b = 1AH) OR (i >= LEN(text) - 1) THEN EXIT END;
    IF b # 0 THEN text[i] := CHR(b); INC(i) END
  END;
  text[i] := 0X;
  Files.Close(f)
END MemoRead;

(** Store text as a memo.  block is the memo's current starting block (0
    for none); it is rewritten in place when the new text fits in the
    blocks already used, otherwise appended.  Returns the block used. **)
PROCEDURE MemoWrite*(dbtName: ARRAY OF CHAR; VAR block: INTEGER; text: ARRAY OF CHAR);
VAR
  f: Files.File; r: Files.Rider;
  i, n, oldLen, next, need, have: INTEGER; b: BYTE;
BEGIN
  IF ~Files.Exists(dbtName) THEN MemoCreate(dbtName) END;
  f := Files.Old(dbtName);
  IF f = NIL THEN RETURN END;
  n := Strings.Length(text);
  IF n = 0 THEN block := 0; Files.Close(f); RETURN END;
  Files.Set(r, f, 0);
  next := ReadDWord(r);
  IF next < 1 THEN next := 1 END;
  need := (n + 2 + MemoBlock - 1) DIV MemoBlock;
  have := 0;
  IF block > 0 THEN
    Files.Set(r, f, block * MemoBlock);
    oldLen := 0;
    LOOP
      Files.Read(r, b);
      IF r.eof OR (b = 1AH) THEN EXIT END;
      INC(oldLen)
    END;
    have := (oldLen + 2 + MemoBlock - 1) DIV MemoBlock
  END;
  IF (block <= 0) OR (need > have) THEN
    block := next;
    next := block + need;
    Files.Set(r, f, 0);
    WriteDWord(r, next)
  END;
  Files.Set(r, f, block * MemoBlock);
  FOR i := 0 TO n - 1 DO Files.Write(r, ORD(text[i])) END;
  Files.Write(r, 1AH); Files.Write(r, 1AH);
  PadTo(r, (block + need) * MemoBlock);
  Files.Register(f);
  Files.Close(f)
END MemoWrite;

END DBF.
