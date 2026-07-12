# VBIC 1.2 (Vertical Bipolar Inter-Company model)

Reference: official Verilog-A definition, designers-guide.org release 1.2
(fetched). VBIC is the public-domain SGP replacement: separate Early-effect
via depletion charges, quasi-saturation (Kull collector), parasitic PNP,
avalanche, self-heating, excess phase.

## 1. Mathematical specification

### 1.1 Topology

External: C, B, E, (S), (dt thermal), local ground for xf1/xf2 (excess
phase). Internal: bi/ei/ci (intrinsic), bx (extrinsic base), cx, bp
(parasitic base), si. Resistive branches: RCX (c–cx), RCI (cx–ci,
modulated), RBX (b–bx), RBI (bx–bi, qb-modulated), RE (e–ei), RS (s–si),
RBP (bx–bp). Zero-valued resistances collapse their nodes.

### 1.2 Temperature mapping (all "atT" quantities)

$T_{dev} = T + \Delta T_{inst} + V(rth)$ (electro-thermal), $r_T = T_{dev}/T_{nom}$, $V_{tv} = kT_{dev}/q$:

$$I_S(T) = I_S\left[r_T^{X_{IS}}\,e^{-E_A(1-r_T)/V_{tv}}\right]^{1/N_F}$$

(same template for ISRR/ISP/IBEI/IBEN/IBCI/IBCN/... each with its own
activation energy $E_{A\cdot}$ and exponent $X_{I\cdot}$ and emission
coefficient). Resistances: $R(T) = R\,r_T^{X_R}$. $N_F(T) = N_F(1 + \Delta T\,T_{NF})$,
$AVC2(T) = AVC2(1+\Delta T\,T_{AVC})$. Built-in potentials use the
`psibi` mapping (smooth, avoids the SGP kink):

$$\psi_{bi}(P, E_a, T): \quad
\psi_{io} = 2\frac{V_{tv}}{r_T}\ln\!\left(e^{0.5 P r_T/V_{tv}} - e^{-0.5 P r_T / V_{tv}}\right),\;
\psi_{in} = \psi_{io}r_T - 3V_{tv}\ln r_T - E_a(r_T - 1),$$
$$P(T) = \psi_{in} + 2V_{tv}\ln\!\left[\tfrac{1}{2}\left(1 + \sqrt{1 + 4e^{-\psi_{in}/V_{tv}}}\right)\right]$$

$C_J(T) = C_J\left(P/P(T)\right)^{M}$.

### 1.3 Depletion charge normal form (`qj`)

Single-piece smooth depletion charge with forward linearization at
$F_C$ and optional smoothing parameter $A_J$:

- $A_J \le 0$ (SPICE-classic): power law below $F_C P$, quadratic
  extension above (same F1/F2/F3 algebra as the diode).
- $A_J > 0$ (VBIC-smooth, default path): a $\sqrt{\cdot}$-smoothed
  effective junction voltage, with $dv_0 = -PF_C$:

$$v_{l0} = -\tfrac{1}{2}\left(dv_0 + \sqrt{dv_0^2 + 4A_J^2}\right),\quad
v_l = \tfrac{1}{2}\left(V + dv_0 - \sqrt{(V+dv_0)^2 + 4A_J^2}\right) - dv_0$$
$$q_j = \frac{-P(1 - v_l/P)^{1-M}}{1-M} + (1-F_C)^{-M}(V - v_l + v_{l0}) - \frac{-P(1 - v_{l0}/P)^{1-M}}{1-M}$$

i.e. exact power-law charge up to a smooth clamp at $F_C P$, linear
$(1-F_C)^{-M}$ capacitance beyond. `qjrt` adds punch-through (VRT, ART)
for the BC junction: below $-V_{RT}$ the capacitance flattens (charge
goes linear) via a second smooth selector.

Normalized charges: $q_{dbe} = q_j(V_{bei}; P_E, M_E)$,
$q_{dbc} = q_{jrt}(V_{bci})$, plus bex/bep/bcp variants.

### 1.4 Transport current

$$I_{fi} = I_S(T)\left(e^{V_{bei}/(N_F(T)V_{tv})} - 1\right),\qquad
I_{ri} = I_S(T)\,I_{SRR}(T)\left(e^{V_{bci}/(N_R(T)V_{tv})} - 1\right)$$

Normalized base charge — Early effect from *depletion charges*, not a
linear VA fit:

$$q_{1z} = 1 + \frac{q_{dbe}}{V_{ER}} + \frac{q_{dbc}}{V_{EF}},\qquad
q_1 = \tfrac{1}{2}\left(\sqrt{(q_{1z}-10^{-4})^2 + 10^{-8}} + q_{1z} - 10^{-4}\right) + 10^{-4}$$

(positivity smoothing), high-injection knee:

$$q_2 = \frac{I_{fi}}{I_{KF}(T)} + \frac{I_{ri}}{I_{KR}},\qquad
q_b = \begin{cases}\tfrac{1}{2}\left(q_1 + \left(q_1^{1/N_{KF}} + 4q_2\right)^{N_{KF}}\right) & QBM < 0.5 \text{ (default)}\\[4pt]
\tfrac{1}{2}\,q_1\left(1 + \left(1 + 4q_2\right)^{N_{KF}}\right) & QBM \ge 0.5\end{cases}$$

with $N_{KF}$ the high-injection rolloff exponent (default 0.5, giving
the familiar $\tfrac{1}{2}(q_1 + \sqrt{q_1^2 + 4q_2})$ special case).

$$\boxed{I_{tzf} = \frac{I_{fi}}{q_b},\qquad I_{tzr} = \frac{I_{ri}}{q_b},\qquad I_{cc} = I_{tzf} - I_{tzr}}$$

Excess phase (TD > 0): second-order network on internal nodes xf1/xf2
($L_{EP} = T_D/3$, $C_{EP} = T_D$; branch equations
$I_{tzf} - V_{xf2} - j\omega C\,V_{xf1} = 0$,
$j\omega L\,V_{xf2} + V_{xf2} - V_{xf1} = 0$); the delayed
$I_{txf} = V(x_{f2})$ replaces $I_{tzf}$ in the collector KCL
(and in the avalanche term).

### 1.5 Base currents

Ideal + non-ideal pairs, split between intrinsic (WBE) and extrinsic
(1−WBE) BE junctions:

$$I_{be} = W_{BE}\left[I_{BEI}(T)\left(e^{V_{bei}/(N_{EI}V_{tv})}-1\right) + I_{BEN}(T)\left(e^{V_{bei}/(N_{EN}V_{tv})}-1\right) - I_{BBE}\right]$$

$I_{bex}$ analogous at $V_{bex}$ with weight $1-W_{BE}$. BE breakdown
term (VBBE > 0): $I_{BBE} = I_{BBE}\left(e^{-(V_{BBE}(T)+V_{bei})/(N_{BBE}(T)V_{tv})} - E_{BBE}(T)\right)$.
BC: $I_{bcj} = I_{BCI}(T)(e^{V_{bci}/(N_{CI}V_{tv})}-1) + I_{BCN}(T)(e^{V_{bci}/(N_{CN}V_{tv})}-1)$.

### 1.6 Avalanche (weak breakdown)

$$v_l = \tfrac{1}{2}\left[\sqrt{(P_C(T)-V_{bci})^2 + 0.01} + (P_C(T)-V_{bci})\right]$$
$$I_{gc} = (I_{tzf} - I_{tzr} - I_{bcj})\;AVC1\;v_l\,e^{-AVC2(T)\,v_l^{\,M_C-1}},\qquad I_{bc} = I_{bcj} - I_{gc}$$

### 1.7 Quasi-saturation collector (Kull model + velocity saturation)

$$K_{bci} = \sqrt{1 + \Gamma(T)e^{V_{bci}/V_{tv}}},\qquad K_{bcx} = \sqrt{1 + \Gamma(T)e^{V_{bcx}/V_{tv}}}$$
$$I_{ohm} = \frac{V_{rci} + V_{tv}\left(K_{bci} - K_{bcx} - \ln\frac{K_{bci}+1}{K_{bcx}+1}\right)}{R_{CI}(T)}$$
$$I_{rci} = \frac{I_{ohm}}{\sqrt{1 + d_{erf}^2}},\qquad
d_{erf} = \frac{R_{CI}(T)\,I_{ohm}/V_O(T)}{1 + \dfrac{0.5}{V_O(T)\,H_{RCF}}\sqrt{V_{rci}^2 + 0.01}}$$

(the $d_{erf}$ factor is velocity-saturation smoothing). Modulated base
resistance: $I_{rbi} = V_{rbi}\,q_b / R_{BI}(T)$.

### 1.8 Parasitic (substrate) transistor

$$I_{fp} = I_{SP}(T)\left(W_{SP}e^{V_{bep}/(N_{FP}V_{tv})} + (1-W_{SP})e^{V_{bci}/(N_{FP}V_{tv})} - 1\right)$$
$$q_{bp} = \tfrac{1}{2}\left(1+\sqrt{1+4 I_{fp}/I_{KP}}\right),\qquad
I_{rp} = I_{SP}(T)\left(e^{V_{bcp}/(N_{FP}V_{tv})}-1\right),\qquad I_{ccp} = \frac{I_{fp} - I_{rp}}{q_{bp}}$$

plus $I_{bep}, I_{bcp}$ ideal/non-ideal pairs.

### 1.9 Charges

$$t_{ff} = T_F\left(1 + Q_{TF}q_1\right)\left(1 + X_{TF}\,e^{V_{bci}/(1.44 V_{TF})}\left(s_{lTF} + m_{If}^2\right)\sigma(I_{fi})\right),\quad m_{If} = \frac{I_{fi}/I_{TF}}{I_{fi}/I_{TF}+1}$$

$$Q_{be} = C_{JE}(T)\,q_{dbe}W_{BE} + t_{ff}\frac{I_{fi}}{q_b},\qquad
Q_{bex} = C_{JE}(T)\,q_{dbex}(1-W_{BE})$$
$$Q_{bc} = C_{JC}(T)\,q_{dbc} + T_R I_{ri} + Q_{CO}K_{bci},\qquad
Q_{bcx} = Q_{CO}K_{bcx},\qquad Q_{bep} = C_{JEP}(T)q_{dbep} + T_R I_{fp}$$

plus $Q_{bcp}$, fixed overlaps $Q_{beo} = C_{BEO}V_{be}$,
$Q_{bco} = C_{BCO}V_{bc}$.

### 1.10 Self-heating

$$I_{th} = -\Big(I_{be}V_{bei} + I_{bc}V_{bci} + (I_{tzf}-I_{tzr})V_{cei} + I_{bex}V_{bex} + I_{bep}V_{bep} + \sum_R I_R V_R + \ldots\Big)$$

into the dt node with $R_{TH} \| C_{TH}$.

## 2. Flow explanation

Pure branch-oriented formulation (this is why the VA definition *is* the
spec): every current/charge above is a branch constituent relation; MNA
stamps follow mechanically from branch topology.

1. Temperature block (§1.2) — depends on V(rth), so with self-heating it
   re-evaluates every iteration and contributes $\partial/\partial T$
   terms to the Jacobian through the dt column.
2. Depletion normalized charges $q_{dbe}, q_{dbc}, \ldots$ (§1.3) — these
   feed *both* the charge model and the Early-effect $q_1$.
3. Transport: $I_{fi}, I_{ri} \to q_1, q_2 \to q_b \to I_{tzf}, I_{tzr}$;
   parasitic transistor currents; base currents; avalanche $I_{gc}$
   (needs $I_{tzf/r}$, hence ordered after).
4. Resistive branches: constant (RCX/RBX/RE/RS/RBP), modulated
   ($I_{rci}$ Kull, $I_{rbi}\propto q_b$).
5. Charges (§1.9), thermal power (§1.10), excess-phase network.
6. Junction limiting: SPICE ports (ngspice vbicload.c) apply pnjlim to
   $V_{bei}, V_{bci}, V_{bex}, V_{bep}, V_{bcp}$; the VA source relies on
   `$limexp` (log-linearized exponential above a threshold) instead —
   both bound the same exponentials.

State: junction voltages + charges; no region switching anywhere — VBIC
is single-expression throughout (all bias regions live inside smooth
functions), which is its main numerical advantage over SGP.

## 3. Pseudo-code, CPU sequential

```
fn vbic_eval(x, P) -> (I, Q, J, C):
    v = branch_voltages(x)         # bei, bci, bex, bep, bcp, rcx, rci, rbx,
                                   # rbi, re, rs, rbp, cei, rth, xf1, xf2
    T  = P.temp + v.rth;  A = atT(P, T)          # §1.2, cheap closed forms

    qdbe  = qj(v.bei, A.pe, P.me, P.fc, P.aje)
    qdbc  = qjrt(v.bci, A.pc, P.mc, P.fc, P.ajc, P.vrt, P.art)
    ...

    ifi = A.is*(limexp(v.bei/(A.nf*Vtv)) - 1)
    iri = A.is*A.isrr*(limexp(v.bci/(A.nr*Vtv)) - 1)
    q1  = smooth_pos(1 + qdbe/P.ver + qdbc/P.vef)
    q2  = ifi/A.ikf + iri/P.ikr
    qb  = 0.5*(q1 + sqrt(q1*q1 + 4*q2))          # QBM=0
    itzf = ifi/qb;  itzr = iri/qb

    ibe/ibex/ibcj = ideal+nonideal pairs (§1.5)
    igc  = (itzf - itzr - ibcj)*avalm(v.bci, A.pc, P.mc, P.avc1, A.avc2)
    irci = kull(v.rci, v.bci, v.bcx, A)          # §1.7
    irbi = v.rbi*qb/A.rbi
    ifp/irp/iccp/qbp = parasitic(...)            # §1.8

    tff  = tf_expr(q1, ifi, v.bci)
    Qbe  = A.cje*qdbe*P.wbe + tff*ifi/qb;  Qbc = A.cjc*qdbc + P.tr*iri + P.qco*kbci
    ...
    ith  = -(sum of I*V products)                # §1.10

    return assemble_branches(...)  # each branch stamps (row+, row-, dI/dV cols)
```

Our `vbic.zig` evaluates this chain in the AD scalar type; `$limexp` maps
to the clamped-exp helper; node collapse for zero resistances mirrors the
VA conditionals.

## 4. Pseudo-code, GPU parallel (batched SoA)

VBIC is the friendliest BJT for SIMT: no region branches at all — every
lane executes the identical expression tree.

```
kernel vbic_batch(g, desc, blob, x, env):
    # batch key: (model, selfheat?, excess_phase?, 3/4/5-terminal) fixes NU
    for i = g.tid; i < desc.count; i += g.stride:
        v = gather(x, gath[i*NU..])
        A = atT(models[i], v.rth)      # recomputed per lane; ~30 pow/exp —
                                       # hoist to prep when selfheat is off
        chain of §1.4–§1.10, straight-line code, limexp = min-clamped exp
        scatter_add(g.rhs, gath, branch_kcl(...) + env.alpha*Q + hist)
        if WITH_DIAG: scatter_add(g.diag, ...)   # per-branch g on both rows

    # limiting kernel: pnjlim on bei/bci/bex/bep/bcp gathered pairs
```

When self-heating is disabled the temperature block is x-independent:
precompute `atT` host-side into prep (as our PrepCache pattern) and the
device kernel is pure polynomial/exp arithmetic.

## Noise model (in-device)

Contract: [noise-contract.md](noise-contract.md). Source-verified
against ngspice vbicnoise.c (matches the VA's noise semantics):

| Generator | Branch | PSD |
|---|---|---|
| thermal RCX / RCI / RBX / RBI / RE / RBP / RS | each resistive branch | $4kT\,g_{branch}$ -- RCI/RBI use the **stored modulated** conductances (Kull, $q_b$) |
| shot forward transport | ci-ei | $2q\,|I_{tzf}|$ |
| shot base | bi-ei | $2q\,|I_{be}|$ |
| shot parasitic BE | bx-bp | $2q\,|I_{bep}|$ |
| shot parasitic transport | bx-si | $2q\,|I_{ccp}|$ |
| flicker | bi-ei | $m\,K_F\,|I_{be}|^{A_F}/f$ |

(The VA additionally scales flicker by 1/BFN exponent variants in 1.3;
1.2 is as tabled.) `noisePsd`: every input is produced by the SS3
chain (Itzf, Ibe, Ibep, Iccp, Kull/qb conductances); 12 PsdTerms,
straight-line on GPU. ngspice vs modern: no B-C correlation in VBIC
(that is HICUM's addition).

## Sources

- https://designers-guide.org/vbic/release1.2/vbic1.2.tar.gz (fetched — `vbic.vcs`, the unmangled official VBIC 1.2 Verilog-A; also carries reference C code + test vectors under `vbic_code/` and `test/ReferenceResults/`)
- https://designers-guide.org/vbic/release1.2/vbic1.2.va.html (fetched — HTML rendering, superseded by the tarball)
- https://designers-guide.org/vbic/ , /downloads.html (fetched — index)

## Verification status

- §1.2–1.10: **source-verified** against `vbic.vcs` from the release
  tarball — including the exact $q_b$/QBM/NKF expressions, the `qj`
  $A_J \le 0$ / $A_J > 0$ branches, and the excess-phase network. The
  earlier HTML-mangling caveat is cleared.
- ngspice `vbic/vbicload.c` limiting specifics: not fetched; stated from SPICE convention.
- Bonus for bit-exact work: the tarball's `test/ReferenceResults/*.reference` are official verification vectors (FG/FO/RG/RO/AC/TEMP/XF sweeps).

## Our implementation

- `modules/devices/src/vbic.zig`.
- Bench fixtures: `benchmark/fixtures/devices/vbic`, `vbic_gummel`, `vbic_forward_gummel`, `vbic_output`, `vbic_forced_output`, `vbic_ce_amp`, `vbic_diffamp`, `vbic_temp`, `vbic_noise_scale`.
