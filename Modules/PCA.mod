MODULE PCA;
(*
 * Principal Component Analysis using Power Iteration with Deflation.
 * Uses fixed-size arrays (no dynamic allocation) for transpiler compatibility.
 *)

IMPORT Out, Math, DataFrame;

CONST
  MAXFEAT   = 64;
  MAXK      = 16;
  PCA_MAXROWS = 1024;
  N_ITER    = 50;

TYPE
  Vec  = ARRAY MAXFEAT OF REAL;
  Mat  = ARRAY MAXFEAT OF ARRAY MAXFEAT OF REAL;

VAR
  (* Module-level scratch storage *)
  sData  : ARRAY PCA_MAXROWS OF Vec;
  cov    : Mat;
  tmpMat : Mat;
  tmpVec : Vec;
  means  : Vec;
  stdevs : Vec;
  eigV   : ARRAY MAXK OF Vec;
  proj   : ARRAY PCA_MAXROWS OF ARRAY MAXK OF REAL;

PROCEDURE DotVec(VAR v1, v2: Vec; n: INTEGER): REAL;
VAR i: INTEGER; s: REAL;
BEGIN
  s := 0.0;
  FOR i := 0 TO n - 1 DO s := s + v1[i] * v2[i] END;
  RETURN s
END DotVec;

PROCEDURE NormalizeVec(VAR v: Vec; n: INTEGER);
VAR i: INTEGER; nv: REAL;
BEGIN
  nv := Math.sqrt(DotVec(v, v, n));
  IF nv > 0.0 THEN
    FOR i := 0 TO n - 1 DO v[i] := v[i] / nv END
  END
END NormalizeVec;

PROCEDURE MatVecMul(VAR m: Mat; VAR v, res: Vec; n: INTEGER);
VAR i, j: INTEGER;
BEGIN
  FOR i := 0 TO n - 1 DO
    res[i] := 0.0;
    FOR j := 0 TO n - 1 DO
      res[i] := res[i] + m[i][j] * v[j]
    END
  END
END MatVecMul;

PROCEDURE Standardize(df: DataFrame.DataFrame; featureCols: SET; VAR nRows, nFeat: INTEGER);
VAR r, c, i: INTEGER; val, sum, sumSq, mean, sd: REAL;
BEGIN
  nRows := DataFrame.NRows(df);
  nFeat := 0;
  FOR c := 0 TO DataFrame.MAXCOLS - 1 DO
    IF c IN featureCols THEN INC(nFeat) END
  END;

  (* Compute means and stddevs *)
  i := 0;
  FOR c := 0 TO DataFrame.MAXCOLS - 1 DO
    IF c IN featureCols THEN
      sum := 0.0; sumSq := 0.0;
      FOR r := 0 TO nRows - 1 DO
        DataFrame.GetReal(df, r, c, val);
        sum   := sum   + val;
        sumSq := sumSq + val * val
      END;
      mean := sum / nRows;
      sd   := Math.sqrt(sumSq / nRows - mean * mean);
      means[i]  := mean;
      stdevs[i] := sd;
      INC(i)
    END
  END;

  (* Fill sData with standardized values *)
  i := 0;
  FOR c := 0 TO DataFrame.MAXCOLS - 1 DO
    IF c IN featureCols THEN
      FOR r := 0 TO nRows - 1 DO
        DataFrame.GetReal(df, r, c, val);
        IF stdevs[i] > 0.0 THEN
          sData[r][i] := (val - means[i]) / stdevs[i]
        ELSE
          sData[r][i] := 0.0
        END
      END;
      INC(i)
    END
  END
END Standardize;

PROCEDURE Covariance(nRows, nFeat: INTEGER);
VAR i, j, r: INTEGER; sum: REAL;
BEGIN
  FOR i := 0 TO nFeat - 1 DO
    FOR j := i TO nFeat - 1 DO
      sum := 0.0;
      FOR r := 0 TO nRows - 1 DO
        sum := sum + sData[r][i] * sData[r][j]
      END;
      cov[i][j] := sum / (nRows - 1);
      cov[j][i] := cov[i][j]
    END
  END
END Covariance;

PROCEDURE PowerIter(VAR ev: Vec; nFeat: INTEGER);
VAR iter, f: INTEGER;
BEGIN
  FOR f := 0 TO nFeat - 1 DO ev[f] := 1.0 END;
  FOR iter := 0 TO N_ITER - 1 DO
    MatVecMul(cov, ev, tmpVec, nFeat);
    FOR f := 0 TO nFeat - 1 DO ev[f] := tmpVec[f] END;
    NormalizeVec(ev, nFeat)
  END
END PowerIter;

PROCEDURE Deflate(VAR ev: Vec; nFeat: INTEGER);
VAR i, j: INTEGER; lambda: REAL;
BEGIN
  MatVecMul(cov, ev, tmpVec, nFeat);
  lambda := DotVec(ev, tmpVec, nFeat);
  FOR i := 0 TO nFeat - 1 DO
    FOR j := 0 TO nFeat - 1 DO
      tmpMat[i][j] := ev[i] * ev[j]
    END
  END;
  FOR i := 0 TO nFeat - 1 DO
    FOR j := 0 TO nFeat - 1 DO
      cov[i][j] := cov[i][j] - lambda * tmpMat[i][j]
    END
  END
END Deflate;

PROCEDURE Execute*(df: DataFrame.DataFrame; featureCols: SET; labelCol, k: INTEGER);
VAR
  nRows, nFeat, i, j, r: INTEGER;
  label: ARRAY DataFrame.CELLLEN OF CHAR;
BEGIN
  Standardize(df, featureCols, nRows, nFeat);
  Covariance(nRows, nFeat);

  FOR i := 0 TO k - 1 DO
    PowerIter(eigV[i], nFeat);
    Deflate(eigV[i], nFeat)
  END;

  (* Project *)
  FOR r := 0 TO nRows - 1 DO
    FOR i := 0 TO k - 1 DO
      proj[r][i] := 0.0;
      FOR j := 0 TO nFeat - 1 DO
        proj[r][i] := proj[r][i] + sData[r][j] * eigV[i][j]
      END
    END
  END;

  (* Header *)
  FOR i := 1 TO k DO
    Out.String("PC"); Out.Int(i, 0); Out.Char(',')
  END;
  Out.String("Label"); Out.Ln;

  (* Rows *)
  FOR r := 0 TO nRows - 1 DO
    FOR i := 0 TO k - 1 DO
      Out.Real(proj[r][i]); Out.Char(',')
    END;
    DataFrame.GetStr(df, r, labelCol, label);
    Out.String(label); Out.Ln
  END
END Execute;

END PCA.
