MODULE BioPDB;
(*
  BioPDB — PDB (Protein Data Bank) file I/O.

  Parses ATOM and HETATM records from PDB format files.
  Supports multi-model files (NMR ensembles, MD trajectories) via
  a model-number selector in LoadModel.

  The Model record is a flat value type (fixed atom array); no heap
  allocation is required beyond opening the Files.File.  Bounding box
  and centroid are computed during Load so the viewer can center and
  scale without a second pass.

  Column offsets follow the PDB format specification (1-based in the
  spec; converted to 0-based here):
    Record type : 0-5
    Serial      : 6-10
    Name        : 12-15
    AltLoc      : 16
    ResName     : 17-19
    ChainID     : 21
    ResSeq      : 22-25
    iCode       : 26
    X           : 30-37
    Y           : 38-45
    Z           : 46-53
    Occupancy   : 54-59
    TempFactor  : 60-65
    Element     : 76-77
*)

IMPORT Files, OS, Strings, Env;

CONST
  MaxAtoms*  = 8192;
  MaxChains* = 26;

  (* Error codes returned by Load / LoadModel *)
  ErrNone*        = 0;
  ErrFileOpen*    = 1;
  ErrTooManyAtoms* = 2;

  (* Secondary structure codes *)
  SSCoil*  = 0;
  SSHelix* = 1;
  SSSheet* = 2;

  (* Maximum residues tracked for secondary structure per model *)
  MaxSSRes* = 20000;

TYPE
  SSEntry* = RECORD
    chain*  : CHAR;
    resSeq* : INTEGER;
    ss*     : INTEGER
  END;

  Atom* = RECORD
    serial*     : INTEGER;
    name*       : ARRAY 5  OF CHAR;  (* e.g. " CA " *)
    altLoc*     : CHAR;
    resName*    : ARRAY 4  OF CHAR;  (* e.g. "ALA" *)
    chainID*    : CHAR;
    resSeq*     : INTEGER;
    iCode*      : CHAR;
    x*, y*, z*  : REAL;
    occupancy*  : REAL;
    tempFactor* : REAL;
    element*    : ARRAY 3  OF CHAR;  (* e.g. "C", "N", "O" *)
    isHet*      : BOOLEAN            (* TRUE for HETATM *)
  END;

  Model* = RECORD
    atoms*  : ARRAY MaxAtoms OF Atom;
    count*  : INTEGER;
    minX*, maxX* : REAL;
    minY*, maxY* : REAL;
    minZ*, maxZ* : REAL;
    cx*, cy*, cz* : REAL;
    (* Secondary structure table — populated by Load/LoadModel/ReadModel *)
    ssMap*   : ARRAY MaxSSRes OF SSEntry;
    ssCount* : INTEGER
  END;

  (* Reader for iterating over models in a multi-model file.
     Use OpenPDB / ReadModel / ClosePDB for that pattern.
     For single-model use, Load / LoadModel are more convenient. *)
  PDBReader* = RECORD
    rider   : Files.Rider;
    done*   : BOOLEAN;
    tmpPath : ARRAY 1024 OF CHAR;
    (* SS table parsed once at open; copied into each model on ReadModel *)
    ssModel : Model
  END;

(* ------------------------------------------------------------------ *)
(*  Internal string / column helpers                                    *)
(* ------------------------------------------------------------------ *)

PROCEDURE StrLen(s: ARRAY OF CHAR): INTEGER;
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (i < LEN(s)) & (s[i] # 0X) DO INC(i) END;
  RETURN i
END StrLen;

(* Copy columns [lo, hi] (0-based, inclusive) from line into dst,
   strip leading/trailing spaces, and null-terminate.
   If line is shorter than hi+1 the short portion is used. *)
PROCEDURE ColExtract(line: ARRAY OF CHAR; lo, hi: INTEGER;
                     VAR dst: ARRAY OF CHAR; maxDst: INTEGER);
VAR i, j, last: INTEGER;
BEGIN
  (* clamp to actual line length *)
  IF hi >= LEN(line) THEN hi := LEN(line) - 1 END;
  IF lo > hi THEN dst[0] := 0X; RETURN END;

  (* strip leading spaces *)
  WHILE (lo <= hi) & (line[lo] = ' ') DO INC(lo) END;
  (* strip trailing spaces *)
  last := hi;
  WHILE (last >= lo) & (line[last] = ' ') DO DEC(last) END;

  j := 0;
  FOR i := lo TO last DO
    IF j < maxDst - 1 THEN dst[j] := line[i]; INC(j) END
  END;
  dst[j] := 0X
END ColExtract;

(* Parse an integer from columns [lo, hi] of line. Returns 0 on failure. *)
PROCEDURE ColInt(line: ARRAY OF CHAR; lo, hi: INTEGER): INTEGER;
VAR buf: ARRAY 16 OF CHAR; n: INTEGER;
BEGIN
  ColExtract(line, lo, hi, buf, 16);
  IF ~Strings.StrToInt(buf, n) THEN n := 0 END;
  RETURN n
END ColInt;

(* Parse a real from columns [lo, hi] of line. Returns 0.0 on failure. *)
PROCEDURE ColReal(line: ARRAY OF CHAR; lo, hi: INTEGER): REAL;
VAR buf: ARRAY 16 OF CHAR; x: REAL;
BEGIN
  ColExtract(line, lo, hi, buf, 16);
  IF ~Strings.StrToReal(buf, x) THEN x := 0.0 END;
  RETURN x
END ColReal;

(* Return TRUE if line begins with the given 6-char record tag.
   Comparison is case-sensitive per the PDB spec. *)
PROCEDURE RecordIs(line: ARRAY OF CHAR; tag: ARRAY OF CHAR): BOOLEAN;
VAR i, tlen: INTEGER;
BEGIN
  tlen := StrLen(tag);
  IF LEN(line) < tlen THEN RETURN FALSE END;
  i := 0;
  WHILE i < tlen DO
    IF line[i] # tag[i] THEN RETURN FALSE END;
    INC(i)
  END;
  RETURN TRUE
END RecordIs;

(* ------------------------------------------------------------------ *)
(*  Bounding box and centroid                                           *)
(* ------------------------------------------------------------------ *)

PROCEDURE ComputeBounds(VAR m: Model);
VAR i: INTEGER; a: Atom;
BEGIN
  IF m.count = 0 THEN
    m.minX := 0.0; m.maxX := 0.0;
    m.minY := 0.0; m.maxY := 0.0;
    m.minZ := 0.0; m.maxZ := 0.0;
    m.cx   := 0.0; m.cy   := 0.0; m.cz := 0.0;
    RETURN
  END;

  a := m.atoms[0];
  m.minX := a.x; m.maxX := a.x;
  m.minY := a.y; m.maxY := a.y;
  m.minZ := a.z; m.maxZ := a.z;
  m.cx := 0.0; m.cy := 0.0; m.cz := 0.0;

  FOR i := 0 TO m.count - 1 DO
    a := m.atoms[i];
    IF a.x < m.minX THEN m.minX := a.x END;
    IF a.x > m.maxX THEN m.maxX := a.x END;
    IF a.y < m.minY THEN m.minY := a.y END;
    IF a.y > m.maxY THEN m.maxY := a.y END;
    IF a.z < m.minZ THEN m.minZ := a.z END;
    IF a.z > m.maxZ THEN m.maxZ := a.z END;
    m.cx := m.cx + a.x;
    m.cy := m.cy + a.y;
    m.cz := m.cz + a.z
  END;

  m.cx := m.cx / FLT(m.count);
  m.cy := m.cy / FLT(m.count);
  m.cz := m.cz / FLT(m.count)
END ComputeBounds;

(* ------------------------------------------------------------------ *)
(*  Secondary structure parsing                                         *)
(* ------------------------------------------------------------------ *)

(* Parse integer from fixed 0-based columns [lo,hi] of a PDB line. *)
PROCEDURE SSColInt(VAR line: ARRAY OF CHAR; lo, hi: INTEGER): INTEGER;
VAR i, n, sign: INTEGER;
BEGIN
  WHILE (lo <= hi) & (line[lo] = ' ') DO INC(lo) END;
  n := 0; sign := 1;
  IF (lo <= hi) & (line[lo] = '-') THEN sign := -1; INC(lo) END;
  FOR i := lo TO hi DO
    IF (line[i] >= '0') & (line[i] <= '9') THEN
      n := n * 10 + ORD(line[i]) - ORD('0')
    END
  END;
  RETURN sign * n
END SSColInt;

(* Mark every residue in [seqStart..seqEnd] on chain with ss code. *)
PROCEDURE MarkSS(VAR m: Model; chain: CHAR;
                 seqStart, seqEnd, ss: INTEGER);
VAR r: INTEGER;
BEGIN
  FOR r := seqStart TO seqEnd DO
    IF m.ssCount < MaxSSRes THEN
      m.ssMap[m.ssCount].chain  := chain;
      m.ssMap[m.ssCount].resSeq := r;
      m.ssMap[m.ssCount].ss     := ss;
      INC(m.ssCount)
    END
  END
END MarkSS;

(*
  Parse HELIX and SHEET records from an already-open rider into m.ssMap.
  The rider must be positioned at the start of the file.
  Stops at the first ATOM/HETATM/MODEL line (SS records appear in the
  PDB header before coordinates).

  HELIX column offsets (0-based):
    19      init chain ID
    21-24   init seq num
    31      end chain ID
    33-36   end seq num

  SHEET column offsets (0-based):
    21      init chain ID
    22-25   init seq num
    32      end chain ID
    33-36   end seq num
*)
PROCEDURE ParseSS(VAR r: Files.Rider; VAR m: Model);
VAR line: ARRAY 128 OF CHAR;
    chainS: CHAR;
    seqS, seqE: INTEGER;
BEGIN
  m.ssCount := 0;
  LOOP
    IF r.eof THEN EXIT END;
    Files.ReadLine(r, line);
    IF r.eof & (line[0] = 0X) THEN EXIT END;

    IF RecordIs(line, "HELIX ") OR RecordIs(line, "HELIX") THEN
      IF LEN(line) > 36 THEN
        chainS := line[19];
        seqS   := SSColInt(line, 21, 24);
        seqE   := SSColInt(line, 33, 36);
        MarkSS(m, chainS, seqS, seqE, SSHelix)
      END
    ELSIF RecordIs(line, "SHEET ") OR RecordIs(line, "SHEET") THEN
      IF LEN(line) > 36 THEN
        chainS := line[21];
        seqS   := SSColInt(line, 22, 25);
        seqE   := SSColInt(line, 33, 36);
        MarkSS(m, chainS, seqS, seqE, SSSheet)
      END
    ELSIF RecordIs(line, "ATOM  ") OR RecordIs(line, "ATOM ") OR
          RecordIs(line, "HETATM") OR RecordIs(line, "MODEL ") OR
          RecordIs(line, "MODEL") THEN
      EXIT
    END
  END
END ParseSS;

(* ------------------------------------------------------------------ *)
(*  Core line parser                                                    *)
(* ------------------------------------------------------------------ *)

PROCEDURE ParseAtomLine(line: ARRAY OF CHAR; VAR a: Atom; het: BOOLEAN);
VAR buf: ARRAY 8 OF CHAR;
BEGIN
  a.isHet := het;

  a.serial := ColInt(line, 6, 10);

  (* Atom name: preserve the original 4-char field including leading
     space, which encodes element for single-char elements (" CA ").  *)
  ColExtract(line, 12, 15, a.name, 5);

  IF LEN(line) > 16 THEN a.altLoc := line[16] ELSE a.altLoc := ' ' END;

  ColExtract(line, 17, 19, a.resName, 4);

  IF LEN(line) > 21 THEN a.chainID := line[21] ELSE a.chainID := ' ' END;

  a.resSeq := ColInt(line, 22, 25);

  IF LEN(line) > 26 THEN a.iCode := line[26] ELSE a.iCode := ' ' END;

  a.x := ColReal(line, 30, 37);
  a.y := ColReal(line, 38, 45);
  a.z := ColReal(line, 46, 53);

  a.occupancy   := ColReal(line, 54, 59);
  a.tempFactor  := ColReal(line, 60, 65);

  (* Element symbol: columns 76-77 are not always present in older files.
     Fall back to the first non-space character of the atom name field. *)
  IF LEN(line) > 76 THEN
    ColExtract(line, 76, 77, a.element, 3)
  ELSE
    a.element[0] := 0X
  END;
  IF a.element[0] = 0X THEN
    (* derive from name: skip leading space, take first alpha char *)
    buf[0] := 0X;
    IF (a.name[0] # ' ') & (a.name[0] # 0X) THEN
      buf[0] := a.name[0]; buf[1] := 0X
    ELSIF (a.name[1] # ' ') & (a.name[1] # 0X) THEN
      buf[0] := a.name[1]; buf[1] := 0X
    END;
    COPY(buf, a.element)
  END
END ParseAtomLine;

(* ------------------------------------------------------------------ *)
(*  Internal model accumulator used by both reader patterns            *)
(* ------------------------------------------------------------------ *)

(* Read ATOM/HETATM lines from rider into m until END, ENDMDL, or EOF.
   Returns FALSE and sets err = ErrTooManyAtoms if capacity exceeded.
   The MODEL record line (if any) is assumed already consumed.
   On return the rider is positioned just after ENDMDL/END or at EOF. *)
PROCEDURE AccumModel(VAR r: Files.Rider; VAR m: Model;
                     VAR err: INTEGER): BOOLEAN;
VAR line: ARRAY 128 OF CHAR; a: Atom;
BEGIN
  m.count := 0; err := ErrNone;
  LOOP
    IF r.eof THEN EXIT END;
    Files.ReadLine(r, line);
    IF r.eof & (line[0] = 0X) THEN EXIT END;

    IF RecordIs(line, "ATOM  ") OR RecordIs(line, "ATOM ") THEN
      (* some files write "ATOM " with 5 chars — RecordIs handles both *)
      IF m.count >= MaxAtoms THEN err := ErrTooManyAtoms; RETURN FALSE END;
      ParseAtomLine(line, a, FALSE);
      m.atoms[m.count] := a; INC(m.count)

    ELSIF RecordIs(line, "HETATM") THEN
      IF m.count >= MaxAtoms THEN err := ErrTooManyAtoms; RETURN FALSE END;
      ParseAtomLine(line, a, TRUE);
      m.atoms[m.count] := a; INC(m.count)

    ELSIF RecordIs(line, "ENDMDL") OR RecordIs(line, "END   ") OR
          RecordIs(line, "END") THEN
      EXIT
    END
  END;
  ComputeBounds(m);
  RETURN TRUE
END AccumModel;

(* ------------------------------------------------------------------ *)
(*  Compressed-file helper (mirrors BioIO's GzOpen)                    *)
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
  Strings.Append("/_biopdb_", path);
  i := Strings.Length(path);
  path[i]   := CHR(tmpSeq MOD 10 + ORD('0'));
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
    Strings.Append(path,    cmd);
    Strings.Append(" > ",   cmd);
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

(*
  Look up the secondary structure code for a given chain + residue number.
  Returns SSCoil if not found (residues not covered by HELIX/SHEET records).
  Linear scan — adequate for typical protein sizes (≤ a few thousand residues).
*)
PROCEDURE LookupSS*(VAR m: Model; chain: CHAR; resSeq: INTEGER): INTEGER;
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO m.ssCount - 1 DO
    IF (m.ssMap[i].chain = chain) & (m.ssMap[i].resSeq = resSeq) THEN
      RETURN m.ssMap[i].ss
    END
  END;
  RETURN SSCoil
END LookupSS;

(* ------------------------------------------------------------------ *)
(*  Convenience loaders                                                 *)
(* ------------------------------------------------------------------ *)

(*
  Load the first MODEL (or the whole file if no MODEL records) into m.
  Returns TRUE on success.  err is set to an Err* constant.
*)
PROCEDURE Load*(path: ARRAY OF CHAR; VAR m: Model; VAR err: INTEGER): BOOLEAN;
VAR f: Files.File; r: Files.Rider; tmpPath: ARRAY 1024 OF CHAR;
    line: ARRAY 128 OF CHAR; ssRider: Files.Rider;
BEGIN
  err := ErrNone; m.count := 0;
  IF ~GzOpen(path, f, tmpPath) THEN err := ErrFileOpen; RETURN FALSE END;
  Files.Set(ssRider, f, 0);
  ParseSS(ssRider, m);
  Files.Set(r, f, 0);

  (* Skip to first ATOM/HETATM or MODEL record *)
  LOOP
    IF r.eof THEN EXIT END;
    Files.ReadLine(r, line);
    IF r.eof & (line[0] = 0X) THEN EXIT END;
    IF RecordIs(line, "MODEL ") OR RecordIs(line, "MODEL")  OR
       RecordIs(line, "ATOM  ") OR RecordIs(line, "ATOM ")  OR
       RecordIs(line, "HETATM") THEN
      (* If it was MODEL, consume it; if ATOM/HETATM the rider is
         already past it, so push it back via a single-atom pre-parse. *)
      IF RecordIs(line, "ATOM  ") OR RecordIs(line, "ATOM ") OR
         RecordIs(line, "HETATM") THEN
        (* Manually handle the already-read first atom *)
        IF m.count >= MaxAtoms THEN
          err := ErrTooManyAtoms;
          Files.Close(f);
          IF tmpPath[0] # 0X THEN Files.Delete(tmpPath) END;
          RETURN FALSE
        END;
        ParseAtomLine(line, m.atoms[m.count],
                      RecordIs(line, "HETATM"));
        INC(m.count)
      END;
      EXIT
    END
  END;

  IF ~AccumModel(r, m, err) THEN
    Files.Close(f);
    IF tmpPath[0] # 0X THEN Files.Delete(tmpPath) END;
    RETURN FALSE
  END;

  Files.Close(f);
  IF tmpPath[0] # 0X THEN Files.Delete(tmpPath) END;
  RETURN TRUE
END Load;

(*
  Load a specific model by 1-based index (modelNo = 1 = first MODEL block).
  For files without MODEL records, modelNo = 1 is equivalent to Load.
  Returns TRUE on success.
*)
PROCEDURE LoadModel*(path: ARRAY OF CHAR; VAR m: Model;
                     modelNo: INTEGER; VAR err: INTEGER): BOOLEAN;
VAR f: Files.File; r: Files.Rider; tmpPath: ARRAY 1024 OF CHAR;
    line: ARRAY 128 OF CHAR; cur: INTEGER; found: BOOLEAN; ssRider: Files.Rider;
BEGIN
  err := ErrNone; m.count := 0;
  IF modelNo < 1 THEN modelNo := 1 END;
  IF ~GzOpen(path, f, tmpPath) THEN err := ErrFileOpen; RETURN FALSE END;
  Files.Set(ssRider, f, 0);
  ParseSS(ssRider, m);
  Files.Set(r, f, 0);

  cur := 0; found := FALSE;
  LOOP
    IF r.eof THEN EXIT END;
    Files.ReadLine(r, line);
    IF r.eof & (line[0] = 0X) THEN EXIT END;

    IF RecordIs(line, "MODEL ") OR RecordIs(line, "MODEL") THEN
      INC(cur);
      IF cur = modelNo THEN found := TRUE; EXIT END
    END
  END;

  (* Files without MODEL records: treat entire file as model 1. *)
  IF ~found & (modelNo = 1) THEN
    Files.Set(r, f, 0);
    found := TRUE
  END;

  IF ~found THEN
    Files.Close(f);
    IF tmpPath[0] # 0X THEN Files.Delete(tmpPath) END;
    err := ErrFileOpen;   (* no such model — reuse file error code *)
    RETURN FALSE
  END;

  IF ~AccumModel(r, m, err) THEN
    Files.Close(f);
    IF tmpPath[0] # 0X THEN Files.Delete(tmpPath) END;
    RETURN FALSE
  END;

  Files.Close(f);
  IF tmpPath[0] # 0X THEN Files.Delete(tmpPath) END;
  RETURN TRUE
END LoadModel;

(* ------------------------------------------------------------------ *)
(*  Streaming reader (for iterating all models)                         *)
(* ------------------------------------------------------------------ *)

(*
  Open a PDB file for streaming model-by-model access.
  Use ReadModel in a WHILE loop; close with ClosePDB.

    VAR rdr: BioPDB.PDBReader;  m: BioPDB.Model;  err: INTEGER;
    IF BioPDB.OpenPDB(rdr, "ensemble.pdb") THEN
      WHILE BioPDB.ReadModel(rdr, m, err) DO
        (* process m *)
      END;
      BioPDB.ClosePDB(rdr)
    END
*)
PROCEDURE OpenPDB*(VAR r: PDBReader; path: ARRAY OF CHAR): BOOLEAN;
VAR f: Files.File; ssRider: Files.Rider;
BEGIN
  IF ~GzOpen(path, f, r.tmpPath) THEN r.done := TRUE; RETURN FALSE END;
  (* Parse SS from a fresh rider before handing the file to the caller *)
  Files.Set(ssRider, f, 0);
  ParseSS(ssRider, r.ssModel);
  Files.Set(r.rider, f, 0);
  r.done := FALSE;
  RETURN TRUE
END OpenPDB;

(*
  Read the next model from an open PDBReader into m.
  Returns FALSE at EOF or on error (check err for ErrTooManyAtoms).
  Skips non-MODEL/ATOM/HETATM records between models automatically.
*)
PROCEDURE ReadModel*(VAR r: PDBReader; VAR m: Model;
                     VAR err: INTEGER): BOOLEAN;
VAR line: ARRAY 128 OF CHAR; scanning: BOOLEAN; i: INTEGER;
BEGIN
  IF r.done THEN RETURN FALSE END;
  m.count := 0; err := ErrNone;

  (* Scan forward to the next MODEL or ATOM/HETATM *)
  scanning := TRUE;
  WHILE scanning DO
    IF r.rider.eof THEN r.done := TRUE; RETURN FALSE END;
    Files.ReadLine(r.rider, line);
    IF r.rider.eof & (line[0] = 0X) THEN r.done := TRUE; RETURN FALSE END;

    IF RecordIs(line, "MODEL ") OR RecordIs(line, "MODEL") THEN
      scanning := FALSE  (* consume MODEL line, fall through to AccumModel *)

    ELSIF RecordIs(line, "ATOM  ") OR RecordIs(line, "ATOM ") OR
          RecordIs(line, "HETATM") THEN
      (* File has no MODEL records; parse the pre-read atom then accumulate *)
      IF m.count >= MaxAtoms THEN
        err := ErrTooManyAtoms; r.done := TRUE; RETURN FALSE
      END;
      ParseAtomLine(line, m.atoms[m.count],
                    RecordIs(line, "HETATM"));
      INC(m.count);
      scanning := FALSE
    END
  END;

  IF ~AccumModel(r.rider, m, err) THEN
    r.done := TRUE; RETURN FALSE
  END;

  (* Copy the SS table parsed at open time into this model *)
  m.ssCount := r.ssModel.ssCount;
  IF m.ssCount > MaxSSRes THEN m.ssCount := MaxSSRes END;
  FOR i := 0 TO m.ssCount - 1 DO
    m.ssMap[i] := r.ssModel.ssMap[i]
  END;

  IF m.count > 0 THEN RETURN TRUE END;
  r.done := TRUE;
  RETURN FALSE
END ReadModel;

PROCEDURE ClosePDB*(VAR r: PDBReader);
BEGIN
  r.done := TRUE;
  IF r.tmpPath[0] # 0X THEN Files.Delete(r.tmpPath); r.tmpPath[0] := 0X END
END ClosePDB;

(* ------------------------------------------------------------------ *)
(*  Write                                                               *)
(* ------------------------------------------------------------------ *)

PROCEDURE WriteChar(VAR r: Files.Rider; c: CHAR);
BEGIN Files.Write(r, ORD(c)) END WriteChar;

PROCEDURE WriteStr(VAR r: Files.Rider; s: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (i < LEN(s)) & (s[i] # 0X) DO
    Files.Write(r, ORD(s[i])); INC(i)
  END
END WriteStr;

PROCEDURE WriteNL(VAR r: Files.Rider);
BEGIN Files.Write(r, 10) END WriteNL;

(* Right-justify integer n in a field of width w, space-padded. *)
PROCEDURE WriteIntW(VAR r: Files.Rider; n, w: INTEGER);
VAR buf: ARRAY 12 OF CHAR; i, j, len: INTEGER; tmp: CHAR;
BEGIN
  IF n < 0 THEN WriteChar(r, '-'); n := -n; DEC(w) END;
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
  buf[i] := 0X; len := i;
  WHILE len < w DO WriteChar(r, ' '); INC(len) END;
  WriteStr(r, buf)
END WriteIntW;

(* Write real x in %8.3f style (8 chars wide, 3 decimal places). *)
PROCEDURE WriteReal83(VAR r: Files.Rider; x: REAL);
VAR whole, frac, i: INTEGER; neg: BOOLEAN;
    buf: ARRAY 12 OF CHAR; tmp: CHAR; len: INTEGER;
BEGIN
  neg := x < 0.0;
  IF neg THEN x := -x END;
  whole := FLOOR(x);
  frac  := FLOOR((x - FLT(whole)) * 1000.0 + 0.5);
  IF frac >= 1000 THEN INC(whole); frac := frac - 1000 END;

  (* build integer part reversed *)
  i := 0;
  IF whole = 0 THEN buf[0] := '0'; i := 1
  ELSE
    WHILE whole > 0 DO
      buf[i] := CHR(whole MOD 10 + ORD('0'));
      whole := whole DIV 10; INC(i)
    END;
    len := 0;
    WHILE len < i DIV 2 DO
      tmp := buf[len]; buf[len] := buf[i-1-len]; buf[i-1-len] := tmp; INC(len)
    END
  END;
  buf[i] := 0X;

  (* total printed length: sign + integer + '.' + 3 digits *)
  len := i + 4;
  IF neg THEN INC(len) END;
  WHILE len < 8 DO WriteChar(r, ' '); INC(len) END;
  IF neg THEN WriteChar(r, '-') END;
  WriteStr(r, buf);
  WriteChar(r, '.');
  WriteChar(r, CHR(frac DIV 100 + ORD('0')));
  WriteChar(r, CHR(frac DIV 10 MOD 10 + ORD('0')));
  WriteChar(r, CHR(frac MOD 10 + ORD('0')))
END WriteReal83;

PROCEDURE WriteReal62(VAR r: Files.Rider; x: REAL);
(* 6.2f — used for occupancy and B-factor *)
VAR whole, frac, i, len: INTEGER; neg: BOOLEAN;
    buf: ARRAY 10 OF CHAR; tmp: CHAR;
BEGIN
  neg := x < 0.0;
  IF neg THEN x := -x END;
  whole := FLOOR(x);
  frac  := FLOOR((x - FLT(whole)) * 100.0 + 0.5);
  IF frac >= 100 THEN INC(whole); frac := frac - 100 END;
  i := 0;
  IF whole = 0 THEN buf[0] := '0'; i := 1
  ELSE
    WHILE whole > 0 DO
      buf[i] := CHR(whole MOD 10 + ORD('0'));
      whole := whole DIV 10; INC(i)
    END;
    len := 0;
    WHILE len < i DIV 2 DO
      tmp := buf[len]; buf[len] := buf[i-1-len]; buf[i-1-len] := tmp; INC(len)
    END
  END;
  buf[i] := 0X;
  len := i + 3;
  IF neg THEN INC(len) END;
  WHILE len < 6 DO WriteChar(r, ' '); INC(len) END;
  IF neg THEN WriteChar(r, '-') END;
  WriteStr(r, buf);
  WriteChar(r, '.');
  WriteChar(r, CHR(frac DIV 10 + ORD('0')));
  WriteChar(r, CHR(frac MOD 10 + ORD('0')))
END WriteReal62;

(* Write atom name left-justified in a 4-char field, space-padded. *)
PROCEDURE WriteAtomName(VAR r: Files.Rider; name: ARRAY OF CHAR);
VAR i, n: INTEGER;
BEGIN
  n := StrLen(name);
  (* Atom names are stored with their original PDB spacing; if the
     stored name is already 4 chars we write it verbatim. *)
  IF n >= 4 THEN
    FOR i := 0 TO 3 DO WriteChar(r, name[i]) END
  ELSE
    (* re-pad: single-char elements get a leading space *)
    WriteChar(r, ' ');
    FOR i := 0 TO n - 1 DO WriteChar(r, name[i]) END;
    WHILE n < 3 DO WriteChar(r, ' '); INC(n) END
  END
END WriteAtomName;

(*
  Write a Model to an open Files.Rider in PDB format.
  modelNo is written in the MODEL record (pass 1 for single-model files,
  or 0 to suppress MODEL/ENDMDL records entirely).
*)
PROCEDURE WriteModel*(VAR r: Files.Rider; VAR m: Model; modelNo: INTEGER);
VAR i: INTEGER; a: Atom; recName: ARRAY 7 OF CHAR;
BEGIN
  IF modelNo > 0 THEN
    WriteStr(r, "MODEL ");
    WriteIntW(r, modelNo, 8);
    WriteNL(r)
  END;

  FOR i := 0 TO m.count - 1 DO
    a := m.atoms[i];
    IF a.isHet THEN COPY("HETATM", recName) ELSE COPY("ATOM  ", recName) END;
    WriteStr(r, recName);              (* cols  1- 6 *)
    WriteIntW(r, a.serial, 5);        (* cols  7-11 *)
    WriteChar(r, ' ');                 (* col  12    *)
    WriteAtomName(r, a.name);         (* cols 13-16 *)
    WriteChar(r, a.altLoc);           (* col  17    *)
    (* ResName: left-pad to 3 chars *)
    WriteStr(r, a.resName);
    i := StrLen(a.resName);
    WHILE i < 3 DO WriteChar(r, ' '); INC(i) END;
    WriteChar(r, ' ');                 (* col  21    *)
    WriteChar(r, a.chainID);          (* col  22    *)
    WriteIntW(r, a.resSeq, 4);        (* cols 23-26 *)
    WriteChar(r, a.iCode);            (* col  27    *)
    WriteStr(r, "   ");               (* cols 28-30 *)
    WriteReal83(r, a.x);              (* cols 31-38 *)
    WriteReal83(r, a.y);              (* cols 39-46 *)
    WriteReal83(r, a.z);              (* cols 47-54 *)
    WriteReal62(r, a.occupancy);      (* cols 55-60 *)
    WriteReal62(r, a.tempFactor);     (* cols 61-66 *)
    WriteStr(r, "          ");        (* cols 67-76 *)
    (* Element right-justified in 2-char field *)
    IF StrLen(a.element) < 2 THEN WriteChar(r, ' ') END;
    WriteStr(r, a.element);           (* cols 77-78 *)
    WriteNL(r)
  END;

  IF modelNo > 0 THEN WriteStr(r, "ENDMDL"); WriteNL(r)
  ELSE              WriteStr(r, "END");    WriteNL(r)
  END
END WriteModel;

BEGIN
  tmpSeq := 0
END BioPDB.
