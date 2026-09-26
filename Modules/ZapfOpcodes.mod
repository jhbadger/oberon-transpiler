MODULE ZapfOpcodes;
(*
  ZapfOpcodes — Z-machine opcode table, ported from Zapf.Parsing.Instructions.Opcodes (C#).

  Note: the exported table/count fields are named opTable/opCount rather
  than table/count. This transpiler emits exported top-level VARs as
  unscoped C preprocessor #defines (e.g. "#define count ZapfOpcodes_count"),
  which would otherwise silently rewrite unrelated ".count" struct-field
  accesses (ZapfAst.LineList.count, ZapfSym.Table.count, ...) anywhere else
  in the linked program. Any future exported module-level VAR/CONST here
  should keep a distinguishing prefix for the same reason.

  Opcode numbering (matches the Z-Machine Standards Document's own numbering):
    0-31    2OP, opcode = number
    128-143 1OP, opcode = number-128
    176-191 0OP, opcode = number-176
    224-255 VAR, opcode = number-224
    256+    EXT, opcode = number-256

  Flag bits (ZOpFlags):
*)

IMPORT Strings;

CONST
  FlStore*       = 1;
  FlBranch*      = 2;
  FlExtra*       = 4;
  FlVarArgs*     = 8;
  FlString*      = 16;
  FlLabel*       = 32;
  FlIndirectVar* = 64;
  FlCall*        = 128;
  FlTerminates*  = 256;

  (* Several opcode NAMES appear more than once in the table (one entry per
     version range, e.g. COLOR's V5 and V6 forms), so this is bigger than
     the number of distinct mnemonics. Was exactly 128 before the ICALL
     family (ICALL1/ICALL2/ICALL/IXCALL) pushed the real count to 132 -
     silently past the array bound, since Add has no overflow check of its
     own, which dropped every opcode registered after the 128th Add() call
     (XCALL among them) without any error at ALL until a V4 game happened
     to need one of the dropped entries ("unrecognized opcode: XCALL"
     during mandelbrot's assembly, a real regression this fix caused and
     this same fix corrects). Left generous headroom rather than the exact
     count, so the next opcode added here doesn't repeat the mistake. *)
  MaxOps* = 192;

TYPE
  OpEntry* = RECORD
    classicName*: ARRAY 24 OF CHAR;
    informName*: ARRAY 24 OF CHAR;
    minVer*: INTEGER;
    maxVer*: INTEGER;
    number*: INTEGER;
    flags*: INTEGER;
    whenExtra*: ARRAY 16 OF CHAR  (* "" if none; else "XCALL" or "IXCALL" *)
  END;

VAR
  opTable*: ARRAY MaxOps OF OpEntry;
  opCount*: INTEGER;

PROCEDURE Add(classic, inform: ARRAY OF CHAR; minVer, maxVer, number, flags: INTEGER; whenExtra: ARRAY OF CHAR);
BEGIN
  Strings.Copy(classic, opTable[opCount].classicName);
  Strings.Copy(inform, opTable[opCount].informName);
  opTable[opCount].minVer := minVer;
  opTable[opCount].maxVer := maxVer;
  opTable[opCount].number := number;
  opTable[opCount].flags := flags;
  Strings.Copy(whenExtra, opTable[opCount].whenExtra);
  INC(opCount)
END Add;

PROCEDURE Init*;
BEGIN
  opCount := 0;
  Add("ADD", "add", 1, 6, 20, FlStore, "");
  Add("ARCIMG", "draw_image", 5, 5, 384, 0, "");
  Add("ASHIFT", "art_shift", 5, 6, 259, FlStore, "");
  Add("ASSIGNED?", "check_arg_count", 5, 6, 255, FlBranch + FlIndirectVar, "");
  Add("BAND", "and", 1, 6, 9, FlStore, "");
  Add("BCOM", "not", 1, 4, 143, FlStore, "");
  Add("BCOM", "not", 5, 6, 248, FlStore, "");
  Add("BOR", "or", 1, 6, 8, FlStore, "");
  Add("BTST", "test", 1, 6, 7, FlBranch, "");
  Add("BUFOUT", "buffer_mode", 4, 6, 242, 0, "");
  Add("BUFSCR", "buffer_screen", 6, 6, 285, FlStore, "");
  Add("CALL", "call_vs", 1, 6, 224, FlStore + FlCall, "XCALL");
  Add("CALL1", "call_1s", 4, 6, 136, FlStore + FlCall, "");
  Add("CALL2", "call_2s", 4, 6, 25, FlStore + FlCall, "");
  (* the NON-STORING call family, V5+ only - real zilf's own EmitCall uses
     these instead of CALL/CALL1/CALL2/XCALL + FSTACK once a version has
     them, because FSTACK's own opcode (pop, 1-4 only) doesn't exist in V5
     - there's no way to discard a V5 CALL's result other than never
     storing it in the first place. Same 0/1/2-3/4+ argument-count split as
     CALL/CALL1/CALL2/XCALL, "I"-prefixed to match the real compiler's own
     naming (ICALL1/ICALL2/ICALL/IXCALL, confirmed against a real V5 build
     of cloak_plus.zil). *)
  Add("ICALL1", "call_1n", 5, 6, 143, FlCall, "");
  Add("ICALL2", "call_2n", 5, 6, 26, FlCall, "");
  Add("ICALL", "call_vn", 5, 6, 249, FlCall, "IXCALL");
  Add("IXCALL", "call_vn2", 5, 6, 250, FlCall + FlExtra, "");
  Add("CATCH", "catch", 5, 6, 185, FlStore, "");
  Add("CHECKU", "check_unicode", 5, 6, 268, FlStore, "");
  Add("CLEAR", "erase_window", 4, 6, 237, 0, "");
  Add("COLOR", "set_colour", 5, 5, 27, 0, "");
  Add("COLOR", "set_colour", 6, 6, 27, FlVarArgs, "");
  Add("COPYT", "copy_table", 5, 6, 253, 0, "");
  Add("CRLF", "new_line", 1, 6, 187, 0, "");
  Add("CURGET", "get_cursor", 4, 6, 240, 0, "");
  Add("CURSET", "set_cursor", 4, 6, 239, 0, "");
  Add("DCLEAR", "erase_picture", 6, 6, 263, 0, "");
  Add("DEC", "dec", 1, 6, 134, FlIndirectVar, "");
  Add("DIRIN", "input_stream", 3, 6, 244, 0, "");
  Add("DIROUT", "output_stream", 3, 6, 243, 0, "");
  Add("DISPLAY", "draw_picture", 6, 6, 261, 0, "");
  Add("DIV", "div", 1, 6, 23, FlStore, "");
  Add("DLESS?", "dec_chk", 1, 6, 4, FlBranch + FlIndirectVar, "");
  Add("EQUAL?", "je", 1, 6, 1, FlBranch + FlVarArgs, "");
  Add("ERASE", "erase_line", 4, 6, 238, 0, "");
  Add("FCLEAR", "clear_attr", 1, 6, 12, 0, "");
  Add("FIRST?", "get_child", 1, 6, 130, FlStore + FlBranch, "");
  Add("FONT", "set_font", 5, 6, 260, FlStore, "");
  Add("FSET", "set_attr", 1, 6, 11, 0, "");
  Add("FSET?", "test_attr", 1, 6, 10, FlBranch, "");
  Add("FSTACK", "pop", 1, 4, 185, 0, "");
  Add("FSTACK", "pop_stack", 6, 6, 277, 0, "");
  Add("GET", "loadw", 1, 6, 15, FlStore, "");
  Add("GETB", "loadb", 1, 6, 16, FlStore, "");
  Add("GETP", "get_prop", 1, 6, 17, FlStore, "");
  Add("GETPT", "get_prop_addr", 1, 6, 18, FlStore, "");
  Add("GRTR?", "jg", 1, 6, 3, FlBranch, "");
  Add("HLIGHT", "set_text_style", 4, 6, 241, 0, "");
  Add("ICALL", "call_vn", 5, 6, 249, FlCall, "IXCALL");
  Add("ICALL1", "call_1n", 5, 6, 143, FlCall, "");
  Add("ICALL2", "call_2n", 5, 6, 26, FlCall, "");
  Add("IGRTR?", "inc_chk", 1, 6, 5, FlBranch + FlIndirectVar, "");
  Add("IN?", "jin", 1, 6, 6, FlBranch, "");
  Add("INC", "inc", 1, 6, 133, FlIndirectVar, "");
  Add("INPUT", "read_char", 4, 6, 246, FlStore, "");
  Add("INTBL?", "scan_table", 4, 6, 247, FlStore + FlBranch, "");
  Add("IRESTORE", "restore_undo", 5, 6, 266, FlStore, "");
  Add("ISAVE", "save_undo", 5, 6, 265, FlStore, "");
  Add("IXCALL", "call_vn2", 5, 6, 250, FlExtra + FlCall, "");
  Add("JUMP", "jump", 1, 6, 140, FlLabel + FlTerminates, "");
  Add("LESS?", "jl", 1, 6, 2, FlBranch, "");
  Add("LEX", "tokenise", 5, 6, 251, 0, "");
  Add("LOC", "get_parent", 1, 6, 131, FlStore, "");
  Add("MARGIN", "set_margins", 6, 6, 264, 0, "");
  Add("MENU", "make_menu", 6, 6, 283, FlBranch, "");
  Add("MOD", "mod", 1, 6, 24, FlStore, "");
  Add("MOUSE-INFO", "read_mouse", 6, 6, 278, 0, "");
  Add("MOUSE-LIMIT", "mouse_window", 6, 6, 279, 0, "");
  Add("MOVE", "insert_obj", 1, 6, 14, 0, "");
  Add("MUL", "mul", 1, 6, 22, FlStore, "");
  Add("NEXT?", "get_sibling", 1, 6, 129, FlStore + FlBranch, "");
  Add("NEXTP", "get_next_prop", 1, 6, 19, FlStore, "");
  Add("NOOP", "nop", 1, 6, 180, 0, "");
  Add("ORIGINAL?", "piracy", 5, 6, 191, FlBranch, "");
  Add("PICINF", "picture_data", 6, 6, 262, FlBranch, "");
  Add("PICSET", "picture_table", 6, 6, 284, 0, "");
  Add("POP", "pull", 1, 5, 233, 0, "");
  Add("POP", "pull", 6, 6, 233, FlStore, "");
  Add("PRINT", "print_paddr", 1, 6, 141, 0, "");
  Add("PRINTB", "print_addr", 1, 6, 135, 0, "");
  Add("PRINTC", "print_char", 1, 6, 229, 0, "");
  Add("PRINTD", "print_obj", 1, 6, 138, 0, "");
  Add("PRINTF", "print_form", 6, 6, 282, 0, "");
  Add("PRINTI", "print", 1, 6, 178, FlString, "");
  Add("PRINTN", "print_num", 1, 6, 230, 0, "");
  Add("PRINTR", "print_ret", 1, 6, 179, FlString + FlTerminates, "");
  Add("PRINTT", "print_table", 5, 6, 254, 0, "");
  Add("PRINTU", "print_unicode", 5, 6, 267, 0, "");
  Add("PTSIZE", "get_prop_len", 1, 6, 132, FlStore, "");
  Add("PUSH", "push", 1, 6, 232, 0, "");
  Add("PUT", "storew", 1, 6, 225, 0, "");
  Add("PUTB", "storeb", 1, 6, 226, 0, "");
  Add("PUTP", "put_prop", 1, 6, 227, 0, "");
  Add("QUIT", "quit", 1, 6, 186, FlTerminates, "");
  Add("RANDOM", "random", 1, 6, 231, FlStore, "");
  Add("READ", "sread", 1, 4, 228, 0, "");
  Add("READ", "aread", 5, 6, 228, FlStore, "");
  Add("REMOVE", "remove_obj", 1, 6, 137, 0, "");
  Add("RESTART", "restart", 1, 6, 183, FlTerminates, "");
  Add("RESTORE", "restore", 1, 3, 182, FlBranch, "");
  Add("RESTORE", "restore", 4, 4, 182, FlStore, "");
  Add("RESTORE", "restore", 5, 6, 257, FlStore, "");
  Add("RETURN", "ret", 1, 6, 139, FlTerminates, "");
  Add("RFALSE", "rfalse", 1, 6, 177, FlTerminates, "");
  Add("RSTACK", "ret_popped", 1, 6, 184, FlTerminates, "");
  Add("RTRUE", "rtrue", 1, 6, 176, FlTerminates, "");
  Add("SAVE", "save", 1, 3, 181, FlBranch, "");
  Add("SAVE", "save", 4, 4, 181, FlStore, "");
  Add("SAVE", "save", 5, 6, 256, FlStore, "");
  Add("SCREEN", "set_window", 3, 6, 235, 0, "");
  Add("SCROLL", "scroll_window", 6, 6, 276, 0, "");
  Add("SET", "store", 1, 6, 13, FlIndirectVar, "");
  Add("SHIFT", "log_shift", 5, 6, 258, FlStore, "");
  Add("SOUND", "sound_effect", 3, 6, 245, 0, "");
  Add("SPLIT", "split_window", 3, 6, 234, 0, "");
  Add("SUB", "sub", 1, 6, 21, FlStore, "");
  Add("TCOLOR", "set_true_colour", 5, 5, 269, 0, "");
  Add("TCOLOR", "set_true_colour", 6, 6, 269, 0, "");
  Add("THROW", "throw", 5, 6, 28, FlTerminates, "");
  Add("USL", "show_status", 1, 3, 188, 0, "");
  Add("VALUE", "load", 1, 6, 142, FlStore + FlIndirectVar, "");
  Add("VERIFY", "verify", 3, 6, 189, FlBranch, "");
  Add("WINATTR", "window_style", 6, 6, 274, 0, "");
  Add("WINGET", "get_wind_prop", 6, 6, 275, FlStore, "");
  Add("WINPOS", "move_window", 6, 6, 272, 0, "");
  Add("WINPUT", "put_wind_prop", 6, 6, 281, 0, "");
  Add("WINSIZE", "window_size", 6, 6, 273, 0, "");
  Add("XCALL", "call_vs2", 4, 6, 236, FlStore + FlExtra + FlCall, "");
  Add("XPUSH", "push_stack", 6, 6, 280, FlBranch, "");
  Add("ZERO?", "jz", 1, 6, 128, FlBranch, "");
  Add("ZWSTR", "encode_text", 5, 6, 252, 0, "")
END Init;

(* opcode-number ranges *)
PROCEDURE Form*(number: INTEGER; VAR opcode: INTEGER): INTEGER;
(* returns: 0=2OP 1=1OP 2=0OP 3=VAR 4=EXT; opcode := raw opcode number within the form *)
BEGIN
  IF number < 32 THEN opcode := number; RETURN 0
  ELSIF number < 144 THEN opcode := number - 128; RETURN 1
  ELSIF number < 192 THEN opcode := number - 176; RETURN 2
  ELSIF number < 256 THEN opcode := number - 224; RETURN 3
  ELSE opcode := number - 256; RETURN 4
  END
END Form;

PROCEDURE EffectiveVersion*(zversion: INTEGER): INTEGER;
BEGIN
  IF (zversion = 7) OR (zversion = 8) THEN RETURN 5 ELSE RETURN zversion END
END EffectiveVersion;

(* Mnemonic lookup for a given (already-effective) version and naming mode. *)
PROCEDURE Lookup*(name: ARRAY OF CHAR; effVersion: INTEGER; inform: BOOLEAN; VAR idx: INTEGER): BOOLEAN;
VAR i: INTEGER; cand: ARRAY 24 OF CHAR; found: BOOLEAN;
BEGIN
  i := 0; found := FALSE;
  WHILE (i < opCount) & ~found DO
    IF (effVersion >= opTable[i].minVer) & (effVersion <= opTable[i].maxVer) THEN
      IF inform THEN cand := opTable[i].informName ELSE cand := opTable[i].classicName END;
      IF cand = name THEN idx := i; found := TRUE END
    END;
    INC(i)
  END;
  RETURN found
END Lookup;

END ZapfOpcodes.
