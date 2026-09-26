# AC Small-Signal + Noise (Adjoint) Analysis

## 1. Mathematical specification

### Linearization about the operating point

Let $x_0$ solve the DC system $F(x_0) = 0$ and define

$$
G = \frac{\partial i}{\partial x}\Big|_{x_0}, \qquad
C = \frac{\partial q}{\partial x}\Big|_{x_0}.
$$

A small-signal excitation $u(t) = \Re\{U e^{j\omega t}\}$ superposed on the
DC bias produces, to first order, the phasor response $X(\omega)$ solving
the linear complex system

$$
A(\omega)\,X = U, \qquad A(\omega) = G + j\omega C .
$$

Excitation placement: driving a vsource means setting the RHS of its
**branch row** (branch equation $v_p - v_n - V = 0$, so
$\text{rhs}[\text{branch}] = V_{ac} e^{j\phi}$); stamping the clamped node
row instead yields identically zero response.

### Stacked-real formulation

The engine solves the $2n$ real equivalent

$$
\begin{pmatrix} G & -\omega C \\ \omega C & G \end{pmatrix}
\begin{pmatrix} x_{re} \\ x_{im} \end{pmatrix}
=
\begin{pmatrix} u_{re} \\ u_{im} \end{pmatrix},
$$

which reuses the real sparse machinery (pattern = $G$/$C$ union, doubled).
One symbolic analysis; per frequency point only a numeric refill + refactor
+ solve.

### Noise: adjoint (transposed-system) method

Each physical noise generator $s$ is a current source of one-sided PSD
$S_s(f)$ across nodes $(p_s, n_s)$; for thermal noise of a (linearized)
conductance $g_s$,

$$
S_s = 4 k_B T g_s \quad [\mathrm{A^2/Hz}] .
$$

In general each generator reports a white part and a flicker part,
$S_s(f) = W_s + K_s / f^{e_s}$, from the device's own noise model (§2).

The output noise density at node $o$ sums over uncorrelated sources through
their transfer impedances $H_s(\omega) = e_o^{\mathsf T} A^{-1} (e_{p_s} - e_{n_s})$:

$$
S_{v,o}(\omega) \;=\; \sum_s |H_s(\omega)|^2 \, S_s .
$$

Computing every $H_s$ directly costs one solve per source. The **adjoint
trick**: one transposed solve per frequency,

$$
A^{\mathsf H}\, y = e_o
\;\;\Longrightarrow\;\;
H_s = \langle y,\, e_{p_s} - e_{n_s} \rangle^{*} = (y_{p_s} - y_{n_s})^{*},
$$

since $e_o^{\mathsf T} A^{-1} b = (A^{-\mathsf H} e_o)^{\mathsf H} b$. Every
source then costs one 2-element dot; solve count drops from
$N_{\text{pts}} \times N_{\text{src}}$ to $N_{\text{pts}}$. The conjugate
drops out of $|H_s|^2$, so the stacked-real transpose solve suffices.
This is Rohrer's adjoint-network noise analysis (interreciprocity: the
transposed MNA system *is* the adjoint network).

The input-referred spectrum divides by the power gain of the `.noise` card's
own input source, $S_{v,i} = S_{v,o} / \max(|H_{in}|^2, 10^{-20})$, with
$H_{in}$ the ordinary AC response at $o$ driven from that source's branch
(ngspice `noisean.c:423-430`; the floor is `N_MINGAIN`).

Total integrated noise over the sweep band $[f_1, f_2]$:

$$
v_{n,\text{tot}} = \sqrt{\int_{f_1}^{f_2} S_{v,o}(f)\, df}.
$$

Not a trapezoid, and **per source**: between two adjacent sweep points each
generator's own density is fitted as $a f^{p}$ in log-log and integrated
exactly, because the sum of a flat thermal and a $1/f$ flicker term is not
itself a power law (ngspice `ninteg.c:27-45`, applied per generator at
`resnoise.c:141-161`). $|p| < 10^{-10}$ degenerates to the rectangle rule and
$|p+1| < 10^{-10}$ to $a\ln(f_2/f_1)$. The first sweep point only seeds the
history ($\Delta f = 0$, `noisean.c:376`).

**Output contract**: ngspice's, exactly. One `.noise` card produces two
plots: `Noise Spectral Density Curves` over
(`frequency`, `onoise_spectrum`, `inoise_spectrum`), and: only when
$f_1 \neq f_2$ (`noisean.c:495`): `Integrated Noise`, one point, no scale,
over (`v(onoise_total)`, `v(inoise_total)`). Every `onoise*`/`inoise*` column
is **square-rooted on the way out** unless `set sqrnoise`
(`cktnoise.c:110-113`, `:123-126`), so the shipped units are
$\mathrm{V}/\sqrt{\mathrm{Hz}}$ and $\mathrm{V}$ rms, not
$\mathrm{V^2/Hz}$. Everything inside `noise.sweep` is squared, like ngspice's
`Ndata`; `noise.run` takes the root at the same boundary ngspice does.

Error criteria: AC/noise are direct linear solves: accuracy is set by the
operating-point accuracy (all of [tolerance-system.md](tolerance-system.md)
applies to the OP) plus factorization conditioning; there is no iteration
to tolerance here.

## 2. Flow explanation

**AC** (`src/analysis/ac/ac.zig`): one `eval()` at $x_{op}$
linearizes the circuit: the analytic $G$ and $C$ planes *are* the
linearization; the sweep never touches the circuit again. Phases: (1) build
`FreqSolver` from the planes (stacked-real pattern, symbolic once);
(2) stamp the excitation phasor on the source branch row; (3) sweep through
`freq.Stream` (below): per chunk of frequencies, refill and replay the
factorization across SIMD lanes, solve, gather probes. Failure
handling: a singular factor at some $\omega$ surfaces as an error for the
whole sweep (no silent point skipping). Knobs: the shared `sweep` grid
(`f_start`/`f_stop`/`points`/`kind`, where `kind` is `dec`/`oct`/`lin`);
tolerance bundle only affects the upstream OP.

**Noise: the in-device convention.** Every device model owns its noise
sources; analyses only consume them. Model sources live in
[models/](../../models/). A device declares comptime `noise_gens` metadata
(one generator per entry, `row`/`col` naming the local unknowns it sits
across) and a `noisePsd` function returning one term per generator:
`white`, `flicker` and the flicker exponent `ef`. The batch collector
(`collectNoise` in `src/device/eval.zig`, surfaced as
`Circuit.collectNoiseSources`) evaluates `noisePsd` for each instance at the
given $x$ and appends one `NoiseSource` per generator with the absolute
values of both parts (`@abs`, as ngspice `nevalsrc.c:106`). The PSD comes
from the device's own physics at its own bias, never from an analysis-side
table. It is pure in $x$, so `.pnoise` calls it once per PSS sample.
Zero-power generators stay in the list: their ordinal identifies them across
PSS samples. Correlation between generators is not transported; they are
treated as independent.

Per frequency the analysis then does one transposed solve
$A^{\mathsf H} y = e_o$ for the adjoint, one ordinary solve driven from the
input source for $H_{in}$, a 2-element dot per source, PSD weighting, and the
per-source log-log band integral above.

A model that declares no generator is silent, not zero-noise: the
`collect_noise` hook is installed only for devices with a `noise_gens`
declaration, so an omitted declaration removes the device from the analysis.
That is why a resistor-only `.noise` deck returned exactly 0 until
2026-09-13.

**Frequency lanes.** `ac`, `noise` and `stb` share one driver,
`freq.Stream` (`src/analysis/ac/freq.zig`): it solves `quantum` = 64
frequencies per `FreqSolver.solveBatch` call (W lanes per `LaneLu` replay of
one pivot tape) and hands them out in order, so at most 64 solutions of
$2n$ values are live instead of the whole sweep. Chunking cannot change a bit
of the result, since lanes are independent and the pivot tape carries across
calls. Measured (commit `8bd084e`) on a 1k-stage RC ladder with
`.noise dec 200 1 1g` (1601 points): 3.191G to 3.183G Ir and peak RSS
70.1 MB to 16.6 MB. The same ladder under `.ac dec 200 1 1g` with every node
probed stays at 67 MB, since the all-node result dominates the peak. `sp`
keeps its dense per-port, per-point solve: a Stream per port would multiply
the factorizations, and a per-lane-rhs `solveBatch` (a solver change) would
be needed first.

Related small-signal analyses share the machinery: `ac/sp.zig`
(S-parameters), `ac/stb.zig` (stability/loop gain), `dc/tf.zig` (DC transfer
function), `eigen/pz.zig` (pole-zero on the same $G$, $C$ planes).

## 3. Pseudo-code, CPU sequential

```
ac_sweep(ckt, x_op, branch, mag, phase, probes):
    eval(x_op)                        # fills analytic G and C planes once
    fs = FreqSolver(G, C)             # 2n stacked-real, symbolic once
    rhs = 0; rhs[branch] = mag*cos(phase); rhs[n+branch] = mag*sin(phase)
    for chunk of 64 omegas in sweep:
        X = fs.solve_batch(chunk, rhs)   # W lanes per LaneLu replay; failing lanes peel to scalar
        for (f, x) in chunk: for p in probes: resp[p][f] = x[p] + j*x[n+p]

noise_sweep(ckt, x_op, out_node):
    srcs = collect_noise_sources(x_op)     # (p, n, white, flicker, ef) per generator
    fs = FreqSolver(G, C); e_out = unit(out_node)
    total = 0
    for (f, y) in stream(fs, sweep, e_out, adjoint = true):   # ONE adjoint solve per point
        S(f) = sum over srcs:
                 psd = white + flicker / f^ef
                 h   = (y[p]-y[n]) + j*(y[n+p]-y[n+n_])
                 |h|^2 * psd
        total += per-source log-log band integral
    return sqrt(S(.)), sqrt(total)
```

## 4. Parallel execution

Frequency points are independent linear solves on the same pattern. The
implemented axis is SIMD lanes: `FreqSolver.solveBatch` replays one
`SparseLu` pivot tape across W frequencies at once (`LaneLu(W)`, W = the
native f64 vector width), and a lane whose pivot-growth monitor fails peels
to the scalar full-factor path, which repivots the tape for the next chunk.
Everything runs on the host.

Not implemented (design notes): all RHS columns of one frequency (multi-output
noise, S-parameter ports) solved together as blocked triangular solves; and
for very large $n$, a matrix-free GMRES per point where $A\cdot v$ is one
batched device pass stamping $Gv + j\omega Cv$, with frequencies as
independent GPU lanes. Noise-source accumulation would then parallelize over
sources within a lane. The adjoint is what keeps any of these cheap: without
it the RHS axis is $N_{\text{src}}$ wide per point.

## Solvers used

| Phase | Solver doc | Impl |
|---|---|---|
| Stacked-real $2n$ sweep: sparse path fills the KLU pattern per $\omega$ (streamed copy, no re-assembly), dense for $n \le 16$ | [klu-pipeline.md](../solvers/klu-pipeline.md), [circuit-matrix-specifics.md](../solvers/circuit-matrix-specifics.md) | `src/solver/freq_solve.zig` (`fromCircuit`, `solveBatch`), `src/solver/lane_lu.zig` |
| Noise adjoint: transposed solve on the same per-$\omega$ factors | [klu-pipeline.md](../solvers/klu-pipeline.md) (sparse `solveT`; dense fallback transposes per call) | `freq_solve.zig solveBatch(..., adjoint = true)` |
| Upstream OP | [homotopy-continuation.md](../solvers/homotopy-continuation.md), [newton-raphson-convergence.md](../solvers/newton-raphson-convergence.md) | `dc/op.zig`, `src/solver/converger.zig` |

---

**Sources fetched**

| Source | Status |
|---|---|
| Kundert rf-sim.pdf (designers-guide.org) | fetched; small-signal-about-operating-point framing verified (§ "periodic AC"/adjoint PXF discussion generalizes the LTI case here) |
| Rohrer et al. adjoint noise analysis (1971) | paywalled; derived, not source-verified (interreciprocity argument; standard result) |

**Per-section verification**

- §1 stacked-real system, branch-row excitation, adjoint identity
  $A^{\mathsf H} y = e_o$, white-plus-flicker PSD, per-source log-log
  integration: verified against `ac.zig` / `noise.zig`.
- §1 adjoint derivation: derived (textbook); consistent with the
  implementation's `solveRhsT` + per-source dot.
- §2 in-device noise convention: verified against `collectNoise` in
  `src/device/eval.zig` and the `collect_noise` hook in `src/device/abi.zig`.
- §3: transcribed from source. §4: SIMD lanes are implemented; the rest is
  design.

**Our implementation**

- `src/analysis/ac/ac.zig`: AC sweep.
- `src/analysis/ac/noise.zig`: adjoint noise.
- `src/analysis/ac/freq.zig`: `Stream`, the shared frequency driver.
- `src/solver/freq_solve.zig`, `src/solver/lane_lu.zig`: stacked-real solver
  and its lane replay.
- Related: `ac/sp.zig`, `ac/stb.zig`, `dc/tf.zig`, `eigen/pz.zig`.
- Fixtures: `tests/fixtures/ac/`, `tests/fixtures/noise/`,
  `tests/fixtures/{sp,stb,tf,pz}/`.
