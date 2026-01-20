# B4SOI 4.4 — body / floating-body, self-heating, and deltas from BSIMPD 2.0

Reference: ngspice `bsimsoi/b4soild.c`, `bsimsoi/b4soitemp.c` (B4SOI
v4.4). This is a **current want** (RESEARCH.md): our `devices/b4soi`
fixture FAILs because we map B4SOI cards onto the BSIMPD-2.x cognate
(`b3soipd.zig`, netlist.zig level-58 mapping).

## 1. Mathematical specification

### 1.1 Topology and operating modes

Terminals: D, G, S, E (substrate under the buried oxide, "back gate"),
optional external body contact P. Internal nodes (configuration
dependent): B (floating body), T (temperature, shMod=1), d′/s′ (rdsMod),
dB/sB (rbodyMod: separate body-side junction nodes), gate-resistance
nodes (rgateMod). Node presence is a collapse decision at setup.

**soiMod** selects the body treatment (the B4SOI-vs-BSIMPD structural
core):

- `soiMod = 0`: **BSIMPD** — pure partially-depleted; body potential
  $V_{bs}$ is a real unknown solved from the body KCL.
- `soiMod = 2`: **ideal FD** — fully depleted; body node eliminated;
  $V_{bs}$ replaced by an internally computed
  $V_{bs0,FD}(V_{gs},V_{es},V_{ds},T)$ from the front/back-gate coupling
  equations; no impact-ionization/diode body currents.
- `soiMod = 1`: **unified** — smooth interpolation: below a transition the
  device behaves PD (body solved), the FD module supplies the body bias
  through the interface potential $V_{bsitf}$ when the body floats high;
  b4soild.c blends via $V_{bs,mos} = f(V_{bs0,mos}, V_{bs0,FD}, V_{bsitf})$
  with offset constant `OFF_Vbsitf = 0.02`.

### 1.2 Floating-body KCL

For soiMod < 2 the body node carries its own equation:

$$\frac{dQ_{body}}{dt} + I_{bs} + I_{bd} + I_{bp} - I_{ii} - I_{GIDL} - I_{GISL} - I_{gb,tunnel} = 0$$

- $I_{bs}, I_{bd}$: body–source/drain junction diodes (recombination,
  diffusion, tunneling components, `ndiode`, `ntun`, temperature-mapped
  saturation currents). With rbodyMod the diodes hang off dB/sB through
  body resistances.
- $I_{bp}$: body-contact current through `rbody/rbsh` when bodyMod ≠ 0.
- $I_{ii}$: impact ionization (feeds the body — this is the floating-body
  effect engine; kink, history effect).
- GIDL/GISL and gate-to-body tunneling also charge the body.

**Impact ionization (iiiMod = 0)**, source-verified in both ngspice C
and Berkeley VA (identical equations):

$$I_{ii} = \alpha_0'\,e^{V_{diff}/T_B}\,\left(I_{ds} + f_{bjtii}\cdot\text{mode}\cdot I_c\right),\qquad
T_B = \beta_2 + \beta_1 V_{diff} + \beta_0 V_{diff}^2 \ (\ge 10^{-5})$$

$$V_{diff} = V_{ds} - V_{dsat,ii},\qquad
V_{dsat,ii} = \left[v_{dsatii0}\left(1 + t_{ii}\left(\tfrac{T}{T_{nom}}-1\right)\right) - \tfrac{l_{ii}}{L_{eff}}\right] + V_{gsStep}$$

$$V_{gsStep} = \left[\frac{s_{ii0}\,E_{satii}L_{eff}}{1 + E_{satii}L_{eff}}\right]
\left[V_{gst}\left(\frac{1}{1+s_{ii1}V_{gsteff}} + s_{ii2}\right)\right]\frac{1}{1 + s_{iid}V_{ds}}$$

with the exponential ratio clamped to ≤ 10 and $I_c$ the parasitic-BJT
collector current ($f_{bjtii}$ weighting). iiiMod = 1 adds a separate
BJT-driven term $I_{ii,bjt}$.

**Parasitic lateral BJT** (PD region): the source/body/drain form an NPN;
$I_c = I_{bjt}(V_{bs}, V_{bd})$ with `nbjt`, `lbjt0`, `vabjt`, `aely` —
transport current added to the drain KCL:
$I_D^{tot} = I_{ds} + I_c - I_{bd} + I_{ii} + I_{GIDL}$ (b4soild.c line
6063).

### 1.3 MOS core

The channel current core is BSIM4-class (v4.x sync): Vth with SOI-specific
back-gate coupling ($k_{1w1}, k_{1w2}, k_{b1}$ terms in the body-effect
via the buried-oxide capacitance ratio), DIBL, DITS, m*-style Vgsteff,
mobMod 0/1/2, rdsMod internal/external, Vdsat/Vdseff, VA chain — all as
in bsim4-core.md but with every temperature-dependent quantity carrying an
explicit $\partial/\partial T$ derivative (see §1.4). $V_{bseff}$ is built
from the *body* voltage (solved or FD-computed), and $V_{es}$ (back gate)
enters Vth and the depletion charge through the back-interface coupling.

### 1.4 Self-heating (shMod = 1)

Active when `shMod == 1 && rth0 != 0`. A thermal node $T$ (local
temperature rise $\delta T$) is added with the companion network:

$$C_{th}\frac{d(\delta T)}{dt} + \frac{\delta T}{R_{th}} = P_{diss},\qquad
R_{th} = \frac{r_{th0}}{N_F(W_{eff} + W_{th0})}\,N_{seg},\quad
C_{th} = c_{th0}\,\frac{N_F(W_{eff} + W_{th0})}{N_{seg}}$$

(rth/cth scaling verified in both the ngspice C and the Berkeley VA.)
Dissipated power: the Berkeley VA (v4.6.1) stamps exactly

$$\mathrm{Pwr}(t)\ {+}{=}\ -I_{ds}V_{ds} + \frac{d}{dt}(\delta T\,C_{th}) + \frac{\delta T}{R_{th}}$$

i.e. $P_{diss} = I_{ds}V_{ds}$ only; ngspice's b4soi 4.4 `cth`
(b4soild.c line 6251) additionally folds junction/BJT power terms —
a real generation difference in the electro-thermal loop, not just
bookkeeping. Jacobian: $G_{th} = 1/R_{th}$ and
$g_{cTt} = \alpha\,C_{th}$ on the (T,T) diagonal.

Electro-thermal coupling: every bias quantity with temperature dependence
($V_{th}, \mu_{eff}, v_{sat}, R_{ds}$, junction saturation currents,
$V_{dsat,ii}$, …) is evaluated at $T_{nom-shifted} + \delta T$ and its
derivative $\partial X/\partial T$ chained into
$G_{mT} = \partial I_{ds}/\partial T$, $G_{iiT}$, junction $G_{T}$s — these
stamp the coupling column (rows d/s/b × column T) and $P_{diss}$'s
derivatives stamp the T row against d/g/s/b columns. When selfheat is off
all $d\cdot/dT$ are zero and the node collapses.

### 1.5 Deltas B4SOI 4.4 vs BSIMPD 2.0

BSIMPD 2.0 ("Berkeley SOI, partially depleted", what `b3soipd.zig`
implements) is the ancestor; B4SOI adds, in rough impact order:

1. **soiMod unified/FD modules** (§1.1) — BSIMPD has no FD branch; the
   body is always a solved unknown. The FD module computes
   $V_{bs0}$ from front/back interface coupling with `vbsa, nofffd,
   vofffd, k1b, k2b, dk2b, dvbd0, dvbd1, moin` parameters.
2. **BSIM4-class core**: m* Vgsteff, mobMod renumbering + ud coulomb
   term, DITS (dvtp0/dvtp1), rdsMod=1 external resistors, improved
   Vdseff — BSIMPD 2.0 carries the BSIM3v3 core instead.
3. **Gate tunneling family** (igbMod/igcMod with Igb split acc/inv, Igcs/
   Igcd partition, Igs/Igd overlaps) — BSIMPD 2.0 has only a simple
   `igMod` gate current.
4. **rgateMod / rbodyMod networks** (dB/sB nodes, gate resistor modes) —
   absent in BSIMPD.
5. **Improved GIDL/GISL** with body-bias factor and `egidl` variants and
   the `iiiMod=1` alternative impact-ionization formulation.
6. **Back-gate parasitics**: `agbcp2` second poly-to-body contact cap,
   substrate-related caps (`csdmin`, `asd`) refined.
7. **Stress model** (SA/SB/SD LOD effects) and `w/l`-binned parameter
   set extensions; temperature model refinements (tempMod-like split of
   Vtm vs Vtm0, `tii`, `tvbci` etc.).
8. **v4.x numerics**: Wagner-fix derivative corrections (many
   `v4.2 bugfix` markers), DEXP-clamped exponentials, per-quantity
   $\partial/\partial T$ completeness for self-heating.

Generation skew note (benchmark/TRIAGE.md): our b3soipd rms ≈ 7.5e-3
against ngspice's BSIMPD-line and b4soi FAIL (3.2e-1) are consistent with
items 1–3 dominating: the FD/unified body computation and the BSIM4-class
Vgsteff/mobility shift the DC operating point, not just dynamics.

## 2. Flow explanation

Per iteration (b4soild.c order):

1. Read node voltages incl. body ($v_{bs}$ or dB/sB pair), back gate
   $v_{es}$, $\delta T$ (if selfheat). Bypass checks cover every extra
   unknown.
2. Limiting: fetlim/limvds/pnjlim as BSIM4; body voltage limited
   (`B4SOIDELT_Vbseff` guards); $\delta T$ step-limited.
3. If soiMod ≥ 1: compute FD body potential $V_{bs0}$ (+ derivatives
   incl. $\partial/\partial T$); blend to get the effective body bias;
   soiMod=2 skips all body-current physics.
4. MOS core chain (Vth → Vgsteff → mobility → Vdsat/Vdseff → Ids chain)
   with $d/dT$ carried alongside $d/dV_{g,d,b,e}$.
5. Body currents: junction diodes (dioMod variants, tunneling), parasitic
   BJT, $I_{ii}$ (§1.2), GIDL/GISL, gate–body tunneling. Sum into body
   KCL and drain/source KCL.
6. Self-heating: $P_{diss}$ and all $G_{\cdot T}$ couplings; thermal RC
   stamp.
7. Charges: front-gate CV (BSIM4-class), back-gate/BOX charge, body
   charge $Q_{body}$ (its dt term is the floating-body memory), junction
   depletion.
8. Stamp the full bordered system: usual MOS 4×4 block, body row/column,
   thermal row/column, network nodes.

State: all inter-node voltages + $\delta T$ + charge states; the body
voltage state is what carries the floating-body history effect across
timesteps.

## 3. Pseudo-code, CPU sequential

```
fn b4soi_eval(x, P) -> (I, Q, J, C):
    (vds,vgs,vbs,ves,dT) = frame(x)          # + vdbd/vsbs when rbodyMod
    selfheat = P.shmod==1 && P.rth0!=0

    # --- body bias resolution ---
    if P.soimod == 2:      vbs_mos = vbs0_fd(vgs, ves, vds, dT, P)   # no body eq
    elif P.soimod == 1:    vbs_mos = blend(vbs, vbs0_fd(...), vbsitf(...))
    else:                  vbs_mos = vbs                              # BSIMPD

    # --- BSIM4-class core with dT chain ---
    (vth, dvth_d{g,d,b,e,T})      = vth_soi(vbs_mos, ves, vds, dT, P)
    vgsteff = mstar_form(...); ueff = mobility(...); vdsat/vdseff = ...
    (ids, gm, gds, gmb, gme, gmT) = ids_chain(...)

    # --- body current sources ---
    (ibs, ibd, g...)   = body_junctions(vbs_jct, vbd_jct, dT, P)
    ic                 = parasitic_bjt(vbs, vbd, dT, P)
    vdsatii = (P.vdsatii0*(1 + P.tii*(T/Tnom-1)) - P.lii/P.leff) + vgs_step(...)
    tb      = max(P.beta2 + P.beta1*vdiff + P.beta0*vdiff^2, 1e-5)
    iii     = min(P.alpha0*exp(vdiff/tb), 10*P.alpha0) * (ids + P.fbjtii*ic)
    igidl, igisl, igb = leakage(...)

    # --- self-heating ---
    pdiss = ids*vds + bjt_junction_power(...)          # -> thermal row
    q_th  = P.cth * dT

    I[d]  = ids + ic - ibd + iii + igidl ...
    I[b]  = -(iii + igidl + igisl + igb) + ibs + ibd + ibp
    I[T]  = dT/P.rth - pdiss                            # + d(q_th)/dt
    Q[b]  = q_body(...); Q[T] = q_th; Q[g,d,s,e] = front/back CV
    J     = all cross-derivatives incl. G*T column and dPdiss row
```

## 4. Pseudo-code, GPU parallel (batched SoA)

```
kernel b4soi_batch(g, desc, blob, x, env):
    # batch key = (model, soiMod, shMod, bodyMod, rbodyMod, rgateMod):
    # fixes NU and eliminates all configuration divergence
    for i = g.tid; i < desc.count; i += g.stride:
        v  = gather(x, gath[i*NU..])       # incl. body + T rows when present
        b  = bins[inst_bin[i]]

        vbs_mos = soi_body_bias(v, b)      # warp-uniform soiMod branch
        core    = bsim4_class_chain(v, vbs_mos, v.dT, b)   # dT chained in regs
        bodyI   = junctions+bjt+iii+gidl(v, core, b)       # select()-guarded
        pdiss   = core.ids*v.vds + bodyI.power

        scatter_add(g.rhs, gath, kcl(core, bodyI, pdiss)
                                 + env.alpha*q(...) + hist)
        if WITH_DIAG:
            scatter_add(g.diag, gath, [gds.., g_body.., 1/b.rth + alpha*b.cth])
```

Self-heating on GPU costs one extra unknown per instance and a dense-ish
coupling row; the $\partial/\partial T$ chain doubles register pressure of
the core — worth keeping selfheat-off instances in separate batches
(different kernel instantiation) rather than predicating.

## Noise model (in-device)

Contract: [noise-contract.md](noise-contract.md). From bsimsoi.va
(v4.6.1) noise block (fetched, spot-verified at lines ~7743-7870,
8060-8080):

- Channel thermal (tnoiMod 0 path): $4kT\cdot NTNOI\cdot
  \mu_{eff}|Q_{inv}|/(L_{eff}^2 + \mu_{eff}|Q_{inv}|\ldots)$
  (`thermalNoiseContrib`, I(di,si) white_noise) -- with a
  $\tfrac{2}{3}(g_m+g_{ds}+g_{mb})$ variant for the alternative
  tnoiMod (line ~7861).
- rbodyMod network: white noise on b-db and b-sb ($4kT g_{rbdb}$,
  $4kT g_{rbsb}$).
- Flicker: unified BSIM4-style; shot on gate tunneling and body
  currents (VA `white_noise(2q...)` contributions).
- ngspice b4soinoi.c (4.4) mirrors the VA minus v4.6 additions -- not
  fetched this pass (mirror gap), **derived** at that level.

`noisePsd`: body/thermal-node coupling makes B4SOI the model where
orbit-sampled noise (noise-contract.md SS2b) matters most -- floating
body modulates every PSD through $V_{bs}(t)$.

## Sources

- https://raw.githubusercontent.com/ngspice/ngspice/master/src/spicelib/devices/bsimsoi/b4soild.c (fetched, 11283 lines — landmark sections read: mode/bias init, Iii block ~5644–5770, self-heating stamps ~6251/9594/10349/10674)
- https://raw.githubusercontent.com/ngspice/ngspice/master/src/spicelib/devices/bsimsoi/b4soitemp.c (fetched)
- https://raw.githubusercontent.com/pascalkuthe/OpenVAF/master/integration_tests/BSIMSOI/bsimsoi.va (fetched — **Berkeley BSIM-SOI v4.6.1** Verilog-A; Iii block ~6690–6735, rth/cth scaling ~3082, thermal stamp ~8073–8085)
- Berkeley BSIM-SOI page (https://bsim.berkeley.edu/models/bsimsoi/) — manual tarball not fetched.

**Version note**: the free VA is v4.6.1, ngspice implements v4.4. Where
cross-checked they agree (Iii iiiMod=0, rth/cth scaling, soiMod/shMod
semantics) *except* the self-heating power: v4.6 VA dissipates
$I_{ds}V_{ds}$ only, ngspice 4.4 adds junction/BJT power terms (§1.4).
For a bit-exact ngspice match use the C; for CMC-current behavior use
the VA.

## Verification status

- §1.1 soiMod semantics, §1.2 $I_{ii}$ (iiiMod=0) incl. $V_{dsat,ii}$/VgsStep/$T_B$ and the mode factor, §1.4 rth/cth scaling, thermal stamp and $P_{diss}$, drain KCL composition: **source-verified** against both b4soild.c and bsimsoi.va (cross-checked; one Pdiss delta, noted above).
- §1.3 core details, FD-module ($V_{bs0}$) equations, BJT equations, §1.5 delta list items 5–8: **derived / structurally verified only** (symbols located in both sources; full expressions not audited). The v4.6.1 VA is now the recommended audit target — single file, no SPICE plumbing.
- b4soitemp.c: fetched, not audited in detail.

## Our implementation

- Cognate today: `src/devices/models/bsimsoi_va.va` (BSIM-SOI 100.1.1). The
  hand-written `b3soipd.zig`/`b3soifd.zig`/`b3soidd.zig` (BSIMPD 2.x, floating
  body + self-heating + body contact) went with the move to build-time
  Verilog-A and have no `.va` replacement, so the level-58 card mapping in
  `src/frontend/parser.zig` is the thing to check first.
- Bench fixtures: `benchmark/fixtures/devices/b4soi`, `b4soi_output` (FAIL, 3.2e-1 — the reason this doc exists), `b3soipd`, `b3soipd_output` (7.5e-3 generation skew).
