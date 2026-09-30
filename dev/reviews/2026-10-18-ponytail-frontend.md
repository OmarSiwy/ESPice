# Ponytail audit (ultra): frontend side

- **Change**: an over-engineering audit of `src/core/`, `src/frontend/`, `src/output/`, `src/espice.zig`, `src/c_api.zig`, `src/main.zig`, `include/`, `tools/` and `tests/benchmark/`, looking for code to delete or simplify.
- **Skill**: `ponytail` (ultra), using the `ponytail-audit` method.
- **Base**: `int-3` at 7c515efd. Branch `audit-pony-fe`.
- **Hot/cold**: not assessed. Every finding is cold (validation, test support, bench harness).
- **Stages run**: R10 only (§1.1, "any other diff"). Nothing was built, because zigq refuses agent builds. The applied commits are limited to edits that obviously compile.

## Method

1. Mechanical scan over every in-scope file, done twice:
   - Every `pub fn/const/var` was counted as a whole word across all tracked non-fixture files (code, `build.zig`, `docs/`, `dev/`, `tests/`). Each name with 3 or fewer mentions was read by hand.
   - Every private top-level and struct-level declaration was counted inside its own file. None was unused.
2. Four read-only sub-audits, split into netlist/builder/lexer, the rest of the frontend, core+output, and API/CLI/tools/bench. I re-verified each finding they returned with `git grep` and the module wiring in `build.zig` before acting on it.

Overall: this scope is lean. Almost every candidate turned out to have a second caller, a test, or a cited spec reason. Shared-looking code mostly turned out to be false DRY that §2.3 allows, such as the nine output encoders, which implement nine different wire formats.

## Findings, ranked by size

| # | Tag | Location | What to cut | Replacement | Status |
|---|-----|----------|-------------|-------------|--------|
| 1 | yagni | `tests/benchmark/ensemble/{gen,run}.py` (294 lines) | Manual repro scripts for the GPU-ensemble research prototype. No build step or CI job references them. The only reference is the repro recipe in `dev/research/gpu-ensemble.md:745`, and that note concludes "do not build an ensemble mode" (line 79). | Delete the scripts and the recipe paragraph, or move them under `dev/research/`. | PROPOSED: owner decision, because `dev/decisions.md:173` still lists the drill as an open research item |
| 2 | stdlib/reuse | `src/frontend/vec.zig:340` `number` (about 20 lines) | Re-implements the strict-decimal grammar of `sparam.plainNumber` (`src/frontend/sparam.zig:149`). I compared the two grammars by hand: both accept and reject the same strings, including `""`, `"."`, `".e5"`, `"+"` and `"5."`. | `return plainNumber(text) orelse error.InvalidVector;` | PROPOSED: needs a build. I tried the obvious edit and reverted it. `vec.zig` belongs to `netlist_mod` (through `netlist.zig:3999`), while `sparam.zig` belongs to `builder_mod` (`builder.zig:12`). Importing sparam from vec would put one file in two modules, which is a compile error. The fix is to move `plainNumber` to the netlist side (`lines.zig` or `vec.zig`) and have `sparam.zig` and `wfit.zig` reach it through `@import("netlist")`. The `test-frontend` wfit-only module (`build.zig:414`) would then also need the `netlist` import. |
| 3 | stdlib/reuse | `src/c_api.zig:653-666` `sweep_vtable`/`sweepAlloc`/`sweepFree` (about 14 lines) | A third hand-written copy of `core.testing.fixed_growth` (`src/core/testing.zig:12`, #128). | `std.testing.checkAllAllocationFailures(@import("core").testing.fixed_growth, ...)` | PROPOSED: `c_api_mod` (`build.zig:326`) has no `core` import. Adding one is a `build.zig` edit (`restricted_imports` allows it), and that needs a build. |
| 4 | stdlib/reuse | `src/tests/espice.zig:38-52` local `fixed_growth` (about 14 lines) | Same duplicate as #3. | `@import("core").testing.fixed_growth` | PROPOSED: the `src/tests/espice.zig` module (`build.zig:373`) also has no `core` import. Same build edit as #3. |
| 5 | shrink | `tests/benchmark/runner.zig:232,445` | Two identical anonymous byte-order comparators. | One file-level `lessStr`. | APPLIED 92590434 |
| 6 | delete | `src/core/validate.zig:145` `"pss_periods"` | A dead entry in the positive-count `@hasField` list. No query struct has this field: `git grep pss_periods` finds only this line and one historical note in `dev/analysis/pac.md:82`. | Nothing. | APPLIED 427f1c38 |
| 7 | yagni (minor) | `src/core/query.zig:693` `Unified.VariantRange`, `src/frontend/prepare.zig:177` `BuildError` | Marked `pub` but used only inside their own files. | Drop the `pub`. | PROPOSED: not worth a commit by itself. Do it the next time those files are touched. |

## Checked and kept (so nobody raises them again)

- `src/frontend/spice.zig:110` `absent_model` has no reader, but it is the only declaration in each `Absent(name)` stand-in type, and every consumer gates on `@hasDecl(T, "eval")`. Removing it changes nothing at runtime and saves one line. Kept.
- `src/frontend/csr.zig` `BipartiteHypergraph` has one production instantiation, but it is comptime (rung 5), tested as a generic, and already scoped down by its own `ponytail:` comment.
- `sparam.zig` linear algebra (`symEig`, `householder`, `leastSquares`) against `core/eigen.zig` and `core/lm.zig`: these are different algorithms solving different problems, so they are not duplicates.
- `output/*` encoders: each implements a distinct wire format with its own tests. This is the false-DRY case in §2.3.
- The `std_options` and `vera_validate_contract` pair repeated in `main.zig`, `c_api.zig` and `device/eval.zig`: Zig requires these declarations in each root, so they cannot be shared.
- C ABI: the `export fn` list in `c_api.zig` and the declarations in `include/espice.h` match exactly in both directions.
- `tools/asm_probe.py`, `tools/bench_plot.py`, `tools/playground/`: all wired into `build.zig`, `flake.nix`, CI or `docs/`.
- Analysis-side aliases such as `pub const max_tones = core.validate.mhb_max_tones` (`src/analysis/pss/mhb.zig:56`) are outside this audit's scope and left to the backend audit.

## Proposed issues

1. **Title**: frontend: one strict-decimal parser for vector files, Touchstone and RLGC
   **Body**: `src/frontend/vec.zig:340` `number` re-implements `src/frontend/sparam.zig:149` `plainNumber` with the same grammar. They cannot share code today because `vec.zig` is in `netlist_mod` and `sparam.zig` is in `builder_mod`. Move `plainNumber` to the netlist side (`lines.zig`), import it in `sparam.zig` and `wfit.zig` through `@import("netlist")`, and add the `netlist` import to the wfit test module (`build.zig:414`). Gate: `test-frontend` and `test-grammar` (`vec_check.zig`, the RLGC and Touchstone data checks). About -20 lines.
2. **Title**: tests: use core.testing.fixed_growth in the C ABI and Problem allocation sweeps
   **Body**: `src/c_api.zig:653-666` and `src/tests/espice.zig:38-52` each hand-write the allocator that `src/core/testing.zig:12` already provides (#128). Add `core_import` to `c_api_mod` and to the `src/tests/espice.zig` test module in `build.zig`, then delete both copies. Gate: `test-espice`. About -28 lines.
3. **Title**: bench: keep or archive tests/benchmark/ensemble
   **Body**: `gen.py` and `run.py` (294 lines) are run only by hand, from the recipe in `dev/research/gpu-ensemble.md:745`. That note concludes against building an ensemble mode, but `dev/decisions.md:173` keeps the drill open. The owner should decide: delete them, or move them next to the research note.

## Checklist

| # | Check | Source | Verdict | Evidence |
|---|-------|--------|---------|----------|
| 1 | Dead `pub` declarations | ponytail-audit | pass (none found) | whole-repo word-count scan; only `absent_model` had 1 mention, and it is kept as explained above |
| 2 | Dead private declarations | ponytail-audit | pass | per-file scan: zero unused |
| 3 | Hand-written std or in-repo helpers | ponytail ladder rungs 2–3 | fail, 3 duplicates | findings 2–4 |
| 4 | Dead config or option names | ponytail-audit | fail, 1 | finding 6, applied |
| 5 | Applied edits compile without a build | audit brief | pass | both edits are local to one file and add no imports. The vec.zig edit was reverted after the module-ownership check failed |
| 6 | No observable result, frozen GPU boundary or third-party .va changed | audit brief | pass | the diff touches only `validate.zig` (removes a check that was always false) and the bench runner |

Net: -12 lines applied. About -60 lines possible with a build, -294 more with an owner decision. 0 dependencies to remove.
