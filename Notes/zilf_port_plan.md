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

## Suggested order for the next session

1. Re-run the checks this session established, which are quicker and
   broader than the old per-phase harnesses: build the driver
   (`obc --mod-path Modules examples/zilf.mod -o zilf`), run it over all
   52 corpus files under `~/lib/src/zilf/zillib/` and
   `~/lib/src/zilf/sample/*/` expecting zero *parse* failures, and re-run
   the two end-to-end programs described in the globals section above
   (compile → `zapf` → `zmachine.mod`, checking the printed values). Also
   re-run the transpiler's own full `Modules/*.mod`+`examples/*.mod`
   regression suite (138 files, 3 pre-existing failures).
2. **A library/include search path** — five corpus files, including every
   real game, stop at `INSERT-FILE "parser"`, because this port resolves an
   INSERT-FILE only against the including file's own directory and the
   library lives in `zillib/`. The original has a configurable include-path
   list; `ZilEval.SetCurrentDir`'s own comment already notes this port
   dropped it only because there was no CLI to configure it from — and now
   there is (`examples/zilf.mod`). Small, and on the critical path for
   compiling any real game.
3. Then the remaining phase-3b codegen widenings, roughly in value order:
   a. **`AND`/`OR` and the loop constructs**: read `Compilation.Loops.cs`
      (896 lines, still not read). `COND`'s condition fallback already
      handles a bare value tested for truthiness, but `AND`/`OR`'s
      short-circuit *sequencing* and the compiled `REPEAT`/`AGAIN` forms
      (not to be confused with this port's interpreter-level `PROG`/
      `REPEAT` from phase 2b — completely different code) don't exist in
      the compiler at all.
   b. **Object/property/flag table emission**: read
      `Compilation.Objects.cs` (762 lines, not yet read). `ZilCompile`
      currently emits a well-formed but *empty* V3 object table (31 words
      of property defaults, no entries) purely so the header's `OBJECT`
      pointer is valid. Needed before `MOVE`/`FSET?`/`GETP`/`IN?` mean
      anything, and before a compiled game can do more than arithmetic,
      conditionals and printing.
   c. **Strings**: `TELL` and packed string tables (`.GSTR`/`.STR`), so a
      string can be an operand rather than only a `PRINTI` literal.
   d. **Vocabulary/syntax tables**: `Compilation.Syntax.cs`. Same
      placeholder situation as objects — an empty but well-formed
      dictionary is emitted today.
   e. More `ZBuiltins.cs` builtins on demand, same methodology as always,
      each tested compile → `zapf` → run → check the actual result.
4. The `PACKAGE`/`USE`/`ADD-TELL-TOKENS`/qualified-OBLIST cluster remains
   its own self-contained investigation (see phase 3a's own section for
   what's already known) — 11 corpus files are blocked on it, so it has to
   happen eventually, but it is not a quick slice and shouldn't be
   attempted as one.
5. Update this doc's "what's done" section and commit again.
