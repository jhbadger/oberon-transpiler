MODULE TestPCA;

IMPORT DataFrame, PCA, Out;

VAR
  df: DataFrame.DataFrame;
  err: INTEGER;
  featureSet: SET;

BEGIN
  df := DataFrame.LoadTSV("iris.txt", TRUE, err);
  IF err # DataFrame.OK THEN
    Out.String("Error: Failed to load 'iris.txt'."); Out.Ln;
    HALT(1)
  END;

  featureSet := {0, 1, 2, 3};

  Out.String("--- PCA Results for Iris Dataset (2 Components) ---"); Out.Ln;
  PCA.Execute(df, featureSet, 4, 2)

END TestPCA.
