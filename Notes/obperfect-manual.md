# obperfect — a WordPerfect 4.2 work-alike

`examples/obperfect.mod` re-creates WordPerfect 4.2 for DOS as taught in
chapters 5–10 of Tim Duffy's *Four Software Tools*: the function-key
interface and template, embedded codes and Reveal Codes, the format menus,
printing, block and move, search and replace, two documents and windows,
Line Draw, the Speller and Thesaurus, Merge, Sort, Math, footnotes and
endnotes, and macros.

Documents are real WordPerfect files:

| Format | Read | Write |
|--------|------|-------|
| WordPerfect 4.2 (no header; codes 80h–FEh) | yes — the native format | F10 Save, F7 Exit |
| WordPerfect 4.2 locked (password) document | yes (asks for the key) | Ctrl-F5 4 |
| WordPerfect 4.1 | yes | Ctrl-F5 7 |
| WordPerfect 5.0 / 5.1 (`FFh "WPC"` header) | yes | Ctrl-F5 8, or F10 on a document that was read from a 5.x file |
| DOS text (CR/LF or LF, UTF-8 or code page 437) | yes | Ctrl-F5 1 (formatted lines), Ctrl-F5 6 (generic) |
| WordPerfect 6.x, Macintosh WordPerfect | no (reported) | — |

The WP 4.2 reader and writer follow WordPerfect Corporation's *WordPerfect
File Information* (version 4.2, 1986, from the PC Developer's Toolkit).
Codes obperfect does not interpret are kept byte for byte and written back
unchanged.  Characters above 7Fh are IBM code page 437, stored as WP 4.2
"extended character" functions (E1h c E1h); the screen and text output use
UTF-8.

## Building and starting

```
cd examples
../obc -I ../Modules obperfect.mod -o obperfect
./obperfect                 # a clear screen, like typing WP
./obperfect letter          # edit LETTER
./obperfect -s              # the Set-up menu first, like WP/S
```

Command-line tools (no full screen):

```
./obperfect -t file         # the document as formatted text, on stdout
./obperfect -r file         # its codes, as Reveal Codes shows them
./obperfect -p file [out]   # print (pages with margins, headers, footnotes ...)
./obperfect -c in out       # convert: out.wp5/.wpd -> WP 5.1, .txt -> text,
                            #          anything else -> WP 4.2
```

## The keyboard

WordPerfect is driven by F1–F10 alone and with Shift, Ctrl and Alt:

| | Ctrl | Shift | Alt | plain |
|---|---|---|---|---|
| F1 | Shell | Super/Subscript | Thesaurus | Cancel / Undelete |
| F2 | Spell | ←Search | Replace | →Search |
| F3 | Screen | Switch | Reveal Codes | Help |
| F4 | Move | →Indent← | Block | →Indent |
| F5 | Text In/Out | Date | Mark Text | List Files |
| F6 | Tab Align | Center | Flush Right | Bold |
| F7 | Footnote | Print | Math/Columns | Exit |
| F8 | Print Format | Line Format | Page Format | Underline |
| F9 | Merge/Sort | Merge E | Merge Codes | Merge R |
| F10 | Macro Def | Retrieve | Macro | Save |

The terminal has to send the modified function keys (xterm style, e.g.
`ESC [ 18 ; 2 ~` for Shift-F7): iTerm2, kitty, Ghostty, WezTerm and xterm
do.  Where a key doesn't get through (macOS Terminal sends nothing useful
for Ctrl+F-keys, and laptops may need the fn key), press **F12** (or F3 F3)
for the on-screen template: pick a function with the arrows and Enter.
Alt+letter (macros) needs "Option as Meta" in Terminal/iTerm.

Other keys, as in WordPerfect 4.2:

* Cursor: arrows; Ctrl-←/→ word; End; Home,← / Home,→ line start/end;
  Home,↑ / Home,↓ top/bottom of the screen (and the previous/next screen);
  Home,Home,↑ / Home,Home,↓ start/end of the document; PgUp/PgDn previous/next
  page; Ctrl-↑/↓ (or Shift-↑/↓) screen up/down (the numeric pad's - and +);
  Ctrl-Home "Go to": a page number, ↑/↓ top/bottom of the page, a character,
  or Ctrl-Home again (back to where the last search or go-to started, or
  re-highlight the last block).
* Delete: Del, Backspace, Ctrl-Backspace (word), Home,Del / Home,Backspace
  (rest/start of the word), Ctrl-End (rest of the line), Ctrl-PgDn (rest of
  the page).  Deleting a code outside Reveal Codes asks `Delete [Bold]? (Y/N) N`.
* F1 brings back one of the last three deletions: `Undelete: 1 Restore;
  2 Show Previous Deletion`.
* Ins toggles Typeover.  Tab, Shift-Tab (margin release), Enter (hard
  return), Ctrl-Enter (hard page), Home,Space (hard space), Home,- (hyphen code).
* Esc: `n = 8`; type a number, then a character, cursor key, command or macro
  to repeat it.
* Ctrl+letter types a merge code (^C ^D ^E ^F ... ^V); ^B in a header or
  footer prints the page number.
* The mouse positions the cursor and the wheel scrolls.

## The screen

The text fills 24 lines (or the terminal's height); the status line shows
the file name (or `Typeover`, a blinking `Block on`/`Macro Def`, `Math`,
messages and prompts) and `Doc 1 Pg 1 Ln 1 Pos 10`.  The Pos number is shown
bold or underlined when the text at the cursor is.  Position 10 is one inch
from the paper's edge at 10 pitch, so the default margins are 10 and 74.

Soft page breaks are a line of dashes; hard page breaks (Ctrl-Enter) a line
of `=`.  Double spacing is shown double spaced.  Comments are shown in a
double-line box.  Bold is bright, underline underlined, redline red,
strikeout magenta, superscripts and subscripts yellow, generated text (note
numbers, the date function) green, a block in reverse video.

**Reveal Codes** (Alt-F3) splits the screen: the text above, then the
status line and the tab ruler (`[` `]` margins, `{` `}` when a margin is on
a tab stop, triangles for tabs), then the text with its codes in brackets:
`[B]` `[b]`, `[U]` `[u]`, `[C]` `[c]`, `[A]` `[a]`, `[HRt]`, `[SRt]`, `[TAB]`,
`[->Indent]`, `[Margin Set:10,74]`, `[Hdr/Ftr:1,1;...]`, `[Note:Foot,1;[Note #]...]`
and so on.  The cursor moves over codes one at a time; Del and Backspace
remove them without asking.  Alt-F3 or Enter returns.

As in 4.2, the cursor also stops on codes in the normal screen (the cursor
"doesn't move" when it passes one), and new codes go in at the cursor: Bold
(F6) inserts `[B]` where bold is off and `[b]` where it is on.

## Files (chapter 5–6)

* **Save** (F10): `Document to be Saved:` and `Replace ...? (Y/N) N`.  With a
  block on: `Block Name:` saves just the block.
* **Exit** (F7): `Save Document? (Y/N) Y`, then `Exit WP? (Y/N) N` — N clears the
  screen for a new document, Cancel (F1) goes back.  With a second document
  open, Exit moves to it.
* **Retrieve** (Shift-F10) inserts a file at the cursor (into an empty screen
  it becomes the document).  Format is detected from the contents.
* **List Files** (F5): the directory with sizes, dates and free space.
  1 Retrieve, 2 Delete, 3 Rename, 4 Print, 5 Text In, 6 Look, 7 Change
  Directory (offers to create it), 8 Copy, 9 Word Search (keeps the files
  containing a pattern).  `*` marks files (Alt-F5 marks all); letters search
  by name; `=` at the `Dir` prompt changes directory.
* Backups (Set-up 4): the original document is kept as `NAME.BK!`, and
  timed backups go to `~/.config/obperfect/{WP}BACK.1/2`.

## Formatting (chapters 6–7)

* **Line Format** (Shift-F8): 1/2 tabs (the ruler: Ctrl-End clears from the
  cursor, a number sets a tab — `15,5` sets one every 5 from 15 —, Del clears,
  L C R D set the type, `.` dot leader, Exit when done), 3 margins
  (`[Margin Set] 10 74 to Left = `), 4 spacing (1, 1.5, 2, 3 ...),
  5 hyphenation (codes and the H-zone), 6 alignment character.
* **Indent** (F4), **L/R Indent** (Shift-F4), **Margin Release** (Shift-Tab),
  **Center** (Shift-F6, between the margins or around the cursor's column),
  **Flush Right** (Alt-F6), **Tab Align** (Ctrl-F6: text moves left until the
  alignment character), **Bold** (F6), **Underline** (F8), **Date**
  (Shift-F5: text, format, or a date function that shows the current date).
  Tab stops of type C/R/D align text as Center/Flush/Tab Align do.
* **Super/Subscript** (Shift-F1): superscript, subscript (the next character,
  or each character of a block), Overstrike (Voy a pasar un an`[Ovrstk]`~o
  prints *año*), advance up/down, advance to line.
* **Page Format** (Alt-F8): page number position (nine choices, alternating
  for 4 and 8), new page number (Arabic or Roman), center page top to bottom,
  page length (letter, legal, other), top margin (half-lines), headers and
  footers (A/B, every/odd/even page, discontinue, edit — typed on their own
  screen; ^B is the page number), page number column positions, suppress
  for this page only (`5+6+2`), conditional end of page, widow/orphan.
* **Print Format** (Ctrl-F8): pitch and font, lines per inch, right
  justification on/off (on by default: printed lines are justified), the four
  underline styles, sheet feeder bin, printer commands (`<27>4`), line
  numbering.

## Printing (chapter 6–7)

Shift-F7: `1 Full Text; 2 Page; 3 Options; 4 Printer Control; 5 Type-thru;
6 Preview`.  With a block on, `Print Block? (Y/N)`.

Pages are laid out as WordPerfect does: 66-line forms with 54 text lines,
1-inch top margin, headers (plus a blank line) at the top of the text,
page numbers, footnotes at the bottom with a 2-inch separator, endnotes at
the end, right justification, line numbers.  Printed text is UTF-8;
superscripted digits come out as ¹²³, overstrikes compose (n + ~ = ñ).

Printers (Printer Control, 3 Select Printers): ports LPT1–3 and COM1–4 send
the pages to the system print spooler with `lpr`; any other "port" is a file
name (print to disk).  Printer 6 is the book's *DOS Text Printer*, writing
`DOS.TXT`.  Print Options sets the printer, copies and binding width.

**Preview** (Shift-F7 6) shows the printed pages on the screen.

## Block, Move, Search (chapter 8)

* **Block** (Alt-F4), then Bold, Underline, Center, Flush Right, Del,
  Save, Print, Move, Super/Subscript, Mark Text (redline, strikeout, ToC and
  list marks), Switch (upper/lower case — lower case keeps the first letter
  of sentences and "I"), Spell, Sort, Replace.  Ctrl-Home Ctrl-Home
  re-highlights the last block.
* **Move** (Ctrl-F4): sentence, paragraph, page or block — Cut, Copy, Delete;
  Retrieve text, column or rectangle; Append a block to a file; Cut/Copy a
  tab column or a rectangle (the block's corners).
* **Search** (F2, Shift-F2): the search string can contain codes (press F6,
  Enter, Tab ... at the prompt) and `^X` (Ctrl-V Ctrl-X) matches any
  character.  Lower case matches both cases.  ↑/↓ at the prompt change the
  direction.  **Replace** (Alt-F2) with or without confirmation, in the block
  if one is on.
* **Two documents** (Shift-F3 switches), **windows** (Ctrl-F3 1, e.g. 12
  lines each), **Line Draw** (Ctrl-F3 2: single and double lines with proper
  junctions, `*`, eight other characters, erase, move; Exit when done).
* **Redline and strikeout** (Alt-F5 3, or a block and Alt-F5 3/4);
  Alt-F5 6, 4 removes all redline markings and strikeout text.

## Speller and Thesaurus (chapter 9)

* **Spell** (Ctrl-F2): `Check: 1 Word; 2 Page; 3 Document; 4 Change
  Dictionary; 5 Look Up; 6 Count` (or the block).  Suggestions are lettered
  A–X; `1 Skip Once; 2 Skip; 3 Add Word; 4 Edit; 5 Look Up; 6 Phonetic`;
  double words (`1 2 Skip; 3 Delete 2nd ...`); words with numbers.  A word
  corrected once is corrected again later in the same check.  The main
  dictionary (LEX.WP) is `/usr/share/dict/words` (common endings like -s, -ed,
  -ing are accepted from its base forms); words added go to
  `~/.config/obperfect/wplex.sup`.
* **Thesaurus** (Alt-F1): up to three columns; references marked with a
  bullet are headwords — press their letter to open them; ←/→ choose the
  column; `1 Replace Word; 2 View Doc; 3 Look Up Word; 4 Clear Column`.  The
  word list is `ostar-thesaurus.txt` (shared with ostar; about 1,900
  headwords), or `~/.config/obperfect/th.wp`, or one set in Set-up.

## Merge, Sort, Math, Notes, Macros (chapters 9–10)

* **Merge** (Ctrl-F9 1): primary and secondary files, as in the book.  F9
  ends a field (`^R`), Shift-F9 a record (`^E`); Alt-F9 inserts codes (F asks
  `Field Number?`).  Primary codes: `^Fn^` (and `^Fn?^`, which drops an empty
  line), `^D`, `^C` (keyboard input; the status line shows the `^O...^O`
  message), `^N`, `^P..^P`, `^S..^S`, `^T`, `^Q`, `^G..^G`, `^U`, `^V`.  The
  letters (one per record, with hard page breaks) go into the document.
* **Sort** (Ctrl-F9 2, or with a block): input and output can be the screen
  or files; line, paragraph and secondary-merge sorts; nine keys (type a/n,
  field, line, word — negative counts from the end); ascending/descending;
  Select statements such as `key1=Bloomington & key2>60000 | keyg=Chicago`.
* **Math** (Alt-F7): Math On/Off, Math Def (24 columns: 0 calculation,
  1 text, 2 numeric, 3 total; negative style; digits; four formulas such as
  `B*C`), Calculate.  In math mode Tab aligns numbers on the decimal point;
  `+` subtotal, `=` total, `*` grand total, `t`/`T` extra subtotal/total
  entries, `N` negative; a calculated column shows `!`.
* **Footnotes and endnotes** (Ctrl-F7): create, edit, new number, options
  (spacing, separator line, numbering).  Notes are numbered automatically.
* **Macros**: Ctrl-F10 starts and ends a definition (a 2–8 letter name saves
  `NAME.MAC`; Alt+letter `ALTx.MAC`; Enter or one letter a temporary macro).
  Alt-F10 runs one, Alt+letter runs ALTx.MAC, Esc n repeats; a macro stops
  when a search fails, so `Esc 100 Alt-F10 FOOTNOTE` works as in the book.
  Macro files are text (one key code per line), not WordPerfect's binary
  .MAC format.
* **Text In/Out** (Ctrl-F5): DOS text in and out, locked documents,
  WP 4.1 and 5.1 formats, document summary (date, author, typist, comments)
  and comments.
* **Shell** (Ctrl-F1), **Help** (F3: a function key explains itself, a letter
  lists features, F3 again shows the template).

## Set-up (obperfect -s)

`1` dictionary and thesaurus files, `2` initial settings (press Shift-F8,
Alt-F8, Ctrl-F8, Shift-F7, Shift-F5, Ins, Ctrl-F7, Esc, Ctrl-F3, Ctrl-F5),
`3` screen and beep options (the character shown for hard returns, the file
name on the status line), `4` backup options.  Settings are kept in
`~/.config/obperfect/wp.set`.  Ctrl-F3 4 picks a color scheme (white on blue,
white on black, green or amber screen); Ctrl-F3 3 maps Alt+letters to code
page 437 characters.

## Exchanging files

LibreOffice opens obperfect's files through libwpd, which is a good check
that they are genuine WordPerfect documents.  Its WP 4.2 importer is
partial, though: it shows text, bold, underline, margins and tabs, but
not headers, footers or footnotes, and it maps 4.2 extended characters
differently from code page 437.  For exchange with modern software,
Text In/Out 8 (WordPerfect 5.1) carries headers, footers, footnotes,
endnotes and accented characters, all of which LibreOffice reads.

## Not implemented

Text columns (newspaper/parallel), outlines and paragraph numbering, table
of contents/index/authorities generation (the marks can be inserted and are
kept), aided hyphenation (soft hyphens and hyphen codes work), proportional
fonts and pitch on screen, and WordPerfect's own binary macro format.
WP 4.2 tab-set bitmaps are read with position 0 as the high bit of the
first byte, which matches the one real 4.2 file tested.

## Notes on the implementation

The document is a stream of items (characters and codes); the formatter
lays out the whole document on every change (a 700 KB document takes about
30 ms), divides it into pages, and builds the display rows.  The source is
in one file, in this order: character tables, strings, keyboard, the
document model, WP 4.2 and 5.1 readers/writers, the formatter, display,
editing, the menus, printing, files, Speller, Thesaurus, Merge/Sort, Math,
Screen/Line Draw, macros/Help, Set-up, the main loop.

Writing it needed a few runtime additions in `codegen.c`: Terminal.ReadKey
decodes modified function and cursor keys (`Terminal.Modifiers()`) and
Alt+key (`Terminal.AltChar()`), and Insert; the automatic terminal set-up is
skipped when stdout is not a terminal (so `-t`/`-p` can be piped);
`OS.DirSize`, `OS.DirTime` and `OS.FreeSpace` for List Files; and a codegen
fix for passing a value open-array parameter on to a VAR parameter.
`TUI.SetColor` gained underline/blink/reverse attribute bits
(`TUI.AttrUnderline` etc.).
