# ESPice — open work (2026-09-09)

State after the SPICE audit: **170 PASS / 15 FAIL** vs ngspice 44.2 (264
fixtures), espice faster-or-equal on **183/229 timed (80%)**, mean **1.79×**.
Full mechanism log: `docs/spice-audit-2026-09.md`.

**2026-09-09, device evaluation measured against ngspice rather than against
its own past** (`docs/device-eval-vs-ngspice-2026-09.md`). ngspice 44.2 rebuilt
from source with symbols so `MOS1load` is attributable. On
`scaling/parallel_inverters_100`, same deck, callgrind: espice was **2,403 Ir
per MOS1 instance evaluation against ngspice's 759**, at the SAME Newton
iteration count (1352 vs 1319) — the deficit was never the solver, and RESULTS.md
agreed (every MOSFET-dense fixture at 0.4-0.5x, every linear one winning).
Three structural causes fixed; **-35.4% total instructions, output
bit-identical**, `parallel_inverters_500` wall clock 0.45 s -> 0.29 s against
ngspice's 0.24 s (0.53x -> 0.83x). Device MATH is now 634 Ir against ngspice's
759 for its whole load; what remains is scatter bookkeeping, itemized in that
doc.

VerA lives on branch `ddt-capform`; espice on `spice-audit`. Gates: espice
`zig build test` 398/400 (2 BJT failures pre-date this work — verified
identical with the Jacobian pattern forced dense); VerA `zig build test`
252/253 (§5.6.5 collapse-hook pre-exists) + `zig build torture` 1239/1242 (the
3 are the untracked WIP `$limit` fixtures, which fail without the change too).
Iteration builds: `-Dgpu=false` (4.5 min, one GPU model instead of 38; NOT a
shipping or bench configuration). `-Ddebug-info=true` still SEGVs the Zig
0.16.0 host `build-exe`; device modules no longer carry DWARF at all.

---

## REGRESSION — GPU wedges on the largest layout fixture

`--gpu` on `scaling/parallel_inverters_2000`, `ZP_TRAN_STATS=1`, same binary:
CPU is 595 accepted with `rej[newton=0]` on every run; GPU with the dense
Jacobian was 593-597 / `newton=0-2` / 0 failures in 16 runs; GPU with the
structural pattern is 599-622 / `newton=6-31` / **3 failures in 8**
(`DT UNDERFLOW (newton) dt=5e-19` -> `TimestepTooSmall`).

The defect underneath is older: the GPU accumulates the planes with
`@atomicRmw(.Add)` in unspecified order, and the Vdd branch-current row is the
sum of 2000 nearly-cancelling currents. `ZP_NEWTON_DEBUG=1` on a `.op` cut of
the deck shows CPU `-7.275957614183426e-9` vs GPU `-7.225480658235028e-9` at
iterate 2 — 0.7% relative — with every other unknown agreeing to ~10 digits.
Stable at 100 and 500 instances; fan-in dependent. This pass only changed which
way the chaos falls (comptime stamp count -> NVPTX regalloc/FMA contraction);
CPU output is bit-identical and matrix nnz is unchanged at 10,011 both ways.

**2026-09 follow-up: reproduced directly, and the failure chain is closed.**
`ESPICE_GPU_EVAL_CHECK=1` (`gpu_context.evalCheck`) replays the device half at
the SAME x and diffs the planes. Eval reads the lim plane and never writes it,
so the two replays have byte-identical inputs and the only variable is atomic
order. Measured worst gap, by fan-in into one plane cell:

| fixture | contributors per row | worst \|Δplane\| |
|---|---|---|
| `scaling/rc_ladder_10k` | 2-3 | none — reproducible |
| `scaling/parallel_inverters_100` | 200 | 1.0e-12 on `g[1]`=3.05e-2 |
| `scaling/parallel_inverters_2000` | 4000 | 3.6e-10 on `g[1]`/`rhs[1]` |

The chain from there: `|F|` at the `vdd` node floors at 1e-11..1e-10 (CPU floors
at 2e-16, and 8-thread ParEval — a different summation order — also floors at
1e-20, so it is reproducibility and not accuracy that differs). The LU maps that
row 1:1 onto the Vdd BRANCH-CURRENT unknown, whose value at that instant is
~2.5e-9 A, so `finalizeStep`'s delta gate allows `reltol*2.5e-9 + abstol` =
1.25e-12 and sees 1e-11..1e-10: `why=delta`, `scaled=10..80`, every iterate,
forever. Ten Newton rejects, dt halves ~30 times, `TimestepTooSmall`. A branch
current is the worst possible place for this to land — its tolerance is set by
its own nanoamp magnitude, not by the 0.26 A the rail actually carries.

Note the gap is ~2 orders LARGER than a naive `N*eps*max_partial` bound on the
same values predicts, which is worth a look when the fix below is written: pure
reordering of these magnitudes should not reach 3.6e-10.

- [ ] **Deterministic GPU scatter.** Replace atomic accumulation with a
      fixed-order segmented reduction. The scatter tape is frozen at setup, so
      its transpose is: build CSR `(destination -> contribution list)` once at
      `finalize`, have the eval kernel write each contribution to its own slot
      with no atomics, reduce each destination in index order, pairwise or
      Neumaier-compensated on high-fan-in rows. Deterministic, removes the
      atomic contention two previous audit passes spent effort mitigating, and
      the compensation is the half that buys accuracy rather than only
      reproducibility. Until it lands, `--gpu` is unsafe above ~1000 instances.

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

## Accuracy — edge-phase only (max fails on one edge sample)

ngspice's own coarse LTE grid disagrees with itself below the comparator's
edge window; espice resolves the edge, the max-sample lands mid-transition.
Closing these is **tran-grid matching (a policy choice)**, not a model/solver
bug. Meyer averaging is NOT the mechanism for any of them — see the closed
item at the bottom of this section.

- [ ] ensemble/pvt_corners (max 9.1e-2, rms 3.9e-3 — note the rms is over the
      1e-3 gate too, so this one is not purely edge-phase). Meyer caps are
      *identically zero* here: the deck gives no TOX and no CGSO/CGDO/CGBO, so
      ngspice's `MOS1oxideCapFactor` is 0 (`mos1temp.c:61`) and so is
      `mos1.va`'s `coxp`. The only gate capacitance is `CL = 100f`. What is
      left is `.tran 10n 20u` against a 10 ns PULSE edge — ~1 output point
      spans the transition.
- [ ] scaling/parallel_inverters_2000 (1.2e-2 / 5.8e-4)
- [ ] devices/mos6_inverter (1.5e-2 / 2.2e-3), devices/hfet_inverter (9.8e-2 / 5.9e-3).
      Measured directly (VerA 50a69da): at tmax=2ps BOTH engines converge to
      the same v(4) edge, 1.0874 ns; espice's coarse grid is 0.7 ps off it,
      ngspice's is 9.6 ps. The metric is scoring ngspice's own grid phase.
- [ ] vacask/mul (1.5e-2 / 8e-5), ngspice/mosamp (5.6e-2 / 1.9e-2 — ngspice
      runs it ~100× harder; frame-following limiter already removed the wedge)
- [x] ~~Underlying lever for the whole class: **per-device-state LTE** instead
      of per-node summed-q-plane in `stepBound`~~ — DONE 2026-09-07. It was a
      lever for a NARROWER class than this line claimed: 151 PASS / 7 FAIL is
      unchanged and pvt_corners, parallel_inverters_2000 and hfet_inverter are
      **bit-identical** before and after, so the four fixtures above are NOT
      this. 9 fixtures improved (txl2_3_line 2.3x, ltra2 12x, fourbitadder 10x,
      mos1_large_signal 8x, mosmem 3.5x), 3 regressed (kinduc 1.5e-8 -> 2.8e-4
      but still PASS at 36x margin, mos6_inverter 1.7e-2 -> 3.3e-2, txl1 +5%).
      `ZP_NO_QTAPE=1` is the per-row oracle on a live binary; `ZP_TRAN_STATS=1`
      prints `n_qt`. Mechanism and the three named divergences (per-terminal vs
      per-`ddt`, kinduc's extra states, GPU keeps per-row) in
      `docs/analysis/transient-integration.md`.
- [x] ~~Meyer capacitance averaging in the MOS models~~ — DONE, `a7a3f70`
      (espice) on VerA `6cfafc4` `$prev` / `50a69da` path-integration. mos1/2/3/6/9
      now spell ngspice's `capgs = state0 + state1 + overlap` exactly
      (`mos1.va:347-349`, `mos2.va:486-488`, `mos3.va:488-490`, `mos6.va:392-394`,
      `mos9.va:402-404`), unswapping the mode before averaging as ngspice's
      device-frame state slots do, with the OP-exit commit reproducing the
      MODETRANOP `2*half + overlap` branch. hfet1/hfet2/mes/mesa correctly do
      NOT average — `hfet2load.c:231` is plain `q += C*(v - v1)`, which is what
      the bare `C*ddt(V)` path lowering already emits.

## Accuracy — documented architectural

- [x] ~~**tline/txl2_3_line** — CKTterr runs per matrix ROW where ngspice runs
      per device STATE~~ — 1.23e-2 -> 5.40e-3 max, 7.30e-4 -> 3.54e-4 rms, and
      2.3x faster. It was never blocked by "the frozen single-plane q layout at
      the GPU boundary": that claim was wrong. Nothing needed unfreezing,
      because the per-contribution index space ALREADY EXISTED and nobody had
      noticed — `engine.buildTapes` writes `rhs_idx[id*n_u + ru]`, a dense
      (instance, unknown) array whose VALUE is the row, i.e. exactly the
      state->node map. The tape stores `qv` on that same index, host-side.
      What it actually cost: one nullable fn pointer on the cold `Hooks`
      vtable. Planes, u32 tapes, CSC pattern, Model/Instance PODs and
      `DeviceKernel.run`'s signature are byte-identical; the `layoutHash()`
      bump re-keys the FastVAF `.so` cache once, which is that hash's job.
- [x] ~~**per-`ddt` LTE states**~~ — MEASURED AND DECLINED 2026-09-10,
      `docs/perf/lte-2026-09-10.md`. The description was right (VerA emits
      `D.q` per device UNKNOWN, so a MOSFET's `qgs+qgd+qgb` arrive pre-summed
      on the gate where `MOS1trunc` terrs them separately); the VALUE was not.
      Refining the index space is a step-count knob, not an accuracy-per-step
      knob: `ZP_NO_QTAPE`'s per-row and the default per-state trace the SAME
      accuracy-vs-steps frontier on both mosamp and mos6_inverter (trtol swept
      7 → 0.02, scored against grid-converged references), so the next
      refinement has no reason to behave differently. And the "11x steps" is
      ngspice's cost, not correctness's — on mosamp espice's frontier
      DOMINATES ngspice's by 4-9x steps at equal rms. The one place ngspice is
      genuinely ahead (mos6_inverter, ~2.5x steps) ends in an ngspice error
      floor at 3e-4 rms that espice goes through. Not worth a device-ABI
      event; `ngspice/mosamp` and `devices/mos6_inverter` stay FAIL as a
      stated trade.
- [ ] **devices/kinduc over-split** (1.53e-8 -> 2.75e-4, PASS, 36x margin) —
      espice gives a `K` card its own charge states on the inductors' branch
      rows; ngspice folds the mutual flux into the single `INDflux`
      (`indload.c:70-77`, `MUT` has no `MUTtrunc`), so ngspice's candidate IS
      espice's row sum. `CKTterr` is homogeneous of degree zero in q, so the
      extra state binds at full strength however small it is — measured
      per-state/per-row 2.75e-4/1.53e-8 at k=0.99 down to 6.17e-5/2.02e-12 at
      k=0.001, gap independent of coupling. Fix = teach the host that a K
      card's charge belongs to the inductor's state; deliberately NOT done, it
      is a device-type special case for a passing fixture.
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
      REVISED 2026-09-09: partly false for the MOS family. Four of mos1's six
      `pow` were the junction depletion charge of a device with no junction
      capacitance, which `mos1load.c:567,628` guards and `mos1.va` did not.
      Guard added (also mos6/mos9); `evalQ` 1,249 -> 634 Ir. What is left after
      that IS the per-iterate physics.

### Device-eval bookkeeping — the remaining gap to ngspice

espice is 1,547 Ir per MOS1 instance evaluation against ngspice's 759, and the
device MATH is already cheaper (634 vs 759). Everything below is the difference,
itemized from `callgrind --dump-instr=yes` over the eval symbol with the buckets
mapped through `objdump`. Full derivation: `docs/device-eval-vs-ngspice-2026-09.md`.

- [ ] **The 8x8 Jacobian is materialized before it is scattered.** `evalQ`
      returns `[n_u]S` for both halves — 32 ymm of live derivative against 16
      architectural registers, so the frame spills (offsets to `0x7e0`,
      `vmovapd 0x4c0(%rsp)` on the scatter path). Scattering each row as it is
      produced fixes it and needs a different device entry point.
- [ ] **`zPnjlim` evaluates three `@log` libcalls unconditionally.** VerA
      `src/backend/limit_kernels.zig`, branchless per simd-first T7 — but the
      damping arm is dead on ~all iterates, and on the host each dead arm is a
      **libcall**, not a select. mos1 calls it twice, so six `log`s per MOSFET
      per Newton iterate. Ablation (`ZP_NO_LIMIT` / `ZP_LIM_NOCALL` gates,
      2026-09-09): `log` is **56.58M Ir = 8.02%** of
      `scaling/parallel_inverters_100` and **every one of those calls comes
      from `zPnjlim`** — the symbol vanishes entirely under either gate while
      the mos1 core keeps running. Guarding the arm with `if (comptime !k_dev)
      if (!damp) return floored;` — the same host/device split `sel` already
      uses — measured **704.92M -> 619.03M (-12.2%)** on
      parallel_inverters_100 and **248.51M -> 224.79M (-9.5%)** on
      devices/mos6_inverter, raw output BYTE-IDENTICAL on both, Newton
      iterations unchanged (1352, 595 accepted). Bit-identity is structural
      (the early return IS the `damp == false` arm of the final `sel`) and was
      checked two ways: VerA's own oracle differential test passes, and a
      4M-draw direct diff of both spellings hits the damping arm 617,209 times
      with 0 bit mismatches. **The change is VerA's; espice needs no edit.**
      Same lever exists for `zFetlim`/`zLimvds` (no libcalls, so smaller and
      less clear-cut — the clamp fires often on a switching inverter).
- [ ] **Two device walks per Newton iterate — priced, and the fusable half is
      small.** `applyLimits` (`limitRange`, re-gathers all `n_u` unknowns) then
      `evalRange`. ngspice limits inline in `MOS1load` — one walk. The 312
      Ir/instance figure above conflated the walk with `D.limit` itself.
      Ablation splits it: whole limiting machinery **612 Ir/MOS/iterate
      (23.5%)**, of which `D.limit`'s BODY is 515 and the second gather +
      `setLim` + `evalRange`'s `lim`/`corr` read is **97 Ir (3.7%)**. So fusing
      the walks — which touches the Newton contract in `solvers/converger.zig`
      and changes WHICH iterate gets clamped — buys 3.7%, while the `zPnjlim`
      item above buys 12.2% for four lines. Do that one first; after it the
      limit pass is 204 Ir/MOS/iterate against ngspice's 52.
- [ ] **Post-accept `ckt.eval(cur, t)` is a full extra device pass per accepted
      step** (`analysis/tran/tran.zig`, the `has_state_q` q-refresh). 595
      re-evals against 1352 Newton evals = **+44% device passes, ~113M Ir =
      16%** of parallel_inverters_100 (marginal cost measured at 952
      Ir/instance/pass via a `ZP_NO_REEVAL` gate, which agrees with kernel 754
      + stamp 195). Correctness-required and already gated off once — see the
      comment at the call site. It reads only `q_vec`/`q_tape`, never the
      Jacobian or residual, so the real fix is a q-only scalar pass (no
      `Dual(8)`, no G/C scatter) rather than deleting it; bit-identity of the
      value path between `Dual(n,f64).v` and a plain scalar `S` is the thing to
      prove first.
- [ ] **Parameter-only prologue runs per evaluation.** VerA's `pcClass` returns
      false for `.phi`/`.branch`, so an `if ($param_given(...))` ladder is not
      hoistable, and `pcConsider` requires a libm-class op, so `cox`/`beta`/
      `f2d..f4s` are recomputed every iterate. 141 Ir/eval (measured as the
      LICM-allowed vs pointer-laundered delta in `/tmp/devbench`). ngspice does
      all of it once in `MOS1temp` — called **1** time for the whole run.
      Wants either a param-only REGION hoist (phi with param-only incoming and
      param-only controlling conditions) or if-conversion before the hoist,
      since `pcClass` already handles `.select`.
- [ ] **`-Djac-f32=mos1,mos6` — MEASURED 2026-09-10, a win, not yet a default.**
      Full numbers and method in `docs/perf/jac-f32-2026-09-10.md` (two real
      builds, callgrind Ir, `ZP_TRAN_STATS`/`ZP_OPDBG` iteration counts).
      `parallel_inverters_100` **466.4M -> 436.6M (0.936)** with the iteration
      count FLAT (1352 -> 1349 NR, 613 -> 613 attempts, 595 -> 595 points);
      `parallel_inverters_500` reproduces it at 0.935. mos1 `evalQ` 955 -> 865
      Ir per MOSFET per iterate (0.904); `devices/mos6_inverter` 0.949 whole
      run, 1059 -> 954 per eval. The "cost is iteration count, not the answer"
      claim HOLDS: 60 mos1/mos6/bsim4/diode fixtures all pass the suite rule
      (22 bit-identical, worst RMS 2.9e-4), and no PASS/FAIL verdict moves
      against ngspice on any of 196 fixtures.
      The win is `n_u`, not model size: `n_u=8` (mos1/mos6) is the only width
      where `@Vector(n,f32)` saves a register. **`diode` (n_u=4) is 4-5% SLOWER
      in the kernel and `bsim4va` (n_u=18) is exactly 0.0%** — three decks,
      -0.04% on the kernel — so §11's "mixed precision is the prerequisite for
      re-admitting bsim4-class models" has no CPU half.
      Blocker on making it default: **`ngspice/mosmem` is +13.7%**. The f32
      Jacobian makes plain Newton fail on that latch's operating point
      (`ladder: plain conv=true` -> `false`), forcing the whole gmin ladder —
      OP 50 -> 144 NR iterates. Answer still fine, time is not. Prerequisite is
      a stiff-MOS corpus: there is no MOSFET deck under `convergence/` or
      `adversarial/` at all, so the only counter-example was found by accident.
      No interaction with `direct.zig`'s `iter_refine_steps`: the Jacobian
      widens back to f64 at `ddxAt`/`grad` before the scatter, `Solver` is
      `SolverT(f64)` everywhere, refinement is 0 outside one unit test, and
      refining an inexact-Newton step converges harder onto the perturbed
      Jacobian anyway.
- [x] **`canDedup` is dead for every built-in** — DELETED (2026-09). Not just
      unreachable in practice, unreachable by contract: `canDedup` requires
      `PrepCache`, which is absent from VerA's `allowed_pub_decls`, so
      `rejectStrayPubDecls` refuses to compile a generated device that declares
      it — and VerA's codegen never emits it anyway. Measured before the
      decision: 100 identical instances cost 2,589 Ir/instance and 100
      deliberately varied ones 2,542, a 2% spread where a live cache would show
      ~99% hits. `PrepCache`/`computePrep`/`evalFromPrep`/`qFromPrep`,
      `tryCached`/`store`/`storeQ`, `eval_cache_*` and the `set_lanes` hook are
      gone; making it reachable would have to start in VerA.
- [x] **Small-circuit `--gpu` no-decline** — DONE (2026-09). Cause was not the
      resident path: fourbitadder's whole GPU run is 0.36 s against a 0.04 s
      circuit, i.e. ~all of it is the fixed ~340 ms driver setup (cuInit +
      primary context + module JIT), which no per-iteration `work` proxy can
      see. The gate was also stale — the nonlinear x16 weight was added to
      `work` without moving the threshold, so it had been admitting circuits
      16x smaller than the number it was derived from. `default_min_work`
      200_000 -> 3_200_000, with the wall-clock table in `gpu_context.zig`.
      Explicit `--gpu`/`--backend cuda|hip` bypass the gate entirely now.
- [ ] **Per-model LLVM objects** — `buildsplit` branch (unmerged,
      bit-identical): caching granularity so a one-model edit doesn't
      re-optimize all 38. Strip already took the headline build-time win
      (737 s → 184 s); this is the incremental-rebuild win.
- [ ] **GPU re-admit big models** — `--outline-chunk` (VerA, default off)
      compiles NVPTX 70–110× faster with 26–68 MB PTX vs 1.2 GB; currently
      moot at the 80 KB `gpu_max_model_bytes` cap. Raising the cap + outlining
      the whales is the path to GPU-evaluating bsim4-class layouts.
      **Do not do this on the current hardware.** `--outline-chunk` fixes BUILD
      time, and build time is not what the cap is defending against: the cap's
      own measurement is that bsim4's PTX carries 142_990 f64 ops at ~16%
      occupancy on a part whose f64 rate is 1/64 of its f32 rate — 152.7
      GFLOP/s against the CPU's 1449. Re-admitted, those kernels lose at RUN
      time however fast they compile. The prerequisite is the §9 mixed-precision
      work (which needs VerA to reach `.optimized` float mode), or an FP64 part.
      UNMEASURED here: the direction follows from `docs/gpu-device-eval.md`'s
      existing numbers, not from a new re-admission run.

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
