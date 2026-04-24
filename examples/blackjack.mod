MODULE Blackjack;
(*
 * Blackjack – standard rules, dealer peeks for blackjack.
 *
 * $5 per hand, starting balance $100.
 * Blackjack pays 3:2 (on a $5 bet: +$7).
 * Dealer hits below 17, stands on 17+.
 * Double down allowed on first two cards if affordable.
 *
 * Layout (80x24):
 *   Row  1 : Title
 *   Row  3 : DEALER: <score>
 *   Row  5-9 : Dealer cards (up to 6)
 *   Row  11 : PLAYER: <score>
 *   Row  13-17 : Player cards (up to 6)
 *   Row  19 : Balance / bet / hands
 *   Row  21 : Result message
 *   Row  22 : Controls
 *
 * Controls:
 *   ENTER / SPACE : deal next hand
 *   H             : hit
 *   S             : stand
 *   D             : double down (first 2 cards, if affordable)
 *   R             : restart ($100)
 *   Q             : quit
 *)

IMPORT Terminal, Out, Random;

CONST
  Clubs = 0;  Diamonds = 1;  Hearts = 2;  Spades = 3;
  KeyEnter = 0DX;

  CardX0  = 2;    (* left edge of first card column *)
  CardDX  = 12;   (* column stride between cards    *)
  DealerY = 5;    (* top row of dealer cards        *)
  PlayerY = 13;   (* top row of player cards        *)

  Bet        = 5;
  StartMoney = 100;

  PhaseBet    = 0;
  PhasePlayer = 1;
  PhaseDealer = 2;  (* dealer auto-playing – used only for controls label *)
  PhaseResult = 3;
  PhaseOver   = 4;

  ResNone       = 0;
  ResWin        = 1;
  ResLose       = 2;
  ResPush       = 3;
  ResBlackjack  = 4;  (* player natural 21, dealer has none *)
  ResBust       = 5;  (* player busted   *)
  ResDealerBust = 6;

VAR
  deck       : ARRAY 52 OF INTEGER;
  dHand      : ARRAY 12 OF INTEGER;
  pHand      : ARRAY 12 OF INTEGER;
  dCount, pCount : INTEGER;
  deckTop    : INTEGER;
  phase      : INTEGER;
  currentBet : INTEGER;          (* 5 normally, 10 after double *)
  money, games : INTEGER;
  result     : INTEGER;
  hideHole   : BOOLEAN;          (* TRUE while dealer hole card is face-down *)
  quit       : BOOLEAN;
  key        : CHAR;

(* ── Deck ──────────────────────────────────────────────────── *)

PROCEDURE Shuffle;
VAR i, j, t : INTEGER;
BEGIN
  FOR i := 0 TO 51 DO deck[i] := i END;
  FOR i := 51 TO 1 BY -1 DO
    j := Random.Int(i + 1);
    t := deck[i];  deck[i] := deck[j];  deck[j] := t
  END;
  deckTop := 0
END Shuffle;

PROCEDURE DrawOne() : INTEGER;
VAR c : INTEGER;
BEGIN
  c := deck[deckTop];  INC(deckTop);  RETURN c
END DrawOne;

(* ── Hand value ─────────────────────────────────────────────── *)

PROCEDURE HandValue(VAR hand : ARRAY OF INTEGER; n : INTEGER) : INTEGER;
VAR i, r, total, aces : INTEGER;
BEGIN
  total := 0;  aces := 0;
  FOR i := 0 TO n - 1 DO
    r := hand[i] MOD 13 + 1;       (* rank 1-13 *)
    IF r = 1 THEN
      INC(aces);  INC(total, 11)
    ELSIF r >= 10 THEN
      INC(total, 10)
    ELSE
      INC(total, r)
    END
  END;
  (* Reduce aces from 11 to 1 until not bust *)
  WHILE (total > 21) & (aces > 0) DO
    DEC(total, 10);  DEC(aces)
  END;
  RETURN total
END HandValue;

PROCEDURE IsBlackjack(VAR hand : ARRAY OF INTEGER; n : INTEGER) : BOOLEAN;
BEGIN
  RETURN (n = 2) & (HandValue(hand, 2) = 21)
END IsBlackjack;

(* ── Card rendering ─────────────────────────────────────────── *)

PROCEDURE PrintRank(r : INTEGER);
BEGIN
  IF    r = 1  THEN Out.Char('A')
  ELSIF r = 10 THEN Out.Char('T')
  ELSIF r = 11 THEN Out.Char('J')
  ELSIF r = 12 THEN Out.Char('Q')
  ELSIF r = 13 THEN Out.Char('K')
  ELSE Out.Int(r, 0)
  END
END PrintRank;

PROCEDURE PrintSuit(s : INTEGER);
BEGIN
  IF    s = Clubs    THEN Out.String("♣")
  ELSIF s = Diamonds THEN Out.String("♦")
  ELSIF s = Hearts   THEN Out.String("♥")
  ELSE                    Out.String("♠")
  END
END PrintSuit;

PROCEDURE SuitFg(s : INTEGER) : INTEGER;
BEGIN
  IF (s = Hearts) OR (s = Diamonds) THEN RETURN 160 ELSE RETURN 16 END
END SuitFg;

PROCEDURE DrawCardAt(x, y, card : INTEGER);
VAR r, s, fg : INTEGER;
BEGIN
  r := card MOD 13 + 1;
  s := card DIV 13;
  fg := SuitFg(s);
  Terminal.Color256(fg, 231);
  Terminal.Goto(x, y);     Out.String("+---------+");
  Terminal.Goto(x, y + 1); Out.Char('|'); PrintRank(r); Out.String("        |");
  Terminal.Goto(x, y + 2); Out.String("|    "); PrintSuit(s); Out.String("    |");
  Terminal.Goto(x, y + 3); Out.String("|        "); PrintRank(r); Out.Char('|');
  Terminal.Goto(x, y + 4); Out.String("+---------+");
  Terminal.Reset
END DrawCardAt;

PROCEDURE DrawBackAt(x, y : INTEGER);
BEGIN
  Terminal.Color256(15, 17);
  Terminal.Goto(x, y);     Out.String("+---------+");
  Terminal.Goto(x, y + 1); Out.String("| * * * * |");
  Terminal.Goto(x, y + 2); Out.String("| * * * * |");
  Terminal.Goto(x, y + 3); Out.String("| * * * * |");
  Terminal.Goto(x, y + 4); Out.String("+---------+");
  Terminal.Reset
END DrawBackAt;

PROCEDURE ClearCardSlot(x, y : INTEGER);
VAR row : INTEGER;
BEGIN
  Terminal.Color256(0, 0);
  FOR row := 0 TO 4 DO
    Terminal.Goto(x, y + row);
    Out.String("           ")   (* 11 spaces *)
  END;
  Terminal.Reset
END ClearCardSlot;

(* Erase all visible card positions in a row (6 max) *)
PROCEDURE ClearHandRow(y : INTEGER);
VAR i : INTEGER;
BEGIN
  FOR i := 0 TO 5 DO ClearCardSlot(CardX0 + i * CardDX, y) END
END ClearHandRow;

PROCEDURE DrawDealerHand;
VAR i : INTEGER;
BEGIN
  FOR i := 0 TO dCount - 1 DO
    IF hideHole & (i = 0) THEN
      DrawBackAt(CardX0 + i * CardDX, DealerY)
    ELSE
      DrawCardAt(CardX0 + i * CardDX, DealerY, dHand[i])
    END
  END
END DrawDealerHand;

PROCEDURE DrawPlayerHand;
VAR i, n : INTEGER;
BEGIN
  n := pCount;  IF n > 6 THEN n := 6 END;
  FOR i := 0 TO n - 1 DO
    DrawCardAt(CardX0 + i * CardDX, PlayerY, pHand[i])
  END
END DrawPlayerHand;

(* ── Score labels ────────────────────────────────────────────── *)

PROCEDURE DrawDealerLabel;
VAR score : INTEGER;
BEGIN
  Terminal.Goto(1, DealerY - 2);
  IF hideHole THEN
    Terminal.Color256(7, 0);
    Out.String("DEALER: ?                               ")
  ELSE
    score := HandValue(dHand, dCount);
    IF score > 21 THEN
      Terminal.Color256(46, 0);
      Out.String("DEALER: BUST ("); Out.Int(score, 0); Out.String(")                ")
    ELSIF IsBlackjack(dHand, dCount) THEN
      Terminal.Color256(226, 0);
      Out.String("DEALER: BLACKJACK!                      ")
    ELSE
      Terminal.Color256(7, 0);
      Out.String("DEALER: "); Out.Int(score, 0);
      Out.String("                               ")
    END
  END;
  Terminal.Reset
END DrawDealerLabel;

PROCEDURE DrawPlayerLabel;
VAR score : INTEGER;
BEGIN
  Terminal.Goto(1, PlayerY - 2);
  score := HandValue(pHand, pCount);
  IF score > 21 THEN
    Terminal.Color256(196, 0);
    Out.String("PLAYER: BUST ("); Out.Int(score, 0); Out.String(")                ")
  ELSIF IsBlackjack(pHand, pCount) THEN
    Terminal.Color256(226, 0);
    Out.String("PLAYER: BLACKJACK!                      ")
  ELSE
    Terminal.Color256(7, 0);
    Out.String("PLAYER: "); Out.Int(score, 0);
    Out.String("                               ")
  END;
  Terminal.Reset
END DrawPlayerLabel;

(* ── UI panels ───────────────────────────────────────────────── *)

PROCEDURE DrawTitle;
BEGIN
  Terminal.Color256(226, 0);
  Terminal.Goto(36, 1); Out.String("BLACKJACK");
  Terminal.Reset;
  Terminal.Color256(7, 0);
  Terminal.Goto(22, 1); Out.String("♠  ♥  ♦  ♣");
  Terminal.Goto(48, 1); Out.String("♣  ♦  ♥  ♠");
  Terminal.Reset
END DrawTitle;

PROCEDURE DrawMoney;
BEGIN
  Terminal.Goto(1, 19);
  IF money > 30 THEN
    Terminal.Color256(46, 0)
  ELSIF money > Bet THEN
    Terminal.Color256(226, 0)
  ELSE
    Terminal.Color256(196, 0)
  END;
  Out.String("  Balance: $"); Out.Int(money, 0);
  Terminal.Color256(7, 0);
  Out.String("    Bet: $"); Out.Int(currentBet, 0);
  Out.String("    Hands: "); Out.Int(games, 0);
  Out.String("           ");
  Terminal.Reset
END DrawMoney;

PROCEDURE ClearResult;
BEGIN
  Terminal.Color256(0, 0);
  Terminal.Goto(1, 21);
  Out.String("                                                       ");
  Terminal.Reset
END ClearResult;

PROCEDURE DrawResult;
BEGIN
  Terminal.Goto(1, 21);
  IF result = ResBlackjack THEN
    Terminal.Color256(226, 0);
    Out.String("  *** BLACKJACK!  You win $");
    Out.Int(currentBet * 3 DIV 2, 0);
    Out.String("! ***                    ")
  ELSIF result = ResWin THEN
    Terminal.Color256(46, 0);
    Out.String("  You win! +$"); Out.Int(currentBet, 0);
    Out.String("                              ")
  ELSIF result = ResPush THEN
    Terminal.Color256(226, 0);
    Out.String("  Push – bet returned.                                 ")
  ELSIF result = ResBust THEN
    Terminal.Color256(196, 0);
    Out.String("  Bust!  You lose $"); Out.Int(currentBet, 0);
    Out.String("                           ")
  ELSIF result = ResDealerBust THEN
    Terminal.Color256(46, 0);
    Out.String("  Dealer busts!  You win +$"); Out.Int(currentBet, 0);
    Out.String("                      ")
  ELSE
    Terminal.Color256(196, 0);
    Out.String("  Dealer wins.  You lose $"); Out.Int(currentBet, 0);
    Out.String("                     ")
  END;
  Terminal.Reset
END DrawResult;

PROCEDURE DrawControls;
BEGIN
  Terminal.Goto(1, 22);
  Terminal.Color256(7, 0);
  IF phase = PhaseBet THEN
    Out.String("  ENTER/SPACE: deal    R: restart    Q: quit          ")
  ELSIF phase = PhasePlayer THEN
    IF pCount = 2 THEN
      Out.String("  H: hit    S: stand    D: double down    Q: quit     ")
    ELSE
      Out.String("  H: hit    S: stand                      Q: quit     ")
    END
  ELSIF phase = PhaseDealer THEN
    Out.String("  Dealer is playing...                                  ")
  ELSIF phase = PhaseResult THEN
    Out.String("  ENTER/SPACE: next hand    R: restart       Q: quit   ")
  ELSIF phase = PhaseOver THEN
    Out.String("  Out of money!             R: restart       Q: quit   ")
  END;
  Terminal.Reset
END DrawControls;

PROCEDURE DrawGameOver;
BEGIN
  Terminal.Color256(15, 88);
  Terminal.Goto(17, 12); Out.String("                            ");
  Terminal.Goto(17, 13); Out.String("   *** GAME  OVER ***       ");
  Terminal.Goto(17, 14); Out.String("   You ran out of money!    ");
  Terminal.Goto(17, 15); Out.String("   R = restart  Q = quit    ");
  Terminal.Goto(17, 16); Out.String("                            ");
  Terminal.Reset
END DrawGameOver;

PROCEDURE Delay(ms : INTEGER);
VAR t : LONGINT;
BEGIN
  t := Terminal.GetTickCount() + ms;
  REPEAT UNTIL Terminal.GetTickCount() >= t
END Delay;

(* ── Game logic ──────────────────────────────────────────────── *)

(*
 * Settle the hand: determine result, add winnings, update display.
 * Called after player stands, player busts, or immediate BJ/peek.
 * If runDealer=TRUE the dealer first plays out their hand.
 *)
PROCEDURE Settle(runDealer : BOOLEAN);
VAR ps, ds : INTEGER;
    pBJ, dBJ : BOOLEAN;
BEGIN
  IF runDealer THEN
    (* Animate dealer drawing *)
    hideHole := FALSE;
    DrawDealerHand;
    DrawDealerLabel;
    Delay(700);
    LOOP
      ds := HandValue(dHand, dCount);
      IF ds >= 17 THEN EXIT END;
      dHand[dCount] := DrawOne();
      INC(dCount);
      DrawDealerHand;
      DrawDealerLabel;
      Delay(600)
    END
  END;

  ps  := HandValue(pHand, pCount);
  ds  := HandValue(dHand, dCount);
  pBJ := IsBlackjack(pHand, pCount);
  dBJ := IsBlackjack(dHand, dCount);

  IF    ps > 21              THEN result := ResBust
  ELSIF pBJ & dBJ            THEN result := ResPush
  ELSIF pBJ                  THEN result := ResBlackjack
  ELSIF dBJ                  THEN result := ResLose
  ELSIF ds > 21              THEN result := ResDealerBust
  ELSIF ps > ds              THEN result := ResWin
  ELSIF ps = ds              THEN result := ResPush
  ELSE                            result := ResLose
  END;

  (* Pay out *)
  IF result = ResBlackjack THEN
    INC(money, currentBet + currentBet * 3 DIV 2)   (* bet returned + 3:2 bonus *)
  ELSIF (result = ResWin) OR (result = ResDealerBust) THEN
    INC(money, currentBet * 2)                       (* bet returned + equal win *)
  ELSIF result = ResPush THEN
    INC(money, currentBet)                           (* bet returned *)
  END;

  INC(games);
  DrawDealerLabel;
  DrawResult;
  DrawMoney;
  phase := PhaseResult;
  DrawControls
END Settle;

(*
 * Deal a new hand: deduct $5, shuffle, give 2 cards each.
 * Returns TRUE if an immediate result should be shown
 * (player BJ or dealer BJ via peek).
 *)
PROCEDURE NewDeal;
BEGIN
  DEC(money, Bet);
  currentBet := Bet;
  Shuffle;
  pHand[0] := DrawOne();  dHand[0] := DrawOne();
  pHand[1] := DrawOne();  dHand[1] := DrawOne();
  pCount := 2;  dCount := 2;
  hideHole := TRUE
END NewDeal;

PROCEDURE StartRound;
BEGIN
  ClearHandRow(DealerY);
  ClearHandRow(PlayerY);
  NewDeal;
  DrawDealerHand;
  DrawDealerLabel;
  DrawPlayerHand;
  DrawPlayerLabel;
  ClearResult;
  DrawMoney;

  (* Dealer peek: if dealer has BJ, resolve immediately *)
  IF IsBlackjack(dHand, dCount) THEN
    hideHole := FALSE;
    DrawDealerHand;
    DrawDealerLabel;
    Settle(FALSE)                (* result = ResLose (or ResPush if player also BJ) *)
  ELSIF IsBlackjack(pHand, pCount) THEN
    (* Player BJ, dealer has no BJ: pay 3:2 without dealer playing *)
    hideHole := FALSE;
    DrawDealerHand;
    DrawDealerLabel;
    Settle(FALSE)
  ELSE
    phase := PhasePlayer;
    DrawControls
  END
END StartRound;

PROCEDURE InitScreen;
BEGIN
  Terminal.Clear;
  DrawTitle;
  Terminal.Color256(8, 0);
  Terminal.Goto(1, DealerY - 2); Out.String("DEALER:");
  Terminal.Goto(1, PlayerY - 2); Out.String("PLAYER:");
  Terminal.Reset;
  phase := PhaseBet;
  result := ResNone;
  DrawMoney;
  ClearResult;
  Terminal.Color256(242, 0);
  Terminal.Goto(1, 21);
  Out.String("  Press ENTER or SPACE to deal.  ($5 per hand)");
  Terminal.Reset;
  DrawControls
END InitScreen;

(* ── Main ────────────────────────────────────────────────────── *)

BEGIN
  money      := StartMoney;
  currentBet := Bet;
  games      := 0;
  phase      := PhaseBet;
  result     := ResNone;
  hideHole   := FALSE;
  quit       := FALSE;

  Terminal.HideCursor;
  InitScreen;

  LOOP
    key := Terminal.ReadKey();

    IF (key = 'q') OR (key = 'Q') THEN EXIT END;

    (* R = restart at any point *)
    IF (key = 'r') OR (key = 'R') THEN
      money      := StartMoney;
      currentBet := Bet;
      games      := 0;
      result     := ResNone;
      InitScreen

    ELSIF phase = PhaseBet THEN
      IF (key = KeyEnter) OR (key = ' ') THEN
        IF money < Bet THEN
          phase := PhaseOver;
          DrawGameOver;
          DrawControls
        ELSE
          StartRound
        END
      END

    ELSIF phase = PhasePlayer THEN
      IF (key = 'h') OR (key = 'H') THEN
        pHand[pCount] := DrawOne();
        INC(pCount);
        DrawPlayerHand;
        DrawPlayerLabel;
        IF HandValue(pHand, pCount) > 21 THEN
          (* Bust: reveal dealer hole card, no dealer play needed *)
          hideHole := FALSE;
          DrawDealerHand;
          DrawDealerLabel;
          Settle(FALSE)
        END

      ELSIF (key = 's') OR (key = 'S') THEN
        phase := PhaseDealer;
        DrawControls;
        Settle(TRUE)

      ELSIF ((key = 'd') OR (key = 'D')) & (pCount = 2) & (money >= Bet) THEN
        (* Double down: extra $5, exactly one more card, then stand *)
        DEC(money, Bet);
        INC(currentBet, Bet);
        pHand[pCount] := DrawOne();
        INC(pCount);
        DrawPlayerHand;
        DrawPlayerLabel;
        DrawMoney;
        IF HandValue(pHand, pCount) > 21 THEN
          hideHole := FALSE;
          DrawDealerHand;
          DrawDealerLabel;
          Settle(FALSE)
        ELSE
          phase := PhaseDealer;
          DrawControls;
          Settle(TRUE)
        END
      END

    ELSIF phase = PhaseResult THEN
      IF (key = KeyEnter) OR (key = ' ') THEN
        IF money < Bet THEN
          phase := PhaseOver;
          DrawGameOver;
          DrawControls
        ELSE
          StartRound
        END
      END
    END
    (* PhaseOver: R and Q only, handled above *)
  END;

  Terminal.Clear;
  Terminal.Goto(1, 1);
  Out.String("Thanks for playing Blackjack!"); Out.Ln;
  Out.String("Final balance: $"); Out.Int(money, 0); Out.Ln;
  Out.String("Hands played:  "); Out.Int(games, 0); Out.Ln
END Blackjack.

