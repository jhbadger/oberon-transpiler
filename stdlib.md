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
| `PACK(VAR x: REAL; n: INTEGER)` | Multiply `x` by 2ⁿ in place: `x := x * 2^n`. Equivalent to adjusting the floating-point exponent by `n`. |
| `UNPK(VAR x: REAL; VAR n: INTEGER)` | Decompose `x` into a normalised mantissa and exponent. After the call `x` is in `[1.0, 2.0)` and `n` holds the original exponent such that the previous value of `x` equals `x * 2^n`. |

### Functions

| Signature | Returns | Description |
|-----------|---------|-------------|
| `ABS(x)` | same type | Absolute value.  Uses integer `abs` for `INTEGER`/`LONGINT` arguments, `fabs` for `REAL`/`LONGREAL`. |
| `ODD(x: INTEGER)` | BOOLEAN | TRUE if `x` is odd. |
| `ORD(x: CHAR)` | INTEGER | Character code of `x`. |
| `CHR(n: INTEGER)` | CHAR | Character with code `n`. |
| `LEN(a: ARRAY)` | INTEGER | Number of elements in array `a`. |
| `FLT(x: INTEGER)` | REAL | Convert integer `x` to a floating-point value (`(double)x`). |
| `ASR(x: INTEGER; n: INTEGER)` | INTEGER | Arithmetic shift right: `x` shifted right by `n` bits, sign-extending the MSB. Equivalent to `x DIV 2^n` with floor semantics. `n` is masked to `[0, 31]`. |
| `LSL(x: INTEGER; n: INTEGER)` | INTEGER | Logical shift left: `x` shifted left by `n` bits, filling zeros on the right. `n` is masked to `[0, 31]`. |
| `ROR(x: INTEGER; n: INTEGER)` | INTEGER | Rotate right: the 32-bit pattern of `x` rotated right by `n` bit positions. `n` is masked to `[0, 31]`. |

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
| `In.Char(VAR c: CHAR)` | Read one character from stdin (alias for `In.Read`). |
| `In.Int(VAR n: INTEGER)` | Read a decimal integer from stdin. |
| `In.Real(VAR x: REAL)` | Read a floating-point number from stdin. |
| `In.String(VAR s: ARRAY OF CHAR)` | Read a whitespace-delimited word from stdin (max 255 chars). |
| `In.Line(VAR s: ARRAY OF CHAR)` | Read a full line from stdin (up to 255 chars); the newline is consumed but not stored. |

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
| `Math.min(a, b)` | Smaller of `a` and `b`. Works for both REAL and INTEGER arguments. |
| `Math.max(a, b)` | Larger of `a` and `b`. Works for both REAL and INTEGER arguments. |
| `Math.clamp(x, lo, hi)` | Clamp `x` to `[lo, hi]`: returns `lo` if `x < lo`, `hi` if `x > hi`, else `x`. |

---

## Env - Environment Variables

```
IMPORT Env;
```

| Procedure / Function | Description |
|----------------------|-------------|
| `Env.Get(name: ARRAY OF CHAR; VAR val: ARRAY OF CHAR): BOOLEAN` | Look up environment variable `name`. Copies the value into `val` and returns TRUE, or sets `val` to the empty string and returns FALSE if the variable is not set. |

---

## OS - Operating System Calls

```
IMPORT OS;
```

| Procedure / Function | Description |
|----------------------|-------------|
| `OS.Exec(cmd: ARRAY OF CHAR): INTEGER` | Run `cmd` via the system shell. Returns the command's exit code (0 = success), or -1 on error. |
| `OS.Exit(code: INTEGER)` | Terminate the program immediately with exit code `code`. |
| `OS.GetCwd(VAR s: ARRAY OF CHAR)` | Copy the current working directory path into `s`. Sets `s` to the empty string on error. |
| `OS.ChDir(path: ARRAY OF CHAR): BOOLEAN` | Change the working directory to `path`. Returns TRUE on success. |

---

## Time - Date and Time

```
IMPORT Time;
```

Timestamps are milliseconds since the Unix epoch, stored as `LONGINT`.

| Procedure / Function | Description |
|----------------------|-------------|
| `Time.Now(): LONGINT` | Current time as milliseconds since the Unix epoch. |
| `Time.Sleep(ms: INTEGER)` | Pause execution for `ms` milliseconds. |
| `Time.Format(t: LONGINT; fmt: ARRAY OF CHAR; VAR s: ARRAY OF CHAR)` | Format timestamp `t` into `s` using `strftime`-style `fmt` (e.g. `"%Y-%m-%d %H:%M:%S"`). Uses local time. |

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
| `Strings.Pos(pattern, s: ARRAY OF CHAR): INTEGER` | Index of first occurrence of `pattern` in `s`, or -1 if absent. |
| `Strings.Pos(pattern, s: ARRAY OF CHAR; from: INTEGER): INTEGER` | As above but search starts at `from`. |
| `Strings.Extract(src: ARRAY OF CHAR; pos, len: INTEGER; VAR dst: ARRAY OF CHAR)` | Copy `len` characters from `src` starting at `pos` into `dst`. |
| `Strings.Insert(src: ARRAY OF CHAR; pos: INTEGER; VAR dst: ARRAY OF CHAR)` | Insert `src` into `dst` at position `pos`. |
| `Strings.Delete(VAR s: ARRAY OF CHAR; pos, len: INTEGER)` | Delete `len` characters from `s` starting at `pos`. |
| `Strings.Replace(src: ARRAY OF CHAR; pos: INTEGER; VAR dst: ARRAY OF CHAR)` | Overwrite `dst` at `pos` with `src`. |
| `Strings.ToUpper(VAR s: ARRAY OF CHAR)` | Convert all characters in `s` to uppercase in place. |
| `Strings.ToLower(VAR s: ARRAY OF CHAR)` | Convert all characters in `s` to lowercase in place. |
| `Strings.Trim(VAR s: ARRAY OF CHAR)` | Strip leading and trailing whitespace from `s` in place. |
| `Strings.NextWord(src: ARRAY OF CHAR; VAR pos: INTEGER; VAR dst: ARRAY OF CHAR)` | Skip whitespace in `src` from `pos`, copy the next word into `dst`, advance `pos` past it. `dst` is empty if no more words. |
| `Strings.IntToStr(n: INTEGER; VAR s: ARRAY OF CHAR)` | Format integer `n` into string `s`. |
| `Strings.RealToStr(x: REAL; VAR s: ARRAY OF CHAR)` | Format real `x` into string `s` (`%g` format). |
| `Strings.StrToInt(s: ARRAY OF CHAR; VAR n: INTEGER): BOOLEAN` | Parse integer from `s` into `n`. Returns FALSE if `s` is not a valid integer. |
| `Strings.StrToReal(s: ARRAY OF CHAR; VAR x: REAL): BOOLEAN` | Parse real from `s` into `x`. Returns FALSE if `s` is not a valid number. |
| `Strings.StartsWith(s, prefix: ARRAY OF CHAR): BOOLEAN` | Returns TRUE if `s` begins with `prefix`. |
| `Strings.EndsWith(s, suffix: ARRAY OF CHAR): BOOLEAN` | Returns TRUE if `s` ends with `suffix`. |
| `Strings.Split(s: ARRAY OF CHAR; sep: CHAR; n: INTEGER; VAR part: ARRAY OF CHAR): BOOLEAN` | Extract the `n`-th (0-based) field of `s` split by delimiter `sep` into `part`. Returns FALSE if there is no `n`-th field. |

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
| `Files.Delete(name)` | Delete the file with the given name. No-op if it does not exist. |
| `Files.Rename(old, new)` | Rename (or move) a file from `old` to `new`. |
| `Files.Exists(name): BOOLEAN` | Returns TRUE if the named file exists and can be opened. |

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
| `Files.ReadLine(VAR r; VAR x: ARRAY OF CHAR)` | Read one text line (up to `\n` or EOF); the newline is consumed but not stored. Sets `r.eof` when no characters are available. |
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
| `Files.WriteLine(VAR r; x: ARRAY OF CHAR)` | Write a string followed by a newline character. |
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
| `Terminal.ReadKey(): CHAR` | Read and return the next key.  Blocks if no key is ready. Special keys are mapped to values above 127: |
| KUp*        = 0A0X;  (* Up arrow    *)|
| KDown*      = 0A1X;  (* Down arrow  *)|
| KLeft*      = 0A2X;  (* Left arrow  *)|
| KRight*     = 0A3X;  (* Right arrow *)|
| KMouse*     = 0A4X;  (* Mouse event *)|
| KShiftUp*   = 0A5X;  (* Shift+Up    *)|
| KShiftDown* = 0A6X;  (* Shift+Down  *)|
| KShiftLeft* = 0A7X;  (* Shift+Left  *)|
| KShiftRight*= 0A8X;  (* Shift+Right *)|
| KBackspace* = 08X;|
| KTab*       = 09X;|
| KEnter*     = 0DX;|
| KEsc*       = 1BX;|
| KPgUp*      = 80X;   (* Page Up         *)|
| KPgDn*      = 81X;   (* Page Down       *)|
| KHome*      = 82X;   (* Home            *)|
| KEnd*       = 83X;   (* End             *)|
| KDel*       = 84X;   (* Delete          *)|
| KCtrlLeft*  = 85X;   (* Ctrl+Left       *)|
| KCtrlRight* = 86X;   (* Ctrl+Right      *)|
| KCtrlHome*  = 87X;   (* Ctrl+Home       *)|
| KCtrlEnd*   = 88X;   (* Ctrl+End        *)|
| KF1*        = 89X;   (* F1              *)|
| KF2*        = 8AX;   (* F2              *)|
| KF3*        = 8BX;   (* F3              *)|
| KF4*        = 8CX;   (* F4              *)|
| KF5*        = 8DX;   (* F5              *)|
| KF6*        = 8EX;   (* F6              *)|
| KF7*        = 8FX;   (* F7              *)|
| KF8*        = 90X;   (* F8              *)|
| KF9*        = 91X;   (* F9              *)|
| KF10*       = 92X;   (* F10             *)|
| KF11*       = 93X;   (* F11             *)|
| KF12*       = 94X;   (* F12             *)|
| `Terminal.GetTickCount(): INTEGER` | Milliseconds since the Unix epoch (useful for timing). |
| `Terminal.Cols(): INTEGER` | Returns the terminal width in columns (falls back to 80 if unavailable). |
| `Terminal.Rows(): INTEGER` | Returns the terminal height in rows (falls back to 24 if unavailable). |
| `Terminal.Random(n: INTEGER): INTEGER` | Random integer in `[0, n)`. |
| `Terminal.Shell(cmd: ARRAY OF CHAR)` | Suspend raw mode, run `cmd` via the system shell, print `-- Press Enter to return --`, wait for Enter, then reinitialise raw mode. Useful for invoking compilers, pagers, or any interactive command without leaving the editor. |
| `Terminal.Restore()` | Restore the terminal to its original (cooked) mode and show the cursor. Called automatically on exit; call manually before handing control to code that expects a normal terminal. |
| `Terminal.Init()` | Re-enter raw (non-canonical) mode and hide the cursor, matching the state established at program start. Use after `Terminal.Restore()` to return to raw mode without restarting the program. |

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
| `Graphics.FillCircle(cx, cy, r, color: INTEGER)` | Draw a filled circle using Bresenham scan-fill. |
| `Graphics.Line(x0, y0, x1, y1, color: INTEGER)` | Draw a line between `(x0, y0)` and `(x1, y1)` using Bresenham's algorithm. |
| `Graphics.FillBuf(color: INTEGER)` | Fill the entire pixel buffer with `color`. |
| `Graphics.RGBColor(r, g, b: INTEGER): INTEGER` | Map an RGB triple (0–255 each) to the nearest xterm-256 color index. Useful for passing to `Graphics.Plot` or `Graphics.Color256`. |
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
| `Args.GetEnv(name: ARRAY OF CHAR; VAR val: ARRAY OF CHAR)` | Copy environment variable `name` into `val`. Sets `val` to the empty string if the variable is not set. (Prefer `Env.Get` for new code, which also returns a BOOLEAN.) |

---

## Dict - String-keyed Hash Table

```
IMPORT Dict;
```

Declare a table with `VAR d: Dict.Table` and initialise it with `Dict.Init` before use.
Keys and values are strings (max 255 characters each). The table uses 256-bucket chaining and heap-allocates nodes internally.

| Procedure / Function | Description |
|----------------------|-------------|
| `Dict.Init(VAR d: Dict.Table)` | Initialise (or reset) a table. Must be called before use. |
| `Dict.Put(VAR d: Dict.Table; key, value: ARRAY OF CHAR)` | Insert or update `key` with `value`. |
| `Dict.Get(VAR d: Dict.Table; key: ARRAY OF CHAR; VAR value: ARRAY OF CHAR): BOOLEAN` | Look up `key`. Copies value into `value` and returns TRUE, or returns FALSE if not found. |
| `Dict.Has(VAR d: Dict.Table; key: ARRAY OF CHAR): BOOLEAN` | Returns TRUE if `key` exists. |
| `Dict.Remove(VAR d: Dict.Table; key: ARRAY OF CHAR)` | Delete `key` from the table. No-op if absent. |
| `Dict.Clear(VAR d: Dict.Table)` | Remove all entries and free memory. |
| `Dict.First(VAR d: Dict.Table; VAR key, value: ARRAY OF CHAR): BOOLEAN` | Initialise an iteration and retrieve the first key/value pair. Returns FALSE if the table is empty. The order is unspecified (hash order). |
| `Dict.Next(VAR d: Dict.Table; VAR key, value: ARRAY OF CHAR): BOOLEAN` | Advance the iterator and retrieve the next key/value pair. Returns FALSE when all entries have been visited. Only one active iteration per table is supported at a time. |

---

## Zip - ZIP Archive Reading

```
IMPORT Zip;
```

Read-only access to ZIP archives (the format used by `.epub`, `.jar`, `.odt`, etc.).
Supports both stored (method 0) and deflated (method 8) entries.  Backed by zlib;
links with `-lz` automatically.

### Types

| Type | Description |
|------|-------------|
| `Zip.Archive` | Opaque handle to an open ZIP archive.  NIL means no archive / error. |

### Procedures and Functions

| Procedure / Function | Description |
|----------------------|-------------|
| `Zip.Open(path: ARRAY OF CHAR): Archive` | Open a ZIP file for reading.  Parses the Central Directory on open.  Returns NIL on error. |
| `Zip.Count(z: Archive): INTEGER` | Number of entries in the archive. |
| `Zip.EntryName(z: Archive; i: INTEGER; VAR name: ARRAY OF CHAR)` | Copy the name of entry `i` (0-based) into `name`.  Sets `name` to empty string if out of range. |
| `Zip.EntrySize(z: Archive; i: INTEGER): INTEGER` | Uncompressed size in bytes of entry `i`. |
| `Zip.Find(z: Archive; name: ARRAY OF CHAR): INTEGER` | Linear search for an entry by exact name.  Returns its index, or -1 if not found. |
| `Zip.Extract(z: Archive; i: INTEGER; VAR buf: ARRAY OF CHAR): INTEGER` | Decompress entry `i` into `buf`.  Returns the number of bytes written, or -1 on error.  The buffer size limits how much is read. |
| `Zip.ExtractFile(z: Archive; i: INTEGER; dest: ARRAY OF CHAR): BOOLEAN` | Decompress entry `i` and write it to the file path `dest`.  Returns TRUE on success. |
| `Zip.Close(z: Archive)` | Close the archive and free all resources. |

---

## TUI - Terminal User Interface

```
IMPORT TUI;
```

Double-buffered character-cell UI framework.  The screen is a grid of cells, each
holding one character plus foreground/background color.  Views are linked-list nodes
attached to `TUI.Desktop`; `DrawAll` paints them back-to-front.

### Colors

| Constant | Value | Description |
|----------|-------|-------------|
| `TUI.Black` | 0 | |
| `TUI.Red` | 1 | |
| `TUI.Green` | 2 | |
| `TUI.Yellow` | 3 | |
| `TUI.Blue` | 4 | |
| `TUI.Magenta` | 5 | |
| `TUI.Cyan` | 6 | |
| `TUI.White` | 7 | |

### Key Codes

Same values as Terminal module.  Use `TUI.KEsc`, `TUI.KUp`, `TUI.KDown`, etc.  Mouse
events arrive as `ev.kind = TUI.EvMouse` with `ev.mb`: 0=left press, 3=release,
32=motion, 64=wheel-up, 65=wheel-down.

### Box-Drawing Characters

| Constant | Description |
|----------|-------------|
| `TUI.BoxH` | Horizontal line `─` |
| `TUI.BoxV` | Vertical line `│` |
| `TUI.BoxTL` | Top-left corner `┌` |
| `TUI.BoxTR` | Top-right corner `┐` |
| `TUI.BoxBL` | Bottom-left corner `└` |
| `TUI.BoxBR` | Bottom-right corner `┘` |

These are stored as single-byte codes (0xC0–0xC5) in the back-buffer and converted
to UTF-8 at flush time.  Pass them to `TUI.PutCell`.

### Event Kinds

| Constant | Description |
|----------|-------------|
| `TUI.EvNone` | No event |
| `TUI.EvKey` | Keyboard event; `ev.key` holds the key code |
| `TUI.EvMouse` | Mouse event; `ev.mx`, `ev.my`, `ev.mb` set |
| `TUI.EvResize` | Terminal was resized; `ev.cols`, `ev.rows` set |

### Types

| Type | Description |
|------|-------------|
| `TUI.Event` | Event record: `kind: INTEGER; key: CHAR; mx, my, mb, cols, rows: INTEGER` |
| `TUI.View` | `POINTER TO TUI.ViewRec` — base view type |
| `TUI.ViewRec` | Base record: `x, y, w, h: INTEGER; draw: DrawProc; handle: HandleProc; next, child: View; focused, alwaysOnTop: INTEGER` |
| `TUI.Window` | `POINTER TO TUI.WindowRec` — view with a titled border |
| `TUI.WindowRec` | Extends `ViewRec` with `title: ARRAY 256 OF CHAR; moveable: INTEGER` |
| `TUI.DrawProc` | `PROCEDURE(v: TUI.View)` — callback to paint a view |
| `TUI.HandleProc` | `PROCEDURE(v: TUI.View; ev: TUI.Event): BOOLEAN` — callback to handle an event |

### Global Variables

| Variable | Description |
|----------|-------------|
| `TUI.Cols` | Current terminal width in columns |
| `TUI.Rows` | Current terminal height in rows |
| `TUI.Desktop` | Head of the view linked list (back of drawing order) |
| `TUI.Focused` | Currently focused view (receives keyboard events) |
| `TUI.ModalResult` | Set non-zero to break out of a `REPEAT ... UNTIL TUI.ModalResult # 0` main loop |

### Procedures

| Procedure / Function | Description |
|----------------------|-------------|
| `TUI.Init` | Initialize the TUI (enter raw mode, enable mouse, query terminal size). |
| `TUI.Done` | Restore the terminal to normal state. |
| `TUI.Suspend` | Temporarily restore the terminal (e.g. before shelling out). |
| `TUI.Resume` | Re-enter TUI mode after `Suspend`. |
| `TUI.ClearBack(fg, bg: INTEGER)` | Fill the entire back-buffer with character `' '` in the given colors. Call at the top of each frame. |
| `TUI.PutCell(x, y: INTEGER; ch: CHAR; fg, bg: INTEGER)` | Write one character to the back-buffer at column `x`, row `y` (1-based). |
| `TUI.PutStr(x, y: INTEGER; s: ARRAY OF CHAR; fg, bg: INTEGER)` | Write a string starting at `(x, y)`. One cell per byte; stops at the null terminator. |
| `TUI.PutInt(x, y, n, fg, bg: INTEGER)` | Write integer `n` as a decimal string at `(x, y)`. |
| `TUI.FillRect(x, y, w, h: INTEGER; ch: CHAR; fg, bg: INTEGER)` | Fill a rectangle of `w` x `h` cells with `ch`. |
| `TUI.DrawBox(x, y, w, h, fg, bg: INTEGER)` | Draw a box outline using box-drawing characters. |
| `TUI.Flush` | Compare back-buffer to front-buffer and emit only the changed cells to the terminal, then swap. |
| `TUI.InvalidateFront` | Mark the entire front-buffer as dirty so `Flush` redraws everything. Use after a terminal resize. |
| `TUI.InvalidateLine(y: INTEGER)` | Mark row `y` dirty. |
| `TUI.SetCursor(x, y: INTEGER)` | Position the hardware cursor. |
| `TUI.UpdateSize` | Re-query the terminal dimensions; updates `TUI.Cols` and `TUI.Rows`. Returns 1 if size changed. |
| `TUI.WaitEvent(VAR ev: TUI.Event)` | Block until the next event and fill `ev`. |
| `TUI.PollEvent(VAR ev: TUI.Event): INTEGER` | Non-blocking event check. Returns 1 if an event was available, 0 otherwise. |
| `TUI.AddView(v: TUI.View)` | Append `v` to the desktop list (drawn last = on top). |
| `TUI.RemoveView(v: TUI.View)` | Unlink `v` from the desktop list. |
| `TUI.BringToFront(v: TUI.View)` | Move `v` to the front of the desktop list. |
| `TUI.HitTest(x, y: INTEGER): TUI.View` | Return the topmost view whose bounding box contains `(x, y)`, or NIL. |
| `TUI.TileWindows` | Arrange all `TUI.Window` views in a non-overlapping tile layout. |
| `TUI.SetFocus(v: TUI.View)` | Set `TUI.Focused` to `v`. |
| `TUI.FocusNext` | Cycle focus to the next focusable view in the desktop list. |
| `TUI.Dispatch(ev: TUI.Event): INTEGER` | Route `ev` to the focused view's `handle` proc. Returns the result. |
| `TUI.RunModal(w: TUI.Window): INTEGER` | Run a modal event loop for window `w` until `TUI.ModalResult` is set; returns `ModalResult`. |
| `TUI.DrawView(v: TUI.View)` | Call `v.draw(v)` if `v.draw # NIL`. |
| `TUI.DrawWindow(w: TUI.Window)` | Draw the window border and title, then call `w.draw`. |
| `TUI.DrawAll` | Repaint all views on the desktop in back-to-front order. |

---

## Widgets - TUI Widget Library

```
IMPORT Widgets;
```

Ready-made interactive controls built on `TUI`.  Each widget is a `TUI.View`
subtype with its own `draw` and `handle` procs; call `TUI.AddView` after creation
and `TUI.RemoveView` when done.

### Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `Widgets.CmdOK` | 1 | Command code sent by OK buttons |
| `Widgets.CmdCancel` | 2 | Command code sent by Cancel buttons |
| `Widgets.CmdYes` | 3 | Command code sent by Yes buttons |
| `Widgets.CmdNo` | 4 | Command code sent by No buttons |
| `Widgets.MaxItemText` | 64 | Maximum characters per list item |
| `Widgets.MaxItems` | 256 | Maximum items in a ListBox |
| `Widgets.MaxMenus` | 8 | Maximum menus in a MenuBar |
| `Widgets.MaxMenuItems` | 32 | Maximum items per menu |

### Types

| Type | Description |
|------|-------------|
| `Widgets.Label` | Read-only text label. Fields: `text: ARRAY 128 OF CHAR; fg, bg: INTEGER` |
| `Widgets.Button` | Clickable button. Fields: `text: ARRAY 64 OF CHAR; cmd: INTEGER; onClick: CmdProc` |
| `Widgets.InputLine` | Single-line text input. Fields: `buf: ARRAY 256 OF CHAR; len, pos, scroll: INTEGER` |
| `Widgets.ListBox` | Scrollable item list. Fields: `items: ARRAY[MaxItems][MaxItemText]; count, sel, scroll: INTEGER; onClick: CmdProc` |
| `Widgets.CheckBox` | Toggle checkbox. Fields: `text: ARRAY 64 OF CHAR; checked: INTEGER` |
| `Widgets.StaticText` | Multi-line read-only text. Fields: `text: ARRAY 1024 OF CHAR; fg, bg: INTEGER` |
| `Widgets.StatusLine` | Single-line status bar. Fields: `text: ARRAY 256 OF CHAR` |
| `Widgets.MenuBar` | Pulldown menu bar. Has `onCmd: CmdProc` callback fired when a menu item is selected. |
| `Widgets.CmdProc` | `PROCEDURE(cmd: INTEGER)` — callback type used by Button and ListBox |

### Constructors

| Function | Description |
|----------|-------------|
| `Widgets.NewLabel(x, y, w: INTEGER; text: ARRAY OF CHAR): Label` | Create a label at `(x, y)` with width `w`. |
| `Widgets.NewButton(x, y, w: INTEGER; text: ARRAY OF CHAR; cmd: INTEGER): Button` | Create a button. |
| `Widgets.NewInputLine(x, y, w: INTEGER): InputLine` | Create an empty single-line input field. |
| `Widgets.NewListBox(x, y, w, h: INTEGER): ListBox` | Create an empty list box. |
| `Widgets.NewCheckBox(x, y: INTEGER; text: ARRAY OF CHAR; checked: INTEGER): CheckBox` | Create a checkbox. |
| `Widgets.NewStaticText(x, y, w, h: INTEGER; text: ARRAY OF CHAR): StaticText` | Create a multi-line static text area. |
| `Widgets.NewStatusLine(x, y, w: INTEGER; text: ARRAY OF CHAR): StatusLine` | Create a status bar. Typically placed at `y = TUI.Rows`. |
| `Widgets.NewMenuBar(x, y, w: INTEGER): MenuBar` | Create a menu bar. Typically placed at `y = 1`. |

### Helper Procedures

| Procedure | Description |
|-----------|-------------|
| `Widgets.ListBoxAdd(lb: ListBox; item: ARRAY OF CHAR)` | Append an item to the list. |
| `Widgets.ListBoxClear(lb: ListBox)` | Remove all items and reset selection. |
| `Widgets.MenuBarAddMenu(mb: MenuBar; title: ARRAY OF CHAR)` | Add a top-level menu with the given title. |
| `Widgets.MenuBarAddItem(mb: MenuBar; menu: INTEGER; text: ARRAY OF CHAR; cmd: INTEGER)` | Add an item to menu `menu` (0-based) that fires `cmd` when selected. |
| `Widgets.MenuBarAddSep(mb: MenuBar; menu: INTEGER)` | Add a separator line to menu `menu`. |

---

## FileDialog - Modal File-Open Dialog

```
IMPORT FileDialog;
```

Presents a full-screen modal file browser built on `TUI` and `Widgets`.  Saves and
restores the desktop automatically; the caller's views are unaffected.

| Function | Description |
|----------|-------------|
| `FileDialog.Show(title, startPath, filter: ARRAY OF CHAR; VAR result: ARRAY OF CHAR): BOOLEAN` | Display the dialog.  `title` is the window title.  `startPath` is the initial directory (`""` = current working directory).  `filter` is a filename suffix to show (`""` = all files, e.g. `".mod"`).  On confirmation, copies the full absolute path into `result` and returns TRUE.  Returns FALSE if the user cancelled. |

**Navigation:** Arrow keys / PgUp / PgDn move through the file list.  Enter on a
directory navigates into it; Enter on a file accepts it.  Tab cycles focus between
list, filename input, OK, and Cancel.  Esc cancels.

---

## Help - Context-sensitive Help Dialog

```
IMPORT Help;
```

Searches `stdlib.md` for a query string and shows matching lines in a scrollable
modal window.  The IDE calls this from the F1 key.

| Procedure | Description |
|-----------|-------------|
| `Help.Show(query: ARRAY OF CHAR)` | Open a modal help window pre-searched for `query`.  The user can retype the term and press Enter to re-search.  Up/Down/PgUp/PgDn scroll results; Home/End jump to top/bottom; Esc closes. |

`stdlib.md` is located by searching the binary's directory, then `./stdlib.md`,
then `../stdlib.md`.

---

## Editor - Gap-buffer Text Editor

```
IMPORT Editor;
```

Gap-buffer text editor with undo support.  Implemented in C via FFI.
Line and column numbers in the API are **1-based**.

### Types

| Type | Description |
|------|-------------|
| `Editor.Handle` | Opaque pointer to an editor buffer. NIL = no buffer. |

### Lifecycle

| Function / Procedure | Description |
|----------------------|-------------|
| `Editor.New(): Handle` | Allocate a new empty editor buffer. |
| `Editor.Free(h: Handle)` | Free all resources associated with `h`. |
| `Editor.Load(h: Handle; path: ARRAY OF CHAR): INTEGER` | Load the file at `path` into `h`. Returns 0 on success, non-zero on error. |
| `Editor.Save(h: Handle; path: ARRAY OF CHAR): INTEGER` | Write the buffer to `path`. Returns 0 on success, non-zero on error. |

### Buffer State

| Function | Description |
|----------|-------------|
| `Editor.Len(h): INTEGER` | Total character count in the buffer. |
| `Editor.LineCount(h): INTEGER` | Number of lines in the buffer. |
| `Editor.IsModified(h): INTEGER` | Non-zero if the buffer has unsaved changes. |
| `Editor.CursorPos(h): INTEGER` | Absolute character offset of the cursor. |
| `Editor.CursorLine(h): INTEGER` | Line number of the cursor (1-based). |
| `Editor.CursorCol(h): INTEGER` | Column of the cursor (1-based). |

### Cursor Movement

| Procedure | Description |
|-----------|-------------|
| `Editor.MoveLeft(h)` | Move cursor one character left. |
| `Editor.MoveRight(h)` | Move cursor one character right. |
| `Editor.MoveUp(h)` | Move cursor one line up. |
| `Editor.MoveDown(h)` | Move cursor one line down. |
| `Editor.MoveLineStart(h)` | Move cursor to start of current line. |
| `Editor.MoveLineEnd(h)` | Move cursor to end of current line. |
| `Editor.GotoLine(h: Handle; line: INTEGER)` | Move cursor to line `line` (1-based). |
| `Editor.GotoPos(h: Handle; pos: INTEGER)` | Move cursor to absolute character offset `pos`. |

### Editing

| Procedure | Description |
|-----------|-------------|
| `Editor.InsertChar(h: Handle; ch: CHAR)` | Insert character `ch` at the cursor. |
| `Editor.InsertStr(h: Handle; s: ARRAY OF CHAR)` | Insert string `s` at the cursor. |
| `Editor.Backspace(h: Handle)` | Delete the character before the cursor. |
| `Editor.DeleteChar(h: Handle)` | Delete the character at the cursor. |
| `Editor.Undo(h: Handle)` | Undo the last edit. |

### Rendering and Search

| Function / Procedure | Description |
|----------------------|-------------|
| `Editor.GetLine(h: Handle; lineNo, bufsize: INTEGER; VAR buf: ARRAY OF CHAR): INTEGER` | Copy line `lineNo` (1-based) into `buf`, limited to `bufsize` bytes.  Pass `LEN(buf)` as `bufsize`.  Returns the character count. |
| `Editor.Find(h: Handle; pat: ARRAY OF CHAR; caseSensitive, wholeWord: INTEGER): INTEGER` | Search for `pat`. Returns 1 if found (cursor moves to match), 0 otherwise. |
| `Editor.FindAgain(h: Handle): INTEGER` | Repeat the last search. Returns 1 if found. |
| `Editor.Replace(h: Handle; repl: ARRAY OF CHAR): INTEGER` | Replace the current match with `repl`. Returns 1 on success. |

---

## FastaParser - FASTA Sequence File Parser

```
IMPORT FastaParser;
```

Streaming parser for FASTA-format files.  Iterates records without loading the
entire file into memory.

### Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `FastaParser.MaxIdLen` | 128 | Maximum bytes in a sequence identifier |

### Types

| Type | Description |
|------|-------------|
| `FastaParser.Scanner` | Parser state record.  Declare `VAR s: FastaParser.Scanner`.  Public field: `eof: BOOLEAN`. |

### Procedures

| Procedure / Function | Description |
|----------------------|-------------|
| `FastaParser.InitScanner(VAR s: Scanner; f: Files.File)` | Initialize `s` to read from file `f` (already opened with `Files.Old`). |
| `FastaParser.NextRecord(VAR s: Scanner; VAR id: ARRAY OF CHAR): BOOLEAN` | Advance to the next `>` header.  Copies the identifier into `id` (up to `LEN(id)-1` bytes) and returns TRUE.  Returns FALSE at end of file. |
| `FastaParser.ReadChunk(VAR s: Scanner; VAR buffer: ARRAY OF CHAR): INTEGER` | Read sequence data for the current record into `buffer`.  Returns the number of characters written.  Whitespace is stripped.  Must call `NextRecord` first.  Returns 0 and sets `buffer[0] := 0X` if called out of sequence. |

**Typical pattern:**
```oberon
VAR s: FastaParser.Scanner; id: ARRAY 128 OF CHAR; seq: ARRAY 4096 OF CHAR;
f := Files.Old("sequences.fasta");
FastaParser.InitScanner(s, f);
WHILE FastaParser.NextRecord(s, id) DO
  n := FastaParser.ReadChunk(s, seq);
  (* process id and seq *)
END
```

---

## DataFrame - Tabular Data

```
IMPORT DataFrame;
```

In-memory table with up to `MAXCOLS` columns and `MAXROWS` rows.  All cell values
are stored internally as strings; numeric accessors convert on the fly.

### Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `DataFrame.MAXCOLS` | 32 | Maximum columns |
| `DataFrame.MAXROWS` | 32768 | Maximum rows |
| `DataFrame.CNAMELEN` | 64 | Maximum column-name length |
| `DataFrame.CELLLEN` | 64 | Maximum cell string length |
| `DataFrame.OK` | 0 | Success |
| `DataFrame.ERR_COL` | 1 | Column index out of range |
| `DataFrame.ERR_ROW` | 2 | Row index out of range |
| `DataFrame.ERR_FULL` | 3 | Table is full |
| `DataFrame.ERR_FILE` | 4 | File not found or I/O error |

### Types

| Type | Description |
|------|-------------|
| `DataFrame.DataFrame` | `POINTER TO DataFrameRec` — opaque table handle.  NIL = error / not created. |

### Construction and Dimensions

| Function / Procedure | Description |
|----------------------|-------------|
| `DataFrame.Create(): DataFrame` | Allocate and return an empty DataFrame. |
| `DataFrame.AddCol(df: DataFrame; name: ARRAY OF CHAR): INTEGER` | Add a column named `name`. Returns the new column index, or -1 if at capacity. |
| `DataFrame.AddRow(df: DataFrame): INTEGER` | Append a blank row. Returns the new row index, or -1 if at capacity. |
| `DataFrame.NCols(df): INTEGER` | Number of columns. |
| `DataFrame.NRows(df): INTEGER` | Number of rows. |
| `DataFrame.ColName(df: DataFrame; c: INTEGER; VAR name: ARRAY OF CHAR)` | Copy the name of column `c` into `name`. Sets `name` to `""` if `c` is out of range. |
| `DataFrame.FindCol(df: DataFrame; name: ARRAY OF CHAR): INTEGER` | Return the index of the column named `name`, or -1 if not found. |

### Cell Setters

| Procedure | Description |
|-----------|-------------|
| `DataFrame.SetStr(df: DataFrame; r, c: INTEGER; val: ARRAY OF CHAR)` | Set cell `(r, c)` to a string value. |
| `DataFrame.SetInt(df: DataFrame; r, c, val: INTEGER)` | Set cell `(r, c)` to an integer (stored as a string). |
| `DataFrame.SetReal(df: DataFrame; r, c: INTEGER; val: REAL)` | Set cell `(r, c)` to a real (stored as a string). |

### Cell Getters

| Function / Procedure | Description |
|----------------------|-------------|
| `DataFrame.GetStr(df: DataFrame; r, c: INTEGER; VAR val: ARRAY OF CHAR)` | Copy cell `(r, c)` into `val`. Sets `val` to `""` for bad indices. |
| `DataFrame.GetInt(df: DataFrame; r, c: INTEGER; VAR val: INTEGER): BOOLEAN` | Parse cell `(r, c)` as integer into `val`. Returns FALSE if not a valid integer. |
| `DataFrame.GetReal(df: DataFrame; r, c: INTEGER; VAR val: REAL): BOOLEAN` | Parse cell `(r, c)` as real into `val`. Returns FALSE if not a valid number. |

### File Loading

| Function | Description |
|----------|-------------|
| `DataFrame.LoadCSV(fname: ARRAY OF CHAR; hasHeader: BOOLEAN; VAR err: INTEGER): DataFrame` | Load a CSV file. `hasHeader = TRUE` treats the first row as column names. Sets `err` to `OK` or an `ERR_*` constant. Returns NIL on file error. |
| `DataFrame.LoadTSV(fname: ARRAY OF CHAR; hasHeader: BOOLEAN; VAR err: INTEGER): DataFrame` | Load a tab-separated file. Same semantics as `LoadCSV`. |
| `DataFrame.LoadSep(fname: ARRAY OF CHAR; sep: CHAR; hasHeader: BOOLEAN; VAR err: INTEGER): DataFrame` | Load a file with an arbitrary separator character `sep`. |

### Display

| Procedure | Description |
|-----------|-------------|
| `DataFrame.Info(df: DataFrame)` | Print column count, row count, and column names to stdout. |
| `DataFrame.Head(df: DataFrame; n: INTEGER)` | Print the first `n` rows with column headers. |
| `DataFrame.Tail(df: DataFrame; n: INTEGER)` | Print the last `n` rows with column headers. |
| `DataFrame.Print(df: DataFrame)` | Print all rows with column headers. |

---

## DBF - dBASE/FoxPro Database Files

```
IMPORT DBF;
```

Read and write dBASE III / FoxPro `.dbf` files.  Supports Character (`C`), Numeric
(`N`), Logical (`L`), and Memo (`M`) field types.

### Constants

| Constant | Description |
|----------|-------------|
| `DBF.MaxFields` | Maximum number of fields per database (32) |
| `DBF.TypeChar` | Field type character `'C'` |
| `DBF.TypeNumeric` | Field type character `'N'` |
| `DBF.TypeLogical` | Field type character `'L'` |
| `DBF.TypeMemo` | Field type character `'M'` |

### Types

| Type | Description |
|------|-------------|
| `DBF.Field` | Field descriptor: `name: ARRAY 11 OF CHAR; type: CHAR; len, dec: BYTE` |
| `DBF.Database` | Open database state: `f: Files.File; numFields, recordLen, numRecs, headerLen: INTEGER; fields: ARRAY MaxFields OF Field` |
| `DBF.Index` | In-memory sorted index: `count, fieldIdx: INTEGER` |
| `DBF.ValidationResult` | Result of `Validate`: `ok: BOOLEAN; recNum, fieldIdx: INTEGER; msg: ARRAY 64 OF CHAR` |

### Field Construction

| Procedure | Description |
|-----------|-------------|
| `DBF.MakeField(VAR f: Field; name: ARRAY OF CHAR; ftype: CHAR; len, dec: BYTE)` | Fill a `Field` record with the given name, type, total length, and decimal places. |

### File Lifecycle

| Procedure | Description |
|-----------|-------------|
| `DBF.Create(VAR db: Database; filename: ARRAY OF CHAR; VAR flds: ARRAY OF Field; n: INTEGER)` | Create a new `.dbf` file with `n` fields from `flds`. |
| `DBF.Open(VAR db: Database; filename: ARRAY OF CHAR)` | Open an existing `.dbf` file. |
| `DBF.Close(VAR db: Database)` | Write the EOF marker, flush, and close. |

### Navigation

| Function / Procedure | Description |
|----------------------|-------------|
| `DBF.RecordCount(VAR db): INTEGER` | Number of records (including deleted). |
| `DBF.SeekRecord(VAR db: Database; recNum: INTEGER)` | Position the rider at record `recNum` (0-based). |
| `DBF.IsDeleted(VAR db: Database; recNum: INTEGER): BOOLEAN` | TRUE if record `recNum` is marked deleted. |

### Reading Fields

| Procedure / Function | Description |
|----------------------|-------------|
| `DBF.GetField(VAR db: Database; recNum, fieldIdx: INTEGER; VAR dst: ARRAY OF CHAR)` | Read a field as a trimmed string. |
| `DBF.GetFieldInt(VAR db: Database; recNum, fieldIdx: INTEGER; VAR n: INTEGER): BOOLEAN` | Read a numeric field as integer. Returns FALSE if not parseable. |
| `DBF.GetFieldReal(VAR db: Database; recNum, fieldIdx: INTEGER; VAR x: REAL): BOOLEAN` | Read a numeric field as real. Returns FALSE if not parseable. |
| `DBF.GetFieldBool(VAR db: Database; recNum, fieldIdx: INTEGER): BOOLEAN` | Read a logical field (T/t/Y/y = TRUE). |
| `DBF.GetRecord(VAR db: Database; recNum: INTEGER; VAR packed: ARRAY OF CHAR)` | Read all fields as a pipe-delimited packed string. |

### Writing Records

| Procedure | Description |
|-----------|-------------|
| `DBF.AppendFields(VAR db: Database; packed: ARRAY OF CHAR)` | Append a new record from a pipe-delimited packed string. |
| `DBF.UpdateField(VAR db: Database; recNum, fieldIdx: INTEGER; value: ARRAY OF CHAR)` | Overwrite one field in an existing record. |
| `DBF.UpdateFieldInt(VAR db: Database; recNum, fieldIdx, n: INTEGER)` | Overwrite a numeric field with integer `n`. |
| `DBF.UpdateFieldReal(VAR db: Database; recNum, fieldIdx: INTEGER; x: REAL)` | Overwrite a numeric field with real `x`. |
| `DBF.UpdateFieldBool(VAR db: Database; recNum, fieldIdx: INTEGER; v: BOOLEAN)` | Overwrite a logical field. |
| `DBF.UpdateRecord(VAR db: Database; recNum: INTEGER; packed: ARRAY OF CHAR)` | Overwrite all fields of record `recNum` from a pipe-delimited string. |

### Delete / Undelete / Pack

| Procedure | Description |
|-----------|-------------|
| `DBF.Delete(VAR db: Database; recNum: INTEGER)` | Mark record `recNum` as deleted. |
| `DBF.Undelete(VAR db: Database; recNum: INTEGER)` | Clear the deleted marker on record `recNum`. |
| `DBF.Pack(VAR db: Database; filename: ARRAY OF CHAR)` | Physically remove all deleted records by rewriting the file. |

### Search and Index

| Function | Description |
|----------|-------------|
| `DBF.Find(VAR db: Database; fieldIdx: INTEGER; value: ARRAY OF CHAR): INTEGER` | Linear search; returns first matching record index, or -1. |
| `DBF.FindNext(VAR db: Database; fieldIdx, fromRec: INTEGER; value: ARRAY OF CHAR): INTEGER` | Linear search starting at `fromRec`. Returns matching index or -1. |
| `DBF.BuildIndex(VAR db: Database; fieldIdx: INTEGER; VAR idx: Index)` | Build an in-memory sorted index on field `fieldIdx`. |
| `DBF.IndexFind(VAR idx: Index; value: ARRAY OF CHAR): INTEGER` | Binary search in an index. Returns matching record number or -1. |

### Export and Validate

| Procedure | Description |
|-----------|-------------|
| `DBF.ExportCSV(VAR db: Database; csvfile: ARRAY OF CHAR)` | Write all non-deleted records to a CSV file with a header row. |
| `DBF.Validate(VAR db: Database; VAR result: ValidationResult)` | Check all non-deleted records for type validity. Sets `result.ok` to FALSE and fills `result.msg` on the first error found. |

---

## PCA - Principal Component Analysis

```
IMPORT PCA;
```

Performs PCA on numeric columns of a `DataFrame` using power iteration with
deflation.  Results are printed to stdout as CSV.

### Limits

| Constant | Value | Description |
|----------|-------|-------------|
| `PCA.MAXFEAT` | 64 | Maximum number of feature columns |
| `PCA.MAXK` | 16 | Maximum number of principal components |
| `PCA.PCA_MAXROWS` | 1024 | Maximum number of rows |

### Procedures

| Procedure | Description |
|-----------|-------------|
| `PCA.Execute(df: DataFrame.DataFrame; featureCols: SET; labelCol, k: INTEGER)` | Standardize the columns indicated by `featureCols` (a SET of column indices), compute the top `k` principal components via power iteration, project each row, and print a CSV with columns `PC1, PC2, ..., PCk, Label` where `Label` comes from column `labelCol`. |

---

## SummarizedExperiment - Bioinformatics Assay Container

```
IMPORT SummarizedExperiment;
```

An Oberon port of Bioconductor's `SummarizedExperiment`.  Stores one or more named
numeric assay matrices (rows = features/genes, columns = samples) alongside
per-row and per-column metadata DataFrames and a string key/value metadata dict.

### Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `SummarizedExperiment.MAXROWS` | 4096 | Maximum feature (row) count |
| `SummarizedExperiment.MAXCOLS` | 256 | Maximum sample (column) count |
| `SummarizedExperiment.MAXASSAYS` | 8 | Maximum number of named assays |
| `SummarizedExperiment.NAMELEN` | 64 | Maximum length of row/column/assay names |
| `SummarizedExperiment.OK` | 0 | Success |
| `SummarizedExperiment.ERR_NIL` | 1 | SE pointer is NIL |
| `SummarizedExperiment.ERR_DIM` | 2 | Dimension out of range |
| `SummarizedExperiment.ERR_ROW` | 3 | Row index out of range |
| `SummarizedExperiment.ERR_COL` | 4 | Column index out of range |
| `SummarizedExperiment.ERR_ASSAY` | 5 | Assay index or name invalid |
| `SummarizedExperiment.ERR_FULL` | 6 | Capacity exceeded |
| `SummarizedExperiment.ERR_NAME` | 7 | Name already exists or is empty |

### Types

| Type | Description |
|------|-------------|
| `SummarizedExperiment.SE` | `POINTER TO SERec` — the top-level container handle |

### Construction and Dimensions

| Function / Procedure | Description |
|----------------------|-------------|
| `SummarizedExperiment.Create(nrows, ncols: INTEGER; VAR err: INTEGER): SE` | Allocate an SE with `nrows` features and `ncols` samples. Sets `err`. |
| `SummarizedExperiment.NRows(se: SE): INTEGER` | Number of feature rows. |
| `SummarizedExperiment.NCols(se: SE): INTEGER` | Number of sample columns. |
| `SummarizedExperiment.AssayCount(se: SE): INTEGER` | Number of assays added so far. |
| `SummarizedExperiment.Info(se: SE)` | Print dimensions and assay names to stdout. |

### Assays

| Function / Procedure | Description |
|----------------------|-------------|
| `SummarizedExperiment.AddAssay(se: SE; name: ARRAY OF CHAR; VAR err: INTEGER): INTEGER` | Add a named zero-filled assay matrix.  Returns its index, or -1 on error. |
| `SummarizedExperiment.FindAssay(se: SE; name: ARRAY OF CHAR): INTEGER` | Return the index of the assay named `name`, or -1 if not found. |
| `SummarizedExperiment.AssayName(se: SE; a: INTEGER; VAR name: ARRAY OF CHAR)` | Copy the name of assay `a` into `name`. |
| `SummarizedExperiment.SetAssay(se: SE; a, r, c: INTEGER; x: REAL; VAR err: INTEGER)` | Set cell `(r, c)` of assay `a` to `x`. |
| `SummarizedExperiment.GetAssay(se: SE; a, r, c: INTEGER; VAR x: REAL; VAR err: INTEGER)` | Get cell `(r, c)` of assay `a` into `x`. |
| `SummarizedExperiment.SetAssayByName(se: SE; assayName: ARRAY OF CHAR; r, c: INTEGER; x: REAL; VAR err: INTEGER)` | Set by assay name instead of index. |
| `SummarizedExperiment.GetAssayByName(se: SE; assayName: ARRAY OF CHAR; r, c: INTEGER; VAR x: REAL; VAR err: INTEGER)` | Get by assay name instead of index. |

### Row / Column Names

| Procedure | Description |
|-----------|-------------|
| `SummarizedExperiment.SetRowName(se: SE; r: INTEGER; name: ARRAY OF CHAR; VAR err: INTEGER)` | Set the name of feature row `r`. |
| `SummarizedExperiment.RowName(se: SE; r: INTEGER; VAR name: ARRAY OF CHAR)` | Copy the name of row `r` into `name`. |
| `SummarizedExperiment.SetColName(se: SE; c: INTEGER; name: ARRAY OF CHAR; VAR err: INTEGER)` | Set the name of sample column `c`. |
| `SummarizedExperiment.ColName(se: SE; c: INTEGER; VAR name: ARRAY OF CHAR)` | Copy the name of column `c` into `name`. |

### Row Metadata (rowData)

The rowData is a `DataFrame` with one row per feature.  Use the procedures below to
add columns and set/get values by column name.

| Function / Procedure | Description |
|----------------------|-------------|
| `SummarizedExperiment.AddRowDataCol(se: SE; name: ARRAY OF CHAR; VAR err: INTEGER): INTEGER` | Add a rowData column named `name`. Returns column index or -1. |
| `SummarizedExperiment.FindRowDataCol(se: SE; name: ARRAY OF CHAR): INTEGER` | Find a rowData column by name. |
| `SummarizedExperiment.SetRowDataStr(se: SE; r: INTEGER; colName, val: ARRAY OF CHAR; VAR err: INTEGER)` | Set a string cell in rowData. |
| `SummarizedExperiment.GetRowDataStr(se: SE; r: INTEGER; colName: ARRAY OF CHAR; VAR val: ARRAY OF CHAR; VAR err: INTEGER)` | Get a string cell from rowData. |
| `SummarizedExperiment.SetRowDataInt(se: SE; r: INTEGER; colName: ARRAY OF CHAR; val: INTEGER; VAR err: INTEGER)` | Set an integer cell in rowData. |
| `SummarizedExperiment.GetRowDataInt(se: SE; r: INTEGER; colName: ARRAY OF CHAR; VAR val: INTEGER; VAR err: INTEGER)` | Get an integer cell from rowData. |
| `SummarizedExperiment.SetRowDataReal(se: SE; r: INTEGER; colName: ARRAY OF CHAR; val: REAL; VAR err: INTEGER)` | Set a real cell in rowData. |
| `SummarizedExperiment.GetRowDataReal(se: SE; r: INTEGER; colName: ARRAY OF CHAR; VAR val: REAL; VAR err: INTEGER)` | Get a real cell from rowData. |
| `SummarizedExperiment.RowDataFrame(se: SE): DataFrame.DataFrame` | Return the underlying rowData DataFrame for direct access. |

### Column Metadata (colData)

Same API as rowData but indexed by sample column index `cix`.

| Function / Procedure | Description |
|----------------------|-------------|
| `SummarizedExperiment.AddColDataCol(se: SE; name: ARRAY OF CHAR; VAR err: INTEGER): INTEGER` | Add a colData column. |
| `SummarizedExperiment.FindColDataCol(se: SE; name: ARRAY OF CHAR): INTEGER` | Find a colData column by name. |
| `SummarizedExperiment.SetColDataStr(se: SE; cix: INTEGER; colName, val: ARRAY OF CHAR; VAR err: INTEGER)` | Set a string cell. |
| `SummarizedExperiment.GetColDataStr(se: SE; cix: INTEGER; colName: ARRAY OF CHAR; VAR val: ARRAY OF CHAR; VAR err: INTEGER)` | Get a string cell. |
| `SummarizedExperiment.SetColDataInt(se: SE; cix: INTEGER; colName: ARRAY OF CHAR; val: INTEGER; VAR err: INTEGER)` | Set an integer cell. |
| `SummarizedExperiment.GetColDataInt(se: SE; cix: INTEGER; colName: ARRAY OF CHAR; VAR val: INTEGER; VAR err: INTEGER)` | Get an integer cell. |
| `SummarizedExperiment.SetColDataReal(se: SE; cix: INTEGER; colName: ARRAY OF CHAR; val: REAL; VAR err: INTEGER)` | Set a real cell. |
| `SummarizedExperiment.GetColDataReal(se: SE; cix: INTEGER; colName: ARRAY OF CHAR; VAR val: REAL; VAR err: INTEGER)` | Get a real cell. |
| `SummarizedExperiment.ColDataFrame(se: SE): DataFrame.DataFrame` | Return the underlying colData DataFrame. |

### Metadata

| Function / Procedure | Description |
|----------------------|-------------|
| `SummarizedExperiment.MetadataPut(se: SE; key, value: ARRAY OF CHAR; VAR err: INTEGER)` | Store a key/value string pair in the SE's metadata dictionary. |
| `SummarizedExperiment.MetadataGet(se: SE; key: ARRAY OF CHAR; VAR value: ARRAY OF CHAR): BOOLEAN` | Retrieve a metadata value by key. Returns FALSE if not found. |

---

## Sixel - Sixel Graphics

```
IMPORT Sixel;
```

640 × 480 pixel buffer rendered as DEC Sixel graphics sequences on terminals that
support them (e.g. xterm, iTerm2, mlterm).  Pixels are addressed as palette color
indices (0–255).

### Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `Sixel.Width` | 640 | Buffer width in pixels |
| `Sixel.Height` | 480 | Buffer height in pixels |

### Procedures

| Procedure | Description |
|-----------|-------------|
| `Sixel.Init(w, h: INTEGER)` | Clear the pixel buffer and reset the palette to all-black. (`w` and `h` are accepted but the buffer is always 640 × 480.) |
| `Sixel.SetPalette(idx, r, g, b: INTEGER)` | Define palette entry `idx` (0–255) with RGB values in the range 0–255. Internally converts to Sixel's 0–100 range. |
| `Sixel.Plot(x, y, color: INTEGER)` | Set pixel at `(x, y)` to palette index `color`. |
| `Sixel.ClearBuf` | Fill the entire pixel buffer with color index 0. |
| `Sixel.Flush` | Encode the buffer as a Sixel stream and write it to stdout. |
| `Sixel.Line(x0, y0, x1, y1, color: INTEGER)` | Draw a Bresenham line from `(x0, y0)` to `(x1, y1)` using `Plot`. |

---

## Turtle - Turtle Graphics

```
IMPORT Turtle;
```

Logo-style turtle graphics drawn into the `Graphics` pixel buffer.  The canvas is
240 × 100 (matching `Graphics`).  The turtle starts at `(120, 50)` facing East
(angle 0), pen down, color 7.

### Types

| Type | Description |
|------|-------------|
| `Turtle.State` | Record holding the turtle's position and heading: `x, y, angle: REAL` |

### Procedures and Functions

| Procedure / Function | Description |
|----------------------|-------------|
| `Turtle.Init` | Clear the pixel buffer and reset the turtle to the center, facing East, pen down, color 7. |
| `Turtle.SetPos(x, y: REAL)` | Teleport the turtle to `(x, y)` without drawing. |
| `Turtle.Rotate(degrees: REAL)` | Set the absolute heading in degrees (0 = East, increases clockwise). |
| `Turtle.Right(degrees: REAL)` | Turn the turtle right (clockwise) by `degrees` relative to the current heading. |
| `Turtle.Forward(dist: REAL)` | Move the turtle forward by `dist` pixels. If the pen is down, draws a line. Clamps position to the canvas bounds. |
| `Turtle.GetX(): REAL` | Return the current X coordinate. |
| `Turtle.GetY(): REAL` | Return the current Y coordinate. |
| `Turtle.GetHeading(): REAL` | Return the current heading in degrees. |
| `Turtle.GetState(VAR s: Turtle.State)` | Capture the current position and heading into `s`. |
| `Turtle.RestoreState(s: Turtle.State)` | Restore position and heading from a previously saved state. |
| `Turtle.SetColor(c: INTEGER)` | Set the pen color (ANSI color index 1–7). |
| `Turtle.PenUp` | Lift the pen: `Forward` moves without drawing. |
| `Turtle.PenDown` | Lower the pen: `Forward` draws. |
| `Turtle.Update` | Flush the `Graphics` pixel buffer to the terminal. Call after each frame. |

---

## Menu - Text-based Popup Menu

```
IMPORT Menu;
```

Retro dBASE-style interactive menu.  Uses `Terminal` raw mode and `Graphics` for
rendering.

### Types

| Type | Description |
|------|-------------|
| `Menu.Option` | `ARRAY 64 OF CHAR` — a single menu item string |
| `Menu.MenuData` | Menu state record: `count: INTEGER; options: ARRAY 32 OF Option; fg, bg, highlightFg, highlightBg, width: INTEGER` |

### Procedures

| Procedure / Function | Description |
|----------------------|-------------|
| `Menu.Init(VAR m: MenuData)` | Initialize `m` with default colors (white text on blue, black-on-white highlight) and zero items. |
| `Menu.Add(VAR m: MenuData; text: ARRAY OF CHAR)` | Append an item. Automatically widens the menu box to fit. Maximum 32 items. |
| `Menu.Run(VAR m: MenuData; x, y: INTEGER): INTEGER` | Display the menu at `(x, y)` and run the selection loop.  Up/Down navigate; number keys jump directly; Enter confirms.  Returns the 0-based index of the selected item. |

---

## Base64 - Base64 Encoding

```
IMPORT Base64;
```

| Procedure | Description |
|-----------|-------------|
| `Base64.Encode(VAR src, dst: ARRAY OF CHAR)` | Encode the null-terminated string `src` to standard Base64 in `dst`.  Stops at the first null byte in `src`. |
| `Base64.EncodeBin(VAR src: ARRAY OF CHAR; n: INTEGER; VAR dst: ARRAY OF CHAR)` | Binary-safe variant: encode exactly `n` bytes from `src` (null bytes included) into `dst`. |

The output alphabet is `A–Z a–z 0–9 + /` with `=` padding.

---

## XHTML - HTML/XHTML Parsing Utilities

```
IMPORT XHTML;
```

| Procedure / Function | Description |
|----------------------|-------------|
| `XHTML.ToText(src: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR)` | Strip all HTML tags from `src` and write plain text to `dst`.  Block-level elements (`<p>`, `<br>`, `<div>`, `<li>`, headings, etc.) become newlines.  `<script>` and `<style>` bodies are removed entirely.  HTML entities are decoded to their nearest ASCII equivalent.  Consecutive whitespace collapses to a single space. |
| `XHTML.AttrValue(src: ARRAY OF CHAR; attr: ARRAY OF CHAR; VAR val: ARRAY OF CHAR): BOOLEAN` | Find the first occurrence of attribute `attr` (case-insensitive; supply in lowercase) anywhere in `src` and copy its quoted value into `val`.  Returns TRUE on success.  Useful for parsing OPF/container.xml fragments without a full XML parser. |

---

## NumberTheory - Number Theory Utilities

```
IMPORT NumberTheory;
```

| Function | Returns | Description |
|----------|---------|-------------|
| `NumberTheory.IsPrime(N: INTEGER): BOOLEAN` | BOOLEAN | TRUE if `N` is a prime number.  Uses trial division up to √N. |
| `NumberTheory.GCD(a, b: LONGINT): LONGINT` | LONGINT | Greatest common divisor of `a` and `b` via recursive Euclidean algorithm. |

---

## MathUtils - Simple Math Utilities

```
IMPORT MathUtils;
```

A small demonstration module with a call counter.

### Constants and Variables

| Name | Type | Description |
|------|------|-------------|
| `MathUtils.MaxVal` | INTEGER constant | Compile-time constant with value 1000 |
| `MathUtils.CallCount` | INTEGER variable | Running count of `Square` and `Cube` calls; starts at 0 |

### Procedures

| Function / Procedure | Description |
|----------------------|-------------|
| `MathUtils.Square(n: INTEGER): INTEGER` | Return `n * n`.  Increments `CallCount`. |
| `MathUtils.Cube(n: INTEGER): INTEGER` | Return `n * n * n`.  Increments `CallCount`. |
| `MathUtils.PrintInfo()` | Print `"MathUtils loaded. MaxVal = 1000"` to stdout. |
