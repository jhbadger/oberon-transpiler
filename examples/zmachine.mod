MODULE ZMachine;
(*
 * Z-machine interpreter for Infocom / Inform story files.
 * Supports versions 1-5 (focus on v3).
 *
 * Usage:  zmachine <story.z3>
 *
 * Controls: type commands as normal text, Enter to submit.
 *           Backspace to edit.  Ctrl-C / QUIT to exit.
 *)
IMPORT Terminal, Args, Strings, Files, Out;

(* Debug: set dbgN > 0 to log first N steps to /tmp/zmdbg.txt *)
CONST DBGMAX = 3000;

CONST
  MEMSIZE   = 524288;   (* 512 KB *)
  STACKSZ   = 2048;
  MAXFRAMES = 128;

  (* Keys *)
  KEY_BS    = 07FX;
  KEY_ENTER = 13;
  KEY_CTRLC =  3;
  KEY_CTRLD =  4;

TYPE
  Frame = RECORD
    retPC    : INTEGER;  (* PC to return to                *)
    stkBase  : INTEGER;  (* sp at call time                *)
    storeVar : INTEGER;  (* variable to store result; -1 = discard *)
    nlocals  : INTEGER;
    locals   : ARRAY 16 OF INTEGER;
    argCount : INTEGER;
  END;

VAR
  (* Z-machine memory *)
  mem  : ARRAY MEMSIZE OF BYTE;
  flen : INTEGER;

  (* Cached header fields *)
  zver     : INTEGER;
  himem    : INTEGER;
  iPC      : INTEGER;
  dictAddr : INTEGER;
  objAddr  : INTEGER;
  globBase : INTEGER;
  statBase : INTEGER;
  abbrev   : INTEGER;
  termSep  : ARRAY 8 OF INTEGER;  (* dictionary word separators *)
  nTermSep : INTEGER;
  dictEntSz: INTEGER;
  dictNEnt : INTEGER;

  (* Execution state *)
  pc      : INTEGER;
  running : BOOLEAN;

  (* Evaluation stack *)
  stk  : ARRAY STACKSZ OF INTEGER;
  sp   : INTEGER;  (* next free slot *)

  (* Call frames *)
  frames : ARRAY MAXFRAMES OF Frame;
  fp     : INTEGER;  (* -1 = top level *)

  (* Screen *)
  screenW   : INTEGER;
  screenH   : INTEGER;
  curCol    : INTEGER;   (* 1-based *)
  upperRows : INTEGER;
  curWin    : INTEGER;   (* 0=lower, 1=upper *)
  upperX    : INTEGER;
  upperY    : INTEGER;

  (* Output stream 3 stack (nested output_stream 3 support) *)
  strm3Stk  : ARRAY 16 OF INTEGER;  (* base addresses *)
  strm3Len  : ARRAY 16 OF INTEGER;  (* bytes written to each level *)
  strm3Top  : INTEGER;              (* # active levels; 0=inactive *)
  strm3     : INTEGER;              (* = strm3Stk[strm3Top-1] or 0 *)
  strm3len  : INTEGER;              (* = strm3Len[strm3Top-1] or 0 *)

  (* Word-wrap buffer for lower window *)
  wrapBuf : ARRAY 256 OF CHAR;
  wrapLen : INTEGER;

  (* Bit-shift table *)
  pw2 : ARRAY 17 OF INTEGER;  (* pw2[i] = 2^i *)

  (* Debug *)
  dbgF : Files.File;
  dbgR : Files.Rider;
  dbgN : INTEGER;

  (* Alphabet table (init in BEGIN) *)
  a2tab : ARRAY 25 OF CHAR;

(* ══════════════════════════════════════════════════════════════
   Debug helpers
   ══════════════════════════════════════════════════════════════ *)

PROCEDURE DbgStr(s: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  IF dbgF = NIL THEN RETURN END;
  i := 0;
  WHILE s[i] # 0X DO Files.Write(dbgR, ORD(s[i])); INC(i) END
END DbgStr;

PROCEDURE DbgInt(n: INTEGER);
VAR s: ARRAY 16 OF CHAR;
BEGIN Strings.IntToStr(n, s); DbgStr(s) END DbgInt;

PROCEDURE DbgHex(n: INTEGER);
VAR d, shift: INTEGER;
    c: CHAR;
BEGIN
  IF dbgF = NIL THEN RETURN END;
  Files.Write(dbgR, ORD('0')); Files.Write(dbgR, ORD('x'));
  n := n MOD 65536;  (* 4 hex digits *)
  shift := 12;
  WHILE shift >= 0 DO
    d := (n DIV pw2[shift]) MOD 16;
    IF d < 10 THEN c := CHR(ORD('0') + d)
    ELSE c := CHR(ORD('a') + d - 10) END;
    Files.Write(dbgR, ORD(c));
    DEC(shift, 4)
  END
END DbgHex;

PROCEDURE DbgNL;
BEGIN Files.Write(dbgR, ORD(0AX)) END DbgNL;

(* ══════════════════════════════════════════════════════════════
   Memory access
   ══════════════════════════════════════════════════════════════ *)

PROCEDURE RB(addr: INTEGER): INTEGER;
BEGIN
  IF (addr < 0) OR (addr >= MEMSIZE) THEN RETURN 0 END;
  RETURN mem[addr]
END RB;

PROCEDURE RW(addr: INTEGER): INTEGER;
BEGIN
  IF (addr < 0) OR (addr >= MEMSIZE - 1) THEN RETURN 0 END;
  RETURN mem[addr] * 256 + mem[addr+1]
END RW;

PROCEDURE WB(addr, val: INTEGER);
BEGIN
  IF (addr >= 0) & (addr < MEMSIZE) THEN mem[addr] := val MOD 256 END
END WB;

PROCEDURE WW(addr, val: INTEGER);
BEGIN
  IF (addr >= 0) & (addr < MEMSIZE - 1) THEN
    val := val MOD 65536;
    mem[addr] := val DIV 256;
    mem[addr+1] := val MOD 256
  END
END WW;

PROCEDURE S16(v: INTEGER): INTEGER;
(* sign-extend 16-bit to 32-bit *)
BEGIN
  v := v MOD 65536;
  IF v >= 32768 THEN RETURN v - 65536 ELSE RETURN v END
END S16;

PROCEDURE U16(v: INTEGER): INTEGER;
BEGIN RETURN v MOD 65536 END U16;

(* ══════════════════════════════════════════════════════════════
   Bitwise helpers (no native bitwise ops in Oberon)
   ══════════════════════════════════════════════════════════════ *)

PROCEDURE BitOR(a, b: INTEGER): INTEGER;
VAR i, r: INTEGER;
BEGIN
  a := a MOD 65536;  b := b MOD 65536;  r := 0;
  FOR i := 0 TO 15 DO
    IF ODD(a DIV pw2[i]) OR ODD(b DIV pw2[i]) THEN
      INC(r, pw2[i])
    END
  END;
  RETURN r
END BitOR;

PROCEDURE BitAND(a, b: INTEGER): INTEGER;
VAR i, r: INTEGER;
BEGIN
  a := a MOD 65536;  b := b MOD 65536;  r := 0;
  FOR i := 0 TO 15 DO
    IF ODD(a DIV pw2[i]) & ODD(b DIV pw2[i]) THEN
      INC(r, pw2[i])
    END
  END;
  RETURN r
END BitAND;

PROCEDURE BitNOT16(a: INTEGER): INTEGER;
BEGIN RETURN 65535 - a MOD 65536 END BitNOT16;

PROCEDURE BitSet(v, bit: INTEGER): INTEGER;
(* set bit 'bit' in v *)
VAR m: INTEGER;
BEGIN
  m := pw2[bit];
  RETURN (v DIV (m*2)) * (m*2) + m + v MOD m
END BitSet;

PROCEDURE BitClr(v, bit: INTEGER): INTEGER;
(* clear bit 'bit' in v *)
VAR m: INTEGER;
BEGIN
  m := pw2[bit];
  RETURN (v DIV (m*2)) * (m*2) + v MOD m
END BitClr;

PROCEDURE BitTst(v, bit: INTEGER): BOOLEAN;
BEGIN RETURN ODD(v DIV pw2[bit]) END BitTst;

(* ══════════════════════════════════════════════════════════════
   Stack
   ══════════════════════════════════════════════════════════════ *)

PROCEDURE Push(v: INTEGER);
BEGIN
  IF sp < STACKSZ THEN stk[sp] := v;  INC(sp) END
END Push;

PROCEDURE Pop(): INTEGER;
BEGIN
  IF sp > 0 THEN DEC(sp);  RETURN stk[sp] END;
  RETURN 0
END Pop;

(* ══════════════════════════════════════════════════════════════
   Variable access
   ══════════════════════════════════════════════════════════════ *)

PROCEDURE GetVar(v: INTEGER): INTEGER;
BEGIN
  IF v = 0 THEN RETURN Pop()
  ELSIF v <= 15 THEN
    IF fp >= 0 THEN RETURN frames[fp].locals[v] END;
    RETURN 0
  ELSE RETURN RW(globBase + (v - 16) * 2)
  END
END GetVar;

PROCEDURE SetVar(v, val: INTEGER);
BEGIN
  IF v = 0 THEN Push(val)
  ELSIF v <= 15 THEN
    IF fp >= 0 THEN frames[fp].locals[v] := val END
  ELSE WW(globBase + (v - 16) * 2, val)
  END
END SetVar;

(* Indirect variable access: var 0 peeks/pokes instead of pop/push *)
PROCEDURE IndGet(v: INTEGER): INTEGER;
BEGIN
  IF v = 0 THEN RETURN stk[sp-1]
  ELSIF v <= 15 THEN RETURN frames[fp].locals[v]
  ELSE RETURN RW(globBase + (v - 16) * 2)
  END
END IndGet;

PROCEDURE IndSet(v, val: INTEGER);
BEGIN
  IF v = 0 THEN stk[sp-1] := val
  ELSIF v <= 15 THEN frames[fp].locals[v] := val
  ELSE WW(globBase + (v - 16) * 2, val)
  END
END IndSet;

(* ══════════════════════════════════════════════════════════════
   Output
   ══════════════════════════════════════════════════════════════ *)

PROCEDURE FlushWord;
(* Output the buffered word, wrapping to next line first if needed *)
VAR i: INTEGER;
BEGIN
  IF wrapLen = 0 THEN RETURN END;
  IF curCol + wrapLen > screenW THEN
    Out.Char(0DX);  Out.Char(0AX);
    curCol := 1
  END;
  FOR i := 0 TO wrapLen - 1 DO
    Out.Char(wrapBuf[i]);
    INC(curCol)
  END;
  wrapLen := 0
END FlushWord;

PROCEDURE EmitChar(c: CHAR);
BEGIN
  IF (dbgF # NIL) & (dbgN < DBGMAX) THEN
    DbgStr("  EMIT "); DbgInt(ORD(c)); DbgNL
  END;
  (* Stream 3 (memory): capture output, suppress screen *)
  IF strm3 > 0 THEN
    WB(strm3 + 2 + strm3len, ORD(c));
    INC(strm3len);
    strm3Len[strm3Top - 1] := strm3len;
    RETURN
  END;
  IF curWin = 0 THEN
    IF c = 0AX THEN
      FlushWord;
      Out.Char(0DX);  Out.Char(0AX);
      curCol := 1
    ELSIF c = ' ' THEN
      FlushWord;
      IF curCol < screenW THEN
        Out.Char(' ');
        INC(curCol)
      END
      (* space at end of line is swallowed *)
    ELSE
      IF wrapLen < 255 THEN
        wrapBuf[wrapLen] := c;
        INC(wrapLen)
      ELSE
        (* word too long to buffer: flush then output directly *)
        FlushWord;
        Out.Char(c);
        INC(curCol)
      END
    END
  ELSE
    Out.Char(c);
    INC(upperX)
  END
END EmitChar;

PROCEDURE EmitNewline;
BEGIN
  IF curWin = 0 THEN
    FlushWord;
    Out.Char(0DX);  Out.Char(0AX);
    curCol := 1
  END
END EmitNewline;

PROCEDURE EmitStr(s: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN i := 0;  WHILE s[i] # 0X DO EmitChar(s[i]);  INC(i) END END EmitStr;

PROCEDURE EmitInt(n: INTEGER);
VAR s: ARRAY 16 OF CHAR;
BEGIN Strings.IntToStr(n, s);  EmitStr(s) END EmitInt;

(* ══════════════════════════════════════════════════════════════
   Z-string decoding  (outputs to screen)
   ══════════════════════════════════════════════════════════════ *)

(* Forward declaration needed because PrintZStr is recursive via abbrevs *)
PROCEDURE PrintZStr(addr: INTEGER);
VAR
  w, done    : INTEGER;
  zc0,zc1,zc2 : INTEGER;
  alpha      : INTEGER;   (* 0=A0 1=A1 2=A2 *)
  abbMode    : INTEGER;   (* 0=none 1..3=abbrev row *)
  tenPhase   : INTEGER;   (* 0=off 1=got-high 2=got-low *)
  tenHi      : INTEGER;
  ch         : CHAR;
  aAddr      : INTEGER;

  PROCEDURE ZChar(zc: INTEGER);
  VAR idx, aIdx: INTEGER;
  BEGIN
    (* abbreviation continuation *)
    IF abbMode > 0 THEN
      aIdx  := (abbMode - 1) * 32 + zc;
      aAddr := RW(abbrev + aIdx * 2) * 2;
      PrintZStr(aAddr);
      abbMode := 0;  alpha := 0;
      RETURN
    END;
    (* 10-bit literal continuation *)
    IF tenPhase = 1 THEN
      tenHi    := zc;
      tenPhase := 2;
      RETURN
    END;
    IF tenPhase = 2 THEN
      idx := tenHi * 32 + zc;
      IF idx = 13 THEN EmitNewline
      ELSIF idx >= 32 THEN EmitChar(CHR(idx))
      END;
      tenPhase := 0;  alpha := 0;
      RETURN
    END;
    (* normal z-char *)
    IF zc = 0 THEN
      EmitChar(' ');  alpha := 0
    ELSIF (zc >= 1) & (zc <= 3) THEN
      abbMode := zc;  alpha := 0
    ELSIF zc = 4 THEN
      alpha := 1
    ELSIF zc = 5 THEN
      alpha := 2
    ELSIF alpha = 0 THEN
      EmitChar(CHR(ORD('a') + zc - 6));
      (* alpha stays 0 *)
    ELSIF alpha = 1 THEN
      EmitChar(CHR(ORD('A') + zc - 6));
      alpha := 0
    ELSE (* alpha = 2 *)
      IF zc = 6 THEN
        tenPhase := 1
        (* keep alpha=2 until ten-phase resolves *)
      ELSIF zc = 7 THEN
        EmitNewline;  alpha := 0
      ELSE
        EmitChar(a2tab[zc - 8]);
        alpha := 0
      END
    END
  END ZChar;

BEGIN
  alpha := 0;  abbMode := 0;  tenPhase := 0;  done := 0;
  WHILE done = 0 DO
    w    := RW(addr);
    done := w DIV 32768;
    zc0  := (w DIV 1024) MOD 32;
    zc1  := (w DIV 32) MOD 32;
    zc2  := w MOD 32;
    ZChar(zc0);  ZChar(zc1);  ZChar(zc2);
    INC(addr, 2)
  END
END PrintZStr;

(* ZStr length in bytes (including the final word with bit15 set) *)
PROCEDURE ZStrLen(addr: INTEGER): INTEGER;
(* Not used externally but kept for reference *)
VAR n: INTEGER;
BEGIN
  n := 0;
  REPEAT INC(n, 2) UNTIL ODD(RW(addr + n - 2) DIV 32768);
  RETURN n
END ZStrLen;

(* skip past a z-string, return address just after it *)
PROCEDURE SkipZStr(addr: INTEGER): INTEGER;
BEGIN
  WHILE ~ODD(RW(addr) DIV 32768) DO INC(addr, 2) END;
  RETURN addr + 2
END SkipZStr;

(* ══════════════════════════════════════════════════════════════
   Object system  (v1-3: up to 255 objects, 32 attrs, 1-byte parent/sib/child)
   ══════════════════════════════════════════════════════════════ *)

PROCEDURE ObjBase(obj: INTEGER): INTEGER;
(* byte address of object record
   v1-3: 31 default props (62 bytes) + 9-byte records
   v4+:  63 default props (126 bytes) + 14-byte records *)
BEGIN
  IF zver <= 3 THEN RETURN objAddr + 62 + (obj - 1) * 9
  ELSE RETURN objAddr + 126 + (obj - 1) * 14
  END
END ObjBase;

PROCEDURE GetParent(obj: INTEGER): INTEGER;
BEGIN
  IF zver <= 3 THEN RETURN RB(ObjBase(obj) + 4)
  ELSE RETURN RW(ObjBase(obj) + 6) END
END GetParent;
PROCEDURE GetSibling(obj: INTEGER): INTEGER;
BEGIN
  IF zver <= 3 THEN RETURN RB(ObjBase(obj) + 5)
  ELSE RETURN RW(ObjBase(obj) + 8) END
END GetSibling;
PROCEDURE GetChild(obj: INTEGER): INTEGER;
BEGIN
  IF zver <= 3 THEN RETURN RB(ObjBase(obj) + 6)
  ELSE RETURN RW(ObjBase(obj) + 10) END
END GetChild;
PROCEDURE GetPropAddr(obj: INTEGER): INTEGER;
BEGIN
  IF zver <= 3 THEN RETURN RW(ObjBase(obj) + 7)
  ELSE RETURN RW(ObjBase(obj) + 12) END
END GetPropAddr;

PROCEDURE SetParent(obj, val: INTEGER);
BEGIN
  IF zver <= 3 THEN WB(ObjBase(obj) + 4, val)
  ELSE WW(ObjBase(obj) + 6, val) END
END SetParent;
PROCEDURE SetSibling(obj, val: INTEGER);
BEGIN
  IF zver <= 3 THEN WB(ObjBase(obj) + 5, val)
  ELSE WW(ObjBase(obj) + 8, val) END
END SetSibling;
PROCEDURE SetChild(obj, val: INTEGER);
BEGIN
  IF zver <= 3 THEN WB(ObjBase(obj) + 6, val)
  ELSE WW(ObjBase(obj) + 10, val) END
END SetChild;

PROCEDURE TestAttr(obj, attr: INTEGER): BOOLEAN;
BEGIN
  RETURN BitTst(RB(ObjBase(obj) + attr DIV 8), 7 - attr MOD 8)
END TestAttr;

PROCEDURE SetAttr(obj, attr: INTEGER);
VAR a: INTEGER;
BEGIN
  a := ObjBase(obj) + attr DIV 8;
  WB(a, BitSet(RB(a), 7 - attr MOD 8))
END SetAttr;

PROCEDURE ClearAttr(obj, attr: INTEGER);
VAR a: INTEGER;
BEGIN
  a := ObjBase(obj) + attr DIV 8;
  WB(a, BitClr(RB(a), 7 - attr MOD 8))
END ClearAttr;

PROCEDURE PrintObjName(obj: INTEGER);
(* Print the short description of an object *)
VAR pa: INTEGER;
BEGIN
  pa := GetPropAddr(obj);
  IF RB(pa) > 0 THEN
    PrintZStr(pa + 1)   (* first byte = word count of short name *)
  END
END PrintObjName;

(* Remove obj from its parent's child list *)
PROCEDURE RemoveObj(obj: INTEGER);
VAR par, sib, prev: INTEGER;
BEGIN
  par := GetParent(obj);
  IF par = 0 THEN RETURN END;
  IF GetChild(par) = obj THEN
    SetChild(par, GetSibling(obj))
  ELSE
    prev := GetChild(par);
    WHILE (prev # 0) & (GetSibling(prev) # obj) DO
      prev := GetSibling(prev)
    END;
    IF prev # 0 THEN SetSibling(prev, GetSibling(obj)) END
  END;
  SetParent(obj, 0);
  SetSibling(obj, 0)
END RemoveObj;

(* Insert obj as first child of dest *)
PROCEDURE InsertObj(obj, dest: INTEGER);
BEGIN
  RemoveObj(obj);
  SetSibling(obj, GetChild(dest));
  SetChild(dest, obj);
  SetParent(obj, dest)
END InsertObj;

(* v4+ property helpers.
   Size byte format:
     bit7=0: bit6=0 → 1 byte data, bit6=1 → 2 bytes; bits 5-0 = prop num
     bit7=1: bits 5-0 of first byte = prop num; second byte bits 5-0 = length (0→64) *)
PROCEDURE Prop4Num(pa: INTEGER): INTEGER;
BEGIN RETURN RB(pa) MOD 64 END Prop4Num;

(* Returns data length; sets dataOff to number of size bytes (1 or 2) *)
PROCEDURE Prop4Len(pa: INTEGER; VAR dataOff: INTEGER): INTEGER;
VAR sb, len: INTEGER;
BEGIN
  sb := RB(pa);
  IF ODD(sb DIV 128) THEN
    dataOff := 2;
    len := RB(pa + 1) MOD 64;
    IF len = 0 THEN len := 64 END
  ELSE
    dataOff := 1;
    IF ODD(sb DIV 64) THEN len := 2 ELSE len := 1 END
  END;
  RETURN len
END Prop4Len;

(* Return property data address for obj's property prop, or 0 if not found *)
PROCEDURE GetProp(obj, prop: INTEGER): INTEGER;
VAR pa, pnum, plen, dataOff: INTEGER;
BEGIN
  pa := GetPropAddr(obj);
  INC(pa, RB(pa) * 2 + 1);  (* skip count byte + short-name z-bytes *)
  IF zver <= 3 THEN
    LOOP
      IF RB(pa) = 0 THEN RETURN 0 END;
      pnum := RB(pa) MOD 32;
      plen := RB(pa) DIV 32 + 1;
      IF pnum = prop THEN RETURN pa + 1 END;
      INC(pa, plen + 1)
    END
  ELSE
    LOOP
      IF RB(pa) = 0 THEN RETURN 0 END;
      pnum := Prop4Num(pa);
      plen := Prop4Len(pa, dataOff);
      IF pnum = prop THEN RETURN pa + dataOff END;
      INC(pa, plen + dataOff)
    END
  END
END GetProp;

PROCEDURE GetPropLen(dataAddr: INTEGER): INTEGER;
(* dataAddr points to the data bytes; size byte(s) are before it *)
VAR sb: INTEGER;
BEGIN
  IF zver <= 3 THEN
    RETURN RB(dataAddr - 1) DIV 32 + 1
  ELSE
    sb := RB(dataAddr - 1);
    IF ODD(sb DIV 128) THEN  (* this is the second size byte *)
      sb := sb MOD 64;
      IF sb = 0 THEN RETURN 64 ELSE RETURN sb END
    ELSE
      IF ODD(sb DIV 64) THEN RETURN 2 ELSE RETURN 1 END
    END
  END
END GetPropLen;

PROCEDURE GetNextProp(obj, prop: INTEGER): INTEGER;
(* Return property number after prop (or first prop if prop=0) *)
VAR pa, pnum, plen, dataOff: INTEGER;
BEGIN
  pa := GetPropAddr(obj);
  INC(pa, RB(pa) * 2 + 1);  (* skip count byte + short-name z-bytes *)
  IF zver <= 3 THEN
    IF prop = 0 THEN
      IF RB(pa) = 0 THEN RETURN 0 END;
      RETURN RB(pa) MOD 32
    END;
    LOOP
      IF RB(pa) = 0 THEN RETURN 0 END;
      pnum := RB(pa) MOD 32;
      plen := RB(pa) DIV 32 + 1;
      IF pnum = prop THEN
        INC(pa, plen + 1);
        IF RB(pa) = 0 THEN RETURN 0 END;
        RETURN RB(pa) MOD 32
      END;
      INC(pa, plen + 1)
    END
  ELSE
    IF prop = 0 THEN
      IF RB(pa) = 0 THEN RETURN 0 END;
      RETURN Prop4Num(pa)
    END;
    LOOP
      IF RB(pa) = 0 THEN RETURN 0 END;
      pnum := Prop4Num(pa);
      plen := Prop4Len(pa, dataOff);
      IF pnum = prop THEN
        INC(pa, plen + dataOff);
        IF RB(pa) = 0 THEN RETURN 0 END;
        RETURN Prop4Num(pa)
      END;
      INC(pa, plen + dataOff)
    END
  END
END GetNextProp;

(* Default property value *)
PROCEDURE DefaultProp(prop: INTEGER): INTEGER;
BEGIN RETURN RW(objAddr + (prop - 1) * 2) END DefaultProp;

(* Read property: returns word or byte depending on size *)
PROCEDURE ReadProp(obj, prop: INTEGER): INTEGER;
VAR pa, plen: INTEGER;
BEGIN
  pa := GetProp(obj, prop);
  IF pa = 0 THEN RETURN DefaultProp(prop) END;
  plen := GetPropLen(pa);
  IF plen = 1 THEN RETURN RB(pa)
  ELSE RETURN RW(pa)
  END
END ReadProp;

PROCEDURE WriteProp(obj, prop, val: INTEGER);
VAR pa, plen: INTEGER;
BEGIN
  pa := GetProp(obj, prop);
  IF pa = 0 THEN RETURN END;
  plen := GetPropLen(pa);
  IF plen = 1 THEN WB(pa, val)
  ELSE WW(pa, val)
  END
END WriteProp;

(* ══════════════════════════════════════════════════════════════
   Dictionary & tokenisation
   ══════════════════════════════════════════════════════════════ *)

(* Encode word into Z-words for dictionary lookup.
   v1-3: 2 words (6 z-chars, terminal bit on w1)
   v4+:  3 words (9 z-chars, terminal bit on w2) *)
PROCEDURE EncodeWord(s: ARRAY OF CHAR; len: INTEGER;
                     VAR w0, w1, w2: INTEGER);
VAR zch : ARRAY 9 OF INTEGER;
    maxZ, i, c : INTEGER;
    ch   : CHAR;
BEGIN
  IF zver <= 3 THEN maxZ := 6 ELSE maxZ := 9 END;
  FOR i := 0 TO maxZ - 1 DO zch[i] := 5 END;
  i := 0;
  WHILE (i < len) & (i < maxZ) DO
    ch := s[i];
    IF (ch >= 'a') & (ch <= 'z') THEN
      zch[i] := ORD(ch) - ORD('a') + 6
    ELSIF (ch >= 'A') & (ch <= 'Z') THEN
      zch[i] := ORD(ch) - ORD('A') + 6
    ELSE
      (* check a2 table *)
      c := 0;
      WHILE (c < 24) & (a2tab[c] # ch) DO INC(c) END;
      IF (c < 24) & (i < maxZ - 1) THEN
        zch[i] := 5; INC(i); zch[i] := 8 + c
      ELSE
        zch[i] := 5
      END
    END;
    INC(i)
  END;
  w0 := zch[0] * 1024 + zch[1] * 32 + zch[2];
  w1 := zch[3] * 1024 + zch[4] * 32 + zch[5];
  IF zver <= 3 THEN
    INC(w1, 32768);  (* terminal bit on w1 *)
    w2 := 0
  ELSE
    w2 := zch[6] * 1024 + zch[7] * 32 + zch[8];
    INC(w2, 32768)   (* terminal bit on w2 *)
  END
END EncodeWord;

(* Binary search dictionary for encoded word; return entry addr or 0 *)
PROCEDURE DictLookup(w0, w1, w2: INTEGER): INTEGER;
VAR lo, hi, mid, ea, d0, d1, d2: INTEGER;
BEGIN
  lo := 0;  hi := dictNEnt - 1;
  WHILE lo <= hi DO
    mid := (lo + hi) DIV 2;
    ea  := dictAddr + nTermSep + 1 + 3 + mid * dictEntSz;
    d0  := RW(ea);
    d1  := RW(ea + 2);
    IF zver <= 3 THEN
      IF (d0 = w0) & (d1 = w1) THEN RETURN ea
      ELSIF (d0 < w0) OR ((d0 = w0) & (d1 < w1)) THEN lo := mid + 1
      ELSE hi := mid - 1
      END
    ELSE
      d2 := RW(ea + 4);
      IF (d0 = w0) & (d1 = w1) & (d2 = w2) THEN RETURN ea
      ELSIF (d0 < w0) OR ((d0 = w0) & (d1 < w1)) OR
            ((d0 = w0) & (d1 = w1) & (d2 < w2)) THEN lo := mid + 1
      ELSE hi := mid - 1
      END
    END
  END;
  RETURN 0
END DictLookup;

(* Tokenise text buffer into parse buffer *)
PROCEDURE Tokenise(textBuf, parseBuf: INTEGER);
VAR
  maxText, maxWords, nWords : INTEGER;
  i, start, wlen            : INTEGER;
  ch                        : CHAR;
  isSep                     : BOOLEAN;
  word                      : ARRAY 10 OF CHAR;
  w0, w1, w2, dictEnt       : INTEGER;
  j                         : INTEGER;

  PROCEDURE IsSeparator(c: CHAR): BOOLEAN;
  VAR k: INTEGER;
  BEGIN
    FOR k := 0 TO nTermSep - 1 DO
      IF ORD(c) = termSep[k] THEN RETURN TRUE END
    END;
    RETURN FALSE
  END IsSeparator;

BEGIN
  maxText  := RB(textBuf);
  maxWords := RB(parseBuf);
  nWords   := 0;
  (* v5+: byte 1 = char count, text starts at offset 2; v1-4: text at offset 1 *)
  IF zver >= 5 THEN i := 2 ELSE i := 1 END;
  WB(parseBuf + 1, 0);
  WHILE (RB(textBuf + i) # 0) & (nWords < maxWords) DO
    ch := CHR(RB(textBuf + i));
    IF ch = ' ' THEN
      INC(i)
    ELSIF IsSeparator(ch) THEN
      (* separator is its own token *)
      word[0] := ch;  word[1] := 0X;
      EncodeWord(word, 1, w0, w1, w2);
      dictEnt := DictLookup(w0, w1, w2);
      j := parseBuf + 2 + nWords * 4;
      WW(j, dictEnt);
      WB(j + 2, 1);
      WB(j + 3, i);
      INC(nWords);
      INC(i)
    ELSE
      start := i;
      wlen  := 0;
      WHILE (RB(textBuf + i) # 0) & (CHR(RB(textBuf + i)) # ' ')
            & ~IsSeparator(CHR(RB(textBuf + i))) & (wlen < 9) DO
        word[wlen] := CHR(RB(textBuf + i));
        INC(wlen);  INC(i)
      END;
      word[wlen] := 0X;
      EncodeWord(word, wlen, w0, w1, w2);
      dictEnt := DictLookup(w0, w1, w2);
      j := parseBuf + 2 + nWords * 4;
      WW(j, dictEnt);
      WB(j + 2, wlen);
      WB(j + 3, start);
      INC(nWords)
    END
  END;
  WB(parseBuf + 1, nWords)
END Tokenise;

(* ══════════════════════════════════════════════════════════════
   Status line (v3)
   ══════════════════════════════════════════════════════════════ *)

PROCEDURE Esc(s: ARRAY OF CHAR);
(* Emit ESC + s *)
BEGIN  Out.Char(1BX);  Out.String(s)  END Esc;

PROCEDURE EscN2(a, b: INTEGER; term: CHAR);
(* Emit ESC [ a ; b term *)
VAR sa, sb: ARRAY 8 OF CHAR;
BEGIN
  Out.Char(1BX);  Out.Char('[');
  Strings.IntToStr(a, sa);  Out.String(sa);
  Out.Char(';');
  Strings.IntToStr(b, sb);  Out.String(sb);
  Out.Char(term)
END EscN2;

PROCEDURE SetScrollRegion(top, bot: INTEGER);
(* Set terminal scroll region to rows top..bot *)
BEGIN  EscN2(top, bot, 'r')  END SetScrollRegion;

PROCEDURE ShowStatus;
(* Draw v3 status line at row 1 and restore cursor position *)
VAR
  locObj, score, turns : INTEGER;
  numStr  : ARRAY 16 OF CHAR;
  i, col  : INTEGER;
  savedWin : INTEGER;
BEGIN
  IF zver > 3 THEN RETURN END;
  locObj := RW(globBase);
  score  := S16(RW(globBase + 2));
  turns  := RW(globBase + 4);

  savedWin := curWin;
  curWin   := 1;            (* upper window: EmitChar just outputs *)

  Esc("[s");                (* save cursor position *)
  Terminal.Goto(1, 1);
  Esc("[7m");               (* reverse video *)
  (* Blank full line *)
  FOR i := 1 TO screenW DO Out.Char(' ') END;
  (* Room name *)
  Terminal.Goto(2, 1);
  PrintObjName(locObj);
  (* Score + turns on right *)
  Strings.IntToStr(score, numStr);
  col := screenW - 18;
  IF col < 2 THEN col := 2 END;
  Terminal.Goto(col, 1);
  Out.String("Score:");  Out.String(numStr);
  Out.String("  Moves:");
  Strings.IntToStr(turns, numStr);
  Out.String(numStr);
  Esc("[0m");               (* reset video *)
  Esc("[u");                (* restore cursor position *)

  curWin := savedWin
END ShowStatus;

(* ══════════════════════════════════════════════════════════════
   Line input (SREAD / AREAD)
   ══════════════════════════════════════════════════════════════ *)

PROCEDURE ReadLine(textBuf: INTEGER);
(* Read a line of text into Z-machine text buffer.
   textBuf[0] = max chars, textBuf[1..] = text, null-terminated.
   (In v5+ textBuf[1] = initial text length; we ignore that.) *)
VAR
  maxLen, n : INTEGER;
  c         : CHAR;
  k         : INTEGER;
BEGIN
  maxLen := RB(textBuf) - 1;
  n      := 0;
  IF zver >= 5 THEN
    (* v5: textBuf[1] = pre-loaded chars count; we clear it for now *)
    WB(textBuf + 1, 0)
  END;

  Terminal.ShowCursor;
  LOOP
    c := Terminal.ReadKey();
    k := ORD(c);
    IF (k = KEY_ENTER) OR (k = 0AX) THEN
      EXIT
    ELSIF k = KEY_BS THEN
      IF n > 0 THEN
        DEC(n);
        Out.Char(8X);  Out.Char(' ');  Out.Char(8X)
      END
    ELSIF (k = KEY_CTRLC) OR (k = KEY_CTRLD) THEN
      running := FALSE;
      EXIT
    ELSIF (k >= 32) & (k < 127) & (n < maxLen) THEN
      IF (k >= ORD('A')) & (k <= ORD('Z')) THEN k := k + 32 END;  (* lowercase *)
      Out.Char(CHR(k));
      IF zver >= 5 THEN
        WB(textBuf + 2 + n, k)
      ELSE
        WB(textBuf + 1 + n, k)
      END;
      INC(n)
    END
  END;
  Terminal.HideCursor;
  IF zver >= 5 THEN
    WB(textBuf + 1, n);
    WB(textBuf + 2 + n, 0)
  ELSE
    WB(textBuf + 1 + n, 0)
  END;
  EmitNewline
END ReadLine;

(* ══════════════════════════════════════════════════════════════
   Call / Return
   ══════════════════════════════════════════════════════════════ *)

PROCEDURE PackedAddr(p: INTEGER): INTEGER;
(* Convert packed routine address to byte address *)
BEGIN
  IF zver <= 3 THEN RETURN p * 2
  ELSIF zver <= 5 THEN RETURN p * 4
  ELSIF zver <= 7 THEN RETURN p * 4  (* v6/7: add offset; simplified *)
  ELSE RETURN p * 8
  END
END PackedAddr;

PROCEDURE PackedStr(p: INTEGER): INTEGER;
(* Packed string address (v6: different from routine) *)
BEGIN
  IF zver <= 3 THEN RETURN p * 2
  ELSIF zver <= 5 THEN RETURN p * 4
  ELSE RETURN p * 8
  END
END PackedStr;

PROCEDURE DoCall(routineAddr, nArgs: INTEGER;
                 args: ARRAY OF INTEGER;
                 storeVar: INTEGER);
(* Push a new call frame and jump to routineAddr.
   If routineAddr = 0, store 0 and return immediately. *)
VAR i, nLocals, initPC2: INTEGER;
BEGIN
  IF routineAddr = 0 THEN
    IF storeVar >= 0 THEN SetVar(storeVar, 0) END;
    RETURN
  END;
  IF fp >= MAXFRAMES - 1 THEN  (* frame overflow guard *)
    running := FALSE;  RETURN
  END;
  INC(fp);
  frames[fp].retPC    := pc;
  frames[fp].stkBase  := sp;
  frames[fp].storeVar := storeVar;
  frames[fp].argCount := nArgs;

  nLocals := RB(routineAddr);
  IF nLocals > 15 THEN nLocals := 15 END;  (* guard against garbage routine header *)
  frames[fp].nlocals := nLocals;

  (* Initialise locals: v1-4 have initial values in the routine header *)
  FOR i := 1 TO nLocals DO
    IF zver <= 4 THEN
      frames[fp].locals[i] := RW(routineAddr + 1 + (i-1)*2)
    ELSE
      frames[fp].locals[i] := 0
    END
  END;
  (* Override with supplied arguments *)
  FOR i := 1 TO nArgs DO
    IF i <= nLocals THEN frames[fp].locals[i] := args[i-1] END
  END;

  IF zver <= 4 THEN
    pc := routineAddr + 1 + nLocals * 2
  ELSE
    pc := routineAddr + 1
  END
END DoCall;

PROCEDURE DoReturn(val: INTEGER);
VAR storeVar, base: INTEGER;
BEGIN
  storeVar := frames[fp].storeVar;
  base     := frames[fp].stkBase;
  pc       := frames[fp].retPC;
  (* Discard this frame's stack entries *)
  sp := base;
  DEC(fp);
  IF storeVar >= 0 THEN SetVar(storeVar, val) END
END DoReturn;

(* ══════════════════════════════════════════════════════════════
   Branch helper
   ══════════════════════════════════════════════════════════════ *)

PROCEDURE DoBranch(cond: BOOLEAN);
(* Read branch data at pc, take branch if condition matches sense *)
VAR b1, b2, sense, offset: INTEGER;
BEGIN
  b1 := RB(pc);  INC(pc);
  sense := b1 DIV 128;           (* 1=branch if true, 0=branch if false *)
  IF ODD(b1 DIV 64) THEN         (* single-byte offset *)
    offset := b1 MOD 64
  ELSE
    b2     := RB(pc);  INC(pc);
    offset := (b1 MOD 64) * 256 + b2;
    IF offset >= 8192 THEN DEC(offset, 16384) END  (* sign extend 14-bit *)
  END;
  IF (cond & (sense = 1)) OR (~cond & (sense = 0)) THEN
    IF offset = 0 THEN DoReturn(0)
    ELSIF offset = 1 THEN DoReturn(1)
    ELSE INC(pc, offset - 2)
    END
  END
END DoBranch;

(* ══════════════════════════════════════════════════════════════
   Save / Restore  (simple: dump/load dynamic memory)
   ══════════════════════════════════════════════════════════════ *)

PROCEDURE PromptFilename(prompt: ARRAY OF CHAR; VAR name: ARRAY OF CHAR);
VAR n, k: INTEGER;  c: CHAR;
BEGIN
  FlushWord;
  EmitNewline;
  EmitStr(prompt);
  n := 0;
  Terminal.ShowCursor;
  LOOP
    c := Terminal.ReadKey();
    k := ORD(c);
    IF (k = KEY_ENTER) OR (k = 0AX) THEN
      EXIT
    ELSIF (k = KEY_BS) OR (k = 127) THEN
      IF n > 0 THEN
        DEC(n);
        Out.Char(8X);  Out.Char(' ');  Out.Char(8X)
      END
    ELSIF (k >= 32) & (k < 127) & (n < LEN(name) - 1) THEN
      Out.Char(c);
      name[n] := c;
      INC(n)
    END
  END;
  Terminal.HideCursor;
  name[n] := 0X;
  EmitNewline;
  IF n = 0 THEN COPY("zm.sav", name) END
END PromptFilename;

PROCEDURE DoSave(): BOOLEAN;
VAR f: Files.File;
    r: Files.Rider;
    i: INTEGER;
    name: ARRAY 64 OF CHAR;
BEGIN
  PromptFilename("Save to file: ", name);
  f := Files.New(name);
  IF f = NIL THEN RETURN FALSE END;
  Files.Set(r, f, 0);
  FOR i := 0 TO statBase - 1 DO
    Files.Write(r, mem[i])
  END;
  Files.Register(f);
  Files.Close(f);
  RETURN TRUE
END DoSave;

PROCEDURE DoRestore(): BOOLEAN;
VAR f: Files.File;
    r: Files.Rider;
    i: INTEGER;
    b: BYTE;
    name: ARRAY 64 OF CHAR;
BEGIN
  PromptFilename("Restore from file: ", name);
  f := Files.Old(name);
  IF f = NIL THEN RETURN FALSE END;
  Files.Set(r, f, 0);
  FOR i := 0 TO statBase - 1 DO
    Files.Read(r, b);
    IF r.eof THEN Files.Close(f);  RETURN FALSE END;
    mem[i] := b
  END;
  Files.Close(f);
  RETURN TRUE
END DoRestore;

(* ══════════════════════════════════════════════════════════════
   Instruction decode and execute
   ══════════════════════════════════════════════════════════════ *)

PROCEDURE Step;
VAR
  opbyte           : INTEGER;
  form             : INTEGER;  (* 0=long 1=short 2=var 3=ext *)
  opcode           : INTEGER;
  ops              : ARRAY 8 OF INTEGER;
  nops             : INTEGER;
  typeByte         : INTEGER;
  i, t             : INTEGER;
  storeVar         : INTEGER;
  val, a, b        : INTEGER;
  args             : ARRAY 8 OF INTEGER;
  nArgs            : INTEGER;

  PROCEDURE ReadOps1(tb: INTEGER);
  VAR j, tp: INTEGER;
  BEGIN
    nops := 0;
    FOR j := 0 TO 3 DO
      tp := (tb DIV pw2[6 - j*2]) MOD 4;
      IF tp = 3 THEN RETURN END;
      IF tp = 0 THEN ops[nops] := RW(pc); INC(pc, 2)
      ELSIF tp = 1 THEN ops[nops] := RB(pc); INC(pc)
      ELSE ops[nops] := GetVar(RB(pc)); INC(pc)
      END;
      INC(nops)
    END
  END ReadOps1;

VAR dbgPC : INTEGER;
BEGIN
  IF (dbgF # NIL) & (dbgN < DBGMAX) THEN
    INC(dbgN);
    DbgHex(pc); DbgStr(" ob="); DbgHex(RB(pc)); DbgNL
  END;
  dbgPC := pc;
  opbyte := RB(pc);  INC(pc);

  (* Decode form *)
  IF opbyte = 0BEH THEN              (* extended opcode (v5+) *)
    form   := 3;
    opcode := RB(pc);  INC(pc);
    typeByte := RB(pc);  INC(pc);
    ReadOps1(typeByte)
  ELSIF opbyte >= 0C0H THEN          (* 11xxxxxx = variable form *)
    form   := 2;
    opcode := opbyte MOD 32;
    typeByte := RB(pc);  INC(pc);
    IF (opcode = 12) OR (opcode = 26) THEN  (* call_vs2 / call_vn2: two type bytes *)
      ReadOps1(typeByte);
      typeByte := RB(pc);  INC(pc);
      (* read 4 more operands and append *)
      FOR i := 0 TO 3 DO
        t := (typeByte DIV pw2[6 - i*2]) MOD 4;
        IF t = 3 THEN i := 4
        ELSE
          IF t = 0 THEN ops[nops] := RW(pc); INC(pc, 2)
          ELSIF t = 1 THEN ops[nops] := RB(pc); INC(pc)
          ELSE ops[nops] := GetVar(RB(pc)); INC(pc)
          END;
          INC(nops)
        END
      END
    ELSE
      ReadOps1(typeByte)
    END;
    IF opbyte < 0E0H THEN form := 22 END  (* 110x = 2OP in var encoding *)
  ELSIF opbyte >= 080H THEN          (* 10xxxxxx = short form *)
    form := 1;
    t    := (opbyte DIV 16) MOD 4;
    opcode := opbyte MOD 16;
    IF t = 3 THEN nops := 0          (* 0OP *)
    ELSE
      nops := 1;
      IF t = 0 THEN ops[0] := RW(pc); INC(pc, 2)
      ELSIF t = 1 THEN ops[0] := RB(pc); INC(pc)
      ELSE ops[0] := GetVar(RB(pc)); INC(pc)
      END
    END
  ELSE                               (* 0xxxxxxx = long form (2OP) *)
    form   := 0;
    opcode := opbyte MOD 32;
    nops   := 2;
    IF BitTst(opbyte, 6) THEN ops[0] := GetVar(RB(pc)) ELSE ops[0] := RB(pc) END;
    INC(pc);
    IF BitTst(opbyte, 5) THEN ops[1] := GetVar(RB(pc)) ELSE ops[1] := RB(pc) END;
    INC(pc)
  END;

  (* ── 0OP ─────────────────────────────────────────────────── *)
  IF (form = 1) & (nops = 0) THEN
    CASE opcode OF
      0 : DoReturn(1)           (* rtrue *)
    | 1 : DoReturn(0)           (* rfalse *)
    | 2 :                       (* print *)
        PrintZStr(pc);
        pc := SkipZStr(pc)
    | 3 :                       (* print_ret *)
        PrintZStr(pc);
        pc := SkipZStr(pc);
        EmitNewline;
        DoReturn(1)
    | 4 : (* nop *)
    | 5 :                       (* save *)
        IF zver <= 3 THEN
          DoBranch(DoSave())
        ELSE
          storeVar := RB(pc);  INC(pc);
          IF DoSave() THEN SetVar(storeVar, 1)
          ELSE SetVar(storeVar, 0)
          END
        END
    | 6 :                       (* restore *)
        IF zver <= 3 THEN
          IF DoRestore() THEN DoBranch(TRUE)
          ELSE DoBranch(FALSE)
          END
        ELSE
          storeVar := RB(pc);  INC(pc);
          IF DoRestore() THEN SetVar(storeVar, 2)
          ELSE SetVar(storeVar, 0)
          END
        END
    | 7 :                       (* restart *)
        (* reload initial pc; simplest restart = re-init execution *)
        pc := iPC;
        fp := -1;  sp := 0
    | 8 : DoReturn(Pop())       (* ret_popped *)
    | 9 :                       (* pop / catch *)
        IF zver <= 4 THEN val := Pop()
        ELSE
          storeVar := RB(pc);  INC(pc);
          SetVar(storeVar, fp + 1)  (* catch: return call-frame depth *)
        END
    | 10 : running := FALSE      (* quit *)
    | 11 : EmitNewline           (* new_line *)
    | 12 : ShowStatus            (* show_status (v3) *)
    | 13 : DoBranch(TRUE)        (* verify: assume OK *)
    | 15 : DoBranch(TRUE)        (* piracy: assume genuine *)
    ELSE
    END

  (* ── 1OP ─────────────────────────────────────────────────── *)
  ELSIF (form = 1) & (nops = 1) THEN
    CASE opcode OF
      0 : DoBranch(ops[0] = 0)                    (* jz *)
    | 1 :                                          (* get_sibling *)
        storeVar := RB(pc);  INC(pc);
        val := GetSibling(ops[0]);
        SetVar(storeVar, val);
        DoBranch(val # 0)
    | 2 :                                          (* get_child *)
        storeVar := RB(pc);  INC(pc);
        val := GetChild(ops[0]);
        SetVar(storeVar, val);
        DoBranch(val # 0)
    | 3 :                                          (* get_parent *)
        storeVar := RB(pc);  INC(pc);
        SetVar(storeVar, GetParent(ops[0]))
    | 4 :                                          (* get_prop_len *)
        storeVar := RB(pc);  INC(pc);
        IF ops[0] = 0 THEN SetVar(storeVar, 0)
        ELSE SetVar(storeVar, GetPropLen(ops[0]))
        END
    | 5 :                                          (* inc *)
        val := S16(IndGet(ops[0])) + 1;
        IndSet(ops[0], U16(val))
    | 6 :                                          (* dec *)
        val := S16(IndGet(ops[0])) - 1;
        IndSet(ops[0], U16(val))
    | 7 :                                          (* print_addr *)
        PrintZStr(ops[0])
    | 8 :                                          (* call_1s (v4+) *)
        storeVar := RB(pc);  INC(pc);
        DoCall(PackedAddr(ops[0]), 0, args, storeVar)
    | 9 : RemoveObj(ops[0])                        (* remove_obj *)
    | 10 : PrintObjName(ops[0])                    (* print_obj *)
    | 11 : DoReturn(ops[0])                        (* ret *)
    | 12 :                                         (* jump *)
        val := S16(ops[0]) - 2;
        INC(pc, val)
    | 13 : PrintZStr(PackedStr(ops[0]))             (* print_paddr (packed) *)
    | 14 :                                         (* load *)
        storeVar := RB(pc);  INC(pc);
        SetVar(storeVar, IndGet(ops[0]))
    | 15 :                                         (* not (v1-4) / call_1n (v5+) *)
        IF zver <= 4 THEN
          storeVar := RB(pc);  INC(pc);
          SetVar(storeVar, BitNOT16(ops[0]))
        ELSE
          DoCall(PackedAddr(ops[0]), 0, args, -1)
        END
    ELSE
    END

  (* ── 2OP ─────────────────────────────────────────────────── *)
  ELSIF (form = 0) OR (form = 22) THEN
    a := ops[0];  b := ops[1];
    CASE opcode OF
      1 :                                          (* je *)
        val := 0;
        FOR i := 1 TO nops - 1 DO
          IF ops[0] = ops[i] THEN val := 1 END
        END;
        DoBranch(val = 1)
    | 2 : DoBranch(S16(a) < S16(b))               (* jl *)
    | 3 : DoBranch(S16(a) > S16(b))               (* jg *)
    | 4 :                                          (* dec_chk *)
        val := U16(S16(IndGet(a)) - 1);
        IndSet(a, val);
        DoBranch(S16(val) < S16(b))
    | 5 :                                          (* inc_chk *)
        val := U16(S16(IndGet(a)) + 1);
        IndSet(a, val);
        DoBranch(S16(val) > S16(b))
    | 6 : DoBranch(GetParent(a) = b)              (* jin *)
    | 7 : DoBranch(BitAND(a, b) = b)              (* test *)
    | 8 :                                          (* or *)
        storeVar := RB(pc);  INC(pc);
        SetVar(storeVar, BitOR(a, b))
    | 9 :                                          (* and *)
        storeVar := RB(pc);  INC(pc);
        SetVar(storeVar, BitAND(a, b))
    | 10 : DoBranch(TestAttr(a, b))               (* test_attr *)
    | 11 : SetAttr(a, b)                           (* set_attr *)
    | 12 : ClearAttr(a, b)                         (* clear_attr *)
    | 13 : SetVar(a, b)                            (* store (indirect) *)
    | 14 : InsertObj(a, b)                         (* insert_obj *)
    | 15 :                                         (* loadw *)
        storeVar := RB(pc);  INC(pc);
        SetVar(storeVar, RW(a + b * 2))
    | 16 :                                         (* loadb *)
        storeVar := RB(pc);  INC(pc);
        SetVar(storeVar, RB(a + b))
    | 17 :                                         (* get_prop *)
        storeVar := RB(pc);  INC(pc);
        SetVar(storeVar, ReadProp(a, b))
    | 18 :                                         (* get_prop_addr *)
        storeVar := RB(pc);  INC(pc);
        SetVar(storeVar, GetProp(a, b))
    | 19 :                                         (* get_next_prop *)
        storeVar := RB(pc);  INC(pc);
        SetVar(storeVar, GetNextProp(a, b))
    | 20 :                                         (* add *)
        storeVar := RB(pc);  INC(pc);
        SetVar(storeVar, U16(S16(a) + S16(b)))
    | 21 :                                         (* sub *)
        storeVar := RB(pc);  INC(pc);
        SetVar(storeVar, U16(S16(a) - S16(b)))
    | 22 :                                         (* mul *)
        storeVar := RB(pc);  INC(pc);
        SetVar(storeVar, U16(S16(a) * S16(b)))
    | 23 :                                         (* div *)
        storeVar := RB(pc);  INC(pc);
        IF b = 0 THEN SetVar(storeVar, 0)
        ELSE SetVar(storeVar, U16(S16(a) DIV S16(b)))
        END
    | 24 :                                         (* mod *)
        storeVar := RB(pc);  INC(pc);
        IF b = 0 THEN SetVar(storeVar, 0)
        ELSE SetVar(storeVar, U16(S16(a) MOD S16(b)))
        END
    | 25 :                                         (* call_2s v4+ *)
        storeVar := RB(pc);  INC(pc);
        args[0] := b;
        DoCall(PackedAddr(a), 1, args, storeVar)
    | 26 :                                         (* call_2n v5+ *)
        args[0] := b;
        DoCall(PackedAddr(a), 1, args, -1)
    ELSE
    END

  (* ── VAR ─────────────────────────────────────────────────── *)
  ELSIF form = 2 THEN
    CASE opcode OF
      0 :                                          (* call / call_vs *)
        storeVar := RB(pc);  INC(pc);
        nArgs := nops - 1;
        FOR i := 0 TO nArgs - 1 DO args[i] := ops[i+1] END;
        IF zver <= 3 THEN
          DoCall(PackedAddr(ops[0]), nArgs, args, storeVar)
        ELSE
          DoCall(PackedAddr(ops[0]), nArgs, args, storeVar)
        END
    | 1 :                                          (* storew *)
        WW(ops[0] + ops[1] * 2, ops[2])
    | 2 :                                          (* storeb *)
        WB(ops[0] + ops[1], ops[2])
    | 3 :                                          (* put_prop *)
        WriteProp(ops[0], ops[1], ops[2])
    | 4 :                                          (* sread (v1-4) / aread (v5) *)
        IF zver <= 3 THEN
          ShowStatus
        END;
        FlushWord;
        Out.String("> ");
        curCol := 3;
        ReadLine(ops[0]);
        IF zver <= 4 THEN
          IF nops >= 2 THEN Tokenise(ops[0], ops[1]) END
        ELSE
          (* v5: aread stores terminator in storeVar *)
          storeVar := RB(pc);  INC(pc);
          IF (nops >= 2) & (ops[1] # 0) THEN Tokenise(ops[0], ops[1]) END;
          SetVar(storeVar, 13)  (* Enter = 13 *)
        END
    | 5 :                                          (* print_char *)
        EmitChar(CHR(ops[0]))
    | 6 :                                          (* print_num *)
        EmitInt(S16(ops[0]))
    | 7 :                                          (* random *)
        storeVar := RB(pc);  INC(pc);
        IF ops[0] = 0 THEN
          SetVar(storeVar, 0)  (* seed with time: simplified *)
        ELSIF S16(ops[0]) < 0 THEN
          SetVar(storeVar, 0)
        ELSE
          SetVar(storeVar, Terminal.Random(ops[0]) + 1)
        END
    | 8 :                                          (* push *)
        Push(ops[0])
    | 9 :                                          (* pull *)
        IndSet(ops[0], Pop())
    | 10 :                                         (* split_window *)
        upperRows := ops[0];
        IF upperRows = 0 THEN
          SetScrollRegion(1, screenH)   (* full screen scrolls *)
        ELSE
          SetScrollRegion(upperRows + 1, screenH);  (* lower window only *)
          (* Clear upper rows *)
          Terminal.Goto(1, 1);
          FOR i := 1 TO upperRows DO
            Terminal.Goto(1, i);
            FOR val := 1 TO screenW DO Out.Char(' ') END
          END;
          Terminal.Goto(1, upperRows + 1)
        END
    | 11 :                                         (* set_window *)
        IF ops[0] = 1 THEN
          (* Switch to upper window: save lower cursor, go to upper *)
          IF curWin = 0 THEN Esc("[s") END;
          curWin := 1;
          upperX := 1;  upperY := 1;
          Terminal.Goto(upperX, upperY)
        ELSE
          (* Switch to lower window: restore saved lower cursor *)
          curWin := 0;
          Esc("[u")
        END
    | 12 :                                         (* call_vs2 (v4+) *)
        storeVar := RB(pc);  INC(pc);
        nArgs := nops - 1;
        FOR i := 0 TO nArgs - 1 DO args[i] := ops[i+1] END;
        DoCall(PackedAddr(ops[0]), nArgs, args, storeVar)
    | 13 :                                         (* erase_window *)
        IF ops[0] = 0 THEN
          Terminal.Goto(1, upperRows + 1)
        ELSIF ops[0] = 1 THEN
          (* clear upper window *)
          FOR i := 1 TO upperRows DO
            Terminal.Goto(1, i);  Esc("[2K")
          END;
          Terminal.Goto(1, 1)
        ELSIF S16(ops[0]) = -1 THEN
          Terminal.Clear;
          curWin := 0;  curCol := 1
        ELSIF S16(ops[0]) = -2 THEN
          (* unsplit, clear all, select lower window *)
          upperRows := 0;
          SetScrollRegion(1, screenH);
          Terminal.Clear;
          curWin := 0;  curCol := 1
        END
    | 14 :                                         (* erase_line *)
        FlushWord;
        Esc("[K")
    | 15 :                                         (* set_cursor *)
        IF curWin = 1 THEN
          upperY := ops[0];  upperX := ops[1];
          Terminal.Goto(upperX, upperY)
        END
    | 16 :                                         (* get_cursor *)
        (* store [row, col] into table at ops[0] *)
        IF curWin = 1 THEN
          WW(ops[0], upperY);  WW(ops[0] + 2, upperX)
        ELSE
          WW(ops[0], screenH);  WW(ops[0] + 2, curCol)
        END
    | 17 :                                         (* set_text_style: ignore *)
    | 18 :                                         (* buffer_mode: ignore *)
    | 19 :                                         (* output_stream *)
        IF S16(ops[0]) = 3 THEN
          IF (strm3Top < 16) & (ops[1] > 0) THEN
            strm3Stk[strm3Top] := ops[1];
            strm3Len[strm3Top] := 0;
            INC(strm3Top);
            strm3    := ops[1];
            strm3len := 0;
            WW(strm3, 0)  (* initial length word = 0 *)
          END
        ELSIF S16(ops[0]) = -3 THEN
          IF strm3Top > 0 THEN
            WW(strm3, strm3len);  (* write final length *)
            DEC(strm3Top);
            IF strm3Top > 0 THEN
              strm3    := strm3Stk[strm3Top - 1];
              strm3len := strm3Len[strm3Top - 1]
            ELSE
              strm3    := 0;
              strm3len := 0
            END
          END
        END
    | 20 :                                         (* input_stream: ignore *)
    | 21 :                                         (* sound_effect: ignore *)
    | 22 :                                         (* read_char (v4+) *)
        storeVar := RB(pc);  INC(pc);
        Terminal.ShowCursor;
        val := ORD(Terminal.ReadKey());
        Terminal.HideCursor;
        SetVar(storeVar, val)
    | 23 :                                         (* scan_table *)
        storeVar := RB(pc);  INC(pc);
        a := ops[1];  b := ops[2];  (* table addr, length *)
        val := 0;
        IF nops >= 4 THEN t := ops[3] ELSE t := 130 END;  (* 0x82 *)
        i := 0;
        WHILE i < b DO
          IF ODD(t DIV 128) THEN  (* word comparison *)
            IF RW(a + i * (t MOD 128)) = ops[0] THEN
              val := a + i * (t MOD 128);  i := b
            END
          ELSE                    (* byte comparison *)
            IF RB(a + i * (t MOD 128)) = ops[0] THEN
              val := a + i * (t MOD 128);  i := b
            END
          END;
          INC(i)
        END;
        SetVar(storeVar, val);
        DoBranch(val # 0)
    | 24 :                                         (* not v5+ *)
        storeVar := RB(pc);  INC(pc);
        SetVar(storeVar, BitNOT16(ops[0]))
    | 25 :                                         (* call_vn (v5+) *)
        nArgs := nops - 1;
        FOR i := 0 TO nArgs - 1 DO args[i] := ops[i+1] END;
        DoCall(PackedAddr(ops[0]), nArgs, args, -1)
    | 26 :                                         (* call_vn2 (v5+) *)
        nArgs := nops - 1;
        FOR i := 0 TO nArgs - 1 DO args[i] := ops[i+1] END;
        DoCall(PackedAddr(ops[0]), nArgs, args, -1)
    | 27 :                                         (* tokenise (v5+) *)
        IF ops[1] # 0 THEN Tokenise(ops[0], ops[1]) END
    | 29 :                                         (* copy_table (v5+) *)
        val := S16(ops[2]);  (* signed: positive = safe backward copy, negative = forward *)
        IF ops[1] = 0 THEN
          FOR i := 0 TO ABS(val) - 1 DO WB(ops[0] + i, 0) END
        ELSIF val >= 0 THEN
          FOR i := val - 1 TO 0 BY -1 DO
            WB(ops[1] + i, RB(ops[0] + i))
          END
        ELSE
          FOR i := 0 TO (-val) - 1 DO
            WB(ops[1] + i, RB(ops[0] + i))
          END
        END
    | 30 :                                         (* print_table (v5+) *)
        (* ops[0]=addr, ops[1]=width, ops[2]=height (default 1), ops[3]=skip *)
        IF nops < 3 THEN ops[2] := 1 END;
        IF nops < 4 THEN ops[3] := 0 END;
        a := ops[0];
        FOR i := 0 TO ops[2] - 1 DO
          FOR t := 0 TO ops[1] - 1 DO
            EmitChar(CHR(RB(a + t)))
          END;
          INC(a, ops[1] + ops[3]);
          IF i < ops[2] - 1 THEN EmitNewline END
        END
    | 31 :                                         (* check_arg_count (v5+) *)
        DoBranch(ops[0] <= frames[fp].argCount)
    ELSE
    END

  (* ── EXT (v5+) ───────────────────────────────────────────── *)
  ELSIF form = 3 THEN
    CASE opcode OF
      0 :                                          (* save (extended) *)
        storeVar := RB(pc);  INC(pc);
        IF DoSave() THEN SetVar(storeVar, 1)
        ELSE SetVar(storeVar, 0)
        END
    | 1 :                                          (* restore (extended) *)
        storeVar := RB(pc);  INC(pc);
        IF DoRestore() THEN SetVar(storeVar, 2)
        ELSE SetVar(storeVar, 0)
        END
    | 2 :                                          (* log_shift *)
        storeVar := RB(pc);  INC(pc);
        a := ops[0];  b := S16(ops[1]);
        IF b >= 0 THEN
          WHILE b > 0 DO a := a * 2;  DEC(b) END
        ELSE
          b := ABS(b);
          WHILE b > 0 DO a := a DIV 2;  DEC(b) END
        END;
        SetVar(storeVar, U16(a))
    | 3 :                                          (* art_shift *)
        storeVar := RB(pc);  INC(pc);
        a := S16(ops[0]);  b := S16(ops[1]);
        IF b >= 0 THEN
          WHILE b > 0 DO a := a * 2;  DEC(b) END
        ELSE
          b := ABS(b);
          WHILE b > 0 DO a := a DIV 2;  DEC(b) END
        END;
        SetVar(storeVar, U16(a))
    | 4 :                                          (* set_font: return 1 *)
        storeVar := RB(pc);  INC(pc);
        SetVar(storeVar, 1)
    | 5 :                                          (* set_colour: ignore *)
    | 9 :                                          (* save_undo *)
        storeVar := RB(pc);  INC(pc);
        SetVar(storeVar, -1)   (* unsupported *)
    | 10 :                                         (* restore_undo *)
        storeVar := RB(pc);  INC(pc);
        SetVar(storeVar, 0)
    ELSE
    END
  END
END Step;

(* ══════════════════════════════════════════════════════════════
   Initialisation
   ══════════════════════════════════════════════════════════════ *)

PROCEDURE LoadFile(name: ARRAY OF CHAR): BOOLEAN;
VAR f: Files.File;
    r: Files.Rider;
    i: INTEGER;
    b: BYTE;
BEGIN
  f := Files.Old(name);
  IF f = NIL THEN RETURN FALSE END;
  flen := Files.Length(f);
  IF flen > MEMSIZE THEN flen := MEMSIZE END;
  Files.Set(r, f, 0);
  FOR i := 0 TO flen - 1 DO
    Files.Read(r, b);
    mem[i] := b
  END;
  Files.Close(f);
  RETURN TRUE
END LoadFile;

PROCEDURE Init;
VAR i, addr: INTEGER;
BEGIN
  (* Read header *)
  zver     := RB(0);
  himem    := RW(4);
  iPC      := RW(6);
  dictAddr := RW(8);
  objAddr  := RW(10);
  globBase := RW(12);
  statBase := RW(14);
  abbrev   := RW(24);

  (* Load dictionary info *)
  addr      := dictAddr;
  nTermSep  := RB(addr);  INC(addr);
  FOR i := 0 TO nTermSep - 1 DO
    termSep[i] := RB(addr);  INC(addr)
  END;
  dictEntSz := RB(addr);  INC(addr);
  dictNEnt  := S16(RW(addr));

  (* Execution state *)
  sp  := 0;
  fp  := -1;
  running := TRUE;
  curCol := 1;
  IF zver <= 3 THEN upperRows := 1 ELSE upperRows := 0 END;
  curWin   := 0;
  upperX   := 1;
  upperY   := 1;
  strm3Top := 0;
  strm3    := 0;
  strm3len := 0;
  wrapLen  := 0;

  (* Set flags in header for terminal capabilities *)
  WB(1, BitClr(RB(1), 4));  (* no status line split needed *)
  WB(1, BitSet(RB(1), 5));  (* screen splitting available *)
  IF zver >= 4 THEN
    WB(1, BitSet(RB(1), 0))  (* colours available *)
  END;
  WB(32, screenW);   (* screen width in chars (byte) *)
  WB(33, screenH);   (* screen height in lines (byte) *)
  IF zver >= 5 THEN
    WW(34, screenW);   (* screen width in units *)
    WW(36, screenH);   (* screen height in units *)
    WB(38, 1);         (* font width in units *)
    WB(39, 1);         (* font height in units *)
    WB(44, 1);         (* default background colour: black *)
    WB(45, 9)          (* default foreground colour: white *)
  END;

  (* v1-4: header word 6 is initial byte PC directly.
     v5+: header word 6 is initial byte PC (main routine entry point). *)
  pc := iPC
END Init;

(* ══════════════════════════════════════════════════════════════
   Main
   ══════════════════════════════════════════════════════════════ *)

VAR fname : ARRAY 256 OF CHAR;
    i     : INTEGER;

BEGIN
  (* Debug file *)
  dbgF := Files.New("/tmp/zmdbg.txt");
  IF dbgF # NIL THEN
    Files.Set(dbgR, dbgF, 0);
    Files.Register(dbgF)
  END;
  dbgN := 0;

  (* Build tables *)
  pw2[0] := 1;
  FOR i := 1 TO 16 DO pw2[i] := pw2[i-1] * 2 END;

  (* A2 table: positions 8-31 (24 entries) *)
  a2tab[ 0] := '0';  a2tab[ 1] := '1';  a2tab[ 2] := '2';
  a2tab[ 3] := '3';  a2tab[ 4] := '4';  a2tab[ 5] := '5';
  a2tab[ 6] := '6';  a2tab[ 7] := '7';  a2tab[ 8] := '8';
  a2tab[ 9] := '9';  a2tab[10] := '.';  a2tab[11] := ',';
  a2tab[12] := '!';  a2tab[13] := '?';  a2tab[14] := '_';
  a2tab[15] := '#';  a2tab[16] := "'";  a2tab[17] := '"';
  a2tab[18] := '/';  a2tab[19] := 5CH;  a2tab[20] := '-';
  a2tab[21] := ':';  a2tab[22] := '(';  a2tab[23] := ')';

  screenW := Terminal.Cols();
  screenH := Terminal.Rows();

  IF Args.Count() < 1 THEN
    Out.String("Usage: zmachine <story-file>");  Out.Char(0AX);
    HALT(1)
  END;
  Args.Get(1, fname);

  IF ~LoadFile(fname) THEN
    Out.String("Cannot open: ");  Out.String(fname);  Out.Char(0AX);
    HALT(1)
  END;

  Terminal.HideCursor;
  Terminal.Clear;

  Init;

  (* Position cursor at top of lower window; set scroll region *)
  IF upperRows > 0 THEN
    SetScrollRegion(upperRows + 1, screenH)
  END;
  Terminal.Goto(1, upperRows + 1);
  (* Save this as the initial lower-window cursor position *)
  Esc("[s");

  WHILE running DO
    Step
  END;

  (* Restore full-screen scroll region and clear status line *)
  SetScrollRegion(1, screenH);
  curWin := 1;
  Terminal.Goto(1, 1);
  Esc("[2K");        (* erase entire line *)
  Esc("[0m");        (* reset attributes *)
  curWin := 0;
  Terminal.Goto(1, upperRows + 1);
  Esc("[u");

  FlushWord;
  EmitNewline;
  Out.String("[Game over]");
  EmitNewline
END ZMachine.

