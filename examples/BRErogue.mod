MODULE BRErogue;
(*
 * Barbarians of the Ruined Earth dungeon crawl.
 * Post-apocalyptic roguelike based on the BRE RPG rules.
 * Controls: hjkl / arrow keys = move/attack (melee bump)
 *           f + hjkl/arrows  = fire blaster (ranged, uses ammo)
 *           >  = descend elevator (when standing on it)
 *           q  = quit
 *
 * Layout (80x24 terminal):
 *   Row 1       : message line
 *   Rows 2..21  : map (80 wide x 20 tall)
 *   Row 22      : stats bar
 *
 * BRE Classes (player is a Barbarian):
 *   Starting HP: 1d10+4 -> 15
 *   Melee ATK: 5 (1d8 weapon)
 *   Armor: DEF 2 (medium)
 *
 * BRE Monsters (HD-based; tier gated by player level):
 *   Tier 1 (any): cultist 'c', raider 'r', antmen worker 'a', skeleton 's'
 *   Tier 2 (any): giant beetle 'B', giant lizard 'l', flaming raider 'R', killer clown 'K'
 *   Tier 3 (lv3+): demon dog 'd', cult leader 'L', robot 'b', fungal killer 'F'
 *   Tier 4 (lv5+): ape-oid 'A', lightning man 'Z', car golem 'G', sky octopus 'O'
 *
 * BRE Items:
 *   Ceramic Coins '$'  (currency of the Ruined Earth Sorcerers)
 *   Stim-Pack    '!'  (restore HP)
 *   Blaster      ')'  (Ancient Earth firearm - adds ammo charges)
 *   Vibro-Blade  '('  (melee ATK+)
 *   Scrap Armor  ']'  (DEF+, salvaged protection)
 *)
IMPORT Terminal, Graphics, Out, Random, Strings;

CONST
  MW = 80;  MH = 20;
  MAX_ROOMS = 10;
  MAX_MON   = 20;
  MAX_ITEM  = 30;

  WALL   = 0;
  FLOOR  = 1;
  STAIRS = 2;

  COINS    = 0;
  STIMPACK = 1;
  BLASTER  = 2;
  VIBROBLADE = 3;
  SCRAP    = 4;

  FOV_R = 7;

  KUp = 01X;  KDown = 02X;  KLeft = 03X;  KRight = 04X;

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
  pammo  : INTEGER;   (* blaster ammo charges *)
  pfiring : BOOLEAN;  (* waiting for direction after 'f' *)
  dead  : BOOLEAN;
  healTimer : INTEGER;  (* counts turns; heal 1 HP every 15 turns *)

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
(* Four tiers gated by player level (plevel):
 *
 * Tier 1 (1 HD, any level):
 *   'c' cultist       6+ HP  atk=3 def=0 xp=3
 *   'r' raider        5+ HP  atk=3 def=0 xp=3
 *   'a' antmen worker 5+ HP  atk=2 def=0 xp=2
 *   's' skeleton      5+ HP  atk=2 def=0 xp=2
 *
 * Tier 2 (2 HD, any level):
 *   'B' giant beetle  12+ HP atk=5 def=1 xp=7
 *   'l' giant lizard  10+ HP atk=4 def=0 xp=6
 *   'R' flaming raider 11+ HP atk=5 def=1 xp=8
 *   'K' killer clown  12+ HP atk=5 def=2 xp=8
 *
 * Tier 3 (3 HD, plevel >= 3 only):
 *   'd' demon dog     20+ HP atk=8 def=1 xp=15
 *   'L' cult leader   18+ HP atk=7 def=1 xp=12
 *   'b' robot         20+ HP atk=8 def=1 xp=14
 *   'F' fungal killer 19+ HP atk=7 def=1 xp=13
 *
 * Tier 4 (4 HD, plevel >= 5 only):
 *   'A' ape-oid       28+ HP atk=12 def=2 xp=25
 *   'Z' lightning man 28+ HP atk=12 def=0 xp=25
 *   'G' car golem     30+ HP atk=14 def=2 xp=30
 *   'O' sky octopus   28+ HP atk=12 def=2 xp=28
 *)
VAR room, i, j, cnt, mx, my, tries, k : INTEGER;
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

          (* k drives tier selection; cap by player level *)
          k := Random.Int(10) + depth;
          IF plevel < 3 THEN
            IF k > 8 THEN  k := 8  END    (* max tier 2 *)
          ELSIF plevel < 5 THEN
            IF k > 12 THEN  k := 12  END  (* max tier 3 *)
          END;

          j := Random.Int(4);  (* pick one of 4 in the tier *)

          IF k <= 4 THEN
            (* Tier 1 *)
            IF j = 0 THEN
              mons[nmons].ch := 'c';  COPY("cultist", mons[nmons].name);
              mons[nmons].maxhp := 6 + Random.Int(3);
              mons[nmons].atk := 3;  mons[nmons].def := 0;  mons[nmons].xpval := 3
            ELSIF j = 1 THEN
              mons[nmons].ch := 'r';  COPY("raider", mons[nmons].name);
              mons[nmons].maxhp := 5 + Random.Int(4);
              mons[nmons].atk := 3;  mons[nmons].def := 0;  mons[nmons].xpval := 3
            ELSIF j = 2 THEN
              mons[nmons].ch := 'a';  COPY("antmen worker", mons[nmons].name);
              mons[nmons].maxhp := 5 + Random.Int(3);
              mons[nmons].atk := 2;  mons[nmons].def := 0;  mons[nmons].xpval := 2
            ELSE
              mons[nmons].ch := 's';  COPY("skeleton", mons[nmons].name);
              mons[nmons].maxhp := 5 + Random.Int(3);
              mons[nmons].atk := 2;  mons[nmons].def := 0;  mons[nmons].xpval := 2
            END

          ELSIF k <= 8 THEN
            (* Tier 2 *)
            IF j = 0 THEN
              mons[nmons].ch := 'B';  COPY("giant beetle", mons[nmons].name);
              mons[nmons].maxhp := 12 + Random.Int(5);
              mons[nmons].atk := 5;  mons[nmons].def := 1;  mons[nmons].xpval := 7
            ELSIF j = 1 THEN
              mons[nmons].ch := 'l';  COPY("giant lizard", mons[nmons].name);
              mons[nmons].maxhp := 10 + Random.Int(5);
              mons[nmons].atk := 4;  mons[nmons].def := 0;  mons[nmons].xpval := 6
            ELSIF j = 2 THEN
              mons[nmons].ch := 'R';  COPY("flaming raider", mons[nmons].name);
              mons[nmons].maxhp := 11 + Random.Int(5);
              mons[nmons].atk := 5;  mons[nmons].def := 1;  mons[nmons].xpval := 8
            ELSE
              mons[nmons].ch := 'K';  COPY("killer clown", mons[nmons].name);
              mons[nmons].maxhp := 12 + Random.Int(5);
              mons[nmons].atk := 5;  mons[nmons].def := 2;  mons[nmons].xpval := 8
            END

          ELSIF k <= 12 THEN
            (* Tier 3: plevel >= 3 guaranteed by cap above *)
            IF j = 0 THEN
              mons[nmons].ch := 'd';  COPY("demon dog", mons[nmons].name);
              mons[nmons].maxhp := 20 + Random.Int(8);
              mons[nmons].atk := 8;  mons[nmons].def := 1;  mons[nmons].xpval := 15
            ELSIF j = 1 THEN
              mons[nmons].ch := 'L';  COPY("cult leader", mons[nmons].name);
              mons[nmons].maxhp := 18 + Random.Int(7);
              mons[nmons].atk := 7;  mons[nmons].def := 1;  mons[nmons].xpval := 12
            ELSIF j = 2 THEN
              mons[nmons].ch := 'b';  COPY("robot", mons[nmons].name);
              mons[nmons].maxhp := 20 + Random.Int(6);
              mons[nmons].atk := 8;  mons[nmons].def := 1;  mons[nmons].xpval := 14
            ELSE
              mons[nmons].ch := 'F';  COPY("fungal killer", mons[nmons].name);
              mons[nmons].maxhp := 19 + Random.Int(7);
              mons[nmons].atk := 7;  mons[nmons].def := 1;  mons[nmons].xpval := 13
            END

          ELSE
            (* Tier 4: plevel >= 5 guaranteed by cap above *)
            IF j = 0 THEN
              mons[nmons].ch := 'A';  COPY("ape-oid", mons[nmons].name);
              mons[nmons].maxhp := 28 + Random.Int(10);
              mons[nmons].atk := 12;  mons[nmons].def := 2;  mons[nmons].xpval := 25
            ELSIF j = 1 THEN
              mons[nmons].ch := 'Z';  COPY("lightning man", mons[nmons].name);
              mons[nmons].maxhp := 28 + Random.Int(10);
              mons[nmons].atk := 12;  mons[nmons].def := 0;  mons[nmons].xpval := 25
            ELSIF j = 2 THEN
              mons[nmons].ch := 'G';  COPY("car golem", mons[nmons].name);
              mons[nmons].maxhp := 30 + Random.Int(10);
              mons[nmons].atk := 14;  mons[nmons].def := 2;  mons[nmons].xpval := 30
            ELSE
              mons[nmons].ch := 'O';  COPY("sky octopus", mons[nmons].name);
              mons[nmons].maxhp := 28 + Random.Int(10);
              mons[nmons].atk := 12;  mons[nmons].def := 2;  mons[nmons].xpval := 28
            END
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
          k := Random.Int(12);
          IF k < 4 THEN
            items[nitems].kind := COINS;
            items[nitems].value := Random.Int(20) + 5 + depth * 3;
            items[nitems].ch := '$'
          ELSIF k < 7 THEN
            items[nitems].kind := STIMPACK;
            items[nitems].value := 8 + depth * 2;
            items[nitems].ch := '!'
          ELSIF k < 9 THEN
            items[nitems].kind := BLASTER;
            items[nitems].value := 4 + depth;   (* ammo charges *)
            items[nitems].ch := ')'
          ELSIF k < 11 THEN
            items[nitems].kind := VIBROBLADE;
            items[nitems].value := 1 + depth DIV 3;
            items[nitems].ch := '('
          ELSE
            items[nitems].kind := SCRAP;
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
  pmaxhp  := pmaxhp + 6;   (* Barbarian: 1d10 per level, ~6 avg *)
  php     := php + 6;
  INC(patk);  INC(pdef);
  MsgA("  ** LEVEL UP! **")
END LevelUp;

PROCEDURE KillMonster(mi : INTEGER);
BEGIN
  mons[mi].alive := FALSE;
  MsgA("  Slain!");
  pxp := pxp + mons[mi].xpval;
  IF pxp >= pxpnext THEN  LevelUp  END
END KillMonster;

PROCEDURE Attack(mi : INTEGER);
VAR dmg : INTEGER;
BEGIN
  dmg := patk + Random.Int(4) - mons[mi].def;
  IF dmg < 1 THEN dmg := 1 END;
  mons[mi].hp := mons[mi].hp - dmg;
  Msg("You hit the ");  MsgA(mons[mi].name);
  MsgA(" for ");  MsgI(dmg);  MsgA(" dmg");
  IF mons[mi].hp <= 0 THEN  KillMonster(mi)  END
END Attack;

PROCEDURE RangedAttack(dx, dy : INTEGER);
(* Fire blaster in direction (dx,dy).  Shot travels until it hits a
   monster or a wall.  Costs 1 ammo.  Damage: 1d6+depth (blasters
   are powerful Ancient Earth tech but ignore ATK/DEF: pure firearm). *)
VAR cx, cy, i, found, dmg : INTEGER;
BEGIN
  DEC(pammo);
  cx := px + dx;  cy := py + dy;
  found := -1;
  WHILE (cx >= 0) & (cx < MW) & (cy >= 0) & (cy < MH)
      & (map[cy][cx] # WALL) & (found < 0) DO
    FOR i := 0 TO nmons - 1 DO
      IF mons[i].alive & (mons[i].x = cx) & (mons[i].y = cy) THEN
        found := i
      END
    END;
    IF found < 0 THEN
      cx := cx + dx;  cy := cy + dy
    END
  END;
  IF found >= 0 THEN
    dmg := Random.Int(6) + 1 + depth;
    mons[found].hp := mons[found].hp - dmg;
    Msg("You blast the ");  MsgA(mons[found].name);
    MsgA(" for ");  MsgI(dmg);  MsgA(" dmg");
    IF mons[found].hp <= 0 THEN  KillMonster(found)  END
  ELSE
    Msg("Shot fizzles into the dark.")
  END
END RangedAttack;

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
      ndx := 0;  ndy := 0;
      IF px > mons[i].x THEN ndx :=  1 ELSIF px < mons[i].x THEN ndx := -1 END;
      IF py > mons[i].y THEN ndy :=  1 ELSIF py < mons[i].y THEN ndy := -1 END;

      IF (ABS(px - mons[i].x) + ABS(py - mons[i].y)) = 1 THEN
        MonsterAttack(i)
      ELSE
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
  END;
  (* Natural regeneration: +1 HP every 15 turns *)
  INC(healTimer);
  IF healTimer >= 15 THEN
    healTimer := 0;
    IF php < pmaxhp THEN
      INC(php)
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
      IF items[i].kind = COINS THEN
        pgold := pgold + items[i].value;
        Msg("Found ");  MsgI(items[i].value);  MsgA(" ceramic coins.")
      ELSIF items[i].kind = STIMPACK THEN
        php := php + items[i].value;
        IF php > pmaxhp THEN  php := pmaxhp  END;
        Msg("Used a Stim-Pack.  HP restored.")
      ELSIF items[i].kind = BLASTER THEN
        pammo := pammo + items[i].value;
        Msg("Found a Blaster!  Ammo +");  MsgI(items[i].value);  MsgC('.')
      ELSIF items[i].kind = VIBROBLADE THEN
        patk := patk + items[i].value;
        Msg("Found a Vibro-Blade!  ATK +");  MsgI(items[i].value);  MsgC('.')
      ELSE
        pdef := pdef + items[i].value;
        Msg("Found Scrap Armor!  DEF +");  MsgI(items[i].value);  MsgC('.')
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
      Msg("Elevator!  Press > to descend.")
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
          Graphics.Color256(243, 0);  Out.Char('#')
        ELSIF map[y][x] = STAIRS THEN
          Graphics.Color256(46, 0);   Out.Char('>')
        ELSE
          Graphics.Color256(238, 0);  Out.Char('.')
        END
      ELSIF seen[y][x] THEN
        IF map[y][x] = WALL THEN
          Graphics.Color256(235, 0);  Out.Char('#')
        ELSIF map[y][x] = STAIRS THEN
          Graphics.Color256(22, 0);   Out.Char('>')
        ELSE
          Graphics.Color256(233, 0);  Out.Char('.')
        END
      ELSE
        Graphics.Color(0, 0);  Out.Char(' ')
      END
    END
  END;

  FOR i := 0 TO nitems - 1 DO
    IF items[i].there & lit[items[i].y][items[i].x] THEN
      Terminal.Goto(items[i].x + 1, items[i].y + 2);
      IF    items[i].kind = COINS     THEN  Graphics.Color256(226, 0)
      ELSIF items[i].kind = STIMPACK  THEN  Graphics.Color256(51,  0)
      ELSIF items[i].kind = BLASTER   THEN  Graphics.Color256(214, 0)
      ELSIF items[i].kind = VIBROBLADE THEN Graphics.Color256(15,  0)
      ELSE                                  Graphics.Color256(240, 0)
      END;
      Out.Char(items[i].ch)
    END
  END;

  FOR i := 0 TO nmons - 1 DO
    IF mons[i].alive & lit[mons[i].y][mons[i].x] THEN
      Terminal.Goto(mons[i].x + 1, mons[i].y + 2);
      (* Tier 1: dim colours *)
      IF    mons[i].ch = 'c' THEN  Graphics.Color256(160, 0)   (* cultist: red *)
      ELSIF mons[i].ch = 'r' THEN  Graphics.Color256(166, 0)   (* raider: orange-red *)
      ELSIF mons[i].ch = 'a' THEN  Graphics.Color256(100, 0)   (* antmen worker: olive *)
      ELSIF mons[i].ch = 's' THEN  Graphics.Color256(250, 0)   (* skeleton: grey *)
      (* Tier 2: mid colours *)
      ELSIF mons[i].ch = 'B' THEN  Graphics.Color256(130, 0)   (* giant beetle: brown *)
      ELSIF mons[i].ch = 'l' THEN  Graphics.Color256(64,  0)   (* giant lizard: green *)
      ELSIF mons[i].ch = 'R' THEN  Graphics.Color256(202, 0)   (* flaming raider: bright orange *)
      ELSIF mons[i].ch = 'K' THEN  Graphics.Color256(201, 0)   (* killer clown: magenta *)
      (* Tier 3: bright danger colours *)
      ELSIF mons[i].ch = 'd' THEN  Graphics.Color256(208, 0)   (* demon dog: orange *)
      ELSIF mons[i].ch = 'L' THEN  Graphics.Color256(196, 0)   (* cult leader: bright red *)
      ELSIF mons[i].ch = 'b' THEN  Graphics.Color256(51,  0)   (* robot: cyan *)
      ELSIF mons[i].ch = 'F' THEN  Graphics.Color256(34,  0)   (* fungal killer: dark green *)
      (* Tier 4: boss colours *)
      ELSIF mons[i].ch = 'A' THEN  Graphics.Color256(226, 0)   (* ape-oid: bright yellow *)
      ELSIF mons[i].ch = 'Z' THEN  Graphics.Color256(227, 0)   (* lightning man: electric yellow *)
      ELSIF mons[i].ch = 'G' THEN  Graphics.Color256(68,  0)   (* car golem: steel blue *)
      ELSIF mons[i].ch = 'O' THEN  Graphics.Color256(135, 0)   (* sky octopus: purple *)
      ELSE                         Graphics.Color256(196, 0)
      END;
      Out.Char(mons[i].ch)
    END
  END;

  Terminal.Goto(px + 1, py + 2);
  Graphics.Color256(15, 0);
  Out.Char('@');
  Graphics.Reset
END DrawMap;

PROCEDURE DrawStats;
BEGIN
  Terminal.Goto(1, 22);
  Graphics.Color256(196, 0);
  Out.String(" HP:");  Out.Int(php, 0);  Out.Char('/');  Out.Int(pmaxhp, 0);
  Graphics.Color256(15, 0);
  Out.String("  ATK:");  Out.Int(patk, 0);
  Out.String("  DEF:");  Out.Int(pdef, 0);
  Graphics.Color256(214, 0);
  Out.String("  Ammo:");  Out.Int(pammo, 0);
  Graphics.Color256(226, 0);
  Out.String("  Coins:");  Out.Int(pgold, 0);
  Graphics.Color256(46, 0);
  Out.String("  Lv:");  Out.Int(depth, 0);
  Graphics.Color256(51, 0);
  Out.String("  XP:");  Out.Int(pxp, 0);  Out.Char('/');  Out.Int(pxpnext, 0);
  Graphics.Color256(240, 0);
  Out.String("  f+dir=fire ");
  Graphics.Reset
END DrawStats;

PROCEDURE DrawMsg;
VAR i, len : INTEGER;
BEGIN
  Terminal.Goto(1, 1);
  Graphics.Color256(255, 0);
  Out.String(msg);
  len := Strings.Length(msg);
  FOR i := len TO 79 DO  Out.Char(' ')  END;
  Graphics.Reset
END DrawMsg;

PROCEDURE Render;
BEGIN
  DrawMap;
  DrawStats;
  DrawMsg
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
  php := 15;  pmaxhp := 15;
  patk := 5;  pdef := 2;
  pgold := 0;  pxp := 0;  pxpnext := 20;
  plevel := 1;  depth := 1;
  pammo := 0;  pfiring := FALSE;
  dead := FALSE;  healTimer := 0;

  GenLevel;
  Msg("Ruined Earth!  Find the elevator (>).  hjkl=move  f+dir=fire blaster");

  LOOP
    Render;
    key := Terminal.ReadKey();

    IF pfiring THEN
      (* Second keypress after 'f': resolve the shot direction *)
      pfiring := FALSE;
      IF    (key = KLeft)  OR (key = 'h') THEN  RangedAttack(-1,  0)
      ELSIF (key = KRight) OR (key = 'l') THEN  RangedAttack( 1,  0)
      ELSIF (key = KUp)    OR (key = 'k') THEN  RangedAttack( 0, -1)
      ELSIF (key = KDown)  OR (key = 'j') THEN  RangedAttack( 0,  1)
      ELSE  Msg("Cancelled.")
      END;
      IF ~dead THEN  MonsterTurn;  ComputeFOV  END
    ELSIF (key = KLeft)  OR (key = 'h') THEN
      TryMove(-1,  0);
      IF ~dead THEN  MonsterTurn;  ComputeFOV  END
    ELSIF (key = KRight) OR (key = 'l') THEN
      TryMove( 1,  0);
      IF ~dead THEN  MonsterTurn;  ComputeFOV  END
    ELSIF (key = KUp)    OR (key = 'k') THEN
      TryMove( 0, -1);
      IF ~dead THEN  MonsterTurn;  ComputeFOV  END
    ELSIF (key = KDown)  OR (key = 'j') THEN
      TryMove( 0,  1);
      IF ~dead THEN  MonsterTurn;  ComputeFOV  END
    ELSIF key = 'f' THEN
      (* First keypress: arm the blaster, wait for direction *)
      IF pammo > 0 THEN
        pfiring := TRUE;
        Msg("Fire which direction? (hjkl / arrows)")
      ELSE
        Msg("No ammo!  Find a Blaster ) to reload.")
      END
      (* No monster turn: arming is free *)
    ELSIF key = '>' THEN
      IF map[py][px] = STAIRS THEN
        INC(depth);
        GenLevel;
        Msg("Level ");  MsgI(depth);  MsgA(".  Find the elevator.")
      ELSE
        Msg("No elevator here.")
      END;
      IF ~dead THEN  MonsterTurn;  ComputeFOV  END
    ELSIF (key = 'q') OR (key = 1BX) THEN
      EXIT
    ELSE
      Msg("")
    END;

    IF dead THEN
      Render;
      Terminal.Goto(25, 10);
      Graphics.Color256(196, 0);
      Out.String("  +-----------------+  ");
      Terminal.Goto(25, 11);
      Out.String("  |   YOU  DIED !   |  ");
      Terminal.Goto(25, 12);
      Out.String("  +-----------------+  ");
      Terminal.Goto(25, 13);
      Graphics.Color256(226, 0);
      Out.String("  Coins:");  Out.Int(pgold, 5);
      Out.String("  Level:");  Out.Int(depth, 3);
      Out.String("  Lvl:");  Out.Int(plevel, 2);
      Terminal.Goto(25, 15);
      Graphics.Color256(240, 0);
      Out.String("  Press any key.  ");
      Graphics.Reset;
      key := Terminal.ReadKey();
      EXIT
    END
  END;

  Terminal.Clear;
  Terminal.Goto(1, 1)
END BRErogue.
