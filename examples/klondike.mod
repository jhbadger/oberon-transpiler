MODULE Klondike;
(*
 * Klondike Solitaire.
 *
 * Click Stock to draw a card.  Click a face-up card to select it (and
 * any sequence below it in the tableau), then click a destination pile
 * to move.  Click the same card again to deselect.
 *
 * N = new game   Esc = quit
 *)

IMPORT TUI, Widgets, Random;

CONST
  Club = 0; Diamond = 1; Heart = 2; Spade = 3;

  CardW = 7; CardH = 5;
  PileX = 2; PileY = 2;
  Spacing = 9;

  FaceDownOff = 1;   (* rows between face-down cards in tableau fan *)
  FaceUpOff   = 2;   (* rows between face-up   cards in tableau fan *)

TYPE
  Card = RECORD
    rank   : INTEGER;   (* 1=A  2..10  11=J  12=Q  13=K *)
    suit   : INTEGER;
    faceUp : BOOLEAN
  END;

  Pile    = POINTER TO PileRec;
  PileRec = RECORD (TUI.ViewRec)
    cards     : ARRAY 52 OF Card;
    count     : INTEGER;
    isTableau : BOOLEAN
  END;

VAR
  Deck       : ARRAY 52 OF Card;
  Tableau    : ARRAY 7 OF Pile;
  Foundation : ARRAY 4 OF Pile;
  Stock, Waste : Pile;
  Status     : Widgets.StatusLine;
  SelPile    : Pile;
  SelIdx     : INTEGER;
  Won        : BOOLEAN;

(* ── Helpers ─────────────────────────────────────────────────────── *)

PROCEDURE IsRed(suit: INTEGER): BOOLEAN;
BEGIN RETURN (suit = Heart) OR (suit = Diamond) END IsRed;

(* Screen-y of card i's top row inside pile p *)
PROCEDURE CardTopY(p: Pile; i: INTEGER): INTEGER;
VAR j, y: INTEGER;
BEGIN
  y := p.y;
  IF p.isTableau THEN
    FOR j := 0 TO i - 1 DO
      IF p.cards[j].faceUp THEN INC(y, FaceUpOff)
      ELSE                      INC(y, FaceDownOff)
      END
    END
  END;
  RETURN y
END CardTopY;

PROCEDURE SetMsg(msg: ARRAY OF CHAR);
BEGIN
  COPY(msg, Status.text)
END SetMsg;

(* ── Card / Pile drawing ─────────────────────────────────────────── *)

(* Single-byte suit character: C D H S *)
PROCEDURE SuitChar(suit: INTEGER): CHAR;
BEGIN
  IF suit = Club    THEN RETURN 'C'
  ELSIF suit = Diamond THEN RETURN 'D'
  ELSIF suit = Heart   THEN RETURN 'H'
  ELSE                      RETURN 'S'
  END
END SuitChar;

PROCEDURE DrawOneCard(x, y, rank, suit: INTEGER; faceUp, sel: BOOLEAN);
VAR fg, bg, rx: INTEGER; sc: CHAR; rs: ARRAY 3 OF CHAR;
BEGIN
  IF faceUp THEN
    bg := TUI.White;
    IF IsRed(suit) THEN fg := TUI.Red ELSE fg := TUI.Black END
  ELSE
    bg := TUI.Blue; fg := TUI.White
  END;
  IF sel THEN bg := TUI.Yellow; fg := TUI.Black END;

  TUI.DrawBox(x, y, CardW, CardH, fg, bg);
  TUI.FillRect(x + 1, y + 1, CardW - 2, CardH - 2, ' ', fg, bg);

  IF faceUp THEN
    IF    rank =  1 THEN rs[0] := 'A'; rs[1] := 0X
    ELSIF rank = 10 THEN rs[0] := '1'; rs[1] := '0'; rs[2] := 0X
    ELSIF rank = 11 THEN rs[0] := 'J'; rs[1] := 0X
    ELSIF rank = 12 THEN rs[0] := 'Q'; rs[1] := 0X
    ELSIF rank = 13 THEN rs[0] := 'K'; rs[1] := 0X
    ELSE  rs[0] := CHR(ORD('0') + rank); rs[1] := 0X
    END;
    sc := SuitChar(suit);

    (* Top row: rank at left, suit at right — both always visible in fan *)
    TUI.PutStr( x + 1,         y + 1, rs, fg, bg);
    TUI.PutCell(x + CardW - 2, y + 1, sc, fg, bg);

    (* Bottom row (only seen on the last fully-exposed card):
       suit at left, rank right-aligned *)
    IF rank = 10 THEN rx := x + CardW - 3 ELSE rx := x + CardW - 2 END;
    TUI.PutCell(x + 1, y + CardH - 2, sc,  fg, bg);
    TUI.PutStr( rx,    y + CardH - 2, rs,  fg, bg)
  ELSE
    TUI.FillRect(x + 1, y + 1, CardW - 2, CardH - 2, '#', fg, bg)
  END
END DrawOneCard;

PROCEDURE DrawPile(v: TUI.View);
VAR p: Pile; i: INTEGER; sel: BOOLEAN;
BEGIN
  p := v(PileRec);
  IF p.count = 0 THEN
    TUI.DrawBox(p.x, p.y, CardW, CardH, TUI.White, TUI.Green)
  ELSE
    FOR i := 0 TO p.count - 1 DO
      sel := (p = SelPile) & (i >= SelIdx);
      DrawOneCard(p.x, CardTopY(p, i),
                  p.cards[i].rank, p.cards[i].suit,
                  p.cards[i].faceUp, sel)
    END
  END
END DrawPile;

(* ── Pile creation ────────────────────────────────────────────────── *)

PROCEDURE NewPile(x, y: INTEGER; isTableau: BOOLEAN): Pile;
VAR p: Pile;
BEGIN
  NEW(p);
  p.x := x; p.y := y;
  p.w := CardW;
  IF isTableau THEN p.h := TUI.Rows - y - 1 ELSE p.h := CardH END;
  p.count := 0; p.isTableau := isTableau;
  p.draw  := DrawPile;
  p.next  := NIL; p.child := NIL;
  p.focused := 0; p.alwaysOnTop := 0;
  TUI.AddView(p);
  RETURN p
END NewPile;

(* ── Shuffle ─────────────────────────────────────────────────────── *)

PROCEDURE Shuffle;
VAR i, j: INTEGER; t: Card;
BEGIN
  FOR i := 51 TO 1 BY -1 DO
    j := Random.Int(i + 1);
    t := Deck[i]; Deck[i] := Deck[j]; Deck[j] := t
  END
END Shuffle;

(* ── Move validation ──────────────────────────────────────────────── *)

PROCEDURE CanMoveToFoundation(c: Card): BOOLEAN;
VAR f: Pile;
BEGIN
  f := Foundation[c.suit];
  IF f.count = 0 THEN RETURN c.rank = 1
  ELSE RETURN c.rank = f.cards[f.count - 1].rank + 1
  END
END CanMoveToFoundation;

PROCEDURE CanMoveToTableau(c: Card; dest: Pile): BOOLEAN;
VAR top: Card;
BEGIN
  IF dest.count = 0 THEN RETURN c.rank = 13
  ELSE
    top := dest.cards[dest.count - 1];
    RETURN top.faceUp & (top.rank = c.rank + 1) &
           (IsRed(top.suit) # IsRed(c.suit))
  END
END CanMoveToTableau;

(* Move cards src[fromIdx..count-1] to dst; auto-flip new src top *)
PROCEDURE MoveCards(src: Pile; fromIdx: INTEGER; dst: Pile);
VAR i: INTEGER;
BEGIN
  FOR i := fromIdx TO src.count - 1 DO
    dst.cards[dst.count] := src.cards[i];
    INC(dst.count)
  END;
  src.count := fromIdx;
  IF src.isTableau & (src.count > 0) & ~src.cards[src.count - 1].faceUp THEN
    src.cards[src.count - 1].faceUp := TRUE
  END
END MoveCards;

PROCEDURE CheckWin;
VAR i: INTEGER;
BEGIN
  Won := TRUE;
  FOR i := 0 TO 3 DO
    IF Foundation[i].count # 13 THEN Won := FALSE END
  END;
  IF Won THEN SetMsg("*** YOU WIN!  Press N for a new game. ***") END
END CheckWin;

(* ── Hit-testing ─────────────────────────────────────────────────── *)

PROCEDURE PileHit(p: Pile; mx, my: INTEGER): BOOLEAN;
VAR h: INTEGER;
BEGIN
  IF (mx < p.x) OR (mx >= p.x + CardW) THEN RETURN FALSE END;
  IF p.isTableau & (p.count > 0) THEN
    h := CardTopY(p, p.count - 1) + CardH;
    RETURN (my >= p.y) & (my < h)
  ELSE
    RETURN (my >= p.y) & (my < p.y + CardH)
  END
END PileHit;

(* Index of the card in p that covers screen row my. *)
PROCEDURE CardIdxAt(p: Pile; my: INTEGER): INTEGER;
VAR i, best: INTEGER;
BEGIN
  IF p.count = 0 THEN RETURN -1 END;
  IF ~p.isTableau THEN RETURN p.count - 1 END;
  best := 0;
  FOR i := 0 TO p.count - 1 DO
    IF my >= CardTopY(p, i) THEN best := i END
  END;
  RETURN best
END CardIdxAt;

PROCEDURE FindPileAt(mx, my: INTEGER): Pile;
VAR i: INTEGER;
BEGIN
  IF PileHit(Stock, mx, my)  THEN RETURN Stock END;
  IF PileHit(Waste, mx, my)  THEN RETURN Waste END;
  FOR i := 0 TO 3 DO
    IF PileHit(Foundation[i], mx, my) THEN RETURN Foundation[i] END
  END;
  FOR i := 0 TO 6 DO
    IF PileHit(Tableau[i], mx, my) THEN RETURN Tableau[i] END
  END;
  RETURN NIL
END FindPileAt;

(* ── Click handler ───────────────────────────────────────────────── *)

PROCEDURE HandleClick(mx, my: INTEGER);
VAR p: Pile; idx, i: INTEGER; c: Card; moved: BOOLEAN;
BEGIN
  IF Won THEN RETURN END;
  p := FindPileAt(mx, my);

  (* ── Stock: deal or recycle ── *)
  IF p = Stock THEN
    SelPile := NIL;
    IF Stock.count > 0 THEN
      Stock.cards[Stock.count - 1].faceUp := TRUE;
      Waste.cards[Waste.count] := Stock.cards[Stock.count - 1];
      INC(Waste.count); DEC(Stock.count);
      SetMsg("Drew a card.")
    ELSIF Waste.count > 0 THEN
      FOR i := Waste.count - 1 TO 0 BY -1 DO
        Waste.cards[i].faceUp := FALSE;
        Stock.cards[Stock.count] := Waste.cards[i];
        INC(Stock.count)
      END;
      Waste.count := 0;
      SetMsg("Recycled waste to stock.")
    ELSE
      SetMsg("No cards left.")
    END;
    RETURN
  END;

  (* ── Have a selection: try to move ── *)
  IF SelPile # NIL THEN
    moved := FALSE;
    c     := SelPile.cards[SelIdx];

    IF p = NIL THEN
      SelPile := NIL; SetMsg(""); RETURN
    END;

    IF p = SelPile THEN
      (* Clicked same pile: reselect lower card or deselect *)
      idx := CardIdxAt(p, my);
      IF (idx >= 0) & (idx # SelIdx) & p.cards[idx].faceUp THEN
        SelIdx := idx; SetMsg("Re-selected.")
      ELSE
        SelPile := NIL; SetMsg("")
      END;
      RETURN
    END;

    (* Try foundation *)
    FOR i := 0 TO 3 DO
      IF (p = Foundation[i]) & ~moved THEN
        IF (SelIdx = SelPile.count - 1) & CanMoveToFoundation(c) THEN
          MoveCards(SelPile, SelIdx, Foundation[c.suit]);
          SelPile := NIL; moved := TRUE;
          SetMsg("Moved to foundation!");
          CheckWin
        ELSE
          SetMsg("Can't go to foundation."); SelPile := NIL
        END
      END
    END;
    IF moved THEN RETURN END;

    (* Try tableau *)
    FOR i := 0 TO 6 DO
      IF (p = Tableau[i]) & ~moved THEN
        IF CanMoveToTableau(c, Tableau[i]) THEN
          MoveCards(SelPile, SelIdx, Tableau[i]);
          SelPile := NIL; moved := TRUE; SetMsg("Moved!")
        ELSE
          SetMsg("Invalid move."); SelPile := NIL
        END
      END
    END;
    IF moved THEN RETURN END;

    SelPile := NIL   (* clicked something else – deselect and fall through *)
  END;

  (* ── No selection: try to select clicked card ── *)
  IF p = NIL     THEN SetMsg(""); RETURN END;
  IF p.count = 0 THEN RETURN END;
  idx := CardIdxAt(p, my);
  IF (idx < 0) OR ~p.cards[idx].faceUp THEN
    SetMsg("That card is face down."); RETURN
  END;
  SelPile := p; SelIdx := idx;
  SetMsg("Selected.  Click destination.")
END HandleClick;

(* ── Game initialisation ─────────────────────────────────────────── *)

PROCEDURE InitGame;
VAR i, j, n: INTEGER;
BEGIN
  SelPile := NIL; SelIdx := 0; Won := FALSE;

  (* Build and shuffle the deck *)
  n := 0;
  FOR i := 0 TO 3 DO
    FOR j := 1 TO 13 DO
      Deck[n].suit := i; Deck[n].rank := j; Deck[n].faceUp := FALSE;
      INC(n)
    END
  END;
  Shuffle;

  (* Stock and Waste *)
  Stock := NewPile(PileX, PileY, FALSE);
  Waste := NewPile(PileX + Spacing, PileY, FALSE);

  (* Four foundation piles (columns 3-6) *)
  FOR i := 0 TO 3 DO
    Foundation[i] := NewPile(PileX + (i + 3) * Spacing, PileY, FALSE)
  END;

  (* Seven tableau columns *)
  n := 0;
  FOR i := 0 TO 6 DO
    Tableau[i] := NewPile(PileX + i * Spacing, PileY + CardH + 2, TRUE);
    FOR j := 0 TO i DO
      Tableau[i].cards[j] := Deck[n]; INC(n); INC(Tableau[i].count)
    END;
    Tableau[i].cards[Tableau[i].count - 1].faceUp := TRUE
  END;

  (* Remaining cards to stock (face-down) *)
  WHILE n < 52 DO
    Stock.cards[Stock.count] := Deck[n]; INC(n); INC(Stock.count)
  END;

  Status := Widgets.NewStatusLine(1, TUI.Rows, TUI.Cols,
    "Click Stock to draw. Click card to select. N=new  Esc=quit");
  TUI.AddView(Status)
END InitGame;

PROCEDURE ClearGame;
VAR i: INTEGER;
BEGIN
  IF Stock  # NIL THEN TUI.RemoveView(Stock)  END;
  IF Waste  # NIL THEN TUI.RemoveView(Waste)  END;
  IF Status # NIL THEN TUI.RemoveView(Status) END;
  FOR i := 0 TO 3 DO
    IF Foundation[i] # NIL THEN TUI.RemoveView(Foundation[i]) END;
    Foundation[i] := NIL
  END;
  FOR i := 0 TO 6 DO
    IF Tableau[i] # NIL THEN TUI.RemoveView(Tableau[i]) END;
    Tableau[i] := NIL
  END;
  Stock := NIL; Waste := NIL; Status := NIL;
  SelPile := NIL; SelIdx := 0
END ClearGame;

PROCEDURE NewGame;
BEGIN
  ClearGame; InitGame
END NewGame;

(* ── Main loop ───────────────────────────────────────────────────── *)

PROCEDURE Run;
VAR ev: TUI.Event;
BEGIN
  TUI.Init;
  InitGame;
  REPEAT
    TUI.ClearBack(TUI.White, TUI.Green);
    TUI.DrawAll;
    TUI.Flush;
    TUI.WaitEvent(ev);
    IF ev.kind = TUI.EvKey THEN
      IF ev.key = TUI.KEsc THEN
        TUI.ModalResult := 1
      ELSIF (ev.key = 'n') OR (ev.key = 'N') THEN
        NewGame
      END
    ELSIF ev.kind = TUI.EvMouse THEN
      IF ev.mb = 0 THEN HandleClick(ev.mx, ev.my) END
    END
  UNTIL TUI.ModalResult # 0;
  TUI.Done
END Run;

BEGIN
  SelPile := NIL; SelIdx := 0; Won := FALSE;
  Stock := NIL; Waste := NIL; Status := NIL;
  Run
END Klondike.
