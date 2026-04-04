MODULE Pets;
  IMPORT Out;

  TYPE
    PetRec  = RECORD name: ARRAY 32 OF CHAR END;
    Pet     = POINTER TO PetRec;

    CatRec  = RECORD (PetRec) END;
    Cat     = POINTER TO CatRec;

    DogRec  = RECORD (PetRec) END;
    Dog     = POINTER TO DogRec;

    BirdRec = RECORD (PetRec) END;
    Bird    = POINTER TO BirdRec;

  VAR
    pety:     Pet;
    pico:     Cat;
    snuggles: Dog;
    tweety:   Bird;

  PROCEDURE Speak(p: Pet);
  BEGIN
    IF p IS CatRec THEN
      WITH p: CatRec DO Out.String(p.name); Out.String(": meow!") END
    ELSIF p IS DogRec THEN
      WITH p: DogRec DO Out.String(p.name); Out.String(": bark!") END
    ELSIF p IS BirdRec THEN
      WITH p: BirdRec DO Out.String(p.name); Out.String(": chirp chirp!") END
    ELSE
      Out.String(p.name); Out.String(": [generic pet noises]")
    END;
    Out.Ln
  END Speak;

BEGIN
  NEW(pety);     pety.name     := "Pety";
  NEW(pico);     pico.name     := "Pico";
  NEW(snuggles); snuggles.name := "Snuggles";
  NEW(tweety);   tweety.name   := "Tweety";

  Speak(pety);
  Speak(pico);
  Speak(snuggles);
  Speak(tweety);
END Pets.
