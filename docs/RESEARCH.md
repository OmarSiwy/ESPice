# BigOSpice Performance Research

> Compiled 2026-04-06. Covers sparse solver backends, GPU acceleration, DOD audit findings, and the implementation roadmap to reach ngspice-parity accuracy with superior performance.

---

## Table of Contents

1. [Current Bottleneck](#current-bottleneck)
2. [Sparse Linear Algebra Backends](#sparse-linear-algebra-backends)
3. [KLU Deep Dive](#klu-deep-dive)
4. [GPU Sparse LU — State of the Art](#gpu-sparse-lu--state-of-the-art)
5. [Hybrid CPU-GPU Pipeline](#hybrid-cpu-gpu-pipeline)
6. [Alternative Nonlinear Solvers](#alternative-nonlinear-solvers)
7. [Parallelism Strategies](#parallelism-strategies)
8. [Incremental Simulation](#incremental-simulation)
9. [Rust Ecosystem](#rust-ecosystem)
10. [DOD Audit Findings](#dod-audit-findings)
11. [The Killer Stack](#the-killer-stack)
12. [Implementation Roadmap](#implementation-roadmap)
13. [Sources](#sources)

---

## Current Bottleneck

BigOSpice's `lu_factorize` in `crates/linalg/src/lu.rs` expands the sparse CSC matrix to a **dense** `Vec<f64>` of size n*n and runs dense Gaussian elimination. This is O(n^3) time, O(n^2) space.

For a 1,000-node circuit: 8 MB dense matrix, ~1 billion FLOPs — but the sparse matrix has only ~5,000 nonzeros (0.5% fill). **99.5% of computation is on zeros.**

| Circuit size | Dense LU time | Sparse LU (est.) | Speedup |
|---|---|---|---|
| 100 nodes | ~0.1 ms | ~0.05 ms | 2x |
| 1,000 nodes | ~50 ms | ~0.5 ms | 100x |
| 10,000 nodes | ~50 s | ~5 ms | 10,000x |
| 100,000 nodes | infeasible | ~100 ms | — |

**Replacing dense LU with sparse LU is the single highest-impact change possible.**

---

## Sparse Linear Algebra Backends

### Options ranked by impact/effort

| Option | Expected Speedup | Effort | Ecosystem |
|---|---|---|---|
| **KLU via `klu-rs`** | 100-1000x (n>200) | Low (2-3 days) | `klu-rs` crate, wraps SuiteSparse. LGPL. |
| **rsparse** (pure Rust CSparse port) | 50-500x (n>200) | Low (1-2 days) | `rsparse` crate, MIT, no C deps |
| **Native sparse LU** (in-house) | 50-500x (n>200) | High (2-4 weeks) | Full control, follows CLAUDE.md DOD |
| **faer-sparse** | Unknown | Medium | `faer-sparse` crate, sparse LU exists but not circuit-optimized |
| **Intel PARDISO** | ~0.5-1x vs KLU | Medium | Proprietary (MKL). General-purpose, not circuit-optimized. |

### Fill-Reducing Orderings

Even with sparse LU, bad ordering causes catastrophic fill-in. Good ordering reduces fill 10-100x.

| Method | Best For | Rust Crate |
|---|---|---|
| **AMD** (Approx. Minimum Degree) | Small circuits, pre-layout, <5K nodes | `amd` crate or `faer-sparse::amd` |
| **COLAMD** | Unsymmetric matrices, general-purpose | `faer-sparse::colamd` |
| **Nested Dissection (METIS)** | Large post-layout circuits, >10K nodes | `metis` crate (FFI) |

**CKTSO's strategy**: Run AMD, AMDEF, and METIS in parallel, pick whichever produces fewest fill-ins. No single method dominates across all circuit types.

---

## KLU Deep Dive

KLU (Tim Davis) is the gold standard sparse direct solver for circuit simulation. Default in Xyce and ngspice.

### Algorithm Pipeline

**Stage 1: BTF (Block Triangular Form)**

Permute A into upper block triangular form via Duff's algorithm (maximum transversal). Each diagonal block is irreducible (strongly connected component). For circuit matrices, most blocks are 1x1 or 2x2 — **BTF avoids factorizing 80-90% of the matrix entirely.**

```
P * A * Q = [ B11  B12  B13  ... ]
            [  0   B22  B23  ... ]
            [  0    0   B33  ... ]
            [  ...           Bkk ]
```

**Stage 2: AMD Ordering (within each block)**

For each nontrivial diagonal block, compute AMD ordering on A+A^T to minimize fill-in. Computed once (symbolic phase), reused across Newton iterations.

**Stage 3: Symbolic Factorization**

Build elimination tree + predict L/U sparsity structure without arithmetic. Determines memory allocation. Uses Liu's algorithm with union-find.

**Stage 4: Gilbert-Peierls Left-Looking Numeric Factorization**

For each column k:
1. **Sparse reach**: DFS on graph of L^T from nonzero rows of A(:,k). Produces topological ordering.
2. **Sparse triangular solve**: Process only reached entries in topological order. Work is O(nnz(L(:,k)) + nnz(U(:,k))), not O(n).
3. **Partial pivoting**: Find largest magnitude below diagonal, swap.
4. **Store**: Pivot row → U, scaled subdiagonal → L.

### Why KLU is Fast for Circuits

- Never touches structural zeros
- BTF avoids factorizing trivial 1x1 blocks
- Left-looking: each column computed independently
- No dense BLAS kernels (circuit matrices too sparse for supernodal to help)
- Symbolic/numeric separation: symbolic runs once, numeric refactorization reuses pattern

### Core Data Structures (for Rust implementation)

```rust
struct SparseLuSymbolic {
    n: usize,
    btf_row_perm: Vec<usize>,
    btf_col_perm: Vec<usize>,
    n_blocks: usize,
    block_starts: Vec<usize>,
    block_col_perm: Vec<usize>,  // AMD within each block
    etree: Vec<i32>,             // elimination tree
    l_col_ptr: Vec<usize>,
    u_col_ptr: Vec<usize>,
}

struct SparseLuFactors {
    n: usize,
    l_col_ptr: Vec<usize>,
    l_row_idx: Vec<usize>,
    l_values: Vec<f64>,
    u_col_ptr: Vec<usize>,
    u_row_idx: Vec<usize>,
    u_values: Vec<f64>,
    row_perm: Vec<usize>,
    // Reusable work arrays
    work_dense: Vec<f64>,
    work_flag: Vec<i32>,
    work_stack: Vec<usize>,
}
```

### Gilbert-Peierls Core Loop (pseudocode)

```
for each column k = 0..n:
    // 1. Scatter A(:,k) into dense work vector
    for (row, val) in A.column(k):
        work_dense[row] = val

    // 2. DFS on L^T graph to find reach set (topological order)
    reach = dfs_reach(k, L_graph, A_nonzeros)

    // 3. Sparse triangular solve
    for j in reach (topological order):
        if j < k:
            for (row, lval) in L.column(j):
                work_dense[row] -= lval * work_dense[j]

    // 4. Partial pivot
    pivot_row = argmax |work_dense[i]| for i >= k in reach
    swap rows

    // 5. Store L(:,k) and U(:,k)
    pivot = work_dense[k]
    for i in reach:
        if i <= k: U[i,k] = work_dense[i]
        else:      L[i,k] = work_dense[i] / pivot
        work_dense[i] = 0.0  // clear for next column
```

---

## GPU Sparse LU — State of the Art

### ISLU (ICCAD 2024)

"Indexing-Efficient Sparse LU Factorization for Circuit Simulation on GPUs"

**Problem solved**: Standard sparse LU requires searching row index arrays for element (i,j) — O(log n) binary search. On GPU with thousands of threads, this indirect indexing is the primary bottleneck.

**Solution — "Member Union" data structure**: Precomputed O(1) lookup from (row, col) to position in compressed arrays. Eliminates search overhead.

**GPU parallelism**: Level-based scheduling — columns at the same elimination tree level have no dependencies, factored in parallel.

**Performance**: 23.4x over PARDISO (1 thread), 9.4x over PARDISO (16 threads).

**wgpu feasibility**: Partially feasible. The member union is a lookup table in global memory. Level-based parallelism maps to compute dispatches. **Dealbreaker: WGSL f64 support is not universally available.** Circuit simulation requires double precision.

### GLU 3.0

"Fast GPU-based Parallel Sparse LU Factorization"

**Approach**: Hybrid right-looking LU with three levels of GPU parallelism (column selection, row operations within column, scatter across dependent columns). Dynamic kernel mode switching based on parallelism width.

**Performance**: 19.6x over KLU.

**wgpu feasibility**: **Not portable.** Relies on CUDA dynamic parallelism, warp-level primitives, and `__syncthreads` patterns that don't map to WGSL.

### CKTSO (CPU, 2024-2025)

The state of the art for CPU parallel sparse LU for circuits.

**Ordering**: Hybrid — runs AMD, AMDEF, and nested dissection in parallel, picks best.

**Parallel factorization** — dual mode:
- **Cluster mode**: Wide levels → columns distributed across threads with barrier sync
- **Pipeline mode**: Narrow levels → atomic work-stealing between dependent rows

**Performance**: 4.86x with 16 threads over sequential. Fastest on 50/56 benchmarks.

**Rust implementation**: Cluster mode via Rayon, pipeline mode via atomics. Directly implementable.

### cuSPARSE

**Not suitable for SPICE.** Provides ILU preconditioner, not full sparse LU. No pivoting, no BTF, no AMD. Designed for iterative solvers.

### Summary

| Solver | Platform | vs KLU | wgpu Feasible? |
|---|---|---|---|
| ISLU | GPU (CUDA) | ~20x vs PARDISO | Partially (no f64) |
| GLU 3.0 | GPU (CUDA) | 19.6x | No (CUDA-specific) |
| CKTSO | CPU (threads) | ~5x (16 threads) | N/A (CPU) |
| cuSPARSE | GPU (CUDA) | N/A | No (wrong algorithm) |

---

## Hybrid CPU-GPU Pipeline

### SPICE Newton-Raphson Iteration Phases

```
1. Device Evaluation  → compute I(V), G(V) per device     [GPU-friendly]
2. Matrix Assembly    → stamp into Jacobian                [GPU-possible]
3. LU Factorization   → factor the Jacobian                [CPU wins]
4. Solve + Update     → Jx = -F, update voltages           [CPU wins]
```

### GPU Device Evaluation (the best GPU target)

Embarrassingly parallel. Each MOSFET eval is independent. Consumes ~75% of SPICE runtime for transistor-heavy circuits.

```wgsl
@compute @workgroup_size(256)
fn eval_mosfets(@builtin(global_invocation_id) id: vec3<u32>) {
    let idx = id.x;
    if (idx >= arrayLength(&states)) { return; }
    let p = params[idx];
    var s = states[idx];
    // BSIM-like evaluation...
    states[idx] = s;
}
```

**f64 constraint**: WGSL f64 is an optional extension. Mixed precision possible: f64 for voltage differences, f32 for model intermediates.

### GPU Matrix Assembly

After device eval on GPU, stamp directly into pre-allocated sparse buffer. Requires atomic adds for nodes shared by multiple devices.

**Limitation**: WGSL atomics are i32/u32 only — forces fixed-point representation during assembly. Needs CPU correction pass for full precision.

### When GPU Loses to CPU

| Circuit Size | Device Eval GPU? | Matrix Solve GPU? | Verdict |
|---|---|---|---|
| < 1K devices | No | No | CPU wins, overhead kills GPU |
| 1K - 10K | Maybe (2-3x) | No | Marginal |
| 10K - 100K | Yes (5-7x) | Maybe | Eval on GPU, solve on CPU |
| 100K+ | Yes (7-10x) | Assembly yes, factor no | Hybrid |

### Recommended Hybrid Pipeline

```
CPU: symbolic analysis (once)
Per Newton iteration:
  GPU: device evaluation (all MOSFETs in parallel)
  GPU: matrix assembly (stamp into pre-allocated buffer)
  CPU <- GPU: transfer matrix values (f64 values only, not structure)
  CPU: sparse LU refactorization
  CPU: triangular solve
  CPU -> GPU: transfer updated voltages
```

---

## Alternative Nonlinear Solvers

| Method | When Better Than NR | Status in BigOSpice |
|---|---|---|
| **Pseudo-transient continuation** | Hard-to-converge circuits (bandgaps, PTAT). Guaranteed convergence for passive circuits. | Not implemented. **High priority.** |
| **Homotopy / continuation** | Multiple DC operating points | Not implemented |
| **Anderson acceleration** | Can speed up NR convergence by 30-50% | Not implemented |
| **GMRES + ILU preconditioner** | Very large circuits (>50K nodes) where direct LU is too expensive | Not implemented. Long-term. |

**Pseudo-transient**: Install large capacitors (1F) from every node to ground, simulate transient converging to DC OP. Most robust method for difficult circuits. **Should be the next solver variant added to `SolverKind`.**

---

## Parallelism Strategies

| Strategy | Expected Speedup | Effort | Notes |
|---|---|---|---|
| **Parallel device evaluation** (rayon) | 2-4x for transistor-heavy | Low (tune threshold) | Already in place |
| **Matrix reordering** (AMD/COLAMD/METIS) | 2-10x fill reduction | Low-Medium | Critical for sparse LU |
| **Pipeline parallelism** (overlap eval/solve) | 1.5-2x | Medium | Overlap iteration N+1 eval with N solve |
| **Circuit partitioning** | 3-10x for large circuits | Very high | Months of work. Xyce's approach. |
| **Parallel sparse LU** (CKTSO-style) | 2-5x with multi-threading | High (3-4 weeks) | Cluster + pipeline mode |

---

## Incremental Simulation

| Technique | When It Helps | Status |
|---|---|---|
| **Selective device re-evaluation** | Only re-eval devices whose inputs changed significantly | `DirtyTracker` exists in `crates/cache` |
| **Woodbury rank-k updates** | Few matrix entries change between NR iterations | `WoodburyUpdater` exists in `crates/linalg` |
| **Symbolic factorization reuse** | Pattern fixed across NR iterations | `LinSolver::refactorize()` API exists |

---

## Rust Ecosystem

### Sparse Linear Algebra

| Crate | Purpose | License | Notes |
|---|---|---|---|
| [`klu-rs`](https://github.com/pascalkuthe/klu-rs) | KLU (SuiteSparse) FFI | LGPL | Circuit-optimized. C dependency. |
| [`rsparse`](https://github.com/RLado/rsparse) | Pure Rust CSparse port | MIT | No C deps. No symbolic/numeric split. |
| [`gplu`](https://github.com/rwl/gplu) | Gilbert-Peierls sparse LU | MIT | Translated from FORTRAN. No AMD/BTF. |
| [`faer`](https://docs.rs/faer/latest/faer/) | Dense + sparse LA | MIT | Active. Sparse LU exists, not circuit-optimized. |
| [`faer-sparse`](https://docs.rs/crate/faer-sparse/0.17.1) | AMD, COLAMD, sparse factors | MIT | Good for orderings. |
| [`amd`](https://github.com/rwl/amd_order) | AMD ordering | MIT | Pure Rust port of Tim Davis's AMD. |
| [`sprs`](https://crates.io/crates/sprs) | CSC/CSR matrix formats | MIT/Apache | Matrix storage only, no solver. |
| [`metis`](https://lib.rs/crates/metis) | Graph partitioning | Apache | Vendored build. For nested dissection. |

### Notable Non-Rust Solvers

| Solver | Speed vs KLU | Parallel | License |
|---|---|---|---|
| **CKTSO** | 3x serial, 25x @ 16 threads | Yes | Proprietary (free binary) |
| **NICSLU** | 2-3x serial, 10x @ 16 threads | Yes | LGPL + license key |
| **PARDISO** (MKL) | ~0.5-1x (worse for circuits) | Yes | Proprietary |

---

## DOD Audit Findings

### Fixes Applied (2026-04-06)

1. **ParamMap::get() eliminated heap allocation on hot path** — Every `get("resistance")` allocated a `String` via `.to_lowercase()`. Fixed with stack-allocated 32-byte lowercase buffer + `Borrow<str>` impl. Eliminates thousands of allocations per NR iteration.

2. **DeviceRegistry: HashMap → array-indexed dispatch** — `AHashMap<DeviceKind, DeviceDispatch>` replaced with `[Option<DeviceDispatch>; 16]` indexed by discriminant. O(1) array index vs hash+probe.

3. **Pre-allocated scratch buffers in NR loops** — `x_new`, `neg_res`, `jac_triplet`, `residual` moved outside loops. Eliminates 4 heap allocations per NR iteration.

4. **Stack-allocated diag_sum** — `vec![0.0; num_nodes]` → `SmallVec<[f64; 64]>`. Stack-allocated for circuits up to 64 nodes.

5. **stamp_circuit_into() for buffer reuse** — New function takes pre-allocated `TripletMatrix` + `DenseVec`, clears and reuses them.

### Recommendations (not yet implemented)

| Rec | Description | Risk | Impact |
|---|---|---|---|
| **Circuit SoA** | Split `DeviceInstance` into hot (kind, terminals) and cold (name) fields | High | Better cache utilization in stamper loop |
| **Batch device eval by type** | Evaluate all resistors as a batch with SoA layout, enabling SIMD | Medium-high | Eliminates per-device dispatch overhead |
| **BitSet for device-kind filtering** | `BitSet` per `DeviceKind` for O(popcount) filtering | Low | Faster `devices_of_kind()` |
| **IndexVec with NodeId/DeviceId** | Compile-time safety against mixing node/device indices | Low | Type safety |
| **DC sweep: in-place param mutation** | Replace `circuit.clone()` with mutation + restore | Medium | Avoids full deep copy |
| **Transient: flat result storage** | Replace `Vec<Vec<f64>>` per timestep with flat `Vec<f64>` stride=num_nodes | Low | Fewer small allocations |
| **TripletMatrix SoA** | Separate `rows: Vec<u32>`, `cols: Vec<u32>`, `vals: Vec<f64>` | Medium | Halves index storage, better SIMD potential |

---

## The Killer Stack

### Tier 1: Immediate (1-2 weeks, 100-1000x improvement)

1. **Pure-Rust sparse LU** — Gilbert-Peierls left-looking algorithm
2. **AMD ordering** — via `amd` crate or `faer-sparse`
3. **Symbolic/numeric separation** — already architected, wire up real sparse impl
4. **(Optional) KLU via `klu-rs`** — feature-gated, maximum performance reference

### Tier 2: Near-term (1-2 months, additional 3-10x)

5. **BTF decomposition** — Tarjan's SCC + block triangular form
6. **Pseudo-transient continuation** — convergence robustness
7. **Parallel device evaluation** — tune rayon thresholds
8. **Selective device re-evaluation** — dirty tracking

### Tier 3: Medium-term (3-6 months, additional 2-5x)

9. **GPU batch MOSFET evaluation** — wgpu compute shaders
10. **Woodbury incremental updates** — late NR iterations
11. **Pipeline parallelism** — overlap eval/solve
12. **Mixed-precision** — f32 initial NR iterations, f64 final

### Tier 4: Long-term (6-12 months, additional 2-10x for large circuits)

13. **Circuit partitioning** — domain decomposition
14. **GMRES + ILU** — for >50K node circuits
15. **Parallel sparse LU** — CKTSO-style cluster/pipeline mode
16. **GPU sparse matrix assembly** — overlapped with CPU factorization

### Expected Combined Performance

| Circuit Size | Current (dense) | After Tier 1 | After Tier 2 | After Tier 3-4 |
|---|---|---|---|---|
| 50 nodes | 1x | 5-10x | 10-20x | 20-40x |
| 500 nodes | 1x | 100-500x | 300-1500x | 500-3000x |
| 5,000 nodes | 1x | 5K-50Kx | 10K-100Kx | 50K-500Kx |
| 50,000 nodes | Infeasible | Feasible (seconds) | Fast (sub-second/NR) | Near-commercial |

---

## Implementation Roadmap

### LinSolver Architecture

```rust
pub enum LinSolverKind {
    DenseLu,                        // Current, for small circuits / debugging
    SparseLu,                       // Pure-Rust, production default
    #[cfg(feature = "klu")]
    Klu,                            // SuiteSparse FFI, max performance
    #[cfg(feature = "gpu-solve")]
    GpuSparseLu,                    // Experimental, large circuits only
}

pub enum LinSolver {
    DenseLu  { symbolic: DenseLuSymbolic, factors: DenseLuFactors },
    SparseLu { symbolic: SparseLuSymbolic, factors: SparseLuFactors },
    #[cfg(feature = "klu")]
    Klu      { matrix: klu_rs::FixedKluMatrix<f64> },
    #[cfg(feature = "gpu-solve")]
    GpuSparseLu { gpu_state: GpuSolverState },
}
```

### Key Files to Modify

- `crates/linalg/src/sparse_lu.rs` — new: Gilbert-Peierls core
- `crates/linalg/src/amd.rs` — new: AMD ordering
- `crates/linalg/src/btf.rs` — new: block triangular form
- `crates/linalg/src/etree.rs` — new: elimination tree
- `crates/linalg/src/lin_solver.rs` — extend enum with SparseLu variant
- `crates/linalg/src/solve.rs` — add sparse forward/back solve

### Phase 1 Effort Estimate

| Component | Lines of Rust | Time |
|---|---|---|
| AMD ordering | ~400 | 2-3 days |
| Elimination tree | ~200 | 1 day |
| Symbolic factorization | ~300 | 2 days |
| Gilbert-Peierls numeric LU | ~500 | 3-4 days |
| Sparse triangular solve | ~200 | 1 day |
| BTF decomposition | ~500 | 3-4 days |
| Integration + testing | ~300 | 2-3 days |
| **Total** | **~2,400** | **~2-3 weeks** |

---

## Sources

### Sparse Solvers
- [Algorithm 907: KLU — A Direct Sparse Solver for Circuit Simulation](https://dl.acm.org/doi/abs/10.1145/1824801.1824814)
- [KLU Thesis (Palamadai)](https://ufdcimages.uflib.ufl.edu/UF/E0/01/17/21/00001/palamadai_e.pdf)
- [CKTSO: High-Performance Parallel Sparse Linear Solver](https://arxiv.org/html/2411.14082v1) — [GitHub](https://github.com/chenxm1986/cktso)
- [NICSLU GitHub](https://github.com/chenxm1986/nicslu)
- [SuiteSparse (Tim Davis)](https://github.com/DrTimothyAldenDavis/SuiteSparse)

### GPU Sparse LU
- [ISLU: Indexing-Efficient Sparse LU on GPUs (ICCAD 2024)](https://dl.acm.org/doi/10.1145/3676536.3695410)
- [GLU3.0: Fast GPU-based Parallel Sparse LU](https://arxiv.org/abs/1908.00204) — [Project page](https://intra.ece.ucr.edu/~stan/project/glu/glu_proj.htm)

### GPU SPICE
- [CUSPICE: ngspice on GPU](https://ngspice.sourceforge.io/cuspice.html)
- [Synopsys PrimeSim GPU Acceleration](https://www.synopsys.com/blogs/chip-design/nvidia-gpu-circuit-simulation.html)
- [Accelerating Circuit Simulation 10x With GPUs (SemiEngineering)](https://semiengineering.com/accelerating-circuit-simulation-10x-with-gpus/)
- [Massive Parallelization of SPICE Device Eval on GPU](https://www.researchgate.net/publication/221309317)

### Orderings & Partitioning
- [AMD Algorithm (Amestoy, Davis, Duff)](https://people.engr.tamu.edu/davis/publications_files/An_Approximate_Minimum_Degree_Ordering_Algorithm.pdf)
- [Elimination Trees for Sparse Factorization](https://www.cs.purdue.edu/homes/apothen/Papers/elimination-DS2004.pdf)
- [Hypergraph-Based Unsymmetric Nested Dissection](https://people.engr.tamu.edu/davis/publications_files/Hypergraph_based_unsymmetric_nested_dissection_ordering_for_sparse_LU.pdf)

### Iterative Methods
- [Hybrid-Precision Block-Jacobi Preconditioned GMRES](https://arxiv.org/html/2509.09139v1)
- [Parallel ILU-GMRES for Circuit Simulation](https://ieeexplore.ieee.org/abstract/document/10044751)

### Rust Crates
- [klu-rs](https://github.com/pascalkuthe/klu-rs) — [docs](https://docs.rs/klu-rs/latest/klu_rs/)
- [rsparse](https://github.com/RLado/rsparse)
- [gplu](https://github.com/rwl/gplu/)
- [faer](https://docs.rs/faer/latest/faer/) — [paper](https://github.com/sarah-quinones/faer-rs/blob/main/paper.md)
- [faer-sparse](https://docs.rs/crate/faer-sparse/0.17.1)
- [amd_order](https://github.com/rwl/amd_order)
- [metis](https://lib.rs/crates/metis)

### Parallel Simulation
- [Xyce Parallel Electronic Simulator](https://xyce.sandia.gov/about-xyce/)
- [Xyce: Open Source Large-Scale Circuit Simulation (Sandia)](https://apps.dtic.mil/sti/tr/pdf/AD1075709.pdf)
- [FastSpice Circuit Partitioning](https://www.sciencedirect.com/science/article/abs/pii/S1569190X17301727)

### Convergence
- [SiMetrix DC Operating Point Algorithms](https://help.simetrix.co.uk/8.0/simetrix/mergedProjects/simulator_reference/topics/simref_convergence_accuracyandperformance_dcoperatingpointalgorithms.htm)

### Fundamentals
- [CSparse Source (cs_lu.c)](https://github.com/DrTimothyAldenDavis/SuiteSparse/blob/stable/CSparse/Source/cs_lu.c)
- [WGSL Specification](https://www.w3.org/TR/WGSL/)
- [Woodbury Matrix Identity](https://en.wikipedia.org/wiki/Woodbury_matrix_identity)
- [Anderson Acceleration](https://en.wikipedia.org/wiki/Anderson_acceleration)
