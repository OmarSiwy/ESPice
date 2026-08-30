# Legacy MOS family — MOS2, MOS3, MOS6 (Sakurai–Newton), MOS9, BSIM1, BSIM2, MOSVAR

Reference: ngspice `mos2/mos2load.c`, `mos3/mos3load.c`,
`mos6/mos6load.c`, `mos9/mos9load.c` (fetched), `bsim1/`, `bsim2/`
(not fetched — structural), MOSVAR VA (our port header). All share the
MOS1 chassis (mos1-shichman-hodges.md): d′/s′ series nodes, bulk
diodes, Meyer gate caps (except BSIM1/2 charge-based), mode swap,
fetlim/limvds/pnjlim, SPICE temperature maps. Only the channel-current
block differs — documented per level below.

## 1. Mathematical specification (channel blocks)

### 1.1 MOS2 (Meyer–Grove analytic)

Full bulk-charge model: threshold from the exact depletion integral
(no $\gamma\sqrt{\cdot}$ linearization),

$$I_D = \beta\left[\left(v_{gs} - v_{bin} - \frac{\eta v_{ds}}{2}\right)v_{ds}
- \frac{2}{3}\gamma_{eff}\left((\phi + v_{ds} - v_{bs})^{3/2} - (\phi - v_{bs})^{3/2}\right)\right]$$

with short-channel $\gamma_{eff}$ (junction-curvature correction via
XJ), UCRIT/UEXP surface-mobility degradation
($\mu_{eff} = \mu_0 (u_{crit}\varepsilon_{si}/(C_{ox}(v_{gs}-v_{th})))^{u_{exp}}$),
VMAX velocity-saturation $V_{dsat}$ (Baum's cubic when VMAX=0, else the
Grove-Frohman iteration), weak-inversion exponential below
$v_{on} = v_{bin} + \gamma_{eff}\sqrt{\phi - v_{bs}} + $ fast-surface-state
term (NFS), and channel-length modulation from the depletion
approximation $\Delta L = x_d\sqrt{\ldots}$. The mos2load.c block is
~500 lines of exactly this chain (fetched; transcribe on demand — MOS2
is historical, ngspice itself recommends level 3+).

### 1.2 MOS3 (empirical short-channel)

$$V_{th} = V_{bi} - \frac{8.14\times10^{-22}\,\eta}{C_{ox}L_{eff}^3}\,v_{ds}
+ \gamma\,f_s\sqrt{\Phi_s} + f_n\,\Phi_s\ \text{terms}$$

($f_s$ = Dang's short-channel depletion-sharing factor from XJ/LD,
$f_n$ = narrow-width DELTA term); mobility
$\mu_{eff} = \mu_0/(1 + \theta(v_{gs}-v_{th}))$ then velocity
saturation $1/(1 + \mu_{eff}v_{ds}/(v_{max}L_{eff}))$;
$V_{dsat}$ closed-form with $f_{drain}$; weak inversion via
$v_{on} = v_{th} + x_n V_t$ (NFS), exponential below; CLM from
$\Delta L$ with KAPPA and the $g_{ds}$ clamp. (mos3load.c fetched;
block-level verified, coefficients not all transcribed.)

### 1.3 MOS6 — Sakurai–Newton (source-verified, failing fixtures)

Power-law empirical model, three regions:

$$v_{on} = V_{bi}(T)\,\text{type} + \gamma\,s(v_b) - \gamma_1 v_b - \sigma\,v_{ds},\qquad
v_{gon} = v_{gx} - v_{on}$$

($s(v_b) = \sqrt{\phi - v_b}$ with the MOS1 Taylor guard; $\gamma_1$
linear body term; $\sigma$ = DIBL). For $v_{gon} > 0$:

$$V_{dsat} = K_V\,v_{gon}^{N_V},\qquad
I_{dsat} = \beta_c\,v_{gon}^{N_C},\quad \beta_c = K_C\frac{W\,m}{L_{eff}}$$

$$\lambda = \lambda_0 - \lambda_1 v_b,\qquad
I_D = \begin{cases}
I_{dsat}(1+\lambda v_{ds}) & v_{ds} \ge V_{dsat}\ \text{(saturation)}\\[3pt]
I_{dsat}(1+\lambda v_{ds})\left(2 - \frac{v_{ds}}{V_{dsat}}\right)\frac{v_{ds}}{V_{dsat}} & v_{ds} < V_{dsat}\ \text{(linear)}
\end{cases}
$$

with $g_m = I_D N_C/v_{gon}$ (+ region corrections as in mos6load.c),
$g_{ds} = g_m\sigma + I_{dsat}\lambda$ (+ linear-region terms),
$g_{mbs} = g_m(\gamma_1 + \gamma/2s)$-form. Defaults $N_V = 0.5$,
$N_C$ from KC fit; the parabolic linear-region blend is only $C^0$ in
$g_{ds}$ at $V_{dsat}$ — a known convergence wart of level 6 (relevant
to the `mos6_inverter` FAIL: check our blend matches this exact
$(2-v)v$ form and the $g$ corrections before suspecting anything else).

### 1.4 MOS9

Modified level 3 (same skeleton, corrected $\Delta L$ and subthreshold
junction handling; ngspice mos9load.c differs from mos3load.c in a few
dozen lines). Treat as MOS3 with the mos9load.c deltas — fetched,
diffable when needed.

### 1.5 BSIM1 / BSIM2 (Berkeley polynomial)

BSIM1: flat-band-referenced threshold with 24 L/W-interpolated
polynomial coefficients ($v_{fb}, \phi_s, K_1, K_2, \eta, \beta_0,
U_0, U_1, X_{2*}, X_{3*}$…), drain current in three smooth-matched
regions with the $a$-bulk factor $1 + \frac{gK_1}{2\sqrt{\phi - v_{bs}}}$;
charge-based capacitances (40/60 etc. partition). BSIM2 refines with
$V_{gg}/V_{gt}$ transition polynomials and improved subthreshold +
output conductance. Both are parameter-extraction-era models: no
physical defaults — every coefficient comes from the card, so the doc
value is the *structure*, not derivations. (Loads not fetched; marked
structural. Our `bsim1.zig`/`bsim2.zig` ports are the operative
reference; `bsim2_ngspice` fixture pins bit-behavior.)

### 1.6 MOSVAR (varactor)

PSP-based MOS varactor 1.4.0 (our port): gate–bulk two-terminal with
surface-potential C–V (accumulation through inversion), poly depletion,
QM correction, gate tunneling, and an RC relaxation node for inversion
response time TAU (topology in mosvar.zig header: g–Rgsal–gii–Rgpv–gi–
[Cox]–ci–Rend–bi–Rsub–b + τ node). Normative source: the MOSVAR VA
(CMC); our doc pointer only — C–V math is PSP-family (psp103.md §1.4
machinery).

## 2. Flow explanation

MOS1's flow (mos1-shichman-hodges.md §2) verbatim, with the channel
block swapped per level; MOS2 adds its internal $V_{dsat}$ iteration
(Newton on the cubic when VMAX given), MOS3/9 are closed-form; MOS6 is
closed-form with the $C^0$ seam noted above. BSIM1/2 replace Meyer caps
with their own charge equations (charge-conserving, stamped like our q
functions). MOSVAR is charge-dominated: eval carries only leakage,
everything lives in q.

## 3. Pseudo-code, CPU sequential

MOS1 skeleton + per-level channel:

```
fn mos6_channel(vgx, vds, vb, P):            # the verified one
    s    = vb <= 0 ? sqrt(P.phi - vb) : taylor_guard(...)
    von  = P.vbi_t*P.ty + P.gamma*s - P.gamma1*vb - P.sigma*vds
    vgon = vgx - von
    if vgon <= 0: return (0,0,0,0)
    vdsat = P.kv * pow(vgon, P.nv)
    idsat = P.betac * pow(vgon, P.nc)
    lam   = P.lamda0 - P.lamda1*vb
    id    = idsat*(1 + lam*vds)
    gm    = id*P.nc/vgon; gds = gm*P.sigma + idsat*lam
    gmbs  = gm*(P.gamma1 + P.gamma/(2*s)) - idsat*P.lamda1*vds
    if vds < vdsat:                           # parabolic blend
        u = vds/vdsat; f = (2-u)*u
        (id, gm, gds, gmbs) = blend(f, du_corrections per mos6load.c)
    return (id, gm, gds, gmbs)
```

(MOS2/MOS3 channels: same signature, chains per §1.1/§1.2.)

## 4. Pseudo-code, GPU parallel (batched SoA)

MOS1's kernel (mos1-shichman-hodges.md §4) with the channel function
swapped; MOS6's `pow(vgon, nc)` pair is the only transcendental —
cheaper than MOS1's junctions. MOS2's internal Vdsat Newton is a fixed
small iteration (bounded trips, no divergence concern). BSIM1/2 are
polynomial — ideal SIMT. Batch key = level (separate device types
already).

## Noise model (in-device)

Contract: [noise-contract.md](noise-contract.md). ngspice pattern for
every level here (mos1noi.c verified; mos2/3/6/9 noise files are the
same four-generator template):

| Generator | Branch | PSD |
|---|---|---|
| thermal RD / RS | d′–d, s′–s | $4kT\,g_{d/s}$ |
| channel thermal | d′–s′ | $4kT\cdot\frac{2}{3}|g_m|$ |
| flicker | d′–s′ | $\dfrac{K_F\,|I_D|^{A_F}}{f\cdot W\,m\,L_{eff}\,C_{ox}'^2}$ (mos1noi.c denominator, verified — note $C_{ox}'^2$, not the textbook $C_{ox}L^2$) |

BSIM1/2: ngspice uses the same template with model KF/AF. MOSVAR: VA
carries its own noise (gate-tunneling shot + thermal of the R network)
— transcribe from the VA when ported. What a modern treatment adds over
ngspice for all legacy MOS: induced gate noise and $g_{ds}$-correct
channel noise in triode (the $\frac{2}{3}g_m$ form is a saturation
approximation — compare JFET NLEV=3's $\alpha$-blend, which ngspice
never backported to MOS). `noisePsd`: channel gens need $g_m, I_D$ at
x — the §3 channel function re-run; GPU straight-line.

## Sources

- https://raw.githubusercontent.com/ngspice/ngspice/master/src/spicelib/devices/mos6/mos6load.c (fetched)
- https://raw.githubusercontent.com/ngspice/ngspice/master/src/spicelib/devices/mos2/mos2load.c, mos3/mos3load.c, mos9/mos9load.c (fetched, block-level read)
- https://raw.githubusercontent.com/ngspice/ngspice/master/src/spicelib/devices/mos1/mos1noi.c (fetched — noise template)
- BSIM1/BSIM2: not fetched (structural; our ports + `bsim2_ngspice` fixture are the pin).

## Verification status

- §1.3 MOS6 (von/vdsat/idsat/λ/blend + conductances): **source-verified**.
- §1.1/§1.2/§1.4: **block-level verified** (files fetched and read for structure; full coefficient chains not transcribed).
- §1.5 BSIM1/2, §1.6 MOSVAR: **structural/derived**.
- Noise: mos1noi.c verified; other levels asserted same-template (**derived** for mos2/3/6/9 noise files specifically).

## Our implementation

- `src/devices/{mos2,mos3,mos6,mos9,bsim1,bsim2,mosvar}.zig`.
- Bench fixtures: `devices/mos2*`, `mos3*`, `mos6_inverter` (FAIL 1.09e-1), `mos6_simpleinv` (FAIL 1.13e-2), `mos6`, `mos9`, `bsim1`, `bsim2`, `bsim2_ngspice`.
