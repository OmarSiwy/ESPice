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
$U e^{j\omega t}$ and collecting orders gives the Volterra cascade — each
order is a **linear** solve at its own frequency, driven by products of
lower-order responses:

**First order** (ordinary AC):

$$
\big(G + j\omega C\big)\, V_1 = U .
$$

$U$ is not free. ngspice takes the F1 drive from whichever source card carries
`DISTOF1 [mag [phase]]` — never "the first source" — and a V card's drive lands
on that card's **MNA branch row**, at *half* the sinusoid amplitude, because
every Volterra kernel here is a one-sided phasor (`cktdisto.c:100-117`, the
stamp at `:115-116`). An I card instead drives its two node rows with
$\mp\tfrac12\,\text{mag}$ (`cktdisto.c:151-158`). Stamping the V-card drive on
a *node* row is what returned $V_1 = 0$ on every `.disto` deck until
2026-09-13: that node is pinned by the source's own branch equation.

**Second order** — the second-order nonlinear current at $2\omega$ acts as
the only source:

$$
\big(G + j\,2\omega\, C\big)\, V_2 = -\tfrac{1}{2} F''\,[V_1, V_1]
\;\;(-\, j2\omega\, \tfrac12 Q''[V_1,V_1] \text{ for charge nonlinearity}),
$$

**Third order** at $3\omega$ (and the intermodulation buckets):

$$
\big(G + j\,3\omega\,C\big)\, V_3 = -\,F''\,[V_1, V_2] - \tfrac{1}{6} F'''\,[V_1,V_1,V_1],
$$

The $\tfrac12$ on $F''[V_1,V_1]$ is ngspice's too — it spells the factor into
the device coefficient ($g_2 = \tfrac12\,g_d/v_{te}$, `diodset.c:78`) and
contributes $g_2 V_1^2$ (`dloadfns.c:545` `D1n2F1`); here the full double sum
already covers both $(a,b)$ and $(b,a)$, so the factor belongs once on the RHS.
Kernels are reported back as **sinusoid amplitudes**, i.e. $\times 2$ for $f_1$
and $2f_1$ (`dkerproc.c:24-52`).

Distortion figures: $\mathrm{HD2} = |V_2^{\text{out}}|/|V_1^{\text{out}}|$,
$\mathrm{HD3} = |V_3^{\text{out}}|/|V_1^{\text{out}}|$; two-tone inputs
$(\omega_1, \omega_2)$ populate mixing buckets
($\omega_1 \pm \omega_2$, $2\omega_1 - \omega_2$) with the same cascade —
this is exactly what ngspice .DISTO reports (manual §1.2.5: complex second
and third harmonics at every node for one tone; sum/difference and
$2f_2 - f_1$ buckets for two tones). Because each order is linear, results
are exact in the small-signal limit — no transient settling, no windowing,
numerically clean far below what .FOUR can resolve.

### Kernel acquisition

$F''$ requires second derivatives of every device. ngspice carries
hand-coded second/third derivatives per supported model (D, BJT, JFET,
MOS1-3/9/BSIM1). This engine gets $F''$ **by finite-differencing the
analytic Jacobian**:

$$
F''_{i,ab} \;\approx\; \frac{G_{ia}(x_0 + \epsilon e_b) - G_{ia}(x_0)}{\epsilon},
$$

one `eval` per unknown ($n$ evals total) — first derivatives stay analytic,
only the *extra* order is FD, so the truncation error is one order better
conditioned than FD-ing the residual twice. Implemented scope: **HD2 for a
single tone** ($V_1$, $V_2$, ratio); HD3/IM buckets are the documented
extension (same machinery, one more solve per bucket and the $F'''$
difference).

## 2. Flow explanation

`src/analysis/post/disto.zig`:

1. One `eval()` at $x_{op}$: dense $G$, $C$ copies.
2. Kernel pass: $n$ perturbed `eval`s, differencing `denseG` snapshots into
   the rank-3 tensor `d2[row][a][b]` ($n^3$ storage — the dense ceiling;
   device-side analytic $F''$ stamps are the scalable upgrade). A final
   `eval(x_op)` leaves the planes consistent with the op.
3. Per frequency (log sweep): first-order stacked-real solve at $\omega$
   (excitation: $\tfrac12\,\text{mag}\,e^{j\phi}$ on `drive_branch`, the
   branch row of the `DISTOF1` V card that `engine.zig buildJob` resolved off
   the deck; `ac_source_node` is the I-card form and takes the negated stamp);
   form $D_2 = F''[V_1, V_1]$ by the tensor contraction with complex $V_1$;
   second solve at $2\omega$ with $-\tfrac12 D_2$; record HD2 and
   $2|V_1|$, $2|V_2|$ at the output node.

Failure: singular admittance at any point errors the sweep. Knobs:
sweep triple, `ac_magnitude`/`ac_phase`, `fd_eps` ($10^{-6}$), drive branch
and output node, defaults from the contract.

**Output contract — an espice divergence, deliberate.** ngspice writes two
complex plots (`DISTORTION - 2nd harmonic`, `DISTORTION - 3rd harmonic`) over
*every* circuit variable; espice writes one real plot,
(`frequency`, `hd2`, `v1_mag`, `v2_mag`), at a single node — `output_node`,
defaulting to the last probe. The kernel numbers agree (all four `disto/*`
fixtures match the corresponding ngspice 2nd-harmonic column to
$\le 2.1\times10^{-5}$), but "the last probe" is an artifact of MNA row
numbering, not a contract: on `disto/bjt_ce` it selects `v(b)`, not the
collector. Emitting ngspice's shape needs the third-order kernel as well;
both are the same follow-up.

## 3. Pseudo-code, CPU sequential

```
disto(ckt, x_op, f_range):
    eval(x_op); G, C = dense planes
    # second-order kernel: FD of the analytic Jacobian
    for b in 0..n:
        eval(x_op + eps*e_b)
        d2[:, :, b] = (denseG() - G)/eps
    eval(x_op)                          # restore planes
    for f in log_sweep(f_range):
        solve (G + jwC) V1 = 0.5*mag*e^{j*phase} * e[drive_branch]
        D2[i] = sum_ab d2[i,a,b] * V1[a]*V1[b]       # complex contraction
        solve (G + j2wC) V2 = -0.5*D2                # second order
        HD2(f) = |V2[out]| / |V1[out]|               # the 2x cancels
        V1mag(f), V2mag(f) = 2*|V1[out]|, 2*|V2[out]|
```

## 4. Pseudo-code, GPU parallel

Three wide axes:

- **Kernel pass**: the $n$ perturbed Jacobian evaluations are independent —
  and on GPU they are $n$ batched SoA device-eval launches (or one launch
  with a perturbation-index axis); the differencing is a grid-stride
  subtract. Better: skip the tensor entirely — evaluate the *action*
  $F''[V_1, V_1]$ directly as a directional derivative,
  $F''[v,v] \approx (G(x_0 + \epsilon v) - G(x_0))\,v / \epsilon$ applied
  twice per frequency (2 batched evals per point instead of $n$ up front,
  no $n^3$ tensor) — the matrix-free flavor that matches the repo's JFNK
  style.
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
| Per-frequency complex solves (stacked-real dense) | none (dense path) | `src/analysis/solvers/dense_lu.zig` `buildComplexAdmittance` + `factorizeSolve` |
| Sparse upgrade for large n | [klu-pipeline.md](../solvers/klu-pipeline.md) via `freq_solve.zig` (same pattern at $\omega$ and $2\omega$) | upgrade path |
| Upstream OP | [homotopy-continuation.md](../solvers/homotopy-continuation.md) | `dc/op.zig` |

---

**Sources fetched**

| Source | Status |
|---|---|
| ngspice manual §1.2.5/§11.3.3 (.DISTO) | **fetched, verified** — Volterra small-signal method, harmonic/IM buckets, supported-device list, "use Fourier otherwise" guidance |
| Volterra circuit analysis theory (Chua & Ng; Wambacq & Sansen) | **books/paywalled — derived, not source-verified** (cascade equations standard) |

**Per-section verification**

- §1 Volterra cascade: derived (standard), consistent with the fetched
  manual's description of what .DISTO computes.
- §1 FD-of-analytic-Jacobian kernel + HD2-only scope: verified against
  `disto.zig` source (marked: HD3/IM not implemented).
- §2/§3: direct transcription. §4: prospective (matrix-free directional
  variant is a design note).

**Our implementation**

- `src/analysis/post/disto.zig` — HD2 sweep.
- Bench fixtures: `benchmark/fixtures/disto/*`.
