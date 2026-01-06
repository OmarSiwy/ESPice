# Ideal transmission line (Bergeron) and voltage/current switch semantics

Reference: ngspice `tra/traload.c` (T element), `sw/swload.c` (S element;
W element is the same with a branch-current control).

## 1. Mathematical specification

### 1.1 Ideal lossless line — Bergeron / method of characteristics

Parameters: characteristic impedance $Z_0$, delay $T_d$ (or f/nl),
$G_0 = 1/Z_0$. The lossless telegrapher solution reduces each port to a
Thévenin branch whose source is the *delayed reflected wave* from the
other port:

$$
\boxed{\begin{aligned}
v_1(t) - Z_0\, i_1(t) &= E_1(t) \equiv v_2(t - T_d) + Z_0\, i_2(t - T_d)\\
v_2(t) - Z_0\, i_2(t) &= E_2(t) \equiv v_1(t - T_d) + Z_0\, i_1(t - T_d)
\end{aligned}}
$$

MNA realization (traload.c): internal nodes int1/int2 and branch
currents $i_{br1}, i_{br2}$;

- conductance $G_0$ between pos1–int1 and pos2–int2 (the $Z_0$ Thévenin
  resistance);
- branch rows: $v_{int1} - v_{neg1} = E_1(t)$, i.e. row $i_{br1}$ has
  $-1$ on neg1, $+1$ on int1, RHS $E_1$; current $i_{br1}$ enters int1
  and leaves neg1;
- $E_{1,2}$ are the `input1/2` RHS values.

**DC**: the delayed sources are replaced by the exact zero-frequency
constraint — the line is transparent:
row $i_{br1}$: $-(v_{p2} - v_{n2}) - (1 - g_{min})\,Z_0\, i_{br2} = \ldots$
i.e. $v_1 - v_2 - Z_0 i_2 = 0$-type coupled equations (the $g_{min}$
factor keeps the matrix nonsingular for pathological connections).

**History**: a growing list of triples $(t_k, E_1(t_k), E_2(t_k))$
(`TRAdelays`, 3 doubles per accepted point). At MODEINITTRAN the list is
seeded with the initial values at $t \in \{-2T_d, -T_d, 0\}$ (from UIC
initial conditions or the operating point). At each new timepoint
(MODEINITPRED) the delayed values are **quadratically interpolated**:
find $t_1 \le t_2 \le t - T_d \le t_3$ in the list, Lagrange weights

$$f_j = \prod_{k \ne j}\frac{(t - T_d) - t_k}{t_j - t_k},\qquad
E_i(t) = f_1 E_i(t_1) + f_2 E_i(t_2) + f_3 E_i(t_3)$$

Timestep control (tratrunc): steps are limited so breakpoints at
$t + T_d$ (sharp input edges reflected later) are hit; ngspice registers
breakpoints when port waveforms change slope beyond a tolerance.

### 1.2 Switch — threshold + hysteresis state machine

Parameters: threshold $V_T$ (or $I_T$), hysteresis $V_H$, on/off
conductances $G_{on} = 1/R_{on}$, $G_{off} = 1/R_{off}$. Control value
$u$ = control-port voltage (S) or control branch current (W). The switch
is **piecewise-constant**: no Jacobian coupling to the control at all —
$\partial G/\partial u$ is treated as 0 (the state decision is outside
the linearization).

Four states: `REALLY_OFF`, `REALLY_ON` (outside the hysteresis window),
`HYST_OFF`, `HYST_ON` (inside the window, remembering how it got there).

**Positive hysteresis ($V_H > 0$)** — classic Schmitt behavior:

$$
\text{state}(t) = \begin{cases}
\text{ON} & u > V_T + V_H\\
\text{OFF} & u < V_T - V_H\\
\text{previous state} & \text{otherwise (window is memory)}
\end{cases}
$$

**Negative hysteresis ($V_H < 0$)** — the window $[V_T + V_H, V_T - V_H]$
is *unstable*: entering it from a rail flips the state (oscillator
primitive). Semantics per swload.c:

- $u > V_T - V_H$ ⇒ REALLY_ON; $u < V_T + V_H$ ⇒ REALLY_OFF;
- entering the window from REALLY_ON ⇒ HYST_OFF (turns off), from
  REALLY_OFF ⇒ HYST_ON (turns on); already in a HYST state ⇒ stays.

At the first timepoint / DC init, the IC (`ON`/`OFF` on the instance)
seeds REALLY_ON/OFF if $u$ is beyond the corresponding rail else the
HYST_ON/OFF state. During NR float (MODEINITFLOAT) a state change
increments `CKTnoncon` — one more Newton iteration is forced so the new
conductance is re-solved; the decision uses state0 (current) vs state1
(last accepted timepoint), so a rejected timestep rolls the state back.

Stamp: $G_{now} \in \{G_{on}, G_{off}\}$ on the 2×2 (p,n) block. Noise:
thermal $4kT G_{now}$.

There is no voltage smoothing in ngspice's S/W switch — "smoothness" is
provided only by the hysteresis window as an iteration-stabilizer.
(A continuous alternative — cubic $G(u)$ interpolation inside the window
as in some SPICE derivatives — changes convergence behavior and DC sweep
results; we deliberately match the discrete FSM.)

## 2. Flow explanation

**T line**: per timepoint, MODEINITPRED interpolates $E_{1,2}$ from the
delay list once (frozen across NR iterations — the line is linear); every
load call stamps the constant pattern and adds $E_{1,2}$ to the branch
RHS. On accept, append $(t, E_1, E_2)$. DC replaces the delayed sources
by the transparency equations. Breakpoints ensure edges launched at $t$
are resolved when they arrive at $t + T_d$.

**Switch**: per NR iteration, read the control value from the *previous
iterate* (`rhsOld`), run the FSM (§1.2) against current + last-accepted
state, write state0, stamp the resulting constant $G$. Convergence is
gated by "state stopped changing", not by derivative information. In
transient the FSM runs in the pre-convergence phase of each timepoint, so
a step that lands past a threshold flips at that timepoint (timestep
control does not bisect to the crossing; hysteresis prevents chatter).

## 3. Pseudo-code, CPU sequential

```
# ----- ideal tline -----
fn tra_timepoint_prep(hist, t, Td) -> (E1, E2):     # once per timepoint
    if t <= first accepted point: return seeded initial values
    k  = index with hist.t[k] <= t - Td < hist.t[k+1]
    (f1,f2,f3) = lagrange3(t - Td, hist.t[k-1..k+1])
    return (dot(f, hist.E1[k-1..k+1]), dot(f, hist.E2[k-1..k+1]))

fn tra_eval(x, P, E1, E2) -> residuals:             # x = [p1,n1,p2,n2,int1,int2,i1,i2]
    r[p1]  =  P.G0*(x.p1 - x.int1);   r[int1] = -r[p1] + x.i1
    r[n1]  = -x.i1
    r[i1]  =  (x.int1 - x.n1) - E1                  # branch eq (transient)
    ... port 2 symmetric ...
    # DC mode: r[i1] = -(x.p2 - x.n2) - (1-gmin)*P.Z0*x.i2 + (x.int1 - x.n1)-ish
fn tra_accept(hist, t, x, P):
    hist.push(t, (x.p2-x.n2) + P.Z0*x.i2, (x.p1-x.n1) + P.Z0*x.i1)

# ----- switch -----
fn sw_update_state(u, st, P) -> st':                # pre-NR / per iteration
    if P.vh > 0:
        st' = u > P.vt+P.vh ? ON : u < P.vt-P.vh ? OFF : st
    else:
        st' = u > P.vt-P.vh ? ON
            : u < P.vt+P.vh ? OFF
            : st in {HYST_*} ? st
            : st == ON ? HYST_OFF : HYST_ON          # window flips rail states
    if st' != st: request_extra_iteration()
fn sw_eval(x, st, P):
    g = st in {ON, HYST_ON} ? P.g_on : P.g_off
    r[p] = g*(x.p - x.n); r[n] = -r[p]              # J: ±g on 2x2 block
```

Our `switch.zig` implements exactly this FSM with `accepted_state`
bookkeeping (`stateCtl`) so rejected timesteps roll back — the analog of
ngspice's state0/state1 pair; `tline.zig` implements the Bergeron model
with the same internal-node topology and a history ring.

## 4. Pseudo-code, GPU parallel (batched SoA)

Both devices are trivial stamps once their per-timepoint scalars are
known; the sequential parts (history interpolation, FSM) are tiny and
per-instance.

```
kernel tra_batch(g, desc, blob, x, env):
    for i = g.tid; i < desc.count; i += g.stride:
        v  = gather(x, gath[i*8..])
        E1 = env_slot[i].E1; E2 = env_slot[i].E2    # host-interpolated per
                                                    # timepoint (frozen in NR)
        scatter_add_kcl(g.rhs, ..., G0-couplings, i1/i2 rows with -E1/-E2)
        if WITH_DIAG: scatter_add(g.diag, G0 & unit entries)
    # accept-time kernel (or host): push (t, v2+Z0*i2, v1+Z0*i1) per instance

kernel sw_batch(g, desc, blob, x, x_old, env):
    for i = g.tid; i < desc.count; i += g.stride:
        u  = x_old[gath_ctl[i*2]] - x_old[gath_ctl[i*2+1]]   # prev iterate
        st = state[i]                                # SoA u8 states
        st' = fsm(u, st, P)                          # branchless: two compares
                                                     # + select on vh sign
        changed |= (st' != st); state[i] = st'
        gnow = select(st' & ON_BIT, P.g_on, P.g_off)
        scatter_add(g.rhs, p/n rows, ±gnow*(v.p - v.n))
        if WITH_DIAG: scatter_add(g.diag, ±gnow)
    # grid-reduce `changed` -> force another Newton iteration (same flag
    # path as junction limiting); accepted/current state pair kept per
    # instance for timestep rollback
```

The switch FSM is 4 states × sign(vh): encode as bit tests and selects —
zero divergence. The tline delayed-source interpolation is left on the
host (per-instance scalar, once per timepoint, needs the shared accepted
history — same place the transient loop already lives).

## Noise model (in-device)

Contract: [noise-contract.md](noise-contract.md).

- **Ideal T line**: none (lossless, ngspice computes none).
- **Switch (S/W)**: thermal $4kT\,G_{eff}$ across p-n with
  $G_{eff} \in \{G_{on}, G_{off}\}$ from the FSM state -- declared in
  our `switch.zig` `noise_gens` (thermal, row 0/col 1) and collected
  today via the Jacobian path (the stamp IS $G_{eff}$, so the current
  thermal-only collection is already exact for the switch). ngspice
  itself has no switch noise routine -- our declaration is a modern
  addition, physically just Johnson noise of $R_{on}/R_{off}$.

`noisePsd`: trivial -- one white term $4kT G_{eff}(state)$; state read
from the instance, not x, which makes the switch the one device whose
PSD is discontinuous across timepoints (pnoise orbit sampling handles
it naturally).

## Sources

- https://raw.githubusercontent.com/ngspice/ngspice/master/src/spicelib/devices/tra/traload.c (fetched)
- https://raw.githubusercontent.com/ngspice/ngspice/master/src/spicelib/devices/sw/swload.c (fetched)

## Verification status

- §1.1 stamps/history/interpolation, DC form; §1.2 FSM incl. negative-hysteresis semantics and noncon behavior: **source-verified** against the fetched files.
- tratrunc breakpoint details: stated from ngspice structure, that file not fetched (**derived**).
- §3/§4: derived.

## Our implementation

- `modules/devices/src/tline.zig` (Bergeron + history), `switch.zig` (4-state FSM + accepted-state rollback via `stateCtl`), `cswitch.zig` (current-controlled twin).
- Bench fixtures: `benchmark/fixtures/tline/ideal_tline`, `delay_line`, `terminated`; `benchmark/fixtures/devices/tline`, `switch`, `switch_hysteresis`, `cswitch`.
