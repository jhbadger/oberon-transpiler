(*
  Chu-Fasman Secondary Structure Prediction
  -----------------------------------------
  This module implements the Chu-Fasman method for predicting protein
  secondary structure (helix, sheet, coil) from amino acid sequences.

  The Chu-Fasman method uses propensity values for each amino acid
  to calculate the probability of being in a helical, sheet, or coil
  conformation.
*)

MODULE ChuFasman;

IMPORT BioIO, BioSeq, Out, Args;

(* ---- Chu-Fasman Propensity Values ----------------------------------- *)
(* These are the original propensity values from Chu & Fasman (1972) *)
(* Higher values indicate higher propensity for that secondary structure *)

CONST
  (* Helix propensity values *)
  P_Helix_A = 1.42;
  P_Helix_C = 0.76;
  P_Helix_D = 0.88;
  P_Helix_E = 0.67;
  P_Helix_F = 0.31;
  P_Helix_G = 0.73;
  P_Helix_H = 0.57;
  P_Helix_I = 1.00;
  P_Helix_K = 0.77;
  P_Helix_L = 0.80;
  P_Helix_M = 0.91;
  P_Helix_N = 0.76;
  P_Helix_P = 0.57;
  P_Helix_Q = 1.11;
  P_Helix_R = 0.50;
  P_Helix_S = 0.77;
  P_Helix_T = 0.54;
  P_Helix_V = 0.71;
  P_Helix_W = 0.27;
  P_Helix_Y = 0.64;

  (* Sheet propensity values *)
  P_Sheet_A = 0.83;
  P_Sheet_C = 1.18;
  P_Sheet_D = 0.51;
  P_Sheet_E = 0.88;
  P_Sheet_F = 0.36;
  P_Sheet_G = 1.03;
  P_Sheet_H = 0.57;
  P_Sheet_I = 0.74;
  P_Sheet_K = 0.79;
  P_Sheet_L = 0.59;
  P_Sheet_M = 0.97;
  P_Sheet_N = 0.71;
  P_Sheet_P = 0.82;
  P_Sheet_Q = 0.10;
  P_Sheet_R = 0.67;
  P_Sheet_S = 0.94;
  P_Sheet_T = 0.67;
  P_Sheet_V = 0.73;
  P_Sheet_W = 0.24;
  P_Sheet_Y = 0.90;

  (* Coil propensity values *)
  P_Coil_A = 0.86;
  P_Coil_C = 1.18;
  P_Coil_D = 0.51;
  P_Coil_E = 0.88;
  P_Coil_F = 0.36;
  P_Coil_G = 1.03;
  P_Coil_H = 0.57;
  P_Coil_I = 0.74;
  P_Coil_K = 0.79;
  P_Coil_L = 0.59;
  P_Coil_M = 0.97;
  P_Coil_N = 0.71;
  P_Coil_P = 0.82;
  P_Coil_Q = 0.10;
  P_Coil_R = 0.67;
  P_Coil_S = 0.94;
  P_Coil_T = 0.67;
  P_Coil_V = 0.73;
  P_Coil_W = 0.24;
  P_Coil_Y = 0.90;

  (* Amino acid order for indexing *)
  AA_ORDER = "ACDEFGHIKLMNPQRSTVWY";
  NumAA = 20;

(* ---- Propensity lookup tables ---------------------------------------- *)
VAR
  P_Helix: ARRAY 20 OF REAL;
  P_Sheet: ARRAY 20 OF REAL;
  P_Coil:  ARRAY 20 OF REAL;

(* ---- Initialize propensity tables ------------------------------------ *)
PROCEDURE InitTables();
BEGIN
  P_Helix[ 0] := P_Helix_A; P_Helix[ 1] := P_Helix_C;
  P_Helix[ 2] := P_Helix_D; P_Helix[ 3] := P_Helix_E;
  P_Helix[ 4] := P_Helix_F; P_Helix[ 5] := P_Helix_G;
  P_Helix[ 6] := P_Helix_H; P_Helix[ 7] := P_Helix_I;
  P_Helix[ 8] := P_Helix_K; P_Helix[ 9] := P_Helix_L;
  P_Helix[10] := P_Helix_M; P_Helix[11] := P_Helix_N;
  P_Helix[12] := P_Helix_P; P_Helix[13] := P_Helix_Q;
  P_Helix[14] := P_Helix_R; P_Helix[15] := P_Helix_S;
  P_Helix[16] := P_Helix_T; P_Helix[17] := P_Helix_V;
  P_Helix[18] := P_Helix_W; P_Helix[19] := P_Helix_Y;

  P_Sheet[ 0] := P_Sheet_A; P_Sheet[ 1] := P_Sheet_C;
  P_Sheet[ 2] := P_Sheet_D; P_Sheet[ 3] := P_Sheet_E;
  P_Sheet[ 4] := P_Sheet_F; P_Sheet[ 5] := P_Sheet_G;
  P_Sheet[ 6] := P_Sheet_H; P_Sheet[ 7] := P_Sheet_I;
  P_Sheet[ 8] := P_Sheet_K; P_Sheet[ 9] := P_Sheet_L;
  P_Sheet[10] := P_Sheet_M; P_Sheet[11] := P_Sheet_N;
  P_Sheet[12] := P_Sheet_P; P_Sheet[13] := P_Sheet_Q;
  P_Sheet[14] := P_Sheet_R; P_Sheet[15] := P_Sheet_S;
  P_Sheet[16] := P_Sheet_T; P_Sheet[17] := P_Sheet_V;
  P_Sheet[18] := P_Sheet_W; P_Sheet[19] := P_Sheet_Y;

  P_Coil[ 0] := P_Coil_A; P_Coil[ 1] := P_Coil_C;
  P_Coil[ 2] := P_Coil_D; P_Coil[ 3] := P_Coil_E;
  P_Coil[ 4] := P_Coil_F; P_Coil[ 5] := P_Coil_G;
  P_Coil[ 6] := P_Coil_H; P_Coil[ 7] := P_Coil_I;
  P_Coil[ 8] := P_Coil_K; P_Coil[ 9] := P_Coil_L;
  P_Coil[10] := P_Coil_M; P_Coil[11] := P_Coil_N;
  P_Coil[12] := P_Coil_P; P_Coil[13] := P_Coil_Q;
  P_Coil[14] := P_Coil_R; P_Coil[15] := P_Coil_S;
  P_Coil[16] := P_Coil_T; P_Coil[17] := P_Coil_V;
  P_Coil[18] := P_Coil_W; P_Coil[19] := P_Coil_Y;
END InitTables;

(* ---- Get propensity value -------------------------------------------- *)
PROCEDURE GetPropensity(aa: CHAR; structure: INTEGER): REAL;
(* structure: 0 = Helix, 1 = Sheet, 2 = Coil *)
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO NumAA - 1 DO
    IF AA_ORDER[i] = aa THEN
      IF structure = 0 THEN RETURN P_Helix[i]
      ELSIF structure = 1 THEN RETURN P_Sheet[i]
      ELSE RETURN P_Coil[i]
      END
    END
  END;
  RETURN 1.0  (* unknown residue: neutral propensity *)
END GetPropensity;

(* ---- Chu-Fasman prediction algorithm -------------------------------- *)
PROCEDURE PredictStructure(seq: BioSeq.Seq; VAR result: ARRAY OF CHAR);
VAR
  i, len: INTEGER;
  p_H, p_S, p_C, sum: REAL;
BEGIN
  len := BioSeq.Length(seq);
  FOR i := 0 TO len - 1 DO result[i] := 'C' END;  (* Default to coil *)

  FOR i := 1 TO len - 2 DO
    p_H := GetPropensity(BioSeq.Get(seq, i), 0);
    p_S := GetPropensity(BioSeq.Get(seq, i), 1);
    p_C := GetPropensity(BioSeq.Get(seq, i), 2);

    sum := p_H + p_S + p_C;
    IF sum > 0.0 THEN
      p_H := p_H / sum;
      p_S := p_S / sum;
      p_C := p_C / sum
    END;

    IF (p_H > p_S) & (p_H > p_C) THEN
      result[i] := 'H'
    ELSIF (p_S > p_H) & (p_S > p_C) THEN
      result[i] := 'E'
    ELSE
      result[i] := 'C'
    END
  END
END PredictStructure;

(* ---- Process a single sequence -------------------------------------- *)
PROCEDURE ProcessSeq(name: ARRAY OF CHAR; seq: BioSeq.Seq);
VAR
  i, len: INTEGER;
  structure: ARRAY 1000 OF CHAR;
BEGIN
  len := BioSeq.Length(seq);
  IF len = 0 THEN
    Out.String("Warning: Empty sequence "); Out.String(name); Out.Ln;
    RETURN
  END;

  PredictStructure(seq, structure);

  Out.String("Sequence: "); Out.String(name); Out.Ln;
  Out.String("Length: "); Out.Int(len, 0); Out.Ln;
  Out.String("Secondary Structure:"); Out.Ln;
  FOR i := 0 TO len - 1 DO
    Out.Char(structure[i])
  END;
  Out.Ln;
  Out.String("Legend: H = Helix, E = Sheet, C = Coil"); Out.Ln
END ProcessSeq;

(* ---- Main program --------------------------------------------------- *)
VAR
  filename: ARRAY 255 OF CHAR;
  rec: BioIO.FastaRecord;
  reader: BioIO.FastaReader;
BEGIN
  InitTables();

  IF Args.Count() < 1 THEN
    Out.String("Chu-Fasman Secondary Structure Prediction"); Out.Ln;
    Out.String("Usage: ChuFasman <fasta_file>"); Out.Ln;
    RETURN
  END;

  Args.Get(1, filename);

  IF ~BioIO.OpenFasta(reader, filename) THEN
    Out.String("Error: Cannot open file "); Out.String(filename); Out.Ln;
    RETURN
  END;

  rec.seq := NIL;
  WHILE BioIO.ReadFasta(reader, rec) DO
    ProcessSeq(rec.name, rec.seq)
  END;

  BioIO.CloseFasta(reader)
END ChuFasman.
