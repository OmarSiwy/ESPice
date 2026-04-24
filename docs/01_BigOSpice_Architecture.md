# Document 1: BigOSpice Architecture — Pipeline, Backends, and Data-Oriented Design

**Date:** 2026-04-21 | **Version:** 1.0

---

## 1. High-Level Pipeline Overview

BigOSpice processes a SPICE netlist through a six-stage data-oriented pipeline. Every stage is designed around Structure-of-Arrays (SoA) memory layout, index-based graph traversal, and zero-allocation hot paths.

```
 NETLIST INPUT (.sp/.cir)
       │
       ▼
 ┌──────────────────┐     ┌─────────────────────┐     ┌───────────────────────┐
 │ 1. PARSER         │ ──► │ 2. CIRCUIT GRAPH     │ ──► │ 3. ANALYSIS ENGINE     │
 │                    │     │                       │     │                         │
 │ SpiceParser        │     │ Circuit struct        │     │ DC-OP, DC-Sweep, AC     │
 │ Byte-slice Lexer   │     │ Vec<Node>             │     │ Transient, Noise, PZ    │
 │ Recursive descent  │     │ Vec<DeviceInstance>   │     │ HB, PSS, Envelope       │
 │ Subckt expansion   │     │ CompressedGraph (CSR) │     │ MC, WCASE, LHS, FFT     │
 │ .INCLUDE/.LIB      │     │ MNA index mapping     │     │ Disto, Fourier, TF, SP  │
 │ Param evaluation   │     │ ParamMap (stack keys)  │     │ Sensitivity, Measure    │
 │ HSPICE/Xyce compat │     │ Param dependency map   │     │ .STEP/.ALTER/.CONTROL   │
 │                    │     │ AcStimulus defs        │     │                         │
 │ Output:            │     │ VoltageConstraints     │     │ Each analysis calls     │
 │  ParsedNetlist IR  │     │ TlineHistory buffers   │     │ solver in a loop        │
 └──────────────────┘     └─────────────────────┘     └───────────┬───────────┘
                                                                   │
                                                                   ▼
 ┌──────────────────┐     ┌─────────────────────┐     ┌───────────────────────┐
 │ 6. I/O OUTPUT     │ ◄── │ 5. CACHE MANAGER     │ ◄── │ 4. SOLVER + LINALG     │
 │                    │     │                       │     │                         │
 │ Rawfile (bin/asc)  │     │ TopologyCache (5.1)   │     │ Newton-Raphson          │
 │ CSV (RFC 4180)     │     │ DirtyTracker (5.2)    │     │ + Anderson acceleration │
 │ HSPICE POST (.tr0) │     │ CompiledEval (5.3)    │     │ + GMIN stepping         │
 │ Touchstone (.sNp)  │     │ WoodburyUpdate (5.4)  │     │ + Source stepping       │
 │ MT0 (Monte Carlo)  │     │ TransientArena (5.5)  │     │ + Pseudo-transient      │
 │ AC column extract   │     │ CacheManager (5.6)    │     │ + Homotopy continuation │
 │ Wildcard .PRINT    │     │                       │     │                         │
 │                    │     │ Topology hash (FNV-1a) │     │ Sparse LU pipeline:     │
 │ Format dispatch:   │     │ BitVec dirty sets     │     │  BTF decomposition      │
 │  .OPTIONS FILETYPE │     │ Affine model patching │     │  AMD ordering per block │
 │  .OPTIONS RAWFMT   │     │ Rank-k LU updates     │     │  Gilbert-Peierls LU     │
 │                    │     │ Time-domain snapshots  │     │  Partial pivoting       │
 └──────────────────┘     └─────────────────────┘     │                         │
                                                       │ Compute backends:       │
                                                       │  CPU (Rayon + SIMD)     │
                                                       │  GPU (wgpu WebGPU)     │
                                                       │  Memory pool + Arena    │
                                                       └───────────────────────┘
```

---

## 2. Stage 1 — Parser (`crates/parser`)

### Tokenizer Architecture

The lexer operates on a byte slice (`&[u8]`), producing tokens without heap allocation for most token types:

| Token Type | Example | Notes |
|-----------|---------|-------|
| `Word` | `R1`, `drain`, `sky130_fd_pr__nfet_01v8` | Lowercased on output |
| `Number` | `1.8`, `10u`, `3.3k`, `1e-12` | SI suffix pre-resolved to f64 |
| `Dot` | `.TRAN`, `.MODEL`, `.PARAM` | Directive marker |
| `QuotedString` | `"sky130.lib"` | Double-quoted, lowercased |
| `SingleQuoteExpr` | `'R0*SCALE'` | HSPICE arithmetic expression |
| `LeftBrace`/`RightBrace` | `{`, `}` | Expression delimiters |
| Operators | `+`, `-`, `*`, `/`, `=` | Arithmetic and assignment |
| `Newline` | `\n` | Statement boundary |
| `Eof` | — | End of input |

**SI suffix resolution** happens in the tokenizer — `10u` becomes `10e-6`, `3.3k` becomes `3300.0`, `1p` becomes `1e-12`. The suffix map lives in `crates/utility` and covers: `T` (1e12), `G` (1e9), `MEG` (1e6), `K` (1e3), `M` (1e-3), `U` (1e-6), `N` (1e-9), `P` (1e-12), `F` (1e-15), `A` (1e-18).

Line continuation: `+` at line start joins to previous statement. Comments: `*` at line start or `;` inline.

### Expression Parser

Recursive descent with standard precedence:

```
parse_expr()    → parse_term() (('+' | '-') parse_term())*
parse_term()    → parse_unary() (('*' | '/') parse_unary())*
parse_unary()   → '-'? parse_power()
parse_power()   → parse_primary() ('**' parse_unary())?
parse_primary() → NUMBER | PARAM | FUNC '(' args ')' | '(' expr ')' | V(node) | I(dev)
```

**40+ built-in functions:** `sqrt`, `abs`, `exp`, `log`, `ln`, `log10`, `log2`, `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `cosh`, `sinh`, `tanh`, `acosh`, `asinh`, `atanh`, `pow`, `min`, `max`, `sign`, `sgn`, `limit`, `ceil`, `floor`, `round`, `int`, `nint`, `db`, `uramp`, `u`, `pwr`, `pwrs`, `hypot`, `if`, `gauss`, `agauss`, `unif`, `aunif`, `flat`.

Stochastic functions (`gauss`, `agauss`, `unif`, `aunif`, `flat`) use a thread-local xorshift PRNG with Box-Muller transform for normal distribution.

### Netlist Directives Parsed

**Analysis commands:** `.OP`, `.DC`, `.TRAN`, `.AC`, `.NOISE`, `.FOUR`, `.FFT`, `.DISTO`, `.SENS`, `.HB`, `.PZ`, `.TF`, `.SP`, `.PSS`, `.ENVLP`

**Circuit structure:** `.MODEL`, `.SUBCKT`/`.ENDS`, `.PARAM`, `.FUNC`, `.IC`, `.NODESET`, `.GLOBAL`, `.TEMP`, `.INCLUDE`, `.LIB`

**Sweep/statistical:** `.STEP` (LIN/DEC/OCT/LIST/DATA), `.MC`, `.WCASE`, `.DATA`/`.ENDDATA`

**HSPICE extensions:** `OPTVAL(init,lo,hi)`, `.DISTRIBUTION` (UNIFORM/GAUSSIAN/LOGNORM/BIMODAL), `.BINMODEL`, `.EXTRACT`, `.ROL`, `.CONNECT`, `.IF`/`.IFDEF`, `.ALTER`

**Output control:** `.SAVE`, `.PRINT`, `.PLOT` (with wildcard `V(*)`, `I(*)`, `*`), `.OPTIONS` (50+ solver/output parameters), `.MEAS`/`.MEASURE`

**Scripting:** `.control`/`.endc` blocks captured verbatim for interpreter

### Element Parsing (First-Letter Dispatch)

| Letter | Device | Terminals | Branch? |
|--------|--------|-----------|---------|
| R | Resistor | 2 | No |
| C | Capacitor | 2 | No |
| L | Inductor | 2 | Yes |
| D | Diode | 2 | No |
| M | MOSFET | 4 (D,G,S,B) | No |
| Q | BJT | 3 (C,B,E) | No |
| J | JFET | 3 (D,G,S) | No |
| Z | MESFET | 3 (D,G,S) | No |
| V | V-source | 2 | Yes |
| I | I-source | 2 | No |
| E | VCVS | 4 | Yes |
| G | VCCS | 4 | No |
| F | CCCS | 2 + ref | No |
| H | CCVS | 2 + ref | Yes |
| K | Mutual inductance | — | — |
| X | Subcircuit instance | N | — |
| B | Behavioral source | 2 | V:Yes, I:No |
| A | XSPICE / Digital | N | — |
| W | Lossy T-line | 4 | — |
| P | Port | 2 | — |
| T | Ideal T-line | 4 | Yes (2 branches) |
| U | URC ladder | 2×Nseg | — |
| S | V-controlled switch | 4 | No |

### Subcircuit Expansion

1. Collect all `.SUBCKT` definitions into a map
2. For each `X` instance: find definition → copy with parameter substitution → prefix internal nodes (`Xname:nodename`) → recurse for nested subcircuits
3. Cycle detection via visited-set (prevents infinite recursion)
4. `.GLOBAL` nodes bypass prefixing

---

## 3. Stage 2 — Circuit Graph (`crates/core`)

### Data-Oriented Circuit Representation

```rust
pub struct Circuit {
    // SoA parallel arrays
    nodes: Vec<Node>,                      // indexed by NodeId(u32)
    devices: Vec<DeviceInstance>,           // indexed by DeviceId(u32)

    // Name lookup (cold path)
    node_names: AHashMap<String, NodeId>,
    device_names: AHashMap<String, DeviceId>,

    // MNA dimensions
    num_vars: u32,      // voltage unknowns (nodes minus ground)
    num_branches: u32,  // branch current unknowns (V-sources, inductors)

    // Topology
    graph: Option<CompressedGraph>,        // CSR adjacency, built lazily

    // Parameter dependency tracking
    param_deps: AHashMap<ParamKey, Vec<DeviceId>>,

    // Analysis-specific data
    ac_stimuli: Vec<AcStimulus>,
    voltage_constraints: Vec<VoltageConstraint>,
    tline_histories: Vec<TlineHistory>,
    ltra_histories: Vec<LtraHistoryStore>,
    digital_spec: Option<DigitalNetSpec>,
    bsource_exprs: Vec<(DeviceId, BehavioralExpr)>,
}
```

### Node System

```rust
pub struct Node {
    id: NodeId,              // NodeId(u32) — index into nodes[]
    name: String,            // case-insensitive (lowercased)
    matrix_index: Option<u32>, // MNA row (None for ground)
}
```

- `NodeId::GROUND = NodeId(0)` — always present, never gets a matrix row
- MNA mapping: `NodeId(i)` → matrix row `i - 1` (ground excluded)
- Branch currents: rows `num_vars` to `num_vars + num_branches - 1`
- Total MNA dimension: `mna_dimension() = num_vars + num_branches`

### CompressedGraph (CSR Adjacency)

```rust
pub struct CompressedGraph {
    row_ptr: Vec<u32>,     // length = num_nodes + 1
    device_ids: Vec<u32>,  // flat array of device IDs per node
}
```

- `devices_at(node: NodeId) -> &[DeviceId]` = `device_ids[row_ptr[node]..row_ptr[node+1]]`
- Built once at parse time via `circuit.build_topology()`
- O(1) per-node device lookup, O(nnz) total storage
- Enables fast dirty propagation in cache layer

### ParamMap (Zero-Heap Hot Path)

```rust
pub struct ParamKey([u8; 32]); // stack-allocated, fixed-size key

pub struct ParamMap {
    inner: AHashMap<ParamKey, f64>,
}
```

- Keys limited to 32 bytes (sufficient for all SPICE parameter names)
- No heap allocation per lookup on hot path
- Case-insensitive via lowercased storage

### MNA (Modified Nodal Analysis) Formulation

The MNA system `Ax = b` has structure:

```
┌─────────────┬────────────┐ ┌───┐   ┌───┐
│  G_nodes    │  B_branch  │ │ V │   │ i │
│  (N×N)      │  (N×M)     │ │   │ = │   │
├─────────────┼────────────┤ ├───┤   ├───┤
│  C_branch   │  D_branch  │ │ I │   │ e │
│  (M×N)      │  (M×M)     │ │   │   │   │
└─────────────┴────────────┘ └───┘   └───┘
```

Where:
- `G_nodes` (N×N): Conductance between nodes (resistors, MOSFET gm/gds)
- `B_branch` (N×M): Branch coupling (V-source columns)
- `C_branch` (M×N): KVL branch rows (I_branch = g(V1, V2))
- `D_branch` (M×M): Branch-to-branch (CCVS, mutual inductance)
- `V` (N): Node voltage unknowns
- `I` (M): Branch current unknowns
- `i` (N): Current source injections at nodes
- `e` (M): Applied branch voltages

---

## 4. Stage 3 — Analysis Engine (`crates/analysis`)

### Composable Analysis Architecture

Analyses compose via nesting:

```
.STEP (outer parameter sweep)
  └─ .MC (Monte Carlo sampling)
       └─ .DC / .TRAN / .AC (inner analysis)
            └─ Solver (Newton-Raphson)
                 └─ Cache Manager
```

Each analysis is a standalone function taking `(&Circuit, &DeviceRegistry, &Config)` and returning a typed result struct. The CLI dispatches based on `AnalysisKind`.

### Complete Analysis Catalog (20+ types)

**DC Domain:**
- `dc_op::run()` — Single operating point. NR with 5-level fallback. `.IC` pin constraints via stiff conductance. Temperature sweep support.
- `dc_sweep::run()` — Parameter sweep with warm-start from previous point. Linear/decade/octave. Ascending/descending with direction validation. Nested 2-variable sweeps.

**Frequency Domain:**
- `ac::run()` — Small-signal linearized at DC OP. 2N×2N real block system (avoids complex arithmetic):
  ```
  [ G   -ωC ] [x_re]   [b_re]
  [ ωC   G  ] [x_im] = [b_im]
  ```
- `noise::run()` — Per-device noise PSD injection. Models: thermal (`4kT/R`), shot (`2qI`), 1/f flicker. Input/output referred. Per-device contribution breakdown.
- `sp::run()` — N-port S-parameter computation via wave variables. Per-port termination + excitation. Differential and single-ended ports. Configurable Z_ref (default 50Ω).

**Time Domain:**
- `transient::run()` — Time integration with BDF/Trapezoidal/Backward Euler. Adaptive timestepping. Companion model discretization for reactive elements. BDF history buffer (rolling window). Digital runtime hook for mixed-signal. LTRA history management.

**RF/Microwave (BigOSpice Exclusive):**
- `hb::run()` — Harmonic Balance. Single-tone, two-tone (APFT frequency mapping), N-tone (box truncation). Newton on frequency-domain residual with IDFT→eval→DFT cycle. SoA layout (real/imag per node per harmonic).
- `pss::run()` — Periodic Steady-State via shooting method. Transient integration over one period + monodromy Jacobian via finite differences. Error presets (Liberal/Moderate/Conservative).
- `envelope::run()` — Envelope following for modulated RF. Decouples fast carrier (HB) from slow envelope. Warm-start chaining between envelope timesteps.

**Analysis/Extraction:**
- `sensitivity::run()` — DC sensitivity via forward finite differences. `h = max(1e-8, 1e-3 × |p|)`. Absolute + relative sensitivities.
- `sens_ac::run()` — AC sensitivity. FD-perturbed AC sweep at each frequency.
- `pz::run()` — Pole-Zero. QR iteration on state matrix `A = -C⁻¹G` with Tikhonov regularization. Finds ALL poles simultaneously.
- `tf::run()` — Transfer function. DC gain, Zin, Zout from single LU with three RHS solves.
- `disto::run()` — Volterra distortion. HD2, HD3, IM2, IM3 from kernel solutions at harmonic frequencies.

**Spectral:**
- `fourier::run()` — Direct DFT on transient data. Resampling to uniform grid. Harmonics 1-9 + THD%.
- `fft::run()` — Radix-2 Cooley-Tukey. Windows: Rectangular, Hanning, Hamming, Blackman, Kaiser. Zero-pad to next power-of-2.

**Statistical:**
- `mc::run()` — Monte Carlo. DEV/LOT matching modes. Deterministic PRNG seeding `(seed, sample_idx)`. Sample 0 = nominal. SoA output.
- `wcase::run()` — Worst-case corners. Extreme (all ±kσ) and OneAtATime (perturb each independently). 2n+1 or 3 corners.
- `sampling::run()` — Latin Hypercube. Stratified quasi-MC with permuted intervals. √N faster convergence than pure MC.

**Meta/Control:**
- `sweep::run()` — Generic parameter sweep runner. LIN/DEC/OCT/LIST/DATA. Targets: GlobalParam or DeviceParam.
- `measure::run()` — Post-analysis measurements. FIND/WHEN/TRIG-TARG + AVG/RMS/MAX/MIN/PP/INTEG/DERIV. Binary signal expressions.
- `control::interpret()` — `.control`/`.endc` scripting. if/else/while/foreach/repeat/define/let/set/run/op/dc/ac/tran/alter/wrdata/write.
- `alter::apply()` — Runtime parameter modification. Device or model parameter changes between analyses.

### Time Integration Methods (Companion Models)

For transient analysis, reactive elements are discretized:

**Backward Euler (order 1):**
```
I_eq = C/h × V_new - C/h × V_old
G_eq = C/h
```

**Trapezoidal (order 2):**
```
I_eq = 2C/h × V_new - (2C/h × V_old + I_old)
G_eq = 2C/h
```

**Gear BDF (orders 2-5):**
```
I_eq = α₀C/h × V_new - Σ(αₖ × Q_{n-k}) / h
G_eq = α₀C/h
```

BDF coefficient tables (α₀, history_coeffs) stored per order. Bootstrapping: Gear-2 starts with BE first step; Gear-3 with Gear-2; etc. Order selection based on `METHOD` and `MAXORD` options.

---

## 5. Stage 4 — Solver + Linear Algebra

### Newton-Raphson Implementation

**Per-iteration hot loop:**

```
1. Clear Jacobian triplet matrix and residual vector
2. For each device in circuit:
   a. Extract terminal voltages from solution vector
   b. Apply junction voltage limiting (pnjlim, fetlim, limvds)
   c. Evaluate device model → DeviceEval { g[], q[], G[], C[], rhs[] }
   d. Stamp G entries into Jacobian triplet matrix
   e. Stamp g/rhs entries into residual vector
3. Apply diagonal regularization (Levenberg-Marquardt) for weak diagonals
4. Convert triplet → CSC matrix
5. LU factorize (or refactorize) the Jacobian
6. Solve J·dx = -residual via forward/back substitution
7. Apply damping: x_new = x_old + α·dx (BankRose adaptive α)
8. Check convergence: |dx[i]| < abstol + reltol×|x[i]| AND |F[i]| < itol
9. If not converged and iter < max_iter: goto 1
```

**Scratch buffer strategy:** `NrScratch` pre-allocates `x_new`, `x_prev`, `neg_res`, `jac_triplet`, `residual` once per `solve()` call. Reused across all iterations — avoids ~100ns allocator hits per iteration + L1/L2 cache pollution.

**Initial guess heuristics (5-pass topology-aware):**
1. Voltage source terminals → set from source voltage
2. Internal nodes → midpoint between min/max known voltages
3. MOSFET bias → pin so Vgs > Vth (avoids cutoff trap)
4. BJT bias → Vbe ≈ 0.7V, Vce ≈ 0.8×supply
5. `.NODESET` overrides → final pass

**Convergence fallback chain:** Plain NR → GMIN stepping [1e-2, 1e-3, 1e-4, 0] → Source stepping (λ=0→1 with bisection) → DC initial guess retry → Homotopy continuation → Pseudo-transient (C/dt exponential growth)

### Sparse LU Pipeline

```
Input: Triplet matrix A (row, col, val triples)
  │
  ▼
Convert to CSC (Compressed Sparse Column)
  │
  ▼
BTF Decomposition (Block Triangular Form)
  ├─ Hopcroft-Karp bipartite matching → maximum transversal
  ├─ Tarjan SCC on column dependency graph → strongly-connected components
  └─ Compose permutations → diagonal blocks + upper-triangular off-diagonal
  │
  ▼
Per-block AMD Ordering (Approximate Minimum Degree)
  ├─ Pick alive vertex of minimum current degree
  ├─ Eliminate → neighbors become clique
  └─ Repeat until all eliminated
  │
  ▼
Gilbert-Peierls Left-Looking LU (per block)
  ├─ Symbolic reach: DFS on L^T graph for sparsity pattern
  ├─ Scatter A(:,k) into dense work vector
  ├─ Numeric solve: x[i] -= L(i,j)×x[j] for fill entries
  ├─ Partial pivoting: largest |x[i]| among unpivoted rows
  └─ Emit L(:,k) and U(:,k) as CSC
  │
  ▼
LU factors { L (CSC), U (CSC), row_perm, col_perm }
  │
  ▼
Solve: b → apply perms → forward_solve(L) → back_solve(U) → undo perms → x
```

**Refactorization path:** Reuses symbolic pattern + pivot sequence. Only recomputes numeric L/U values. ~5-10x faster than full factorization. Used for NR iterations 2+ where matrix structure is stable.

**KLU C binding** (feature-gated): Same algorithm (BTF + AMD + G-P) but highly optimized C code from SuiteSparse. 64-bit indices (vs u32 native). Used for circuits >10k nodes where native AMD's O(n²) inner loop becomes expensive.

---

## 6. Computation Backends (`crates/compute`)

### Backend Trait

```rust
pub trait ComputeBackend: Send + Sync {
    fn eval_batch(&self, devices: &[DeviceData], voltages: &[f64]) -> Vec<DeviceEval>;
    fn axpy(&self, alpha: f64, x: &[f64], y: &mut [f64]);        // y += α·x
    fn dot(&self, x: &[f64], y: &[f64]) -> f64;                   // Σ(x·y)
    fn norm_inf(&self, x: &[f64]) -> f64;                         // max(|x|)
    fn scale(&self, alpha: f64, x: &mut [f64]);                   // x *= α
    fn name(&self) -> &str;
}
```

### CPU Backend

```
CpuBackend {
    parallel_config: ParallelConfig {
        min_parallel_size: 1024,  // below this: sequential
        chunk_size: 256,          // Rayon chunk size
    }
}
```

- **Sequential path:** Direct scalar loops, relies on LLVM auto-vectorization with `RUSTFLAGS="-C target-cpu=native"` for AVX2 codegen
- **Parallel path:** Rayon `par_chunks()` for vectors > `min_parallel_size`. Work-stealing threadpool scales to all cores.
- **SIMD kernels** (`crates/utility/src/simd.rs`): SSE2 intrinsics (128-bit, 4 f32/cycle):
  - `add_scaled_f32(dst, src, scalar)` — `dst[i] += src[i] * scalar`
  - `mul_scalar_f32(dst, scalar)` — `dst[i] *= scalar`
  - `add_f32(dst, a, b)` — `dst[i] = a[i] + b[i]`
  - `sum_f32(x)` — Horizontal sum via `_mm_movehdup_ps` shuffles
  - `min_f32(x)` / `max_f32(x)` — Reductions
  - `clamp_f32(x, lo, hi)` — Bounds checking
  - All have scalar fallback via `#[cfg(not(target_arch = "x86_64"))]`

### GPU Backend (wgpu)

```
WgpuBackend {
    device: wgpu::Device,
    queue: wgpu::Queue,
    pipelines: HashMap<&str, ComputePipeline>,
    min_gpu_size: usize,  // 1024 — below this, fall back to CPU
}
```

- **Availability:** `WgpuBackend::is_available()` probes for GPU adapter without allocating device
- **Workgroup size:** 256 threads
- **WGSL shaders:**
  - `axpy`: `y[gid] += alpha * x[gid]`
  - `scale`: `x[gid] *= alpha`
  - `dot_partial`: Per-workgroup reduction → CPU finishes horizontal sum
  - `norm_inf_partial`: Per-workgroup max(|x|) → CPU finishes
- **BSIM4 batch evaluation:** When `num_devices > GPU_DEVICE_THRESHOLD` (~256), device evaluation offloaded to GPU compute shader
- **Automatic fallback:** If vector length < `min_gpu_size`, transparently falls back to CPU to avoid PCIe transfer overhead

### Backend Selection (Enum Dispatch)

```rust
pub enum Backend {
    Cpu(CpuBackend),
    Gpu(WgpuBackend),
}
```

Zero-cost dispatch via `match` statement — no vtable indirection. Compiler can inline both arms. Selection logic:

```
if wgpu adapter available AND vector_size > min_gpu_size:
    use GPU
else:
    use CPU
        if vector_size > min_parallel_size:
            use Rayon parallel
        else:
            use sequential (LLVM auto-vectorized)
```

### Memory Management

- **AlignedVec** (`crates/compute/src/aligned_vec.rs`): 64-byte aligned allocation for SIMD. Ensures cache-line alignment for vectorized loops.
- **MemoryPool** (`crates/compute/src/memory_pool.rs`): Pre-allocated buffer pool for BSIM4 batch intermediates. Pop/push without allocation in steady state.
- **Pool<T>** (`crates/utility/src/pool.rs`): Generic arena allocator. `items: Vec<T>` + `free_list: Vec<usize>`. Used by device evaluators to avoid per-iteration heap allocation.

---

## 7. Stage 5 — Cache Manager (`crates/cache`)

*Detailed in Document 5 (Caching and Performance).*

Core principle: "Incremental SPICE runs just call a cached version that plugs values into the cached equation."

Six layers: TopologyCache → DirtyTracker → CompiledEvalCache → WoodburyUpdate → TransientArena → CacheManager facade.

---

## 8. Stage 6 — I/O Output (`crates/io`)

### Format Writers

| Format | Module | File Extensions | Data Types |
|--------|--------|----------------|------------|
| Berkeley Rawfile | `rawfile.rs` | `.raw` | Real (DC/Tran) + Complex (AC) |
| CSV | `csv.rs` | `.csv` | Real columns |
| HSPICE POST | `hspice.rs` | `.tr0`, `.ac0`, `.sw0` | Fortran-record f32 (complex for AC) |
| Touchstone | `touchstone.rs` | `.s1p`, `.s2p`, `.sNp` | Complex S/Y/Z matrices |
| MT0 | `mt0.rs` | `.mt0` | ASCII measurement table |

**Rawfile:** Header (text, key-value pairs: Title, Date, Plotname, Flags, No. Variables, No. Points, Variables) + separator (`Binary:` or `Values:`) + data (packed f64 or decimal). Complex data as (re, im) pairs. Round-trip compatible with ngspice.

**HSPICE POST:** Fortran-style unformatted records (4-byte LE length prefix/suffix). Header block (nauto, nprobe, nsweep, iversn, date, title) + type codes + variable names + data blocks (LE f32, 1e30 sentinel).

**Touchstone:** IBIS-ATM 1.1. Option line (`# GHz S MA R 50`). 1-port: inline. 2-port: column-major S11 S21 S12 S22. N-port (N≥3): row-major, 4 entries/line.

**AC Column Extraction** (`ac_output.rs`): Bridges complex AC data to format writers. `V(node)` → magnitude, `VM` → magnitude, `VDB` → 20·log₁₀(|V|), `VR` → real, `VI` → imaginary, `VP` → phase (degrees).

**Print/Save Wildcard Resolution** (`print_select.rs`): `V(*)` → all node voltages except ground. `I(*)` → all branch currents. `*` → both. Deduplicated output.

---

## 9. Crate Dependency Architecture

```
                              ┌─────────┐
                              │   CLI   │
                              └────┬────┘
                                   │
                    ┌──────────────┼──────────────┐
                    │              │              │
               ┌────▼────┐   ┌────▼────┐    ┌────▼────┐
               │ Parser  │   │   IO    │    │  OSDI   │
               └────┬────┘   └────┬────┘    └────┬────┘
                    │              │              │
                    ▼              │              │
               ┌─────────┐        │              │
               │  Core   │◄───────┘              │
               └────┬────┘                       │
                    │                            │
         ┌─────────┼──────────┐                  │
         │         │          │                  │
    ┌────▼────┐ ┌──▼───┐ ┌───▼────┐             │
    │Analysis │ │Cache │ │Digital │             │
    └────┬────┘ └──────┘ └───┬────┘             │
         │                    │                  │
    ┌────▼────┐          ┌───▼────┐             │
    │ Solver  │          │ Cosim  │             │
    └────┬────┘          └────────┘             │
         │                                      │
    ┌────▼────┐    ┌─────────┐                  │
    │ Linalg  │    │ Device  │◄─────────────────┘
    └────┬────┘    └────┬────┘
         │              │
         │         ┌────▼────┐
         │         │ Compute │
         │         └────┬────┘
         │              │
         └──────┬───────┘
                │
           ┌────▼────┐
           │ Utility │  (SoA, Pool, Arena, BitSet, SIMD, TypedIndex)
           └─────────┘
```

### Crate Roles Summary

| Crate | LOC (approx) | Role | Hot Path? |
|-------|-------------|------|-----------|
| `utility` | 2,000 | Data-oriented primitives | Yes (SIMD, Pool) |
| `core` | 5,000 | Circuit representation, MNA types | Warm |
| `parser` | 4,000 | Netlist parsing, expression eval | Cold (once) |
| `device` | 15,000 | 38+ device models, dispatch, registry | Yes (per NR iter) |
| `linalg` | 4,000 | Sparse LU, BTF, AMD, KLU binding | Yes (per NR iter) |
| `solver` | 5,000 | Newton-Raphson, stamping, convergence | Yes (inner loop) |
| `compute` | 3,000 | CPU/GPU backends, memory pool | Yes (device eval) |
| `cache` | 3,000 | 6-layer incremental cache | Yes (per sweep) |
| `analysis` | 12,000 | 20+ analysis types | Warm (orchestration) |
| `io` | 4,000 | 5 output format writers | Cold (once) |
| `digital` | 3,000 | 12-state logic, event queue, bridges | Conditional |
| `osdi` | 2,000 | OpenVAF Verilog-A plugin loading | Conditional |
| `cosim` | 1,000 | Verilator co-simulation | Conditional |
| `cli` | 500 | CLI argument parsing, orchestration | Cold (once) |

---

## 10. Design Philosophy

### Data-Oriented Design Principles

1. **SoA over AoS**: Parallel `Vec`s for hot-loop data. Digital events: separate `times`, `nodes`, `values` vectors. OSDI: separate terminal voltage columns. Transient history: separate `q`, `dq`, `time` arrays.

2. **Indices over pointers**: `NodeId(u32)`, `DeviceId(u32)`, `ExprIdx(u32)` — 4 bytes vs 8-byte pointer. Better cache utilization. Enables SoA layout.

3. **Existence-based processing**: BitVec dirty sets — iterate only over set bits. No per-item branching on alive/dead status.

4. **Batch operations**: Process `&[f64]` slices, not individual items. SIMD-friendly. Cache-line aligned.

5. **Hot/cold split**: `DeviceInstance` has hot `params` and cold `name`. BSIM4 has cold `params.rs`, warm `instance.rs`, hot `eval.rs`/`stamp.rs`.

6. **Enum dispatch over vtables**: `DeviceDispatch` enum with flat `match` — compiler can inline all arms. Branch predictor friendly.

7. **Zero-allocation hot paths**: `NrScratch` reused buffers. `SmallVec<[f64; 8]>` for device eval outputs (stack-allocated for typical 2-4 terminal devices). `ParamKey([u8; 32])` for parameter lookups.
