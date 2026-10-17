MODULE obperfect;
(*
 * obperfect -- a WordPerfect 4.2 work-alike, after the WordPerfect chapters
 * (5-10) of Tim Duffy's "Four Software Tools".
 *
 * Usage:
 *   obperfect [file]          edit file (Doc 1)
 *   obperfect -s              start with the Set-up menu (like "WP/S")
 *   obperfect -t file         print the text of a WordPerfect file to stdout
 *   obperfect -r file         show a file's codes the way Reveal Codes does
 *   obperfect -p file [out]   "print" file (formatted pages) to out or stdout
 *   obperfect -c in out       convert: out ending .wp5/.wpd -> WP 5.1,
 *                             .txt -> DOS text, anything else -> WP 4.2
 *
 * Documents are read and written as genuine WordPerfect files.  The native
 * format is WordPerfect 4.2 (WordPerfect Corporation's "WordPerfect File
 * Information", 1986: text with embedded single-byte codes 80h-BFh and
 * gated multi-byte functions C0h-FEh).  WordPerfect 5.0/5.1 files (the
 * FFh "WPC" header format) are read too, and can be written with
 * Text In/Out (Ctrl-F5).  Plain DOS text files are retrieved as text.
 *
 * Main pieces, in source order:
 *   character tables, strings, keyboard (function keys, macros), screen
 *   the document model: a stream of characters and codes
 *   WordPerfect 4.2 and 5.1 readers and writers, DOS text
 *   the formatter: word wrap, tabs, indents, centering, pagination
 *   screen display, status line, Reveal Codes
 *   editing, block, move, undelete, search and replace
 *   format menus: Line, Page and Print Format, headers, footnotes
 *   printing and preview, List Files, Text In/Out, Set-up
 *   Speller, Thesaurus, Merge, Sort, Math, Line Draw, macros, Help
 *   the main command loop
 *)

IMPORT TUI, Terminal, Files, Strings, Time, Args, OS, Out;

CONST
  Version = "obperfect 1.0 (WordPerfect 4.2 work-alike)";

  (* ---- document item kinds ---- *)
  kChar = 0;      (* ch: a character in IBM code page 437 *)
  kCtl = 1;       (* ch: control character 01X..1FX (merge codes ^C ^D ^E ...) *)
  kHRt = 2;       (* hard return *)
  kHPg = 3;       (* hard page *)
  kTab = 4;       (* tab *)
  kAttrOn = 5;    (* a: attribute number (aBold ...) *)
  kAttrOff = 6;
  kSingle = 7;    (* a: other single-byte function code (80h-BFh) *)
  kCenter = 8;    (* a: type (0 margins, 1 column), b: center col *)
  kEndCenter = 9;
  kAlign = 10;    (* a: align char (0AX = flush right), b: column; c: 1 dot leader *)
  kEndAlign = 11;
  kMargin = 12;   (* a: left, b: right *)
  kSpacing = 13;  (* a: half-lines per line (2 = single) *)
  kMarRel = 14;   (* a: spaces to go left *)
  kHZone = 15;    (* a: left zone, b: right zone *)
  kPnPos = 16;    (* a: page number position 0..8 *)
  kPgNum = 17;    (* a: new page number, b: 1 = roman *)
  kPnCol = 18;    (* a, b, c: left / center / right column *)
  kCondEOP = 19;  (* a: lines to keep together *)
  kFont = 20;     (* a: pitch (negative = proportional), b: font *)
  kIndent = 21;   (* a: new temporary margin *)
  kTopMar = 22;   (* a: half-lines *)
  kSuppress = 23; (* a: suppress bits *)
  kFormLen = 24;  (* a: form length (lines), b: text lines (half-lines) *)
  kHdrFtr = 25;   (* a: definition byte, b: left margin, c: right margin, sub *)
  kAdvLn = 26;    (* a: advance to half-line *)
  kLPI = 27;      (* a: 6 or 8 *)
  kMathDef = 28;  (* s: column definitions *)
  kAlignChar = 29;(* a: alignment character *)
  kUndMode = 30;  (* a: underline style 0..3 *)
  kBin = 31;      (* a: sheet feeder bin (1 = first) *)
  kPrnCmd = 32;   (* s: printer command text *)
  kLRIndent = 33; (* a: indent amount *)
  kNote = 34;     (* a: definition (bit 1 = endnote), b: number, sub *)
  kNoteOpt = 35;  (* s: 74 bytes of footnote options *)
  kNoteNum = 36;  (* a: new footnote number *)
  kDate = 37;     (* s: date format *)
  kBlockPro = 38; (* a: 0 on, 1 off *)
  kComment = 39;  (* a: 0 comment, 1 document summary; sub *)
  kTabSet = 40;   (* s: 52 bytes: tab bitmap + type nibbles *)
  kLineNum = 41;  (* a: interval byte, b: position *)
  kMark = 42;     (* a: 1 begin / 0 end marked text, b: definition byte *)
  kRaw = 43;      (* s: an unrecognised WP 4.2 function, kept verbatim *)
  kRaw5 = 44;     (* s: an unrecognised WP 5.x function, kept verbatim *)
  kDefMark = 45;  (* s: define marked text / index mark etc. (WP 4.2 raw) *)

  (* ---- attributes (bit numbers) ---- *)
  aBold = 0; aUnd = 1; aRed = 2; aStrike = 3; aItal = 4; aShadow = 5;
  aOutline = 6; aRev = 7;
  (* extra bits used only on screen *)
  bSuper = 8; bSub = 9; bBlock = 10; bCode = 11; bGen = 12;

  (* ---- single-byte functions (WP 4.2) ---- *)
  fJustOn = 81H; fJustOff = 82H; fEndCenter = 83H; fEndAlign = 84H;
  fCenterPg = 86H; fColOn = 87H; fColOff = 88H; fTabRM = 89H;
  fWOOn = 8AH; fWOOff = 8BH; fHRtSPg = 8CH; fNoteNum = 8DH;
  fRedOn = 90H; fRedOff = 91H; fStrkOn = 92H; fStrkOff = 93H;
  fUndOn = 94H; fUndOff = 95H; fRevOn = 96H; fRevOff = 97H;
  fToC = 98H; fOvrstk = 99H; fNoHyph = 9AH; fEndGen = 9BH;
  fBoldOff = 9CH; fBoldOn = 9DH; fHyphOff = 9EH; fHyphOn = 9FH;
  fHardSp = 0A0H; fDoSub = 0A1H; fSubEnt = 0A2H; fDoTot = 0A3H;
  fTotEnt = 0A4H; fDoGrand = 0A5H; fCalcCol = 0A6H; fMathOn = 0A7H;
  fMathOff = 0A8H; fHardHy = 0A9H; fSoftHy = 0ACH; fNeg = 0B1H;
  fItalOn = 0B2H; fItalOff = 0B3H; fShadOn = 0B4H; fShadOff = 0B5H;
  fOutlOn = 0B6H; fOutlOff = 0B7H; fSuper = 0BCH; fSub = 0BDH;
  fAdvUp = 0BEH; fAdvDn = 0BFH;

  (* ---- file formats ---- *)
  fmtWP42 = 0; fmtWP5 = 1; fmtText = 2; fmtNew = 3;

  (* ---- line breaks ---- *)
  brSoft = 0; brHard = 1; brPage = 2; brEnd = 3;

  (* ---- display row kinds ---- *)
  rText = 0; rBlank = 1; rSoftPg = 2; rHardPg = 3; rCmtTop = 4;
  rCmtText = 5; rCmtBot = 6;

  (* ---- keys (see GetKey) ---- *)
  KBS = 127;        (* Backspace *)
  KCtrlBS = 8;      (* Ctrl-Backspace *)
  KEnter = 13; KTab = 9; KEsc = 27; KCtrlEnter = 10;
  KF = 2000;        (* KF + 100*mod + n : function key n with modifiers *)
  KNav = 3000;      (* KNav + 100*mod + code : navigation keys *)
  nUp = 1; nDown = 2; nLeft = 3; nRight = 4; nHome = 5; nEnd = 6; nPgUp = 7;
  nPgDn = 8; nDel = 9; nIns = 10; nTab = 11;
  KAlt = 4000;      (* KAlt + ORD(lower-case letter): Alt+letter *)
  KMouse = 5000;
  KExt = 1000;      (* KExt + byte: a code page 437 character above 7FH *)
  mShift = 1; mAlt = 2; mCtrl = 4;


  MaxPath = 512;
  MaxPrompt = 256;
  MaxQueue = 20000;
  MaxMacro = 8000;
  MaxRows = 60;
  MaxCols = 220;
  NoteLen = 74;

TYPE
  Path = ARRAY MaxPath OF CHAR;
  Str = ARRAY 256 OF CHAR;
  Bytes = POINTER TO ARRAY OF CHAR;
  Doc = POINTER TO DocRec;
  Item = RECORD
    k, a, b, c: INTEGER;
    ch: CHAR;
    s: Bytes;         (* payload bytes (sl of them) *)
    sl: INTEGER;
    sub: Doc          (* header/footer, note or comment text *)
  END;
  Items = POINTER TO ARRAY OF Item;
  DocRec = RECORD
    n, cap: INTEGER;
    it: Items
  END;
  IntArr = POINTER TO ARRAY OF INTEGER;

  (* format state at a point of the document *)
  Fmt = RECORD
    lm, rm, spacing, alignCh: INTEGER;
    tabs: ARRAY 256 OF CHAR;     (* 0X no tab, else CHR(type + 1) *)
    just, widow, hyph, mathOn: BOOLEAN;
    hzL, hzR: INTEGER;
    pnPos, pnL, pnC, pnR: INTEGER;
    topMar, formLen, textHalf, lpi, pitch, font, undMode, bin: INTEGER;
    lineNum, lnPos: INTEGER;
    attr: INTEGER;
    hdr: ARRAY 4 OF Doc;          (* header A, header B, footer A, footer B *)
    hdrOcc: ARRAY 4 OF INTEGER;   (* occurrence bits: 1 all, 2 odd, 4 even *)
    hdrLm, hdrRm: ARRAY 4 OF INTEGER;
    noteOpt: ARRAY NoteLen OF CHAR
  END;
  Fmts = POINTER TO ARRAY OF Fmt;

  Line = RECORD
    start, end, brk: INTEGER;    (* items start..end-1; brk = brSoft ... *)
    page, ln, snap, height: INTEGER;  (* page index, half-line on page *)
    lm, row: INTEGER             (* left margin in effect; first display row *)
  END;
  Lines = POINTER TO ARRAY OF Line;

  Page = RECORD
    first, last, num, roman, hard: INTEGER;
    snap: INTEGER;               (* format snapshot at page start *)
    center, suppress: INTEGER;
    hdrMask: INTEGER;            (* headers/footers printed on this page *)
    hdrLines, ftrLines: INTEGER  (* half-lines used *)
  END;
  Pages = POINTER TO ARRAY OF Page;

  Row = RECORD kind, line, x: INTEGER END;
  Rows = POINTER TO ARRAY OF Row;

  (* an editing window onto a document *)
  Ed = POINTER TO EdRec;
  EdRec = RECORD
    d: Doc;
    name: Path;
    num: INTEGER;               (* Doc 1 / Doc 2 *)
    fmt0: Fmt;                  (* settings before the first code *)
    cur, goal, top, hscroll, anchor: INTEGER;
    typeover, modified, dirty: BOOLEAN;
    srcFmt: INTEGER;
    isSub: BOOLEAN;             (* header/footer/note/comment editing *)
    subTitle: Str;
    (* formatter output *)
    icol, iattr: IntArr; icap: INTEGER;
    lines: Lines; nlines, lcap: INTEGER;
    snaps: Fmts; nsnaps, scap: INTEGER;
    pages: Pages; npages, pcap: INTEGER;
    rows: Rows; nrows, rcap: INTEGER;
    endFmt: Fmt
  END;

  Settings = RECORD
    fmt: Fmt;                   (* initial settings *)
    dateFmt: Str;
    typeover: BOOLEAN;
    escN: INTEGER;
    backupMin: INTEGER;
    origBackup, summaryOnSave, autoRewrite, showName: BOOLEAN;
    beepErr, beepSearch, beepHyph: BOOLEAN;
    hrtChar: INTEGER;
    lexPath, supPath, thPath: Path;
    printer: INTEGER;            (* 1..6 *)
    copies, binding: INTEGER;
    prnName: ARRAY 7 OF Str;
    prnPort: ARRAY 7 OF Path;
    fnSpacing, fnBetween, fnKeep, fnLine: INTEGER;
    colors: INTEGER;            (* color scheme 1..4 *)
    altMap: ARRAY 26 OF CHAR    (* Ctrl/Alt keys: Alt+letter types a character *)
  END;

  Deleted = RECORD d: Doc END;

VAR
  (* character tables *)
  cpUni: ARRAY 256 OF INTEGER;         (* CP437 byte -> Unicode *)
  wp5Multi: ARRAY 256 OF INTEGER;      (* WP5 set 1 -> Unicode *)
  wp5Box: ARRAY 256 OF INTEGER;        (* WP5 set 3 *)
  wp5Typo: ARRAY 256 OF INTEGER;       (* WP5 set 4 *)

  cfg: Settings;
  cBg, cFg, cHi: INTEGER;              (* screen colors *)
  eds: ARRAY 3 OF Ed;                  (* Doc 1, Doc 2 *)
  active: INTEGER;                     (* 1 or 2 *)
  e: Ed;                               (* the editor being worked on *)
  winSplit: INTEGER;                   (* rows in window 1 (0 = one window) *)
  revealOn: BOOLEAN;
  scrRows, scrCols: INTEGER;
  quit: BOOLEAN;

  (* keyboard *)
  queue: ARRAY MaxQueue OF INTEGER;
  qHead, qTail: INTEGER;
  pushed: INTEGER;                     (* one key of look-ahead, -1 none *)
  macroRec: BOOLEAN;
  macroBuf: ARRAY MaxMacro OF INTEGER;
  macroLen: INTEGER;
  macroName: Str;
  macroRep: INTEGER;                   (* playback repetitions left *)
  repBuf: ARRAY MaxMacro OF INTEGER;
  repLen: INTEGER;
  tempMacro: ARRAY MaxMacro OF INTEGER;
  tempLen: INTEGER;
  mouseX, mouseY, mouseB: INTEGER;
  lastBackup: LONGINT;
  utfPend: INTEGER;

  (* status line messages *)
  msg: Str;
  msgSticky: BOOLEAN;

  (* clipboard / undelete *)
  clip: Doc;                           (* last cut/copy (Move "Text") *)
  rectClip: Doc;                       (* last rectangle (one line per row) *)
  rectW: INTEGER;
  colClip: Doc;                        (* last tab column *)
  undel: ARRAY 3 OF Deleted;
  delOpen: BOOLEAN;                    (* consecutive deletes accumulate *)
  delAt: INTEGER;
  lastBlockA, lastBlockB: INTEGER;
  prevPos: INTEGER;

  (* search *)
  srch, repl: Doc;
  srchBack: BOOLEAN;

  (* misc *)
  cwd: Path;
  cfgDir: Path;
  printJobs: INTEGER;
  hrtShow: CHAR;
  emptyFmt: Fmt;
  noteCounter: INTEGER;
  batch: BOOLEAN;
(* ---- character set tables (generated from CP437 and libwpd) ---- *)

PROCEDURE InitCp437;
(* IBM code page 437, upper half: byte -> Unicode code point *)
BEGIN
  cpUni[128] := 199; cpUni[129] := 252; cpUni[130] := 233;
  cpUni[131] := 226; cpUni[132] := 228; cpUni[133] := 224;
  cpUni[134] := 229; cpUni[135] := 231; cpUni[136] := 234;
  cpUni[137] := 235; cpUni[138] := 232; cpUni[139] := 239;
  cpUni[140] := 238; cpUni[141] := 236; cpUni[142] := 196;
  cpUni[143] := 197; cpUni[144] := 201; cpUni[145] := 230;
  cpUni[146] := 198; cpUni[147] := 244; cpUni[148] := 246;
  cpUni[149] := 242; cpUni[150] := 251; cpUni[151] := 249;
  cpUni[152] := 255; cpUni[153] := 214; cpUni[154] := 220;
  cpUni[155] := 162; cpUni[156] := 163; cpUni[157] := 165;
  cpUni[158] := 8359; cpUni[159] := 402; cpUni[160] := 225;
  cpUni[161] := 237; cpUni[162] := 243; cpUni[163] := 250;
  cpUni[164] := 241; cpUni[165] := 209; cpUni[166] := 170;
  cpUni[167] := 186; cpUni[168] := 191; cpUni[169] := 8976;
  cpUni[170] := 172; cpUni[171] := 189; cpUni[172] := 188;
  cpUni[173] := 161; cpUni[174] := 171; cpUni[175] := 187;
  cpUni[176] := 9617; cpUni[177] := 9618; cpUni[178] := 9619;
  cpUni[179] := 9474; cpUni[180] := 9508; cpUni[181] := 9569;
  cpUni[182] := 9570; cpUni[183] := 9558; cpUni[184] := 9557;
  cpUni[185] := 9571; cpUni[186] := 9553; cpUni[187] := 9559;
  cpUni[188] := 9565; cpUni[189] := 9564; cpUni[190] := 9563;
  cpUni[191] := 9488; cpUni[192] := 9492; cpUni[193] := 9524;
  cpUni[194] := 9516; cpUni[195] := 9500; cpUni[196] := 9472;
  cpUni[197] := 9532; cpUni[198] := 9566; cpUni[199] := 9567;
  cpUni[200] := 9562; cpUni[201] := 9556; cpUni[202] := 9577;
  cpUni[203] := 9574; cpUni[204] := 9568; cpUni[205] := 9552;
  cpUni[206] := 9580; cpUni[207] := 9575; cpUni[208] := 9576;
  cpUni[209] := 9572; cpUni[210] := 9573; cpUni[211] := 9561;
  cpUni[212] := 9560; cpUni[213] := 9554; cpUni[214] := 9555;
  cpUni[215] := 9579; cpUni[216] := 9578; cpUni[217] := 9496;
  cpUni[218] := 9484; cpUni[219] := 9608; cpUni[220] := 9604;
  cpUni[221] := 9612; cpUni[222] := 9616; cpUni[223] := 9600;
  cpUni[224] := 945; cpUni[225] := 223; cpUni[226] := 915;
  cpUni[227] := 960; cpUni[228] := 931; cpUni[229] := 963;
  cpUni[230] := 181; cpUni[231] := 964; cpUni[232] := 934;
  cpUni[233] := 920; cpUni[234] := 937; cpUni[235] := 948;
  cpUni[236] := 8734; cpUni[237] := 966; cpUni[238] := 949;
  cpUni[239] := 8745; cpUni[240] := 8801; cpUni[241] := 177;
  cpUni[242] := 8805; cpUni[243] := 8804; cpUni[244] := 8992;
  cpUni[245] := 8993; cpUni[246] := 247; cpUni[247] := 8776;
  cpUni[248] := 176; cpUni[249] := 8729; cpUni[250] := 183;
  cpUni[251] := 8730; cpUni[252] := 8319; cpUni[253] := 178;
  cpUni[254] := 9632; cpUni[255] := 160;
END InitCp437;

PROCEDURE InitWP5Sets;
(* WP 5.x character set 1 (multinational) -> Unicode, from libwpd *)
BEGIN
  wp5Multi[0] := 768; wp5Multi[1] := 183; wp5Multi[2] := 771;
  wp5Multi[3] := 770; wp5Multi[4] := 821; wp5Multi[5] := 824;
  wp5Multi[6] := 769; wp5Multi[7] := 776; wp5Multi[8] := 772;
  wp5Multi[9] := 787; wp5Multi[10] := 789; wp5Multi[11] := 700;
  wp5Multi[12] := 806; wp5Multi[13] := 789; wp5Multi[14] := 176;
  wp5Multi[15] := 775; wp5Multi[16] := 779; wp5Multi[17] := 807;
  wp5Multi[18] := 808; wp5Multi[19] := 780; wp5Multi[20] := 823;
  wp5Multi[21] := 773; wp5Multi[22] := 774; wp5Multi[23] := 223;
  wp5Multi[24] := 312; wp5Multi[25] := 106; wp5Multi[26] := 193;
  wp5Multi[27] := 225; wp5Multi[28] := 194; wp5Multi[29] := 226;
  wp5Multi[30] := 196; wp5Multi[31] := 228; wp5Multi[32] := 192;
  wp5Multi[33] := 224; wp5Multi[34] := 197; wp5Multi[35] := 229;
  wp5Multi[36] := 198; wp5Multi[37] := 230; wp5Multi[38] := 199;
  wp5Multi[39] := 231; wp5Multi[40] := 201; wp5Multi[41] := 233;
  wp5Multi[42] := 202; wp5Multi[43] := 234; wp5Multi[44] := 203;
  wp5Multi[45] := 235; wp5Multi[46] := 200; wp5Multi[47] := 232;
  wp5Multi[48] := 205; wp5Multi[49] := 237; wp5Multi[50] := 206;
  wp5Multi[51] := 238; wp5Multi[52] := 207; wp5Multi[53] := 239;
  wp5Multi[54] := 204; wp5Multi[55] := 236; wp5Multi[56] := 209;
  wp5Multi[57] := 241; wp5Multi[58] := 211; wp5Multi[59] := 243;
  wp5Multi[60] := 212; wp5Multi[61] := 244; wp5Multi[62] := 214;
  wp5Multi[63] := 246; wp5Multi[64] := 210; wp5Multi[65] := 242;
  wp5Multi[66] := 218; wp5Multi[67] := 250; wp5Multi[68] := 219;
  wp5Multi[69] := 251; wp5Multi[70] := 220; wp5Multi[71] := 252;
  wp5Multi[72] := 217; wp5Multi[73] := 249; wp5Multi[74] := 376;
  wp5Multi[75] := 255; wp5Multi[76] := 195; wp5Multi[77] := 227;
  wp5Multi[78] := 272; wp5Multi[79] := 273; wp5Multi[80] := 216;
  wp5Multi[81] := 248; wp5Multi[82] := 213; wp5Multi[83] := 245;
  wp5Multi[84] := 221; wp5Multi[85] := 253; wp5Multi[86] := 208;
  wp5Multi[87] := 240; wp5Multi[88] := 222; wp5Multi[89] := 254;
  wp5Multi[90] := 258; wp5Multi[91] := 259; wp5Multi[92] := 256;
  wp5Multi[93] := 257; wp5Multi[94] := 260; wp5Multi[95] := 261;
  wp5Multi[96] := 262; wp5Multi[97] := 263; wp5Multi[98] := 268;
  wp5Multi[99] := 269; wp5Multi[100] := 264; wp5Multi[101] := 265;
  wp5Multi[102] := 266; wp5Multi[103] := 267; wp5Multi[104] := 270;
  wp5Multi[105] := 271; wp5Multi[106] := 282; wp5Multi[107] := 283;
  wp5Multi[108] := 278; wp5Multi[109] := 279; wp5Multi[110] := 274;
  wp5Multi[111] := 275; wp5Multi[112] := 280; wp5Multi[113] := 281;
  wp5Multi[114] := 500; wp5Multi[115] := 501; wp5Multi[116] := 286;
  wp5Multi[117] := 287; wp5Multi[118] := 486; wp5Multi[119] := 487;
  wp5Multi[120] := 290; wp5Multi[121] := 291; wp5Multi[122] := 284;
  wp5Multi[123] := 285; wp5Multi[124] := 288; wp5Multi[125] := 289;
  wp5Multi[126] := 292; wp5Multi[127] := 293; wp5Multi[128] := 294;
  wp5Multi[129] := 295; wp5Multi[130] := 304; wp5Multi[131] := 105;
  wp5Multi[132] := 298; wp5Multi[133] := 299; wp5Multi[134] := 302;
  wp5Multi[135] := 303; wp5Multi[136] := 296; wp5Multi[137] := 297;
  wp5Multi[138] := 306; wp5Multi[139] := 307; wp5Multi[140] := 308;
  wp5Multi[141] := 309; wp5Multi[142] := 310; wp5Multi[143] := 311;
  wp5Multi[144] := 313; wp5Multi[145] := 314; wp5Multi[146] := 317;
  wp5Multi[147] := 318; wp5Multi[148] := 315; wp5Multi[149] := 316;
  wp5Multi[150] := 319; wp5Multi[151] := 320; wp5Multi[152] := 321;
  wp5Multi[153] := 322; wp5Multi[154] := 323; wp5Multi[155] := 324;
  wp5Multi[157] := 329; wp5Multi[158] := 327; wp5Multi[159] := 328;
  wp5Multi[160] := 325; wp5Multi[161] := 326; wp5Multi[162] := 336;
  wp5Multi[163] := 337; wp5Multi[164] := 332; wp5Multi[165] := 333;
  wp5Multi[166] := 338; wp5Multi[167] := 339; wp5Multi[168] := 340;
  wp5Multi[169] := 341; wp5Multi[170] := 344; wp5Multi[171] := 345;
  wp5Multi[172] := 342; wp5Multi[173] := 343; wp5Multi[174] := 346;
  wp5Multi[175] := 347; wp5Multi[176] := 352; wp5Multi[177] := 353;
  wp5Multi[178] := 350; wp5Multi[179] := 351; wp5Multi[180] := 348;
  wp5Multi[181] := 349; wp5Multi[182] := 356; wp5Multi[183] := 357;
  wp5Multi[184] := 354; wp5Multi[185] := 355; wp5Multi[186] := 358;
  wp5Multi[187] := 359; wp5Multi[188] := 364; wp5Multi[189] := 365;
  wp5Multi[190] := 368; wp5Multi[191] := 369; wp5Multi[192] := 362;
  wp5Multi[193] := 363; wp5Multi[194] := 370; wp5Multi[195] := 371;
  wp5Multi[196] := 366; wp5Multi[197] := 367; wp5Multi[198] := 360;
  wp5Multi[199] := 361; wp5Multi[200] := 372; wp5Multi[201] := 373;
  wp5Multi[202] := 374; wp5Multi[203] := 375; wp5Multi[204] := 377;
  wp5Multi[205] := 378; wp5Multi[206] := 381; wp5Multi[207] := 382;
  wp5Multi[208] := 379; wp5Multi[209] := 380; wp5Multi[210] := 330;
  wp5Multi[211] := 331; wp5Multi[226] := 7922; wp5Multi[227] := 7923;
  wp5Multi[228] := 270; wp5Multi[229] := 271; wp5Multi[230] := 416;
  wp5Multi[231] := 417; wp5Multi[232] := 431; wp5Multi[233] := 432;
  wp5Multi[234] := 276; wp5Multi[235] := 277; wp5Multi[236] := 300;
  wp5Multi[237] := 301; wp5Multi[238] := 73; wp5Multi[239] := 305;
  wp5Multi[240] := 334; wp5Multi[241] := 335;

  wp5Box[0] := 9617; wp5Box[1] := 9618; wp5Box[2] := 9619;
  wp5Box[3] := 9608; wp5Box[4] := 9612; wp5Box[5] := 9600;
  wp5Box[6] := 9616; wp5Box[7] := 9604; wp5Box[8] := 9472;
  wp5Box[9] := 9474; wp5Box[10] := 9484; wp5Box[11] := 9488;
  wp5Box[12] := 9496; wp5Box[13] := 9492; wp5Box[14] := 9500;
  wp5Box[15] := 9516; wp5Box[16] := 9508; wp5Box[17] := 9524;
  wp5Box[18] := 9532; wp5Box[19] := 9552; wp5Box[20] := 9553;
  wp5Box[21] := 9556; wp5Box[22] := 9559; wp5Box[23] := 9565;
  wp5Box[24] := 9562; wp5Box[25] := 9568; wp5Box[26] := 9574;
  wp5Box[27] := 9571; wp5Box[28] := 9577; wp5Box[29] := 9580;
  wp5Box[30] := 9554; wp5Box[31] := 9557; wp5Box[32] := 9563;
  wp5Box[33] := 9560; wp5Box[34] := 9555; wp5Box[35] := 9558;
  wp5Box[36] := 9564; wp5Box[37] := 9561; wp5Box[38] := 9566;
  wp5Box[39] := 9573; wp5Box[40] := 9569; wp5Box[41] := 9576;
  wp5Box[42] := 9567; wp5Box[43] := 9572; wp5Box[44] := 9570;
  wp5Box[45] := 9575; wp5Box[46] := 9579; wp5Box[47] := 9578;
  wp5Box[48] := 9588; wp5Box[49] := 9589; wp5Box[50] := 9590;
  wp5Box[51] := 9591; wp5Box[52] := 9592; wp5Box[53] := 9593;
  wp5Box[54] := 9594; wp5Box[55] := 9595; wp5Box[56] := 9596;
  wp5Box[57] := 9598; wp5Box[58] := 9597; wp5Box[59] := 9599;
  wp5Box[60] := 9503; wp5Box[61] := 9506; wp5Box[62] := 9502;
  wp5Box[63] := 9505; wp5Box[64] := 9518; wp5Box[65] := 9522;
  wp5Box[66] := 9517; wp5Box[67] := 9521; wp5Box[68] := 9511;
  wp5Box[69] := 9510; wp5Box[70] := 9514; wp5Box[71] := 9513;
  wp5Box[72] := 9526; wp5Box[73] := 9530; wp5Box[74] := 9525;
  wp5Box[75] := 9529; wp5Box[76] := 9537; wp5Box[77] := 9542;
  wp5Box[78] := 9534; wp5Box[79] := 9536; wp5Box[80] := 9540;
  wp5Box[81] := 9546; wp5Box[82] := 9533; wp5Box[83] := 9541;
  wp5Box[84] := 9544; wp5Box[85] := 9539; wp5Box[86] := 9545;
  wp5Box[87] := 9543;
  wp5Typo[0] := 9679; wp5Typo[1] := 9675; wp5Typo[2] := 9632;
  wp5Typo[3] := 8226; wp5Typo[4] := 42; wp5Typo[5] := 182;
  wp5Typo[6] := 167; wp5Typo[7] := 161; wp5Typo[8] := 191;
  wp5Typo[9] := 171; wp5Typo[10] := 187; wp5Typo[11] := 163;
  wp5Typo[12] := 165; wp5Typo[13] := 8359; wp5Typo[14] := 402;
  wp5Typo[15] := 170; wp5Typo[16] := 186; wp5Typo[17] := 189;
  wp5Typo[18] := 188; wp5Typo[19] := 162; wp5Typo[20] := 178;
  wp5Typo[21] := 8319; wp5Typo[22] := 174; wp5Typo[23] := 169;
  wp5Typo[24] := 164; wp5Typo[25] := 190; wp5Typo[26] := 179;
  wp5Typo[27] := 8219; wp5Typo[28] := 8217; wp5Typo[29] := 8216;
  wp5Typo[30] := 8223; wp5Typo[31] := 8221; wp5Typo[32] := 8220;
  wp5Typo[33] := 8211; wp5Typo[34] := 8212; wp5Typo[35] := 8249;
  wp5Typo[36] := 8250; wp5Typo[37] := 9675; wp5Typo[38] := 9633;
  wp5Typo[39] := 8224; wp5Typo[40] := 8225; wp5Typo[41] := 8482;
  wp5Typo[42] := 8480; wp5Typo[43] := 8478; wp5Typo[44] := 9679;
  wp5Typo[45] := 9702; wp5Typo[46] := 9632; wp5Typo[47] := 9642;
  wp5Typo[48] := 9633; wp5Typo[49] := 9643; wp5Typo[50] := 8210;
  wp5Typo[51] := 64256; wp5Typo[52] := 64259; wp5Typo[53] := 64260;
  wp5Typo[54] := 64257; wp5Typo[55] := 64258; wp5Typo[56] := 8230;
  wp5Typo[57] := 36; wp5Typo[58] := 8355; wp5Typo[59] := 8354;
  wp5Typo[60] := 8352; wp5Typo[61] := 8356; wp5Typo[62] := 8218;
  wp5Typo[63] := 8222; wp5Typo[64] := 8531; wp5Typo[65] := 8532;
  wp5Typo[66] := 8539; wp5Typo[67] := 8540; wp5Typo[68] := 8541;
  wp5Typo[69] := 8542; wp5Typo[70] := 9410; wp5Typo[71] := 9413;
  wp5Typo[72] := 8364; wp5Typo[73] := 8453; wp5Typo[74] := 8454;
  wp5Typo[75] := 8240; wp5Typo[76] := 8470; wp5Typo[77] := 8212;
  wp5Typo[78] := 185; wp5Typo[79] := 9225; wp5Typo[80] := 9228;
  wp5Typo[81] := 9229; wp5Typo[82] := 9226; wp5Typo[83] := 9252;
  wp5Typo[84] := 9227; wp5Typo[85] := 9852; wp5Typo[86] := 8361;
  wp5Typo[87] := 8358; wp5Typo[88] := 8360; wp5Typo[89] := 32;
  wp5Typo[90] := 32; wp5Typo[91] := 32; wp5Typo[92] := 32;
  wp5Typo[93] := 32; wp5Typo[94] := 32; wp5Typo[95] := 32;
  wp5Typo[96] := 32; wp5Typo[97] := 32; wp5Typo[98] := 32;
  wp5Typo[99] := 32; wp5Typo[100] := 119070; wp5Typo[101] := 119074;
END InitWP5Sets;


(* ====================================================================
   String helpers
   ==================================================================== *)

PROCEDURE SLen(s: ARRAY OF CHAR): INTEGER;
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (i < LEN(s)) & (s[i] # 0X) DO INC(i) END;
  RETURN i
END SLen;

PROCEDURE Cpy(src: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (i < LEN(src)) & (src[i] # 0X) & (i < LEN(dst) - 1) DO dst[i] := src[i]; INC(i) END;
  dst[i] := 0X
END Cpy;

PROCEDURE Append(extra: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR);
VAR i, j: INTEGER;
BEGIN
  i := SLen(dst); j := 0;
  WHILE (j < LEN(extra)) & (extra[j] # 0X) & (i < LEN(dst) - 1) DO
    dst[i] := extra[j]; INC(i); INC(j)
  END;
  dst[i] := 0X
END Append;

PROCEDURE AppendCh(c: CHAR; VAR dst: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  i := SLen(dst);
  IF i < LEN(dst) - 1 THEN dst[i] := c; dst[i + 1] := 0X END
END AppendCh;

PROCEDURE IntStr(n: INTEGER; VAR s: ARRAY OF CHAR);
VAR t: ARRAY 24 OF CHAR; i, j: INTEGER; neg: BOOLEAN;
BEGIN
  neg := n < 0; IF neg THEN n := -n END;
  i := 0;
  REPEAT t[i] := CHR(ORD("0") + n MOD 10); n := n DIV 10; INC(i) UNTIL n = 0;
  j := 0;
  IF neg THEN s[0] := "-"; j := 1 END;
  WHILE i > 0 DO DEC(i); IF j < LEN(s) - 1 THEN s[j] := t[i]; INC(j) END END;
  s[j] := 0X
END IntStr;

PROCEDURE AppendInt(n: INTEGER; VAR dst: ARRAY OF CHAR);
VAR t: ARRAY 24 OF CHAR;
BEGIN
  IntStr(n, t); Append(t, dst)
END AppendInt;

PROCEDURE AppendLong(n: LONGINT; VAR dst: ARRAY OF CHAR);
VAR t: ARRAY 32 OF CHAR; i: INTEGER;
BEGIN
  IF n < 0 THEN AppendCh("-", dst); n := -n END;
  i := 0;
  REPEAT t[i] := CHR(ORD("0") + n MOD 10); n := n DIV 10; INC(i) UNTIL n = 0;
  WHILE i > 0 DO DEC(i); AppendCh(t[i], dst) END
END AppendLong;

(* number right-aligned in w columns *)
PROCEDURE AppendIntW(n, w: INTEGER; VAR dst: ARRAY OF CHAR);
VAR t: ARRAY 24 OF CHAR; i: INTEGER;
BEGIN
  IntStr(n, t);
  FOR i := SLen(t) TO w - 1 DO AppendCh(" ", dst) END;
  Append(t, dst)
END AppendIntW;

PROCEDURE PadTo(VAR s: ARRAY OF CHAR; w: INTEGER);
BEGIN
  WHILE SLen(s) < w DO AppendCh(" ", s) END
END PadTo;

PROCEDURE StrInt(s: ARRAY OF CHAR; VAR n: INTEGER): BOOLEAN;
VAR i: INTEGER; neg, any: BOOLEAN;
BEGIN
  i := 0; n := 0; neg := FALSE; any := FALSE;
  WHILE s[i] = " " DO INC(i) END;
  IF s[i] = "-" THEN neg := TRUE; INC(i) ELSIF s[i] = "+" THEN INC(i) END;
  WHILE (s[i] >= "0") & (s[i] <= "9") DO
    n := n * 10 + ORD(s[i]) - ORD("0"); INC(i); any := TRUE
  END;
  WHILE s[i] = " " DO INC(i) END;
  IF neg THEN n := -n END;
  RETURN any & (s[i] = 0X)
END StrInt;

PROCEDURE UpCh(c: CHAR): CHAR;
BEGIN
  IF (c >= "a") & (c <= "z") THEN c := CHR(ORD(c) - 32)
  ELSIF c = 87X THEN c := 80X   (* c cedilla *)
  ELSIF c = 81X THEN c := 9AX   (* u umlaut *)
  ELSIF c = 82X THEN c := 90X   (* e acute *)
  ELSIF c = 84X THEN c := 8EX   (* a umlaut *)
  ELSIF c = 86X THEN c := 8FX
  ELSIF c = 91X THEN c := 92X
  ELSIF c = 94X THEN c := 99X
  ELSIF c = 0A4X THEN c := 0A5X (* n tilde *)
  END;
  RETURN c
END UpCh;

PROCEDURE LoCh(c: CHAR): CHAR;
BEGIN
  IF (c >= "A") & (c <= "Z") THEN c := CHR(ORD(c) + 32)
  ELSIF c = 80X THEN c := 87X
  ELSIF c = 9AX THEN c := 81X
  ELSIF c = 90X THEN c := 82X
  ELSIF c = 8EX THEN c := 84X
  ELSIF c = 8FX THEN c := 86X
  ELSIF c = 92X THEN c := 91X
  ELSIF c = 99X THEN c := 94X
  ELSIF c = 0A5X THEN c := 0A4X
  END;
  RETURN c
END LoCh;

PROCEDURE IsUpper(c: CHAR): BOOLEAN;
BEGIN RETURN LoCh(c) # c
END IsUpper;

PROCEDURE IsLetter(c: CHAR): BOOLEAN;
BEGIN
  RETURN ((c >= "a") & (c <= "z")) OR ((c >= "A") & (c <= "Z")) OR
         ((c >= 80X) & (c <= 0A5X))
END IsLetter;

PROCEDURE IsDigit(c: CHAR): BOOLEAN;
BEGIN RETURN (c >= "0") & (c <= "9")
END IsDigit;

PROCEDURE Upper(VAR s: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  i := 0; WHILE (i < LEN(s)) & (s[i] # 0X) DO s[i] := UpCh(s[i]); INC(i) END
END Upper;

PROCEDURE Lower(VAR s: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  i := 0; WHILE (i < LEN(s)) & (s[i] # 0X) DO s[i] := LoCh(s[i]); INC(i) END
END Lower;

PROCEDURE StrEq(a, b: ARRAY OF CHAR): BOOLEAN;
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (i < LEN(a)) & (i < LEN(b)) & (a[i] # 0X) & (a[i] = b[i]) DO INC(i) END;
  RETURN ((i >= LEN(a)) OR (a[i] = 0X)) & ((i >= LEN(b)) OR (b[i] = 0X))
END StrEq;

PROCEDURE StrEqCI(a, b: ARRAY OF CHAR): BOOLEAN;
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (i < LEN(a)) & (i < LEN(b)) & (a[i] # 0X) & (LoCh(a[i]) = LoCh(b[i])) DO INC(i) END;
  RETURN ((i >= LEN(a)) OR (a[i] = 0X)) & ((i >= LEN(b)) OR (b[i] = 0X))
END StrEqCI;

(* three-way compare, case-insensitive *)
PROCEDURE StrCmpCI(a, b: ARRAY OF CHAR): INTEGER;
VAR i: INTEGER; x, y: CHAR;
BEGIN
  i := 0;
  LOOP
    x := LoCh(a[i]); y := LoCh(b[i]);
    IF x # y THEN
      IF x < y THEN RETURN -1 ELSE RETURN 1 END
    END;
    IF x = 0X THEN RETURN 0 END;
    INC(i)
  END
END StrCmpCI;

PROCEDURE StrCmp(a, b: ARRAY OF CHAR): INTEGER;
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (a[i] = b[i]) & (a[i] # 0X) DO INC(i) END;
  IF a[i] = b[i] THEN RETURN 0 ELSIF a[i] < b[i] THEN RETURN -1 ELSE RETURN 1 END
END StrCmp;

PROCEDURE Trim(VAR s: ARRAY OF CHAR);
VAR i, j, n: INTEGER;
BEGIN
  n := SLen(s);
  WHILE (n > 0) & (s[n - 1] = " ") DO DEC(n) END;
  s[n] := 0X;
  i := 0; WHILE s[i] = " " DO INC(i) END;
  IF i > 0 THEN
    j := 0; WHILE s[i] # 0X DO s[j] := s[i]; INC(i); INC(j) END; s[j] := 0X
  END
END Trim;

(* index of pat in s at or after from, or -1 *)
PROCEDURE Find(pat, s: ARRAY OF CHAR; from: INTEGER): INTEGER;
VAR i, j, n, m: INTEGER;
BEGIN
  n := SLen(s); m := SLen(pat);
  i := from;
  WHILE i + m <= n DO
    j := 0;
    WHILE (j < m) & (s[i + j] = pat[j]) DO INC(j) END;
    IF j = m THEN RETURN i END;
    INC(i)
  END;
  RETURN -1
END Find;

PROCEDURE FindCI(pat, s: ARRAY OF CHAR): INTEGER;
VAR i, j, n, m: INTEGER;
BEGIN
  n := SLen(s); m := SLen(pat);
  i := 0;
  WHILE i + m <= n DO
    j := 0;
    WHILE (j < m) & (LoCh(s[i + j]) = LoCh(pat[j])) DO INC(j) END;
    IF j = m THEN RETURN i END;
    INC(i)
  END;
  RETURN -1
END FindCI;

PROCEDURE Sub(s: ARRAY OF CHAR; pos, len: INTEGER; VAR dst: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (i < len) & (pos + i < LEN(s)) & (s[pos + i] # 0X) & (i < LEN(dst) - 1) DO
    dst[i] := s[pos + i]; INC(i)
  END;
  dst[i] := 0X
END Sub;

(* ---- paths ---- *)

PROCEDURE BaseName(path: ARRAY OF CHAR; VAR name: ARRAY OF CHAR);
VAR i, j: INTEGER;
BEGIN
  i := SLen(path); j := i;
  WHILE (j > 0) & (path[j - 1] # "/") DO DEC(j) END;
  Sub(path, j, i - j, name)
END BaseName;

PROCEDURE DirPart(path: ARRAY OF CHAR; VAR dir: ARRAY OF CHAR);
VAR j: INTEGER;
BEGIN
  j := SLen(path);
  WHILE (j > 0) & (path[j - 1] # "/") DO DEC(j) END;
  IF j = 0 THEN dir[0] := 0X
  ELSIF j = 1 THEN Cpy("/", dir)
  ELSE Sub(path, 0, j - 1, dir)
  END
END DirPart;

(* out may be the same variable as dir or name *)
PROCEDURE JoinPath(dir, name: ARRAY OF CHAR; VAR out: ARRAY OF CHAR);
VAR d, n: Path;
BEGIN
  Cpy(dir, d); Cpy(name, n);
  IF (n[0] = "/") OR (d[0] = 0X) THEN Cpy(n, out)
  ELSE
    Cpy(d, out);
    IF out[SLen(out) - 1] # "/" THEN AppendCh("/", out) END;
    Append(n, out)
  END
END JoinPath;

(* extension (without dot), lower case *)
PROCEDURE ExtOf(path: ARRAY OF CHAR; VAR ext: ARRAY OF CHAR);
VAR b: Path; i: INTEGER;
BEGIN
  BaseName(path, b);
  i := SLen(b);
  WHILE (i > 0) & (b[i - 1] # ".") DO DEC(i) END;
  IF i = 0 THEN ext[0] := 0X ELSE Sub(b, i, 20, ext); Lower(ext) END
END ExtOf;

(* a file name relative to the current directory becomes absolute *)
PROCEDURE FullPath(name: ARRAY OF CHAR; VAR out: ARRAY OF CHAR);
VAR home: Path; t: Path;
BEGIN
  IF (name[0] = "~") & (name[1] = "/") THEN
    Args.GetEnv("HOME", home); Sub(name, 2, MaxPath, t); JoinPath(home, t, out)
  ELSE
    Cpy(name, t); OS.GetCwd(cwd); JoinPath(cwd, t, out)
  END
END FullPath;

PROCEDURE Exists(name: ARRAY OF CHAR): BOOLEAN;
BEGIN RETURN Files.Exists(name)
END Exists;

(* ====================================================================
   Characters: IBM code page 437 <-> Unicode <-> UTF-8
   ==================================================================== *)

PROCEDURE CpToUni(c: CHAR): INTEGER;
BEGIN
  IF ORD(c) < 128 THEN RETURN ORD(c) ELSE RETURN cpUni[ORD(c)] END
END CpToUni;

(* Unicode -> CP437 byte, or -1 *)
PROCEDURE UniToCp(u: INTEGER): INTEGER;
VAR i: INTEGER;
BEGIN
  IF (u >= 32) & (u < 127) THEN RETURN u END;
  FOR i := 128 TO 255 DO IF cpUni[i] = u THEN RETURN i END END;
  (* a few look-alikes *)
  IF (u = 2018H) OR (u = 2019H) THEN RETURN ORD("'")
  ELSIF (u = 201CH) OR (u = 201DH) THEN RETURN ORD(22X)
  ELSIF (u = 2013H) OR (u = 2014H) THEN RETURN ORD("-")
  ELSIF u = 2026H THEN RETURN ORD(".")
  ELSIF u = 0A0H THEN RETURN ORD(" ")
  END;
  RETURN -1
END UniToCp;

PROCEDURE Utf8(u: INTEGER; VAR b: ARRAY OF CHAR): INTEGER;
BEGIN
  IF u < 80H THEN b[0] := CHR(u); RETURN 1
  ELSIF u < 800H THEN
    b[0] := CHR(0C0H + u DIV 64); b[1] := CHR(80H + u MOD 64); RETURN 2
  ELSIF u < 10000H THEN
    b[0] := CHR(0E0H + u DIV 4096); b[1] := CHR(80H + (u DIV 64) MOD 64);
    b[2] := CHR(80H + u MOD 64); RETURN 3
  ELSE
    b[0] := CHR(0F0H + u DIV 262144); b[1] := CHR(80H + (u DIV 4096) MOD 64);
    b[2] := CHR(80H + (u DIV 64) MOD 64); b[3] := CHR(80H + u MOD 64); RETURN 4
  END
END Utf8;

(* CP437 string -> UTF-8 *)
PROCEDURE ToUtf8(src: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR);
VAR i, j, n, k: INTEGER; b: ARRAY 4 OF CHAR;
BEGIN
  i := 0; j := 0;
  WHILE (i < LEN(src)) & (src[i] # 0X) DO
    n := Utf8(CpToUni(src[i]), b);
    IF j + n < LEN(dst) THEN FOR k := 0 TO n - 1 DO dst[j] := b[k]; INC(j) END END;
    INC(i)
  END;
  dst[j] := 0X
END ToUtf8;

(* UTF-8 string -> CP437 (unknown characters become "?") *)
PROCEDURE FromUtf8(src0: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR);
VAR i, j, u, c, need: INTEGER; src: ARRAY 1024 OF CHAR;
BEGIN
  Cpy(src0, src);
  i := 0; j := 0;
  WHILE (i < LEN(src)) & (src[i] # 0X) & (j < LEN(dst) - 1) DO
    c := ORD(src[i]); INC(i);
    IF c < 80H THEN u := c; need := 0
    ELSIF c >= 0F0H THEN u := c MOD 8; need := 3
    ELSIF c >= 0E0H THEN u := c MOD 16; need := 2
    ELSIF c >= 0C0H THEN u := c MOD 32; need := 1
    ELSE u := 3FH; need := 0
    END;
    WHILE (need > 0) & (i < LEN(src)) & (ORD(src[i]) >= 80H) & (ORD(src[i]) < 0C0H) DO
      u := u * 64 + ORD(src[i]) MOD 64; INC(i); DEC(need)
    END;
    c := UniToCp(u);
    IF c < 0 THEN c := ORD("?") END;
    dst[j] := CHR(c); INC(j)
  END;
  dst[j] := 0X
END FromUtf8;

(* ====================================================================
   Dates in WordPerfect's date format language
     1 day  2 month  3 month name  4 year  5 yy  6 weekday  7 hour(24)
     8 hour(12)  9 minute  0 am/pm   % before a number: leading zero
   ==================================================================== *)

PROCEDURE TimePart(f: ARRAY OF CHAR; VAR n: INTEGER);
VAR s: Str;
BEGIN
  Time.Format(Time.Now(), f, s);
  IF ~StrInt(s, n) THEN n := 0 END
END TimePart;

PROCEDURE FormatDate(fmt: ARRAY OF CHAR; VAR out: ARRAY OF CHAR);
VAR i, n: INTEGER; lead: BOOLEAN; s: Str; c: CHAR;

  PROCEDURE Num(VAR out: ARRAY OF CHAR; n: INTEGER; lead: BOOLEAN);
  BEGIN
    IF lead & (n < 10) THEN AppendCh("0", out) END;
    AppendInt(n, out)
  END Num;

BEGIN
  out[0] := 0X; i := 0; lead := FALSE;
  WHILE (i < LEN(fmt)) & (fmt[i] # 0X) DO
    c := fmt[i];
    IF c = "%" THEN lead := TRUE
    ELSE
      IF c = "1" THEN TimePart("%d", n); Num(out, n, lead)
      ELSIF c = "2" THEN TimePart("%m", n); Num(out, n, lead)
      ELSIF c = "3" THEN Time.Format(Time.Now(), "%B", s); Append(s, out)
      ELSIF c = "4" THEN Time.Format(Time.Now(), "%Y", s); Append(s, out)
      ELSIF c = "5" THEN Time.Format(Time.Now(), "%y", s); Append(s, out)
      ELSIF c = "6" THEN Time.Format(Time.Now(), "%A", s); Append(s, out)
      ELSIF c = "7" THEN TimePart("%H", n); Num(out, n, lead)
      ELSIF c = "8" THEN TimePart("%I", n); Num(out, n, lead)
      ELSIF c = "9" THEN TimePart("%M", n); Num(out, n, TRUE)
      ELSIF c = "0" THEN Time.Format(Time.Now(), "%p", s); Lower(s); Append(s, out)
      ELSE AppendCh(c, out)
      END;
      lead := FALSE
    END;
    INC(i)
  END
END FormatDate;

PROCEDURE Roman(n: INTEGER; VAR s: ARRAY OF CHAR);
VAR v: ARRAY 13 OF INTEGER; i: INTEGER;
  PROCEDURE Sym(i: INTEGER; VAR s: ARRAY OF CHAR);
  BEGIN
    CASE i OF
      0: Append("m", s) | 1: Append("cm", s) | 2: Append("d", s) | 3: Append("cd", s)
    | 4: Append("c", s) | 5: Append("xc", s) | 6: Append("l", s) | 7: Append("xl", s)
    | 8: Append("x", s) | 9: Append("ix", s) | 10: Append("v", s) | 11: Append("iv", s)
    | 12: Append("i", s)
    END
  END Sym;
BEGIN
  v[0] := 1000; v[1] := 900; v[2] := 500; v[3] := 400; v[4] := 100; v[5] := 90;
  v[6] := 50; v[7] := 40; v[8] := 10; v[9] := 9; v[10] := 5; v[11] := 4; v[12] := 1;
  s[0] := 0X;
  IF n <= 0 THEN AppendInt(n, s) ELSE
    FOR i := 0 TO 12 DO WHILE n >= v[i] DO Sym(i, s); n := n - v[i] END END
  END
END Roman;

(* ====================================================================
   The document: a stream of items (characters and codes)
   ==================================================================== *)

PROCEDURE NewDoc(): Doc;
VAR d: Doc;
BEGIN
  NEW(d); d.cap := 64; NEW(d.it, d.cap); d.n := 0;
  RETURN d
END NewDoc;

PROCEDURE Grow(d: Doc; need: INTEGER);
VAR nit: Items; i, nc: INTEGER;
BEGIN
  IF need > d.cap THEN
    nc := d.cap * 2; IF nc < need THEN nc := need + 64 END;
    NEW(nit, nc);
    FOR i := 0 TO d.n - 1 DO nit[i] := d.it[i] END;
    d.it := nit; d.cap := nc
  END
END Grow;

PROCEDURE ClearItem(VAR x: Item);
BEGIN
  x.k := kChar; x.a := 0; x.b := 0; x.c := 0; x.ch := " ";
  x.s := NIL; x.sl := 0; x.sub := NIL
END ClearItem;

PROCEDURE NewBytes(n: INTEGER): Bytes;
VAR b: Bytes;
BEGIN
  IF n < 1 THEN n := 1 END;
  NEW(b, n); RETURN b
END NewBytes;

(* store a 0X-terminated string as the item payload *)
PROCEDURE SetStr(VAR x: Item; s: ARRAY OF CHAR);
VAR i, n: INTEGER;
BEGIN
  n := SLen(s);
  x.s := NewBytes(n + 1); x.sl := n;
  FOR i := 0 TO n - 1 DO x.s[i] := s[i] END;
  x.s[n] := 0X
END SetStr;

PROCEDURE GetStr(VAR x: Item; VAR s: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  i := 0;
  IF x.s # NIL THEN
    WHILE (i < x.sl) & (x.s[i] # 0X) & (i < LEN(s) - 1) DO s[i] := x.s[i]; INC(i) END
  END;
  s[i] := 0X
END GetStr;

PROCEDURE CopyDoc(src: Doc): Doc;
VAR d: Doc; i: INTEGER;
BEGIN
  d := NewDoc();
  IF src # NIL THEN
    Grow(d, src.n);
    FOR i := 0 TO src.n - 1 DO CopyItemInto(src.it[i], d.it[i]) END;
    d.n := src.n
  END;
  RETURN d
END CopyDoc;

(* deep copy: payload bytes and sub-documents are duplicated *)
PROCEDURE CopyItemInto(VAR src: Item; VAR dst: Item);
VAR i: INTEGER;
BEGIN
  dst := src;
  IF src.s # NIL THEN
    dst.s := NewBytes(src.sl + 1);
    FOR i := 0 TO src.sl - 1 DO dst.s[i] := src.s[i] END;
    dst.s[src.sl] := 0X
  END;
  IF src.sub # NIL THEN dst.sub := CopyDoc(src.sub) END
END CopyItemInto;

PROCEDURE InsItem(d: Doc; pos: INTEGER; VAR x: Item);
VAR i: INTEGER;
BEGIN
  Grow(d, d.n + 1);
  i := d.n;
  WHILE i > pos DO d.it[i] := d.it[i - 1]; DEC(i) END;
  d.it[pos] := x;
  INC(d.n)
END InsItem;

PROCEDURE DelItems(d: Doc; pos, cnt: INTEGER);
VAR i: INTEGER;
BEGIN
  IF cnt <= 0 THEN RETURN END;
  IF pos + cnt > d.n THEN cnt := d.n - pos END;
  FOR i := pos TO d.n - cnt - 1 DO d.it[i] := d.it[i + cnt] END;
  d.n := d.n - cnt
END DelItems;

(* copy items from..to-1 into a new document *)
PROCEDURE CopyRange(d: Doc; from, to: INTEGER): Doc;
VAR r: Doc; i: INTEGER;
BEGIN
  r := NewDoc();
  IF from < 0 THEN from := 0 END;
  IF to > d.n THEN to := d.n END;
  IF to > from THEN
    Grow(r, to - from);
    FOR i := from TO to - 1 DO CopyItemInto(d.it[i], r.it[i - from]) END;
    r.n := to - from
  END;
  RETURN r
END CopyRange;

(* insert a copy of src at pos; returns the number of items inserted *)
PROCEDURE InsDoc(d: Doc; pos: INTEGER; src: Doc): INTEGER;
VAR i, n: INTEGER;
BEGIN
  IF (src = NIL) OR (src.n = 0) THEN RETURN 0 END;
  n := src.n;
  Grow(d, d.n + n);
  i := d.n - 1;
  WHILE i >= pos DO d.it[i + n] := d.it[i]; DEC(i) END;
  FOR i := 0 TO n - 1 DO CopyItemInto(src.it[i], d.it[pos + i]) END;
  d.n := d.n + n;
  RETURN n
END InsDoc;

PROCEDURE AddItem(d: Doc; VAR x: Item);
BEGIN
  Grow(d, d.n + 1); d.it[d.n] := x; INC(d.n)
END AddItem;

PROCEDURE AddK(d: Doc; k, a, b, c: INTEGER);
VAR x: Item;
BEGIN
  ClearItem(x); x.k := k; x.a := a; x.b := b; x.c := c; AddItem(d, x)
END AddK;

PROCEDURE AddCh(d: Doc; ch: CHAR);
VAR x: Item;
BEGIN
  ClearItem(x);
  IF (ORD(ch) < 32) & (ch # 09X) THEN x.k := kCtl ELSE x.k := kChar END;
  x.ch := ch; AddItem(d, x)
END AddCh;

PROCEDURE AddStr(d: Doc; s: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (i < LEN(s)) & (s[i] # 0X) DO
    IF s[i] = 0AX THEN AddK(d, kHRt, 0, 0, 0) ELSE AddCh(d, s[i]) END;
    INC(i)
  END
END AddStr;

PROCEDURE MkItem(k, a, b, c: INTEGER; VAR x: Item);
BEGIN
  ClearItem(x); x.k := k; x.a := a; x.b := b; x.c := c
END MkItem;

PROCEDURE IsChar(VAR x: Item): BOOLEAN;
BEGIN RETURN x.k = kChar
END IsChar;

(* plain text of a document (codes dropped, hard returns as 0AX) *)
PROCEDURE DocText(d: Doc; VAR s: ARRAY OF CHAR);
VAR i, j: INTEGER;
BEGIN
  j := 0;
  IF d # NIL THEN
    FOR i := 0 TO d.n - 1 DO
      IF j < LEN(s) - 1 THEN
        IF d.it[i].k = kChar THEN s[j] := d.it[i].ch; INC(j)
        ELSIF d.it[i].k = kHRt THEN s[j] := 0AX; INC(j)
        ELSIF d.it[i].k = kTab THEN s[j] := " "; INC(j)
        ELSIF (d.it[i].k = kSingle) & (d.it[i].a = fHardSp) THEN s[j] := " "; INC(j)
        ELSIF (d.it[i].k = kSingle) & (d.it[i].a = fHardHy) THEN s[j] := "-"; INC(j)
        END
      END
    END
  END;
  s[j] := 0X
END DocText;

PROCEDURE CountLines(d: Doc): INTEGER;
VAR i, n: INTEGER;
BEGIN
  n := 1;
  IF d # NIL THEN
    FOR i := 0 TO d.n - 1 DO IF d.it[i].k = kHRt THEN INC(n) END END;
    IF (d.n > 0) & (d.it[d.n - 1].k = kHRt) THEN DEC(n) END
  END;
  RETURN n
END CountLines;

(* ====================================================================
   Format defaults and tab tables
   ==================================================================== *)

PROCEDURE DefaultNoteOpt(VAR o: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO NoteLen - 1 DO o[i] := 0X END;
  o[0] := 1X;      (* spacing in footnotes *)
  o[1] := 1X;      (* spacing between footnotes *)
  o[2] := 3X;      (* lines to keep together *)
  o[3] := 0A0X;    (* footnotes at bottom of page, 2" separator line *)
  o[4] := 1X; o[5] := "*"
END DefaultNoteOpt;

PROCEDURE InitFmt(VAR f: Fmt);
VAR i: INTEGER;
BEGIN
  f.lm := 10; f.rm := 74; f.spacing := 2; f.alignCh := ORD(".");
  FOR i := 0 TO 255 DO
    IF (i MOD 5 = 0) & (i <= 250) THEN f.tabs[i] := 1X ELSE f.tabs[i] := 0X END
  END;
  f.just := TRUE; f.widow := FALSE; f.hyph := FALSE; f.mathOn := FALSE;
  f.hzL := 7; f.hzR := 0;
  f.pnPos := 0; f.pnL := 10; f.pnC := 42; f.pnR := 74;
  f.topMar := 12; f.formLen := 66; f.textHalf := 108; f.lpi := 6;
  f.pitch := 10; f.font := 1; f.undMode := 2; f.bin := 1;
  f.lineNum := 0; f.lnPos := 6; f.attr := 0;
  FOR i := 0 TO 3 DO f.hdr[i] := NIL; f.hdrOcc[i] := 0; f.hdrLm[i] := 10; f.hdrRm[i] := 74 END;
  DefaultNoteOpt(f.noteOpt)
END InitFmt;

(* tab table <-> the 52 bytes of a WP 4.2 Tab Reset function:
   32 bytes of position bits (position 0 = high bit of byte 0), then 20
   bytes of type nibbles, high nibble first, one per tab that is set *)
PROCEDURE TabsToBytes(VAR f: Fmt; VAR b: ARRAY OF CHAR);
VAR i, n, t, byte: INTEGER;
BEGIN
  FOR i := 0 TO 51 DO b[i] := 0X END;
  n := 0;
  FOR i := 0 TO 250 DO
    IF f.tabs[i] # 0X THEN
      byte := ORD(b[i DIV 8]) + LSL(1, 7 - i MOD 8);
      b[i DIV 8] := CHR(byte);
      t := ORD(f.tabs[i]) - 1;
      IF n < 40 THEN
        IF n MOD 2 = 0 THEN b[32 + n DIV 2] := CHR(ORD(b[32 + n DIV 2]) + t * 16)
        ELSE b[32 + n DIV 2] := CHR(ORD(b[32 + n DIV 2]) + t)
        END
      END;
      INC(n)
    END
  END
END TabsToBytes;

PROCEDURE BytesToTabs(VAR b: ARRAY OF CHAR; off: INTEGER; VAR f: Fmt);
VAR i, n, t: INTEGER;
BEGIN
  n := 0;
  FOR i := 0 TO 255 DO f.tabs[i] := 0X END;
  FOR i := 0 TO 250 DO
    IF ODD(ASR(ORD(b[off + i DIV 8]), 7 - i MOD 8)) THEN
      t := 0;
      IF n < 40 THEN
        IF n MOD 2 = 0 THEN t := ORD(b[off + 32 + n DIV 2]) DIV 16
        ELSE t := ORD(b[off + 32 + n DIV 2]) MOD 16
        END
      END;
      IF t > 7 THEN t := 0 END;
      f.tabs[i] := CHR(t + 1);
      INC(n)
    END
  END
END BytesToTabs;

(* ====================================================================
   Byte buffers: file loading and an output buffer
   ==================================================================== *)

VAR
  ob: Bytes; obLen, obCap: INTEGER;      (* output buffer *)

PROCEDURE ObReset;
BEGIN
  IF ob = NIL THEN obCap := 65536; ob := NewBytes(obCap) END;
  obLen := 0
END ObReset;

PROCEDURE Put(b: INTEGER);
VAR nb: Bytes; i: INTEGER;
BEGIN
  IF obLen >= obCap THEN
    nb := NewBytes(obCap * 2);
    FOR i := 0 TO obLen - 1 DO nb[i] := ob[i] END;
    ob := nb; obCap := obCap * 2
  END;
  ob[obLen] := CHR(b MOD 256); INC(obLen)
END Put;

PROCEDURE PutStr(s: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  i := 0; WHILE (i < LEN(s)) & (s[i] # 0X) DO Put(ORD(s[i])); INC(i) END
END PutStr;

PROCEDURE PutW(v: INTEGER);    (* 16-bit little-endian *)
BEGIN Put(v MOD 256); Put((v DIV 256) MOD 256)
END PutW;

PROCEDURE PutUtf8(c: CHAR);
VAR b: ARRAY 4 OF CHAR; n, i: INTEGER;
BEGIN
  n := Utf8(CpToUni(c), b);
  FOR i := 0 TO n - 1 DO Put(ORD(b[i])) END
END PutUtf8;

PROCEDURE WriteOb(name: ARRAY OF CHAR): BOOLEAN;
VAR f: Files.File; r: Files.Rider; i: INTEGER;
BEGIN
  f := Files.New(name);
  IF f = NIL THEN RETURN FALSE END;
  Files.Set(r, f, 0);
  FOR i := 0 TO obLen - 1 DO Files.Write(r, ob[i]) END;
  Files.Register(f); Files.Close(f);
  RETURN TRUE
END WriteOb;

PROCEDURE LoadFile(name: ARRAY OF CHAR; VAR buf: Bytes; VAR len: INTEGER): BOOLEAN;
VAR f: Files.File; r: Files.Rider; c: CHAR; n: INTEGER;
BEGIN
  IF ~Files.Exists(name) THEN RETURN FALSE END;
  f := Files.Old(name);
  IF f = NIL THEN RETURN FALSE END;
  n := Files.Length(f);
  buf := NewBytes(n + 1);
  Files.Set(r, f, 0); len := 0;
  Files.Read(r, c);
  WHILE ~r.eof & (len < n) DO buf[len] := c; INC(len); Files.Read(r, c) END;
  Files.Close(f);
  RETURN TRUE
END LoadFile;

(* ====================================================================
   WordPerfect 4.2 reader
   ==================================================================== *)

(* size of the multi-byte functions C0h..FEh (-1 = variable length) *)
PROCEDURE GroupSize(code: INTEGER): INTEGER;
BEGIN
  CASE code OF
    0C0H: RETURN 6 | 0C1H: RETURN 4 | 0C2H: RETURN 3 | 0C3H: RETURN 5
  | 0C4H: RETURN 5 | 0C5H: RETURN 6 | 0C6H: RETURN 4 | 0C7H: RETURN 6
  | 0C8H: RETURN 8 | 0C9H: RETURN 42 | 0CAH: RETURN 3 | 0CBH: RETURN 6
  | 0CCH: RETURN 4 | 0CDH: RETURN 3 | 0CEH: RETURN 4 | 0CFH: RETURN 3
  | 0D0H: RETURN 6 | 0D3H: RETURN 4 | 0D4H: RETURN 4 | 0D5H: RETURN 4
  | 0D6H: RETURN 6 | 0D8H: RETURN 4 | 0D9H: RETURN 4 | 0DAH: RETURN 4
  | 0DBH: RETURN 4 | 0DDH: RETURN 24 | 0DEH: RETURN 4 | 0E0H: RETURN 4
  | 0E1H: RETURN 3 | 0E3H: RETURN 150 | 0E4H: RETURN 6 | 0E5H: RETURN 23
  | 0E6H: RETURN 11 | 0E7H: RETURN 3 | 0E8H: RETURN 3 | 0ECH: RETURN 4
  | 0EEH: RETURN 44 | 0EFH: RETURN 18 | 0F0H: RETURN 6 | 0F1H: RETURN 106
  | 0F3H: RETURN 100 | 0F4H: RETURN 4 | 0F6H: RETURN 5
  ELSE RETURN -1
  END
END GroupSize;

PROCEDURE B(VAR buf: ARRAY OF CHAR; p: INTEGER): INTEGER;
BEGIN RETURN ORD(buf[p])
END B;

PROCEDURE RawItem(VAR buf: ARRAY OF CHAR; p, n, k: INTEGER; VAR x: Item);
VAR i: INTEGER;
BEGIN
  ClearItem(x); x.k := k; x.a := B(buf, p);
  x.s := NewBytes(n + 1); x.sl := n;
  FOR i := 0 TO n - 1 DO x.s[i] := buf[p + i] END
END RawItem;

(* find the closing gate of a variable-length function opened at p *)
PROCEDURE CloseGate(VAR buf: ARRAY OF CHAR; p, end: INTEGER): INTEGER;
VAR q: INTEGER;
BEGIN
  q := p + 1;
  WHILE (q < end) & (buf[q] # buf[p]) DO INC(q) END;
  RETURN q
END CloseGate;

PROCEDURE Map42Single(c: INTEGER; VAR x: Item): BOOLEAN;
BEGIN
  ClearItem(x);
  CASE c OF
    fBoldOn: x.k := kAttrOn; x.a := aBold | fBoldOff: x.k := kAttrOff; x.a := aBold
  | fUndOn: x.k := kAttrOn; x.a := aUnd | fUndOff: x.k := kAttrOff; x.a := aUnd
  | fRedOn: x.k := kAttrOn; x.a := aRed | fRedOff: x.k := kAttrOff; x.a := aRed
  | fStrkOn: x.k := kAttrOn; x.a := aStrike | fStrkOff: x.k := kAttrOff; x.a := aStrike
  | fItalOn: x.k := kAttrOn; x.a := aItal | fItalOff: x.k := kAttrOff; x.a := aItal
  | fShadOn: x.k := kAttrOn; x.a := aShadow | fShadOff: x.k := kAttrOff; x.a := aShadow
  | fOutlOn: x.k := kAttrOn; x.a := aOutline | fOutlOff: x.k := kAttrOff; x.a := aOutline
  | fRevOn: x.k := kAttrOn; x.a := aRev | fRevOff: x.k := kAttrOff; x.a := aRev
  | fEndCenter: x.k := kEndCenter
  | fEndAlign: x.k := kEndAlign
  | fHRtSPg: x.k := kHRt
  | fTabRM: x.k := kTab
  | 80H: RETURN FALSE                       (* no-op, always deleted *)
  | 0AAH, 0ABH: x.k := kSingle; x.a := fHardHy
  | 0ADH, 0AEH: x.k := kSingle; x.a := fSoftHy
  ELSE x.k := kSingle; x.a := c
  END;
  RETURN TRUE
END Map42Single;

(* Parse WP 4.2 bytes buf[p..end) into d.  Stops at a byte equal to term
   (when term >= 0) found at the top level; p is left on it. *)
PROCEDURE Parse42(VAR buf: ARRAY OF CHAR; VAR p: INTEGER; end, term: INTEGER; d: Doc);
VAR c, sz, q, i, n, hi, lo: INTEGER; x: Item; f: Fmt;
BEGIN
  WHILE p < end DO
    c := B(buf, p);
    IF (term >= 0) & (c = term) THEN RETURN END;
    IF c < 20H THEN
      IF c = 09H THEN AddK(d, kTab, 0, 0, 0)
      ELSIF c = 0AH THEN AddK(d, kHRt, 0, 0, 0)
      ELSIF (c = 0BH) OR (c = 0DH) THEN AddCh(d, " ")
      ELSIF c = 0CH THEN AddK(d, kHPg, 0, 0, 0)
      ELSIF c # 0 THEN AddCh(d, CHR(c))
      END;
      INC(p)
    ELSIF c < 80H THEN AddCh(d, CHR(c)); INC(p)
    ELSIF c < 0C0H THEN
      IF Map42Single(c, x) THEN AddItem(d, x) END;
      INC(p)
    ELSIF c = 0FFH THEN INC(p)
    ELSE
      sz := GroupSize(c);
      IF sz > 0 THEN
        IF (p + sz > end) OR (B(buf, p + sz - 1) # c) THEN
          INC(p)      (* not a valid group: skip the byte *)
        ELSE
          ClearItem(x);
          CASE c OF
            0C0H: x.k := kMargin; x.a := B(buf, p + 3); x.b := B(buf, p + 4)
          | 0C1H: x.k := kSpacing; x.a := B(buf, p + 2)
          | 0C2H: x.k := kMarRel; x.a := B(buf, p + 1)
          | 0C3H: x.k := kCenter; x.a := B(buf, p + 1); x.b := B(buf, p + 2); x.c := B(buf, p + 3)
          | 0C4H: x.k := kAlign; x.a := B(buf, p + 1) MOD 128; x.b := B(buf, p + 2);
                  IF B(buf, p + 1) >= 128 THEN x.c := 1 END
          | 0C5H: x.k := kHZone; x.a := B(buf, p + 3); x.b := B(buf, p + 4)
          | 0C6H: x.k := kPnPos; x.a := B(buf, p + 2)
          | 0C7H: x.k := kPgNum; hi := B(buf, p + 3); lo := B(buf, p + 4);
                  x.a := (hi MOD 128) * 256 + lo; IF hi >= 128 THEN x.b := 1 END
          | 0C8H: x.k := kPnCol; x.a := B(buf, p + 4); x.b := B(buf, p + 5); x.c := B(buf, p + 6)
          | 0C9H: (* old 160-position tab table *)
                  x.k := kTabSet; FOR i := 0 TO 255 DO f.tabs[i] := 0X END;
                  FOR i := 0 TO 159 DO
                    IF ODD(ASR(B(buf, p + 21 + i DIV 8), 7 - i MOD 8)) THEN f.tabs[i] := 1X END
                  END;
                  x.s := NewBytes(52); x.sl := 52; TabsToBytes(f, x.s^)
          | 0CAH: x.k := kCondEOP; x.a := B(buf, p + 1)
          | 0CBH: x.k := kFont; x.a := B(buf, p + 3); IF x.a >= 128 THEN x.a := x.a - 256 END;
                  x.b := B(buf, p + 4)
          | 0CCH: x.k := kIndent; x.a := B(buf, p + 2)
          | 0CEH: x.k := kTopMar; x.a := B(buf, p + 2)
          | 0CFH: x.k := kSuppress; x.a := B(buf, p + 1)
          | 0D0H: x.k := kFormLen; x.a := B(buf, p + 3); x.b := B(buf, p + 4)
          | 0D4H: x.k := kAdvLn; x.a := B(buf, p + 2)
          | 0D5H: x.k := kLPI; x.a := B(buf, p + 2)
          | 0D8H: x.k := kAlignChar; x.a := B(buf, p + 2)
          | 0DAH: x.k := kUndMode; x.a := B(buf, p + 2)
          | 0DBH: x.k := kBin; x.a := B(buf, p + 2) + 1
          | 0E0H: x.k := kLRIndent; x.a := B(buf, p + 2)
          | 0E1H: x.k := kChar; x.ch := buf[p + 1];
                  IF ORD(x.ch) < 20H THEN x.ch := "?" END
          | 0E3H: x.k := kNoteOpt; x.s := NewBytes(NoteLen); x.sl := NoteLen;
                  FOR i := 0 TO NoteLen - 1 DO x.s[i] := buf[p + 1 + NoteLen + i] END
          | 0E4H: x.k := kNoteNum; x.a := B(buf, p + 3) * 128 + B(buf, p + 4)
          | 0E7H: x.k := kMark; x.a := 1; x.b := B(buf, p + 1)
          | 0E8H: x.k := kMark; x.a := 0; x.b := B(buf, p + 1)
          | 0ECH: x.k := kBlockPro; x.a := B(buf, p + 1); x.b := B(buf, p + 2)
          | 0F0H: x.k := kLineNum; x.a := B(buf, p + 3); x.b := B(buf, p + 4)
          | 0F1H: x.k := kTabSet; x.s := NewBytes(52); x.sl := 52;
                  FOR i := 0 TO 51 DO x.s[i] := buf[p + 53 + i] END
          | 0CDH, 0D3H, 0D9H: x.k := -1     (* obsolete; dropped *)
          ELSE RawItem(buf, p, sz, kRaw, x)
          END;
          IF x.k >= 0 THEN AddItem(d, x) END;
          p := p + sz
        END
      ELSE
        (* variable-length functions *)
        ClearItem(x);
        IF c = 0D1H THEN
          (* header/footer: D1 olddef oldhl FF FF lm rm text FF hl def D1 *)
          x.k := kHdrFtr; x.b := B(buf, p + 5); x.c := B(buf, p + 6);
          x.sub := NewDoc();
          q := p + 7; Parse42(buf, q, end, 0FFH, x.sub);
          x.a := B(buf, q + 2);
          p := q + 4;
          AddItem(d, x)
        ELSIF c = 0E2H THEN
          (* footnote/endnote *)
          x.k := kNote; x.a := B(buf, p + 1);
          IF ~ODD(x.a) THEN x.b := B(buf, p + 2) * 128 + B(buf, p + 3) ELSE x.b := 0 END;
          q := p + 6;
          WHILE (q < end) & (B(buf, q) # 0FFH) DO INC(q) END;
          q := q + 3;
          x.sub := NewDoc();
          Parse42(buf, q, end, 0E2H, x.sub);
          p := q + 1;
          AddItem(d, x)
        ELSIF c = 0F2H THEN
          (* comment or document summary *)
          x.k := kComment; x.a := B(buf, p + 1) MOD 2;
          q := p + 5; x.sub := NewDoc();
          Parse42(buf, q, end, 0F2H, x.sub);
          p := q + 1;
          AddItem(d, x)
        ELSIF c = 0DFH THEN
          (* printer command, 7-bit with BF escape *)
          q := CloseGate(buf, p, end);
          x.k := kPrnCmd; x.s := NewBytes(q - p + 1); n := 0; i := p + 1;
          WHILE i < q DO
            IF (B(buf, i) = 0BFH) & (i + 1 < q) THEN x.s[n] := CHR(B(buf, i + 1) + 0BFH); INC(i)
            ELSE x.s[n] := buf[i]
            END;
            INC(n); INC(i)
          END;
          x.s[n] := 0X; x.sl := n;
          AddItem(d, x); p := q + 1
        ELSIF c = 0EBH THEN
          (* date/time function: 30-byte format *)
          q := CloseGate(buf, p, end);
          x.k := kDate; x.s := NewBytes(32); n := 0;
          WHILE (p + 1 + n < q) & (n < 30) & (buf[p + 1 + n] # 0X) DO x.s[n] := buf[p + 1 + n]; INC(n) END;
          x.s[n] := 0X; x.sl := n;
          AddItem(d, x); p := q + 1
        ELSIF c = 0D7H THEN
          q := CloseGate(buf, p, end);
          RawItem(buf, p, q - p + 1, kMathDef, x); AddItem(d, x); p := q + 1
        ELSIF c = 0DCH THEN
          p := CloseGate(buf, p, end) + 1      (* end of page: WordPerfect regenerates it *)
        ELSE
          q := CloseGate(buf, p, end);
          IF (c = 0E9H) OR (c = 0EAH) OR (c = 0EDH) THEN RawItem(buf, p, q - p + 1, kDefMark, x)
          ELSE RawItem(buf, p, q - p + 1, kRaw, x)
          END;
          IF q < end THEN AddItem(d, x) END;
          p := q + 1
        END
      END
    END
  END
END Parse42;

(* ---- locked (password protected) documents ---- *)

PROCEDURE Xor(a, b: INTEGER): INTEGER;
VAR r, bit: INTEGER;
BEGIN
  r := 0; bit := 1;
  WHILE (a > 0) OR (b > 0) DO
    IF ODD(a) # ODD(b) THEN r := r + bit END;
    a := a DIV 2; b := b DIV 2; bit := bit * 2
  END;
  RETURN r
END Xor;

PROCEDURE PwChecksum(pw: ARRAY OF CHAR): INTEGER;
VAR i, cs: INTEGER;
BEGIN
  cs := 0; i := 0;
  WHILE pw[i] # 0X DO
    cs := (cs DIV 2 + (cs MOD 2) * 8000H);
    cs := Xor(cs, ORD(UpCh(pw[i])) * 256) MOD 10000H;
    INC(i)
  END;
  RETURN cs
END PwChecksum;

PROCEDURE Crypt(VAR buf: ARRAY OF CHAR; start, len: INTEGER; pw: ARRAY OF CHAR);
VAR i, n, m: INTEGER;
BEGIN
  n := SLen(pw);
  IF n = 0 THEN RETURN END;
  FOR i := start TO len - 1 DO
    m := (n + 1 + i - start) MOD 256;
    buf[i] := CHR(Xor(Xor(ORD(buf[i]), ORD(UpCh(pw[(i - start) MOD n]))), m))
  END
END Crypt;

(* ====================================================================
   WordPerfect 4.2 writer.  "Old value" bytes are filled in from a
   running format state, the way WordPerfect itself maintains them.
   ==================================================================== *)

VAR
  write41: BOOLEAN;  (* Text In/Out 7: WordPerfect 4.1 tab codes *)
  softAt: IntArr;    (* softAt[i] = 1: item i is the space ending a soft line *)
  softCap: INTEGER;

PROCEDURE PutStrBytes(VAR x: Item);
VAR i: INTEGER;
BEGIN
  IF x.s # NIL THEN FOR i := 0 TO x.sl - 1 DO Put(ORD(x.s[i])) END END
END PutStrBytes;

PROCEDURE Write42(d: Doc; VAR st: Fmt; soft: BOOLEAN);
VAR i, j, c, n, hl: INTEGER; x: Item; tb: ARRAY 52 OF CHAR; ok: BOOLEAN;
  oldPn, oldPg, oldNote, oldTop, oldLpi, oldUnd, oldBin, oldSpc, tmar: INTEGER;
  oldP, oldF, oldFl, oldTl, oldLn, oldLp: INTEGER;
  oldNoteOpt: ARRAY NoteLen OF CHAR;
  hdrDef: ARRAY 4 OF INTEGER;
BEGIN
  oldPn := st.pnPos; oldPg := 0; oldNote := 1; oldTop := st.topMar; oldLpi := st.lpi;
  oldUnd := st.undMode; oldBin := st.bin; oldSpc := st.spacing; tmar := st.lm;
  oldP := st.pitch; oldF := st.font; oldFl := st.formLen; oldTl := st.textHalf;
  oldLn := st.lineNum; oldLp := st.lnPos;
  FOR i := 0 TO NoteLen - 1 DO oldNoteOpt[i] := st.noteOpt[i] END;
  FOR i := 0 TO 3 DO hdrDef[i] := i END;
  FOR i := 0 TO d.n - 1 DO
    x := d.it[i];
    CASE x.k OF
      kChar:
        IF soft & (x.ch = " ") & (i < softCap) & (softAt[i] = 1) THEN Put(0DH)
        ELSIF ORD(x.ch) < 80H THEN Put(ORD(x.ch))
        ELSE Put(0E1H); Put(ORD(x.ch)); Put(0E1H)
        END
    | kCtl: Put(ORD(x.ch))
    | kHRt: Put(0AH); tmar := st.lm
    | kHPg: Put(0CH)
    | kTab: Put(09H)
    | kAttrOn, kAttrOff:
        ok := x.k = kAttrOn;
        CASE x.a OF
          aBold: IF ok THEN Put(fBoldOn) ELSE Put(fBoldOff) END
        | aUnd: IF ok THEN Put(fUndOn) ELSE Put(fUndOff) END
        | aRed: IF ok THEN Put(fRedOn) ELSE Put(fRedOff) END
        | aStrike: IF ok THEN Put(fStrkOn) ELSE Put(fStrkOff) END
        | aItal: IF ok THEN Put(fItalOn) ELSE Put(fItalOff) END
        | aShadow: IF ok THEN Put(fShadOn) ELSE Put(fShadOff) END
        | aOutline: IF ok THEN Put(fOutlOn) ELSE Put(fOutlOff) END
        | aRev: IF ok THEN Put(fRevOn) ELSE Put(fRevOff) END
        ELSE
        END
    | kSingle: Put(x.a)
    | kEndCenter: Put(fEndCenter)
    | kEndAlign: Put(fEndAlign)
    | kCenter: Put(0C3H); Put(x.a); Put(x.b); Put(x.c); Put(0C3H)
    | kAlign: Put(0C4H); Put(x.a + 128 * x.c); Put(x.b); Put(tmar); Put(0C4H)
    | kMargin: Put(0C0H); Put(st.lm); Put(st.rm); Put(x.a); Put(x.b); Put(0C0H);
        st.lm := x.a; st.rm := x.b; tmar := x.a
    | kSpacing: Put(0C1H); Put(oldSpc); Put(x.a); Put(0C1H); oldSpc := x.a
    | kMarRel: Put(0C2H); Put(x.a); Put(0C2H)
    | kHZone: Put(0C5H); Put(st.hzL); Put(st.hzR); Put(x.a); Put(x.b); Put(0C5H);
        st.hzL := x.a; st.hzR := x.b
    | kPnPos: Put(0C6H); Put(oldPn); Put(x.a); Put(0C6H); oldPn := x.a
    | kPgNum: Put(0C7H); Put(oldPg DIV 256); Put(oldPg MOD 256);
        Put((x.a DIV 256) MOD 128 + 128 * x.b); Put(x.a MOD 256); Put(0C7H);
        oldPg := x.a + 32768 * x.b
    | kPnCol: Put(0C8H); Put(st.pnL); Put(st.pnC); Put(st.pnR); Put(x.a); Put(x.b); Put(x.c); Put(0C8H);
        st.pnL := x.a; st.pnC := x.b; st.pnR := x.c
    | kCondEOP: Put(0CAH); Put(x.a); Put(0CAH)
    | kFont: Put(0CBH); Put((oldP + 256) MOD 256); Put(oldF); Put((x.a + 256) MOD 256); Put(x.b); Put(0CBH);
        oldP := x.a; oldF := x.b
    | kIndent: Put(0CCH); Put(tmar); Put(x.a); Put(0CCH); tmar := x.a
    | kTopMar: Put(0CEH); Put(oldTop); Put(x.a); Put(0CEH); oldTop := x.a
    | kSuppress: Put(0CFH); Put(x.a); Put(0CFH)
    | kFormLen: Put(0D0H); Put(oldFl); Put(oldTl); Put(x.a); Put(x.b); Put(0D0H);
        oldFl := x.a; oldTl := x.b
    | kHdrFtr:
        c := x.a MOD 4;
        hl := CountLines(x.sub) * 2;
        Put(0D1H); Put(hdrDef[c]); Put(0); Put(0FFH); Put(0FFH); Put(x.b); Put(x.c);
        IF x.sub # NIL THEN Write42(x.sub, st, FALSE) END;
        Put(0FFH); Put(hl); Put(x.a); Put(0D1H);
        hdrDef[c] := x.a
    | kAdvLn: Put(0D4H); Put(0); Put(x.a); Put(0D4H)
    | kLPI: Put(0D5H); Put(oldLpi); Put(x.a); Put(0D5H); oldLpi := x.a
    | kMathDef: PutStrBytes(x)
    | kAlignChar: Put(0D8H); Put(st.alignCh); Put(x.a); Put(0D8H); st.alignCh := x.a
    | kUndMode: Put(0DAH); Put(oldUnd); Put(x.a); Put(0DAH); oldUnd := x.a
    | kBin: Put(0DBH); Put(oldBin - 1); Put(x.a - 1); Put(0DBH); oldBin := x.a
    | kPrnCmd:
        Put(0DFH);
        IF x.s # NIL THEN
          FOR j := 0 TO x.sl - 1 DO
            c := ORD(x.s[j]);
            IF c >= 0BFH THEN Put(0BFH); Put(c - 0BFH) ELSE Put(c) END
          END
        END;
        Put(0DFH)
    | kLRIndent: Put(0E0H); Put(0); Put(x.a); Put(0E0H); tmar := tmar + x.a
    | kNote:
        n := CountLines(x.sub);
        Put(0E2H); Put(x.a);
        Put((x.b DIV 128) MOD 128); Put(x.b MOD 128);
        Put((n DIV 128) MOD 128); Put(n MOD 128);
        IF ODD(x.a DIV 2) THEN Put(0)                (* endnote *)
        ELSE Put(0); Put(n); Put(1)                  (* footnote: one page *)
        END;
        Put(0FFH); Put(st.lm); Put(st.rm);
        IF x.sub # NIL THEN Write42(x.sub, st, FALSE) END;
        Put(0E2H)
    | kNoteOpt:
        Put(0E3H);
        FOR j := 0 TO NoteLen - 1 DO Put(ORD(oldNoteOpt[j])) END;
        FOR j := 0 TO NoteLen - 1 DO
          IF (x.s # NIL) & (j < x.sl) THEN Put(ORD(x.s[j])); oldNoteOpt[j] := x.s[j] ELSE Put(0) END
        END;
        Put(0E3H)
    | kNoteNum: Put(0E4H); Put((oldNote DIV 128) MOD 128); Put(oldNote MOD 128);
        Put((x.a DIV 128) MOD 128); Put(x.a MOD 128); Put(0E4H); oldNote := x.a
    | kDate:
        Put(0EBH);
        FOR j := 0 TO 29 DO
          IF (x.s # NIL) & (j < x.sl) THEN Put(ORD(x.s[j])) ELSE Put(0) END
        END;
        Put(0EBH)
    | kBlockPro: Put(0ECH); Put(x.a); Put(x.b); Put(0ECH)
    | kComment:
        Put(0F2H); Put(x.a); Put(0); Put(CountLines(x.sub)); Put(0);
        IF x.sub # NIL THEN Write42(x.sub, st, FALSE) END;
        Put(0F2H)
    | kTabSet:
      IF write41 THEN
        (* WordPerfect 4.1: 160-position table, no tab types *)
        TabsToBytes(st, tb);
        Put(0C9H);
        FOR j := 0 TO 19 DO Put(ORD(tb[j])) END;
        IF x.s # NIL THEN BytesToTabs(x.s^, 0, st) END;
        TabsToBytes(st, tb);
        FOR j := 0 TO 19 DO Put(ORD(tb[j])) END;
        Put(0C9H)
      ELSE
        TabsToBytes(st, tb);
        Put(0F1H);
        FOR j := 0 TO 51 DO Put(ORD(tb[j])) END;
        FOR j := 0 TO 51 DO
          IF (x.s # NIL) & (j < x.sl) THEN Put(ORD(x.s[j])) ELSE Put(0) END
        END;
        Put(0F1H);
        IF x.s # NIL THEN BytesToTabs(x.s^, 0, st) END
      END
    | kLineNum: Put(0F0H); Put(oldLn); Put(oldLp); Put(x.a); Put(x.b); Put(0F0H);
        oldLn := x.a; oldLp := x.b
    | kMark: IF x.a = 1 THEN Put(0E7H); Put(x.b); Put(0E7H) ELSE Put(0E8H); Put(x.b); Put(0E8H) END
    | kRaw, kDefMark: PutStrBytes(x)
    ELSE (* kRaw5 and anything else has no WP 4.2 form *)
    END
  END
END Write42;

(* ====================================================================
   WordPerfect 5.0/5.1 reader.  WP 5 measures in WordPerfect units
   (1200 per inch); a 10-pitch column is 120 units and a half-line 100.
   ==================================================================== *)

PROCEDURE W16(VAR buf: ARRAY OF CHAR; p: INTEGER): INTEGER;
BEGIN RETURN ORD(buf[p]) + 256 * ORD(buf[p + 1])
END W16;

PROCEDURE Fixed5Size(c: INTEGER): INTEGER;
BEGIN
  CASE c OF
    0C0H: RETURN 4 | 0C1H: RETURN 9 | 0C2H: RETURN 11 | 0C3H: RETURN 3
  | 0C4H: RETURN 3 | 0C5H: RETURN 5 | 0C6H: RETURN 6 | 0C7H: RETURN 7
  | 0C8H: RETURN 4 | 0C9H: RETURN 5 | 0CAH: RETURN 6 | 0CBH: RETURN 6
  | 0CCH: RETURN 8 | 0CDH: RETURN 10 | 0CEH: RETURN 10 | 0CFH: RETURN 12
  ELSE RETURN 1
  END
END Fixed5Size;

PROCEDURE Wp5CharToCp(ch, set: INTEGER): CHAR;
VAR u, c: INTEGER;
BEGIN
  u := 0;
  IF set = 0 THEN u := ch
  ELSIF set = 1 THEN u := wp5Multi[ch]
  ELSIF set = 3 THEN u := wp5Box[ch]
  ELSIF set = 4 THEN u := wp5Typo[ch]
  END;
  c := UniToCp(u);
  IF c < 0 THEN c := ORD("?") END;
  RETURN CHR(c)
END Wp5CharToCp;

(* CP437 character -> WP 5 character (ch, set); FALSE if none *)
PROCEDURE CpToWp5(c: CHAR; VAR ch, set: INTEGER): BOOLEAN;
VAR u, i: INTEGER;
BEGIN
  u := CpToUni(c);
  FOR i := 0 TO 255 DO
    IF wp5Multi[i] = u THEN ch := i; set := 1; RETURN TRUE END
  END;
  FOR i := 0 TO 255 DO
    IF wp5Box[i] = u THEN ch := i; set := 3; RETURN TRUE END
  END;
  FOR i := 0 TO 255 DO
    IF wp5Typo[i] = u THEN ch := i; set := 4; RETURN TRUE END
  END;
  RETURN FALSE
END CpToWp5;

PROCEDURE Map5Attr(a: INTEGER): INTEGER;
BEGIN
  CASE a OF
    0CH: RETURN aBold | 0EH, 0BH: RETURN aUnd | 08H: RETURN aItal
  | 0DH: RETURN aStrike | 0AH: RETURN aRed | 09H: RETURN aShadow
  | 07H: RETURN aOutline
  ELSE RETURN -1
  END
END Map5Attr;

PROCEDURE ColOf5(wpu: INTEGER): INTEGER;
BEGIN RETURN (wpu + 60) DIV 120
END ColOf5;

PROCEDURE Parse5(VAR buf: ARRAY OF CHAR; p, end: INTEGER; d: Doc);
VAR c, sz, sub, q, i, t, a, open, supMode: INTEGER; x: Item; f: Fmt;
BEGIN
  open := 0; supMode := 0;
  WHILE p < end DO
    c := ORD(buf[p]);
    IF (c = 0) OR (c = 7FH) OR (c = 0FFH) THEN INC(p)
    ELSIF c < 20H THEN
      IF c = 0AH THEN AddK(d, kHRt, 0, 0, 0)
      ELSIF (c = 0BH) OR (c = 0DH) THEN AddCh(d, " ")
      ELSIF c = 0CH THEN AddK(d, kHPg, 0, 0, 0)
      ELSIF c = 09H THEN AddK(d, kTab, 0, 0, 0)
      END;
      INC(p)
    ELSIF c < 7FH THEN
      IF supMode # 0 THEN AddK(d, kSingle, supMode, 0, 0) END;
      AddCh(d, CHR(c)); INC(p)
    ELSIF c < 0C0H THEN
      CASE c OF
        8CH, 90H, 99H: AddK(d, kHRt, 0, 0, 0)
      | 93H, 94H, 95H: AddCh(d, " ")
      | 0A0H: AddK(d, kSingle, fHardSp, 0, 0)
      | 0A9H, 0AAH, 0ABH: AddK(d, kSingle, fHardHy, 0, 0)
      | 0ACH, 0ADH, 0AEH: AddK(d, kSingle, fSoftHy, 0, 0)
      | 81H: AddK(d, kSingle, fJustOn, 0, 0)
      | 82H: AddK(d, kSingle, fJustOff, 0, 0)
      | 83H: IF open = 1 THEN AddK(d, kEndCenter, 0, 0, 0)
             ELSIF open = 2 THEN AddK(d, kEndAlign, 0, 0, 0) END;
             open := 0
      | 86H: AddK(d, kSingle, fCenterPg, 0, 0)
      | 8AH: AddK(d, kSingle, fWOOn, 0, 0)
      | 8BH: AddK(d, kSingle, fWOOff, 0, 0)
      ELSE
      END;
      INC(p)
    ELSIF c < 0D0H THEN
      sz := Fixed5Size(c);
      IF p + sz > end THEN p := end
      ELSE
        IF c = 0C0H THEN
          x.ch := Wp5CharToCp(ORD(buf[p + 1]), ORD(buf[p + 2]));
          IF supMode # 0 THEN AddK(d, kSingle, supMode, 0, 0) END;
          AddCh(d, x.ch)
        ELSIF c = 0C1H THEN
          t := ORD(buf[p + 1]) MOD 32;
          a := ColOf5(W16(buf, p + 4));
          IF (t = 08H) THEN AddK(d, kAlign, ORD("."), a, 0); open := 2
          ELSIF t = 0CH THEN AddK(d, kAlign, 0AH, a, 0); open := 2
          ELSIF t = 10H THEN AddK(d, kMarRel, 5, 0, 0)
          ELSIF t = 18H THEN AddK(d, kCenter, 1, a, 0); open := 1
          ELSIF t = 1CH THEN AddK(d, kCenter, 0, a, 0); open := 1
          ELSE AddK(d, kTab, 0, 0, 0)
          END
        ELSIF c = 0C2H THEN
          IF ORD(buf[p + 1]) MOD 2 = 1 THEN AddK(d, kLRIndent, 5, 0, 0)
          ELSE AddK(d, kIndent, 0, 0, 0)
          END
        ELSIF (c = 0C3H) OR (c = 0C4H) THEN
          a := ORD(buf[p + 1]);
          IF (a = 05H) OR (a = 06H) THEN
            IF c = 0C4H THEN supMode := 0
            ELSIF a = 05H THEN supMode := fSuper ELSE supMode := fSub
            END
          ELSE
            a := Map5Attr(a);
            IF a >= 0 THEN
              IF c = 0C3H THEN AddK(d, kAttrOn, a, 0, 0) ELSE AddK(d, kAttrOff, a, 0, 0) END
            END
          END
        END;
        p := p + sz
      END
    ELSE
      (* variable length: code sub len16 data len16 sub code *)
      IF p + 4 > end THEN p := end
      ELSE
        sub := ORD(buf[p + 1]);
        sz := W16(buf, p + 2) + 4;
        IF (sz < 8) OR (p + sz > end) THEN p := end
        ELSE
          q := p + 4;       (* data *)
          IF (c = 0D0H) & (sub = 01H) THEN
            AddK(d, kMargin, ColOf5(W16(buf, q + 4)), 84 - ColOf5(W16(buf, q + 6)), 0)
          ELSIF (c = 0D0H) & (sub = 02H) THEN
            a := W16(buf, q + 2);
            AddK(d, kSpacing, (a DIV 256) * 2 + (a MOD 256) DIV 128, 0, 0)
          ELSIF (c = 0D0H) & (sub = 04H) THEN
            FOR i := 0 TO 255 DO f.tabs[i] := 0X END;
            i := 0;
            WHILE (i < 40) & (W16(buf, q + 100 + 2 * i) # 0FFFFH) DO
              a := ColOf5(W16(buf, q + 100 + 2 * i));
              IF (a >= 0) & (a <= 250) THEN f.tabs[a] := 1X END;
              INC(i)
            END;
            ClearItem(x); x.k := kTabSet; x.s := NewBytes(52); x.sl := 52;
            TabsToBytes(f, x.s^); AddItem(d, x)
          ELSIF (c = 0D0H) & (sub = 05H) THEN
            AddK(d, kTopMar, (W16(buf, q + 4) + 50) DIV 100, 0, 0)
          ELSIF (c = 0D0H) & (sub = 06H) THEN
            IF ORD(buf[q + 1]) = 1 THEN AddK(d, kSingle, fJustOn, 0, 0)
            ELSE AddK(d, kSingle, fJustOff, 0, 0)
            END
          ELSIF (c = 0D4H) & (sub = 0) THEN
            (* end of page: regenerated *)
          ELSIF (c = 0D5H) & (sub <= 3) THEN
            ClearItem(x); x.k := kHdrFtr; x.a := sub + 4 * (ORD(buf[q + 7]) MOD 64);
            x.b := 10; x.c := 74; x.sub := NewDoc();
            IF q + 18 < p + sz - 4 THEN Parse5(buf, q + 18, p + sz - 4, x.sub) END;
            AddItem(d, x)
          ELSIF (c = 0D6H) & (sub <= 1) THEN
            ClearItem(x); x.k := kNote; x.a := sub * 2; x.b := W16(buf, q + 1);
            IF ORD(buf[q]) >= 128 THEN x.a := x.a + 1 END;
            IF sub = 0 THEN i := q + 4 + 2 * (ORD(buf[q + 3]) + 1) + 9
            ELSE i := q + 7
            END;
            x.sub := NewDoc();
            IF i < p + sz - 4 THEN Parse5(buf, i, p + sz - 4, x.sub) END;
            AddItem(d, x)
          ELSE
            RawItem(buf, p, sz, kRaw5, x); AddItem(d, x)
          END;
          p := p + sz
        END
      END
    END
  END
END Parse5;

(* ====================================================================
   WordPerfect 5.1 writer
   ==================================================================== *)

VAR
  tabPos: IntArr;       (* column reached by the item after a tab, or 0 *)

PROCEDURE VarStart(code, sub: INTEGER): INTEGER;
VAR at: INTEGER;
BEGIN
  at := obLen; Put(code); Put(sub); PutW(0); RETURN at
END VarStart;

PROCEDURE VarEnd(at: INTEGER);
VAR n: INTEGER;
BEGIN
  n := obLen - at - 4 + 4;      (* data bytes + trailing 4 *)
  PutW(n); Put(ORD(ob[at + 1])); Put(ORD(ob[at]));
  ob[at + 2] := CHR(n MOD 256); ob[at + 3] := CHR(n DIV 256)
END VarEnd;

PROCEDURE PutFix5(code, a, pos: INTEGER);    (* C1 tab group *)
BEGIN
  Put(code); Put(a); PutW(0); PutW(pos); PutW(0); Put(code)
END PutFix5;

PROCEDURE Write5(d: Doc; VAR st: Fmt; soft: BOOLEAN);
VAR i, j, ch, set, at, pend, a, oldSpc, oldTop: INTEGER; x: Item;
BEGIN
  pend := 0; oldSpc := st.spacing; oldTop := st.topMar;
  FOR i := 0 TO d.n - 1 DO
    x := d.it[i];
    CASE x.k OF
      kChar:
        IF pend # 0 THEN Put(0C3H); Put(pend); Put(0C3H) END;
        IF soft & (x.ch = " ") & (i < softCap) & (softAt[i] = 1) THEN Put(0DH)
        ELSIF ORD(x.ch) < 7FH THEN Put(ORD(x.ch))
        ELSIF CpToWp5(x.ch, ch, set) THEN Put(0C0H); Put(ch); Put(set); Put(0C0H)
        ELSE Put(ORD("?"))
        END;
        IF pend # 0 THEN Put(0C4H); Put(pend); Put(0C4H); pend := 0 END
    | kHRt: Put(0AH)
    | kHPg: Put(0CH)
    | kTab:
        a := 0; IF soft & (i < softCap) THEN a := tabPos[i] END;
        PutFix5(0C1H, 0, a * 120)
    | kAttrOn, kAttrOff:
        CASE x.a OF
          aBold: a := 0CH | aUnd: a := 0EH | aRed: a := 0AH | aStrike: a := 0DH
        | aItal: a := 08H | aShadow: a := 09H | aOutline: a := 07H
        ELSE a := -1
        END;
        IF a >= 0 THEN
          IF x.k = kAttrOn THEN Put(0C3H); Put(a); Put(0C3H) ELSE Put(0C4H); Put(a); Put(0C4H) END
        END
    | kSingle:
        IF x.a = fSuper THEN pend := 05H
        ELSIF x.a = fSub THEN pend := 06H
        ELSIF x.a = fHardSp THEN Put(0A0H)
        ELSIF x.a = fHardHy THEN Put(0A9H)
        ELSIF x.a = fSoftHy THEN Put(0ACH)
        ELSIF (x.a = fJustOn) OR (x.a = fJustOff) THEN
          at := VarStart(0D0H, 06H); Put(1);
          IF x.a = fJustOn THEN Put(1) ELSE Put(0) END; VarEnd(at)
        ELSIF (x.a = fWOOn) OR (x.a = fWOOff) OR (x.a = fCenterPg) THEN Put(x.a)
        END
    | kCenter:
        IF x.a = 0 THEN PutFix5(0C1H, 1CH, x.b * 120) ELSE PutFix5(0C1H, 18H, x.b * 120) END
    | kEndCenter, kEndAlign: Put(83H)
    | kAlign:
        IF x.a = 0AH THEN PutFix5(0C1H, 0CH, st.rm * 120) ELSE PutFix5(0C1H, 08H, x.b * 120) END
    | kMarRel: PutFix5(0C1H, 10H, 0)
    | kIndent, kLRIndent:
        IF x.k = kIndent THEN a := 0 ELSE a := 1 END;
        Put(0C2H); Put(a); PutW(0); PutW(0); PutW(x.a * 120); PutW(0); Put(0C2H)
    | kMargin:
        at := VarStart(0D0H, 01H);
        PutW(st.lm * 120); PutW((84 - st.rm) * 120);
        PutW(x.a * 120); PutW((84 - x.b) * 120);
        VarEnd(at); st.lm := x.a; st.rm := x.b
    | kSpacing:
        at := VarStart(0D0H, 02H);
        PutW((oldSpc DIV 2) * 256 + (oldSpc MOD 2) * 128);
        PutW((x.a DIV 2) * 256 + (x.a MOD 2) * 128);
        VarEnd(at); oldSpc := x.a
    | kTopMar:
        at := VarStart(0D0H, 05H);
        PutW(oldTop * 100); PutW(1200); PutW(x.a * 100); PutW(1200);
        VarEnd(at); oldTop := x.a
    | kTabSet:
        at := VarStart(0D0H, 04H);
        FOR j := 0 TO 99 DO Put(0) END;
        IF x.s # NIL THEN BytesToTabs(x.s^, 0, st) END;
        a := 0;
        FOR j := 0 TO 250 DO
          IF (st.tabs[j] # 0X) & (a < 40) THEN PutW(j * 120); INC(a) END
        END;
        IF a < 40 THEN PutW(0FFFFH); INC(a) END;
        WHILE a < 40 DO PutW(0); INC(a) END;
        FOR j := 0 TO 19 DO Put(0) END;
        VarEnd(at)
    | kHdrFtr:
        at := VarStart(0D5H, x.a MOD 4);
        FOR j := 0 TO 6 DO Put(0) END;
        Put(x.a DIV 4);
        FOR j := 0 TO 9 DO Put(0) END;
        IF x.sub # NIL THEN Write5(x.sub, st, FALSE) END;
        VarEnd(at)
    | kNote:
        IF ODD(x.a DIV 2) THEN a := 1 ELSE a := 0 END;
        at := VarStart(0D6H, a);
        Put(0); PutW(x.b);
        IF a = 0 THEN Put(0); FOR j := 1 TO 11 DO Put(0) END
        ELSE FOR j := 1 TO 4 DO Put(0) END
        END;
        IF x.sub # NIL THEN Write5(x.sub, st, FALSE) END;
        VarEnd(at)
    | kRaw5: PutStrBytes(x)
    | kCtl: Put(ORD(x.ch))
    ELSE
    END
  END
END Write5;

PROCEDURE Header5;
BEGIN
  Put(0FFH); PutStr("WPC"); PutW(16); PutW(0);
  Put(1); Put(0AH); Put(0); Put(1);
  PutW(0); PutW(0)
END Header5;

(* ====================================================================
   DOS text
   ==================================================================== *)

PROCEDURE ValidUtf8(VAR buf: ARRAY OF CHAR; len: INTEGER): BOOLEAN;
VAR i, c, need: INTEGER;
BEGIN
  i := 0;
  WHILE i < len DO
    c := ORD(buf[i]); INC(i);
    IF c >= 80H THEN
      IF c >= 0F0H THEN need := 3 ELSIF c >= 0E0H THEN need := 2
      ELSIF c >= 0C2H THEN need := 1 ELSE RETURN FALSE END;
      WHILE need > 0 DO
        IF (i >= len) OR (ORD(buf[i]) < 80H) OR (ORD(buf[i]) >= 0C0H) THEN RETURN FALSE END;
        INC(i); DEC(need)
      END
    END
  END;
  RETURN TRUE
END ValidUtf8;

(* join = TRUE: single line breaks inside paragraphs become spaces
   (Text In/Out "CR/LF in H-Zone to [SRt]") *)
PROCEDURE ImportText(VAR buf: ARRAY OF CHAR; len: INTEGER; d: Doc; join: BOOLEAN);
VAR i, c, u, need: INTEGER; utf, nl: BOOLEAN;
BEGIN
  utf := ValidUtf8(buf, len);
  i := 0;
  WHILE i < len DO
    c := ORD(buf[i]); INC(i);
    nl := FALSE;
    IF c = 0DH THEN
      IF (i < len) & (buf[i] = 0AX) THEN INC(i) END;
      nl := TRUE
    ELSIF c = 0AH THEN nl := TRUE
    ELSIF c = 09H THEN AddK(d, kTab, 0, 0, 0)
    ELSIF c = 0CH THEN AddK(d, kHPg, 0, 0, 0)
    ELSIF c < 20H THEN AddCh(d, CHR(c))
    ELSIF (c >= 80H) & utf THEN
      IF c >= 0F0H THEN u := c MOD 8; need := 3
      ELSIF c >= 0E0H THEN u := c MOD 16; need := 2
      ELSE u := c MOD 32; need := 1
      END;
      WHILE (need > 0) & (i < len) DO u := u * 64 + ORD(buf[i]) MOD 64; INC(i); DEC(need) END;
      u := UniToCp(u);
      IF u < 0 THEN u := ORD("?") END;
      AddCh(d, CHR(u))
    ELSE AddCh(d, CHR(c))
    END;
    IF nl THEN
      IF join & (d.n > 0) & (d.it[d.n - 1].k = kChar) & (i < len) &
         (buf[i] # 0DX) & (buf[i] # 0AX) & (buf[i] # " ") & (buf[i] # 09X) THEN
        AddCh(d, " ")
      ELSE AddK(d, kHRt, 0, 0, 0)
      END
    END
  END
END ImportText;

(* ====================================================================
   Loading: detect the format
   ==================================================================== *)

PROCEDURE IsLocked(name: ARRAY OF CHAR): BOOLEAN;
VAR buf: Bytes; len: INTEGER;
BEGIN
  IF ~LoadFile(name, buf, len) THEN RETURN FALSE END;
  RETURN (len >= 6) & (buf[0] = 0FEX) & (buf[1] = 0FFX) & (buf[2] = 61X) & (buf[3] = 61X)
END IsLocked;

(* load a file into d (appending).  Returns the format, or -1 (not found),
   -2 (bad password), -3 (unsupported WordPerfect version). *)
PROCEDURE LoadDoc(name: ARRAY OF CHAR; d: Doc; pw: ARRAY OF CHAR): INTEGER;
VAR buf: Bytes; len, p, i, cr, hi: INTEGER;
BEGIN
  IF ~LoadFile(name, buf, len) THEN RETURN -1 END;
  IF (len >= 16) & (buf[0] = 0FFX) & (buf[1] = "W") & (buf[2] = "P") & (buf[3] = "C") THEN
    IF ORD(buf[10]) # 0 THEN RETURN -3 END;       (* WP 6 and later *)
    p := W16(buf^, 4);
    IF (p < 16) OR (p > len) THEN p := 16 END;
    Parse5(buf^, p, len, d);
    RETURN fmtWP5
  ELSIF (len >= 6) & (buf[0] = 0FEX) & (buf[1] = 0FFX) & (buf[2] = 61X) & (buf[3] = 61X) THEN
    IF W16(buf^, 4) # PwChecksum(pw) THEN RETURN -2 END;
    Crypt(buf^, 6, len, pw);
    p := 6; Parse42(buf^, p, len, -1, d);
    RETURN fmtWP42
  ELSE
    hi := 0; cr := 0;
    FOR i := 0 TO len - 1 DO
      IF ORD(buf[i]) >= 80H THEN INC(hi) END;
      IF (buf[i] = 0DX) & (i + 1 < len) & (buf[i + 1] = 0AX) THEN INC(cr) END
    END;
    IF ((hi > 0) & ValidUtf8(buf^, len)) OR ((hi = 0) & (cr > 0)) THEN
      ImportText(buf^, len, d, FALSE);
      RETURN fmtText
    END;
    p := 0; Parse42(buf^, p, len, -1, d);
    RETURN fmtWP42
  END
END LoadDoc;

(* ====================================================================
   The formatter.  Lays the item stream out into lines (word wrap with
   the margins, tabs and indents in effect), numbers notes, divides the
   lines into pages, and builds the list of display rows.
   ==================================================================== *)

VAR
  noteCtx: INTEGER;        (* number shown for [Note #] inside a note *)

PROCEDURE NextTab(VAR f: Fmt; col: INTEGER): INTEGER;
VAR i: INTEGER;
BEGIN
  i := col + 1;
  WHILE (i <= 250) & (f.tabs[i] = 0X) DO INC(i) END;
  IF i > 250 THEN i := col + 1 END;
  RETURN i
END NextTab;

PROCEDURE PrevTab(VAR f: Fmt; col: INTEGER): INTEGER;
VAR i: INTEGER;
BEGIN
  i := col - 1;
  WHILE (i > 0) & (f.tabs[i] = 0X) DO DEC(i) END;
  IF i < 0 THEN i := 0 END;
  RETURN i
END PrevTab;

(* text an item shows on screen, for items that are not plain characters *)
PROCEDURE GenText(VAR x: Item; VAR s: ARRAY OF CHAR);
VAR f: Str;
BEGIN
  s[0] := 0X;
  CASE x.k OF
    kCtl: s[0] := "^"; s[1] := CHR(ORD(x.ch) + 64); s[2] := 0X
  | kNote: IntStr(x.b, s)
  | kDate: GetStr(x, f); FormatDate(f, s)
  | kSingle:
      CASE x.a OF
        fHardSp: Cpy(" ", s) | fHardHy: Cpy("-", s)
      | fDoSub: Cpy("+", s) | fDoTot: Cpy("=", s) | fDoGrand: Cpy("*", s)
      | fCalcCol: Cpy("!", s) | fSubEnt: Cpy("t", s) | fTotEnt: Cpy("T", s)
      | fNeg: Cpy("N", s)
      | fNoteNum: IntStr(noteCtx, s)
      ELSE
      END
  ELSE
  END
END GenText;

PROCEDURE ItemWidth(VAR x: Item): INTEGER;
VAR s: Str;
BEGIN
  IF x.k = kChar THEN RETURN 1
  ELSIF (x.k = kCtl) OR (x.k = kNote) OR (x.k = kDate) OR (x.k = kSingle) THEN
    GenText(x, s); RETURN SLen(s)
  ELSE RETURN 0
  END
END ItemWidth;

PROCEDURE EnsureLayoutCaps(e: Ed);
VAR n: INTEGER;
BEGIN
  n := e.d.n + 2;
  IF (e.icol = NIL) OR (e.icap < n) THEN
    e.icap := n + n DIV 2 + 256;
    NEW(e.icol, e.icap); NEW(e.iattr, e.icap)
  END;
  IF e.lines = NIL THEN e.lcap := 256; NEW(e.lines, e.lcap) END;
  IF e.snaps = NIL THEN e.scap := 16; NEW(e.snaps, e.scap) END;
  IF e.pages = NIL THEN e.pcap := 16; NEW(e.pages, e.pcap) END;
  IF e.rows = NIL THEN e.rcap := 256; NEW(e.rows, e.rcap) END
END EnsureLayoutCaps;

PROCEDURE AddSnap(e: Ed; VAR st: Fmt);
VAR ns: Fmts; i: INTEGER;
BEGIN
  IF e.nsnaps >= e.scap THEN
    NEW(ns, e.scap * 2);
    FOR i := 0 TO e.nsnaps - 1 DO ns[i] := e.snaps[i] END;
    e.snaps := ns; e.scap := e.scap * 2
  END;
  e.snaps[e.nsnaps] := st; INC(e.nsnaps)
END AddSnap;

PROCEDURE AddLine(e: Ed; start, end, brk, snap, height, lm: INTEGER);
VAR nl: Lines; i: INTEGER;
BEGIN
  IF e.nlines >= e.lcap THEN
    NEW(nl, e.lcap * 2);
    FOR i := 0 TO e.nlines - 1 DO nl[i] := e.lines[i] END;
    e.lines := nl; e.lcap := e.lcap * 2
  END;
  e.lines[e.nlines].start := start; e.lines[e.nlines].end := end;
  e.lines[e.nlines].brk := brk; e.lines[e.nlines].snap := snap;
  e.lines[e.nlines].height := height; e.lines[e.nlines].lm := lm;
  e.lines[e.nlines].page := 0; e.lines[e.nlines].ln := 0; e.lines[e.nlines].row := 0;
  INC(e.nlines)
END AddLine;

(* width of a centered/aligned segment starting after item i *)
PROCEDURE SegWidth(d: Doc; i: INTEGER; endK: INTEGER; stopAtAlign: INTEGER): INTEGER;
VAR w: INTEGER;
BEGIN
  w := 0; INC(i);
  WHILE (i < d.n) & (d.it[i].k # endK) & (d.it[i].k # kHRt) & (d.it[i].k # kHPg) &
        (d.it[i].k # kTab) & (d.it[i].k # kCenter) & (d.it[i].k # kAlign) &
        ~((stopAtAlign > 0) & (d.it[i].k = kChar) & (ORD(d.it[i].ch) = stopAtAlign)) DO
    w := w + ItemWidth(d.it[i]); INC(i)
  END;
  RETURN w
END SegWidth;

PROCEDURE SetAttr(VAR st: Fmt; a: INTEGER; on: BOOLEAN);
BEGIN
  IF on THEN
    IF ~ODD(ASR(st.attr, a)) THEN st.attr := st.attr + LSL(1, a) END
  ELSE
    IF ODD(ASR(st.attr, a)) THEN st.attr := st.attr - LSL(1, a) END
  END
END SetAttr;

(* apply a format code to st (shared by the formatter, the printer and
   anything else that needs the state at some point of the document) *)
PROCEDURE ApplyCode(VAR x: Item; VAR st: Fmt);
VAR t: INTEGER;
BEGIN
  CASE x.k OF
    kAttrOn: SetAttr(st, x.a, TRUE)
  | kAttrOff: SetAttr(st, x.a, FALSE)
  | kMargin: st.lm := x.a; st.rm := x.b
  | kSpacing: IF x.a > 0 THEN st.spacing := x.a END
  | kTabSet: IF x.s # NIL THEN BytesToTabs(x.s^, 0, st) END
  | kAlignChar: st.alignCh := x.a
  | kHZone: st.hzL := x.a; st.hzR := x.b
  | kPnPos: st.pnPos := x.a
  | kPnCol: st.pnL := x.a; st.pnC := x.b; st.pnR := x.c
  | kTopMar: st.topMar := x.a
  | kFormLen: st.formLen := x.a; st.textHalf := x.b
  | kLPI: st.lpi := x.a
  | kFont: st.pitch := x.a; st.font := x.b
  | kUndMode: st.undMode := x.a
  | kBin: st.bin := x.a
  | kLineNum: st.lineNum := x.a; st.lnPos := x.b
  | kNoteOpt: IF x.s # NIL THEN FOR t := 0 TO NoteLen - 1 DO st.noteOpt[t] := x.s[t] END END
  | kHdrFtr:
      t := x.a MOD 4;
      st.hdrOcc[t] := x.a DIV 4;
      IF x.a DIV 4 = 0 THEN st.hdr[t] := NIL ELSE st.hdr[t] := x.sub END;
      st.hdrLm[t] := x.b; st.hdrRm[t] := x.c
  | kSingle:
      CASE x.a OF
        fJustOn: st.just := TRUE | fJustOff: st.just := FALSE
      | fWOOn: st.widow := TRUE | fWOOff: st.widow := FALSE
      | fHyphOn: st.hyph := TRUE | fHyphOff: st.hyph := FALSE
      | fMathOn: st.mathOn := TRUE | fMathOff: st.mathOn := FALSE
      ELSE
      END
  ELSE
  END
END ApplyCode;

PROCEDURE EndLine(e: Ed; endIdx, brk: INTEGER; VAR st: Fmt; VAR lineStart, col, tL, tR,
                  lastBrk, snapAt: INTEGER; VAR hasText, snapDirty: BOOLEAN);
BEGIN
  IF snapDirty THEN AddSnap(e, st); snapAt := e.nsnaps - 1; snapDirty := FALSE END;
  AddLine(e, lineStart, endIdx, brk, snapAt, st.spacing, tL);
  lineStart := endIdx;
  IF brk # brSoft THEN tL := st.lm; tR := st.rm END;
  col := tL; hasText := FALSE; lastBrk := -1
END EndLine;

PROCEDURE Layout(e: Ed);
VAR d: Doc; i, col, tL, tR, lineStart, lastBrk, brkCol, w, center, stop, noteNo, endNo,
    snapAt, script, j: INTEGER;
    st, brkSt: Fmt; brkTL, brkTR, brkNote, brkEnd: INTEGER;
    hasText, ovr, snapDirty: BOOLEAN; x: Item;



BEGIN
  d := e.d;
  EnsureLayoutCaps(e);
  e.nlines := 0; e.nsnaps := 0;
  st := e.fmt0; AddSnap(e, st); snapAt := 0; snapDirty := FALSE;
  tL := st.lm; tR := st.rm; col := tL; lineStart := 0; lastBrk := -1;
  hasText := FALSE; ovr := FALSE; script := 0; noteNo := 1; endNo := 1;
  brkTL := tL; brkTR := tR; brkCol := col; brkNote := 1; brkEnd := 1; brkSt := st;
  i := 0;
  WHILE i < d.n DO
    x := d.it[i];
    e.icol[i] := col;
    e.iattr[i] := st.attr + script;
    CASE x.k OF
      kChar, kCtl, kNote, kDate:
        IF x.k = kNote THEN
          IF ODD(x.a DIV 2) THEN d.it[i].b := endNo; INC(endNo)
          ELSE d.it[i].b := noteNo; INC(noteNo)
          END;
          x.b := d.it[i].b
        END;
        w := ItemWidth(x);
        IF ovr & (w = 1) THEN
          col := col - 1; e.icol[i] := col; ovr := FALSE
        END;
        IF (x.k = kChar) & (x.ch = " ") THEN
          col := col + 1;
          lastBrk := i; brkSt := st; brkTL := tL; brkTR := tR; brkNote := noteNo; brkEnd := endNo;
          INC(i)
        ELSIF (col + w - 1 > tR) & (i > lineStart) & (hasText OR (lastBrk >= lineStart)) THEN
          (* wrap *)
          IF lastBrk >= lineStart THEN
            j := lastBrk + 1;
            st := brkSt; tL := brkTL; tR := brkTR; noteNo := brkNote; endNo := brkEnd
          ELSE
            j := i
          END;
          EndLine(e, j, brSoft, st, lineStart, col, tL, tR, lastBrk, snapAt, hasText, snapDirty);
          i := j; script := 0; ovr := FALSE
        ELSE
          col := col + w; hasText := TRUE; script := 0;
          IF (x.k = kChar) & (x.ch = "-") & (i + 1 < d.n) & (d.it[i + 1].k = kChar) &
             IsLetter(d.it[i + 1].ch) THEN
            lastBrk := i; brkSt := st; brkTL := tL; brkTR := tR; brkNote := noteNo; brkEnd := endNo
          END;
          INC(i)
        END
    | kHRt:
        INC(i);
        EndLine(e, i, brHard, st, lineStart, col, tL, tR, lastBrk, snapAt, hasText, snapDirty)
    | kHPg:
        INC(i);
        EndLine(e, i, brPage, st, lineStart, col, tL, tR, lastBrk, snapAt, hasText, snapDirty)
    | kTab:
        col := NextTab(st, col); hasText := TRUE; INC(i)
    | kSingle:
        CASE x.a OF
          fHardSp, fHardHy, fDoSub, fDoTot, fDoGrand, fCalcCol, fSubEnt, fTotEnt, fNeg, fNoteNum:
            w := ItemWidth(x);
            IF (col + w - 1 > tR) & (lastBrk >= lineStart) & (i > lineStart) THEN
              j := lastBrk + 1;
              st := brkSt; tL := brkTL; tR := brkTR; noteNo := brkNote; endNo := brkEnd;
              EndLine(e, j, brSoft, st, lineStart, col, tL, tR, lastBrk, snapAt, hasText, snapDirty);
              i := j
            ELSE
              col := col + w; hasText := TRUE;
              IF x.a = fHardHy THEN
                lastBrk := i; brkSt := st; brkTL := tL; brkTR := tR; brkNote := noteNo; brkEnd := endNo
              END;
              INC(i)
            END
        | fSoftHy:
            lastBrk := i; brkSt := st; brkTL := tL; brkTR := tR; brkNote := noteNo; brkEnd := endNo;
            INC(i)
        | fOvrstk: ovr := TRUE; INC(i)
        | fSuper: script := LSL(1, bSuper); INC(i)
        | fSub: script := LSL(1, bSub); INC(i)
        ELSE
          ApplyCode(x, st); snapDirty := TRUE; INC(i)
        END
    | kCenter:
        w := SegWidth(d, i, kEndCenter, 0);
        IF x.a = 0 THEN center := (tL + tR + 1) DIV 2 ELSE center := x.b END;
        IF center - w DIV 2 > col THEN col := center - w DIV 2 END;
        IF x.a = 0 THEN d.it[i].b := center END;
        hasText := TRUE; INC(i)
    | kAlign:
        IF x.a = 0AH THEN
          w := SegWidth(d, i, kEndAlign, 0);
          IF tR + 1 - w > col THEN col := tR + 1 - w END
        ELSE
          w := SegWidth(d, i, kEndAlign, x.a);
          stop := NextTab(st, col);
          d.it[i].b := stop;
          IF stop - w > col THEN col := stop - w END
        END;
        hasText := TRUE; INC(i)
    | kMargin:
        ApplyCode(x, st); snapDirty := TRUE;
        tL := st.lm; tR := st.rm;
        IF ~hasText THEN col := tL END;
        INC(i)
    | kMarRel:
        col := PrevTab(st, col); IF ~hasText & (col < tL) THEN tL := tL END;
        INC(i)
    | kIndent:
        stop := NextTab(st, col);
        d.it[i].a := stop;
        col := stop; tL := stop; INC(i)
    | kLRIndent:
        stop := NextTab(st, col);
        d.it[i].a := stop - col;
        tR := tR - (stop - col); col := stop; tL := stop; INC(i)
    | kNoteNum:
        noteNo := x.a; INC(i)
    | kAttrOn, kAttrOff:
        ApplyCode(x, st); INC(i)
    ELSE
      ApplyCode(x, st); snapDirty := TRUE; INC(i)
    END
  END;
  e.icol[d.n] := col; e.iattr[d.n] := st.attr;
  e.icol[d.n + 1] := col;
  EndLine(e, d.n, brEnd, st, lineStart, col, tL, tR, lastBrk, snapAt, hasText, snapDirty);
  e.endFmt := st
END Layout;

(* ---- pagination ---- *)

PROCEDURE AddPage(e: Ed);
VAR np: Pages; i: INTEGER;
BEGIN
  IF e.npages >= e.pcap THEN
    NEW(np, e.pcap * 2);
    FOR i := 0 TO e.npages - 1 DO np[i] := e.pages[i] END;
    e.pages := np; e.pcap := e.pcap * 2
  END;
  e.pages[e.npages].first := 0; e.pages[e.npages].last := -1;
  e.pages[e.npages].num := 1; e.pages[e.npages].roman := 0; e.pages[e.npages].hard := 0;
  e.pages[e.npages].snap := 0; e.pages[e.npages].center := 0; e.pages[e.npages].suppress := 0;
  e.pages[e.npages].hdrMask := 0; e.pages[e.npages].hdrLines := 0; e.pages[e.npages].ftrLines := 0;
  INC(e.npages)
END AddPage;

(* does header/footer t print on a page with this number? *)
PROCEDURE HdrOn(VAR st: Fmt; t, num: INTEGER): BOOLEAN;
VAR occ: INTEGER;
BEGIN
  occ := st.hdrOcc[t];
  IF st.hdr[t] = NIL THEN RETURN FALSE END;
  RETURN ODD(occ) OR (ODD(occ DIV 2) & ODD(num)) OR (ODD(occ DIV 4) & ~ODD(num))
END HdrOn;

(* half-lines a footnote takes at the bottom of a page *)
PROCEDURE NoteHeight(x: Item; VAR st: Fmt): INTEGER;
VAR h: INTEGER;
BEGIN
  h := 0;
  IF (x.k = kNote) & ~ODD(x.a DIV 2) THEN
    h := CountLines(x.sub) * 2 + 2       (* text + one blank line between notes *)
  END;
  RETURN h
END NoteHeight;

PROCEDURE PageSetup(e: Ed; L, num: INTEGER; VAR hdrUse, ftrUse, cap: INTEGER);
VAR st: Fmt; t, s, h, sup, j: INTEGER; d: Doc;
BEGIN
  d := e.d;
  (* state after the first line of the page *)
  IF L + 1 < e.nlines THEN st := e.snaps[e.lines[L + 1].snap] ELSE st := e.endFmt END;
  sup := 0;
  FOR j := e.lines[L].start TO e.lines[L].end - 1 DO
    IF d.it[j].k = kSuppress THEN sup := d.it[j].a END
  END;
  hdrUse := 0; ftrUse := 0; s := 0;
  FOR t := 0 TO 3 DO
    IF HdrOn(st, t, num) & ~ODD(sup) & ~ODD(sup DIV 8) &
       ~((t = 0) & ODD(sup DIV 16)) & ~((t = 1) & ODD(sup DIV 32)) &
       ~((t = 2) & ODD(sup DIV 64)) & ~((t = 3) & ODD(sup DIV 128)) THEN
      h := CountLines(st.hdr[t]) * 2;
      IF t < 2 THEN hdrUse := hdrUse + h + 2 ELSE ftrUse := ftrUse + h + 2 END;
      s := s + LSL(1, t)
    END
  END;
  e.pages[e.npages - 1].hdrMask := s;
  e.pages[e.npages - 1].hdrLines := hdrUse; e.pages[e.npages - 1].ftrLines := ftrUse;
  e.pages[e.npages - 1].suppress := sup;
  cap := st.textHalf - hdrUse - ftrUse;
  IF (st.pnPos # 0) & ~ODD(sup) & ~ODD(sup DIV 2) THEN cap := cap - 4 END;
  IF cap < 4 THEN cap := 4 END
END PageSetup;

PROCEDURE Paginate(e: Ed);
VAR L, i, used, cap, h, num, roman, pg, need, sup, notes, nh, hdrUse, ftrUse, t, cnt: INTEGER;
    st: Fmt; newPage, firstOnPage, lastPara: BOOLEAN; nextNum, nextRoman: INTEGER;
    d: Doc;



BEGIN
  d := e.d;
  e.npages := 0;
  num := 1; roman := 0; nextNum := -1; nextRoman := 0;
  L := 0; newPage := TRUE; used := 0; cap := 108; notes := 0;
  WHILE L < e.nlines DO
    IF newPage THEN
      AddPage(e); pg := e.npages - 1;
      e.pages[pg].first := L; e.pages[pg].snap := e.lines[L].snap;
      (* page number codes on the first line of the page apply to it *)
      FOR i := e.lines[L].start TO e.lines[L].end - 1 DO
        IF d.it[i].k = kPgNum THEN num := d.it[i].a; roman := d.it[i].b; nextNum := -1 END;
        IF (d.it[i].k = kSingle) & (d.it[i].a = fCenterPg) THEN e.pages[pg].center := 1 END
      END;
      IF nextNum >= 0 THEN num := nextNum; roman := nextRoman; nextNum := -1 END;
      e.pages[pg].num := num; e.pages[pg].roman := roman;
      PageSetup(e, L, num, hdrUse, ftrUse, cap);
      used := 0; notes := 0; newPage := FALSE; firstOnPage := TRUE
    END;
    st := e.snaps[e.lines[L].snap];
    h := e.lines[L].height; IF h < 1 THEN h := 2 END;
    (* notes referenced on this line *)
    nh := 0;
    FOR i := e.lines[L].start TO e.lines[L].end - 1 DO
      nh := nh + NoteHeight(d.it[i], st);
      IF (d.it[i].k = kPgNum) & (L # e.pages[pg].first) THEN nextNum := d.it[i].a; nextRoman := d.it[i].b END
    END;
    IF (nh > 0) & (notes = 0) THEN nh := nh + 2 END;    (* separator line *)
    need := h;
    (* conditional end of page and block protect *)
    FOR i := e.lines[L].start TO e.lines[L].end - 1 DO
      IF d.it[i].k = kCondEOP THEN
        IF d.it[i].a * 2 > need THEN need := d.it[i].a * 2 END
      ELSIF (d.it[i].k = kBlockPro) & (d.it[i].a = 0) THEN
        cnt := 0; t := L;
        WHILE (t < e.nlines) & (cnt < 200) DO
          FOR i := e.lines[t].start TO e.lines[t].end - 1 DO
            IF (d.it[i].k = kBlockPro) & (d.it[i].a = 1) THEN cnt := 1000 END
          END;
          IF cnt < 1000 THEN need := need + e.lines[t].height END;
          INC(t); INC(cnt)
        END
      END
    END;
    (* widow/orphan protection *)
    IF st.widow & ~firstOnPage THEN
      lastPara := (L > 0) & (e.lines[L - 1].brk # brSoft);
      IF lastPara & (e.lines[L].brk = brSoft) & (L + 1 < e.nlines) THEN
        need := h + e.lines[L + 1].height                   (* first line of a paragraph *)
      ELSIF (e.lines[L].brk # brSoft) & (L > 0) & (e.lines[L - 1].brk = brSoft) &
            (used + h + nh > cap) & (L - 1 > e.pages[pg].first) THEN
        (* last line of a paragraph would be alone: take the line before too *)
        e.pages[pg].last := L - 2;
        L := L - 1; newPage := TRUE; num := num + 1
      END
    END;
    IF ~newPage THEN
      IF ~firstOnPage & (used + need + nh + notes > cap) THEN
        e.pages[pg].last := L - 1; newPage := TRUE; num := num + 1
      ELSE
        e.lines[L].page := pg; e.lines[L].ln := used;
        used := used + h; notes := notes + nh; firstOnPage := FALSE;
        IF e.lines[L].brk = brPage THEN
          e.pages[pg].last := L; e.pages[pg].hard := 1; newPage := TRUE; num := num + 1
        END;
        INC(L)
      END
    END
  END;
  IF e.npages = 0 THEN AddPage(e) END;
  IF ~newPage THEN e.pages[e.npages - 1].last := e.nlines - 1 END;
  IF (e.pages[e.npages - 1].last < e.pages[e.npages - 1].first) & (e.npages > 1) THEN
    e.pages[e.npages - 1].last := e.pages[e.npages - 1].first
  END
END Paginate;

(* ---- display rows ---- *)

PROCEDURE AddRow(e: Ed; kind, line, x: INTEGER);
VAR nr: Rows; i: INTEGER;
BEGIN
  IF e.nrows >= e.rcap THEN
    NEW(nr, e.rcap * 2);
    FOR i := 0 TO e.nrows - 1 DO nr[i] := e.rows[i] END;
    e.rows := nr; e.rcap := e.rcap * 2
  END;
  e.rows[e.nrows].kind := kind; e.rows[e.nrows].line := line; e.rows[e.nrows].x := x;
  INC(e.nrows)
END AddRow;

PROCEDURE CommentRows(e: Ed; L, i: INTEGER);
VAR k, n: INTEGER;
BEGIN
  AddRow(e, rCmtTop, L, i);
  n := CountLines(e.d.it[i].sub);
  FOR k := 0 TO n - 1 DO AddRow(e, rCmtText, L, i * 64 + k) END;
  AddRow(e, rCmtBot, L, i)
END CommentRows;

PROCEDURE BuildRows(e: Ed);
VAR L, i, k, first: INTEGER; d: Doc;
BEGIN
  d := e.d;
  e.nrows := 0;
  FOR L := 0 TO e.nlines - 1 DO
    (* comments ahead of the line's first text show above it *)
    first := e.lines[L].start;
    WHILE (first < e.lines[L].end) & (ItemWidth(d.it[first]) = 0) & (d.it[first].k # kTab) &
          (d.it[first].k # kHRt) & (d.it[first].k # kHPg) DO
      IF (d.it[first].k = kComment) & (d.it[first].a = 0) THEN CommentRows(e, L, first) END;
      INC(first)
    END;
    e.lines[L].row := e.nrows;
    AddRow(e, rText, L, 0);
    IF ~e.isSub THEN
      FOR k := 2 TO e.lines[L].height DIV 2 DO AddRow(e, rBlank, L, 0) END
    END;
    FOR i := first TO e.lines[L].end - 1 DO
      IF (d.it[i].k = kComment) & (d.it[i].a = 0) THEN CommentRows(e, L, i) END
    END;
    IF ~e.isSub & (L + 1 < e.nlines) & (e.lines[L + 1].page # e.lines[L].page) THEN
      IF e.lines[L].brk = brPage THEN AddRow(e, rHardPg, L, 0) ELSE AddRow(e, rSoftPg, L, 0) END
    ELSIF e.lines[L].brk = brPage THEN AddRow(e, rHardPg, L, 0)
    END
  END
END BuildRows;

PROCEDURE Reformat(e: Ed);
BEGIN
  Layout(e);
  IF ~e.isSub THEN Paginate(e)
  ELSE
    e.npages := 0; AddPage(e); e.pages[0].last := e.nlines - 1
  END;
  BuildRows(e);
  e.dirty := FALSE
END Reformat;

(* line holding item index i (binary search) *)
PROCEDURE LineOf(e: Ed; i: INTEGER): INTEGER;
VAR lo, hi, mid: INTEGER;
BEGIN
  lo := 0; hi := e.nlines - 1;
  WHILE lo < hi DO
    mid := (lo + hi + 1) DIV 2;
    IF e.lines[mid].start <= i THEN lo := mid ELSE hi := mid - 1 END
  END;
  (* an empty last line starts at d.n *)
  RETURN lo
END LineOf;

PROCEDURE PageOf(e: Ed; i: INTEGER): INTEGER;
BEGIN RETURN e.lines[LineOf(e, i)].page
END PageOf;

(* last valid cursor position on line L *)
PROCEDURE LineLast(e: Ed; L: INTEGER): INTEGER;
BEGIN
  IF e.lines[L].brk = brEnd THEN RETURN e.lines[L].end
  ELSIF e.lines[L].end > e.lines[L].start THEN RETURN e.lines[L].end - 1
  ELSE RETURN e.lines[L].start
  END
END LineLast;

(* soft line ends, for the writers *)
PROCEDURE MarkSoft(e: Ed);
VAR L, i: INTEGER;
BEGIN
  IF (softAt = NIL) OR (softCap < e.d.n + 1) THEN
    softCap := e.d.n + 1024; NEW(softAt, softCap); NEW(tabPos, softCap)
  END;
  FOR i := 0 TO e.d.n DO softAt[i] := 0; tabPos[i] := 0 END;
  FOR L := 0 TO e.nlines - 1 DO
    IF (e.lines[L].brk = brSoft) & (e.lines[L].end > e.lines[L].start) THEN
      i := e.lines[L].end - 1;
      IF (e.d.it[i].k = kChar) & (e.d.it[i].ch = " ") THEN softAt[i] := 1 END
    END
  END;
  FOR i := 0 TO e.d.n - 1 DO
    IF e.d.it[i].k = kTab THEN tabPos[i] := e.icol[i + 1] END
  END
END MarkSoft;

(* ====================================================================
   Code names, as Reveal Codes shows them
   ==================================================================== *)

PROCEDURE AttrName(a: INTEGER; on: BOOLEAN; VAR s: ARRAY OF CHAR);
BEGIN
  CASE a OF
    aBold: IF on THEN Cpy("B", s) ELSE Cpy("b", s) END
  | aUnd: IF on THEN Cpy("U", s) ELSE Cpy("u", s) END
  | aRed: IF on THEN Cpy("RedLn", s) ELSE Cpy("r", s) END
  | aStrike: IF on THEN Cpy("StrkOut", s) ELSE Cpy("s", s) END
  | aItal: IF on THEN Cpy("I", s) ELSE Cpy("i", s) END
  | aShadow: IF on THEN Cpy("Shdw", s) ELSE Cpy("shdw", s) END
  | aOutline: IF on THEN Cpy("Otln", s) ELSE Cpy("otln", s) END
  | aRev: IF on THEN Cpy("Rev", s) ELSE Cpy("rev", s) END
  ELSE Cpy("?", s)
  END
END AttrName;

PROCEDURE SubExcerpt(d: Doc; VAR s: ARRAY OF CHAR; max: INTEGER);
VAR t: ARRAY 1024 OF CHAR; i: INTEGER;
BEGIN
  DocText(d, t);
  i := 0;
  WHILE (t[i] # 0X) & (i < max) DO
    IF t[i] = 0AX THEN t[i] := " " END;
    INC(i)
  END;
  IF i >= max THEN t[max] := 0X; Append("...", t) END;
  Append(t, s)
END SubExcerpt;

(* the bracketed name of a code, without the brackets *)
PROCEDURE CodeName(VAR x: Item; VAR s: ARRAY OF CHAR);
VAR t: Str; i: INTEGER;
BEGIN
  s[0] := 0X;
  CASE x.k OF
    kHRt: Cpy("HRt", s)
  | kHPg: Cpy("HPg", s)
  | kTab: Cpy("TAB", s)
  | kAttrOn: AttrName(x.a, TRUE, s)
  | kAttrOff: AttrName(x.a, FALSE, s)
  | kCenter: Cpy("C", s)
  | kEndCenter: Cpy("c", s)
  | kAlign: IF x.a = 0AH THEN Cpy("A", s) ELSE Cpy("A", s) END
  | kEndAlign: Cpy("a", s)
  | kMargin: Cpy("Margin Set:", s); AppendInt(x.a, s); AppendCh(",", s); AppendInt(x.b, s)
  | kSpacing: Cpy("Spacing Set:", s); AppendInt(x.a DIV 2, s);
      IF ODD(x.a) THEN Append(".5", s) END
  | kMarRel: Cpy("<-Mar Rel:", s); AppendInt(x.a, s)
  | kHZone: Cpy("H-Zone:", s); AppendInt(x.a, s); AppendCh(",", s); AppendInt(x.b, s)
  | kPnPos: Cpy("Pos Pg#:", s); AppendInt(x.a, s)
  | kPgNum: Cpy("Pg#:", s);
      IF x.b = 1 THEN Roman(x.a, t); Append(t, s) ELSE AppendInt(x.a, s) END
  | kPnCol: Cpy("Pg# Col:", s); AppendInt(x.a, s); AppendCh(",", s); AppendInt(x.b, s);
      AppendCh(",", s); AppendInt(x.c, s)
  | kCondEOP: Cpy("CndlEOP:", s); AppendInt(x.a, s)
  | kFont: Cpy("Font Change:", s); AppendInt(ABS(x.a), s);
      IF x.a < 0 THEN AppendCh("*", s) END; AppendCh(",", s); AppendInt(x.b, s)
  | kIndent: Cpy("->Indent", s)
  | kLRIndent: Cpy("->Indent<-", s)
  | kTopMar: Cpy("Top Mar:", s); AppendInt(x.a, s)
  | kSuppress: Cpy("Suppress:", s); AppendInt(x.a, s)
  | kFormLen: Cpy("Pg Lnth:", s); AppendInt(x.a, s); AppendCh(",", s); AppendInt(x.b DIV 2, s)
  | kHdrFtr:
      Cpy("Hdr/Ftr:", s); AppendInt(x.a MOD 4 + 1, s); AppendCh(",", s); AppendInt(x.a DIV 4, s);
      AppendCh(";", s); SubExcerpt(x.sub, s, 40)
  | kAdvLn: Cpy("AdvLn:", s); AppendInt(x.a, s)
  | kLPI: Cpy("LPI:", s); AppendInt(x.a, s)
  | kMathDef: Cpy("Math Def", s)
  | kAlignChar: Cpy("Align Char:", s); AppendCh(CHR(x.a), s)
  | kUndMode: Cpy("Undrl Style:", s); AppendInt(x.a, s)
  | kBin: Cpy("Bin#:", s); AppendInt(x.a, s)
  | kPrnCmd:
      Cpy("Cmnd:", s);
      IF x.s # NIL THEN
        FOR i := 0 TO x.sl - 1 DO
          IF (ORD(x.s[i]) < 32) OR (ORD(x.s[i]) > 126) THEN
            AppendCh("<", s); AppendInt(ORD(x.s[i]), s); AppendCh(">", s)
          ELSE AppendCh(x.s[i], s)
          END
        END
      END
  | kNote:
      IF ODD(x.a DIV 2) THEN Cpy("Note:End,", s) ELSE Cpy("Note:Foot,", s) END;
      AppendInt(x.b, s); Append(";[Note #]", s); SubExcerpt(x.sub, s, 45)
  | kNoteOpt: Cpy("Ftn Opt", s)
  | kNoteNum: Cpy("Set Note #:", s); AppendInt(x.a, s)
  | kDate: Cpy("Date:", s); GetStr(x, t); Append(t, s)
  | kBlockPro: IF x.a = 0 THEN Cpy("BlockPro:On", s) ELSE Cpy("BlockPro:Off", s) END
  | kComment: IF x.a = 0 THEN Cpy("Comment", s) ELSE Cpy("Smry/Cmnt", s) END
  | kTabSet: Cpy("Tab Set", s)
  | kLineNum: IF x.a >= 128 THEN Cpy("Ln Num:On", s) ELSE Cpy("Ln Num:Off", s) END
  | kMark:
      IF x.b DIV 16 = 0 THEN Cpy("ToC", s) ELSE Cpy("List", s) END;
      IF x.a = 1 THEN Append(" Mark:", s) ELSE Append(" End Mark:", s) END;
      AppendInt(x.b MOD 16 + 1, s)
  | kDefMark: Cpy("Def Mark", s)
  | kRaw: Cpy("Function:", s); IntStr(x.a, t); Append(t, s)
  | kRaw5: Cpy("WP5:", s); IntStr(x.a, t); Append(t, s)
  | kSingle:
      CASE x.a OF
        fJustOn: Cpy("Rt Just On", s) | fJustOff: Cpy("Rt Just Off", s)
      | fCenterPg: Cpy("Center Pg", s) | fColOn: Cpy("Col On", s) | fColOff: Cpy("Col Off", s)
      | fWOOn: Cpy("W/O On", s) | fWOOff: Cpy("W/O Off", s)
      | fNoteNum: Cpy("Note #", s) | fToC: Cpy("Def Mark", s)
      | fOvrstk: Cpy("Ovrstk", s) | fNoHyph: Cpy("/", s) | fEndGen: Cpy("End Gen", s)
      | fHyphOff: Cpy("Hyph Off", s) | fHyphOn: Cpy("Hyph On", s)
      | fHardSp: Cpy(" ", s) | fDoSub: Cpy("+", s) | fSubEnt: Cpy("t", s)
      | fDoTot: Cpy("=", s) | fTotEnt: Cpy("T", s) | fDoGrand: Cpy("*", s)
      | fCalcCol: Cpy("!", s) | fMathOn: Cpy("Math On", s) | fMathOff: Cpy("Math Off", s)
      | fHardHy: Cpy("-", s) | fSoftHy: Cpy("^", s) | fNeg: Cpy("N", s)
      | fSuper: Cpy("SuprScrpt", s) | fSub: Cpy("SubScrpt", s)
      | fAdvUp: Cpy("AdvUp", s) | fAdvDn: Cpy("AdvDn", s)
      ELSE Cpy("Function:", s); AppendInt(x.a, s)
      END
  ELSE Cpy("?", s)
  END
END CodeName;

(* longer description used in "Delete [x]? (Y/N) N" *)
PROCEDURE CodeTitle(VAR x: Item; VAR s: ARRAY OF CHAR);
BEGIN
  CASE x.k OF
    kAttrOn, kAttrOff:
      CASE x.a OF
        aBold: Cpy("Bold", s) | aUnd: Cpy("Undrln", s) | aRed: Cpy("RedLn", s)
      | aStrike: Cpy("StrkOut", s) | aItal: Cpy("Italc", s)
      ELSE CodeName(x, s)
      END
  | kCenter, kEndCenter: Cpy("Cntr", s)
  | kAlign, kEndAlign: IF x.a = 0AH THEN Cpy("FlshRt", s) ELSE Cpy("Align", s) END
  | kNote: Cpy("Note", s)
  ELSE CodeName(x, s)
  END
END CodeTitle;

(* ====================================================================
   Editors and saving
   ==================================================================== *)

PROCEDURE NewEd(num: INTEGER): Ed;
VAR x: Ed;
BEGIN
  NEW(x);
  x.d := NewDoc(); x.name[0] := 0X; x.num := num;
  x.fmt0 := cfg.fmt;
  x.cur := 0; x.goal := -1; x.top := 0; x.hscroll := 0; x.anchor := -1;
  x.typeover := cfg.typeover; x.modified := FALSE; x.dirty := TRUE;
  x.srcFmt := fmtNew; x.isSub := FALSE; x.subTitle[0] := 0X;
  x.icol := NIL; x.icap := 0; x.lines := NIL; x.snaps := NIL; x.pages := NIL; x.rows := NIL;
  x.nlines := 0; x.nsnaps := 0; x.npages := 0; x.nrows := 0;
  RETURN x
END NewEd;

PROCEDURE SubEd(d: Doc; title: ARRAY OF CHAR; lm, rm: INTEGER): Ed;
VAR x: Ed;
BEGIN
  x := NewEd(0); x.d := d; x.isSub := TRUE; Cpy(title, x.subTitle);
  x.fmt0.lm := lm; x.fmt0.rm := rm;
  RETURN x
END SubEd;

PROCEDURE Ensure(x: Ed);
BEGIN
  IF x.dirty OR (x.lines = NIL) THEN Reformat(x) END
END Ensure;

(* the document as formatted lines of text (codes dropped) *)
PROCEDURE LineText(x: Ed; L: INTEGER; VAR s: ARRAY OF CHAR);
VAR i, c, j, n: INTEGER; g: Str; it: Item;
BEGIN
  n := 0;
  FOR i := x.lines[L].start TO x.lines[L].end - 1 DO
    it := x.d.it[i];
    IF (it.k = kChar) OR (it.k = kCtl) OR (it.k = kNote) OR (it.k = kDate) OR
       ((it.k = kSingle) & (ItemWidth(it) > 0)) THEN
      c := x.icol[i] - x.lines[L].lm;
      IF c < 0 THEN c := 0 END;
      WHILE (n < c) & (n < LEN(s) - 2) DO s[n] := " "; INC(n) END;
      IF it.k = kChar THEN
        IF (n = c) & (n < LEN(s) - 2) THEN s[n] := it.ch; INC(n)
        ELSIF (n = c + 1) & (n > 0) THEN s[n - 1] := it.ch     (* overstrike *)
        END
      ELSE
        GenText(it, g); j := 0;
        WHILE (g[j] # 0X) & (n < LEN(s) - 2) DO s[n] := g[j]; INC(n); INC(j) END
      END
    END
  END;
  (* trailing spaces off *)
  WHILE (n > 0) & (s[n - 1] = " ") DO DEC(n) END;
  s[n] := 0X
END LineText;

(* DOS text: one line per formatted line, in UTF-8 *)
PROCEDURE BuildText(x: Ed);
VAR L, i, k: INTEGER; s: ARRAY 2048 OF CHAR;
BEGIN
  Ensure(x);
  ObReset;
  FOR L := 0 TO x.nlines - 1 DO
    IF (L < x.nlines - 1) OR (x.lines[L].end > x.lines[L].start) THEN
      LineText(x, L, s);
      FOR k := 0 TO x.lines[L].lm - cfg.fmt.lm - 1 DO Put(ORD(" ")) END;
      i := 0; WHILE s[i] # 0X DO PutUtf8(s[i]); INC(i) END;
      IF (L < x.nlines - 1) OR (x.lines[L].brk # brEnd) THEN Put(0AH) END
    END
  END
END BuildText;

(* build the file image of x in format fmt into the output buffer *)
PROCEDURE BuildFile(x: Ed; fmt: INTEGER);
VAR st: Fmt;
BEGIN
  Ensure(x);
  MarkSoft(x);
  ObReset;
  st := x.fmt0;
  IF fmt = fmtWP5 THEN Header5; Write5(x.d, st, TRUE)
  ELSIF fmt = fmtText THEN BuildText(x)
  ELSE Write42(x.d, st, TRUE)
  END
END BuildFile;

PROCEDURE BackupName(name: ARRAY OF CHAR; VAR bk: ARRAY OF CHAR);
VAR i: INTEGER; b: Path;
BEGIN
  Cpy(name, bk);
  BaseName(name, b);
  i := SLen(bk);
  IF Find(".", b, 0) >= 0 THEN
    WHILE (i > 0) & (bk[i - 1] # ".") DO DEC(i) END;
    bk[i - 1] := 0X
  END;
  Append(".BK!", bk)
END BackupName;

(* save x to name in fmt; pw # "" makes a locked WP 4.2 document *)
PROCEDURE SaveFile(x: Ed; name: ARRAY OF CHAR; fmt: INTEGER; pw: ARRAY OF CHAR): BOOLEAN;
VAR bk: Path; i, cs: INTEGER;
BEGIN
  BuildFile(x, fmt);
  IF (pw[0] # 0X) & (fmt = fmtWP42) THEN
    (* prefix FE FF 61 61 + checksum, then encrypt *)
    Put(0); Put(0); Put(0); Put(0); Put(0); Put(0);
    FOR i := obLen - 1 TO 6 BY -1 DO ob[i] := ob[i - 6] END;
    ob[0] := 0FEX; ob[1] := 0FFX; ob[2] := 61X; ob[3] := 61X;
    cs := PwChecksum(pw); ob[4] := CHR(cs MOD 256); ob[5] := CHR(cs DIV 256);
    Crypt(ob^, 6, obLen, pw)
  END;
  IF cfg.origBackup & Exists(name) & ~x.isSub THEN
    BackupName(name, bk);
    IF Exists(bk) THEN Files.Delete(bk) END;
    Files.Rename(name, bk)
  END;
  RETURN WriteOb(name)
END SaveFile;

(* ====================================================================
   Settings (the Set-up menu writes them to ~/.config/obperfect/wp.set)
   ==================================================================== *)

PROCEDURE InitSettings;
VAR i: INTEGER; home: Path;
BEGIN
  InitFmt(cfg.fmt);
  Cpy("3 1, 4", cfg.dateFmt);
  cfg.typeover := FALSE; cfg.escN := 8; cfg.backupMin := 0;
  cfg.origBackup := FALSE; cfg.summaryOnSave := FALSE; cfg.autoRewrite := TRUE;
  cfg.showName := TRUE; cfg.beepErr := FALSE; cfg.beepSearch := FALSE; cfg.beepHyph := TRUE;
  cfg.hrtChar := 32;
  Cpy("/usr/share/dict/words", cfg.lexPath);
  Args.GetEnv("HOME", home);
  JoinPath(home, ".config/obperfect", cfgDir);
  JoinPath(cfgDir, "wplex.sup", cfg.supPath);
  cfg.thPath[0] := 0X;
  cfg.printer := 1; cfg.copies := 1; cfg.binding := 0;
  FOR i := 0 TO 6 DO cfg.prnName[i][0] := 0X; cfg.prnPort[i][0] := 0X END;
  Cpy("Standard Printer", cfg.prnName[1]); Cpy("LPT1", cfg.prnPort[1]);
  Cpy("DOS Text Printer", cfg.prnName[6]); Cpy("DOS.TXT", cfg.prnPort[6]);
  cfg.fnSpacing := 1; cfg.fnBetween := 1; cfg.fnKeep := 3; cfg.fnLine := 1;
  cfg.colors := 1; ApplyColors;
  FOR i := 0 TO 25 DO cfg.altMap[i] := 0X END
END InitSettings;

PROCEDURE ApplyColors;
BEGIN
  CASE cfg.colors OF
    2: cBg := TUI.Black; cFg := TUI.White; cHi := TUI.BrightWhite
  | 3: cBg := TUI.Black; cFg := TUI.Green; cHi := TUI.BrightGreen
  | 4: cBg := TUI.Black; cFg := TUI.Yellow; cHi := TUI.BrightWhite
  ELSE cBg := TUI.Blue; cFg := TUI.White; cHi := TUI.BrightWhite
  END
END ApplyColors;

PROCEDURE SetPath(VAR p: ARRAY OF CHAR);
BEGIN JoinPath(cfgDir, "wp.set", p)
END SetPath;

PROCEDURE PutKV(key: ARRAY OF CHAR; v: INTEGER);
BEGIN PutStr(key); Put(ORD("=")); IntStr(v, msg); PutStr(msg); Put(10)
END PutKV;

PROCEDURE PutKS(key, v: ARRAY OF CHAR);
BEGIN PutStr(key); Put(ORD("=")); PutStr(v); Put(10)
END PutKS;

PROCEDURE B2I(b: BOOLEAN): INTEGER;
BEGIN IF b THEN RETURN 1 ELSE RETURN 0 END
END B2I;

PROCEDURE SaveSettings;
VAR p: Path; i: INTEGER; tb: ARRAY 52 OF CHAR; t: ARRAY 120 OF CHAR; k: Str;
BEGIN
  Cpy("mkdir -p ", p); AppendCh(22X, p); Append(cfgDir, p); AppendCh(22X, p);
  i := OS.Exec(p);
  ObReset;
  PutStr("# obperfect set-up file"); Put(10);
  PutKV("lm", cfg.fmt.lm); PutKV("rm", cfg.fmt.rm); PutKV("spacing", cfg.fmt.spacing);
  PutKV("align", cfg.fmt.alignCh); PutKV("just", B2I(cfg.fmt.just));
  PutKV("widow", B2I(cfg.fmt.widow)); PutKV("pnpos", cfg.fmt.pnPos);
  PutKV("pnl", cfg.fmt.pnL); PutKV("pnc", cfg.fmt.pnC); PutKV("pnr", cfg.fmt.pnR);
  PutKV("top", cfg.fmt.topMar); PutKV("form", cfg.fmt.formLen); PutKV("text", cfg.fmt.textHalf);
  PutKV("lpi", cfg.fmt.lpi); PutKV("pitch", cfg.fmt.pitch); PutKV("font", cfg.fmt.font);
  PutKV("undmode", cfg.fmt.undMode); PutKV("hzl", cfg.fmt.hzL); PutKV("hzr", cfg.fmt.hzR);
  TabsToBytes(cfg.fmt, tb);
  t[0] := 0X;
  FOR i := 0 TO 51 DO AppendInt(ORD(tb[i]), t); AppendCh(",", t) END;
  PutKS("tabs", t);
  PutKS("datefmt", cfg.dateFmt);
  PutKV("typeover", B2I(cfg.typeover)); PutKV("escn", cfg.escN);
  PutKV("backupmin", cfg.backupMin); PutKV("origbackup", B2I(cfg.origBackup));
  PutKV("summary", B2I(cfg.summaryOnSave)); PutKV("autorewrite", B2I(cfg.autoRewrite));
  PutKV("showname", B2I(cfg.showName)); PutKV("hrtchar", cfg.hrtChar);
  PutKV("beeperr", B2I(cfg.beepErr)); PutKV("beepsearch", B2I(cfg.beepSearch));
  PutKS("lex", cfg.lexPath); PutKS("sup", cfg.supPath); PutKS("th", cfg.thPath);
  PutKV("colors", cfg.colors);
  t[0] := 0X;
  FOR i := 0 TO 25 DO AppendInt(ORD(cfg.altMap[i]), t); AppendCh(",", t) END;
  PutKS("altmap", t);
  PutKV("printer", cfg.printer); PutKV("copies", cfg.copies); PutKV("binding", cfg.binding);
  FOR i := 1 TO 6 DO
    Cpy("prnname", k); AppendInt(i, k); PutKS(k, cfg.prnName[i]);
    Cpy("prnport", k); AppendInt(i, k); PutKS(k, cfg.prnPort[i])
  END;
  SetPath(p);
  IF WriteOb(p) THEN END
END SaveSettings;

PROCEDURE LoadSettings;
VAR p: Path; buf: Bytes; len, i, j, v, n: INTEGER; key: Str; val: Path; tb: ARRAY 52 OF CHAR;
  num: Str; ok: BOOLEAN;
BEGIN
  SetPath(p);
  IF ~LoadFile(p, buf, len) THEN RETURN END;
  i := 0;
  WHILE i < len DO
    j := 0;
    WHILE (i < len) & (buf[i] # "=") & (buf[i] # 0AX) DO
      IF j < 255 THEN key[j] := buf[i]; INC(j) END; INC(i)
    END;
    key[j] := 0X;
    j := 0;
    IF (i < len) & (buf[i] = "=") THEN INC(i) END;
    WHILE (i < len) & (buf[i] # 0AX) DO
      IF j < MaxPath - 1 THEN val[j] := buf[i]; INC(j) END; INC(i)
    END;
    val[j] := 0X; INC(i);
    ok := StrInt(val, v);
    IF key[0] = "#" THEN
    ELSIF StrEq(key, "lm") THEN cfg.fmt.lm := v
    ELSIF StrEq(key, "rm") THEN cfg.fmt.rm := v
    ELSIF StrEq(key, "spacing") THEN cfg.fmt.spacing := v
    ELSIF StrEq(key, "align") THEN cfg.fmt.alignCh := v
    ELSIF StrEq(key, "just") THEN cfg.fmt.just := v = 1
    ELSIF StrEq(key, "widow") THEN cfg.fmt.widow := v = 1
    ELSIF StrEq(key, "pnpos") THEN cfg.fmt.pnPos := v
    ELSIF StrEq(key, "pnl") THEN cfg.fmt.pnL := v
    ELSIF StrEq(key, "pnc") THEN cfg.fmt.pnC := v
    ELSIF StrEq(key, "pnr") THEN cfg.fmt.pnR := v
    ELSIF StrEq(key, "top") THEN cfg.fmt.topMar := v
    ELSIF StrEq(key, "form") THEN cfg.fmt.formLen := v
    ELSIF StrEq(key, "text") THEN cfg.fmt.textHalf := v
    ELSIF StrEq(key, "lpi") THEN cfg.fmt.lpi := v
    ELSIF StrEq(key, "pitch") THEN cfg.fmt.pitch := v
    ELSIF StrEq(key, "font") THEN cfg.fmt.font := v
    ELSIF StrEq(key, "undmode") THEN cfg.fmt.undMode := v
    ELSIF StrEq(key, "hzl") THEN cfg.fmt.hzL := v
    ELSIF StrEq(key, "hzr") THEN cfg.fmt.hzR := v
    ELSIF StrEq(key, "tabs") THEN
      n := 0; j := 0;
      WHILE (val[j] # 0X) & (n < 52) DO
        num[0] := 0X;
        WHILE (val[j] # 0X) & (val[j] # ",") DO AppendCh(val[j], num); INC(j) END;
        IF val[j] = "," THEN INC(j) END;
        IF StrInt(num, v) THEN tb[n] := CHR(v) ELSE tb[n] := 0X END;
        INC(n)
      END;
      IF n = 52 THEN BytesToTabs(tb, 0, cfg.fmt) END
    ELSIF StrEq(key, "datefmt") THEN Cpy(val, cfg.dateFmt)
    ELSIF StrEq(key, "typeover") THEN cfg.typeover := v = 1
    ELSIF StrEq(key, "escn") THEN cfg.escN := v
    ELSIF StrEq(key, "backupmin") THEN cfg.backupMin := v
    ELSIF StrEq(key, "origbackup") THEN cfg.origBackup := v = 1
    ELSIF StrEq(key, "summary") THEN cfg.summaryOnSave := v = 1
    ELSIF StrEq(key, "autorewrite") THEN cfg.autoRewrite := v = 1
    ELSIF StrEq(key, "showname") THEN cfg.showName := v = 1
    ELSIF StrEq(key, "hrtchar") THEN cfg.hrtChar := v
    ELSIF StrEq(key, "beeperr") THEN cfg.beepErr := v = 1
    ELSIF StrEq(key, "beepsearch") THEN cfg.beepSearch := v = 1
    ELSIF StrEq(key, "lex") THEN Cpy(val, cfg.lexPath)
    ELSIF StrEq(key, "sup") THEN Cpy(val, cfg.supPath)
    ELSIF StrEq(key, "th") THEN Cpy(val, cfg.thPath)
    ELSIF StrEq(key, "colors") THEN cfg.colors := v; ApplyColors
    ELSIF StrEq(key, "altmap") THEN
      n := 0; j := 0;
      WHILE (val[j] # 0X) & (n < 26) DO
        num[0] := 0X;
        WHILE (val[j] # 0X) & (val[j] # ",") DO AppendCh(val[j], num); INC(j) END;
        IF val[j] = "," THEN INC(j) END;
        IF StrInt(num, v) THEN cfg.altMap[n] := CHR(v) END;
        INC(n)
      END
    ELSIF StrEq(key, "printer") THEN cfg.printer := v
    ELSIF StrEq(key, "copies") THEN cfg.copies := v
    ELSIF StrEq(key, "binding") THEN cfg.binding := v
    ELSIF (Find("prnname", key, 0) = 0) & (key[7] >= "1") & (key[7] <= "6") THEN
      Cpy(val, cfg.prnName[ORD(key[7]) - ORD("0")])
    ELSIF (Find("prnport", key, 0) = 0) & (key[7] >= "1") & (key[7] <= "6") THEN
      Cpy(val, cfg.prnPort[ORD(key[7]) - ORD("0")])
    END
  END
END LoadSettings;

(* ====================================================================
   Keyboard.  Keys are integers:
     32..126           ASCII characters, 1..31 control characters
     KExt + b          a code page 437 character above 7FH
     KF + 100*m + n    function key Fn with modifiers m (1 Shift, 2 Alt, 4 Ctrl)
     KNav + 100*m + c  cursor keys (nUp ... nTab)
     KAlt + c          Alt+letter
   Macros record and replay these numbers.
   ==================================================================== *)

PROCEDURE Beep;
BEGIN
  IF cfg.beepErr THEN Out.Char(07X); Out.Flush END
END Beep;

PROCEDURE RawKey(): INTEGER;
VAR c: CHAR; o, m, u, need, b: INTEGER; a: CHAR;
BEGIN
  c := Terminal.ReadKey(); m := Terminal.Modifiers(); o := ORD(c);
  IF o = 27 THEN
    a := Terminal.AltChar();
    IF (a >= "a") & (a <= "z") THEN RETURN KAlt + ORD(a)
    ELSIF (a >= "A") & (a <= "Z") THEN RETURN KAlt + ORD(a) + 32
    ELSIF (a >= "0") & (a <= "9") THEN RETURN KAlt + ORD(a)
    ELSIF a = 7FX THEN RETURN KCtrlBS
    END;
    RETURN KEsc
  ELSIF o = 7FH THEN RETURN KBS
  ELSIF o = 09H THEN
    IF ODD(m) THEN RETURN KNav + 100 + nTab ELSE RETURN KTab END
  ELSIF (o >= 80H) & (o <= 88H) THEN
    CASE o OF
      80H: RETURN KNav + 100 * m + nPgUp
    | 81H: RETURN KNav + 100 * m + nPgDn
    | 82H: RETURN KNav + 100 * m + nHome
    | 83H: RETURN KNav + 100 * m + nEnd
    | 84H: RETURN KNav + 100 * m + nDel
    | 85H: RETURN KNav + 400 + nLeft
    | 86H: RETURN KNav + 400 + nRight
    | 87H: RETURN KNav + 400 + nHome
    | 88H: RETURN KNav + 400 + nEnd
    END
  ELSIF (o >= 89H) & (o <= 94H) THEN RETURN KF + 100 * m + (o - 88H)
  ELSIF (o >= 0A0H) & (o <= 0A3H) THEN
    CASE o OF
      0A0H: RETURN KNav + 100 * m + nUp
    | 0A1H: RETURN KNav + 100 * m + nDown
    | 0A2H: RETURN KNav + 100 * m + nLeft
    | 0A3H: RETURN KNav + 100 * m + nRight
    END
  ELSIF (o >= 0A5H) & (o <= 0A8H) THEN
    CASE o OF
      0A5H: RETURN KNav + 100 + nUp
    | 0A6H: RETURN KNav + 100 + nDown
    | 0A7H: RETURN KNav + 100 + nLeft
    | 0A8H: RETURN KNav + 100 + nRight
    END
  ELSIF o = 0A9H THEN RETURN KNav + 100 * m + nIns
  ELSIF o = 0A4H THEN
    mouseX := Terminal.MouseX(); mouseY := Terminal.MouseY(); mouseB := Terminal.MouseBtn();
    RETURN KMouse
  ELSIF o >= 0C0H THEN
    (* UTF-8 sequence: map to code page 437 *)
    IF o >= 0F0H THEN u := o MOD 8; need := 3
    ELSIF o >= 0E0H THEN u := o MOD 16; need := 2
    ELSE u := o MOD 32; need := 1
    END;
    WHILE need > 0 DO
      b := ORD(Terminal.ReadKey()); u := u * 64 + b MOD 64; DEC(need)
    END;
    b := UniToCp(u);
    IF b < 0 THEN RETURN 0 END;
    IF b < 128 THEN RETURN b END;
    RETURN KExt + b
  END;
  RETURN o
END RawKey;

PROCEDURE MacroStop;
BEGIN
  qHead := 0; qTail := 0; macroRep := 0
END MacroStop;

PROCEDURE PushKeys(VAR k: ARRAY OF INTEGER; n: INTEGER);
VAR i: INTEGER;
BEGIN
  (* insert at the front of the queue *)
  IF qTail - qHead + n > MaxQueue THEN RETURN END;
  IF qHead < n THEN
    FOR i := qTail - 1 TO qHead BY -1 DO queue[i + n - qHead] := queue[i] END;
    qTail := qTail + n - qHead; qHead := n
  END;
  qHead := qHead - n;
  FOR i := 0 TO n - 1 DO queue[qHead + i] := k[i] END
END PushKeys;

PROCEDURE Playing(): BOOLEAN;
BEGIN RETURN (qHead < qTail) OR (macroRep > 0)
END Playing;

PROCEDURE TimedBackup;
VAR now: LONGINT; p, n: Path; i: INTEGER;
BEGIN
  IF (cfg.backupMin <= 0) OR batch THEN RETURN END;
  now := Time.Now();
  IF lastBackup = 0 THEN lastBackup := now END;
  IF now - lastBackup >= cfg.backupMin * 60000 THEN
    lastBackup := now;
    FOR i := 1 TO 2 DO
      IF (eds[i] # NIL) & eds[i].modified THEN
        Cpy("{WP}BACK.", n); AppendInt(i, n);
        JoinPath(cfgDir, n, p);
        IF SaveFile(eds[i], p, fmtWP42, "") THEN END
      END
    END
  END
END TimedBackup;

PROCEDURE GetKey(): INTEGER;
VAR k: INTEGER;
BEGIN
  IF pushed >= 0 THEN k := pushed; pushed := -1; RETURN k END;
  IF (qHead >= qTail) & (macroRep > 0) THEN
    DEC(macroRep);
    qHead := 0; qTail := 0;
    FOR k := 0 TO repLen - 1 DO queue[qTail] := repBuf[k]; INC(qTail) END
  END;
  IF qHead < qTail THEN
    k := queue[qHead]; INC(qHead);
    IF qHead = qTail THEN qHead := 0; qTail := 0 END;
    RETURN k
  END;
  TimedBackup;
  REPEAT k := RawKey() UNTIL k # 0;
  IF macroRec & (macroLen < MaxMacro) THEN macroBuf[macroLen] := k; INC(macroLen) END;
  RETURN k
END GetKey;

PROCEDURE UnGet(k: INTEGER);
BEGIN pushed := k
END UnGet;

PROCEDURE IsFKey(k, n, m: INTEGER): BOOLEAN;
BEGIN RETURN k = KF + 100 * m + n
END IsFKey;

PROCEDURE IsNav(k, c, m: INTEGER): BOOLEAN;
BEGIN RETURN k = KNav + 100 * m + c
END IsNav;

(* plain key -> upper-case letter or digit, else 0X *)
PROCEDURE KeyChar(k: INTEGER): CHAR;
BEGIN
  IF (k >= 32) & (k < 127) THEN RETURN UpCh(CHR(k)) ELSE RETURN 0X END
END KeyChar;

PROCEDURE IsCancel(k: INTEGER): BOOLEAN;
BEGIN RETURN (k = KF + 1) OR (k = KEsc)
END IsCancel;

(* the name of a function key, e.g. "Shift-F7" *)
PROCEDURE FKeyName(k: INTEGER; VAR s: ARRAY OF CHAR);
VAR m, n: INTEGER;
BEGIN
  s[0] := 0X;
  IF (k >= KF) & (k < KNav) THEN
    m := (k - KF) DIV 100; n := (k - KF) MOD 100;
    IF ODD(m DIV 4) THEN Append("Ctrl-", s) END;
    IF ODD(m DIV 2) THEN Append("Alt-", s) END;
    IF ODD(m) THEN Append("Shift-", s) END;
    AppendCh("F", s); AppendInt(n, s)
  END
END FKeyName;

(* ====================================================================
   Screen primitives
   ==================================================================== *)

PROCEDURE PutUni(x, y, u, fg, bg: INTEGER);
VAR b: ARRAY 4 OF CHAR; n: INTEGER;
BEGIN
  IF (x < 1) OR (x > scrCols) OR (y < 1) OR (y > scrRows) THEN RETURN END;
  n := Utf8(u, b);
  IF n = 1 THEN TUI.PutCell(x, y, b[0], fg, bg)
  ELSIF n = 2 THEN TUI.PutCellMB(x, y, b[0], b[1], 0X, 0X, fg, bg)
  ELSIF n = 3 THEN TUI.PutCellMB(x, y, b[0], b[1], b[2], 0X, fg, bg)
  ELSE TUI.PutCellMB(x, y, b[0], b[1], b[2], b[3], fg, bg)
  END
END PutUni;

PROCEDURE PutCp(x, y: INTEGER; c: CHAR; fg, bg: INTEGER);
BEGIN
  IF ORD(c) < 32 THEN PutUni(x, y, ORD("?"), fg, bg)
  ELSE PutUni(x, y, CpToUni(c), fg, bg)
  END
END PutCp;

(* CP437 text *)
PROCEDURE Text(x, y: INTEGER; s: ARRAY OF CHAR; fg, bg: INTEGER);
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (i < LEN(s)) & (s[i] # 0X) DO PutCp(x + i, y, s[i], fg, bg); INC(i) END
END Text;

PROCEDURE TextB(x, y: INTEGER; s: ARRAY OF CHAR);
BEGIN Text(x, y, s, cHi, cBg)
END TextB;

PROCEDURE TextN(x, y: INTEGER; s: ARRAY OF CHAR);
BEGIN Text(x, y, s, cFg, cBg)
END TextN;

PROCEDURE ClearRow(y: INTEGER);
BEGIN TUI.FillRect(1, y, scrCols, 1, " ", cFg, cBg)
END ClearRow;

PROCEDURE ClearScreen;
BEGIN TUI.FillRect(1, 1, scrCols, scrRows, " ", cFg, cBg)
END ClearScreen;

PROCEDURE HLine(y: INTEGER; u: INTEGER);
VAR x: INTEGER;
BEGIN
  FOR x := 1 TO scrCols DO PutUni(x, y, u, cFg, cBg) END
END HLine;

PROCEDURE Flush;
BEGIN
  IF ~batch THEN TUI.Flush END
END Flush;

(* menu text: digits and capital letters that select options are bright *)
PROCEDURE MenuText(x, y: INTEGER; s: ARRAY OF CHAR);
VAR i: INTEGER; c: CHAR; hi: BOOLEAN;
BEGIN
  i := 0;
  WHILE (i < LEN(s)) & (s[i] # 0X) DO
    c := s[i];
    hi := ((c >= "0") & (c <= "9") & ((i = 0) OR (s[i - 1] = " ") OR (s[i - 1] = ";"))) &
          ((s[i + 1] = " ") OR (s[i + 1] = 0X) OR (s[i + 1] = "-"));
    IF hi THEN PutCp(x + i, y, c, cHi, cBg) ELSE PutCp(x + i, y, c, cFg, cBg) END;
    INC(i)
  END
END MenuText;

(* ---- the status line ---- *)

PROCEDURE StatusRow(): INTEGER;
BEGIN RETURN scrRows
END StatusRow;

PROCEDURE ShowMsg(s: ARRAY OF CHAR);
BEGIN
  Cpy(s, msg); msgSticky := FALSE
END ShowMsg;

(* show a prompt on the status line; returns the column after it *)
PROCEDURE StatusPrompt(s: ARRAY OF CHAR): INTEGER;
VAR y: INTEGER;
BEGIN
  y := StatusRow(); ClearRow(y); MenuText(1, y, s);
  RETURN SLen(s) + 1
END StatusPrompt;

VAR inputSeeded: BOOLEAN;   (* the next InputEx starts with a typed first key *)

(* line input on the status line.  F1 or Esc cancels (FALSE).  When
   fkeyEnd # 0 that function key also accepts (e.g. F2 in search). *)
PROCEDURE InputEx(prompt: ARRAY OF CHAR; VAR s: ARRAY OF CHAR; fkeyEnd: INTEGER; VAR endKey: INTEGER): BOOLEAN;
VAR k, x0, pos, n, i, y: INTEGER; first: BOOLEAN;
BEGIN
  y := StatusRow(); pos := SLen(s); first := TRUE;
  LOOP
    ClearRow(y); MenuText(1, y, prompt);
    x0 := SLen(prompt) + 1;
    Text(x0, y, s, cHi, cBg);
    TUI.SetCursor(x0 + pos, y);
    Flush;
    k := GetKey(); endKey := k;
    n := SLen(s);
    IF (k = KEnter) OR ((fkeyEnd # 0) & (k = fkeyEnd)) THEN TUI.SetCursor(1, 1); Terminal.HideCursor(); inputSeeded := FALSE; RETURN TRUE
    ELSIF IsCancel(k) THEN Terminal.HideCursor(); inputSeeded := FALSE; RETURN FALSE
    ELSIF k = KBS THEN
      IF pos > 0 THEN
        FOR i := pos - 1 TO n - 1 DO s[i] := s[i + 1] END; DEC(pos)
      END
    ELSIF IsNav(k, nDel, 0) THEN
      IF pos < n THEN FOR i := pos TO n - 1 DO s[i] := s[i + 1] END END
    ELSIF IsNav(k, nLeft, 0) THEN IF pos > 0 THEN DEC(pos) END
    ELSIF IsNav(k, nRight, 0) THEN IF pos < n THEN INC(pos) END
    ELSIF IsNav(k, nHome, 0) THEN pos := 0
    ELSIF IsNav(k, nEnd, 0) THEN pos := n
    ELSIF IsNav(k, nEnd, 4) THEN s[pos] := 0X
    ELSIF ((k >= 32) & (k < 127)) OR ((k > KExt) & (k < KExt + 256)) THEN
      IF first & (n > 0) & ~inputSeeded THEN s[0] := 0X; n := 0; pos := 0 END;    (* typing replaces the default *)
      IF n < LEN(s) - 1 THEN
        FOR i := n TO pos BY -1 DO s[i + 1] := s[i] END;
        IF k > KExt THEN s[pos] := CHR(k - KExt) ELSE s[pos] := CHR(k) END;
        INC(pos)
      END
    END;
    first := FALSE
  END
END InputEx;

PROCEDURE Input(prompt: ARRAY OF CHAR; VAR s: ARRAY OF CHAR): BOOLEAN;
VAR k: INTEGER;
BEGIN RETURN InputEx(prompt, s, 0, k)
END Input;

PROCEDURE InputInt(prompt: ARRAY OF CHAR; VAR v: INTEGER): BOOLEAN;
VAR s: Str; n: INTEGER;
BEGIN
  IntStr(v, s);
  IF ~Input(prompt, s) THEN RETURN FALSE END;
  IF StrInt(s, n) THEN v := n; RETURN TRUE END;
  RETURN FALSE
END InputInt;

VAR yesNoCancelled: BOOLEAN;

(* a WordPerfect yes/no question: "Replace X? (Y/N) N" *)
PROCEDURE YesNo(q: ARRAY OF CHAR; def: BOOLEAN): BOOLEAN;
VAR k, x, y: INTEGER; t: Str;
BEGIN
  yesNoCancelled := FALSE;
  y := StatusRow();
  Cpy(q, t); Append(" (Y/N) ", t);
  IF def THEN AppendCh("Y", t) ELSE AppendCh("N", t) END;
  ClearRow(y); MenuText(1, y, t); x := SLen(t);
  TUI.SetCursor(x, y); Flush;
  k := GetKey();
  Terminal.HideCursor();
  IF IsCancel(k) THEN yesNoCancelled := TRUE; RETURN FALSE END;
  IF k = KEnter THEN RETURN def END;
  IF (k = ORD("y")) OR (k = ORD("Y")) THEN RETURN TRUE END;
  IF (k = ORD("n")) OR (k = ORD("N")) THEN RETURN FALSE END;
  RETURN def
END YesNo;

(* a one-line menu on the status line; returns the key pressed:
   an upper-case letter or digit, "0" for Enter/Cancel *)
PROCEDURE MenuKey(menu: ARRAY OF CHAR): CHAR;
VAR k, y: INTEGER;
BEGIN
  y := StatusRow(); ClearRow(y); MenuText(1, y, menu);
  TUI.SetCursor(SLen(menu) + 1, y); Flush;
  k := GetKey();
  Terminal.HideCursor();
  IF IsCancel(k) OR (k = KEnter) THEN RETURN "0" END;
  IF (k >= 32) & (k < 127) THEN RETURN UpCh(CHR(k)) END;
  UnGet(k);
  RETURN 0X
END MenuKey;

(* "Press any key to continue" *)
PROCEDURE PressKey(s: ARRAY OF CHAR);
VAR k, y: INTEGER;
BEGIN
  y := StatusRow(); ClearRow(y); TextN(1, y, s); Flush;
  k := GetKey()
END PressKey;

(* ====================================================================
   Display
   ==================================================================== *)

VAR
  curX, curY: INTEGER;       (* screen cursor of the active window *)
  bottomReserve: INTEGER;    (* screen rows kept free below the editor *)
  hlA, hlB: INTEGER;         (* highlighted items (speller, replace ...), hlA < 0: none *)

PROCEDURE AttrColors(a: INTEGER; VAR fg, bg: INTEGER);
BEGIN
  fg := cFg; bg := cBg;
  IF ODD(ASR(a, aBold)) OR ODD(ASR(a, aShadow)) OR ODD(ASR(a, aOutline)) THEN fg := cHi END;
  IF ODD(ASR(a, aRed)) THEN fg := TUI.BrightRed END;
  IF ODD(ASR(a, aStrike)) THEN fg := TUI.BrightMagenta END;
  IF ODD(ASR(a, aItal)) THEN fg := TUI.BrightCyan END;
  IF ODD(ASR(a, bSuper)) OR ODD(ASR(a, bSub)) THEN fg := TUI.Yellow END;
  IF ODD(ASR(a, bGen)) THEN fg := TUI.BrightGreen END;
  IF ODD(ASR(a, aUnd)) THEN fg := fg + TUI.AttrUnderline END;
  IF ODD(ASR(a, aRev)) OR ODD(ASR(a, bBlock)) THEN bg := cFg; fg := cBg END
END AttrColors;

PROCEDURE BlockRange(x: Ed; VAR a, b: INTEGER): BOOLEAN;
BEGIN
  IF x.anchor < 0 THEN RETURN FALSE END;
  IF x.anchor < x.cur THEN a := x.anchor; b := x.cur ELSE a := x.cur; b := x.anchor END;
  RETURN TRUE
END BlockRange;

PROCEDURE DrawTextLine(x: Ed; L, y: INTEGER; blk: BOOLEAN; ba, bb: INTEGER);
VAR i, j, c, a, fg, bg, last: INTEGER; it: Item; g: Str;
BEGIN
  ClearRow(y);
  last := x.lines[L].end;
  FOR i := x.lines[L].start TO last - 1 DO
    it := x.d.it[i];
    a := x.iattr[i];
    IF blk & (i >= ba) & (i < bb) THEN a := a + LSL(1, bBlock) END;
    c := x.icol[i] - x.hscroll + 1;
    IF it.k = kChar THEN
      AttrColors(a, fg, bg); PutCp(c, y, it.ch, fg, bg)
    ELSIF (it.k = kCtl) OR (it.k = kNote) OR (it.k = kDate) OR
          ((it.k = kSingle) & (ItemWidth(it) > 0)) THEN
      IF (it.k = kNote) OR (it.k = kDate) OR (it.k = kCtl) THEN a := a + LSL(1, bGen) END;
      IF it.k = kCtl THEN a := a + LSL(1, aBold) END;
      AttrColors(a, fg, bg); GenText(it, g);
      j := 0; WHILE g[j] # 0X DO PutCp(c + j, y, g[j], fg, bg); INC(j) END
    ELSIF it.k = kTab THEN
      IF blk & (i >= ba) & (i < bb) THEN
        AttrColors(a, fg, bg);
        FOR j := x.icol[i] TO x.icol[i + 1] - 1 DO PutCp(j - x.hscroll + 1, y, " ", fg, bg) END
      END
    ELSIF (it.k = kSingle) & (it.a = fSoftHy) & (i = last - 2) THEN
      AttrColors(a, fg, bg); PutCp(c, y, "-", fg, bg)
    ELSIF (it.k = kHRt) & (cfg.hrtChar # 32) & (cfg.hrtChar > 0) THEN
      PutCp(c, y, CHR(cfg.hrtChar), cFg, cBg)
    ELSIF blk & (i >= ba) & (i < bb) & (it.k = kHRt) THEN
      PutCp(c, y, " ", cBg, cFg)
    END
  END
END DrawTextLine;

PROCEDURE DrawCommentRow(x: Ed; kind, v, y: INTEGER);
VAR i, k, n, l, r, col, j: INTEGER; s: ARRAY 1024 OF CHAR; sub: Doc;
BEGIN
  ClearRow(y);
  l := x.fmt0.lm - x.hscroll; r := x.fmt0.rm - x.hscroll + 2;
  IF l < 1 THEN l := 1 END;
  IF r > scrCols THEN r := scrCols END;
  IF kind = rCmtTop THEN
    PutCp(l, y, 0C9X, cFg, cBg); FOR i := l + 1 TO r - 1 DO PutCp(i, y, 0CDX, cFg, cBg) END;
    PutCp(r, y, 0BBX, cFg, cBg)
  ELSIF kind = rCmtBot THEN
    PutCp(l, y, 0C8X, cFg, cBg); FOR i := l + 1 TO r - 1 DO PutCp(i, y, 0CDX, cFg, cBg) END;
    PutCp(r, y, 0BCX, cFg, cBg)
  ELSE
    PutCp(l, y, 0BAX, cFg, cBg); PutCp(r, y, 0BAX, cFg, cBg);
    sub := x.d.it[v DIV 64].sub; n := v MOD 64;
    IF sub # NIL THEN
      DocText(sub, s);
      i := 0; k := 0;
      WHILE (s[i] # 0X) & (k < n) DO IF s[i] = 0AX THEN INC(k) END; INC(i) END;
      col := l + 2; j := i;
      WHILE (s[j] # 0X) & (s[j] # 0AX) & (col < r - 1) DO PutCp(col, y, s[j], cFg, cBg); INC(col); INC(j) END
    END
  END
END DrawCommentRow;

PROCEDURE DrawRow(x: Ed; row, y: INTEGER; blk: BOOLEAN; ba, bb: INTEGER);
VAR i, k: INTEGER;
BEGIN
  IF (row < 0) OR (row >= x.nrows) THEN ClearRow(y); RETURN END;
  k := x.rows[row].kind;
  CASE k OF
    rText: DrawTextLine(x, x.rows[row].line, y, blk, ba, bb)
  | rBlank: ClearRow(y)
  | rSoftPg: ClearRow(y); FOR i := 1 TO scrCols DO PutUni(i, y, ORD("-"), cFg, cBg) END
  | rHardPg: ClearRow(y); FOR i := 1 TO scrCols DO PutUni(i, y, ORD("="), cFg, cBg) END
  | rCmtTop, rCmtText, rCmtBot: DrawCommentRow(x, k, x.rows[row].x, y)
  END
END DrawRow;

(* the display row holding the cursor *)
PROCEDURE CursorRow(x: Ed): INTEGER;
BEGIN RETURN x.lines[LineOf(x, x.cur)].row
END CursorRow;

PROCEDURE ScrollTo(x: Ed; h: INTEGER);
VAR r, c, w: INTEGER;
BEGIN
  r := CursorRow(x);
  IF r < x.top THEN x.top := r END;
  IF r >= x.top + h THEN x.top := r - h + 1 END;
  IF x.top < 0 THEN x.top := 0 END;
  c := x.icol[x.cur];
  w := scrCols;
  IF c - x.hscroll >= w - 1 THEN x.hscroll := c - w + 20 END;
  IF c < x.hscroll THEN x.hscroll := c - 20 END;
  IF x.hscroll < 0 THEN x.hscroll := 0 END
END ScrollTo;

PROCEDURE DrawDocWindow(x: Ed; y0, h: INTEGER; active: BOOLEAN);
VAR r, ba, bb: INTEGER; blk: BOOLEAN;
BEGIN
  Ensure(x);
  ScrollTo(x, h);
  blk := BlockRange(x, ba, bb);
  IF active & (hlA >= 0) THEN blk := TRUE; ba := hlA; bb := hlB END;
  FOR r := 0 TO h - 1 DO DrawRow(x, x.top + r, y0 + r, blk, ba, bb) END;
  IF active THEN
    curX := x.icol[x.cur] - x.hscroll + 1;
    curY := y0 + CursorRow(x) - x.top
  END
END DrawDocWindow;

(* the status line of a window *)
PROCEDURE DrawStatus(x: Ed; y: INTEGER; active: BOOLEAN);
VAR s, t: Str; L, pg, ln, a, fg, bg, col, i: INTEGER;
BEGIN
  ClearRow(y);
  IF active & (msg[0] # 0X) THEN
    TextN(1, y, msg)
  ELSIF x.isSub THEN
    TextN(1, y, x.subTitle)
  ELSIF x.anchor >= 0 THEN
    Text(1, y, "Block on", cFg + TUI.AttrBlink, cBg)
  ELSIF macroRec & active THEN
    Text(1, y, "Macro Def", cFg + TUI.AttrBlink, cBg)
  ELSIF x.typeover THEN
    TextN(1, y, "Typeover")
  END;
  IF ~(active & (msg[0] # 0X)) & ~x.isSub & (x.anchor < 0) & ~(macroRec & active) & ~x.typeover THEN
    IF Ensure2(x) & x.snaps[x.lines[LineOf(x, x.cur)].snap].mathOn THEN TextN(1, y, "Math")
    ELSIF cfg.showName THEN
      FromUtf8(x.name, s);
      IF SLen(s) > 45 THEN Sub(s, SLen(s) - 42, 50, t); Cpy("...", s); Append(t, s) END;
      TextN(1, y, s)
    END
  END;
  L := LineOf(x, x.cur);
  s[0] := 0X;
  IF ~x.isSub THEN
    Append("Doc ", s); AppendInt(x.num, s);
    pg := x.lines[L].page;
    Append(" Pg ", s);
    IF (pg < x.npages) & (x.pages[pg].roman = 1) THEN Roman(x.pages[pg].num, t); Append(t, s)
    ELSIF pg < x.npages THEN AppendInt(x.pages[pg].num, s)
    ELSE AppendInt(1, s)
    END;
    ln := x.lines[L].ln DIV 2 + 1
  ELSE
    ln := L + 1
  END;
  Append(" Ln ", s); AppendInt(ln, s);
  Append(" Pos ", s);
  col := 80 - SLen(s) - 3;
  IF col > scrCols - SLen(s) - 3 THEN col := scrCols - SLen(s) - 3 END;
  IF col < 30 THEN col := 30 END;
  TextN(col, y, s);
  IntStr(x.icol[x.cur], t);
  a := x.iattr[x.cur];
  AttrColors(a MOD 256, fg, bg);
  IF ODD(ASR(a, aBold)) THEN fg := cHi + (fg DIV 256) * 256 END;
  FOR i := 0 TO SLen(t) - 1 DO PutCp(col + SLen(s) + i, y, t[i], fg, bg) END
END DrawStatus;

PROCEDURE Ensure2(x: Ed): BOOLEAN;
BEGIN Ensure(x); RETURN TRUE
END Ensure2;

(* the tab ruler: margins as [ ] (braces when on a tab stop), tabs as triangles *)
PROCEDURE DrawRuler(x: Ed; y: INTEGER);
VAR p, c, L: INTEGER; st: Fmt;
BEGIN
  Ensure(x);
  L := LineOf(x, x.cur);
  st := x.snaps[x.lines[L].snap];
  ClearRow(y);
  FOR c := 1 TO scrCols DO
    p := c - 1 + x.hscroll;
    IF p = st.lm THEN
      IF (p <= 250) & (st.tabs[p] # 0X) THEN PutUni(c, y, ORD("{"), cHi, cBg) ELSE PutUni(c, y, ORD("["), cHi, cBg) END
    ELSIF p = st.rm THEN
      IF (p <= 250) & (st.tabs[p] # 0X) THEN PutUni(c, y, ORD("}"), cHi, cBg) ELSE PutUni(c, y, ORD("]"), cHi, cBg) END
    ELSIF (p <= 250) & (st.tabs[p] # 0X) THEN PutUni(c, y, 25B2H, cFg, cBg)
    ELSE PutUni(c, y, 2500H, cFg, cBg)
    END
  END
END DrawRuler;

(* ---- Reveal Codes ---- *)

PROCEDURE DrawReveal(x: Ed; y0, h: INTEGER);
VAR L, L0, i, c, y, row, curRow, curCol, pass, w, j, fg, bg: INTEGER;
    s, t: Str; isCode, soft, done: BOOLEAN; it: Item;
BEGIN
  Ensure(x);
  L := LineOf(x, x.cur);
  L0 := L - 2; IF L0 < 0 THEN L0 := 0 END;
  (* two passes: find the cursor's reveal row, then draw with scrolling *)
  curRow := 0; row := 0;
  FOR pass := 0 TO 1 DO
    y := 0; c := 1; i := x.lines[L0].start; done := FALSE;
    WHILE ~done DO
      IF (i >= x.d.n) OR (y - row >= h) THEN done := TRUE
      ELSE
        it := x.d.it[i];
        soft := FALSE;
        IF it.k = kChar THEN
          s[0] := it.ch; s[1] := 0X; isCode := FALSE;
          (* the space that ends a soft line is the soft return *)
          L := LineOf(x, i);
          IF (it.ch = " ") & (x.lines[L].brk = brSoft) & (i = x.lines[L].end - 1) THEN
            Cpy("[SRt]", s); isCode := TRUE; soft := TRUE
          END
        ELSIF it.k = kCtl THEN
          s[0] := "^"; s[1] := CHR(ORD(it.ch) + 64); s[2] := 0X; isCode := FALSE
        ELSE
          s[0] := "["; s[1] := 0X; CodeName(it, s);
          Cpy("[", msg); msg[0] := "["; msg[1] := 0X;
          w := SLen(s);
          FOR j := w TO 0 BY -1 DO s[j + 1] := s[j] END;
          s[0] := "["; Append("]", s); isCode := TRUE;
          msg[0] := 0X
        END;
        w := SLen(s);
        IF c + w - 1 > scrCols THEN INC(y); c := 1 END;
        IF i = x.cur THEN curRow := y; curCol := c END;
        IF (pass = 1) & (y >= row) & (y - row < h) THEN
          IF isCode THEN fg := cHi ELSE AttrColors(x.iattr[i] MOD 256, fg, bg) END;
          bg := cBg;
          IF i = x.cur THEN bg := cFg; fg := cBg END;
          FOR j := 0 TO w - 1 DO PutCp(c + j, y0 + y - row, s[j], fg, bg) END
        END;
        c := c + w;
        IF (it.k = kHRt) OR (it.k = kHPg) OR soft THEN INC(y); c := 1 END;
        INC(i)
      END
    END;
    IF (pass = 0) THEN
      IF x.cur >= x.d.n THEN curRow := y; curCol := c END;
      row := 0;
      IF curRow >= h THEN row := curRow - h + 1 END;
      FOR j := 0 TO h - 1 DO ClearRow(y0 + j) END
    END
  END;
  IF x.cur >= x.d.n THEN
    IF (curRow - row >= 0) & (curRow - row < h) THEN PutCp(curCol, y0 + curRow - row, " ", cBg, cFg) END
  END
END DrawReveal;

(* ---- the whole screen ---- *)

PROCEDURE DrawEditor(x: Ed; y0, h: INTEGER; active: BOOLEAN);
VAR th: INTEGER;
BEGIN
  IF revealOn & active THEN
    th := (h - 2) DIV 2;
    IF th < 2 THEN th := 2 END;
    DrawDocWindow(x, y0, th, TRUE);
    DrawStatus(x, y0 + th, TRUE);
    DrawRuler(x, y0 + th + 1);
    DrawReveal(x, y0 + th + 2, h - th - 2)
  ELSE
    DrawDocWindow(x, y0, h - 1, active);
    DrawStatus(x, y0 + h - 1, active)
  END
END DrawEditor;

PROCEDURE Redraw;
VAR other, h1: INTEGER;
BEGIN
  scrRows := TUI.Rows; scrCols := TUI.Cols;
  IF scrRows > MaxRows THEN scrRows := MaxRows END;
  IF e.isSub OR (bottomReserve > 0) THEN
    DrawEditor(e, 1, scrRows - bottomReserve, TRUE)
  ELSIF (winSplit > 0) & (winSplit < scrRows - 3) THEN
    h1 := winSplit;
    IF active = 1 THEN other := 2 ELSE other := 1 END;
    IF eds[other] = NIL THEN eds[other] := NewEd(other) END;
    IF active = 1 THEN
      DrawEditor(eds[1], 1, h1, TRUE);
      DrawRuler(eds[1], h1 + 1);
      DrawEditor(eds[2], h1 + 2, scrRows - h1 - 1, FALSE)
    ELSE
      DrawEditor(eds[1], 1, h1, FALSE);
      DrawRuler(eds[2], h1 + 1);
      DrawEditor(eds[2], h1 + 2, scrRows - h1 - 1, TRUE)
    END
  ELSE
    DrawEditor(e, 1, scrRows, TRUE)
  END;
  Flush;
  IF (curX >= 1) & (curX <= scrCols) THEN TUI.SetCursor(curX, curY) ELSE Terminal.HideCursor() END
END Redraw;

(* ====================================================================
   Editing
   ==================================================================== *)

PROCEDURE Touch(x: Ed);
BEGIN
  x.modified := TRUE; x.dirty := TRUE
END Touch;

PROCEDURE Moved;
BEGIN
  delOpen := FALSE; e.goal := -1
END Moved;

PROCEDURE SetCur(x: Ed; i: INTEGER);
BEGIN
  IF i < 0 THEN i := 0 END;
  IF i > x.d.n THEN i := x.d.n END;
  x.cur := i
END SetCur;

PROCEDURE InsertItem(VAR it: Item);
BEGIN
  InsItem(e.d, e.cur, it); INC(e.cur);
  IF (e.anchor >= 0) & (e.anchor >= e.cur) THEN INC(e.anchor) END;
  Touch(e); delOpen := FALSE
END InsertItem;

PROCEDURE InsertCode(k, a, b, c: INTEGER);
VAR it: Item;
BEGIN
  MkItem(k, a, b, c, it); InsertItem(it)
END InsertCode;

(* insert a code at position p (cursor and anchor follow) *)
PROCEDURE InsertCodeAt(p, k, a, b, c: INTEGER);
VAR it: Item;
BEGIN
  MkItem(k, a, b, c, it);
  InsItem(e.d, p, it);
  IF e.cur >= p THEN INC(e.cur) END;
  IF (e.anchor >= 0) & (e.anchor >= p) THEN INC(e.anchor) END;
  Touch(e)
END InsertCodeAt;

(* a pair of codes with the cursor between them *)
PROCEDURE InsertPair(k1, a, b, c, k2: INTEGER);
BEGIN
  InsertCode(k1, a, b, c);
  InsertCode(k2, 0, 0, 0);
  DEC(e.cur)
END InsertPair;

(* step over an end-of-center/align code the cursor sits on *)
PROCEDURE SkipEndCode;
BEGIN
  IF (e.cur < e.d.n) & ((e.d.it[e.cur].k = kEndCenter) OR (e.d.it[e.cur].k = kEndAlign)) THEN
    INC(e.cur)
  END
END SkipEndCode;

(* the align code whose segment the cursor is in, or -1 *)
PROCEDURE OpenAlign(): INTEGER;
VAR i: INTEGER;
BEGIN
  i := e.cur - 1;
  WHILE (i >= 0) & (e.d.it[i].k # kAlign) & (e.d.it[i].k # kEndAlign) &
        (e.d.it[i].k # kHRt) & (e.d.it[i].k # kTab) DO DEC(i) END;
  IF (i >= 0) & (e.d.it[i].k = kAlign) THEN RETURN i END;
  RETURN -1
END OpenAlign;

PROCEDURE InsertChar(ch: CHAR);
VAR it: Item; a: INTEGER;
BEGIN
  IF (e.cur < e.d.n) & (e.d.it[e.cur].k = kEndAlign) THEN
    a := OpenAlign();
    IF (a >= 0) & (ORD(ch) = e.d.it[a].a) THEN INC(e.cur) END
  END;
  ClearItem(it);
  IF (ORD(ch) < 32) THEN it.k := kCtl ELSE it.k := kChar END;
  it.ch := ch;
  IF e.typeover & (e.cur < e.d.n) & (e.d.it[e.cur].k = kChar) THEN
    e.d.it[e.cur] := it; INC(e.cur); Touch(e); delOpen := FALSE
  ELSE
    InsertItem(it)
  END
END InsertChar;

(* ---- deletion and undelete ---- *)

PROCEDURE SaveDeleted(frag: Doc; fwd: BOOLEAN);
VAR i, n: INTEGER;
BEGIN
  IF frag.n = 0 THEN RETURN END;
  IF delOpen & (undel[0].d # NIL) & (delAt = e.cur) THEN
    IF fwd THEN n := InsDoc(undel[0].d, undel[0].d.n, frag)
    ELSE n := InsDoc(undel[0].d, 0, frag)
    END
  ELSE
    FOR i := 2 TO 1 BY -1 DO undel[i] := undel[i - 1] END;
    undel[0].d := CopyDoc(frag)
  END;
  delOpen := TRUE
END SaveDeleted;

PROCEDURE DeleteRange(a, b: INTEGER; fwd: BOOLEAN);
VAR frag: Doc;
BEGIN
  IF a < 0 THEN a := 0 END;
  IF b > e.d.n THEN b := e.d.n END;
  IF b <= a THEN RETURN END;
  frag := CopyRange(e.d, a, b);
  IF e.cur > a THEN
    IF e.cur >= b THEN e.cur := e.cur - (b - a) ELSE e.cur := a END
  END;
  SaveDeleted(frag, fwd);
  DelItems(e.d, a, b - a);
  delAt := e.cur;
  Touch(e)
END DeleteRange;

(* does deleting item i need a "Delete [x]?" confirmation? *)
PROCEDURE NeedsConfirm(i: INTEGER): BOOLEAN;
VAR k: INTEGER;
BEGIN
  IF revealOn THEN RETURN FALSE END;
  k := e.d.it[i].k;
  RETURN ~((k = kChar) OR (k = kCtl) OR (k = kHRt) OR (k = kHPg) OR (k = kTab) OR
           ((k = kSingle) & (ItemWidth(e.d.it[i]) > 0)))
END NeedsConfirm;

PROCEDURE ConfirmDelete(i: INTEGER): BOOLEAN;
VAR s, t: Str;
BEGIN
  IF ~NeedsConfirm(i) THEN RETURN TRUE END;
  CodeTitle(e.d.it[i], t);
  Cpy("Delete [", s); Append(t, s); Append("]?", s);
  RETURN YesNo(s, FALSE)
END ConfirmDelete;

PROCEDURE DelChar;
BEGIN
  IF e.cur < e.d.n THEN
    IF ConfirmDelete(e.cur) THEN DeleteRange(e.cur, e.cur + 1, TRUE) END
  END
END DelChar;

PROCEDURE Backspace;
BEGIN
  IF e.cur > 0 THEN
    IF ConfirmDelete(e.cur - 1) THEN DeleteRange(e.cur - 1, e.cur, FALSE) END
  END
END Backspace;

PROCEDURE IsWordItem(i: INTEGER): BOOLEAN;
BEGIN
  RETURN (i >= 0) & (i < e.d.n) & (e.d.it[i].k = kChar) & (e.d.it[i].ch # " ")
END IsWordItem;

(* Ctrl-Backspace: the word at the cursor and the spaces after it *)
PROCEDURE DelWord;
VAR a, b: INTEGER;
BEGIN
  a := e.cur; b := e.cur;
  IF ~IsWordItem(a) & IsWordItem(a - 1) THEN DEC(a); b := a END;
  WHILE IsWordItem(a - 1) DO DEC(a) END;
  WHILE IsWordItem(b) DO INC(b) END;
  WHILE (b < e.d.n) & (e.d.it[b].k = kChar) & (e.d.it[b].ch = " ") DO INC(b) END;
  DeleteRange(a, b, TRUE)
END DelWord;

PROCEDURE DelWordRight;     (* Home, Del *)
VAR b: INTEGER;
BEGIN
  b := e.cur;
  WHILE IsWordItem(b) DO INC(b) END;
  WHILE (b < e.d.n) & (e.d.it[b].k = kChar) & (e.d.it[b].ch = " ") DO INC(b) END;
  DeleteRange(e.cur, b, TRUE)
END DelWordRight;

PROCEDURE DelWordLeft;      (* Home, Backspace *)
VAR a: INTEGER;
BEGIN
  a := e.cur;
  WHILE IsWordItem(a - 1) DO DEC(a) END;
  DeleteRange(a, e.cur, FALSE)
END DelWordLeft;

(* Ctrl-End: delete to the end of the line *)
PROCEDURE DelEOL;
VAR L, b: INTEGER;
BEGIN
  Ensure(e);
  L := LineOf(e, e.cur);
  b := e.lines[L].end;
  IF (e.lines[L].brk = brHard) OR (e.lines[L].brk = brPage) THEN b := e.lines[L].end - 1 END;
  DeleteRange(e.cur, b, TRUE)
END DelEOL;

(* Ctrl-PgDn: delete to the end of the page *)
PROCEDURE DelEOP;
VAR pg, b, L: INTEGER;
BEGIN
  IF ~YesNo("Delete Remainder of Page?", FALSE) THEN RETURN END;
  Ensure(e);
  pg := PageOf(e, e.cur);
  L := e.pages[pg].last;
  IF L < 0 THEN L := e.nlines - 1 END;
  b := e.lines[L].end;
  IF e.lines[L].brk = brPage THEN DEC(b) END;
  DeleteRange(e.cur, b, TRUE)
END DelEOP;

(* F1 outside a menu: "Undelete: 1 Restore; 2 Show Previous Deletion: 0" *)
PROCEDURE Undelete;
VAR which, n, i, at: INTEGER; c: CHAR; saveAnchor: INTEGER;
BEGIN
  which := 0;
  WHILE (which < 3) & (undel[which].d = NIL) DO INC(which) END;
  IF which >= 3 THEN ShowMsg("* Nothing to undelete *"); RETURN END;
  LOOP
    at := e.cur;
    n := InsDoc(e.d, at, undel[which].d);
    saveAnchor := e.anchor;
    hlA := at; hlB := at + n; e.cur := at + n; e.dirty := TRUE;
    Redraw;
    c := MenuKey("Undelete: 1 Restore; 2 Show Previous Deletion: 0");
    hlA := -1; e.anchor := saveAnchor;
    IF c = "1" THEN
      Touch(e); delOpen := FALSE; RETURN
    END;
    DelItems(e.d, at, n); e.cur := at; e.dirty := TRUE;
    IF c = "2" THEN
      i := 0;
      REPEAT which := (which + 1) MOD 3; INC(i) UNTIL (undel[which].d # NIL) OR (i > 3)
    ELSE
      RETURN
    END
  END
END Undelete;

(* ---- cursor movement ---- *)

PROCEDURE GoalCol(): INTEGER;
BEGIN
  IF e.goal < 0 THEN e.goal := e.icol[e.cur] END;
  RETURN e.goal
END GoalCol;

(* position on line L closest to column g *)
PROCEDURE PosInLine(L, g: INTEGER): INTEGER;
VAR i, best, last: INTEGER;
BEGIN
  best := e.lines[L].start; last := LineLast(e, L);
  FOR i := e.lines[L].start TO last DO
    IF (e.icol[i] <= g) & (e.icol[i] > e.icol[best]) THEN best := i END
  END;
  RETURN best
END PosInLine;

PROCEDURE MoveLines(n: INTEGER);
VAR L, g: INTEGER;
BEGIN
  Ensure(e);
  g := GoalCol();
  L := LineOf(e, e.cur) + n;
  IF L < 0 THEN L := 0 END;
  IF L >= e.nlines THEN L := e.nlines - 1 END;
  e.cur := PosInLine(L, g);
  delOpen := FALSE
END MoveLines;

PROCEDURE LineStart;
BEGIN Ensure(e); e.cur := e.lines[LineOf(e, e.cur)].start; Moved
END LineStart;

PROCEDURE LineEnd;
BEGIN Ensure(e); e.cur := LineLast(e, LineOf(e, e.cur)); Moved
END LineEnd;

PROCEDURE WordRight;
BEGIN
  WHILE IsWordItem(e.cur) DO INC(e.cur) END;
  WHILE (e.cur < e.d.n) & ~IsWordItem(e.cur) DO INC(e.cur) END;
  Moved
END WordRight;

PROCEDURE WordLeft;
BEGIN
  IF e.cur > 0 THEN DEC(e.cur) END;
  WHILE (e.cur > 0) & ~IsWordItem(e.cur) DO DEC(e.cur) END;
  WHILE IsWordItem(e.cur - 1) DO DEC(e.cur) END;
  Moved
END WordLeft;

PROCEDURE WindowRows(): INTEGER;
VAR h: INTEGER;
BEGIN
  h := scrRows - 1 - bottomReserve;
  IF (winSplit > 0) & ~e.isSub & (bottomReserve = 0) THEN
    IF active = 1 THEN h := winSplit - 1 ELSE h := scrRows - winSplit - 2 END
  END;
  IF revealOn THEN h := (h - 1) DIV 2 END;
  IF h < 2 THEN h := 2 END;
  RETURN h
END WindowRows;

(* first line of the screen / last line of the screen *)
PROCEDURE ScreenUp;
VAR r, top, L: INTEGER;
BEGIN
  Ensure(e); ScrollTo(e, WindowRows());
  top := e.top;
  r := CursorRow(e);
  IF r = top THEN top := top - WindowRows(); IF top < 0 THEN top := 0 END END;
  WHILE (top < e.nrows - 1) & (e.rows[top].kind # rText) DO INC(top) END;
  L := e.rows[top].line;
  e.cur := PosInLine(L, GoalCol()); e.top := top; delOpen := FALSE
END ScreenUp;

PROCEDURE ScreenDown;
VAR r, bot, L: INTEGER;
BEGIN
  Ensure(e); ScrollTo(e, WindowRows());
  bot := e.top + WindowRows() - 1;
  r := CursorRow(e);
  IF r >= bot THEN bot := bot + WindowRows() END;
  IF bot >= e.nrows THEN bot := e.nrows - 1 END;
  WHILE (bot > 0) & (e.rows[bot].kind # rText) DO DEC(bot) END;
  L := e.rows[bot].line;
  e.cur := PosInLine(L, GoalCol()); delOpen := FALSE
END ScreenDown;

PROCEDURE PageMove(dir: INTEGER);
VAR pg: INTEGER;
BEGIN
  Ensure(e);
  pg := PageOf(e, e.cur) + dir;
  IF pg < 0 THEN pg := 0 END;
  IF pg >= e.npages THEN pg := e.npages - 1 END;
  e.cur := e.lines[e.pages[pg].first].start; Moved
END PageMove;

PROCEDURE GotoPage(n: INTEGER);
VAR pg: INTEGER;
BEGIN
  Ensure(e);
  FOR pg := 0 TO e.npages - 1 DO
    IF e.pages[pg].num = n THEN e.cur := e.lines[e.pages[pg].first].start; Moved; RETURN END
  END;
  IF (n >= 1) & (n <= e.npages) THEN e.cur := e.lines[e.pages[n - 1].first].start; Moved END
END GotoPage;

(* Ctrl-Home: "Go to" *)
PROCEDURE GoTo;
VAR k, n, pg, L, i: INTEGER; s: Str; tmp: INTEGER;
BEGIN
  Ensure(e);
  n := StatusPrompt("Go to "); Flush;
  k := GetKey();
  IF IsNav(k, nHome, 4) THEN
    IF e.anchor >= 0 THEN
      IF (lastBlockA >= 0) THEN e.anchor := lastBlockA; e.cur := lastBlockB END
    ELSE
      tmp := e.cur; SetCur(e, prevPos); prevPos := tmp
    END
  ELSIF IsNav(k, nUp, 0) THEN
    pg := PageOf(e, e.cur); prevPos := e.cur; e.cur := e.lines[e.pages[pg].first].start
  ELSIF IsNav(k, nDown, 0) THEN
    pg := PageOf(e, e.cur); prevPos := e.cur;
    L := e.pages[pg].last; IF L < 0 THEN L := e.nlines - 1 END;
    e.cur := LineLast(e, L)
  ELSIF (k >= ORD("0")) & (k <= ORD("9")) THEN
    s[0] := CHR(k); s[1] := 0X; inputSeeded := TRUE;
    IF InputEx("Go to ", s, 0, k) & StrInt(s, n) THEN prevPos := e.cur; GotoPage(n) END
  ELSIF (k > 32) & (k < 127) THEN
    i := e.cur + 1;
    WHILE (i < e.d.n) & (i < e.cur + 2000) & ~((e.d.it[i].k = kChar) & (e.d.it[i].ch = CHR(k))) DO INC(i) END;
    IF (i < e.d.n) & (e.d.it[i].k = kChar) THEN prevPos := e.cur; e.cur := i + 1 END
  ELSIF k = KEnter THEN
    i := e.cur;
    WHILE (i < e.d.n) & (e.d.it[i].k # kHRt) DO INC(i) END;
    IF i < e.d.n THEN prevPos := e.cur; e.cur := i + 1 END
  END;
  Moved
END GoTo;

(* the Home key prefix: Home, arrow / Home, Home, arrow / Home, Del ... *)
PROCEDURE HomeKey;
VAR k, homes: INTEGER;
BEGIN
  homes := 1;
  k := GetKey();
  IF IsNav(k, nHome, 0) THEN homes := 2; k := GetKey();
    IF IsNav(k, nHome, 0) THEN homes := 3; k := GetKey() END
  END;
  Ensure(e);
  IF IsNav(k, nUp, 0) THEN
    IF homes >= 2 THEN prevPos := e.cur; e.cur := 0; Moved ELSE ScreenUp END
  ELSIF IsNav(k, nDown, 0) THEN
    IF homes >= 2 THEN prevPos := e.cur; e.cur := e.d.n; Moved ELSE ScreenDown END
  ELSIF IsNav(k, nLeft, 0) THEN
    LineStart;
    IF homes = 3 THEN
      WHILE (e.cur > 0) & (e.d.it[e.cur - 1].k # kHRt) & (e.d.it[e.cur - 1].k # kHPg) &
            (ItemWidth(e.d.it[e.cur - 1]) = 0) & (e.d.it[e.cur - 1].k # kTab) DO DEC(e.cur) END
    END
  ELSIF IsNav(k, nRight, 0) THEN LineEnd
  ELSIF IsNav(k, nDel, 0) THEN DelWordRight
  ELSIF k = KBS THEN DelWordLeft
  ELSIF k = ORD(" ") THEN InsertCode(kSingle, fHardSp, 0, 0)
  ELSIF k = ORD("-") THEN InsertCode(kSingle, fHardHy, 0, 0)
  ELSE UnGet(k)
  END
END HomeKey;

(* ====================================================================
   Save, Retrieve, Exit, Switch
   ==================================================================== *)

PROCEDURE Saving(name: ARRAY OF CHAR);
VAR s: Path; b: Path;
BEGIN
  BaseName(name, b);
  Cpy("Saving ", s); Append(b, s);
  ClearRow(StatusRow()); TextN(1, StatusRow(), s); Flush
END Saving;

PROCEDURE ErrMsg(s: ARRAY OF CHAR);
BEGIN
  Beep; MacroStop;
  Cpy("ERROR: ", msg); Append(s, msg)
END ErrMsg;

(* write a document to name, asking before replacing a file *)
PROCEDURE SaveTo(x: Ed; name: ARRAY OF CHAR; fmt: INTEGER; ask: BOOLEAN; pw: ARRAY OF CHAR): BOOLEAN;
VAR q: Path; full: Path;
BEGIN
  FullPath(name, full);
  IF ask & Exists(full) THEN
    Cpy("Replace ", q); Append(full, q); AppendCh("?", q);
    IF ~YesNo(q, FALSE) THEN RETURN FALSE END
  END;
  Saving(full);
  IF ~SaveFile(x, full, fmt, pw) THEN ErrMsg("Can't write file"); RETURN FALSE END;
  RETURN TRUE
END SaveTo;

PROCEDURE DocFormat(x: Ed): INTEGER;
BEGIN
  IF x.srcFmt = fmtWP5 THEN RETURN fmtWP5 ELSE RETURN fmtWP42 END
END DocFormat;

(* save the document (or the block) *)
PROCEDURE SaveDocument(x: Ed): BOOLEAN;
VAR name, full: Path;
BEGIN
  Cpy(x.name, name);
  IF ~Input("Document to be Saved: ", name) THEN RETURN FALSE END;
  Trim(name);
  IF name[0] = 0X THEN RETURN FALSE END;
  IF cfg.summaryOnSave & ~HasSummary(x) THEN CreateSummary(x) END;
  FullPath(name, full);
  IF SaveTo(x, full, DocFormat(x), TRUE, "") THEN
    Cpy(full, x.name); x.modified := FALSE; RETURN TRUE
  END;
  RETURN FALSE
END SaveDocument;

PROCEDURE SaveBlock;
VAR name: Path; ba, bb: INTEGER; x: Ed;
BEGIN
  IF ~BlockRange(e, ba, bb) THEN RETURN END;
  name[0] := 0X;
  IF ~Input("Block Name: ", name) THEN RETURN END;
  Trim(name);
  IF name[0] = 0X THEN RETURN END;
  x := NewEd(0); x.d := CopyRange(e.d, ba, bb); x.fmt0 := e.fmt0;
  IF SaveTo(x, name, fmtWP42, TRUE, "") THEN END
END SaveBlock;

PROCEDURE SaveCmd;
BEGIN
  IF e.isSub THEN RETURN END;
  IF e.anchor >= 0 THEN SaveBlock ELSE IF SaveDocument(e) THEN END END
END SaveCmd;

(* read a file, asking for the key of a locked document *)
PROCEDURE ReadFileInto(name: ARRAY OF CHAR; d: Doc; VAR fmt: INTEGER): BOOLEAN;
VAR pw: Str; r: INTEGER;
BEGIN
  pw[0] := 0X;
  IF IsLocked(name) THEN
    IF ~Input("Enter Key: ", pw) THEN RETURN FALSE END
  END;
  r := LoadDoc(name, d, pw);
  IF r = -1 THEN ErrMsg("File not found"); RETURN FALSE
  ELSIF r = -2 THEN ErrMsg("Incorrect key"); RETURN FALSE
  ELSIF r = -3 THEN ErrMsg("Incompatible file format (WordPerfect 6.x or Macintosh)"); RETURN FALSE
  END;
  fmt := r;
  RETURN TRUE
END ReadFileInto;

(* retrieve a file into the document at the cursor *)
PROCEDURE RetrieveFile(name: ARRAY OF CHAR);
VAR d: Doc; fmt, n: INTEGER; full: Path; wasEmpty: BOOLEAN;
BEGIN
  FullPath(name, full);
  d := NewDoc();
  IF ~ReadFileInto(full, d, fmt) THEN RETURN END;
  wasEmpty := (e.d.n = 0) & ~e.modified;
  n := InsDoc(e.d, e.cur, d);
  e.dirty := TRUE;
  IF wasEmpty & ~e.isSub THEN
    Cpy(full, e.name); e.srcFmt := fmt; e.modified := FALSE
  ELSE Touch(e)
  END
END RetrieveFile;

PROCEDURE RetrieveCmd;
VAR name: Path;
BEGIN
  name[0] := 0X;
  IF Input("Document to be Retrieved: ", name) THEN
    Trim(name);
    IF name[0] # 0X THEN RetrieveFile(name) END
  END
END RetrieveCmd;

PROCEDURE ClearDoc(x: Ed);
VAR n: INTEGER;
BEGIN
  n := x.num;
  eds[n] := NewEd(n);
  IF e = x THEN e := eds[n] END
END ClearDoc;

PROCEDURE OtherDoc(): INTEGER;
BEGIN
  IF active = 1 THEN RETURN 2 ELSE RETURN 1 END
END OtherDoc;

PROCEDURE ExitCmd;
VAR o: INTEGER; save: BOOLEAN;
BEGIN
  IF e.isSub THEN RETURN END;
  IF e.anchor >= 0 THEN e.anchor := -1 END;
  save := YesNo("Save Document?", TRUE);
  IF yesNoCancelled THEN RETURN END;
  IF save THEN
    IF ~SaveDocument(e) THEN RETURN END
  END;
  IF YesNo("Exit WP? (Cancel to return to document)", FALSE) THEN
    o := OtherDoc();
    IF (eds[o] # NIL) & ((eds[o].d.n > 0) OR eds[o].modified) THEN
      (* the other document still has to be handled *)
      ClearDoc(e);
      active := o; e := eds[o];
      ShowMsg("Exit the other document as well (F7)")
    ELSE
      quit := TRUE
    END
  ELSIF ~yesNoCancelled THEN
    ClearDoc(e)
  END
END ExitCmd;

PROCEDURE SwitchDoc;
BEGIN
  active := OtherDoc();
  IF eds[active] = NIL THEN eds[active] := NewEd(active) END;
  e := eds[active]; e.dirty := TRUE
END SwitchDoc;

(* ====================================================================
   List Files (F5)
   ==================================================================== *)

CONST
  MaxFiles = 2000;

VAR
  lfName: ARRAY MaxFiles OF Path;
  lfDir: ARRAY MaxFiles OF BOOLEAN;
  lfMark: ARRAY MaxFiles OF BOOLEAN;
  lfSize: ARRAY MaxFiles OF INTEGER;
  lfTime: ARRAY MaxFiles OF LONGINT;
  lfN: INTEGER;

PROCEDURE GlobMatch(pat, s: ARRAY OF CHAR; p, i: INTEGER): BOOLEAN;
BEGIN
  LOOP
    IF pat[p] = 0X THEN RETURN s[i] = 0X END;
    IF pat[p] = "*" THEN
      WHILE pat[p] = "*" DO INC(p) END;
      IF pat[p] = 0X THEN RETURN TRUE END;
      WHILE s[i] # 0X DO
        IF GlobMatch(pat, s, p, i) THEN RETURN TRUE END;
        INC(i)
      END;
      RETURN FALSE
    END;
    IF s[i] = 0X THEN RETURN FALSE END;
    IF (pat[p] # "?") & (LoCh(pat[p]) # LoCh(s[i])) THEN RETURN FALSE END;
    INC(p); INC(i)
  END
END GlobMatch;

PROCEDURE NameMatches(pat, s: ARRAY OF CHAR): BOOLEAN;
BEGIN
  IF StrEq(pat, "*.*") OR StrEq(pat, "*") OR (pat[0] = 0X) THEN RETURN TRUE END;
  RETURN GlobMatch(pat, s, 0, 0)
END NameMatches;

PROCEDURE ReadDir(dir, pat: ARRAY OF CHAR);
VAR i, n: INTEGER; name: Path;
BEGIN
  lfN := 0;
  Cpy(".", lfName[0]); lfDir[0] := TRUE; lfMark[0] := FALSE; lfSize[0] := 0; lfTime[0] := 0;
  Cpy("..", lfName[1]); lfDir[1] := TRUE; lfMark[1] := FALSE; lfSize[1] := 0; lfTime[1] := 0;
  lfN := 2;
  OS.DirOpen(dir, "");
  n := OS.DirCount();
  FOR i := 0 TO n - 1 DO
    OS.DirName(i, name);
    IF (lfN < MaxFiles) & (name[0] # ".") &
       (OS.DirIsDir(i) # 0 OR NameMatches(pat, name)) THEN
      Cpy(name, lfName[lfN]); lfDir[lfN] := OS.DirIsDir(i) # 0; lfMark[lfN] := FALSE;
      lfSize[lfN] := OS.DirSize(i); lfTime[lfN] := OS.DirTime(i);
      INC(lfN)
    END
  END
END ReadDir;

PROCEDURE DocSize(x: Ed): INTEGER;
BEGIN
  BuildFile(x, fmtWP42); RETURN obLen
END DocSize;

PROCEDURE FileEntry(i: INTEGER; VAR s: ARRAY OF CHAR);
VAR t: Str; u: Path;
BEGIN
  IF i = 0 THEN Cpy(".  <CURRENT>", s); PadTo(s, 18); Append("<DIR>", s); RETURN END;
  IF i = 1 THEN Cpy(".. <PARENT>", s); PadTo(s, 18); Append("<DIR>", s); RETURN END;
  FromUtf8(lfName[i], u);
  IF SLen(u) > 15 THEN u[14] := "~"; u[15] := 0X END;
  Cpy(u, s); PadTo(s, 16);
  IF lfDir[i] THEN Append(" <DIR>  ", s)
  ELSE t[0] := 0X; AppendIntW(lfSize[i], 8, t); Append(t, s)
  END;
  AppendCh(" ", s);
  IF lfTime[i] > 0 THEN Time.Format(lfTime[i] * 1000, "%m/%d/%y %H:%M", t); Append(t, s) END
END FileEntry;

PROCEDURE DrawFiles(dir, pat: ARRAY OF CHAR; sel, top, rows: INTEGER; docSize: INTEGER);
VAR s, t: Path; i, r, c, x, y, fg, bg: INTEGER;
BEGIN
  ClearScreen;
  Time.Format(Time.Now(), "%m/%d/%y %H:%M", s);
  TextN(1, 1, s);
  Cpy("Directory ", s); FromUtf8(dir, t); Append(t, s); Append("/", s); Append(pat, s);
  TextN(20, 1, s);
  Cpy("Document Size: ", s); AppendIntW(docSize, 8, s);
  TextN(1, 2, s);
  Cpy("Free Disk Space: ", s); AppendLong(OS.FreeSpace(dir), s);
  TextN(41, 2, s);
  HLine(3, 2500H);
  FOR r := 0 TO rows - 1 DO
    FOR c := 0 TO 1 DO
      i := top + r * 2 + c;
      IF i < lfN THEN
        FileEntry(i, s);
        x := 1 + c * 41; y := 4 + r;
        fg := cFg; bg := cBg;
        IF i = sel THEN fg := cBg; bg := cFg END;
        IF lfMark[i] THEN PutCp(x, y, "*", cHi, cBg) END;
        Cpy(s, t); PadTo(t, 39);
        Text(x + 1, y, t, fg, bg)
      END
    END
  END;
  HLine(scrRows - 2, 2500H);
  MenuText(1, scrRows - 1, "1 Retrieve; 2 Delete; 3 Rename; 4 Print; 5 Text In;");
  MenuText(1, scrRows, "6 Look; 7 Change Directory; 8 Copy; 9 Word Search; 0 Exit: 6")
END DrawFiles;

PROCEDURE CopyFileTo(src, dst: ARRAY OF CHAR): BOOLEAN;
VAR buf: Bytes; len, i: INTEGER;
BEGIN
  IF ~LoadFile(src, buf, len) THEN RETURN FALSE END;
  ObReset;
  FOR i := 0 TO len - 1 DO Put(ORD(buf[i])) END;
  RETURN WriteOb(dst)
END CopyFileTo;

(* view a file without retrieving it *)
PROCEDURE LookFile(name: ARRAY OF CHAR);
VAR x: Ed; fmt, top, r, k, L: INTEGER; s: ARRAY 2048 OF CHAR; t: Path;
BEGIN
  x := NewEd(0);
  IF ~ReadFileInto(name, x.d, fmt) THEN RETURN END;
  Ensure(x);
  top := 0;
  LOOP
    ClearScreen;
    FOR r := 0 TO scrRows - 3 DO
      L := top + r;
      IF L < x.nlines THEN LineText(x, L, s); s[scrCols - 1] := 0X; TextN(1, r + 1, s) END
    END;
    HLine(scrRows - 1, 2500H);
    BaseName(name, t); FromUtf8(t, t);
    Cpy("Look: ", s); Append(t, s); Append("   (cursor keys scroll; any other key to exit)", s);
    TextN(1, scrRows, s);
    Flush;
    k := GetKey();
    IF IsNav(k, nDown, 0) THEN IF top < x.nlines - 1 THEN INC(top) END
    ELSIF IsNav(k, nUp, 0) THEN IF top > 0 THEN DEC(top) END
    ELSIF IsNav(k, nPgDn, 0) OR (k = ORD(" ")) THEN top := top + scrRows - 3;
      IF top >= x.nlines THEN top := x.nlines - 1 END
    ELSIF IsNav(k, nPgUp, 0) THEN top := top - (scrRows - 3); IF top < 0 THEN top := 0 END
    ELSE EXIT
    END
  END
END LookFile;

PROCEDURE FileContains(name, pat: ARRAY OF CHAR): BOOLEAN;
VAR x: Ed; r, i, j, m: INTEGER; low: Str;
BEGIN
  IF IsLocked(name) THEN RETURN FALSE END;
  x := NewEd(0);
  r := LoadDoc(name, x.d, "");
  IF r < 0 THEN RETURN FALSE END;
  Cpy(pat, low); Lower(low); m := SLen(low);
  IF m = 0 THEN RETURN TRUE END;
  FOR i := 0 TO x.d.n - m DO
    j := 0;
    WHILE (j < m) & (x.d.it[i + j].k = kChar) & (LoCh(x.d.it[i + j].ch) = low[j]) DO INC(j) END;
    IF j = m THEN RETURN TRUE END
  END;
  RETURN FALSE
END FileContains;

PROCEDURE ListFiles;
VAR dir, pat, s, full, q: Path; sel, top, rows, k, i, n, docSize: INTEGER;
    any, done: BOOLEAN; d: Doc; search: Str; buf: Bytes;
BEGIN
  OS.GetCwd(dir);
  Cpy(dir, s); Append("/*.*", s);
  IF ~Input("Dir ", s) THEN RETURN END;
  Trim(s);
  IF s[0] = "=" THEN
    Cpy(dir, s);
    IF ~Input("New directory = ", s) THEN RETURN END;
    IF ~OS.ChDir(s) THEN ErrMsg("Invalid drive/path specification"); RETURN END;
    OS.GetCwd(dir); Cpy(dir, s); Append("/*.*", s)
  END;
  (* split into directory and pattern *)
  BaseName(s, pat); DirPart(s, full);
  IF (Find("*", pat, 0) < 0) & (Find("?", pat, 0) < 0) THEN
    IF pat[0] # 0X THEN JoinPath(full, pat, full) END;
    Cpy("*.*", pat)
  END;
  IF full[0] # 0X THEN Cpy(full, dir) END;
  docSize := DocSize(e);
  ReadDir(dir, pat);
  sel := 2; IF lfN <= 2 THEN sel := 0 END;
  top := 0; done := FALSE;
  WHILE ~done DO
    rows := scrRows - 6;
    IF sel < top THEN top := (sel DIV 2) * 2 END;
    IF sel >= top + rows * 2 THEN top := (sel DIV 2 - rows + 1) * 2 END;
    DrawFiles(dir, pat, sel, top, rows, docSize); Flush;
    k := GetKey();
    JoinPath(dir, lfName[sel], full);
    any := FALSE; FOR i := 0 TO lfN - 1 DO any := any OR lfMark[i] END;
    IF IsNav(k, nDown, 0) THEN IF sel + 2 < lfN THEN sel := sel + 2 END
    ELSIF IsNav(k, nUp, 0) THEN IF sel >= 2 THEN sel := sel - 2 END
    ELSIF IsNav(k, nRight, 0) THEN IF sel + 1 < lfN THEN INC(sel) END
    ELSIF IsNav(k, nLeft, 0) THEN IF sel > 0 THEN DEC(sel) END
    ELSIF IsNav(k, nPgDn, 0) THEN sel := sel + rows * 2; IF sel >= lfN THEN sel := lfN - 1 END
    ELSIF IsNav(k, nPgUp, 0) THEN sel := sel - rows * 2; IF sel < 0 THEN sel := 0 END
    ELSIF IsNav(k, nHome, 0) THEN
      k := GetKey(); IF IsNav(k, nHome, 0) THEN k := GetKey() END;
      IF IsNav(k, nUp, 0) THEN sel := 0 ELSIF IsNav(k, nDown, 0) THEN sel := lfN - 1 END
    ELSIF k = ORD("*") THEN
      IF ~lfDir[sel] THEN lfMark[sel] := ~lfMark[sel] END;
      IF sel + 1 < lfN THEN INC(sel) END
    ELSIF k = KF + 205 THEN
      FOR i := 2 TO lfN - 1 DO IF ~lfDir[i] THEN lfMark[i] := ~any END END
    ELSIF IsCancel(k) OR (k = KF + 7) OR (k = KEnter) OR (k = ORD("0")) THEN done := TRUE
    ELSIF (k = ORD("1")) OR ((k = ORD("6")) & lfDir[sel]) THEN
      IF lfDir[sel] THEN
        IF OS.ChDir(full) THEN OS.GetCwd(dir); ReadDir(dir, pat); sel := 0; top := 0 END
      ELSE
        Redraw; RetrieveFile(full); done := TRUE
      END
    ELSIF k = ORD("2") THEN
      IF any THEN
        IF YesNo("Delete marked files?", FALSE) THEN
          FOR i := 2 TO lfN - 1 DO
            IF lfMark[i] THEN JoinPath(dir, lfName[i], q); Files.Delete(q) END
          END;
          ReadDir(dir, pat); IF sel >= lfN THEN sel := lfN - 1 END
        END
      ELSIF sel >= 2 THEN
        Cpy("Delete ", q); Append(lfName[sel], q); AppendCh("?", q);
        IF YesNo(q, FALSE) THEN
          IF lfDir[sel] THEN Cpy("rmdir ", s); AppendCh(22X, s); Append(full, s); AppendCh(22X, s);
            IF OS.Exec(s) # 0 THEN ErrMsg("Directory not empty") END
          ELSE Files.Delete(full)
          END;
          ReadDir(dir, pat); IF sel >= lfN THEN sel := lfN - 1 END
        END
      END
    ELSIF (k = ORD("3")) & (sel >= 2) THEN
      Cpy(lfName[sel], s);
      IF Input("New Name: ", s) & (s[0] # 0X) THEN
        JoinPath(dir, s, q); Files.Rename(full, q); ReadDir(dir, pat)
      END
    ELSIF k = ORD("4") THEN
      IF any THEN
        FOR i := 2 TO lfN - 1 DO IF lfMark[i] THEN JoinPath(dir, lfName[i], q); PrintFile(q) END END
      ELSIF ~lfDir[sel] THEN PrintFile(full)
      END
    ELSIF (k = ORD("5")) & ~lfDir[sel] THEN
      d := NewDoc();
      IF LoadFile(full, buf, n) THEN ImportText(buf^, n, d, FALSE);
        i := InsDoc(e.d, e.cur, d); Touch(e)
      END;
      done := TRUE
    ELSIF k = ORD("6") THEN LookFile(full)
    ELSIF k = ORD("7") THEN
      Cpy(dir, s);
      IF Input("New directory = ", s) THEN
        IF ~OS.ChDir(s) THEN
          Cpy("mkdir -p ", q); AppendCh(22X, q); Append(s, q); AppendCh(22X, q);
          IF YesNo("Create new directory?", FALSE) & (OS.Exec(q) = 0) & OS.ChDir(s) THEN END
        END;
        OS.GetCwd(dir); ReadDir(dir, pat); sel := 0; top := 0
      END
    ELSIF (k = ORD("8")) & (sel >= 2) & ~lfDir[sel] THEN
      s[0] := 0X;
      IF Input("Copy this file to: ", s) & (s[0] # 0X) THEN
        JoinPath(dir, s, q);
        IF ~CopyFileTo(full, q) THEN ErrMsg("Can't copy file") END;
        ReadDir(dir, pat)
      END
    ELSIF k = ORD("9") THEN
      search[0] := 0X;
      IF Input("Word Pattern: ", search) & (search[0] # 0X) THEN
        ClearRow(scrRows); TextN(1, scrRows, "* Searching *"); Flush;
        n := 2;
        FOR i := 2 TO lfN - 1 DO
          JoinPath(dir, lfName[i], q);
          IF ~lfDir[i] & FileContains(q, search) THEN
            Cpy(lfName[i], lfName[n]); lfDir[n] := FALSE; lfMark[n] := FALSE;
            lfSize[n] := lfSize[i]; lfTime[n] := lfTime[i]; INC(n)
          END
        END;
        lfN := n; sel := 0; top := 0
      END
    ELSIF (k >= ORD("A")) & (k <= ORD("z")) THEN
      (* name search *)
      search[0] := CHR(k); search[1] := 0X;
      LOOP
        n := -1;
        FOR i := lfN - 1 TO 2 BY -1 DO
          IF (StrCmpCI(lfName[i], search) >= 0) & (FindCI(search, lfName[i]) = 0) THEN n := i END
        END;
        IF n >= 0 THEN sel := n END;
        IF sel < top THEN top := (sel DIV 2) * 2 END;
        IF sel >= top + rows * 2 THEN top := (sel DIV 2 - rows + 1) * 2 END;
        DrawFiles(dir, pat, sel, top, rows, docSize);
        ClearRow(scrRows); Text(1, scrRows, "(Name Search; Enter or arrows to Exit) ", cFg, cBg);
        Text(40, scrRows, search, cHi, cBg); Flush;
        k := GetKey();
        IF (k >= 32) & (k < 127) THEN AppendCh(CHR(k), search)
        ELSIF k = KBS THEN IF SLen(search) > 0 THEN search[SLen(search) - 1] := 0X END
        ELSE EXIT
        END
      END
    END;
  END;
  e.dirty := TRUE
END ListFiles;

(* ====================================================================
   Format commands
   ==================================================================== *)

PROCEDURE CurFmt(VAR st: Fmt);
VAR L, i: INTEGER;
BEGIN
  Ensure(e);
  L := LineOf(e, e.cur);
  st := e.snaps[e.lines[L].snap];
  FOR i := e.lines[L].start TO e.cur - 1 DO ApplyCode(e.d.it[i], st) END
END CurFmt;

(* codes that must start a line get a hard return in front of them *)
PROCEDURE AtLineStart;
BEGIN
  Ensure(e);
  IF e.cur > e.lines[LineOf(e, e.cur)].start THEN
    IF (e.d.it[e.cur - 1].k = kChar) OR (e.d.it[e.cur - 1].k = kTab) THEN
      InsertCode(kHRt, 0, 0, 0)
    END
  END
END AtLineStart;

PROCEDURE ParseHalf(s: ARRAY OF CHAR; VAR h: INTEGER): BOOLEAN;
VAR i, n: INTEGER;
BEGIN
  n := 0; i := 0;
  WHILE s[i] = " " DO INC(i) END;
  IF ~IsDigit(s[i]) THEN RETURN FALSE END;
  WHILE IsDigit(s[i]) DO n := n * 10 + ORD(s[i]) - ORD("0"); INC(i) END;
  h := n * 2;
  IF (s[i] = ".") & (s[i + 1] = "5") THEN INC(h) END;
  RETURN h > 0
END ParseHalf;

(* ---- the tab ruler (Line Format 1/2) ---- *)

PROCEDURE TabTypeChar(t: CHAR): CHAR;
BEGIN
  CASE ORD(t) - 1 OF
    0: RETURN "L" | 1: RETURN "C" | 2: RETURN "R" | 3: RETURN "D"
  | 4: RETURN "l" | 6: RETURN "r" | 7: RETURN "d"
  ELSE RETURN "L"
  END
END TabTypeChar;

PROCEDURE EditTabs(VAR st: Fmt): BOOLEAN;
VAR pos, off, k, c, x, y, i, n, inc: INTEGER; s: Str; t: CHAR; num: Str;
BEGIN
  pos := 0; off := 0;
  LOOP
    IF pos < off THEN off := (pos DIV 10) * 10 END;
    IF pos >= off + scrCols - 1 THEN off := ((pos - scrCols + 11) DIV 10) * 10 END;
    Redraw;
    y := scrRows - 4;
    FOR i := y TO scrRows DO ClearRow(i) END;
    FOR c := 1 TO scrCols DO
      x := c - 1 + off;
      IF x <= 250 THEN
        IF st.tabs[x] # 0X THEN PutCp(c, y, TabTypeChar(st.tabs[x]), cHi, cBg)
        ELSE PutCp(c, y, ".", cFg, cBg)
        END;
        IF x MOD 10 = 0 THEN
          IntStr(x, s);
          IF c + SLen(s) - 1 <= scrCols THEN TextN(c, y + 1, s) END
        END
      END
    END;
    MenuText(1, scrRows - 1, "Delete EOL (clear tabs); Enter number (set tab); Del (clear tab);");
    MenuText(1, scrRows, "Left; Center; Right; Decimal; .= Dot Leader; Press EXIT when done.");
    TUI.SetCursor(pos - off + 1, y); Flush;
    k := GetKey();
    IF k = KF + 7 THEN Terminal.HideCursor(); RETURN TRUE
    ELSIF IsCancel(k) THEN Terminal.HideCursor(); RETURN FALSE
    ELSIF IsNav(k, nLeft, 0) THEN IF pos > 0 THEN DEC(pos) END
    ELSIF IsNav(k, nRight, 0) THEN IF pos < 250 THEN INC(pos) END
    ELSIF IsNav(k, nHome, 0) THEN
      k := GetKey();
      IF IsNav(k, nLeft, 0) THEN pos := off ELSIF IsNav(k, nRight, 0) THEN pos := off + scrCols - 2 END;
      IF IsNav(k, nHome, 0) THEN k := GetKey();
        IF IsNav(k, nLeft, 0) THEN pos := 0 ELSIF IsNav(k, nRight, 0) THEN pos := 250 END
      END
    ELSIF IsNav(k, nEnd, 4) THEN FOR i := pos TO 250 DO st.tabs[i] := 0X END
    ELSIF IsNav(k, nDel, 0) OR (k = KBS) THEN st.tabs[pos] := 0X
    ELSIF k = KTab THEN
      i := pos + 1; WHILE (i < 250) & (st.tabs[i] = 0X) DO INC(i) END; pos := i
    ELSIF (k >= ORD("0")) & (k <= ORD("9")) THEN
      num[0] := CHR(k); num[1] := 0X; inputSeeded := TRUE;
      IF InputEx("Set tab at: ", num, 0, k) THEN
        i := Find(",", num, 0);
        IF i >= 0 THEN
          Sub(num, i + 1, 10, s); num[i] := 0X;
          IF StrInt(num, n) & StrInt(s, inc) & (inc > 0) THEN
            WHILE n <= 250 DO st.tabs[n] := 1X; n := n + inc END
          END
        ELSIF StrInt(num, n) & (n >= 0) & (n <= 250) THEN
          st.tabs[n] := 1X; pos := n
        END
      END
    ELSE
      t := KeyChar(k);
      IF t = "L" THEN st.tabs[pos] := 1X
      ELSIF t = "C" THEN st.tabs[pos] := 2X
      ELSIF t = "R" THEN st.tabs[pos] := 3X
      ELSIF t = "D" THEN st.tabs[pos] := 4X
      ELSIF (t = ".") & (st.tabs[pos] # 0X) THEN
        CASE ORD(st.tabs[pos]) OF
          1: st.tabs[pos] := 5X | 5: st.tabs[pos] := 1X | 3: st.tabs[pos] := 7X
        | 7: st.tabs[pos] := 3X | 4: st.tabs[pos] := 8X | 8: st.tabs[pos] := 4X
        ELSE
        END
      END
    END
  END
END EditTabs;

PROCEDURE InsertTabSet(VAR st: Fmt);
VAR it: Item;
BEGIN
  MkItem(kTabSet, 0, 0, 0, it);
  it.s := NewBytes(52); it.sl := 52;
  TabsToBytes(st, it.s^);
  InsertItem(it)
END InsertTabSet;

PROCEDURE LineFormat;
VAR c: CHAR; st: Fmt; s: Str; l, r, h: INTEGER;
BEGIN
  c := MenuKey("1 2 Tabs; 3 Margins; 4 Spacing; 5 Hyphenation; 6 Align Char: 0");
  CurFmt(st);
  IF (c = "1") OR (c = "2") THEN
    IF EditTabs(st) THEN InsertTabSet(st) END
  ELSIF c = "3" THEN
    l := st.lm; r := st.rm;
    Cpy("[Margin Set] ", s); AppendInt(st.lm, s); AppendCh(" ", s); AppendInt(st.rm, s);
    Append(" to Left = ", s);
    IF InputInt(s, l) THEN
      Append(" ", s); AppendInt(l, s); Append(" Right = ", s);
      IF InputInt(s, r) & (l >= 0) & (r <= 250) & (l < r) THEN
        AtLineStart; InsertCode(kMargin, l, r, 0)
      END
    END
  ELSIF c = "4" THEN
    Cpy("", s); AppendInt(st.spacing DIV 2, s); IF ODD(st.spacing) THEN Append(".5", s) END;
    IF Input("[Spacing Set] ", s) & ParseHalf(s, h) THEN InsertCode(kSpacing, h, 0, 0) END
  ELSIF c = "5" THEN
    c := MenuKey("1 On; 2 Off; 3 Set H-Zone; 4 Aided; 5 Auto: 0");
    IF c = "1" THEN InsertCode(kSingle, fHyphOn, 0, 0)
    ELSIF c = "2" THEN InsertCode(kSingle, fHyphOff, 0, 0)
    ELSIF c = "3" THEN
      l := st.hzL; r := st.hzR;
      Cpy("[HZone Set] ", s); AppendInt(st.hzL, s); AppendCh(" ", s); AppendInt(st.hzR, s); Append(" to Left = ", s);
      IF InputInt(s, l) THEN
        Append(" Right = ", s);
        IF InputInt(s, r) THEN InsertCode(kHZone, l, r, 0) END
      END
    END
  ELSIF c = "6" THEN
    l := StatusPrompt("Align Char = "); Flush;
    h := GetKey();
    IF (h > 32) & (h < 127) THEN InsertCode(kAlignChar, h, 0, 0) END
  END
END LineFormat;

(* ---- header/footer, note and comment editing ---- *)

PROCEDURE EditSub(d: Doc; title: ARRAY OF CHAR; lm, rm: INTEGER);
VAR x: Ed;
BEGIN
  x := SubEd(d, title, lm, rm);
  x.cur := d.n;
  RunSub(x);
  e.dirty := TRUE; Touch(e)
END EditSub;

PROCEDURE FindCodeBack(k, a: INTEGER; useA: BOOLEAN): INTEGER;
VAR i: INTEGER;
BEGIN
  i := e.cur - 1;
  WHILE i >= 0 DO
    IF (e.d.it[i].k = k) & (~useA OR (e.d.it[i].a MOD 4 = a)) THEN RETURN i END;
    DEC(i)
  END;
  RETURN -1
END FindCodeBack;

PROCEDURE HeaderFooter;
VAR t, o, i: INTEGER; st: Fmt; it: Item; title: Str;
BEGIN
  ClearScreen;
  TextB(25, 2, "Header/Footer Specification");
  TextB(5, 4, "Type"); TextB(45, 4, "Occurrence");
  MenuText(5, 6, "1 - Header A"); MenuText(45, 6, "0 - Discontinue");
  MenuText(5, 7, "2 - Header B"); MenuText(45, 7, "1 - Every Page");
  MenuText(5, 8, "3 - Footer A"); MenuText(45, 8, "2 - Odd Pages");
  MenuText(5, 9, "4 - Footer B"); MenuText(45, 9, "3 - Even Pages");
  MenuText(45, 10, "4 - Edit");
  TextN(5, 12, "Selection: 0"); TUI.SetCursor(16, 12); Flush;
  t := GetKey();
  IF (t < ORD("1")) OR (t > ORD("4")) THEN Terminal.HideCursor(); RETURN END;
  t := t - ORD("1");
  TextN(5, 12, "Selection: "); PutCp(16, 12, CHR(t + ORD("1")), cHi, cBg);
  TextN(45, 12, "Selection: 0"); TUI.SetCursor(56, 12); Flush;
  o := GetKey(); Terminal.HideCursor();
  IF (o < ORD("0")) OR (o > ORD("4")) THEN RETURN END;
  o := o - ORD("0");
  CurFmt(st);
  IF t < 2 THEN Cpy("Header ", title) ELSE Cpy("Footer ", title) END;
  IF ODD(t) THEN AppendCh("B", title) ELSE AppendCh("A", title) END;
  Append(": Press EXIT when done", title);
  IF o = 4 THEN
    i := FindCodeBack(kHdrFtr, t, TRUE);
    IF (i >= 0) & (e.d.it[i].sub # NIL) THEN
      EditSub(e.d.it[i].sub, title, e.d.it[i].b, e.d.it[i].c)
    ELSE ErrMsg("Header/footer not found")
    END
  ELSE
    IF o = 3 THEN o := 4 END;           (* even pages = bit 4 *)
    MkItem(kHdrFtr, t + 4 * o, st.lm, st.rm, it);
    it.sub := NewDoc();
    InsertItem(it);
    IF o # 0 THEN EditSub(e.d.it[e.cur - 1].sub, title, st.lm, st.rm) END
  END
END HeaderFooter;

PROCEDURE PageNumPos;
VAR k: INTEGER;
BEGIN
  ClearScreen;
  TextB(20, 2, "Position of Page Number on Page");
  MenuText(10, 4, "0 - No page numbers");
  MenuText(10, 5, "1 - Top left of every page");
  MenuText(10, 6, "2 - Top center of every page");
  MenuText(10, 7, "3 - Top right of every page");
  MenuText(10, 8, "4 - Top alternating left & right");
  MenuText(10, 9, "5 - Bottom left of every page");
  MenuText(10, 10, "6 - Bottom center of every page");
  MenuText(10, 11, "7 - Bottom right of every page");
  MenuText(10, 12, "8 - Bottom alternating left & right");
  TextN(10, 14, "Selection: 0"); TUI.SetCursor(21, 14); Flush;
  k := GetKey(); Terminal.HideCursor();
  IF (k >= ORD("0")) & (k <= ORD("8")) THEN InsertCode(kPnPos, k - ORD("0"), 0, 0) END
END PageNumPos;

PROCEDURE PageLength;
VAR k, f, t: INTEGER; st: Fmt; s: Str;
BEGIN
  CurFmt(st);
  ClearScreen;
  TextB(30, 2, "Page Length");
  MenuText(5, 4, "1 - Letter Size Paper: Form Length = 66 lines (11 inches)");
  TextN(9, 5, "Single Spaced Text lines = 54 (This includes lines used for Headers,");
  TextN(9, 6, "Footers and/or page numbers.)");
  MenuText(5, 8, "2 - Legal Size Paper: Form Length = 84 lines (14 inches)");
  TextN(9, 9, "Single Spaced Text Lines = 72 (This includes lines used for Headers,");
  TextN(9, 10, "Footers and/or page numbers.)");
  MenuText(5, 12, "3 - Other (Maximum page length = 108 lines.)");
  TextN(5, 14, "Current Settings");
  Cpy("Form Length in Lines (6 per inch): ", s); AppendInt(st.formLen, s); TextN(9, 16, s);
  Cpy("Number of Single Spaced Text Lines: ", s); AppendInt(st.textHalf DIV 2, s); TextN(9, 17, s);
  TextN(5, 19, "Selection: 0"); TUI.SetCursor(16, 19); Flush;
  k := GetKey(); Terminal.HideCursor();
  IF k = ORD("1") THEN InsertCode(kFormLen, 66, 108, 0)
  ELSIF k = ORD("2") THEN InsertCode(kFormLen, 84, 144, 0)
  ELSIF k = ORD("3") THEN
    f := st.formLen; t := st.textHalf DIV 2;
    IF InputInt("Form Length in Lines (6 per inch): ", f) &
       InputInt("Number of Single Spaced Text Lines: ", t) & (f > 0) & (f <= 108) & (t > 0) & (t <= f) THEN
      InsertCode(kFormLen, f, t * 2, 0)
    END
  END
END PageLength;

PROCEDURE PnColumns;
VAR k, l, c, r: INTEGER; st: Fmt; s: Str;
BEGIN
  CurFmt(st);
  ClearScreen;
  TextB(20, 2, "Reset Column Position for Page Numbers");
  TextN(15, 3, "(L = Left Corner, C = Center, R = Right Corner)");
  MenuText(5, 5, "1 - Set to Initial Settings (In tenths of an inch)");
  TextN(9, 6, "L=10 C=42 R=74");
  MenuText(5, 8, "2 - Set to Specified Settings");
  TextN(5, 10, "Current Settings");
  Cpy("L=", s); AppendInt(st.pnL, s); Append(" C=", s); AppendInt(st.pnC, s);
  Append(" R=", s); AppendInt(st.pnR, s); TextN(9, 11, s);
  TextN(5, 13, "Selection: 0"); TUI.SetCursor(16, 13); Flush;
  k := GetKey(); Terminal.HideCursor();
  IF k = ORD("1") THEN InsertCode(kPnCol, 10, 42, 74)
  ELSIF k = ORD("2") THEN
    l := st.pnL; c := st.pnC; r := st.pnR;
    IF InputInt("L=", l) & InputInt("C=", c) & InputInt("R=", r) THEN InsertCode(kPnCol, l, c, r) END
  END
END PnColumns;

PROCEDURE SuppressMenu;
VAR s: Str; i, bits: INTEGER; k: INTEGER;
BEGIN
  ClearScreen;
  TextB(20, 2, "Suppress Page Format for Current Page Only");
  TextN(5, 4, "To temporarily turn off multiple items, include a '+' between menu entries.");
  TextN(5, 5, "For example 5+6+2 will turn off Header A, Header B, and Page Numbering");
  TextN(5, 6, "for the current page.");
  MenuText(5, 8, "1 - Turn off all page numbering, headers and footers");
  MenuText(5, 9, "2 - Turn page numbering off");
  MenuText(5, 10, "3 - Print page number at bottom center (this page only)");
  MenuText(5, 11, "4 - Turn off all headers and footers");
  MenuText(5, 12, "5 - Turn off Header A");
  MenuText(5, 13, "6 - Turn off Header B");
  MenuText(5, 14, "7 - Turn off Footer A");
  MenuText(5, 15, "8 - Turn off Footer B");
  Flush;
  s[0] := 0X;
  IF ~Input("Selection(s): ", s) THEN RETURN END;
  bits := 0; i := 0;
  WHILE s[i] # 0X DO
    k := ORD(s[i]) - ORD("0");
    CASE k OF
      1: bits := bits + 1 | 2: bits := bits + 2 | 3: bits := bits + 4 | 4: bits := bits + 8
    | 5: bits := bits + 16 | 6: bits := bits + 32 | 7: bits := bits + 64 | 8: bits := bits + 128
    ELSE
    END;
    INC(i)
  END;
  IF bits > 0 THEN InsertCode(kSuppress, bits, 0, 0) END
END SuppressMenu;

PROCEDURE PageFormat;
VAR k, n: INTEGER; s: Str; c: CHAR;
BEGIN
  LOOP
    ClearScreen;
    TextB(30, 2, "Page Format");
    MenuText(5, 4, "1 - Page Number Position");
    MenuText(5, 6, "2 - New Page Number");
    MenuText(5, 8, "3 - Center Page Top to Bottom");
    MenuText(5, 10, "4 - Page Length");
    MenuText(5, 12, "5 - Top Margin");
    MenuText(5, 14, "6 - Headers or Footers");
    MenuText(5, 16, "7 - Page Number Column Positions");
    MenuText(5, 18, "8 - Suppress for Current page only");
    MenuText(5, 20, "9 - Conditional End of Page");
    TextN(5, 22, "A"); TextN(6, 22, " - Widow/Orphan"); PutCp(5, 22, "A", cHi, cBg);
    TextN(5, 24, "Selection: 0"); TUI.SetCursor(16, 24); Flush;
    k := GetKey(); Terminal.HideCursor();
    c := KeyChar(k);
    IF c = "1" THEN PageNumPos
    ELSIF c = "2" THEN
      n := 1;
      IF InputInt("New Page #: ", n) & (n > 0) THEN
        c := MenuKey("Numbering Style: 1 Arabic; 2 Roman: 0");
        IF c = "2" THEN InsertCode(kPgNum, n, 1, 0) ELSE InsertCode(kPgNum, n, 0, 0) END
      END
    ELSIF c = "3" THEN InsertCode(kSingle, fCenterPg, 0, 0)
    ELSIF c = "4" THEN PageLength
    ELSIF c = "5" THEN
      n := 12; Cpy("Set half-lines (12/inch) from 12 to ", s);
      IF InputInt(s, n) & (n >= 0) THEN InsertCode(kTopMar, n, 0, 0) END
    ELSIF c = "6" THEN HeaderFooter
    ELSIF c = "7" THEN PnColumns
    ELSIF c = "8" THEN SuppressMenu
    ELSIF c = "9" THEN
      n := 0;
      IF InputInt("Number of lines to keep together = ", n) & (n > 0) THEN InsertCode(kCondEOP, n, 0, 0) END
    ELSIF c = "A" THEN
      IF YesNo("Widow/Orphan Protect?", FALSE) THEN InsertCode(kSingle, fWOOn, 0, 0)
      ELSIF ~yesNoCancelled THEN InsertCode(kSingle, fWOOff, 0, 0)
      END
    ELSE EXIT
    END
  END;
  e.dirty := TRUE
END PageFormat;

(* ---- Print Format (Ctrl-F8) ---- *)

PROCEDURE ParseCmd(s: ARRAY OF CHAR; VAR it: Item);
VAR i, n, v: INTEGER; buf: ARRAY 256 OF CHAR;
BEGIN
  i := 0; n := 0;
  WHILE (s[i] # 0X) & (n < 250) DO
    IF s[i] = "<" THEN
      INC(i); v := 0;
      WHILE IsDigit(s[i]) DO v := v * 10 + ORD(s[i]) - ORD("0"); INC(i) END;
      IF s[i] = ">" THEN INC(i) END;
      buf[n] := CHR(v MOD 256); INC(n)
    ELSE buf[n] := s[i]; INC(n); INC(i)
    END
  END;
  MkItem(kPrnCmd, 0, 0, 0, it);
  it.s := NewBytes(n + 1); it.sl := n;
  FOR i := 0 TO n - 1 DO it.s[i] := buf[i] END
END ParseCmd;

PROCEDURE LineNumbering;
VAR k, n: INTEGER; st: Fmt; s: Str; on, blanks, restart: BOOLEAN; every, pos: INTEGER;
BEGIN
  CurFmt(st);
  on := st.lineNum >= 128; blanks := ~ODD(st.lineNum DIV 64); restart := ODD(st.lineNum DIV 32);
  every := st.lineNum MOD 32; IF every = 0 THEN every := 1 END;
  pos := st.lnPos;
  LOOP
    ClearScreen;
    TextB(30, 2, "Line Numbering");
    MenuText(5, 4, "1 - Turn off"); IF ~on THEN TextN(50, 4, "Off") END;
    MenuText(5, 5, "2 - Turn on"); IF on THEN TextN(50, 5, "On") END;
    MenuText(5, 7, "3 - Count blank lines?"); IF blanks THEN TextN(50, 7, "Y") ELSE TextN(50, 7, "N") END;
    MenuText(5, 8, "4 - Number every n lines, where n ="); IntStr(every, s); TextN(50, 8, s);
    MenuText(5, 9, "5 - Position of number from left edge:"); IntStr(pos, s); TextN(50, 9, s);
    TextN(9, 10, "(in tenths of an inch)");
    MenuText(5, 11, "6 - Restart numbering on each page?"); IF restart THEN TextN(50, 11, "Y") ELSE TextN(50, 11, "N") END;
    TextN(5, 13, "Selection: 0"); TUI.SetCursor(16, 13); Flush;
    k := GetKey(); Terminal.HideCursor();
    IF k = ORD("1") THEN on := FALSE
    ELSIF k = ORD("2") THEN on := TRUE
    ELSIF k = ORD("3") THEN blanks := YesNo("Count blank lines?", blanks)
    ELSIF k = ORD("4") THEN n := every; IF InputInt("Number every n lines, where n = ", n) & (n > 0) & (n < 31) THEN every := n END
    ELSIF k = ORD("5") THEN n := pos; IF InputInt("Position of number from left edge: ", n) THEN pos := n END
    ELSIF k = ORD("6") THEN restart := YesNo("Restart numbering on each page?", restart)
    ELSE EXIT
    END
  END;
  n := every;
  IF on THEN n := n + 128 END;
  IF ~blanks THEN n := n + 64 END;
  IF restart THEN n := n + 32 END;
  IF n # st.lineNum THEN InsertCode(kLineNum, n, pos, 0) END
END LineNumbering;

PROCEDURE PrintFormat;
VAR k, p, f, n: INTEGER; st: Fmt; s: Str; c: CHAR; it: Item;
BEGIN
  LOOP
    CurFmt(st);
    ClearScreen;
    TextB(30, 2, "Print Format");
    MenuText(5, 4, "1 - Pitch"); IntStr(ABS(st.pitch), s); IF st.pitch < 0 THEN AppendCh("*", s) END; TextN(50, 4, s);
    TextN(9, 5, "Font"); IntStr(st.font, s); TextN(50, 5, s);
    MenuText(5, 7, "2 - Lines per Inch"); IntStr(st.lpi, s); TextN(50, 7, s);
    TextN(9, 9, "Right Justification"); IF st.just THEN TextN(50, 9, "On") ELSE TextN(50, 9, "Off") END;
    MenuText(5, 10, "3 - Turn off");
    MenuText(5, 11, "4 - Turn on");
    TextN(9, 13, "Underline Style"); IntStr(st.undMode + 5, s); TextN(50, 13, s);
    MenuText(5, 14, "5 - Non-continuous Single");
    MenuText(5, 15, "6 - Non-continuous Double");
    MenuText(5, 16, "7 - Continuous Single");
    MenuText(5, 17, "8 - Continuous Double");
    MenuText(5, 19, "9 - Sheet Feeder Bin Number"); IntStr(st.bin, s); TextN(50, 19, s);
    TextN(5, 21, "A - Insert Printer Command"); PutCp(5, 21, "A", cHi, cBg);
    TextN(5, 23, "B - Line Numbering"); PutCp(5, 23, "B", cHi, cBg);
    IF st.lineNum >= 128 THEN TextN(50, 23, "On") ELSE TextN(50, 23, "Off") END;
    TextN(5, 25, "Selection: 0"); TUI.SetCursor(16, 25); Flush;
    k := GetKey(); Terminal.HideCursor();
    c := KeyChar(k);
    IF c = "1" THEN
      IntStr(ABS(st.pitch), s); IF st.pitch < 0 THEN AppendCh("*", s) END;
      IF Input("Pitch: ", s) THEN
        p := 0; n := 0;
        WHILE IsDigit(s[n]) DO p := p * 10 + ORD(s[n]) - ORD("0"); INC(n) END;
        IF s[n] = "*" THEN p := -p END;
        f := st.font;
        IF (p # 0) & InputInt("Font: ", f) THEN InsertCode(kFont, p, f, 0) END
      END
    ELSIF c = "2" THEN
      n := st.lpi;
      IF InputInt("Lines per inch (6 or 8): ", n) & ((n = 6) OR (n = 8)) THEN InsertCode(kLPI, n, 0, 0) END
    ELSIF c = "3" THEN InsertCode(kSingle, fJustOff, 0, 0)
    ELSIF c = "4" THEN InsertCode(kSingle, fJustOn, 0, 0)
    ELSIF (c >= "5") & (c <= "8") THEN
      CASE ORD(c) - ORD("5") OF 0: n := 0 | 1: n := 1 | 2: n := 2 | 3: n := 3 END;
      InsertCode(kUndMode, n, 0, 0)
    ELSIF c = "9" THEN
      n := st.bin; IF InputInt("Bin number: ", n) & (n > 0) THEN InsertCode(kBin, n, 0, 0) END
    ELSIF c = "A" THEN
      s[0] := 0X;
      IF Input("Cmnd: ", s) & (s[0] # 0X) THEN ParseCmd(s, it); InsertItem(it) END
    ELSIF c = "B" THEN LineNumbering
    ELSE EXIT
    END
  END;
  e.dirty := TRUE
END PrintFormat;

(* ---- Super/Subscript (Shift-F1) ---- *)

PROCEDURE ScriptBlock(code: INTEGER);
VAR ba, bb, i: INTEGER;
BEGIN
  IF ~BlockRange(e, ba, bb) THEN RETURN END;
  i := bb - 1;
  WHILE i >= ba DO
    IF e.d.it[i].k = kChar THEN InsertCodeAt(i, kSingle, code, 0, 0) END;
    DEC(i)
  END;
  e.anchor := -1
END ScriptBlock;

PROCEDURE SuperSub;
VAR c: CHAR; n: INTEGER;
BEGIN
  c := MenuKey("1 Superscript; 2 Subscript; 3 Overstrike; 4 Adv Up; 5 Adv Dn; 6 Adv Ln: 0");
  IF c = "1" THEN
    IF e.anchor >= 0 THEN ScriptBlock(fSuper) ELSE InsertCode(kSingle, fSuper, 0, 0) END
  ELSIF c = "2" THEN
    IF e.anchor >= 0 THEN ScriptBlock(fSub) ELSE InsertCode(kSingle, fSub, 0, 0) END
  ELSIF c = "3" THEN InsertCode(kSingle, fOvrstk, 0, 0)
  ELSIF c = "4" THEN InsertCode(kSingle, fAdvUp, 0, 0)
  ELSIF c = "5" THEN InsertCode(kSingle, fAdvDn, 0, 0)
  ELSIF c = "6" THEN
    n := 1;
    IF InputInt("Adv. to line: ", n) & (n > 0) THEN InsertCode(kAdvLn, n * 2, 0, 0) END
  END
END SuperSub;

(* ---- Date (Shift-F5) ---- *)

PROCEDURE DateFormatScreen;
VAR s: Str;
BEGIN
  ClearScreen;
  TextB(30, 2, "Date Format");
  TextB(5, 4, "Character"); TextB(20, 4, "Meaning");
  TextN(9, 5, "1"); TextN(20, 5, "Day of the month");
  TextN(9, 6, "2"); TextN(20, 6, "Month (number)");
  TextN(9, 7, "3"); TextN(20, 7, "Month (word)");
  TextN(9, 8, "4"); TextN(20, 8, "Year (all four digits)");
  TextN(9, 9, "5"); TextN(20, 9, "Year (last two digits)");
  TextN(9, 10, "6"); TextN(20, 10, "Day of the week (word)");
  TextN(9, 11, "7"); TextN(20, 11, "Hour (24-hour clock)");
  TextN(9, 12, "8"); TextN(20, 12, "Hour (12-hour clock)");
  TextN(9, 13, "9"); TextN(20, 13, "Minute");
  TextN(9, 14, "0"); TextN(20, 14, "am / pm");
  TextN(9, 15, "%"); TextN(20, 15, "Include leading zero for numbers less than 10");
  TextN(20, 16, "(must directly precede number)");
  TextN(5, 18, "Examples: 3 1, 4      = December 25, 1984");
  TextN(15, 19, "%2/%1/5 (6) = 01/01/85 (Tuesday)");
  Flush;
  Cpy(cfg.dateFmt, s);
  IF Input("Date Format: ", s) & (s[0] # 0X) THEN
    s[29] := 0X; Cpy(s, cfg.dateFmt)
  END
END DateFormatScreen;

PROCEDURE DateCmd;
VAR c: CHAR; s: Str; it: Item; i: INTEGER;
BEGIN
  c := MenuKey("Date: 1 Insert Text; 2 Format; 3 Insert Function: 0");
  IF c = "1" THEN
    FormatDate(cfg.dateFmt, s);
    i := 0; WHILE s[i] # 0X DO InsertChar(s[i]); INC(i) END
  ELSIF c = "2" THEN DateFormatScreen
  ELSIF c = "3" THEN
    MkItem(kDate, 0, 0, 0, it); SetStr(it, cfg.dateFmt); InsertItem(it)
  END
END DateCmd;

(* ---- Footnotes and endnotes (Ctrl-F7) ---- *)

PROCEDURE FindNote(endnote: BOOLEAN; num: INTEGER): INTEGER;
VAR i: INTEGER;
BEGIN
  Ensure(e);
  FOR i := 0 TO e.d.n - 1 DO
    IF (e.d.it[i].k = kNote) & (ODD(e.d.it[i].a DIV 2) = endnote) & (e.d.it[i].b = num) THEN RETURN i END
  END;
  RETURN -1
END FindNote;

PROCEDURE NextNoteNum(endnote: BOOLEAN): INTEGER;
VAR i: INTEGER;
BEGIN
  Ensure(e);
  FOR i := e.cur TO e.d.n - 1 DO
    IF (e.d.it[i].k = kNote) & (ODD(e.d.it[i].a DIV 2) = endnote) THEN RETURN e.d.it[i].b END
  END;
  RETURN 1
END NextNoteNum;

PROCEDURE EditNote(i: INTEGER);
VAR title: Str; st: Fmt;
BEGIN
  CurFmt(st);
  noteCtx := e.d.it[i].b;
  IF ODD(e.d.it[i].a DIV 2) THEN Cpy("Endnote ", title) ELSE Cpy("Footnote ", title) END;
  AppendInt(e.d.it[i].b, title); Append(": Press EXIT when done", title);
  EditSub(e.d.it[i].sub, title, st.lm, st.rm)
END EditNote;

PROCEDURE CreateNote(endnote: BOOLEAN);
VAR it: Item; a: INTEGER;
BEGIN
  IF endnote THEN a := 2 ELSE a := 0 END;
  MkItem(kNote, a, 0, 0, it);
  it.sub := NewDoc();
  AddK(it.sub, kSingle, fNoteNum, 0, 0);
  AddCh(it.sub, " ");
  InsertItem(it);
  Ensure(e);
  EditNote(e.cur - 1);
  e.dirty := TRUE
END CreateNote;

PROCEDURE NoteOptions;
VAR o: ARRAY NoteLen OF CHAR; st: Fmt; k, i, v, flag: INTEGER; s: Str; it: Item;
BEGIN
  CurFmt(st);
  FOR i := 0 TO NoteLen - 1 DO o[i] := st.noteOpt[i] END;
  LOOP
    flag := ORD(o[3]);
    ClearScreen;
    TextB(30, 2, "Footnote Options");
    MenuText(5, 4, "1 - Spacing within notes"); IntStr(ORD(o[0]), s); TextN(50, 4, s);
    MenuText(5, 5, "2 - Spacing between notes"); IntStr(ORD(o[1]), s); TextN(50, 5, s);
    MenuText(5, 6, "3 - Lines to keep together"); IntStr(ORD(o[2]), s); TextN(50, 6, s);
    MenuText(5, 7, "4 - Start footnote numbers each page");
    IF ODD(flag) THEN TextN(50, 7, "Y") ELSE TextN(50, 7, "N") END;
    MenuText(5, 8, "5 - Footnote numbering mode"); IntStr((flag DIV 2) MOD 4, s); TextN(50, 8, s);
    MenuText(5, 9, "6 - Endnote numbering mode"); IntStr((flag DIV 8) MOD 4, s); TextN(50, 9, s);
    MenuText(5, 10, "7 - Line separating text and footnotes"); IntStr((flag DIV 32) MOD 4, s); TextN(50, 10, s);
    MenuText(5, 11, "8 - Footnotes at bottom of page");
    IF flag >= 128 THEN TextN(50, 11, "Y") ELSE TextN(50, 11, "N") END;
    MenuText(5, 12, "9 - Characters for notes"); s[0] := 0X;
    FOR i := 1 TO ORD(o[4]) DO IF i <= 5 THEN AppendCh(o[4 + i], s) END END; TextN(50, 12, s);
    TextN(5, 14, "For options 5 & 6:"); TextN(45, 14, "For option 7:");
    TextN(9, 15, "0 - Numbers"); TextN(49, 15, "0 - No line");
    TextN(9, 16, "1 - Characters"); TextN(49, 16, "1 - 2 inch line");
    TextN(9, 17, "2 - Letters"); TextN(49, 17, "2 - Line across entire page");
    TextN(49, 18, "3 - 2 in. line w/continued strings");
    TextN(5, 20, "Selection: 0"); TUI.SetCursor(16, 20); Flush;
    k := GetKey(); Terminal.HideCursor();
    IF (k >= ORD("1")) & (k <= ORD("3")) THEN
      v := ORD(o[k - ORD("1")]);
      IF InputInt("Value: ", v) & (v >= 0) & (v < 100) THEN o[k - ORD("1")] := CHR(v) END
    ELSIF k = ORD("4") THEN
      IF YesNo("Start footnote numbers each page?", ODD(flag)) THEN flag := (flag DIV 2) * 2 + 1
      ELSE flag := (flag DIV 2) * 2 END;
      o[3] := CHR(flag)
    ELSIF (k = ORD("5")) OR (k = ORD("6")) OR (k = ORD("7")) THEN
      v := 0;
      IF InputInt("Value: ", v) & (v >= 0) & (v <= 3) THEN
        IF k = ORD("5") THEN flag := flag - ((flag DIV 2) MOD 4) * 2 + (v MOD 3) * 2
        ELSIF k = ORD("6") THEN flag := flag - ((flag DIV 8) MOD 4) * 8 + (v MOD 3) * 8
        ELSE flag := flag - ((flag DIV 32) MOD 4) * 32 + v * 32
        END;
        o[3] := CHR(flag)
      END
    ELSIF k = ORD("8") THEN
      IF YesNo("Footnotes at bottom of page?", flag >= 128) THEN
        IF flag < 128 THEN flag := flag + 128 END
      ELSIF flag >= 128 THEN flag := flag - 128
      END;
      o[3] := CHR(flag)
    ELSIF k = ORD("9") THEN
      s[0] := 0X;
      IF Input("Characters: ", s) THEN
        IF SLen(s) > 5 THEN s[5] := 0X END;
        o[4] := CHR(SLen(s)); FOR i := 0 TO 4 DO o[5 + i] := 0X END;
        FOR i := 0 TO SLen(s) - 1 DO o[5 + i] := s[i] END
      END
    ELSE EXIT
    END
  END;
  MkItem(kNoteOpt, 0, 0, 0, it); it.s := NewBytes(NoteLen); it.sl := NoteLen;
  FOR i := 0 TO NoteLen - 1 DO it.s[i] := o[i] END;
  InsertItem(it)
END NoteOptions;

PROCEDURE FootnoteCmd;
VAR c: CHAR; n, i: INTEGER; s: Str;
BEGIN
  c := MenuKey("1 Create; 2 Edit; 3 New #; 4 Options; 5 Create Endnote; 6 Edit Endnote: 0");
  IF c = "1" THEN CreateNote(FALSE)
  ELSIF c = "5" THEN CreateNote(TRUE)
  ELSIF (c = "2") OR (c = "6") THEN
    n := NextNoteNum(c = "6");
    IF c = "2" THEN Cpy("Ftn #? ", s) ELSE Cpy("Endn #? ", s) END;
    IF InputInt(s, n) THEN
      i := FindNote(c = "6", n);
      IF i >= 0 THEN EditNote(i) ELSE ErrMsg("Note not found") END
    END
  ELSIF c = "3" THEN
    n := 1;
    IF InputInt("Ftn #? ", n) & (n > 0) THEN InsertCode(kNoteNum, n, 0, 0) END
  ELSIF c = "4" THEN NoteOptions
  END
END FootnoteCmd;

(* ---- Mark Text (Alt-F5) ---- *)

PROCEDURE RemoveRedStrike;
VAR i, j: INTEGER;
BEGIN
  i := 0;
  WHILE i < e.d.n DO
    IF ((e.d.it[i].k = kAttrOn) OR (e.d.it[i].k = kAttrOff)) & (e.d.it[i].a = aRed) THEN
      DelItems(e.d, i, 1); IF e.cur > i THEN DEC(e.cur) END
    ELSIF (e.d.it[i].k = kAttrOn) & (e.d.it[i].a = aStrike) THEN
      j := i + 1;
      WHILE (j < e.d.n) & ~((e.d.it[j].k = kAttrOff) & (e.d.it[j].a = aStrike)) DO INC(j) END;
      IF j < e.d.n THEN INC(j) END;
      DelItems(e.d, i, j - i);
      IF e.cur > i THEN
        IF e.cur >= j THEN e.cur := e.cur - (j - i) ELSE e.cur := i END
      END
    ELSE INC(i)
    END
  END;
  Touch(e)
END RemoveRedStrike;

PROCEDURE MarkOther;
VAR k: INTEGER;
BEGIN
  ClearScreen;
  TextB(25, 2, "Other Mark Text Options");
  MenuText(5, 4, "1 - Define Paragraph/Outline Numbering");
  MenuText(5, 6, "2 - Define Table of Contents, Lists and Index");
  MenuText(5, 8, "3 - Define Table of Authorities");
  MenuText(5, 10, "4 - Remove all Redline markings and all Strikeout text from document");
  MenuText(5, 12, "5 - Edit Table of Authorities full form");
  MenuText(5, 14, "6 - Generate Tables and Index");
  TextN(5, 16, "Selection: 0"); TUI.SetCursor(16, 16); Flush;
  k := GetKey(); Terminal.HideCursor();
  IF k = ORD("4") THEN
    IF YesNo("Delete Redline markings and Strikeout text?", FALSE) THEN RemoveRedStrike END
  ELSIF (k >= ORD("1")) & (k <= ORD("6")) THEN
    ShowMsg("Outlines, tables and indexes are not available in obperfect")
  END
END MarkOther;

PROCEDURE MarkText;
VAR c: CHAR; ba, bb, n: INTEGER; s: Str; it: Item;
BEGIN
  IF BlockRange(e, ba, bb) THEN
    c := MenuKey("Mark: 1 ToC; 2 List; 3 Redline; 4 Strikeout; 5 Index; 6 ToA: 0");
    IF c = "1" THEN
      n := 1;
      IF InputInt("ToC Level: ", n) & (n >= 1) & (n <= 5) THEN
        InsertCodeAt(bb, kMark, 0, n - 1, 0); InsertCodeAt(ba, kMark, 1, n - 1, 0)
      END
    ELSIF c = "2" THEN
      n := 1;
      IF InputInt("List #: ", n) & (n >= 1) & (n <= 5) THEN
        InsertCodeAt(bb, kMark, 0, 32 + n - 1, 0); InsertCodeAt(ba, kMark, 1, 32 + n - 1, 0)
      END
    ELSIF c = "3" THEN InsertCodeAt(bb, kAttrOff, aRed, 0, 0); InsertCodeAt(ba, kAttrOn, aRed, 0, 0)
    ELSIF c = "4" THEN InsertCodeAt(bb, kAttrOff, aStrike, 0, 0); InsertCodeAt(ba, kAttrOn, aStrike, 0, 0)
    ELSIF c = "5" THEN
      s[0] := 0X;
      IF Input("Index heading: ", s) THEN
        MkItem(kDefMark, 0EAH, 0, 0, it);
        it.s := NewBytes(SLen(s) + 4); it.sl := SLen(s) + 3;
        it.s[0] := 0EAX; FOR n := 0 TO SLen(s) - 1 DO it.s[1 + n] := s[n] END;
        it.s[SLen(s) + 1] := 0X; it.s[SLen(s) + 2] := 0EAX;
        InsItem(e.d, ba, it); Touch(e)
      END
    END;
    e.anchor := -1
  ELSE
    c := MenuKey("1 Outline; 2 Para #; 3 Redline; 4 Short Form; 5 Index; 6 Other Options: 0");
    IF c = "3" THEN ToggleAttr(aRed)
    ELSIF c = "6" THEN MarkOther
    ELSIF (c = "1") OR (c = "2") OR (c = "4") OR (c = "5") THEN
      ShowMsg("Outlines, tables and indexes are not available in obperfect")
    END
  END
END MarkText;

(* ---- Text In/Out (Ctrl-F5): DOS text, locked documents, summaries ---- *)

PROCEDURE HasSummary(x: Ed): BOOLEAN;
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO x.d.n - 1 DO
    IF (x.d.it[i].k = kComment) & (x.d.it[i].a = 1) THEN RETURN TRUE END
  END;
  RETURN FALSE
END HasSummary;

PROCEDURE SummaryField(d: Doc; n: INTEGER; VAR s: ARRAY OF CHAR);
VAR t: ARRAY 2048 OF CHAR; i, k, j: INTEGER;
BEGIN
  s[0] := 0X;
  IF d = NIL THEN RETURN END;
  DocText(d, t);
  i := 0; k := 0;
  WHILE (t[i] # 0X) & (k < n) DO IF t[i] = 0AX THEN INC(k) END; INC(i) END;
  j := 0;
  WHILE (t[i] # 0X) & ((t[i] # 0AX) OR (n >= 3)) & (j < LEN(s) - 1) DO
    IF t[i] = 0AX THEN s[j] := " " ELSE s[j] := t[i] END; INC(j); INC(i)
  END;
  s[j] := 0X
END SummaryField;

PROCEDURE CreateSummary(x: Ed);
VAR i, at: INTEGER; d: Doc; date, author, typist, cmt: Str; it: Item;
BEGIN
  at := -1;
  FOR i := 0 TO x.d.n - 1 DO
    IF (at < 0) & (x.d.it[i].k = kComment) & (x.d.it[i].a = 1) THEN at := i END
  END;
  IF at >= 0 THEN
    SummaryField(x.d.it[at].sub, 0, date); SummaryField(x.d.it[at].sub, 1, author);
    SummaryField(x.d.it[at].sub, 2, typist); SummaryField(x.d.it[at].sub, 3, cmt)
  ELSE
    FormatDate("%2/%1/5", date); author[0] := 0X; typist[0] := 0X; cmt[0] := 0X
  END;
  ClearScreen;
  TextB(25, 2, "Document Summary");
  TextN(5, 4, "System Filename"); TextN(30, 4, x.name);
  TextN(5, 6, "Date of Creation"); TextN(30, 6, date);
  Flush;
  IF ~Input("Author: ", author) THEN RETURN END;
  IF ~Input("Typist: ", typist) THEN RETURN END;
  IF ~Input("Comments: ", cmt) THEN RETURN END;
  d := NewDoc();
  AddStr(d, date); AddK(d, kHRt, 0, 0, 0); AddStr(d, author); AddK(d, kHRt, 0, 0, 0);
  AddStr(d, typist); AddK(d, kHRt, 0, 0, 0); AddStr(d, cmt);
  IF at >= 0 THEN x.d.it[at].sub := d
  ELSE
    MkItem(kComment, 1, 0, 0, it); it.sub := d; InsItem(x.d, 0, it);
    IF x.cur > 0 THEN INC(x.cur) END;
    IF x.anchor > 0 THEN INC(x.anchor) END
  END;
  Touch(x)
END CreateSummary;

PROCEDURE ShowSummary;
VAR i, y, n: INTEGER; s: ARRAY 1024 OF CHAR;
BEGIN
  ClearScreen;
  TextB(25, 2, "Document Summary and Comments");
  y := 4;
  FOR i := 0 TO e.d.n - 1 DO
    IF (e.d.it[i].k = kComment) & (y < scrRows - 2) THEN
      IF e.d.it[i].a = 1 THEN
        SummaryField(e.d.it[i].sub, 0, s); TextN(5, y, "Date of Creation:"); TextN(25, y, s); INC(y);
        SummaryField(e.d.it[i].sub, 1, s); TextN(5, y, "Author:"); TextN(25, y, s); INC(y);
        SummaryField(e.d.it[i].sub, 2, s); TextN(5, y, "Typist:"); TextN(25, y, s); INC(y);
        SummaryField(e.d.it[i].sub, 3, s); TextN(5, y, "Comments:"); s[50] := 0X; TextN(25, y, s); INC(y)
      ELSE
        DocText(e.d.it[i].sub, s); s[60] := 0X;
        n := 0; WHILE s[n] # 0X DO IF s[n] = 0AX THEN s[n] := " " END; INC(n) END;
        TextN(5, y, "Comment:"); TextN(15, y, s); INC(y)
      END;
      INC(y)
    END
  END;
  IF y = 4 THEN TextN(5, 4, "This document has no summary or comments.") END;
  PressKey("Press any key to continue")
END ShowSummary;

PROCEDURE GenericText(x: Ed);
VAR i: INTEGER; it: Item;
BEGIN
  ObReset;
  FOR i := 0 TO x.d.n - 1 DO
    it := x.d.it[i];
    IF it.k = kChar THEN PutUtf8(it.ch)
    ELSIF it.k = kHRt THEN Put(0DH); Put(0AH)
    ELSIF it.k = kTab THEN Put(09H)
    ELSIF it.k = kHPg THEN Put(0CH)
    ELSIF (it.k = kSingle) & (it.a = fHardSp) THEN Put(ORD(" "))
    ELSIF (it.k = kSingle) & (it.a = fHardHy) THEN Put(ORD("-"))
    END
  END
END GenericText;

PROCEDURE TextInOut;
VAR k, i, n, fmt: INTEGER; name, full: Path; pw, pw2: Str; d: Doc; buf: Bytes; c: CHAR; it: Item;
BEGIN
  ClearScreen;
  TextB(15, 1, "Document Conversion, Summary and Comments");
  TextB(5, 3, "DOS Text File Format");
  MenuText(9, 4, "1 - Save current document as a DOS text file");
  MenuText(9, 5, "2 - Retrieve a DOS text file (CR/LF to [HRt])");
  MenuText(9, 6, "3 - Retrieve a DOS text file (CR/LF in H-Zone to [SRt])");
  TextB(5, 8, "Locked Document Format");
  MenuText(9, 9, "4 - Save current document as a locked document");
  MenuText(9, 10, "5 - Retrieve a locked document");
  TextB(5, 12, "Other Word Processor Formats");
  MenuText(9, 13, "6 - Save current document in a generic word processor format");
  MenuText(9, 14, "7 - Save current document in WordPerfect 4.1 format");
  MenuText(9, 15, "8 - Save current document in WordPerfect 5.1 format");
  TextB(5, 17, "Document Summary and Comments");
  TextN(9, 18, "A - Create/Edit Summary"); PutCp(9, 18, "A", cHi, cBg);
  TextN(9, 19, "B - Create Comment"); PutCp(9, 19, "B", cHi, cBg);
  TextN(9, 20, "C - Edit Comment"); PutCp(9, 20, "C", cHi, cBg);
  TextN(9, 21, "D - Display Summary and Comments"); PutCp(9, 21, "D", cHi, cBg);
  TextN(5, 23, "Selection: 0"); TUI.SetCursor(16, 23); Flush;
  k := GetKey(); Terminal.HideCursor();
  c := KeyChar(k);
  IF c = "1" THEN
    name[0] := 0X;
    IF Input("Document to be Saved (DOS Text): ", name) & (name[0] # 0X) THEN
      IF SaveTo(e, name, fmtText, TRUE, "") THEN END
    END
  ELSIF (c = "2") OR (c = "3") THEN
    name[0] := 0X;
    IF Input("Document to be Retrieved: ", name) & (name[0] # 0X) THEN
      FullPath(name, full);
      IF LoadFile(full, buf, n) THEN
        d := NewDoc(); ImportText(buf^, n, d, c = "3");
        IF (e.d.n = 0) & ~e.modified THEN Cpy(full, e.name); e.srcFmt := fmtText END;
        i := InsDoc(e.d, e.cur, d); e.dirty := TRUE
      ELSE ErrMsg("File not found")
      END
    END
  ELSIF c = "4" THEN
    pw[0] := 0X; pw2[0] := 0X;
    IF Input("Enter Key: ", pw) & (pw[0] # 0X) & Input("Re-Enter Key: ", pw2) THEN
      IF ~StrEqCI(pw, pw2) THEN ErrMsg("Keys do not match")
      ELSE
        Cpy(e.name, name);
        IF Input("Document to be Saved: ", name) & (name[0] # 0X) THEN
          FullPath(name, full);
          IF SaveTo(e, full, fmtWP42, TRUE, pw) THEN Cpy(full, e.name); e.modified := FALSE END
        END
      END
    END
  ELSIF c = "5" THEN RetrieveCmd
  ELSIF c = "6" THEN
    name[0] := 0X;
    IF Input("Document to be Saved (Generic): ", name) & (name[0] # 0X) THEN
      FullPath(name, full);
      GenericText(e);
      IF ~WriteOb(full) THEN ErrMsg("Can't write file") END
    END
  ELSIF (c = "7") OR (c = "8") THEN
    name[0] := 0X;
    IF c = "7" THEN fmt := fmtWP42; write41 := TRUE ELSE fmt := fmtWP5 END;
    IF c = "7" THEN Cpy("Document to be Saved (WP 4.1): ", pw) ELSE Cpy("Document to be Saved (WP 5.1): ", pw) END;
    IF Input(pw, name) & (name[0] # 0X) THEN
      IF SaveTo(e, name, fmt, TRUE, "") THEN END
    END;
    write41 := FALSE
  ELSIF c = "A" THEN CreateSummary(e)
  ELSIF c = "B" THEN
    MkItem(kComment, 0, 0, 0, it); it.sub := NewDoc(); InsertItem(it);
    EditSub(e.d.it[e.cur - 1].sub, "Comment: Press EXIT when done", 10, 74)
  ELSIF c = "C" THEN
    i := FindCodeBack(kComment, 0, TRUE);
    IF i >= 0 THEN EditSub(e.d.it[i].sub, "Comment: Press EXIT when done", 10, 74)
    ELSE ErrMsg("Comment not found")
    END
  ELSIF c = "D" THEN ShowSummary
  END
END TextInOut;

(* ====================================================================
   Printing.  The formatter's pages are rendered into lines of text
   (code page 437 plus an attribute byte per character); the printer
   drivers write those as UTF-8 text, Preview shows them on screen.
   ==================================================================== *)

CONST
  PW = 256;         (* print line width *)
  pBold = 1; pUnd = 2; pSup = 4; pSub = 8; pRed = 16; pStrk = 32;

TYPE
  PLine = RECORD s, a: ARRAY PW OF CHAR; n: INTEGER END;
  PLines = POINTER TO ARRAY OF PLine;

VAR
  pl: PLines; plN, plCap: INTEGER;     (* rendered lines *)
  pageLines: INTEGER;                  (* lines per page of the last render *)
  pgStart: ARRAY 2000 OF INTEGER;      (* first rendered line of each page *)
  pgCount: INTEGER;
  pageNumStr: Str;                     (* what ^B prints *)

PROCEDURE PlReset;
BEGIN
  IF pl = NIL THEN plCap := 256; NEW(pl, plCap) END;
  plN := 0; pgCount := 0
END PlReset;

PROCEDURE PlNew(): INTEGER;
VAR np: PLines; i: INTEGER;
BEGIN
  IF plN >= plCap THEN
    NEW(np, plCap * 2);
    FOR i := 0 TO plN - 1 DO np[i] := pl[i] END;
    pl := np; plCap := plCap * 2
  END;
  pl[plN].n := 0; pl[plN].s[0] := 0X;
  INC(plN);
  RETURN plN - 1
END PlNew;

(* overstrike: a letter and an accent make a code page 437 letter *)
PROCEDURE Compose(base, acc: CHAR): CHAR;
BEGIN
  IF (acc = "~") & (base = "n") THEN RETURN 0A4X
  ELSIF (acc = "~") & (base = "N") THEN RETURN 0A5X
  ELSIF (acc = "'") OR (acc = 0BFX) THEN
    IF base = "e" THEN RETURN 82X ELSIF base = "a" THEN RETURN 0A0X
    ELSIF base = "i" THEN RETURN 0A1X ELSIF base = "o" THEN RETURN 0A2X
    ELSIF base = "u" THEN RETURN 0A3X ELSIF base = "E" THEN RETURN 90X END
  ELSIF acc = "`" THEN
    IF base = "e" THEN RETURN 8AX ELSIF base = "a" THEN RETURN 85X
    ELSIF base = "i" THEN RETURN 8DX ELSIF base = "o" THEN RETURN 95X
    ELSIF base = "u" THEN RETURN 97X END
  ELSIF acc = "^" THEN
    IF base = "e" THEN RETURN 88X ELSIF base = "a" THEN RETURN 83X
    ELSIF base = "i" THEN RETURN 8CX ELSIF base = "o" THEN RETURN 93X
    ELSIF base = "u" THEN RETURN 96X END
  ELSIF acc = 22X THEN
    IF base = "e" THEN RETURN 89X ELSIF base = "a" THEN RETURN 84X
    ELSIF base = "i" THEN RETURN 8BX ELSIF base = "o" THEN RETURN 94X
    ELSIF base = "u" THEN RETURN 81X ELSIF base = "A" THEN RETURN 8EX
    ELSIF base = "O" THEN RETURN 99X ELSIF base = "U" THEN RETURN 9AX END
  ELSIF acc = "," THEN
    IF base = "c" THEN RETURN 87X ELSIF base = "C" THEN RETURN 80X END
  ELSIF acc = "/" THEN
    IF base = "o" THEN RETURN 0EDX END
  END;
  RETURN acc
END Compose;

PROCEDURE PlPut(r, col: INTEGER; c: CHAR; a: INTEGER; over: BOOLEAN);
BEGIN
  IF (col < 0) OR (col >= PW - 1) THEN RETURN END;
  WHILE pl[r].n <= col DO
    pl[r].s[pl[r].n] := " "; pl[r].a[pl[r].n] := 0X; INC(pl[r].n)
  END;
  IF over & (pl[r].s[col] # " ") THEN c := Compose(pl[r].s[col], c) END;
  pl[r].s[col] := c; pl[r].a[col] := CHR(a)
END PlPut;

PROCEDURE PlStr(r, col: INTEGER; s: ARRAY OF CHAR; a: INTEGER);
VAR i: INTEGER;
BEGIN
  i := 0; WHILE s[i] # 0X DO PlPut(r, col + i, s[i], a, FALSE); INC(i) END
END PlStr;

PROCEDURE PAttr(a: INTEGER): INTEGER;
VAR p: INTEGER;
BEGIN
  p := 0;
  IF ODD(ASR(a, aBold)) OR ODD(ASR(a, aShadow)) OR ODD(ASR(a, aOutline)) THEN p := p + pBold END;
  IF ODD(ASR(a, aUnd)) THEN p := p + pUnd END;
  IF ODD(ASR(a, bSuper)) THEN p := p + pSup END;
  IF ODD(ASR(a, bSub)) THEN p := p + pSub END;
  IF ODD(ASR(a, aRed)) THEN p := p + pRed END;
  IF ODD(ASR(a, aStrike)) THEN p := p + pStrk END;
  RETURN p
END PAttr;

(* render formatted line L of x into print line r *)
PROCEDURE PrintLine(x: Ed; L, r, offset: INTEGER; justify: BOOLEAN; rm: INTEGER);
VAR i, j, c, a, last, gaps, extra, add, shift, firstChar, lastTab: INTEGER; it: Item; g: Str;
    over: BOOLEAN;
BEGIN
  (* find the expandable spaces for right justification *)
  gaps := 0; last := -1; firstChar := -1; lastTab := x.lines[L].start - 1;
  FOR i := x.lines[L].start TO x.lines[L].end - 1 DO
    it := x.d.it[i];
    IF (it.k = kTab) OR (it.k = kAlign) OR (it.k = kCenter) OR (it.k = kIndent) THEN lastTab := i END;
    IF (it.k = kChar) & (it.ch # " ") OR (ItemWidth(it) > 0) & (it.k # kChar) THEN last := i END
  END;
  extra := 0;
  IF justify & (last >= 0) THEN
    FOR i := lastTab + 1 TO last DO
      IF (x.d.it[i].k = kChar) & (x.d.it[i].ch = " ") & (firstChar >= 0) THEN INC(gaps) END;
      IF (x.d.it[i].k = kChar) & (x.d.it[i].ch # " ") & (firstChar < 0) THEN firstChar := i END
    END;
    extra := rm - (x.icol[last] + ItemWidth(x.d.it[last]) - 1);
    IF (extra <= 0) OR (gaps = 0) OR (extra > 3 * (rm - x.lines[L].lm) DIV 4) THEN extra := 0 END
  END;
  shift := 0; j := 0; over := FALSE;
  FOR i := x.lines[L].start TO x.lines[L].end - 1 DO
    it := x.d.it[i];
    a := PAttr(x.iattr[i]);
    c := x.icol[i] + shift + offset;
    IF it.k = kChar THEN
      PlPut(r, c, it.ch, a, over); over := FALSE;
      IF (extra > 0) & (it.ch = " ") & (i > lastTab) & (i < last) & (firstChar >= 0) & (i > firstChar) THEN
        add := extra DIV gaps;
        IF j < extra MOD gaps THEN INC(add) END;
        shift := shift + add; INC(j)
      END
    ELSIF (it.k = kSingle) & (it.a = fOvrstk) THEN over := TRUE
    ELSIF it.k = kCtl THEN
      IF it.ch = 02X THEN PlStr(r, c, pageNumStr, a)
      ELSE GenText(it, g); PlStr(r, c, g, a)
      END
    ELSIF it.k = kNote THEN GenText(it, g); PlStr(r, c, g, pSup)
    ELSIF (it.k = kDate) OR ((it.k = kSingle) & (ItemWidth(it) > 0)) THEN
      IF (it.k = kSingle) & ((it.a = fDoSub) OR (it.a = fDoTot) OR (it.a = fDoGrand) OR
         (it.a = fCalcCol) OR (it.a = fSubEnt) OR (it.a = fTotEnt) OR (it.a = fNeg)) THEN
        (* math operators do not print *)
      ELSIF (it.k = kSingle) & (it.a = fNoteNum) THEN
        IntStr(noteCtx, g); PlStr(r, c, g, pSup)
      ELSE GenText(it, g); PlStr(r, c, g, a)
      END
    ELSIF (it.k = kSingle) & (it.a = fSoftHy) & (i = x.lines[L].end - 2) THEN
      PlPut(r, c, "-", a, FALSE)
    END
  END
END PrintLine;

(* lay out a sub-document (header, footer, note) and render it *)
PROCEDURE PrintSub(d: Doc; lm, rm, offset: INTEGER): INTEGER;
VAR x: Ed; L, r, n: INTEGER;
BEGIN
  x := SubEd(d, "", lm, rm);
  Ensure(x);
  n := 0;
  FOR L := 0 TO x.nlines - 1 DO
    IF (L < x.nlines - 1) OR (x.lines[L].end > x.lines[L].start) THEN
      r := PlNew(); PrintLine(x, L, r, offset, FALSE, rm); INC(n)
    END
  END;
  RETURN n
END PrintSub;

PROCEDURE PageNumText(num, roman: INTEGER; VAR s: ARRAY OF CHAR);
BEGIN
  IF roman = 1 THEN Roman(num, s) ELSE IntStr(num, s) END
END PageNumText;

PROCEDURE PageNumLine(VAR st: Fmt; pos, num, offset: INTEGER);
VAR r, col: INTEGER;
BEGIN
  r := PlNew();
  CASE pos OF
    1, 5: col := st.pnL
  | 2, 6: col := st.pnC - SLen(pageNumStr) DIV 2
  | 3, 7: col := st.pnR - SLen(pageNumStr) + 1
  | 4, 8: IF ODD(num) THEN col := st.pnR - SLen(pageNumStr) + 1 ELSE col := st.pnL END
  ELSE col := st.pnC
  END;
  PlStr(r, col + offset, pageNumStr, 0)
END PageNumLine;

PROCEDURE Blank(n: INTEGER);
VAR r: INTEGER;
BEGIN
  WHILE n > 0 DO r := PlNew(); DEC(n) END
END Blank;

(* render page pg of x *)
PROCEDURE RenderPage(x: Ed; pg, offset: INTEGER);
VAR st, st2: Fmt; start, L, i, t, h, used, body, half, pos, sup, num, nh, k, lnNo, r: INTEGER;
    notes: ARRAY 64 OF INTEGER; nn: INTEGER; s: Str; it: Item; lineCol: INTEGER;
BEGIN
  start := plN;
  pgStart[pgCount] := start; INC(pgCount);
  st := x.snaps[x.pages[pg].snap];
  L := x.pages[pg].first;
  IF L + 1 < x.nlines THEN st2 := x.snaps[x.lines[L + 1].snap] ELSE st2 := x.endFmt END;
  num := x.pages[pg].num; sup := x.pages[pg].suppress;
  PageNumText(num, x.pages[pg].roman, pageNumStr);
  pos := st2.pnPos;
  IF ODD(sup) OR ODD(sup DIV 2) THEN pos := 0 END;
  IF ODD(sup DIV 4) THEN pos := 6 END;
  half := st.topMar;
  Blank(half DIV 2);
  (* headers *)
  FOR t := 0 TO 1 DO
    IF ODD(ASR(x.pages[pg].hdrMask, t)) THEN
      h := PrintSub(st2.hdr[t], st2.hdrLm[t], st2.hdrRm[t], offset); Blank(1)
    END
  END;
  IF (pos >= 1) & (pos <= 4) THEN PageNumLine(st2, pos, num, offset); Blank(1) END;
  body := plN;
  IF x.pages[pg].center = 1 THEN
    used := 0;
    FOR L := x.pages[pg].first TO x.pages[pg].last DO used := used + x.lines[L].height END;
    Blank((st.textHalf - x.pages[pg].hdrLines - x.pages[pg].ftrLines - used) DIV 4)
  END;
  nn := 0; lnNo := 0;
  FOR L := x.pages[pg].first TO x.pages[pg].last DO
    IF (L < x.nlines - 1) OR (x.lines[L].end > x.lines[L].start) OR (L = x.pages[pg].first) THEN
      st := x.snaps[x.lines[L].snap];
      r := PlNew();
      PrintLine(x, L, r, offset, st.just & (x.lines[L].brk = brSoft), st.rm);
      IF st.lineNum >= 128 THEN
        IF (x.lines[L].end > x.lines[L].start + 1) OR ~ODD(st.lineNum DIV 64) THEN
          INC(lnNo);
          k := st.lineNum MOD 32; IF k = 0 THEN k := 1 END;
          IF lnNo MOD k = 0 THEN
            IntStr(lnNo, s); lineCol := st.lnPos - SLen(s);
            IF lineCol < 0 THEN lineCol := 0 END;
            FOR i := 0 TO SLen(s) - 1 DO pl[r].s[i] := " " END;
            PlStr(r, lineCol, s, 0)
          END
        END
      END;
      Blank(x.lines[L].height DIV 2 - 1);
      FOR i := x.lines[L].start TO x.lines[L].end - 1 DO
        IF (x.d.it[i].k = kNote) & ~ODD(x.d.it[i].a DIV 2) & (nn < 64) THEN notes[nn] := i; INC(nn) END
      END
    END
  END;
  (* footnotes at the bottom of the text *)
  IF nn > 0 THEN
    Blank(1);
    k := (ORD(st.noteOpt[3]) DIV 32) MOD 4;
    r := PlNew();
    IF k = 2 THEN FOR i := st.lm TO st.rm DO PlPut(r, i + offset, "_", 0, FALSE) END
    ELSIF k # 0 THEN FOR i := st.lm TO st.lm + 19 DO PlPut(r, i + offset, "_", 0, FALSE) END
    END;
    FOR i := 0 TO nn - 1 DO
      it := x.d.it[notes[i]];
      noteCtx := it.b;
      nh := PrintSub(it.sub, st.lm, st.rm, offset);
      IF i < nn - 1 THEN Blank(1) END
    END
  END;
  (* footers and bottom page numbers sit at the bottom of the text area *)
  used := plN - start;
  t := st.topMar DIV 2 + st.textHalf DIV 2 - x.pages[pg].ftrLines DIV 2;
  IF (pos >= 5) THEN t := t - 2 END;
  IF used < t THEN Blank(t - used) END;
  FOR t := 2 TO 3 DO
    IF ODD(ASR(x.pages[pg].hdrMask, t)) THEN
      Blank(1); h := PrintSub(st2.hdr[t], st2.hdrLm[t], st2.hdrRm[t], offset)
    END
  END;
  IF pos >= 5 THEN Blank(1); PageNumLine(st2, pos, num, offset) END;
  (* fill the form *)
  pageLines := st.formLen;
  WHILE plN - start < st.formLen DO i := PlNew() END
END RenderPage;

(* the document with its endnotes appended (for printing) *)
PROCEDURE WithEndnotes(x: Ed): Ed;
VAR y: Ed; i, j: INTEGER; any: BOOLEAN; s: Str; it: Item;
BEGIN
  Ensure(x);
  any := FALSE;
  FOR i := 0 TO x.d.n - 1 DO IF (x.d.it[i].k = kNote) & ODD(x.d.it[i].a DIV 2) THEN any := TRUE END END;
  IF ~any THEN RETURN x END;
  y := NewEd(0); y.fmt0 := x.fmt0; y.d := CopyDoc(x.d);
  AddK(y.d, kHRt, 0, 0, 0);
  FOR i := 0 TO x.d.n - 1 DO
    it := x.d.it[i];
    IF (it.k = kNote) & ODD(it.a DIV 2) & (it.sub # NIL) THEN
      AddK(y.d, kHRt, 0, 0, 0);
      IntStr(it.b, s);
      FOR j := 0 TO it.sub.n - 1 DO
        IF (it.sub.it[j].k = kSingle) & (it.sub.it[j].a = fNoteNum) THEN
          AddStr(y.d, s); AddCh(y.d, ".")
        ELSE AddItem(y.d, it.sub.it[j])
        END
      END;
      AddK(y.d, kHRt, 0, 0, 0)
    END
  END;
  RETURN y
END WithEndnotes;

(* render pages [from, to] (1-based physical pages; 0 = all) *)
PROCEDURE RenderDoc(x: Ed; from, to: INTEGER);
VAR y: Ed; pg: INTEGER;
BEGIN
  y := WithEndnotes(x);
  Ensure(y);
  PlReset;
  pageLines := 66;
  FOR pg := 0 TO y.npages - 1 DO
    IF ((from = 0) OR (pg + 1 >= from)) & ((to = 0) OR (pg + 1 <= to)) THEN
      RenderPage(y, pg, cfg.binding)
    END
  END
END RenderDoc;

PROCEDURE SupDigit(c: CHAR): INTEGER;
BEGIN
  CASE c OF
    "0": RETURN 2070H | "1": RETURN 0B9H | "2": RETURN 0B2H | "3": RETURN 0B3H
  | "4": RETURN 2074H | "5": RETURN 2075H | "6": RETURN 2076H | "7": RETURN 2077H
  | "8": RETURN 2078H | "9": RETURN 2079H | "+": RETURN 207AH | "-": RETURN 207BH
  ELSE RETURN 0
  END
END SupDigit;

PROCEDURE SubDigit(c: CHAR): INTEGER;
BEGIN
  IF IsDigit(c) THEN RETURN 2080H + ORD(c) - ORD("0") END;
  RETURN 0
END SubDigit;

(* rendered lines -> output buffer; plain = no attributes at all *)
PROCEDURE EmitText(plain: BOOLEAN);
VAR r, i, n, u, k: INTEGER; b: ARRAY 4 OF CHAR; c: CHAR;
BEGIN
  ObReset;
  FOR r := 0 TO plN - 1 DO
    n := pl[r].n;
    WHILE (n > 0) & (pl[r].s[n - 1] = " ") DO DEC(n) END;
    FOR i := 0 TO n - 1 DO
      c := pl[r].s[i];
      u := 0;
      IF ~plain & ODD(ORD(pl[r].a[i]) DIV pSup) THEN u := SupDigit(c) END;
      IF ~plain & ODD(ORD(pl[r].a[i]) DIV pSub) THEN u := SubDigit(c) END;
      IF u = 0 THEN u := CpToUni(c) END;
      k := Utf8(u, b);
      FOR u := 0 TO k - 1 DO Put(ORD(b[u])) END
    END;
    Put(0AH)
  END
END EmitText;

(* send the rendered pages to the selected printer *)
PROCEDURE SendToPrinter(copies: INTEGER): BOOLEAN;
VAR port, tmp, cmd: Path; c, i, keep: INTEGER; ok: BOOLEAN;
BEGIN
  Cpy(cfg.prnPort[cfg.printer], port);
  IF port[0] = 0X THEN Cpy("LPT1", port) END;
  EmitText(cfg.printer = 6);
  keep := obLen;
  FOR c := 2 TO copies DO FOR i := 0 TO keep - 1 DO Put(ORD(ob[i])) END END;
  INC(printJobs);
  IF (Find("LPT", port, 0) = 0) OR (Find("COM", port, 0) = 0) OR StrEq(port, "PRN") THEN
    JoinPath(cfgDir, "print.tmp", tmp);
    Cpy("mkdir -p ", cmd); AppendCh(22X, cmd); Append(cfgDir, cmd); AppendCh(22X, cmd);
    i := OS.Exec(cmd);
    IF ~WriteOb(tmp) THEN RETURN FALSE END;
    Cpy("lpr ", cmd); AppendCh(22X, cmd); Append(tmp, cmd); AppendCh(22X, cmd);
    Append(" >/dev/null 2>&1", cmd);
    ok := OS.Exec(cmd) = 0;
    RETURN ok
  ELSE
    FullPath(port, tmp);
    RETURN WriteOb(tmp)
  END
END SendToPrinter;

PROCEDURE PrintRange(x: Ed; from, to: INTEGER);
BEGIN
  ClearRow(StatusRow()); TextN(1, StatusRow(), "* Please Wait *"); Flush;
  RenderDoc(x, from, to);
  IF ~SendToPrinter(cfg.copies) THEN ErrMsg("Printer not accepting characters")
  ELSE ShowMsg("Document printed")
  END
END PrintRange;

PROCEDURE PrintFile(name: ARRAY OF CHAR);
VAR x: Ed; fmt: INTEGER; s: Str; a, b, i: INTEGER;
BEGIN
  x := NewEd(0);
  IF ~ReadFileInto(name, x.d, fmt) THEN RETURN END;
  Cpy("(All)", s); a := 0; b := 0;
  IF Input("Page(s): ", s) THEN
    i := Find("-", s, 0);
    IF StrEq(s, "(All)") OR (s[0] = 0X) THEN a := 0; b := 0
    ELSIF i > 0 THEN
      Sub(s, i + 1, 10, msg); s[i] := 0X;
      IF ~StrInt(s, a) THEN a := 0 END;
      IF ~StrInt(msg, b) THEN b := 0 END;
      msg[0] := 0X
    ELSIF StrInt(s, a) THEN b := a
    END;
    PrintRange(x, a, b)
  END
END PrintFile;

(* ---- Preview: the pages on screen ---- *)

PROCEDURE Preview(x: Ed);
VAR top, r, i, k, fg, bg, a, pg: INTEGER; s: Str; c: CHAR;
BEGIN
  ClearRow(StatusRow()); TextN(1, StatusRow(), "* Please Wait *"); Flush;
  RenderDoc(x, 0, 0);
  top := 0;
  LOOP
    ClearScreen;
    FOR r := 0 TO scrRows - 2 DO
      IF top + r < plN THEN
        FOR i := 0 TO pl[top + r].n - 1 DO
          IF i < scrCols THEN
            a := ORD(pl[top + r].a[i]);
            fg := cFg; bg := cBg;
            IF ODD(a DIV pBold) THEN fg := cHi END;
            IF ODD(a DIV pSup) OR ODD(a DIV pSub) THEN fg := TUI.Yellow END;
            IF ODD(a DIV pRed) THEN fg := TUI.BrightRed END;
            IF ODD(a DIV pStrk) THEN fg := TUI.BrightMagenta END;
            IF ODD(a DIV pUnd) THEN fg := fg + TUI.AttrUnderline END;
            c := pl[top + r].s[i];
            PutCp(i + 1, r + 1, c, fg, bg)
          END
        END;
        FOR pg := 1 TO pgCount - 1 DO
          IF pgStart[pg] = top + r + 1 THEN
            FOR i := 1 TO scrCols DO PutUni(i, r + 1, 2500H, TUI.Cyan, cBg) END
          END
        END
      END
    END;
    pg := 0;
    WHILE (pg + 1 < pgCount) & (pgStart[pg + 1] <= top) DO INC(pg) END;
    Cpy("Preview: Doc 3  Pg ", s); AppendInt(pg + 1, s); Append(" of ", s); AppendInt(pgCount, s);
    Append("   (PgUp/PgDn, arrows; Exit (F7) when done)", s);
    ClearRow(scrRows); TextN(1, scrRows, s); Flush;
    k := GetKey();
    IF IsNav(k, nDown, 0) THEN IF top < plN - 1 THEN INC(top) END
    ELSIF IsNav(k, nUp, 0) THEN IF top > 0 THEN DEC(top) END
    ELSIF IsNav(k, nPgDn, 0) THEN
      IF pg + 1 < pgCount THEN top := pgStart[pg + 1] END
    ELSIF IsNav(k, nPgUp, 0) THEN
      IF (top > pgStart[pg]) OR (pg = 0) THEN top := pgStart[pg] ELSE top := pgStart[pg - 1] END
    ELSIF (k = ORD("+")) OR IsNav(k, nDown, 4) THEN top := top + scrRows - 1; IF top >= plN THEN top := plN - 1 END
    ELSIF (k = ORD("-")) OR IsNav(k, nUp, 4) THEN top := top - (scrRows - 1); IF top < 0 THEN top := 0 END
    ELSIF IsNav(k, nHome, 0) THEN
      k := GetKey(); IF IsNav(k, nHome, 0) THEN k := GetKey() END;
      IF IsNav(k, nUp, 0) THEN top := 0 ELSIF IsNav(k, nDown, 0) THEN top := pgStart[pgCount - 1] END
    ELSE EXIT
    END
  END
END Preview;

(* ---- Printer Control ---- *)

PROCEDURE PrintOptions(VAR prn, copies, binding: INTEGER);
VAR k, n: INTEGER; s: Str;
BEGIN
  LOOP
    ClearScreen;
    TextB(20, 2, "Change Print Options Temporarily");
    MenuText(5, 4, "1 - Printer Number"); IntStr(prn, s); TextN(45, 4, s);
    MenuText(5, 5, "2 - Number of Copies"); IntStr(copies, s); TextN(45, 5, s);
    MenuText(5, 6, "3 - Binding Width (1/10 in.)"); IntStr(binding, s); TextN(45, 6, s);
    TextN(5, 8, "Selection: 0"); TUI.SetCursor(16, 8); Flush;
    k := GetKey(); Terminal.HideCursor();
    IF k = ORD("1") THEN n := prn; IF InputInt("Printer Number: ", n) & (n >= 1) & (n <= 6) THEN prn := n END
    ELSIF k = ORD("2") THEN n := copies; IF InputInt("Number of Copies: ", n) & (n >= 1) & (n < 100) THEN copies := n END
    ELSIF k = ORD("3") THEN n := binding; IF InputInt("Binding Width: ", n) & (n >= 0) & (n < 100) THEN binding := n END
    ELSE EXIT
    END
  END
END PrintOptions;

PROCEDURE SelectPrinters;
VAR k, p, i: INTEGER; s: Str; port: Path;
BEGIN
  LOOP
    ClearScreen;
    TextB(25, 1, "Printer Selection");
    FOR i := 1 TO 6 DO
      Cpy("Printer ", s); AppendInt(i, s); Append(": ", s); Append(cfg.prnName[i], s);
      IF cfg.prnName[i][0] = 0X THEN Append("(none)", s) END;
      PadTo(s, 45); Append(cfg.prnPort[i], s);
      MenuText(5, 2 + i, s)
    END;
    TextN(5, 10, "Printer ports: LPT1-3 and COM1-4 go to the system print spooler (lpr);");
    TextN(5, 11, "anything else is the name of a file to print to.");
    TextN(5, 13, "Printer number to change (0 = done): "); TUI.SetCursor(42, 13); Flush;
    k := GetKey(); Terminal.HideCursor();
    IF (k >= ORD("1")) & (k <= ORD("6")) THEN
      p := k - ORD("0");
      Cpy(cfg.prnName[p], s);
      IF Input("Printer name: ", s) THEN
        Cpy(s, cfg.prnName[p]);
        ClearScreen;
        TextB(30, 2, "Printer Port");
        MenuText(5, 4, "0 - LPT 1   1 - LPT 2   2 - LPT 3");
        MenuText(5, 5, "4 - COM 1   5 - COM 2   6 - COM 3   7 - COM 4");
        MenuText(5, 6, "8 - Device or File Pathname");
        TextN(5, 8, "Selection: "); TUI.SetCursor(16, 8); Flush;
        k := GetKey(); Terminal.HideCursor();
        CASE k - ORD("0") OF
          0: Cpy("LPT1", cfg.prnPort[p]) | 1: Cpy("LPT2", cfg.prnPort[p]) | 2: Cpy("LPT3", cfg.prnPort[p])
        | 4: Cpy("COM1", cfg.prnPort[p]) | 5: Cpy("COM2", cfg.prnPort[p])
        | 6: Cpy("COM3", cfg.prnPort[p]) | 7: Cpy("COM4", cfg.prnPort[p])
        | 8: Cpy(cfg.prnPort[p], port);
             IF Input("Device or File Pathname: ", port) & (port[0] # 0X) THEN Cpy(port, cfg.prnPort[p]) END
        ELSE
        END
      END
    ELSE EXIT
    END
  END;
  SaveSettings
END SelectPrinters;

PROCEDURE PrinterControl;
VAR k, i: INTEGER; s: Str; name: Path; c: CHAR;
BEGIN
  LOOP
    ClearScreen;
    TextB(30, 1, "Printer Control");
    MenuText(5, 3, "1 - Select Print Options"); TextN(45, 3, "C - Cancel Print Job(s)");
    MenuText(5, 4, "2 - Display Printers and Fonts"); TextN(45, 4, "D - Display All Print Jobs");
    MenuText(5, 5, "3 - Select Printers"); TextN(45, 5, "G - 'Go' (Resume Printing)");
    TextN(45, 6, "P - Print a Document");
    TextN(45, 7, "R - Rush a Print Job");
    TextN(45, 8, "S - Stop Printing");
    TextN(5, 8, "Selection: 0");
    TextB(5, 10, "Current Job");
    TextN(5, 11, "Job Number: n/a"); TextN(45, 11, "Page Number: n/a");
    TextN(5, 12, "Job Status: n/a"); TextN(45, 12, "Current Copy: n/a");
    TextN(5, 13, "Message:    The print queue is empty");
    TextB(5, 15, "Job List");
    TextN(5, 16, "Job  Document               Destination          Forms and Print Options");
    Cpy("Additional jobs not shown: 0      Jobs printed this session: ", s); AppendInt(printJobs, s);
    TextN(5, 18, s);
    Cpy("Selected printer: ", s); AppendInt(cfg.printer, s); Append(" ", s); Append(cfg.prnName[cfg.printer], s);
    Append(" on ", s); Append(cfg.prnPort[cfg.printer], s);
    TextN(5, 20, s);
    TUI.SetCursor(16, 8); Flush;
    k := GetKey(); Terminal.HideCursor();
    c := KeyChar(k);
    IF c = "1" THEN PrintOptions(cfg.printer, cfg.copies, cfg.binding); SaveSettings
    ELSIF c = "2" THEN
      ClearScreen; TextB(25, 2, "Printers and Fonts");
      FOR i := 1 TO 6 DO
        Cpy("Printer ", s); AppendInt(i, s); Append(": ", s); Append(cfg.prnName[i], s);
        IF cfg.prnName[i][0] # 0X THEN Append("   Pitch 10, Font 1 (all text output)", s) END;
        TextN(5, 3 + i, s)
      END;
      PressKey("Press any key to continue")
    ELSIF c = "3" THEN SelectPrinters
    ELSIF c = "P" THEN
      name[0] := 0X;
      IF Input("Document name: ", name) & (name[0] # 0X) THEN FullPath(name, name); PrintFile(name) END
    ELSIF (c = "C") OR (c = "G") OR (c = "R") OR (c = "S") OR (c = "D") THEN
      ShowMsg("The print queue is empty")
    ELSE EXIT
    END
  END
END PrinterControl;

(* Type-thru: lines typed are printed one at a time *)
PROCEDURE TypeThru;
VAR c: CHAR; s: ARRAY 256 OF CHAR; r: INTEGER;
BEGIN
  c := MenuKey("Type-thru printing: 1 by Line; 2 by Character: 0");
  IF (c # "1") & (c # "2") THEN RETURN END;
  PlReset;
  LOOP
    s[0] := 0X;
    IF ~Input("Type-thru (Enter prints the line; Exit when done): ", s) THEN EXIT END;
    r := PlNew(); PlStr(r, 10, s, 0);
    IF ~SendToPrinter(1) THEN ErrMsg("Printer not accepting characters"); EXIT END;
    PlReset
  END
END TypeThru;

PROCEDURE PrintCmd;
VAR c: CHAR; pg, prn, copies, binding: INTEGER; ba, bb: INTEGER; x: Ed;
BEGIN
  Ensure(e);
  IF BlockRange(e, ba, bb) THEN
    IF YesNo("Print Block?", FALSE) THEN
      x := NewEd(0); x.fmt0 := e.fmt0; x.d := CopyRange(e.d, ba, bb);
      PrintRange(x, 0, 0)
    END;
    RETURN
  END;
  c := MenuKey("1 Full Text; 2 Page; 3 Options; 4 Printer Control; 5 Type-thru; 6 Preview: 0");
  IF c = "1" THEN PrintRange(e, 0, 0)
  ELSIF c = "2" THEN
    pg := PageOf(e, e.cur) + 1; PrintRange(e, pg, pg)
  ELSIF c = "3" THEN
    prn := cfg.printer; copies := cfg.copies; binding := cfg.binding;
    PrintOptions(cfg.printer, cfg.copies, cfg.binding);
    Redraw;
    c := MenuKey("1 Full Text; 2 Page: 0");
    IF c = "1" THEN PrintRange(e, 0, 0)
    ELSIF c = "2" THEN pg := PageOf(e, e.cur) + 1; PrintRange(e, pg, pg)
    END;
    cfg.printer := prn; cfg.copies := copies; cfg.binding := binding
  ELSIF c = "4" THEN PrinterControl
  ELSIF c = "5" THEN TypeThru
  ELSIF c = "6" THEN Preview(e)
  END
END PrintCmd;

(* ====================================================================
   Search and Replace.  A search string is a little document: it can
   hold codes ([HRt], [B] ...) and the ^X wildcard (Ctrl-V Ctrl-X).
   Lower-case letters match either case; upper-case only upper case.
   ==================================================================== *)

PROCEDURE PatText(p: Doc; VAR s: ARRAY OF CHAR);
VAR i: INTEGER; t: Str;
BEGIN
  s[0] := 0X;
  FOR i := 0 TO p.n - 1 DO
    IF p.it[i].k = kChar THEN AppendCh(p.it[i].ch, s)
    ELSIF p.it[i].k = kCtl THEN AppendCh("^", s); AppendCh(CHR(ORD(p.it[i].ch) + 64), s)
    ELSE CodeName(p.it[i], t); AppendCh("[", s); Append(t, s); AppendCh("]", s)
    END
  END
END PatText;

(* edit a search/replace string; returns FALSE if cancelled *)
PROCEDURE PatInput(prompt: ARRAY OF CHAR; p: Doc; dirPrompt: BOOLEAN): BOOLEAN;
VAR k, y, x0, a: INTEGER; s: ARRAY 512 OF CHAR; lit, boldOn, undOn, first: BOOLEAN; pr: Str;
BEGIN
  lit := FALSE; boldOn := FALSE; undOn := FALSE; first := TRUE;
  y := StatusRow();
  LOOP
    IF dirPrompt THEN
      IF srchBack THEN Cpy("<- Srch: ", pr) ELSE Cpy("-> Srch: ", pr) END
    ELSE Cpy(prompt, pr)
    END;
    ClearRow(y); TextN(1, y, pr);
    x0 := SLen(pr) + 1;
    PatText(p, s);
    IF SLen(s) > scrCols - x0 - 1 THEN Sub(s, SLen(s) - (scrCols - x0 - 1), 300, s) END;
    Text(x0, y, s, cHi, cBg);
    TUI.SetCursor(x0 + SLen(s), y); Flush;
    k := GetKey();
    IF first & (p.n > 0) & (((k >= 32) & (k < 127)) OR ((k > KExt) & (k < KExt + 256)) OR
       (k = KEnter) OR (k = KTab)) THEN
      p.n := 0         (* typing replaces the previous string *)
    END;
    IF ~(IsNav(k, nUp, 0) OR IsNav(k, nDown, 0)) THEN first := FALSE END;
    IF (k = KF + 2) OR (k = KF + 102) OR (k = KEsc) OR (k = KF + 202) THEN Terminal.HideCursor(); RETURN TRUE
    ELSIF k = KF + 1 THEN Terminal.HideCursor(); RETURN FALSE
    ELSIF dirPrompt & (IsNav(k, nUp, 0) OR IsNav(k, nDown, 0)) THEN srchBack := IsNav(k, nUp, 0)
    ELSIF k = KBS THEN IF p.n > 0 THEN DEC(p.n) END
    ELSIF lit & (k > 0) & (k < 32) THEN
      AddCh(p, CHR(k)); IF k = 18H THEN p.it[p.n - 1].c := 1 END; lit := FALSE
    ELSIF k = 16H THEN lit := TRUE
    ELSIF (k >= 32) & (k < 127) THEN AddCh(p, CHR(k))
    ELSIF (k > KExt) & (k < KExt + 256) THEN AddCh(p, CHR(k - KExt))
    ELSIF k = KEnter THEN AddK(p, kHRt, 0, 0, 0)
    ELSIF k = KTab THEN AddK(p, kTab, 0, 0, 0)
    ELSIF k = KCtrlEnter THEN AddK(p, kHPg, 0, 0, 0)
    ELSIF k = KF + 6 THEN
      IF boldOn THEN AddK(p, kAttrOff, aBold, 0, 0) ELSE AddK(p, kAttrOn, aBold, 0, 0) END;
      boldOn := ~boldOn
    ELSIF k = KF + 8 THEN
      IF undOn THEN AddK(p, kAttrOff, aUnd, 0, 0) ELSE AddK(p, kAttrOn, aUnd, 0, 0) END;
      undOn := ~undOn
    ELSIF k = KF + 106 THEN AddK(p, kCenter, 0, 0, 0)
    ELSIF k = KF + 206 THEN AddK(p, kAlign, 0AH, 0, 0)
    ELSIF k = KF + 4 THEN AddK(p, kIndent, 0, 0, 0)
    ELSIF k = KF + 104 THEN AddK(p, kLRIndent, 0, 0, 0)
    ELSIF k = KNav + 100 + nTab THEN AddK(p, kMarRel, 0, 0, 0)
    ELSIF k = KF + 108 THEN
      a := ORD(MenuKey("1 Tabs; 2 Margins; 3 Spacing: 0"));
      IF a = ORD("1") THEN AddK(p, kTabSet, 0, 0, 0)
      ELSIF a = ORD("2") THEN AddK(p, kMargin, 0, 0, 0)
      ELSIF a = ORD("3") THEN AddK(p, kSpacing, 0, 0, 0)
      END
    ELSIF k = KF + 407 THEN AddK(p, kNote, 0, 0, 0)
    END
  END
END PatInput;

PROCEDURE ItemMatches(VAR pi, di: Item): BOOLEAN;
BEGIN
  IF (pi.k = kCtl) & (pi.c = 1) THEN RETURN di.k = kChar END;    (* ^X *)
  IF pi.k # di.k THEN RETURN FALSE END;
  CASE pi.k OF
    kChar:
      IF IsUpper(pi.ch) THEN RETURN pi.ch = di.ch ELSE RETURN pi.ch = LoCh(di.ch) END
  | kCtl: RETURN pi.ch = di.ch
  | kAttrOn, kAttrOff: RETURN pi.a = di.a
  | kSingle: RETURN pi.a = di.a
  | kAlign: RETURN (pi.a = 0AH) = (di.a = 0AH)
  ELSE RETURN TRUE
  END
END ItemMatches;

PROCEDURE MatchAt(p: Doc; i: INTEGER): BOOLEAN;
VAR j: INTEGER;
BEGIN
  IF i + p.n > e.d.n THEN RETURN FALSE END;
  FOR j := 0 TO p.n - 1 DO
    IF ~ItemMatches(p.it[j], e.d.it[i + j]) THEN RETURN FALSE END
  END;
  RETURN TRUE
END MatchAt;

(* next match of p from position i (forward) within [lo, hi) *)
PROCEDURE FindFwd(p: Doc; i, hi: INTEGER): INTEGER;
BEGIN
  WHILE i + p.n <= hi DO
    IF MatchAt(p, i) THEN RETURN i END;
    INC(i)
  END;
  RETURN -1
END FindFwd;

PROCEDURE FindBack(p: Doc; i, lo: INTEGER): INTEGER;
BEGIN
  WHILE i >= lo DO
    IF MatchAt(p, i) THEN RETURN i END;
    DEC(i)
  END;
  RETURN -1
END FindBack;

PROCEDURE NotFound;
BEGIN
  Cpy("* Not Found *", msg);
  IF cfg.beepSearch THEN Out.Char(07X) END;
  MacroStop
END NotFound;

PROCEDURE SearchCmd(back: BOOLEAN);
VAR i: INTEGER;
BEGIN
  IF srch = NIL THEN srch := NewDoc() END;
  srchBack := back;
  IF ~PatInput("", srch, TRUE) THEN RETURN END;
  IF srch.n = 0 THEN RETURN END;
  IF srchBack THEN
    i := FindBack(srch, e.cur - 1, 0);
    IF i >= 0 THEN prevPos := e.cur; e.cur := i; Moved ELSE NotFound END
  ELSE
    i := FindFwd(srch, e.cur, e.d.n);
    IF i >= 0 THEN prevPos := e.cur; e.cur := i + srch.n; Moved ELSE NotFound END
  END
END SearchCmd;

PROCEDURE ReplaceCmd;
VAR confirm, inBlock, doIt: BOOLEAN; lo, hi, i, n, cnt: INTEGER;
BEGIN
  confirm := YesNo("w/Confirm?", FALSE);
  IF yesNoCancelled THEN RETURN END;
  IF srch = NIL THEN srch := NewDoc() END;
  srchBack := FALSE;
  IF ~PatInput("", srch, TRUE) OR (srch.n = 0) THEN RETURN END;
  IF repl = NIL THEN repl := NewDoc() END;
  repl.n := 0;
  IF ~PatInput("Replace with: ", repl, FALSE) THEN RETURN END;
  inBlock := BlockRange(e, lo, hi);
  e.anchor := -1;
  IF ~inBlock THEN
    IF srchBack THEN lo := 0; hi := e.cur ELSE lo := e.cur; hi := e.d.n END
  END;
  cnt := 0;
  prevPos := e.cur;
  IF srchBack THEN i := FindBack(srch, hi - srch.n, lo) ELSE i := FindFwd(srch, lo, hi) END;
  WHILE i >= 0 DO
    doIt := TRUE;
    IF confirm THEN
      hlA := i; hlB := i + srch.n; e.cur := i + srch.n; e.dirty := TRUE;
      Redraw;
      doIt := YesNo("Confirm?", FALSE);
      hlA := -1;
      IF yesNoCancelled THEN i := -1; doIt := FALSE END
    END;
    IF i >= 0 THEN
      IF doIt THEN
        DelItems(e.d, i, srch.n);
        n := InsDoc(e.d, i, repl);
        hi := hi - srch.n + n;
        e.cur := i + n; Touch(e); INC(cnt)
      ELSE
        n := srch.n; e.cur := i + srch.n
      END;
      IF srchBack THEN i := FindBack(srch, i - srch.n, lo)
      ELSE i := FindFwd(srch, i + n, hi)
      END
    END
  END;
  IF cnt = 0 THEN NotFound END;
  Moved
END ReplaceCmd;

(* ====================================================================
   Move (Ctrl-F4), rectangles and columns
   ==================================================================== *)

PROCEDURE IsSentEnd(i: INTEGER): BOOLEAN;
VAR c: CHAR;
BEGIN
  IF (i < 0) OR (i >= e.d.n) OR (e.d.it[i].k # kChar) THEN RETURN FALSE END;
  c := e.d.it[i].ch;
  RETURN ((c = ".") OR (c = "?") OR (c = "!")) &
         ((i + 1 >= e.d.n) OR (e.d.it[i + 1].k # kChar) OR (e.d.it[i + 1].ch = " "))
END IsSentEnd;

PROCEDURE SentenceRange(VAR a, b: INTEGER);
BEGIN
  a := e.cur;
  WHILE (a > 0) & ~IsSentEnd(a - 1) & (e.d.it[a - 1].k # kHRt) & (e.d.it[a - 1].k # kHPg) DO DEC(a) END;
  WHILE (a < e.d.n) & (e.d.it[a].k = kChar) & (e.d.it[a].ch = " ") DO INC(a) END;
  b := e.cur;
  WHILE (b < e.d.n) & ~IsSentEnd(b) & (e.d.it[b].k # kHRt) & (e.d.it[b].k # kHPg) DO INC(b) END;
  IF (b < e.d.n) & IsSentEnd(b) THEN INC(b) END;
  WHILE (b < e.d.n) & (e.d.it[b].k = kChar) & (e.d.it[b].ch = " ") DO INC(b) END
END SentenceRange;

PROCEDURE ParagraphRange(VAR a, b: INTEGER);
BEGIN
  a := e.cur;
  WHILE (a > 0) & (e.d.it[a - 1].k # kHRt) & (e.d.it[a - 1].k # kHPg) DO DEC(a) END;
  b := e.cur;
  WHILE (b < e.d.n) & (e.d.it[b].k # kHRt) & (e.d.it[b].k # kHPg) DO INC(b) END;
  IF b < e.d.n THEN INC(b) END;
  WHILE (b < e.d.n) & (e.d.it[b].k = kHRt) DO INC(b) END
END ParagraphRange;

PROCEDURE PageRange(VAR a, b: INTEGER);
VAR pg, L: INTEGER;
BEGIN
  Ensure(e);
  pg := PageOf(e, e.cur);
  a := e.lines[e.pages[pg].first].start;
  L := e.pages[pg].last; IF L < 0 THEN L := e.nlines - 1 END;
  b := e.lines[L].end
END PageRange;

PROCEDURE CutCopyDelete(a, b: INTEGER; blockMenu: BOOLEAN);
VAR c: CHAR; sa, sc: INTEGER;
BEGIN
  sa := e.anchor; sc := e.cur;
  hlA := a; hlB := b; e.dirty := TRUE;
  Redraw;
  c := MenuKey("1 Cut; 2 Copy; 3 Delete: 0");
  hlA := -1; e.cur := sc;
  IF c = "1" THEN
    clip := CopyRange(e.d, a, b);
    DelItems(e.d, a, b - a);
    IF e.cur > a THEN IF e.cur >= b THEN e.cur := e.cur - (b - a) ELSE e.cur := a END END;
    Touch(e)
  ELSIF c = "2" THEN clip := CopyRange(e.d, a, b)
  ELSIF c = "3" THEN DeleteRange(a, b, TRUE)
  ELSE e.anchor := sa
  END
END CutCopyDelete;

(* the cells of the block as a rectangle: lines la..lb, columns c1..c2 *)
PROCEDURE RectBounds(VAR la, lb, c1, c2: INTEGER): BOOLEAN;
VAR t: INTEGER;
BEGIN
  IF e.anchor < 0 THEN RETURN FALSE END;
  Ensure(e);
  la := LineOf(e, e.anchor); lb := LineOf(e, e.cur);
  c1 := e.icol[e.anchor]; c2 := e.icol[e.cur];
  IF la > lb THEN t := la; la := lb; lb := t END;
  IF c1 > c2 THEN t := c1; c1 := c2; c2 := t END;
  RETURN TRUE
END RectBounds;

(* items of line L covering columns c1..c2 *)
PROCEDURE RectSeg(L, c1, c2: INTEGER; VAR s, t: INTEGER);
VAR last: INTEGER;
BEGIN
  last := e.lines[L].end;
  IF (last > e.lines[L].start) & ((e.d.it[last - 1].k = kHRt) OR (e.d.it[last - 1].k = kHPg)) THEN DEC(last) END;
  s := e.lines[L].start;
  WHILE (s < last) & (e.icol[s] < c1) DO INC(s) END;
  t := s;
  WHILE (t < last) & (e.icol[t] <= c2) DO INC(t) END
END RectSeg;

(* tab column: from the tab before c1 to before the tab after c2 *)
PROCEDURE ColSeg(L, c1, c2: INTEGER; VAR s, t: INTEGER);
VAR last, i, k: INTEGER;
BEGIN
  last := e.lines[L].end;
  IF (last > e.lines[L].start) & ((e.d.it[last - 1].k = kHRt) OR (e.d.it[last - 1].k = kHPg)) THEN DEC(last) END;
  s := e.lines[L].start;
  FOR i := e.lines[L].start TO last - 1 DO
    k := e.d.it[i].k;
    IF ((k = kTab) OR (k = kAlign) OR (k = kIndent)) & (e.icol[i] <= c1) THEN s := i END
  END;
  t := s + 1;
  WHILE (t < last) & ~(((e.d.it[t].k = kTab) OR (e.d.it[t].k = kAlign)) & (e.icol[t] > c1)) DO INC(t) END;
  IF t > last THEN t := last END
END ColSeg;

PROCEDURE RectCutCopy(column: BOOLEAN);
VAR la, lb, c1, c2, L, s, t, i: INTEGER; c: CHAR; buf: Doc;
BEGIN
  IF ~RectBounds(la, lb, c1, c2) THEN RETURN END;
  c := MenuKey("1 Cut; 2 Copy; 3 Delete: 0");
  IF (c # "1") & (c # "2") & (c # "3") THEN RETURN END;
  buf := NewDoc();
  FOR L := la TO lb DO
    IF column THEN ColSeg(L, c1, c2, s, t) ELSE RectSeg(L, c1, c2, s, t) END;
    FOR i := s TO t - 1 DO AddItem(buf, e.d.it[i]) END;
    AddK(buf, kHPg, 1, 0, 0)            (* row separator *)
  END;
  IF c # "3" THEN
    IF column THEN colClip := CopyDoc(buf) ELSE rectClip := CopyDoc(buf); rectW := c2 - c1 + 1 END
  END;
  IF c # "2" THEN
    FOR L := lb TO la BY -1 DO
      IF column THEN ColSeg(L, c1, c2, s, t) ELSE RectSeg(L, c1, c2, s, t) END;
      DelItems(e.d, s, t - s)
    END;
    e.cur := e.lines[la].start;
    Touch(e)
  END;
  e.anchor := -1
END RectCutCopy;

(* put a rectangle or column back, one row per line from the cursor down *)
PROCEDURE RectRetrieve(r: Doc; pad: BOOLEAN);
VAR L, c0, i, j, at, last, row, n: INTEGER; it: Item;
BEGIN
  IF r = NIL THEN RETURN END;
  Ensure(e);
  L := LineOf(e, e.cur); c0 := e.icol[e.cur];
  i := 0; row := 0;
  WHILE i < r.n DO
    Ensure(e);
    IF L >= e.nlines THEN
      e.cur := e.d.n; InsertCode(kHRt, 0, 0, 0); Ensure(e); L := e.nlines - 1
    END;
    last := e.lines[L].end;
    IF (last > e.lines[L].start) & ((e.d.it[last - 1].k = kHRt) OR (e.d.it[last - 1].k = kHPg)) THEN DEC(last) END;
    at := e.lines[L].start;
    WHILE (at < last) & (e.icol[at] < c0) DO INC(at) END;
    IF pad & (at = last) THEN
      n := c0 - e.icol[last];
      FOR j := 1 TO n DO MkItem(kChar, 0, 0, 0, it); it.ch := " "; InsItem(e.d, at, it); INC(at) END
    END;
    WHILE (i < r.n) & ~((r.it[i].k = kHPg) & (r.it[i].a = 1)) DO
      CopyItemInto(r.it[i], it); InsItem(e.d, at, it); INC(at); INC(i)
    END;
    INC(i); INC(L); INC(row);
    Touch(e); Reformat(e)
  END
END RectRetrieve;

PROCEDURE AppendBlock;
VAR name, full: Path; ba, bb, n, fmt: INTEGER; x: Ed; d: Doc;
BEGIN
  IF ~BlockRange(e, ba, bb) THEN RETURN END;
  name[0] := 0X;
  IF ~Input("Append to: ", name) OR (name[0] = 0X) THEN RETURN END;
  FullPath(name, full);
  x := NewEd(0); fmt := fmtWP42;
  IF Exists(full) THEN
    IF ~ReadFileInto(full, x.d, fmt) THEN RETURN END
  END;
  d := CopyRange(e.d, ba, bb);
  n := InsDoc(x.d, x.d.n, d);
  IF fmt = fmtText THEN fmt := fmtWP42 END;
  IF SaveTo(x, full, fmt, FALSE, "") THEN END;
  e.anchor := -1
END AppendBlock;

PROCEDURE MoveCmd;
VAR c: CHAR; a, b, n: INTEGER;
BEGIN
  IF BlockRange(e, a, b) THEN
    c := MenuKey("1 Cut Block; 2 Copy Block; 3 Append; 4 Cut/Copy Column; 5 Cut/Copy Rectangle: 0");
    IF c = "1" THEN
      clip := CopyRange(e.d, a, b); DelItems(e.d, a, b - a); e.cur := a; e.anchor := -1; Touch(e)
    ELSIF c = "2" THEN clip := CopyRange(e.d, a, b); e.anchor := -1
    ELSIF c = "3" THEN AppendBlock
    ELSIF c = "4" THEN RectCutCopy(TRUE)
    ELSIF c = "5" THEN RectCutCopy(FALSE)
    END
  ELSE
    c := MenuKey("Move: 1 Sentence; 2 Paragraph; 3 Page; Retrieve: 4 Column; 5 Text; 6 Rectangle: 0");
    IF c = "1" THEN SentenceRange(a, b); CutCopyDelete(a, b, FALSE)
    ELSIF c = "2" THEN ParagraphRange(a, b); CutCopyDelete(a, b, FALSE)
    ELSIF c = "3" THEN PageRange(a, b); CutCopyDelete(a, b, FALSE)
    ELSIF c = "4" THEN RectRetrieve(colClip, FALSE)
    ELSIF c = "5" THEN
      IF clip # NIL THEN n := InsDoc(e.d, e.cur, clip); e.cur := e.cur + n; Touch(e) END
    ELSIF c = "6" THEN RectRetrieve(rectClip, TRUE)
    END
  END
END MoveCmd;

(* Shift-F3 with a block: case conversion *)
PROCEDURE CaseConvert;
VAR c: CHAR; a, b, i: INTEGER; start: BOOLEAN; ch: CHAR;
BEGIN
  IF ~BlockRange(e, a, b) THEN RETURN END;
  c := MenuKey("Block: 1 Uppercase; 2 Lowercase: 0");
  IF c = "1" THEN
    FOR i := a TO b - 1 DO IF e.d.it[i].k = kChar THEN e.d.it[i].ch := UpCh(e.d.it[i].ch) END END
  ELSIF c = "2" THEN
    (* keep the first letter of each sentence and the word "I" *)
    start := (a = 0) OR IsSentEnd(a - 1) OR (a > 1) & IsSentEnd(a - 2) OR
             (e.d.it[a - 1].k = kHRt);
    FOR i := a TO b - 1 DO
      IF e.d.it[i].k = kChar THEN
        ch := e.d.it[i].ch;
        IF IsLetter(ch) THEN
          IF ~start & ~((ch = "I") & ~IsWordItem(i - 1) & ~(IsWordItem(i + 1) & IsLetter(e.d.it[i + 1].ch))) THEN
            e.d.it[i].ch := LoCh(ch)
          END;
          start := FALSE
        ELSIF IsSentEnd(i) THEN start := TRUE
        END
      ELSIF e.d.it[i].k = kHRt THEN start := TRUE
      END
    END
  END;
  IF (c = "1") OR (c = "2") THEN Touch(e); lastBlockA := e.anchor; lastBlockB := e.cur; e.anchor := -1 END
END CaseConvert;

(* ====================================================================
   Speller (Ctrl-F2).  The main dictionary (LEX.WP) is a word list, by
   default /usr/share/dict/words; words added go to the supplementary
   dictionary ({WP}LEX.SUP, ~/.config/obperfect/wplex.sup).
   ==================================================================== *)

CONST
  MaxSugg = 24;
  MaxSup = 2000;

VAR
  lex: Bytes; lexLen: INTEGER;
  lexOff: IntArr; lexN: INTEGER;
  lexLoaded: BOOLEAN;
  supW: ARRAY MaxSup OF ARRAY 40 OF CHAR;
  supN: INTEGER;
  skipW: ARRAY MaxSup OF ARRAY 40 OF CHAR;
  skipN: INTEGER;
  fixFrom, fixTo: ARRAY 100 OF ARRAY 40 OF CHAR;
  fixN: INTEGER;
  sugg: ARRAY MaxSugg OF ARRAY 40 OF CHAR;
  suggN: INTEGER;
  spWords: INTEGER;
  spIgnoreNum, spNoDouble: BOOLEAN;

(* compare the word at arena offset o with s *)
PROCEDURE LexCmp(o: INTEGER; s: ARRAY OF CHAR): INTEGER;
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (lex[o + i] # 0AX) & (s[i] # 0X) & (lex[o + i] = s[i]) DO INC(i) END;
  IF lex[o + i] = 0AX THEN
    IF s[i] = 0X THEN RETURN 0 ELSE RETURN -1 END
  ELSIF s[i] = 0X THEN RETURN 1
  ELSIF lex[o + i] < s[i] THEN RETURN -1
  ELSE RETURN 1
  END
END LexCmp;

PROCEDURE LexWord(o: INTEGER; VAR s: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (lex[o + i] # 0AX) & (i < LEN(s) - 1) DO s[i] := lex[o + i]; INC(i) END;
  s[i] := 0X
END LexWord;

PROCEDURE OffLess(a, b: INTEGER): BOOLEAN;
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (lex[a + i] = lex[b + i]) & (lex[a + i] # 0AX) DO INC(i) END;
  RETURN (lex[a + i] # lex[b + i]) & ((lex[a + i] = 0AX) OR (lex[b + i] # 0AX) & (lex[a + i] < lex[b + i]))
END OffLess;

PROCEDURE SortLex(lo, hi: INTEGER);
VAR i, j, p, t: INTEGER;
BEGIN
  WHILE lo < hi DO
    p := lexOff[(lo + hi) DIV 2]; i := lo; j := hi;
    REPEAT
      WHILE OffLess(lexOff[i], p) DO INC(i) END;
      WHILE OffLess(p, lexOff[j]) DO DEC(j) END;
      IF i <= j THEN t := lexOff[i]; lexOff[i] := lexOff[j]; lexOff[j] := t; INC(i); DEC(j) END
    UNTIL i > j;
    IF j - lo < hi - i THEN SortLex(lo, j); lo := i ELSE SortLex(i, hi); hi := j END
  END
END SortLex;

PROCEDURE LoadSup;
VAR buf: Bytes; len, i, j: INTEGER;
BEGIN
  supN := 0;
  IF ~LoadFile(cfg.supPath, buf, len) THEN RETURN END;
  i := 0;
  WHILE (i < len) & (supN < MaxSup) DO
    j := 0;
    WHILE (i < len) & (buf[i] # 0AX) & (buf[i] # 0DX) DO
      IF j < 39 THEN supW[supN][j] := LoCh(buf[i]); INC(j) END; INC(i)
    END;
    supW[supN][j] := 0X;
    IF j > 0 THEN INC(supN) END;
    INC(i)
  END
END LoadSup;

PROCEDURE LoadLex(): BOOLEAN;
VAR buf: Bytes; len, i, n, w: INTEGER; c: CHAR;
BEGIN
  IF lexLoaded THEN RETURN TRUE END;
  ClearRow(StatusRow()); TextN(1, StatusRow(), "* Please Wait *"); Flush;
  IF ~LoadFile(cfg.lexPath, buf, len) THEN RETURN FALSE END;
  lex := NewBytes(len + 2); lexLen := 0; n := 0; w := 0;
  FOR i := 0 TO len - 1 DO
    c := buf[i];
    IF c = 0DX THEN
    ELSIF c = 0AX THEN IF w > 0 THEN lex[lexLen] := 0AX; INC(lexLen); INC(n) END; w := 0
    ELSE lex[lexLen] := LoCh(c); INC(lexLen); INC(w)
    END
  END;
  IF w > 0 THEN lex[lexLen] := 0AX; INC(lexLen); INC(n) END;
  NEW(lexOff, n + 1); lexN := 0;
  i := 0;
  WHILE i < lexLen DO
    lexOff[lexN] := i; INC(lexN);
    WHILE lex[i] # 0AX DO INC(i) END;
    INC(i)
  END;
  IF lexN > 1 THEN SortLex(0, lexN - 1) END;
  LoadSup;
  lexLoaded := TRUE;
  RETURN TRUE
END LoadLex;

PROCEDURE InLex(s: ARRAY OF CHAR): BOOLEAN;
VAR lo, hi, mid, c: INTEGER;
BEGIN
  lo := 0; hi := lexN - 1;
  WHILE lo <= hi DO
    mid := (lo + hi) DIV 2;
    c := LexCmp(lexOff[mid], s);
    IF c = 0 THEN RETURN TRUE ELSIF c < 0 THEN lo := mid + 1 ELSE hi := mid - 1 END
  END;
  RETURN FALSE
END InLex;

(* which: 0 supplementary dictionary, 1 skipped words, 2 suggestions *)
PROCEDURE InList(which: INTEGER; s: ARRAY OF CHAR): BOOLEAN;
VAR i: INTEGER;
BEGIN
  IF which = 0 THEN FOR i := 0 TO supN - 1 DO IF StrEq(supW[i], s) THEN RETURN TRUE END END
  ELSIF which = 1 THEN FOR i := 0 TO skipN - 1 DO IF StrEq(skipW[i], s) THEN RETURN TRUE END END
  ELSE FOR i := 0 TO suggN - 1 DO IF StrEq(sugg[i], s) THEN RETURN TRUE END END
  END;
  RETURN FALSE
END InList;

PROCEDURE KnownBase(s: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN (s[0] # 0X) & (InLex(s) OR InList(0, s) OR InList(1, s))
END KnownBase;

(* try the stem of s without its last n letters, plus an ending *)
PROCEDURE Stem(s: ARRAY OF CHAR; n: INTEGER; add: ARRAY OF CHAR): BOOLEAN;
VAR t: ARRAY 64 OF CHAR; m: INTEGER;
BEGIN
  m := SLen(s) - n;
  IF m < 2 THEN RETURN FALSE END;
  Sub(s, 0, m, t); Append(add, t);
  RETURN KnownBase(t)
END Stem;

PROCEDURE EndsWith(s, suf: ARRAY OF CHAR): BOOLEAN;
VAR n, m: INTEGER;
BEGIN
  n := SLen(s); m := SLen(suf);
  RETURN (n > m) & StrEq(suf, s) OR (n > m) & (Find(suf, s, n - m) = n - m)
END EndsWith;

(* short words that never take an ending *)
PROCEDURE NoEndings(s: ARRAY OF CHAR; n: INTEGER): BOOLEAN;
VAR t: ARRAY 16 OF CHAR;
BEGIN
  IF n > 8 THEN RETURN FALSE END;
  Sub(s, 0, n, t);
  RETURN StrEq(t, "the") OR StrEq(t, "a") OR StrEq(t, "an") OR StrEq(t, "of") OR StrEq(t, "to") OR
    StrEq(t, "in") OR StrEq(t, "is") OR StrEq(t, "it") OR StrEq(t, "he") OR StrEq(t, "she") OR
    StrEq(t, "we") OR StrEq(t, "they") OR StrEq(t, "and") OR StrEq(t, "or") OR StrEq(t, "but") OR
    StrEq(t, "if") OR StrEq(t, "at") OR StrEq(t, "by") OR StrEq(t, "for") OR StrEq(t, "with") OR
    StrEq(t, "as") OR StrEq(t, "be") OR StrEq(t, "his") OR StrEq(t, "her") OR StrEq(t, "this") OR
    StrEq(t, "that") OR StrEq(t, "then") OR StrEq(t, "than") OR StrEq(t, "there") OR
    StrEq(t, "their") OR StrEq(t, "not") OR StrEq(t, "no") OR StrEq(t, "so") OR StrEq(t, "from") OR
    StrEq(t, "on") OR StrEq(t, "up") OR StrEq(t, "was") OR StrEq(t, "are") OR StrEq(t, "you") OR
    StrEq(t, "me") OR StrEq(t, "my") OR StrEq(t, "our") OR StrEq(t, "your") OR StrEq(t, "who") OR
    StrEq(t, "what") OR StrEq(t, "which") OR StrEq(t, "when") OR StrEq(t, "where") OR StrEq(t, "th")
END NoEndings;

(* the main dictionary is a list of base forms: accept common inflections *)
PROCEDURE Inflected(s: ARRAY OF CHAR): BOOLEAN;
VAR n: INTEGER; dbl: BOOLEAN;
BEGIN
  n := SLen(s);
  dbl := (n > 4) & (s[n - 4] = s[n - 5]);
  IF EndsWith(s, "ies") & Stem(s, 3, "y") THEN RETURN TRUE END;
  IF EndsWith(s, "es") & ~NoEndings(s, n - 2) & ~NoEndings(s, n - 1) & (Stem(s, 2, "") OR Stem(s, 1, "")) THEN RETURN TRUE END;
  IF EndsWith(s, "s") & ~EndsWith(s, "ss") & ~NoEndings(s, n - 1) & Stem(s, 1, "") THEN RETURN TRUE END;
  IF EndsWith(s, "ied") & Stem(s, 3, "y") THEN RETURN TRUE END;
  IF EndsWith(s, "ed") & (Stem(s, 2, "") OR Stem(s, 1, "") OR (dbl & Stem(s, 3, ""))) THEN RETURN TRUE END;
  IF EndsWith(s, "ing") & (Stem(s, 3, "") OR Stem(s, 3, "e") OR ((n > 5) & (s[n - 4] = s[n - 5]) & Stem(s, 4, ""))) THEN RETURN TRUE END;
  IF EndsWith(s, "ily") & Stem(s, 3, "y") THEN RETURN TRUE END;
  IF EndsWith(s, "ly") & (Stem(s, 2, "") OR Stem(s, 1, "e")) THEN RETURN TRUE END;
  IF EndsWith(s, "ier") & Stem(s, 3, "y") THEN RETURN TRUE END;
  IF EndsWith(s, "iest") & Stem(s, 4, "y") THEN RETURN TRUE END;
  IF EndsWith(s, "er") & (Stem(s, 2, "") OR Stem(s, 1, "") OR (dbl & Stem(s, 3, ""))) THEN RETURN TRUE END;
  IF EndsWith(s, "est") & (Stem(s, 3, "") OR Stem(s, 2, "")) THEN RETURN TRUE END;
  IF EndsWith(s, "ment") & Stem(s, 4, "") THEN RETURN TRUE END;
  IF EndsWith(s, "ness") & Stem(s, 4, "") THEN RETURN TRUE END;
  RETURN FALSE
END Inflected;

PROCEDURE Known(w: ARRAY OF CHAR): BOOLEAN;
VAR s: ARRAY 64 OF CHAR; n: INTEGER;
BEGIN
  Cpy(w, s); Lower(s);
  IF KnownBase(s) THEN RETURN TRUE END;
  n := SLen(s);
  IF (n > 2) & (s[n - 2] = "'") & (s[n - 1] = "s") THEN s[n - 2] := 0X; RETURN Known(s) END;
  IF (n > 1) & (s[n - 1] = "'") THEN s[n - 1] := 0X; RETURN KnownBase(s) END;
  RETURN Inflected(s)
END Known;

PROCEDURE AddSugg(s: ARRAY OF CHAR);
BEGIN
  IF (suggN < MaxSugg) & ~InList(2, s) THEN Cpy(s, sugg[suggN]); INC(suggN) END
END AddSugg;

PROCEDURE TryCand(s: ARRAY OF CHAR);
BEGIN
  IF InLex(s) OR InList(0, s) THEN AddSugg(s) END
END TryCand;

(* edit distance (with transpositions), giving up above lim *)
PROCEDURE Dist(a, b: ARRAY OF CHAR; lim: INTEGER): INTEGER;
VAR d: ARRAY 34, 34 OF INTEGER; i, j, n, m, c, best: INTEGER;
BEGIN
  n := SLen(a); m := SLen(b);
  IF (n > 32) OR (m > 32) OR (ABS(n - m) > lim) THEN RETURN lim + 1 END;
  FOR i := 0 TO n DO d[i][0] := i END;
  FOR j := 0 TO m DO d[0][j] := j END;
  FOR i := 1 TO n DO
    best := 99;
    FOR j := 1 TO m DO
      IF a[i - 1] = b[j - 1] THEN c := 0 ELSE c := 1 END;
      d[i][j] := d[i - 1][j - 1] + c;
      IF d[i - 1][j] + 1 < d[i][j] THEN d[i][j] := d[i - 1][j] + 1 END;
      IF d[i][j - 1] + 1 < d[i][j] THEN d[i][j] := d[i][j - 1] + 1 END;
      IF (i > 1) & (j > 1) & (a[i - 1] = b[j - 2]) & (a[i - 2] = b[j - 1]) & (d[i - 2][j - 2] + 1 < d[i][j]) THEN
        d[i][j] := d[i - 2][j - 2] + 1
      END;
      IF d[i][j] < best THEN best := d[i][j] END
    END;
    IF best > lim THEN RETURN lim + 1 END
  END;
  RETURN d[n][m]
END Dist;

PROCEDURE Suggest(w: ARRAY OF CHAR);
VAR s, t, word: ARRAY 64 OF CHAR; i, j, n, k: INTEGER; c: CHAR;
BEGIN
  suggN := 0;
  Cpy(w, s); Lower(s); n := SLen(s);
  (* one edit away *)
  FOR i := 0 TO n - 2 DO
    Cpy(s, t); c := t[i]; t[i] := t[i + 1]; t[i + 1] := c; TryCand(t)
  END;
  FOR i := 0 TO n - 1 DO
    Cpy(s, t); FOR j := i TO n - 1 DO t[j] := t[j + 1] END; TryCand(t)
  END;
  FOR i := 0 TO n - 1 DO
    FOR k := 0 TO 25 DO
      Cpy(s, t); t[i] := CHR(ORD("a") + k);
      IF t[i] # s[i] THEN TryCand(t) END
    END
  END;
  FOR i := 0 TO n DO
    FOR k := 0 TO 25 DO
      t[0] := 0X; Sub(s, 0, i, t); AppendCh(CHR(ORD("a") + k), t);
      Sub(s, i, 60, word); Append(word, t); TryCand(t)
    END
  END;
  FOR i := 1 TO n - 1 DO           (* run-together words *)
    Sub(s, 0, i, t); Sub(s, i, 60, word);
    IF InLex(t) & InLex(word) & (SLen(t) > 1) & (SLen(word) > 1) THEN
      Append(" ", t); Append(word, t); AddSugg(t)
    END
  END;
  (* two edits away, by scanning *)
  IF suggN < 6 THEN
    FOR i := 0 TO lexN - 1 DO
      IF (suggN < MaxSugg) & (lex[lexOff[i]] = s[0]) THEN
        LexWord(lexOff[i], word);
        IF Dist(s, word, 2) <= 2 THEN AddSugg(word) END
      END
    END
  END
END Suggest;

(* a sound-alike key (Soundex, extended) *)
PROCEDURE SoundKey(w: ARRAY OF CHAR; VAR k: ARRAY OF CHAR);
VAR i, n: INTEGER; c, d, last: CHAR;
BEGIN
  n := 0; last := 0X; i := 0;
  WHILE (w[i] # 0X) & (n < 6) DO
    c := LoCh(w[i]);
    CASE c OF
      "b", "f", "p", "v": d := "1"
    | "c", "g", "j", "k", "q", "s", "x", "z": d := "2"
    | "d", "t": d := "3" | "l": d := "4" | "m", "n": d := "5" | "r": d := "6"
    ELSE d := "0"
    END;
    IF i = 0 THEN k[0] := c; n := 1; last := d
    ELSE
      IF (d # "0") & (d # last) THEN k[n] := d; INC(n) END;
      IF c # "h" THEN last := d END
    END;
    INC(i)
  END;
  k[n] := 0X
END SoundKey;

PROCEDURE Phonetic(w: ARRAY OF CHAR);
VAR key, k2, word: ARRAY 64 OF CHAR; i: INTEGER;
BEGIN
  suggN := 0;
  SoundKey(w, key);
  FOR i := 0 TO lexN - 1 DO
    IF suggN < MaxSugg THEN
      LexWord(lexOff[i], word);
      IF ABS(SLen(word) - SLen(w)) <= 2 THEN
        SoundKey(word, k2);
        IF StrEq(k2, key) THEN AddSugg(word) END
      END
    END
  END
END Phonetic;

PROCEDURE LookUpPattern(pat: ARRAY OF CHAR);
VAR word: ARRAY 64 OF CHAR; i: INTEGER; low: ARRAY 64 OF CHAR;
BEGIN
  suggN := 0;
  Cpy(pat, low); Lower(low);
  FOR i := 0 TO lexN - 1 DO
    IF suggN < MaxSugg THEN
      LexWord(lexOff[i], word);
      IF GlobMatch(low, word, 0, 0) THEN AddSugg(word) END
    END
  END
END LookUpPattern;

PROCEDURE ShowSugg(y0: INTEGER);
VAR i, x, y: INTEGER; s: Str;
BEGIN
  FOR i := 0 TO suggN - 1 DO
    x := 1 + (i MOD 3) * 26; y := y0 + i DIV 3;
    s[0] := CHR(ORD("A") + i); s[1] := 0X; Append(". ", s);
    TextB(x, y, s); TextN(x + 3, y, sugg[i])
  END
END ShowSugg;

PROCEDURE SpellScreen(a, b: INTEGER; head, menu: ARRAY OF CHAR): INTEGER;
VAR k, y0, i: INTEGER;
BEGIN
  bottomReserve := 11;
  hlA := a; hlB := b; e.cur := b; e.dirty := TRUE;
  Redraw;
  hlA := -1;
  y0 := scrRows - 10;
  FOR i := y0 TO scrRows DO ClearRow(i) END;
  HLine(y0, 2550H);
  ShowSugg(y0 + 1);
  TextN(1, scrRows - 1, head);
  MenuText(1, scrRows, menu);
  TUI.SetCursor(SLen(head) + 1, scrRows - 1); Flush;
  k := GetKey(); Terminal.HideCursor();
  bottomReserve := 0;
  RETURN k
END SpellScreen;

(* replace items a..b-1 (a word) with s, keeping its capitalisation *)
PROCEDURE ReplaceWord(a, b: INTEGER; s: ARRAY OF CHAR): INTEGER;
VAR i, n: INTEGER; cap, all: BOOLEAN; it: Item;
BEGIN
  cap := IsUpper(e.d.it[a].ch);
  all := cap & (b - a > 1) & IsUpper(e.d.it[a + 1].ch);
  DelItems(e.d, a, b - a);
  n := SLen(s);
  FOR i := 0 TO n - 1 DO
    MkItem(kChar, 0, 0, 0, it); it.ch := s[i];
    IF all OR (cap & (i = 0)) THEN it.ch := UpCh(it.ch) END;
    InsItem(e.d, a + i, it)
  END;
  Touch(e);
  RETURN n
END ReplaceWord;

PROCEDURE WordChar(i: INTEGER): BOOLEAN;
VAR c: CHAR;
BEGIN
  IF (i < 0) OR (i >= e.d.n) OR (e.d.it[i].k # kChar) THEN RETURN FALSE END;
  c := e.d.it[i].ch;
  RETURN IsLetter(c) OR IsDigit(c) OR
         (c = "'") & (i + 1 < e.d.n) & (e.d.it[i + 1].k = kChar) & IsLetter(e.d.it[i + 1].ch) & (i > 0) & (e.d.it[i - 1].k = kChar) & IsLetter(e.d.it[i - 1].ch)
END WordChar;

PROCEDURE ItemsWord(a, b: INTEGER; VAR s: ARRAY OF CHAR);
VAR i, j: INTEGER;
BEGIN
  j := 0;
  FOR i := a TO b - 1 DO IF (j < LEN(s) - 1) & (e.d.it[i].k = kChar) THEN s[j] := e.d.it[i].ch; INC(j) END END;
  s[j] := 0X
END ItemsWord;

PROCEDURE AddToSup(w: ARRAY OF CHAR);
VAR buf: Bytes; len, i: INTEGER; s: ARRAY 64 OF CHAR; cmd: Path;
BEGIN
  Cpy(w, s); Lower(s);
  IF supN < MaxSup THEN Cpy(s, supW[supN]); INC(supN) END;
  Cpy("mkdir -p ", cmd); AppendCh(22X, cmd); Append(cfgDir, cmd); AppendCh(22X, cmd);
  i := OS.Exec(cmd);
  ObReset;
  IF LoadFile(cfg.supPath, buf, len) THEN FOR i := 0 TO len - 1 DO Put(ORD(buf[i])) END END;
  PutStr(s); Put(0AH);
  IF WriteOb(cfg.supPath) THEN END
END AddToSup;

(* check [a, b); returns FALSE if cancelled *)
PROCEDURE CheckRange(a, b: INTEGER): BOOLEAN;
VAR i, j, k, n, prevA, prevB, gap: INTEGER; w, pw: ARRAY 64 OF CHAR; hasNum, done: BOOLEAN;
    c: CHAR; s: Str; fixed: BOOLEAN;
BEGIN
  i := a; prevA := -1; prevB := -1;
  WHILE i < b DO
    IF ~WordChar(i) OR (e.d.it[i].k # kChar) THEN INC(i)
    ELSE
      j := i; WHILE (j < b) & WordChar(j) DO INC(j) END;
      ItemsWord(i, j, w); INC(spWords);
      hasNum := FALSE; FOR k := 0 TO SLen(w) - 1 DO IF IsDigit(w[k]) THEN hasNum := TRUE END END;
      done := FALSE;
      (* double words *)
      IF ~spNoDouble & (prevA >= 0) THEN
        ItemsWord(prevA, prevB, pw);
        gap := prevB; WHILE (gap < i) & (e.d.it[gap].k = kChar) & (e.d.it[gap].ch = " ") DO INC(gap) END;
        IF (gap = i) & StrEqCI(pw, w) & ~hasNum THEN
          suggN := 0;
          k := SpellScreen(i, j, "Double Word! ", "1 2 Skip; 3 Delete 2nd; 4 Edit; 5 Disable double word checking");
          IF k = KF + 1 THEN RETURN FALSE
          ELSIF k = ORD("3") THEN DelItems(e.d, prevB, j - prevB); Touch(e);
            b := b - (j - prevB); j := prevB
          ELSIF k = ORD("4") THEN
            Cpy(w, s); IF Input("Edit: ", s) THEN n := ReplaceWord(i, j, s); b := b + n - (j - i); j := i + n END
          ELSIF k = ORD("5") THEN spNoDouble := TRUE
          END;
          done := TRUE
        END
      END;
      IF ~done & hasNum THEN
        IF ~spIgnoreNum & ~Known(w) THEN
          suggN := 0;
          k := SpellScreen(i, j, "", "1 2 Skip; 3 Ignore words containing numbers; 4 Edit");
          IF k = KF + 1 THEN RETURN FALSE
          ELSIF k = ORD("3") THEN spIgnoreNum := TRUE
          ELSIF k = ORD("4") THEN
            Cpy(w, s); IF Input("Edit: ", s) THEN n := ReplaceWord(i, j, s); b := b + n - (j - i); j := i + n END
          END
        END;
        done := TRUE
      END;
      IF ~done & ~Known(w) THEN
        (* earlier correction of the same word *)
        fixed := FALSE;
        FOR k := 0 TO fixN - 1 DO
          IF ~fixed & StrEqCI(fixFrom[k], w) THEN
            n := ReplaceWord(i, j, fixTo[k]); b := b + n - (j - i); j := i + n; fixed := TRUE
          END
        END;
        IF ~fixed THEN
          Suggest(w);
          LOOP
            IF suggN > 0 THEN Cpy("Select Word or Menu Option (0=Continue): 0", s)
            ELSE Cpy("Not Found! Select Word or Menu Option (0=Continue): 0", s)
            END;
            k := SpellScreen(i, j, s, "1 Skip Once; 2 Skip; 3 Add Word; 4 Edit; 5 Look Up; 6 Phonetic");
            c := KeyChar(k);
            IF k = KF + 1 THEN RETURN FALSE
            ELSIF (c >= "A") & (c <= "X") & (ORD(c) - ORD("A") < suggN) THEN
              IF fixN < 100 THEN Cpy(w, fixFrom[fixN]); Cpy(sugg[ORD(c) - ORD("A")], fixTo[fixN]); INC(fixN) END;
              n := ReplaceWord(i, j, sugg[ORD(c) - ORD("A")]); b := b + n - (j - i); j := i + n;
              EXIT
            ELSIF c = "2" THEN
              IF skipN < MaxSup THEN Cpy(w, skipW[skipN]); Lower(skipW[skipN]); INC(skipN) END; EXIT
            ELSIF c = "3" THEN AddToSup(w); EXIT
            ELSIF c = "4" THEN
              Cpy(w, s);
              IF Input("Edit (press Enter when done): ", s) THEN
                n := ReplaceWord(i, j, s); b := b + n - (j - i); j := i + n
              END;
              EXIT
            ELSIF c = "5" THEN
              Cpy(w, s);
              IF Input("Word Pattern: ", s) THEN LookUpPattern(s) END
            ELSIF c = "6" THEN Phonetic(w)
            ELSE EXIT
            END
          END
        END
      END;
      prevA := i; prevB := j;
      i := j
    END
  END;
  RETURN TRUE
END CheckRange;

PROCEDURE CountWords(a, b: INTEGER): INTEGER;
VAR i, n: INTEGER;
BEGIN
  n := 0; i := a;
  WHILE i < b DO
    IF WordChar(i) THEN INC(n); WHILE (i < b) & WordChar(i) DO INC(i) END ELSE INC(i) END
  END;
  RETURN n
END CountWords;

PROCEDURE SpellDone;
VAR s: Str;
BEGIN
  Cpy("Word Count: ", s); AppendInt(spWords, s); Append("   Press any key to continue", s);
  Redraw; PressKey(s)
END SpellDone;

PROCEDURE SpellCmd;
VAR c: CHAR; a, b, save: INTEGER; s: Path; ok: BOOLEAN;
BEGIN
  IF ~LoadLex() THEN
    Cpy(cfg.lexPath, s);
    IF Input("Main dictionary not found. Enter name: ", s) THEN Cpy(s, cfg.lexPath);
      IF ~LoadLex() THEN ErrMsg("Dictionary not found"); RETURN END
    ELSE RETURN
    END
  END;
  spWords := 0; spIgnoreNum := FALSE; spNoDouble := FALSE; fixN := 0;
  save := e.cur;
  IF BlockRange(e, a, b) THEN
    e.anchor := -1;
    ok := CheckRange(a, b); e.cur := save; SpellDone; RETURN
  END;
  c := MenuKey("Check: 1 Word; 2 Page; 3 Document; 4 Change Dictionary; 5 Look Up; 6 Count: 0");
  IF c = "1" THEN
    a := e.cur; WHILE WordChar(a - 1) DO DEC(a) END;
    b := e.cur; WHILE WordChar(b) DO INC(b) END;
    IF b = a THEN WHILE (b < e.d.n) & ~WordChar(b) DO INC(b) END; a := b; WHILE WordChar(b) DO INC(b) END END;
    ok := CheckRange(a, b);
    e.cur := b; WHILE (e.cur < e.d.n) & ~WordChar(e.cur) DO INC(e.cur) END
  ELSIF c = "2" THEN PageRange(a, b); ok := CheckRange(a, b); e.cur := save; SpellDone
  ELSIF c = "3" THEN ok := CheckRange(0, e.d.n); e.cur := save; SpellDone
  ELSIF c = "4" THEN
    Cpy(cfg.lexPath, s);
    IF Input("Enter new main dictionary name: ", s) THEN Cpy(s, cfg.lexPath); lexLoaded := FALSE END;
    Cpy(cfg.supPath, s);
    IF Input("Enter new supplementary dictionary name: ", s) THEN Cpy(s, cfg.supPath); lexLoaded := FALSE END
  ELSIF c = "5" THEN
    s[0] := 0X;
    IF Input("Word Pattern: ", s) THEN
      LookUpPattern(s);
      Redraw;
      bottomReserve := 0;
      FOR a := scrRows - 9 TO scrRows DO ClearRow(a) END;
      ShowSugg(scrRows - 9);
      IF suggN = 0 THEN TextN(1, scrRows - 9, "No words match.") END;
      PressKey("Press any key to continue")
    END
  ELSIF c = "6" THEN
    spWords := CountWords(0, e.d.n); SpellDone
  END
END SpellCmd;

(* ====================================================================
   Thesaurus (Alt-F1).  TH.WP is a tab-separated list,
     headword <TAB> synonym,synonym,... <TAB> definition
   looked for at the Set-up path, ~/.config/obperfect/th.wp,
   ~/.config/ostar/thesaurus.txt, then ostar-thesaurus.txt here or next
   to the program (the list that comes with ostar).
   ==================================================================== *)

CONST
  MaxThCol = 3;
  MaxRef = 60;

VAR
  th: Bytes; thLen: INTEGER;
  thOff: IntArr; thN: INTEGER;      (* sorted offsets of entry lines *)
  thLoaded: BOOLEAN;
  colWord: ARRAY MaxThCol OF ARRAY 40 OF CHAR;
  colDef: ARRAY MaxThCol OF ARRAY 120 OF CHAR;
  colRef: ARRAY MaxThCol, MaxRef OF ARRAY 40 OF CHAR;
  colRefN: ARRAY MaxThCol OF INTEGER;
  nCols, curCol: INTEGER;

PROCEDURE ThHeadLess(a, b: INTEGER): BOOLEAN;
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (th[a + i] = th[b + i]) & (th[a + i] # 09X) & (th[a + i] # 0AX) DO INC(i) END;
  IF (th[a + i] = 09X) OR (th[a + i] = 0AX) THEN RETURN ~((th[b + i] = 09X) OR (th[b + i] = 0AX)) END;
  IF (th[b + i] = 09X) OR (th[b + i] = 0AX) THEN RETURN FALSE END;
  RETURN th[a + i] < th[b + i]
END ThHeadLess;

PROCEDURE SortTh(lo, hi: INTEGER);
VAR i, j, p, t: INTEGER;
BEGIN
  WHILE lo < hi DO
    p := thOff[(lo + hi) DIV 2]; i := lo; j := hi;
    REPEAT
      WHILE ThHeadLess(thOff[i], p) DO INC(i) END;
      WHILE ThHeadLess(p, thOff[j]) DO DEC(j) END;
      IF i <= j THEN t := thOff[i]; thOff[i] := thOff[j]; thOff[j] := t; INC(i); DEC(j) END
    UNTIL i > j;
    IF j - lo < hi - i THEN SortTh(lo, j); lo := i ELSE SortTh(i, hi); hi := j END
  END
END SortTh;

PROCEDURE TryThFile(name: ARRAY OF CHAR): BOOLEAN;
VAR buf: Bytes; len, i, n: INTEGER;
BEGIN
  IF (name[0] = 0X) OR ~LoadFile(name, buf, len) THEN RETURN FALSE END;
  th := NewBytes(len + 2); thLen := 0;
  FOR i := 0 TO len - 1 DO
    IF buf[i] # 0DX THEN
      IF (buf[i] >= "A") & (buf[i] <= "Z") & ((thLen = 0) OR (th[thLen - 1] = 0AX)) THEN
        th[thLen] := LoCh(buf[i])
      ELSE th[thLen] := buf[i]
      END;
      INC(thLen)
    END
  END;
  IF (thLen = 0) OR (th[thLen - 1] # 0AX) THEN th[thLen] := 0AX; INC(thLen) END;
  n := 0; FOR i := 0 TO thLen - 1 DO IF th[i] = 0AX THEN INC(n) END END;
  NEW(thOff, n + 1); thN := 0; i := 0;
  WHILE i < thLen DO
    IF (th[i] # "#") & (th[i] # 0AX) THEN thOff[thN] := i; INC(thN) END;
    WHILE th[i] # 0AX DO INC(i) END;
    INC(i)
  END;
  IF thN > 1 THEN SortTh(0, thN - 1) END;
  RETURN thN > 0
END TryThFile;

PROCEDURE LoadTh(): BOOLEAN;
VAR p, home, exe: Path;
BEGIN
  IF thLoaded THEN RETURN TRUE END;
  Args.GetEnv("HOME", home);
  IF TryThFile(cfg.thPath) THEN thLoaded := TRUE
  ELSE
    JoinPath(cfgDir, "th.wp", p);
    IF TryThFile(p) THEN thLoaded := TRUE
    ELSE
      JoinPath(home, ".config/ostar/thesaurus.txt", p);
      IF TryThFile(p) THEN thLoaded := TRUE
      ELSIF TryThFile("ostar-thesaurus.txt") THEN thLoaded := TRUE
      ELSE
        Args.ExeDir(exe); JoinPath(exe, "ostar-thesaurus.txt", p);
        thLoaded := TryThFile(p)
      END
    END
  END;
  RETURN thLoaded
END LoadTh;

(* the entry line for a headword, or -1 *)
PROCEDURE ThFind(w: ARRAY OF CHAR): INTEGER;
VAR lo, hi, mid, i, o: INTEGER; low: ARRAY 64 OF CHAR; c: INTEGER;
BEGIN
  Cpy(w, low); Lower(low);
  lo := 0; hi := thN - 1;
  WHILE lo <= hi DO
    mid := (lo + hi) DIV 2; o := thOff[mid];
    i := 0;
    WHILE (low[i] # 0X) & (th[o + i] = low[i]) DO INC(i) END;
    IF (low[i] = 0X) & ((th[o + i] = 09X) OR (th[o + i] = 0AX)) THEN RETURN o END;
    IF (th[o + i] = 09X) OR (th[o + i] = 0AX) THEN c := -1
    ELSIF (low[i] = 0X) THEN c := 1
    ELSIF th[o + i] < low[i] THEN c := -1 ELSE c := 1
    END;
    IF c < 0 THEN lo := mid + 1 ELSE hi := mid - 1 END
  END;
  RETURN -1
END ThFind;

(* a headword for w, trying its stem when w itself is not one *)
PROCEDURE ThFindStem(VAR w: ARRAY OF CHAR): INTEGER;
VAR o, n: INTEGER; t: ARRAY 64 OF CHAR;
BEGIN
  o := ThFind(w); IF o >= 0 THEN RETURN o END;
  n := SLen(w);
  IF (n > 4) & EndsWith(w, "ies") THEN Sub(w, 0, n - 3, t); Append("y", t); o := ThFind(t) END;
  IF (o < 0) & (n > 3) & EndsWith(w, "s") THEN Sub(w, 0, n - 1, t); o := ThFind(t) END;
  IF (o < 0) & (n > 4) & EndsWith(w, "es") THEN Sub(w, 0, n - 2, t); o := ThFind(t) END;
  IF (o < 0) & (n > 4) & EndsWith(w, "ed") THEN Sub(w, 0, n - 2, t); o := ThFind(t);
    IF o < 0 THEN Sub(w, 0, n - 1, t); o := ThFind(t) END
  END;
  IF (o < 0) & (n > 5) & EndsWith(w, "ing") THEN Sub(w, 0, n - 3, t); o := ThFind(t);
    IF o < 0 THEN Append("e", t); o := ThFind(t) END
  END;
  IF (o < 0) & (n > 4) & EndsWith(w, "ly") THEN Sub(w, 0, n - 2, t); o := ThFind(t) END;
  IF o >= 0 THEN Cpy(t, w) END;
  RETURN o
END ThFindStem;

(* load headword w into column c *)
PROCEDURE ThColumn(c: INTEGER; w: ARRAY OF CHAR): BOOLEAN;
VAR o, i, n, j: INTEGER;
BEGIN
  o := ThFindStem(w);
  IF o < 0 THEN RETURN FALSE END;
  Cpy(w, colWord[c]); Lower(colWord[c]);
  i := o; WHILE (th[i] # 09X) & (th[i] # 0AX) DO INC(i) END;
  n := 0; colDef[c][0] := 0X;
  IF th[i] = 09X THEN
    INC(i);
    WHILE (th[i] # 09X) & (th[i] # 0AX) DO
      WHILE th[i] = " " DO INC(i) END;
      j := 0;
      WHILE (th[i] # ",") & (th[i] # 09X) & (th[i] # 0AX) DO
        IF j < 39 THEN colRef[c][n][j] := th[i]; INC(j) END; INC(i)
      END;
      colRef[c][n][j] := 0X;
      IF (j > 0) & (n < MaxRef) THEN INC(n) END;
      IF th[i] = "," THEN INC(i) END
    END;
    IF th[i] = 09X THEN
      INC(i); j := 0;
      WHILE (th[i] # 0AX) & (j < 119) DO colDef[c][j] := th[i]; INC(j); INC(i) END;
      colDef[c][j] := 0X
    END
  END;
  colRefN[c] := n;
  RETURN TRUE
END ThColumn;

PROCEDURE WordAtCursor(VAR a, b: INTEGER);
BEGIN
  a := e.cur;
  IF ~WordChar(a) & WordChar(a - 1) THEN DEC(a) END;
  WHILE WordChar(a - 1) DO DEC(a) END;
  b := a; WHILE WordChar(b) DO INC(b) END
END WordAtCursor;

PROCEDURE DrawTh(a, b: INTEGER);
VAR c, i, x, y, w: INTEGER; d: ARRAY 120 OF CHAR;
BEGIN
  bottomReserve := scrRows - 5;
  hlA := a; hlB := b; e.cur := b; e.dirty := TRUE;
  Redraw;
  hlA := -1; bottomReserve := 0;
  FOR y := 6 TO scrRows DO ClearRow(y) END;
  HLine(6, 2550H);
  w := scrCols DIV 3;
  FOR c := 0 TO nCols - 1 DO
    x := c * w + 1;
    IF c = curCol THEN Text(x, 7, colWord[c], cHi, cBg) ELSE TextN(x, 7, colWord[c]) END;
    Cpy(colDef[c], d); IF SLen(d) > w - 2 THEN d[w - 4] := 0X; Append("..", d) END;
    TextN(x, 8, d);
    TextN(x, 9, "1");
    FOR i := 0 TO colRefN[c] - 1 DO
      y := 10 + i;
      IF y < scrRows - 1 THEN
        IF c = curCol THEN PutCp(x, y, CHR(ORD("A") + i), cHi, cBg) END;
        IF ThFind(colRef[c][i]) >= 0 THEN PutUni(x + 2, y, 2022H, cFg, cBg) END;
        Cpy(colRef[c][i], d); IF SLen(d) > w - 5 THEN d[w - 5] := 0X END;
        TextN(x + 4, y, d)
      END
    END
  END;
  MenuText(1, scrRows, "1 Replace Word; 2 View Doc; 3 Look Up Word; 4 Clear Column: 0");
  TUI.SetCursor(63, scrRows); Flush
END DrawTh;

PROCEDURE ThesaurusCmd;
VAR a, b, k, i, n, save: INTEGER; w: ARRAY 64 OF CHAR; s: Str; c: CHAR;
BEGIN
  IF ~LoadTh() THEN
    s[0] := 0X;
    IF Input("Thesaurus not found. Enter name: ", s) THEN Cpy(s, cfg.thPath); thLoaded := FALSE;
      IF ~LoadTh() THEN ErrMsg("Thesaurus not found"); RETURN END
    ELSE RETURN
    END
  END;
  save := e.cur;
  WordAtCursor(a, b);
  ItemsWord(a, b, w);
  nCols := 0; curCol := 0;
  IF (w[0] = 0X) OR ~ThColumn(0, w) THEN
    IF w[0] # 0X THEN Cpy("Word not found: ", s); Append(w, s); ShowMsg(s) END;
    s[0] := 0X;
    IF ~Input("Word: ", s) OR (s[0] = 0X) THEN e.cur := save; RETURN END;
    IF ~ThColumn(0, s) THEN e.cur := save; ErrMsg("Word not found"); RETURN END
  END;
  nCols := 1;
  LOOP
    DrawTh(a, b);
    k := GetKey(); Terminal.HideCursor();
    c := KeyChar(k);
    IF (c >= "A") & (c <= "Z") & (ORD(c) - ORD("A") < colRefN[curCol]) THEN
      i := ORD(c) - ORD("A");
      IF ThFind(colRef[curCol][i]) >= 0 THEN
        IF nCols < MaxThCol THEN n := nCols; INC(nCols) ELSE n := MaxThCol - 1 END;
        Cpy(colRef[curCol][i], w);
        IF ThColumn(n, w) THEN curCol := n END
      END
    ELSIF IsNav(k, nLeft, 0) THEN IF curCol > 0 THEN DEC(curCol) END
    ELSIF IsNav(k, nRight, 0) THEN IF curCol < nCols - 1 THEN INC(curCol) END
    ELSIF c = "1" THEN
      ClearRow(scrRows); TextN(1, scrRows, "Press letter for word "); Flush;
      k := GetKey(); c := KeyChar(k);
      IF (c >= "A") & (ORD(c) - ORD("A") < colRefN[curCol]) & (b > a) THEN
        n := ReplaceWord(a, b, colRef[curCol][ORD(c) - ORD("A")]);
        e.cur := a + n; RETURN
      END
    ELSIF c = "2" THEN
      e.cur := save; Redraw;
      PressKey("View Doc: press any key to return to the Thesaurus")
    ELSIF c = "3" THEN
      s[0] := 0X;
      IF Input("Word: ", s) & (s[0] # 0X) THEN
        IF nCols < MaxThCol THEN n := nCols ELSE n := MaxThCol - 1 END;
        IF ThColumn(n, s) THEN IF n = nCols THEN INC(nCols) END; curCol := n
        ELSE ErrMsg("Word not found")
        END
      END
    ELSIF (c = "4") OR (k = KBS) OR IsNav(k, nDel, 0) THEN
      IF nCols > 1 THEN DEC(nCols); IF curCol >= nCols THEN curCol := nCols - 1 END
      ELSE EXIT
      END
    ELSE EXIT
    END
  END;
  e.cur := save
END ThesaurusCmd;

(* ====================================================================
   Merge.  Merge codes are control characters, as in WordPerfect 4.2:
   ^R ends a field and ^E a record of a secondary file; a primary file
   uses ^Fn^ (^Fn?^ drops the line if the field is empty), ^D date,
   ^C keyboard input, ^O message^O, ^N next record, ^P file^P primary,
   ^S file^S secondary, ^T type (print), ^Q quit, ^G macro^G, ^U, ^V.
   ==================================================================== *)

CONST
  cB = 02X; cC = 03X; cD = 04X; cE = 05X; cF = 06X; cG = 07X; cN = 0EX; cO = 0FX;
  cP = 10X; cQ = 11X; cR = 12X; cS = 13X; cT = 14X; cU = 15X; cV = 16X;
  MaxFields = 20000;

VAR
  secF: ARRAY MaxFields OF Doc;   (* all fields *)
  secRec: ARRAY MaxFields OF INTEGER;
  secN, secRecs: INTEGER;
  mrgMacro: Str;

PROCEDURE IsCtl(VAR x: Item; c: CHAR): BOOLEAN;
BEGIN RETURN (x.k = kCtl) & (x.ch = c)
END IsCtl;

PROCEDURE ParseSecondary(d: Doc);
VAR i: INTEGER; f: Doc;
BEGIN
  secN := 0; secRecs := 0;
  i := 0; f := NewDoc();
  WHILE i < d.n DO
    IF IsCtl(d.it[i], cR) THEN
      IF secN < MaxFields THEN secF[secN] := f; secRec[secN] := secRecs; INC(secN) END;
      f := NewDoc(); INC(i);
      IF (i < d.n) & (d.it[i].k = kHRt) THEN INC(i) END
    ELSIF IsCtl(d.it[i], cE) THEN
      IF f.n > 0 THEN
        IF secN < MaxFields THEN secF[secN] := f; secRec[secN] := secRecs; INC(secN) END
      END;
      f := NewDoc();
      INC(secRecs); INC(i);
      WHILE (i < d.n) & ((d.it[i].k = kHRt) OR (d.it[i].k = kHPg)) DO INC(i) END
    ELSE
      AddItem(f, d.it[i]); INC(i)
    END
  END;
  IF f.n > 0 THEN
    IF secN < MaxFields THEN secF[secN] := f; secRec[secN] := secRecs; INC(secN) END;
    INC(secRecs)
  END
END ParseSecondary;

PROCEDURE GetField(rec, n: INTEGER): Doc;
VAR i, k: INTEGER;
BEGIN
  k := 0;
  FOR i := 0 TO secN - 1 DO
    IF secRec[i] = rec THEN INC(k); IF k = n THEN RETURN secF[i] END END
  END;
  RETURN NIL
END GetField;

(* text between item i and the next code c (the code itself skipped) *)
PROCEDURE CodeArg(p: Doc; VAR i: INTEGER; c: CHAR; VAR s: ARRAY OF CHAR);
VAR j: INTEGER;
BEGIN
  j := 0;
  WHILE (i < p.n) & ~IsCtl(p.it[i], c) DO
    IF (p.it[i].k = kChar) & (j < LEN(s) - 1) THEN s[j] := p.it[i].ch; INC(j) END;
    INC(i)
  END;
  s[j] := 0X;
  IF i < p.n THEN INC(i) END
END CodeArg;

PROCEDURE LoadMergeFile(name: ARRAY OF CHAR; d: Doc): BOOLEAN;
VAR full: Path; fmt: INTEGER;
BEGIN
  FullPath(name, full);
  RETURN ReadFileInto(full, d, fmt)
END LoadMergeFile;

PROCEDURE PrintDoc(d: Doc);
VAR x: Ed;
BEGIN
  x := NewEd(0); x.d := d; x.fmt0 := e.fmt0;
  RenderDoc(x, 0, 0);
  IF ~SendToPrinter(1) THEN ErrMsg("Printer not accepting characters") END
END PrintDoc;

PROCEDURE RunMerge(pName, sName: ARRAY OF CHAR);
VAR p, s, out, f: Doc; i, rec, n, j: INTEGER; stop, quiet: BOOLEAN; arg: Path;
    prompt, t: Str; it: Item; lineEmpty: BOOLEAN;
BEGIN
  p := NewDoc();
  IF ~LoadMergeFile(pName, p) THEN RETURN END;
  secN := 0; secRecs := 1;
  IF sName[0] # 0X THEN
    s := NewDoc();
    IF ~LoadMergeFile(sName, s) THEN RETURN END;
    ParseSecondary(s)
  END;
  ClearRow(StatusRow()); TextN(1, StatusRow(), "* Merging *"); Flush;
  out := NewDoc(); rec := 0; i := 0; stop := FALSE; prompt[0] := 0X; mrgMacro[0] := 0X;
  LOOP
    WHILE (i < p.n) & ~stop DO
      it := p.it[i]; INC(i);
      IF it.k = kCtl THEN
        CASE it.ch OF
          cF:
            n := 0; quiet := FALSE;
            WHILE (i < p.n) & (p.it[i].k = kChar) & IsDigit(p.it[i].ch) DO
              n := n * 10 + ORD(p.it[i].ch) - ORD("0"); INC(i)
            END;
            IF (i < p.n) & (p.it[i].k = kChar) & (p.it[i].ch = "?") THEN quiet := TRUE; INC(i) END;
            IF (i < p.n) & (p.it[i].k = kChar) & (p.it[i].ch = "^") THEN INC(i) END;
            f := GetField(rec, n);
            IF (f # NIL) & (f.n > 0) THEN j := InsDoc(out, out.n, f)
            ELSIF quiet THEN
              lineEmpty := (out.n = 0) OR (out.it[out.n - 1].k = kHRt);
              IF lineEmpty & (i < p.n) & (p.it[i].k = kHRt) THEN INC(i) END
            END
        | cD: FormatDate(cfg.dateFmt, t); AddStr(out, t)
        | cC:
            t[0] := 0X;
            IF prompt[0] # 0X THEN Cpy(prompt, arg) ELSE Cpy("Merge input: ", arg) END;
            Append(" ", arg);
            e.dirty := TRUE; Redraw;
            IF Input(arg, t) THEN AddStr(out, t) ELSE stop := TRUE END;
            prompt[0] := 0X
        | cO: CodeArg(p, i, cO, prompt)
        | cN:
            IF rec + 1 < secRecs THEN INC(rec) ELSE stop := TRUE END
        | cP:
            CodeArg(p, i, cP, arg);
            IF arg[0] # 0X THEN p := NewDoc(); IF ~LoadMergeFile(arg, p) THEN stop := TRUE END END;
            i := 0
        | cQ: stop := TRUE
        | cS:
            CodeArg(p, i, cS, arg);
            s := NewDoc();
            IF LoadMergeFile(arg, s) THEN ParseSecondary(s); rec := 0 ELSE stop := TRUE END
        | cT: PrintDoc(out); out := NewDoc()
        | cG: CodeArg(p, i, cG, mrgMacro)
        | cU:
        | cV: IF i < p.n THEN AddItem(out, p.it[i]); INC(i) END
        ELSE AddItem(out, it)
        END
      ELSE
        AddItem(out, it)
      END
    END;
    IF stop THEN EXIT END;
    IF rec + 1 < secRecs THEN
      AddK(out, kHPg, 0, 0, 0); INC(rec); i := 0
    ELSE EXIT
    END
  END;
  j := InsDoc(e.d, e.cur, out);
  e.cur := e.cur + j; Touch(e);
  IF mrgMacro[0] # 0X THEN RunMacroFile(mrgMacro, 1) END
END RunMerge;

PROCEDURE MergeCodes;
VAR c: CHAR; n: INTEGER; s: Str;
BEGIN
  c := MenuKey("^C; ^D; ^E; ^F; ^G; ^N; ^O; ^P; ^Q; ^R; ^S; ^T; ^U; ^V: ");
  IF c = "F" THEN
    n := 1;
    IF InputInt("Field Number? ", n) THEN
      InsertChar(cF); IntStr(n, s); n := 0; WHILE s[n] # 0X DO InsertChar(s[n]); INC(n) END;
      InsertChar("^")
    END
  ELSE
    CASE c OF
      "C", "D", "E", "G", "N", "O", "P", "Q", "R", "S", "T", "U", "V": InsertChar(CHR(ORD(c) - 64))
    ELSE
    END
  END
END MergeCodes;

(* ====================================================================
   Sort (Ctrl-F9 2)
   ==================================================================== *)

CONST
  MaxRecs = 20000;
  stMerge = 1; stLine = 2; stPara = 3;

VAR
  sortType, sortOrder, sortAction: INTEGER;  (* order 0 asc, 1 desc; action 0 sort, 1 select only *)
  keyTyp: ARRAY 9 OF CHAR;                    (* "a", "n" or 0X = unused *)
  keyFld, keyWrd, keyLin: ARRAY 9 OF INTEGER;
  sortSel: Str;
  recA, recB, ord, tmpOrd: ARRAY MaxRecs OF INTEGER;
  nRecs: INTEGER;
  sd: Doc;                                    (* document being sorted *)
  selPos: INTEGER;
  selRec: INTEGER;

PROCEDURE InitSort;
VAR i: INTEGER;
BEGIN
  IF sortType = 0 THEN
    sortType := stLine; sortOrder := 0; sortAction := 0;
    FOR i := 0 TO 8 DO keyTyp[i] := 0X; keyFld[i] := 1; keyWrd[i] := 1; keyLin[i] := 1 END;
    keyTyp[0] := "a"; sortSel[0] := 0X
  END
END InitSort;

PROCEDURE IsFieldSep(VAR x: Item): BOOLEAN;
BEGIN
  IF sortType = stMerge THEN RETURN IsCtl(x, cR) END;
  RETURN (x.k = kTab) OR (x.k = kAlign) OR (x.k = kIndent) OR (x.k = kLRIndent) OR (x.k = kCenter)
END IsFieldSep;

(* split [a, b) into records *)
PROCEDURE SplitRecords(d: Doc; a, b: INTEGER);
VAR i, s, hr: INTEGER;
BEGIN
  nRecs := 0; i := a;
  WHILE (i < b) & (nRecs < MaxRecs) DO
    s := i;
    IF sortType = stLine THEN
      WHILE (i < b) & (d.it[i].k # kHRt) & (d.it[i].k # kHPg) DO INC(i) END;
      IF i < b THEN INC(i) END
    ELSIF sortType = stPara THEN
      LOOP
        IF i >= b THEN EXIT END;
        IF d.it[i].k = kHRt THEN
          hr := i; WHILE (hr < b) & (d.it[hr].k = kHRt) DO INC(hr) END;
          IF hr - i >= 2 THEN i := hr; EXIT END;
          i := hr
        ELSIF d.it[i].k = kHPg THEN INC(i); EXIT
        ELSE INC(i)
        END
      END
    ELSE
      WHILE (i < b) & ~IsCtl(d.it[i], cE) DO INC(i) END;
      IF i < b THEN INC(i) END;
      WHILE (i < b) & ((d.it[i].k = kHRt) OR (d.it[i].k = kHPg)) DO INC(i) END
    END;
    recA[nRecs] := s; recB[nRecs] := i; INC(nRecs)
  END
END SplitRecords;

(* the text of key k of record r *)
PROCEDURE KeyText(r, k: INTEGER; VAR s: ARRAY OF CHAR);
VAR i, b, n, fld, ln, w, j, nw, target: INTEGER; inWord: BOOLEAN; words: ARRAY 512 OF CHAR;
    starts: ARRAY 64 OF INTEGER;
BEGIN
  s[0] := 0X;
  i := recA[r]; b := recB[r];
  (* line within the record (paragraphs and merge fields) *)
  IF sortType = stMerge THEN
    fld := 1;
    WHILE (i < b) & (fld < keyFld[k]) DO IF IsCtl(sd.it[i], cR) THEN INC(fld) END; INC(i) END;
    IF (i < b) & (sd.it[i].k = kHRt) & (fld > 1) THEN INC(i) END;
    ln := 1;
    WHILE (i < b) & (ln < keyLin[k]) & ~IsCtl(sd.it[i], cR) DO IF sd.it[i].k = kHRt THEN INC(ln) END; INC(i) END
  ELSE
    IF sortType = stPara THEN
      ln := 1;
      WHILE (i < b) & (ln < keyLin[k]) DO IF sd.it[i].k = kHRt THEN INC(ln) END; INC(i) END
    END;
    fld := 1;
    WHILE (i < b) & (fld < keyFld[k]) & (sd.it[i].k # kHRt) DO
      IF IsFieldSep(sd.it[i]) THEN INC(fld) END; INC(i)
    END
  END;
  (* collect the field's text *)
  n := 0;
  WHILE (i < b) & ~IsFieldSep(sd.it[i]) & (sd.it[i].k # kHRt) & ~IsCtl(sd.it[i], cE) & (n < 510) DO
    IF sd.it[i].k = kChar THEN words[n] := sd.it[i].ch; INC(n) END;
    INC(i)
  END;
  words[n] := 0X;
  (* pick the word *)
  nw := 0; inWord := FALSE;
  FOR j := 0 TO n - 1 DO
    IF words[j] # " " THEN
      IF ~inWord & (nw < 64) THEN starts[nw] := j; INC(nw) END; inWord := TRUE
    ELSE inWord := FALSE
    END
  END;
  w := keyWrd[k];
  IF w < 0 THEN target := nw + w ELSE target := w - 1 END;
  IF (target < 0) OR (target >= nw) THEN RETURN END;
  j := starts[target]; n := 0;
  WHILE (words[j] # 0X) & (words[j] # " ") & (n < LEN(s) - 1) DO s[n] := words[j]; INC(n); INC(j) END;
  s[n] := 0X
END KeyText;

PROCEDURE NumVal(s: ARRAY OF CHAR; VAR v: REAL): BOOLEAN;
VAR t: Str; i, j: INTEGER; neg: BOOLEAN; x: REAL; frac: REAL; any: BOOLEAN;
BEGIN
  j := 0; neg := FALSE;
  FOR i := 0 TO SLen(s) - 1 DO
    IF (s[i] = "-") OR (s[i] = "(") THEN neg := TRUE
    ELSIF IsDigit(s[i]) OR (s[i] = ".") THEN t[j] := s[i]; INC(j)
    END
  END;
  t[j] := 0X;
  x := 0.0; frac := 0.0; any := FALSE; i := 0;
  WHILE IsDigit(t[i]) DO x := x * 10.0 + FLT(ORD(t[i]) - ORD("0")); INC(i); any := TRUE END;
  IF t[i] = "." THEN
    INC(i); frac := 0.1;
    WHILE IsDigit(t[i]) DO x := x + frac * FLT(ORD(t[i]) - ORD("0")); frac := frac / 10.0; INC(i); any := TRUE END
  END;
  IF neg THEN x := -x END;
  v := x;
  RETURN any
END NumVal;

PROCEDURE CmpKey(r1, r2, k: INTEGER): INTEGER;
VAR s1, s2: Str; v1, v2: REAL; b1, b2: BOOLEAN;
BEGIN
  KeyText(r1, k, s1); KeyText(r2, k, s2);
  IF keyTyp[k] = "n" THEN
    b1 := NumVal(s1, v1); b2 := NumVal(s2, v2);
    IF ~b1 THEN v1 := 0.0 END; IF ~b2 THEN v2 := 0.0 END;
    IF v1 < v2 THEN RETURN -1 ELSIF v1 > v2 THEN RETURN 1 ELSE RETURN 0 END
  END;
  RETURN StrCmpCI(s1, s2)
END CmpKey;

PROCEDURE RecLess(r1, r2: INTEGER): BOOLEAN;
VAR k, c: INTEGER;
BEGIN
  FOR k := 0 TO 8 DO
    IF keyTyp[k] # 0X THEN
      c := CmpKey(r1, r2, k);
      IF sortOrder = 1 THEN c := -c END;
      IF c # 0 THEN RETURN c < 0 END
    END
  END;
  RETURN FALSE
END RecLess;

PROCEDURE MergeSort(lo, hi: INTEGER);    (* stable sort of ord[lo..hi) *)
VAR mid, i, j, k: INTEGER;
BEGIN
  IF hi - lo < 2 THEN RETURN END;
  mid := (lo + hi) DIV 2;
  MergeSort(lo, mid); MergeSort(mid, hi);
  i := lo; j := mid; k := lo;
  WHILE (i < mid) & (j < hi) DO
    IF RecLess(ord[j], ord[i]) THEN tmpOrd[k] := ord[j]; INC(j) ELSE tmpOrd[k] := ord[i]; INC(i) END;
    INC(k)
  END;
  WHILE i < mid DO tmpOrd[k] := ord[i]; INC(i); INC(k) END;
  WHILE j < hi DO tmpOrd[k] := ord[j]; INC(j); INC(k) END;
  FOR k := lo TO hi - 1 DO ord[k] := tmpOrd[k] END
END MergeSort;

(* ---- select statements: key1=Chicago & key2>60000 | keyg=foo ---- *)

PROCEDURE SelSkip;
BEGIN WHILE sortSel[selPos] = " " DO INC(selPos) END
END SelSkip;

PROCEDURE SelCmp(r: INTEGER): BOOLEAN;
VAR k, op, n, i, w: INTEGER; val, s: Str; v1, v2: REAL; c: INTEGER; global, res, b1: BOOLEAN;
BEGIN
  SelSkip;
  IF sortSel[selPos] = "(" THEN
    INC(selPos); res := SelOr(r); SelSkip;
    IF sortSel[selPos] = ")" THEN INC(selPos) END;
    RETURN res
  END;
  (* keyN or keyg *)
  global := FALSE; k := 0;
  WHILE IsLetter(sortSel[selPos]) & (LoCh(sortSel[selPos]) # "g") DO INC(selPos) END;
  IF LoCh(sortSel[selPos]) = "g" THEN global := TRUE; INC(selPos)
  ELSE
    WHILE IsDigit(sortSel[selPos]) DO k := k * 10 + ORD(sortSel[selPos]) - ORD("0"); INC(selPos) END;
    DEC(k); IF (k < 0) OR (k > 8) THEN k := 0 END
  END;
  SelSkip;
  op := 0;   (* 1 =, 2 <>, 3 >, 4 <, 5 >=, 6 <= *)
  IF sortSel[selPos] = "=" THEN op := 1; INC(selPos)
  ELSIF (sortSel[selPos] = "<") & (sortSel[selPos + 1] = ">") THEN op := 2; selPos := selPos + 2
  ELSIF (sortSel[selPos] = ">") & (sortSel[selPos + 1] = "=") THEN op := 5; selPos := selPos + 2
  ELSIF (sortSel[selPos] = "<") & (sortSel[selPos + 1] = "=") THEN op := 6; selPos := selPos + 2
  ELSIF sortSel[selPos] = ">" THEN op := 3; INC(selPos)
  ELSIF sortSel[selPos] = "<" THEN op := 4; INC(selPos)
  END;
  SelSkip;
  n := 0;
  WHILE (sortSel[selPos] # 0X) & (sortSel[selPos] # " ") & (sortSel[selPos] # "&") &
        (sortSel[selPos] # "|") & (sortSel[selPos] # ")") DO
    val[n] := sortSel[selPos]; INC(n); INC(selPos)
  END;
  val[n] := 0X;
  IF global THEN
    (* any word of the record *)
    res := FALSE;
    FOR i := 1 TO 40 DO
      FOR w := 1 TO 10 DO
        keyFld[8] := i; keyWrd[8] := w; keyLin[8] := 1; keyTyp[8] := "a";
        KeyText(r, 8, s);
        IF (s[0] # 0X) & StrEqCI(s, val) THEN res := TRUE END
      END
    END;
    keyTyp[8] := 0X;
    IF op = 2 THEN RETURN ~res END;
    RETURN res
  END;
  KeyText(r, k, s);
  IF keyTyp[k] = "n" THEN
    b1 := NumVal(s, v1); b1 := NumVal(val, v2);
    IF v1 < v2 THEN c := -1 ELSIF v1 > v2 THEN c := 1 ELSE c := 0 END
  ELSE c := StrCmpCI(s, val)
  END;
  CASE op OF
    1: RETURN c = 0 | 2: RETURN c # 0 | 3: RETURN c > 0 | 4: RETURN c < 0
  | 5: RETURN c >= 0 | 6: RETURN c <= 0
  ELSE RETURN FALSE
  END
END SelCmp;

PROCEDURE SelAnd(r: INTEGER): BOOLEAN;
VAR res, b: BOOLEAN;
BEGIN
  res := SelCmp(r); SelSkip;
  WHILE sortSel[selPos] = "&" DO INC(selPos); b := SelCmp(r); res := res & b; SelSkip END;
  RETURN res
END SelAnd;

PROCEDURE SelOr(r: INTEGER): BOOLEAN;
VAR res, b: BOOLEAN;
BEGIN
  res := SelAnd(r); SelSkip;
  WHILE sortSel[selPos] = "|" DO INC(selPos); b := SelAnd(r); res := res OR b; SelSkip END;
  RETURN res
END SelOr;

PROCEDURE Selected(r: INTEGER): BOOLEAN;
BEGIN
  IF sortSel[0] = 0X THEN RETURN TRUE END;
  selPos := 0;
  RETURN SelOr(r)
END Selected;

(* sort d[a, b); returns the sorted items *)
PROCEDURE DoSort(d: Doc; a, b: INTEGER): Doc;
VAR out: Doc; i, j, n: INTEGER;
BEGIN
  sd := d;
  SplitRecords(d, a, b);
  n := 0;
  FOR i := 0 TO nRecs - 1 DO IF Selected(i) THEN ord[n] := i; INC(n) END END;
  IF sortAction = 0 THEN MergeSort(0, n) END;
  out := NewDoc();
  FOR i := 0 TO n - 1 DO
    FOR j := recA[ord[i]] TO recB[ord[i]] - 1 DO AddItem(out, d.it[j]) END;
    (* a last line without its return gets one *)
    IF (sortType = stLine) & (out.n > 0) & (out.it[out.n - 1].k # kHRt) & (out.it[out.n - 1].k # kHPg) & (i < n - 1) THEN
      AddK(out, kHRt, 0, 0, 0)
    END
  END;
  RETURN CopyDoc(out)
END DoSort;

PROCEDURE SortTypeName(VAR s: ARRAY OF CHAR);
BEGIN
  IF sortType = stMerge THEN Cpy("Sort Secondary Merge File", s)
  ELSIF sortType = stPara THEN Cpy("Sort by Paragraph", s)
  ELSE Cpy("Sort by Line", s)
  END
END SortTypeName;

PROCEDURE DrawSortKeys(y, curK, curF: INTEGER);
VAR k, x, r, f: INTEGER; s: Str; hasLine: BOOLEAN;
BEGIN
  hasLine := sortType # stLine;
  IF hasLine THEN TextB(1, y, "Key Typ Field Line Word") ELSE TextB(1, y, "Key Typ Field Word") END;
  FOR k := 0 TO 8 DO
    r := y + 1 + k DIV 3; x := 1 + (k MOD 3) * 26;
    IntStr(k + 1, s); TextN(x, r, s);
    IF keyTyp[k] # 0X THEN
      FOR f := 0 TO 3 DO
        IF (f # 2) OR hasLine THEN
          s[0] := 0X;
          IF f = 0 THEN AppendCh(keyTyp[k], s)
          ELSIF f = 1 THEN AppendInt(keyFld[k], s)
          ELSIF f = 2 THEN AppendInt(keyLin[k], s)
          ELSE AppendInt(keyWrd[k], s)
          END;
          IF (k = curK) & (f = curF) THEN Text(x + 3 + f * 5, r, s, cBg, cFg) ELSE TextN(x + 3 + f * 5, r, s) END
        END
      END
    ELSIF k = curK THEN Text(x + 3, r, " ", cBg, cFg)
    END
  END
END DrawSortKeys;

PROCEDURE DrawSortScreen(curK, curF: INTEGER);
VAR y: INTEGER; s: Str;
BEGIN
  bottomReserve := 12;
  Redraw;
  bottomReserve := 0;
  y := scrRows - 11;
  FOR y := scrRows - 11 TO scrRows DO ClearRow(y) END;
  y := scrRows - 11;
  HLine(y, 2550H);
  SortTypeName(s); TextB(30, y + 1, s);
  DrawSortKeys(y + 2, curK, curF);
  TextB(1, y + 6, "Select"); TextN(10, y + 6, sortSel);
  TextB(1, y + 8, "Action"); TextB(20, y + 8, "Order"); TextB(40, y + 8, "Type of Sort");
  IF sortAction = 0 THEN TextN(1, y + 9, "Sort") ELSE TextN(1, y + 9, "Select Only") END;
  IF sortOrder = 0 THEN TextN(20, y + 9, "Ascending") ELSE TextN(20, y + 9, "Descending") END;
  IF sortType = stMerge THEN TextN(40, y + 9, "Merge Sort")
  ELSIF sortType = stPara THEN TextN(40, y + 9, "Paragraph Sort")
  ELSE TextN(40, y + 9, "Line Sort")
  END;
  MenuText(1, scrRows, "1 Perform Action; 2 View; 3 Keys; 4 Select; 5 Action; 6 Order; 7 Type: 0")
END DrawSortScreen;

PROCEDURE SetKeyField(k, f, v: INTEGER);
BEGIN
  IF f = 1 THEN keyFld[k] := v ELSIF f = 2 THEN keyLin[k] := v ELSE keyWrd[k] := v END
END SetKeyField;

PROCEDURE EditKeys;
VAR k, curK, curF, i, val, sign: INTEGER; c: CHAR; typing: BOOLEAN;
BEGIN
  curK := 0; curF := 0; typing := FALSE; val := 0; sign := 1;
  LOOP
    DrawSortScreen(curK, curF);
    ClearRow(scrRows);
    TextN(1, scrRows, "a/n type; digits (- from the end) set field/line/word; Del removes key; Exit when done");
    Flush;
    k := GetKey();
    c := KeyChar(k);
    IF (k = KF + 7) OR IsCancel(k) OR (k = KEnter) THEN EXIT
    ELSIF IsNav(k, nRight, 0) OR (k = KTab) THEN
      typing := FALSE;
      REPEAT INC(curF) UNTIL (curF # 2) OR (sortType # stLine);
      IF curF > 3 THEN curF := 0; IF curK < 8 THEN INC(curK) END END
    ELSIF IsNav(k, nLeft, 0) THEN
      typing := FALSE;
      DEC(curF); IF (curF = 2) & (sortType = stLine) THEN DEC(curF) END;
      IF curF < 0 THEN curF := 3; IF curK > 0 THEN DEC(curK) END END
    ELSIF IsNav(k, nDown, 0) THEN typing := FALSE; IF curK + 3 <= 8 THEN curK := curK + 3 END
    ELSIF IsNav(k, nUp, 0) THEN typing := FALSE; IF curK >= 3 THEN curK := curK - 3 END
    ELSIF IsNav(k, nDel, 0) THEN
      typing := FALSE;
      FOR i := curK TO 7 DO
        keyTyp[i] := keyTyp[i + 1]; keyFld[i] := keyFld[i + 1]; keyWrd[i] := keyWrd[i + 1]; keyLin[i] := keyLin[i + 1]
      END;
      keyTyp[8] := 0X
    ELSIF (c = "A") OR (c = "N") THEN
      typing := FALSE;
      keyTyp[curK] := LoCh(c);
      IF keyFld[curK] = 0 THEN keyFld[curK] := 1 END;
      IF keyWrd[curK] = 0 THEN keyWrd[curK] := 1 END;
      IF keyLin[curK] = 0 THEN keyLin[curK] := 1 END
    ELSIF (keyTyp[curK] # 0X) & (curF > 0) & (IsDigit(c) OR (c = "-")) THEN
      IF ~typing THEN val := 0; sign := 1; typing := TRUE END;
      IF c = "-" THEN sign := -1 ELSE val := val * 10 + ORD(c) - ORD("0") END;
      IF val > 0 THEN SetKeyField(curK, curF, sign * val) END
    END
  END
END EditKeys;

PROCEDURE SortCmd;
VAR inName, outName, full: Path; a, b, k, n: INTEGER; c: CHAR; d, res: Doc; blk: BOOLEAN; x: Ed;
BEGIN
  InitSort;
  blk := BlockRange(e, a, b);
  inName[0] := 0X; outName[0] := 0X;
  IF ~blk THEN
    IF ~Input("Input file to sort: (Screen) ", inName) THEN RETURN END;
    IF ~Input("Output file for sort: (Screen) ", outName) THEN RETURN END;
    Trim(inName); Trim(outName)
  END;
  LOOP
    DrawSortScreen(-1, -1); Flush;
    k := GetKey();
    c := KeyChar(k);
    IF c = "1" THEN
      ClearRow(scrRows); TextN(1, scrRows, "* Please Wait *"); Flush;
      IF inName[0] # 0X THEN
        d := NewDoc();
        IF ~LoadMergeFile(inName, d) THEN EXIT END;
        a := 0; b := d.n
      ELSE
        d := e.d;
        IF ~blk THEN a := 0; b := e.d.n END
      END;
      res := DoSort(d, a, b);
      IF outName[0] # 0X THEN
        x := NewEd(0); x.d := res; x.fmt0 := e.fmt0;
        FullPath(outName, full);
        IF SaveTo(x, full, fmtWP42, TRUE, "") THEN END
      ELSIF inName[0] # 0X THEN
        n := InsDoc(e.d, e.cur, res); Touch(e)
      ELSE
        DelItems(e.d, a, b - a);
        n := InsDoc(e.d, a, res);
        e.cur := a; e.anchor := -1; Touch(e)
      END;
      EXIT
    ELSIF c = "2" THEN
      Redraw; PressKey("View: press any key to return to the Sort menu")
    ELSIF c = "3" THEN EditKeys
    ELSIF c = "4" THEN
      IF Input("Select: ", sortSel) THEN END
    ELSIF c = "5" THEN
      c := MenuKey("Action: 1 Select and Sort; 2 Select Only: 0");
      IF c = "1" THEN sortAction := 0 ELSIF c = "2" THEN sortAction := 1 END
    ELSIF c = "6" THEN
      c := MenuKey("Order: 1 Ascending; 2 Descending: 0");
      IF c = "1" THEN sortOrder := 0 ELSIF c = "2" THEN sortOrder := 1 END
    ELSIF c = "7" THEN
      c := MenuKey("Type: 1 Merge; 2 Line; 3 Paragraph: 0");
      IF c = "1" THEN sortType := stMerge ELSIF c = "2" THEN sortType := stLine
      ELSIF c = "3" THEN sortType := stPara END
    ELSE EXIT
    END
  END;
  e.dirty := TRUE
END SortCmd;

PROCEDURE MergeSortCmd;
VAR c: CHAR; p, s: Path;
BEGIN
  IF e.anchor >= 0 THEN SortCmd; RETURN END;
  c := MenuKey("1 Merge; 2 Sort; 3 Sorting Sequences: 0");
  IF c = "1" THEN
    p[0] := 0X; s[0] := 0X;
    IF Input("Primary file: ", p) & (p[0] # 0X) & Input("Secondary file: ", s) THEN
      Trim(s); RunMerge(p, s)
    END
  ELSIF c = "2" THEN SortCmd
  ELSIF c = "3" THEN ShowMsg("Sorting sequence: US/European (only one available)")
  END
END MergeSortCmd;

(* ====================================================================
   Math (Alt-F7).  Columns are the tab stops after the left margin
   (A, B, C ...).  Column types: 0 calculation, 1 text, 2 numeric,
   3 total.  In math mode Tab aligns on the decimal point; + subtotal,
   = total, * grand total, t/T extra subtotal/total entries, N negative,
   and ! marks a calculated column.
   ==================================================================== *)

TYPE
  MathDefRec = RECORD
    typ, neg, dig: ARRAY 24 OF INTEGER;   (* neg: 0 parentheses, 1 minus *)
    form: ARRAY 4 OF ARRAY 40 OF CHAR;
    formCol: ARRAY 4 OF INTEGER
  END;

PROCEDURE DefaultMathDef(VAR m: MathDefRec);
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO 23 DO m.typ[i] := 2; m.neg[i] := 0; m.dig[i] := 2 END;
  FOR i := 0 TO 3 DO m.form[i][0] := 0X; m.formCol[i] := -1 END
END DefaultMathDef;

(* the payload of a Define Math Columns code (D7 ... D7):
   24 old bytes, 4 old formulas, FF, 24 new bytes, 4 new formulas.
   Each column byte: type + 4*negative + 16*digits *)
PROCEDURE ParseMathDef(VAR x: Item; VAR m: MathDefRec);
VAR i, p, f, j, n: INTEGER;
BEGIN
  DefaultMathDef(m);
  IF (x.s = NIL) OR (x.sl < 30) THEN RETURN END;
  p := 1;
  WHILE (p < x.sl) & (x.s[p] # 0FFX) DO INC(p) END;
  INC(p);
  IF p + 24 > x.sl THEN RETURN END;
  FOR i := 0 TO 23 DO
    m.typ[i] := ORD(x.s[p + i]) MOD 4; m.neg[i] := (ORD(x.s[p + i]) DIV 4) MOD 2;
    m.dig[i] := (ORD(x.s[p + i]) DIV 16) MOD 8; IF m.dig[i] > 4 THEN m.dig[i] := 2 END
  END;
  p := p + 24;
  n := 0;
  FOR i := 0 TO 23 DO
    IF (m.typ[i] = 0) & (n < 4) THEN m.formCol[n] := i; INC(n) END
  END;
  FOR f := 0 TO 3 DO
    j := 0;
    WHILE (p < x.sl - 1) & (x.s[p] # 0X) DO
      IF j < 39 THEN m.form[f][j] := x.s[p]; INC(j) END; INC(p)
    END;
    m.form[f][j] := 0X;
    IF p < x.sl - 1 THEN INC(p) END
  END
END ParseMathDef;

PROCEDURE BuildMathDef(VAR m: MathDefRec; VAR x: Item);
VAR i, j, n: INTEGER;
BEGIN
  MkItem(kMathDef, 0D7H, 0, 0, x);
  x.s := NewBytes(256);
  n := 0;
  x.s[n] := 0D7X; INC(n);
  FOR i := 0 TO 23 DO x.s[n] := 0X; INC(n) END;      (* old definition *)
  FOR i := 0 TO 3 DO x.s[n] := 0X; INC(n) END;       (* old formulas *)
  x.s[n] := 0FFX; INC(n);
  FOR i := 0 TO 23 DO x.s[n] := CHR(m.typ[i] + 4 * m.neg[i] + 16 * m.dig[i]); INC(n) END;
  FOR i := 0 TO 3 DO
    FOR j := 0 TO SLen(m.form[i]) - 1 DO x.s[n] := m.form[i][j]; INC(n) END;
    x.s[n] := 0X; INC(n)
  END;
  x.s[n] := 0D7X; INC(n);
  x.sl := n
END BuildMathDef;

PROCEDURE CurMathDef(VAR m: MathDefRec);
VAR i: INTEGER;
BEGIN
  i := FindCodeBack(kMathDef, 0, FALSE);
  IF i >= 0 THEN ParseMathDef(e.d.it[i], m) ELSE DefaultMathDef(m) END
END CurMathDef;

PROCEDURE InMath(): BOOLEAN;
VAR st: Fmt;
BEGIN
  CurFmt(st); RETURN st.mathOn
END InMath;

(* the math column the next tab at the cursor starts (0 = A) *)
PROCEDURE TabColumnIndex(): INTEGER;
VAR i, n: INTEGER;
BEGIN
  Ensure(e);
  n := 0; i := e.lines[LineOf(e, e.cur)].start;
  WHILE i < e.cur DO
    IF (e.d.it[i].k = kTab) OR (e.d.it[i].k = kAlign) THEN INC(n) END;
    INC(i)
  END;
  RETURN n
END TabColumnIndex;

PROCEDURE MathTab(): BOOLEAN;
VAR m: MathDefRec; c: INTEGER; st: Fmt;
BEGIN
  IF ~InMath() THEN RETURN FALSE END;
  CurMathDef(m);
  c := TabColumnIndex();
  IF c > 23 THEN c := 23 END;
  CurFmt(st);
  IF m.typ[c] = 1 THEN InsertCode(kTab, 0, 0, 0)
  ELSIF m.typ[c] = 0 THEN
    InsertCode(kAlign, ORD("."), NextTab(st, e.icol[e.cur]), 0);
    InsertCode(kEndAlign, 0, 0, 0);
    InsertCode(kSingle, fCalcCol, 0, 0)
  ELSE
    InsertPair(kAlign, ORD("."), NextTab(st, e.icol[e.cur]), 0, kEndAlign)
  END;
  RETURN TRUE
END MathTab;

PROCEDURE MathChar(k: INTEGER): BOOLEAN;
VAR c: CHAR;
BEGIN
  c := CHR(k);
  IF (c # "+") & (c # "=") & (c # "*") & (c # "t") & (c # "T") & (c # "N") THEN RETURN FALSE END;
  IF (e.cur = 0) OR (e.cur >= e.d.n) OR (e.d.it[e.cur].k # kEndAlign) OR
     (e.d.it[e.cur - 1].k # kAlign) THEN RETURN FALSE END;
  IF ~InMath() THEN RETURN FALSE END;
  IF c = "+" THEN INC(e.cur); InsertCode(kSingle, fDoSub, 0, 0)
  ELSIF c = "=" THEN INC(e.cur); InsertCode(kSingle, fDoTot, 0, 0)
  ELSIF c = "*" THEN INC(e.cur); InsertCode(kSingle, fDoGrand, 0, 0)
  ELSIF c = "t" THEN InsertCode(kSingle, fSubEnt, 0, 0)
  ELSIF c = "T" THEN InsertCode(kSingle, fTotEnt, 0, 0)
  ELSIF c = "N" THEN InsertCode(kSingle, fNeg, 0, 0)
  END;
  RETURN TRUE
END MathChar;

(* ---- Math Def screen ---- *)

PROCEDURE MathDefScreen;
VAR m: MathDefRec; row, col, k, i, f, x: INTEGER; s: Str; c: CHAR; it: Item;
BEGIN
  CurMathDef(m);
  row := 0; col := 0;
  LOOP
    ClearScreen;
    TextB(30, 1, "Math Definition"); TextN(45, 2, "Use arrow keys to position cursor");
    TextN(1, 4, "Columns"); TextN(1, 6, "Type"); TextN(1, 8, "Negative Numbers");
    TextN(1, 10, "# of digits to"); TextN(1, 11, "the right (0-4)");
    FOR i := 0 TO 23 DO
      x := 20 + i * 2;
      PutCp(x, 4, CHR(ORD("A") + i), cHi, cBg);
      PutCp(x, 6, CHR(ORD("0") + m.typ[i]), cFg, cBg);
      IF m.neg[i] = 0 THEN PutCp(x, 8, "(", cFg, cBg) ELSE PutCp(x, 8, "-", cFg, cBg) END;
      PutCp(x, 10, CHR(ORD("0") + m.dig[i]), cFg, cBg)
    END;
    TextN(1, 13, "Calculation"); TextN(1, 14, "Formulas");
    f := 0;
    FOR i := 0 TO 23 DO
      IF (m.typ[i] = 0) & (f < 4) THEN
        s[0] := CHR(ORD("A") + i); s[1] := 0X; Append("  ", s); Append(m.form[f], s);
        TextN(20, 13 + f, s); INC(f)
      END
    END;
    TextN(1, 18, "Type of Column:");
    TextN(5, 19, "0 = Calculation   1 = Text   2 = Numeric   3 = Total");
    TextN(1, 21, "Negative Numbers");
    TextN(5, 22, "( = Parenthesis (50.00)      - = Minus Sign -50.00");
    TextN(1, 24, "Press EXIT when done");
    TUI.SetCursor(20 + col * 2, 6 + row * 2); Flush;
    k := GetKey();
    c := KeyChar(k);
    IF (k = KF + 7) THEN EXIT
    ELSIF IsCancel(k) THEN Terminal.HideCursor(); RETURN
    ELSIF IsNav(k, nRight, 0) THEN IF col < 23 THEN INC(col) END
    ELSIF IsNav(k, nLeft, 0) THEN IF col > 0 THEN DEC(col) END
    ELSIF IsNav(k, nDown, 0) THEN IF row < 2 THEN INC(row) END
    ELSIF IsNav(k, nUp, 0) THEN IF row > 0 THEN DEC(row) END
    ELSIF (row = 0) & (c >= "0") & (c <= "3") THEN
      m.typ[col] := ORD(c) - ORD("0");
      (* re-assign formulas to calculation columns in order *)
      f := 0;
      FOR i := 0 TO 23 DO IF (m.typ[i] = 0) & (f < 4) THEN m.formCol[f] := i; INC(f) END END;
      IF m.typ[col] = 0 THEN
        f := 0; i := 0;
        WHILE (i < col) DO IF m.typ[i] = 0 THEN INC(f) END; INC(i) END;
        IF f < 4 THEN
          Cpy(m.form[f], s);
          IF Input("Formula: ", s) THEN Cpy(s, m.form[f]) END
        END
      END;
      IF col < 23 THEN INC(col) END
    ELSIF (row = 1) & ((c = "(") OR (c = "-")) THEN
      IF c = "(" THEN m.neg[col] := 0 ELSE m.neg[col] := 1 END;
      IF col < 23 THEN INC(col) END
    ELSIF (row = 2) & (c >= "0") & (c <= "4") THEN
      m.dig[col] := ORD(c) - ORD("0");
      IF col < 23 THEN INC(col) END
    END
  END;
  Terminal.HideCursor();
  BuildMathDef(m, it);
  InsertItem(it)
END MathDefScreen;

(* ---- Calculate ---- *)

PROCEDURE FmtNum(v: REAL; dig, neg: INTEGER; VAR ip, fp: ARRAY OF CHAR);
VAR scale, n, i, intp, fr, g: INTEGER; negative: BOOLEAN; t: Str;
BEGIN
  negative := v < 0.0; IF negative THEN v := -v END;
  scale := 1; FOR i := 1 TO dig DO scale := scale * 10 END;
  n := FLOOR(v * FLT(scale) + 0.5);
  intp := n DIV scale; fr := n MOD scale;
  IntStr(intp, t);
  ip[0] := 0X;
  IF negative THEN IF neg = 0 THEN AppendCh("(", ip) ELSE AppendCh("-", ip) END END;
  g := SLen(t);
  FOR i := 0 TO SLen(t) - 1 DO
    AppendCh(t[i], ip); DEC(g);
    IF (g > 0) & (g MOD 3 = 0) THEN AppendCh(",", ip) END
  END;
  fp[0] := 0X;
  IF dig > 0 THEN
    AppendCh(".", fp);
    IntStr(fr, t);
    FOR i := SLen(t) TO dig - 1 DO AppendCh("0", fp) END;
    Append(t, fp)
  END;
  IF negative & (neg = 0) THEN AppendCh(")", fp) END
END FmtNum;

PROCEDURE EvalFormula(f: ARRAY OF CHAR; VAR vals: ARRAY OF REAL; VAR m: MathDefRec): REAL;
VAR i, k, cnt: INTEGER; acc, v, frac: REAL; op: CHAR; have: BOOLEAN;
BEGIN
  IF StrEq(f, "+") OR StrEq(f, "+/") OR StrEq(f, "=") OR StrEq(f, "=/") THEN
    acc := 0.0; cnt := 0;
    FOR k := 0 TO 23 DO
      IF ((f[0] = "+") & (m.typ[k] = 2)) OR ((f[0] = "=") & (m.typ[k] = 3)) THEN acc := acc + vals[k]; INC(cnt) END
    END;
    IF (f[1] = "/") & (cnt > 0) THEN acc := acc / FLT(cnt) END;
    RETURN acc
  END;
  acc := 0.0; op := "+"; i := 0;
  WHILE f[i] # 0X DO
    have := FALSE;
    IF (UpCh(f[i]) >= "A") & (UpCh(f[i]) <= "X") THEN
      v := vals[ORD(UpCh(f[i])) - ORD("A")]; INC(i); have := TRUE
    ELSIF IsDigit(f[i]) OR (f[i] = ".") THEN
      v := 0.0;
      WHILE IsDigit(f[i]) DO v := v * 10.0 + FLT(ORD(f[i]) - ORD("0")); INC(i) END;
      IF f[i] = "." THEN
        INC(i); frac := 0.1;
        WHILE IsDigit(f[i]) DO v := v + frac * FLT(ORD(f[i]) - ORD("0")); frac := frac / 10.0; INC(i) END
      END;
      have := TRUE
    ELSIF (f[i] = "+") OR (f[i] = "-") OR (f[i] = "*") OR (f[i] = "/") THEN op := f[i]; INC(i)
    ELSE INC(i)
    END;
    IF have THEN
      IF op = "+" THEN acc := acc + v
      ELSIF op = "-" THEN acc := acc - v
      ELSIF op = "*" THEN acc := acc * v
      ELSIF (op = "/") & (v # 0.0) THEN acc := acc / v
      END
    END
  END;
  RETURN acc
END EvalFormula;

PROCEDURE Calculate;
VAR m: MathDefRec; ra, rb, i, rowS, rowE, col, j, k, n, fi: INTEGER;
    sub, tot, grand, vals: ARRAY 24 OF REAL;
    entS, entOp, entCol: ARRAY 24 OF INTEGER; nEnt: INTEGER;
    v, r: REAL; negf: BOOLEAN; s, ip, fp: Str; it: Item;
BEGIN
  CurMathDef(m);
  ra := e.cur;
  WHILE (ra > 0) & ~((e.d.it[ra - 1].k = kSingle) & (e.d.it[ra - 1].a = fMathOn)) DO DEC(ra) END;
  rb := e.cur;
  WHILE (rb < e.d.n) & ~((e.d.it[rb].k = kSingle) & (e.d.it[rb].a = fMathOff)) DO INC(rb) END;
  FOR col := 0 TO 23 DO sub[col] := 0.0; tot[col] := 0.0; grand[col] := 0.0 END;
  rowS := ra;
  WHILE rowS < rb DO
    rowE := rowS;
    WHILE (rowE < rb) & (e.d.it[rowE].k # kHRt) & (e.d.it[rowE].k # kHPg) DO INC(rowE) END;
    (* the entries of this row *)
    nEnt := 0; col := -1;
    FOR col := 0 TO 23 DO vals[col] := 0.0 END;
    col := -1;
    FOR i := rowS TO rowE - 1 DO
      IF (e.d.it[i].k = kTab) OR (e.d.it[i].k = kAlign) THEN
        INC(col);
        IF (col < 24) & (nEnt < 24) THEN entS[nEnt] := i; entOp[nEnt] := -1; entCol[nEnt] := col; INC(nEnt) END
      ELSIF (e.d.it[i].k = kSingle) & (nEnt > 0) &
            ((e.d.it[i].a = fDoSub) OR (e.d.it[i].a = fDoTot) OR (e.d.it[i].a = fDoGrand) OR (e.d.it[i].a = fCalcCol)) THEN
        entOp[nEnt - 1] := i
      END
    END;
    (* values, left to right *)
    FOR j := 0 TO nEnt - 1 DO
      col := entCol[j];
      IF entOp[j] < 0 THEN
        IF m.typ[col] # 1 THEN
          s[0] := 0X; negf := FALSE; n := 0;
          k := entS[j] + 1;
          WHILE (k < rowE) & (e.d.it[k].k # kTab) & (e.d.it[k].k # kAlign) DO
            IF e.d.it[k].k = kChar THEN AppendCh(e.d.it[k].ch, s)
            ELSIF (e.d.it[k].k = kSingle) & (e.d.it[k].a = fNeg) THEN negf := TRUE
            ELSIF (e.d.it[k].k = kSingle) & (e.d.it[k].a = fSubEnt) THEN n := 1
            ELSIF (e.d.it[k].k = kSingle) & (e.d.it[k].a = fTotEnt) THEN n := 2
            END;
            INC(k)
          END;
          IF NumVal(s, v) THEN
            IF negf THEN v := -v END;
            vals[col] := v;
            IF n = 1 THEN tot[col] := tot[col] + v
            ELSIF n = 2 THEN grand[col] := grand[col] + v
            ELSE sub[col] := sub[col] + v
            END
          END
        END
      ELSE
        k := e.d.it[entOp[j]].a;
        IF k = fDoSub THEN r := sub[col]; tot[col] := tot[col] + r; sub[col] := 0.0
        ELSIF k = fDoTot THEN r := tot[col]; grand[col] := grand[col] + r; tot[col] := 0.0
        ELSIF k = fDoGrand THEN r := grand[col]; grand[col] := 0.0
        ELSE
          r := 0.0;
          FOR fi := 0 TO 3 DO IF m.formCol[fi] = col THEN r := EvalFormula(m.form[fi], vals, m) END END
        END;
        vals[col] := r;
        IF k = fCalcCol THEN sub[col] := sub[col] + r END
      END
    END;
    (* write results right to left so indices stay valid *)
    FOR j := nEnt - 1 TO 0 BY -1 DO
      IF entOp[j] >= 0 THEN
        col := entCol[j];
        FmtNum(vals[col], m.dig[col], m.neg[col], ip, fp);
        k := entS[j];
        DelItems(e.d, k + 1, entOp[j] - k - 1);
        n := k + 1;
        IF e.d.it[k].k = kAlign THEN
          FOR i := 0 TO SLen(ip) - 1 DO MkItem(kChar, 0, 0, 0, it); it.ch := ip[i]; InsItem(e.d, n, it); INC(n) END;
          MkItem(kEndAlign, 0, 0, 0, it); InsItem(e.d, n, it); INC(n)
        ELSE
          FOR i := 0 TO SLen(ip) - 1 DO MkItem(kChar, 0, 0, 0, it); it.ch := ip[i]; InsItem(e.d, n, it); INC(n) END
        END;
        FOR i := 0 TO SLen(fp) - 1 DO MkItem(kChar, 0, 0, 0, it); it.ch := fp[i]; InsItem(e.d, n, it); INC(n) END;
        rb := rb + (n - (k + 1)) - (entOp[j] - k - 1);
        IF e.cur > k THEN e.cur := e.cur + (n - (k + 1)) - (entOp[j] - k - 1) END
      END
    END;
    (* next row *)
    rowE := rowS;
    WHILE (rowE < rb) & (e.d.it[rowE].k # kHRt) & (e.d.it[rowE].k # kHPg) DO INC(rowE) END;
    rowS := rowE + 1
  END;
  IF e.cur > e.d.n THEN e.cur := e.d.n END;
  Touch(e)
END Calculate;

PROCEDURE MathCmd;
VAR c: CHAR;
BEGIN
  IF InMath() THEN
    c := MenuKey("1 Math Off; 2 Calculate; 3 Column On/Off; 4 Column Def; 5 Column Display: 0");
    IF c = "1" THEN InsertCode(kSingle, fMathOff, 0, 0)
    ELSIF c = "2" THEN
      ClearRow(StatusRow()); TextN(1, StatusRow(), "* Please Wait *"); Flush;
      Calculate
    ELSIF (c = "3") OR (c = "4") OR (c = "5") THEN ShowMsg("Text columns are not available in obperfect")
    END
  ELSE
    c := MenuKey("1 Math On; 2 Math Def; 3 Column On/Off; 4 Column Def; 5 Column Display: 0");
    IF c = "1" THEN InsertCode(kSingle, fMathOn, 0, 0)
    ELSIF c = "2" THEN MathDefScreen
    ELSIF (c = "3") OR (c = "4") OR (c = "5") THEN ShowMsg("Text columns are not available in obperfect")
    END
  END
END MathCmd;

(* ====================================================================
   Screen (Ctrl-F3): Rewrite, Window, Line Draw, Ctrl/Alt Keys, Colors,
   Auto Rewrite
   ==================================================================== *)

(* box-drawing directions: up 1, down 2, left 4, right 8; style 1 single, 2 double *)
PROCEDURE BoxChar(dirs, style: INTEGER): CHAR;
BEGIN
  IF style = 2 THEN
    CASE dirs OF
      12, 4, 8: RETURN 0CDX | 3, 1, 2: RETURN 0BAX | 10: RETURN 0C9X | 6: RETURN 0BBX
    | 9: RETURN 0C8X | 5: RETURN 0BCX | 11: RETURN 0CCX | 7: RETURN 0B9X
    | 14: RETURN 0CBX | 13: RETURN 0CAX | 15: RETURN 0CEX
    ELSE RETURN " "
    END
  ELSE
    CASE dirs OF
      12, 4, 8: RETURN 0C4X | 3, 1, 2: RETURN 0B3X | 10: RETURN 0DAX | 6: RETURN 0BFX
    | 9: RETURN 0C0X | 5: RETURN 0D9X | 11: RETURN 0C3X | 7: RETURN 0B4X
    | 14: RETURN 0C2X | 13: RETURN 0C1X | 15: RETURN 0C5X
    ELSE RETURN " "
    END
  END
END BoxChar;

PROCEDURE BoxDirs(c: CHAR; VAR dirs, style: INTEGER);
VAR d, s: INTEGER;
BEGIN
  dirs := 0; style := 0;
  FOR s := 1 TO 2 DO
    FOR d := 1 TO 15 DO
      IF (dirs = 0) & (c # " ") & (BoxChar(d, s) = c) THEN
        dirs := d; style := s;
        IF (d = 12) OR (d = 3) THEN RETURN END
      END
    END
  END;
  (* the straight pieces stand for both ends *)
  IF (dirs = 4) OR (dirs = 8) THEN dirs := 12 ELSIF (dirs = 1) OR (dirs = 2) THEN dirs := 3 END
END BoxDirs;

(* the character at line L, column c *)
PROCEDURE CellChar(L, c: INTEGER): CHAR;
VAR i: INTEGER;
BEGIN
  IF L >= e.nlines THEN RETURN " " END;
  FOR i := e.lines[L].start TO e.lines[L].end - 1 DO
    IF (e.d.it[i].k = kChar) & (e.icol[i] = c) THEN RETURN e.d.it[i].ch END
  END;
  RETURN " "
END CellChar;

(* overwrite the character at line L, column c (padding as needed) *)
PROCEDURE SetCell(L, c: INTEGER; ch: CHAR);
VAR i, last, n: INTEGER; it: Item;
BEGIN
  Ensure(e);
  WHILE L >= e.nlines DO
    e.cur := e.d.n; InsertCode(kHRt, 0, 0, 0); Ensure(e)
  END;
  FOR i := e.lines[L].start TO e.lines[L].end - 1 DO
    IF (e.d.it[i].k = kChar) & (e.icol[i] = c) THEN
      e.d.it[i].ch := ch; Touch(e); Ensure(e); RETURN
    END
  END;
  last := e.lines[L].end;
  IF (last > e.lines[L].start) & ((e.d.it[last - 1].k = kHRt) OR (e.d.it[last - 1].k = kHPg)) THEN DEC(last) END;
  i := e.lines[L].start;
  WHILE (i < last) & (e.icol[i] < c) DO INC(i) END;
  IF i = last THEN
    n := c - e.icol[last];
    WHILE n > 0 DO MkItem(kChar, 0, 0, 0, it); it.ch := " "; InsItem(e.d, i, it); INC(i); DEC(n) END
  END;
  MkItem(kChar, 0, 0, 0, it); it.ch := ch; InsItem(e.d, i, it);
  Touch(e); Ensure(e)
END SetCell;

CONST MaxDrawn = 4000;
VAR
  drawnL, drawnC, drawnD: ARRAY MaxDrawn OF INTEGER;   (* cells drawn this session *)
  nDrawn: INTEGER;

PROCEDURE AddDir(L, c, dir, style: INTEGER);
VAR d, s, i, k: INTEGER; ch: CHAR;
BEGIN
  k := -1;
  FOR i := 0 TO nDrawn - 1 DO IF (drawnL[i] = L) & (drawnC[i] = c) THEN k := i END END;
  ch := CellChar(L, c);
  IF (k >= 0) & (BoxChar(drawnD[k] MOD 16, drawnD[k] DIV 16) = ch) THEN
    d := drawnD[k] MOD 16; s := drawnD[k] DIV 16
  ELSE
    BoxDirs(ch, d, s)
  END;
  IF (s # 0) & (s # style) THEN d := 0 END;
  IF ~ODD(d DIV dir) THEN d := d + dir END;
  IF k < 0 THEN
    IF nDrawn < MaxDrawn THEN k := nDrawn; INC(nDrawn); drawnL[k] := L; drawnC[k] := c END
  END;
  IF k >= 0 THEN drawnD[k] := d + 16 * style END;
  SetCell(L, c, BoxChar(d, style))
END AddDir;

PROCEDURE LineDraw;
VAR mode, k, L, c, nl, nc, dir, back, style: INTEGER; ch, drawCh: CHAR; s: Str;
BEGIN
  Ensure(e);
  L := LineOf(e, e.cur); c := e.icol[e.cur];
  mode := 1; drawCh := "*"; nDrawn := 0;
  LOOP
    e.cur := PosInLine(L, c); e.goal := c;
    Redraw;
    ClearRow(StatusRow());
    MenuText(1, StatusRow(), "1 ");
    PutUni(3, StatusRow(), 2502H, cFg, cBg);
    MenuText(4, StatusRow(), "; 2 ");
    PutUni(8, StatusRow(), 2551H, cFg, cBg);
    MenuText(9, StatusRow(), "; 3 ");
    PutCp(13, StatusRow(), drawCh, cFg, cBg);
    MenuText(14, StatusRow(), "; 4 Change; 5 Erase; 6 Move: ");
    PutCp(44, StatusRow(), CHR(ORD("0") + mode), cHi, cBg);
    TUI.SetCursor(c - e.hscroll + 1, curY); Flush;
    k := GetKey();
    IF (k = KF + 7) OR IsCancel(k) OR (k = KEnter) THEN EXIT END;
    ch := KeyChar(k);
    IF (ch >= "1") & (ch <= "6") & (ch # "4") THEN mode := ORD(ch) - ORD("0")
    ELSIF ch = "4" THEN
      ClearRow(StatusRow());
      MenuText(1, StatusRow(), "1 ");  PutCp(3, StatusRow(), 0B1X, cFg, cBg);
      MenuText(4, StatusRow(), "; 2 "); PutCp(8, StatusRow(), 0B0X, cFg, cBg);
      MenuText(9, StatusRow(), "; 3 "); PutCp(13, StatusRow(), 0B2X, cFg, cBg);
      MenuText(14, StatusRow(), "; 4 "); PutCp(18, StatusRow(), 0DBX, cFg, cBg);
      MenuText(19, StatusRow(), "; 5 "); PutCp(23, StatusRow(), 0DCX, cFg, cBg);
      MenuText(24, StatusRow(), "; 6 "); PutCp(28, StatusRow(), 0DFX, cFg, cBg);
      MenuText(29, StatusRow(), "; 7 "); PutCp(33, StatusRow(), 0FEX, cFg, cBg);
      MenuText(34, StatusRow(), "; 8 Other: 0"); Flush;
      k := GetKey(); ch := KeyChar(k);
      CASE ch OF
        "1": drawCh := 0B1X | "2": drawCh := 0B0X | "3": drawCh := 0B2X | "4": drawCh := 0DBX
      | "5": drawCh := 0DCX | "6": drawCh := 0DFX | "7": drawCh := 0FEX
      | "8":
          ClearRow(StatusRow()); TextN(1, StatusRow(), "Solid character: "); Flush;
          k := GetKey();
          IF (k > 32) & (k < 127) THEN drawCh := CHR(k) ELSIF (k > KExt) & (k < KExt + 256) THEN drawCh := CHR(k - KExt) END
      ELSE
      END;
      mode := 3
    ELSE
      dir := 0; nl := L; nc := c;
      IF IsNav(k, nUp, 0) THEN dir := 1; back := 2; DEC(nl)
      ELSIF IsNav(k, nDown, 0) THEN dir := 2; back := 1; INC(nl)
      ELSIF IsNav(k, nLeft, 0) THEN dir := 4; back := 8; DEC(nc)
      ELSIF IsNav(k, nRight, 0) THEN dir := 8; back := 4; INC(nc)
      END;
      IF (dir # 0) & (nl >= 0) & (nc >= 0) & (nc <= 250) THEN
        IF (mode = 1) OR (mode = 2) THEN
          style := mode;
          AddDir(L, c, dir, style);
          AddDir(nl, nc, back, style)
        ELSIF mode = 3 THEN SetCell(L, c, drawCh); SetCell(nl, nc, drawCh)
        ELSIF mode = 5 THEN SetCell(L, c, " "); SetCell(nl, nc, " ")
        END;
        L := nl; c := nc
      END
    END
  END;
  e.cur := PosInLine(L, c); Moved
END LineDraw;

PROCEDURE CtrlAltKeys;
VAR k, i, v, x, y: INTEGER; s: Str;
BEGIN
  LOOP
    ClearScreen;
    TextB(25, 1, "Ctrl/Alt Key Mapping");
    FOR i := 0 TO 25 DO
      x := 1 + (i MOD 4) * 20; y := 3 + i DIV 4;
      Cpy("Alt-", s); AppendCh(CHR(ORD("A") + i), s); Append("  ", s);
      TextN(x, y, s);
      IF cfg.altMap[i] # 0X THEN PutCp(x + 8, y, cfg.altMap[i], cHi, cBg) END
    END;
    TextB(1, 11, "Value   Character");
    FOR i := 128 TO 255 DO
      x := 1 + ((i - 128) MOD 16) * 5; y := 12 + (i - 128) DIV 16;
      IntStr(i, s); TextN(x, y, s); PutCp(x + 3, y, CHR(i), cHi, cBg)
    END;
    TextN(1, scrRows, "Press the Alt key combination to be defined (Exit when done): "); Flush;
    k := GetKey();
    IF (k > KAlt + ORD("a") - 1) & (k <= KAlt + ORD("z")) THEN
      v := ORD(cfg.altMap[k - KAlt - ORD("a")]);
      IF InputInt("Value: ", v) & (v >= 0) & (v <= 255) THEN cfg.altMap[k - KAlt - ORD("a")] := CHR(v) END
    ELSE EXIT
    END
  END;
  SaveSettings
END CtrlAltKeys;

PROCEDURE ColorsMenu;
VAR c: CHAR;
BEGIN
  c := MenuKey("Colors: 1 White on Blue; 2 White on Black; 3 Green screen; 4 Amber screen: 0");
  IF (c >= "1") & (c <= "4") THEN
    cfg.colors := ORD(c) - ORD("0"); ApplyColors; SaveSettings; TUI.InvalidateFront
  END
END ColorsMenu;

PROCEDURE ScreenCmd;
VAR c: CHAR; n: INTEGER; s: Str;
BEGIN
  c := MenuKey("0 Rewrite; 1 Window; 2 Line Draw; 3 Ctrl/Alt Keys; 4 Colors; 5 Auto Rewrite: 0");
  IF c = "0" THEN TUI.InvalidateFront; e.dirty := TRUE
  ELSIF c = "1" THEN
    IF winSplit > 0 THEN n := winSplit ELSE n := scrRows - 1 END;
    Cpy("# Lines in this Window: ", s);
    IF InputInt(s, n) THEN
      IF (n >= 2) & (n < scrRows - 4) THEN winSplit := n;
        IF eds[OtherDoc()] = NIL THEN eds[OtherDoc()] := NewEd(OtherDoc()) END
      ELSE winSplit := 0
      END
    END
  ELSIF c = "2" THEN LineDraw
  ELSIF c = "3" THEN CtrlAltKeys
  ELSIF c = "4" THEN ColorsMenu
  ELSIF c = "5" THEN
    cfg.autoRewrite := YesNo("Auto Rewrite?", cfg.autoRewrite)
  END
END ScreenCmd;

(* ====================================================================
   Macros.  Ctrl-F10 starts and ends a definition: a name of two to
   eight characters (saved as NAME.MAC), Alt+letter (ALTx.MAC), or
   Enter / a single character for a temporary macro.  Alt-F10 runs one,
   Alt+letter runs ALTx.MAC, and Esc n repeats it n times.  Macro files
   hold the recorded keys, one number per line.
   ==================================================================== *)

PROCEDURE MacroFile(name: ARRAY OF CHAR; VAR path: ARRAY OF CHAR);
VAR n: Path;
BEGIN
  Cpy(name, n);
  IF FindCI(".mac", n) < 0 THEN Append(".MAC", n) END;
  FullPath(n, path);
  IF ~Exists(path) THEN
    JoinPath(cfgDir, n, n);
    IF Exists(n) THEN Cpy(n, path) END
  END
END MacroFile;

PROCEDURE SaveMacro(name: ARRAY OF CHAR);
VAR p: Path; i: INTEGER;
BEGIN
  IF (name[0] = 0X) OR (name[1] = 0X) THEN
    FOR i := 0 TO macroLen - 1 DO tempMacro[i] := macroBuf[i] END;
    tempLen := macroLen
  ELSE
    MacroFile(name, p);
    IF ~Exists(p) THEN Cpy(name, p); IF FindCI(".mac", p) < 0 THEN Append(".MAC", p) END; FullPath(p, p) END;
    ObReset;
    PutStr("OBPERFECT-MACRO 1"); Put(10);
    FOR i := 0 TO macroLen - 1 DO IntStr(macroBuf[i], msg); PutStr(msg); Put(10) END;
    msg[0] := 0X;
    IF ~WriteOb(p) THEN ErrMsg("Can't write macro file") END
  END
END SaveMacro;

(* load a macro's keys into repBuf; FALSE if there is none *)
PROCEDURE LoadMacro(name: ARRAY OF CHAR): BOOLEAN;
VAR p: Path; buf: Bytes; len, i, v: INTEGER; line: Str; j: INTEGER; first: BOOLEAN;
BEGIN
  repLen := 0;
  IF (name[0] = 0X) OR (name[1] = 0X) THEN
    IF tempLen = 0 THEN RETURN FALSE END;
    FOR i := 0 TO tempLen - 1 DO repBuf[i] := tempMacro[i] END;
    repLen := tempLen;
    RETURN TRUE
  END;
  MacroFile(name, p);
  IF ~LoadFile(p, buf, len) THEN RETURN FALSE END;
  i := 0; first := TRUE;
  WHILE i < len DO
    j := 0;
    WHILE (i < len) & (buf[i] # 0AX) DO IF j < 250 THEN line[j] := buf[i]; INC(j) END; INC(i) END;
    line[j] := 0X; INC(i);
    IF first THEN first := FALSE
    ELSIF StrInt(line, v) & (repLen < MaxMacro) THEN repBuf[repLen] := v; INC(repLen)
    END
  END;
  RETURN repLen > 0
END LoadMacro;

PROCEDURE RunMacroFile(name: ARRAY OF CHAR; times: INTEGER);
VAR s: Str;
BEGIN
  IF ~LoadMacro(name) THEN
    Cpy("Macro not found: ", s); Append(name, s); ErrMsg(s); RETURN
  END;
  IF times < 1 THEN times := 1 END;
  PushKeys(repBuf, repLen);
  macroRep := macroRep + times - 1
END RunMacroFile;

(* the name typed at "Define Macro:" or "Macro:" (Alt+letter allowed) *)
PROCEDURE MacroName(prompt: ARRAY OF CHAR; VAR name: ARRAY OF CHAR): BOOLEAN;
VAR k, x: INTEGER;
BEGIN
  name[0] := 0X;
  x := StatusPrompt(prompt); TUI.SetCursor(x, StatusRow()); Flush;
  k := GetKey();
  IF IsCancel(k) THEN RETURN FALSE END;
  IF (k > KAlt) & (k < KAlt + 128) THEN
    Cpy("ALT", name); AppendCh(UpCh(CHR(k - KAlt)), name); RETURN TRUE
  END;
  IF k = KEnter THEN RETURN TRUE END;
  UnGet(k);
  IF ~Input(prompt, name) THEN RETURN FALSE END;
  Trim(name);
  RETURN TRUE
END MacroName;

PROCEDURE MacroDefine;
VAR p: Path;
BEGIN
  IF macroRec THEN
    macroRec := FALSE;
    IF macroLen > 0 THEN DEC(macroLen) END;      (* the closing Ctrl-F10 *)
    SaveMacro(macroName);
    ShowMsg("Macro defined")
  ELSE
    IF ~MacroName("Define Macro: ", macroName) THEN RETURN END;
    IF SLen(macroName) > 1 THEN
      MacroFile(macroName, p);
      IF Exists(p) THEN
        Cpy("Replace ", msg); Append(macroName, msg); Append(".MAC?", msg);
        IF ~YesNo(msg, FALSE) THEN msg[0] := 0X; RETURN END;
        msg[0] := 0X
      END
    END;
    macroRec := TRUE; macroLen := 0
  END
END MacroDefine;

PROCEDURE MacroExec(times: INTEGER);
VAR name: Str;
BEGIN
  IF MacroName("Macro: ", name) THEN RunMacroFile(name, times) END
END MacroExec;

PROCEDURE AltKey(k: INTEGER; times: INTEGER);
VAR c: INTEGER; name: Str; i: INTEGER;
BEGIN
  c := k - KAlt;
  IF (c >= ORD("a")) & (c <= ORD("z")) & (cfg.altMap[c - ORD("a")] # 0X) THEN
    FOR i := 1 TO times DO InsertChar(cfg.altMap[c - ORD("a")]) END
  ELSE
    Cpy("ALT", name); AppendCh(UpCh(CHR(c)), name);
    RunMacroFile(name, times)
  END
END AltKey;

PROCEDURE RepeatMacro(k, n: INTEGER);
BEGIN
  IF k = KF + 210 THEN MacroExec(n) ELSE AltKey(k, n) END
END RepeatMacro;

(* ====================================================================
   The keyboard template and Help
   ==================================================================== *)

PROCEDURE KeyFunction(n, m: INTEGER; VAR s: ARRAY OF CHAR);
BEGIN
  s[0] := 0X;
  CASE n OF
    1: IF m = 4 THEN Cpy("Shell", s) ELSIF m = 1 THEN Cpy("Super/Subscript", s)
       ELSIF m = 2 THEN Cpy("Thesaurus", s) ELSE Cpy("Cancel", s) END
  | 2: IF m = 4 THEN Cpy("Spell", s) ELSIF m = 1 THEN Cpy("<-Search", s)
       ELSIF m = 2 THEN Cpy("Replace", s) ELSE Cpy("->Search", s) END
  | 3: IF m = 4 THEN Cpy("Screen", s) ELSIF m = 1 THEN Cpy("Switch", s)
       ELSIF m = 2 THEN Cpy("Reveal Codes", s) ELSE Cpy("Help", s) END
  | 4: IF m = 4 THEN Cpy("Move", s) ELSIF m = 1 THEN Cpy("->Indent<-", s)
       ELSIF m = 2 THEN Cpy("Block", s) ELSE Cpy("->Indent", s) END
  | 5: IF m = 4 THEN Cpy("Text In/Out", s) ELSIF m = 1 THEN Cpy("Date", s)
       ELSIF m = 2 THEN Cpy("Mark Text", s) ELSE Cpy("List Files", s) END
  | 6: IF m = 4 THEN Cpy("Tab Align", s) ELSIF m = 1 THEN Cpy("Center", s)
       ELSIF m = 2 THEN Cpy("Flush Right", s) ELSE Cpy("Bold", s) END
  | 7: IF m = 4 THEN Cpy("Footnote", s) ELSIF m = 1 THEN Cpy("Print", s)
       ELSIF m = 2 THEN Cpy("Math/Columns", s) ELSE Cpy("Exit", s) END
  | 8: IF m = 4 THEN Cpy("Print Format", s) ELSIF m = 1 THEN Cpy("Line Format", s)
       ELSIF m = 2 THEN Cpy("Page Format", s) ELSE Cpy("Underline", s) END
  | 9: IF m = 4 THEN Cpy("Merge/Sort", s) ELSIF m = 1 THEN Cpy("Merge E", s)
       ELSIF m = 2 THEN Cpy("Merge Codes", s) ELSE Cpy("Merge R", s) END
  | 10: IF m = 4 THEN Cpy("Macro Def", s) ELSIF m = 1 THEN Cpy("Retrieve", s)
       ELSIF m = 2 THEN Cpy("Macro", s) ELSE Cpy("Save", s) END
  ELSE
  END
END KeyFunction;

PROCEDURE ModOfRow(r: INTEGER): INTEGER;
BEGIN
  CASE r OF 0: RETURN 4 | 1: RETURN 1 | 2: RETURN 2 ELSE RETURN 0 END
END ModOfRow;

PROCEDURE RowColor(r: INTEGER): INTEGER;
BEGIN
  CASE r OF 0: RETURN TUI.BrightRed | 1: RETURN TUI.BrightGreen | 2: RETURN TUI.BrightCyan
  ELSE RETURN cHi
  END
END RowColor;

PROCEDURE DrawTemplate(selR, selC: INTEGER);
VAR r, c, x, y, fg, bg, w: INTEGER; s: Str;
BEGIN
  ClearScreen;
  TextB(22, 1, "WordPerfect 4.2 Keyboard Template");
  Text(4, 2, "Ctrl", TUI.BrightRed, cBg); Text(10, 2, "Shift", TUI.BrightGreen, cBg);
  Text(17, 2, "Alt", TUI.BrightCyan, cBg); Text(22, 2, "plain key", cHi, cBg);
  w := 15;
  FOR c := 0 TO 9 DO
    x := 1 + (c MOD 5) * w + 4; y := 4 + (c DIV 5) * 7;
    Cpy("F", s); AppendInt(c + 1, s);
    Text(x, y, s, cHi, cBg);
    FOR r := 0 TO 3 DO
      KeyFunction(c + 1, ModOfRow(r), s);
      fg := RowColor(r); bg := cBg;
      IF (r = selR) & (c = selC) THEN fg := cBg; bg := cFg END;
      Text(x, y + 1 + r, s, fg, bg)
    END
  END;
  TextN(1, scrRows - 2, "Arrows choose a function, Enter runs it; Cancel (F1/Esc) returns.");
  TextN(1, scrRows - 1, "Template: F12 (or F3 F3).  Use it when the terminal can't send Shift/Ctrl/Alt+F keys.")
END DrawTemplate;

PROCEDURE Template;
VAR r, c, k: INTEGER;
BEGIN
  r := 3; c := 0;
  LOOP
    DrawTemplate(r, c); Flush;
    k := GetKey();
    IF IsNav(k, nUp, 0) THEN
      IF r > 0 THEN DEC(r) ELSIF c >= 5 THEN c := c - 5; r := 3 END
    ELSIF IsNav(k, nDown, 0) THEN
      IF r < 3 THEN INC(r) ELSIF c < 5 THEN c := c + 5; r := 0 END
    ELSIF IsNav(k, nLeft, 0) THEN IF c > 0 THEN DEC(c) END
    ELSIF IsNav(k, nRight, 0) THEN IF c < 9 THEN INC(c) END
    ELSIF k = KEnter THEN
      e.dirty := TRUE; Redraw;
      Dispatch(KF + 100 * ModOfRow(r) + c + 1);
      EXIT
    ELSIF IsCancel(k) OR (k = KF + 12) THEN EXIT
    ELSIF (k >= KF) & (k < KNav) THEN e.dirty := TRUE; Redraw; Dispatch(k); EXIT
    END
  END;
  e.dirty := TRUE
END Template;

(* help text for a function key *)
PROCEDURE HelpLines(k: INTEGER; VAR a, b, c: ARRAY OF CHAR);
BEGIN
  a[0] := 0X; b[0] := 0X; c[0] := 0X;
  CASE k - KF OF
    1: Cpy("Cancels the current command or menu.  When no command is active it", a);
       Cpy("brings back one of the last three deletions (Undelete: 1 Restore;", b);
       Cpy("2 Show Previous Deletion).  With Block on it turns Block off.", c)
  | 101: Cpy("Superscript or subscript the next character (or the block),", a);
       Cpy("Overstrike (the next character prints over the previous one),", b);
       Cpy("Advance Up/Down half a line, or Advance to a line.", c)
  | 201: Cpy("Thesaurus: synonyms for the word at the cursor.  Press a letter to", a);
       Cpy("look up a headword (marked with a bullet); 1 replaces the word.", b)
  | 401: Cpy("Shell: go to the operating system.  Type EXIT to return.", a)
  | 2: Cpy("Search forward for text and codes.  Press F2 again to start.", a);
       Cpy("Ctrl-V Ctrl-X is a one-character wild card.  Lower case matches", b);
       Cpy("either case.  Up/Down arrows change the direction.", c)
  | 102: Cpy("Search backward.", a)
  | 202: Cpy("Replace: w/Confirm? then the search string, F2, the replacement, F2.", a);
       Cpy("With Block on, only the block is searched.", b)
  | 402: Cpy("Spell: check a word, page, document or block; look up words by", a);
       Cpy("pattern (? and *); count words.  Suggestions are lettered A-X.", b)
  | 3: Cpy("Help.  Press a function key for help on it, a letter for features", a);
       Cpy("starting with that letter, F3 again for the template.", b)
  | 103: Cpy("Switch to the other document (Doc 1 / Doc 2).  With Block on:", a);
       Cpy("convert the block to upper or lower case.", b)
  | 203: Cpy("Reveal Codes: the text with its codes shown in [brackets].", a);
       Cpy("Codes can be deleted there.  Press Alt-F3 or Enter to return.", b)
  | 403: Cpy("Screen: rewrite, split the screen into two windows, Line Draw,", a);
       Cpy("Ctrl/Alt key characters, colors.", b)
  | 4: Cpy("Indent: the left margin moves to the next tab stop until a hard", a);
       Cpy("return.  Shift-Tab after it makes a hanging paragraph.", b)
  | 104: Cpy("Indent both margins one tab stop until the next hard return.", a)
  | 204: Cpy("Block: mark text by moving the cursor, then bold, underline, center,", a);
       Cpy("delete, move, save, print, spell, sort, replace or change case.", b)
  | 404: Cpy("Move: cut, copy or delete a sentence, paragraph, page or block;", a);
       Cpy("retrieve text, a column or a rectangle; append a block to a file.", b)
  | 5: Cpy("List Files: the directory.  1 Retrieve 2 Delete 3 Rename 4 Print", a);
       Cpy("5 Text In 6 Look 7 Change Directory 8 Copy 9 Word Search.", b);
       Cpy("* marks files; typing letters searches by name.", c)
  | 105: Cpy("Date: insert today's date as text, change the date format, or", a);
       Cpy("insert a date function that shows the date when printed.", b)
  | 205: Cpy("Mark Text: redline; with Block, redline or strikeout the block.", a);
       Cpy("6 Other Options removes all redline marks and strikeout text.", b)
  | 405: Cpy("Text In/Out: DOS text files, locked (password) documents,", a);
       Cpy("WordPerfect 4.1 and 5.1 formats, document summary and comments.", b)
  | 6: Cpy("Bold on / off.  With Block on, bolds the block.", a)
  | 106: Cpy("Center the line between the margins (or around the cursor's", a);
       Cpy("column).  With Block on, centers each line of the block.", b)
  | 206: Cpy("Flush Right: the text up to the next hard return ends at the", a);
       Cpy("right margin.", b)
  | 406: Cpy("Tab Align: text moves left until the alignment character (normally", a);
       Cpy("a period) is typed, lining numbers up on the next tab stop.", b)
  | 7: Cpy("Exit: save the document (Y/N), then leave obperfect (Y) or clear", a);
       Cpy("the screen for a new document (N).  In a header, footnote or", b);
       Cpy("comment it returns to the document.", c)
  | 107: Cpy("Print: 1 Full Text 2 Page 3 Options 4 Printer Control 5 Type-thru", a);
       Cpy("6 Preview.  With Block on, prints the block.", b)
  | 207: Cpy("Math: Math On/Off, Math Definition (column types, formulas) and", a);
       Cpy("Calculate (+ subtotal, = total, * grand total, ! formula column).", b)
  | 407: Cpy("Footnote: create or edit footnotes and endnotes, set a new number,", a);
       Cpy("footnote options.  The note's text is typed on a separate screen.", b)
  | 8: Cpy("Underline on / off.  With Block on, underlines the block.", a)
  | 108: Cpy("Line Format: 1/2 tabs, 3 margins, 4 spacing, 5 hyphenation,", a);
       Cpy("6 alignment character.", b)
  | 208: Cpy("Page Format: page numbers, new page number, center page, page", a);
       Cpy("length, top margin, headers and footers, suppress, conditional", b);
       Cpy("end of page, widow/orphan protection.", c)
  | 408: Cpy("Print Format: pitch and font, lines per inch, right justification,", a);
       Cpy("underline style, sheet feeder bin, printer commands, line numbering.", b)
  | 9: Cpy("Merge R: ends a field in a secondary merge file (^R).", a)
  | 109: Cpy("Merge E: ends a record in a secondary merge file (^E).", a)
  | 209: Cpy("Merge Codes: ^C ^D ^E ^Fn^ ^G ^N ^O ^P ^Q ^R ^S ^T ^U ^V.", a)
  | 409: Cpy("Merge/Sort: 1 Merge a primary and a secondary file; 2 Sort lines,", a);
       Cpy("paragraphs or merge records by up to nine keys, with Select.", b)
  | 10: Cpy("Save the document (or, with Block on, the block) to disk.", a)
  | 110: Cpy("Retrieve a document into the screen at the cursor.", a)
  | 210: Cpy("Macro: run a macro (name, Alt+letter, or Enter for the unnamed one).", a)
  | 410: Cpy("Macro Def: start / end recording a macro.", a)
  | 12: Cpy("Template: choose a function from the keyboard template.", a)
  ELSE
  END
END HelpLines;

PROCEDURE HelpIndex(letter: CHAR);
VAR names: ARRAY 1200 OF CHAR; i, y, x, j: INTEGER; s, name, keyn: Str; k, n, m: INTEGER;
BEGIN
  ClearScreen;
  Cpy("Features beginning with ", s); AppendCh(letter, s);
  TextB(5, 1, s);
  y := 3;
  FOR n := 1 TO 10 DO
    FOR m := 0 TO 7 DO
      IF (m = 0) OR (m = 1) OR (m = 2) OR (m = 4) THEN
        KeyFunction(n, m, name);
        j := 0; WHILE (name[j] # 0X) & ~IsLetter(name[j]) DO INC(j) END;
        IF (UpCh(name[j]) = letter) & (y < scrRows - 2) THEN
          FKeyName(KF + 100 * m + n, keyn);
          TextN(5, y, name); TextN(35, y, keyn); INC(y)
        END
      END
    END
  END;
  names[0] := 0X; i := 0; x := 0; k := 0;
  IF y = 3 THEN TextN(5, 3, "(none)") END;
  PressKey("Press any key to continue")
END HelpIndex;

PROCEDURE Help;
VAR k: INTEGER; a, b, c, s, t: Str; ch: CHAR;
BEGIN
  LOOP
    ClearScreen;
    TextB(30, 2, Version);
    TextN(5, 5, "Press any function key to get information about the use of the key.");
    TextN(5, 7, "Press a letter for a list of features beginning with that letter.");
    TextN(5, 9, "Press Enter or Space bar to exit Help.");
    TextN(5, 11, "Press F3 again for the keyboard template.");
    TextN(5, 14, "Shift, Ctrl and Alt with F1-F10 need a terminal that sends them");
    TextN(5, 15, "(xterm style).  F12 brings up the template to choose any of them.");
    Flush;
    k := GetKey();
    IF k = KF + 3 THEN Template; RETURN
    ELSIF (k >= KF) & (k < KNav) THEN
      FKeyName(k, s); KeyFunction((k - KF) MOD 100, (k - KF) DIV 100, t);
      HelpLines(k, a, b, c);
      ClearScreen;
      Append("  ", s); Append(t, s);
      TextB(5, 3, s);
      TextN(5, 6, a); TextN(5, 7, b); TextN(5, 8, c);
      PressKey("Press any key to continue");
      RETURN
    ELSE
      ch := KeyChar(k);
      IF (ch >= "A") & (ch <= "Z") THEN HelpIndex(ch); RETURN END;
      RETURN
    END
  END
END Help;

(* ====================================================================
   Shell (Ctrl-F1)
   ==================================================================== *)

PROCEDURE ShellCmd;
VAR c: CHAR; sh: Path; r: INTEGER;
BEGIN
  c := MenuKey("1 Go to DOS: 0");
  IF c # "1" THEN RETURN END;
  Args.GetEnv("SHELL", sh);
  IF sh[0] = 0X THEN Cpy("/bin/sh", sh) END;
  TUI.Suspend;
  Terminal.Clear();
  Out.String("Enter 'EXIT' to return to obperfect"); Out.Ln; Out.Flush;
  r := OS.Exec(sh);
  TUI.Resume;
  TUI.InvalidateFront;
  e.dirty := TRUE
END ShellCmd;

(* ====================================================================
   The rest of the function keys
   ==================================================================== *)

PROCEDURE CommandKey(k: INTEGER);
BEGIN
  IF k = KF + 101 THEN SuperSub
  ELSIF k = KF + 201 THEN ThesaurusCmd
  ELSIF k = KF + 401 THEN ShellCmd
  ELSIF k = KF + 2 THEN SearchCmd(FALSE)
  ELSIF k = KF + 102 THEN SearchCmd(TRUE)
  ELSIF k = KF + 202 THEN ReplaceCmd
  ELSIF k = KF + 402 THEN SpellCmd
  ELSIF k = KF + 103 THEN
    IF e.anchor >= 0 THEN CaseConvert ELSIF ~e.isSub THEN SwitchDoc END
  ELSIF k = KF + 403 THEN ScreenCmd
  ELSIF k = KF + 404 THEN MoveCmd
  ELSIF k = KF + 5 THEN ListFiles
  ELSIF k = KF + 105 THEN DateCmd
  ELSIF k = KF + 205 THEN MarkText
  ELSIF k = KF + 405 THEN TextInOut
  ELSIF k = KF + 107 THEN PrintCmd
  ELSIF k = KF + 207 THEN MathCmd
  ELSIF k = KF + 407 THEN IF ~e.isSub THEN FootnoteCmd END
  ELSIF k = KF + 108 THEN LineFormat
  ELSIF k = KF + 208 THEN IF ~e.isSub THEN PageFormat END
  ELSIF k = KF + 408 THEN PrintFormat
  ELSIF k = KF + 9 THEN InsertChar(cR); InsertCode(kHRt, 0, 0, 0)
  ELSIF k = KF + 109 THEN InsertChar(cE); InsertCode(kHRt, 0, 0, 0)
  ELSIF k = KF + 209 THEN MergeCodes
  ELSIF k = KF + 409 THEN MergeSortCmd
  ELSIF k = KF + 210 THEN MacroExec(1)
  ELSIF k = KF + 410 THEN MacroDefine
  ELSIF k = KF + 11 THEN Template
  ELSIF (k > KAlt) & (k < KAlt + 128) THEN AltKey(k, 1)
  ELSIF k = KF + 203 THEN revealOn := ~revealOn
  END
END CommandKey;

(* ====================================================================
   Set-up (obperfect -s)
   ==================================================================== *)

PROCEDURE YN(b: BOOLEAN; VAR s: ARRAY OF CHAR);
BEGIN IF b THEN Cpy("Y", s) ELSE Cpy("N", s) END
END YN;

PROCEDURE SetupDirs;
VAR s: Path;
BEGIN
  ClearScreen;
  TextB(15, 2, "Set Directories or Drivers for Dictionary and Thesaurus Files");
  TextN(5, 5, "Main dictionary (LEX.WP):"); TextN(40, 5, cfg.lexPath);
  TextN(5, 6, "Supplementary ({WP}LEX.SUP):"); TextN(40, 6, cfg.supPath);
  TextN(5, 7, "Thesaurus (TH.WP):"); TextN(40, 7, cfg.thPath);
  Flush;
  Cpy(cfg.lexPath, s); IF Input("Main dictionary: ", s) THEN Cpy(s, cfg.lexPath) END;
  Cpy(cfg.supPath, s); IF Input("Supplementary dictionary: ", s) THEN Cpy(s, cfg.supPath) END;
  Cpy(cfg.thPath, s); IF Input("Thesaurus: ", s) THEN Cpy(s, cfg.thPath) END;
  lexLoaded := FALSE; thLoaded := FALSE
END SetupDirs;

PROCEDURE SetupInitial;
VAR k, n, l, r: INTEGER; s: Str; c: CHAR; f: Fmt;
BEGIN
  LOOP
    ClearScreen;
    TextB(25, 1, "Change Initial Settings");
    TextN(5, 2, "Press any of the keys listed below to change initial settings");
    TextB(5, 4, "Key"); TextB(25, 4, "Initial Settings");
    TextN(5, 5, "Line Format"); TextN(25, 5, "Tabs, Margins, Spacing, Hyphenation, Align Character");
    TextN(5, 6, "Page Format"); TextN(25, 6, "Page # Pos, Page Length, Top Margin, W/O");
    TextN(5, 7, "Print Format"); TextN(25, 7, "Pitch, Font, Lines/Inch, Right Just, Underlining");
    TextN(5, 8, "Print"); TextN(25, 8, "Printers, Copies, Binding Width");
    TextN(5, 9, "Date"); TextN(25, 9, "Date Format");
    TextN(5, 10, "Insert/Typeover"); TextN(25, 10, "Insert/Typeover Mode");
    TextN(5, 11, "Footnote"); TextN(25, 11, "Footnote/Endnote Options");
    TextN(5, 12, "Escape"); TextN(25, 12, "Set N");
    TextN(5, 13, "Screen"); TextN(25, 13, "Set Auto-rewrite");
    TextN(5, 14, "Text In/Out"); TextN(25, 14, "Set Insert Document Summary on Save/Exit");
    Cpy("Margins ", s); AppendInt(cfg.fmt.lm, s); AppendCh(" ", s); AppendInt(cfg.fmt.rm, s);
    Append("   Spacing ", s); AppendInt(cfg.fmt.spacing DIV 2, s);
    Append("   Page length ", s); AppendInt(cfg.fmt.formLen, s); AppendCh(",", s); AppendInt(cfg.fmt.textHalf DIV 2, s);
    Append("   Top margin ", s); AppendInt(cfg.fmt.topMar, s);
    TextN(5, 17, s);
    Cpy("Page # position ", s); AppendInt(cfg.fmt.pnPos, s);
    Append("   Right justification ", s); IF cfg.fmt.just THEN Append("On", s) ELSE Append("Off", s) END;
    Append("   Escape n = ", s); AppendInt(cfg.escN, s);
    TextN(5, 18, s);
    TextN(5, 21, "Selection:");
    TextN(5, 22, "Press Enter to return to the Set-up Menu"); TUI.SetCursor(16, 21); Flush;
    k := GetKey(); Terminal.HideCursor();
    IF k = KF + 108 THEN
      c := MenuKey("1 2 Tabs; 3 Margins; 4 Spacing; 5 Hyphenation; 6 Align Char: 0");
      IF (c = "1") OR (c = "2") THEN f := cfg.fmt; e := NewEd(1); IF EditTabs(f) THEN FOR n := 0 TO 255 DO cfg.fmt.tabs[n] := f.tabs[n] END END
      ELSIF c = "3" THEN
        l := cfg.fmt.lm; r := cfg.fmt.rm;
        IF InputInt("Left margin: ", l) & InputInt("Right margin: ", r) & (l < r) THEN cfg.fmt.lm := l; cfg.fmt.rm := r END
      ELSIF c = "4" THEN
        IntStr(cfg.fmt.spacing DIV 2, s);
        IF Input("Spacing: ", s) & ParseHalf(s, n) THEN cfg.fmt.spacing := n END
      ELSIF c = "5" THEN
        cfg.fmt.hyph := YesNo("Hyphenation on?", cfg.fmt.hyph)
      ELSIF c = "6" THEN
        ClearRow(scrRows); TextN(1, scrRows, "Align Char = "); Flush;
        n := GetKey(); IF (n > 32) & (n < 127) THEN cfg.fmt.alignCh := n END
      END
    ELSIF k = KF + 208 THEN
      c := MenuKey("1 Page # Pos; 4 Page Length; 5 Top Margin; A Widow/Orphan: 0");
      IF c = "1" THEN n := cfg.fmt.pnPos; IF InputInt("Page number position (0-8): ", n) & (n >= 0) & (n <= 8) THEN cfg.fmt.pnPos := n END
      ELSIF c = "4" THEN
        l := cfg.fmt.formLen; r := cfg.fmt.textHalf DIV 2;
        IF InputInt("Form length in lines: ", l) & InputInt("Text lines: ", r) & (r <= l) THEN
          cfg.fmt.formLen := l; cfg.fmt.textHalf := r * 2
        END
      ELSIF c = "5" THEN n := cfg.fmt.topMar; IF InputInt("Top margin in half-lines: ", n) THEN cfg.fmt.topMar := n END
      ELSIF c = "A" THEN cfg.fmt.widow := YesNo("Widow/Orphan Protect?", cfg.fmt.widow)
      END
    ELSIF k = KF + 408 THEN
      c := MenuKey("1 Pitch; 2 Lines per Inch; 3 Right Just Off; 4 Right Just On; 5-8 Underline: 0");
      IF c = "1" THEN n := cfg.fmt.pitch; IF InputInt("Pitch: ", n) & (n # 0) THEN cfg.fmt.pitch := n END
      ELSIF c = "2" THEN n := cfg.fmt.lpi; IF InputInt("Lines per inch: ", n) & ((n = 6) OR (n = 8)) THEN cfg.fmt.lpi := n END
      ELSIF c = "3" THEN cfg.fmt.just := FALSE
      ELSIF c = "4" THEN cfg.fmt.just := TRUE
      ELSIF (c >= "5") & (c <= "8") THEN cfg.fmt.undMode := ORD(c) - ORD("5")
      END
    ELSIF k = KF + 107 THEN PrintOptions(cfg.printer, cfg.copies, cfg.binding)
    ELSIF k = KF + 105 THEN DateFormatScreen
    ELSIF k = KNav + nIns THEN cfg.typeover := ~YesNo("Insert mode (N = Typeover)?", ~cfg.typeover)
    ELSIF k = KF + 407 THEN
      n := ORD(cfg.fmt.noteOpt[0]);
      IF InputInt("Spacing within notes: ", n) & (n > 0) & (n < 10) THEN cfg.fmt.noteOpt[0] := CHR(n) END
    ELSIF k = KEsc THEN n := cfg.escN; IF InputInt("Set n = ", n) & (n > 0) THEN cfg.escN := n END
    ELSIF k = KF + 403 THEN cfg.autoRewrite := YesNo("Auto Rewrite?", cfg.autoRewrite)
    ELSIF k = KF + 405 THEN cfg.summaryOnSave := YesNo("Insert Document Summary on Save/Exit?", cfg.summaryOnSave)
    ELSIF (k = KEnter) OR IsCancel(k) THEN EXIT
    END
  END
END SetupInitial;

PROCEDURE SetupScreen;
VAR s: Str; n: INTEGER;
BEGIN
  ClearScreen;
  TextB(25, 2, "Set Screen Options");
  IntStr(scrRows, s); TextN(5, 4, "Number of rows:"); TextN(45, 4, s);
  IntStr(scrCols, s); TextN(5, 5, "Number of columns:"); TextN(45, 5, s);
  TextN(5, 6, "(the terminal's size is used)");
  Flush;
  n := cfg.hrtChar;
  IF InputInt("Hard return displayed as ascii value: ", n) & (n >= 32) & (n < 256) THEN cfg.hrtChar := n END;
  cfg.showName := YesNo("Display filename on status line?", cfg.showName);
  cfg.beepSearch := YesNo("Beep when search fails?", cfg.beepSearch);
  cfg.beepErr := YesNo("Beep on error?", cfg.beepErr);
  cfg.beepHyph := YesNo("Beep on hyphenation?", cfg.beepHyph)
END SetupScreen;

PROCEDURE SetupBackup;
VAR n: INTEGER;
BEGIN
  ClearScreen;
  TextB(25, 2, "Set Timed Backup");
  TextN(5, 4, "To safeguard against losing large amounts of text in the event of a");
  TextN(5, 5, "power or machine failure, obperfect can automatically back up the");
  TextN(5, 6, "documents on the screen at a chosen time interval (to ~/.config/obperfect).");
  TextB(25, 9, "Set Original Backup");
  TextN(5, 11, "obperfect can rename the last copy of a document when a new version");
  TextN(5, 12, "of the document is saved.  The old copy has the same file name with");
  TextN(5, 13, "an extension of .BK!");
  Flush;
  n := cfg.backupMin;
  IF InputInt("Number of minutes between each backup: ", n) & (n >= 0) THEN cfg.backupMin := n END;
  cfg.origBackup := YesNo("Backup the original document?", cfg.origBackup)
END SetupBackup;

(* returns FALSE when cancelled ("ignore changes and return to DOS") *)
PROCEDURE SetupMenu(): BOOLEAN;
VAR k: INTEGER; saved: Settings;
BEGIN
  saved := cfg;
  LOOP
    ClearScreen;
    TextB(32, 3, "Set-up Menu");
    MenuText(10, 6, "0 - End Set-up and enter obperfect");
    MenuText(10, 8, "1 - Set Directories or Drivers for Dictionary and Thesaurus Files");
    MenuText(10, 10, "2 - Set Initial Settings");
    MenuText(10, 12, "3 - Set Screen and Beep Options");
    MenuText(10, 14, "4 - Set Backup Options");
    TextN(10, 17, "Selection: ");
    TextN(10, 20, "Press Cancel to ignore changes and return to DOS");
    TUI.SetCursor(21, 17); Flush;
    k := GetKey(); Terminal.HideCursor();
    IF k = ORD("0") THEN SaveSettings; RETURN TRUE
    ELSIF k = ORD("1") THEN SetupDirs
    ELSIF k = ORD("2") THEN SetupInitial
    ELSIF k = ORD("3") THEN SetupScreen
    ELSIF k = ORD("4") THEN SetupBackup
    ELSIF IsCancel(k) THEN cfg := saved; ApplyColors; RETURN FALSE
    END
  END
END SetupMenu;

(* ====================================================================
   The command loop
   ==================================================================== *)

PROCEDURE ToggleAttr(a: INTEGER);
VAR ba, bb: INTEGER;
BEGIN
  Ensure(e);
  IF BlockRange(e, ba, bb) THEN
    InsertCodeAt(bb, kAttrOff, a, 0, 0);
    InsertCodeAt(ba, kAttrOn, a, 0, 0);
    lastBlockA := e.anchor; lastBlockB := e.cur;
    e.anchor := -1
  ELSIF ODD(ASR(e.iattr[e.cur], a)) THEN InsertCode(kAttrOff, a, 0, 0)
  ELSE InsertCode(kAttrOn, a, 0, 0)
  END
END ToggleAttr;

PROCEDURE BlockToggle;
BEGIN
  IF e.anchor >= 0 THEN
    lastBlockA := e.anchor; lastBlockB := e.cur; e.anchor := -1
  ELSE e.anchor := e.cur
  END
END BlockToggle;

PROCEDURE TabKey;
VAR col, stop, t: INTEGER; st: Fmt;
BEGIN
  Ensure(e);
  SkipEndCode;
  Ensure(e);
  st := e.snaps[e.lines[LineOf(e, e.cur)].snap];
  col := e.icol[e.cur];
  IF MathTab() THEN RETURN END;
  stop := NextTab(st, col);
  t := 0;
  IF (stop <= 250) & (st.tabs[stop] # 0X) THEN t := ORD(st.tabs[stop]) - 1 END;
  CASE t OF
    1: InsertPair(kCenter, 1, stop, 0, kEndCenter)
  | 2, 6: InsertPair(kAlign, 0, stop, t DIV 6, kEndAlign)
  | 3, 7: InsertPair(kAlign, st.alignCh, stop, t DIV 7, kEndAlign)
  ELSE InsertCode(kTab, 0, 0, 0)
  END
END TabKey;

PROCEDURE CenterCmd;
VAR ba, bb, i: INTEGER; L: INTEGER;
BEGIN
  Ensure(e);
  IF BlockRange(e, ba, bb) THEN
    IF YesNo("[Cntr]?", FALSE) THEN
      i := bb;
      WHILE i > ba DO
        L := LineOf(e, i - 1);
        IF e.lines[L].start < ba THEN
          InsertCodeAt(i, kEndCenter, 0, 0, 0); InsertCodeAt(ba, kCenter, 0, 0, 0); i := ba
        ELSE
          IF (e.lines[L].end - 1 >= e.lines[L].start) & (e.d.it[e.lines[L].end - 1].k = kHRt) &
             (e.lines[L].end <= i) THEN
            InsertCodeAt(e.lines[L].end - 1, kEndCenter, 0, 0, 0)
          ELSE InsertCodeAt(i, kEndCenter, 0, 0, 0)
          END;
          InsertCodeAt(e.lines[L].start, kCenter, 0, 0, 0);
          Ensure(e);
          i := e.lines[LineOf(e, e.lines[L].start)].start
        END
      END
    END;
    e.anchor := -1
  ELSIF (e.cur = e.lines[LineOf(e, e.cur)].start) THEN InsertPair(kCenter, 0, 0, 0, kEndCenter)
  ELSE InsertPair(kCenter, 1, e.icol[e.cur], 0, kEndCenter)
  END
END CenterCmd;

PROCEDURE FlushRightCmd;
VAR ba, bb: INTEGER;
BEGIN
  Ensure(e);
  IF BlockRange(e, ba, bb) THEN
    IF YesNo("[FlshRt]?", FALSE) THEN
      InsertCodeAt(bb, kEndAlign, 0, 0, 0); InsertCodeAt(ba, kAlign, 0AH, 0, 0)
    END;
    e.anchor := -1
  ELSE InsertPair(kAlign, 0AH, 0, 0, kEndAlign)
  END
END FlushRightCmd;

PROCEDURE TabAlignCmd;
VAR st: Fmt;
BEGIN
  Ensure(e); SkipEndCode; Ensure(e);
  st := e.snaps[e.lines[LineOf(e, e.cur)].snap];
  InsertPair(kAlign, st.alignCh, NextTab(st, e.icol[e.cur]), 0, kEndAlign);
  Cpy("Align Char = ", msg); AppendCh(CHR(st.alignCh), msg)
END TabAlignCmd;

PROCEDURE MarginRelease;
VAR st: Fmt; col: INTEGER;
BEGIN
  Ensure(e);
  st := e.snaps[e.lines[LineOf(e, e.cur)].snap];
  col := e.icol[e.cur];
  InsertCode(kMarRel, col - PrevTab(st, col), 0, 0)
END MarginRelease;

PROCEDURE EnterKey;
BEGIN
  SkipEndCode;
  InsertCode(kHRt, 0, 0, 0)
END EnterKey;

(* Esc: "n = 8" repeat count for the next key *)
PROCEDURE EscRepeat;
VAR n, k, i: INTEGER; s: Str;
BEGIN
  n := cfg.escN;
  LOOP
    Cpy("n = ", s); AppendInt(n, s);
    i := StatusPrompt(s); Flush;
    k := GetKey();
    IF (k >= ORD("0")) & (k <= ORD("9")) THEN
      IF n = cfg.escN THEN n := 0 END;
      n := n * 10 + k - ORD("0");
      IF n > 9999 THEN n := 9999 END
    ELSE EXIT
    END
  END;
  IF IsCancel(k) THEN RETURN END;
  IF ((k >= 32) & (k < 127)) OR ((k > KExt) & (k < KExt + 256)) THEN
    FOR i := 1 TO n DO
      IF k > KExt THEN InsertChar(CHR(k - KExt)) ELSE InsertChar(CHR(k)) END
    END
  ELSIF (k = KF + 210) OR ((k > KAlt) & (k < KAlt + 128)) THEN
    RepeatMacro(k, n)
  ELSE
    FOR i := 1 TO n DO
      IF ~quit THEN Dispatch(k) END
    END
  END
END EscRepeat;

PROCEDURE MouseClick;
VAR r, L, h, y0: INTEGER;
BEGIN
  Ensure(e);
  y0 := 1;
  IF (winSplit > 0) & (active = 2) THEN y0 := winSplit + 2 END;
  h := WindowRows();
  IF mouseB = 0 THEN
    r := e.top + mouseY - y0;
    IF (mouseY >= y0) & (mouseY < y0 + h) & (r >= 0) & (r < e.nrows) & (e.rows[r].kind = rText) THEN
      L := e.rows[r].line;
      e.cur := PosInLine(L, mouseX - 1 + e.hscroll); Moved
    END
  ELSIF mouseB = 64 THEN MoveLines(-3)
  ELSIF mouseB = 65 THEN MoveLines(3)
  END
END MouseClick;

(* one command key *)
PROCEDURE Dispatch(k: INTEGER);
BEGIN
  IF (k >= 32) & (k < 127) THEN
    IF MathChar(k) THEN ELSE InsertChar(CHR(k)) END
  ELSIF (k > KExt) & (k < KExt + 256) THEN InsertChar(CHR(k - KExt))
  ELSIF k = KEnter THEN EnterKey
  ELSIF k = KCtrlEnter THEN InsertCode(kHPg, 0, 0, 0)
  ELSIF k = KTab THEN TabKey
  ELSIF k = KBS THEN Backspace
  ELSIF k = KCtrlBS THEN DelWord
  ELSIF k = KEsc THEN EscRepeat
  ELSIF k = KMouse THEN MouseClick
  ELSIF (k > 0) & (k < 32) THEN InsertChar(CHR(k))
  ELSIF k = KNav + nLeft THEN IF e.cur > 0 THEN DEC(e.cur) END; Moved
  ELSIF k = KNav + nRight THEN IF e.cur < e.d.n THEN INC(e.cur) END; Moved
  ELSIF k = KNav + nUp THEN MoveLines(-1)
  ELSIF k = KNav + nDown THEN MoveLines(1)
  ELSIF (k = KNav + 400 + nUp) OR (k = KNav + 100 + nUp) THEN ScreenUp
  ELSIF (k = KNav + 400 + nDown) OR (k = KNav + 100 + nDown) THEN ScreenDown
  ELSIF k = KNav + 400 + nLeft THEN WordLeft
  ELSIF k = KNav + 400 + nRight THEN WordRight
  ELSIF k = KNav + nHome THEN HomeKey
  ELSIF k = KNav + nEnd THEN LineEnd
  ELSIF k = KNav + nPgUp THEN PageMove(-1)
  ELSIF k = KNav + nPgDn THEN PageMove(1)
  ELSIF k = KNav + nDel THEN DelChar
  ELSIF k = KNav + 400 + nEnd THEN DelEOL
  ELSIF k = KNav + 400 + nPgDn THEN DelEOP
  ELSIF k = KNav + 400 + nHome THEN GoTo
  ELSIF k = KNav + nIns THEN e.typeover := ~e.typeover
  ELSIF k = KNav + 100 + nTab THEN MarginRelease
  ELSIF k = KF + 1 THEN
    IF e.anchor >= 0 THEN BlockToggle ELSE Undelete END
  ELSIF k = KF + 3 THEN Help
  ELSIF k = KF + 4 THEN InsertCode(kIndent, 0, 0, 0)
  ELSIF k = KF + 104 THEN InsertCode(kLRIndent, 0, 0, 0)
  ELSIF k = KF + 6 THEN ToggleAttr(aBold)
  ELSIF k = KF + 8 THEN ToggleAttr(aUnd)
  ELSIF k = KF + 106 THEN CenterCmd
  ELSIF k = KF + 206 THEN FlushRightCmd
  ELSIF k = KF + 406 THEN TabAlignCmd
  ELSIF k = KF + 203 THEN revealOn := ~revealOn
  ELSIF k = KF + 204 THEN BlockToggle
  ELSIF k = KF + 7 THEN ExitCmd
  ELSIF k = KF + 10 THEN SaveCmd
  ELSIF k = KF + 110 THEN RetrieveCmd
  ELSIF k = KF + 12 THEN Template
  ELSE CommandKey(k)
  END
END Dispatch;

(* the editing loop; a sub-document editor (header, note, comment)
   returns on Exit (F7) *)
PROCEDURE EditLoop(sub: BOOLEAN);
VAR k: INTEGER;
BEGIN
  LOOP
    Ensure(e);
    IF ~Playing() THEN Redraw END;
    k := GetKey();
    msg[0] := 0X;
    IF sub & (k = KF + 7) THEN EXIT END;
    Dispatch(k);
    IF quit THEN EXIT END
  END
END EditLoop;

PROCEDURE RunSub(x: Ed);
VAR prev: Ed; rv: BOOLEAN;
BEGIN
  prev := e; e := x; rv := revealOn; revealOn := FALSE;
  EditLoop(TRUE);
  revealOn := rv; e := prev; e.dirty := TRUE
END RunSub;

(* ====================================================================
   Command-line modes (no full-screen interface)
   ==================================================================== *)

PROCEDURE OutUtf8(s: ARRAY OF CHAR);
VAR t: ARRAY 4096 OF CHAR;
BEGIN
  ToUtf8(s, t); Out.String(t)
END OutUtf8;

PROCEDURE CliLoad(name: ARRAY OF CHAR; x: Ed): BOOLEAN;
VAR r: INTEGER;
BEGIN
  r := LoadDoc(name, x.d, "");
  IF r = -1 THEN Out.ErrString("obperfect: cannot read "); Out.ErrString(name); Out.ErrLn; RETURN FALSE
  ELSIF r = -2 THEN Out.ErrString("obperfect: locked document"); Out.ErrLn; RETURN FALSE
  ELSIF r = -3 THEN Out.ErrString("obperfect: this WordPerfect version (6.x or Macintosh) is not supported"); Out.ErrLn; RETURN FALSE
  END;
  x.srcFmt := r; Cpy(name, x.name); x.dirty := TRUE;
  RETURN TRUE
END CliLoad;

PROCEDURE OutOb;
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO obLen - 1 DO Out.Char(ob[i]) END
END OutOb;

PROCEDURE CliText(name: ARRAY OF CHAR);
VAR x: Ed;
BEGIN
  x := NewEd(1);
  IF CliLoad(name, x) THEN BuildText(x); OutOb END
END CliText;

PROCEDURE RevealDoc(d: Doc; depth: INTEGER);
VAR i, k: INTEGER; s: Str; line: ARRAY 4096 OF CHAR;
BEGIN
  line[0] := 0X;
  FOR i := 0 TO d.n - 1 DO
    IF d.it[i].k = kChar THEN AppendCh(d.it[i].ch, line)
    ELSIF d.it[i].k = kCtl THEN AppendCh("^", line); AppendCh(CHR(ORD(d.it[i].ch) + 64), line)
    ELSE
      CodeName(d.it[i], s); AppendCh("[", line); Append(s, line); AppendCh("]", line);
      IF d.it[i].k = kHRt THEN
        FOR k := 1 TO depth DO Out.String("    ") END;
        OutUtf8(line); Out.Ln; line[0] := 0X
      END;
      IF (d.it[i].sub # NIL) & (d.it[i].k # kHdrFtr) & (d.it[i].k # kNote) THEN
        IF line[0] # 0X THEN OutUtf8(line); Out.Ln; line[0] := 0X END;
        RevealDoc(d.it[i].sub, depth + 1)
      END
    END
  END;
  IF line[0] # 0X THEN
    FOR k := 1 TO depth DO Out.String("    ") END;
    OutUtf8(line); Out.Ln
  END
END RevealDoc;

PROCEDURE CliReveal(name: ARRAY OF CHAR);
VAR x: Ed;
BEGIN
  x := NewEd(1);
  IF CliLoad(name, x) THEN RevealDoc(x.d, 0) END
END CliReveal;

PROCEDURE CliConvert(src, dst: ARRAY OF CHAR);
VAR x: Ed; ext: Str; fmt: INTEGER;
BEGIN
  x := NewEd(1);
  IF CliLoad(src, x) THEN
    ExtOf(dst, ext);
    IF StrEq(ext, "wp5") OR StrEq(ext, "wpd") OR StrEq(ext, "wp51") THEN fmt := fmtWP5
    ELSIF StrEq(ext, "txt") THEN fmt := fmtText
    ELSE fmt := fmtWP42
    END;
    IF ~SaveFile(x, dst, fmt, "") THEN Out.ErrString("obperfect: cannot write "); Out.ErrString(dst); Out.ErrLn END
  END
END CliConvert;

PROCEDURE CliPrint(name, out: ARRAY OF CHAR);
VAR x: Ed;
BEGIN
  x := NewEd(1);
  IF CliLoad(name, x) THEN
    RenderDoc(x, 0, 0); EmitText(FALSE);
    IF out[0] # 0X THEN
      IF ~WriteOb(out) THEN Out.ErrString("obperfect: cannot write "); Out.ErrString(out); Out.ErrLn END
    ELSE OutOb
    END
  END
END CliPrint;

(* the opening screen, as WordPerfect showed while loading *)
PROCEDURE Splash;
VAR t: LONGINT;
BEGIN
  ClearScreen;
  TextB(32, 6, "obperfect");
  TextN(27, 7, "WordPerfect 4.2 work-alike");
  TextN(14, 9, "after Tim Duffy's Four Software Tools (chapters 5-10)");
  TextN(15, 12, "Reads and writes WordPerfect 4.2 and 5.1 documents");
  TextN(15, 16, "Shift/Ctrl/Alt+F1..F10 as on the WordPerfect template;");
  TextN(15, 17, "F3 is Help, F12 the on-screen template.");
  TextN(34, 20, "Please Wait *");
  Flush;
  t := Time.Now();
  WHILE (Time.Now() - t < 700) & ~Terminal.KeyPressed() DO Time.Sleep(20) END
END Splash;

PROCEDURE Main(file: ARRAY OF CHAR; setup: BOOLEAN);
VAR full: Path; fmt: INTEGER; i: INTEGER;
BEGIN
  TUI.Init;
  scrRows := TUI.Rows; scrCols := TUI.Cols;
  IF scrRows > MaxRows THEN scrRows := MaxRows END;
  pushed := -1; qHead := 0; qTail := 0;
  eds[1] := NewEd(1); eds[2] := NIL; active := 1; e := eds[1];
  IF setup THEN
    IF ~SetupMenu() THEN TUI.Done; RETURN END
  ELSE Splash
  END;
  eds[1] := NewEd(1); e := eds[1];
  IF file[0] # 0X THEN
    FullPath(file, full);
    IF Exists(full) THEN
      IF ReadFileInto(full, e.d, fmt) THEN e.srcFmt := fmt END;
      e.dirty := TRUE
    END;
    Cpy(full, e.name)
  END;
  FOR i := 0 TO 2 DO undel[i].d := NIL END;
  lastBlockA := -1; prevPos := 0; hlA := -1;
  quit := FALSE;
  EditLoop(FALSE);
  TUI.Done
END Main;

VAR
  argA, argB, argC: Path;
  nargs: INTEGER;

BEGIN
  InitCp437; InitWP5Sets;
  InitSettings; LoadSettings;
  InitFmt(emptyFmt);
  nargs := Args.Count();
  IF nargs >= 1 THEN Args.Get(1, argA) ELSE argA[0] := 0X END;
  IF nargs >= 2 THEN Args.Get(2, argB) ELSE argB[0] := 0X END;
  IF nargs >= 3 THEN Args.Get(3, argC) ELSE argC[0] := 0X END;
  IF StrEq(argA, "-t") & (argB[0] # 0X) THEN CliText(argB)
  ELSIF StrEq(argA, "-r") & (argB[0] # 0X) THEN CliReveal(argB)
  ELSIF StrEq(argA, "-c") & (argC[0] # 0X) THEN CliConvert(argB, argC)
  ELSIF StrEq(argA, "-p") & (argB[0] # 0X) THEN CliPrint(argB, argC)
  ELSIF StrEq(argA, "-h") OR StrEq(argA, "--help") THEN
    Out.String(Version); Out.Ln;
    Out.String("usage: obperfect [-s] [file] | -t file | -r file | -p file [out] | -c in out"); Out.Ln
  ELSIF StrEq(argA, "-s") OR StrEq(argA, "/s") OR StrEq(argA, "/S") THEN Main(argB, TRUE)
  ELSE Main(argA, FALSE)
  END
END obperfect.
