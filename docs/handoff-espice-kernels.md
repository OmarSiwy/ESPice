# Handoff: host-pass SIMD/layout work (2026-09-23)

Branch `worktree-agent-a17f44bf2fd9e4b47`, based on `bcc13b3`. The full
profile table, kept changes and dropped experiments are in
`docs/analysis/evaluation-profile.md`, section "Host-pass profile — 2026-09-23".

## Committed

Each commit passed `zig build` and `zig build test`, and all 564 fixture raws stayed byte-identical.

| Hash | Change | mos6_inverter Ir | parallel_inverters_100 Ir |
|---|---|---:|---:|
| `e5634f7` | build: host device objects strip-pinned so `-Ddebug-info` builds | no change | no change |
| `e5fb043` | tran: vector `rebaseCurrent`, swap per-state history | -1.08% | -1.88% |
| `4cd2ef6` | tran: comptime Method in `stepBound`/`advanceCurrent` | -0.76% | -1.31% |
| `0100c06` | eval: host Sink holds `q_tape` pointer | -0.54% | -0.85% |
| `eebea9f` | eval: `corr_live` via `anyNonzero` bit test | -0.56% | -0.43% |
| `fd1f202` | docs: profile, kept and dropped experiments | — | — |
| | cumulative | 126.41M -> 122.73M (-2.91%) | 373.54M -> 357.11M (-4.40%) |

inverter_chain_256: 4912.95M -> 4761.73M (-3.08%). Tests: 299/299 unit,
correctness 518 pass / 98 fail, the same set as baseline. Wall time was not
usable: A/A noise on the shared machine was 5-20%. `zig build bench` needs
VACASK (`nix develop .#benchmarking`), not run.

## Uncommitted / in progress

None.

## Left

- `stepBound`: constant-operand `@max` as a plain `maxpd` select (exact,
  ~0.25% on parallel_inverters_100). The data-data maxes would change NaN
  behavior; leave them.
- The remaining time is generated physics (eval, limit, updateState, evalQ) and
  the solver (owned by the solvers agent). The scatter is ~4 instructions
  per stamp against a frozen tape.
- `builder.applyKv` `mem.eql` scan: 1.4% of mos6_inverter, prep only.

## Profile (base bcc13b3, self Ir unless inclusive)

| Pass | mos6_inverter | parallel_inverters_100 |
|---|---:|---:|
| Whole process | 126.41M | 373.54M |
| Device eval + scatter (inclusive) | 54.5% | 55.8% |
| Sparse LU factor (inclusive) | 8.8% | 6.5% |
| Limiting | 7.2% | 8.7% |
| State staging (`updateState`) | 6.7% | 4.4% |
| Charge re-eval (`evalQOnly`) | 5.3% | 5.8% |
| LTE `stepBound` | 2.7% | 4.7% |
| Sparse LU solve | 2.6% | 2.7% |
| `simulateInto` self | 1.5% | 2.4% |
| `advanceCurrent` | 0.9% | 1.5% |
| `finalizeStep` self | 1.0% | 1.2% |
| DC OP (inclusive) | 4.3% | — |
| Parse + prepare (inclusive) | 4.0% | 1.7% |
