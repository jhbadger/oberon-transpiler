MODULE NameGenerator;

  IMPORT Out, In, Random;

  CONST
    MaxNames = 50;

  VAR
    firstNames: ARRAY MaxNames OF ARRAY 32 OF CHAR;
    lastNames: ARRAY MaxNames OF ARRAY 32 OF CHAR;
    chosenFirst, chosenLast: ARRAY 32 OF CHAR;
    input: CHAR;
    i: INTEGER;

  PROCEDURE InitLists;
  BEGIN
    (* First Names *)
    firstNames[0] := "James"; firstNames[1] := "Mary"; firstNames[2] := "Robert";
    firstNames[3] := "Patricia"; firstNames[4] := "John"; firstNames[5] := "Jennifer";
    firstNames[6] := "Michael"; firstNames[7] := "Linda"; firstNames[8] := "William";
    firstNames[9] := "Elizabeth"; firstNames[10] := "Thomas"; firstNames[11] := "Sarah";
    firstNames[12] := "Christopher"; firstNames[13] := "Karen"; firstNames[14] := "Matthew";
    firstNames[15] := "Nancy"; firstNames[16] := "Anthony"; firstNames[17] := "Betty";
    firstNames[18] := "Mark"; firstNames[19] := "Sandra"; firstNames[20] := "Evelyn";
    firstNames[21] := "Liam"; firstNames[22] := "Mia"; firstNames[23] := "Ethan";
    firstNames[24] := "Charlotte"; firstNames[25] := "Noah"; firstNames[26] := "Sophia";
    firstNames[27] := "Lucas"; firstNames[28] := "Amelia"; firstNames[29] := "Oliver";
    firstNames[30] := "Aurora"; firstNames[31] := "Carter"; firstNames[32] := "Penelope";
    firstNames[33] := "Leo"; firstNames[34] := "Hazel"; firstNames[35] := "Julian";
    firstNames[36] := "Violet"; firstNames[37] := "Grayson"; firstNames[38] := "Stella";
    firstNames[39] := "Gabriel"; firstNames[40] := "Silas"; firstNames[41] := "Cora";
    firstNames[42] := "Xavier"; firstNames[43] := "Ruby"; firstNames[44] := "Kai";
    firstNames[45] := "Ivy"; firstNames[46] := "Quinn"; firstNames[47] := "Jude";
    firstNames[48] := "Clara"; firstNames[49] := "Felix";

    (* Last Names *)
    lastNames[0] := "Smith"; lastNames[1] := "Johnson"; lastNames[2] := "Williams";
    lastNames[3] := "Brown"; lastNames[4] := "Jones"; lastNames[5] := "Garcia";
    lastNames[6] := "Miller"; lastNames[7] := "Davis"; lastNames[8] := "Rodriguez";
    lastNames[9] := "Martinez"; lastNames[10] := "White"; lastNames[11] := "Harris";
    lastNames[12] := "Clark"; lastNames[13] := "Lewis"; lastNames[14] := "Robinson";
    lastNames[15] := "Walker"; lastNames[16] := "Young"; lastNames[17] := "Allen";
    lastNames[18] := "King"; lastNames[19] := "Wright"; lastNames[20] := "Powell";
    lastNames[21] := "Sullivan"; lastNames[22] := "Russell"; lastNames[23] := "Ortiz";
    lastNames[24] := "Jenkins"; lastNames[25] := "Gutierrez"; lastNames[26] := "Perry";
    lastNames[27] := "Butler"; lastNames[28] := "Barnes"; lastNames[29] := "Fisher";
    lastNames[30] := "Hayes"; lastNames[31] := "Myers"; lastNames[32] := "Ford";
    lastNames[33] := "Hamilton"; lastNames[34] := "Graham"; lastNames[35] := "Sullivan";
    lastNames[36] := "Wallace"; lastNames[37] := "Cole"; lastNames[38] := "West";
    lastNames[39] := "Jordan"; lastNames[40] := "Mendez"; lastNames[41] := "Bush";
    lastNames[42] := "Wagner"; lastNames[43] := "Hunter"; lastNames[44] := "Cunningham";
    lastNames[45] := "McCarty"; lastNames[46] := "Estrada"; lastNames[47] := "Walters";
    lastNames[48] := "Bowden"; lastNames[49] := "Ziegler"
  END InitLists;

  PROCEDURE Generate;
  BEGIN
    chosenFirst := firstNames[Random.Int(MaxNames)];
    chosenLast := lastNames[Random.Int(MaxNames)];

    Out.String("Result: ");
    Out.String(chosenFirst); Out.Char(" "); Out.String(chosenLast);
    Out.Ln
  END Generate;

BEGIN
  InitLists;
  
  REPEAT
    FOR i := 1 TO 10 DO
      Generate;
    END;
    Out.String("Press 'q' to quit or any other key to play again: ");
    READ(input);
  UNTIL (input = "q") OR (input = "Q");
  
  Out.String("Exiting..."); Out.Ln
END NameGenerator.