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
reuses the exact same mechanism as `PROG`'s named activation. Quoted
(unevaluated) individual arguments (`'N`) were initially skipped here too,
but turned out to be needed almost immediately — see phase 2d below.
**Still deliberately NOT ported** (pragmatic subset, revisit only if real
source needs them): DECL checking/type declarations anywhere in the spec,
and the `"CALL"`/`"BIND"`/`"VALUE"`/`"NAME"`/`"ACT"` one-off clauses inside
the arg list itself (as opposed to the leading activation atom, which *is*
supported). Also **not ported**: the already-defined/redefinition check
(`AllowRedefine`) — this port always silently allows redefinition, which
is actually convenient for iterative test-file development.

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

## What's done (phase 2d: quasiquote, quoted args, and two real reader bugs) — files, and what's tested

Followed this doc's own "Suggested order" advice: tried a short real excerpt
through phases 1-2c instead of continuing to guess from the TODO list —
`~/lib/src/zilf/sample/beer/beer.zil` (the 99-bottles-of-beer sample). This
immediately surfaced three real, previously-unknown gaps, all now fixed:

1. **Quasiquote (`` ` ``/`~`) is not a niche feature.** Before assuming it
   was skippable (`beer.zil` only needs it because it explicitly
   `<USE "QQ">`s), grepped all of `zillib/*.zil` and every `sample/*/*.zil`:
   `` `<...> `` is used pervasively across the **core** zillib files
   (`parser.zil`, `scope.zil`, `verbs.zil`, `pronouns.zil`, `template.zil`,
   `orphan.zil`, `status.zil`, `pseudo.zil`) and most of the real game
   samples — not an opt-in extra. This is essential, not optional, for the
   "pragmatic subset covering common real ZIL games" goal.

   The real implementation (`zillib/qq.mud`) is itself an ordinary ZIL
   library built on CHTYPE/NEWTYPE, the full PACKAGE/OBLIST hierarchy,
   MAPF/MAPRET, APPLY, and PRIMTYPE reflection, registering `` ` ``/`~` at
   runtime via a `MAKE-PREFIX-MACRO` SUBR this port has none of the
   infrastructure for. Rather than port that whole mechanism, this
   implements the same *observable* behavior natively — same
   "pragmatic reimplementation over faithful port" approach already used
   for `PROG`/`REPEAT`/`BIND` vs. `LocalEnvironment`.

   - **`ZilRead.mod`**: `` ` ``/`~` are new reader prefix chars (mirroring
     the existing `.`/`,`/`'` → `LVAL`/`GVAL`/`QUOTE` sugar exactly),
     producing `<QUASIQUOTE X>` / `<UNQUOTE X>` — ordinary 2-element FORMs,
     no new `ZilObj` kinds needed. (Also bumped `atomName`'s buffer from
     `ARRAY 8 OF CHAR` to 16 — it was sized for `"QUOTE"`, silently
     truncating `"QUASIQUOTE"` to 7 characters.)
   - **`ZilEval.mod`**: the evaluator (`Eval`) is renamed to an internal
     `EvalImpl(z, qq: BOOLEAN)`, with `Eval*` now a thin
     `EvalImpl(z, FALSE)` wrapper — the quasiquote-walk mode and normal
     eval mode each need to call the other (`QUASIQUOTE`'s FSUBR case
     switches into walk mode; an `UNQUOTE`'d spot switches back out), so —
     same forward-reference reason as everything else self-recursive in
     this port — they have to be one procedure. Every one of the ~16
     existing self-recursive call sites was mechanically updated
     (`Eval(x)` → `EvalImpl(x, FALSE)`) via a scripted regex pass (verified
     safe first: every call site's argument was a single simple
     expression, no nested calls, so no ambiguity) rather than by hand, to
     avoid missing one.
   - **Semantics** (verified against `qq.mud`'s `QQ-IMPL` before coding,
     then reimplemented natively): a non-structured leaf (ATOM/FIX/STRING/
     etc.) passes through completely literally, unevaluated; a LIST/FORM
     is rebuilt recursively with the same shape; `~X` evaluates `X`
     normally and substitutes the single result; `~!X` (unquote wrapping a
     SEGMENT — matching the original's own splicing detection, which is
     also just "unquote of a segment") evaluates `X` normally and splices
     *its* elements into the surrounding LIST/FORM instead of inserting
     one — this needed special-casing in the rebuild loop itself (peeking
     at each raw element's shape before recursing), since splicing must be
     able to contribute zero or many elements, which a single recursive
     return value can't represent. VECTOR is walked too (real templates
     use it far less than FORM/LIST) but **without splice support** —
     pragmatic subset. ADECL bodies and a bare top-level `~!X` (splicing
     with nothing to splice into) are not specially handled either.

2. **Quoted individual arguments** (`'N` in an arg-spec, e.g.
   `DEFMAC BOTTLES ('N)`) — the other deliberately-skipped-in-phase-2c
   feature that `beer.zil` turned out to need immediately: a quoted
   parameter binds the caller's *literal, unevaluated* argument form
   rather than its evaluated value. This is *the* standard ZIL idiom for
   writing a macro that syntactically re-embeds one of its own arguments
   into generated code (quote it going in, `~`-unquote it back out inside
   the quasiquote template) so the generated code, evaluated later in the
   *caller's* scope, refers to the caller's own variable — not a value
   frozen at macro-expansion time. Verified against `ArgSpec.Parse`'s own
   ADECL-then-QUOTE unwrap order and matched it. **Found and fixed a real
   bug while wiring this up**: a bare `<QUOTE atom>`-shaped spec item
   (`fnOneSpec.kind = ZilObj.KForm`) didn't match any of the existing
   item-shape branches (bare ATOM / ADECL / 2-list-with-default) and fell
   straight into the "malformed argument-list entry" error *before* ever
   reaching the new quote-unwrapping check — needed its own branch in the
   shape dispatch purely to flow through to the check below it.

3. **Two real, previously-latent bugs found and fixed while chasing why
   `beer.zil` still wouldn't read even after (1) and (2) landed** — both
   completely unrelated to quasiquote, and both worth calling out because
   they'd silently corrupt *any* bang-prefixed token (`!\X` character
   literals, `!.X`/`!,X`/`!'X`/`!<...>` segments) that follows whitespace
   preceded by anything else, which just hadn't been exercised by any
   earlier test file:
   - **`ZilRead.mod`'s `SkipWhitespace` had a single-slot pushback bug.**
     Its own "`!` immediately before real whitespace is itself whitespace"
     rule needs to push back *two* characters (the `!` and whatever
     followed it) so the main dispatch's separate bang-lookahead can
     re-read them in order — but `Reader.heldChar` was a single `INTEGER`
     slot, so the second `PushBack` call silently overwrote the first,
     losing a character and desynchronizing the whole rest of that token
     read (e.g. `<PRINTC !\s>` would lose the `\` and instead read the
     *next* raw byte in the stream as if it were the character right after
     `!`, eventually producing "empty atom" errors several characters
     later with no direct connection to the real cause). Fixed by making
     the pushback buffer a proper 2-deep LIFO stack (`heldChar`+
     `heldChar2`). Isolated repro (confirmed failing before, passing
     after): `<A !\B>` — a bang-prefixed token as anything but a FORM's
     very first element.
   - (Same session, same root cause class, listed under (1) above for
     where it was found) the `atomName` buffer truncating `"QUASIQUOTE"`.

**Tested**: `/private/tmp/.../scratchpad/sample5.zil` + `eval5test.mod` —
basic substitution (`` `<FOO ~.X BAR>` `` with X=5 `=> <FOO 5 BAR>`),
nested lists with a computed unquote (`` `(A ~.X (NESTED ~<+ .X 1>) C)` ``
`=> (A 5 (NESTED 6) C)`), unquote-splicing (`` `<ADD ~.X ~!.LST>` `` with
LST=(1 2 3) `=> <ADD 5 1 2 3>`), and **the actual `beer.zil` `BOTTLES`
macro verbatim** (quoted `'N`, quasiquoted `PROG` template, `~.N` splicing
the caller's own reference back in) called from a real `DEFINE`d function
— correctly prints "7" then (since `N==?` means *not* exactly equal, verified
against `Subrs.Math.cs` before trusting the output) pluralizes with an "s"
for `N=7` but not for `N=1`, exactly matching real English-pluralization
behavior and confirming the whole macro pipeline end-to-end. Also
confirmed via `readbeer.mod` that **the entire real `beer.zil` file now
reads without error** (`ROUTINE`/`GO`/`SING` bodies parse fine as inert
data — actually *compiling* them is phase 3's job). Re-ran every earlier
phase's existing tests, plus the full transpiler `Modules/*.mod`+
`examples/*.mod` regression suite (135 files) — no regressions anywhere.

Also added (needed to make the `BOTTLES` test actually runnable):
`PRINTN`, `PRINTC` SUBRs in `ZilEval.mod`.

## Milestone: the reader (phase 1) validated against the entire real corpus

Per this doc's own "try another small real sample" suggestion, but scaled
up: rather than one file at a time, wrote a generic `readfile.mod` harness
(takes a path via `Args`, reads every top-level form, reports the count or
the first error) and ran it over **every single `.zil` file in
`~/lib/src/zilf/zillib/` and `~/lib/src/zilf/sample/`** — 84 files total,
zero filtering/cherry-picking. This includes the entire core library
(`parser.zil` — 357 top-level forms, `verbs.zil` — 274, `scope.zil`,
`pronouns.zil`, `libmsg-defaults.zil`, every other `zillib/*.zil`) and
every sample game (`advent.zil` — 608 forms, `cloak.zil`, `rascal/*.zil`,
and the **complete real Zork 1 source** — `1dungeon.zil`, `1actions.zil`,
`gparser.zil`, `gsyntax.zil`, `gmain.zil`, `gverbs.zil`, `gclock.zil`,
`gglobals.zil`, `gmacros.zil`, `zork1.zil`).

**All 84 files read with zero errors.** This is a strong, broad validation
that phase 1 (plus phase 2d's two reader bug fixes) is solid against real,
unmodified, production ZIL source at real-game scale — not just the small
hand-written samples used to build each phase. Re-run this
(`readfile.mod` — recreate from this description if the scratchpad is
gone; it's ~25 lines) as a fast regression check after any future
`ZilRead.mod` change, the same way the smaller phase-specific tests are
re-run after `ZilEval.mod`/`ZilObj.mod` changes.

**What this does and doesn't prove**: it proves the reader's *syntax*
coverage is complete enough for real source. It does **not** exercise
evaluation — `ROUTINE`/`OBJECT` bodies read as inert structured data at
this stage (correct — see phase 2c's finding that routines are compiled,
never interpreted) and nothing here calls `Eval` on these files' top-level
forms. Doing that next would immediately hit unimplemented FSUBRs
(`ROUTINE`, `OBJECT`, `GLOBAL`, `SYNTAX`, etc. aren't registered at all
yet — phase 2's builtin set was only ever built from small hand-written
test files, not from what real top-level game/library forms actually use)
and wouldn't currently produce an informative signal beyond "phase 3's
ZModel doesn't exist yet", which is already known. The next genuinely
informative experiment along these lines would be evaluating a real
library file's **macro *definitions*** in isolation (skipping `ROUTINE`/
`OBJECT`/etc. top-level forms, evaluating only the `DEFINE`/`DEFMAC` ones)
to see how much further phase 2's builtin set needs to grow before that
works — `pronouns.zil` (read above, 12 forms) is a good candidate: it
defines real macros using `DEFSTRUCT`, `MAPF`, `EVAL` with an explicit
environment argument, `PARSE`, `STRING`, `VOC`, and `TYPE?` — all
currently unimplemented — so it would surface a realistic, prioritized
list of what phase 2 still needs, the same way `beer.zil` did for phase 2d.

## What's done (phase 2e: CONSTANT, and a full-corpus gap analysis)

Followed through on the milestone section's own suggestion: evaluated
(not just read) `zillib/pronouns.zil`'s top-level forms with a new generic
`evalfile.mod` harness (like `readfile.mod`, but calls `ZilEval.Eval` on
each form and reports the result or error). Of its 12 top-level forms, 8
already succeeded outright (`SETG`, both real `DEFINE`s, `PUTPROP`) even
though this file needed `DEFSTRUCT`/`MAPF`/`EVAL`-with-environment/`PARSE`/
`STRING`/`VOC`/`TYPE?` per the milestone's own prediction — because a
`DEFINE`d function's *body* only needs those builtins when the function is
actually *called*, and none of `pronouns.zil`'s functions are called at
its own top level (they're defined for other files to call later). This
revises last section's prediction: defining real library macros is easier
than expected; only 4 forms failed (`FILE-FLAGS`, `DEFSTRUCT`, `ROUTINE`×2)
and all 4 are legitimately phase-3 (compiler/`ZModel`) concerns, not
phase-2 gaps.

**Added `CONSTANT`** (`ZilEval.mod`): verified against `Subrs.ZModel.cs`
that the original's `CONSTANT`/`GLOBAL` are FSUBRs (name unevaluated,
value explicitly `Eval`'d inside the SUBR body) rather than plain
evaluated-args SUBRs — but since a bare ATOM name (the common case) or an
ADECL name (this port's usual "DECL checking skipped" simplification
already reduces `Eval`uating an ADECL to its bare atom) self-evaluate to
exactly what the FSUBR form would bind anyway, folding `CONSTANT` into the
existing evaluated-args `SET`/`SETG`/`GLOBAL` SUBR case produces the same
observable result for real source, with no new FSUBR case needed.

**Then ran `evalfile.mod` over the entire 84-file corpus** (same set as
the reader milestone) and aggregated every "calling unassigned atom"
error by name, to get a real, prioritized, whole-corpus signal instead of
one file's — this is the most important artifact of this session's work
for planning phase 3, so the full histogram is worth keeping here
verbatim (counts are *occurrences*, i.e. call sites, not distinct files):

```
1537 ROUTINE        92 SYNONYM        18 VERSION?
 479 OBJECT          82 VOC            18 REPLACE-DEFINITION
 450 SYNTAX          75 ITABLE         14 USE
 229 ROOM            73 INSERT-FILE    14 DELAY-DEFINITION
 192 TEST-CASE       70 DEFAULT-LIBRARY-MESSAGES   11 IF-DEBUG
  43 DEFAULT-DEFINITION   40 VERSION    9 ADD-TELL-TOKENS
  37 VERB-SYNONYM    37 EVAL            8 HINT, FILE-FLAGS (each)
  33 PROPDEF         32 TABLE           7 PTABLE, DEFSTRUCT (each)
  31 TEST-GO         28 TEST-SETUP      6 VECTOR, OBJECT-TEMPLATE (each)
  25 LTABLE          5 COMPILATION-FLAG-DEFAULT
  4 PRONOUN, PACKAGE, ENDPACKAGE, GDECL (each)
  3 STATUS-LINE-SECTION, SCORING-ACHIEVEMENTS, REPLACE-LIBRARY-MESSAGES, MAPF (each)
```

**Reading this list (grouped, not in count order):**
- **The Z-machine/`ZModel` core — by far the largest group, and
  confirms phase 3 dominates the remaining work exactly as the original's
  own source-size ratio predicted** (`Compiler`+`ZModel` ≈ 20,500 lines
  vs. `Interpreter` ≈ 16,900): `ROUTINE` (1537), `OBJECT`/`ROOM` (479+229),
  `SYNTAX` (450), `ITABLE`/`TABLE`/`LTABLE`/`PTABLE` (75+32+25+7),
  `PROPDEF` (33), `VERSION`/`VERSION?` (40+18), `GDECL` (4),
  `OBJECT-TEMPLATE` (6), `VECTOR`-as-a-top-level-form (6). None of this is
  a phase-2 gap; it's what phase 3 exists to build.
- **Parser/vocabulary table-building — also `ZModel`/`Vocab`, phase 3**:
  `SYNONYM`/`VERB-SYNONYM` (92+37), `VOC` (82), `DEFAULT-DEFINITION`/
  `REPLACE-DEFINITION`/`DELAY-DEFINITION` (43+18+14).
- **zilf's own test framework, likely low-priority or skippable
  entirely** for the "real games" goal: `TEST-CASE`/`TEST-GO`/
  `TEST-SETUP` (192+31+28) — these support the compiler's *own* unit
  tests, not gameplay; worth confirming this reading before investing
  effort here, but they're a strong candidate to just skip.
- **A cheap, high-leverage phase-1/2 candidate for next time:
  `INSERT-FILE` (73 occurrences)** — real zilf implements it as an
  ordinary evaluated-args **SUBR** (`Subrs.Meta.cs`, aliased to `FLOAD`/
  `XFLOAD`), *not* a reader/parser-level construct: evaluating it finds
  the named file (`Context.FindIncludeFile` — tries the name as-is, with
  a `.zil`/`.mud` extension appended, and a lowercased variant, across
  configured include paths) and recursively runs the *same* read-eval
  loop (`Program.Evaluate`) on it in the current context, then returns
  once exhausted. Investigated but not yet built this session — it
  can't be a small `ApplySubr` addition, since `ApplySubr` is
  deliberately kept free of any dependency on `Eval` (that's what lets it
  be declared before `EvalImpl` without a forward-reference conflict);
  `INSERT-FILE` fundamentally needs to call `EvalImpl` on each form it
  reads from the new file, so it has to be inlined into `EvalImpl` itself,
  the same way `PROG`/`REPEAT`/`BIND` and function/macro application are.
  It would also need `ZilEval.mod` to `IMPORT ZilRead` (checked: no
  circular-import risk — `ZilRead.mod` doesn't import `ZilEval`), and the
  `Reader` type would need to track its own file's directory so a
  relative `INSERT-FILE` reference can resolve against it (this port has
  no `IncludePaths`/library-search-directory config at all yet — a
  reasonable first cut would just resolve relative to the *including*
  file's own directory, deferring a real search-path list until
  something actually needs one). Once built, this would very likely
  reduce many of the "library macro" errors above for free, since files
  like `DEFAULT-LIBRARY-MESSAGES`'s definition live in a *different*
  zillib file that a real game's own top-level source pulls in via
  exactly this mechanism — the 84-file-independently test run this
  session never followed that chain.
- **Genuine remaining phase-2 (interpreter) gaps, smaller than expected**:
  `EVAL` (37 — the *SUBR* form, `<EVAL expr [environment]>`, distinct from
  this port's internal `EvalImpl` — not yet exposed as a callable
  builtin), `USE`/`PACKAGE`/`ENDPACKAGE` (14+4+4 — the package/OBLIST
  system phase 1 flattened away), `IF-DEBUG` (11), `MAPF` (3 — mapping
  with early-exit control values, `Outcome.MapRet`/`MapLeave`/`MapStop`,
  none of which this port's `ZResult` implements yet), `DEFSTRUCT` (7),
  `HINT`/`ADD-TELL-TOKENS`/`STATUS-LINE-SECTION`/`SCORING-ACHIEVEMENTS`/
  `COMPILATION-FLAG-DEFAULT`/`REPLACE-LIBRARY-MESSAGES` (single digits
  each — likely all themselves `DEFMAC`s living in not-yet-`INSERT-FILE`d
  library files, so investigate after `INSERT-FILE` exists, not before).

**Tested**: re-ran all five existing phase test harnesses (no regressions)
plus the full transpiler `Modules/*.mod`+`examples/*.mod` regression suite
(135 files, same pre-existing-only failures as always).

## What's done (phase 2f: INSERT-FILE, and CONS)

Built `INSERT-FILE` exactly as scoped in phase 2e: an evaluated-args SUBR
case inlined directly into `EvalImpl` (right before the generic
`ApplySubr` fallback for plain SUBRs), since — same forward-reference
reason as everything else that needs `Eval` in this port — it has to
recursively run the read-eval loop (open a new `ZilRead.Reader`, `ReadOne`
+ `EvalImpl` each form, `ZilRead.Close`) on another file, which
`ApplySubr` deliberately can't do. `ZilEval.mod` now imports `ZilRead`
(checked beforehand: no circular-import risk, confirmed again while
building this).

- **New module-level state**: `currentDir` (the directory `INSERT-FILE`
  resolves a relative filename against) and an exported `SetCurrentDir`
  for a driver to call once before its first `ReadOne`/`Eval`, mirroring
  the original's `Context.CurrentFile` in spirit but with no configurable
  `IncludePaths` list — just "the currently-including file's own
  directory" — since nothing has needed a real search-path list yet.
  `INSERT-FILE` itself save/restores `currentDir` around each nested file
  (via the same save-then-restore-on-a-single-slot pattern used
  throughout this port), so nested `INSERT-FILE`s correctly resolve
  relative to whichever file is *currently* being read, not always the
  original top-level file.
- **Path resolution**: tries the given name as-is, then with `.zil`/`.mud`
  appended, then all three again lowercased. The lowercase fallback
  turned out to matter immediately, not hypothetically: real source
  (`sample/zork1/zork1.zil`) writes `<INSERT-FILE "GMACROS" T>` for the
  real file `gmacros.zil` — matching the original's own
  `GetIncludeFileNameVariants`, which does this exact fallback for this
  exact reason.
- **Verified against real multi-file source**: ran the new `evalfile.mod`
  harness (now calling `ZilEval.SetCurrentDir` first, derived from the
  input path) against `sample/zork1/zork1.zil` itself. All nine of its
  `INSERT-FILE`s (`GMACROS`, `GSYNTAX`, `1DUNGEON`, `GGLOBALS`, `GCLOCK`,
  `GMAIN`, `GPARSER`, `GVERBS`, `1ACTIONS`) correctly opened their
  real (lowercase) files, evaluated forms in sequence *within* each
  (accumulating into the same global environment as the includer),
  and correctly propagated that included file's first real error
  (invariably `ROUTINE`/`OBJECT`/`SYNTAX`/etc. — phase-3 concepts, exactly
  as expected) back up as `INSERT-FILE`'s own result, after which the
  outer driver moved on to the next top-level form. Mechanically, this is
  exactly right — `INSERT-FILE` is not a leftover gap anymore.

**Then re-ran the full 84-file corpus aggregate** (same command as phase
2e) now that `INSERT-FILE` can actually follow real include chains. As
predicted, the shape changed: `ROUTINE`/`OBJECT`/`SYNTAX`/`ROOM` counts
all rose (more of each file's *actual* content is now reachable through
its own includes, rather than each of the 84 files being tested in total
isolation) — and one large *new* entry appeared: **`CONS` (192
occurrences)**, a basic "prepend an element onto a list" primitive that
real top-level/library code calls directly far more than expected.
Verified its exact signature against `Subrs.Types.cs` (`<CONS first
rest>`, where `rest` is a LIST or `FALSE`/`<>` for "build a 1-element
list") and added it — a small, safe, obviously-correct primitive
directly expressible via the existing `ZilObj.Cons` helper, not requiring
any new machinery. The remaining new/grown entries in the histogram
(`MOVE`, `REMOVE`, `MAKE-NOUN-PHRASE`, `IFFLAG`, `IF-DEBUGGING-VERBS`) are
**not** being chased further this session — `MOVE`/`REMOVE` in particular
are Z-machine object-tree runtime operations that only make sense once a
compiled game's object tree exists (`ZModel`/phase 3), not
interpret-time-safe primitives like `CONS`, so implementing them now
would mean faking behavior with no real object tree behind it rather than
porting anything genuine.

**Tested**: re-ran all five existing phase test harnesses (byte-for-byte
identical output before/after the `CONS` addition, confirmed via `diff`)
plus the full transpiler regression suite (135 files, same
pre-existing-only failures as always) after both the `INSERT-FILE` and
`CONS` changes.

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

1. Re-run all five existing test harnesses to confirm nothing regressed:
   phase 1's `sample1.zil` (`readtest.mod`), phase 2's `sample2.zil`
   (`evaltest.mod`), phase 2b's `sample3.zil` (`eval3test.mod`), phase 2c's
   `sample4.zil` (`eval4test.mod`), and phase 2d's `sample5.zil`
   (`eval5test.mod`). Also re-run `readfile.mod` over every file in
   `zillib/` and `sample/` (zero failures out of 84) and `evalfile.mod`
   against `sample/zork1/zork1.zil` (now that `INSERT-FILE` works — should
   still walk into and evaluate forms from all nine of its included files,
   see phase 2f). (All live under the session's scratchpad, which may not
   survive between machine sessions — if gone, they're small and quick to
   recreate from this doc's descriptions of what they cover.) Also re-run
   the transpiler's own full `Modules/*.mod`+`examples/*.mod` regression
   suite if any transpiler work happened in between sessions.
2. Phase 2f's own re-run of the full-corpus aggregate (its own section
   above has the updated histogram and the exact command) is now the
   most current signal for "what does real source need next" — read it
   before picking a next step. `ROUTINE`/`OBJECT`/`SYNTAX`/`ROOM`/table-
   family forms dominate overwhelmingly and are squarely phase 3's job;
   nothing else in the current histogram looked like another clean,
   high-value, phase-2-appropriate primitive the way `INSERT-FILE` and
   `CONS` did. This is a reasonable signal that **phase 2's interpreter
   core is essentially sufficient for what real library/game source needs
   at the definition/top-level-form level**, and that continuing to add
   one-off builtins from the long tail of the histogram (`MOVE`, `REMOVE`,
   `MAKE-NOUN-PHRASE`, etc. — several of which are Z-machine runtime
   object-tree operations that don't make sense without a real object
   tree, i.e. without phase 3) has hit diminishing returns.
3. Given #2, **phase 3 (Compiler/ZModel/Emit.Zap) is now the most
   valuable next slice**, not further phase-2 additions. Before writing
   any code: read `Zilf/Compiler`'s top-level driver file(s) first (not
   done yet in any session so far) to understand the real compile
   pipeline shape, then `Zilf.Emit` root + `Zilf.Emit/Zap` together (see
   the dedicated phase-3 section below, already written from a
   directory/size survey — treat it as a starting pointer, not a
   substitute for actually reading those files). This is a substantially
   bigger, multi-session undertaking than any phase-2 slice so far
   (`Compiler`+`ZModel` alone is ~20,500 lines, more than the entire
   `Interpreter` this port has been building against) — do the reading
   pass fully before committing to an implementation approach, the same
   discipline that made each phase-2 slice go smoothly.
4. If phase 3 feels too large to start cold, the smaller fallback is
   still on the table: pick from the "what's still needed" list above —
   item 4 (fixing phase 1's `%`/`#TYPE` stubs, now that `Eval`/quasiquote
   both exist) is the most likely of the remaining phase-2 items to
   matter soon; the rest are genuinely on-demand and should stay
   deprioritized given #2's finding above.
5. Update this doc's "what's done" section and commit again.
