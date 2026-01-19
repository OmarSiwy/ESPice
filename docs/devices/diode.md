# Junction Diode (SPICE level 1/3) — incl. breakdown and DEVpnjlim

Reference: ngspice `dio/dioload.c`, `dio/diotemp.c`, `devsup.c` (DEVpnjlim).

## 1. Mathematical specification

### 1.1 Symbols and units

| Symbol | Param | Units | Meaning |
|---|---|---|---|
| $I_S$ | IS | A | saturation current (per unit area) |
| $J_{SW}$ | JSW | A | sidewall saturation current (per unit perimeter) |
| $N$ | N | — | emission coefficient |
| $N_S$ | NS | — | sidewall emission coefficient |
| $N_{BV}$ | NBV | — | breakdown emission coefficient |
| $R_S$ | RS | Ω | ohmic series resistance |
| $BV$, $I_{BV}$ | BV, IBV | V, A | reverse breakdown voltage / current at breakdown |
| $C_{J0}$, $V_J$, $M$ | CJO, VJ, M | F, V, — | zero-bias junction cap, built-in potential, grading coefficient |
| $F_C$ | FC | — | forward-bias depletion switchover coefficient |
| $\tau_T$ | TT | s | transit time |
| $E_g$ | EG | eV | activation energy |
| $X_{TI}$ | XTI | — | saturation-current temperature exponent |
| $A$, $P_J$ | area, pj | —, — | area / perimeter multipliers (instance) |
| $V_t$ | — | V | thermal voltage $kT/q$ |

Derived: $V_{te} = N V_t$, $V_{te,sw} = N_S V_t$, $V_{te,brk} = N_{BV} V_t$.
Junction voltage $v_d = V_{p'} - V_n$ (internal anode to cathode).

### 1.2 Temperature scaling (diotemp.c)

Bandgap (silicon default form):

$$E_g(T) = 1.16 - \frac{7.02\times10^{-4}\,T^2}{T + 1108} \quad \text{[eV]}$$

Saturation currents (evaluated at device temperature $T$, nominal $T_{nom}$):

$$I_S(T) = I_S\,A\,\exp\!\left[\left(\frac{T}{T_{nom}}-1\right)\frac{E_g}{N V_t} + \frac{X_{TI}}{N}\ln\frac{T}{T_{nom}}\right]$$

(sidewall identical with $J_{SW} P_J$ and $N_S$; tunneling currents use $K_{EG} E_g$ and $X_{TI,tun}$ with no $1/N$).

Junction potential and capacitance, tlevc = 0 (SPICE default). With
$\phi(T)$ the intrinsic-shift form ($T_{ref} = 300.15\,$K, `fact` $= T/T_{ref}$):

$$
\begin{aligned}
\text{pbfact}(T) &= -2 V_t \left[1.5 \ln(T/T_{ref}) + \frac{q\,\text{arg}(T)}{1}\right], \quad
\text{arg}(T) = -\frac{E_g(T)}{2kT} + \frac{1.1150877}{2 k\,T_{ref}} \\
p_{bo} &= \frac{V_J - \text{pbfact}(T_{nom})}{T_{nom}/T_{ref}}, \qquad
V_J(T) = \text{pbfact}(T) + \frac{T}{T_{ref}} p_{bo} \\
C_{J0}(T) &= C_{J0}\cdot\frac{1 + M\left[4\times10^{-4}(T - T_{ref}) - \gamma_{new}\right]}{1 + M\left[4\times10^{-4}(T_{nom} - T_{ref}) - \gamma_{old}\right]},
\quad \gamma_{\{old,new\}} = \frac{V_J^{\{nom,T\}} - p_{bo}}{p_{bo}}
\end{aligned}
$$

tlevc = 1 (linear): $V_J(T) = V_J - t_{pb}(T - T_{ref})$, $C_{J0}(T) = C_{J0}(1 + c_{ta}(T - T_{ref}))$.

Critical voltage (used by pnjlim and cold-start seed):

$$V_{crit} = V_{te}\,\ln\!\frac{V_{te}}{\sqrt{2}\,I_S(T)}$$

Breakdown voltage matching. Given temperature-adjusted $BV(T)$
($BV - t_{cv}\,\Delta T$ for tlev=0, $BV(1 - t_{cv}\Delta T)$ for tlev≠0)
and $c_{bv} = \max(I_{BV},\, I_S(T)\,BV(T)/V_t)$, ngspice solves for the
effective $x_{bv}$ such that the breakdown exponential passes through
$(−x_{bv}, −c_{bv})$ by fixed-point iteration (≤25 iterations):

$$x_{bv}^{(k+1)} = BV(T) - N_{BV} V_t \ln\!\left(\frac{c_{bv}}{I_S(T)} + 1 - \frac{x_{bv}^{(k)}}{V_t}\right)$$

Series conductance: $g_{spr} = \dfrac{A}{R_S\,[1 + t_{rs1}\Delta T + t_{rs2}\Delta T^2]}$.

Depletion-charge linearization constants (recomputed at $T$), $x_{fc}=\ln(1-F_C)$:

$$F_1 = \frac{V_J(T)\left[1 - e^{(1-M)x_{fc}}\right]}{1-M},\quad F_2 = e^{(1+M)x_{fc}},\quad F_3 = 1 - F_C(1+M)$$

### 1.3 DC current — all bias regions (dioload.c)

Bottom junction (sidewall identical with its own $V_{te,sw}$; if NS not
given the sidewall saturation current is merged into $I_S$):

$$
I_d(v_d) =
\begin{cases}
I_S\left(e^{v_d/V_{te}} - 1\right), & v_d \ge -3V_{te} \quad\text{(forward)}\\[4pt]
-I_S\left[1 + \left(\dfrac{3V_{te}}{e\,v_d}\right)^{3}\right], & -BV \le v_d < -3V_{te} \quad\text{(reverse)}\\[6pt]
-I_S\, e^{-(BV + v_d)/V_{te,brk}}, & v_d < -BV \quad\text{(breakdown)}
\end{cases}
$$

with conductances

$$
g_d =
\begin{cases}
I_S e^{v_d/V_{te}} / V_{te} \\
3 I_S \left(3V_{te}/(e\,v_d)\right)^3 / v_d \\
I_S e^{-(BV+v_d)/V_{te,brk}} / V_{te,brk}
\end{cases}
$$

The reverse branch is the smooth cubic $-I_S(1 + (3V_{te}/(e\,v_d))^3)$ —
NOT the raw Shockley $-I_S$ — so $I_d$ and $g_d$ are $C^1$ at $v_d = -3V_{te}$
and $g_d$ never collapses to zero in reverse.

Tunneling (both bottom and sidewall, reverse-directed exponential):

$$I_{tun} = -I_{S,tun}(T)\left(e^{-v_d/(N_{tun} V_t)} - 1\right)$$

High-injection knee (forward, only if $I_{KF} > 0$ and $I_d > 10^{-18}$):

$$I_d' = \frac{I_d}{1 + \sqrt{I_d / I_{KF}}}, \qquad
g_d' = \frac{(1+s)\,g_d - I_d\,g_d/(2 s I_{KF})}{1 + 2s + I_d/I_{KF}},\quad s = \sqrt{I_d/I_{KF}}$$

(reverse: same with $I_{KR}$, $s = \sqrt{-I_d/I_{KR}}$). Then GMIN:
$I_d \mathrel{+}= g_{min} v_d$, $g_d \mathrel{+}= g_{min}$.

### 1.4 Charge / capacitance

Depletion, below switchover $v_d < F_C V_J(T)$:

$$Q_{dep} = \frac{C_{J0}(T)\,V_J(T)}{1-M}\left[1 - \left(1 - \frac{v_d}{V_J}\right)^{1-M}\right], \qquad
C_{dep} = C_{J0}(T)\left(1 - \frac{v_d}{V_J}\right)^{-M}$$

Above switchover (quadratic extension, continuous in $Q$ and $C$):

$$Q_{dep} = C_{J0} F_1 + \frac{C_{J0}}{F_2}\left[F_3(v_d - F_C V_J) + \frac{M}{2V_J}\left(v_d^2 - (F_C V_J)^2\right)\right],\quad
C_{dep} = \frac{C_{J0}}{F_2}\left(F_3 + \frac{M v_d}{V_J}\right)$$

Sidewall depletion identical with CJP/PHP/MJSW/FCS. Diffusion charge:
$Q_{diff} = \tau_T(T)\, I_{d,bottom}$, $C_{diff} = \tau_T g_{d,bottom}$.
Total device charge sits between $p'$ and $n$.

### 1.5 Junction limiting — DEVpnjlim as math

Given the Newton proposal $v_{new}$ and previous iterate $v_{old}$:

$$
\text{pnjlim}(v_{new}, v_{old}) =
\begin{cases}
v_{old} + V_t\left(2 + \ln\left(\frac{v_{new}-v_{old}}{V_t} - 2\right)\right), & v_{new} > V_{crit},\ |v_{new}-v_{old}| > 2V_t,\ v_{old} > 0,\ \frac{v_{new}-v_{old}}{V_t} > 0 \\
v_{old} - V_t\left(2 + \ln\left(2 - \frac{v_{new}-v_{old}}{V_t}\right)\right), & \text{same but } \frac{v_{new}-v_{old}}{V_t} \le 0 \\
V_t \ln(v_{new}/V_t), & v_{new} > V_{crit},\ |v_{new}-v_{old}| > 2V_t,\ v_{old} \le 0 \\
\max(v_{new},\, -v_{old}-1), & v_{new} < 0,\ v_{old} > 0 \\
\max(v_{new},\, 2 v_{old}-1), & v_{new} < 0,\ v_{old} \le 0 \\
v_{new}, & \text{otherwise}
\end{cases}
$$

The step is limited *relative to $v_{old}$* (log-compressed walk), which is
why it settles instead of dead-locking Newton the way absolute clamps do.
A limited step sets the "check" flag → the iteration is not allowed to
declare convergence.

Breakdown mirroring: if BV given and
$v_d < \min(0, -BV + 10 V_{te,brk})$, pnjlim runs on the mirrored voltage
$\tilde v = -(v_d + BV)$ with $V_t \to V_{te,brk}$, then un-mirrors:
$v_d = -(\text{pnjlim}(\tilde v_{new}, \tilde v_{old}) + BV)$. The breakdown
exponential is thereby limited exactly like a forward junction.

### 1.6 Node collapse and cold start

- $R_S = 0 \Rightarrow p' \equiv p$ (DIOsetup: `posPrimeNode = posNode`). No
  tie conductance — the row is merged.
- MODEINITJCT (first OP iteration): the diode evaluates at $v_d = V_{crit}$
  rather than the (zero) node vector, so iteration 1 linearizes on the
  exponential's shoulder.

## 2. Flow explanation

Per Newton iteration and instance:

1. **Bias acquisition**: $v_d$ from the solution vector (or from init mode:
   IC value, 0 if OFF, $V_{crit}$ at MODEINITJCT, predictor in transient).
2. **Limiting**: breakdown-region test first (mirrored pnjlim), else plain
   pnjlim against the stored previous $v_d$. Store the check flag.
3. **Region selection** on the limited $v_d$: forward / smooth-cubic
   reverse / breakdown exponential — three-way branch, then tunneling
   add-on, then IKF/IKR knee scaling of the summed current, then GMIN.
4. **Charge** (transient/AC only): depletion (two-branch: power-law below
   $F_C V_J$, quadratic above) + sidewall + diffusion $\tau_T I_d$. The
   integrator turns $(Q, C)$ into companion $(g_{eq}, i_{eq})$ which fold
   into $g_d$/RHS.
5. **State**: $v_d, I_d, g_d$ saved for next iteration's bypass check,
   limiting, and convergence test ($|\hat I - I| <$ reltol·max + abstol).
6. **MNA stamp**: RHS current $I_{eq} = I_d - g_d v_d$ into $n$ (+) and $p'$
   (−); matrix $g_{spr}$ on $(p,p)$, $(p',p')$, $-(p,p')$, $-(p',p)$; $g_d$
   on $(n,n)$, $(p',p')$, $-(n,p')$, $-(p',n)$.

Our implementation replaces steps 3–4's hand derivatives with dual-number
AD over `eval`/`q` value functions; the region branches select on `.val()`
only, so AD sees a fixed smooth composition per iteration.

## 3. Pseudo-code, CPU sequential

One device, pure function. `x = [Vp, Vn, Vpp]`, params pre-scaled at temp.

```
fn diode_eval(x, P) -> (I[3], Q[3], J[3][3], C[3][3]):
    vd = x.Vpp - x.Vn

    # --- region-selected junction current + analytic gd ---
    if vd >= -3*P.vte:
        e  = exp(min(vd/P.vte, 80))
        id = P.is_t*(e - 1);            gd = P.is_t*e/P.vte
    elif not P.has_bv or vd >= -P.bv_t:
        a  = (3*P.vte/(E*vd))^3
        id = -P.is_t*(1 + a);           gd = 3*P.is_t*a/vd
    else:
        e  = exp(-(P.bv_t + vd)/P.vtebrk)
        id = -P.is_t*e;                 gd = P.is_t*e/P.vtebrk

    id += sidewall(vd)                  # same 3 regions, vte_sw
    id -= P.jtun_t*(exp(-vd/P.vtetun) - 1)   # tunneling (+gd term)

    if id >= 0 and P.ikf > 0:           # knee
        s = sqrt(id/P.ikf)
        gd = ((1+s)*gd - id*gd/(2*s*P.ikf)) / (1 + 2*s + id/P.ikf)
        id = id/(1+s)
    # (mirror for ikr when id < 0)
    id += GMIN*vd; gd += GMIN

    # --- charge, two-branch depletion + diffusion ---
    if vd < P.fc*P.vj_t:
        arg = 1 - vd/P.vj_t; s = arg^(-P.m)
        q = P.cj_t*P.vj_t*(1 - arg*s)/(1 - P.m);  c = P.cj_t*s
    else:
        q = P.cj_t*P.f1 + (P.cj_t/P.f2)*(P.f3*(vd - P.fcvj)
              + P.m/(2*P.vj_t)*(vd^2 - P.fcvj^2))
        c = (P.cj_t/P.f2)*(P.f3 + P.m*vd/P.vj_t)
    q += P.tt*id_bottom;  c += P.tt*gd_bottom     # diffusion

    irs = (x.Vp - x.Vpp)*P.gspr

    I = [ irs,            -id,  id - irs ]        # p, n, p'
    Q = [ 0,              -q,   q        ]
    J = stamp(gd: (pp,pp)+(n,n)-(pp,n)-(n,pp); gspr: (p,p)+(pp,pp)-(p,pp)-(pp,p))
    C = stamp(c:  (pp,pp)+(n,n)-(pp,n)-(n,pp))
    return (I, Q, J, C)

fn diode_limit(x_new, x_old, P) -> x_lim:
    vdn = x_new.Vpp - x_new.Vn;  vdo = x_old.Vpp - x_old.Vn
    if P.has_bv and vdn < min(0, -P.bv_t + 10*P.vtebrk):
        vd = -(pnjlim(-(vdn+P.bv_t), -(vdo+P.bv_t), P.vtebrk, P.vcrit) + P.bv_t)
    else:
        vd = pnjlim(vdn, vdo, P.vte, P.vcrit)
    x_lim.Vpp = x_new.Vpp + (vd - vdn)            # correction on p' only
```

## 4. Pseudo-code, GPU parallel (batched SoA)

Thread-per-instance over a batch of N diodes; `gath[i*3+u]` maps local
unknown u to the global x index; models/instances/prep are SoA arrays;
stamps scatter-add into the global residual/diag.

```
kernel diode_batch(g, desc, blob, x_global, env):
    gath  = blob + desc.off_gath          # u32[N*3]
    prep  = blob + desc.off_prep          # f64 SoA: is_t, inv_vte, bv_t, ...
    lim   = blob + desc.off_lim           # per-instance limited voltages

    for i = g.tid; i < desc.count; i += g.stride:      # grid-stride
        # gather (3 coalesced-ish loads via index array)
        vp  = x_global[gath[i*3+0]]
        vn  = x_global[gath[i*3+1]]
        vpp = x_global[gath[i*3+2]]        # == vp when collapsed (same index)
        vd  = vpp - vn

        # branchless region select: compute all three region currents on
        # clamped args, pick with two comparisons (predicated selects,
        # no divergent memory access; exp() is the cost either way)
        ef   = exp(min(vd*p.inv_vte, 80.0))
        i_f  = p.is_t*(ef - 1.0)
        a    = cube(3.0/(E*vd*p.inv_vte));  i_r = -p.is_t*(1.0 + a)
        eb   = exp(min(-(p.bv_t + vd)*p.inv_vtebrk, 80.0))
        i_b  = -p.is_t*eb
        in_fwd = vd >= -3.0*p.vte;  in_brk = p.has_bv & (vd < -p.bv_t)
        id  = select(in_fwd, i_f, select(in_brk, i_b, i_r))    # gd likewise

        id += tunneling(vd)                       # unconditional (0 when jtun=0)
        s   = sqrt(max(abs(id)*p.inv_ik, 0.0) + 1.0)  # knee, inv_ik pre-selected
        id /= s                                   # (exact gd folded analytically)
        id += GMIN*vd

        q   = depletion_charge(vd) + p.tt*id_bottom   # two-branch on fc*vj:
                                                      # both branches cheap poly,
                                                      # select() not branch
        irs = (vp - vpp)*p.gspr

        # scatter-add KCL residuals (atomicAdd — instances share nodes)
        atomicAdd(&g.rhs[gath[i*3+0]],  irs)
        atomicAdd(&g.rhs[gath[i*3+1]], -id  + alpha*(-q) + hist_n)
        atomicAdd(&g.rhs[gath[i*3+2]],  id - irs + alpha*q + hist_pp)
        if WITH_DIAG:                             # Jacobian diagonal for precond
            atomicAdd(&g.diag[gath[i*3+0]], p.gspr)
            atomicAdd(&g.diag[gath[i*3+1]], gd + alpha*c)
            atomicAdd(&g.diag[gath[i*3+2]], gd + p.gspr + alpha*c)

kernel diode_limit_batch(...):   # mirrors CPU limit(); flags any change
    for i = tid..count: lim[i*3..] = pnjlim-corrected gather(x)
```

Notes: no allocation; all temp-dependent constants precomputed host-side
into the prep blob; the only warp divergence left is the `exp` argument
range, which is data-uniform for same-model batches.

## Noise model (in-device)

Contract: [noise-contract.md](noise-contract.md). Source-verified
against ngspice dionoise.c:

| Generator (`noise_gens`) | Branch | PSD |
|---|---|---|
| thermal RS | p'-p | $4kT\,g_{spr}\,A\,m$ |
| shot junction | p'-n | $2q\,|I_d|$ (stored state current) |
| flicker | p'-n | $m\,K_F\,|I_d/m|^{A_F}/f$ |

Our `diode.zig` declares exactly these three gens; today only thermal
is collected (noise-contract.md SS1). `noisePsd` hook: re-run SS3's
current chain at the gathered x for $I_d$, emit the three PsdTerms.
GPU: strict subset of the eval kernel, straight-line per lane.
ngspice vs modern: identical -- nothing more exists for a diode.

## Sources

- https://raw.githubusercontent.com/ngspice/ngspice/master/src/spicelib/devices/dio/dioload.c (fetched)
- https://raw.githubusercontent.com/ngspice/ngspice/master/src/spicelib/devices/dio/diotemp.c (fetched)
- https://raw.githubusercontent.com/ngspice/ngspice/master/src/spicelib/devices/devsup.c (fetched — DEVpnjlim)

## Verification status

- §1.2–1.6 (temp scaling, regions, knee, charge, pnjlim, collapse, seed): **source-verified** against fetched ngspice C.
- §3/§4 pseudo-code: derived from the sources + this repo's device contract; not a line-by-line port.

## Our implementation

- `src/devices/models/diode.va` (eval/q/limit/collapse/seed; note: our eval uses the clamped Shockley + constant $-I_S$ deep-reverse instead of ngspice's smooth cubic reverse branch, and uses IBV directly as breakdown pre-exponential — see comments there).
- Bench fixtures: `benchmark/fixtures/devices/diode`, `diode_breakdown`, `diode_capacitance`, `diode_high_injection`, `diode_iv_sweep`, `diode_recombination`, `diode_temp`.
