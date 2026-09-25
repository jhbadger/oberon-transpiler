# Porting zilf (the ZIL compiler) to Oberon — plan & status

This is a multi-session port of **zilf** (the ZIL/MDL-to-Z-machine compiler,
from `~/lib/src/zilf`) to this Oberon system, following on from the
already-completed port of **zapf** (the Z-machine assembler — see
`Modules/ZapfAsm.mod` et al. and `examples/zapf.mod`). The zilf compiler
emits `.zap` text; the plan is for the Oberon port to do the same, feeding
into the Oberon zapf we already built, rather than porting a direct-to-binary
backend.

Decisions made with the user before starting (do not re-litigate without
asking): **(1)** incremental, resumable, multi-session approach — commit
working milestones, keep this doc current; **(2)** a *pragmatic subset* of
the ZIL language covering real games, not full historical/edge-case
fidelity; **(3)** target `Zilf.Emit.Zap` (textual `.zap` output), not
`Zilf.Emit.Glulx` or `Zilf.Emit.Cornerstone` (direct-to-binary) — those two
and `Zilf.Emit.Intermediate`'s multi-backend abstraction can likely be
skipped or drastically simplified once we're deep enough to confirm the
compiler doesn't need the generic backend interface for anything the
Zap-only path doesn't already provide directly.

## Why this can't be done the way zapf was

zapf's C# and Oberon module boundaries lined up cleanly: tokenizer, then
parser, then assembler, each layer usable/testable independently before the
next existed. **zilf is a real Lisp interpreter (MDL dialect) with the
evaluator wired directly into the reader**: `%<...>` in source text means
"evaluate this now, during parsing," and `#ATOM (...)` means "CHTYPE the
following value now, during parsing" (see `Zilf/Language/Parsing/Parser.cs`).
Nearly all real ZIL source also leans on `<DEFMAC ...>`-defined macros, which
requires the interpreter to expand forms before the compiler ever sees them.
So "just the reader, no evaluator" is a real phase boundary (and worth
doing, see below) but a much thinner slice of usefulness than zapf's
tokenizer was — you can't compile *anything* real without phase 2.

## Source size inventory (C#, `~/lib/src/zilf/src/`)

Recursive line counts, established by direct exploration (not estimates):

| Subsystem | Lines | Files | Status |
|---|---|---|---|
| `Zilf/Language` (+`Parsing`,`Signatures`) | 5,165 | — | **Parser.cs ported** (phase 1); Signatures (constraint/type-checking DSL for builtin argument validation) not started |
| `Zilf/Interpreter` (+`Values`) | 16,868 | — | `Values/` core types ported (phase 1, subset — see below); environments/eval loop/SUBR-FSUBR dispatch/OBLIST-as-package-hierarchy NOT started (phase 2) |
| `Zilf/Compiler` (+`Builtins`) | 13,187 | 221 total across `Zilf/` | not started (phase 3+) |
| `Zilf/ZModel` (+`Values`,`Vocab`) | 7,367 | — | not started (phase 3+) |
| `Zilf/Cli` | 2,066 | — | not started; will be much smaller in practice (System.CommandLine boilerplate, like zapf's Program.cs top) |
| `Zilf/Diagnostics` | 1,517 | — | not started; will be much smaller (error message catalog — port a handful of messages as needed, not the whole resource system) |
| `Zilf/Blorb` | 169 | — | **skip** (resource-file packaging, not needed for a working `.zap`) |
| `Zilf/Ide`, `Zilf/Cli`'s Ide bits | 611+ | — | **skip** (editor support) |
| `Zilf.Emit` root | 3,108 | — | the abstract `IGameBuilder`/`IRoutineBuilder`/etc. interfaces every backend implements — read this early in phase 3, may be able to skip the abstraction and go straight to a Zap-shaped API |
| `Zilf.Emit/Zap` | 4,548 | — | not started (phase 3+) — this is the actual `.zap` text writer, the most directly relevant Emit piece |
| `Zilf.Emit/Intermediate` | 6,060 | — | not started; may be largely skippable (see above) |
| `Zilf.Emit/Glulx` | 8,677 | — | **skip entirely** (different VM target) |
| `Zilf.Emit/Cornerstone` | 6,861 | — | **skip entirely** (direct-to-binary backend, we're going through zapf instead) |
| `Analyzers`, `ZilfPub`, `Zilf.Playground`, `WindowsInstaller`, `Dezapf` | ~18,500 | — | **skip entirely** (dev tooling / unrelated projects) |

**Realistic remaining scope after all the skips: roughly 45,000–50,000
lines** of C# to work from (Language + Interpreter + Compiler + ZModel +
reduced Cli/Diagnostics + Emit/Zap + maybe-reduced Emit/Intermediate). That
is itself **~5-6x the size of zapf**, which took a full long session. Set
expectations accordingly across future sessions — this is not a "finish it
in a sitting" task even now that phase 1 exists.

## What's done (phase 1) — files, and what's tested

- **`Modules/ZilObj.mod`** — the ZIL value-type system, ported from
  `Zilf/Interpreter/Values/*.cs`. One tagged record `Zo` (kind + payload
  fields), not a class hierarchy — same rationale as zapf's `ZapfAst.Line`.
  Kinds implemented: `KAtom, KFix, KString, KChar, KForm, KList, KVector,
  KAdecl, KSegment, KFalse`. Includes atom interning (`Intern`), cons-cell
  helpers (`Cons`, `NewEmpty`, `IsEmpty`, `ListLength`, `ListNth`), and a
  reparsable-form printer (`PrintTo`/`Print`) used for testing.
- **`Modules/ZilRead.mod`** — the reader, ported from
  `Zilf/Language/Parsing/Parser.cs` (+ `CharBuffer.cs`). One large
  self-recursive `ReadOne` procedure (see "Oberon-specific gotchas" below
  for why it isn't factored into smaller mutually-recursive helpers).
  Handles: `<...>` FORM, `(...)` LIST, `[...]` VECTOR, `"..."` STRING,
  `!\X`/`!"X` CHARACTER, `.X`/`,X`/'X sugar (LVAL/GVAL/QUOTE), `!<...>` /
  `!.X` / `!,X` / `!'X` SEGMENT, `X:Y` ADECL, `;X` datum comments, `;;text`
  line comments, decimal/`-`/`+`-signed FIX, `*NNN*` octal FIX, `#16 XX`
  hex FIX.
- **Tested**: `/private/tmp/.../scratchpad/sample1.zil` (a representative
  snippet — `ROUTINE`, `OBJECT` with a property list, `GLOBAL`, `CONSTANT`
  in decimal/octal/hex, nested `COND`/`EQUAL?`/`TELL`, `SETG`/`SET`,
  `,GVAL`/`.LVAL`/`'QUOTE` sugar, both comment forms) round-trips through
  `ZilRead.ReadOne` + `ZilObj.PrintTo` correctly, verified by eye against
  the input. Re-run this before trusting any future refactor of these two
  files — there is no automated test harness yet (consider adding one
  early in phase 2, since regressions here would be silent and costly
  later).

### Simplifications made in phase 1 (pragmatic subset — flag to user later)

- **Single flat OBLIST.** The original has a full package/OBLIST hierarchy
  (`FOO!-BAR` = atom `FOO` in oblist `BAR`, nested `<1 .OBLIST>` search
  paths, `ZILCH` vs user packages). This port uses one global hash table
  (`ZilObj.Intern`). Real ZIL library code sometimes uses qualified atoms;
  if/when that turns out to matter, revisit `ZilAtom.Parse` in the
  original (`Interpreter/Values/ZilAtom.cs`) for the real algorithm.
- **`%` and `#TYPE (...)` are parsed but not evaluated.** `%<...>` returns
  its argument unevaluated (should evaluate it at read time, needs phase
  2's interpreter). `#ATOM (...)` returns the inner value un-retyped
  (should CHTYPE it, needs phase 2's type system). `ZilRead.Reader` sets
  `sawPercent`/`sawChtype` flags so a caller can at least warn. This means
  phase 1 alone will silently produce semantically-wrong results for any
  source using these — **do not treat phase-1 parse success as "this file
  is understood correctly," only as "structurally well-formed."**
  Revisit once phase 2 exists: the fix is to actually call into the
  evaluator/CHTYPE machinery from inside `ReadOne` at those two call sites.
- **No `{n}` template-parameter substitution** (macro-template reading,
  only meaningful via the interpreter) — not implemented at all yet.
- **No binary `#2 ...` literals** (rare in practice) — not implemented;
  hex `#16 ...` IS implemented since real source uses it more.
- **ZilString has no `OffsetString` sharing view** — `ZilObj` strings are
  plain fixed buffers; a `REST`-style substring would need to copy (no
  such operation exists yet in the port anyway — that's a phase-2/3
  concern once `IStructure` operations are ported).
- **`ZilVector` has no `Grow`/`BaseOffset` view tricks** — not needed yet
  since nothing mutates vectors in place in phase 1.
- **No circular-structure-safe printing** (`Recursion.TryLock` in the
  original) — `ZilObj.PrintTo` will loop forever on a circular structure.
  Real ZIL source essentially never constructs one before this stage, so
  low priority; revisit if it ever matters.
- **Mid-atom `!` escaping is approximated**, not a byte-exact port of the
  original's subtle rule (see comments at the top of `ZilRead.mod`). Only
  `!-` (needed for the oblist-qualifier syntax, itself not really acted on
  per the point above) is preserved specially; any other embedded `!` just
  drops itself and reprocesses the next character normally.

### Oberon-specific gotchas hit again in phase 1 (same ones as zapf — keep watching for these)

- **No `FORWARD` declarations.** `ReadOne` needed to recursively read
  sub-elements of lists/forms/vectors/adecls — the natural factoring
  (`ReadOne` calls `ReadStructure`, `ReadStructure` calls `ReadOne`) is a
  mutual recursion Oberon can't express here. Fix: **one big self-recursive
  procedure** with the list/form/vector/adecl reading bodies inlined
  directly (see `ZilRead.mod`'s `ReadOne`) rather than factored out.
  *Self*-recursion (a procedure calling itself) is fine — this restriction
  only bites *mutual* recursion between two named procedures.
- **A `PROCEDURE` with a return type must be called as an expression, not
  a bare statement** — obvious in hindsight, but an early draft of
  `ZilRead.mod` called `ReadOne(...)` as a statement and tried to fetch its
  result from a phantom variable afterward. Oberon has no implicit
  "last call's return value" — always capture into a local var:
  `x := ReadOne(rd, ...)`.
- **`Strings.Append` takes a *string* (`ARRAY OF CHAR`), not a `CHAR`.**
  Appending one character needs a small local helper
  (`AppendChar(c: CHAR; VAR s: ARRAY OF CHAR)` in `ZilObj.mod`) that writes
  directly into the array and re-terminates it — passing a bare `CHAR`
  where `Strings.Append` expects a string fails at the C-compilation stage
  with a confusing pointer/int mismatch, not at the Oberon level.
- **An exported top-level `VAR` name becomes a bare, unscoped C `#define`.**
  Bit us on zapf (`ZapfOpcodes.count`/`.table` collided with unrelated
  `.count` struct-field access elsewhere in the linked program). Keep
  exported module-level `VAR` names distinctive; this doesn't affect
  `RECORD` field names (those are fine, as seen throughout `ZilObj.mod`).

## What's done (phase 2) — files, and what's tested

**`Modules/ZilEval.mod`**, plus binding/property-list fields added to
`ZilObj.ZoDesc` (`globalVal`, `localVal` on atoms; a per-object `assoc`
linked list for `PUTPROP`/`GETPROP` — see the file for why these live
directly on the value's own record rather than in a separate table keyed
by object identity, which is what the original does).

**A key semantic fact, verified against `Subrs.Atoms.cs` before writing
any of this and worth restating because it's easy to get backwards: a
bare ATOM is self-evaluating in ZIL, not a variable reference.**
`<SET X 5>` works because evaluating `X` (as SET's already-evaluated SUBR
argument) just yields the atom `X` itself; real variable dereference is
always explicit (`.X`/`<LVAL X>` for locals, `,X`/`<GVAL X>` for globals).
`ZilForm.EvalImpl`'s head-atom lookup (global-then-local, in that priority
order — also verified, and non-obvious) is the *only* place a bare atom's
value is actually consulted, and only to decide what to call.

Implemented and working:
- `ZResult` (the `Outcome`-tagged value/signal type — `OValue`/`OReturn`/
  `OAgain`, matching the original's `ZilResult` design exactly; only
  `OValue` is actually produced yet, since nothing needing `RETURN`/`AGAIN`
  targets — i.e. `PROG`/routine calls — exists yet).
- `Eval`, self-recursive (same reason as `ZilRead.ReadOne` — no `FORWARD`),
  handling: self-evaluating ATOM/FIX/STRING/CHARACTER/VECTOR/FALSE/SUBR/
  FSUBR; ADECL (evaluates its first part, DECL check skipped); SEGMENT
  (errors — only valid spliced into a structure, not implemented); LIST
  (evaluates each element into a new list — no SEGMENT-splicing yet,
  errors if one appears); FORM (the real "apply" logic: global-then-local
  head lookup, then FSUBR args-unevaluated vs SUBR args-evaluated-first
  dispatch).
- FSUBRs (inlined into `Eval` itself, for the same forward-reference
  reason SUBR dispatch isn't): `QUOTE`, `COND`, `AND`, `OR`.
- SUBRs (factored into `ApplySubr`, which — unlike the FSUBRs — never
  calls `Eval` itself, so it *can* be declared separately without hitting
  the forward-reference restriction): `SET`, `SETG`/`GLOBAL`, `LVAL`,
  `GVAL`, `GASSIGNED?`, `ASSIGNED?`, `PUTPROP`, `GETPROP`, `+`, `-`, `*`,
  `/`, `MOD`, `1+`, `1-`, `=?`/`EQUAL?`/`==?`, `N=?`/`N==?`, `L?`, `G?`,
  `L=?`, `G=?`, `NOT`, `PRINC`, `PRIN1`, `PRINT`, `CRLF`.
- **Tested**: `/private/tmp/.../scratchpad/sample2.zil` + `evaltest.mod` —
  18 top-level forms covering every SUBR/FSUBR above, including the exact
  milestone from this doc's previous revision (`<SET X <+ 1 2>>` → `3`).
  **All 18 produced the correct result**, cross-checked by hand (arithmetic,
  `COND` branch selection, `PUTPROP`/`GETPROP` round-trip, atom
  self-evaluation and identity comparison via `=?`). Re-run this before
  trusting any refactor of `ZilObj.mod`/`ZilEval.mod`, same caveat as
  phase 1's reader test — no automated harness yet.

### New Oberon-specific gotcha found this session

- **A single-character string literal (e.g. `"+"`) is inferred as `CHAR`
  by this transpiler**, even in a context comparing it against a `ARRAY OF
  CHAR` variable — `name = "+"` silently mistranslates to a `strcmp` call
  with a raw `char` argument and fails at the **C compilation** stage, not
  at the Oberon-parsing stage (confusing pointer/int-conversion error).
  Fix: compare length-then-first-char instead, exactly as this transpiler's
  own examples do for genuine `CHAR` comparisons — see `ZilEval.mod`'s
  `IsOp` helper. Only bites *single-character* string literals; multi-char
  ones (`"ADD"`, `"SUB"`, etc.) are unaffected.
- Hit the `n.e.text`-style pointer-chain bug from zapf *again*
  (`z.first.kind`, `z.rest.first`, etc. — any `.field` chained through a
  second pointer-typed field in one expression). Same fix as before:
  assign the intermediate pointer to a local variable first, then access
  the second field off *that*. Given this has now bitten twice independently,
  **audit for this pattern as a matter of course whenever writing a chained
  field access through more than one pointer**, don't wait to hit the C
  compile error.

## What's done (phase 2b: PROG/REPEAT/BIND) — files, and what's tested

Read `Zilf/Interpreter/Context.cs` in full (all 1,457 lines — confirms
`LocalEnvironment` is a real per-call lexical-chain structure, not a
single global slot, but since lookups only ever walk the *dynamic* call
chain (each `PushEnvironment` chains onto whatever environment is
currently active, not a captured lexical closure), it's externally
equivalent to dynamic/shallow binding on a single slot per atom — this
confirms phase 2's `localVal`-on-the-atom simplification was sound and
didn't need revisiting) and `Subrs.Loops.cs` (`PROG`/`REPEAT`/`BIND`/
`RETURN`/`AGAIN`, ~150 lines) in full.

Added to **`ZilObj.mod`**: a `KActivation` kind (`NewActivation`) — an
activation's identity is just its pointer, matching the original's C#
reference-equality use of `ZilActivation`; the atom's own `atomText`
field is reused to hold its display name (same trick as `KSubr`/`KFSubr`).

Added to **`ZilEval.mod`**: `PROG`, `REPEAT`, `BIND` (inlined FSUBRs in
`Eval`, same forward-reference reason as `QUOTE`/`COND`/`AND`/`OR`), and
`RETURN`/`AGAIN` (ordinary SUBRs in `ApplySubr`, factored into a small
`ApplyReturnOrAgain` helper since — unlike the FSUBRs — they don't call
`Eval` and so aren't subject to the forward-reference restriction).

**Key implementation points, all verified against the original before
coding:**
- A named activation (`<PROG FOO (X) ...>`) needs **no special-case
  machinery at all**: `FOO`'s `localVal` is simply bound to the
  `KActivation` value like any other PROG binding, so `<RETURN val .FOO>`
  (an ordinary `LVAL`) fetches it naturally, and `RETURN`'s SUBR
  implementation just checks the fetched arg's kind. This mirrors the
  original exactly (`ZilActivation` flows through as an ordinary
  already-evaluated SUBR argument).
- The **default (unnamed) enclosing-PROG lookup** uses one internal,
  non-user-visible atom (`ZilObj.Intern("LPROG ")` — note the trailing
  space, copied deliberately from the original's own
  `EnclosingProgActivationAtom` naming trick, since a real ZIL atom name
  can't contain a space) whose `localVal` is rebound by `PROG`/`REPEAT`
  (not `BIND` — this is the original's `catchy` flag) using the exact
  same save/restore-on-the-atom's-own-slot mechanism as every other
  binding. This is what makes a bare `RETURN`/`AGAIN` skip over an
  enclosing `BIND` and find the next real `PROG`/`REPEAT` outward,
  exactly like the original.
- **No `try`/`finally` in Oberon**: every bound atom's previous `localVal`
  (params, the optional name, and — for `PROG`/`REPEAT` —
  `enclosingProgAtom` itself) is recorded in one flat array as bindings
  are established, and restored in a single pass immediately before the
  branch's one `RETURN r` at the very end — every internal exit path
  (`RETURN`/`AGAIN` targeting this activation, an escaping signal
  targeting an outer one, normal fall-through) sets a `progStop`/loop-exit
  flag and falls through to that same shared restore-then-return tail
  rather than returning early. The one exception is genuinely malformed
  input (missing bindings list, non-atom binding target, too many
  bindings) — those `RETURN Err(...)` immediately without restoring
  bindings established so far, matching this port's existing philosophy
  elsewhere that parse-shape errors are fatal-ish, not designed for clean
  continuation.
- **`AGAIN` mid-body does not short-circuit the rest of that body pass** —
  verified against `PerformProg`'s C# (`if (result.IsAgain(...)) { again =
  true; }` has no `continue`/`break`, so remaining top-level body forms in
  the *same* pass still evaluate before the loop actually restarts) and
  replicated exactly: the Oberon `WHILE` only sets `progAgain := TRUE` and
  falls through to the next body form, never `EXIT`s for that case.

**Tested**: `/private/tmp/.../scratchpad/sample3.zil` + `eval3test.mod` —
7 forms covering: a plain `PROG` with sequential `SET`s (`=> 6`); a
binding-list initializer (`=> 15`); a bare `RETURN` short-circuiting the
rest of a `PROG` body (`=> 99`); `REPEAT` + `RETURN` as a counting loop
(`=> 5`); a nested `PROG` where the inner `RETURN` unwinds only the inner
activation (`=> 43`); a **named activation** where `RETURN .Y .FOO` inside
a `BIND` skips the `BIND` and unwinds straight to the outer `PROG FOO`,
never reaching the `SET X 999` after it (`=> 2`); and `AGAIN` restarting a
`REPEAT` (`=> 3`). **All 7 produced exactly the expected result.** Re-ran
phase 1's `sample1.zil` and phase 2's `sample2.zil` too — no regressions.

## What's done (phase 2c: DEFINE/DEFMAC function & macro application) — files, and what's tested

Resolved last session's open question by reading
`Zilf/ZModel/Values/ZilRoutine.cs` in full: **`ZilRoutine` (the `ROUTINE`
keyword) has no `IApplicable`, `Apply`, or `Eval` override at all** — it's
a `ZModel` value with only an `ExpandInPlace` method that macro-expands its
argspec defaults and body in place, for the phase-3 *compiler* to consume
later. **Interpret-time routine application is not a real original
behavior** — routines are compiled, never `Eval`'d directly. This settles
the question: the valuable next slice was function/macro application, not
"routine application".

The actual interpret-time-callable thing is **`ZilFunction`** (used by
both `DEFINE`/`DEFINE20` and, wrapped in a `ZilEvalMacro`, by `DEFMAC`) —
read `ZilFunction.cs`, `ZilEvalMacro.cs`, and `ArgSpec.cs`'s `BeginApply`
(the real argument-binding algorithm) in full. **Non-obvious semantic
point, verified against `ZilForm.EvalImpl`'s applicable-head dispatch
before coding**: a ZIL `DEFMAC` macro is *not* like a Lisp `defmacro` —
its call-site arguments are evaluated completely normally (self-evaluating
atoms make this usually invisible), and it's the macro function's *return
value* that gets treated as a new FORM and `Eval`'d again (`ZilEvalMacro.
Apply` = `Expand` then `.Eval()` the expansion) — not its arguments that
are left unevaluated the way a Scheme/CL macro's are.

Added to **`ZilObj.mod`**: `KFunction` (`funcArgSpec` — kept as a *raw,
unparsed* arg-spec list and walked afresh on every call rather than
pre-compiled, since call frequency at this level makes that irrelevant;
`funcAct`; `funcBody`) and `KMacro` (`macWrapped`).

Added to **`ZilEval.mod`**: `DEFINE`/`DEFINE20`/`DEFMAC` (a standalone
`ApplyDefine` procedure — doesn't call `Eval`, just builds and stores a
value, so unlike the apply logic below it isn't subject to the
forward-reference restriction), and the actual function/macro **apply**
logic (inlined in `Eval`, same reason as `PROG`/`REPEAT`/`BIND` — reuses
the *exact same* flat-array save/restore-bindings pattern). Also added
`FORM`, `LIST` (evaluated-arg cons-chain builders, needed so a macro body
can construct its expansion), and `LENGTH?` (needed for a `"ARGS"`-style
recursive base case — ported faithfully: returns the actual length as a
FIX if `<=` the given limit, else `FALSE`, not a plain boolean — verified
against `Subrs.Structures.cs`).

**Argument-spec subset implemented** (the common real-world shape,
verified against `ArgSpec.Parse`/`BeginApply`): required positional atoms,
`"OPT"` (with optional `(atom default-expr)` — defaults evaluate in the
new environment, so they can see earlier-bound params, matching the
original), `"AUX"` (same shape, never filled from call-site args), and
`"ARGS"`/`"TUPLE"` (gathers all remaining call-site args, evaluated, into
one LIST). The optional leading activation atom (`<DEFINE F ACT (...) ...>`)
reuses the exact same mechanism as `PROG`'s named activation. **Deliberately
NOT ported** (pragmatic subset, revisit only if real source needs them):
DECL checking/type declarations anywhere in the spec, quoted (unevaluated)
individual arguments, and the `"CALL"`/`"BIND"`/`"VALUE"`/`"NAME"`/`"ACT"`
one-off clauses inside the arg list itself (as opposed to the leading
activation atom, which *is* supported). Also **not ported**: the
already-defined/redefinition check (`AllowRedefine`) — this port always
silently allows redefinition, which is actually convenient for iterative
test-file development.

**Key implementation points confirmed against the original before
coding**: entering *any* function/macro application unconditionally clears
`enclosingProgAtom` (an opaque boundary for a bare `RETURN`/`AGAIN`,
whether or not the function has its own activation atom — verified via
`ArgSpec.BeginApply`'s unconditional `innerEnv.Rebind(EnclosingProgActivationAtom)`
with no value, i.e. unassigned); a function *with* its own activation atom
behaves like a hybrid of `PROG` and `REPEAT` — runs its body once via the
equivalent of the original's `EvalProgram` (evaluate forms in sequence,
stop and propagate on *any* non-Value signal, no activation-awareness at
that level), but if the result is `AGAIN` targeting its *own* activation it
restarts (unlike plain `PROG`), and if `RETURN` targets its own activation
that becomes the final value (like `PROG`); with *no* activation atom, the
raw result of the body (value or escaping signal) is returned completely
as-is, with no interpretation at all.

**Tested**: `/private/tmp/.../scratchpad/sample4.zil` + `eval4test.mod` —
15 forms: a plain required-arg function (`ADD1`, `=> 6`); `"OPT"` with a
default expression (`ADDN`, `=> 11` / `=> 15`); `"AUX"` (`DOUBLE-PLUS-ONE`,
`=> 9`); `"ARGS"` gathering 3 call-site args into a LIST, checked via
`LENGTH?` (`=> 3`); a **recursive factorial** using `"AUX"` + `REPEAT` +
bare `RETURN` inside a function with no activation atom of its own
(`FACT 5 => 120`, exercising the enclosing-activation-boundary-clearing
behavior for real); a `DEFMAC` that builds `<FORM + .X .X>` and gets it
evaluated (`DOUBLE 21 => 42`); and a `DEFMAC` that uses its own *evaluated*
argument (a `COND` test result) to decide what `COND`-form to splice
together via `FORM`+`LIST` (`MY-IF <G? 5 3> "yes" "no" => "yes"`). **All 15
produced exactly the expected result.** Re-ran phases 1, 2, and 2b's
existing tests too, plus the full `Modules/*.mod`+`examples/*.mod`
regression suite (135 files) — no regressions anywhere.

## What's still needed for a complete phase 2 (Interpreter core)

1. **`ObList.cs`** (145 lines, read in phase 2b) confirms the real
   package/OBLIST hierarchy this port's `ZilObj.Intern` flattens away is
   just a name→atom hash table per oblist, same shape as the flat one
   already implemented — extending to multiple named oblists later (if it
   turns out to matter) should be a moderate, not a rearchitecting, change.
2. **`StdAtom` table** (`Language/StdAtom.cs`, 374 lines) — an enum of
   every special atom the interpreter/compiler hard-codes checks against.
   Still being ported incrementally on demand (plain interned-string
   comparisons so far, no enum yet) — keep doing that rather than porting
   all 374 up front; revisit if the on-demand string-comparison approach
   starts feeling unwieldy once dozens of builtins exist.
3. **CHTYPE / type system**: `PrimType` (ATOM/FIX/STRING/LIST/VECTOR — the
   "primitive representation" every ZIL type ultimately reduces to) and
   the `BuiltinType`/`ChtypeMethod` attribute-driven coercion machinery.
   Needed to make phase 1's `#TYPE (...)` stub actually retype values.
4. Now that phase 2c's function/macro application exists, **go back and
   fix phase 1's two remaining `ZilRead.mod` stubs** (`%` compile-time eval
   should call `ZilEval.Eval`; `#TYPE (...)` CHTYPE still needs #3 above
   first) instead of passing their argument through unevaluated/unretyped.
   This unlocks reading real macro-heavy library/game source *while
   reading it*, not just evaluating already-read forms.
5. **Widen the argument-spec subset** (see phase 2c's "deliberately not
   ported" list) only on demand, the same way builtins are added on
   demand — don't speculatively build out DECL checking, quoted args, or
   the `"CALL"`/`"BIND"`/`"VALUE"`/`"NAME"` one-offs until a real macro
   from actual library/game source needs one.
6. **`ArgSpec.cs`/`ArgDecoder.cs`**'s SUBR-argument-checking half (as
   opposed to the FUNCTION/MACRO-argument-binding half phase 2c already
   covers) remains **deliberately not ported as a generic system** —
   `ApplySubr` just hand-checks each builtin's own arg count/types inline
   (same philosophy as zapf's `HandleInstruction`). Keep doing this for
   new builtins; only reconsider if the per-builtin boilerplate becomes
   the bottleneck.

## What phase 3+ needs to cover (Compiler / ZModel / Emit.Zap)

Not researched in depth yet this session beyond directory/size survey.
Before starting:
- Read `Zilf/Compiler`'s top-level driver file(s) first to understand the
  overall compile pipeline shape (likely: read all top-level forms via
  phase 1+2, sort into routines/objects/globals/constants/tables via
  `ZModel`, then compile each routine's body to Z-machine instructions via
  `Compiler/Builtins/*.cs`, emitting through the `Zilf.Emit` abstraction).
- Read `Zilf.Emit` root (3,108 lines) and `Zilf.Emit/Zap` (4,548 lines)
  together to determine whether the generic `IGameBuilder` abstraction
  (shared across Zap/Glulx/Cornerstone) is worth porting, or whether the
  Oberon port can have the compiler call directly into Zap-shaped
  procedures (routine-builder, object-builder, table-builder, etc.) and
  skip a layer of indirection that only exists to support multiple
  backends we've already decided to drop down to one.
- `Zilf/Compiler/Builtins` (4,439 lines within the 13,187 Compiler total)
  is the ZIL-builtin-to-Z-machine-instruction mapping (e.g. `<TELL>` →
  `PRINTI`/`PRINTR`, `<MOVE>` → the `MOVE` zapf instruction, `<FSET?>` →
  `FSET?`) — this is the most directly analogous piece to zapf's
  `Opcodes.cs`/instruction-encoding work, and probably the safest place to
  resume concrete porting work once phases 1-2 are solid, since each
  builtin can be ported and tested somewhat independently (compile one
  tiny routine using it, check the emitted `.zap` text, feed it through
  our zapf, run it in `examples/zmachine.mod`) — this mirrors exactly how
  zapf itself was validated end-to-end.

## Suggested order for the next session

1. Re-run all four existing test harnesses to confirm nothing regressed:
   phase 1's `sample1.zil` (`readtest.mod`), phase 2's `sample2.zil`
   (`evaltest.mod`), phase 2b's `sample3.zil` (`eval3test.mod`), and phase
   2c's `sample4.zil` (`eval4test.mod`). (All live under the session's
   scratchpad, which may not survive between machine sessions — if gone,
   they're small and quick to recreate from this doc's descriptions of
   what they cover.) Also re-run the transpiler's own full
   `Modules/*.mod`+`examples/*.mod` regression suite if any transpiler
   work happened in between sessions.
2. With phases 1-2c now covering read + eval + control flow + function/
   macro application, real (if simple) ZIL *library-style* source — code
   that defines and uses its own `DEFMAC` macros — should now be
   evaluable end-to-end for the first time. Before writing more
   interpreter features on spec, it's worth trying a short real excerpt
   from `~/lib/src/zilf`'s own library files (or a small real game's
   source) through phases 1-2c as a sanity/integration check, expecting
   it to fail on something specific — that failure is the most
   trustworthy signal for what to port next, more so than continuing to
   guess from the "what's still needed" list above.
3. Otherwise, pick from the "what's still needed" list above — items 4
   (fixing phase 1's `%`/`#TYPE` stubs now that Eval exists) and 1
   (`ObList`, if a real source file turns out to need qualified atoms)
   are the most likely to matter soon; the rest are genuinely on-demand.
4. Once phase 2 feels solid (or once real source above exposes what's
   still missing), move to **phase 3** (Compiler/ZModel/Emit.Zap) — see
   that section below for where to start reading first.
5. Update this doc's "what's done" section and commit again.
