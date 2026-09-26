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

## Phase 3 reading pass #1 (architecture) — findings

First real reading pass into `Zilf/Compiler`, `Zilf.Emit`, and `Zilf/ZModel`
(previously only surveyed by directory/size). Covers the *architecture* —
enough to plan concrete next slices — not every file; see "still not read"
at the end for what's deliberately deferred.

### The pipeline is two clearly separate phases (confirmed from `FrontEnd.cs`)

1. **`EvaluateInput`**: reads and evaluates the *entire* source file(s) via
   `Program.Evaluate` — i.e. exactly phases 1+2 this port already has.
   `ROUTINE`/`OBJECT`/`GLOBAL`/`CONSTANT`/`TABLE`/`SYNTAX`/etc. are FSUBRs
   that, when evaluated, do **not** compile anything — they just build a
   `ZilRoutine`/`ZilModelObject`/`ZilGlobal`/etc. value (already confirmed
   for `ZilRoutine` in phase 2c) and append it to a list on
   `ctx.ZEnvironment` (`ZEnvironment.cs`, 865 lines — `Routines`,
   `Objects`, `Globals`, `Constants`, `Tables`, `Syntaxes`, `Vocabulary`,
   `Synonyms`, `Directions`, `Buzzwords`, `TellPatterns`,
   `PropertyDefaults` — all plain `List<T>`/`Dictionary<K,V>`). This is
   the **exact same shape** as this port's `DEFINE`/`DEFMAC` registering a
   `KFunction`/`KMacro` as an atom's `globalVal` — so phase 3's
   "registration" side (adding `ROUTINE`/`OBJECT`/`GLOBAL` as new FSUBR
   cases) is an incremental extension of exactly what phase 2 already
   does, not a new architecture.
2. **`EmitCompilation`** (only if no errors from step 1): a *separate*
   pass, `Compilation.Compile(ctx, gameBuilder)`
   (`Compilation.Compile.cs`), that walks everything accumulated on
   `ZEnvironment` and emits code for it.

This means **phase 3 splits cleanly into two independently-testable
halves**, the same way phase 2 built up incrementally: (3a) teach the
evaluator to *register* `ROUTINE`/`OBJECT`/`GLOBAL`/`TABLE`/`SYNTAX`/etc.
as data (cheap — see below), and only later (3b) actually walk that data
and emit `.zap` text for it. 3a alone is independently useful: it would
let real game source's *own* top-level forms stop erroring out during
`evalfile.mod`-style testing, without yet producing any compiled output.

### The `Zilf.Emit` abstraction (`IGameBuilder`/`IRoutineBuilder`/Peephole) is skippable — confirmed, not just guessed

Read `IRoutineBuilder.cs` (679 lines — the interface every instruction
"emit" call goes through) and cross-checked against `Zilf.Emit.Zap`'s own
`RoutineBuilder.cs` implementation. Confirmed: `EmitBinary`/`EmitUnary`/
`EmitTernary`/etc. are **thin wrappers that map an enum value
(`BinaryOp.Add`, `BinaryOp.MoveObject`, ...) directly to a Z-machine
opcode mnemonic string** (`"ADD"`, `"MOVE"`, `"FSET"`, `"GETP"`, ...) —
exactly the mnemonics `ZapfOpcodes.mod` already has in its ~110-entry
table — then builds a structured `Instruction` object, buffered in a
`PeepholeBuffer` for a peephole optimizer (`Peephole.cs`, 1446 lines) that
runs at `Finish()` time to produce the final `.zap` text.

**This port doesn't need any of that layer.** Since we already have a
working `zapf` assembler that reads `.zap` *text*, the Oberon phase-3
code generator can skip the abstract interface, the `Instruction`/
`ZapCode` object model, and the entire peephole optimizer, and just
**emit `.zap` text lines directly** as each ZIL form is compiled — a
`BinaryOp`-style case dispatch (`<MOVE .X .Y>` → emit the text line
`MOVE ...,...`) with zero indirection. The peephole optimizer only
affects output size/speed, never correctness, so skipping it is a pure
pragmatic-subset win with no functional cost (zapf will happily assemble
slightly less-optimal but correct code). This confirms what this doc
already speculated before reading anything — worth having verified before
committing to it.

### The VALUE/VOID/PRED/VALUE-PRED calling convention — the central codegen concept to replicate

Confirmed via `Compilation.Expressions.cs`/`Compilation.Conditions.cs`'s
dispatch into `Builtins/ZBuiltins.cs`: every builtin call compiles one of
**four ways**, matching the Z-machine's own instruction shapes exactly:
- **VoidCall** — no result needed, not used as a branch condition (e.g.
  `<MOVE .X .Y>` as a bare statement).
- **ValueCall** — produces a value to store, not a branch (e.g. `<+ .A
  .B>`).
- **PredCall** — used only as a branch condition inside `COND`/`AND`/`OR`
  (e.g. `<FSET? .X .F>` in a `COND` clause test) — no value stored.
- **ValuePredCall** — produces a value *and* branches in one instruction
  (several real Z-machine opcodes do both at once, e.g. object-tree
  walks). When a builtin's *natural* shape doesn't match the context it's
  used in (e.g. a value-only builtin used as a condition), the compiler
  bridges the gap with small adapter logic (compute the value, then branch
  on nonzero, etc.) — this is the one place with real, non-mechanical
  logic worth reading `Compilation.Expressions.cs` lines ~40-140 for
  directly when the time comes, rather than re-deriving it from scratch.
`Builtins/ZBuiltins.cs` (3,516 lines, 237 `[Builtin(...)]`-attributed
registrations — some builtins have multiple attributes for name aliases
or per-platform variants) is organized as one method per builtin, each
tagged with which of the four shapes it supports and its target platform
(`ZMachine`/`Glulx`/`Cornerstone` — filtering to `ZMachine`-only cuts the
237 down meaningfully, though not yet counted exactly). This is the
single largest remaining piece, but — like `ApplySubr` and zapf's own
opcode table before it — it's a long, *mechanical*, one-at-a-time list,
not a hard design problem once the VALUE/VOID/PRED/VALUE-PRED shape is
understood.

### `ZModel` value shapes surveyed (quick, targeted reads — not the full 7,367 lines)

- **`ZilModelObject`** (`OBJECT`/`ROOM`, 83 lines): trivially simple — a
  name atom, an `isRoom` flag, and a **raw, unprocessed array of property
  lists** (`(DESC "...")`, `(FLAGS LIGHTBIT)`, `(IN ROOMS)`, etc.). All
  the real interpretation (which property is a flag list vs. a normal
  property vs. special ones like `IN`/`LOC`) happens later, during
  compilation (`Compilation.Objects.cs`), *not* at registration time. This
  means registering an `OBJECT` (phase 3a) is exactly as cheap as it
  looked from `ZilRoutine` — capture the name/flag/raw-property-list-array
  as-is (this port's existing cons-chain `KList` representation needs no
  new parsing at all for this).
- **`ZilGlobal`** (`GLOBAL`, 66 lines): name + already-evaluated default
  value + a storage-type hint (`GlobalStorageType`, not yet read). Same
  shape this port's existing `SET`/`SETG`/`GLOBAL`/`CONSTANT` merge
  already produces — the only gap is that this port doesn't yet *also*
  append to a `ZEnvironment.Globals`-equivalent list the way the original
  does (needed so the compiler can later allocate a real Z-machine global
  variable slot and emit its default value into the header) — a small,
  incremental addition to the existing `GLOBAL`/`CONSTANT` SUBR case, not
  a rewrite.
- **`ZEnvironment.cs`** (865 lines): the central registry — see the
  pipeline section above for its field list. This is the direct model for
  whatever Oberon module ends up holding phase 3's equivalent global
  state (most likely a new module, `ZilModel.mod` or similar, alongside
  `ZilObj`/`ZilRead`/`ZilEval`).
- **Not yet read in any depth**: `ZilTable` (790 lines — `TABLE`/`ITABLE`/
  `LTABLE`/`PTABLE`), `ComplexPropDef` (1,021 lines — custom `PROPDEF`
  patterns; the *default* directional-exit PROPDEF is already known from
  `Context.InitPropDefs`, read back in phase 2b, so a pragmatic first cut
  can likely hard-code that default and skip general custom-PROPDEF
  support), `Syntax.cs`/`SyntaxMatcher.cs`/the `Vocab/` subtree (vocabulary
  and grammar-table encoding — a large, self-contained subsystem, probably
  its own reading-and-porting pass later, low priority until routines/
  objects/globals/tables work since a game with no verbs (`SYNTAX`) can't
  do much but *does* still exercise the object/routine/table machinery).

### What's still not read at all

- `Compilation.Objects.cs` (762 lines — the actual property/flag/object
  *table binary layout* algorithm — numbering, packing order, inheritance
  of properties from a `PROPSPEC`/`DEFAULT` object). Needed before 3b can
  emit real object tables.
- `Compilation.Globals.cs` (463), `Compilation.Tables.cs` (142),
  `Compilation.Operands.cs` (342), `Compilation.Strings.cs` (249 — Z-char
  string encoding; likely closely mirrors `ZapfZChar.mod`, already built).
- `Compilation.Routines.cs` (480), `Compilation.Loops.cs` (896),
  `Compilation.Inlining.cs` (1,193 — **the current plan is to skip
  inlining and reachability/dead-routine analysis entirely for the
  pragmatic subset**: compile every registered routine unconditionally,
  matching this port's existing philosophy of correctness-first,
  optimization-never, and cutting ~1,200 lines of C# to port down to zero).
- `Zilf.Emit/Zap`'s `GameBuilder.cs`/`ObjectBuilder.cs`/etc. beyond
  `RoutineBuilder.cs`'s `EmitBinary`/`EmitTernary` (skimmed for the
  mnemonic-mapping pattern only) — given the decision to bypass the whole
  interface and emit text directly, these may not need reading at all,
  only spot-checked if a specific instruction's exact `.zap` textual
  syntax is unclear (and even then, `Modules/ZapfAsm.mod`'s own opcode
  table/encoder, already built and tested, is the more directly useful
  reference than the C# source).

## What's done (phase 3a: ROUTINE/OBJECT/ROOM registration) — files, and what's tested

Implemented exactly the slice scoped at the end of the reading pass above.
Added a new module, **`Modules/ZilModel.mod`** — the Oberon equivalent of
`ZEnvironment`: plain fixed-size arrays (`routines`/`objects`/`globals`/
`constants`, each with an `n*` count and an `Add*` procedure) holding
whatever `ROUTINE`/`OBJECT`/`ROOM`/`GLOBAL`/`CONSTANT` registrations have
been seen so far. Pure data capture, no compilation — matches
`ZilModelObject`/`ZilGlobal`'s own confirmed-cheap shape from the reading
pass exactly, with **zero new parsing needed**: an `OBJECT`'s property
lists are stored as the raw cons-chain the reader already produced.

Added to **`ZilEval.mod`**: `ApplyRoutine` and `ApplyObject` (standalone
procedures alongside `ApplyDefine`, for the same reason — they don't call
`Eval`, only capture raw unevaluated arguments, so they aren't subject to
the forward-reference restriction), dispatched as new FSUBR cases
(`ROUTINE`, `OBJECT`, `ROOM`) in `EvalImpl`. Also upgraded the existing
`GLOBAL`/`CONSTANT` SUBR case to *additionally* call
`ZilModel.AddGlobal`/`AddConstant` after doing what it already did
(setting `globalVal`) — this doesn't change that SUBR's own observable
behavior at all, it just also records the registration for a future
compilation pass. `ZilEval.mod` now imports `ZilModel` (no circular-import
concern — `ZilModel.mod` only imports `ZilObj`).

**Tested exactly like `INSERT-FILE` was** (phase 2f): re-ran `evalfile.mod`
against `sample/zork1/zork1.zil`. Confirmed real, direct improvement —
`INSERT-FILE "GMACROS"`, `"GGLOBALS"`, and `"GMAIN"` now each process
their **entire** file successfully (returning `"DONE"` — every top-level
form in each of those three files evaluates without error now), and the
other six `INSERT-FILE`s advance further into their files before hitting
a genuinely different, not-yet-registered construct (`SYNTAX`, `LTABLE`,
`ITABLE`, `PROPDEF`) instead of stopping at `ROUTINE`/`OBJECT` immediately.

**Then re-ran the full 84-file corpus aggregate** (same command as phases
2e/2f) to confirm at scale, not just on one file. Result: **`ROUTINE`
(was 1624 occurrences), `OBJECT` (was 481), and `ROOM` (was 229) are now
completely absent from the histogram** — every single occurrence across
all 84 real files now registers successfully. The histogram's new shape
is dominated by `SYNTAX` (451, unchanged — its own subsystem, not touched
this slice), `EVAL` (269, up from 46 — now that more code past the
`ROUTINE`/`OBJECT` gate is reachable, more real `<EVAL ...>` calls are
exposed; still not implemented — needs to be inlined into `EvalImpl` like
`INSERT-FILE`, since `ApplySubr` can't call `Eval`, so this is a natural
next small slice), and the `ITABLE`/`TABLE`/`LTABLE`/`PTABLE` table family
(111+32+28+8 = 179, up from before for the same reachability reason).
`MOVE`/`REMOVE`/`FCLEAR` (17+5+3) remain deliberately unimplemented, same
reasoning as phase 2f: real Z-machine object-tree runtime operations that
don't make sense without an actual object tree existing (phase 3b).

**Tested**: re-ran all five existing phase-2 test harnesses (byte-for-byte
identical output, confirmed via `diff`) plus the full transpiler
regression suite (136 files now, counting the new `ZilModel.mod` itself —
same 3 pre-existing-only failures as always) — no regressions.

## What's done (phase 3a continued: EVAL, and the TABLE family) — files, and what's tested

Both candidates scoped at the end of phase 3a's own section above, done
in one slice.

**`EVAL`**: added as an inlined `EvalImpl` case (same forward-reference
reason as `INSERT-FILE` — it needs to call `EvalImpl` again on its
argument, so it can't be a plain `ApplySubr` case). Implements the common
real-source shape only: `<EVAL expr>` with no explicit environment
argument — verified this is overwhelmingly the real usage pattern before
committing to skip environments; a second (environment) argument, if
given, is accepted but ignored, since this port has no first-class
environment objects (flattened away back in phase 2). `EVAL-IN-SEGMENT`
is registered as an alias (same original-source pattern as
`INSERT-FILE`/`FLOAD`/`XFLOAD` sharing one implementation).

**The TABLE family** (`TABLE`, `LTABLE`, `PTABLE`, `PLTABLE`, `ITABLE`):
read `Subrs.ZModel.cs`'s actual implementations first (not `ZilTable.cs`
itself, which turned out to be just the abstract value type with the real
construction logic living in the SUBRs) and found a genuinely different
shape than `ROUTINE`/`OBJECT`: these are **plain evaluated-args SUBRs**
that construct a real table *value* immediately (closer to how `FORM`/
`LIST` already work in this port than to `ROUTINE`'s "capture raw syntax
for later" pattern) — so no forward-reference issue, and `PerformTable`/
`PerformITable` are ordinary standalone procedures.

- **`ZilObj.mod`**: new `KTable` kind. Deliberately **reuses the existing
  `vecItems`/`vecLen` fields** from `VECTOR` rather than adding a separate
  pair — same flat-array shape, no reason to duplicate it — plus two new
  fields, `tabRepCount` (`ITABLE`'s repetition count; always 1 for the
  plain `[P][L]TABLE` forms) and `tabFlags` (a bitmask of new `TfByte`/
  `TfLength`/`TfPure`/`TfLexv`/`TfTemp` constants). This representation is
  intentionally much thinner than the original's `ZilTable` — no byte-level
  encoding yet, since that's phase 3b's job once a real compilation pass
  exists to walk what's registered here.
- **`ZilEval.mod`**: `TableFlagBits` (scans a flag LIST like `(BYTE
  LENGTH)` into the bitmask — recognizes `BYTE`/`LENGTH`/`PURE`/
  `PARSER-TABLE`-as-`PURE`/`LEXV`/`TEMP-TABLE`; deliberately not yet
  `PATTERN`/`SEGMENT`/`STRING`/`KERNEL`/`WORD` — pragmatic subset, add on
  demand), `PerformTable` (the `[P][L]TABLE` shape: optional leading flag
  list, then values as-is, `repCount` always 1), and `PerformITable` (the
  `ITABLE` shape: optional `BYTE`/`WORD`/`NONE` specifier atom — only
  `BYTE` is distinguished, a coarser approximation than the original's
  separate element-type-vs-length-prefix-type distinction — then a
  required count, optional flag list, then an initializer that gets
  **pre-expanded** `count` times into the table's element array). `ITABLE`
  needed its own much larger buffer (`MaxTableElems = 8192`) independent of
  the shared `MaxArgs = 64` used for ordinary call arguments, since e.g.
  `<ITABLE 100 0>` has only 2 call-site arguments but 100 *expanded*
  elements. Both register the constructed table into the new
  `ZilModel.tables` list **unless** the `TEMP-TABLE` flag was given —
  matching the original's own exclusion exactly (temp tables are
  compiler-internal scratch space, never part of final output).
- **`ZilModel.mod`**: added `tables`/`nTables`/`AddTable`, matching
  `ZEnvironment.Tables`'s own shape (just a flat list of table values, not
  a separate wrapper record — the `ZilObj.Zo` *is* the registered value,
  same as the original's `List<ZilTable>`).

**Tested**: `sample6.zil` — `EVAL` re-evaluating a constructed `<FORM + .X
.X>` (`=> 42` for `X=21`); plain/`L`/`P`-prefixed tables with and without
a flag list; `ITABLE` both with a single zero-fill initializer and a
multi-value repeating one (`<ITABLE 2 (BYTE) 1 2> => (1 2 1 2)`); and a
table constructed inline as a `CONSTANT`'s value (a common real pattern,
confirming both registrations compose correctly). All 8 forms produced
exactly the expected result. Re-ran all five existing phase-2 test
harnesses (byte-identical output) plus the full transpiler regression
suite (136 files, same 3 pre-existing-only failures) — no regressions.

**Then re-ran the full 84-file corpus aggregate** once more: **`EVAL` (was
269 occurrences) and the entire table family (`ITABLE`/`TABLE`/`LTABLE`/
`PTABLE`, was 179 combined) are now completely absent from the
histogram** — zero occurrences of any of them remain anywhere in the real
corpus. Also directly observed on `sample/zork1/zork1.zil`: 5 of its 9
`INSERT-FILE`d files now process end-to-end with no errors at all
(`GMACROS`, `GGLOBALS`, `GCLOCK`, `GMAIN`, `GPARSER` — up from 3 after
phase 3a alone). `SYNTAX` (451, completely unchanged by this slice — its
own subsystem, per the plan) is now unambiguously the single largest
remaining item in the histogram, with vocabulary-adjacent forms
(`SYNONYM`/`VOC`/`VERB-SYNONYM`/`DEFAULT-DEFINITION`/etc.) and `PROPDEF`
next after it.

## What's done (phase 3a continued: SYNTAX/vocabulary registration) — files, and what's tested

Read `Syntax.cs` (421 lines) as scoped. Found `SYNTAX`'s *real* semantic
shape is genuinely involved (~400 lines: verb, up to two `OBJECT`/`TOPIC`
clauses each with an optional preposition/`FIND`-flag/scope-bits, an
action/preaction/action-name, and verb synonyms) — but also confirmed (via
`Subrs.ZModel.cs`) that `SYNTAX` itself, like `TABLE`, is a **plain
evaluated-args SUBR**, not an FSUBR — so the same "register the raw,
already-evaluated arguments now, defer real semantic decomposition to
phase 3b" pattern already used for `OBJECT`'s raw property lists applies
directly, without needing to port `Syntax.Parse`'s full logic yet. This
turned out to be the right call: `SYNTAX` (like `TABLE`) didn't need its
own new architecture, just the same registration pattern applied once
more. Also read the `SYNONYM`-family SUBRs (`SYNONYM`/`VERB-SYNONYM`/
`PREP-SYNONYM`/`ADJ-SYNONYM`/`DIR-SYNONYM`, all sharing one
`PerformSynonym` shape: an original atom and one or more atoms that are
synonyms of it) and `VOC`/`DIRECTIONS`/`BUZZ` (also plain SUBRs, simple
list-registration or intern-and-return shapes) — did **not** need to read
`SyntaxMatcher.cs` or the `ZModel/Vocab/` subtree at all for this slice,
since real dictionary/vocab-table *encoding* is squarely phase 3b's job.

- **`ZilModel.mod`**: `SyntaxRec` (just `rawArgs`, the raw argument
  chain), `SynonymRec` (`kind` — `SynPlain`/`SynVerb`/`SynPrep`/`SynAdj`/
  `SynDir` — plus the original and synonym atoms), and flat
  `directions`/`buzzwords` lists, each with an `Add*` procedure.
- **`ZilEval.mod`**: `SYNTAX`, `SYNONYM`-family, `DIRECTIONS`, `BUZZ`, and
  `VOC` all added directly to `ApplySubr` (no forward-reference issue —
  none of them call `Eval`). `VOC` is a deliberate simplification: the
  original `CHTYPE`s the result to a `VOC` pseudo-type and registers it
  by part-of-speech for later dictionary encoding; this just interns and
  returns the plain atom, since this port has no pseudo-type system yet
  and `VOC`'s dominant real use is as a self-evaluating-atom-producing
  building block inside other expressions, which this preserves.

**Tested**: `sample7.zil` — two `SYNTAX` definitions (one- and two-object),
all five `SYNONYM`-family variants, `DIRECTIONS`, `BUZZ`, and `VOC` — all
10 forms produced exactly the expected result (each returns its own verb/
original atom, or `T`, or the interned word atom). Re-ran all five
existing phase-2 test harnesses (byte-identical output) plus the full
transpiler regression suite (136 files, same 3 pre-existing-only
failures) — no regressions.

**Then re-ran the full 84-file corpus aggregate**: **`SYNTAX` (was 451
occurrences — the single largest item in the entire histogram), plus
`SYNONYM`/`VOC`/`VERB-SYNONYM` (92+82+38), are now completely absent.**
On `sample/zork1/zork1.zil` specifically, **7 of its 9 `INSERT-FILE`d
files now process end-to-end with zero errors** — `GSYNTAX` and
`1DUNGEON` newly joined `GMACROS`/`GGLOBALS`/`GCLOCK`/`GMAIN`/`GPARSER`;
only `GVERBS` and `1ACTIONS` remain, both now blocked on `GDECL` (a small,
6-occurrence item — likely simple). The aggregate histogram overall
shrank dramatically and is now much flatter, with no single dominant
item — remaining significant entries are `DEFAULT-LIBRARY-MESSAGES`/
`ADD-TELL-TOKENS`/`DEFAULT-DEFINITION`/`REPLACE-DEFINITION`/
`DELAY-DEFINITION` (70+44+43+19+14 = 190, a "hooks/customization"
subsystem — `<DEFAULT-DEFINITION name body...>` conditionally evaluates
`body` based on `PUTPROP`/`GETPROP` state, genuinely implementable with
machinery this port already has, but an FSUBR needing to call `Eval` —
same shape as `INSERT-FILE`), `VERSION`/`VERSION?` (40+25 — compiler
directives, phase 3b), `PROPDEF` (33, phase 3b), and a long tail of
single-digit items.

## What's done (phase 3a continued: the DEFAULT/REPLACE/DELAY-DEFINITION "hooks" system) — files, and what's tested

Read `Subrs.Meta.cs`'s `DELAY_DEFINITION`/`REPLACE_DEFINITION`/
`DEFAULT_DEFINITION` in full. This is a small state machine, entirely
implementable with machinery this port already has: state lives in a
`PUTPROP`/`GETPROP` property (indicator atom `"REPLACE-DEFINITION"` —
the *same* atom is also reused as one of the possible *state values*
itself, a self-referential terminal marker for "already inserted",
exactly matching the original's own reuse of `StdAtom.REPLACE_DEFINITION`
in both roles) on the definition-section's own name atom:

- **`DELAY-DEFINITION name`**: a plain evaluated-args SUBR (added directly
  to `ApplySubr`) — errors if already referenced, else marks the section
  `"DELAY-DEFINITION"`.
- **`REPLACE-DEFINITION name body...`** and **`DEFAULT-DEFINITION name
  body...`**: FSUBRs (body unevaluated), inlined into `EvalImpl` (same
  forward-reference reason as `INSERT-FILE` — the body actually inserted
  needs `EvalImpl`). A pending replacement (one arriving *before* its
  matching `DEFAULT-DEFINITION`) is stashed as a VECTOR via a new
  `ChainToVector` helper (doesn't call `Eval`, so it's a standalone
  procedure, like `BuildConsChain`) — matching the original's own choice
  of `ZilVector` for exactly this state. The full 4-state transition table
  (unset → insert now; delayed → a later `REPLACE-DEFINITION` inserts
  immediately; a stored pending vector → the matching
  `DEFAULT-DEFINITION` runs *that* instead of its own body; already
  inserted → error) is implemented directly, verified against the
  original's own branches line-by-line rather than approximated.

**Tested**: `sample8.zil` — all four real interleavings: a plain
`DEFAULT-DEFINITION` with no prior state (inserts immediately); `DELAY-
DEFINITION` followed by `REPLACE-DEFINITION` (inserts the replacement
immediately, since delayed); a `REPLACE-DEFINITION` arriving *before* its
matching `DEFAULT-DEFINITION` (correctly runs the stored replacement
instead of the default body when the `DEFAULT-DEFINITION` is later
encountered — the trickiest case, confirmed via the arithmetic result
actually run, not just which branch was taken); and a duplicate
`DEFAULT-DEFINITION` for an already-defaulted section (correctly errors).
All 6 forms produced exactly the expected result. Re-ran all five existing
phase-2 test harnesses (byte-identical output) plus the full transpiler
regression suite (136 files, same 3 pre-existing-only failures) — no
regressions.

**Then re-ran the full 84-file corpus aggregate**: `DEFAULT-DEFINITION`/
`REPLACE-DEFINITION`/`DELAY-DEFINITION` (was 43+19+14 = 76 combined) are
now completely absent from the histogram.

**Investigated `DEFAULT-LIBRARY-MESSAGES`/`ADD-TELL-TOKENS`** (70+44 —
now the two largest remaining items) before attempting to port them, and
found they're a *different* problem than expected: grepped the entire
`src/` tree for any C# implementation and found none at all — they're not
`[Subr]`/`[FSubr]`-attributed builtins like everything ported so far.
Reading `zillib/libmsg.zil`'s own header comment confirmed why: "Library
messages are stored in the GVALs of atoms which are inserted into OBLISTs
created for this purpose" — e.g. the message `SUCCESS` in category `TAKE`
lives in the GVAL of an atom literally named `SUCCESS!-TAKE!-LIBRARY-
MESSAGES`, constructed via the **qualified-OBLIST atom naming** (`FOO!-BAR`)
system that phase 1 deliberately flattened away into one global table
(`ZilObj.Intern`) back at the very start of this port — documented then as
a known, revisit-if-it-matters gap (see phase 1's own "simplifications"
section). This is genuinely a different, larger undertaking than "port one
more builtin" — it needs the real qualified-OBLIST/package hierarchy
(`ObList.cs`, read back in phase 2b, confirmed to be "just a name→atom
hash table per oblist, same shape as the flat one already implemented" —
so the *data structure* change is moderate, but atom *parsing* would need
to recognize and split `!-`-qualified names, which `ZilRead.mod` doesn't
do at all currently) before `DEFAULT-LIBRARY-MESSAGES` itself (whatever
mechanism actually defines it — not found in this session's search, it
may be built dynamically the same way `PRONOUN`'s macros construct routine
names via `PARSE`/`STRING`) can be tackled. Deliberately not started this
session — flagged for its own investigation, separate from the "port the
next SUBR" pattern that's worked well so far.

## What's done (phase 3a continued: PROPDEF) — files, and what's tested

Confirmed via `Subrs.ZModel.cs`'s `PROPDEF` that the common real-source
shape (`<PROPDEF name default-value>`, no complex spec — exactly what
`zork1.zil` itself uses: `<PROPDEF SIZE 5>`, `<PROPDEF CAPACITY 0>`, etc.)
is by far the dominant case, with the complex-pattern form (`<PROPDEF
DIRECTIONS <> (DIR TO R:ROOM = ...)>`, used to define direction-property
syntax) genuinely rare. `PROPDEF` is an FSUBR (name and the complex spec
are raw/unevaluated; only the default value is explicitly `Eval`'d inside
the original's own SUBR body), so — same forward-reference reason as
`INSERT-FILE`/`DEFAULT-DEFINITION`/`PROPDEF` needing `EvalImpl` for the
default value — this is inlined into `EvalImpl`, not a separate procedure.

Replicated the original's one genuine special case exactly (not
approximated): a `<PROPDEF DIRECTIONS <> (DIR ...)>` — `DIRECTIONS` atom,
`FALSE` default, *and* a spec present — registers only the complex
pattern, not a real property default, since `DIRECTIONS` isn't an actual
property in that form; any other combination (including `DIRECTIONS`
with a spec *and* a truthy default) registers both. The complex spec
itself is captured raw (`ZilModel.PropDefSpecRec`) rather than parsed —
real parsing (`ComplexPropDef.Parse`, 1,021 lines) is deferred to phase
3b, same "register now, interpret later" pattern as `OBJECT`/`SYNTAX`.

**Tested**: `sample9.zil` plus a new `modeltest.mod` harness (reads+evals
a file, then prints `ZilModel`'s registered state directly — useful
beyond just this test, for inspecting any future registration) — the
simple case (`SIZE`/`TEXT-HELD`, the latter with a `FALSE` default,
confirming a falsy-but-real default still registers, matching the
original's own documented rationale for that), the `DIRECTIONS` special
case (correctly registers *only* the complex spec, not a property
default), and a complex spec with a truthy default (correctly registers
*both*) — all behaved exactly as expected. Re-ran all five existing
phase-2 test harnesses (byte-identical output) plus the full transpiler
regression suite (136 files, same 3 pre-existing-only failures) — no
regressions.

**Then re-ran the full 84-file corpus aggregate**: `PROPDEF` (was 33
occurrences) is now completely absent. The remaining histogram is
unchanged in shape from phase 3a's hooks-system slice: dominated by the
OBLIST-dependent `DEFAULT-LIBRARY-MESSAGES`/`ADD-TELL-TOKENS` (already
investigated and deferred — see that section above), `VERSION`/`VERSION?`
(compiler directives, phase 3b), `MOVE`/`REMOVE`/`FCLEAR` (Z-machine
runtime object-tree operations, deliberately still unimplemented), and an
increasingly long tail of single-digit items.

## Milestone: phase 3b begins — first real ZIL-to-.zap code generation

Read `Compilation.Routines.cs` in full to understand `BuildRoutine`'s
shape: set up Z-machine locals 1:1 from the argspec (via
`rb.DefineRequiredParameter`/etc.), compile each body statement via
`CompileStmt` (wanting a result *only* for the routine's last statement —
matches this port's own established "the last body form's value is the
result" convention from `PROG`/function application), and for the
result-wanted case, explicitly `rb.Return(result)` — there's no implicit
fall-through return anywhere in the original, every routine explicitly
returns or (for the entry point) quits.

Confirmed the exact `.zap` textual syntax needed by reading a **real
zilf-compiled `.zap` file already present on this machine**
(`~/cloak_plus.zap`, 4,427 lines) rather than guessing: `.FUNCT
NAME,local1[=default],local2,...` declares a routine and its locals;
plain instruction lines are `MNEMONIC operand1,operand2,... >storeTarget
/branchLabel` (or `\branchLabel` for inverted polarity); `STACK` is a
literal pseudo-variable name usable as both a store target and an
operand (confirmed via real examples like `MUL N,2 >STACK` immediately
followed by further ops consuming `STACK`); `RETURN operand` and the
0-operand `RTRUE`/`RFALSE` are ordinary instructions, both already in
`ZapfOpcodes.mod`'s table. Found an even more directly reusable artifact:
a **minimal, previously-verified-working `.zap` template** sitting in
this session's own scratchpad from earlier zapf-port testing
(`sample1.zap` — a bare header plus `.FUNCT GO` / `START::` / `QUIT` /
`.END`), used as the base for this milestone's own test file instead of
reconstructing header boilerplate from scratch.

**Added `Modules/ZilCompile.mod`** — deliberately minimal, the same "get
one trivial case working before widening" discipline used to start every
earlier phase. Handles: a required-args-only `ROUTINE`, body expressions
that are FIX literals, `.X`-style `LVAL` references to the routine's own
parameters, and the four arithmetic `BinaryOp`s (`+`/`-`/`*`//`). Compound
sub-expressions always route their result through the Z-machine stack
(`STACK`) rather than allocating temporary locals — correct, not maximally
efficient, but consistent with this port's "correctness first,
optimization never" philosophy (the original's own peephole optimizer,
already decided against porting, is what would tighten this in the real
compiler). `CompileOperand` is self-recursive (same forward-reference
reason as `ZilRead.ReadOne`/`ZilEval.EvalImpl` — Oberon has no `FORWARD`),
returning the `.zap` operand text for whatever it just compiled (a literal
number, a bare local name, or `"STACK"`) so the caller can use it as an
operand to a further instruction.

**Tested end-to-end, exactly the way the plan called for**: compiled
`<ROUTINE ADD1 (X) <+ .X 1>>`, wrapped it with a hand-written minimal `GO`
entry point (`CALL ADD1,41 >STACK` / `PRINTN STACK` / `CRLF` / `QUIT`),
assembled the result with the existing `zapf` (512-byte story file,
assembled cleanly), and ran it through `examples/zmachine.mod`. The
interpreter printed `41+1=42` correctly (verified after stripping ANSI
escape codes) — **the first real ZIL routine compiled by this port,
assembled, and executed, producing the correct result end-to-end.** Also
tested a nested expression, `<+ <* .X 2> 1>` for `X=41` (expected `83`,
matching `41*2+1`) to validate the stack-based sub-expression handling —
also correct.

**A cosmetic artifact worth recording so it isn't re-investigated as a
bug later**: running any minimal-header V3 story through
`examples/zmachine.mod` prints a stray `"7"` prefix before the first
`PRINTN`'d value and a stray `"8"` on the next screen redraw (confirmed:
a literal `PRINTN 42` alone, with no `ROUTINE`/`CALL` involved at all,
produces the exact same `"742"`/`"8"` artifacts). This is pre-existing
status-line/screen-model behavior in `zmachine.mod` when a game has no
real object tree or globals configured for the status line to render
(this milestone's test header is a bare minimal template, not a real
game) — confirmed unrelated to `ZilCompile.mod` by reproducing it with a
hand-written `.zap` file containing no compiled code at all. Not a phase-
3b bug; not investigated further since it's out of scope for this slice.

**Tested**: re-ran all five existing phase-2 test harnesses (byte-
identical output) plus the full transpiler regression suite (137 files —
includes the new `ZilCompile.mod` — same 3 pre-existing-only failures) —
no regressions.

## What's done (phase 3b continued: multi-statement bodies, SET/PRINTI/PRINTN/CRLF)

Widened `ZilCompile.mod` exactly per the plan's own item (a) then most of
(b): `CompileRoutine` now compiles every body statement (not just a
single one), wanting a result only for the last — matching the original's
`BuildRoutine` loop precisely, `wantResult = (i == routine.BodyLength)`.
Introduced the statement-vs-expression split the original itself has
(`CompileForm` vs `CompileAsOperand`): a new `CompileStmt` handles the
statement-shaped builtins `SET`/`PRINTI`/`PRINTN`/`CRLF` directly (none of
these are meaningful as a *nested* expression operand the way arithmetic
is) and falls back to the existing `CompileOperand` for anything else —
so a bare value expression used as a statement (the original trivial test
case) still works unchanged. `CompileStmt` always calls `CompileOperand`,
never the reverse, so — unlike `CompileOperand` — it doesn't need to be
self-recursive or declared before it; it's simply declared after, with no
forward-reference issue, the same one-directional-dependency reasoning
already used elsewhere in this port wherever it applies.

- **`SET`** compiles to `SET 'target,<operand>` (confirmed the leading
  `'` on the *target* from real examples in `~/cloak_plus.zap`, e.g. `SET
  'HERE,FOYER` — a Z-machine `SET` instruction's first operand names the
  variable itself, not its value) and returns the target's own bare name
  as the statement's value if needed — correct regardless of whether the
  assigned value came from a literal or a compound `STACK`-routed
  sub-expression, since by the time `SET` finishes, the *variable* holds
  the value either way.
- **`PRINTI`** required confirming ZAP's actual string-escaping
  convention first, rather than assuming C-style backslash escapes:
  checked `ZapfTok.ReadString` (this port's own zapf tokenizer, already
  built and tested) and confirmed ZAP doubles an embedded `"` (`""`)
  rather than backslash-escaping it — implemented as a new
  `CompileZapString` helper that re-encodes an already-decoded ZIL string
  into that convention.
- **`PRINTN`**/**`CRLF`** are straightforward direct mappings.
- All three void-shaped builtins (`PRINTI`/`PRINTN`/`CRLF`) return the
  literal text `"1"` when used as a routine's final (value-wanted)
  statement — a safe stand-in for `T`, since none of them produce a real
  ZIL value, but the calling convention still needs *something*
  returnable in that position.

**Tested end-to-end** (same discipline as the original `ADD1` milestone —
compile, assemble with `zapf`, run in `examples/zmachine.mod`, check the
actual result, not just that the `.zap` text looks plausible): a routine
that doubles its argument via `<SET X <* .X 2>>`, prints `"Doubled: "` via
`PRINTI`, prints the new value via `PRINTN`, emits a `CRLF`, then returns
`.X` as its last statement. Called with `X=41`, correctly printed
`"Doubled: 82"` and then correctly returned `82` as the routine's own
result (confirmed via the test harness's own `PRINTN` of the `CALL`'s
result) — verifying multi-statement compilation, `SET`'s
read-back-from-the-variable result semantics, string literal encoding,
and the interaction between all of them together, in one real compiled
program. Also confirmed the original trivial `<ROUTINE ADD1 (X) <+ .X
1>>` test still produces byte-identical `.zap` output after this
widening — a true extension, not a rewrite that happened to still work.

**Tested**: re-ran all five existing phase-2 test harnesses (byte-
identical output) plus the full transpiler regression suite (137 files,
same 3 pre-existing-only failures) — no regressions.

## What's done (phase 3b continued: COND as a real branch tree)

Read `Compilation.Conditions.cs` (663 lines) in full, as scoped. This is
where the VALUE/VOID/PRED/VALUE-PRED calling convention from the phase 3
architecture reading pass actually gets exercised — `CompileCondition`
picks predicate builtins first (branch directly), then value builtins
(compile, then branch on nonzero), then value+predicate builtins (a
harder hybrid case), then void builtins (always branch true, since a
void call "succeeds"), with a generic "compile as a value and test
against zero" fallback at the very end. `CompileCOND` walks clauses,
compiling each clause's *condition* via `CompileCondition` (branching past
it, i.e. polarity `false`, when the clause doesn't match) and each
clause's *body* via the ordinary statement compiler, defaulting
`resultStorage` to the Z-machine stack.

Ported a **pragmatic subset** of this rather than the full generality:
`CompileCondition`/`CompileCOND` handle the four comparison predicates
that show up overwhelmingly in real source (`ZERO?`, `EQUAL?`/`=?`/`==?`,
`L?`, `G?` — confirmed the ZAP mnemonics for `L?`/`G?` really do rename to
`LESS?`/`GRTR?`, not keep their ZIL spelling, by checking real usage in
`~/cloak_plus.zap`), `T`/`ELSE`/`FALSE`/FIX-literal conditions, and a
generic "compile as a value, branch on nonzero" fallback for anything
else (a bare `LVAL`, or a builtin with no special predicate handling) —
not the full `PredCall`/`ValueCall`/`ValuePredCall`/`VoidCall` builtin
classification system (`ZBuiltins.cs`'s 237 registrations), and
`EQUAL?` only supports exactly 2 args here (the real one accepts 2-4,
matching the first against any of the rest). `AND`/`OR`/loops
(`Compilation.Loops.cs`) are not touched by this slice.

**`COND` had to be inlined directly into `CompileStmt` itself** (making it
self-recursive), not factored into a separate `CompileCOND` procedure the
way the plan first framed it — a clause's body can contain an arbitrary
statement, including another `COND`, so `CompileStmt` calling a separate
`CompileCOND` that calls back into `CompileStmt` would be exactly the
mutual recursion this transpiler's lack of `FORWARD` declarations can't
express, the same reasoning behind every other self-recursive procedure in
this whole port (`ZilRead.ReadOne`, `ZilEval.EvalImpl`). `CompileCondition`
was kept as its own separate procedure since it only ever calls
`CompileOperand`, never `CompileStmt` — no such issue there.

**`COND`'s result, when wanted, is always left on the Z-machine stack**
(matching the original's own `resultStorage ??= rb.Stack` default): each
matching clause's final value is `PUSH`ed (skipped if it's already sitting
on the stack from its own last instruction, to avoid double-pushing), and
since at most one clause's branch is ever taken, exactly one value is on
the stack by the time control reaches the end label — including the
"no clause matched, no `ELSE`" case, which pushes a bare `0`, matching the
original's `EmitStore(resultStorage, Game.Zero)`.

**Tested end-to-end**, three cases, each compiled → assembled with `zapf`
→ run in `examples/zmachine.mod` → checked against the actual printed
result: a value-producing `COND` with an `ELSE` clause (`<G? .X 100> 111`
/ `<L? .X 10> 222` / `ELSE 333`, correctly returned `333` for `X=41`); the
same shape with the `ELSE` clause *removed* (correctly returned `0`,
confirming the no-match default); and a `COND` used as a **void**
statement purely for its `PRINTI` side effects, followed by a separate
`CRLF` and `.X` return (correctly printed `"medium"` then returned `41`,
confirming `COND` composes correctly with both calling conventions). All
three matched expectations exactly. Also re-ran the two earlier `ZilCompile`
milestone tests (`ADD1`'s trivial arithmetic and the `SET`/`PRINTI`
multi-statement one) and confirmed byte-identical `.zap` output — a true
extension, not a rewrite that happened to still pass.

**Tested**: re-ran all five existing phase-2 test harnesses (byte-
identical output) plus the full transpiler regression suite (137 files,
same 3 pre-existing-only failures) — no regressions.

## Correction: this transpiler DOES support mutual recursion

Every earlier phase of this port worked around a believed lack of forward
declarations by collapsing naturally-mutually-recursive procedures into one
big self-recursive one (`ZilRead.ReadOne`, `ZilEval.EvalImpl`,
`ZilCompile.CompileStmt` with `COND` inlined into it). **That belief is
wrong.** `codegen.c` emits a C prototype for every top-level procedure
before emitting any bodies, so a procedure may call another declared later
in the file, and two top-level procedures may call each other. Verified
directly this session with a two-procedure `IsEven`/`IsOdd` test program,
which compiled and ran correctly.

What is true — and is probably what the original observation came from — is
that the `PROCEDURE Foo(...); FORWARD;` *syntax* does not parse in this
dialect at all. It isn't needed.

Practical effect: new code in this port may be factored the obvious way.
The existing self-recursive procedures are left as they are because they
work and are tested, not because they have to be that shape; don't cite the
"no FORWARD" reason in new comments, and don't collapse a new procedure
into an existing one to avoid a forward reference.

## What's done (phase 3b continued: globals, constants, and whole-program `.zap` emission)

This is the plan's own next item (a), plus the program-level emitter that
globals turned out to require: a `GLOBAL::` table has to be *placed* in the
story file's memory map, which means something has to emit the whole file,
not just one routine at a time.

Read `Compilation.Globals.cs` (463 lines) and the relevant half of
`Zilf.Emit/Zap/GameBuilder.cs` (`Finish`, `FinishSymbols`, `FinishGlobals`,
`FinishSyntax`) in full, plus the `SET`/`SETG`/`INC`/`DEC`/`VALUE` builtin
registrations in `ZBuiltins.cs` and `RoutineBuilder.EmitCall`.

**`Modules/ZilCompile.mod`** gained:

- **`CompileProgram(entryName)`** — emits a complete, assemblable `.zap`.
  The emission ORDER is not cosmetic and was taken from `GameBuilder.Finish`:
  constants (symbols only), then `GLOBAL::`/`OBJECT::`/impure tables, then
  `IMPURE::`, then `VOCAB::`/`WORDS::`, then `ENDLOD::`, then the routines.
  `IMPURE` is the header's static-memory base and `ENDLOD` its high-memory
  base, so globals *must* precede `IMPURE::` or writes to them would be
  writes to read-only memory. The original splits these across four files
  stitched with `.INSERT`; this port emits one stream in the same order.
- **`CompileGlobals`** — one `.GVAR NAME=value` per GLOBAL. `.GVAR` is what
  allocates the Z-machine variable number (zapf hands out 16, 17, … in
  declaration order), so order is semantically significant in V3, where the
  interpreter reads `HERE`/`SCORE`/`MOVES` from variables 16/17/18
  specifically — ported the original's `MoveGlobal("HERE", 0)` etc. from
  `FinishGlobals`, applied (as there) only for V3. `DoFunnyGlobals` — the
  "soft globals" spill table for games with more than ~240 globals — is
  deliberately NOT ported; the overflow is reported as a compile error
  instead.
- **`CompileConstants`** — one `NAME=value` assembly symbol per CONSTANT.
- **`ConstantText`** — the original's `CompileConstant`, cut down to the
  value shapes this slice can render, with its resolution order preserved
  exactly (`T` → 1, then routine names, then object names, then constant
  names, each becoming a bare ZAP symbol). A bare atom naming a *global* is
  deliberately rejected: the original only reads that as the global's
  variable index in "optimistic" mode and warns when it does, and zapf
  rejects a variable symbol in a constant expression anyway.
- **Operands**: `,X` (GVAL), bare atoms, `<>`, and CHARACTER literals.
  `,X` resolves to the bare ZAP name whether X is a global, a constant, an
  object or a routine — zapf resolves a `.GVAR`-declared name to a variable
  reference and anything else to its value, so one spelling covers all four
  (which is exactly what the original's `GvalOp` does).
- **Statements**: `SETG` (identical to `SET` in ZAP text — `SetgValueOp` in
  the original literally just calls `SetValueOp`; the two differ only in
  which namespace the *original* resolves the name in, and in ZAP a local
  declared by `.FUNCT` already shadows a same-named global), `INC`/`DEC`
  (emitted as the real `INC 'VAR`/`DEC 'VAR` instructions rather than the
  original's un-peepholed `ADD VAR,1 >VAR`), `RETURN`, `RTRUE`, `RFALSE`,
  `QUIT`, and **calls to routines the program defines**. V3 has only the
  storing `CALL` opcode, so a call whose value is discarded is followed by
  `FSTACK` to pop it — confirmed from `EmitCall`'s own `zversion < 4`
  branch, which does exactly this.
- **Conditions**: `IGRTR?`/`DLESS?` (one instruction each, taking the
  variable by number — hence `IGRTR? 'I,MAX`, confirmed against real usage
  in `~/cloak_plus.zap`) and `NOT`/`F?`/`T?` (a polarity flip, no
  instruction, as in the original).
- **Dead-code suppression after a terminating clause**: a `COND` clause
  whose body ends in `RETURN`/`RTRUE`/`RFALSE`/`QUIT` no longer emits the
  now-unreachable result `PUSH` and jump to the end label. Tracked with a
  module-level `termFlag` that `CompileStmt` sets; `CompileRoutine` reads
  the same flag to skip the trailing `RETURN` when the body's last
  statement already left the routine. `COND` itself always reports
  "doesn't terminate", because proving otherwise needs every clause to
  terminate *and* (with no `ELSE`) a clause to always match — the
  conservative answer costs an unreachable instruction, the optimistic one
  would let control run off the end of a routine.
- **Output abstraction** (`OpenOutput`/`CloseOutput`/`W`/`WLn`): emission
  now goes to a real file or to stdout. Note `Files.WriteString` on this
  system appends a NUL byte (it writes Oberon's own null-terminated string
  format, not plain text) — `Files.WriteLine` is the only text-clean file
  write available and writes a whole line at a time, hence the line buffer.

**A real, silently-wrong-code bug found** (fixed in the very next slice —
see the section below; the description is kept because the reasoning is
what the fix is built on).
Every compound sub-expression routes its result through the Z-machine
stack. When *both* operands of a binary op do that, they come back off the
stack in the opposite order to the one they went on — harmless for `+`,
`*` and `EQUAL?`, but wrong for `-`, `/`, `MOD`, `L?` and `G?`. The
original avoids this entirely by spilling one side into a compiler
temporary local (`PushInnerLocal` with a `?TMP` atom). This port can't do
that yet because a routine's local list is already written to the `.FUNCT`
line by the time its body is compiled. **For now the compiler refuses the
case with an explicit error** rather than emitting wrong code (verified:
`<- <+ .A 1> <+ .B 1>>` is rejected; `<+ <+ .A 1> <+ .B 1>>` still
compiles and runs correctly). **The real fix is buffering a routine's body
before writing its `.FUNCT` line**, so the temporaries a body turned out to
need can be appended to the local list — worth doing before any more
codegen widening, since almost every further builtin can hit this.

**`examples/zilf.mod` — the compiler driver** (the `zilf` command that
didn't exist yet). Reads a `.zil`, runs the interleaved read-eval loop over
every top-level form (the original's reader and evaluator are interleaved
by design — `%<...>` and `DEFMAC` both need it), then calls
`CompileProgram`. `zilf game.zil game.zap && zapf game.zap` is now the
whole pipeline. Options: `-e/--entry NAME` (default `GO`, matching
`ZEnvironment.EntryRoutineName`), `-q/--quiet`.

**Tested end-to-end** — the established discipline (compile → assemble with
`zapf` → run in `examples/zmachine.mod` → check the actual printed result,
not that the `.zap` looks plausible):

- A globals program: `CONSTANT MAX-SCORE 350`, four globals, a `BUMP`
  routine doing `<SETG SCORE <+ ,SCORE .N>>` and `<INC MOVES>`, called
  twice from `GO`. Printed `start=0 / score=17 / moves=2 / max=350 /
  left=333 / over ten` — every value correct, exercising global read,
  global write across a routine call, `INC` on a global, a constant as an
  operand, `SETG` from a compound expression, and `COND` branching on a
  global.
- A 12-case regression program re-running all three earlier phase-3b
  milestones through the new driver (`<+ .X 1>`; `<+ <* .X 2> 1>`; the
  `SET`/`PRINTI`/`PRINTN`/`CRLF` doubling routine; the value-`COND` with
  and without `ELSE`; the void-`COND`) plus the new `IGRTR?`, `NOT`,
  `RETURN`, `RTRUE`/`RFALSE` and nested-routine-call cases. All twelve
  printed the expected values.
- The whole real corpus (52 files across `zillib/` and `sample/*/`) through
  the new driver: **zero parse failures** — phase 1's reader result still
  holds under the new top-level loop.

**Tested**: full transpiler regression suite, 138 files (`Modules/*.mod` +
`examples/*.mod`, now including `examples/zilf.mod`) — 135 pass, the same
3 pre-existing-only failures (`ClojBio`, `ClojStats`, `Editor`).

## What's done (phase 3b continued: compiler temporaries, and buffered routine bodies)

Fixes the operand-ordering bug the globals slice could only refuse, which
the plan named as the thing to do before widening codegen any further.

**The bug**: every compound sub-expression leaves its result on the
Z-machine stack, so when two of them feed one instruction, the operands
come back off the stack in the opposite order to the one they went on —
harmless for `+`, `*` and `EQUAL?`, wrong for `-`, `/`, `MOD`, `L?`, `G?`
and for the argument list of a routine call.

**The fix**, the same one the original uses (`PushInnerLocal` with a `?TMP`
atom, in `ZBuiltins.cs`'s `SetValueOp`): spill the earlier value into a
named local so the later one has the stack to itself. `SET '?TMPn,STACK`
is the spill — the Z-machine store instruction reads its value operand
from the stack, popping it.

What that needed structurally: **a routine's `.FUNCT NAME,local,...` line
names every local the body uses, but which temporaries a body needs is
only known once it has been compiled.** So `CompileRoutine` now compiles
the body into a line buffer first, then writes the `.FUNCT` line with the
temporary count the body turned out to need, then flushes the buffer
underneath it. (`START::` is written between the two, matching real zilf
output.)

- Temporaries are allocated by nesting depth (`?TMP1`, `?TMP2`, …) and
  released as each instruction consumes them, so a routine declares only
  as many as its deepest expression actually needed — verified in the
  generated `.zap`: a routine with two sequentially-nested subtractions
  reuses `?TMP1` for both, while a three-argument call with two compound
  arguments declares `?TMP1` and `?TMP2`.
- A spill is emitted only when it is needed: the operand must actually be
  sitting on the stack, *and* something still to be compiled must be able
  to push over it (`IsSimpleOperand` — a FIX/CHARACTER/`<>`/atom/`.X`/`,X`
  operand emits nothing, so an earlier stack value is safe). This
  over-approximates slightly in the safe direction; being wrong costs one
  extra spill instruction, never wrong code.
- The Z-machine's 15-locals-per-routine limit is checked (parameters plus
  temporaries) and reported.

**Tested end-to-end** (compile → `zapf` → `zmachine.mod`, checking printed
values): six routines specifically shaped to need temporaries — `<- <+ .A
1> <+ .B 1>>` (the case the previous slice refused, now correct), a
doubly-nested subtraction, a division with two compound operands, an `L?`
condition with two compound operands in both the true and false
directions, and a three-argument routine call with two compound arguments.
All six correct. All four earlier end-to-end programs re-run and produced
**identical** output, including the ones that never needed a temporary —
so no spill is emitted where one isn't wanted.

**Tested**: corpus (52 files, zero parse failures) and the full transpiler
regression suite (138 files, same 3 pre-existing-only failures).

## What's done (phase 3b continued: VERSION, VERSION?, FILE-FLAGS, GDECL)

The gap analysis's four cheap registrations, plus making `VERSION` actually
mean something in the emitter rather than just being accepted.

Read the originals first (`Subrs.ZModel.cs`'s `VERSION`/`ParseZVersion`/
`CHECK-VERSION?`/`VERSION_P`, `Subrs.Meta.cs`'s `FILE_FLAGS`,
`Subrs.Atoms.cs`'s `GDECL`) — all four are small, and three of them reduce
further in this port because it doesn't have the state they write to.

**`Modules/ZilModel.mod`**: added `zversion` (default 3, reset by `Reset`,
and the module now has an initialisation body that calls `Reset` so the
default holds even if a driver never does) and `timeStatusLine` — the
original's `ZEnvironment.ZVersion` and `.TimeStatusLine`.

**`Modules/ZilEval.mod`**:

- **`ParseZVersion`** — direct port, accepting `ZIP`/`EZIP`/`XZIP`/`YZIP`
  as an atom or a string, or a plain number 3-8; the `GLULX` case is
  dropped (a different VM target, already out of scope).
- **`VERSION`** — sets `ZilModel.zversion`, handles the optional trailing
  `TIME` atom (V3 only, as in the original), returns the version number.
- **`CHECK-VERSION?`** — came free once `ParseZVersion` existed.
- **`VERSION?`** — an FSUBR, `COND`-shaped but testing each clause's
  condition as a version specifier (or `T`/`ELSE`) against the target
  version instead of evaluating it. Kept the original's exact result rule:
  the matching clause's last body value, or the condition itself when the
  clause has no body, or FALSE when nothing matched.
- **`FILE-FLAGS`** — validates the six flag names (so a typo is still an
  error, as in the original) and otherwise does nothing: the only flag with
  downstream meaning for code generation is `CLEAN-STACK?`, and ZilCompile
  already pops every discarded call result unconditionally.
- **`GDECL`** — accepts and discards its arguments, returning T. This is
  the faithful reduction rather than a stub: the original's only effect is
  to attach DECL constraints to global bindings, and this port skips DECL
  checking entirely (an explicit phase-1 simplification).

**`Modules/ZilCompile.mod`** now reads the version for every
version-dependent decision, instead of assuming V3 everywhere:

- `.NEW <version>` in the emitted header.
- The `HERE`/`SCORE`/`MOVES`-first global ordering is applied **only** for
  V3 (as in the original's `FinishGlobals`) — V4+ draws its status line
  from game code, so the order is free there.
- Object-table property defaults: 31 words in V1-3, 63 in V4+; dictionary
  entry length 7 in V1-3, 9 in V4+ (the original's `zversion < 4 ? 4 : 6`
  z-word bytes plus 3 data bytes).
- Routine calls: V1-3 have only `CALL` and a 3-argument limit; V4 splits by
  argument count into `CALL1`/`CALL2`/`CALL`/`XCALL` with a 7-argument
  limit — the same switch as the original's `EmitCall`.
- **V5+ is refused with an explicit error.** zapf auto-generates the
  64-byte header only for V1-4; a V5+ story file has to lay its header out
  by hand with data directives (see `ZapfAsm.WriteHeader`'s own comment and
  the top of `~/cloak_plus.zap`). That's its own slice. Both games this
  port is ultimately aiming at — `advent.zil` and `zork1.zil` — are
  `<VERSION ZIP>`, i.e. V3, so this isn't on the critical path.

**Tested end-to-end**: a program using all four directives, with
`<CONSTANT WHICH <VERSION? (ZIP 3) (EZIP 4) (ELSE 99)>>`, compiled,
assembled and run — printed `version=3`; changing its `<VERSION ZIP>` to
`<VERSION EZIP>` produced a `.NEW 4` header, assembled to a `.z4`, and
printed `version=4`, confirming the version really drives emission and not
just the header byte; changing it to `<VERSION XZIP>` was refused with the
V5 message. All five earlier end-to-end programs re-run with identical
output.

**Measured effect on the corpus** (52 files): evaluation failures 40 → 35,
and — more informative than the count — `advent.zil` itself now gets
through `VERSION`, its `CONSTANT`/`PTABLE` declarations and its scoring
setup before stopping at `COMPILATION-FLAG-DEFAULT`, where before it
stopped on its eighth line. The remaining frontier, by first failure:

| Missing | Files |
|---|---|
| `USE` / `PACKAGE` / `ADD-TELL-TOKENS` (the qualified-OBLIST cluster) | 13 |
| `INSERT-FILE "parser"` not found — the games include library files from `zillib/`, and this port resolves an INSERT-FILE only against the including file's own directory. **A library/include search path is the fix, and it is small** | 5 |
| `ITABLE` keyword argument shapes (`<ITABLE NONE n>`, `<ITABLE BYTE ...>`) | 3 |
| `COMPILATION-FLAG-DEFAULT` / `IF-DEBUG` / `IFFLAG` family | 4 |
| `DEFSTRUCT`, `GUNASSIGN`, `STRING`, `STATUS-LINE-SECTION` | 4 |
| forward references across files (`ZORK-NUMBER`, `INITIAL-PLAYER-MAX-HP`) | 3 |
| SEGMENT splicing inside a LIST | 1 |
| arithmetic on non-FIX values (`sample/rascal`) | 2 |

**Tested**: transpiler regression suite, 138 files, same 3 pre-existing-only
failures.

## What's done (phase 3b continued: include paths, and read-time `%` evaluation)

Two small changes that together moved the corpus further than any codegen
slice has.

**A library search path.** `ZilEval.AddIncludePath`/`ClearIncludePaths`,
and `-i/--include DIR` on the driver. INSERT-FILE now resolves a name
against the including file's own directory first (as before) and then
against each configured library path, keeping the existing per-directory
`name` / `name.zil` / `name.mud` / lowercased variants. Every real game
lives in its own directory and does `<INSERT-FILE "parser">` to pull in the
shared library out of `zillib/`, so without this no real game's source
could be read at all — this is what `ZilEval.SetCurrentDir`'s own comment
had already flagged as "add it if/when something needs it".

**Read-time `%<...>` evaluation** — the last phase-1 stub, and the thing
that turned out to be blocking every cloak-family game. `%<...>` means
"evaluate this NOW, while parsing", and library source really depends on
it: `zillib/parser.zil` builds an OBJECT's property list with
`%<VERSION? (ZIP <LIST DESC ...>) (ELSE ())>`, which is a FORM — not the
LIST an OBJECT property must be — until it's evaluated at read time.

The dependency has to be inverted to do this: ZilEval imports ZilRead, and
Oberon has no circular imports. `ZilRead` now declares
`EvalProc = PROCEDURE(z: ZilObj.Zo): ZilObj.Zo` and an `evalHook` variable
that `ZilEval.InitBuiltins` installs — exactly the pattern `Cloj.mod`
already uses for its own evaluator callback. With the hook NIL (a driver
that only wants to parse) the old behaviour stands: the argument comes back
unevaluated and `rd.sawPercent` is set. `%%<...>` (evaluate and discard) is
handled the same way.

**Three bugs this immediately surfaced, all fixed:**

- **`GLULX` has to be a RECOGNIZED version specifier** even though this
  port will never emit for it. `zillib/parser.zil` defines `WORD-SIZE` with
  `<VERSION? (GLULX <CONSTANT WORD-SIZE 4>) (ELSE <CONSTANT WORD-SIZE 2>)>`
  — rejecting the specifier outright killed the whole form instead of
  simply not matching that clause, so `WORD-SIZE` was never defined at all.
  `ParseZVersion` now returns the original's own `GLULX_ZVERSION` (1000)
  for it; `VERSION` itself still refuses to target it.
- **An evaluation error inside INSERT-FILE didn't stop the included file.**
  Errors are reported through `evalErrFlag`, not through the result's
  outcome (`Err` returns a FALSE *value*), so the include loop kept going
  and every later form failed in some confusing derived way — the
  `WORD-SIZE` case above surfaced hundreds of lines later as
  "`*`: expected FIX args". The loop now checks `evalErrFlag` and stops
  where the error actually is.
- **Error messages didn't carry the underlying cause.** A read-time `%`
  failure surfaces as a *read* error while the useful message is the
  evaluator's, and an INSERT-FILE read error named neither the file nor the
  reason; both now report the full chain. `OBJECT`/`ROOM`'s "each property
  must be a list" now names the object and prints the offending value —
  which is how the `%` problem was found at all.

**Measured effect on the corpus** (52 files, with `-i .../zillib`): **12
files now get all the way through evaluation and into code generation** —
nine are library files that simply have no `GO` routine, two stop on a
global initializer ZilCompile can't render yet, and `sample/mandelbrot`
reaches real codegen and stops on an unimplemented builtin. Every
cloak-family game now reads the whole 4,000-line `zillib/parser.zil` and
stops at `USE` — the qualified-OBLIST cluster, now by far the single
biggest blocker at 11 files.

**Tested**: all six end-to-end programs re-run with identical output;
transpiler regression suite, 138 files, same 3 pre-existing-only failures.

## What's done: the package system (`PACKAGE`/`USE`/`ENTRY`), and the interpreter's predefined globals

The plan named the qualified-OBLIST/package cluster as the next major piece
of work and the single biggest blocker (11 corpus files). It turned out to
be much smaller than feared, for a reason worth recording.

**Read the originals in full first** (`Interpreter/Subrs.Packages.cs`,
`Interpreter/ObList.cs`, `ZilAtom.Parse`, `Context.PushObPath`/`PopObPath`/
`MakeObList`/`InitConstants`) and then, crucially, **surveyed what the
corpus actually uses**: across all of `zillib/` and `sample/`, the entire
package system amounts to **4 `PACKAGE` declarations, 4 `ENDPACKAGE`s, 3
`ENTRY`s and 14 `USE`s**, with five qualified `FOO!-BAR` atom names. Not
the pervasive mechanism the phase-1 and phase-3a notes had assumed.

**Why one flat oblist is enough.** The original gives each package an
internal and an external OBLIST and pushes a three-deep lookup path
(internal, external, root), so an unqualified name written inside a package
resolves to that package's own atom and only `ENTRY`'d names escape. This
port has a single global atom table (phase 1's deliberate simplification),
which makes every name visible everywhere. That is **strictly more
permissive**: any name the original would have resolved still resolves
here. What it gives up is *isolation* — two packages each defining a
different `FOO` would collide here where the original keeps them apart —
and real library and game source is written so that exported names don't
collide anyway. So the package declarations reduce to bookkeeping:

- **`PACKAGE`/`ZPACKAGE`/`ZZPACKAGE`/`DEFINITIONS`/`ZSECTION`/`ZZSECTION`**
  record that the package exists (which is what `USE` checks) and return
  its name atom. `DEFINITIONS` differs from `PACKAGE` only in the oblist
  path it builds — exactly the part that doesn't apply.
- **`ENDPACKAGE`/`END-DEFINITIONS`/`ENDSECTION`/`BLOCK`/`ENDBLOCK`** pop or
  push an oblist path that doesn't exist here: no-ops returning T.
- **`ENTRY`/`RENTRY`** move atoms from a package's internal oblist to its
  external one (or to root), i.e. export them. Everything is already
  globally visible: no-ops.
- **`USE`/`INCLUDE`/`USE-WHEN`/`INCLUDE-WHEN`** are the part that carries
  real weight, and it isn't the oblist manipulation — it's the **loading**.
  `PerformUse` loads a package from a file when it isn't defined yet, and
  that is how `zillib/parser.zil` pulls in `libmsg.zil` at all. Ported
  faithfully: load if not already defined, error if the file is missing or
  if it loads without declaring the package (both "unrecognized package" in
  the original), skip if already loaded. `USE-WHEN`/`INCLUDE-WHEN` take a
  leading condition. `INCLUDE`'s only real difference is requiring a
  `DEFINITIONS`-type package, a distinction that needs the per-oblist
  PACKAGE property this port doesn't keep, so it's a synonym.
- **`COMPILING?`** returns T, as in the original.
- **Built-in packages**: `<USE "QQ">` must NOT try to load `zillib/qq.mud`.
  That file is a full MDL implementation of quasiquote using `NEWTYPE`/
  `MAPF`/`CHTYPE`/`APPLY`/`MAKE-PREFIX-MACRO`, none of which this port has
  — while phase 2d ported quasiquote directly into the evaluator. So the
  requirement really is satisfied, not skipped. `READER-MACROS`,
  `NEWSTRUC`, `ZILCH` and `ZIL` are empty placeholder packages created by
  `Context.InitPackages` in the original, and are treated the same way.

**`LoadFile` factored out.** `USE` and `INSERT-FILE` need identical
find-and-load-and-evaluate behaviour, so it became its own procedure — and
`LoadFile` calls `EvalImpl` while `EvalImpl` calls `LoadFile`, i.e. the
first place in this port to actually use the mutual recursion the earlier
phases wrongly believed was impossible (see the correction section above).
It works; the corpus results were byte-identical across the refactor before
any package code was added.

**The interpreter's predefined globals** (`Context.InitConstants`) turned
out to be the very next blocker once `USE` worked, because
`zillib/parser.zil` opens with `<SETG ZILLIB-VERSION ,ZIL-VERSION>`.
Ported: the compile-time globals `ZILCH`, `ZILF`, `ZIL-VERSION`, `PREDGEN`,
`PLUS-MODE`, `SIBREAKS`, `GLK`, `CORNERSTONE`, and as real ZIL CONSTANTs
(registered with ZilModel, so ZilCompile emits them as assembly symbols)
`TRUE-VALUE`/`FALSE-VALUE`/`FATAL-VALUE` and the ten `P1?`/`PS?`
part-of-speech bit values copied from the original's `PartOfSpeech` enum.
`PLUS-MODE` is updated by `VERSION` as well as at init, matching
`SetZVersion`.

**An initialisation-order bug this surfaced**: `InitBuiltins` ends with
`ZilModel.Reset`, so registering the predefined constants at the *start* of
it silently threw them away — `,TRUE-VALUE` compiled to "undefined
constant" with no other symptom. `InitPredefined` now runs after that
Reset, and the driver no longer Resets again afterwards.

**Tested end-to-end**: a two-file program — a real `mathlib.zil` package
(`PACKAGE`/`ENTRY`/`CONSTANT`/`ROUTINE`/`ENDPACKAGE`) in a separate library
directory, pulled in by the main file with `<USE "MATHLIB">` (twice, to
confirm it isn't loaded twice) alongside `<USE "QQ">` — compiled, assembled
and run: printed `triple=42` (a routine called across the package
boundary), `base=100` (a constant likewise) and `true=1` (a predefined
constant). `<USE "NOSUCHPACKAGE">` is correctly rejected.

**Measured effect on the corpus** (52 files): the `USE`/`PACKAGE`/
`ADD-TELL-TOKENS` cluster is **gone from the failure list entirely**, and
**16 files now reach code generation**. The new top blocker is
`COMPILATION-FLAG-DEFAULT` (7 files, including `advent.zil`).

**Tested**: all seven end-to-end programs; transpiler regression suite, 138
files, same 3 pre-existing-only failures.

## What's done: compilation flags (`COMPILATION-FLAG`, `IFFLAG`, `IF-<FLAG>`)

The plan's next item, and the corpus's top blocker at the time (7 files,
`advent.zil` among them, which opens with `<COMPILATION-FLAG-DEFAULT BETA
<>>`). Ported from `Subrs.Meta.cs` and `Context.DefineCompilationFlag`/
`InitCompilationFlags`.

Flags get their own small name-to-value table rather than living as atom
globals. The original keeps them on a dedicated OBLIST so a flag named
`FOO` can't collide with a global named `FOO` — and with this port's flat
atom table that isolation is the one thing a separate map still has to
provide, so this is the one place the package work's "flat is enough"
argument does *not* apply.

- **`COMPILATION-FLAG name [value]`** defines and redefines (value defaults
  to T); **`COMPILATION-FLAG-DEFAULT name value`** defines only if the flag
  isn't already defined — which is how a game states its own defaults
  without overriding a value set elsewhere. Both accept the name as an ATOM
  or a STRING and return it.
- **`COMPILATION-FLAG-VALUE name`** returns the value, or FALSE when the
  flag is undefined. The undefined-vs-false distinction is kept internally
  (`FlagValue` returns NIL for undefined) because `IFFLAG` needs it.
- **`IFFLAG`** is a `COND` over flags, with the original's exact three-way
  condition matching: a bare ATOM or STRING naming a *defined* flag matches
  when its value is true; a FORM is evaluated after substituting every flag
  name appearing in it with that flag's value; anything else always
  matches, which is what makes a trailing `T`/`ELSE` clause work with no
  special handling. Note the substitution is deliberately **one level
  deep** — `form.Select` over the form's own elements — so
  `<AND DBMAZE VERBOSE>` tests the flags but `<AND DBMAZE <NOT BETA>>`
  does *not* substitute the nested `BETA`. That's the original's behaviour,
  not an omission; a test written expecting the nested case to substitute
  was corrected to match, after checking `SubstituteIfflagForm`.
- **`IF-<FLAG>` / `IFN-<FLAG>`**: defining a flag also makes these usable.
  The original synthesizes a pair of `DEFMAC`s (`IF-{0}!-`/`IFN-{0}!-` on
  the root oblist) that expand to an `IFFLAG`. Building those macro bodies
  as data here would be a lot of structure for no extra behaviour, so the
  names are recognized directly in the evaluator instead — and only when
  the suffix really names a *defined* flag, so an ordinary routine called
  `IF-SOMETHING` is unaffected. Equivalent to the original's expansion
  apart from the `BIND` wrapper it puts around a multi-statement body,
  which isn't needed when the statements are simply evaluated in order.
- The nine flags the original predefines (`IN-ZILCH`, `COLOR`, `MOUSE`,
  `UNDO`, `DISPLAY`, `SOUND`, `MENU`, `LONG-WORDS` false;
  `WORD-FLAGS-IN-TABLE` true) are registered at init.

**Tested end-to-end**: a program covering all of it — a
`COMPILATION-FLAG-DEFAULT` that must *not* override an earlier default, a
`COMPILATION-FLAG` that must, `IFFLAG` selecting by flag name and by
substituted condition form (both the matching and non-matching way), and
`IF-<FLAG>`/`IFN-<FLAG>` guarding top-level definitions. Compiled,
assembled and run: all six printed values correct.

**A limitation this exposed, worth knowing before the next codegen slice**:
`<IF-DEBUG ...>` and any other macro used *inside a routine body* is not
expanded, because routine bodies are stored raw at registration time and
`ZilCompile` does no macro expansion at all yet — it reports "unrecognized
builtin". The original expands macros in routine bodies as part of
compilation. Top-level use (guarding a `CONSTANT`, `ROUTINE` or `OBJECT`
definition) works, since that really is evaluated. **Macro expansion of
routine bodies is now a prerequisite for compiling any real game**, whose
routines are full of library `DEFMAC`s — `TELL` chief among them.

**Measured effect on the corpus**: `COMPILATION-FLAG-DEFAULT` is gone from
the failure list. The new top blocker is `MOBLIST` (7 files).

**Tested**: all eight end-to-end programs; transpiler regression suite, 138
files, same 3 pre-existing-only failures.

## What's done: macro expansion of routine bodies

The prerequisite the compilation-flag slice exposed, and the thing standing
between "compiles toy programs" and "compiles real routines": a ROUTINE's
body is captured raw and unevaluated at registration time, so every `DEFMAC`
used inside it — `TELL` above all, and every `IF-<FLAG>` — was still an
unexpanded FORM when the compiler reached it, and came out as "unrecognized
builtin".

The original does this as the first step of compiling a routine
(`ZilRoutine.ExpandInPlace`, called from `Compilation.Compile.cs`), and the
port follows the same shape.

**The distinction that makes it work: expansion is not evaluation.**
`<TELL "hi">` must turn into the code the macro produces, not run it. This
port's evaluator expands-and-immediately-re-evaluates a macro in one step
(phase 2c), which is right for `Eval` but wrong here — the original has a
separate `ZilForm.Expand` alongside `Eval` for exactly this reason. Added a
one-shot `expandOnlyPending` flag that `ExpandOnce` sets immediately before
a single `EvalImpl` call and that call consumes at entry, so the macro
branch hands back its result instead of re-evaluating it. It deliberately
does **not** propagate into nested `EvalImpl` calls: a macro's own body must
evaluate completely normally, and it is only the macro's *result* that is
wanted unevaluated.

**`ZilEval.ExpandTree`** is the recursive walk, mirroring
`RecursiveExpandWithSplice`: rebuild LISTs, VECTORs and FORMs element by
element, and when a FORM's head is a macro, expand it and then expand the
**result** again, since a macro may expand into another macro call.
`ZilCompile.CompileRoutine` calls it on the body before compiling anything.
`IsExpandable` also recognizes the `IF-<FLAG>`/`IFN-<FLAG>` forms — which
really are macros in the original — and EvalImpl's handling of them now
yields the guarded code in expand-only mode (`<1 .A>` for a single
statement, `<BIND () !.A>` for several, matching the original's generated
macro) instead of evaluating it.

Two deliberate simplifications against the original: no `!.A` splicing of a
macro result into its surrounding list (the original wraps results in
`ZilMacroResult` and `SelectMany`s them; nothing in the corpus's routine
bodies has needed it), and an expansion error leaves the form as it was
rather than substituting FALSE — so the compiler then reports the real
construct it couldn't handle instead of a mysterious `0`.

**Tested end-to-end**: a program with three `DEFMAC`s used inside a routine
body — a simple one, one macro call nested inside another's argument, and a
macro that expands into a *further* macro call (exercising the re-expand
step) — plus `IF-DEBUG`/`IF-BETA`/`IFN-BETA` guarding statements inside the
body, and a macro call inside a `COND` condition (exercising the recursion
through list structure). Compiled, assembled and run: `double=42`,
`nested=23`, `quad=20`, `debug on`, `beta off`, `macro in cond` — all
correct.

**Tested**: all nine end-to-end programs; corpus unchanged (the blockers
ahead of it are all at evaluation time); transpiler regression suite, 138
files, same 3 pre-existing-only failures.

## MILESTONE: the first real game compiled and run — `sample/beer/beer.zil`

`zilf -i .../zillib beer.zil beer.zap && zapf beer.zap && frotz beer.z3`
produces all 99 verses of *99 Bottles of Beer*, with correct singular/plural
grammar and a clean exit. **This is the first complete, unmodified game from
zilf's own sample set compiled by this port and run correctly end to end.**
Verified again with the count reduced to 3 so the whole output is checkable
at once, against the expected text exactly.

`beer.zil` is a real program: a `REPEAT` loop, a `PROG` block arriving from a
quasiquoted `DEFMAC` expansion, `DLESS?` as a loop condition, `PRINTR`,
`PRINTC` with a CHARACTER literal, `N==?`, and a routine call. What it
needed:

### `PROG`/`REPEAT`/`BIND`, `RETURN` and `AGAIN` (`Compilation.Loops.cs`)

`CompilePROG` handles all three (`REPEAT` is `PROG` with `repeat` set;
`BIND` is `PROG` with `catchy` clear — the flag deciding whether an
unqualified `RETURN` may target it, which has no effect here since named
activations aren't implemented, so `BIND` compiles as `PROG`). The body is
bracketed by two labels: an "again" label before it that `AGAIN` jumps back
to, and a "return" label after it that `RETURN` jumps forward to, with
`REPEAT` additionally jumping back to the again label when the body falls
off the end — that jump is the whole of what makes it a loop.

- **A stack of blocks** (`Compilation.Blocks`), not a single current block:
  a `RETURN` inside a `COND` inside a `PROG` inside a `REPEAT` has to leave
  the `PROG`, not the `REPEAT`.
- **`RETURN` is block-aware now.** Inside a `PROG`/`REPEAT` it leaves the
  *block* (push the value, branch to the block's return label); only with no
  enclosing block does it emit a real routine return. That is exactly the
  original's `ReturnOp`.
- **A `REPEAT` body's own value is always discarded** — a loop only produces
  a value by way of a `RETURN`, which is why the original passes `!repeat`
  as the "want result" flag for the body's last statement.
- **Unreferenced end labels aren't emitted**, and a `REPEAT` that nothing
  ever `RETURN`s out of is marked as terminating, since control provably
  never leaves it — so the caller doesn't emit an unreachable trailing
  return after an infinite loop.
- **Bindings are refused, not faked.** A non-empty binding list would need
  extra named locals on the `.FUNCT` line with renaming where a name is
  already in use (the original's `PushInnerLocal`/`PopInnerLocal`). The
  extra-locals machinery exists — it is what compiler temporaries use — but
  the scoping and renaming don't, so a non-empty binding list is an explicit
  error rather than silently compiled into the wrong storage. `beer.zil`
  and most real loop/grouping use is `<PROG () ...>`/`<REPEAT () ...>`.

Also added `PRINTC`, `PRINTR` (print + newline + return true, one
instruction, and it terminates) and `N==?`/`N=?` (the `EQUAL?` instruction
with the branch polarity flipped, as in the original's `NotEqualOp`).

### Two bugs the first real run exposed, both real and both now fixed

**1. ZIL string literals were emitted untranslated.** In ZIL a `|` inside a
string means a newline; the first run printed a literal `|` at every line
break. Ported `Compilation.Strings.cs`'s `TranslateString`: the CRLF
character (`|` by default, overridable by the `CRLF-CHARACTER` global)
becomes a real newline; a *source* newline becomes a space so a long string
can be wrapped across source lines, unless it directly follows a `|`, in
which case it is dropped; a CR is dropped; and two spaces after a `.` or a
`|` collapse to one (the original's default `CollapseAfterPeriod` mode — the
`SENTENCE-ENDS?` and `PRESERVE-SPACES?` variants are not ported). zapf's own
string reader accepts embedded newlines, so the translated text can go
straight into the `.zap`.

**2. The entry routine must QUIT, not return.** `GO` ended with a `RETURN`,
and returning from the initial routine is undefined in the Z-machine —
frotz aborted with "Fatal error: Illegal opcode" after the last verse. The
original says so in `BuildRoutine` in as many words ("the entry point has to
quit instead of returning"), and also never wants a result from the entry
routine's last statement, since there is no caller to give one to. Both
now match.

### A note on interpreters

`examples/zmachine.mod` **hangs** on `beer.z3` — no output at all, where
frotz runs it correctly. Every earlier end-to-end test in this port still
behaves identically under `zmachine.mod`, so this is specific to something
`beer` does (most likely the volume of output and the pager, or the
scrolling screen model), and is a `zmachine.mod` issue rather than a
compiler one — the same story file is correct under frotz. **Verify with
frotz when a compiled game misbehaves under `zmachine.mod`**, and treat a
disagreement between the two as evidence about the interpreter, not
automatically about the compiler.

**Tested**: a dedicated loop program alongside `beer` — a `REPEAT` exited by
`RETURN` from inside a `COND`, a `PROG` used for its value, a `PROG` exited
early by `RETURN`, and an `AGAIN` loop over a global — all five printed the
expected values. All nine earlier end-to-end programs re-run unchanged.
Transpiler regression suite: 138 files, same 3 pre-existing-only failures.

## MILESTONE 2: `sample/mandelbrot/mandelbrot.zil` — a second real game, and the first V4 one

Compiles clean and renders the Mandelbrot set as ASCII art, verified by
running the story file and reading the picture. It is `<VERSION EZIP>`, so
it also exercises the V4 emission path (`.NEW 4`, the `CALL1`/`CALL2`/
`CALL`/`XCALL` split, 63-word property defaults) end to end for the first
time. Three things it needed:

### `"OPT"`/`"AUX"` arguments (`DefineLocalsFromArgSpec`)

A ZAP `.FUNCT` line doesn't distinguish the three argument kinds — they are
all just the routine's locals, in order, and the Z-machine's own calling
convention is what makes the leading ones parameters: the caller supplies
some, and every local the caller didn't supply keeps its declared default.
So this is mostly a matter of collecting them in source order with their
defaults. A constant default rides along on the `.FUNCT` line as
`NAME=value`; a non-constant one (mandelbrot has several, e.g.
`(SPANX <* 3 ,MANDEL-SCALE>)`) becomes an assignment emitted at the top of
the body, which the buffered-body design already made easy. An **`"OPT"`
argument with a non-constant default is refused**: it would have to run
that assignment only when the caller *didn't* supply the argument, which
needs an argument-count test this port doesn't emit — better an explicit
error than silently overwriting a supplied value. Renaming to avoid
shadowing (`MakeUniqueVariableName`) is not ported.

### A table of one-instruction builtins

The bulk of `ZBuiltins.cs`'s 237 registrations are just "emit this opcode
with these operands", so `SimpleBuiltin` is a lookup returning the ZAP
mnemonic, the operand count and whether it stores — which is what decides
between the value path in `CompileOperand` and the void path in
`CompileStmt`. Both paths compile every operand before writing the
instruction line (an operand can emit instructions of its own) and spill to
a temporary where a later operand could push over an earlier one, the same
rule the arithmetic and call paths already use. Registered so far:
`GET`/`NTH`, `GETB`, `GETP`, `GETPT`, `NEXTP`, `BAND`, `BOR`, `BCOM`,
`ASH`/`ASHIFT`, `SHIFT`, `RANDOM`, `LOC`, `PTSIZE`, `PUT`, `PUTB`, `PUTP`,
`MOVE`, `REMOVE`, `FSET`, `FCLEAR`, `HLIGHT`, `SCREEN`, `SPLIT`, `CLEAR`,
`CURSET`, `BUFOUT`, `DIROUT`, `USL`, `PRINT`, `PRINTD`, `PRINTB`, `PRINTU`,
`PUSH`, `RESTART`. Adding another is one line. Builtins with real
compilation behaviour (the predicates, the variable ops, `COND`, the loop
constructs, calls) are deliberately not in the table.

Also added the comparison predicates `G=?`/`L=?` — no separate Z-machine
instruction, just `LESS?`/`GRTR?` with the branch polarity flipped, exactly
as the original defines them.

### Table emission (`Compilation.Tables.cs`)

Every registered `TABLE`/`LTABLE`/`PTABLE`/`PLTABLE`/`ITABLE` is emitted as
a labelled ZAP table (`T?1`, `T?2`, ..., the original's own generated
naming), and `ConstantText` renders a table *value* as its label — so
`<CONSTANT MANDEL-CHARS <TABLE ...>>` emits `MANDEL-CHARS=T?1` and a `GET`
against it resolves. Tables are matched **by identity**, not by name or
contents: a table is an anonymous value that a CONSTANT or GLOBAL happens
to hold, and the same contents could legitimately appear twice (the
original keys its own dictionary by reference for the same reason).
Element width is a word unless the table was flagged BYTE; an LTABLE's
length prefix is emitted in the same width; ITABLE's repetition is already
expanded when the value is built. The LEXV format is not ported.

All tables are emitted in **dynamic** memory, before `IMPURE::`, even ones
declared PURE. Static memory is read-only, so putting a pure table there is
the optimisation and putting it in dynamic memory is the safe direction —
a game that writes to a table the compiler wrongly believed was pure still
works.

Error messages now name the offending builtin or global, which is what
turned "unrecognized builtin" into a two-minute diagnosis rather than a
bisect.

**Tested**: `mandelbrot` compiled, assembled and run (art verified by
reading it); `beer` still compiles and runs; a dedicated argument-spec
program (`"AUX"` with constant and computed defaults, `"OPT"` with and
without the argument supplied, `G=?`/`L=?`) printed all five expected
values. All eleven end-to-end programs pass. Transpiler regression suite:
138 files, same 3 pre-existing-only failures.

**Corpus**: `sample/name` now reaches `TELL`, the last big codegen piece
before a parser-driven game.

## What's done: `TELL`, and object/property/flag tables

Two of the three items the plan named next. Both are tested end to end, and
together they are what a game with a world model needs.

### `TELL` (`ZModel/TellTokens.cs` + `Compilation.Expressions.cs`)

`TELL` is not a fixed builtin — it is a variadic print statement driven by a
table of token patterns that the library extends with `ADD-TELL-TOKENS`, so
`<TELL "x" CR D ,HERE>` and the library's own `<TELL T .OBJ>` go through one
matcher.

- **A pattern** is a sequence of token specs plus an output FORM. A spec is
  an atom (match it), a LIST of atoms (match any — this is how `(CR CRLF)`
  gives `CR` an alias), `*` (match anything and capture), or `<GVAL atom>`
  (match that exact GVAL). The output FORM's `<LVAL ...>` elements are
  replaced by the captures in order, and the result is compiled as an
  ordinary statement. Patterns and outputs are kept as plain Zo structures
  and walked directly rather than parsed into a separate representation,
  which makes `ADD-TELL-TOKENS` almost nothing: accumulate token specs until
  a FORM that isn't a `<GVAL ...>` arrives, and that FORM ends the pattern.
  `*:DECL` specs are not matched (they need DECL).
- **The five built-in patterns** (`(CR CRLF) <CRLF>`, `D`/`N`/`C`/`B` with
  their print opcodes) are built directly rather than parsed from source
  text as `Context.InitTellPatterns` does — there is no reader to hand a
  string to here, and five patterns is little enough that a parser would
  cost more than it saved.
- **The fallbacks**, in the original's order: a literal STRING prints inline
  (translated, so `|` really is a newline), a CHARACTER prints as a
  character, `'FOO` prints an object's short description, `P?FOO expr`
  fetches and prints that property, and anything else is printed as a
  packed string address. A bare atom that is none of these is an error
  naming the atom, as in the original.
- `CompileTell` is **its own procedure calling `CompileStmt`, which calls
  back** — the second place this port uses the mutual recursion earlier
  phases believed impossible.

### Objects, properties and flags (`Compilation.Objects.cs`)

An OBJECT/ROOM's property list is stored raw and uninterpreted at
registration time, so this is where `DESC`, `IN`/`LOC`, `FLAGS` and ordinary
properties are finally told apart.

- **Numbering counts DOWNWARDS**, exactly as the original does: property
  numbers start at the maximum (31 in V1-3, 63 in V4+) and descend in
  definition order; flag numbers start at the maximum minus one (31 / 47)
  and descend. Getting this backwards would still assemble and still run —
  it would just silently disagree with every property-default slot — so it
  is worth stating rather than leaving to be re-derived.
- **Emitted**: `NAME=<n>` and `FX?NAME=<bit>` per flag (the bit mask being
  what an `.OBJECT` row's flag words are built from), `P?NAME=<n>` per
  property, the property-default words in property-number order, one
  `.OBJECT name,flags1,flags2[,flags3],parent,sibling,child,?PTBL?name` row
  per object, and a `?PTBL?name` table per object holding its `.STRL`
  description and its properties **in descending property-number order**,
  which the Z-machine's property lookup relies on.
- **The containment tree** is built the original's way: each child is pushed
  onto the front of its parent's child list (`ob.Sibling = parent.Child;
  parent.Child = ob`).
- **`ConstantText` now resolves flag names and `P?NAME`**, because
  `CompileObjects` runs before any routine is compiled, so by the time a
  routine body references one it is registered. The original reaches these
  the same way — `DefineFlag`/`DefineProperty` each add a `Constants` entry.
- Added the object predicates `FSET?`, `IN?`, `FIRST?` and `NEXT?` (the last
  two store a value *and* branch; in a condition position only the branch
  matters and the value goes to the stack).
- **Not handled, and skipped with a comment in the emitted `.zap` rather
  than failing the compile**: `SYNONYM`, `ADJECTIVE`, `PSEUDO`, and
  direction properties like `(NORTH TO CELLAR)`. All of them need the
  vocabulary and complex-`PROPDEF` machinery that isn't ported. Failing
  would block every game that has a map; skipping leaves the gap visible in
  the output.

**Tested end-to-end**, one program covering both: three objects and a room
with `DESC`/`IN`/`FLAGS`/`SIZE`, a `<PROPDEF SIZE 5>` default, and a `GO`
that prints an object's description through `TELL`'s `D` token (both from a
global and by name), through `'FOO`, reads an explicit property and a
**defaulted** one (`ROCK` has no `SIZE`, so 5 comes out of the
property-default table — which validates the default slots and the property
numbering together), tests two flags in both directions, `MOVE`s an object
and re-reads its location. Every one of the eleven printed values correct.
A separate `TELL` program covers the token matcher: literal strings, `CR`,
`N`, `C` with a character literal, globals as operands, a compound
expression as an operand, and custom tokens registered by
`ADD-TELL-TOKENS` including an alias list.

**Tested**: all thirteen end-to-end programs; `beer` and `mandelbrot` still
compile clean; transpiler regression suite, 138 files, same 3
pre-existing-only failures; corpus unchanged (the 5 "parse error" entries
are the documented read-time-`%` failures from compiling library sub-files
standalone, where a global their parent file sets is missing).

**Corpus**: `sample/name` now gets past `TELL`'s built-in tokens and stops
on its own `BUF` token, which its hand-written `TELL` macro would have
defined — that file needs the MDL list primitives, not more TELL work.

## MILESTONE 3: `sample/name/name.zil` — the first INTERACTIVE game, plus the MDL interpreter layer

`name.zil` asks for your name and two years and tells you how old you are.
It compiles, assembles and runs correctly under frotz: status line, `READ`
input, buffer manipulation, and the right arithmetic (`1852 - 1815 = 37`).
It is the first compiled game here that takes input, and getting it working
needed most of the MDL interpreter layer this port had been doing without —
because `name.zil` defines **its own `TELL`** as a `DEFMAC` built on
`MAPF`/`FUNCTION`.

### The MDL primitives (`Interpreter/Subrs.*`)

- **Structure access**: `NTH`, `REST`, `EMPTY?`, `LENGTH`, `TYPE`,
  `PRIMTYPE`, `TYPE?`, `STRUCTURED?`, `APPLICABLE?`, `SPNAME`/`PNAME`,
  `PARSE`, `ERROR`. All three value shapes are handled — cons chains
  (LIST/FORM), flat arrays (VECTOR/TABLE) and STRINGs — so `REST` on a
  VECTOR or STRING copies, this port having no offset-view representation.
  `TYPE?` returns the matching type ATOM rather than plain T, as the
  original does, because real source uses the returned atom.
- **`<1 .L>`**: a FIX applied as a function is MDL's element accessor. Real
  source uses this spelling far more than `NTH` itself.
- **`FUNCTION`**: an anonymous `DEFINE` — the same value, never named.
- **`APPLY`**, and **`MAPF`/`MAPR`** with `MAPRET`/`MAPSTOP`/`MAPLEAVE`.
  The map control forms propagate out of the loop function exactly the way
  `RETURN` propagates out of a `PROG`, so the enclosing `MAPF` catches them
  through any nesting. **With no structure arguments at all, the loop
  function is called repeatedly with none** until it stops — an idiom real
  source really uses as a generator, and precisely what `name.zil`'s `TELL`
  does to walk its own argument list.
  `ApplyValue` reuses the ordinary application path by building
  `<fn <QUOTE a0> ...>` rather than duplicating the argument-binding
  machinery.
- **SEGMENT splicing** (`!.X`) in an argument list and in a LIST literal —
  `<FORM PROG '() !.O>` is how source builds a form from a computed list of
  statements.

### A real bug this exposed: `"ARGS"` must bind arguments UNEVALUATED

`name.zil` first compiled and ran but printed *"You must be about 0 by
now"*. The generated code said `PRINTN 0`: `<- ,CURYEAR ,BIRTHYEAR>` had
been **constant-folded at macro-expansion time**, both globals still holding
their declared 0.

The cause was an earlier phase's belief, written into `ZilEval.mod`'s own
comment, that a `DEFMAC`'s call-site arguments are always evaluated as they
are bound. Checking `ArgSpec.cs` shows the real rule:
`evaluator.GetRest(eval && !varargsQuoted)` — **`"ARGS"` binds the rest of
the arguments unevaluated, `"TUPLE"` binds them evaluated**. That one bit is
the entire difference between the two clauses, and it is what makes a
`DEFMAC` written with `("ARGS" A)` a real macro: it sees the call site's
syntax rather than its values. This would have silently miscompiled every
game using such a macro — which is most of them.

### `MOBLIST`/`LOOKUP`/`INSERT` — OBLISTs as compile-time data

The corpus's top blocker for a long time, and a genuinely different problem
from the package work. `zillib/libmsg.zil` doesn't use oblists for name
*resolution* (the flat table handles that); it uses them as **hash maps
built while compiling**, interning one atom per library message per
category.

The shape that made this small: **an OBLIST value carries nothing but its
name**, and `INSERT`/`LOOKUP` intern `NAME!-<oblist name>` in the one flat
table. That reproduces the original's own qualified spelling
(`SUCCESS!-TAKE!-LIBRARY-MESSAGES`) exactly, so source that writes such a
name out literally finds the same atom. Membership — what distinguishes
"this oblist contains N" from "an atom of that name exists somewhere" — is
recorded on the atom's own property list under an internal indicator,
reusing `PUTPROP`/`GETPROP` rather than adding a table. `ROOT` and `OBLIST?`
came along with it.

Verified directly: `LOOKUP` false before `INSERT` and the same atom after,
the interned atom really being the one spelled `FOO!-MYLIST` (checked by
`SETG`ing that literal name and reading it back), two oblists keeping
separate entries of the same name, and the two-level nesting `libmsg` builds
(`SUCCESS!-TAKE!-MYLIST`). All six values correct.

### Compiler work `name.zil` also needed

- **`PROG`/`REPEAT` bindings**, previously refused. Bindings become extra
  locals on the `.FUNCT` line, scoped by a rename stack — the Z-machine
  knows nothing about inner scopes, so the scoping is entirely the
  compiler's job, as it is in the original (`PushInnerLocal`/
  `PopInnerLocal`). A binding shadowing a parameter gets a distinct ZAP name
  (`X?1`); sibling blocks binding the same name **share one slot** rather
  than each burning another of the routine's fifteen. `SET` resolves through
  the rename stack and `SETG` deliberately does not, so `<SETG X ...>` inside
  a `PROG` binding `X` still writes the global — verified both ways.
- **`AND`/`OR`**, in both positions: short-circuit *branching* in a
  condition (no value materialised at all), and in a value position the
  first true (OR) / first false (AND) operand, held in a compiler temporary
  because the test must not consume it. Verified that the short-circuit
  really short-circuits, by printing from the operands.
- **A routine-level block**, so a bare `<AGAIN>` loops back to the start of
  the routine. It has an again label but **no return label**, which is how
  the original distinguishes it — a `RETURN` with no enclosing `PROG` must
  leave the routine, not jump to a block label.
- **`EQUAL?` widened to 2-4 arguments**, matching the first against any of
  the rest in one instruction, as the original does.
- **An empty FORM `<>` compiles as 0.** The evaluator turns one into FALSE
  when it sees it, but a routine body is never evaluated, so the literal
  `<SET OK <>>` in real source arrives at the compiler still shaped as an
  empty FORM.
- `READ`, `COPYT`, `PRINTT`, `ZWSTR`, `DIRIN`, `INPUT`, `SOUND`, `POP`,
  `FSTACK`, `MARGIN` added to the one-instruction builtin table; a TABLE
  value usable directly as an operand (macro expansion can substitute one
  into a routine body).

**Tested**: sixteen end-to-end programs, all passing; `beer`, `mandelbrot`
and `name` all compile and assemble; transpiler regression suite, 138 files,
same 3 pre-existing-only failures.

**Corpus**: `MOBLIST` is gone from the blocker list. `cloak`, `empty` and
`cloak_test` now evaluate the entire zillib — parser, library messages and
all — and stop at `DEFSTRUCT`; `advent` stops at `STRING`.

## MILESTONE 4: `zillib` evaluates end to end — `DEFSTRUCT` and the last interpreter gaps

**`sample/cloak/cloak.zil` now evaluates completely** — the whole of
`zillib`: the 4,000-line parser, the library-message system with its
per-category oblists, pronouns, the DEFSTRUCT records, the package system,
the compilation flags — and reaches **code generation**. That was the goal
`DEFSTRUCT` was blocking.

### Parsing source from a string (`ZilRead.OpenString`)

The original builds generated definitions by writing ZIL source as text and
parsing it (`Program.Parse(ctx, template, ...)`), which is how `DEFSTRUCT`
makes its accessors. `ZilRead` could only read files; it now also reads from
a string, so this port can use the same approach instead of assembling macro
bodies out of cons cells by hand.

### `DEFSTRUCT` (`Subrs.Defstruct.cs`)

`<DEFSTRUCT NAME BASE (FIELD DECL options...) ...>` defines a record over a
TABLE or VECTOR. BASE is a type atom or a list of option clauses
(`('NTH fn) ('PUT fn) ('START-OFFSET n)`); each field may override
`'NTH`/`'PUT` and give an explicit `'OFFSET`, otherwise the offset
auto-increments.

- **Accessors** are generated from the original's own template and
  evaluated. The original has three, differing only in how much DECL
  checking they wrap around the access; this port skips DECL checking
  entirely, so its `SNoCheckTemplate` — no wrapping at all — is exactly
  right, and the other two would only add machinery that does nothing.
- **`MAKE-<NAME>`** is implemented natively rather than as the original's
  (very large) generated macro, which would have needed `CHTYPE`,
  `IVECTOR` and `SPLICE` just to construct a record. All three call shapes
  are supported, distinguished as the original's macro does by inspecting
  the **raw** first argument: fill an existing object
  (`<MAKE-FOO 'FOO obj 'FIELD v ...>`), build one by field name, or build
  one positionally. A field's element index is its offset measured from the
  structure's own start offset.
- Not ported: `'CONSTRUCTOR`, `'INIT-ARGS`, `'PRINTTYPE`, and per-field
  default values — none is used by the corpus. `'NODECL`/`'NOTYPE` are
  accepted and do nothing, there being no DECL checking or type registry to
  suppress.

### The interpreter gaps `zillib` needed after that

- **`<BYTE n>` / `<WORD n>`** mark a table element's width. The original
  CHTYPEs the value to the BYTE type; with no type system here the width is
  recorded as a property on the value, and `CompileTables` honours it
  per element — so `<TABLE 0 0 <BYTE 0> <BYTE 0>>` really emits two words
  then two bytes.
- **`CHTYPE`**, restricted to the conversions that can mean anything here:
  the structural ones between LIST/FORM and VECTOR (quasiquote's own
  implementation does `<CHTYPE .X FORM>`). Retyping to anything else
  returns the value unchanged, which is the right answer precisely because
  nothing downstream inspects a type tag.
- **`MEMQ`/`MEMBER`**, **`ASCII`** (both directions), **`MIN`/`MAX`**,
  **`ABS`**, **`GBOUND?`/`BOUND?`**, **`SET-SOURCE-INFO`** (a no-op here,
  this port tracking no source lines).
- **`MAPRET`/`MAPSTOP` with more than one value.** `pronouns.zil` really
  does `<MAPRET a b c>` to contribute three statements per iteration. A
  ZResult carries one value, so the rest ride in a module-level list the
  enclosing `MAPF` drains.
- **An empty ROUTINE body is legal.** `zillib` generates routines whose
  whole body is spliced in from a `MAPF`, and that list is legitimately
  empty when the game defined none of whatever it enumerates —
  `pronouns.zil`'s `V-PRONOUNS` for a game with no `<PRONOUN>` definitions.
  The compiler emits `RTRUE` for such a routine.

### A diagnostics fix that was worth more than it looks: **the first error wins**

An error's result is an ordinary value (the atom `FALSE`), not a distinct
outcome, so a failure doesn't stop the surrounding evaluation by itself —
callers keep going, fail again on the bad value, and **overwrite the message
that actually explained what went wrong**. Chasing `cloak.zil` produced
"SEGMENT: expected a structured value to splice, got FALSE", which was the
*second* error; the real one was a missing `ASCII`. `Err` now keeps the
first message, and the splice paths check the error flag directly. Every
subsequent blocker in this session was diagnosed in one step instead of
several.

**Tested**: sixteen end-to-end programs, all passing; `beer`, `mandelbrot`
and `name` all still compile, assemble and run (`name` re-checked
interactively, still answering 37); transpiler regression suite, 138 files,
same 3 pre-existing-only failures.

**Corpus**: `cloak` reaches code generation and stops on a table element it
can't render; `advent` stops at `BIT-SYNONYM`.

## What's done: the dictionary, the syntax/action tables, and packed strings

The vocabulary layer the plan scoped as its own session. `cloak` now gets
through object, vocabulary, syntax and most routine compilation; it is not
yet running (see the end of this section for exactly what is left).

### Vocabulary (`ZilModel` + `ZilEval` + `ZilCompile.EmitVocabTable`)

- A **word registry** in `ZilModel`: text, the set of PartOfSpeech bits, and
  a number per part of speech. Numbers count **down from 255** in a separate
  sequence per part, as `OldParserVocabFormat` does.
- **Registration** from `VOC` (with its optional part-of-speech argument),
  `DIRECTIONS`, `BUZZ`, `SYNTAX` (the verb and every preposition), and
  objects' `SYNONYM`/`ADJECTIVE` properties.
- **The dictionary**, emitted in the V1-3 layout from
  `GameBuilder.FinishSyntax` plus `OldParserWord.WriteToBuilder`: break
  characters, entry length, count, then `W?FOO:: .ZWORD "foo"` and three
  data bytes per word. Two things there are not free choices — words must
  be **sorted**, because run-time lookup is a binary search; and each word's
  two value bytes are chosen from its parts of speech in a **fixed priority
  order** that the "First" flags can promote within, copied from
  `WriteToBuilder` rather than reinvented.
- **The Z-character encoding is not done here at all.** `zapf` already
  implements it and exposes it as `.ZWORD`, so this only emits the
  structure around it — which is what made the whole slice tractable.

### Syntax, action and verb tables (`Compilation.Syntax.cs`)

`SYNTAX` is now decomposed rather than stored raw: verb, up to two objects
with their prepositions, `(FIND flag)` clauses, scope-option lists (the
original's `ScopeFlags.Original` bits, defaulting to 240 when a line names
none), the action and an optional pre-action.

Emitted: `ST?VERB` per verb (a count byte then one 8-byte line each, in
**reverse** definition order as the original does), `VTBL` with one word per
possible verb value indexed `255 - verbValue`, `ATBL`/`PATBL` for the action
and pre-action routines, and `PRTBL` as a count plus (word, number) pairs.
The four globals the parser reaches them through — `VERBS`, `ACTIONS`,
`PREACTIONS`, `PREPOSITIONS` — are defined by the **compiler**, not the
source, matching the original's `GetGlobal(...).DefaultValue = table`.

**An action has two names** and they are not interchangeable: the routine
that implements it (`V-TELL`) and the constant that identifies it
(`V?TELL`), derived by turning a leading `V-` into `V?`. Getting that wrong
is silent — the constant simply never resolves.

### Objects' word properties

`SYNONYM` and `ADJECTIVE` are no longer skipped. Their values are dictionary
words rather than ordinary constants, so they have their own emission:
`SYNONYM` holds word addresses, and `ADJECTIVE` holds the adjective
**number** in V1-3 (one byte, via an `A?NAME` constant) and the word address
in V4+ — the original's own version split.

### Packed strings

A STRING used as a *value* — in a table, as an operand, as `TELL`'s
packed-string fallback — needs an address, so strings are pooled and emitted
as `.GSTR STR?n,"..."` with identical texts shared. `ConstantText` returns
the symbol.

### Compiler generalisations this needed

- **`CompileOperand` and `CompileStmt` are now mutually recursive.** A
  statement-shaped builtin is perfectly usable as a value (`<SET X <COND
  ...>>`), so `CompileOperand` delegates those to `CompileStmt` rather than
  duplicating them. The recursion terminates because `CompileStmt` only
  falls back the other way for heads that are *not* in that list.
- **Predicates used as values.** `<SET X <FSET? .O ,BIT>>` compiles the
  branch and materialises a 1 or 0 through a temporary — the original's own
  PredCall-vs-ValueCall distinction. This fixed every predicate at once
  rather than just the one that surfaced.
- **`DO`** (`Compilation.Loops.cs`'s bounded loop): counter as an inner
  local, a FORM `end` treated as a predicate tested *before* the body and a
  value `end` compared *after* the increment, direction from the step or
  from constant start/end.
- **`VERSION?` and `IFFLAG` inside a routine body** are resolved during
  macro expansion, since they select *source* at compile time — the same
  treatment `IF-<FLAG>` already had.
- `BTST`, `0?`, `1?`, `ZGET`/`ZPUT`/`ZGETB`/`ZPUTB` aliases, and an empty
  FORM `<>` compiling as 0 in constant position as well as operand
  position (object property lists are raw too).

### A transpiler gotcha worth recording

`nObjects` was both an exported VAR in `ZilModel` and a new field in
`SyntaxRec`. An exported top-level VAR becomes a bare, unscoped C `#define`,
so `s.nObjects` compiled to `s.ZilModel_nObjects` and the field "did not
exist". Record field names are safe in general; they are **not** safe when
they collide with an exported VAR in the same module. The field is now
`numObjects`, with a comment saying why.

### What is still between `cloak` and running

It stops on a LIST reaching `CompileOperand` — a library message expansion
that should be **spliced** into its enclosing `TELL`. So: SEGMENT splicing
inside a routine body (the compiler side; the interpreter side is done),
then `LIBRARY-MESSAGE`, then `MAP-CONTENTS`/`MAP-DIRECTIONS`, `PSEUDO`
properties and complex-PROPDEF direction properties.

**Tested**: sixteen end-to-end programs, all passing; `beer`, `mandelbrot`
and `name` all still compile, assemble and run, `name` re-checked
interactively; transpiler regression suite, 138 files, same 3
pre-existing-only failures.

## What's done: pushing `cloak` through code generation

`cloak` now compiles **every routine in `zillib` except one**, which needs
one more local than the Z-machine allows (see the end). Everything below was
needed to get there, and all of it is general rather than cloak-specific.

### Splicing, and where expansion has to happen

- **A macro can return a SPLICE**, whose elements replace it in the
  enclosing form rather than becoming one element. `zillib`'s
  `LIBRARY-MESSAGE` does exactly that — `<CHTYPE <RESOLVE-MESSAGE-DEFINITION
  ...> SPLICE>` — to expand into several `TELL` tokens at once. Added a
  `KSplice` kind, `CHTYPE ... SPLICE`, and splicing in `ExpandTree`.
- **A TELL pattern's output needs expanding too.** The body is expanded
  before compilation, but a pattern's output form is built *during* it, and
  `zillib`'s `IFELSE` token expands to a `DEFMAC`.
- **A routine's ARGUMENT SPEC needs expanding** as much as its body: an
  `"AUX"` default is ordinary code, and `zillib` writes
  `<ROUTINE R (SPEC "AUX" (A <OBJSPEC-ADJ .SPEC>))>` where that default is a
  DEFSTRUCT accessor macro. The original expands both, spec first.
- **`VERSION?`/`IFFLAG` in a routine body** select source, so they are
  resolved during expansion like `IF-<FLAG>` already was.
- **An expansion failure is now reported** rather than leaving the
  unexpanded form for the compiler to reject as "unrecognized builtin
  `<macro name>`", which pointed at the macro instead of at what went wrong
  inside it.

### `OBJECT`/`ROOM` evaluate their property lists

The original registers them as `[Subr]`s — with **evaluated** arguments —
and that is load-bearing: `zillib` writes `<OBJECT ROOMS ... (FLAGS
!,KNOWN-FLAGS)>`, and it is list evaluation that splices those 28 flag names
in. Every other element of a property list self-evaluates, so nothing else
changes.

### Words referenced only from code

A routine can name a dictionary word nothing else mentions (`W?COMMA`). The
original creates it on demand, which works there because its dictionary is
written after the routines; here the dictionary must come first, because it
lives in static memory and routines live in high memory. So routines are now
**prepared** before any data is emitted: each one's spec and body are
expanded once (and stored back, so compilation doesn't repeat the work) and
scanned for `W?`/`ACT?`/`PR?`/`A?` references.

### Compiler additions

- **`DO`** and **`MAP-CONTENTS`** (including its three-element form, which
  binds the *next* child before the body so the body may move the current
  one out).
- **`APPLY`/`CALL`** — a call through a computed address.
- **N-ary arithmetic**, folded left, with `<- x>` as negation and
  `<REST t>`/`<BACK t>` defaulting their offset to 1.
- **`EQUAL?` chained** past three comparands (real source tests a word
  against a dozen), branching to the label from each group when matching and
  past it when not.
- **A destination hint** (`CompileOperandTo`), the original's
  `CompileAsOperand(..., dest)`: `<SET X <+ .A .B>>` becomes `ADD A,B >X`
  instead of going through the stack, and AND/OR and predicates accumulate
  into the destination instead of a temporary.
- **Blocks in condition position**: a `PROG`/`BIND` whose value is only
  being tested compiles its last statement *as a condition*, materialising
  nothing.
- `ORB`/`ANDB` instructions, `FIRST?`/`NEXT?` as values, strings as
  operands, `SYNONYM`/`ADJECTIVE` object properties, the parser globals
  registered so `,VERBS` resolves like any other global.

### Local-slot pressure — the interesting constraint

A Z-machine routine has **fifteen locals**, and `zillib` routines routinely
declare thirteen or fourteen. Four changes were needed before the library
would fit:

1. **One pool.** Compiler temporaries come from the same pool as
   `PROG`/`REPEAT` bindings rather than a separate `?TMP` series, so a
   binding that has gone out of scope can serve as a temporary.
2. **Reuse any free slot**, not only one previously used for the same name —
   the original's `SpareLocals`.
3. **Predicates materialise on the stack**, the same shape `COND` uses,
   instead of in a temporary.
4. **Operand-order fix-ups happen after the fact, and only when needed.**
   The old rule spilled the left operand whenever the right one *might*
   push. The emitter actually has a stronger invariant — a compiled operand
   leaves a value on the stack exactly when it returns `"STACK"` — so
   whether a fix-up is needed is *knowable afterwards*: if both ended up on
   the stack, pop the right one into a temporary, which also leaves them in
   the right order. And for a **commutative** operation the reversed order
   is the same answer, so no temporary at all.

   Temporaries are also released **by name** rather than by position in the
   rename stack, because a temporary's lifetime can straddle other
   allocations (a call spills several arguments while compiling the ones
   between) and popping "the top" then frees somebody else's slot.

### What is still in the way — one routine, one local

**`cloak` emits 81 routines and then stops on `zillib`'s
`MATCH-NOUN-PHRASE`.** That routine declares thirteen locals of its own and
contains a `REPEAT (I)` and a `DO (J ...)` whose scopes overlap, so all
fifteen slots are in use before any compiler temporary — and one expression
inside still wants one.

What has been ruled out, so the next session doesn't redo it:

- It is **not a leak.** Every statement is now checked for leaked bindings
  and temporaries when it finishes, and the check is clean; the accounting
  really is 13 + 2 = 15.
- It is **not** the obvious temporary sources. Predicates materialise on the
  stack, commutative operations skip the order fix-up, `SET`, calls,
  arithmetic and one-instruction builtins all store into their destination,
  blocks in condition position materialise nothing, and bitwise ops fold
  n-ary.

What is left to try, in order of likely value:

1. **`AND`/`OR` in value position with no destination** still takes a
   temporary, because the accumulated value must be testable without being
   consumed. Giving it a stack-only shape, or threading a destination
   through more callers (a `RETURN <OR ...>`, a block's last statement),
   would remove the last one.
2. **Reuse a dead parameter slot.** The original tracks which locals are
   still live; a parameter that is never read again is a free slot. That is
   a bigger change (liveness) but it is the general answer.
3. Failing both, note that this is **one library routine**: a targeted
   rewrite of the offending expression is not available (the library is not
   ours to change), but the routine could be compiled with a
   `SET`-into-an-existing-local shape if the expression were recognised.

After that: `PSEUDO` properties and complex-PROPDEF direction properties,
both still skipped with a comment in the emitted `.zap`.

**Tested**: seventeen end-to-end programs, all passing; `beer`,
`mandelbrot` and `name` all still compile, assemble and run (`beer` and
`name` re-checked under frotz, `mandelbrot` still rendering its 49 rows of
art); transpiler regression suite, 138 files, same 3 pre-existing-only
failures.

## Corpus gap analysis: exactly what blocks compiling a real game

Running the new driver over all 52 corpus files makes the remaining gap
concrete and *short*. Nothing fails to parse; 40 files fail during
evaluation, and every failure is one of a small set of missing top-level
SUBRs (count = files blocked at that point, first failure only):

| Missing | Files blocked | Notes |
|---|---|---|
| `VERSION` | 9 | `<VERSION ZIP>` / `<VERSION XZIP>` — sets the Z-machine version. Small, and it gates the first line of nearly every game including `advent.zil`. |
| `FILE-FLAGS` | 7 | per-file compiler flags; likely a near-no-op registration |
| `PACKAGE` | 4 | needs the qualified-OBLIST system (known blocker, see phase 3a) |
| `USE` | 4 | same OBLIST blocker |
| `ADD-TELL-TOKENS` | 3 | same OBLIST blocker (already investigated — see above) |
| `ITABLE` arg shapes | 3 | `<ITABLE NONE n>` / `<ITABLE BYTE ...>` — the repetition-count parser doesn't accept the keyword forms yet |
| `GDECL` | 2 | global DECLs; this port skips DECL checking anyway, so likely a no-op registration |
| `VERSION?` | 1 | version-conditional compilation |
| `STATUS-LINE-SECTION` | 1 | |
| SEGMENT splicing inside LIST | 1 | `zillib/scope.zil`; a phase-2 reader/eval gap |
| arithmetic on non-FIX | 2 | `sample/rascal` — probably a real evaluator gap worth a look |
| unassigned atom at eval time | 2 | `INITIAL-PLAYER-MAX-HP`, `ZORK-NUMBER` — forward references across files |

The useful conclusion: `VERSION` + `FILE-FLAGS` + `GDECL` + `VERSION?` are
four small, self-contained registrations and the cheapest next step by a
wide margin. **Read the counts as "what each file hits first", not "files
this would finish"** — the table counts first failures only, so
implementing the top entry mostly moves each file on to whatever it hits
next rather than completing it (see the measured result in the section
below, where implementing all four took the failure count from 40 to 35,
while moving several files substantially further through their source).
The `PACKAGE`/`USE`/`ADD-TELL-TOKENS` cluster is the known
qualified-OBLIST investigation and should stay one task.

## MILESTONE 5: `sample/cloak/cloak.zil` — a real parser game, playable and winnable

**`cloak.zil` compiles, assembles, runs and can be completed.** It is a
full `zillib` game: a parser, a dictionary, syntax tables, objects with
exits, darkness, scoring and an endgame. Playing

    west / put cloak on hook / east / south / read message

prints `****  You have won  ****` and `In 4 turns, you scored 2 points out
of a possible 2.` Movement, room descriptions, the status line, the turn
counter, GWIM (`[the cloak]`), implicit taking, the darkness messages and
the score notification all behave.

This section records what the last stretch needed, because most of it was
*silent* — the story file assembled cleanly and then did nothing.

### Code generation

- **`MAP-DIRECTIONS`**, plus the `LOW-DIRECTION` constant its `DLESS?`
  bound reads. `LOW-DIRECTION` is the smallest property number used by a
  direction; the original takes it from the last atom in the `DIRECTIONS`
  list, which is equivalent because property numbers count down in
  registration order. `DIRECTIONS` now also *replaces* the set rather than
  adding to it, matching `Directions.Clear()`.
- **`LOWCORE`** and **`LOWCORE-TABLE`**, with the header-field table ported
  from `ZModel/LowCoreField.cs`. `LOWCORE` is rewritten into
  `<GET 0 offset>` / `<PUT 0 offset v>` (or the `GETB`/`PUTB` forms) so it
  reaches every path that already knows how to place a `GET`'s result,
  including a destination. The V5+ header-*extension* fields are
  deliberately absent — they need `EXTAB` indirection and a reserved
  minimum extension length, and nothing in the corpus uses them.
- **Inline table constructors** (`<PICK-ONE-R <PLTABLE "a" "b">>`). These
  cannot be evaluated while a routine is being compiled, because tables are
  emitted into static memory *before* any routine body is looked at — a
  table discovered then would get a label and no data. So they are
  evaluated in `PrepareRoutines` and the resulting table is memoized on the
  FORM under a private indicator, which `CompileOperand` reads back.
- **A void-only builtin used as a value** yields TRUE, which is what the
  original does (`CompileVoidCall(...); return Game.One`). The library
  writes `<AND <DIROUT 2> ...>`.
- **`FIRST?`/`NEXT?` used as values** get a branch to the next instruction.
  They are the Z-machine's `get_child`/`get_sibling`, which both store *and*
  branch — the original classes them as `ValuePredCall`, the one builtin
  kind that is both — and the branch offset is part of the encoding, so it
  cannot be omitted.
- **`SanitizeSymbol`**, ported from `Zap/GameBuilder.cs`. ZAP symbols allow
  letters, digits, `?`, `#` and `-`; everything else becomes `$` plus four
  hex digits, and the four punctuation words get readable names
  (`$PERIOD`, `$COMMA`, `$QUOTE`, `$APOSTROPHE`). This is not theoretical:
  zillib defines the one-character words `,` `.` and `"`, `<SYNTAX \,TELL
  ...>` makes `,TELL` a verb, and `MAXWORD/10` is an ordinary constant
  name. A prefixed symbol sanitizes only the part after the prefix, so the
  word `.` becomes `W?$PERIOD` in both the definition and every reference —
  sanitizing `"W?."` whole would give `W?$002e` and never match.
- **The LEXV table format**: a count byte, a zero byte, then word/byte/byte
  triples. Without it the parse buffer declared zero word slots, so every
  command parsed as empty input and the game answered `...` to everything.
- **Direction properties**, from `SDirectionsPropDef_V3` in
  `Context.InitPropDefs`:

  | Written | Bytes | Layout |
  |---|---|---|
  | `(DIR TO R)` / `(DIR R)` | 1 | room |
  | `(DIR SORRY S)` / `(DIR S)` | 2 | string word |
  | `(DIR PER F)` | 3 | routine word, zero byte |
  | `(DIR TO R IF G ["OPT"] ELSE S)` | 4 | room, global, string word |
  | `(DIR TO R IF D IS OPEN ["OPT"] ELSE S)` | 5 | room, door, string word, zero |

  The **length** is what identifies the kind at run time: `V-WALK` switches
  on `<PTSIZE .PT>` against `UEXIT`/`NEXIT`/`FEXIT`/`CEXIT`/`DEXIT`, which
  are exactly 1..5 in V3. A `CEXIT`'s condition byte is a *global's variable
  number*, which is what the `.GVAR`-defined symbol evaluates to;
  `ConstantText` does not look globals up (a global is normally reached as
  `,NAME`), so that case checks `FindGlobalIdx` directly. V3 layout only —
  V4+ widens object numbers to words.

### Interpreter

- **The `PRE-COMPILE` hook.** zillib's `ADD-FINISHER` chains onto a global
  in the `HOOKS` package which the compiler calls by name before compiling;
  that is what builds `ACHIEVEMENTS` and `ACHIEVEMENT-COUNT`. This port has
  one flat oblist in which a qualified name interns under its full
  `NAME!-OBLIST!-OBLIST` spelling, so the lookup is literally the atom the
  library writes.
- **`SORT`** (insertion sort, stable; the predicate is asked only "is A
  greater than B?", which is all a stable insertion sort needs).
- **`ZVAL`** on routines, objects, globals and constants. The library tests
  it: it refuses to build the achievements table unless `MAX-SCORE` has
  one. The atom itself is stored, because existence is all that is tested
  and a constant whose value is `0` must still read as defined.
- **`TYPE?`/`CHTYPE` special cases for `LVAL` and `GVAL`.** `.X` reads as
  the FORM `<LVAL X>`; `TYPE` still calls it a FORM, but `TYPE?` also
  answers `LVAL`, and `CHTYPE` converts between such a form and a bare
  atom. The original marks these "hacky special cases"; they are
  load-bearing. zillib's library-message substitution finds the
  placeholders in a template with `<TYPE? .STRUC LVAL>` and reads the name
  out with `<CHTYPE .STRUC ATOM>`, so without them every message's `.OBJ`
  / `.WHOM` / `.POINTS` survived into the generated code as a reference to
  a local the calling routine does not have — 14 undefined symbols at
  assembly time.
- **`#DECL` is inert.** A DECL self-evaluates in the original because its
  *type* is DECL rather than LIST. Dropping the type tag the way every
  other `#TYPE` is dropped left an ordinary LIST, which a `DEFINE` body
  then evaluates element by element — harmless by luck for
  `((HANDLER) APPLICABLE)`, fatal for `(<OR !<LIST ATOM ANY> FALSE>)`.
  Reading it as `<QUOTE (...)>` gives the self-evaluating behaviour with no
  type system, and the value is discarded everywhere a decl can appear.
- **A macro's SPLICE result splices into an enclosing form's arguments**,
  not only into a routine body. `<CONSTANT TRY-REPHRASING-CMD
  <LIBRARY-MESSAGE ORPHANING TRY-REPHRASING>>` is a STRING constant only
  because the message's one-element SPLICE collapses into `CONSTANT`'s
  second argument.
- **VECTORs evaluate their elements**, as LISTs do. `<SETG NEW-SFLAGS
  ["TOUCH" (+ ,SF-TOUCH) ...]>` depends on it. Note that the `+` marking an
  additive flag then arrives as the addition SUBR rather than as the atom,
  because a bare atom evaluates to its global value; both spellings are
  accepted.
- **A DEFSTRUCT over a TABLE writes through the field's own accessor
  width.** A table's elements are not all one width, so a byte offset is
  not an element index and neither is a word index. `PARSER-RESULT` is
  `<ITABLE 26 (BYTE)>` with `ZGET`/`ZPUT` (word) fields, so `PST-PRSOS`
  (word 4) landed in byte slot 4 — the assembler only *warned* that a table
  address will not fit in a byte, and the parser then read nonsense.
  Writing a word into two adjacent byte slots now merges them into one
  word element.

### Parser data

- **The part-of-speech First flags.** They are the low two bits of a word's
  data byte, and they are what tells the library which of the two value
  bytes to read: `CHKWORD?` takes `VOCAB-V1` when `<BAND flags 3>` matches
  the part of speech's `P1?` constant and `VOCAB-V2` otherwise. Leaving
  them clear is quiet and total — every verb's number reads as 0, so the
  parser recognises every word and then does nothing with any command.
  Ported from `OldParserWord.ShouldSetFirst`: set only when the word has no
  value-recording part of speech yet, and never on a buzzword.
- **`NEW-SFLAGS`.** A library may redefine what the scope-flag names in a
  `SYNTAX` line mean. zillib does, because it has always treated
  `ON-GROUND`/`IN-ROOM` alike and `CARRIED`/`HELD` alike, so it reuses the
  freed bits for `EVERYWHERE` and `TOUCH`. Its `SEARCH-ALL` is **24**, not
  the built-in default **240**. The first non-additive option clears the
  defaults; `HAVE`, `TAKE`, `MANY` and anything written `(+ n)` are
  additive.

### The two codegen bugs that made it *look* like a parser problem

1. **A `DO` loop whose end is `.X` or `,X` was treated as a predicate**,
   because `.X` reads as a FORM. The original tests
   `end.IsNonVariableForm()` for exactly this reason. `<DO (I 0 .LEN) ...>`
   compiled to "branch out of the loop while LEN is true", so the body ran
   zero times or forever — and zillib's `COPY-TABLE` is written exactly
   that way. The parser copies each command into its EDIT buffers and then
   switches `LEXBUF` to them *before* scanning the words, so every command
   arrived empty and the game said `I don't know the word ""`. A FORM
   *step* likewise computes the counter's next value and is stored, not
   added.

2. **A comparison's first comparand was compiled twice.** `CompileCondition`
   pre-compiled the right operand for `FixStackedPair` and then the
   `EQUAL?` group loop compiled every comparand again from the start, so
   `<==? .I <+ ,P-P1-WN 1>>` emitted its `ADD ... >STACK` twice and leaked
   a stack entry on every evaluation. Only `L?`/`G?` need the pre-compiled
   pair now; the `EQUAL?` path counts the comparands and spills the left
   operand off the stack when any of them emits anything or when there is
   more than one group.

### Tooling: reading what a story file actually prints

`frotz` drives a real screen — cursor positioning, line deletion, scroll
regions — so piping it to a file interleaves escape codes with the game's
text and the transcript is unreadable. Several of the fixes above were
invisible for that reason: markers were printing and could not be seen.
`ansiscreen.py` in the scratchpad replays such a stream onto a grid and,
with `--scroll`, keeps the lines that scrolled off, which gives a clean
transcript:

    printf 'west\nput cloak on hook\n' | timeout 30 frotz -p cloak.z3 2>&1 \
        | python3 ansiscreen.py --scroll

`examples/zmachine.mod` is also a usable second channel — it runs `cloak`
fine (it is `beer.z3`, with its volume of output, that it hangs on), and
its output needs much less untangling.

The other technique that paid for itself: **copy `zillib` into the
scratchpad and patch `<TELL "[dbg ...]">` markers into it**, then compile
the game against the copy. Every remaining bug was found that way in a
couple of iterations, after a long stretch of reading generated `.zap` by
eye.

### Where `cloak` still differs from the original's output

- `<TYPE? <GETPROP .R ZVAL> ROUTINE>` in `pronouns.zil`'s
  `PRONOUN-PROPSPEC` needs the stored ZVAL to have type ROUTINE. This port
  stores the atom, so that helper would reject every pronoun. It only runs
  for an object with a `PRONOUN` property, which no game compiled so far
  has.
- Compiling with `<COMPILATION-FLAG DEBUG T>` fails in `BYTE/WORD: expected
  a FIX` — the debugging verbs build tables this port's `BYTE`/`WORD`
  doesn't accept yet. Not needed for a release build.
- `V4+` direction properties (object numbers widen to words) are not
  emitted.

## MILESTONE 6: `sample/advent/advent.zil` — Colossal Cave Adventure, playable

**`advent.zil` compiles, assembles, runs and is genuinely playable.**
Movement, taking/dropping/holding objects, INVENTORY, SCORE, darkness and
the lamp, and out-of-scope object handling ("You don't see that here.")
all behave correctly under frotz. This is the largest and most demanding
game in the corpus so far — a real port of the original 1977 Adventure,
not a small demo — and it needed both a chain of missing pieces to reach a
clean compile and, separately, three *runtime* bugs that a clean compile
and a clean assemble gave no hint of.

### The new tool that made the runtime half tractable

**A real build of zilf's own C# compiler is available locally**
(`~/lib/src/zilf`, `dotnet build src/Zilf/Zilf.csproj -c Release`, then
`dotnet bin/Release/net10.0/zilf.dll build -q -I zillib -I <gamedir> -S
game.zil game.zap`). When a compiled game misbehaves and the cause isn't
obvious from reading ZIL source, **compile the same game with the real
zilf and diff the two `.zap` outputs** (or, for a specific symbol, grep
both for it). This is categorically faster than reasoning about MDL
semantics from documentation and comments: it was how the `ITABLE`
length-prefix bug below was found and confirmed, in minutes, after a long
unproductive stretch of hand-tracing scope-crawl arithmetic. Real zilf's
data tables land in a separate `*_data.zap` file (its own choice, not this
port's); the routine bodies are in the main output. See
[[project_zilf_port]] for where the checkout and build live.

### Getting it to compile

- `BIT-SYNONYM` (a flag alias sharing another flag's bit — V3 only has 32).
- `=?` vs `==?`: MDL distinguishes STRUCTURAL equality from EXACT identity;
  this port had conflated them into one exact test, which rejected every
  achievement flag in zillib's SCORING-ACHIEVEMENTS (`'REPEATABLE` built
  fresh each call is `=?` but not `==?` to another fresh `'REPEATABLE`).
- The general `PROPSPEC` object-property hook (`ApplyPropSpecs`, run before
  anything else compiles, since a PROPSPEC may itself define routines and
  tables — zillib's THINGS-PROPSPEC and PRONOUN-PROPSPEC both do).
- `PUT`, `ZGET`/`ZPUT`/`GETB`/`PUTB`, `UNPARSE`, `0?`/`1?` at the
  interpreter level — needed because compile-time finisher/PROPSPEC code
  calls them directly, not just Z-machine-runtime compiled code.
- A ROUTINE's ZVAL is now a value of type ROUTINE, not the bare atom, so
  pronouns.zil's `<TYPE? <GETPROP .R ZVAL> ROUTINE>` finally works.
- `<SYNTAX ... = action preaction NAME>`: the optional third value after
  `=`, an explicit action-constant name overriding the one derived from the
  routine (advent shares `V-POUR-LIQUID` between WATER and POUR, and wants
  `V?WATER` on the WATER line specifically).
- The reader no longer auto-splices a `#SPLICE` literal into whatever
  structure it's read into (a cloak-milestone addition that turned out to
  be wrong — see the plan doc's own postmortem in the commit message).
  Splicing now happens only at genuine consumption points: quasiquote
  splicing works on VECTOR templates as well as LIST/FORM now, and a new
  `FlattenSpliceMembers` flattens one level of SPLICE members out of every
  object property's value list, in `ApplyPropSpecs`.
- Direction properties and location (`IN`/`LOC`) properties, told apart by
  the property's BODY SHAPE now (not by name — `IN` is both a zillib
  direction and the pseudo-property naming an object's parent), and a
  `GLOBAL` property packs one byte per object on V3 (object numbers fit in
  a byte there), not a word — needed since some of advent's rooms have five
  `GLOBAL` objects, over V3's 8-byte property limit at word width.
- `AddRoutine` replaces an existing definition instead of emitting two
  `.FUNCT`s under the same name — advent overrides `V-QUIT`/`V-THINK-ABOUT`
  inside `<BIND ((REDEFINE T)) ...>`.
- Several error messages now name the actual symbol or form involved
  (`"calling unassigned atom: PUT in <PUT .A 4 T>"`, not a bare
  `"unrecognized SUBR"`) — worth doing on sight whenever a message doesn't
  already say enough to `grep` the source with.

### Getting it to behave: three runtime bugs, invisible until played

1. **Named `PROG`/`REPEAT`/`BIND` blocks.** `<PROG NAME (...) ...>`'s
   activation atom was parsed and discarded; `<AGAIN .NAME>` /
   `<RETURN val .NAME>` always targeted the innermost block. `MATCH-NOUN-
   PHRASE`'s `<PROG BITS-SET () ...>` needs `<AGAIN .BITS-SET>` to work from
   inside a nested *unnamed* `REPEAT` that `MAP-SCOPE`'s own macro expansion
   introduces — defaulting to "innermost" restarted the wrong loop
   entirely. A ROUTINE's own optional activation atom needs the identical
   targeting one level further out (`<RETURN val .MSN>` inside `MAP-SCOPE-
   NEXT` means "leave the routine"), checked as a special case first since
   a routine is never itself pushed as a numbered block.
2. **`<ITABLE WORD n>` / `<ITABLE BYTE n>` allocated `n` elements; they
   need `n + 1`.** The specifier atom doesn't set the element width — it
   requests an automatic LENGTH PREFIX (one extra word/byte, pre-filled
   with `n`), exactly like the already-correct `TfLength` flag `LTABLE`/
   `PLTABLE` use. zillib's `SCOPE-CURRENT-STAGES` is `<ITABLE WORD
   ,SIZE>`: `SIZE` routine references plus a leading count word the
   scope-crawl machinery reads and writes directly. Sized one word short,
   the library's own bookkeeping — which deliberately writes the *full
   declared* `SIZE` into slot 0 even when fewer stages are active, relying
   on the unused trailing slots being the ITABLE's own zero-fill — walks
   one slot past the table's end into whatever follows it in the story
   file, and can end up calling whatever packed-address-shaped garbage is
   sitting there: `Call to non-routine`, reachable the moment a player
   tries to take or examine anything not in the current room (which widens
   scope through every stage in turn). Confirmed character-for-character
   against the real compiler: `SCOPE-CURRENT-STAGES:: .TABLE 16` — 16
   bytes, 8 words, one more than the 7-element count.
3. **A word's part-of-speech "First" flag, once set, was never cleared.**
   `AddVocab` set `VerbFirst` (or `AdjectiveFirst`/`DirectionFirst`) the
   first time a word gained any value-recording part of speech, but a
   `PREPOSITION` or `BUZZWORD` registered on the word LATER always wins the
   first value slot regardless, by the original's own fixed priority order
   (already correctly ported into `EmitVocabTable`) — so the flag byte has
   to agree with whichever part actually ends up first, and the original's
   `SetPreposition`/`SetBuzzword` unconditionally clear the First bits on
   their own first registration for exactly this reason. `AddVocab` didn't.
   `INVENTORY` is both a verb and a preposition in advent's grammar: left
   flagged `VerbFirst` from its earlier verb registration, `CHKWORD?`'s "is
   this a verb?" query silently read the *preposition's* value out of the
   wrong slot, and the parser failed to recognise "inventory" (and "score")
   as verbs at all — with no error, no crash, just `I don't understand
   that sentence.`

**None of these three were visible in the compiled `.zap` or in whether it
assembled.** All three were found the same way: play the game, hit the
wrong behavior, then diff against a real zilf build once the shape of the
problem (a table walked past its declared end; a word that silently
doesn't parse as a verb) pointed at a specific mechanism.

### Two more bugs, found by playing it *harder*

Calling `advent.zil` "playable" after the three bugs above was premature —
the user tried single-letter command abbreviations (`i`, `x`, `n`/`s`/`e`/
`w`, etc.) and got "I don't understand that sentence", and pointed out
`zilf`'s own `vocab collision` warnings as possibly relevant. Both turned
out to be real, and related to each other only in that both are about
`SYNONYM`/`VERB-SYNONYM`/etc. never having been wired up at all:

4. **`SYNONYM` and its four variants (`VERB-`, `PREP-`, `ADJ-`, `DIR-`)
   were recorded and never read.** `ZilEval.ApplySubr` filed every
   `<SYNONYM ORIGINAL alias...>` into `ZilModel.synonyms[]` and stopped —
   nothing in `ZilCompile.mod` ever consumed the list, so declaring a
   synonym had zero effect on the compiled game. zillib's own library
   defines every single-letter shortcut this way (`<SYNONYM NORTH N>`,
   `<VERB-SYNONYM INVENTORY I>`, `<VERB-SYNONYM EXAMINE X>`, ...), so none
   of them worked, in *any* game compiled by this port, not just advent.
   Fixed by a new `ApplyVocabSynonyms` (`ZilCompile.mod`), run after
   `CompileSyntax` has assigned every original word's verb/preposition
   numbers, which copies the original's vocab data onto the synonym word
   via the same `MergeVocabWord` the vocab-collision merge below also
   uses.
5. **V3's 6-Z-character dictionary key genuinely can't tell some of
   advent's words apart, and the resulting duplicate rows were never
   merged.** `BOULDER`/`BOULDERS`, `BOTTLE`/`BOTTLED`,
   `STALAGMITE`/`STALAGTITE` and 18 others in advent all truncate to an
   identical dictionary key; a runtime binary search on that key can land
   on either row, so if the two rows' part-of-speech data differs (as
   `BOTTLE`/`BOTTLED`'s does — one is an adjective, one isn't), the lookup
   silently gets the wrong one's data. `zapf`'s own dictionary
   sort/compare (`VocabCompare`/`VocabCompareSaved`) compared whole
   records instead of just the key bytes, which both risked an
   out-of-order dictionary and drastically under-reported the collision
   warning (6 of the real 21 pairs) — fixed to compare only
   `ctx.vocabKeySize` bytes. But fixing detection wasn't enough on its
   own: confirmed by a head-to-head `frotz` comparison against a fully
   real-compiled `advent.z3` that "examine bottled water" still failed
   after that fix alone, because the two dictionary rows were still
   emitted separately with different data — nothing actually merged them.
   Ported the original's `PlanVocabMerges`/`PerformVocabMerges` as
   `ApplyVocabMerges` (`ZilCompile.mod`): sorts vocab words alphabetically,
   groups adjacent entries whose Z-char-encoded key matches (reusing
   `ZapfZChar.Encode`, the same routine `zapf` itself uses, so this can
   never disagree with what gets assembled), and folds every non-first
   member of a group into the alphabetically-first survivor. A merged
   word gets no `.ZWORD` row of its own; its `W?` symbol becomes a bare
   alias (`W?dup=W?survivor`) emitted after `.ENDT`. Runs *before*
   `ApplyVocabSynonyms`, matching the original's own ordering, which
   turned up one more wrinkle: a collision that only exists between two
   *synonym* words (advent's `LUBRICANT`/`LUBRICATE`, both synonyms of
   `OIL`) was invisible to it, because this port used to create a synonym
   word's vocab entry only inside `ApplyVocabSynonyms` itself — too late
   for the merge pass to see it. Fixed by having `ZilModel.AddSynonym`
   register that vocab entry immediately, matching the real compiler's own
   timing (it creates the `IWord` as soon as the `SYNONYM` form is
   evaluated, not when `Apply()` later copies data onto it).

   Verified: warning count and wording now match a real zilf+zapf build of
   advent.zil exactly (21 collisions). "examine bottled water" now answers
   "It looks like ordinary water to me." Single-letter abbreviations
   (`i`, `x`, `n`, `s`, `e`, `w`, ...) all parse correctly. Full sample
   regression (`advent`, `beer`, `cloak`, `hello`, `mandelbrot`, `name`)
   still compiles, assembles and plays clean; `cloak` still wins.

## MILESTONE 7: `sample/zork1` — a real interpreter bug, not just missing features

Started on the full, unmodified Zork I source (`zork1.zil` plus its nine
`INSERT-FILE`d parts — `1dungeon.zil`, `1actions.zil`, `gclock.zil`,
`gglobals.zil`, `gmacros.zil`, `gmain.zil`, `gparser.zil`, `gsyntax.zil`,
`gverbs.zil` — 20k+ lines total, by far the largest source tried yet).
The very first attempt didn't fail — it **hung**, RSS climbing into the
gigabytes with no output, which is a different and more serious class of
problem than the missing-builtin errors every previous milestone hit.

**Bisection method, since there was no error message to start from**:
confirmed via `ps`/RSS sampling that CPU was pinned but the process was
never going to finish (not just "slow"); killed it; then found the smallest
failing input by truncating `zork1.zil`'s own `INSERT-FILE` chain one file
at a time (fast — hits `CompileProgram: entry routine not defined`, since
none of those partial programs define an entry routine), then, once
`1dungeon.zil` alone was implicated, truncating it at successive top-level
form boundaries (a small Python script tracking `<`/`(`/`"` nesting depth
to find safe split points) with **a trivial stand-in `<ROUTINE GO ()
<RTRUE>>` appended** so the partial program *would* reach the entry check
and hang or not — the earlier bisection attempts without this trick were
worthless false negatives, since every truncated prefix failed the SAME
"entry routine not defined" check before ever reaching the code that
actually hangs. That narrowed it to a single routine, then to a single
statement: `<COND (<VERB? OPEN> ...))>`, then to a **7-line, fully
self-contained repro with no zork1/zillib code at all**:

```
<DEFINE FOO (ATMS "AUX" (L ()))
  <REPEAT ()
    <COND (<EMPTY? .ATMS> <RETURN!- 999>)>
    ...
```

**Root cause**: `PROG`/`REPEAT`/`BIND`'s body-evaluation loop
(`ZilEval.mod`) only checked `EvalImpl`'s `outcome` field to decide whether
to keep looping, never the separate `evalErrFlag` global this port reports
evaluation errors through (`Err` returns an *ordinary* `OValue` of `FALSE`
— see its own comment — specifically so a caller that forgets to check the
flag fails soon after on the bad value instead of nowhere). Every other
similar loop in the file (e.g. `INSERT-FILE`'s own read/eval loop) already
had this check; `PROG`/`REPEAT`/`BIND` never did. A `REPEAT` whose body
errors on *every* pass, rather than eventually succeeding or hitting a real
`RETURN`, therefore never stopped — `RETURN!-` (see below) was
permanently unassigned, so zork1's `gmacros.zil` `MULTIFROB` (the
compile-time helper behind the `VERB?`/`PRSO?`/`PRSI?`/`ROOM?` DEFMACs,
used constantly throughout zork1) walked its argument list down to empty
and then called the same failing statement forever. This is the most
significant bug found in this whole port so far: not a missing feature,
but the interpreter's own error handling failing to stop a loop. Fixed by
adding the missing `evalErrFlag` check (two call sites: the body loop and
the bindings-initializer loop).

Two more real gaps surfaced once the loop actually stopped erroring
instead of hanging:

- **`RETURN!-`** (and any `NAME!-` with nothing after the `-`) is MDL's
  spelling for "NAME, looked up in the ROOT oblist specifically" —
  confirmed against the real compiler's own `ZilAtom.Parse` (`idx ==
  text.Length - 2` case). This port's reader already preserves `!-`
  literally in an atom's raw text, matching the real reader's `Parser.cs`
  exactly — the gap was in `ZilObj.Intern`, the one place every atom
  actually gets interned, which had no equivalent normalization and so
  treated `RETURN!-` as a permanently distinct, forever-unassigned atom
  instead of the same `RETURN` already registered as a builtin.
- **`PUTREST`** (destructively replace a list's own tail pointer, returning
  the mutated list) was simply never ported. `MULTIFROB` uses it for the
  classic MDL "build a list by mutation, walking a saved tail pointer"
  idiom.

Once `RETURN!-`/`PUTREST` worked, the compile got much further and hit a
run of smaller, ordinary missing-feature gaps in quick succession (each
found by just re-running the full 20k-line compile and fixing whatever it
stopped on next — no more bisection needed once the hang itself was gone):

- **`ApplyDefine`'s macro-call argument binder only recognized `"OPT"`/
  `"AUX"`**, not their full-word synonyms `"OPTIONAL"`/`"EXTRA"` (real
  zilf's `ArgSpec.cs` treats all four identically; this port's OWN
  ROUTINE-argspec parser, a separate piece of code, already had both
  pairs). `gmacros.zil`'s `PROB` macro is declared `('BASE? "OPTIONAL"
  'LOSER?)`.
- **A bare atom naming a GLOBAL whose value is itself a table** (`<GLOBAL
  DEF1-RES <TABLE DEF1 0 0>>`, where `DEF1` — no comma — means "the
  address of DEF1's own table") wasn't resolved as a compilable constant;
  only a table VALUE reached directly was.
- **`#DECL (...)` used as a plain STATEMENT** (rather than a value)
  wasn't handled. The reader turns `#DECL (...)` into a literal `<QUOTE
  (...)>` FORM on purpose, so it self-evaluates correctly in value
  position (see `ZilRead`'s own comment) — but `gclock.zil`'s `QUEUE`
  opens with a bare `#DECL (...)` statement, and this port has no DECL
  checking to feed it to (a documented simplification), so a `QUOTE` in
  statement position now just compiles to nothing.
- **`RSTACK`** (pop the value stack and return it; zap mnemonic
  `ret_popped`, already fully known to `ZapfOpcodes`) had no `CompileStmt`
  case and wasn't in `IsStatementBuiltin`. `gmacros.zil`'s `RFATAL` DEFMAC
  expands to `<PROG () <PUSH 2> <RSTACK>>`, used throughout zork1
  whenever a command fatally fails to parse.

Progress checkpoint: zork1.zil now compiles all the way through
`GMACROS`/`GSYNTAX`/`1DUNGEON`/`GGLOBALS`/`GCLOCK`/`GMAIN`/`GPARSER`/
`GVERBS` and is currently stopped inside `1ACTIONS` on the next item in
this doc's own **Known gaps** list below: `PSEUDO` object properties
(`GLOBAL-CHECK` in `1actions.zil` reads a room's `PSEUDO` property table
directly).

### Finishing it: PSEUDO, GLOBAL redefinition, and a real parser bug

Four more fixes, in the same session, got `zork1.zil` all the way to
**genuinely playable**:

- **`PSEUDO` object properties** (`(PSEUDO "WORD" ACTION-ROUTINE ...)`,
  scenery words that only exist so a room can react to them — zork1's
  rooms are full of these: `NAILS`, `CHASM`, `DOOR`, `GATE`, `GAS`...).
  Ported the original's `Compilation.Objects.cs` handling exactly: each
  STRING element registers as a vocabulary NOUN the same way a SYNONYM
  atom does, and the property emits one WORD per element regardless of
  shape (a word's dictionary address, or a routine's address). Also
  resolves `LOW-DIRECTION` (an assembler symbol the real compiler always
  writes — the smallest property number used by any direction — that
  this port's `ConstantText` had no case for, even though `EmitObjectTable`
  was already emitting the symbol itself; `OTHER-SIDE`/`GLOBAL-CHECK`
  read it directly via `,LOW-DIRECTION`).
- **`GLOBAL` redefinition.** `zork1.zil` genuinely declares `WON-FLAG`
  and `LUCKY` as `GLOBAL` twice (once in `1dungeon.zil`/`1actions.zil`,
  again in `gverbs.zil`) under its own `<SET REDEFINE T>` — legitimate,
  real-zilf-tolerated ZIL, not a bug in the game. This port's `AddGlobal`
  always appended a new entry rather than checking for an existing one
  under the same name, so both survived into the `.zap` as two `.GVAR`s
  of the same name, and `zapf`'s own duplicate-symbol check ("global
  redefined") caught what registration should have. Fixed the same way
  `AddRoutine` already handles `ROUTINE` redefinition: update in place.
- **The real bug, found only by actually playing the compiled game**:
  every ordinary object noun ("open mailbox", "read leaflet", "take
  lamp"...) failed with "There seems to be a noun missing in that
  sentence!", despite the words being correctly registered with the
  OBJECT part-of-speech bit set. zork1's own `gparser.zil` (unlike
  zillib's `parser.zil`, which only ever checks a word's part-of-speech
  BIT and never reads its VALUE for a plain noun) has a `WT?` routine
  whose return value — the dictionary word's own V1/V2 byte — its caller
  uses directly as a boolean. This port's vocabulary emission had no
  value at all for the OBJECT part of speech (`PartValue`'s dispatch fell
  through to its final `RETURN 0`), so every noun-only word's value byte
  was 0 — FALSE — and `WT?` reported every single one of them as "not an
  object". Confirmed byte-for-byte against a real zilf+zapf build:
  `MAILBOX`'s compiled dictionary flags/value bytes were `[128, 0, 0]` in
  this port versus the real compiler's `[128, 1, 0]`. Real zilf's own
  `OldParserWord.SetObject` sets exactly this — `speechValues[PartOfSpeech
  .Object] = 1`, a fixed sentinel never read as a number anywhere, only
  as a non-zero truth value — so `PartValue` now returns `1` for
  `PsObject`, matching it.

**Verified by playing well into the game**: the mailbox/leaflet opening
sequence and welcome message, entering the house through the kitchen
window, taking and lighting the brass lantern, moving the rug and opening
the trap door, descending into the cellar (the trap door slamming shut
and being barred behind the player, exactly as the real game does), the
`SCORE` command ("Your score is 35 (total of 350 points)... rank of
Amateur Adventurer"), the troll fight (the sword's glow-when-danger-
nearby mechanic, and a real randomized combat resolution ending in "The
troll takes a fatal blow and slumps to the floor dead."). Full sample
regression (`advent`, `beer`, `cloak`, `hello`, `mandelbrot`, `name`,
**`zork1`**) all compile/assemble clean; `cloak` still wins, `advent`'s
abbreviations and "examine bottled water" still work.

## Suggested order for the next session

**Where this stands**: six complete, unmodified games compile, assemble
and run — `sample/beer` (V3), `sample/mandelbrot` (V4, ASCII art),
`sample/name` (V3, interactive), `sample/cloak` (V3, a full `zillib` parser
game, playable and winnable), **`sample/advent` (V3, Colossal Cave
Adventure, playable)** and **`sample/zork1` (V3, the real, unmodified
1980s Zork I — its own custom parser, not zillib's — playable well into
the game: house, lamp, trap door, combat, scoring; see MILESTONE 7
above)**. The pipeline:

```
./obc -I Modules/ examples/zilf.mod -o zilf
./zilf -q -i ~/lib/src/zilf/zillib -i <gamedir> game.zil > game.zap
./zapf game.zap && frotz -p game.z3 | python3 ansiscreen.py --scroll
```

To compare against the real compiler on a specific point:

```
cd ~/lib/src/zilf && dotnet build src/Zilf/Zilf.csproj -c Release
dotnet bin/Release/net10.0/zilf.dll build -q -I zillib -I <gamedir> \
    -S game.zil real_game.zap   # data tables land in real_game_data.zap
```

1. **Re-run the checks** first: the eighteen end-to-end programs in the
   scratchpad, the five games, and the transpiler's own suite (171 files,
   3 pre-existing failures: `ClojBio`, `ClojStats`, `Editor`). *Run*
   `loop`, `temps`, `regress`, `andor` and `tell` and read their output, not
   just their exit code — several of this session's worst bugs assembled
   clean and only showed up in what the program actually printed or did.

2. **`sample/zork1` is done (playable)** — next up is something smaller
   like `sample/cloak_plus`/`cloak_test`/`cloak_glk`, or push zork1
   itself further (it hasn't been played to a WIN, only well into the
   early game — the thief, the maze, and the full treasure/trophy-case
   scoring loop are all unexplored). Expect the same two-phase shape any
   new game brings: a short chain of missing builtins to compile, then a
   shorter but much less obvious chain of runtime-only bugs to behave —
   and reach for the real-zilf diff the moment a symptom (wrong value,
   crash, silently unrecognised command) doesn't point at an obvious
   cause in the ZIL source itself.

3. **Known gaps, in rough order of how likely a game is to hit them**:
   - V4+ direction properties (object numbers widen to words)
   - `PSEUDO` object properties — **done, see MILESTONE 7**
   - `<COMPILATION-FLAG DEBUG T>` builds fail in `BYTE/WORD: expected a
     FIX`; the debugging verbs build tables `BYTE`/`WORD` doesn't accept
   - `SORT` with extra vectors to rearrange in step
   - V5+ header-extension `LOWCORE` fields (`EXTAB` indirection)
   - `ZIP-OPTIONS`, `FREQUENT-WORDS?`, `SUPPRESS-WARNINGS?`, remaining
     `ITABLE` keyword shapes, an `"OPT"` argument with a non-constant
     default, a V5+ hand-built header
   - the `ITABLE`/`AddVocab` fixes above were found by NEED, not by
     survey — there may well be other MDL semantics this port has subtly
     wrong that no game exercised yet; the real-zilf diff is the fastest
     way to find out once one is suspected

**Testing discipline that has caught everything so far**: compile →
assemble with `zapf` → actually run the story file → **read the real
printed output through `ansiscreen.py`**. Never trust that the `.zap` text
looks right, and never trust that it assembles cleanly either — this
session's three runtime bugs all did. When a compiled game misbehaves,
check it under both interpreters before assuming the compiler is at
fault; when *that* doesn't explain it, copy `zillib` into the scratchpad
and patch `<TELL "[dbg ...]">` markers into the routine you suspect, or —
new this session — diff against a real local build of zilf itself.

**Diagnostics go to stderr now** (`Out.ErrString`/`ErrLn`/`ErrInt`/
`ErrChar`, added this session). `zilf ... > game.zap` no longer risks
putting an error message inside the file that a later `wc -l`/`zapf` call
then treats as "compiled fine, produced *some* output" — check `$?` and
stderr, not just whether the output file has content.

**And when an error message names something that makes no sense**, suspect
a *later* error masking the real one. That is why `Err` now keeps the first
message — see the diagnostics note in the DEFSTRUCT milestone above.
