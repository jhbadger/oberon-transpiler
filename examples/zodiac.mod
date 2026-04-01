MODULE Zodiac;
  IMPORT Out;

  PROCEDURE DetermineZodiac(year: INTEGER);
    VAR
      animalIdx: INTEGER;
      elementIdx: INTEGER;
      yinYangIdx: INTEGER;

      animals: ARRAY 12, 10 OF CHAR;
      elements: ARRAY 5, 10 OF CHAR;
      compatible: ARRAY 12, 20 OF CHAR;
      incompatible: ARRAY 12, 10 OF CHAR;
      
  BEGIN
    (* Initialize Animals *)
    animals[0] := "Rat";     animals[1] := "Ox";
    animals[2] := "Tiger";   animals[3] := "Rabbit";
    animals[4] := "Dragon";  animals[5] := "Snake";
    animals[6] := "Horse";   animals[7] := "Goat";
    animals[8] := "Monkey";  animals[9] := "Rooster";
    animals[10] := "Dog";    animals[11] := "Pig";

    (* Initialize Elements *)
    elements[0] := "Wood";   elements[1] := "Fire";
    elements[2] := "Earth";  elements[3] := "Metal";
    elements[4] := "Water";

    (* Initialize Compatibility (The 4 Trines) *)
    compatible[0] := "Dragon, Monkey"; (* Rat *)
    compatible[1] := "Snake, Rooster"; (* Ox *)
    compatible[2] := "Horse, Dog";    (* Tiger *)
    compatible[3] := "Goat, Pig";      (* Rabbit *)
    compatible[4] := "Rat, Monkey";    (* Dragon *)
    compatible[5] := "Ox, Rooster";    (* Snake *)
    compatible[6] := "Tiger, Dog";     (* Horse *)
    compatible[7] := "Rabbit, Pig";    (* Goat *)
    compatible[8] := "Rat, Dragon";    (* Monkey *)
    compatible[9] := "Ox, Snake";      (* Rooster *)
    compatible[10] := "Tiger, Horse";  (* Dog *)
    compatible[11] := "Rabbit, Goat";  (* Pig *)

    (* Initialize Incompatibility (The 6 Clashes) *)
    incompatible[0] := "Horse";   incompatible[1] := "Goat";
    incompatible[2] := "Monkey";  incompatible[3] := "Rooster";
    incompatible[4] := "Dog";     incompatible[5] := "Pig";
    incompatible[6] := "Rat";     incompatible[7] := "Ox";
    incompatible[8] := "Tiger";   incompatible[9] := "Rabbit";
    incompatible[10] := "Dragon"; incompatible[11] := "Snake";

    animalIdx := (year - 4) MOD 12;
    elementIdx := ((year - 4) MOD 10) DIV 2;
    yinYangIdx := year MOD 2;

    (* Output basic info *)
    Out.Int(year, 0);
    Out.String(": ");
    Out.String(elements[elementIdx]);
    Out.Char(" ");
    Out.String(animals[animalIdx]);
    
    IF yinYangIdx = 0 THEN
      Out.String(" (Yang)");
    ELSE
      Out.String(" (Yin)");
    END;
    Out.Ln;

    (* Output Relationship info *)
    Out.String("   + Compatible with: ");
    Out.String(compatible[animalIdx]);
    Out.Ln;
    Out.String("   - Incompatible with: ");
    Out.String(incompatible[animalIdx]);
    Out.Ln; Out.Ln;

  END DetermineZodiac;

VAR
  year: INTEGER;
  
BEGIN
  FOR year := 1936 TO 2036 DO
    DetermineZodiac(year);
  END;
END Zodiac.