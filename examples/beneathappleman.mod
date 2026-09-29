MODULE BeneathAppleManor;

IMPORT Terminal, Random, Strings, Out;

CONST
  MapW = 50;
  MapH = 20;
  MaxMonsters = 12;
  MaxChests = 8;

  (* Map Tile Types *)
  TileWall = "#";
  TileFloor = ".";
  TileStairs = ">";

  (* Colors *)
  ColBlack = 0;
  ColRed = 1;
  ColGreen = 2;
  ColYellow = 3;
  ColBlue = 4;
  ColMagenta = 5;
  ColCyan = 6;
  ColWhite = 7;

  (* Key codes *)
  KUp = 0A0X;
  KDown = 0A1X;
  KLeft = 0A2X;
  KRight = 0A3X;

TYPE
  Monster = RECORD
    x, y: INTEGER;
    hp, maxHp: INTEGER;
    str: INTEGER;
    symbol: CHAR;
    name: ARRAY 32 OF CHAR;
    active: BOOLEAN;
  END;

  Chest = RECORD
    x, y: INTEGER;
    gold: INTEGER;
    active: BOOLEAN;
  END;

  Room = RECORD
    x, y, w, h: INTEGER;
    cx, cy: INTEGER;
  END;

VAR
  map: ARRAY MapH, MapW OF CHAR;
  monsters: ARRAY MaxMonsters OF Monster;
  chests: ARRAY MaxChests OF Chest;
  rooms: ARRAY 9 OF Room;

  (* Player State *)
  pX, pY: INTEGER;
  pHP, pMaxHP: INTEGER;
  pMP, pMaxMP: INTEGER;
  pSTR, pDEX, pINT: INTEGER;
  pGold, pXP: INTEGER;
  dungeonLevel: INTEGER;
  gameOver: BOOLEAN;
  msgLog: ARRAY 128 OF CHAR;

PROCEDURE SetMessage(msg: ARRAY OF CHAR);
BEGIN
  Strings.Copy(msg, msgLog);
END SetMessage;

PROCEDURE Abs(x: INTEGER): INTEGER;
BEGIN
  IF x < 0 THEN RETURN -x ELSE RETURN x END;
END Abs;

PROCEDURE Dist(x1, y1, x2, y2: INTEGER): INTEGER;
BEGIN
  RETURN Abs(x1 - x2) + Abs(y1 - y2);
END Dist;

PROCEDURE ClearMap;
VAR r, c: INTEGER;
BEGIN
  FOR r := 0 TO MapH - 1 DO
    FOR c := 0 TO MapW - 1 DO
      map[r, c] := TileWall;
    END;
  END;
END ClearMap;

PROCEDURE CarveRoom(r: Room);
VAR x, y: INTEGER;
BEGIN
  FOR y := r.y TO r.y + r.h - 1 DO
    FOR x := r.x TO r.x + r.w - 1 DO
      IF (y >= 0) & (y < MapH) & (x >= 0) & (x < MapW) THEN
        map[y, x] := TileFloor;
      END;
    END;
  END;
END CarveRoom;

PROCEDURE CarveCorridor(x1, y1, x2, y2: INTEGER);
VAR x, y: INTEGER;
BEGIN
  x := x1; y := y1;
  WHILE x # x2 DO
    IF (y >= 0) & (y < MapH) & (x >= 0) & (x < MapW) THEN map[y, x] := TileFloor; END;
    IF x < x2 THEN INC(x) ELSE DEC(x) END;
  END;
  WHILE y # y2 DO
    IF (y >= 0) & (y < MapH) & (x >= 0) & (x < MapW) THEN map[y, x] := TileFloor; END;
    IF y < y2 THEN INC(y) ELSE DEC(y) END;
  END;
  IF (y >= 0) & (y < MapH) & (x >= 0) & (x < MapW) THEN map[y, x] := TileFloor; END;
END CarveCorridor;

PROCEDURE SpawnMonster(idx, x, y: INTEGER);
VAR mType: INTEGER;
BEGIN
  monsters[idx].x := x;
  monsters[idx].y := y;
  monsters[idx].active := TRUE;

  mType := Random.Int(4);
  IF mType = 0 THEN
    monsters[idx].symbol := "G";
    Strings.Copy("Goblin", monsters[idx].name);
    monsters[idx].hp := 8 + dungeonLevel * 2;
    monsters[idx].str := 3 + dungeonLevel;
  ELSIF mType = 1 THEN
    monsters[idx].symbol := "S";
    Strings.Copy("Skeleton", monsters[idx].name);
    monsters[idx].hp := 12 + dungeonLevel * 3;
    monsters[idx].str := 4 + dungeonLevel;
  ELSIF mType = 2 THEN
    monsters[idx].symbol := "O";
    Strings.Copy("Orc", monsters[idx].name);
    monsters[idx].hp := 18 + dungeonLevel * 4;
    monsters[idx].str := 6 + dungeonLevel * 2;
  ELSE
    monsters[idx].symbol := "T";
    Strings.Copy("Troll", monsters[idx].name);
    monsters[idx].hp := 30 + dungeonLevel * 5;
    monsters[idx].str := 8 + dungeonLevel * 2;
  END;
  monsters[idx].maxHp := monsters[idx].hp;
END SpawnMonster;

PROCEDURE GenerateLevel;
VAR
  gridX, gridY, roomIdx, i, rx, ry, rw, rh, cellW, cellH: INTEGER;
  mCount, cCount: INTEGER;
BEGIN
  ClearMap;

  cellW := MapW DIV 3;
  cellH := MapH DIV 3;
  roomIdx := 0;

  (* Generate 3x3 Grid of Rooms *)
  FOR gridY := 0 TO 2 DO
    FOR gridX := 0 TO 2 DO
      rw := 4 + Random.Int(cellW - 5);
      rh := 3 + Random.Int(cellH - 4);
      rx := gridX * cellW + 1 + Random.Int(cellW - rw - 1);
      ry := gridY * cellH + 1 + Random.Int(cellH - rh - 1);

      rooms[roomIdx].x := rx;
      rooms[roomIdx].y := ry;
      rooms[roomIdx].w := rw;
      rooms[roomIdx].h := rh;
      rooms[roomIdx].cx := rx + rw DIV 2;
      rooms[roomIdx].cy := ry + rh DIV 2;

      CarveRoom(rooms[roomIdx]);
      INC(roomIdx);
    END;
  END;

  (* Connect adjacent rooms with corridors *)
  FOR i := 0 TO 7 DO
    CarveCorridor(rooms[i].cx, rooms[i].cy, rooms[i+1].cx, rooms[i+1].cy);
  END;

  (* Spawn Player in Room 0 *)
  pX := rooms[0].cx;
  pY := rooms[0].cy;

  (* Stairs down in Room 8 *)
  map[rooms[8].cy, rooms[8].cx] := TileStairs;

  (* Spawn Monsters *)
  mCount := 4 + Random.Int(4) + dungeonLevel;
  IF mCount > MaxMonsters THEN mCount := MaxMonsters; END;
  FOR i := 0 TO MaxMonsters - 1 DO
    IF i < mCount THEN
      roomIdx := 1 + Random.Int(8);
      rx := rooms[roomIdx].x + Random.Int(rooms[roomIdx].w);
      ry := rooms[roomIdx].y + Random.Int(rooms[roomIdx].h);
      SpawnMonster(i, rx, ry);
    ELSE
      monsters[i].active := FALSE;
    END;
  END;

  (* Spawn Chests *)
  cCount := 2 + Random.Int(3);
  IF cCount > MaxChests THEN cCount := MaxChests; END;
  FOR i := 0 TO MaxChests - 1 DO
    IF i < cCount THEN
      roomIdx := 1 + Random.Int(8);
      chests[i].x := rooms[roomIdx].x + Random.Int(rooms[roomIdx].w);
      chests[i].y := rooms[roomIdx].y + Random.Int(rooms[roomIdx].h);
      chests[i].gold := 10 + Random.Int(25) * dungeonLevel;
      chests[i].active := TRUE;
    ELSE
      chests[i].active := FALSE;
    END;
  END;
END GenerateLevel;

PROCEDURE FindMonster(x, y: INTEGER): INTEGER;
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO MaxMonsters - 1 DO
    IF monsters[i].active & (monsters[i].x = x) & (monsters[i].y = y) THEN
      RETURN i;
    END;
  END;
  RETURN -1;
END FindMonster;

PROCEDURE FindChest(x, y: INTEGER): INTEGER;
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO MaxChests - 1 DO
    IF chests[i].active & (chests[i].x = x) & (chests[i].y = y) THEN
      RETURN i;
    END;
  END;
  RETURN -1;
END FindChest;

PROCEDURE Combat(mIdx: INTEGER);
VAR dmg, hitChance: INTEGER;
    numStr: ARRAY 16 OF CHAR;
    msg: ARRAY 128 OF CHAR;
BEGIN
  hitChance := 60 + pDEX * 5;
  IF Random.Int(100) < hitChance THEN
    dmg := pSTR + Random.Int(4);
    DEC(monsters[mIdx].hp, dmg);
    Strings.Copy("You hit ", msg);
    Strings.Append(monsters[mIdx].name, msg);
    Strings.Append(" for ", msg);
    Strings.IntToStr(dmg, numStr);
    Strings.Append(numStr, msg);
    Strings.Append(" dmg!", msg);
    SetMessage(msg);

    IF monsters[mIdx].hp <= 0 THEN
      monsters[mIdx].active := FALSE;
      INC(pXP, monsters[mIdx].maxHp * 2);
      Strings.Copy("You defeated ", msg);
      Strings.Append(monsters[mIdx].name, msg);
      Strings.Append("!", msg);
      SetMessage(msg);
    END;
  ELSE
    Strings.Copy("You missed ", msg);
    Strings.Append(monsters[mIdx].name, msg);
    Strings.Append("!", msg);
    SetMessage(msg);
  END;
END Combat;

PROCEDURE MovePlayer(dx, dy: INTEGER);
VAR nx, ny, mIdx, cIdx: INTEGER;
    numStr: ARRAY 16 OF CHAR;
    msg: ARRAY 128 OF CHAR;
BEGIN
  nx := pX + dx;
  ny := pY + dy;

  IF (nx < 0) OR (nx >= MapW) OR (ny < 0) OR (ny >= MapH) THEN RETURN; END;

  mIdx := FindMonster(nx, ny);
  IF mIdx >= 0 THEN
    Combat(mIdx);
    RETURN;
  END;

  IF map[ny, nx] = TileWall THEN
    SetMessage("Ouch! You bumped into a wall.");
    RETURN;
  END;

  cIdx := FindChest(nx, ny);
  IF cIdx >= 0 THEN
    INC(pGold, chests[cIdx].gold);
    chests[cIdx].active := FALSE;
    Strings.Copy("Opened chest! Found ", msg);
    Strings.IntToStr(chests[cIdx].gold, numStr);
    Strings.Append(numStr, msg);
    Strings.Append(" gold.", msg);
    SetMessage(msg);
  END;

  pX := nx;
  pY := ny;
END MovePlayer;

PROCEDURE Rest;
BEGIN
  IF pHP < pMaxHP THEN
    INC(pHP, 2 + pSTR DIV 3);
    IF pHP > pMaxHP THEN pHP := pMaxHP; END;
  END;
  IF pMP < pMaxMP THEN
    INC(pMP, 1 + pINT DIV 3);
    IF pMP > pMaxMP THEN pMP := pMaxMP; END;
  END;
  SetMessage("You rest and recover health/mana.");
END Rest;

PROCEDURE CastSpell(ch: CHAR);
VAR i, minD, d, target: INTEGER;
    numStr: ARRAY 16 OF CHAR;
    msg: ARRAY 128 OF CHAR;
BEGIN
  IF ch = "h" THEN
    IF pMP >= 3 THEN
      DEC(pMP, 3);
      INC(pHP, 12 + pINT * 2);
      IF pHP > pMaxHP THEN pHP := pMaxHP; END;
      SetMessage("Cast Heal! Restored HP.");
    ELSE
      SetMessage("Not enough Mana for Heal (3 MP needed).");
    END;
  ELSIF ch = "f" THEN
    IF pMP >= 4 THEN
      target := -1;
      minD := 999;
      FOR i := 0 TO MaxMonsters - 1 DO
        IF monsters[i].active THEN
          d := Dist(pX, pY, monsters[i].x, monsters[i].y);
          IF (d < minD) & (d <= 6) THEN
            minD := d;
            target := i;
          END;
        END;
      END;

      IF target >= 0 THEN
        DEC(pMP, 4);
        d := 10 + pINT * 3;
        DEC(monsters[target].hp, d);
        Strings.Copy("Fireball hits ", msg);
        Strings.Append(monsters[target].name, msg);
        Strings.Append(" for ", msg);
        Strings.IntToStr(d, numStr);
        Strings.Append(numStr, msg);
        Strings.Append(" dmg!", msg);
        SetMessage(msg);

        IF monsters[target].hp <= 0 THEN
          monsters[target].active := FALSE;
          INC(pXP, monsters[target].maxHp * 2);
        END;
      ELSE
        SetMessage("No targets in range for Fireball.");
      END;
    ELSE
      SetMessage("Not enough Mana for Fireball (4 MP needed).");
    END;
  ELSIF ch = "t" THEN
    IF pMP >= 5 THEN
      DEC(pMP, 5);
      pX := rooms[Random.Int(9)].cx;
      pY := rooms[Random.Int(9)].cy;
      SetMessage("Teleported to safety!");
    ELSE
      SetMessage("Not enough Mana for Teleport (5 MP needed).");
    END;
  END;
END CastSpell;

PROCEDURE MonsterTurn;
VAR i, d, dx, dy, targetX, targetY, dmg: INTEGER;
    numStr: ARRAY 16 OF CHAR;
    msg: ARRAY 128 OF CHAR;
BEGIN
  FOR i := 0 TO MaxMonsters - 1 DO
    IF monsters[i].active THEN
      d := Dist(monsters[i].x, monsters[i].y, pX, pY);
      IF d = 1 THEN
        dmg := monsters[i].str - (pDEX DIV 4);
        IF dmg < 1 THEN dmg := 1; END;
        DEC(pHP, dmg);
        Strings.Copy(monsters[i].name, msg);
        Strings.Append(" attacks you for ", msg);
        Strings.IntToStr(dmg, numStr);
        Strings.Append(numStr, msg);
        Strings.Append(" dmg!", msg);
        SetMessage(msg);

        IF pHP <= 0 THEN
          pHP := 0;
          gameOver := TRUE;
        END;
      ELSIF d <= 6 THEN
        dx := 0; dy := 0;
        IF monsters[i].x < pX THEN dx := 1; ELSIF monsters[i].x > pX THEN dx := -1; END;
        IF monsters[i].y < pY THEN dy := 1; ELSIF monsters[i].y > pY THEN dy := -1; END;

        targetX := monsters[i].x + dx;
        targetY := monsters[i].y + dy;

        IF (map[targetY, targetX] # TileWall) & (FindMonster(targetX, targetY) < 0) THEN
          monsters[i].x := targetX;
          monsters[i].y := targetY;
        END;
      END;
    END;
  END;
END MonsterTurn;

PROCEDURE DrawScreen;
VAR r, c, i: INTEGER;
    numStr: ARRAY 32 OF CHAR;
    statStr: ARRAY 128 OF CHAR;
BEGIN
  Terminal.Clear;

  (* Render Map *)
  FOR r := 0 TO MapH - 1 DO
    FOR c := 0 TO MapW - 1 DO
      Terminal.Goto(c + 1, r + 1);
      IF map[r, c] = TileWall THEN
        Terminal.Color(ColBlue, ColBlack);
        Out.Char("#");
      ELSIF map[r, c] = TileStairs THEN
        Terminal.Color(ColYellow, ColBlack);
        Out.Char(">");
      ELSE
        Terminal.Color(ColWhite, ColBlack);
        Out.Char(".");
      END;
    END;
  END;

  (* Render Chests *)
  FOR i := 0 TO MaxChests - 1 DO
    IF chests[i].active THEN
      Terminal.Goto(chests[i].x + 1, chests[i].y + 1);
      Terminal.Color(ColYellow, ColBlack);
      Out.Char("$");
    END;
  END;

  (* Render Monsters *)
  FOR i := 0 TO MaxMonsters - 1 DO
    IF monsters[i].active THEN
      Terminal.Goto(monsters[i].x + 1, monsters[i].y + 1);
      Terminal.Color(ColRed, ColBlack);
      Out.Char(monsters[i].symbol);
    END;
  END;

  (* Render Player *)
  Terminal.Goto(pX + 1, pY + 1);
  Terminal.Color(ColGreen, ColBlack);
  Out.Char("@");

  (* Render HUD Stats *)
  Terminal.Goto(1, MapH + 2);
  Terminal.Color(ColCyan, ColBlack);
  Strings.Copy("Lvl:", statStr);
  Strings.IntToStr(dungeonLevel, numStr); Strings.Append(numStr, statStr);
  Strings.Append(" HP:", statStr);
  Strings.IntToStr(pHP, numStr); Strings.Append(numStr, statStr);
  Strings.Append("/", statStr);
  Strings.IntToStr(pMaxHP, numStr); Strings.Append(numStr, statStr);
  Strings.Append(" MP:", statStr);
  Strings.IntToStr(pMP, numStr); Strings.Append(numStr, statStr);
  Strings.Append("/", statStr);
  Strings.IntToStr(pMaxMP, numStr); Strings.Append(numStr, statStr);
  Strings.Append(" STR:", statStr);
  Strings.IntToStr(pSTR, numStr); Strings.Append(numStr, statStr);
  Strings.Append(" DEX:", statStr);
  Strings.IntToStr(pDEX, numStr); Strings.Append(numStr, statStr);
  Strings.Append(" INT:", statStr);
  Strings.IntToStr(pINT, numStr); Strings.Append(numStr, statStr);
  Terminal.Color(ColYellow, ColBlack);
  Strings.Append(" Gold:", statStr);
  Strings.IntToStr(pGold, numStr); Strings.Append(numStr, statStr);
  Strings.Append(" XP:", statStr);
  Strings.IntToStr(pXP, numStr); Strings.Append(numStr, statStr);
  Out.String(statStr);

  (* Controls Bar *)
  Terminal.Goto(1, MapH + 3);
  Terminal.Color(ColWhite, ColBlack);
  Out.String("Move: Arrows/WASD | [r]est | Spells: [h]eal [f]ireball [t]eleport | [>]Stairs | [q]uit");

  (* Message Line *)
  Terminal.Goto(1, MapH + 4);
  Terminal.Color(ColGreen, ColBlack);
  Out.String("Msg: ");
  Out.String(msgLog);

  Terminal.Reset;
END DrawScreen;

PROCEDURE InitGame;
BEGIN
  pMaxHP := 30; pHP := 30;
  pMaxMP := 15; pMP := 15;
  pSTR := 10;
  pDEX := 10;
  pINT := 10;
  pGold := 0;
  pXP := 0;
  dungeonLevel := 1;
  gameOver := FALSE;
  SetMessage("Welcome to Beneath Apple Manor! Gather gold and survive.");
  GenerateLevel;
END InitGame;

PROCEDURE Play;
VAR key: CHAR;
BEGIN
  InitGame;

  WHILE ~gameOver DO
    DrawScreen;
    key := Terminal.ReadKey();

    IF (key = KUp) OR (key = "w") OR (key = "W") THEN
      MovePlayer(0, -1);
      MonsterTurn;
    ELSIF (key = KDown) OR (key = "s") OR (key = "S") THEN
      MovePlayer(0, 1);
      MonsterTurn;
    ELSIF (key = KLeft) OR (key = "a") OR (key = "A") THEN
      MovePlayer(-1, 0);
      MonsterTurn;
    ELSIF (key = KRight) OR (key = "d") OR (key = "D") THEN
      MovePlayer(1, 0);
      MonsterTurn;
    ELSIF key = "r" THEN
      Rest;
      MonsterTurn;
    ELSIF (key = "h") OR (key = "f") OR (key = "t") THEN
      CastSpell(key);
      MonsterTurn;
    ELSIF key = ">" THEN
      IF map[pY, pX] = TileStairs THEN
        INC(dungeonLevel);
        INC(pMaxHP, 5); pHP := pMaxHP;
        INC(pMaxMP, 3); pMP := pMaxMP;
        GenerateLevel;
        SetMessage("You descend deeper into the manor...");
      ELSE
        SetMessage("There are no stairs here!");
      END;
    ELSIF (key = "q") OR (key = "Q") THEN
      gameOver := TRUE;
      SetMessage("You fled the manor!");
    END;
  END;

  (* Game Over Screen *)
  Terminal.Clear;
  Terminal.Goto(10, 10);
  Terminal.Color(ColRed, ColBlack);
  IF pHP <= 0 THEN
    Out.String("GAME OVER - You perished beneath Apple Manor!");
  ELSE
    Out.String("GAME OVER - You escaped alive!");
  END;
  Terminal.Goto(10, 12);
  Terminal.Color(ColYellow, ColBlack);
  Out.String("Final Gold: "); Out.Int(pGold, 0);
  Out.String(" | Final XP: "); Out.Int(pXP, 0);
  Terminal.Goto(10, 14);
  Out.String("Press any key to exit.");
  Terminal.Reset;
  key := Terminal.ReadKey();
END Play;

BEGIN
  Play;
END BeneathAppleManor.