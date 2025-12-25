# Lossy Transmission Line (LTRA) -- Parameter & Equation Reference

> Lumped RLGC lossy transmission line with pi-network topology (SPICE3f5 LTRA/O model)

## Model Topology

Four-terminal device with two ports: port 1 (pos1, neg1) and port 2 (pos2, neg2), plus two internal branch-current unknowns (branch1, branch2). DC/transient behavior is modeled as a lumped pi-network: series resistance $R_\text{total}$ and inductance $L_\text{total}$ between the ports, with shunt conductance $G_\text{total}/2$ and capacitance $C_\text{total}/2$ at each port. Branch1 enforces current conservation ($I_1 + I_2 = 0$); Branch2 enforces KVL around the series path.

```
        branch1 (I1)            branch2 (I2)
  pos1 o----+------[R_eff, L_total]------+----o pos2
            |                             |
         [G/2, C/2]                   [G/2, C/2]
            |                             |
  neg1 o----+-----------------------------+----o neg2
```

## Unknowns

| Index | Name    | Kind    | Description                     |
|-------|---------|---------|---------------------------------|
| 0     | pos1    | voltage | Port 1 positive terminal        |
| 1     | neg1    | voltage | Port 1 negative terminal        |
| 2     | pos2    | voltage | Port 2 positive terminal        |
| 3     | neg2    | voltage | Port 2 negative terminal        |
| 4     | branch1 | current | Branch current 1 (port 1 side)  |
| 5     | branch2 | current | Branch current 2 (port 2 side)  |

External ports: 4 (pos1, neg1, pos2, neg2)

## Parameters

### Model Parameters

| Parameter     | Symbol          | Unit | Default | Range     | Description                                                         |
|---------------|-----------------|------|---------|-----------|---------------------------------------------------------------------|
| R             | $R$             | Ohm/m | 0.0    | $\geq 0$ | Series resistance per unit length                                   |
| L             | $L$             | H/m  | 0.0    | $\geq 0$ | Series inductance per unit length                                   |
| G             | $G$             | S/m  | 0.0    | $\geq 0$ | Shunt conductance per unit length                                   |
| C             | $C$             | F/m  | 0.0    | $\geq 0$ | Shunt capacitance per unit length                                   |
| LEN           | $\ell$          | m    | 1.0    | $> 0$    | Physical length of transmission line                                |
| NOCONTROL     | --              | flag | false   | bool      | Disable timestep control                                            |
| STEPLIMIT     | --              | flag | false   | bool      | Always limit timestep to $0.8 \times \tau_d$                        |
| NOSTEPLIMIT   | --              | flag | false   | bool      | Never limit timestep to $0.8 \times \tau_d$                         |
| LININTERP     | --              | flag | false   | bool      | Use linear interpolation for history                                |
| QUADINTERP    | --              | flag | false   | bool      | Use quadratic interpolation for history                             |
| MIXEDINTERP   | --              | flag | false   | bool      | Use linear interpolation if quadratic results look unacceptable     |
| TRUNCNR       | --              | flag | false   | bool      | Use Newton-Raphson iterations for timestep calculation in LTRAtrunc |
| TRUNCDONTCUT  | --              | flag | false   | bool      | Do not limit timestep to keep impulse response errors low           |
| COMPACTREL    | $\epsilon_r$   | --   | 0.001   | $> 0$    | Relative tolerance for straight-line compaction                     |
| COMPACTABS    | $\epsilon_a$   | --   | 1e-12   | $> 0$    | Absolute tolerance for straight-line compaction                     |

### Instance Parameters

| Parameter | Symbol      | Unit | Default | Range     | Description                          |
|-----------|-------------|------|---------|-----------|--------------------------------------|
| TEMP      | $T$         | C    | 27.0    | --        | Instance temperature                 |
| DTEMP     | $\Delta T$  | C    | 0.0     | --        | Temperature offset from circuit temp |
| M         | $m$         | --   | 1.0     | $> 0$    | Parallel multiplier                  |
| W         | $W$         | m    | 1e-6    | $> 0$    | Instance width                       |
| L         | $L_i$       | m    | 1e-6    | $> 0$    | Instance length                      |

## Equations

### Derived Totals

$$R_\text{total} = R \cdot \ell$$

Total series resistance.

$$L_\text{total} = L \cdot \ell$$

Total series inductance.

$$G_\text{total} = G \cdot \ell$$

Total shunt conductance.

$$C_\text{total} = C \cdot \ell$$

Total shunt capacitance.

### Effective Series Resistance (Singularity Guard)

$$G_\text{SHORT} = 10^{12}$$

$$R_\text{eff} = \begin{cases} R_\text{total} & \text{if } R_\text{total} > 0 \\ \dfrac{1}{G_\text{SHORT}} = 10^{-12} & \text{if } R_\text{total} = 0 \end{cases}$$

When $R = 0$, a near-short conductance $G_\text{SHORT}$ replaces the zero resistance to avoid a singular matrix. This effectively enforces $V_1 = V_2$.

### Port Voltages

$$V_1 = V_{\text{pos1}} - V_{\text{neg1}}$$

$$V_2 = V_{\text{pos2}} - V_{\text{neg2}}$$

### Resistive (DC) Contributions -- `i()` Function

**Branch equation 1 -- Current conservation:**

$$f_{\text{branch1}} = I_{\text{br1}} + I_{\text{br2}} = 0$$

Enforces $I_1 + I_2 = 0$ (current into port 1 equals current out of port 2).

**Branch equation 2 -- KVL (series path):**

$$f_{\text{branch2}} = V_1 - V_2 - R_\text{eff} \cdot I_{\text{br1}} = 0$$

Kirchhoff's voltage law around the series R path.

**KCL at external nodes -- shunt conductance (pi-network):**

$$G_\text{shunt} = \frac{G_\text{total}}{2} \cdot m$$

$$f_{\text{pos1}} = I_{\text{br1}} + G_\text{shunt} \cdot V_1$$

$$f_{\text{neg1}} = -I_{\text{br1}} - G_\text{shunt} \cdot V_1$$

$$f_{\text{pos2}} = I_{\text{br2}} + G_\text{shunt} \cdot V_2$$

$$f_{\text{neg2}} = -I_{\text{br2}} - G_\text{shunt} \cdot V_2$$

### Reactive (Charge) Contributions -- `q()` Function

The solver differentiates $q$ with respect to time to obtain displacement currents ($i_C = dq/dt$, $v_L = d\Phi/dt$).

**Series inductance -- flux linkage in branch 2 (KVL equation):**

$$q_{\text{branch2}} = \begin{cases} L_\text{total} \cdot I_{\text{br1}} & \text{if } L_\text{total} > 0 \\ 0 & \text{otherwise} \end{cases}$$

The solver computes $\dfrac{dq_{\text{branch2}}}{dt} = L_\text{total} \cdot \dfrac{dI_{\text{br1}}}{dt}$, adding an inductive voltage drop to the KVL equation.

**Shunt capacitance -- pi-network charge at each port:**

$$C_\text{shunt} = \frac{C_\text{total}}{2} \cdot m$$

When $C_\text{total} > 0$:

$$q_{\text{pos1}} = C_\text{shunt} \cdot V_1$$

$$q_{\text{neg1}} = -C_\text{shunt} \cdot V_1$$

$$q_{\text{pos2}} = C_\text{shunt} \cdot V_2$$

$$q_{\text{neg2}} = -C_\text{shunt} \cdot V_2$$

$$q_{\text{branch1}} = 0$$

The solver computes $\dfrac{dq}{dt} = C_\text{shunt} \cdot \dfrac{dV}{dt}$ at each port, yielding capacitive shunt currents.

### Jacobian (G-matrix) Stamps -- Conductance

Derived from $\partial f / \partial x$ of the `i()` function:

| Row     | Col     | Value                  |
|---------|---------|------------------------|
| branch1 | branch1 | $+1$                   |
| branch1 | branch2 | $+1$                   |
| branch2 | pos1    | $+1$                   |
| branch2 | neg1    | $-1$                   |
| branch2 | pos2    | $-1$                   |
| branch2 | neg2    | $+1$                   |
| branch2 | branch1 | $-R_\text{eff}$        |
| pos1    | branch1 | $+1$                   |
| pos1    | pos1    | $+G_\text{shunt}$      |
| pos1    | neg1    | $-G_\text{shunt}$      |
| neg1    | branch1 | $-1$                   |
| neg1    | pos1    | $-G_\text{shunt}$      |
| neg1    | neg1    | $+G_\text{shunt}$      |
| pos2    | branch2 | $+1$                   |
| pos2    | pos2    | $+G_\text{shunt}$      |
| pos2    | neg2    | $-G_\text{shunt}$      |
| neg2    | branch2 | $-1$                   |
| neg2    | pos2    | $-G_\text{shunt}$      |
| neg2    | neg2    | $+G_\text{shunt}$      |

### Jacobian (C-matrix) Stamps -- Capacitance/Inductance

Derived from $\partial q / \partial x$ of the `q()` function:

| Row     | Col     | Value                  | Condition             |
|---------|---------|------------------------|-----------------------|
| branch2 | branch1 | $+L_\text{total}$      | $L_\text{total} > 0$ |
| pos1    | pos1    | $+C_\text{shunt}$      | $C_\text{total} > 0$ |
| pos1    | neg1    | $-C_\text{shunt}$      | $C_\text{total} > 0$ |
| neg1    | pos1    | $-C_\text{shunt}$      | $C_\text{total} > 0$ |
| neg1    | neg1    | $+C_\text{shunt}$      | $C_\text{total} > 0$ |
| pos2    | pos2    | $+C_\text{shunt}$      | $C_\text{total} > 0$ |
| pos2    | neg2    | $-C_\text{shunt}$      | $C_\text{total} > 0$ |
| neg2    | pos2    | $-C_\text{shunt}$      | $C_\text{total} > 0$ |
| neg2    | neg2    | $+C_\text{shunt}$      | $C_\text{total} > 0$ |

### Noise

No noise generators declared for this device.

### Temperature Dependence

No explicit temperature-dependent equations in the current implementation. Instance parameters `TEMP` and `DTEMP` are declared but not used in the `i()` or `q()` functions.

### Convergence Aids

No `limit()` (Newton step damping) or `attempt()` (parameter stepping / source stepping) functions are implemented for this device.

## Implementation Notes

- This is a **lumped-element approximation**, not a distributed delay model. The full history-dependent (`iH` variant) implementation for true travelling-wave transient delay is marked as TODO in the source.
- The model matches the ngspice LTRA DC topology: pi-network shunt elements with a series branch.
- The parallel multiplier $m$ scales shunt elements ($G_\text{shunt}$, $C_\text{shunt}$) but not the series branch equations, consistent with $m$ parallel identical lines sharing the same port voltages.
- Width ($W$) and length ($L_i$) instance parameters are declared but not used in the equations; the model length parameter `LEN` ($\ell$) controls the electrical length.
