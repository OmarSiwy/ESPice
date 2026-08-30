# BSIM4 core + deltas from BSIM3v3

Reference: ngspice `bsim4/b4ld.c`, `bsim4/b4temp.c` (BSIM4 v4.8). This doc
presents the core DC chain **as deltas from bsim3v3-core.md** — everything
not mentioned carries over structurally from BSIM3 (Vbseff smoothing,
Xdep, characteristic lengths, Abulk skeleton, Vdseff smoothing, VA
combination, guard/continuation pattern).

## 1. Mathematical specification

### 1.1 Vbseff — extra forward-bias correction

After the BSIM3-style lower smoothing at `vbsc`, BSIM4 adds an upper
smoothing so $V_{bseff}$ can never reach $\phi_s$:

$$V_{bseff} \leftarrow 0.95\phi_s - \tfrac{1}{2}\left[T_0 + \sqrt{T_0^2 + 0.004\cdot 0.95\phi_s}\right],\quad T_0 = 0.95\phi_s - V_{bseff} - 0.001$$

### 1.2 Vth — deltas

$$
\begin{aligned}
V_{th} = {}& V_{th0} + \underbrace{(k_{1,ox}\sqrt{\Phi_s} - k_1\sqrt{\phi_s})\,\sqrt{1 + \tfrac{L_{PEB}}{L_{eff}}}}_{\text{lateral non-uniform doping, body-bias part}}
- k_{2,ox}V_{bseff} - \Delta V_{th,SCE} - \Delta V_{th,W} \\
&+ (k_3 + k_{3b}V_{bseff})\frac{T_{OXE}\,\phi_s}{W_{eff}+w_0}
+ \underbrace{k_{1,ox}\left(\sqrt{1+\tfrac{L_{PE0}}{L_{eff}}}-1\right)\sqrt{\phi_s}}_{L_{PE0} \text{ replaces } N_{LX}}
+ k_t\text{-terms} - \Delta V_{th,DIBL} \\
&- \underbrace{n\,V_{tm}\ln\!\frac{L_{eff}}{L_{eff} + d_{vtp0}\left(1 + e^{-d_{vtp1}V_{ds}}\right)}}_{\text{DITS (pocket implant), if } d_{vtp0}>0}
- \underbrace{d_{vtp2}\tanh(d_{vtp4}V_{ds})}_{\text{DITS\_Sft2, v4.7}}
\end{aligned}
$$

Short-channel $\Theta_0$ uses the exact hyperbolic form instead of the
two-exponential approximation:

$$\Theta_0 = \frac{e^{d_{vt1}L_{eff}/l_t}}{\left(e^{d_{vt1}L_{eff}/l_t}-1\right)^2 + 2\,e^{d_{vt1}L_{eff}/l_t}\,\varepsilon_{min}} \;\approx\; \frac{1}{2\left[\cosh\!\left(\frac{d_{vt1}L_{eff}}{l_t}\right)-1\right]}$$

(same form for the narrow-width term with $d_{vt1w}W_{eff}L_{eff}/l_{tw}$).

### 1.3 Vgsteff — m* formulation

BSIM3's single unified expression is replaced by the $m^*$ ratio,
$m^* = 0.5 + \frac{\arctan(m_{inv})}{\pi}$ (MINV parameter),
$V_{offcbn} = V_{off} + V_{offl}/L_{eff}$:

$$
\boxed{V_{gsteff} = \frac{n V_{tm}\ln\!\left(1 + e^{\,m^* V_{gst}/(nV_{tm})}\right)}
{m^* + n\,\dfrac{C_{oxe}}{C_{dep0}}\,\exp\!\left(\dfrac{V_{offcbn} - (1-m^*)V_{gst}}{nV_{tm}}\right)}}
$$

($m^* = 0.5$ default reduces close to BSIM3's behavior with symmetric
sub/above-threshold blending; asymptote clamps at EXP_THRESHOLD identical
in structure).

### 1.4 Rds — rdsMod

- **rdsMod = 0** (internal, default): no d′/s′ nodes for the bias-dependent part;

$$R_{ds} = R_{dswmin} + \frac{r_{ds0}}{2}\left[\frac{1}{1+p_{rwg}V_{gsteff}} + p_{rwb}(\sqrt{\Phi_s}-\sqrt{\phi_s}) + \sqrt{(\cdot)^2 + 0.01}\right]$$

  (the sqrt-smoothing keeps the bracket positive), folded into the Ids
  denominator exactly as BSIM3.
- **rdsMod = 1** (external): $R_{ds} = 0$ inside the core; instead
  bias-dependent conductances $g_{s}(V_{ges},V_{sbs})$, $g_d$ stamp on real
  d–d′ / s–s′ branches, each
  $\frac{1}{R_{s/d}}$ with
  $R = \frac{R_{dwmin} + r_{dw}\left[\frac{1}{1+p_{rwg}v_{g\cdot}}+ p_{rwb}\,\theta(v_{b\cdot})\right]}{(10^6 W_{effCJ})^{w_r}\,N_F}$-type expressions and their own convergence checks.

### 1.5 Abulk delta

$T_1$ gains the k2ox/k3b coupling:
$T_1 = \frac{k_{1,ox}L_{peVb}}{2\sqrt{\Phi_s}} + k_{2,ox} - k_{3b}\frac{T_{OXE}\phi_s}{W_{eff}+w_0}$ — otherwise identical skeleton (a0/ags/b0/b1/keta, 0.1 floor).

### 1.6 Mobility — mobMod 0/1/2 (renumbered!)

BSIM4 adds the coulomb-scattering term $u_d$ and (mobMod 2) the
$E_{eff}^{EU}$ power law:

$$
D = \begin{cases}
\dfrac{V_{gsteff}+2V_{th}}{T_{OXE}}\left(u_a + u_c V_{bseff} + u_b\dfrac{V_{gsteff}+2V_{th}}{T_{OXE}}\right) + u_d\left(\dfrac{V_{th}\,T_{OXE}}{V_{gsteff} + 2\sqrt{V_{th}^2+10^{-4}}}\right)^2 & \text{mobMod}=0\\[10pt]
\left[\dfrac{V_{gsteff}+2V_{th}}{T_{OXE}}\left(u_a + u_b\dfrac{V_{gsteff}+2V_{th}}{T_{OXE}}\right)\right](1 + u_c V_{bseff}) + u_d(\cdot)^2 & \text{mobMod}=1\\[10pt]
(u_a + u_c V_{bseff})\left(\dfrac{V_{gsteff} + v_{tfbphi1}}{T_{OXE}}\right)^{EU} + u_d(\cdot)^2 & \text{mobMod}=2
\end{cases}
$$

$\mu_{eff} = U_0(T)/(1+D)$ with the same $-0.8$ rational guard.
Temperature: $u_a,u_b,u_c,u_d$ each have their own T-coefficients; with
tempMod ≥ 1 the T-mapping of Vth/mobility separates `vtm` vs `vtm0` usage
(kt-terms use `TRatio − 1` with `vtm0`-based ni).

### 1.7 Vdsat / Vdseff / Ids deltas

Same Vdsat quadratic and Vdseff smoothing as BSIM3 (`delta`). The Ids
chain gains one more Early-voltage-like factor for DITS:

$$I_{ds} = \frac{I_{ds0}\,N_F}{1 + \frac{R_{ds}I_{ds0}}{V_{dseff}}}
\left(1 + \frac{V_{ds}-V_{dseff}}{C_{clm}\,V_A}\right)^{\!\ast}
\left(1 + \frac{V_{ds}-V_{dseff}}{V_{ADIBL}}\right)
\left(1 + \frac{V_{ds}-V_{dseff}}{V_{ADITS}}\right)
\left(1 + \frac{V_{ds}-V_{dseff}}{V_{ASCBE}}\right)$$

structurally (ngspice folds CLM logarithmically:
$M_{clm} = 1 + \frac{1}{C_{clm}}\ln\frac{V_A + V_{ACLM}\cdot C_{clm}}{V_A}$ form via `Cclm`), with

$$V_{ADITS} = \frac{1 + (1 + p_{ditsl}L_{eff})e^{p_{ditsd}V_{ds}}}{p_{dits}}\cdot F_P,\qquad
F_P = \frac{1}{1 + f_{prout}\sqrt{L_{eff}}/V_{gsteff}\cdot\ldots}$$

($F_P$ = pocket-implant DIBL degradation factor, `fprout`). $V_{ADIBL}$
same as BSIM3 (pdiblc1/2, pdiblcb).

### 1.8 New current paths absent in BSIM3

Source-verified against the BSIM4 v4.8 Verilog-A (OpenVAF
integration_tests). Oxide voltages first ($\delta_3 = 10^{-3}$ smoothing):

$$V_{fbeff} = V_{fbzb} - \tfrac{1}{2}\left(V_3 + \sqrt{V_3^2 \pm 4\delta_3 V_{fbzb}}\right),\quad V_3 = V_{fbzb} - V_{gs,eff} + V_{bseff} - \delta_3$$
$$V_{oxacc} = \max(V_{fbzb} - V_{fbeff},\ 0),\qquad
V_{oxdepinv} = k_{1,ox}\left(\sqrt{\tfrac{k_{1,ox}^2}{4} + V_{gs,eff} - V_{fbeff} - V_{bseff} - V_{gsteff}} - \tfrac{k_{1,ox}}{2}\right) + V_{gsteff}$$

All tunneling exponents share one template:
$X(a,b,c,V_{ox}) \equiv a + (ac - b)V_{ox} - bc\,V_{ox}^2$
(= expanding $(a - bV_{ox})(1 + cV_{ox})$).

**Gate–channel tunneling** (igcMod 1/2):

$$V_{aux} = n_{igc}V_{tm}\ln\!\left(1 + e^{(V_{gs,eff}-V_x)/(n_{igc}V_{tm})}\right),\quad
V_x = \begin{cases}\text{type}\cdot v_{th0} & \text{igcMod}=1\\ V_{th} & \text{igcMod}=2\end{cases}$$

$$I_{gc} = A\,W_{eff}L_{eff}\,T_{oxRatio}\;V_{gs,eff}\,V_{aux}\;
e^{-B\,T_{OXE}\,X(a_{igc},\,b_{igc},\,c_{igc},\,V_{oxdepinv})}$$

$A = 4.97232\times10^{-7}$ A/V² (NMOS) / $3.42537\times10^{-7}$ (PMOS),
$B = 7.45669\times10^{11}$ (N) / $1.16645\times10^{12}$ (P) — the VA folds
`Aechvb = A·Weff·Leff·ToxRatio`, `Bechvb = −B·toxe`. Partition with
$\tau = -P_{igcd}V_{dseff}$, default
$P_{igcd} = \frac{B\,T_{OXE}}{V_{gsteff}^2}\left(1 - \frac{V_{dseff}}{2V_{gsteff}}\right)$:

$$I_{gcs} = I_{gc}\,\frac{e^{\tau} - 1 - \tau + 10^{-4}}{\tau^2 + 2\times10^{-4}},\qquad
I_{gcd} = I_{gc}\,\frac{(\tau - 1)e^{\tau} + 1 + 10^{-4}}{\tau^2 + 2\times10^{-4}}$$

Gate–S/D overlap tunneling, $v' = \sqrt{(v_{gs} - v_{fbsd} - v_{fbsdoff})^2 + 10^{-4}}$:

$$I_{gs} = A_{edgeS}\;v_{gs}\,v'\;e^{-B_{edge}T_{OXE}\,P_{OXEDGE}\,X(a_{igs},\,b_{igs},\,c_{igs},\,v')}$$

($A_{edgeS}$ carries the DLCIG overlap length and edge ToxRatio; $I_{gd}$
mirrored with aigd/bigd/cigd, DLCIGD).

**Gate–substrate tunneling** (igbMod), $I_{gb} = I_{gb,acc} + I_{gb,inv}$:

$$I_{gb,acc} = A\,W_{eff}L_{eff}T_{oxRatio}\,(V_{gs,eff} - V_{bseff})\,V_{aux}\;
e^{-B\,T_{OXE}\,X(a_{igbacc},\,b_{igbacc},\,c_{igbacc},\,V_{oxacc})}$$

with $V_{aux} = n_{igbacc}V_{tm}\ln\!\left(1 + e^{(V_{bseff} + V_{fbzb} - V_{gs,eff})/(n_{igbacc}V_{tm})}\right)$,
$A = 4.97232\times10^{-7}$, $B = 7.45669\times10^{11}$ (both channel
types); $I_{gb,inv}$ identical on $V_{oxdepinv}$ with $V_{aux}$ argument
$(V_{oxdepinv} - e_{igbinv})/(n_{igbinv}V_{tm})$ and prefactors
$A\times0.75610$, $B\times1.31724$.

**GIDL/GISL** — gidlMod 0 (classic), $T_0 = 3T_{OXE}$ (mtrlMod 0),
$T_1 = (V_{ds} - v_{gs,eff} - e_{gidl})/T_0$:

$$I_{GIDL} = a_{gidl}\,W_{effCJ}\;T_1\;e^{-b_{gidl}/T_1}\;\frac{(-v_{bd})^3}{c_{gidl} + (-v_{bd})^3},
\qquad 0 \text{ if } T_1 \le 0 \text{ or } v_{bd} > 0$$

(GISL mirrored on $-V_{ds}, v_{gd,eff}, v_{bs}$). gidlMod 1 (v4.7)
replaces the cubic body factor with an exponential and adds RGIDL
gate coupling:

$$I_{GIDL} = a_{gidl}W_{effCJ}\,T_1\,e^{-b_{gidl}/T_1}\,e^{\,k_{gidl}/(v_{bd} - f_{gidl})},\qquad
T_1 = \frac{V_{ds} - r_{gidl}\,v_{gs,eff} - e_{gidl}}{T_0}$$

Substrate current $I_{sub}$ (impact ionization, alpha0/alpha1/beta0)
unchanged from BSIM3.

### 1.9 Parasitic networks (structural deltas)

- **rgateMod 0–3**: 0 = none; 1 = constant $R_{geltd}$; 2 = $R_{geltd}$ + bias-dependent intrinsic gate resistance $\frac{1}{X_{RCRG1}\left(\frac{I_{ds}}{V_{dseff}} + X_{RCRG2}\frac{W_{eff}\mu_{eff}C_{oxe}V_{tm}}{L_{eff}}\right)}$; 3 = two-node split (gNodeExt, gNodeMid).
- **rbodyMod**: 5-resistor substrate network (dbNode, bNodePrime, sbNode; RBPB/RBPD/RBPS/RBDB/RBSB), with node collapse when resistances hit limits.
- **trnqsMod/acnqsMod**: Elmore-resistance charge-deficit NQS with an extra q-node.
- Junction diodes: dioMod 0/1/2 (resistance-free/ideal/exponential-with-breakdown), tunneling components (JTSS/JTSD…) in the source/drain junctions.

### 1.10 Derived defaults (b4temp.c) — deltas from BSIM3

Same k1/k2/gamma/vbx/phi machinery. Additions: TOXP/TOXE/DTOX split
(electrical vs physical oxide, `toxRatio` powers in tunneling
pre-factors); `vtfbphi1/vtfbphi2` for mobMod 2 and CV; `vfbsdoff`,
`k1ox = k1` (no TOXM scaling of k1 in v4.7+ — k1ox/k2ox are
`k1·toxe/toxm` only when TOXM given), `njts` junction tunneling temp
mapping, `eu` defaults (1.67 NMOS / 1.0 PMOS), `ud` temp power `ucs`.
Where BSIM3 printed warnings for k1/k2-vs-gamma conflicts, BSIM4 keeps
the same precedence.

## 2. Flow explanation

Identical spine to BSIM3 (see bsim3v3-core.md §2) with these insertions:

1. After junction diodes and before Vth: **rdsMod=1** source/drain
   resistor voltages ($v_{ses}, v_{ded}$) get their own bypass/limit/
   convergence treatment.
2. Vth chain adds DITS terms; Vgsteff via $m^*$; mobility per mobMod.
3. After Ids: **gate-current block** (Igc partition, Igs/Igd, Igb) — each
   with its own $\partial/\partial V_{g,d,b}$ chain, stamped between g and
   d′/s′/b rows.
4. **GIDL/GISL** stamped d→b and s→b.
5. Charge model (capMod 0–2, plus overlap/fringe with bias-dependent
   Vgs_eff overlap) — BSIM4 always computes both S/D-referenced charge
   partitions (XPART).
6. rgate/rbody nodes stamped; NQS q-node if enabled.

Mode handling, limiting (fetlim on vgs, limvds, pnjlim on vbs/vbd — plus
pnjlim-like limiting of $v_{ges}/v_{ged}$ when rgateMod > 0 and of
rdsMod=1 resistor voltages), bypass, and convergence checks all follow
the BSIM3 pattern with the extra current components added to the
predicted-current tests (`Igstot/Igdtot/...` in b4ld.c).

## 3. Pseudo-code, CPU sequential

Delta view — reuse `bsim3_eval` skeleton:

```
fn bsim4_eval(x, P):
    frame, junctions as bsim3 (+ dioMod variants, + rdsMod=1 branch resistors)

    vbseff = bsim3_vbseff(...);  vbseff = fwd_correction_095phi(vbseff)
    vth    = bsim3_vth(...)
             .with(LpeVb_factor, Lpe0_instead_of_nlx)
             .minus(n*Vtm*log(Leff/(Leff + dvtp0*(1+exp(-dvtp1*vds)))))   # DITS
             .minus(dvtp2*tanh(dvtp4*vds))                                # v4.7
    vgsteff = mstar_form(vgst, n, P)              # §1.3
    rds     = P.rdsmod==0 ? rdswmin + smooth_bracket(...)*rds0/2 : 0
    abulk   = bsim3_abulk(..., T1 += k2ox - k3b*Vth_NarrowW)
    ueff    = u0t / (1 + mob_denom_mobmod012(...) )   # + ud coulomb term
    vdsat, vdseff = bsim3 forms
    ids     = idl * Mclm(...) * (1+dvds/VADIBL) * (1+dvds/VADITS) * (1+dvds/VASCBE)
    isub    = bsim3_isub(...)

    igidl, igisl = gidl(vds, vgse, vdb), gisl(-vds, vgde, vsb)
    igc -> (igcs, igcd) via pigcd partition;  igs, igd overlap tunneling
    igb  = igbacc + igbinv

    q... = capmod_charges(...)   # + overlap w/ vgs_eff, fringe

    return stamps over {d,g,s,b,d',s'} ∪ rgate/rbody/q nodes as configured
```

## 4. Pseudo-code, GPU parallel (batched SoA)

Same batching pattern as BSIM3 (see bsim3v3-core.md §4). BSIM4-specific
notes:

```
kernel bsim4_batch(g, desc, blob, x, env):
    for i = g.tid; i < desc.count; i += g.stride:
        v = gather(x, gath[i*NU..])       # NU fixed per batch: node-config
                                          # (rgateMod/rbodyMod/trnqs) must be
                                          # part of the batch key so all
                                          # instances share one unknown layout
        b = bins[inst_bin[i]]

        core chain (§1) — all guards as select(); mobMod/rdsMod/igcMod are
        model-level -> warp-uniform branches, keep them as real branches
        (skips whole blocks: gate tunneling is ~30% of flops when enabled)

        ids/gm/gds/gmb, isub, igidl/gisl, igc/igs/igd/igb, junctions, q

        scatter_add rhs/diag over up to ~8 rows; collapsed nodes share
        gather indices so the same code covers every rdsMod/rgateMod
        configuration without special cases
```

The only per-lane data divergence risk is the DEXP/EXP_THRESHOLD clamps —
value-dependent but register-only. Batches should be keyed on
(model, node-configuration) so `mobMod/rdsMod/rgateMod/rbodyMod/igcMod`
never diverge within a warp.

## Noise model (in-device)

Contract: [noise-contract.md](noise-contract.md). From b4noi.c
(fetched; structure verified, tnoiMod1/2 coefficient chains not fully
transcribed):

- RD/RS (rdsMod=1 branches), rgate, rbody resistors: thermal $4kT g$ each.
- Channel, `tnoiMod 0`: charge-based BSIM3 noiMod-2 form
  $4kT\,\mu_{eff}|Q_{inv}|/(L_{eff}^2 + \mu_{eff}|Q_{inv}|R_{ds})$.
- `tnoiMod 1` (holistic): single Vds-referred source with partition
  factors $\beta_{npart} = RNOIB(1 + TNOIB\cdot L\ldots)$,
  $\theta_{npart} = RNOIA(\ldots)$; gspr/gdpr amplified by
  $(1 + \theta^2 g V_{dseff}/I_{ds})$ and a correlated component
  `igsquare` subtracted -- drain and induced-gate noise with implied
  correlation.
- `tnoiMod 2` (v4.7): explicit correlated + uncorrelated channel
  sources (CORL entry) -- maps directly onto the PsdTerm corr_with
  pair in the target contract.
- Flicker `fnoiMod 0`: SPICE2; `fnoiMod 1`: unified (BSIM3-style
  NOIA/NOIB/NOIC with EM/LINTNOI).
- Gate-current shot: $2q\,I$ for each tunneling component
  (Igs, Igd, Igcs, Igcd, Igb) -- b4noi.c sources ".igs"/".igd"/".igb".

ngspice computes all of the above; tnoiMod>=1 is precisely the
correlation case the current `noise_gens` cannot express
(noise-contract.md SS2c). `noisePsd`: SS1-SS8 chain already computes
every input; tnoiMod is warp-uniform.

## Sources

- https://raw.githubusercontent.com/ngspice/ngspice/master/src/spicelib/devices/bsim4/b4ld.c (fetched)
- https://raw.githubusercontent.com/ngspice/ngspice/master/src/spicelib/devices/bsim4/b4temp.c (fetched)
- https://raw.githubusercontent.com/pascalkuthe/OpenVAF/master/integration_tests/BSIM4/bsim4.va (fetched — official Berkeley BSIM4 v4.8 Verilog-A; §1.8 verified against lines ~10930–11360, 7405–7415)

## Verification status

- §1.1–1.7 (Vbseff correction, Vth incl. DITS, m* Vgsteff, rdsMod split, Abulk delta, mobMod 0/1/2, Ids factor chain): **source-verified** against fetched b4ld.c (lines ~1050–1500, 1870–2010).
- §1.8 gate tunneling / GIDL / GISL incl. prefactor constants, partition functions, gidlMod 0/1: **source-verified** against the fetched bsim4.va.
- §1.9 network resistor expressions: structural (presence and stamps confirmed; rgate/rbody expressions not transcribed line-by-line).
- §1.10: partially verified (b4temp.c fetched; only the delta items spot-checked).

## Our implementation

- `src/devices/models/bsim4va.va`.
- Bench fixtures: `benchmark/fixtures/devices/bsim4`, `bsim4_transfer`, `bsim4_output`, `bsim4_pmos`.
