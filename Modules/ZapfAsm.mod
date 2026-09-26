MODULE ZapfAsm;
(*
  ZapfAsm — assembler engine, ported from Zapf/Context.cs, Symbol.cs,
  Fixup.cs, SymbolType.cs, ZapfAssembler.cs, and (for the parts marked
  TODO below) Zapf/Program.cs.

  Design differences from the C# original, all behavior-preserving:
  - The whole story file is built in one in-memory byte buffer (buf) rather
    than through a seekable file stream; it is written out once at the end.
    This replaces Context.stream/prevStream/Position-as-seek with plain
    array indexing, which is simpler and behaviorally identical (nothing
    in the original relies on real file-system semantics beyond "seek and
    (re)write a byte range", which array indexing already gives for free).
  - No exceptions: SeriousError becomes "increment errorCount, print, set
    ctx.abortLine so the per-line dispatch loop moves to the next source
    line" (mirroring ZapfParser's p.fatal, but scoped per assembled line
    rather than per token); FatalError becomes an immediate print+HALT(2).
  - Debug-file output (XmlDebugFileWriter/BinaryDebugFileWriter) is out of
    scope; DebugWriter-related fields/calls from the original are omitted
    entirely rather than stubbed.
*)

IMPORT ZapfAst, ZapfExpr, ZapfOpcodes, ZapfZChar, ZapfParser, ZapfTok, Files, Strings, Out, Time;

CONST
  (* SymbolType *)
  SymUnknown*  = 0;
  SymConstant* = 1;
  SymVariable* = 2;
  SymLabel*    = 3;
  SymFunction* = 4;
  SymString*   = 5;
  SymObject*   = 6;

  NumBuckets = 2048;
  MaxStory = 1310720;      (* 1.25 MB - comfortably above any real Z-machine story file *)
  MaxVocabScratch = 131072;
  MaxFileStack = 16;
  MaxLines* = 200000;

TYPE
  Symbol* = POINTER TO SymbolDesc;
  SymbolDesc* = RECORD
    name*: ARRAY 80 OF CHAR;
    kind*: INTEGER;
    value*: INTEGER;
    phantom*: BOOLEAN;
    hnext: Symbol;
    lnext: Symbol   (* used only when chained into ctx.localHead *)
  END;

  Fixup* = POINTER TO FixupDesc;
  FixupDesc* = RECORD
    symName*: ARRAY 80 OF CHAR;
    location*: INTEGER;
    next*: Fixup
  END;

  Context* = POINTER TO ContextDesc;
  ContextDesc* = RECORD
    (* ---- configuration (set once, untouched by Restart/ResetBetweenPasses) ---- *)
    quiet*, informMode*, listAddresses*: BOOLEAN;
    inFile*, outFile*: ARRAY 512 OF CHAR;
    creator*: ARRAY 16 OF CHAR;
    creatorSpecified*, noCreator*: BOOLEAN;
    serial*: ARRAY 8 OF CHAR;
    serialSpecified*: BOOLEAN;
    zversion*: INTEGER;
    zflags*, zflags2*: INTEGER;
    release*: INTEGER;
    releaseSpecified*: BOOLEAN;

    (* ---- per-attempt state, reset by RestartContext ---- *)
    errorCount*, warningCount*: INTEGER;
    globalBuckets: ARRAY NumBuckets OF Symbol;
    localHead: Symbol;
    fixups*, fixupsTail: Fixup;
    fileStack: ARRAY MaxFileStack OF ARRAY 512 OF CHAR;
    fileStackDepth: INTEGER;
    languageEscapeChar*: INTEGER;              (* -1 = none *)
    langFrom, langTo: ARRAY 16 OF INTEGER;
    langCount: INTEGER;
    pendingForm*: ARRAY 24 OF CHAR;
    hasPendingForm*: BOOLEAN;
    pendingOpEnc: ARRAY 9 OF INTEGER;    (* index 1..8; -1 = not forced *)
    hasPendingOpEnc: BOOLEAN;
    tableStart, tableSize: INTEGER;      (* -1 = none / not tracking *)
    unicodeCodepoints: ARRAY 97 OF INTEGER;
    unicodeTableCount: INTEGER;

    lines: ARRAY MaxLines OF ZapfAst.Line;
    lineCount: INTEGER;

    (* ---- output buffer / position tracking ---- *)
    buf: ARRAY MaxStory OF INTEGER;             (* bytes, as 0..255 ints *)
    position*: INTEGER;
    highWater: INTEGER;                          (* highest position ever written+1 *)
    inVocab*: BOOLEAN;
    vocabBuf: ARRAY MaxVocabScratch OF INTEGER;
    vocabLen: INTEGER;
    vocabStart*, vocabRecSize*, vocabKeySize*: INTEGER;

    globalVarCount, objectCount: INTEGER;
    functionsOffset*, stringsOffset*: INTEGER;

    finalPass*: BOOLEAN;
    measureAgain*: BOOLEAN;
    abortLine*: BOOLEAN;                         (* "SeriousError happened, skip to next line" *)

    (* ---- reassembly scope (within one .FUNCT body) ---- *)
    reassemblyNodeIndex*: INTEGER;
    reassemblyPosition*: INTEGER;
    reassemblySymbol*: Symbol;
    reassemblyLabels: ARRAY 256 OF ARRAY 80 OF CHAR;
    reassemblyLabelCount: INTEGER;
    deferredNames: ARRAY 64 OF ARRAY 80 OF CHAR;
    deferredExpected: ARRAY 64 OF INTEGER;
    deferredCount: INTEGER
  END;

(* ------------------------------------------------------------------ *)
(* symbol table                                                        *)
(* ------------------------------------------------------------------ *)

PROCEDURE HashName(name: ARRAY OF CHAR): INTEGER;
VAR h, i: INTEGER;
BEGIN
  h := 0; i := 0;
  WHILE name[i] # 0X DO
    h := (h * 31 + ORD(name[i])) MOD NumBuckets;
    INC(i)
  END;
  IF h < 0 THEN h := -h END;
  RETURN h
END HashName;

PROCEDURE FindGlobal*(ctx: Context; name: ARRAY OF CHAR): Symbol;
VAR s: Symbol;
BEGIN
  s := ctx.globalBuckets[HashName(name)];
  WHILE (s # NIL) & (s.name # name) DO s := s.hnext END;
  RETURN s
END FindGlobal;

PROCEDURE NewSymbol(name: ARRAY OF CHAR; kind, value: INTEGER): Symbol;
VAR s: Symbol;
BEGIN
  NEW(s);
  Strings.Copy(name, s.name);
  s.kind := kind; s.value := value; s.phantom := FALSE;
  s.hnext := NIL; s.lnext := NIL;
  RETURN s
END NewSymbol;

PROCEDURE DefineGlobal*(ctx: Context; name: ARRAY OF CHAR; kind, value: INTEGER): Symbol;
VAR s: Symbol; b: INTEGER;
BEGIN
  s := FindGlobal(ctx, name);
  IF s = NIL THEN
    s := NewSymbol(name, kind, value);
    b := HashName(name);
    s.hnext := ctx.globalBuckets[b];
    ctx.globalBuckets[b] := s
  ELSE
    s.kind := kind; s.value := value; s.phantom := FALSE
  END;
  RETURN s
END DefineGlobal;

(* Look up-or-create as Unknown (matches the original's "reference before
   definition" behavior: any name not yet known becomes an Unknown global). *)
PROCEDURE LookupGlobal*(ctx: Context; name: ARRAY OF CHAR): Symbol;
VAR s: Symbol; b: INTEGER;
BEGIN
  s := FindGlobal(ctx, name);
  IF s = NIL THEN
    s := NewSymbol(name, SymUnknown, 0);
    b := HashName(name);
    s.hnext := ctx.globalBuckets[b];
    ctx.globalBuckets[b] := s
  END;
  RETURN s
END LookupGlobal;

PROCEDURE FindLocal*(ctx: Context; name: ARRAY OF CHAR): Symbol;
VAR s: Symbol;
BEGIN
  s := ctx.localHead;
  WHILE (s # NIL) & (s.name # name) DO s := s.lnext END;
  RETURN s
END FindLocal;

PROCEDURE DefineLocal*(ctx: Context; name: ARRAY OF CHAR; kind, value: INTEGER): Symbol;
VAR s: Symbol;
BEGIN
  s := FindLocal(ctx, name);
  IF s = NIL THEN
    s := NewSymbol(name, kind, value);
    s.lnext := ctx.localHead;
    ctx.localHead := s
  ELSE
    s.kind := kind; s.value := value; s.phantom := FALSE
  END;
  RETURN s
END DefineLocal;

PROCEDURE ClearLocals*(ctx: Context);
BEGIN ctx.localHead := NIL END ClearLocals;

(* Resolve a name for use as an operand/reference: locals shadow globals;
   an unknown name becomes (or reuses) a global Unknown symbol. *)
PROCEDURE Resolve*(ctx: Context; name: ARRAY OF CHAR): Symbol;
VAR s: Symbol;
BEGIN
  s := FindLocal(ctx, name);
  IF s # NIL THEN RETURN s END;
  RETURN LookupGlobal(ctx, name)
END Resolve;

PROCEDURE ClearGlobals(ctx: Context);
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO NumBuckets - 1 DO ctx.globalBuckets[i] := NIL END
END ClearGlobals;

PROCEDURE MarkAllPhantom(ctx: Context);
VAR i: INTEGER; s: Symbol;
BEGIN
  FOR i := 0 TO NumBuckets - 1 DO
    s := ctx.globalBuckets[i];
    WHILE s # NIL DO s.phantom := TRUE; s := s.hnext END
  END
END MarkAllPhantom;

(* ------------------------------------------------------------------ *)
(* error reporting                                                      *)
(* ------------------------------------------------------------------ *)

(* Diagnostics go to STDERR. The assembler writes the story file to a named
   file rather than to stdout, so this is hygiene rather than corruption -
   but a caller that redirects or discards one stream should still see the
   other, and a survey script that reads stderr should see the failures. *)
PROCEDURE Loc(file: ARRAY OF CHAR; line: INTEGER);
BEGIN
  IF file[0] # 0X THEN
    Out.ErrString(file); Out.ErrString(":"); Out.ErrInt(line, 0); Out.ErrString(": ")
  END
END Loc;

PROCEDURE Warn*(ctx: Context; file: ARRAY OF CHAR; line: INTEGER; msg: ARRAY OF CHAR);
BEGIN
  INC(ctx.warningCount);
  Loc(file, line); Out.ErrString("warning: "); Out.ErrString(msg); Out.ErrLn
END Warn;

(* Marks the current line as aborted (skip its remaining processing) and
   reports the error - this is the port's stand-in for `throw SeriousError`. *)
PROCEDURE Serious*(ctx: Context; file: ARRAY OF CHAR; line: INTEGER; msg: ARRAY OF CHAR);
BEGIN
  INC(ctx.errorCount);
  Loc(file, line); Out.ErrString("error: "); Out.ErrString(msg); Out.ErrLn;
  ctx.abortLine := TRUE
END Serious;

PROCEDURE CloseOutput*(ctx: Context);
VAR f: Files.File; r: Files.Rider; i: INTEGER;
BEGIN
  f := Files.New(ctx.outFile);
  IF f # NIL THEN
    Files.Set(r, f, 0);
    FOR i := 0 TO ctx.highWater - 1 DO
      Files.Write(r, ctx.buf[i])
    END;
    Files.Register(f);
    Files.Close(f)
  END
END CloseOutput;

PROCEDURE Fatal*(ctx: Context; file: ARRAY OF CHAR; line: INTEGER; msg: ARRAY OF CHAR);
BEGIN
  Loc(file, line); Out.ErrString("fatal error: "); Out.ErrString(msg); Out.ErrLn;
  CloseOutput(ctx);
  HALT(2)
END Fatal;

(* ------------------------------------------------------------------ *)
(* derived properties                                                    *)
(* ------------------------------------------------------------------ *)

PROCEDURE PackingDivisor*(ctx: Context): INTEGER;
BEGIN
  IF ctx.zversion <= 3 THEN RETURN 2
  ELSIF ctx.zversion <= 7 THEN RETURN 4
  ELSE RETURN 8
  END
END PackingDivisor;

PROCEDURE HeaderLengthDivisor*(ctx: Context): INTEGER;
BEGIN
  IF ctx.zversion <= 3 THEN RETURN 2
  ELSIF ctx.zversion <= 5 THEN RETURN 4
  ELSE RETURN 8
  END
END HeaderLengthDivisor;

PROCEDURE UsePackingOffsets*(ctx: Context): BOOLEAN;
BEGIN RETURN (ctx.zversion = 6) OR (ctx.zversion = 7) END UsePackingOffsets;

PROCEDURE ZWordChars*(ctx: Context): INTEGER;
BEGIN IF ctx.zversion <= 3 THEN RETURN 6 ELSE RETURN 9 END END ZWordChars;

PROCEDURE AtVocabRecord*(ctx: Context): BOOLEAN;
BEGIN RETURN (ctx.position - ctx.vocabStart) MOD ctx.vocabRecSize = 0 END AtVocabRecord;

(* ------------------------------------------------------------------ *)
(* output buffer                                                        *)
(* ------------------------------------------------------------------ *)

PROCEDURE PutByteRaw(ctx: Context; pos, v: INTEGER);
BEGIN
  IF ctx.inVocab THEN
    ctx.vocabBuf[pos - ctx.vocabStart] := v MOD 256
  ELSE
    ctx.buf[pos] := v MOD 256;
    IF pos + 1 > ctx.highWater THEN ctx.highWater := pos + 1 END
  END
END PutByteRaw;

PROCEDURE GetByteRaw(ctx: Context; pos: INTEGER): INTEGER;
BEGIN
  IF ctx.inVocab THEN RETURN ctx.vocabBuf[pos - ctx.vocabStart]
  ELSE RETURN ctx.buf[pos]
  END
END GetByteRaw;

PROCEDURE WriteByte*(ctx: Context; v: INTEGER);
BEGIN
  PutByteRaw(ctx, ctx.position, v);
  INC(ctx.position)
END WriteByte;

PROCEDURE WriteWord*(ctx: Context; v: INTEGER);
BEGIN
  WriteByte(ctx, (v DIV 256) MOD 256);
  WriteByte(ctx, v MOD 256)
END WriteWord;

PROCEDURE ReadByte*(ctx: Context): INTEGER;
BEGIN RETURN GetByteRaw(ctx, ctx.position) END ReadByte;

(* WriteByte/WriteWord of a possibly-not-yet-defined symbol: 0 while not the
   final pass (tolerate forward references), a reported error on the final
   pass if still Unknown. *)
PROCEDURE WriteByteSym*(ctx: Context; sym: Symbol; file: ARRAY OF CHAR; line: INTEGER);
BEGIN
  IF sym.kind = SymUnknown THEN
    IF ctx.finalPass THEN
      Serious(ctx, file, line, "undefined symbol");
      WriteByte(ctx, 0)
    ELSE
      WriteByte(ctx, 0)
    END
  ELSE
    WriteByte(ctx, sym.value)
  END
END WriteByteSym;

PROCEDURE WriteWordSym*(ctx: Context; sym: Symbol; file: ARRAY OF CHAR; line: INTEGER);
BEGIN
  IF sym.kind = SymUnknown THEN
    IF ctx.finalPass THEN
      Serious(ctx, file, line, "undefined symbol");
      WriteWord(ctx, 0)
    ELSE
      WriteWord(ctx, 0)
    END
  ELSE
    WriteWord(ctx, sym.value)
  END
END WriteWordSym;

PROCEDURE AddFixup*(ctx: Context; symName: ARRAY OF CHAR; location: INTEGER);
VAR f: Fixup;
BEGIN
  NEW(f);
  Strings.Copy(symName, f.symName);
  f.location := location;
  f.next := NIL;
  IF ctx.fixups = NIL THEN ctx.fixups := f ELSE ctx.fixupsTail.next := f END;
  ctx.fixupsTail := f
END AddFixup;

PROCEDURE GetHeader*(ctx: Context; VAR hdr: ARRAY OF INTEGER);
VAR i: INTEGER;
BEGIN FOR i := 0 TO 63 DO hdr[i] := ctx.buf[i] END END GetHeader;

(* ------------------------------------------------------------------ *)
(* vocabulary section (.VOCBEG / .VOCEND)                                *)
(* ------------------------------------------------------------------ *)

PROCEDURE EnterVocab*(ctx: Context; recSize, keySize: INTEGER);
BEGIN
  ctx.inVocab := TRUE;
  ctx.vocabStart := ctx.position;
  ctx.vocabRecSize := recSize;
  ctx.vocabKeySize := keySize
END EnterVocab;

(* Compares two vocabulary records by their DICTIONARY KEY ONLY - the
   encoded word bytes (vocabKeySize: 4 in V1-3, 6 in V4+) - never the flag
   and value bytes that follow it in the record. A real Z-machine
   dictionary is looked up at RUNTIME by binary search on exactly those key
   bytes, so the key is what has to be sorted, and it is what defines
   whether two entries are "the same word" for the vocab-collision check
   below: a duplicate key is a duplicate regardless of what values happen
   to follow it.

   This used to compare the WHOLE record (through vocabRecSize), which is
   wrong two ways at once: it can put the dictionary out of key order
   whenever two words share a key but differ in their values (e.g. an
   OBJECT-only word with all-zero values sorting differently against a
   VERB/ADJECTIVE word that shares its key), and it silently missed most
   real V3 truncation collisions in the warning below, since two SEPARATE
   ZIL words being folded onto the same 6-Z-character key (SanitizedNAME
   truncation, not sanitization) essentially never have byte-identical
   value bytes too. Confirmed against advent.zil: BOTTLE/BOTTLED,
   STREAM/STREAMBED, SHADOW/SHADOWY, DRAGON/DRAGON'S and others all encode
   to the identical 4-byte key and are genuinely the same Z-machine
   dictionary word, but only the handful whose value bytes ALSO happened to
   match by coincidence (all-zero SYNONYM-only entries) were ever reported
   or sorted correctly. *)
PROCEDURE VocabCompare(ctx: Context; i, j: INTEGER): INTEGER;
VAR k, a, b: INTEGER;
BEGIN
  k := 0;
  WHILE k < ctx.vocabKeySize DO
    a := ctx.vocabBuf[i * ctx.vocabRecSize + k];
    b := ctx.vocabBuf[j * ctx.vocabRecSize + k];
    IF a # b THEN RETURN a - b END;
    INC(k)
  END;
  RETURN 0
END VocabCompare;

PROCEDURE VocabCompareSaved(ctx: Context; saved: ARRAY OF INTEGER; j: INTEGER): INTEGER;
VAR k, a, b: INTEGER;
BEGIN
  k := 0;
  WHILE k < ctx.vocabKeySize DO
    a := saved[k];
    b := ctx.vocabBuf[j * ctx.vocabRecSize + k];
    IF a # b THEN RETURN a - b END;
    INC(k)
  END;
  RETURN 0
END VocabCompareSaved;

PROCEDURE VocabMove(ctx: Context; fromIdx, toIdx, nRecords: INTEGER);
VAR i, byteLen: INTEGER;
BEGIN
  byteLen := nRecords * ctx.vocabRecSize;
  IF toIdx < fromIdx THEN
    FOR i := 0 TO byteLen - 1 DO
      ctx.vocabBuf[toIdx * ctx.vocabRecSize + i] := ctx.vocabBuf[fromIdx * ctx.vocabRecSize + i]
    END
  ELSE
    FOR i := byteLen - 1 TO 0 BY -1 DO
      ctx.vocabBuf[toIdx * ctx.vocabRecSize + i] := ctx.vocabBuf[fromIdx * ctx.vocabRecSize + i]
    END
  END
END VocabMove;

(* Reverse lookup for the "vocab collision" warning: name of the Label
   symbol pointing at byte offset addr, else "index N". *)
PROCEDURE VocabLabel(ctx: Context; addr, idx: ARRAY OF CHAR; addrVal: INTEGER; VAR out: ARRAY OF CHAR);
VAR i: INTEGER; s: Symbol; found: BOOLEAN;
BEGIN
  found := FALSE;
  i := 0;
  WHILE (i < NumBuckets) & ~found DO
    s := ctx.globalBuckets[i];
    WHILE (s # NIL) & ~found DO
      IF (s.kind = SymLabel) & (s.value = addrVal) THEN
        Strings.Copy(s.name, out); found := TRUE
      END;
      s := s.hnext
    END;
    INC(i)
  END
END VocabLabel;

(* Ends the vocab section: sorts records (insertion sort, since ZIL output
   is nearly sorted already), remaps every global Label symbol and every
   vocab-internal fixup through the resulting permutation, then appends the
   sorted bytes to the main buffer at vocabStart. *)
PROCEDURE LeaveVocab*(ctx: Context);
VAR nRecords, i, j, insertAt, lo, hi, mid, cmp: INTEGER;
    saved: ARRAY 64 OF INTEGER;
    newIndexes: ARRAY 8192 OF INTEGER;
    k: INTEGER;
    vocabEnd: INTEGER;
    s: Symbol;
    f, prevF, nextF: Fixup;
    oldIdx, newIdx, within, addr: INTEGER;
    labelBuf: ARRAY 80 OF CHAR;
    label1, label2: ARRAY 80 OF CHAR;
BEGIN
  ctx.vocabLen := ctx.position - ctx.vocabStart;
  nRecords := ctx.vocabLen DIV ctx.vocabRecSize;
  FOR i := 0 TO nRecords - 1 DO newIndexes[i] := i END;

  FOR i := 1 TO nRecords - 1 DO
    IF VocabCompare(ctx, i, i - 1) < 0 THEN
      FOR k := 0 TO ctx.vocabRecSize - 1 DO saved[k] := ctx.vocabBuf[i * ctx.vocabRecSize + k] END;
      (* binary search for insertion point among [0, i) *)
      lo := 0; hi := i;
      WHILE lo < hi DO
        mid := (lo + hi) DIV 2;
        cmp := VocabCompareSaved(ctx, saved, mid);
        IF cmp < 0 THEN hi := mid ELSE lo := mid + 1 END
      END;
      insertAt := lo;
      VocabMove(ctx, insertAt, insertAt + 1, i - insertAt);
      FOR k := 0 TO ctx.vocabRecSize - 1 DO ctx.vocabBuf[insertAt * ctx.vocabRecSize + k] := saved[k] END;
      FOR j := 0 TO nRecords - 1 DO
        IF (newIndexes[j] >= insertAt) & (newIndexes[j] < i) THEN INC(newIndexes[j]) END
      END;
      newIndexes[i] := insertAt   (* old index i now lives at insertAt; but newIndexes is old->new, fix below *)
    END
  END;

  (* newIndexes as built above tracks "old physical index -> new physical
     index" incrementally, but the last assignment overwrote entry i with
     insertAt directly (correct: record that STARTED this iteration at
     physical slot i, i.e. old index i, now sits at insertAt). *)

  vocabEnd := ctx.vocabStart + ctx.vocabLen;

  (* remap every global Label symbol inside the vocab range *)
  FOR i := 0 TO NumBuckets - 1 DO
    s := ctx.globalBuckets[i];
    WHILE s # NIL DO
      IF (s.kind = SymLabel) & (s.value >= ctx.vocabStart) & (s.value < vocabEnd) THEN
        oldIdx := (s.value - ctx.vocabStart) DIV ctx.vocabRecSize;
        within := (s.value - ctx.vocabStart) MOD ctx.vocabRecSize;
        newIdx := newIndexes[oldIdx];
        s.value := ctx.vocabStart + newIdx * ctx.vocabRecSize + within
      END;
      s := s.hnext
    END
  END;

  (* splice sorted bytes into the real buffer *)
  ctx.inVocab := FALSE;
  FOR i := 0 TO ctx.vocabLen - 1 DO PutByteRaw(ctx, ctx.vocabStart + i, ctx.vocabBuf[i]) END;

  IF ctx.finalPass THEN
    FOR i := 1 TO nRecords - 1 DO
      IF VocabCompare(ctx, i, i - 1) = 0 THEN
        VocabLabel(ctx, "", "", ctx.vocabStart + (i - 1) * ctx.vocabRecSize, label1);
        VocabLabel(ctx, "", "", ctx.vocabStart + i * ctx.vocabRecSize, label2);
        IF label1[0] = 0X THEN Strings.Copy("(unlabeled)", label1) END;
        IF label2[0] = 0X THEN Strings.Copy("(unlabeled)", label2) END;
        Strings.Copy("vocab collision between ", labelBuf);
        Strings.Append(label1, labelBuf); Strings.Append(" and ", labelBuf); Strings.Append(label2, labelBuf);
        Warn(ctx, "", 0, labelBuf)
      END
    END
  END;

  (* resolve+remove any pending fixup that targets a vocab-internal
     location AND whose symbol is itself a vocab-internal label *)
  prevF := NIL; f := ctx.fixups;
  WHILE f # NIL DO
    nextF := f.next;
    IF (f.location >= ctx.vocabStart) & (f.location < vocabEnd) THEN
      s := FindGlobal(ctx, f.symName);
      IF (s # NIL) & (s.kind = SymLabel) & (s.value >= ctx.vocabStart) & (s.value < vocabEnd) THEN
        oldIdx := (f.location - ctx.vocabStart) DIV ctx.vocabRecSize;
        within := (f.location - ctx.vocabStart) MOD ctx.vocabRecSize;
        newIdx := newIndexes[oldIdx];
        addr := ctx.vocabStart + newIdx * ctx.vocabRecSize + within;
        PutByteRaw(ctx, addr, (s.value DIV 256) MOD 256);
        PutByteRaw(ctx, addr + 1, s.value MOD 256);
        (* unlink f *)
        IF prevF = NIL THEN ctx.fixups := nextF ELSE prevF.next := nextF END;
        IF f = ctx.fixupsTail THEN ctx.fixupsTail := prevF END
      ELSE
        prevF := f
      END
    ELSE
      prevF := f
    END;
    f := nextF
  END;

  ctx.position := vocabEnd;
  ctx.vocabStart := -1; ctx.vocabRecSize := 0; ctx.vocabKeySize := 0
END LeaveVocab;

(* ------------------------------------------------------------------ *)
(* global var / object numbering                                        *)
(* ------------------------------------------------------------------ *)

PROCEDURE AddGlobalVar*(ctx: Context; name: ARRAY OF CHAR; file: ARRAY OF CHAR; line: INTEGER): Symbol;
VAR s: Symbol; num: INTEGER; msg: ARRAY 160 OF CHAR; numStr: ARRAY 16 OF CHAR;
BEGIN
  num := 16 + ctx.globalVarCount;
  INC(ctx.globalVarCount);
  s := FindGlobal(ctx, name);
  IF s = NIL THEN
    RETURN DefineGlobal(ctx, name, SymVariable, num)
  ELSIF s.phantom & (s.kind = SymVariable) THEN
    IF s.value # num THEN
      Strings.Copy("global ", msg); Strings.Append(name, msg); Strings.Append(" seems to have moved", msg);
      Serious(ctx, file, line, msg)
    END;
    s.phantom := FALSE;
    RETURN s
  ELSIF s.kind = SymUnknown THEN
    s.kind := SymVariable; s.value := num; s.phantom := FALSE;
    ctx.measureAgain := TRUE;
    RETURN s
  ELSE
    Strings.Copy("global redefined: ", msg); Strings.Append(name, msg);
    Serious(ctx, file, line, msg);
    RETURN s
  END
END AddGlobalVar;

PROCEDURE AddObject*(ctx: Context; name: ARRAY OF CHAR; file: ARRAY OF CHAR; line: INTEGER): Symbol;
VAR s: Symbol; num: INTEGER; msg: ARRAY 160 OF CHAR;
BEGIN
  num := 1 + ctx.objectCount;
  INC(ctx.objectCount);
  s := FindGlobal(ctx, name);
  IF s = NIL THEN
    RETURN DefineGlobal(ctx, name, SymObject, num)
  ELSIF s.phantom & (s.kind = SymObject) THEN
    IF s.value # num THEN
      Strings.Copy("object ", msg); Strings.Append(name, msg); Strings.Append(" seems to have moved", msg);
      Fatal(ctx, file, line, msg)
    END;
    s.phantom := FALSE;
    RETURN s
  ELSIF s.kind = SymUnknown THEN
    s.kind := SymObject; s.value := num; s.phantom := FALSE;
    ctx.measureAgain := TRUE;
    RETURN s
  ELSE
    Strings.Copy("object redefined: ", msg); Strings.Append(name, msg);
    Serious(ctx, file, line, msg);
    RETURN s
  END
END AddObject;

PROCEDURE CheckLimits*(ctx: Context; file: ARRAY OF CHAR; line: INTEGER);
VAR maxObjects: INTEGER; msg: ARRAY 160 OF CHAR; n: ARRAY 16 OF CHAR;
BEGIN
  IF ctx.globalVarCount > 240 THEN
    Strings.Copy("too many global variables: ", msg); Strings.IntToStr(ctx.globalVarCount, n);
    Strings.Append(n, msg); Strings.Append(" defined, only 240 allowed", msg);
    Serious(ctx, file, line, msg)
  END;
  IF ctx.zversion <= 3 THEN maxObjects := 255 ELSE maxObjects := 65535 END;
  IF ctx.objectCount > maxObjects THEN
    Strings.Copy("too many objects defined", msg);
    Serious(ctx, file, line, msg)
  END
END CheckLimits;

(* ------------------------------------------------------------------ *)
(* .LANG                                                                 *)
(* ------------------------------------------------------------------ *)

PROCEDURE SetLanguage*(ctx: Context; langId, escapeChar: INTEGER);
BEGIN
  ctx.languageEscapeChar := escapeChar;
  ctx.langCount := 0;
  IF langId = 1 THEN
    ctx.langFrom[0] := ORD("a"); ctx.langTo[0] := 228;
    ctx.langFrom[1] := ORD("o"); ctx.langTo[1] := 246;
    ctx.langFrom[2] := ORD("u"); ctx.langTo[2] := 252;
    ctx.langFrom[3] := ORD("s"); ctx.langTo[3] := 223;
    ctx.langFrom[4] := ORD("A"); ctx.langTo[4] := 196;
    ctx.langFrom[5] := ORD("O"); ctx.langTo[5] := 214;
    ctx.langFrom[6] := ORD("U"); ctx.langTo[6] := 220;
    ctx.langFrom[7] := ORD("<"); ctx.langTo[7] := 171;
    ctx.langFrom[8] := ORD(">"); ctx.langTo[8] := 187;
    ctx.langCount := 9
  END
END SetLanguage;

(* ------------------------------------------------------------------ *)
(* reassembly scope (branch-size convergence within one .FUNCT)         *)
(* ------------------------------------------------------------------ *)

PROCEDURE BeginReassemblyScope*(ctx: Context; nodeIndex: INTEGER; sym: Symbol);
BEGIN
  ctx.reassemblyLabelCount := 0;
  ctx.deferredCount := 0;
  ctx.reassemblyNodeIndex := nodeIndex;
  ctx.reassemblyPosition := ctx.position;
  ctx.reassemblySymbol := sym
END BeginReassemblyScope;

(* Registers "symbol should end up equal to expected" to be checked once,
   at the natural (non-rewind) end of the current reassembly scope, rather
   than immediately -- a rewind before then might still correct it. First
   registration per symbol per scope wins (TryAdd semantics). *)
PROCEDURE DeferGlobalLabelStabilityCheck*(ctx: Context; name: ARRAY OF CHAR; expected: INTEGER);
VAR i: INTEGER; found: BOOLEAN;
BEGIN
  found := FALSE; i := 0;
  WHILE (i < ctx.deferredCount) & ~found DO
    IF ctx.deferredNames[i] = name THEN found := TRUE END;
    INC(i)
  END;
  IF ~found & (ctx.deferredCount < LEN(ctx.deferredNames)) THEN
    Strings.Copy(name, ctx.deferredNames[ctx.deferredCount]);
    ctx.deferredExpected[ctx.deferredCount] := expected;
    INC(ctx.deferredCount)
  END
END DeferGlobalLabelStabilityCheck;

PROCEDURE InReassemblyScope*(ctx: Context): BOOLEAN;
BEGIN RETURN ctx.reassemblyPosition # -1 END InReassemblyScope;

PROCEDURE MarkUnknownBranch*(ctx: Context; label: ARRAY OF CHAR);
BEGIN
  IF ctx.reassemblyLabelCount < LEN(ctx.reassemblyLabels) THEN
    Strings.Copy(label, ctx.reassemblyLabels[ctx.reassemblyLabelCount]);
    INC(ctx.reassemblyLabelCount)
  END
END MarkUnknownBranch;

PROCEDURE CausesReassembly*(ctx: Context; label: ARRAY OF CHAR): BOOLEAN;
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (i < ctx.reassemblyLabelCount) & (ctx.reassemblyLabels[i] # label) DO INC(i) END;
  RETURN i < ctx.reassemblyLabelCount
END CausesReassembly;

(* Rewinds output/local-symbol state to the start of the current .FUNCT
   body; returns the AST node index the caller should resume from. *)
PROCEDURE Reassemble*(ctx: Context; curLabel: ARRAY OF CHAR): INTEGER;
VAR s, prev, cur, nxt: Symbol;
BEGIN
  DefineLocal(ctx, curLabel, SymLabel, ctx.position);
  s := ctx.localHead; prev := NIL;
  WHILE s # NIL DO
    nxt := s.lnext;
    IF s.kind = SymLabel THEN
      s.phantom := TRUE;
      prev := s
    ELSE
      (* drop non-label locals *)
      IF prev = NIL THEN ctx.localHead := nxt ELSE prev.lnext := nxt END
    END;
    s := nxt
  END;
  IF ctx.reassemblySymbol # NIL THEN ctx.reassemblySymbol.phantom := TRUE END;
  ctx.reassemblyLabelCount := 0;
  ctx.deferredCount := 0;
  ctx.position := ctx.reassemblyPosition;
  RETURN ctx.reassemblyNodeIndex
END Reassemble;

PROCEDURE EndReassemblyScope*(ctx: Context; nodeIndex: INTEGER);
VAR i: INTEGER; sym: Symbol; msg: ARRAY 200 OF CHAR;
BEGIN
  IF nodeIndex # ctx.reassemblyNodeIndex THEN
    ctx.reassemblyLabelCount := 0;
    ctx.reassemblyNodeIndex := -1;
    ctx.reassemblyPosition := -1;
    ctx.reassemblySymbol := NIL;
    ClearLocals(ctx);
    FOR i := 0 TO ctx.deferredCount - 1 DO
      sym := FindGlobal(ctx, ctx.deferredNames[i]);
      IF (sym # NIL) & (sym.value # ctx.deferredExpected[i]) THEN
        IF ctx.finalPass THEN
          Strings.Copy("global label ", msg); Strings.Append(ctx.deferredNames[i], msg);
          Strings.Append(" seems to have moved", msg);
          Fatal(ctx, "", 0, msg)
        ELSE
          ctx.measureAgain := TRUE
        END
      END
    END;
    ctx.deferredCount := 0
  END
END EndReassemblyScope;

(* ------------------------------------------------------------------ *)
(* lifecycle                                                             *)
(* ------------------------------------------------------------------ *)

PROCEDURE InitContext*(ctx: Context);
BEGIN
  ctx.quiet := FALSE; ctx.informMode := FALSE; ctx.listAddresses := FALSE;
  ctx.inFile[0] := 0X; ctx.outFile[0] := 0X;
  Strings.Copy("ZAPF", ctx.creator);
  ctx.creatorSpecified := FALSE; ctx.noCreator := FALSE;
  ctx.serial[0] := 0X; ctx.serialSpecified := FALSE;
  ctx.zversion := 3;
  ctx.zflags := 0; ctx.zflags2 := 0;
  ctx.release := 0; ctx.releaseSpecified := FALSE;
  ctx.fixups := NIL; ctx.fixupsTail := NIL;
  ctx.localHead := NIL;
  ctx.fileStackDepth := 0;
  ClearGlobals(ctx)
END InitContext;

PROCEDURE RestartContext*(ctx: Context);
VAR stackName: ARRAY 8 OF CHAR;
BEGIN
  ctx.errorCount := 0; ctx.warningCount := 0;
  ClearGlobals(ctx);
  ctx.localHead := NIL;
  ctx.fixups := NIL; ctx.fixupsTail := NIL;
  ctx.fileStackDepth := 0;
  ctx.languageEscapeChar := -1;
  ctx.langCount := 0;
  ctx.hasPendingForm := FALSE;
  ctx.hasPendingOpEnc := FALSE;
  ctx.tableStart := -1; ctx.tableSize := -1;
  ctx.position := 0;
  ctx.highWater := 0;
  ctx.inVocab := FALSE;
  ctx.vocabStart := -1; ctx.vocabRecSize := 0; ctx.vocabKeySize := 0;
  ctx.globalVarCount := 0; ctx.objectCount := 0;
  ctx.functionsOffset := 0; ctx.stringsOffset := 0;
  ctx.finalPass := FALSE; ctx.measureAgain := FALSE; ctx.abortLine := FALSE;
  ctx.reassemblyNodeIndex := -1; ctx.reassemblyPosition := -1; ctx.reassemblySymbol := NIL;
  ctx.reassemblyLabelCount := 0; ctx.deferredCount := 0;
  ctx.unicodeTableCount := 0;
  ZapfZChar.ResetUnicodeTable;
  IF ctx.informMode THEN Strings.Copy("sp", stackName) ELSE Strings.Copy("STACK", stackName) END;
  DefineGlobal(ctx, stackName, SymVariable, 0)
END RestartContext;

PROCEDURE ResetBetweenPasses*(ctx: Context);
BEGIN
  ctx.fixups := NIL; ctx.fixupsTail := NIL;
  MarkAllPhantom(ctx);
  ctx.globalVarCount := 0; ctx.objectCount := 0;
  ctx.functionsOffset := 0; ctx.stringsOffset := 0;
  ctx.unicodeTableCount := 0;
  ZapfZChar.ResetUnicodeTable
END ResetBetweenPasses;

PROCEDURE CheckForUndefinedSymbols*(ctx: Context);
VAR f: Fixup; s: Symbol; msg: ARRAY 160 OF CHAR;
    seen: ARRAY 4096 OF ARRAY 80 OF CHAR; seenCount, i: INTEGER; already: BOOLEAN;
BEGIN
  IF UsePackingOffsets(ctx) THEN
    DefineGlobal(ctx, "FOFF", SymConstant, ctx.functionsOffset DIV 8);
    DefineGlobal(ctx, "SOFF", SymConstant, ctx.stringsOffset DIV 8)
  END;

  seenCount := 0;
  f := ctx.fixups;
  WHILE f # NIL DO
    s := FindGlobal(ctx, f.symName);
    IF s = NIL THEN
      already := FALSE;
      i := 0;
      WHILE (i < seenCount) & ~already DO
        IF seen[i] = f.symName THEN already := TRUE END;
        INC(i)
      END;
      IF ~already THEN
        IF seenCount < LEN(seen) THEN Strings.Copy(f.symName, seen[seenCount]); INC(seenCount) END;
        Strings.Copy("symbol is never defined: ", msg); Strings.Append(f.symName, msg);
        Serious(ctx, "", 0, msg)
      END
    END;
    f := f.next
  END
END CheckForUndefinedSymbols;

(* ------------------------------------------------------------------ *)
(* expression evaluation                                                *)
(* ------------------------------------------------------------------ *)

PROCEDURE Addable(kind: INTEGER): BOOLEAN;
BEGIN RETURN (kind = SymConstant) OR (kind = SymLabel) OR (kind = SymObject) END Addable;

PROCEDURE EvalExpr*(ctx: Context; e: ZapfExpr.Expr; file: ARRAY OF CHAR; line: INTEGER;
                     VAR kind, value: INTEGER);
VAR s: Symbol; lk, lv, rk, rv: INTEGER; msg: ARRAY 160 OF CHAR;
BEGIN
  kind := SymConstant; value := 0;
  IF e = NIL THEN RETURN END;
  CASE e.kind OF
    ZapfExpr.KindNum: kind := SymConstant; value := e.numVal
   |ZapfExpr.KindSym:
      s := Resolve(ctx, e.text);
      IF (s.kind = SymUnknown) & ctx.finalPass THEN
        Strings.Copy("undefined symbol: ", msg); Strings.Append(e.text, msg);
        Fatal(ctx, file, line, msg)
      END;
      kind := s.kind; value := s.value
   |ZapfExpr.KindAdd:
      EvalExpr(ctx, e.left, file, line, lk, lv);
      EvalExpr(ctx, e.right, file, line, rk, rv);
      IF (~ctx.finalPass) & ((lk = SymUnknown) OR (rk = SymUnknown)) THEN
        kind := SymUnknown; value := 0
      ELSE
        kind := SymConstant; value := lv + rv
      END
  ELSE
    (* StringLiteral/QuoteExpr never reach EvalExpr in the original *)
    kind := SymConstant; value := 0
  END
END EvalExpr;

PROCEDURE IsLongConstant*(ctx: Context; e: ZapfExpr.Expr; file: ARRAY OF CHAR; line: INTEGER): BOOLEAN;
VAR s: Symbol; lk, lv, rk, rv: INTEGER;
BEGIN
  IF e = NIL THEN RETURN FALSE END;
  CASE e.kind OF
    ZapfExpr.KindNum: RETURN (e.numVal < 0) OR (e.numVal > 255)
   |ZapfExpr.KindSym:
      s := FindLocal(ctx, e.text);
      IF s # NIL THEN RETURN FALSE END;
      s := FindGlobal(ctx, e.text);
      IF s # NIL THEN RETURN (s.value < 0) OR (s.value > 255) END;
      RETURN TRUE   (* not defined yet: assume a faraway global label *)
   |ZapfExpr.KindAdd:
      IF IsLongConstant(ctx, e.left, file, line) OR IsLongConstant(ctx, e.right, file, line) THEN
        RETURN TRUE
      END;
      EvalExpr(ctx, e.left, file, line, lk, lv);
      EvalExpr(ctx, e.right, file, line, rk, rv);
      RETURN (lv + rv < 0) OR (lv + rv > 255)
  ELSE
    RETURN FALSE   (* StringLiteral / QuoteExpr *)
  END
END IsLongConstant;

CONST
  OpWord* = 0; OpByte* = 1; OpVar* = 2; OpOmitted* = 3;

(* Evaluates one instruction operand. otype: OpWord/OpByte/OpVar.
   allowLocalLabel: TRUE for a JUMP-style Label-flagged operand (returns a
   PC-relative word the caller still has to bias); FALSE for a normal value
   operand (unresolved symbols become fixups instead). *)
PROCEDURE EvalOperand*(ctx: Context; e: ZapfExpr.Expr; allowLocalLabel: BOOLEAN;
                        file: ARRAY OF CHAR; line: INTEGER;
                        VAR otype, ovalue: INTEGER; VAR hasFixup: BOOLEAN; VAR fixupName: ARRAY OF CHAR);
VAR apos: BOOLEAN; inner: ZapfExpr.Expr; s: Symbol; ek, ev, uv: INTEGER; msg: ARRAY 160 OF CHAR;
BEGIN
  hasFixup := FALSE; fixupName[0] := 0X;
  apos := FALSE; inner := e;
  IF e.kind = ZapfExpr.KindQuote THEN apos := TRUE; inner := e.inner END;

  IF inner.kind = ZapfExpr.KindSym THEN
    s := FindLocal(ctx, inner.text);
    IF s # NIL THEN
      IF s.kind = SymLabel THEN
        IF ~allowLocalLabel THEN Serious(ctx, file, line, "local label used as operand") END;
        (* relative to current position; caller corrects the bias *)
        otype := OpWord; ovalue := s.value - ctx.position
      ELSE
        otype := OpVar; ovalue := s.value
      END
    ELSE
      s := FindGlobal(ctx, inner.text);
      IF s # NIL THEN
        IF s.kind = SymVariable THEN otype := OpVar
        ELSIF (s.value >= 0) & (s.value < 256) THEN otype := OpByte
        ELSE otype := OpWord
        END;
        ovalue := s.value
      ELSIF ctx.finalPass & ~allowLocalLabel THEN
        Strings.Copy("undefined symbol: ", msg); Strings.Append(inner.text, msg);
        Fatal(ctx, file, line, msg);
        otype := OpByte; ovalue := 0
      ELSE
        otype := OpByte; ovalue := 0;
        IF allowLocalLabel THEN
          MarkUnknownBranch(ctx, inner.text)
        ELSE
          hasFixup := TRUE; Strings.Copy(inner.text, fixupName)
        END
      END
    END
  ELSE
    EvalExpr(ctx, inner, file, line, ek, ev);
    uv := ev MOD 65536;
    ovalue := uv;
    IF uv < 256 THEN otype := OpByte ELSE otype := OpWord END
  END;

  IF apos THEN otype := OpByte END
END EvalOperand;

(* ------------------------------------------------------------------ *)
(* alignment                                                            *)
(* ------------------------------------------------------------------ *)

PROCEDURE AlignUnpacked*(ctx: Context; divisor: INTEGER);
BEGIN WHILE ctx.position MOD divisor # 0 DO WriteByte(ctx, 0) END END AlignUnpacked;

CONST PackingOffsetDivisor = 8;

PROCEDURE AlignPacked(ctx: Context; VAR offset: INTEGER);
BEGIN
  IF UsePackingOffsets(ctx) & (offset = 0) THEN
    WHILE (ctx.position MOD PackingOffsetDivisor # 0) OR (ctx.position < PackingOffsetDivisor) DO
      WriteByte(ctx, 0)
    END;
    offset := ctx.position - PackingOffsetDivisor
  END;
  WHILE (ctx.position - offset) MOD PackingDivisor(ctx) # 0 DO WriteByte(ctx, 0) END
END AlignPacked;

PROCEDURE AlignRoutine(ctx: Context);
BEGIN AlignPacked(ctx, ctx.functionsOffset) END AlignRoutine;

PROCEDURE AlignString(ctx: Context);
BEGIN AlignPacked(ctx, ctx.stringsOffset) END AlignString;

(* ------------------------------------------------------------------ *)
(* string encoding glue (Z-char encoding lives in ZapfZChar)            *)
(* ------------------------------------------------------------------ *)

CONST MaxZStr = 2048;

(* %% -> %; %<c> -> the language's special char for <c> if one is mapped,
   else passed through unchanged. No-op if no .LANG escape char is set. *)
PROCEDURE MaybeProcessEscapeChars(ctx: Context; VAR s: ARRAY OF CHAR);
VAR buf: ARRAY MaxZStr OF CHAR; i, n, j, k, mapped: INTEGER; found: BOOLEAN;
BEGIN
  IF ctx.languageEscapeChar < 0 THEN RETURN END;
  n := Strings.Length(s);
  i := 0; j := 0;
  WHILE i < n DO
    IF (ORD(s[i]) = ctx.languageEscapeChar) & (i + 1 < n) THEN
      IF ORD(s[i + 1]) = ctx.languageEscapeChar THEN
        buf[j] := CHR(ctx.languageEscapeChar); INC(j); i := i + 2
      ELSE
        found := FALSE; k := 0; mapped := 0;
        WHILE (k < ctx.langCount) & ~found DO
          IF ctx.langFrom[k] = ORD(s[i + 1]) THEN mapped := ctx.langTo[k]; found := TRUE END;
          INC(k)
        END;
        IF found THEN
          buf[j] := CHR(mapped); INC(j); i := i + 2
        ELSE
          buf[j] := s[i]; INC(j); INC(i)
        END
      END
    ELSE
      buf[j] := s[i]; INC(j); INC(i)
    END
  END;
  buf[j] := 0X;
  Strings.Copy(buf, s)
END MaybeProcessEscapeChars;

PROCEDURE WriteZString*(ctx: Context; text: ARRAY OF CHAR; withLength: BOOLEAN; mode: INTEGER);
VAR s: ARRAY MaxZStr OF CHAR; outBuf: ARRAY MaxZStr OF INTEGER; outLen, zchars, i: INTEGER;
BEGIN
  Strings.Copy(text, s);
  MaybeProcessEscapeChars(ctx, s);
  ZapfZChar.Encode(s, mode, FALSE, 0, outBuf, outLen, zchars);
  IF withLength THEN WriteByte(ctx, outLen DIV 2) END;
  FOR i := 0 TO outLen - 1 DO WriteByte(ctx, outBuf[i]) END
END WriteZString;

PROCEDURE WriteZStringLength*(ctx: Context; text: ARRAY OF CHAR);
VAR s: ARRAY MaxZStr OF CHAR; outBuf: ARRAY MaxZStr OF INTEGER; outLen, zchars: INTEGER;
BEGIN
  Strings.Copy(text, s);
  MaybeProcessEscapeChars(ctx, s);
  ZapfZChar.Encode(s, ZapfZChar.ModeNormal, FALSE, 0, outBuf, outLen, zchars);
  WriteByte(ctx, outLen DIV 2)
END WriteZStringLength;

PROCEDURE WriteZWord*(ctx: Context; text: ARRAY OF CHAR);
VAR s: ARRAY MaxZStr OF CHAR; outBuf: ARRAY MaxZStr OF INTEGER; outLen, zchars, i: INTEGER;
BEGIN
  Strings.Copy(text, s);
  MaybeProcessEscapeChars(ctx, s);
  ZapfZChar.Encode(s, ZapfZChar.ModeNoAbbrev, TRUE, ZWordChars(ctx), outBuf, outLen, zchars);
  FOR i := 0 TO outLen - 1 DO WriteByte(ctx, outBuf[i]) END
END WriteZWord;

(* ------------------------------------------------------------------ *)
(* instructions                                                         *)
(* ------------------------------------------------------------------ *)

PROCEDURE TypeByteMul(pos: INTEGER): INTEGER;
BEGIN
  CASE pos OF
    0: RETURN 64
   |1: RETURN 16
   |2: RETURN 4
  ELSE
    RETURN 1
  END
END TypeByteMul;

PROCEDURE ApplyForced(haveForced: BOOLEAN; VAR forced: ARRAY OF INTEGER; opIndex: INTEGER;
                        ctx: Context; l: ZapfAst.Line; VAR otype, ovalue: INTEGER);
VAR msg: ARRAY 160 OF CHAR;
BEGIN
  IF haveForced & (forced[opIndex + 1] >= 0) THEN
    CASE forced[opIndex + 1] OF
      OpByte:
        IF (ovalue > 255) OR (ovalue < 0) THEN
          Strings.Copy(".OPERAND cannot encode this value as BYTE", msg);
          Serious(ctx, l.sourceFile, l.lineNum, msg)
        END;
        otype := OpByte
     |OpWord: otype := OpWord
     |OpVar: otype := OpVar
    ELSE
    END
  END
END ApplyForced;

PROCEDURE HandleInstruction*(ctx: Context; l: ZapfAst.Line);
VAR idx, opcode, operandCount, i: INTEGER;
    ops: ARRAY 8 OF ZapfExpr.Expr;
    otype, ovalue: ARRAY 8 OF INTEGER;
    hasFix: ARRAY 8 OF BOOLEAN;
    fixName: ARRAY 8 OF ARRAY 80 OF CHAR;
    effVer: INTEGER;
    forceTwoOp, forceVarForm, needVar: BOOLEAN;
    haveForced: BOOLEAN;
    forced: ARRAY 9 OF INTEGER;
    n: ZapfAst.ExprNode;
    msg: ARRAY 160 OF CHAR;
    sym: Symbol;
    flags, whenExtraLen: INTEGER;
    b, typeByte, maxArgs: INTEGER;
    polarity, far: BOOLEAN;
    offset: INTEGER;
BEGIN
  effVer := ZapfOpcodes.EffectiveVersion(ctx.zversion);
  IF ~ZapfOpcodes.Lookup(l.name, effVer, ctx.informMode, idx) THEN
    Strings.Copy("unknown opcode: ", msg); Strings.Append(l.name, msg);
    Serious(ctx, l.sourceFile, l.lineNum, msg);
    RETURN
  END;
  opcode := ZapfOpcodes.opTable[idx].number;
  flags := ZapfOpcodes.opTable[idx].flags;
  operandCount := l.exprList.count;
  n := l.exprList.head; i := 0;
  WHILE n # NIL DO ops[i] := n.e; INC(i); n := n.next END;

  IF (ZapfOpcodes.opTable[idx].whenExtra[0] # 0X) & (operandCount > 4) THEN
    IF ZapfOpcodes.Lookup(ZapfOpcodes.opTable[idx].whenExtra, effVer, ctx.informMode, idx) THEN
      opcode := ZapfOpcodes.opTable[idx].number;
      flags := ZapfOpcodes.opTable[idx].flags
    END
  END;

  forceTwoOp := ctx.hasPendingForm & (ctx.pendingForm = "2OP");
  forceVarForm := ctx.hasPendingForm & (ctx.pendingForm = "VAR");
  ctx.hasPendingForm := FALSE;

  haveForced := ctx.hasPendingOpEnc;
  IF haveForced THEN
    FOR i := 1 TO 8 DO forced[i] := ctx.pendingOpEnc[i] END;
    ctx.hasPendingOpEnc := FALSE;
    FOR i := 1 TO 8 DO
      IF (forced[i] >= 0) & ((i < 1) OR (i > operandCount)) THEN
        Strings.Copy(".OPERAND index out of range for this instruction", msg);
        Serious(ctx, l.sourceFile, l.lineNum, msg)
      END
    END
  ELSE
    FOR i := 1 TO 8 DO forced[i] := -1 END
  END;

  IF forceTwoOp THEN
    IF opcode >= 224 THEN
      Serious(ctx, l.sourceFile, l.lineNum, ".FORM 2OP is not valid for this instruction")
    ELSIF opcode >= 192 THEN
      opcode := opcode - 192
    END;
    IF operandCount > 2 THEN
      Serious(ctx, l.sourceFile, l.lineNum, ".FORM 2OP cannot be applied: too many operands")
    END
  END;

  IF forceVarForm & (opcode < 192) THEN
    IF opcode < 128 THEN opcode := opcode + 192
    ELSE Serious(ctx, l.sourceFile, l.lineNum, ".FORM VAR is only valid for 2OP instructions")
    END
  END;

  IF (opcode < 128) & ~forceTwoOp THEN
    needVar := operandCount > 2;
    IF ~needVar THEN
      FOR i := 0 TO operandCount - 1 DO
        IF IsLongConstant(ctx, ops[i], l.sourceFile, l.lineNum) THEN needVar := TRUE END
      END
    END;
    IF needVar THEN opcode := opcode + 192 END
  END;

  IF ctx.abortLine THEN RETURN END;

  IF opcode < 128 THEN
    (* 2OP long form *)
    IF operandCount # 2 THEN
      Serious(ctx, l.sourceFile, l.lineNum, "expected 2 operands"); RETURN
    END;
    b := opcode;
    EvalOperand(ctx, ops[0], FALSE, l.sourceFile, l.lineNum, otype[0], ovalue[0], hasFix[0], fixName[0]);
    EvalOperand(ctx, ops[1], FALSE, l.sourceFile, l.lineNum, otype[1], ovalue[1], hasFix[1], fixName[1]);
    ApplyForced(haveForced, forced, 0, ctx, l, otype[0], ovalue[0]);
    ApplyForced(haveForced, forced, 1, ctx, l, otype[1], ovalue[1]);
    IF (otype[0] = OpWord) OR (otype[1] = OpWord) THEN
      Serious(ctx, l.sourceFile, l.lineNum, ".FORM 2OP requires byte or variable operands; use .FORM VAR for word operands");
      RETURN
    END;
    IF otype[0] = OpVar THEN b := b + 040H END;
    IF otype[1] = OpVar THEN b := b + 020H END;
    WriteByte(ctx, b);
    WriteByte(ctx, ovalue[0]);
    WriteByte(ctx, ovalue[1])
  ELSIF opcode < 176 THEN
    (* 1OP *)
    IF operandCount # 1 THEN
      Serious(ctx, l.sourceFile, l.lineNum, "expected 1 operand"); RETURN
    END;
    b := opcode;
    EvalOperand(ctx, ops[0], (flags DIV ZapfOpcodes.FlLabel) MOD 2 = 1, l.sourceFile, l.lineNum,
                otype[0], ovalue[0], hasFix[0], fixName[0]);
    IF (flags DIV ZapfOpcodes.FlLabel) MOD 2 = 1 THEN
      ovalue[0] := ovalue[0] - 1  (* -3 for opcode+operand, +2 for jump bias *)
    END;
    ApplyForced(haveForced, forced, 0, ctx, l, otype[0], ovalue[0]);
    b := b + otype[0] * 16;
    WriteByte(ctx, b);
    IF hasFix[0] THEN AddFixup(ctx, fixName[0], ctx.position) END;
    IF otype[0] = OpWord THEN WriteWord(ctx, ovalue[0]) ELSE WriteByte(ctx, ovalue[0]) END
  ELSIF opcode < 192 THEN
    (* 0OP *)
    IF (flags DIV ZapfOpcodes.FlString) MOD 2 = 0 THEN
      IF operandCount # 0 THEN
        Serious(ctx, l.sourceFile, l.lineNum, "expected 0 operands"); RETURN
      END;
      WriteByte(ctx, opcode)
    ELSE
      IF (operandCount # 1) OR (ops[0].kind # ZapfExpr.KindStr) THEN
        Serious(ctx, l.sourceFile, l.lineNum, "expected literal string as only operand"); RETURN
      END;
      WriteByte(ctx, opcode);
      WriteZString(ctx, ops[0].text, FALSE, ZapfZChar.ModeNormal)
    END
  ELSE
    (* VAR / EXT *)
    IF (flags DIV ZapfOpcodes.FlExtra) MOD 2 = 0 THEN maxArgs := 4 ELSE maxArgs := 8 END;
    IF operandCount > maxArgs THEN
      Serious(ctx, l.sourceFile, l.lineNum, "too many operands"); RETURN
    END;
    IF opcode >= 256 THEN
      WriteByte(ctx, 190);
      WriteByte(ctx, opcode - 256)
    ELSE
      WriteByte(ctx, opcode)
    END;

    typeByte := 0;
    FOR i := 0 TO maxArgs - 1 DO
      IF i < operandCount THEN
        EvalOperand(ctx, ops[i], FALSE, l.sourceFile, l.lineNum, otype[i], ovalue[i], hasFix[i], fixName[i]);
        ApplyForced(haveForced, forced, i, ctx, l, otype[i], ovalue[i])
      ELSE
        otype[i] := OpOmitted
      END;
      typeByte := typeByte + otype[i] * TypeByteMul(i MOD 4);
      IF i MOD 4 = 3 THEN WriteByte(ctx, typeByte); typeByte := 0 END
    END;

    FOR i := 0 TO operandCount - 1 DO
      IF hasFix[i] THEN AddFixup(ctx, fixName[i], ctx.position) END;
      IF otype[i] = OpWord THEN WriteWord(ctx, ovalue[i]) ELSE WriteByte(ctx, ovalue[i]) END
    END
  END;

  IF ctx.abortLine THEN RETURN END;

  IF (flags DIV ZapfOpcodes.FlStore) MOD 2 = 1 THEN
    IF l.storeTarget[0] = 0X THEN
      WriteByte(ctx, 0)
    ELSE
      sym := FindLocal(ctx, l.storeTarget);
      IF sym = NIL THEN sym := FindGlobal(ctx, l.storeTarget) END;
      IF (sym = NIL) OR (sym.kind # SymVariable) THEN
        Serious(ctx, l.sourceFile, l.lineNum, "expected local or global variable as store target");
        WriteByte(ctx, 0)
      ELSE
        WriteByte(ctx, sym.value)
      END
    END
  END;

  IF (flags DIV ZapfOpcodes.FlBranch) MOD 2 = 1 THEN
    IF ~l.hasBranch THEN
      Serious(ctx, l.sourceFile, l.lineNum, "expected branch target")
    ELSE
      polarity := l.branchPolarity; far := FALSE;
      IF l.branchTarget = "TRUE" THEN
        offset := 1
      ELSIF l.branchTarget = "FALSE" THEN
        offset := 0
      ELSE
        sym := FindLocal(ctx, l.branchTarget);
        IF sym # NIL THEN
          offset := sym.value - (ctx.position + 1) + 2;
          IF (offset < 2) OR (offset > 63) THEN far := TRUE; offset := offset - 1 END
        ELSE
          offset := 2;
          MarkUnknownBranch(ctx, l.branchTarget)
        END
      END;

      IF (offset < -8192) OR (offset > 8191) THEN
        Serious(ctx, l.sourceFile, l.lineNum, "branch target is too far away")
      END;

      IF far THEN
        IF polarity THEN b := 08000H ELSE b := 0 END;
        WriteWord(ctx, b + (offset MOD 04000H))
      ELSE
        IF polarity THEN b := 0C0H ELSE b := 040H END;
        WriteByte(ctx, b + (offset MOD 040H))
      END
    END
  END
END HandleInstruction;

(* ------------------------------------------------------------------ *)
(* labels                                                                *)
(* ------------------------------------------------------------------ *)

PROCEDURE CheckGlobalMoved(ctx: Context; l: ZapfAst.Line; sym: Symbol; expected: INTEGER);
VAR msg: ARRAY 200 OF CHAR;
BEGIN
  IF sym.value # expected THEN
    IF InReassemblyScope(ctx) THEN
      DeferGlobalLabelStabilityCheck(ctx, l.name, expected)
    ELSIF ctx.finalPass THEN
      Strings.Copy("global label ", msg); Strings.Append(l.name, msg);
      Strings.Append(" seems to have moved", msg);
      Fatal(ctx, l.sourceFile, l.lineNum, msg)
    ELSE
      ctx.measureAgain := TRUE
    END
  END
END CheckGlobalMoved;

PROCEDURE HandleLabel*(ctx: Context; l: ZapfAst.Line; VAR nodeIndex: INTEGER);
VAR sym: Symbol; expected: INTEGER;
BEGIN
  IF l.kind = ZapfAst.LkGlobalLbl THEN
    sym := FindGlobal(ctx, l.name);
    IF sym # NIL THEN
      IF (sym.kind # SymLabel) & (sym.kind # SymUnknown) THEN
        Serious(ctx, l.sourceFile, l.lineNum, "redefining global label"); RETURN
      END;
      IF ctx.inVocab THEN
        IF ~AtVocabRecord(ctx) THEN
          Serious(ctx, l.sourceFile, l.lineNum, "unaligned global label in vocab section"); RETURN
        END;
        sym.value := ctx.position
      ELSIF sym.value # ctx.position THEN
        expected := sym.value;
        sym.value := ctx.position;
        CheckGlobalMoved(ctx, l, sym, expected)
      END;
      sym.kind := SymLabel; sym.phantom := FALSE
    ELSE
      DefineGlobal(ctx, l.name, SymLabel, ctx.position)
    END
  ELSIF l.kind = ZapfAst.LkLocalLbl THEN
    IF ~InReassemblyScope(ctx) THEN
      Serious(ctx, l.sourceFile, l.lineNum, "local labels not allowed outside a function"); RETURN
    END;
    sym := FindLocal(ctx, l.name);
    IF sym = NIL THEN
      IF CausesReassembly(ctx, l.name) THEN
        nodeIndex := Reassemble(ctx, l.name) - 1
      ELSE
        DefineLocal(ctx, l.name, SymLabel, ctx.position)
      END
    ELSIF (sym.kind = SymLabel) & sym.phantom THEN
      IF sym.value # ctx.position THEN
        nodeIndex := Reassemble(ctx, l.name) - 1
      ELSE
        sym.phantom := FALSE
      END
    ELSE
      Serious(ctx, l.sourceFile, l.lineNum, "redefining local label")
    END
  END
END HandleLabel;

(* ------------------------------------------------------------------ *)
(* .FUNCT / .GSTR / .FSTR / .UNICHR                                      *)
(* ------------------------------------------------------------------ *)

PROCEDURE BeginFunction*(ctx: Context; l: ZapfAst.Line; nodeIndex: INTEGER);
VAR n: ZapfAst.FunctLocalNode; count, paddr, dk, dv: INTEGER;
    sym: Symbol; msg: ARRAY 160 OF CHAR; gotDefaults: BOOLEAN;
    localVals: ARRAY 16 OF INTEGER;
BEGIN
  count := 0; gotDefaults := FALSE;
  n := l.locals;
  WHILE n # NIL DO
    IF FindLocal(ctx, n.name) # NIL THEN
      Strings.Copy("duplicate local: ", msg); Strings.Append(n.name, msg);
      Serious(ctx, l.sourceFile, l.lineNum, msg); RETURN
    END;
    INC(count);
    DefineLocal(ctx, n.name, SymVariable, count);
    IF n.defaultVal # NIL THEN
      gotDefaults := TRUE;
      EvalExpr(ctx, n.defaultVal, l.sourceFile, l.lineNum, dk, dv);
      IF count <= LEN(localVals) THEN localVals[count - 1] := dv END
    ELSE
      IF count <= LEN(localVals) THEN localVals[count - 1] := 0 END
    END;
    n := n.next
  END;

  IF count > 15 THEN
    Serious(ctx, l.sourceFile, l.lineNum, "too many local variables")
  END;

  AlignRoutine(ctx);

  paddr := (ctx.position - ctx.functionsOffset) DIV PackingDivisor(ctx);
  sym := FindGlobal(ctx, l.name);
  IF sym = NIL THEN
    sym := DefineGlobal(ctx, l.name, SymFunction, paddr)
  ELSIF (sym.kind # SymUnknown) & (~sym.phantom OR (sym.kind # SymFunction)) THEN
    Strings.Copy("function redefined: ", msg); Strings.Append(l.name, msg);
    Serious(ctx, l.sourceFile, l.lineNum, msg); RETURN
  ELSE
    sym.kind := SymFunction;
    sym.phantom := FALSE;
    IF sym.value # paddr THEN
      sym.value := paddr;
      ctx.measureAgain := TRUE
    END
  END;

  BeginReassemblyScope(ctx, nodeIndex, sym);

  WriteByte(ctx, count);
  IF ctx.zversion < 5 THEN
    FOR dv := 0 TO count - 1 DO WriteWord(ctx, localVals[dv]) END
  ELSIF gotDefaults THEN
    Warn(ctx, l.sourceFile, l.lineNum, "ignoring default local variable values")
  END
END BeginFunction;

PROCEDURE PackString*(ctx: Context; l: ZapfAst.Line);
VAR paddr: INTEGER; sym: Symbol; msg: ARRAY 160 OF CHAR;
BEGIN
  AlignString(ctx);
  paddr := (ctx.position - ctx.stringsOffset) DIV PackingDivisor(ctx);
  sym := FindGlobal(ctx, l.name);
  IF sym = NIL THEN
    sym := DefineGlobal(ctx, l.name, SymString, paddr)
  ELSIF (sym.kind # SymUnknown) & (~sym.phantom OR (sym.kind # SymString)) THEN
    Strings.Copy("string redefined: ", msg); Strings.Append(l.name, msg);
    Serious(ctx, l.sourceFile, l.lineNum, msg); RETURN
  ELSE
    sym.kind := SymString;
    sym.phantom := FALSE;
    IF sym.value # paddr THEN
      sym.value := paddr;
      ctx.measureAgain := TRUE
    END
  END;
  WriteZString(ctx, l.text, FALSE, ZapfZChar.ModeNormal)
END PackString;

PROCEDURE AddAbbreviation*(ctx: Context; l: ZapfAst.Line);
VAR msg: ARRAY 160 OF CHAR;
BEGIN
  IF ZapfZChar.frozen THEN
    Serious(ctx, l.sourceFile, l.lineNum, "abbreviations must be defined before strings"); RETURN
  END;
  IF ctx.position MOD 2 # 0 THEN WriteByte(ctx, 0) END;
  DefineGlobal(ctx, l.name, SymConstant, ctx.position DIV 2);
  WriteZString(ctx, l.text, FALSE, ZapfZChar.ModeNoAbbrev);
  IF Strings.Length(l.text) > 0 THEN
    IF ~ZapfZChar.AddAbbreviation(l.text) THEN
      Strings.Copy("could not add abbreviation (too many, or defined too late)", msg);
      Warn(ctx, l.sourceFile, l.lineNum, msg)
    END
  END
END AddAbbreviation;

PROCEDURE HexDigit(c: CHAR): INTEGER;
BEGIN
  IF (c >= "0") & (c <= "9") THEN RETURN ORD(c) - ORD("0")
  ELSIF (c >= "A") & (c <= "F") THEN RETURN ORD(c) - ORD("A") + 10
  ELSIF (c >= "a") & (c <= "f") THEN RETURN ORD(c) - ORD("a") + 10
  ELSE RETURN -1
  END
END HexDigit;

PROCEDURE HandleUnichr*(ctx: Context; l: ZapfAst.Line);
VAR codepoint, i, d, n: INTEGER; ok: BOOLEAN; msg: ARRAY 200 OF CHAR;
BEGIN
  n := Strings.Length(l.text);
  ok := TRUE; codepoint := 0;
  IF (n > 2) & ((l.text[0] = "U") OR (l.text[0] = "u")) & (l.text[1] = "+") THEN
    IF n = 3 THEN ok := FALSE END;
    FOR i := 2 TO n - 1 DO
      d := HexDigit(l.text[i]);
      IF d < 0 THEN ok := FALSE ELSE codepoint := codepoint * 16 + d END
    END
  ELSIF n = 1 THEN
    codepoint := ORD(l.text[0])
  ELSE
    ok := FALSE
  END;
  IF ~ok THEN
    Strings.Copy(".UNICHR requires exactly one character or a U+XXXX literal", msg);
    Serious(ctx, l.sourceFile, l.lineNum, msg);
    RETURN
  END;
  IF ctx.unicodeTableCount >= LEN(ctx.unicodeCodepoints) THEN
    Serious(ctx, l.sourceFile, l.lineNum, ".UNICHR table can hold at most 97 entries");
    RETURN
  END;
  i := 0;
  WHILE i < ctx.unicodeTableCount DO
    IF ctx.unicodeCodepoints[i] = codepoint THEN
      Serious(ctx, l.sourceFile, l.lineNum, "duplicate .UNICHR codepoint");
      RETURN
    END;
    INC(i)
  END;
  ZapfZChar.AddUnicodeMapping(codepoint, ctx.unicodeTableCount);
  ctx.unicodeCodepoints[ctx.unicodeTableCount] := codepoint;
  INC(ctx.unicodeTableCount);
  WriteWord(ctx, codepoint)
END HandleUnichr;

(* ------------------------------------------------------------------ *)
(* everything else: HandleDirective                                     *)
(* ------------------------------------------------------------------ *)

PROCEDURE HandleDirective*(ctx: Context; l: ZapfAst.Line; nodeIndex: INTEGER; assembling: BOOLEAN);
VAR k, v, k2, v2, i, divisor: INTEGER;
    n: ZapfAst.ExprNode;
    ex: ZapfExpr.Expr;
    sym: Symbol;
    msg: ARRAY 200 OF CHAR;
    csChars: ARRAY 32 OF INTEGER; csCount: INTEGER;
    e1, e2, e3, e4, e5, e6, e7: INTEGER;
    ek1, ek2, ek3, ek4, ek5, ek6, ek7: INTEGER;
    haveFlags3: BOOLEAN;
    encTxt: ARRAY 24 OF CHAR;
BEGIN
  IF (l.kind # ZapfAst.LkNew) THEN
    (* local scope ends on any directive except .FORM/.OPERAND (they apply
       to the NEXT instruction) -- .DEBUG-LINE is skipped entirely (out of
       scope) so it never reaches here as a distinct kind. *)
    IF (l.kind # ZapfAst.LkForm) & (l.kind # ZapfAst.LkOperand) THEN
      EndReassemblyScope(ctx, nodeIndex)
    END
  END;

  CASE l.kind OF
    ZapfAst.LkNull, ZapfAst.LkNew, ZapfAst.LkTime, ZapfAst.LkSound,
    ZapfAst.LkInsert, ZapfAst.LkEnd, ZapfAst.LkEndi:
      (* no-op here: .NEW/.TIME/.SOUND are handled directly by PassOne;
         .INSERT was already resolved before either pass ran;
         .END/.ENDI terminate the pass loop before HandleDirective runs *)

   |ZapfAst.LkLang:
      EvalExpr(ctx, l.exprA, l.sourceFile, l.lineNum, k, v);
      EvalExpr(ctx, l.exprB, l.sourceFile, l.lineNum, k2, v2);
      SetLanguage(ctx, v, v2)

   |ZapfAst.LkChrset:
      IF ctx.zversion >= 5 THEN
        EvalExpr(ctx, l.exprA, l.sourceFile, l.lineNum, k, v);
        IF (v < 0) OR (v > 2) THEN
          Fatal(ctx, l.sourceFile, l.lineNum, "no such character set")
        END;
        csCount := 0;
        n := l.exprList.head;
        WHILE n # NIL DO
          EvalExpr(ctx, n.e, l.sourceFile, l.lineNum, k2, v2);
          IF csCount < LEN(csChars) THEN csChars[csCount] := v2; INC(csCount) END;
          n := n.next
        END;
        ZapfZChar.SetCharset(v, csChars, csCount)
      ELSE
        Fatal(ctx, l.sourceFile, l.lineNum, ".CHRSET is only supported in Z-machine versions 5-8")
      END

   |ZapfAst.LkFunct:
      BeginFunction(ctx, l, nodeIndex)

   |ZapfAst.LkForm:
      IF l.text = "2OP" THEN ctx.pendingForm := "2OP"; ctx.hasPendingForm := TRUE
      ELSIF l.text = "VAR" THEN ctx.pendingForm := "VAR"; ctx.hasPendingForm := TRUE
      ELSE
        Strings.Copy("unrecognized form specifier: ", msg); Strings.Append(l.text, msg);
        Serious(ctx, l.sourceFile, l.lineNum, msg)
      END

   |ZapfAst.LkOperand:
      EvalExpr(ctx, l.exprA, l.sourceFile, l.lineNum, k, v);
      IF k # SymConstant THEN
        Serious(ctx, l.sourceFile, l.lineNum, ".OPERAND index must be constant")
      ELSIF (v < 1) OR (v > 8) THEN
        Serious(ctx, l.sourceFile, l.lineNum, ".OPERAND index must be 1-8")
      ELSE
        Strings.Copy(l.text, encTxt);
        IF ~ctx.hasPendingOpEnc THEN
          FOR i := 1 TO 8 DO ctx.pendingOpEnc[i] := -1 END;
          ctx.hasPendingOpEnc := TRUE
        END;
        IF (encTxt = "LONG") OR (encTxt = "WORD") THEN ctx.pendingOpEnc[v] := OpWord
        ELSIF (encTxt = "SHORT") OR (encTxt = "BYTE") THEN ctx.pendingOpEnc[v] := OpByte
        ELSIF (encTxt = "VAR") OR (encTxt = "VARIABLE") THEN ctx.pendingOpEnc[v] := OpVar
        ELSE
          Strings.Copy("unrecognized operand encoding: ", msg); Strings.Append(encTxt, msg);
          Serious(ctx, l.sourceFile, l.lineNum, msg)
        END
      END

   |ZapfAst.LkCreator:
      IF ~ctx.creatorSpecified THEN Strings.Copy(l.text, ctx.creator) END

   |ZapfAst.LkAlign:
      EvalExpr(ctx, l.exprA, l.sourceFile, l.lineNum, k, v);
      IF k # SymConstant THEN
        Serious(ctx, l.sourceFile, l.lineNum, "non-constant argument to .ALIGN")
      ELSE
        AlignUnpacked(ctx, v)
      END

   |ZapfAst.LkTable:
      IF ctx.tableStart >= 0 THEN
        Warn(ctx, l.sourceFile, l.lineNum, "starting new table before ending old table")
      END;
      ctx.tableStart := ctx.position;
      ctx.tableSize := -1;
      IF l.exprA # NIL THEN
        EvalExpr(ctx, l.exprA, l.sourceFile, l.lineNum, k, v);
        IF k # SymConstant THEN
          Warn(ctx, l.sourceFile, l.lineNum, "ignoring non-constant table size specifier")
        ELSE
          ctx.tableSize := v
        END
      END

   |ZapfAst.LkEndt:
      IF ctx.tableStart < 0 THEN
        Warn(ctx, l.sourceFile, l.lineNum, "ignoring .ENDT outside of a table definition")
      ELSE
        IF (ctx.tableSize >= 0) & (ctx.position - ctx.tableStart # ctx.tableSize) THEN
          Warn(ctx, l.sourceFile, l.lineNum, "incorrect table size")
        END
      END;
      ctx.tableStart := -1; ctx.tableSize := -1

   |ZapfAst.LkVocbeg:
      IF ctx.inVocab THEN
        Warn(ctx, l.sourceFile, l.lineNum, "ignoring .VOCBEG inside another vocabulary block")
      ELSE
        EvalExpr(ctx, l.exprA, l.sourceFile, l.lineNum, k, v);
        EvalExpr(ctx, l.exprB, l.sourceFile, l.lineNum, k2, v2);
        IF (k # SymConstant) OR (k2 # SymConstant) THEN
          Warn(ctx, l.sourceFile, l.lineNum, "ignoring .VOCBEG with non-constant size specifiers")
        ELSE
          EnterVocab(ctx, v, v2)
        END
      END

   |ZapfAst.LkVocend:
      IF ~ctx.inVocab THEN
        Warn(ctx, l.sourceFile, l.lineNum, "ignoring .VOCEND outside of a vocabulary block")
      ELSE
        LeaveVocab(ctx)
      END

   |ZapfAst.LkByte:
      n := l.exprList.head;
      WHILE n # NIL DO
        ex := n.e;
        EvalExpr(ctx, ex, l.sourceFile, l.lineNum, k, v);
        IF (k = SymUnknown) & ctx.finalPass THEN
          Strings.Copy("unrecognized symbol: ", msg); Strings.Append(ex.text, msg);
          Fatal(ctx, l.sourceFile, l.lineNum, msg)
        END;
        IF (k = SymLabel) & ctx.inVocab THEN
          Fatal(ctx, l.sourceFile, l.lineNum, "global label refs inside vocab section must be assembled as words")
        END;
        IF (v < -128) OR (v > 255) THEN
          Warn(ctx, l.sourceFile, l.lineNum, "byte value out of range")
        END;
        WriteByte(ctx, v);
        n := n.next
      END

   |ZapfAst.LkWord:
      n := l.exprList.head;
      WHILE n # NIL DO
        ex := n.e;
        EvalExpr(ctx, ex, l.sourceFile, l.lineNum, k, v);
        IF (k = SymUnknown) & ctx.finalPass THEN
          Strings.Copy("unrecognized symbol: ", msg); Strings.Append(ex.text, msg);
          Fatal(ctx, l.sourceFile, l.lineNum, msg)
        END;
        IF (k = SymLabel) & ctx.inVocab & (ex.kind = ZapfExpr.KindSym) THEN
          AddFixup(ctx, ex.text, ctx.position)
        END;
        WriteWord(ctx, v);
        n := n.next
      END

   |ZapfAst.LkUnichr:
      HandleUnichr(ctx, l)

   |ZapfAst.LkFstr:
      AddAbbreviation(ctx, l)

   |ZapfAst.LkGstr:
      PackString(ctx, l)

   |ZapfAst.LkStr:
      WriteZString(ctx, l.text, FALSE, ZapfZChar.ModeNormal)

   |ZapfAst.LkStrl:
      WriteZString(ctx, l.text, TRUE, ZapfZChar.ModeNormal)

   |ZapfAst.LkLen:
      WriteZStringLength(ctx, l.text)

   |ZapfAst.LkZword:
      WriteZWord(ctx, l.text)

   |ZapfAst.LkEquals:
      EvalExpr(ctx, l.exprA, l.sourceFile, l.lineNum, k, v);
      IF (k = SymUnknown) & ctx.finalPass THEN
        Fatal(ctx, l.sourceFile, l.lineNum, "unrecognized symbol")
      ELSE
        DefineGlobal(ctx, l.name, k, v)
      END

   |ZapfAst.LkGvar:
      sym := AddGlobalVar(ctx, l.name, l.sourceFile, l.lineNum);
      IF l.exprA # NIL THEN
        EvalExpr(ctx, l.exprA, l.sourceFile, l.lineNum, k, v);
        IF (k = SymUnknown) & ctx.finalPass THEN
          Fatal(ctx, l.sourceFile, l.lineNum, "unrecognized symbol")
        END;
        WriteWord(ctx, v)
      ELSE
        WriteWord(ctx, 0)
      END

   |ZapfAst.LkObject:
      sym := AddObject(ctx, l.name, l.sourceFile, l.lineNum);
      EvalExpr(ctx, l.exprA, l.sourceFile, l.lineNum, ek1, e1);
      EvalExpr(ctx, l.exprB, l.sourceFile, l.lineNum, ek2, e2);
      haveFlags3 := l.exprC # NIL;
      IF haveFlags3 THEN EvalExpr(ctx, l.exprC, l.sourceFile, l.lineNum, ek3, e3) END;
      EvalExpr(ctx, l.exprD, l.sourceFile, l.lineNum, ek4, e4);
      EvalExpr(ctx, l.exprE, l.sourceFile, l.lineNum, ek5, e5);
      EvalExpr(ctx, l.exprF, l.sourceFile, l.lineNum, ek6, e6);
      EvalExpr(ctx, l.exprG, l.sourceFile, l.lineNum, ek7, e7);
      IF ctx.zversion < 4 THEN
        WriteWord(ctx, e1); WriteWord(ctx, e2);
        IF haveFlags3 THEN
          Serious(ctx, l.sourceFile, l.lineNum, "wrong .OBJECT syntax for this version")
        END;
        WriteByte(ctx, e4); WriteByte(ctx, e5); WriteByte(ctx, e6);
        WriteWord(ctx, e7)
      ELSE
        WriteWord(ctx, e1); WriteWord(ctx, e2);
        IF ~haveFlags3 THEN
          Serious(ctx, l.sourceFile, l.lineNum, "wrong .OBJECT syntax for this version");
          WriteWord(ctx, 0)
        ELSE
          WriteWord(ctx, e3)
        END;
        WriteWord(ctx, e4); WriteWord(ctx, e5); WriteWord(ctx, e6);
        WriteWord(ctx, e7)
      END

   |ZapfAst.LkProp:
      EvalExpr(ctx, l.exprA, l.sourceFile, l.lineNum, ek1, e1);
      EvalExpr(ctx, l.exprB, l.sourceFile, l.lineNum, ek2, e2);
      IF ctx.finalPass & ((ek1 # SymConstant) OR (ek2 # SymConstant)) THEN
        Serious(ctx, l.sourceFile, l.lineNum, "non-constant arguments to .PROP")
      END;
      IF ctx.zversion < 4 THEN
        IF e1 > 8 THEN Serious(ctx, l.sourceFile, l.lineNum, "property too long (8 bytes max in V3)") END;
        WriteByte(ctx, 32 * (e1 - 1) + e2)
      ELSIF e1 > 2 THEN
        IF e1 > 64 THEN Serious(ctx, l.sourceFile, l.lineNum, "property too long (64 bytes max in V4+)") END;
        WriteByte(ctx, e2 + 128);
        WriteByte(ctx, e1 + 128)
      ELSE
        IF e1 = 2 THEN WriteByte(ctx, e2 + 64) ELSE WriteByte(ctx, e2) END
      END

  ELSE
    (* LkInstr/LkLocalLbl/LkGlobalLbl/LkBareSym are handled by the caller,
       never reach HandleDirective *)
  END
END HandleDirective;

(* ------------------------------------------------------------------ *)
(* header / finalize                                                     *)
(* ------------------------------------------------------------------ *)

PROCEDURE GetHeaderValue*(ctx: Context; name: ARRAY OF CHAR; required: BOOLEAN): INTEGER;
VAR sym: Symbol; msg: ARRAY 200 OF CHAR;
BEGIN
  sym := FindGlobal(ctx, name);
  IF sym # NIL THEN
    IF (sym.kind = SymLabel) OR (sym.kind = SymFunction) OR (sym.kind = SymConstant) THEN
      RETURN sym.value
    ELSE
      RETURN 0
    END
  END;
  IF required THEN
    Strings.Copy("required global symbol '", msg); Strings.Append(name, msg); Strings.Append("' is missing", msg);
    Serious(ctx, "", 0, msg)
  END;
  RETURN 0
END GetHeaderValue;

PROCEDURE GetHeaderValue2(ctx: Context; name1, name2: ARRAY OF CHAR; required: BOOLEAN): INTEGER;
VAR sym: Symbol;
BEGIN
  sym := FindGlobal(ctx, name1);
  IF sym = NIL THEN sym := FindGlobal(ctx, name2) END;
  IF sym # NIL THEN
    IF (sym.kind = SymLabel) OR (sym.kind = SymFunction) OR (sym.kind = SymConstant) THEN RETURN sym.value ELSE RETURN 0 END
  END;
  IF required THEN Serious(ctx, "", 0, "required global symbol is missing") END;
  RETURN 0
END GetHeaderValue2;

(* Auto-generates the 64-byte header for V1-4 (V5+ headers are laid out
   manually by the source via ordinary data directives). *)
PROCEDURE WriteHeader*(ctx: Context; strict: BOOLEAN);
VAR endlod, start, impure: INTEGER; msg: ARRAY 160 OF CHAR;
BEGIN
  WriteByte(ctx, ctx.zversion);
  WriteByte(ctx, ctx.zflags);
  WriteWord(ctx, GetHeaderValue2(ctx, "RELEASEID", "ZORKID", FALSE));
  endlod := GetHeaderValue(ctx, "ENDLOD", strict);
  WriteWord(ctx, endlod);
  start := GetHeaderValue(ctx, "START", strict);
  WriteWord(ctx, start);
  WriteWord(ctx, GetHeaderValue(ctx, "VOCAB", strict));
  WriteWord(ctx, GetHeaderValue(ctx, "OBJECT", strict));
  WriteWord(ctx, GetHeaderValue(ctx, "GLOBAL", strict));
  impure := GetHeaderValue(ctx, "IMPURE", strict);
  WriteWord(ctx, impure);
  WriteWord(ctx, ctx.zflags2);
  WriteWord(ctx, 0); WriteWord(ctx, 0); WriteWord(ctx, 0);  (* serial, filled in later *)
  WriteWord(ctx, GetHeaderValue(ctx, "WORDS", strict));
  WriteWord(ctx, 0);  (* packed program length, filled in later *)
  WriteWord(ctx, 0);  (* checksum, filled in later *)

  WHILE ctx.position < 64 DO WriteByte(ctx, 0) END;

  IF start >= 65536 THEN
    Strings.Copy("START must be in the first 64k", msg); Serious(ctx, "", 0, msg)
  END;
  IF impure >= 65536 THEN
    Strings.Copy("IMPURE must be in the first 64k", msg); Serious(ctx, "", 0, msg)
  END;
  IF endlod < impure THEN
    Strings.Copy("ENDLOD must be after IMPURE", msg); Serious(ctx, "", 0, msg)
  END
END WriteHeader;

PROCEDURE CheckHeaderFits(ctx: Context; name: ARRAY OF CHAR; val: INTEGER);
VAR msg: ARRAY 200 OF CHAR;
BEGIN
  IF val >= 65536 THEN
    Strings.Copy(name, msg); Strings.Append(" must be in the first 64k", msg);
    Serious(ctx, "", 0, msg)
  END
END CheckHeaderFits;

PROCEDURE WarnPackedOverflow(ctx: Context);
VAR i: INTEGER; s: Symbol; msg: ARRAY 200 OF CHAR;
BEGIN
  FOR i := 0 TO NumBuckets - 1 DO
    s := ctx.globalBuckets[i];
    WHILE s # NIL DO
      IF s.value >= 65536 THEN
        IF s.kind = SymFunction THEN
          Strings.Copy("packed address overflow for function: ", msg); Strings.Append(s.name, msg);
          Warn(ctx, "", 0, msg)
        ELSIF s.kind = SymString THEN
          Strings.Copy("packed address overflow for string: ", msg); Strings.Append(s.name, msg);
          Warn(ctx, "", 0, msg)
        END
      END;
      s := s.hnext
    END
  END
END WarnPackedOverflow;

(* PadRight(4,' ') then PadLeft(8,NUL) then take the first 8 chars --
   replicates the original's exact two-stage creator-ID padding. *)
PROCEDURE PadCreator(src: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR);
VAR tmp: ARRAY 32 OF CHAR; n, i, pad: INTEGER;
BEGIN
  Strings.Copy(src, tmp);
  WHILE Strings.Length(tmp) < 4 DO Strings.Append(" ", tmp) END;
  n := Strings.Length(tmp);
  IF n < 8 THEN
    pad := 8 - n;
    FOR i := 0 TO pad - 1 DO dst[i] := 0X END;
    FOR i := 0 TO n - 1 DO dst[pad + i] := tmp[i] END
  ELSE
    FOR i := 0 TO 7 DO dst[i] := tmp[i] END
  END
END PadCreator;

PROCEDURE FixOutputExtension*(ctx: Context);
VAR n, i: INTEGER; base: ARRAY 512 OF CHAR; verStr: ARRAY 4 OF CHAR;
BEGIN
  n := Strings.Length(ctx.outFile);
  IF (n >= 3) & (ctx.outFile[n-3] = ".") & (ctx.outFile[n-2] = "z") & (ctx.outFile[n-1] = "#") THEN
    FOR i := 0 TO n - 4 DO base[i] := ctx.outFile[i] END;
    base[n - 3] := 0X;
    Strings.IntToStr(ctx.zversion, verStr);
    Strings.Copy(base, ctx.outFile);
    Strings.Append(".z", ctx.outFile);
    Strings.Append(verStr, ctx.outFile)
  END
END FixOutputExtension;

PROCEDURE FinalizeOutput*(ctx: Context);
CONST MinSize = 512;
VAR length, maxLength, checksum: INTEGER;
    serial: ARRAY 16 OF CHAR;
    creatorBuf: ARRAY 10 OF CHAR;
    msg: ARRAY 200 OF CHAR;
    start, impure, i: INTEGER;
BEGIN
  WHILE ctx.position < MinSize DO WriteByte(ctx, 0) END;
  WHILE ctx.position MOD HeaderLengthDivisor(ctx) # 0 DO WriteByte(ctx, 0) END;
  length := ctx.position;

  CASE ctx.zversion OF
    1, 2, 3: maxLength := 128
   |4, 5: maxLength := 256
   |7: maxLength := 320
  ELSE
    maxLength := 512
  END;

  IF length > maxLength * 1024 THEN
    Strings.Copy("file length exceeds platform limit", msg);
    Serious(ctx, "", 0, msg);
    RETURN
  END;

  ctx.position := 64;
  checksum := 0;
  WHILE ctx.position < length DO
    checksum := (checksum + ReadByte(ctx)) MOD 65536;
    ctx.position := ctx.position + 1
  END;

  ctx.position := 0;
  WriteByte(ctx, ctx.zversion);

  IF ctx.zversion >= 5 THEN
    start := GetHeaderValue(ctx, "START", FALSE);
    impure := GetHeaderValue(ctx, "IMPURE", FALSE);
    CheckHeaderFits(ctx, "START", start);
    CheckHeaderFits(ctx, "IMPURE", impure)
  END;

  IF ctx.releaseSpecified THEN
    ctx.position := 2;
    WriteWord(ctx, ctx.release)
  END;

  IF ~ctx.serialSpecified THEN
    Time.Format(Time.Now(), "%y%m%d", serial)
  ELSE
    Strings.Copy(ctx.serial, serial);
    WHILE Strings.Length(serial) < 6 DO Strings.Append(" ", serial) END
  END;
  ctx.position := 012H;
  FOR i := 0 TO 5 DO WriteByte(ctx, ORD(serial[i])) END;

  ctx.position := 01AH;
  WriteWord(ctx, length DIV HeaderLengthDivisor(ctx));
  WriteWord(ctx, checksum);

  IF ~ctx.noCreator THEN
    PadCreator(ctx.creator, creatorBuf);
    ctx.position := 038H;
    FOR i := 0 TO 7 DO WriteByte(ctx, ORD(creatorBuf[i])) END
  END;

  IF ~ctx.quiet THEN
    Out.String("Wrote "); Out.Int(length, 0); Out.String(" bytes to "); Out.String(ctx.outFile); Out.Ln
  END;

  CloseOutput(ctx)
END FinalizeOutput;

(* ------------------------------------------------------------------ *)
(* two-pass driver                                                       *)
(* ------------------------------------------------------------------ *)

PROCEDURE PassOne*(ctx: Context; VAR nodeIndex: INTEGER);
VAR l: ZapfAst.Line; k, v: INTEGER; msg: ARRAY 200 OF CHAR;
BEGIN
  l := ctx.lines[nodeIndex];
  CASE l.kind OF
    ZapfAst.LkNew:
      IF l.exprA = NIL THEN v := 4 ELSE EvalExpr(ctx, l.exprA, l.sourceFile, l.lineNum, k, v) END;
      IF (v < 3) OR (v > 8) THEN
        Fatal(ctx, l.sourceFile, l.lineNum, "Only Z-machine versions 3-8 are supported")
      END;
      ctx.zversion := v

   |ZapfAst.LkTime:
      IF ctx.zversion = 3 THEN ctx.zflags := ctx.zflags + 2
      ELSE Fatal(ctx, l.sourceFile, l.lineNum, ".TIME is only supported in Z-machine version 3")
      END

   |ZapfAst.LkSound:
      IF ctx.zversion = 3 THEN ctx.zflags2 := ctx.zflags2 + 16
      ELSIF ctx.zversion = 4 THEN ctx.zflags2 := ctx.zflags2 + 128
      ELSE Fatal(ctx, l.sourceFile, l.lineNum, ".SOUND is only supported in Z-machine versions 3-4")
      END

   |ZapfAst.LkInstr:
      HandleInstruction(ctx, l)

   |ZapfAst.LkBareSym:
      IF (l.bareOperandCount > 0) OR l.bareHasStore OR l.bareHasBranch THEN
        Strings.Copy("unrecognized opcode: ", msg); Strings.Append(l.name, msg);
        Serious(ctx, l.sourceFile, l.lineNum, msg)
      ELSE
        HandleDirective(ctx, l, nodeIndex, FALSE)
      END

   |ZapfAst.LkLocalLbl, ZapfAst.LkGlobalLbl:
      HandleLabel(ctx, l, nodeIndex)

  ELSE
    HandleDirective(ctx, l, nodeIndex, FALSE)
  END
END PassOne;

PROCEDURE PassTwo*(ctx: Context; VAR nodeIndex: INTEGER);
VAR l: ZapfAst.Line;
BEGIN
  l := ctx.lines[nodeIndex];
  CASE l.kind OF
    ZapfAst.LkInstr: HandleInstruction(ctx, l)
   |ZapfAst.LkLocalLbl, ZapfAst.LkGlobalLbl: HandleLabel(ctx, l, nodeIndex)
  ELSE
    HandleDirective(ctx, l, nodeIndex, TRUE)
  END
END PassTwo;

(* ------------------------------------------------------------------ *)
(* .INSERT flattening                                                    *)
(* ------------------------------------------------------------------ *)

PROCEDURE TryFindInsertedFile(name: ARRAY OF CHAR; VAR found: ARRAY OF CHAR): BOOLEAN;
VAR f: Files.File; cand: ARRAY 600 OF CHAR;
BEGIN
  f := Files.Old(name);
  IF f # NIL THEN Files.Close(f); Strings.Copy(name, found); RETURN TRUE END;
  Strings.Copy(name, cand); Strings.Append(".zap", cand);
  f := Files.Old(cand);
  IF f # NIL THEN Files.Close(f); Strings.Copy(cand, found); RETURN TRUE END;
  Strings.Copy(name, cand); Strings.Append(".xzap", cand);
  f := Files.Old(cand);
  IF f # NIL THEN Files.Close(f); Strings.Copy(cand, found); RETURN TRUE END;
  RETURN FALSE
END TryFindInsertedFile;

(* Parses one file and appends its lines to ctx.lines, recursively
   splicing in any .INSERT'd files at the point they occur (terminating
   each inserted file's own contribution at its own .END/.ENDI, exactly
   as the original's ReadAllCode does -- but never truncating the root
   file, whose own trailing .END is left in place for the pass loops to
   detect). *)
PROCEDURE AppendFlatten(ctx: Context; VAR p: ZapfParser.Parser; filename: ARRAY OF CHAR; isRoot: BOOLEAN);
VAR ll: ZapfAst.LineList; ok: BOOLEAN; l: ZapfAst.Line; found: ARRAY 600 OF CHAR; msg: ARRAY 700 OF CHAR;
    stop: BOOLEAN;
BEGIN
  ZapfAst.InitList(ll);
  ok := ZapfParser.Parse(p, filename, ll);
  IF (~ok) OR (p.errorCount > 0) THEN
    Fatal(ctx, filename, 0, "syntax error")
  END;

  l := ll.head;
  stop := FALSE;
  WHILE (l # NIL) & ~stop DO
    IF l.kind = ZapfAst.LkInsert THEN
      IF ~TryFindInsertedFile(l.text, found) THEN
        Strings.Copy("inserted file not found: ", msg); Strings.Append(l.text, msg);
        Fatal(ctx, filename, l.lineNum, msg)
      END;
      AppendFlatten(ctx, p, found, FALSE);
      l := l.next
    ELSIF (~isRoot) & ((l.kind = ZapfAst.LkEndi) OR (l.kind = ZapfAst.LkEnd)) THEN
      stop := TRUE
    ELSE
      IF ctx.lineCount < MaxLines THEN
        ctx.lines[ctx.lineCount] := l;
        INC(ctx.lineCount)
      END;
      l := l.next
    END
  END
END AppendFlatten;

(* ------------------------------------------------------------------ *)
(* top-level assembly + CLI entry point                                  *)
(* ------------------------------------------------------------------ *)

PROCEDURE Assemble*(ctx: Context): BOOLEAN;
VAR p: ZapfParser.Parser; i: INTEGER;
    start, impure, endlod, vocab, obj, globals, words: INTEGER;
BEGIN
  ZapfParser.InitParser(p, ctx.informMode, ctx.zversion);
  ctx.lineCount := 0;
  AppendFlatten(ctx, p, ctx.inFile, TRUE);

  IF ~ctx.quiet THEN Out.String("Measuring") END;
  ctx.finalPass := FALSE;

  REPEAT
    ctx.measureAgain := FALSE;
    ctx.position := 0;
    IF ctx.zversion < 5 THEN WriteHeader(ctx, FALSE) END;

    i := 0;
    WHILE i < ctx.lineCount DO
      IF ctx.lines[i].kind = ZapfAst.LkEnd THEN
        i := ctx.lineCount
      ELSE
        ctx.abortLine := FALSE;
        PassOne(ctx, i);
        ctx.abortLine := FALSE;
        INC(i)
      END
    END;

    CheckForUndefinedSymbols(ctx);
    IF ctx.fixups # NIL THEN ctx.measureAgain := TRUE END;
    CheckLimits(ctx, ctx.inFile, 0);
    ResetBetweenPasses(ctx);

    IF ~ctx.quiet & ctx.measureAgain & (ctx.errorCount = 0) THEN Out.String(".") END
  UNTIL (~ctx.measureAgain) OR (ctx.errorCount > 0);

  IF ~ctx.quiet THEN Out.Ln END;

  IF ctx.errorCount = 0 THEN
    FixOutputExtension(ctx);
    ctx.position := 0;
    IF ctx.zversion < 5 THEN WriteHeader(ctx, TRUE) END
  END;

  IF (ctx.zversion >= 5) & (ctx.errorCount = 0) THEN
    start := GetHeaderValue(ctx, "START", FALSE);
    impure := GetHeaderValue(ctx, "IMPURE", FALSE);
    endlod := GetHeaderValue(ctx, "ENDLOD", FALSE);
    vocab := GetHeaderValue(ctx, "VOCAB", FALSE);
    obj := GetHeaderValue(ctx, "OBJECT", FALSE);
    globals := GetHeaderValue(ctx, "GLOBAL", FALSE);
    words := GetHeaderValue(ctx, "WORDS", FALSE);
    CheckHeaderFits(ctx, "START", start);
    CheckHeaderFits(ctx, "IMPURE", impure);
    CheckHeaderFits(ctx, "ENDLOD", endlod);
    CheckHeaderFits(ctx, "VOCAB", vocab);
    CheckHeaderFits(ctx, "OBJECT", obj);
    CheckHeaderFits(ctx, "GLOBAL", globals);
    CheckHeaderFits(ctx, "WORDS", words);
    IF ctx.errorCount > 0 THEN RETURN FALSE END
  END;

  WarnPackedOverflow(ctx);

  IF ctx.errorCount > 0 THEN RETURN FALSE END;

  IF ~ctx.quiet THEN Out.String("Assembling"); Out.Ln END;
  ctx.finalPass := TRUE;

  i := 0;
  WHILE i < ctx.lineCount DO
    IF ctx.lines[i].kind = ZapfAst.LkEnd THEN
      i := ctx.lineCount
    ELSE
      ctx.abortLine := FALSE;
      PassTwo(ctx, i);
      ctx.abortLine := FALSE;
      INC(i)
    END
  END;

  IF ctx.fixups # NIL THEN
    Serious(ctx, "", 0, "unresolved references after final pass")
  END;

  FinalizeOutput(ctx);

  RETURN ctx.errorCount = 0
END Assemble;

PROCEDURE PrintLabelAddresses*(ctx: Context);
VAR i: INTEGER; s: Symbol; addr: INTEGER; has: BOOLEAN;
BEGIN
  Out.Ln;
  FOR i := 0 TO NumBuckets - 1 DO
    s := ctx.globalBuckets[i];
    WHILE s # NIL DO
      has := TRUE;
      IF s.kind = SymLabel THEN addr := s.value
      ELSIF s.kind = SymFunction THEN addr := s.value * PackingDivisor(ctx) + ctx.functionsOffset
      ELSIF s.kind = SymString THEN addr := s.value * PackingDivisor(ctx) + ctx.stringsOffset
      ELSE has := FALSE
      END;
      IF has THEN
        Out.String(s.name); Out.String(" $");
        Out.Int(addr, 0); Out.Ln
      END;
      s := s.hnext
    END
  END
END PrintLabelAddresses;

PROCEDURE RunAssembler*(ctx: Context): INTEGER;
VAR ok: BOOLEAN;
BEGIN
  IF ~ctx.quiet THEN Out.String("ZAPF (Oberon port)"); Out.Ln END;

  RestartContext(ctx);
  ok := Assemble(ctx);

  IF ctx.listAddresses THEN PrintLabelAddresses(ctx) END;

  IF ctx.errorCount > 0 THEN
    IF ~ctx.quiet THEN
      Out.Ln;
      Out.String("Failed ("); Out.Int(ctx.errorCount, 0); Out.String(" error");
      IF ctx.errorCount # 1 THEN Out.String("s") END;
      Out.String(")"); Out.Ln
    END;
    RETURN 2
  END;
  RETURN 0
END RunAssembler;

END ZapfAsm.
