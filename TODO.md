# TODO

## Compiler bugs

- **Nested procedure open-array call sites missing length argument**: When a
  nested procedure has an `ARRAY OF CHAR` (or any open-array) parameter and is
  called from within its enclosing procedure using a string literal or variable,
  the generated C call omits the `_len` argument that the nested procedure's C
  signature expects.  Top-level procedure calls inject `sizeof(lit)/sizeof(lit[0])`
  correctly; the same injection is missing in `emit_call` when the callee is a
  closure (called through its `_frame` pointer).  Workaround: avoid open-array
  parameters in nested procedures — use fixed-size arrays or module-level helpers
  instead.  Reproducer: `examples/speedscript.mod` `ShowHelp` originally used
  nested procs `Sect`/`Row` with `ARRAY OF CHAR` params; they had to be inlined.
