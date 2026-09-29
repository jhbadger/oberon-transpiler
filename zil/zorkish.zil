<VERSION ZIP>
<CONSTANT RELEASEID 2>
<SETG USE-SCORING? T>
<INSERT-FILE "parser">

<CONSTANT GAME-BANNER
"Zorkish|
A Simple ZIL example">

<CONSTANT MAX-SCORE 100>

"The GO routine is the entry point for your game"
<ROUTINE GO ()
    <CRLF>
    <TELL "Welcome to the interactive fiction tutorial!" CR>
    <CRLF>
    <V-VERSION> "Prints the standard library version and GAME-BANNER"

    "Initialize the player's starting location"
    <SETG HERE ,START-ROOM>
    <MOVE ,PLAYER ,HERE>
    <V-LOOK>

    "Start the standard ZIL parser/game loop"
    <MAIN-LOOP>>


<OBJECT BRASS-LANTERN
    (IN START-ROOM)
    (DESC "brass lantern")
    (SYNONYM LANTERN LAMP)
    (ADJECTIVE BRASS)
    (FLAGS TAKEBIT)
    (ACTION LANTERN-F)>

<ROUTINE LANTERN-F ()
    <COND (<VERB? EXAMINE>
           <TELL "It is a heavy brass lantern, currently turned off." CR>)>>

<ROOM KITCHEN
    (IN ROOMS)
    (DESC "Creepy Kitchen")
    (FLAGS LIGHTBIT)
    (DOWN TO START-ROOM)
    (ACTION KITCHEN-F)>

<ROUTINE KITCHEN-F (RARG)
    <COND (<==? .RARG ,M-LOOK>
           <TELL "You are in an abandoned kitchen. Stairs lead back down to the cellar." CR>)>>


<ROOM START-ROOM
    (IN ROOMS)
    (DESC "Dusty Cellar")
    (FLAGS LIGHTBIT)
    (UP TO KITCHEN)
    (DOWN TO DARK-PASSAGE)
    (ACTION START-ROOM-F)>

<ROUTINE START-ROOM-F (RARG)
    <COND (<==? .RARG ,M-LOOK>
           <TELL "You are in a dusty, damp cellar. A wooden staircase leads up, and a
narrow passage leads down into darkness." CR>)>>

<ROOM DARK-PASSAGE
    (IN ROOMS)
    (DESC "Dark Passage")
    (UP TO START-ROOM)
    (ACTION DARK-PASSAGE-F)>

<ROUTINE DARK-PASSAGE-F (RARG)
    <COND (<==? .RARG ,M-LOOK>
           <TELL "You are in a narrow passage carved out of the bare rock." CR>)>>

<OBJECT SILVER-KEY
    (IN DARK-PASSAGE)
    (DESC "silver key")
    (SYNONYM KEY)
    (ADJECTIVE SILVER)
    (FLAGS TAKEBIT TOOLBIT)>

<ROUTINE LANTERN-F ()
    <COND (<VERB? EXAMINE>
           <COND (<FSET? ,BRASS-LANTERN ,LIGHTBIT>
                  <TELL "It is a heavy brass lantern, currently turned on and glowing." CR>)
                 (T
                  <TELL "It is a heavy brass lantern, currently turned off." CR>)>)

          (<VERB? TURN-ON>
           <COND (<FSET? ,BRASS-LANTERN ,LIGHTBIT>
                  <TELL "It is already on!" CR>)
                 (T
                  <FSET ,BRASS-LANTERN ,LIGHTBIT>
                  <TELL "The lantern flickers to life." CR>
                  "Check whether this just lit up a dark room"
                  <NOW-LIT?>
                  <RTRUE>)>)

          (<VERB? TURN-OFF>
           <COND (<FSET? ,BRASS-LANTERN ,LIGHTBIT>
                  <FCLEAR ,BRASS-LANTERN ,LIGHTBIT>
                  <TELL "You turn off the lantern." CR>
                  "Check whether this just left the room dark"
                  <NOW-DARK?>
                  <RTRUE>)
                 (T
                  <TELL "It is already off." CR>)>)>>


<SYNTAX SMASH OBJECT = V-SMASH>

<ROUTINE V-SMASH ()
    <TELL "You hit the " D ,PRSO " as hard as you can, but nothing much happens." CR>>

<OBJECT VASE
    (IN KITCHEN)
    (DESC "porcelain vase")
    (SYNONYM VASE)
    (ADJECTIVE PORCELAIN)
    (FLAGS TAKEBIT)
    (ACTION VASE-F)>

<ROUTINE VASE-F ()
    <COND (<VERB? SMASH>
           <REMOVE ,VASE>
           <TELL "You smash the vase to pieces! It shatters all over the floor." CR>)>>


<SYNTAX HELLO = V-HELLO>

<ROUTINE V-HELLO ()
    <TELL "Hello yourself!" CR>>


<OBJECT TROLL
    (IN KITCHEN)
    (DESC "grumpy troll")
    (SYNONYM TROLL MONSTER)
    (ADJECTIVE GRUMPY)
    (FLAGS PERSONBIT)
    (ACTION TROLL-F)>

<ROUTINE TROLL-F ()
    <COND
        ;"Check if the player is giving a command to the Troll"
        (<==? ,WINNER ,TROLL>
           <COND (<VERB? HELLO>
                  <TELL "The troll growls, 'Leave me alone!'" CR>
                  <RTRUE>)
                 (T
                  <TELL "The troll glares at you and ignores your command." CR>
                  <RTRUE>)>)

        ;"Handling standard actions on the Troll"
        (<VERB? EXAMINE>
           <TELL "He looks very green and very angry." CR>)

        (<VERB? TELL>
           <TELL "The troll covers his ears and refuses to listen." CR>
           <RFALSE>)

        (<VERB? ATTACK>
           <JIGS-UP "The troll dodges your attack and crushes you with a single blow from his massive club.">)>>



<OBJECT WOODEN-CHEST
    (IN START-ROOM)
    (DESC "wooden chest")
    (SYNONYM CHEST BOX TRUNK)
    (ADJECTIVE WOODEN OLD)
    (FLAGS CONTBIT TAKEBIT)
    (CAPACITY 20)
    (ACTION CHEST-F)>

<ROUTINE CHEST-F ()
    <COND (<VERB? OPEN>
           <COND (<FSET? ,WOODEN-CHEST ,OPENBIT>
                  <TELL "The chest is already open." CR>)
                 (T
                  <FSET ,WOODEN-CHEST ,OPENBIT>
                  <TELL "You creak the heavy wooden lid open." CR>
                  <RTRUE>)>)
          (<VERB? CLOSE>
           <COND (<FSET? ,WOODEN-CHEST ,OPENBIT>
                  <FCLEAR ,WOODEN-CHEST ,OPENBIT>
                  <TELL "You slam the wooden chest shut." CR>)
                 (T
                  <TELL "The chest is already closed." CR>)>)>>

"To put an item inside a container, set its IN property to the container's name"
<OBJECT GOLD-COIN
    (IN WOODEN-CHEST)
    (DESC "gold coin")
    (SYNONYM COIN GOLD)
    (ADJECTIVE GOLD SHINY)
    (FLAGS TAKEBIT)>


<ROUTINE COIN-F ()
    <COND (<VERB? TAKE>
           "Check a custom flag to ensure we only award points once"
           <COND (<NOT <FSET? ,GOLD-COIN ,TOUCHBIT>>
                  <SETG SCORE <+ ,SCORE 10>>
                  <TELL "As you take the coin, you feel a sense of wealth! (10 points)" CR>)>
           "Return false so the standard TAKE routine still runs"
           <RFALSE>)>>


<SYNTAX LOCK OBJECT (FIND OPENABLEBIT) (TOUCH) WITH OBJECT (FIND TOOLBIT) (HAVE HELD CARRIED) = V-LOCK>
<SYNTAX UNLOCK OBJECT (FIND LOCKEDBIT) (TOUCH) WITH OBJECT (FIND TOOLBIT) (HAVE HELD CARRIED) = V-UNLOCK>


<OBJECT TREASURE-DOOR
    (IN KITCHEN)
    (DESC "heavy door")
    (SYNONYM DOOR)
    (ADJECTIVE HEAVY)
    (FLAGS DOORBIT OPENABLEBIT LOCKEDBIT)
    (ACTION TREASURE-DOOR-F)>

<ROUTINE TREASURE-DOOR-F ()
    <COND (<VERB? OPEN>
           <COND (<NOT <FSET? ,TREASURE-DOOR ,LOCKEDBIT>>
                  <JIGS-UP "You open the door and step into the sunlight. You have escaped!">)>)

          (<VERB? UNLOCK>
           <COND (<==? ,PRSI ,SILVER-KEY>
                  <FCLEAR ,TREASURE-DOOR ,LOCKEDBIT>
                  <TELL "You unlock the heavy door with the silver key." CR>)>)>>


<GLOBAL HUNGER-LEVEL 0>

<ROUTINE I-HUNGER ()
    <SETG HUNGER-LEVEL <+ ,HUNGER-LEVEL 1>>
    <COND (<==? ,HUNGER-LEVEL 10>
           <TELL "Your stomach rumbles aggressively." CR>)
          (<==? ,HUNGER-LEVEL 20>
           <JIGS-UP "You have starved to death in the dungeon.">)>>


<ROUTINE GO ()
    <CRLF>
    <TELL "Welcome to the interactive fiction tutorial!" CR>
    <CRLF>
    <V-VERSION>

    <SETG HERE ,START-ROOM>
    <MOVE ,PLAYER ,HERE>
    <V-LOOK>
    <QUEUE I-HUNGER -1>

    <MAIN-LOOP>>


<OBJECT MAGIC-BOAT
    (IN START-ROOM)
    (DESC "magic boat")
    (SYNONYM BOAT)
    (ADJECTIVE MAGIC)
    (FLAGS VEHBIT CONTBIT OPENBIT)
    (CAPACITY 100)
    (ACTION BOAT-F)>


<ROUTINE BOAT-F ()
    <COND (<VERB? WALK>
           <TELL "You can't walk while you're in the boat! You need to ROW it." CR>
           <RTRUE>)>>

