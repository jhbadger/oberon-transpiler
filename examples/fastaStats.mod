MODULE FastaStats;

IMPORT BioIO, BioSeq, Out, Args, Strings;

VAR
    total_size:     INTEGER;
    num_sequences:  INTEGER;
    min_size:       INTEGER;
    max_size:       INTEGER;
    total_gc_count: INTEGER;
    min_gc_percent: REAL;
    max_gc_percent: REAL;
    is_nucl:        BOOLEAN;   (* detected from first sequence *)
    type_known:     BOOLEAN;

PROCEDURE IsNucleotide(seq: BioSeq.Seq): BOOLEAN;
VAR total, nucl: INTEGER;
BEGIN
    total := BioSeq.Length(seq);
    IF total = 0 THEN RETURN TRUE END;
    nucl := BioSeq.Count(seq, 'A') + BioSeq.Count(seq, 'T') +
            BioSeq.Count(seq, 'G') + BioSeq.Count(seq, 'C') +
            BioSeq.Count(seq, 'U') + BioSeq.Count(seq, 'N') +
            BioSeq.Count(seq, 'a') + BioSeq.Count(seq, 't') +
            BioSeq.Count(seq, 'g') + BioSeq.Count(seq, 'c') +
            BioSeq.Count(seq, 'u') + BioSeq.Count(seq, 'n');
    RETURN (FLT(nucl) / FLT(total)) > 0.85
END IsNucleotide;

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

    IF is_nucl THEN
        IF size > 0 THEN
            current_gc_percent := (FLT(gc_count) / FLT(size)) * 100.0
        ELSE
            current_gc_percent := 0.0
        END;
        IF current_gc_percent < min_gc_percent THEN min_gc_percent := current_gc_percent END;
        IF current_gc_percent > max_gc_percent THEN max_gc_percent := current_gc_percent END
    END
END UpdateStats;

PROCEDURE ProcessFasta(VAR filename: ARRAY OF CHAR; summary: BOOLEAN);
VAR
    rdr:      BioIO.FastaReader;
    rec:      BioIO.FastaRecord;
    gc_count: INTEGER;
    size:     INTEGER;
    gc_pct:   REAL;
    unit:     ARRAY 9 OF CHAR;
BEGIN
    total_size     := 0;
    num_sequences  := 0;
    min_size       := 1500000000;
    max_size       := 0;
    total_gc_count := 0;
    min_gc_percent := 101.0;
    max_gc_percent := 0.0;
    type_known     := FALSE;

    IF ~BioIO.OpenFasta(rdr, filename) THEN
        Out.String("Error: Could not open file: "); Out.String(filename); Out.Ln;
        RETURN
    END;

    rec.seq := NIL;
    WHILE BioIO.ReadFasta(rdr, rec) DO
        IF ~type_known THEN
            is_nucl    := IsNucleotide(rec.seq);
            type_known := TRUE;
            IF ~summary THEN
                Out.String("name"); Out.Char(9H);
                IF is_nucl THEN
                    Out.String("length"); Out.Char(9H);
                    Out.String("gc_percent")
                ELSE
                    Out.String("residues")
                END;
                Out.Ln
            END
        END;

        size     := BioSeq.Length(rec.seq);
        gc_count := 0;
        IF is_nucl THEN
            gc_count := BioSeq.Count(rec.seq, 'G') + BioSeq.Count(rec.seq, 'C') +
                        BioSeq.Count(rec.seq, 'g') + BioSeq.Count(rec.seq, 'c')
        END;
        UpdateStats(size, gc_count);

        IF ~summary THEN
            Out.String(rec.name); Out.Char(9H);
            Out.Int(size, 0);
            IF is_nucl THEN
                IF size > 0 THEN
                    gc_pct := (FLT(gc_count) / FLT(size)) * 100.0
                ELSE
                    gc_pct := 0.0
                END;
                Out.Char(9H);
                Out.Fixed(gc_pct, 0, 2)
            END;
            Out.Ln
        END
    END;

    BioIO.CloseFasta(rdr)
END ProcessFasta;

PROCEDURE OutputSummary();
    VAR avg_size: REAL; avg_gc: REAL; unit: ARRAY 9 OF CHAR;
BEGIN
    IF num_sequences = 0 THEN
        Out.String("No sequences found in the input file."); Out.Ln;
        RETURN
    END;

    IF is_nucl THEN unit := "Bases" ELSE unit := "Residues" END;

    avg_size := FLT(total_size) / FLT(num_sequences);

    Out.String("=========================================="); Out.Ln;
    Out.String("FASTA File Analysis Statistics");           Out.Ln;
    Out.String("=========================================="); Out.Ln;

    Out.String("Total Sequences Processed: "); Out.Int(num_sequences, 0); Out.Ln;
    Out.String("Total "); Out.String(unit); Out.String(" Counted:      ");
    Out.Int(total_size, 0); Out.Ln;
    Out.String("------------------------------------------"); Out.Ln;

    Out.String("Sequence Length ("); Out.String(unit); Out.String("):"); Out.Ln;
    Out.String("  Average:  "); Out.Fixed(avg_size, 0, 2); Out.Ln;
    Out.String("  Minimum:  "); Out.Int(min_size, 0);      Out.Ln;
    Out.String("  Maximum:  "); Out.Int(max_size, 0);      Out.Ln;

    IF is_nucl THEN
        avg_gc := (FLT(total_gc_count) / FLT(total_size)) * 100.0;
        Out.Ln;
        Out.String("GC Content (%GC):"); Out.Ln;
        Out.String("  Average:  "); Out.Fixed(avg_gc, 0, 2);         Out.Ln;
        Out.String("  Minimum:  "); Out.Fixed(min_gc_percent, 0, 2); Out.Ln;
        Out.String("  Maximum:  "); Out.Fixed(max_gc_percent, 0, 2); Out.Ln
    END
END OutputSummary;

VAR
    filename: ARRAY 1024 OF CHAR;
    arg:      ARRAY 64 OF CHAR;
    summary:  BOOLEAN;
    i:        INTEGER;
BEGIN
    summary  := FALSE;
    filename := "";

    i := 1;
    WHILE i <= Args.Count() DO
        Args.Get(i, arg);
        IF Strings.Compare(arg, "-t") = 0 THEN
            summary := TRUE
        ELSE
            COPY(arg, filename)
        END;
        INC(i)
    END;

    IF filename = "" THEN
        Out.String("Usage: FastaStats [-t] <input_fasta_file>"); Out.Ln;
        Out.String("  -t   print summary statistics instead of per-sequence TSV"); Out.Ln
    ELSE
        ProcessFasta(filename, summary);
        IF summary THEN OutputSummary() END
    END
END FastaStats.
