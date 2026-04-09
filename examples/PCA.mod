MODULE PCA;
(*
 * Generalized Principal Component Analysis (PCA) for any DataFrame.
 *
 * This module performs PCA for a specified number of components (k) on
 * a given DataFrame. It uses dynamic memory allocation to handle any
 * number of features and rows.
 *)

IMPORT Out, Strings, Math, DataFrame;

CONST
  N_ITER = 30; (* Iterations for Power Iteration convergence *)

TYPE
  (* Dynamic types for matrices and vectors *)
  Vector    = POINTER TO ARRAY OF REAL;
  Matrix    = POINTER TO ARRAY OF ARRAY OF REAL;
  VectorSet = POINTER TO ARRAY OF Vector; (* For storing eigenvectors *)

(* --- Dynamic Vector & Matrix Helper Procedures --- *)

PROCEDURE Dot(v1, v2: Vector; n: INTEGER): REAL;
VAR i: INTEGER; res: REAL;
BEGIN
  res := 0.0;
  FOR i := 0 TO n - 1 DO res := res + v1[i] * v2[i] END;
  RETURN res
END Dot;

PROCEDURE Norm(v: Vector; n: INTEGER): REAL;
BEGIN
  RETURN Math.sqrt(Dot(v, v, n))
END Norm;

PROCEDURE Normalize(v: Vector; n: INTEGER);
VAR i: INTEGER; normVal: REAL;
BEGIN
  normVal := Norm(v, n);
  IF normVal > 0.0 THEN
    FOR i := 0 TO n - 1 DO v[i] := v[i] / normVal END
  END
END Normalize;

PROCEDURE MatVecMul(m: Matrix; v: Vector; n: INTEGER; VAR res: Vector);
VAR i, j: INTEGER;
BEGIN
  FOR i := 0 TO n - 1 DO
    res[i] := 0.0;
    FOR j := 0 TO n - 1 DO
      res[i] := res[i] + m[i][j] * v[j]
    END
  END
END MatVecMul;

PROCEDURE OuterProduct(v1, v2: Vector; n: INTEGER; VAR res: Matrix);
VAR i, j: INTEGER;
BEGIN
  FOR i := 0 TO n - 1 DO
    FOR j := 0 TO n - 1 DO
      res[i][j] := v1[i] * v2[j]
    END
  END
END OuterProduct;

(* --- PCA Step Procedures --- *)

PROCEDURE StandardizeData(df: DataFrame.DataFrame; featureCols: SET; VAR data: Matrix; VAR nRows, nFeat: INTEGER);
VAR
  r, c, i: INTEGER;
  val, sum, sumSq, mean, stddev: REAL;
  means, stddevs: Vector;
BEGIN
  nRows := DataFrame.NRows(df);
  nFeat := 0;
  FOR c := 0 TO DataFrame.MAXCOLS - 1 DO
    IF c IN featureCols THEN INCL(nFeat) END
  END;

  NEW(means, nFeat); NEW(stddevs, nFeat);
  NEW(data, nRows); FOR r := 0 TO nRows - 1 DO NEW(data[r], nFeat) END;

  i := 0;
  FOR c := 0 TO DataFrame.MAXCOLS - 1 DO
    IF c IN featureCols THEN
      sum := 0.0; sumSq := 0.0;
      FOR r := 0 TO nRows - 1 DO
        DataFrame.GetReal(df, r, c, val);
        sum := sum + val;
        sumSq := sumSq + val * val;
      END;
      mean := sum / nRows;
      stddev := Math.sqrt(sumSq / nRows - mean * mean);
      means[i] := mean;
      stddevs[i] := stddev;
      INC(i);
    END;
  END;

  i := 0;
  FOR c := 0 TO DataFrame.MAXCOLS - 1 DO
    IF c IN featureCols THEN
      FOR r := 0 TO nRows - 1 DO
        DataFrame.GetReal(df, r, c, val);
        IF stddevs[i] > 0 THEN
          data[r][i] := (val - means[i]) / stddevs[i]
        ELSE
          data[r][i] := 0.0
        END
      END;
      INC(i);
    END
  END;
END StandardizeData;

PROCEDURE CovarianceMatrix(data: Matrix; nRows, nFeat: INTEGER; VAR cov: Matrix);
VAR i, j, r: INTEGER; sum: REAL;
BEGIN
  NEW(cov, nFeat); FOR i := 0 TO nFeat - 1 DO NEW(cov[i], nFeat) END;

  FOR i := 0 TO nFeat - 1 DO
    FOR j := i TO nFeat - 1 DO
      sum := 0.0;
      FOR r := 0 TO nRows - 1 DO
        sum := sum + data[r][i] * data[r][j];
      END;
      cov[i][j] := sum / (nRows - 1);
      cov[j][i] := cov[i][j];
    END
  END
END CovarianceMatrix;

PROCEDURE PowerIteration(cov: Matrix; n: INTEGER; VAR eigVec: Vector);
VAR iter: INTEGER;
BEGIN
  NEW(eigVec, n);
  FOR iter := 0 TO n - 1 DO eigVec[iter] := 1.0 END;

  FOR iter := 0 TO N_ITER - 1 DO
    MatVecMul(cov, eigVec, n, eigVec);
    Normalize(eigVec, n);
  END
END PowerIteration;

PROCEDURE Project(data: Matrix; eigVecs: VectorSet; nRows, nFeat, k: INTEGER; VAR projected: Matrix);
VAR r, c, i: INTEGER;
BEGIN
  NEW(projected, nRows); FOR r := 0 TO nRows - 1 DO NEW(projected[r], k) END;

  FOR r := 0 TO nRows - 1 DO
    FOR c := 0 TO k - 1 DO
      projected[r][c] := 0.0;
      FOR i := 0 TO nFeat - 1 DO
        projected[r][c] := projected[r][c] + data[r][i] * eigVecs[c][i];
      END
    END
  END
END Project;

(* --- Main Public Procedure --- *)

PROCEDURE Execute*(df: DataFrame.DataFrame; featureCols: SET; labelCol: INTEGER; k: INTEGER);
VAR
  nRows, nFeat, i, j, r: INTEGER;
  data, cov, tmpMat, projected: Matrix;
  eigVecs: VectorSet;
  tmpVec: Vector;
  lambda: REAL;
  label: ARRAY DataFrame.CELLLEN OF CHAR;
BEGIN
  StandardizeData(df, featureCols, data, nRows, nFeat);
  CovarianceMatrix(data, nRows, nFeat, cov);

  NEW(eigVecs, k);
  NEW(tmpMat, nFeat); FOR i := 0 TO nFeat - 1 DO NEW(tmpMat[i], nFeat) END;
  NEW(tmpVec, nFeat);

  (* Sequentially find k eigenvectors *)
  FOR i := 0 TO k - 1 DO
    PowerIteration(cov, eigVecs[i], nFeat);

    (* Deflate matrix: C' = C - lambda*v*v' *)
    MatVecMul(cov, eigVecs[i], nFeat, tmpVec);
    lambda := Dot(eigVecs[i], tmpVec, nFeat);
    OuterProduct(eigVecs[i], eigVecs[i], nFeat, tmpMat);

    FOR r := 0 TO nFeat - 1 DO
      FOR j := 0 TO nFeat - 1 DO
        cov[r][j] := cov[r][j] - lambda * tmpMat[r][j]
      END
    END;
  END;

  Project(data, eigVecs, nRows, nFeat, k, projected);

  (* Print results *)
  FOR i := 1 TO k DO
    Out.String("PC"); Out.Int(i, 0); Out.Char(',');
  END;
  Out.String("Label"); Out.Ln;

  FOR r := 0 TO nRows - 1 DO
    FOR i := 0 TO k - 1 DO
      Out.Real(projected[r][i]); Out.Char(',');
    END;
    DataFrame.GetStr(df, r, labelCol, label);
    Out.String(label);
    Out.Ln;
  END;
END Execute;

END PCA.
