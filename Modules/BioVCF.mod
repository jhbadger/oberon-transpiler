MODULE BioVCF;
(*
  BioVCF — VCF/BCF variant call format reader (VCF 4.x).

  Opens a VCF file (plain text; bgzipped not supported), skips ##-header
  lines, reads the #CHROM header to discover sample names, then yields one
  VCFRecord per data line via ReadVCF.

  Field layout (mandatory):
    CHROM  POS  ID  REF  ALT  QUAL  FILTER  INFO  [FORMAT  sample...]

  POS is converted from 1-based to 0-based in VCFRecord.pos.
  ALT may contain multiple comma-separated alleles; only the first is stored
  in alt[0]; all alleles are stored in alts[] (up to MaxAlts).
  INFO is stored verbatim (up to 512 chars).
  Up to MaxSamples genotype strings are stored in gts[].

  Typical use:
    VAR r : BioVCF.VCFReader;  rec : BioVCF.VCFRecord;
    BioVCF.OpenVCF(r, "my.vcf");
    WHILE BioVCF.ReadVCF(r, rec) DO ... END;
    BioVCF.CloseVCF(r)
*)

IMPORT Files, Strings, Out;

CONST
  MaxAlts*    = 8;
  MaxSamples* = 128;

TYPE
  VCFRecord* = RECORD
    chrom*   : ARRAY 64  OF CHAR;
    pos*     : INTEGER;            (* 0-based *)
    id*      : ARRAY 64  OF CHAR;
    ref*     : ARRAY 64  OF CHAR;
    alt*     : ARRAY 64  OF CHAR;  (* first ALT allele *)
    alts*    : ARRAY MaxAlts OF ARRAY 64 OF CHAR;
    nAlts*   : INTEGER;
    qual*    : REAL;
    filter*  : ARRAY 64  OF CHAR;
    info*    : ARRAY 512 OF CHAR;
    format*  : ARRAY 128 OF CHAR;
    gts*     : ARRAY MaxSamples OF ARRAY 64 OF CHAR;
    nGTs*    : INTEGER
  END;

  VCFReader* = RECORD
    rider    : Files.Rider;
    done*    : BOOLEAN;
    samples* : ARRAY MaxSamples OF ARRAY 64 OF CHAR;
    nSamples*: INTEGER
  END;

(* ------------------------------------------------------------------ *)
(*  Private helpers                                                     *)
(* ------------------------------------------------------------------ *)

PROCEDURE GetTab(line: ARRAY OF CHAR; VAR pos: INTEGER;
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
END GetTab;

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

PROCEDURE ReadLine(VAR r: Files.Rider; VAR line: ARRAY OF CHAR);
VAR i: INTEGER; ch: CHAR;
BEGIN
  i := 0;
  REPEAT
    Files.Read(r, ch);
    IF ~r.eof & (ch # 0AX) & (ch # 0DX) & (i < LEN(line) - 1) THEN
      line[i] := ch; INC(i)
    END
  UNTIL r.eof OR (ch = 0AX);
  line[i] := 0X
END ReadLine;

PROCEDURE StripCR(VAR line: ARRAY OF CHAR);
VAR n: INTEGER;
BEGIN
  n := Strings.Length(line);
  IF (n > 0) & (line[n - 1] = 0DX) THEN line[n - 1] := 0X END
END StripCR;

(* ------------------------------------------------------------------ *)
(*  Open / Close                                                        *)
(* ------------------------------------------------------------------ *)

PROCEDURE OpenVCF*(VAR r: VCFReader; path: ARRAY OF CHAR): BOOLEAN;
(*
  Open a VCF file.  Reads and discards ##-meta lines; parses the #CHROM
  header line to populate r.samples.  Returns FALSE if the file cannot be
  opened.
*)
VAR
  f    : Files.File;
  line : ARRAY 4096 OF CHAR;
  pos  : INTEGER;
  tmp  : ARRAY 64 OF CHAR;
  col  : INTEGER;
BEGIN
  r.done     := TRUE;
  r.nSamples := 0;
  f := Files.Old(path);
  IF f = NIL THEN RETURN FALSE END;
  Files.Set(r.rider, f, 0);

  LOOP
    ReadLine(r.rider, line);
    IF r.rider.eof & (line[0] = 0X) THEN EXIT END;
    StripCR(line);
    IF (line[0] = '#') & (line[1] = '#') THEN
      (* meta-information line — skip *)
    ELSIF (line[0] = '#') THEN
      (* #CHROM header line: parse sample names from columns 9+ *)
      pos := 0; col := 0;
      WHILE (pos < LEN(line)) & (line[pos] # 0X) DO
        GetTab(line, pos, tmp, 64);
        IF col >= 9 THEN
          IF r.nSamples < MaxSamples THEN
            COPY(tmp, r.samples[r.nSamples]);
            INC(r.nSamples)
          END
        END;
        INC(col)
      END;
      r.done := FALSE;
      EXIT
    ELSE
      EXIT  (* data line before header — unexpected, stop *)
    END
  END;
  RETURN ~r.done
END OpenVCF;

PROCEDURE CloseVCF*(VAR r: VCFReader);
BEGIN
  r.done := TRUE
END CloseVCF;

(* ------------------------------------------------------------------ *)
(*  ReadVCF                                                             *)
(* ------------------------------------------------------------------ *)

PROCEDURE ReadVCF*(VAR r: VCFReader; VAR rec: VCFRecord): BOOLEAN;
(*
  Read the next data record into rec.  Returns FALSE at EOF or after Close.
*)
VAR
  line        : ARRAY 4096 OF CHAR;
  tmp         : ARRAY 64   OF CHAR;
  pos, i      : INTEGER;
  ai, aj, ak  : INTEGER;
BEGIN
  IF r.done THEN RETURN FALSE END;
  LOOP
    ReadLine(r.rider, line);
    IF r.rider.eof & (line[0] = 0X) THEN r.done := TRUE; RETURN FALSE END;
    StripCR(line);
    IF (line[0] # '#') & (line[0] # 0X) THEN EXIT END
  END;

  pos := 0;
  GetTab(line, pos, rec.chrom,  64);
  GetTab(line, pos, tmp,        64); rec.pos    := AtoI(tmp) - 1;
  GetTab(line, pos, rec.id,     64);
  GetTab(line, pos, rec.ref,    64);
  GetTab(line, pos, tmp,        64);

  (* parse ALT alleles — split tmp on commas *)
  ai := 0; aj := 0; ak := 0;
  WHILE (ai < LEN(tmp)) & (tmp[ai] # 0X) & (aj < MaxAlts) DO
    IF tmp[ai] = ',' THEN
      rec.alts[aj][ak] := 0X; INC(aj); ak := 0
    ELSIF ak < 63 THEN
      rec.alts[aj][ak] := tmp[ai]; INC(ak)
    END;
    INC(ai)
  END;
  IF ak > 0 THEN rec.alts[aj][ak] := 0X; INC(aj) END;
  rec.nAlts := aj;
  IF rec.nAlts > 0 THEN COPY(rec.alts[0], rec.alt)
  ELSE rec.alt[0] := 0X
  END;

  GetTab(line, pos, tmp,         64);
  IF tmp[0] = '.' THEN rec.qual := 0.0
  ELSE rec.qual := AtoR(tmp)
  END;

  GetTab(line, pos, rec.filter, 64);
  GetTab(line, pos, rec.info,  512);

  (* FORMAT column (optional) *)
  rec.format[0] := 0X;
  rec.nGTs      := 0;
  IF (pos < LEN(line)) & (line[pos] # 0X) THEN
    GetTab(line, pos, rec.format, 128);
    i := 0;
    WHILE (pos < LEN(line)) & (line[pos] # 0X) & (i < MaxSamples) DO
      GetTab(line, pos, rec.gts[i], 64);
      INC(i)
    END;
    rec.nGTs := i
  END;
  RETURN TRUE
END ReadVCF;

(* ------------------------------------------------------------------ *)
(*  WriteVCF  (simple header + data line writer)                       *)
(* ------------------------------------------------------------------ *)

PROCEDURE WriteVCF*(VAR wr: Files.Rider; VAR rec: VCFRecord);
(*
  Write one VCF data line (no ##-header) to wr.
  ALT is assembled from rec.alts[0..nAlts-1]; if nAlts=0, rec.alt is used.
*)
VAR
  tmp : ARRAY 64  OF CHAR;
  i   : INTEGER;
BEGIN
  Files.WriteString(wr, rec.chrom);   Files.Write(wr, 09X);
  Strings.IntToStr(rec.pos + 1, tmp);
  Files.WriteString(wr, tmp);         Files.Write(wr, 09X);
  Files.WriteString(wr, rec.id);      Files.Write(wr, 09X);
  Files.WriteString(wr, rec.ref);     Files.Write(wr, 09X);
  IF rec.nAlts > 0 THEN
    FOR i := 0 TO rec.nAlts - 1 DO
      IF i > 0 THEN Files.Write(wr, ',') END;
      Files.WriteString(wr, rec.alts[i])
    END
  ELSE
    Files.WriteString(wr, rec.alt)
  END;
  Files.Write(wr, 09X);
  IF rec.qual = 0.0 THEN Files.Write(wr, '.')
  ELSE
    Strings.RealToStr(rec.qual, tmp);
    Files.WriteString(wr, tmp)
  END;
  Files.Write(wr, 09X);
  Files.WriteString(wr, rec.filter);  Files.Write(wr, 09X);
  Files.WriteString(wr, rec.info);
  IF rec.nGTs > 0 THEN
    Files.Write(wr, 09X);
    Files.WriteString(wr, rec.format);
    FOR i := 0 TO rec.nGTs - 1 DO
      Files.Write(wr, 09X);
      Files.WriteString(wr, rec.gts[i])
    END
  END;
  Files.Write(wr, 0AX)
END WriteVCF;

END BioVCF.
