MODULE Metro;
(*
 * Metro Explorer -- a text-mode tour of Washington, D.C. by Metrorail.
 *
 * A stylized schematic of all six lines (Red, Orange, Silver, Blue,
 * Yellow, Green) and all 98 stations.  Pick a station with the arrow
 * keys or the mouse, or let fate choose one with R.  Each station opens
 * a card describing the neighborhood and what there is to see and do.
 * From a card you can "ride" the line to the next or previous stop.
 *
 * Keys (map)   arrows move   Enter/click open   R random   Q quit
 * Keys (card)  Left/Right ride the line   Up/Down switch line
 *              PgUp/PgDn scroll   R random   Esc back to the map
 *
 * Build (from examples/):  ../obc metro.mod -o metro   or   make metro
 *)

IMPORT TUI, Time, Out;

CONST
  MaxSt = 110;  MaxStops = 40;  NLines = 6;  MaxNb = 8;
  MapW = 108;  MapH = 31;          (* map grid, in cells *)
  NeedW = 110;  NeedH = 37;        (* smallest usable terminal *)
  MaxRows = 160;                   (* rows in a station card *)

  (* 256-colour palette entries *)
  CBg = 0;  CText = 252;  CDim = 244;  CHead = 220;  CHi = 226;
  CWhite = 15;  CTitleBg = 18;  CPopBg = 236;  CShadow = 233;  CLogo = 94;

  GH = "─";  GV = "│";  GDn = "╲";  GUp = "╱";
  GStation = "●";  GTransfer = "◉";

TYPE
  Station = RECORD
    name: ARRAY 64 OF CHAR;
    x, y: INTEGER;               (* position on the map grid, 1-based *)
    side: CHAR;                  (* where a permanent label goes: L R A B, or blank *)
    lines: SET;                  (* lines serving the station *)
    hood: ARRAY 700 OF CHAR;     (* the neighborhood *)
    sees: ARRAY 700 OF CHAR      (* things to see and do, separated by | *)
  END;

  Row = RECORD
    txt: ARRAY 200 OF CHAR;
    fg, chip: INTEGER;           (* chip >= 0: a line-colour marker *)
    hi: BOOLEAN
  END;

VAR
  st: ARRAY MaxSt OF Station;
  nSt: INTEGER;
  nb: ARRAY MaxSt, MaxNb OF INTEGER;
  nNb: ARRAY MaxSt OF INTEGER;

  stops: ARRAY NLines, MaxStops OF INTEGER;
  straight: ARRAY NLines, MaxStops OF BOOLEAN;
  nStops: ARRAY NLines OF INTEGER;
  lineName: ARRAY NLines, 8 OF CHAR;
  lineColor: ARRAY NLines OF INTEGER;

  track: ARRAY MapH + 2, MapW + 2 OF SET;
  glyph: ARRAY MapH + 2, MapW + 2 OF INTEGER;   (* 1 - 2 | 3 \ 4 / *)
  stAt: ARRAY MapH + 2, MapW + 2 OF INTEGER;

  rows: ARRAY MaxRows OF Row;
  nRows, scroll: INTEGER;

  ox, oy: INTEGER;                 (* screen position of map cell (1,1) *)
  px, py, pw, ph: INTEGER;         (* last drawn card rectangle *)
  sel, curLine, mode: INTEGER;     (* mode 0 = map, 1 = station card *)
  seed: INTEGER;
  running, loadOk: BOOLEAN;
  badName: ARRAY 64 OF CHAR;
  seqBuf: ARRAY 2000 OF CHAR;          (* a line's stop list, being assembled *)

(* ════════════════════════════════════════════════════════════════════
   Small string helpers (UTF-8 aware where it matters)
   ════════════════════════════════════════════════════════════════════ *)

PROCEDURE StrLen(s: ARRAY OF CHAR): INTEGER;
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (i < LEN(s)) & (s[i] # 0X) DO INC(i) END;
  RETURN i
END StrLen;

(* Number of screen cells a UTF-8 string occupies (one per code point). *)
PROCEDURE Cells(s: ARRAY OF CHAR): INTEGER;
VAR i, n: INTEGER;
BEGIN
  i := 0;  n := 0;
  WHILE (i < LEN(s)) & (s[i] # 0X) DO
    IF (ORD(s[i]) < 128) OR (ORD(s[i]) >= 192) THEN INC(n) END;
    INC(i)
  END;
  RETURN n
END Cells;

PROCEDURE Cat(VAR dst: ARRAY OF CHAR; src: ARRAY OF CHAR);
VAR i, j: INTEGER;
BEGIN
  i := StrLen(dst);  j := 0;
  WHILE (j < LEN(src)) & (src[j] # 0X) & (i < LEN(dst) - 1) DO
    dst[i] := src[j];  INC(i);  INC(j)
  END;
  dst[i] := 0X
END Cat;

PROCEDURE CatCh(VAR dst: ARRAY OF CHAR; c: CHAR);
VAR i: INTEGER;
BEGIN
  i := StrLen(dst);
  IF i < LEN(dst) - 1 THEN dst[i] := c;  dst[i + 1] := 0X END
END CatCh;

PROCEDURE Pad(VAR dst: ARRAY OF CHAR; cells: INTEGER);
BEGIN
  WHILE Cells(dst) < cells DO CatCh(dst, " ") END
END Pad;

PROCEDURE Eq(a, b: ARRAY OF CHAR): BOOLEAN;
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (i < LEN(a)) & (i < LEN(b)) & (a[i] = b[i]) & (a[i] # 0X) DO INC(i) END;
  RETURN ((i = LEN(a)) OR (a[i] = 0X)) & ((i = LEN(b)) OR (b[i] = 0X))
END Eq;

(* PutClip -- PutStr, but never more than max cells. *)
PROCEDURE PutClip(x, y: INTEGER; s: ARRAY OF CHAR; max, fg, bg: INTEGER);
VAR buf: ARRAY 256 OF CHAR;
    i, n: INTEGER;
    done: BOOLEAN;
BEGIN
  i := 0;  n := 0;  done := FALSE;
  WHILE ~done & (i < LEN(s)) & (s[i] # 0X) & (i < LEN(buf) - 1) DO
    IF (ORD(s[i]) < 128) OR (ORD(s[i]) >= 192) THEN
      IF n >= max THEN done := TRUE ELSE INC(n) END
    END;
    IF ~done THEN buf[i] := s[i];  INC(i) END
  END;
  buf[i] := 0X;
  IF max > 0 THEN TUI.PutStr(x, y, buf, fg, bg) END
END PutClip;

(* ════════════════════════════════════════════════════════════════════
   Random numbers (Park-Miller, safe in 32-bit arithmetic)
   ════════════════════════════════════════════════════════════════════ *)

PROCEDURE Rand(n: INTEGER): INTEGER;
VAR hi, lo: INTEGER;
BEGIN
  hi := seed DIV 127773;  lo := seed MOD 127773;
  seed := 16807 * lo - 2836 * hi;
  IF seed <= 0 THEN seed := seed + 2147483647 END;
  RETURN seed MOD n
END Rand;

(* ════════════════════════════════════════════════════════════════════
   Building the network
   ════════════════════════════════════════════════════════════════════ *)

(* Station text is supplied in pieces: obc caps a string literal at 255
   characters, so St creates the station and H / S append to its
   neighborhood and see-and-do texts. *)
PROCEDURE St(name: ARRAY OF CHAR; x, y: INTEGER; side: CHAR);
BEGIN
  IF nSt < MaxSt THEN
    st[nSt].name := name;
    st[nSt].x := x;  st[nSt].y := y;  st[nSt].side := side;
    st[nSt].lines := {};
    st[nSt].hood := "";
    st[nSt].sees := "";
    nNb[nSt] := 0;
    INC(nSt)
  END
END St;

PROCEDURE H(s: ARRAY OF CHAR);
BEGIN
  IF nSt > 0 THEN Cat(st[nSt - 1].hood, s) END
END H;

PROCEDURE S(s: ARRAY OF CHAR);
BEGIN
  IF nSt > 0 THEN Cat(st[nSt - 1].sees, s) END
END S;

PROCEDURE Find(name: ARRAY OF CHAR): INTEGER;
VAR i, r: INTEGER;
BEGIN
  r := -1;  i := 0;
  WHILE (r < 0) & (i < nSt) DO
    IF Eq(st[i].name, name) THEN r := i END;
    INC(i)
  END;
  RETURN r
END Find;

(* Line -- define line l from a ;-separated list of station names.
   A leading ^ on a name draws the segment arriving there straight-first
   (horizontal or vertical run, then the diagonal) instead of the default
   diagonal-first, which keeps a few tracks out of each other's way. *)
PROCEDURE Line(l: INTEGER; nm: ARRAY OF CHAR; col: INTEGER);
BEGIN
  lineName[l] := nm;  lineColor[l] := col;  nStops[l] := 0;  seqBuf := ""
END Line;

PROCEDURE Stops(s: ARRAY OF CHAR);
BEGIN
  Cat(seqBuf, s)
END Stops;

PROCEDURE ParseLine(l: INTEGER);
VAR i, k, id: INTEGER;
    tok: ARRAY 64 OF CHAR;
    sf: BOOLEAN;
BEGIN
  i := 0;
  REPEAT
    k := 0;  sf := FALSE;
    IF seqBuf[i] = "^" THEN sf := TRUE;  INC(i) END;
    WHILE (seqBuf[i] # 0X) & (seqBuf[i] # ";") DO
      IF k < LEN(tok) - 1 THEN tok[k] := seqBuf[i];  INC(k) END;
      INC(i)
    END;
    tok[k] := 0X;
    id := Find(tok);
    IF id < 0 THEN
      loadOk := FALSE;  badName := tok
    ELSIF nStops[l] < MaxStops THEN
      stops[l][nStops[l]] := id;
      straight[l][nStops[l]] := sf;
      INC(nStops[l]);
      INCL(st[id].lines, l)
    END;
    IF seqBuf[i] = ";" THEN INC(i) END
  UNTIL seqBuf[i] = 0X
END ParseLine;

PROCEDURE AddNb(a, b: INTEGER);
VAR i: INTEGER;
    found: BOOLEAN;
BEGIN
  found := FALSE;
  FOR i := 0 TO nNb[a] - 1 DO
    IF nb[a][i] = b THEN found := TRUE END
  END;
  IF ~found & (nNb[a] < MaxNb) THEN nb[a][nNb[a]] := b;  INC(nNb[a]) END
END AddNb;

PROCEDURE IsTransfer(i: INTEGER): BOOLEAN;
BEGIN
  RETURN nNb[i] > 2
END IsTransfer;

PROCEDURE Mark(x, y, l, g: INTEGER);
BEGIN
  IF (x >= 1) & (x <= MapW) & (y >= 1) & (y <= MapH) THEN
    INCL(track[y][x], l);  glyph[y][x] := g
  END
END Mark;

(* Seg -- lay track for line l between stations a and b: a diagonal run
   plus a straight run, in the order sf asks for. *)
PROCEDURE Seg(l, a, b: INTEGER; sf: BOOLEAN);
VAR x, y, dx, dy, sx, sy, nd, ns, i, gd, gs, ddx, ddy: INTEGER;
BEGIN
  x := st[a].x;  y := st[a].y;
  dx := st[b].x - x;  dy := st[b].y - y;
  IF dx > 0 THEN sx := 1 ELSIF dx < 0 THEN sx := -1 ELSE sx := 0 END;
  IF dy > 0 THEN sy := 1 ELSIF dy < 0 THEN sy := -1 ELSE sy := 0 END;
  dx := ABS(dx);  dy := ABS(dy);
  IF dx < dy THEN nd := dx ELSE nd := dy END;
  IF sx * sy > 0 THEN gd := 3 ELSE gd := 4 END;
  IF dx > dy THEN ns := dx - dy;  gs := 1;  ddx := sx;  ddy := 0
  ELSE ns := dy - dx;  gs := 2;  ddx := 0;  ddy := sy
  END;
  IF sf THEN
    FOR i := 1 TO ns DO x := x + ddx;  y := y + ddy;  Mark(x, y, l, gs) END;
    FOR i := 1 TO nd DO x := x + sx;  y := y + sy;  Mark(x, y, l, gd) END
  ELSE
    FOR i := 1 TO nd DO x := x + sx;  y := y + sy;  Mark(x, y, l, gd) END;
    FOR i := 1 TO ns DO x := x + ddx;  y := y + ddy;  Mark(x, y, l, gs) END
  END
END Seg;

PROCEDURE BuildGraph;
VAR l, k, a, b, x, y, i: INTEGER;
BEGIN
  FOR y := 0 TO MapH + 1 DO
    FOR x := 0 TO MapW + 1 DO
      track[y][x] := {};  glyph[y][x] := 0;  stAt[y][x] := -1
    END
  END;
  FOR l := 0 TO NLines - 1 DO
    FOR k := 1 TO nStops[l] - 1 DO
      a := stops[l][k - 1];  b := stops[l][k];
      AddNb(a, b);  AddNb(b, a);
      Seg(l, a, b, straight[l][k])
    END
  END;
  FOR i := 0 TO nSt - 1 DO stAt[st[i].y][st[i].x] := i END
END BuildGraph;

(* ════════════════════════════════════════════════════════════════════
   The stations
   ════════════════════════════════════════════════════════════════════ *)

PROCEDURE LoadRed;
BEGIN
  St("Shady Grove", 32, 1, "L");
      H("The Red Line's northwestern terminus sits in Derwood, between Rockville and Gaithersburg, ringed by enormous commuter garages. Around it spreads the I-270 technology corridor, home to biotech firms, ");
      H("federal labs and planned communities.");
      S("Universities at Shady Grove, a shared campus where several Maryland universities teach upper-level classes|Kentlands, a new-urbanist neighborhood of porches and walkable streets, a short drive ");
      S("west|Rock Creek Regional Park and Lake Needwood for boating, fishing and trails|The Montgomery County Agricultural Fair each August at the Gaithersburg fairgrounds");
  St("Rockville", 35, 1, " ");
      H("The county seat of Montgomery County, with a compact, rebuilt downtown around Rockville Town Square. Amtrak and MARC trains share the station, and Rockville Pike, one of the region's great shopping ");
      H("and dining strips, runs just to the east.");
      S("Rockville Town Square: restaurants, a library, summer concerts and a winter ice rink|F. Scott and Zelda Fitzgerald's grave at St. Mary's Church, steps from the station|Glenview Mansion and its ");
      S("gardens in Rockville Civic Center Park|Dozens of Chinese, Taiwanese and Korean restaurants along Rockville Pike");
  St("Twinbrook", 38, 1, " ");
      H("A postwar neighborhood of modest brick houses that has been filling in with apartments and offices around the station. It is the gateway to the densest stretch of Rockville Pike's strip-mall ");
      H("restaurants.");
      S("Rockville Pike's food scene: dim sum, hot pot, banh mi and bubble tea within a few blocks|Twinbrook Park and the Twinbrook Community Recreation Center|An easy walk or bike ride to Pike and Rose to ");
      S("the south");
  St("North Bethesda", 41, 1, " ");
      H("Known as White Flint until 2023, this stretch of Rockville Pike is being remade from a car-oriented mall strip into a dense, walkable town center. Pike and Rose is the showpiece.");
      S("Pike and Rose: shops, restaurants, a cinema and summer events on its plazas|The Kennedy Shriver Aquatic Center, a large public indoor pool complex|Wall Local Park and the new North Bethesda street ");
      S("grid|Music Center at Strathmore, one stop south");
  St("Grosvenor-Strathmore", 44, 1, " ");
      H("A leafy stop wedged between I-495 and Rockville Pike. The station exists for commuters, but its neighbor is one of the region's top concert halls, linked to the platform by a pedestrian bridge.");
      S("Music Center at Strathmore, a concert hall with superb acoustics and a busy calendar of orchestral, jazz and folk shows|The Mansion at Strathmore, with art exhibitions, a sculpture garden and ");
      S("afternoon tea|Garrett Park, a tiny historic town that is an arboretum in its own right|Rock Creek Trail access for walking and cycling");
  St("Medical Center", 47, 1, " ");
      H("The station sits between two giants of American medicine: the National Institutes of Health campus and Walter Reed National Military Medical Center. The surrounding streets are quiet Bethesda ");
      H("residential blocks.");
      S("The National Library of Medicine, the world's largest biomedical library, with public exhibitions (bring photo ID)|The NIH campus and its Clinical Center, the largest hospital devoted to ");
      S("research|Walter Reed, where presidents receive their annual physicals|The Bethesda Trolley Trail, heading north to Rockville");
  St("Bethesda", 50, 1, " ");
      H("Downtown Bethesda is a dense, affluent urban center with towers, a lively restaurant scene and one of the region's best trails starting just a short walk away. A Purple Line light rail station is ");
      H("being built beneath it.");
      S("Bethesda Row: shops, a cinema and dozens of restaurants with outdoor seating|The Capital Crescent Trail, a paved rail-trail running 7 miles to Georgetown|Imagination Stage, an acclaimed theater for ");
      S("children and families|Bethesda Blues and Jazz Supper Club in a restored 1938 movie palace");
  St("Friendship Heights", 53, 1, " ");
      H("The station straddles the District-Maryland line on Wisconsin Avenue, where Chevy Chase and upper Northwest D.C. meet. It is a long-established shopping district with department stores and mid-rise ");
      H("offices.");
      S("Shopping along Wisconsin Avenue and Western Avenue|Chevy Chase Pavilion and the Friendship Heights Village Center park|Walks into the Chevy Chase and Friendship Heights neighborhoods of grand old ");
      S("houses|Fort Reno Park, the city's highest point, a short walk south");
  St("Tenleytown-AU", 55, 3, " ");
      H("Tenleytown sits on the highest ground in the District, a mostly residential area of shops, schools and churches on Wisconsin Avenue. American University's campus lies a short walk or shuttle ride ");
      H("west.");
      S("Fort Reno Park, the highest natural point in D.C., with free outdoor punk and indie concerts in summer|American University and its Katzen Arts Center museum|Washington National Cathedral, a pleasant ");
      S("walk or bus ride south on Wisconsin Avenue|Neighborhood bookshops and cafes along Wisconsin Avenue");
  St("Van Ness-UDC", 57, 5, " ");
      H("A Connecticut Avenue neighborhood of large prewar apartment buildings, home to the University of the District of Columbia and a cluster of modern embassies at the International Chancery Center.");
      S("Hillwood Estate, Museum and Gardens, Marjorie Merriweather Post's mansion of Faberge eggs and Russian imperial art|Politics and Prose, a beloved independent bookstore a few blocks north|Rock Creek ");
      S("Park's trails via Soapstone Valley|The University of the District of Columbia's campus and theater");
  St("Cleveland Park", 59, 7, " ");
      H("A historic streetcar suburb with a small commercial strip on Connecticut Avenue, Victorian houses on winding streets and a famous Art Deco cinema marquee.");
      S("The Uptown Theater, a 1936 Art Deco landmark|Restaurants and cafes on Connecticut Avenue|Rosedale and Tregaron, two historic estates turned into neighborhood green spaces|Washington National ");
      S("Cathedral, about a 15 minute walk west");
  St("Woodley Park-Zoo/Adams Morgan", 61, 9, " ");
      H("Quiet rowhouses and two grand hotels in Woodley Park; across the Duke Ellington Bridge lies Adams Morgan, one of the city's liveliest and most international nightlife districts.");
      S("Smithsonian's National Zoo, free, with giant pandas, elephants and Asian lions|Adams Morgan's 18th Street: Ethiopian, Salvadoran and late-night food, bars and live music|Rock Creek Park trails and ");
      S("the Rock Creek Trail|The Duke Ellington Bridge's view across the Rock Creek valley");
  St("Dupont Circle", 63, 11, "L");
      H("One of D.C.'s most beloved neighborhoods: Victorian rowhouses, Beaux-Arts mansions now used as embassies and clubs, bookstores and cafes, all spiraling out from a traffic circle with a marble ");
      H("fountain. It has long been the heart of the city's LGBTQ community.");
      S("The circle itself, with its fountain, chess players and a year-round Sunday farmers market|The Phillips Collection, America's first museum of modern art (Renoir's Luncheon of the Boating ");
      S("Party)|Embassy Row along Massachusetts Avenue|Kramers bookstore and cafe, and Anderson House, a grand Gilded Age mansion museum");
  St("Farragut North", 65, 13, " ");
      H("Downtown's office core along Connecticut Avenue and K Street, the corridor long synonymous with lobbyists. Farragut Square is the area's lunchtime living room.");
      S("Farragut Square, famous for its lunchtime food trucks|St. Matthew's Cathedral, site of President Kennedy's funeral Mass|The White House and Lafayette Square, two blocks south|The historic Mayflower ");
      S("Hotel on Connecticut Avenue");
  St("Metro Center", 67, 15, " ");
      H("The center of the system and of downtown: Red, Orange, Silver and Blue meet here beneath a dense district of offices, hotels, theaters and shops between the White House and Chinatown.");
      S("Ford's Theatre, where Lincoln was shot, with its museum and the Petersen House across the street|CityCenterDC's upscale shops, restaurants and fountain-filled alleys|The Martin Luther King Jr. ");
      S("Memorial Library, renovated, with a rooftop garden|The National Theatre and the Warner Theatre on Pennsylvania Avenue and 13th Street");
  St("Gallery Place-Chinatown", 71, 15, " ");
      H("Penn Quarter and Chinatown: a busy entertainment district around a sports arena, marked by the ornate Friendship Archway over H Street. Red, Green and Yellow meet below.");
      S("Capital One Arena, home of the Capitals and the Wizards|The Smithsonian American Art Museum and National Portrait Gallery, sharing the old Patent Office and its glass-roofed Kogod Courtyard|The ");
      S("Friendship Archway and Chinatown's restaurants|Theaters including the Shakespeare Theatre Company's Harman Hall");
  St("Judiciary Square", 74, 15, " ");
      H("The District's legal quarter of courthouses and government buildings, with some of the city's most striking civic architecture.");
      S("The National Building Museum, in the vast Great Hall of the 1887 Pension Building|The National Law Enforcement Officers Memorial and its museum|The Capital Jewish Museum, including a restored 1876 ");
      S("synagogue|The old District of Columbia City Hall, now a courthouse");
  St("Union Station", 77, 15, "R");
      H("Washington's grand 1907 Beaux-Arts railway terminal, gateway for Amtrak, MARC and VRE trains, sits a few blocks north of the Capitol. Capitol Hill's rowhouse blocks begin just east.");
      S("The station's vaulted main hall and the Columbus Fountain out front|The Smithsonian's National Postal Museum, free, next door|The U.S. Capitol, Supreme Court and Library of Congress, about a 10 ");
      S("minute walk|The DC Streetcar along H Street NE to bars and restaurants");
  St("NoMa-Gallaudet U", 79, 13, " ");
      H("North of Massachusetts Avenue, a once-industrial rail corridor that turned into a forest of new apartment towers in two decades. Gallaudet University, for deaf and hard of hearing students, anchors ");
      H("the east side.");
      S("Gallaudet University, whose campus pioneered architecture designed around deaf ways of seeing and signing|Union Market, a food hall and market district with dozens of vendors|The Metropolitan Branch ");
      S("Trail, a bike path running north along the tracks|The NoMa underpass art installations and pocket parks");
  St("Rhode Island Ave-Brentwood", 81, 11, " ");
      H("An elevated station above a mix of rowhouse blocks, light industry and newer retail on Rhode Island Avenue in Northeast D.C.");
      S("The Metropolitan Branch Trail runs right past the station|Rhode Island Row's shops and the neighborhood's taquerias and carry-outs|The U.S. National Arboretum, 446 acres of gardens and the old ");
      S("Capitol columns, a short bus or bike ride east|Mount Rainier's arts scene just over the Maryland line");
  St("Brookland-CUA", 83, 9, " ");
      H("Nicknamed Little Rome for its many Catholic institutions, Brookland is a friendly neighborhood of bungalows, Catholic University and an arts walk beside the tracks.");
      S("The Basilica of the National Shrine of the Immaculate Conception, the largest Catholic church in North America|The Franciscan Monastery, with gardens and replicas of Holy Land shrines|The Monroe ");
      S("Street Market Arts Walk of studios and shops|Dance Place, a long-running contemporary dance venue");
  St("Fort Totten", 85, 7, " ");
      H("A transfer point between the Red and Green lines amid wooded parkland in upper Northeast. The park preserves a Civil War fort that was part of the ring defending Washington.");
      S("Fort Totten Park, with earthworks from the Civil War defenses of Washington|The Fort Circle Parks trail system linking the old forts|Quiet residential Lamond-Riggs and Queens Chapel");
  St("Takoma", 85, 5, " ");
      H("Takoma, D.C. and its twin Takoma Park, Maryland, form a bohemian, Victorian-era streetcar suburb with a famously progressive streak, a nuclear-free-zone sign and plenty of front-porch charm.");
      S("Old Takoma's shops, cafes and the Sunday Takoma Park Farmers Market|Victorian and Craftsman houses on tree-lined streets|The Sligo Creek Trail for walking and biking|The Takoma Park Folk Festival and ");
      S("other community events");
  St("Silver Spring", 85, 3, " ");
      H("Downtown Silver Spring is a lively, diverse urban center just over the Maryland line, with a strong arts and food scene, a big transit center and a famous restored movie palace.");
      S("The AFI Silver Theatre, a restored 1938 Art Deco cinema run by the American Film Institute|The Fillmore Silver Spring concert hall|Ellsworth Drive's restaurants and Veterans Plaza, with an ice rink ");
      S("in winter|Ethiopian, Salvadoran and Vietnamese food all over downtown");
  St("Forest Glen", 87, 1, " ");
      H("A quiet residential stop and the deepest station in the system, about 200 feet down, reached only by high-speed elevators. Wooded Sligo Creek parkland winds nearby.");
      S("The National Park Seminary historic district: a former girls' school with a pagoda, a Dutch windmill and a castle, now homes|Sligo Creek Park's trails and playgrounds|A glimpse of the gleaming ");
      S("Washington D.C. Temple's spires rising above the Beltway nearby|The ride itself: the elevators drop like a mine shaft");
  St("Wheaton", 90, 1, " ");
      H("A diverse, working suburb with one of the region's best concentrations of family-run restaurants. Its station has the longest single escalators in the Western Hemisphere, about 230 feet.");
      S("Riding the record-setting escalators|Brookside Gardens, 50 free acres of formal gardens, a conservatory and a summer butterfly show|Wheaton Regional Park's miniature train, carousel and ice ");
      S("rink|Peruvian chicken, Thai, Salvadoran, Korean and Ethiopian food in downtown Wheaton");
  St("Glenmont", 93, 1, "R");
      H("The Red Line's northeastern terminus, in a suburban area of garden apartments and split-levels at the crossing of Georgia Avenue and Randolph Road.");
      S("Brookside Gardens and Wheaton Regional Park, a short ride away|The Matthew Henson Trail, named for the Arctic explorer, for a woodland walk or bike ride|Glenmont's strip-mall Latin American and Asian ");
      S("eateries");
END LoadRed;

PROCEDURE LoadOrange;
BEGIN
  St("Vienna/Fairfax-GMU", 22, 15, "L");
      H("The Orange Line's western terminus sits in the median of I-66 between the Town of Vienna and Fairfax, with huge commuter garages and shuttles to George Mason University.");
      S("The Town of Vienna's Church Street, with the historic Freeman Store and the Washington and Old Dominion Trail|George Mason University's Fairfax campus and the EagleBank Arena, by shuttle bus|Historic ");
      S("downtown Fairfax City, with its 1800 courthouse|Nottoway Park's trails and playing fields");
  St("Dunn Loring-Merrifield", 26, 15, " ");
      H("Once a crossroads of warehouses and car dealers, Merrifield now has a dense new town center beside the station.");
      S("The Mosaic District: an arthouse cinema, restaurants, shops and outdoor movie nights|Merrifield Garden Center, a sprawling nursery popular with local gardeners|Gatehouse Plaza and the Fairfax County ");
      S("Government cluster nearby");
  St("West Falls Church", 30, 15, " ");
      H("A commuter station in the I-66 median beside the City of Falls Church's western edge and a Virginia Tech graduate campus, now being redeveloped as the West Falls neighborhood.");
      S("The Wolf Trap Express shuttle in summer to Wolf Trap, the only national park devoted to the performing arts|Falls Church's small-town Broad Street shops and restaurants|The Washington and Old ");
      S("Dominion Trail nearby");
  St("East Falls Church", 34, 15, "B");
      H("Where the Silver Line peels off from the Orange, on the border of Arlington and the Little City of Falls Church. Two of the region's best bike trails meet a few blocks away.");
      S("The Washington and Old Dominion Trail and Custis Trail junction for long bike rides|The Eden Center, the largest Vietnamese shopping center on the East Coast, a short bus ride away|The State Theatre ");
      S("in Falls Church, a 1930s cinema turned concert hall|Arlington's leafy Westover village");
  St("Ballston-MU", 38, 15, " ");
      H("Ballston is the western anchor of Arlington's Rosslyn-Ballston corridor, a planned string of dense urban villages built around Metro. Offices, apartments and Marymount University share the area.");
      S("MedStar Capitals Iceplex atop Ballston Quarter, where the Capitals practice and fans can often watch for free|Ballston Quarter's food hall and restaurants|Bluemont Park and the Four Mile Run ");
      S("Trail|Marymount University's Ballston campus");
  St("Virginia Square-GMU", 41, 15, " ");
      H("A calmer stretch of the Rosslyn-Ballston corridor, home to George Mason University's Arlington campus and law school.");
      S("Arlington Central Library, with events, gardens and a farmers market nearby|The Arlington Arts Center's galleries in a 1910 schoolhouse|Quincy Park and the Arlington Mill neighborhood|Theatre ");
      S("performances at Theatre on the Run and local venues");
  St("Clarendon", 44, 15, " ");
      H("Arlington's nightlife and dining hub, once a Vietnamese-American commercial district known as Little Saigon, now a lively mix of bars, restaurants, live music and brick storefronts.");
      S("Clarendon's bar and rooftop scene, busy every weekend|Market Common Clarendon's shops and restaurants|Live music at local clubs and the annual Clarendon Day street festival|Vietnamese restaurants ");
      S("that remain from Little Saigon's heyday");
  St("Court House", 47, 15, " ");
      H("Arlington's civic center, with the county government, courts and a growing cluster of offices and apartments above a Saturday farmers market.");
      S("The Arlington Farmers Market, Saturdays at Courthouse|The Marine Corps War Memorial (Iwo Jima) and the Netherlands Carillon, a walk east|Irish pubs and casual restaurants around Wilson and Clarendon ");
      S("Boulevards|Fort Myer's ceremonial units nearby");
  St("Rosslyn", 51, 15, "A");
      H("A cluster of glass towers across the Key Bridge from Georgetown, with some of the best views of D.C. and quick access to riverside trails and parks.");
      S("The Marine Corps War Memorial (Iwo Jima) and the Netherlands Carillon's bell tower|Theodore Roosevelt Island, a wooded island memorial reached by footbridge|The Mount Vernon Trail along the Potomac|A ");
      S("walk across the Key Bridge to Georgetown's shops, canal and waterfront");
  St("Foggy Bottom-GWU", 55, 15, " ");
      H("Named for the marshy lowland that once lay here, Foggy Bottom is home to George Washington University, the State Department and the Watergate complex, with the Kennedy Center on the river.");
      S("The Kennedy Center, with a free performance every evening at 6 p.m. on the Millennium Stage and a free shuttle from the station|The Watergate complex|The Lincoln Memorial and Reflecting Pool, about a ");
      S("15 minute walk|Georgetown and its waterfront park, a walk west on Pennsylvania Avenue");
  St("Farragut West", 59, 15, " ");
      H("Downtown's western office district along 17th and 18th Streets, a few blocks from the White House and Lafayette Square.");
      S("The White House and Lafayette Square|The Renwick Gallery, the Smithsonian's museum of contemporary craft and decorative art|Decatur House, an 1818 townhouse on Lafayette Square|DAR Constitution Hall ");
      S("and the Art Museum of the Americas, a short walk south");
  St("McPherson Square", 63, 15, " ");
      H("Downtown offices around two classic squares, McPherson and Franklin, close to the White House and the Treasury.");
      S("Planet Word, a free museum of language in the historic Franklin School|Franklin Park, newly renovated, with a playground and cafe|The Treasury Building and the White House, a short walk south|Old ");
      S("Ebbitt Grill, a Washington institution since 1856");
  St("Federal Triangle", 67, 17, " ");
      H("A wedge of monumental Beaux-Arts federal buildings between Pennsylvania and Constitution Avenues, built in the 1930s, with the museums of the Mall just south.");
      S("The National Museum of American History, with the Star-Spangled Banner and Julia Child's kitchen|The National Museum of African American History and Culture|The Old Post Office clock tower and ");
      S("Freedom Plaza|The historic Willard Hotel and the Ronald Reagan Building");
  St("Smithsonian", 67, 19, "L");
      H("The station opens right onto the National Mall, between the Capitol and the Washington Monument. Most of the Smithsonian's great free museums lie within a short walk.");
      S("The National Museum of Natural History, with the Hope Diamond and the dinosaur hall|The National Air and Space Museum and the National Museum of Asian Art|The Washington Monument, the Hirshhorn ");
      S("sculpture garden and the Smithsonian Castle|The U.S. Holocaust Memorial Museum and the Bureau of Engraving and Printing, a short walk south");
  St("L'Enfant Plaza", 71, 21, " ");
      H("A 1960s office complex above the system's busiest transfer point: Orange, Silver, Blue, Yellow and Green all stop here. The Mall is just north and the Wharf is a short walk south.");
      S("The International Spy Museum, with gadgets, disguises and a spy mission to play|The National Air and Space Museum and the National Museum of the American Indian|A walk down the 10th Street promenade ");
      S("to the Wharf|The Hirshhorn Museum and its sculpture garden");
  St("Federal Center SW", 74, 21, " ");
      H("A district of federal office buildings at the foot of Capitol Hill, near the Botanic Garden and the western front of the Capitol.");
      S("The U.S. Botanic Garden's conservatory and the Bartholdi Fountain|The Capitol Reflecting Pool and the Ulysses S. Grant Memorial|The National Museum of the American Indian, with its excellent cafe|The ");
      S("House office buildings and Garfield Park");
  St("Capitol South", 77, 21, " ");
      H("The station for the Capitol, the House office buildings and the Library of Congress, at the edge of Capitol Hill's rowhouse neighborhood.");
      S("The U.S. Capitol Visitor Center and free Capitol tours|The Library of Congress's ornate Jefferson Building and Great Hall|The Supreme Court|The Folger Shakespeare Library, with the world's largest ");
      S("Shakespeare collection");
  St("Eastern Market", 80, 21, " ");
      H("The heart of residential Capitol Hill, a neighborhood of Victorian rowhouses, corner cafes and tree-lined streets around one of the city's oldest public markets.");
      S("Eastern Market's 1873 market hall, plus weekend flea markets and craft stalls|Barracks Row's restaurants along 8th Street SE|The Marine Barracks' Friday Evening Parade in summer (reserve ");
      S("ahead)|Lincoln Park and its Emancipation and Mary McLeod Bethune statues");
  St("Potomac Ave", 83, 21, " ");
      H("The eastern end of Capitol Hill, Hill East, a residential area of rowhouses and small businesses running down to the Anacostia River.");
      S("Historic Congressional Cemetery, resting place of J. Edgar Hoover and John Philip Sousa, and famous for its dog-walking members|The Anacostia Riverwalk Trail|Pennsylvania Avenue SE's neighborhood ");
      S("restaurants and bars");
  St("Stadium-Armory", 86, 21, " ");
      H("Beside the old RFK Stadium site on the Anacostia River, where the Orange line splits from the Blue and Silver. The stadium site is slated for a new Washington Commanders stadium.");
      S("The D.C. Armory, which hosts circuses, sporting events and festivals|Kingman and Heritage Islands Park, a nature area in the Anacostia River|The Fields at RFK, public sports fields and a ");
      S("playground|The Anacostia Riverwalk Trail");
  St("Minnesota Ave", 88, 19, " ");
      H("The first station east of the Anacostia River on the Orange line, serving the residential neighborhoods of Ward 7.");
      S("Anacostia Park and its outdoor roller skating pavilion|The Anacostia Riverwalk Trail along the river|Fort Mahan Park, one of the Civil War fort sites");
  St("Deanwood", 90, 17, " ");
      H("One of the city's oldest African-American neighborhoods, with wood-frame houses on rolling streets, built and settled by Black craftsmen in the early 1900s.");
      S("Kenilworth Park and Aquatic Gardens, ponds full of water lilies and lotus that bloom in July|Marvin Gaye Park along Watts Branch, the city's longest municipal park|The Nannie Helen Burroughs School ");
      S("historic site");
  St("Cheverly", 92, 15, " ");
      H("A small Prince George's County town of hilly, wooded streets laid out in the 1920s as a garden suburb.");
      S("Cheverly's tree-lined residential streets and Cheverly Nature Park|Bladensburg Waterfront Park on the Anacostia, with boat rentals and trails|The Anacostia Tributary Trail System");
  St("Landover", 94, 13, " ");
      H("A suburban commuter stop near U.S. Route 50 in Prince George's County, surrounded by garden apartments and office parks.");
      S("The Prince George's Sports and Learning Complex, with an aquatic center and fitness facilities|The Anacostia Tributary trails|Northwest Stadium, home of the Commanders, a short ride away");
  St("New Carrollton", 96, 11, "A");
      H("The Orange Line's eastern terminus is a major transit hub, where Amtrak, MARC and many buses meet. A Purple Line light rail station is under construction.");
      S("Amtrak and MARC trains to Baltimore and beyond|The future western end of the Purple Line light rail|Lake Artemesia and the Northeast Branch trails, a short drive away");
END LoadOrange;

PROCEDURE LoadSilver;
BEGIN
  St("Ashburn", 1, 9, "A");
      H("The Silver Line's western terminus is in Loudoun County, which holds one of the world's densest concentrations of data centers, plus fast-growing suburbs.");
      S("One Loudoun's shops, restaurants and outdoor events|Loudoun's wineries and breweries, a short drive west|The Washington and Old Dominion Trail's western stretch toward Leesburg");
  St("Loudoun Gateway", 4, 9, " ");
      H("A commuter stop in the Dulles Greenway median, at the northern edge of Washington Dulles International Airport.");
      S("Park and ride, then head west into Loudoun's countryside|Watching planes approach Dulles|The Broad Run stream valley trails");
  St("Washington Dulles International Airport", 7, 9, " ");
      H("The region's main international airport, with Eero Saarinen's swooping 1962 terminal, one of the great buildings of modern architecture.");
      S("Eero Saarinen's main terminal, inside and out|The Smithsonian's Steven F. Udvar-Hazy Center, with the Space Shuttle Discovery, the SR-71 Blackbird and the Enola Gay, a short bus ride away|The ");
      S("airport's mobile lounges, vehicles that have shuttled passengers since the 1960s");
  St("Innovation Center", 10, 9, " ");
      H("A high-tech office area on the Dulles Toll Road, marked by the Center for Innovative Technology's famous upside-down pyramid of a building.");
      S("The Center for Innovative Technology's inverted-pyramid building|The Udvar-Hazy Center, a short drive south|Herndon's town center and the Washington and Old Dominion Trail nearby");
  St("Herndon", 13, 9, " ");
      H("A small town with a historic railroad depot and a growing cluster of new apartments near the station. Herndon grew up along the old Washington and Old Dominion railroad.");
      S("Historic downtown Herndon and its depot museum on the Washington and Old Dominion Trail|The Herndon Festival each spring|Frying Pan Farm Park, a working 1950s-era farm with animals and wagon rides");
  St("Reston Town Center", 16, 9, " ");
      H("Reston is a famous 1960s planned community; its Town Center is a dense, walkable downtown of offices, apartments, shops and plazas.");
      S("Reston Town Center's fountain plaza, shops and restaurants, with a pavilion skating rink in winter|Reston's 55 miles of paths and its lakes|Summer concerts and festivals at the Town Center");
  St("Wiehle-Reston East", 19, 9, " ");
      H("The original Silver Line terminus, now a dense cluster of apartments and offices on Reston's eastern side.");
      S("Lake Anne Plaza, Reston's original 1960s village center on a lake, with a Saturday farmers market|The Washington and Old Dominion Trail, steps from the station|Wolf Trap National Park for the ");
      S("Performing Arts, a short drive");
  St("Spring Hill", 22, 9, " ");
      H("The western end of Tysons, a former office-park district being remade into a walkable downtown.");
      S("Tysons West shops and restaurants|Wolf Trap National Park for the Performing Arts, a few miles away|Ashgrove Historic District and wooded stream-valley parks");
  St("Greensboro", 25, 9, " ");
      H("Central Tysons, with office towers and new mixed-use developments along Route 7.");
      S("The Boro, a newer neighborhood with restaurants and a cinema|Tysons Galleria's upscale shopping nearby|Scott's Run Nature Preserve, with a waterfall on the Potomac, a short drive");
  St("Tysons", 28, 9, " ");
      H("The commercial heart of Tysons, Virginia's largest office market, built around a pair of giant malls.");
      S("Tysons Corner Center, one of the largest malls on the East Coast, linked to the station by a walkway|The Plaza at Tysons Corner Center's outdoor events|Tysons Galleria across Route 123");
  St("McLean", 31, 12, " ");
      H("The eastern edge of Tysons, beside Capital One's headquarters tower. The leafy, affluent suburb of McLean spreads to the east.");
      S("Capital One Hall, a performing arts center with Broadway tours and concerts|The Perch, a rooftop park with gardens and food stalls|Scott's Run Nature Preserve and Great Falls Park a short drive away");

  St("Benning Road", 89, 23, " ");
      H("A Ward 7 neighborhood east of the Anacostia River, with rowhouses, apartments and wooded parkland.");
      S("Fort Dupont Park, one of the city's largest parks, with trails and an ice rink|Fort Chaplin Park, another Civil War fort site|The Watts Branch and Marvin Gaye Park nearby");
  St("Capitol Heights", 92, 23, " ");
      H("A small Prince George's County town right on the District line, with a quiet residential character.");
      S("Marvin Gaye Park and the Watts Branch trail, just to the west|Fort Dupont Park's trails|Local soul food and carry-out spots");
  St("Addison Road-Seat Pleasant", 95, 23, " ");
      H("Seat Pleasant is a small Prince George's County city, famous as the hometown of NBA star Kevin Durant.");
      S("Walker Mill Regional Park, with trails and a creek|The Kevin Durant-funded courts and community spaces in Seat Pleasant|The Central Avenue corridor");
  St("Morgan Boulevard", 98, 23, " ");
      H("A suburban station best known as the Metro stop for the Washington Commanders' stadium, about a mile's walk away.");
      S("Northwest Stadium, home of the Commanders, for football and stadium concerts|Game-day crowds and tailgates|The newer Morgan Boulevard town center development");
  St("Downtown Largo", 101, 23, "B");
      H("The Blue and Silver lines' eastern terminus, in a fast-growing area of Prince George's County with a new hospital and town center.");
      S("Watkins Regional Park, with a miniature train, carousel, nature center and old Maryland farm|Prince George's Community College|The University of Maryland Capital Region Medical Center");
END LoadSilver;

PROCEDURE LoadBlue;
BEGIN
  St("Franconia-Springfield", 38, 31, "L");
      H("The Blue Line's southern terminus is a hub for VRE and Amtrak trains, surrounded by Springfield's suburbs and shopping.");
      S("Springfield Town Center mall|Lake Accotink Park, with a trail around the lake|VRE and Amtrak trains south toward Fredericksburg");
  St("Van Dorn Street", 42, 31, " ");
      H("A commuter stop on the western side of Alexandria, near the Cameron Station neighborhood and the Landmark area.");
      S("Ben Brenman Park and the Cameron Station neighborhood|The Holmes Run Trail|Alexandria's West End restaurants");
  St("King St-Old Town", 44, 29, "A");
      H("Old Town Alexandria, a beautifully preserved 18th-century port town, begins at the station and runs down King Street to the Potomac waterfront.");
      S("The free King Street Trolley down to the waterfront|The George Washington Masonic National Memorial, with an observation deck|The Torpedo Factory Art Center, a converted munitions plant full of ");
      S("artists' studios|Gadsby's Tavern, Christ Church and the water taxi to National Harbor");
  St("Braddock Road", 47, 29, " ");
      H("The northern side of Old Town Alexandria, with rowhouses, Parker-Gray's historic African-American neighborhood and new apartments.");
      S("The Alexandria Black History Museum|Old Town North's arts district and restaurants|The Freedom House Museum, a former slave-trading office, now a museum|The Mount Vernon Trail along the river");
  St("Potomac Yard", 50, 29, " ");
      H("The system's newest infill station, opened in 2023 on a former railroad yard that is now a new neighborhood.");
      S("The Del Ray neighborhood's Mount Vernon Avenue shops, cafes and Art on the Avenue festival|Potomac Yard Park and its trail|Virginia Tech's new Innovation Campus");
  St("Ronald Reagan Washington National Airport", 53, 29, " ");
      H("The airport closest to downtown, on the Potomac. Cesar Pelli's terminal frames a famous view of the Washington Monument and the Capitol.");
      S("Gravelly Point Park, where planes roar just overhead as they land, a short ride or walk up the Mount Vernon Trail|The Mount Vernon Trail along the river|Terminal 2's art collection and its views of ");
      S("the city");
  St("Crystal City", 55, 27, " ");
      H("A neighborhood of 1960s and 1970s high-rises, part of the area now called National Landing and the site of Amazon's second headquarters.");
      S("The Crystal City Underground's shops and restaurants|The Crystal City Water Park|The Mount Vernon Trail and Long Bridge Park nearby");
  St("Pentagon City", 55, 25, " ");
      H("Shopping, high-rise apartments and Amazon's HQ2 offices on Arlington's southern side.");
      S("The Fashion Centre at Pentagon City mall|Amazon's Metropolitan Park and its public green|Long Bridge Park, with an aquatic center and views of the monuments");
  St("Pentagon", 55, 23, "L");
      H("The station sits right at the Pentagon, headquarters of the Department of Defense and the world's largest office building.");
      S("The Pentagon Memorial, honoring the 184 people killed on September 11|Tours of the Pentagon, by reservation in advance|The Air Force Memorial's soaring spires on the hill above");
  St("Arlington Cemetery", 51, 19, " ");
      H("The station at the gates of Arlington National Cemetery, the nation's most famous military burial ground.");
      S("The Changing of the Guard at the Tomb of the Unknown Soldier|President Kennedy's grave and eternal flame|Arlington House, the Robert E. Lee Memorial|A walk across Memorial Bridge to the Lincoln ");
      S("Memorial");
END LoadBlue;

PROCEDURE LoadYellow;
BEGIN
  St("Huntington", 38, 29, "L");
      H("The Yellow Line's southern terminus, in a suburban part of Fairfax County just south of Alexandria.");
      S("Huntley Meadows Park, with a wetland boardwalk and excellent birding|George Washington's Mount Vernon estate, reachable by Fairfax Connector bus|Huntington's riverside trails");
  St("Eisenhower Avenue", 41, 29, " ");
      H("A district of federal agencies and new apartments, including the U.S. Patent and Trademark Office and the National Science Foundation.");
      S("The National Inventors Hall of Fame Museum, free, in the Patent Office|Cameron Run Regional Park, with a wave pool and mini golf|The Carlyle neighborhood's restaurants");
  St("Archives-Navy Memorial-Penn Quarter", 71, 18, " ");
      H("Penn Quarter, a lively district of restaurants and theaters, faces the National Archives across Pennsylvania Avenue, with the Mall just south.");
      S("The National Archives Rotunda, with the Declaration of Independence, the Constitution and the Bill of Rights|The U.S. Navy Memorial and its granite world map plaza|The National Gallery of Art and its ");
      S("Sculpture Garden, with ice skating in winter|Penn Quarter's restaurants and the Shakespeare Theatre's Lansburgh");
  St("Mt Vernon Sq/7th St-Convention Center", 71, 13, " ");
      H("Beside the Walter E. Washington Convention Center, in a booming area of new hotels and restaurants on the edge of Shaw.");
      S("The historic Carnegie Library, now an Apple store and DC History Center|Blagden Alley's restaurants and cafes in old carriage houses|The Walter E. Washington Convention Center's events");
END LoadYellow;

PROCEDURE LoadGreen;
BEGIN
  St("Branch Ave", 89, 29, "R");
      H("The Green Line's southeastern terminus, in a suburban part of Prince George's County near Joint Base Andrews.");
      S("Joint Base Andrews, home of Air Force One, nearby|The Henson Creek Trail|Suitland Parkway, a scenic road into D.C.");
  St("Suitland", 86, 29, " ");
      H("A cluster of federal buildings, including the U.S. Census Bureau headquarters, with residential neighborhoods around them.");
      S("The Suitland Federal Center, home of the Census Bureau|Local parks along Suitland Parkway|The Smithsonian's Museum Support Center nearby, where much of its collection lives");
  St("Naylor Road", 83, 29, " ");
      H("A suburban stop in Hillcrest Heights and Temple Hills, just over the District line.");
      S("Hillcrest Heights' neighborhood shops|Oxon Run Park's trails|Local carry-outs and soul food spots");
  St("Southern Avenue", 80, 29, " ");
      H("A station right on Southern Avenue, the District-Maryland line, serving Hillcrest Heights and Washington Highlands.");
      S("Oxon Run Park, with a long stream-valley trail|Neighborhood parks and recreation centers|Views over the city from the high ground");
  St("Congress Heights", 77, 29, " ");
      H("A Ward 8 neighborhood on the bluffs east of the Anacostia River, now home to a new arena on the historic St. Elizabeths campus.");
      S("The Entertainment and Sports Arena, home of the WNBA's Washington Mystics|The historic St. Elizabeths Hospital campus|Views of the city from the bluffs");
  St("Anacostia", 75, 27, " ");
      H("A historic neighborhood east of the river, home to Frederick Douglass's last house and a growing arts scene.");
      S("The Frederick Douglass National Historic Site at Cedar Hill|The Smithsonian's Anacostia Community Museum|The Big Chair, a 19-foot chair landmark on MLK Jr. Avenue|The Anacostia Arts Center's galleries");
  St("Navy Yard-Ballpark", 73, 25, " ");
      H("A fast-growing riverfront district of new apartments, restaurants and stadiums around the historic Washington Navy Yard.");
      S("Nationals Park, home of the Washington Nationals|Audi Field, home of D.C. United soccer|The Yards Park's boardwalk and fountain|The National Museum of the U.S. Navy inside the Navy Yard (ID required)");
  St("Waterfront", 71, 23, " ");
      H("Southwest D.C.'s riverfront, transformed by the Wharf, a mile-long district of restaurants, music venues and docks on the Washington Channel.");
      S("The Wharf's restaurants, piers and the Anthem concert hall|The Municipal Fish Market, the oldest continuously operating open-air fish market in the U.S.|Arena Stage, a pioneering regional theater|The ");
      S("Titanic Memorial and the riverside trail");
  St("Shaw-Howard U", 71, 11, " ");
      H("Shaw is one of D.C.'s historic Black neighborhoods, once called Black Broadway for its theaters and clubs; Howard University's campus is just north.");
      S("The Howard Theatre, a historic venue where Ella Fitzgerald and Duke Ellington played|Howard University's campus|Shaw's restaurants and bars along 7th and 9th Streets");
  St("U Street/African-Amer Civil War Memorial/Cardozo", 71, 9, " ");
      H("U Street, the heart of historic Black Washington, is now one of the city's liveliest nightlife and music districts.");
      S("Ben's Chili Bowl, a U Street institution since 1958|The Lincoln Theatre and the 9:30 Club for live music|The African American Civil War Memorial and Museum|Meridian Hill Park, with its cascading ");
      S("fountain and Sunday drum circle");
  St("Columbia Heights", 73, 7, " ");
      H("A dense, diverse neighborhood with a strong Latin American presence, big-box stores and historic rowhouses.");
      S("GALA Hispanic Theatre in the restored Tivoli Theatre|The Columbia Heights Civic Plaza and its fountain|Salvadoran, Ethiopian and Vietnamese food|Meridian Hill Park, a short walk south");
  St("Georgia Ave-Petworth", 78, 7, " ");
      H("Petworth is a neighborhood of early 1900s rowhouses with front porches and a lively strip of restaurants on Upshur Street.");
      S("President Lincoln's Cottage, Lincoln's summer retreat where he worked on the Emancipation Proclamation|Upshur Street's restaurants and cafes|The Petworth Neighborhood Library");
  St("West Hyattsville", 88, 7, " ");
      H("A Prince George's County stop in a wooded stream valley, with apartments and new townhouses.");
      S("The Northwest Branch Trail, part of the Anacostia Tributary trails|Hyattsville's Route 1 arts district, a short ride east|Local Latin American restaurants");
  St("Hyattsville Crossing", 91, 7, " ");
      H("Formerly Prince George's Plaza, renamed in 2022, a growing area of shops and apartments around a regional mall.");
      S("The Mall at Prince Georges|University Town Center's shops and cinema|The Hyattsville Arts District on Route 1");
  St("College Park-University of Maryland", 94, 7, " ");
      H("The station for the University of Maryland's flagship campus and the city of College Park.");
      S("The University of Maryland campus and its Clarice Smith Performing Arts Center|The College Park Aviation Museum at the world's oldest continuously operating airport|Lake Artemesia and its trails");
  St("Greenbelt", 97, 7, "R");
      H("The Green Line's northern terminus, near the historic New Deal planned town of Greenbelt.");
      S("Historic Greenbelt, a New Deal planned town with the Art Deco Old Greenbelt Theatre and a museum|The NASA Goddard Space Flight Center Visitor Center|Greenbelt Park, an NPS park with camping|MARC ");
      S("Camden Line trains to Baltimore");
END LoadGreen;

PROCEDURE LoadLines;
BEGIN
  Line(0, "Red", 196);
      Stops("Shady Grove;Rockville;Twinbrook;North Bethesda;Grosvenor-Strathmore;Medical Center;Bethesda;Friendship Heights;Tenleytown-AU;Van Ness-UDC;Cleveland Park;Woodley Park-Zoo/Adams Morgan;Dupont Circle;");
      Stops("Farragut North;Metro Center;Gallery Place-Chinatown;Judiciary Square;Union Station;NoMa-Gallaudet U;Rhode Island Ave-Brentwood;Brookland-CUA;Fort Totten;Takoma;Silver Spring;Forest Glen;Wheaton;");
      Stops("Glenmont");
      ParseLine(0);
  Line(1, "Orange", 208);
      Stops("Vienna/Fairfax-GMU;Dunn Loring-Merrifield;West Falls Church;East Falls Church;Ballston-MU;Virginia Square-GMU;Clarendon;Court House;Rosslyn;Foggy Bottom-GWU;Farragut West;McPherson Square;");
      Stops("Metro Center;Federal Triangle;Smithsonian;L'Enfant Plaza;Federal Center SW;Capitol South;Eastern Market;Potomac Ave;Stadium-Armory;Minnesota Ave;Deanwood;Cheverly;Landover;New Carrollton");
      ParseLine(1);
  Line(2, "Silver", 250);
      Stops("Ashburn;Loudoun Gateway;Washington Dulles International Airport;Innovation Center;Herndon;Reston Town Center;Wiehle-Reston East;Spring Hill;Greensboro;Tysons;McLean;East Falls Church;Ballston-MU;");
      Stops("Virginia Square-GMU;Clarendon;Court House;Rosslyn;Foggy Bottom-GWU;Farragut West;McPherson Square;Metro Center;Federal Triangle;Smithsonian;L'Enfant Plaza;Federal Center SW;Capitol South;");
      Stops("Eastern Market;Potomac Ave;Stadium-Armory;Benning Road;Capitol Heights;Addison Road-Seat Pleasant;Morgan Boulevard;Downtown Largo");
      ParseLine(2);
  Line(3, "Blue", 33);
      Stops("Franconia-Springfield;Van Dorn Street;King St-Old Town;Braddock Road;Potomac Yard;Ronald Reagan Washington National Airport;Crystal City;Pentagon City;Pentagon;Arlington Cemetery;Rosslyn;");
      Stops("Foggy Bottom-GWU;Farragut West;McPherson Square;Metro Center;Federal Triangle;Smithsonian;L'Enfant Plaza;Federal Center SW;Capitol South;Eastern Market;Potomac Ave;Stadium-Armory;Benning Road;");
      Stops("Capitol Heights;Addison Road-Seat Pleasant;Morgan Boulevard;Downtown Largo");
      ParseLine(3);
  Line(4, "Yellow", 226);
      Stops("Huntington;Eisenhower Avenue;King St-Old Town;Braddock Road;Potomac Yard;Ronald Reagan Washington National Airport;Crystal City;Pentagon City;Pentagon;^L'Enfant Plaza;");
      Stops("Archives-Navy Memorial-Penn Quarter;Gallery Place-Chinatown;Mt Vernon Sq/7th St-Convention Center");
      ParseLine(4);
  Line(5, "Green", 40);
      Stops("Branch Ave;Suitland;Naylor Road;Southern Avenue;Congress Heights;Anacostia;Navy Yard-Ballpark;Waterfront;L'Enfant Plaza;Archives-Navy Memorial-Penn Quarter;Gallery Place-Chinatown;");
      Stops("Mt Vernon Sq/7th St-Convention Center;Shaw-Howard U;U Street/African-Amer Civil War Memorial/Cardozo;Columbia Heights;Georgia Ave-Petworth;Fort Totten;West Hyattsville;Hyattsville Crossing;");
      Stops("College Park-University of Maryland;Greenbelt");
      ParseLine(5)
END LoadLines;

(* ════════════════════════════════════════════════════════════════════
   Map rendering
   ════════════════════════════════════════════════════════════════════ *)

(* PickColor -- shared track is striped: successive cells cycle through
   the lines that use it, so trunk sections show every colour. *)
PROCEDURE PickColor(s: SET; pos: INTEGER): INTEGER;
VAR l, cnt, k, c: INTEGER;
BEGIN
  cnt := 0;
  FOR l := 0 TO NLines - 1 DO IF l IN s THEN INC(cnt) END END;
  c := CText;
  IF cnt > 0 THEN
    k := pos MOD cnt;
    FOR l := 0 TO NLines - 1 DO
      IF l IN s THEN
        IF k = 0 THEN c := lineColor[l] END;
        DEC(k)
      END
    END
  END;
  RETURN c
END PickColor;

PROCEDURE FirstLine(i: INTEGER): INTEGER;
VAR l, r: INTEGER;
BEGIN
  r := -1;
  FOR l := NLines - 1 TO 0 BY -1 DO IF l IN st[i].lines THEN r := l END END;
  RETURN r
END FirstLine;

PROCEDURE DrawLabel(i: INTEGER; side: CHAR; fg, bg: INTEGER; skip: BOOLEAN);
VAR lx, ly, n, k, mx: INTEGER;
    s: ARRAY 72 OF CHAR;
BEGIN
  s := "";
  IF ~skip THEN Cat(s, " ") END;
  Cat(s, st[i].name);
  IF ~skip THEN Cat(s, " ") END;
  n := StrLen(s);
  ly := st[i].y;  lx := st[i].x - n DIV 2;
  IF side = "L" THEN lx := st[i].x - n - 1
  ELSIF side = "R" THEN lx := st[i].x + 2
  ELSIF side = "A" THEN ly := st[i].y - 1
  ELSE ly := st[i].y + 1
  END;
  IF lx + n - 1 > MapW THEN lx := MapW - n + 1 END;
  IF lx < 1 THEN lx := 1 END;
  IF (ly >= 1) & (ly <= MapH) THEN
    FOR k := 0 TO n - 1 DO
      mx := lx + k;
      IF (mx <= MapW) & (~skip OR ((track[ly][mx] = {}) & (stAt[ly][mx] < 0))) THEN
        TUI.PutCell(ox + mx - 1, oy + ly - 1, s[k], fg, bg)
      END
    END
  END
END DrawLabel;

PROCEDURE DrawLegend;
VAR bx, by, l: INTEGER;
    s: ARRAY 24 OF CHAR;
BEGIN
  bx := ox + 1;  by := oy + 17;
  TUI.DrawBox(bx, by, 22, 9, CDim, CBg);
  TUI.PutStr(bx + 2, by, " LINES ", CHead, CBg);
  FOR l := 0 TO NLines - 1 DO
    TUI.PutStr(bx + 2, by + 1 + l, "━━━", lineColor[l], CBg);
    s := "";  Cat(s, lineName[l]);  Cat(s, " Line");
    TUI.PutStr(bx + 6, by + 1 + l, s, CText, CBg)
  END;
  TUI.PutStr(bx + 3, by + 7, GTransfer, CWhite, CBg);
  TUI.PutStr(bx + 6, by + 7, "transfer", CDim, CBg)
END DrawLegend;

PROCEDURE DrawMap;
VAR x, y, i, c, g: INTEGER;
    side: CHAR;
BEGIN
  TUI.PutStr(ox + 1, oy + 2, "WASHINGTON METRORAIL", CWhite, CBg);
  TUI.PutStr(ox + 1, oy + 3, "explore D.C. by train", CDim, CBg);
  DrawLegend;

  FOR y := 1 TO MapH DO
    FOR x := 1 TO MapW DO
      IF (stAt[y][x] < 0) & (track[y][x] # {}) THEN
        g := glyph[y][x];
        IF g = 2 THEN c := PickColor(track[y][x], y) ELSE c := PickColor(track[y][x], x) END;
        IF g = 1 THEN TUI.PutStr(ox + x - 1, oy + y - 1, GH, c, CBg)
        ELSIF g = 2 THEN TUI.PutStr(ox + x - 1, oy + y - 1, GV, c, CBg)
        ELSIF g = 3 THEN TUI.PutStr(ox + x - 1, oy + y - 1, GDn, c, CBg)
        ELSE TUI.PutStr(ox + x - 1, oy + y - 1, GUp, c, CBg)
        END
      END
    END
  END;

  FOR i := 0 TO nSt - 1 DO
    IF st[i].side # " " THEN DrawLabel(i, st[i].side, CDim, CBg, TRUE) END
  END;

  FOR i := 0 TO nSt - 1 DO
    IF i = sel THEN
      TUI.PutStr(ox + st[i].x - 1, oy + st[i].y - 1, GTransfer, 16, CHi)
    ELSIF IsTransfer(i) THEN
      TUI.PutStr(ox + st[i].x - 1, oy + st[i].y - 1, GTransfer, CWhite, CBg)
    ELSE
      TUI.PutStr(ox + st[i].x - 1, oy + st[i].y - 1, GStation, CWhite, CBg)
    END
  END;

  side := st[sel].side;
  IF side = " " THEN
    IF st[sel].y > 1 THEN side := "A" ELSE side := "B" END
  END;
  DrawLabel(sel, side, 16, CHi, FALSE)
END DrawMap;

PROCEDURE DrawStatus;
VAR x, y, l, i: INTEGER;
    teaser: ARRAY 400 OF CHAR;
    done: BOOLEAN;
BEGIN
  y := oy + MapH + 1;
  TUI.PutStr(ox, y, GTransfer, CHi, CBg);
  TUI.PutStr(ox + 2, y, st[sel].name, CWhite, CBg);
  x := ox + 2 + Cells(st[sel].name) + 3;
  FOR l := 0 TO NLines - 1 DO
    IF l IN st[sel].lines THEN
      TUI.PutStr(x, y, "■", lineColor[l], CBg);
      TUI.PutStr(x + 2, y, lineName[l], CText, CBg);
      x := x + Cells(lineName[l]) + 4
    END
  END;

  (* the first sentence of the neighborhood description *)
  teaser := "";  i := 0;  done := FALSE;
  WHILE ~done & (st[sel].hood[i] # 0X) & (i < LEN(teaser) - 1) DO
    CatCh(teaser, st[sel].hood[i]);
    IF (st[sel].hood[i] = ".") & (st[sel].hood[i + 1] = " ") & (i > 20) THEN done := TRUE END;
    INC(i)
  END;
  IF Cells(teaser) > MapW - 2 THEN
    PutClip(ox + 2, y + 1, teaser, MapW - 3, CDim, CBg);
    TUI.PutStr(ox + MapW - 1, y + 1, "…", CDim, CBg)
  ELSE
    PutClip(ox + 2, y + 1, teaser, MapW - 2, CDim, CBg)
  END
END DrawStatus;

PROCEDURE DrawChrome;
VAR help: ARRAY 120 OF CHAR;
BEGIN
  TUI.FillRect(1, 1, TUI.Cols, 1, " ", CWhite, CTitleBg);
  TUI.PutStr(2, 1, " M ", CWhite, CLogo);
  TUI.PutStr(6, 1, "METRO EXPLORER", CWhite, CTitleBg);
  TUI.PutStr(21, 1, "· Washington, D.C. by Metrorail", CText, CTitleBg);
  TUI.PutStr(TUI.Cols - 23, 1, "98 stations · 6 lines", CText, CTitleBg);
  IF mode = 0 THEN
    help := "←↑↓→ move   Enter or click: explore station   R random station   Q quit"
  ELSE
    help := "←/→ ride the line   ↑/↓ switch line   PgUp/PgDn scroll   R random   Esc back to map"
  END;
  PutClip((TUI.Cols - Cells(help)) DIV 2 + 1, TUI.Rows, help, TUI.Cols, CDim, CBg)
END DrawChrome;

(* ════════════════════════════════════════════════════════════════════
   Station card
   ════════════════════════════════════════════════════════════════════ *)

PROCEDURE AddRow(s: ARRAY OF CHAR; fg, chip: INTEGER; hi: BOOLEAN);
BEGIN
  IF nRows < MaxRows THEN
    rows[nRows].txt := "";  Cat(rows[nRows].txt, s);
    rows[nRows].fg := fg;  rows[nRows].chip := chip;  rows[nRows].hi := hi;
    INC(nRows)
  END
END AddRow;

(* Wrap -- greedy word wrap of text into rows at most width cells wide. *)
PROCEDURE Wrap(text: ARRAY OF CHAR; width: INTEGER; first, cont: ARRAY OF CHAR; fg: INTEGER);
VAR line, word: ARRAY 200 OF CHAR;
    i, k, base: INTEGER;
BEGIN
  line := "";  Cat(line, first);  base := Cells(line);
  i := 0;
  WHILE text[i] # 0X DO
    WHILE text[i] = " " DO INC(i) END;
    k := 0;
    WHILE (text[i] # 0X) & (text[i] # " ") DO
      IF k < LEN(word) - 1 THEN word[k] := text[i];  INC(k) END;
      INC(i)
    END;
    word[k] := 0X;
    IF k > 0 THEN
      IF (Cells(line) > base) & (Cells(line) + 1 + Cells(word) > width) THEN
        AddRow(line, fg, -1, FALSE);
        line := "";  Cat(line, cont);  base := Cells(line)
      END;
      IF Cells(line) > base THEN CatCh(line, " ") END;
      Cat(line, word)
    END
  END;
  IF Cells(line) > base THEN AddRow(line, fg, -1, FALSE) END
END Wrap;

PROCEDURE IndexOn(l, i: INTEGER): INTEGER;
VAR k, r: INTEGER;
BEGIN
  r := -1;
  FOR k := 0 TO nStops[l] - 1 DO IF stops[l][k] = i THEN r := k END END;
  RETURN r
END IndexOn;

PROCEDURE NbRow(l: INTEGER);
VAR k: INTEGER;
    s: ARRAY 200 OF CHAR;
BEGIN
  k := IndexOn(l, sel);
  s := "";  Cat(s, lineName[l]);  Pad(s, 8);
  IF k > 0 THEN Cat(s, "◂ ");  Cat(s, st[stops[l][k - 1]].name)
  ELSE Cat(s, "◂ end of the line")
  END;
  Cat(s, "   ●   ");
  IF k < nStops[l] - 1 THEN Cat(s, st[stops[l][k + 1]].name);  Cat(s, " ▸")
  ELSE Cat(s, "end of the line ▸")
  END;
  AddRow(s, CText, lineColor[l], l = curLine)
END NbRow;

PROCEDURE BuildRows(width: INTEGER);
VAR l, i, j: INTEGER;
    item: ARRAY 700 OF CHAR;
BEGIN
  nRows := 0;
  AddRow("", CText, -1, FALSE);
  FOR l := 0 TO NLines - 1 DO
    IF l IN st[sel].lines THEN NbRow(l) END
  END;
  AddRow("", CText, -1, FALSE);
  AddRow("THE NEIGHBORHOOD", CHead, -1, FALSE);
  Wrap(st[sel].hood, width, "", "", CText);
  AddRow("", CText, -1, FALSE);
  AddRow("SEE & DO", CHead, -1, FALSE);
  i := 0;
  WHILE st[sel].sees[i] # 0X DO
    j := 0;
    WHILE (st[sel].sees[i] # 0X) & (st[sel].sees[i] # "|") DO
      item[j] := st[sel].sees[i];  INC(i);  INC(j)
    END;
    item[j] := 0X;
    Wrap(item, width, "• ", "  ", CText);
    IF st[sel].sees[i] = "|" THEN INC(i) END
  END
END BuildRows;

PROCEDURE DrawCard;
VAR inner, vis, i, r, y, fg: INTEGER;
    t: ARRAY 80 OF CHAR;
BEGIN
  pw := 78;
  IF pw > TUI.Cols - 4 THEN pw := TUI.Cols - 4 END;
  inner := pw - 4;
  BuildRows(inner);
  ph := nRows + 4;
  IF ph > TUI.Rows - 2 THEN ph := TUI.Rows - 2 END;
  px := (TUI.Cols - pw) DIV 2 + 1;
  py := (TUI.Rows - ph) DIV 2 + 1;
  vis := ph - 3;
  IF scroll > nRows - vis THEN scroll := nRows - vis END;
  IF scroll < 0 THEN scroll := 0 END;

  TUI.FillRect(px + 2, py + ph, pw, 1, " ", CText, CShadow);
  TUI.FillRect(px + pw, py + 1, 2, ph, " ", CText, CShadow);
  TUI.FillRect(px, py, pw, ph, " ", CText, CPopBg);
  TUI.DrawBox(px, py, pw, ph, CDim, CPopBg);
  t := " ";  Cat(t, st[sel].name);  Cat(t, " ");
  PutClip(px + 2, py, t, pw - 4, CHi, CPopBg);

  FOR i := 0 TO vis - 1 DO
    r := scroll + i;  y := py + 1 + i;
    IF r < nRows THEN
      IF rows[r].chip >= 0 THEN
        IF rows[r].hi THEN TUI.PutStr(px + 1, y, "▶", CHi, CPopBg);  fg := CWhite
        ELSE fg := CDim
        END;
        TUI.PutStr(px + 2, y, "■", rows[r].chip, CPopBg);
        PutClip(px + 4, y, rows[r].txt, inner - 2, fg, CPopBg)
      ELSE
        PutClip(px + 2, y, rows[r].txt, inner, rows[r].fg, CPopBg)
      END
    END
  END;
  IF scroll > 0 THEN TUI.PutStr(px + pw - 2, py + 1, "▲", CHi, CPopBg) END;
  IF scroll + vis < nRows THEN TUI.PutStr(px + pw - 2, py + vis, "▼", CHi, CPopBg) END;
  PutClip(px + 2, py + ph - 2, "←/→ ride   ↑/↓ line   R random   Esc map", inner, CDim, CPopBg)
END DrawCard;

PROCEDURE Render;
VAR msg: ARRAY 100 OF CHAR;
    n: ARRAY 12 OF CHAR;
BEGIN
  TUI.ClearBack(CText, CBg);
  IF (TUI.Cols < NeedW) OR (TUI.Rows < NeedH) THEN
    msg := "Please enlarge the terminal to at least 110 x 37";
    PutClip((TUI.Cols - Cells(msg)) DIV 2 + 1, TUI.Rows DIV 2, msg, TUI.Cols, CHi, CBg);
    msg := "(Q quits)";
    PutClip((TUI.Cols - Cells(msg)) DIV 2 + 1, TUI.Rows DIV 2 + 1, msg, TUI.Cols, CDim, CBg);
    n := ""
  ELSE
    ox := (TUI.Cols - MapW) DIV 2 + 1;
    oy := 3 + (TUI.Rows - NeedH) DIV 2;
    DrawChrome;
    DrawMap;
    DrawStatus;
    IF mode = 1 THEN DrawCard END
  END;
  TUI.Flush
END Render;

(* ════════════════════════════════════════════════════════════════════
   Interaction
   ════════════════════════════════════════════════════════════════════ *)

(* Move -- jump to the closest station in a direction.  Rows are about
   twice as tall as columns are wide, so vertical distance counts double. *)
PROCEDURE Move(ddx, ddy: INTEGER);
VAR i, vx, vy, along, perp, score, best, bestScore: INTEGER;
BEGIN
  best := -1;  bestScore := 1000000;
  FOR i := 0 TO nSt - 1 DO
    IF i # sel THEN
      vx := st[i].x - st[sel].x;  vy := (st[i].y - st[sel].y) * 2;
      along := vx * ddx + vy * ddy;
      perp := ABS(vx * ddy - vy * ddx);
      IF (along > 0) & (perp <= along * 2) THEN
        score := along + perp * 2;
        IF score < bestScore THEN bestScore := score;  best := i END
      END
    END
  END;
  IF best >= 0 THEN sel := best END
END Move;

PROCEDURE Hit(x, y: INTEGER): INTEGER;
VAR i, d, best, bestD: INTEGER;
BEGIN
  best := -1;  bestD := 100;
  FOR i := 0 TO nSt - 1 DO
    IF (ABS(st[i].x - x) <= 1) & (ABS(st[i].y - y) <= 1) THEN
      d := ABS(st[i].x - x) + 2 * ABS(st[i].y - y);
      IF d < bestD THEN bestD := d;  best := i END
    END
  END;
  RETURN best
END Hit;

PROCEDURE Open(i: INTEGER);
BEGIN
  sel := i;
  IF (curLine < 0) OR ~(curLine IN st[sel].lines) THEN curLine := FirstLine(sel) END;
  scroll := 0;  mode := 1
END Open;

PROCEDURE RandomStation(): INTEGER;
VAR r: INTEGER;
BEGIN
  REPEAT r := Rand(nSt) UNTIL r # sel;
  RETURN r
END RandomStation;

PROCEDURE Ride(dir: INTEGER);
VAR k: INTEGER;
BEGIN
  k := IndexOn(curLine, sel);
  IF (k >= 0) & (k + dir >= 0) & (k + dir < nStops[curLine]) THEN
    sel := stops[curLine][k + dir];  scroll := 0
  END
END Ride;

PROCEDURE SwitchLine(dir: INTEGER);
VAR l: INTEGER;
BEGIN
  l := curLine;
  REPEAT l := (l + dir + NLines) MOD NLines UNTIL l IN st[sel].lines;
  curLine := l
END SwitchLine;

PROCEDURE MapKey(k: CHAR);
BEGIN
  IF k = TUI.KUp THEN Move(0, -1)
  ELSIF k = TUI.KDown THEN Move(0, 1)
  ELSIF k = TUI.KLeft THEN Move(-1, 0)
  ELSIF k = TUI.KRight THEN Move(1, 0)
  ELSIF (k = TUI.KEnter) OR (k = " ") OR (k = 0AX) THEN Open(sel)
  ELSIF (k = "r") OR (k = "R") THEN Open(RandomStation())
  ELSIF (k = "q") OR (k = "Q") OR (k = TUI.KEsc) THEN running := FALSE
  END
END MapKey;

PROCEDURE CardKey(k: CHAR);
BEGIN
  IF k = TUI.KLeft THEN Ride(-1)
  ELSIF k = TUI.KRight THEN Ride(1)
  ELSIF k = TUI.KUp THEN SwitchLine(-1)
  ELSIF k = TUI.KDown THEN SwitchLine(1)
  ELSIF k = TUI.KPgUp THEN scroll := scroll - (ph - 4)
  ELSIF k = TUI.KPgDn THEN scroll := scroll + (ph - 4)
  ELSIF (k = "r") OR (k = "R") THEN Open(RandomStation())
  ELSIF (k = TUI.KEsc) OR (k = TUI.KEnter) OR (k = "q") OR (k = "Q") OR (k = 0AX) THEN mode := 0
  END
END CardKey;

PROCEDURE Mouse(mx, my, mb: INTEGER);
VAR i: INTEGER;
    inside: BOOLEAN;
BEGIN
  IF mode = 0 THEN
    i := Hit(mx - ox + 1, my - oy + 1);
    IF i >= 0 THEN
      IF mb = 0 THEN Open(i)
      ELSIF (mb >= 32) & (mb < 64) THEN sel := i
      END
    END
  ELSE
    inside := (mx >= px) & (mx < px + pw) & (my >= py) & (my < py + ph);
    IF mb = 64 THEN DEC(scroll, 2)
    ELSIF mb = 65 THEN INC(scroll, 2)
    ELSIF (mb = 0) & ~inside THEN mode := 0
    END
  END
END Mouse;

PROCEDURE Run;
VAR ev: TUI.Event;
    small: BOOLEAN;
BEGIN
  TUI.Init();
  running := TRUE;
  Render;
  WHILE running DO
    WHILE ~TUI.PollEvent(ev) DO Time.Sleep(15) END;
    small := (TUI.Cols < NeedW) OR (TUI.Rows < NeedH);
    IF ev.kind = TUI.EvResize THEN
      TUI.InvalidateFront
    ELSIF ev.kind = TUI.EvKey THEN
      IF small THEN
        IF (ev.key = "q") OR (ev.key = "Q") OR (ev.key = TUI.KEsc) THEN running := FALSE END
      ELSIF mode = 0 THEN MapKey(ev.key)
      ELSE CardKey(ev.key)
      END
    ELSIF (ev.kind = TUI.EvMouse) & ~small THEN
      Mouse(ev.mx, ev.my, ev.mb)
    END;
    IF running THEN Render END
  END;
  TUI.Done()
END Run;

BEGIN
  nSt := 0;  loadOk := TRUE;  badName := "";
  LoadRed;  LoadOrange;  LoadSilver;  LoadBlue;  LoadYellow;  LoadGreen;
  LoadLines;
  BuildGraph;

  seed := Time.Now();
  IF seed < 0 THEN seed := -seed END;
  seed := seed MOD 2147483646 + 1;

  sel := Find("Metro Center");
  curLine := -1;  mode := 0;  scroll := 0;

  IF ~loadOk THEN
    Out.String("metro: line data names an unknown station: ");
    Out.String(badName);  Out.Ln
  ELSIF nSt # 98 THEN
    Out.String("metro: expected 98 stations, loaded ");
    Out.Int(nSt, 0);  Out.Ln
  ELSE
    Run
  END
END Metro.
