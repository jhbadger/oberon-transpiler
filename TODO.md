# Oberon Transpiler — Todo List

## Stdlib — Missing Procedures/Functions

### Files module
- `Files.Delete(name)` — delete a file by name
- `Files.Rename(old, new)` — rename/move a file
- `Files.Exists(name): BOOLEAN` — check if a file exists
- Text-mode I/O: `Files.ReadLine` / `Files.WriteLine` (currently only raw binary riders)

### In module
- `In.Line(VAR s)` — read a full line from stdin (currently only word-by-word with `In.String`)

### Dict module
- Iteration support — no way to enumerate keys/values (e.g. `Dict.First`, `Dict.Next`, or a `Keys` procedure)

### Graphics module
- `Graphics.Line(x1, y1, x2, y2, color)` — diagonal line in pixel buffer (Bresenham; only HLine/VLine exist)
- `Graphics.FillCircle(cx, cy, r, color)` — filled circle (only outline `Circle` exists)
- `Graphics.FillBuf(color)` — flood-fill the entire pixel buffer with one color
- `Graphics.RGBColor(r, g, b): INTEGER` — map RGB to nearest 256-color index

### Strings module
- `Strings.StartsWith(s, prefix): BOOLEAN`
- `Strings.EndsWith(s, suffix): BOOLEAN`
- `Strings.Split` or similar (currently requires manual `NextWord`/`Pos` loops)

### Math module
- `Math.min(a, b)` / `Math.max(a, b)` as real functions (currently users must write IF-chains)
- `Math.clamp(x, lo, hi)` — useful in graphics/games

### New modules to consider
- `Env` — read environment variables (currently buried in `Args.GetEnv` which isn't in stdlib.md)
- `OS` — basic OS calls: `OS.Exec`, `OS.Exit`, `OS.GetCwd`, `OS.ChDir`
- `Time` — `Time.Now(): LONGINT`, `Time.Format`, `Time.Sleep(ms)`

---

## Transpiler — Language/Compiler Issues

- **`expr_type()` is incomplete** (`codegen.c:390,392`): returns `NULL` for `ND_FIELD_ACCESS` and
  `ND_CALL`. This means string comparison via `=`/`#` can silently fall back to pointer comparison
  when the LHS is a record field or function call result.
- **`Args.GetEnv` is not in stdlib.md** — it's implemented in codegen but undocumented.
- **Hard limits** that could be hit in large programs:
  - Nested proc frame capped at 64 vars (`build_frame`)
  - Max 16 nested procedures per outer proc
  - Max 128 type tags / pointer types
  - Max 1024 symbols in the flat symbol table
- **`FLT`, `ASR`, `LSL`, `ROR`, `PACK`, `UNPK`** — listed in IDE keywords but not in the codegen
  builtin handler; calling them would silently emit bare C function calls.
- **`FLOOR`** listed as keyword in IDE but it's not a language builtin (it's `Math.floor`); could
  be confusing.
- **Unused variable warnings** — none emitted; easy to have silent dead variables.

---

## IDE — Features & Polish

- **Window switching**: only `Alt-2` is wired up in the menu; `Alt-1` through `Alt-9` shortcuts
  should be added for all open windows.
- **Autocomplete doesn't suggest `Module.Proc` members** — typing `Out.` gives no completions;
  could filter known module names from the keyword list.
- **About dialog is incomplete** — doesn't list most shortcuts (e.g. `Ctrl-K` autocomplete,
  `Ctrl-L` goto line, `Alt-2` switch window, `F8` compile).
- **No "Tile / Cascade windows"** menu item under Window.
- **No recent files list** in the File menu.
- **No "Rename file"** for the current editor (only Save As).
- **Multi-error display** — only the first error line is highlighted; a full list panel would help.
- **Number highlighting colour** reuses comment colour (cyan), making numbers and comments
  visually indistinguishable.
- **Tab width is hardcoded** — no way to set indent size preference.

---

## Documentation

- **`Args.GetEnv` is undocumented** — missing from stdlib.md entirely.
- **README examples table** is missing newer examples (`BRErogue`, `rogue`, `sheet`, `videopoker`,
  `zodiac`, `epub`, etc.).
