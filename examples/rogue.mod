MODULE Rogue;
(*
 * Classic dungeon crawl.
 * Controls: hjkl / arrow keys = move/attack
 *           >  = descend stairs (when standing on them)
 *           q  = quit
 *
 * Layout (80x24 terminal):
 *   Row 1       : message line
 *   Rows 2..21  : map (80 wide x 20 tall)
 *   Row 22      : stats bar
 *)
IMPORT Terminal, Out, Random, Strings;

CONST
  MW = 80;  MH = 20;
  MAX_ROOMS = 10;
  MAX_MON   = 20;
  MAX_ITEM  = 30;

  WALL   = 0;
  FLOOR  = 1;
  STAIRS = 2;

  GOLD   = 0;
  POTION = 1;
  SWORD  = 2;
  ARMOR  = 3;

  FOV_R = 7;

  KUp = 0A0X;  KDown = 0A1X;  KLeft = 0A2X;  KRight = 0A3X;

TYPE
  Room = RECORD  x, y, w, h : INTEGER  END;

  Monster = RECORD
    x, y, hp, maxhp, atk, def, xpval : INTEGER;
    ch    : CHAR;
    alive : BOOLEAN;
    name  : ARRAY 16 OF CHAR;
  END;

  Item = RECORD
    x, y, kind, value : INTEGER;
    ch    : CHAR;
    there : BOOLEAN;
  END;

VAR
  map   : ARRAY MH, MW OF INTEGER;
  seen  : ARRAY MH, MW OF BOOLEAN;
  lit   : ARRAY MH, MW OF BOOLEAN;

  rooms : ARRAY MAX_ROOMS OF Room;
  nrooms: INTEGER;

  mons  : ARRAY MAX_MON OF Monster;
  nmons : INTEGER;

  items : ARRAY MAX_ITEM OF Item;
  nitems: INTEGER;

  px, py, php, pmaxhp, patk, pdef : INTEGER;
  pgold, pxp, pxpnext, plevel, depth : INTEGER;
  dead  : BOOLEAN;

  msg  : ARRAY 80 OF CHAR;
  stmp : ARRAY 16 OF CHAR;
  key  : CHAR;


(* ── Message helpers ───────────────────────────────────────────────── *)

PROCEDURE Msg(s : ARRAY OF CHAR);
BEGIN  COPY(s, msg)  END Msg;

PROCEDURE MsgA(s : ARRAY OF CHAR);
BEGIN  Strings.Append(s, msg)  END MsgA;

PROCEDURE MsgI(n : INTEGER);
BEGIN  Strings.IntToStr(n, stmp);  Strings.Append(stmp, msg)  END MsgI;

PROCEDURE MsgC(c : CHAR);
VAR i : INTEGER;
BEGIN
  i := 0;
  WHILE msg[i] # 0X DO  INC(i)  END;
  msg[i] := c;  msg[i+1] := 0X
END MsgC;


(* ── Line-of-sight ─────────────────────────────────────────────────── *)

PROCEDURE LoSBlocked(x0, y0, x1, y1 : INTEGER) : BOOLEAN;
VAR adx, ady, sx, sy, err, e2, cx, cy : INTEGER;
BEGIN
  cx := x0;  cy := y0;
  adx := ABS(x1 - x0);  ady := ABS(y1 - y0);
  IF x0 < x1 THEN sx :=  1 ELSE sx := -1 END;
  IF y0 < y1 THEN sy :=  1 ELSE sy := -1 END;
  err := adx - ady;
  LOOP
    IF (cx = x1) & (cy = y1) THEN  RETURN FALSE  END;
    e2 := 2 * err;
    IF e2 > -ady THEN  err := err - ady;  cx := cx + sx  END;
    IF e2 <  adx THEN  err := err + adx;  cy := cy + sy  END;
    IF (cx # x1) OR (cy # y1) THEN
      IF map[cy][cx] = WALL THEN  RETURN TRUE  END
    END
  END;
  RETURN FALSE
END LoSBlocked;


(* ── FOV ────────────────────────────────────────────────────────────── *)

PROCEDURE ComputeFOV;
VAR cx, cy, dx, dy : INTEGER;
BEGIN
  FOR cy := 0 TO MH-1 DO
    FOR cx := 0 TO MW-1 DO  lit[cy][cx] := FALSE  END
  END;
  FOR dy := -FOV_R TO FOV_R DO
    FOR dx := -FOV_R TO FOV_R DO
      cx := px + dx;  cy := py + dy;
      IF (cx >= 0) & (cx < MW) & (cy >= 0) & (cy < MH) THEN
        IF dx*dx + dy*dy <= FOV_R * FOV_R THEN
          IF ~LoSBlocked(px, py, cx, cy) THEN
            lit[cy][cx]  := TRUE;
            seen[cy][cx] := TRUE
          END
        END
      END
    END
  END
END ComputeFOV;


(* ── Dungeon generation ─────────────────────────────────────────────── *)

PROCEDURE CarveH(row, xa, xb : INTEGER);
VAR x, t : INTEGER;
BEGIN
  IF xa > xb THEN  t := xa;  xa := xb;  xb := t  END;
  FOR x := xa TO xb DO  map[row][x] := FLOOR  END
END CarveH;

PROCEDURE CarveV(col, ya, yb : INTEGER);
VAR y, t : INTEGER;
BEGIN
  IF ya > yb THEN  t := ya;  ya := yb;  yb := t  END;
  FOR y := ya TO yb DO  map[y][col] := FLOOR  END
END CarveV;

PROCEDURE GenDungeon;
VAR r, i, j, rw, rh, rx, ry, ok, cx1, cy1, cx2, cy2 : INTEGER;
BEGIN
  FOR i := 0 TO MH-1 DO
    FOR j := 0 TO MW-1 DO
      map[i][j] := WALL;  seen[i][j] := FALSE;  lit[i][j] := FALSE
    END
  END;
  nrooms := 0;

  FOR r := 0 TO 49 DO
    IF nrooms < MAX_ROOMS THEN
      rw := Random.Int(8) + 4;
      rh := Random.Int(4) + 3;
      rx := Random.Int(MW - rw - 2) + 1;
      ry := Random.Int(MH - rh - 2) + 1;
      ok := 1;
      FOR i := 0 TO nrooms - 1 DO
        IF (rx < rooms[i].x + rooms[i].w + 1) &
           (rx + rw + 1 > rooms[i].x) &
           (ry < rooms[i].y + rooms[i].h + 1) &
           (ry + rh + 1 > rooms[i].y) THEN
          ok := 0
        END
      END;
      IF ok = 1 THEN
        rooms[nrooms].x := rx;  rooms[nrooms].y := ry;
        rooms[nrooms].w := rw;  rooms[nrooms].h := rh;
        INC(nrooms);
        FOR i := ry TO ry + rh - 1 DO
          FOR j := rx TO rx + rw - 1 DO  map[i][j] := FLOOR  END
        END
      END
    END
  END;

  FOR r := 1 TO nrooms - 1 DO
    cx1 := rooms[r-1].x + rooms[r-1].w DIV 2;
    cy1 := rooms[r-1].y + rooms[r-1].h DIV 2;
    cx2 := rooms[r].x   + rooms[r].w   DIV 2;
    cy2 := rooms[r].y   + rooms[r].h   DIV 2;
    IF Random.Int(2) = 0 THEN
      CarveH(cy1, cx1, cx2);  CarveV(cx2, cy1, cy2)
    ELSE
      CarveV(cx1, cy1, cy2);  CarveH(cy2, cx1, cx2)
    END
  END;

  IF nrooms > 0 THEN
    r := nrooms - 1;
    map[rooms[r].y + rooms[r].h DIV 2][rooms[r].x + rooms[r].w DIV 2] := STAIRS
  END
END GenDungeon;


(* ── Spawn ──────────────────────────────────────────────────────────── *)

PROCEDURE SpawnMonsters;
VAR room, i, cnt, mx, my, tries, k : INTEGER;
BEGIN
  nmons := 0;
  FOR room := 1 TO nrooms - 1 DO
    cnt := Random.Int(2) + 1;
    IF depth > 3 THEN  INC(cnt)  END;
    FOR i := 1 TO cnt DO
      IF nmons < MAX_MON THEN
        tries := 0;
        REPEAT
          mx := rooms[room].x + Random.Int(rooms[room].w);
          my := rooms[room].y + Random.Int(rooms[room].h);
          INC(tries)
        UNTIL (map[my][mx] = FLOOR) OR (tries > 20);
        IF tries <= 20 THEN
          mons[nmons].x := mx;  mons[nmons].y := my;
          mons[nmons].alive := TRUE;
          k := Random.Int(10) + depth;
          IF k <= 3 THEN
            mons[nmons].ch := 'r';  COPY("rat", mons[nmons].name);
            mons[nmons].maxhp := 4 + Random.Int(3);
            mons[nmons].atk := 2;  mons[nmons].def := 0;  mons[nmons].xpval := 2
          ELSIF k <= 7 THEN
            mons[nmons].ch := 'g';  COPY("goblin", mons[nmons].name);
            mons[nmons].maxhp := 8 + Random.Int(5);
            mons[nmons].atk := 4;  mons[nmons].def := 1;  mons[nmons].xpval := 5
          ELSIF k <= 12 THEN
            mons[nmons].ch := 'o';  COPY("orc", mons[nmons].name);
            mons[nmons].maxhp := 14 + Random.Int(7);
            mons[nmons].atk := 6;  mons[nmons].def := 2;  mons[nmons].xpval := 10
          ELSE
            mons[nmons].ch := 'T';  COPY("troll", mons[nmons].name);
            mons[nmons].maxhp := 25 + Random.Int(10);
            mons[nmons].atk := 10;  mons[nmons].def := 3;  mons[nmons].xpval := 20
          END;
          mons[nmons].hp := mons[nmons].maxhp;
          INC(nmons)
        END
      END
    END
  END
END SpawnMonsters;

PROCEDURE SpawnItems;
VAR room, i, cnt, ix, iy, tries, k : INTEGER;
BEGIN
  nitems := 0;
  FOR room := 0 TO nrooms - 1 DO
    cnt := Random.Int(2) + 1;
    FOR i := 1 TO cnt DO
      IF nitems < MAX_ITEM THEN
        tries := 0;
        REPEAT
          ix := rooms[room].x + Random.Int(rooms[room].w);
          iy := rooms[room].y + Random.Int(rooms[room].h);
          INC(tries)
        UNTIL (map[iy][ix] = FLOOR) OR (tries > 20);
        IF tries <= 20 THEN
          items[nitems].x := ix;  items[nitems].y := iy;
          items[nitems].there := TRUE;
          k := Random.Int(10);
          IF k < 5 THEN
            items[nitems].kind := GOLD;
            items[nitems].value := Random.Int(20) + 5 + depth * 3;
            items[nitems].ch := '$'
          ELSIF k < 8 THEN
            items[nitems].kind := POTION;
            items[nitems].value := 8 + depth * 2;
            items[nitems].ch := '!'
          ELSIF k < 9 THEN
            items[nitems].kind := SWORD;
            items[nitems].value := 1 + depth DIV 3;
            items[nitems].ch := ')'
          ELSE
            items[nitems].kind := ARMOR;
            items[nitems].value := 1 + depth DIV 3;
            items[nitems].ch := ']'
          END;
          INC(nitems)
        END
      END
    END
  END
END SpawnItems;


(* ── Combat ─────────────────────────────────────────────────────────── *)

PROCEDURE LevelUp;
BEGIN
  INC(plevel);
  pxp := pxp - pxpnext;
  pxpnext := pxpnext + 10 * plevel;
  pmaxhp  := pmaxhp + 5;
  php     := php + 5;
  INC(patk);  INC(pdef);
  MsgA("  ** LEVEL UP! **")
END LevelUp;

PROCEDURE Attack(mi : INTEGER);
VAR dmg : INTEGER;
BEGIN
  dmg := patk + Random.Int(4) - mons[mi].def;
  IF dmg < 1 THEN dmg := 1 END;
  mons[mi].hp := mons[mi].hp - dmg;
  Msg("You hit the ");  MsgA(mons[mi].name);
  MsgA(" for ");  MsgI(dmg);  MsgA(" dmg");
  IF mons[mi].hp <= 0 THEN
    mons[mi].alive := FALSE;
    MsgA("  Killed!");
    pxp := pxp + mons[mi].xpval;
    IF pxp >= pxpnext THEN  LevelUp  END
  END
END Attack;

PROCEDURE MonsterAttack(mi : INTEGER);
VAR dmg : INTEGER;
BEGIN
  dmg := mons[mi].atk + Random.Int(3) - pdef;
  IF dmg < 1 THEN dmg := 1 END;
  php := php - dmg;
  Msg("The ");  MsgA(mons[mi].name);
  MsgA(" hits you for ");  MsgI(dmg);  MsgC('.');
  IF php <= 0 THEN  php := 0;  dead := TRUE  END
END MonsterAttack;


(* ── Monster AI ──────────────────────────────────────────────────────── *)

PROCEDURE MonsterTurn;
VAR i, j, ndx, ndy, nx, ny, ok : INTEGER;
BEGIN
  FOR i := 0 TO nmons - 1 DO
    IF mons[i].alive & lit[mons[i].y][mons[i].x] THEN
      (* Direction toward player *)
      ndx := 0;  ndy := 0;
      IF px > mons[i].x THEN ndx :=  1 ELSIF px < mons[i].x THEN ndx := -1 END;
      IF py > mons[i].y THEN ndy :=  1 ELSIF py < mons[i].y THEN ndy := -1 END;

      (* Adjacent? Attack. *)
      IF (ABS(px - mons[i].x) + ABS(py - mons[i].y)) = 1 THEN
        MonsterAttack(i)
      ELSE
        (* Try to close distance (cardinal movement) *)
        IF ABS(px - mons[i].x) >= ABS(py - mons[i].y) THEN
          nx := mons[i].x + ndx;  ny := mons[i].y;
          IF map[ny][nx] = WALL THEN
            nx := mons[i].x;  ny := mons[i].y + ndy
          END
        ELSE
          nx := mons[i].x;  ny := mons[i].y + ndy;
          IF map[ny][nx] = WALL THEN
            nx := mons[i].x + ndx;  ny := mons[i].y
          END
        END;
        IF map[ny][nx] # WALL THEN
          IF (nx = px) & (ny = py) THEN
            MonsterAttack(i)
          ELSE
            ok := 1;
            FOR j := 0 TO nmons - 1 DO
              IF (j # i) & mons[j].alive
                 & (mons[j].x = nx) & (mons[j].y = ny) THEN
                ok := 0
              END
            END;
            IF ok = 1 THEN
              mons[i].x := nx;  mons[i].y := ny
            END
          END
        END
      END
    END
  END
END MonsterTurn;


(* ── Pick up items ───────────────────────────────────────────────────── *)

PROCEDURE CheckPickup;
VAR i : INTEGER;
BEGIN
  FOR i := 0 TO nitems - 1 DO
    IF items[i].there & (items[i].x = px) & (items[i].y = py) THEN
      items[i].there := FALSE;
      IF items[i].kind = GOLD THEN
        pgold := pgold + items[i].value;
        Msg("Picked up ");  MsgI(items[i].value);  MsgA(" gold.")
      ELSIF items[i].kind = POTION THEN
        php := php + items[i].value;
        IF php > pmaxhp THEN  php := pmaxhp  END;
        Msg("Drank a potion.  HP restored.")
      ELSIF items[i].kind = SWORD THEN
        patk := patk + items[i].value;
        Msg("Found a sword!  ATK +");  MsgI(items[i].value);  MsgC('.')
      ELSE
        pdef := pdef + items[i].value;
        Msg("Found armor!  DEF +");  MsgI(items[i].value);  MsgC('.')
      END
    END
  END
END CheckPickup;


(* ── Player move ─────────────────────────────────────────────────────── *)

PROCEDURE TryMove(dx, dy : INTEGER);
VAR nx, ny, i, found : INTEGER;
BEGIN
  nx := px + dx;  ny := py + dy;
  IF (nx < 0) OR (nx >= MW) OR (ny < 0) OR (ny >= MH) THEN  RETURN  END;
  IF map[ny][nx] = WALL THEN  RETURN  END;

  found := -1;
  FOR i := 0 TO nmons - 1 DO
    IF mons[i].alive & (mons[i].x = nx) & (mons[i].y = ny) THEN  found := i  END
  END;

  IF found >= 0 THEN
    Attack(found)
  ELSE
    px := nx;  py := ny;
    CheckPickup;
    IF map[py][px] = STAIRS THEN
      Msg("Stairs!  Press > to descend.")
    END
  END
END TryMove;


(* ── Rendering ───────────────────────────────────────────────────────── *)

PROCEDURE DrawMap;
VAR x, y, i : INTEGER;
BEGIN
  FOR y := 0 TO MH-1 DO
    FOR x := 0 TO MW-1 DO
      Terminal.Goto(x + 1, y + 2);
      IF lit[y][x] THEN
        IF map[y][x] = WALL THEN
          Terminal.Color256(243, 0);  Out.Char('#')
        ELSIF map[y][x] = STAIRS THEN
          Terminal.Color256(46, 0);   Out.Char('>')
        ELSE
          Terminal.Color256(238, 0);  Out.Char('.')
        END
      ELSIF seen[y][x] THEN
        IF map[y][x] = WALL THEN
          Terminal.Color256(235, 0);  Out.Char('#')
        ELSIF map[y][x] = STAIRS THEN
          Terminal.Color256(22, 0);   Out.Char('>')
        ELSE
          Terminal.Color256(233, 0);  Out.Char('.')
        END
      ELSE
        Terminal.Color(0, 0);  Out.Char(' ')
      END
    END
  END;

  FOR i := 0 TO nitems - 1 DO
    IF items[i].there & lit[items[i].y][items[i].x] THEN
      Terminal.Goto(items[i].x + 1, items[i].y + 2);
      IF    items[i].kind = GOLD   THEN  Terminal.Color256(226, 0)
      ELSIF items[i].kind = POTION THEN  Terminal.Color256(51,  0)
      ELSIF items[i].kind = SWORD  THEN  Terminal.Color256(15,  0)
      ELSE                               Terminal.Color256(214, 0)
      END;
      Out.Char(items[i].ch)
    END
  END;

  FOR i := 0 TO nmons - 1 DO
    IF mons[i].alive & lit[mons[i].y][mons[i].x] THEN
      Terminal.Goto(mons[i].x + 1, mons[i].y + 2);
      IF    mons[i].ch = 'r' THEN  Terminal.Color256(160, 0)
      ELSIF mons[i].ch = 'g' THEN  Terminal.Color256(214, 0)
      ELSIF mons[i].ch = 'o' THEN  Terminal.Color256(208, 0)
      ELSE                         Terminal.Color256(196, 0)
      END;
      Out.Char(mons[i].ch)
    END
  END;

  Terminal.Goto(px + 1, py + 2);
  Terminal.Color256(15, 0);
  Out.Char('@');
  Terminal.Reset
END DrawMap;

PROCEDURE DrawStats;
BEGIN
  Terminal.Goto(1, 22);
  Terminal.Color256(196, 0);
  Out.String(" HP:");  Out.Int(php, 0);  Out.Char('/');  Out.Int(pmaxhp, 0);
  Terminal.Color256(15, 0);
  Out.String("  ATK:");  Out.Int(patk, 0);
  Out.String("  DEF:");  Out.Int(pdef, 0);
  Terminal.Color256(226, 0);
  Out.String("  Gold:");  Out.Int(pgold, 0);
  Terminal.Color256(46, 0);
  Out.String("  Depth:");  Out.Int(depth, 0);
  Terminal.Color256(51, 0);
  Out.String("  Lv:");  Out.Int(plevel, 0);
  Out.String("  XP:");  Out.Int(pxp, 0);  Out.Char('/');  Out.Int(pxpnext, 0);
  Terminal.Color256(240, 0);
  Out.String("  hjkl/>  ");
  Terminal.Reset
END DrawStats;

PROCEDURE DrawMsg;
VAR i, len : INTEGER;
BEGIN
  Terminal.Goto(1, 1);
  Terminal.Color256(255, 0);
  Out.String(msg);
  len := Strings.Length(msg);
  FOR i := len TO 79 DO  Out.Char(' ')  END;
  Terminal.Reset
END DrawMsg;

PROCEDURE Render;
BEGIN
  DrawMap;
  DrawStats;
  DrawMsg;
  Out.Flush
END Render;


(* ── Level setup ─────────────────────────────────────────────────────── *)

PROCEDURE GenLevel;
BEGIN
  GenDungeon;
  px := rooms[0].x + rooms[0].w DIV 2;
  py := rooms[0].y + rooms[0].h DIV 2;
  SpawnMonsters;
  SpawnItems;
  ComputeFOV
END GenLevel;


(* ── Main ────────────────────────────────────────────────────────────── *)

BEGIN
  Terminal.Clear;
  php := 20;  pmaxhp := 20;
  patk := 4;  pdef := 1;
  pgold := 0;  pxp := 0;  pxpnext := 20;
  plevel := 1;  depth := 1;
  dead := FALSE;

  GenLevel;
  Msg("Welcome!  Find the stairs (>) to descend.  hjkl or arrows to move.");

  LOOP
    Render;
    key := Terminal.ReadKey();

    IF    (key = KLeft)  OR (key = 'h') THEN  TryMove(-1,  0)
    ELSIF (key = KRight) OR (key = 'l') THEN  TryMove( 1,  0)
    ELSIF (key = KUp)    OR (key = 'k') THEN  TryMove( 0, -1)
    ELSIF (key = KDown)  OR (key = 'j') THEN  TryMove( 0,  1)
    ELSIF key = '>' THEN
      IF map[py][px] = STAIRS THEN
        INC(depth);
        GenLevel;
        Msg("Depth ");  MsgI(depth);  MsgA(".  Find the stairs.")
      ELSE
        Msg("No stairs here.")
      END
    ELSIF (key = 'q') OR (key = 1BX) THEN
      EXIT
    ELSE
      Msg("")
    END;

    IF ~dead THEN
      MonsterTurn;
      ComputeFOV
    END;

    IF dead THEN
      Render;
      Terminal.Goto(25, 10);
      Terminal.Color256(196, 0);
      Out.String("  +-----------------+  ");
      Terminal.Goto(25, 11);
      Out.String("  |   YOU  DIED !   |  ");
      Terminal.Goto(25, 12);
      Out.String("  +-----------------+  ");
      Terminal.Goto(25, 13);
      Terminal.Color256(226, 0);
      Out.String("  Gold:");  Out.Int(pgold, 5);
      Out.String("  Depth:");  Out.Int(depth, 3);
      Out.String("  Lvl:");  Out.Int(plevel, 2);
      Terminal.Goto(25, 15);
      Terminal.Color256(240, 0);
      Out.String("  Press any key.  ");
      Terminal.Reset;
      key := Terminal.ReadKey();
      EXIT
    END
  END;

  Terminal.Clear;
  Terminal.Goto(1, 1)
END Rogue.

