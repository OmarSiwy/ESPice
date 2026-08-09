# AGENTS.md — ESPice: a SPICE circuit simulator in Zig

SPICE netlists in; DC, AC, transient, periodic, noise and sweep analyses out.
Device models are Verilog-A compiled at build time by VerA, GPU device
evaluation goes through Gompute, and stdpp supplies the vectorizing iterators.
All three are git URL pins in `build.zig.zon`. To co-develop one, build against
a local checkout with `zig build --fork=../VerA` (repeatable; it replaces every
package whose manifest name matches, and fails if none does), so
`build.zig.zon` never carries a `.path`. Commit the new pin (url and hash) once
the dependency's change is pushed.

This file is the project's design standard and its design review. Every agent
and every human follows it before writing, changing or reviewing code. It
defines one discipline, **code that is lean in storage, has zero runtime
overhead from its abstractions, is easy to modify, keeps its failures
contained, and is proven by its tests**, and it routes each step to the skill
that carries the mechanics. A skill is named in backticks
(`data-oriented-design`), a supporting file as `skill/FILE.md`
(`codebase-clean-code/LADDER.md`). Load a skill with the Skill tool (other
agents: read `~/.claude/skills/<name>/SKILL.md`), then **follow its steps and
"Done when" criteria**. Skills marked _(explicit)_ never fire on their own;
invoke them by name when this file sends you there.

The Principles (Parts I–VII, Appendices A–C) are in
[`dev/principles.md`](dev/principles.md). **Read the Part a design-review stage
cites before running that stage**, and read Chapter 24 before any code review.

---

## 0. How to use this file

### 0.1 What is binding

| Section | Status |
| --- | --- |
| §1 The Design Review | **Binding.** Run it for every change it covers (§1.1). |
| §2 Project overrides | **Binding.** These rulings beat any skill they name. |
| `dev/principles.md` Parts I–VII | **Binding** where a principle states a rule; otherwise the reasoning behind the rules. |
| `dev/principles.md` Appendices A–C | Reference. |

### 0.2 Precedence when sources disagree

1. **§2 of this file** (project overrides).
2. **`systems` conflict rules**, in its order: data layout beats code brevity; `ponytail` decides how little code to write, never what shape the data takes; the zero-cost proof comes before the abstraction.
3. **`codebase-rules` rulings**: Clean Code loses to the data in hot code only; pure by default, impure when the pieces are tested; testability is a seam question; measure before accepting any performance rung.
4. **The domain skill for the block** (`spice-engine`, `compiler-construction`, `gpu-kernel-optimization`, `gpu-parallel-algorithm-thinking`, `writing-perfect-verilog`).
5. **The general skills.**
6. **The Principles.**

If a principle and a skill disagree and §2 does not settle it: the skill wins on **mechanics** (how to do it in this language and toolchain), the principle wins on the **requirement** (zero runtime overhead, containment, tests). Record the conflict as a new §2 entry in the same change.

### 0.3 Project specifics

- **Zig:** 0.17.0. Every build, test and probe runs inside `nix develop` (Zig 0.17.0, LLVM 21, CUDA, ROCm/HIP); the system `zig` on the development machine is 0.16 and is never used. `nix develop .#benchmarking` adds perf, ngspice and VACASK for `zig build bench`. Code carrying 0.16 forms is ported with `zig/migration-0.17.md` before review.
- **Rust:** none. The Rust rows of the skills do not apply.
- **The oracles:** ngspice and VACASK (pinned in the flake's benchmarking shell), analytic answers, and the fixture corpus `tests/fixtures/**` whose `.expected.json` files record them (§2.7).
- **Shipped targets:** x86_64 Linux at `x86_64_v2`/`v3`/`v4`, aarch64 Linux (generic, `neoverse_n1`), macOS arm64 (`release.yml`). Codegen probes run at `-mcpu=x86_64_v3` (AVX2; the development machine has no AVX-512).
- **Backends:** CPU host; CUDA (tested on the local NVIDIA GPU through `zig build test-gpu`); HIP (no AMD hardware: untested, labelled unsupported per Technique 21.14 until it runs on hardware).
- **Where artifacts live:** `ARCHITECTURE.md`, `GLOSSARY.md`, `TESTING.md` (repo root); seam records and drill tables in `dev/decisions.md`; ADRs in `dev/adr/`; design-review reports in `dev/reviews/<yyyy-mm-dd>-<topic>.md`; design notes, maths, root-cause digs and measured evidence in `dev/`. `docs/` is the user documentation (the GitHub Pages site built by `mkdocs.yml`), never design notes.

### 0.4 Skill map: which skill, when

Every session, before writing or reviewing code here, load in this order (design constraints first, code minimization last): `data-oriented-design`, `codebase-clean-code`, `spice-engine`, `zig`, `assertions`, `ponytail`. Then use the map:

| Situation | Skill |
| --- | --- |
| Which skill to reach for; who wins on conflict | `systems` _(explicit)_ |
| Build order before, during and after writing; rulings | `codebase-rules` |
| Program or subsystem layout; where a feature goes; pattern vs concrete code; change drills | `codebase-clean-code` (+ `LADDER.md`, `HIERARCHY.md`, `DECISIONS.md`) |
| Deep-module vocabulary; the deletion test | `codebase-design` (+ `DEEPENING.md`, `DESIGN-IT-TWICE.md`) |
| A library, engine or FFI boundary someone else calls (`espice.zig`, `c_api.zig`, the device ABI) | `api-design` (+ `zig.md`) |
| Struct layout, SoA/AoS, field widths, hot/cold, profiling a hot path | `data-oriented-design` (+ `foundations.md`, `measurement.md`, `REFERENCE.md`, `zig.md`) |
| Writing or reviewing `.zig`; 0.16 → 0.17 port; does an abstraction cost anything | `zig` (+ `comptime.md`, `memory.md`, `zero-cost.md`, `simd-first.md`, `migration-0.17.md`) |
| Programmer-error contracts, capacities, bounded loops | `assertions` (+ `zig.md`) |
| A `pub` item, error set or module needs its doc comment; the post-feature doc audit | `doc-comments` (+ `zig.md`) |
| A data-dependent branch in a hot loop | `branchless` |
| A hot scalar loop to vectorize (after `branchless`) | `simd-loops` |
| SIMD past the walls; a lane axis across instances | `simd-first` (and `zig/simd-first.md`) |
| A GPU kernel written, ported, reviewed or slow | `gpu-kernel-optimization` |
| A sequential algorithm rewritten for a GPU; dependency DAG; work/span | `gpu-parallel-algorithm-thinking` |
| The netlist lexer/parser, expression compiler, interner, diagnostics | `compiler-construction` (+ `FIXTURES.md`) |
| Stamping, sparse LU, Newton, timestep control, device models | `spice-engine` (+ `LINEAR.md`, `NUMERICS.md`, `TESTING.md`) |
| Digital Verilog models | `writing-perfect-verilog` |
| Test strategy, fuzzing, differential/golden testing, CI gates, release criteria | `test-plan` (+ `DOMAINS.md`, `TECHNIQUES.md`, `SOURCES.md`) |
| The red → green loop; where tests go | `tdd` (+ `tests.md`, `mocking.md`) |
| A bug or a performance regression | `diagnosing-bugs` |
| Reviewing a diff: Standards axis and Spec axis | `code-review` |
| What should not have been built | `ponytail` (writing), `ponytail-review` (a diff), `ponytail-audit` (a repo) |
| After a phase lands | `simplify` |
| Docs and comments read like a person wrote them | `humanizer` |
| Terminology, `GLOSSARY.md`, ADRs | `domain-modeling` (+ `ADR-FORMAT.md`, `GLOSSARY-FORMAT.md`) |
| Bringing existing code up to this standard, block by block | `codebase-improvement` (the live plan: `dev/plan/standard-adoption.md`) |
| Finding deepening opportunities, as an HTML report | `improve-codebase-architecture` _(explicit)_ |
| Changing code that has no tests | `legacy-code` (+ `REFERENCE.md`) |
| Fowler's smell catalogue and refactoring moves | `refactoring-patterns` _(explicit)_ |
| DRY, orthogonality, reversibility, contracts, tracer bullets | `pragmatic-programmer` _(explicit)_ |
| Tests, review, dependencies, deprecation, large-scale change | `engineering-at-scale` _(explicit)_ |

---

## 1. The Design Review

The design review is a fixed sequence of stages, each with a skill, a question and a "Done when." A design passes when every stage's verdict is **pass** or an **exception the user accepted in writing**. It fails if any stage's verdict is missing.

### 1.1 When to run it

| Change | Review |
| --- | --- |
| New program, subsystem, module or analysis | Full (R0–R10) |
| New feature touching two or more tables, or adding a table | Full, scoped to the tables it touches |
| New or moved seam; any rung change | R4, R5, R8, R9 |
| Change to a boundary: `espice.zig`, the C ABI, the device ABI, a netlist dialect, an output format | R1, R6, R7, R9 |
| Change to a hot path (profiled, benchmarked, or in a loop over many elements) | R2, R4, R7, R8 |
| Bug fix | R6 and R7 (the missing oracle, Principle 19.4) |
| Any other diff | R10 only |
| Existing code brought up to standard | `codebase-improvement`, which runs the relevant stages per block |
| Code with no tests | `legacy-code` first (characterization tests), then the stages above |

### 1.2 The stages

Each stage lists: **Skill**, **Principles** (sections of `dev/principles.md`), **Ask**, **Done when**.

**R0 — Scope and route.**

- Skill: `systems`, `codebase-rules`.
- Ask: Which domain skill owns this block? Is this new code, existing code or untested code? Is it hot or cold? ("Hot" needs evidence: a profile, a benchmark, or a call site in a loop over many elements; otherwise it is cold until proven, per `codebase-improvement`.)
- Done when: the review report names the change, its domain skill(s), its hot/cold verdict with evidence, and which stages apply (§1.1).

**R1 — Boundary.**

- Skill: `api-design`.
- Principles: Chapter 14, Chapter 18.
- Ask: Where does the boundary go, and is the usage code written first? Does each high tier of the interface have a path down to a low one (no integration discontinuity)? Is flow control the caller's?
- Done when: the usage code a real caller would write exists in the report, and the five characteristics (granularity, redundancy, coupling, retention, flow control) are assessed. Getting this wrong is the one mistake a later stage cannot fix (`codebase-rules`).

**R2 — Data.**

- Skill: `data-oriented-design` (Six Questions).
- Principles: Part I, Part II.
- Ask: All six, out loud: what goes in and out; how many; how wide (from the spec); access pattern; lifetime; parallelizable.
- Done when: every table has a producer, a consumer, a layout (SoA or justified AoS), each field's width with its stated range, a capacity constant with a unit, and a lifetime (arena named for its phase), and every transform is written as `name: reads → writes`. A width that cannot be stated is a spec gap to ask about, not a reason to widen.

**R3 — Owners and spines.**

- Skill: `codebase-clean-code` steps 2–3, `codebase-clean-code/HIERARCHY.md`.
- Principles: Chapter 13, Chapter 14.
- Ask: Who is the one owner of each table? Do the modules form a DAG? Does each pipeline have one spine, one line per transform? Does any outside write bypass a request table?
- Done when: the ownership map lists one owner per table, the module graph has no cycle and the build enforces it, every outside write goes through a named request table, and the spine runs end to end as stubs with every "which work" branch in the spine.

**R4 — Seams and the ladder, under the project budget.**

- Skill: `codebase-clean-code` steps 4–5, `codebase-clean-code/LADDER.md`.
- Principles: Part III, §2.1.
- Ask: For each place behaviour could vary: what varies (kind, backend, platform, dialect, policy, plugin), and what is the evidence (two cases today, or a drill)? Which is the cheapest rung that handles the axis? Is it allowed in this path under §2.1?
- Done when: every seam names its axis, evidence, rung, and why the rung below fails; every place without evidence is concrete code; no seam violates the hot-path budget in §2.1.

**R5 — Change drills.**

- Skill: `codebase-clean-code` step 6, `codebase-clean-code/DECISIONS.md` (drill table).
- Principles: Chapter 15.
- Ask: What are three likely changes? Get them from the user, or from the GitHub issues, `dev/plan/` or `dev/decisions.md` with the source cited; never invent them. For each: every edit (file and function), the change radius, the interface-weight change.
- Done when: every drill has a complete edit list and a numeric radius, and every failed drill is fixed (restructure first, climb one rung second) or recorded as an exception the user accepted.

**R6 — Failure containment.**

- Skill: `assertions`; `zig/memory.md`; `doc-comments` (ranks 1 and 4).
- Principles: Part V.
- Ask: Is every check classified as operating error or programmer error? Is outside data validated once at the boundary into refined types? Does each module return a narrow, explicit error set? Is every state change fallible-first, infallible-after (or `errdefer`-rolled-back)? Is there global mutable state? Is every loop and queue bounded? Which runtime checks ship in release, and why?
- Done when: no assert tests a value straight from outside; every boundary function owns its error return and every function behind it owns an assert; error sets are explicit at every module boundary; no global mutable state exists; every table has a capacity and every loop a bound; the check budget (Principle 17.10) is recorded for each module.

**R7 — Test plan.**

- Skill: `test-plan` (steps 1–7), `tdd` (seams), `spice-engine/TESTING.md`, `compiler-construction/FIXTURES.md` (netlist dialects), `gpu-parallel-algorithm-thinking/verification.md`, `test-plan/DOMAINS.md`.
- Principles: Part VI.
- Ask: What are the bug classes, and what oracle sees each one? Which seams are tested, agreed with the user? Which layer and tier covers each bug class? What are the exit criteria?
- Done when: every bug class has an oracle that does not recompute the answer the way the code does; the tested seams are written down and confirmed with the user before the first test; every layer has a tier and the merge tier fits its budget; exit criteria are numbers or yes/no checks; `TESTING.md` is updated.

**R8 — Proof of zero overhead and of speed.**

- Skill: `zig/zero-cost.md` (probe protocol); `data-oriented-design/measurement.md`; `simd-loops`, `branchless`, `simd-first` for hot loops.
- Principles: Chapter 1, Chapter 12, Technique 21.15.
- Ask: For every seam at rung 5 or above and every new abstraction on a hot path, what is the probe verdict? For every speed claim, what is the number?
- Done when: every such pair reports FOLDED, IDENTICAL, EQUIVALENT or NEGATIVE and is wired into `zig build test`; rungs 6–9 state where their residue sits and its count per run; every speed claim carries a before/after benchmark (§2.13); data size, code size and compile time are reported for abstractions that move them. A vectorized loop that benchmarks slower is reported and the scalar version kept.

**R9 — Record.**

- Skill: `codebase-clean-code` step 7 and `DECISIONS.md`; `domain-modeling` (`GLOSSARY.md`, ADRs).
- Principles: Principle 15.6.
- Ask: Does every seam have a seam record? Is the drill table written? Is `ARCHITECTURE.md` current (module DAG, spines, tables, seams, invariants, adding a feature, change drill)? Did any term get sharpened or any hard-to-reverse decision get made?
- Done when: someone who has not read the code can say from `ARCHITECTURE.md` which file a given feature goes in; every seam has a record in `dev/decisions.md` (with its probe verdict at rung ≥5); new terms are in `GLOSSARY.md`; decisions are in `dev/adr/`.

**R10 — Code review of the result.**

- Skill: `code-review` (Standards and Spec axes; this file is a Standards source), then `ponytail-review`; `doc-comments` audit; for a whole repo, `ponytail-audit`.
- Principles: Chapter 24 (red flags).
- Ask: Does the diff follow this file and the skills (Standards)? Does it do what the spec asked, no more (Spec)? What should not have been built?
- Done when: both axes are reported separately and not reranked; every hard Standards violation is fixed; the doc audit passes; every `ponytail-review` deletion is applied or answered.

### 1.3 The review report

Write it to `dev/reviews/<yyyy-mm-dd>-<topic>.md`:

```markdown
# Design review: <topic>

- **Change**: <one sentence>
- **Domain skill(s)**: <…>
- **Hot/cold**: <verdict> — evidence: <profile / benchmark / loop call site / none → cold>
- **Stages run**: <R0…R10 per §1.1>

## Data (R2)

| Table | Owner | Fields: width (range) | Layout | Capacity | Lifetime/arena | Producer → consumer |
| ----- | ----- | --------------------- | ------ | -------- | -------------- | ------------------- |

Transforms: `name: reads → writes`, one per line.

## Seams (R4) and drills (R5)

<seam records per codebase-clean-code/DECISIONS.md; drill table>

## Containment (R6)

| Module | Error set | Boundary validation | Check budget (Principle 17.10) | Bounds |
| ------ | --------- | ------------------- | ------------------------------ | ------ |

## Test plan (R7)

| Bug class | Oracle | Layer | Tier | Harness / file |
| --------- | ------ | ----- | ---- | -------------- |

Seams under test (confirmed with the user on <date>): <…>
Exit criteria: <numbers or yes/no>

## Proof (R8)

| Abstraction / seam | Rung | Probe verdict | Probe file | Data size | Code size | Benchmark (before → after) |
| ------------------ | ---- | ------------- | ---------- | --------- | --------- | -------------------------- |

## Checklist

| #   | Check | Source | Verdict | Evidence (file:line, probe, number) |
| --- | ----- | ------ | ------- | ----------------------------------- |

## Accepted exceptions

<each with who accepted it and the "revisit when" event>
```

The **Checklist** table carries every item from Chapter 24's design-review list and from `codebase-clean-code`'s "Reviewing an existing codebase" list that applies. Each row needs a verdict (pass / fail / n.a. with reason) and evidence. "Looks fine" is not evidence.

### 1.4 Exit criterion

The design is approved when every applicable stage is done by its "Done when," every new seam names its rung, cites a change drill it passes, and has its zero-cost proof at rung 5 or above, the test plan's merge-tier layers exist and fail against stubs (red before green), and the report is committed with the change.

---

## 2. Project overrides of the skills

These rulings are this project's. Each one names the skill text it overrides or sharpens.

### 2.1 The runtime-overhead budget

The project rule is **no runtime overhead from abstraction**: an abstraction may cost compile time, build time or test time, never run-time work beyond the hand-written code (Principle 1.2). Applied to `codebase-clean-code/LADDER.md`:

| Rung | Mechanism | In a hot path | In cold code | Condition |
| --- | --- | --- | --- | --- |
| 1 | Concrete code | Allowed | Allowed | The default |
| 2 | Free function over plain data | Allowed | Allowed | Extract per `HIERARCHY.md` |
| 3 | Table + transform (value table or table per kind) | Allowed | Allowed | Value table: compiler must refuse a missing row (`std.enums.EnumArray`) |
| 4 | Closed enum + exhaustive switch | Allowed only when it is the hand-written minimum for data that genuinely varies per element (the probe compares it with the hand tag-and-switch, not with a single concrete path); a switch repeated across transforms moves to rung 3 | Allowed | No `else =>` (Principle 10.2) |
| 5 | Comptime or generic parameter | Allowed with a probe verdict of FOLDED, IDENTICAL, EQUIVALENT or NEGATIVE | Allowed | Code size reported per instantiation |
| 6 | Request table or command queue | Never per element; per request, with capacity reserved at the phase boundary so no growth call runs in the emitter loop | Allowed | Residue location and count in the seam record |
| 7 | Function-pointer table indexed by kind | Never per element; once per kind per pass, over a bucketed batch (the device `Batch` vtable: O(device types) indirect calls per eval) | Allowed | Same |
| 8 | `*anyopaque` + function pointers (a vtable) | **Forbidden** | Only at a cold boundary (a backend picked at startup, a test fake) and only when rung 5 cannot do the job because the choice is not known at build time | Seam record states why rung 5 fails |
| 9 | Process, `.so` or ABI plugin boundary | **Forbidden** | Only for separately built code: the runtime HDL loader, the GPU kernel ABI, the C ABI | Snapshots in, request tables out; ABI version + `layout_hash` checked |

"Hot path" is a measured claim (R0). Code without that evidence is cold, and the cold column applies; the probe is still required for rung 5 if the code later becomes hot.

### 2.2 Clean Code and function size

`codebase-rules` already rules that Clean Code loses to the data in hot code only. This project adds: function extraction follows `codebase-clean-code/HIERARCHY.md` everywhere (extract when used in three or more places, when it defines an interface worth documenting, when the test plan names it, or when it has a table of input → expected-output cases). A spine or run-once sequence stays one function with labelled blocks. Function size follows cohesion, not line count (Principle 13.3).

### 2.3 The `code-review` smell baseline

`code-review` says a documented repo standard overrides its Fowler baseline. This project overrides these baseline fixes:

| Baseline smell | Baseline fix | This project's fix |
| --- | --- | --- |
| Repeated Switches | Replace with polymorphism, or one shared map | Bucket by kind and move to a table per kind (rung 3), or a value table (rung 3); climb to rung 7 only per §2.1. Never a vtable |
| Feature Envy | Move the method onto the data it envies | Move the transform to the **owner** of the table it writes; reads stay `const` parameters |
| Data Clumps | Bundle into one type | Bundle only if the fields are read together by the same transforms; otherwise keep parallel columns (SoA) |
| Duplicated Code | Extract the shared shape | Extract only if it is the same **knowledge** (Principle 13.5) and meets §2.2; similar-looking code that changes for different reasons stays separate (false DRY) |
| Primitive Obsession | Give the concept its own small type | Same, as a zero-cost `enum(u32)` handle, with its width from R2 |
| Refused Bequest | Drop inheritance, use composition | Not applicable: no implementation inheritance exists in this codebase |

All other baseline smells apply as written, as judgement calls.

### 2.4 Abstraction timing

A **seam** is introduced at the second real case today or when a drill needs it (`codebase-clean-code` step 4); a **function** is extracted at the third use (`HIERARCHY.md`). The two rules apply together and do not conflict.

### 2.5 Build modes and runtime checks

The check budget in Principle 17.10 is the project policy, with one ruling (user, 2026-10-17): **ReleaseFast is the default and the shipped mode; ReleaseSafe is the test mode.** `zig build`, the flake package and `release.yml` build ReleaseFast, because the product is compared against `-O2` ngspice and a safe build measured up to 2.2× slower (`stress/scaling_rc_ladder_100k` 2.15 s → 4.65 s; the 4k inverter chain +16%). Every gate runs ReleaseSafe (`zig build test -Doptimize=ReleaseSafe`, the CI job), so every `std.debug.assert` and safety check executes on the whole suite and corpus before a merge; a ReleaseSafe failure is a bug even when ReleaseFast passes (it found #122, #123, #124). Debug joins the gate once #25 (self-hosted backend divergence) closes. Boundary code (the netlist parser, the C ABI, the session) may later opt into safety in the shipped binary with a scoped `@setRuntimeSafety(true)`, each with a benchmark in its review. Comptime assertions are always on. `assertions/zig.md` governs what each assert compiles to per build mode.

### 2.6 Testing rules that every change obeys

- No change merges without tests at agreed seams (`tdd`). Untested code is not done.
- Every test layer names its oracle (`test-plan`); a test whose expected value is computed the way the code computes it is tautological and does not count (`tdd`).
- Every bug fix adds the regression test **and** the oracle or generator that would have found it (Principle 19.4).
- Refactoring is done after green, in the review stage, never inside the red → green loop (`tdd`).
- Every SIMD kernel adds a differential case against its scalar oracle (its `W == 1` instantiation) in the owning module's test suite (an in-file `test`, `src/solver/tests.zig` or `src/analysis/tests/`), so `zig build test` runs it, plus an asm spot-check that the expected vector instruction is emitted (§2.12). `LaneLu` is the worked example.

### 2.7 The corpus is the oracle, and it is measured

The architecture is free to change; the observable results are not. **Every fixture's verdict must hold by name**: `tests/VERDICTS.tsv` records each deck's verdict (PASS or XFAIL) as the harness measured it, and a change may move a deck from XFAIL to PASS (dropping its marker) but never the reverse. Rules:

1. **Never type a conformance number. Measure it.** Only the harness writes a count or a verdict into a document; `zig build test` prints the current counts.
2. **Gate on `$?`, never on the tail of a log.** `cmd 2>&1 | tail` swallows the exit code; in a pipeline, `exit "${PIPESTATUS[0]}"`.
3. **Diff PASS and XFAIL name lists, never counts.** A count can hold while its membership changes (Principle 22.4). Zero names captured means the capture broke, not a pass.
4. **`* KNOWN GAP:` markers are implemented, never deleted.** A deck whose feature is missing says so in the deck, naming the cause, and the harness reports it XFAIL; it fails on any FAIL or XPASS, so a marker cannot outlive its limitation. There is no separate index of failing decks.
5. **Establish that an expectation is right before changing the engine to pass it.** Every `.expected.json` records its provenance (ngspice or VACASK version, analytic derivation, re-derivation). An intentional divergence from ngspice or VACASK is recorded in `dev/` with its measurements and fallback, in its own commit, never inside the code change.
6. **Refuse by name.** A card, option or analysis ESPice cannot execute yet is parsed and refused with a named diagnostic (the `tests/fixtures/invalid/` input contract), never silently ignored.
7. **Timing-sensitive decks** (`stress/scaling_inverter_chain_4k`) can time out on a loaded machine; check the failure reason before calling it a regression.

### 2.8 The module DAG is the build graph

A module can only import what `build.zig` hands it, so the wiring is the DAG. A module must exist before it is handed on, so only a late `addImport` could close a cycle; `checkModuleGraph` in `build.zig` walks the shipped graphs at configure time and panics on a cycle or on an edge its `restricted_imports` table forbids (Principle 14.4). A new rule below is a new row in that table. `tests/fitness.zig` checks what the build cannot see inside a module (leaf → root imports, `else =>` notes, `//!` headers). `ARCHITECTURE.md` holds the current graph, owners and spines; this section holds the rules that graph must keep:

- **Only `analysis` imports `solver`.** Cross-layer tests that need solvers belong inside analysis.
- **Only `device` deals with devices.** It owns the neutral ABI (`abi.zig`), the evaluator (`eval.zig`, also the per-model host-object, GPU-kernel and runtime `.so` build root), the parameter binder, HDL loading, the frozen `Circuit` and the per-Problem `Library` (one dense `DeviceType` per device type). The SPICE letter and LEVEL policy stays in the frontend. The runtime loader rebuilds `eval.zig` by path, so the `dyn_path`, `device_abi_path`, `core_path`, `stdpp_path` and `gompute_path` build options follow any move of those files.
- **Analysis never imports frontend or the facade;** output never imports analysis (`analysis.schemaOf` describes a result before it runs, `output.validateQuery` decides whether a format holds it).
- **stdpp is a std extension:** every host module gets it, so it is not a DAG edge. GPU device modules do not get it, so `device/eval.zig` never imports it.
- **Leaves import shared types or other leaves, never their module's `root.zig`.** Roots aggregate and re-export; the alias list is the module's API.

### 2.9 CPU/GPU sharing and the frozen boundary

No GPU-only kernel logic. Kernel code lives once in the shared path (`device/eval.zig` `evalRange` + `Sink(comptime device)`); gompute compiles it for host, CUDA and HIP. Backend is a runtime choice (`--backend auto|cpu|cuda|hip`) gated by the hardware probe; `--backend cuda` on absent hardware fails with an error naming what was detected. The GPU evaluates device planes; every solve runs on the host.

FROZEN at the GPU boundary (ABI + `layout_hash`): scatter tapes (gath/rhs_idx/slots u32 layout), Model/Instance PODs, the `model_of` row tape, pattern CSC and plane `[]f64` layout. Redesign host tables around them, never through them; a change through them bumps `abi_version` and keeps the default build, `zig build test-gpu` and CUDA-vs-CPU results as they were. Anything touching the device ABI, the Circuit GPU hooks or `analysis/gpu.zig` is verified with the default (GPU) build, not only `-Dgpu=false`.

### 2.10 The lane axis is designed in

| Axis | Mechanism |
| --- | --- |
| Frequency points (ac, noise, stb, sp through `ac/freq.zig`) | SIMD lanes: `LaneLu(W)` replay of one SparseLu pivot tape; `FreqSolver.solveBatch`, every rhs per factorization. pac, pxf and pnoise solve per point with GMRES over the periodic operator |
| Sweep points (mc/temp/sens/dcmatch) | Structural lanes: `sweep/lanes.zig solveLanes` (serial over lanes) |
| Device derivatives | `Dual(N, F)` forward AD (`device/eval.zig`) |
| Device instances | ParEval worker threads |

Not lanes: transient timesteps (sequential in t), Newton iterations, HB harmonics (coupled through the nonlinearity), PSS shooting. The scalar oracle is the `W == 1` instantiation of the same kernel, never a second code path. Lane kernels return per-lane failure masks, and failed lanes peel to the scalar path, whose full factor re-pivots.

### 2.11 Loops and stdpp

Zig 0.17 ships with LLVM's loop vectorizer off, so a plain `for` over `[]f64` is scalar even at `-mcpu=x86_64_v3`. Vector code comes from stdpp pipelines or explicit `@Vector(W)` kernels whose `W == 1` instantiation is the oracle. Read `zig-pkg/stdpp-*/skill/stdpp/{SKILL,PERFORMANCE}.md` before converting a loop or claiming a speedup (`zig build --fetch` fills `zig-pkg/`).

- A contiguous, pure, per-element loop (map, reduction, search, filtered count, compaction) is a stdpp pipeline, through a `core.numerics` helper (`axpy`, `scale`, `sub`, `dot`, `sum`, `normInf`) where one fits. `numerics.dot` and `sum` reassociate (fixed lane accumulators, one fixed combine order), so every caller rounds the same way, though not like an index-order fold. A sum that must match ngspice bit for bit stays a plain loop.
- Plain loops: gathers and sparse walks, chains where each step reads the last, parsers, and the shapes stdpp keeps scalar (`fold`, `reduce`, `forEach`, non-lanewise callbacks, unfiltered `stepBy(k)` with k ≥ 3).
- Below its size cutoffs stdpp runs the scalar path with the same results (unfiltered folds and searches under max(64, 4 vectors), filtered pipelines under 2 vectors, stores under 1 vector); claim no speedup on short vectors without a bench.
- Callbacks are lanewise: generic over `T` and `@Vector(N, T)`, pure, total on every lane. Pass runtime constants through `z.bind` or a `lanewise = true` struct; a comptime constant makes a new ~810 B instantiation per value.
- Every pipeline asserts `comptime std.debug.assert(@TypeOf(it).lane_count != null)` (guarded to `builtin.zig_backend == .stage2_llvm or .stage2_x86_64`) and has a differential test against the same pipeline on `.byRef()`: lengths 0 past 3× the widest lane count, several misalignments, bitwise where exact, NaN and inf where the input can carry them. `core/numerics.zig` is the template.
- When 0.18 turns the vectorizer back on, re-measure before deleting a pipeline.

### 2.12 Call conventions and Zig idioms

- Immutable input: by value `T` (Zig passes big structs by hidden reference). Callee mutates: `*T`. Large and identity matters: `*const T`; never `*const` on small PODs. Non-mutating methods take `self: Self` (or `*const Self` when large).
- Cross-object references are typed `enum(u32)` handles into tables, never stored pointers (Principle 5.1). Allowed pointers: the device `Batch` vtable, slices into owned storage, `ParamRef.ptr` (frozen-storage contract), and `Circuit.lin.x_ptr` (an identity key never dereferenced; every plane or parameter writer clears it). Any other stored pointer is a flag for `codebase-improvement`.
- `std.StaticStringMap` for every fixed string set (the card keyword map `cards` in `frontend/netlist.zig` is the template); `std.enums.EnumArray` for every enum-keyed table.
- SoA with explicit hot/cold splits for hot tables (`SparseLu` and the `frontend/csr.zig` hypergraph are the templates). AoS only when all fields are read together per iteration (`Batch` is the documented exception).
- Arenas by lifetime: parse scratch (dies after preparation), session arena (prepared template/source), per-query work and result arenas. Completed results and prerequisite products remain valid until Problem destruction.
- Comptime existence (`if (has_X) T else void`, `DeviceBatch`) over runtime optionals in per-element hot paths.
- Reading the asm of a kernel: `zig build-obj -OReleaseFast -fllvm -femit-asm=/tmp/k.s --dep core --dep stdpp -Mroot=src/solver/direct.zig --dep stdpp -Mcore=src/core/root.zig -Mstdpp=zig-pkg/stdpp-<hash>/src/root.zig`. A verdict that gates a seam comes from `zig/scripts/asm_probe.py` wired into `zig build test`, not from reading.

### 2.13 The proof rule

Every performance claim ships with a measured before/after in the commit message: `zig build bench` for wall time, callgrind instruction counts when the machine is too noisy for wall time. Every retired experiment is recorded in `dev/` with its measurements. Deliberate shortcuts carry a `ponytail:` comment naming the ceiling and upgrade path. Session notes and handoffs do not go in `dev/`: fold their durable facts into the topical page before the branch merges.

### 2.14 Verification

- `zig build && zig build test -Doptimize=ReleaseSafe` after every step (§2.5). `zig build test` runs the unit suites, the codegen probes, the fitness check and then the numeric corpus; its exit code is the gate (in Zig 0.17 output, `run test w` with a `failed command:` line only shows a step's stderr), and `tests/VERDICTS.tsv` is the name list it must keep (§2.7).
- While editing, keep `nix develop -c zig build check -Dgpu=false --watch -fincremental` running in the worktree: it type-checks every test root without binaries, about a minute for the first pass, then under a second per edit. It catches compile errors only; the gate is still the ReleaseSafe `zig build test`.
- A CPU-only build (`-Dgpu=false`) compiles much faster and is enough for host-only changes (§2.9 names the exceptions).
- A frontend change that alters what a syntax means updates its grammar in `tests/grammar/*.peg` first; `zig build test-grammar` (part of `zig build test`) fails on any disagreement, one-sided refusal or unmatched grammar alternative (dev/frontend.md, "Grammar oracle").
- Every example under `docs/examples/` must still run.

### 2.15 Repository discipline

- **Commit at every step.** Each completed step (a document, a gate, a block, a fix, a test) is its own commit with tests green before the next step starts. Never combine a behaviour change with a layout change in one commit.
- Stage by explicit path; never `git add -A`. One agent per worktree.
- **Never `git stash`.** For a baseline, use a worktree: `git worktree add ../espice-base <rev>`; pass `--fork` there too to build against a local dependency checkout.
- No `Co-Authored-By:` trailers or other AI attribution in commits; every commit is authored by the repository's git user.
- **Every user-visible change gets a `CHANGELOGS.md` bullet** under `## Unreleased`, in the same commit: one line, kept light. Every fix cites its GitHub issue as `(#123)`; open the issue first (`gh issue create`) if none exists. A release renames `Unreleased` to the version and date and starts a new empty `Unreleased`.
- `docs/` stays in sync with user-visible behaviour: a change to a card, flag, analysis, output format or error a user can hit updates the matching `docs/` page in the same commit.
- Every file opens with a `//!` header: its transformation (in → out) and what it cites (ngspice/VACASK source, papers, `dev/` notes, decision records). Implementation notes go in `//` comments inside the body.
