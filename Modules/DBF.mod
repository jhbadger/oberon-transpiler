MODULE DBF;

IMPORT Files, Strings, Time;

CONST
  MaxFields* = 32;
  HeaderSize = 32;
  FieldSize  = 32;
  
  (* Field Types *)
  TypeChar* = "C";
  TypeNumeric* = "N";
  TypeLogical* = "L";

TYPE
  Field* = RECORD
    name*: ARRAY 11 OF CHAR;
    type*: CHAR;
    len*:  BYTE;
    dec*:  BYTE; (* Decimal count for Numeric types *)
  END;

  Database* = RECORD
    f: Files.File;
    r: Files.Rider;
    numFields: INTEGER;
    recordLen: INTEGER;
    fields: ARRAY MaxFields OF Field;
  END;

(** Helper: Seek to a specific record (0-based) **)
PROCEDURE SeekRecord*(VAR db: Database; recNum: INTEGER);
VAR 
  offset, headerLen: INTEGER;
BEGIN
  (* DBF stores Header Length at offset 8 as a 16-bit value *)
  Files.Set(db.r, db.f, 8);
  Files.ReadInt(db.r, headerLen);
  
  offset := headerLen + (recNum * db.recordLen);
  Files.Set(db.r, db.f, offset);
END SeekRecord;

(** Initialize a new DBF file with current system date **)
PROCEDURE Create*(VAR db: Database; filename: ARRAY OF CHAR; fields: ARRAY OF Field; numFields: INTEGER);
VAR 
  i, val: INTEGER;
  now: LONGINT;
  dateStr: ARRAY 10 OF CHAR;
BEGIN
  db.f := Files.New(filename);
  IF db.f # NIL THEN
    Files.Set(db.r, db.f, 0);
    db.numFields := numFields;
    db.fields := fields;
    
    (* Version: dBase III (03X) *)
    Files.Write(db.r, 03X);
    
    (* Use Time module for header date: YY MM DD *)
    now := Time.Now();
    
    Time.Format(now, "%y", dateStr);
    IF Strings.StrToInt(dateStr, val) THEN Files.Write(db.r, CHR(val)) END;
    
    Time.Format(now, "%m", dateStr);
    IF Strings.StrToInt(dateStr, val) THEN Files.Write(db.r, CHR(val)) END;
    
    Time.Format(now, "%d", dateStr);
    IF Strings.StrToInt(dateStr, val) THEN Files.Write(db.r, CHR(val)) END;
    
    Files.WriteInt(db.r, 0); (* Initial Record Count *)
    
    db.recordLen := 1; (* 1 byte for deletion flag *)
    FOR i := 0 TO numFields - 1 DO
      INC(db.recordLen, fields[i].len);
    END;

    Files.WriteInt(db.r, HeaderSize + (numFields * FieldSize) + 1); (* Header Length *)
    Files.WriteInt(db.r, db.recordLen); (* Record Length *)
    
    (* Padding Reserved bytes *)
    FOR i := 0 TO 19 DO Files.Write(db.r, 0X) END;

    (* Field Descriptors *)
    FOR i := 0 TO numFields - 1 DO
      Files.WriteString(db.r, fields[i].name);
      Files.Set(db.r, db.f, HeaderSize + (i * FieldSize) + 11);
      Files.Write(db.r, ORD(fields[i].type));
      Files.WriteInt(db.r, 0); (* Reserved *)
      Files.Write(db.r, fields[i].len);
      Files.Write(db.r, fields[i].dec);
      FOR val := 0 TO 13 DO Files.Write(db.r, 0X) END;
    END;

    Files.Write(db.r, 0DX); (* Terminator *)
    Files.Register(db.f);
  END;
END Create;

(** Append a record. Data must be exactly recordLen-1 characters **)
PROCEDURE AppendRecord*(VAR db: Database; data: ARRAY OF CHAR);
VAR
  numRecs: INTEGER;
BEGIN
  Files.Set(db.r, db.f, Files.Length(db.f));
  Files.Write(db.r, 20X); (* Space = Not Deleted *)
  Files.WriteString(db.r, data);
  
  (* Update record count *)
  Files.Set(db.r, db.f, 4);
  Files.ReadInt(db.r, numRecs);
  INC(numRecs);
  Files.Set(db.r, db.f, 4);
  Files.WriteInt(db.r, numRecs);
END AppendRecord;

(** Linear Search for a value in a specific field **)
PROCEDURE Find*(VAR db: Database; fieldIdx: INTEGER; value: ARRAY OF CHAR): INTEGER;
VAR
  i, numRecs, fieldOffset: INTEGER;
  currentVal: ARRAY 256 OF CHAR;
BEGIN
  Files.Set(db.r, db.f, 4);
  Files.ReadInt(db.r, numRecs);

  fieldOffset := 1; 
  FOR i := 0 TO fieldIdx - 1 DO
    INC(fieldOffset, db.fields[i].len);
  END;

  FOR i := 0 TO numRecs - 1 DO
    SeekRecord(db, i);
    Files.Set(db.r, db.f, Files.Pos(db.r) + fieldOffset);
    Files.ReadString(db.r, currentVal);
    IF Strings.Compare(currentVal, value) = 0 THEN RETURN i END;
  END;
  RETURN -1;
END Find;

(** Read a record into a buffer **)
PROCEDURE GetRecord*(VAR db: Database; recIdx: INTEGER; VAR dst: ARRAY OF CHAR);
BEGIN
  SeekRecord(db, recIdx);
  Files.Set(db.r, db.f, Files.Pos(db.r) + 1); (* Skip deletion flag *)
  Files.ReadString(db.r, dst);
END GetRecord;

(** Close and finalize the file **)
PROCEDURE Close*(VAR db: Database);
BEGIN
  IF db.f # NIL THEN
    Files.Set(db.r, db.f, Files.Length(db.f));
    Files.Write(db.r, 1AX); (* EOF marker *)
    Files.Close(db.f);
  END;
END Close;

END DBF.