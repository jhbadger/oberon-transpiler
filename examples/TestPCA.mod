MODULE TestPCA;

IMPORT DataFrame, DataFramePCA, Out;

VAR
  df: DataFrame.DataFrame;
  err: INTEGER;
  featureSet: SET;

BEGIN
  (* Load the data *)
  df := DataFrame.LoadTSV("iris.txt", TRUE, err);
  IF err # DataFrame.OK THEN
    Out.String("Error: Failed to load 'iris.txt'."); Out.Ln;
    HALT(1);
  END;

  (* Define which columns are features (0-3) for the PCA *)
  featureSet := {0, 1, 2, 3};

  (*
   * Execute a 2D PCA on the DataFrame.
   * - df: The loaded data.
   * - featureSet: The set of columns to analyze.
   * - 4: The column index for the label (Species).
   * - 2: The number of principal components to compute (k).
   *)
  Out.String("--- PCA Results for Iris Dataset (2 Components) ---"); Out.Ln;
  DataFramePCA.Execute(df, featureSet, 4, 2);

END TestPCA.
