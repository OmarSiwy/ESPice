# BSIM3v3.3 core: Vth / mobility / Vdsat / Ids + derived-default parameter rules

Reference: ngspice `bsim3/b3ld.c`, `bsim3/b3temp.c` (BSIM3v3.3.0). The
Berkeley manual presents the same equations; the C source is bit-exact.
Scope: DC core chain. CV (capMod 0–3), NQS, and noise are out of scope
here.

## 1. Mathematical specification

All voltages are type-normalized (NMOS frame). $V_{tm} = kT/q$,
$C_{ox} = \varepsilon_{ox}/T_{OX}$,
`factor1` $= \sqrt{\varepsilon_{si}/\varepsilon_{ox}\,T_{OX}}$.
$L_{eff}, W_{eff}$ from L/W with DL/DW geometry corrections (b3temp).

### 1.1 Effective body bias

$$V_{bseff} = V_{bc} + \tfrac{1}{2}\left[(V_{bs} - V_{bc} - \delta_1) + \sqrt{(V_{bs} - V_{bc} - \delta_1)^2 - 4\delta_1 V_{bc}}\right],\quad \delta_1 = 0.001$$

with $V_{bc}$ the upper body-bias bound
$V_{bc} = 0.9\left(\phi_s - \frac{k_1^2}{4 k_2^2}\right)$ clamped to
$[-30, -3]$ and $\ge V_{bm}$ (b3temp `vbsc`). Then
$\Phi_s = \phi_s - V_{bseff}$ (guarded), $\sqrt{\Phi_s}$, and depletion width

$$X_{dep} = X_{dep0}\frac{\sqrt{\Phi_s}}{\sqrt{\phi_s}},\qquad X_{dep0} = \sqrt{\frac{2\varepsilon_{si}}{q N_{ch}}}\sqrt{\phi_s}$$

### 1.2 Threshold voltage

Characteristic lengths (with smoothed $(1 + d_{vt2} V_{bseff})$ factors —
each linear factor $1+x$ is replaced by $(1+3x)/(3+8x)$ once $x < -0.5$ to
avoid sign flips; this guard pattern recurs throughout BSIM3):

$$l_t = \text{factor1}\,\sqrt{X_{dep}}\,(1 + d_{vt2}V_{bseff}),\qquad
l_{tw} = \text{factor1}\,\sqrt{X_{dep}}\,(1 + d_{vt2w}V_{bseff})$$

Short-channel and narrow-width Vth shifts, $V_0 = v_{bi} - \phi_s$:

$$\theta_0 = e^{-d_{vt1}L_{eff}/(2l_t)}\left(1 + 2e^{-d_{vt1}L_{eff}/(2l_t)}\right),\qquad
\Delta V_{th,SCE} = d_{vt0}\,\theta_0\,V_0$$

$$\Delta V_{th,W} = d_{vt0w}\,e^{-d_{vt1w}W_{eff}L_{eff}/(2l_{tw})}\left(1+2e^{-\cdot}\right) V_0$$

DIBL: $\theta_{0,vb0} = e^{-d_{sub}L_{eff}/(2l_{t0})} + 2e^{-d_{sub}L_{eff}/l_{t0}}$
(precomputed at $V_{bs}=0$),

$$\Delta V_{th,DIBL} = (\eta_0 + \eta_b V_{bseff})\,\theta_{0,vb0}\,V_{ds}$$

(with the $\eta_0 + \eta_b V_{bseff} < 10^{-4}$ smoothing guard). Full Vth:

$$
\boxed{\begin{aligned}
V_{th} = {}& V_{th0} - k_1\sqrt{\phi_s} + k_{1,ox}\sqrt{\Phi_s} - k_{2,ox}V_{bseff}
- \Delta V_{th,SCE} - \Delta V_{th,W} \\
&+ (k_3 + k_{3b}V_{bseff})\frac{T_{OX}\,\phi_s}{W_{eff} + w_0}
+ k_{1,ox}\left(\sqrt{1 + \frac{N_{LX}}{L_{eff}}} - 1\right)\sqrt{\phi_s} \\
&+ \left(k_{t1} + \frac{k_{t1l}}{L_{eff}} + k_{t2}V_{bseff}\right)\left(\frac{T}{T_{nom}} - 1\right)
- \Delta V_{th,DIBL}
\end{aligned}}
$$

where $k_{1,ox} = k_1 T_{OX}/T_{OXM}$, $k_{2,ox} = k_2 T_{OX}/T_{OXM}$.

### 1.3 Subthreshold swing factor and unified Vgsteff

$$n = 1 + \frac{n_{factor}\,\varepsilon_{si}/X_{dep} + (c_{dsc} + c_{dscb}V_{bseff} + c_{dscd}V_{ds})\theta_0 + c_{it}}{C_{ox}}$$

(smoothing guard at $n - 1 < -0.5$). Poly-gate depletion (only if
$10^{18} < N_{gate} < 10^{25}$ and $V_{gs} > V_{fb} + \phi_s$):

$$V_{gs,eff} = V_{gs} - \left[1.12 - \tfrac{1}{2}\left(T_7 + \sqrt{T_7^2 + 0.224}\right)\right],\quad
T_7 = 1.12 - V_{poly} - 0.05,\quad
V_{poly} = \frac{T_2^2}{2 T_1},\ T_2 = T_1(\sqrt{1 + 2(V_{gs} - V_{fb} - \phi_s)/T_1} - 1),\ T_1 = \frac{10^6 q\varepsilon_{si}N_{gate}}{C_{ox}^2}$$

$V_{gst} = V_{gs,eff} - V_{th}$. Unified overdrive (single expression,
valid from subthreshold to strong inversion):

$$
\boxed{V_{gsteff} = \frac{2 n V_{tm}\,\ln\!\left(1 + e^{V_{gst}/(2nV_{tm})}\right)}
{1 + 2n\,\dfrac{C_{ox}}{C_{dep0}}\,e^{-(V_{gst} - 2\,V_{off})/(2nV_{tm})}}}
\qquad C_{dep0} = \sqrt{\frac{q\varepsilon_{si}N_{ch}}{2\phi_s}}
$$

Asymptotes: $V_{gsteff}\to V_{gst}$ for $V_{gst} \gg nV_{tm}$;
$V_{gsteff}\to V_{tm}\frac{C_{dep0}}{C_{ox}}e^{(V_{gst}-V_{off})/(nV_{tm})}$
in deep subthreshold (both asymptotes are used verbatim in b3ld.c when the
exponent exceeds EXP_THRESHOLD = 34).

### 1.4 Effective geometry, Rds, Abulk

$$W_{eff}' = W_{eff} - 2(d_{wg}V_{gsteff} + d_{wb}(\sqrt{\Phi_s} - \sqrt{\phi_s}))$$

(floor-smoothed at $2\times10^{-8}$).

$$R_{ds} = r_{ds0}\left[1 + p_{rwg}V_{gsteff} + p_{rwb}(\sqrt{\Phi_s}-\sqrt{\phi_s})\right],\qquad
r_{ds0}(T) = \frac{r_{dsw} + p_{rt}\left(\frac{T}{T_{nom}}-1\right)}{(10^6\,W_{eff})^{w_r}}$$

Bulk-charge factor:

$$A_{bulk0} = 1 + \frac{k_{1,ox}}{2\sqrt{\Phi_s}}\left[\frac{A_0 L_{eff}}{L_{eff} + 2\sqrt{X_J X_{dep}}} + \frac{B_0}{W_{eff}+B_1}\right]$$
$$A_{bulk} = \frac{A_{bulk0} - \dfrac{k_{1,ox}}{2\sqrt{\Phi_s}}\,A_{GS}A_0\left(\dfrac{L_{eff}}{L_{eff}+2\sqrt{X_JX_{dep}}}\right)^3 V_{gsteff}}{1 + K_{ETA}V_{bseff}}$$

(0.1-floor and keta guards as in source).

### 1.5 Mobility

$u_{0,T} = u_0 (T/T_{nom})^{u_{te}}$; $u_a, u_b, u_c$ linear in
$(T/T_{nom}-1)$ via $u_{a1}, u_{b1}, u_{c1}$.

$$
\mu_{eff} = \frac{u_{0,T}}{1 + D},\qquad
D = \begin{cases}
\dfrac{V_{gsteff}+2V_{th}}{T_{OX}}\left(u_a + u_c V_{bseff} + u_b\dfrac{V_{gsteff}+2V_{th}}{T_{OX}}\right) & \text{mobMod}=1\\[8pt]
\dfrac{V_{gsteff}}{T_{OX}}\left(u_a + u_c V_{bseff} + u_b\dfrac{V_{gsteff}}{T_{OX}}\right) & \text{mobMod}=2\\[8pt]
\dfrac{V_{gsteff}+2V_{th}}{T_{OX}}\left(u_a + u_b\dfrac{V_{gsteff}+2V_{th}}{T_{OX}}\right)(1 + u_c V_{bseff}) & \text{mobMod}=3
\end{cases}
$$

($D < -0.8$ guard: $D \to (0.6+D)/(7+10D)$ mapping).

### 1.6 Vdsat, Vdseff

$E_{sat} = 2 v_{sat,T}/\mu_{eff}$ with
$v_{sat,T} = v_{sat} - a_t(T/T_{nom}-1)$; $E_{sat}L = E_{sat}L_{eff}$;
$V_{gst2Vtm} = V_{gsteff} + 2V_{tm}$. Velocity-overshoot factor $\lambda$
from $a_1, a_2$ (smoothed; $\lambda = a_2$ when $a_1 = 0$).

If $R_{ds} = 0$ and $\lambda = 1$:

$$V_{dsat} = \frac{E_{sat}L\,V_{gst2Vtm}}{A_{bulk}E_{sat}L + V_{gst2Vtm}}$$

else the quadratic root

$$V_{dsat} = \frac{T_1 - \sqrt{T_1^2 - 2 T_0 T_2}}{T_0}$$

with

$$
\begin{aligned}
T_0 &= 2 A_{bulk}\left(A_{bulk} W_{eff}' v_{sat} C_{ox} R_{ds} - 1 + \tfrac{1}{\lambda}\right)\\
T_1 &= V_{gst2Vtm}\left(\tfrac{2}{\lambda}-1\right) + A_{bulk}E_{sat}L + 3 A_{bulk} V_{gst2Vtm} W_{eff}' v_{sat}C_{ox}R_{ds}\\
T_2 &= V_{gst2Vtm}\left(E_{sat}L + 2 V_{gst2Vtm} W_{eff}' v_{sat}C_{ox}R_{ds}\right)
\end{aligned}
$$

Smoothed effective Vds (DELTA parameter $\delta$):

$$V_{dseff} = V_{dsat} - \tfrac{1}{2}\left[(V_{dsat} - V_{ds} - \delta) + \sqrt{(V_{dsat}-V_{ds}-\delta)^2 + 4\delta V_{dsat}}\right]$$

clamped to $\le V_{ds}$, forced 0 at $V_{ds}=0$.

### 1.7 Output-conductance voltages and Ids

$$V_{Asat} = \frac{E_{sat}L + V_{dsat} + 2 W_{eff}'v_{sat}C_{ox}R_{ds}V_{gsteff}\left(1 - \frac{A_{bulk}V_{dsat}}{2V_{gst2Vtm}}\right)}{\frac{2}{\lambda} - 1 + W_{eff}'v_{sat}C_{ox}R_{ds}A_{bulk}}$$

$$V_{ACLM} = \frac{L_{eff}\left(A_{bulk} + \frac{V_{gsteff}}{E_{sat}L}\right)}{p_{clm}A_{bulk}\,l_{itl}}(V_{ds}-V_{dseff}),\qquad l_{itl} = \sqrt{3 X_J T_{OX}}$$

$$V_{ADIBL} = \frac{V_{gst2Vtm} - \frac{A_{bulk}V_{dsat}V_{gst2Vtm}}{V_{gst2Vtm} + A_{bulk}V_{dsat}}}{\theta_{rout}(1 + p_{diblb}V_{bseff})},\qquad
\theta_{rout} = p_{dibl1}\left[e^{-\frac{d_{rout}L_{eff}}{2l_{t0}}} + 2e^{-\frac{d_{rout}L_{eff}}{l_{t0}}}\right] + p_{dibl2}$$

$$V_A = V_{Asat} + \left(1 + \frac{p_{vag}V_{gsteff}}{E_{sat}L}\right)\frac{V_{ACLM}V_{ADIBL}}{V_{ACLM}+V_{ADIBL}}$$

$$V_{ASCBE} = \frac{L_{eff}}{p_{scbe2}}\exp\!\left(\frac{p_{scbe1}\,l_{itl}}{V_{ds}-V_{dseff}}\right)$$

Current chain:

$$
\boxed{\begin{aligned}
g_{che} &= \mu_{eff}C_{ox}\frac{W_{eff}'}{L_{eff}}\cdot
\frac{V_{gsteff}\left(1 - \frac{A_{bulk}V_{dseff}}{2 V_{gst2Vtm}}\right)}{1 + V_{dseff}/(E_{sat}L)}\\
I_{dl} &= \frac{g_{che}V_{dseff}}{1 + g_{che}R_{ds}}\\
I_{ds} &= I_{dl}\left(1 + \frac{V_{ds}-V_{dseff}}{V_A}\right)\left(1 + \frac{V_{ds}-V_{dseff}}{V_{ASCBE}}\right)
\end{aligned}}
$$

Substrate (impact-ionization) current:

$$I_{sub} = \frac{\alpha_0 + \alpha_1 L_{eff}}{L_{eff}}(V_{ds}-V_{dseff})\,e^{-\beta_0/(V_{ds}-V_{dseff})}\,\frac{I_{dl}}{1 + R_{ds}g_{che}} \cdot (1 + \tfrac{V_{ds}-V_{dseff}}{V_A})$$

Bulk diodes: same exponential junction model as MOS1 (with `ijth`
linearization above the junction knee in v3.3).

### 1.8 Derived-default parameter rules (b3temp.c)

Applied per (L,W) bin after L/W/P interpolation
($P_{eff} = P + P_l/L + P_w/W + P_p/(LW)$):

- $n_i(T) = 1.45\times10^{10}\left(\frac{T}{300.15}\right)^{1.5} e^{21.5565981 - E_g(T)/(2V_{tm0})}$ (cm⁻³).
- If NCH (npeak) not given and $\gamma_1$ given: $N_{ch} = 3.021\times10^{22}(\gamma_1 C_{ox})^2$; default NCH $=1.7\times10^{17}$ cm⁻³.
- $\phi_s = 2 V_{tm0}\ln(N_{ch}/n_i)$, $v_{bi} = V_{tm0}\ln\!\frac{10^{20}N_{ch}}{n_i^2}$.
- $X_{dep0}$, $C_{dep0}$, $l_{itl} = \sqrt{3X_JT_{OX}}$, $l_{deb} = \frac{1}{3}\sqrt{\varepsilon_{si}V_{tm0}/(qN_{ch})}$.
- ACDE scaled by $(N_{ch}/2\times10^{16})^{-1/4}$.
- **k1/k2**: if either given, missing one defaults ($k_1 = 0.53$, $k_2 = -0.0186$) and nsub/xt/vbx/γ1/γ2 are ignored. Otherwise:
  - $v_{bx} = \phi_s - 7.7348\times10^{-4}N_{ch}X_t^2$ if not given (forced $\le 0$); $v_{bm}$ forced $\le 0$;
  - $\gamma_1 = \frac{5.753\times10^{-12}\sqrt{N_{ch}}}{C_{ox}}$, $\gamma_2$ same with NSUB, if not given;
  - $$k_2 = \frac{(\gamma_1-\gamma_2)\left(\sqrt{\phi_s - v_{bx}} - \sqrt{\phi_s}\right)}{2\left(\sqrt{\phi_s(\phi_s - v_{bm})} - \phi_s\right) + v_{bm}},\qquad k_1 = \gamma_2 - 2k_2\sqrt{\phi_s - v_{bm}}$$
- $v_{bsc}$: for $k_2 < 0$: $0.9(\phi_s - (k_1/2k_2)^2)$ clamped to $[-30,-3]$ and $\ge v_{bm}$, else $-30$.
- **vfb/vth0 mutual defaults**: vfb $= \text{type}\cdot v_{th0} - \phi_s - k_1\sqrt{\phi_s}$ if vth0 given, else $-1.0$; vth0 $= \text{type}(v_{fb} + \phi_s + k_1\sqrt{\phi_s})$ if not given.
- $k_{1,ox} = k_1 T_{OX}/T_{OXM}$, $k_{2,ox} = k_2 T_{OX}/T_{OXM}$.
- $\theta_{0,vb0}$, $\theta_{rout}$ precomputed with $l_{t0} = \sqrt{\frac{\varepsilon_{si}}{\varepsilon_{ox}}T_{OX}X_{dep0}}$.
- Temperature: $u_{0,T}$, $v_{sat,T}$, $r_{ds0}(T)$ as §1.5–1.6; junction currents/caps with jctTempExponent/energy-gap mapping; overlap caps $c_{gdo} = (CGDO + c_f)W_{effCV}$ with fringe default $c_f = \frac{2\varepsilon_{ox}}{\pi}\ln(1 + 4\times10^{-7}/T_{OX})$.
- `vcrit` $= V_t\ln(V_t/(\sqrt 2\cdot 10^{-14}))$ used by junction limiting.

### 1.9 Limiting

b3ld.c uses DEVfetlim($v_{gs}, v_{gs}^{old}, v_{on}$), DEVlimvds, and
DEVpnjlim on $v_{bs}/v_{bd}$ (see mos1 doc §1.7 for the math) — plus a
±0.1 V max delta on vds/vgs near OP for v3.3.

## 2. Flow explanation

Order matters — each block feeds the next, and every derivative
($\partial/\partial V_g, V_d, V_b$) is chained forward by hand in the C:

1. Junction diodes on vbs/vbd (with ijth linearization) — independent of channel.
2. $V_{bseff}$ → $\Phi_s, X_{dep}$ → characteristic lengths → $V_{th}$ → $n$ → poly depletion → $V_{gsteff}$.
3. $W_{eff}'$, $R_{ds}$, $A_{bulk}$.
4. Mobility → $E_{sat}L$ → $\lambda$ → $V_{dsat}$ → $V_{dseff}$.
5. $V_{Asat}, V_{ACLM}, V_{ADIBL}, V_A, V_{ASCBE}$ → $I_{ds}$ chain → $G_m, G_{ds}, G_{mb}$ by chaining through $dV_{gsteff}$ and $dV_{bseff}$.
6. $I_{sub}$; CV model (not covered here) produces the charge stamps.
7. Convergence: predicted-vs-actual drain/bulk current test; stamps as in MOS1 (d', s' internal nodes; mode swap identical).

Every guard (Abulk<0.1, n<0.5, T5<−0.8, keta, etab, prw, pdiblb) replaces
$f(x) = 1+x$-type factors with a rational continuation that keeps value +
derivative continuous at the switch point — reproducing these exactly is
what "bit-exact" means in practice; missing one shows up as an NR
convergence difference, not a DC error.

The mode ($V_{ds} < 0$) is handled by evaluating in the swapped frame and
un-swapping the stamp exactly as MOS1.

## 3. Pseudo-code, CPU sequential

```
fn bsim3_eval(x, P) -> (I, Q, J, C):        # P = per-bin pParam + temp consts
    (vgs, vds, vbs) = frame(x)              # type + mode normalize
    (ibs,gbs,ibd,gbd) = junctions(vbs, vbs-vds)

    vbseff = smooth_max(vbs, P.vbsc, 0.001)
    phis   = P.phi - vbseff;  sphis = sqrt(phis)
    xdep   = P.xdep0*sphis/P.sqrtphi
    lt     = P.factor1*sqrt(xdep)*guarded(1 + P.dvt2*vbseff)
    theta0 = exp2sum(-P.dvt1*P.leff/(2*lt))         # e + 2e^2
    vth    = P.vth0 - P.k1*P.sqrtphi + P.k1ox*sphis - P.k2ox*vbseff
             - P.dvt0*theta0*(P.vbi-P.phi) - narrow_w(...) 
             + (P.k3 + P.k3b*vbseff)*P.toxphi_w + P.nlx_term
             + (P.kt1 + P.kt1l/P.leff + P.kt2*vbseff)*P.tratio_m1
             - guarded(P.eta0 + P.etab*vbseff)*P.theta0vb0*vds
    n      = guarded_n(1 + (P.nf_esi/xdep + cdsc_terms*theta0 + P.cit)/P.cox)
    vgst   = poly_depletion(vgs) - vth
    vgsteff= unified_vgsteff(vgst, n, P)             # 3-asymptote exact form

    weff  = guarded_w(P.weff - 2*(P.dwg*vgsteff + P.dwb*(sphis - P.sqrtphi)))
    rds   = P.rds0*guarded(1 + P.prwg*vgsteff + P.prwb*(sphis-P.sqrtphi))
    abulk = abulk_expr(vgsteff, vbseff, xdep, P)     # with 0.1 + keta guards

    ueff  = P.u0t / guarded_mob(mob_denom(P.mobmod, vgsteff, vth, vbseff, P))
    esatl = 2*P.vsatt/ueff * P.leff
    lam   = lambda_expr(P.a1, P.a2, vgsteff)
    vdsat = (rds==0 && lam==1) ? esatl*vg2/(abulk*esatl + vg2)
                               : quadratic_root(T0,T1,T2)   # §1.6
    vdseff= min(vds, smooth_min(vdsat, vds, P.delta))

    va    = vasat(...) + pvag_factor(...)*parallel(vaclm(...), vadibl(...))
    vascbe= P.pscbe2>0 ? P.leff*exp(P.pscbe1*P.litl/dvds)/P.pscbe2 : INF

    gche  = beta*vgsteff*(1 - abulk*vdseff/(2*vg2)) / (1 + vdseff/esatl)
    idl   = gche*vdseff/(1 + gche*rds)
    ids   = idl*(1 + dvds/va)*(1 + dvds/vascbe)
    isub  = isub_expr(dvds, idl, P)

    # derivatives: chain dVth,dVgsteff,dVdseff,... exactly as source, or
    # (our impl) evaluate the whole chain in the AD scalar type S
    return stamps(ids, isub, ibs, ibd, gm, gds, gmb, charges_from_cv_model)
```

## 4. Pseudo-code, GPU parallel (batched SoA)

The chain is long but branch-light once the smoothing guards are written
as rational selects — every `if (x >= -0.5) A else B` is
`select(x >= c, A(x), B(x))` on registers, no memory divergence. Ids has
no hard region split at all (Vgsteff and Vdseff are single expressions),
which makes BSIM3 friendlier to SIMT than MOS1.

```
kernel bsim3_batch(g, desc, blob, x, env):
    # SoA layout: per-instance pParam slice index (bin), per-bin const
    # tables in blob (broadcast reads, cached), per-instance state slots
    for i = g.tid; i < desc.count; i += g.stride:
        v = gather(x, gath[i*NU..])           # d g s b e? d' s'
        b = bins[inst_bin[i]]                 # per-(L,W)-bin derived consts

        m    = sign1(vds(v))                  # source/drain swap as sign frame
        vgs, vds, vbs = swapped_frame(v, m)

        vbseff  = smooth_max(vbs, b.vbsc, 1e-3)          # sqrt-select, no branch
        ... full §1 chain, all guards as select() ...
        ids, gm, gds, gmb = core_chain(vgs, vds, vbs, b)
        isub              = isub_chain(...)
        (ibs,gbs,ibd,gbd) = junctions(vbs, vbd)
        q...              = cv_model(...)                # capMod uniform per model

        scatter_add(g.rhs, gath, kcl(m, ids, isub, ibs, ibd) + env.alpha*q + hist)
        if WITH_DIAG: scatter_add(g.diag, gath, diag_entries(gds+gm-mix, gbs, gbd, alpha*c))

    # limiting kernel: fetlim(vgs,von)/limvds/pnjlim per instance, same as CPU;
    # von must be the stored per-instance value from the previous eval
    # (b3ld uses here->BSIM3von), so keep a von slot in the state SoA.
```

Practical notes for the megakernel: (a) per-bin derived constants
(§1.8) must be resolved host-side into the batch blob — the ni/k1/k2
defaulting logic has printf-warnings and Given-flags that cannot live on
device; (b) the guards keep all lanes on the same instruction path, so a
mixed-bias batch loses nothing to divergence except the poly-depletion
conditional, which is model-uniform (ngate) and hence warp-uniform.

## Noise model (in-device)

Contract: [noise-contract.md](noise-contract.md). Source-verified
against b3noi.c. RD/RS thermal as MOS1. Channel thermal by `noiMod`:

| noiMod | channel thermal PSD (d'-s') |
|---|---|
| 1, 3 | $4kT\cdot\frac{2}{3}(g_m + g_{ds} + g_{mb})\,m$ |
| 5, 6 | $4kT\cdot\frac{3 - v_{ds}'/V_{dsat}}{3}(g_m+g_{ds}+g_{mb})\,m$, $v_{ds}' = \min(v_{ds}, V_{dsat})$ |
| 2, 4 | $4kT\,\dfrac{\mu_{eff}|Q_{inv}|}{L_{eff}^2 + \mu_{eff}|Q_{inv}|R_{ds}}\,m$ (charge-based) |

Flicker by noiMod: 1/4/5 SPICE2 form
$K_F|I_D|^{A_F}/(f^{E_F}L_{eff}^2 C_{ox})$; 2/3/6 unified BSIM3:
$S_{fl} = \dfrac{S_{si}\,S_{wi}}{S_{si}+S_{wi}}$ with the
strong-inversion density $S_{si}$ built from NOIA/NOIB/NOIC over the
carrier densities $N_0, N_l$ (+ the $\Delta L_{clm}$ term) and the
weak-inversion $S_{wi} = \dfrac{N_{OIA}\,kT\,I_D^2}{W_{eff}L_{eff}f^{E_F}\cdot 4\times10^{36}}$
(b3noi.c StrongInversionNoiseEval, transcribed constants 8.62e-5/1e8/2e14).
`noisePsd`: needs $g$'s, $Q_{inv}$, $V_{dsat}$, $I_D$ at x -- all
already produced by the SS3 chain; emit per-noiMod terms (noiMod is
model-uniform, warp-uniform on GPU).

## Sources

- https://raw.githubusercontent.com/ngspice/ngspice/master/src/spicelib/devices/bsim3/b3ld.c (fetched)
- https://raw.githubusercontent.com/ngspice/ngspice/master/src/spicelib/devices/bsim3/b3temp.c (fetched)
- Berkeley BSIM3v3.3 manual (https://bsim.berkeley.edu/models/bsim3/) — **not fetched** (site offers tarballs, not direct HTML); equations cross-checked against the ngspice source instead.

## Verification status

- §1.1–1.7 (Vth, n, Vgsteff, Rds, Abulk, mobility, Vdsat/Vdseff, VA chain, Ids, Isub): **source-verified** against fetched b3ld.c lines 500–1230.
- §1.8 derived defaults: **source-verified** against fetched b3temp.c lines 590–770.
- §1.9 limiting call order: from b3ld.c init section (partially quoted in the fetch; the fetlim/pnjlim math itself source-verified via devsup.c).
- CV/NQS/noise: intentionally out of scope, not verified.

## Our implementation

- `modules/devices/src/bsim3.zig`.
- Bench fixtures: `benchmark/fixtures/devices/bsim3`, `bsim3_transfer`, `bsim3_output`, `bsim3_body_effect`, `bsim3_pmos`, `bsim3_temp`.
