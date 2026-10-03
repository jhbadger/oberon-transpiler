# The Implementor's Guide: Getting Started with ZIL

ZIL (Zork Implementation Language) is a dialect of MDL (a Lisp derivative) used by Infocom in the 1980s to write classics like *Zork* and *The Hitchhiker's Guide to the Galaxy*. Today, thanks to the open-source **ZILF** project, you can write and compile ZIL code into Z-machine files playable on any modern interpreter.

This tutorial covers the basics of setting up a modern ZIL workflow while using classic Infocom programming concepts. Every example in this tutorial has been compiled, assembled, and actually played through an interpreter (`frotz`) to confirm it behaves as described — see section 21 for how to do the same with your own code.

## 1. Prerequisites and Setup (The Oberon Part)

This tutorial assumes you are using the Oberon port of Tara McGrew's ZILF (which still uses McGrew's zillib), but also works with original ZILF/ZAPF.

## 2. ZIL Syntax Basics

If you have ever looked at Lisp, ZIL will look familiar, but with a unique twist: Infocom used angle brackets `< >` for function evaluation instead of parentheses `( )`.

* **`< >` (Form):** Evaluates a function. `<TELL "Hello" CR>` calls the `TELL` function to print "Hello" and a carriage return.

* **`( )` (List):** Used for data grouping, defining object properties, or parameter lists.

* **`" "` (String):** Used for text.

* **`+ - * /`:** Standard math operators. `<+ 2 2>` evaluates to 4.

* **`;"..."` (Comment):** A semicolon tells the reader to read the next form and throw it away, so `;"a comment"` vanishes completely — it is not code, just a note to yourself. This matters more than it sounds like it should: see the warning box in section 10 for what goes wrong if you write a comment as `("a comment")` instead.

## 3. The Basic Boilerplate

Every ZIL game needs a starting point. Create a file called `zorkish.zil` and add this code. Note that we must include specific constants and the standard library `parser` so the compiler understands how to build a text adventure.

```zil
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
```

`<SETG USE-SCORING? T>` has to come *before* `<INSERT-FILE "parser">`, because the parser library only compiles in its scoring code (`V-SCORE`, the `SCORE` command, `AWARD-POINTS`, and so on) when that flag is already set. We won't use scoring until section 14, but the flag has to be set here, at the top of the file, before the library that reads it is loaded — setting it later, next to `MAX-SCORE`, is too late and `V-SCORE` will fail to compile with an "unrecognized builtin" error.

Placing the player for the first time uses `SETG HERE`/`MOVE`/`V-LOOK` rather than the more obvious-looking `<GOTO ,START-ROOM>`. You'll see `<GOTO ...>` used for movement all over real ZIL code (it's what the parser calls internally whenever the player walks somewhere), but `GOTO` also checks whether the player's *previous* location was a vehicle — a check that makes sense for an ordinary mid-game move, but not for the very first placement, when there is no previous location yet. Using `GOTO` for the initial placement anyway (a natural thing to reach for, since it's the "move the player" function) makes the interpreter print `Warning: @test_attr called with object 0 (PC = ...) (will ignore further occurrences)` on turn one, because that vehicle check runs against object 0. It's harmless — the real Cloak of Darkness sample game initializes the player exactly this same `SETG HERE`/`MOVE`/`V-LOOK` way, specifically to avoid it — but there's no reason to have it in the transcript at all, so this tutorial does what Cloak does. `V-LOOK` still correctly triggers the room's own `ACTION` routine with `M-LOOK` (via the library's `DESCRIBE-ROOM`), so `START-ROOM-F` below behaves identically either way.

## 4. Creating Rooms

In ZIL, everything in the game world is an `<OBJECT>`. Rooms and items are created using the same structure, just with different properties.

```zil
<ROOM START-ROOM
    (IN ROOMS)
    (DESC "Dusty Cellar")
    (FLAGS LIGHTBIT)
    (UP TO KITCHEN)
    (ACTION START-ROOM-F)>

<ROUTINE START-ROOM-F (RARG)
    <COND (<==? .RARG ,M-LOOK>
           <TELL "You are in a dusty, damp cellar. A wooden staircase leads up." CR>)>>
```

## 5. Creating Items

Now, let's put an item in the room that the player can interact with.

```zil
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
```

We'll extend `LANTERN-F` with `TURN ON`/`TURN OFF` handling in section 7 — an object only gets *one* `ACTION` routine, so as we add behavior for more verbs we add more clauses to the same `COND`, rather than writing a second `ROUTINE LANTERN-F`.

## 6. Connecting Rooms (Exits and Directions)

To connect rooms, you define directional properties like `UP`, `DOWN`, `NORTH`, etc., pointing to the destination room.

```zil
<ROOM KITCHEN
    (IN ROOMS)
    (DESC "Creepy Kitchen")
    (FLAGS LIGHTBIT)
    (DOWN TO START-ROOM)
    (ACTION KITCHEN-F)>

<ROUTINE KITCHEN-F (RARG)
    <COND (<==? .RARG ,M-LOOK>
           <TELL "You are in an abandoned kitchen. Stairs lead back down to the cellar." CR>)>>
```

## 7. Changing State (Flags)

You check flags with `FSET?`, add them with `FSET`, and remove them with `FCLEAR`. Here is the *complete*, final version of `LANTERN-F`, adding the on/off clauses to the one from section 5:

```zil
<ROUTINE LANTERN-F ()
    <COND (<VERB? EXAMINE>
           <TELL "It is a heavy brass lantern, currently turned off." CR>)

          (<VERB? TURN-ON>
           <COND (<FSET? ,BRASS-LANTERN ,LIGHTBIT>
                  <TELL "It is already on!" CR>)
                 (T
                  <FSET ,BRASS-LANTERN ,LIGHTBIT>
                  <TELL "The lantern flickers to life." CR>)>)

          (<VERB? TURN-OFF>
           <COND (<FSET? ,BRASS-LANTERN ,LIGHTBIT>
                  <FCLEAR ,BRASS-LANTERN ,LIGHTBIT>
                  <TELL "You turn off the lantern." CR>)
                 (T
                  <TELL "It is already off." CR>)>)>>
```

We're using `LIGHTBIT` itself as the "is it on" flag here, rather than a separate flag of our own invention. That's not an arbitrary choice — `LIGHTBIT` is the *same* flag the library checks everywhere it needs to know whether something is providing light, which matters a lot once a room can actually be dark. More on that next.

## 8. Darkness and Light Sources

So far, both of our rooms have `(FLAGS LIGHTBIT)`, so they're always lit and the lantern has never actually had to do any work. A room *without* `LIGHTBIT` is dark, and the library only considers the room lit if something with `LIGHTBIT` set is in scope — the player's own inventory included. That's exactly why section 7 had `TURN-ON`/`TURN-OFF` toggle `LIGHTBIT` directly on `BRASS-LANTERN`: it's not just recording "on" or "off" for our own messages, it's the actual flag the library's darkness check reads.

Let's add a room with no light of its own, reachable from the cellar:

```zil
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
```

`START-ROOM-F` also picks up a new `DOWN` sentence here — the whole point of adding an exit is for the player to know it's there, and a room description that never mentions it is the one thing the library can't fix for you (unlike the darkness message below, which *is* automatic). (`TOOLBIT` isn't about darkness — it's set up for section 14, which is what this key is actually *for*. Ignore it for now.)

Walk down into `DARK-PASSAGE` without a lit lantern and the library handles everything on its own: `LOOK` (and the room's own `DARK-PASSAGE-F`, which never even gets a chance to run) is replaced by `It is pitch black. You can't see a thing.`, and anything requiring you to see something in the room, like `TAKE KEY`, gives `It's too dark to see anything here.` No code of ours runs at all — the room's `ACTION` routine, and everything else the room might contain, is unreachable from darkness by default.

Take the lantern, turn it on, and go back down, and the room description shows normally — you'll need a light source to ever find that key.

### Reacting to Light Changing Mid-Turn

There's one more piece: what if the player is *standing in* the dark passage and turns the lantern off, or on? The library doesn't notice this automatically — turning a device's `LIGHTBIT` on or off is just a flag change as far as it's concerned. Two helper routines, `NOW-LIT?` and `NOW-DARK?`, do the actual re-checking and print the transition message, but the *game* has to call them after anything that might have changed the light in the room. Here's the complete, final `LANTERN-F`, adding those calls to the version from section 7:

```zil
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
```

The `<RTRUE>` at the end of each clause matters, and it's the same lesson as `TROLL-F`'s `<RFALSE>` in reverse. `NOW-LIT?` and `NOW-DARK?` only return true when they actually *did* something — if you turn the lantern on while already standing in a lit room, `NOW-LIT?` correctly does nothing and returns false. Without the `<RTRUE>` after it, that false value becomes `LANTERN-F`'s own return value, which tells the parser "I didn't handle this," and it goes on to run the library's own default `TURN ON` handler too — which doesn't know what a lantern is, and prints an unrelated `That's not something you can switch on and off.` right after the message you already printed. The `<RTRUE>` guarantees the clause always reports "handled," regardless of whether `NOW-LIT?`/`NOW-DARK?` had anything to say.

### Customizing the Darkness Message (Optional)

The stock `It is pitch black. You can't see a thing.` is a placeholder, not a tone. If you want the real Zork flavor (or your own), you can override the library's default with `REPLACE-DEFINITION` — but doing that for a section the library defines with `DEFAULT-DEFINITION` requires telling it *in advance*, before `<INSERT-FILE "parser">`, that you intend to replace it, with `DELAY-DEFINITION`:

```zil
<VERSION ZIP>
<CONSTANT RELEASEID 2>
<SETG USE-SCORING? T>
<DELAY-DEFINITION DARKNESS-F>
<INSERT-FILE "parser">
```

Without that line, the library inserts its own default `DARKNESS-F` the moment it's read (partway through loading `parser`), and by the time your own `REPLACE-DEFINITION` is reached later in the file, it's too late — you'll get `zilf: evaluation error: REPLACE-DEFINITION: section has already been inserted: DARKNESS-F`. With it, this works anywhere later in your file:

```zil
<REPLACE-DEFINITION DARKNESS-F
    <ROUTINE DARKNESS-F (ARG)
        <COND (<=? .ARG ,M-LOOK>
               <TELL "It is pitch black. You are likely to be eaten by a grue." CR>)
              (<=? .ARG ,M-SCOPE?>
               <T? <SCOPE-STAGE? VEHICLE GENERIC INVENTORY GLOBALS>>)
              (<=? .ARG ,M-NOW-DARK>
               <TELL "It suddenly gets dark in here." CR>)
              (<=? .ARG ,M-NOW-LIT>
               <TELL "The darkness recedes." CR CR>
               <RFALSE>)
              (ELSE <RFALSE>)>>>
```

The `M-SCOPE?`/`M-NOW-LIT` clauses are copied verbatim from the library's own default (see `DEFAULT-DEFINITION DARKNESS-F` in `verbs.zil`) — only the `M-LOOK` and `M-NOW-DARK` text actually changed here. That's deliberate: `M-SCOPE?` controls which objects are still reachable in the dark, and getting it wrong (rather than just leaving it alone) can silently change what commands work while the player can't see.

## 9. Custom Verbs

Creating a custom verb involves two steps: defining the **grammar** using the `SYNTAX` statement, and creating the **global action routine**.

```zil
<SYNTAX SMASH OBJECT = V-SMASH>

<ROUTINE V-SMASH ()
    <TELL "You hit the " D ,PRSO " as hard as you can, but nothing much happens." CR>>
```

Objects can intercept the verb in their `ACTION` routines before the global `V-SMASH` fires:

```zil
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
```

## 10. Non-Player Characters (NPCs)

In ZIL, an NPC is simply an `<OBJECT>` that has the `PERSONBIT` flag set. This flag tells the parser that this object is alive and can be talked to or given commands.

`HELLO` isn't a verb the standard library defines on its own, so if we want the troll to respond to it we have to add the grammar for it ourselves, exactly the way section 9 added `SMASH`:

```zil
<SYNTAX HELLO = V-HELLO>

<ROUTINE V-HELLO ()
    <TELL "Hello yourself!" CR>>
```

Now the troll itself:

```zil
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
```

`,WINNER` is normally the player, but the library changes it temporarily when the player gives an order to an NPC, so you can type `TROLL, HELLO` to make the troll say hello to *you*, or `TROLL, TAKE LAMP` to order it around. `<==? ,WINNER ,TROLL>` is how `TROLL-F` recognizes that it's currently being asked to carry out an order rather than being the direct object of the player's own command.

> **Warning — a comment in the wrong parentheses silently breaks your COND.** The first draft of `TROLL-F` wrote its two documentation notes like this (this is *not* real, complete code — a sketch of the mistake, not something to compile):
>
> &nbsp;&nbsp;&nbsp;&nbsp;`<COND`
> &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;`("Check if the player is giving a command to the Troll")`
> &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;`(<==? ,WINNER ,TROLL> <the HELLO handling from above>)`
> &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;`("Handling standard actions on the Troll")`
> &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;`(<VERB? EXAMINE> <the rest of the clauses...>)>`
>
> This compiles without error, and then silently does the wrong thing at runtime. `COND` evaluates each `(condition body...)` clause in order; if a clause's body is empty, the *condition itself* becomes the clause's value. A non-empty string is truthy — so `("some comment")` is a clause that is immediately true and returns that string, and `COND` stops right there, never reaching the real clauses after it. In the code above, `EXAMINE TROLL` never even got as far as checking `<VERB? EXAMINE>`: the "Handling standard actions on the Troll" clause fired first and swallowed everything after it.
>
> The fix is the `;"..."` comment syntax from section 2, used *outside* any clause's parentheses, as shown in the corrected listing above. `;"..."` is thrown away by the reader entirely and can never accidentally become a clause of its own.

Two more things worth testing once you've compiled this:

* **`TELL` returns false on purpose.** The `<VERB? TELL>` clause ends with `<RFALSE>`. Without it, `TROLL-F` would report the command as fully handled, which would stop the standard library's own `V-TELL` from ever running — and it's `V-TELL` that actually sets `,WINNER` to the troll in the first place. Leave out the `<RFALSE>` and `TROLL, HELLO` will print "The troll covers his ears..." and then silently do nothing else, because the order-giving mechanism never got a chance to engage.
* **Try it:** `TROLL, HELLO` should print *both* the "covers his ears" line (from the ordinary `TELL` handling, on the way to setting `,WINNER`) *and* "The troll growls, 'Leave me alone!'" (from the `,WINNER` branch, once the troll is actually the one being asked to say `HELLO`).

## 11. NPC Conversation Topics

`TELL <person> ABOUT <topic>` is the only topic-asking grammar zillib defines out of the box (there's no `ASK ... ABOUT` unless a game adds it itself). It's a separate verb from the plain `TELL` in section 10 — `V-TELL-ABOUT` rather than `V-TELL` — so it needs its own `<VERB? TELL-ABOUT>` clause, and the topic itself arrives as `,PRSI` (the "indirect object," the same slot a preposition's object fills in verbs like `PUT X IN Y`).

Add this clause to `TROLL-F`, alongside the others from section 10:

```zil
        ;"Topics the troll knows something about"
        (<VERB? TELL-ABOUT>
           <COND (<==? ,PRSI ,BRASS-LANTERN>
                  <TELL "The troll grunts. \"Yeah, I've got one of those too. Keeps the shadows back.\"" CR>)
                 (<==? ,PRSI ,SILVER-KEY>
                  <TELL "The troll's eyes narrow. \"Where'd you find THAT?\"" CR>)
                 (<==? ,PRSI ,TROLL>
                  <TELL "The troll snorts. \"Me? I'm a mystery, I am.\"" CR>)>)
```

Try `TELL TROLL ABOUT LANTERN`, `TELL TROLL ABOUT KEY` (you'll need to have actually picked the key up first — see section 8), `TELL TROLL ABOUT TROLL`, and then something *not* in the list, like `TELL TROLL ABOUT VASE`. That last one is the interesting case: none of the three `==?` checks match, so the inner `COND` falls through with no clause taken — evaluating to false — and `TROLL-F` returns false for the same reason `COIN-F`'s explicit `<RFALSE>` does in section 13. That lets the library's own default response run, and it's a genuinely good one: `The grumpy troll doesn't seem interested.` (it correctly names the object.) You get a sensible fallback for every topic you *haven't* written, for free, without writing an `(T ...)` catch-all clause yourself.

## 12. Containers

Containers allow objects to hold other objects. To make an object function as a container, you assign it the `CONTBIT` flag. You can also define a `CAPACITY` to limit how many items it can hold, and use `OPENBIT` to determine if it starts open or closed.

```zil
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
```

## 13. Scoring, Game Over, and Death

In a classic text adventure, the status line (in Version 3 games) automatically displays the current score and number of moves. Section 3's boilerplate already has everything scoring needs: `<SETG USE-SCORING? T>` before `<INSERT-FILE "parser">`, and `<CONSTANT MAX-SCORE 100>` telling the library the maximum possible score. We just haven't actually awarded any points yet.

### Awarding Points

The standard library tracks the score in a global variable called `SCORE`. You can update it using `<SETG>` (Set Global). Let's say taking the gold coin gives the player 10 points — this means `GOLD-COIN` needs its own `ACTION` routine now, so add `(ACTION COIN-F)` to the `OBJECT GOLD-COIN` from section 12:

```zil
<ROUTINE COIN-F ()
    <COND (<VERB? TAKE>
           "Check a custom flag to ensure we only award points once"
           <COND (<NOT <FSET? ,GOLD-COIN ,TOUCHBIT>>
                  <SETG SCORE <+ ,SCORE 10>>
                  <TELL "As you take the coin, you feel a sense of wealth! (10 points)" CR>)>
           "Return false so the standard TAKE routine still runs"
           <RFALSE>)>>
```

### Player Death (JIGS-UP)

Infocom games are famous for their sudden and creative deaths. The standard library provides a beautifully named routine for this: `JIGS-UP`. Calling `JIGS-UP` prints your death message, stops the current turn, and prompts the player to Restart, Restore, or Quit. You've already seen it in action — it's the same call `TROLL-F`'s `<VERB? ATTACK>` clause in section 10 makes.

### Winning the Game

There's no separate "you win" routine in zillib — `FINISH` and `V-QUIT` aren't real library functions. The idiomatic way real Infocom games end on a *win* is to call `JIGS-UP` with the victory text, exactly the same call used for death: `JIGS-UP` already prints the final score (via `V-SCORE`, now that scoring is turned on) and offers RESTART/RESTORE/QUIT, which is exactly what you want at the end of the game either way.

Let's put a door in the kitchen that ends the game when opened (section 14 will make it a locked door instead — this is the version before that):

```zil
<OBJECT TREASURE-DOOR
    (IN KITCHEN)
    (DESC "heavy door")
    (SYNONYM DOOR)
    (ADJECTIVE HEAVY)
    (FLAGS DOORBIT)
    (ACTION TREASURE-DOOR-F)>

<ROUTINE TREASURE-DOOR-F ()
    <COND (<VERB? OPEN>
           <JIGS-UP "You open the door and step into the sunlight. You have escaped!">)>>
```

Try it end to end: `OPEN CHEST`, `TAKE COIN`, `UP`, `OPEN DOOR` should take you from 0 to 10 points and then straight to the winning message, with the score shown correctly in the game-over screen. (Once you've added section 14's lock, you'll need the silver key from section 8 first — `TAKE LANTERN`, `TURN ON LANTERN`, `DOWN`, `TAKE KEY`, `UP`, `UP`, `UNLOCK DOOR WITH KEY`, `OPEN DOOR`.)

## 14. Locked Doors and Keys

Remember the silver key from the dark passage in section 8? Here's what it's for. `OPENABLEBIT` marks something as capable of being opened at all, and `LOCKEDBIT` marks it as currently locked; the standard library's `LOCK`/`UNLOCK` grammar is scoped specifically to objects with those flags:

```zil
<SYNTAX LOCK OBJECT (FIND OPENABLEBIT) (TOUCH) WITH OBJECT (FIND TOOLBIT) (HAVE HELD CARRIED) = V-LOCK>
<SYNTAX UNLOCK OBJECT (FIND LOCKEDBIT) (TOUCH) WITH OBJECT (FIND TOOLBIT) (HAVE HELD CARRIED) = V-UNLOCK>
```

(These two lines already exist in zillib — you don't write them yourself. They're shown here because they explain something you *do* need: the parser will only ever offer an object as the `WITH` object of `LOCK`/`UNLOCK` if it has `TOOLBIT` set, which is exactly why `SILVER-KEY` in section 8 already has `(FLAGS TAKEBIT TOOLBIT)`.) The default `V-LOCK`/`V-UNLOCK` themselves don't do anything useful — they're stubs, left for the game to override, the same as every other verb in this tutorial.

Update `TREASURE-DOOR` from section 13 to start locked. Here is the complete, final version of both:

```zil
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
```

Try `OPEN DOOR` before unlocking it: the inner `COND` in the `OPEN` clause has no `LOCKEDBIT`-still-set branch, falls through false, and `TREASURE-DOOR-F` returns false — letting the library's own `V-OPEN` take over, which already knows how to check `LOCKEDBIT` and prints `You'll have to unlock it first.` on its own. This is the same "return false and let the library handle it" pattern as the darkness message in section 8 and the topic fallback in section 11 — by this point in the tutorial it should start to feel like the normal way to write one of these routines, not a special trick.

You don't actually have to type the `WITH KEY` part. `UNLOCK`'s `SYNTAX` line requires a `WITH OBJECT`, but if you just type `UNLOCK DOOR` and leave it out, the parser's `GWIM` ("get what I mean") routine looks through everything you're holding for a single object with `TOOLBIT` set; if there's exactly one — which there is, since `SILVER-KEY` is the only such object here — it silently fills in `PRSI` with it, echoes `[with the silver key]` so you know what it assumed, and carries on. Try it: plain `UNLOCK DOOR` produces the same result as `UNLOCK DOOR WITH KEY`. This is also why `SILVER-KEY` needing `TOOLBIT` (from section 8) matters beyond just satisfying the `SYNTAX` line's `WITH OBJECT (FIND TOOLBIT)` clause — it's the exact flag `GWIM` searches for.

## 15. Daemons (Background Events)

Daemons (or Interrupt Routines) are functions that execute automatically at the end of every turn, or after a specific number of turns. They are perfect for countdowns, wandering monsters, or a hunger mechanic.

First, you define the routine you want to run. By convention, daemon routines start with `I-` (for Interrupt).

```zil
<GLOBAL HUNGER-LEVEL 0>

<ROUTINE I-HUNGER ()
    <SETG HUNGER-LEVEL <+ ,HUNGER-LEVEL 1>>
    <COND (<==? ,HUNGER-LEVEL 10>
           <TELL "Your stomach rumbles aggressively." CR>)
          (<==? ,HUNGER-LEVEL 20>
           <JIGS-UP "You have starved to death in the dungeon.">)>>
```

To activate the daemon, you add it to the game's event queue using the `<QUEUE>` function.
* `<QUEUE I-HUNGER 1>` runs it *once* on the very next turn.
* `<QUEUE I-HUNGER -1>` runs it *every single turn* continuously.
* `<QUEUE I-HUNGER 0>` removes it from the queue (disabling it).

Start the daemon in your `GO` routine, right after placing the player. Here is the complete, final version of `GO`, adding one line (`<QUEUE I-HUNGER -1>`) to the version from section 3:

```zil
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
```

Twenty turns of typing anything at all (even just `LOOK` repeatedly) should now end the game with the starvation message.

## 16. Vehicles

Vehicles allow the player to board an object and travel around while inside it (like the famous plastic boat in *Zork I*). To make an object a vehicle, you give it the `VEHBIT` flag. Since the player needs to be *inside* it, it also requires `CONTBIT` (container) and `OPENBIT` (open).

```zil
<OBJECT MAGIC-BOAT
    (IN START-ROOM)
    (DESC "magic boat")
    (SYNONYM BOAT)
    (ADJECTIVE MAGIC)
    (FLAGS VEHBIT CONTBIT OPENBIT)
    (CAPACITY 100)
    (ACTION BOAT-F)>
```

Because it has `VEHBIT`, the standard library will automatically allow the player to type `ENTER BOAT` or `GET IN BOAT`.

If you want to customize what happens when the player moves while inside the vehicle, you can intercept the movement verbs in the vehicle's action routine. For example, stopping them from walking without rowing:

```zil
<ROUTINE BOAT-F ()
    <COND (<VERB? WALK>
           <TELL "You can't walk while you're in the boat! You need to ROW it." CR>
           <RTRUE>)>>
```

Note that `WALK` needs an actual direction to reach this code at all — typing bare `WALK` makes the parser ask "Which way do you want to walk?" *before* any `ACTION` routine gets a chance to run, since the parser doesn't have a complete command yet. Test this one with `WALK NORTH` (or any other direction), not `WALK` by itself.

## 17. Pre-Actions and the Full Handling Order

Section 4's boilerplate noted that `PRSI`'s own `ACTION` routine gets the first crack at the input, then `PRSO`'s, then the verb default. There's a stop on that chain that runs *earlier* than any of them: a **pre-action**.

A pre-action is tied to a verb, not an object, named by convention `PRE-<verb>`, and wired up right on the `SYNTAX` line, after the verb default's name. This isn't a tutorial-only convention — it's the exact mechanism zillib itself uses; `<SYNTAX TAKE OBJECT (MANY IN-ROOM) FROM OBJECT (FIND CONTBIT) (TOUCH) = V-TAKE-FROM PRE-TAKE-FROM>` is a real line straight out of `verbs.zil`.

The point of a pre-action is to make one verb-wide check instead of repeating it in every object that verb might target. Here, smashing *anything* should require a hammer, and that check belongs in one place rather than copy-pasted into `VASE-F` and every smashable object added later:

```zil
<SYNTAX SMASH OBJECT = V-SMASH PRE-SMASH>

<ROUTINE PRE-SMASH ()
    <COND (<NOT <IN? ,HAMMER ,PLAYER>>
           <TELL "You'll need something solid to smash " T ,PRSO " with." CR>
           <RTRUE>)>>
```

```zil
<OBJECT HAMMER
    (IN START-ROOM)
    (DESC "heavy hammer")
    (SYNONYM HAMMER)
    (ADJECTIVE HEAVY)
    (FLAGS TAKEBIT)
    (DESCFCN HAMMER-D)>   ;"see section 18"
```

Try `SMASH VASE` before ever picking up the hammer: `PRE-SMASH` runs *before* `VASE-F` gets a chance, so the vase survives and you get the refusal message instead. `RTRUE` from a pre-action means exactly what it means from an `ACTION` routine — "fully handled, stop here" — so `VASE-F` never runs at all. Now `TAKE HAMMER` and try `SMASH VASE` again: `PRE-SMASH`'s predicate is false this time, the `COND` falls through, `PRE-SMASH` returns false, and the chain continues down to `VASE-F` exactly as it did back in section 9, unmodified.

> **Watch the spacing around tell-tokens.** `T ,PRSO` (and `A ,PRSO`) print `"the "`/`"a "` *followed by* the `DESC` — a trailing space, with no leading space of its own. The strings on either side have to supply their own spacing, or words run together. The first draft of `PRE-SMASH` wrote `"...to smash" T ,PRSO "with."`, which compiled fine and printed `You'll need something solid to smashthe porcelain vasewith.` The fix is the version above: a trailing space before the token, a leading space after it.

## 18. Dynamic Object Descriptions (DESCFCN)

An object's appearance in a room listing has, so far, used its `DESC` (plugged into a generic default) or a static `LDESC` for something more specific. Neither can change *mid-game* on its own. The `DESCFCN` property hands that job to a routine instead, so the exact same object can describe itself differently depending on what's happened so far:

```zil
<GLOBAL VASE-SMASHED <>>
```

Update `VASE-F` from section 9 to set it the moment the vase breaks (this is the complete, final version):

```zil
<ROUTINE VASE-F ()
    <COND (<VERB? SMASH>
           <SETG VASE-SMASHED T>
           <REMOVE ,VASE>
           <TELL "You smash the vase to pieces! It shatters all over the floor." CR>)>>
```

And `HAMMER-D`, the routine named in `HAMMER`'s `DESCFCN` property back in section 17:

```zil
<ROUTINE HAMMER-D ("OPTIONAL" ARG)
    <COND (<EQUAL? .ARG ,M-OBJDESC?>
           <RTRUE>)
          (,VASE-SMASHED
           <TELL "There is a heavy hammer here, its head chipped from smashing the vase." CR>)
          (T
           <TELL "There is a heavy hammer here." CR>)>>
```

`LOOK` while standing in `START-ROOM` prints "There is a heavy hammer here." the ordinary way. Now pick up the hammer, go smash the vase (section 17), come back and `DROP HAMMER`, then `LOOK` again — the exact same object now reports "its head chipped from smashing the vase," with no change at all to `HAMMER`'s `DESC`, `LDESC`, or any other static property.

> **A `DESCFCN` is called twice, and only one of those calls should ever print anything.** The describers first call it with the argument `M-OBJDESC?`, as a yes/no question: "will you be the one describing yourself?" Only if that returns true do they call it again, with `M-OBJDESC`, meaning "okay, go ahead." `HAMMER-D`'s first `COND` clause exists *only* to answer that question with `<RTRUE>` — which is the entire reason it checks for `M-OBJDESC?` instead of falling straight through to the `,VASE-SMASHED` clause. A routine that `TELL`s unconditionally, ignoring which constant it was actually handed, answers both calls by printing — once for the query, and once more for the real request. (Some real 1980s Infocom source, Zork I's own `BAT-D`, does exactly that, always `TELL`ing regardless of its argument — treat it as a historical oddity rather than a pattern worth copying; checking `M-OBJDESC?` explicitly, as `HAMMER-D` does, is the safe default.)

## 19. "Switch" Syntaxes

`GIVE HAMMER TO TROLL` and `GIVE TROLL THE HAMMER` mean the same thing, but they put `PRSO` and `PRSI` in opposite slots — in the first, `PRSO` is the hammer and `PRSI` is the troll; in the second, it's reversed. zillib already defines grammar for both phrasings — these two lines are real, straight out of `verbs.zil`, not something you write yourself:

```zil
<SYNTAX GIVE OBJECT (HAVE HELD CARRIED) TO OBJECT (FIND PERSONBIT) (TOUCH) = V-GIVE>
<SYNTAX GIVE OBJECT (FIND PERSONBIT) (TOUCH) OBJECT (HAVE HELD CARRIED) = V-SGIVE>
```

The second line is the "switch" syntax, recognizable by the naming convention — the ordinary verb's name with an `S` tacked on the front, `V-GIVE` → `V-SGIVE`. Its entire job is to swap `PRSO` and `PRSI` back and re-run the input as the first form, via `PERFORM` (the same routine from section 8 that `TROLL-F`'s `V-TELL`/`WINNER` dance in section 10 relies on):

```zil
<ROUTINE V-SGIVE ()
    <PERFORM ,V?GIVE ,PRSI ,PRSO>
    <RTRUE>>
```

Practical effect: you write handling once, for the `V-GIVE` phrasing, and the switched phrasing reaches the exact same code for free. Add this clause to `TROLL-F`, alongside the ones from sections 10 and 11:

```zil
        (<AND <VERB? GIVE> <==? ,PRSO ,HAMMER>>
           <MOVE ,HAMMER ,TROLL>
           <TELL "The troll's eyes light up. \"Finally, something useful!\" He snatches the hammer and stomps off into the shadows." CR>
           <RTRUE>)
```

Note that this clause checks `,PRSO`, not `,PRSI` — even though `TROLL-F` is running because the troll is `PRSI` (the recipient) under the ordinary `V-GIVE` phrasing. `V-SGIVE` already swapped `PRSO` and `PRSI` *before* calling `PERFORM`, so by the time any code in `TROLL-F` runs, the two globals have settled back into their `V-GIVE` meaning no matter which way the player actually typed it.

Try it: `TAKE HAMMER`, then either `GIVE HAMMER TO TROLL` or `GIVE TROLL THE HAMMER` — both print the identical "eyes light up" response and move the hammer out of your inventory and into the troll's. There's no second, parallel implementation anywhere that could quietly drift out of sync with the first.

## 20. Compiling Your Game

1. Compile the ZIL to ZAP, telling `zilf` where to find zillib and what to name the output:

   ```
   zilf -i /path/to/zillib zorkish.zil zorkish.zap
   ```

2. Assemble the ZAP into a playable Z-machine file:

   ```
   zapf zorkish.zap
   ```

This produces `zorkish.z3`, playable in any Z-machine interpreter (`frotz`, Lectrote, Gargoyle, etc.).

## 21. Testing Your Game

Compiling cleanly is not the same as working correctly — several of the bugs called out earlier in this tutorial (the `COND`-comment trap in section 10, the missing `<RFALSE>`/`<RTRUE>` calls) compiled without a single warning and only showed up once actually played. Get in the habit of playing through everything you add, not just re-reading it.

```
frotz zorkish.z3
```

runs the game interactively. If you're scripting a test (feeding it a fixed sequence of commands to check the output), pipe commands in and give it a timeout, since a game waiting on input will otherwise hang forever:

```
printf 'look\ntake lamp\nturn on lamp\n' | timeout 30 frotz -p zorkish.z3
```

Two `zilf` diagnostics are worth knowing on sight, since neither one is fatal and both are easy to misread as "my code is broken" when the real story is more specific:

* `zilf: warning: undefined global or constant 'FOO', using 0` — you referenced an atom (a verb constant, a dictionary word symbol, a flag) that was never actually defined anywhere the compiler could see, and it silently substituted `0`. This is *exactly* what happens if you use `<VERB? SOMEVERB>` for a verb with no matching `<SYNTAX>` line, or reference an object/flag before it's ever declared — the compile succeeds, but the check that uses the constant can never be true. If you see this, look for a missing `<SYNTAX>`, `<OBJECT>`, or `<CONSTANT>` for the exact name in the warning.
* `Warning: @test_attr called with object 0` (from the interpreter, not the compiler) — as covered in section 3, this means something called `GOTO` while the player had no location yet (typically the initial placement in `GO`). It's harmless if you see it, but this tutorial's own `GO` routine avoids it entirely by using `SETG HERE`/`MOVE`/`V-LOOK` for that first placement instead of `GOTO`.

## 22. Where to Go From Here

This tutorial's `zorkish.zil` is intentionally small. Once its patterns feel natural — `ACTION` routines intercepting verbs before the library's own, `RFALSE`/`RTRUE` controlling whether the library still gets a turn, flags for state — the best next step is reading real, complete games built the same way. A few, all buildable with the exact same `zilf`/`zapf` pipeline from section 20:

* **`cloak.zil`** (Cloak of Darkness) — a short, complete, winnable game, and the source of the `SETG HERE`/`MOVE`/`V-LOOK` startup idiom from section 3.
* **`advent.zil`** (Colossal Cave Adventure) — much bigger: multiple light sources, a maze, NPCs, real puzzles, and its own `REPLACE-DEFINITION DARKNESS-F` (with a warning about falling into pits in the dark) along the same lines as section 8's.
* **`zork1.zil`** — the real, unmodified 1980s *Zork I*, notable for using its own custom parser file instead of zillib's, which is a good way to see how much of what feels like "the language" is actually just library code you could replace.

All three of these are Version 3 (`<VERSION ZIP>`, same as this tutorial's game), which caps a story file at 128KB and limits you to 255 objects. If a bigger game outgrows that, `<VERSION EZIP>` (V4) or `<VERSION XZIP>` (V5) raise those limits and add features real V3 interpreters don't have (more attributes and properties per object, a proper status-line-free interface, sound in some interpreters). Making that jump isn't just changing one line, though — some things (like a room's exit encoding) change size on disk between versions — so it's worth doing once you have an actual reason (a real game that no longer fits), not preemptively.

A few things this tutorial deliberately left out, worth knowing exist: **pronouns** (`IT`, `HIM`, `HER`, `THEM` — the library already tracks these for you, see `PRONOUN` in `pronouns.zil`), **disambiguation** (what happens when two objects in scope match the same typed word — the parser already asks "which do you mean?" without any code from you), and `SCORING-ACHIEVEMENTS` (a way to award points in named, non-repeatable chunks rather than raw `SETG SCORE` arithmetic, documented right at the top of `scoring.zil`). The library's own doc comments, throughout `zillib`, are consistently better and more precise than any summary of them here — once a specific feature is what you need, going and reading the real routine's comment is usually faster than searching for a tutorial that covers it.

## Common Pitfalls Recap

A short list of the non-obvious traps this tutorial's own examples ran into, in case you hit their symptoms later in a bigger game:

* **A comment written as `("text")` inside a `COND` is a live clause, not a comment.** Use `;"text"` outside any clause's parentheses instead — see section 10.
* **An `ACTION` routine that "handles" a verb by returning non-`FALSE` stops the library's own handling for that verb from ever running.** If you want your extra text to *add to* the default behavior rather than replace it, end the clause with `<RFALSE>` (see `COIN-F` in section 13 and `TROLL-F`'s `TELL` clause in section 10) — or, if you called a helper like `NOW-LIT?`/`NOW-DARK?` last and it happened to return false because nothing needed to change, end with an explicit `<RTRUE>` instead (see `LANTERN-F` in section 8).
* **`LIGHTBIT` is not just documentation — it's the literal flag the library's darkness code reads.** A portable light source's on/off state has to be represented by toggling `LIGHTBIT` itself, not a separate flag of your own; giving an object `LIGHTBIT` permanently in its `FLAGS` list makes it provide light *regardless* of any on/off state you track separately.
* **Turning a light on or off mid-turn doesn't automatically announce the change.** Call `<NOW-LIT?>` or `<NOW-DARK?>` yourself right after the flag change for the "it suddenly gets dark"/"the darkness recedes" messages (and the room redescription) to happen.
* **Overriding a library `DEFAULT-DEFINITION` with your own `REPLACE-DEFINITION` requires a `<DELAY-DEFINITION NAME>` line *before* `<INSERT-FILE "parser">`.** Without it, the library's own default is already installed by the time your replacement is read, and you get `REPLACE-DEFINITION: section has already been inserted`.
* **Compilation flags like `USE-SCORING?` must be set before the library file that reads them is `INSERT-FILE`d**, not just before the feature is first used in your own code.
* **A verb doesn't exist for the parser to recognize just because you wrote `<VERB? SOMEVERB>` somewhere** — you need a `<SYNTAX>` line establishing the grammar first, exactly as for any other custom verb.
* **An object's `ACTION` routine does nothing if the object's own `(ACTION ...)` property was never actually set.** The routine itself compiles cleanly either way — nothing in the compiler can tell that nobody wired it up. (This is exactly what happened to this tutorial's own `GOLD-COIN` for a while: section 13's text always said to add `(ACTION COIN-F)`, but the property was missing from the actual object definition, so `COIN-F` silently never ran and taking the coin never scored any points.)
* **`T`/`A` tell-tokens print a trailing space before the `DESC`, never a leading one.** The strings on either side of the token have to supply their own spacing, or words run together — see section 17.
* **A `DESCFCN` is called once to ask whether it *will* describe the object, and only then again to actually do it.** `TELL`ing unconditionally, instead of checking for the `M-OBJDESC?` query first, prints the description twice — see section 18.
