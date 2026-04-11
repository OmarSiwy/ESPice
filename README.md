# VAICS: The Architecture Blueprint

## Vectorized Incremental Analog Circuit Simulator

**Version 1.0 — Architecture Specification**

---

## 0. Why BigOSpice Exists

Every existing open-source circuit simulator was designed in a world without GPUs, without terabytes of RAM, and without the need to simulate million-transistor post-layout circuits across hundreds of PVT corners in hours rather than weeks. The commercial world has partially caught up — Synopsis PrimeSim uses GPUs for 10× speedup, Empyrean ALPS-GT achieves 15× with heterogeneous compute — but these are closed-source, expensive, and architecturally constrained by backward compatibility.

BigOSpice is designed from first principles to be the simulator that should have existed from the start: one that treats GPU acceleration, incremental re-simulation, and massive parallelism as foundational requirements rather than bolted-on afterthoughts.

**The three pillars:**

1. **Complete feature parity** with NGSpice + Xyce + VACASK combined — every analysis type, every device model, every netlist format
2. **Incremental simulation** — change a resistor value and get results in milliseconds, not minutes, by caching the compiled equation system and applying surgical matrix updates
3. **GPU-native acceleration** — device evaluation, matrix solve, and Monte Carlo sweeps all run on GPU by default, with CPU fallback for small circuits

No existing simulator combines all three. BigOSpice does.

---

## 1. Competitive Landscape — What We Beat and How

### 1.1 Feature Matrix

| Capability            | NGSpice     | Xyce             | VACASK       | CedarSim      | PrimeSim         | **BigOSpice**                |
| --------------------- | ----------- | ---------------- | ------------ | ------------- | ---------------- | -------------------------- |
| DC/AC/TRAN/Noise      | ✅          | ✅               | ✅           | ✅            | ✅               | **✅**                     |
| Harmonic Balance      | ❌          | ✅               | ✅           | ❌            | ✅               | **✅**                     |
| Sensitivity / Adjoint | Limited     | ✅               | Planned      | Planned       | ✅               | **✅**                     |
| Monte Carlo           | ✅          | ✅               | Planned      | Planned       | ✅               | **✅ (GPU-batch)**         |
| Periodic Steady-State | ❌          | Limited          | Planned      | ❌            | ✅               | **✅**                     |
| BSIM4                 | ✅          | ✅               | ✅ (VA)      | ✅ (VA)       | ✅               | **✅ (VA + GPU kernel)**   |
| BSIM-CMG (FinFET)     | ✅ (OSDI)   | ✅               | ✅ (OSDI)    | ✅            | ✅               | **✅**                     |
| All CMC models        | Partial     | Partial          | ✅ (OSDI)    | Partial       | ✅               | **✅**                     |
| Verilog-A             | OpenVAF     | ADMS             | OpenVAF      | Native        | Proprietary      | **OpenVAF-R (OSDI v0.4)**  |
| Mixed-signal          | ✅ (XSPICE) | Limited          | ❌           | ❌            | ✅               | **✅**                     |
| SPICE netlist compat  | ✅          | Via XDM          | Spectre only | SPICE+Spectre | HSPICE           | **✅ (all formats)**       |
| GPU acceleration      | ❌ (stale)  | ❌               | ❌           | ❌            | ✅ (proprietary) | **✅ (CUDA + HIP)**        |
| Incremental sim       | ❌          | ❌               | Bypass only  | Planned       | ❌               | **✅ (full stack)**        |
| MPI parallel          | ❌          | ✅ (1000s cores) | ❌           | ❌            | Multi-machine    | **✅**                     |
| OpenMP parallel       | ✅ (~2×)    | ❌               | ❌           | Julia threads | ✅               | **✅**                     |
| Shared library API    | ✅          | Limited          | Planned      | Julia API     | ❌               | **✅ (C + Python + Rust)** |
| Open source           | BSD-3       | GPL-3            | AGPL-3       | MIT/CERN      | ❌               | **LGPL-3**                 |

### 1.2 Performance Targets

| Benchmark                               | NGSpice      | Xyce         | VACASK      | **BigOSpice Target** | **Speedup vs Best OSS** |
| --------------------------------------- | ------------ | ------------ | ----------- | ------------------ | ----------------------- |
| C6288 multiplier (10K MOSFET, TRAN)     | 72s          | 152s         | 48s         | **≤8s**            | **6× vs VACASK**        |
| 9-stage ring osc (PSP, 1M timepoints)   | 2.21s        | 10.60s       | 1.89s       | **≤0.4s**          | **5× vs VACASK**        |
| SRAM 1Mbit (post-layout, 100M elements) | Days         | Hours        | —           | **≤1 hour**        | —                       |
| Parameter re-sim (1 param change)       | Full re-run  | Full re-run  | ~23% faster | **≤5% of initial** | **20× vs any**          |
| 1000-point Monte Carlo (medium circuit) | 1000× single | 1000× single | —           | **≤50× single**    | **20× vs any**          |

These targets are achievable because:

- GPU device evaluation gives 10-30× on model computation (demonstrated by PrimeSim, CUSPICE)
- GPU sparse LU gives 5-10× on matrix solve (demonstrated by SFLU, ISLU, GLU 3.0)
- Incremental simulation avoids 95% of computation on parameter changes (demonstrated by NICSLU reuse + Woodbury updates)
- Batch Monte Carlo runs thousands of independent simulations simultaneously on GPU (demonstrated by TinySPICE)

---

## 2. Core Architecture

### 2.1 Layered Design Philosophy

BigOSpice uses a strict 6-layer architecture. Each layer communicates only with its immediate neighbors through well-defined interfaces. This enables GPU acceleration, incremental caching, and parallelism to be implemented at the correct layer without cross-cutting concerns.

```
┌─────────────────────────────────────────────────────────────────────────┐
│  LAYER 6: USER INTERFACE                                                │
│  Python API · Rust API · C FFI · CLI · Jupyter · REST Server            │
│  Netlist Parsers: SPICE/HSPICE/Spectre/VACASK · PDK Loader             │
├─────────────────────────────────────────────────────────────────────────┤
│  LAYER 5: ANALYSIS ORCHESTRATOR                                         │
│  Analysis Manager · Sweep Controller · Monte Carlo Engine               │
│  Incremental Cache Manager · Result Storage · .MEASURE Post-Processing  │
├─────────────────────────────────────────────────────────────────────────┤
│  LAYER 4: ANALYSIS ENGINES                                              │
│  DC OP · DC Sweep · Transient · AC · Noise · HB · PSS · Sensitivity    │
│  Each engine owns its time integration, frequency sweep, or HB loop     │
├─────────────────────────────────────────────────────────────────────────┤
│  LAYER 3: NONLINEAR SOLVER CORE                                        │
│  Newton-Raphson · Continuation · Pseudo-Transient · Warm-Start          │
│  Convergence Control · Damping · Source Stepping · GMIN Stepping        │
├─────────────────────────────────────────────────────────────────────────┤
│  LAYER 2: LINEAR ALGEBRA ENGINE                                         │
│  Sparse Matrix Assembly · KLU (CPU) · SFLU/ISLU (GPU)                   │
│  Symbolic Factorization Cache · Numeric LU · Woodbury Updater           │
│  GMRES+ILU (GPU iterative) · Batch Solver (Monte Carlo)                │
├─────────────────────────────────────────────────────────────────────────┤
│  LAYER 1: DEVICE EVALUATION ENGINE                                      │
│  OSDI v0.4 Interface · GPU Device Kernels · CPU Fallback                │
│  g(x)/q(x)/G/C Computation · Noise Sources · Limiting Functions        │
│  OpenVAF-Reloaded Compiler · Device Instance Cache                      │
├─────────────────────────────────────────────────────────────────────────┤
│  LAYER 0: COMPUTE ABSTRACTION                                          │
│  CUDA · HIP (AMD) · CPU (fallback) · MPI (distributed)                  │
│  Memory Pool · Pinned Memory · Async Streams · Device Selection          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 2.2 Key Architectural Decisions

**Decision 1: VACASK's g(x)/q(x) separation as the device interface.**

Following VACASK's proven approach (and matching Spectre/Xyce), every device model computes only:

- `g(x)` — resistive contributions (currents as function of voltages)
- `q(x)` — reactive contributions (charges/fluxes as function of voltages)
- `G = ∂g/∂x` — conductance Jacobian
- `C = ∂q/∂x` — capacitance Jacobian

The simulator core handles ALL numerical integration. This means:

- Device models are analysis-independent (same model works for DC, TRAN, AC, HB, PSS)
- No charge-conservation bugs (Ward-Dutton problem eliminated by construction)
- GPU kernels can batch-evaluate g(x) and q(x) without knowing the analysis type
- Jacobians are computed by OpenVAF's symbolic differentiation — no manual derivative errors

**Decision 2: MNA formulation with clean reactive separation.**

The circuit equation system is:

```
g*(x) + d/dt[q*(x)] = s(t)
```

where `g*` sums all device resistive contributions, `q*` sums all reactive contributions, and `s(t)` is the source vector. Time discretization (BDF, Trapezoidal, or Matrix Exponential) is applied uniformly by the analysis engine, producing the stamped system:

```
[G* + α·C*] · Δx = -f(x_k)
```

where `α` depends on the integration method and timestep. This is the system that gets cached for incremental simulation.

**Decision 3: C++20 core with Rust safety layer and Python scripting.**

- **Core simulation loop**: C++20 (matching VACASK's proven performance advantage over C and Julia)
- **Memory management and API boundary**: Rust wrapper providing memory safety guarantees
- **User scripting and automation**: Python via pybind11 (compatible with PyOPUS, sklearn, etc.)
- **GPU compute**: CUDA (primary) + HIP (AMD) via a thin abstraction layer

**Decision 4: LGPL-3.0 licensing.**

- Allows embedding in commercial tools (unlike VACASK's AGPL)
- Requires sharing modifications to the simulator itself (unlike NGSpice's BSD)
- Compatible with all dependencies (KLU is LGPL, OpenVAF is GPL but used as a build tool)

---

## 3. The Incremental Simulation Engine — BigOSpice's Killer Feature

This is the capability no other simulator has. When a user changes one or two parameters and re-simulates, BigOSpice avoids 95%+ of the computation by reusing cached intermediate results.

### 3.1 The Five-Level Cache Hierarchy

```
LEVEL 5: TOPOLOGY CACHE (changes only on netlist structural edit)
├── Circuit graph (compressed adjacency)
├── Node-to-matrix-index mapping
├── Device-to-stamp mapping (which matrix entries each device touches)
└── KLU symbolic factorization (fill-in pattern, pivot order, elimination tree)

LEVEL 4: COMPILED MODEL CACHE (changes only on model/PDK change)
├── OpenVAF-compiled .osdi shared libraries
├── Model parameter defaults
└── GPU kernel launch configurations per model type

LEVEL 3: OPERATING POINT CACHE (changes on parameter value change)
├── Converged DC solution vector x*
├── Per-device g(x*), q(x*), G(x*), C(x*) evaluations
├── Assembled G* and C* matrices (sparse, in KLU format)
├── LU factors L, U from numeric factorization
└── Condition number estimate

LEVEL 2: TRANSIENT/AC STATE CACHE (changes on stimulus or analysis change)
├── Time-point solutions {x(t_0), x(t_1), ..., x(t_N)}
├── Per-timestep LU factors (if different from OP)
├── Krylov subspace basis vectors (for matrix-exponential method)
└── Waveform database (compressed, seekable)

LEVEL 1: RESULT CACHE (changes on measurement change)
├── .MEASURE results
├── FFT/spectral data
├── Eye diagram data
└── Extracted performance metrics
```

### 3.2 Parameter Change Flow — The 20× Speedup Path

When a user changes parameter P from value v₁ to v₂:

```
1. IDENTIFY AFFECTED DEVICES
   cache.param_to_devices[P] → {D₁, D₂, ..., Dₖ}    // O(1) lookup

2. IDENTIFY AFFECTED MATRIX ENTRIES
   for each Dᵢ: cache.device_to_stamps[Dᵢ] → {(r₁,c₁), (r₂,c₂), ...}
   Total affected entries: typically 4-20 for a single parameter change

3. RE-EVALUATE ONLY AFFECTED DEVICES (GPU if k > threshold)
   new_g = gpu_eval_g(devices=[D₁..Dₖ], params={P: v₂})
   new_G = gpu_eval_jacobian(devices=[D₁..Dₖ], params={P: v₂})

4. COMPUTE MATRIX DELTA
   ΔA = assemble_delta(new_stamps - cached_stamps)
   rank(ΔA) = typically 2-8 for single parameter change

5. CHOOSE UPDATE STRATEGY
   if rank(ΔA) ≤ WOODBURY_THRESHOLD (default: 16):
       // Sherman-Morrison-Woodbury update: O(n·r²) instead of O(n³)
       // where n = matrix dimension, r = rank of change
       L_new, U_new = woodbury_update(cache.L, cache.U, ΔA)
   elif rank(ΔA) ≤ REUSE_THRESHOLD (default: n/10):
       // Partial refactorization with symbolic reuse
       L_new, U_new = klu_refactor(cache.symbolic, A + ΔA)
   else:
       // Full factorization (rare — only when topology effectively changes)
       L_new, U_new = klu_factor(A + ΔA)

6. WARM-START NEWTON-RAPHSON
   x₀ = cache.last_solution    // Not zero — the previous converged solution
   // Typically converges in 1-3 iterations instead of 8-15
   x_new = newton_raphson(L_new, U_new, x₀, max_iter=5)

7. UPDATE CACHE
   cache.L, cache.U = L_new, U_new
   cache.last_solution = x_new
   cache.device_evals[D₁..Dₖ] = new values
```

**Why this is 20× faster:**

- Steps 1-2: microseconds (hash lookups)
- Step 3: evaluates k devices instead of N (k/N typically < 1%)
- Step 4-5: updates rank-r instead of factoring full n×n matrix
- Step 6: 1-3 Newton iterations instead of 8-15
- Net: ~5% of full simulation cost for single-parameter changes

### 3.3 Transient Re-Simulation with Matrix Exponential

For transient analysis parameter changes, BigOSpice uses a hybrid approach:

**For linear regions of the circuit** (parasitics, passive networks): Use the R-MATEX matrix exponential method. The conductance matrix G is factored once at the start. During re-simulation, the Krylov subspace basis vectors from the original simulation are reused, enabling adaptive time-stepping without any additional matrix factorizations. Published results show up to 14× speedup over trapezoidal rule.

**For nonlinear regions** (active devices): Use the standard BDF/Trap integration but with warm-started Newton iterations from the cached trajectory. The key insight from the Stanford dissertation (Deng): in a typical transient simulation, 80-95% of nodes are "idle" at any given timestep. Only the active nodes need re-evaluation.

**Checkpoint-restart**: BigOSpice periodically snapshots the full simulation state (solution vector, device states, matrix factors) to enable restarting from any timepoint. When a parameter changes, the simulator identifies the earliest affected timepoint and restarts from the previous checkpoint, rather than from t=0.

---

## 4. GPU Acceleration Architecture

### 4.1 What Runs on GPU vs CPU

| Component                     | GPU?       | Rationale                                          |
| ----------------------------- | ---------- | -------------------------------------------------- |
| Netlist parsing               | ❌ CPU     | Sequential, text processing                        |
| Topology analysis             | ❌ CPU     | Graph algorithms, done once                        |
| Symbolic factorization        | ❌ CPU     | Done once, reused across all solves                |
| **Device model evaluation**   | **✅ GPU** | Embarrassingly parallel: N independent evaluations |
| **Matrix stamp assembly**     | **✅ GPU** | Parallel scatter into sparse matrix                |
| **Numeric LU factorization**  | **✅ GPU** | SFLU/ISLU algorithms, 5-10× over CPU               |
| **Forward/back substitution** | **✅ GPU** | After factorization, parallelizable                |
| **Woodbury rank-k update**    | **✅ GPU** | Dense matrix ops → cuBLAS                          |
| **Monte Carlo batch**         | **✅ GPU** | Thousands of independent circuits                  |
| Newton convergence check      | ❌ CPU     | Simple scalar comparison                           |
| Timestep control              | ❌ CPU     | Sequential decision logic                          |
| Result storage                | ❌ CPU     | I/O bound                                          |

### 4.2 GPU Device Evaluation Pipeline

This is where the biggest single speedup comes from. The insight: all MOSFET instances of the same model type execute the same code with different data. This maps perfectly to GPU SIMT execution.

```
GPU DEVICE EVALUATION PIPELINE

1. SORT devices by model type and operating region
   → Maximizes warp coherence (devices in same region take same branches)
   → Reduces warp divergence from 60% to <10% (measured by CUSPICE team)

2. UPLOAD terminal voltages to GPU
   → Use pinned memory for async transfer
   → Only transfer changed voltages (from dirty-device tracking)

3. LAUNCH model evaluation kernel
   → One CUDA thread per device instance
   → Thread block size = 128 (empirically optimal from ALPS-GT research)
   → Each thread computes g(x), q(x), G, C for its device
   → Model parameters stored in GPU texture memory (cached, read-only)

4. DOWNLOAD results: g, q, G, C arrays
   → Async transfer overlapped with next Newton iteration setup

5. SCATTER into sparse matrix on GPU
   → Each thread writes its device's stamp entries
   → Atomic adds for shared nodes (rare for well-partitioned circuits)
```

**For BSIM4 specifically**: The model has ~300 parameters and significant branching (different equations for different operating regions). BigOSpice handles this with:

- **Region pre-sorting**: Before each Newton iteration, devices are bucketed by operating region (cutoff, linear, saturation, subthreshold). Each bucket launches a separate kernel with a region-specific code path, eliminating warp divergence.
- **Parameter texture cache**: The ~300 model parameters per device type are stored in CUDA texture memory, which provides hardware-cached, coalesced access patterns.
- **Partial evaluation**: Using the Elysian approach (Stanford, 2025), model parameters that don't change between iterations are pre-evaluated into intermediate constants, reducing per-iteration compute by 30-50%.

### 4.3 GPU Sparse LU Solver

BigOSpice implements a hybrid direct-iterative solver strategy:

**For circuits < 50K nodes**: Direct LU factorization using a GPU port of the SFLU (Synchronization-Free LU) algorithm:

- Assigns column elimination to CUDA thread blocks
- Single-kernel launch (no host-device synchronization during factorization)
- Published speedup: up to 287× over sequential CPU, 6× over 20-core CPU
- Reuses symbolic factorization across Newton iterations (structure doesn't change)

**For circuits 50K-1M nodes**: Hybrid LU + GMRES approach (following Empyrean ALPS's architecture):

- Partition circuit into overlapping blocks via hypergraph partitioning (METIS/ParMETIS)
- Internal blocks: GPU sparse LU (small, very sparse)
- Coupling between blocks: GPU-accelerated GMRES with ILU preconditioner
- Preconditioner from cached LU factors of previous iteration

**For circuits > 1M nodes**: Distributed MPI + GPU:

- Domain decomposition across MPI ranks
- Each rank handles a partition on its local GPU
- Schur complement method for inter-partition coupling
- Follows Xyce's proven MPI scaling patterns but with GPU acceleration per rank

### 4.4 GPU Monte Carlo Batch Engine

For statistical analysis (yield, mismatch, process variation), BigOSpice runs thousands of independent circuit instances simultaneously on GPU:

```
BATCH MONTE CARLO PIPELINE

1. Generate N parameter sets (Latin Hypercube or Sobol sampling)
2. Replicate circuit topology N times in GPU memory
   → Shared topology, per-instance parameter arrays
   → Memory: O(N × params) not O(N × full_circuit)
3. Run N DC operating points simultaneously
   → Each CUDA thread block handles one instance
   → Shared model code, different parameter values
4. Run N transient simulations simultaneously
   → Synchronize at convergence checkpoints
   → Adaptive timestep per instance (no global synchronization)
5. Collect N result sets
   → Statistical aggregation on GPU (mean, σ, yield)
```

Following TinySPICE's approach but at production scale. For a medium-sized circuit (1000 transistors), a single A100 GPU can run ~2000 instances simultaneously, giving an effective 2000× throughput improvement over sequential simulation.

---

## 5. Device Model Layer

### 5.1 The OpenVAF-Reloaded Pipeline

BigOSpice uses Bürmen's OpenVAF-Reloaded fork (OSDI v0.4) as the Verilog-A compiler. This provides:

- **Symbolic differentiation**: Automatic Jacobian computation — no manual derivatives
- **LLVM backend**: Compiles to native machine code (x86, ARM, RISC-V)
- **OSDI v0.4 interface**: Adds harmonic-balance Jacobian support over v0.3
- **Compilation speed**: PSP103 compiles in 3.5 seconds (vs 109s for ADMS)
- **All CMC models supported**: BSIM3, BSIM4, BSIMBULK, BSIM-CMG, BSIM-IMG, PSP, HICUM, MEXTRAM, VBIC, JUNCAP, EKV

**GPU model compilation extension**: BigOSpice extends OpenVAF with a CUDA/HIP backend that compiles Verilog-A directly to GPU kernels. This is the key innovation over VACASK:

```
Verilog-A source (.va)
    │
    ▼
OpenVAF-Reloaded Compiler
    │
    ├──→ LLVM IR (intermediate representation)
    │       │
    │       ├──→ CPU: native .osdi shared library (standard path)
    │       │
    │       └──→ GPU: NVPTX backend → .cubin GPU binary (new path)
    │               │
    │               └──→ Region-specialized variants:
    │                       bsim4_cutoff.cubin
    │                       bsim4_linear.cubin
    │                       bsim4_saturation.cubin
    │                       bsim4_subthreshold.cubin
    │
    └──→ Metadata: parameter list, terminal count, noise sources,
         operating region classifier, Jacobian sparsity pattern
```

### 5.2 Built-in Devices (C++, not Verilog-A)

Following VACASK's pattern, some devices cannot be expressed in Verilog-A and are implemented in C++:

- Independent voltage/current sources (DC, AC, PULSE, SIN, PWL, SFFM, AM, noise)
- All four linear controlled sources (VCVS, VCCS, CCVS, CCCS)
- Polynomial controlled sources
- Inductive coupling (mutual inductance)
- Transmission lines (lossless and lossy)
- Ideal switches (voltage/current controlled)
- XSPICE-compatible code model interface (for mixed-signal)

### 5.3 VADistiller Integration

Bürmen's VADistiller tool converts legacy SPICE3 C-coded models to Verilog-A automatically. BigOSpice includes this in its build pipeline so that legacy model cards from any SPICE variant can be imported:

```bash
voltaic import-model --format=spice3 --model=bsim4v4.8.3.c --output=bsim4.va
voltaic compile-model bsim4.va --target=cpu,gpu
```

---

## 6. Analysis Engines

Each analysis engine is a self-contained module that uses the nonlinear solver core (Layer 3) and linear algebra engine (Layer 2). The key is that device models don't know which analysis is running — they only compute g(x), q(x), G, C.

### 6.1 DC Operating Point

Standard Newton-Raphson with BigOSpice enhancements:

- **Source stepping**: Ramp sources from 0 to final value for difficult convergence
- **GMIN stepping**: Add/remove shunt conductances for numerical stability
- **Pseudo-transient continuation**: Treat DC as a transient problem with large timesteps (Xyce's approach, better convergence than pure NR for strongly nonlinear circuits)
- **Warm start from cache**: If a cached solution exists, start from it
- **GPU device evaluation**: All devices evaluated in parallel on GPU

### 6.2 DC Sweep

Multiple operating points with parameter variation. BigOSpice's incremental engine makes this dramatically faster:

- First point: full DC solve (cached)
- Subsequent points: Woodbury update + 1-3 NR iterations
- Continuation (from VACASK): use previous solution as starting point

### 6.3 Transient Analysis

Time integration options:

- **Trapezoidal rule** (default): No numerical damping, accurate for LC circuits. Handle ringing via LTspice's post-processing approach (not PSpice's destructive Gear-2 default)
- **BDF (Gear) methods**: Orders 1-6 for stiff circuits
- **Matrix exponential (R-MATEX)**: Factor G once, adaptive time-stepping without refactorization. Especially powerful for power delivery networks and linear-dominant circuits
- **Hybrid**: Matrix exponential for linear subcircuits, BDF for nonlinear — automatic partitioning

Timestep control:

- **Local Truncation Error**: Milne's estimate applied to voltages/currents (not charges), matching VACASK/Spectre's efficient approach
- **Breakpoint handling**: Align timesteps to source transitions
- **Checkpoint-restart**: Periodic state snapshots for incremental re-simulation

### 6.4 AC Small-Signal Analysis

Linearize around DC operating point, sweep frequency:

- Small-signal model: G + jωC
- Noise analysis: thermal, shot, flicker (1/f) from device noise models
- Pole-zero analysis
- Transfer function computation
- **GPU acceleration**: Each frequency point is independent → parallelize across frequencies on GPU

### 6.5 Harmonic Balance

For periodic steady-state of RF/microwave circuits:

- Frequency-domain nonlinear solve
- OSDI v0.4 provides HB-specific Jacobians (Bürmen's OpenVAF extension)
- Multi-tone support
- GPU acceleration: FFT/IFFT on GPU (cuFFT), device evaluation in frequency domain on GPU

### 6.6 Periodic Steady-State (PSS / Shooting)

Time-domain approach to finding periodic solutions:

- Shooting Newton method
- Converges to steady state without simulating startup transient
- Prerequisite for PAC (periodic AC) and PNoise (periodic noise) analyses
- **Krylov subspace recycling**: Reuse basis vectors across shooting iterations (following the Fast Recycling GMRES research)

### 6.7 Sensitivity Analysis

- **Direct sensitivity**: ∂x/∂p computed alongside simulation
- **Adjoint sensitivity**: Efficient for many parameters, few outputs (Xyce's strength)
- **Automatic differentiation**: Enabled by OpenVAF's symbolic differentiation — Jacobians ∂g/∂p come for free from the Verilog-A compilation

### 6.8 Uncertainty Propagation

- Monte Carlo (GPU-batched)
- Latin Hypercube Sampling
- Polynomial Chaos Expansion (for faster statistical moments than brute-force MC)
- Worst-case distance analysis

---

## 7. Netlist Compatibility Layer

BigOSpice reads all major netlist formats through a unified parser frontend:

```
Input Netlist (any format)
    │
    ├── SPICE/HSPICE parser    (.sp, .spice, .cir)
    ├── Spectre parser         (.scs)
    ├── VACASK parser          (.vacask)
    ├── PSpice parser          (.lib, .olb)
    └── XDM translator         (format conversion fallback)
    │
    ▼
Unified Circuit IR (Internal Representation)
    │
    ├── Topology graph
    ├── Device instances with parameter bindings
    ├── Analysis specifications
    ├── Subcircuit hierarchy (flattened or hierarchical)
    └── .PARAM / .FUNC expressions
```

**PDK support:**

- SKY130 (open): validated at release
- IHP SG13G2 (open): validated (VACASK already demonstrated this)
- GF180 (open): validated at release
- TSMC/Samsung/Intel (NDA): compatible via HSPICE model card import

---

## 8. Software Architecture Details

### 8.1 Directory Structure

```
voltaic/
├── core/                    # C++20 simulation engine
│   ├── circuit/             # Circuit IR, topology, stamps
│   ├── solver/              # Newton-Raphson, convergence
│   ├── linalg/              # Sparse matrix, KLU wrapper, Woodbury
│   ├── analysis/            # DC, TRAN, AC, HB, PSS, SENS engines
│   ├── device/              # OSDI interface, built-in devices
│   ├── cache/               # 5-level incremental cache
│   └── compute/             # CUDA/HIP/CPU abstraction
├── gpu/                     # GPU-specific implementations
│   ├── kernels/             # Device eval, matrix ops, batch MC
│   ├── sparse/              # SFLU, ISLU GPU sparse solver
│   └── memory/              # Pool allocator, pinned memory
├── models/                  # Verilog-A model sources
│   ├── bsim4/               # BSIM4 v4.8.3 (from CedarEDA, MIT)
│   ├── bsimcmg/             # BSIM-CMG (FinFET)
│   ├── bsimbulk/            # BSIMBULK
│   ├── psp/                 # PSP 103.4
│   ├── hicum/               # HICUM L2
│   ├── mextram/             # MEXTRAM 505
│   └── ...                  # All CMC standard models
├── parser/                  # Netlist parsers (SPICE, Spectre, etc.)
├── bindings/                # Language bindings
│   ├── python/              # pybind11 Python API
│   ├── rust/                # Rust safety wrapper + API
│   └── c/                   # C FFI for embedding
├── tools/                   # Utilities
│   ├── vadistiller/         # SPICE3 C → Verilog-A converter
│   ├── openvaf-r/           # OpenVAF-Reloaded (submodule)
│   └── benchmarks/          # Regression and performance tests
└── tests/                   # Test suite
    ├── regression/          # NGSpice/Xyce result comparison
    ├── pdk/                 # PDK validation tests
    └── performance/         # Benchmark circuits
```

### 8.2 Core Data Structures

```cpp
// The central circuit representation
struct Circuit {
    // Topology (Level 5 cache)
    CompressedGraph topology;          // Sparse adjacency: nodes × devices
    std::vector<Node> nodes;           // Node properties
    std::vector<DeviceInstance> devices; // Device instances

    // Stamp mapping (enables incremental updates)
    // device_id → [(matrix_row, matrix_col, stamp_type)]
    FlatHashMap<DeviceID, SmallVec<StampEntry, 8>> stamp_map;

    // Parameter → device mapping (enables change detection)
    // param_name → [device_ids that depend on this param]
    FlatHashMap<ParamKey, SmallVec<DeviceID, 4>> param_deps;
};

// The incremental cache
struct IncrementalCache {
    // Level 5: Topology (rarely invalidated)
    KLU_Symbolic* symbolic;            // Symbolic factorization
    std::vector<int> pivot_order;      // Cached pivot sequence

    // Level 4: Compiled models
    FlatHashMap<ModelKey, OsdiModule*> compiled_models;
    FlatHashMap<ModelKey, CudaModule*> gpu_kernels;  // GPU variants

    // Level 3: Operating point
    AlignedVector<double> solution;    // x* (converged)
    AlignedVector<double> g_cache;     // Per-device g(x*) values
    AlignedVector<double> q_cache;     // Per-device q(x*) values
    SparseMatrix<double> G_assembled;  // Full conductance matrix
    SparseMatrix<double> C_assembled;  // Full capacitance matrix
    KLU_Numeric* lu_factors;           // L, U factors

    // Level 2: Transient state
    WaveformDB waveforms;              // Compressed time-series
    std::vector<Checkpoint> checkpoints; // Restart points
    KrylovBasis krylov_cache;          // For matrix-exponential reuse

    // Dirty tracking
    BitSet dirty_devices;              // Which devices need re-eval
    SmallVec<StampEntry, 64> dirty_stamps; // Which matrix entries changed

    // Cache validity
    uint64_t topology_hash;
    uint64_t param_hash;
    CacheState state;                  // EMPTY, TOPOLOGY, OP, TRANSIENT, FULL
};

// GPU memory layout for batch device evaluation
struct GPUDeviceArray {
    // Structure of Arrays (SoA) for coalesced memory access
    double* terminal_voltages;  // [num_devices × num_terminals]
    double* g_out;              // [num_devices × num_stamps]
    double* q_out;              // [num_devices × num_stamps]
    double* G_out;              // [num_devices × num_jacobian_entries]
    double* C_out;              // [num_devices × num_jacobian_entries]
    int* region_ids;            // [num_devices] — operating region
    ModelParams* params;        // Stored in texture memory
};
```

### 8.3 The Newton-Raphson Loop (GPU-Accelerated)

```
BigOSpice NEWTON-RAPHSON ITERATION (one analysis step)

Input: Previous solution x_k (from cache or initial guess)
Output: Converged solution x_{k+1}

1. [GPU] Evaluate all devices:
   for each device type T in parallel:
       sort instances by operating region
       launch kernel: eval_g_q_G_C(instances_of_T, x_k)

2. [GPU] Assemble matrix:
   A = G* + α·C*   (α from time integration)
   b = -[g*(x_k) + α·q*(x_k) - s(t)]
   → Parallel scatter of device stamps into sparse matrix A

3. [GPU or CPU] Solve A·Δx = b:
   if cache.state >= OP and rank(ΔA) ≤ 16:
       Δx = woodbury_solve(cache.L, cache.U, ΔA, b)     // GPU cuBLAS
   elif circuit_size > 50K:
       Δx = gmres_ilu_solve(A, b, cache.preconditioner)  // GPU iterative
   elif circuit_size > 5K:
       Δx = sflu_solve(A, b, cache.symbolic)              // GPU direct
   else:
       Δx = klu_solve(A, b, cache.symbolic)               // CPU direct

4. [CPU] Update and check convergence:
   x_{k+1} = x_k + Δx
   converged = check_solution_convergence(Δx, x_{k+1}, tolerances)
              AND check_residual_convergence(f(x_{k+1}), tolerances)

5. [CPU] If not converged and iter < max_iter:
   apply damping if needed
   goto 1

6. [CPU+GPU] Update cache:
   cache.solution = x_{k+1}
   cache.lu_factors = current L, U
   cache.dirty_devices.clear()
```

---

## 9. Mixed-Signal and Co-Simulation

### 9.1 XSPICE-Compatible Code Model Interface

BigOSpice implements the XSPICE code model interface for:

- Digital primitives (AND, OR, NAND, flip-flops, etc.)
- A/D and D/A converters (automatic interface generation)
- Event-driven digital simulation (fast for pure digital sections)
- User-defined behavioral models in C

### 9.2 Verilog/VHDL Co-Simulation

Following NGSpice's d_cosim approach:

- Verilog blocks compiled with Verilator or Icarus Verilog
- VHDL blocks compiled with GHDL
- Interface via the d_cosim code model
- Analog ↔ digital boundary handled by XSPICE event system

---

## 10. Python API and Automation

```python
import voltaic

# Load circuit
ckt = voltaic.load("amplifier.sp", pdk="sky130")

# Initial simulation
result = ckt.tran(stop="1us", step="1ns")
result.plot("v(out)")

# Incremental: change one parameter, get result in milliseconds
ckt.set_param("R1", 2.2e3)           # Was 1.0e3
result2 = ckt.tran(stop="1us", step="1ns")  # Uses cached state
print(f"Incremental speedup: {result.time / result2.time:.0f}×")

# GPU Monte Carlo: 10,000 points
mc = ckt.monte_carlo(
    analysis="tran", stop="1us", step="1ns",
    variations={"R1": ("gauss", 1e3, 0.05), "C1": ("gauss", 1e-12, 0.1)},
    n_samples=10000,
    gpu=True
)
print(f"Yield: {mc.yield_at('v(out) > 0.5V'):.1%}")
print(f"Time: {mc.elapsed:.1f}s")  # ~50× faster than 10000 sequential runs

# Harmonic Balance for RF
hb = ckt.hb(fund_freq=2.4e9, harmonics=7)
hb.plot_spectrum("v(out)")

# Sensitivity
sens = ckt.sensitivity(output="v(out)", params=["R1", "R2", "C1"])
print(sens.ranking())  # Parameters sorted by impact
```

---

## 11. Performance Engineering

### 11.1 Memory Layout

- **Structure of Arrays (SoA)** for device data: enables coalesced GPU memory access
- **Arena allocators** for per-simulation temporary data: no malloc/free in hot path
- **Pinned memory** for CPU↔GPU transfer: avoids page faults during DMA
- **Memory pools** for sparse matrix data: pre-allocated based on symbolic analysis

### 11.2 Cache-Friendly Design (from VACASK)

- Expressions stored as Reverse Polish Notation for stack-based evaluation
- Matrix loading via direct pointers, not virtual function calls
- No heap allocations, range checks, or string operations in simulation loop
- Device data aligned to cache lines (64 bytes)

### 11.3 Compile-Time Optimization

- **Link-Time Optimization (LTO)**: Inline across compilation units
- **Profile-Guided Optimization (PGO)**: Optimize branch prediction for common circuits
- **Specialized builds**: Compile model kernels for specific GPU architectures (sm_70, sm_80, sm_90)

---

## 12. Development Roadmap

### Phase 1: Core Engine (Months 1-6) — "First Light"

- C++20 project setup with CMake, CI/CD
- MNA matrix assembly from circuit IR
- KLU integration (CPU sparse solver)
- Newton-Raphson with GMIN/source stepping
- DC operating point analysis
- OSDI v0.4 integration (load OpenVAF-compiled models)
- BSIM4, BSIM3, PSP model validation
- SPICE netlist parser (basic subset)
- **Milestone**: Match VACASK on C6288 benchmark

### Phase 2: GPU Acceleration (Months 4-9)

- CUDA abstraction layer
- GPU device evaluation kernel (BSIM4 first)
- GPU sparse matrix assembly
- SFLU GPU sparse solver integration
- CPU↔GPU memory management
- Region-sorting for warp coherence
- **Milestone**: 5× faster than VACASK on C6288

### Phase 3: Incremental Simulation (Months 7-12)

- 5-level cache data structure
- Parameter→device→stamp dependency tracking
- Woodbury rank-k matrix update
- Warm-start Newton-Raphson
- Symbolic factorization cache persistence
- Incremental DC sweep
- **Milestone**: Parameter re-sim in <5% of initial sim time

### Phase 4: Complete Analysis Suite (Months 10-15)

- Transient analysis with BDF/Trap
- Matrix exponential (R-MATEX) integration
- AC analysis with noise
- Harmonic Balance
- Periodic Steady-State (Shooting Newton)
- Sensitivity analysis (direct + adjoint)
- Monte Carlo GPU batch engine
- **Milestone**: Feature parity with Xyce

### Phase 5: Ecosystem (Months 13-18)

- HSPICE netlist compatibility
- Spectre netlist compatibility
- Full PDK validation (SKY130, GF180, IHP SG13G2)
- Python API (pybind11)
- Shared library API (C FFI)
- XSPICE code model interface
- Mixed-signal co-simulation
- MPI distributed support
- **Milestone**: Drop-in replacement for NGSpice/Xyce

### Phase 6: Production (Months 16-24)

- AMD HIP backend
- Comprehensive regression test suite (vs NGSpice, Xyce, HSPICE)
- Documentation and tutorials
- Benchmark publication (DAC/ICCAD paper)
- Community release
- **Milestone**: Public release 1.0

---

## 13. Team and Resources

### Minimum Viable Team: 5 people

| Role                      | Focus                                          | Skills                                       |
| ------------------------- | ---------------------------------------------- | -------------------------------------------- |
| **Lead Architect**        | Overall design, solver core, convergence       | PhD-level numerical methods, SPICE internals |
| **GPU Engineer**          | CUDA kernels, sparse GPU solver, batch MC      | CUDA optimization, sparse linear algebra     |
| **Model Engineer**        | OpenVAF integration, Verilog-A, PDK validation | Compact modeling, semiconductor physics      |
| **Systems Engineer**      | Build system, testing, CI/CD, packaging        | C++20, CMake, cross-platform                 |
| **Applications Engineer** | Python API, benchmarking, user-facing features | Python, EDA workflows, circuit design        |

### Compute Resources

- Development: 4× workstations with NVIDIA A100 or H100 GPUs
- CI/CD: GPU-enabled CI runners (GitHub Actions + self-hosted)
- Benchmarking: Access to NVIDIA A100, H100, AMD MI250X for cross-platform validation

### Budget Estimate

- Personnel (5 people × 24 months): Primary cost
- GPU hardware: ~$100K (4 workstations)
- Cloud compute for CI: ~$20K/year
- Conference travel (DAC, ICCAD, FOSDEM): ~$15K/year
- Total 2-year estimate: $2-3M (academic) or $4-6M (commercial)

---

## 14. Why BigOSpice Wins

**Against NGSpice**: 10-30× faster on large circuits (GPU), 20× faster on parameter sweeps (incremental), modern C++20 codebase vs 30-year-old C, all features preserved.

**Against Xyce**: 5-10× faster on single-node (GPU + better single-thread performance from VACASK heritage), equivalent or better MPI scaling, incremental simulation (Xyce has nothing), harmonic balance preserved.

**Against VACASK**: GPU acceleration (VACASK has none), full incremental cache (VACASK has only bypass), MPI parallelism (VACASK has none), SPICE netlist compatibility (VACASK is Spectre-only), larger model library, mixed-signal support.

**Against CedarSim**: Actually works today (no Julia compilation latency problem), GPU acceleration (CedarSim planned but unimplemented), true incremental simulation (not JIT recompilation), production-quality solver.

**Against PrimeSim/ALPS-GT (commercial)**: Open source, comparable GPU performance, incremental simulation (neither commercial tool has this), full transparency and extensibility.

The combination of GPU acceleration + incremental simulation is BigOSpice's unique moat. No simulator, open-source or commercial, has both. Together they enable workflows that are currently impossible: interactive circuit exploration with millisecond feedback, overnight yield analysis that currently takes weeks, and real-time what-if analysis during design reviews.
