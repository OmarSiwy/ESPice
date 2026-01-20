# HICUM/L2 — transfer current (GICCR) and critical current ICK

Reference: HICUM/L2 v2.4.0 manual (Schröter & Pawlak, TU Dresden, March
2017), §2.2 "Quasi-static transfer current" and §2.3.1 (ICK). Scope per
the wants list: the transfer-current core and $I_{CK}$; the full transit
time / charge partition (§2.3 of the manual) is only sketched where the
transfer current needs it.

## 1. Mathematical specification

### 1.1 GICCR basic form

The Generalized Integral Charge-Control Relation gives the 1D transfer
current between internal nodes B′, E′, C′ (eq. 2.2.0-1/-2):

$$\boxed{i_T = \frac{c_{10}}{Q_{p,T}}\left[\exp\!\left(\frac{v_{B'E'}}{V_T}\right) - \exp\!\left(\frac{v_{B'C'}}{V_T}\right)\right]},\qquad
c_{10} = (qA_E)^2 V_T\,\overline{\mu_{nB}n_{iB}^2}$$

with the conventional saturation current $I_S = c_{10}/Q_{p0}$
(eq. 2.2.0-4). Split (2.2.0-6/-7):

$$i_{Tf} = \frac{c_{10}}{Q_{p,T}}e^{v_{B'E'}/V_T},\qquad i_{Tr} = \frac{c_{10}}{Q_{p,T}}e^{v_{B'C'}/V_T},\qquad i_T = i_{Tf} - i_{Tr}$$

### 1.2 Weighted hole charge

(2.2.0-3):

$$\boxed{Q_{p,T} = Q_{p0} + h_{jEi}Q_{jEi} + h_{jCi}Q_{jCi} + Q_{f,T} + Q_{r,T}}$$

- $Q_{p0}$: zero-bias hole charge (model parameter).
- $Q_{jEi}, Q_{jCi}$: BE/BC depletion charges; weight factors $h$ capture
  HBT bandgap differences: $h_{jCi} \approx e^{-a_G w_{B0}/V_T}$
  (2.2.0-9); $h_{jEi}$ is bias dependent (2.2.0-10/-11):

$$h_{jEi}(v_{B'E'}) = h_{jEi0}\,\frac{e^{u}-1}{u},\qquad
u = a_{hjEi}\left[1 - \left(1 - \frac{v_j}{V_{DEi}}\right)^{z_{Ei}}\right]$$

  with $v_j$ the smooth-limited junction voltage (2.2.0-14/-15): upper
  limit toward $V_{DEi}$ through
  $v_{j,upp} = V_{DEi} - r_{hjEi}V_T\frac{x_{upp}+\sqrt{x_{upp}^2+a_{fi}}}{2}$,
  $x_{upp} = \frac{V_{DEi}-v_{B'E'}}{r_{hjEi}V_T}$, and a lower smoothing at
  $v_{B'E'} = 0$; $a_{fi} = 1.921812$.
- Weighted forward minority charge (2.2.0-8):
  $Q_{f,T} = h_{f0}Q_{f0} + h_{fE}\Delta Q_{Ef} + \Delta Q_{Bf} + h_{fC}\Delta Q_{Cf}$
  with $h_{fE} = \overline{\mu_{nB}n_{iB}^2}/\overline{\mu_{nE}n_{iE}^2}$,
  $h_{fC} = \overline{\mu_{nB}n_{iB}^2}/\overline{\mu_{nC}n_{iC}^2}$ (2.2.0-16);
  $Q_{r,T} = Q_r$ (unweighted).
- HBT non-ideality: $i_{Tf}$ optionally uses $m_{Cf}V_T$ in the exponent (2.2.0-17).

### 1.3 High-current correction and final form

Collector current spreading is folded into the pre-factor (2.2.0-18/-19):

$$c_1 = c_{10}\left(1 + \frac{i_{Tf1}}{I_{CH}}\right),\qquad
i_{Tf1} = \frac{c_{10}}{Q_{p,T}}e^{v_{B'E'}/(m_{Cf}V_T)} = I_S\frac{Q_{p0}}{Q_{p,T}}e^{v_{B'E'}/(m_{Cf}V_T)}$$

giving the explicit final forward component (2.2.0-20/-21/-22):

$$\boxed{i_{Tf} = i_{Tf1}\left(1 + \frac{i_{Tf1}}{I_{CH}}\right),\qquad i_T = i_{Tf} - i_{Tr}}$$

($i_{Tr}$ keeps $c_1 = c_{10}$.)

### 1.4 Punch-through guard and the implicit solve

Low-current hole charge (2.2.0-23):
$Q_{pT,j} = Q_{p0} + h_{jEi}Q_{jEi} + h_{jCi}Q_{jCi}$, which reverse bias
can drive toward 0. It is floored at $Q_{B,rt} = 0.05\,Q_{p0}$ by the
hyperbolic smoothing (2.2.0-24):

$$Q_{pT,low} = Q_{B,rt}\left(1 + \frac{x + \sqrt{x^2 + a}}{2}\right),\qquad
x = \frac{Q_{pT,j}}{Q_{B,rt}} - 1,\quad a = 1.921812$$

Since $Q_{f,T}(i_{Tf})$ and $Q_r(i_{Tr})$ depend on the currents, the
GICCR is **implicit in $Q_{p,T}$**. HICUM solves it by an internal
Newton–Raphson on $Q_{p,T}$. With current-independent transit times it
collapses to a quadratic with the explicit root (2.2.0-25):

$$Q_{p,T} = \frac{Q_{pT,low}}{2} + \sqrt{\left(\frac{Q_{pT,low}}{2}\right)^2 + \tau_{f0}\,c_{10}\,e^{v_{B'E'}/(m_{Cf}V_T)} + \tau_r\,c_{10}\,e^{v_{B'C'}/V_T}}$$

which also serves as the initial guess
$Q_{p,T}^{(0)} = Q_{pT,low} + \tau_{f0}i_{Tf} + \tau_r i_{Tr}$ (2.2.0-26)
for the full iteration.

### 1.5 Effective collector voltage and low-current transit time

The transit-time/ICK machinery runs on a smoothed internal CE voltage
(2.3.1-3/-4), $v_c = v_{C'E'} - V_{C'E's}$
($V_{C'E's} \approx V_{DEi} - V_{DCi}$, model parameter):

$$v_{ceff} = V_T\left[1 + \frac{u + \sqrt{u^2 + a_{vceff}}}{2}\right],\qquad
u = \frac{v_c - V_T}{V_T},\quad a_{vceff} = 1.921812$$

($v_{ceff} \to v_c$ for $v_c \gtrsim 2V_{C'E's}$, $\to V_T$ for negative
$v_c$). Low-current transit time (2.3.1-5), with
$1/c = C_{jCi,t}(v_{B'C'})/C_{jCi0}$ (BC depletion cap evaluated with
infinite punch-through voltage):

$$\tau_{f0}(v_{B'C'}) = \tau_0 + \Delta\tau_{0h}(c - 1) + \tau_{Bvl}\left(\frac{1}{c} - 1\right),\qquad Q_{f0} = \tau_{f0}\,i_{Tf}$$

### 1.6 Critical current ICK

Onset of high-current (Kirk) effects (2.3.1-7):

$$\boxed{I_{CK} = \frac{v_{ceff}}{r_{Ci0}}\;
\frac{1}{\left[1 + \left(\dfrac{v_{ceff}}{V_{lim}}\right)^{\delta_{ck}}\right]^{1/\delta_{ck}}}\;
\left[1 + \frac{x + \sqrt{x^2 + a_{ick}}}{2}\right]},\qquad
x = \frac{v_{ceff} - V_{lim}}{V_{PT}}$$

with smoothing parameter $a_{ick}$ (default $10^{-3}$). Physics-based
parameter relations (2.3.1-8/-9/-10) — treated as independent model
parameters for extraction flexibility:

$$r_{Ci0} = \frac{w_C}{q\mu_{nC0}N_{Ci}A_E}\frac{1}{f_{cs}},\qquad
V_{lim} = \frac{v_{sn}}{\mu_{nC0}}w_C,\qquad
V_{PT} = \frac{qN_{Ci}}{2\varepsilon}w_C^2$$

($v_{sn}$ electron saturation velocity, $\mu_{nC0}$ low-field mobility,
$f_{cs}$ current-spreading factor). Behavior: ohmic $v_{ceff}/r_{Ci0}$ at
low fields, saturating toward $V_{lim}/r_{Ci0}$-scaled drift at high
fields, and rising again past $V_{lim}$ via the punch-through bracket.

$I_{CK}$ then drives the high-current transit-time increase
$\Delta\tau_f(i_{Tf}, I_{CK})$ (injection width $w_i$, §2.3 of manual —
out of scope here) which feeds $\Delta Q_{Ef}, \Delta Q_{Bf}, \Delta Q_{Cf}$
back into $Q_{f,T}$, closing the §1.4 loop.

## 2. Flow explanation

Per Newton iteration of the circuit solver, one HICUM/L2 eval:

1. Junction voltages $v_{B'E'}, v_{B'C'}, v_{C'E'}$ from internal nodes
   (after the external rB/rE/rC network; rBi is bias/charge modulated
   like VBIC's).
2. Depletion charges $Q_{jEi}(v_{B'E'})$, $Q_{jCi}(v_{B'C'})$ and the
   punch-through-free $C_{jCi,t}$ for $\tau_{f0}$.
3. $v_{ceff}$ (§1.5) → $\tau_{f0}$ → $I_{CK}$ (§1.6).
4. Weight factors ($h_{jEi}(v)$, constants $h_{jCi}, h_{f0}, h_{fE},
   h_{fC}$) → $Q_{pT,low}$ (§1.4).
5. **Inner Newton on $Q_{p,T}$**: start from the quadratic root
   (2.2.0-25); each inner step evaluates
   $i_{Tf}, i_{Tr}$, then $\Delta\tau_f(i_{Tf}, I_{CK})$ → minority
   charges → residual $Q_{p,T} - (Q_{pT,low} + Q_{f,T} + Q_{r,T})$.
   Converges in a few steps; the inner Jacobian is analytic.
6. Final $i_T = i_{Tf}(1 + i_{Tf1}/I_{CH}) - i_{Tr}$; derivatives w.r.t.
   the three controlling voltages are obtained by implicit
   differentiation through the converged $Q_{p,T}$ (or, in our AD
   setting, by differentiating the fixed-point at convergence).
7. Remaining EC elements (base currents, avalanche, tunneling, substrate
   transistor, NQS, self-heating) evaluate around this core and stamp as
   usual.

State: $Q_{p,T}$ makes a good warm start across outer iterations; charges
feed the transient companion as usual.

## 3. Pseudo-code, CPU sequential

```
fn hicum_transfer(vbe, vbc, vce, P) -> (iT, diT_dvbe, diT_dvbc, Qf, Qr):
    Vt   = P.vt
    qjE  = qj_depletion(vbe, P.cjei0, P.vdei, P.zei, P.ajei)   # charge
    qjC  = qj_depletion(vbc, P.cjci0, P.vdci, P.zci, P.ajci)
    c    = P.cjci0 / cj_no_pt(vbc, P)               # 1/c normalized cap
    tf0  = P.t0 + P.dt0h*(c - 1) + P.tbvl*(1/c - 1)

    vc    = vce - P.vces
    u     = (vc - Vt)/Vt
    vceff = Vt*(1 + 0.5*(u + sqrt(u*u + 1.921812)))
    x     = (vceff - P.vlim)/P.vpt
    ick   = vceff/P.rci0
            / pow(1 + pow(vceff/P.vlim, P.dck), 1/P.dck)
            * (1 + 0.5*(x + sqrt(x*x + P.aick)))

    hje  = P.hjei0 * expm1_over(u_hje(vbe, P))       # §1.2 bias-dep weight
    QpTj = P.qp0 + hje*qjE + P.hjci*qjC
    Qrt  = 0.05*P.qp0
    xq   = QpTj/Qrt - 1
    Qlow = Qrt*(1 + 0.5*(xq + sqrt(xq*xq + 1.921812)))

    ef = exp(vbe/(P.mcf*Vt));  er = exp(vbc/Vt)      # clamped
    # explicit quadratic start (exact when tau const):
    QpT = Qlow/2 + sqrt(0.25*Qlow*Qlow + tf0*P.c10*ef + P.tr*P.c10*er)
    repeat until |dQ| < tol*QpT:                     # inner NR, ~2-4 iters
        itf1 = P.c10*ef/QpT;  itr = P.c10*er/QpT
        itf  = itf1*(1 + itf1/P.ich)
        dtf  = delta_tau_f(itf, ick, P)              # high-current increase
        QfT  = P.hf0*tf0*itf + weights(P)*dtf_charges(itf, dtf, P)
        QrT  = P.tr*itr
        F    = QpT - (Qlow + QfT + QrT)
        QpT -= F / (1 - d(QfT+QrT)/dQpT)             # analytic inner Jacobian

    iT = itf - itr
    return with derivatives via implicit function theorem on F(QpT, v)=0
```

## 4. Pseudo-code, GPU parallel (batched SoA)

The inner Newton is the wrinkle: iteration counts may differ per lane.
Fixed-trip-count iteration (e.g. 4 steps, monotone-convergent from the
quadratic start) keeps lanes lockstep at negligible flop cost.

```
kernel hicum_batch(g, desc, blob, x, env):
    for i = g.tid; i < desc.count; i += g.stride:
        v = gather(x, gath[i*NU..])                 # b, e, c, internal nodes
        p = prep[i]                                 # temp-mapped constants

        tf0, ick, hje, Qlow, ef, er = straight_line(§3 head)   # branch-free
        QpT = quadratic_root(Qlow, tf0, er, ef, p)
        #pragma unroll
        for k in 0..N_INNER:                        # fixed trips, no divergence
            QpT -= giccr_residual(QpT, ...) * inv_inner_jacobian(...)
        iT  = itf(QpT) - itr(QpT)

        scatter_add(g.rhs,  gath, kcl(iT, base_currents, ...) + env.alpha*q + hist)
        scatter_add(g.diag, gath, conductances(...))
```

All smoothing functions are the same
$\frac{x+\sqrt{x^2+a}}{2}$ template — one fused helper, fully branchless.
Junction limiting: HICUM exponentials are bounded through $v_{ceff}$ /
$v_j$ smoothing internally, but the outer NR still wants pnjlim-style
limiting on $v_{B'E'}$/$v_{B'C'}$ (our converger applies the generic
device `limit`).

## Noise model (in-device)

Contract: [noise-contract.md](noise-contract.md). HICUM/L2 manual
SS2.13 (**pages not fetched in this pass** -- section list verified from
the TOC; formulas below are the standard HICUM/L2 set, derived):

- Thermal: $4kT/r_B$ (with emitter-crowding small-signal factor on the
  internal $r_{Bi}$), $4kT/r_E$, $4kT/r_{Cx}$.
- Shot: $2q\,i_T$ (transfer current, C'-E'), $2q\,i_{jBE}$ (B'-E').
- **B-C correlation** (SS2.13.3): at high frequencies the transfer shot
  noise seen at base and collector is correlated through the NQS delay
  ($e^{-j\omega\tau}$-type factor) -- the flagship case for the
  PsdTerm corr_with/corr extension (complex correlation).
- Flicker: $K_F\,i_{jBE}^{A_F}/f$ on B'-E'.

Transcribe SS2.13 (manual pp. 69-72) before implementing; the PDF is
already fetched locally (`hicum_l2_manual.pdf`), only the pages were
not read this pass.

## Sources

- https://www.iee.et.tu-dresden.de/iee/eb/forsch/Hicum_PD/Hicum23/hicum_L2V2p4p0_manual.pdf (fetched; §2.2 pp. 9–17, §2.3.1 pp. 18–23 read)
- https://www.iee.et.tu-dresden.de/iee/eb/hic_new/hic_doc.html (fetched — doc index)

## Verification status

- §1.1–1.6: **source-verified** against the fetched manual (equation numbers cited inline).
- $\Delta\tau_f$ / minority-charge partition detail (manual pp. 24–31): **not fetched/verified** — sketched only where the GICCR loop needs its existence.
- §3/§4: derived pseudo-code; the fixed-trip inner NR is our device-side choice, the manual specifies NR without trip policy.

## Our implementation

- `src/devices/models/hicumL2_va.va` (also `hicum_l0.zig` for L0).
- Bench fixtures: `benchmark/fixtures/devices/hicum2`, `hicum2_gummel`, `hicum2_output`.
