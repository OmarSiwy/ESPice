# HSPICE W and S elements

In the HSPICE dialect a `W` card is a coupled lossy transmission line and an
`S` card is an N-port described by Touchstone data. Both run as Verilog-A
devices (`models/wline_1..4.va`, `models/sparam_1..4.va`). The frontend fits
a rational model to the line or the data at build time
(`src/frontend/wfit.zig`, `src/frontend/sparam.zig`), and the device reads
the fitted coefficients from parameter arrays. Every fitted transfer is a
direct term plus second-order sections

    d + Σ_k (b1 s + b0) / (a2 s² + a1 s + a0)

and each section is its own `laplace_nd`. A complex pole pair, or two real
poles, makes one section. The poles are never multiplied into one
polynomial, because a high-degree `laplace_nd` is ill-conditioned. VerA's
`laplace_nd` applies the exact H(jω) of the coefficients in AC, so the AC
error is the fit error. In a transient, VerA (since 6355aaf1) runs each
section as a state-space realization whose steady state is exactly H(0).

## W element

```
W1 i1 .. iN iR o1 .. oN oR N=n L=length RLGCMODEL=m [FGD=f] [INCLUDERSIMAG=YES|NO]
.model m W MODELTYPE=RLGC N=n Lo=... Co=... [Ro=...] [Go=...] [Rs=...] [Gd=...]
W1 ... RLGCFILE=file.rlgc
```

The matrices are lower triangles, row by row (`L11 L21 L22` for N=2). An
RLGC file holds N and then the triangles of L, C, R, G, Rs and Gd in that
order, as plain numbers; `*` starts a comment. N is 1 to 4. The reference
nodes iR and oR may be any nodes: each end's port voltages and currents are
taken against its own reference.

Per unit length:

    Z(f) = R0 + Rs·√f·(1 + j) + j2πf·L0      (no j·Rs·√f with INCLUDERSIMAG=NO)
    Y(f) = G0 + Gd·f / √(1 + (f/fgd)²) + j2πf·C0      (Gd·f when FGD is 0 or absent)

The Gd roll-off is our reading of the manual's equation for FGD. Its
typesetting is garbled, and the formula has not been checked against
HSPICE.

### Method

One constant real transform splits the line into modes. With C0 = FᵀF
(Cholesky) and F·L0·Fᵀ = QΛQᵀ, the transforms are Tv = F⁻¹Q and Ti = FᵀQ,
with columns scaled to unit maximum, so that both L0 and C0 become diagonal.
Each mode then has its own scalar z(s) and y(s), the diagonals of Tv⁻¹·Z·Ti
and Ti⁻¹·Y·Tv. Per mode the frontend fits:

- the characteristic admittance Yc = √(y/z), scaled by the lossless Z0 to
  O(1). Passivity (Re Yc ≥ 0) is enforced;
- the propagation P = e^(−γ·l + s·τ), γ = √(zy), with the lossless delay
  τ = l·√(L·C) taken out. The fit is of 1 − P with relative weighting, so
  the small low-frequency loss keeps its precision.

The device runs the method of characteristics on the modal waves:

    w1 = P · delay_τ(2·yc·vm2 − w2),   w2 = P · delay_τ(2·yc·vm1 − w1)
    im1 = (yc·vm1 − w1) / Z0,          im2 = (yc·vm2 − w2) / Z0

w1 and w2 are internal nodes, in volts. The delay is `absdelay`, which AC
also reads exactly as e^(−jωτ).

The fit grid is log spaced at 30 points per decade, plus DC. It runs from
1/100 of the lowest to 100 times the highest of each mode's corners: 1/τ,
R0/(2πL), G0/(2πC), the skin corner (Rs/(2πL))², and FGD (or 1/τ) when
Gd ≠ 0. Each function gets at most 12 sections (`W_K`).

DC (`analysis("static")`) does not go through the fit. It uses the exact
resistive line: series R0·l from each near-end conductor to its far end,
mutual terms included, and G0·l/2 shunts at each end. With G0 = 0 that is
exact. With G0 ≠ 0 it is a π section, not the exact cosh/sinh solution; we
have no deck that needs better. The static point also sets the waves to the
values the first transient step expects, so a transient starts at rest.

A lossy mode with R0 = 0 or G0 = 0 has Yc ~ √s (or 1/√s) toward DC, and no
rational function follows that. The fit therefore gives that mode the R0 or
G0 that puts its corner at the bottom of the grid. Yc and 1 − P then level
off to finite DC values whose ratio is still the line's series resistance.
The price is about 1e-5 of extra loss in band (G·Z0·l/2), but more at
DC, where the floor's shunt is the only conductance: 1.4e-3 of the level
in `hspice/w_settle`.

### Exactness and accuracy

- A lossless line fits exactly: Yc = 1/Z0 and P = 1, with no sections. The
  W card is then an ideal delay line (`hspice/w_lossless_delay`: 5e-15).
- For N = 1, and for coupled lines whose R, G, Rs and Gd are diagonal in
  the same modes as L0·C0 (a symmetric pair, for example), the modal split
  is exact. Otherwise the off-diagonal modal loss terms are dropped.
- `hspice/w_element` checks .ac against the exact ABCD chain from 1 MHz to
  10 GHz. With R0 and Rs the worst error is 1.5e-5 relative (tolerance
  5e-5). With Gd added it is 2.7e-2 (tolerance 5e-2). Gd·f with a constant
  C0 is a frequency-independent loss tangent. That is not causal: the
  propagation's magnitude e^(−a|ω|) has no causal phase partner, so no
  rational model reaches it. The builder warns when a mode's fit error
  passes 1e-2.
- Transient against ngspice-44.2: `hspice/w_txl` (one RLC line against TXL)
  is within 6.6 mV on a 1 V edge, and `hspice/w_coupled_cpl` (the
  `tran/device_coupled_tlines` pair against CPL) is within 10.5 mV. Both
  ngspice engines are approximations of the same line. Our own time-step
  error on the CPL deck is about 7 mV: a ten times smaller step moves the
  result by that much.
- `hspice/w_settle` holds a resistive line (R0 = 50 Ω/m, G0 = 0) under a
  step for 2 µs. The transient settles to the fitted model's DC limit
  within 1.0e-7 and stays there. That limit is 0.62410 V, not the
  resistive divider's 0.625 V, because of the G floor described above:
  the floor's shunt 2π·lo·C0 costs 1.4e-3 of the DC level here. The DC
  operating point uses the exact resistive line, so a transient that
  starts from it moves by that much once the waves arrive.

### Divergence from HSPICE

HSPICE's S element defaults to IFFT convolution of the data and offers
rational fitting as `RATIONAL_FUNC=1`. Here both elements always run a
rational fit. The constant modal transform, the fit band and the π-section
DC model for G0 ≠ 0 are our choices. None of this has been compared
against HSPICE.

### Known limits

- The propagation fit is not constrained to |P| ≤ 1; out of band a fit
  could exceed it slightly. Yc is made passive, P is not checked.
- `absdelay` takes a constant maxdelay of 1 s (`W_TDMAX`), so no modal
  delay is ever clamped. VerA sizes each site's history ring from it, up
  to its 16384-sample cap. That is 256 KB per site and two sites per mode,
  so 512 KB per mode and 2 MB for an N = 4 line, per instance. A line
  whose delay spans more than 16384 accepted time steps still stops the
  run (E1012).

### Retired: state-space sections on internal nodes

Before VerA 6355aaf1, `laplace_nd` ran each section in direct form on
the bilinear-mapped coefficients. A section whose pole is slow next to the
step (ω·dt ≪ 1e-3) lost its DC gain to roundoff, because Σ a_z ~
(ω·dt)², and `hspice/w_settle` drifted to 0.6217 V by 2 µs. The
workaround we tried ran the slowest W_S sections of each fitted function
as scaled state space with `ddt()` on two internal nodes each, and left
the rest on `laplace_nd`.

A host device has at most 64 unknowns (the u64 row masks and the 64-lane
`Dual` in `device/eval.zig`). wline_N has 7N + 3 unknowns before any
state: 2N + 2 ports, 2N wave nodes, and 3N branch flows. Each
state-space section adds 2 per fitted function, 4 functions per mode, so
8·N·W_S. That caps W_S at 6, 2, 1 and 1 for N = 1 to 4 (58, 49, 48 and
63 unknowns), with one spare node besides. Running every section
(W_K = 12) as state space would need 106 unknowns at N = 1. A
coefficient written outside `ddt()` (c·ddt(V)) costs VerA an operator
unknown per site, and wline_1 reached 82 that way.

Measured on VerA 6355aaf1 with the same fit (1 ps to 2 µs, 20.8k
points):

| realization | w_settle error | w_settle run | w_txl | w_coupled_cpl |
|---|---|---|---|---|
| all `laplace_nd` (W_S = 0) | 1.01e-7 | 0.18 s | 6.6 mV | 10.5 mV |
| hybrid, W_S = 6 | 1.01e-7 | 0.23 s | 6.6 mV | 10.5 mV |

VerA's section kernel now holds H(0) exactly, so the hybrid bought
nothing and cost more run time on w_settle (0.23 s against 0.18 s, one
run each). It was dropped. A
device that mixed `laplace_nd` with `ddt()` also hit a VerA codegen bug
(a local `q` shadowing the device's `q`), fixed in VerA d9d8bf58.

## S element

```
S1 n1 .. nN [nRef] MNAME=m
.model m S TSTONEFILE=file.sNp [N=n]
```

The data file is Touchstone 1.0. The option line is `# <unit> <S|Y|Z>
<MA|DB|RI> R <z0>`, with defaults `GHz S MA R 50`. Any real reference
impedance works. A two-port lists N11 N21 N12 N22, and the noise block after
a two-port's data is skipped. The path is relative to the deck's directory.
N is 1 to 4, taken from `N=` or the `.sNp` extension. Every port is taken
against nRef, or against ground when there is none.

### Method

At each data point Y = Z0⁻¹·(I − S)(I + S)⁻¹, or the given Y or Z. Then
the frontend runs vector fitting (Gustavsen and Semlyen, 1999) with poles
common to every entry and the fast column-wise pole identification of
Deschrijver et al. (2008), at orders 4, 8, … up to 32 (16 sections,
`SP_K`), until the RMS error is under 1e-6 of max |Y|. Passivity
(λ_min(Re Y(jω)) ≥ 0 on a dense grid, and a positive semidefinite symmetric
direct term) is enforced by the minimum-norm change of the residues and
direct terms over the data points. The device sums each entry's sections:
I_i = Σ_j (d_ij + Σ_k section_ijk(s))·V_j.

DC is the fit's H(0). When the data has no point at f = 0, H(0) is an
extrapolation, which is exact when the network is rational and the fit
recovers it.

### Accuracy

- `hspice/s_element`: a rational two-port written to Touchstone. The node
  voltages match the analytic network to 4e-15 at all 41 data points, and
  the DC point to 1e-15.
- `hspice/s_element_tran`: the same file in a transient, against ngspice
  running the lumped network. The difference is 1.1e-7 V on a 0.46 V
  pulse at a 1 ps step. It was 4.6 mV before VerA's state-space
  `laplace_nd` sections (6355aaf1).

## Not supported

Refused with a diagnostic:

- W: TABLEMODEL, UMODEL, FSMODEL and SMODEL, and N > 4;
- S: FQMODEL, CITIFILE, RFMFILE, MIXEDMODE, more than 4 ports, and the
  2N-node (pairwise reference) form;
- Touchstone 2.0 (keyword lines such as `[Version]`).

Also missing:

- noise: both devices are noiseless, although a lossy line or a lossy
  N-port has thermal noise;
- DELAYHANDLE and the other S options; the S element always fits;
- a data file named from inside an `.include` resolves against the top
  deck's directory, not the include's.
