# Handoff: solver performance pass (2026-09)

Two passes. Details, retired experiments and follow-ups are in
`docs/solvers/solver-perf-2026-09.md`.

## Pass 2 (branch `worktree-agent-a2a7be1e9219c3d1d`, based on main `6bfb0c0`)

All builds and tests in this pass are `-Dgpu=false` (coordinator
instruction). The GPU-kernel build and its test run were not done here.

### Verification of pass 1

`a87cb8c` (pass 1 tip) against `bcc13b3` (its base), both `-Dgpu=false`,
every one of the 616 fixture decks run with `--backend=cpu`: raw files,
stdout, stderr and exit codes are byte-identical except
`ac/bench_medium_ladder_filter` raw (1394 of 7128 values, max abs 5.1e-13,
max rel 2.4e-6), as documented. `zig build test -Dgpu=false` at `a87cb8c`:
unit tests 302/302, correctness 518/616 with the same failure list as main
(`scaling_inverter_chain_4k` fails as Timeout or ValueMismatch depending on
machine load).

### Committed

| change | numbers |
|---|---|
| `SparseLu.factor`: supernode panels + DFS scan end (`lend`), bitwise | grid factor 212.6M -> 123.3M Ir; `scaling_resistor_grid_100x100` 357.5M -> 272.4M Ir; circuit decks within 0.05% |

### In progress

- Small-matrix refactor tape (task b): flat `{dst, l, u}` slot triples,
  one loop per column, used when the factor has at most 2048 flops.
  Prototype (scratch tree) is bitwise the column refactor on every dump;
  per Newton step (factor + solveNeg, bench Ir) vacask_mul 3223 -> 2790,
  vacask_graetz 2900 -> 2568, inverter_chain_256 83.7k -> 70.1k.

## Pass 1 (branch `worktree-agent-ab9985e38396806c7`, based on main `bcc13b3`)

### Committed

| commit | change | numbers |
|---|---|---|
| `bbcf852` | LaneLu local slices + zero-on-consume; `solveBatch` drops the per-chunk scalar refresh | AC bench 1,654M -> 772M Ir; `sweep_opamp_wl_5000` 3584 -> 2739 ms median. 190/191 AC-family decks bitwise identical; `ac/bench_medium_ladder_filter` differs by at most 5.1e-13 abs (repivots at a lane's omega) |
| `d237b37` | `SparseLu.factor`: local slices, register DFS cursor, per-column reservation | grid factor ~347M -> ~210M Ir; `scaling_resistor_grid_100x100` 484M -> 357M Ir, 308 -> 218 ms. All 615 decks bitwise identical |
| `b5cbca9` | fix: `w` zeroed on a singular full factor; exact LaneLu masks under the self-hosted backend | no perf claim; 615 decks bitwise identical |
| `c74392b` | converger: one 4-wide pass for x_old/x += dx/norm; `norm_f` only when printed | `rc_ladder_100k` -8.6% Ir, vacask rc/mul -3.3%. 615 decks bitwise identical |
| `ef8d056` | `DenseLu`: rank-8 panel updates for n >= 40, bitwise the unblocked LU | n=640 36.7 -> 12.8 ms, n=100 171 -> 83 us; HB deck was 95% in this kernel |

Every commit: `zig build -Dgpu=false` and `zig build test -Dgpu=false`
green (unit tests 299 -> 302, correctness 518/616, the same pass set as main,
diffed through `c74392b`).

### Not done

- No uncommitted work.
- Final verification of `ef8d056` on the default build (`-Dgpu=true`), a
  pass-set diff and a full-corpus raw diff for it, and the HB deck's
  end-to-end before/after were not run.
- `zig build bench` (needs `nix develop .#benchmarking`) was not run.

### Left, ranked by remaining solver share

- Full factor on high-fill matrices (59% of `resistor_grid_100x100`): needs
  a supernodal numeric phase.
- Tiny-n refactor + solve overhead (about 30% of vacask_mul/graetz, n=10..12):
  diffuse per-column cost; hand-stepped loops gave only 8% (parked).
- Ordering computed once per executor (1.5 to 2% on big decks): cache it with
  the prepared pattern (outside solvers/).
- `scaling_inverter_chain_4k`: 321 of 360 s are the OP falling back to
  pseudo-transient continuation (`dc/op.zig`), not the solver.

### Solver profile (self Ir share, after `c74392b`)

| deck | total Ir | refactor | full factor | solve | lanes | converger |
|---|---|---|---|---|---|---|
| resistor_grid_100x100 | 356M | | 59.3% | 1.5% | | 0.1% |
| sweep_opamp_wl_5000 | 7,295M | 14.7% | 2.3% | 3.3% | 18.5% | 0.3% |
| vacask_mul | 12,156M | 22.4% | | 9.1% | | 4.2% |
| vacask_graetz | 18,229M | 20.1% | | 7.7% | | 4.8% |
| rc_ladder_100k | 11,538M | 5.2% | 0.9% | 10.6% | | 6.4% |
| inverter_chain_256 | 4,867M | 9.2% | | 3.0% | | 0.5% |
| lc_energy_trap | 485M | | | | | 14.3% |
