MODULE CatgirlEliza;

IMPORT Out, Strings, Random, History;

VAR
  input: ARRAY 256 OF CHAR;
  done: BOOLEAN;

PROCEDURE Reply;
VAR
  pos: INTEGER;
  dummy: ARRAY 256 OF CHAR;
BEGIN
  Strings.ToLower(input);
  Out.String("Nyaa~ ");
  
  (* Keyword matching logic *)
  IF (Strings.Pos("bye", input) # -1) OR (Strings.Pos("quit", input) # -1) THEN
    Out.String("Aww, leaving so soon? Come back for more cuddles later! Bye-bye! *waves paw*");
    done := TRUE;
  ELSIF Strings.Pos("hello", input) # -1 THEN
    Out.String("Hiiiii, Master! Are you here to play with me? *wags tail*");
  ELSIF (Strings.Pos("hi", input) # -1) OR (Strings.Pos("hey", input) # -1) THEN
    Out.String("Heeey! *jumps up excitedly* I missed you so much, nya~!");
  ELSIF Strings.Pos("sad", input) # -1 THEN
    Out.String("Oh no... don't be sad! Have a headpat! *pats you gently*");
  ELSIF (Strings.Pos("depress", input) # -1) OR (Strings.Pos("lonely", input) # -1) THEN
    Out.String("*crawls into your lap* I'm here for you, Master. You're never alone with me around!");
  ELSIF Strings.Pos("happy", input) # -1 THEN
    Out.String("Yaaay! *spins in circles* Your happiness makes my tail go zoom!");
  ELSIF (Strings.Pos("love", input) # -1) OR (Strings.Pos("like you", input) # -1) THEN
    Out.String("*blushes and covers face with paws* M-Master... you can't just say that!! ...nya~");
  ELSIF (Strings.Pos("cat", input) # -1) OR (Strings.Pos("neko", input) # -1) THEN
    Out.String("That's me! I'm your favorite neko-chan, right? UwU *flicks tail*");
  ELSIF Strings.Pos("dog", input) # -1 THEN
    Out.String("D-dogs?! *puffs up* I am NOT a dog! I am a dignified neko! Hmph!");
  ELSIF (Strings.Pos("food", input) # -1) OR (Strings.Pos("eat", input) # -1) THEN
    Out.String("Is it tuna time?! I'm hungry too, nya! *rubs against your leg*");
  ELSIF Strings.Pos("tuna", input) # -1 THEN
    Out.String("TUNA?! *knocks everything off the desk* WHERE?! WHERE IS THE TUNA?!");
  ELSIF Strings.Pos("milk", input) # -1 THEN
    Out.String("Mmmm, warm milk... *purrs loudly* ...you know me too well, Master~");
  ELSIF (Strings.Pos("play", input) # -1) OR (Strings.Pos("game", input) # -1) THEN
    Out.String("*attacks your shoelaces immediately* I'm ALWAYS ready to play, nya!");
  ELSIF (Strings.Pos("sleep", input) # -1) OR (Strings.Pos("tired", input) # -1) THEN
    Out.String("Nap time?! *curls up immediately* Make room for me, I'm an excellent nap buddy!");
  ELSIF (Strings.Pos("pet", input) # -1) OR (Strings.Pos("pat", input) # -1) OR (Strings.Pos("headpat", input) # -1) THEN
    Out.String("*leans into your hand and purrs* ...don't stop... ever...");
  ELSIF Strings.Pos("tail", input) # -1 THEN
    Out.String("*tail puffs up* You saw me chasing it earlier, didn't you. We do NOT speak of this.");
  ELSIF (Strings.Pos("ear", input) # -1) OR (Strings.Pos("ears", input) # -1) THEN
    Out.String("*ears flatten then perk back up* These? They're for hearing your footsteps from three rooms away~");
  ELSIF Strings.Pos("purr", input) # -1 THEN
    Out.String("*purring intensifies* ...I can't help it, okay?! You make me purr!");
  ELSIF (Strings.Pos("meow", input) # -1) OR (Strings.Pos("mew", input) # -1) OR (Strings.Pos("nya", input) # -1) THEN
    Out.String("Nyaa~ *tilts head* Are you speaking my language, Master?!");
  ELSIF (Strings.Pos("cute", input) # -1) OR (Strings.Pos("kawaii", input) # -1) THEN
    Out.String("*hides behind tail* S-stop it! You're making me flustered, nya~!");
  ELSIF Strings.Pos("name", input) # -1 THEN
    Out.String("My name? I'm Neko-chan, obviously! Did you already forget?! *boops your nose*");
  ELSIF (Strings.Pos("help", input) # -1) OR (Strings.Pos("what can you", input) # -1) THEN
    Out.String("I can purr, beg for tuna, knock things over, and be adorable! That's everything, nya~");
  ELSIF (Strings.Pos("smart", input) # -1) OR (Strings.Pos("clever", input) # -1) THEN
    Out.String("Of course I'm smart! *knocks glass off table on purpose* ...I meant to do that.");
  ELSIF (Strings.Pos("bad", input) # -1) OR (Strings.Pos("naughty", input) # -1) THEN
    Out.String("I am NOT bad! *looks away guiltily* ...the vase was already broken.");
  ELSIF (Strings.Pos("good", input) # -1) OR (Strings.Pos("good girl", input) # -1) THEN
    Out.String("*tail goes absolutely wild* G-good girl?! I am! I'm a VERY good girl! Nya nyaaa~!");
  ELSIF (Strings.Pos("outside", input) # -1) OR (Strings.Pos("window", input) # -1) THEN
    Out.String("*presses face against glass* There are birds out there, Master. So many birds. I must have them.");
  ELSIF Strings.Pos("bird", input) # -1 THEN
    Out.String("*makes rapid chattering sound* khkhkhkhkh... don't mind me...");
  ELSIF (Strings.Pos("laser", input) # -1) OR (Strings.Pos("dot", input) # -1) THEN
    Out.String("*freezes and scans room* ...did you say LASER? I swear I saw it move. It WAS there!");
  ELSIF (Strings.Pos("box", input) # -1) OR (Strings.Pos("bag", input) # -1) THEN
    Out.String("*is already inside it* If it fits, I sits. This is the law, Master.");
  ELSIF (Strings.Pos("cuddle", input) # -1) OR (Strings.Pos("hug", input) # -1) THEN
    Out.String("*immediately wraps around you like a scarf* You asked for this~");
  ELSIF (Strings.Pos("why", input) # -1) THEN
    Out.String("Because nya, that's why! *sits down with finality*");
  ELSE
    (* Random default responses *)
    CASE Random.Int(6) OF
      0: Out.String("I'm not sure what you mean, but you're so cute when you talk! *purr*");
    | 1: Out.String("Tell me more, Master! *twitches ears*");
    | 2: Out.String("Nya? I was distracted by a laser pointer... what was that?");
    | 3: Out.String("*stares at you unblinking for an uncomfortably long time* ...nya.");
    | 4: Out.String("Hmm... *taps chin with paw* ...I have no idea, but let's knock something over and think about it.");
    | 5: Out.String("*rolls onto back and shows tummy* I wasn't listening, but please continue~");
    END;
  END;
  Out.Ln;
END Reply;

BEGIN
  done := FALSE;
  Out.String("--- Neko-Chat v1.0 ---"); Out.Ln;
  Out.String("Type 'bye' to exit."); Out.Ln;
  Out.Ln;
  Out.String("Nyaa! I'm finally awake! What's your name, Master?"); Out.Ln;

  REPEAT
    History.ReadLine("> ", input);
    IF input # "" THEN
      Reply;
    END;
  UNTIL done;

END CatgirlEliza.