# CPL coupled transmission lines — modal decomposition (P element)

Reference: ngspice `cpl/cplload.c`, `cpl/cplsetup.c` (Charles Hough,
1992). **Status: closed** — `src/devices/coupled_ltra.zig` is a faithful
port of the full pipeline below (P cards with N in `supported_n` route
there; `tline/cpl3_4_line` matches ngspice to 4e-10, `devices/
coupled_tlines` to 6e-12). The 2-conductor even/odd `coupled_tlines.va`
cognate remains only as the fallback for unsupported N. Two retired
experiments, both measurably wrong against the goldens because the
reference's own approximation IS the spec: per-mode exact LTRA/Bessel
convolution (1.5e-2 rms on cpl3_4) and per-mode analytic TXL Padé over a
joint eigenbasis (2.5e-2) — the golden's per-entry constants come from
polynomial interpolation THROUGH the eight 1/s samples, which neither
analytic shortcut reproduces. This doc specifies the general N-line
method ngspice actually runs.

## 1. Mathematical specification

### 1.1 System

$N$ coupled lines over a common return, per-unit-length matrices
$\mathbf{R}, \mathbf{L}, \mathbf{G}, \mathbf{C}$ (symmetric; card gives
the upper triangle), length $\ell$. Telegrapher system:

$$-\frac{\partial \mathbf{v}}{\partial z} = (\mathbf{R} + s\mathbf{L})\,\mathbf{i},\qquad
-\frac{\partial \mathbf{i}}{\partial z} = (\mathbf{G} + s\mathbf{C})\,\mathbf{v}$$

Unknowns per instance: $N$ port voltages each end + $2N$ branch
currents (`ibr1[m]`, `ibr2[m]` MNA rows).

### 1.2 Modal decomposition (cplsetup.c)

The propagation operator is governed by the matrix product
$\mathbf{Z}\mathbf{Y} = (\mathbf{R}+s\mathbf{L})(\mathbf{G}+s\mathbf{C})$.
The setup:

1. **Assemble** $\mathbf{ZY}(y)$ at expansion points $y$
   (`loop_ZY`): products of $(\text{scaled }\mathbf{L} + \mathbf{R}y)$
   and $(\text{scaled }\mathbf{C} + \mathbf{G}y)$ — $y=0$ gives the
   lossless $\mathbf{LC}$ product; `deg_o` further sample points
   capture the loss-induced frequency dependence.
2. **Diagonalize** each sample by cyclic **Jacobi rotations**
   (`diag`/`rotate`, threshold `epsi2`, symmetric pre-scaling by
   $2/(f_{min}+f_{max})$): produces the voltage eigenvector matrix
   $\mathbf{S}_v$, current transform $\mathbf{S}_i$
   ($\mathbf{S}_i \propto$ the congruent transform making
   $\mathbf{Y}\mathbf{S}_v$ diagonal), and eigenvalues $D_m$:

   $$\mathbf{S}_v^{-1}(\mathbf{ZY})\mathbf{S}_v = \mathrm{diag}(D_m)
   \;\Rightarrow\; \text{mode } m \text{ propagates with } \gamma_m = \sqrt{D_m}$$

   Modal delays $\tau_m = \ell\sqrt{D_m^{(LC)}}$ (`taul`, stored in ps).
3. **Frequency fit**: $\mathbf{S}_i(y), \mathbf{S}_i^{-1}(y),
   \mathbf{S}_v^{-1}(y)$ and the composite
   $\mathbf{S}_i\mathbf{S}_v^{-1}$ are interpolated as polynomials in
   $y$ over the sample points (`poly_matrix`, `poly_W`, giving the
   characteristic-admittance operator IWI/IWV entries).
4. **Padé synthesis** (`generate_out` → `Pade_apx`): every needed
   scalar transfer entry $h(y) = C_0(1 + p_1 y + \ldots)$ is fitted by
   a **3-pole rational**, poles from the real cubic
   (`find_roots`/`root3`), i.e.

   $$h(s) \approx C_0\left(c_0 + \sum_{k=1}^{3} \frac{c_k}{s - x_k}\right)
   \;\xrightarrow{\ \mathcal{L}^{-1}\ }\; C_0\Big(c_0\delta(t) + \sum_k c_k e^{x_k t}\Big)$$

   — exponential kernels ⇒ **recursive convolution**: each state
   updates in O(1) per timestep,
   $s_k(t+\Delta) = e^{x_k\Delta}s_k(t) + (\text{PWL input integral})$
   (`update_cnv`/`update_cnv_a` with `expC/multC` handling the complex
   pole pairs). Diagonal (attenuation) entries get the DC anchor
   $\sqrt{G_{mm}/R_{mm}}/C_0$; off-diagonals anchor at 0.

### 1.3 Port equations (cplload.c)

Per conductor $m$, Bergeron-style branch rows with the modal transforms
folded in:

- transient: characteristic-admittance instantaneous part on the
  port voltages (via the $\mathbf{S}_i\mathbf{W}\mathbf{S}_v^{-1}$
  polynomial operators) minus the branch current, RHS = delayed modal
  waves: transform port histories to modes ($\mathbf{S}_v^{-1}$ fit),
  delay each mode by $\tau_m$ with PWL interpolation on the shared
  history list (`VI_list`, `get_pvs_vi`), apply the per-mode
  attenuation convolution (recursive states, `update_delayed_cnv`),
  transform back ($\mathbf{S}_i$).
- **DC / cond1**: the line collapses to its series resistance:
  $i_1^{(m)} + i_2^{(m)} = 0$ and
  $(v_{pos}^{(m)} - v_{neg}^{(m)}) = (\mathbf{R}\ell\, \mathbf{i})_m$
  (row loop with `g = Rm·length`), plus `0.1·gmin` conditioning on all
  port diagonals.

### 1.4 Timestep guard

If $\min_m \tau_m < $ current max step, ngspice **forces**
`CKTmaxStep = 0.9·min(τ)` (cplload.c ~line 140) — the recursive
convolution assumes at least one sample per modal delay. (This is the
CPL analog of LTRA's `nl·T` limit, but imposed, not advisory.)

### 1.5 Symmetric 2-line special case (what our impl does)

For $N=2$ with identical self terms, the eigenvectors are bias-free:
even/odd modes $v_{e,o} = (v_1 \pm v_2)/\sqrt2$,
$L_{e,o} = L \pm L_m$, $C_{e,o} = C \pm C_m$,
$Z_{e,o} = \sqrt{L_{e,o}/C_{e,o}}$, $\tau_{e,o} = \ell\sqrt{L_{e,o}C_{e,o}}$
— two decoupled Bergeron lines plus lumped loss. This is exact for the
symmetric lossless 2-line and is what `coupled_tlines.zig` implements.
It **cannot represent** $N \ge 3$ (cpl3_4_line) or asymmetric 2-line
cards; the netlist mapping must reject/split those instead of forcing
them through the 6-terminal even/odd device (root cause of the 7.5e34
blowup: a 3-line P card mapped onto a 2-line topology leaves a port
row unconstrained).

## 2. Flow explanation

Setup once: parse R/L/G/C triangles → build ZY samples → Jacobi →
polynomial fits → Padé poles/residues per transfer entry → allocate
per-instance history (`VI_list`) and per-pole convolution states (TMS).

Per accepted timepoint (first NR iteration): append port $v/i$ to the
history; linearize inputs over the step (`nd->dv`); advance every
recursive convolution state; interpolate the $\tau_m$-delayed modal
values. Per NR iteration: stamp the constant matrix pattern + RHS
delayed sources (the line is linear — inputs frozen within the step,
exactly like LTRA/TRA).

State: shared timepoint list + per-instance port histories + per-pole
complex exponential states. Rejected steps roll back by list pointer.

## 3. Pseudo-code, CPU sequential

```
# setup (host, once)
fn cpl_setup(R, L, G, C, len):
    for y in {0, y1..y_deg}:                # expansion samples
        ZY = (aL + R*y)(aC + G*y)
        (Sv[y], D[y]) = jacobi(ZY);  Si[y] = derive_current_transform(...)
    fits = poly_fit({Si, Si^-1, Sv^-1, Si*Sv^-1}, y_samples)
    for each transfer entry h: (c[0..3], x[1..3]) = pade3(h, dc_anchor)
    tau[m] = len*sqrt(D_lossless[m])

# per accepted timestep
fn cpl_advance(hist, states, dt):
    hist.push(t, v_ports, i_ports)
    for s in states: s.val = exp(s.pole*dt)*s.val + pwl_integral(s, inputs, dt)
    for m in modes:  delayed[m] = attenuate(interp(hist_modal[m], t - tau[m]), states)

# per NR iteration
fn cpl_eval(x, P, delayed) -> residuals:
    vm  = Sv_inv * port_voltages(x)                  # modal transform
    for m: r_ibr1[m] = (Yc*v)(m) - x.ibr1[m] - E1m(delayed)   # + mirrored port 2
    port rows: ±ibr currents
    # DC: r_ibr1[m] = i1+i2 ; r_ibr2[m] = (vpos-vneg) - (R*len*i)[m]
```

## 4. Pseudo-code, GPU parallel (batched SoA)

Same split as LTRA: history/convolution advance is per-instance scalar
work once per timestep (host or a tiny kernel); the per-iteration
device work is dense small-matrix multiplies — ideal per-thread:

```
kernel cpl_batch(g, desc, blob, x, env):
    for inst = g.tid; inst < desc.count; inst += g.stride:
        P = prep[inst]                     # Sv_inv, Yc fits, N = dims[inst]
        v = gather(x, gath[inst*NU..])     # 2N ports + 2N branch currents
        vm = matvec(P.Sv_inv, v.ports)     # N<=MAX_DIM=8: registers
        r  = branch_rows(P.Yc, vm, v.ibr, env.delayed[inst])  # E1/E2 slabs
        scatter_add(g.rhs, gath, r)
        if WITH_DIAG: scatter_add(g.diag, P.Yc_diag, ones)
    # batch key: dimension N (fixes the register matrices, no divergence)
```

## Noise model (in-device)

None. ngspice computes no noise for CPL (no `cplnoise.c`); the
series-resistance loss is physically thermal but the reference is
silent. Contract ([noise-contract.md](noise-contract.md)):
`noise_gens = {}` today. A modern in-device treatment would add
per-conductor thermal $4kT\,/(R_{mm}\ell)$ distributed sources — only
worth it with a source demanding it (derived, no reference).

## Sources

- https://raw.githubusercontent.com/ngspice/ngspice/master/src/spicelib/devices/cpl/cplload.c (fetched)
- https://raw.githubusercontent.com/ngspice/ngspice/master/src/spicelib/devices/cpl/cplsetup.c (fetched)

## Verification status

- §1.2 pipeline (ZY assembly, Jacobi diag, poly fits, 3-pole Padé, DC anchors), §1.3 DC stamps + gmin, §1.4 maxstep clamp, §2 history/convolution flow: **source-verified** against the fetched files.
- §1.3 transient stamp detail (exact operator-to-matrix-entry mapping through IWI/IWV): **structural** — the polynomial-operator bookkeeping in cplsetup.c lines 800–1000 was not fully traced; trace before implementing.
- §1.5: our-impl analysis + fixture evidence (this repo).

## Our implementation

- `src/devices/models/coupled_tlines.va` (2-conductor even/odd cognate — see §1.5 for the ceiling), `src/frontend/parser.zig` P-card mapping.
- Bench fixtures: `benchmark/fixtures/devices/coupled_tlines` (FAIL 6.45e-1), `benchmark/fixtures/tline/cpl3_4_line` (7.5e34 blowup — N=3), `tline/cpl_ibm2`.
