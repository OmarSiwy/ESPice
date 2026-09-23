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
