MODULE Adventure;
(*
 * Two-word text adventure.
 *
 * You have broken into a wizard's tower to steal the Crystal Orb.
 *
 * Map:
 *           [VAULT]
 *              |
 *           [HALL]--W--[CELLAR]
 *              |
 *           [FOYER]--E--[STUDY]
 *
 * Commands: VERB NOUN  (e.g.  GO NORTH,  GET LANTERN,  USE KEY)
 *   GO / WALK / RUN   : NORTH SOUTH EAST WEST  (or N S E W)
 *   GET / TAKE        : item name
 *   DROP              : item name
 *   USE               : item name
 *   LOOK / EXAMINE    : (no noun needed)
 *   INVENTORY / INV   : list carried items
 *   HELP              : show commands
 *   QUIT / EXIT       : leave game
 *)

IMPORT In, Out, Strings;

CONST
  (* Rooms *)
  FOYER  = 0;
  STUDY  = 1;
  HALL   = 2;
  CELLAR = 3;
  VAULT  = 4;

  (* Directions *)
  N = 0;  S = 1;  E = 2;  W = 3;

  (* Items *)
  I_LANTERN = 0;
  I_KEY     = 1;
  I_SWORD   = 2;
  I_ORB     = 3;
  NITEMS    = 4;

  NONE = -1;
  INV  = -2;  (* item is in player's inventory *)

VAR
  room       : INTEGER;
  itemRoom   : ARRAY NITEMS OF INTEGER;
  vaultOpen  : BOOLEAN;
  playing    : BOOLEAN;
  line       : ARRAY 80 OF CHAR;
  verb, noun : ARRAY 32 OF CHAR;
  i          : INTEGER;
  c          : CHAR;


(* ── I/O helpers ─────────────────────────────────────────────────── *)

PROCEDURE P(s : ARRAY OF CHAR);
BEGIN  Out.String(s);  Out.Ln  END P;

PROCEDURE ReadLine;
(* Read one line into the global 'line' buffer, uppercase it. *)
VAR i : INTEGER;  c : CHAR;
BEGIN
  i := 0;
  In.Read(c);
  WHILE (c # 0AX) & (c # 0DX) & (c # 0X) DO
    IF i < LEN(line) - 1 THEN  line[i] := c;  INC(i)  END;
    In.Read(c)
  END;
  line[i] := 0X;
  Strings.ToUpper(line)
END ReadLine;

PROCEDURE ParseWords;
(* Split 'line' into verb and noun. *)
VAR i, j : INTEGER;
BEGIN
  i := 0;
  WHILE line[i] = ' ' DO  INC(i)  END;
  j := 0;
  WHILE (line[i] # ' ') & (line[i] # 0X) DO
    verb[j] := line[i];  INC(i);  INC(j)
  END;
  verb[j] := 0X;
  WHILE line[i] = ' ' DO  INC(i)  END;
  j := 0;
  WHILE (line[i] # ' ') & (line[i] # 0X) DO
    noun[j] := line[i];  INC(i);  INC(j)
  END;
  noun[j] := 0X
END ParseWords;

PROCEDURE Eq(a, b : ARRAY OF CHAR) : BOOLEAN;
BEGIN  RETURN Strings.Compare(a, b) = 0  END Eq;

PROCEDURE Is(a : ARRAY OF CHAR; c : CHAR) : BOOLEAN;
(* True if a is exactly the single character c *)
BEGIN  RETURN (a[0] = c) & (a[1] = 0X)  END Is;


(* ── World queries ───────────────────────────────────────────────── *)

PROCEDURE HasLantern() : BOOLEAN;
BEGIN  RETURN itemRoom[I_LANTERN] = INV  END HasLantern;

PROCEDURE Lit() : BOOLEAN;
(* Current room is visible *)
BEGIN
  RETURN (room = FOYER) OR (room = STUDY) OR HasLantern()
END Lit;

PROCEDURE ItemHere(it : INTEGER) : BOOLEAN;
BEGIN  RETURN itemRoom[it] = room  END ItemHere;

PROCEDURE Carrying(it : INTEGER) : BOOLEAN;
BEGIN  RETURN itemRoom[it] = INV  END Carrying;

PROCEDURE ItemName(it : INTEGER; VAR s : ARRAY OF CHAR);
BEGIN
  IF    it = I_LANTERN THEN COPY("lantern", s)
  ELSIF it = I_KEY     THEN COPY("brass key", s)
  ELSIF it = I_SWORD   THEN COPY("rusty sword", s)
  ELSE                      COPY("crystal orb", s)
  END
END ItemName;

PROCEDURE ItemByNoun(VAR it : INTEGER);
(* Find an item index matching the current noun. *)
BEGIN
  it := NONE;
  IF    Eq(noun, "LANTERN") OR Eq(noun, "LAMP")   THEN  it := I_LANTERN
  ELSIF Eq(noun, "KEY")  OR Eq(noun, "BRASSKEY")  THEN  it := I_KEY
  ELSIF Eq(noun, "SWORD") OR Eq(noun, "BLADE")    THEN  it := I_SWORD
  ELSIF Eq(noun, "ORB")  OR Eq(noun, "CRYSTAL")
        OR Eq(noun, "CRYSTALORB")                 THEN  it := I_ORB
  END
END ItemByNoun;


(* ── Room descriptions ───────────────────────────────────────────── *)

PROCEDURE ListItemsHere;
VAR it : INTEGER;  name : ARRAY 16 OF CHAR;
BEGIN
  FOR it := 0 TO NITEMS - 1 DO
    IF ItemHere(it) THEN
      Out.String("  There is a ");
      ItemName(it, name);
      Out.String(name);
      Out.String(" here.");
      Out.Ln
    END
  END
END ListItemsHere;

PROCEDURE DescRoom;
BEGIN
  IF ~Lit() THEN
    P("It is pitch dark.  You are likely to be eaten by a grue.");
    RETURN
  END;
  Out.Ln;
  CASE room OF
    FOYER :
      P("** FOYER **");
      P("You stand in the vaulted entrance of a crumbling wizard's tower.");
      P("Cobwebs fill the corners.  Exits lead NORTH and EAST.");
  | STUDY :
      P("** STUDY **");
      P("Floor-to-ceiling bookshelves groan under the weight of arcane tomes.");
      P("A heavy oak desk dominates the centre of the room.");
      P("Exit leads WEST.");
  | HALL :
      P("** HALL **");
      P("A long corridor runs through the heart of the tower.");
      P("The stones are slick with damp.  Exits: SOUTH, WEST.");
      IF vaultOpen THEN
        P("A heavy iron door to the NORTH stands open.")
      ELSE
        P("A heavy iron door to the NORTH bears a brass keyhole.")
      END
  | CELLAR :
      P("** CELLAR **");
      P("Low stone arches support the ceiling of this dank store-room.");
      P("Broken crates line the walls.  Exit leads EAST.");
  | VAULT :
      P("** VAULT **");
      P("The wizard's inner sanctum.  Runes blaze on every surface.");
      P("Exit leads SOUTH.")
  END;
  Out.Ln;
  ListItemsHere
END DescRoom;


(* ── Movement ────────────────────────────────────────────────────── *)

PROCEDURE ExitFor(dir : INTEGER) : INTEGER;
(* Returns destination room or NONE. *)
BEGIN
  CASE room OF
    FOYER  : IF dir = N THEN RETURN HALL  ELSIF dir = E THEN RETURN STUDY  END
  | STUDY  : IF dir = W THEN RETURN FOYER END
  | HALL   : IF dir = S THEN RETURN FOYER ELSIF dir = W THEN RETURN CELLAR
             ELSIF (dir = N) & vaultOpen   THEN RETURN VAULT
             ELSIF dir = N                 THEN RETURN NONE  (* locked *)
             END
  | CELLAR : IF dir = E THEN RETURN HALL  END
  | VAULT  : IF dir = S THEN RETURN HALL  END
  END;
  RETURN NONE
END ExitFor;

PROCEDURE DoGo;
VAR dir, dest : INTEGER;
BEGIN
  dir := NONE;
  IF Is(noun,'N') OR Eq(noun,"NORTH") THEN dir := N
  ELSIF Is(noun,'S') OR Eq(noun,"SOUTH") THEN dir := S
  ELSIF Is(noun,'E') OR Eq(noun,"EAST")  THEN dir := E
  ELSIF Is(noun,'W') OR Eq(noun,"WEST")  THEN dir := W
  END;
  IF dir = NONE THEN
    P("Go where?  (NORTH / SOUTH / EAST / WEST)");  RETURN
  END;
  IF (room = HALL) & (dir = N) & ~vaultOpen THEN
    P("The iron door is locked.  (Hint: USE KEY)");  RETURN
  END;
  dest := ExitFor(dir);
  IF dest = NONE THEN
    P("You can't go that way.");  RETURN
  END;
  IF (dest = HALL) OR (dest = CELLAR) THEN
    IF ~HasLantern() THEN
      P("It is pitch dark beyond that door.");
      P("You bump your head and retreat.  (Hint: GET LANTERN first)");
      RETURN
    END
  END;
  room := dest;
  DescRoom
END DoGo;


(* ── Item commands ───────────────────────────────────────────────── *)

PROCEDURE DoGet;
VAR it : INTEGER;  name : ARRAY 16 OF CHAR;
BEGIN
  ItemByNoun(it);
  IF it = NONE THEN  P("Get what?");  RETURN  END;
  IF ~ItemHere(it) THEN
    IF Carrying(it) THEN  P("You are already carrying that.")
    ELSE                  P("You don't see that here.")
    END;
    RETURN
  END;
  itemRoom[it] := INV;
  ItemName(it, name);
  Out.String("You pick up the ");
  Out.String(name);  Out.String(".");  Out.Ln;
  IF it = I_ORB THEN
    Out.Ln;
    P("The orb pulses with cold light in your hands.");
    P("You have what you came for.  Now get out alive.");
    Out.Ln
  END
END DoGet;

PROCEDURE DoDrop;
VAR it : INTEGER;  name : ARRAY 16 OF CHAR;
BEGIN
  ItemByNoun(it);
  IF it = NONE THEN  P("Drop what?");  RETURN  END;
  IF ~Carrying(it) THEN  P("You aren't carrying that.");  RETURN  END;
  itemRoom[it] := room;
  ItemName(it, name);
  Out.String("You set down the ");  Out.String(name);  Out.String(".");  Out.Ln
END DoDrop;

PROCEDURE DoUse;
VAR it : INTEGER;
BEGIN
  ItemByNoun(it);
  IF it = NONE THEN  P("Use what?");  RETURN  END;
  IF ~Carrying(it) THEN  P("You aren't carrying that.");  RETURN  END;
  IF it = I_LANTERN THEN
    P("The lantern is already lit, casting a warm glow.")
  ELSIF it = I_KEY THEN
    IF room = HALL THEN
      vaultOpen := TRUE;
      P("You turn the brass key in the lock.  The iron door swings open!")
    ELSE
      P("There's nothing here to unlock.")
    END
  ELSIF it = I_SWORD THEN
    P("You brandish the rusty sword heroically.  Nothing happens.")
  ELSIF it = I_ORB THEN
    P("The orb swirls with eldritch light but reveals no further secrets.")
  END
END DoUse;

PROCEDURE DoInventory;
VAR it, count : INTEGER;  name : ARRAY 16 OF CHAR;
BEGIN
  count := 0;
  FOR it := 0 TO NITEMS - 1 DO
    IF Carrying(it) THEN  INC(count)  END
  END;
  IF count = 0 THEN
    P("You are carrying nothing.");  RETURN
  END;
  P("You are carrying:");
  FOR it := 0 TO NITEMS - 1 DO
    IF Carrying(it) THEN
      Out.String("  a ");  ItemName(it, name);
      Out.String(name);  Out.Ln
    END
  END
END DoInventory;


(* ── Examine ─────────────────────────────────────────────────────── *)

PROCEDURE DoExamine;
VAR it : INTEGER;
BEGIN
  IF (noun[0] = 0X) OR Eq(noun, "ROOM") OR Eq(noun, "AROUND") THEN
    DescRoom;  RETURN
  END;
  ItemByNoun(it);
  IF it = NONE THEN  P("You don't see anything special.");  RETURN  END;
  IF ~ItemHere(it) & ~Carrying(it) THEN
    P("You don't see that here.");  RETURN
  END;
  IF it = I_LANTERN THEN
    P("A brass oil lantern.  The flame burns steadily.")
  ELSIF it = I_KEY THEN
    P("A small brass key.  One side has a crest: a tower inside a circle.")
  ELSIF it = I_SWORD THEN
    P("A short-sword, spotted with rust but still sharp at the tip.")
  ELSIF it = I_ORB THEN
    P("A sphere of pure crystal, the size of a grapefruit.");
    P("Tiny lightning-storms swirl inside it.")
  END
END DoExamine;


(* ── Win condition ───────────────────────────────────────────────── *)

PROCEDURE CheckWin() : BOOLEAN;
BEGIN
  RETURN (room = FOYER) & Carrying(I_ORB)
END CheckWin;


(* ── Help ────────────────────────────────────────────────────────── *)

PROCEDURE DoHelp;
BEGIN
  Out.Ln;
  P("Commands (two words, e.g.  GO NORTH  or  GET LANTERN):");
  P("  GO / WALK       NORTH SOUTH EAST WEST  (or N S E W)");
  P("  GET / TAKE      <item>   -- pick something up");
  P("  DROP            <item>   -- leave something here");
  P("  USE             <item>   -- use an item");
  P("  LOOK / EXAMINE  [item]   -- describe room or item");
  P("  INVENTORY / INV          -- list what you carry");
  P("  QUIT / EXIT              -- give up");
  Out.Ln
END DoHelp;


(* ── Main loop ───────────────────────────────────────────────────── *)

PROCEDURE Init;
BEGIN
  room := FOYER;
  itemRoom[I_LANTERN] := FOYER;
  itemRoom[I_KEY]     := STUDY;
  itemRoom[I_SWORD]   := CELLAR;
  itemRoom[I_ORB]     := VAULT;
  vaultOpen := FALSE;
  playing   := TRUE
END Init;

BEGIN
  Out.Ln;
  P("======================================================");
  P("  THE WIZARD'S TOWER  --  a two-word text adventure  ");
  P("======================================================");
  Out.Ln;
  P("Your mission: steal the Crystal Orb and escape with it");
  P("through the FOYER.  Type HELP for a list of commands.");
  Out.Ln;

  Init;
  DescRoom;

  WHILE playing DO
    Out.Ln;
    Out.String("> ");
    ReadLine;
    ParseWords;

    IF verb[0] = 0X THEN
      (* blank line, ignore *)
    ELSIF Eq(verb, "QUIT") OR Eq(verb, "EXIT") OR Eq(verb, "BYE") THEN
      playing := FALSE
    ELSIF Eq(verb, "HELP") OR Is(verb,'?') THEN
      DoHelp
    ELSIF Eq(verb, "INVENTORY") OR Eq(verb, "INV") OR Is(verb,'I') THEN
      DoInventory
    ELSIF Eq(verb, "LOOK") OR Is(verb,'L') OR Eq(verb, "EXAMINE") OR Is(verb,'X') THEN
      DoExamine
    ELSIF Eq(verb, "GO") OR Eq(verb, "WALK") OR Eq(verb, "RUN")
          OR Eq(verb, "MOVE") OR Eq(verb, "HEAD") THEN
      DoGo
    ELSIF Is(verb,'N') OR Eq(verb, "NORTH") THEN
      COPY("NORTH", noun);  DoGo
    ELSIF Is(verb,'S') OR Eq(verb, "SOUTH") THEN
      COPY("SOUTH", noun);  DoGo
    ELSIF Is(verb,'E') OR Eq(verb, "EAST") THEN
      COPY("EAST", noun);   DoGo
    ELSIF Is(verb,'W') OR Eq(verb, "WEST") THEN
      COPY("WEST", noun);   DoGo
    ELSIF Eq(verb, "GET") OR Eq(verb, "TAKE") OR Eq(verb, "PICK") THEN
      DoGet
    ELSIF Eq(verb, "DROP") OR Eq(verb, "LEAVE") OR Eq(verb, "PUT") THEN
      DoDrop
    ELSIF Eq(verb, "USE") OR Eq(verb, "UNLOCK") OR Eq(verb, "OPEN") THEN
      DoUse
    ELSIF Eq(verb, "ATTACK") OR Eq(verb, "KILL") OR Eq(verb, "HIT") THEN
      P("There's nothing here worth fighting.")
    ELSIF Eq(verb, "READ") THEN
      P("That's not something you can read.")
    ELSE
      Out.String("I don't understand '");  Out.String(verb);
      Out.String("'.  Type HELP for commands.");  Out.Ln
    END;

    IF playing THEN
      IF CheckWin() THEN
        Out.Ln;
        P("You burst through the tower doors into the cold night air,");
        P("the Crystal Orb blazing in your hands.");
        P("In the distance a bell begins to toll — the wizard has noticed.");
        P("But you are already gone.");
        Out.Ln;
        P("  *** YOU WIN! ***");
        Out.Ln;
        playing := FALSE
      END
    END
  END;

  Out.Ln;
  P("Farewell, adventurer.")
END Adventure.
