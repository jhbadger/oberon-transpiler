MODULE testpdb;
(*
  testpdb — Exercise BioPDB Load, LoadModel, and streaming reader.

  Usage:  testpdb <file.pdb[.gz]>

  Prints a summary of each model found, the bounding box, centroid,
  atom-type counts, and a dump of the first 5 and last 5 atoms so
  the column parser can be visually verified.
*)

IMPORT Args, BioPDB, Strings, Out;

(* ------------------------------------------------------------------ *)
(*  Helpers                                                             *)
(* ------------------------------------------------------------------ *)

PROCEDURE Separator;
BEGIN
  Out.String("--------------------------------------------------"); Out.Ln()
END Separator;

PROCEDURE PrintReal(x: REAL; w, d: INTEGER);
BEGIN Out.Fixed(x, w, d) END PrintReal;

PROCEDURE PrintAtom(VAR a: BioPDB.Atom; idx: INTEGER);
BEGIN
  Out.String("  ["); Out.Int(idx, 4); Out.String("] ");
  IF a.isHet THEN Out.String("HETATM") ELSE Out.String("ATOM  ") END;
  Out.String("  serial="); Out.Int(a.serial, 5);
  Out.String("  name=|"); Out.String(a.name); Out.String("|");
  Out.String("  res=");   Out.String(a.resName);
  Out.Char(' '); Out.Char(a.chainID);
  Out.Int(a.resSeq, 4);
  Out.String("  elem=|"); Out.String(a.element); Out.String("|");
  Out.String("  xyz=(");
  PrintReal(a.x, 8, 3); Out.Char(',');
  PrintReal(a.y, 8, 3); Out.Char(',');
  PrintReal(a.z, 8, 3); Out.Char(')');
  Out.String("  B="); PrintReal(a.tempFactor, 6, 2);
  Out.Ln()
END PrintAtom;

PROCEDURE PrintModelSummary(VAR m: BioPDB.Model; label: ARRAY OF CHAR);
VAR i, nAtom, nHet, nCA: INTEGER; a: BioPDB.Atom;
BEGIN
  Separator();
  Out.String(label); Out.Ln();
  Out.String("  Atoms      : "); Out.Int(m.count, 0); Out.Ln();

  (* Count ATOM vs HETATM and CA atoms *)
  nAtom := 0; nHet := 0; nCA := 0;
  FOR i := 0 TO m.count - 1 DO
    a := m.atoms[i];
    IF a.isHet THEN INC(nHet) ELSE INC(nAtom) END;
    IF (a.name[0] = 'C') & (a.name[1] = 'A') &
       (a.name[2] = ' ') & ~a.isHet THEN INC(nCA) END
  END;
  Out.String("    ATOM     : "); Out.Int(nAtom, 0); Out.Ln();
  Out.String("    HETATM   : "); Out.Int(nHet,  0); Out.Ln();
  Out.String("    CA atoms  : "); Out.Int(nCA,   0); Out.Ln();

  Out.String("  Bounding box:"); Out.Ln();
  Out.String("    X  "); PrintReal(m.minX,9,3);
  Out.String(" .."); PrintReal(m.maxX,9,3); Out.Ln();
  Out.String("    Y  "); PrintReal(m.minY,9,3);
  Out.String(" .."); PrintReal(m.maxY,9,3); Out.Ln();
  Out.String("    Z  "); PrintReal(m.minZ,9,3);
  Out.String(" .."); PrintReal(m.maxZ,9,3); Out.Ln();

  Out.String("  Centroid    : (");
  PrintReal(m.cx,8,3); Out.Char(',');
  PrintReal(m.cy,8,3); Out.Char(',');
  PrintReal(m.cz,8,3); Out.Char(')'); Out.Ln();

  IF m.count = 0 THEN RETURN END;

  (* First up to 5 atoms *)
  Out.String("  First atoms:"); Out.Ln();
  i := 0;
  WHILE (i < m.count) & (i < 5) DO
    PrintAtom(m.atoms[i], i); INC(i)
  END;

  (* Last up to 5 atoms (skip if already shown) *)
  IF m.count > 5 THEN
    Out.String("  Last atoms:"); Out.Ln();
    i := m.count - 5;
    IF i < 5 THEN i := 5 END;
    WHILE i < m.count DO
      PrintAtom(m.atoms[i], i); INC(i)
    END
  END
END PrintModelSummary;

(* ------------------------------------------------------------------ *)
(*  Tests                                                               *)
(* ------------------------------------------------------------------ *)

PROCEDURE TestLoad(path: ARRAY OF CHAR);
VAR m: BioPDB.Model; err: INTEGER;
BEGIN
  Separator();
  Out.String("TEST 1: BioPDB.Load"); Out.Ln();
  Out.String("  File: "); Out.String(path); Out.Ln();
  IF BioPDB.Load(path, m, err) THEN
    PrintModelSummary(m, "Load result (first/only model)")
  ELSE
    Out.String("  FAILED  err="); Out.Int(err, 0); Out.Ln()
  END
END TestLoad;

PROCEDURE TestLoadModel(path: ARRAY OF CHAR);
VAR m: BioPDB.Model; err: INTEGER;
BEGIN
  Separator();
  Out.String("TEST 2: BioPDB.LoadModel(1)"); Out.Ln();
  Out.String("  File: "); Out.String(path); Out.Ln();
  IF BioPDB.LoadModel(path, m, 1, err) THEN
    PrintModelSummary(m, "LoadModel(1) result")
  ELSE
    Out.String("  FAILED  err="); Out.Int(err, 0); Out.Ln()
  END;

  Out.Ln();
  Out.String("TEST 2b: BioPDB.LoadModel(2)"); Out.Ln();
  IF BioPDB.LoadModel(path, m, 2, err) THEN
    PrintModelSummary(m, "LoadModel(2) result")
  ELSE
    Out.String("  No second model (err="); Out.Int(err, 0);
    Out.String(") -- expected for single-model files"); Out.Ln()
  END
END TestLoadModel;

PROCEDURE TestStreaming(path: ARRAY OF CHAR);
VAR rdr: BioPDB.PDBReader; m: BioPDB.Model;
    err, n: INTEGER; label: ARRAY 64 OF CHAR; ns: ARRAY 16 OF CHAR;
BEGIN
  Separator();
  Out.String("TEST 3: Streaming OpenPDB / ReadModel"); Out.Ln();
  Out.String("  File: "); Out.String(path); Out.Ln();
  n := 0;
  IF BioPDB.OpenPDB(rdr, path) THEN
    WHILE BioPDB.ReadModel(rdr, m, err) DO
      INC(n);
      COPY("Streaming model #", label);
      Strings.IntToStr(n, ns);
      Strings.Append(ns, label);
      PrintModelSummary(m, label)
    END;
    BioPDB.ClosePDB(rdr);
    Out.String("  Total models read: "); Out.Int(n, 0); Out.Ln()
  ELSE
    Out.String("  OpenPDB failed"); Out.Ln()
  END
END TestStreaming;

PROCEDURE TestBadFile;
VAR m: BioPDB.Model; err: INTEGER;
BEGIN
  Separator();
  Out.String("TEST 4: Load non-existent file (expect failure)"); Out.Ln();
  IF BioPDB.Load("/nonexistent/no.pdb", m, err) THEN
    Out.String("  UNEXPECTED SUCCESS"); Out.Ln()
  ELSE
    Out.String("  Correctly returned FALSE, err=");
    Out.Int(err, 0); Out.Ln()
  END
END TestBadFile;

(* ------------------------------------------------------------------ *)
(*  Main                                                                *)
(* ------------------------------------------------------------------ *)

VAR path: ARRAY 1024 OF CHAR;

BEGIN
  IF Args.Count() < 1 THEN
    Out.String("Usage: testpdb <file.pdb[.gz]>"); Out.Ln();
    HALT(1)
  END;
  Args.Get(1, path);

  TestLoad(path);
  TestLoadModel(path);
  TestStreaming(path);
  TestBadFile();

  Separator();
  Out.String("Done."); Out.Ln()
END testpdb.

