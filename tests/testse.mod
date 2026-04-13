MODULE TestSE;

IMPORT SummarizedExperiment, Out;

VAR
  se: SummarizedExperiment.SE;
  err: INTEGER;
  x: REAL;
  s: ARRAY 64 OF CHAR;

BEGIN
  se := SummarizedExperiment.Create(3, 2, err);

  SummarizedExperiment.AddAssay(se, "counts", err);
  SummarizedExperiment.AddAssay(se, "logcounts", err);

  SummarizedExperiment.SetAssayByName(se, "counts", 0, 0, 10.0, err);
  SummarizedExperiment.SetAssayByName(se, "counts", 0, 1, 12.0, err);
  SummarizedExperiment.SetAssayByName(se, "counts", 1, 0, 3.0, err);

  SummarizedExperiment.AddRowDataCol(se, "gene_id", err);
  SummarizedExperiment.AddColDataCol(se, "condition", err);

  SummarizedExperiment.SetRowDataStr(se, 0, "gene_id", "ENSG0001", err);
  SummarizedExperiment.SetRowDataStr(se, 1, "gene_id", "ENSG0002", err);

  SummarizedExperiment.SetColDataStr(se, 0, "condition", "ctrl", err);
  SummarizedExperiment.SetColDataStr(se, 1, "condition", "stim", err);

  SummarizedExperiment.SetRowName(se, 0, "GeneA", err);
  SummarizedExperiment.SetRowName(se, 1, "GeneB", err);
  SummarizedExperiment.SetColName(se, 0, "Sample1", err);
  SummarizedExperiment.SetColName(se, 1, "Sample2", err);

  SummarizedExperiment.MetadataPut(se, "organism", "human", err);

  SummarizedExperiment.Info(se);

  SummarizedExperiment.GetAssayByName(se, "counts", 0, 1, x, err);
  Out.String("counts[0,1] = "); Out.Real(x); Out.Ln;

  SummarizedExperiment.RowName(se, 0, s);
  Out.String("row 0 name = "); Out.String(s); Out.Ln
END TestSE.
