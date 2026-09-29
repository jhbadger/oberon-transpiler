<VERSION XZIP>
<CONSTANT RELEASEID 1>
<SETG USE-SCORING? T>
<DELAY-DEFINITION DARKNESS-F>
<INSERT-FILE "parser">

<CONSTANT GAME-BANNER
"DERELICT ECHOES|
An Interactive Sci-Fi Mystery in ZIL">

<CONSTANT MAX-SCORE 50>

;"==========================================================================="
;" Syntax & Grammar Definitions"
;"==========================================================================="

<SYNTAX HELLO = V-HELLO>

<ROUTINE V-HELLO ()
    <TELL "You speak into the silence, but get no response." CR>>

;"Standard ZIL parser includes topic asking via TELL ABOUT"

;"==========================================================================="
;" Game Initialization & Setup"
;"==========================================================================="

<ROUTINE GO ()
    <CRLF>
    <TELL "ALERT: Primary power failure on Starlight Relay Alpha." CR>
    <TELL "You wake up on the deck floor, the station hum dead around you..." CR>
    <CRLF>
    <V-VERSION>

    <SETG HERE ,AIRLOCK>
    <MOVE ,PLAYER ,HERE>
    <V-LOOK>
    
    ;"Start the radiation hazard daemon running every turn"
    <QUEUE I-RADIATION -1>
    <MAIN-LOOP>>

;"==========================================================================="
;" Darkness Customization"
;"==========================================================================="

<REPLACE-DEFINITION DARKNESS-F
    <ROUTINE DARKNESS-F (ARG)
        <COND (<=? .ARG ,M-LOOK>
               <TELL "It is pitch black. The shadow of something monstrous looms unseen." CR>)
              (<=? .ARG ,M-SCOPE?>
               <T? <SCOPE-STAGE? VEHICLE GENERIC INVENTORY GLOBALS>>)
              (<=? .ARG ,M-NOW-DARK>
               <TELL "The light dies. Cold shadows swallow the corridor." CR>)
              (<=? .ARG ,M-NOW-LIT>
               <TELL "The gloom is forced back by light." CR CR>
               <RFALSE>)
              (ELSE <RFALSE>)>>>

;"==========================================================================="
;" Global Daemons & Hazards"
;"==========================================================================="

<GLOBAL RAD-LEVEL 0>

<ROUTINE I-RADIATION ()
    <SETG RAD-LEVEL <+ ,RAD-LEVEL 1>>
    <COND (<==? ,RAD-LEVEL 12>
           <TELL "Your Geiger counter clicks rapidly. Atmospheric seal breach imminent." CR>)
          (<==? ,RAD-LEVEL 25>
           <JIGS-UP "Radiation sickness overwhelms your central nervous system. You collapse onto the cold deck plates.">)>>

;"==========================================================================="
;" Room 1: Airlock (Lit Starting Room)"
;"==========================================================================="

<ROOM AIRLOCK
    (IN ROOMS)
    (DESC "Depressurized Airlock")
    (FLAGS LIGHTBIT)
    (EAST TO MED-BAY)
    (ACTION AIRLOCK-F)>

<ROUTINE AIRLOCK-F (RARG)
    <COND (<==? .RARG ,M-LOOK>
           <TELL "You are standing in the entry airlock of the derelict station. Emergency strips flicker weakly overhead. An inner hatchway leads east into the station interior." CR>)>>

<OBJECT FLASH-BATON
    (IN AIRLOCK)
    (DESC "plasma baton")
    (SYNONYM BATON LIGHT LAMP FLASH-BATON)
    (ADJECTIVE PLASMA FLASH)
    (FLAGS TAKEBIT)
    (ACTION BATON-F)>

<ROUTINE BATON-F ()
    <COND (<VERB? EXAMINE>
           <COND (<FSET? ,FLASH-BATON ,LIGHTBIT>
                  <TELL "The plasma baton burns with a bright, crackling blue beam." CR>)
                 (T
                  <TELL "A heavy plasma baton, currently deactivated." CR>)>)

          (<VERB? TURN-ON>
           <COND (<FSET? ,FLASH-BATON ,LIGHTBIT>
                  <TELL "It is already hummed to life!" CR>)
                 (T
                  <FSET ,FLASH-BATON ,LIGHTBIT>
                  <TELL "You snap the ignition switch. The plasma baton flares to life!" CR>
                  <NOW-LIT?>
                  <RTRUE>)>)

          (<VERB? TURN-OFF>
           <COND (<FSET? ,FLASH-BATON ,LIGHTBIT>
                  <FCLEAR ,FLASH-BATON ,LIGHTBIT>
                  <TELL "The plasma beam dies out." CR>
                  <NOW-DARK?>
                  <RTRUE>)
                 (T
                  <TELL "It is already off." CR>)>)>>

;"==========================================================================="
;" Room 2: Dark Corridor (Unlit Room)"
;"==========================================================================="

<ROOM DARK-CORRIDOR
    (IN ROOMS)
    (DESC "Dark Corridor")
    (WEST TO MED-BAY)
    (NORTH TO COMMAND-DECK)
    (ACTION DARK-CORRIDOR-F)>

<ROUTINE DARK-CORRIDOR-F (RARG)
    <COND (<==? .RARG ,M-LOOK>
           <TELL "You are in a long corridor scarred by claw marks and scorched bulkheads. The passage leads back west to the Med-Bay, and north toward the Command Deck." CR>)>>

<OBJECT ACCESS-CARD
    (IN DARK-CORRIDOR)
    (DESC "encrypted keycard")
    (SYNONYM CARD KEYCARD KEY)
    (ADJECTIVE ENCRYPTED ACCESS)
    (FLAGS TAKEBIT TOOLBIT)>

;"==========================================================================="
;" Room 3: Med-Bay (Home of the Friendly Android)"
;"==========================================================================="

<ROOM MED-BAY
    (IN ROOMS)
    (DESC "Med-Bay")
    (FLAGS LIGHTBIT)
    (WEST TO AIRLOCK)
    (EAST TO DARK-CORRIDOR)
    (ACTION MED-BAY-F)>

<ROUTINE MED-BAY-F (RARG)
    <COND (<==? .RARG ,M-LOOK>
           <TELL "Racked medical supplies lie shattered across the floor. An operational Android stands quietly beside a diagnostic bay. Exits lie west to the airlock and east to a dark hallway." CR>)>>

<OBJECT EVE
    (IN MED-BAY)
    (DESC "Eve the Synthetic")
    (SYNONYM EVE ANDROID SYNTHETIC FEMALE WOMAN)
    (ADJECTIVE FRIENDLY SYNTHETIC)
    (FLAGS PERSONBIT)
    (ACTION EVE-F)>

<ROUTINE EVE-F ()
    <COND
        ;"Commands directly to Eve"
        (<==? ,WINNER ,EVE>
           <COND (<VERB? HELLO>
                  <TELL "Eve offers a gentle smile. 'Hello, survivor. I am Eve, class-4 medical unit. How may I assist?'" CR>
                  <RTRUE>)
                 (T
                  <TELL "Eve tilted her head gently. 'My programming limits me from executing that directive.'" CR>
                  <RTRUE>)>)

        ;"Standard interactions with Eve"
        (<VERB? EXAMINE>
           <TELL "Eve is a sleek, friendly android with silver trim and expressive synthetic eyes. She seems undamaged by the catastrophe." CR>)

        (<VERB? TELL>
           <TELL "Eve tilts her head, listening intently." CR>
           <RFALSE>)

        (<VERB? TELL-ABOUT>
           <COND (<==? ,PRSI ,MONSTER>
                  <TELL "Eve winces. 'The specimen escaped containment on the lower decks. Its hide is resistant to kinetic fire, but light repels it!'" CR>)
                 (<==? ,PRSI ,ACCESS-CARD>
                  <TELL "Eve nods. 'The chief officer dropped his clearance card during the evacuation in the eastern hallway.'" CR>)
                 (<==? ,PRSI ,EVE>
                  <TELL "Eve smiles warm-heartedly. 'I was manufactured by Weyland-Yutani to safeguard station personnel.'" CR>)>)

        (<VERB? ATTACK>
           <TELL "Eve effortlessly sidesteps your strike. 'Violence will not resolve our predicament, human.'" CR>)>>

<OBJECT FIRST-AID-KIT
    (IN MED-BAY)
    (DESC "medical kit")
    (SYNONYM KIT MEDKIT PACKAGE)
    (ADJECTIVE FIRST-AID MEDICAL)
    (FLAGS CONTBIT TAKEBIT OPENBIT)
    (CAPACITY 10)>

<OBJECT STIM-PACK
    (IN FIRST-AID-KIT)
    (DESC "stimpack")
    (SYNONYM STIM STIMPACK HYPO)
    (ADJECTIVE HYPER)
    (FLAGS TAKEBIT)
    (ACTION STIM-PACK-F)>

<ROUTINE STIM-PACK-F ()
    <COND (<VERB? TAKE>
           <COND (<NOT <FSET? ,STIM-PACK ,TOUCHBIT>>
                  <SETG SCORE <+ ,SCORE 15>>
                  <TELL "You pocket the stimpack. You feel a sudden surge of hope! (+15 points)" CR>)>
           <RFALSE>)>>

;"==========================================================================="
;" Room 4: Command Deck (Monster & Security Gate)"
;"==========================================================================="

<ROOM COMMAND-DECK
    (IN ROOMS)
    (DESC "Command Deck Entrance")
    (FLAGS LIGHTBIT)
    (SOUTH TO DARK-CORRIDOR)
    (ACTION COMMAND-DECK-F)>

<ROUTINE COMMAND-DECK-F (RARG)
    <COND (<==? .RARG ,M-LOOK>
           <TELL "You stand before the main blast doors of the Bridge. A hulking monstrosity lurks near the terminal!" CR>)>>

<OBJECT MONSTER
    (IN COMMAND-DECK)
    (DESC "shadow xenomorph")
    (SYNONYM MONSTER XENOMORPH ALIEN BEAST)
    (ADJECTIVE SHADOW HULKING)
    (FLAGS PERSONBIT)
    (ACTION MONSTER-F)>

<ROUTINE MONSTER-F ()
    <COND (<VERB? EXAMINE>
           <TELL "A terrifying creature made of teeth, talons, and dark chitin. It hates bright light!" CR>)

          (<VERB? ATTACK>
           <COND (<FSET? ,FLASH-BATON ,LIGHTBIT>
                  <REMOVE ,MONSTER>
                  <SETG SCORE <+ ,SCORE 15>>
                  <TELL "You thrust the glowing plasma baton at the beast! Shrieking in pain from the blazing beam, the monster retreats into the ventilation shafts! (+15 points)" CR>)
                 (T
                  <JIGS-UP "You attempt to fight the beast barehanded. It lunges instantly, gutting you in single stroke.">)>)>>

<OBJECT ESCAPE-POD-DOOR
    (IN COMMAND-DECK)
    (DESC "pod hatch")
    (SYNONYM DOOR HATCH POD)
    (ADJECTIVE HEAVY BLAST ESCAPE)
    (FLAGS DOORBIT OPENABLEBIT LOCKEDBIT)
    (ACTION ESCAPE-POD-DOOR-F)>

<ROUTINE ESCAPE-POD-DOOR-F ()
    <COND (<VERB? OPEN>
           <COND (<IN? ,MONSTER ,COMMAND-DECK>
                  <JIGS-UP "As you reach for the hatch, the monster strikes you down from behind!">)
                 (<NOT <FSET? ,ESCAPE-POD-DOOR ,LOCKEDBIT>>
                  <SETG SCORE <+ ,SCORE 20>>
                  <JIGS-UP "You climb into the escape pod and jettison away from the station into safe orbit. You have survived! (Final Score: 50/50)">)>)

          (<VERB? UNLOCK>
           <COND (<==? ,PRSI ,ACCESS-CARD>
                  <FCLEAR ,ESCAPE-POD-DOOR ,LOCKEDBIT>
                  <TELL "You swipe the keycard through the door terminal. The blast door unlocks with a heavy hiss." CR>)>)>>
