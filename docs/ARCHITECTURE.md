# BigOSpice Architecture Documentation

> **Complete technical reference for the BigOSpice SPICE-compatible circuit simulator.**
> Covers device models, numerical methods, analysis engines, solver algorithms, netlist format, and data structures.
> All equations rendered in LaTeX.

---

## Table of Contents

### Part I: Foundations
1. [Circuit Representation & MNA Formulation](#1-circuit-representation--mna-formulation)
2. [Device Model Interface (g(x)/q(x))](#2-device-model-interface-gxqx)
3. [Newton-Raphson Solver](#3-newton-raphson-solver)

### Part II: Device Models
4. [Diode Model](#4-diode-model)
5. [BJT Models (Gummel-Poon & VBIC)](#5-bjt-models-gummel-poon--vbic)
6. [MOSFET Models (Level 1/2/3/6)](#6-mosfet-models-level-1236)
7. [BSIM3 MOSFET Model](#7-bsim3-mosfet-model)
8. [BSIM4 MOSFET Model](#8-bsim4-mosfet-model)
9. [JFET and MESFET Models](#9-jfet-and-mesfet-models)

### Part III: Analysis Engines
10. [DC Operating Point Analysis](#10-dc-operating-point-analysis)
11. [DC Sweep Analysis](#11-dc-sweep-analysis)
12. [Transient Analysis](#12-transient-analysis)
13. [Time Integration Methods (BDF/Gear/Trapezoidal)](#13-time-integration-methods-bdfgeartrapezoidal)
14. [AC Small-Signal Analysis](#14-ac-small-signal-analysis)
15. [Noise Analysis](#15-noise-analysis)
16. [Harmonic Balance](#16-harmonic-balance)
17. [Periodic Steady-State (Shooting)](#17-periodic-steady-state-shooting)
18. [Fourier Analysis](#18-fourier-analysis)
19. [Transfer Function & Sensitivity](#19-transfer-function--sensitivity)
20. [Pole-Zero Analysis](#20-pole-zero-analysis)
21. [Distortion Analysis](#21-distortion-analysis)
22. [S-Parameter Analysis](#22-s-parameter-analysis)

### Part IV: Solver & Linear Algebra
23. [Sparse Matrix Implementation](#23-sparse-matrix-implementation)
24. [LU Factorization (BTF+AMD+Gilbert-Peierls)](#24-lu-factorization-btfamdgilbert-peierls)
25. [Convergence & Damping Strategies](#25-convergence--damping-strategies)
26. [GMIN/Source Stepping & Pseudo-Transient](#26-gminsource-stepping--pseudo-transient)

### Part V: Netlist & Parser
27. [Netlist Format Reference](#27-netlist-format-reference)
28. [Expression Syntax](#28-expression-syntax)
29. [Waveform Sources](#29-waveform-sources)

### Part VI: Advanced Topics
30. [OSDI Interface (Verilog-A Models)](#30-osdi-interface-verilog-a-models)
31. [Digital/XSPICE Simulation](#31-digitalxspice-simulation)
32. [Verilator Co-Simulation](#32-verilator-co-simulation)
33. [GPU Acceleration](#33-gpu-acceleration)
34. [Incremental Cache Architecture](#34-incremental-cache-architecture)

### Appendices
A. [Device Model Parameters Reference](#a-device-model-parameters-reference)
B. [Analysis Types Summary](#b-analysis-types-summary)
C. [Directory Structure](#c-directory-structure)

---

# Part I: Foundations

## 1. Circuit Representation & MNA Formulation

### 1.1 Node Representation

```text
NodeId(u32)                   Ground = NodeId(0)
    └── index() → usize      matrix_index = node_id.0 - 1 (excludes ground)
```

- Ground is always `NodeId(0)` — it has no matrix entry
- Non-ground nodes map to matrix row `node_id.0 - 1`
- `CompressedGraph` (CSR format) encodes node→device adjacency for O(1) device lookup

### 1.2 Device Instance Structure

```text
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

### 1.3 The Fundamental MNA Equation

The circuit equation system is:

$$G \cdot x + \frac{dQ}{dt} = I(t)$$

Where:
- **G** = conductance matrix (real, from resistive components)
- **Q** = charge/flux vector (nonlinear, from capacitors/inductors)
- **x** = solution vector `[V_node0, V_node1, ..., I_branch0, ...]`
- **I(t)** = RHS vector (sources, independent currents)

### 1.4 Matrix Dimensions

```text
MNA dimension = num_vars + num_branches
num_vars      = num_nodes - 1          (ground excluded)
num_branches  = voltage sources + inductors + some controlled sources
```

The matrix has the block form:

$$\begin{pmatrix} G & B \\ B^T & 0 \end{pmatrix} \cdot \begin{pmatrix} V \\ I \end{pmatrix} = \begin{pmatrix} I_{\text{sources}} \\ E_{\text{v_sources}} \end{pmatrix}$$

Where:
- **G** is the n×n conductance matrix (nodal stamps)
- **B** is the n×b branch incidence matrix
- **V** is the vector of node voltages (size n)
- **I** is the vector of branch currents (size b)

### 1.5 How Devices Contribute to the MNA Matrix

| Device | G contributions |
|--------|----------------|
| Resistor R between n+ and n- | `G[n+,n+] += 1/R`, `G[n-,n-] += 1/R`, `G[n+,n-] -= 1/R`, `G[n-,n+] -= 1/R` |
| V-source (branch variable I_b) | adds branch equation row: `V[n+] - V[n-] = V_dc` |
| Current source I | `RHS[n+] += I`, `RHS[n-] -= I` |
| Diode/MOSFET/BJT | linearised at operating point: `G = ∂I/∂V` (Jacobian element) |
| BsourceV (behavioral) | `G[i,j] = ∂V_expr/∂V(node_j)` — pre-differentiated symbolically |

### 1.6 DC Initial Guess Computation

`NewtonRaphson::compute_dc_initial_guess()` applies a 5-pass heuristic:

1. **Pass 1:** Voltage source terminals → set to source voltage
2. **Pass 2:** Unknown nodes → set to VDD/2 (midpoint)
3. **Pass 3:** MOSFET source nodes → bias so Vgs > Vth (active region from iteration 1)
4. **Pass 4:** BJT nodes → topology-aware Vbe ≈ 0.7V heuristics
5. **Pass 5:** Apply `.NODESET` overrides

---

## 2. Device Model Interface (g(x)/q(x))

### 2.1 The DeviceModel Trait

All devices implement the `DeviceModel` trait:

```rust
pub trait DeviceModel: Send + Sync {
    fn eval(&self, voltages: &[f64], params: &ParamMap) -> DeviceEval;
    fn num_terminals(&self) -> usize;
    fn needs_branch(&self) -> bool { false }
    fn kind(&self) -> DeviceKind;
    fn eval_with_branch(&self, voltages: &[f64], branch_current: f64, params: &ParamMap) -> DeviceEval;
    fn eval_at_time(&self, voltages: &[f64], params: &ParamMap, t: f64) -> DeviceEval;
}
```

### 2.2 DeviceEval — The Stamping Interface

```rust
pub struct DeviceEval {
    pub g: SmallVec<[f64; 8]>,           // Resistive currents per terminal
    pub q: SmallVec<[f64; 8]>,           // Charge/flux per terminal
    pub G: SmallVec<[(u8, u8, f64); 8]>, // Conductance Jacobian: (row, col, value) = dg/dx
    pub C: SmallVec<[(u8, u8, f64); 16]>,// Capacitance Jacobian: (row, col, value) = dq/dx
    pub rhs: SmallVec<[f64; 4]>,         // Direct RHS contributions
}
```

**Convention:** All `g` and `q` values represent net current **leaving** the node (MNA convention).

### 2.3 The g(x)/q(x) Interface Pattern

The fundamental SPICE device interface:

- **g(x)**: Vector of resistive currents = $I_D(V_1, ..., V_n)$ — contributes to MNA G matrix
- **q(x)**: Vector of stored charges = $Q(V_1, ..., V_n)$ — contributes to MNA C matrix via $\frac{dq}{dt} = \frac{\partial q}{\partial V} \cdot \frac{dV}{dt}$

- **G Jacobian**: $\frac{\partial g}{\partial V}$ — Newton-Raphson update
- **C Jacobian**: $\frac{\partial q}{\partial V}$ — time integration

This separates DC (purely resistive, q=0) from transient (g handles resistors, q handles capacitors/inductors).

### 2.4 Jacobian Convention

`G[row, col]` = $\frac{\partial g[row]}{\partial V[col]}$ where:
- `row` = terminal whose current equation is being differentiated
- `col` = voltage node being perturbed

For a 2-terminal diode:
```
G[0,0] = +G_D   (dI_anode/dV_anode)
G[0,1] = -G_D   (dI_anode/dV_cathode)
G[1,0] = -G_D   (dI_cathode/dV_anode)
G[1,1] = +G_D   (dI_cathode/dV_cathode)
```

---

## 3. Newton-Raphson Solver

### 3.1 Core Iteration Formula

The Newton-Raphson (NR) algorithm solves the nonlinear system $F(x) = 0$ via the iteration:

$$x_{n+1} = x_n - J^{-1}(x_n) \cdot F(x_n)$$

In circuit simulation:
- **x** — the MNA solution vector
- **F(x)** — the residual vector (KCL equations), computed by the stamper
- **J(x) = ∂F/∂x** — the Jacobian matrix (also built by the stamper)

The actual solve uses:

$$J \cdot \Delta x = -F(x_n) \implies \Delta x = -J^{-1} \cdot F(x_n)$$
$$x_{n+1} = x_n + \Delta x$$

### 3.2 Convergence Criteria

The `ConvergenceCriteria` implements **both** an update-based test AND a residual-based test:

**Update test (relative + absolute tolerance):**
$$\forall i: |dx_i| < \text{abstol} + \text{reltol} \cdot |x_i|$$

**Residual test:**
$$\forall i: |F_i(x)| < \text{i\_tol}$$

Where `i_tol = abstol × 1000` (SPICE convention).

### 3.3 Damping Strategies

**Bank-Rose (adaptive):** Halves the step when the residual grows:

$$x_{n+1} = x_n + \alpha \cdot \Delta x, \quad \alpha = \begin{cases} 0.5 & \text{if } \|F(x_{n+1})\| > \|F(x_n)\| \\ 1.0 & \text{otherwise} \end{cases}$$

### 3.4 Voltage Step Limiting

An additional per-iteration clamp prevents large voltage swings (SPICE's `VNSTEP` option):

```rust
fn limit_step(dx: &mut [f64], max_voltage_step: f64) {
    for v in dx.iter_mut() {
        if *v > max_voltage_step { *v = max_voltage_step; }
        else if *v < -max_voltage_step { *v = -max_voltage_step; }
    }
}
```

### 3.5 Levenberg-Marquardt Regularization

`regularize_weak_diagonals` adds a floor conductance (1e-9 S) to node diagonals weaker than the floor. This is **Jacobian-only** (Levenberg-Marquardt style) — the residual is NOT modified — preserving the correct convergence target while preventing singular pivots.

---

# Part II: Device Models

## 4. Diode Model

### 4.1 DC Model (Shockley Equation)

$$I_D = I_{s,eff} \cdot \left( \exp\left(\frac{V_D}{N \cdot V_t}\right) - 1 \right) + I_{sr,eff} \cdot \left( \exp\left(\frac{V_D}{N_r \cdot V_t}\right) - 1 \right)$$

With optional Zener breakdown for $V_D < -BV$:

$$I_{bd} = -I_{BV} \cdot \exp\left(-\frac{V_D + BV}{N \cdot V_t}\right)$$

Where:
- $V_t = \frac{k_B T}{q} \approx 25.85$ mV at 300 K
- $I_S$ = saturation current (default 1e-14 A)

### 4.2 Temperature Scaling

$$I_s(T) = I_s(T_{nom}) \cdot \left(\frac{T}{T_{nom}}\right)^{XTI/N} \cdot \exp\left(\frac{E_g}{N} \cdot \frac{T/T_{nom} - 1}{V_t(T)}\right)$$

### 4.3 Junction Capacitance

For $V \le FC \cdot V_j$:
$$C_j = C_{j0} \cdot (1 - V/V_j)^{-M_j}$$

For $V > FC \cdot V_j$ (linearized):
$$C_j = C_{j0} \cdot \left(F_2 + \frac{F_3}{V_j} \cdot V\right)$$

where:
$$F_2 = (1-FC)^{-(1+M_j)} \cdot (1 - FC(1+M_j))$$
$$F_3 = (1-FC)^{-(1+M_j)} \cdot M_j$$

### 4.4 Transit-Time Charge

$$Q_{TT} = T_T \cdot I_D$$
$$C_{TT} = \frac{\partial Q_{TT}}{\partial V} = T_T \cdot G_D$$

### 4.5 Jacobian (∂I/∂V)

Forward bias (Shockley):
$$G_D = \frac{I_S}{N \cdot V_t} \cdot \exp\left(\frac{V_D}{N \cdot V_t}\right) + G_{MIN}$$

Breakdown:
$$G_{bd} = \frac{I_{BV}}{N \cdot V_t} \cdot \exp\left(-\frac{V_D + BV}{N \cdot V_t}\right)$$

### 4.6 Key Parameters

| Parameter | Default | Units | Description |
|-----------|---------|-------|-------------|
| `is` | 1e-14 | A | Saturation current |
| `n` | 1.0 | - | Ideality factor |
| `bv` | ∞ | V | Reverse breakdown voltage |
| `ibv` | 1e-3 | A | Current at breakdown onset |
| `xti` | 3.0 | - | Is temperature exponent |
| `eg` | 1.11 | eV | Bandgap energy (Si) |
| `tt` | 0.0 | s | Transit time |
| `cj0` | 0.0 | F | Zero-bias junction capacitance |
| `vj` | 1.0 | V | Junction built-in potential |
| `mj` | 0.5 | - | Junction grading coefficient |
| `fc` | 0.5 | - | Forward-bias depletion cap limit |

---

## 5. BJT Models (Gummel-Poon & VBIC)

### 5.1 Gummel-Poon DC Model Equations

**Transport Currents:**
$$I_F = I_S \cdot \left(\exp\left(\frac{V_{BE}}{N_F \cdot V_t}\right) - 1\right)$$
$$I_R = I_S \cdot \left(\exp\left(\frac{V_{BC}}{N_R \cdot V_t}\right) - 1\right)$$

**Recombination Leakage:**
$$I_{BE,rec} = I_{SE} \cdot \left(\exp\left(\frac{V_{BE}}{N_E \cdot V_t}\right) - 1\right)$$
$$I_{BC,rec} = I_{SC} \cdot \left(\exp\left(\frac{V_{BC}}{N_C \cdot V_t}\right) - 1\right)$$

**Base Charge Factor (Webster effect + Early effect):**
$$q_1 = \frac{1}{1 - \frac{V_{BC}}{V_{AF}} - \frac{V_{BE}}{V_{AR}}}$$
$$q_2 = \frac{I_F}{I_{KF}} + \frac{I_R}{I_{KR}}$$
$$q_b = \frac{q_1}{2} \cdot \left(1 + \sqrt{1 + 4 \cdot q_2}\right)$$

**Terminal Currents:**
$$I_{CC} = \frac{I_F - I_R}{q_b}$$
$$I_{BE} = \frac{I_F}{F_B} + I_{BE,rec}$$
$$I_{BC} = \frac{I_R}{F_B} + I_{BC,rec}$$
$$I_C = I_{CC} - I_{BC}$$
$$I_B = I_{BE} + I_{BC}$$

### 5.2 VBIC Enhanced Model

VBIC (Vertical Bipolar Inter-Company) is a 4-terminal model with explicit substrate node. Key enhancements over Gummel-Poon:

**Extrinsic/Intrinsic Collector Resistance Split:**
- RCX = extrinsic collector resistance
- RCI = intrinsic collector resistance

**Avalanche Multiplication:**
$$I_C = I_{CC} \cdot (1 + \alpha \cdot M(V_{BC}))$$

**Transit Time Charges:**
$$Q_T = \tau_F \cdot I_F + \tau_R \cdot I_r + C_{je}(V_{BE}) \cdot V_{BE} + C_{jc}(V_{BC}) \cdot V_{BC}$$

### 5.3 AC Small-Signal (Charge Storage)

**Base-Emitter Charge:**
$$Q_{BE} = \tau_F \cdot I_F + C_{je}(V_{BE}) \cdot V_{BE}$$

**Base-Collector Charge:**
$$Q_{BC} = \tau_R \cdot I_R + C_{jc}(V_{BC}) \cdot V_{BC}$$

**Excess Phase (Cole's approximation):**
$$I_C(t) = I_{CC}(t) - \sum_{k=1}^{n} \frac{\alpha_k}{\tau_d^k} \cdot \frac{d^k I_{CC}}{dt^k}$$

### 5.4 Key BJT Parameters

| Parameter | Default | Units | Description |
|-----------|---------|-------|-------------|
| `is` | 1e-15 | A | Transport saturation current |
| `bf` | 100 | - | Forward beta |
| `br` | 1 | - | Reverse beta |
| `nf` | 1 | - | Forward ideality |
| `vaf` | ∞ | V | Forward Early voltage |
| `ikf` | ∞ | A | Forward knee current |
| `ise` | 0 | A | BE recombination saturation current |
| `cje` | 0 | F | BE depletion capacitance |
| `tf` | 0 | s | Forward transit time |
| `td` | 0 | s | Excess phase delay |

---

## 6. MOSFET Models (Level 1/2/3/6)

### 6.1 Level 1 (Shichman-Hodges)

**Pin Layout:** 0=Drain, 1=Gate, 2=Source, 3=Bulk

**Threshold Voltage with Body Effect:**
$$V_{th} = V_{TO} + \gamma \cdot (\sqrt{\phi + V_{SB}} - \sqrt{\phi})$$

where $V_{SB} = V_S - V_B$ (source-bulk voltage, positive when body is reverse-biased)

**Operating Regions:**

1. **Cutoff** ($V_{ov} \le 0$): $I_D = GDS_{MIN} \cdot V_{DS}$

2. **Linear/Triode** ($V_{DS} < V_{ov}$):
$$I_D = \beta \cdot \left(V_{ov} \cdot V_{DS} - \frac{V_{DS}^2}{2}\right) \cdot (1 + \lambda \cdot V_{DS})$$

3. **Saturation** ($V_{DS} \ge V_{ov}$):
$$I_D = \frac{\beta}{2} \cdot V_{ov}^2 \cdot (1 + \lambda \cdot V_{DS})$$

where $\beta = K_P \cdot \frac{W}{L}$ and $V_{ov} = V_{GS} - V_{th}$

### 6.2 Level 2 (Grove-Frohman)

Adds body effect via the same $V_{th}$ formula as Level 1. Otherwise identical to Level 1.

### 6.3 Level 3 (Empirical)

Adds:
- **DIBL (Drain-Induced Barrier Lowering):** $V_{th} = V_{th,long} - \eta \cdot V_{DS}$
- **Mobility degradation:** $\beta = \frac{\beta_0}{1 + \theta \cdot V_{ov}}$
- **Saturation voltage with kappa:** $V_{DSAT} = \frac{V_{ov}}{1 + \kappa \cdot V_{ov}}$
- **Narrow-width effect:** $\gamma_W = \gamma + \delta \cdot \frac{\pi \cdot 3.9 \cdot 10^{-11}}{4 W \sqrt{\phi + V_{SB}}}$

### 6.4 Level 6 (Sakurai-Newton Power Law)

$$I_D = \frac{W}{L} \cdot K_O \cdot V_{ov}^{m_k} \cdot \tanh\left(\frac{V_{DS}}{V_{ov}}\right) \cdot (1 + \lambda \cdot V_{DS})$$

### 6.5 Source-Drain Swap Handling

When $V_{DS} < 0$, standard SPICE swaps D and S internally:
- $V_{GS}' = V_{GD}$ (gate-to-drain)
- $V_{DS}' = -V_{DS}$
- $V_{BS}' = V_{BD}$

After evaluation, current is negated and Jacobian columns for D/S are swapped.

### 6.6 Meyer Gate Capacitances (Level 1)

Computed when `TOX` is specified:

$$C_{OX} = \frac{\epsilon_{ox}}{TOX} \cdot W \cdot L_{eff}$$

**Saturation:**
$$C_{GS} = \frac{2}{3} \cdot C_{OX} \cdot \left(1 - \left(\frac{V_{DS}-V_{DSAT}}{2 V_{ov}}\right)^2\right)$$

**Triode:**
$$C_{GS} = C_{OX} / 2, \quad C_{GD} = C_{OX} / 2$$

### 6.7 Transconductances (Jacobian Derivatives)

$$g_m = \frac{\partial I_D}{\partial V_{GS}} = \begin{cases} \beta \cdot V_{DS} \cdot (1 + \lambda V_{DS}) & \text{linear} \\ \beta \cdot V_{ov} \cdot (1 + \lambda V_{DS}) & \text{saturation} \end{cases}$$

$$g_{ds} = \frac{\partial I_D}{\partial V_{DS}} = \begin{cases} \beta \cdot (V_{ov} - V_{DS}) \cdot (1 + \lambda V_{DS}) + \beta \cdot (V_{ov} V_{DS} - V_{DS}^2/2) \cdot \lambda & \text{linear} \\ \frac{\beta}{2} \cdot V_{ov}^2 \cdot \lambda & \text{saturation} \end{cases}$$

$$g_{mb} = g_m \cdot \frac{\gamma}{2 \sqrt{\phi + V_{SB}}}$$

---

## 7. BSIM3 MOSFET Model

### 7.1 Threshold Voltage

$$V_{th} = V_{th0} + K_{1ox} \cdot (\sqrt{\phi - V_{bseff}} - \sqrt{\phi}) - K_{2ox} \cdot V_{bseff}$$

Plus corrections for:
- **Short-channel SCE:** $-dvt0 \cdot \exp(-dvt1 \cdot L / lt_0) \cdot (V_{bi} - \phi)$
- **Narrow-width:** $(k3 + k3b \cdot V_{bseff}) \cdot \frac{Tox}{W + W_0} \cdot \phi$
- **DIBL:** $-\theta_{Rout} \cdot (\eta_0 + \eta_b \cdot V_{bseff}) \cdot V_{DS}$

### 7.2 Subthreshold Smoothing

$$V_{gsteff} = n \cdot V_t \cdot \ln\left(1 + \exp\left(\frac{V_{GS} - V_{th} - V_{off}}{n \cdot V_t}\right)\right)$$

### 7.3 Mobility

$$\mu_{eff} = \frac{\mu_0}{1 + (U_a + U_c \cdot V_{bseff}) \cdot E_{eff} + U_b \cdot E_{eff}^2}$$

where $E_{eff} = \frac{V_{gsteff} + 2 V_{th}}{Tox}$

### 7.4 Saturation Voltage

$$V_{DSAT} = \frac{E_{sat} \cdot L \cdot (V_{gsteff} + 2 V_t)}{A_{bulk} \cdot E_{sat} \cdot L + V_{gsteff} + 2 V_t}$$

with bulk charge factor:
$$A_{bulk} = 1 + \frac{K_{1ox}}{2\sqrt{\phi}} \cdot \left(\frac{A_0 \cdot L_{eff}}{L_{eff} + 2\sqrt{X_j \cdot X_{dep}}} + \frac{B_0}{W + B_1}\right) \cdot (1 - A_{gs} \cdot V_{gsteff}) \cdot (1 + K_{eta} \cdot V_{bseff})$$

### 7.5 Drain Current

$$I_{DS} = \mu_{eff} \cdot C_{ox} \cdot \frac{W}{L} \cdot V_{gsteff} \cdot \left(1 - \frac{A_{bulk} \cdot V_{dseff}}{2(V_{gsteff} + 2 V_t)}\right) \cdot \frac{V_{dseff}}{1 + V_{dseff} / (E_{sat} \cdot L)}$$

with channel-length modulation:
$$I_{DS} = I_{DS} \cdot \left(1 + \frac{V_{DS} - V_{dseff}}{P_{clm} \cdot E_{sat} \cdot L}\right)$$

### 7.6 Substrate Current (Impact Ionization)

$$I_{sub} = \frac{\alpha_0 + \alpha_1 \cdot L_{eff}}{L_{eff}} \cdot (V_{DS} - V_{dseff}) \cdot \exp\left(-\frac{\beta_0}{V_{DS} - V_{dseff}}\right) \cdot I_{DS}$$

### 7.7 Key BSIM3 Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `vth0` | 0.7 | Zero-Vbs threshold |
| `k1` | 0.5 | Body effect coefficient |
| `u0` | 0.067 (NMOS) | Low-field mobility |
| `ua` | 2.25e-9 | Mobility degradation |
| `vsat` | 8e4 | Saturation velocity |
| `tox` | 1.5e-8 | Oxide thickness |
| `pclm` | 1.3 | CLM coefficient |
| `drout` | 0.56 | DIBL coefficient |

---

## 8. BSIM4 MOSFET Model

### 8.1 Threshold Voltage

Same long-channel formula as BSIM3, with enhanced short-channel rolloff and DIBL:

$$V_{th} = V_{th0} + K_{1ox}(\sqrt{\phi - V_{bseff}} - \sqrt{\phi}) - K_{2ox} \cdot V_{bseff} - SCE + NW - DIBL$$

### 8.2 Vgsteff Smoothing

$$V_{gsteff} = n \cdot V_t \cdot \ln\left(1 + \exp\left(\frac{V_{gst} - V_{off}}{n \cdot V_t}\right)\right)$$

### 8.3 Mobility

Enhanced mobility model (mobMod 0/1/2):

$$\mu_{eff} = \frac{\mu_0}{1 + (U_a + U_c \cdot V_{bseff}) \cdot E_{eff} + U_b \cdot E_{eff}^2}$$

### 8.4 Drain Current

$$I_{DS} = \beta \cdot V_{gsteff} \cdot V_{dseff} \cdot \left(1 - \frac{A_{bulk} \cdot V_{dseff}}{2(V_{gsteff} + 2V_t)}\right) \cdot \frac{1}{1 + V_{dseff} / (E_{sat} \cdot L)}$$

with CLM, DIBL, and SCBE multipliers applied.

### 8.5 GIDL/GISL Leakage

$$I_{GIDL} = A_{gidl} \cdot W_{diod} \cdot \frac{V_{DS} - V_{GS} - E_{gidl}}{3 \cdot T_{oxe}} \cdot \exp\left(-3 \cdot T_{oxe} \cdot \frac{B_{gidl}}{V_{DS} - V_{GS} - E_{gidl}}\right)$$

### 8.6 Charge Partitioning (Ward-Dutton)

In saturation:
$$C_{gg} = C_{inv}$$
$$C_{gs} = -\frac{2}{3} \cdot C_{inv} \cdot \left(1 - \left(\frac{V_{gsteff}}{2(V_{gsteff} + 2V_t) - V_{DSAT}}\right)^2\right)$$
$$C_{gd} = 0$$
$$C_{gb} = 0$$

Drain charge gets 40% partition.

### 8.7 Key BSIM4 Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `vth0` | 0.7 | Zero-Vbs threshold |
| `k1` | 0.53 | First-order body effect |
| `u0` | 0.067 | Low-field mobility |
| `toxe` | 3e-9 | Electrical oxide thickness |
| `rdsw` | 200 | S/D parasitic resistance |
| `pclm` | 1.3 | CLM coefficient |
| `agidl` | 0 | GIDL coefficient |
| `bgidl` | 2.3e9 | GIDL exponential factor |

---

## 9. JFET and MESFET Models

### 9.1 Level 1 JFET (Shichman-Hodges)

**Regions:**

1. **Cutoff** ($V_{GS} \le V_{TO}$): $I_D = GDS_{MIN} \cdot V_{DS}$

2. **Triode** ($0 \le V_{DS} < V_{GS} - V_{TO}$):
$$I_D = \beta \cdot (2(V_{GS} - V_{TO}) V_{DS} - V_{DS}^2) \cdot (1 + \lambda V_{DS})$$

3. **Saturation** ($V_{DS} \ge V_{GS} - V_{TO}$):
$$I_D = \beta \cdot (V_{GS} - V_{TO})^2 \cdot (1 + \lambda V_{DS})$$

### 9.2 Level 2 JFET (Parker-Skellern)

Smooth hyperbolic model eliminating abrupt region transitions:

$$V_{ST} = \frac{V_{ov}}{1 + \delta \cdot V_{ov}} \quad \text{(smooth saturation voltage)}$$

$$V_{eff} = V_{DS} - \frac{1}{n_{ds}} \ln\left(1 + \exp(n_{ds}(V_{DS} - V_{ST}))\right) \quad \text{(smooth clamp)}$$

$$I_D = \beta \cdot V_{eff}^2 \cdot (1 + \lambda V_{DS}) \cdot \frac{1 - \exp(-n_{ds} V_{DS})}{n_{ds}} \cdot \frac{1}{1 + HFETA \cdot V_{GS}}$$

### 9.3 MESFET (Curtice)

$$I_{DS} = BETA \cdot (V_{gs} - V_{TO})^2 \cdot (1 + LAMBDA \cdot V_{ds}) \cdot \tanh(ALPHA \cdot V_{ds})$$

---

# Part III: Analysis Engines

## 10. DC Operating Point Analysis

### 10.1 Mathematical Formulation

DC OP solves the nonlinear circuit equations at a single bias point (all frequency-dependent terms vanish):

$$F(x) = G(x) + I_{src} = 0$$

where:
- $x$ = node voltages (MNA unknowns)
- $G(x)$ = nonlinear device currents evaluated at $x$
- $I_{src}$ = independent source contributions

The Jacobian is:
$$J_{ij} = \frac{\partial F_i}{\partial x_j} = G_{ij} = \frac{\partial I_i}{\partial x_j}$$

### 10.2 Algorithm

```
1. Clone circuit, propagate .TEMP / .OPTIONS TEMP to devices
2. Solver::solve(circuit, registry, warm_start=None)
   a. Build initial guess via topology-aware logic
   b. Newton-Raphson loop
      - stamp_circuit_gc_at_time: build residual + Jacobian at x
      - J · Δx = −F(x)
      - x ← x + Δx (with damping)
      - Convergence check: ||F||∞ < abstol AND max|Δx| < vntol
   c. Handle non-convergence: fallback through homotopy strategies
      (gmin stepping → source stepping → pseudo-transient → Anderson acceleration)
3. Extract node voltages and branch currents from solution vector
```

### 10.3 .IC Pinning

For `.TRAN UIC`-free runs, nodes are held at initial voltages during DC OP via a **stiff conductance** (large $G_{IC}$), then released for transient.

---

## 11. DC Sweep Analysis

### 11.1 Algorithm

```
for val in start → stop (step):
    ckt.set_device_param(source_name, "dc", val)
    result = Solver::solve(circuit, registry, prev_solution.as_deref())
    record val, node_voltages
    prev_solution = result.solution
```

### 11.2 Nested DC Sweep with Bisection

When NR fails at a sweep point:
1. Between last good point $V_{i-1}$ and target $V_i$, try midpoint
2. Up to 3 bisection iterations
3. Final fallback: cold-start
4. If all fail: warn, reuse last good solution

---

## 12. Transient Analysis

### 12.1 Mathematical Formulation

The circuit DAEs are:

$$q'(x, t) + g(x, t) = 0$$

where $q$ = reactive (capacitor/inductor) charges, $g$ = resistive currents.

Discretized with a BDF-$k$ method at timestep $h$:

$$\sum_{j=0}^{k} \alpha_j \, q(x_{n-j}) + g(x_n) = 0$$

Rearranged for Newton residual:

$$F(x_n) = g(x_n) + \alpha_0 \, q(x_n) + \sum_{j=1}^{k} c_j \, q(x_{n-j}) = 0$$

### 12.2 Adaptive Timestep (LTE-Based)

**Richardson Extrapolation**: The difference between BDF-1 (BE) and BDF-2 (Gear-2/Trap) solutions is an $O(h^2)$ estimate of the local truncation error.

$$\text{LTE}[i] = \frac{|x_{ord2}[i] - x_{BE}[i]|}{\text{TRTOL} \cdot (\text{reltol} \cdot |x_{ord2}[i]| + \text{abstol})}$$

With `TRTOL = 7.0` (ngspice default), step is **accepted** if `ratio < 1.0`, rejected otherwise.

**Predictor** (for next step):

$$h_{new} = \text{clamp}\left(0.9 \cdot h \cdot \text{ratio}^{-1/3}, \; h_{min}, \; t_{max}\right)$$

### 12.3 Bootstrap Order

Gear methods need $k-1$ historical charge vectors. The first steps bootstrap:

| Steps done | Gear-2 | Gear-3 | Gear-4 | Gear-5 |
|---|---|---|---|---|
| 0 | BE | BE | BE | BE |
| 1 | Gear-2 | Gear-2 | Gear-2 | Gear-2 |
| 2 | Gear-2 | Gear-3 | Gear-3 | Gear-3 |
| 3 | Gear-2 | Gear-3 | Gear-4 | Gear-4 |
| 4+ | Gear-2 | Gear-3 | Gear-5 | Gear-5 |

---

## 13. Time Integration Methods (BDF/Gear/Trapezoidal)

### 13.1 BDF Coefficients Table

The standard BDF-$k$ form:
$$\sum_{j=0}^{k} \alpha_j \, x_{n-j} = h \, \beta_0 \, f_n$$

Rearranged for residual form (with $q$ as reactive charge):

$$F = g(x_n) + \frac{\alpha_0}{h \beta_0} \cdot q(x_n) - \sum_{j=1}^{k} \frac{\alpha_j}{h \beta_0} \cdot q(x_{n-j})$$

| Order | Method | $\alpha = \alpha_0/(h\beta_0)$ | History coeffs (newest→oldest) |
|---|---|---|---|
| 1 | Backward Euler | $1/h$ | $-1/h$ |
| 2 | Gear (BDF-2) | $3/(2h)$ | $-\frac{4}{3}\alpha$, $+\frac{1}{3}\alpha$ |
| 3 | Gear (BDF-3) | $11/(6h)$ | $-\frac{18}{11}\alpha$, $+\frac{9}{11}\alpha$, $-\frac{2}{11}\alpha$ |
| 4 | Gear (BDF-4) | $25/(12h)$ | $-\frac{48}{25}\alpha$, $+\frac{36}{25}\alpha$, $-\frac{16}{25}\alpha$, $+\frac{3}{25}\alpha$ |
| 5 | Gear (BDF-5) | $137/(60h)$ | $-\frac{300}{137}\alpha$, $+\frac{300}{137}\alpha$, $-\frac{200}{137}\alpha$, $+\frac{75}{137}\alpha$, $-\frac{12}{137}\alpha$ |

### 13.2 Trapezoidal (Gear-1 with history averaging)

$$F = g(x_n) + g(x_{n-1}) + \frac{2}{h}(q(x_n) - q(x_{n-1}))$$

Note: $\alpha = 2/h$ (not $1/h$ as in BE). The `g_prev` (resistive residual at previous step) is needed.

### 13.3 Jacobian Structure

For all methods, the Jacobian is:

$$J = G + \alpha \cdot C$$

where $G = \partial g/\partial x$ and $C = \partial q/\partial x$ (capacitance matrix — constant for linear elements).

---

## 14. AC Small-Signal Analysis

### 14.1 Mathematical Formulation

Linearized at DC OP: $G + sC$ where $G$ =conductance Jacobian, $C$ = capacitance Jacobian.

At frequency $\omega$ ($s = j\omega$):

$$(G + j\omega C) \cdot V(\omega) = I_{src}(\omega)$$

### 14.2 Block Matrix Formulation (Real Arithmetic)

The complex $N \times N$ system is converted to a real $2N \times 2N$ block:

$$\begin{bmatrix} G & -\omega C \\ \omega C & G \end{bmatrix} \begin{bmatrix} V_{re} \\ V_{im} \end{bmatrix} = \begin{bmatrix} I_{re} \\ I_{im} \end{bmatrix}$$

### 14.3 Algorithm

```
1. DC OP solve → dc.solution (bias point)
2. stamp_circuit_gc_into(circuit, dc_solution, …) → G_triplet, C_triplet
3. For each frequency f:
     ω = 2πf
     Build block matrix:
       block[r,c]      += G[r,c]      (top-left)
       block[r,c+N]    += -ω*C[r,c]   (top-right)
       block[r+N,c]    +=  ω*C[r,c]   (bottom-left)
       block[r+N,c+N]  +=  G[r,c]     (bottom-right)
     Build RHS from AcStimulus list
     SparseLU → solve
     Extract magnitude = sqrt(V_re² + V_im²), phase = atan2(V_im, V_re)
```

---

## 15. Noise Analysis

### 15.1 Physical Noise Models

| Device | Noise Type | PSD Formula |
|---|---|---|
| Resistor | Thermal (Johnson-Nyquist) | $S_I = \frac{4kT}{R}$ [A²/Hz] |
| Diode | Shot | $S_I = 2qI_D$ [A²/Hz] |
| BJT | Shot (Ic + Ib) + Flicker | $S_I = 2q(I_C + I_B) + \frac{K_f I_B^{A_f}}{f}$ |
| MOSFET | Thermal + Flicker | $S_I = \frac{8}{3}kT \cdot g_m + \frac{K_f I_D^{A_f}}{C_{ox}L^2 f}$ |

### 15.2 Algorithm

```
1. DC OP → bias point (dc_solution)
2. Build G, C at OP (stamp_circuit_gc_into)
3. For each frequency f:
     Build Y(jω) = G + jωC as 2N×2N block matrix
     Factorize once (SparseLU)

     # Compute |H(f)|² (transfer from input source to output)
     RHS = unit stimulus at input source branch
     H_sol = lin.solve(RHS)
     |H|² = H_re² + H_im²

     For each noisy device:
         Inject unit noise current at device terminals
         Solve for V_out
         |V_out|² = V_re² + V_im²
         Contribution = |V_out|² × S_device(f)
         Accumulate to total output noise
4. Input-referred = Output / |H|²
```

---

## 16. Harmonic Balance

### 16.1 Mathematical Formulation

For a periodic steady-state with fundamental $f_0$ and $K$ harmonics:

$$F(V) = Y_{lin}(j\omega) \cdot V + I_{NL}(V) - I_{src} = 0$$

Where:
- $V$ = vector of complex Fourier coefficients $[V_0, V_1, V_{-1}, ..., V_K, V_{-K}]$
- $Y_{lin}(j\omega)$ = diagonal matrix of linear admittances at each harmonic: $Y_h = G + j\omega_h C$
- $I_{NL}(V)$ = nonlinear branch currents in frequency domain (IDFT → evaluate devices → DFT)
- $I_{src}$ = source current phasors

### 16.2 Single-Tone HB Algorithm

```
1. N = 2K + 1 time samples per period (Nyquist limit for K harmonics)
2. Build DFT matrix W[k,n] = exp(-j2πkn/N)
3. Initial guess: DC operating point
4. Newton loop:
     # Time domain:
     v_td = IDFT(V)          # N real time samples
     i_nl_td = eval_nonlinear_devices(v_td)  # time-domain currents
     i_nl_fd = DFT(i_nl_td)  # back to frequency domain

     # Frequency domain residual:
     F(V)_h = (G + jω_h C)·V_h + i_nl_fd,h - I_src,h

     # Jacobian via forward AD:
     ∂i_nl_fd/∂V = (∂i_nl_td/∂v_td) · ∂v_td/∂V = diag(g_j) · W/N

     J = Y_diagonal + DFT_diag(g)
     ΔV = solve(J, -F(V))
     V = V + ΔV
     if ||ΔV|| < tol: converged
```

---

## 17. Periodic Steady-State (Shooting)

### 17.1 Mathematical Formulation

Shooting seeks $x_0$ such that after one period $T = 1/f_{fund}$:

$$F(x_0) = x(T; x_0) - x_0 = 0$$

i.e., the state after one period equals the initial state (periodic boundary condition).

### 17.2 Algorithm

```
1. DC OP → initial guess x₀
2. Newton loop on shooting residual:
   for it = 0..max_iter:
     # (a) Shoot: integrate one period from x₀
     inject_ic(x₀)
     tran = run_transient(circuit, UIC, tstop=T, tstep=T/(2K+1))
     x_T = extract_final_state(tran)

     # (b) Residual: F = x(T) - x₀
     F = x_T - x₀
     if ||F||∞ < tol: converged

     # (c) Monodromy matrix Φ = ∂x(T)/∂x₀ via finite differences
     for j = 0..n_state-1:
       x₀_pert = x₀; x₀_pert[j] += ε
       inject_ic(x₀_pert)
       tran_j = run_transient(...)
       x_T_j = extract_final_state(tran_j)
       Φ[:,j] = (x_T_j - x_T) / ε

     # (d) Jacobian: J = Φ - I
     Δx₀ = solve(J, -F)
     x₀ = x₀ + Δx₀
```

### 17.3 Monodromy Matrix

The monodromy matrix $\Phi = \partial x(T)/\partial x_0$ maps initial state perturbations to final state perturbations. Computed via **finite differences**:

$$\Phi_{ij} = \frac{x_i(T; x_0 + \epsilon \cdot e_j) - x_i(T; x_0)}{\epsilon}$$

---

## 18. Fourier Analysis

### 18.1 .FOUR Algorithm (Branin's Direct DFT)

```
1. Extract waveform for node_index from TransientResult
2. Find last complete period: t_start = t_end - T, T = 1/freq
3. Resample uniformly onto N=1024 (or longer) uniform grid over [t_start, t_end]
4. Compute DC: a₀ = (1/N) Σ v[n]
5. For each harmonic k = 1..9:
     a_k = (2/N) Σ v[n] · cos(2πkn/N)
     b_k = (2/N) Σ v[n] · sin(2πkn/N)
     mag_k = sqrt(a_k² + b_k²)
     phase_k = atan2(b_k, a_k) [degrees]
6. THD = sqrt(Σ mag_k² for k≥2) / mag_1 × 100%
```

Returns **THD as percentage**: $\text{THD} = \frac{\sqrt{\sum_{k=2}^{N_h} |V_k|^2}}{|V_1|} \times 100\%$

---

## 19. Transfer Function & Sensitivity

### 19.1 Transfer Function Algorithm

```
1. DC OP → G (at ω=0, C matrix discarded)
2. Factor G once (SparseLU)
3. Gain: RHS = unit source at input branch row
   V = solve(G, RHS)
   gain = V[out_node] - V[ref_node]
4. Input Z: Zin = -1 / (dI_branch/dV_in)
5. Output Z: RHS = unit current at out node
   V_z = solve(G, RHS)
   Zout = V_z[out_node] - V_z[ref_node]
```

### 19.2 DC Sensitivity (Forward Finite Differences)

```
For each parameter p:
    h = max(1e-8, 1e-3 * |p₀|)   # perturbation
    V₀ = DC_OP(circuit)           # baseline
    V₊ = DC_OP(circuit with p ← p₀ + h)
    output₊ = extract_output(V₊)
    output₀ = extract_output(V₀)
    absolute = (output₊ - output₀) / h
    relative = (p₀ / output₀) * absolute   # if |output₀| > 1e-20
```

---

## 20. Pole-Zero Analysis

### 20.1 Mathematical Formulation

The linearized circuit state-space at DC OP:

$$(G + sC) \cdot x = b$$

Poles are eigenvalues $s$ where $\det(G + sC) = 0$, i.e.:

$$G \cdot x = -s C \cdot x \iff (-C^{-1} G) \cdot x = s \cdot x$$

### 20.2 Algorithm

```
1. DC OP → G, C at bias point
2. Tikhonov regularisation: C ← C + εI (ε = 1e-18 F) to handle singular C
3. Solve C · X = -G  →  X = -C⁻¹ · G   [LU factorisation]
4. Compute eigenvalues of X via QR iteration on Hessenberg form
5. Return eigenvalues as poles (complex s = σ + jω)
```

---

## 21. Distortion Analysis

### 21.1 Volterra-Series Formulation

For a nonlinear element with Taylor expansion $i = a_1 v + a_2 v^2 + a_3 v^3 + \cdots$:

$$H_2(f_1, f_2) = |a_2| \cdot |H(f_1)| \cdot |H(f_2)| \cdot |H(f_1 + f_2)|$$
$$H_3(f_1, f_2, f_3) = |a_3| \cdot |H(f_1)| \cdot |H(f_2)| \cdot |H(f_3)| \cdot |H(f_1 + f_2 + f_3)|$$

### 21.2 Harmonic Distortion (Single Tone)

| Type | Formula |
|---|---|
| HD2 | $\frac{|a_2| \cdot |H(f_1)|^2 \cdot |H(2f_1)|}{|H(f_1)|}$ |
| HD3 | $\frac{|a_3| \cdot |H(f_1)|^3 \cdot |H(3f_1)|}{|H(f_1)|}$ |

---

## 22. S-Parameter Analysis

### 22.1 Wave Variable Definition (IEEE Std 1597)

$$a_i = \frac{V_i + R_i \cdot I_i}{2\sqrt{R_i}}$$ (incident wave)
$$b_i = \frac{V_i - R_i \cdot I_i}{2\sqrt{R_i}}$$ (reflected wave)
$$S_{ij} = \frac{b_i}{a_j}\bigg|_{a_k=0 \text{ for } k \neq j}$$

### 22.2 Algorithm

```
For each frequency f:
    Build Y(jω) = G + jωC as 2N×2N block matrix

    For each driven port p (0..N_ports-1):
        Build termination conductances for all OTHER ports q ≠ p:
            G_q = 1/R_q added to diagonal entries of port q nodes

        Inject unit current (1 A real) at port p nodes
        Solve Y · V = I
        Compute a_p, b_i for all ports i
        S_ip = b_i / a_p
```

---

# Part IV: Solver & Linear Algebra

## 23. Sparse Matrix Implementation

### 23.1 CSC (Compressed Sparse Column) Format

`CscMatrix` stores the matrix as three arrays:

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

### 23.2 TripletMatrix → CscMatrix Conversion

`TripletMatrix` is the mutable "assembly" format used during stamping. `to_csc()` converts:

1. Count entries per column
2. Build `col_ptr` via prefix sum
3. Scatter entries into position arrays
4. Sort each column by row index (insertion sort)
5. **Compress duplicates:** sum values for duplicate entries

---

## 24. LU Factorization (BTF+AMD+Gilbert-Peierls)

### 24.1 Factorization Pipeline

```
A → BTF decomposition → AMD ordering → Gilbert-Peierls sparse LU
```

### 24.2 BTF (Block Triangular Form)

Finds a permutation $P, Q$ such that $P A Q^T$ is block upper-triangular:

1. **Bipartite matching** (maximum transversal via augmenting-path DFS)
2. **Tarjan SCC** on the column dependency graph
3. Compose row/column permutations to place SCCs on the diagonal

### 24.3 AMD (Approximate Minimum Degree)

Computes a fill-reducing column ordering within each BTF block.

### 24.4 Gilbert-Peierls LU

Left-looking sparse LU with partial pivoting:
- Time proportional to $O(\text{flops} + \text{nnz}(L) + \text{nnz}(U))$
- Partial pivoting for numerical stability
- Workspace reuse across columns

For column $k$ of $A$:
1. **Symbolic:** DFS over $L^T$ graph to determine the non-zero pattern of $L(:, k)$ and $U(:, k)$
2. **Scatter:** $x = A(:, k)$ into dense work vector
3. **Numeric:** For each row $j < k$ in topological order: $x[i] -= L[i,j] \cdot x[j]$
4. **Pivot:** Find $\max|x_i|$ among unpivoted rows, swap into position $k$
5. **Emit:** $U(:, k)$ entries and $L(:, k)$ entries

Both $L$ and $U$ are stored as CSC:
- **L**: diagonal (value 1.0) is the **first** entry of each column
- **U**: diagonal is the **last** entry of each column

---

## 25. Convergence & Damping Strategies

### 25.1 GMIN Stepping

Adds a small conductance $G_{\text{min}}$ from every node to ground, improving Jacobian conditioning:

$$G_{\text{min},k} = \frac{G_{\text{init}}}{\text{reduction\_factor}^k}, \quad G_{\text{init}} = 10^{-2}, \text{ reduction\_factor} = 3.1623 \;(=\sqrt{10})$$

The factor of $\sqrt{10}$ per step (half-decade) was chosen to avoid the abrupt transition when GMIN-dominated behavior gives way to device-dominated behavior.

### 25.2 Source Stepping

Ramps independent source values from 0 to full over a graduated sequence:

$$\text{steps} = [0.001, 0.01, 0.05, 0.1, 0.2, 0.3, 0.5, 0.7, 0.9, 1.0]$$

### 25.3 Anderson Acceleration

Given window size $m$:

1. Build $\Delta F = [f_{k-m_k} - f_{k-m_k+1} | \cdots | f_{k-1} - f_{k-2}]$
2. Build $\Delta X = [x_{k-m_k} - x_{k-m_k+1} | \cdots | x_{k-1} - x_{k-2}]$
3. Solve $\gamma^* = \arg\min_\gamma \|\Delta F \cdot \gamma - f_k\|_2$
4. $x_{k+1} = x_k + \beta \cdot f_k - (\Delta X + \beta \cdot \Delta F) \cdot \gamma^*$

---

## 26. GMIN/Source Stepping & Pseudo-Transient

### 26.1 Pseudo-Transient Continuation (PTC)

Last-resort fallback when NR + GMIN + source stepping all fail. Transforms the algebraic system into a stiff ODE:

$$F(x) + \frac{C}{\Delta t} \cdot (x - x_{\text{prev}}) = 0$$

The Jacobian becomes $J + \frac{C}{\Delta t} \cdot I$ (well-conditioned for large $C/\Delta t$). The algorithm:

1. Start with large stamp value ($C/\Delta t \approx 1$ F/s)
2. Run inner Newton iterations until modified residual is small
3. Check **true residual** — if both modified and true residual are below tolerance, DC OP is found
4. Reduce stamp value by `dt_growth` factor (default 2×) and repeat

---

# Part V: Netlist & Parser

## 27. Netlist Format Reference

### 27.1 Basic Structure

```
<title line — always consumed, even if blank>
* comments start with *
<element lines>
<dot directives>
.END
```

Line continuation: `+` at the start of a line joins it to the preceding line.

### 27.2 Model Card

```
.MODEL  mname  type  [(param=val ...)]
```

Recognized types: R/RES, C/CAP, D, NPN/PNP, NMOS/PMOS, NJF/PJF, NMF/PMF, SW, CSW, LTRA, URC

### 27.3 Subcircuits

```
.SUBCKT  name  port1  port2  ...  [param=default ...]
* element lines
* nested .SUBCKT / .ENDS allowed
.ENDS  [name]
```

Instantiation:
```
Xname  node1  node2  ...  subckt_name  [param=val ...]
```

### 27.4 Analysis Directives

| Directive | Description |
|-----------|-------------|
| `.OP` | DC Operating Point |
| `.DC` | DC Sweep |
| `.AC` | AC Sweep |
| `.TRAN` | Transient |
| `.HB` | Harmonic Balance |
| `.PSS` | Periodic Steady State |
| `.NOISE` | Noise Analysis |
| `.DISTO` | Distortion |
| `.SP` | S-Parameter |
| `.PZ` | Pole-Zero |
| `.TF` | Transfer Function |
| `.SENS` | Sensitivity |
| `.FOUR` | Fourier |
| `.STEP` | Parameter Sweep |

---

## 28. Expression Syntax

### 28.1 Operators

| Operator | Description | Precedence |
|----------|-------------|------------|
| `**`, `^` | Power | highest |
| unary `-` | Negation | |
| `*`, `/` | Multiply, divide | |
| `+`, `-` | Add, subtract | |
| `<`, `>`, `<=`, `>=` | Comparisons | |
| `==`, `!=` | Equality | |
| `&&` | Logical AND | lowest |
| `\|\|` | Logical OR | lowest |

Ternary: `cond ? val_true : val_false`

### 28.2 Built-in Functions

| Function | Description |
|----------|-------------|
| `abs(x)` | Absolute value |
| `sqrt(x)` | Square root |
| `exp(x)` | Exponential e^x |
| `log(x)` | Natural logarithm |
| `log10(x)` | Base-10 logarithm |
| `sin(x)`, `cos(x)`, `tan(x)` | Trigonometry (radians) |
| `asin(x)`, `acos(x)`, `atan(x)` | Inverse trig |
| `atan2(y,x)` | Two-argument inverse tangent |
| `sinh(x)`, `cosh(x)`, `tanh(x)` | Hyperbolic trig |
| `floor(x)`, `ceil(x)` | Rounding |
| `min(a,b)`, `max(a,b)` | Min/max |
| `pow(a,b)` | Power a^b |
| `if(c,t,f)` | Conditional |
| `V(n)` | Node voltage |
| `V(n1,n2)` | Differential voltage |
| `I(Vsrc)` | Branch current |

---

## 29. Waveform Sources

### 29.1 PULSE

```
PULSE(v1  v2  td  tr  tf  pw  per  [cycles])
```

| Param | Description |
|-------|-------------|
| v1 | Initial value |
| v2 | Pulsed value |
| td | Delay time |
| tr | Rise time |
| tf | Fall time |
| pw | Pulse width |
| per | Period |

### 29.2 SIN

```
SIN(vo  va  freq  [td  [theta  [phase]]])
```

$$v(t) = vo + va * \exp(-\theta * (t - td)) * \sin(2\pi * freq * (t - td) + phase)$$

### 29.3 EXP

```
EXP(v1  v2  td1  tau1  td2  tau2)
```

Double-exponential waveform.

### 29.4 PWL

```
PWL(t0 v0  t1 v1  t2 v2  ...)
PWL FILE="filename"  [R=offset]
```

Piecewise-linear waveform. Time-voltage pairs in ascending time order.

### 29.5 SFFM

```
SFFM(vo  va  fc  mdi  fs)
```

Single-frequency FM signal:
$$v(t) = vo + va * \sin(2\pi*fc*t + mdi * \sin(2\pi*fs*t))$$

### 29.6 AM

```
AM(vo  va  fc  fm  [td])
```

$$v(t) = va * (vo + \sin(2\pi*fm*(t-td))) * \sin(2\pi*fc*(t-td))$$

---

# Part VI: Advanced Topics

## 30. OSDI Interface (Verilog-A Models)

### 30.1 Architecture

The OSDI crate enables loading any device model compiled by OpenVAF into a `.osdi` shared object at runtime via `dlopen`.

```
bigospice CLI --dlopen--> bsim4.osdi (.so)
                             |
                  OsdiPlugin (Library handle + descriptor slice)
                             |
                  OsdiRegistry (descriptor name -> entry map)
                             |
                  OsdiInstance (per-device: Box<[u8]> handle + Arc<Library>)
                             |
                  OsdiTrampoline (SoaBuffers: voltage/residual/Jacobian columns)
                             |
                  BigOSpice stamper (maps node pairs to MNA matrix)
```

### 30.2 OSDI v0.3 ABI

The plugin exports four symbols validated on load:
- `OSDI_VERSION_MAJOR` / `OSDI_VERSION_MINOR` — version scalars
- `OSDI_NUM_DESCRIPTORS` — number of device descriptors
- `OSDI_DESCRIPTORS` — pointer to array of `OsdiDescriptor`

### 30.3 OsdiDescriptor Structure

```rust
pub struct OsdiDescriptor {
    pub name: *const c_char,
    pub num_terminals: u32,
    pub num_nodes: u32,
    pub nodes: *const OsdiNode,
    pub num_jacobian_entries: u32,
    pub jacobian_entries: *const OsdiNodePair,
    pub num_react_entries: u32,
    pub react_entries: *const OsdiNodePair,
    pub instance_size: u32,
    pub model_size: u32,
    pub num_params: u32,
    pub params: *const OsdiParamOpvar,
    pub num_opvars: u32,
    pub opvars: *const OsdiParamOpvar,
    // Function table
    pub setup_model: Option<OsdiSetupModelFn>,
    pub setup_instance: Option<OsdiSetupInstanceFn>,
    pub init_instance: Option<OsdiInitInstanceFn>,
    pub eval: Option<OsdiEvalFn>,
    pub load_residual_resist: Option<OsdiLoadResidualFn>,
    pub load_jacobian_resist: Option<OsdiLoadJacobianFn>,
    pub load_jacobian_react: Option<OsdiLoadJacobianReactFn>,
    // ... more function pointers
}
```

### 30.4 Hot-Path Trampoline

```
BigOSpice state --> write_voltages() --> OsdiSimInfo (paras.vals = voltages)
                                     --> eval(handle, &mut sim_info)
                                     --> load_residual_resist(handle, dst)
                                     --> load_jacobian_resist(handle, dst)
                                     --> load_jacobian_react(handle, dst, alpha)
```

---

## 31. Digital/XSPICE Simulation

### 31.1 12-State Logic Encoding

`DigState` packs a logic level and drive strength into a single `u8`:

```
bits 7..4 : strength (Strong=3, Weak=2, Resistive=1, HiZ=0)
bits 3..0 : level    (Zero=0, One=1, X=2, Z=3)
```

### 31.2 Digital Primitives

**Combinational (0–11):**
- `Buf`, `Not` — single input
- `And`, `Nand`, `Or`, `Nor`, `Xor`, `Xnor` — multi-input reduction
- `Mux2`, `Mux4` — 2:1 and 4:1 multiplexers
- `Demux2`, `Demux4` — 1:2 and 1:4 demultiplexers

**Sequential (12–13):**
- `DLatch` — level-sensitive D latch
- `DFlipFlop` — edge-triggered D flip-flop

**Sources (14–16):**
- `DPulse` — clock generator
- `DSource` — externally scheduled
- `DState` — user-supplied state machine

### 31.3 Analog/Digital Bridges

**AdcBridge** — analog → digital with hysteresis:
- `v >= in_high` → schedule `ONE` event
- `v <= in_low` → schedule `ZERO` event
- `in_low < v < in_high` → no change (hysteresis band)

**DacBridge** — digital → analog with linear ramps:
- `on_digital_event(t, new_state)` records the ramp start point and target
- `current_voltage(t)` computes the linear interpolation

---

## 32. Verilator Co-Simulation

### 32.1 Architecture

```
User's SystemVerilog --> verilator --cc --> libdesign.so
                                               |
                           VerilatorModel::load() via dlopen
                                               |
                           bigospice_cosim::DCosim (digital device)
                                               |
                           digital_event_runtime (event-driven sim)
```

### 32.2 Verilator Symbol Loading

Resolves five entry points from the `.so`:
- `bigospice_verilator_new` — constructor (returns opaque ctx handle)
- `bigospice_verilator_eval` — advance one combinational pass
- `bigospice_verilator_final` — terminate and free state
- `bigspice_verilator_set_signal` — drive input port by name
- `bigospice_verilator_get_signal` — read output port by name

---

## 33. GPU Acceleration

### 33.1 ComputeBackend Trait

```rust
pub trait ComputeBackend: Send + Sync {
    fn eval_batch(&self, voltages: &[f64], num_devices: usize,
                  num_terminals: usize, results: &mut [f64]);
    fn axpy(&self, alpha: f64, x: &[f64], y: &mut [f64]);
    fn dot(&self, x: &[f64], y: &[f64]) -> f64;
    fn norm_inf(&self, x: &[f64]) -> f64;
    fn scale(&self, alpha: f64, x: &mut [f64]);
    fn name(&self) -> &str;
}
```

### 33.2 GPU Backend — WGSL

`WgpuBackend` uses the **wgpu** crate (Rust wrapper over Vulkan/Metal/DX12) with four pipelines from `blas.wgsl`:

| Pipeline | Entry | Operation |
|---|---|---|
| `axpy_pipeline` | `axpy` | `x[i] += alpha * y[i]` |
| `scale_pipeline` | `scale` | `x[i] *= alpha` |
| `dot_pipeline` | `dot_partial` | partial sums for dot product |
| `norm_inf_pipeline` | `norm_inf_partial` | partial max for infinity norm |

### 33.3 BSIM4 Batch Evaluation

GPU kernel structure (`bsim4_eval.wgsl`):

```wgsl
@compute @workgroup_size(64)
fn bsim4_eval(@builtin(global_invocation_id) gid: vec3<u32>) {
    let idx = gid.x;
    if idx >= uniforms.n_devices { return; }

    let b = biases[idx];    // Bias { vgs, vds, vbs }
    let p = params[idx];    // Bsim4Params (37 fields)

    // Steps:
    // 1. compute_vth()     — threshold voltage + body effect + SCE + DIBL
    // 2. compute_vgsteff() — effective Vgs with subthreshold smoothing
    // 3. compute_mobility()— mu_eff with vertical field and Coulomb scattering
    // 4. compute_vdsat()  — velocity-saturation limited Vds
    // 5. compute_vdseff() — smooth min(Vds, Vdsat)
    // 6. Ids = beta0 * vgsteff * vdseff * bracket / denom * CLM
    // 7. Conductances: gm, gds, gmbs from derivative chain rule

    output[idx] = Bsim4Out { ids, gm, gds, gmbs };
}
```

---

## 34. Incremental Cache Architecture

### 34.1 Five Layers of Cache

**Layer 5.1: Topology Cache** — 64-bit FNV-1a digest of topology; skips symbolic LU when topology unchanged.

**Layer 5.2: Dirty Tracker** — BitVec per device+node; marks dirty via adjacency propagation.

**Layer 5.3: Compiled Eval Cache** — caches affine device models:
$$I(V) \approx I_0 + G \cdot (V - V_0)$$

Replay at new operating point if $|V - V_0|_\infty < \text{tolerance}$.

**Layer 5.4: Woodbury Rank-k Update** — Sherman-Morrison-Woodbury for low-rank matrix updates:
$$(J + U \cdot V^T)^{-1} = J^{-1} - J^{-1} \cdot U \cdot (I_k + V^T \cdot J^{-1} \cdot U)^{-1} \cdot V^T \cdot J^{-1}$$

**Layer 5.5: Transient Checkpoints** — periodic snapshots for rollback with `nearest_before(t)` binary search.

### 34.2 ParamChange Classification

```
Scaling     → resistance, capacitance, W, L, M, scale → analytically patched into affine model
Temperature → temp, tnom, tj → patch_temperature (Arrhenius ratio)
NonLinear   → everything else → invalidate compiled entry
```

---

# Appendices

## A. Device Model Parameters Reference

### Resistor

| Parameter | Default | Units | Description |
|-----------|---------|-------|-------------|
| `TC1` | 0 | 1/K | First-order temperature coefficient |
| `TC2` | 0 | 1/K² | Second-order temperature coefficient |
| `TNOM` | 27 | °C | Nominal temperature |

$$R(T) = R_0 \cdot [1 + TC1 \cdot (T - T_{nom}) + TC2 \cdot (T - T_{nom})^2]$$

### Capacitor

| Parameter | Default | Units | Description |
|-----------|---------|-------|-------------|
| `C` | 1 | - | Capacitance multiplier |
| `TC1` | 0 | 1/K | First-order TC |
| `TC2` | 0 | 1/K² | Second-order TC |

### Inductor

| Parameter | Default | Units | Description |
|-----------|---------|-------|-------------|
| Current initial condition | 0 | A | IC |

### Mutual Inductance (K)

Adds off-diagonal terms: $M = k \cdot \sqrt{L_1 \cdot L_2}$

---

## B. Analysis Types Summary

| Analysis | DC OP | Stamp G/C | Freq Sweep | NR Solve | Special |
|---|---|---|---|---|---|
| DC OP | — | Yes | No | Yes | Temperature propagation |
| DC Sweep | Yes (per pt) | Yes (per pt) | No | Yes | Warm-starting |
| Transient | Yes (init) | Yes (per step) | No | Yes | BDF/Gear, LTE, checkpoints |
| AC | Yes | Yes | Yes | No (LU only) | 2N×2N block matrix |
| Noise | Yes | Yes | Yes | No (LU per freq) | Per-device PSD |
| HB | Yes | Yes | Implicit | Yes (Newton) | IDFT/DFT round-trip |
| PSS | Yes | Yes | No | Yes (shooting) | Monodromy via FD |
| Fourier | No | No | No | No | DFT of TransientResult |
| TF | Yes | Yes | No | No (LU only) | Unit source injection |
| DC Sens | Yes | Yes | No | Yes (per param) | Forward FD |
| AC Sens | Yes | Yes | Yes | No | AC + FD perturbation |
| PZ | Yes | Yes | No | No (eigenvalue) | QR on Hessenberg |
| Disto | Yes | Yes | Yes | No (LU per freq) | Volterra kernels |
| SP | Yes | Yes | Yes | No (LU per port+freq) | Wave variables |

---

## C. Directory Structure

```
BigOSpice/
├── crates/
│   ├── cli/              # Command-line interface
│   ├── core/             # Circuit representation, MNA formulation
│   ├── cache/            # 5-layer incremental cache
│   ├── analysis/         # All analysis engines (DC, TRAN, AC, HB, etc.)
│   ├── solver/           # Newton-Raphson, convergence, stamping
│   ├── linalg/           # Sparse matrices, LU factorization
│   ├── device/           # Device models (BJT, MOSFET, diode, etc.)
│   ├── parser/           # Netlist tokenizer and parser
│   ├── io/               # Rawfile, HSPICE, CSV, Touchstone output
│   ├── utility/          # SoA containers, SIMD, arenas, pools
│   ├── osdi/             # OSDI v0.3 Verilog-A loader
│   ├── digital/           # XSPICE digital simulation
│   ├── cosim/            # Verilator co-simulation
│   └── compute/           # GPU acceleration (wgpu/WGSL)
├── docs/                  # This documentation
├── tests/
│   ├── suite/            # Internal test suite
│   └── external/         # External simulator comparison (ngspice, Xyce)
└── scripts/
    └── run_benchmarks.sh # Performance benchmarking
```

---

*Document version: 2026-04-16. Generated from comprehensive codebase research.*
