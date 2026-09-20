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
| Movement | Diamond keys, word/sentence/paragraph/heading jumps, "previous position" jump (`^QP`), ten numbered bookmarks (`^K0`–`9` set, `^Q0`–`9` jump), screen top/bottom, doc start/end |
| Search | Incremental find (`^QF`), find & replace with per-match Y/N/A confirmation (`^QA`), find-next (`^L`) |
| Word wrap | Soft (visual) wrap at a configurable column, on by default at 72 |
| Spell check | hunspell-backed; flags misspellings in the theme's error color, jump between them, maintain a personal dictionary |
| Dictionary & thesaurus | `^OY` looks up the word under the cursor — synonyms and a short definition in a dismissable popup, from an offline, replaceable word list |
| Style check | Flags `-ly` adverbs, filler/hedge words, passive voice, and overlong sentences, each in its own color |
| Projects | Group several files into a `.ostarproj` manifest; binder popup with per-doc synopses (`^PI`/`^PY`) and note/manuscript roles (`^PM`), outline panel, project-wide search and replace (`^PS`/`^PW`), and "compile" (concatenate all non-note docs to one RTF, EPUB, DOCX, or text file) |
| Export | Manuscript-format RTF (`^KM`), plain HTML (`^KJ`), DOCX (`^KI`), a notes-stripped clean `.txt` (`^KE`), and timestamped backup snapshots (`^KN`, browsable with `^KO` and diffable against the live document by pressing `D` there) — RTF/HTML/DOCX rendering all live in the shared `Modules/Markdown.mod` |
| Other window | A second, independently-scrolled pane (`^OK`) for reference material or a companion file, with block-copy (`^KA`) and jump-to-source (`^QV`) between the two |
| Accented letters | `^^` compose: a letter straight after it takes a circumflex (`^^c` = ĉ — Esperanto's hats in two keystrokes), or an accent selector first picks another of fourteen accents (`^^:o` = ö, `^^'e` = é, `^^(u` = ŭ) |
| Look & feel | Three themes (WordPerfect blue, WordStar black, terminal default), three help-verbosity levels, focus mode, typewriter scrolling, reveal codes (`^OD`) |

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
- For `^O Y` dictionary/thesaurus lookup, an `ostar-thesaurus.txt` findable
  via one of the three paths in §10 (a `~/.config/ostar/thesaurus.txt`
  override, the current directory, or next to the binary — the copy in
  `examples/` covers the latter two when run from there or installed
  alongside it) — without one, `^O Y` just reports the resource unavailable.

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

For places you want to return to deliberately rather than just "the last
big jump," use the ten numbered bookmarks: `^K` then a digit `0`–`9` marks
the cursor's current position as that bookmark; `^Q` then the same digit
jumps straight back to it from anywhere in the document (jumping pushes
your prior position, so `^Q P` still gets you back if you change your
mind). Bookmarks are cleared when you switch to a different document —
they mark a place in *this* file, not a location in general.

Made a mistake? `^U` undoes the last edit — up to 400 steps are kept, and
undo restores both the text and the cursor position at the time of the
edit.

For letters your keyboard doesn't have, `^^` starts a compose sequence: a
letter right after it takes a circumflex (`^^c` gives ĉ), and an accent
selector before the letter picks a different accent (`^^:o` gives ö, `^^'e`
gives é). A popup lists all fourteen accents while the sequence is pending;
the full table is in Part 4.

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
  are automatically stripped out of both the RTF export (§12) and the clean
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

### 10. Dictionary & thesaurus lookup

Put the cursor on any word and press `^O Y` to look up synonyms and a short
definition in a dismissable popup — press any key (`Esc`, `Enter`, anything)
to close it and keep writing.

This is a small, offline word list (ported from a companion project,
*PerfectStar 2k*), not a full dictionary — a miss just reports "No
dictionary entry for '\<word\>'" in the status line rather than an error.
OStar looks for the word list in this order, using the first one it finds:

1. `~/.config/ostar/thesaurus.txt` — a personal override.
2. `ostar-thesaurus.txt` in the **current directory**.
3. `ostar-thesaurus.txt` next to the **running binary** (wherever `ostar`
   itself lives, resolved the same way as `Help.mod`'s stdlib lookup) — so
   the bundled starter list is still found even when you launch OStar from
   elsewhere, e.g. editing a manuscript in its own directory with an
   installed or symlinked `ostar`.

If none of the three is found, `^O Y` reports "Thesaurus unavailable"
instead of doing nothing silently. To use a bigger or different word list,
write one in the same tab-separated format
(`word<TAB>synonym,synonym,...<TAB>definition`, `#`-comments and blank
lines ignored) at `~/.config/ostar/thesaurus.txt` — that path always takes
priority over the other two.

### 11. Save your work

- `^K D` (or `^K S`) saves. If the buffer has no filename yet, you're
  prompted for one first.
- `^K X` saves and exits in one step.
- `^K Q` quits; if there are unsaved changes you'll be asked
  `Quit without saving? (Y/N)` — answer `Y` to discard them, anything else
  to cancel and stay in the editor.
- `^K N` writes a timestamped backup snapshot alongside the file
  (`draft.20260915-143000.bak`) without altering your normal save.
- `^K O` opens a scrollable list of every snapshot `^K N` has taken of the
  current file. Up/Down to pick one, then:
  - `Enter` — load that snapshot's content into the buffer (marked dirty;
    `^K D` to actually overwrite the file with it).
  - `D` — **diff** the selected snapshot against your current document: a
    unified-style view where unchanged lines are plain, lines only in the
    snapshot (removed since then) are prefixed `-` in red, and lines only
    in the current buffer (added since then) are prefixed `+` in green.
    Up/Down scrolls, `Enter` jumps the cursor to that line in the live
    document (there's nothing to jump to for a `-` line, since it isn't in
    the current buffer — OStar says so rather than moving the cursor),
    and `Esc` returns to the snapshot list. Diffing is capped at 2000
    lines per side.
  - `Esc` — close without restoring or diffing anything.

### 12. Export a manuscript

Five export commands turn your working file into a deliverable, all
derived from the current filename (`draft.txt` → `draft.rtf` /
`draft.html` / `draft.docx` / `draft.epub` / `draft.txt`… careful with
extensions, see below):

- `^K M` — **RTF manuscript export**. Produces a standard-manuscript-format
  `.rtf`: 12pt Times New Roman, double-spaced, one-inch margins,
  first-line paragraph indents, a page break and nine blank lines before
  each chapter heading (level-1 `#`), bold body-paragraph sub-headings for
  deeper heading levels, `*italic*` and `**bold**` markup rendered as real
  emphasis, and "smart" typography (curly quotes, em dashes from `--`,
  ellipses from `...`). Note lines (`..`) and blank lines are dropped —
  paragraph spacing comes from the first-line indent, not blank lines.
  (Rendered by `Modules/Markdown.mod`'s manuscript-mode RTF renderer,
  shared with `^P K`'s project-wide compile.)
- `^K J` — **HTML export**. Plain (not manuscript-format, single-spaced)
  HTML via the same `Modules/Markdown.mod` used by the `plume` markdown
  converter: headings, `*italic*`/`**bold**` emphasis, `` `code` ``,
  `[links](url)`, lists, tables, blockquotes, and fenced code blocks all
  render as real HTML tags, with a small embedded stylesheet. Note lines
  (`..`) are stripped first, same convention as `^K M`/`^K E`.
- `^K I` — **DOCX export**. A real `.docx` a word processor can open
  directly — headings (any level, via Word's built-in Heading1–6 paragraph
  styles), `*italic*`/`**bold**`/`` `code` `` runs, and the same smart
  typography as RTF export. Deliberately smaller than the HTML renderer's
  feature set (no lists/tables/links/images), matching PerfectStar 2k's
  own DOCX export — see Markdown.mod's Docx* procedures. Note lines are
  stripped, same convention as the others.
- `^K G` — **EPUB export**. A real `.epub` e-readers can open, with one
  chapter file per level-1 (`#`) heading and a linked table of contents —
  see Markdown.mod's Epub* procedures for the details.
- `^K E` — **clean export**. Writes a plain `.txt` copy with note lines
  stripped, everything else left as-is — good for sending a quick draft to
  someone who doesn't want your margin notes.

All five report the path they wrote to in the status line. DOCX and EPUB
are real ZIP archives (via `Modules/ZipWriter.mod`), assembled from
temp files that are cleaned up afterward whether the export succeeds or
fails partway through.

### 13. Where to go next

That covers a full single-document session. If you're working on
something with multiple files — a novel with one file per chapter, a
report with one file per section — read Part 3 on OStar's project system,
then use Part 4 as your day-to-day command reference.

---

## Part 3 — Working with multiple files (Projects)

A **project** is a small manifest file, extension `.ostarproj`, that lists
the paths of the documents that belong together — one path per line, plain
text. A line prefixed with `!` marks that document as a **note** rather
than manuscript (`^P M`, see below); everything else about the format is
unchanged. All project commands live under the `^P` prefix.

### Creating and populating a project

- `^P N` — create a new project. You're prompted for a project name; the
  manifest is written to `<name>.ostarproj` in the current directory (a
  bare name like `fred` becomes `fred.ostarproj` automatically — no need
  to type the extension). If a file is already open, it becomes the
  project's first document automatically.
- `^P A` — add the **currently open** file to the open project (the file
  must already be saved — save it first with `^K D` if needed).
- `^P R` — remove the currently open file from the project's manifest
  (does not delete the file itself).
- `^P L` — list the project's documents in the status line, with the
  currently open one shown in `[brackets]`.
- `^P P` — open an *existing* `.ostarproj` file, loading its document list
  (same bare-name convenience as `^P N`).

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
  - `^P` re-enters the Project prefix without leaving the binder, so
    `^P I`, `^P Y`, `^P M`, and `^P V` (all below) act on whichever entry
    is highlighted.

### Synopses and document roles

- `^P I` — edit the highlighted (or, outside the binder, the current)
  document's one-line **synopsis** — a short blurb describing what the
  chapter covers. It's stored next to the document as `<file>.synopsis`,
  not in the manifest, so it survives re-ordering the project.
- `^P Y` — toggle whether the binder shows each document's synopsis as a
  dimmed second line under its title. Off by default to keep the binder
  compact.
- `^P M` — toggle the highlighted (or current) document between
  **manuscript** and **note**. A note is marked `[note]` in the binder
  and skipped by `^P K` / `^P T` compile — useful for a synopsis,
  character sheet, or outline file you keep in the project but don't
  want in the finished book. (This is a whole-document flag, distinct
  from the `..`-prefixed note *lines* `^Q M`/`^Q U` navigate within a
  single document — see "Document conventions" below.)

### Annotations

- `^P C` — insert a `..`-prefixed comment line above the cursor (you're
  prompted for the text). It's the same convention `^Q M`/`^Q U`
  navigate between and `^K E`/project compile strip out — `^P C` is
  just a quick way to drop one in without typing `.. ` yourself.

### Searching and replacing across the whole project

- `^P S` — **project-wide find**: searches every document listed in the
  manifest (not just the open one) for a string you type, and reports
  matches (with file and line) so you can jump to them.
- `^P W` — **project-wide replace**: prompts for a find string and a
  replacement, then applies it to every occurrence in every document in
  the project (not a per-match confirmation like `^Q A` — it's a
  find-and-replace-all across the whole manifest). Each file is loaded,
  fully replaced, and saved in turn; you end up back on the document you
  started from. Use this for a name change or terminology fix that spans
  chapters.

### Compiling the project

- `^P K` — **compile to RTF**: concatenates every non-note document in
  the project, in manifest order, through the same manuscript-format
  renderer as `^K M` (chapter breaks, smart typography, etc.), producing
  one combined `.rtf`. This is the "build the whole manuscript"
  command — write each chapter as its own file during drafting, then
  compile the finished book in one shot.
- `^P T` — the same idea, but compiles to a single clean, note-stripped
  plain-text file instead of RTF.

### The other window

`^O K` opens (or switches focus between) a second, independently
scrolled pane below the main one — useful for glancing at another
chapter, a style sheet, or research notes without losing your place.

- `^O K` — if no other window is open, prompts for a file to open there
  (an existing document, or a new filename to start one); the main
  document keeps keyboard focus. Press it again to switch focus to the
  other pane, and again to switch back.
- `^K A` — copy the block marked *in the other window* into this one at
  the cursor (the reverse of the usual `^K C`, which only copies within
  the current document).
- `^Q V` — jump to wherever the marked block actually is: if it's marked
  in the current pane this is the same as `^Q B`/`^Q K`; if it's only
  marked in the other pane, focus switches there and the cursor lands on
  it.
- `^P O` — open the current document's free-form notes file
  (`<file>.notes`, distinct from the one-line `^P I` synopsis) in the
  other window — a scratch area beside your manuscript.
- `^P V` — from the binder, open the highlighted document in the other
  window instead of replacing the active one with `Enter`.
- **Esc** closes the other window, always landing you back on your
  original document regardless of which pane currently has focus.

Both panes redraw unwrapped while split (word wrap resumes once you
close the other window), and undo history isn't preserved across a
focus switch — each pane's undo stack starts fresh when it gains focus.

### Outline panel

`^Q H` (mentioned in the tutorial) works the same whether or not a project
is open — it always lists the headings of the **current document only**.
For a project-wide table of contents, rely on the heading (`#`) convention
being consistent across chapter files and use the binder plus per-file
outlines together.

---

## Part 4 — Command Reference

Chords are grouped by prefix, matching OStar's own `F1` palette (100
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
| `^Q V` | Jump to the marked block, wherever it is (this pane or the other window) |
| `^Q H` | Open the outline panel |
| `^Q 0`–`9` | Jump to numbered bookmark 0–9 |

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
| `^K J` | Export HTML |
| `^K I` | Export DOCX |
| `^K G` | Export EPUB |
| `^K E` | Clean export (notes stripped, plain `.txt`) |
| `^K N` | Save a timestamped `.bak` snapshot |
| `^K A` | Copy the block marked in the other window (`^O K`) here |
| `^K U` | Jump to the previously-marked block |
| `^K O` | Browse and restore (or diff, with `D`) this document's `^K N` snapshots |
| `^K 0`–`9` | Set numbered bookmark 0–9 at the cursor |

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
| `^O K` | Open/switch focus to the other window (Esc closes it) |
| `^O D` | Toggle reveal codes (markdown markers shown in inverse video) |
| `^O Y` | Look up the word under the cursor (dictionary/thesaurus popup) |

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
| `^P K` | Compile all non-note project documents to one RTF file |
| `^P G` | Compile all non-note project documents to one EPUB file |
| `^P D` | Compile all non-note project documents to one DOCX file |
| `^P T` | Compile all non-note project documents to one clean text file |
| `^P S` | Find a string across every document in the project |
| `^P W` | Replace a string across every document in the project |
| `^P B` | Toggle the binder popup |
| `^P I` | Edit the current (or binder-highlighted) doc's synopsis |
| `^P Y` | Toggle showing synopses in the binder |
| `^P M` | Toggle the current (or binder-highlighted) doc as a note |
| `^P C` | Insert a `..` comment line above the cursor |
| `^P O` | Open the current doc's notes file in the other window |
| `^P V` | From the binder, open the highlighted doc in the other window |

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

### `^^` — Accented letters (compose)

`^^` (Ctrl-^) opens a compose sequence. Whatever you type next decides what
happens:

* **A letter** gets a **circumflex**, because that is the accent `^^` names:
  `^^c` = ĉ, `^^g` = ĝ, `^^h` = ĥ, `^^j` = ĵ, `^^s` = ŝ. Esperanto's five
  hatted letters therefore cost two keystrokes each, with no accent selector
  at all. Its sixth special letter, ŭ, takes the breve: `^^(u`.
* **An accent selector**, then a letter, gets that accent instead: `^^:o` = ö,
  `^^'e` = é, `^^~n` = ñ, `^^,c` = ç.
* **`&` is a special case** — "ligature" rather than a diacritic — for the
  letters that don't compose from a base + accent mark at all: `^^&s` = ß
  (German eszett, the *ss* convention from X11 Compose; `^^&S` gives the rare
  capital ẞ), `^^&a` = æ, `^^&o` = œ.
* **Space** types the accent character itself, so `^^` then space inserts a
  plain `^`.
* **Esc** (or Backspace) abandons the sequence.

Compose works anywhere you type: in the document, in the `^QF` find string,
and at any filename or input prompt.

Ctrl-^ is awkward on some keyboard layouts, so **`^\` (Ctrl-\) is the same
key** — both open the sequence with the circumflex selected.

While a sequence is pending the status bar shows the chosen accent, and (at
help level 1 or 2) a popup lists every selector with live samples — the
sample letters are generated from the same table that does the composing, so
they always show exactly what you will get.

| Selector | Accent | Examples |
|---|---|---|
| `^` (or `>`) | circumflex | ĉ ĝ ĥ ĵ ŝ â ê î ô û ŵ ŷ |
| `:` (or `"`) | diaeresis / umlaut | ä ë ï ö ü ÿ |
| `'` | acute | á é í ó ú ý ć ń ś ź ĺ ŕ |
| `` ` `` | grave | à è ì ò ù |
| `~` | tilde | ã ñ õ ẽ ĩ ũ |
| `,` | cedilla | ç ş ţ ģ ķ ļ ņ ŗ |
| `<` | caron (háček) | č š ž ř ť ď ň ě ǧ |
| `(` (or `)`) | breve | ŭ ă ğ ĭ ĕ ŏ |
| `-` (or `_`) | macron | ā ē ī ō ū |
| `*` | ring above | å ů |
| `.` | dot above | ż ė ċ ġ |
| `;` | ogonek | ą ę į ų |
| `=` | double acute | ő ű |
| `/` | stroke | ø đ ł ħ ŧ |
| `&` | ligature | ß ẞ æ Æ œ Œ |

Capital letters work throughout: `^^C` = Ĉ, `^^:O` = Ö. A combination with no
precomposed Unicode character (`^^q`, say) inserts nothing and says so in the
status bar.

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
| `^P` | Re-enter the Project prefix — `^P I`/`^P Y`/`^P M`/`^P V` act on the highlighted document |
| Esc | Close the popup without changing documents |

### Snapshot browser keys (active after `^K O`)

| Key | Action |
|---|---|
| Up/Down or `^E`/`^X` | Move the highlighted snapshot |
| Enter | Load that snapshot's content into the current buffer (marked dirty — `^K D` to actually overwrite the file) and close |
| `D` | Diff the highlighted snapshot against the current document (opens the diff view, below) |
| Esc | Close without restoring anything |

### Diff view keys (active after `D` from the snapshot browser)

| Key | Action |
|---|---|
| Up/Down or `^E`/`^X` | Move the highlighted diff line |
| Enter | Jump the cursor to that line in the current document (no-op with a status message on a `-` line, which only exists in the snapshot) |
| Esc | Close and return to the snapshot browser |

### Lookup popup keys (active after `^O Y`)

| Key | Action |
|---|---|
| Any key | Close the popup and return to editing |

### Other window keys

| Chord | Action |
|---|---|
| `^O K` | Open the other window (prompts for a file), or switch focus to it |
| `^K A` | Copy the block marked in the other window into this one |
| `^Q V` | Jump to the marked block, switching focus if it's in the other window |
| `^P O` | Open this document's notes file (`<file>.notes`) in the other window |
| `^P V` | From the binder, open the highlighted document in the other window |
| Esc | Close the other window and return to a single pane |

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
| A line starting with `..` | Note/comment line — visible while editing, navigable with `^Q M`/`^Q U` (or inserted with `^P C`), stripped from both RTF and clean exports. |
| `*italic text*` | Rendered as italic in RTF export; shown in inverse video when reveal codes (`^O D`) is on. |
| `**bold text**` | Rendered as bold in RTF export; shown in inverse video when reveal codes is on. |
| `--` | Rendered as an em dash in RTF export. |
| `...` | Rendered as an ellipsis character in RTF export. |
| Straight quotes (`"`, `'`) | Rendered as curly/smart quotes in RTF export. |
| A project manifest line starting with `!` | That document is a **note** (`^P M`) — skipped by `^P K`/`^P T` compile. Whole-document flag, unrelated to the `..` line convention above. |

### Files OStar reads and writes on its own

| Path | Purpose |
|---|---|
| `<name>.ostarproj` | Project manifest — one document path per line, `!`-prefixed for a note doc |
| `<name>.rtf` | Output of `^K M` / `^P K` |
| `<name>.html` | Output of `^K J` |
| `<name>.docx` | Output of `^K I` / `^P D` |
| `<name>.epub` | Output of `^K G` / `^P G` |
| `<name>.txt` | Output of `^K E` / `^P T` — derived by replacing the source file's extension. **Warning:** if your source file is already `.txt`, this overwrites it in place. |
| `<name>.YYYYMMDD-HHMMSS.bak` | Output of `^K N`; browse/restore with `^K O` |
| `<file>.synopsis` | The document's one-line blurb, set with `^P I` |
| `<file>.notes` | The document's free-form notes, opened in the other window with `^P O` |
| `~/.config/ostar/personal.txt` | Your persisted spell-check personal dictionary |
| `~/.config/ostar/thesaurus.txt`, `./ostar-thesaurus.txt`, or `<exe dir>/ostar-thesaurus.txt` | Word list read by `^O Y`, first found wins (see §10 for the search order and format) |
| `$TMPDIR` (or `/tmp`) | Scratch files used while shelling out to `hunspell` |

---

*This manual documents the behavior implemented in `examples/ostar.mod` as
of the commits tagged `feat(ostar)`/`fix(ostar)`/`refactor(ostar)` through
"add DOCX export."*
