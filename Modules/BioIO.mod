MODULE BioIO;
(*
  BioIO — Sequence file I/O for FASTA, FASTQ, and BED formats.
  Reader structs hold state across successive Read calls.
  Writers accept a Files.Rider set up by the caller (Files.New + Files.Set).
*)

IMPORT BioSeq, Env, Files, OS, Strings;

CONST
  LineBuf = 1024;

TYPE
  FastaRecord* = RECORD
    name* : ARRAY 128 OF CHAR;
    desc* : ARRAY 256 OF CHAR;
    seq*  : BioSeq.Seq
  END;

  FastqRecord* = RECORD
    name* : ARRAY 128 OF CHAR;
    seq*  : BioSeq.Seq;
    qual* : BioSeq.Seq
  END;

  BedRecord* = RECORD
    chrom*  : ARRAY 64 OF CHAR;
    start*  : INTEGER;
    end_*   : INTEGER;
    name*   : ARRAY 64 OF CHAR;
    score*  : INTEGER;
    strand* : CHAR
  END;

  (* buf / hasBuf hold the lookahead line between ReadFasta calls. *)
  FastaReader* = RECORD
    rider   : Files.Rider;
    done*   : BOOLEAN;
    buf     : ARRAY LineBuf OF CHAR;
    hasBuf  : BOOLEAN;
    tmpPath : ARRAY 1024 OF CHAR
  END;

  FastqReader* = RECORD
    rider   : Files.Rider;
    done*   : BOOLEAN;
    tmpPath : ARRAY 1024 OF CHAR
  END;

  BedReader* = RECORD
    rider   : Files.Rider;
    done*   : BOOLEAN;
    tmpPath : ARRAY 1024 OF CHAR
  END;

(* ------------------------------------------------------------------ *)
(*  Internal write helpers                                              *)
(* ------------------------------------------------------------------ *)

PROCEDURE WriteChar(VAR r: Files.Rider; c: CHAR);
BEGIN
  Files.Write(r, ORD(c))
END WriteChar;

PROCEDURE WriteStr(VAR r: Files.Rider; s: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (i < LEN(s)) & (s[i] # 0X) DO
    Files.Write(r, ORD(s[i])); INC(i)
  END
END WriteStr;

PROCEDURE WriteNL(VAR r: Files.Rider);
BEGIN
  Files.Write(r, 10)   (* LF *)
END WriteNL;

PROCEDURE WriteInt(VAR r: Files.Rider; n: INTEGER);
VAR buf: ARRAY 20 OF CHAR; i, j: INTEGER; tmp: CHAR;
BEGIN
  IF n < 0 THEN WriteChar(r, '-'); n := -n END;
  i := 0;
  IF n = 0 THEN buf[0] := '0'; i := 1
  ELSE
    WHILE n > 0 DO
      buf[i] := CHR(n MOD 10 + ORD('0')); n := n DIV 10; INC(i)
    END;
    j := 0;
    WHILE j < i DIV 2 DO
      tmp := buf[j]; buf[j] := buf[i-1-j]; buf[i-1-j] := tmp; INC(j)
    END
  END;
  buf[i] := 0X;
  WriteStr(r, buf)
END WriteInt;

(* ------------------------------------------------------------------ *)
(*  Internal parse helpers                                              *)
(* ------------------------------------------------------------------ *)

PROCEDURE StrLen(s: ARRAY OF CHAR): INTEGER;
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (i < LEN(s)) & (s[i] # 0X) DO INC(i) END;
  RETURN i
END StrLen;

PROCEDURE CopyStr(src: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR; maxLen: INTEGER);
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (i < maxLen - 1) & (i < LEN(src)) & (src[i] # 0X) DO
    dst[i] := src[i]; INC(i)
  END;
  dst[i] := 0X
END CopyStr;

PROCEDURE AtoI(s: ARRAY OF CHAR): INTEGER;
VAR n: INTEGER;
BEGIN
  n := 0;
  IF ~Strings.StrToInt(s, n) THEN n := 0 END;
  RETURN n
END AtoI;

PROCEDURE StripCR(VAR line: ARRAY OF CHAR; VAR n: INTEGER);
BEGIN
  IF (n > 0) & (line[n-1] = 0DX) THEN DEC(n); line[n] := 0X END
END StripCR;

PROCEDURE GetField(line: ARRAY OF CHAR; VAR pos: INTEGER;
                   VAR field: ARRAY OF CHAR; maxLen: INTEGER);
(* Extract one tab-delimited token from line[pos..] into field; advance pos past the tab. *)
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (pos < LEN(line)) & (line[pos] # 0X) &
        (line[pos] # 09X) & (i < maxLen - 1) DO
    field[i] := line[pos]; INC(i); INC(pos)
  END;
  field[i] := 0X;
  IF (pos < LEN(line)) & (line[pos] = 09X) THEN INC(pos) END
END GetField;

PROCEDURE IsBedSkip(VAR line: ARRAY OF CHAR): BOOLEAN;
BEGIN
  IF line[0] = 0X  THEN RETURN TRUE END;
  IF line[0] = '#' THEN RETURN TRUE END;
  IF (line[0]='t') & (line[1]='r') & (line[2]='a') &
     (line[3]='c') & (line[4]='k') THEN RETURN TRUE END;
  IF (line[0]='b') & (line[1]='r') & (line[2]='o') &
     (line[3]='w') & (line[4]='s') THEN RETURN TRUE END;
  RETURN FALSE
END IsBedSkip;

(* ------------------------------------------------------------------ *)
(*  Compressed-file helpers                                             *)
(* ------------------------------------------------------------------ *)

VAR tmpSeq: INTEGER;

PROCEDURE IsGzipped(path: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN Strings.EndsWith(path, ".gz")
END IsGzipped;

PROCEDURE MakeTmpPath(VAR path: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  IF ~Env.Get("TMPDIR", path) THEN COPY("/tmp", path) END;
  Strings.Append("/_bioio_", path);
  i := Strings.Length(path);
  path[i] := CHR(tmpSeq MOD 10 + ORD('0'));
  path[i+1] := 0X;
  Strings.Append(".tmp", path);
  tmpSeq := (tmpSeq + 1) MOD 10
END MakeTmpPath;

PROCEDURE GzOpen(path: ARRAY OF CHAR; VAR f: Files.File;
                 VAR tmpPath: ARRAY OF CHAR): BOOLEAN;
VAR cmd: ARRAY 2048 OF CHAR;
BEGIN
  IF IsGzipped(path) THEN
    MakeTmpPath(tmpPath);
    COPY("gunzip -c ", cmd);
    Strings.Append(path, cmd);
    Strings.Append(" > ", cmd);
    Strings.Append(tmpPath, cmd);
    IF OS.Exec(cmd) # 0 THEN
      tmpPath[0] := 0X; f := NIL; RETURN FALSE
    END;
    f := Files.Old(tmpPath);
    IF f = NIL THEN Files.Delete(tmpPath); tmpPath[0] := 0X; RETURN FALSE END
  ELSE
    f := Files.Old(path);
    tmpPath[0] := 0X
  END;
  RETURN f # NIL
END GzOpen;

(* ------------------------------------------------------------------ *)
(*  FASTA reader                                                        *)
(* ------------------------------------------------------------------ *)

PROCEDURE OpenFasta*(VAR r: FastaReader; path: ARRAY OF CHAR): BOOLEAN;
VAR f: Files.File;
BEGIN
  IF ~GzOpen(path, f, r.tmpPath) THEN r.done := TRUE; RETURN FALSE END;
  Files.Set(r.rider, f, 0);
  r.done   := FALSE;
  r.hasBuf := FALSE;
  r.buf[0] := 0X;
  RETURN TRUE
END OpenFasta;

PROCEDURE ReadFasta*(VAR r: FastaReader; VAR rec: FastaRecord): BOOLEAN;
VAR line: ARRAY LineBuf OF CHAR; i, j, n: INTEGER; scanning: BOOLEAN;
BEGIN
  IF r.done THEN RETURN FALSE END;

  (* Locate header line: use lookahead buffer or scan forward. *)
  IF r.hasBuf THEN
    i := 0;
    WHILE (i < LineBuf) & (r.buf[i] # 0X) DO line[i] := r.buf[i]; INC(i) END;
    line[i] := 0X;
    r.hasBuf := FALSE
  ELSE
    scanning := TRUE;
    WHILE scanning DO
      IF r.rider.eof THEN r.done := TRUE; RETURN FALSE END;
      Files.ReadLine(r.rider, line);
      IF r.rider.eof & (line[0] = 0X) THEN r.done := TRUE; RETURN FALSE END;
      IF line[0] = '>' THEN scanning := FALSE END
    END
  END;

  (* Parse ">name[ description]" *)
  i := 1; j := 0;
  WHILE (i < LineBuf) & (line[i] # 0X) & (line[i] # ' ') & (j < 127) DO
    rec.name[j] := line[i]; INC(i); INC(j)
  END;
  rec.name[j] := 0X;
  IF (i < LineBuf) & (line[i] = ' ') THEN INC(i) END;
  j := 0;
  WHILE (i < LineBuf) & (line[i] # 0X) & (j < 255) DO
    rec.desc[j] := line[i]; INC(i); INC(j)
  END;
  rec.desc[j] := 0X;

  IF rec.seq = NIL THEN BioSeq.New(rec.seq) END;
  BioSeq.FromStr(rec.seq, "");
  CopyStr(rec.name, rec.seq.name, 128);

  (* Accumulate sequence lines until the next header or EOF. *)
  scanning := TRUE;
  WHILE scanning DO
    IF r.rider.eof THEN r.done := TRUE; RETURN TRUE END;
    Files.ReadLine(r.rider, line);
    IF r.rider.eof & (line[0] = 0X) THEN r.done := TRUE; RETURN TRUE END;
    IF line[0] = '>' THEN
      CopyStr(line, r.buf, LineBuf);
      r.hasBuf := TRUE;
      scanning := FALSE
    ELSE
      n := StrLen(line); StripCR(line, n);
      IF n > 0 THEN BioSeq.Append(rec.seq, line, n) END
    END
  END;
  RETURN TRUE
END ReadFasta;

PROCEDURE CloseFasta*(VAR r: FastaReader);
BEGIN
  r.done := TRUE; r.hasBuf := FALSE;
  IF r.tmpPath[0] # 0X THEN Files.Delete(r.tmpPath); r.tmpPath[0] := 0X END
END CloseFasta;

PROCEDURE WriteFasta*(VAR r: Files.Rider; VAR rec: FastaRecord; width: INTEGER);
VAR i, col: INTEGER;
BEGIN
  WriteChar(r, '>'); WriteStr(r, rec.name);
  IF rec.desc[0] # 0X THEN WriteChar(r, ' '); WriteStr(r, rec.desc) END;
  WriteNL(r);
  IF width <= 0 THEN width := 60 END;
  i := 0; col := 0;
  WHILE i < BioSeq.Length(rec.seq) DO
    WriteChar(r, BioSeq.Get(rec.seq, i));
    INC(col); INC(i);
    IF col = width THEN WriteNL(r); col := 0 END
  END;
  IF col > 0 THEN WriteNL(r) END
END WriteFasta;

(* ------------------------------------------------------------------ *)
(*  FASTQ reader                                                        *)
(* ------------------------------------------------------------------ *)

PROCEDURE OpenFastq*(VAR r: FastqReader; path: ARRAY OF CHAR): BOOLEAN;
VAR f: Files.File;
BEGIN
  IF ~GzOpen(path, f, r.tmpPath) THEN r.done := TRUE; RETURN FALSE END;
  Files.Set(r.rider, f, 0);
  r.done := FALSE;
  RETURN TRUE
END OpenFastq;

PROCEDURE ReadFastq*(VAR r: FastqReader; VAR rec: FastqRecord): BOOLEAN;
VAR line: ARRAY LineBuf OF CHAR; i, j, n: INTEGER; scanning: BOOLEAN;
BEGIN
  IF r.done THEN RETURN FALSE END;

  (* Find '@' header line, skipping anything else (e.g. blank lines). *)
  scanning := TRUE;
  WHILE scanning DO
    IF r.rider.eof THEN r.done := TRUE; RETURN FALSE END;
    Files.ReadLine(r.rider, line);
    IF r.rider.eof & (line[0] = 0X) THEN r.done := TRUE; RETURN FALSE END;
    IF line[0] = '@' THEN scanning := FALSE END
  END;

  i := 1; j := 0;
  WHILE (i < LineBuf) & (line[i] # 0X) & (line[i] # ' ') & (j < 127) DO
    rec.name[j] := line[i]; INC(i); INC(j)
  END;
  rec.name[j] := 0X;

  (* Sequence line *)
  IF r.rider.eof THEN r.done := TRUE; RETURN FALSE END;
  Files.ReadLine(r.rider, line);
  n := StrLen(line); StripCR(line, n);
  IF rec.seq = NIL THEN BioSeq.New(rec.seq) END;
  BioSeq.FromStr(rec.seq, "");
  IF n > 0 THEN BioSeq.Append(rec.seq, line, n) END;

  (* '+' separator line — discard *)
  IF r.rider.eof THEN r.done := TRUE; RETURN FALSE END;
  Files.ReadLine(r.rider, line);

  (* Quality line *)
  IF r.rider.eof THEN r.done := TRUE; RETURN FALSE END;
  Files.ReadLine(r.rider, line);
  n := StrLen(line); StripCR(line, n);
  IF rec.qual = NIL THEN BioSeq.New(rec.qual) END;
  BioSeq.FromStr(rec.qual, "");
  IF n > 0 THEN BioSeq.Append(rec.qual, line, n) END;

  RETURN TRUE
END ReadFastq;

PROCEDURE CloseFastq*(VAR r: FastqReader);
BEGIN
  r.done := TRUE;
  IF r.tmpPath[0] # 0X THEN Files.Delete(r.tmpPath); r.tmpPath[0] := 0X END
END CloseFastq;

PROCEDURE WriteFastq*(VAR r: Files.Rider; VAR rec: FastqRecord);
VAR i, n: INTEGER;
BEGIN
  WriteChar(r, '@'); WriteStr(r, rec.name); WriteNL(r);
  i := 0; n := BioSeq.Length(rec.seq);
  WHILE i < n DO WriteChar(r, BioSeq.Get(rec.seq, i)); INC(i) END;
  WriteNL(r);
  Files.WriteLine(r, "+");
  i := 0; n := BioSeq.Length(rec.qual);
  WHILE i < n DO WriteChar(r, BioSeq.Get(rec.qual, i)); INC(i) END;
  WriteNL(r)
END WriteFastq;

(* ------------------------------------------------------------------ *)
(*  BED reader                                                          *)
(* ------------------------------------------------------------------ *)

PROCEDURE OpenBed*(VAR r: BedReader; path: ARRAY OF CHAR): BOOLEAN;
VAR f: Files.File;
BEGIN
  IF ~GzOpen(path, f, r.tmpPath) THEN r.done := TRUE; RETURN FALSE END;
  Files.Set(r.rider, f, 0);
  r.done := FALSE;
  RETURN TRUE
END OpenBed;

PROCEDURE ReadBed*(VAR r: BedReader; VAR rec: BedRecord): BOOLEAN;
VAR line: ARRAY LineBuf OF CHAR; pos: INTEGER; tmp: ARRAY 64 OF CHAR; scanning: BOOLEAN;
BEGIN
  IF r.done THEN RETURN FALSE END;

  scanning := TRUE;
  WHILE scanning DO
    IF r.rider.eof THEN r.done := TRUE; RETURN FALSE END;
    Files.ReadLine(r.rider, line);
    IF r.rider.eof & (line[0] = 0X) THEN r.done := TRUE; RETURN FALSE END;
    IF ~IsBedSkip(line) THEN scanning := FALSE END
  END;

  pos := 0;
  GetField(line, pos, rec.chrom, 64);
  GetField(line, pos, tmp, 64); rec.start := AtoI(tmp);
  GetField(line, pos, tmp, 64); rec.end_  := AtoI(tmp);

  (* Optional fields: name, score, strand — supply defaults first. *)
  rec.name[0] := '.'; rec.name[1] := 0X;
  rec.score   := 0;
  rec.strand  := '.';
  IF (pos < LEN(line)) & (line[pos] # 0X) THEN
    GetField(line, pos, rec.name, 64)
  END;
  IF (pos < LEN(line)) & (line[pos] # 0X) THEN
    GetField(line, pos, tmp, 64); rec.score := AtoI(tmp)
  END;
  IF (pos < LEN(line)) & (line[pos] # 0X) THEN
    GetField(line, pos, tmp, 64);
    IF (tmp[0] = '+') OR (tmp[0] = '-') THEN rec.strand := tmp[0] END
  END;
  RETURN TRUE
END ReadBed;

PROCEDURE CloseBed*(VAR r: BedReader);
BEGIN
  r.done := TRUE;
  IF r.tmpPath[0] # 0X THEN Files.Delete(r.tmpPath); r.tmpPath[0] := 0X END
END CloseBed;

PROCEDURE WriteBed*(VAR r: Files.Rider; VAR rec: BedRecord);
BEGIN
  WriteStr(r, rec.chrom); WriteChar(r, 09X);
  WriteInt(r, rec.start); WriteChar(r, 09X);
  WriteInt(r, rec.end_);  WriteChar(r, 09X);
  WriteStr(r, rec.name);  WriteChar(r, 09X);
  WriteInt(r, rec.score); WriteChar(r, 09X);
  WriteChar(r, rec.strand);
  WriteNL(r)
END WriteBed;

END BioIO.
