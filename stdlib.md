# Oberon Transpiler - Standard Library Reference

This document covers every built-in procedure and every procedure/constant available
in the built-in import modules.  All modules listed here are implemented directly by
the transpiler (inlined into the generated C); no external library files are needed.

---

## Language Built-ins

These identifiers are always in scope without any IMPORT statement.

### Procedures

| Signature | Description |
|-----------|-------------|
| `INC(VAR x: INTEGER)` | Increment `x` by 1. |
| `INC(VAR x: INTEGER; n: INTEGER)` | Increment `x` by `n`. |
| `DEC(VAR x: INTEGER)` | Decrement `x` by 1. |
| `DEC(VAR x: INTEGER; n: INTEGER)` | Decrement `x` by `n`. |
| `NEW(VAR p: Pointer)` | Allocate heap memory for the pointed-to type. |
| `HALT(code: INTEGER)` | Terminate program with exit code `code`. |
| `ASSERT(cond: BOOLEAN)` | Abort with a C `assert` failure if `cond` is FALSE. |
| `COPY(src: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR)` | Copy string `src` into `dst` (`strcpy`). |

### Functions

| Signature | Returns | Description |
|-----------|---------|-------------|
| `ABS(x)` | same type | Absolute value (integer or real). |
| `ODD(x: INTEGER)` | BOOLEAN | TRUE if `x` is odd. |
| `ORD(x: CHAR)` | INTEGER | Character code of `x`. |
| `CHR(n: INTEGER)` | CHAR | Character with code `n`. |
| `LEN(a: ARRAY)` | INTEGER | Number of elements in array `a`. |

### Legacy I/O (prefer Out/In modules)

| Call | Description |
|------|-------------|
| `WRITE(x)` | Print `x` followed by a newline. Chooses format by type: `%d`, `%g`, `%c`, or `%s`. |
| `WRITELN(x)` | Same as `WRITE`, or just print a newline when called with no argument. |
| `READ(VAR x)` | Read a value from stdin into `x`. Chooses format by type. |

---

## Out - Formatted Output

```
IMPORT Out;
```

| Procedure | Description |
|-----------|-------------|
| `Out.String(s: ARRAY OF CHAR)` | Write string `s` to stdout (no newline). |
| `Out.Ln()` | Write a newline. |
| `Out.Int(n: INTEGER)` | Write integer `n` with no padding. |
| `Out.Int(n: INTEGER; w: INTEGER)` | Write integer `n` right-aligned in a field of width `w`. |
| `Out.Real(x: REAL)` | Write real `x` in `%g` format. |
| `Out.Char(c: CHAR)` | Write character `c`. |
| `Out.Fixed(x: REAL; w, d: INTEGER)` | Write real `x` left-aligned in field `w` with `d` decimal places. |

---

## In - Formatted Input

```
IMPORT In;
```

| Procedure | Description |
|-----------|-------------|
| `In.Read(VAR c: CHAR)` | Read one character from stdin. |
| `In.Int(VAR n: INTEGER)` | Read a decimal integer from stdin. |
| `In.Real(VAR x: REAL)` | Read a floating-point number from stdin. |

---

## Random - Pseudo-random Numbers

```
IMPORT Random;
```

The RNG is seeded automatically at program start (`srand(time(NULL))`).

| Function | Returns | Description |
|----------|---------|-------------|
| `Random.Int(n: INTEGER)` | INTEGER | Random integer in `[0, n)`. |
| `Random.Real()` | REAL | Random real in `[0.0, 1.0)`. |

---

## Math - Mathematical Functions

```
IMPORT Math;
```

### Constants

| Name | Value |
|------|-------|
| `Math.pi` | pi (3.14159...) |
| `Math.e`  | e (2.71828...)  |

### Functions

All functions take and return REAL unless noted.

| Function | Description |
|----------|-------------|
| `Math.sqrt(x)` | Square root. |
| `Math.exp(x)` | e^x. |
| `Math.ln(x)` | Natural logarithm. |
| `Math.log(x)` | Base-10 logarithm. |
| `Math.sin(x)` | Sine (radians). |
| `Math.cos(x)` | Cosine (radians). |
| `Math.tan(x)` | Tangent (radians). |
| `Math.arcsin(x)` | Arcsine (result in radians). |
| `Math.arccos(x)` | Arccosine (result in radians). |
| `Math.arctan(x)` | Arctangent (result in radians). |
| `Math.arctan2(y, x)` | Two-argument arctangent (result in radians). |
| `Math.power(base, exp)` | `base` raised to `exp`. |
| `Math.floor(x)` | Largest integer <= x, as REAL. |
| `Math.ceil(x)` | Smallest integer >= x, as REAL. |
| `Math.round(x)` | Nearest integer, as REAL. |
| `Math.entier(x)` | Floor as INTEGER. |
| `Math.abs(x)` | Absolute value (real). |

---

## Strings - String Operations

```
IMPORT Strings;
```

String variables are `ARRAY OF CHAR` (or the `STRING` alias), capped at 256 bytes.

| Procedure / Function | Description |
|----------------------|-------------|
| `Strings.Length(s): INTEGER` | Number of characters in `s` (like `strlen`). |
| `Strings.Copy(src, VAR dst)` | Copy `src` into `dst`. |
| `Strings.Append(extra, VAR dst)` | Append `extra` to the end of `dst`. |
| `Strings.Compare(a, b): INTEGER` | Lexicographic compare: -1, 0, or +1. |
| `Strings.Pos(pattern, s): INTEGER` | Index of first occurrence of `pattern` in `s`, or -1 if absent. |

---

## Files - Standard Oberon File I/O

```
IMPORT Files;
```

### Types

| Type | Description |
|------|-------------|
| `Files.File` | Opaque handle to an open file. NIL means no file / error. |
| `Files.Rider` | Read/write cursor positioned within a file. Has a public `eof: BOOLEAN` field. |

A `Rider` is a value type (declare `VAR r: Files.Rider`).  Call `Files.Set` to attach it
to a file and seek to a position before using any read or write procedure.

All I/O is **binary** (raw bytes).  For the string procedures the on-disk format is a
null-terminated byte sequence.  For integers it is the native C `int` representation.

### File Operations

| Procedure / Function | Description |
|----------------------|-------------|
| `Files.Old(name): File` | Open an existing file for reading/writing. Returns NIL on error. |
| `Files.New(name): File` | Create (or truncate) a file for reading/writing. Returns NIL on error. |
| `Files.Register(f)` | Make a new file permanent (flushes buffer; files are on-disk from creation here). |
| `Files.Close(f)` | Close `f` and free its resources. |
| `Files.Length(f): INTEGER` | File size in bytes. |

### Rider Operations

| Procedure / Function | Description |
|----------------------|-------------|
| `Files.Set(VAR r, f: File, pos: INTEGER)` | Attach rider `r` to file `f` at byte offset `pos`. Clears `r.eof`. |
| `Files.Pos(VAR r): INTEGER` | Current byte offset of rider `r`. |
| `Files.Base(VAR r): File` | The file underlying rider `r`. |

### Read Procedures

All read procedures advance the rider position.  `r.eof` is set TRUE when the end
of file is reached or an error occurs.

| Procedure | Description |
|-----------|-------------|
| `Files.Read(VAR r; VAR x: BYTE)` | Read one byte. |
| `Files.ReadInt(VAR r; VAR x: INTEGER)` | Read a binary `int` (platform-native size). |
| `Files.ReadBool(VAR r; VAR x: BOOLEAN)` | Read a boolean (1 byte: 0=FALSE, non-zero=TRUE). |
| `Files.ReadReal(VAR r; VAR x: REAL)` | Read a binary `double`. |
| `Files.ReadString(VAR r; VAR x: ARRAY OF CHAR)` | Read a null-terminated string. |
| `Files.ReadNum(VAR r; VAR x: INTEGER)` | Read a LEB128-compressed integer. |

### Write Procedures

All write procedures advance the rider position.  `r.eof` is set TRUE on write error.

| Procedure | Description |
|-----------|-------------|
| `Files.Write(VAR r; x: BYTE)` | Write one byte. |
| `Files.WriteInt(VAR r; x: INTEGER)` | Write a binary `int`. |
| `Files.WriteBool(VAR r; x: BOOLEAN)` | Write a boolean (1 byte). |
| `Files.WriteReal(VAR r; x: REAL)` | Write a binary `double`. |
| `Files.WriteString(VAR r; x: ARRAY OF CHAR)` | Write a null-terminated string. |
| `Files.WriteNum(VAR r; x: INTEGER)` | Write a LEB128-compressed integer. |

---

## Terminal - Raw Terminal I/O

```
IMPORT Terminal;
```

Importing `Terminal` switches the terminal into raw (non-canonical) mode automatically
at program start and restores it on exit.  The cursor is hidden on entry and restored
on exit.  `Random` is also seeded automatically.

| Procedure / Function | Description |
|----------------------|-------------|
| `Terminal.Clear()` | Clear the screen and move cursor to top-left. |
| `Terminal.Goto(x, y: INTEGER)` | Move cursor to column `x`, row `y` (1-based). |
| `Terminal.ShowCursor()` | Make the cursor visible. |
| `Terminal.HideCursor()` | Hide the cursor. |
| `Terminal.KeyPressed(): BOOLEAN` | Returns TRUE (non-zero) if a key is waiting in the input buffer. Non-blocking. |
| `Terminal.ReadKey(): CHAR` | Read and return the next key.  Blocks if no key is ready. Arrow keys are mapped to control characters: Up=`01X`, Down=`02X`, Left=`03X`, Right=`04X`. Mouse events return `05X` -- call `MouseX/Y/Btn` immediately after to get the details. |
| `Terminal.GetTickCount(): INTEGER` | Milliseconds since the Unix epoch (useful for timing). |
| `Terminal.Random(n: INTEGER): INTEGER` | Random integer in `[0, n)`. |

### Mouse Input

Mouse reporting is opt-in. Call `Terminal.MouseOn()` to enable it; `ReadKey` will then
return `05X` whenever a mouse event arrives.

| Procedure / Function | Description |
|----------------------|-------------|
| `Terminal.MouseOn()` | Enable SGR mouse reporting (`?1000h ?1006h`). Mouse events arrive via `ReadKey`. |
| `Terminal.MouseOff()` | Disable mouse reporting and restore normal terminal behaviour. |
| `Terminal.MouseX(): INTEGER` | Column of the most recent mouse event (1-based). |
| `Terminal.MouseY(): INTEGER` | Row of the most recent mouse event (1-based). |
| `Terminal.MouseBtn(): INTEGER` | Button for the most recent event: `0`=left press, `1`=middle press, `2`=right press, `3`=any release, `64`=wheel up, `65`=wheel down. |

**Typical pattern:**
```oberon
Terminal.MouseOn();
key := Terminal.ReadKey();
IF key = 05X THEN
  x := Terminal.MouseX();
  y := Terminal.MouseY();
  IF Terminal.MouseBtn() = 0 THEN (* left click at x,y *) END
END
```

---

## Graphics - ANSI Terminal Graphics

```
IMPORT Graphics;
```

Provides two layers:
- **Text layer** -- direct cursor/color control for character-cell graphics.
- **Pixel buffer** -- a 240 x 100 logical pixel grid rendered using half-block
  characters (two vertical pixels per terminal cell).

### Text Layer

| Procedure | Description |
|-----------|-------------|
| `Graphics.Clear()` | Clear screen and home cursor. |
| `Graphics.Goto(x, y: INTEGER)` | Move cursor to column `x`, row `y` (1-based). |
| `Graphics.Color(fg, bg: INTEGER)` | Set foreground / background using standard ANSI color indices 0-7. |
| `Graphics.Color256(fg, bg: INTEGER)` | Set foreground / background using 256-color indices 0-255. |
| `Graphics.Reset()` | Reset all color/style attributes. |
| `Graphics.Fill(x, y, w, h: INTEGER; ch: CHAR)` | Fill a rectangle of `w` x `h` cells at `(x, y)` with character `ch`. |
| `Graphics.HLine(x, y, len: INTEGER; ch: CHAR)` | Draw a horizontal line of `len` copies of `ch` starting at `(x, y)`. |
| `Graphics.VLine(x, y, len: INTEGER; ch: CHAR)` | Draw a vertical line of `len` copies of `ch` starting at `(x, y)`. |
| `Graphics.Box(x, y, w, h: INTEGER)` | Draw a box using ASCII box-drawing characters (+-+|+-). |
| `Graphics.Sprite(x, y: INTEGER; s: ARRAY OF CHAR; color: INTEGER)` | Draw multi-line string `s` at `(x, y)` with ANSI color `color`. Newlines in `s` advance to the next row at column `x`. |

### Pixel Buffer

The pixel buffer is 240 columns x 100 rows.  Call `Graphics.Flush` to render it.
Colors are ANSI indices 1-7 (0 = transparent/off).

| Procedure | Description |
|-----------|-------------|
| `Graphics.ClearBuf()` | Clear the pixel buffer (all pixels off). |
| `Graphics.Plot(x, y, color: INTEGER)` | Set pixel at `(x, y)` to `color` (1-255, same palette as `Color256`). |
| `Graphics.Circle(cx, cy, r, color: INTEGER)` | Draw a circle outline using Bresenham's algorithm. |
| `Graphics.Flush()` | Render the pixel buffer to the terminal using half-block characters. |

---

## Keywords - Oberon Language Keywords

These are the reserved words of the Oberon language.  They cannot be used as
identifiers.

### Program Structure

| Keyword | Description |
|---------|-------------|
| `MODULE name; ... END name.` | Top-level compilation unit. Every source file is a MODULE. |
| `IMPORT m1 [, m2];` | Declare modules used by this module. Must come first, after MODULE heading. |
| `CONST name = expr;` | Declare a compile-time constant. |
| `TYPE name = TypeDef;` | Declare a named type alias or new type. |
| `VAR name: Type;` | Declare a variable. Multiple names can share a type: `VAR a, b: INTEGER`. |
| `PROCEDURE name(params): RetType; ... END name;` | Declare a procedure or function. Omit `: RetType` for procedures. |
| `BEGIN` | Opens the statement sequence of a MODULE or PROCEDURE body. |
| `END` | Closes a block: MODULE body, PROCEDURE body, IF, WHILE, FOR, LOOP, RECORD, etc. |
| `RETURN expr` | Return a value from a function procedure. Also valid without `expr` to exit a procedure early. |

### Control Flow

| Keyword | Description |
|---------|-------------|
| `IF cond THEN ... END` | Conditional.  Add `ELSIF cond THEN` branches and an optional `ELSE` branch before `END`. |
| `ELSIF cond THEN` | Additional condition branch inside an `IF` statement. |
| `ELSE` | Fallback branch in `IF` or `CASE` statements. |
| `WHILE cond DO ... END` | Loop while `cond` is TRUE. |
| `REPEAT ... UNTIL cond` | Loop until `cond` is TRUE (body executes at least once). |
| `FOR v := start TO stop [BY step] DO ... END` | Count loop. `v` is incremented by `step` (default 1) each iteration. |
| `LOOP ... END` | Infinite loop. Use `EXIT` to break out. |
| `EXIT` | Break out of the enclosing `LOOP ... END`. |
| `CASE expr OF v: stmts ELSE stmts END` | Multi-way branch on an INTEGER or CHAR expression. Separate cases with a vertical bar. |
| `WITH v: Type DO ... END` | Type guard: narrows the type of a pointer variable inside the block. |

### Type Constructors

| Keyword | Description |
|---------|-------------|
| `ARRAY n OF Type` | Fixed-length array of `n` elements.  Multi-dimensional: `ARRAY n, m OF Type`. |
| `RECORD [( BaseType )] field: Type; ... END` | Record (struct).  Optional `(BaseType)` extends `BaseType`, inheriting all its fields. |
| `POINTER TO Type` | Heap-allocated reference to `Type`.  Dereferenced with `^` (e.g. `p^.field`). |
| `PROCEDURE (params): RetType` | Procedure type (for procedure-typed variables and parameters). Omit `: RetType` for procedures with no return value. |

### Record Inheritance and Dynamic Dispatch

A record type can extend a base type:

```oberon
TYPE
  Animal  = RECORD name: ARRAY 32 OF CHAR END;
  Dog     = RECORD (Animal) breed: ARRAY 32 OF CHAR END;
  AnimalP = POINTER TO Animal;
  DogP    = POINTER TO Dog;
```

- All fields of `Animal` are inherited by `Dog`.
- A `DogP` pointer is assignment-compatible with `AnimalP`.
- The `IS` operator tests the runtime type: `p IS Dog` is TRUE if `p` points to a `Dog`.
- Use `WITH p: Dog DO ... END` to narrow the pointer type inside a block (see `WITH` in Control Flow).
- Call `NEW(p)` on a pointer variable to heap-allocate the record.  The runtime type tag is set automatically.

### Nested Procedures

Procedures may be declared inside other procedures.  The inner procedure has read/write access to all variables and parameters of the enclosing procedure:

```oberon
PROCEDURE Outer;
  VAR x: INTEGER;
  PROCEDURE Inner;
  BEGIN x := x + 1 END Inner;
BEGIN
  x := 10;
  Inner;   (* x is now 11 *)
END Outer;
```

Nested procedures are not visible outside their enclosing procedure.  They cannot be stored in procedure-type variables or passed as procedure parameters.

### Predeclared Types

| Keyword | Description |
|---------|-------------|
| `BYTE` | Unsigned 8-bit integer (maps to C `unsigned char`). |
| `SHORTINT` | Signed 16-bit integer (maps to C `short`). Oberon-2 extension. |
| `INTEGER` | Signed 32-bit integer (maps to C `int`). |
| `LONGINT` | Signed 64-bit integer on 64-bit platforms (maps to C `long`). Use for timestamps and large counts. Oberon-2 extension. |
| `REAL` | 64-bit floating-point (maps to C `double`). |
| `LONGREAL` | Alias for `REAL`; both map to C `double`. Oberon-2 extension. |
| `BOOLEAN` | Logical type with values `TRUE` and `FALSE` (maps to C `int`). |
| `CHAR` | Single character (maps to C `char`). |
| `SET` | Bit-set type (32 bits); supports `+`, `-`, `*`, `/` (union, diff, intersection, sym-diff) and the `IN` operator. |
| `STRING` | Alias for `ARRAY 256 OF CHAR`. |

### Predeclared Constants

| Keyword | Description |
|---------|-------------|
| `TRUE` | Boolean true value. |
| `FALSE` | Boolean false value. |
| `NIL` | Null pointer value (compatible with any `POINTER TO` type). |

### Operators

| Keyword | Description |
|---------|-------------|
| `DIV` | Integer division with floor semantics: `7 DIV 3 = 2`, `-7 DIV 3 = -3`. Result rounds toward negative infinity (unlike C `/` which truncates toward zero). |
| `MOD` | Integer modulo, always non-negative when divisor is positive: `7 MOD 3 = 1`, `-7 MOD 3 = 2`. Satisfies `(a DIV b)*b + a MOD b = a`. |
| `OR` | Boolean or (short-circuit): `a OR b`. |
| `IN` | Set membership test: `x IN s` is TRUE if bit `x` is set in `s`. |
| `IS` | Dynamic type test: `v IS T` is TRUE if the pointer `v` currently points to a record of type `T` or a type that extends `T`. Requires the record type to be heap-allocated via `NEW`. |
| `OF` | Used in `ARRAY n OF T`, `CASE ... OF`, `ARRAY OF CHAR` (open array), and type guards. |

---

## Args - Command-line Arguments

```
IMPORT Args;
```

Arguments are numbered from 1 (argument 0 is the program name and is not accessible).

| Procedure / Function | Description |
|----------------------|-------------|
| `Args.Count(): INTEGER` | Number of command-line arguments (not counting the program name). |
| `Args.Get(n: INTEGER; VAR s: ARRAY OF CHAR)` | Copy argument `n` (1-based) into `s`. `s` is set to the empty string if `n` is out of range. |
