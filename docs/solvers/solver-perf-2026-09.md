# Solver performance pass (2026-09)

Machine: i9-14900HX (AVX2 + FMA, no AVX-512, 4 f64 lanes), zig 0.16.0,
ReleaseFast. Instruction counts come from callgrind on a `-Ddebug-info`
build; wall times are hyperfine medians and were taken on a shared machine
(load average 20 to 120), so treat small-deck wall deltas as noise and read
the Ir column.

## Where solver time went before this pass

Self Ir of solver code as a share of the whole run, by bucket. "refactor" is
`SparseLu.refactor` inlined into `direct.factor`; "lanes" is `LaneLu`
inlined into the AC batch; "converger" is converger.zig's own loops.

| deck | total Ir | refactor | full factor | solve | lanes | converger |
|---|---|---|---|---|---|---|
| stress/scaling_resistor_grid_100x100 (op, n=10k, 8x fill) | 484M | | 70.0% | 1.1% | | 0.2% |
| stress/sweep_opamp_wl_5000 (op + ac, 2n=30k) | 8,814M | 22.6% | 2.4% | 2.8% | 20.3% | 0.8% |
| stress/vacask_mul (tran, n=12) | 12,567M | 21.6% | | 8.8% | | 6.9% |
| stress/vacask_graetz (tran, n=10) | 18,638M | 19.7% | | 7.5% | | 6.5% |
| stress/scaling_rc_ladder_100k (tran) | 12,613M | 4.7% | 0.8% | 9.7% | | 14.2% |
| stress/scaling_inverter_chain_256 (tran) | 4,913M | 9.1% | | 2.9% | | 1.4% |
| tran/lc_energy_trap | 483M | | | | | 14.4% |
| tran_noise/rc_equilibrium | 869M | | | 5.5% | | 13.4% |

On the AC decks, the scalar pivot refresh `solveBatch` ran per chunk (not
in the table, attributed to `setOmegaSparse`) was another 16%.

`stress/scaling_inverter_chain_4k` (360 s) is not a solver problem: 321 s is
the OP falling through to pseudo-transient continuation (24k steps in
`dc/op.zig`) at about 1 ms per Newton iteration, the same per-iteration cost
as the 2000-stage chain.

## Frequency lanes: LaneLu and FreqSolver.solveBatch

`LaneLu.refactor` indexed `self.w` and `self.lx` inside the axpy. A `[]V`
store may alias `self`, so both slice pointers were reloaded per element; the
kernel now works on local slices, the same hoist `SparseLu.refactor` has. It
also zeroes each `w` slot as it consumes it instead of zeroing the column
pattern first (SparseLu's invariant). A structurally void pivot is not
replayed: every lane fails and peels to the scalar ladder, which owns the
void logic.

`solveBatch` used to refactor the scalar solver at each chunk's middle omega
before the lane replay. LaneLu borrows only the index arrays from that
factorization, so the numeric result was discarded; the refactor only
mattered on the rare chunk where it tripped the growth monitor and
repivoted. The lanes run the same monitor per lane, bit-identical to the
scalar replay, so a decaying lane now fails, peels to the serial path, and
that full factor repivots the tape for the next chunk. A scalar factor still
runs when none exists yet.

Divergence: when a sweep repivots, it now repivots at the failing lane's
omega instead of the chunk middle. `ac/bench_medium_ladder_filter` is the one
corpus deck where this happens: 1394 of 6880 output values change, max
absolute difference 5.1e-13 (max relative 2.4e-6, on an entry of about
2e-7). The other 190 frequency-domain decks (ac, noise, sp, stb, pnoise, pac,
pxf, disto, tf, pz, multi_analysis, layout, sweep_opamp) are bitwise
identical. Fallback: restore the `setOmegaSparse` call at the top of the
chunk loop.

| measure | before | after |
|---|---|---|
| `solveBatch`, fourbitadder lifted to 2n=1982, 91 omegas (bench Ir) | 1,654M | 772M |
| `sweep_opamp_wl_5000` wall, median of 9 | 3584 ms | 2739 ms |
| `bench_medium_ladder_filter` Ir | 3.55M | 2.95M |

### Retired: 8 lanes instead of 4

`LaneLu(8)` (two ymm per entry) halves the index loads per lane and cut bench
Ir another 22% (772M to 600M). Wall time moved only 3 to 7% at 91 omegas
(fourbitadder 2n: 20.0 to 18.1 ms min; 8x block-diagonal tiling, 2n=15856:
205 to 192 ms), because the per-entry traffic doubles. One 8-lane chunk
costs about 1.86 four-lane chunks, so short sweeps lose to ragged-tail
waste (10 points: 3 chunks of 4 against 2 chunks of 8, about 3.7 chunk
costs). Kept at the native width.

## Full factor: SparseLu.factor

The Gilbert-Peierls factor had the problem `refactor` had before its hoist:
the numeric axpy indexed `self.w`, `self.li.items` and `self.lx.items`, so
every element reloaded three slice pointers (about 12 Ir per element), and
the DFS kept its resume cursor in `self.pstack[sp]`, a load and a store per
edge. The column loop now works on local slices, keeps the cursor in a
register, encodes an unpivoted row as the empty range [0, 0) instead of a
NONE sentinel (one compare per edge), and reserves each column's U and L
growth once (`nt` bounds both) instead of a capacity check per append. The
reservation sits before the scatter, so an OutOfMemory leaves `w` zero.
Same operations in the same order: the factors are bitwise identical.

| measure | before | after |
|---|---|---|
| factor, 100x100 grid Laplacian (bench Ir per factor) | ~347M | ~210M |
| factor, fourbitadder n=991 (bench min wall) | 647 us | 499 us |
| `scaling_resistor_grid_100x100` whole run Ir | 484M | 357M |
| `scaling_resistor_grid_100x100` wall, median of 11 | 308 ms | 218 ms |

### Supernode panels (second pass)

After the hoist, the 100x100 grid factor was still 59% of its deck:
about 80M Ir of DFS and 96M Ir of scatter-axpy per factor (12.4M axpy
elements). The fill there is supernodal. Consecutive steps s, s+1 with
L[:,s] = {row of s+1} ∪ L[:,s+1] hold 97% of the axpy elements in
supernodes of width 2 or more, and 69% in width 16 or more. Circuit matrices
have almost none (`parallel_inverters_2000`: 0%, `inverter_chain_256`:
0.4%). The one other case is the AC real-equivalent 2n matrix, where each
complex entry is a 2x2 block: `sweep_opamp_wl_5000` has 73% in supernodes
of width 4 to 7 with short row lists.

The data questions, answered before the code:

1. In: the column being factored (dense `w`, its reach in topo order) and
   the finished columns of L. Out: the same `w` updates, U entries and L
   column as the column-at-a-time loop, bit for bit.
2. How many: one panel per supernode, a few thousand per factor on the grid;
   one full factor per deck on the linear decks this targets.
3. Widths: steps, rows and slots are below n or |L|, so u32, matching every
   other index in `SparseLu`.
4. Access: a run of panel steps reads the panel column-major (contiguous per
   member step) and gathers/scatters `w` once per row per run, not once per
   (row, step). Block rows go through a dense scratch so the triangular part
   is contiguous axpys.
5. Lifetime: scratch of one `factor` call, capacity retained with the other
   L/U lists. `refactor` never reads it.
6. Parallel: rows of a run are independent lanes (4 f64 per ymm). Columns
   are not (left-looking dependency).

What it does, all inside `factor`:

- `lend[s]`: the DFS scan of L[:,s] stops just after the row pivoted at
  s+1 when every later entry of L[:,s] is in L[:,s+1]. Descending into that
  child marks all of them, so the skipped checks could only have found
  marked rows: the traversal, and so the topological order, is unchanged.
- Panels: when step k joins step k-1's supernode (and the supernode started
  on an L column of at least 32 rows), column k is copied into a dense
  column-major panel whose first rows are the supernode's own pivot rows in
  step order. When the reach walks a run of consecutive steps of one panel,
  the run is applied as a dense triangular solve on those block rows plus a
  4-wide update of the remaining rows. Per row the subtractions still happen
  in step order, mul then sub (no FMA contraction), so the result is
  bitwise the column loop's. The run is contiguous in the topological order
  by construction, so no other column's update interleaves.
- Two copies of the column loop (`inline for` over a comptime flag): the
  plain loop runs until some L column reaches 32 rows, then the supernodal
  loop takes over. Circuit matrices stay in the plain loop.

Differential test: `SparseTests` "factor: supernode panels are bitwise the
column-at-a-time refactor" (24x24 grid plus a void unknown, f64 and f32):
`refactor` replays the stored U order one column at a time, and its L, U
and diagonal must equal the panel factor's exactly. asm (`-mcpu=native`):
the row kernel is `vbroadcastsd` + `vmulpd ymm` + `vsubpd ymm`, the block
axpy `vmulpd`/`vsubpd ymm`; no `vfmadd`/`vfnmadd` anywhere in `factor`.

| measure (callgrind Ir) | before | after |
|---|---|---|
| bench, one factor of the 100x100 grid Laplacian | 212.6M | 123.3M |
| `scaling_resistor_grid_100x100` whole run | 357.5M | 272.4M |
| `scaling_resistor_grid_32x32` whole run | 20.36M | 19.98M |
| `scaling_parallel_inverters_100` whole run | 353.83M | 353.74M |
| `sweep_opamp_wl_200` whole run | 279.20M | 279.31M |
| `scaling_inverter_chain_256` whole run | 4,715.5M | 4,713.5M |

All 616 corpus decks produce byte-identical raw files, stdout and exit
codes (one stderr differs in the order of two parallel HDL loader lines).

Tuning and dropped variants, bench Ir for three factors plus setup:

- Always-on supernode bookkeeping (link scan per column, panel check per U
  entry, no loop switch): grid 675M to 450M, but circuit matrices paid 8 to
  12% more per factor (opamp AC 2n 453M to 495M, `parallel_inverters_2000`
  46.6M to 50.7M). The comptime loop switch brought those to +0.7% and
  +1.4%, and whole-deck Ir moves by under 0.05%.
- Panels finalized only when a supernode ends: the columns of the supernode
  still growing were applied one at a time, which on the grid is most of
  the work (538M against 508M for incremental panels, before the other
  changes).
- `panel_min_rows` 8 and 16: grid 423M and 421M against 419M at 32; 8 opens
  panels on the opamp's 2x2 complex blocks and costs 21% there.
- The `lend` shortcut alone: grid 675M to 626M.

Not done: the DFS is now the larger half of the grid factor. A supernodal
DFS (one adjacency scan per supernode, as SuperLU does) changes the
traversal order and with it the per-row summation order, so every full
factor in the corpus would move by rounding. Sorting the reach by pivot
step (a valid topological order) before the numeric phase would make the
order independent of the DFS and allow pruning; that is a deliberate
one-time FP change and was left for a separate decision.

## Small matrices: the refactor tape

On the vacask decks (n = 10 and 12, nnz 36) a Newton step's factor plus
solve cost about 3,200 Ir (bench: `direct.Solver.factor` on new values plus
`solveNeg`, over 2,000 steps). The work is about 36 A entries, 36 flops and
20 L entries; the rest is loop control on trip counts of 1 to 3. LLVM
unrolls the A scatter by 8, so each column pays the unrolled loop's guard
chain (12 Ir per A entry), and every U entry pays a `scatterAxpy` preamble
(about 35 Ir per call). `refactor-tape-2026-09.md` recorded a flat tape
losing on fourbitadder (110k flops, a 220KB tape streamed with no reuse) and
listed "tiny n, the tape fits in L1" as the case that would reopen it.

The data questions:

1. In: A's values in CSC order. Out: lx, ux, udiag, the same bits as the
   column replay.
2. How many: one refactor per Newton iterate, about a million per vacask
   run, each on the same pattern.
3. Widths: slots and flops are below |L| + |U| + n + 1, u32 like the rest
   of `SparseLu`. u16 would fit these matrices; not tried, the Ir is in
   loop control, not bytes.
4. Access: the tape streams in order, one {dst, l, u} triple per flop (read
   together, so AoS). The slot values `tv` are ux ++ udiag ++ lx ++ one
   discard slot, so an A entry, a U value, a pivot and an L value are all one
   index space and nothing goes through the dense `w`.
5. Lifetime: built at the end of each full factor with the pivot order;
   valid until the next one.
6. Parallel: no. Flops of a column depend on the previous columns' L.

`refactorTape`: zero `tv`, scatter A through `amap` in one pass, then per
column one flat loop `tv[dst] -= tv[l] * tv[u]` and the pivot check and L
normalization on a contiguous slice, then copy out to ux, udiag and lx. A U
value is read in place: its slot is final before any flop reads it (the
same argument that lets the column loop zero `w[i]` as it consumes it). Same
operations per slot in the same order, so bitwise the column loop. Built
only when the factor has at most 2,048 flops (a 24KB tape). The zero fill
and the copies are hand-laned: a compiler_rt `memset` call cost 760 Ir per
refactor on vacask_mul's 100 slots, which cancelled the whole win in the
first cut.

`refactorColumns` (the previous loop) is still the path above 2,048 flops
and is the oracle: SparseTests "refactor: the small-matrix tape is bitwise
the column replay" runs eight value sets (f64 and f32) through both on a
40-unknown matrix with a zero-diagonal branch row and a void unknown,
including one set where the growth monitor fails in both.

| measure | before | after |
|---|---|---|
| bench Ir per Newton step, vacask_mul (n=12) | 3,223 | 2,790 |
| bench Ir per Newton step, vacask_graetz (n=10) | 2,900 | 2,568 |
| bench Ir per Newton step, inverter_chain_256 (n=261) | 83,738 | 70,065 |
| `vacask_mul` whole run Ir | 11,996.9M | 11,493.7M |
| `vacask_graetz` whole run Ir | 18,029.0M | 17,472.7M |
| `scaling_inverter_chain_256` whole run Ir | 4,713.5M | 4,616.5M |
| `scaling_parallel_inverters_100` whole run Ir | 353.7M | 348.5M |
| `scaling_resistor_grid_32x32` whole run Ir (no tape: 213k flops) | 19.98M | 20.03M |
| `vacask_mul` wall, min of 7 (load 25 to 40) | 3243 ms | 2859 ms |
| `scaling_inverter_chain_256` wall, min of 7 | 413.8 ms | 410.1 ms |

All 616 decks byte-identical in raw, stdout and exit code.

The forward substitution of a tape matrix then got the same treatment: one
flat pass over L in column order (`lsrc` gives each entry's column) with a
per-entry zero skip, instead of a `scatterAxpy` per column. The skip keeps
the column loop's semantics exactly: a zero y[k] leaves its rows alone, so a
-0 stays -0 (the differential case solves an all -0 right-hand side, which
catches a skip-free variant). Back substitution keeps its per-column loop,
since each column divides by its pivot before its entries run.

| measure (callgrind Ir) | before | after |
|---|---|---|
| bench per Newton step, vacask_mul | 2,790 | 2,688 |
| `vacask_mul` whole run | 11,493.7M | 11,358.5M |
| `vacask_graetz` whole run | 17,472.7M | 17,320.8M |
| `scaling_inverter_chain_256` whole run | 4,616.5M | 4,596.7M |
| `scaling_parallel_inverters_100` whole run | 348.5M | 347.1M |

## Converger: per-iterate O(n) passes

`newton` computed `norm_f = max |rhs|` on every iterate, and nothing but the
two debug prints read it; it now runs only when `ZP_NEWTON_DEBUG` or
`ZP_OPDBG` is set. `finalizeStep` copied `x` into `x_old` and then made a
second scalar pass for `x += dx` and the scaled-delta norm; `updateAndNorm`
now does both in one W-wide pass (the current-row mask selects abstol or
vntol per lane) with a scalar tail. Max is exact and order-independent, so
the result is bitwise the scalar loop's; the differential case covers
lengths 0 to 39 with NaN, inf and -0 inputs (ConvergerTests).

## Retired experiments

- **Dense LU for tiny systems.** The SIMD `DenseLu` (partial pivoting, the
  BBD block kernel) against sparse refactor + solve per Newton step: grid
  Laplacians n=9, 16, 25 cost 5101, 15047 and 37777 Ir per step dense
  against 2540, 5295 and 9205 sparse. Loses 2x to 4x even at n=9.
- **Level-scheduled parallel refactor.** Columns whose U pattern depends
  only on finished columns can run on worker threads with no FP change.
  Upper bound at 8 threads, ignoring barrier cost, from the real matrices:
  fourbitadder 1.32x (292 levels), 100x100 grid 1.43x (551 levels),
  `sweep_opamp_wl_5000` OP 1.81x and AC 2n 1.64x, `parallel_inverters_2000`
  2.10x, `inverter_chain_256` none (259 levels for 261 columns). AMD's
  elimination trees are deep, and on the replicated stress decks the shared
  supply and bias columns land last and depend on every instance (4 serial
  columns hold 49% of the opamp OP work). Solver threads are also opt-in
  (`ESPICE_SOLVER_THREADS`, default 1). Not built.
- **Hand-stepped loops in `refactor`** (scatter and L normalize, the
  `scatterAxpy` treatment): 7 to 9% fewer Ir per refactor at n=9 to 16, no
  change at n=991. Bitwise identical but under 2% of the n=12 vacask deck.
  Parked.

## Follow-ups outside `solvers/`

- **Ordering computed per executor.** The OP and tran executors each build
  a Circuit and a `converger.Workspace`, and each runs BTF + AMD on the same
  frozen pattern: two `computeOrdering` calls, 95M Ir each on
  `scaling_rc_ladder_100k` (1.5% of the run; about 2% on the 100x100 grid).
  The ordering belongs with the prepared pattern; `direct.SolverT` would
  take it as an input instead of computing it.
- **`scaling_inverter_chain_4k`.** 321 of its 360 s are the OP falling
  through to pseudo-transient continuation in `dc/op.zig`.
