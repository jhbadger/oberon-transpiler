MODULE BRECharGen;
(*
 * Barbarians of the Ruined Earth – Character Generator
 *
 * Implements character creation per the BRE rules:
 *   - Roll stats (3d6, with 2d6+2 after any 15+)
 *   - Choose class (Barbarian, Beastman, Death Priest, Robot,
 *                   Scavenger, Sorcerer, Urchin, Vek)
 *   - Roll starting HP
 *   - Roll starting coins (1d10 x 10)
 *   - Roll life event, trinket
 *   - Class-specific options (Robot model, Urchin type,
 *                             Beastman animal, Sorcerer appearance,
 *                             Sorcerer starting schools)
 *
 * Controls: answer prompts with a number and press ENTER.
 *)

IMPORT Out, In, Random, Strings;

(* ── Dice helpers ──────────────────────────────────────────── *)

PROCEDURE d4()  : INTEGER;  BEGIN RETURN Random.Int(4)  + 1 END d4;
PROCEDURE d6()  : INTEGER;  BEGIN RETURN Random.Int(6)  + 1 END d6;
PROCEDURE d8()  : INTEGER;  BEGIN RETURN Random.Int(8)  + 1 END d8;
PROCEDURE d10() : INTEGER;  BEGIN RETURN Random.Int(10) + 1 END d10;
PROCEDURE d12() : INTEGER;  BEGIN RETURN Random.Int(12) + 1 END d12;
PROCEDURE d20() : INTEGER;  BEGIN RETURN Random.Int(20) + 1 END d20;

PROCEDURE d3d6() : INTEGER;
BEGIN RETURN d6() + d6() + d6() END d3d6;

PROCEDURE d2d6p2() : INTEGER;
BEGIN RETURN d6() + d6() + 2 END d2d6p2;

(* ── Output helpers ────────────────────────────────────────── *)

PROCEDURE Ln;
BEGIN Out.Ln END Ln;

PROCEDURE S(s : ARRAY OF CHAR);
BEGIN Out.String(s) END S;

PROCEDURE SL(s : ARRAY OF CHAR);
BEGIN Out.String(s); Out.Ln END SL;

PROCEDURE I(n : INTEGER);
BEGIN Out.Int(n, 0) END I;

PROCEDURE Separator;
BEGIN SL("────────────────────────────────────────────────") END Separator;

(* ── Input helpers ─────────────────────────────────────────── *)

PROCEDURE ReadInt(VAR n : INTEGER);
(* Read a single integer from stdin, ignore rest of line. *)
VAR c : CHAR;
BEGIN
  In.Int(n);
  In.Read(c);
  WHILE (c # 0AX) & (c # 0X) DO In.Read(c) END
END ReadInt;

PROCEDURE PickOption(max : INTEGER) : INTEGER;
(* Prompt until the user enters 1..max. *)
VAR n : INTEGER;
BEGIN
  LOOP
    S("  Choice [1-"); I(max); S("]: ");
    ReadInt(n);
    IF (n >= 1) & (n <= max) THEN RETURN n END;
    SL("  Invalid – please try again.")
  END
END PickOption;

(* ── Stat rolling ──────────────────────────────────────────── *)

PROCEDURE RollStats(VAR str, dex, con, int_, wis, cha : INTEGER);
(* Roll 3d6 per stat; if a 15+ is rolled use 2d6+2 for the next one. *)
VAR vals : ARRAY 6 OF INTEGER;
    i : INTEGER;
    useBonus : BOOLEAN;
BEGIN
  useBonus := FALSE;
  FOR i := 0 TO 5 DO
    IF useBonus THEN
      vals[i] := d2d6p2();
      useBonus := FALSE
    ELSE
      vals[i] := d3d6();
      IF vals[i] >= 15 THEN useBonus := TRUE END
    END
  END;
  str  := vals[0];
  dex  := vals[1];
  con  := vals[2];
  int_ := vals[3];
  wis  := vals[4];
  cha  := vals[5]
END RollStats;

(* ── Print one stat line ───────────────────────────────────── *)

PROCEDURE PrintStat(name : ARRAY OF CHAR; val : INTEGER);
BEGIN
  S("  "); S(name); S(": "); I(val); Ln
END PrintStat;

(* ── Class names ───────────────────────────────────────────── *)

PROCEDURE ClassName(c : INTEGER; VAR s : ARRAY OF CHAR);
BEGIN
  IF    c = 1 THEN COPY("Barbarian",   s)
  ELSIF c = 2 THEN COPY("Beastman",    s)
  ELSIF c = 3 THEN COPY("Death Priest",s)
  ELSIF c = 4 THEN COPY("Robot",       s)
  ELSIF c = 5 THEN COPY("Scavenger",   s)
  ELSIF c = 6 THEN COPY("Sorcerer",    s)
  ELSIF c = 7 THEN COPY("Urchin",      s)
  ELSE              COPY("Vek",        s)
  END
END ClassName;

(* ── HP tables ─────────────────────────────────────────────── *)

PROCEDURE RollStartHP(class : INTEGER) : INTEGER;
(* Starting HP = HD+4 where HD depends on class *)
BEGIN
  IF    class = 1 THEN RETURN d10() + 4   (* Barbarian *)
  ELSIF class = 2 THEN RETURN d12() + 4   (* Beastman  *)
  ELSIF class = 3 THEN RETURN d6()  + 4   (* Death Priest *)
  ELSIF class = 4 THEN RETURN d8()  + 4   (* Robot     *)
  ELSIF class = 5 THEN RETURN d8()  + 4   (* Scavenger *)
  ELSIF class = 6 THEN RETURN d6()  + 4   (* Sorcerer  *)
  ELSIF class = 7 THEN RETURN d4()  + 4   (* Urchin    *)
  ELSE                  RETURN d8()  + 4  (* Vek       *)
  END
END RollStartHP;

(* ── Beastman animal ───────────────────────────────────────── *)

PROCEDURE BeastAnimal(roll : INTEGER; VAR s : ARRAY OF CHAR);
BEGIN
  IF    roll = 2  THEN COPY("Wolf",     s)
  ELSIF roll = 3  THEN COPY("Bear",     s)
  ELSIF roll = 4  THEN COPY("Cougar",   s)
  ELSIF roll = 5  THEN COPY("Alligator",s)
  ELSIF roll = 6  THEN COPY("Snake",    s)
  ELSIF roll = 7  THEN COPY("Armadillo",s)
  ELSIF roll = 8  THEN COPY("Badger",   s)
  ELSIF roll = 9  THEN COPY("Tiger",    s)
  ELSIF roll = 10 THEN COPY("Lion",     s)
  ELSIF roll = 11 THEN COPY("Moose",    s)
  ELSIF roll = 12 THEN COPY("Frog",     s)
  ELSIF roll = 13 THEN COPY("Mole",     s)
  ELSIF roll = 14 THEN COPY("Rabbit",   s)
  ELSIF roll = 15 THEN COPY("Rhino",    s)
  ELSE                 COPY("Hybrid",   s)
  END
END BeastAnimal;

PROCEDURE BeastSpecies(roll : INTEGER; VAR s : ARRAY OF CHAR);
BEGIN
  IF    roll = 1  THEN COPY("Cull",   s)
  ELSIF roll = 2  THEN COPY("Sylthis",s)
  ELSIF roll = 3  THEN COPY("Nok",    s)
  ELSIF roll = 4  THEN COPY("Kurd",   s)
  ELSIF roll = 5  THEN COPY("Bryll",  s)
  ELSIF roll = 6  THEN COPY("Dredge", s)
  ELSIF roll = 7  THEN COPY("Grok",   s)
  ELSIF roll = 8  THEN COPY("Fanth",  s)
  ELSIF roll = 9  THEN COPY("Ryn",    s)
  ELSE                 COPY("Hulyth", s)
  END
END BeastSpecies;

(* ── Sorcerer appearance ───────────────────────────────────── *)

PROCEDURE SorcSkinColor(roll : INTEGER; VAR s : ARRAY OF CHAR);
BEGIN
  IF    roll = 1  THEN COPY("Natural",        s)
  ELSIF roll = 2  THEN COPY("Blue/Lime green",s)
  ELSIF roll = 3  THEN COPY("Alabaster/Silver",s)
  ELSIF roll = 4  THEN COPY("Pink/Copper",    s)
  ELSIF roll = 5  THEN COPY("Obsidian/Charcoal",s)
  ELSIF roll = 6  THEN COPY("Grey/Teal",      s)
  ELSIF roll = 7  THEN COPY("Orange/Powder Blue",s)
  ELSIF roll = 8  THEN COPY("Yellow/Plum",    s)
  ELSIF roll = 9  THEN COPY("Purple/Fuchsia", s)
  ELSE                 COPY("Red/Sage",       s)
  END
END SorcSkinColor;

PROCEDURE SorcStaff(roll : INTEGER; VAR s : ARRAY OF CHAR);
BEGIN
  IF    roll = 1  THEN COPY("Strange metal from another world",          s)
  ELSIF roll = 2  THEN COPY("Oak from the oldest tree (won't burn)",     s)
  ELSIF roll = 3  THEN COPY("Darkest obsidian",                         s)
  ELSIF roll = 4  THEN COPY("Ivory of an ancient dragon horn",           s)
  ELSIF roll = 5  THEN COPY("Metallic, etched with spider webs",         s)
  ELSIF roll = 6  THEN COPY("Resin with a whirlwind trapped inside",     s)
  ELSIF roll = 7  THEN COPY("Pitchfork said to be the first ever",       s)
  ELSIF roll = 8  THEN COPY("Metallic rod with glowing lights & buttons",s)
  ELSIF roll = 9  THEN COPY("Boring wooden staff (feel self-conscious)",  s)
  ELSE                 COPY("Made from the spinal cord of a great snake", s)
  END
END SorcStaff;

(* ── Robot combat special feature ─────────────────────────── *)

PROCEDURE RobotCombatFeature(roll : INTEGER; VAR s : ARRAY OF CHAR);
BEGIN
  IF    roll = 1 THEN COPY("Laser beam eyes (1d6 Usage Die, recharges with sleep)",          s)
  ELSIF roll = 2 THEN COPY("Hand transforms into axe",                                       s)
  ELSIF roll = 3 THEN COPY("Rocket boots – can fly (1d10 Usage Die, recharges with sleep)",  s)
  ELSIF roll = 4 THEN COPY("Electric dampening shield (absorbs 4 elec dmg, recharges sleep)",s)
  ELSIF roll = 5 THEN COPY("Shoulder laser cannon (1d8 Usage Die, recharges with sleep)",    s)
  ELSIF roll = 6 THEN COPY("Hand transforms into chainsaw",                                   s)
  ELSIF roll = 7 THEN COPY("Hand transforms into sword",                                      s)
  ELSE                COPY("Web beam on forearm (Web spell, 1d4 Usage Die, recharges sleep)", s)
  END
END RobotCombatFeature;

(* ── Urchin type ───────────────────────────────────────────── *)

PROCEDURE UrchinType(roll : INTEGER; VAR s : ARRAY OF CHAR);
BEGIN
  IF    roll = 1 THEN COPY("Swamp",    s)
  ELSIF roll = 2 THEN COPY("Desert",   s)
  ELSIF roll = 3 THEN COPY("Sewer",    s)
  ELSIF roll = 4 THEN COPY("Urban",    s)
  ELSIF roll = 5 THEN COPY("Forest",   s)
  ELSE                COPY("Badlands", s)
  END
END UrchinType;

PROCEDURE UrchinBonus(roll : INTEGER; VAR s : ARRAY OF CHAR);
BEGIN
  IF    roll = 1 THEN COPY("Advantage on swamp knowledge/survival tests; 2nd stat: WIS",s)
  ELSIF roll = 2 THEN COPY("Advantage vs poisons & desert survival; 2nd stat: CON",     s)
  ELSIF roll = 3 THEN COPY("Never lost underground, low-light vision Nearby; 2nd: CON", s)
  ELSIF roll = 4 THEN COPY("Advantage: climbing, hazard detect, structural sense; WIS", s)
  ELSIF roll = 5 THEN COPY("Animal companion (roll 1d10), forest survival; 2nd: WIS",   s)
  ELSE                COPY("2 extra days without food/water, +short spear prof; STR",   s)
  END
END UrchinBonus;

(* ── Life events ───────────────────────────────────────────── *)

PROCEDURE LifeEvent(class, roll : INTEGER; VAR s : ARRAY OF CHAR);
BEGIN
  (* All classes share event 1: "slave and escaped" *)
  IF roll = 1 THEN
    COPY("You were a slave and escaped.", s);
    RETURN
  END;
  IF class = 1 THEN (* Barbarian *)
    IF    roll = 2 THEN COPY("Your mother was killed by croc-men.",                                          s)
    ELSIF roll = 3 THEN COPY("Your village was sacked by a Sorcerer; most villagers taken.",                 s)
    ELSIF roll = 4 THEN COPY("You bravely fought off several bandits as a young teenager.",                  s)
    ELSIF roll = 5 THEN COPY("While resting under a tree, a spirit appeared and talked to you.",             s)
    ELSIF roll = 6 THEN COPY("You went into ancient ruins on a dare; a family member saved you.",            s)
    ELSIF roll = 7 THEN COPY("You went on a hunt and landed the killing blow on a great rhino-lion.",        s)
    ELSE                COPY("The love of your young life died in your arms during a raider attack.",         s)
    END
  ELSIF class = 2 THEN (* Beastman *)
    IF    roll = 2 THEN COPY("Your father was tribe leader; you and family were pushed into exile.",          s)
    ELSIF roll = 3 THEN COPY("You fought off slavers who were attempting to take your sister.",               s)
    ELSIF roll = 4 THEN COPY("You watched many of your tribe vaporized by a Sorcerer; you survived.",        s)
    ELSIF roll = 5 THEN COPY("A Water Weird attacked you by the river; it stopped and let you live.",        s)
    ELSIF roll = 6 THEN COPY("On a hunt you found a dragon's lair; it talked to you and let you leave.",     s)
    ELSIF roll = 7 THEN COPY("You won a fighting contest in youth; considered a celebrity in your tribe.",   s)
    ELSE                COPY("You stumbled across a lush valley; your tribe has relocated there.",            s)
    END
  ELSIF class = 3 THEN (* Death Priest *)
    IF    roll = 2 THEN COPY("You were forced to use your powers by a Sorcerer, causing much harm.",         s)
    ELSIF roll = 3 THEN COPY("You fell in a crevice; a spirit guided you out. It still visits you.",         s)
    ELSIF roll = 4 THEN COPY("You drained raiders of life force to save humans; they now fear you.",         s)
    ELSIF roll = 5 THEN COPY("You joined an extremist Death Priest order; you left, but they want you back.",s)
    ELSIF roll = 6 THEN COPY("You ruled a small village before being pushed out by a Barbarian.",            s)
    ELSIF roll = 7 THEN COPY("Your calm judgment quelled a generations-long family feud.",                   s)
    ELSE                COPY("A vile spirit possessed you and you killed innocents. Atoning since.",          s)
    END
  ELSIF class = 4 THEN (* Robot *)
    IF    roll = 2 THEN COPY("A generous Stupendous Scientist made you self-aware, taught compassion.",      s)
    ELSIF roll = 3 THEN COPY("First person to realize you were sentient tried to reboot you. You killed them.",s)
    ELSIF roll = 4 THEN COPY("Almost scrapped for disobeying orders; you killed the machinist and fled.",    s)
    ELSIF roll = 5 THEN COPY("You served in a Sorcerer's army; caused great harm. You seek repentance.",     s)
    ELSIF roll = 6 THEN COPY("Your mouthing off has gotten you chased out of towns more than once.",         s)
    ELSIF roll = 7 THEN COPY("The person who realized you were sentient smuggled you out of the factory.",   s)
    ELSE                COPY("You booted up after a great battle; spent months scrounging to rebuild yourself.",s)
    END
  ELSIF class = 5 THEN (* Scavenger *)
    IF    roll = 2 THEN COPY("You were exiled for stealing food from your village.",                          s)
    ELSIF roll = 3 THEN COPY("You found an Ancient Earth factory of robots; you accidentally blew it up.",   s)
    ELSIF roll = 4 THEN COPY("You used a freeze-beam device to thwart Pig Raiders; you're a hero.",          s)
    ELSIF roll = 5 THEN COPY("You lived in a cave with a crazed ancient Sorcerer for years.",                s)
    ELSIF roll = 6 THEN COPY("You accidentally vaporized your father and two of his drinking buddies.",      s)
    ELSIF roll = 7 THEN COPY("Delirious in the wastes, you found a lake of golden water; vowed to return.",  s)
    ELSE                COPY("Zapped by Stupendous Science; transported to 1994 for several days.",          s)
    END
  ELSIF class = 6 THEN (* Sorcerer *)
    IF    roll = 2 THEN COPY("You used powers to bully your village; they rose up and exiled you.",          s)
    ELSIF roll = 3 THEN COPY("Your mother abandoned you in the wastes; somehow you survived.",               s)
    ELSIF roll = 4 THEN COPY("You battled another Sorcerer in youth and won; part of them is in you.",       s)
    ELSIF roll = 5 THEN COPY("A friendly Barbarian stood by you and eventually died defending your honor.",  s)
    ELSIF roll = 6 THEN COPY("You have used your powers many times to protect your village; you're a hero.", s)
    ELSIF roll = 7 THEN COPY("Your family was pushed out of the village because of your birth.",              s)
    ELSE                COPY("As a child you came across a demon and battled it in a test of wills.",         s)
    END
  ELSIF class = 7 THEN (* Urchin *)
    IF    roll = 2 THEN COPY("You were abandoned by your parents in this environment.",                       s)
    ELSIF roll = 3 THEN COPY("Your parents were killed by raiders; you raised yourself.",                     s)
    ELSIF roll = 4 THEN COPY("You ran away from your village and decided to raise yourself.",                 s)
    ELSIF roll = 5 THEN COPY("You were a servant to a Sorcerer and managed to escape.",                      s)
    ELSIF roll = 6 THEN COPY("Chased from your village after too many childish pranks.",                     s)
    ELSIF roll = 7 THEN COPY("Child of the village leader; exiled after your father sold villagers.",        s)
    ELSE                COPY("You dreamed of flying on a magical bed; awoke in your environment.",            s)
    END
  ELSE (* Vek *)
    IF    roll = 2 THEN COPY("Your father was a brilliant inventor; a Sorcerer killed him in front of you.", s)
    ELSIF roll = 3 THEN COPY("Your mother leads the Collective; you have served with distinction.",           s)
    ELSIF roll = 4 THEN COPY("You broke the Collective supercomputer; you've been exiled.",                  s)
    ELSIF roll = 5 THEN COPY("You and a Barbarian defended your Collective from Pig Raiders.",               s)
    ELSIF roll = 6 THEN COPY("You traveled with a Scavenger, discovering Ancient Earth ruins.",              s)
    ELSIF roll = 7 THEN COPY("A Sorcerer transformed your seven sisters and five brothers into statues.",    s)
    ELSE                COPY("You discovered a sentient robot during your travels; still friends.",           s)
    END
  END
END LifeEvent;

(* ── Trinkets ──────────────────────────────────────────────── *)

PROCEDURE Trinket(class, roll : INTEGER; VAR s : ARRAY OF CHAR);
BEGIN
  IF class = 1 THEN
    IF    roll = 1 THEN COPY("Memento from a lost love sold into slavery",           s)
    ELSIF roll = 2 THEN COPY("Father's dagger – he died defending you with it",      s)
    ELSIF roll = 3 THEN COPY("A thick cloak",                                        s)
    ELSIF roll = 4 THEN COPY("Old World 'flashlight' – it still works",              s)
    ELSIF roll = 5 THEN COPY("Collapsible cooking pot set",                          s)
    ELSE                COPY("Necklace of fangs – spoils of your first hunt",         s)
    END
  ELSIF class = 2 THEN
    IF    roll = 1 THEN COPY("A tooth of your father, worn around your neck",        s)
    ELSIF roll = 2 THEN COPY("The rusted manacles that once bound you",              s)
    ELSIF roll = 3 THEN COPY("A flute",                                              s)
    ELSIF roll = 4 THEN COPY("A backpack made by your sister",                       s)
    ELSIF roll = 5 THEN COPY("A bag of seeds from your village elder",               s)
    ELSE                COPY("Staff made from bones of a great beast",               s)
    END
  ELSIF class = 3 THEN
    IF    roll = 1 THEN COPY("An ornate robe showing your station",                  s)
    ELSIF roll = 2 THEN COPY("A skull with yellow pinprick lights in the sockets",   s)
    ELSIF roll = 3 THEN COPY("Highly decorative, jeweled earrings",                  s)
    ELSIF roll = 4 THEN COPY("A ceremonial silver dagger",                           s)
    ELSIF roll = 5 THEN COPY("Censer with incense",                                  s)
    ELSE                COPY("Vial of ectoplasm",                                    s)
    END
  ELSIF class = 4 THEN
    IF    roll = 1 THEN COPY("Keepsake from the first person who treated you as living",  s)
    ELSIF roll = 2 THEN COPY("A tin full of human teeth",                            s)
    ELSIF roll = 3 THEN COPY("An Ancient Earth WWII army helmet",                    s)
    ELSIF roll = 4 THEN COPY("A baby doll that 'coos' when shaken",                  s)
    ELSIF roll = 5 THEN COPY("A beat-up fedora hat and trench coat",                 s)
    ELSE                COPY("Furry plush robotic teddy bear with cassette player",   s)
    END
  ELSIF class = 5 THEN
    IF    roll = 1 THEN COPY("Ancient Earth 'HAM' radio – still functional",         s)
    ELSIF roll = 2 THEN COPY("A blowtorch",                                          s)
    ELSIF roll = 3 THEN COPY("A metal detector",                                     s)
    ELSIF roll = 4 THEN COPY("A collection of pretty glass bottles",                 s)
    ELSIF roll = 5 THEN COPY("A tattered but beautiful wedding dress",               s)
    ELSE                COPY("A 'football' helmet",                                  s)
    END
  ELSIF class = 6 THEN
    IF    roll = 1 THEN COPY("A friendly animal loyal to you",                       s)
    ELSIF roll = 2 THEN COPY("An orb that lets you scry on one chosen individual",   s)
    ELSIF roll = 3 THEN COPY("A music box",                                          s)
    ELSIF roll = 4 THEN COPY("A fine silk robe of vibrant colors",                   s)
    ELSIF roll = 5 THEN COPY("An ornate crown",                                      s)
    ELSE                COPY("A golden necklace denoting your remarkable birth",     s)
    END
  ELSIF class = 7 THEN
    IF    roll = 1 THEN COPY("A necklace made of a railroad spike",                  s)
    ELSIF roll = 2 THEN COPY("A snow globe",                                         s)
    ELSIF roll = 3 THEN COPY("A miner hardhat with working headlamp",                s)
    ELSIF roll = 4 THEN COPY("An Ancient Earth police officer's hat",                s)
    ELSIF roll = 5 THEN COPY("A pair of whacky eyeball glasses",                     s)
    ELSE                COPY("A tattered yet adorable teddy bear",                   s)
    END
  ELSE (* Vek *)
    IF    roll = 1 THEN COPY("A book of Ancient Earth history",                      s)
    ELSIF roll = 2 THEN COPY("A laser pistol (d10 Usage Die on battery pack)",       s)
    ELSIF roll = 3 THEN COPY("A headdress of bone, leather, and feathers",           s)
    ELSIF roll = 4 THEN COPY("A map of Ancient Earth city 'Los Angeles'",            s)
    ELSIF roll = 5 THEN COPY("A ruby necklace",                                      s)
    ELSE                COPY("An Ancient Earth sea captain's hat and jacket",        s)
    END
  END
END Trinket;

(* ── Starting equipment text ───────────────────────────────── *)

PROCEDURE PrintEquipment(class : INTEGER);
BEGIN
  Separator;
  SL("STARTING EQUIPMENT");
  IF class = 1 THEN (* Barbarian *)
    SL("  Choose THREE weapons from:");
    SL("    short sword, short bow, spear, dagger, axe, mace, spiked club");
    SL("  Armor: Loincloth or leather bikini (2 RP / Medium)");
    SL("  + Ammo (if ranged), rations d6, waterskin d6, bedroll,");
    SL("    torches x6 (d6), healing salve (1 HD HP)")
  ELSIF class = 2 THEN (* Beastman *)
    SL("  Choose TWO weapons from:");
    SL("    short sword, short bow, spear, dagger, axe, mace, spiked club");
    SL("  Armor: Cloth armor (1 RP / Light)");
    SL("  + Ammo (if ranged), rations d6, waterskin d6, bedroll,");
    SL("    torches x6 (d6), healing salve (1 HD HP)")
  ELSIF class = 3 THEN (* Death Priest *)
    SL("  Weapons: Blowgun and mace");
    SL("  Armor: Light armor (1 RP)");
    SL("  + Ammo for blowgun, symbol of holy order, rations d6,");
    SL("    waterskin d6, bedroll, torches x6 (d6), healing salve")
  ELSIF class = 4 THEN (* Robot *)
    SL("  Weapons: Fists and laser pistol");
    SL("  Armor: None (metal body = 1 RP, indestructible)");
    SL("  + Ammo for laser pistol, torches x6 (d6), Robot Repair Kit")
  ELSIF class = 5 THEN (* Scavenger *)
    SL("  Weapons: Dagger and crossbow");
    SL("  Armor: Cloth armor (1 RP / Light)");
    SL("  + Ammo, rations d6, waterskin d6, bedroll,");
    SL("    torches x6 (d6), healing salve (1 HD HP)")
  ELSIF class = 6 THEN (* Sorcerer *)
    SL("  Weapon: Sorcerer's staff (see staff description above)");
    SL("  Armor: None");
    SL("  + Rations d6, waterskin d6, bedroll, torches x6 (d6), healing salve")
  ELSIF class = 7 THEN (* Urchin *)
    SL("  Weapons: Dagger and blowgun OR sling (your choice)");
    SL("  Armor: Light armor (1 RP)");
    SL("  + Ammo, rations d6, waterskin d6, bedroll,");
    SL("    torches x6 (d6), healing salve (1 HD HP)")
  ELSE (* Vek *)
    SL("  Weapons: Spear and short sword");
    SL("  Armor: Medium armor (2 RP)");
    SL("  + Rations d6, waterskin d6, bedroll, torches x6 (d6), healing salve")
  END
END PrintEquipment;

(* ── Class special features ────────────────────────────────── *)

PROCEDURE PrintFeatures(class : INTEGER);
BEGIN
  Separator;
  SL("CLASS FEATURES");
  IF class = 1 THEN
    SL("  Attacker: 1 extra attack every odd level (max 5 at 9th).");
    SL("           Damage EXPLODES on max roll.");
    SL("  Avid Fighter: Once/combat, deflect one attack to failure.");
    SL("  Battle Shout: Once/combat, next STR or DEX test auto-succeeds.");
    SL("  Stout: Advantage vs Poisons and Fear.");
    SL("  Loin Cloth Warrior: Loincloth+bracers = Medium armor;");
    SL("    metal loincloth/chainmail bikini = Heavy; helmet = small shield.");
    SL("  Level-up: Roll twice for STR and DEX.")
  ELSIF class = 2 THEN
    SL("  Animal Features: Claws (never unarmed), darkvision Nearby.");
    SL("  Super Strong: Advantage on feats of strength (not attacks).");
    SL("  Impossibly Strong: Once/hour, impossible strength feat; 2d10 if attack.");
    SL("  Thick Hide: Once/day, half damage (not magic) for level rounds.");
    SL("  Level-up: Roll twice for STR or CON.")
  ELSIF class = 3 THEN
    SL("  Miracles: Starts with 2; gains more every odd level (max 6 at 9th).");
    SL("  Knowledge of the Dead: Once/hour, Advantage on an INT test.");
    SL("  Blessed: Advantage vs diseases and mind-control.");
    SL("  Recharge: Once/day after 1h rest, Luck roll to regain a Miracle.");
    SL("  Guardian Spirit: Once/session, 50% chance a spirit negates lethal blow.");
    SL("  Level-up: Roll twice for WIS or CHA.")
  ELSIF class = 4 THEN
    SL("  Metal Body: 1 RP armor (indestructible). No normal armor.");
    SL("  Machine: Low-light vision Nearby; immune to mind effects,");
    SL("    poisons, diseases; no food/breath; shutdown 8h to recharge.");
    SL("  Immune to non-magical fire; double damage from electricity.");
    SL("  Salvage: Rip parts from deactivated robots (WIS save vs corruption).");
    SL("  Level-up: Roll twice for STR and INT.")
  ELSIF class = 5 THEN
    SL("  Agile: Advantage on DEX saves vs traps, delicate tasks,");
    SL("    climbing, hearing, stealth, languages, locks.");
    SL("  Sneaky Bastard: Advantage when attacking from behind;");
    SL("    deals 2d6/2d4 + level damage.");
    SL("  Keen Eye: Once/hour, Luck roll to find mundane useful item.");
    SL("  Fixer: INT test to repair tech; heals 1d6+level HP, takes 1d6 hours.");
    SL("  Level-up: Roll twice for DEX or WIS.")
  ELSIF class = 6 THEN
    SL("  Detect: Detect magic/Stupendous Science/evil (all Nearby glow).");
    SL("  Magically Resistant: Advantage vs magic and charm.");
    SL("  Sorcerer's Staff: Channel energy – 1d4+1 damage ranged attack.");
    SL("  Spell Slinger: Cast spells by succeeding on INT test.");
    SL("    Fail = can't cast this turn. Roll 20 = lose casting for 24h.");
    SL("  Starts knowing 4 schools, 1 spell each; learns 1 spell/level,");
    SL("    1 new school every 3rd level.");
    SL("  Level-up: Roll twice for INT or WIS.")
  ELSIF class = 7 THEN
    SL("  Small: Advantage to avoid melee from larger targets.");
    SL("  Unexpected Adversary: First attack with Advantage; 2d4+level dmg.");
    SL("  Bossy: Once/day auto-succeed on a CHA test.");
    SL("  Environment: Special bonus based on Urchin type.");
    SL("  Level-up: Roll twice for DEX + secondary stat from type.")
  ELSE
    SL("  Highly Intelligent: Advantage on INT rolls and mind-altering saves;");
    SL("    always literate.");
    SL("  Dinosaur!: Low-light vision Nearby; 1 RP thick hide (stacks);");
    SL("    claws = class weapon damage; can leap 15-20ft.");
    SL("    Leap: Advantage on bite OR 3 attacks (Disadvantage all three).");
    SL("  More Juice: Once/hour, restore a spent tech item's Usage Die to d4.");
    SL("  Level-up: Roll twice for DEX or INT.")
  END
END PrintFeatures;

(* ── Sorcerer school picker ────────────────────────────────── *)

PROCEDURE PrintSorcSchools;
VAR i, pick : INTEGER;
    chosen : ARRAY 4 OF INTEGER;
    taken : BOOLEAN;
    names : ARRAY 10 OF ARRAY 24 OF CHAR;
BEGIN
  names[0] := "Arcane";
  names[1] := "Blight";
  names[2] := "Control";
  names[3] := "Force";
  names[4] := "Illusion";
  names[5] := "Movement";
  names[6] := "Protection";
  names[7] := "Restoration";
  names[8] := "Stupendous Science";
  names[9] := "Transformation";

  Separator;
  SL("SORCERER STARTING SCHOOLS");
  SL("  There are 10 schools. You start knowing 4 schools, 1 spell each.");
  SL("  Available schools:");
  FOR i := 0 TO 9 DO
    S("  "); I(i+1); S(") "); SL(names[i])
  END;
  SL("  Pick your 4 starting schools (enter 4 numbers):");
  FOR i := 0 TO 3 DO
    LOOP
      S("  School "); I(i+1); S(": ");
      ReadInt(pick);
      IF (pick >= 1) & (pick <= 10) THEN
        (* Check not already chosen *)
        taken := FALSE;
        IF i > 0 THEN
          IF chosen[0] = pick THEN taken := TRUE END
        END;
        IF i > 1 THEN
          IF chosen[1] = pick THEN taken := TRUE END
        END;
        IF i > 2 THEN
          IF chosen[2] = pick THEN taken := TRUE END
        END;
        IF ~taken THEN
          chosen[i] := pick;
          (* break loop *)
          i := i;  (* no-op to keep compiler happy *)
          EXIT
        ELSE
          SL("  Already chosen – pick a different school.")
        END
      ELSE
        SL("  Invalid choice.")
      END
    END
  END;
  SL("  Your starting schools:");
  FOR i := 0 TO 3 DO
    S("    "); I(i+1); S(". "); SL(names[chosen[i]-1])
  END;
  SL("  (Choose one spell from each school – see BRE rulebook p.50-54)")
END PrintSorcSchools;

(* ── Death Priest miracle picker ───────────────────────────── *)

PROCEDURE PrintDPMiracles;
VAR i, pick1, pick2 : INTEGER;
    miracles : ARRAY 16 OF ARRAY 20 OF CHAR;
BEGIN
  miracles[0]  := "Banish";
  miracles[1]  := "Bolster";
  miracles[2]  := "Curse";
  miracles[3]  := "Darkvision";
  miracles[4]  := "Death Throes";
  miracles[5]  := "Ethereal Form";
  miracles[6]  := "Guardian Spirit";
  miracles[7]  := "Harming Touch";
  miracles[8]  := "Haunt";
  miracles[9]  := "Heal";
  miracles[10] := "Heighten";
  miracles[11] := "Howling Crash";
  miracles[12] := "See Invisibility";
  miracles[13] := "Speak With Dead";
  miracles[14] := "Spectral Limb";
  miracles[15] := "Spectral Wall";

  Separator;
  SL("DEATH PRIEST STARTING MIRACLES");
  SL("  Available miracles:");
  FOR i := 0 TO 15 DO
    S("  "); I(i+1); S(") "); SL(miracles[i])
  END;
  S("  Choose your FIRST miracle [1-16]: ");
  pick1 := PickOption(16);
  LOOP
    S("  Choose your SECOND miracle [1-16]: ");
    pick2 := PickOption(16);
    IF pick2 # pick1 THEN EXIT
    ELSE SL("  Already chosen – pick a different miracle.")
    END
  END;
  S("  Starting Miracles: "); S(miracles[pick1-1]);
  S(" and "); SL(miracles[pick2-1])
END PrintDPMiracles;

(* ── Adventure generator tables ────────────────────────────── *)

PROCEDURE AdvPerson(roll : INTEGER; VAR s : ARRAY OF CHAR);
BEGIN
  IF    roll = 1  THEN COPY("Mutant",   s)
  ELSIF roll = 2  THEN COPY("Child",    s)
  ELSIF roll = 3  THEN COPY("Merchant", s)
  ELSIF roll = 4  THEN COPY("Sorcerer", s)
  ELSIF roll = 5  THEN COPY("Wise Man", s)
  ELSIF roll = 6  THEN COPY("Princess", s)
  ELSIF roll = 7  THEN COPY("Raider",   s)
  ELSIF roll = 8  THEN COPY("Cultist",  s)
  ELSIF roll = 9  THEN COPY("Beastman", s)
  ELSIF roll = 10 THEN COPY("Croc-man", s)
  ELSIF roll = 11 THEN COPY("Vek",      s)
  ELSE                 COPY("Priest",   s)
  END
END AdvPerson;

PROCEDURE AdvAction(roll : INTEGER; VAR s : ARRAY OF CHAR);
BEGIN
  IF    roll = 1  THEN COPY("Kidnap",    s)
  ELSIF roll = 2  THEN COPY("Rescue",    s)
  ELSIF roll = 3  THEN COPY("Kill",      s)
  ELSIF roll = 4  THEN COPY("Protect",   s)
  ELSIF roll = 5  THEN COPY("Find",      s)
  ELSIF roll = 6  THEN COPY("Threaten",  s)
  ELSIF roll = 7  THEN COPY("Aid",       s)
  ELSIF roll = 8  THEN COPY("Thwart",    s)
  ELSIF roll = 9  THEN COPY("Harass",    s)
  ELSIF roll = 10 THEN COPY("Spy",       s)
  ELSIF roll = 11 THEN COPY("Transport", s)
  ELSE                 COPY("Persuade",  s)
  END
END AdvAction;

PROCEDURE AdvLocation(roll : INTEGER; VAR s : ARRAY OF CHAR);
BEGIN
  IF    roll = 1  THEN COPY("Abandoned Metal Factory",        s)
  ELSIF roll = 2  THEN COPY("Ruined School",                  s)
  ELSIF roll = 3  THEN COPY("Sorcerer's Metal War Vehicle",   s)
  ELSIF roll = 4  THEN COPY("Dilapidated Shopping Mall",      s)
  ELSIF roll = 5  THEN COPY("Floating Landmass",              s)
  ELSIF roll = 6  THEN COPY("Broken Down Museum",             s)
  ELSIF roll = 7  THEN COPY("Series of Catacombs",            s)
  ELSIF roll = 8  THEN COPY("Shutdown Science Station",       s)
  ELSIF roll = 9  THEN COPY("Mutated Rodent Infested Sewer",  s)
  ELSIF roll = 10 THEN COPY("Raider Occupied Amusement Park", s)
  ELSIF roll = 11 THEN COPY("Old Firearms Factory",           s)
  ELSE                 COPY("Eerie Ancient Earth Graveyard",  s)
  END
END AdvLocation;

PROCEDURE AdvObject(roll : INTEGER; VAR s : ARRAY OF CHAR);
BEGIN
  IF    roll = 1  THEN COPY("Mind Control Rod",                    s)
  ELSIF roll = 2  THEN COPY("Solar Sword",                         s)
  ELSIF roll = 3  THEN COPY("Helmet of Power",                     s)
  ELSIF roll = 4  THEN COPY("Vicious Whip of Subjugation",         s)
  ELSIF roll = 5  THEN COPY("Ring of Healing",                     s)
  ELSIF roll = 6  THEN COPY("Computer of Tactical Competence",     s)
  ELSIF roll = 7  THEN COPY("The Wizard's Ride",                   s)
  ELSIF roll = 8  THEN COPY("The Vest of Deflection",              s)
  ELSIF roll = 9  THEN COPY("Clamps of Holding",                   s)
  ELSIF roll = 10 THEN COPY("Cask of Drinking",                    s)
  ELSIF roll = 11 THEN COPY("Staff of Vengeance",                  s)
  ELSE                 COPY("The Heavy Metal Throne of the Eclipse",s)
  END
END AdvObject;

PROCEDURE AdvSecondPerson(roll : INTEGER; VAR s : ARRAY OF CHAR);
BEGIN
  IF    roll = 1  THEN COPY("Chieftain",            s)
  ELSIF roll = 2  THEN COPY("Witch",                s)
  ELSIF roll = 3  THEN COPY("Band of Warriors",     s)
  ELSIF roll = 4  THEN COPY("Bandit Leader",        s)
  ELSIF roll = 5  THEN COPY("Savage",               s)
  ELSIF roll = 6  THEN COPY("Hawk-man",             s)
  ELSIF roll = 7  THEN COPY("Vek",                  s)
  ELSIF roll = 8  THEN COPY("Wastelander",          s)
  ELSIF roll = 9  THEN COPY("Sorcerer",             s)
  ELSIF roll = 10 THEN COPY("Group of Humans",      s)
  ELSIF roll = 11 THEN COPY("Healer",               s)
  ELSE                 COPY("Stupendous Scientist",  s)
  END
END AdvSecondPerson;

PROCEDURE AdvTwist(roll : INTEGER; VAR s : ARRAY OF CHAR);
BEGIN
  IF    roll = 1  THEN COPY("Secret Raider Hideout",                       s)
  ELSIF roll = 2  THEN COPY("Home to Ancient Earth Technology",             s)
  ELSIF roll = 3  THEN COPY("Person Not Who They Appear to Be",             s)
  ELSIF roll = 4  THEN COPY("Malfunctioning Magic",                         s)
  ELSIF roll = 5  THEN COPY("No Twist",                                     s)
  ELSIF roll = 6  THEN COPY("Stupendous Science at Work!",                  s)
  ELSIF roll = 7  THEN COPY("Third Party Complicates Matters",              s)
  ELSIF roll = 8  THEN COPY("Killer Robots Activated",                      s)
  ELSIF roll = 9  THEN COPY("Natural Disaster",                             s)
  ELSIF roll = 10 THEN COPY("Object is Not What it is Believed to Be",      s)
  ELSIF roll = 11 THEN COPY("Doomsday Weapon Discovered",                   s)
  ELSE                 COPY("Large Cache of Treasure Discovered",            s)
  END
END AdvTwist;

PROCEDURE AdvCrazy(roll : INTEGER; VAR s : ARRAY OF CHAR);
BEGIN
  IF    roll = 1  THEN COPY("Techno-infused zombies",                                   s)
  ELSIF roll = 2  THEN COPY("Pterodactyls with missile launchers",                      s)
  ELSIF roll = 3  THEN COPY("Enslaved elementals powering Stupendous Science devices",  s)
  ELSIF roll = 4  THEN COPY("Active volcano with slumbering Cosmic Being",              s)
  ELSIF roll = 5  THEN COPY("Chasm to underground city of Molemen at war with bats",    s)
  ELSIF roll = 6  THEN COPY("Roving mechanical prison built by a Sorcerer",             s)
  ELSIF roll = 7  THEN COPY("Crashed alien ship – aliens still lurking",                s)
  ELSIF roll = 8  THEN COPY("Sentient AI with digital body; curious but wary",          s)
  ELSIF roll = 9  THEN COPY("Village controlled by slugs burrowed into inhabitants",    s)
  ELSIF roll = 10 THEN COPY("Being of pure sunlight (and radiation)",                   s)
  ELSIF roll = 11 THEN COPY("Tower resembling a circuit board",                         s)
  ELSIF roll = 12 THEN COPY("Anthropomorphic tree-people enraged at nature's abuse",    s)
  ELSIF roll = 13 THEN COPY("Old train delivering alchemical supplies to a Sorcerer",   s)
  ELSIF roll = 14 THEN COPY("Swamp creatures infected by a fungal plague",              s)
  ELSIF roll = 15 THEN COPY("Gyrocopter-riding raiders",                                s)
  ELSIF roll = 16 THEN COPY("Forest of crystalline trees; nightmare creatures within",  s)
  ELSIF roll = 17 THEN COPY("Ancient Earth factory full of robots",                     s)
  ELSIF roll = 18 THEN COPY("Pig raiders on demon-powered motorcycles",                 s)
  ELSIF roll = 19 THEN COPY("Massive creature of solar panels, metal, and concrete",    s)
  ELSE                 COPY("Sports stadium turned cult shrine for petrified Sorcerer",  s)
  END
END AdvCrazy;

PROCEDURE GenerateAdventure;
VAR
  buf  : ARRAY 64 OF CHAR;
  abuf : ARRAY 64 OF CHAR;  (* long-entry buffer *)
  c    : CHAR;
BEGIN
  Separator;
  SL("ADVENTURE GENERATOR");
  Separator;
  AdvPerson(d12(), buf);
  S("  Person:        "); SL(buf);
  AdvAction(d12(), buf);
  S("  Action:        "); SL(buf);
  AdvLocation(d12(), abuf);
  S("  Location:      "); SL(abuf);
  AdvObject(d12(), abuf);
  S("  Object:        "); SL(abuf);
  AdvSecondPerson(d12(), buf);
  S("  Second Person: "); SL(buf);
  AdvTwist(d12(), abuf);
  S("  Twist:         "); SL(abuf);
  Separator;
  S("Add a Bring the Crazy entry? [y/n]: ");
  In.Read(c);
  WHILE (c = ' ') OR (c = 0AX) DO In.Read(c) END;
  IF (c = 'y') OR (c = 'Y') THEN
    (* flush rest of line *)
    In.Read(c);
    WHILE (c # 0AX) & (c # 0X) DO In.Read(c) END;
    AdvCrazy(d20(), abuf);
    S("  Bring the Crazy: "); SL(abuf)
  ELSE
    (* flush rest of line *)
    WHILE (c # 0AX) & (c # 0X) DO In.Read(c) END
  END;
  Separator
END GenerateAdventure;

(* ── Main generation loop ───────────────────────────────────── *)

VAR
  str, dex, con, int_, wis, cha : INTEGER;
  hp, coins, classChoice : INTEGER;
  lifeRoll, trinketRoll : INTEGER;
  buf : ARRAY 64 OF CHAR;
  buf2 : ARRAY 64 OF CHAR;
  robotModel, urchinRoll, animalRoll, speciesRoll : INTEGER;
  staffRoll, skinRoll, mode : INTEGER;

BEGIN
  LOOP
    Ln;
    SL("╔════════════════════════════════════════╗");
    SL("║    BARBARIANS OF THE RUINED EARTH      ║");
    SL("╚════════════════════════════════════════╝");
    Ln;
    SL("  1) Generate a Character");
    SL("  2) Generate an Adventure");
    SL("  3) Quit");
    mode := PickOption(3);
    IF mode = 3 THEN
      SL("May your steel never dull and your enemies be many!");
      EXIT
    END;
    Ln;

    IF mode = 2 THEN
      GenerateAdventure
    ELSE (* mode = 1 *)

    (* ── Roll stats ── *)
    SL("Rolling ability scores (3d6 each; 2d6+2 after any 15+)...");
    RollStats(str, dex, con, int_, wis, cha);
    Separator;
    SL("ABILITY SCORES");
    PrintStat("STR", str);
    PrintStat("DEX", dex);
    PrintStat("CON", con);
    PrintStat("INT", int_);
    PrintStat("WIS", wis);
    PrintStat("CHA", cha);

    (* ── Choose class ── *)
    Separator;
    SL("CHOOSE YOUR CLASS");
    SL("  Human classes:");
    SL("    1) Barbarian   – fierce warrior; battle prowess; damage explodes");
    SL("    2) Beastman    – bestial mutant; super strength; thick hide");
    SL("    3) Death Priest– channels death energy; miracles; guardian spirit");
    SL("    5) Scavenger   – tinkerer; sneaky; fixer of tech");
    SL("    7) Urchin      – scrappy child; small but deadly; environment expert");
    SL("  Non-human classes:");
    SL("    2) Beastman    (see above)");
    SL("    4) Robot       – construct; metal body; choose model");
    SL("    6) Sorcerer    – mystic; spells from 10 schools; not truly human");
    SL("    8) Vek         – raptorfolk; tech obsessed; claws and leap");
    Ln;
    SL("  1) Barbarian");
    SL("  2) Beastman");
    SL("  3) Death Priest");
    SL("  4) Robot");
    SL("  5) Scavenger");
    SL("  6) Sorcerer");
    SL("  7) Urchin");
    SL("  8) Vek");
    classChoice := PickOption(8);

    ClassName(classChoice, buf);
    Separator;
    S("CLASS: "); SL(buf);

    (* ── Roll HP ── *)
    hp := RollStartHP(classChoice);
    S("Starting HP: "); I(hp); Ln;

    (* ── Starting coins ── *)
    coins := d10() * 10;
    S("Starting Coins: "); I(coins); SL(" ceramic coins");

    (* ── Class-specific options ── *)
    IF classChoice = 4 THEN (* Robot model *)
      Separator;
      SL("CHOOSE ROBOT MODEL (permanent)");
      SL("  1) Combat    – RP 2, 1d8 dmg, extra attack every 3rd lvl (max 4)");
      SL("                 + 1 random combat special feature");
      SL("  2) Medical   – Medical Gel (1 HD heal, d4 Usage Die);");
      SL("                 once/day revive a dead ally (Luck roll)");
      SL("  3) Tracker   – complete darkness vision Nearby; Advantage tracking;");
      SL("                 cloaking (Invisible, d4 Usage Die); web beam");
      SL("  4) Diplomatic– no CHA Disadvantage; retractable blade hands;");
      SL("                 backstab: 2d6+level damage");
      robotModel := PickOption(4);
      S("  Robot Model: ");
      IF    robotModel = 1 THEN
        SL("Combat");
        S("  Combat special feature: ");
        RobotCombatFeature(d8(), buf);
        SL(buf)
      ELSIF robotModel = 2 THEN SL("Medical")
      ELSIF robotModel = 3 THEN SL("Tracker")
      ELSE                      SL("Diplomatic")
      END
    ELSIF classChoice = 2 THEN (* Beastman *)
      Separator;
      SL("MARK OF THE BEAST");
      animalRoll := d8() + d8();   (* 2d8 as per rules *)
      IF animalRoll = 16 THEN
        (* Roll twice and merge *)
        BeastAnimal(d8() + d8(), buf);
        BeastAnimal(d8() + d8(), buf2);
        S("  Animal type: "); S(buf); Out.Char('/'); SL(buf2); SL(" hybrid")
      ELSE
        BeastAnimal(animalRoll, buf);
        S("  Animal type: "); SL(buf)
      END;
      speciesRoll := d10();
      BeastSpecies(speciesRoll, buf);
      S("  Species name: "); SL(buf)
    ELSIF classChoice = 6 THEN (* Sorcerer *)
      Separator;
      SL("SORCERER APPEARANCE");
      skinRoll := d10();
      SorcSkinColor(skinRoll, buf);
      S("  Skin/Hair color: "); SL(buf);
      staffRoll := d10();
      SorcStaff(staffRoll, buf);
      S("  Staff: "); SL(buf)
    ELSIF classChoice = 7 THEN (* Urchin *)
      Separator;
      SL("TYPE OF URCHIN");
      SL("  1) Swamp    6) Badlands");
      SL("  2) Desert   (or roll randomly)");
      SL("  3) Sewer");
      SL("  4) Urban");
      SL("  5) Forest");
      SL("  7) Roll randomly");
      urchinRoll := PickOption(7);
      IF urchinRoll = 7 THEN urchinRoll := d6() END;
      UrchinType(urchinRoll, buf);
      UrchinBonus(urchinRoll, buf2);
      S("  Type: "); SL(buf);
      S("  Bonus: "); SL(buf2)
    END;

    (* ── Features ── *)
    PrintFeatures(classChoice);

    (* ── Equipment ── *)
    PrintEquipment(classChoice);

    (* ── Class-specific extras ── *)
    IF classChoice = 6 THEN PrintSorcSchools
    ELSIF classChoice = 3 THEN PrintDPMiracles
    END;

    (* ── Life event ── *)
    Separator;
    SL("BACKGROUND");
    lifeRoll := d8();
    LifeEvent(classChoice, lifeRoll, buf);
    S("  Life Event: "); SL(buf);

    trinketRoll := d6();
    Trinket(classChoice, trinketRoll, buf);
    S("  Trinket: "); SL(buf);

    (* ── Literacy ── *)
    Separator;
    SL("OTHER");
    IF (classChoice = 3) OR (classChoice = 6) OR (classChoice = 8) THEN
      SL("  Literacy: Always literate.")
    ELSIF int_ >= 13 THEN
      SL("  Literacy: Literate (INT >= 13).")
    ELSE
      SL("  Literacy: Illiterate (INT < 13).")
    END;
    S("  Languages: Common + 1 extra");
    IF int_ >= 14 THEN S("; INT 14+ allows a 3rd") END;
    IF int_ >= 17 THEN S(" and 4th") END;
    Ln;

    (* ── Summary ── *)
    Separator;
    SL("CHARACTER SUMMARY");
    ClassName(classChoice, buf);
    S("  Class: "); SL(buf);
    S("  HP: ");    I(hp);   SL(" (starting)");
    S("  Coins: "); I(coins); SL(" ceramic");
    S("  STR "); I(str);
    S("  DEX "); I(dex);
    S("  CON "); I(con);
    S("  INT "); I(int_);
    S("  WIS "); I(wis);
    S("  CHA "); I(cha);
    Ln;
    SL("  Weapon Damage:");
    IF classChoice = 1 THEN SL("    1d8 / 1d6 unarmed")
    ELSIF classChoice = 2 THEN SL("    1d8 / 1d6 improvised")
    ELSIF classChoice = 3 THEN SL("    1d6 / 1d4 unarmed")
    ELSIF classChoice = 4 THEN
      IF robotModel = 1 THEN SL("    1d8 / 1d6 (Combat model)")
      ELSE                    SL("    1d6 / 1d4 unarmed")
      END
    ELSIF classChoice = 5 THEN SL("    1d6 / 1d4 unarmed")
    ELSIF classChoice = 6 THEN SL("    1d4 / 1 unarmed; staff 1d4+1 energy")
    ELSIF classChoice = 7 THEN SL("    1d4 / 1 unarmed")
    ELSE                        SL("    1d6 / 1d4 unarmed; claws = class dmg")
    END;

    Separator

    END; (* IF mode = 1 *)

    Ln
  END
END BRECharGen.
