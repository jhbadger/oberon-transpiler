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
