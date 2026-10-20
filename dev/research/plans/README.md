# Lane-batching plans: phases 3-6

One plan per GitHub issue. Each plan holds:
- the design;
- every edit as concrete Zig 0.18 code, in dependency order;
- the W = 1 identity and codegen-probe plan;
- the tests;
- the risks;
- an effort estimate per step.

The plans were written against main 06cff37f, and nothing in them has been
built or run. Spots that only a build or a GPU run can settle are marked
**CHECK** (and **API?** for Gompute calls I could not confirm).

| Phase | Issue | Plan | Steps | Effort |
|---|---|---|---|---|
| 3. Transient lanes (CPU) | #207 | [phase3-transient-lanes.md](phase3-transient-lanes.md) | 5 code edits, 4 test items | ~7 d |
| 4. GPU lane backend | #208 | [phase4-gpu-lanes.md](phase4-gpu-lanes.md) | G0-G10 (G10 deferred) | ~28-31 d (5.5-6 wk); G2 runs in parallel |
| 5. AC family | #209 | [phase5-ac-lanes.md](phase5-ac-lanes.md) | 7 edits, 5 test items | ~4-4.5 d CPU; +1-1.5 wk for the GPU provider |
| 6. Periodic (shooting PSS) | #210 | [phase6-periodic-lanes.md](phase6-periodic-lanes.md) | 6 edits, 4 test items | ~3.5 d CPU; phase 6b (GPU only) +2-3 wk |

**Total: ≈ 9-10 engineer-weeks with every GPU follow-up, or ≈ 8.5 weeks
without phase 6b.**

## Shared decisions

These hold across all four plans:

1. **The GPU serves throughput, and the CPU lane path is its bitwise scalar
   oracle.**
   - CPU lanes stay off by default (`executor.lanesOn`, #211).
   - GPU lanes are decided once per Problem (`Config.gpu_lanes`): on for an
     explicit `cuda`/`hip`; under `auto`, on only for FP64-class devices
     (`fp64Ratio() <= 4`). So `auto` keeps the CPU on the RTX 4060 (E1:
     1.4-2x the 24-core CPU).
2. **Host control, backend numerics.** Every analysis keeps its per-lane
   decisions as scalar host code. The CPU runs that code unchanged per lane,
   and only Newton or the linear solve is batched. The GPU computes a whole
   round's numbers and answers the same calls from them.
   - Phase 3 splits `tran.zig` into a step machine (`Sim`).
   - Phase 4 G1 makes `Sim` generic over `Ops`, so the step control exists
     once.
3. **The `dc.zig` precedent.** Each laned analysis gets a pinned per-query
   state struct shared by its scalar `run` and a `runLanes(W, ctxs, opts,
   out)`. The executor gains one branch per kind, and
   `session.gather`/`sameLaneJob` admit the kind.
4. **`LaneSystem` gets per-lane hooks** (`hooks: [W]Hook`, phase 3 §2.1), and
   `beginSolve` touches only active lanes. Phases 5 and 6 assume this shape.
5. **GPU layout.** Lane-major (`i * N + l`) for everything touched per Newton
   tick, and lane-minor only for the round-level LTE tape ring.
   - One thread per lane walks its instances in tape order, writing straight
     into the lane's planes. There is no staging and no clear-and-reduce, as
     the owner asked after E1.
   - Lanes innermost: a warp holds 32 lanes of one instance.
   - Model rows are deduplicated by bytes over (instance, lane).
6. **No codegen probe is added for code that stays scalar.** Phases 3-6 make no
   scalar arithmetic W-generic: the per-lane scalar code runs as is, and
   `newtonLanes` is already probed. Each plan's identity gate is the corpus
   byte-identical (`tools/lane_diff.py`, phase 3 §4.4). The GPU kernel bodies
   are restatements with bitwise host oracles (`LaneSolver`,
   `converger.updateAndNorm(1)`, `integrator.stepBound`/`companionAt`).

## Order and dependencies

```
phase 3 (CPU transient lanes)
  2.1 LaneSystem hooks ─┐
  2.2 Sim transplant ───┼─> 2.3 Run/runLanes ─> 2.4-2.5 executor/session ─> tests, lane_diff.py gates
                        │
                        └─> phase 4 G1 (Sim over Ops; CPU bitwise gate)
                                 │
phase 4   G0 (gpu_host_only) ·· G2 (bsimcmg frame/spills, GPU box, parallel)
          G3 lane kernels/model ─┐
          G4 lane_kernels.zig ───┼─> G5 device root ─> G6 gpu_lanes.zig ─> G7 runGpuLanes ─> G8 policy/schedule ─> G9 parity + throughput
                                 │
phase 5 (needs phase 3's executor/session arms; GPU provider needs G6)
phase 6 (needs phase 3's LaneSystem shape; 6b GPU needs phase 4 + phase 5's stacked fill)
```

- **Phase 3 → phase 4** is a hard dependency:
  - G1 rewrites phase 3's `Sim`;
  - `runGpuLanes` copies `runLanes`' round loop;
  - the CPU lane path is phase 4's parity oracle.
- **Phase 5's CPU part** needs only phase 3's executor/session arms. It can run
  in parallel with phase 4 (a second engineer). Its GPU provider extends G6.
- **Phase 6** reuses phase 3's per-lane hooks and `newtonLanes`, not `Sim`:
  shooting PSS integrates each period with its own fixed-step trapezoid and
  never calls `tran.simulate` (see the plan's §0 correction to the issue). The
  corpus has no swept `.pss` deck, so its plan adds swept tests in place of
  the §11 corpus gate. HB/MHB/PAC/pnoise stay ungrouped on the CPU: their
  masked forms buy nothing there and move to a GPU-only phase 6b.

## Critical path to a usable GPU backend

For one engineer:
- phase 3: 2.1 → 2.2 → 2.3 → 2.4-2.5 and gates (a)-(d), ≈ 1.5 weeks;
- phase 4: G1 → G3 + G4 → G5 → G6 → G7 → G8 → G9, ≈ 5 weeks;
- **≈ 6.5 weeks in all.**

- **G6** (`gpu_lanes.zig`: packing, Newton graphs, peel, probe, apply) is the
  long pole at 7-9 days. Land it in two milestones: Newton-only parity at one
  fixed step against `newtonLanes`, then rounds.
- **G2** (frame and spill reduction) and **G0** (empty `gpu_host_only`) run
  beside the critical path on a GPU box.
- Throughput is first measured at G9. The A100/H100 numbers stay projections
  until someone runs E1 or G9 on one.

## Top risks, across plans

1. **Phase 3's transplant.** About 450 lines move into `Sim`, and every
   mutated-local read must see the same value. The corpus byte-identity gate
   (lanes off, old binary against new) catches any slip. Review it side by side.
2. **GPU wave quantization.** A thread per lane needs N ≥ ~2x the card's
   resident threads to fill it. That is 16k+ on the 4060 at 17% occupancy, and
   more on an A100. The cap defaults to 16384 and memory sets N; the lane path
   has no staging, so ~40k lanes of the chain fit in 8 GB. The fallback
   (colored instances plus hub staging) is specified in phase 4 G10.
3. **The GPU charge re-read** is one extra eval per round, ~+44% of evals on
   the chain, the same cost today's GPU path pays. Fusing `acceptQ` into the
   lane state kernel (G10) is the follow-up, gated on G9's measurement.
4. **CPU/GPU grid desync.** Last-bit differences can flip one accept/reject,
   and the grids then diverge within tolerance. The parity test must compare by
   interpolation (the runner's `sample` path), not row by row.
5. **Build cost.** The lane kernels double each model's device code (ptxas
   ~2x). `-Dgpu-lanes=false` keeps CI as today. Emptying `gpu_host_only` adds
   asmhemt/bsimsoi_va at ~180 s and 11 GB each.
6. **Phases 5 and 6 buy nothing on the CPU by design.** They exist as the
   oracle for later GPU providers. With `--lanes --jobs=N` they serialize W
   queries onto one worker, which is acceptable only because CPU lanes are off
   by default.
