# Device evaluation measured AGAINST ngspice

2026-09-09. `docs/device-evaluation-audit-2026-09.md` measured device evaluation
against its own past. This pass measures it against the reference, which is a
different question and gives a different answer.

## The rig

nixpkgs ships ngspice stripped, so `MOS1load` was an unnamed address and none of
the earlier profiles could attribute a single instruction to it. ngspice 44.2 is
therefore rebuilt from its own source with symbols:

```
nix-store --realise /nix/store/pfaksd0kl46y99lq6s4axsc89f8vbngj-ngspice-44.2.tar.gz.drv
tar xzf /nix/store/3lzc9hcjbyr3sg0qvhcpi0jh8hsp0z61-ngspice-44.2.tar.gz -C /tmp/ng
cd /tmp/ng/ngspice-44.2 && ./configure --enable-xspice --enable-cider --enable-osdi \
    --disable-openmp --with-readline=no --prefix=/tmp/ng/inst CFLAGS="-g -O2" && make -j && make install
```

`--disable-openmp` diverges from nixpkgs (the local `cc` has no `omp.h`). It does
not affect the per-instance instruction count, which is what is compared: the
device loop body is the same code and callgrind runs it serially either way.
Totals below are therefore ngspice-favourable-neutral, not ngspice-pessimistic.

Both engines under `valgrind --tool=callgrind --cache-sim=no --branch-sim=no` on
`benchmark/fixtures/scaling/parallel_inverters_100/circuit.sp` — 200 MOS1
instances, `.tran 0.1n 50n`. Per-instance figures divide the device symbol's
self cost by (Newton iterations x instances); the iteration counts are read from
`ZP_TRAN_STATS=1` on espice and from callgrind's call count on `MOS1load`, which
is called once per `CKTload` and loops over both models internally.

espice was built `-Dgpu=false` throughout so an iteration is 4.5 min rather than
~25; that flag changes no host code.

## What the reference actually costs

ngspice does **1,319** loads; espice does **1,352** Newton iterations. Iteration
count is not the gap — the two engines agree on how hard this circuit is.

| | espice (before) | ngspice 44.2 |
|---|---:|---:|
| total Ir | 1,168,075,147 | 513,424,350 |
| device evaluation | 649,767,008 (55.6%) | 216M (`MOS1load` 200.3M + `DEVqmeyer` 7.8M + `exp`) |
| Ir per MOS1 instance evaluation | **2,403** | **759** |

RESULTS.md agrees with the shape of that: every MOSFET-dense fixture was where
espice lost (`parallel_inverters_100/500/2000` at 0.4x/0.4x/0.5x) while the
linear ones won outright (`resistor_grid_100x100` at 27.3x). The deficit was
never the solver.

Splitting the 2,403 needed a rig that runs the device math alone. `/tmp/devbench`
compiles the REAL generated `mos1.zig` against a copy of `engine.Dual(8, f64)`
and calls `evalQ` in a loop, with the `Model`/`Instance` pointers laundered
through an empty `asm volatile` so LLVM cannot hoist the parameter-only prologue
out of the loop the way it never can in espice. Marginal cost between 1000 and
3000 iterations:

| | Ir per `evalQ` |
|---|---:|
| device math, prologue not hoistable | 1,249 |
| device math, prologue hoisted (LICM allowed) | 1,044 |

So of the 2,403: ~1,249 was physics and ~1,150 was gather/scatter bookkeeping.
The bookkeeping alone cost more than ngspice's entire device evaluation.

## Finding 1 — the local Jacobian was dense by construction

`evalRange` stamped `n_u x n_u` for G and again for the charge Jacobian: **128
matrix adds + 16 residual adds** per mos1 instance per Newton iteration, each
one behind a runtime `if (active[cu])`. `MOS1load` stamps **22 matrix + 4 rhs**.

The device knows which of those entries its physics can fill, and nothing was
asking it. VerA now computes that. `Analysis.deps` is a u64-per-Value refinement
of the existing `dfree` lattice — same monotone fixpoint, same arm-for-arm rules,
`block_param => 1 << u` instead of `false` — and `emitStamps` accumulates one
bitset per residual row as it writes that row, so a row shape cannot be added
without stating its columns. The result is emitted as `jac_pattern`/`q_pattern`
(`[n_u]u64`, omitted above 64 unknowns, where the dense fallback is correct).

For mos1 the live fraction is **21 of 64** resistive and **16 of 64** reactive —
71% of the per-instance scatter was adding a structural zero into a matrix slot.
The pattern is over-approximate by construction: a set bit costs a stamp that
happens to be zero, a clear bit is a promise.

The host uses it twice, and the second use matters as much as the first:

- `evalRange` drops the cleared stamps at **comptime**, so the code is not
  emitted rather than predicated.
- `ProtoStore.addPattern` no longer **reserves** a sparse-matrix entry for them.
  An entry no device can fill is still a nonzero once reserved, and costs
  fill-in and float work in every factorization for the rest of the run.
  `buildTapes` writes `trash_slot` there, which keeps the frozen
  `[id][ru][cu]` tape shape byte-identical.

Gate: every generated testbench now runs `patternCheck` at every probe point —
a nonzero partial outside the declared pattern fails the run. 1239/1242 torture
fixtures pass; the 3 failures are the untracked WIP `$limit` fixtures and fail
identically without this change.

## Finding 2 — the models computed charges ngspice skips

`mos1load.c:567,628`, `mos6load.c:581,640` and `mos9load.c:918,977` all guard the
junction depletion charge with `if (Cbs != 0 || Cbssw != 0)`. `mos1.va`,
`mos6.va` and `mos9.va` did not, so every instance evaluated
`pow(1 - v/pb, 1 - mj)` twice per junction to arrive at a charge that is
identically zero. This is not a corner case: a layout netlist leaves
`CJ/CJSW/CBD/CBS` and `AD/AS/PD/PS` at their zero defaults, which is exactly the
workload the GPU path exists for. `mos2.va`, `mos3.va` and `diode.va` already
carried the guard; `bjt.va` does not and neither does `bjtload.c`, so it was left
alone.

Four of the six `pow` calls per mos1 evaluation were this. In the standalone rig
`evalQ` fell **1,249 -> 634 Ir**, which puts espice's device math below ngspice's
759 for its whole load.

Correctness: with `cz == czsw == 0` both arms are exactly zero — the second arm's
`f2/f3/f4` are themselves built from `cz`/`czsw`. The guard also removes a latent
`0 * NaN` for `v > pb`, where `pow` of a negative base was reached before being
multiplied by zero.

## Finding 3 — two predicates that were the wrong way round

- **Ground.** A ground row or column already resolves to `trash_row`/`trash_slot`
  in the tape, so the per-stamp `if (active[cu])` bought one skipped add on a
  line that is L1-resident by construction. Dropped on the host, **kept on the
  GPU**, where the same skipped add is a contended atomic worth 2x at 40,000
  instances (`docs/device-evaluation-audit-2026-09.md`, "Ground scatter"). Same
  body, opposite right answer, so it is a comptime split on `SinkT.on_device`.
- **Limiting correction.** `use_lim` says the limiter is ARMED, not that anything
  moved; `lim_x` equals `x` on every instance the limiter left alone, which near
  convergence is nearly all of them. One `@reduce(.Or, corr != 0)` now replaces
  `2 * n_u` masked dot products of a zero vector.

## Result

Same deck, same build configuration, callgrind, **output bit-identical at every
step** (`cmp` on the raw file):

| build | total Ir | device symbol | Ir / instance eval |
|---|---:|---:|---:|
| baseline | 1,168,075,147 | 649,767,008 | 2,403 |
| + structural Jacobian | 1,006,102,232 | 488,260,634 | 1,806 |
| + junction-charge guards | 769,394,145 | 423,549,858 | 1,566 |
| + branchless ground / corr gate | **754,947,513** | 418,259,110 | **1,547** |
| ngspice 44.2 | 513,424,350 | ~216M | **759** |

**-35.4% total instructions.** Wall clock, `parallel_inverters_500`, median of 3:
**0.45 s -> 0.29 s** against ngspice's 0.24 s, i.e. 0.53x -> 0.83x of the
reference on the fixture class that was espice's worst.

## What did NOT close, and why

Device **math** is now cheaper than ngspice's (634 vs 759). The residual 1,547
is bookkeeping, and the per-instruction profile of the eval symbol
(`callgrind --dump-instr=yes`, buckets mapped through `objdump`) says where:

- The 8x8 Jacobian is materialized before it is scattered. `evalQ` returns
  `[n_u]S` for both halves, which is 32 ymm registers of live derivative against
  16 architectural ones, so the frame spills — stack offsets up to `0x7e0` and
  `vmovapd 0x4c0(%rsp)` on the scatter path. Scattering each row as it is
  produced would fix it and needs a different device entry point.
- Every stamp pays a `vextractf128`/`vshufpd` to get one lane of a
  `@Vector(8, f64)` gradient to a scalar address. AVX2 has no scatter. This is
  the structural cost of forward-AD-then-scatter against ngspice's named
  `gm`/`gds`/`gmbs` into precomputed pointers.
- Devices are still walked TWICE per Newton iteration — `applyLimits`
  (`limitRange`, re-gathers all `n_u` unknowns) and then `evalRange`. ngspice
  limits inline in `MOS1load`. Measured at ~312 Ir/instance, 8.4% of the run.
- The parameter-only prologue still runs per evaluation: VerA's `pcClass` bails
  on `.phi`/`.branch`, so an `if ($param_given(...))` ladder is not hoistable,
  and `pcConsider` requires a libm-class op, so `cox`/`beta`/`f2d..f4s` are
  recomputed. 141 Ir/eval measured (the LICM-allowed vs laundered delta above).
  ngspice does all of it once, in `MOS1temp`, called **1** time.

## Dead code found on the way

`canDedup` requires `PrepCache` and no `State`. No generated built-in exposes
`PrepCache`, and mos1 has `State` (the `$prev` Meyer average), so the whole
`tryCached`/`eval_cache_*` path is compiled out for every built-in device.
Confirmed by measurement, not by reading: 100 identical instances cost 2,589
Ir/instance and 100 deliberately varied ones cost 2,542, a 2% spread. Either
make it reachable or delete it; it is currently ~120 lines and three allocations
that never run.

## GPU: a REGRESSION, and the older defect under it

The GPU path is opt-in (`--gpu`, `--backend cuda`; the default is CPU) and this
work made it worse on the largest fixture. Both facts are measured.

`parallel_inverters_2000`, `ZP_TRAN_STATS=1`, same binary:

| | accepted | `rej[newton=]` | `TimestepTooSmall` |
|---|---|---|---|
| CPU, 3 runs | 595 every time | 0 | 0 |
| GPU, dense pattern, 16 runs | 593-597 | 0-2 | 0/16 |
| GPU, structural pattern, 8 runs | 599-622 | 6-31 | **3/8** |

The underlying defect predates all of this: the GPU accumulates the planes with
`@atomicRmw(.Add)` from thousands of threads in unspecified order, and a KCL row
with high fan-in and heavy cancellation is exactly where float addition's
non-associativity stops being a rounding detail. `ZP_NEWTON_DEBUG=1` on a `.op`
version of the deck shows it directly: at iterate 2 the Vdd branch current reads
`-7.275957614183426e-9` on CPU and `-7.225480658235028e-9` on GPU — 0.7%
relative — while every other unknown agrees to ~10 digits. That unknown is the
sum of 2000 nearly-cancelling device currents. At 100 and 500 instances the GPU
is stable; the failure is fan-in dependent.

What this pass contributed is only WHICH way the chaos falls: a comptime change
in the number of emitted stamps reshuffles NVPTX register allocation and FMA
contraction, and the run count moved from 0/16 failures to 3/8. Do not read that
as "the structural pattern is wrong on GPU" — the CPU output is bit-identical
and the matrix nnz is unchanged (10,011 both ways) — read it as "the GPU was
already on a knife edge".

The fix is the data-oriented one and it is assigned: replace the atomic
accumulation with a fixed-order segmented reduction. The scatter tape is frozen
at setup, so its transpose is too — build a CSR `(destination -> contribution
list)` once at `finalize`, have the eval kernel write each contribution to its
own slot with no atomics, and reduce each destination in index order, with a
pairwise or compensated sum on high-fan-in rows. That is deterministic, removes
the atomic contention the previous audit spent two passes mitigating, and is the
half that buys accuracy rather than only reproducibility.

## Build-system fixes made to get here

- `-Ddebug-info=true` SEGV'd the compiler: `zig build-obj -target nvptx64-cuda`
  died in DWARF emission for mos2/vdmos, so the one build mode the profiling
  doc names was unusable. Generated device modules are now ALWAYS stripped —
  their DWARF maps to a cache file nobody reads, and the DI cost is superlinear
  in function size, which is precisely what the whale models are. The host side
  still SEGVs in this Zig (0.16.0); the profiles above are therefore attributed
  by address plus call count, which was sufficient. Symbolized host profiling
  remains blocked.
- `-Dgpu=false` compiles ONE model for the GPU instead of all 38 (gompute panics
  on an empty root list, and `gompute_kernels` must exist for gpu_context.zig).
  4.5 min instead of ~25. It is an iteration flag, not a shipping one, and not
  what `zig build bench` should run.
