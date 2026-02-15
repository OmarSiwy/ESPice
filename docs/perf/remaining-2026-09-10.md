# Remaining performance opportunities — handoff, 2026-09-10

Written at the end of a long optimization session. Everything here is either
measured or explicitly marked as an estimate. Read "Measurement hazards" first —
five separate wrong answers this session came from rig bugs, not from the code
under test.

## Where the numbers stand

| deck | espice | ngspice 44.2 (PATH build) | ratio |
|---|---:|---:|---:|
| `scaling/parallel_inverters_100` | 465,576,835 | 557,174,981 | **0.836** |
| `devices/mos6_inverter` | 153,490,575 | 166,331,933 | **0.923** |
| `scaling/rc_chain_500` | 79,097,457 | 179,877,040 | **0.440** |
| `scaling/rc_ladder_10k` | 1,178,022,498 | 2,918,358,824 | **0.404** |

Against a from-source ngspice (8.5% faster than the PATH build, see hazard 4):
pi100 **0.907**, mos6 **1.031**. mos6 against ngspice's fastest build is the
only remaining loss, and it is 3%.

Session arc on pi100: 754.9M → 465.6M (−38.3%).

## THE BUDGET IS STALE

The per-pass budget below was taken at pi100 = 507M and mos6 = 189M. Since
then the prefix-latch (−7.7%/−12.6%) and the LU reshape (−3.6%/−4.2%) landed,
so every percentage is wrong and the ORDERING may be wrong too. **Re-measure
before choosing a target.** It is included because it is the only map that
exists and the mechanisms are still accurate.

pi100 @ 507M — 1352 NR iters, 613 attempts, 595 points; n=105, nnz=511:

| pass | Ir | % | per MOSFET per NR iter |
|---|---:|---:|---:|
| MOS1 kernel + stamp | 277.4M | 54.7% | 1026 |
| limiting (gather 54.9M + `D.limit` 17.9M) | 72.8M | 14.4% | 269 |
| LU refactor | 38.8M | 7.65% | 143 |
| post-accept `evalQ` (RealFor q-only) | 29.6M | 5.8% | 110 |
| `updateStates` | 19.6M | 3.9% | 73 |
| `stepBound` LTE (1800-entry q-tape) | 16.7M | 3.3% | 62 |
| LU triangular solve | 14.9M | 2.9% | 55 |
| tran-loop self | 11.2M | 2.2% | 41 |
| parse + build + OP solve | 10.6M | 2.1% | — |
| memcpy/memset helpers | 8.4M | 1.7% | — |
| `finalizeStep` / `updateAndNorm` / `stateCtl` / `snapshotQTape` | 13.1M | 2.5% | 48 |

mos6 @ 189M — 884 NR iters, 320 attempts, 316 points; n=45, nnz=243:
kernel+stamp 52.9%, limiting 10.6%, LU refactor 9.2%, parse+build+**OP solve**
8.2% (that is the OP solve, not fixed overhead — process floor on a two-device
deck is 0.83M), `updateStates` 7.5%, post-accept `evalQ` 4.9%, LU solve 2.4%.

---

## Open opportunities, ranked by expected value

### 1. The device kernel — still >50% of both decks

mos1 `evalQ` was 754 Ir/eval before the prefix-latch; mos6 was 1224.6 → ~1164.
ngspice: MOS1load self 759, whole per-instance MOS1 evaluation 1053; whole
per-instance MOS6 evaluation 1138. Our figures contain **no stamping, no
limiting and no integration**, so the kernel-to-kernel gap is wider than the
raw comparison suggests.

Composition of the mos6 kernel at 1403 (before two fixes): Dual AD methods 583
(41.6%), model expressions 264, transcendentals 309, rest 96. The AD layer is
the biggest single line and nothing has touched it.

**Do not re-attempt derivative narrowing.** Settled with measurements:
on AVX2 every width ≤4 is ONE vector instruction, so narrowing popcount-2
values from 4 lanes to 2 saves zero; mos1's smallest *correct* lane universe is
**six** (the rd/rs series branches touch `{d,di}` and `{s,si}`), and
`@Vector(6,f64)` lowers to ymm+xmm — same FP count as 8, +145 shuffles.
Measured k=6: **1088 Ir, a 21% loss**. k=4 wins but is provably wrong: 3150 bit
mismatches at `rd=12, rs=9`. A contract `axpy` injector was added and reverted
— measured 2.95 instructions per component, not the ~1 that would close the
ledger.

Live sub-items:
- **`sel` still evaluates both arms** where the arms are cheap. In mos6 only 6
  `sel` sites exist and 4 are the Meyer ladder: converting them to branches
  measured **−8.8 Ir**. That is the ceiling for mos6; other models may differ.
- **`pcExpensive`'s libm-root filter** still blocks `grd`/`grs`/`czb*` from
  hoisting. Relaxed once already (`pcWorthAField`, 99bb324).
- Block-by-block against `/tmp/ng/ngspice-44.2/src/spicelib/devices/mos6/mos6load.c`
  found ngspice recomputes its own per-eval preamble with an apologetic
  comment, so we are not behind everywhere. Find the blocks where we are.

### 2. Limiting — `D.limit`'s body is 291 Ir per instance per iterate

ngspice's whole limiter ladder is 52. Probe passes isolated it: an extra
gather costs 2.13%, an extra `D.limit` costs **14.64%** — the body is ~79% of
limiting, the gather is not the problem, and the second read in `evalRange` is
under 1% because `corr_live` already needs those loads.

`zPnjlim` (7dd74a0) and `zFetlim`/`zLimvds` (baccc5a) now have host fast paths.
What remains is the generated `limit()` scaffolding and the per-unknown
gather/write around it.

**Fusing the two walks is worth 2.1% and is not separable from clamp ordering**
— with `lim_active` true, `old` is read from `lim_x`, which the pass itself
writes. Doubling the pass changes the raw output; that is the hazard, concretely.

`@call(.always_inline, D.limit, ...)` is a **regression**: +0.28% pi100,
+0.20% mos6, verified with two builds.

### 3. The dedup / eval cache is UNREACHABLE — wire it up or delete it

`canDedup(D)` requires `@hasDecl(D, "PrepCache")`, and `PrepCache` is **not in
`VerA/tools/contract.zig`'s `allowed_pub_decls`** — a device declaring it fails
validation. So `SinkT.dedup` is comptime-false for every device that can exist,
and `tryCached`, `hashVoltages`, `store`/`storeQ` and the whole per-lane eval
cache are dead code. `engine.zig:1093` says so itself.

This is the largest *unexplored* item in the tree. On
`scaling/parallel_inverters_2000` all 2000 nch instances see identical voltages
by construction, so a working dedup would collapse 4000 evaluations per Newton
iteration to ~2. Nobody has measured what fraction of real decks have repeated
bias points. Decide deliberately: implement, or delete the dead code.

### 4. `jac_rows` / `q_rows` — which residual rows are ever WRITTEN

~22 Ir/instance (14 reactive + 8 resistive). A patch was drafted
(`/tmp/vera-rows.patch`, likely lost to the `/tmp` wipe — regenerate it).

The invariant it exists to respect, which is easy to get wrong:
`jac_pattern`/`q_pattern` answer for the **derivative only**. A term whose
value depends on no unknown ORs zero into the column mask *while still writing
the row* — `isource` ships exactly that, `jac_pattern = {0,0}` with `eval`
stamping DC current into both rows. **A host that reads a clear pattern row as
"identically zero" deletes every independent current source in the netlist.**
The reactive failure is quieter: a `ddt()` of something varying in `t` and not
`x` would leave `q_tape` holding a frozen zero for a live state and `stepBound`
would silently drop a real LTE bound. The safe predicate is "row `ru` is ever
written", which the generator knows and does not emit.

### 5. Post-accept charge re-evaluation — 5.8% / 4.9%

Already improved by the `RealFor` value-only scalar (mos6 −2.3%; mos1 is a
wash because LLVM already dead-codes the gradient for a small core — the value
of the change is that "computes no derivatives" is now a property of the type
rather than of the optimizer).

Why it cannot simply be skipped, established properly: `converger.newton`
assembles at `x`, solves, and `finalizeStep` writes `x += dx` and returns on
convergence **without reassembling**. So the planes always hold `q(x_k)` while
the accepted point is `x_{k+1}` — limited or not, so `lim_x` is irrelevant here.
Consumers are the companion-RHS `i_prev`, `q_hist[1]`, and the per-state
`q_tape` that `stepBound` reduces over. `g_vals`/`c_vals`/`rhs` are dead.
ngspice tolerates the same one-correction gap and does not correct it; removing
ours takes `parallel_inverters_100` from 8.98e-3 to 1.49e-2 (PASS → FAIL).

The idea deliberately not pursued: extrapolate `q(x_{k+1}) ≈ q(x_k) + C·dx`
from the already-computed `c_vals`. Not byte-identical, and `c_vals` is summed
per matrix entry so it cannot produce the per-state `q_tape` that LTE needs.

### 6. `updateStates` — re-measure, it may already be fixed

Was 2.8× more per MOS6 instance than per MOS1 (556 vs 182 Ir **per converged
solve**, not per iterate — `converger.zig:289` moved it). Mechanism: it
re-enters the core at `R` to restage `ddt` arguments, and mos6's Meyer
partition needs the Sakurai–Newton saturation voltage, whose closure carried
two non-integer `pow`. Isolated conclusively — the same circuit re-carded to
LEVEL 1 costs 215 Ir where LEVEL 6 costs 556, and callgrind counted exactly
200,000 `pow` entries from mos6 and 0 from mos1.

**The shared-`ln` patch (542e9a0) removed those two `pow`.** Nobody has
re-measured `updateStates` since. Do that before anything else here.

Separately: only 3% of `updateStates` calls are discarded work (the 18
LTE-rejected attempts), so it is real per-solve cost, not waste.

### 7. The stamp — 61 scattered RMWs per instance for 21 real Jacobian entries

195 Ir/instance and it does not vectorize (AVX2 has no scatter; W=4 measured
196, i.e. 1.00×). Two approaches already priced and rejected:
- **Fusing the two `ru` passes**: −0.74% on mos6, **+0.28% on pi100**. Extends
  `out`'s live range across the charge stamps; pressure costs more than the
  shared addressing saves.
- **Contiguous staging + ordered reduction**: strictly worse on CPU. The hot
  loop does 37 stores, then the reduction needs 37 stage loads + 37 slot loads
  + the same 37 random RMWs — 74 extra memory ops per instance to move none of
  the RMW traffic.

The charge side is 32 of the 61 and `q_pattern` says only 4 rows and 16 columns
are live, so item 4 is the lever here, not a different loop shape.

### 8. Instance-axis SIMD — NO-GO, recorded so it is not re-proposed

End-to-end **1.17×** for de-branching 26 compact models, a second lane-parallel
ABI through `evalRange`/`Sink`, and an instance-sort pass. Two independent
killers: the sparse stamp is 195 Ir at W=1 and **196 at W=4**, and with
realistic branch arms the kernel gets **1.67× not 4×** because the scalar path
takes ONE junction `exp` and every lane path must take BOTH (mos6 has four such
branches). `lane_clean` is 12/38 today and **not one is a nonlinear
semiconductor model**; mos1 alone has 52 pin sites.

One caveat on the original no-go: part of its argument was that dedup already
collapses `parallel_inverters_2000`. That was **wrong** (item 3). The other two
killers stand.

### 9. `jac_f32` — MEASURED 2026-09-10: `docs/perf/jac-f32-2026-09-10.md`

`VerA/src/cli.zig:206` → `codegen.zig:1347` → `ARPice/build.zig:18,107` →
`engine.jacFloat`. `@Vector(8,f32)` costs 10 instructions where
`@Vector(8,f64)` costs 13 — ratio 0.77, which is exactly the 752/965 a forced
4-lane experiment produced. Residual stays f64; `layoutHash`, scatter tapes and
`jac_pattern` do not move.

Measured with two real builds (`-Dgpu=false` ± `-Djac-f32=…`), callgrind Ir,
`ZP_TRAN_STATS`/`ZP_OPDBG` iteration counts:

- **pi100 0.936** (466.4M → 436.6M) with the iteration count flat — 1352 → 1349
  NR, 613 → 613 attempts, 595 → 595 points. pi500 reproduces at 0.935. mos1
  `evalQ` 955 → 865 Ir per MOSFET per iterate; mos6 0.949 whole run,
  1059 → 954 per eval.
- "Cost is iteration count, not accuracy" **holds**: 60 fixtures pass the suite
  rule, 22 bit-identical, and no PASS/FAIL verdict moves against ngspice on any
  of 196.
- The win is **`n_u`, not model size**. `n_u=8` (mos1/mos6) is the only width
  that saves a register. `diode` (n_u=4) is 4–5% **slower** in the kernel;
  `bsim4va` (n_u=18) is **0.0%**, so §11's claim that mixed precision is the
  prerequisite for re-admitting bsim4-class models has no CPU half.
- **Not a default yet**: `ngspice/mosmem` is **+13.7%** — the f32 Jacobian
  makes plain Newton fail on that latch's OP, forcing the gmin ladder (50 → 144
  iterates). The tree has no MOSFET deck under `convergence/` or `adversarial/`,
  which is why that was the only counter-example and why a stiff-MOS corpus is
  the prerequisite.
- No interaction with `direct.zig`'s `iter_refine_steps`: the Jacobian widens
  back to f64 before the scatter, `Solver` is `SolverT(f64)` everywhere, and
  refinement is 0 outside one unit test.

### 10. Memory — two real items

- **`pc__` slots are model-level quantities living on the Instance.** 2000
  identical inverters keep 2000 copies of the same 62 numbers. ngspice splits
  `MOS1model` from `MOS1instance` for exactly this reason. Splitting the hoist
  by whether a root reads `inst.temperature` is the follow-up.
- **The prefix-latch grew the whales.** bsim4va is **+2 KB per instance**
  (235 f64 + 14 i64), so 100k BSIM4 instances is +200 MB. It does not cost time
  (`bsim4_transfer` −3.68%) but it is a straight trade against the
  less-memory-than-ngspice goal. 20 of 39 models get a region, 956 slots total.
- **Waveform streaming** (todo #13): `rc_ladder_100k` is 760 MB against
  ngspice's 220 MB after the 16×→2× capacity fix. Full streaming (reserve
  header, patch npoints at the end) closes the last ~3×.
  `src/analysis/tran/{tran,types}.zig`, `src/output/rawfile.zig`.
- **AC workspace**: `freq_solve.zig:98` sets `total_nnz = 4 * src_nnz`
  unconditionally. On `sweep/opamp_wl_5000` that is n 15,009→30,018, nnz
  115,017→460,068, L+U 750k, where the C matrix is essentially diagonal
  (5,000 caps, no TOX/CGSO/CJ declared) — ~1.9× waste before fill. Build each
  of the four blocks from its own structural pattern, or go complex-valued.

### 11. GPU — no fixture is a win today

Measured on an RTX 4060 Laptop against the i9-14900HX. The CPU path got ~3.5×
faster this session; a GPU run carries a fixed ~340 ms driver setup (cuInit
114 ms, primary-context retain 81 ms, module JIT).

**Do not raise `gpu_max_model_bytes` to re-admit bsim4-class models on this
hardware.** `--outline-chunk` fixes BUILD time, and build time is not what the
cap defends against: bsim4's PTX is 142,990 f64 ops at ~16% occupancy on a part
whose f64 rate is 1/64 of f32 (152.7 GFLOP/s against the CPU's 1449). Those
kernels lose at RUN time however fast they compile. The prerequisite is mixed
precision (item 9, which needs VerA to reach `.optimized` float mode) or an
FP64 part. CAVEAT 2026-09-10: on the CPU, `-Djac-f32=bsim4va` measured
**exactly 0.0%** (three decks; the kernel itself −0.04%), because bsim4's
`n_u=18` derivative vector saves nothing at that width. That does not settle
the GPU case — a 64:1 rate ratio is a different argument — but the mixed-
precision prerequisite cannot be assumed to help bsim4 just because it helps
mos1. See `docs/perf/jac-f32-2026-09-10.md`.

Keep the zero-atomic guard: `v == 0` plus a bit-preservation check, exactly
neutral numerically, −30%/−26.5% at 4,000/40,000 instances.

### 12. `ParEval` has never been benchmarked on real hardware

Opt-in via `ESPICE_THREADS`, and `default_min_instances = 1024` so it does not
engage on either gate deck. Under callgrind, 4 lanes on
`parallel_inverters_500` measured +45% Ir — but callgrind serializes threads,
so the spin loops burn instructions that never happen on real hardware. **Ir is
not a usable metric inside ParEval.** Nobody has taken a wall-clock number.

Determinism is settled: the merge order is fixed and 4 lanes are byte-identical
run-to-run; the residual difference from serial is a bounded 1-ulp
reassociation (`init` cuts lane ranges at instance boundaries, so a cancelling
pair never straddles a lane) — 1.1e-16 to 4.4e-16 against a 1e-2 tolerance.

### 13. Build and measurement infrastructure

- **Per-model LLVM objects.** Any VerA change forces a **~35 minute** ARPice
  rebuild because all 38 models are `-M` modules in ONE `build-exe`, so Zig
  caches the compilation as a unit. `../espice-buildsplit` has the per-model
  `addObject` work but has diverged (36 files, 1896 lines, old base). This is
  the single biggest drag on iteration speed for kernel work.
- **Pin the reference simulator.** The runner takes `ngspice` from PATH.
  There are two 44.2 builds on this machine differing by 8.5%; RESULTS.md
  ratios are computed against whichever one PATH supplies. Add explicit
  `--ngspice PATH` and print the binary and version in the report.
- **ngspice KLU is slower on every deck we have** — 1.080× pi100, 1.093× mos6,
  1.529× rc_ladder_10k. Enable with `.options klu`. Its default Sparse1.3 is
  its best configuration at these sizes, so the comparison has always been
  against its strongest form. Worth a column, not a default.
- **Xyce and vacask are absent.** The runner already has full `xyce` plumbing
  (`probeXyce`, argv, `xyce_median_ns`/`xyce_skip`/`xyce_rss_kb`, `xy-*`
  columns) that has never been exercised — every row reads `skip`. There is no
  vacask plumbing, though `benchmark/fixtures/vacask/*` decks exist.
- **`zig build test` fails on a stderr gate**, not an assertion: the
  device-test binary passes 11/11 with exit 0 standalone. Same class as the
  `test-devices --listen` flake AGENTS.md documents. The aggregate gate is blind
  until it settles.

---

## Measurement hazards — read before building any rig

Five wrong answers this session came from the rig, not the code.

1. **A kernel rig's `dual.zig` MUST mirror `ARPice/src/devices/engine.zig`'s
   `DualFor` method for method**, including `gompute.math` rather than
   `std.math`. A hand-copy using `std.math.pow` inflated the mos6 kernel from
   1608 to 2074 and made `std.math.pow` look like the culprit — gompute's `pow`
   is in fact FASTER than `exp(y*log(x))` (134 Ir/call).
2. **Do not invent model-card parameters.** Fabricated `AD/AS/PD/PS` made the
   junction-charge block look live when the deck gives no areas and it is dead,
   exactly as in ngspice.
3. **Consume every derivative lane in the rig.** Reading one lets LLVM
   scalarize the dual and dead-code the rest, which silently turns a width
   sweep into a no-op (633 vs 965 Ir/eval for the same kernel).
4. **Two ngspice 44.2 builds exist** and differ 8.5%: `~/.nix-profile/bin/ngspice`
   (PATH, slower — 557M on pi100) and a from-source build (513M). Using the
   PATH one flatters every ratio. `/tmp` was wiped late in the session and took
   the from-source build with it; rebuild it before quoting ratios.
5. **The "gate a pass to run twice and difference" ablation trick is sound for
   idempotent pass COSTS and invalid for codegen or inlining questions.** On an
   inlining question it gave the OPPOSITE SIGN and 14× the magnitude, because
   keeping a non-inlined arm alive forces the callee out of line and prices
   *defeating* the inliner. Those need two real builds.

Also: `zig build -Ddebug-info=true` **SEGVs the Zig compiler**, so there are no
symbols — attribution is by ablation only. And valgrind SIGILLs on this
binary's GFNI instructions (`vgf2p8affineqb`) for decks that reach the
BJT/VerA model path, so those decks' Ir is meaningless if they abort early.

## Settled — do not re-open without new evidence

| claim | the measurement that settled it |
|---|---|
| per-value derivative narrowing | k=6 (the smallest correct universe) is a **21% loss**; k=4 is unsound, 3150 bit mismatches at rd=12/rs=9 |
| global reduced tangent basis | rank-5 → 14 instructions vs 13 for width 8 on AVX2 |
| instance-axis SIMD | 1.17× end-to-end; stamp 195→196 at W=4 |
| out-params instead of the by-value `evalQ` return | **zero** — `@call(.always_inline)` means there is no ABI and no sret |
| packing structurally-zero res/q rows | −5 instructions, wrong sign; LLVM already folds them |
| dead-path outlining / `--outline-chunk` on CPU | **+63% worse**; only 196 of 1727 instructions ever execute |
| data movement below 10% | floor is 25–30%; needs ≳18 flops per f64 word, MOS1 has 3.0 |
| solve-independent re-expansion at branch conditions | **zero** — LLVM's GVN handles it completely; cleanliness argument only |
| `@call(.always_inline, D.limit)` | +0.28% / +0.20%, two builds |
| GMRES solution-update tiling | +0.069% |
| noise-term hoisting | the `pow` it hoists is unreachable (`engine.zig:1651` emits only `.thermal`) |
