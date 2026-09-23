MODULE Tennis;
(*
 * Tennis — a text-mode port of "Boing!", the Pong-style game from
 * Chapter 1 ("Tennis") of Code the Classics Volume I (David Crookes
 * et al., Raspberry Pi Press), itself a tribute to Atari's Pong (1972).
 *
 * The ball/bat physics, AI, and scoring state machine below are ported
 * 1:1 from the book's Python/Pygame Zero source: both objects live in a
 * virtual 800x480 pixel space (VW x VH, matching the original exactly),
 * moved and collision-tested in that space, and only scaled down to the
 * character grid when drawing. The ball's direction is a normalised
 * (dx,dy) vector; each frame it takes `speed` one-pixel substeps,
 * checking for a bat/wall collision after every substep, exactly as in
 * the book — this is what keeps a fast ball from tunnelling through a
 * bat. Every time a bat returns the ball, speed increases by one and an
 * "ai_offset" is re-rolled, matching Nolan Bushnell's advice (quoted in
 * the book) to keep escalating the challenge as a rally continues.
 *
 * The AI blends two targets: screen centre when the ball is far away,
 * and the ball's own Y (plus that random offset) as it gets close —
 * "as the ball gets closer, we have a better idea of where it's going
 * to end up."
 *
 * A terminal has no continuous key-down state (unlike Pygame Zero's
 * keyboard module) — holding a key down just makes the OS re-send the
 * same character over and over, with a long initial delay before the
 * first repeat and then a much faster repeat rate. So each matching
 * keypress *refreshes* a "still held" countdown (HOLD_FRAMES) rather
 * than toggling anything: the bat keeps gliding at PLAYER_SPEED every
 * frame as long as fresh key events keep arriving, and coasts to a
 * stop shortly after they stop (i.e. after the key is released).
 * HOLD_FRAMES is sized to comfortably outlast a terminal's initial
 * auto-repeat delay, so a genuinely held key never stutters.
 *
 * Controls:
 *   1-player : W/S or Up/Down arrows move the left bat; the right bat
 *              is computer-controlled.
 *   2-player : left bat = W/S, right bat = Up/Down arrows.
 *   Up/Down on the menu — choose 1 or 2 players
 *   Space               — start game / return to menu from game over
 *   Q / Ctrl-Q / Ctrl-C — quit
 *   Ctrl-L              — force a full screen redraw
 *)

IMPORT TUI, Random, Math, Time, Strings, Out;

CONST
  (* Virtual playing-field coordinate space — identical to Boing!'s. *)
  VW = 800;  VH = 480;
  HALF_VW = 400;  HALF_VH = 240;

  PLAYER_SPEED  = 6;
  MAX_AI_SPEED  = 6;
  BAT_X_OFFSET  = 40;   (* bat's fixed distance from the left/right edge *)
  HIT_BOUNDARY  = 344;  (* ball x-distance from centre that arms a bat check *)
  HIT_HALF_H    = 64;   (* half-height of a bat's hit window *)
  BOUNCE_MARGIN = 220;  (* ball y-distance from centre that bounces off top/bottom *)
  BAT_MIN_Y     = 80;
  BAT_MAX_Y     = 400;
  START_SPEED   = 5;
  WIN_SCORE     = 10;

  (* Terminal layout: fits an 80x25 terminal comfortably. *)
  FIELD_W = 70;  FIELD_H = 18;
  FIELD_X = 6;   FIELD_Y = 5;

  FRAME_MS = 16;   (* ~60 fps — matches the frame rate the book's constants
                       (PLAYER_SPEED, ball speed, ...) were tuned for *)
  (* How long a key "stays held" after its last event, in frames at
     FRAME_MS each — must comfortably outlast a terminal's initial
     auto-repeat delay (commonly ~400-500ms). 34 frames * 16ms = 544ms. *)
  HOLD_FRAMES = 34;

  ST_MENU = 0;  ST_PLAY = 1;  ST_OVER = 2;

TYPE
  BatRec = RECORD
    bx: INTEGER;              (* fixed virtual x *)
    y: REAL;                   (* virtual y, centre of bat *)
    isAI: BOOLEAN;
    score: INTEGER;
    timer: INTEGER;
    holdUp, holdDown: INTEGER  (* frame countdown; >0 = key still "held" *)
  END;

  BallRec = RECORD
    x, y, dx, dy: REAL;
    speed: INTEGER
  END;

VAR
  bats: ARRAY 2 OF BatRec;
  ball: BallRec;
  aiOffset: INTEGER;
  state, numPlayers: INTEGER;
  running: BOOLEAN;
  colScale, rowScale: REAL;
  batRows: INTEGER;
  ev: TUI.Event;

(* ════════════════════════════════════════════════════════════════════ *)
(*  Small helpers                                                        *)
(* ════════════════════════════════════════════════════════════════════ *)

PROCEDURE IRound(x: REAL): INTEGER;
BEGIN RETURN FLOOR(x + 0.5) END IRound;

(* Scale (dx,dy) so it has length 1 — see Figure 1/2 in the book: a
   direction vector must be normalised or diagonal motion runs faster
   than horizontal/vertical motion. *)
PROCEDURE Normalize(VAR dx, dy: REAL);
VAR len: REAL;
BEGIN
  len := Math.sqrt(dx * dx + dy * dy);
  IF len > 0.0 THEN dx := dx / len; dy := dy / len END
END Normalize;

PROCEDURE Bell;
BEGIN
  Out.Char(07X);
  Out.Flush
END Bell;

(* ════════════════════════════════════════════════════════════════════ *)
(*  Game state                                                           *)
(* ════════════════════════════════════════════════════════════════════ *)

PROCEDURE BallOut(): BOOLEAN;
BEGIN RETURN (ball.x < 0.0) OR (ball.x > FLT(VW)) END BallOut;

PROCEDURE NewBall(dir: INTEGER);
BEGIN
  ball.x := FLT(HALF_VW);  ball.y := FLT(HALF_VH);
  ball.dx := FLT(dir);     ball.dy := 0.0;
  ball.speed := START_SPEED
END NewBall;

PROCEDURE InitBat(VAR b: BatRec; bx: INTEGER; ai: BOOLEAN);
BEGIN
  b.bx := bx;  b.y := FLT(HALF_VH);  b.isAI := ai;
  b.score := 0;  b.timer := 0;  b.holdUp := 0;  b.holdDown := 0
END InitBat;

(* Start a real match: left bat is always human, right bat is AI unless
   two players were chosen. *)
PROCEDURE ResetGame(np: INTEGER);
BEGIN
  numPlayers := np;
  InitBat(bats[0], BAT_X_OFFSET, FALSE);
  InitBat(bats[1], VW - BAT_X_OFFSET, np = 1);
  aiOffset := 0;
  NewBall(-1)
END ResetGame;

(* "Attract mode": two AIs volley while the menu is up, as in the book. *)
PROCEDURE ResetAttract;
BEGIN
  InitBat(bats[0], BAT_X_OFFSET, TRUE);
  InitBat(bats[1], VW - BAT_X_OFFSET, TRUE);
  aiOffset := 0;
  NewBall(-1)
END ResetAttract;

(* When the ball is far away, aim for screen centre; as it approaches,
   increasingly aim for where it will actually end up. *)
PROCEDURE AIMove(b: BatRec): REAL;
VAR xDist, w1, w2, targetY, mv: REAL;
BEGIN
  xDist := ball.x - FLT(b.bx);
  IF xDist < 0.0 THEN xDist := -xDist END;
  w1 := xDist / FLT(HALF_VW);
  IF w1 > 1.0 THEN w1 := 1.0 END;
  w2 := 1.0 - w1;
  targetY := w1 * FLT(HALF_VH) + w2 * (ball.y + FLT(aiOffset));

  mv := targetY - b.y;
  IF mv > FLT(MAX_AI_SPEED)  THEN mv := FLT(MAX_AI_SPEED)   END;
  IF mv < -FLT(MAX_AI_SPEED) THEN mv := -FLT(MAX_AI_SPEED)  END;
  RETURN mv
END AIMove;

PROCEDURE UpdateBat(VAR b: BatRec);
VAR mv: REAL;
BEGIN
  DEC(b.timer);
  IF b.holdUp   > 0 THEN DEC(b.holdUp)   END;
  IF b.holdDown > 0 THEN DEC(b.holdDown) END;

  IF b.isAI THEN
    mv := AIMove(b)
  ELSIF b.holdDown > 0 THEN mv := FLT(PLAYER_SPEED)
  ELSIF b.holdUp   > 0 THEN mv := -FLT(PLAYER_SPEED)
  ELSE mv := 0.0
  END;

  b.y := b.y + mv;
  IF b.y < FLT(BAT_MIN_Y) THEN b.y := FLT(BAT_MIN_Y) END;
  IF b.y > FLT(BAT_MAX_Y) THEN b.y := FLT(BAT_MAX_Y) END
END UpdateBat;

(* The ball only reflects off a bat if it's within the bat's hit window;
   where it lands within that window steers the return angle — "the ball
   should bounce with more obtuse angles as the edge of the paddle is
   approached" (Nolan Bushnell, quoted in the book). *)
PROCEDURE HitBat(VAR b: BatRec);
VAR diffY: REAL;
BEGIN
  diffY := ball.y - b.y;
  IF (diffY > -FLT(HIT_HALF_H)) & (diffY < FLT(HIT_HALF_H)) THEN
    ball.dx := -ball.dx;
    ball.dy := ball.dy + diffY / 128.0;
    IF ball.dy >  1.0 THEN ball.dy :=  1.0 END;
    IF ball.dy < -1.0 THEN ball.dy := -1.0 END;
    Normalize(ball.dx, ball.dy);

    INC(ball.speed);
    aiOffset := Random.Int(21) - 10;  (* -10..10, re-rolled on every return *)
    b.timer := 10;
    Bell
  END
END HitBat;

(* Move the ball one substep at a time (as many as `speed`), testing for
   a bat or wall collision after each substep — this is what stops a
   fast ball tunnelling straight through a bat, per the book's
   "stepping through time" section. *)
PROCEDURE UpdateBall;
VAR i, idx: INTEGER;  origX: REAL;
BEGIN
  FOR i := 1 TO ball.speed DO
    origX := ball.x;
    ball.x := ball.x + ball.dx;
    ball.y := ball.y + ball.dy;

    IF (ABS(ball.x - FLT(HALF_VW)) >= FLT(HIT_BOUNDARY)) &
       (ABS(origX   - FLT(HALF_VW)) <  FLT(HIT_BOUNDARY)) THEN
      IF ball.x < FLT(HALF_VW) THEN idx := 0 ELSE idx := 1 END;
      HitBat(bats[idx])
    END;

    IF ABS(ball.y - FLT(HALF_VH)) > FLT(BOUNCE_MARGIN) THEN
      ball.dy := -ball.dy;
      ball.y := ball.y + ball.dy
    END
  END
END UpdateBall;

(* Scoring is gated on the losing bat's timer, exactly as in the book:
   a fresh point is awarded the instant the ball goes out (timer < 0 —
   i.e. well past its last hit-flash), then the game waits for that
   same timer to count down from 20 to 0 before serving a new ball
   toward whoever just missed, giving them the next touch. *)
PROCEDURE UpdateGame;
VAR scoring, losing, dir: INTEGER;
BEGIN
  UpdateBat(bats[0]);
  UpdateBat(bats[1]);
  UpdateBall;

  IF BallOut() THEN
    IF ball.x < FLT(HALF_VW) THEN scoring := 1 ELSE scoring := 0 END;
    losing := 1 - scoring;

    IF bats[losing].timer < 0 THEN
      INC(bats[scoring].score);
      bats[losing].timer := 20;
      Bell
    ELSIF bats[losing].timer = 0 THEN
      IF losing = 0 THEN dir := -1 ELSE dir := 1 END;
      NewBall(dir)
    END
  END
END UpdateGame;

(* ════════════════════════════════════════════════════════════════════ *)
(*  Drawing                                                              *)
(* ════════════════════════════════════════════════════════════════════ *)

PROCEDURE ScreenCol(vx: REAL): INTEGER;
BEGIN RETURN FIELD_X + IRound(vx * colScale) END ScreenCol;

PROCEDURE ScreenRow(vy: REAL): INTEGER;
BEGIN RETURN FIELD_Y + IRound(vy * rowScale) END ScreenRow;

PROCEDURE PutCenteredBox(bx, bw, row: INTEGER; s: ARRAY OF CHAR; fg, bg: INTEGER);
VAR x, len: INTEGER;
BEGIN
  len := Strings.Length(s);
  x := bx + (bw - len) DIV 2;
  TUI.PutStr(x, row, s, fg, bg)
END PutCenteredBox;

PROCEDURE PutCentered(row: INTEGER; s: ARRAY OF CHAR; fg, bg: INTEGER);
BEGIN PutCenteredBox(FIELD_X, FIELD_W, row, s, fg, bg) END PutCentered;

PROCEDURE DrawNet;
VAR col, r: INTEGER;
BEGIN
  col := FIELD_X + FIELD_W DIV 2;
  r := FIELD_Y;
  WHILE r < FIELD_Y + FIELD_H DO
    TUI.PutCell(col, r, ':', TUI.White, TUI.Black);
    INC(r, 2)
  END
END DrawNet;

PROCEDURE DrawBat(b: BatRec; color: INTEGER);
VAR col, top, r, useColor: INTEGER;
BEGIN
  col := ScreenCol(FLT(b.bx));
  top := ScreenRow(b.y) - batRows DIV 2;
  useColor := color;
  IF (b.timer > 0) & ~BallOut() THEN useColor := TUI.BrightWhite END;
  FOR r := top TO top + batRows - 1 DO
    TUI.PutCell(col, r, '#', useColor, TUI.Black)
  END
END DrawBat;

PROCEDURE DrawBall;
BEGIN
  IF ~BallOut() THEN
    TUI.PutCell(ScreenCol(ball.x), ScreenRow(ball.y), 'O', TUI.BrightWhite, TUI.Black)
  END
END DrawBall;

PROCEDURE DrawMessageRow;
BEGIN
  IF (state = ST_PLAY) & BallOut() THEN
    IF bats[0].timer > 0 THEN
      PutCentered(3, "PLAYER 2 SCORES!", TUI.BrightGreen, TUI.Black)
    ELSIF bats[1].timer > 0 THEN
      PutCentered(3, "PLAYER 1 SCORES!", TUI.BrightGreen, TUI.Black)
    END
  END
END DrawMessageRow;

PROCEDURE DrawHintRow;
VAR row: INTEGER;
BEGIN
  row := FIELD_Y + FIELD_H + 1;
  IF state = ST_PLAY THEN
    IF numPlayers = 1 THEN
      PutCentered(row, "Hold W/S or Up/Down to move    Q: quit", TUI.White, TUI.Black)
    ELSE
      PutCentered(row, "P1: W/S   P2: Up/Down   Q: quit", TUI.White, TUI.Black)
    END
  END
END DrawHintRow;

PROCEDURE DrawMenuOverlay;
VAR bx, by, bw, bh, fg1, fg2: INTEGER;
BEGIN
  bw := 42;  bh := 10;
  bx := FIELD_X + (FIELD_W - bw) DIV 2;
  by := FIELD_Y + (FIELD_H - bh) DIV 2;

  TUI.FillRect(bx, by, bw, bh, ' ', TUI.White, TUI.Black);
  TUI.DrawBox(bx, by, bw, bh, TUI.BrightWhite, TUI.Black);

  PutCenteredBox(bx, bw, by + 1, "T E N N I S", TUI.BrightWhite, TUI.Black);
  PutCenteredBox(bx, bw, by + 2, "a text-mode tribute to Boing!/Pong", TUI.White, TUI.Black);

  IF numPlayers = 1 THEN fg1 := TUI.BrightGreen ELSE fg1 := TUI.White END;
  IF numPlayers = 2 THEN fg2 := TUI.BrightGreen ELSE fg2 := TUI.White END;
  PutCenteredBox(bx, bw, by + 4, "1 PLAYER  (vs computer)", fg1, TUI.Black);
  PutCenteredBox(bx, bw, by + 5, "2 PLAYERS (vs friend)",   fg2, TUI.Black);

  PutCenteredBox(bx, bw, by + 7, "Up/Down choose   Space start", TUI.White, TUI.Black);
  PutCenteredBox(bx, bw, by + 8, "Q quit", TUI.White, TUI.Black)
END DrawMenuOverlay;

PROCEDURE DrawGameOverOverlay;
VAR bx, by, bw, bh, winner: INTEGER;
BEGIN
  bw := 36;  bh := 7;
  bx := FIELD_X + (FIELD_W - bw) DIV 2;
  by := FIELD_Y + (FIELD_H - bh) DIV 2;

  TUI.FillRect(bx, by, bw, bh, ' ', TUI.White, TUI.Black);
  TUI.DrawBox(bx, by, bw, bh, TUI.BrightWhite, TUI.Black);

  IF bats[0].score > bats[1].score THEN winner := 1 ELSE winner := 2 END;
  PutCenteredBox(bx, bw, by + 1, "GAME OVER", TUI.BrightWhite, TUI.Black);
  IF winner = 1 THEN
    PutCenteredBox(bx, bw, by + 3, "PLAYER 1 WINS!", TUI.Cyan, TUI.Black)
  ELSE
    PutCenteredBox(bx, bw, by + 3, "PLAYER 2 WINS!", TUI.Yellow, TUI.Black)
  END;
  PutCenteredBox(bx, bw, by + 5, "Space for menu    Q quit", TUI.White, TUI.Black)
END DrawGameOverOverlay;

PROCEDURE DrawScreen;
BEGIN
  TUI.ClearBack(TUI.White, TUI.Black);

  PutCentered(1, "TENNIS", TUI.BrightWhite, TUI.Black);
  TUI.PutStr(FIELD_X, 2, "PLAYER 1", TUI.Cyan, TUI.Black);
  TUI.PutInt(FIELD_X + 9, 2, bats[0].score, TUI.Cyan, TUI.Black);
  TUI.PutStr(FIELD_X + FIELD_W - 11, 2, "PLAYER 2", TUI.Yellow, TUI.Black);
  TUI.PutInt(FIELD_X + FIELD_W - 2, 2, bats[1].score, TUI.Yellow, TUI.Black);

  DrawMessageRow;

  TUI.DrawBox(FIELD_X - 1, FIELD_Y - 1, FIELD_W + 2, FIELD_H + 2, TUI.White, TUI.Black);
  DrawNet;
  DrawBat(bats[0], TUI.Cyan);
  DrawBat(bats[1], TUI.Yellow);
  DrawBall;

  DrawHintRow;

  IF state = ST_MENU THEN DrawMenuOverlay
  ELSIF state = ST_OVER THEN DrawGameOverOverlay
  END;

  TUI.Flush
END DrawScreen;

(* ════════════════════════════════════════════════════════════════════ *)
(*  Input                                                                *)
(* ════════════════════════════════════════════════════════════════════ *)

PROCEDURE HandleKey(k: CHAR);
BEGIN
  IF (k = 'q') OR (k = 'Q') OR (ORD(k) = 17) OR (ORD(k) = 3) THEN
    running := FALSE;  RETURN
  END;
  IF ORD(k) = 12 THEN TUI.InvalidateFront;  RETURN END;

  IF state = ST_MENU THEN
    IF k = ' ' THEN
      ResetGame(numPlayers);  state := ST_PLAY
    ELSIF (k = TUI.KUp) & (numPlayers = 2) THEN numPlayers := 1
    ELSIF (k = TUI.KDown) & (numPlayers = 1) THEN numPlayers := 2
    END
  ELSIF state = ST_PLAY THEN
    IF (k = 'w') OR (k = 'W') THEN bats[0].holdUp := HOLD_FRAMES
    ELSIF (k = 's') OR (k = 'S') THEN bats[0].holdDown := HOLD_FRAMES
    ELSIF k = TUI.KUp THEN
      IF numPlayers = 1 THEN bats[0].holdUp := HOLD_FRAMES ELSE bats[1].holdUp := HOLD_FRAMES END
    ELSIF k = TUI.KDown THEN
      IF numPlayers = 1 THEN bats[0].holdDown := HOLD_FRAMES ELSE bats[1].holdDown := HOLD_FRAMES END
    END
  ELSIF state = ST_OVER THEN
    IF k = ' ' THEN
      state := ST_MENU;  numPlayers := 1;  ResetAttract
    END
  END
END HandleKey;

(* ════════════════════════════════════════════════════════════════════ *)
(*  Entry point                                                          *)
(* ════════════════════════════════════════════════════════════════════ *)

BEGIN
  Random.Randomize;
  TUI.Init;
  TUI.UpdateSize;

  colScale := FLT(FIELD_W) / FLT(VW);
  rowScale := FLT(FIELD_H) / FLT(VH);
  batRows := IRound(FLT(HIT_HALF_H * 2) * rowScale);
  IF batRows < 3 THEN batRows := 3 END;

  numPlayers := 1;
  state := ST_MENU;
  ResetAttract;
  running := TRUE;

  WHILE running DO
    WHILE TUI.PollEvent(ev) DO
      IF ev.kind = TUI.EvResize THEN
        TUI.UpdateSize;  TUI.InvalidateFront
      ELSIF ev.kind = TUI.EvKey THEN
        HandleKey(ev.key)
      END
    END;

    IF running THEN
      IF state # ST_OVER THEN
        UpdateGame;
        IF (state = ST_PLAY) &
           ((bats[0].score >= WIN_SCORE) OR (bats[1].score >= WIN_SCORE)) THEN
          state := ST_OVER
        END
      END;
      DrawScreen;
      Time.Sleep(FRAME_MS)
    END
  END;

  TUI.Done
END Tennis.
