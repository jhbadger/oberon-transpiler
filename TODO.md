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

**Cross-module array field type resolution failure in `codegen.c`**

`expr_type()` in `codegen.c` resolves the type of an expression by walking the AST. For a field access (`ND_FIELD_ACCESS`), it calls `find_type_decl()` to look up the record type — but `find_type_decl()` searches only `g_module_decls`, which is set to the *current* module's declaration list at the start of `codegen()` and never includes imported modules.

This means that when a caller in module A accesses a field of a record type defined in module B, `expr_type()` returns `NULL` for that field access. Two things then go wrong:

1. **VAR parameter passing:** `emit_addr_of()` can't determine whether the field is an array type. Array-typed VAR parameters should be passed as a plain pointer (the array already decays), but non-array VAR parameters need an explicit `&`. With `NULL` type info, the wrong form is chosen, producing a bad pointer at the call site.

2. **Assignment operator selection:** `emit_stmt()` for `ND_ASSIGN` uses `expr_type()` on the LHS to decide between plain `=`, `strcpy`, or `memcpy`. With `NULL` returned for a cross-module array field, `is_str` and `is_arr` both stay false and plain `=` is emitted — a C compile error for array types, or silent memory corruption for char arrays if the RHS happens to be a single-char string literal that the transpiler folds to a char value.

**Fix direction:** The cross-module proc signature table (`g_xmod_procsigs`) already solves the analogous problem for procedure parameters by accumulating type info across `codegen()` calls and never freeing it. A similar persistent cross-module type declaration table is needed — populated during each library module's `codegen()` call and consulted by `find_type_decl()` as a fallback when the current module's `g_module_decls` search fails.

**Workaround:** Define a constructor procedure in the module that owns the record type (e.g. `MakeField` in `DBF.mod`) and do all array field writes there, where the compiler has full type information.
