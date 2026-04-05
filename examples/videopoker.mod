MODULE VideoPoker;
(*
 * Video Poker – five-card draw, Jacks-or-Better payout schedule.
 *
 * $5 per hand, starting balance $100.
 *
 * Payout (on $5 bet):
 *   Royal Flush    $4000   Straight Flush  $250
 *   Four of a Kind  $125   Full House        $45
 *   Flush            $30   Straight          $20
 *   Three of a Kind  $15   Two Pair          $10
 *   Jacks or Better   $5   Below Jacks / High $0
 *
 * Controls: 1-5 toggle HOLD  ENTER/SPACE deal or draw  R restart  Q quit
 *)

IMPORT Graphics, Terminal, Out, Random;

CONST
  Clubs = 0;  Diamonds = 1;  Hearts = 2;  Spades = 3;

  KeyEnter = 0DX;

  (* Card layout – 11 chars wide, 5 rows tall *)
  CardX0 = 2;   CardDX = 12;   CardY = 5;

  (* Payout table panel – right side col 63, rows 2-12 *)
  PayX = 63;   PayY = 3;

  (* Money *)
  Bet        = 5;
  StartMoney = 100;

  (* Phases *)
  PhaseDeal = 0;  PhaseDraw = 1;  PhaseShow = 2;  PhaseOver = 3;

  (* Hand ranks *)
  HighCard      = 0;  OnePair       = 1;  TwoPair       = 2;
  ThreeOfAKind  = 3;  Straight      = 4;  Flush         = 5;
  FullHouse     = 6;  FourOfAKind   = 7;
  StraightFlush = 8;  RoyalFlush    = 9;

VAR
  deck     : ARRAY 52 OF INTEGER;
  hand     : ARRAY 5  OF INTEGER;
  hold     : ARRAY 5  OF BOOLEAN;
  deckTop  : INTEGER;
  phase    : INTEGER;
  handRank : INTEGER;
  money, payout, games, won : INTEGER;
  jacksBetter : BOOLEAN;
  quit    : BOOLEAN;
  key     : CHAR;
  i       : INTEGER;

(* ── Deck ──────────────────────────────────────────────── *)

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

PROCEDURE CardSuit(c : INTEGER) : INTEGER;
BEGIN RETURN c DIV 13 END CardSuit;

PROCEDURE CardRank(c : INTEGER) : INTEGER;
BEGIN RETURN c MOD 13 + 1 END CardRank;  (* 1=A 2-10 11=J 12=Q 13=K *)

PROCEDURE DealHand;
VAR i : INTEGER;
BEGIN
  FOR i := 0 TO 4 DO
    hand[i] := deck[deckTop];  hold[i] := FALSE;  INC(deckTop)
  END
END DealHand;

PROCEDURE DrawCards;
VAR i : INTEGER;
BEGIN
  FOR i := 0 TO 4 DO
    IF ~hold[i] THEN hand[i] := deck[deckTop];  INC(deckTop) END
  END
END DrawCards;

(* ── Scoring ────────────────────────────────────────────── *)

PROCEDURE ScoreHand() : INTEGER;
VAR
  rc : ARRAY 14 OF INTEGER;
  sc : ARRAY 4  OF INTEGER;
  i, r, s, pairs, trips, quads, minR, maxR : INTEGER;
  isFlush, isStraight, isRoyal : BOOLEAN;
BEGIN
  FOR r := 0 TO 13 DO rc[r] := 0 END;
  FOR s := 0 TO 3  DO sc[s] := 0 END;
  FOR i := 0 TO 4 DO
    INC(rc[CardRank(hand[i])]);  INC(sc[CardSuit(hand[i])])
  END;

  isFlush := FALSE;
  FOR s := 0 TO 3 DO IF sc[s] = 5 THEN isFlush := TRUE END END;

  minR := 14;  maxR := 0;
  FOR r := 1 TO 13 DO
    IF rc[r] > 0 THEN
      IF r < minR THEN minR := r END;
      IF r > maxR THEN maxR := r END
    END
  END;

  isStraight := (maxR - minR = 4);
  IF isStraight THEN
    FOR r := minR TO maxR DO
      IF rc[r] # 1 THEN isStraight := FALSE END
    END
  END;
  (* Ace-low A-2-3-4-5 *)
  IF (rc[1]=1)&(rc[2]=1)&(rc[3]=1)&(rc[4]=1)&(rc[5]=1)          THEN isStraight := TRUE END;
  (* Ace-high T-J-Q-K-A *)
  IF (rc[1]=1)&(rc[10]=1)&(rc[11]=1)&(rc[12]=1)&(rc[13]=1)       THEN isStraight := TRUE END;

  isRoyal := isFlush & (rc[1]=1)&(rc[10]=1)&(rc[11]=1)&(rc[12]=1)&(rc[13]=1);

  pairs := 0;  trips := 0;  quads := 0;
  FOR r := 1 TO 13 DO
    IF    rc[r] = 2 THEN INC(pairs)
    ELSIF rc[r] = 3 THEN INC(trips)
    ELSIF rc[r] = 4 THEN INC(quads)
    END
  END;

  IF isRoyal               THEN RETURN RoyalFlush    END;
  IF isStraight & isFlush  THEN RETURN StraightFlush END;
  IF quads = 1             THEN RETURN FourOfAKind   END;
  IF (trips=1) & (pairs=1) THEN RETURN FullHouse     END;
  IF isFlush               THEN RETURN Flush         END;
  IF isStraight            THEN RETURN Straight      END;
  IF trips = 1             THEN RETURN ThreeOfAKind  END;
  IF pairs = 2             THEN RETURN TwoPair       END;
  IF pairs = 1             THEN RETURN OnePair       END;
  RETURN HighCard
END ScoreHand;

PROCEDURE IsJacksOrBetter() : BOOLEAN;
VAR rc : ARRAY 14 OF INTEGER;
    i  : INTEGER;
BEGIN
  FOR i := 0 TO 13 DO rc[i] := 0 END;
  FOR i := 0 TO 4  DO INC(rc[CardRank(hand[i])]) END;
  RETURN (rc[1] >= 2) OR (rc[11] >= 2) OR (rc[12] >= 2) OR (rc[13] >= 2)
END IsJacksOrBetter;

PROCEDURE HandPayout() : INTEGER;
BEGIN
  IF    handRank = RoyalFlush                    THEN RETURN 4000
  ELSIF handRank = StraightFlush                 THEN RETURN  250
  ELSIF handRank = FourOfAKind                   THEN RETURN  125
  ELSIF handRank = FullHouse                     THEN RETURN   45
  ELSIF handRank = Flush                         THEN RETURN   30
  ELSIF handRank = Straight                      THEN RETURN   20
  ELSIF handRank = ThreeOfAKind                  THEN RETURN   15
  ELSIF handRank = TwoPair                       THEN RETURN   10
  ELSIF (handRank = OnePair) & jacksBetter       THEN RETURN    5
  ELSE                                                RETURN    0
  END
END HandPayout;

(* ── Card rendering ─────────────────────────────────────── *)

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

PROCEDURE DrawCard(slot : INTEGER);
VAR x, y, r, s, fg : INTEGER;
BEGIN
  x := CardX0 + slot * CardDX;
  y := CardY;
  r := CardRank(hand[slot]);
  s := CardSuit(hand[slot]);
  fg := SuitFg(s);
  Graphics.Color256(fg, 231);
  Graphics.Goto(x, y);     Out.String("+---------+");
  Graphics.Goto(x, y + 1); Out.Char('|'); PrintRank(r); Out.String("        |");
  Graphics.Goto(x, y + 2); Out.String("|    "); PrintSuit(s); Out.String("    |");
  Graphics.Goto(x, y + 3); Out.String("|        "); PrintRank(r); Out.Char('|');
  Graphics.Goto(x, y + 4); Out.String("+---------+");
  Graphics.Reset
END DrawCard;

PROCEDURE DrawHold(slot : INTEGER);
VAR x : INTEGER;
BEGIN
  x := CardX0 + slot * CardDX;
  Graphics.Goto(x, CardY - 2);
  IF hold[slot] THEN
    Graphics.Color256(16, 226);
    Out.String("   [HOLD]  ")
  ELSE
    Graphics.Color256(8, 0);
    Out.String("    ["); Out.Int(slot + 1, 0); Out.String("]    ")
  END;
  Graphics.Reset
END DrawHold;

PROCEDURE DrawAllCards;
VAR i : INTEGER;
BEGIN
  FOR i := 0 TO 4 DO DrawCard(i);  DrawHold(i) END
END DrawAllCards;

PROCEDURE DrawCardBack(slot : INTEGER);
VAR x, y : INTEGER;
BEGIN
  x := CardX0 + slot * CardDX;
  y := CardY;
  Graphics.Color256(15, 17);
  Graphics.Goto(x, y);     Out.String("+---------+");
  Graphics.Goto(x, y + 1); Out.String("| * * * * |");
  Graphics.Goto(x, y + 2); Out.String("| * * * * |");
  Graphics.Goto(x, y + 3); Out.String("| * * * * |");
  Graphics.Goto(x, y + 4); Out.String("+---------+");
  Graphics.Reset;
  Graphics.Color256(8, 0);
  Graphics.Goto(x, y - 2);
  Out.String("    ["); Out.Int(slot + 1, 0); Out.String("]    ");
  Graphics.Reset
END DrawCardBack;

(* ── UI panels ──────────────────────────────────────────── *)

PROCEDURE DrawTitle;
BEGIN
  Graphics.Color256(226, 0);
  Graphics.Goto(34, 1); Out.String("VIDEO POKER");
  Graphics.Reset;
  Graphics.Color256(7, 0);
  Graphics.Goto(20, 1); Out.String("♠  ♥  ♦  ♣");
  Graphics.Goto(48, 1); Out.String("♣  ♦  ♥  ♠");
  Graphics.Reset
END DrawTitle;

(*
 * One row of the right-side payout table (col PayX, row y).
 * name must be exactly 11 chars.  Highlighted when this hand won.
 * isJacks distinguishes the two OnePair rows (Jacks+ vs below).
 *)
PROCEDURE DrawPayRow(y, rank : INTEGER; name : ARRAY OF CHAR;
                     amt : INTEGER; isJacks : BOOLEAN);
VAR fg, bg : INTEGER;
    win    : BOOLEAN;
BEGIN
  win := (phase = PhaseShow) & (rank = handRank) &
         ((rank # OnePair) OR (isJacks = jacksBetter));
  IF win THEN
    IF payout > 0 THEN fg := 16; bg := 226   (* black on yellow = winner *)
    ELSE               fg := 15; bg := 88    (* white on dark red = loser *)
    END
  ELSE
    fg := 8; bg := 0
  END;
  Graphics.Color256(fg, bg);
  Graphics.Goto(PayX, y);
  Out.String(name);   (* 11 chars *)
  Out.String(" $");
  Out.Int(amt, 4);
  Graphics.Reset
END DrawPayRow;

PROCEDURE DrawPayTable;
BEGIN
  Graphics.Color256(7, 0);
  Graphics.Goto(PayX, PayY - 1);
  Out.String(" HAND        PAY");
  Graphics.Reset;
  DrawPayRow(PayY,     RoyalFlush,    "Royal Flush", 4000, FALSE);
  DrawPayRow(PayY + 1, StraightFlush, "Str Flush  ",  250, FALSE);
  DrawPayRow(PayY + 2, FourOfAKind,   "4 of a Kind",  125, FALSE);
  DrawPayRow(PayY + 3, FullHouse,     "Full House ",   45, FALSE);
  DrawPayRow(PayY + 4, Flush,         "Flush      ",   30, FALSE);
  DrawPayRow(PayY + 5, Straight,      "Straight   ",   20, FALSE);
  DrawPayRow(PayY + 6, ThreeOfAKind,  "3 of a Kind",   15, FALSE);
  DrawPayRow(PayY + 7, TwoPair,       "Two Pair   ",   10, FALSE);
  DrawPayRow(PayY + 8, OnePair,       "Jacks+     ",    5, TRUE);
  DrawPayRow(PayY + 9, OnePair,       "One Pair   ",    0, FALSE)
END DrawPayTable;

PROCEDURE DrawControls;
BEGIN
  Graphics.Goto(1, 11);
  Graphics.Color256(7, 0);
  IF phase = PhaseDraw THEN
    Out.String("  1-5: toggle HOLD    ENTER/SPACE: draw    Q: quit        ")
  ELSIF phase = PhaseShow THEN
    Out.String("  ENTER/SPACE: next hand (-$5)    R: restart    Q: quit   ")
  ELSIF phase = PhaseOver THEN
    Out.String("  Out of money!                  R: restart    Q: quit   ")
  ELSE
    Out.String("  ENTER/SPACE: deal (-$5)                     Q: quit   ")
  END;
  Graphics.Reset
END DrawControls;

PROCEDURE ClearResult;
BEGIN
  Graphics.Color256(0, 0);
  Graphics.Goto(1, 13);
  Out.String("                                                        ");
  Graphics.Reset
END ClearResult;

PROCEDURE ShowResult;
VAR fg, net : INTEGER;
BEGIN
  net := payout - Bet;
  IF    handRank >= StraightFlush THEN fg := 226
  ELSIF handRank >= FourOfAKind   THEN fg := 214
  ELSIF handRank >= FullHouse     THEN fg := 46
  ELSIF handRank >= ThreeOfAKind  THEN fg := 51
  ELSIF payout > 0                THEN fg := 15
  ELSE                                 fg := 196
  END;
  Graphics.Color256(fg, 0);
  Graphics.Goto(1, 13);
  IF    handRank = RoyalFlush    THEN Out.String("  *** ROYAL FLUSH!  Incredible! ***")
  ELSIF handRank = StraightFlush THEN Out.String("  *** STRAIGHT FLUSH!  Amazing! ***")
  ELSIF handRank = FourOfAKind   THEN Out.String("  *** FOUR OF A KIND!  Excellent!***")
  ELSIF handRank = FullHouse     THEN Out.String("  Full House!  Great hand!         ")
  ELSIF handRank = Flush         THEN Out.String("  Flush!                           ")
  ELSIF handRank = Straight      THEN Out.String("  Straight!                        ")
  ELSIF handRank = ThreeOfAKind  THEN Out.String("  Three of a Kind.                 ")
  ELSIF handRank = TwoPair       THEN Out.String("  Two Pair.                        ")
  ELSIF (handRank = OnePair) & jacksBetter
                                 THEN Out.String("  Jacks or Better.                 ")
  ELSIF handRank = OnePair       THEN Out.String("  One Pair (below Jacks).          ")
  ELSE                                Out.String("  High Card.                       ")
  END;
  IF net > 0 THEN
    Graphics.Color256(46, 0);
    Out.String("  +$"); Out.Int(net, 0); Out.String("       ")
  ELSIF net = 0 THEN
    Graphics.Color256(11, 0);
    Out.String("  push         ")
  ELSE
    Graphics.Color256(196, 0);
    Out.String("  -$"); Out.Int(Bet, 0); Out.String("       ")
  END;
  Graphics.Reset
END ShowResult;

PROCEDURE DrawMoney;
BEGIN
  Graphics.Goto(1, 15);
  IF money > 30 THEN
    Graphics.Color256(46, 0)    (* green – comfortable *)
  ELSIF money > Bet THEN
    Graphics.Color256(226, 0)   (* yellow – getting low *)
  ELSE
    Graphics.Color256(196, 0)   (* red – last hand! *)
  END;
  Out.String("  Balance: $"); Out.Int(money, 0);
  Graphics.Color256(7, 0);
  Out.String("    Hands: "); Out.Int(games, 0);
  Out.String("    Won: ");   Out.Int(won, 0);
  Out.String("             ");
  Graphics.Reset
END DrawMoney;

PROCEDURE DrawGameOver;
BEGIN
  Graphics.Color256(15, 88);
  Graphics.Goto(17, 12); Out.String("                            ");
  Graphics.Goto(17, 13); Out.String("   *** GAME  OVER ***       ");
  Graphics.Goto(17, 14); Out.String("   You ran out of money!    ");
  Graphics.Goto(17, 15); Out.String("   R = restart  Q = quit    ");
  Graphics.Goto(17, 16); Out.String("                            ");
  Graphics.Reset
END DrawGameOver;

PROCEDURE InitScreen;
BEGIN
  Graphics.Clear;
  DrawTitle;
  FOR i := 0 TO 4 DO DrawCardBack(i) END;
  DrawPayTable;
  DrawControls;
  DrawMoney;
  Graphics.Color256(242, 0);
  Graphics.Goto(1, 13);
  Out.String("  Press ENTER or SPACE to deal your first hand.  ($5/hand)");
  Graphics.Reset
END InitScreen;

(* ── Main ───────────────────────────────────────────────── *)

BEGIN
  money       := StartMoney;
  payout      := 0;
  games       := 0;
  won         := 0;
  phase       := PhaseDeal;
  jacksBetter := FALSE;
  quit        := FALSE;

  Terminal.HideCursor;
  InitScreen;

  LOOP
    key := Terminal.ReadKey();

    IF (key = 'q') OR (key = 'Q') THEN EXIT END;

    (* R = restart at any point *)
    IF (key = 'r') OR (key = 'R') THEN
      money       := StartMoney;
      payout      := 0;
      games       := 0;
      won         := 0;
      phase       := PhaseDeal;
      jacksBetter := FALSE;
      InitScreen

    ELSIF phase = PhaseDeal THEN
      IF (key = KeyEnter) OR (key = ' ') THEN
        IF money < Bet THEN
          phase := PhaseOver;
          DrawGameOver;
          DrawControls
        ELSE
          DEC(money, Bet);
          Shuffle;  DealHand;
          DrawAllCards;
          DrawPayTable;   (* clear any previous highlight *)
          ClearResult;
          DrawMoney;
          phase := PhaseDraw;
          DrawControls
        END
      END

    ELSIF phase = PhaseDraw THEN
      IF (key >= '1') & (key <= '5') THEN
        i := ORD(key) - 49;   (* '1'=49 -> slot 0 *)
        hold[i] := ~hold[i];
        DrawHold(i)
      ELSIF (key = KeyEnter) OR (key = ' ') THEN
        DrawCards;
        handRank    := ScoreHand();
        jacksBetter := IsJacksOrBetter();
        payout      := HandPayout();
        INC(money, payout);
        INC(games);
        IF payout > 0 THEN INC(won) END;
        DrawAllCards;
        ShowResult;
        DrawPayTable;   (* highlight winning row *)
        DrawMoney;
        phase := PhaseShow;
        DrawControls
      END

    ELSIF phase = PhaseShow THEN
      IF (key = KeyEnter) OR (key = ' ') THEN
        IF money < Bet THEN
          phase := PhaseOver;
          DrawGameOver;
          DrawControls
        ELSE
          DEC(money, Bet);
          Shuffle;  DealHand;
          DrawAllCards;
          DrawPayTable;   (* clear previous highlight *)
          ClearResult;
          DrawMoney;
          phase := PhaseDraw;
          DrawControls
        END
      END
    END
    (* PhaseOver: R and Q handled above; all other keys ignored *)
  END;

  Graphics.Clear;
  Graphics.Goto(1, 1);
  Out.String("Thanks for playing Video Poker!"); Out.Ln;
  Out.String("Final balance: $"); Out.Int(money, 0); Out.Ln;
  Out.String("Hands played:  "); Out.Int(games, 0); Out.Ln;
  Out.String("Hands won:     "); Out.Int(won, 0);
  IF games > 0 THEN
    Out.String("  ("); Out.Int(won * 100 DIV games, 0); Out.String("% win rate)")
  END;
  Out.Ln
END VideoPoker.
