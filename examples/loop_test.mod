MODULE loop_test;
VAR
    i : INTEGER;
BEGIN
    i := 1;
    WHILE i < 6 DO
        Write("Iteration: ");
        Write(i);
        IF i = 3 THEN
            Write("Three is the magic number!");
        END;
        i := i + 1;
    END;
END loop_test.