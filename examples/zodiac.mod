MODULE Zodiac;
  IMPORT Out;

  PROCEDURE DetermineZodiac(year: INTEGER);
    VAR
      animalIdx: INTEGER;
      elementIdx: INTEGER;
      yinYangIdx: INTEGER;
      animals: ARRAY 12 OF STRING;
      elements: ARRAY 5 OF STRING;
      
  BEGIN
    (* Initialize Animals *)
    animals[0] := "Rat";     animals[1] := "Ox";
    animals[2] := "Tiger"; animals[3] := "Rabbit";
    animals[4] := "Dragon"; animals[5] := "Snake";
    animals[6] := "Horse";   animals[7] := "Goat";
    animals[8] := "Monkey"; animals[9] := "Rooster";
    animals[10] := "Dog";   animals[11] := "Pig";

    (* Initialize Elements *)
    elements[0] := "Wood"; elements[1] := "Fire";
    elements[2] := "Earth"; elements[3] := "Metal";
    elements[4] := "Water";

    animalIdx := (year - 4) MOD 12;
    elementIdx := ((year - 4) MOD 10) DIV 2;
    yinYangIdx := year MOD 2;

    Out.Int(year, 0);
    Out.String(" is the year of the ");
    Out.String(elements[elementIdx]);
    Out.Char(" ");
    Out.String(animals[animalIdx]);
    Out.String(" (");

    IF yinYangIdx = 0 THEN
      Out.String("yang")
    ELSE
      Out.String("yin")
    END;

    Out.String("). ");
    Out.Ln;
  END DetermineZodiac;

VAR
  year: INTEGER;
  
BEGIN
  FOR year := 1936 TO 2036 DO
    DetermineZodiac(year);
  END;
END Zodiac.
