MODULE ZapfAst;
(*
  ZapfAst — the parsed-line AST for ZAP source, ported from the many small
  classes under Zapf.Parsing.Directives plus Instruction/LocalLabel/GlobalLabel.

  Rather than one C# class per directive, every parsed source line is one
  tagged "Line" record; `kind` says which directive/instruction/label it is
  and which of the generic fields below are meaningful for it (documented
  per constant below). Debug directives (dot-DEBUG dash names) all collapse to LkNull:
  the parser still consumes their exact grammar (so it doesn't desync the
  following lines) but does not preserve their contents, since debug-file
  output is out of scope for this port.
*)

IMPORT ZapfExpr;

CONST
  (* plain lines *)
  LkNull*      = 0;   (* no-op: .END/.ENDI/.ENDT/.SOUND/.TIME/.VOCEND, ignored directives, debug directives, .FORM/.OPERAND parse-error fallback *)
  LkInstr*     = 1;   (* name=mnemonic; operands=exprList; storeTarget; hasBranch/branchPolarity/branchTarget *)
  LkLocalLbl*  = 2;   (* name *)
  LkGlobalLbl* = 3;   (* name *)
  LkBareSym*   = 4;   (* name=text; bareOperandCount; bareHasStore; bareHasBranch *)

  (* directives *)
  LkAlign*   = 10;  (* exprA = divisor *)
  LkByte*    = 11;  (* exprList = elements *)
  LkWord*    = 12;  (* exprList = elements *)
  LkChrset*  = 13;  (* exprA = alphabet num; exprList = characters *)
  LkCreator* = 14;  (* text *)
  LkEnd*     = 15;
  LkEndi*    = 16;
  LkEndt*    = 17;
  LkEquals*  = 18;  (* name; exprA = value *)
  LkForm*    = 19;  (* text = form specifier *)
  LkFstr*    = 20;  (* name; text *)
  LkFunct*   = 21;  (* name; locals = funct-local list *)
  LkGstr*    = 22;  (* name; text *)
  LkGvar*    = 23;  (* name; exprA = initial value (may be NIL) *)
  LkInsert*  = 24;  (* text = filename *)
  LkLang*    = 25;  (* exprA = langId; exprB = escapeChar *)
  LkLen*     = 26;  (* text *)
  LkNew*     = 27;  (* exprA = version (may be NIL) *)
  LkObject*  = 28;  (* name; exprA..exprG = flags1,flags2,flags3(NIL ok),parent,sibling,child,propTable *)
  LkOperand* = 29;  (* exprA = index; text = encoding specifier *)
  LkProp*    = 30;  (* exprA = size; exprB = prop *)
  LkSound*   = 31;
  LkStr*     = 32;  (* text *)
  LkStrl*    = 33;  (* text *)
  LkTable*   = 34;  (* exprA = size (may be NIL) *)
  LkTime*    = 35;
  LkUnichr*  = 36;  (* text *)
  LkVocbeg*  = 37;  (* exprA = recordSize; exprB = keySize *)
  LkVocend*  = 38;
  LkZword*   = 39;  (* text *)

TYPE
  ExprNode* = POINTER TO ExprNodeDesc;
  ExprNodeDesc* = RECORD
    e*: ZapfExpr.Expr;
    next*: ExprNode
  END;

  ExprList* = RECORD
    head*, tail*: ExprNode;
    count*: INTEGER
  END;

  FunctLocalNode* = POINTER TO FunctLocalDesc;
  FunctLocalDesc* = RECORD
    name*: ARRAY 64 OF CHAR;
    defaultVal*: ZapfExpr.Expr;   (* NIL if none given *)
    next*: FunctLocalNode
  END;

  Line* = POINTER TO LineDesc;
  LineDesc* = RECORD
    kind*: INTEGER;
    sourceFile*: ARRAY 256 OF CHAR;
    lineNum*: INTEGER;
    next*: Line;

    name*: ARRAY 80 OF CHAR;
    text*: ARRAY 2048 OF CHAR;

    exprA*, exprB*, exprC*, exprD*, exprE*, exprF*, exprG*: ZapfExpr.Expr;

    exprList*: ExprList;
    locals*: FunctLocalNode;
    localsTail*: FunctLocalNode;

    storeTarget*: ARRAY 80 OF CHAR;   (* "" = none *)
    hasBranch*: BOOLEAN;
    branchPolarity*: BOOLEAN;
    branchTarget*: ARRAY 80 OF CHAR;

    bareOperandCount*: INTEGER;
    bareHasStore*: BOOLEAN;
    bareHasBranch*: BOOLEAN
  END;

PROCEDURE NewLine*(kind: INTEGER): Line;
VAR l: Line;
BEGIN
  NEW(l);
  l.kind := kind;
  l.sourceFile[0] := 0X;
  l.lineNum := 0;
  l.next := NIL;
  l.name[0] := 0X;
  l.text[0] := 0X;
  l.exprA := NIL; l.exprB := NIL; l.exprC := NIL; l.exprD := NIL;
  l.exprE := NIL; l.exprF := NIL; l.exprG := NIL;
  l.exprList.head := NIL; l.exprList.tail := NIL; l.exprList.count := 0;
  l.locals := NIL; l.localsTail := NIL;
  l.storeTarget[0] := 0X;
  l.hasBranch := FALSE;
  l.branchPolarity := FALSE;
  l.branchTarget[0] := 0X;
  l.bareOperandCount := 0;
  l.bareHasStore := FALSE;
  l.bareHasBranch := FALSE;
  RETURN l
END NewLine;

PROCEDURE AddExpr*(VAR list: ExprList; e: ZapfExpr.Expr);
VAR n: ExprNode;
BEGIN
  NEW(n);
  n.e := e;
  n.next := NIL;
  IF list.head = NIL THEN list.head := n ELSE list.tail.next := n END;
  list.tail := n;
  INC(list.count)
END AddExpr;

PROCEDURE AddLocal*(l: Line; name: ARRAY OF CHAR; defaultVal: ZapfExpr.Expr);
VAR n: FunctLocalNode;
BEGIN
  NEW(n);
  COPY(name, n.name);
  n.defaultVal := defaultVal;
  n.next := NIL;
  IF l.locals = NIL THEN l.locals := n ELSE l.localsTail.next := n END;
  l.localsTail := n
END AddLocal;

(* ---- Line list (parser output / assembler input) ---- *)

TYPE
  LineList* = RECORD
    head*, tail*: Line;
    count*: INTEGER
  END;

PROCEDURE InitList*(VAR ll: LineList);
BEGIN
  ll.head := NIL; ll.tail := NIL; ll.count := 0
END InitList;

PROCEDURE Append*(VAR ll: LineList; l: Line);
BEGIN
  IF ll.head = NIL THEN ll.head := l ELSE ll.tail.next := l END;
  ll.tail := l;
  INC(ll.count)
END Append;

END ZapfAst.
