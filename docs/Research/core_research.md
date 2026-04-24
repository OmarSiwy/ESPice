# BigOSpice Core & Cache Architecture Research

**Date:** 2026-04-16
**Crates:** `crates/core` + `crates/cache`

---

## Table of Contents

1. [Circuit Representation](#1-circuit-representation)
2. [Modified Nodal Analysis (MNA) Formulation](#2-modified-nodal-analysis-mna-formulation)
3. [Simulation State Management](#3-simulation-state-management)
4. [Cache Architecture](#4-cache-architecture)
5. [The Analysis Manager](#5-the-analysis-manager)

---

## 1. Circuit Representation

### 1.1 Node Data Structure

```text
NodeId(u32)                   Ground = NodeId(0)
    └── index() → usize      matrix_index = node_id.0 - 1 (excludes ground)

Node {
    id: NodeId,
    name: String,
    matrix_index: Option<u32>,  // None for ground (index 0)
}
```

**Key properties:**
- Ground is always `NodeId(0)` — it has no matrix entry.
- Non-ground nodes map to matrix row `node_id.0 - 1`.
- `CompressedGraph` encodes the node→device adjacency as CSR format.

### 1.2 Element/Device Instance Structure

```text
DeviceId(u32)  — transparent wrapper, index into device array

DeviceKind (enum, repr(u8), 0..40):
  Resistor=0, Capacitor=1, Inductor=2, Diode=3
  MosfetN=4, MosfetP=5, VoltageSource=6, CurrentSource=7
  Vcvs=8, Vccs=9, Ccvs=10, Cccs=11
  BjtNpn=12, BjtPnp=13
  BsourceV=14, BsourceI=15  (behavioral voltage/current)
  Switch=16, CSwitch=17, JfetN=18, JfetP=19
  Tline=20, VbicNpn=21, VbicPnp=22
  Bsim4N=23, Bsim4P=24, Ltra=25, VcvsExpr=26, VccsExpr=27
  Bsim3N=28, Bsim3P=29, MesfetN=30, MesfetP=31
  MosfetN2=32..MosfetP3=36, Urc=38, Wlossy=39, Port=40

DeviceInstance {
    id: DeviceId,
    name: String,
    kind: DeviceKind,
    terminals: SmallVec<[Terminal; 4]>,   // (pin, NodeId)
    params: ParamMap,
    branch_index: Option<u32>,            // MNA row for V-source/inductor branches
}
```

**Branch-supplying devices** (need a branch current variable in MNA):
- `VoltageSource`, `Inductor`, `Vcvs`, `Ccvs`, `Cccs`, `BsourceV`, `VcvsExpr`, `Tline`

### 1.3 Topology Representation

**`CompressedGraph`** — CSR (Compressed Sparse Row) format:

```text
CompressedGraph {
    row_ptr: Vec<u32>,   // node i spans row_ptr[i]..row_ptr[i+1]-1
    col_idx: Vec<DeviceId>, // devices connected to each node
    num_nodes: u32,
    num_devices: u32,
}
```

Built by `Circuit::build_topology()` from the terminal list of every device.

### 1.4 How Elements Connect to Nodes

Each `DeviceInstance` has a `terminals: SmallVec<[Terminal; 4]>` where:

```text
Terminal { pin: u8, node: NodeId }
```

The mapping `device pin → matrix row` is handled by `pin_to_global()` in the stamper:

```text
pin < num_terminals  →  matrix_index of connected node (or None for ground)
pin >= num_terminals  →  num_vars + branch_index  (branch current variable)
```

---

## 2. Modified Nodal Analysis (MNA) Formulation

### 2.1 The Fundamental Equation

```
G·x + dQ/dt = I(t)
```

Where:
- **G** = conductance matrix (real, from resistive components)
- **Q** = charge/flux vector (nonlinear, from capacitors/inductors)
- **x** = solution vector `[V_node0, V_node1, ..., I_branch0, I_branch1, ...]`
- **I(t)** = RHS vector (sources, independent currents)

### 2.2 Matrix Dimensions

```text
MNA dimension = num_vars + num_branches
num_vars      = num_nodes - 1          (ground excluded)
num_branches  = voltage sources + inductors + some controlled sources
```

Example: 3 nodes + 2 V-sources → dimension = (3-1) + 2 = 4

### 2.3 How Devices Contribute to G (Conductance) Matrix

Each device contributes stamp entries via `stamp_circuit_into()`. The stamper builds a triplet matrix `(row, col, value)`:

| Device | G contributions |
|--------|----------------|
| Resistor R between n+ and n- | `G[n+,n+] += 1/R`, `G[n-,n-] += 1/R`, `G[n+,n-] -= 1/R`, `G[n-,n+] -= 1/R` |
| V-source (branch variable I_b) | adds branch equation row: `V[n+] - V[n-] = V_dc` |
| Current source I | `RHS[n+] += I`, `RHS[n-] -= I` |
| Diode/MOSFET/BJT | linearised at operating point: `G = ∂I/∂V` (Jacobian element) |
| BsourceV (behavioral) | `G[i,j] = ∂V_expr/∂V(node_j)` — pre-differentiated symbolically |

### 2.4 How Devices Contribute to Q (Charge) Vector

Capacitors contribute to the charge vector `Q` and its time derivative `dQ/dt`:

For a capacitor C between nodes a and b:
```
I_C = C · dV_ab/dt
```

In the **trapezoidal integration** (default method):
```
dQ/dt ≈ (C/dt) · (V_ab(t) - V_ab(t-dt))  [plus correction from previous step]
```

The companion model for a capacitor at time t_n:
```
I_eq = C/dt · V_ab(t_n) - I_eq_prev
G_eq = C/dt
```

For **Gear integration** (backward differentiation):
```
dQ/dt ≈ Σ a_k · Q(t_k)  (multi-step)
```

### 2.5 How the RHS Vector I(t) is Built

The RHS (residual vector `F(x)`) is built by `stamp_circuit()` / `stamp_circuit_into()`:

```text
residual[row] = Σ G[row][col] · x[col] - RHS_contributions
```

- Independent voltage sources: branch equation sets `x[branch] = V_dc`
- Independent current sources: `residual[node] -= I(t)` (KCL injection)
- Behavioral B-sources: expression evaluated at current `x`, contributes to residual and Jacobian

### 2.6 Stamp Entry Classification

```text
StampType:
  Conductance  → G matrix entry
  Capacitance  → C/companion matrix entry
  Rhs          → RHS source vector entry
  Branch       → branch equation row/column (V-source, inductor)
```

Each `StampEntry` records `(row, col, device, kind)` enabling incremental cache updates.

---

## 3. Simulation State Management

### 3.1 Solution Vector

The solution vector `x` has dimension `num_vars + num_branches`:

```
x[0..num_vars-1]       → node voltages (V_node0, V_node1, ...)
x[num_vars..]           → branch currents (I_Vsrc0, I_L0, ...)
```

Extracted from `NrResult.solution` via `extract_results()`:
```rust
let node_voltages = circuit.nodes().iter()
    .filter_map(|node| node.matrix_index.map(|idx| (node.name.clone(), solution[idx as usize])));

let branch_currents = circuit.devices().iter()
    .filter_map(|dev| dev.branch_index.map(|bi| {
        let idx = circuit.num_vars() as usize + bi as usize;
        (dev.name.clone(), solution[idx])
    }));
```

### 3.2 Device Internal States

Device internal states (e.g., MOSFET surface potentials, BJT carrier concentrations) are managed by `DeviceEval` in `incspice_device`. These are **not** stored in the core `Circuit` struct — they're owned by the solver's scratch buffers.

### 3.3 Initial Conditions

**`.IC` (Initial Conditions):**
```rust
initial_conditions: Vec<(NodeId, f64)>  // forced node voltages during DC OP
```
Set via `Circuit::set_initial_condition()`. During DC OP preceding transient, nodes are pinned via **stiff conductance** (1e9 S) in `solve_with_ic_pins()`.

**`.NODESET`:**
```rust
node_sets: Vec<(NodeId, f64)>  // solver starting-point bias only
```
Applied as hints to the initial guess in `compute_dc_initial_guess()`, Pass 5.

### 3.4 DC Initial Guess Computation

`NewtonRaphson::compute_dc_initial_guess()` applies a 5-pass heuristic:

1. **Pass 1:** Voltage source terminals → set to source voltage
2. **Pass 2:** Unknown nodes → set to VDD/2 (midpoint)
3. **Pass 3:** MOSFET source nodes → bias so Vgs > Vth (active region from iteration 1)
4. **Pass 4:** BJT nodes → topology-aware Vbe ≈ 0.7V heuristics
5. **Pass 5:** Apply `.NODESET` overrides

### 3.5 Transient State

The transient simulation uses a `TransientArena` (see Section 4.5) for checkpointing. The state vector at each time point includes node voltages and branch currents.

---

## 4. Cache Architecture

The `incspice-cache` crate provides **five layers** of incremental cache, each independently usable, orchestrated by `CacheManager`:

### 4.1 Layer 5.1: Topology Cache (`topology_cache.rs`)

**Purpose:** Skip expensive symbolic LU factorization when topology is unchanged.

**`TopologyHash`** — 64-bit FNV-1a digest of:
- `TOPOLOGY_VERSION` (u64 constant)
- Node count
- Device count
- For each device (in declaration order): `kind as u8`, terminal count, `(pin, node_id)` pairs, `branch_index` presence

**Key insight:** Parameters are **excluded** — two circuits with identical topology but different R values share the same hash. This is what enables `.STEP` sweeps to reuse symbolic factorization.

**`SymbolicLu`** — cached symbolic factorization:
```text
col_counts: Vec<u32>       // column counts of L+U pattern
row_indices: Vec<u32>     // row indices of L+U non-zeros
amd_perm: Vec<u32>        // AMD fill-reducing permutation
amd_inv: Vec<u32>         // inverse permutation
etree_parent: Vec<u32>    // elimination tree
```

**`LinSolverCache`** — `Vec<LinSolverCacheEntry>` lookup by `TopologyHash`:
- Linear scan over entries (typically 1–4 in a sweep)
- `get_mut()` increments hit counter
- `trim(max)` retains top-`max` by hit count (naive LRU)

### 4.2 Layer 5.2: Dirty Tracker (`dirty_tracker.rs`)

**Purpose:** Track which devices need re-evaluation after parameter changes.

**Data layout (DOD):**
```text
devices: BitVec               // one bit per device
nodes: BitVec                 // one bit per non-ground node
adjacency: Vec<SmallVec<[u32; 4]>>   // device → its node row indices
device_neighbours: Vec<SmallVec<[u32; 4]>>  // device → sharing-node devices
```

**Operations:**
- `mark_param_changed(device_idx, num_devices)` — marks device + adjacent nodes dirty
- `propagate()` — two-hop: dirty device → neighbour devices (same node) → their nodes
- `iter_dirty_devices()` → `Iterator<Item = DeviceId>` via `bitvec::iter_ones()`
- `iter_dirty_nodes()` → `Iterator<Item = usize>` for MNA row iteration

### 4.3 Layer 5.3: Compiled Eval Cache (`compiled_eval.rs`)

**Purpose:** The **key differentiator** — cache affine device models for O(1) replay.

**The insight:** Every nonlinear device evaluation produces an affine local model:
```
I(V) ≈ I0 + G · (V - V0)
```

Once computed, this can be **replayed** at new operating points without a full BSIM4/diode eval, as long as `|V - V0|` stays within tolerance.

**Storage (SoA, DOD):**
```text
MAX_ROWS = 4  (hard upper bound on terminal Jacobian rows per device)

i0:  Vec<f64>     // flat n * 4, cached I0 current vector
g:   Vec<f64>     // flat n * 4 * 4, cached G Jacobian tiles (row-major)
v0:  Vec<f64>     // flat n * 4, cached linearisation voltage
valid: BitVec     // one bit per device
tolerance: f64    // |V-V0| infinity-norm threshold (default 1e-3)
```

**Operations:**
- `store(idx, rows, i0, g, v0)` — cache an affine model
- `replay(idx, v, out_i) → Option<()>` — compute `I = I0 + G·(v-v0)` if valid
- `patch_scale(idx, factor)` — scale I0 and G by factor (for W/L/M/scale params)
- `patch_temperature(idx, ratio)` — Arrhenius-like temperature patch
- Move-too-far check: `|v - v0|_∞ > tolerance` → invalidate

### 4.4 Layer 5.4: Woodbury Rank-k Update (`woodbury.rs`)

**Purpose:** Solve `(J_old + U·V^T)·x = b` without refactorizing when J changes by a low-rank update.

**Sherman-Morrison-Woodbury identity:**
```
(J + U·V^T)^{-1} = J^{-1} - J^{-1}·U·(I_k + V^T·J^{-1}·U)^{-1}·V^T·J^{-1}
```

**Cost:** `2k` base solves + `O(k^3)` dense solve for the `k×k` inner system.
**Cutover:** When `k > √n`, full refactorization is cheaper.

**Storage:** Flat SoA `Vec<f64>` for `U` and `V` (column-major, `n×k` each).

### 4.5 Layer 5.5: Transient Checkpoints (`checkpoint.rs`)

**Purpose:** Periodic snapshots for `.STEP` sweep replay and rollback.

**Storage (SoA, CSR-style):**
```text
times: Vec<f64>                    // checkpoint times (ascending)
state_offset: Vec<u32>             // CSR offsets into state_data
state_data: Vec<f64>               // flat concatenated state vectors
charge_offset: Vec<u32>            // CSR offsets for charge history
charge_data: Vec<f64>              // flat concatenated charge vectors
event_offset: Vec<u32>             // CSR offsets for digital events
event_data: Vec<(f64, u32)>        // flat event queue snapshots
```

**Operations:**
- `push(time, state, charges, events) → CheckpointIdx` — monotone append
- `nearest_before(t) → CheckpointIdx` — binary search via `partition_point` (`O(log N)`)
- `get(idx) → Checkpoint` — borrowed view
- `reset()` — O(1) clear, retains capacity

### 4.6 Layer 5.6: Cache Manager (`manager.rs`)

**Public façade** orchestrating all five layers:

```text
CacheManager {
    topology_hash: Option<TopologyHash>
    lin_cache: LinSolverCache          // Layer 5.1
    dirty: DirtyTracker                 // Layer 5.2
    compiled: CompiledEvalCache         // Layer 5.3
    checkpoints: TransientArena        // Layer 5.5
    op_solution: Vec<f64>               // warm start vector
    op_valid: bool
}
```

**Event-driven API:**
```rust
on_topology_built(&Circuit)  → bool  // returns true if topology hash hit
store_symbolic(SymbolicLu)            // stash after fresh factorization
on_param_changed(DeviceId, ParamChange)
solve_cached(rhs, eval_device) → u64  // replay dirty devices only
on_solve_complete(solution)
on_transient_step(time, state, charges, events) → CheckpointIdx
```

**ParamChange classification:**
```text
Scaling     → resistance, capacitance, inductance, W, L, M, area, scale, dc, value, amplitude
             → analytically patched into cached affine model
Temperature → temp, tnom, tj  → patch_temperature (Arrhenius ratio)
NonLinear   → everything else  → invalidate compiled entry
```

---

## 5. The Analysis Manager

The analysis manager in `crates/analysis` orchestrates simulations using the core and cache infrastructure.

### 5.1 DC Operating Point (`dc_op.rs`)

```rust
pub fn run_dc_op(circuit: &Circuit, registry: &DeviceRegistry)
    → Result<DcOpOutput, SimError>

DcOpOutput {
    result: DcOpResult { node_voltages, branch_currents },
    cache: IncrementalCache,
}
```

**Flow:**
1. Clone circuit and propagate global temperature
2. Extract warm start from cache if available
3. Call `solver.solve(circuit, registry, warm_start)`
4. Build `IncrementalCache` from topology + solution
5. Return `DcOpOutput`

### 5.2 DC Sweep (`dc_sweep.rs`)

Nested DC sweep with **up to 4 convergence strategies** per point:
1. Warm start from previous sweep point
2. Bisection between last good and target (up to 3 steps)
3. Cold start from DC initial guess
4. Reuse last good solution (with warning)

### 5.3 Transient Analysis (`transient.rs`)

Uses `TransientArena` checkpoints and integration methods (Trapezoidal/Gear/BE) from `companion.rs`.

### 5.4 Incremental Reuse in Sweeps

`ParamSweep::run_with_cache()` (in `sweep.rs`) maintains a single `CacheManager` across sweep points:
- `on_topology_built()` — computed once on first point
- `on_param_changed()` — marks dirty per parameter change
- `solve_cached()` — only re-evaluates dirty devices
- `on_transient_step()` — checkpoints for rollback

---

## Key Data Structures Summary

```
Circuit (crates/core/src/circuit.rs)
├── nodes: Vec<Node>                          // parallel node array
├── devices: Vec<DeviceInstance>             // parallel device array
├── topology: Option<CompressedGraph>        // CSR node→device adjacency
├── param_deps: AHashMap<ParamKey, SmallVec<[DeviceId; 4]>>  // param → devices
├── num_vars: u32                            // MNA voltage unknowns
├── num_branches: u32                        // MNA branch unknowns
├── initial_conditions: Vec<(NodeId, f64)> // .IC entries
├── node_sets: Vec<(NodeId, f64)>           // .NODESET entries
├── tline_histories: AHashMap<DeviceId, TlineHistory>
├── ltra_histories: AHashMap<DeviceId, LtraHistoryStore>
└── ac_stimuli: Vec<AcStimulus>

CacheManager (crates/cache/src/manager.rs)
├── topology_hash: Option<TopologyHash>      // FNV-1a of topology
├── lin_cache: LinSolverCache               // SymbolicLu by hash
├── dirty: DirtyTracker                      // BitVec per device+node
├── compiled: CompiledEvalCache             // SoA affine models
├── checkpoints: TransientArena              // SoA checkpoint storage
└── op_solution: Vec<f64>                    // warm start

NrResult (crates/solver/src/newton.rs)
├── solution: Vec<f64>                       // MNA solution vector
├── iterations: u32
├── converged: bool
└── residual: f64
```

---

## Simulation Flow Diagram

```
Netlist Parse
    ↓
Circuit::build_topology()
    ↓
CacheManager::on_topology_built()
    ├── Compute TopologyHash (FNV-1a)
    ├── DirtyTracker::rebuild_adjacency()
    ├── LinSolverCache::peek() → symbolic hit?
    └── CompiledEvalCache::resize()
    ↓
[For each analysis point]
    │
    ├─→ ParamSweep: for each param value
    │       ├─→ CacheManager::on_param_changed() → mark dirty
    │       └─→ CacheManager::solve_cached(rhs, eval_device)
    │               ├─→ DirtyTracker::iter_dirty_devices()
    │               ├─→ For each dirty device: eval_device(device)
    │               │       └─→ DeviceEval (BSIM4/diode/BJT/etc.)
    │               │               └─→ CompiledEvalCache::store(i0, G, v0)
    │               └─→ For each clean device: CompiledEvalCache::replay(v, out_i)
    │
    ├─→ NewtonRaphson::solve()
    │       ├─→ nr_loop() — plain Newton
    │       │       ├─→ stamper::stamp_circuit_into(J, residual)
    │       │       ├─→ regularize_weak_diagonals()
    │       │       ├─→ lu_factorize() or lu_refactorize()
    │       │       ├─→ lu_solve() → dx
    │       │       ├─→ limit_step() [voltage clamping]
    │       │       ├─→ damping.apply()
    │       │       └─→ convergence.check()?
    │       │
    │       ├─→ [GMIN stepping fallback]
    │       ├─→ [Source stepping fallback]
    │       ├─→ [Homotopy continuation fallback]
    │       └─→ [Pseudo-transient fallback]
    │
    └─→ CacheManager::on_solve_complete(solution)
            ├─→ Store op_solution for warm start
            ├─→ DirtyTracker::clear()
            └─→ [Woodbury: if incremental LU update applicable]
```
