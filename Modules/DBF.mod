MODULE DBF;

(* dBASE/FoxPro database file format *)

IMPORT Files, Strings, Math, Time;

CONST
  MaxFields*  = 32;
  HeaderBase  = 32;
  FieldDescSz = 32;

  TypeChar*    = "C";
  TypeNumeric* = "N";
  TypeLogical* = "L";
  TypeMemo*    = "M";

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
  Time.Format(now, "%y", tmp); Strings.StrToInt(tmp, yy);
  Time.Format(now, "%m", tmp); Strings.StrToInt(tmp, mm);
  Time.Format(now, "%d", tmp); Strings.StrToInt(tmp, dd);

  Files.Set(db.r, db.f, 0);
  Files.Write(db.r, 03H);
  Files.Write(db.r, yy);
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
  Files.Register(db.f)
END Create;

PROCEDURE Open*(VAR db: Database; filename: ARRAY OF CHAR);
VAR i: INTEGER; b: BYTE;
BEGIN
  db.f := Files.Old(filename);
  IF db.f = NIL THEN RETURN END;

  Files.Set(db.r, db.f, 0);
  Files.Read(db.r, b);
  Files.Read(db.r, b); Files.Read(db.r, b); Files.Read(db.r, b);

  db.numRecs   := ReadDWord(db.r);
  db.headerLen := ReadWord(db.r);
  db.recordLen := ReadWord(db.r);

  db.numFields := (db.headerLen - HeaderBase - 1) DIV FieldDescSz;
  IF db.numFields > MaxFields THEN db.numFields := MaxFields END;

  FOR i := 0 TO db.numFields - 1 DO
    Files.Set(db.r, db.f, HeaderBase + i * FieldDescSz);
    Files.ReadString(db.r, db.fields[i].name);
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
  packed: ARRAY 4096 OF CHAR;
  i: INTEGER;
BEGIN
  Strings.Copy(filename, tmpname);
  Strings.Append(".tmp", tmpname);

  Create(tmp, tmpname, db.fields, db.numFields);
  IF tmp.f = NIL THEN RETURN END;

  FOR i := 0 TO db.numRecs - 1 DO
    IF ~IsDeleted(db, i) THEN
      GetRecord(db, i, packed);
      AppendFields(tmp, packed)
    END
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

END DBF.