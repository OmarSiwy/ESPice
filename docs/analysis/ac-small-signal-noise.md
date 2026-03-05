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

**Output contract** — ngspice's, exactly. One `.noise` card produces two
plots: `Noise Spectral Density Curves` over
(`frequency`, `onoise_spectrum`, `inoise_spectrum`), and — only when
$f_1 \neq f_2$ (`noisean.c:495`) — `Integrated Noise`, one point, no scale,
over (`v(onoise_total)`, `v(inoise_total)`). Every `onoise*`/`inoise*` column
is **square-rooted on the way out** unless `set sqrnoise`
(`cktnoise.c:110-113`, `:123-126`), so the shipped units are
$\mathrm{V}/\sqrt{\mathrm{Hz}}$ and $\mathrm{V}$ rms, not
$\mathrm{V^2/Hz}$. Everything inside `noise.sweep` is squared, like ngspice's
`Ndata`; `noise.run` takes the root at the same boundary ngspice does.

Error criteria: AC/noise are direct linear solves — accuracy is set by the
operating-point accuracy (all of [tolerance-system.md](tolerance-system.md)
applies to the OP) plus factorization conditioning; there is no iteration
to tolerance here.

## 2. Flow explanation

**AC** (`src/analysis/ac/ac.zig`): one `eval()` at $x_{op}$
linearizes the circuit — the analytic $G$ and $C$ planes *are* the
linearization; the sweep never touches the circuit again. Phases: (1) build
`FreqSolver` from the planes (stacked-real pattern, symbolic once);
(2) stamp the excitation phasor on the source branch row; (3) log sweep,
per point: set $\omega$, refill, refactor, solve, gather probes. Failure
handling: a singular factor at some $\omega$ surfaces as an error for the
whole sweep (no silent point skipping). Knobs: `f_start`, `f_stop`,
`points_per_decade`; tolerance bundle only affects the upstream OP.

**Noise — the in-device convention.** Every device model **owns its noise
sources**; analyses only consume them. Model source definitions live in
[models/](../../models/).
The contract interface (`../VerA/tools/contract.zig`): a device
declares comptime `noise_gens` metadata — `NoiseGen{row, col, kind}` with
`kind ∈ {thermal, shot, flicker}`, `row/col` naming the local unknowns the
generator sits across. The batch collector
(`problem/batch.zig collectNoise`, surfaced as
`Circuit.collectNoiseSources`) evaluates each device once at $x_{op}$ with
the AD scalar and reads the generator's small-signal conductance
**straight off the analytic Jacobian entry** `∂F[row]/∂x[col]` — the PSD
magnitude comes from the device's own physics at its own bias, never from
an analysis-side source table or netlist re-derivation.

Per frequency the analysis then does: one transposed solve
$A^{\mathsf H} y = e_o$ for the adjoint, one ordinary solve driven from the
input source for $H_{in}$, a 2-element dot per source, PSD weighting, and the
per-source log-log band integral above.

A model that declares no generator is **silent, not zero-noise**: `collect_noise`
is installed only for devices with a `noise_gens` decl
(`src/analysis/eval/engine.zig` `Hooks.collect_noise`), so an omitted declaration removes
the device from the analysis entirely. That is what made a resistor-only
`.noise` deck return exactly 0 until 2026-09-13.

Current coverage gap, flagged and measured: the collector maps only
`kind = thermal` ($S = 4kTg$); `shot` and `flicker` generators are declared by
16 models and **silently dropped** (`src/analysis/eval/engine.zig collectNoise`,
`.shot, .flicker => {}`). VerA compounds it — every `white_noise` call is
tagged `.thermal` regardless of what its argument computes
(`../VerA/src/ir/lower.zig` `noiseSrcsOf`), so a shot generator written
`white_noise(2q|I|)` is evaluated as $4kTg_d = 4q|I|/N$, i.e. $\sqrt 2$ high in
amplitude. Cost on the fixtures: `noise/amp_noise` +19.5%,
`devices/vbic_noise_scale` −62% at 1 kHz where ngspice's flicker term
dominates. The fix is the device-side `noisePsd` hook (contract surface landed
2026-07-12, `../VerA/tools/contract.zig PsdTerm`) plus VerA codegen emitting a
scalar noise-expression variant; the two land together. These figures
come from the historical 2026-09-10 zero-analysis audit.

Related small-signal analyses share the machinery: `ac/sp.zig`
(S-parameters), `ac/stb.zig` (stability/loop gain), `dc/tf.zig` (DC transfer
function), `eigen/pz.zig` (pole-zero on the same $G$, $C$ planes).

## 3. Pseudo-code, CPU sequential

```
ac_sweep(ckt, x_op, branch, mag, phase, probes):
    eval(x_op)                        # fills analytic G and C planes once
    fs = FreqSolver(G, C)             # 2n stacked-real, symbolic once
    rhs = 0; rhs[branch] = mag*cos(phase); rhs[n+branch] = mag*sin(phase)
    for f in log_sweep(f_start, f_stop, ppd):
        fs.set_omega(2*pi*f)          # refill [G -wC; wC G]
        x = fs.solve(rhs)             # refactor + solve
        for p in probes: resp[p][f] = x[p] + j*x[n+p]

noise_sweep(ckt, x_op, out_node):
    srcs = collect_noise_sources(x_op)     # (p, n, g) off analytic Jacobian
    fs = FreqSolver(G, C); e_out = unit(out_node)
    total = 0
    for f in log_sweep(...):
        fs.set_omega(2*pi*f)
        y = fs.solve_transposed(e_out)     # ONE adjoint solve per point
        S(f) = sum over srcs:
                 psd = 4*k*T*src.g
                 h   = (y[p]-y[n]) + j*(y[n+p]-y[n+n_])
                 |h|^2 * psd
        total += trapezoid(S, f)
    return S(.), sqrt(total)
```

## 4. Pseudo-code, GPU parallel

Frequency points are **embarrassingly parallel** — each is an independent
linear solve on the same pattern. Three axes, in order of payoff:

1. **Frequency batching**: all $N_{\text{pts}}$ systems share one symbolic
   factorization; numeric refactor + solve per point are independent →
   one point per block-cluster, or batched sparse refactor (same pivot
   order, different values).
2. **Multiple RHS**: for multi-output noise or S-params, all RHS columns
   of one frequency solve together (blocked triangular solves).
3. **Matrix-free/JFNK flavor** (repo GPU style): for very large $n$, solve
   $A(\omega) X = U$ per point with GMRES where $A\cdot v$ is one batched
   SoA pass over the device batches stamping $Gv + j\omega Cv$ — no
   factorization; frequency points become independent cooperative launches
   or lanes of one launch.

Sequential remains: nothing essential — the OP that feeds the sweep is the
only sequential prerequisite.

```
host:
    solve OP (see operating-point doc)
    upload G/C planes (or device batches) once
kernel ac_noise(freqs[0..P)):
    lane = frequency index (block cluster or launch)
    per lane:
        build/refresh values for omega_lane           # grid-stride over nnz
        solve A x = u   and/or   A^H y = e_out        # batched refactor
                                                      # or GMRES w/ batched G,C apply
        parallel over sources: acc += |y_p - y_n|^2 * psd   # atomic add per lane
    grid reduction: trapezoidal integral over sorted lanes  # log-scan, cheap
```

Noise-source accumulation parallelizes over sources within a lane (a dot +
atomic each). The adjoint structure is what makes the GPU version cheap:
without it, the multiple-RHS axis would be $N_{\text{src}}$ wide per point.

## Solvers used

| Phase | Solver doc | Impl |
|---|---|---|
| Stacked-real $2n$ sweep — sparse path fills the KLU pattern per $\omega$ (streamed copy, no re-assembly), dense below `DENSE_THRESHOLD = 16` | [klu-pipeline.md](../solvers/klu-pipeline.md), [circuit-matrix-specifics.md](../solvers/circuit-matrix-specifics.md) | `src/analysis/solvers/freq_solve.zig` (`fromCircuit`/`setOmega`/`solve`) |
| Noise adjoint: transposed solve on the same per-$\omega$ factors | [klu-pipeline.md](../solvers/klu-pipeline.md) (sparse `solveT`; dense fallback transposes per call) | `freq_solve.zig solveRhsT` |
| Upstream OP | [homotopy-continuation.md](../solvers/homotopy-continuation.md), [newton-raphson-convergence.md](../solvers/newton-raphson-convergence.md) | `dc/op.zig`, `src/analysis/solvers/converger.zig` |

---

**Sources fetched**

| Source | Status |
|---|---|
| Kundert rf-sim.pdf (designers-guide.org) | fetched — small-signal-about-operating-point framing verified (§ "periodic AC"/adjoint PXF discussion generalizes the LTI case here) |
| Rohrer et al. adjoint noise analysis (1971) | **paywalled — derived, not source-verified** (interreciprocity argument from knowledge; standard result) |

**Per-section verification**

- §1 stacked-real system, branch-row excitation, adjoint identity
  $A^{\mathsf H} y = e_o$, $4kTg$ PSD, trapezoidal integration: verified
  against `ac.zig` / `noise.zig` source.
- §1 adjoint derivation: derived (textbook); consistent with the
  implementation's `solveRhsT` + per-source dot.
- §2 in-device noise convention: verified against
  `../VerA/tools/contract.zig` (`noise_gens`/`NoiseGen`) and
  `src/analysis/eval/engine.zig collectNoise` (AD-Jacobian
  conductance read; thermal-only gap marked in source).
- §3: direct transcription. §4: extrapolation of the repo's batched-eval /
  JFNK GPU style to the frequency axis (frequency batching not yet
  implemented on GPU).

**Our implementation**

- `src/analysis/ac/ac.zig` — AC sweep.
- `src/analysis/ac/noise.zig` — adjoint noise.
- `src/analysis/solvers/freq_solve.zig` — stacked-real solver.
- Related: `ac/sp.zig`, `ac/stb.zig`, `dc/tf.zig`, `eigen/pz.zig`.
- Bench fixtures: `benchmark/fixtures/ac/rc_lowpass`,
  `benchmark/fixtures/noise/{amp_noise,rc_noise,resistor_noise}`,
  `benchmark/fixtures/{sp,stb,tf,pz}/*`.
