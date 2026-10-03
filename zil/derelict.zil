<VERSION ZIP>
<CONSTANT RELEASEID 1>
<SETG USE-SCORING? T>
<DELAY-DEFINITION DARKNESS-F>
<INSERT-FILE "parser">

<CONSTANT GAME-BANNER
"DERELICT ECHOES|
An Interactive Sci-Fi Mystery in ZIL">

<CONSTANT MAX-SCORE 50>

;"Global Resource Tracking"
<GLOBAL POWER-LEVEL 100>
<GLOBAL RADIATION-TOLERANCE 25>

;"==========================================================================="
;" Syntax & Grammar Definitions"
;"==========================================================================="

<SYNTAX HELLO = V-HELLO>

<ROUTINE V-HELLO ()
    <TELL "You speak into the silence, but get no response." CR>>

<SYNTAX KISS OBJECT = V-KISS>

<SYNTAX LIGHT OBJECT (FIND DEVICEBIT) (TOUCH) = V-TURN-ON>

<ROUTINE V-KISS ()
    <TELL "That would be inappropriate." CR>>

;"Standard ZIL parser includes topic asking via TELL ABOUT"

<SYNTAX ASK OBJECT (FIND PERSONBIT) ABOUT OBJECT = V-ASK-ABOUT>

<ROUTINE V-ASK-ABOUT ()
    <TELL "That doesn't seem like something worth asking about." CR>>

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
    ;"Start the power drain daemon running every turn"
    <QUEUE I-POWER-DRAIN -1>
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

;"Routine to slowly drain station power"
<ROUTINE I-POWER-DRAIN ()
    <SETG POWER-LEVEL <- ,POWER-LEVEL 2>>
    <COND (<==? ,POWER-LEVEL 10>
           <TELL "The station lights flicker violently. Critical power levels detected!" CR>)
          (<==? ,POWER-LEVEL 0>
           <JIGS-UP "The station goes completely dark, and vital systems fail. You are stranded in the void.">)>>

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
    <COND (<==? ,POWER-LEVEL 0>
           <TELL "The airlock systems are dead. Emergency lighting has failed. You are trapped in absolute darkness." CR>)
          (<==? .RARG ,M-LOOK>
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
    (NORTH TO ENGINEERING-DECK)
    (ACTION MED-BAY-F)>

<ROUTINE MED-BAY-F (RARG)
    <COND (<==? .RARG ,M-LOOK>
           <TELL "Racked medical supplies lie shattered across the floor. An operational Android stands quietly beside a diagnostic bay. Exits lie west to the airlock, east to a dark hallway, and north through a heavy bulkhead door into Engineering." CR>)>>

<OBJECT EVE
    (IN MED-BAY)
    (DESC "Eve the Synthetic")
    (SYNONYM EVE ANDROID SYNTHETIC)
    (ADJECTIVE FRIENDLY SYNTHETIC)
    (FLAGS PERSONBIT CONTBIT FEMALEBIT)
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

        (<VERB? KISS>
           <TELL "Eve gently steps back, her expression remaining polite and calm. 'I am a class-4 medical unit, not a companion model. Romance is not part of my programming.'" CR>)

        (<VERB? TELL>
           <TELL "Eve tilts her head, listening intently." CR>
           <RFALSE>)

        (<VERB? TELL-ABOUT ASK-ABOUT>
           <COND (<==? ,PRSI ,MONSTER>
                  <TELL "Eve winces. 'The specimen escaped containment on the lower decks. Its hide is resistant to kinetic fire, but light repels it!'" CR>)
                 (<==? ,PRSI ,ACCESS-CARD>
                  <TELL "Eve nods. 'The chief officer dropped his clearance card during the evacuation in the eastern hallway.'" CR>)
                 (<==? ,PRSI ,EVE>
                  <TELL "Eve smiles warm-heartedly. 'I was manufactured by Weyland-Yutani to safeguard station personnel. I hold vital diagnostics on my internal drive.'" CR>)
                 (<==? ,PRSI ,DATA-CHIP>
                  <TELL "Eve scans the chip with a diagnostic lens. 'This is a primary system key. It holds the necessary override code for the Reactor Core.'" CR>)
                 (T
                  <TELL "Eve tilts her head. 'I don't have any information on that.'" CR>)>)

        (<VERB? ATTACK>
           <TELL "Eve effortlessly sidesteps your strike. 'Violence will not resolve our predicament, human.'" CR>)
           
        ;"NEW ACTION: Putting items into Eve"
        (<VERB? PUT>
           <COND (<IN? ,DATA-CHIP ,EVE>
                  <TELL "Eve accepts the chip with a slight whirring sound. 'Thank you. This will allow me to access restricted protocols.'" CR>
                  <RTRUE>)
                 (T
                  <TELL "Eve declines the chip; it does not fit her primary docking port." CR>
                  <RFALSE>)>)>>

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

;"NEW OBJECT: Critical Data Chip held by Eve"
<OBJECT DATA-CHIP
    (IN EVE)
    (DESC "corrupted data chip")
    (SYNONYM CHIP MODULE)
    (ADJECTIVE CRITICAL)
    (FLAGS TAKEBIT TOOLBIT)>

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
           <TELL "A terrifying creature made of teeth, talons, and dark chitin. It hates bright light and specialized electromagnetic pulses." CR>)

          (<VERB? ATTACK>
           <COND (<FSET? ,FLASH-BATON ,LIGHTBIT>
                  <REMOVE ,MONSTER>
                  <SETG SCORE <+ ,SCORE 15>>
                  <TELL "You thrust the glowing plasma baton at the beast! Shrieking in pain from the blazing beam, the monster retreats into the ventilation shafts! (+15 points)" CR>)
                 (<FSET? ,EMERGENCY-STUNNER ,HAS-STUNNER>
                  <REMOVE ,MONSTER>
                  <SETG SCORE <+ ,SCORE 25>>
                  <TELL "You deploy the stunner! The creature collapses into a stunned heap, defeated. (+25 points)" CR>)
                 (T
                  <JIGS-UP "You attempt to fight the beast barehanded. It lunges instantly, gutting you in single stroke.">)>)>>

;"NEW OBJECT: High-power item for the monster"
<OBJECT EMERGENCY-STUNNER
    (IN COMMAND-DECK)
    (DESC "EMERGENCY stunner")
    (SYNONYM STUNNER PULSE)
    (ADJECTIVE HIGH-POWER ELECTRIC)
    (FLAGS TAKEBIT TOOLBIT)>

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

;"==========================================================================="
;" Room 5: Engineering Deck (Power Grid & coolant hazard)"
;"==========================================================================="

<ROOM ENGINEERING-DECK
    (IN ROOMS)
    (DESC "Engineering Deck")
    (SOUTH TO MED-BAY)
    (DOWN TO REACTOR-CORE)
    (NORTH TO VENT-SHAFT)
    (ACTION ENGINEERING-DECK-F)>

<ROUTINE ENGINEERING-DECK-F (RARG)
    <COND (<==? .RARG ,M-LOOK>
           <TELL "Heavy coolant pipes line the steel walls, hiss-venting green vapor. High-voltage conduits run down toward the Reactor Core below, and a maintenance vent shaft opens to the north. South leads back to the Med-Bay." CR>)>>

<OBJECT FUSE-BOX
    (IN ENGINEERING-DECK)
    (DESC "breaker panel")
    (SYNONYM BOX PANEL BREAKER)
    (ADJECTIVE BREAKER ELECTRICAL COOLANT)
    (FLAGS CONTBIT OPENABLEBIT)
    (CAPACITY 5)
    (ACTION FUSE-BOX-F)>

<ROUTINE FUSE-BOX-F ()
    <COND (<VERB? OPEN>
           <COND (<FSET? ,FUSE-BOX ,OPENBIT>
                  <TELL "The breaker panel is already open." CR>)
                 (T
                  <FSET ,FUSE-BOX ,OPENBIT>
                  <TELL "You pull open the breaker panel, exposing the power bus." CR>
                  <RTRUE>)>)>>

<OBJECT FUSE
    (IN FUSE-BOX)
    (DESC "power relay fuse")
    (SYNONYM FUSE RELAY)
    (ADJECTIVE POWER HEAVY)
    (FLAGS TAKEBIT TOOLBIT)>

<OBJECT COOLANT-LEAK
    (IN ENGINEERING-DECK)
    (DESC "coolant leak")
    (SYNONYM LEAK VAPOR GAS PIPE)
    (ADJECTIVE GREEN TOXIC COOLANT)
    (ACTION COOLANT-LEAK-F)>

<ROUTINE COOLANT-LEAK-F ()
    <COND (<VERB? EXAMINE>
           <TELL "Corrosive coolant vapor vents from a ruptured pipe. Breathing it unprotected will quickly prove fatal." CR>)
          (<VERB? REPAIR SEAL FIX>
           <COND (<IN? ,SEALANT-CANISTER ,PLAYER>
                  <REMOVE ,COOLANT-LEAK>
                  <SETG SCORE <+ ,SCORE 10>>
                  <TELL "You spray thermal sealant over the breach. The hissing stops and the green vapor clears! (+10 points)" CR>)
                 (T
                  <TELL "You need some kind of industrial sealant to repair the pipe." CR>)>)>>

;"==========================================================================="
;" Room 6: Reactor Core (Deep Power Grid)"
;"==========================================================================="

<ROOM REACTOR-CORE
    (IN ROOMS)
    (DESC "Reactor Chamber")
    (UP TO ENGINEERING-DECK)
    (ACTION REACTOR-CORE-F)>

<ROUTINE REACTOR-CORE-F (RARG)
    <COND (<==? .RARG ,M-LOOK>
           <TELL "You stand on a metal catwalk suspended above the dormant containment vessel. A master sub-station terminal hums faintly. Metal stairs lead up to Engineering." CR>)>>

<OBJECT REACTOR-TERMINAL
    (IN REACTOR-CORE)
    (DESC "main reactor console")
    (SYNONYM TERMINAL CONSOLE PANEL REACTOR)
    (ADJECTIVE REACTOR MASTER MAIN)
    (FLAGS TOOLBIT)
    (ACTION REACTOR-TERMINAL-F)>

<ROUTINE REACTOR-TERMINAL-F ()
    <COND (<VERB? EXAMINE>
           <COND (<FSET? ,REACTOR-TERMINAL ,LIGHTBIT>
                  <TELL "The main reactor console is fully online, directing primary emergency power across the station! The station systems stabilize." CR>)
                 (<FSET? ,REACTOR-TERMINAL ,SYSTEM-ONLINE>
                  <TELL "The terminal display flashes: 'CRITICAL ERROR: RELAY FUSE MISSING.'">)
                 (T
                  <TELL "The terminal display flashes: 'SYSTEM CRITICAL: CORE DORMANT. DATA REQUIRED.'" CR>)>)

          (<VERB? REPAIR FIX>
           <COND (<IN? ,FUSE ,REACTOR-TERMINAL>
                  <FSET ,REACTOR-TERMINAL ,LIGHTBIT>
                  <SETG SCORE <+ ,SCORE 10>>
                  <TELL "You seat the heavy power relay fuse into the reactor bus. A low rumble shakes the floor as secondary power returns! (+10 points)" CR>)
                 (T
                  <TELL "The terminal is missing a primary relay fuse." CR>)>)

          ;"NEW ACTION: Inserting the chip"
          (<VERB? INSERT>
           <COND (<IN? ,DATA-CHIP ,PLAYER>
                  <COND (<NOT <FSET? ,REACTOR-TERMINAL ,SYSTEM-ONLINE>>
                         <SETG SCORE <+ ,SCORE 15>>
                         <SETG ,REACTOR-TERMINAL ,SYSTEM-ONLINE>
                         <TELL "The chip slides into the console slot. The main reactor hums to life! Primary power restored! (+15 points)" CR>)
                  (T
                   <TELL "The reactor console is already operating at full capacity." CR>)>)>)>>
"==========================================================================="
;" Room 7: Ventilation Shaft (Bypassing obstacles)"
;"==========================================================================="

<ROOM VENT-SHAFT
(IN ROOMS)
(DESC "Maintenance Vent Shaft")
(SOUTH TO ENGINEERING-DECK)
(NORTH TO COMMAND-DECK)
(ACTION VENT-SHAFT-F)>

<ROUTINE VENT-SHAFT-F (RARG)
<COND (<==? .RARG ,M-LOOK>
<TELL "A claustrophobic square tunnel running above the primary decks. Ducting leads south to Engineering and north directly behind the Command Deck blast doors." CR>)>>

<OBJECT SEALANT-CANISTER
(IN VENT-SHAFT)
(DESC "canister of thermal sealant")
(SYNONYM CANISTER SEALANT FOAM SPRAY)
(ADJECTIVE THERMAL INDUSTRIAL FOAM)
(FLAGS TAKEBIT TOOLBIT)
(ACTION SEALANT-CANISTER-F)>

<ROUTINE SEALANT-CANISTER-F ()
<COND (<VERB? EXAMINE>
<TELL "A pressurized canister of quick-curing thermal sealant foam." CR>)>>
