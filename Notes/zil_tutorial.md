# The Implementor's Guide: Getting Started with ZIL

ZIL (Zork Implementation Language) is a dialect of MDL (a Lisp derivative) used by Infocom in the 1980s to write classics like *Zork* and *The Hitchhiker's Guide to the Galaxy*. Today, thanks to the open-source **ZILF** project, you can write and compile ZIL code into Z-machine files playable on any modern interpreter.

This tutorial covers the basics of setting up a modern ZIL workflow while using classic Infocom programming concepts. Every example in this tutorial has been compiled, assembled, and actually played through an interpreter (`frotz`) to confirm it behaves as described — see section 15 for how to do the same with your own code.

## 1. Prerequisites and Setup (The Oberon Part)

This tutorial assumes you are using the Oberon port of Tara McGrew's ZILF (which still uses McGrew's zillib), but also works with original ZILF/ZAPF.

## 2. ZIL Syntax Basics

If you have ever looked at Lisp, ZIL will look familiar, but with a unique twist: Infocom used angle brackets `< >` for function evaluation instead of parentheses `( )`.

* **`< >` (Form):** Evaluates a function. `<TELL "Hello" CR>` calls the `TELL` function to print "Hello" and a carriage return.

* **`( )` (List):** Used for data grouping, defining object properties, or parameter lists.

* **`" "` (String):** Used for text.

* **`+ - * /`:** Standard math operators. `<+ 2 2>` evaluates to 4.

* **`;"..."` (Comment):** A semicolon tells the reader to read the next form and throw it away, so `;"a comment"` vanishes completely — it is not code, just a note to yourself. This matters more than it sounds like it should: see the warning box in section 9 for what goes wrong if you write a comment as `("a comment")` instead.

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
    <GOTO ,START-ROOM>

    "Start the standard ZIL parser/game loop"
    <MAIN-LOOP>>
```

`<SETG USE-SCORING? T>` has to come *before* `<INSERT-FILE "parser">`, because the parser library only compiles in its scoring code (`V-SCORE`, the `SCORE` command, `AWARD-POINTS`, and so on) when that flag is already set. We won't use scoring until section 11, but the flag has to be set here, at the top of the file, before the library that reads it is loaded — setting it later, next to `MAX-SCORE`, is too late and `V-SCORE` will fail to compile with an "unrecognized builtin" error.

When you first run this, you'll likely see a line like:

```
Warning: @test_attr called with object 0 (PC = ...) (will ignore further occurrences)
```

This is harmless. The very first time your game calls `GOTO`, the library checks whether the player is currently inside a vehicle by testing a flag on the player's *current location* — which doesn't exist yet, since the player hasn't been placed anywhere. Every zillib game prints this exact warning once, on its very first turn. It is not something your code did wrong.

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
    (FLAGS TAKEBIT LIGHTBIT)
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
           <COND (<FSET? ,BRASS-LANTERN ,ONBIT>
                  <TELL "It is already on!" CR>)
                 (T
                  <FSET ,BRASS-LANTERN ,ONBIT>
                  <TELL "The lantern flickers to life." CR>)>)

          (<VERB? TURN-OFF>
           <COND (<FSET? ,BRASS-LANTERN ,ONBIT>
                  <FCLEAR ,BRASS-LANTERN ,ONBIT>
                  <TELL "You turn off the lantern." CR>)
                 (T
                  <TELL "It is already off." CR>)>)>>
```

## 8. Custom Verbs

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

## 9. Non-Player Characters (NPCs)

In ZIL, an NPC is simply an `<OBJECT>` that has the `PERSONBIT` flag set. This flag tells the parser that this object is alive and can be talked to or given commands.

`HELLO` isn't a verb the standard library defines on its own, so if we want the troll to respond to it we have to add the grammar for it ourselves, exactly the way section 8 added `SMASH`:

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

> **Warning — a comment in the wrong parentheses silently breaks your COND.** The first draft of `TROLL-F` wrote its two documentation notes like this:
> ```zil
> <COND
>     ("Check if the player is giving a command to the Troll")
>     (<==? ,WINNER ,TROLL> ...)
>     ("Handling standard actions on the Troll")
>     (<VERB? EXAMINE> ...)
>     ...>
> ```
> This compiles without error, and then silently does the wrong thing at runtime. `COND` evaluates each `(condition body...)` clause in order; if a clause's body is empty, the *condition itself* becomes the clause's value. A non-empty string is truthy — so `("some comment")` is a clause that is immediately true and returns that string, and `COND` stops right there, never reaching the real clauses after it. In the code above, `EXAMINE TROLL` never even got as far as checking `<VERB? EXAMINE>`: the "Handling standard actions on the Troll" clause fired first and swallowed everything after it.
>
> The fix is the `;"..."` comment syntax from section 2, used *outside* any clause's parentheses, as shown in the corrected listing above. `;"..."` is thrown away by the reader entirely and can never accidentally become a clause of its own.

Two more things worth testing once you've compiled this:

* **`TELL` returns false on purpose.** The `<VERB? TELL>` clause ends with `<RFALSE>`. Without it, `TROLL-F` would report the command as fully handled, which would stop the standard library's own `V-TELL` from ever running — and it's `V-TELL` that actually sets `,WINNER` to the troll in the first place. Leave out the `<RFALSE>` and `TROLL, HELLO` will print "The troll covers his ears..." and then silently do nothing else, because the order-giving mechanism never got a chance to engage.
* **Try it:** `TROLL, HELLO` should print *both* the "covers his ears" line (from the ordinary `TELL` handling, on the way to setting `,WINNER`) *and* "The troll growls, 'Leave me alone!'" (from the `,WINNER` branch, once the troll is actually the one being asked to say `HELLO`).

## 10. Containers

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

## 11. Scoring, Game Over, and Death

In a classic text adventure, the status line (in Version 3 games) automatically displays the current score and number of moves. To make use of this, we already turned scoring on back in section 3 (`<SETG USE-SCORING? T>`, before `<INSERT-FILE "parser">`) — now we just need to tell the library the maximum possible score. Add this near the top of your file, alongside `GAME-BANNER`:

```zil
<CONSTANT MAX-SCORE 100>
```

### Awarding Points

The standard library tracks the score in a global variable called `SCORE`. You can update it using `<SETG>` (Set Global). Let's say taking the gold coin gives the player 10 points — this means `GOLD-COIN` needs its own `ACTION` routine now, so add `(ACTION COIN-F)` to the `OBJECT GOLD-COIN` from section 10:

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

Infocom games are famous for their sudden and creative deaths. The standard library provides a beautifully named routine for this: `JIGS-UP`. Calling `JIGS-UP` prints your death message, stops the current turn, and prompts the player to Restart, Restore, or Quit.

```zil
<ROUTINE TROLL-F ()
    <COND (<VERB? ATTACK>
           <JIGS-UP "The troll dodges your attack and crushes you with a single blow from his massive club.">)>>
```

### Winning the Game

There's no separate "you win" routine in zillib — `FINISH` and `V-QUIT` aren't real library functions. The idiomatic way real Infocom games end on a *win* is to call `JIGS-UP` with the victory text, exactly the same call used for death: `JIGS-UP` already prints the final score (via `V-SCORE`, now that scoring is turned on) and offers RESTART/RESTORE/QUIT, which is exactly what you want at the end of the game either way.

Let's put a door in the kitchen that ends the game when opened:

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

Try it end to end: `OPEN CHEST`, `TAKE COIN`, `UP`, `OPEN DOOR` should take you from 0 to 10 points and then straight to the winning message, with the score shown correctly in the game-over screen.

## 12. Daemons (Background Events)

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

Start the daemon in your `GO` routine, right after placing the player (add this line to the `GO` routine from section 3, between `<GOTO ,START-ROOM>` and `<MAIN-LOOP>`):

```zil
<ROUTINE GO ()
    ...
    <GOTO ,START-ROOM>
    <QUEUE I-HUNGER -1>
    <MAIN-LOOP>>
```

Twenty turns of typing anything at all (even just `LOOK` repeatedly) should now end the game with the starvation message.

## 13. Vehicles

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

## 14. Compiling Your Game

1. Compile the ZIL to ZAP, telling `zilf` where to find zillib and what to name the output:

   ```
   zilf -i /path/to/zillib zorkish.zil zorkish.zap
   ```

2. Assemble the ZAP into a playable Z-machine file:

   ```
   zapf zorkish.zap
   ```

This produces `zorkish.z3`, playable in any Z-machine interpreter (`frotz`, Lectrote, Gargoyle, etc.).

## 15. Testing Your Game

Compiling cleanly is not the same as working correctly — several of the bugs called out earlier in this tutorial (the `COND`-comment trap in section 9, the missing `<RFALSE>`) compiled without a single warning and only showed up once actually played. Get in the habit of playing through everything you add, not just re-reading it.

```
frotz zorkish.z3
```

runs the game interactively. If you're scripting a test (feeding it a fixed sequence of commands to check the output), pipe commands in and give it a timeout, since a game waiting on input will otherwise hang forever:

```
printf 'look\ntake lamp\nturn on lamp\n' | timeout 30 frotz -p zorkish.z3
```

Two `zilf` diagnostics are worth knowing on sight, since neither one is fatal and both are easy to misread as "my code is broken" when the real story is more specific:

* `zilf: warning: undefined global or constant 'FOO', using 0` — you referenced an atom (a verb constant, a dictionary word symbol, a flag) that was never actually defined anywhere the compiler could see, and it silently substituted `0`. This is *exactly* what happens if you use `<VERB? SOMEVERB>` for a verb with no matching `<SYNTAX>` line, or reference an object/flag before it's ever declared — the compile succeeds, but the check that uses the constant can never be true. If you see this, look for a missing `<SYNTAX>`, `<OBJECT>`, or `<CONSTANT>` for the exact name in the warning.
* `Warning: @test_attr called with object 0` (from the interpreter, not the compiler) — as covered in section 3, this specific one is a normal, one-time artifact of the very first `GOTO` in any zillib game, not a bug.

## Common Pitfalls Recap

A short list of the non-obvious traps this tutorial's own examples ran into, in case you hit their symptoms later in a bigger game:

* **A comment written as `("text")` inside a `COND` is a live clause, not a comment.** Use `;"text"` outside any clause's parentheses instead — see section 9.
* **An `ACTION` routine that "handles" a verb by returning non-`FALSE` stops the library's own handling for that verb from ever running.** If you want your extra text to *add to* the default behavior rather than replace it, end the clause with `<RFALSE>` (see `COIN-F` in section 11 and `TROLL-F`'s `TELL` clause in section 9).
* **Compilation flags like `USE-SCORING?` must be set before the library file that reads them is `INSERT-FILE`d**, not just before the feature is first used in your own code.
* **A verb doesn't exist for the parser to recognize just because you wrote `<VERB? SOMEVERB>` somewhere** — you need a `<SYNTAX>` line establishing the grammar first, exactly as for any other custom verb.
