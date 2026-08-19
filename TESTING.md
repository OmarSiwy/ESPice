# Testing

What "correct" means for ESPice: for every deck, the analysis results agree
with an independent oracle (ngspice, VACASK, or an analytic answer) within a
tolerance justified per quantity, on every shipped target and backend, and an
invalid deck is refused with a named diagnostic. `AGENTS.md` §2.6–§2.7 are
the rules; this file is the plan (`test-plan` step 7). Counts are never typed
here: `zig build test` prints them, and `tests/VERDICTS.tsv` holds the
measured name list.

## Domains

| Component | Domain (`test-plan/DOMAINS.md`) |
|---|---|
| frontend: lines, expr, netlist, source, analyses, measure | parser / compiler frontend |
| device: eval, bind, ABI, loader; `models/` via VerA | numerical (derivatives), plugin ABI |
| solver: sparse/dense/lane/BBD LU, converger, GMRES, FFT | numerical solvers |
| analysis: OP, DC, AC, tran, PSS/HB, noise, sweeps | numerical simulator, stateful/concurrent (session, workers) |
| analysis/gpu, solver/lu_device, device kernels | GPU multi-backend |
| lane kernels, stdpp pipelines | SIMD |
| espice.zig, c_api.zig | library / FFI boundary |
| output | encoders (round-trip, golden) |

## Bug classes → oracle → layer

Status: **have** (exists, with file), **gap** (plan block that adds it).

| Bug class | Oracle | Layer | Tier | Harness | Status |
|---|---|---|---|---|---|
| Wrong analysis result, plausible range | ngspice / VACASK values recorded in `.expected.json` with provenance | differential (golden with provenance) | merge | `tests/test_correctness.zig` over `tests/fixtures/**` | have |
| Wrong result, simple circuits | closed form (RC step, divider, RLC resonance) | spec example | merge | `analytic` fixtures in the corpus | have |
| Fixture verdict silently changes | the name list `tests/VERDICTS.tsv` | ratchet | merge | `tests/test_correctness.zig` (full CPU run) | have |
| Converged OP is wrong | KCL residual of the accepted point under a plain device evaluation | certificate | merge | `analysis/tests/` | gap: P4 (#53 is the known trip) |
| Linear solve is wrong | scaled residual ‖Ax − b‖∞ / (‖A‖∞‖x‖∞ n ε) ≤ 30, `solve` and `solveT`, on generated matrices of exact κ₂ (Givens of a geometric Σ, row-permuted, badly scaled) through `direct.Solver`: sparse LU and Thomas to κ 1e15, BBD to block κ 1e4 | certificate | merge | `solver/residual_tests.zig` | have (BBD past block κ 1e4: #136) |
| Wrong device derivative | central finite difference | certificate | merge | `device/tests/eval.zig:857` (sampled models) | partial: P4 extends to every model |
| Lane kernel differs from scalar | `W == 1` instantiation, bitwise | differential | merge | `solver/tests.zig` LaneLu, `device/tests/eval.zig:105` Dual | have |
| stdpp pipeline differs from scalar | the same pipeline on `.byRef()`, lengths 0…3×lanes, misalignments, NaN/inf | differential, exhaustive small domain | merge | `core/numerics.zig` tests | have |
| Integrator order wrong | manufactured solution, three step sizes, observed order (BE 1, trap 2, gear k) | convergence order | merge | `analysis/tests/transient.zig` | gap: P4 |
| Threading changes results | `solver_threads = 1` and `device_threads = 1` vs N, byte-identical output | determinism | merge | `analysis/tests/circuit.zig:152` (device threads only) | partial: P4 |
| Run-to-run drift | run twice, byte-compare the raw file | determinism | merge | new | gap: P4 |
| Node order changes results | renumber nodes / permute device order → same named results | metamorphic | nightly | new | gap: P4 |
| Parser crash, hang, leak, undeclared error | assertions + declared error set; structure-aware generator | fuzz (Smith) with corpus replay, seeded generator run | merge (replay), nightly (long: `zig build test-frontend --fuzz=<N>`) | `src/frontend/tests/fuzz.zig`, `src/frontend/tests/fuzz_corpus/` | have (`netlist.parse` only; `prepare`/`build` not fuzzed) |
| Invalid deck accepted or mis-diagnosed | the input contract per deck | example | merge | `tests/fixtures/invalid/` | have |
| Frontend grammar drifts from the dialect | PEG grammar oracle | differential | merge | `tests/grammar/` (#121) | partial |
| Swallowed OOM, leak on error path | `checkAllAllocationFailures` | fault injection | merge | intern, netlist.parse, `source.expand` (`frontend/tests/netlist.zig`), facade construct and `run_all` incl. builder, `.step` runs, `analyses.queries`, `Session.append`, OP/AC/tran (`src/tests/espice.zig`), solver, device freeze | partial: loader (compiles HDL) and C ABI not covered |
| Non-convergence, singular matrix, NaN device output handled | injected faults return named errors | fault injection | merge | `tests/fixtures/convergence/` | partial: P4 |
| C ABI misuse (stale handle, short buffer, bad version) | the header's documented error codes; a model of valid handle states | stateful property | merge | `src/tests/c_api.zig` | partial: P3 (generational handles) + P4 |
| CPU and CUDA disagree | the CPU backend on the same deck | differential | nightly (needs the GPU) | `zig build test-gpu` (shared expectations only) | partial: P4 adds direct CPU-vs-CUDA |
| HIP wrong | none: no hardware | — | — | — | unsupported (Technique 21.14) |
| Shipped ISA differs | same suite at each `-Dcpu` of `release.yml` | target matrix | release | `release.yml` smoke | gap: P1 runs the suite per target |
| Abstraction leaves residue | `tools/asm_probe.py` verdict | codegen probe | merge | `tests/codegen.zig` (`zig build test-codegen`) | partial: `normInf`, `Dual.mul`; one pair per rung-5 seam as its block lands |
| Hot struct grows | comptime `@sizeOf` assert | compile | merge | in the owning file | gap: P1 |
| Architecture degrades | configure-time graph check, `else =>` / root-import ratchet, `//!` header scan | fitness function | merge | `build.zig` `checkModuleGraph`, `tests/fitness.zig` + `tests/FITNESS.tsv` | have |
| Performance regression | `zig build bench` medians vs ngspice/VACASK, callgrind Ir | benchmark | nightly | `tests/benchmark/` | have (no threshold yet: P6) |
| Tests that cannot fail | mutation (flip one comparison, expect red) | mutation | weekly | new script | gap: P5 |

## Gates

| Tier | Budget | Runs | Command |
|---|---|---|---|
| Edit loop | < 1 s | `zig build check --watch -fincremental`: semantic analysis of every test root, no binaries | `nix develop -c zig build check -Dgpu=false --watch -fincremental` |
| Local | < 10 s per touched module | `zig build test-<suite>` for the touched module (`zig build --help` lists them) | `nix develop -c zig build test-solver` etc. |
| Merge | < 15 min | full `zig build test` (units + corpus) in ReleaseSafe, `-Dgpu=false`; verdict ratchet; fuzz corpus replay; probes; fitness functions. Debug joins when #25 (self-hosted backend divergence) closes | `.github/workflows/test.yml` |
| Nightly | hours | long fuzz per target; metamorphic suite; `zig build test-gpu` on the NVIDIA runner; `zig build bench` with thresholds | P4/P6 |
| Release | unbounded | release exit criteria below; `release.yml` target matrix runs the suite | `release.yml` |

## Exit criteria (release)

1. `zig build test` exits 0 on every `release.yml` target, and `tests/VERDICTS.tsv` has no PASS → XFAIL move since the last release.
2. Every fuzz target has run ≥ 24 CPU-hours with no new crash, and its corpus growth has plateaued.
3. Every fixture agrees with its oracle within its recorded tolerance; every disagreement is a KNOWN GAP with an issue.
4. Threaded and serial runs are byte-identical on the determinism decks.
5. CPU vs CUDA within each deck's tolerance on the local GPU; HIP labelled unsupported.
6. No probe verdict is RESIDUE; no benchmark median regresses past its threshold.
7. Zero open crash bugs; zero quarantined tests.
8. The KNOWN GAP markers are the written list of known gaps.
