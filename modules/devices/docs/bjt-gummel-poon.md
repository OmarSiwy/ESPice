# BJT — SPICE Gummel-Poon (Q element)

Reference: ngspice `bjt/bjtload.c`, `bjt/bjttemp.c`, `bjt/bjtnoise.c`.
Vertical NPN frame; PNP by type = −1 on voltages/currents; lateral
(`subs`) swaps which area scales the BC/substrate caps.

## 1. Mathematical specification

### 1.1 Topology

C–RC–c′, B–RB(bias-dep)–b′, E–RE–e′, substrate S. Junction voltages
$v_{be}, v_{bc}$ at the primed nodes; $v_{bx}$ = B(ext)–c′ (the
extrinsic BC cap sits outside RB); $v_{sub}$ = substrate junction.
Zero resistances collapse primed nodes.

### 1.2 Junction currents — all bias regions

Same smooth-cubic reverse continuation as the diode, per junction with
its own emission coefficient ($V_{tN} = N_F V_t$, $N_R V_t$; leakage
$N_E V_t$, $N_C V_t$; substrate $N_S V_t$):

$$
i(v; I_s, V_{tn}) = \begin{cases}
I_s\left(e^{v/V_{tn}} - 1\right) & v \ge -3V_{tn}\\
-I_s\left[1 + \left(\frac{3V_{tn}}{e\,v}\right)^3\right] & v < -3V_{tn}
\end{cases}
$$

$c_{be} = i(v_{be}; I_S(T))$, $c_{bc} = i(v_{bc}; I_S(T))$; leakage
components $c_{ben} = i(v_{be}; C_2 = I_{SE}(T))$,
$c_{bcn} = i(v_{bc}; C_4 = I_{SC}(T))$; substrate diode
$c_{dsub} = i(v_{sub}; I_{SS}(T))$. GMIN added to each leakage/substrate
conductance.

### 1.3 Base charge — Early + Webster (high injection)

$$q_1 = \frac{1}{1 - v_{bc}/V_{AF} - v_{be}/V_{AR}},\qquad
q_2 = \frac{c_{be}}{I_{KF}(T)} + \frac{c_{bc}}{I_{KR}(T)}$$

$$q_b = \frac{q_1}{2}\left(1 + (1 + 4q_2)^{N_K}\right)$$

($N_K$ default 0.5 → the familiar $\sqrt{1+4q_2}$; `nkf` param as in
VBIC). Derivatives $dq_b/dv_{be,bc}$ carried analytically.

### 1.4 Transport current and conductances

$$I_{CC} = \frac{c_{be} - c_{bc}}{q_b},\qquad
I_C = I_{CC} - \frac{c_{bc}}{\beta_R(T)} - c_{bcn},\qquad
I_B = \frac{c_{be}}{\beta_F(T)} + c_{ben} + \frac{c_{bc}}{\beta_R(T)} + c_{bcn}$$

$$g_o = \frac{g_{bc} + (c_{ex} - c_{bc})\,\frac{dq_b}{dv_{bc}}/q_b}{q_b},\qquad
g_m = \frac{g_{ex} - (c_{ex}-c_{bc})\,\frac{dq_b}{dv_{be}}/q_b}{q_b} - g_o$$

with $c_{ex} = c_{be}$, $g_{ex} = g_{be}$ except under **excess phase**
(PTF/TD ≠ 0): Weil's approximation, backward-Euler over the two
previous states —
$c_{ex} = c_{be}\frac{a_1}{1+a_1+a_2}$, $a_2 = 3\Delta t/t_d$,
$a_1 = a_2\Delta t/t_d$, plus the history recurrence on
state($c_{ex}/q_b$) (bjtload.c ~line 500).

### 1.5 Bias-dependent base resistance

$r_{b,pr} = R_{BM}(T)/A$, $r_{b,pi} = R_B(T)/A - r_{b,pr}$:

$$
R_{bb'} = \begin{cases}
r_{b,pr} + \dfrac{r_{b,pi}}{q_b} & I_{RB} \text{ not given}\\[6pt]
r_{b,pr} + 3r_{b,pi}\dfrac{\tan z - z}{z\tan^2 z},\quad
z = \dfrac{\sqrt{1 + 14.59025\,\frac{I_B}{I_{RB}A}} - 1}{2.4317\sqrt{I_B/(I_{RB}A)}} & I_{RB} \text{ given}
\end{cases}
$$

(current-crowding form; $g_x = 1/R_{bb'}$ stamps B–b′).

### 1.6 Charge storage

Bias-dependent forward transit time (Webster + Kirk empirics):

$$\tau_F' = \tau_F\left[1 + X_{TF}\,e^{v_{bc}/(1.44\,V_{TF})}\left(\frac{c_{be}}{c_{be} + I_{TF}A}\right)^2\right]$$

(implemented via `argtf/arg2/arg3` with the exact derivative folding of
bjtload.c: the diffusion charge is $\tau_F c_{be}(1+\text{argtf})/q_b$
including the $1/q_b$ base-widening division and cross-derivative
`geqcb` = $\partial Q_{be}/\partial v_{bc}$). Depletion parts: standard
two-branch F1/F2/F3 forms per junction —

$$Q_{be} = \tau_F' \frac{c_{be}}{q_b}\Big|_{\text{folded}} + \frac{P_E\,C_{JE}A}{1-M_{JE}}\left[1-(1-v_{be}/P_E)^{1-M_{JE}}\right]\ (v_{be} < F_C P_E;\ \text{quadratic above})$$

$Q_{bc} = \tau_R c_{bc} + $ depletion with $C_{JC}\cdot X_{CJC}$ (the
`baseFractionBCcap` split); $Q_{bx}$ = depletion only with
$C_{JC}(1-X_{CJC})$ between external base and c′; $Q_{sub}$: depletion
for $v_{sub}<0$, quadratic extension above 0.

### 1.7 Temperature (bjttemp.c)

$$I_S(T) = I_S\,e^{\left(\frac{T}{T_{nom}}-1\right)\frac{E_G}{V_t}}\left(\frac{T}{T_{nom}}\right)^{X_{TI}},\qquad
\beta_{F,R}(T) = \beta_{F,R}\left(\frac{T}{T_{nom}}\right)^{X_{TB}}$$

leakage saturation currents divide by the β temperature factor and use
$E_G$ with their emission coefficients; junction potentials/caps use
the standard SPICE intrinsic-shift mapping (diode.md §1.2);
$V_{crit}$ per junction. ISE/ISC given as C2/C4 multipliers when the
legacy form is used.

### 1.8 Limiting and stamps

pnjlim on $v_{be}, v_{bc}, v_{sub}$ (each with own Vcrit); MODEINITJCT
seeds $v_{be} = V_{crit}$, $v_{bc} = 0$. Stamp: gx (B–b′), RC/RE
conductances, then the classic 2-port
($g_\pi, g_\mu, g_m, g_o$) + cap companions (capbe with `geqcb`
cross-term, capbc, capbx, capsub) + substrate diode.

## 2. Flow explanation

1. Bias acquisition + bypass test on $(\hat c_c, \hat c_b)$.
2. pnjlim all three junctions (§1.8).
3. Junction currents (§1.2) → $q_1, q_2, q_b$ (§1.3) → excess-phase
   filter (§1.4) → $I_C, I_B$, conductances.
4. $R_{bb'}(q_b, I_B)$ (§1.5) — note it needs $I_B$, hence ordered after.
5. Charges (§1.6) — diffusion parts reuse the *already knee-folded*
   currents; integrator folds companions into $g$'s and RHS.
6. Convergence check on predicted vs actual $c_c, c_b$; state save;
   stamp.

State per instance: $v_{be}, v_{bc}, v_{sub}, v_{bx}$, currents,
conductances, four charges, excess-phase history ($c_{exbc}$, two
deep).

## 3. Pseudo-code, CPU sequential

```
fn bjt_eval(x, P) -> (I, Q, J, C):
    ty = P.type
    vbe = ty*(x.bp - x.ep); vbc = ty*(x.bp - x.cp)
    vbx = ty*(x.b - x.cp);  vsub = ty*(x.s - swap_node)

    (cbe,gbe) = junction(vbe, P.is_t, P.nf*vt)
    (cben,gben) = junction(vbe, P.ise_t, P.ne*vt) + gmin terms
    (cbc,gbc) = junction(vbc, P.is_t, P.nr*vt); (cbcn,gbcn) = ...
    (cdsub,gdsub) = junction(vsub, P.iss_t, P.ns*vt)

    q1 = 1/(1 - vbc*P.inv_vaf - vbe*P.inv_var)
    q2 = cbe*P.inv_ikf + cbc*P.inv_ikr
    qb = q1*(1 + pow(max(0,1+4*q2), P.nk))/2          # + dqb/dv analytic

    (cex,gex) = excess_phase(cbe, gbe, hist, dt, P.td) # identity when td=0
    ic = (cex - cbc)/qb - cbc/P.br_t - cbcn
    ib = cbe/P.bf_t + cben + cbc/P.br_t + cbcn
    gx = 1/rbb(qb, ib, P)                              # §1.5
    gm, go, gpi, gmu = conductances(...)               # §1.4

    tfp  = P.tf*(1 + xtf_term(vbc, cbe, P))
    Qbe  = tfp*cbe/qb + depletion(vbe, P.cje, P.pe, P.mje, P.fc)
    Qbc  = P.tr*cbc + depletion(vbc, P.cjc*P.xcjc, ...)
    Qbx  = depletion(vbx, P.cjc*(1-P.xcjc), ...)       # ext base to c'
    Qsub = depletion_or_quadratic(vsub, P.csub, ...)
    return stamps(ty, ...)
```

Our `bjt.zig` runs this chain through the AD scalar (branches select on
values); excess phase uses the history hook.

## 4. Pseudo-code, GPU parallel (batched SoA)

```
kernel bjt_batch(g, desc, blob, x, env):
    for i = g.tid; i < desc.count; i += g.stride:
        v = gather(x, gath[i*7..])            # c b e s c' b' e'
        p = prep[i]
        # four junctions: branchless smooth-cubic selects (as diode kernel)
        core = junctions -> qb -> ic/ib -> rbb -> charges   # straight-line;
        # the only data branches: vbe<fc*pe style charge splits -> select()
        # excess phase needs per-instance history state -> CPU-side batch
        # today (has_hist disqualifies GPU); td=0 batches run on device
        scatter_add(g.rhs, gath, kcl(core) + env.alpha*q + hist)
        if WITH_DIAG: scatter_add(g.diag, gpi+gmu+gx+..., alpha*caps)

kernel bjt_limit_batch: pnjlim(vbe), pnjlim(vbc), pnjlim(vsub) per lane
```

## Noise model (in-device)

Contract: [noise-contract.md](noise-contract.md). Source-verified
against bjtnoise.c:

| Generator | Branch | PSD |
|---|---|---|
| thermal RC | c′–c | $4kT\,g_{cpr}\,A\,m$ |
| thermal RB | b′–b | $4kT\,g_x\,m$ — **the modulated** $g_x$ state, so `noisePsd` must reuse the §1.5 value at the given x |
| thermal RE | e′–e | $4kT\,g_{epr}\,A\,m$ |
| shot $I_C$ | c′–e′ | $2q\,|I_C|\,m$ |
| shot $I_B$ | b′–e′ | $2q\,|I_B|\,m$ |
| flicker | b′–e′ | $m\,K_F\,|I_B|^{A_F}/f$ |

ngspice computes exactly these six; a modern in-device treatment could
add substrate-diode shot ($2q|c_{dsub}|$) and B–C correlation à la
HICUM — neither in the reference. `noisePsd` hook: recompute
$I_C, I_B, g_x$ from the gathered x (the §3 chain up to conductances),
emit six PsdTerms; GPU identical straight-line per lane. Our
`bjt.zig:282` currently declares only the three thermal gens — the shot
and flicker rows are the gap the hook closes.

## Sources

- https://raw.githubusercontent.com/ngspice/ngspice/master/src/spicelib/devices/bjt/bjtload.c (fetched)
- https://raw.githubusercontent.com/ngspice/ngspice/master/src/spicelib/devices/bjt/bjttemp.c (fetched)
- https://raw.githubusercontent.com/ngspice/ngspice/master/src/spicelib/devices/bjt/bjtnoise.c (fetched)

## Verification status

- §1.2–1.6, §1.8, noise table: **source-verified** against the fetched files (qb/NK form, crowding constants 14.59025/2.4317, Weil coefficients, XTF folding incl. geqcb, cap splits — all quoted from bjtload.c).
- §1.7 temperature: bjttemp.c fetched, key maps spot-checked; the C2/C4 legacy-parameter plumbing not fully transcribed (**partially verified**).

## Our implementation

- `modules/devices/src/bjt.zig`.
- Bench fixtures: `benchmark/fixtures/devices/bjt_npn`, `bjt_npn_gummel`, `bjt_npn_output`, `bjt_npn_early`, `bjt_npn_high_injection`, `bjt_npn_saturation`, `bjt_npn_temp`, `bjt_pnp`, `bjt_pnp_output`; `bjt/*`.
