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

## What phase 2 needs to cover (Interpreter core)

Read `Zilf/Interpreter/*.cs` (not just `Values/`) in full before starting.
At minimum, phase 2 needs:

1. **`Context`** (the ZIL interpreter's global state — distinct from, but
   analogous in spirit to, zapf's `ZapfAsm.Context`): global value table
   (`GVAL`), local/lexical value table (`LVAL`) with environment chaining
   for `PROG`/routine-call scoping, the `OBLIST` special variable, property
   lists (`PUTPROP`/`GETPROP`, used heavily for e.g. object flags),
   `StdAtom` well-known-atom table (the original's `StdAtom.cs`, 374 lines
   — an enum of every special atom the interpreter/compiler hard-codes
   checks against, e.g. `GVAL`, `LVAL`, `QUOTE`, `ELSE`, `FLAGS`, `DESC`
   — port this incrementally, adding entries as builtins need them rather
   than all 374 up front).
   **Update (confirmed this session, after the plan above was written):**
   found them. They're partial-class files directly in `Zilf/Interpreter/`
   (not a subdirectory): `Subrs.cs` (104, the dispatch table itself) +
   `Subrs.{Atoms,Conditionals,DefStruct,Functions,Loops,Map,Math,Meta,
   Output,Packages,Structures,Types,ZModel}.cs` = **7,272 lines total**,
   biggest being `Subrs.ZModel.cs` (1,672 — object/room/table builtins
   evaluated at *interpret* time, not to be confused with the *compiler's*
   `Compiler/Builtins`), `Subrs.DefStruct.cs` (920), `Subrs.Meta.cs` (710),
   `Subrs.Atoms.cs` (685), `Subrs.Structures.cs` (640). The remaining core
   infra (everything else directly in `Zilf/Interpreter/`, non-`Subrs`,
   non-`Values`) is **5,193 lines**, dominated by `Context.cs` (1,457,
   **the** file to read first for phase 2 — global/local value storage,
   OBLIST, property lists all likely live here) and `ArgSpec.cs` (970 —
   the SUBR/FSUBR argument-list declaration & checking mini-DSL, e.g. how
   a builtin declares "1 required FIX, up to 3 optional ATOMs"). Also
   present and worth reading early: `ZilResult.cs` (225 — confirms the
   "explicit signal value, no exceptions" design guessed above),
   `LocalEnvironment.cs` (173), `ObList.cs` (145, the *real* package
   hierarchy this port's `ZilObj.Intern` currently flattens away),
   `IStructure.cs`/`StructureExtensions.cs` (115+233 — the generic
   sequence-operation interface `ZilString`/`ZilVector`/`ZilAdecl` all
   implement, referenced throughout `Values/` in phase 1's reading).

2. **`LocalEnvironment`/activation frames** for routine/PROG calls with
   proper dynamic extent and `RETURN`/`AGAIN` non-local exit (the original
   uses `ZilResult` as a discriminated "value or control-flow signal"
   return type threaded through everything — `EvalImpl` returns `ZilResult`
   precisely so a `RETURN`/`AGAIN`/exception-like signal can propagate up
   without real exceptions; Oberon has no exceptions either, so this
   `ZilResult`-as-explicit-signal pattern actually translates *naturally*
   — don't try to use HALT or error-flag tricks here, model `ZilResult`
   directly as a tagged value/signal, matching the original's own design
   rather than fighting it).
3. **SUBR/FSUBR/macro dispatch**: `ZilForm.EvalImpl` (already read in
   full, in this session, for context — see `Zilf/Interpreter/Values/
   ZilForm.cs`) looks up the head atom's global or local value; if it's a
   `ZilSubr`/`ZilFSubr` (built-in procedures — FSUBR gets unevaluated
   args, SUBR gets evaluated args), it calls into a big dispatch table of
   native implementations (`Zilf/Interpreter/Subrs/*.cs` — **note**: this
   directory wasn't in the top-level listing surveyed this session; find
   and size it before starting phase 2, it's likely where much of the
   16,868-line `Interpreter` total actually lives beyond `Values/`).
   `ZilEvalMacro`/`DEFMAC`-defined macros expand via `ZilForm.Expand`
   (also already read).
4. **CHTYPE / type system**: `PrimType` (ATOM/FIX/STRING/LIST/VECTOR — the
   "primitive representation" every ZIL type ultimately reduces to) and
   the `BuiltinType`/`ChtypeMethod` attribute-driven coercion machinery.
   Needed to make `#TYPE (...)` from phase 1 actually work.
5. Once 1-4 exist, **go back and fix phase 1's two stubs** (`%` and
   `#TYPE`) to call the real evaluator/CHTYPE instead of passing through
   unevaluated.

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

1. Re-run phase 1's read/print round-trip test on `sample1.zil` (and maybe
   a real excerpt from an actual `.zil` file, if one is findable in this
   machine's zilf checkout or a public ZIL sample) to confirm nothing
   regressed.
2. Read `Zilf/Interpreter/Context.cs` (1,457 lines) and `ZilResult.cs`,
   `LocalEnvironment.cs`, `ObList.cs`, `ArgSpec.cs` in full — all found
   and sized already (see the "phase 2" section above), just not read yet.
3. Design `ZilCtx.mod` (global/local value tables, OBLIST special var,
   property lists, StdAtom-so-far) and `ZilEval.mod` (the `ZilResult`
   signal type, `Eval`/`Expand`, SUBR/FSUBR dispatch for a *small* starter
   set: `SET`, `GET`, `PUT`, `+`/`-`/`*`/`/`, `COND`, `PROG`, `DEFINE`/
   `ROUTINE` recognition, `QUOTE`/`GVAL`/`LVAL` evaluation). Get a trivial
   ZIL expression like `<SET X <+ 1 2>>` evaluating correctly end to end
   before trying to cover more builtins — same "narrow vertical slice,
   fully working, then widen" strategy that made zapf tractable.
4. Update this doc's "what's done" section and commit again.
