# Oberon Transpiler

An Oberon-07 to C transpiler. Write programs in Oberon, compile them to native executables via C.

## Requirements

- GCC
- POSIX system (macOS, Linux)

## Building

```
make all
```

This produces:
- `obc` — the command-line compiler
- `oberon` — an IDE with syntax highlighting and run capability

## Usage

```
./obc <file.mod> [-o outfile] [--emit-c]
```

Options:
- `-o outfile` — name the output executable (defaults to the module name)
- `--emit-c` — keep generated `.c` files after compilation

Example:
```
./obc examples/fact.mod -o fact
./fact
```

## Language

Oberon-07 with multi-module support. Exported declarations are marked with `*`.

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

Supported features:
- Types: `INTEGER`, `REAL`, `CHAR`, `BOOLEAN`, `ARRAY`, `RECORD`, `POINTER`
- Statements: `IF/ELSIF/ELSE`, `WHILE`, `REPEAT/UNTIL`, `FOR`, `CASE`, `LOOP/EXIT`
- Procedures with value and `VAR` (reference) parameters, return types
- Multi-module compilation with `IMPORT`

## Standard Library

| Module | Purpose |
|--------|---------|
| `Out` | Formatted output (`String`, `Int`, `Real`, `Char`, `Ln`, `Fixed`) |
| `In` | Formatted input (`Int`, `Real`, `Read`) |
| `Math` | Math functions (`sqrt`, `sin`, `cos`, `exp`, `ln`, `pi`, ...) |
| `Random` | Random numbers (`Int(n)`, `Real()`) |
| `Strings` | String operations (`Length`, `Copy`, `Append`, `Compare`, `Pos`) |
| `Files` | Binary file I/O with Rider cursor model |
| `Terminal` | Raw terminal I/O, keyboard, mouse, timing |
| `Graphics` | ANSI terminal graphics, pixel buffer, drawing primitives |

Full API reference: [stdlib.md](stdlib.md)

## Examples

| File | Description |
|------|-------------|
| `examples/fact.mod` | Recursive factorial |
| `examples/fibonacci.mod` | Fibonacci via FOR loop |
| `examples/records.mod` | RECORD types |
| `examples/multitest.mod` | Multi-module program |
| `examples/filestest.mod` | Binary file I/O |
| `examples/gfxtest.mod` | Terminal graphics |
| `examples/mandelbrot.mod` | Mandelbrot fractal |
| `examples/mousetest.mod` | Mouse input |
| `examples/snake.mod` | Snake game |
| `examples/tetris.mod` | Tetris game |
| `examples/sudoku.mod` | Sudoku game |
| `examples/slots.mod` | Slot machine game |

## How It Works

1. Lex and parse the `.mod` file into an AST
2. Resolve imports, recursively compiling user modules first
3. Emit `.c` and `.h` files for each module
4. Link everything with `gcc`

Built-in modules are inlined directly into the generated C — no external runtime dependencies.

## License

MIT — see [LICENSE](LICENSE)
