# MOS1 (Shichman–Hodges) with MEYER gate capacitances

Reference: ngspice `mos1/mos1load.c`, `mos1/mos1temp.c`, `devsup.c`
(DEVfetlim, DEVlimvds, DEVpnjlim, DEVqmeyer).

## 1. Mathematical specification

### 1.1 Symbols

| Symbol | Param | Units | Meaning |
|---|---|---|---|
| $V_{T0}$ | VTO | V | zero-bias threshold |
| $KP$ | KP | A/V² | transconductance parameter |
| $\gamma$ | GAMMA | √V | body-effect coefficient |
| $\phi$ | PHI | V | surface potential |
| $\lambda$ | LAMBDA | 1/V | channel-length modulation |
| $L_D$ | LD | m | lateral diffusion |
| $T_{OX}$ | TOX | m | oxide thickness; $C_{ox}' = \varepsilon_{ox}/T_{OX}$ |
| $I_S$, $J_S$ | IS, JS | A, A/m² | bulk junction saturation current (abs / density) |
| $C_{BD}, C_{BS}, C_J, C_{JSW}$ | — | F, F/m² , F/m | junction caps |
| $P_B$, $M_J$, $M_{JSW}$, $F_C$ | PB, MJ, MJSW, FC | | junction potential/grading |
| CGSO/CGDO/CGBO | | F/m | overlap capacitances per width (CGBO per length) |
| type | | ±1 | +1 NMOS, −1 PMOS (all voltages/currents multiplied by type) |

$L_{eff} = L - 2L_D$, $\beta = KP(T)\,m\,W/L_{eff}$,
$C_{ox} = C_{ox}'\,W\,L_{eff}\,m$.

### 1.2 Parameter defaulting (mos1temp.c)

If TOX given: $C_{ox}' = 3.9\,\varepsilon_0/T_{OX}$; if KP not given,
$KP = U_O \cdot C_{ox}' \cdot 10^{-4}$ ($U_O$ default 600 cm²/Vs).
If NSUB given (must exceed $n_i = 1.45\times10^{16}\,\mathrm{m^{-3}}$):

$$\phi = \max\!\left(0.1,\ 2 V_{t,nom}\ln\frac{N_{SUB}}{n_i}\right),\qquad
\gamma = \frac{\sqrt{2\,\varepsilon_{si} q N_{SUB}}}{C_{ox}'}$$

and if VTO not given it is built from the gate work-function difference and
surface state density NSS: $V_{fb} = w_{kfngs} - q\,N_{SS}/C_{ox}'$,
$V_{T0} = V_{fb} + \text{type}(\gamma\sqrt{\phi} + \phi)$.

### 1.3 Temperature scaling (mos1temp.c)

With ratio $r = T/T_{nom}$:

$$KP(T) = KP / r^{1.5},\qquad \mu(T) = U_O / r^{1.5}$$

$\phi(T)$ follows the standard SPICE intrinsic-shift mapping (same
`pbfact/fact` machinery as the diode, §1.2 of diode.md). Then

$$V_{bi}(T) = V_{T0} - \text{type}\,\gamma\sqrt{\phi} + \tfrac{1}{2}(E_{g,nom} - E_g(T)) + \text{type}\,\tfrac{1}{2}(\phi(T) - \phi)$$
$$V_{T0}(T) = V_{bi}(T) + \text{type}\,\gamma\sqrt{\phi(T)}$$

Junction saturation currents: $I_S(T) = I_S\,e^{-E_g(T)/V_t + E_{g,nom}/V_{t,nom}}$
(same for $J_S$). Junction caps scale by the same two-stage
$1 + M_J(4\times10^{-4}\Delta T - \gamma_{ma})$ factor as the diode.
$V_{crit} = V_t\ln(V_t/(\sqrt 2 I_{S,\{s,d\}}))$ for each junction.
Forward-region junction-charge linearization constants $f_{2,3,4}$ per
junction (bottom+sidewall combined) are precomputed exactly as in
mos1temp.c so that charge/cap are evaluated branch-free above
$F_C P_B(T)$:

$$C_{bx}(v) = f_2 + f_3\,v, \qquad Q_{bx}(v) = f_4 + f_2 v + \tfrac{1}{2}f_3 v^2 \quad (v \ge F_C P_B)$$

### 1.4 Bulk junction diodes

For $x \in \{vbs, vbd\}$ with saturation current $I_{Sx}$
($= J_S\cdot A_{S/D}\cdot m$ if area given, else $I_S\cdot m$):

$$
I_{bx} = \begin{cases} I_{Sx}\left(e^{x/V_t} - 1\right) + g_{min}x, & x > -3V_t\\
g_{min}x - I_{Sx}, & x \le -3V_t \end{cases}
\qquad
g_{bx} = \begin{cases} I_{Sx}e^{x/V_t}/V_t + g_{min} \\ g_{min}\end{cases}
$$

### 1.5 Drain current — all regions

Mode: normal ($vds \ge 0$) or inverted; in inverted mode swap
source↔drain roles ($vgs \to vgd$, $vbs \to vbd$, $vds \to -vds$). Let
$v_b$ = (mode==1 ? vbs : vbd).

Body term:

$$
s = \begin{cases}\sqrt{\phi(T) - v_b}, & v_b \le 0 \\
\max\!\left(0,\ \sqrt{\phi(T)} - \dfrac{v_b}{2\sqrt{\phi(T)}}\right), & v_b > 0 \text{ (Taylor, keeps } s \ge 0)\end{cases}
$$

$$v_{on} = V_{bi}(T)\,\text{type} + \gamma s,\qquad v_{gst} = v_{gsx} - v_{on},\qquad V_{dsat} = \max(v_{gst}, 0)$$

Backgate transconductance factor $\alpha_b = \gamma/(2s)$ (0 if $s \le 0$).
With $\beta_p = \beta(1 + \lambda |v_{ds}|)$:

**Cutoff** ($v_{gst} \le 0$): $I_D = 0$, $g_m = g_{ds} = g_{mbs} = 0$.

**Saturation** ($0 < v_{gst} \le |v_{ds}|$):

$$I_D = \tfrac{1}{2}\beta_p v_{gst}^2,\quad g_m = \beta_p v_{gst},\quad
g_{ds} = \tfrac{1}{2}\lambda\beta v_{gst}^2,\quad g_{mbs} = g_m\alpha_b$$

**Linear** ($v_{gst} > |v_{ds}|$):

$$I_D = \beta_p |v_{ds}|\left(v_{gst} - \tfrac{|v_{ds}|}{2}\right),\quad
g_m = \beta_p |v_{ds}|,\quad
g_{ds} = \beta_p(v_{gst} - |v_{ds}|) + \lambda\beta |v_{ds}|(v_{gst} - \tfrac{|v_{ds}|}{2}),\quad
g_{mbs} = g_m \alpha_b$$

Total drain current $I_{cd} = \text{mode}\cdot I_D - I_{bd}$.

### 1.6 MEYER gate capacitances (DEVqmeyer)

Piecewise reciprocal-capacitance model; returns *half* the non-constant
part (the load routine averages state0+state1 halves and adds constant
overlaps). With $v_{gst} = v_{gs} - v_{on}$, $V_{dsat}' = \max(V_{dsat}, 0.025)$:

$$
\begin{array}{ll}
v_{gst} \le -\phi: & C_{gb} = \tfrac{C_{ox}}{2},\quad C_{gs} = C_{gd} = 0\\[2pt]
-\phi < v_{gst} \le -\phi/2: & C_{gb} = -\dfrac{v_{gst}C_{ox}}{2\phi},\quad C_{gs} = C_{gd} = 0\\[4pt]
-\phi/2 < v_{gst} \le 0: & C_{gb} = -\dfrac{v_{gst}C_{ox}}{2\phi},\quad
C_{gs} = \dfrac{v_{gst}C_{ox}}{1.5\phi} + \dfrac{C_{ox}}{3},\quad C_{gd}\ \text{from sat/lin split below}\\[4pt]
v_{gst} > 0,\ v_{ds} \ge V_{dsat}': & C_{gs} = \tfrac{C_{ox}}{3},\quad C_{gd} = 0,\quad C_{gb} = 0\\[4pt]
v_{gst} > 0,\ v_{ds} < V_{dsat}': &
C_{gd} = \tfrac{C_{ox}}{3}\left[1 - \dfrac{V_{dsat}'^2}{(2V_{dsat}' - v_{ds})^2}\right],\quad
C_{gs} = \tfrac{C_{ox}}{3}\left[1 - \dfrac{(V_{dsat}' - v_{ds})^2}{(2V_{dsat}' - v_{ds})^2}\right],\quad C_{gb}=0
\end{array}
$$

(In the $-\phi/2 < v_{gst} \le 0$ subthreshold band, the same
$V_{dsat}$-based split scales the $C_{gs}$ expression.) In inverted mode
qmeyer is called with $(v_{gd}, v_{gs})$ swapped and $C_{gs}/C_{gd}$
outputs swapped.

Total (per timestep): $cap_{gs} = C_{gs}^{(0)} + C_{gs}^{(1)} + CGSO\cdot W m$
(at OP: $2C_{gs}^{(0)} + $ overlap), similarly gd (CGDO·W) and gb
(CGBO·$L_{eff}$). Charge is advanced incrementally:
$q_{gs}^{(0)} = q_{gs}^{(1)} + cap_{gs}(v_{gs} - v_{gs}^{(1)})$ — Meyer
caps are capacitance-based, not charge-conserving.

### 1.7 Limiting functions

DEVfetlim (gate voltage vs $v_{on}$): with
$\Delta = v_{new} - v_{old}$, $t_{hi} = 2|v_{old}-v_{to}|+2$,
$t_{lo} = |v_{old}-v_{to}|+1$:

- on, high ($v_{old} \ge v_{to}+3.5$): decreasing steps limited to $t_{lo}$ (floor $v_{to}+2$ if crossing), increasing to $t_{hi}$;
- middle ($v_{to} \le v_{old} < v_{to}+3.5$): clamp to $[\,v_{to}-0.5,\ v_{to}+4\,]$;
- off ($v_{old} < v_{to}$): decreasing limited to $t_{hi}$, increasing limited to $t_{lo}$ once past $v_{to}+0.5$, else ceiling $v_{to}+0.5$.

DEVlimvds:

$$
v_{ds}' = \begin{cases}
\min(v_{ds}, 3v_{old}+2) & v_{old} \ge 3.5,\ v_{ds} > v_{old}\\
\max(v_{ds}, 2) & v_{old} \ge 3.5,\ v_{ds} < 3.5\\
\min(v_{ds}, 4) & v_{old} < 3.5,\ v_{ds} > v_{old}\\
\max(v_{ds}, -0.5) & v_{old} < 3.5,\ v_{ds} \le v_{old}
\end{cases}
$$

Order (mos1load.c): if $v_{ds}^{old} \ge 0$: fetlim($v_{gs}$), then
limvds($v_{ds} = v_{gs} - v_{gd}$), else fetlim($v_{gd}$) and mirrored
limvds; then pnjlim on $v_{bs}$ (if $v_{ds}\ge0$) or $v_{bd}$ with the
per-junction $V_{crit}$.

### 1.8 Node topology

d, g, s, b external; d′, s′ internal behind
$g_{d/s} = m/R_{D/S}$ (or $m/(R_{SH}\cdot\text{squares})$). $R=0$ ⇒ node
collapse d′≡d / s′≡s.

## 2. Flow explanation

1. Compute per-eval geometry factors ($\beta$, $C_{ox}$, overlaps, sat
   currents).
2. Get $v_{gs}, v_{ds}, v_{bs}$ (type-corrected node differences to s′);
   derive $v_{bd}, v_{gd}, v_{gb}$.
3. Limit: fetlim/limvds/pnjlim as §1.7 (skipped on init modes that seed
   voltages: MODEINITJCT seeds $v_{bs}=-1, v_{gs}=V_{T0}(T), v_{ds}=0$).
4. Bulk diodes → $I_{bs}, I_{bd}, g_{bs}, g_{bd}$.
5. Mode select on sign of $v_{ds}$; Shichman–Hodges 3-region current and
   $g_m, g_{ds}, g_{mbs}$ in swapped frame.
6. Junction depletion charge/cap (two-branch, $f$-constants above
   $F_C P_B$); integrate → fold $g_{eq}/i_{eq}$ into $g_{bd}/g_{bs}$ and RHS.
7. Meyer caps at current bias, average with previous timepoint halves, add
   overlaps; integrate $q_{gs}, q_{gd}, q_{gb}$ → conductances
   $g_{cgs},g_{cgd},g_{cgb}$ and equivalent currents.
8. Stamp: series conductances (d–d′, s–s′), channel ($g_{ds}, g_m,
   g_{mbs}$ with normal/reverse selectors $x_{nrm}/x_{rev}$), junctions,
   gate-cap conductances; RHS equivalent currents, all multiplied by type
   where signed.

State per instance: $v_{bs}, v_{bd}, v_{gs}, v_{ds}$, Meyer half-caps,
junction charges, gate charges (3 history slots for predictor).

## 3. Pseudo-code, CPU sequential

`x = [Vd, Vg, Vs, Vb, Vdp, Vsp]`, prep P holds temp-scaled params.

```
fn mos1_eval(x, P) -> (I[6], Q[6], J, C):
    ty = P.type
    vbs = ty*(x.Vb - x.Vsp); vgs = ty*(x.Vg - x.Vsp); vds = ty*(x.Vdp - x.Vsp)
    vbd = vbs - vds; vgd = vgs - vds; vgb = vgs - vbs

    (ibs, gbs) = junction(vbs, P.is_s);  (ibd, gbd) = junction(vbd, P.is_d)

    mode = vds >= 0 ? 1 : -1
    vb  = mode==1 ? vbs : vbd
    vgx = mode==1 ? vgs : vgd
    s   = vb <= 0 ? sqrt(P.phi - vb) : max(0, sqrt(P.phi) - vb/(2*sqrt(P.phi)))
    von = P.vbi*ty + P.gamma*s
    vgst = vgx - von;  vdsat = max(vgst, 0);  ab = s > 0 ? P.gamma/(2*s) : 0
    bp  = P.beta*(1 + P.lambda*vds*mode)

    if vgst <= 0:            id, gm, gds, gmbs = 0,0,0,0
    elif vgst <= vds*mode:   # saturation
        id  = 0.5*bp*vgst^2;         gm = bp*vgst
        gds = 0.5*P.lambda*P.beta*vgst^2;  gmbs = gm*ab
    else:                    # linear
        vdm = vds*mode
        id  = bp*vdm*(vgst - vdm/2); gm = bp*vdm
        gds = bp*(vgst - vdm) + P.lambda*P.beta*vdm*(vgst - vdm/2)
        gmbs = gm*ab

    # junction depletion charges: power-law below fc*pb, f2/f3/f4 quadratic above
    (qbs, cbs) = jcharge(vbs, P.s_side);  (qbd, cbd) = jcharge(vbd, P.d_side)

    # Meyer caps (half, non-constant); swap gs<->gd when mode<0
    (cgs_h, cgd_h, cgb_h) = qmeyer(mode>0 ? (vgs,vgd) : (vgd,vgs), vgb, von, vdsat, P.phi, P.cox)
    capgs = cgs_h + cgs_h_prev + P.cgso_w      # trapezoid with previous timepoint
    capgd = cgd_h + cgd_h_prev + P.cgdo_w
    capgb = cgb_h + cgb_h_prev + P.cgbo_l
    qgs += capgs*(vgs - vgs_prev); ...          # incremental Meyer charges

    # KCL currents (type applied), stamps per mos1load.c pattern
    I[dp] = ty*(mode*id - ibd + ...);  I[sp] = ...; I[b] = ty*(ibs + ibd); ...
    J: gdrain(d,dp), gsource(s,sp), channel(gds,gm,gmbs @ xnrm/xrev), gbd, gbs
    C: capgs/capgd/capgb on g row/cols, cbs/cbd on b
```

Our `mos1.zig` computes the same quantities through the AD scalar type; the
mode/region/junction branches select on values so each Newton iteration
differentiates one smooth composition.

## 4. Pseudo-code, GPU parallel (batched SoA)

```
kernel mos1_batch(g, desc, blob, x, env):
    for i = g.tid; i < desc.count; i += g.stride:
        v[0..6] = gather(x, gath[i*6..])          # d g s b d' s'
        vgs, vds, vbs = ty*diffs(v)               # ty from model SoA

        # mode handling without divergence: fold mode into signed frame
        m   = sign1(vds)                          # +1/-1
        vdm = m*vds
        vgx = select(m>0, vgs, vgs - vds)         # = vgd when reversed
        vb  = select(m>0, vbs, vbs - vds)

        s    = select(vb<=0, sqrt(P.phi - vb), max(0, sqrtphi - vb*inv2sqrtphi))
        von  = P.vbi_t + P.gamma*s
        vgst = vgx - von
        # branchless 3-region: linear formula with vd_eff = min(vdm, vgst),
        # zero-clamped by vgst<=0 mask — identical algebra:
        vde  = clamp(vdm, 0, max(vgst, 0))
        bp   = P.beta*(1 + P.lambda*vdm)
        on   = vgst > 0
        id   = on ? bp*vde*(vgst - 0.5*vde) : 0.0      # sat falls out at vde=vgst
        gm   = on ? bp*vde                    : 0.0    # + sat-region variants via
        gds  = on ? bp*(vgst - vde) + P.lambda*P.beta*vde*(vgst-0.5*vde) : 0.0
        gmbs = gm * P.gamma/(2*max(s,eps))

        (ibs,gbs) = junction(vbs); (ibd,gbd) = junction(vbs - vds)
        (qbs,cbs) = jcharge(vbs);  (qbd,cbd) = jcharge(vbs - vds)
        (cgs,cgd,cgb) = qmeyer_branchless(...)     # region masks -> select()
        # Meyer history (prev half-caps, prev vg*) lives in per-instance
        # state slots in the blob; env.alpha turns q into companion current

        scatter_add_kcl(g.rhs, gath[i*6..], m, ty, id, ibs, ibd, q...)
        if WITH_DIAG: scatter_add_diag(g.diag, gds, gm-selects, gbs, gbd, caps*alpha)

kernel mos1_limit_batch: fetlim/limvds/pnjlim per instance on gathered
    (x_new, x_old/lim) exactly as CPU; write lim[], flag junction-limited
    unknowns only (vbs/vbd) for the extra-iteration gate.
```

The saturated/linear unification via `vde = clamp(vdm, 0, vgst)` removes
the region branch entirely (the Shichman–Hodges linear expression
evaluated at $v_{de} = v_{gst}$ *is* the saturation expression); only the
cutoff mask remains, which is a predicated select.

## Noise model (in-device)

Contract: [noise-contract.md](noise-contract.md). Source-verified
against ngspice mos1noi.c:

| Generator | Branch | PSD |
|---|---|---|
| thermal RD | d'-d | $4kT\,g_{drain}$ |
| thermal RS | s'-s | $4kT\,g_{source}$ |
| channel thermal | d'-s' | $4kT\cdot\frac{2}{3}|g_m|$ |
| flicker | d'-s' | $\dfrac{K_F\,|I_D|^{A_F}}{f\cdot W\,m\,L_{eff}\,C_{ox}'^2}$ |

Notes: (a) the channel source is THERMNOISE with 2/3*gm -- our
`mos1.zig:183` currently tags it `.shot`, which the target hook must
correct (it is neither collected today, so no behavior change yet);
(b) the flicker denominator uses $C_{ox}'^2$ (oxideCapFactor squared),
not the textbook $C_{ox}L^2$ -- verified at mos1noi.c:57-61.
`noisePsd`: re-run the SS3 channel block for $g_m, I_D$; four PsdTerms.
GPU: subset of the eval kernel. Modern delta over ngspice: induced
gate noise and triode-correct channel noise (cf. JFET NLEV=3) -- absent
in every SPICE MOS level.

## Sources

- https://raw.githubusercontent.com/ngspice/ngspice/master/src/spicelib/devices/mos1/mos1load.c (fetched)
- https://raw.githubusercontent.com/ngspice/ngspice/master/src/spicelib/devices/mos1/mos1temp.c (fetched)
- https://raw.githubusercontent.com/ngspice/ngspice/master/src/spicelib/devices/devsup.c (fetched — DEVqmeyer, DEVfetlim, DEVlimvds, DEVpnjlim)

## Verification status

- §1.2–1.8, §2: **source-verified** against the fetched C files.
- §3/§4: derived pseudo-code (the branchless `vde` unification in §4 is our transformation, algebraically equal to the source's region split).

## Our implementation

- `src/devices/models/mos1.va`.
- Bench fixtures: `benchmark/fixtures/devices/mos1_transfer`, `mos1_output`, `mos1_body_effect`, `mos1_subthreshold`, `mos1_temp`, `mos1_pmos`, `mos1_large_signal`, `mosfet_l1`; `benchmark/fixtures/mosfet/{cmos_inverter,nand2,nmos_cs}`.
