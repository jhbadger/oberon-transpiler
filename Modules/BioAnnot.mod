MODULE BioAnnot;
(*
  BioAnnot — Genomic interval annotation (BED / GFF3).

  Features are stored in a flat array sorted by (chrom, start) after
  SortByPos.  The Dict index maps each chromosome to "start,count"
  (its contiguous slice in the sorted array), enabling O(1) chromosome
  lookup in Overlaps and Contains.

  Index lifecycle:
    Init        — empty dict, no index
    LoadBed/Add — index invalidated (sentinel "~SORTED" removed)
    SortByPos   — sorts then rebuilds the full index
    Overlaps/Contains — use index if valid; fall back to linear scan

  NOTE: AnnotDB (~6.5 MB for the feature array) should be declared at
  module level, not as a local variable.

  BED loading:  chrom/start/end mandatory; name/score/strand optional.
  GFF3 loading: seqname→chrom, feature-type→name, start converted from
                1-based to 0-based; raw attributes string stored in attrs.
*)

IMPORT Files, Strings, Dict;

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
    count*    : INTEGER;
    index*    : Dict.Table        (* chrom -> "start,count" after SortByPos *)
  END;

(* ------------------------------------------------------------------ *)
(*  Private helpers                                                     *)
(* ------------------------------------------------------------------ *)

PROCEDURE GetField(line: ARRAY OF CHAR; VAR pos: INTEGER;
                   VAR field: ARRAY OF CHAR; maxLen: INTEGER);
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

PROCEDURE IndexRange(VAR db: AnnotDB; chrom: ARRAY OF CHAR;
                     VAR lo, lim: INTEGER): BOOLEAN;
(*
  If the index is valid, set lo/lim to the slice [lo,lim) for chrom and
  return TRUE.  Return FALSE if the index is absent or chrom is unknown.
*)
VAR
  val               : ARRAY 256 OF CHAR;   (* Dict.Get writes up to 256 bytes *)
  spart, cpart      : ARRAY 32  OF CHAR;
  cp, cnt           : INTEGER;
  ok                : BOOLEAN;
BEGIN
  IF ~Dict.Has(db.index, "~SORTED") THEN RETURN FALSE END;
  IF ~Dict.Get(db.index, chrom, val)  THEN RETURN FALSE END;
  cp := Strings.Pos(",", val);
  IF cp < 0 THEN RETURN FALSE END;
  Strings.Extract(val, 0, cp, spart);
  Strings.Extract(val, cp + 1, Strings.Length(val) - cp - 1, cpart);
  ok := Strings.StrToInt(spart, lo);
  IF ok THEN ok := Strings.StrToInt(cpart, cnt) END;
  IF ok THEN lim := lo + cnt END;
  RETURN ok
END IndexRange;

(* ------------------------------------------------------------------ *)
(*  Init / Add                                                          *)
(* ------------------------------------------------------------------ *)

PROCEDURE Init*(VAR db: AnnotDB);
BEGIN
  db.count := 0;
  Dict.Init(db.index)
END Init;

PROCEDURE Add*(VAR db: AnnotDB; VAR f: Feature): BOOLEAN;
(*
  Append f to db.  Returns FALSE if the database is full.
  Invalidates the chromosome index so queries fall back to linear scan
  until SortByPos is called again.
*)
BEGIN
  IF db.count >= MaxFeatures THEN RETURN FALSE END;
  db.features[db.count] := f;
  INC(db.count);
  Dict.Remove(db.index, "~SORTED");
  RETURN TRUE
END Add;

(* ------------------------------------------------------------------ *)
(*  LoadBed                                                             *)
(* ------------------------------------------------------------------ *)

PROCEDURE LoadBed*(VAR db: AnnotDB; path: ARRAY OF CHAR): INTEGER;
(*
  Parse a BED file and add features to db.
  Returns the number of features added, or -1 if the file cannot be opened.
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
  GFF3 start (1-based) → 0-based; end (1-based inclusive) → 0-based exclusive.
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
        GetField(line, pos, feat.chrom, 64);
        GetField(line, pos, tmp,        64);   (* source — discard *)
        GetField(line, pos, feat.name,  64);   (* feature type *)
        GetField(line, pos, tmp,        64); feat.start := AtoI(tmp) - 1;
        GetField(line, pos, tmp,        64); feat.end_  := AtoI(tmp);
        GetField(line, pos, tmp,        64);
        IF tmp[0] = '.' THEN feat.score := 0.0
        ELSE feat.score := AtoR(tmp)
        END;
        feat.strand := '.';
        IF (pos < LEN(line)) & (line[pos] # 0X) THEN
          GetField(line, pos, tmp, 64);
          IF (tmp[0] = '+') OR (tmp[0] = '-') THEN feat.strand := tmp[0] END
        END;
        GetField(line, pos, tmp, 64);          (* frame — discard *)
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
  Uses the Dict index when available (after SortByPos); otherwise linear scan.
*)
VAR i, lo, lim : INTEGER;
BEGIN
  n := 0;
  IF IndexRange(db, chrom, lo, lim) THEN
    (* chrom absent from a valid index → nothing to report *)
  ELSE
    lo := 0; lim := db.count
  END;
  FOR i := lo TO lim - 1 DO
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
  Return indices of all features on chrom where f.start <= pos < f.end_.
  Uses the Dict index when available; otherwise linear scan.
*)
VAR i, lo, lim : INTEGER;
BEGIN
  n := 0;
  IF IndexRange(db, chrom, lo, lim) THEN
  ELSE
    lo := 0; lim := db.count
  END;
  FOR i := lo TO lim - 1 DO
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
  Sort db.features[0..count-1] by (chrom, start) using shell sort, then
  rebuild the Dict index so that each chromosome maps to "start,count".
*)
VAR
  gap, i, j, cmp     : INTEGER;
  tmp                 : Feature;
  done                : BOOLEAN;
  curChrom            : ARRAY 64 OF CHAR;
  val, numStr         : ARRAY 32 OF CHAR;
  chromStart, chromCount : INTEGER;
BEGIN
  (* Shell sort by (chrom, start) *)
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
  END;

  (* Rebuild chromosome index *)
  Dict.Clear(db.index);
  i := 0;
  WHILE i < db.count DO
    COPY(db.features[i].chrom, curChrom);
    chromStart := i;
    WHILE (i < db.count) &
          (Strings.Compare(db.features[i].chrom, curChrom) = 0) DO
      INC(i)
    END;
    chromCount := i - chromStart;
    Strings.IntToStr(chromStart, val);
    Strings.Append(",", val);
    Strings.IntToStr(chromCount, numStr);
    Strings.Append(numStr, val);
    Dict.Put(db.index, curChrom, val)
  END;
  Dict.Put(db.index, "~SORTED", "1")
END SortByPos;

(* ------------------------------------------------------------------ *)
(*  Coverage                                                            *)
(* ------------------------------------------------------------------ *)

PROCEDURE Coverage*(VAR db: AnnotDB; chrom: ARRAY OF CHAR;
                    VAR depths: ARRAY OF INTEGER; n: INTEGER);
(*
  Compute per-base coverage depth for positions [0, n) on chrom.
  depths[p] is incremented by 1 for each feature whose [start, end_) covers p.
  The caller must zero-initialise depths before calling.
  Uses the Dict index when available (after SortByPos); otherwise linear scan.
*)
VAR
  i, lo, lim : INTEGER;
  lo2, hi    : INTEGER;
BEGIN
  IF IndexRange(db, chrom, lo, lim) THEN
  ELSE
    lo := 0; lim := db.count
  END;
  FOR i := lo TO lim - 1 DO
    IF Strings.Compare(db.features[i].chrom, chrom) = 0 THEN
      lo2 := db.features[i].start;
      hi  := db.features[i].end_;
      IF lo2 < 0    THEN lo2 := 0    END;
      IF hi  > n    THEN hi  := n    END;
      WHILE lo2 < hi DO
        INC(depths[lo2]); INC(lo2)
      END
    END
  END
END Coverage;

END BioAnnot.
