# GPU LU for large Newton solves: design

**Status: stage 1 built; the multicore host refactor (option 3) is on by
default.** The kernel body in `src/solver/lu_kernels.zig` runs as the
device LU (`lu_device.zig`, `src/analysis/gpu_lu.zig`) and as a refactor on
host threads (`HostRefactor`, picked by `direct.Solver`). Both are bitwise
`SparseLu.refactor` (plus `solve` on the device). The host form runs
whenever the query has more than one thread (`ESPICE_THREADS`, or
`ESPICE_SOLVER_THREADS`) and its flop-count model admits the epoch; see
"Multicore host refactor" in §5. The device form is `auto` under a GPU backend at n of 10k or more, on
every pivot epoch with at least 500 flops per column (`GpuLu.min_per_col`),
whatever the card's FP64 rate; `ESPICE_GPU_LU=1` forces it on and `=0` off.
On this RTX 4060 (FP64 at 1/64) its kernels lost to 8 host threads in
isolation (E2), but end to end it wins 2-4x over the host LU that `cuda`
runs by default ("E3, host"), so stage 2 was not started and stage 1
ships. The GPU otherwise only evaluates device
planes (`docs/devices/gpu-evaluation.md`). This page answers one question:
if the host sparse LU dominates on post-layout netlists (extracted RC plus
many transistors), how should espice factor and solve on the GPU? The
theory behind level-set GPU LU (GLU, NICSLU) is in `gpu-sparse-lu.md` and is
not repeated here. The conformance constraints come from
`gpu-convergence.md` §2.6 and §10.

§4 is the design as proposed. Stage 1 as built departs from it in the
solves and a few mechanics; "Stage 1 as built" in §5 lists what changed
and why, with the measurements.

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
   Each iteration's device work is one captured graph, replayed with a
   single launch (§4.3). Staged: (1) kernels fed by host-uploaded values,
   (2) resident values, (3) the companion on the device, one sync per
   iteration, (4) k iterations per launch with the gates on the device.
2. **BBD blocks on the device** (option d), only if the census (E1) finds
   post-layout decks that take the BBD engine. Flat extracted netlists
   probably do not: RC parasitics couple the subcircuit blocks, and
   `Bbd.init` declines a border above 512.
3. **The same kernel on host threads.** Rank 1's kernel body compiles for
   the host too. Run on worker threads with the same tickets, it is a
   multicore refactor (NICSLU's pipeline mode) with identical bits. It is
   the yardstick the GPU must beat, and a fallback where no GPU exists.
4. **cuDSS** (option c): not an option. Every kernel goes through gompute,
   written once in our Zig and compiled for CUDA and HIP; there is no
   vendor library and no C shim. cuDSS serves only as a performance
   reference in E2.
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

Determinism is a hard constraint: no float atomics anywhere. The only sum
in assembly is today's staged plane reduce, reused as is; the scatter into
the factor's slots is injective, so it needs neither atomics nor coloring.
The kernels use integer atomics only for tickets, which order the schedule
and never touch a value.

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
  (`ESPICE_GPU_LU_CHECK`, §4.6), the way `ESPICE_GPU_EVAL_CHECK` checks the
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
(§4.6). The device owns L/U values, the done stamps, three tickets and a
per-column fail byte.

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
check. A failure peels (§4.5).

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

Tickets need a u32 `atomicAdd` and the waits need acquire loads and release
stores, none of which gompute has today (§7). A static column-per-block
assignment without the ticket can deadlock, because neither vendor
promises to dispatch blocks in index order. Plan B, if the atomics stall:
one kernel per level, captured into a graph (§4.3). It is deterministic
and needs nothing gompute lacks except graphs, and its span becomes the
level count times one graph node's launch latency.

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

### (c) cuDSS and the vendor libraries (reference only)

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

Neither is an option: the project routes every kernel through gompute,
with no vendor library and no C shim. They would also give two vendor
code paths with two sets of numerics, neither bitwise with the host, so a
peel would fork the run. cuDSS appears only in E2, as a speed-of-light
reference on dumped matrices from an out-of-tree harness that nothing in
the build depends on.

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

None of this adds a reduction. Contributions are summed once, by the
existing staged reduce (`gpu.zig` `Order`, two levels in the serial CPU
order). The scatter from plane index to factor slot is injective (distinct
entries of a column have distinct rows), and the overlay replaces distinct
slots, so no two threads write one value and no coloring is needed.

For decks whose devices all evaluate on the host (the common case: `auto`
keeps light models on the CPU), the same overlay works with the constant
Jacobian: `g_base` and `c_base` are uploaded once, and each iteration
uploads only the final g and c values at the slots non-constant batches
touch. In a post-layout deck that is the transistor slots, a small share
of nnz.

The effect on round trips is in §4.4. Syncs per iteration stay at one or
two. Bytes per iteration fall from O(nnz) to O(n + overlay).

### Comparison

| Option | Wins when | Pivoting | Device memory | Deterministic | Bitwise with host | Frozen boundary | CUDA + HIP via gompute |
|---|---|---|---|---|---|---|---|
| (a) tape replay | many flops per nnz, short critical path, n above ~10^5 | host full factor; device replays and monitors growth | 4 B per flop plus values | yes | yes | untouched: reads plane indices, owns new tables | yes, given u32 atomics and acquire/release (§7) |
| (b) sync-free solves | factors already on the device; batched rhs | none needed | row lists, 8 B per factor entry | yes | yes, with the zero skip | untouched | yes, with level-packed waves |
| (c) cuDSS / rocSOLVER (reference only) | NVIDIA, large matrices | cuDSS's own; rocSOLVER needs host P, Q | library-managed | cuDSS: per arch | no | untouched | no: vendor code, outside gompute |
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
| `done_r`, `done_l`, `done_u` | n | completion flags stamped with the iteration number |
| `fail` (u8) | n | per-column refactor failure, cleared by a fill node each iteration |
| `params` | one small struct | every per-iteration scalar the LU kernels read (ag0, gmin, growth limit, iteration stamp), so their graph nodes never change (§4.3) |

Epoch size is about 4F + 16 nnz(L+U) + 8 nnz(U) + 4 nnz(A) + 53n bytes.
`dmap` dominates once F exceeds a few flops per factor entry.

`ponytail: dmap is u32; a column-relative slot fits u16 in all but the
widest columns. Split columns into a u16 list and a u32 list (existence,
not a flag) when E2 shows dmap traffic above 30% of refactor bytes.`

### 4.2 Kernel plan

Six kernels in one image (`arp_lu_*`), one node each in the iteration's
graph (§4.3), on the eval's stream, no host wait between them:

```
scatter      one thread per plane entry p:
               A = g[p] + ag0 * c[p]          (overlay values replace g, c)
               val[amap[p]] = A; a_copy[p] = A
             one thread per void slot: A != 0 -> vfail = 1
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
             failure: fail[k] = 1 (a byte per column, no atomic)
             barrier; thread 0 stores done_r[k] = epoch (release)

status       one block: the lowest k with fail[k] != 0 (or 0 when
             vfail), as a block-wide min in shared memory in a fixed tree
             order; writes the status word the solves and the host read

lsolve       permute in: y[pinv[r]] = -rhs[r]   (solveNeg negates first)
             one thread per row in lorder, waves ticketed in level order:
             acc = y[r]
             for (k, s) in L row r, k ascending:
                 wait done_l[k]; if y[k] != 0: acc -= val[s] * y[k]
             y[r] = acc; release done_l[r]

usolve       same over uorder, k descending, then z[i] = acc / val[diag(i)]
             permute out: dx[q[j]] = z[j]

Refactor blocks check vfail and the skip flag on entry and exit at once.
Solve blocks exit when the status word says a step failed.
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
nothing beyond gompute's block `barrier()` and shared memory for
intra-column sync and the column max. The bypass equality test and the
status min are our own block reductions with a fixed tree, not
`gompute.reduce`, which folds its partials on the host and so cannot sit
inside a captured graph. The
refactor's discard slot takes concurrent garbage writes from void columns;
it is never read.

### 4.3 Launch: one captured graph per iteration

Today an iteration is a chain of separately submitted copies and launches
on one stream: the x upload, the staging fill, one eval kernel per resident
batch, two reduces, the plane download, and the limit pass. The device LU
adds a fill, the scatter, the refactor, the status kernel and two solves.
Every submission costs host time and leaves a gap on the device.
`gpu-convergence.md` §1.2 measured a fixed 150 µs per Newton iteration on
small MOS decks (launches, two syncs, the limit pass, at `ee66e0b`), and
`gpu.zig` still books about 40 µs of launch and wait around 111 µs of device
work per eval on `mos1_2000`. On small decks that overhead is most of the
iteration.

ZINC (MIT licensed, a Zig GPU LLM engine) removes the same overhead with
stream capture. It records a decode step's kernel chain on its stream,
instantiates the graph once, and replays it with one launch per step
(`src/cuda/cuda_shim.c`, `cuda_graph_begin` and `cuda_graph_end_launch`;
the hipGraph twin is in `src/rocm/rocm_shim.c`). Every per-step scalar is
read from a device buffer uploaded before the launch, never passed as a
kernel argument, so the topology and the node parameters stay the same and
`cuGraphExecUpdate` is a cheap no-op. When the driver rejects an update,
ZINC re-instantiates. The replay runs the same kernels in the same order on
one stream, so it is bit-identical to the uncaptured chain
(`src/compute/forward_cuda.zig`, `decodeBatchGraph`). The brief reports
+6.7% on an RTX 4090, where launches dominated, and -2.9% on a Radeon R9700,
where they did not. I did not find those measurements in the ZINC checkout.

Rules that make an espice iteration capturable:

- Nothing inside the captured region waits on the host: no stream sync, no
  host fold (so no `gompute.reduce`), no readback that decides what runs
  next. Data-dependent control stays on the device as early exits: the
  bypass flag and the status word make later kernels return at once.
- Every scalar our kernels read per iteration comes from the `params`
  block. Its upload, the x upload and the downloads are copy nodes inside
  the graph. A copy node reads and writes pinned host memory when the graph
  runs, not when it was captured, so fixed pinned addresses are all it
  needs.
- Grid sizes depend on n, nnz and the pivot epoch only.
- Buffers keep their addresses for a pivot epoch. A new epoch (after a
  peel) reallocates the tables, and the context captures and instantiates
  again. Epochs are rare.
- The eval kernels are the exception. Their arguments are frozen at the GPU
  boundary and carry `SimState` (t and the Newton iteration count) and
  `limiting` by value, so those nodes change every iteration. Graph update
  accepts new parameter values on an unchanged topology, so the context
  re-captures each iteration (host-side recording, no device work) and
  updates in place. E2 prices that against plain launches; if it loses,
  the eval launches go ahead of the graph on the same stream.

Capture changes no numbers: same kernels, same order, one stream. Outputs
must be bitwise equal with `ESPICE_GPU_NOGRAPH` set.

Graphs and waits per Newton iteration, by stage:

| Stage | Graph launches | Waits | Host work between |
|---|---|---|---|
| today, resident eval | none (one submission per copy and kernel) | 1 | host batches, combine, factor, solve |
| 1: host eval, device LU | 1 | 1 | none inside the iteration |
| 2: resident values, host companion | 2 | 2 | overlay stamps, companion |
| 3: companion on the device | 1 | 1 | none |
| 4: k iterations per launch | 1 per k iterations | 1 per k iterations | none |

Graph replay removes submission cost and the gaps between kernels. It does
not remove the wait itself, about 15 µs each (`gpu-evaluation.md`). Only
stage 4 removes waits.

**Stage 4: k iterations per launch.** With the Newton gates on the device,
one graph can hold k unrolled iterations: eval, reduce, scatter, refactor,
solves, update and limit, then the gate, which writes a `done` word that
every later node checks on entry. Iterations past convergence or a failure
cost one empty kernel per node, a few microseconds on the device. One
small download per launch brings back the converged flag, the iteration
count and the norms. Graph conditional (while) nodes would avoid the empty
kernels, but HIP parity for them is not established, so the design
unrolls. k follows the deck's measured iterations per solve: 2.0 to 4.0 on
the corpus (`gpu-convergence.md` §10.3). Preconditions, all of which must
hold:

- Every batch is resident, so there is no overlay. `gpuEligible` already
  excludes Newton-history hooks.
- The gate code (`updateAndNorm`, the first-iterate and `init_fix` rules,
  the row-scaled residual gate, `checkConvergence`) compiles once for
  host and device, per the no-GPU-only-logic rule, never as a device copy.
  The norms are block reductions with a fixed tree; `updateAndNorm`'s max
  is exact in any order.
- The published iterate stays x_k, the last linearization point, as
  `newton` publishes it today.
- A peel inside the k iterations stops the rest, and the host resumes at
  that iteration.

This is the only stage that removes waits, and the largest change. It
comes after stage 3 and only on E3's numbers.

### 4.4 Per-iteration flow and round trips

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

### 4.5 Fallback and peel

The device mirrors the host's refactor decisions exactly, so a device
failure is a host failure. The peel:

1. The solve's download carries the status word. Status k means pivot
   step k failed. The status kernel takes the lowest failing step, which
   does not depend on the schedule, and every step below it computed the
   host's exact values, so k is the step at which the host refactor would
   have stopped. A void-slot failure from the scatter reports before any
   column, as the host checks it first.
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

### 4.6 What changes where

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
The gates are unchanged. Stage 4 only: the gate code of `finalizeStep`
moves into a body compiled for host and device, and `newton` calls that
body on the host, so there is still one implementation.

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
- Epoch upload, the six kernels, the overlay gather and replace, the
  peel download.
- The graph cache of §4.3: one exec per graph shape, re-captured per
  iteration only while the eval nodes' by-value arguments change, updated
  in place, re-instantiated on a new pivot epoch or a rejected update.
  `ESPICE_GPU_NOGRAPH` launches the same chain uncaptured for A/B, as
  `ESPICE_GPU_NOFUSE` does for the fused waits.
- `ESPICE_GPU_LU_CHECK`: after each device refactor, refactor on the host
  from `a_copy` and compare `val` and dx bitwise, printing the first
  mismatch.
- `ESPICE_GPU_STATS`: epochs, peels, skips and per-kernel time.

**gompute.** The requests are in §7, in priority order: device u32
atomics with acquire/release, graphs with capture, events, async
device-to-device copies, stream query. gompute's own notes say its AMDGCN
path has never run on AMD hardware, so HIP support means "compiles" until
someone runs E2 on an AMD card.

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

E1 ran on 2026-09-27 (`ZP_LU_STATS` census, `--timing-in-depth` split);
the tables are in `docs/devices/gpu-evaluation.md`, "Post-layout results".
Refactor plus solve reached 40% of wall time under `cuda` on 14 of 20
decks (all synthetic 10k and 100k ones) and on none of the three real
ones; `Bbd.init` declined every deck; `S_r` was within 10x of n on the
SRAMs and on every real deck, whose one supply column holds most of it.

**E2. Kernels in isolation (stage 1).** Host-uploaded A, device refactor
and solves, on CUDA and on HIP where hardware exists. Inputs: the
post-layout matrices, plus two synthetic ones that separate the ceilings: a
bidiagonal chain (pure span, gives `h_r` and `h_s`) and a block-diagonal
matrix of many independent small blocks (pure bandwidth, gives BW).
Measure µs per refactor and per solve pair; the same body on 1 and 8 host
threads (rank 3); cuDSS on the same matrices, with our ordering if it
accepts a user permutation (reference only); and `ESPICE_GPU_LU_CHECK`
mismatches, which must be zero on every iteration. Check the PTX and the AMDGPU asm for `fma` in
the refactor and solve bodies; there must be none.

- Continue to E3 if device refactor plus solve is at least 2x faster than
  the better of 1 and 8 host threads on the decks E1 passed, with zero
  mismatches.
- If it is not, and the threaded host kernel is 1.5x or better, ship rank 3
  alone behind `ESPICE_SOLVER_THREADS`.
- If cuDSS beats our kernel by more than 3x, look at the gap (supernodes,
  ordering) before tuning ours.

**E2 results (2026-09-28).** `ESPICE_GPU_LU=1 ESPICE_GPU_LU_CHECK=1
ESPICE_GPU_LU_BENCH=10` on a `-Dgpu=false` build (device evals on the
host; the LU kernels are built anyway), RTX 4060 Laptop, i9-14900HX, load
average 1.4-2.2. Medians of the first 10 device refactors of the transient
(the only query for the 100k decks, which start from `uic`), in ms. Device
times are CUDA event times of the kernels alone; the host columns are
`SparseLu.refactor` plus `solve` on one thread, and the same kernel bodies
with the refactor on 8 threads (`runHost`; its solves run on one thread,
as the host's do). The GPU held 2640 MHz with no throttle reason even at a
CPU load of 150, so the device columns do not move with host load.

| deck | n | F | dev refactor | dev solves | dev total | host 1 thr | kernels 8 thr | vs better host |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| logic_bsim4_10k | 38.6k | 167M | 11.7 | 10.0 | 21.7 | 103.1 | 28.5 | 1.31x |
| sram_bsim4_10k | 17.1k | 59M | 10.5 | 7.8 | 18.3 | 35.8 | 13.0 | 0.71x |
| chain_bsim4_10k | 44.9k | 2.9M | 3.2 | 3.8 | 7.0 | 3.3 | 8.1 | 0.47x |
| chain_bsim4_100k | 446k | 74M | 40.2 | 47.9 | 88.0 | 63.1 | 116.5 | 0.72x |
| ring_bsim4_100k | 442k | 70M | 28.4 | 60.2 | 88.6 | 69.3 | 111.8 | 0.78x |
| c7552_sky130 | 117k | 2.0M | 14.9 | 20.6 | 35.5 | 5.4 | 18.9 | 0.15x |

`ESPICE_GPU_LU_CHECK` compared every device refactor of those runs with the
host's, factors and dx, bitwise: 0 mismatches over 4,900 refactors (every
query to completion on the 10k decks, c7552 and both 100k decks). The
chain's operating point peeled 23 times, exactly where the host refactor
fails too. The raw outputs of logic_bsim4_10k, sram_bsim4_10k and
chain_bsim4_10k are byte-identical with the device LU on and off. The PTX has no `fma`
(`mul.rn.f64` and `sub.rn.f64`, which ptxas may not fuse, and
`div.rn.f64`); the HIP image is compile-only and its IR carries no
`contract` flag or `fmuladd`, but its asm was not read (no AMD toolchain
here).

The gate fails: 1.31x at best, and the device loses outright on the chain,
the 100k decks and c7552. Against the path that ships today (the host LU on
one thread) the kernels win 4.7x on logic_bsim4_10k and 2.0x on
sram_bsim4_10k. End to end (same build, one run each, load under 2.5) the
wall time fell from 176.8 to 65.1 s on logic and from 55.6 to 37.2 s on the
SRAM, and rose from 16.8 to 23.9 s on the chain. That is E3's 1.3x on two
decks of three, against a host path that 8 threads would beat; the gate
asks for the harder comparison, so E3 was not run.

Why, on this card:

- f64 runs at 1/64 of f32, two operations per clock per SM. In the dense
  trailing block (logic, SRAM) each column on the critical path costs its
  last U step, about a thousand IEEE divisions to scale L, and the handoff
  to the next column: about 3.5 µs, times the S_r of §4.2.
- Bitwise order forbids splitting a long row's sum. c7552's supply row is a
  49k-term chain in the refactor and in both solves.
- The solves are one block. On the 100k decks their wide head levels
  (hundreds of thousands of rows) run on one SM, latency-bound.
- The host kernel bodies on one thread are 1.2-2.6x slower than
  `SparseLu` (indirection and tickets), so "8 threads" beats one host
  thread only where F is large (logic 3.6x, SRAM 2.8x) and loses elsewhere.

**Stage 1 as built.** Departures from §4, each measured on
logic_bsim4_10k and chain_bsim4_10k (device ms, refactor/solves):

- Solves: one block, not sync-free row chunks across the grid. Chunks of
  64 rows, each waiting on every chunk of the level below, took 145 ms of
  solves on logic (one thread walks each dense-tail row serially). The
  built form runs the sparse head level by level (a gather per row, eight
  loads before their subtractions) and sweeps the dense tail column by
  column with the tail's y in shared memory, the host's own order. The
  cut is priced per epoch (`solveCost`, t0 from n - 16 to n - 4096):
  logic 145 -> 10.0 ms. 256 lanes, not 1024 (18.6 ms, register-starved);
  prefetching 2 entries per lane a step ahead, not 4 (10.6) or 8 (13.5);
  one lane divides in the back sweep (all lanes dividing cost 4 µs a step).
- Refactor: 64-lane blocks, a 256-slot shared scratch. A 3072-slot scratch
  cut residency (logic 17.7 -> 28.2, chain 6.8 -> 16.6); 128 and 256 lanes
  were 0.97-1.8x the time. The column max is a tree over the lanes (a
  serial fold cost 9.2 vs 7.1 ms on the chain, 61 vs 14 ms at 256 lanes).
  One barrier per U step, with the next source polled a window of 64 steps
  at a time (13.1 -> 12.4, 3.7 -> 3.5). The gather form serves the wide
  shallow columns (c7552's rail, 332 columns); on logic it neither helps nor
  hurts (17.3 vs 17.4).
- Done stamps use device-scope acquire and release (inline PTX in
  `lu_device.zig`): Zig lowers its atomics at system scope, and that cost
  15.0 vs 13.1 ms on logic and 7.1 vs 3.7 on the chain. §7 R6.
- Division is IEEE `/`. A reciprocal multiply (not bitwise, timing only)
  saved 12% on logic, so a Markstein division with a slow-path fallback is
  worth about that much.
- `ESPICE_GPU_LU_TAIL=m` and `ESPICE_GPU_LU_NOGATHER` override the cut and
  the gather form for calibration.

Next, if this is picked up again: multi-block head levels for the 100k
solves, and the Markstein division.

**Multicore host refactor (option 3).** `lu_kernels.HostRefactor` runs the
refactor body on the caller plus `lu_threads - 1` tasks of the query's
`std.Io` (one lane per "block"), then copies the column-contiguous values
into `SparseLu`'s `ux`, `udiag` and `lx`; the solve stays `SparseLu.solve`.
A failure is `refactor`'s failure, so the full re-pivoting factor follows
as before. `direct.Solver` judges each pivot epoch once: at least 500k
flops, at least 300 flops per column, at most 400M (the tables cost 4
bytes per flop). `ESPICE_LU_PAR=0/1` forces it, `ESPICE_LU_PAR_STATS`
prints each verdict. Host waits spin 256 times, then yield: without that,
chain_psp103_10k at a load of 98 spent 149 s factoring instead of 16.7.

The crossover, factor time summed over the run, `--backend=cpu`, serial
refactor vs the kernel body (all bitwise equal):

| deck | n | F | F/n | 2 thr | 4 thr | 8 thr |
|---|---:|---:|---:|---:|---:|---:|
| sram_bsim4_1k | 1.7k | 0.78M | 449 | 1.48x | 1.17x | 1.47x-1.55x |
| logic_bsim4_1k | 4.0k | 1.8M | 445 | 1.40x | 1.06x | 1.81x-1.94x |
| sram_bsim4_10k | 17k | 40M | 2,349 | | | 1.68x |
| logic_psp103_1k | 12.6k | 1.9M | 152 | 0.79x | 0.99x | 0.87x-1.03x |
| ring_bsim4_10k | 44k | 3.9M | 87 | | | 0.57x |
| chain_bsim4_10k | 45k | 2.9M | 63 | | | 0.39x |
| c7552_sky130 | 117k | 2.0M | 17 | | | 0.39x |
| stress/scaling_inverter_chain_4k | 4.0k | 20k | 4 | | | 0.08x |

The 2- and 4-thread rows ran at a load of 130-215 and are noisy; the
8-thread rows at 10-50 except where two runs are given. Below F/n of about
150 the columns form a chain and every step is a handoff; the admission
bar of 300 sits between the last loss and the first win.

E3 for the host path is below ("E3, host").

E2 also measures the launch strategy, and this part needs no LU kernel:
capture today's eval chain (x upload, staging fill, one eval kernel per
resident batch, two reduces, the plane download) and replay it. On
`mos1_2000` and `stress/scaling_parallel_inverters_2000`, record µs per
iteration outside device kernel time, with and without capture, and the
host cost of re-capture plus `update` when the eval's by-value arguments
change. Outputs must be bitwise equal with and without capture.

- Keep the eval nodes in the graph if re-capture plus update costs less
  than the launches it replaces; otherwise launch them ahead of the graph.

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
- Build stage 4 (k iterations per launch) only if, after stage 3, the one
  remaining wait per iteration is still at least 20% of the iteration on
  the decks that motivate it.

**E3, host.** Wall time, one run each (the 1k rows: three, all within
5%), 2026-10-01, i9-14900HX and RTX 4060 Laptop, load average in brackets.
`serial` is `--backend cpu`; `lu8` adds `ESPICE_SOLVER_THREADS=8` (the
multicore refactor); `cuda` evaluates on the GPU with the host LU on one
thread, `cuda8` with it on 8; `cudalu` adds `ESPICE_GPU_LU=1`.

| deck | F/n | serial | lu8 | cuda | cuda8 | cudalu |
|---|---:|---:|---:|---:|---:|---:|
| sram_bsim4_1k | 450 | 1.71 (2) | 1.60 (2) | 1.62 (3) | | 2.35 (3) |
| logic_bsim4_1k | 445 | 5.05 (3) | 4.00 (4) | 4.38 (5) | | 5.25 (5) |
| sram_bsim4_10k | 2,400 | 38.6 (4) | 27.3 (4) | 32.9-52.2 (5-9) | 26.0 (7) | 19.8-26.1 (6-10) |
| logic_bsim4_10k | 4,400 | 183.6 (9) | 85.7 (6) | 228-237 (8-15) | 114.9 (8) | 51.9-63.1 (5-12) |
| logic_psp103_10k | 1,600 | | | 357.2 (15) | 217.7 (5) | 86.1 (18) |
| chain_bsim4_10k | 63 | | 21.7 (5) | 9.9 (7) | 9.3 (6) | 11.6 (7) |
| ring_bsim4_10k | 87 | | 36.2 (7) | 20.1 (6) | 17.8 (6) | 24.4 (6) |

- The multicore host refactor pays end to end on every deck its bar
  admits: 1.07x on sram_bsim4_1k, 1.26x on logic_bsim4_1k, 1.41x on
  sram_bsim4_10k, 2.14x on logic_bsim4_10k.
- The device LU wins where the factor is thick: 2.0-4.1x over `cuda`'s
  default host LU and 1.0-2.5x over `cuda8`, on the three decks with F/n
  of 1,600 and up. It loses on the chain and the ring (F/n under 100),
  and on the E2 100k decks (about 160), so `auto` takes it from F/n 500.
  No deck between 166 and 1,600 has been measured.
- The 1k decks sit under `gpu_lu_min_n`; forced on, the device LU loses
  there (2.35 against 1.62 s).

### fast_mode (retired, deleted)

`direct.Params.fast_mode` (`--lu-fast`, C API `espice_create_options.lu_fast`,
default off) ran Newton's refactor in f32 and refined each solve back to
f64 accuracy (`src/solver/fast_lu.zig`). Off, nothing changed: the corpus
was byte-identical to the default path. The record below is what it
measured before it was deleted.

- The full factor, and so every pivot decision, stays f64 (`SparseLu.factor`).
  The f32 refactor replays its tape with the same kernel body, `T = f32`:
  on host threads (`HostFactor(f32)`, threads by the multicore model) or on
  the device (`arp_lu_*_f32`, when the device LU is on).
- Before it, A is equilibrated with powers of two, rows by their largest
  entry and then columns, so R A C is exact in f64 and a 1e60 conductance
  lands near 1 in f32. The scales stay f64.
- The f32 pivot monitor uses a growth limit of 1e-6; a failure sends that
  Newton iteration to the exact f64 refactor (and its re-pivot).
- Each solve: x = 0, r = b; per step d = C (LU_32)^-1 (R r), scaled into f32
  range by a power of two, x += d, r = b - A x in f64 over the f64 values.
  Stop when ||r|| <= 16 u (||A|| ||x|| + ||b||), u = 2^-53 (normwise
  backward error at f64 roundoff, infinity norms). A step that shrinks the
  backward error by less than half switches to GMRES-IR (Carson and Higham
  2017): up to 3 outer steps of GMRES(30) in f64, right-preconditioned by
  the f32 factors. Past 8 plain steps or 3 GMRES-IR steps the solve gave
  up and the exact f64 factor and solve ran for that Newton iteration, so
  no answer was worse than the f64 path's.

Corpus (`zig build test-fast`, 622 decks, `--backend cpu`): 613 pass and 9
fail, the same 9 as the default path, so no deck changes pass/fail. The
9 fail with their default reasons (ValueMismatch on
dc/device_vbic_forced_output, noise/device_vbic_noise_scale,
tran/bench_ngspice_mosamp, the two txl lines, tran/device_hfet_inverter,
tran/device_mesa_oscillator, tran/device_mos6_inverter; SimulatorFailed on
hdl/verilog_inverter). 531 decks take the fast path and change bytes; the
other 91 never refactor a general sparse LU in Newton (tridiagonal or BBD
engines, linear analyses only, or a parse error). Over all fast solves,
`ESPICE_LU_FAST_STATS`:

| | solves | steps per solve | GMRES-IR | fallbacks | f32 refactor failures |
|---|---:|---:|---:|---:|---:|
| 530 decks | 4,522,814 | 2.20 | 702 | 37 | 341 of 1.62M |
| stress/vacask_graetz | 1,994,308 | 5.34 | 1,990,097 | 699,852 (35%) | 5,714 of 2.0M |

The Graetz bridge's diodes swing the matrix across many decades each step,
so f32 refinement contracts slowly there and a third of its solves fall
back.

Wall time (same runs and columns as "E3, host"; `fast1` is `--lu-fast`
on one thread, `fast8` with `ESPICE_SOLVER_THREADS=8`):

| deck | serial | fast1 | lu8 | fast8 |
|---|---:|---:|---:|---:|
| sram_bsim4_1k | 1.71 | 2.25 | 1.60 | 1.94 |
| logic_bsim4_1k | 5.05 | 6.32 | 4.00 | 4.64 |
| sram_bsim4_10k | 38.6 | 46.0 | 27.3 | 28.4 |
| logic_bsim4_10k | 183.6 | 186.6 | 85.7 | 183.8 |

fast_mode loses on every deck, 2-32% against the f64 path at the same
thread count and 2.1x on logic_bsim4_10k at 8 threads. On
stress/vacask_graetz (n = 6) it costs 212.4G instructions against 15.8G
(callgrind, 13.5x): 1,990,100 of 1,993,548 solves fell to GMRES-IR and
698,182 of them to the f64 fallback. The refinement steps cost more than
the f32 refactor saves, even where the refactor dominates. **Retired and
deleted**, since no deck paid for it: `fast_lu.zig`, the `_f32`
device kernels, `HostFactor(f32)`, `--lu-fast`, `zig build test-fast`
and the C API's `lu_fast` field are gone. Removing the field (and its `reserved` pad) shrank
`espice_create_options` back to its ABI 1 size. Callers that set
`lu_fast` must drop it; binaries built against the longer struct still
load, because `espice_create` reads only the prefix it knows.
Restarting the idea means starting from git history and beating the f64
path on a deck first.

## 6. Rejected and deferred

| Idea | Status | Reason |
|---|---|---|
| GLU's right-looking kernel | rejected | atomic accumulation is not deterministic (`gpu.zig` `Order`: 2.1e-10 drift, dt underflow) |
| Level-set launches per level | plan B only | 145 to 1,626 levels times a launch; captured as graph nodes it is the fallback if device atomics stall (§3a) |
| cuDSS, rocSOLVER, or any vendor library or C shim | rejected | project rule: every kernel through gompute; also not bitwise, two code paths |
| Float atomics in assembly or LU | rejected | nondeterministic sums; the staged reduce and injective scatters cover every write |
| Graph conditional (while) nodes | deferred | stage 4 unrolls k iterations with early exits instead; HIP parity unknown |
| Iterative default solve | rejected | §10.1 conformance; Chen's GMRES numbers; our §10.4 result |
| f32 factors plus refinement | rejected for default | f32 Jacobians already failed four decks; LU is bandwidth bound, so f32 saves at most 2x of the traffic |
| MC64 static pivoting (GLU) | rejected | replaces the host's threshold pivoting, so no host oracle |
| Supernodal refactor on the device | deferred | pays on extracted power meshes (the grid's 97% supernodal axpy); after E2 |
| Partial refactor of changed columns only | deferred | `README.md` open question 6; host and device alike |
| Batched lanes on the device (sweeps, MC, AC) | deferred | the same kernel with W values per slot; fixes the narrow tail; after stage 2 |

## 7. gompute feature requests

Everything in this design goes through gompute. This section lists what
gompute lacks at `67f1983`, per the gompute session's inventory and a read
of `src/runtime/cuda.zig`, `src/host/raw.zig` and `src/device/builtins.zig`.
gompute already has streams (`createStream`, flags 0), `launchOn`, async
upload, download and fill on the per-backend `Buffer`, pinned host memory,
the block `barrier()` and `addrspace(.shared)` scratch. It had no graphs,
events, async device-to-device copy, stream query or device atomics; R1,
R6 and R2 to R5 below have since landed, and our pin (a91b9b1) carries
them all.

Every host-side shape below goes into `runtime/cuda.zig` and
`runtime/hip.zig` with identical signatures, and is re-exported through
`RawByName(be)` beside `Buffer` and `Stream`. The driver entry points join
the existing dlsym table. Priority order, kept as the record of what was
asked:

**R1. Device atomics and memory order** (`src/device/builtins.zig`). This
blocks the sync-free kernels; plan B (§3a) avoids it at a span cost.

```zig
/// Returns the old value. Device (agent) scope, relaxed. Integer only:
/// no float atomics, by design.
pub inline fn atomicAddU32(ptr: *addrspace(.global) u32, v: u32) u32;
/// Device-scope acquire: later loads see every write the releasing thread
/// made before its `storeRelease`.
pub inline fn loadAcquire(ptr: *addrspace(.global) const u32) u32;
/// Device-scope release.
pub inline fn storeRelease(ptr: *addrspace(.global) u32, v: u32) void;
/// Backoff in a spin loop: `nanosleep` on sm_70 and up, `s_sleep` on AMDGCN,
/// nothing elsewhere.
pub inline fn spinPause() void;
```

If Zig's `@atomicRmw`, `@atomicLoad` and `@atomicStore` lower correctly on
`addrspace(.global)` for NVPTX and AMDGCN, these are one-line wrappers; the
request is also for the compile check on both targets. For the host
instance, the same names on plain pointers use Zig's atomics directly.

**R6. Scoped acquire and release** (added after E2). Zig lowers
`@atomicLoad(.acquire)` and `@atomicStore(.release)` to `.sys` scope on
NVPTX, and the LU's done stamps paid for it (§5, E2). Requested:

```zig
/// Device (agent) scope: `ld.acquire.gpu` / `st.release.gpu` on NVPTX,
/// `syncscope("agent")` on AMDGCN.
pub inline fn loadAcquireDevice(ptr: *addrspace(.global) const u32) u32;
pub inline fn storeReleaseDevice(ptr: *addrspace(.global) u32, v: u32) void;
```

Delivered in gompute 064fcd8, which also made AMDGCN's `barrier()` fence
like `__syncthreads`; `lu_device.zig` uses them. a91b9b1 added
`fp64Ratio` (CUDA only; HIP answers `Unsupported`, which `auto` reads as
slow FP64).

**R2. Graphs with capture.**

```zig
pub const CaptureMode = enum { global, thread_local, relaxed };

// Context
/// CU_STREAM_NON_BLOCKING / hipStreamNonBlocking: a captured stream must
/// not synchronize implicitly with the legacy default stream.
pub fn createStreamNonBlocking(self: *Context) Error!Stream;

// Stream
pub fn beginCapture(self: *Stream, mode: CaptureMode) Error!void;
/// Ends the capture begun on this stream and returns the recorded graph.
pub fn endCapture(self: *Stream) Error!Graph;
/// For Debug asserts that nothing synchronizes inside a capture.
pub fn isCapturing(self: *Stream) Error!bool;

pub const Graph = struct {
    pub fn instantiate(self: *const Graph) Error!GraphExec;
    pub fn deinit(self: *Graph) void;
};

pub const GraphExec = struct {
    /// Enqueues one replay on `stream` and returns without waiting.
    pub fn launch(self: *GraphExec, stream: *Stream) Error!void;
    /// Updates this exec in place from `graph`, which must have the same
    /// topology. Returns false, leaving the exec unchanged, when the driver
    /// rejects the update; the caller then instantiates `graph` instead.
    pub fn update(self: *GraphExec, graph: *const Graph) Error!bool;
    pub fn deinit(self: *GraphExec) void;
};
```

`Error` gains `CaptureFailed` and `GraphFailed`. Driver calls: CUDA
`cuStreamCreate(CU_STREAM_NON_BLOCKING)`, `cuStreamBeginCapture`,
`cuStreamEndCapture`, `cuStreamIsCapturing`, `cuGraphInstantiate`,
`cuGraphExecUpdate`, `cuGraphLaunch`, `cuGraphExecDestroy`,
`cuGraphDestroy`. HIP `hipStreamCreateWithFlags(hipStreamNonBlocking)`,
`hipStreamBeginCapture`, `hipStreamEndCapture`, `hipStreamIsCapturing`,
`hipGraphInstantiate`, `hipGraphExecUpdate` (whose out-parameters are an
error node and a result enum, as ZINC's `rocm_shim.c` uses them),
`hipGraphLaunch`, `hipGraphExecDestroy`, `hipGraphDestroy`. The existing
`uploadAtAsync`, `downloadAtAsync`, `fillAsync` and `launchOn` must be
legal under capture; they are, as long as the host side is pinned.

**R3. Events.**

```zig
// Context
/// `timing` false sets CU_EVENT_DISABLE_TIMING / hipEventDisableTiming.
pub fn createEvent(self: *Context, timing: bool) Error!Event;

// Stream
/// Later work on this stream waits for `event`, without the host waiting.
pub fn waitEvent(self: *Stream, event: *const Event) Error!void;

pub const Event = struct {
    pub fn record(self: *Event, stream: *Stream) Error!void;
    pub fn synchronize(self: *Event) Error!void;
    /// True once the recorded work is done (CUDA_ERROR_NOT_READY and
    /// hipErrorNotReady map to false).
    pub fn query(self: *Event) Error!bool;
    /// Both events need `timing` true.
    pub fn elapsedUs(start: *const Event, end: *const Event) Error!f32;
    pub fn deinit(self: *Event) void;
};
```

`Error` gains `EventFailed`. Uses: the epoch upload after a peel runs on a
second stream and the next graph waits on its event; `Prof.phases` times
phases with events instead of synchronizing the stream after each one.

**R4. Async device-to-device copy.**

```zig
// Buffer
pub fn copyFromAsync(self: *Buffer, src: *const Buffer, src_offset: usize, dst_offset: usize, n: usize, stream: *Stream) Error!void;
```

`cuMemcpyDtoDAsync_v2` / `hipMemcpyDtoDAsync`. The plain `copyFrom` is
synchronous and cannot sit in a graph. Use: snapshotting the factored A
for the value bypass inside the graph.

**R5. Stream query.**

```zig
// Stream
pub fn query(self: *Stream) Error!bool;
```

`cuStreamQuery` / `hipStreamQuery`. Lets the host stamp overlay batches
while it polls, instead of blocking in `synchronize`. Lowest priority.

R2 to R5 were delivered in gompute 96cc593 ("runtime: graph capture and
replay, events, async DtoD, stream query"), with these signatures on CUDA
and HIP. The device LU already times with R3's events (`Bench` in
`analysis/gpu_lu.zig`); nothing captures a graph yet, so graph replay in
Newton is open and unblocked.

Not requested: device-resident reductions. The design's reductions (status
min, bypass equality, stage 4's norms) are ordinary kernels built from
`barrier()` and shared memory, written once in our shared path. Also not
requested: warp shuffles, conditional graph nodes, cooperative launch.

## Sources

Our code and docs, read at `96807bd`: `src/solver/sparse_lu.zig`
(`refactorColumns`, `buildTape`, `refactorTape`, `solve`),
`src/solver/direct.zig`, `src/solver/lane_lu.zig`, `src/solver/bbd.zig`,
`src/solver/converger.zig` (`newton`, `finalizeStep`),
`src/analysis/gpu.zig` (`Cost` constants, `Order`, `enqueueEval`),
`src/analysis/Circuit.zig` (`GpuHook`, `combinePlanes`),
`src/analysis/tran/tran.zig` (`TranHook`), `src/device/eval.zig` (the
`@mulAdd` note); gompute at `67f1983` (`src/device/builtins.zig`,
`src/runtime/cuda.zig`, `src/host/raw.zig`) and the gompute session's
inventory of it; ZINC (MIT), `src/cuda/cuda_shim.c` (graph capture, update
and launch), `src/rocm/rocm_shim.c` (the hipGraph twin),
`src/compute/forward_cuda.zig` (`decodeBatchGraph` and the capture notes);
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
