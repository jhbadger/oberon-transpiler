MODULE Easter;

IMPORT Args, Strings, Out;

TYPE
Date = RECORD
  day, month, year: INTEGER
END;

PROCEDURE EasterDate (year: INTEGER; VAR easter: Date);
	(*Gives the western Easter date of a year between 1583 and 2299 (Gregorian calender).
After an algorithm by C.F. Gauss (1816).*)
		VAR
			a, b, c, d, e: INTEGER;
			M, N: INTEGER;
			marchDay, aprilDay: INTEGER;
	BEGIN
		ASSERT((year > 1582) & (year < 2300));
		a := year MOD 19;
		b := year MOD 4;
		c := year MOD 7;
		IF (year >= 1583) & (year <= 1699) THEN
			M := 22;  N := 2;
		ELSIF (year >= 1700) & (year <= 1799) THEN
			M := 23;  N := 3;
		ELSIF (year >= 1800) & (year <= 1899) THEN
			M := 23;  N := 4;
		ELSIF (year >= 1900) & (year <= 2099) THEN
			M := 24;  N := 5;
		ELSIF (year >= 2100) & (year <= 2199) THEN
			M := 24;  N := 6;
		ELSIF (year >= 2200) & (year <= 2299) THEN
			M := 25;  N := 7
		END;
		d := (19*a + M) MOD 30;
		e := (2*b + 4*c + 6*d + N) MOD 7;
		marchDay := 22 + d + e;
		aprilDay := d + e - 9;
		IF aprilDay = 26 THEN aprilDay := 19 END;
		IF (aprilDay = 25) & ((d = 28) & (a > 10)) THEN aprilDay := 18 END;
		easter.year := year;
		IF marchDay <= 31 THEN
			easter.month := 3;
			easter.day := marchDay
		ELSE
			easter.month := 4;
			easter.day := aprilDay
		END
	END EasterDate;
	
VAR d: Date;
    year: INTEGER;
    arg: ARRAY 10 OF CHAR;
    	
BEGIN
  Args.Get(1, arg);
  IF Args.Count() < 1 OR ~Strings.StrToInt(arg, year) THEN
    Out.String("easter: year"); Out.Ln;
  ELSE 
    EasterDate(year, d);
    Out.String("Easter "); Out.Int(year);
    Out.String(" is on Sunday, ");
    IF d.month = 3 THEN
      Out.String("March "); 
    ELSE
      Out.String("April ");
    END;
    Out.Int(d.day);
    Out.Ln;
  END; 
END Easter.