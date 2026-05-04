MODULE BRErogue;
(*
 * Barbarians of the Ruined Earth dungeon crawl – Extended Edition.
 * Post-apocalyptic roguelike based on the BRE RPG rules.
 *
 * Controls: hjkl / arrow keys = move/attack (melee bump)
 *           f + hjkl/arrows  = fire blaster (ranged, uses ammo)
 *           a                = use class ability
 *           >  = descend elevator (when standing on it)
 *           q  = quit
 *
 * Layout (80x24 terminal):
 *   Row 1       : message line
 *   Rows 2..21  : map (80 wide x 20 tall)
 *   Row 22      : stats bar
 *   Row 23      : class & ability bar
 *
 * Classes:
 *   1 Barbarian   – HP 15, ATK 5, DEF 2.
 *                   Battle Shout (a): next melee attack deals double damage.
 *                   3 charges per depth.
 *   2 Beastman    – HP 18, ATK 5, DEF 1.
 *                   Thick Hide (a): take half damage for 10 turns.
 *                   1 charge per depth.
 *   3 Scavenger   – HP 12, ATK 4, DEF 1. Starts with 8 blaster ammo.
 *                   Sneak attack: +4 dmg vs monsters not yet aggro'd.
 *                   Keen Eye (a): teleport to a random room.
 *                   1 charge per depth.
 *   4 Death Priest – HP 10, ATK 3, DEF 1.
 *                   Spirit Drain (a): steal 1d8+depth HP from nearest
 *                   visible monster, healing yourself the same amount.
 *                   2 charges per depth.
 *   5 Robot       – HP 12, ATK 4, DEF 3. No natural regen. Blaster +3 dmg.
 *                   Overclock (a): half damage for 5 turns.
 *                   1 charge per depth.
 *
 * Monsters (tier gated by player level):
 *   Tier 1: cultist 'c', raider 'r', antmen worker 'a', skeleton 's',
 *            pig raider 'p', hawk-man 'h'
 *   Tier 2: giant beetle 'B', giant lizard 'l', flaming raider 'R',
 *            killer clown 'K', croc-man 'C', wasteland wolf 'w'
 *   Tier 3 (lv3+): demon dog 'd', cult leader 'L', robot 'b',
 *            fungal killer 'F', vek warrior 'V', techno-zombie 'T'
 *   Tier 4 (lv5+): ape-oid 'A', lightning man 'Z', car golem 'G',
 *            sky octopus 'O', dev. machine 'D', pterodactyl 'P'
 *   Boss (depth 7): Vyconia 'X' – defeat to win!
 *
 * Items:
 *   Ceramic Coins '$', Stim-Pack '!', Blaster ')',
 *   Vibro-Blade '(', Scrap Armor ']'
 *)
IMPORT Terminal, Out, Random, Strings, Files;

CONST
  MW = 80;  MH = 20;
  MAX_ROOMS = 10;
  MAX_MON   = 30;
  MAX_ITEM  = 30;

  WALL   = 0;
  FLOOR  = 1;
  STAIRS = 2;

  COINS      = 0;
  STIMPACK   = 1;
  BLASTER    = 2;
  VIBROBLADE = 3;
  SCRAP      = 4;

  FOV_R      = 7;
  BOSS_DEPTH = 7;

  SAVEFILE   = "BRErogue.sav";
  SAVE_MAGIC = 20250424;   (* bump this if save format changes *)

  CLASS_BARB   = 1;
  CLASS_BEAST  = 2;
  CLASS_SCAV   = 3;
  CLASS_PRIEST = 4;
  CLASS_ROBOT  = 5;

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
  map  : ARRAY MH, MW OF INTEGER;
  seen : ARRAY MH, MW OF BOOLEAN;
  lit  : ARRAY MH, MW OF BOOLEAN;

  rooms  : ARRAY MAX_ROOMS OF Room;
  nrooms : INTEGER;

  mons  : ARRAY MAX_MON OF Monster;
  nmons : INTEGER;

  items  : ARRAY MAX_ITEM OF Item;
  nitems : INTEGER;

  px, py, php, pmaxhp, patk, pdef : INTEGER;
  pgold, pxp, pxpnext, plevel, depth : INTEGER;
  pammo   : INTEGER;
  pfiring : BOOLEAN;
  dead    : BOOLEAN;
  won     : BOOLEAN;
  bossAlive : BOOLEAN;
  healTimer : INTEGER;

  pclass          : INTEGER;   (* 1=Barb 2=Beast 3=Scav 4=Priest 5=Robot *)
  pabilityCharges : INTEGER;   (* uses remaining for class ability *)
  pabilityTimer   : INTEGER;   (* turns left for timed ability effect *)
  pshout          : BOOLEAN;   (* Barbarian: next attack is doubled *)

  msg  : ARRAY 80 OF CHAR;
  stmp : ARRAY 16 OF CHAR;
  key  : CHAR;


(* ── Message helpers ──────────────────────────────────────────── *)

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


(* ── Line-of-sight ────────────────────────────────────────────── *)

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


(* ── FOV ──────────────────────────────────────────────────────── *)

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


(* ── Dungeon generation ───────────────────────────────────────── *)

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


(* ── Spawn monsters ───────────────────────────────────────────── *)

PROCEDURE SpawnMonsters;
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

          k := Random.Int(10) + depth;
          IF plevel < 3 THEN
            IF k > 8 THEN  k := 8  END
          ELSIF plevel < 5 THEN
            IF k > 12 THEN  k := 12  END
          END;

          j := Random.Int(6);

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
            ELSIF j = 3 THEN
              mons[nmons].ch := 's';  COPY("skeleton", mons[nmons].name);
              mons[nmons].maxhp := 5 + Random.Int(3);
              mons[nmons].atk := 2;  mons[nmons].def := 0;  mons[nmons].xpval := 2
            ELSIF j = 4 THEN
              mons[nmons].ch := 'p';  COPY("pig raider", mons[nmons].name);
              mons[nmons].maxhp := 7 + Random.Int(4);
              mons[nmons].atk := 3;  mons[nmons].def := 1;  mons[nmons].xpval := 4
            ELSE
              mons[nmons].ch := 'h';  COPY("hawk-man", mons[nmons].name);
              mons[nmons].maxhp := 5 + Random.Int(4);
              mons[nmons].atk := 3;  mons[nmons].def := 0;  mons[nmons].xpval := 4
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
            ELSIF j = 3 THEN
              mons[nmons].ch := 'K';  COPY("killer clown", mons[nmons].name);
              mons[nmons].maxhp := 12 + Random.Int(5);
              mons[nmons].atk := 5;  mons[nmons].def := 2;  mons[nmons].xpval := 8
            ELSIF j = 4 THEN
              mons[nmons].ch := 'C';  COPY("croc-man", mons[nmons].name);
              mons[nmons].maxhp := 14 + Random.Int(6);
              mons[nmons].atk := 5;  mons[nmons].def := 2;  mons[nmons].xpval := 9
            ELSE
              mons[nmons].ch := 'w';  COPY("wasteland wolf", mons[nmons].name);
              mons[nmons].maxhp := 10 + Random.Int(5);
              mons[nmons].atk := 4;  mons[nmons].def := 1;  mons[nmons].xpval := 6
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
            ELSIF j = 3 THEN
              mons[nmons].ch := 'F';  COPY("fungal killer", mons[nmons].name);
              mons[nmons].maxhp := 19 + Random.Int(7);
              mons[nmons].atk := 7;  mons[nmons].def := 1;  mons[nmons].xpval := 13
            ELSIF j = 4 THEN
              mons[nmons].ch := 'V';  COPY("vek warrior", mons[nmons].name);
              mons[nmons].maxhp := 22 + Random.Int(8);
              mons[nmons].atk := 9;  mons[nmons].def := 2;  mons[nmons].xpval := 18
            ELSE
              mons[nmons].ch := 'T';  COPY("techno-zombie", mons[nmons].name);
              mons[nmons].maxhp := 18 + Random.Int(7);
              mons[nmons].atk := 7;  mons[nmons].def := 0;  mons[nmons].xpval := 13
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
            ELSIF j = 3 THEN
              mons[nmons].ch := 'O';  COPY("sky octopus", mons[nmons].name);
              mons[nmons].maxhp := 28 + Random.Int(10);
              mons[nmons].atk := 12;  mons[nmons].def := 2;  mons[nmons].xpval := 28
            ELSIF j = 4 THEN
              mons[nmons].ch := 'D';  COPY("dev. machine", mons[nmons].name);
              mons[nmons].maxhp := 35 + Random.Int(10);
              mons[nmons].atk := 15;  mons[nmons].def := 3;  mons[nmons].xpval := 35
            ELSE
              mons[nmons].ch := 'P';  COPY("pterodactyl", mons[nmons].name);
              mons[nmons].maxhp := 25 + Random.Int(10);
              mons[nmons].atk := 11;  mons[nmons].def := 1;  mons[nmons].xpval := 22
            END
          END;

          mons[nmons].hp := mons[nmons].maxhp;
          INC(nmons)
        END
      END
    END
  END
END SpawnMonsters;

PROCEDURE SpawnBoss;
(* Place Vyconia the Rapturous in the last room *)
VAR bx, by : INTEGER;
BEGIN
  IF nmons < MAX_MON THEN
    bx := rooms[nrooms-1].x + rooms[nrooms-1].w DIV 2;
    by := rooms[nrooms-1].y + rooms[nrooms-1].h DIV 2;
    (* Don't overlap stairs *)
    IF map[by][bx] = STAIRS THEN
      IF by > rooms[nrooms-1].y THEN  DEC(by)
      ELSE  INC(by)
      END
    END;
    mons[nmons].x     := bx;
    mons[nmons].y     := by;
    mons[nmons].alive := TRUE;
    mons[nmons].ch    := 'X';
    COPY("Vyconia", mons[nmons].name);
    mons[nmons].maxhp := 60 + Random.Int(20);
    mons[nmons].hp    := mons[nmons].maxhp;
    mons[nmons].atk   := 16;
    mons[nmons].def   := 4;
    mons[nmons].xpval := 200;
    INC(nmons);
    bossAlive := TRUE
  END
END SpawnBoss;

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
            items[nitems].kind  := COINS;
            items[nitems].value := Random.Int(20) + 5 + depth * 3;
            items[nitems].ch    := '$'
          ELSIF k < 7 THEN
            items[nitems].kind  := STIMPACK;
            items[nitems].value := 8 + depth * 2;
            items[nitems].ch    := '!'
          ELSIF k < 9 THEN
            items[nitems].kind  := BLASTER;
            items[nitems].value := 4 + depth;
            items[nitems].ch    := ')'
          ELSIF k < 11 THEN
            items[nitems].kind  := VIBROBLADE;
            items[nitems].value := 1 + depth DIV 3;
            items[nitems].ch    := '('
          ELSE
            items[nitems].kind  := SCRAP;
            items[nitems].value := 1 + depth DIV 3;
            items[nitems].ch    := ']'
          END;
          INC(nitems)
        END
      END
    END
  END
END SpawnItems;


(* ── Combat ───────────────────────────────────────────────────── *)

PROCEDURE LevelUp;
VAR hpGain : INTEGER;
BEGIN
  INC(plevel);
  pxp     := pxp - pxpnext;
  pxpnext := pxpnext + 10 * plevel;

  (* Class-specific HP gain per level *)
  IF    pclass = CLASS_BARB   THEN  hpGain := Random.Int(10) + 1 + 2
  ELSIF pclass = CLASS_BEAST  THEN  hpGain := Random.Int(12) + 1 + 2
  ELSIF pclass = CLASS_SCAV   THEN  hpGain := Random.Int(8)  + 1 + 1
  ELSIF pclass = CLASS_PRIEST THEN  hpGain := Random.Int(6)  + 1
  ELSE (* Robot *)                  hpGain := Random.Int(8)  + 1 + 1
  END;
  pmaxhp := pmaxhp + hpGain;
  php    := php    + hpGain;

  INC(patk);
  IF (pclass = CLASS_BARB) OR (pclass = CLASS_ROBOT) THEN  INC(pdef)  END;

  (* Barbarian refreshes Battle Shout on level-up too *)
  IF pclass = CLASS_BARB THEN  pabilityCharges := 3  END;

  MsgA("  ** LEVEL UP! **")
END LevelUp;

PROCEDURE KillMonster(mi : INTEGER);
BEGIN
  mons[mi].alive := FALSE;
  MsgA("  Slain!");
  pxp := pxp + mons[mi].xpval;
  IF mons[mi].ch = 'X' THEN
    won := TRUE;
    bossAlive := FALSE
  END;
  IF pxp >= pxpnext THEN  LevelUp  END
END KillMonster;

PROCEDURE Attack(mi : INTEGER);
VAR dmg : INTEGER;
    sneak : BOOLEAN;
BEGIN
  sneak := (pclass = CLASS_SCAV) & ~lit[mons[mi].y][mons[mi].x];
  dmg := patk + Random.Int(4) - mons[mi].def;
  IF dmg < 1 THEN  dmg := 1  END;
  IF pshout THEN
    dmg := dmg * 2;
    pshout := FALSE;
    MsgA("(SHOUT!) ")
  END;
  IF sneak THEN
    dmg := dmg + 4;
    MsgA("(sneak!) ")
  END;
  mons[mi].hp := mons[mi].hp - dmg;
  Msg("You hit the ");  MsgA(mons[mi].name);
  MsgA(" for ");  MsgI(dmg);  MsgA(" dmg");
  IF mons[mi].hp <= 0 THEN  KillMonster(mi)  END
END Attack;

PROCEDURE RangedAttack(dx, dy : INTEGER);
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
    IF pclass = CLASS_ROBOT THEN  dmg := dmg + 3  END;
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
  IF dmg < 1 THEN  dmg := 1  END;
  (* Beastman Thick Hide / Robot Overclock: half damage *)
  IF pabilityTimer > 0 THEN
    dmg := dmg DIV 2;
    IF dmg < 1 THEN  dmg := 1  END
  END;
  php := php - dmg;
  Msg("The ");  MsgA(mons[mi].name);
  MsgA(" hits you for ");  MsgI(dmg);  MsgC('.');
  IF php <= 0 THEN  php := 0;  dead := TRUE  END
END MonsterAttack;

PROCEDURE UseAbility;
(* Activate the current class ability *)
VAR i, best, dist, d, dmg : INTEGER;
    ri : INTEGER;
BEGIN
  IF pabilityCharges <= 0 THEN
    Msg("No ability charges!  Press > to descend and restock.");
    RETURN
  END;

  IF pclass = CLASS_BARB THEN
    (* Battle Shout: next attack deals double damage *)
    pshout := TRUE;
    DEC(pabilityCharges);
    Msg("BATTLE SHOUT!  Next attack will hit twice as hard!")

  ELSIF pclass = CLASS_BEAST THEN
    (* Thick Hide: half damage for 10 turns *)
    pabilityTimer := 10;
    DEC(pabilityCharges);
    Msg("Your hide thickens – half damage for 10 turns!")

  ELSIF pclass = CLASS_SCAV THEN
    (* Keen Eye: teleport to a random non-starting room *)
    IF nrooms > 1 THEN
      ri := Random.Int(nrooms - 1) + 1;
      px := rooms[ri].x + rooms[ri].w DIV 2;
      py := rooms[ri].y + rooms[ri].h DIV 2;
      ComputeFOV;
      DEC(pabilityCharges);
      Msg("You vanish into the shadows and reappear elsewhere!")
    ELSE
      Msg("Nowhere to go!")
    END

  ELSIF pclass = CLASS_PRIEST THEN
    (* Spirit Drain: steal HP from nearest visible monster *)
    best := -1;  dist := 9999;
    FOR i := 0 TO nmons - 1 DO
      IF mons[i].alive & lit[mons[i].y][mons[i].x] THEN
        d := ABS(mons[i].x - px) + ABS(mons[i].y - py);
        IF d < dist THEN  dist := d;  best := i  END
      END
    END;
    IF best >= 0 THEN
      dmg := Random.Int(8) + 1 + depth;
      IF dmg > mons[best].hp THEN  dmg := mons[best].hp  END;
      mons[best].hp := mons[best].hp - dmg;
      php := php + dmg;
      IF php > pmaxhp THEN  php := pmaxhp  END;
      DEC(pabilityCharges);
      Msg("SPIRIT DRAIN!  Stole ");  MsgI(dmg);
      MsgA(" HP from the ");  MsgA(mons[best].name);  MsgC('!');
      IF mons[best].hp <= 0 THEN  KillMonster(best)  END
    ELSE
      Msg("No visible target for Spirit Drain!")
    END

  ELSE (* Robot: Overclock – damage shield for 5 turns *)
    pabilityTimer := 5;
    DEC(pabilityCharges);
    Msg("OVERCLOCK!  Damage shield active for 5 turns!")
  END
END UseAbility;


(* ── Monster AI ───────────────────────────────────────────────── *)

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

  (* Decrement timed ability *)
  IF pabilityTimer > 0 THEN  DEC(pabilityTimer)  END;

  (* Natural regeneration – Robots don't heal naturally *)
  IF pclass # CLASS_ROBOT THEN
    INC(healTimer);
    IF healTimer >= 15 THEN
      healTimer := 0;
      IF php < pmaxhp THEN  INC(php)  END
    END
  END
END MonsterTurn;


(* ── Player move ──────────────────────────────────────────────── *)

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


(* ── Rendering ────────────────────────────────────────────────── *)

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
      IF    items[i].kind = COINS      THEN  Terminal.Color256(226, 0)
      ELSIF items[i].kind = STIMPACK   THEN  Terminal.Color256(51,  0)
      ELSIF items[i].kind = BLASTER    THEN  Terminal.Color256(214, 0)
      ELSIF items[i].kind = VIBROBLADE THEN  Terminal.Color256(15,  0)
      ELSE                                   Terminal.Color256(240, 0)
      END;
      Out.Char(items[i].ch)
    END
  END;

  FOR i := 0 TO nmons - 1 DO
    IF mons[i].alive & lit[mons[i].y][mons[i].x] THEN
      Terminal.Goto(mons[i].x + 1, mons[i].y + 2);
      (* Tier 1 *)
      IF    mons[i].ch = 'c' THEN  Terminal.Color256(160, 0)
      ELSIF mons[i].ch = 'r' THEN  Terminal.Color256(166, 0)
      ELSIF mons[i].ch = 'a' THEN  Terminal.Color256(100, 0)
      ELSIF mons[i].ch = 's' THEN  Terminal.Color256(250, 0)
      ELSIF mons[i].ch = 'p' THEN  Terminal.Color256(206, 0)  (* pig raider: pink *)
      ELSIF mons[i].ch = 'h' THEN  Terminal.Color256(220, 0)  (* hawk-man: gold *)
      (* Tier 2 *)
      ELSIF mons[i].ch = 'B' THEN  Terminal.Color256(130, 0)
      ELSIF mons[i].ch = 'l' THEN  Terminal.Color256(64,  0)
      ELSIF mons[i].ch = 'R' THEN  Terminal.Color256(202, 0)
      ELSIF mons[i].ch = 'K' THEN  Terminal.Color256(201, 0)
      ELSIF mons[i].ch = 'C' THEN  Terminal.Color256(40,  0)  (* croc-man: bright green *)
      ELSIF mons[i].ch = 'w' THEN  Terminal.Color256(180, 0)  (* wasteland wolf: sandy tan *)
      (* Tier 3 *)
      ELSIF mons[i].ch = 'd' THEN  Terminal.Color256(208, 0)
      ELSIF mons[i].ch = 'L' THEN  Terminal.Color256(196, 0)
      ELSIF mons[i].ch = 'b' THEN  Terminal.Color256(51,  0)
      ELSIF mons[i].ch = 'F' THEN  Terminal.Color256(34,  0)
      ELSIF mons[i].ch = 'V' THEN  Terminal.Color256(105, 0)  (* vek warrior: purple *)
      ELSIF mons[i].ch = 'T' THEN  Terminal.Color256(29,  0)  (* techno-zombie: teal *)
      (* Tier 4 *)
      ELSIF mons[i].ch = 'A' THEN  Terminal.Color256(226, 0)
      ELSIF mons[i].ch = 'Z' THEN  Terminal.Color256(227, 0)
      ELSIF mons[i].ch = 'G' THEN  Terminal.Color256(68,  0)
      ELSIF mons[i].ch = 'O' THEN  Terminal.Color256(135, 0)
      ELSIF mons[i].ch = 'D' THEN  Terminal.Color256(88,  0)  (* dev. machine: dark red *)
      ELSIF mons[i].ch = 'P' THEN  Terminal.Color256(33,  0)  (* pterodactyl: blue *)
      (* Boss *)
      ELSIF mons[i].ch = 'X' THEN  Terminal.Color256(201, 0)  (* Vyconia: magenta *)
      ELSE                          Terminal.Color256(196, 0)
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
  Terminal.Color256(214, 0);
  Out.String("  Ammo:");  Out.Int(pammo, 0);
  Terminal.Color256(226, 0);
  Out.String("  Coins:");  Out.Int(pgold, 0);
  Terminal.Color256(46, 0);
  Out.String("  Flr:");  Out.Int(depth, 0);
  Terminal.Color256(51, 0);
  Out.String("  Lv:");  Out.Int(plevel, 0);
  Out.String("  XP:");  Out.Int(pxp, 0);  Out.Char('/');  Out.Int(pxpnext, 0);
  Terminal.Color256(240, 0);
  Out.String("  f+dir=fire ");
  Terminal.Reset
END DrawStats;

PROCEDURE DrawClassBar;
BEGIN
  Terminal.Goto(1, 23);
  Terminal.Color256(220, 0);
  IF    pclass = CLASS_BARB   THEN  Out.String(" Barbarian ")
  ELSIF pclass = CLASS_BEAST  THEN  Out.String(" Beastman  ")
  ELSIF pclass = CLASS_SCAV   THEN  Out.String(" Scavenger ")
  ELSIF pclass = CLASS_PRIEST THEN  Out.String(" Dt.Priest ")
  ELSE                              Out.String(" Robot     ")
  END;
  Terminal.Color256(240, 0);
  Out.String("| a=");
  Terminal.Color256(51, 0);
  IF    pclass = CLASS_BARB   THEN  Out.String("BattleShout")
  ELSIF pclass = CLASS_BEAST  THEN  Out.String("Thick Hide ")
  ELSIF pclass = CLASS_SCAV   THEN  Out.String("Keen Eye   ")
  ELSIF pclass = CLASS_PRIEST THEN  Out.String("SpiritDrain")
  ELSE                              Out.String("Overclock  ")
  END;
  Terminal.Color256(196, 0);
  Out.String("[");  Out.Int(pabilityCharges, 0);  Out.String("]");
  IF pshout THEN
    Terminal.Color256(226, 0);
    Out.String(" SHOUT-RDY")
  ELSIF pabilityTimer > 0 THEN
    Terminal.Color256(46, 0);
    Out.String(" ACTIVE:");  Out.Int(pabilityTimer, 0);  Out.String("t")
  END;
  IF bossAlive THEN
    Terminal.Color256(201, 0);
    Out.String("  *** SLAY VYCONIA 'X' TO WIN! ***")
  END;
  Out.String("      ");  (* pad to overwrite leftovers *)
  Terminal.Reset
END DrawClassBar;

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
  DrawClassBar;
  DrawMsg
END Render;


(* ── Level setup ──────────────────────────────────────────────── *)

PROCEDURE GenLevel;
BEGIN
  bossAlive := FALSE;
  GenDungeon;
  px := rooms[0].x + rooms[0].w DIV 2;
  py := rooms[0].y + rooms[0].h DIV 2;
  SpawnMonsters;
  IF depth = BOSS_DEPTH THEN  SpawnBoss  END;
  SpawnItems;
  ComputeFOV
END GenLevel;

PROCEDURE RefreshAbility;
(* Refresh class ability charges on entering a new depth *)
BEGIN
  IF    pclass = CLASS_BARB   THEN  pabilityCharges := 3
  ELSIF pclass = CLASS_PRIEST THEN  pabilityCharges := 2
  ELSE                              pabilityCharges := 1
  END;
  pabilityTimer := 0;
  pshout        := FALSE
END RefreshAbility;


(* ── Save / Load ──────────────────────────────────────────────── *)

PROCEDURE NameFromCh(c : CHAR; VAR name : ARRAY OF CHAR);
(* Rebuild monster name from its display character (avoids saving strings) *)
BEGIN
  IF    c = 'c' THEN  COPY("cultist",       name)
  ELSIF c = 'r' THEN  COPY("raider",        name)
  ELSIF c = 'a' THEN  COPY("antmen worker", name)
  ELSIF c = 's' THEN  COPY("skeleton",      name)
  ELSIF c = 'p' THEN  COPY("pig raider",    name)
  ELSIF c = 'h' THEN  COPY("hawk-man",      name)
  ELSIF c = 'B' THEN  COPY("giant beetle",  name)
  ELSIF c = 'l' THEN  COPY("giant lizard",  name)
  ELSIF c = 'R' THEN  COPY("flaming raider",name)
  ELSIF c = 'K' THEN  COPY("killer clown",  name)
  ELSIF c = 'C' THEN  COPY("croc-man",      name)
  ELSIF c = 'w' THEN  COPY("wasteland wolf",name)
  ELSIF c = 'd' THEN  COPY("demon dog",     name)
  ELSIF c = 'L' THEN  COPY("cult leader",   name)
  ELSIF c = 'b' THEN  COPY("robot",         name)
  ELSIF c = 'F' THEN  COPY("fungal killer", name)
  ELSIF c = 'V' THEN  COPY("vek warrior",   name)
  ELSIF c = 'T' THEN  COPY("techno-zombie", name)
  ELSIF c = 'A' THEN  COPY("ape-oid",       name)
  ELSIF c = 'Z' THEN  COPY("lightning man", name)
  ELSIF c = 'G' THEN  COPY("car golem",     name)
  ELSIF c = 'O' THEN  COPY("sky octopus",   name)
  ELSIF c = 'D' THEN  COPY("dev. machine",  name)
  ELSIF c = 'P' THEN  COPY("pterodactyl",   name)
  ELSIF c = 'X' THEN  COPY("Vyconia",       name)
  ELSE                COPY("unknown",        name)
  END
END NameFromCh;

PROCEDURE WBool(VAR r : Files.Rider; b : BOOLEAN);
BEGIN  IF b THEN  Files.WriteInt(r, 1)  ELSE  Files.WriteInt(r, 0)  END  END WBool;

PROCEDURE RBool(VAR r : Files.Rider; VAR b : BOOLEAN);
VAR n : INTEGER;
BEGIN  Files.ReadInt(r, n);  b := n # 0  END RBool;

PROCEDURE SaveGame;
VAR f : Files.File;  r : Files.Rider;
    x, y, i : INTEGER;
BEGIN
  f := Files.New(SAVEFILE);
  IF f = NIL THEN  RETURN  END;
  Files.Set(r, f, 0);

  (* Header *)
  Files.WriteInt(r, SAVE_MAGIC);

  (* Player scalars *)
  Files.WriteInt(r, pclass);
  Files.WriteInt(r, px);        Files.WriteInt(r, py);
  Files.WriteInt(r, php);       Files.WriteInt(r, pmaxhp);
  Files.WriteInt(r, patk);      Files.WriteInt(r, pdef);
  Files.WriteInt(r, pgold);
  Files.WriteInt(r, pxp);       Files.WriteInt(r, pxpnext);
  Files.WriteInt(r, plevel);    Files.WriteInt(r, depth);
  Files.WriteInt(r, pammo);
  Files.WriteInt(r, healTimer);
  Files.WriteInt(r, pabilityCharges);
  Files.WriteInt(r, pabilityTimer);
  WBool(r, pshout);
  WBool(r, bossAlive);

  (* Rooms *)
  Files.WriteInt(r, nrooms);
  FOR i := 0 TO nrooms - 1 DO
    Files.WriteInt(r, rooms[i].x);  Files.WriteInt(r, rooms[i].y);
    Files.WriteInt(r, rooms[i].w);  Files.WriteInt(r, rooms[i].h)
  END;

  (* Map and seen arrays *)
  FOR y := 0 TO MH - 1 DO
    FOR x := 0 TO MW - 1 DO
      Files.WriteInt(r, map[y][x])
    END
  END;
  FOR y := 0 TO MH - 1 DO
    FOR x := 0 TO MW - 1 DO
      IF seen[y][x] THEN  Files.WriteInt(r, 1)
      ELSE                Files.WriteInt(r, 0)
      END
    END
  END;

  (* Monsters *)
  Files.WriteInt(r, nmons);
  FOR i := 0 TO nmons - 1 DO
    Files.WriteInt(r, mons[i].x);      Files.WriteInt(r, mons[i].y);
    Files.WriteInt(r, mons[i].hp);     Files.WriteInt(r, mons[i].maxhp);
    Files.WriteInt(r, mons[i].atk);    Files.WriteInt(r, mons[i].def);
    Files.WriteInt(r, mons[i].xpval);
    Files.WriteInt(r, ORD(mons[i].ch));
    WBool(r, mons[i].alive)
  END;

  (* Items *)
  Files.WriteInt(r, nitems);
  FOR i := 0 TO nitems - 1 DO
    Files.WriteInt(r, items[i].x);     Files.WriteInt(r, items[i].y);
    Files.WriteInt(r, items[i].kind);  Files.WriteInt(r, items[i].value);
    Files.WriteInt(r, ORD(items[i].ch));
    WBool(r, items[i].there)
  END;

  Files.Register(f);
  Files.Close(f)
END SaveGame;

PROCEDURE LoadGame() : BOOLEAN;
VAR f : Files.File;  r : Files.Rider;
    x, y, i, n : INTEGER;
BEGIN
  f := Files.Old(SAVEFILE);
  IF f = NIL THEN  RETURN FALSE  END;
  Files.Set(r, f, 0);

  (* Verify magic *)
  Files.ReadInt(r, n);
  IF (r.eof) OR (n # SAVE_MAGIC) THEN  Files.Close(f);  RETURN FALSE  END;

  (* Player scalars *)
  Files.ReadInt(r, pclass);
  Files.ReadInt(r, px);         Files.ReadInt(r, py);
  Files.ReadInt(r, php);        Files.ReadInt(r, pmaxhp);
  Files.ReadInt(r, patk);       Files.ReadInt(r, pdef);
  Files.ReadInt(r, pgold);
  Files.ReadInt(r, pxp);        Files.ReadInt(r, pxpnext);
  Files.ReadInt(r, plevel);     Files.ReadInt(r, depth);
  Files.ReadInt(r, pammo);
  Files.ReadInt(r, healTimer);
  Files.ReadInt(r, pabilityCharges);
  Files.ReadInt(r, pabilityTimer);
  RBool(r, pshout);
  RBool(r, bossAlive);

  (* Rooms *)
  Files.ReadInt(r, nrooms);
  FOR i := 0 TO nrooms - 1 DO
    Files.ReadInt(r, rooms[i].x);  Files.ReadInt(r, rooms[i].y);
    Files.ReadInt(r, rooms[i].w);  Files.ReadInt(r, rooms[i].h)
  END;

  (* Map and seen *)
  FOR y := 0 TO MH - 1 DO
    FOR x := 0 TO MW - 1 DO
      Files.ReadInt(r, map[y][x])
    END
  END;
  FOR y := 0 TO MH - 1 DO
    FOR x := 0 TO MW - 1 DO
      Files.ReadInt(r, n);  seen[y][x] := n # 0
    END
  END;

  (* Monsters *)
  Files.ReadInt(r, nmons);
  FOR i := 0 TO nmons - 1 DO
    Files.ReadInt(r, mons[i].x);      Files.ReadInt(r, mons[i].y);
    Files.ReadInt(r, mons[i].hp);     Files.ReadInt(r, mons[i].maxhp);
    Files.ReadInt(r, mons[i].atk);    Files.ReadInt(r, mons[i].def);
    Files.ReadInt(r, mons[i].xpval);
    Files.ReadInt(r, n);  mons[i].ch := CHR(n);
    RBool(r, mons[i].alive);
    NameFromCh(mons[i].ch, mons[i].name)
  END;

  (* Items *)
  Files.ReadInt(r, nitems);
  FOR i := 0 TO nitems - 1 DO
    Files.ReadInt(r, items[i].x);     Files.ReadInt(r, items[i].y);
    Files.ReadInt(r, items[i].kind);  Files.ReadInt(r, items[i].value);
    Files.ReadInt(r, n);  items[i].ch := CHR(n);
    RBool(r, items[i].there)
  END;

  Files.Close(f);
  dead := FALSE;  won := FALSE;
  pfiring := FALSE;

  (* Restore computed state *)
  ComputeFOV;
  RETURN TRUE
END LoadGame;

PROCEDURE EraseSave;
(* Truncate the save file so it fails the magic-number check next time *)
VAR f : Files.File;  r : Files.Rider;
BEGIN
  f := Files.New(SAVEFILE);
  IF f # NIL THEN
    Files.Set(r, f, 0);
    Files.WriteInt(r, 0);   (* invalid magic *)
    Files.Register(f);
    Files.Close(f)
  END
END EraseSave;

PROCEDURE HasSave() : BOOLEAN;
VAR f : Files.File;
BEGIN
  f := Files.Old(SAVEFILE);
  IF f # NIL THEN  Files.Close(f);  RETURN TRUE  END;
  RETURN FALSE
END HasSave;

PROCEDURE SavePrompt;
(* Show a save-found screen and return the user's choice via key *)
BEGIN
  Terminal.Clear;
  Terminal.Goto(2, 3);
  Terminal.Color256(226, 0);
  Out.String("BARBARIANS OF THE RUINED EARTH");
  Terminal.Goto(2, 5);
  Terminal.Color256(46, 0);
  Out.String("  A saved adventure was found!");
  Terminal.Goto(2, 7);
  Terminal.Color256(15, 0);
  Out.String("  (L) Load – continue your adventure");
  Terminal.Goto(2, 8);
  Out.String("  (N) New game – start fresh (discards save)");
  Terminal.Goto(2, 10);
  Terminal.Color256(240, 0);
  Out.String("  Press L or N: ");
  Terminal.Reset;
  REPEAT
    key := Terminal.ReadKey()
  UNTIL (key = 'l') OR (key = 'L') OR (key = 'n') OR (key = 'N')
END SavePrompt;


(* ── Class selection screen ───────────────────────────────────── *)

PROCEDURE ClassSelect;
BEGIN
  Terminal.Clear;
  Terminal.Goto(2, 1);
  Terminal.Color256(226, 0);
  Out.String("BARBARIANS OF THE RUINED EARTH  – Choose Your Class");
  Terminal.Goto(2, 2);
  Out.String("──────────────────────────────────────────────────────────────────────────────");

  Terminal.Goto(2, 4);
  Out.String("1) Barbarian  ");
  Terminal.Color256(250, 0);
  Out.String("HP:15 ATK:5 DEF:2  ");
  Out.String("Battle Shout");
  Out.String(": next melee attack x2 damage. 3 charges/depth.");

  Terminal.Goto(2, 5);
  Out.String("2) Beastman   ");
  Terminal.Color256(250, 0);
  Out.String("HP:18 ATK:5 DEF:1  ");
  Out.String("Thick Hide");
  Out.String(": half damage for 10 turns. 1 charge/depth.");

  Terminal.Goto(2, 6);
  Out.String("3) Scavenger  ");
  Out.String("HP:12 ATK:4 DEF:1  ");
  Out.String("Keen Eye");
  Out.String(": teleport to unknown room. 1 charge/depth. +sneak atk.");

  Terminal.Goto(2, 7);
  Out.String("4) DeathPriest ");
  Out.String("HP:10 ATK:3 DEF:1  ");
  Out.String("Spirit Drain");
  Out.String(": steal HP from visible foe. 2 charges/depth.");

  Terminal.Goto(2, 8);
  Out.String("5) Robot      ");
  Out.String("HP:12 ATK:4 DEF:3  ");
  Out.String("Overclock");
  Out.String(": half damage 5 turns. 1 charge. No natural regen.");

  Terminal.Goto(2, 10);
  Out.String("Goal: reach depth ");
  Out.Int(BOSS_DEPTH, 0);
  Out.String(" and slay Vyconia the Rapturous (X) to win!");

  Terminal.Goto(2, 12);
  Out.String("Press 1-5 to choose: ");
  Terminal.Reset;

  REPEAT
    key := Terminal.ReadKey()
  UNTIL (key >= '1') & (key <= '5');
  pclass := ORD(key) - ORD('0')
END ClassSelect;


(* ── Main ─────────────────────────────────────────────────────── *)

BEGIN
  Terminal.Clear;
  pfiring := FALSE;  dead := FALSE;  won := FALSE;
  bossAlive := FALSE;  healTimer := 0;
  pshout := FALSE;  pabilityTimer := 0;

  (* ── Startup: check for existing save ── *)
  IF HasSave() THEN
    SavePrompt;
    IF (key = 'l') OR (key = 'L') THEN
      IF ~LoadGame() THEN
        (* Corrupted save – fall through to new game *)
        EraseSave;
        ClassSelect;
        IF pclass = CLASS_BARB THEN
          php := 15;  pmaxhp := 15;  patk := 5;  pdef := 2;  pammo := 0
        ELSIF pclass = CLASS_BEAST THEN
          php := 18;  pmaxhp := 18;  patk := 5;  pdef := 1;  pammo := 0
        ELSIF pclass = CLASS_SCAV THEN
          php := 12;  pmaxhp := 12;  patk := 4;  pdef := 1;  pammo := 8
        ELSIF pclass = CLASS_PRIEST THEN
          php := 10;  pmaxhp := 10;  patk := 3;  pdef := 1;  pammo := 0
        ELSE
          php := 12;  pmaxhp := 12;  patk := 4;  pdef := 3;  pammo := 0
        END;
        pgold := 0;  pxp := 0;  pxpnext := 20;
        plevel := 1;  depth := 1;
        RefreshAbility;
        Terminal.Clear;
        GenLevel;
        Msg("Save was corrupt – new game started.  S=save&quit  q=quit")
      ELSE
        Terminal.Clear;
        Msg("Game restored!  S=save&quit  q=quit")
      END
    ELSE
      (* New game – discard save *)
      EraseSave;
      ClassSelect;
      IF pclass = CLASS_BARB THEN
        php := 15;  pmaxhp := 15;  patk := 5;  pdef := 2;  pammo := 0
      ELSIF pclass = CLASS_BEAST THEN
        php := 18;  pmaxhp := 18;  patk := 5;  pdef := 1;  pammo := 0
      ELSIF pclass = CLASS_SCAV THEN
        php := 12;  pmaxhp := 12;  patk := 4;  pdef := 1;  pammo := 8
      ELSIF pclass = CLASS_PRIEST THEN
        php := 10;  pmaxhp := 10;  patk := 3;  pdef := 1;  pammo := 0
      ELSE
        php := 12;  pmaxhp := 12;  patk := 4;  pdef := 3;  pammo := 0
      END;
      pgold := 0;  pxp := 0;  pxpnext := 20;
      plevel := 1;  depth := 1;
      RefreshAbility;
      Terminal.Clear;
      GenLevel;
      Msg("Ruined Earth!  hjkl=move  f+dir=blast  a=ability  >=descend  S=save&quit")
    END
  ELSE
    (* No save – fresh start *)
    ClassSelect;
    IF pclass = CLASS_BARB THEN
      php := 15;  pmaxhp := 15;  patk := 5;  pdef := 2;  pammo := 0
    ELSIF pclass = CLASS_BEAST THEN
      php := 18;  pmaxhp := 18;  patk := 5;  pdef := 1;  pammo := 0
    ELSIF pclass = CLASS_SCAV THEN
      php := 12;  pmaxhp := 12;  patk := 4;  pdef := 1;  pammo := 8
    ELSIF pclass = CLASS_PRIEST THEN
      php := 10;  pmaxhp := 10;  patk := 3;  pdef := 1;  pammo := 0
    ELSE
      php := 12;  pmaxhp := 12;  patk := 4;  pdef := 3;  pammo := 0
    END;
    pgold := 0;  pxp := 0;  pxpnext := 20;
    plevel := 1;  depth := 1;
    RefreshAbility;
    Terminal.Clear;
    GenLevel;
    Msg("Ruined Earth!  hjkl=move  f+dir=blast  a=ability  >=descend  S=save&quit")
  END;

  LOOP
    Render;
    key := Terminal.ReadKey();

    IF pfiring THEN
      pfiring := FALSE;
      IF    (key = KLeft)  OR (key = 'h') THEN  RangedAttack(-1,  0)
      ELSIF (key = KRight) OR (key = 'l') THEN  RangedAttack( 1,  0)
      ELSIF (key = KUp)    OR (key = 'k') THEN  RangedAttack( 0, -1)
      ELSIF (key = KDown)  OR (key = 'j') THEN  RangedAttack( 0,  1)
      ELSE  Msg("Cancelled.")
      END;
      IF ~dead & ~won THEN  MonsterTurn;  ComputeFOV  END

    ELSIF (key = KLeft)  OR (key = 'h') THEN
      TryMove(-1,  0);
      IF ~dead & ~won THEN  MonsterTurn;  ComputeFOV  END
    ELSIF (key = KRight) OR (key = 'l') THEN
      TryMove( 1,  0);
      IF ~dead & ~won THEN  MonsterTurn;  ComputeFOV  END
    ELSIF (key = KUp)    OR (key = 'k') THEN
      TryMove( 0, -1);
      IF ~dead & ~won THEN  MonsterTurn;  ComputeFOV  END
    ELSIF (key = KDown)  OR (key = 'j') THEN
      TryMove( 0,  1);
      IF ~dead & ~won THEN  MonsterTurn;  ComputeFOV  END

    ELSIF key = 'f' THEN
      IF pammo > 0 THEN
        pfiring := TRUE;
        Msg("Fire which direction? (hjkl / arrows)")
      ELSE
        Msg("No ammo!  Find a Blaster ) to reload.")
      END

    ELSIF key = 'a' THEN
      UseAbility;
      IF ~dead & ~won THEN  MonsterTurn;  ComputeFOV  END

    ELSIF key = '>' THEN
      IF map[py][px] = STAIRS THEN
        IF bossAlive THEN
          Msg("Vyconia's sorcery seals the passage – defeat her first!")
        ELSE
          INC(depth);
          GenLevel;
          RefreshAbility;
          IF depth = BOSS_DEPTH THEN
            Msg("DEPTH 7!  Vyconia the Rapturous awaits – slay her to win!")
          ELSE
            Msg("Level ");  MsgI(depth);  MsgA(".  Find the elevator.")
          END
        END
      ELSE
        Msg("No elevator here.")
      END;
      IF ~dead & ~won THEN  MonsterTurn;  ComputeFOV  END

    ELSIF (key = 'S') THEN
      (* Save and quit *)
      SaveGame;
      Terminal.Goto(1, 1);
      Terminal.Color256(46, 0);
      Out.String("Game saved to ");
      Out.String(SAVEFILE);
      Out.String("  – goodbye!");
      Terminal.Reset;
      EXIT

    ELSIF (key = 'q') OR (key = 1BX) THEN
      EXIT
    ELSE
      Msg("")
    END;

    (* ── Death screen ── *)
    IF dead THEN
      EraseSave;
      Render;
      Terminal.Goto(24, 9);
      Terminal.Color256(196, 0);
      Out.String("  +---------------------+");
      Terminal.Goto(24, 10);
      Out.String("  |    YOU  DIED !      |");
      Terminal.Goto(24, 11);
      Out.String("  +---------------------+");
      Terminal.Goto(24, 12);
      Terminal.Color256(226, 0);
      Out.String("  Coins:");  Out.Int(pgold, 5);
      Out.String("  Floor:");  Out.Int(depth, 3);
      Out.String("  Lv:");     Out.Int(plevel, 2);
      Terminal.Goto(24, 14);
      Terminal.Color256(240, 0);
      Out.String("  Press any key.");
      Terminal.Reset;
      key := Terminal.ReadKey();
      EXIT
    END;

    (* ── Victory screen ── *)
    IF won THEN
      EraseSave;
      Render;
      Terminal.Goto(18, 8);
      Terminal.Color256(201, 0);
      Out.String("  +================================+");
      Terminal.Goto(18, 9);
      Out.String("  |       VICTORY !!!              |");
      Terminal.Goto(18, 10);
      Out.String("  |  Vyconia the Rapturous         |");
      Terminal.Goto(18, 11);
      Out.String("  |  has been slain!               |");
      Terminal.Goto(18, 12);
      Out.String("  |  The Ruined Earth is FREE!     |");
      Terminal.Goto(18, 13);
      Out.String("  +================================+");
      Terminal.Goto(18, 15);
      Terminal.Color256(226, 0);
      Out.String("  Coins:");  Out.Int(pgold, 5);
      Out.String("  Level:");  Out.Int(plevel, 3);
      Terminal.Goto(18, 16);
      Terminal.Color256(240, 0);
      Out.String("  Press any key.");
      Terminal.Reset;
      key := Terminal.ReadKey();
      EXIT
    END
  END;

  Terminal.Clear;
  Terminal.Goto(1, 1)
END BRErogue.

