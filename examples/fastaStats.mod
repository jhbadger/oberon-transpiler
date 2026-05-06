MODULE FastaStats;

IMPORT Out, Files, Args;

CONST
    LineBufferSize = 4096;
    SeqBufSize     = 1000000;

(* --- Global/Accumulator Variables --- *)

VAR
    total_size:     INTEGER;
    num_sequences:  INTEGER;
    min_size:       INTEGER;
    max_size:       INTEGER;
    total_gc_count: INTEGER;
    min_gc_percent: REAL;
    max_gc_percent: REAL;

    (* FIX 7: moved off the stack to avoid stack overflow *)
    current_sequence_buffer: ARRAY SeqBufSize OF CHAR;

(* --- Helper Procedures --- *)

PROCEDURE CalculateStats(VAR sequence_buffer: ARRAY OF CHAR;
                         VAR current_size: INTEGER;
                         VAR current_gc_count: INTEGER);
    VAR i: INTEGER; c: CHAR;
BEGIN
    current_size     := 0;
    current_gc_count := 0;
    i := 0;
    WHILE (i < LEN(sequence_buffer)) & (sequence_buffer[i] # 0X) DO
        c := sequence_buffer[i];
        IF (c = 'A') OR (c = 'T') OR (c = 'C') OR (c = 'G') THEN
            INC(current_size);
            IF (c = 'G') OR (c = 'C') THEN
                INC(current_gc_count)
            END
        END;
        INC(i)
    END
END CalculateStats;

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

PROCEDURE ProcessStats(bufLen: INTEGER;
                       VAR size: INTEGER;
                       VAR gc: INTEGER);
BEGIN
    IF bufLen > 0 THEN
        CalculateStats(current_sequence_buffer, size, gc);
        UpdateStats(size, gc)
    END
END ProcessStats;

PROCEDURE AppendLineToBuffer(VAR dst: ARRAY OF CHAR; offset: INTEGER;
                             VAR src_line: ARRAY OF CHAR): INTEGER;
    VAR i: INTEGER;
BEGIN
    i := 0;
    WHILE (i < LEN(src_line)) & (src_line[i] # 0X) &
          (offset + i < LEN(dst) - 1) DO
        dst[offset + i] := src_line[i];
        INC(i)   
    END;
    dst[offset + i] := 0X;   (* keep buffer null-terminated *)
    RETURN offset + i
END AppendLineToBuffer;

PROCEDURE ProcessFastaFile(VAR filename: ARRAY OF CHAR);
VAR
    f:              Files.File;
    r:              Files.Rider;   
    line:           ARRAY LineBufferSize OF CHAR;
    buf_offset:     INTEGER;
    sequence_length: INTEGER;
    gc_count:       INTEGER;
    in_sequence_block: BOOLEAN;
BEGIN
    total_size     := 0;
    num_sequences  := 0;
    min_size       := 1500000;
    max_size       := 0;
    total_gc_count := 0;
    min_gc_percent := 101.0;
    max_gc_percent := 0.0;

    f := Files.Old(filename);
    IF f = NIL THEN
        Out.String("Error: Could not open file: "); Out.String(filename); Out.Ln;
        RETURN
    END;

    current_sequence_buffer[0] := 0X;
    buf_offset        := 0;
    sequence_length   := 0;
    gc_count          := 0;
    in_sequence_block := FALSE;

    Files.Set(r, f, 0);

    WHILE ~r.eof DO
        Files.ReadLine(r, line);

        (* ReadLine sets r.eof when no characters were available;
           skip processing the empty sentinel read *)
        IF ~r.eof OR (line[0] # 0X) THEN

            IF line[0] = '>' THEN
                IF in_sequence_block THEN
                    ProcessStats(buf_offset, sequence_length, gc_count)
                END;

                current_sequence_buffer[0] := 0X;
                buf_offset        := 0;
                sequence_length   := 0;
                gc_count          := 0;
                in_sequence_block := TRUE
            ELSIF in_sequence_block THEN
                buf_offset := AppendLineToBuffer(current_sequence_buffer,
                                                 buf_offset, line);
                sequence_length := buf_offset
            END
        END
    END;

    (* Flush the final sequence *)
    IF in_sequence_block THEN
        ProcessStats(buf_offset, sequence_length, gc_count)
    END;

    Files.Close(f)
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

