# GPU LU for large Newton solves: design

**Status: design, not implemented.** Every factor and solve runs on the
host today (`direct.zig`, `sparse_lu.zig`); the GPU only evaluates device
planes (`docs/devices/gpu-evaluation.md`). This page answers one question:
if the host sparse LU dominates on post-layout netlists (extracted RC plus
many transistors), how should espice factor and solve on the GPU? The
theory behind level-set GPU LU (GLU, NICSLU) is in `gpu-sparse-lu.md` and is
not repeated here. The conformance constraints come from
`gpu-convergence.md` §2.6 and §10.

Nothing here has been measured on a post-layout deck yet. Those decks are
being built on another branch (`tests/benchmark/postlayout/`), so §5 lists
the metrics that decide this design instead of numbers.

## Summary

Ranked recommendation:

1. **Replay the host's pivot tape on the device, solve there too, and keep
   the values resident** (options a, b and f below, as one path). The host
   keeps every pivot decision: its full `SparseLu.factor` picks the pattern
   and pivot sequence exactly as today. The device runs the operations of
   `SparseLu.refactorTape` (uncapped, one u32 per flop) as a sync-free
   left-looking column kernel, then two sync-free triangular solves. Assembly
   stays on the device so the bus carries a few n-vectors per Newton
   iteration instead of the planes. The result is bitwise the host's
   `refactorColumns` and `solve`, so a pivot failure peels to the host's
   full factor and the run continues exactly as a host-only run would.
   Staged: (1) kernels fed by host-uploaded values, (2) resident values,
   (3) the companion on the device, one sync per iteration.
2. **BBD blocks on the device** (option d), only if the census (E1) finds
   post-layout decks that take the BBD engine. Flat extracted netlists
   probably do not: RC parasitics couple the subcircuit blocks, and
   `Bbd.init` declines a border above 512.
3. **The same kernel on host threads.** Rank 1's kernel body compiles for
   the host too. Run on worker threads with the same tickets, it is a
   multicore refactor (NICSLU's pipeline mode) with identical bits. It is
   the yardstick the GPU must beat, and a fallback where no GPU exists.
4. **cuDSS** (option c): a measurement reference on NVIDIA, not a
   dependency. It has no HIP counterpart, it is not bitwise with the host,
   and it would put vendor-only numerics on the device.
5. **Iterative solves** (option e): not in the default mode. An inexact
   linear solve changes the Newton iterates, and §10.1 of
   `gpu-convergence.md` shows the corpus oracles encode ngspice's exact
   per-iteration solve.

Verdicts in the sense of the gpu-parallel-algorithm-thinking method: the
refactor is **nested-parallel**. The column DAG is real, but sync-free
scheduling shortens its span to the critical path, and the entries of each
L column update in parallel. A single-rhs triangular solve is **thin**: on
circuit matrices a GPU solve lost 3.16x to one CPU core (Chen, TPDS 2015).
It stays on the device anyway because the alternative is
**movement-bound**: downloading the factors costs more than solving where
they live.

GLU's right-looking kernel is rejected outright. It accumulates subcolumn
updates with atomics, so the operation order changes from run to run. The
eval path already learned this (the `Order` comment in `gpu.zig`): two
atomic replays of the same stamp differed by 2.1e-10, the converger
rejected every iterate and dt underflowed.

## 1. The contract

**Equivalence level: bitwise with the host.** The device refactor must
produce, value for value, what `SparseLu.refactorColumns` produces, and the
device solve what `SparseLu.solve` produces. Three reasons:

- The peel. When a pivot degrades, the host re-pivots with a full factor
  and the run continues on the host's factors. If the device values
  differed, a peel would fork the run from the one the host would have
  taken, and no test could tell a peel bug from rounding.
- Determinism. Newton cannot converge on a solve that is not a function of
  its inputs.
- The oracle. The lane-axis doctrine makes the host path the oracle. A
  bitwise target makes every device refactor checkable with `==`
  (`ESPICE_GPU_LU_CHECK`, §4.5), the way `ESPICE_GPU_EVAL_CHECK` checks the
  eval.

What bitwise requires of the kernels:

- Each value slot receives its subtractions in the host's order. In the
  refactor that is the stored U order of its column (the order
  `refactorTape` replays). In the forward solve, row r receives
  `y[r] -= l * y[k]` in ascending k; in the back solve, descending k.
- No contraction. The kernels write `a - l * u` in Zig's default float mode
  and never call `@mulAdd`. `gpu-evaluation.md` attributes one deck's
  CPU/GPU gap to contraction and fast math in the device image, so E2 reads
  the LU image's asm and must find no `fma` in the refactor or solves.
- IEEE division. NVPTX lowers a strict f64 `/` to `div.rn.f64`; AMDGPU
  expands it to a correctly rounded sequence. Both need a hardware check
  (E2). f64 denormals are on by default on both, as on the host.
- The zero skip. The host solve skips `y[k] == 0`, which only changes the
  sign of a zero result; the device keeps the skip so signed zeros agree.
- Same tests, same order: zero or non-finite pivot, `void_slots` nonzero,
  and the growth test `|d| < growth_limit * cmax` skipped on
  `scaled_pivot` steps. `cmax` is a max, which is exact in any order.

**Conformance.** The Newton test, the published iterate x_k and the time
grid stay as they are. That rules out anything that returns a different dx
than the host's direct solve (§3e).

**Mutated state.** While the device owns the factors, the host `SparseLu`
keeps a valid pattern but stale values; `direct.Solver`'s bypass copy must
not match, so a later host factor refactors rather than trusting it
(§4.5). The device owns L/U values, the done stamps, three tickets and a
fail word per iteration.

## 2. When the GPU can win

Per Newton iteration, with F flops per refactor:

```
host:    T_h = t_eval + t_combine + t_refactor(F) + t_solve
         (+ 16*nnz/B for the plane download when the eval is resident)
device:  T_d = t_eval + max(bytes_r / BW, S_r * h_r) + (S_L + S_U) * h_s
         + t_bus(n-vectors) + t_fixed
```

`S_r` is the refactor's span in dependent steps, `S_L` and `S_U` the
solves' spans, `h_r` and `h_s` the cost of one dependent step on the
device (a barrier plus an acquire of a done flag and a dependent L2 load),
`bytes_r` about 12 bytes per flop (a u32 destination and an f64 L value;
the read-modify-write stays in the column's own slots). All three spans
come from the host factor with O(nnz(L+U)) passes (E1, §5), so the model
can be priced before the first driver call, as `gpu.zig`'s `Cost` already
does for the eval.

Circuit LU is far below the f64 ridge even on consumer cards: about 2 flops
per 12 bytes, 0.17 flop/byte, where an RTX 4060 Laptop's f64 ridge is near
1 (its f64 rate is 1/64 of f32). So the refactor is bandwidth or latency
bound everywhere, and consumer f64 throughput does not disqualify it.

Regimes, by matrix class:

| Class | Structure after BTF + AMD | Expected on the device |
|---|---|---|
| Small, n below ~10k | refactor well under the ~40 µs fixed cost (`cost_fixed_us`) | loses; decline |
| RC ladders, inverter chains | depth near n (`inverter_chain_256`: 259 levels for 261 columns) | loses; tridiagonal decks already take the host Thomas path |
| MOS-heavy flat logic | fill 1 to 2x, few flops per nnz, wide early levels, then supply-rail columns last that depend on everything (4 columns held 49% of the opamp OP work) | refactor near host speed; the win is not downloading planes; the wide last columns bound the span (§4.2) |
| Extracted interconnect, ideal supplies | one RC tree per net: many independent nets, depth set by the longest wire, then the MOS and rail columns | wide levels; the good case for sync-free columns |
| Extracted power mesh | mesh-like: 8x fill on the 100x100 grid, 97% of its axpy work in supernodes | most flops per nnz; best bandwidth use; supernodal panels are the upgrade |

Published results bracket the gain. GLU3.0 beat 32-thread NICSLU by 3.51x
(arithmetic mean) in single precision, with one loss (0.98x on Raj1).
Chen's GPU left-looking refactor beat sequential KLU refactor by 24x but
ran at 0.78x of 16-thread NICSLU, bandwidth bound. Chen and Ren's DAC 2012
dispatcher sent a factor to the GPU only above about 200 Mflop. ORNL's
ACOPF solver, with KLU on the CPU and refactor plus solves resident on the
GPU, measured 2.4 to 3.4x faster factorization and 3.2 to 5.8x faster
triangular solves, the latter because the factors never moved. Our own
bound for a host level-scheduled refactor at 8 threads, ignoring barriers,
was 1.3 to 2.1x on the corpus matrices (`solver-perf-2026-09.md`).

The honest expectation: a real gain on the refactor above roughly 10^5
unknowns with fill, near break-even on the solve, and a large gain on
movement for decks whose eval is already resident, where today each
iteration downloads 16 bytes per nonzero.

## 3. The options

### (a) Refactor that replays our pivot tape

The host factor already records everything a replay needs: the pattern
(`lp/li`, `up/ui`), the pivot sequence (`q`, `pinv`, `prow`), void and
scaled-pivot steps, and for small matrices a flat tape
(`tape`: one `{dst, l, u}` per flop). `refactorTape` is bitwise
`refactorColumns` and is tested as such. The device kernel is that tape,
uncapped, compressed and executed a column at a time:

- In column k, U entry p (row i) subtracts L column i times the U value
  into column k's slots. The l slots are contiguous (L column i) and the u
  slot is p, so only the destination needs storing: one column-relative u32
  per flop, the `dmap`.
- Columns start in pivot order through a ticket counter and wait only on
  the columns their U entries name (sync-free, below). Within a column the
  U entries run in stored order; the L entries of one U entry hit distinct
  slots and run in parallel.

This is left-looking, as are KLU's refactor, our host and Chen's GPU
solver. Each column writes only itself, so it needs no atomics and no
double-U dependency analysis (that hazard belongs to GLU's right-looking
updates, `gpu-sparse-lu.md` §1).

**Pivoting and stability.** None on the device. The replay inherits the
host's refactor semantics exactly, including its permissive growth limit
(1e-12). KLU's guide warns that `klu_refactor` "can lead to numeric
instability" and recommends `klu_rcond`, `klu_rgrowth` or `klu_condest`;
Chen's DATE 2015 paper calls refactor "faster but not stable" and checks
each reused pivot against its column. Our growth monitor is that per-column
check. A failure peels (§4.4).

**Why sync-free rather than level sets.** Level scheduling needs a launch
or a grid barrier per level: 145 to 1,626 levels on GLU3.0's circuit
matrices, 292 on fourbitadder, 551 on the 100x100 grid. gompute has no
cooperative launch, and GLU3.0 already lost up to 40% of its GPU time to
driver overhead on a 100k-row matrix. With tickets,
a column waits only on its own dependencies, and the span is the weighted
critical path instead of the level count times a barrier. Deadlock freedom
comes from the ticket order: a block takes its ticket after it starts
running, tickets increase in pivot order, and a column depends only on
lower pivot steps, which blocks already running hold. That holds for any
grid size, the argument CUB's decoupled look-back scan relies on.
rocSPARSE's `csrsv` spins on done flags the same way.

**Memory.** Dominated by `dmap`: 4 bytes per flop. A factor with 5x10^7
flops needs 200 MB. Ceiling and upgrade in §4.1.

### (b) Triangular solves on the device

Forward and back substitution as a gather per row, rows sync-free in
level order. Row r of L computes `y[r] -= L[r,k] * y[k]` over its entries
in ascending k after waiting for each y[k], which is the host's per-row
order. This needs L and U transposed to rows once per pivot epoch, and a
level per row (host passes, O(nnz(L+U))).

A thread per row is fast but deadlocks if two rows of one warp or wavefront
depend on each other: AMD waves run in lockstep, and NVIDIA before Volta
did too. Sorting rows by level and padding each wave to one level removes
every intra-wave dependency; waves then take tickets in level order.
Liu et al.'s sync-free SpTRSV reported 2.1 to 2.3x over cuSPARSE's
level-set `csrsv2` with 44x cheaper preprocessing, on general matrices.

The single-rhs solve is thin. Its span is the depth of the L and U DAGs
times `h_s`, and on circuit matrices Chen measured the GPU losing to one
core. It stays on the device only because the factors live there: pulling
L and U down costs 8 bytes per factor entry per iteration, more than the
planes cost today. Batched right-hand sides (sweeps, sp ports, a lane
axis) are where device solves win outright.

### (c) cuDSS and the vendor libraries

cuDSS runs reordering on the host, then symbolic and numeric factorization
and solve phases on the device. Its REFACTORIZATION phase differs from
FACTORIZATION only under the BTF_COLAMD or COLAMD orderings; the other
orderings pivot locally inside supernodes, and NVIDIA's tips page calls
global pivoting "usually significantly slower" but the most robust. It has
a uniform batch mode (one pattern, many value sets) and a deterministic
mode that is bitwise run to run on one GPU architecture. It is at 0.8.0
with breaking API changes between minor versions, the wheel is about
109 MB per platform, and the license forbids combining it into anything
that would put it under an open-source license. cusolverRf, the older
refactor-only path, is deprecated in favor of cuDSS.

HIP has no cuDSS. rocSOLVER's `csrrf_*` routines are the closest: given P,
Q and the bundled L+U pattern from a host factor, `refactlu` scatters PAQ
and calls rocSPARSE `csrilu0` (ILU(0) on the filled pattern is exact LU
with frozen pivots), and `csrrf_solve` calls `csrsm`. That is option (a)'s
architecture in vendor code.

Taking either as a dependency would give two vendor code paths with two
sets of numerics, neither bitwise with the host, so a peel would fork the
run. It breaks the rule that kernel logic lives once in the shared path,
and adds a closed 0.x binary for NVIDIA only. Use cuDSS in E2 as a
speed-of-light reference on dumped matrices, from an out-of-tree harness.

### (d) BBD blocks on the device

`bbd.zig` factors each block (at most 64 unknowns) as a dense
partial-pivoting LU, forms `W_i = A_i^-1 E_i`, and reduces the Schur
complement `S - sum F_i W_i` in fixed block order, then factors S (at most
512). Every factor is a full dense factor; there is no replay.

On the device: one block of threads per BBD block (a 64x64 f64 panel is
32 KB of shared memory), dense pivoting inside it (an argmax over at most
64 rows, deterministic with the same tie rule as `dense_lu.zig`), then the
Schur sum as an ordered segmented reduction, the same pattern as the eval's
two-level reduce, and S factored on the host (512^2 doubles is 2 MB).

It is exact, deterministic and needs no pivot tape, since pivoting inside a
dense block is cheap. Two catches:

- Bitwise agreement needs the device to use the host's vector width in
  `dotSimd` and `axpySimdNeg`, whose partial sums depend on
  `suggestVectorLength` (4 on AVX2, 8 on AVX-512). The shared code would
  have to fix W at comptime.
- It applies only when the builder emits `BbdInfo` and `Bbd.init` accepts
  it: at least 8 blocks, blocks of at most 64, a border of at most 512.
  Flat post-layout netlists likely fail the border limit. E1 checks.

### (e) Iterative solves

GMRES or BiCGStab with ILU or block-Jacobi refreshed rarely would remove
the refactor from most iterations. It fails the contract:

- An inexact solve returns a different dx. `gpu-convergence.md` §10.1
  showed that publishing a solution one Newton step more accurate than
  ngspice's fails 10 corpus decks at rtol 3e-3. A dx that differs by a
  Krylov tolerance moves iterates in the same way, and deterministic dot
  products on the device need ordered reductions.
- Circuit Jacobians are hard to precondition: MNA voltage-source rows have
  zero diagonals, supply rails make dense rows, and the matrices are
  unsymmetric. Chen's appendix measured GMRES with an AINV preconditioner
  on a K20x against the direct solve: 2.27 against 0.012 on hcircuit,
  2742 against 0.37 on rajat24, and no convergence on asic_680k or
  asic_320k.
- We tried the favorable version. GMRES(10) right-preconditioned by the
  stale LU, as the modified-Newton fallback, cost more instructions than a
  plain refactor on 12 of 13 decks (`gpu-convergence.md` §10.4).

Verdict: no. It could return only inside a non-default native mode, after
that mode settles §10.1 with a tighter reference.

### (f) Assembly on the device

The eval already produces g, c, rhs and q on the device, reduced in the
CPU's order. Today every iteration downloads the planes, 16 bytes per
nonzero plus 16 per unknown, and the host combines `G + ag0*C`, factors
and solves. With the LU on the device, the planes can stay: a scatter
kernel forms `A = g + ag0*c` (the expression `combinePlanes` uses, without
contraction) straight into the factor's value slots, and only n-vectors
cross the bus.

Host-evaluated batches still stamp on the host. The slots they touch are
fixed by their tapes, so they form an **overlay**: a compact slot list.
The device gathers those slots, the host adds its stamps in today's order,
and uploads the final values, which replace (not add to) the device's.
Replacing keeps the host's summation order, so the result stays bitwise.
The ground pin's slot joins the overlay.

For decks whose devices all evaluate on the host (the common case: `auto`
keeps light models on the CPU), the same overlay works with the constant
Jacobian: `g_base` and `c_base` are uploaded once, and each iteration
uploads only the final g and c values at the slots non-constant batches
touch. In a post-layout deck that is the transistor slots, a small share
of nnz.

The effect on round trips is in §4.3. Syncs per iteration stay at one or
two. Bytes per iteration fall from O(nnz) to O(n + overlay).

### Comparison

| Option | Wins when | Pivoting | Device memory | Deterministic | Bitwise with host | Frozen boundary | CUDA + HIP via gompute |
|---|---|---|---|---|---|---|---|
| (a) tape replay | many flops per nnz, short critical path, n above ~10^5 | host full factor; device replays and monitors growth | 4 B per flop plus values | yes | yes | untouched: reads plane indices, owns new tables | yes, given atomics and acquire/release (§4.5) |
| (b) sync-free solves | factors already on the device; batched rhs | none needed | row lists, 8 B per factor entry | yes | yes, with the zero skip | untouched | yes, with level-packed waves |
| (c) cuDSS / rocSOLVER | NVIDIA, large matrices | cuDSS's own; rocSOLVER needs host P, Q | library-managed | cuDSS: per arch | no | untouched | no: two vendor paths |
| (d) BBD | hierarchical decks that pass `Bbd.init` | dense, on device | 32 KB panel per block | yes | only with a fixed vector width | untouched | yes |
| (e) iterative | never in default mode | preconditioner only | Krylov basis | only with ordered reductions | no | untouched | yes |
| (f) resident assembly | the eval is resident, or the constant Jacobian is large | n/a | the planes, already resident | yes | yes, with overlay replace | untouched | yes |

## 4. Recommended design

### 4.1 Data layout

The six questions, for the device mirror of one host factor (a "pivot
epoch": everything below is rebuilt when the host runs a full factor):

1. **In and out.** In: the host's frozen pattern and pivot sequence, the
   A values each iteration (resident planes or uploaded), rhs. Out: dx
   (n f64), the lowest failing pivot step (u32), and for the gates the
   residual and the diagonal of A (n f64 each).
2. **How many.** One epoch per `converger.Workspace`. n from 10^4 to 10^7,
   nnz(A) about 5n, nnz(L+U) 1 to 6x nnz(A) (GLU3.0's table), flops per
   refactor from 10^6 to 10^9, 10^3 to 10^6 iterations per query, and
   epochs (full factors) usually a handful per query.
3. **How wide.** Every index is u32: n, nnz and the value-slot count are
   below 2^32, and a factor with 2^32 flops would need 16 GB of `dmap`, so
   the cost model declines it first. `dmap` entries are column-relative
   slots, u32 in the first version. Flags are one u8 per step (bit 0 void,
   bit 1 scaled pivot). Done stamps are u32 iteration numbers, so flags
   never need clearing; on wraparound the context clears them once. Values
   are f64; an f32 Jacobian failed four decks on the device path
   (`gpu-evaluation.md`), and f32 factors would fail more.
4. **Access pattern.** Refactor block k reads `up[k..k+1]`, then for each U
   entry `ui[p]`, `dmap_off[p]` and a contiguous `dmap` run, the
   contiguous L values of the source column (coalesced, and reused by
   every column that names it, so often L2 hits), and read-modify-writes
   its own contiguous slot range. The solves read row lists contiguously
   and gather y and values. Hot: `val`, `dmap`, `dmap_off`, `up`, `ui`, the
   row lists, the permutations. Cold: flags (one byte per column), epoch
   metadata. Host only: `li` (the device never needs L's row indices; `dmap`
   replaces them for the refactor and the row lists for the solve).
5. **Lifetime.** An epoch allocation freed and replaced on each host full
   factor. Per-context buffers for A, y, rhs, dx, tickets and the fail
   word, allocated once. Pinned host staging per context, as for the eval.
6. **Parallel.** Columns sync-free in pivot order; the L entries of each U
   entry in parallel. Rows sync-free in level order. A lane axis (W value
   sets on one tape, a sweep or Monte Carlo batch) is the natural second
   dimension: it widens every column, which is what the narrow tail lacks.

SoA, all u32 unless noted:

| Array | Length | Meaning |
|---|---|---|
| `val` (f64) | nnz(U) + n + nnz(L) + 1 | column-contiguous values: column k is `[U_k, d_k, L_k]` at `off(k) = up[k] + lp[k] + k`, so no offset table; the last slot is the discard slot |
| `up`, `lp` | n + 1 | the host's U and L column pointers, unchanged |
| `ui` | nnz(U) | source column of each U entry, in stored order |
| `dmap_off` | nnz(U) + 1 | start of each U entry's run in `dmap` |
| `dmap` | F | destination slot of each flop, relative to `off(k)` |
| `amap` | nnz(A) | plane index (the frozen CSC order) to value slot; below-diagonal rows of a void column map to the discard slot, as in `buildTape` |
| `void_slots` | as host | plane indices that must stay zero for the replay to be valid |
| `flags` (u8) | n | void, scaled pivot |
| `lrow_ptr`, `lrow_col`, `lrow_slot` | n + 1, nnz(L), nnz(L) | L by rows, columns ascending |
| `urow_ptr`, `urow_col`, `urow_slot` | n + 1, nnz(U), nnz(U) | U by rows, columns descending |
| `lorder`, `uorder` | n, padded to wave width | rows sorted by solve level, each wave within one level |
| `pinv`, `q` | n | the host permutations |
| `done_r`, `done_l`, `done_u` | n | epoch-stamped completion flags |

Epoch size is about 4F + 16 nnz(L+U) + 8 nnz(U) + 4 nnz(A) + 53n bytes.
`dmap` dominates once F exceeds a few flops per factor entry.

`ponytail: dmap is u32; a column-relative slot fits u16 in all but the
widest columns. Split columns into a u16 list and a u32 list (existence,
not a flag) when E2 shows dmap traffic above 30% of refactor bytes.`

### 4.2 Kernel plan

Five kernels in one image (`arp_lu_*`), one launch each per iteration on
the eval's stream, no host wait between them:

```
scatter      one thread per plane entry p:
               A = g[p] + ag0 * c[p]          (overlay values replace g, c)
               val[amap[p]] = A; a_copy[p] = A
             one thread per void slot: A != 0 -> fail = 0
             equality with the last factored A (the host's simdEql rule:
               -0 == +0, NaN != NaN), and-reduced into a skip flag
             (val is zeroed by a fill before the scatter, as fillZero does)

refactor     one 64-thread block per column; k = atomicAdd(ticket_r, 1)
             for p in up[k]..up[k+1]:           # stored topological order
                 i = ui[p]
                 thread 0 spins until done_r[i] == epoch (acquire); barrier
                 u = val[off(k) + (p - up[k])]  # final: only earlier p wrote it
                 lanes t over L column i:       # distinct destinations
                     val[off(k) + dmap[dmap_off[p] + t]] -= val[lbase(i) + t] * u
                 barrier
             d = val[off(k) + |U_k|]
             void: d = 1. Else zero or non-finite fails; unless scaled,
               cmax = block max of |d| and |L slots|; L slots /= d;
               |d| < growth_limit * cmax fails
             failure: atomicMin(fail, k)
             barrier; thread 0 stores done_r[k] = epoch (release)

lsolve       permute in: y[pinv[r]] = -rhs[r]   (solveNeg negates first)
             one thread per row in lorder, waves ticketed in level order:
             acc = y[r]
             for (k, s) in L row r, k ascending:
                 wait done_l[k]; if y[k] != 0: acc -= val[s] * y[k]
             y[r] = acc; release done_l[r]

usolve       same over uorder, k descending, then z[i] = acc / val[diag(i)]
             permute out: dx[q[j]] = z[j]

A failure (fail != NONE) or the skip flag makes later blocks exit at once.
```

The span of the refactor is not its level count. A column walks its U
entries in order and waits at each on that entry's column, so its finish
time is

```
t = 0; for p in U_k in order: t = max(t, finish(ui[p])) + 1
finish(k) = t + 1
```

and `S_r = max finish`, O(nnz(U)) on the host. On MOS-heavy decks the
supply-rail columns come last with U columns thousands of entries long, and
each entry costs a barrier: this is where the kernel will spend its time.
The upgrade, if E2 confirms it, is a gather form for wide columns only
(per destination slot, its contributions in stored order; the column's own
DAG level-scheduled), chosen per column at epoch build.

Block width 64 is one AMD wave64 or two NVIDIA warps, and the kernel needs
nothing beyond gompute's block `barrier()` for intra-column sync. The
refactor's discard slot takes concurrent garbage writes from void columns;
it is never read.

### 4.3 Per-iteration flow and round trips

n unknowns, nnz plane entries, m overlay slots:

| Path | Syncs | Up | Down |
|---|---|---|---|
| today, host eval | 0 | 0 | 0 |
| today, resident eval | 1 | x: 8n | planes: 16 nnz + 16n |
| stage 1: device LU, host-uploaded A | 1 | A: 8 nnz, rhs: 8n | dx: 8n |
| stage 2: resident values, host companion | 2 | x: 8n; then overlay: 16m, rhs: 8n | rhs, q, diag(A): 24n, overlay gather: 16m; then dx: 8n |
| stage 3: companion on the device | 1 | x: 8n, overlay: 16m | dx, residual, diag(A): 24n |

At n = 10^6 and nnz = 5x10^6, today's resident path moves 96 MB down per
iteration, about 9 ms at the measured 11 GB/s; stage 2 moves about 48 MB
and stage 3 about 32 MB. At post-layout sizes the plane download alone can
exceed the device eval.

Stage 2 keeps the transient companion (`integrator.companionAt`) on the
host, because it reads q history the host owns. A second sync is about
15 µs against milliseconds of LU work at these sizes. Stage 3 moves
`companionAt` onto the device, but that code lives in analysis, not in a
kernel root, so it needs a decision on where shared analysis kernels live.
Do it only if E3 shows the second sync or the q download matters.

The converger's gates read the residual and `diagAt`, both n-vectors in
every stage. `x` updates and host-side limiting stay on the host.

### 4.4 Fallback and peel

The device mirrors the host's refactor decisions exactly, so a device
failure is a host failure. The peel:

1. The solve's download carries the fail word. `fail = k` means pivot step
   k failed. `atomicMin` gives the lowest failing step whatever the
   schedule, and every step below it computed the host's exact values, so
   k is the step at which the host refactor would have stopped. `fail = 0`
   from the scatter means a void slot turned nonzero, which the host checks
   before any column.
2. The host downloads the combined A (`a_copy`, 8 nnz; one more sync), runs
   `SparseLu.factor` (full re-pivot) through the ordinary `direct.Solver`
   path, and solves on the host. That iteration is bitwise a host-only
   iteration.
3. `SparseLu` bumps its pivot epoch. The context builds the new device
   tables on the host (O(F)) and uploads them on the stream; the next
   device refactor waits on the upload in stream order.
4. Hysteresis: more than one peel per 20 device refactors in a query
   demotes the query to the host solve for good, and `ESPICE_GPU_STATS`
   says why. `ponytail: fixed ratio; price peels in the cost model once E3
   measures their cost.`

The other paths out:

- A driver fault: fall back to the host for the rest of the query, as
  `GpuContext` does for the eval (`poisoned`).
- The tridiagonal and BBD engines: the device LU attaches only when
  `direct.Solver` runs the general `SparseLu`. A structured engine that
  demotes to `SparseLu` makes the device path eligible from then on.
- `matrix_sig` bypass: host logic, one u64 compare; the device skips the
  scatter and refactor launches.
- Lanes, later: a W-lane refactor returns a per-lane fail mask like
  `LaneLu`, and failed lanes peel to the scalar host path as in
  `freq_solve.zig`'s `solveBatch`.

### 4.5 What changes where

**`src/solver/sparse_lu.zig`.** Numerics untouched.

- `pattern_epoch: u32`, bumped by every successful `factor`.
- `deviceTape(gpa) !DeviceTape`: builds the tables of §4.1 from `lp/li`,
  `up/ui`, `prow`, `void_col`, `scaled_pivot`. The walk is `buildTape`'s
  without the `tape_max_flops` cap and with column-relative destinations.
  Two walks is the second instance; fold them into one when the second
  lands. Also the row transposes and the solve levels.
- `DeviceTape` is host memory, freed after upload.

**New `src/solver/lu_kernels.zig`** (std only). The kernel bodies, generic
over the pointer type and the sync operations (ticket, wait, publish,
barrier). The host instance runs them serially in ticket order, and a
threaded host instance is rank 3. `src/solver/tests.zig` checks the host
instance against `refactorColumns` and `solve` bitwise, on the existing
`SparseTests` matrices plus cases with void steps, scaled pivots and a
growth failure (same failing step). The file adds a pointer to that case in
`ref/SIMD-Strategies/verify.zig`, as AGENTS.md asks.

**New `src/solver/lu_device.zig`**, a kernel root like `device/eval.zig`:
imports gompute and `lu_kernels.zig` and exports `arp_lu_*`. The solver
module still imports only core. `build.zig` adds one `KernelRoot` (name
`lu`) to `emitKernels`, built whenever GPU kernels are.

**`src/solver/direct.zig`.** `Solver.invalidateValues()`: marks the bypass
copy stale without dropping the pattern, so the next host `factor`
refactors. Nothing else.

**`src/solver/converger.zig`.** `newton` gains one branch: when `sys` has
`deviceSolve` (comptime `@hasDecl`, like `evalFollows`), it calls
`sys.deviceSolve(ws, rhs, dx)` instead of `slv.factor` plus
`slv.solveNeg`. A false return (declined or peeled) runs the host pair.
The gates are unchanged.

**`src/analysis/Circuit.zig`, `GpuHook`.** New entries:

- `lu_solve(ctx, rhs, dx) LuOutcome` (`solved`, `peeled`, `declined`),
  forwarded by `Circuit.deviceSolve`;
- `lu_values(ctx, out)`, the `a_copy` download for a peel;
- stage 2: `eval_newton_resident(ctx, x, t)`, which leaves the planes on the
  device and brings down rhs, q, the diagonal and the overlay gather.

Stage 2 makes `g_vals` and `c_vals` stale on the host between Newton evals.
`Circuit` gets `planes_on_device: bool`, set by the resident eval and
cleared by every full `eval`, `evalQ` and `linearize`. In Debug, every host
reader of the planes asserts it false. `lin.x_ptr` is unaffected: the
resident eval is a plane writer and clears it like every other.

**`src/analysis/gpu.zig`.**

- An LU context that exists without resident batches, so a post-layout
  deck whose devices all run on the host can still factor on the device.
  Today `init` fails with `CircuitNotEligible` when nothing is resident;
  that becomes "neither the eval nor the LU was admitted".
- `Cost` gains the LU terms of §2, with `h_r`, `h_s` and the bandwidth
  measured in E2 and recorded next to the existing constants.
- Epoch upload, the five launches, the overlay gather and replace, the
  peel download.
- `ESPICE_GPU_LU_CHECK`: after each device refactor, refactor on the host
  from `a_copy` and compare `val` and dx bitwise, printing the first
  mismatch.
- `ESPICE_GPU_STATS`: epochs, peels, skips and per-kernel time.

**gompute.** The kernels need what the eval kernels never did: u32
`atomicAdd` and `atomicMin` on global memory, acquire loads and release
stores at device scope, and optionally a sleep in the spin loop
(`nanosleep` on sm_70 and up, `s_sleep` on AMD). If Zig's `@atomicRmw`,
`@atomicLoad` and `@atomicStore` lower on `addrspace(.global)` for both
NVPTX and AMDGCN, gompute adds nothing. Otherwise they become builtins
beside `barrier()`. gompute's own notes say its AMDGCN path has never run
on AMD hardware, so HIP support means "compiles" until someone runs E2 on
an AMD card.

**The frozen boundary.** Untouched. The scatter reads plane indices in the
frozen CSC order; every LU table is new and sits beside the tapes. The
device ABI and `layout_hash` do not change, but the LU kernel root still
needs the default (GPU) build.

## 5. Experiments

Each has a decision rule. The first is host-only and can run on the CPU
build; the post-layout decks are the input to all three.

**E1. Structural census and host time split.** Extend `ZP_LU_STATS` (or a
test harness over dumped patterns) to print per full factor: n, nnz(A),
nnz(L), nnz(U), F, the refactor span `S_r` (§4.2), the level count, the
solve spans `S_L` and `S_U`, the widest U column, the share of F in columns
whose level holds fewer than 64 columns, rows or columns above 1,000
entries (rails), and the epoch bytes of §4.1. Also whether the builder
emitted `BbdInfo` and what `Bbd.init` said. Then the wall-time split per
deck on the CPU and on `--backend cuda`: eval, combine, refactor, full
factor, solve, plane download, with refactors and full factors per Newton
iteration.

- Continue to E2 only if refactor plus solve plus plane download is at
  least 40% of wall time on at least half of the post-layout decks
  (Amdahl caps the gain at 1/(1 - share)).
- If `Bbd.init` accepts most of them, rank (d) first and build it before
  (a).
- If `S_r` is within 10x of n, the critical path is serial and the gather
  form for wide columns (§4.2) comes before any tuning.

**E2. Kernels in isolation (stage 1).** Host-uploaded A, device refactor
and solves, on CUDA and on HIP where hardware exists. Inputs: the
post-layout matrices, plus two synthetic ones that separate the ceilings: a
bidiagonal chain (pure span, gives `h_r` and `h_s`) and a block-diagonal
matrix of many independent small blocks (pure bandwidth, gives BW).
Measure µs per refactor and per solve pair; the same body on 1 and 8 host
threads (rank 3); cuDSS on the same matrices, with our ordering if it
accepts a user permutation (reference only); and `ESPICE_GPU_LU_CHECK` mismatches, which must
be zero on every iteration. Check the PTX and the AMDGPU asm for `fma` in
the refactor and solve bodies; there must be none.

- Continue to E3 if device refactor plus solve is at least 2x faster than
  the better of 1 and 8 host threads on the decks E1 passed, with zero
  mismatches.
- If it is not, and the threaded host kernel is 1.5x or better, ship rank 3
  alone behind `ESPICE_SOLVER_THREADS`.
- If cuDSS beats our kernel by more than 3x, look at the gap (supernodes,
  ordering) before tuning ours.

**E3. End to end with resident values (stage 2).** Per deck: syncs and
bytes per Newton iteration, peels per 1,000 refactors, wall time against
today's `--backend cuda` and `--backend cpu` (median of 5, load noted), and
what `auto` picks against what was faster. Gate: `zig build test-gpu` with
no new failures, and raw outputs bitwise equal to the same build with the
device LU off, on every deck where it activates (it is bitwise by
construction, so any difference is a bug).

- Ship behind `auto` only with at least 1.3x wall time on the post-layout
  set and no deck where `auto` picks a slower path.
- Build stage 3 only if the second sync or the q download is at least 10%
  of the device iteration.

## 6. Rejected and deferred

| Idea | Status | Reason |
|---|---|---|
| GLU's right-looking kernel | rejected | atomic accumulation is not deterministic (`gpu.zig` `Order`: 2.1e-10 drift, dt underflow) |
| Level-set launches per level | rejected | 145 to 1,626 levels times a launch; gompute has no grid barrier |
| cuDSS or rocSOLVER as a dependency | rejected | vendor-only, not bitwise, two code paths, NVIDIA one closed and 0.x |
| Iterative default solve | rejected | §10.1 conformance; Chen's GMRES numbers; our §10.4 result |
| f32 factors plus refinement | rejected for default | f32 Jacobians already failed four decks; LU is bandwidth bound, so f32 saves at most 2x of the traffic |
| MC64 static pivoting (GLU) | rejected | replaces the host's threshold pivoting, so no host oracle |
| Supernodal refactor on the device | deferred | pays on extracted power meshes (the grid's 97% supernodal axpy); after E2 |
| Partial refactor of changed columns only | deferred | `README.md` open question 6; host and device alike |
| Batched lanes on the device (sweeps, MC, AC) | deferred | the same kernel with W values per slot; fixes the narrow tail; after stage 2 |

## Sources

Our code and docs, read at `96807bd`: `src/solver/sparse_lu.zig`
(`refactorColumns`, `buildTape`, `refactorTape`, `solve`),
`src/solver/direct.zig`, `src/solver/lane_lu.zig`, `src/solver/bbd.zig`,
`src/solver/converger.zig` (`newton`, `finalizeStep`),
`src/analysis/gpu.zig` (`Cost` constants, `Order`, `enqueueEval`),
`src/analysis/Circuit.zig` (`GpuHook`, `combinePlanes`),
`src/analysis/tran/tran.zig` (`TranHook`), `src/device/eval.zig` (the
`@mulAdd` note), gompute `src/device/builtins.zig`,
`docs/devices/gpu-evaluation.md`, `docs/solvers/gpu-convergence.md`,
`docs/solvers/solver-perf-2026-09.md`, `docs/solvers/gpu-sparse-lu.md`.

External, each read at the source:

- GLU: K. He, S. X.-D. Tan et al., IEEE TVLSI 2016,
  https://intra.ece.ucr.edu/~stan/papers/tvlsi_gpu_lu14.pdf (19.56x over
  KLU; MC64, AMD and symbolic analysis on the CPU).
- GLU3.0: S. Peng, S. X.-D. Tan, arXiv:1908.00204,
  https://arxiv.org/pdf/1908.00204 (3.51x/2.81x over 32-thread NICSLU,
  0.98x on Raj1, single precision; fill and level counts per matrix).
- X. Chen, L. Ren, Y. Wang, H. Yang, IEEE TPDS 2015,
  https://nicsefc.ee.tsinghua.edu.cn//nics_file/pdf/publications/2015/IEEE%20TPDS_147.pdf
  (24.24x over KLU refactor, 0.78x of 16-thread NICSLU, GPU triangular
  solve 3.16x slower than one core, GMRES/AINV appendix).
- L. Ren, X. Chen et al., DAC 2012,
  https://nicsefc.ee.tsinghua.edu.cn//nics_file/pdf/publications/2012/DAC12_56.pdf
  (the ~200 Mflop CPU/GPU dispatch threshold).
- X. Chen et al., DATE 2015,
  https://nicsefc.ee.tsinghua.edu.cn/nics_file/pdf/publications/2015/DATE15_23.pdf
  (per-column pivot check; refactor "faster but not stable").
- KLU user guide, SuiteSparse,
  https://raw.githubusercontent.com/DrTimothyAldenDavis/SuiteSparse/stable/KLU/Doc/KLU_UserGuide.tex
  (`klu_refactor`, `klu_rgrowth`, `klu_rcond`).
- cuDSS documentation, https://docs.nvidia.com/cuda/cudss/ (types,
  advanced features, release notes, license); PyPI `nvidia-cudss-cu12`
  for the wheel size; cuSOLVER documentation for the cusolverRf
  deprecation, https://docs.nvidia.com/cuda/cusolver/index.html.
- rocSOLVER refactorization reference,
  https://rocm.docs.amd.com/projects/rocSOLVER/en/latest/reference/refact.html,
  and its source under `projects/rocsolver/library/src/refact` in
  https://github.com/ROCm/rocm-libraries (`csrilu0`, `csrsm`); rocSPARSE
  `csrsv_device.h` in the same repository (spin-waiting on done flags).
- ORNL ACOPF solvers on V100 and MI250X, arXiv:2306.14337,
  https://arxiv.org/pdf/2306.14337.
- W. Liu et al., sync-free SpTRSV, Euro-Par 2016,
  https://www.ssslab.cn/assets/papers/2016-liu-sptrsv.pdf.
- M. Naumov, NVIDIA NVR-2011-001,
  https://research.nvidia.com/sites/default/files/pubs/2011-06_Parallel-Solution-of/nvr-2011-001.pdf
  (level-set analysis and solve).

Not verified at the source: whether cuDSS's REFACTORIZATION keeps the
first factorization's pivots (the documentation does not say), and whether
any AMD library matches cuDSS (none found).
