# Voltage-Controlled Switch (S) -- Parameter & Equation Reference

> Voltage-controlled switch with 4-state hysteresis machine, following the SPICE3f5 / ngspice `SW` model (`swload.c`).

## Model Topology

The device has four terminals: two output port terminals (**p**, **n**) carrying the switched current, and two control port terminals (**cp**, **cn**) that sense the control voltage. The control port draws zero current (infinite input impedance). Between **p** and **n** the device stamps a single conductance $G_{\text{eff}}$ whose value is switched discretely between $G_{\text{on}} = 1/R_{\text{on}}$ and $G_{\text{off}} = 1/R_{\text{off}}$ by a 4-state hysteresis machine driven by $V_{\text{ctrl}} = V_{cp} - V_{cn}$.

```
       cp o----+
                |  (voltage sense, I = 0)
       cn o----+
                |
        [4-state hysteresis FSM]
                |
                v  selects G_eff
       p o---[ G_eff ]---o n
```

## Parameters

### Model Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `VT` (vt) | $V_{TH}$ | V | 0.0 | $(-\infty, +\infty)$ | Threshold voltage for switching |
| `VH` (vh) | $V_H$ | V | 0.0 | $(-\infty, +\infty)$ | Hysteresis voltage (positive = normal hysteresis, negative = snap-through, zero = no hysteresis) |
| `RON` (ron) | $R_{\text{on}}$ | $\Omega$ | 1.0 | $(0, +\infty)$ | On-state resistance |
| `ROFF` (roff) | $R_{\text{off}}$ | $\Omega$ | $10^{12}$ | $(0, +\infty)$ | Off-state resistance (ngspice default: $1/G_{\text{MIN}}$) |

### Instance Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `IC=ON` (init_on) | -- | flag | false | {true, false} | Initial condition: switch starts in the ON state (`HYST_ON`) |
| `IC=OFF` (init_off) | -- | flag | false | {true, false} | Initial condition: switch starts in the OFF state (`HYST_OFF`) |

### Internal State

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `current_state` | u8 | 0 (`REALLY_OFF`) | Current FSM state: 0=`REALLY_OFF`, 1=`REALLY_ON`, 2=`HYST_OFF`, 3=`HYST_ON` |
| `g_eff` | f64 | 0.0 | Effective conductance set by the state machine after each update |

## Equations

### Derived Conductances

$$G_{\text{on}} = \frac{1}{R_{\text{on}}}$$

$$G_{\text{off}} = \frac{1}{R_{\text{off}}}$$

On-state and off-state conductances computed from model resistance parameters.

### Control Voltage

$$V_{\text{ctrl}} = V_{cp} - V_{cn}$$

Voltage across the control terminals. Draws zero current.

### Output Current (Resistive Stamp)

$$I_{sw} = G_{\text{eff}} \cdot (V_p - V_n)$$

where

$$G_{\text{eff}} = \begin{cases} G_{\text{on}} & \text{if state} \in \{\texttt{REALLY\_ON},\, \texttt{HYST\_ON}\} \\ G_{\text{off}} & \text{if state} \in \{\texttt{REALLY\_OFF},\, \texttt{HYST\_OFF}\} \end{cases}$$

KCL contributions: $+I_{sw}$ into node **p**, $-I_{sw}$ into node **n**, $0$ into **cp** and **cn**.

### Conductance Matrix Stamp

The linearized (Newton) stamp is a $4 \times 4$ block, but only the **p**--**n** quadrant is nonzero:

$$\frac{\partial I_p}{\partial V_p} = +G_{\text{eff}}, \quad \frac{\partial I_p}{\partial V_n} = -G_{\text{eff}}$$

$$\frac{\partial I_n}{\partial V_p} = -G_{\text{eff}}, \quad \frac{\partial I_n}{\partial V_n} = +G_{\text{eff}}$$

All other Jacobian entries (rows/columns involving **cp**, **cn**) are zero. The `blendv` function provides a discrete step selection (no derivative through the switching decision), matching ngspice's piecewise-constant conductance stamp.

## State Machine

### Initial State (`initState`)

$$\text{state}_0 = \begin{cases} \texttt{HYST\_ON},\; G_{\text{eff}} = G_{\text{on}} & \text{if } \texttt{init\_on} = \text{true} \\ \texttt{HYST\_OFF},\; G_{\text{eff}} = G_{\text{off}} & \text{if } \texttt{init\_off} = \text{true} \\ \texttt{REALLY\_OFF},\; G_{\text{eff}} = G_{\text{off}} & \text{otherwise (default)} \end{cases}$$

### State Update (`updateState`) -- 4-State Hysteresis FSM

Three regimes depending on the sign of $V_H$:

#### Case 1: Positive Hysteresis ($V_H > 0$)

$$\text{new\_state} = \begin{cases} \texttt{REALLY\_ON} & \text{if } V_{\text{ctrl}} > V_{TH} + V_H \\ \texttt{REALLY\_OFF} & \text{if } V_{\text{ctrl}} < V_{TH} - V_H \\ \text{old\_state} & \text{otherwise (in hysteresis band)} \end{cases}$$

The hysteresis band is $[V_{TH} - V_H,\; V_{TH} + V_H]$. Within this band the state is unchanged (memory effect).

#### Case 2: Negative Hysteresis / Snap-Through ($V_H < 0$)

Note: since $V_H < 0$, $V_{TH} - V_H > V_{TH}$ and $V_{TH} + V_H < V_{TH}$, so the thresholds are swapped.

$$\text{new\_state} = \begin{cases} \texttt{REALLY\_ON} & \text{if } V_{\text{ctrl}} > V_{TH} - V_H \\ \texttt{REALLY\_OFF} & \text{if } V_{\text{ctrl}} < V_{TH} + V_H \\ \text{old\_state} & \text{if old\_state} \in \{\texttt{HYST\_OFF},\, \texttt{HYST\_ON}\} \\ \texttt{HYST\_OFF} & \text{if old\_state} = \texttt{REALLY\_ON} \\ \texttt{HYST\_ON} & \text{if old\_state} = \texttt{REALLY\_OFF} \end{cases}$$

In the band $[V_{TH} + V_H,\; V_{TH} - V_H]$: if already in a hysteresis state, hold; otherwise snap to the opposite hysteresis state (snap-through behavior).

#### Case 3: No Hysteresis ($V_H = 0$)

$$\text{new\_state} = \begin{cases} \texttt{REALLY\_ON} & \text{if } V_{\text{ctrl}} > V_{TH} \\ \texttt{REALLY\_OFF} & \text{otherwise} \end{cases}$$

Simple threshold comparison with no memory.

### Post-Update Conductance Assignment

After the FSM resolves the new state:

$$G_{\text{eff}} = \begin{cases} G_{\text{on}} & \text{if new\_state} \in \{\texttt{REALLY\_ON},\, \texttt{HYST\_ON}\} \\ G_{\text{off}} & \text{if new\_state} \in \{\texttt{REALLY\_OFF},\, \texttt{HYST\_OFF}\} \end{cases}$$

### Convergence Feedback

If $\text{new\_state} \neq \text{old\_state}$, the state machine returns `request_reject_at = 0.0`, signaling the solver to reject the current timepoint and re-solve with the updated conductance. If the state is unchanged, it returns `ok`.

## Noise

### Thermal Noise

A single thermal noise source is declared between nodes **p** (index 0) and **n** (index 1):

$$\overline{i_n^2} = 4 k T G_{\text{eff}} \Delta f$$

where $G_{\text{eff}}$ is the current effective conductance selected by the state machine. This is the standard Johnson-Nyquist noise of the switch resistance.
