MODULE Ceefax;

(*
 * Ceefax — a terminal Viewdata/Teletext client for the CEEFAX service
 * run by the Matrix Network (teletext.matrixnetwork.co.uk:48065), modelled
 * on MatrixBrandy's examples/Mode7/telstar BBC BASIC client.
 *
 * The server speaks Viewdata: printable bytes are written at the cursor,
 * ESC + c inserts the teletext control code (c MOD 32), and 08/09/0A/0B/
 * 0C/0D/1E move the cursor or clear the screen.  This program keeps a
 * 40x24 Mode 7 page in memory and renders it in the terminal with the
 * Level 1 serial-attribute rules: alpha/mosaic colours, background,
 * flash, conceal, hold graphics and double height.  Mosaic cells are
 * drawn with the Unicode "Symbols for Legacy Computing" sextants.
 *
 * Usage:  ceefax [host [port]]
 *
 * Keys:
 *   0-9          type a page number (e.g. 101)
 *   Up / Down    next / previous page
 *   Enter or #   send '#' (Viewdata "send" key)
 *   Ctrl-R       toggle reveal (concealed text)
 *   Ctrl-L       redraw the screen
 *   Ctrl-D       disconnect      R  reconnect (when disconnected)
 *   Ctrl-X, Ctrl-C, Esc   quit
 *)

IMPORT TUI, Terminal, Net, Args, Strings;

CONST
  DefHost  = "teletext.matrixnetwork.co.uk";
  DefPort  = 48065;
  W        = 40;   (* Mode 7 columns *)
  H        = 24;   (* Mode 7 rows used by the page *)
  FlashMs  = 600;  (* half-period of flashing text *)

  (* Teletext colours as xterm-256 indices, so a terminal theme can't
     dull them: black, red, green, yellow, blue, magenta, cyan, white. *)
  C0 = 16;  C1 = 196;  C2 = 46;  C3 = 226;
  C4 = 21;  C5 = 201;  C6 = 51;  C7 = 231;

VAR
  scr: ARRAY H, W OF INTEGER;   (* 0..31 = control code, 32..127 = char *)
  curX, curY: INTEGER;
  pal: ARRAY 8 OF INTEGER;

  host: ARRAY 256 OF CHAR;
  port: INTEGER;
  fd: INTEGER;
  connected: BOOLEAN;

  escPending: BOOLEAN;   (* last byte was ESC *)
  iacSkip: INTEGER;      (* telnet IAC bytes still to swallow *)

  reveal, flashPhase, dirty, quit: BOOLEAN;
  lastFlash: LONGINT;
  ox, oy: INTEGER;       (* 1-based screen position of page cell (0,0) *)
  status: ARRAY 128 OF CHAR;

(* ── Page memory ─────────────────────────────────────────────────────── *)

PROCEDURE ClearPage;
VAR r, c: INTEGER;
BEGIN
  FOR r := 0 TO H - 1 DO
    FOR c := 0 TO W - 1 DO scr[r][c] := 32 END
  END;
  curX := 0;  curY := 0
END ClearPage;

(* Write one cell at the cursor and advance, wrapping like the BBC Micro
   text window telstar uses (0,0)-(39,23). *)
PROCEDURE PutCode(code: INTEGER);
BEGIN
  scr[curY][curX] := code;
  INC(curX);
  IF curX >= W THEN
    curX := 0;  INC(curY);
    IF curY >= H THEN curY := 0 END
  END
END PutCode;

PROCEDURE Recv(b: INTEGER);
BEGIN
  IF iacSkip > 0 THEN
    DEC(iacSkip)
  ELSIF b = 255 THEN
    iacSkip := 2                      (* telnet IAC <cmd> <opt> *)
  ELSIF escPending THEN
    escPending := FALSE;
    PutCode(b MOD 32)
  ELSIF b >= 128 THEN
    PutCode(b - 128)                  (* 8-bit form: 80-9F codes, A0-FF chars *)
  ELSIF b >= 32 THEN
    PutCode(b)
  ELSIF b = 27 THEN
    escPending := TRUE
  ELSIF b = 8 THEN
    IF curX > 0 THEN DEC(curX)
    ELSE
      curX := W - 1;
      IF curY > 0 THEN DEC(curY) ELSE curY := H - 1 END
    END
  ELSIF b = 9 THEN
    INC(curX);
    IF curX >= W THEN
      curX := 0;  INC(curY);
      IF curY >= H THEN curY := 0 END
    END
  ELSIF b = 10 THEN
    INC(curY);  IF curY >= H THEN curY := 0 END
  ELSIF b = 11 THEN
    IF curY > 0 THEN DEC(curY) ELSE curY := H - 1 END
  ELSIF b = 12 THEN
    ClearPage
  ELSIF b = 13 THEN
    curX := 0
  ELSIF b = 30 THEN
    curX := 0;  curY := 0
  END
  (* 17/20 (cursor on/off) and anything else are ignored *)
END Recv;

(* Page number shown in the header ("  P101"), or -1. *)
PROCEDURE CurrentPage(): INTEGER;
VAR i, n, c: INTEGER;
BEGIN
  n := -1;
  IF scr[0][2] = ORD("P") THEN
    n := 0;  i := 3;
    WHILE (n >= 0) & (i <= 5) DO
      c := scr[0][i];
      IF (c >= ORD("0")) & (c <= ORD("9")) THEN n := n * 10 + c - ORD("0")
      ELSE n := -1 END;
      INC(i)
    END
  END;
  RETURN n
END CurrentPage;

(* ── Glyph output ────────────────────────────────────────────────────── *)

PROCEDURE Put1(x, y, ch, fg, bg: INTEGER);
BEGIN
  TUI.PutCell(ox + x, oy + y, CHR(ch), fg, bg)
END Put1;

PROCEDURE Put2(x, y, b1, b2, fg, bg: INTEGER);
BEGIN
  TUI.PutCellMB(ox + x, oy + y, CHR(b1), CHR(b2), 0X, 0X, fg, bg)
END Put2;

PROCEDURE Put3(x, y, b1, b2, b3, fg, bg: INTEGER);
BEGIN
  TUI.PutCellMB(ox + x, oy + y, CHR(b1), CHR(b2), CHR(b3), 0X, fg, bg)
END Put3;

(* Draw a 2x3 mosaic.  s bits: 0 TL, 1 TR, 2 ML, 3 MR, 4 BL, 5 BR. *)
PROCEDURE PutSextant(x, y, s, fg, bg: INTEGER);
VAR i: INTEGER;
BEGIN
  IF s = 0 THEN Put1(x, y, 32, fg, bg)
  ELSIF s = 63 THEN Put3(x, y, 0E2H, 096H, 088H, fg, bg)    (* █ *)
  ELSIF s = 21 THEN Put3(x, y, 0E2H, 096H, 08CH, fg, bg)    (* ▌ *)
  ELSIF s = 42 THEN Put3(x, y, 0E2H, 096H, 090H, fg, bg)    (* ▐ *)
  ELSE
    (* U+1FB00.. lists sextants 1..62 in order, skipping 21 and 42 *)
    i := s - 1;
    IF s > 21 THEN DEC(i) END;
    IF s > 42 THEN DEC(i) END;
    TUI.PutCellMB(ox + x, oy + y, 0F0X, 09FX, 0ACX, CHR(080H + i), fg, bg)
  END
END PutSextant;

(* Sextant pattern of a mosaic character code. *)
PROCEDURE SextantOf(c: INTEGER): INTEGER;
VAR s: INTEGER;
BEGIN
  s := c MOD 32;
  IF (c DIV 64) MOD 2 = 1 THEN s := s + 32 END;
  RETURN s
END SextantOf;

(* Stretch one half of a mosaic to fill a double-height cell.
   Rows of s: r0 = bits 0-1, r1 = bits 2-3, r2 = bits 4-5. *)
PROCEDURE StretchSextant(s: INTEGER; bottom: BOOLEAN): INTEGER;
VAR r0, r1, r2: INTEGER;
BEGIN
  r0 := s MOD 4;  r1 := (s DIV 4) MOD 4;  r2 := (s DIV 16) MOD 4;
  IF bottom THEN RETURN r1 + r2 * 4 + r2 * 16
  ELSE RETURN r0 + r0 * 4 + r1 * 16 END
END StretchSextant;

(* Alphanumeric character, UK G0 set (SAA5050). *)
PROCEDURE PutText(x, y, c, fg, bg: INTEGER);
BEGIN
  IF    c = 023H THEN Put2(x, y, 0C2H, 0A3H, fg, bg)          (* £ *)
  ELSIF c = 05BH THEN Put3(x, y, 0E2H, 086H, 090H, fg, bg)    (* ← *)
  ELSIF c = 05CH THEN Put2(x, y, 0C2H, 0BDH, fg, bg)          (* ½ *)
  ELSIF c = 05DH THEN Put3(x, y, 0E2H, 086H, 092H, fg, bg)    (* → *)
  ELSIF c = 05EH THEN Put3(x, y, 0E2H, 086H, 091H, fg, bg)    (* ↑ *)
  ELSIF c = 05FH THEN Put1(x, y, ORD("#"), fg, bg)
  ELSIF c = 060H THEN Put3(x, y, 0E2H, 094H, 080H, fg, bg)    (* ─ *)
  ELSIF c = 07BH THEN Put2(x, y, 0C2H, 0BCH, fg, bg)          (* ¼ *)
  ELSIF c = 07CH THEN Put3(x, y, 0E2H, 080H, 096H, fg, bg)    (* ‖ *)
  ELSIF c = 07DH THEN Put2(x, y, 0C2H, 0BEH, fg, bg)          (* ¾ *)
  ELSIF c = 07EH THEN Put2(x, y, 0C3H, 0B7H, fg, bg)          (* ÷ *)
  ELSIF c = 07FH THEN Put3(x, y, 0E2H, 096H, 088H, fg, bg)    (* █ *)
  ELSE Put1(x, y, c, fg, bg)
  END
END PutText;

(* ── Teletext row decoder ────────────────────────────────────────────── *)

(* Render page row src onto screen row y.  part: 0 = normal row (the top
   half of any double-height characters), 1 = the bottom halves of row
   src drawn on the row below it.  Returns TRUE if src uses double height. *)
PROCEDURE RenderRow(y, src, part: INTEGER): BOOLEAN;
VAR x, c, fg, bg, held, s: INTEGER;
    gfx, flash, conceal, dbl, hold, hasDbl, hide: BOOLEAN;
BEGIN
  fg := 7;  bg := 0;  held := 32;
  gfx := FALSE;  flash := FALSE;  conceal := FALSE;
  dbl := FALSE;  hold := FALSE;  hasDbl := FALSE;
  FOR x := 0 TO W - 1 DO
    c := scr[src][x];

    (* "Set-at" attributes take effect on the control cell itself. *)
    IF c < 32 THEN
      IF    c = 09H THEN flash := FALSE
      ELSIF c = 0CH THEN
        IF dbl THEN held := 32 END;
        dbl := FALSE
      ELSIF c = 18H THEN conceal := TRUE
      ELSIF c = 1CH THEN bg := 0
      ELSIF c = 1DH THEN bg := fg
      ELSIF c = 1EH THEN hold := TRUE
      END
    END;

    hide := (flash & ~flashPhase) OR (conceal & ~reveal);

    IF (part = 1) & ~dbl THEN
      Put1(x, y, 32, pal[fg], pal[bg])
    ELSIF c < 32 THEN
      (* Control cells show as space, or the held mosaic in hold mode *)
      IF hold & gfx & (held # 32) & ~hide THEN
        s := SextantOf(held);
        IF dbl THEN s := StretchSextant(s, part = 1) END;
        PutSextant(x, y, s, pal[fg], pal[bg])
      ELSE
        Put1(x, y, 32, pal[fg], pal[bg])
      END
    ELSIF gfx & ((c DIV 32) MOD 2 = 1) THEN
      held := c;
      IF hide THEN Put1(x, y, 32, pal[fg], pal[bg])
      ELSE
        s := SextantOf(c);
        IF dbl THEN s := StretchSextant(s, part = 1) END;
        PutSextant(x, y, s, pal[fg], pal[bg])
      END
    ELSIF hide OR (part = 1) THEN
      Put1(x, y, 32, pal[fg], pal[bg])
    ELSE
      PutText(x, y, c, pal[fg], pal[bg])
    END;

    (* "Set-after" attributes take effect from the next cell. *)
    IF c < 32 THEN
      IF (c >= 01H) & (c <= 07H) THEN
        fg := c;  conceal := FALSE;
        IF gfx THEN held := 32 END;
        gfx := FALSE
      ELSIF (c >= 11H) & (c <= 17H) THEN
        fg := c - 10H;  conceal := FALSE;
        IF ~gfx THEN held := 32 END;
        gfx := TRUE
      ELSIF c = 08H THEN flash := TRUE
      ELSIF c = 0DH THEN
        IF ~dbl THEN held := 32 END;
        dbl := TRUE;  hasDbl := TRUE
      ELSIF c = 1FH THEN hold := FALSE
      END
      (* 19H/1AH contiguous/separated: separated mosaics are drawn
         contiguous, terminal fonts rarely have separated sextants *)
    END
  END;
  RETURN hasDbl
END RenderRow;

(* ── Screen ──────────────────────────────────────────────────────────── *)

PROCEDURE DrawStatus;
VAR x, y, n, fg, bg: INTEGER;
    line: ARRAY 64 OF CHAR;
BEGIN
  y := oy + H;
  fg := C7;  bg := C4;
  IF ~connected THEN bg := C1 END;
  FOR x := 0 TO W - 1 DO TUI.PutCell(ox + x, y, " ", fg, bg) END;
  TUI.PutStr(ox + 1, y, status, fg, bg);
  IF reveal THEN TUI.PutStr(ox + W - 7, y, "REVEAL", C3, bg) END;
  line := "Up/Dn page  ^R reveal  ^X quit";
  n := Strings.Length(line);
  IF oy + H + 1 <= TUI.Rows THEN
    FOR x := 0 TO W - 1 DO TUI.PutCell(ox + x, y + 1, " ", C6, C0) END;
    TUI.PutStr(ox + (W - n) DIV 2, y + 1, line, C6, C0)
  END
END DrawStatus;

PROCEDURE Redraw;
VAR r: INTEGER;
BEGIN
  ox := (TUI.Cols - W) DIV 2 + 1;
  IF ox < 1 THEN ox := 1 END;
  oy := (TUI.Rows - H - 2) DIV 2 + 1;
  IF oy < 1 THEN oy := 1 END;
  r := 0;
  WHILE r < H DO
    IF RenderRow(r, r, 0) & (r < H - 1) THEN
      IF RenderRow(r + 1, r, 1) THEN END;
      r := r + 2
    ELSE
      INC(r)
    END
  END;
  DrawStatus;
  TUI.Flush;
  dirty := FALSE
END Redraw;

PROCEDURE FullRedraw;
BEGIN
  TUI.ClearBack(C7, C0);
  Terminal.Clear;
  TUI.InvalidateFront;
  Redraw
END FullRedraw;

(* ── Connection ──────────────────────────────────────────────────────── *)

PROCEDURE SetStatus(s: ARRAY OF CHAR);
BEGIN
  COPY(s, status);
  dirty := TRUE
END SetStatus;

PROCEDURE Connect;
VAR msg: ARRAY 128 OF CHAR;
BEGIN
  ClearPage;
  escPending := FALSE;  iacSkip := 0;
  SetStatus("Connecting...");
  Redraw;
  fd := Net.Connect(host, port);
  connected := fd >= 0;
  IF connected THEN
    (* Telnet IAC DO SUPPRESS-GO-AHEAD, as telstar sends *)
    IF Net.WriteByte(fd, 255) = 1 THEN END;
    IF Net.WriteByte(fd, 253) = 1 THEN END;
    IF Net.WriteByte(fd, 3) = 1 THEN END;
    msg := "CEEFAX  ";
    Strings.Append(host, msg);
    SetStatus(msg)
  ELSE
    SetStatus("Connection failed - R retry, ^X quit")
  END
END Connect;

PROCEDURE Disconnect;
BEGIN
  IF connected THEN Net.Close(fd) END;
  connected := FALSE;  fd := -1;
  SetStatus("Disconnected - R reconnect, ^X quit")
END Disconnect;

PROCEDURE Send(b: INTEGER);
BEGIN
  IF connected THEN
    IF Net.WriteByte(fd, b) # 1 THEN Disconnect END
  END
END Send;

PROCEDURE SendPage(n: INTEGER);
BEGIN
  IF n > 899 THEN n := 100 ELSIF n < 100 THEN n := 899 END;
  Send(ORD("0") + n DIV 100);
  Send(ORD("0") + (n DIV 10) MOD 10);
  Send(ORD("0") + n MOD 10)
END SendPage;

(* ── Input ───────────────────────────────────────────────────────────── *)

PROCEDURE HandleKey(k: CHAR);
VAR n: INTEGER;
BEGIN
  n := ORD(k);
  IF (n = 18H) OR (n = 03H) OR (k = TUI.KEsc) THEN quit := TRUE
  ELSIF n = 12H THEN reveal := ~reveal;  dirty := TRUE
  ELSIF n = 0CH THEN FullRedraw
  ELSIF n = 04H THEN Disconnect
  ELSIF ~connected THEN
    IF (k = "r") OR (k = "R") THEN Connect
    ELSIF (k = "q") OR (k = "Q") THEN quit := TRUE
    END
  ELSIF (k = TUI.KUp) OR (k = TUI.KPgUp) OR (k = "+") THEN
    n := CurrentPage();
    IF n >= 0 THEN SendPage(n + 1) END
  ELSIF (k = TUI.KDown) OR (k = TUI.KPgDn) OR (k = "-") THEN
    n := CurrentPage();
    IF n >= 0 THEN SendPage(n - 1) END
  ELSIF (k = TUI.KEnter) OR (k = "#") THEN Send(5FH)   (* Viewdata '#' *)
  ELSIF k = TUI.KBackspace THEN Send(8)
  ELSIF (n >= 32) & (n <= 126) THEN Send(n)
  END
END HandleKey;

(* ── Main ────────────────────────────────────────────────────────────── *)

PROCEDURE ParseArgs;
VAR s: ARRAY 256 OF CHAR;
    i, n: INTEGER;
BEGIN
  host := DefHost;  port := DefPort;
  IF Args.Count() >= 1 THEN Args.Get(1, host) END;
  IF Args.Count() >= 2 THEN
    Args.Get(2, s);
    n := 0;  i := 0;
    WHILE (s[i] >= "0") & (s[i] <= "9") DO
      n := n * 10 + ORD(s[i]) - ORD("0");  INC(i)
    END;
    IF n > 0 THEN port := n END
  END
END ParseArgs;

PROCEDURE Run;
VAR ev: TUI.Event;
    b, count: INTEGER;
    now: LONGINT;
BEGIN
  Connect;
  lastFlash := Terminal.GetTickCount();
  WHILE ~quit DO
    (* Drain what the server has sent, redrawing at most every 512 bytes
       so a page arrives in a few visible strokes rather than byte by byte *)
    IF connected THEN
      count := 0;
      b := Net.ReadByte(fd);
      WHILE b >= 0 DO
        Recv(b);  dirty := TRUE;  INC(count);
        IF count >= 512 THEN b := -1 ELSE b := Net.ReadByte(fd) END
      END;
      IF b = -2 THEN Disconnect END
    END;

    WHILE TUI.PollEvent(ev) DO
      IF ev.kind = TUI.EvKey THEN HandleKey(ev.key)
      ELSIF ev.kind = TUI.EvResize THEN FullRedraw
      END
    END;

    now := Terminal.GetTickCount();
    IF now - lastFlash >= FlashMs THEN
      flashPhase := ~flashPhase;  lastFlash := now;  dirty := TRUE
    END;

    IF dirty & ~quit THEN Redraw END;
    IF connected THEN
      IF Net.Wait(fd, 50) = 0 THEN END
    ELSE
      IF Net.Wait(0, 50) = 0 THEN END
    END
  END;
  IF connected THEN Net.Close(fd) END
END Run;

BEGIN
  pal[0] := C0;  pal[1] := C1;  pal[2] := C2;  pal[3] := C3;
  pal[4] := C4;  pal[5] := C5;  pal[6] := C6;  pal[7] := C7;
  ParseArgs;
  reveal := FALSE;  flashPhase := TRUE;  quit := FALSE;
  connected := FALSE;  fd := -1;
  TUI.Init;
  TUI.ClearBack(C7, C0);
  Terminal.Clear;
  Run;
  TUI.Done
END Ceefax.
