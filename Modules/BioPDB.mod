MODULE BioPDB;
(*
  BioPDB -- PDB / mmCIF / SDF / XYZ structure I/O.

  Additional formats via LoadAny (auto-detected by extension):
    .pdb  .ent   -- PDB format (LoadModel)
    .cif  .mmcif -- mmCIF / PDBx
    .sdf  .mol   -- MDL Molfile / SDF (multi-compound via modelNo)
    .xyz          -- XYZ cartesian (multi-frame via modelNo)
  All formats accept .gz suffix (transparently decompressed via gunzip).
*)

IMPORT Files, OS, Strings, Env;

CONST
  MaxAtoms*   = 8192;
  MaxChains*  = 26;

  ErrNone*         = 0;
  ErrFileOpen*     = 1;
  ErrTooManyAtoms* = 2;

  SSCoil*  = 0;
  SSHelix* = 1;
  SSSheet* = 2;

  MaxSSRes* = 20000;

TYPE
  SSEntry* = RECORD
    chain*  : CHAR;
    resSeq* : INTEGER;
    ss*     : INTEGER
  END;

  Atom* = RECORD
    serial*     : INTEGER;
    name*       : ARRAY 5 OF CHAR;
    altLoc*     : CHAR;
    resName*    : ARRAY 4 OF CHAR;
    chainID*    : CHAR;
    resSeq*     : INTEGER;
    iCode*      : CHAR;
    x*, y*, z*  : REAL;
    occupancy*  : REAL;
    tempFactor* : REAL;
    element*    : ARRAY 3 OF CHAR;
    isHet*      : BOOLEAN
  END;

  Model* = RECORD
    atoms*   : ARRAY MaxAtoms OF Atom;
    count*   : INTEGER;
    minX*, maxX* : REAL;
    minY*, maxY* : REAL;
    minZ*, maxZ* : REAL;
    cx*, cy*, cz* : REAL;
    ssMap*   : ARRAY MaxSSRes OF SSEntry;
    ssCount* : INTEGER
  END;

  PDBReader* = RECORD
    rider   : Files.Rider;
    done*   : BOOLEAN;
    tmpPath : ARRAY 1024 OF CHAR;
    ssModel : Model
  END;

(* ------------------------------------------------------------------ *)
(*  String / column helpers                                             *)
(* ------------------------------------------------------------------ *)

PROCEDURE StrLen(s: ARRAY OF CHAR): INTEGER;
VAR i: INTEGER;
BEGIN
  i := 0; WHILE (i < LEN(s)) & (s[i] # 0X) DO INC(i) END;
  RETURN i
END StrLen;

PROCEDURE ColExtract(line: ARRAY OF CHAR; lo, hi: INTEGER;
                     VAR dst: ARRAY OF CHAR; maxDst: INTEGER);
VAR i, j, last: INTEGER;
BEGIN
  IF hi >= LEN(line) THEN hi := LEN(line)-1 END;
  IF lo > hi THEN dst[0] := 0X; RETURN END;
  WHILE (lo <= hi) & (line[lo] = ' ') DO INC(lo) END;
  last := hi;
  WHILE (last >= lo) & (line[last] = ' ') DO DEC(last) END;
  j := 0;
  FOR i := lo TO last DO
    IF j < maxDst-1 THEN dst[j] := line[i]; INC(j) END
  END;
  dst[j] := 0X
END ColExtract;

PROCEDURE ColInt(line: ARRAY OF CHAR; lo, hi: INTEGER): INTEGER;
VAR buf: ARRAY 16 OF CHAR; n: INTEGER;
BEGIN
  ColExtract(line, lo, hi, buf, 16);
  IF ~Strings.StrToInt(buf, n) THEN n := 0 END;
  RETURN n
END ColInt;

PROCEDURE ColReal(line: ARRAY OF CHAR; lo, hi: INTEGER): REAL;
VAR buf: ARRAY 16 OF CHAR; x: REAL;
BEGIN
  ColExtract(line, lo, hi, buf, 16);
  IF ~Strings.StrToReal(buf, x) THEN x := 0.0 END;
  RETURN x
END ColReal;

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
    m.minX:=0.0; m.maxX:=0.0; m.minY:=0.0; m.maxY:=0.0;
    m.minZ:=0.0; m.maxZ:=0.0; m.cx:=0.0; m.cy:=0.0; m.cz:=0.0;
    RETURN
  END;
  a := m.atoms[0];
  m.minX:=a.x; m.maxX:=a.x; m.minY:=a.y; m.maxY:=a.y;
  m.minZ:=a.z; m.maxZ:=a.z;
  m.cx:=0.0; m.cy:=0.0; m.cz:=0.0;
  FOR i := 0 TO m.count-1 DO
    a := m.atoms[i];
    IF a.x < m.minX THEN m.minX:=a.x END;
    IF a.x > m.maxX THEN m.maxX:=a.x END;
    IF a.y < m.minY THEN m.minY:=a.y END;
    IF a.y > m.maxY THEN m.maxY:=a.y END;
    IF a.z < m.minZ THEN m.minZ:=a.z END;
    IF a.z > m.maxZ THEN m.maxZ:=a.z END;
    m.cx := m.cx+a.x; m.cy := m.cy+a.y; m.cz := m.cz+a.z
  END;
  m.cx := m.cx/FLT(m.count);
  m.cy := m.cy/FLT(m.count);
  m.cz := m.cz/FLT(m.count)
END ComputeBounds;

(* ------------------------------------------------------------------ *)
(*  Secondary structure parsing                                         *)
(* ------------------------------------------------------------------ *)

PROCEDURE SSColInt(VAR line: ARRAY OF CHAR; lo, hi: INTEGER): INTEGER;
VAR i, n, sign: INTEGER;
BEGIN
  WHILE (lo <= hi) & (line[lo] = ' ') DO INC(lo) END;
  n := 0; sign := 1;
  IF (lo <= hi) & (line[lo] = '-') THEN sign := -1; INC(lo) END;
  FOR i := lo TO hi DO
    IF (line[i] >= '0') & (line[i] <= '9') THEN
      n := n*10 + ORD(line[i]) - ORD('0')
    END
  END;
  RETURN sign * n
END SSColInt;

PROCEDURE MarkSS(VAR m: Model; chain: CHAR; seqStart, seqEnd, ss: INTEGER);
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

PROCEDURE ParseSS(VAR r: Files.Rider; VAR m: Model);
VAR line: ARRAY 128 OF CHAR; chainS: CHAR; seqS, seqE: INTEGER;
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
(*  Core PDB line parser                                               *)
(* ------------------------------------------------------------------ *)

PROCEDURE ParseAtomLine(line: ARRAY OF CHAR; VAR a: Atom; het: BOOLEAN);
VAR buf: ARRAY 8 OF CHAR;
BEGIN
  a.isHet := het;
  a.serial := ColInt(line, 6, 10);
  ColExtract(line, 12, 15, a.name, 5);
  IF LEN(line) > 16 THEN a.altLoc := line[16] ELSE a.altLoc := ' ' END;
  ColExtract(line, 17, 19, a.resName, 4);
  IF LEN(line) > 21 THEN a.chainID := line[21] ELSE a.chainID := ' ' END;
  a.resSeq := ColInt(line, 22, 25);
  IF LEN(line) > 26 THEN a.iCode := line[26] ELSE a.iCode := ' ' END;
  a.x := ColReal(line, 30, 37);
  a.y := ColReal(line, 38, 45);
  a.z := ColReal(line, 46, 53);
  a.occupancy  := ColReal(line, 54, 59);
  a.tempFactor := ColReal(line, 60, 65);
  IF LEN(line) > 76 THEN ColExtract(line, 76, 77, a.element, 3)
  ELSE a.element[0] := 0X END;
  IF a.element[0] = 0X THEN
    buf[0] := 0X;
    IF (a.name[0] # ' ') & (a.name[0] # 0X) THEN
      buf[0] := a.name[0]; buf[1] := 0X
    ELSIF (a.name[1] # ' ') & (a.name[1] # 0X) THEN
      buf[0] := a.name[1]; buf[1] := 0X
    END;
    COPY(buf, a.element)
  END
END ParseAtomLine;

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
(*  Gzip helper                                                         *)
(* ------------------------------------------------------------------ *)

VAR tmpSeq: INTEGER;

PROCEDURE MakeTmpPath(VAR path: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  IF ~Env.Get("TMPDIR", path) THEN COPY("/tmp", path) END;
  Strings.Append("/_biopdb_", path);
  i := Strings.Length(path);
  path[i]   := CHR(tmpSeq MOD 10 + ORD('0'));
  path[i+1] := 0X;
  Strings.Append(".tmp", path);
  tmpSeq := (tmpSeq+1) MOD 10
END MakeTmpPath;

(* Open path, decompressing if it ends in .gz.
   On success f is open and tmpPath holds the temp file name (or "" if
   no decompression was needed).  Caller must Files.Close(f) and, if
   tmpPath[0] # 0X, Files.Delete(tmpPath) when done. *)
PROCEDURE GzOpen(path: ARRAY OF CHAR; VAR f: Files.File;
                 VAR tmpPath: ARRAY OF CHAR): BOOLEAN;
VAR cmd: ARRAY 2048 OF CHAR;
BEGIN
  tmpPath[0] := 0X;
  IF Strings.EndsWith(path, ".gz") THEN
    MakeTmpPath(tmpPath);
    COPY("gunzip -c ", cmd);
    Strings.Append(path, cmd); Strings.Append(" > ", cmd);
    Strings.Append(tmpPath, cmd);
    IF OS.Exec(cmd) # 0 THEN
      tmpPath[0] := 0X; f := NIL; RETURN FALSE
    END;
    f := Files.Old(tmpPath);
    IF f = NIL THEN Files.Delete(tmpPath); tmpPath[0] := 0X; RETURN FALSE END
  ELSE
    f := Files.Old(path)
  END;
  RETURN f # NIL
END GzOpen;

PROCEDURE GzClose(f: Files.File; VAR tmpPath: ARRAY OF CHAR);
BEGIN
  Files.Close(f);
  IF tmpPath[0] # 0X THEN Files.Delete(tmpPath); tmpPath[0] := 0X END
END GzClose;

PROCEDURE LookupSS*(VAR m: Model; chain: CHAR; resSeq: INTEGER): INTEGER;
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO m.ssCount-1 DO
    IF (m.ssMap[i].chain = chain) & (m.ssMap[i].resSeq = resSeq) THEN
      RETURN m.ssMap[i].ss
    END
  END;
  RETURN SSCoil
END LookupSS;

(* ------------------------------------------------------------------ *)
(*  PDB loaders                                                         *)
(* ------------------------------------------------------------------ *)

PROCEDURE Load*(path: ARRAY OF CHAR; VAR m: Model; VAR err: INTEGER): BOOLEAN;
VAR f: Files.File; r: Files.Rider; tmpPath: ARRAY 1024 OF CHAR;
    line: ARRAY 128 OF CHAR; ssRider: Files.Rider;
BEGIN
  err := ErrNone; m.count := 0;
  IF ~GzOpen(path, f, tmpPath) THEN err := ErrFileOpen; RETURN FALSE END;
  Files.Set(ssRider, f, 0); ParseSS(ssRider, m);
  Files.Set(r, f, 0);
  LOOP
    IF r.eof THEN EXIT END;
    Files.ReadLine(r, line);
    IF r.eof & (line[0] = 0X) THEN EXIT END;
    IF RecordIs(line, "MODEL ") OR RecordIs(line, "MODEL") OR
       RecordIs(line, "ATOM  ") OR RecordIs(line, "ATOM ") OR
       RecordIs(line, "HETATM") THEN
      IF RecordIs(line, "ATOM  ") OR RecordIs(line, "ATOM ") OR
         RecordIs(line, "HETATM") THEN
        IF m.count >= MaxAtoms THEN
          err := ErrTooManyAtoms; GzClose(f, tmpPath); RETURN FALSE
        END;
        ParseAtomLine(line, m.atoms[m.count], RecordIs(line, "HETATM"));
        INC(m.count)
      END;
      EXIT
    END
  END;
  IF ~AccumModel(r, m, err) THEN GzClose(f, tmpPath); RETURN FALSE END;
  GzClose(f, tmpPath);
  RETURN TRUE
END Load;

PROCEDURE LoadModel*(path: ARRAY OF CHAR; VAR m: Model;
                     modelNo: INTEGER; VAR err: INTEGER): BOOLEAN;
VAR f: Files.File; r: Files.Rider; tmpPath: ARRAY 1024 OF CHAR;
    line: ARRAY 128 OF CHAR; cur: INTEGER; found: BOOLEAN; ssRider: Files.Rider;
BEGIN
  err := ErrNone; m.count := 0;
  IF modelNo < 1 THEN modelNo := 1 END;
  IF ~GzOpen(path, f, tmpPath) THEN err := ErrFileOpen; RETURN FALSE END;
  Files.Set(ssRider, f, 0); ParseSS(ssRider, m);
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
  IF ~found & (modelNo = 1) THEN Files.Set(r, f, 0); found := TRUE END;
  IF ~found THEN
    err := ErrFileOpen; GzClose(f, tmpPath); RETURN FALSE
  END;
  IF ~AccumModel(r, m, err) THEN GzClose(f, tmpPath); RETURN FALSE END;
  GzClose(f, tmpPath);
  RETURN TRUE
END LoadModel;

(* ------------------------------------------------------------------ *)
(*  Streaming reader                                                    *)
(* ------------------------------------------------------------------ *)

PROCEDURE OpenPDB*(VAR r: PDBReader; path: ARRAY OF CHAR): BOOLEAN;
VAR f: Files.File; ssRider: Files.Rider;
BEGIN
  IF ~GzOpen(path, f, r.tmpPath) THEN r.done := TRUE; RETURN FALSE END;
  Files.Set(ssRider, f, 0); ParseSS(ssRider, r.ssModel);
  Files.Set(r.rider, f, 0); r.done := FALSE;
  RETURN TRUE
END OpenPDB;

PROCEDURE ReadModel*(VAR r: PDBReader; VAR m: Model;
                     VAR err: INTEGER): BOOLEAN;
VAR line: ARRAY 128 OF CHAR; scanning: BOOLEAN; i: INTEGER;
BEGIN
  IF r.done THEN RETURN FALSE END;
  m.count := 0; err := ErrNone;
  scanning := TRUE;
  WHILE scanning DO
    IF r.rider.eof THEN r.done := TRUE; RETURN FALSE END;
    Files.ReadLine(r.rider, line);
    IF r.rider.eof & (line[0] = 0X) THEN r.done := TRUE; RETURN FALSE END;
    IF RecordIs(line, "MODEL ") OR RecordIs(line, "MODEL") THEN
      scanning := FALSE
    ELSIF RecordIs(line, "ATOM  ") OR RecordIs(line, "ATOM ") OR
          RecordIs(line, "HETATM") THEN
      IF m.count >= MaxAtoms THEN
        err := ErrTooManyAtoms; r.done := TRUE; RETURN FALSE
      END;
      ParseAtomLine(line, m.atoms[m.count], RecordIs(line, "HETATM"));
      INC(m.count); scanning := FALSE
    END
  END;
  IF ~AccumModel(r.rider, m, err) THEN r.done := TRUE; RETURN FALSE END;
  m.ssCount := r.ssModel.ssCount;
  IF m.ssCount > MaxSSRes THEN m.ssCount := MaxSSRes END;
  FOR i := 0 TO m.ssCount-1 DO m.ssMap[i] := r.ssModel.ssMap[i] END;
  IF m.count > 0 THEN RETURN TRUE END;
  r.done := TRUE; RETURN FALSE
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
  WHILE (i < LEN(s)) & (s[i] # 0X) DO Files.Write(r, ORD(s[i])); INC(i) END
END WriteStr;

PROCEDURE WriteNL(VAR r: Files.Rider);
BEGIN Files.Write(r, 10) END WriteNL;

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

PROCEDURE WriteReal83(VAR r: Files.Rider; x: REAL);
VAR whole, frac, i, len: INTEGER; neg: BOOLEAN;
    buf: ARRAY 12 OF CHAR; tmp: CHAR;
BEGIN
  neg := x < 0.0; IF neg THEN x := -x END;
  whole := FLOOR(x); frac := FLOOR((x-FLT(whole))*1000.0+0.5);
  IF frac >= 1000 THEN INC(whole); frac := frac-1000 END;
  i := 0;
  IF whole = 0 THEN buf[0] := '0'; i := 1
  ELSE
    WHILE whole > 0 DO
      buf[i] := CHR(whole MOD 10+ORD('0')); whole := whole DIV 10; INC(i)
    END;
    len := 0;
    WHILE len < i DIV 2 DO
      tmp := buf[len]; buf[len] := buf[i-1-len]; buf[i-1-len] := tmp; INC(len)
    END
  END;
  buf[i] := 0X;
  len := i+4; IF neg THEN INC(len) END;
  WHILE len < 8 DO WriteChar(r, ' '); INC(len) END;
  IF neg THEN WriteChar(r, '-') END;
  WriteStr(r, buf); WriteChar(r, '.');
  WriteChar(r, CHR(frac DIV 100+ORD('0')));
  WriteChar(r, CHR(frac DIV 10 MOD 10+ORD('0')));
  WriteChar(r, CHR(frac MOD 10+ORD('0')))
END WriteReal83;

PROCEDURE WriteReal62(VAR r: Files.Rider; x: REAL);
VAR whole, frac, i, len: INTEGER; neg: BOOLEAN;
    buf: ARRAY 10 OF CHAR; tmp: CHAR;
BEGIN
  neg := x < 0.0; IF neg THEN x := -x END;
  whole := FLOOR(x); frac := FLOOR((x-FLT(whole))*100.0+0.5);
  IF frac >= 100 THEN INC(whole); frac := frac-100 END;
  i := 0;
  IF whole = 0 THEN buf[0] := '0'; i := 1
  ELSE
    WHILE whole > 0 DO
      buf[i] := CHR(whole MOD 10+ORD('0')); whole := whole DIV 10; INC(i)
    END;
    len := 0;
    WHILE len < i DIV 2 DO
      tmp := buf[len]; buf[len] := buf[i-1-len]; buf[i-1-len] := tmp; INC(len)
    END
  END;
  buf[i] := 0X; len := i+3; IF neg THEN INC(len) END;
  WHILE len < 6 DO WriteChar(r, ' '); INC(len) END;
  IF neg THEN WriteChar(r, '-') END;
  WriteStr(r, buf); WriteChar(r, '.');
  WriteChar(r, CHR(frac DIV 10+ORD('0')));
  WriteChar(r, CHR(frac MOD 10+ORD('0')))
END WriteReal62;

PROCEDURE WriteAtomName(VAR r: Files.Rider; name: ARRAY OF CHAR);
VAR i, n: INTEGER;
BEGIN
  n := StrLen(name);
  IF n >= 4 THEN
    FOR i := 0 TO 3 DO WriteChar(r, name[i]) END
  ELSE
    WriteChar(r, ' ');
    FOR i := 0 TO n-1 DO WriteChar(r, name[i]) END;
    WHILE n < 3 DO WriteChar(r, ' '); INC(n) END
  END
END WriteAtomName;

PROCEDURE WriteModel*(VAR r: Files.Rider; VAR m: Model; modelNo: INTEGER);
VAR i: INTEGER; a: Atom; recName: ARRAY 7 OF CHAR;
BEGIN
  IF modelNo > 0 THEN
    WriteStr(r, "MODEL "); WriteIntW(r, modelNo, 8); WriteNL(r)
  END;
  FOR i := 0 TO m.count-1 DO
    a := m.atoms[i];
    IF a.isHet THEN COPY("HETATM", recName) ELSE COPY("ATOM  ", recName) END;
    WriteStr(r, recName); WriteIntW(r, a.serial, 5);
    WriteChar(r, ' '); WriteAtomName(r, a.name);
    WriteChar(r, a.altLoc); WriteStr(r, a.resName);
    i := StrLen(a.resName); WHILE i < 3 DO WriteChar(r, ' '); INC(i) END;
    WriteChar(r, ' '); WriteChar(r, a.chainID);
    WriteIntW(r, a.resSeq, 4); WriteChar(r, a.iCode);
    WriteStr(r, "   ");
    WriteReal83(r, a.x); WriteReal83(r, a.y); WriteReal83(r, a.z);
    WriteReal62(r, a.occupancy); WriteReal62(r, a.tempFactor);
    WriteStr(r, "          ");
    IF StrLen(a.element) < 2 THEN WriteChar(r, ' ') END;
    WriteStr(r, a.element); WriteNL(r)
  END;
  IF modelNo > 0 THEN WriteStr(r, "ENDMDL"); WriteNL(r)
  ELSE WriteStr(r, "END"); WriteNL(r)
  END
END WriteModel;

(* ================================================================== *)
(*  Multi-format parsers: mmCIF, SDF/MOL, XYZ                         *)
(* ================================================================== *)

PROCEDURE StrEqCI(VAR a, b: ARRAY OF CHAR): BOOLEAN;
VAR i: INTEGER; ca, cb: CHAR;
BEGIN
  i := 0;
  LOOP
    ca := a[i]; cb := b[i];
    IF (ca >= 'a') & (ca <= 'z') THEN ca := CHR(ORD(ca)-32) END;
    IF (cb >= 'a') & (cb <= 'z') THEN cb := CHR(ORD(cb)-32) END;
    IF ca # cb THEN RETURN FALSE END;
    IF ca = 0X THEN RETURN TRUE END;
    INC(i)
  END
END StrEqCI;

PROCEDURE FileExt(path: ARRAY OF CHAR; VAR ext: ARRAY OF CHAR);
VAR i, dot: INTEGER; c: CHAR;
BEGIN
  dot := -1; i := 0;
  WHILE path[i] # 0X DO
    IF path[i] = '.' THEN dot := i END; INC(i)
  END;
  IF dot < 0 THEN ext[0] := 0X; RETURN END;
  i := 0;
  WHILE path[dot+i] # 0X DO
    c := path[dot+i];
    IF (c >= 'A') & (c <= 'Z') THEN c := CHR(ORD(c)+32) END;
    ext[i] := c; INC(i)
  END;
  ext[i] := 0X
END FileExt;

PROCEDURE TrimStr(VAR s: ARRAY OF CHAR);
VAR i, j, len: INTEGER;
BEGIN
  len := 0; WHILE s[len] # 0X DO INC(len) END;
  i := 0; WHILE (i < len) & (s[i] = ' ') DO INC(i) END;
  j := len-1; WHILE (j >= i) & (s[j] = ' ') DO DEC(j) END;
  len := j-i+1;
  IF i > 0 THEN FOR j := 0 TO len-1 DO s[j] := s[i+j] END END;
  s[len] := 0X
END TrimStr;

PROCEDURE SubReal(VAR line: ARRAY OF CHAR; from, len: INTEGER; VAR val: REAL): BOOLEAN;
VAR buf: ARRAY 32 OF CHAR; i, j: INTEGER;
BEGIN
  i := from; j := 0;
  WHILE (i < from+len) & (line[i] = ' ') DO INC(i) END;
  WHILE (i < from+len) & (line[i] # 0X) & (j < 31) DO
    buf[j] := line[i]; INC(i); INC(j)
  END;
  buf[j] := 0X;
  RETURN Strings.StrToReal(buf, val)
END SubReal;

PROCEDURE SubInt(VAR line: ARRAY OF CHAR; from, len: INTEGER; VAR val: INTEGER): BOOLEAN;
VAR buf: ARRAY 16 OF CHAR; i, j: INTEGER;
BEGIN
  i := from; j := 0;
  WHILE (i < from+len) & (line[i] = ' ') DO INC(i) END;
  WHILE (i < from+len) & (line[i] # 0X) & (j < 15) DO
    buf[j] := line[i]; INC(i); INC(j)
  END;
  buf[j] := 0X;
  RETURN Strings.StrToInt(buf, val)
END SubInt;

PROCEDURE SubCopy(VAR line: ARRAY OF CHAR; from, n: INTEGER; VAR dest: ARRAY OF CHAR);
VAR i, j, lim: INTEGER;
BEGIN
  lim := LEN(dest)-1; j := 0; i := from;
  WHILE (line[i] = ' ') & (i < from+n) DO INC(i) END;
  WHILE (i < from+n) & (line[i] # 0X) & (j < lim) DO
    dest[j] := line[i]; INC(i); INC(j)
  END;
  WHILE (j > 0) & (dest[j-1] = ' ') DO DEC(j) END;
  dest[j] := 0X
END SubCopy;

(* ---- mmCIF -------------------------------------------------------- *)

CONST CifMaxCols = 64;

TYPE
  CifColMap = RECORD
    group, serial, element, name,
    resName, chainLabel, chainAuth,
    seqLabel, seqAuth,
    x, y, z, bfac, modelNum: INTEGER
  END;

PROCEDURE CifColInit(VAR m: CifColMap);
BEGIN
  m.group:=-1; m.serial:=-1; m.element:=-1; m.name:=-1; m.resName:=-1;
  m.chainLabel:=-1; m.chainAuth:=-1; m.seqLabel:=-1; m.seqAuth:=-1;
  m.x:=-1; m.y:=-1; m.z:=-1; m.bfac:=-1; m.modelNum:=-1
END CifColInit;

PROCEDURE CifMatchCol(VAR colname: ARRAY OF CHAR; VAR m: CifColMap; idx: INTEGER);
VAR s: ARRAY 64 OF CHAR;
BEGIN
  Strings.Copy(colname, s); TrimStr(s);
  IF Strings.Pos("_atom_site.", s) = 0 THEN
    Strings.Extract(s, 11, Strings.Length(s)-11, s)
  END;
  IF    StrEqCI(s, "group_PDB")          THEN m.group      := idx
  ELSIF StrEqCI(s, "id")                 THEN m.serial      := idx
  ELSIF StrEqCI(s, "type_symbol")        THEN m.element     := idx
  ELSIF StrEqCI(s, "label_atom_id")      THEN m.name        := idx
  ELSIF StrEqCI(s, "label_comp_id")      THEN m.resName     := idx
  ELSIF StrEqCI(s, "label_asym_id")      THEN m.chainLabel  := idx
  ELSIF StrEqCI(s, "auth_asym_id")       THEN m.chainAuth   := idx
  ELSIF StrEqCI(s, "label_seq_id")       THEN m.seqLabel    := idx
  ELSIF StrEqCI(s, "auth_seq_id")        THEN m.seqAuth     := idx
  ELSIF StrEqCI(s, "Cartn_x")            THEN m.x           := idx
  ELSIF StrEqCI(s, "Cartn_y")            THEN m.y           := idx
  ELSIF StrEqCI(s, "Cartn_z")            THEN m.z           := idx
  ELSIF StrEqCI(s, "B_iso_or_equiv")     THEN m.bfac        := idx
  ELSIF StrEqCI(s, "pdbx_PDB_model_num") THEN m.modelNum    := idx
  END
END CifMatchCol;

PROCEDURE CifNextToken(VAR line: ARRAY OF CHAR; VAR pos: INTEGER;
                        VAR tok: ARRAY OF CHAR): BOOLEAN;
VAR i, lim: INTEGER;
BEGIN
  lim := LEN(tok)-1;
  WHILE (line[pos] = ' ') OR (line[pos] = 9X) DO INC(pos) END;
  IF (line[pos] = 0X) OR (line[pos] = '#') THEN RETURN FALSE END;
  i := 0;
  IF line[pos] = "'" THEN
    INC(pos);
    WHILE (line[pos] # 0X) &
          ~((line[pos] = "'") & ((line[pos+1] = ' ') OR (line[pos+1] = 0X))) DO
      IF i < lim THEN tok[i] := line[pos]; INC(i) END; INC(pos)
    END;
    IF line[pos] = "'" THEN INC(pos) END
  ELSE
    WHILE (line[pos] # 0X) & (line[pos] # ' ') & (line[pos] # 9X) DO
      IF i < lim THEN tok[i] := line[pos]; INC(i) END; INC(pos)
    END
  END;
  tok[i] := 0X;
  RETURN i > 0
END CifNextToken;

PROCEDURE LoadCIF(path: ARRAY OF CHAR; VAR model: Model;
                  modelNo: INTEGER; VAR err: INTEGER): BOOLEAN;
VAR
  f: Files.File; rd: Files.Rider; tmpPath: ARRAY 1024 OF CHAR;
  line: ARRAY 512 OF CHAR; tok, colname: ARRAY 64 OF CHAR;
  tokens: ARRAY CifMaxCols OF ARRAY 64 OF CHAR;
  cm: CifColMap; inAtomLoop: BOOLEAN;
  nCols, pos, t, seqVal, serialVal, mdlNum: INTEGER;
  xv, yv, zv, bv: REAL; a: Atom; loop_: ARRAY 8 OF CHAR;
BEGIN
  err := 0;
  IF ~GzOpen(path, f, tmpPath) THEN err := 1; RETURN FALSE END;
  Files.Set(rd, f, 0);
  model.count := 0; model.ssCount := 0;
  CifColInit(cm); inAtomLoop := FALSE; nCols := 0;
  loop_ := "loop_";
  LOOP
    Files.ReadLine(rd, line);
    IF rd.eof & (line[0] = 0X) THEN EXIT END;
    TrimStr(line);
    IF line[0] = '#' THEN
    ELSIF StrEqCI(line, loop_) THEN
      inAtomLoop := FALSE; nCols := 0; CifColInit(cm)
    ELSIF (line[0] = '_') & (Strings.Pos("_atom_site.", line) = 0) THEN
      Strings.Copy(line, colname);
      CifMatchCol(colname, cm, nCols); INC(nCols); inAtomLoop := TRUE
    ELSIF inAtomLoop & (nCols > 0) & (line[0] # '_') & (line[0] # 0X) THEN
      pos := 0; t := 0;
      WHILE (t < nCols) & CifNextToken(line, pos, tokens[t]) DO INC(t) END;
      mdlNum := 1;
      IF cm.modelNum >= 0 THEN
        IF ~Strings.StrToInt(tokens[cm.modelNum], mdlNum) THEN mdlNum := 1 END
      END;
      IF mdlNum = modelNo THEN
        a.isHet := FALSE;
        IF cm.group >= 0 THEN
          tok := "ATOM"; a.isHet := ~StrEqCI(tokens[cm.group], tok)
        END;
        IF (cm.x >= 0) & (cm.y >= 0) & (cm.z >= 0) &
           Strings.StrToReal(tokens[cm.x], xv) &
           Strings.StrToReal(tokens[cm.y], yv) &
           Strings.StrToReal(tokens[cm.z], zv) &
           (model.count < MaxAtoms) THEN
          a.x := xv; a.y := yv; a.z := zv;
          serialVal := model.count+1;
          IF cm.serial >= 0 THEN
            IF ~Strings.StrToInt(tokens[cm.serial], serialVal) THEN
              serialVal := model.count+1
            END
          END;
          a.serial := serialVal;
          IF cm.element >= 0 THEN Strings.Copy(tokens[cm.element], a.element)
          ELSE a.element[0] := 0X END;
          IF cm.name >= 0 THEN Strings.Copy(tokens[cm.name], a.name)
          ELSE a.name[0] := 0X END;
          IF cm.resName >= 0 THEN Strings.Copy(tokens[cm.resName], a.resName)
          ELSE a.resName[0] := 0X END;
          IF cm.chainAuth >= 0 THEN a.chainID := tokens[cm.chainAuth][0]
          ELSIF cm.chainLabel >= 0 THEN a.chainID := tokens[cm.chainLabel][0]
          ELSE a.chainID := 'A' END;
          seqVal := 1;
          IF cm.seqAuth >= 0 THEN
            IF ~Strings.StrToInt(tokens[cm.seqAuth], seqVal) THEN seqVal := 1 END
          ELSIF cm.seqLabel >= 0 THEN
            IF ~Strings.StrToInt(tokens[cm.seqLabel], seqVal) THEN seqVal := 1 END
          END;
          a.resSeq := seqVal; bv := 0.0;
          IF cm.bfac >= 0 THEN
            IF ~Strings.StrToReal(tokens[cm.bfac], bv) THEN bv := 0.0 END
          END;
          a.tempFactor := bv; a.altLoc := ' '; a.iCode := ' '; a.occupancy := 1.0;
          model.atoms[model.count] := a; INC(model.count)
        END
      END
    ELSIF inAtomLoop & (line[0] = '_') THEN
      inAtomLoop := FALSE
    END
  END;
  GzClose(f, tmpPath);
  IF model.count = 0 THEN err := 2; RETURN FALSE END;
  ComputeBounds(model); RETURN TRUE
END LoadCIF;

(* ---- SDF / MOL ---------------------------------------------------- *)

PROCEDURE LoadSDF(path: ARRAY OF CHAR; VAR model: Model;
                  modelNo: INTEGER; VAR err: INTEGER): BOOLEAN;
VAR
  f: Files.File; rd: Files.Rider; tmpPath: ARRAY 1024 OF CHAR;
  line: ARRAY 256 OF CHAR; sym: ARRAY 4 OF CHAR;
  xv, yv, zv: REAL; natoms, i, molIdx: INTEGER;
  a: Atom; sep: ARRAY 8 OF CHAR;
BEGIN
  err := 0;
  IF ~GzOpen(path, f, tmpPath) THEN err := 1; RETURN FALSE END;
  Files.Set(rd, f, 0);
  model.count := 0; model.ssCount := 0;
  molIdx := 0; sep := "$$$$";
  LOOP
    INC(molIdx);
    Files.ReadLine(rd, line); IF rd.eof THEN EXIT END;
    Files.ReadLine(rd, line); IF rd.eof THEN EXIT END;
    Files.ReadLine(rd, line); IF rd.eof THEN EXIT END;
    Files.ReadLine(rd, line); IF rd.eof THEN EXIT END;
    IF ~SubInt(line, 0, 3, natoms) THEN
      err := 2; GzClose(f, tmpPath); RETURN FALSE
    END;
    IF molIdx = modelNo THEN
      FOR i := 1 TO natoms DO
        Files.ReadLine(rd, line);
        IF rd.eof THEN err := 2; GzClose(f, tmpPath); RETURN FALSE END;
        IF SubReal(line, 0, 10, xv) & SubReal(line, 10, 10, yv) &
           SubReal(line, 20, 10, zv) & (model.count < MaxAtoms) THEN
          SubCopy(line, 31, 3, sym); TrimStr(sym);
          a.x := xv; a.y := yv; a.z := zv;
          Strings.Copy(sym, a.element);
          IF (a.element[0] >= 'a') & (a.element[0] <= 'z') THEN
            a.element[0] := CHR(ORD(a.element[0])-32)
          END;
          Strings.Copy(sym, a.name);
          a.resName[0]:='L'; a.resName[1]:='I'; a.resName[2]:='G'; a.resName[3]:=0X;
          a.chainID:='A'; a.resSeq:=1; a.serial:=model.count+1;
          a.tempFactor:=0.0; a.occupancy:=1.0; a.altLoc:=' '; a.iCode:=' ';
          a.isHet:=FALSE;   (* SDF ligands shown as regular atoms so they *)
          model.atoms[model.count] := a; INC(model.count)
        END
      END;
      LOOP
        Files.ReadLine(rd, line); IF rd.eof THEN EXIT END;
        IF Strings.Pos(sep, line) = 0 THEN EXIT END
      END;
      EXIT
    ELSE
      FOR i := 1 TO natoms DO
        Files.ReadLine(rd, line); IF rd.eof THEN EXIT END
      END;
      LOOP
        Files.ReadLine(rd, line); IF rd.eof THEN EXIT END;
        IF Strings.Pos(sep, line) = 0 THEN EXIT END
      END
    END
  END;
  GzClose(f, tmpPath);
  IF model.count = 0 THEN err := 2; RETURN FALSE END;
  ComputeBounds(model); RETURN TRUE
END LoadSDF;

(* ---- XYZ ---------------------------------------------------------- *)

PROCEDURE LoadXYZ(path: ARRAY OF CHAR; VAR model: Model;
                  modelNo: INTEGER; VAR err: INTEGER): BOOLEAN;
VAR
  f: Files.File; rd: Files.Rider; tmpPath: ARRAY 1024 OF CHAR;
  line: ARRAY 256 OF CHAR;
  xv, yv, zv: REAL; natoms, i, frameIdx, pos, j: INTEGER;
  a: Atom;
BEGIN
  err := 0;
  IF ~GzOpen(path, f, tmpPath) THEN err := 1; RETURN FALSE END;
  Files.Set(rd, f, 0);
  model.count := 0; model.ssCount := 0;
  frameIdx := 0;
  LOOP
    Files.ReadLine(rd, line);
    IF rd.eof & (line[0] = 0X) THEN EXIT END;
    TrimStr(line);
    IF (line[0] = 0X) OR ~Strings.StrToInt(line, natoms) OR (natoms <= 0) THEN
    ELSE
      INC(frameIdx);
      Files.ReadLine(rd, line);
      IF frameIdx = modelNo THEN
        FOR i := 1 TO natoms DO
          Files.ReadLine(rd, line);
          IF rd.eof THEN err := 2; GzClose(f, tmpPath); RETURN FALSE END;
          pos := 0;
          WHILE (line[pos] = ' ') OR (line[pos] = 9X) DO INC(pos) END;
          j := 0;
          WHILE (line[pos] # 0X) & (line[pos] # ' ') & (line[pos] # 9X) & (j < 3) DO
            a.element[j] := line[pos]; INC(pos); INC(j)
          END;
          a.element[j] := 0X;
          IF (a.element[0] >= 'a') & (a.element[0] <= 'z') THEN
            a.element[0] := CHR(ORD(a.element[0])-32)
          END;
          IF SubReal(line, pos, 20, xv) & SubReal(line, pos+20, 20, yv) &
             SubReal(line, pos+40, 20, zv) & (model.count < MaxAtoms) THEN
            a.x:=xv; a.y:=yv; a.z:=zv;
            Strings.Copy(a.element, a.name);
            a.resName[0]:='U'; a.resName[1]:='N'; a.resName[2]:='K'; a.resName[3]:=0X;
            a.chainID:='A'; a.resSeq:=i; a.serial:=model.count+1;
            a.tempFactor:=0.0; a.occupancy:=1.0; a.altLoc:=' '; a.iCode:=' ';
            a.isHet:=FALSE;
            model.atoms[model.count] := a; INC(model.count)
          END
        END;
        EXIT
      ELSE
        FOR i := 1 TO natoms DO
          Files.ReadLine(rd, line); IF rd.eof THEN EXIT END
        END
      END
    END;
    IF rd.eof THEN EXIT END
  END;
  GzClose(f, tmpPath);
  IF model.count = 0 THEN err := 2; RETURN FALSE END;
  ComputeBounds(model); RETURN TRUE
END LoadXYZ;

(* ---- Format dispatcher -------------------------------------------- *)

PROCEDURE LoadAny*(path: ARRAY OF CHAR; VAR model: Model;
                   modelNo: INTEGER; VAR err: INTEGER): BOOLEAN;
VAR ext, a, b: ARRAY 16 OF CHAR; base: ARRAY 1024 OF CHAR; blen: INTEGER;
BEGIN
  Strings.Copy(path, base);
  blen := Strings.Length(base);
  IF Strings.EndsWith(base, ".gz") THEN base[blen-3] := 0X END;
  FileExt(base, ext);
  a := ".pdb"; b := ".ent";
  IF StrEqCI(ext, a) OR StrEqCI(ext, b) THEN
    RETURN LoadModel(path, model, modelNo, err)
  END;
  a := ".cif"; b := ".mmcif";
  IF StrEqCI(ext, a) OR StrEqCI(ext, b) THEN
    RETURN LoadCIF(path, model, modelNo, err)
  END;
  a := ".sdf"; b := ".mol";
  IF StrEqCI(ext, a) OR StrEqCI(ext, b) THEN
    RETURN LoadSDF(path, model, modelNo, err)
  END;
  a := ".xyz";
  IF StrEqCI(ext, a) THEN RETURN LoadXYZ(path, model, modelNo, err) END;
  err := 3; RETURN FALSE
END LoadAny;

BEGIN
  tmpSeq := 0
END BioPDB.
