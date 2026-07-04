# Current-Controlled Switch (W Element) -- Parameter & Equation Reference

> SPICE current-controlled switch (CSW / W device) with 4-state hysteresis conductance selection.

## Model Topology

The W element is a two-terminal switch whose conductance is controlled by a current flowing through a sensing element (typically a voltage source). Terminals **p** (+) and **n** (-) carry the switch current; **ctrl** is the sensed control current from an external branch. The equivalent circuit is a simple conductance $G_{\text{eff}}$ stamped between p and n, hard-switched between $G_{\text{on}} = 1/R_{\text{on}}$ and $G_{\text{off}} = 1/R_{\text{off}}$ by a 4-state hysteresis machine driven by $I_{\text{ctrl}}$.

### Terminals

| Index | Name | Unknown Kind | Description |
|-------|------|-------------|-------------|
| 0 | p | Voltage | Positive switch terminal |
| 1 | n | Voltage | Negative switch terminal |
| 2 | ctrl | Current | Control (sense) current |

External port count: **2** (p, n). The ctrl current is an internal branch reference.

## Parameters

### Model Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| IT | $I_T$ | A | 0 | $(-\infty, +\infty)$ | Switching threshold current |
| IH | $I_H$ | A | 0 | $(-\infty, +\infty)$ | Hysteresis current (negative enables snap-through) |
| RON | $R_{\text{on}}$ | $\Omega$ | 1 | $(0, +\infty)$ | Closed (on-state) resistance |
| ROFF | $R_{\text{off}}$ | $\Omega$ | $1/G_{\min} = 10^{12}$ | $(0, +\infty)$ | Open (off-state) resistance |

### Instance Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| IC_ON | -- | flag | false | {true, false} | Initial condition: switch starts ON |
| IC_OFF | -- | flag | false | {true, false} | Initial condition: switch starts OFF |

## Equations

### Conductance Selection

On-state and off-state conductances derived from model resistances:

$$G_{\text{on}} = \frac{1}{R_{\text{on}}}$$

$$G_{\text{off}} = \frac{1}{R_{\text{off}}}$$

### Effective Conductance (iS -- Physics Function)

The effective conductance is selected by a hard step function (`blendv`) at the threshold current $I_T$. This is a discontinuous switch with no gradient through the transition point, matching ngspice's constant-conductance stamp behavior:

$$G_{\text{eff}} = \begin{cases} G_{\text{on}} & \text{if } I_{\text{ctrl}} \geq I_T \\ G_{\text{off}} & \text{if } I_{\text{ctrl}} < I_T \end{cases}$$

The `blendv` selector evaluates $(I_{\text{ctrl}} - I_T)$: non-negative selects $G_{\text{on}}$, negative selects $G_{\text{off}}$.

### Switch Current (KCL Stamps)

$$I_{\text{sw}} = G_{\text{eff}} \cdot (V_p - V_n)$$

KCL contributions to each node:

$$I_p = +I_{\text{sw}}$$

$$I_n = -I_{\text{sw}}$$

$$I_{\text{ctrl}} = 0 \quad \text{(sense only, no load on control branch)}$$

### 4-State Hysteresis Machine (updateState)

The switch state persists across Newton iterations and timepoints. Four states govern the hysteresis:

| State | Value | Meaning |
|-------|-------|---------|
| REALLY_OFF | 0 | Firmly off |
| REALLY_ON | 1 | Firmly on |
| HYST_OFF | 2 | In hysteresis band, switched off |
| HYST_ON | 3 | In hysteresis band, switched on |

#### Normal Hysteresis ($I_H > 0$)

Upper and lower thresholds:

$$I_{\text{upper}} = I_T + I_H$$

$$I_{\text{lower}} = I_T - I_H$$

State transitions:

$$\text{state} = \begin{cases} \text{REALLY\_ON} & \text{if } I_{\text{ctrl}} > I_T + I_H \\ \text{REALLY\_OFF} & \text{if } I_{\text{ctrl}} < I_T - I_H \\ \text{prev} & \text{if } I_T - I_H \leq I_{\text{ctrl}} \leq I_T + I_H \end{cases}$$

In the hysteresis band $[I_T - I_H,\; I_T + I_H]$, the previous state is retained (no transition).

#### Negative / Zero Hysteresis ($I_H \leq 0$) -- Snap-Through

When $I_H < 0$, the band inverts: $I_T - I_H > I_T + I_H$, so the band becomes $[I_T + I_H,\; I_T - I_H]$.

When $I_H = 0$, the band is degenerate (zero width at $I_T$).

$$\text{state} = \begin{cases} \text{REALLY\_ON} & \text{if } I_{\text{ctrl}} > I_T - I_H \\ \text{REALLY\_OFF} & \text{if } I_{\text{ctrl}} < I_T + I_H \\ \text{snap-through} & \text{if } I_T + I_H \leq I_{\text{ctrl}} \leq I_T - I_H \end{cases}$$

Snap-through logic within the band:

$$\text{state} = \begin{cases} \text{prev} & \text{if prev} \in \{\text{HYST\_OFF}, \text{HYST\_ON}\} \\ \text{HYST\_OFF} & \text{if prev} = \text{REALLY\_ON} \\ \text{HYST\_ON} & \text{if prev} = \text{REALLY\_OFF} \end{cases}$$

When entering the band from REALLY_ON, the switch snaps OFF (HYST_OFF). When entering from REALLY_OFF, the switch snaps ON (HYST_ON). Once in a HYST state inside the band, it holds.

### Initial State (initState)

$$\text{state}_0 = \begin{cases} \text{HYST\_ON} & \text{if IC\_ON = true} \\ \text{REALLY\_OFF} & \text{otherwise} \end{cases}$$

### Convergence

On any state change ($\text{state}_{\text{new}} \neq \text{state}_{\text{prev}}$), the solver is signaled to re-iterate (equivalent to ngspice `CKTnoncon++`). The `updateState` function returns `request_reject_at = 0.0` to force re-evaluation.

## Notes

- No temperature dependence -- the model has no temperature coefficients.
- No noise model -- no flicker or thermal noise equations are defined.
- No AC small-signal model beyond the DC conductance stamp.
- The Jacobian has no coupling between the control current and the switch terminals. The conductance is stamped as a constant within each Newton iteration; only the state machine triggers re-iteration on state changes.
- Default $R_{\text{off}} = 10^{12}\;\Omega$ corresponds to ngspice's $1/G_{\min}$.
