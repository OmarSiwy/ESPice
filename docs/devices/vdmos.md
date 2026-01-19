# VDMOS — vertical power MOSFET (body diode, quasi-saturation, Cgd hysteresis)

Reference: ngspice VDMOS (M-level `VDMOS` model, ngspice ≥ 28; the
GitHub mirror we fetch from predates the vdmos directory, so the
normative equations below are grounded in our port `vdmos.zig` — which
was written against ngspice's vdmosload.c — and marked derived where
noted). The model is deliberately simple: datasheet-fittable, not
physical.

## 1. Mathematical specification

### 1.1 Topology (vdmos.zig header, matches ngspice)

D–RD–d′, G–RG–g′, S–RS–s′; channel d′–s′ controlled by $v_{g's'}$;
**body diode** s′→b′ with series RB to d′ (the reverse-conduction
path); fixed shunt RDS d′–s′; GMIN d′–s′. Self-heating parameters
(RTHJC/RTHCA/CTHJ) exist for the electro-thermal variant.

### 1.2 Channel — level-1 core + power-MOS extensions

MOS1 Shichman–Hodges three-region core
($\beta = KP\,W/(L-2L_D)\cdot m$, $\lambda$, no body effect — VDMOS has
no separate bulk terminal) with:

- **Mobility degradation**: $\beta \to \beta/(1 + \theta\,v_{gst})$.
- **Triode shaping**: MTRIODE scales the linear region
  ($I_{lin} \propto m_{tr}$-adjusted knee) — datasheet knob for the
  ohmic-region slope.
- **Subthreshold**: smooth exponential turn-on
  $v_{gst,eff} = k_{sub}\ln(1 + e^{v_{gst}/k_{sub}})$ (KSUBTHRES width,
  SUBSHIFT offset, tksubthres1/2 temp coefficients) — replaces the hard
  cutoff, C∞.
- **Quasi-saturation** (RQ/VQ): a drain-side degeneration that softens
  the sat-region current at high $v_{ds}$ — implemented as a
  bias-dependent series drop $R_Q/(1 + v_{ds}/V_Q)$-form in the drain
  path (epi-layer velocity saturation surrogate). This is what makes
  high-current output curves bend below the ideal MOS1 saturation.

### 1.3 Body diode

Full diode (diode.md) between s′ and d′ via b′: $I_S$, N, breakdown
BV/IBV/NBV (mirrored pnjlim), RB series, depletion cap CJO/VJ/MJ/FC,
transit time TT, temperature via EG/XTI. This diode carries the
freewheeling current in power bridges — its recovery (TT) and
breakdown are first-order behaviors, not parasitics.

### 1.4 Gate capacitances — the VDMOS-specific part

$C_{gs}$ constant. $C_{gd}$ is the datasheet-style nonlinear Miller
capacitance interpolating between CGDMIN and CGDMAX as a function of
$v_{gd}$ (not charge-derived):

$$C_{gd}(v_{gd}) = C_{gd,min} + \frac{C_{gd,max} - C_{gd,min}}{2}\left(1 + \tanh\!\big(a\,v_{gd}\big)\right)$$

(parameter A = transition steepness). This reproduces the gate-charge
plateau (Miller step) that dominates switching loss.

### 1.5 Temperature

$V_{TO}(T) = V_{TO} - t_{cvth}\Delta T$; $KP(T) \propto (T/T_{nom})^{\mu}$
(MU default −1.5); subthreshold width via tksubthres1/2; resistances
quadratic (trd/trg/trs/trb 1/2); diode per diode.md. TEXP0/TEXP1 shape
the RDS(on) temperature curve — the datasheet quantity.

## 2. Flow explanation

Per iteration: limit ($v_{gs}$ fetlim vs von, limvds, pnjlim on the
body diode); channel 3-region with subthreshold-smoothed overdrive and
quasi-sat drain degeneration; body diode incl. breakdown; caps
($C_{gs}$ const, $C_{gd}(v_{gd})$, diode depletion+diffusion); stamp
over 6–7 nodes (RD/RG/RS collapse when 0). Mode swap as MOS1. The
self-heating variant adds the thermal node exactly as b4soi.md §1.4
(RTH ladder junction→case→ambient).

## 3. Pseudo-code, CPU sequential

```
fn vdmos_eval(x, P):
    vgs = ty*(x.gp - x.sp); vds = ty*(x.dp - x.sp); vgd = vgs - vds
    m = sign1(vds)
    vgst  = (m>0 ? vgs : vgd) - P.vto_t
    vgste = P.ksub_t * ln(1 + exp((vgst - P.subshift)/P.ksub_t))   # smooth
    beta  = P.beta_t / (1 + P.theta*vgste)
    id    = mos1_3region(vgste, m*vds, beta, P.lambda, P.mtriode)
    id    = quasi_sat(id, vds, P.rq, P.vq)          # drain degeneration
    (ibd, gbd, qbd) = body_diode(ty*(x.sp - x.bp), P)   # + breakdown, TT
    i_rds = (x.dp - x.sp)/P.rds
    q_gd  = integrate Cgd(vgd) = cgdmin + 0.5*(cgdmax-cgdmin)*(1+tanh(P.a*vgd))
    q_gs  = P.cgs * vgs
    return stamps(RD/RG/RS series, channel, diode via b', rds shunt)
```

## 4. Pseudo-code, GPU parallel (batched SoA)

MOS1-shape kernel + diode-shape kernel fused per instance; everything
branchless except the diode breakdown select (same as diode.md §4).
`tanh` for $C_{gd}$ is one intrinsic. Self-heating variant batches
separately (extra unknown). Nothing else special — VDMOS is cheap.

## Noise model (in-device)

Contract: [noise-contract.md](noise-contract.md). ngspice VDMOS noise
(vdmosnoi.c, **not fetched** — mirror lacks the directory; table below
derived from the MOS1 template + model params, flagged):

| Generator | Branch | PSD |
|---|---|---|
| thermal RD/RG/RS | series branches | $4kT\,g$ each |
| channel thermal | d′–s′ | $4kT\cdot\frac{2}{3}|g_m|$ |
| flicker | d′–s′ | $K_F|I_D|^{A_F}/f$ (model kf/af present in vdmos.zig) |
| body-diode shot | s′–b′ | $2q|I_{bd}|$ — physically required for reverse conduction; **verify against vdmosnoi.c before claiming ngspice parity** |

`noisePsd`: channel + diode chains re-run at x; GPU straight-line.

## Sources

- `src/devices/models/vdmos.va` (in-tree port of ngspice vdmosload.c; topology/params verified against it above)
- ngspice vdmos directory: **not fetchable from the GitHub mirror used** (predates it) — fetch from git.code.sf.net/p/ngspice/ngspice when bit-exactness work starts.

## Verification status

- §1.1 topology + parameter set: **verified against our port** (which is the operative reference in this tree).
- §1.2–1.5 equation forms (subthreshold ln(1+e), quasi-sat form, tanh Cgd): **derived** — consistent with the port and the ngspice manual's VDMOS chapter as remembered; not source-verified against vdmosload.c in this pass.
- Noise: **derived** (see table note).

## Our implementation

- `src/devices/models/vdmos.va`.
- Bench fixtures: `devices/vdmos`, `vdmos_output`.
