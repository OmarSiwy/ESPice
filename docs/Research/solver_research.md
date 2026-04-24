# Solver and Linear Algebra Crate Research

**Date:** 2026-04-16
**Crates examined:** `crates/solver/src/` and `crates/linalg/src/`

---

## 1. Newton-Raphson Algorithm Implementation

### 1.1 Core Iteration Formula

The Newton-Raphson (NR) algorithm solves the nonlinear system $F(x) = 0$ via the iteration:

$$x_{n+1} = x_n - J^{-1}(x_n) \cdot F(x_n)$$

In the circuit simulation context:
- **$x$** — the MNA solution vector: $[V_{node_1}, V_{node_2}, \ldots, I_{branch_1}, \ldots]^T$
- **$F(x)$** — the residual vector (KCL equations), computed by the stamper
- **$J(x) = \partial F / \partial x$** — the Jacobian matrix (also built by the stamper)

The actual solve uses the equivalent form:

$$J \cdot \Delta x = -F(x_n) \implies \Delta x = -J^{-1} \cdot F(x_n)$$
$$x_{n+1} = x_n + \Delta x$$

In `newton.rs` the hot loop solves this via:

```rust
// jac_triplet = J, residual = F(x)
let factors = lu_factorize(&jac_csc)?;
// neg_res = -F(x)  (RHS for Ax = b form)
for i in 0..dim { neg_res[i] = -residual[i]; }
let dx = lu_solve(&factors, &neg_res)?;
// x_new = x + dx (with damping)
```

### 1.2 Convergence Criteria

The `ConvergenceCriteria` struct (convergence.rs) implements **both** an update-based test AND a residual-based test, matching standard SPICE behavior:

**Update test (relative + absolute tolerance):**
$$\forall i: |dx_i| < \text{abstol} + \text{reltol} \cdot |x_i|$$

**Residual test:**
$$\forall i: |F_i(x)| < \text{i\_tol}$$

Where `i_tol = abstol × 1000` (SPICE convention, i.e., `RELTOL` for currents).

From SPICE `.OPTIONS` mapping:
- `abstol` → `abs_tol` (voltage tolerance, default 1e-12 V)
- `reltol` → `rel_tol` (relative tolerance, default 1e-6)
- `vntol` → `v_tol` (alternate voltage tolerance)
- `itl1` → `max_iter` (DC operating-point iteration limit, default 100)

The `check()` method in `ConvergenceCriteria` implements both tests and returns `true` only if **both** pass:

```rust
pub fn check(&self, dx: &[f64], x: &[f64], rhs: &[f64]) -> bool {
    let update_ok = dx.iter().zip(x.iter()).all(|(&dxi, &xi)| {
        dxi.abs() < self.abs_tol + self.rel_tol * xi.abs()
    });
    let residual_ok = rhs.iter().all(|&ri| ri.abs() < self.i_tol);
    update_ok && residual_ok
}
```

### 1.3 Damping Strategies

The `DampingStrategy` enum (damping.rs) supports three modes:

**1. `None` (no damping):** $x_{n+1} = x_n + \Delta x$ — pure Newton step.

**2. `Fixed(f64)`:** $x_{n+1} = x_n + \alpha \cdot \Delta x$ with fixed $\alpha \in (0, 1]$.

**3. `BankRose` (adaptive):** Halves the step when the residual grows:

$$x_{n+1} = x_n + \alpha \cdot \Delta x, \quad \alpha = \begin{cases} 0.5 & \text{if } \|F(x_{n+1})\| > \|F(x_n)\| \\ 1.0 & \text{otherwise} \end{cases}$$

The `DampingStrategy::apply()` method:

```rust
pub fn apply(&self, x_old: &[f64], dx: &[f64], x_new: &mut [f64], residual_grew: bool) -> f64 {
    let alpha = match self {
        Self::None => 1.0,
        Self::Fixed(a) => *a,
        Self::BankRose => if residual_grew { 0.5 } else { 1.0 },
    };
    for i in 0..x_old.len() {
        x_new[i] = x_old[i] + alpha * dx[i];
    }
    alpha
}
```

### 1.4 Voltage Step Limiting

An additional per-iteration clamp (`limit_step` in newton.rs) prevents large voltage swings:

```rust
fn limit_step(dx: &mut [f64], max_voltage_step: f64) {
    for v in dx.iter_mut() {
        if *v > max_voltage_step { *v = max_voltage_step; }
        else if *v < -max_voltage_step { *v = -max_voltage_step; }
    }
}
```

This corresponds to SPICE's `VNSTEP` option.

### 1.5 Source Stepping

`SourceStepping` (source_stepping.rs) ramps independent source values from 0 to full over a graduated sequence when plain NR fails to converge:

$$\text{steps} = [0.001, 0.01, 0.05, 0.1, 0.2, 0.3, 0.5, 0.7, 0.9, 1.0]$$

For each step fraction $s$, all independent sources are scaled by $s \cdot V_{\text{full}}$. The circuit is solved with NR at each step; convergence at step $s$ means the solution for the fully-scaled circuit has been found.

The `itl6` option (NrConfig) can override with a uniform schedule: $\lambda_k = k/\text{itl6}$ for $k = 1 \ldots \text{itl6}$, with bisection fallback on failure.

### 1.6 GMIN Stepping

`GminStepping` (gmin_stepping.rs) adds a small conductance $G_{\text{min}}$ from every node to ground, improving the Jacobian conditioning at the start of a difficult solve. The sequence is:

$$G_{\text{min},k} = \frac{G_{\text{init}}}{\text{reduction\_factor}^k}, \quad G_{\text{init}} = 10^{-2}, \text{ reduction\_factor} = 3.1623 \;(=\sqrt{10})$$

The factor of $\sqrt{10}$ per step (half-decade) was chosen to avoid the abrupt transition when GMIN-dominated behavior gives way to device-dominated behavior — a common cause of divergence in circuits like diff pairs and current mirrors.

At each GMIN value, the stamper adds $G_{\text{min}}$ to each diagonal entry of the Jacobian:

```rust
pub fn add_gmin_stamps(triplet: &mut TripletMatrix, gmin: f64, num_nodes: usize) {
    for i in 0..num_nodes {
        triplet.add(i, i, gmin);
    }
}
```

### 1.7 Levenberg-Marquardt Regularization

`regularize_weak_diagonals` in newton.rs adds a floor conductance to node diagonals weaker than `DEFAULT_GMIN_FLOOR = 1e-9` S:

```rust
fn regularize_weak_diagonals(jac: &mut TripletMatrix, num_nodes: usize, gmin_floor: f64) {
    // Compute diagonal sums from existing stamps
    let mut diag_sum: SmallVec<[f64; 64]> = smallvec::smallvec![0.0; num_nodes];
    for ((&r, &c), &v) in rows.iter().zip(cols.iter()).zip(vals.iter()) {
        if r < num_nodes && r == c as usize {
            diag_sum[r] += v;
        }
    }
    // Add floor if diagonal is too weak
    for i in 0..num_nodes {
        if diag_sum[i].abs() < gmin_floor {
            jac.add(i, i, gmin_floor - diag_sum[i].abs());
        }
    }
}
```

This is **Jacobian-only** (Levenberg-Marquardt style) — the residual is NOT modified — preserving the correct convergence target while preventing singular pivots at high-impedance nodes (e.g., MOSFET drain with $\lambda = 0$, $g_{ds} \approx 10^{-12}$ S).

### 1.8 Anderson Acceleration

`AndersonAcceleration` (anderson.rs, Walker-Ni 2011) accelerates NR by mixing past iterates. Given window size $m$:

1. Build $\Delta F = [f_{k-m_k} - f_{k-m_k+1} | \cdots | f_{k-1} - f_{k-2}]$ (residual diffs, $n \times m_k$)
2. Build $\Delta X = [x_{k-m_k} - x_{k-m_k+1} | \cdots | x_{k-1} - x_{k-2}]$ (iterate diffs, $n \times m_k$)
3. Solve $\gamma^* = \arg\min_\gamma \|\Delta F \cdot \gamma - f_k\|_2$ (least-squares via normal equations + Cholesky)
4. $x_{k+1} = x_k + \beta \cdot f_k - (\Delta X + \beta \cdot \Delta F) \cdot \gamma^*$

where $f_k = G(x_k) - x_k$ is the fixed-point residual and $\beta \in (0,1]$ is a mixing parameter (default 1.0).

The least-squares is solved via Tikhonov-regularized normal equations ($A^T A + \lambda I$) with Cholesky, because $m_k \leq 10$ typically, so the Gram matrix is at most $10 \times 10$.

### 1.9 Pseudo-Transient Continuation (PTC)

`solve_pseudo_transient` (pseudo_transient.rs) is the last-resort fallback when NR + GMIN + source stepping all fail. It transforms the algebraic system into a stiff ODE:

$$F(x) + \frac{C}{\Delta t} \cdot (x - x_{\text{prev}}) = 0$$

The Jacobian becomes $J + \frac{C}{\Delta t} \cdot I$ (well-conditioned for large $C/\Delta t$). The algorithm:

1. Start with large stamp value ($C/\Delta t \approx 1$ F/s), giving a near-trivial system
2. Run inner Newton iterations until the modified residual is small
3. Check the **true residual** (without the PTC stamp) — if both the true residual and the stamp value are below tolerance, the DC OP is found
4. Reduce stamp value by `dt_growth` factor (default 2×) and repeat

This is essentially time-domain integration with an exponentially growing time step, effectively tracing the solution from a trivial initial condition to the true DC operating point.

---

## 2. Modified Nodal Analysis (MNA)

### 2.1 System Matrix Construction

MNA builds a system of size $n + b$ where:
- $n$ = number of circuit nodes (excluding ground)
- $b$ = number of branch current variables (for voltage sources, inductors, etc.)

The matrix has the block form:

$$\begin{pmatrix} G & B \\ B^T & 0 \end{pmatrix} \cdot \begin{pmatrix} V \\ I \end{pmatrix} = \begin{pmatrix} I_{\text{sources}} \\ E_{\text{v_sources}} \end{pmatrix}$$

Where:
- $G$ is the $n \times n$ conductance matrix (nodal stamps)
- $B$ is the $n \times b$ branch incidence matrix
- $V$ is the vector of node voltages (size $n$)
- $I$ is the vector of branch currents (size $b$)

### 2.2 Stamp Functions for Each Device Type

All stamping happens in `stamper.rs`. The `stamp_circuit_into` function iterates over devices and calls the `DeviceEval` trait's `stamp` method via `registry.get(device.kind)`. Key device stamps:

**Resistor** (between nodes $i, j$, value $R$):
- $G[i][i] += 1/R$, $G[j][j] += 1/R$, $G[i][j] -= 1/R$, $G[j][i] -= 1/R$

**Independent Voltage Source** (from node $i$ to node $j$, voltage $V_{dc}$):
- Branch variable $I_b$ added at row $n + b_{\text{idx}}$
- KCL stamp: row $i$ += $+I_b$, row $j$ += $-I_b$
- Branch equation: $V_i - V_j = V_{dc}$ (or $V_i - V_j - V_{expr} = 0$ for expression-based sources)

**Diode** (nonlinear stamp via DeviceEval):
- $I_D = I_S \left( e^{V_D/(n \cdot V_T)} - 1 \right)$
- Jacobian: $g_D = \frac{I_S}{n V_T} e^{V_D/(n V_T)}$
- Stamp: $G[i][i] += g_D$, $G[j][j] += g_D$, $G[i][j] -= g_D$, $G[j][i] -= g_D$

**MOSFET** (BSIM4 model):
- Large nonlinear stamp with region-dependent equations (cutoff, triode, saturation)
- Includes $g_{m}$, $g_{ds}$, $g_{mb}$ (transconductance, drain-source conductance, bulk transconductance)
- The `stamp` method dispatches to either CPU SIMD batch evaluation or a WGSL GPU kernel when device count exceeds `gpu_device_threshold` (default 1024)

**BJT** (Gummel-Pool model):
- QBA model for intrinsic plus extrinsic resistance network
- Region-dependent equations (forward active, reverse active, saturation, cutoff)
- Includes $g_\pi$, $g_\mu$, $g_x$ transconductance elements

**Lossless Transmission Line** (T-line):
- Branin's method: two Thevenin-equivalent port models with delayed history
- Two branch variables (port-1 and port-2 currents)
- Stamp pattern: $[G]$ with $Z_0$ characteristic impedance

**B-source (voltage and current form):**
- Handles `BsourceV`, `BsourceI`, `VcvsExpr`, `VccsExpr`
- Evaluates an expression tree from `circuit.bsource_exprs`
- Returns `eval_bsource_v` (voltage form with branch variable) or `eval_bsource_i` (current-only form)

### 2.3 Junction Voltage Limiting (per-device)

Before evaluation, `stamp_circuit_into` applies SPICE-style voltage limiting when `prev_solution` is available:

**Diode (`pnjlim`):** When $|V_{\text{new}} - V_{\text{old}}| > 2 V_T$ and $V_{\text{new}} > V_{\text{crit}}$, compress the step logarithmically:

$$V_{\text{lim}} = V_{\text{old}} + V_T \cdot \left(2 + \ln\left(1 + \frac{V_{\text{new}} - V_{\text{old}}}{V_T}\right)\right)$$

where $V_{\text{crit}} = n V_T \ln\left(\frac{n V_T}{\sqrt{2} \cdot I_S}\right)$.

**MOSFET (`fetlim`):** Limits $|V_{gs}|$ changes per iteration based on whether the device was in strong inversion (larger allowed step) or below threshold (tighter limits):

```rust
if vgs_old >= vth {
    let vtsthi = 2.0 * (vgs_old - vth).abs() + 2.0;
    // limit if |delv| >= vtsthi
} else {
    let vtstlo = vtsthi / 2.0 + 2.0;
    // limit if |delv| >= vtstlo
}
```

Also `limvds`: clamps $|V_{ds}|$ changes to $\pm 3.5$ V per iteration.

### 2.4 RHS Construction

The residual (RHS) vector $F(x)$ is built by the stamper simultaneously with the Jacobian. For each device stamp, the residual contribution is computed as:

- **KCL equations:** sum of currents leaving node (signed by convention)
- **Branch equations:** $V_{n+} - V_{n-} - f(V_{\text{device}})$ for voltage-defined devices

At convergence: $F(x^*) = 0$, meaning all KCLs are satisfied and all branch equations are met simultaneously.

---

## 3. Sparse Matrix Implementation

### 3.1 CSC (Compressed Sparse Column) Format

`CscMatrix` (csc.rs) stores the matrix as three arrays:

```rust
pub struct CscMatrix {
    col_ptr: Vec<usize>,   // length ncols + 1
    row_idx: Vec<usize>,   // length nnz
    values: Vec<f64>,      // length nnz
}
```

- `col_ptr[j]` — starting index in `row_idx`/`values` for column $j$
- `col_ptr[j+1] - col_ptr[j]` — number of non-zeros in column $j$
- `row_idx[k]` — row index of the $k$-th non-zero
- Invariant: row indices within each column are sorted in ascending order

The SoA (Structure of Arrays) layout — three parallel slices — enables cache-friendly column traversal, which is optimal for:
- Left-looking sparse LU ( Gilbert-Peierls algorithm)
- Sparse matrix-vector multiplication (`mul_vec`)

### 3.2 TripletMatrix → CscMatrix Conversion

`TripletMatrix` is the mutable "assembly" format used during stamping. `to_csc()` converts to CSC:

1. Count entries per column
2. Build `col_ptr` via prefix sum
3. Scatter entries into position arrays
4. Sort each column by row index (insertion sort — columns are typically short)
5. **Compress duplicates:** when multiple triplet entries map to the same $(i, j)$, sum their values

The duplicate compression (step 5) is critical for circuit simulation where multiple devices contribute to the same matrix entries (e.g., multiple resistors connected to the same node).

### 3.3 LU Factorization

The factorization pipeline is:

```
A → BTF decomposition → AMD ordering → Gilbert-Peierls sparse LU
```

**BTF (Block Triangular Form):** Finds a permutation $P, Q$ such that $P A Q^T$ is block upper-triangular, with strongly-connected components (SCCs) on the diagonal. Circuit matrices typically decompose into large blocks (nodes in the same subcircuit) with small singletons (nodes with no feedback paths). BTF:
1. **Bipartite matching** (maximum transversal via augmenting-path DFS)
2. **Tarjan SCC** on the column dependency graph (iterative implementation)
3. Compose row/column permutations to place SCCs on the diagonal

**AMD (Approximate Minimum Degree):** Computes a fill-reducing column ordering within each BTF block. The algorithm orders columns to minimize fill-in during Gaussian elimination. Used as the column permutation after BTF.

**Gilbert-Peierls LU:** Left-looking sparse LU with partial pivoting. Key properties:
- Time proportional to $O(\text{flops} + \text{nnz}(L) + \text{nnz}(U))$
- Partial pivoting for numerical stability
- Workspace reuse across columns

The algorithm (for column $k$ of $A$):
1. **Symbolic:** DFS over $L^T$ graph to determine the non-zero pattern of $L(:, k)$ and $U(:, k)$
2. **Scatter:** $x = A(:, k)$ into dense work vector
3. **Numeric:** For each row $j < k$ in topological order: $x[i] -= L[i,j] \cdot x[j]$
4. **Pivot:** Find $\max|x_i|$ among unpivoted rows, swap into position $k$
5. **Emit:** $U(:, k)$ entries (above diagonal + pivot) and $L(:, k)$ entries (below diagonal, divided by pivot)

Both $L$ and $U$ are stored as CSC:
- **L**: diagonal (value 1.0) is the **first** entry of each column
- **U**: diagonal is the **last** entry of each column

### 3.4 Fill-in Patterns

Fill-in occurs where zeros in $A$ become non-zeros in $L$ or $U$. The BTF + AMD ordering minimizes this:

- **BTF** isolates blocks where fill-in is confined to each block (no cross-block fill)
- **AMD** reduces fill-in within each block by ordering columns to minimize degree growth during elimination

For typical circuit matrices (sparse, near-banded), these orderings keep the LU factors reasonably sparse. The worst case is highly connected small-signal models with many cross-coupling elements.

---

## 4. Linear Solver Backend Architecture

### 4.1 Solvers Available

Two backends implement the `LinSolver` trait (`lin_solver.rs`):

**1. Built-in Sparse LU (`LinSolverKind::SparseLu`):**
- BTF + AMD + Gilbert-Peierls LU (fully Rust implementation)
- Public API: `lu_factorize`, `lu_refactorize`, `lu_solve`
- Supports symbolic analysis reuse: `lu_symbolic` returns `LuSymbolic`, then `lu_refactorize` reuses it for numerical refactorization

**2. SuiteSparse KLU (`LinSolverKind::Klu`):**
- Feature-gated (`klu` Cargo feature, requires `libklu.so` at runtime)
- BTF + AMD + Gilbert-Peierls LU via FFI (thin Rust wrapper over C library)
- Same algorithm chain as ngspice and Xyce

### 4.2 Solve Pipeline

`lu_solve` in solve.rs implements the full solve for $A x = b$:

```
b → [BTF row perm] → forward_solve(L, b') → back_solve(U, z) → [BTF+AMD col perm] → x
```

1. **BTF row permutation** (applied to RHS before forward solve)
2. **Forward substitution** (sparse, $L y = b'$)
3. **Back substitution** (sparse, $U z = y$)
4. **Inverse of combined column permutation** (undoes BTF+AMD column ordering)

Forward/back solves operate directly on the sparse CSC L and U factors with no dense expansion.

### 4.3 Re-factorization Path (Newton Iteration Fast Path)

During Newton iteration the matrix structure (non-zero pattern) is stable while values change dramatically each iteration. The flow is:

```
Iteration 0:
  lu_symbolic(A)  →  LuSymbolic  (expensive, ~O(nnz log n))
  lu_factorize(A) →  LuFactors   (expensive, O(flops))

Iterations 1..N:
  lu_refactorize(A_new, &LuSymbolic) → LuFactors  (fast, O(flops only))
```

The `KluSolver` similarly exposes `refactorize` for the same purpose. This is critical for performance: the Newton iteration count typically ranges from 5–20 per operating point, and a transient simulation may have thousands of time points.

### 4.4 Anderson Acceleration Wrapper

`AndersonAcceleration` (anderson.rs) wraps a fixed-point iteration (not NR itself). The Walker-Ni algorithm:

$$\gamma^* = \arg\min_\gamma \|\Delta F \gamma - f_k\|_2, \quad x_{k+1} = x_k + \beta f_k - (\Delta X + \beta \Delta F) \gamma^*$$

where:
- $\Delta F = [f_{k-m} - f_{k-m+1} | \cdots | f_{k-1} - f_{k-2}]$
- $\Delta X = [x_{k-m} - x_{k-m+1} | \cdots | x_{k-1} - x_{k-2}]$
- $f_k = G(x_k) - x_k$ (fixed-point residual, not the NR residual $F$)

The least-squares problem is small ($m \leq 10$) and solved via Tikhonov-regularized normal equations + Cholesky (Gaussian elimination with partial pivoting).

### 4.5 Pseudo-Transient Continuation

`solve_pseudo_transient` runs an outer loop of inner Newton solves with a decaying pseudo-capacitance stamp:

- Initial stamp value: $C/\Delta t = 1$ F/s (large, well-conditioned)
- Each step: divide stamp by `dt_growth` (default 2×)
- Convergence requires: true residual $< \text{tol}$ AND stamp $< \text{tol}$ (i.e., the pseudo-transient term is negligible)
- Fallback: if stamp is negligible but residual is still large, reports convergence error

The inner Newton uses the same stamper and solver as the main NR loop.

---

## 5. Key Implementation Notes

### 5.1 Scratch Buffer Reuse

`NrScratch` (in newton.rs) is a key performance optimization: all buffers (`x_new`, `x_prev`, `neg_res`, `jac_triplet`, `residual`) are allocated once per `solve()` call via `prepare(dim)` and then reused across iterations. This eliminates:
- ~100 ns per allocation on modern allocators
- L1/L2 cache pollution from allocator housekeeping

### 5.2 DC Initial Guess

`compute_dc_initial_guess` (newton.rs) applies five heuristic passes:

1. **Voltage source terminals:** set to $V_{\text{dc}}$ for positive terminal, 0 for negative
2. **Unconnected nodes:** set to midpoint of known voltage range (VDD/2)
3. **MOSFET bias:** set source/drain nodes so $V_{gs} > V_{\text{th}}$ from the start
4. **BJT bias:** set base/emitter/collector voltages from topology (using 0.7 V junction drops)
5. **NODESET overrides:** apply `.NODESET` directives last (user-specified hints)

This matches the standard SPICE heuristic and significantly reduces Newton iterations when the starting point is close to the solution.

### 5.3 GPU Offload

BSIM4 device evaluation can be offloaded to a WGSL GPU kernel when circuit has $\geq$ `gpu_device_threshold` devices (default 1024). The `device_eval.rs` module handles auto-dispatch; the actual GPU kernel is `bsim4_eval.wgsl`.

### 5.4 Anderson Acceleration Status

Currently `enable_anderson = false` by default. The infrastructure is in place (full Walker-Ni implementation with Tikhonov regularization) but not yet production-enabled. This is a potential improvement area for hard-to-converge circuits.

---

## 6. Key Files Summary

| File | Purpose |
|------|---------|
| `solver/src/newton.rs` | Newton-Raphson main loop, config, DC initial guess, Levenberg-Marquardt regularization, voltage step limiting |
| `solver/src/stamper.rs` | MNA stamping for all device types, junction voltage limiting dispatch, B-source expression evaluation, T-line |
| `solver/src/convergence.rs` | ConvergenceCriteria (update+residual tests), ConvergenceStatus |
| `solver/src/damping.rs` | DampingStrategy (None, Fixed, Bank-Rose adaptive) |
| `solver/src/gmin_stepping.rs` | GminStepping (geometric GMIN reduction sequence) |
| `solver/src/source_stepping.rs` | SourceStepping (source ramp fraction sequence) |
| `solver/src/junction_limit.rs` | pnjlim (diode), fetlim (MOSFET Vgs), limvds (MOSFET Vds) |
| `solver/src/pseudo_transient.rs` | PseudoTransientConfig, solve_pseudo_transient (outer PTC loop) |
| `solver/src/anderson.rs` | AndersonAcceleration (Walker-Ni) |
| `solver/src/backend.rs` | Solver, SolverConfig, SolverKind (enum dispatch) |
| `solver/src/device_eval.rs` | GPU/CPU BSIM4 batch dispatch |
| `linalg/src/csc.rs` | CscMatrix (CSC format, mul_vec, transpose, add) |
| `linalg/src/triplet.rs` | TripletMatrix (assembly format, to_csc conversion) |
| `linalg/src/sparse_lu.rs` | Gilbert-Peierls sparse LU (factor, forward_solve_inplace, back_solve_inplace) |
| `linalg/src/lu.rs` | Public LU API: lu_factorize, lu_refactorize, lu_symbolic, LuFactors |
| `linalg/src/solve.rs` | lu_solve (full solve pipeline with BTF row perm + column perm undo) |
| `linalg/src/btf.rs` | BTF decomposition (bipartite matching + Tarjan SCC) |
| `linalg/src/amd.rs` | AMD (approximate minimum degree) column ordering |
| `linalg/src/klu.rs` | KluSolver (FFI wrapper over SuiteSparse KLU, feature-gated) |
| `linalg/src/lin_solver.rs` | LinSolver enum, LinSolverKind (SparseLu/Klu) |