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
| `FREE(VAR p: Pointer)` | Free heap memory allocated by `NEW` and set `p` to `NIL`. |
| `HALT(code: INTEGER)` | Terminate program with exit code `code`. |
| `ASSERT(cond: BOOLEAN)` | Abort with a C `assert` failure if `cond` is FALSE. |
| `INCL(VAR s: SET; x: INTEGER)` | Include element `x` in set `s` (`s \|= 1u << x`). |
| `EXCL(VAR s: SET; x: INTEGER)` | Exclude element `x` from set `s` (`s &= ~(1u << x)`). |
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
| `CAP(c: CHAR)` | CHAR | Uppercase equivalent of `c` (uses C `toupper`). |
| `FLOOR(x: REAL)` | INTEGER | Largest integer not greater than `x` (uses C `floor`, cast to `int`). |
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

### Color and Drawing

| Procedure | Description |
|-----------|-------------|
| `Terminal.Color(fg, bg: INTEGER)` | Set foreground / background using standard ANSI color indices 0-7. |
| `Terminal.Color256(fg, bg: INTEGER)` | Set foreground / background using 256-color indices 0-255. |
| `Terminal.Reset()` | Reset all color/style attributes. |
| `Terminal.Fill(x, y, w, h: INTEGER; ch: CHAR)` | Fill a rectangle of `w` x `h` cells at `(x, y)` with character `ch`. |
| `Terminal.HLine(x, y, len: INTEGER; ch: CHAR)` | Draw a horizontal line of `len` copies of `ch` starting at `(x, y)`. |
| `Terminal.VLine(x, y, len: INTEGER; ch: CHAR)` | Draw a vertical line of `len` copies of `ch` starting at `(x, y)`. |
| `Terminal.Box(x, y, w, h: INTEGER)` | Draw a box using Unicode box-drawing characters. |
| `Terminal.Sprite(x, y: INTEGER; s: ARRAY OF CHAR; color: INTEGER)` | Draw multi-line string `s` at `(x, y)` with ANSI color `color`. Newlines advance to the next row at column `x`. |

### Pixel Buffer

A 240 x 100 logical pixel grid rendered via half-block characters (two vertical pixels per terminal cell).
Colors are xterm-256 indices 1-255 (0 = transparent/off).  Call `Terminal.Flush` to render.

| Procedure | Description |
|-----------|-------------|
| `Terminal.ClearBuf()` | Clear the pixel buffer (all pixels off). |
| `Terminal.Plot(x, y, color: INTEGER)` | Set pixel at `(x, y)` to `color`. |
| `Terminal.Circle(cx, cy, r, color: INTEGER)` | Draw a circle outline using Bresenham's algorithm. |
| `Terminal.FillCircle(cx, cy, r, color: INTEGER)` | Draw a filled circle using Bresenham scan-fill. |
| `Terminal.Line(x0, y0, x1, y1, color: INTEGER)` | Draw a line between `(x0, y0)` and `(x1, y1)` using Bresenham's algorithm. |
| `Terminal.FillBuf(color: INTEGER)` | Fill the entire pixel buffer with `color`. |
| `Terminal.RGBColor(r, g, b: INTEGER): INTEGER` | Map an RGB triple (0–255 each) to the nearest xterm-256 color index. |
| `Terminal.Flush()` | Render the pixel buffer to the terminal using half-block characters. |

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

Logo-style turtle graphics drawn into the \`Terminal\` pixel buffer.  The canvas is
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

## Parallel - Multi-core Parallel Loops

```
IMPORT Parallel;
```

Runs loop bodies in parallel using POSIX threads.  Links with `-lpthread` on Linux.

| Function / Procedure | Description |
|----------------------|-------------|
| `Parallel.NumCPU(): INTEGER` | Return the number of logical CPU cores available (from `sysconf(_SC_NPROCESSORS_ONLN)`). Use this to pick a sensible thread count. |
| `Parallel.SetMaxCPU(n: INTEGER)` | Cap the number of threads used by subsequent `Parallel.For` calls to `n`.  Requests with `nthreads` > `n` are silently clamped.  Pass 0 to remove the cap.  Useful on shared systems to avoid starving other processes. |
| `Parallel.For(lo, hi, body: PROCEDURE(INTEGER); nthreads: INTEGER)` | Call `body(i)` for every integer `i` in `[lo, hi)`, using up to `nthreads` threads.  The calls are unordered and may run concurrently.  Returns only after all iterations complete.  `body` must be a module-level procedure (not a nested procedure). |

**Thread-safety rules:** Each worker invocation receives a unique `i`, so writing to arrays indexed by `i` is safe without locks.  Any shared state accessed inside `body` must be read-only, or protected externally.  The standard library allocator (`NEW`) is thread-safe.

---

## BioAlpha - Biological Sequence Alphabets

```
IMPORT BioAlpha;
```

Defines named alphabets (DNA, RNA, protein) used by the other Bio modules.  All character tests are **case-sensitive**; call `BioAlpha.ToUpper` before querying if your data may be lowercase.

### Types

| Type | Description |
|------|-------------|
| `BioAlpha.Alphabet` | Record holding a set of valid characters with complement mappings and ranked symbol list.  Field `size: INTEGER` = number of valid symbols. |

### Pre-built Alphabets

| Procedure | Description |
|-----------|-------------|
| `BioAlpha.DNA(VAR a: Alphabet)` | Initialise `a` as the DNA alphabet: `A C G T`.  Complements: A↔T, C↔G. |
| `BioAlpha.DNAIUPAC(VAR a: Alphabet)` | Initialise `a` as the IUPAC DNA alphabet including ambiguity codes (R, Y, S, W, K, M, B, D, H, V, N). |
| `BioAlpha.RNA(VAR a: Alphabet)` | Initialise `a` as the RNA alphabet: `A C G U`.  Complements: A↔U, C↔G. |
| `BioAlpha.Protein(VAR a: Alphabet)` | Initialise `a` as the 20-letter protein alphabet.  No complements defined. |

### Alphabet Construction

| Procedure | Description |
|-----------|-------------|
| `BioAlpha.Clear(VAR a: Alphabet)` | Reset `a` to an empty alphabet (no valid symbols). |
| `BioAlpha.Add(VAR a: Alphabet; c, complement: CHAR)` | Mark `c` as valid and set its complement to `complement`.  Pass `0X` as `complement` if no complement is defined. |

### Character Queries

| Function | Returns | Description |
|----------|---------|-------------|
| `BioAlpha.IsValid(VAR a: Alphabet; c: CHAR): BOOLEAN` | BOOLEAN | TRUE if `c` is a valid character in alphabet `a`. |
| `BioAlpha.Complement(VAR a: Alphabet; c: CHAR): CHAR` | CHAR | Complement of `c` in `a`.  Returns `0X` if no complement is defined. |
| `BioAlpha.Rank(VAR a: Alphabet; c: CHAR): INTEGER` | INTEGER | 0-based rank (insertion order) of `c` in `a`.  Returns -1 if `c` is not valid. |
| `BioAlpha.Symbol(VAR a: Alphabet; rank: INTEGER): CHAR` | CHAR | The symbol at position `rank` in `a`.  Returns `0X` if out of range. |
| `BioAlpha.ToUpper(c: CHAR): CHAR` | CHAR | Uppercase version of `c` (ASCII only). |
| `BioAlpha.Matches(VAR a: Alphabet; query, ref: CHAR): BOOLEAN` | BOOLEAN | TRUE if `query` matches `ref` under IUPAC ambiguity rules.  For non-IUPAC alphabets this is equivalent to `query = ref`. |

### Convenience Predicates (alphabet-independent)

| Function | Returns | Description |
|----------|---------|-------------|
| `BioAlpha.IsDNABase(c: CHAR): BOOLEAN` | BOOLEAN | TRUE if `c` is one of `A C G T a c g t`. |
| `BioAlpha.IsRNABase(c: CHAR): BOOLEAN` | BOOLEAN | TRUE if `c` is one of `A C G U a c g u`. |
| `BioAlpha.IsAmbiguous(c: CHAR): BOOLEAN` | BOOLEAN | TRUE if `c` is an IUPAC ambiguity code other than `N`. |
| `BioAlpha.IUPACBits(c: CHAR): INTEGER` | INTEGER | 4-bit IUPAC encoding of `c` (A=1, C=2, G=4, T=8, combinations for ambiguous bases). |

| Procedure | Description |
|-----------|-------------|
| `BioAlpha.Print(VAR a: Alphabet)` | Print the symbol list and complement table to stdout. |

---

## BioSeq - Biological Sequence Storage

```
IMPORT BioSeq;
```

Heap-allocated linked-list sequence type for sequences that are too long to fit in an Oberon string.  All positions are **0-based**.

### Types

| Type | Description |
|------|-------------|
| `BioSeq.Seq` | `POINTER TO SeqRec` — the sequence handle.  Fields: `length: INTEGER` (total char count), `name: ARRAY 128 OF CHAR`. |

### Lifecycle

| Procedure | Description |
|-----------|-------------|
| `BioSeq.New(VAR s: Seq)` | Allocate a new empty sequence.  Must be called before use. |
| `BioSeq.Free(VAR s: Seq)` | Free all storage and set `s` to NIL. |

### Building and Modifying

| Procedure | Description |
|-----------|-------------|
| `BioSeq.Append(s: Seq; buf: ARRAY OF CHAR; n: INTEGER)` | Append the first `n` characters of `buf` to `s`. |
| `BioSeq.FromStr(s: Seq; str: ARRAY OF CHAR)` | Replace the contents of `s` with the null-terminated string `str`. |
| `BioSeq.ToUpper(s: Seq)` | Convert all characters to uppercase in place. |
| `BioSeq.ToLower(s: Seq)` | Convert all characters to lowercase in place. |

### Random Access and Extraction

| Function / Procedure | Description |
|----------------------|-------------|
| `BioSeq.Get(s: Seq; pos: INTEGER): CHAR` | Return the character at position `pos` (0-based). |
| `BioSeq.Slice(s: Seq; start, len: INTEGER; VAR buf: ARRAY OF CHAR)` | Copy `len` characters starting at `start` into `buf`.  Null-terminates if space allows; never writes past `LEN(buf)-1`. |
| `BioSeq.Length(s: Seq): INTEGER` | Total number of characters in `s`. |
| `BioSeq.ToStr(s: Seq; VAR str: ARRAY OF CHAR)` | Copy the entire sequence into `str`.  Truncates at `LEN(str)-1`. |

### Sequence Analysis

| Function / Procedure | Description |
|----------------------|-------------|
| `BioSeq.Count(s: Seq; ch: CHAR): INTEGER` | Count occurrences of character `ch` in `s`. |
| `BioSeq.IsNucleotide(s: Seq): BOOLEAN` | Heuristic: returns TRUE if more than 90% of the first 200 characters are `A C G T U N` (or lowercase). |
| `BioSeq.GCContent(s: Seq): REAL` | Fraction of characters that are G or C (0.0–1.0).  Returns 0.0 for an empty sequence. |
| `BioSeq.Equal(a, b: Seq): BOOLEAN` | TRUE if `a` and `b` have the same length and identical characters. |
| `BioSeq.RevComp(s: Seq; VAR a: BioAlpha.Alphabet; dst: Seq)` | Write the reverse complement of `s` (using alphabet `a`) into `dst`.  `dst` must already exist (call `BioSeq.New` first). |

| Procedure | Description |
|-----------|-------------|
| `BioSeq.Print(s: Seq)` | Print the sequence to stdout. |

---

## BioIO - Biological File I/O

```
IMPORT BioIO;
```

Readers and writers for FASTA, FASTQ, and BED files.  Transparently decompresses `.gz` files via `gunzip -c` and a temporary file; the temp path is cleaned up on close.  Set a sequence field to `NIL` before the first read so the reader allocates it.

### Types

| Type | Public fields | Description |
|------|---------------|-------------|
| `BioIO.FastaRecord` | `name: ARRAY 128 OF CHAR; desc: ARRAY 256 OF CHAR; seq: BioSeq.Seq` | One FASTA record. |
| `BioIO.FastqRecord` | `name: ARRAY 128 OF CHAR; seq: BioSeq.Seq; qual: BioSeq.Seq` | One FASTQ record; `qual` holds Phred quality scores as ASCII characters. |
| `BioIO.BedRecord` | `chrom: ARRAY 64 OF CHAR; start, end_, score: INTEGER; name: ARRAY 64 OF CHAR; strand: CHAR` | One BED record.  `start` is 0-based, `end_` is exclusive. |
| `BioIO.FastaReader` | `done: BOOLEAN` | State for an open FASTA file.  Check `done` to detect errors after `ReadFasta` returns FALSE. |
| `BioIO.FastqReader` | `done: BOOLEAN` | State for an open FASTQ file. |
| `BioIO.BedReader` | `done: BOOLEAN` | State for an open BED file. |

### FASTA

| Procedure / Function | Description |
|----------------------|-------------|
| `BioIO.OpenFasta(VAR r: FastaReader; path: ARRAY OF CHAR): BOOLEAN` | Open the FASTA file at `path` (`.gz` ok).  Returns TRUE on success.  Sets `r.done` on failure. |
| `BioIO.ReadFasta(VAR r: FastaReader; VAR rec: FastaRecord): BOOLEAN` | Read the next record into `rec`.  Returns FALSE at EOF or on error.  Set `rec.seq := NIL` before the first call so it is heap-allocated. |
| `BioIO.CloseFasta(VAR r: FastaReader)` | Close the reader and delete any temporary file. |
| `BioIO.WriteFasta(VAR r: Files.Rider; VAR rec: FastaRecord; width: INTEGER)` | Write `rec` to rider `r` as FASTA with `width` characters per line (0 = no line-wrapping). |

### FASTQ

| Procedure / Function | Description |
|----------------------|-------------|
| `BioIO.OpenFastq(VAR r: FastqReader; path: ARRAY OF CHAR): BOOLEAN` | Open the FASTQ file at `path` (`.gz` ok). |
| `BioIO.ReadFastq(VAR r: FastqReader; VAR rec: FastqRecord): BOOLEAN` | Read the next record.  Set `rec.seq := NIL; rec.qual := NIL` before the first call. |
| `BioIO.CloseFastq(VAR r: FastqReader)` | Close the reader and delete any temporary file. |
| `BioIO.WriteFastq(VAR r: Files.Rider; VAR rec: FastqRecord)` | Write `rec` to rider `r` in four-line FASTQ format. |

### BED

| Procedure / Function | Description |
|----------------------|-------------|
| `BioIO.OpenBed(VAR r: BedReader; path: ARRAY OF CHAR): BOOLEAN` | Open the BED file at `path` (`.gz` ok). |
| `BioIO.ReadBed(VAR r: BedReader; VAR rec: BedRecord): BOOLEAN` | Read the next BED record. |
| `BioIO.CloseBed(VAR r: BedReader)` | Close the reader and delete any temporary file. |
| `BioIO.WriteBed(VAR r: Files.Rider; VAR rec: BedRecord)` | Write one BED line to rider `r`. |

**Typical FASTA reading pattern:**
```oberon
VAR rdr: BioIO.FastaReader;  rec: BioIO.FastaRecord;
IF BioIO.OpenFasta(rdr, "seqs.fa.gz") THEN
  rec.seq := NIL;
  WHILE BioIO.ReadFasta(rdr, rec) DO
    (* use rec.name, rec.seq *)
  END;
  BioIO.CloseFasta(rdr)
END
```

---

## BioAlign - Pairwise Sequence Alignment

```
IMPORT BioAlign;
```

Needleman-Wunsch (global), Smith-Waterman (local), semi-global, edit distance, and Hamming distance.  The DP-based aligners use affine gap penalties.

### Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `BioAlign.MaxSeqLen` | 10000 | Maximum query or reference length. |
| `BioAlign.MaxCigar` | 8192 | Maximum CIGAR operations in one alignment. |
| `BioAlign.opMatch` | 0 | CIGAR: matched pair (identical bases). |
| `BioAlign.opIns` | 1 | CIGAR: insertion into query (gap in reference). |
| `BioAlign.opDel` | 2 | CIGAR: deletion from query (gap in query). |
| `BioAlign.opSubst` | 3 | CIGAR: substitution (mismatched pair). |

### Types

| Type | Public fields | Description |
|------|---------------|-------------|
| `BioAlign.ScoreMatrix` | `match_, mismatch, gapOpen, gapExt: INTEGER; useTable: BOOLEAN; table: ARRAY 26 OF ARRAY 26 OF INTEGER` | Scoring parameters.  When `useTable = TRUE`, `table[ORD(a)-ORD('A')][ORD(b)-ORD('A')]` is used for letter pairs. |
| `BioAlign.CigarEntry` | `op, len: INTEGER` | One run in the CIGAR string: `op` is one of the `op*` constants, `len` is the run length. |
| `BioAlign.Alignment` | `score, qStart, qEnd, rStart, rEnd, nOps: INTEGER; identity: REAL; cigar: ARRAY MaxCigar OF CigarEntry` | Result of an alignment.  `identity` = fraction of aligned positions that are exact matches. |
| `BioAlign.DPState` | *(opaque)* | Per-worker DP workspace for `GlobalW`.  Declare as a VAR; zero-initialised globals work without explicit init. |

### Score Matrix Setup

| Procedure | Description |
|-----------|-------------|
| `BioAlign.DefaultScore(VAR m: ScoreMatrix)` | Match=+1, mismatch=-1, gapOpen=-5, gapExt=-1.  Suitable for DNA. |
| `BioAlign.BLOSUM62(VAR m: ScoreMatrix)` | BLOSUM62 protein matrix; gapOpen=-11, gapExt=-1. |
| `BioAlign.PAM250(VAR m: ScoreMatrix)` | PAM250 (Dayhoff) protein matrix; gapOpen=-12, gapExt=-2. |
| `BioAlign.PairScore(VAR m: ScoreMatrix; a, b: CHAR): INTEGER` | Return the substitution score for characters `a` and `b` under matrix `m`. |

### Alignment

| Procedure | Description |
|-----------|-------------|
| `BioAlign.Global(q, r: BioSeq.Seq; VAR m: ScoreMatrix; VAR aln: Alignment)` | Needleman-Wunsch global alignment.  Uses shared module-level DP matrices — **not thread-safe**; use `GlobalW` in parallel code. |
| `BioAlign.GlobalW(q, r: BioSeq.Seq; VAR m: ScoreMatrix; VAR aln: Alignment; VAR s: DPState)` | Thread-safe global alignment using caller-supplied DP workspace `s`.  Each parallel worker should have its own `DPState`. |
| `BioAlign.Local(q, r: BioSeq.Seq; VAR m: ScoreMatrix; VAR aln: Alignment)` | Smith-Waterman local alignment.  Not thread-safe. |
| `BioAlign.SemiGlobal(q, r: BioSeq.Seq; VAR m: ScoreMatrix; VAR aln: Alignment)` | Semi-global alignment: query end-gaps are free; reference end-gaps are penalised.  Not thread-safe. |
| `BioAlign.EditDistance(q, r: BioSeq.Seq): INTEGER` | Levenshtein edit distance.  O(n·m) time, O(n) space.  Thread-safe (uses module-level row buffers shared across calls). |
| `BioAlign.HammingDistance(q, r: BioSeq.Seq): INTEGER` | Hamming distance (requires equal-length sequences).  Returns -1 if lengths differ.  Thread-safe. |
| `BioAlign.PrintAlignment(VAR aln: Alignment; q, r: BioSeq.Seq)` | Pretty-print `aln` to stdout in 60-column blocks showing query, bar, and reference. |

---

## BioAnnot - Genomic Interval Annotation

```
IMPORT BioAnnot;
```

Load and query genomic feature databases from BED or GFF3 files.  After `SortByPos`, overlap and containment queries use a per-chromosome index for O(1) chromosome lookup.

**Note:** `AnnotDB` is ~6.5 MB; declare it at module level, not as a local variable.

### Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `BioAnnot.MaxFeatures` | 16384 | Maximum features per database. |

### Types

| Type | Public fields | Description |
|------|---------------|-------------|
| `BioAnnot.Feature` | `chrom: ARRAY 64; start, end_: INTEGER; name: ARRAY 64; score: REAL; strand: CHAR; attrs: ARRAY 256` | One genomic feature.  `start` is 0-based, `end_` is exclusive.  `attrs` holds raw GFF3 attributes or is empty for BED. |
| `BioAnnot.AnnotDB` | `features: ARRAY MaxFeatures OF Feature; count: INTEGER; index: Dict.Table` | The feature database.  Use `index` via `SortByPos`; `count` is the current number of features. |

### Procedures

| Procedure / Function | Description |
|----------------------|-------------|
| `BioAnnot.Init(VAR db: AnnotDB)` | Clear the database (empty features, no index). |
| `BioAnnot.Add(VAR db: AnnotDB; VAR f: Feature): BOOLEAN` | Append one feature; returns FALSE if capacity is exceeded.  Invalidates the sort index. |
| `BioAnnot.LoadBed(VAR db: AnnotDB; path: ARRAY OF CHAR): INTEGER` | Load a BED file; returns count added, or -1 on file error.  Appends to existing features. |
| `BioAnnot.LoadGFF(VAR db: AnnotDB; path: ARRAY OF CHAR): INTEGER` | Load a GFF3 file; returns count added, or -1 on file error.  Converts 1-based GFF3 positions to 0-based. |
| `BioAnnot.SortByPos(VAR db: AnnotDB)` | Sort features by (chrom, start) and rebuild the chromosome index.  Must be called before `Overlaps`/`Contains` for indexed queries. |
| `BioAnnot.Overlaps(VAR db: AnnotDB; chrom: ARRAY OF CHAR; start, end_: INTEGER; VAR hits: ARRAY OF INTEGER; VAR n: INTEGER)` | Find all features in `db` on `chrom` that overlap `[start, end_)`.  Stores feature indices into `hits`; sets `n` to count found. |
| `BioAnnot.Contains(VAR db: AnnotDB; chrom: ARRAY OF CHAR; pos: INTEGER; VAR hits: ARRAY OF INTEGER; VAR n: INTEGER)` | Find all features that contain point `pos` (0-based). |
| `BioAnnot.Coverage(VAR db: AnnotDB; chrom: ARRAY OF CHAR; VAR depths: ARRAY OF INTEGER; n: INTEGER)` | Compute per-position coverage depth for the first `n` positions of `chrom` into `depths`. |

---

## BioFM - FM-Index

```
IMPORT BioFM;
```

Backward-search FM-index built over a `BioSeq`.  Supports exact pattern search, locate (map SA interval to text positions), and count.

**Note:** `FMIndex` is ~2.3 MB; declare it at module level, not as a local variable.

### Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `BioFM.OccSample` | 16 | Sampling rate for the occurrence table. |

### Types

| Type | Description |
|------|-------------|
| `BioFM.FMIndex` | The full index structure (embeds `BioSuffix.SuffixArray`, `BioSuffix.BWTResult`, a `LessTable`, and a sampled `OccTable`).  Field `n: INTEGER` = text length. |

### Procedures

| Procedure / Function | Description |
|----------------------|-------------|
| `BioFM.Build(text: BioSeq.Seq; VAR a: BioAlpha.Alphabet; VAR idx: FMIndex)` | Build the FM-index from `text` using alphabet `a`.  O(n log n). |
| `BioFM.BackwardSearch(VAR idx: FMIndex; pat: ARRAY OF CHAR; VAR lo, hi: INTEGER): BOOLEAN` | Search for `pat` in O(m).  On success, sets `[lo, hi)` to the SA interval of occurrences and returns TRUE.  Returns FALSE if `pat` is not present. |
| `BioFM.Locate(VAR idx: FMIndex; lo, hi: INTEGER; VAR positions: ARRAY OF INTEGER; VAR nPos: INTEGER)` | Convert SA interval `[lo, hi)` to text start positions.  Stores results in `positions` and count in `nPos`. |
| `BioFM.Count(VAR idx: FMIndex; pat: ARRAY OF CHAR): INTEGER` | Return the number of occurrences of `pat` in the text.  O(m). |

---

## BioORF - Open Reading Frame Detection

```
IMPORT BioORF;
```

Scan for ORFs and translate sequences using the standard or vertebrate mitochondrial genetic code.

**Note:** `ORFList` is ~96 KB; declare at module level.  The reverse-complement scratch buffer is not reentrant.

### Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `BioORF.MaxORFs` | 4096 | Maximum ORFs per `ORFList`. |

### Types

| Type | Public fields | Description |
|------|---------------|-------------|
| `BioORF.ORF` | `frame: INTEGER; start, end_, len: INTEGER; aa: BioSeq.Seq` | One ORF.  `frame` is 0/1/2 for forward, -1/-2/-3 for reverse-complement strands.  `start`/`end_` are 0-based positions in the original sequence.  `aa` is the translated amino acid sequence (stop codon omitted). |
| `BioORF.ORFList` | `orfs: ARRAY MaxORFs OF ORF; count: INTEGER` | Collection of ORFs. |

### Procedures

| Procedure / Function | Description |
|----------------------|-------------|
| `BioORF.UseStdCode` | Switch to NCBI standard genetic code (table 1).  Default at startup. |
| `BioORF.UseMitoCode` | Switch to vertebrate mitochondrial code (table 2): TGA→Trp, ATA→Met, AGA/AGG→Stop. |
| `BioORF.CodonToAA(codon: ARRAY OF CHAR): CHAR` | Translate a 3-character codon to its amino acid.  Returns `'*'` for stop codons, `'?'` for invalid input. |
| `BioORF.FindForward(seq: BioSeq.Seq; minLen: INTEGER; VAR result: ORFList)` | Find ORFs in frames 0, 1, 2 of the forward strand.  `minLen` is the minimum nucleotide length (including start and stop codons). |
| `BioORF.FindAll(seq: BioSeq.Seq; minLen: INTEGER; VAR result: ORFList)` | Find ORFs in all 6 reading frames (3 forward + 3 reverse-complement).  Reverse-strand coordinates are in the original sequence's space. |
| `BioORF.Translate(seq: BioSeq.Seq; frame: INTEGER; VAR aa: BioSeq.Seq)` | Translate the entire reading frame `frame` (0–2 forward; -1 to -3 sets the reverse-complement frame).  Stop codons become `'*'`. |
| `BioORF.PrintORFs(VAR result: ORFList)` | Print a summary table of all ORFs in `result` to stdout. |

---

## BioPattern - Sequence Pattern Matching

```
IMPORT BioPattern;
```

Exact (Boyer-Moore, KMP, Aho-Corasick) and approximate (Ukkonen) pattern matching on `BioSeq` sequences.  All searches populate a caller-supplied `HitList`.

**Note:** `ACState` is ~2 MB; declare it at module level.

### Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `BioPattern.MaxHits` | 65536 | Maximum hits per search. |
| `BioPattern.MaxACNodes` | 4096 | Maximum Aho-Corasick automaton nodes. |
| `BioPattern.MaxACPat` | 64 | Maximum patterns per Aho-Corasick state. |

### Types

| Type | Public fields | Description |
|------|---------------|-------------|
| `BioPattern.Hit` | `pos, len, dist: INTEGER` | One match: `pos` = 0-based start in text, `len` = pattern length, `dist` = edit distance (0 for exact). |
| `BioPattern.HitList` | `hits: ARRAY MaxHits OF Hit; count: INTEGER` | Collection of hits. |
| `BioPattern.BMState` | `pattern: ARRAY 256; patLen: INTEGER` | Precomputed Boyer-Moore tables for one pattern. |
| `BioPattern.KMPState` | `pattern: ARRAY 256; patLen: INTEGER` | Precomputed KMP failure function. |
| `BioPattern.ACState` | `nNodes, nPat: INTEGER` | Aho-Corasick automaton (multi-pattern). |

### Boyer-Moore (single pattern, exact)

| Procedure | Description |
|-----------|-------------|
| `BioPattern.BMBuild(VAR st: BMState; pat: ARRAY OF CHAR)` | Precompute bad-character and good-suffix tables for `pat` (max 255 chars). |
| `BioPattern.BMSearch(VAR st: BMState; text: BioSeq.Seq; VAR hits: HitList)` | Search `text` for all occurrences of the pattern.  Average O(n/m). |

### Knuth-Morris-Pratt (single pattern, exact)

| Procedure | Description |
|-----------|-------------|
| `BioPattern.KMPBuild(VAR st: KMPState; pat: ARRAY OF CHAR)` | Precompute the KMP failure function for `pat`. |
| `BioPattern.KMPSearch(VAR st: KMPState; text: BioSeq.Seq; VAR hits: HitList)` | Search `text` in O(n + m). |

### Aho-Corasick (multi-pattern, exact)

| Procedure | Description |
|-----------|-------------|
| `BioPattern.ACBuild(VAR st: ACState)` | Initialise an empty Aho-Corasick state. |
| `BioPattern.ACAdd(VAR st: ACState; pat: ARRAY OF CHAR)` | Add pattern `pat` to the automaton (before `ACFinalize`). |
| `BioPattern.ACFinalize(VAR st: ACState)` | Build failure and output links.  Must be called after all `ACAdd` calls and before `ACSearch`. |
| `BioPattern.ACSearch(VAR st: ACState; text: BioSeq.Seq; VAR hits: HitList)` | Search `text` for all patterns simultaneously in O(n + total_pattern_len + hits). |

### Ukkonen (approximate, single pattern)

| Procedure | Description |
|-----------|-------------|
| `BioPattern.Ukkonen(pat: ARRAY OF CHAR; text: BioSeq.Seq; maxDist: INTEGER; VAR hits: HitList)` | Find all substrings of `text` that match `pat` with at most `maxDist` edits.  O(n·m) DP. |

---

## BioQGram - Q-gram Index

```
IMPORT BioQGram;
```

Fast approximate sequence matching via a q-gram index.  Build the index once, then run exact or approximate queries.

**Note:** `QGramIndex` is ~512 KB; declare it at module level.

### Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `BioQGram.MaxQ` | 8 | Maximum q-gram size. |
| `BioQGram.MaxBuckets` | 65536 | Number of hash buckets. |

### Types

| Type | Description |
|------|-------------|
| `BioQGram.QGramIndex` | The index structure.  Fields: `q: INTEGER` (gram size), `textLen: INTEGER`, `nPos: INTEGER` (total positions indexed). |

### Procedures

| Procedure | Description |
|-----------|-------------|
| `BioQGram.Build(text: BioSeq.Seq; q: INTEGER; VAR idx: QGramIndex)` | Build an index of all `q`-grams in `text`.  O(n) time. |
| `BioQGram.Query(VAR idx: QGramIndex; qgram: ARRAY OF CHAR; VAR positions: ARRAY OF INTEGER; VAR n: INTEGER)` | Return all text positions that share the hash of `qgram`.  O(1) lookup; hash collisions are possible — callers should verify matches. |
| `BioQGram.ApproxSearch(VAR idx: QGramIndex; pat: ARRAY OF CHAR; maxDist: INTEGER; VAR hits: BioPattern.HitList)` | Pigeonhole filter: find candidate start positions where `pat` matches with ≤ `maxDist` edits.  Returns `dist=0` hits (positions to verify); call `BioPattern.Ukkonen` to confirm edit distance. |

---

## BioStats - Bioinformatics Statistics

```
IMPORT BioStats;
```

Log-probability arithmetic, combinatorics, Phred quality scores, common distributions, and multiple-testing corrections.

### Variable

| Variable | Description |
|----------|-------------|
| `BioStats.LogZero` | Sentinel value for log(0) = −∞ (initialised to −1.0×10³⁰⁸). |

### Phred Quality Scores

| Function | Returns | Description |
|----------|---------|-------------|
| `BioStats.PhredToProb(q: INTEGER): REAL` | REAL | Error probability for Phred score `q`: 10^(−q/10). |
| `BioStats.ProbToPhred(p: REAL): INTEGER` | INTEGER | Phred score for error probability `p`: floor(−10 log₁₀ p), clamped to [0, 93]. |

### Log-probability Arithmetic

| Function | Returns | Description |
|----------|---------|-------------|
| `BioStats.LogAdd(a, b: REAL): REAL` | REAL | log(exp(a) + exp(b)) computed without overflow. |
| `BioStats.LogSum(arr: ARRAY OF REAL; n: INTEGER): REAL` | REAL | log(Σ exp(arr[i])) for i in 0..n−1. |

### Combinatorics

| Function | Returns | Description |
|----------|---------|-------------|
| `BioStats.LogFactorial(n: INTEGER): REAL` | REAL | ln(n!).  Exact for n ≤ 20; Stirling approximation with 1/(12n) correction for n > 20. |
| `BioStats.Factorial(n: INTEGER): REAL` | REAL | n! as a REAL.  Overflows for large n. |
| `BioStats.LogBinomial(n, k: INTEGER): REAL` | REAL | ln of the binomial coefficient C(n, k). |
| `BioStats.Binomial(n, k: INTEGER): REAL` | REAL | Binomial coefficient C(n, k) as a REAL. |
| `BioStats.BinomialProb(n, k: INTEGER; p: REAL): REAL` | REAL | P(X = k) for X ~ Binomial(n, p). |
| `BioStats.PoissonProb(lambda: REAL; k: INTEGER): REAL` | REAL | P(X = k) for X ~ Poisson(λ). |

### Distributions

| Function | Returns | Description |
|----------|---------|-------------|
| `BioStats.NormalPDF(x, mu, sigma: REAL): REAL` | REAL | Normal (Gaussian) probability density at `x`. |
| `BioStats.NormalCDF(x, mu, sigma: REAL): REAL` | REAL | Cumulative normal distribution at `x` (A&S 7.1.26 approximation; max error ~1.5×10⁻⁷). |
| `BioStats.FisherExact(a, b, c, d: INTEGER): REAL` | REAL | Two-tailed Fisher's exact test p-value for a 2×2 contingency table. |

### Multiple-testing Correction

| Procedure | Description |
|-----------|-------------|
| `BioStats.BonferroniAdj(VAR pvals: ARRAY OF REAL; n: INTEGER)` | Multiply each of the first `n` p-values by `n` (Bonferroni), clamped to 1. In-place. |
| `BioStats.BHAdj(VAR pvals: ARRAY OF REAL; n: INTEGER)` | Benjamini-Hochberg FDR step-down adjustment (1995).  Rewrites the first `n` entries of `pvals` in-place.  Not reentrant. |

---

## BioSuffix - Suffix Array and BWT

```
IMPORT BioSuffix;
```

Build and query a suffix array, Burrows-Wheeler Transform, LCP array, and binary search index over a `BioSeq`.

**Note:** All procedures share module-level scratch arrays and are not reentrant.

### Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `BioSuffix.MaxSALen` | 65536 | Maximum sequence length supported (including sentinel). |

### Types

| Type | Public fields | Description |
|------|---------------|-------------|
| `BioSuffix.SuffixArray` | `sa: ARRAY MaxSALen OF INTEGER; n: INTEGER` | The suffix array.  `n = text_length + 1` (includes the sentinel). |
| `BioSuffix.BWTResult` | `bwt: ARRAY MaxSALen OF CHAR; n, eof: INTEGER` | BWT of the text.  `eof` = position of the sentinel row. |

### Procedures

| Procedure / Function | Description |
|----------------------|-------------|
| `BioSuffix.Build(text: BioSeq.Seq; VAR sa: SuffixArray)` | Build the suffix array using prefix-doubling O(n log n).  Appends a `0X` sentinel; `sa.n` = text length + 1. |
| `BioSuffix.BWT(text: BioSeq.Seq; VAR sa: SuffixArray; VAR bwt: BWTResult)` | Compute the BWT from an already-built suffix array.  O(n). |
| `BioSuffix.InverseBWT(VAR bwt: BWTResult; VAR text: BioSeq.Seq)` | Reconstruct the original text from its BWT using LF-mapping.  `text` must already exist (`BioSeq.New`). |
| `BioSuffix.LCP(text: BioSeq.Seq; VAR sa: SuffixArray; VAR lcp: ARRAY OF INTEGER)` | Compute the LCP array (Kasai's algorithm).  `lcp[i]` = length of the longest common prefix of suffixes `sa[i-1]` and `sa[i]`. |
| `BioSuffix.Search(text: BioSeq.Seq; VAR sa: SuffixArray; pat: ARRAY OF CHAR; VAR lo, hi: INTEGER): BOOLEAN` | Binary search for `pat` in O(m log n).  Sets `[lo, hi)` to the SA interval and returns TRUE if found. |

---

## BioVCF - VCF Variant Call Format

```
IMPORT BioVCF;
```

Reader for VCF 4.x files (plain text; bgzipped is not supported).  Skips `##`-header lines, reads sample names from the `#CHROM` line, and yields one record per data line.

### Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `BioVCF.MaxAlts` | 8 | Maximum alternate alleles per record. |
| `BioVCF.MaxSamples` | 128 | Maximum genotyped samples per file. |

### Types

| Type | Public fields | Description |
|------|---------------|-------------|
| `BioVCF.VCFRecord` | `chrom: ARRAY 64; pos: INTEGER; id, ref, alt: ARRAY 64; alts: ARRAY MaxAlts OF ARRAY 64; nAlts: INTEGER; qual: REAL; filter: ARRAY 64; info: ARRAY 512; format: ARRAY 128; gts: ARRAY MaxSamples OF ARRAY 64; nGTs: INTEGER` | One VCF data line.  `pos` is 0-based (converted from 1-based).  `alt` holds the first alternate allele; `alts` holds all alleles. |
| `BioVCF.VCFReader` | `done: BOOLEAN; samples: ARRAY MaxSamples OF ARRAY 64; nSamples: INTEGER` | Reader state.  `samples` is populated from the `#CHROM` header line. |

### Procedures

| Procedure / Function | Description |
|----------------------|-------------|
| `BioVCF.OpenVCF(VAR r: VCFReader; path: ARRAY OF CHAR): BOOLEAN` | Open the VCF file and parse sample names.  Returns TRUE on success. |
| `BioVCF.ReadVCF(VAR r: VCFReader; VAR rec: VCFRecord): BOOLEAN` | Read the next data record into `rec`.  Returns FALSE at EOF or on error. |
| `BioVCF.CloseVCF(VAR r: VCFReader)` | Close the file. |
| `BioVCF.WriteVCF(VAR wr: Files.Rider; VAR rec: VCFRecord)` | Write one VCF data line (no header) to rider `wr`. |

---

## BioPDB - Protein Data Bank File I/O

```
IMPORT BioPDB;
```

Parses ATOM and HETATM records from PDB-format files (plain or `.gz`).  Supports multi-model files (NMR ensembles, MD trajectories).  Also parses HELIX/SHEET records for secondary-structure annotation and can write models back to PDB format.

### Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `BioPDB.MaxAtoms` | 8192 | Maximum atoms per model. |
| `BioPDB.MaxChains` | 26 | Maximum chain IDs tracked. |
| `BioPDB.MaxSSRes` | 20000 | Maximum residues tracked in the secondary-structure table per model. |
| `BioPDB.ErrNone` | 0 | No error. |
| `BioPDB.ErrFileOpen` | 1 | File could not be opened (or requested model number not found). |
| `BioPDB.ErrTooManyAtoms` | 2 | Atom count exceeded `MaxAtoms`. |
| `BioPDB.SSCoil` | 0 | Secondary structure: coil / unassigned. |
| `BioPDB.SSHelix` | 1 | Secondary structure: alpha helix. |
| `BioPDB.SSSheet` | 2 | Secondary structure: beta sheet. |

### Types

| Type | Public fields | Description |
|------|---------------|-------------|
| `BioPDB.SSEntry` | `chain: CHAR; resSeq: INTEGER; ss: INTEGER` | One secondary-structure assignment (one residue). |
| `BioPDB.Atom` | `serial: INTEGER; name: ARRAY 5; altLoc: CHAR; resName: ARRAY 4; chainID: CHAR; resSeq: INTEGER; iCode: CHAR; x, y, z: REAL; occupancy, tempFactor: REAL; element: ARRAY 3; isHet: BOOLEAN` | One ATOM or HETATM record.  `isHet` is TRUE for HETATM lines. |
| `BioPDB.Model` | `atoms: ARRAY MaxAtoms OF Atom; count: INTEGER; minX, maxX, minY, maxY, minZ, maxZ: REAL; cx, cy, cz: REAL; ssMap: ARRAY MaxSSRes OF SSEntry; ssCount: INTEGER` | A loaded model.  Bounding box and centroid are computed on load.  `ssMap` holds secondary-structure assignments parsed from HELIX/SHEET records. |
| `BioPDB.PDBReader` | `done: BOOLEAN` | Streaming reader for multi-model files.  Use `OpenPDB` / `ReadModel` / `ClosePDB`. |

### Procedures

| Procedure / Function | Description |
|----------------------|-------------|
| `BioPDB.Load(path: ARRAY OF CHAR; VAR m: Model; VAR err: INTEGER): BOOLEAN` | Load the first model (or entire file if no MODEL records) into `m`.  Returns TRUE on success; sets `err` to an `Err*` constant. |
| `BioPDB.LoadModel(path: ARRAY OF CHAR; VAR m: Model; modelNo: INTEGER; VAR err: INTEGER): BOOLEAN` | Load a specific 1-based model number into `m`.  For files without MODEL records, `modelNo = 1` is equivalent to `Load`. |
| `BioPDB.LookupSS(VAR m: Model; chain: CHAR; resSeq: INTEGER): INTEGER` | Return the secondary-structure code (`SSCoil`, `SSHelix`, or `SSSheet`) for the given chain and residue sequence number.  Returns `SSCoil` if not found. |
| `BioPDB.OpenPDB(VAR r: PDBReader; path: ARRAY OF CHAR): BOOLEAN` | Open a PDB file for streaming model-by-model access.  Returns TRUE on success. |
| `BioPDB.ReadModel(VAR r: PDBReader; VAR m: Model; VAR err: INTEGER): BOOLEAN` | Read the next model into `m`.  Returns FALSE at EOF or on error.  Secondary-structure data parsed at open time is copied into each model automatically. |
| `BioPDB.ClosePDB(VAR r: PDBReader)` | Close the streaming reader and clean up any temporary decompressed file. |
| `BioPDB.WriteModel(VAR r: Files.Rider; VAR m: Model; modelNo: INTEGER)` | Write `m` to an open `Files.Rider` in PDB format.  Pass `modelNo > 0` to wrap with MODEL/ENDMDL records; pass 0 to write a bare END record. |

**Usage pattern (streaming):**
```
VAR rdr: BioPDB.PDBReader;  m: BioPDB.Model;  err: INTEGER;
IF BioPDB.OpenPDB(rdr, "ensemble.pdb") THEN
  WHILE BioPDB.ReadModel(rdr, m, err) DO
    (* process m.atoms[0 .. m.count-1] *)
  END;
  BioPDB.ClosePDB(rdr)
END
```

---

## Ollama - Local LLM Client

```
IMPORT Ollama;
```

REST client for a local [Ollama](https://ollama.com) server.  Communicates via the HTTP API using `curl` (must be on PATH).

### Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `Ollama.DefaultHost` | `'http://localhost:11434'` | Default Ollama server URL. |
| `Ollama.MaxResp` | 32768 | Maximum response length; responses are silently truncated if longer. |

### Procedures

| Procedure / Function | Description |
|----------------------|-------------|
| `Ollama.Generate(host, model, prompt: ARRAY OF CHAR; VAR response: ARRAY OF CHAR): BOOLEAN` | Call `POST /api/generate` with `prompt` and copy the full generated text into `response`.  Returns TRUE on success.  Pass `Ollama.DefaultHost` for `host` to use the local server. |
| `Ollama.Chat(host, model, userMsg: ARRAY OF CHAR; VAR response: ARRAY OF CHAR): BOOLEAN` | Single-turn chat via `POST /api/chat`.  Returns the assistant's reply in `response`. |
| `Ollama.Models(host: ARRAY OF CHAR; VAR list: ARRAY OF CHAR): BOOLEAN` | Call `GET /api/tags` and store the raw JSON response in `list`.  Returns TRUE on success.  Parse `list` with `Strings.Split` or similar to extract model names. |

---

## SDL2 - SDL2 Graphics and Input

```
IMPORT SDL2;
```

Thin wrapper around SDL2 for windowed 2D graphics, texture rendering, and input events.  Requires SDL2 (`pkg-config sdl2`).

### Types

| Type | Description |
|------|-------------|
| `SDL2.Window` | Opaque handle to an SDL window. NIL on error. |
| `SDL2.Renderer` | Opaque handle to an SDL renderer. NIL on error. |
| `SDL2.Texture` | Opaque handle to an SDL texture. NIL on error. |
| `SDL2.Surface` | Opaque handle to an SDL surface. NIL on error. |
| `SDL2.Event` | Opaque handle to an SDL event record.  Allocate with `NEW(ev)`. |

### Init Flags

| Constant | Description |
|----------|-------------|
| `SDL2.InitTimer` | Enable the timer subsystem. |
| `SDL2.InitAudio` | Enable the audio subsystem. |
| `SDL2.InitVideo` | Enable the video subsystem. |
| `SDL2.InitAll` | Enable all subsystems. |

### Window Flags

| Constant | Description |
|----------|-------------|
| `SDL2.WinShown` | Window is visible on creation. |
| `SDL2.WinFullscreen` | True fullscreen mode. |
| `SDL2.WinFullDesktop` | Fullscreen at desktop resolution (no mode change). |
| `SDL2.WinBorderless` | No window border or title bar. |
| `SDL2.WinResizable` | Window can be resized. |
| `SDL2.WinHighDPI` | Request high-DPI backing store if available. |
| `SDL2.WinPosCentered` | Center the window on screen. |
| `SDL2.WinPosUndefined` | Let the OS choose the window position. |

### Renderer Flags

| Constant | Description |
|----------|-------------|
| `SDL2.RendAccelerated` | Hardware-accelerated renderer. |
| `SDL2.RendSoftware` | Software renderer. |
| `SDL2.RendVSync` | Enable vertical sync. |

### Event Type Codes

| Constant | Description |
|----------|-------------|
| `SDL2.EvQuit` | Window close / quit event. |
| `SDL2.EvKeyDown` | Key pressed. |
| `SDL2.EvKeyUp` | Key released. |
| `SDL2.EvTextInput` | Text input (Unicode character entered). |
| `SDL2.EvMouseMotion` | Mouse moved. |
| `SDL2.EvMouseDown` | Mouse button pressed. |
| `SDL2.EvMouseUp` | Mouse button released. |
| `SDL2.EvMouseWheel` | Mouse wheel scrolled. |
| `SDL2.EvWindowEvent` | Window state changed (resize, focus, etc.). |

### Window Sub-event IDs

| Constant | Description |
|----------|-------------|
| `SDL2.WinEvResized` | Window was resized. |
| `SDL2.WinEvMinimized` | Window was minimized. |
| `SDL2.WinEvMaximized` | Window was maximized. |
| `SDL2.WinEvRestored` | Window restored from minimized/maximized. |
| `SDL2.WinEvFocusGain` | Window gained keyboard focus. |
| `SDL2.WinEvFocusLost` | Window lost keyboard focus. |

### Key Codes

Special keys (printable ASCII characters use their ASCII value directly):

`SDL2.KReturn` `SDL2.KEnter` `SDL2.KEsc` `SDL2.KBackspace` `SDL2.KTab` `SDL2.KSpace` `SDL2.KDelete` `SDL2.KInsert` `SDL2.KHome` `SDL2.KEnd` `SDL2.KPgUp` `SDL2.KPgDn` `SDL2.KUp` `SDL2.KDown` `SDL2.KLeft` `SDL2.KRight` `SDL2.KF1`…`SDL2.KF12` `SDL2.KLShift` `SDL2.KRShift` `SDL2.KLCtrl` `SDL2.KRCtrl` `SDL2.KLAlt` `SDL2.KRAlt` `SDL2.KCapsLock`

### Modifier Masks (for `EventMod`)

`SDL2.ModNone` `SDL2.ModShift` `SDL2.ModLShift` `SDL2.ModRShift` `SDL2.ModCtrl` `SDL2.ModLCtrl` `SDL2.ModRCtrl` `SDL2.ModAlt` `SDL2.ModLAlt` `SDL2.ModRAlt`

### Mouse Button Numbers

`SDL2.BtnLeft` `SDL2.BtnMiddle` `SDL2.BtnRight`

### Blend Modes

`SDL2.BlendNone` `SDL2.BlendAlpha` `SDL2.BlendAdd` `SDL2.BlendMod`

### Render Flip Flags

`SDL2.FlipNone` `SDL2.FlipH` (horizontal) `SDL2.FlipV` (vertical)

### System

| Procedure / Function | Description |
|----------------------|-------------|
| `SDL2.Init(flags: INTEGER): INTEGER` | Initialise SDL subsystems.  Returns 0 on success. |
| `SDL2.Quit` | Shut down SDL and free all resources. |
| `SDL2.GetError(VAR buf: ARRAY OF CHAR)` | Copy the last SDL error message into `buf`. |

### Window

| Procedure / Function | Description |
|----------------------|-------------|
| `SDL2.CreateWindow(title: ARRAY OF CHAR; w, h, flags: INTEGER): Window` | Create a window of size `w`×`h` (centered).  Returns NIL on error. |
| `SDL2.CreateWindowAt(title: ARRAY OF CHAR; x, y, w, h, flags: INTEGER): Window` | Create a window at position `(x, y)`. |
| `SDL2.DestroyWindow(win: Window)` | Destroy and free a window. |
| `SDL2.SetWindowTitle(win: Window; title: ARRAY OF CHAR)` | Change the window title. |
| `SDL2.WindowWidth(win: Window): INTEGER` | Current window width in pixels. |
| `SDL2.WindowHeight(win: Window): INTEGER` | Current window height in pixels. |

### Renderer

| Procedure / Function | Description |
|----------------------|-------------|
| `SDL2.CreateRenderer(win: Window; flags: INTEGER): Renderer` | Create a renderer for `win`.  Returns NIL on error. |
| `SDL2.DestroyRenderer(ren: Renderer)` | Destroy the renderer. |
| `SDL2.SetDrawColor(ren: Renderer; r, g, b, a: INTEGER)` | Set current draw color (0–255 each; `a` = alpha). |
| `SDL2.Clear(ren: Renderer)` | Clear the render target with the current draw color. |
| `SDL2.Present(ren: Renderer)` | Flip the rendered frame to the screen. |
| `SDL2.DrawPoint(ren: Renderer; x, y: INTEGER)` | Draw a single pixel. |
| `SDL2.DrawLine(ren: Renderer; x1, y1, x2, y2: INTEGER)` | Draw a line. |
| `SDL2.DrawRect(ren: Renderer; x, y, w, h: INTEGER)` | Draw a rectangle outline. |
| `SDL2.FillRect(ren: Renderer; x, y, w, h: INTEGER)` | Draw a filled rectangle. |
| `SDL2.SetBlendMode(ren: Renderer; mode: INTEGER)` | Set the blend mode for drawing operations. |
| `SDL2.SetClipRect(ren: Renderer; x, y, w, h: INTEGER)` | Set a clipping rectangle; drawing outside it is discarded. |
| `SDL2.ClearClipRect(ren: Renderer)` | Remove the clipping rectangle. |
| `SDL2.SetScale(ren: Renderer; sx, sy: REAL)` | Set the rendering scale factors. |
| `SDL2.SetRenderTarget(ren: Renderer; tex: Texture)` | Redirect rendering to a texture. |
| `SDL2.ClearRenderTarget(ren: Renderer)` | Restore rendering to the default screen target. |

### Texture

| Procedure / Function | Description |
|----------------------|-------------|
| `SDL2.CreateTexture(ren: Renderer; w, h: INTEGER): Texture` | Create a blank RGBA8 render-target texture.  Returns NIL on error. |
| `SDL2.CreateTextureFromSurface(ren: Renderer; surf: Surface): Texture` | Create a texture from a surface. |
| `SDL2.DestroyTexture(tex: Texture)` | Free a texture. |
| `SDL2.RenderCopy(ren: Renderer; tex: Texture; dx, dy, dw, dh: INTEGER)` | Draw `tex` scaled to the destination rectangle `(dx, dy, dw, dh)`. |
| `SDL2.RenderCopyRect(ren: Renderer; tex: Texture; sx, sy, sw, sh, dx, dy, dw, dh: INTEGER)` | Draw a subrectangle `(sx, sy, sw, sh)` of `tex` to the destination. |
| `SDL2.RenderCopyEx(ren: Renderer; tex: Texture; dx, dy, dw, dh: INTEGER; angle: REAL; flip: INTEGER)` | Draw `tex` rotated by `angle` degrees and flipped by `flip` flag. |
| `SDL2.SetTextureColor(tex: Texture; r, g, b: INTEGER)` | Apply a color multiplier to the texture. |
| `SDL2.SetTextureAlpha(tex: Texture; a: INTEGER)` | Set the texture's alpha multiplier (0–255). |
| `SDL2.SetTextureBlend(tex: Texture; mode: INTEGER)` | Set the texture's blend mode. |
| `SDL2.TextureWidth(tex: Texture): INTEGER` | Texture width in pixels. |
| `SDL2.TextureHeight(tex: Texture): INTEGER` | Texture height in pixels. |

### Surface

| Procedure / Function | Description |
|----------------------|-------------|
| `SDL2.LoadBMP(path: ARRAY OF CHAR): Surface` | Load a BMP file into a surface.  Returns NIL on error. |
| `SDL2.FreeSurface(surf: Surface)` | Free a surface. |

### Events

Allocate an event record with `NEW(ev)` before calling `PollEvent` or `WaitEvent`.

| Procedure / Function | Description |
|----------------------|-------------|
| `SDL2.PollEvent(ev: Event): INTEGER` | Non-blocking: fill `ev` and return 1 if an event was available, 0 otherwise. |
| `SDL2.WaitEvent(ev: Event)` | Block until an event arrives, then fill `ev`. |
| `SDL2.EventKind(ev: Event): INTEGER` | Event type (`EvQuit`, `EvKeyDown`, etc.). |
| `SDL2.EventKey(ev: Event): INTEGER` | Key symbol for `EvKeyDown`/`EvKeyUp` events. |
| `SDL2.EventMod(ev: Event): INTEGER` | Active modifier mask for key events. |
| `SDL2.EventMouseX(ev: Event): INTEGER` | Mouse X coordinate for motion/button events. |
| `SDL2.EventMouseY(ev: Event): INTEGER` | Mouse Y coordinate for motion/button events. |
| `SDL2.EventMouseBtn(ev: Event): INTEGER` | Button number for `EvMouseDown`/`EvMouseUp`. |
| `SDL2.EventWheelX(ev: Event): INTEGER` | Horizontal scroll delta for `EvMouseWheel`. |
| `SDL2.EventWheelY(ev: Event): INTEGER` | Vertical scroll delta for `EvMouseWheel`. |
| `SDL2.EventWinID(ev: Event): INTEGER` | Window ID for `EvWindowEvent`. |
| `SDL2.EventWinEv(ev: Event): INTEGER` | Window sub-event code (`WinEvResized`, etc.). |
| `SDL2.EventWinW(ev: Event): INTEGER` | New width after `WinEvResized`. |
| `SDL2.EventWinH(ev: Event): INTEGER` | New height after `WinEvResized`. |
| `SDL2.EventTextChar(ev: Event): INTEGER` | First character of a `EvTextInput` event. |

### Timing and Input State

| Procedure / Function | Description |
|----------------------|-------------|
| `SDL2.Delay(ms: INTEGER)` | Sleep for `ms` milliseconds. |
| `SDL2.GetTicks(): INTEGER` | Milliseconds since SDL was initialized. |
| `SDL2.ShowCursor(show: INTEGER)` | Show (1) or hide (0) the mouse cursor. |
| `SDL2.MouseX(): INTEGER` | Current mouse X position. |
| `SDL2.MouseY(): INTEGER` | Current mouse Y position. |
| `SDL2.MouseButtons(): INTEGER` | Bitmask of currently pressed mouse buttons. |
| `SDL2.IsKeyDown(key: INTEGER): INTEGER` | Returns 1 if `key` is currently held down. |

---

## SDL2Sound - Audio Playback

```
IMPORT SDL2Sound;
```

PCM audio playback via SDL2 and SDL2_sound.  Decodes audio files to 44100 Hz / S16 / stereo on load.  Requires SDL2 and SDL2_sound (`pkg-config sdl2 SDL2_sound`).

### Types

| Type | Fields | Description |
|------|--------|-------------|
| `SDL2Sound.Sample` | `duration: INTEGER` | Opaque handle to a loaded, decoded sound.  `duration` = length in milliseconds. |

### Procedures

| Procedure / Function | Description |
|----------------------|-------------|
| `SDL2Sound.Init(): INTEGER` | Open the default audio device and initialise SDL_sound.  Returns 0 on success.  Call once after `SDL2.Init(SDL2.InitAudio)`. |
| `SDL2Sound.Quit` | Close the audio device and free all SDL_sound resources. |
| `SDL2Sound.GetError(VAR buf: ARRAY OF CHAR)` | Copy the last SDL_sound error message into `buf`. |
| `SDL2Sound.Load(path: ARRAY OF CHAR): Sample` | Load and decode a sound file (WAV, OGG, MP3, etc.) into a `Sample`.  Returns NIL on error. |
| `SDL2Sound.Free(sample: Sample)` | Free a loaded sample and its decoded PCM data. |
| `SDL2Sound.Duration(sample: Sample): INTEGER` | Duration of `sample` in milliseconds.  Returns -1 if unknown. |
| `SDL2Sound.Play(sample: Sample): INTEGER` | Queue `sample` for playback.  Returns 1 on success, 0 on error.  Playback is asynchronous. |
| `SDL2Sound.Stop` | Stop all currently queued audio output immediately. |
| `SDL2Sound.Queued(): INTEGER` | Approximate bytes still waiting to be played.  Returns 0 when playback is finished. |
| `SDL2Sound.WriteSineWAV(path: ARRAY OF CHAR; hz, ms: INTEGER): INTEGER` | Write a sine-wave WAV file to `path` with frequency `hz` Hz and duration `ms` ms.  Returns 1 on success. |

---

## Raylib - Game Window, 2D Graphics, Input, and Audio

```
IMPORT Raylib;
```

Self-contained game library: window management, hardware-accelerated 2D rendering, keyboard/mouse input, and audio.  Requires Raylib 4+ (`pkg-config raylib`).

### Color Encoding

All color parameters are a single `INTEGER` packed as `(a SHL 24) OR (r SHL 16) OR (g SHL 8) OR b`.  Fully-opaque colors have the high bit set and appear **negative** in Oberon — this is expected.  Use `Raylib.RGBA(r,g,b,a)` to build custom colors, or the named procedures (`Raylib.Black()`, `Raylib.Red()`, etc.) for the built-in palette.  Store color values in `INTEGER` variables at startup; do not compare them numerically.

### Types

| Type | Description |
|------|-------------|
| `Raylib.Texture` | Opaque handle to a GPU texture loaded from a file. |
| `Raylib.Sound` | Opaque handle to a loaded sound effect. |
| `Raylib.Music` | Opaque handle to a streaming music track. |
| `Raylib.Font` | Opaque handle to a loaded TTF/BMP font. |

### Window / Core

| Procedure / Function | Description |
|----------------------|-------------|
| `Raylib.InitWindow(w, h: INTEGER; title: ARRAY OF CHAR)` | Create a window of size `w`×`h` with the given title. |
| `Raylib.CloseWindow` | Destroy the window and free resources. |
| `Raylib.WindowShouldClose(): INTEGER` | Returns 1 when the user closes the window or presses Esc. |
| `Raylib.SetTargetFPS(fps: INTEGER)` | Cap the frame rate.  60 is typical. |
| `Raylib.GetFrameTime(): REAL` | Seconds elapsed since last frame (delta time). |
| `Raylib.GetTime(): REAL` | Seconds elapsed since `InitWindow`. |
| `Raylib.GetScreenWidth(): INTEGER` | Current window width in pixels. |
| `Raylib.GetScreenHeight(): INTEGER` | Current window height in pixels. |
| `Raylib.IsWindowResized(): INTEGER` | Returns 1 if the window was resized this frame. |
| `Raylib.ToggleFullscreen` | Toggle fullscreen mode. |
| `Raylib.SetWindowTitle(title: ARRAY OF CHAR)` | Change the window title. |
| `Raylib.SetWindowSize(w, h: INTEGER)` | Resize the window. |
| `Raylib.SetWindowResizable` | Allow the window to be resized by the user. |
| `Raylib.SetWindowShouldClose` | Signal the event loop to exit on the next `WindowShouldClose` check. |

### Drawing

Call `BeginDrawing` / `EndDrawing` around all draw calls each frame.

| Procedure | Description |
|-----------|-------------|
| `Raylib.BeginDrawing` | Begin the frame; set up the render target. |
| `Raylib.EndDrawing` | Flush the frame to the screen and wait for vsync/FPS cap. |
| `Raylib.ClearBackground(color: INTEGER)` | Fill the frame with `color`. |

### 2D Shapes

| Procedure | Description |
|-----------|-------------|
| `Raylib.DrawPixel(x, y: INTEGER; color: INTEGER)` | Draw a single pixel. |
| `Raylib.DrawLine(x1, y1, x2, y2: INTEGER; color: INTEGER)` | Draw a 1-pixel line. |
| `Raylib.DrawLineEx(x1, y1, x2, y2, thick: REAL; color: INTEGER)` | Draw a thick antialiased line. |
| `Raylib.DrawCircle(cx, cy: INTEGER; radius: REAL; color: INTEGER)` | Filled circle. |
| `Raylib.DrawCircleLines(cx, cy: INTEGER; radius: REAL; color: INTEGER)` | Circle outline. |
| `Raylib.DrawEllipse(cx, cy: INTEGER; rx, ry: REAL; color: INTEGER)` | Filled ellipse. |
| `Raylib.DrawRectangle(x, y, w, h: INTEGER; color: INTEGER)` | Filled rectangle. |
| `Raylib.DrawRectangleLines(x, y, w, h: INTEGER; color: INTEGER)` | Rectangle outline. |
| `Raylib.DrawRectangleRounded(x, y, w, h, roundness: REAL; segs: INTEGER; color: INTEGER)` | Filled rectangle with rounded corners.  `roundness` in 0.0–1.0. |
| `Raylib.DrawTriangle(x1, y1, x2, y2, x3, y3: REAL; color: INTEGER)` | Filled triangle (vertices must be counter-clockwise). |
| `Raylib.DrawPoly(cx, cy: REAL; sides: INTEGER; radius, rot: REAL; color: INTEGER)` | Filled regular polygon. |

### Text

| Procedure / Function | Description |
|----------------------|-------------|
| `Raylib.DrawText(text: ARRAY OF CHAR; x, y, size: INTEGER; color: INTEGER)` | Draw text using the default font. |
| `Raylib.DrawTextEx(font: Font; text: ARRAY OF CHAR; x, y, size, spacing: REAL; color: INTEGER)` | Draw text with a custom font, size, and character spacing. |
| `Raylib.MeasureText(text: ARRAY OF CHAR; size: INTEGER): INTEGER` | Width in pixels of `text` at `size` using the default font. |

### Textures

| Procedure / Function | Description |
|----------------------|-------------|
| `Raylib.LoadTexture(path: ARRAY OF CHAR): Texture` | Load an image file (PNG, JPG, BMP, TGA…) as a GPU texture.  Returns NIL on error. |
| `Raylib.UnloadTexture(tex: Texture)` | Free the texture. |
| `Raylib.DrawTexture(tex: Texture; x, y: INTEGER; color: INTEGER)` | Draw texture at `(x,y)`.  Use `Raylib.White()` as `color` for no tint. |
| `Raylib.DrawTextureEx(tex: Texture; x, y, rot, scale: REAL; color: INTEGER)` | Draw texture with rotation and uniform scale. |
| `Raylib.DrawTextureRec(tex: Texture; sx, sy, sw, sh: INTEGER; dx, dy: REAL; color: INTEGER)` | Draw a sub-rectangle of the texture at `(dx,dy)`. |
| `Raylib.DrawTexturePro(tex: Texture; sx, sy, sw, sh, dx, dy, dw, dh: INTEGER; color: INTEGER)` | Draw a sub-rectangle of the texture scaled to a destination rectangle. |
| `Raylib.TextureWidth(tex: Texture): INTEGER` | Width of the texture in pixels. |
| `Raylib.TextureHeight(tex: Texture): INTEGER` | Height of the texture in pixels. |

### Fonts

| Procedure / Function | Description |
|----------------------|-------------|
| `Raylib.LoadFont(path: ARRAY OF CHAR): Font` | Load a TTF or BMFont file.  Returns NIL on error. |
| `Raylib.LoadFontSharp(path: ARRAY OF CHAR; size: INTEGER): Font` | Load a TTF at a specific pixel `size` with nearest-neighbour filtering for crisp pixel fonts.  Returns NIL on error. |
| `Raylib.LoadFontSharpAppDir(filename: ARRAY OF CHAR; size: INTEGER): Font` | Like `LoadFontSharp` but resolves `filename` relative to the application's executable directory. |
| `Raylib.UnloadFont(font: Font)` | Free the font. |
| `Raylib.MeasureTextEx(font: Font; text: ARRAY OF CHAR; size, spacing: REAL): INTEGER` | Width in pixels of `text` rendered with `font` at `size` and `spacing`. |
| `Raylib.GetAppDir(buf: ARRAY OF CHAR)` | Fill `buf` with the path to the directory containing the running executable (trailing `/` included). |

### Input — Keyboard

Printable key codes are their ASCII value (e.g. `ORD("A")` = 65).  Special keys use the constants below.

`Raylib.KeySpace` `Raylib.KeyEsc` `Raylib.KeyEnter` `Raylib.KeyTab` `Raylib.KeyBackspace` `Raylib.KeyInsert` `Raylib.KeyDelete` `Raylib.KeyRight` `Raylib.KeyLeft` `Raylib.KeyDown` `Raylib.KeyUp` `Raylib.KeyPgUp` `Raylib.KeyPgDn` `Raylib.KeyHome` `Raylib.KeyEnd` `Raylib.KeyF1`…`Raylib.KeyF12` `Raylib.KeyLShift` `Raylib.KeyRShift` `Raylib.KeyLCtrl` `Raylib.KeyRCtrl` `Raylib.KeyLAlt` `Raylib.KeyRAlt`

| Function | Description |
|----------|-------------|
| `Raylib.IsKeyDown(key: INTEGER): INTEGER` | 1 while the key is held. |
| `Raylib.IsKeyPressed(key: INTEGER): INTEGER` | 1 on the frame the key was first pressed. |
| `Raylib.IsKeyReleased(key: INTEGER): INTEGER` | 1 on the frame the key was released. |
| `Raylib.GetKeyPressed(): INTEGER` | Key code of the next queued keypress, or 0 if none. |

### Input — Mouse

`Raylib.BtnLeft` `Raylib.BtnRight` `Raylib.BtnMiddle`

| Function | Description |
|----------|-------------|
| `Raylib.IsMouseButtonDown(btn: INTEGER): INTEGER` | 1 while the button is held. |
| `Raylib.IsMouseButtonPressed(btn: INTEGER): INTEGER` | 1 on the frame the button was first pressed. |
| `Raylib.IsMouseButtonReleased(btn: INTEGER): INTEGER` | 1 on the frame the button was released. |
| `Raylib.GetMouseX(): INTEGER` | Current mouse X position. |
| `Raylib.GetMouseY(): INTEGER` | Current mouse Y position. |
| `Raylib.GetMouseWheelMove(): REAL` | Wheel scroll delta this frame (positive = up). |
| `Raylib.GetMouseDeltaX(): REAL` | Mouse movement in X since last frame. |
| `Raylib.GetMouseDeltaY(): REAL` | Mouse movement in Y since last frame. |
| `Raylib.SetMousePosition(x, y: INTEGER)` | Warp the mouse cursor. |
| `Raylib.ShowCursor` | Make the OS cursor visible. |
| `Raylib.HideCursor` | Hide the OS cursor. |

### Audio

| Procedure / Function | Description |
|----------------------|-------------|
| `Raylib.InitAudioDevice` | Open the audio device.  Call once before loading sounds. |
| `Raylib.CloseAudioDevice` | Close the audio device. |
| `Raylib.LoadSound(path: ARRAY OF CHAR): Sound` | Load a sound effect (WAV, OGG, MP3…).  Returns NIL on error. |
| `Raylib.UnloadSound(snd: Sound)` | Free a sound. |
| `Raylib.PlaySound(snd: Sound)` | Play the sound from the start. |
| `Raylib.StopSound(snd: Sound)` | Stop playback. |
| `Raylib.PauseSound(snd: Sound)` | Pause playback. |
| `Raylib.ResumeSound(snd: Sound)` | Resume paused playback. |
| `Raylib.IsSoundPlaying(snd: Sound): INTEGER` | 1 if the sound is currently playing. |
| `Raylib.SetSoundVolume(snd: Sound; vol: REAL)` | Set volume 0.0–1.0. |
| `Raylib.LoadMusicStream(path: ARRAY OF CHAR): Music` | Load a music file for streaming.  Returns NIL on error. |
| `Raylib.UnloadMusicStream(mus: Music)` | Free a music stream. |
| `Raylib.PlayMusicStream(mus: Music)` | Start streaming playback. |
| `Raylib.UpdateMusicStream(mus: Music)` | Refill the stream buffer — call once per frame while playing. |
| `Raylib.StopMusicStream(mus: Music)` | Stop and rewind. |
| `Raylib.PauseMusicStream(mus: Music)` | Pause streaming. |
| `Raylib.ResumeMusicStream(mus: Music)` | Resume streaming. |
| `Raylib.IsMusicStreamPlaying(mus: Music): INTEGER` | 1 if streaming is active. |
| `Raylib.SetMusicVolume(mus: Music; vol: REAL)` | Set volume 0.0–1.0. |
| `Raylib.GenToneSound(freq: REAL; ms: INTEGER): Sound` | Synthesise a sine-wave tone at `freq` Hz lasting `ms` milliseconds (44 100 Hz, with 10 ms attack and 25 % decay tail).  No file needed. |
| `Raylib.GenShootSound(): Sound` | Synthesise a square-wave frequency-sweep shoot/laser effect (800→200 Hz, ~250 ms). |
| `Raylib.GenMarchSound(phase: INTEGER): Sound` | Synthesise a short march-step blip (~83 ms).  Alternate `phase` 0/1 between left and right footsteps (160 Hz / 100 Hz). |
| `Raylib.GenExplodeSound(): Sound` | Synthesise a noise-burst explosion effect (~450 ms). |

### Color Utilities

| Function | Description |
|----------|-------------|
| `Raylib.RGBA(r, g, b, a: INTEGER): INTEGER` | Pack r/g/b/a (0–255 each) into a color value. |
| `Raylib.Fade(color: INTEGER; alpha: REAL): INTEGER` | Return `color` with alpha multiplied by `alpha` (0.0–1.0). |

### Named Colors

`Raylib.Black()` `Raylib.White()` `Raylib.RayWhite()` `Raylib.Red()` `Raylib.Green()` `Raylib.Blue()` `Raylib.Yellow()` `Raylib.Gold()` `Raylib.Orange()` `Raylib.Pink()` `Raylib.Maroon()` `Raylib.LightGray()` `Raylib.Gray()` `Raylib.DarkGray()` `Raylib.SkyBlue()` `Raylib.DarkBlue()` `Raylib.DarkGreen()` `Raylib.Purple()` `Raylib.DarkPurple()` `Raylib.Beige()` `Raylib.Brown()` `Raylib.DarkBrown()` `Raylib.Magenta()` `Raylib.Lime()` `Raylib.Violet()` `Raylib.Blank()`

Each returns an `INTEGER` color value.  Store the result in a variable at startup rather than calling repeatedly in the draw loop.

### RenderTexture (off-screen canvas)

A `Raylib.RenderTexture` is an off-screen framebuffer you can draw into, then blit to the screen.  Useful for paint programs, post-processing, or any persistent pixel canvas.

| Procedure / Function | Description |
|----------------------|-------------|
| `Raylib.LoadRenderTexture(w, h: INTEGER): RenderTexture` | Create an off-screen canvas of size `w`×`h`. |
| `Raylib.UnloadRenderTexture(rt: RenderTexture)` | Free the render texture. |
| `Raylib.BeginTextureMode(rt: RenderTexture)` | Redirect subsequent draw calls into `rt`.  Call before any drawing you want captured. |
| `Raylib.EndTextureMode` | Stop drawing into the render texture; resume normal screen rendering. |
| `Raylib.DrawRenderTexture(rt: RenderTexture; x, y, w, h: INTEGER; color: INTEGER)` | Blit the render texture to the screen at `(x,y)` scaled to `w`×`h`.  Handles the OpenGL Y-flip automatically. |
| `Raylib.SaveRTPNG(rt: RenderTexture; filename: ARRAY OF CHAR)` | Export the canvas to a PNG file (Y-flip corrected). |
| `Raylib.LoadPNGIntoRT(rt: RenderTexture; filename: ARRAY OF CHAR)` | Load a PNG and draw it into `rt`, scaling to fit. |
| `Raylib.FloodFillRT(rt: RenderTexture; x, y: INTEGER; fillColor: INTEGER)` | Flood-fill the render texture starting at pixel `(x,y)` with `fillColor`, replacing all contiguous pixels of the same original color (4-connected). |

**Coordinate note:** Inside `BeginTextureMode`/`EndTextureMode`, `y=0` is the top of the texture and increases downward — identical to normal screen drawing.  `DrawRenderTexture` corrects the OpenGL Y-flip when displaying.

### Additional Shapes

| Procedure | Description |
|-----------|-------------|
| `Raylib.DrawEllipseLines(cx, cy: INTEGER; rx, ry: REAL; color: INTEGER)` | Ellipse outline. |
| `Raylib.DrawRectangleLinesEx(x, y, w, h: INTEGER; thick: REAL; color: INTEGER)` | Rectangle outline with specified line thickness. |
| `Raylib.DrawCircleGradient(cx, cy: INTEGER; radius: REAL; c1, c2: INTEGER)` | Filled circle with a radial gradient from center color `c1` to edge color `c2`. |

### Extended Input

| Function | Description |
|----------|-------------|
| `Raylib.GetCharPressed(): INTEGER` | Unicode codepoint of the character typed this frame (0 if none).  Call in a loop until 0 to drain the queue.  Use `CHR()` to convert to `CHAR`. |

### 3D Types

| Type | Description |
|------|-------------|
| `Raylib.Camera` | Opaque handle to a 3D camera (position, target, up, fovy, projection). |
| `Raylib.Model` | Opaque handle to a 3D model loaded from a file (GLB, OBJ, etc.). |

### 3D Camera Constants

| Constant | Description |
|----------|-------------|
| `Raylib.CameraPerspective` | Perspective projection (default for 3D scenes). |
| `Raylib.CameraOrthographic` | Orthographic projection. |
| `Raylib.CameraCustom` | No auto-update; move camera manually each frame. |
| `Raylib.CameraFree` | Free-fly camera controlled by mouse + WASD. |
| `Raylib.CameraOrbital` | Orbit around the target with left-drag + scroll. |
| `Raylib.CameraFirstPerson` | First-person mode. |
| `Raylib.CameraThirdPerson` | Third-person mode. |

### 3D Camera

| Procedure / Function | Description |
|----------------------|-------------|
| `Raylib.NewCamera(posX, posY, posZ, tarX, tarY, tarZ, upX, upY, upZ, fovy: REAL; projType: INTEGER): Camera` | Allocate a camera.  `fovy` is field-of-view in degrees.  `projType` is `Raylib.CameraPerspective` or `Raylib.CameraOrthographic`. |
| `Raylib.FreeCamera(cam: Camera)` | Free the camera handle. |
| `Raylib.UpdateCamera(cam: Camera; mode: INTEGER)` | Apply built-in input to move/rotate the camera this frame.  Pass one of the `CameraFree`, `CameraOrbital`, etc. constants. |
| `Raylib.SetCameraPosition(cam: Camera; x, y, z: REAL)` | Move the camera eye to `(x, y, z)`. |
| `Raylib.SetCameraTarget(cam: Camera; x, y, z: REAL)` | Aim the camera at `(x, y, z)`. |
| `Raylib.SetCameraUp(cam: Camera; x, y, z: REAL)` | Set the camera's up vector to `(x, y, z)`.  Defaults to `(0,1,0)` after `NewCamera`. |
| `Raylib.BeginMode3D(cam: Camera)` | Enter 3D drawing mode.  Must follow `BeginDrawing` and precede all 3D draw calls. |
| `Raylib.EndMode3D` | Exit 3D drawing mode.  Resume 2D drawing (text/UI overlay) after this. |

**Typical 3D frame loop:**
```oberon
Raylib.BeginDrawing;
Raylib.ClearBackground(cBlack);
Raylib.BeginMode3D(cam);
  (* 3D draw calls here *)
Raylib.EndMode3D;
  (* 2D overlay draw calls here *)
Raylib.EndDrawing
```

### 3D Model

| Procedure / Function | Description |
|----------------------|-------------|
| `Raylib.LoadModel(path: ARRAY OF CHAR): Model` | Load a 3D model from file (GLB, GLTF, OBJ, M3D…).  Returns NIL on error. |
| `Raylib.UnloadModel(mdl: Model)` | Unload a model and free GPU resources. |
| `Raylib.DrawModel(mdl: Model; x, y, z: REAL; scale: REAL; color: INTEGER)` | Draw the model at world position `(x,y,z)` with uniform `scale` and tint `color`.  Use `Raylib.White()` for no tint. |
| `Raylib.DrawModelEx(mdl: Model; posX, posY, posZ: REAL; axisX, axisY, axisZ: REAL; angle: REAL; scaleX, scaleY, scaleZ: REAL; color: INTEGER)` | Draw with explicit rotation axis/angle and per-axis scale.  `angle` is in degrees. |
| `Raylib.QueryModelBounds(mdl: Model)` | Compute the model's axis-aligned bounding box and cache it internally. Call once after loading. |
| `Raylib.ModelBBMinX(): REAL` | Cached bounding-box minimum X (call `QueryModelBounds` first). |
| `Raylib.ModelBBMinY(): REAL` | Cached bounding-box minimum Y. |
| `Raylib.ModelBBMinZ(): REAL` | Cached bounding-box minimum Z. |
| `Raylib.ModelBBMaxX(): REAL` | Cached bounding-box maximum X. |
| `Raylib.ModelBBMaxY(): REAL` | Cached bounding-box maximum Y. |
| `Raylib.ModelBBMaxZ(): REAL` | Cached bounding-box maximum Z. |

### 3D Shapes

All positions are world-space `(x,y,z)`.

| Procedure | Description |
|-----------|-------------|
| `Raylib.DrawGrid(slices: INTEGER; spacing: REAL)` | Draw a grid on the XZ plane.  `slices` lines per half-axis, `spacing` units apart.  Good for a chess board background. |
| `Raylib.DrawCube(x, y, z, w, h, len: REAL; color: INTEGER)` | Filled axis-aligned box. `w`=X width, `h`=Y height, `len`=Z depth. |
| `Raylib.DrawCubeWires(x, y, z, w, h, len: REAL; color: INTEGER)` | Wireframe box outline. |
| `Raylib.DrawSphere(x, y, z, radius: REAL; color: INTEGER)` | Filled sphere. |
| `Raylib.DrawCylinder(x, y, z, radTop, radBot, height: REAL; slices: INTEGER; color: INTEGER)` | Filled cylinder or cone. |
| `Raylib.DrawPlane(x, y, z, w, len: REAL; color: INTEGER)` | Flat XZ plane quad of size `w` × `len`. |

### 3D Picking

Cast a ray from the mouse cursor and test it against geometry.

| Procedure / Function | Description |
|----------------------|-------------|
| `Raylib.GetMouseRay(mx, my: INTEGER; cam: Camera; VAR ox, oy, oz: REAL; VAR dx, dy, dz: REAL)` | Compute a world-space ray from screen pixel `(mx,my)` through `cam`.  `(ox,oy,oz)` = ray origin, `(dx,dy,dz)` = normalised direction. |
| `Raylib.GetRayCollisionBox(rox, roy, roz, rdx, rdy, rdz: REAL; minX, minY, minZ, maxX, maxY, maxZ: REAL; VAR dist: REAL; VAR hx, hy, hz: REAL): INTEGER` | Test ray against an axis-aligned box.  Returns 1 on hit; sets `dist` = distance to hit, `(hx,hy,hz)` = hit point. |

**Typical pick pattern:**
```oberon
VAR ox, oy, oz, dx, dy, dz, dist, hx, hy, hz : REAL;
Raylib.GetMouseRay(Raylib.GetMouseX(), Raylib.GetMouseY(), cam,
                   ox, oy, oz, dx, dy, dz);
IF Raylib.GetRayCollisionBox(ox,oy,oz, dx,dy,dz,
                              minX,minY,minZ, maxX,maxY,maxZ,
                              dist, hx,hy,hz) = 1 THEN
  (* piece was clicked *)
END
```


