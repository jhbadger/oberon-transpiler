MODULE testnewick;

IMPORT Out, Strings, Newick;

PROCEDURE TestParsing;
VAR t: Newick.Tree;
root, child1, child2, grandchild: Newick.Node;
testStr: ARRAY 256 OF CHAR;
BEGIN
  Out.String("Running Test: Parsing... ");
  testStr := "((A:0.1,B:0.2):0.3,C:0.4);";
  t := Newick.Parse(testStr);

  ASSERT(t # NIL);
  root := t.root;
  ASSERT(root # NIL);
  ASSERT(root.parent = NIL);
  ASSERT(root.branchLength = 0.0);
    
  (* Root should have two children: the internal node (A,B) and the leaf C *)
  child1 := root.firstChild;
  ASSERT(child1 # NIL);
  child2 := child1.nextSibling;
  ASSERT(child2 # NIL);
  ASSERT(child2.nextSibling = NIL);

  (* Check internal node (A,B) *)
  ASSERT(child1.branchLength > 0.29);
  ASSERT(child1.branchLength < 0.31); (* 0.3 *)
  ASSERT(Strings.Length(child1.name) = 0); (* Internal node has no name *)

  (* Check leaf C *)
  ASSERT(Strings.Compare(child2.name, "C") = 0);
  ASSERT(child2.branchLength > 0.39);
  ASSERT(child2.branchLength < 0.41); (* 0.4 *)

  (* Check grandchildren A and B *)
  grandchild := child1.firstChild;
  ASSERT(grandchild # NIL);
  ASSERT(Strings.Compare(grandchild.name, "A") = 0);
  ASSERT(grandchild.branchLength > 0.09);
  ASSERT(grandchild.branchLength < 0.11); (* 0.1 *)

  grandchild := grandchild.nextSibling;
  ASSERT(grandchild # NIL);
  ASSERT(Strings.Compare(grandchild.name, "B") = 0);
  ASSERT(grandchild.branchLength > 0.19);
  ASSERT(grandchild.branchLength < 0.21); (* 0.2 *)

  Newick.FreeTree(t);
  Out.String("OK"); Out.Ln;
END TestParsing;

PROCEDURE TestNodeFinding;
VAR t: Newick.Tree;
nodeA, nodeC, nodeD: Newick.Node;
testStr: ARRAY 256 OF CHAR;
BEGIN
  Out.String("Running Test: Node Finding... ");
  testStr := "((A:0.1,B:0.2):0.3,C:0.4);";
  t := Newick.Parse(testStr);

  nodeA := Newick.FindNodeByName(t, "A");
  ASSERT(nodeA # NIL);
  ASSERT(Strings.Compare(nodeA.name, "A") = 0);

  nodeC := Newick.FindNodeByName(t, "C");
  ASSERT(nodeC # NIL);
  ASSERT(Strings.Compare(nodeC.name, "C") = 0);
  ASSERT(nodeC.branchLength > 0.39);
  ASSERT(nodeC.branchLength < 0.41);

  nodeD := Newick.FindNodeByName(t, "D");
  ASSERT(nodeD = NIL);

  Newick.FreeTree(t);
  Out.String("OK"); Out.Ln;
END TestNodeFinding;

PROCEDURE TestRerooting;
VAR t: Newick.Tree;
nodeB, oldRoot, newParent: Newick.Node;
testStr: ARRAY 256 OF CHAR;
BEGIN
  Out.String("Running Test: Rerooting at Node... ");
  testStr := "((A:0.1,B:0.2):0.3,C:0.4);";
  t := Newick.Parse(testStr);

  nodeB := Newick.FindNodeByName(t, "B");
  ASSERT(nodeB # NIL);

  Newick.RerootAtNode(t, nodeB);

  (* B should now be the root *)
  ASSERT(t.root = nodeB);
  ASSERT(nodeB.parent = NIL);
  ASSERT(nodeB.branchLength = 0.0);

  Newick.FreeTree(t);
  Out.String("OK"); Out.Ln;
END TestRerooting;

PROCEDURE TestMidpointRooting;
VAR t: Newick.Tree;
root, child1, child2: Newick.Node;
testStr: ARRAY 256 OF CHAR;
BEGIN
  Out.String("Running Test: Midpoint Rooting... ");
  (* Longest path is A to C, length 10+2 = 12. Midpoint is at dist 6 from A. *)
  (* This will split the A branch (length 10) into two branches of length 6 and 4. *)
  testStr := "((A:10,B:2),C:2);";
  t := Newick.Parse(testStr);

  Newick.MidpointRoot(t);
  root := t.root;

  (* The new root should be an unnamed internal node with two children *)
  ASSERT(root # NIL);
  ASSERT(root.branchLength = 0.0);
  ASSERT(Strings.Length(root.name) = 0);
  child1 := root.firstChild;
  child2 := child1.nextSibling;
  ASSERT(child1 # NIL);
  ASSERT(child2 # NIL);

  (* One child is the original root, the other is leaf A *)
  (* Path to A should have length 6 *)
  IF Strings.Compare(child1.name, "A") = 0 THEN
    ASSERT(child1.branchLength > 5.9);
    ASSERT(child1.branchLength < 6.1);
    ASSERT(child2.branchLength > 3.9);
    ASSERT(child2.branchLength < 4.1);
  ELSE
    ASSERT(Strings.Compare(child2.name, "A") = 0);
    ASSERT(child2.branchLength > 5.9);
    ASSERT(child2.branchLength < 6.1);
    ASSERT(child1.branchLength > 3.9);
    ASSERT(child1.branchLength < 4.1);
  END;

  Newick.FreeTree(t);
  Out.String("OK"); Out.Ln;
END TestMidpointRooting;

BEGIN
  TestParsing;
  TestNodeFinding;
  TestRerooting;
  TestMidpointRooting;
  Out.String("-------------------------"); Out.Ln;
  Out.String("All Newick tests passed."); Out.Ln;
END testnewick.



