MODULE RecordTest;
TYPE
    Point = RECORD
        x: INTEGER;
        y: INTEGER
    END;
VAR
    p: Point;
BEGIN
    p.x := 10;
    p.y := 20;
    Write("Point X is: ");
    Write(p.x);
END RecordTest.