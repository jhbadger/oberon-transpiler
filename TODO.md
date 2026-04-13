# Oberon Transpiler — Todo List

## Transpiler — Language/Compiler Issues

- **`expr_type()` is incomplete** (`codegen.c:390,392`): returns `NULL` for `ND_FIELD_ACCESS` and
  `ND_CALL`. This means string comparison via `=`/`#` can silently fall back to pointer comparison
  when the LHS is a record field or function call result.
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

- **README examples table** is missing newer examples (`BRErogue`, `rogue`, `sheet`, `videopoker`,
  `zodiac`, `epub`, etc.).


