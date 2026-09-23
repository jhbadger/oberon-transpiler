# Strategy Guide for Gardner's Minichess (5×5)

Gardner's Minichess is chess compressed onto a 5×5 board. Every piece from the standard game is present — Rook, Knight, Bishop, Queen, and King — but the reduced board changes the game so drastically that standard chess intuitions often lead you astray. This guide assumes you know how the pieces move but have never thought about chess strategy.

---

## The Starting Position

```
  a   b   c   d   e
5 [r] [n] [b] [q] [k]   ← Black's back rank
4 [p] [p] [p] [p] [p]   ← Black's pawns
3  .   .   .   .   .    ← Empty middle
2 [P] [P] [P] [P] [P]   ← White's pawns
1 [R] [N] [B] [Q] [K]   ← White's back rank
```

White plays up (pawns advance toward rank 5), Black plays down (pawns advance toward rank 1).

---

## What Makes This Game Different

### Promotions Happen Fast

In standard chess a pawn needs five moves to promote. Here, a pawn only needs to cross one empty rank (rank 3) and then one more move to land on the back rank. **A passed pawn — one with no enemy pawn blocking its file — can promote in two moves.** This completely dominates the game. If your opponent gets a passed pawn through, you may have only one move to stop it before it becomes a queen.

### The Board Is Tiny

On a 5×5 board all your pieces are within striking distance from move one. There is almost no opening phase where you develop pieces gradually. Within two or three moves, pieces will clash. Play aggressively and watch for attacks that emerge immediately.

### No Castling, No En Passant, No Double Pawn Push

Kings cannot castle to safety. Your king stays where it starts unless you manually walk it. Pawns always move one square. There is no en passant capture.

---

## Core Strategic Principles

### 1. The Center Is a Single Square

In standard chess "the center" means the four squares d4/d5/e4/e5. In 5×5 chess the true center is just **c3** — the single square equidistant from all edges. A piece on c3 attacks or controls the maximum number of squares.

**Open with c2–c3.** This one move advances a pawn to the center, opens a diagonal for your bishop, and puts an obstacle in your opponent's path. It is the most common and most sound first move.

### 2. Think About Passed Pawns Before Anything Else

Every time you look at the board, scan for passed pawns — yours and your opponent's. A passed pawn that has no enemy pawn on the same file is a clock ticking. Your other plans are secondary to either promoting your own passed pawn or stopping your opponent's.

To create a passed pawn: capture on a file where your opponent has no remaining pawn. To stop one: move a pawn of your own onto that file, or get a piece in the way.

### 3. Trades Are Dangerous

Losing a rook (worth ~5 pawns) or a queen (worth ~9) when your opponent keeps theirs is close to a death sentence on a 5×5 board. There is not enough material left for a comeback. Before any capture, ask: *what can my opponent recapture with, and is the exchange fair?*

Piece values as a rough guide:
- Pawn: 1
- Knight: 3
- Bishop: 3
- Rook: 5
- Queen: 9

Never trade a rook for a bishop or knight. Think twice before trading a queen for anything other than the enemy queen.

### 4. Your King Is a Fighter, Not a Liability

In standard chess the king hides in a corner until the endgame. Here there is no corner to hide in, and the endgame arrives within 15 moves. Your king should move toward the center as soon as the immediate danger of checkmate is low. A centralized king attacks four squares and is a real piece.

### 5. Knights Are Cramped; Bishops and Rooks Need Open Lines

Knights jump to specific squares regardless of what is in between, which sounds useful. But on a 5×5 board a knight on the edge attacks very few squares — a knight on a1 attacks only b3 and c2. Knights are best placed at c3 or nearby, and they excel at **forks** (attacking two pieces at once).

Bishops need open diagonals. The diagonal from a1 to e5 is the longest at five squares. If pawns clog the diagonals, your bishop is almost useless. Consider exchanging a bishop early if you cannot open its diagonal.

Rooks become powerful once a file is cleared of pawns. A rook on an open file menaces the whole column. One strong plan is to trade or advance the pawn on a file, then slide your rook to that file.

---

## Common Tactical Patterns

### The Fork

A fork is one piece attacking two of your opponent's pieces at once. Knights fork beautifully because they jump over everything. A knight on c3 can attack squares like a1, a5, b1, b5, d1, d5, e2, e4 — reaching far into both halves of the board.

Watch for knight forks against the king and queen. If you can move your knight to a square where it simultaneously attacks the enemy king and queen, your opponent must move the king, and you win the queen for free.

### The Skewer and the Pin

A **pin** is when a sliding piece (rook, bishop, queen) attacks an enemy piece that cannot move without exposing a more valuable piece behind it. Example: your rook on e1 attacks the enemy knight on e3, but the enemy king sits on e5 — the knight is pinned because moving it would expose the king to check.

A **skewer** is the reverse: the more valuable piece is in front. You attack the king, it must move, and the piece behind it is captured.

On a 5×5 board with short files and ranks, pins and skewers happen constantly. Always look at what sits behind the piece you are attacking.

### Promotion Races

When both sides have a passed pawn racing to promote, count moves. If your pawn promotes in two moves and the opponent's in three, you queen first, use the new queen to stop their pawn (or give check), and win. If you are going to lose the race, calculate whether you can give check in a way that forces the opponent to delay.

---

## A Sample Opening Plan (Playing White)

1. **c2–c3** — Pawn to center. Controls key squares, opens the c1-bishop's diagonal.
2. **d2–d3** — Second central pawn. Opens the queen's diagonal. Now both central pawns are advanced.
3. **Nb1–c3 or Nb1–d2** — Develop the knight toward the center or to support d3.
4. Keep the king on e1 for now; it is not under immediate threat with two pawns in front.

After this, watch the board: has your opponent created a passed pawn? Can you create one? Are there tactical shots (forks, pins)?

---

## Endgame Basics

When most pawns and pieces have been traded off, these rules apply:

- **Queen alone cannot force checkmate without king help** (against a lone king). Your king must participate.
- **Rook + King can force checkmate** even against a lone king. Drive the enemy king to the edge.
- **Pawn endgames are often winning or losing** with no middle ground. A single extra pawn that can promote usually wins. Calculate: can I queen before the opponent stops me?

---

## Summary Checklist

Before each move, ask:

1. Is my king in check or about to be mated?
2. Does my opponent have a passed pawn that will promote soon?
3. Can I capture something for free, or will my opponent recapture and win material?
4. Is there a fork, pin, or skewer available?
5. Can I advance or create a passed pawn?

The game moves fast. Tactics — immediate concrete threats — matter more here than long-term planning. Train yourself to look for double attacks and passed pawns every single turn.
