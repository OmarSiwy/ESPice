# Distortion Analysis (DISTO)

Small-signal harmonic distortion via Volterra series.

## 1. Mathematical specification

### Volterra framework

For small excitation about the operating point, expand the device
nonlinearities in a Taylor series in the perturbation $v$:

$$
F(x_0 + v) \approx G\,v \;+\; \tfrac{1}{2}\, F''\,[v, v]
\;+\; \tfrac{1}{6}\, F'''\,[v, v, v] + \dots
$$

with $G = F'(x_0)$ and the symmetric multilinear forms
$F''_{i,ab} = \partial^2 F_i/\partial x_a \partial x_b$ (and third order
likewise; charge nonlinearities contribute $Q'', Q'''$ terms multiplied by
$j\omega$ of the *response* frequency). Substituting a single-tone input
$U e^{j\omega t}$ and collecting orders gives the Volterra cascade: each
order is a **linear** solve at its own frequency, driven by products of
lower-order responses:

**First order** (ordinary AC):

$$
\big(G + j\omega C\big)\, V_1 = U .
$$

$U$ is not free. ngspice takes the F1 drive from whichever source card carries
`DISTOF1 [mag [phase]]`: never "the first source": and a V card's drive lands
on that card's **MNA branch row**, at *half* the sinusoid amplitude, because
every Volterra kernel here is a one-sided phasor (`cktdisto.c:100-117`, the
stamp at `:115-116`). An I card instead drives its two node rows with
$\mp\tfrac12\,\text{mag}$ (`cktdisto.c:151-158`). Stamping the V-card drive on
a *node* row is what returned $V_1 = 0$ on every `.disto` deck until
2026-09-13: that node is pinned by the source's own branch equation.

**Second order**: the second-order nonlinear current at $2\omega$ acts as
the only source:

$$
\big(G + j\,2\omega\, C\big)\, V_2 = -\tfrac{1}{2} F''\,[V_1, V_1]
\;\;(-\, j2\omega\, \tfrac12 Q''[V_1,V_1] \text{ for charge nonlinearity}),
$$

**Third order** at $3\omega$ (and the intermodulation buckets):

$$
\big(G + j\,3\omega\,C\big)\, V_3 = -\,F''\,[V_1, V_2] - \tfrac{1}{6} F'''\,[V_1,V_1,V_1],
$$

The $\tfrac12$ on $F''[V_1,V_1]$ is ngspice's too: it spells the factor into
the device coefficient ($g_2 = \tfrac12\,g_d/v_{te}$, `diodset.c:78`) and
contributes $g_2 V_1^2$ (`dloadfns.c:545` `D1n2F1`); here the full double sum
already covers both $(a,b)$ and $(b,a)$, so the factor belongs once on the RHS.
Kernels are reported back as **sinusoid amplitudes**, i.e. $\times 2$ for $f_1$
and $2f_1$ (`dkerproc.c:24-52`).

Distortion figures: $\mathrm{HD2} = |V_2^{\text{out}}|/|V_1^{\text{out}}|$,
$\mathrm{HD3} = |V_3^{\text{out}}|/|V_1^{\text{out}}|$; two-tone inputs
$(\omega_1, \omega_2)$ populate mixing buckets
($\omega_1 \pm \omega_2$, $2\omega_1 - \omega_2$) with the same cascade -
this is exactly what ngspice .DISTO reports (manual §1.2.5: complex second
and third harmonics at every node for one tone; sum/difference and
$2f_2 - f_1$ buckets for two tones). Because each order is linear, results
are exact in the small-signal limit: no transient settling, no windowing,
numerically clean far below what .FOUR can resolve.

### Kernel acquisition

$F''$ requires second derivatives of every device. ngspice carries
hand-coded second/third derivatives per supported model (D, BJT, JFET,
MOS1-3/9/BSIM1). This engine gets $F''$ **by finite-differencing the
analytic Jacobian**:

$$
F''_{i,ab} \;\approx\; \frac{G_{ia}(x_0 + \epsilon e_b) - G_{ia}(x_0 - \epsilon e_b)}{2\epsilon},
$$

two `eval`s per unknown ($2n$ evals total): first derivatives stay analytic,
only the *extra* order is FD, so the truncation error is one order better
conditioned than FD-ing the residual twice. The difference is central
because the forward one's $O(\epsilon F''')$ error was the whole residual of
`disto/bench_disto_diode_clipper`'s 2nd-harmonic plot (err/tol 0.016-0.019
forward, 2.1e-7 and 2.5e-7 central for v(out) and i(vin)).

The third-order kernel is never stored: $F'''$ is $O(n^4)$ and its only use
is the contraction $F'''[V_1, V_1, V_1]$. For a unit direction $u$ and
$G_k = G(x + khu)$,
$S(u) = (16(G_1 + G_{-1}) - (G_2 + G_{-2}) - 30G_0)/12h^2 = F'''(\cdot, \cdot, u, u) + O(h^4)$,
and the cubic form follows by symmetry. With $V_1 = p + jq$ that is eight
evaluations per frequency point, $S(\hat p)$ and $S(\hat q)$
(`cubicForms`). Implemented scope: second and third harmonics for a single
tone. The two-tone intermodulation buckets are not implemented.

The step is its own constant, $h = 10^{-3}$ (`cubic_step`), not `fd_eps`.
A second difference loses $\varepsilon|G|/h^2$ to roundoff, and $V_1$ is
usually dominated by a nearly linear output node, so the nonlinearity's
controlling voltage moves only a small fraction of $h$. With the old
three-point stencil at $h = 10^{-6}$, `disto/bench_disto_bjt_ce`'s HD3 was
roundoff: its worst i(vcc) err/tol read 11.5, 0.16, 0.57, 9.05 and 1.03 at
26.99998, 26.99999, 27, 27.00001 and 27.00002 °C. At $h \ge 10^{-4}$ it
reads 0.094 at all five, and the five-point stencil is flat to four digits
from $h = 10^{-4}$ to $10^{-2}$ (the three-point one drifts to 0.083 at
$10^{-2}$ from truncation). The fourth-order truncation is
$(h/V_t)^4/90$, $2.4\times10^{-8}$ relative for a bare exponential at
$10^{-3}$ V. ngspice gets exact coefficients from each device's DISTO
Taylor sections; an exact $F'''$ here would need a second-order AD pass
through the device ABI, which this step makes unnecessary at the corpus's
$10^{-3}$ tolerances.

## 2. Flow explanation

`src/analysis/post/disto.zig`:

1. One `eval()` at $x_{op}$: dense $G$, $C$ copies.
2. Kernel pass: $n$ perturbed `eval`s, differencing `denseG` snapshots into
   the rank-3 tensor `d2[row][a][b]` ($n^3$ storage: the dense ceiling;
   device-side analytic $F''$ stamps are the scalable upgrade). A final
   `eval(x_op)` leaves the planes consistent with the op.
3. Per frequency (log sweep): first-order stacked-real solve at $\omega$
   (excitation: $\tfrac12\,\text{mag}\,e^{j\phi}$ on `drive_branch`, the
   branch row of the `DISTOF1` V card that `buildJob` (`src/frontend/analyses.zig`) resolved off
   the deck; `ac_source_node` is the I-card form and takes the negated stamp);
   form $D_2 = F''[V_1, V_1]$ by the tensor contraction with complex $V_1$;
   second solve at $2\omega$ with $-\tfrac12 D_2$; for the third-harmonic
   plot, the cubic form and a solve at $3\omega$; record HD2,
   $2|V_1|$, $2|V_2|$ and the harmonic solutions at the probes.

Failure: singular admittance at any point errors the sweep. Knobs:
sweep triple, `ac_magnitude`/`ac_phase`, `fd_eps` ($10^{-6}$), drive branch
and output node, defaults from the contract.

**Output contract.** One `.disto` card publishes three plots, one query
each: ngspice's `DISTORTION - 2nd harmonic` and `DISTORTION - 3rd harmonic`,
complex and point-major (frequency, then the probes), and an espice summary
plot `Distortion Analysis`, real, over (`frequency`, `hd2`, `v1_mag`,
`v2_mag`) at a single node (`output_node`, defaulting to the last probe).
The harmonic plots report the sinusoid amplitude, twice the one-sided
phasor; the summary does not apply that factor. The summary is the
deliberate divergence: ngspice has no such plot. "The last probe" is an
artifact of MNA row numbering, not a contract: on `disto/bjt_ce` it selects
`v(b)`, not the collector. Only the first `DISTOF1` card drives the sweep
(ngspice sums every one); with no `DISTOF1` card, ngspice solves an
unexcited system and prints zeros, while espice falls back to the deck's
drive source. Both are marked `ponytail:` in the code. The fan-out of one
card into three queries lives in `frontend/analyses.zig`.

## 3. Pseudo-code, CPU sequential

```
disto(ckt, x_op, f_range):
    eval(x_op); G, C = dense planes
    # second-order kernel: FD of the analytic Jacobian
    for b in 0..n:
        Gp = eval(x_op + eps*e_b); Gm = eval(x_op - eps*e_b)
        d2[:, :, b] = (Gp - Gm)/(2*eps)
    eval(x_op)                          # restore planes
    for f in log_sweep(f_range):
        solve (G + jwC) V1 = 0.5*mag*e^{j*phase} * e[drive_branch]
        D2[i] = sum_ab d2[i,a,b] * V1[a]*V1[b]       # complex contraction
        solve (G + j2wC) V2 = -0.5*D2                # second order
        HD2(f) = |V2[out]| / |V1[out]|               # the 2x cancels
        V1mag(f), V2mag(f) = 2*|V1[out]|, 2*|V2[out]|
```

## 4. Parallel design notes (not implemented)

Three wide axes:

- **Kernel pass**: the $n$ perturbed Jacobian evaluations are independent -
  and on GPU they are $n$ batched SoA device-eval launches (or one launch
  with a perturbation-index axis); the differencing is a grid-stride
  subtract. Better: skip the tensor entirely: evaluate the *action*
  $F''[V_1, V_1]$ directly as a directional derivative,
  $F''[v,v] \approx (G(x_0 + \epsilon v) - G(x_0))\,v / \epsilon$ applied
  twice per frequency (2 batched evals per point instead of $n$ up front,
  no $n^3$ tensor), the same directional trick the third-order kernel
  already uses.
- **Frequency points**: independent lanes (two solves each), as in AC.
- **Tensor contraction** (if kept): per-frequency GEMV-shaped reduction,
  grid-stride over rows with per-row $ab$ loops.

```
kernel disto(lanes = freq points):
    per lane:
        solve (G + jwC) V1 = u                       # batched/GMRES
        D2 = FD-directional F''[V1,V1] via 2 batched evals  # matrix-free
        solve (G + j2wC) V2 = -D2
        HD2 = |V2[out]|/|V1[out]|
```

## Solvers used

| Phase | Solver doc | Impl |
|---|---|---|
| Per-frequency complex solves (stacked-real dense) | none (dense path) | `src/solver/dense_lu.zig` `buildComplexAdmittance` + `factorizeSolve` |
| Sparse upgrade for large n | [klu-pipeline.md](../solvers/klu-pipeline.md) via `freq_solve.zig` (same pattern at $\omega$ and $2\omega$) | upgrade path |
| Upstream OP | [homotopy-continuation.md](../solvers/homotopy-continuation.md) | `dc/op.zig` |

---

**Sources fetched**

| Source | Status |
|---|---|
| ngspice manual §1.2.5/§11.3.3 (.DISTO) | **fetched, verified**: Volterra small-signal method, harmonic/IM buckets, supported-device list, "use Fourier otherwise" guidance |
| Volterra circuit analysis theory (Chua & Ng; Wambacq & Sansen) | **books/paywalled: derived, not source-verified** (cascade equations standard) |

**Per-section verification**

- §1 Volterra cascade: derived (standard), consistent with the fetched
  manual's description of what .DISTO computes.
- §1 FD-of-analytic-Jacobian kernels (second order, and third order as a
  directional second difference): verified against `disto.zig`. Two-tone
  IM: not implemented.
- §2/§3: direct transcription. §4: design notes (matrix-free directional
  variant is a design note).

**Our implementation**

- `src/analysis/post/disto.zig`: HD2/HD3 sweep and the three plots.
- Fixtures: `tests/fixtures/disto/`.
