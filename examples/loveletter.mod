MODULE LoveLetter;
(*
 * Love Letter -- card game of risk, deduction, and courtly love.
 *
 * 2-4 players; player 1 is human, the rest are computer-controlled.
 * The computer players track publicly discarded cards and anything
 * revealed to them (via Priest/Baron/King) to weight their Guard
 * guesses and target choices -- simple but genuine card counting.
 *
 * Controls:
 *   SPACE       : draw a card on your turn
 *   1-9         : menu selections (which card, which target, which guess)
 *   ENTER       : play again after a game ends
 *   Q           : quit at any prompt
 *)

IMPORT Terminal, Out, Random, Strings;

CONST
  Guard = 0;  Priest = 1;  Baron = 2;  Handmaid = 3;
  Prince = 4;  King = 5;  Countess = 6;  Princess = 7;

  MaxPlayers = 4;
  HUMAN = 0;

  KeyEnter = 0DX;

  RowPrompt = 23;

TYPE
  PlayerRec = RECORD
    name         : ARRAY 20 OF CHAR;
    isHuman      : BOOLEAN;
    hand         : ARRAY 2 OF INTEGER;
    handCount    : INTEGER;
    out          : BOOLEAN;
    protected    : BOOLEAN;
    tokens       : INTEGER;
    discards     : ARRAY 16 OF INTEGER;
    discardCount : INTEGER
  END;

VAR
  players      : ARRAY MaxPlayers OF PlayerRec;
  numPlayers   : INTEGER;
  tokensToWin  : INTEGER;
  known        : ARRAY MaxPlayers, MaxPlayers OF INTEGER;
  deck         : ARRAY 16 OF INTEGER;
  deckTop      : INTEGER;
  removedCard  : INTEGER;
  faceUp       : ARRAY 3 OF INTEGER;
  faceUpCount  : INTEGER;
  currentPlayer: INTEGER;
  nextStarter  : INTEGER;
  roundNum     : INTEGER;
  logBuf       : ARRAY 4 OF STRING;
  wantQuit     : BOOLEAN;

(* ── Card data ──────────────────────────────────────────────── *)

PROCEDURE CardTotalCount(v : INTEGER) : INTEGER;
BEGIN
  IF v = Guard THEN RETURN 5
  ELSIF (v = Priest) OR (v = Baron) OR (v = Handmaid) OR (v = Prince) THEN RETURN 2
  ELSE RETURN 1
  END
END CardTotalCount;

PROCEDURE CardColor(v : INTEGER) : INTEGER;
BEGIN
  IF    v = Guard    THEN RETURN 250
  ELSIF v = Priest   THEN RETURN 45
  ELSIF v = Baron    THEN RETURN 196
  ELSIF v = Handmaid THEN RETURN 46
  ELSIF v = Prince   THEN RETURN 208
  ELSIF v = King     THEN RETURN 33
  ELSIF v = Countess THEN RETURN 213
  ELSE RETURN 226
  END
END CardColor;

PROCEDURE CardNameTo(v : INTEGER; VAR s : ARRAY OF CHAR);
BEGIN
  IF    v = Guard    THEN Strings.Copy("Guard", s)
  ELSIF v = Priest   THEN Strings.Copy("Priest", s)
  ELSIF v = Baron    THEN Strings.Copy("Baron", s)
  ELSIF v = Handmaid THEN Strings.Copy("Handmaid", s)
  ELSIF v = Prince   THEN Strings.Copy("Prince", s)
  ELSIF v = King     THEN Strings.Copy("King", s)
  ELSIF v = Countess THEN Strings.Copy("Countess", s)
  ELSE Strings.Copy("Princess", s)
  END
END CardNameTo;

PROCEDURE CardDescTo(v : INTEGER; VAR s : ARRAY OF CHAR);
BEGIN
  IF    v = Guard    THEN Strings.Copy("Name a card (not Guard) for a player; right guess = out.", s)
  ELSIF v = Priest   THEN Strings.Copy("Look at another player's hand.", s)
  ELSIF v = Baron    THEN Strings.Copy("Compare hands with another player; lower card is out.", s)
  ELSIF v = Handmaid THEN Strings.Copy("You are protected until your next turn.", s)
  ELSIF v = Prince   THEN Strings.Copy("Pick a player (self ok) to discard & draw a new card.", s)
  ELSIF v = King     THEN Strings.Copy("Trade hands with another player.", s)
  ELSIF v = Countess THEN Strings.Copy("Must discard this if you also hold King or Prince.", s)
  ELSE Strings.Copy("If you discard this, you are out of the round.", s)
  END
END CardDescTo;

(* ── String / log helpers ──────────────────────────────────── *)

PROCEDURE AppendInt(VAR s : ARRAY OF CHAR; n : INTEGER);
VAR t : STRING;
BEGIN Strings.IntToStr(n, t); Strings.Append(t, s) END AppendInt;

PROCEDURE AppendCardName(VAR s : ARRAY OF CHAR; v : INTEGER);
VAR t : STRING;
BEGIN CardNameTo(v, t); Strings.Append(t, s) END AppendCardName;

PROCEDURE AppendName(VAR s : ARRAY OF CHAR; p : INTEGER);
BEGIN Strings.Append(players[p].name, s) END AppendName;

(* "You" takes plural verb forms ("you play"), named players take singular ("Bea plays") *)
PROCEDURE AppendVerb(VAR s : ARRAY OF CHAR; p : INTEGER; sing, plur : ARRAY OF CHAR);
BEGIN
  IF p = HUMAN THEN Strings.Append(plur, s) ELSE Strings.Append(sing, s) END
END AppendVerb;

PROCEDURE AppendPossessive(VAR s : ARRAY OF CHAR; p : INTEGER);
BEGIN
  IF p = HUMAN THEN Strings.Append("your", s) ELSE AppendName(s, p); Strings.Append("'s", s) END
END AppendPossessive;

(* Used where target may equal actor (only Prince allows self-targeting) *)
PROCEDURE AppendTarget(VAR s : ARRAY OF CHAR; actor, target : INTEGER);
BEGIN
  IF target = actor THEN
    IF actor = HUMAN THEN Strings.Append("yourself", s) ELSE Strings.Append("themselves", s) END
  ELSE
    AppendName(s, target)
  END
END AppendTarget;

PROCEDURE ClearLog;
VAR i : INTEGER;
BEGIN FOR i := 0 TO 3 DO logBuf[i] := "" END END ClearLog;

PROCEDURE AddLog(s : ARRAY OF CHAR);
VAR i : INTEGER;
BEGIN
  FOR i := 0 TO 2 DO Strings.Copy(logBuf[i + 1], logBuf[i]) END;
  Strings.Copy(s, logBuf[3])
END AddLog;

(* ── Deck ───────────────────────────────────────────────────── *)

PROCEDURE BuildDeck;
VAR i, k : INTEGER;
BEGIN
  k := 0;
  FOR i := 1 TO 5 DO deck[k] := Guard; INC(k) END;
  FOR i := 1 TO 2 DO deck[k] := Priest; INC(k) END;
  FOR i := 1 TO 2 DO deck[k] := Baron; INC(k) END;
  FOR i := 1 TO 2 DO deck[k] := Handmaid; INC(k) END;
  FOR i := 1 TO 2 DO deck[k] := Prince; INC(k) END;
  deck[k] := King; INC(k);
  deck[k] := Countess; INC(k);
  deck[k] := Princess; INC(k)
END BuildDeck;

PROCEDURE ShuffleDeck;
VAR i, j, t : INTEGER;
BEGIN
  FOR i := 15 TO 1 BY -1 DO
    j := Random.Int(i + 1);
    t := deck[i]; deck[i] := deck[j]; deck[j] := t
  END
END ShuffleDeck;

(* ── Hand / discard mechanics ──────────────────────────────── *)

PROCEDURE FindCard(p, v : INTEGER) : INTEGER;
BEGIN
  IF players[p].hand[0] = v THEN RETURN 0
  ELSIF (players[p].handCount > 1) & (players[p].hand[1] = v) THEN RETURN 1
  ELSE RETURN -1
  END
END FindCard;

PROCEDURE MustDiscardCountess(p : INTEGER) : BOOLEAN;
VAR hasCountess, hasKP : BOOLEAN; i : INTEGER;
BEGIN
  hasCountess := FALSE; hasKP := FALSE;
  FOR i := 0 TO players[p].handCount - 1 DO
    IF players[p].hand[i] = Countess THEN hasCountess := TRUE END;
    IF (players[p].hand[i] = King) OR (players[p].hand[i] = Prince) THEN hasKP := TRUE END
  END;
  RETURN hasCountess & hasKP
END MustDiscardCountess;

PROCEDURE RemoveAndDiscard(p, idx : INTEGER) : INTEGER;
VAR card, i : INTEGER;
BEGIN
  card := players[p].hand[idx];
  players[p].discards[players[p].discardCount] := card;
  INC(players[p].discardCount);
  FOR i := idx TO players[p].handCount - 2 DO
    players[p].hand[i] := players[p].hand[i + 1]
  END;
  DEC(players[p].handCount);
  RETURN card
END RemoveAndDiscard;

PROCEDURE Eliminate(p : INTEGER);
VAR discarded : INTEGER;
BEGIN
  WHILE players[p].handCount > 0 DO
    discarded := RemoveAndDiscard(p, 0)
  END;
  players[p].out := TRUE
END Eliminate;

PROCEDURE DiscardSum(p : INTEGER) : INTEGER;
VAR j, sum : INTEGER;
BEGIN
  sum := 0;
  FOR j := 0 TO players[p].discardCount - 1 DO INC(sum, players[p].discards[j] + 1) END;
  RETURN sum
END DiscardSum;

PROCEDURE ActiveCount() : INTEGER;
VAR i, c : INTEGER;
BEGIN
  c := 0;
  FOR i := 0 TO numPlayers - 1 DO IF ~players[i].out THEN INC(c) END END;
  RETURN c
END ActiveCount;

PROCEDURE NextActive(p : INTEGER) : INTEGER;
VAR n : INTEGER;
BEGIN
  n := (p + 1) MOD numPlayers;
  WHILE players[n].out DO n := (n + 1) MOD numPlayers END;
  RETURN n
END NextActive;

(* ── AI card counting ──────────────────────────────────────── *)

PROCEDURE RemainingCount(forPlayer, v : INTEGER) : INTEGER;
VAR cnt, p, i : INTEGER;
BEGIN
  cnt := CardTotalCount(v);
  FOR i := 0 TO players[forPlayer].handCount - 1 DO
    IF players[forPlayer].hand[i] = v THEN DEC(cnt) END
  END;
  FOR p := 0 TO numPlayers - 1 DO
    FOR i := 0 TO players[p].discardCount - 1 DO
      IF players[p].discards[i] = v THEN DEC(cnt) END
    END
  END;
  FOR p := 0 TO numPlayers - 1 DO
    IF (p # forPlayer) & (known[forPlayer][p] = v) THEN DEC(cnt) END
  END;
  FOR i := 0 TO faceUpCount - 1 DO
    IF faceUp[i] = v THEN DEC(cnt) END
  END;
  IF cnt < 0 THEN cnt := 0 END;
  RETURN cnt
END RemainingCount;

PROCEDURE ChooseGuess(actor, target : INTEGER) : INTEGER;
VAR v, total, r, acc : INTEGER; weight : ARRAY 8 OF INTEGER;
BEGIN
  IF known[actor][target] >= 0 THEN RETURN known[actor][target] END;
  total := 0;
  FOR v := 1 TO 7 DO
    weight[v] := RemainingCount(actor, v);
    INC(total, weight[v])
  END;
  IF total <= 0 THEN RETURN Priest END;
  r := Random.Int(total);
  acc := 0;
  FOR v := 1 TO 7 DO
    INC(acc, weight[v]);
    IF r < acc THEN RETURN v END
  END;
  RETURN Priest
END ChooseGuess;

PROCEDURE AIChooseDiscardIndex(p : INTEGER) : INTEGER;
VAR pi : INTEGER;
BEGIN
  IF MustDiscardCountess(p) THEN RETURN FindCard(p, Countess) END;
  pi := FindCard(p, Princess);
  IF pi >= 0 THEN
    IF pi = 0 THEN RETURN 1 ELSE RETURN 0 END
  END;
  RETURN Random.Int(2)
END AIChooseDiscardIndex;

PROCEDURE AISelectTarget(actor, card : INTEGER; VAR cand : ARRAY OF INTEGER; n : INTEGER) : INTEGER;
VAR i, best, bestVal : INTEGER;
BEGIN
  IF card = Guard THEN
    FOR i := 0 TO n - 1 DO IF known[actor][cand[i]] = Princess THEN RETURN cand[i] END END;
    FOR i := 0 TO n - 1 DO IF known[actor][cand[i]] >= 0 THEN RETURN cand[i] END END
  ELSIF card = Baron THEN
    best := -1; bestVal := 99;
    FOR i := 0 TO n - 1 DO
      IF (known[actor][cand[i]] >= 0) & (known[actor][cand[i]] < bestVal) THEN
        bestVal := known[actor][cand[i]]; best := cand[i]
      END
    END;
    IF best >= 0 THEN RETURN best END
  ELSIF card = King THEN
    best := -1; bestVal := -1;
    FOR i := 0 TO n - 1 DO
      IF known[actor][cand[i]] > bestVal THEN bestVal := known[actor][cand[i]]; best := cand[i] END
    END;
    IF best >= 0 THEN RETURN best END
  ELSIF card = Prince THEN
    FOR i := 0 TO n - 1 DO IF known[actor][cand[i]] = Princess THEN RETURN cand[i] END END
  END;
  RETURN cand[Random.Int(n)]
END AISelectTarget;

(* ── Input helpers ─────────────────────────────────────────── *)

PROCEDURE ReadChoice(lo, hi : INTEGER) : INTEGER;
VAR key : CHAR; n : INTEGER;
BEGIN
  LOOP
    key := Terminal.ReadKey();
    IF (key = 'q') OR (key = 'Q') THEN wantQuit := TRUE; RETURN lo END;
    IF (key >= '1') & (key <= '9') THEN
      n := ORD(key) - ORD('0');
      IF (n >= lo) & (n <= hi) THEN RETURN n END
    END
  END
END ReadChoice;

PROCEDURE ContinuePrompt;
VAR key : CHAR;
BEGIN
  Terminal.Goto(1, RowPrompt); Terminal.Color256(8, 0);
  Out.String("-- Press any key to continue (Q to quit) --                    ");
  Terminal.Reset; Out.Flush;
  key := Terminal.ReadKey();
  IF (key = 'q') OR (key = 'Q') THEN wantQuit := TRUE END
END ContinuePrompt;

(* ── Board display ─────────────────────────────────────────── *)

PROCEDURE DrawBoard(revealHands : BOOLEAN);
VAR i, j, y : INTEGER; nm, ds : STRING;
BEGIN
  Terminal.Clear;
  Terminal.Color256(213, 0); Terminal.Goto(34, 1); Out.String("LOVE LETTER"); Terminal.Reset;

  Terminal.Color256(7, 0); Terminal.Goto(1, 3);
  Out.String("Round "); Out.Int(roundNum, 0);
  Out.String("   Cards left: "); Out.Int(16 - deckTop, 0);
  Out.String("   Tokens to win: "); Out.Int(tokensToWin, 0);
  Terminal.Reset;

  FOR i := 0 TO numPlayers - 1 DO
    y := 5 + i;
    Terminal.Goto(1, y);
    IF i = currentPlayer THEN
      Terminal.Color256(226, 0); Out.String("> ")
    ELSE
      Terminal.Color256(7, 0); Out.String("  ")
    END;
    Out.String(players[i].name);
    Out.String("  tokens:"); Out.Int(players[i].tokens, 0);
    IF players[i].out THEN
      Out.String("  [OUT]")
    ELSIF players[i].protected THEN
      Out.String("  [PROTECTED]")
    END;
    IF revealHands & ~players[i].out THEN
      Out.String("  hand: "); CardNameTo(players[i].hand[0], nm); Out.String(nm)
    END;
    Out.String("  discards:");
    FOR j := 0 TO players[i].discardCount - 1 DO
      Out.String(" "); Out.Int(players[i].discards[j] + 1, 0)
    END;
    Terminal.Reset
  END;

  IF numPlayers = 2 THEN
    Terminal.Goto(1, 10); Terminal.Color256(8, 0);
    Out.String("Face-up (unused): ");
    FOR i := 0 TO faceUpCount - 1 DO Out.Int(faceUp[i] + 1, 0); Out.String(" ") END;
    Terminal.Reset
  END;

  Terminal.Color256(7, 0); Terminal.Goto(1, 12); Out.String("Your hand:"); Terminal.Reset;
  FOR i := 0 TO players[HUMAN].handCount - 1 DO
    Terminal.Goto(3, 13 + i * 2);
    Terminal.Color256(CardColor(players[HUMAN].hand[i]), 0);
    CardNameTo(players[HUMAN].hand[i], nm);
    Out.String(nm); Out.String(" ("); Out.Int(players[HUMAN].hand[i] + 1, 0); Out.String(")");
    Terminal.Reset;
    Terminal.Goto(5, 14 + i * 2);
    Terminal.Color256(8, 0);
    CardDescTo(players[HUMAN].hand[i], ds); Out.String(ds);
    Terminal.Reset
  END;

  Terminal.Color256(7, 0); Terminal.Goto(1, 18); Out.String("Log:"); Terminal.Reset;
  FOR i := 0 TO 3 DO
    Terminal.Goto(3, 19 + i);
    Terminal.Color256(250, 0);
    Out.String(logBuf[i]);
    Terminal.Reset
  END;
  Out.Flush
END DrawBoard;

PROCEDURE ShowAndWait(revealHands : BOOLEAN);
BEGIN
  DrawBoard(revealHands);
  ContinuePrompt
END ShowAndWait;

(* ── Human choice menus ────────────────────────────────────── *)

PROCEDURE HumanChooseDiscardIndex(p : INTEGER) : INTEGER;
VAR i, c : INTEGER; nm, ds : STRING;
BEGIN
  Terminal.Clear;
  Terminal.Color256(226, 0); Terminal.Goto(1, 1); Out.String("Choose a card to play"); Terminal.Reset;
  FOR i := 0 TO 1 DO
    Terminal.Goto(1, 3 + i * 3);
    Terminal.Color256(CardColor(players[p].hand[i]), 0);
    Out.String("["); Out.Int(i + 1, 0); Out.String("] ");
    CardNameTo(players[p].hand[i], nm);
    Out.String(nm); Out.String("  ("); Out.Int(players[p].hand[i] + 1, 0); Out.String(")");
    Terminal.Reset;
    Terminal.Goto(5, 4 + i * 3);
    Terminal.Color256(8, 0);
    CardDescTo(players[p].hand[i], ds); Out.String(ds);
    Terminal.Reset
  END;
  Terminal.Goto(1, 10); Terminal.Color256(7, 0);
  Out.String("Press 1 or 2 to choose."); Terminal.Reset; Out.Flush;
  c := ReadChoice(1, 2);
  RETURN c - 1
END HumanChooseDiscardIndex;

PROCEDURE HumanSelectTarget(VAR cand : ARRAY OF INTEGER; n : INTEGER) : INTEGER;
VAR i, c : INTEGER;
BEGIN
  Terminal.Clear;
  Terminal.Color256(226, 0); Terminal.Goto(1, 1); Out.String("Choose a target"); Terminal.Reset;
  FOR i := 0 TO n - 1 DO
    Terminal.Goto(1, 3 + i * 2);
    Terminal.Color256(7, 0);
    Out.String("["); Out.Int(i + 1, 0); Out.String("] "); Out.String(players[cand[i]].name);
    Out.String("   tokens: "); Out.Int(players[cand[i]].tokens, 0);
    Terminal.Reset
  END;
  Terminal.Goto(1, 4 + n * 2); Terminal.Color256(7, 0);
  Out.String("Press a number to choose target."); Terminal.Reset; Out.Flush;
  c := ReadChoice(1, n);
  RETURN cand[c - 1]
END HumanSelectTarget;

PROCEDURE HumanChooseGuess() : INTEGER;
VAR i, c : INTEGER; nm : STRING;
BEGIN
  Terminal.Clear;
  Terminal.Color256(226, 0); Terminal.Goto(1, 1); Out.String("Guard: name a card (not Guard)"); Terminal.Reset;
  FOR i := 1 TO 7 DO
    Terminal.Goto(1, 2 + i);
    Terminal.Color256(CardColor(i), 0);
    Out.String("["); Out.Int(i, 0); Out.String("] ");
    CardNameTo(i, nm); Out.String(nm);
    Out.String("  ("); Out.Int(i + 1, 0); Out.String(")");
    Terminal.Reset
  END;
  Terminal.Goto(1, 12); Terminal.Color256(7, 0);
  Out.String("Press 1-7 to guess."); Terminal.Reset; Out.Flush;
  c := ReadChoice(1, 7);
  RETURN c
END HumanChooseGuess;

(* ── Target selection dispatcher ───────────────────────────── *)

PROCEDURE SelectTarget(actor, card : INTEGER) : INTEGER;
VAR candidates : ARRAY MaxPlayers OF INTEGER; nCand, i : INTEGER;
BEGIN
  nCand := 0;
  FOR i := 0 TO numPlayers - 1 DO
    IF (i # actor) & ~players[i].out & ~players[i].protected THEN
      candidates[nCand] := i; INC(nCand)
    END
  END;
  IF card = Prince THEN
    candidates[nCand] := actor; INC(nCand)
  END;
  IF nCand = 0 THEN RETURN -1 END;
  IF players[actor].isHuman THEN
    RETURN HumanSelectTarget(candidates, nCand)
  ELSE
    RETURN AISelectTarget(actor, card, candidates, nCand)
  END
END SelectTarget;

(* ── Card effects ──────────────────────────────────────────── *)

PROCEDURE EffectGuard(actor : INTEGER);
VAR target, guess : INTEGER; s : STRING;
BEGIN
  target := SelectTarget(actor, Guard);
  IF target = -1 THEN
    s := ""; AppendName(s, actor); AppendVerb(s, actor, " plays Guard, but no valid target.", " play Guard, but no valid target.");
    AddLog(s); RETURN
  END;
  IF players[actor].isHuman THEN guess := HumanChooseGuess() ELSE guess := ChooseGuess(actor, target) END;
  s := ""; AppendName(s, actor); AppendVerb(s, actor, " guesses ", " guess "); AppendCardName(s, guess);
  Strings.Append(" for ", s); AppendName(s, target); Strings.Append(".", s);
  AddLog(s);
  IF players[target].hand[0] = guess THEN
    s := ""; AppendName(s, target); AppendVerb(s, target, " had it and is out!", " had it and are out!");
    AddLog(s);
    Eliminate(target)
  ELSE
    s := "Wrong -- "; AppendName(s, target); AppendVerb(s, target, " is safe.", " are safe.");
    AddLog(s)
  END
END EffectGuard;

PROCEDURE EffectPriest(actor : INTEGER);
VAR target : INTEGER; s, nm : STRING;
BEGIN
  target := SelectTarget(actor, Priest);
  IF target = -1 THEN
    s := ""; AppendName(s, actor); AppendVerb(s, actor, " plays Priest, but no valid target.", " play Priest, but no valid target.");
    AddLog(s); RETURN
  END;
  known[actor][target] := players[target].hand[0];
  s := ""; AppendName(s, actor); AppendVerb(s, actor, " peeks at ", " peek at "); AppendPossessive(s, target); Strings.Append(" hand.", s);
  IF actor = HUMAN THEN
    Strings.Append(" (", s); CardNameTo(players[target].hand[0], nm); Strings.Append(nm, s); Strings.Append(")", s)
  END;
  AddLog(s)
END EffectPriest;

PROCEDURE EffectBaron(actor : INTEGER);
VAR target, ac, tc : INTEGER; s, nm : STRING;
BEGIN
  target := SelectTarget(actor, Baron);
  IF target = -1 THEN
    s := ""; AppendName(s, actor); AppendVerb(s, actor, " plays Baron, but no valid target.", " play Baron, but no valid target.");
    AddLog(s); RETURN
  END;
  ac := players[actor].hand[0]; tc := players[target].hand[0];
  known[actor][target] := tc; known[target][actor] := ac;
  s := ""; AppendName(s, actor); AppendVerb(s, actor, " compares hands with ", " compare hands with "); AppendName(s, target); Strings.Append(".", s);
  IF (actor = HUMAN) OR (target = HUMAN) THEN
    Strings.Append(" (", s); AppendName(s, actor); Strings.Append(": ", s); CardNameTo(ac, nm); Strings.Append(nm, s);
    Strings.Append(" vs ", s); AppendName(s, target); Strings.Append(": ", s); CardNameTo(tc, nm); Strings.Append(nm, s);
    Strings.Append(")", s)
  END;
  AddLog(s);
  IF ac > tc THEN
    s := ""; AppendName(s, target); AppendVerb(s, target, " loses and is out.", " lose and are out."); AddLog(s);
    Eliminate(target)
  ELSIF tc > ac THEN
    s := ""; AppendName(s, actor); AppendVerb(s, actor, " loses and is out.", " lose and are out."); AddLog(s);
    Eliminate(actor)
  ELSE
    AddLog("It's a tie -- no one is out.")
  END
END EffectBaron;

PROCEDURE EffectHandmaid(actor : INTEGER);
VAR s : STRING;
BEGIN
  players[actor].protected := TRUE;
  s := ""; AppendName(s, actor); AppendVerb(s, actor, " is protected until their next turn.", " are protected until your next turn.");
  AddLog(s)
END EffectHandmaid;

PROCEDURE EffectPrince(actor : INTEGER);
VAR target, card, p : INTEGER; s : STRING;
BEGIN
  target := SelectTarget(actor, Prince);
  card := RemoveAndDiscard(target, 0);
  s := ""; AppendName(s, actor); AppendVerb(s, actor, " makes ", " make "); AppendTarget(s, actor, target);
  Strings.Append(" discard ", s); AppendCardName(s, card); Strings.Append(".", s);
  AddLog(s);
  IF card = Princess THEN
    s := ""; AppendName(s, target); AppendVerb(s, target, " discarded the Princess and is out!", " discarded the Princess and are out!");
    AddLog(s);
    Eliminate(target)
  ELSE
    IF deckTop < 16 THEN
      players[target].hand[0] := deck[deckTop]; INC(deckTop)
    ELSE
      players[target].hand[0] := removedCard
    END;
    players[target].handCount := 1;
    FOR p := 0 TO numPlayers - 1 DO known[p][target] := -1 END;
    s := ""; AppendName(s, target); AppendVerb(s, target, " draws a new card.", " draw a new card.");
    AddLog(s)
  END
END EffectPrince;

PROCEDURE EffectKing(actor : INTEGER);
VAR target, oldActor, oldTarget, p : INTEGER; s : STRING;
BEGIN
  target := SelectTarget(actor, King);
  IF target = -1 THEN
    s := ""; AppendName(s, actor); AppendVerb(s, actor, " plays King, but no valid target.", " play King, but no valid target.");
    AddLog(s); RETURN
  END;
  oldActor := players[actor].hand[0];
  oldTarget := players[target].hand[0];
  players[actor].hand[0] := oldTarget;
  players[target].hand[0] := oldActor;
  FOR p := 0 TO numPlayers - 1 DO known[p][actor] := -1; known[p][target] := -1 END;
  known[actor][target] := oldActor;
  known[target][actor] := oldTarget;
  s := ""; AppendName(s, actor); AppendVerb(s, actor, " trades hands with ", " trade hands with "); AppendName(s, target); Strings.Append(".", s);
  AddLog(s)
END EffectKing;

PROCEDURE ResolveEffect(actor, card : INTEGER);
BEGIN
  IF    card = Guard    THEN EffectGuard(actor)
  ELSIF card = Priest   THEN EffectPriest(actor)
  ELSIF card = Baron    THEN EffectBaron(actor)
  ELSIF card = Handmaid THEN EffectHandmaid(actor)
  ELSIF card = Prince   THEN EffectPrince(actor)
  ELSIF card = King     THEN EffectKing(actor)
  END
  (* Countess has no effect; Princess is handled by the caller *)
END ResolveEffect;

(* ── Turn / round flow ─────────────────────────────────────── *)

PROCEDURE PlayTurn(p : INTEGER);
VAR idx, card : INTEGER; key : CHAR; s : STRING;
BEGIN
  players[p].protected := FALSE;

  IF players[p].isHuman THEN
    DrawBoard(FALSE);
    Terminal.Goto(1, RowPrompt); Terminal.Color256(7, 0);
    Out.String("Your turn. Press SPACE to draw a card (Q to quit).           ");
    Terminal.Reset; Out.Flush;
    LOOP
      key := Terminal.ReadKey();
      IF (key = 'q') OR (key = 'Q') THEN wantQuit := TRUE; RETURN END;
      IF key = ' ' THEN EXIT END
    END
  END;

  players[p].hand[players[p].handCount] := deck[deckTop]; INC(deckTop);
  INC(players[p].handCount);

  IF MustDiscardCountess(p) THEN
    idx := FindCard(p, Countess);
    s := ""; AppendName(s, p); Strings.Append(" must discard the Countess.", s); AddLog(s)
  ELSIF players[p].isHuman THEN
    idx := HumanChooseDiscardIndex(p)
  ELSE
    idx := AIChooseDiscardIndex(p)
  END;

  card := RemoveAndDiscard(p, idx);

  s := ""; AppendName(s, p); AppendVerb(s, p, " plays ", " play "); AppendCardName(s, card); Strings.Append(".", s);
  AddLog(s);

  IF card = Princess THEN
    s := ""; AppendName(s, p); AppendVerb(s, p, " discarded the Princess and is out!", " discarded the Princess and are out!");
    AddLog(s);
    Eliminate(p)
  ELSE
    ResolveEffect(p, card)
  END;

  ShowAndWait(FALSE)
END PlayTurn;

PROCEDURE StartRound;
VAR i, j : INTEGER; s : STRING;
BEGIN
  INC(roundNum);
  BuildDeck; ShuffleDeck;
  deckTop := 0;
  removedCard := deck[deckTop]; INC(deckTop);

  IF numPlayers = 2 THEN
    faceUpCount := 3;
    FOR i := 0 TO 2 DO faceUp[i] := deck[deckTop]; INC(deckTop) END
  ELSE
    faceUpCount := 0
  END;

  FOR i := 0 TO numPlayers - 1 DO
    players[i].out := FALSE;
    players[i].protected := FALSE;
    players[i].discardCount := 0;
    players[i].hand[0] := deck[deckTop]; INC(deckTop);
    players[i].handCount := 1;
    FOR j := 0 TO numPlayers - 1 DO known[i][j] := -1 END
  END;

  IF nextStarter = -1 THEN currentPlayer := Random.Int(numPlayers) ELSE currentPlayer := nextStarter END;

  ClearLog;
  s := "Round "; AppendInt(s, roundNum); Strings.Append(" begins.", s);
  AddLog(s)
END StartRound;

PROCEDURE ResolveRoundEnd(byDeckEmpty : BOOLEAN);
VAR i, best, bestSum, sum, nWinners, nWinners2 : INTEGER;
    winners, winners2 : ARRAY MaxPlayers OF INTEGER;
    s : STRING;
BEGIN
  nWinners := 0;
  IF ~byDeckEmpty THEN
    FOR i := 0 TO numPlayers - 1 DO
      IF ~players[i].out THEN winners[nWinners] := i; INC(nWinners) END
    END;
    AddLog("Only one player remains!")
  ELSE
    AddLog("The deck is empty. Revealing hands...");
    best := -1;
    FOR i := 0 TO numPlayers - 1 DO
      IF ~players[i].out & (players[i].hand[0] > best) THEN best := players[i].hand[0] END
    END;
    FOR i := 0 TO numPlayers - 1 DO
      IF ~players[i].out & (players[i].hand[0] = best) THEN winners[nWinners] := i; INC(nWinners) END
    END;
    IF nWinners > 1 THEN
      bestSum := -1;
      FOR i := 0 TO nWinners - 1 DO
        sum := DiscardSum(winners[i]);
        IF sum > bestSum THEN bestSum := sum END
      END;
      nWinners2 := 0;
      FOR i := 0 TO nWinners - 1 DO
        IF DiscardSum(winners[i]) = bestSum THEN winners2[nWinners2] := winners[i]; INC(nWinners2) END
      END;
      FOR i := 0 TO nWinners2 - 1 DO winners[i] := winners2[i] END;
      nWinners := nWinners2
    END
  END;

  FOR i := 0 TO nWinners - 1 DO INC(players[winners[i]].tokens) END;
  nextStarter := winners[0];

  s := "Round winner: ";
  FOR i := 0 TO nWinners - 1 DO
    AppendName(s, winners[i]);
    IF i < nWinners - 1 THEN Strings.Append(", ", s) END
  END;
  Strings.Append(" (+1 token)", s);
  AddLog(s);

  DrawBoard(TRUE);
  ContinuePrompt
END ResolveRoundEnd;

PROCEDURE GameWinnerExists() : BOOLEAN;
VAR i : INTEGER;
BEGIN
  FOR i := 0 TO numPlayers - 1 DO IF players[i].tokens >= tokensToWin THEN RETURN TRUE END END;
  RETURN FALSE
END GameWinnerExists;

PROCEDURE GameOverScreen;
VAR i : INTEGER; key : CHAR;
BEGIN
  DrawBoard(TRUE);
  Terminal.Goto(1, RowPrompt); Terminal.Color256(226, 0);
  Out.String("*** GAME OVER *** Champion: ");
  FOR i := 0 TO numPlayers - 1 DO
    IF players[i].tokens >= tokensToWin THEN Out.String(players[i].name); Out.String("  ") END
  END;
  Terminal.Reset;
  Terminal.Goto(1, RowPrompt + 1); Terminal.Color256(8, 0);
  Out.String("Press ENTER to play again, Q to quit.");
  Terminal.Reset; Out.Flush;
  LOOP
    key := Terminal.ReadKey();
    IF (key = 'q') OR (key = 'Q') THEN wantQuit := TRUE; EXIT END;
    IF key = KeyEnter THEN EXIT END
  END
END GameOverScreen;

(* ── Setup ──────────────────────────────────────────────────── *)

PROCEDURE TokensFor(n : INTEGER) : INTEGER;
BEGIN
  IF n = 2 THEN RETURN 7 ELSIF n = 3 THEN RETURN 5 ELSE RETURN 4 END
END TokensFor;

PROCEDURE ChoosePlayerCount;
VAR v, n : INTEGER; key : CHAR; nm, ds : STRING;
BEGIN
  wantQuit := FALSE;
  Terminal.Clear;
  Terminal.Color256(213, 0); Terminal.Goto(34, 1); Out.String("LOVE LETTER"); Terminal.Reset;
  Terminal.Color256(7, 0); Terminal.Goto(10, 3);
  Out.String("A card game of risk, deduction, and courtly love.");
  Terminal.Reset;

  Terminal.Goto(1, 5); Out.String("Card reference:");
  FOR v := 0 TO 7 DO
    Terminal.Goto(1, 6 + v);
    Terminal.Color256(CardColor(v), 0);
    Out.Int(v + 1, 0); Out.String(" ");
    CardNameTo(v, nm); Out.String(nm);
    Terminal.Reset;
    Terminal.Goto(18, 6 + v);
    Terminal.Color256(8, 0);
    CardDescTo(v, ds); Out.String(ds);
    Terminal.Reset
  END;

  Terminal.Goto(1, 16); Terminal.Color256(7, 0);
  Out.String("How many players?  [2]  [3]  [4]   (Q to quit)");
  Terminal.Reset; Out.Flush;

  n := 0;
  LOOP
    key := Terminal.ReadKey();
    IF (key = 'q') OR (key = 'Q') THEN wantQuit := TRUE; RETURN END;
    IF (key >= '2') & (key <= '4') THEN n := ORD(key) - ORD('0'); EXIT END
  END;

  numPlayers := n;
  tokensToWin := TokensFor(n);
  roundNum := 0;
  nextStarter := -1;

  players[0].name := "You"; players[0].isHuman := TRUE; players[0].tokens := 0;
  IF n >= 2 THEN players[1].name := "Lord Ashby"; players[1].isHuman := FALSE; players[1].tokens := 0 END;
  IF n >= 3 THEN players[2].name := "Lady Bryn"; players[2].isHuman := FALSE; players[2].tokens := 0 END;
  IF n >= 4 THEN players[3].name := "Sir Corwin"; players[3].isHuman := FALSE; players[3].tokens := 0 END
END ChoosePlayerCount;

(* ── Main ───────────────────────────────────────────────────── *)

BEGIN
  Terminal.HideCursor;
  wantQuit := FALSE;
  LOOP
    ChoosePlayerCount;
    IF wantQuit THEN EXIT END;
    LOOP
      StartRound;
      LOOP
        PlayTurn(currentPlayer);
        IF wantQuit THEN EXIT END;
        IF ActiveCount() = 1 THEN
          ResolveRoundEnd(FALSE); EXIT
        ELSIF deckTop >= 16 THEN
          ResolveRoundEnd(TRUE); EXIT
        ELSE
          currentPlayer := NextActive(currentPlayer)
        END
      END;
      IF wantQuit THEN EXIT END;
      IF GameWinnerExists() THEN EXIT END
    END;
    IF wantQuit THEN EXIT END;
    GameOverScreen;
    IF wantQuit THEN EXIT END
  END;
  Terminal.Clear;
  Terminal.Goto(1, 1);
  Out.String("Thanks for playing Love Letter!"); Out.Ln
END LoveLetter.
