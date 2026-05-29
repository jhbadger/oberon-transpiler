MODULE BioAnnot;
(*
  BioAnnot — Genomic interval annotation (BED / GFF3).

  Features are stored in a flat array; Overlaps and Contains scan linearly.
  SortByPos orders the array by (chrom, start) using shell sort so that
  callers can iterate over a chromosome in coordinate order.

  NOTE: AnnotDB holds ARRAY 16384 OF Feature (~6.5 MB); declare it at
  module level, not as a local variable.

  BED loading:  chrom/start/end are mandatory; name/score/strand optional.
  GFF3 loading: seqname→chrom, feature-type→name, start is converted from
                1-based to 0-based; raw attributes string stored in attrs.
*)

IMPORT Files, Strings;

CONST
  MaxFeatures* = 16384;

TYPE
  Feature* = RECORD
    chrom*  : ARRAY 64  OF CHAR;
    start*  : INTEGER;            (* 0-based *)
    end_*   : INTEGER;            (* exclusive *)
    name*   : ARRAY 64  OF CHAR;
    score*  : REAL;
    strand* : CHAR;
    attrs*  : ARRAY 256 OF CHAR   (* raw GFF3 attributes or empty *)
  END;

  AnnotDB* = RECORD
    features* : ARRAY MaxFeatures OF Feature;
    count*    : INTEGER
  END;

(* ------------------------------------------------------------------ *)
(*  Private helpers                                                     *)
(* ------------------------------------------------------------------ *)

PROCEDURE GetField(line: ARRAY OF CHAR; VAR pos: INTEGER;
                   VAR field: ARRAY OF CHAR; maxLen: INTEGER);
(* Copy one tab-delimited token from line[pos..] into field; advance pos. *)
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

PROCEDURE AtoI(s: ARRAY OF CHAR): INTEGER;
VAR n: INTEGER;
BEGIN
  n := 0;
  IF ~Strings.StrToInt(s, n) THEN n := 0 END;
  RETURN n
END AtoI;

PROCEDURE AtoR(s: ARRAY OF CHAR): REAL;
VAR r: REAL;
BEGIN
  r := 0.0;
  IF ~Strings.StrToReal(s, r) THEN r := 0.0 END;
  RETURN r
END AtoR;

PROCEDURE IsSkip(line: ARRAY OF CHAR): BOOLEAN;
(* TRUE for blank lines, # comments, and BED track/browser headers. *)
BEGIN
  IF line[0] = 0X  THEN RETURN TRUE END;
  IF line[0] = '#' THEN RETURN TRUE END;
  IF (line[0]='t') & (line[1]='r') & (line[2]='a') &
     (line[3]='c') & (line[4]='k') THEN RETURN TRUE END;
  IF (line[0]='b') & (line[1]='r') & (line[2]='o') &
     (line[3]='w') & (line[4]='s') THEN RETURN TRUE END;
  RETURN FALSE
END IsSkip;

PROCEDURE StripCR(VAR line: ARRAY OF CHAR);
VAR n: INTEGER;
BEGIN
  n := Strings.Length(line);
  IF (n > 0) & (line[n - 1] = 0DX) THEN line[n - 1] := 0X END
END StripCR;

(* ------------------------------------------------------------------ *)
(*  Init / Add                                                          *)
(* ------------------------------------------------------------------ *)

PROCEDURE Init*(VAR db: AnnotDB);
BEGIN
  db.count := 0
END Init;

PROCEDURE Add*(VAR db: AnnotDB; VAR f: Feature): BOOLEAN;
(*
  Append f to db.  Returns FALSE (and does nothing) if the database is full.
*)
BEGIN
  IF db.count >= MaxFeatures THEN RETURN FALSE END;
  db.features[db.count] := f;
  INC(db.count);
  RETURN TRUE
END Add;

(* ------------------------------------------------------------------ *)
(*  LoadBed                                                             *)
(* ------------------------------------------------------------------ *)

PROCEDURE LoadBed*(VAR db: AnnotDB; path: ARRAY OF CHAR): INTEGER;
(*
  Parse a BED file and add features to db.
  Returns the number of features added, or -1 if the file cannot be opened.
  Mandatory columns: chrom, start, end.
  Optional: name, score (integer), strand.
*)
VAR
  f           : Files.File;
  r           : Files.Rider;
  line        : ARRAY 1024 OF CHAR;
  tmp         : ARRAY 64   OF CHAR;
  feat        : Feature;
  pos, added  : INTEGER;
  done        : BOOLEAN;
BEGIN
  f := Files.Old(path);
  IF f = NIL THEN RETURN -1 END;
  Files.Set(r, f, 0);
  added := 0;
  done  := FALSE;

  WHILE ~done DO
    IF r.eof THEN done := TRUE
    ELSE
      Files.ReadLine(r, line);
      IF r.eof & (line[0] = 0X) THEN done := TRUE
      ELSIF ~IsSkip(line) THEN
        StripCR(line);
        pos := 0;
        GetField(line, pos, feat.chrom,  64);
        GetField(line, pos, tmp,         64); feat.start := AtoI(tmp);
        GetField(line, pos, tmp,         64); feat.end_  := AtoI(tmp);
        feat.name[0]  := '.'; feat.name[1]  := 0X;
        feat.score    := 0.0;
        feat.strand   := '.';
        feat.attrs[0] := 0X;
        IF (pos < LEN(line)) & (line[pos] # 0X) THEN
          GetField(line, pos, feat.name, 64)
        END;
        IF (pos < LEN(line)) & (line[pos] # 0X) THEN
          GetField(line, pos, tmp, 64); feat.score := FLT(AtoI(tmp))
        END;
        IF (pos < LEN(line)) & (line[pos] # 0X) THEN
          GetField(line, pos, tmp, 64);
          IF (tmp[0] = '+') OR (tmp[0] = '-') THEN feat.strand := tmp[0] END
        END;
        IF (feat.chrom[0] # 0X) & Add(db, feat) THEN INC(added) END
      END
    END
  END;
  RETURN added
END LoadBed;

(* ------------------------------------------------------------------ *)
(*  LoadGFF                                                             *)
(* ------------------------------------------------------------------ *)

PROCEDURE LoadGFF*(VAR db: AnnotDB; path: ARRAY OF CHAR): INTEGER;
(*
  Parse a GFF3 file and add features to db.
  Returns count added, or -1 if the file cannot be opened.
  Columns: seqname, source, feature, start(1-based), end(1-based incl.),
           score, strand, frame, attributes.
  Conversion: our start = gff_start - 1; our end = gff_end (0-based excl.).
  The feature type (column 3) is stored in name.
  The raw attributes string (column 9) is stored in attrs.
*)
VAR
  f           : Files.File;
  r           : Files.Rider;
  line        : ARRAY 1024 OF CHAR;
  tmp         : ARRAY 64   OF CHAR;
  feat        : Feature;
  pos, added  : INTEGER;
  done        : BOOLEAN;
BEGIN
  f := Files.Old(path);
  IF f = NIL THEN RETURN -1 END;
  Files.Set(r, f, 0);
  added := 0;
  done  := FALSE;

  WHILE ~done DO
    IF r.eof THEN done := TRUE
    ELSE
      Files.ReadLine(r, line);
      IF r.eof & (line[0] = 0X) THEN done := TRUE
      ELSIF ~IsSkip(line) THEN
        StripCR(line);
        pos := 0;
        GetField(line, pos, feat.chrom, 64);   (* col 1: seqname *)
        GetField(line, pos, tmp,        64);   (* col 2: source — discard *)
        GetField(line, pos, feat.name,  64);   (* col 3: feature type *)
        GetField(line, pos, tmp,        64); feat.start := AtoI(tmp) - 1;
        GetField(line, pos, tmp,        64); feat.end_  := AtoI(tmp);
        GetField(line, pos, tmp,        64);   (* col 6: score *)
        IF tmp[0] = '.' THEN feat.score := 0.0
        ELSE feat.score := AtoR(tmp)
        END;
        feat.strand := '.';
        IF (pos < LEN(line)) & (line[pos] # 0X) THEN
          GetField(line, pos, tmp, 64);
          IF (tmp[0] = '+') OR (tmp[0] = '-') THEN feat.strand := tmp[0] END
        END;
        GetField(line, pos, tmp, 64);          (* col 8: frame — discard *)
        feat.attrs[0] := 0X;
        IF (pos < LEN(line)) & (line[pos] # 0X) THEN
          GetField(line, pos, feat.attrs, 256)
        END;
        IF (feat.chrom[0] # 0X) & Add(db, feat) THEN INC(added) END
      END
    END
  END;
  RETURN added
END LoadGFF;

(* ------------------------------------------------------------------ *)
(*  Overlaps / Contains                                                 *)
(* ------------------------------------------------------------------ *)

PROCEDURE Overlaps*(VAR db: AnnotDB; chrom: ARRAY OF CHAR;
                    start, end_: INTEGER;
                    VAR hits: ARRAY OF INTEGER; VAR n: INTEGER);
(*
  Return indices of all features on chrom that overlap [start, end_).
  Two half-open intervals overlap iff start < f.end_ AND f.start < end_.
  n is set to the count written into hits (capped at LEN(hits)).
*)
VAR i: INTEGER;
BEGIN
  n := 0;
  FOR i := 0 TO db.count - 1 DO
    IF (n < LEN(hits)) &
       (Strings.Compare(db.features[i].chrom, chrom) = 0) &
       (db.features[i].start < end_) &
       (start < db.features[i].end_) THEN
      hits[n] := i; INC(n)
    END
  END
END Overlaps;

PROCEDURE Contains*(VAR db: AnnotDB; chrom: ARRAY OF CHAR; pos: INTEGER;
                    VAR hits: ARRAY OF INTEGER; VAR n: INTEGER);
(*
  Return indices of all features on chrom that contain position pos
  (i.e. f.start <= pos < f.end_).
*)
VAR i: INTEGER;
BEGIN
  n := 0;
  FOR i := 0 TO db.count - 1 DO
    IF (n < LEN(hits)) &
       (Strings.Compare(db.features[i].chrom, chrom) = 0) &
       (db.features[i].start <= pos) &
       (pos < db.features[i].end_) THEN
      hits[n] := i; INC(n)
    END
  END
END Contains;

(* ------------------------------------------------------------------ *)
(*  SortByPos                                                           *)
(* ------------------------------------------------------------------ *)

PROCEDURE SortByPos*(VAR db: AnnotDB);
(*
  Sort db.features[0..count-1] by (chrom, start) using shell sort.
  After sorting, features on the same chromosome are in coordinate order.
*)
VAR
  gap, i, j, cmp : INTEGER;
  tmp             : Feature;
  done            : BOOLEAN;
BEGIN
  gap := db.count DIV 2;
  WHILE gap > 0 DO
    i := gap;
    WHILE i < db.count DO
      tmp  := db.features[i];
      j    := i;
      done := FALSE;
      WHILE (j >= gap) & ~done DO
        cmp := Strings.Compare(db.features[j - gap].chrom, tmp.chrom);
        IF (cmp > 0) OR ((cmp = 0) & (db.features[j - gap].start > tmp.start)) THEN
          db.features[j] := db.features[j - gap];
          j := j - gap
        ELSE
          done := TRUE
        END
      END;
      db.features[j] := tmp;
      INC(i)
    END;
    gap := gap DIV 2
  END
END SortByPos;

END BioAnnot.
