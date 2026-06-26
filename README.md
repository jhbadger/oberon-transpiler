# Oberon Transpiler

An Oberon-07 to C transpiler. Write programs in Oberon, compile them to native executables via C.

## Requirements

- GCC
- ncurses (for the IDE)
- POSIX system (macOS, Linux)

## Building

```
make all
```

This produces:
- `obc` — the command-line compiler
- `oberon` — a full-screen IDE with syntax highlighting, autocomplete, and run capability

## Usage

```
obc [options] <file.mod>
```

Options:

| Flag | Description |
|------|-------------|
| `-o outfile` | Name the output executable (defaults to the module name) |
| `--emit-c` | Keep generated `.c` files after compilation |
| `--warnings` | Enable unused-variable and other warnings |
| `--mod-path dir1:dir2` | Colon-separated search path for user modules (also `-I`) |

Example:
```
./obc examples/fact.mod -o fact
./fact
```

Multi-module example:
```
./obc --mod-path Modules examples/fastaStats.mod
```

## Language

Oberon-07 with extensions. Exported declarations are marked with `*`.

```oberon
MODULE fact;
IMPORT Out, In;

PROCEDURE Fact(n : INTEGER) : INTEGER;
BEGIN
    IF n = 0 THEN RETURN 1
    ELSE RETURN n * Fact(n - 1)
    END
END Fact;

VAR n : INTEGER;
BEGIN
    Out.String("n? "); In.Int(n);
    Out.Int(Fact(n)); Out.Ln
END fact.
```

### Supported features

- **Types** — `INTEGER`, `LONGINT`, `REAL`, `CHAR`, `BOOLEAN`, `BYTE`, `SET`, `STRING`; `ARRAY`, `RECORD`, `POINTER TO`
- **Control flow** — `IF/ELSIF/ELSE`, `WHILE`, `REPEAT/UNTIL`, `FOR`, `LOOP/EXIT`, `CASE`, `WITH`
- **Procedures** — value and `VAR` (reference) parameters, return types, nested procedures (closures over enclosing locals)
- **OOP** — record extension (`RECORD (Base)`), `IS` type test, `WITH` type guard, runtime type tags via `NEW`
- **Builtins** — `INC`, `DEC`, `NEW`, `HALT`, `ASSERT`, `ABS`, `ODD`, `ORD`, `CHR`, `LEN`, `COPY`, `FLT`, `ASR`, `LSL`, `ROR`, `PACK`, `UNPK`
- **Multi-module** — `IMPORT`, generated `.h` headers, `--mod-path` search path

## Standard Library

| Module | Purpose |
|--------|---------|
| `Out` | Formatted output (`String`, `Int`, `Real`, `Char`, `Ln`, `Fixed`) |
| `In` | Formatted input (`Int`, `Real`, `String`, `Line`, `Read`, `Char`) |
| `Math` | Functions and constants (`sqrt`, `sin`, `cos`, `exp`, `ln`, `floor`, `pi`, `e`, ...) |
| `Random` | Pseudo-random numbers (`Int(n)`, `Real()`) — seeded automatically |
| `Strings` | String operations (`Length`, `Copy`, `Append`, `Compare`, `Pos`, `Split`, `Trim`, ...) |
| `Files` | Binary file I/O with Rider cursor model (`Read*`, `Write*`, `ReadLine`, `ReadNum`, ...) |
| `Args` | Command-line arguments (`Count`, `Get`) |
| `Env` | Environment variable access (`Get`) |
| `OS` | Shell commands and filesystem (`Exec`, `Exit`, `GetCwd`, `ChDir`) |
| `Time` | Timestamps and sleep (`Now`, `Sleep`, `Format`) |
| `Terminal` | Raw terminal I/O, keyboard, mouse, colour, timing |
| `Graphics` | ANSI terminal graphics — text layer and 240×100 pixel buffer with drawing primitives |
| `Dict` | String-keyed hash table with iteration |
| `Zip` | Read-only ZIP archive access (stored and deflated entries) |

Full API reference: [stdlib.md](stdlib.md)

## User Modules

Reusable library modules live in `Modules/`. Pass `--mod-path Modules` to use them.

### Bioinformatics

| Module | Purpose |
|--------|---------|
| `BioAlpha` | Sequence alphabets — DNA, RNA, protein, IUPAC ambiguity |
| `BioSeq` | Biological sequence storage and manipulation |
| `BioIO` | FASTA/FASTQ file I/O (plain or `.gz`) |
| `BioAlign` | Pairwise sequence alignment (global, local, semi-global) |
| `BioAnnot` | Genomic interval annotation |
| `BioFM` | FM-index for fast exact-match search |
| `BioORF` | Open reading frame detection |
| `BioPDB` | PDB structure file I/O — atoms, models, secondary structure |
| `BioPattern` | Sequence pattern matching |
| `BioQGram` | Q-gram index for approximate matching |
| `BioStats` | Bioinformatics statistics |
| `BioSuffix` | Suffix array and BWT construction |
| `BioVCF` | VCF variant call format reader/writer |

### Data / analysis

| Module | Purpose |
|--------|---------|
| `DataFrame` | Tabular data — rows/columns, typed get/set, CSV load, iteration |
| `DBF` | dBASE/FoxPro `.dbf` file reader/writer |
| `SummarizedExperiment` | Multi-assay experiment container backed by `DataFrame` |
| `PCA` | Principal Component Analysis via power iteration with deflation |

### TUI / UI

| Module | Purpose |
|--------|---------|
| `TUI` | Double-buffered text UI framework (cells, boxes, events, modals) |
| `Widgets` | Standard TUI widgets — Label, Button, InputLine, ListBox, ScrollView |
| `Menu` | Retro dBASE-style text menus |
| `FileDialog` | Modal file-open dialog |
| `Editor` | Gap-buffer text editor component (C FFI) |
| `Help` | Context-sensitive help dialog (searches `stdlib.md`) |

### Graphics / misc

| Module | Purpose |
|--------|---------|
| `Raylib` | Game window, 2D/3D rendering, input, and audio (Raylib 4+) |
| `Sixel` | DEC Sixel high-resolution terminal graphics (640-wide pixel buffer) |
| `Turtle` | Turtle graphics on top of `Terminal` |
| `Base64` | Standard Base64 encode/decode |
| `Ollama` | REST client for a local Ollama LLM server |
| `NumberTheory` | Primality test, GCD/LCM |
| `Parallel` | Multi-core parallel loops via POSIX threads |
| `XHTML` | HTML/XHTML to plain-text converter, attribute extraction |

## Examples

### Core language

| File | Description |
|------|-------------|
| `examples/fact.mod` | Recursive factorial |
| `examples/fibonacci.mod` | Fibonacci via `FOR` loop |
| `examples/sieve.mod` | Sieve of Eratosthenes |
| `examples/nqueens.mod` | N-Queens solver (backtracking) |
| `examples/shapes.mod` | Record types, extension, `IS` type test, `WITH` guard |
| `examples/pets.mod` | Polymorphism via record extension and `WITH` |
| `examples/easter.mod` | Easter date computation (Computus algorithm) |
| `examples/namegenerator.mod` | Procedural name generator |
| `examples/zodiac.mod` | Chinese zodiac lookup |
| `examples/brazilian.mod` | Brazilian numbers (mathematical concept) |

### Terminal / graphics / simulation

| File | Description |
|------|-------------|
| `examples/sinewave.mod` | Animated sine wave in the terminal |
| `examples/plotrand.mod` | Random dot plot using the pixel buffer |
| `examples/smiley.mod` | Animated smiley face |
| `examples/mandelbrot.mod` | Mandelbrot fractal rendered in the pixel buffer |
| `examples/life.mod` | Conway's Game of Life (200×90 grid, real-time) |
| `examples/wator.mod` | Wa-Tor predator/prey ocean simulation |
| `examples/wireworld.mod` | Wireworld cellular automaton |
| `examples/immsim.mod` | Celada-Seiden immune system cellular automaton |

### Raylib (graphical)

| File | Description |
|------|-------------|
| `examples/invaders.mod` | Space Invaders — Raylib sprites, sound effects, wave progression |
| `examples/macpaint.mod` | Retro paint program in the spirit of the 1984 Mac original |
| `examples/piano.mod` | Two-octave piano (C4–C6) with Raylib synthesised tones |
| `examples/glbviewer.mod` | GLB/GLTF 3D model viewer with orbital camera |
| `examples/pdbviewer.mod` | Graphical PDB/CIF/SDF/XYZ molecular structure viewer |

### Games

| File | Description |
|------|-------------|
| `examples/snake.mod` | Snake — keyboard, growing tail, score |
| `examples/tetris.mod` | Tetris — all pieces, line clears, level progression |
| `examples/sudoku.mod` | Sudoku — puzzle generator and solver |
| `examples/minesweeper.mod` | Minesweeper — coloured grid, mouse support |
| `examples/slots.mod` | Slot machine |
| `examples/videopoker.mod` | Video poker — five-card draw, Jacks-or-Better payouts |
| `examples/blackjack.mod` | Blackjack — standard rules, dealer peek |
| `examples/klondike.mod` | Klondike solitaire — mouse-driven, draw-one |
| `examples/maze.mod` | First-person 3D wireframe maze with minimap |
| `examples/rogue.mod` | Roguelike dungeon crawl |
| `examples/BRErogue.mod` | Barbarians of the Ruined Earth dungeon crawl |
| `examples/bre_chargen.mod` | BRE character generator |
| `examples/chess.mod` | Chess — graphical board with self-contained engine |
| `examples/chessattack.mod` | Chess Attack — 5×6 chess variant |
| `examples/anticlerical.mod` | Anti-Clerical Chess — 6×6 Los Alamos variant (no bishops) |
| `examples/minichess.mod` | Gardner's Minichess — 5×5 |
| `examples/baduk9.mod` | 9×9 Go — human vs computer |
| `examples/xiangqi.mod` | Xiangqi (Chinese Chess) — TUI with engine |
| `examples/chainmail.mod` | Chainmail medieval miniatures wargame (Gygax & Perren, 1971) |
| `examples/swords.mod` | Swords & Spells fantastic miniatures rules (Gygax, 1976) |
| `examples/wargame.mod` | One Hour Wargames (Neil Thomas rules) |

### Text / tools

| File | Description |
|------|-------------|
| `examples/adventure.mod` | Two-word text adventure engine |
| `examples/zmachine.mod` | Z-machine interpreter — runs Infocom/Inform story files (`.z3`–`.z5`) |
| `examples/epub.mod` | Terminal EPUB reader |
| `examples/sheet.mod` | Terminal spreadsheet backed by `DataFrame` |
| `examples/ide.mod` | Multi-window full-screen source editor (TUI/Widgets) |
| `examples/speedscript.mod` | Recreation of 1980s word processor |
| `examples/chatbot.mod` | Keyword-driven chatbot (personality loaded from config file) |
| `examples/ollamachat.mod` | Interactive chat client for a local Ollama server |
| `examples/obemacs.mod` | Emacs-style editor implementing core GNU Emacs tutorial commands |
| `examples/newickview.mod` | Terminal phylogenetic tree viewer (cladogram and phylogram) |


### Bioinformatics / data science

| File | Description |
|------|-------------|
| `examples/seqSummary.mod` | Sequence length stats from FASTA/FASTQ files |
| `examples/seqGrep.mod` | Pattern search across FASTA/FASTQ files (plain or `.gz`) |
| `examples/alignedit.mod` | FASTA alignment editor with pairwise-align integration |
| `examples/DeBruijn.mod` | De Bruijn graph assembler for short reads |
| `examples/CodonAlign.mod` | Per-orthogroup nucleotide alignment with codon annotation |
| `examples/OrthoAlign.mod` | Concatenated supermatrix alignment from ortholog groups |
| `examples/OrthoFind.mod` | Reciprocal best hit ortholog finder for protein FASTA files |
| `examples/MSAIdentity.mod` | Per-column identity scores for multiple sequence alignments |
| `examples/PeptideContext.mod` | Extract genomic neighbourhood context for protein IDs |
| `examples/pdbview.mod` | Terminal PDB structure viewer |
| `examples/SeqBlast.mod` | BLAST-like local alignment search with gapped extension |
| `examples/SeqHMM.mod` | Profile HMM builder and sequence-database searcher |
| `examples/EnzymeExplorer.mod` | Interactive enzyme database browser |

## IDE

Launch with `./oberon [file.mod]`. The IDE is a Turbo Pascal-style full-screen editor.

| Key | Action |
|-----|--------|
| F1 | Help (context-sensitive, reads `stdlib.md`) |
| F2 | Save |
| F3 | Open |
| F7 | Find Again |
| F8 | Compile (without running) |
| F9 | Compile and Run |
| Ctrl-F | Find |
| Ctrl-H | Find & Replace |
| Ctrl-K | Autocomplete (keywords + identifiers + `Module.Proc` members) |
| Ctrl-L | Go to Line |
| Ctrl-U | Undo |
| Ctrl-W | Close window |
| Ctrl-Q | Quit |
| Alt-1..9 | Switch to window 1–9 (creation order) |

Compile errors highlight the offending line in red with an inline annotation. The Window menu also has Tile and Cascade for arranging multiple editor windows.

## How It Works

1. Lex and parse the `.mod` file into an AST
2. Resolve imports, recursively compiling user modules first
3. Emit `.c` and `.h` files for each module
4. Link everything with `gcc`

Built-in modules are inlined directly into the generated C — no external runtime dependencies (except `-lncurses` for Terminal/Graphics programs, and `-lz` for Zip).

## License

MIT — see [LICENSE](LICENSE)
