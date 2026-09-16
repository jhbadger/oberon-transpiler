# The OStar Manual

*A guide to OStar, the WordStar/WordPerfect-style text editor for the Oberon
system.*

Source: `examples/ostar.mod`. OStar is a full-screen, keyboard-driven prose
editor modeled on the classic WordStar/WordPerfect "diamond and prefix key"
control scheme, ported from an earlier Rust program *PerfectStar
2k*. It is aimed at long-form writing — manuscripts, chapters, notes — rather
than source code, and it bundles the tools a writer actually reaches for:
block/kill-ring editing, incremental search and replace, undo, word wrap,
spell checking (via hunspell), a lightweight prose-style checker, RTF
manuscript export, and a small multi-document "project" system with a
binder and outline panel.

---

## Part 1 — Introduction

### What OStar is

OStar edits plain text files a screen at a time in your terminal. There is
no mouse-driven menu bar and (mostly) no dialogs — every command is a key
chord, in the WordStar tradition: hold Ctrl and press a letter, and some
commands are two Ctrl-chords in a row (a *prefix* followed by a letter).

If you've never used WordStar or WordPerfect, the mental model is:

- Movement and single-key edits are plain `Ctrl+<letter>` chords.
- Four *prefix* keys — `^K`, `^Q`, `^O`, `^P` — open a "menu" of further
  letter commands. Press the prefix, then a letter, e.g. `^K` then `S` to
  save.
- Press `F1` at any time to see the full key list (the *command palette*).

### Why a two-key scheme

The diamond/prefix layout was designed decades ago for keyboards with no
arrow or function keys — every command reachable with Ctrl and a letter
under the left hand. OStar keeps that discipline (it still works over SSH
on a bare terminal with nothing but Ctrl), but also recognizes ordinary
arrow keys, Home/End, Page Up/Down, and the mouse, so you can mix styles.

### Feature summary

| Area | Highlights |
|---|---|
| Editing | Insert/overtype, undo (400 levels), word-left/right, transpose char/word, kill ring (8 slots) for cut/copy/paste of lines and blocks |
| Movement | Diamond keys, word/sentence/paragraph/heading jumps, "previous position" jump (`^QP`), screen top/bottom, doc start/end |
| Search | Incremental find (`^QF`), find & replace with per-match Y/N/A confirmation (`^QA`), find-next (`^L`) |
| Word wrap | Soft (visual) wrap at a configurable column, on by default at 72 |
| Spell check | hunspell-backed; flags misspellings in the theme's error color, jump between them, maintain a personal dictionary |
| Style check | Flags `-ly` adverbs, filler/hedge words, passive voice, and overlong sentences, each in its own color |
| Projects | Group several files into a `.ostarproj` manifest; binder popup, outline panel, project-wide search, and "compile" (concatenate all docs to one RTF or text file) |
| Export | Manuscript-format RTF (`^KM`), a notes-stripped clean `.txt` (`^KE`), and timestamped backup snapshots (`^KN`) |
| Look & feel | Three themes (WordPerfect blue, WordStar black, terminal default), three help-verbosity levels, focus mode, typewriter scrolling |

### Building and running OStar

OStar is an Oberon-07 source file compiled by this repository's transpiler
(`obc`). From the repository root:

```
make all                      # builds obc (and the oberon IDE)
```

Then, from `examples/`:

```
../obc ostar.mod -o ostar     # or just: make ostar
./ostar                       # start with an empty, unnamed buffer
./ostar mychapter.txt         # or open/create a specific file
```

There is no in-app "Open File" dialog for starting a brand-new editing
session — pass the filename on the command line, the way you'd invoke `vi`
or `nano`. (Once inside OStar you *can* pull another file's contents into
the current buffer with `^KR`, and project mode lets you flip between
several already-registered files — see Part 3.)

### Requirements

- A terminal that OStar's `TUI` layer supports (256-color xterm-compatible
  is assumed for the WordPerfect-blue theme).
- `hunspell` on your `PATH` if you want spell checking — it's invoked as an
  external process (`^OS` runs it; without the binary installed, spell
  check silently finds nothing to flag).
- A writable `$TMPDIR` (or `/tmp`) for spell-check scratch files, and
  `$HOME/.config/ostar/personal.txt` for your persisted personal dictionary.

---

## Part 2 — Tutorial

This tutorial walks through a first session: writing a short piece,
marking and moving text, searching, checking spelling and style, and
finally exporting a manuscript. Chords are written `^X` for Ctrl+X, and
`^K S` means "press `^K`, release, then press `S`" (case doesn't matter for
the letter).

### 1. Start OStar and look around

```
./ostar draft.txt
```

You'll see a brief splash screen (press any key to dismiss it), then the
editor: a full-screen text area over a status line. The status line's left
side shows the filename, a `*` if there are unsaved changes, and the
cursor's line/column (`L:1 C:1`); the right side shows transient status
messages and, while a prefix is held, which prefix menu is active.

By default `helpLevel` is 1, so pressing a prefix key (`^K`, `^Q`, `^O`, or
`^P`) pops up a small boxed menu of that prefix's commands in the
lower-left corner — a built-in cheat sheet. Try it now:

- Press `^K` — a "Block & File" menu appears listing save, block, and quit
  commands.
- Press `Escape` (or just continue with a letter) to dismiss it.

Press `F1` at any time for the **full** command palette — every chord in
the program, scrollable with the arrow keys, closed with `Escape` or `F1`
again.

### 2. Type and move around

Just type — printable characters insert at the cursor, same as any editor.
Enter (`^KEnter`) splits the line; the diamond keys move the cursor:

| Chord | Moves |
|---|---|
| `^E` / `^X` | up / down one line |
| `^S` / `^D` | left / right one character |
| `^A` / `^F` | left / right one **word** |
| `^W` / `^Z` | scroll the view up / down without moving the cursor off-screen |
| `^R` / `^C` | page up / down |

Arrow keys, Home/End, Ctrl+Left/Right (word), Ctrl+Home/End (doc
start/end), Page Up/Down, and the mouse (click to place the cursor, wheel
to scroll) all work too — use whichever you find natural.

Two more useful jumps, both under the `^Q` (Quick) prefix:

- `^Q ,` and `^Q .` — back/forward one sentence.
- `^Q [` and `^Q ]` — back/forward one paragraph.
- `^Q O` — jump to the next Markdown-style heading (a line starting with
  `#`) — handy once you start structuring a manuscript that way (see §6).
- `^Q P` — jump back to your previous cursor position (set automatically
  by the big jumps like doc-start/end, search, or heading navigation).

Made a mistake? `^U` undoes the last edit — up to 400 steps are kept, and
undo restores both the text and the cursor position at the time of the
edit.

### 3. Delete, and get it back

- `^G` deletes the character under the cursor; `^H` (Backspace) deletes the
  one before it.
- `^T` deletes the rest of the current word.
- `^Y` deletes the **whole current line** — and stashes it in the kill
  ring.
- `^Q Y` deletes from the cursor to the end of the line (no kill ring).
- `^N` inserts a blank line before the cursor.

`^Y` is the easiest way to see the kill ring in action: delete a line with
`^Y`, move the cursor somewhere else, and press `^K P` ("put") to paste it
back. Every block/line delete or copy pushes onto an 8-entry ring, so a few
recent kills stay recoverable.

### 4. Mark a block and move it

Blocks are how you cut/copy/move more than one line at a time:

1. Put the cursor at the start of the text you want, press `^K B` (mark
   **b**egin).
2. Move to the end of the selection, press `^K K` (mark end — historically
   "K" for the second `^K` letter, not a new prefix).
3. The marked region is now highlighted. Move the cursor to where you want
   it, then:
   - `^K C` — **copy** the block to the cursor.
   - `^K V` — **move** the block to the cursor (deletes it from the
     original spot).
   - `^K Y` — **delete** the block outright (goes to the kill ring too).
   - `^K H` — hide the highlight / clear the marks without touching the text.
4. `^Q B` / `^Q K` jump the cursor straight to the block's begin/end marker
   — useful once you've scrolled away from it.

### 5. Find and replace

- `^Q F` starts an **incremental** search: type, and the cursor jumps live
  to the first match as you type each character; Backspace shortens the
  search and re-searches. Enter accepts the current match and returns to
  normal editing; Escape cancels.
- `^L` repeats the last search forward (find-next) without reopening the
  prompt.
- `^Q A` is find **and replace**: type the search text and press Enter,
  then type the replacement and press Enter. OStar jumps to the first
  match and asks, per match:

  ```
  REPLACE? (Y/N/A/Esc)
  ```

  - `Y` — replace this one and jump to the next match.
  - `N` — skip this one, jump to the next.
  - `A` — replace this **and every remaining match** with no more asking.
  - `Esc` — stop, leaving anything already replaced as-is.

### 6. Structure a manuscript: headings and notes

OStar recognizes two line-leading conventions that several features build
on:

- A line starting with `#` is a **heading**. One `#` marks a chapter break;
  more `#`s (`##`, `###`, …) mark nested sub-headings. `^Q O` jumps to the
  next heading, `^Q H` opens a scrollable **outline panel** listing every
  heading in the document — arrow keys to move, Enter to jump there,
  Escape to close.
- A line starting with `..` is a **note** — an aside meant for you, not
  the reader. `^Q M` / `^Q U` jump forward/back between note lines. Notes
  are automatically stripped out of both the RTF export (§8) and the clean
  text export.

Try adding a heading and a note to your draft:

```
# Chapter One

This is the opening paragraph.

.. remember to check this date against the outline
```

Then press `^Q H` to see it appear in the outline panel.

### 7. Word wrap, overtype, and the on-screen extras (`^O`)

`^O` is the "Onscreen" prefix — display and editing-mode toggles rather
than document edits:

- `^O W` — toggle soft word wrap (on by default, margin column 72; long
  lines simply wrap visually on screen without inserting real newlines).
  `^O R` lets you type a new wrap-margin column.
- `^V` — toggle insert/overtype mode (typed characters overwrite instead of
  push text right); `^O V` does the same from inside the `^O` menu.
- `^O B` — cycle the color theme: WordPerfect blue → WordStar black →
  terminal default → back to blue.
- `^O H` — cycle help verbosity: clean screen → prefix menus shown →
  menus plus extra hints.
- `^O T` — typewriter-style scrolling (keeps the cursor vertically
  centered as you type, instead of scrolling only at the screen edge).
- `^O C` — word count: shows word and line counts in the status line.
- `^O F` — focus mode (dims everything outside the current paragraph, to
  cut down on visual distraction while drafting).

### 8. Spell check

1. Press `^O S` to turn spell check on. OStar collects every distinct word
   in the document, shells out to `hunspell -l`, and marks anything it
   flags in bright red (as long as `hunspell` is on your `PATH`).
2. `^Q N` jumps the cursor to the next misspelling.
3. If a flagged word is actually fine (a name, a term of art), put the
   cursor on it and press `^O A` to add it to your **personal dictionary**
   (`~/.config/ostar/personal.txt`, persisted across sessions and shared
   by every document you edit).
4. `^O S` again turns it off.

All-caps words and words containing digits are never checked (acronyms,
measurements, etc. are assumed intentional).

### 9. Style check

`^O L` toggles a second, independent pass over the prose that flags four
common weaknesses of a first draft, each underlined in its own color:

- **`-ly` adverbs** (*quickly*, *suddenly*) — a short exclude-list keeps
  real nouns/verbs like *family* or *rely* from being flagged.
- **Filler / hedge words** — intensifiers (*very*, *really*, *totally*)
  and a set of "telling not showing" verbs (*realized*, *noticed*,
  *seemed*, *felt*, …).
- **Passive voice** — a form of *to be* or *get* followed by a past
  participle (a small exclusion list keeps plain adjectives like *tired*
  or *married* from tripping it).
- **Overlong sentences** — any sentence running 30 words or more.

`^Q I` jumps the cursor to the next flagged issue; the status line names
the kind of issue under the cursor (`-ly adverb`, `filler word`, `passive
voice`, `long sentence`) whenever the cursor sits on one.

### 10. Save your work

- `^K D` (or `^K S`) saves. If the buffer has no filename yet, you're
  prompted for one first.
- `^K X` saves and exits in one step.
- `^K Q` quits; if there are unsaved changes you'll be asked
  `Quit without saving? (Y/N)` — answer `Y` to discard them, anything else
  to cancel and stay in the editor.
- `^K N` writes a timestamped backup snapshot alongside the file
  (`draft.20260915-143000.bak`) without altering your normal save.

### 11. Export a manuscript

Two export commands turn your working file into a deliverable, both
derived from the current filename (`draft.txt` → `draft.rtf` /
`draft.txt`… careful with extensions, see below):

- `^K M` — **RTF manuscript export**. Produces a standard-manuscript-format
  `.rtf`: 12pt Times New Roman, double-spaced, one-inch margins,
  first-line paragraph indents, a page break and nine blank lines before
  each chapter heading (level-1 `#`), bold body-paragraph sub-headings for
  deeper heading levels, `*italic*` and `**bold**` markup rendered as real
  emphasis, and "smart" typography (curly quotes, em dashes from `--`,
  ellipses from `...`). Note lines (`..`) and blank lines are dropped —
  paragraph spacing comes from the first-line indent, not blank lines.
- `^K E` — **clean export**. Writes a plain `.txt` copy with note lines
  stripped, everything else left as-is — good for sending a quick draft to
  someone who doesn't want your margin notes.

Both report the path they wrote to in the status line.

### 12. Where to go next

That covers a full single-document session. If you're working on
something with multiple files — a novel with one file per chapter, a
report with one file per section — read Part 3 on OStar's project system,
then use Part 4 as your day-to-day command reference.

---

## Part 3 — Working with multiple files (Projects)

A **project** is a small manifest file, extension `.ostarproj`, that lists
the paths of the documents that belong together — one path per line, plain
text, no other syntax. All project commands live under the `^P` prefix.

### Creating and populating a project

- `^P N` — create a new project. You're prompted for a project name; the
  manifest is written to `<name>.ostarproj` in the current directory. If a
  file is already open, it becomes the project's first document
  automatically.
- `^P A` — add the **currently open** file to the open project (the file
  must already be saved — save it first with `^K D` if needed).
- `^P R` — remove the currently open file from the project's manifest
  (does not delete the file itself).
- `^P L` — list the project's documents in the status line, with the
  currently open one shown in `[brackets]`.
- `^P P` — open an *existing* `.ostarproj` file, loading its document list.

Every add/remove immediately rewrites the manifest file, so the project
stays in sync on disk without an explicit "save project" step.

### Moving between documents

- `^P X` / `^P E` — switch to the next / previous document in the project.
  If the current file has unsaved changes, OStar saves it first
  automatically before switching (a failed save cancels the switch, so you
  never silently lose edits).
- `^P B` — toggle the **binder**: a centered popup (like PerfectStar's)
  listing every document in the project, with the currently open one
  marked. The popup opens straight into navigation:
  - Up/Down (or `^E`/`^X`) move the highlighted entry.
  - Enter opens the highlighted document and closes the popup.
  - Escape closes the popup without changing documents.

### Searching and compiling across the whole project

- `^P S` — **project-wide find**: searches every document listed in the
  manifest (not just the open one) for a string you type, and reports
  matches (with file and line) so you can jump to them.
- `^P K` — **compile to RTF**: concatenates every document in the project,
  in manifest order, through the same manuscript-format renderer as `^K M`
  (chapter breaks, smart typography, etc.), producing one combined `.rtf`.
  This is the "build the whole manuscript" command — write each chapter as
  its own file during drafting, then compile the finished book in one
  shot.
- `^P T` — the same idea, but compiles to a single clean, note-stripped
  plain-text file instead of RTF.

### Outline panel

`^Q H` (mentioned in the tutorial) works the same whether or not a project
is open — it always lists the headings of the **current document only**.
For a project-wide table of contents, rely on the heading (`#`) convention
being consistent across chapter files and use the binder plus per-file
outlines together.

---

## Part 4 — Command Reference

Chords are grouped by prefix, matching OStar's own `F1` palette (76
entries) and the `^O`-menu help boxes. `^X` means hold Ctrl and press X;
`^K X` means press `^K` then, after releasing Ctrl, press X (X is
case-insensitive).

### Cursor movement

| Chord | Action |
|---|---|
| `^E` | Cursor up |
| `^X` | Cursor down |
| `^S` | Cursor left |
| `^D` | Cursor right |
| `^A` | Word left |
| `^F` | Word right |
| `^W` | Scroll view up |
| `^Z` | Scroll view down |
| `^R` | Page up |
| `^C` | Page down |
| Arrows, Home, End, Page Up/Down | Same as above, conventional bindings |
| Ctrl+Left / Ctrl+Right | Word left / right |
| Ctrl+Home / Ctrl+End | Document start / end |
| Mouse click | Place cursor at clicked position |
| Mouse wheel | Scroll up / down |

### `^Q` — Quick movement, search, and misc.

| Chord | Action |
|---|---|
| `^Q S` | Line start |
| `^Q D` | Line end |
| `^Q E` | Screen top |
| `^Q X` | Screen bottom |
| `^Q R` | Document start |
| `^Q C` | Document end |
| `^Q F` | Find (incremental) |
| `^Q A` | Find & replace |
| `^Q Y` | Delete to end of line |
| `^Q P` | Jump to previous cursor position |
| `^Q B` | Jump to block-begin marker |
| `^Q K` | Jump to block-end marker |
| `^Q ,` | Sentence back |
| `^Q .` | Sentence forward |
| `^Q [` | Paragraph back |
| `^Q ]` | Paragraph forward |
| `^Q O` | Next heading (line starting with `#`) |
| `^Q G` | Transpose characters (swap with the one to the left) |
| `^Q T` | Transpose words |
| `^Q N` | Next misspelling (requires spell check on, `^O S`) |
| `^Q I` | Next style issue (requires style check on, `^O L`) |
| `^Q M` | Next comment/note line (starts with `..`) |
| `^Q U` | Previous comment/note line |
| `^Q H` | Open the outline panel |

`^L` (no prefix) repeats the last `^Q F` search — "find next."

### `^K` — Block & File

| Chord | Action |
|---|---|
| `^K B` | Mark block begin |
| `^K K` | Mark block end |
| `^K C` | Copy marked block to cursor |
| `^K V` | Move marked block to cursor |
| `^K Y` | Delete marked block |
| `^K H` | Hide/clear block marks |
| `^K P` | Put (paste) the last kill-ring entry at the cursor |
| `^K D`, `^K S` | Save (prompts for a filename if none yet) |
| `^K X` | Save and quit |
| `^K Q` | Quit (confirms if there are unsaved changes) |
| `^K W` | Write the marked block to a new file |
| `^K R` | Read a file's contents into the buffer at the cursor |
| `^K M` | Export RTF manuscript |
| `^K E` | Clean export (notes stripped, plain `.txt`) |
| `^K N` | Save a timestamped `.bak` snapshot |

### `^O` — Onscreen (display and mode toggles)

| Chord | Action |
|---|---|
| `^O B` | Cycle color theme (WordPerfect blue / WordStar black / terminal default) |
| `^O H` | Cycle help level (clean / menus / menus + hints) |
| `^O W` | Toggle word wrap |
| `^O R` | Set the wrap margin column |
| `^O T` | Toggle typewriter-style scrolling |
| `^O V` | Toggle insert/overtype (same as `^V`) |
| `^O S` | Toggle spell check |
| `^O A` | Add the word under the cursor to your personal dictionary |
| `^O L` | Toggle style check |
| `^O C` | Show word and line count |
| `^O F` | Toggle focus mode |

### `^P` — Project

| Chord | Action |
|---|---|
| `^P N` | New project (prompts for a name → `<name>.ostarproj`) |
| `^P P` | Open an existing `.ostarproj` file |
| `^P A` | Add the current file to the open project |
| `^P R` | Remove the current file from the project |
| `^P E` | Previous document in the project |
| `^P X` | Next document in the project |
| `^P L` | List the project's documents |
| `^P K` | Compile all project documents to one RTF file |
| `^P T` | Compile all project documents to one clean text file |
| `^P S` | Find a string across every document in the project |
| `^P B` | Toggle the binder popup |

### Direct editing (no prefix)

| Chord | Action |
|---|---|
| `^G` | Delete character under cursor |
| `^H` (Backspace) | Delete character before cursor |
| `^T` | Delete word to the right |
| `^Y` | Delete current line (kept in the kill ring) |
| `^N` | Insert a blank line before the cursor |
| `^U` | Undo (up to 400 steps) |
| `^V` | Toggle insert / overtype |
| Enter | Split the line at the cursor |
| Tab | Insert a tab stop |
| Del | Delete character under cursor (same as `^G`) |

### Other

| Chord | Action |
|---|---|
| `F1` | Open the command palette (the full key list, scrollable) — press again or `Esc` to close |
| `Esc` | Cancel the current prompt/search/palette/panel |

### Binder popup keys (active once `^P B` opens the binder)

| Key | Action |
|---|---|
| Up/Down or `^E`/`^X` | Move the highlighted document |
| Enter | Open the highlighted document and close the popup |
| Esc | Close the popup without changing documents |

### Outline-panel keys (active after `^Q H`)

| Key | Action |
|---|---|
| Up/Down or `^E`/`^X` | Move to the previous/next heading |
| Enter | Jump the cursor to the selected heading |
| Esc or F1 | Close the panel |

### Replace-confirmation keys (active mid `^Q A`)

| Key | Action |
|---|---|
| `Y` | Replace this match, move to the next |
| `N` | Skip this match, move to the next |
| `A` | Replace this and every remaining match |
| `Esc` | Stop, keeping replacements made so far |

### Document conventions OStar understands

| Convention | Effect |
|---|---|
| A line starting with `#` | Heading. Leading `#` count = nesting level; level 1 becomes a chapter break (page break + centered bold title) on RTF export. |
| A line starting with `..` | Note/comment line — visible while editing, navigable with `^Q M`/`^Q U`, stripped from both RTF and clean exports. |
| `*italic text*` | Rendered as italic in RTF export. |
| `**bold text**` | Rendered as bold in RTF export. |
| `--` | Rendered as an em dash in RTF export. |
| `...` | Rendered as an ellipsis character in RTF export. |
| Straight quotes (`"`, `'`) | Rendered as curly/smart quotes in RTF export. |

### Files OStar reads and writes on its own

| Path | Purpose |
|---|---|
| `<name>.ostarproj` | Project manifest — one document path per line |
| `<name>.rtf` | Output of `^K M` / `^P K` |
| `<name>.txt` | Output of `^K E` / `^P T` — derived by replacing the source file's extension. **Warning:** if your source file is already `.txt`, this overwrites it in place. |
| `<name>.YYYYMMDD-HHMMSS.bak` | Output of `^K N` |
| `~/.config/ostar/personal.txt` | Your persisted spell-check personal dictionary |
| `$TMPDIR` (or `/tmp`) | Scratch files used while shelling out to `hunspell` |

---

*This manual documents the behavior implemented in `examples/ostar.mod` as
of the commits tagged `feat(ostar)`/`fix(ostar)` through
"fix find/replace state bugs, binder mouse clicks, and off-screen cursor."*
