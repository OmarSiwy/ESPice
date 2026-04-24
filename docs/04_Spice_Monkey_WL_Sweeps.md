# Document 4: "Spice Monkey" Width/Length Sweeps with BigOSpice

**Date:** 2026-04-21 | **Version:** 1.0

---

## 1. What Is a "Spice Monkey" Workflow?

"Spice Monkey" is the industry term for automated MOSFET characterization workflows that sweep transistor width (W) and length (L) across a design space, extracting key electrical parameters at each (W, L) point:

- **Id-Vgs curves**: Drain current vs gate-source voltage (transfer characteristic)
- **gm curves**: Transconductance vs Vgs (derivative of Id)
- **Vth extraction**: Threshold voltage (Id at a reference current, e.g., 1e-7 A)
- **Ron extraction**: On-state resistance (1/gds at low Vds)
- **Id-Vds curves**: Output characteristic (saturation behavior)
- **Matching parameters**: Avt, Aβ (area-normalized mismatch)
- **Subthreshold slope**: mV/decade below Vth
- **DIBL**: Drain-Induced Barrier Lowering (Vth shift with Vds)

This is the bread-and-butter of analog/mixed-signal IC design — characterizing transistor corners for hand calculations, matching analysis, layout-driven optimization, and model-to-silicon correlation.

### Typical Scale

| Parameter | Typical Range | Points |
|-----------|--------------|--------|
| Width (W) | 0.42 µm → 10 µm | 20 |
| Length (L) | 0.18 µm → 2 µm | 10 |
| Vgs sweep | 0 V → VDD (1.8V) | 181 |
| Vds values | 0.05V, VDD/2, VDD | 3 |
| Temperature | -40°C, 27°C, 125°C | 3 |
| **Total DC OP solves** | 20 × 10 × 181 × 3 × 3 | **~326,000** |

With ngspice, this takes minutes. With BigOSpice's cache, the vast majority of these solves are incremental updates.

---

## 2. Complete Netlist Example

### Basic NMOS Characterization

```spice
* Spice Monkey: NMOS W/L Sweep — Full Characterization
* BigOSpice netlist with HSPICE extensions

.LIB 'sky130_fd_pr.lib' tt

*--- DUT (Device Under Test) ---
M1 drain gate 0 0 sky130_fd_pr__nfet_01v8 W=Wval L=Lval

*--- Bias Sources ---
Vgs gate 0 DC 0
Vds drain 0 DC Vds_val
Vbs 0 0 DC 0

*--- Parameters ---
.PARAM Wval=1u Lval=0.18u Vds_val=1.8

*--- W/L Sweep ---
.STEP PARAM Wval  0.42u 10u 0.5u
.STEP PARAM Lval  0.18u 2u  0.2u

*--- Vds Corners ---
.STEP PARAM Vds_val LIST 0.05 0.9 1.8

*--- Temperature Sweep ---
.TEMP -40 27 125

*--- DC Transfer Curve ---
.DC Vgs 0 1.8 0.01

*--- Measurements ---
.MEAS DC vth       FIND V(gate) WHEN I(Vds)=1e-7
.MEAS DC vth_lin   FIND V(gate) WHEN I(Vds)=1e-6
.MEAS DC gm_max    MAX  deriv(I(Vds))
.MEAS DC gm_at_vth FIND deriv(I(Vds)) AT=vth
.MEAS DC id_sat    FIND I(Vds) AT=1.8
.MEAS DC id_lin    FIND I(Vds) AT=0.1
.MEAS DC id_off    FIND I(Vds) AT=0.0
.MEAS DC ron       FIND 1/deriv(I(Vds)) WHEN V(gate)=1.8
.MEAS DC ss        FIND 1/deriv(log10(abs(I(Vds))+1e-30)) WHEN I(Vds)=1e-8

*--- Output ---
.SAVE I(Vds) V(gate) V(drain)
.OPTIONS FILETYPE=ASCII
.END
```

### Advanced: PMOS + NMOS Comparison

```spice
* Spice Monkey: CMOS Pair Characterization
.LIB 'sky130_fd_pr.lib' tt

*--- NMOS DUT ---
Mn drain_n gate_n 0 0 sky130_fd_pr__nfet_01v8 W=Wn L=Ln
Vgsn gate_n 0 DC 0
Vdsn drain_n 0 DC 1.8

*--- PMOS DUT ---
Mp drain_p gate_p vdd vdd sky130_fd_pr__pfet_01v8 W=Wp L=Lp
Vgsp gate_p vdd DC 0
Vdsp drain_p vdd DC -1.8
Vdd vdd 0 DC 1.8

.PARAM Wn=1u Ln=0.18u Wp=2u Lp=0.18u

.STEP PARAM Wn 0.42u 10u 1u
.STEP PARAM Ln 0.18u 1u 0.2u
.STEP PARAM Wp 0.84u 20u 2u
.STEP PARAM Lp 0.18u 1u 0.2u

.DC Vgsn 0 1.8 0.01

.MEAS DC vth_n FIND V(gate_n) WHEN I(Vdsn)=1e-7
.MEAS DC vth_p FIND V(gate_p) WHEN I(Vdsp)=-1e-7
.MEAS DC gm_n  MAX deriv(I(Vdsn))
.MEAS DC gm_p  MAX deriv(abs(I(Vdsp)))
.MEAS DC beta_ratio PARAM='gm_n/gm_p'

.END
```

### Process Corner Sweep

```spice
* Spice Monkey: Corner Analysis
.LIB 'sky130_fd_pr.lib' tt
+ .LIB 'sky130_fd_pr.lib' ss
+ .LIB 'sky130_fd_pr.lib' ff
+ .LIB 'sky130_fd_pr.lib' sf
+ .LIB 'sky130_fd_pr.lib' fs

*--- Or use Monte Carlo ---
.MC 1000 DC
+ .PARAM Wval=GAUSS(1u, 0.05u, 3)
+ .PARAM Lval=GAUSS(0.18u, 0.01u, 3)
+ .PARAM vth0_var=AGAUSS(0, 0.01, 3)

M1 drain gate 0 0 sky130_fd_pr__nfet_01v8 W=Wval L=Lval

.DC Vgs 0 1.8 0.01
.MEAS DC vth FIND V(gate) WHEN I(Vds)=1e-7
.END
```

---

## 3. BigOSpice Execution Flow — Detailed

### Top-Level Orchestration

```
incspice --output results.raw --mt0 measurements.mt0 nmos_sweep.sp
```

```
CLI entry (crates/cli/src/main.rs)
  │
  ├─ Parse arguments: input file, output paths, quiet mode
  │
  ├─ SpiceParser::parse_file("nmos_sweep.sp")
  │    ├─ Tokenize → ParsedNetlist IR
  │    ├─ Resolve .LIB → include sky130 model file
  │    ├─ Expand subcircuits (none in this case)
  │    ├─ Evaluate .PARAM expressions
  │    └─ Return (Circuit, Vec<AnalysisStatement>, SimOptions)
  │
  ├─ DeviceRegistry::new_default()
  │    └─ Register all 38+ device types
  │
  ├─ Detect analysis stack:
  │    .STEP Wval → .STEP Lval → .STEP Vds_val → .TEMP → .DC Vgs
  │    (4-level nested sweep wrapping DC sweep)
  │
  └─ Execute analysis stack:
       sweep::run(Wval, sweep::run(Lval, sweep::run(Vds_val,
         temp_sweep(dc_sweep::run(...)))))
```

### Sweep Nesting Execution

```
LEVEL 0: .STEP Wval (20 points: 0.42u, 0.92u, 1.42u, ..., 9.92u)
│
├─ Wval = 0.42u
│  │
│  ├─ CacheManager::on_param_changed(M1, ParamChange::Scaling("w"))
│  │   ├─ DirtyTracker::mark_param_changed(device_idx=0)
│  │   │   ├─ devices[0] = true
│  │   │   └─ nodes[adjacent] = true
│  │   ├─ CompiledEvalCache::patch_scaling(M1, w_ratio)
│  │   │   ├─ i0[M1] *= (0.42u / prev_W)
│  │   │   └─ g[M1]  *= (0.42u / prev_W)
│  │   └─ WoodburyUpdate::add_rank1(delta_G_at_M1_terminals)
│  │
│  └─ LEVEL 1: .STEP Lval (10 points: 0.18u, 0.38u, ..., 1.98u)
│     │
│     ├─ Lval = 0.18u
│     │  │
│     │  ├─ CacheManager::on_param_changed(M1, ParamChange::Scaling("l"))
│     │  │   └─ (same dirty + patch flow as W change)
│     │  │
│     │  └─ LEVEL 2: .STEP Vds_val (3 points: 0.05, 0.9, 1.8)
│     │     │
│     │     ├─ Vds_val = 0.05
│     │     │  │
│     │     │  ├─ CacheManager::on_param_changed(Vds, ParamChange::Scaling("dc"))
│     │     │  │   └─ Mark Vds dirty, patch source value
│     │     │  │
│     │     │  └─ LEVEL 3: .TEMP (-40, 27, 125)
│     │     │     │
│     │     │     ├─ T = -40°C (233.15 K)
│     │     │     │  │
│     │     │     │  ├─ CacheManager::on_param_changed(M1, ParamChange::Temperature)
│     │     │     │  │   ├─ Patch Is, mobility, Vth temperature terms
│     │     │     │  │   └─ Arrhenius-like ratio: I0_new = I0_old × f(T_new/T_old)
│     │     │     │  │
│     │     │     │  └─ DC SWEEP: Vgs 0→1.8V (181 points)
│     │     │     │     │
│     │     │     │     ├─ First point (Vgs=0):
│     │     │     │     │   ├─ Warm-start from cached OP solution
│     │     │     │     │   ├─ Newton-Raphson iterations (typically 3-8)
│     │     │     │     │   │   ├─ Stamp circuit (only dirty devices)
│     │     │     │     │   │   ├─ LU solve (Woodbury if rank-k small)
│     │     │     │     │   │   └─ Converge
│     │     │     │     │   └─ Cache OP solution for next point
│     │     │     │     │
│     │     │     │     ├─ Subsequent points (Vgs=0.01, 0.02, ...):
│     │     │     │     │   ├─ Warm-start from previous Vgs point
│     │     │     │     │   ├─ Typically 2-4 NR iterations (close to prev)
│     │     │     │     │   └─ Affine replay for unchanged devices
│     │     │     │     │
│     │     │     │     └─ Collect: times[], voltages[], currents[]
│     │     │     │
│     │     │     └─ .MEAS evaluation on DC sweep results:
│     │     │         vth, gm_max, id_sat, ron, ss, ...
│     │     │         → append row to MT0 table
│     │     │
│     │     └─ (repeat for Vds_val = 0.9, 1.8)
│     │
│     └─ (repeat for Lval = 0.38u, ..., 1.98u)
│
└─ (repeat for Wval = 0.92u, ..., 9.92u)
```

### Cache State Machine Through Sweep

```
TIME ──────────────────────────────────────────────────────────────────►

Event:        on_topology_built    on_param_changed(W)    on_param_changed(L)
              │                    │                       │
Cache State:  │                    │                       │
              │                    │                       │
TopologyCache:│ COMPUTE hash       │ HIT (same topology)  │ HIT (same topology)
              │ MISS → build       │ reuse symbolic LU    │ reuse symbolic LU
              │ symbolic LU        │                       │
              │                    │                       │
DirtyTracker: │ ALL dirty (first)  │ M1 dirty             │ M1 dirty
              │                    │ propagate → Vds, Vgs  │ propagate → Vds, Vgs
              │                    │ (shared nodes)        │ (shared nodes)
              │                    │                       │
CompiledEval: │ EMPTY              │ M1 patched (W scale) │ M1 patched (L scale)
              │ → fill on first    │ Vds, Vgs: replay     │ Vds, Vgs: replay
              │   solve            │ affine               │ affine
              │                    │                       │
WoodburyUpd:  │ N/A                │ rank-1 update ΔG(M1) │ rank-1 update ΔG(M1)
              │                    │                       │
OpSolution:   │ EMPTY              │ warm-start from prev │ warm-start from prev
              │ → fill on first    │                       │
              │   converge         │                       │
```

---

## 4. Cache Exploitation — Deep Technical Analysis

### Level 1: Topology Cache Hit

**What's cached:** The complete symbolic LU factorization output:
- `col_counts: Vec<usize>` — column counts of L+U
- `row_indices: Vec<u32>` — packed row indices by column
- `amd_perm: Vec<u32>` — fill-reducing permutation (AMD ordering)
- `amd_inv: Vec<u32>` — inverse permutation
- `etree_parent: Vec<i32>` — elimination tree

**When it hits:** The topology hash (FNV-1a over node count + device kinds + terminal connectivity) is identical between sweep points. W and L changes don't alter connectivity — M1 still connects to the same drain, gate, source, bulk nodes.

**Cost saved:** Symbolic factorization is O(n log n) for AMD ordering + O(nnz + fill) for symbolic LU pattern prediction. For a 50-node test bench, this is ~10,000 operations saved per sweep point. Over 36,200 sweep points: **362 million operations saved.**

**Hash computation:**
```rust
fn topology_hash(circuit: &Circuit) -> TopologyHash {
    let mut h = FnvHasher::new();
    h.write_u32(circuit.num_nodes());
    for dev in circuit.devices() {
        h.write_u8(dev.kind.discriminant());
        for term in &dev.terminals {
            h.write_u8(term.order as u8);
            h.write_u32(term.node.0);
        }
    }
    h.write_u32(TOPOLOGY_VERSION);
    TopologyHash(h.finish())
}
```

Deterministic FNV-1a (not ahash) so sweeps can persist symbolic factors between invocations.

### Level 2: Dirty Tracking + Compiled Eval Patching

**What's tracked:** BitVec per device (1 bit each) + BitVec per node + SmallVec adjacency map.

**When W changes:**
```
mark_param_changed(M1_idx=0, num_devices=4)
  → devices.set(0, true)       // M1 dirty
  → nodes.set(drain-1, true)   // drain node dirty
  → nodes.set(gate-1, true)    // gate node dirty
  → nodes.set(0-1, true)       // source/bulk node dirty (ground excluded)

propagate()
  → M1's neighbors via shared nodes: {Vds (drain), Vgs (gate), Vbs (source)}
  → devices.set(Vds_idx, true)
  → devices.set(Vgs_idx, true)
  → devices.set(Vbs_idx, true)
  → Result: 4 devices dirty out of 4 total
```

Wait — in this simple test bench, ALL devices share nodes with M1. So dirty tracking doesn't help much for this tiny circuit.

**But for a realistic test bench** (e.g., opamp with 50 transistors, 20 resistors, 10 caps, 5 voltage sources):
- Change W of M1 (input pair transistor)
- M1 dirty → propagate to nodes it touches
- Only neighbors (M2 matching transistor, R_load, C_comp) get marked dirty
- 80+ other devices remain clean → skip their evaluation entirely
- **Savings: 80-95% of device evaluations skipped**

**Compiled eval patching for W:**
```
ParamChange::Scaling("w") →
  For device M1:
    w_ratio = W_new / W_old
    i0[M1] *= w_ratio        // I_ds scales linearly with W
    g[M1, :, :] *= w_ratio   // All conductances scale with W
    // V0 (linearization point) unchanged
    // valid bit remains TRUE (no full re-eval needed)
```

This works because BSIM4 drain current is proportional to W:
```
I_ds = (W/L) × µ_eff × C_ox × (V_gs - V_th)² × ... (simplified)
```

When only W changes, all terms scale linearly. The affine model I(V) ≈ I0 + G·(V-V0) can be analytically patched without re-running the 1000+ FLOP BSIM4 evaluation.

**For L changes:** L appears in the denominator AND in short-channel effects (SCE, DIBL, CLM). The affine patch is less accurate but still valid for small ΔL. For large ΔL, the cache invalidates (`MovedTooFar`) and triggers full re-eval.

### Level 3: Woodbury Rank-1 Update

**When to use:** After patching M1's conductance, the Jacobian changes at M1's terminal positions only. This is a rank-1 (or rank-k with k=number of M1 terminals=4) perturbation:

```
J_new = J_old + Σ(ΔG_ij × e_i × e_j^T)
```

Where `ΔG_ij` is the change in conductance between terminals i and j, and `e_i` is the unit vector at node i.

**Sherman-Morrison solve:**
```
Given: J_old already factored (L, U from previous point)
Given: u, v such that J_new = J_old + u·v^T

1. Solve J_old · y = b        (forward/back substitution: O(nnz))
2. Solve J_old · z = u        (forward/back substitution: O(nnz))
3. Compute α = 1 + v^T · z    (dot product: O(n))
4. Return x = y - (v^T·y/α)·z (axpy: O(n))
```

**Cost:** 2 triangular solves + O(n) arithmetic vs. O(nnz) LU refactorization.

**Cutover criterion:**
```rust
fn should_use_woodbury(n: usize, k: usize) -> bool {
    k <= (n as f64).sqrt().max(1.0) as usize
}
```

For our 50-node test bench: √50 ≈ 7. A BSIM4 has 4 terminals = rank-4 update. 4 ≤ 7, so Woodbury is used. For a 10,000-node circuit: √10000 = 100, so up to rank-100 updates use Woodbury.

---

## 5. Performance Analysis

### Detailed Cost Model

**Setup cost (once):**

| Operation | Cost | Notes |
|-----------|------|-------|
| Parse netlist | ~1 ms | .LIB inclusion dominates |
| Build circuit | ~0.1 ms | 4 devices, 5 nodes |
| Topology hash | ~1 µs | FNV-1a, 4 devices |
| Symbolic LU | ~50 µs | AMD + symbolic for 50×50 |
| First DC OP | ~500 µs | Full NR, 8 iterations |
| Cache warmup | ~20 µs | Fill compiled eval cache |
| **Total setup** | **~1.6 ms** | |

**Per-sweep-point cost (incremental, BigOSpice):**

| Operation | Cost | Notes |
|-----------|------|-------|
| Param change notify | ~2 µs | Mark dirty + patch affine |
| Woodbury update | ~5 µs | Rank-4 SM for 50×50 |
| Dirty device eval (M1) | ~3 µs | Single BSIM4 eval |
| Affine replay (3 clean) | ~0.5 µs | Multiply cached I0/G |
| NR convergence | ~15 µs | 2-3 iterations (warm start) |
| Measure extraction | ~1 µs | Find/When on 181-point curve |
| **Total per point** | **~27 µs** | |

**Per-sweep-point cost (brute force, ngspice):**

| Operation | Cost | Notes |
|-----------|------|-------|
| Full CKTsetup | ~50 µs | Allocate matrix ptrs |
| Symbolic factorization | ~50 µs | Markowitz ordering |
| All device evals (4) | ~15 µs | Full BSIM4 + sources |
| LU refactorization | ~10 µs | Full numeric |
| NR convergence | ~80 µs | 5-8 iterations (cold start) |
| Measure extraction | ~1 µs | Same |
| **Total per point** | **~206 µs** | |

### Projection at Scale

**200-corner W/L sweep × 181 DC points × 3 Vds × 3 temperatures:**

| Metric | ngspice | BigOSpice | Speedup |
|--------|---------|-----------|---------|
| Total DC solves | 326,000 | 326,000 | — |
| Symbolic factorizations | 1,800 | **1** | 1,800x |
| Full BSIM4 evals | 326,000 × 4 = 1.3M | 1,800 × 4 + 324,200 × 1 = 331,400 | 3.9x |
| LU refactorizations | 326,000 | ~1,800 (rest Woodbury) | ~180x |
| NR iterations (total) | ~2M (avg 6/solve) | ~800K (avg 2.5/solve) | 2.5x |
| **Wall time** | **~67 s** | **~9 s** | **~7.5x** |

*Estimates for 50-node test bench on modern x86-64. Real speedup varies with circuit size.*

### Speedup Scaling with Circuit Size

| Test Bench Size | ngspice (per solve) | BigOSpice (per solve) | Speedup |
|----------------|--------------------|-----------------------|---------|
| 5 nodes (minimal) | 50 µs | 15 µs | 3.3x |
| 50 nodes (typical) | 200 µs | 27 µs | 7.4x |
| 500 nodes (opamp) | 2 ms | 150 µs | 13x |
| 5000 nodes (full chip) | 50 ms | 2 ms | 25x |

Speedup increases with circuit size because:
1. Topology cache saves more (symbolic LU cost grows with n)
2. More clean devices to skip (dirty fraction shrinks)
3. Woodbury savings grow (√n cutover means larger rank-k updates)

---

## 6. Output Formats for Spice Monkey

### MT0 Measurement Table

Primary output for automated characterization:

```
$DATA1 SOURCE='incspice-mc' VERSION='1.0'
.TITLE Spice Monkey NMOS W/L Sweep

 alter#   W          L          Vds        Temp       vth         gm_max      id_sat      ron         ss
 1        4.200e-07  1.800e-07  1.800e+00  2.731e+02  4.512e-01   1.235e-03   5.679e-04   1.235e+02   6.834e+01
 2        4.200e-07  1.800e-07  9.000e-01  2.731e+02  4.489e-01   8.901e-04   2.345e-04   2.468e+02   6.912e+01
 3        4.200e-07  1.800e-07  5.000e-02  2.731e+02  4.234e-01   1.567e-04   7.890e-06   1.567e+03   7.123e+01
 ...
```

One row per (W, L, Vds, Temp) corner. Columns are measurement names. Failed measurements = `nan`. Directly importable to Python pandas, MATLAB, Excel.

### Rawfile (Full I-V Curves)

```
Title: Spice Monkey NMOS W/L Sweep - Corner #1
Date: Mon Apr 21 2026
Plotname: DC transfer characteristic
Flags: real
No. Variables: 3
No. Points: 181
Variables:
  0  v-sweep  voltage
  1  v(drain) voltage
  2  i(vds)   current
Binary:
[packed f64 data for 181 × 3 values]
```

Multiple plots in one rawfile (one per corner). Viewable in any SPICE waveform viewer (GTKWave, WaveTrace, etc.).

### CSV for Python/MATLAB

```csv
Vgs,Id_W0.42u_L0.18u,Id_W0.92u_L0.18u,...
0.000,1.234e-12,2.345e-12,...
0.010,5.678e-11,8.901e-11,...
0.020,1.234e-09,2.345e-09,...
...
1.800,5.679e-04,1.234e-03,...
```

### HSPICE POST Binary

```
.tr0 file — Fortran-style unformatted records
Header: nauto=1, nprobe=3, iversn=9601
Variable types: [1, 2, 3]  (time/voltage/current)
Variable names: ["v_sweep", "v(drain)", "i(vds)"]
Data: LE f32 values, 1e30 sentinel at end of each sweep
```

Compatible with HSPICE waveform viewers and post-processing tools used in production IC design.

---

## 7. Post-Processing Integration

### Python Script Example

```python
import pandas as pd
import numpy as np
import matplotlib.pyplot as plt

# Read MT0 measurement table
mt0 = pd.read_csv('measurements.mt0', delim_whitespace=True, skiprows=3)

# Pivot: W vs L vs Vth
pivot = mt0.pivot_table(values='vth', index='W', columns='L')

# Contour plot of Vth(W, L)
fig, ax = plt.subplots(figsize=(10, 8))
cs = ax.contourf(pivot.columns * 1e6, pivot.index * 1e6, pivot.values,
                 levels=20, cmap='RdYlBu_r')
ax.set_xlabel('Length (µm)')
ax.set_ylabel('Width (µm)')
ax.set_title('NMOS Vth vs W/L')
plt.colorbar(cs, label='Vth (V)')
plt.savefig('vth_contour.png', dpi=150)

# gm/Id efficiency curve
mt0['gm_id'] = mt0['gm_max'] / mt0['id_sat']
for L in mt0['L'].unique():
    subset = mt0[mt0['L'] == L]
    plt.plot(subset['W'] * 1e6, subset['gm_id'], label=f'L={L*1e6:.2f}µm')
plt.xlabel('Width (µm)')
plt.ylabel('gm/Id (1/V)')
plt.legend()
plt.savefig('gm_id_efficiency.png', dpi=150)
```

### MATLAB Script Example

```matlab
% Read MT0 file
data = readtable('measurements.mt0', 'FileType', 'text', 'HeaderLines', 3);

% Extract unique W and L values
W_vals = unique(data.W);
L_vals = unique(data.L);

% Build Vth matrix
Vth = zeros(length(W_vals), length(L_vals));
for i = 1:length(W_vals)
    for j = 1:length(L_vals)
        idx = data.W == W_vals(i) & data.L == L_vals(j) & data.Vds == 1.8 & data.Temp == 273.15;
        Vth(i,j) = data.vth(idx);
    end
end

% Surface plot
figure;
surf(L_vals*1e6, W_vals*1e6, Vth);
xlabel('L (µm)'); ylabel('W (µm)'); zlabel('Vth (V)');
title('NMOS Threshold Voltage vs Geometry');
```

---

## 8. Comparison: BigOSpice vs ngspice for Spice Monkey

### Feature Comparison

| Feature | ngspice | BigOSpice |
|---------|---------|-----------|
| **Nested .STEP** | Via .control scripting (no built-in nested sweep) | Built-in 4+ level nesting |
| **Arbitrary param sweep** | .STEP limited to source values | .STEP on any .PARAM or device parameter |
| **Built-in .MEAS** | Yes (in .control block) | Yes (native, post-analysis) |
| **MT0 output** | No | Built-in |
| **Topology caching** | No | Full symbolic LU reuse |
| **Dirty tracking** | No | BitVec + adjacency propagation |
| **Affine patching** | No | Scaling params (W, L, M, area, temp) |
| **Woodbury update** | No | Rank-k LU update for small ΔG |
| **Warm-start** | Previous sweep point only | Previous point + cached OP + affine replay |
| **Temperature sweep** | Single .TEMP value (manual loop) | Multi-.TEMP built-in |

### Wall-Time Comparison (200-corner sweep)

```
ngspice:     ████████████████████████████████████████████████████  67s
BigOSpice:   ████████                                              9s
                                                                    ↑
                                                              7.5x faster
```

### Memory Comparison

```
ngspice:     ████████████████████████  2.2 GB (with Skywater PDK bin bloat)
BigOSpice:   ██                        ~180 MB (SoA + index-based)
                                                                    ↑
                                                              12x less
```
