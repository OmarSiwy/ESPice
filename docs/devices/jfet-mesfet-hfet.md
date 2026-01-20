# FET family — JFET (Sydney), JFET2 (Parker–Skellern), MESFET (Statz), MESA, HFET1/2

Reference: ngspice `jfet/jfetload.c` + `jfetnoi.c`, `jfet2/jfet2load.c`
+ `psmodel.c` + `jfet2noi.c`, `mes/mesload.c` + `mesnoise.c`,
`mesa/mesaload.c`, `hfet1/hfetload.c`, `hfet2/hfet2load.c`.
Priority devices: `hfet_inverter` (FAIL 1.28e0), `mesa_inverter`
(1.00e0), `mesa_oscillator` (5.66e-1) fixtures.

Common topology for all: D–RD–d′, S–RS–s′ (G–RG–g′ for MESA), two gate
junction diodes g(′)–d′ and g(′)–s′, channel current d′–s′,
normal/inverse mode swap on sign($v_{ds}$), pnjlim on $v_{gs}/v_{gd}$ +
fetlim, junction depletion caps with the FC quadratic extension.

## 1. Mathematical specification

### 1.1 JFET (SPICE1 quadratic + Sydney "B-factor" doping tail)

Gate diodes: $I = I_S(T)(e^{v/NV_t}-1) + g_{min}v$ each side. Channel,
normal mode, $v_{gst} = v_{gs} - V_{TO}(T)$, $\beta_p = \beta(1+\lambda v_{ds})$,
$B$ = doping-profile parameter, $B_{fac} = (1-B)/(P_B - V_{TO})$:

- cutoff $v_{gst} \le 0$: $I_D = 0$.
- linear ($v_{gst} > v_{ds}$):

$$I_D = \beta_p\,v_{ds}\left[v_{ds}\left(B_{fac}v_{ds} + B\right)\cdot(-1)\cdot(-1) + v_{gst}\,a\right],\quad a = 2B + 3B_{fac}(v_{gst} - v_{ds})$$

  (source form: `cpart = vds*(vds*(Bfac*vds - b) + vgst*apart)` with
  $a_{part} = 2B + 3B_{fac}(v_{gst}-v_{ds})$)
- saturation ($v_{gst} \le v_{ds}$): with $B' = v_{gst}B_{fac}$,

$$I_D = \beta_p\,v_{gst}^2\,(B + B'),\qquad
g_m = \beta_p v_{gst}(2B + 3B'),\qquad g_{ds} = \lambda\beta v_{gst}^2(B+B')$$

$B = 1$, $B_{fac} = 0$ recovers the classic SPICE1 quadratic
($I_D = \beta_p v_{gst}^2$). The Sydney mod (Macquarie/Sydney
University) grades the square law toward cubic to model the real doping
tail. Inverse mode: same with $v_{gdt}$, sign-flipped.

### 1.2 JFET2 — Parker–Skellern (psmodel.c, source-verified)

Full macro-empirical model, evaluated in `PSids`:

1. **Gate junctions**: forward exponential with linearization above
   $\arg = 40$ ($I \to I_{40}(arg-39)$, keeps NR finite), plus reverse
   "breakdown" exponential $I_{BD}e^{-v/V_{BD}}$ — both sides.
2. **Rate-dependent threshold (trapping/self-heating memory)**: in
   transient, filtered voltages
   $v_{trap} = h\,v_{trap}^{prev} + (1-h)v$, $h = (\tau_G/(\tau_G + \Delta t/4))^4$;
   the effective overdrive mixes static and filtered biases via
   LFGAM/LFG1/LFG2 (low-freq feedback $\gamma$) and HFGAM/HFETA/…
   (high-freq):

$$v_{gst} = v_{gs} - V_{TO} - (\Gamma_{LF})v_{gd,trap} + \eta_{HF}(v_{gs,trap}-v_{gs}) + \gamma_{HF}(v_{gd,trap}-v_{gd})$$

3. **Subthreshold**: $v_{gt} = v_{st}\ln(1 + e^{v_{gst}/v_{st}})$,
   $v_{st} = V_{SUB}(1 + m_{vst}v_{ds})$ (exponentially-limited, exact
   large-arg continuation).
4. **Dual power law + early saturation**:
   $v_{dp} = v_{ds}\cdot D_3 v_{gt}^{P-Q}$; smooth saturation voltage
   from $v_{sat} = v_{gt}/(1 + v_{gt}/(m_{xi}v_{gt} + \xi_{woo}))$ and
   the two-sqrt construction
   $v_{dt} = \sqrt{a^2 + z} - \sqrt{(a - v_{sat})^2 + z}$
   ($a = z_a v_{dp} + v_{sat}/2$, $z = v_{sat}^2 Z/4$); intrinsic
   Q-law:

$$I_D = v_{dt}(v_{gt}-v_{dt})^{Q-1} + v_{gt}\left(v_{gt}^{Q-1} - (v_{gt}-v_{dt})^{Q-1}\right)$$

5. **CLM + β**: $\times\,\beta A(1+\lambda v_{ds})$.
6. **Thermal self-consistency**: power-filtered
   $\bar P = h_d \bar P^{prev} + (1-h_d)v_{ds}I_D$
   ($h_d$ from $\tau_D$), then $I_D \mathrel{/}= (1 + \bar P\,\delta/A)$
   — with the exact Gm/Gds corrections of the filter.

All continuations are exact-derivative (the model was designed for NR
friendliness); state: two trapped voltages + filtered power.

### 1.3 MESFET — Statz et al. (mesload.c, source-verified)

$v_{gst} = v_{gs} - V_{TO}$, $\text{denom} = 1 + b\,v_{gst}$,
$\beta_p = \beta(1+\lambda v_{ds})$:

$$
I_D = \begin{cases}
0 & v_{gst}\le 0\\[2pt]
\beta_p\dfrac{v_{gst}^2}{1+b\,v_{gst}}\left[1 - \left(1-\dfrac{\alpha v_{ds}}{3}\right)^3\right] & 0 < v_{ds} < \dfrac{3}{\alpha}\ \text{(linear)}\\[8pt]
\beta_p\dfrac{v_{gst}^2}{1+b\,v_{gst}} & v_{ds} \ge \dfrac{3}{\alpha}\ \text{(saturation)}
\end{cases}
$$

The cubic $(1-\alpha v_{ds}/3)^3$ knee replaces tanh (cheap, $C^2$ at
the join). Gate caps: Statz charge model `qgg` (IEEE T-ED Feb 87) with
smooth partition between $C_{gs}/C_{gd}$ above/below threshold and
$v_{max}$ clamping — charge-based, unlike Meyer.

### 1.4 MESA (levels 2/3/4) and HFET1/2 — structural

MESA (`mesaload.c`, 990 lines): HEMT-class MESFET with charge-control
channel: sheet density $n_s(v_{gt})$ from a unified
2DEG charge-control expression (level 2 single-layer, 3 delta-doped, 4
carrier-concentration-dependent mobility), velocity saturation, and
temperature-dependent threshold; two Schottky diodes with thermionic
+ GGR (gate leakage) terms; Ward–Dutton partitioned gate charge.
HFET1 (`hfetload.c`): analytic HEMT with DIBL
($V_{T,eff} = V_{TO} - \sigma v_{ds}$), exponential subthreshold with
unified $n_s$, knee shaping, dual-exponential gate leakage + GGR;
HFET2: simplified variant (fewer fitting params, same skeleton).
Exact equation transcription deferred — the loads are fetched; do the
line-audit when attacking the `mesa_*`/`hfet_*` FAILs (the fixture
errors are O(1), i.e. wrong operating region, not fine accuracy — first
suspect: subthreshold/knee smoothing constants and the GGR leakage
terms in our ports).

### 1.5 Temperature and limiting (family-common)

$V_{TO}(T)$, $\beta(T)$, junction $I_S(T)$/potentials per SPICE maps;
$V_{crit}$ per gate junction. Limiting order (jfetload/mesload):
fetlim($v_{gs}$), fetlim($v_{gd}$), limvds, then pnjlim on both gate
junctions; MODEINITJCT seeds $v_{gs} = -1$ or 0 per off flag.

## 2. Flow explanation

Identical spine across the family: bias → bypass → limit → gate diodes
→ mode select (sign $v_{ds}$; swap $v_{gs} \leftrightarrow v_{gd}$) →
channel current 3-region (or PS smooth chain) → gate charges → stamp
(gdpr/gspr series, ggs/ggd junctions, gm/gds channel with xnrm/xrev
swap — the MOS1 pattern minus the bulk). JFET2 additionally advances
its two trap filters and the power filter once per timestep (state
committed on accept — the same accepted-state discipline as our switch).

## 3. Pseudo-code, CPU sequential

```
fn fet_eval(x, P) -> (I, Q, J, C):          # one body, model-kind dispatch
    vgs, vgd = frame(x); vds = vgs - vgd
    (igs,ggs) = gate_junction(vgs, P)        # + PS breakdown term for jfet2
    (igd,ggd) = gate_junction(vgd, P)
    m = sign1(vds); vx = m>0 ? vgs : vgd
    id, gm, gds = switch P.kind:
        .jfet:   sydney_bfac(vx - P.vto_t, m*vds, P.b, P.bfac, P.beta_t, P.lambda)
        .jfet2:  ps_ids(vgs, vgd, state, dt, P)        # §1.2 chain
        .mes:    statz(vx - P.vto, m*vds, P.b, P.alpha, P.beta, P.lambda)
        .mesa/.hfet: charge_control_ns -> vsat -> id   # §1.4
    q_gs, q_gd = gate_charge(P.kind, ...)    # depletion / Statz qgg / W-D
    return stamps(m, id, igs, igd, gm, gds, ggs, ggd, series RD/RS)
```

## 4. Pseudo-code, GPU parallel (batched SoA)

```
kernel fet_batch(g, desc, blob, x, env):
    for i = g.tid; i < desc.count; i += g.stride:
        v = gather(x, gath[i*NU..])          # NU: 5 (jfet) / 6 (mes/mesa)
        m  = sign1(vds(v))                   # swap-as-sign-frame, as MOS1
        # 3-region channels: cutoff mask + linear/sat select() — same
        # branchless clamp trick as MOS1 works for JFET (vde=clamp) and
        # Statz (knee select at 3/alpha); PS chain is fully smooth already
        id, gm, gds = channel(v, models[i])
        # jfet2 trap/power filters are per-instance state -> CPU batch today
        # (has_state); static (AC/DC) evaluation has h=0 and runs anywhere
        scatter_add(g.rhs, gath, kcl(m, id, igs, igd) + env.alpha*q + hist)
        if WITH_DIAG: scatter_add(g.diag, ...)
```

## Noise model (in-device)

Contract: [noise-contract.md](noise-contract.md).

| Device | Generator | Branch | PSD | Status |
|---|---|---|---|---|
| JFET | thermal RD / RS | d′–d, s′–s | $4kT\,g_{d/s,pr}\,A\,m$ | jfetnoi.c verified |
| JFET | channel thermal (NLEV<3) | d′–s′ | $4kT\cdot\tfrac{2}{3}|g_m|\,m$ | verified |
| JFET | channel thermal (NLEV=3) | d′–s′ | $4kT\cdot\tfrac{2}{3}\beta v_{gst}\dfrac{1+\alpha+\alpha^2}{1+\alpha}\,g_{dsnoi}$, $\alpha = \max(0, 1 - v_{ds}/v_{gst})$ | verified |
| JFET | flicker | d′–s′ | $m\,K_F|I_D|^{A_F}/f$ | verified |
| JFET2 | same four; channel is $4kT\cdot\tfrac{2}{3}|g_m|m$ | | | jfet2noi.c verified |
| MESFET | same four (2/3·gm form) | | | mesnoise.c verified |
| MESA / HFET1/2 | **none in ngspice** (no noise routine) | — | modern add: channel thermal $\tfrac{2}{3}g_m$ + gate shot $2q|I_G|$ — derived, no reference | — |

`noisePsd`: recompute $g_m$ (and $v_{gst}, \alpha$ for NLEV=3), $I_D$,
$I_G$ from the gathered x — the §3 chain up to conductances — and emit
the table rows. GPU: straight-line per lane; NLEV is model-uniform.
Our `jfet.zig:120` declares rd/rs thermal + channel *flicker* but no
channel-thermal gen — add when the hook lands.

## Sources

- https://raw.githubusercontent.com/ngspice/ngspice/master/src/spicelib/devices/jfet/jfetload.c, jfetnoi.c (fetched)
- https://raw.githubusercontent.com/ngspice/ngspice/master/src/spicelib/devices/jfet2/jfet2load.c, psmodel.c, jfet2noi.c (fetched)
- https://raw.githubusercontent.com/ngspice/ngspice/master/src/spicelib/devices/mes/mesload.c, mesnoise.c (fetched)
- https://raw.githubusercontent.com/ngspice/ngspice/master/src/spicelib/devices/mesa/mesaload.c, hfet1/hfetload.c, hfet2/hfet2load.c (fetched, skimmed — §1.4 not transcribed)

## Verification status

- §1.1 (Sydney B-fac incl. exact `apart/cpart` forms), §1.2 (full PS chain), §1.3 (Statz), §1.5 order, noise table: **source-verified**.
- §1.4 MESA/HFET equations: **structural only** — fetched but not transcribed; line-audit is the named next step for the failing fixtures.
- Statz `qgg` charge internals: present in fetch, not transcribed (derived at section level).

## Our implementation

- `src/devices/{jfet,jfet2,mesfet,mesa,hfet1,hfet2}.zig`.
- Bench fixtures: `devices/jfet*`, `jfet2`, `mesfet*`, `mesa*` (mesa_inverter/oscillator FAIL), `hfet1*`, `hfet2*`, `hfet_id_vgs`, `hfet_inverter` (FAIL).
