# ESPice — open work (2026-09-07)

State after the SPICE audit: **170 PASS / 15 FAIL** vs ngspice 44.2 (264
fixtures), espice faster-or-equal on **183/229 timed (80%)**, mean **1.79×**,
GPU wins layout netlists (parallel_inverters_2000 2.07× vs CPU). Full
mechanism log: `docs/spice-audit-2026-09.md`. Every item below is a NAMED,
measured residual — no catastrophes, no known regressions.

VerA lives on branch `ddt-capform`; espice on `spice-audit`. Gates: espice
`zig build test` green (the `test-devices --listen` line is a pre-existing
build-runner IPC flake — passes 9/9 standalone); VerA `zig build test`
248/249 (§5.6.5 collapse-hook pre-exists) + `zig build torture` 1237/1237.
Profiling builds: `-Doptimize=ReleaseFast -Ddebug-info=true` (Release strips
DWARF by default).

---

## Accuracy — real model gaps (vacuous passes the session's new rigor exposed)

These flipped PASS→FAIL only because the comparator got honest: branch
currents `i(...)` are compared now, and `.dc … TEMP` actually sweeps now.
The models were always wrong on these quantities.

- [ ] **diode XTI/EG/vj/cjo temperature port** — `devices/diode_temp` i(v1)
      ~2.3e-2 across −40..125 °C. Inline `IS(T)` alone REGRESSED it (4.7e-2):
      ngspice `diotemp.c` also scales vj/cjo and uses a temperature-dependent
      `egfet = 1.16 − 7.02e-4·T²/(T+1108)`, not the flat EG param. Full port,
      verified point-by-point. `src/devices/models/diode.va` header carries
      the state. (task #20)
- [ ] **bsim1 / bsim2 drain current** — `devices/bsim1` i(vds) **2.1e3**,
      `devices/bsim2` 0.96. Oldest Berkeley MOS; the voltage-measured error
      was fixed earlier but the current is off by orders. Deep work vs
      `b1eval.c` / `b2eval.c`. Note bsim2's binary-vs-source ~1.38× saturation
      discrepancy (needs a from-source ngspice build to disambiguate). (#21)
- [ ] **ngspice/mosmem** (3.1e-2), **power/rectifier** (4.5e-2),
      **vbic_forced_output** (4.8e-3), **fourier/square_harmonics** (0.10) —
      each newly-compared on a current or harmonic column. Triage per fixture;
      some may be edge-phase (below) rather than model error.

## Accuracy — edge-phase only (RMS passes, max fails on one edge sample)

ngspice's own coarse LTE grid disagrees with itself below the comparator's
edge window; espice resolves the edge, the max-sample lands mid-transition.
Closing these is **tran-grid matching (a policy choice)**, not a model/solver
bug. Confirm each stays RMS-passing before spending on it.

- [ ] ensemble/pvt_corners (max 9.1e-2, rms 3.9e-3)
- [ ] scaling/parallel_inverters_2000 (max 1.2e-2, rms 5.8e-4)
- [ ] devices/mos6_inverter (1.5e-2 / 2.2e-3), devices/hfet_inverter (9.8e-2 / 5.9e-3)
- [ ] vacask/mul (1.5e-2 / 8e-5), ngspice/mosamp (5.6e-2 / 1.9e-2 — ngspice
      runs it ~100× harder; frame-following limiter already removed the wedge)
- [ ] Underlying lever for the whole class: **per-device-state LTE** instead
      of per-node summed-q-plane in `stepBound` (`src/analysis/tran/tran.zig`).
      Same root as txl2 below.

## Accuracy — documented architectural

- [ ] **tline/txl2_3_line** (max 1.2e-2, rms 7.3e-4) — CKTterr runs per matrix
      ROW (summed q-plane) where ngspice runs per device STATE; an 83 fs seed
      difference on a shared node amplifies through the step ramp. Needs
      per-contribution q snapshots — blocked by the frozen single-plane q
      layout at the GPU boundary. Documented in
      `docs/analysis/transient-integration.md`.
- [ ] **devices/bsim4** (1.69e-3) — just over the 1e-3 rms line; BSIM4
      model-version delta vs ngspice's C.

## Solver

- [ ] **BSIMSOI floating-body row** — b4soi/b3soipd PASS (7.8e-4 / 3.3e-5) at
      resolvable junction params, but at DEFAULT params the body KCL row is
      atto-siemens and SparseLu threshold pivoting (pivot_tol·colmax, Gmbs
      ~1e-4 S in the same column) rejects its diagonal → dx_body garbage on
      cold mid-vds solves. ngspice survives via Sparse-1.3 diagonal-preferring
      Markowitz. Fix belongs in the solver: **row equilibration or
      isolated-tiny-row diagonal preference** in `src/solvers/`. Documented in
      `docs/spice-audit-2026-09.md`.

## Performance

- [ ] **Waveform streaming to the raw writer** (#13) — rc_ladder_100k is
      760 MB (ngspice 220 MB) after the 16×→2× capacity + no-double-buffer
      fix; full streaming (reserve header, patch npoints at end) closes the
      last ~3×. `src/analysis/tran/{tran,types}.zig`, `src/output/rawfile.zig`.
- [ ] **BJT/device transcendentals still per-iterate** — temp-hoist moved the
      temperature-only subtree out, but pow/log/exp on node-voltage remain the
      dominant eval cost (correctly — they ARE the per-iterate physics). Only
      lever left is fewer Newton iterates or GPU offload, not hoisting.
- [ ] **Small-circuit `--gpu` no-decline** — devices/fourbitadder under `--gpu`
      is 449 ms (CPU 130 ms): the nonlinear work-gate passes it but the
      resident path loses on a tiny circuit. Cosmetic (default CPU unaffected);
      bump the decline threshold or weight. `src/gpu_context.zig`.
- [ ] **Per-model LLVM objects** — `buildsplit` branch (unmerged,
      bit-identical): caching granularity so a one-model edit doesn't
      re-optimize all 38. Strip already took the headline build-time win
      (737 s → 184 s); this is the incremental-rebuild win.
- [ ] **GPU re-admit big models** — `--outline-chunk` (VerA, default off)
      compiles NVPTX 70–110× faster with 26–68 MB PTX vs 1.2 GB; currently
      moot at the 80 KB `gpu_max_model_bytes` cap. Raising the cap + outlining
      the whales is the path to GPU-evaluating bsim4-class layouts.

## Parser / frontend / models not yet ported

- [ ] **b3soifd / b3soidd** (MOS levels 55/56) — SKIP, no model. Level 57 (PD)
      is ported and passes; FD/DD are the same B3SOI family, mirror the port.
- [ ] **psp103** (vacask/c6288, vacask/ring — level 1040) — SKIP, no model.
- [ ] **hisimhv** — SKIP (compile/size); investigate.
- [ ] **verilog/inverter (.v)** — SKIP, FastVF (digital HDL) loader not wired
      in `src/devices/loader.zig` (only `.va` via FastVAF today).
- [ ] **scaling/inverter_chain_{256,1k,4k}** — SKIP, but ngspice ALSO aborts
      them ("timestep too small … mn103"). Parity, not a gap — leave unless a
      convergence improvement makes espice beat ngspice here.

## Unmerged branches to land or prune

Worktrees beside the repo (some clear the shared zig-cache — disk-heavy):
`../espice-buildsplit` (per-model objects, bit-identical), `../espice-urc`
(merged), and the `wt-*/` pairs (limit/meyer/soi/gpu/simd/hoist — all merged
into spice-audit/ddt-capform). Safe to `git worktree remove` the merged ones
to reclaim disk.

## Rules for this codebase (from CLAUDE.md — do not relearn the hard way)

- Baselines via `git worktree`, NEVER `git stash`; worktrees sit BESIDE the
  repo (relative deps need `../gompute`, `../VerA`).
- `zig build bench` is EXPENSIVE — verification only, never experimentation;
  run single fixtures (`zig-out/bin/espice -b -r out.raw deck.sp` vs
  `ngspice -b -r out.raw deck.sp`) while iterating.
- Every perf claim ships a before/after in the commit; every negative result
  is documented with its rerunnable rig (see `docs/solvers/refactor-tape-2026-09.md`).
- VerA codegen changes: `zig build torture` (1237 fixtures) is the oracle;
  bit-identity of eval before/after is the contract for any non-behavioral change.
