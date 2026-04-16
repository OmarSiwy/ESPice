# Device Models Research

## 1. DeviceModel Trait and DeviceEval Interface

**File:** `crates/device/src/eval.rs`

The core interface all devices implement:

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

**DeviceEval** carries all contributions for MNA stamping:

```rust
pub struct DeviceEval {
    pub g: SmallVec<[f64; 8]>,           // Resistive currents per terminal
    pub q: SmallVec<[f64; 8]>,           // Charge/flux per terminal
    pub G: SmallVec<[(u8, u8, f64); 8]>, // Conductance Jacobian: (row, col, value) = dg/dx
    pub C: SmallVec<[(u8, u8, f64); 16]>,// Capacitance Jacobian: (row, col, value) = dq/dx
    pub rhs: SmallVec<[f64; 4]>,         // Direct RHS contributions
}
```

**Convention:** All `g` and `q` values represent net current **leaving** the node (MNA convention). The Jacobian entries `G[row, col]` = $\frac{\partial g_{row}}{\partial V_{col}}$.

---

## 2. Diode Model

**File:** `crates/device/src/diode.rs`

### 2.1 DC Model (Shockley Equation)

$$I_D = I_{s,eff} \cdot \left( \exp\left(\frac{V_D}{N \cdot V_t}\right) - 1 \right) + I_{sr,eff} \cdot \left( \exp\left(\frac{V_D}{N_r \cdot V_t}\right) - 1 \right)$$

With optional Zener breakdown for $V_D < -BV$:

$$I_{bd} = -I_{BV} \cdot \exp\left(-\frac{V_D + BV}{N \cdot V_t}\right)$$

### 2.2 Parameters

| Parameter | Default | Units | Description |
|-----------|---------|-------|-------------|
| `is` | 1e-14 | A | Saturation current |
| `n` | 1.0 | - | Ideality factor |
| `vt` | derived | V | Thermal voltage (override) |
| `bv` | ∞ | V | Reverse breakdown voltage |
| `ibv` | 1e-3 | A | Current at breakdown onset |
| `xti` | 3.0 | - | Is temperature exponent |
| `eg` | 1.11 | eV | Bandgap energy (Si) |
| `tt` | 0.0 | s | Transit time |
| `area` | 1.0 | - | Area multiplier |
| `m` | 1.0 | - | Multiplicity (parallel diodes) |
| `cj0` | 0.0 | F | Zero-bias junction capacitance |
| `vj` | 1.0 | V | Junction built-in potential |
| `mj` | 0.5 | - | Junction grading coefficient |
| `fc` | 0.5 | - | Forward-bias depletion cap limit |

### 2.3 Temperature Scaling

$$I_s(T) = I_s(T_{nom}) \cdot \left(\frac{T}{T_{nom}}\right)^{XTI/N} \cdot \exp\left(\frac{E_g}{N} \cdot \frac{T/T_{nom} - 1}{V_t(T)}\right)$$

### 2.4 Junction Capacitance

For $V \le FC \cdot V_j$:
$$C_j = C_{j0} \cdot (1 - V/V_j)^{-M_j}$$

For $V > FC \cdot V_j$ (linearized):
$$C_j = C_{j0} \cdot \left(F_2 + \frac{F_3}{V_j} \cdot V\right)$$

where:
$$F_2 = (1-FC)^{-(1+M_j)} \cdot (1 - FC(1+M_j))$$
$$F_3 = (1-FC)^{-(1+M_j)} \cdot M_j$$

### 2.5 Charge Storage

$$Q(V) = \int_0^V C_j(u)\, du = \begin{cases} \frac{C_{j0} \cdot V_j}{1-M_j} \cdot \left[1 - (1 - V/V_j)^{1-M_j}\right] & V \le FC \cdot V_j \\ \text{linear continuation} & V > FC \cdot V_j \end{cases}$$

### 2.6 Transit-Time Charge

$$Q_{TT} = T_T \cdot I_D$$
$$C_{TT} = \frac{\partial Q_{TT}}{\partial V} = T_T \cdot \frac{\partial I_D}{\partial V} = T_T \cdot G_D$$

### 2.7 Jacobian (∂I/∂V)

Forward bias (Shockley):
$$G_D = \frac{I_S}{N \cdot V_t} \cdot \exp\left(\frac{V_D}{N \cdot V_t}\right) + G_{MIN}$$

Breakdown:
$$G_{bd} = \frac{I_{BV}}{N \cdot V_t} \cdot \exp\left(-\frac{V_D + BV}{N \cdot V_t}\right)$$

---

## 3. Bipolar Junction Transistor (Gummel-Poon)

**File:** `crates/device/src/bjt.rs`

### 3.1 DC Model Equations

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

### 3.2 Parameters

| Parameter | Default | Units | Description |
|-----------|---------|-------|-------------|
| `is` | 1e-15 | A | Transport saturation current |
| `bf` | 100 | - | Forward beta |
| `br` | 1 | - | Reverse beta |
| `nf` | 1 | - | Forward ideality |
| `nr` | 1 | - | Reverse ideality |
| `ne` | 1.5 | - | BE recombination ideality |
| `nc` | 1.5 | - | BC recombination ideality |
| `vaf` | ∞ | V | Forward Early voltage |
| `var` | ∞ | V | Reverse Early voltage |
| `ikf` | ∞ | A | Forward knee current |
| `ikr` | ∞ | A | Reverse knee current |
| `ise` | 0 | A | BE recombination saturation current |
| `isc` | 0 | A | BC recombination saturation current |
| `c4/c5` | - | - | Avalanche multiplication factors |
| `xti` | 3 | - | Is temperature exponent |
| `eg` | 1.11 | eV | Bandgap energy |
| `tnom` | 300.15 | K | Nominal temperature |
| `vtc` | 0 | V/K | Vt temperature coefficient |
| `fc` | 0.5 | - | Junction capacitance fc |
| `cje` | 0 | F | BE depletion capacitance |
| `vje` | 0.75 | V | BE built-in potential |
| `mje` | 0.33 | - | BE grading coefficient |
| `cjc` | 0 | F | BC depletion capacitance |
| `vjc` | 0.75 | V | BC built-in potential |
| `mjc` | 0.33 | - | BC grading coefficient |
| `ccs` | 0 | F | Substrate capacitance |
| `tf` | 0 | s | Forward transit time |
| `tr` | 0 | s | Reverse transit time |
| `td` | 0 | s | Excess phase delay |

### 3.3 Temperature Effects

- **Is(T):** Same formula as diode
- **bf(T):** $\beta_F(T) = \beta_{F,Tnom} \cdot (T/T_{nom})^{XTI/NE}$
- **vaf(T):** $V_{AF}(T) = V_{AF,Tnom} + \alpha \cdot (T - T_{nom})$

### 3.4 AC Small-Signal (Charge Storage)

**BaseEmitter Charge:**
$$Q_{BE} = \tau_F \cdot I_F + C_{je}(V_{BE}) \cdot V_{BE}$$

**BaseCollector Charge:**
$$Q_{BC} = \tau_R \cdot I_R + C_{jc}(V_{BC}) \cdot V_{BC}$$

**Excess Phase (Cole's approximation):**
$$I_C(t) = I_{CC}(t) - \sum_{k=1}^{n} \frac{\alpha_k}{\tau_d^k} \cdot \frac{d^k I_{CC}}{dt^k}$$

---

## 4. MOSFET Models (Shichman-Hodges)

**File:** `crates/device/src/mosfet.rs`

### 4.1 Level 1 (Shichman-Hodges)

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

### 4.2 Level 2 (Grove-Frohman)

Adds body effect via the same $V_{th}$ formula as Level 1. Otherwise identical to Level 1.

### 4.3 Level 3 (Empirical)

Adds:
- **DIBL (Drain-Induced Barrier Lowering):** $V_{th} = V_{th,long} - \eta \cdot V_{DS}$
- **Mobility degradation:** $\beta = \frac{\beta_0}{1 + \theta \cdot V_{ov}}$
- **Saturation voltage with kappa:** $V_{DSAT} = \frac{V_{ov}}{1 + \kappa \cdot V_{ov}}$
- **Narrow-width effect:** $\gamma_W = \gamma + \delta \cdot \frac{\pi \cdot 3.9 \cdot 10^{-11}}{4 W \sqrt{\phi + V_{SB}}}$

### 4.4 Level 6 (Sakurai-Newton Power Law)

$$I_D = \frac{W}{L} \cdot K_O \cdot V_{ov}^{m_k} \cdot \tanh\left(\frac{V_{DS}}{V_{ov}}\right) \cdot (1 + \lambda \cdot V_{DS})$$

### 4.5 Source-Drain Swap Handling

When $V_{DS} < 0$, standard SPICE swaps D and S internally:
- $V_{GS}' = V_{GD}$ (gate-to-drain)
- $V_{DS}' = -V_{DS}$
- $V_{BS}' = V_{BD}$

After evaluation, current is negated and Jacobian columns for D/S are swapped.

### 4.6 Meyer Gate Capacitances (Level 1)

Computed when `TOX` is specified:

$$C_{OX} = \frac{\epsilon_{ox}}{TOX} \cdot W \cdot L_{eff}$$

**Saturation:**
$$C_{GS} = \frac{2}{3} \cdot C_{OX} \cdot \left(1 - \left(\frac{V_{DS}-V_{DSAT}}{2 V_{ov}}\right)^2\right)$$

**Triode:**
$$C_{GS} = C_{OX} / 2, \quad C_{GD} = C_{OX} / 2$$

### 4.7 Transconductances (Jacobian Derivatives)

$$g_m = \frac{\partial I_D}{\partial V_{GS}} = \begin{cases} \beta \cdot V_{DS} \cdot (1 + \lambda V_{DS}) & \text{linear} \\ \beta \cdot V_{ov} \cdot (1 + \lambda V_{DS}) & \text{saturation} \end{cases}$$

$$g_{ds} = \frac{\partial I_D}{\partial V_{DS}} = \begin{cases} \beta \cdot (V_{ov} - V_{DS}) \cdot (1 + \lambda V_{DS}) + \beta \cdot (V_{ov} V_{DS} - V_{DS}^2/2) \cdot \lambda & \text{linear} \\ \frac{\beta}{2} \cdot V_{ov}^2 \cdot \lambda & \text{saturation} \end{cases}$$

$$g_{mb} = g_m \cdot \frac{\gamma}{2 \sqrt{\phi + V_{SB}}}$$

---

## 5. BSIM3 Model

**File:** `crates/device/src/bsim3/` (v3.3 from Berkeley)

### 5.1 Threshold Voltage

$$V_{th} = V_{th0} + K_{1ox} \cdot (\sqrt{\phi - V_{bseff}} - \sqrt{\phi}) - K_{2ox} \cdot V_{bseff}$$

Plus corrections for:
- **Short-channel SCE:** $-dvt0 \cdot \exp(-dvt1 \cdot L / lt_0) \cdot (V_{bi} - \phi)$
- **Narrow-width:** $(k3 + k3b \cdot V_{bseff}) \cdot \frac{Tox}{W + W_0} \cdot \phi$
- **DIBL:** $-\theta_{Rout} \cdot (\eta_0 + \eta_b \cdot V_{bseff}) \cdot V_{DS}$

### 5.2 Subthreshold Smoothing

$$V_{gsteff} = n \cdot V_t \cdot \ln\left(1 + \exp\left(\frac{V_{GS} - V_{th} - V_{off}}{n \cdot V_t}\right)\right)$$

### 5.3 Mobility

$$\mu_{eff} = \frac{\mu_0}{1 + (U_a + U_c \cdot V_{bseff}) \cdot E_{eff} + U_b \cdot E_{eff}^2}$$

where $E_{eff} = \frac{V_{gsteff} + 2 V_{th}}{Tox}$

### 5.4 Saturation Voltage

$$V_{DSAT} = \frac{E_{sat} \cdot L \cdot (V_{gsteff} + 2 V_t)}{A_{bulk} \cdot E_{sat} \cdot L + V_{gsteff} + 2 V_t}$$

with bulk charge factor:
$$A_{bulk} = 1 + \frac{K_{1ox}}{2\sqrt{\phi}} \cdot \left(\frac{A_0 \cdot L_{eff}}{L_{eff} + 2\sqrt{X_j \cdot X_{dep}}} + \frac{B_0}{W + B_1}\right) \cdot (1 - A_{gs} \cdot V_{gsteff}) \cdot (1 + K_{eta} \cdot V_{bseff})$$

### 5.5 Drain Current

$$I_{DS} = \mu_{eff} \cdot C_{ox} \cdot \frac{W}{L} \cdot V_{gsteff} \cdot \left(1 - \frac{A_{bulk} \cdot V_{dseff}}{2(V_{gsteff} + 2 V_t)}\right) \cdot \frac{V_{dseff}}{1 + V_{dseff} / (E_{sat} \cdot L)}$$

with channel-length modulation:
$$I_{DS} = I_{DS} \cdot \left(1 + \frac{V_{DS} - V_{dseff}}{P_{clm} \cdot E_{sat} \cdot L}\right)$$

### 5.6 Substrate Current (Impact Ionization)

$$I_{sub} = \frac{\alpha_0 + \alpha_1 \cdot L_{eff}}{L_{eff}} \cdot (V_{DS} - V_{dseff}) \cdot \exp\left(-\frac{\beta_0}{V_{DS} - V_{dseff}}\right) \cdot I_{DS}$$

### 5.7 Key BSIM3 Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `vth0` | 0.7 | Zero-Vbs threshold |
| `k1` | 0.5 | Body effect coefficient |
| `k2` | 0 | Second-order body effect |
| `u0` | 0.067 (NMOS) | Low-field mobility |
| `ua` | 2.25e-9 | Mobility degradation |
| `ub` | 5.87e-19 | Mobility degradation |
| `uc` | -4.65e-11 | Body-bias mobility |
| `vsat` | 8e4 | Saturation velocity |
| `tox` | 1.5e-8 | Oxide thickness |
| `ndep` | 1.7e17 | Channel doping |
| `gamma1` | 0 | Body effect coefficient |
| `pclm` | 1.3 | CLM coefficient |
| `drout` | 0.56 | DIBL coefficient |

---

## 6. BSIM4 Model

**File:** `crates/device/src/bsim4/` (v4.8.3 from Berkeley)

### 6.1 Threshold Voltage

Same long-channel formula as BSIM3, with enhanced short-channel rolloff and DIBL:

$$V_{th} = V_{th0} + K_{1ox}(\sqrt{\phi - V_{bseff}} - \sqrt{\phi}) - K_{2ox} \cdot V_{bseff} - SCE + NW - DIBL$$

### 6.2 Vgsteff Smoothing

$$V_{gsteff} = n \cdot V_t \cdot \ln\left(1 + \exp\left(\frac{V_{gst} - V_{off}}{n \cdot V_t}\right)\right)$$

### 6.3 Mobility

Enhanced mobility model (mobMod 0/1/2):

$$\mu_{eff} = \frac{\mu_0}{1 + (U_a + U_c \cdot V_{bseff}) \cdot E_{eff} + U_b \cdot E_{eff}^2}$$

### 6.4 Drain Current

$$I_{DS} = \beta \cdot V_{gsteff} \cdot V_{dseff} \cdot \left(1 - \frac{A_{bulk} \cdot V_{dseff}}{2(V_{gsteff} + 2V_t)}\right) \cdot \frac{1}{1 + V_{dseff} / (E_{sat} \cdot L)}$$

with CLM, DIBL, and SCBE multipliers applied.

### 6.5 GIDL/GISL Leakage

$$I_{GIDL} = A_{gidl} \cdot W_{diod} \cdot \frac{V_{DS} - V_{GS} - E_{gidl}}{3 \cdot T_{oxe}} \cdot \exp\left(-3 \cdot T_{oxe} \cdot \frac{B_{gidl}}{V_{DS} - V_{GS} - E_{gidl}}\right)$$

### 6.6 Charge Partitioning (Ward-Dutton)

In saturation:
$$C_{gg} = C_{inv}$$
$$C_{gs} = -\frac{2}{3} \cdot C_{inv} \cdot \left(1 - \left(\frac{V_{gsteff}}{2(V_{gsteff} + 2V_t) - V_{DSAT}}\right)^2\right)$$
$$C_{gd} = 0$$
$$C_{gb} = 0$$

Drain charge gets 40% partition.

### 6.7 Key BSIM4 Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `vth0` | 0.7 | Zero-Vbs threshold |
| `k1` | 0.53 | First-order body effect |
| `k2` | -0.0186 | Second-order body effect |
| `u0` | 0.067 | Low-field mobility |
| `toxe` | 3e-9 | Electrical oxide thickness |
| `ndep` | 1.7e17 | Channel doping |
| `rdsw` | 200 | S/D parasitic resistance |
| `pclm` | 1.3 | CLM coefficient |
| `agidl` | 0 | GIDL coefficient |
| `bgidl` | 2.3e9 | GIDL exponential factor |

---

## 7. JFET Model

**File:** `crates/device/src/jfet.rs`

### 7.1 Level 1 (Shichman-Hodges)

**Regions:**

1. **Cutoff** ($V_{GS} \le V_{TO}$): $I_D = GDS_{MIN} \cdot V_{DS}$

2. **Triode** ($0 \le V_{DS} < V_{GS} - V_{TO}$):
$$I_D = \beta \cdot (2(V_{GS} - V_{TO}) V_{DS} - V_{DS}^2) \cdot (1 + \lambda V_{DS})$$

3. **Saturation** ($V_{DS} \ge V_{GS} - V_{TO}$):
$$I_D = \beta \cdot (V_{GS} - V_{TO})^2 \cdot (1 + \lambda V_{DS})$$

### 7.2 Level 2 (Parker-Skellern)

Smooth hyperbolic model eliminating abrupt region transitions:

$$V_{ST} = \frac{V_{ov}}{1 + \delta \cdot V_{ov}} \quad \text{(smooth saturation voltage)}$$

$$V_{eff} = V_{DS} - \frac{1}{n_{ds}} \ln\left(1 + \exp(n_{ds}(V_{DS} - V_{ST}))\right) \quad \text{(smooth clamp)}$$

$$I_D = \beta \cdot V_{eff}^2 \cdot (1 + \lambda V_{DS}) \cdot \frac{1 - \exp(-n_{ds} V_{DS})}{n_{ds}} \cdot \frac{1}{1 + HFETA \cdot V_{GS}}$$

### 7.3 Temperature Scaling

$$V_{TO}(T) = V_{TO}(T_{nom}) + VTOTC \cdot (T - T_{nom})$$
$$\beta(T) = \beta(T_{nom}) \cdot \left(\frac{T}{T_{nom}}\right)^{BETATCE}$$

### 7.4 Gate Junction Leakage

$$I_{GS} = I_S \cdot \left(\exp\left(\frac{V_{GS}}{V_t}\right) - 1\right)$$
$$I_{GD} = I_S \cdot \left(\exp\left(\frac{V_{GD}}{V_t}\right) - 1\right)$$

---

## 8. VBIC Model

**File:** `crates/device/src/vbic.rs`

### 8.1 DC Transport Equations

**Forward/Reverse Injection:**
$$I_{BE} = ibei \cdot \left(\exp\left(\frac{V_{BE}}{nei \cdot V_t}\right) - 1\right)$$
$$I_{BC} = ibci \cdot \left(\exp\left(\frac{V_{BC}}{nci \cdot V_t}\right) - 1\right)$$

**Transport Current:**
$$q_1 = \frac{1}{1 - V_{BC}/V_{ef} - V_{BE}/V_{er}}$$
$$q_2 = \frac{If}{ikf} + \frac{Ir}{ikr}$$
$$q_b = \frac{q_1}{2} \cdot \left(1 + \sqrt{1 + 4q_2}\right)$$
$$I_{CC} = \frac{If - Ir}{q_b}$$

### 8.2 Avalanche Multiplication

$$I_C = I_{CC} \cdot (1 + \alpha \cdot M(V_{BC}))$$
where $M(V_{BC}) = 1 + \frac{V_{BC}}{BV_{CBO}}$ or more complex polynomial

### 8.3 Transit Time Charges

$$Q_T = \tau_F \cdot If + \tau_R \cdot Ir + C_{je}(V_{BE}) \cdot V_{BE} + C_{jc}(V_{BC}) \cdot V_{BC}$$

---

## 9. MNA Matrix Stamping Convention

### 9.1 Current Convention

For a device with N terminals, `g[i]` = net current **leaving** terminal i into the circuit. Kirchhoff's Current Law requires:

$$\sum_{i=0}^{N-1} g[i] = 0 \quad \text{(within numerical tolerance)}$$

### 9.2 Jacobian Convention

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

### 9.3 Charge Vector Convention

`q[i]` = net charge **leaving** terminal i (same direction as g[i]). For the C matrix:

`C[row, col]` = $\frac{\partial q[row]}{\partial V[col]} = \frac{\partial^2 Q_{total}}{\partial V_{row} \partial V_{col}}$

---

## 10. Small-Signal AC Analysis

For AC analysis (harmonic balance), the small-signal admittance is:

$$Y = G + j\omega C$$

where:
- $G$ = conductance Jacobian from `eval()` (real part)
- $C$ = capacitance Jacobian from `eval()` (imaginary part via $\omega$)

This is automatically handled by the solver when building the system matrix for AC/HB analysis.

---

## 11. Operating Region Detection

Each device model implicitly determines operating region from terminal voltages:

| Device | Cutoff | Linear | Saturation |
|--------|--------|--------|------------|
| Diode | $V < 0$ | N/A | $V > 0$ |
| MOSFET | $V_{ov} \le 0$ | $V_{DS} < V_{ov}$ | $V_{DS} \ge V_{ov}$ |
| BJT | $V_{BE} < 0$ | $V_{BC} > 0$ | $V_{BE} > 0, V_{BC} < 0$ |
| JFET | $V_{GS} \le V_{TO}$ | $V_{DS} < V_{GS} - V_{TO}$ | $V_{DS} \ge V_{GS} - V_{TO}$ |

---

## 12. Summary of g(x)/q(x) Interface

The fundamental SPICE device interface:

- **g(x)**: Vector of resistive currents = $I_D(V_1, ..., V_n)$ — contributes to MNA G matrix
- **q(x)**: Vector of stored charges = $Q(V_1, ..., V_n)$ — contributes to MNA C matrix via $\frac{dq}{dt} = \frac{\partial q}{\partial V} \cdot \frac{dV}{dt}$

- **G Jacobian**: $\frac{\partial g}{\partial V}$ — Newton-Raphson update
- **C Jacobian**: $\frac{\partial q}{\partial V}$ — time integration

This separates DC (purely resistive, $q=0$) from transient ($g$ handles resistors, $q$ handles capacitors/inductors).
