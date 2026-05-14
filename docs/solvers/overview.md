# src/solver: linear and nonlinear solvers

`src/solver/` imports only `core`, and build.zig wires it into `analysis`
alone. Every solve runs on the host; the GPU evaluates device planes only
(`src/analysis/gpu.zig`). Analysis code imports the module as `solver`:

```zig
const solver = @import("solver");
```

## Module map

```
root.zig          exports the files below; `test` pulls in tests.zig
direct.zig        Solver: the fixed-pattern facade every Newton caller uses
  tridiag.zig     Thomas algorithm, picked when the pattern is tridiagonal
  bbd.zig         bordered block diagonal engine, picked when a BbdInfo split pays
  sparse_lu.zig   Gilbert-Peierls left-looking LU with refactor replay
  order.zig       BTF (maximum transversal + Tarjan SCC) and per-block AMD
lane_lu.zig       LaneLu(W): W frequency lanes replaying one SparseLu pivot tape
freq_solve.zig    FreqSolver: (G + jwC) x = b in stacked-real form
dense_lu.zig      DenseLu(T): partial-pivoting dense LU (rank-8 panels for n >= 40)
fft.zig           radix-2 complex FFT and inverse
gmres.zig         Gmres: restarted, right-preconditioned GMRES(m)
converger.zig     Newton and JFNK loops, acceptance gates, per-circuit Workspace
tests.zig         unit and differential tests (scalar oracle vs vector kernel)
```

## Direct solver

`direct.zig` chooses its engine from the pattern alone: tridiagonal, then BBD
when `bbd` describes a profitable split, else sparse LU on a BTF + AMD
ordering. A structured engine that meets a singular pivot is demoted to the
sparse LU for the rest of the solver's life.

```zig
var slv = try solver.direct.Solver.init(gpa, n, col_ptr, row_idx, bbd_info); // bbd_info: ?BbdInfo
defer slv.deinit();

try slv.factor(vals);   // returns at once if vals equal the last factored values
slv.solveNeg(rhs, dx);  // dx = -A^-1 rhs, the Newton step
slv.solve(rhs, x);      // x = A^-1 rhs
slv.solveT(rhs, x);     // x = A^-T rhs, for adjoint analyses
```

`col_ptr` and `row_idx` are borrowed and must outlive the solver. `factor`
refactors on the existing pivot sequence and falls back to a full
re-pivoting factor when the replay fails the growth monitor.

`Params` is a field of the solver (`slv.params`), not an init argument:

| Field | Default | Meaning |
|---|---|---|
| `execution` | serial | scheduler for the BBD block factors |
| `pivot_tol` | 1e-3 | threshold partial pivoting keeps the diagonal while \|diag\| >= pivot_tol * column max |
| `refactor_growth_limit` | 1e-12 | a replayed pivot below this fraction of its column max forces a full factor; 0 disables |

There is no iterative refinement and no choice of ordering: the ordering is
always BTF + AMD.

## Frequency-domain solver

`freq_solve.zig` solves (G + jwC) x = b as the 2n real system
[G, -wC; wC, G]. Circuits with n <= 16 use a dense LU; larger ones use a
sparse 2n pattern derived once from the circuit CSC. Both keep their own
copy of G and C, so re-evaluating the circuit does not change the sweep.

```zig
var fs = try solver.freq_solve.FreqSolver.fromCircuit(gpa, ckt, x_op);
defer fs.deinit(gpa);

try fs.solve(omega, rhs, x);          // setOmega + solveRhs
try fs.setOmega(omega);               // factor once per omega
try fs.solveRhs(rhs, x);
try fs.solveRhsT(rhs, x);             // adjoint
try fs.solveBatch(omegas, rhs, x_out, adjoint); // W omegas per LaneLu pass
```

`FreqSolver.initDense(gpa, n, g, c)` builds the dense form directly from
row-major G and C. `solveBatch` runs W frequencies per `LaneLu` replay and
solves every 2n block of `rhs` against each factorization; any lane whose
refactor fails peels to the scalar per-omega path. `addDiagG` adds to a
diagonal of the solver's G copy (sp's port terminations).

## Nonlinear solves

`converger.zig` is generic over the system (`sys`) and its assembly hook.
The module doc comment lists the fields and optional methods it expects.

```zig
var ws = try solver.converger.Workspace.init(gpa, n, col_ptr, row_idx, bbd);
defer ws.deinit(gpa);

const opts = solver.converger.optionsFromTolerances(tol, null); // null: max_iter = itl1
const r = try solver.converger.run(sys, &ws, x, t, opts, hook);
// r.converged, r.iterations, r.max_dx
```

`run` calls `newton` (direct Newton on `ws.slv`) unless `ESPICE_SOLVER` pins
JFNK, and falls back to `newton` when the pinned JFNK fails. `jfnk`
(GMRES(30) with finite-difference Jacobian products, preconditioned by the
factored Jacobian) is also called directly as rung 4
of the operating-point ladder in `src/analysis/dc/op.zig`.

## Other kernels

- `dense_lu`: `factorizeSolve`, `factorizeSolveNeg`, `factorize`,
  `solveFactored`, `solveFactoredT`, `buildComplexAdmittance`. Used by tf,
  pz, disto, HB, PAC/PXF, pnoise, MATEX projections and the dense PSS
  shooting Jacobian.
- `fft`: `fft`, `ifft`, `nextPow2`. Used by `.four` and PAC.
- `gmres`: `Gmres.init(gpa, n, m)` then `solve(&op, b, x, tol,
  max_restarts)`, where `op` has `matvec(v, w)` and, for a right
  preconditioned solve, `precond(r)`. Used without a preconditioner by
  matrix-free PSS shooting (above 50 unknowns) and QPSS. JFNK carries its own
  GMRES(30) inside `converger.zig`, in `Workspace.gmres`.
- `order`: `order` (BTF + AMD) and `amd` on a caller-supplied `Ws` slab of
  `wsSize(n, nnz)` u32s.

## Environment variables

| Variable | Effect |
|---|---|
| `ESPICE_SOLVER=direct\|jfnk\|jfnk-nolu` | pins `converger.run`; `jfnk-nolu` uses a Jacobi preconditioner and never factors |
| `ESPICE_NO_BBD` | forces the flat sparse LU, for A/B comparisons |
| `ZP_OPDBG` | traces operating-point iterates and ladder rungs |
| `ZP_NEWTON_DEBUG` | prints per-iterate Newton norms |
| `ESPICE_HB_TRACE` | traces harmonic-balance iterates |
| `ZP_LU_STATS` | prints n, nnz and fill per full factor |

## Tests

```sh
zig build test-solver
```
