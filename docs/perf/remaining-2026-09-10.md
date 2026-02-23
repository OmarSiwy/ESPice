# Remaining performance opportunities — handoff, 2026-09-10

Written at the end of a long optimization session. Everything here is either
measured or explicitly marked as an estimate. Read "Measurement hazards" first —
five separate wrong answers this session came from rig bugs, not from the code
under test.

**2026-09-10, second pass:** "Where the numbers stand", the per-pass budget,
§1, §2, §6 and hazard 4 were re-measured at `446268a` and rewritten. The budget
they replace was taken at pi100 = 507M / mos6 = 189M and was marked stale in
this file; it is retired, with the old-vs-new deltas kept under "What moved".
Everything else on this page is as first written.

## Where the numbers stand

All re-measured 2026-09-10 at `446268a`, callgrind Ir, one command shape:
`espice -b --backend cpu -r RAW DECK` and `ngspice -b -r RAW DECK`.
**Both ngspice binaries are 44.2 and both report KLU available; neither deck
sets `.options klu`, so both ran Sparse1.3.**

| deck | espice | ngspice PATH¹ | ratio | ngspice from source² | ratio |
|---|---:|---:|---:|---:|---:|
| `scaling/parallel_inverters_100` | 466,358,473 | 557,229,231 | 0.837 | 512,035,556 | **0.911** |
| `devices/mos6_inverter` | 153,737,019 | 166,343,979 | 0.924 | 147,852,963 | **1.040** |
| `scaling/rc_chain_500` | 80,589,126 | 179,875,209 | 0.448 | 154,776,748 | **0.521** |
| `scaling/rc_ladder_10k` | 1,203,408,608 | 2,918,342,133 | 0.412 | 2,606,771,619 | **0.462** |

¹ `~/.nix-profile/bin/ngspice` →
`/nix/store/bywwgg84ccx0544z9qrfm4zc4ls30ghd-ngspice-44.2`.
² rebuilt from `/nix/store/3lzc9hcjbyr3sg0qvhcpi0jh8hsp0z61-ngspice-44.2.tar.gz`
with `NIX_HARDENING_ENABLE="" ./configure --disable-debug --disable-openmp
--with-readline=no CFLAGS="-O2 -fno-stack-protector"`. Reproduces the lost
build to 0.2% (512.0M against the 513M on record).

**Quote the from-source column.** The PATH build is not 8.5% slower as
previously recorded — it is slower by a deck-dependent **8.8% (pi100), 12.5%
(mos6), 16.2% (rc_chain_500), 12.0% (rc_ladder_10k)**, so the PATH column
flatters us by more on exactly the decks where the margin is thin. mos6 against
ngspice's fastest build is the only remaining loss and it is **4.0%**.

**Since**, on the `limit-body` branch (item 2 below): pi100 **433,940,840**
(ratio 0.779 PATH / 0.846 from-source), mos6 **146,039,892** (0.878 / 0.981) —
so mos6 is no longer a loss against ngspice's fastest build either. Both
measured on 446268a + VerA a19b6fb as the baseline, which reads 466,358,459 /
153,736,881 for the same decks (446268a adds a checkpoint commit over the
6e55e74 the table above was taken on).

Session arc on pi100: 754.9M → 466.4M (−38.2%).

Two espice rows moved since these were last written and it is not measurement
noise: pi100 and mos6 drifted +0.17%, but `rc_chain_500` went 79.10M → 80.59M
(**+1.9%**) and `rc_ladder_10k` 1178.0M → 1203.4M (**+2.2%**). `446268a` touched
60 files under `src/`; the linear decks paid for something in it. Not chased.

## The per-pass budget — re-measured 2026-09-10 at `446268a`

**Replaces the budget taken at pi100 = 507M / mos6 = 189M**, which predated the
prefix-latch (−7.7%/−12.6%) and the LU reshape (−3.6%/−4.2%) and whose
percentages were therefore all wrong. That table is gone; the deltas against it
are in "What moved" below so nothing is lost.

### Method, and what it is not

`zig build -Ddebug-info=true` still SEGVs the Zig 0.16 compiler, so the binary
is stripped (`nm`: no symbols) and callgrind prints entry addresses, not names.
Attribution is therefore **not symbolic**. It is also **not ablation**: no pass
was doubled and no second build was made. What callgrind still records exactly
is call counts and caller/callee edges, and on these two decks the counts are
identifying:

| observed count (pi100 / mos6) | can only be |
|---|---|
| 1358 / 935 | once per Newton iterate (1352/884 transient + 6/51 OP) |
| 614 / 319 | once per converged solve (`finalizeStep` tail) |
| 595 / 316 | once per accepted point |
| 271,600 = 200×1358 / 74,800 = 80×935 | once per MOSFET per Newton iterate |
| 642 / 321 | `stepBound` (accepted−1 + LTE rejects + order-promotion trials) |

Cross-checked on `scaling/parallel_inverters_500` — 5× the instances, same
trajectory (1356 vs 1352 iterates), 2,306,885,506 Ir:

| row | pi100 Ir/call | pi500 Ir/call | ratio | scales with |
|---|---:|---:|---:|---|
| kernel + stamp | 190,869 | 954,218 | **5.000** | instances |
| limiting | 37,606 | 187,862 | 4.996 | instances |
| post-accept `evalQ` | 40,389 | 201,801 | 4.997 | instances |
| `updateStates` | 26,861 | 134,176 | 4.995 | instances |
| LU refactor | 17,601 | 86,386 | 4.908 | n, nnz |
| LU solve | 7,422 | 36,144 | 4.870 | n, L+U |
| `stepBound` | 25,938 | 129,379 | 4.988 | q-tape (1800→9000) |
| `snapshotQTape` | 4,638 | 23,038 | 4.967 | q-tape |

Device rows scale exactly with instance count and matrix rows do not — that is
what pins the identities, not a name. Leaves were read off `objdump`: the two
transcendental helpers under mos6's `updateStates` are `exp` (81.2 Ir,
`cmp $0x4086232a` overflow gate) and `log` (57.0 Ir, `add $0xc01200;
and $0xffffff` prologue); the per-instance limiter leaf is branch-free FP with
no calls at all (18.8 / 17.4 Ir).

Rows below are whole-run inclusive and **sum to the deck total exactly**. Both
decks' OP solve shares the same `assemble`/`finalizeStep`/`factor` functions as
the transient, so it is a cross-cut, not a row: it is folded into the kernel,
limiting and LU rows and is called out under each table.

### pi100 — 466,358,473 Ir

1358 NR iterates (1352 transient + 6 OP), 613 attempts, 595 accepted points;
200 MOSFETs, 100 caps, 2 sources; n=105, nnz=511, L+U=608, q-tape 1800.
Last column is Ir ÷ (200 × 1358).

| pass | Ir | % | per MOSFET per NR iter |
|---|---:|---:|---:|
| MOS1 kernel + stamp | 268,940,632 | 57.67% | 990 |
| limiting (whole pass; the clamp leaf is 5.10M of it) | 56,167,552 | 12.04% | 207 |
| LU refactor | 24,041,215 | 5.16% | 89 |
| post-accept `evalQ` (RealFor q-only) | 24,031,420 | 5.15% | 89 |
| `updateStates` (mos1 16.49M + capacitor 0.78M) | 17,269,545 | 3.70% | 64 |
| `stepBound` LTE (1800-entry q-tape) | 16,652,376 | 3.57% | 61 |
| tran-loop self | 11,164,534 | 2.39% | 41 |
| LU triangular solve | 10,079,550 | 2.16% | 37 |
| parse + build + raw write (main thread) | 8,103,744 | 1.74% | — |
| step bookkeeping (`stateCtl`, `commitStates`, `boundStep`, ring rotate) | 6,801,487 | 1.46% | 25 |
| memcpy/memset helpers | 6,570,325 | 1.41% | 24 |
| `snapshotQTape`, per iterate | 6,303,042 | 1.35% | 23 |
| `finalizeStep` self (`x_old` copy, `updateAndNorm`, residual gate) | 4,707,106 | 1.01% | 17 |
| `TranHook.assemble` self (companion RHS) | 2,785,863 | 0.60% | 10 |
| Newton self (`combineGC` + \|F\|) | 2,300,723 | 0.49% | 8 |
| vsource batch | 439,359 | 0.09% | — |

OP solve: **2,033,735 (0.44%)**, 6 Newton iterates, distributed across the
kernel/limiting/LU rows above.

### mos6 — 153,737,019 Ir

935 NR iterates (884 transient + 51 OP), 320 attempts, 316 accepted points;
80 MOSFETs, 16 caps, 2 sources; n=45, nnz=243, L+U=258, q-tape 672.
Last column is Ir ÷ (80 × 935).

| pass | Ir | % | per MOSFET per NR iter |
|---|---:|---:|---:|
| MOS6 kernel + stamp | 87,474,635 | 56.90% | 1169 |
| limiting (whole pass; the clamp leaf is 1.30M of it) | 15,478,434 | 10.07% | 207 |
| LU refactor | 11,106,132 | 7.22% | 148 |
| post-accept `evalQ` (RealFor q-only) | 7,221,028 | 4.70% | 97 |
| `updateStates` (mos6 6.60M + capacitor 0.47M) | 7,074,267 | 4.60% | 95 |
| parse + build + raw write (main thread) | 7,004,679 | 4.56% | — |
| LU triangular solve | 3,235,291 | 2.10% | 43 |
| `stepBound` LTE (672-entry q-tape) | 3,144,126 | 2.05% | 42 |
| tran-loop self | 2,424,227 | 1.58% | 32 |
| step bookkeeping (`stateCtl`, `commitStates`, `boundStep`, ring rotate) | 1,888,313 | 1.23% | 25 |
| memcpy/memset helpers | 1,887,764 | 1.23% | 25 |
| vsource batch — VIN is PWL, averages 893 Ir per source per iterate against pi100's 77 | 1,830,032 | 1.19% | — |
| `finalizeStep` self (`x_old` copy, `updateAndNorm`, residual gate) | 1,396,976 | 0.91% | 19 |
| `TranHook.assemble` self (companion RHS) | 1,035,617 | 0.67% | 14 |
| Newton self (`combineGC` + \|F\|) | 811,034 | 0.53% | 11 |
| `snapshotQTape`, per iterate | 724,464 | 0.47% | 10 |

OP solve: **6,988,149 (4.55%)**, 51 Newton iterates, distributed across the
kernel/limiting/LU rows above. The old table's "parse+build+OP solve 8.2%"
splits today into 4.56% parse/build and 4.55% OP; combined 9.11%, and it is
still the OP solve rather than fixed overhead.

### What moved, and whether the ORDERING moved

**pi100: the ordering did not change through rank 6.** The only swap is at
ranks 7/8, tran-loop self overtaking the LU triangular solve. Anything aimed at
the old pi100 top six is still aimed correctly.

| pi100 | old rank | new rank |
|---|---:|---:|
| MOS1 kernel + stamp | 1 | 1 |
| limiting | 2 | 2 |
| LU refactor | 3 | 3 |
| post-accept `evalQ` | 4 | 4 |
| `updateStates` | 5 | 5 |
| `stepBound` | 6 | 6 |
| LU triangular solve | 7 | **8** |
| tran-loop self | 8 | **7** |

**mos6: one swap, `updateStates` and post-accept `evalQ` trade places.**
`updateStates` went 14.2M → 7.07M (−50%) against `evalQ`'s 9.26M → 7.22M
(−22%), so `evalQ` is now the larger of the two — but by 2%, which is inside the
distance anyone should read as an ordering. Treat them as tied. See §6.

| mos6 | old rank | new rank |
|---|---:|---:|
| MOS6 kernel + stamp | 1 | 1 |
| limiting | 2 | 2 |
| LU refactor | 3 | 3 |
| post-accept `evalQ` | 6 | **4** |
| `updateStates` | 5 | **5** |
| parse + build (was bundled with the OP solve at rank 4) | 4 | **6** |
| LU triangular solve | 7 | 7 |

The mos6 rank-4/6 move is partly accounting, not work: the old row bundled
parse+build with the OP solve at 8.2%, and the OP solve is now attributed to the
passes it actually runs. Parse+build alone is 4.56%, the OP solve 4.55%. Do not
read "parse+build fell from rank 4 to rank 6" as a saving.

Absolute deltas against the retired table:

| pass | pi100 old → new | mos6 old → new |
|---|---|---|
| kernel + stamp | 277.4M → 268.9M (−3.1%), share 54.7% → **57.67%** | 100.0M → 87.5M (−12.5%), share 52.9% → **56.90%** |
| limiting | 72.8M → 56.2M (−22.8%) | 20.0M → 15.5M (−22.7%) |
| LU refactor | 38.8M → 24.0M (−38.0%) | 17.4M → 11.1M (−36.1%) |
| post-accept `evalQ` | 29.6M → 24.0M (−18.8%) | 9.26M → 7.22M (−22.0%) |
| `updateStates` | 19.6M → 17.3M (−11.9%) | 14.2M → 7.07M (**−50.1%**) |
| `stepBound` | 16.7M → 16.65M (flat — nothing touched it) | — |
| LU solve | 14.9M → 10.1M (−32.4%) | 4.54M → 3.24M (−28.7%) |

The kernel's *share* rose on both decks while its absolute Ir fell. Everything
around it got cheaper faster than it did. Nothing overtook anything in the top
three: the kernel is more dominant than the stale map said, not less.

---

## Open opportunities, ranked by expected value

### 1. The device kernel — 57.67% of pi100, 56.90% of mos6, and RISING

Re-measured 2026-09-10: 990 Ir per MOSFET per Newton iterate on pi100, 1169 on
mos6, kernel and stamp together. Its absolute cost fell this session (−3.1% /
−12.5%) but its *share* went up on both decks, because every other pass fell
faster. It is a larger fraction of the run than the retired budget said.

mos1 `evalQ` was 754 Ir/eval before the prefix-latch; mos6 was 1224.6 → ~1164.
ngspice: MOS1load self 759, whole per-instance MOS1 evaluation 1053; whole
per-instance MOS6 evaluation 1138. Our figures contain **no stamping, no
limiting and no integration**, so the kernel-to-kernel gap is wider than the
raw comparison suggests.

**The isolated-rig number and the in-deck number disagree on mos6, and the
in-deck one is lower.** mos1: 990 in-deck minus the 195 stamp (§7) leaves 795
against the rig's 754, +5%, fine. mos6: 1169 − 195 = 974 against the rig's
~1164, **−16%**. Likely mechanism, and it is measurable: the rig prices one
fixed bias point with every branch live, while the deck averages over states.
In the real deck the mos6 kernel enters its transcendental leaves 178,521 +
38,245 times across 935 × 80 = 74,800 instance-evals — **2.39 `exp`-family and
0.51 `log` per instance-eval**, not the full ladder every time. Before spending
a week on a rig-measured −N Ir, check what fraction of instances reach that
block on the deck you are being judged on.

Composition of the mos6 kernel at 1403 (before two fixes): Dual AD methods 583
(41.6%), model expressions 264, transcendentals 309, rest 96. The AD layer is
the biggest single line and nothing has touched it.

**Do not re-attempt derivative narrowing on a device whose internal nodes are
LIVE.** Settled with measurements: on AVX2 every width ≤4 is ONE vector
instruction, so narrowing popcount-2 values from 4 lanes to 2 saves zero; mos1's
smallest *correct* lane universe is **six** (the rd/rs series branches touch
`{d,di}` and `{s,si}`), and `@Vector(6,f64)` lowers to ymm+xmm — same FP count
as 8, +145 shuffles. Measured k=6: **1088 Ir, a 21% loss**. k=4 wins but is
provably wrong there: 3150 bit mismatches at `rd=12, rs=9`. A contract `axpy`
injector was added and reverted — measured 2.95 instructions per component, not
the ~1 that would close the ledger.

**The COLLAPSED case is a different device and it is DONE —
`docs/perf/rank4-2026-09-10.md`.** With `rd = rs = 0` the host has already
aliased `di` onto `d` and `si` onto `s` in the tapes, mos1's core reads `x[d]`,
`x[s]` and both branch-flow unknowns nowhere, and rank 4 is the rank rather than
an approximation of 8. VerA emits the maximal alias map at comptime
(`collapse_full`), `ProtoStore.finalize` partitions instances by whether their
own `collapse` reaches it, and `evalRange` takes a comptime `narrow` flag that
picks the derivative basis and nothing else. **pi100 433.9M → 380.1M (−12.40%),
mos6 146.6M → 130.6M (−10.95%), 198 / 215 Ir per evaluation, 256 of 256 fixture
raws byte-identical (`convergence/mos_series_r` included), NR iterations
unchanged at 1352 / 884.** GPU stays wide; `n_u > 8` (bsim4 and up) stays wide.

**ALL THREE live sub-items below are now CLOSED — see
`docs/perf/dual-ad-2026-09-10.md`, which itemises the AD layer per method
against an exact op census, does the ngspice block-by-block off a
symbol-carrying 44.2 build, and returns a NO-GO. Read it before re-opening
any of them.**

Live sub-items:
- ~~**`sel` still evaluates both arms**~~ — priced: mos6 executes **2** `sel`
  per instance-eval and mos1 **7**. −8.8 Ir is the mos6 ceiling, not a sample.
  Site census for all 38 devices is in VerA `eagerCostly`'s comment (2fde21c).
- ~~**`pcExpensive`'s libm-root filter**~~ — the filter no longer exists
  (`codegen.zig:833 pcConsider` admits every non-folding instruction);
  `grd`/`grs` are `hp[9]`/`hp[10]` and the four `czb*` are `hp[11..14]` in the
  shipped mos6 artifact. All six hoist today.
- ~~Block-by-block against ngspice~~ — done. We are AHEAD on the `<dev>temp`
  preamble (0 vs ~15 Ir) and on the bypass/convergence-prediction ladder
  (0 vs ~40, work ngspice does speculatively and we never do). We are BEHIND
  on: the Jacobian (488 Ir of AD against ~20 hand-derived flops), limiting
  (291 vs **56.3**, and ngspice's is inline), the stamp (195 vs ~78), and the
  junction diode (~2x the flops, deliberately — the tangent continuation).
  Transcendental count and cost are at parity.

### 2. Limiting — DONE. `docs/perf/limiting-2026-09-10.md`

Was 291 Ir per instance per iterate against ngspice's 52. Itemised there
against ngspice's own `mos1load` ladder compiled in the same rig, and three
fixes landed (ARPice `limit-body` + VerA `limit-body-vera` 248c0c6): the
limiter kernels are now `inline` transparent-test wrappers over `noinline`
clamp ladders (`zFetlim` had been too big for LLVM to inline AT ALL — a real
`call` with six caller-saved spills), `cg_limit` hoists the frame sign, and
VerA exports `limit_reads` / `limit_writes` so the host gathers and stores only
the unknowns the device actually corrects (mos1: four of eight read, two of
eight written). **pi100 466.4M → 433.9M (−6.95%), mos6 153.7M → 146.0M
(−5.01%), NR iterations unchanged at 1352 / 884, 248 of 248 fixture raws
byte-identical.**

The pass cost the same 207 Ir per MOSFET per Newton iterate on BOTH decks
before this landed, which is what identified the target: a model-independent
cost is scaffolding, not physics. The clamp leaf itself — branch-free FP, no
calls — was 18.8 Ir on pi100 and 17.4 on mos6, i.e. **9% of the pass**.

Left there deliberately: we run TWO `pnjlim` calls where ngspice runs one and
derives the other by subtraction (≈22 Ir — but it changes which iterates Newton
accepts, so it is a convergence change, not an optimisation), and `limit` still
returns `[n_u]f64`.

Retired experiments, still retired:
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

### 5. Post-accept charge re-evaluation — 5.15% / 4.70%

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

### 6. `updateStates` — re-measured 2026-09-10; the mos6 penalty is half gone

Was 2.8× more per MOS6 instance than per MOS1 (556 vs 182 Ir **per converged
solve**, not per iterate — `converger.zig:289` moved it). Mechanism: it
re-enters the core at `R` to restage `ddt` arguments, and mos6's Meyer
partition needs the Sakurai–Newton saturation voltage, whose closure carried
two non-integer `pow`. Isolated conclusively — the same circuit re-carded to
LEVEL 1 costs 215 Ir where LEVEL 6 costs 556, and callgrind counted exactly
200,000 `pow` entries from mos6 and 0 from mos1.

The shared-`ln` patch (542e9a0) removed those two `pow`. **Re-measured, same
accounting (whole-run pass Ir ÷ converged solves ÷ instances):**

| | old | now | |
|---|---:|---:|---|
| MOS6, Ir per instance per converged solve | 556 | **259** | −53% |
| MOS1, Ir per instance per converged solve | 182 | **134** | −26% |
| ratio | 2.8× | **1.93×** | |
| mos6 deck share | 7.5% | **4.60%** | 14.2M → 7.07M |

The MOS6 column reproduces: 7.5% of 189M ÷ 318 converged solves ÷ 80 instances
= 557, i.e. the old 556 came from this same accounting. **The MOS1 column does
not** — 3.9% of 507M ÷ 613 ÷ 200 = 160, not 182, so the old MOS1 figure came
from somewhere else and its −26% is soft. The MOS6 number and the ratio are the
trustworthy lines here.

`pow` is gone from `updateStates` and so is any 200,000-entry libm count. What
remains in the mos6 pass is exactly the shape 542e9a0 aimed for: **one `exp`
and one `log`, called 12,979 times each** over 319 converged solves × 80
instances — 0.509 of each per instance per solve, i.e. the branch is live on
about half the devices. Together 1,793,628 Ir, **27.2% of the whole pass**.
MOS1's `updateStates` is a leaf with no calls at all (0 transcendentals),
consistent with the original "0 `pow` from mos1".

Consequence for ranking: `updateStates` no longer stands out on mos6. It is now
within 2% of post-accept `evalQ` (7.07M vs 7.22M) — treat them as tied. The
remaining 73% is the re-entry into the core at `R` itself, which is the same
structural cost mos1 pays.

A second measurement of the same pass reports **330 Ir/call** for mos6
`updateState` (`docs/perf/dual-ad-2026-09-10.md` §3), against the 259 above.
The two do not disagree — the denominators differ. 259 is whole-pass Ir ÷
converged solves ÷ instances, so it charges each instance its share of a
pass that runs once per solve; 330 is Ir per invocation of the function.
Quote 259 when comparing against the budget table, 330 when comparing
against a per-call cost like ngspice's load routine. The `RealFor`
charge-only pass measures 299 Ir/call on the same basis.

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
- ~~**AC workspace**: `freq_solve.zig:98` sets `total_nnz = 4 * src_nnz`
  unconditionally.~~ **Tried, measured, reverted — 2026-09-10.** The premise
  above was wrong: "the C matrix is essentially diagonal (5,000 caps, no
  TOX/CGSO/CJ declared)" confuses *numerically* zero with *structurally* zero.
  mos1's `q_pattern` declares 16 charge entries per instance on rows
  `{g,b,di,si}` whatever the card says, and after node mapping **115,004 of
  `opamp_wl_5000`'s 115,017 circuit entries are charge-touched**. Building each
  half from its own pattern took nnz 460,068 → **460,042** — twenty-six entries
  — for ~330 lines, and peak RSS did not move (268.1 → 269.5 MB). Branch
  `ac-blocknnz`, not merged.
  The real split of that deck's 261.7 MB, by deck-variant differencing: `.op`
  alone **148.5 MB**, AC solver workspace 57.3, results 62.8. And the workspace
  is not the index arrays — it is `LaneLu`'s L+U planes at 27.0 MB
  (750k entries × `@Vector(4,f64)`) plus the `×W` lane vals plane at 14.7. Fill
  is healthy at 1.5–1.6×, so the ordering was never the problem. Aim at the
  per-instance storage (§10 first bullet) instead; that is where the 148.5 is.
  A numerically-aware pattern that drops entries whose parameters make them
  zero would collapse them, but a sweep point that changes a parameter makes
  them live again — do not do that without a re-pattern hook.

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

**CLOSED — see `docs/perf/pareval-2026-09-10.md`.** It never wins: the best wall
clock at any width on any deck is 1.07×, and 8/16/32 lanes are 0.6–0.9× on
`parallel_inverters_2000`. The parallel fraction is 13–22% of wall clock, so the
Amdahl ceiling is ~1.15–1.29× before any overhead. Stays opt-in and
`default_min_instances` is unchanged, because instance count is not the variable
that decides. Do not re-open without a deck whose parallel fraction exceeds ~0.6.

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
  There are two 44.2 builds on this machine differing by **8.8%–16.2% depending
  on the deck** (re-measured 2026-09-10); RESULTS.md ratios are computed against
  whichever one PATH supplies, which is the slower one. Add explicit
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
4. **Two ngspice 44.2 builds exist** and they differ by **8.8%–16.2% depending
   on the deck**, not the flat 8.5% first recorded: `~/.nix-profile/bin/ngspice`
   (PATH, slower — 557M on pi100) against a from-source build (512M). Using the
   PATH one flatters every ratio, and it flatters most on rc_chain_500 (16.2%).
   The from-source build was rebuilt 2026-09-10 after the `/tmp` wipe; the
   configure line and the store path of the tarball are in "Where the numbers
   stand". Rebuild it in a durable directory — `/tmp` will eat it again. The
   runner still takes `ngspice` from PATH (item 13).
5. **The "gate a pass to run twice and difference" ablation trick is sound for
   idempotent pass COSTS and invalid for codegen or inlining questions.** On an
   inlining question it gave the OPPOSITE SIGN and 14× the magnitude, because
   keeping a non-inlined arm alive forces the callee out of line and prices
   *defeating* the inliner. Those need two real builds.

Also: `zig build -Ddebug-info=true` **SEGVs the Zig compiler**, so there are no
symbols. Attribution is NOT therefore limited to ablation — callgrind still
emits per-function entry addresses, exact call counts and the full caller/callee
edge list, and on a deck with a known instance count the counts identify the
functions outright (200×1358 calls can only be one thing). The 2026-09-10 budget
was taken that way, with `scaling/parallel_inverters_500` as the 5× scaling
control and `objdump` on the leaves; no pass was doubled and no build was made.
Prefer that to ablation: it costs one run instead of one build per row, and it
cannot perturb the trajectory. And valgrind SIGILLs on this binary's GFNI
instructions (`vgf2p8affineqb`) for decks that reach the BJT/VerA model path, so
those decks' Ir is meaningless if they abort early — check the exit code and
that the summary line is present, an early abort still writes a plausible total.

## Settled — do not re-open without new evidence

| claim | the measurement that settled it |
|---|---|
| per-value derivative narrowing, internal nodes LIVE | k=6 (the smallest correct universe) is a **21% loss**; k=4 is unsound, 3150 bit mismatches at rd=12/rs=9 |
| per-value derivative narrowing, nodes COLLAPSED | the opposite sign, and shipped: rank 4 is exact when `rd = rs = 0`, −12.40% / −10.95%, 256/256 byte-identical — `docs/perf/rank4-2026-09-10.md` |
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
| fat in the `Dual` AD layer | every primitive is at or below its naive AVX2 lowering; 306 attributed Ir against 488 nominal, LLVM already deletes 37% |
| gradient work on provably-zero derivatives | already gone — `con`/`lt` attribute **0 Ir** across 121 executed calls |
| gradient lanes no consumer reads | mos6's `jac_pattern` ∪ `q_pattern` is `0xff`; there is no dead lane |
| `vcrits`/`vcritd`'s two per-entry `ln` | dead-coded in all three callers: **−2 / 0 / 0 Ir** |
