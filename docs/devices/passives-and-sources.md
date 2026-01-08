# Passives and sources — R, C, L, K, V/I waveforms, E/F/G/H, B, URC

Reference: ngspice `res/`, `cap/`, `ind/` (indload.c), `vsrc/`
(vsrcload.c), `urc/urcsetup.c`, `res/resnoise.c`; our implementations in
`modules/devices/src/{resistor,capacitor,inductor,kinduc,vsource,
isource,vcvs,vccs,cccs,ccvs,bsource,urc}.zig`.

## 1. Mathematical specification

### 1.1 Resistor

$$I = G\,V,\qquad G = \frac{m}{R(T)},\qquad
R(T) = R\left[1 + TC_1\Delta T + TC_2\Delta T^2\right]\ \left(\text{or } R\cdot 1.01^{TCE\,\Delta T}\right)$$

Sheet form: $R = R_{SH}\,(L - 2\,\text{NARROW}_L)/(W - 2\,\text{NARROW}_W)$.
AC-variant: separate `ac` resistance used only in AC analyses (our
resistor.zig carries both; ngspice `RESacResist`). Zero/negative $R$ is
clamped to a large conductance, never a hard short.

### 1.2 Capacitor / inductor — charge/flux form

$$Q = C\,V \qquad\text{(capacitor, charge on the two terminals, } \pm Q)$$

Inductor: branch-current unknown $I_{br}$ (row is the KVL equation).
**Flux-sign convention** (this week's kinduc fix, `inductor.zig`/
`kinduc.zig`): the solver forms $F = I(x) + \frac{dq}{dt}$, and the
inductor's branch row is $V_p - V_n - L\frac{dI_{br}}{dt} = 0$, so the
flux stored in the *q function* must be **negative**:

$$q_{br} = -L\,I_{br}\quad\Rightarrow\quad F_{br} = (V_p - V_n) + \frac{d}{dt}(-L I_{br})$$

### 1.3 Mutual inductance (K element, kinduc.zig)

Two current unknowns (the coupled inductors' branch currents), zero
`eval`, pure cross-flux with the **same negative sign**:

$$q_{br1} = -M\,I_{br2},\qquad q_{br2} = -M\,I_{br1},\qquad
M = k\sqrt{L_1 L_2}$$

(the netlist layer resolves $k \to M$ at build time since only it knows
$L_1, L_2$). Each term time-differentiates into $-M\,dI_{other}/dt$ in
the partner inductor's KVL row — matching ngspice MUTload's companion
stamp. Getting either sign positive flips the coupling polarity and
breaks passivity (the week's bug).

### 1.4 Independent sources V/I — waveforms and breakpoints

MNA: V-source adds a branch-current unknown with rows
$\pm 1$ (p/n vs branch) and branch equation $V_p - V_n = E(t)$;
I-source injects $\pm I(t)$ directly. Waveform value $E(t)$
(type-identical for V and I; ngspice vsrcload.c, our vsource.zig):

| Waveform | Value |
|---|---|
| PULSE(v1 v2 td tr pw tf per) | trapezoid: $v_1$ until $t_d$; linear rise over $t_r$; $v_2$ for $p_w$; linear fall over $t_f$; period `per` (defaults: tr/tf = tstep, pw/per = tstop-ish; our impl: pw<0 ⇒ ∞, per ≥ tr+pw+tf) |
| SIN(vo va freq td theta phase) | $v_o$ for $t<t_d$; else $v_o + v_a e^{-(t-t_d)\theta}\sin(2\pi f (t-t_d) + \phi)$ |
| EXP(v1 v2 td1 tau1 td2 tau2) | $v_1 + (v_2-v_1)(1-e^{-(t-t_{d1})/\tau_1})$ for $t>t_{d1}$, plus $(v_1-v_2)(1-e^{-(t-t_{d2})/\tau_2})$ for $t>t_{d2}$ |
| PWL(t₁ v₁ t₂ v₂ … [r=, td=]) | linear interpolation; flat before first / after last point; `td` shifts, `r` repeats from time r |
| SFFM(vo va fc mdi fs) | $v_o + v_a\sin(2\pi f_c t + m_{di}\sin(2\pi f_s t))$ |
| AM(va oc fm fc td) | $v_a(o_c + \sin(2\pi f_m(t-t_d)))\sin(2\pi f_c(t-t_d))$ |

**Breakpoint semantics** (drives the transient step controller; our
`nextBreakpoint`, mirroring ngspice's CKTsetBreak calls): PULSE
registers every edge of the current cycle
($t_d,\ +t_r,\ +p_w,\ +t_f$, next period); PWL registers every corner
($t_i + t_d$); EXP registers $t_{d1}, t_{d2}$; SIN/AM only the delay
(smooth after); SFFM none. Breakpoints force the integrator to land
exactly on derivative discontinuities — miss one and LTE control eats
the corner.

AC small-signal: separate (acmag, acphase) phasor, independent of the
transient waveform. DC/OP: the `dc` value (or waveform value at t=0).

### 1.5 Linear controlled sources E/F/G/H

| El | Type | Equation | Extra unknown |
|---|---|---|---|
| E (vcvs) | V = e·V_c | branch row $V_p - V_n - e\,(V_{cp}-V_{cn}) = 0$ | branch current |
| G (vccs) | I = g·V_c | inject $\pm g(V_{cp}-V_{cn})$ | none |
| F (cccs) | I = f·I_c | inject $\pm f\,I_{br,ctrl}$ (couples to the controlling V-source's branch unknown) | none |
| H (ccvs) | V = h·I_c | branch row $V_p - V_n - h\,I_{br,ctrl} = 0$ | branch current |

All four are constant stamps — pure Jacobian entries, no bias
dependence, no limiting, no charge.

### 1.6 B-source (arbitrary expression)

$V = f(V_{ctrl}, I_{ctrl}, t)$ or $I = f(\ldots)$; the expression's
partial derivatives stamp like a nonlinear controlled source. Our
`bsource.zig` implements the polynomial subset
$f = c_0 + c_1 V_c + c_2 V_c^2$ over one control pair (with a
branch-current unknown in V mode) — a deliberate ceiling; full
expression trees (ngspice B/ASRC with arbitrary parse trees) need an
expression-VM device or codegen (the VA pipeline is the natural route).

### 1.7 URC — lumped RC ladder expansion rule (urcsetup.c)

The URC element *expands at setup* into a geometric R–C (or R–diode
when ISPERL given) ladder. With total $R_0 = R_{perL}\ell$,
$C_0 = C_{perL}\ell$, ratio $p = K$ (default 2 in ngspice, 1.5 our
default):

$$N = \max\!\left(3,\ \frac{\ln\!\left[2\pi f_{max} R_0 C_0\left(\frac{p-1}{p}\right)^2\right]}{\ln p}\right)
\quad(N = 3 \text{ if } 2\pi f_{max}R_0C_0 < 35)$$

First-lump values, growing geometrically ($\times p$ per section,
symmetric halves at the ends — the 2 in the denominators):

$$R_1 = \frac{R_0(p-1)}{2(p^N - 1)},\qquad
C_1 = \frac{C_0(p-1)}{p^{N-1}(p+1) - 2}$$

(diode ladder: saturation currents $I_1$ scale like $C_1$). Our
`urc.zig` bakes the same rule into a fixed-topology device (≤10
sections, 9 internal nodes): section weight
$w_i = p^i\,(p-1)/(p^N - 1)$.

## 2. Flow explanation

All of these are linear or explicitly-evaluated devices: no limiting,
no internal Newton, no bypass logic. Per iteration: R/E/F/G/H stamp
constants; C/L/K contribute only through q (companion terms added by
the integrator); V/I evaluate $E(t)$ once per timepoint (t frozen
across NR) and stamp constant rows + RHS. The only transient-loop
coupling is the breakpoint hook (§1.4) and, for URC, the one-time
expansion. State: none (V/I waveform is a pure function of t; PWL keeps
an index hint only as an optimization).

## 3. Pseudo-code, CPU sequential

```
fn resistor_eval(x, P):   i = P.g*(x.p - x.n);  J = ±P.g on 2x2
fn capacitor_q(x, P):     q = P.c*(x.p - x.n);  C = ±P.c on 2x2
fn inductor(x, P):        # rows: p, n, br
    I[p] =  x.br; I[n] = -x.br
    I[br] = x.p - x.n                 # KVL residual
    Q[br] = -P.l * x.br               # flux, NEGATIVE (see §1.2)
fn kinduc_q(x, P):        Q[br1] = -P.m*x.br2;  Q[br2] = -P.m*x.br1
fn vsource(x, P, t):
    e = waveform_value(P, t)          # table §1.4
    I[p] = x.br; I[n] = -x.br; I[br] = (x.p - x.n) - e
fn vcvs(x, P):            I[br] = (x.p - x.n) - P.gain*(x.cp - x.cn); ...
fn bsource(x, P):
    f  = P.c0 + P.c1*vc + P.c2*vc*vc  # ponytail ceiling: poly subset
    V-mode: branch row (x.p - x.n) - P.factor*f;  I-mode: inject ±factor*f
fn urc: fixed ladder of N sections, R_i = R1*p^i, C_i = C1*p^i stamps
```

## 4. Pseudo-code, GPU parallel (batched SoA)

Trivial stamps; the only care is the V/I waveform evaluation, which is
`t`-dependent but x-independent — hoist per timestep:

```
kernel linear_batch(g, desc, blob, x, env):     # R/E/F/G/H/C/L/K share shape
    for i = g.tid; i < desc.count; i += g.stride:
        v = gather(x, gath[i*NU..])
        scatter_add(g.rhs,  gath, stamp(v, P[i]) + env.alpha*q(v, P[i]) + hist)
        if WITH_DIAG: scatter_add(g.diag, consts(P[i]))

kernel vsrc_batch(..., t):
    e = waveform_value(P[i], t)       # branchless per-kind switch is
                                      # warp-uniform if batches keyed on kind
    scatter_add(rhs, [x.br, -x.br, (x.p-x.n) - e])
# breakpoints: host-side (nextBreakpoint hook already runs on CPU in the
# transient loop; not a device-kernel concern)
```

## Noise model (in-device)

Contract: [noise-contract.md](noise-contract.md).

| Device | Generator (`noise_gens`) | PSD | ngspice source |
|---|---|---|---|
| Resistor | thermal, p–n | $4kT\,G\,m$ | resnoise.c:124 (verified) |
| Resistor (opt.) | flicker, p–n | $m\,K_F\,|I_R|^{A_F}/f$ (NOISE=1, fNcoef given) | resnoise.c:128–139 (verified) |
| C, L, K | — | none (reactive) | none exists |
| V/I, E/F/G/H, B | — | none (ideal sources are noiseless in SPICE) | none exists |
| URC | thermal per expanded R lump | $4kT/R_i$ each | via expansion into real resistors (ngspice); our fixed ladder should declare one thermal gen per section |

`noisePsd` hook: resistor emits one white term $4kTG m$
(+ optional flicker term with $I_R = G(V_p - V_n)$ from the gathered
x — bias-dependent, which is exactly why the hook takes x). CPU/GPU:
the generic collection pass in noise-contract.md §3 — nothing
device-specific beyond the two formulas. What ngspice computes vs
modern: identical; there is no more physics to add for ideal passives.

## Sources

- https://raw.githubusercontent.com/ngspice/ngspice/master/src/spicelib/devices/urc/urcsetup.c (fetched)
- https://raw.githubusercontent.com/ngspice/ngspice/master/src/spicelib/devices/res/resnoise.c (fetched)
- https://raw.githubusercontent.com/ngspice/ngspice/master/src/spicelib/devices/vsrc/vsrcload.c (fetched)
- https://raw.githubusercontent.com/ngspice/ngspice/master/src/spicelib/devices/ind/indload.c (fetched)
- In-tree: `resistor.zig`, `inductor.zig`, `kinduc.zig` (flux-sign comments), `vsource.zig` (waveforms + nextBreakpoint), `urc.zig` (geometric weights + tests).

## Verification status

- Resistor noise, URC expansion rule ($N$, $R_1$, $C_1$), V-source stamp, mutual-flux sign: **source-verified** (fetched files / in-tree code with unit tests).
- Waveform table and breakpoint list: verified against our vsource.zig (which mirrors ngspice); ngspice breakpoint registration code (`CKTsetBreak` call sites) not fetched — **derived** at that level.
- Temp-scaling forms (TC1/TC2/TCE), cap/ind temp variants: standard SPICE, stated from our impl — derived.

## Our implementation

- `modules/devices/src/{resistor,capacitor,inductor,kinduc,vsource,isource,vcvs,vccs,cccs,ccvs,bsource,urc}.zig`.
- Bench fixtures: `devices/resistor*`, `capacitor*`, `inductor*`, `kinduc`, `vsource`, `isource`, `vcvs`, `vccs`, `cccs`, `ccvs`, `bsource`, `urc`, `urc_ac`; `basic/*`, `ac/*`.
