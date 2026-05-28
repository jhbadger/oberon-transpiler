MODULE FastaStats;

IMPORT BioIO, BioSeq, Out, Args;

VAR
    total_size:     INTEGER;
    num_sequences:  INTEGER;
    min_size:       INTEGER;
    max_size:       INTEGER;
    total_gc_count: INTEGER;
    min_gc_percent: REAL;
    max_gc_percent: REAL;

PROCEDURE UpdateStats(size: INTEGER; gc_count: INTEGER);
    VAR current_gc_percent: REAL;
BEGIN
    INC(total_size, size);
    INC(num_sequences);
    INC(total_gc_count, gc_count);

    IF num_sequences = 1 THEN
        min_size       := size;
        max_size       := size;
        min_gc_percent := 101.0;
        max_gc_percent := 0.0
    END;

    IF size <= min_size THEN min_size := size END;
    IF size > max_size  THEN max_size := size END;

    IF size > 0 THEN
        current_gc_percent := (FLT(gc_count) / FLT(size)) * 100.0
    ELSE
        current_gc_percent := 0.0
    END;

    IF current_gc_percent < min_gc_percent THEN min_gc_percent := current_gc_percent END;
    IF current_gc_percent > max_gc_percent THEN max_gc_percent := current_gc_percent END
END UpdateStats;

PROCEDURE ProcessFastaFile(VAR filename: ARRAY OF CHAR);
VAR
    rdr:      BioIO.FastaReader;
    rec:      BioIO.FastaRecord;
    gc_count: INTEGER;
    size:     INTEGER;
BEGIN
    total_size     := 0;
    num_sequences  := 0;
    min_size       := 1500000;
    max_size       := 0;
    total_gc_count := 0;
    min_gc_percent := 101.0;
    max_gc_percent := 0.0;

    IF ~BioIO.OpenFasta(rdr, filename) THEN
        Out.String("Error: Could not open file: "); Out.String(filename); Out.Ln;
        RETURN
    END;

    rec.seq := NIL;
    WHILE BioIO.ReadFasta(rdr, rec) DO
        size     := BioSeq.Length(rec.seq);
        gc_count := BioSeq.Count(rec.seq, 'G') + BioSeq.Count(rec.seq, 'C') +
                    BioSeq.Count(rec.seq, 'g') + BioSeq.Count(rec.seq, 'c');
        UpdateStats(size, gc_count)
    END;

    BioIO.CloseFasta(rdr)
END ProcessFastaFile;

PROCEDURE OutputResults();
    VAR avg_size: REAL; avg_gc: REAL;
BEGIN
    IF num_sequences = 0 THEN
        Out.String("No sequences found in the input file."); Out.Ln;
        RETURN
    END;

    avg_size := FLT(total_size) / FLT(num_sequences);
    avg_gc   := (FLT(total_gc_count) / FLT(total_size)) * 100.0;

    Out.String("=========================================="); Out.Ln;
    Out.String("FASTA File Analysis Statistics");           Out.Ln;
    Out.String("=========================================="); Out.Ln;

    Out.String("Total Sequences Processed: "); Out.Int(num_sequences, 0); Out.Ln;
    Out.String("Total Bases Counted:       "); Out.Int(total_size, 0);    Out.Ln;
    Out.String("------------------------------------------"); Out.Ln;

    Out.String("Sequence Length (Bases):"); Out.Ln;
    Out.String("  Average:  "); Out.Real(avg_size);       Out.Ln;
    Out.String("  Minimum:  "); Out.Int(min_size, 0);     Out.Ln;
    Out.String("  Maximum:  "); Out.Int(max_size, 0);     Out.Ln;
    Out.Ln;

    Out.String("GC Content (%GC):"); Out.Ln;
    Out.String("  Average:  "); Out.Real(avg_gc);          Out.Ln;
    Out.String("  Minimum:  "); Out.Real(min_gc_percent);  Out.Ln;
    Out.String("  Maximum:  "); Out.Real(max_gc_percent);  Out.Ln
END OutputResults;

VAR filename: ARRAY 1024 OF CHAR;
BEGIN
    IF Args.Count() < 1 THEN
        Out.String("Usage: FastaStats <input_fasta_file>"); Out.Ln;
        Out.String("Example: FastaStats data.fasta");       Out.Ln
    ELSE
        Args.Get(1, filename);
        ProcessFastaFile(filename);
        OutputResults()
    END
END FastaStats.
