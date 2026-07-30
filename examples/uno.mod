MODULE Uno;
(*
 * UNO -- the classic matching card game, played to the official
 * printed rules (color/number/symbol matching, no stacking, Wild
 * Draw Four only legal with no card of the current color).
 *
 * 2-4 players; player 1 is human, the rest are computer-controlled.
 * First to 500 points wins the game. A round ends the instant a
 * player empties their hand; everyone else's remaining cards are
 * scored against them.
 *
 * Controls:
 *   1-9, a-z  : play the matching card from your hand
 *   D         : draw a card
 *   Y / N     : play a just-drawn card, or keep it and pass
 *   1-4       : choose a color after playing a Wild
 *   ENTER     : play again after a game ends
 *   Q         : quit at any prompt
 *)

IMPORT Terminal, Out, Random, Strings;

CONST
  Red = 0; Yellow = 1; Green = 2; Blue = 3; Wild = 4;

  Skip = 10; Reverse = 11; DrawTwo = 12; WildCard = 13; WildDrawFour = 14;

  MaxPlayers = 4;
  MaxHand = 108;
  MaxDeck = 108;
  HUMAN = 0;

  KeyEnter = 0DX;
  RowPrompt = 23;

TYPE
  CardRec = RECORD
    color, value : INTEGER
  END;

  PlayerRec = RECORD
    name      : ARRAY 20 OF CHAR;
    isHuman   : BOOLEAN;
    hand      : ARRAY MaxHand OF CardRec;
    handCount : INTEGER;
    score     : INTEGER
  END;

VAR
  players      : ARRAY MaxPlayers OF PlayerRec;
  numPlayers   : INTEGER;
  targetScore  : INTEGER;

  drawPile     : ARRAY MaxDeck OF CardRec;
  drawCount    : INTEGER;
  discardPile  : ARRAY MaxDeck OF CardRec;
  discardCount : INTEGER;

  currentColor : INTEGER;
  topValue     : INTEGER;
  direction    : INTEGER;
  currentPlayer: INTEGER;
  nextStarter  : INTEGER;
  roundNum     : INTEGER;
  roundOver    : BOOLEAN;
  roundWinner  : INTEGER;
  logBuf       : ARRAY 4 OF STRING;
  wantQuit     : BOOLEAN;

(* ── Card data ──────────────────────────────────────────────── *)

PROCEDURE AppendInt(VAR s : ARRAY OF CHAR; n : INTEGER);
VAR t : STRING;
BEGIN Strings.IntToStr(n, t); Strings.Append(t, s) END AppendInt;

PROCEDURE ColorName(c : INTEGER; VAR s : ARRAY OF CHAR);
BEGIN
  IF    c = Red    THEN Strings.Copy("Red", s)
  ELSIF c = Yellow THEN Strings.Copy("Yellow", s)
  ELSIF c = Green  THEN Strings.Copy("Green", s)
  ELSIF c = Blue   THEN Strings.Copy("Blue", s)
  ELSE Strings.Copy("Wild", s)
  END
END ColorName;

PROCEDURE ColorCode(c : INTEGER) : INTEGER;
BEGIN
  IF    c = Red    THEN RETURN 196
  ELSIF c = Yellow THEN RETURN 226
  ELSIF c = Green  THEN RETURN 46
  ELSIF c = Blue   THEN RETURN 33
  ELSE RETURN 250
  END
END ColorCode;

PROCEDURE CardNameTo(c : CardRec; VAR s : ARRAY OF CHAR);
VAR t : STRING;
BEGIN
  s := "";
  IF c.value <= 9 THEN
    ColorName(c.color, t); Strings.Append(t, s); Strings.Append(" ", s); AppendInt(s, c.value)
  ELSIF c.value = Skip THEN
    ColorName(c.color, t); Strings.Append(t, s); Strings.Append(" Skip", s)
  ELSIF c.value = Reverse THEN
    ColorName(c.color, t); Strings.Append(t, s); Strings.Append(" Reverse", s)
  ELSIF c.value = DrawTwo THEN
    ColorName(c.color, t); Strings.Append(t, s); Strings.Append(" Draw Two", s)
  ELSIF c.value = WildCard THEN
    Strings.Append("Wild", s)
  ELSE
    Strings.Append("Wild Draw Four", s)
  END
END CardNameTo;

PROCEDURE CardPoints(c : CardRec) : INTEGER;
BEGIN
  IF c.value <= 9 THEN RETURN c.value
  ELSIF (c.value = Skip) OR (c.value = Reverse) OR (c.value = DrawTwo) THEN RETURN 20
  ELSE RETURN 50
  END
END CardPoints;

(* ── String / log helpers ──────────────────────────────────── *)

PROCEDURE AppendCardName(VAR s : ARRAY OF CHAR; c : CardRec);
VAR t : STRING;
BEGIN CardNameTo(c, t); Strings.Append(t, s) END AppendCardName;

PROCEDURE AppendName(VAR s : ARRAY OF CHAR; p : INTEGER);
BEGIN Strings.Append(players[p].name, s) END AppendName;

(* "You" takes plural verb forms ("you play"), named players take singular ("Bea plays") *)
PROCEDURE AppendVerb(VAR s : ARRAY OF CHAR; p : INTEGER; sing, plur : ARRAY OF CHAR);
BEGIN
  IF p = HUMAN THEN Strings.Append(plur, s) ELSE Strings.Append(sing, s) END
END AppendVerb;

PROCEDURE ClearLog;
VAR i : INTEGER;
BEGIN FOR i := 0 TO 3 DO logBuf[i] := "" END END ClearLog;

PROCEDURE AddLog(s : ARRAY OF CHAR);
VAR i : INTEGER;
BEGIN
  FOR i := 0 TO 2 DO Strings.Copy(logBuf[i + 1], logBuf[i]) END;
  Strings.Copy(s, logBuf[3])
END AddLog;

(* ── Deck / pile mechanics ─────────────────────────────────── *)

PROCEDURE ShuffleRange(VAR arr : ARRAY OF CardRec; n : INTEGER);
VAR i, j : INTEGER; t : CardRec;
BEGIN
  FOR i := n - 1 TO 1 BY -1 DO
    j := Random.Int(i + 1);
    t := arr[i]; arr[i] := arr[j]; arr[j] := t
  END
END ShuffleRange;

PROCEDURE BuildDeck;
VAR i, k, c : INTEGER;
BEGIN
  k := 0;
  FOR c := 0 TO 3 DO
    drawPile[k].color := c; drawPile[k].value := 0; INC(k);
    FOR i := 1 TO 9 DO
      drawPile[k].color := c; drawPile[k].value := i; INC(k);
      drawPile[k].color := c; drawPile[k].value := i; INC(k)
    END;
    FOR i := 1 TO 2 DO drawPile[k].color := c; drawPile[k].value := Skip; INC(k) END;
    FOR i := 1 TO 2 DO drawPile[k].color := c; drawPile[k].value := Reverse; INC(k) END;
    FOR i := 1 TO 2 DO drawPile[k].color := c; drawPile[k].value := DrawTwo; INC(k) END
  END;
  FOR i := 1 TO 4 DO drawPile[k].color := Wild; drawPile[k].value := WildCard; INC(k) END;
  FOR i := 1 TO 4 DO drawPile[k].color := Wild; drawPile[k].value := WildDrawFour; INC(k) END;
  drawCount := k
END BuildDeck;

PROCEDURE ReshuffleDiscardIntoDraw;
VAR i : INTEGER;
BEGIN
  IF discardCount <= 1 THEN RETURN END;
  FOR i := 0 TO discardCount - 2 DO drawPile[i] := discardPile[i] END;
  drawCount := discardCount - 1;
  discardPile[0] := discardPile[discardCount - 1];
  discardCount := 1;
  ShuffleRange(drawPile, drawCount);
  AddLog("The draw pile is empty -- reshuffling discards.")
END ReshuffleDiscardIntoDraw;

PROCEDURE DrawOneCard(p : INTEGER; VAR c : CardRec);
BEGIN
  IF drawCount = 0 THEN ReshuffleDiscardIntoDraw END;
  IF drawCount = 0 THEN
    c.color := Wild; c.value := WildCard
  ELSE
    DEC(drawCount);
    c := drawPile[drawCount]
  END;
  players[p].hand[players[p].handCount] := c;
  INC(players[p].handCount)
END DrawOneCard;

PROCEDURE GiveCards(p, n : INTEGER);
VAR i : INTEGER; c : CardRec;
BEGIN FOR i := 1 TO n DO DrawOneCard(p, c) END END GiveCards;

PROCEDURE FlipStartCard;
VAR c : CardRec;
BEGIN
  LOOP
    DEC(drawCount);
    c := drawPile[drawCount];
    IF (c.value = WildCard) OR (c.value = WildDrawFour) THEN
      drawPile[drawCount] := c;
      INC(drawCount);
      ShuffleRange(drawPile, drawCount)
    ELSE
      discardPile[0] := c; discardCount := 1;
      topValue := c.value; currentColor := c.color;
      RETURN
    END
  END
END FlipStartCard;

PROCEDURE HandHasColor(p, color : INTEGER) : BOOLEAN;
VAR i : INTEGER;
BEGIN
  FOR i := 0 TO players[p].handCount - 1 DO
    IF players[p].hand[i].color = color THEN RETURN TRUE END
  END;
  RETURN FALSE
END HandHasColor;

PROCEDURE CanPlay(p : INTEGER; c : CardRec) : BOOLEAN;
BEGIN
  IF c.value = WildDrawFour THEN RETURN ~HandHasColor(p, currentColor)
  ELSIF c.value = WildCard THEN RETURN TRUE
  ELSIF c.color = currentColor THEN RETURN TRUE
  ELSE RETURN c.value = topValue
  END
END CanPlay;

PROCEDURE NextPlayerIdx(p : INTEGER) : INTEGER;
BEGIN RETURN (p + direction + numPlayers) MOD numPlayers END NextPlayerIdx;

(* ── AI ─────────────────────────────────────────────────────── *)

PROCEDURE ChooseAIColor(p : INTEGER) : INTEGER;
VAR counts : ARRAY 4 OF INTEGER; i, best, bestCount : INTEGER;
BEGIN
  FOR i := 0 TO 3 DO counts[i] := 0 END;
  FOR i := 0 TO players[p].handCount - 1 DO
    IF players[p].hand[i].color < 4 THEN INC(counts[players[p].hand[i].color]) END
  END;
  best := 0; bestCount := counts[0];
  FOR i := 1 TO 3 DO IF counts[i] > bestCount THEN bestCount := counts[i]; best := i END END;
  IF bestCount = 0 THEN best := Random.Int(4) END;
  RETURN best
END ChooseAIColor;

(* Prefer a non-wild playable card; go after a player who is close to
   winning with an action card, otherwise shed the highest point value
   first. Wilds are kept as a last resort so they're available later. *)
PROCEDURE AIChooseIndex(p : INTEGER) : INTEGER;
VAR i, best, bestPts, nxt : INTEGER;
BEGIN
  nxt := NextPlayerIdx(p);
  best := -1; bestPts := -1;
  FOR i := 0 TO players[p].handCount - 1 DO
    IF (players[p].hand[i].value < WildCard) & CanPlay(p, players[p].hand[i]) THEN
      IF (players[nxt].handCount <= 2) & (players[p].hand[i].value >= Skip) THEN
        RETURN i
      END;
      IF CardPoints(players[p].hand[i]) > bestPts THEN
        bestPts := CardPoints(players[p].hand[i]); best := i
      END
    END
  END;
  IF best >= 0 THEN RETURN best END;
  FOR i := 0 TO players[p].handCount - 1 DO
    IF CanPlay(p, players[p].hand[i]) THEN RETURN i END
  END;
  RETURN -1
END AIChooseIndex;

(* ── Input helpers ─────────────────────────────────────────── *)

(* Returns 1..n for a hand-slot key ('1'-'9', then 'a'-'z'/'A'-'Z'),
   0 for D/draw, or -1 for quit (sets wantQuit). *)
PROCEDURE ReadIndexChoice(n : INTEGER) : INTEGER;
VAR key : CHAR; idx : INTEGER;
BEGIN
  LOOP
    key := Terminal.ReadKey();
    IF (key = 'q') OR (key = 'Q') THEN wantQuit := TRUE; RETURN -1 END;
    IF (key = 'd') OR (key = 'D') THEN RETURN 0 END;
    idx := -1;
    IF (key >= '1') & (key <= '9') THEN idx := ORD(key) - ORD('0')
    ELSIF (key >= 'a') & (key <= 'z') THEN idx := ORD(key) - ORD('a') + 10
    ELSIF (key >= 'A') & (key <= 'Z') THEN idx := ORD(key) - ORD('A') + 10
    END;
    IF (idx >= 1) & (idx <= n) THEN RETURN idx END
  END
END ReadIndexChoice;

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

PROCEDURE IndexLabel(i : INTEGER; VAR s : ARRAY OF CHAR);
BEGIN
  IF i < 9 THEN
    s := ""; AppendInt(s, i + 1)
  ELSE
    s[0] := CHR(ORD('a') + i - 9); s[1] := 0X
  END
END IndexLabel;

PROCEDURE DrawBoard;
VAR i, y : INTEGER; nm, lbl : STRING; top : CardRec;
BEGIN
  Terminal.Clear;
  Terminal.Color256(226, 0); Terminal.Goto(37, 1); Out.String("UNO"); Terminal.Reset;

  Terminal.Color256(7, 0); Terminal.Goto(1, 3);
  Out.String("Round "); Out.Int(roundNum, 0);
  Out.String("   Target: "); Out.Int(targetScore, 0);
  IF direction = 1 THEN Out.String("   Direction: clockwise")
  ELSE Out.String("   Direction: counter-clockwise") END;
  Terminal.Reset;

  FOR i := 0 TO numPlayers - 1 DO
    y := 5 + i;
    Terminal.Goto(1, y);
    IF i = currentPlayer THEN Terminal.Color256(226, 0); Out.String("> ")
    ELSE Terminal.Color256(7, 0); Out.String("  ") END;
    Out.String(players[i].name);
    Out.String("  cards:"); Out.Int(players[i].handCount, 0);
    Out.String("  score:"); Out.Int(players[i].score, 0);
    Terminal.Reset
  END;

  top := discardPile[discardCount - 1];
  Terminal.Goto(1, 10); Terminal.Color256(7, 0); Out.String("Discard: "); Terminal.Reset;
  Terminal.Color256(ColorCode(top.color), 0); CardNameTo(top, nm); Out.String(nm); Terminal.Reset;
  Terminal.Goto(1, 11); Terminal.Color256(7, 0); Out.String("Current color: "); Terminal.Reset;
  Terminal.Color256(ColorCode(currentColor), 0); ColorName(currentColor, nm); Out.String(nm); Terminal.Reset;

  Terminal.Color256(7, 0); Terminal.Goto(1, 13); Out.String("Your hand:"); Terminal.Reset;
  FOR i := 0 TO players[HUMAN].handCount - 1 DO
    Terminal.Goto(1, 14 + i);
    IF CanPlay(HUMAN, players[HUMAN].hand[i]) THEN Terminal.Color256(ColorCode(players[HUMAN].hand[i].color), 0)
    ELSE Terminal.Color256(8, 0) END;
    IndexLabel(i, lbl);
    Out.String("["); Out.String(lbl); Out.String("] ");
    CardNameTo(players[HUMAN].hand[i], nm); Out.String(nm);
    Terminal.Reset
  END;

  Terminal.Color256(7, 0); Terminal.Goto(42, 13); Out.String("Log:"); Terminal.Reset;
  FOR i := 0 TO 3 DO
    Terminal.Goto(42, 14 + i);
    Terminal.Color256(250, 0);
    Out.String(logBuf[i]);
    Terminal.Reset
  END;
  Out.Flush
END DrawBoard;

(* ── Human choice menus ────────────────────────────────────── *)

(* -2 = quit, -1 = draw, 0-based hand index otherwise *)
PROCEDURE HumanChooseIndexOrDraw(p : INTEGER) : INTEGER;
VAR c : INTEGER;
BEGIN
  LOOP
    Terminal.Goto(1, RowPrompt); Terminal.Color256(7, 0);
    Out.String("Play a card, [D] to draw, [Q] to quit.                          ");
    Terminal.Reset; Out.Flush;
    c := ReadIndexChoice(players[p].handCount);
    IF wantQuit THEN RETURN -2 END;
    IF c = 0 THEN RETURN -1 END;
    IF CanPlay(p, players[p].hand[c - 1]) THEN RETURN c - 1 END;
    Terminal.Goto(1, RowPrompt + 1); Terminal.Color256(196, 0);
    Out.String("That card doesn't match -- choose another, or [D] to draw.      ");
    Terminal.Reset; Out.Flush
  END
END HumanChooseIndexOrDraw;

PROCEDURE HumanWantsToPlayDrawnCard() : BOOLEAN;
VAR key : CHAR;
BEGIN
  Terminal.Goto(1, RowPrompt); Terminal.Color256(7, 0);
  Out.String("That card is playable! Play it? [Y]es / [N]o                    ");
  Terminal.Reset; Out.Flush;
  LOOP
    key := Terminal.ReadKey();
    IF (key = 'q') OR (key = 'Q') THEN wantQuit := TRUE; RETURN FALSE END;
    IF (key = 'y') OR (key = 'Y') THEN RETURN TRUE END;
    IF (key = 'n') OR (key = 'N') THEN RETURN FALSE END
  END
END HumanWantsToPlayDrawnCard;

PROCEDURE HumanChooseColor() : INTEGER;
VAR key : CHAR;
BEGIN
  Terminal.Clear;
  Terminal.Color256(226, 0); Terminal.Goto(1, 1); Out.String("Choose a color"); Terminal.Reset;
  Terminal.Goto(1, 3); Terminal.Color256(ColorCode(Red), 0); Out.String("[1] Red"); Terminal.Reset;
  Terminal.Goto(1, 4); Terminal.Color256(ColorCode(Yellow), 0); Out.String("[2] Yellow"); Terminal.Reset;
  Terminal.Goto(1, 5); Terminal.Color256(ColorCode(Green), 0); Out.String("[3] Green"); Terminal.Reset;
  Terminal.Goto(1, 6); Terminal.Color256(ColorCode(Blue), 0); Out.String("[4] Blue"); Terminal.Reset;
  Terminal.Goto(1, 8); Terminal.Color256(7, 0); Out.String("Press 1-4."); Terminal.Reset; Out.Flush;
  LOOP
    key := Terminal.ReadKey();
    IF (key = 'q') OR (key = 'Q') THEN wantQuit := TRUE; RETURN Red END;
    IF (key >= '1') & (key <= '4') THEN RETURN ORD(key) - ORD('1') END
  END
END HumanChooseColor;

(* ── Card effects / turn resolution ────────────────────────── *)

PROCEDURE ApplyEffect(actor : INTEGER; card : CardRec);
VAR nxt, chosenColor : INTEGER; s, nm : STRING;
BEGIN
  IF card.value = WildCard THEN
    IF players[actor].isHuman THEN chosenColor := HumanChooseColor() ELSE chosenColor := ChooseAIColor(actor) END;
    currentColor := chosenColor;
    s := "Color is now "; ColorName(chosenColor, nm); Strings.Append(nm, s); Strings.Append(".", s);
    AddLog(s);
    currentPlayer := NextPlayerIdx(actor)

  ELSIF card.value = WildDrawFour THEN
    IF players[actor].isHuman THEN chosenColor := HumanChooseColor() ELSE chosenColor := ChooseAIColor(actor) END;
    currentColor := chosenColor;
    nxt := NextPlayerIdx(actor);
    s := "Color is now "; ColorName(chosenColor, nm); Strings.Append(nm, s); Strings.Append(". ", s);
    AppendName(s, nxt); AppendVerb(s, nxt, " draws 4 and is skipped.", " draw 4 and are skipped.");
    AddLog(s);
    GiveCards(nxt, 4);
    currentPlayer := NextPlayerIdx(nxt)

  ELSIF card.value = DrawTwo THEN
    nxt := NextPlayerIdx(actor);
    s := ""; AppendName(s, nxt); AppendVerb(s, nxt, " draws 2 and is skipped.", " draw 2 and are skipped.");
    AddLog(s);
    GiveCards(nxt, 2);
    currentPlayer := NextPlayerIdx(nxt)

  ELSIF card.value = Skip THEN
    nxt := NextPlayerIdx(actor);
    s := ""; AppendName(s, nxt); AppendVerb(s, nxt, " loses a turn.", " lose a turn.");
    AddLog(s);
    currentPlayer := NextPlayerIdx(nxt)

  ELSIF card.value = Reverse THEN
    IF numPlayers = 2 THEN
      nxt := NextPlayerIdx(actor);
      s := "Reverse skips "; AppendName(s, nxt); Strings.Append(" in a 2-player game.", s);
      AddLog(s);
      currentPlayer := NextPlayerIdx(nxt)
    ELSE
      direction := -direction;
      AddLog("Play direction reverses.");
      currentPlayer := NextPlayerIdx(actor)
    END

  ELSE
    currentPlayer := NextPlayerIdx(actor)
  END
END ApplyEffect;

PROCEDURE PlayChosenCard(p, idx : INTEGER);
VAR card : CardRec; i : INTEGER; s : STRING;
BEGIN
  card := players[p].hand[idx];
  FOR i := idx TO players[p].handCount - 2 DO players[p].hand[i] := players[p].hand[i + 1] END;
  DEC(players[p].handCount);
  discardPile[discardCount] := card; INC(discardCount);
  topValue := card.value;
  IF card.color # Wild THEN currentColor := card.color END;

  s := ""; AppendName(s, p); AppendVerb(s, p, " plays ", " play "); AppendCardName(s, card); Strings.Append(".", s);
  AddLog(s);

  IF players[p].handCount = 0 THEN
    s := ""; AppendName(s, p); AppendVerb(s, p, " has no cards left and wins the round!", " have no cards left and win the round!");
    AddLog(s);
    roundOver := TRUE; roundWinner := p;
    RETURN
  END;

  ApplyEffect(p, card);

  IF players[p].handCount = 1 THEN
    s := ""; AppendName(s, p); AppendVerb(s, p, " calls ", " call "); Strings.Append('"UNO!"', s);
    AddLog(s)
  END
END PlayChosenCard;

(* ── Turn / round flow ─────────────────────────────────────── *)

PROCEDURE PlayTurn(p : INTEGER);
VAR idx : INTEGER; drawn : CardRec; s : STRING;
BEGIN
  IF players[p].isHuman THEN
    DrawBoard;
    idx := HumanChooseIndexOrDraw(p);
    IF wantQuit THEN RETURN END;
    IF idx = -1 THEN
      DrawOneCard(p, drawn);
      s := "You draw "; AppendCardName(s, drawn); Strings.Append(".", s); AddLog(s);
      IF CanPlay(p, drawn) THEN
        DrawBoard;
        IF HumanWantsToPlayDrawnCard() THEN
          idx := players[p].handCount - 1
        ELSE
          AddLog("You keep the drawn card and end your turn.");
          currentPlayer := NextPlayerIdx(p);
          RETURN
        END
      ELSE
        AddLog("Not playable -- your turn ends.");
        currentPlayer := NextPlayerIdx(p);
        RETURN
      END
    END
  ELSE
    idx := AIChooseIndex(p);
    IF idx = -1 THEN
      DrawOneCard(p, drawn);
      s := ""; AppendName(s, p); AppendVerb(s, p, " draws a card.", " draw a card.");
      AddLog(s);
      IF CanPlay(p, drawn) THEN
        idx := players[p].handCount - 1
      ELSE
        currentPlayer := NextPlayerIdx(p);
        RETURN
      END
    END
  END;
  PlayChosenCard(p, idx)
END PlayTurn;

PROCEDURE StartRound;
VAR i, j : INTEGER; c : CardRec; s : STRING;
BEGIN
  INC(roundNum);
  BuildDeck;
  ShuffleRange(drawPile, drawCount);

  FOR i := 0 TO numPlayers - 1 DO
    players[i].handCount := 0;
    FOR j := 1 TO 7 DO DrawOneCard(i, c) END
  END;

  FlipStartCard;
  direction := 1;
  IF nextStarter = -1 THEN currentPlayer := Random.Int(numPlayers) ELSE currentPlayer := nextStarter END;

  ClearLog;
  s := "Round "; AppendInt(s, roundNum); Strings.Append(" begins.", s);
  AddLog(s)
END StartRound;

PROCEDURE ResolveRoundEnd;
VAR i, j, sum : INTEGER; s : STRING;
BEGIN
  sum := 0;
  FOR i := 0 TO numPlayers - 1 DO
    IF i # roundWinner THEN
      FOR j := 0 TO players[i].handCount - 1 DO INC(sum, CardPoints(players[i].hand[j])) END
    END
  END;
  INC(players[roundWinner].score, sum);

  s := ""; AppendName(s, roundWinner); Strings.Append(" earns ", s); AppendInt(s, sum); Strings.Append(" points.", s);
  AddLog(s);

  nextStarter := roundWinner;
  DrawBoard;
  ContinuePrompt
END ResolveRoundEnd;

PROCEDURE GameWinnerExists() : BOOLEAN;
VAR i : INTEGER;
BEGIN
  FOR i := 0 TO numPlayers - 1 DO IF players[i].score >= targetScore THEN RETURN TRUE END END;
  RETURN FALSE
END GameWinnerExists;

PROCEDURE GameOverScreen;
VAR i : INTEGER; key : CHAR;
BEGIN
  DrawBoard;
  Terminal.Goto(1, RowPrompt); Terminal.Color256(226, 0);
  Out.String("*** GAME OVER *** Champion: ");
  FOR i := 0 TO numPlayers - 1 DO
    IF players[i].score >= targetScore THEN Out.String(players[i].name); Out.String("  ") END
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

PROCEDURE ResetScores;
VAR i : INTEGER;
BEGIN FOR i := 0 TO numPlayers - 1 DO players[i].score := 0 END END ResetScores;

PROCEDURE ChoosePlayerCount;
VAR n : INTEGER; key : CHAR;
BEGIN
  wantQuit := FALSE;
  Terminal.Clear;
  Terminal.Color256(226, 0); Terminal.Goto(37, 1); Out.String("UNO"); Terminal.Reset;
  Terminal.Color256(7, 0); Terminal.Goto(4, 3);
  Out.String("Match colors, numbers, or symbols to empty your hand first.");
  Terminal.Reset;

  Terminal.Goto(1, 5); Out.String("Card reference:");
  Terminal.Goto(1, 6);  Out.String("0-9       Number cards -- match by color or number.");
  Terminal.Goto(1, 7);  Out.String("Skip      Next player loses a turn.");
  Terminal.Goto(1, 8);  Out.String("Reverse   Reverses play order (acts as Skip for 2 players).");
  Terminal.Goto(1, 9);  Out.String("Draw Two  Next player draws 2 cards and loses a turn.");
  Terminal.Goto(1, 10); Out.String("Wild      Choose the new color.");
  Terminal.Goto(1, 11); Out.String("Wild + 4  Choose color; next player draws 4 & loses a turn");
  Terminal.Goto(1, 12); Out.String("          (legal only with no card of the current color).");

  Terminal.Goto(1, 14); Out.String("First player to 500 points wins the game.");

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
  targetScore := 500;
  roundNum := 0;
  nextStarter := -1;

  players[0].name := "You"; players[0].isHuman := TRUE;
  IF n >= 2 THEN players[1].name := "Jamie"; players[1].isHuman := FALSE END;
  IF n >= 3 THEN players[2].name := "Riley"; players[2].isHuman := FALSE END;
  IF n >= 4 THEN players[3].name := "Casey"; players[3].isHuman := FALSE END;

  ResetScores
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
      roundOver := FALSE;
      LOOP
        PlayTurn(currentPlayer);
        IF wantQuit THEN EXIT END;
        IF roundOver THEN ResolveRoundEnd; EXIT END
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
  Out.String("Thanks for playing UNO!"); Out.Ln
END Uno.
