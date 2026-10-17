# obbase — a dBASE III PLUS work-alike

`examples/obbase.mod` re-creates dBASE III PLUS as described in chapters
18–23 of Tim Duffy's *Four Software Tools*: the Assistant menus, the dot
prompt, full-screen APPEND/EDIT/BROWSE, indexes, reports, labels,
queries, multi-file relations and command files.

It reads and writes real dBASE III files through `Modules/DBF`:

| File | Format |
|------|--------|
| `.DBF` database | dBASE III (header byte 03H, or 83H with memo fields) |
| `.DBT` memo text | dBASE III, 512-byte blocks |
| `.NDX` index | dBASE III B+-tree |
| `.FRM` report form, `.LBL` label form, `.QRY` query, `.VUE` view, `.MEM` memory | small text formats of obbase's own (the originals were binary) |
| `.PRG` command file | plain text, as in dBASE |

## Building and starting

```
cd examples
../obc -I ../Modules obbase.mod -o obbase
./obbase              # starts in ASSIST, like dBASE III PLUS
./obbase start        # runs START.PRG first, like "DBASE START"
./obbase -b prog      # batch: runs PROG.PRG with output on stdout, no full screen
```

Press **Esc** in the Assistant to get the dot prompt, and type `ASSIST`
(or press F2) to go back.  `QUIT` closes every file and exits.

File names follow DOS habits: `USE B:CUSTOMER` works.  The drive letter is
dropped and files live in the current directory (or the one given with
`SET DEFAULT TO <dir>`).  Extensions are added for you, and lookups try the
name as typed, then lower case, then upper case.

## The screen

The work area fills the screen.  Below it:

* **Status bar**: mode, `<drive:>`, alias of the file in use,
  `Rec: n/total` (or `EOF/total`), `Del` when the record is marked
  for deletion, `Ins` in insert mode.
* **Navigation line**: which keys move around the current menu.
* **Message line**: what the current option does.

`SET STATUS OFF` gives the whole screen to the work area.

## The dot prompt

* Up/Down arrows recall earlier commands (`LIST HISTORY` shows them).
* PgUp shows output that scrolled off the top.
* Function keys: F1 `HELP`, F2 `ASSIST`, F3 `LIST`, F4 `DIR`, F5 `DISPLAY
  STRUCTURE`, F6 `DISPLAY STATUS`, F7 `DISPLAY MEMORY`, F8 `DISPLAY`, F9
  `APPEND`, F10 `EDIT` (change them with `SET FUNCTION n TO "..."`).
* Keywords may be shortened to four letters (`DISP STRU`).
* A bad command shows the error and offers help:
  `Do you want some help? (Y/N)`.
* Esc interrupts a long LIST, report or program: `*** INTERRUPTED ***`.

The sentence pattern is the book's **COMMAND SCOPE NOUN CONDITION**:

```
. use customer
. list first, last, amount for amount > 100
. goto top
. list next 5 first, init, last, amount
. list first, last for 'Gho' $ last
. replace all amount with amount + .05
. sum amount for amount > 100
```

Scopes are `ALL`, `NEXT n`, `RECORD n` and `REST`.  `FOR` selects
records and `WHILE` stops at the first record that fails.

## Commands

**Files and work areas:** `USE [file] [INDEX ndx,...] [ALIAS name]`
(`USE ?` gives a file list), `SELECT 1-10 | A-J | alias`, `CLOSE
ALL|DATABASES|INDEX|ALTERNATE|PROCEDURE`, `DIR [skeleton]`, `LIST FILES
[LIKE skel]`, `COPY FILE a TO b`, `RENAME a TO b`, `ERASE f`, `DELETE FILE
f`, `TYPE f [TO PRINT]`, `RUN cmd` / `! cmd`.

**Looking at data:** `LIST`/`DISPLAY [scope] [exp list] [FOR] [WHILE]
[OFF] [TO PRINT]`, `LIST|DISPLAY STRUCTURE | STATUS | MEMORY | HISTORY`,
`? exp, ...`, `?? exp, ...`, `SUM`, `AVERAGE`, `COUNT [TO var]`.

**Moving the pointer:** `GO[TO] TOP|BOTTOM|n` (or just `n`), `SKIP [n]`,
`LOCATE [scope] FOR cond` then `CONTINUE`, `SEEK exp`, `FIND literal`.

**Changing data:** `APPEND`, `APPEND BLANK`, `APPEND FROM file [FOR]
[SDF|DELIMITED [WITH c]]`, `INSERT [BLANK] [BEFORE]`, `EDIT [n]`, `CHANGE`,
`BROWSE [FIELDS list] [FREEZE f] [NOAPPEND]`, `REPLACE [scope] f WITH exp
[, f WITH exp] [FOR] [WHILE]`, `DELETE`, `RECALL`, `PACK`, `ZAP`.

**Ordering:** `SORT ON f1[/A/C/D], f2 ... TO file [scope] [FOR]`, `INDEX
ON exp TO file [UNIQUE]`, `SET INDEX TO list`, `SET ORDER TO n`,
`REINDEX`.  Open indexes are kept up to date by APPEND, EDIT, BROWSE,
REPLACE and PACK; up to seven per file.  Mixed keys need `STR()`:
`INDEX ON zip + STR(amount,8,2) TO zipamoun`.

**Copying and combining:** `COPY TO file [scope] [FIELDS list] [FOR]
[SDF | DELIMITED [WITH c|BLANK]]`, `COPY STRUCTURE [EXTENDED] TO file`,
`CREATE file FROM structfile`, `TOTAL ON key TO file [FIELDS list]`,
`JOIN WITH alias TO file FOR cond [FIELDS list]`, `UPDATE ON key FROM alias
REPLACE f WITH exp [RANDOM]`.

**Several files at once:** `SELECT 2`, `USE invpurch INDEX purchind`,
`SELECT 1`, `SET RELATION TO invid INTO inventry`, then `alias->field` in
any expression.  `SET FIELDS TO list` (fields may come from related
files) limits LIST, DISPLAY, EDIT and BROWSE.  `CREATE VIEW name FROM
ENVIRONMENT` saves the open files, indexes, relations, filters and field
list.  `SET VIEW TO name` restores them.

**Queries and filters:** `SET FILTER TO cond`, `SET FILTER TO FILE
query`, `CREATE|MODIFY QUERY name`, `SET DELETED ON|OFF`.

**Reports and labels:** `CREATE|MODIFY REPORT name`, `REPORT FORM name
[scope] [FOR] [WHILE] [PLAIN] [HEADING "text"] [NOEJECT] [SUMMARY] [TO
PRINT|TO FILE f]`, `CREATE|MODIFY LABEL name`, `LABEL FORM name [scope]
[FOR] [SAMPLE] [TO PRINT|TO FILE f]`.

**Memory variables:** `STORE exp TO a, b`, `a = exp`, `RELEASE list | ALL
[LIKE|EXCEPT skel]`, `SAVE TO f [ALL LIKE|EXCEPT skel]`, `RESTORE FROM f
[ADDITIVE]`, `PUBLIC`, `PRIVATE`.  `&name` macro substitution works in any
command.

**Command files:** `MODIFY COMMAND name`, `DO name [WITH params]`,
`PARAMETERS`, `IF/ELSE/ENDIF`, `DO WHILE/LOOP/EXIT/ENDDO`, `DO
CASE/CASE/OTHERWISE/ENDCASE`, `PROCEDURE`, `SET PROCEDURE TO file`,
`RETURN [TO MASTER]`, `TEXT/ENDTEXT`, `ACCEPT`, `INPUT`, `WAIT`, `@ r,c SAY
... GET ... [PICTURE] [RANGE]`, `READ`, `CLEAR`, `CANCEL`, `SUSPEND` /
`RESUME`, `*`/`NOTE`/`&&` comments, `;` to continue a line.  Memory
variables passed with `DO ... WITH` are passed by reference.  An error in a
program asks `Cancel, Ignore, or Suspend? (C, I, or S)`.

**Printing:** `TO PRINT`, `SET PRINT ON`, `EJECT`, `SET MARGIN TO n` and
`SET DEVICE TO PRINT` all write to `obbase.prn` (or the file named by `SET
PRINTER TO file`).  `SET ALTERNATE TO file` with `SET ALTERNATE ON` also
copies screen output to a file.

**SET options:** ALTERNATE, BELL, CARRY, CENTURY, CONFIRM, CONSOLE, DATE
(AMERICAN, ANSI, BRITISH, ITALIAN, FRENCH, GERMAN), DECIMALS, DEFAULT,
DELETED, DELIMITERS, DEVICE, ECHO, ESCAPE, EXACT, FIELDS, FILTER,
FUNCTION, HEADINGS, HELP, HISTORY, INDEX, INTENSITY, MARGIN, MEMOWIDTH,
MENU, ORDER, PATH, PRINT, PRINTER, PROCEDURE, RELATION, SAFETY, STATUS,
TALK, UNIQUE, VIEW.  `SET` alone is `DISPLAY STATUS`.

**Functions:** ABS ASC AT BOF CDOW CHR CMONTH COL CTOD DATE DAY DBF
DELETED DISKSPACE DOW DTOC EOF ERROR EXP FIELD FILE FKLABEL FKMAX FOUND
GETENV IIF INKEY INT ISALPHA ISCOLOR ISLOWER ISUPPER LEFT LEN LOG LOWER
LTRIM LUPDATE MAX MESSAGE MIN MOD MONTH NDX OS PCOL PROW READKEY RECCOUNT
RECNO RECSIZE REPLICATE RIGHT ROUND ROW RTRIM SPACE SQRT STR STUFF SUBSTR
TIME TRANSFORM TRIM TYPE UPPER VAL VERSION YEAR.

**Operators:** `+ - * / ** ^`, `= <> # < > <= >= $`, `.AND. .OR. .NOT.`
(`!` too).  `+` joins strings and `-` joins them moving trailing blanks to
the end.  `date + n` and `date - date` work.  With `SET EXACT OFF` (the
default), `"Smith" = "Sm"` is true.

## Full-screen keys

These work in APPEND, EDIT, BROWSE, CREATE/MODIFY STRUCTURE and READ:

| Key | Action |
|-----|--------|
| arrows, ^S ^D | character left/right |
| ^E ^X, Up/Down, Enter | previous/next field |
| ^A ^F, Home/End | word left/right |
| Del ^G, Backspace | delete character |
| ^Y | clear the field |
| ^T | delete word |
| ^V | insert/overwrite |
| PgUp ^R / PgDn ^C | previous/next record (saving changes) |
| ^U | mark/unmark the record for deletion |
| Ctrl-Home | edit a memo field |
| ^W, Ctrl-End | save and leave |
| Esc, ^Q | leave without saving the current record |
| F1 | hide/show the cursor menu |

In APPEND, press Enter on the first field of an empty record to finish.
In BROWSE, Ctrl-Left/Right pans, and moving down past the last record
asks `Add new records? (Y/N)`.

The structure screen also has ^N (insert a field) and ^U (delete a
field).  Typing C, N, D, L or M in the Type column sets the type, and the
space bar cycles through them.  An empty field name followed by Enter
asks `Press ENTER to confirm`.

The text editor (MODIFY COMMAND, MODIFY FILE, memo fields) uses the same
WordStar keys plus Enter/^N (split line), ^Y (delete line), ^KF and ^KL
(find, find again), ^KR (read a file in), ^KW (write to a file), and ^W
(save) or Esc (abandon).

## The Assistant

The menus are those of the book's Figure 18.12:

| Menu | Options |
|------|---------|
| Set Up | Database file, Query, View, Quit |
| Create | Database file, View, Query, Report, Label |
| Update | Append, Edit, Display, Browse, Replace, Delete, Recall, Pack |
| Position | Seek, Locate, Continue, Skip, Goto Record |
| Retrieve | List, Display, Report, Label, Sum, Average, Count |
| Organize | Index, Sort, Copy |
| Modify | Database file, View, Query, Report, Label |
| Tools | Set drive, Copy file, Directory, Rename, Erase, List structure |

Commands that take a scope open the submenu *Execute the command /
Specify scope / Construct a field list / Build a search condition / Build
a scope condition*.  The command being built is shown on the action line,
just as the book describes, so the Assistant also teaches the dot-prompt
syntax.  Output ends with `Press any key to continue work in ASSIST.`

## Report forms

The designer has the book's menus: **Options** (page title of up to four
lines separated by `;`, width, margins, lines per page, double spacing,
page ejects, plain page), **Groups** (group and sub-group expressions and
headings, summary only, eject after group), **Columns** (contents,
heading, width, decimals, total; PgUp/PgDn move between columns, ^N
inserts, ^U deletes), **Locate**, and **Exit** (Save/Abandon).  A `;` in a
column heading or contents starts a new line inside the column, and long
text wraps at word boundaries.  For example, the book's two-line address
column is `ADDRESS + ';' + TRIM(CITY) + ', ' + STATE + ' ' + ZIP`.

Reports print `Page No.` and the date (unless PLAIN), centred titles,
column headings, `** Subtotal **` lines for each group and `*** Total ***`
at the end.

## Label forms

**Options** has the predefined sizes (Enter cycles: 3 1/2 x 15/16 by 1, 2
or 3; 4 x 1 7/16; Cheshire; the two Rolodex cards), width, height, left
margin, lines and spaces between labels, labels across, and remarks.
**Contents** has one expression per label line.  A line like
`TRIM(FIRST), LAST` trims each comma-separated part and joins them with
one blank.  Blank lines are squeezed out, as in dBASE.

## Query files

The Set Filter screen has seven lines of *Field Name / Operator /
Constant / Connect*.  Space cycles fields, operators (Matches, Does not
match, More than, Less than, the "or equal" forms, Contains) and connectors
(.AND., .OR., .AND. .NOT., .OR. .NOT.).  F2 previews the matching
records.  Constants are quoted or wrapped in CTOD() automatically.

## Differences from dBASE III PLUS

* Not available: custom screen forms (CREATE SCREEN, `.FMT`), catalogs,
  IMPORT/EXPORT of PFS files, networking, and the interactive CREATE VIEW
  screen (use `CREATE VIEW name FROM ENVIRONMENT`).
* `.FRM`, `.LBL`, `.QRY`, `.VUE` and `.MEM` files are text, so they are
  not interchangeable with real dBASE.  `.DBF`, `.DBT` and `.NDX` files
  are.
* An index is held in memory while open (up to 65,536 keys) and written
  back to the `.NDX` after each command.
* Two-digit years mean 19xx, as in dBASE III.
* There is no 31-record limit, unlike the student version the book uses.
