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

| Module | Purpose |
|--------|---------|
| `DataFrame` | Tabular data — rows/columns, typed get/set, CSV load, iteration |
| `FastaParser` | FASTA sequence file parser (bioinformatics) |
| `PCA` | Principal Component Analysis via power iteration with deflation |
| `XHTML` | HTML/XHTML to plain-text converter, attribute extraction |
| `MathUtils` | Sieve of Eratosthenes, prime tables |
| `NumberTheory` | Primality test, factorisation, GCD/LCM |
| `SummarizedExperiment` | Multi-assay experiment container backed by DataFrame |

## Examples

### Core language

| File | Description |
|------|-------------|
| `examples/fact.mod` | Recursive factorial |
| `examples/fibonacci.mod` | Fibonacci via `FOR` loop |
| `examples/sieve.mod` | Sieve of Eratosthenes |
| `examples/records.mod` | `RECORD` types and extension |
| `examples/pets.mod` | Polymorphism via record extension and `WITH` |
| `examples/array.mod` | Array operations |
| `examples/types.mod` | Type system tour |
| `examples/easter.mod` | Easter date computation (Computus algorithm) |

### Terminal / graphics

| File | Description |
|------|-------------|
| `examples/sinewave.mod` | Animated sine wave in the terminal |
| `examples/plotrand.mod` | Random dot plot using the pixel buffer |
| `examples/smiley.mod` | Animated smiley face |
| `examples/mandelbrot.mod` | Mandelbrot fractal rendered in the pixel buffer |
| `examples/life.mod` | Conway's Game of Life (200×90 grid, real-time) |

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
| `examples/maze.mod` | First-person 3D wireframe maze with minimap |
| `examples/rogue.mod` | Roguelike dungeon crawl |
| `examples/BRErogue.mod` | Barbarians of the Ruined Earth dungeon crawl |

### Text / tools

| File | Description |
|------|-------------|
| `examples/adventure.mod` | Two-word text adventure engine |
| `examples/zmachine.mod` | Z-machine interpreter — runs Infocom/Inform story files (`.z3`–`.z5`) |
| `examples/epub.mod` | Terminal EPUB reader |
| `examples/sheet.mod` | Terminal spreadsheet backed by `DataFrame` |
| `examples/edit.mod` | Full-screen text editor |
| `examples/speedscript.mod` | Recreation of 1980s word processor |
| `examples/namegenerator.mod` | Procedural name generator |
| `examples/zodiac.mod` | Chinese zodiac lookup |
| `examples/brazilian.mod` | Brazilian numbers (mathematical concept) |

### Bioinformatics / data science

| File | Description |
|------|-------------|
| `examples/fastaStats.mod` | Sequence length stats from a FASTA file (uses `FastaParser`) |

## IDE

Launch with `./oberon [file.mod]`. The IDE is a Turbo Pascal-style full-screen editor built on [magiblot/tvision](https://github.com/magiblot/tvision).

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
