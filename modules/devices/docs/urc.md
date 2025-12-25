# URC (Uniform Distributed RC Line) -- Parameter & Equation Reference

> N-section geometric ladder network approximation of a uniform distributed RC transmission line with optional shunt diodes.

## Model Topology

The URC device has three external terminals: **p1** (input), **p2** (output), and **ref** (reference/ground). Internally it is expanded into an N-section ladder network of series resistors from p1 to p2, with shunt capacitors (or shunt diodes, if `ISPERL > 0`) from each interior node and p2 to the ref node. Up to 9 internal nodes (n1--n9) are created, supporting a maximum of 10 ladder sections; unused internal nodes are shorted to p2 via $G_{SHORT} = 10^{12}$ S.

```
p1 --[R1]-- n1 --[R2]-- n2 -- ... -- n(N-1) --[RN]-- p2
             |           |                      |
            C1/D1       C2/D2                  CN/DN
             |           |                      |
            ref         ref                    ref
```

## Parameters

### Model Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| K | $K$ | -- | 1.5 | $K > 1$ for geometric scaling; $K \le 1$ falls back to uniform | Propagation constant (geometric ratio between successive sections) |
| FMAX | $f_{max}$ | Hz | $10^9$ | $> 0$ | Maximum frequency of interest (used for auto-computing N) |
| RPERL | $R_{perl}$ | $\Omega$/length | 1000 | $> 0$ | Resistance per unit length |
| CPERL | $C_{perl}$ | F/length | $10^{-12}$ | $> 0$ | Capacitance per unit length |
| ISPERL | $I_{S,perl}$ | A/length | 0 | $\ge 0$ | Diode saturation current per unit length (0 = capacitor-only shunt) |
| RSPERL | $R_{S,perl}$ | $\Omega \cdot$length | 0 | $\ge 0$ | Diode series resistance per unit length |

### Instance Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| L | $L$ | length | 1.0 | $> 0$ | Physical length of the RC line |
| N | $N$ | -- | 0 (auto) | $[1, 10]$ | Number of lumped sections (0 = auto-compute from FMAX) |

### Internal Constants

| Constant | Value | Description |
|----------|-------|-------------|
| max\_sections | 10 | Maximum number of ladder sections |
| $G_{MIN}$ | $10^{-12}$ S | Minimum shunt conductance for convergence |
| $G_{SHORT}$ | $10^{12}$ S | Conductance used to short unused internal nodes to p2 |
| $V_T$ | $k_B \cdot 300.15 / q \approx 0.02586$ V | Thermal voltage at nominal 27 C |

## Equations

### Number of Sections (Auto-Compute)

When instance parameter $N = 0$, the section count is computed automatically.

$$R_{total} = R_{perl} \cdot L$$

$$C_{total} = C_{perl} \cdot L$$

$$\tau = R_{total} \cdot C_{total}$$

$$\text{arg} = \tau \cdot f_{max} \cdot 2\pi$$

$$N = \lceil \log(\text{arg}) \;/\; \log(K) \rceil$$

Clamped to $[1,\; 10]$. If $K \le 1$, $f_{max} \le 0$, $R_{perl} \le 0$, $C_{perl} \le 0$, or $L \le 0$, defaults to $N = 1$. If $\text{arg} \le 1$, defaults to $N = 1$.

When $N$ is user-specified ($N > 0$), it is rounded up and clamped to $[1, 10]$.

### Geometric Section Weight

For section $i$ ($1$-indexed) of $N$ total sections with ratio $K > 1$:

$$w_i = \frac{(K - 1) \cdot K^{i-1}}{K^N - 1}$$

The weights sum to unity: $\sum_{i=1}^{N} w_i = 1$.

Fallback for $K \le 1$ (uniform distribution):

$$w_i = \frac{1}{N}$$

### Series Resistor Chain

Total resistance distributed across the ladder:

$$R_{total} = R_{perl} \cdot L$$

Per-section resistance:

$$R_i = R_{total} \cdot w_i$$

Per-section conductance (with protection against $R_i \approx 0$):

$$G_i = \begin{cases} 1 / R_i & \text{if } R_i > 10^{-30} \\ 10^{12} & \text{otherwise} \end{cases}$$

Current through section $i$ resistor (from left node $A$ to right node $B$):

$$I_{R,i} = G_i \cdot (V_A - V_B)$$

Stamp contributions:

$$I_A \mathrel{+}= I_{R,i}, \quad I_B \mathrel{-}= I_{R,i}$$

The ladder node ordering is: $\text{p1}$ (position 0), $\text{n1} \ldots \text{n}_{N-1}$ (positions $1 \ldots N-1$), $\text{p2}$ (position $N$).

### Shunt Capacitance (Charge Contributions)

Total capacitance:

$$C_{total} = C_{perl} \cdot L$$

Per-section capacitance:

$$C_i = C_{total} \cdot w_i$$

Charge stored at section node $j$ ($j = 1 \ldots N$):

$$Q_j = C_j \cdot (V_{\text{node}_j} - V_{\text{ref}})$$

Stamp contributions:

$$Q_{\text{node}_j} \mathrel{+}= Q_j, \quad Q_{\text{ref}} \mathrel{-}= Q_j$$

The corresponding displacement current is $I_{C,j} = dQ_j / dt$, handled by the simulator's charge-based formulation.

### GMIN Shunt Conductance

At each shunt node $j$ ($j = 1 \ldots N$), a minimum conductance is applied for convergence:

$$I_{G_{MIN},j} = G_{MIN} \cdot (V_{\text{node}_j} - V_{\text{ref}})$$

where $G_{MIN} = 10^{-12}$ S.

### Shunt Diode (when ISPERL > 0)

Per-section saturation current:

$$I_{S,i} = I_{S,perl} \cdot L \cdot w_i$$

Diode voltage with exponential clamp:

$$V_{d,j} = V_{\text{node}_j} - V_{\text{ref}}$$

$$\text{arg}_j = \min\!\left(\frac{V_{d,j}}{V_T},\; 80\right)$$

Diode current (ideal Shockley equation):

$$I_{D,j} = I_{S,j} \cdot \left(e^{\text{arg}_j} - 1\right)$$

### Diode Series Resistance (when RSPERL > 0 and ISPERL > 0)

Per-section length:

$$L_i = L \cdot w_i$$

Per-section series resistance (with protection):

$$R_{S,i} = \begin{cases} R_{S,perl} / L_i & \text{if } L_i > 10^{-30} \\ 10^{30} & \text{otherwise} \end{cases}$$

Per-section series conductance (with protection):

$$G_{RS,i} = \begin{cases} 1 / R_{S,i} & \text{if } R_{S,i} > 10^{-30} \\ 10^{12} & \text{otherwise} \end{cases}$$

Approximated as a shunt conductance in parallel with the diode:

$$I_{RS,j} = G_{RS,j} \cdot (V_{\text{node}_j} - V_{\text{ref}})$$

### Total Shunt Current

The total shunt current at node $j$ from node to ref:

$$I_{\text{shunt},j} = I_{G_{MIN},j} + I_{D,j} + I_{RS,j}$$

(Diode and series resistance terms are zero when $I_{S,perl} = 0$ or $R_{S,perl} = 0$ respectively.)

Stamp contributions:

$$I_{\text{node}_j} \mathrel{+}= I_{\text{shunt},j}, \quad I_{\text{ref}} \mathrel{-}= I_{\text{shunt},j}$$

### Unused Node Shorting

When $N < 10$, internal nodes $\text{n}_N$ through $\text{n}_9$ are shorted to p2:

$$I_{\text{short},k} = G_{SHORT} \cdot (V_{\text{n}_k} - V_{\text{p2}})$$

where $G_{SHORT} = 10^{12}$ S, for $k = N, N+1, \ldots, 9$.

Stamp contributions:

$$I_{\text{n}_k} \mathrel{+}= I_{\text{short},k}, \quad I_{\text{p2}} \mathrel{-}= I_{\text{short},k}$$
