MODULE Newick;

IMPORT Out, Strings, Files, Math;

TYPE
    Node* = POINTER TO NodeRec;
    NodeRec* = RECORD
        name*: ARRAY 64 OF CHAR;
        branchLength*: REAL;
        parent*: Node;
        firstChild*: Node;
        nextSibling*: Node;
    END;

    Tree* = POINTER TO TreeRec;
    TreeRec* = RECORD
        root*: Node;
    END;

VAR
    parsePos: INTEGER;
    parseStr: ARRAY 1024 OF CHAR;

PROCEDURE CreateNode*(): Node;
    VAR n: Node;
BEGIN
    NEW(n);
    n.name[0] := 0X;
    n.branchLength := 0.0;
    n.parent := NIL;
    n.firstChild := NIL;
    n.nextSibling := NIL;
    RETURN n;
END CreateNode;

PROCEDURE FreeNode(VAR n: Node);
    VAR child, next: Node;
BEGIN
    IF n # NIL THEN
        child := n.firstChild;
        WHILE child # NIL DO
            next := child.nextSibling;
            FreeNode(child);
            child := next;
        END;
        FREE(n);
    END;
END FreeNode;

PROCEDURE FreeTree*(VAR t: Tree);
BEGIN
    IF t # NIL THEN
        FreeNode(t.root);
        FREE(t);
    END;
END FreeTree;

PROCEDURE AddChild*(parent: Node; child: Node);
    VAR p: Node;
BEGIN
    child.parent := parent;
    IF parent.firstChild = NIL THEN
        parent.firstChild := child;
    ELSE
        p := parent.firstChild;
        WHILE p.nextSibling # NIL DO
            p := p.nextSibling;
        END;
        p.nextSibling := child;
    END;
END AddChild;

PROCEDURE RemoveChild(parent: Node; child: Node);
    VAR p: Node;
BEGIN
    IF (parent = NIL) OR (parent.firstChild = NIL) THEN RETURN END;

    IF parent.firstChild = child THEN
        parent.firstChild := child.nextSibling;
    ELSE
        p := parent.firstChild;
        WHILE (p.nextSibling # NIL) & (p.nextSibling # child) DO
            p := p.nextSibling;
        END;
        IF p.nextSibling = child THEN
            p.nextSibling := child.nextSibling;
        END;
    END;
    child.parent := NIL;
    child.nextSibling := NIL;
END RemoveChild;

PROCEDURE SetAllParents(n, p: Node);
    VAR c: Node;
BEGIN
    IF n = NIL THEN RETURN END;
    n.parent := p;
    c := n.firstChild;
    WHILE c # NIL DO
        SetAllParents(c, n);
        c := c.nextSibling;
    END;
END SetAllParents;

(* -------------------- PARSING -------------------- *)

PROCEDURE ParseRecursive(): Node;
    VAR n, child: Node;
        nameBuf, lenBuf: ARRAY 64 OF CHAR;
        start, len: INTEGER;
        dummy: BOOLEAN;
BEGIN
    n := NIL;
    IF (parsePos < Strings.Length(parseStr)) & (parseStr[parsePos] = '(') THEN
        INC(parsePos);
        n := CreateNode();
        LOOP
            child := ParseRecursive();
            IF child = NIL THEN EXIT END;
            AddChild(n, child);
            IF (parsePos < Strings.Length(parseStr)) & (parseStr[parsePos] = ',') THEN
                INC(parsePos);
            ELSE
                EXIT;
            END;
        END;
        IF (parsePos < Strings.Length(parseStr)) & (parseStr[parsePos] = ')') THEN
            INC(parsePos);
        ELSE
            RETURN NIL;
        END;
    END;

    start := parsePos;
    WHILE (parsePos < Strings.Length(parseStr)) & (parseStr[parsePos] # ':') & (parseStr[parsePos] # ',') & (parseStr[parsePos] # ')') & (parseStr[parsePos] # ';') DO
        INC(parsePos);
    END;
    len := parsePos - start;
    IF len > 0 THEN
        Strings.Extract(parseStr, start, len, nameBuf);
        IF n = NIL THEN n := CreateNode() END;
        Strings.Copy(nameBuf, n.name);
    END;

    IF (parsePos < Strings.Length(parseStr)) & (parseStr[parsePos] = ':') THEN
        INC(parsePos);
        start := parsePos;
        WHILE (parsePos < Strings.Length(parseStr)) & (parseStr[parsePos] # ',') & (parseStr[parsePos] # ')') & (parseStr[parsePos] # ';') DO
            INC(parsePos);
        END;
        len := parsePos - start;
        IF len > 0 THEN
            Strings.Extract(parseStr, start, len, lenBuf);
            dummy := Strings.StrToReal(lenBuf, n.branchLength);
        END;
    END;
    RETURN n;
END ParseRecursive;

PROCEDURE Parse*(newickStr: ARRAY OF CHAR): Tree;
    VAR t: Tree;
BEGIN
    NEW(t);
    Strings.Copy(newickStr, parseStr);
    parsePos := 0;
    t.root := ParseRecursive();
    IF (t.root # NIL) THEN
        SetAllParents(t.root, NIL);
    END;
    RETURN t;
END Parse;

PROCEDURE Load*(filename: ARRAY OF CHAR): Tree;
    VAR f: Files.File; r: Files.Rider; size: INTEGER; content: ARRAY 1024 OF CHAR;
BEGIN
    f := Files.Old(filename);
    IF f = NIL THEN RETURN NIL END;
    size := Files.Length(f);
    IF size > LEN(content)-1 THEN Files.Close(f); RETURN NIL; END;
    Files.Set(r, f, 0); Files.ReadString(r, content); Files.Close(f);
    RETURN Parse(content);
END Load;

(* -------------------- WRITING -------------------- *)

PROCEDURE WriteNode(r: Files.Rider; n: Node);
    VAR child: Node; tempStr: ARRAY 32 OF CHAR;
BEGIN
    IF n = NIL THEN RETURN END;
    IF n.firstChild # NIL THEN
        Files.Write(r, '(');
        child := n.firstChild;
        WHILE child # NIL DO
            WriteNode(r, child);
            child := child.nextSibling;
            IF child # NIL THEN Files.Write(r, ',') END;
        END;
        Files.Write(r, ')');
    END;
    IF Strings.Length(n.name) > 0 THEN Files.WriteString(r, n.name) END;
    IF n.branchLength > 0.0 THEN
        Files.Write(r, ':');
        Strings.RealToStr(n.branchLength, tempStr);
        Files.WriteString(r, tempStr);
    END;
END WriteNode;

PROCEDURE Write*(t: Tree; filename: ARRAY OF CHAR): BOOLEAN;
    VAR f: Files.File; r: Files.Rider;
BEGIN
    IF (t = NIL) OR (t.root = NIL) THEN RETURN FALSE END;
    f := Files.New(filename);
    IF f = NIL THEN RETURN FALSE END;
    Files.Set(r, f, 0); WriteNode(r, t.root); Files.Write(r, ';'); Files.Close(f);
    RETURN TRUE;
END Write;

(* -------------------- MANIPULATION & QUERY -------------------- *)

PROCEDURE FindNodeByNameRecursive(n: Node; name: ARRAY OF CHAR): Node;
    VAR found, child: Node;
BEGIN
    IF n = NIL THEN RETURN NIL END;
    IF Strings.Compare(n.name, name) = 0 THEN RETURN n END;
    child := n.firstChild;
    WHILE child # NIL DO
        found := FindNodeByNameRecursive(child, name);
        IF found # NIL THEN RETURN found END;
        child := child.nextSibling;
    END;
    RETURN NIL;
END FindNodeByNameRecursive;

PROCEDURE FindNodeByName*(t: Tree; name: ARRAY OF CHAR): Node;
BEGIN
    IF (t = NIL) OR (t.root = NIL) THEN RETURN NIL END;
    RETURN FindNodeByNameRecursive(t.root, name);
END FindNodeByName;

PROCEDURE RerootAtNode*(VAR t: Tree; targetNode: Node);
    VAR p, c: Node; oldBranchLength: REAL;
BEGIN
    IF (t = NIL) OR (targetNode = NIL) OR (targetNode = t.root) THEN RETURN END;
    
    c := targetNode;
    oldBranchLength := c.branchLength;

    WHILE c.parent # NIL DO
        p := c.parent;
        RemoveChild(p, c);
        AddChild(c, p);
        p.branchLength := oldBranchLength;
        oldBranchLength := c.branchLength;
    END;
    
    targetNode.parent := NIL;
    targetNode.branchLength := 0.0;
    t.root := targetNode;
END RerootAtNode;

PROCEDURE FarthestLeaf(startNode, ignoreNode: Node; VAR maxDist: REAL; VAR leaf: Node);
    VAR qNode: ARRAY 256 OF Node;
        qDist: ARRAY 256 OF REAL;
        qFrom: ARRAY 256 OF Node;
        head, tail: INTEGER;
        currNode, fromNode, child: Node;
        currDist: REAL;
BEGIN
    maxDist := -1.0; leaf := NIL;
    head := 0; tail := 0;
    
    qNode[tail] := startNode;
    qDist[tail] := 0.0;
    qFrom[tail] := ignoreNode;
    INC(tail);

    WHILE head # tail DO
        currNode := qNode[head];
        currDist := qDist[head];
        fromNode := qFrom[head];
        INC(head);

        IF currNode.firstChild = NIL THEN (* Is a leaf *)
            IF currDist > maxDist THEN
                maxDist := currDist;
                leaf := currNode;
            END;
        END;

        (* Enqueue parent *)
        IF (currNode.parent # NIL) & (currNode.parent # fromNode) THEN
            qNode[tail] := currNode.parent;
            qDist[tail] := currDist + currNode.branchLength;
            qFrom[tail] := currNode;
            INC(tail);
        END;

        (* Enqueue children *)
        child := currNode.firstChild;
        WHILE child # NIL DO
            IF (child # fromNode) THEN
                qNode[tail] := child;
                qDist[tail] := currDist + child.branchLength;
                qFrom[tail] := currNode;
                INC(tail);
            END;
            child := child.nextSibling;
        END;
    END;
END FarthestLeaf;

PROCEDURE MidpointRoot*(VAR t: Tree);
    VAR leaf1, leaf2, p, c, newRoot: Node;
        dist, d1, d2, totalDist, pos: REAL;
BEGIN
    IF (t = NIL) OR (t.root = NIL) OR (t.root.firstChild = NIL) THEN RETURN END;
    
    SetAllParents(t.root, NIL);
    
    FarthestLeaf(t.root, NIL, dist, leaf1);
    IF leaf1 = NIL THEN RETURN END;
    
    FarthestLeaf(leaf1, NIL, totalDist, leaf2);
    IF leaf2 = NIL THEN RETURN END;

    pos := 0.0;
    c := leaf2;
    LOOP
        p := c.parent;
        IF (p = NIL) OR (pos + c.branchLength >= totalDist / 2.0) THEN EXIT END;
        pos := pos + c.branchLength;
        c := p;
    END;
    p := c.parent;
    
    IF p = NIL THEN RETURN END;

    d1 := (totalDist / 2.0) - pos;
    d2 := c.branchLength - d1;
    
    newRoot := CreateNode();
    RemoveChild(p, c);
    AddChild(p, newRoot);
    newRoot.branchLength := d1;
    
    AddChild(newRoot, c);
    c.branchLength := d2;
    
    RerootAtNode(t, newRoot);
END MidpointRoot;

(* -------------------- SVG RENDERING -------------------- *)
CONST
    SVGPad = 20; SVGCharWidth = 8; SVGLineHeight = 20;

PROCEDURE WriteSVGHeader(r: Files.Rider; w, h: INTEGER);
    VAR s: ARRAY 128 OF CHAR;
BEGIN
    Files.WriteString(r, '<svg width="'); Strings.IntToStr(w, s); Files.WriteString(r, s);
    Files.WriteString(r, '" height="'); Strings.IntToStr(h, s); Files.WriteString(r, s);
    Files.WriteString(r, '" xmlns="http://www.w3.org/2000/svg"><style>.label{font: 12px sans-serif;}</style>');
END WriteSVGHeader;

PROCEDURE WriteSVGLine(r: Files.Rider; x1, y1, x2, y2: INTEGER);
    VAR s: ARRAY 64 OF CHAR;
BEGIN
    Files.WriteString(r, '<line x1="'); Strings.IntToStr(x1, s); Files.WriteString(r, s);
    Files.WriteString(r, '" y1="'); Strings.IntToStr(y1, s); Files.WriteString(r, s);
    Files.WriteString(r, '" x2="'); Strings.IntToStr(x2, s); Files.WriteString(r, s);
    Files.WriteString(r, '" y2="'); Strings.IntToStr(y2, s); Files.WriteString(r, s);
    Files.WriteString(r, '" stroke="black" />');
END WriteSVGLine;

PROCEDURE WriteSVGText(r: Files.Rider; x, y: INTEGER; text: ARRAY OF CHAR);
    VAR s: ARRAY 64 OF CHAR;
BEGIN
    Files.WriteString(r, '<text x="'); Strings.IntToStr(x, s); Files.WriteString(r, s);
    Files.WriteString(r, '" y="'); Strings.IntToStr(y, s); Files.WriteString(r, s);
    Files.WriteString(r, '" class="label">'); Files.WriteString(r, text); Files.WriteString(r, '</text>');
END WriteSVGText;

PROCEDURE DrawNodeSVG(r: Files.Rider; n: Node; x: INTEGER; VAR y: INTEGER; scale: REAL; VAR maxX: INTEGER);
    VAR nX, nY, childYMid: INTEGER; firstChildY, lastChildY: INTEGER; child: Node;
BEGIN
    nX := x + FLOOR(n.branchLength * scale + 0.5);
    IF nX > maxX THEN maxX := nX END;
    IF n.firstChild = NIL THEN
        nY := y; WriteSVGLine(r, x, nY, nX, nY);
        WriteSVGText(r, nX + 5, nY + 4, n.name);
        IF nX + 5 + Strings.Length(n.name) * SVGCharWidth > maxX THEN
            maxX := nX + 5 + Strings.Length(n.name) * SVGCharWidth;
        END;
        INC(y, SVGLineHeight);
    ELSE
        child := n.firstChild; firstChildY := y;
        WHILE child # NIL DO DrawNodeSVG(r, child, nX, y, scale, maxX); child := child.nextSibling; END;
        lastChildY := y - SVGLineHeight; nY := (firstChildY + lastChildY) DIV 2;
        WriteSVGLine(r, x, nY, nX, nY); WriteSVGLine(r, nX, firstChildY, nX, lastChildY);
    END;
END DrawNodeSVG;

PROCEDURE GetTreeDims(n: Node; d: REAL; VAR maxD: REAL; VAR leaves: INTEGER);
    VAR c: Node; currD: REAL;
BEGIN
    currD := d + n.branchLength;
    IF currD > maxD THEN maxD := currD END;
    IF n.firstChild = NIL THEN INC(leaves);
    ELSE c := n.firstChild; WHILE c # NIL DO GetTreeDims(c, currD, maxD, leaves); c := c.nextSibling; END;
    END;
END GetTreeDims;

PROCEDURE RenderSVG*(t: Tree; filename: ARRAY OF CHAR): BOOLEAN;
    VAR f: Files.File; r: Files.Rider;
        maxD: REAL; leaves, svgW, svgH, y, maxX: INTEGER; scale: REAL;
BEGIN
    IF (t = NIL) OR (t.root = NIL) THEN RETURN FALSE END;
    maxD := 0.0; leaves := 0; GetTreeDims(t.root, 0.0, maxD, leaves);
    IF leaves = 0 THEN leaves := 1 END;
    svgH := leaves * SVGLineHeight + 2 * SVGPad;
    
    f := Files.New(filename); IF f = NIL THEN RETURN FALSE END; Files.Set(r, f, 0);

    svgW := 800;
    IF maxD > 0 THEN scale := (svgW - 2 * SVGPad - 150) / maxD ELSE scale := 1.0 END;
    y := SVGPad; maxX := 0;
    DrawNodeSVG(r, t.root, SVGPad, y, scale, maxX);
    svgW := maxX + SVGPad;
    
    Files.Close(f); f := Files.New(filename); Files.Set(r, f, 0);

    WriteSVGHeader(r, svgW, svgH);
    y := SVGPad; maxX := 0;
    DrawNodeSVG(r, t.root, SVGPad, y, scale, maxX);
    Files.WriteString(r, '</svg>');
    Files.Close(f);
    RETURN TRUE;
END RenderSVG;

END Newick.
