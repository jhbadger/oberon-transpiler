MODULE newickview;

(*
  newickview -- Terminal phylogenetic tree viewer built on TUI / Widgets / FileDialog.
  Rendering:
    Terminal  half-block pixel buffer 240x100 (cladogram or phylogram)
  Layout modes:
    Cladogram   all leaves at the same depth
    Phylogram   branch lengths proportional
    Radial      circular layout
  Colour schemes:
    Monochrome  all black
    Depth       gradient by depth from root
    Branch Len  short=blue, long=red
    Clade       subtree colouring (8 colours)
  Keyboard shortcuts
    Arrow keys        Scroll / pan view
    + / -             Zoom in / out
    R                 Reroot at selected node (midpoint if none)
    M                 Midpoint reroot
    L                 Cycle layout mode
    C                 Cycle colour scheme
    S                 Toggle node labels
    B                 Toggle branch length labels
    V                 Save SVG snapshot
    Enter / Space     Select hovered node
    Esc               Deselect
    Ctrl+O            Open file
    Ctrl+Q / Q        Quit
    F1                Help
    LMB click         Select node
    Scroll wheel      Zoom
*)

IMPORT TUI, Widgets, FileDialog, Files, Newick, Strings, Math, Terminal, Time, Args, Out;

(* ================================================================== *)
(*  Constants                                                          *)
(* ================================================================== *)

CONST
LayoutCladogram = 0;
LayoutPhylogram = 1;
LayoutRadial    = 2;

ColourMono      = 0;
ColourDepth     = 1;
ColourBranch    = 2;
ColourClade     = 3;

ZoomStep   = 1.15;
PanStep    = 4;

CanvasW    = 240;
CanvasH    = 100;

SvgW       = 900;
SvgH       = 700;

MaxNodes   = 4096;

CmdOpen    = 10;
CmdReload  = 11;
CmdQuit    = 12;

CmdLayCla  = 20;
CmdLayPhy  = 21;
CmdLayRad  = 22;

CmdColMono = 30;
CmdColDep  = 31;
CmdColBr   = 32;
CmdColCla  = 33;

CmdReroot  = 40;
CmdMidRoot = 41;
CmdTogLbl  = 42;
CmdTogBL   = 43;
CmdSaveSVG = 44;
CmdHelp    = 50;

HelpN      = 36;

(* ================================================================== *)
(*  Types                                                              *)
(* ================================================================== *)

TYPE
NodeInfo = RECORD
  node   : Newick.Node;
  px, py : INTEGER;       (* pixel coords in canvas space *)
  depth  : INTEGER;       (* depth from root              *)
  maxBL  : REAL;          (* cumulative branch length     *)
  leafIdx: INTEGER;       (* leaf order index             *)
  cladeCol: INTEGER;      (* clade colour index 0-7       *)
END;

ViewerWin  = POINTER TO ViewerWinRec;
ViewerWinRec = RECORD (TUI.WindowRec)
tree        : Newick.Tree;
loaded      : BOOLEAN;
filePath    : ARRAY 1024 OF CHAR;
sceneDirty  : BOOLEAN;
layout      : INTEGER;
colScheme   : INTEGER;
showLabels  : BOOLEAN;
showBL      : BOOLEAN;
panX, panY  : INTEGER;
zoom        : REAL;
selectedNode: Newick.Node;
hoveredNode : Newick.Node;
nodeCount   : INTEGER;
leafCount   : INTEGER;
maxDepth    : INTEGER;
maxBL       : REAL;
nodes       : ARRAY MaxNodes OF NodeInfo;
nNodes      : INTEGER;
END;

(* ================================================================== *)
(*  Globals                                                            *)
(* ================================================================== *)

VAR
vw        : ViewerWin;
mbar      : Widgets.MenuBar;
sline     : Widgets.StatusLine;
running   : BOOLEAN;
statusMsg : ARRAY 256 OF CHAR;
helpScroll: INTEGER;
helpWin   : TUI.Window;

(* ================================================================== *)
(*  Colour helpers                                                     *)
(* ================================================================== *)

PROCEDURE DepthColor(d, maxD: INTEGER): INTEGER;
VAR t: INTEGER;
BEGIN
  IF maxD <= 0 THEN RETURN 255 END;
  t := d * 5 DIV maxD;
  CASE t OF
    0: RETURN  21
    | 1: RETURN  51
    | 2: RETURN  46
    | 3: RETURN 226
  ELSE   RETURN 196
END
END DepthColor;

PROCEDURE BranchLenColor(bl, maxBL: REAL): INTEGER;
VAR t: INTEGER;
BEGIN
  IF maxBL <= 0.0 THEN RETURN 255 END;
  t := FLOOR(bl / maxBL * 4.0);
  IF t > 4 THEN t := 4 END;
  CASE t OF
    0: RETURN  21
    | 1: RETURN  51
    | 2: RETURN 255
    | 3: RETURN 226
  ELSE   RETURN 196
END
END BranchLenColor;

PROCEDURE CladeColor(idx: INTEGER): INTEGER;
BEGIN
  CASE idx MOD 8 OF
    0: RETURN 196
    | 1: RETURN  46
    | 2: RETURN  21
    | 3: RETURN 226
    | 4: RETURN 201
    | 5: RETURN  51
    | 6: RETURN 208
  ELSE   RETURN 255
END
END CladeColor;

PROCEDURE NodeColor(v: ViewerWin; i: INTEGER): INTEGER;
BEGIN
  CASE v.colScheme OF
    ColourMono   : RETURN 255
    | ColourDepth  : RETURN DepthColor(v.nodes[i].depth, v.maxDepth)
    | ColourBranch : RETURN BranchLenColor(v.nodes[i].maxBL, v.maxBL)
    | ColourClade  : RETURN CladeColor(v.nodes[i].cladeCol)
  END;
  RETURN 255
END NodeColor;

(* Same but returns RGB for SVG *)
PROCEDURE DepthColorRGB(d, maxD: INTEGER; VAR r, g, b: INTEGER);
VAR t: INTEGER;
BEGIN
  IF maxD <= 0 THEN r:=220; g:=220; b:=220; RETURN END;
  t := d * 5 DIV maxD;
  CASE t OF
    0: r:= 40; g:= 40; b:=220
    | 1: r:= 40; g:=200; b:=200
    | 2: r:= 40; g:=200; b:= 40
    | 3: r:=220; g:=220; b:= 40
  ELSE r:=220; g:= 40; b:= 40
END
END DepthColorRGB;

PROCEDURE BranchLenColorRGB(bl, maxBL: REAL; VAR r, g, b: INTEGER);
VAR t: INTEGER;
BEGIN
  IF maxBL <= 0.0 THEN r:=220; g:=220; b:=220; RETURN END;
  t := FLOOR(bl / maxBL * 4.0);
  IF t > 4 THEN t := 4 END;
  CASE t OF
    0: r:= 40; g:= 40; b:=200
    | 1: r:= 40; g:=200; b:=200
    | 2: r:=220; g:=220; b:=220
    | 3: r:=220; g:=220; b:= 40
  ELSE r:=220; g:= 40; b:= 40
END
END BranchLenColorRGB;

PROCEDURE CladeColorRGB(idx: INTEGER; VAR r, g, b: INTEGER);
BEGIN
  CASE idx MOD 8 OF
    0: r:=220; g:= 40; b:= 40
    | 1: r:= 40; g:=200; b:= 40
    | 2: r:= 40; g:= 40; b:=220
    | 3: r:=220; g:=200; b:= 40
    | 4: r:=200; g:= 40; b:=200
    | 5: r:= 40; g:=200; b:=210
    | 6: r:=255; g:=130; b:= 40
  ELSE r:=200; g:=200; b:=200
END
END CladeColorRGB;

PROCEDURE NodeColorRGB(v: ViewerWin; i: INTEGER; VAR r, g, b: INTEGER);
BEGIN
  CASE v.colScheme OF
    ColourMono   : r:=200; g:=200; b:=200
    | ColourDepth  : DepthColorRGB(v.nodes[i].depth, v.maxDepth, r, g, b)
    | ColourBranch : BranchLenColorRGB(v.nodes[i].maxBL, v.maxBL, r, g, b)
    | ColourClade  : CladeColorRGB(v.nodes[i].cladeCol, r, g, b)
  END
END NodeColorRGB;

(* ================================================================== *)
(*  Tree analysis: count, layout                                       *)
(* ================================================================== *)

PROCEDURE CountNodes(n: Newick.Node; VAR nc, lc: INTEGER);
VAR c: Newick.Node;
BEGIN
  IF n = NIL THEN RETURN END;
  INC(nc);
  IF n.firstChild = NIL THEN INC(lc)
ELSE c := n.firstChild; WHILE c # NIL DO CountNodes(c, nc, lc); c := c.nextSibling END
END
END CountNodes;

PROCEDURE MaxDepthOf(n: Newick.Node; d: INTEGER): INTEGER;
VAR c: Newick.Node; m, r: INTEGER;
BEGIN
  IF n = NIL THEN RETURN 0 END;
  IF n.firstChild = NIL THEN RETURN d END;
  m := d;
  c := n.firstChild;
  WHILE c # NIL DO
    r := MaxDepthOf(c, d+1);
    IF r > m THEN m := r END;
    c := c.nextSibling
  END;
  RETURN m
END MaxDepthOf;

PROCEDURE MaxBLOf(n: Newick.Node; acc: REAL): REAL;
VAR c: Newick.Node; m, r: REAL;
BEGIN
  IF n = NIL THEN RETURN 0.0 END;
  m := acc + n.branchLength;
  IF n.firstChild = NIL THEN RETURN m END;
  c := n.firstChild;
  WHILE c # NIL DO
    r := MaxBLOf(c, m);
    IF r > m THEN m := r END;
    c := c.nextSibling
  END;
  RETURN m
END MaxBLOf;

(* Assign clade colours: each direct child of root gets a different colour,
   all descendants inherit it. *)
PROCEDURE AssignCladeColors(n: Newick.Node; col: INTEGER; v: ViewerWin);
VAR c: Newick.Node; i, nextCol: INTEGER;
BEGIN
  IF n = NIL THEN RETURN END;
  (* find this node in v.nodes *)
  FOR i := 0 TO v.nNodes-1 DO
    IF v.nodes[i].node = n THEN v.nodes[i].cladeCol := col END
  END;
  c := n.firstChild; nextCol := col;
  WHILE c # NIL DO
    AssignCladeColors(c, nextCol, v);
    INC(nextCol);
    c := c.nextSibling
  END
END AssignCladeColors;

(* ------------------------------------------------------------------ *)
(*  Layout: Cladogram / Phylogram                                     *)
(* ------------------------------------------------------------------ *)

VAR layoutLeafIdx: INTEGER;

PROCEDURE LayoutRectRecurse(v: ViewerWin; n: Newick.Node;
depth: INTEGER; accBL: REAL;
totalDepth: INTEGER; totalBL: REAL;
cW, cH, margin: INTEGER;
isPhylogram: BOOLEAN);
VAR i: INTEGER; c: Newick.Node;
firstChildY, lastChildY, sumY, cnt: INTEGER;
px, py: INTEGER;
BEGIN
  IF n = NIL THEN RETURN END;
  (* find slot *)
  i := v.nNodes; v.nNodes := v.nNodes + 1;
  v.nodes[i].node   := n;
  v.nodes[i].depth  := depth;
  v.nodes[i].maxBL  := accBL + n.branchLength;

  IF n.firstChild = NIL THEN
    (* leaf *)
    v.nodes[i].leafIdx := layoutLeafIdx;
    IF isPhylogram & (totalBL > 0.0) THEN
      px := margin + FLOOR((accBL + n.branchLength) / totalBL * FLT(cW - 2*margin))
    ELSIF totalDepth > 0 THEN
      px := margin + (depth * (cW - 2*margin)) DIV totalDepth
    ELSE
      px := margin
    END;
    py := margin + (layoutLeafIdx * (cH - 2*margin)) DIV (v.leafCount - 1 + 1);
    INC(layoutLeafIdx);
  ELSE
    (* recurse children first *)
    firstChildY := -1; lastChildY := 0; sumY := 0; cnt := 0;
    c := n.firstChild;
    WHILE c # NIL DO
      LayoutRectRecurse(v, c, depth+1, accBL+n.branchLength,
      totalDepth, totalBL, cW, cH, margin, isPhylogram);
      (* child was just added as v.nodes[v.nNodes-...], find it *)
      (* We look it up by pointer *)
      INC(cnt);
      c := c.nextSibling
    END;
    (* compute parent Y as mean of children Y *)
    sumY := 0; cnt := 0;
    c := n.firstChild;
    WHILE c # NIL DO
      FOR j := 0 TO v.nNodes-1 DO
        IF v.nodes[j].node = c THEN
          IF firstChildY < 0 THEN firstChildY := v.nodes[j].py END;
          lastChildY := v.nodes[j].py;
          INC(sumY, v.nodes[j].py); INC(cnt)
        END
      END
    END;
    c := c.nextSibling;
  IF cnt > 0 THEN py := sumY DIV cnt ELSE py := cH DIV 2 END;

  IF isPhylogram & (totalBL > 0.0) THEN
    px := margin + FLOOR((accBL + n.branchLength) / totalBL * FLT(cW - 2*margin))
  ELSIF totalDepth > 0 THEN
    px := margin + (depth * (cW - 2*margin)) DIV totalDepth
  ELSE
    px := margin
  END;
  firstChildY := firstChildY;
  lastChildY  := lastChildY
END;
v.nodes[i].px := px;
v.nodes[i].py := py
END LayoutRectRecurse;

(* ------------------------------------------------------------------ *)
(*  Layout: Radial                                                     *)
(* ------------------------------------------------------------------ *)

PROCEDURE LayoutRadialRecurse(v: ViewerWin; n: Newick.Node;
cx, cy: INTEGER; r: REAL;
angleStart, angleEnd: REAL;
depth: INTEGER; accBL: REAL;
totalBL: REAL; isPhylogram: BOOLEAN);
VAR i, childLeaves, totalLeaves: INTEGER;
c: Newick.Node;
anglePer, a, childR: REAL;
px, py: INTEGER;
BEGIN
  IF n = NIL THEN RETURN END;
  i := v.nNodes; v.nNodes := v.nNodes + 1;
  v.nodes[i].node  := n;
  v.nodes[i].depth := depth;
  v.nodes[i].maxBL := accBL + n.branchLength;

  IF isPhylogram & (totalBL > 0.0) THEN
    r := (accBL + n.branchLength) / totalBL * FLT(cx)
  END;

  a := (angleStart + angleEnd) / 2.0;
  px := cx + FLOOR(r * Math.cos(a));
  py := cy + FLOOR(r * Math.sin(a));
  v.nodes[i].px := px;
  v.nodes[i].py := py;

  IF n.firstChild # NIL THEN
    (* count leaves under each child *)
    totalLeaves := 0;
    c := n.firstChild;
    WHILE c # NIL DO
      VAR nl, ll: INTEGER;
      BEGIN nl:=0; ll:=0; CountNodes(c, nl, ll); INC(totalLeaves, ll) END;
      c := c.nextSibling
    END;
    IF totalLeaves < 1 THEN totalLeaves := 1 END;
    anglePer := (angleEnd - angleStart) / FLT(totalLeaves);
    c := n.firstChild;
    VAR aStart: REAL;
    BEGIN
      aStart := angleStart;
      WHILE c # NIL DO
        VAR nl2, ll2: INTEGER;
        BEGIN
          nl2:=0; ll2:=0; CountNodes(c, nl2, ll2);
          IF ll2 < 1 THEN ll2 := 1 END;
          IF isPhylogram & (totalBL > 0.0) THEN
            childR := (accBL + n.branchLength + c.branchLength) / totalBL * FLT(cx)
          ELSE
            childR := r + FLT(cx) / FLT(v.maxDepth + 1)
          END;
          LayoutRadialRecurse(v, c, cx, cy, childR,
          aStart, aStart + anglePer * FLT(ll2),
          depth+1, accBL+n.branchLength, totalBL, isPhylogram);
          aStart := aStart + anglePer * FLT(ll2)
        END;
        c := c.nextSibling
      END
    END
  END
END LayoutRadialRecurse;

(* ------------------------------------------------------------------ *)
(*  Top-level layout dispatcher                                        *)
(* ------------------------------------------------------------------ *)

PROCEDURE BuildLayout(v: ViewerWin);
VAR cW, cH, margin: INTEGER;
BEGIN
  v.nNodes := 0;
  layoutLeafIdx := 0;
  IF (v.tree = NIL) OR (v.tree.root = NIL) THEN RETURN END;

  cW := FLOOR(FLT(CanvasW) / v.zoom);
  cH := FLOOR(FLT(CanvasH) / v.zoom);
  margin := 10;

  IF v.layout = LayoutRadial THEN
    LayoutRadialRecurse(v, v.tree.root,
    CanvasW DIV 2, CanvasH DIV 2,
    FLT(CanvasH DIV 2 - margin),
    0.0, 2.0 * Math.pi,
    0, 0.0, v.maxBL,
    FALSE (* cladogram radial *))
  ELSE
    LayoutRectRecurse(v, v.tree.root,
    0, 0.0,
    v.maxDepth, v.maxBL,
    cW, cH, margin,
    v.layout = LayoutPhylogram)
  END;

  (* Assign clade colours from root's children *)
  VAR i, col: INTEGER; c: Newick.Node;
  BEGIN
    (* default all to 0 *)
    FOR i := 0 TO v.nNodes-1 DO v.nodes[i].cladeCol := 0 END;
    c := v.tree.root.firstChild; col := 0;
    WHILE c # NIL DO
      AssignCladeColors(c, col, v);
      INC(col); c := c.nextSibling
    END
  END
END BuildLayout;

(* ================================================================== *)
(*  Canvas → screen coordinate transform                              *)
(* ================================================================== *)

PROCEDURE CanvasToScreen(v: ViewerWin; cx, cy: INTEGER; VAR sx, sy: INTEGER);
BEGIN
  sx := FLOOR(FLT(cx) * v.zoom) + v.panX;
  sy := FLOOR(FLT(cy) * v.zoom) + v.panY
END CanvasToScreen;

PROCEDURE ScreenToCanvas(v: ViewerWin; sx, sy: INTEGER; VAR cx, cy: INTEGER);
BEGIN
  cx := FLOOR(FLT(sx - v.panX) / v.zoom);
  cy := FLOOR(FLT(sy - v.panY) / v.zoom)
END ScreenToCanvas;

(* ================================================================== *)
(*  Pick nearest node to screen position                              *)
(* ================================================================== *)

PROCEDURE PickNode(v: ViewerWin; sx, sy: INTEGER): Newick.Node;
VAR i, best, cx, cy, dx, dy, dist, bestDist, px, py: INTEGER;
BEGIN
  best := -1; bestDist := 9999999;
  ScreenToCanvas(v, sx, sy, cx, cy);
  FOR i := 0 TO v.nNodes-1 DO
    px := v.nodes[i].px; py := v.nodes[i].py;
    dx := px - cx; dy := py - cy;
    dist := dx*dx + dy*dy;
    IF dist < bestDist THEN bestDist := dist; best := i END
  END;
  IF (best >= 0) & (bestDist < 100) THEN RETURN v.nodes[best].node END;
  RETURN NIL
END PickNode;

(* ================================================================== *)
(*  Rendering                                                          *)
(* ================================================================== *)

PROCEDURE RenderScene(v: ViewerWin);
VAR i, j, sx, sy, px, py, sx2, sy2, px2, py2: INTEGER;
col: INTEGER;
c: Newick.Node;
node: Newick.Node;
cx0, cy0, cx1, cy1: INTEGER;
BEGIN
  cx0 := v.x+1; cx1 := v.x+v.w-2;
  cy0 := (v.y+1)*2; cy1 := (v.y+v.h-2)*2+1;
  Terminal.ClearBuf();
  IF ~v.loaded OR (v.nNodes = 0) THEN Terminal.Flush(); RETURN END;

  (* Draw edges first (parent -> each child) *)
  FOR i := 0 TO v.nNodes-1 DO
    node := v.nodes[i].node;
    IF node.parent # NIL THEN
      (* find parent in nodes *)
      FOR j := 0 TO v.nNodes-1 DO
        IF v.nodes[j].node = node.parent THEN
          col := NodeColor(v, i);
          (* canvas coords *)
          px  := v.nodes[i].px;  py  := v.nodes[i].py;
          px2 := v.nodes[j].px;  py2 := v.nodes[j].py;
          (* to screen *)
          CanvasToScreen(v, px, py, sx, sy);
          CanvasToScreen(v, px2, py2, sx2, sy2);

          IF v.layout = LayoutRadial THEN
            Terminal.Line(sx, sy, sx2, sy2, col)
          ELSE
            (* elbow: horizontal from parent X to child X at child Y,
               then vertical connector at parent X *)
            Terminal.Line(sx2, sy, sx, sy, col);   (* horizontal *)
            Terminal.Line(sx2, sy2, sx2, sy, col)  (* vertical   *)
          END
        END
      END
    END
  END;

  (* Draw nodes *)
  FOR i := 0 TO v.nNodes-1 DO
    node := v.nodes[i].node;
    px := v.nodes[i].px; py := v.nodes[i].py;
    CanvasToScreen(v, px, py, sx, sy);
    col := NodeColor(v, i);

    IF node = v.selectedNode THEN
      Terminal.FillCircle(sx, sy, 4, 226)
    ELSIF node = v.hoveredNode THEN
      Terminal.Circle(sx, sy, 3, 51)
    END;

    IF node.firstChild = NIL THEN
      Terminal.FillCircle(sx, sy, 2, col);
      (* Label *)
      IF v.showLabels & (Strings.Length(node.name) > 0) THEN
        IF (sx+4 < CanvasW) & (sy > 0) & (sy < CanvasH) THEN
          Terminal.Goto(sx DIV 1 + 1, sy DIV 2 + 1);
          Out.String(node.name)
        END
      END
    ELSE
      Terminal.Plot(sx, sy, col)
    END;

    IF v.showBL & (node.branchLength > 0.0) & (node.parent # NIL) THEN
      (* label midpoint of branch *)
      FOR j := 0 TO v.nNodes-1 DO
        IF v.nodes[j].node = node.parent THEN
          VAR mx, my: INTEGER; blBuf: ARRAY 16 OF CHAR;
          BEGIN
            CanvasToScreen(v, (v.nodes[i].px + v.nodes[j].px) DIV 2,
            (v.nodes[i].py + v.nodes[j].py) DIV 2,
            mx, my);
            IF (mx > 0) & (my > 0) & (mx < CanvasW) & (my < CanvasH DIV 2) THEN
              Strings.RealToStr(node.branchLength, blBuf);
              blBuf[5] := 0X; (* truncate *)
              Terminal.Goto(mx+1, my DIV 2 + 1);
              Out.String(blBuf)
            END
          END
        END
      END
    END
  END;

  Terminal.Flush()
END RenderScene;

(* ================================================================== *)
(*  TUI draw callback                                                  *)
(* ================================================================== *)

PROCEDURE DrawViewer(view: TUI.View);
VAR bfg, bbg: INTEGER; buf: ARRAY 64 OF CHAR; tlen, tx: INTEGER;
BEGIN
  WITH view: ViewerWinRec DO
    IF view.focused THEN bfg := TUI.White; bbg := TUI.Blue
  ELSE                 bfg := TUI.White; bbg := TUI.Black
END;
TUI.FillRect(view.x+1, view.y+1, view.w-2, view.h-2, ' ', TUI.White, TUI.Black);
TUI.DrawBox(view.x, view.y, view.w, view.h, bfg, bbg);

IF view.loaded THEN
  tlen := Strings.Length(view.filePath);
  WHILE (tlen > 0) & (view.filePath[tlen-1] # '/') DO DEC(tlen) END;
  Strings.Extract(view.filePath, tlen, Strings.Length(view.filePath)-tlen, buf)
ELSE Strings.Copy("[no file]", buf)
END;
tlen := Strings.Length(buf); IF tlen > view.w-4 THEN tlen := view.w-4 END;
buf[tlen] := 0X;
tx := view.x + (view.w - tlen) DIV 2;
TUI.PutStr(tx, view.y, buf, TUI.Yellow, bbg);

CASE view.layout OF
  LayoutCladogram: Strings.Copy(" Cladogram ", buf)
  | LayoutPhylogram: Strings.Copy(" Phylogram ", buf)
  | LayoutRadial   : Strings.Copy(" Radial    ", buf)
END;
TUI.PutStr(view.x+1, view.y+view.h-1, buf, TUI.Cyan, bbg);

CASE view.colScheme OF
  ColourMono  : Strings.Copy(" Mono  ", buf)
  | ColourDepth : Strings.Copy(" Depth ", buf)
  | ColourBranch: Strings.Copy(" BrLen ", buf)
  | ColourClade : Strings.Copy(" Clade ", buf)
END;
TUI.PutStr(view.x+12, view.y+view.h-1, buf, TUI.Green, bbg);

IF view.loaded THEN
  Strings.IntToStr(view.leafCount, buf);
  Strings.Append(" leaves", buf);
  TUI.PutStr(view.x+view.w-Strings.Length(buf)-2, view.y+view.h-1,
  buf, TUI.White, bbg)
END
END
END DrawViewer;

(* ================================================================== *)
(*  Event handler                                                      *)
(* ================================================================== *)

PROCEDURE HandleViewer(view: TUI.View; ev: TUI.Event): BOOLEAN;
VAR ch: CHAR; picked: Newick.Node;
BEGIN
  WITH view: ViewerWinRec DO
    IF ev.kind = TUI.EvKey THEN
      ch := ev.key;
      IF    ch = TUI.KLeft  THEN DEC(view.panX, PanStep)
    ELSIF ch = TUI.KRight THEN INC(view.panX, PanStep)
  ELSIF ch = TUI.KUp    THEN DEC(view.panY, PanStep)
ELSIF ch = TUI.KDown  THEN INC(view.panY, PanStep)
ELSIF (ch='+') OR (ch='=') THEN
  view.zoom := view.zoom * ZoomStep; BuildLayout(view)
ELSIF ch='-' THEN
  view.zoom := view.zoom / ZoomStep;
  IF view.zoom < 0.1 THEN view.zoom := 0.1 END;
  BuildLayout(view)
ELSIF (ch='L') OR (ch='l') THEN
  view.layout := (view.layout + 1) MOD 3;
  BuildLayout(view)
ELSIF (ch='C') OR (ch='c') THEN
  view.colScheme := (view.colScheme + 1) MOD 4
ELSIF (ch='S') OR (ch='s') THEN view.showLabels := ~view.showLabels
ELSIF (ch='B') OR (ch='b') THEN view.showBL := ~view.showBL
ELSIF (ch='V') OR (ch='v') THEN OnMenuCmd(CmdSaveSVG)
ELSIF (ch='R') OR (ch='r') THEN OnMenuCmd(CmdReroot)
ELSIF (ch='M') OR (ch='m') THEN OnMenuCmd(CmdMidRoot)
ELSIF ch = TUI.KEsc THEN view.selectedNode := NIL
ELSE RETURN FALSE
END;
view.sceneDirty := TRUE;
RETURN TRUE

ELSIF ev.kind = TUI.EvMouse THEN
  IF ev.mb = 0 THEN (* press *)
  picked := PickNode(view, ev.mx - view.x - 1, (ev.my - view.y - 1)*2);
  IF picked # NIL THEN view.selectedNode := picked END;
  view.sceneDirty := TRUE
ELSIF ev.mb = 64 THEN (* wheel up = zoom in *)
view.zoom := view.zoom * ZoomStep; BuildLayout(view); view.sceneDirty := TRUE
ELSIF ev.mb = 65 THEN (* wheel down = zoom out *)
view.zoom := view.zoom / ZoomStep;
IF view.zoom < 0.1 THEN view.zoom := 0.1 END;
BuildLayout(view); view.sceneDirty := TRUE
END;
RETURN TRUE
END
END;
RETURN FALSE
END HandleViewer;

(* ================================================================== *)
(*  Status update                                                      *)
(* ================================================================== *)

PROCEDURE UpdateStatus;
VAR buf, tmp: ARRAY 256 OF CHAR; n: Newick.Node;
BEGIN
  IF statusMsg[0] # 0X THEN
    Strings.Copy(statusMsg, buf)
  ELSIF vw.selectedNode # NIL THEN
    n := vw.selectedNode;
    Strings.Copy("  Selected: ", buf);
    IF Strings.Length(n.name) > 0 THEN Strings.Append(n.name, buf)
  ELSE Strings.Append("(internal)", buf) END;
  Strings.Append("  BL:", buf);
  Strings.RealToStr(n.branchLength, tmp); Strings.Append(tmp, buf);
  IF n.firstChild = NIL THEN Strings.Append("  [leaf]", buf)
ELSE Strings.Append("  [internal]", buf) END;
Strings.Append("  R=reroot here  M=midpoint  Esc=deselect", buf)
ELSIF vw.loaded THEN
  Strings.Copy("  Leaves:", buf);
  Strings.IntToStr(vw.leafCount, tmp); Strings.Append(tmp, buf);
  Strings.Append("  Nodes:", buf);
  Strings.IntToStr(vw.nodeCount, tmp); Strings.Append(tmp, buf);
  Strings.Append("  MaxDepth:", buf);
  Strings.IntToStr(vw.maxDepth, tmp); Strings.Append(tmp, buf);
  Strings.Append("  L:layout  C:colour  S:labels  B:BrLen  +/-:zoom  LMB:select", buf)
ELSE
  Strings.Copy("  No file loaded.  Ctrl+O to open.", buf)
END;
IF Strings.Length(buf) > TUI.Cols-1 THEN buf[TUI.Cols-1] := 0X END;
Strings.Copy(buf, sline.text);
statusMsg[0] := 0X
END UpdateStatus;

(* ================================================================== *)
(*  File loading                                                       *)
(* ================================================================== *)

PROCEDURE LoadNewick(path: ARRAY OF CHAR);
BEGIN
  IF vw.tree # NIL THEN Newick.FreeTree(vw.tree) END;
  vw.tree := Newick.Load(path);
  IF vw.tree # NIL THEN
    Strings.Copy(path, vw.filePath);
    vw.loaded       := TRUE;
    vw.selectedNode := NIL;
    vw.nodeCount    := 0; vw.leafCount := 0;
    CountNodes(vw.tree.root, vw.nodeCount, vw.leafCount);
    IF vw.leafCount < 2 THEN vw.leafCount := 2 END;
    vw.maxDepth := MaxDepthOf(vw.tree.root, 0);
    vw.maxBL    := MaxBLOf(vw.tree.root, 0.0);
    vw.zoom     := 1.0;
    vw.panX     := 0; vw.panY := 0;
    BuildLayout(vw);
    Strings.Copy("Loaded.", statusMsg)
  ELSE
    vw.loaded := FALSE;
    Strings.Copy("Failed to load Newick file.", statusMsg)
  END;
  vw.sceneDirty := TRUE
END LoadNewick;

(* ================================================================== *)
(*  SVG export                                                         *)
(* ================================================================== *)

PROCEDURE WStr(VAR rd: Files.Rider; s: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN i := 0; WHILE s[i] # 0X DO Files.Write(rd, ORD(s[i])); INC(i) END END WStr;

PROCEDURE WInt(VAR rd: Files.Rider; n: INTEGER);
VAR buf: ARRAY 16 OF CHAR;
BEGIN Strings.IntToStr(n, buf); WStr(rd, buf) END WInt;

PROCEDURE WReal(VAR rd: Files.Rider; x: REAL);
VAR buf: ARRAY 24 OF CHAR;
BEGIN Strings.RealToStr(x, buf); WStr(rd, buf) END WReal;

PROCEDURE RGBToHex(r, g, b: INTEGER; VAR hex: ARRAY OF CHAR);
PROCEDURE HexD(n: INTEGER): CHAR;
BEGIN IF n < 10 THEN RETURN CHR(ORD('0')+n) ELSE RETURN CHR(ORD('a')+n-10) END END HexD;
BEGIN
  hex[0]:='#';
  hex[1]:=HexD(r DIV 16); hex[2]:=HexD(r MOD 16);
  hex[3]:=HexD(g DIV 16); hex[4]:=HexD(g MOD 16);
  hex[5]:=HexD(b DIV 16); hex[6]:=HexD(b MOD 16);
  hex[7]:=0X
END RGBToHex;

(* Compute layout in SVG space (independent of terminal canvas) *)
PROCEDURE SVGLayout(v: ViewerWin;
VAR pxArr, pyArr: ARRAY OF INTEGER): INTEGER;
(* Returns nNodes; pxArr/pyArr sized MaxNodes.
   We reuse the same logical layout but scale to SvgW x SvgH. *)
VAR i, n: INTEGER; scX, scY: REAL;
BEGIN
  n := v.nNodes;
  scX := FLT(SvgW - 80) / FLT(CanvasW);
  scY := FLT(SvgH - 40) / FLT(CanvasH);
  FOR i := 0 TO n-1 DO
    pxArr[i] := 40 + FLOOR(FLT(v.nodes[i].px) * scX);
    pyArr[i] := 20 + FLOOR(FLT(v.nodes[i].py) * scY)
  END;
  RETURN n
END SVGLayout;

PROCEDURE SaveSVG(v: ViewerWin);
VAR f: Files.File; rd: Files.Rider;
svgPath: ARRAY 1024 OF CHAR;
i, j, n, r, g, b: INTEGER;
hex: ARRAY 8 OF CHAR;
pxArr, pyArr: ARRAY MaxNodes OF INTEGER;
node: Newick.Node;
p: Newick.Node;
ok: BOOLEAN;
lbl: ARRAY 64 OF CHAR;
BEGIN
  IF ~v.loaded THEN Strings.Copy("No file loaded.", statusMsg); RETURN END;

  (* Build SVG path *)
  Strings.Copy(v.filePath, svgPath);
  i := Strings.Length(svgPath);
  WHILE (i > 0) & (svgPath[i-1] # '.') & (svgPath[i-1] # '/') DO DEC(i) END;
  IF (i > 0) & (svgPath[i-1] = '.') THEN DEC(i); svgPath[i] := 0X END;
  Strings.Append(".svg", svgPath);

  f := Files.New(svgPath);
  IF f = NIL THEN Strings.Copy("Cannot create SVG.", statusMsg); RETURN END;
  Files.Set(rd, f, 0);

  n := SVGLayout(v, pxArr, pyArr);

  WStr(rd, '<?xml version="1.0" encoding="UTF-8"?>'); Files.Write(rd, 10);
  WStr(rd, '<svg xmlns="http://www.w3.org/2000/svg" width="');
  WInt(rd, SvgW); WStr(rd, '" height="'); WInt(rd, SvgH);
  WStr(rd, '" style="background:#111111">'); Files.Write(rd, 10);
  WStr(rd, '<style>text{font:10px monospace;fill:#ddd}</style>'); Files.Write(rd, 10);

  (* Edges *)
  FOR i := 0 TO n-1 DO
    node := v.nodes[i].node;
    IF node.parent # NIL THEN
      FOR j := 0 TO n-1 DO
        IF v.nodes[j].node = node.parent THEN
          NodeColorRGB(v, i, r, g, b); RGBToHex(r, g, b, hex);
          IF v.layout = LayoutRadial THEN
            WStr(rd, '<line x1="'); WInt(rd, pxArr[i]);
            WStr(rd, '" y1="'); WInt(rd, pyArr[i]);
            WStr(rd, '" x2="'); WInt(rd, pxArr[j]);
            WStr(rd, '" y2="'); WInt(rd, pyArr[j]);
            WStr(rd, '" stroke="'); WStr(rd, hex);
            WStr(rd, '" stroke-width="1.2"/>'); Files.Write(rd, 10)
          ELSE
            (* elbow *)
            WStr(rd, '<polyline points="');
            WInt(rd, pxArr[i]); WStr(rd, ','); WInt(rd, pyArr[i]);
            WStr(rd, ' ');
            WInt(rd, pxArr[j]); WStr(rd, ','); WInt(rd, pyArr[i]);
            WStr(rd, ' ');
            WInt(rd, pxArr[j]); WStr(rd, ','); WInt(rd, pyArr[j]);
            WStr(rd, '" fill="none" stroke="'); WStr(rd, hex);
            WStr(rd, '" stroke-width="1.2"/>'); Files.Write(rd, 10)
          END
        END
      END
    END
  END;

  (* Nodes *)
  FOR i := 0 TO n-1 DO
    node := v.nodes[i].node;
    NodeColorRGB(v, i, r, g, b); RGBToHex(r, g, b, hex);
    IF node.firstChild = NIL THEN
      WStr(rd, '<circle cx="'); WInt(rd, pxArr[i]);
      WStr(rd, '" cy="'); WInt(rd, pyArr[i]);
      WStr(rd, '" r="3" fill="'); WStr(rd, hex); WStr(rd, '"/>');
      Files.Write(rd, 10);
      IF Strings.Length(node.name) > 0 THEN
        WStr(rd, '<text x="'); WInt(rd, pxArr[i]+5);
        WStr(rd, '" y="'); WInt(rd, pyArr[i]+4);
        WStr(rd, '">'); WStr(rd, node.name); WStr(rd, '</text>');
        Files.Write(rd, 10)
      END
    ELSE
      WStr(rd, '<circle cx="'); WInt(rd, pxArr[i]);
      WStr(rd, '" cy="'); WInt(rd, pyArr[i]);
      WStr(rd, '" r="2" fill="'); WStr(rd, hex); WStr(rd, '"/>');
      Files.Write(rd, 10);
      IF v.showLabels & (Strings.Length(node.name) > 0) THEN
        WStr(rd, '<text x="'); WInt(rd, pxArr[i]+3);
        WStr(rd, '" y="'); WInt(rd, pyArr[i]-3);
        WStr(rd, '" style="fill:#aaa">'); WStr(rd, node.name); WStr(rd, '</text>');
        Files.Write(rd, 10)
      END
    END;
    (* Branch length label *)
    IF v.showBL & (node.branchLength > 0.0) & (node.parent # NIL) THEN
      FOR j := 0 TO n-1 DO
        IF v.nodes[j].node = node.parent THEN
          VAR blBuf: ARRAY 16 OF CHAR;
          BEGIN
            Strings.RealToStr(node.branchLength, blBuf); blBuf[6] := 0X;
            WStr(rd, '<text x="');
            WInt(rd, (pxArr[i]+pxArr[j]) DIV 2);
            WStr(rd, '" y="');
            WInt(rd, (pyArr[i]+pyArr[j]) DIV 2 - 2);
            WStr(rd, '" style="font-size:8px;fill:#888">');
            WStr(rd, blBuf); WStr(rd, '</text>'); Files.Write(rd, 10)
          END
        END
      END
    END
  END;

  WStr(rd, '</svg>'); Files.Write(rd, 10);
  Files.Register(f); Files.Close(f);
  Strings.Copy("SVG saved: ", statusMsg);
  Strings.Append(svgPath, statusMsg)
END SaveSVG;

(* ================================================================== *)
(*  Help popup                                                         *)
(* ================================================================== *)

PROCEDURE HelpLine(i: INTEGER; VAR s: ARRAY OF CHAR);
BEGIN
  CASE i OF
    0:  Strings.Copy("newickview  --  Phylogenetic Tree Viewer", s)
    | 1:  Strings.Copy("", s)
    | 2:  Strings.Copy("# Navigation", s)
    | 3:  Strings.Copy("  Arrow keys          Pan view", s)
    | 4:  Strings.Copy("  + / -               Zoom in / out", s)
    | 5:  Strings.Copy("  Scroll wheel        Zoom in / out", s)
    | 6:  Strings.Copy("", s)
    | 7:  Strings.Copy("# Layout  (L cycles)", s)
    | 8:  Strings.Copy("  Cladogram           Equal branch display", s)
    | 9:  Strings.Copy("  Phylogram           Proportional branch lengths", s)
    | 10: Strings.Copy("  Radial              Circular layout", s)
    | 11: Strings.Copy("", s)
    | 12: Strings.Copy("# Colour  (C cycles)", s)
    | 13: Strings.Copy("  Mono                All white", s)
    | 14: Strings.Copy("  Depth               Blue (shallow) -> Red (deep)", s)
    | 15: Strings.Copy("  Branch Length       Blue (short) -> Red (long)", s)
    | 16: Strings.Copy("  Clade               Each root-child subtree coloured", s)
    | 17: Strings.Copy("", s)
    | 18: Strings.Copy("# Rerooting", s)
    | 19: Strings.Copy("  R                   Reroot at selected node", s)
    | 20: Strings.Copy("  M                   Midpoint reroot", s)
    | 21: Strings.Copy("", s)
    | 22: Strings.Copy("# Labels", s)
    | 23: Strings.Copy("  S                   Toggle node / leaf labels", s)
    | 24: Strings.Copy("  B                   Toggle branch length labels", s)
    | 25: Strings.Copy("", s)
    | 26: Strings.Copy("# Selection", s)
    | 27: Strings.Copy("  LMB click           Select nearest node", s)
    | 28: Strings.Copy("  Esc                 Deselect", s)
    | 29: Strings.Copy("", s)
    | 30: Strings.Copy("# Files", s)
    | 31: Strings.Copy("  Ctrl+O              Open Newick file", s)
    | 32: Strings.Copy("  F5                  Reload current file", s)
    | 33: Strings.Copy("  V                   Save SVG snapshot", s)
    | 34: Strings.Copy("", s)
    | 35: Strings.Copy("  Ctrl+Q / Q          Quit", s)
    | 36: Strings.Copy("  F1                  This help screen", s)
  ELSE  s[0] := 0X
END
END HelpLine;

PROCEDURE DrawHelpWin(v: TUI.View);
VAR row, contentH, maxScroll, li: INTEGER; line: ARRAY 64 OF CHAR; fg: INTEGER;
BEGIN
  WITH v: TUI.WindowRec DO
    TUI.FillRect(v.x+1, v.y+1, v.w-2, v.h-2, ' ', TUI.White, TUI.Black);
    TUI.DrawBox(v.x, v.y, v.w, v.h, TUI.White, TUI.Blue);
    TUI.PutStr(v.x + (v.w-6) DIV 2, v.y, " Help ", TUI.Yellow, TUI.Blue);
    contentH := v.h - 3;
    FOR row := 0 TO contentH-1 DO
      li := helpScroll + row;
      IF li <= HelpN THEN
        HelpLine(li, line);
        IF line[0] = '#' THEN
          fg := TUI.Cyan;
          Strings.Extract(line, 2, Strings.Length(line)-2, line)
        ELSE fg := TUI.White
      END;
      IF line[0] # 0X THEN TUI.PutStr(v.x+2, v.y+1+row, line, fg, TUI.Black) END
    END
  END;
  TUI.FillRect(v.x+1, v.y+v.h-2, v.w-2, 1, ' ', TUI.Black, TUI.White);
  TUI.PutStr(v.x+2, v.y+v.h-2,
  "Up/Dn/PgUp/PgDn: scroll   Esc/Q/Enter: close", TUI.Black, TUI.White)
END
END DrawHelpWin;

PROCEDURE ShowHelp;
VAR ev: TUI.Event; ch: CHAR;
savedDesktop: TUI.View; savedFocus: TUI.View;
dw, dh, dx, dy, contentH, maxScroll: INTEGER;
BEGIN
  savedDesktop := TUI.Desktop; savedFocus := TUI.Focused;
  TUI.Desktop := NIL; TUI.Focused := NIL; helpScroll := 0;
  dw := 60; dh := 24;
  IF TUI.Cols-4 < dw THEN dw := TUI.Cols-4 END;
  IF TUI.Rows-4 < dh THEN dh := TUI.Rows-4 END;
  IF dw < 40 THEN dw := 40 END;
  IF dh < 10 THEN dh := 10 END;
  dx := (TUI.Cols-dw) DIV 2 + 1;
  dy := (TUI.Rows-dh) DIV 2 + 1;
  contentH := dh - 3;
  NEW(helpWin);
  helpWin.x:=dx; helpWin.y:=dy; helpWin.w:=dw; helpWin.h:=dh;
  helpWin.title[0]:=0X; helpWin.moveable:=FALSE;
  helpWin.draw:=DrawHelpWin; helpWin.handle:=NIL;
  helpWin.next:=NIL; helpWin.child:=NIL;
  helpWin.focused:=FALSE; helpWin.alwaysOnTop:=FALSE;
  TUI.AddView(helpWin);
  REPEAT
    TUI.ClearBack(TUI.White, TUI.Black);
    TUI.DrawAll(); TUI.Flush();
    TUI.WaitEvent(ev);
    IF ev.kind = TUI.EvKey THEN
      ch := ev.key;
      maxScroll := HelpN - contentH + 1;
      IF maxScroll < 0 THEN maxScroll := 0 END;
      IF (ch=TUI.KEsc) OR (ch='q') OR (ch='Q') OR (ch=TUI.KEnter) OR (ch=' ') THEN
        helpScroll := -1
      ELSIF ch=TUI.KUp   THEN IF helpScroll > 0        THEN DEC(helpScroll) END
    ELSIF ch=TUI.KDown THEN IF helpScroll < maxScroll THEN INC(helpScroll) END
  ELSIF ch=TUI.KPgUp THEN DEC(helpScroll, contentH); IF helpScroll<0 THEN helpScroll:=0 END
ELSIF ch=TUI.KPgDn THEN
  INC(helpScroll, contentH);
  IF helpScroll > maxScroll THEN helpScroll := maxScroll END
END
ELSIF ev.kind = TUI.EvMouse THEN
  maxScroll := HelpN - contentH + 1; IF maxScroll < 0 THEN maxScroll := 0 END;
  IF ev.mb = 64 THEN IF helpScroll > 0        THEN DEC(helpScroll) END
ELSIF ev.mb = 65 THEN IF helpScroll < maxScroll THEN INC(helpScroll) END
END
ELSIF ev.kind = TUI.EvResize THEN TUI.InvalidateFront()
END
UNTIL helpScroll < 0;
TUI.Desktop := savedDesktop; TUI.SetFocus(savedFocus)
END ShowHelp;

(* ================================================================== *)
(*  Menu command handler                                               *)
(* ================================================================== *)

PROCEDURE OnMenuCmd(cmd: INTEGER);
VAR path: ARRAY 1024 OF CHAR; ok: BOOLEAN;
BEGIN
  IF cmd = CmdOpen THEN
    ok := FileDialog.Show("Open Newick File", "", ".nwk;.newick;.tre;.tree;.phy", path);
    IF ok THEN LoadNewick(path) END
  ELSIF cmd = CmdReload THEN
    IF vw.loaded THEN LoadNewick(vw.filePath)
  ELSE Strings.Copy("No file to reload.", statusMsg) END
ELSIF cmd = CmdQuit THEN running := FALSE

ELSIF cmd = CmdLayCla THEN vw.layout := LayoutCladogram; BuildLayout(vw)
ELSIF cmd = CmdLayPhy THEN vw.layout := LayoutPhylogram; BuildLayout(vw)
ELSIF cmd = CmdLayRad THEN vw.layout := LayoutRadial;    BuildLayout(vw)

ELSIF cmd = CmdColMono THEN vw.colScheme := ColourMono
ELSIF cmd = CmdColDep  THEN vw.colScheme := ColourDepth
ELSIF cmd = CmdColBr   THEN vw.colScheme := ColourBranch
ELSIF cmd = CmdColCla  THEN vw.colScheme := ColourClade

ELSIF cmd = CmdReroot THEN
  IF vw.loaded & (vw.selectedNode # NIL) THEN
    Newick.RerootAtNode(vw.tree, vw.selectedNode);
    vw.selectedNode := NIL;
    vw.nodeCount := 0; vw.leafCount := 0;
    CountNodes(vw.tree.root, vw.nodeCount, vw.leafCount);
    IF vw.leafCount < 2 THEN vw.leafCount := 2 END;
    vw.maxDepth := MaxDepthOf(vw.tree.root, 0);
    vw.maxBL    := MaxBLOf(vw.tree.root, 0.0);
    BuildLayout(vw);
    Strings.Copy("Rerooted.", statusMsg)
  ELSIF vw.loaded THEN
    Strings.Copy("Select a node first (LMB click), then press R.", statusMsg)
  END

ELSIF cmd = CmdMidRoot THEN
  IF vw.loaded THEN
    Newick.MidpointRoot(vw.tree);
    vw.selectedNode := NIL;
    vw.nodeCount := 0; vw.leafCount := 0;
    CountNodes(vw.tree.root, vw.nodeCount, vw.leafCount);
    IF vw.leafCount < 2 THEN vw.leafCount := 2 END;
    vw.maxDepth := MaxDepthOf(vw.tree.root, 0);
    vw.maxBL    := MaxBLOf(vw.tree.root, 0.0);
    BuildLayout(vw);
    Strings.Copy("Midpoint rerooted.", statusMsg)
  END

ELSIF cmd = CmdTogLbl THEN vw.showLabels := ~vw.showLabels
ELSIF cmd = CmdTogBL  THEN vw.showBL    := ~vw.showBL
ELSIF cmd = CmdSaveSVG THEN SaveSVG(vw)
ELSIF cmd = CmdHelp    THEN ShowHelp()
END;
vw.sceneDirty := TRUE;
TUI.SetFocus(vw)
END OnMenuCmd;

(* ================================================================== *)
(*  Menu construction                                                  *)
(* ================================================================== *)

PROCEDURE BuildMenus;
BEGIN
  mbar := Widgets.NewMenuBar(1, 1, TUI.Cols);

  Widgets.MenuBarAddMenu(mbar, "File");
  Widgets.MenuBarAddItem(mbar, 0, "Open...    Ctrl+O", CmdOpen);
  Widgets.MenuBarAddItem(mbar, 0, "Reload     F5",     CmdReload);
  Widgets.MenuBarAddItem(mbar, 0, "Save SVG   V",      CmdSaveSVG);
  Widgets.MenuBarAddSep (mbar, 0);
  Widgets.MenuBarAddItem(mbar, 0, "Quit       Ctrl+Q", CmdQuit);

  Widgets.MenuBarAddMenu(mbar, "Layout");
  Widgets.MenuBarAddItem(mbar, 1, "Cladogram     (L)", CmdLayCla);
  Widgets.MenuBarAddItem(mbar, 1, "Phylogram     (L)", CmdLayPhy);
  Widgets.MenuBarAddItem(mbar, 1, "Radial        (L)", CmdLayRad);

  Widgets.MenuBarAddMenu(mbar, "Colour");
  Widgets.MenuBarAddItem(mbar, 2, "Monochrome    (C)", CmdColMono);
  Widgets.MenuBarAddItem(mbar, 2, "Depth         (C)", CmdColDep);
  Widgets.MenuBarAddItem(mbar, 2, "Branch Length (C)", CmdColBr);
  Widgets.MenuBarAddItem(mbar, 2, "Clade         (C)", CmdColCla);

  Widgets.MenuBarAddMenu(mbar, "Tree");
  Widgets.MenuBarAddItem(mbar, 3, "Reroot at selection  R", CmdReroot);
  Widgets.MenuBarAddItem(mbar, 3, "Midpoint reroot      M", CmdMidRoot);
  Widgets.MenuBarAddSep (mbar, 3);
  Widgets.MenuBarAddItem(mbar, 3, "Toggle labels        S", CmdTogLbl);
  Widgets.MenuBarAddItem(mbar, 3, "Toggle branch len    B", CmdTogBL);

  Widgets.MenuBarAddMenu(mbar, "Help");
  Widgets.MenuBarAddItem(mbar, 4, "Help  F1", CmdHelp);

  mbar.onCmd := OnMenuCmd;
  TUI.AddView(mbar);

  sline := Widgets.NewStatusLine(1, TUI.Rows, TUI.Cols, "");
  sline.alwaysOnTop := TRUE;
  TUI.AddView(sline)
END BuildMenus;

(* ================================================================== *)
(*  Main                                                               *)
(* ================================================================== *)

VAR ev: TUI.Event; ch: CHAR; arg: ARRAY 1024 OF CHAR; argI: INTEGER;

BEGIN
  TUI.Init();
  running := TRUE; statusMsg[0] := 0X;

  NEW(vw);
  vw.x:=1; vw.y:=2; vw.w:=TUI.Cols; vw.h:=TUI.Rows-2;
  vw.title[0]:=0X; vw.moveable:=FALSE;
  vw.draw:=DrawViewer; vw.handle:=HandleViewer;
  vw.next:=NIL; vw.child:=NIL;
  vw.focused:=FALSE; vw.alwaysOnTop:=FALSE;
  vw.tree:=NIL; vw.loaded:=FALSE; vw.filePath[0]:=0X;
  vw.sceneDirty:=TRUE;
  vw.layout:=LayoutCladogram; vw.colScheme:=ColourClade;
  vw.showLabels:=TRUE; vw.showBL:=FALSE;
  vw.zoom:=1.0; vw.panX:=0; vw.panY:=0;
  vw.selectedNode:=NIL; vw.hoveredNode:=NIL;
  vw.nNodes:=0; vw.nodeCount:=0; vw.leafCount:=0;
  vw.maxDepth:=0; vw.maxBL:=0.0;

  BuildMenus();
  TUI.AddView(vw); TUI.SetFocus(vw);

  argI := 1;
  WHILE argI <= Args.Count() DO
    Args.Get(argI, arg);
    IF arg[0] # '-' THEN LoadNewick(arg) END;
    INC(argI)
  END;

  WHILE running DO
    UpdateStatus();
    TUI.ClearBack(TUI.White, TUI.Black);
    TUI.DrawAll();
    TUI.InvalidateFront();
    TUI.Flush();

    IF vw.sceneDirty THEN
      RenderScene(vw); vw.sceneDirty := FALSE
    ELSE
      Terminal.Flush()
    END;

    Terminal.HideCursor();
    TUI.WaitEvent(ev);

    IF (ev.kind = TUI.EvKey) OR
    ((ev.kind = TUI.EvMouse) & (ev.mb # 32) & (ev.mb # 3)) THEN
      statusMsg[0] := 0X
    END;

    IF ev.kind = TUI.EvKey THEN
      ch := ev.key;
      IF    ORD(ch) = 15 THEN OnMenuCmd(CmdOpen)        (* Ctrl+O *)
    ELSIF ORD(ch) = 17 THEN running := FALSE           (* Ctrl+Q *)
  ELSIF ch = 'Q'     THEN running := FALSE
ELSIF ch = TUI.KF1 THEN OnMenuCmd(CmdHelp)
ELSIF ch = TUI.KF5 THEN OnMenuCmd(CmdReload)
ELSE IF ~TUI.Dispatch(ev) THEN END
END
ELSIF ev.kind = TUI.EvMouse THEN
  IF ~TUI.Dispatch(ev) THEN END
ELSIF ev.kind = TUI.EvResize THEN
  sline.y := TUI.Rows; sline.w := TUI.Cols;
  mbar.w  := TUI.Cols;
  vw.w    := TUI.Cols; vw.h := TUI.Rows-2;
  BuildLayout(vw);
  TUI.InvalidateFront()
END
END;

TUI.Done()
END newickview.

