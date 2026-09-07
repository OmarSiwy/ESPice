# LTRA lossy transmission line — recursive convolution (Roychowdhury/Pederson)

Reference: ngspice `ltra/ltraload.c`, `ltra/ltramisc.c`, `ltra/ltraset.c`,
`ltra/ltradefs.h` (author: Jaijeet Roychowdhury; the code implements
Roychowdhury & Pederson, "Efficient transient simulation of lossy
interconnect", DAC 1991 — paper itself paywalled, not fetched; the
ngspice comments/structure are the working spec). **Status: landed** as
`src/devices/ltra_native.zig` (O card): `tline/ltra1_1_line` max 3.5e-3 /
rms 3.7e-4, `ltra2_2_line` 1.0e-4 / 6.6e-6, `devices/lossy_tline` 5.8e-15
against ngspice 44.2. The residual on ltra1 is tran grid-phase noise (see
docs/analysis/transient-integration.md, per-row LTE note), not the
convolution.

## 1. Mathematical specification

### 1.1 Line classification (LTRAsetup)

Per-length R, L, G, C and length $\ell$. Supported special cases:

| Case | Condition | Method |
|---|---|---|
| LC | R=0, G=0 | pure delay (lossless, Bergeron-like with history interpolation) |
| RLC | R>0, G=0 | delay + Bessel-kernel convolution |
| RC | R>0, L=0, G=0 | diffusive (erfc/√t kernels), no delay |
| RG | R>0, G>0, L=C=0 | pure resistive two-port (exact hyperbolic DC solution) |
| RL, general G | — | rejected (E_BADPARM) |

At least two of R, L, G, C must be nonzero.

### 1.2 Derived constants (RLC, G = 0)

$$Z_0 = \sqrt{L/C},\quad Y_0 = \sqrt{C/L}\ (\texttt{admit}),\quad
T = \ell\sqrt{LC}\ (\texttt{td}),\quad
\alpha = \beta = \frac{R}{2L},\quad
A = e^{-\beta T}\ (\texttt{attenuation})$$

RC case: $c_{byr} = C/R$, $rcl^2 = R\,C\,\ell^2$ (`rclsqr`).

### 1.3 Two-port formulation

Unknowns: port voltages $v_1, v_2$ (pos−neg per port) and two branch
currents $i_1, i_2$ (extra MNA rows `brEq1/2`). The Roychowdhury–Pederson
formulation writes each port's characteristic relation as instantaneous
part + convolution of *port histories* with three impulse-response
kernels $h_1'(t)$, $h_2(t)$, $h_3'(t)$ ("tilde" kernels in the paper —
the primes denote that the raw kernels' impulsive parts have been
separated):

**Branch equation, port 1** (port 2 symmetric, $1\leftrightarrow 2$):

$$Y_0\,v_1(t) + Y_0\,(h_1' * v_1)(t) - i_1(t)
\;=\; (h_2 * i_2)(t) + Y_0\,(h_3' * v_2)(t)$$

For the RLC case the $t-T$ endpoints of the delayed convolutions and the
lossless part are pulled out explicitly; the load stamps

- matrix: $\pm Y_0(1 + c^{(1)}_{h_1'})$ on the $v_1$ columns of row
  $i_{br1}$, $-1$ on its own current, symmetric for port 2 (the first PWL
  convolution coefficient $c^{(1)}$ multiplies the *present* unknown, so
  it belongs in the Jacobian);
- RHS (`input1`): all remaining history terms —
  $-Y_0\sum_{i>1} c^{(i)}_{h_1'}\,\tilde v_1(t_i)$
  $+\sum c^{(i)}_{h_2}\,\tilde i_2(t_i)$
  $+Y_0\sum c^{(i)}_{h_3'}\,\tilde v_2(t_i)$
  $+A\left[Y_0\,v_2(t-T) + i_2(t-T)\right]$ (lossless part; before
  $t\le T$ the initial values are used instead),
  where $\tilde x = x - x(0^+)$ and each initial value contributes
  through the precomputed total kernel integrals
  $\int_0^\infty h\,d\tau$ (`intH1dash`, `intH2`, `intH3dash`).

RC case: same structure minus the delay/lossless terms; $Y_0$ replaced by
1 (kernels carry the admittance dimension); additionally $h_2$ and $h_3'$
couple through the matrix first-coefficients (their kernels are nonzero
at $t\to 0^+$).

**DC**: RLC/LC/RC reduce to a series resistance
($i_1 + i_2 = 0$; $v_1 - v_2 = R\ell\,i_1$). RG uses the exact
hyperbolic two-port:

$$\cosh(\ell\sqrt{RG}),\qquad
\sinh(\ell\sqrt{RG})\sqrt{R/G}\ (\texttt{rRsLrGRorG}),\qquad
\sinh(\ell\sqrt{RG})\sqrt{G/R}\ (\texttt{rGsLrGRorR})$$

stamped as: $v_1 - \cosh(\ell\sqrt{RG})\,v_2 + (1+g_{min})\sqrt{R/G}\sinh(\cdot)\,i_2 = 0$ and the symmetric second row.

### 1.4 The kernels (source-verified, ltramisc.c)

RLC ($x \equiv \alpha\sqrt{t^2 - T^2}$; $I_0, I_1$ modified Bessel
functions, evaluated by the Numerical-Recipes polynomial fits):

$$h_1'(t) = \alpha\,e^{-\beta t}\left[I_1(\alpha t) - I_0(\alpha t)\right] \qquad (t \ge 0)$$

$$h_2(t) = \begin{cases}0 & t < T\\
\alpha^2 T\, e^{-\beta t}\,\dfrac{I_1(x)}{x} & t \ge T\end{cases}$$

$$h_3'(t) = \begin{cases}0 & t < T\\
\alpha\,e^{-\beta t}\left[\alpha t\,\dfrac{I_1(x)}{x} - I_0(x)\right] & t \ge T\end{cases}$$

Repeated integrals used by the coefficient setup (G = 0 ⇒ $\beta$ only):

$$\iint h_1' = t\,e^{-\beta t}\left[I_0(\beta t) + I_1(\beta t)\right] - t,\qquad
\int h_3' = e^{-\beta t} I_0\!\left(\beta\sqrt{t^2-T^2}\right) - e^{-\beta T}\ (t>T)$$

RC kernels are given directly as *twice-integrated* closed forms:

$$\iint h_1' = \sqrt{\frac{4 (C/R)\,t}{\pi}},\qquad
\iint h_2 = \left(t + \frac{rcl^2}{2}\right)\mathrm{erfc}\sqrt{q} - \sqrt{\frac{t\,rcl^2}{\pi}}\,e^{-q},\qquad q = \frac{rcl^2}{4t}$$
$$\iint h_3' = \sqrt{C/R}\left[2\sqrt{t/\pi}\,e^{-q} - \sqrt{rcl^2}\,\mathrm{erfc}\sqrt{q}\right]$$

### 1.5 Piecewise-linear convolution coefficients

Given history samples at accepted timepoints $t_0 < \dots < t_n$
($t_{n+1} = $ now) and inputs assumed PWL between samples, each
convolution $(h * x)(t)$ becomes $\sum_i c_i\,x(t_i)$. The $c_i$ are
built from *repeated integrals* of the kernel so that the PWL weighting
is exact:

- $h_1'$ (impulsive at 0, integrable tail): the code uses first
  differences of $\iint h_1'$ over each history interval divided by the
  interval length: with $H(t) = \iint_0^t h_1'$,
  $d_i = \frac{H(t_{now}-t_{i-1}) - H(t_{now}-t_i)}{t_i - t_{i-1}}$ and
  $c_i = d_i - d_{i+1}$; the first coefficient $c^{(1)} = d_{n+1}$
  multiplies the present value and goes into the matrix.
- $h_2$: kernel itself is sampled and treated PWL; coefficients use
  `twiceintlinfunc`/`intlinfunc` (exact double/single integrals of a
  linear segment) of the kernel values at interval endpoints; only
  intervals older than the delay ($t_{now} - t_i \ge T$, index
  `auxindex`) contribute; the $t-T$ endpoint value enters through the
  interpolated delayed current $i_2(t-T)$ times the first coefficient.
- $h_3'$: same with single integrals ($\int h_3'$).

**Coefficient truncation (compaction of the kernel):** the setup loops
newest→oldest and permanently stops computing a kernel's coefficients
(`doh1/doh2/doh3 = 0`, remaining $c_i = 0$) once
$|c_i| < \texttt{chopReltol}\cdot|c^{(1)}|$ — the recursive-convolution
cost then stops growing with simulation length for decaying kernels.

**History compaction (trytocompact):** after each accepted timepoint,
`LTRAstraightLineCheck(x_1,y_1,x_2,y_2,x_3,y_3)` computes the triangle
area of three consecutive history points against
`reltol·(quad areas)+abstol`; collinear-enough middle points are deleted
from the shared $v_1, v_2, i_1, i_2$ history lists (the area criterion is
used because the history only ever enters through integrals).

### 1.6 Delayed-value interpolation

$v_{1,2}(t-T)$, $i_{1,2}(t-T)$ are interpolated from the history:
quadratic Lagrange over $(t_{i-1}, t_i, t_{i+1})$ straddling $t-T$
(`LTRAquadInterp`), falling back to linear (`LTRAlinInterp`) when
`howToInterp` = lin, at the first interval, or (mixed mode) when the
quadratic result falls outside $[\min, \max]$ of the three samples
(overshoot guard). `trytocompact` forces linear.

### 1.7 LTE and step control

`LTRAlteCalculate` estimates each branch equation's local truncation
error from the *first-coefficient moments*: for each kernel a term
$\left|\frac{d^2 x}{dt^2}\right|\cdot\left(\tfrac{1}{2}f_{1i}\,\delta t - g_{1i}\right)$
where $f_{1i}, g_{1i}$ are single/double integrals of the kernel over the
newest interval and the second derivative is a divided-difference of the
convolved history variable ($Y_0$-weighted for voltage kernels; the
delayed terms use the interval at $t-T$). `lteConType`
full/half/nocontrol selects whether this feeds timestep rejection.
Additionally `stepLimit` caps $\Delta t \le \texttt{nl}\cdot T$ (default
0.25 of the delay) unless `nosteplimit`; LC lines warn when
$\Delta t > T$.

## 2. Flow explanation

Per timepoint (not per NR iteration — the line is linear, so convolution
inputs are frozen at the first iteration of each timepoint):

1. **MODEINITTRAN/INITPRED, per model**: rebuild the coefficient lists
   $c_i$ for $h_1', h_2, h_3'$ against the accepted-timepoint list
   (`LTRArlcCoeffsSetup` / `LTRArcCoeffsSetup`), find `auxindex` (last
   index older than $t-T$), and locate + interpolate the delayed values
   $v_{1,2}(t-T), i_{1,2}(t-T)$.
2. **Per instance, every load call**: stamp the constant matrix pattern
   (§1.3) — including the convolution first-coefficients.
3. **Per instance, first iteration only**: compute `input1/input2` — the
   full history convolutions with initial-condition corrections
   ($\tilde x = x - x(0)$ plus $x(0)\int h$) and the attenuated lossless
   part — and add to the two branch-equation RHS entries every iteration
   thereafter (values cached on the instance).
4. **On accept** (`ltraacct.c`): append $v_1, v_2, i_1, i_2$ to the
   history, optionally compact (straight-line test), evaluate LTE for
   the next step size.

MODEINITTRAN also snapshots initial port conditions
(`initVolt/initCur`). The device carries no nonlinear state; all "state"
is the shared timepoint list + per-instance history vectors.

## 3. Pseudo-code, CPU sequential

```
# per model, once per timepoint (history: arrays over accepted points)
fn ltra_coeffs(now, times[0..n], P) -> (c1[3], coeffs[3][..], auxindex):
    RLC: c1.h1 = IIH1(now - times[n]) / (now - times[n])       # §1.5
         for i = n..1:  d_i via IIH1 differences; coeffs.h1[i] = d_i - d_prev
                        stop when |coeff| < chopReltol*c1.h1
         auxindex = last i with now - times[i] >= T
         h2/h3 over i <= auxindex via PWL-kernel double/single integrals

fn ltra_rhs_inputs(hist, init, delayed, coeffs, P) -> (in1, in2):
    conv1v = Σ_i coeffs.h1[i]*(hist.v1[i] - init.v1) + init.v1*P.intH1 - init.v1*c1.h1
    conv2i = c1.h2*(delayed.i2 - init.i2) + Σ coeffs.h2[i]*(hist.i2[i]-init.i2) + init.i2*P.intH2
    conv3v = c1.h3*(delayed.v2 - init.v2) + Σ coeffs.h3[i]*(hist.v2[i]-init.v2) + init.v2*P.intH3
    in1 = -P.Y0*conv1v + conv2i + P.Y0*conv3v
          + P.atten*(P.Y0*delayed.v2 + delayed.i2)     # (init values if t<=T)
    in2 = mirror(1<->2)

fn ltra_stamp(J, rhs, x, c1, in1, in2, P):     # every NR iteration
    row i1: +P.Y0*(1+c1.h1) on (vp1,-vn1); -1 on i1; rhs += in1
    row i2: symmetric;                                rhs += in2
    rows vp1/vn1: ±1 on i1;  vp2/vn2: ±1 on i2
```

A native port in our contract: the branch rows are `current` unknowns;
`eval` returns the affine residual using the frozen per-timepoint
`(c1, in1, in2)`; history append/compaction hooks ride the accepted-step
callback (same infrastructure `tline.zig` uses for its delay buffer).

## 4. Pseudo-code, GPU parallel (batched SoA)

The per-timepoint coefficient setup is shared per *model* and inherently
sequential in history — compute host-side (or one thread per model),
upload `(c1, intH, coeffs[])` with the timestep env. The per-instance
work is two dot products over the history window.

```
# host, per accepted timepoint: build coeffs per model, compact history,
# upload history SoA {v1,v2,i1,i2}[model][0..n] and coeff arrays.

kernel ltra_batch(g, desc, blob, x, env):
    for inst = g.tid; inst < desc.count; inst += g.stride:
        m   = model_of[inst]
        C   = coeffs[m]                    # h1/h2/h3 lists + firsts + intH
        H   = history[inst]                # per-instance port histories
        # dot products: lengths differ per model but are warp-uniform
        conv = pwl_convolutions(C, H, init[inst], delayed[inst])
        in1, in2 = combine(conv, P.Y0, P.atten)

        v = gather(x, gath[inst*8..])      # p1 n1 p2 n2 i1 i2 (+2 unused)
        r_i1 = P.Y0*(1+C.c1h1)*(v.p1-v.n1) - v.i1 + in1
        r_i2 = P.Y0*(1+C.c1h1)*(v.p2-v.n2) - v.i2 + in2
        scatter_add(g.rhs, rows(i1,i2,p1,n1,p2,n2), [r_i1, r_i2, v.i1, -v.i1, v.i2, -v.i2])
        if WITH_DIAG: scatter_add(g.diag, ..., [Y0*(1+c1h1), Y0*(1+c1h1), ...])
```

The history dot product is the only O(history) cost; chopReltol
truncation bounds it. If instances of one model dominate, a cooperative
variant (one block per instance, tree-reduced dot product) beats
thread-per-instance; not needed below ~10³ history points.

## Noise model (in-device)

None. ngspice computes no LTRA noise (no ltranoise.c); the line is
treated as noiseless despite its resistive loss. Contract
([noise-contract.md](noise-contract.md)): `noise_gens = {}`. A
physical treatment would distribute $4kT R\,dz$ sources through the
convolution kernels -- research-grade, no reference implementation;
derived, deferred.

## Sources

- https://raw.githubusercontent.com/ngspice/ngspice/master/src/spicelib/devices/ltra/ltraload.c (fetched)
- https://raw.githubusercontent.com/ngspice/ngspice/master/src/spicelib/devices/ltra/ltramisc.c (fetched — kernels, coefficient setup, straight-line check, LTE)
- https://raw.githubusercontent.com/ngspice/ngspice/master/src/spicelib/devices/ltra/ltraset.c, ltradefs.h, ltratrun.c (fetched)
- Roychowdhury & Pederson, DAC'91 (https://dl.acm.org/doi/10.1145/127601.127727) — **paywalled, not fetched**; formulation reconstructed from the implementing source.

## Verification status

- §1.1–1.6, §2: **source-verified** against the fetched ngspice files (kernels quoted verbatim from ltramisc.c).
- §1.2 constants (`alpha/beta/admit/attenuation/intH*` closed forms): names and roles verified from usage; the ltratemp.c closed forms **not fetched** — derived from standard RLC line theory (marked: derive $\int_0^\infty h\,d\tau$ before implementing; for $h_1'$ it is $A\cdot$-related, check ltratemp.c).
- §1.7 LTE: structure source-verified (ltramisc.c LTRAlteCalculate); constant factors not re-derived.
- §3/§4: derived.

## Our implementation

- Today: `src/devices/models/lossy_tline.va` — lumped RLGC pi (header comment documents the divergence, TRIAGE C4); `coupled_tlines.zig` for CPL.
- Upgrade target: recursive convolution per this doc, reusing `tline.zig`'s history-buffer infrastructure.
- Bench fixtures: `benchmark/fixtures/devices/lossy_tline`, `benchmark/fixtures/tline/ltra1_1_line`, `ltra2_2_line` (rms ~2e-3 with Bergeron cascade today).
