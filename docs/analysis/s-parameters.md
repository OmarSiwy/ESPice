# S-Parameter Analysis

Port formulation, reference impedances, wave-variable extraction.

## 1. Mathematical specification

### Ports and wave variables

Each port $k$ is a netlist vsource (node $n_k$, MNA branch $b_k$) with
reference impedance $z_{0k}$ (default 50 Ω). Incident/reflected **power
waves** at port $k$ with port voltage $V_k$ and current into the DUT
$I_k$:

$$
a_k = \frac{V_k + z_{0k} I_k}{2\sqrt{z_{0k}}}, \qquad
b_k = \frac{V_k - z_{0k} I_k}{2\sqrt{z_{0k}}},
$$

(real $z_0$; the general complex-$z_0$ pseudo-wave definition reduces to
this). The S-matrix is defined by $b = S\,a$ with all other ports
**terminated in their reference impedance** ($a_j = 0,\ j \ne k$):

$$
S_{jk}(\omega) = \frac{b_j}{a_k}\Big|_{a_{l\ne k} = 0}.
$$

### MNA realization of terminated ports

A z0-termination is folded into the port source itself: modify the branch
equation from $v_p - v_n = V_s$ to the **Thevenin form**

$$
v_p - v_n - z_0\, i_{br} = V_s
\quad\Longleftrightarrow\quad
G[b_k, b_k] \mathrel{-}= z_0,
$$

so an *unexcited* port ($V_s = 0$) presents exactly $z_0$ to the DUT
instead of clamping its node, and an excited port is a source with $z_0$
in series. Driving port $k$ with unit source voltage gives incident wave
$a_k = \frac{1}{2\sqrt{z_{0k}}}$ (the source splits between $z_0$ and the
matched-condition definition), and every port's reflected wave is read
from the same solve:

$$
b_j = \frac{V_j - z_{0j} I_j}{2\sqrt{z_{0j}}},
\qquad I_j = -\,i_{br_j}
$$

(branch stamps $F_p = +i_{br}$, so current into the DUT is the negated
branch unknown). One frequency point costs one factorization of
$G' + j\omega C$ ($G'$ = terminated conductance matrix) and $P$ solves
(one per driven port) to fill the whole $P \times P$ S-matrix column by
column.

Derived quantities follow standard conversions ($Z = \sqrt{z_0}(I-S)^{-1}(I+S)\sqrt{z_0}$
etc.); the analysis outputs $S$ directly.

## 2. Flow explanation

`modules/analysis/src/ac/sp.zig`:

1. One `eval()` at $x_{op}$; dense copies of the analytic $G$/$C$ planes.
   The port termination is an *analysis-side* modification, so it is
   stamped on the copy ($-z_0$ on each port's branch diagonal), never on
   the circuit planes.
2. `FreqSolver.initDense` over the modified pair (stacked-real
   $2n \times 2n$; the dense path here since terminations densify the
   branch rows anyway and port counts are small — the sparse pipeline
   remains the path for large $n$ via `fromCircuit`, see the solver note
   below).
3. Sweep (log or linear, `n_points`): per frequency set $\omega$, then per
   port $p$: unit RHS on branch $b_p$, solve, extract all $b_k/a_p$ →
   column $p$ of $S(\omega)$.

Defaults: with no explicit port list, the drive source becomes port 1 (a
1-port $S_{11}$ measurement). Failure: singular factorization at a
frequency point errors the sweep.

Knobs: `f_start/f_stop/n_points/sweep_type`, per-port `z0`.

## 3. Pseudo-code, CPU sequential

```
sp_sweep(ckt, x_op, ports):
    eval(x_op); G, C = dense planes (copies)
    for k in ports: G[b_k, b_k] -= z0_k          # Thevenin termination
    fs = FreqSolver(G, C)                        # stacked-real 2n
    for f in sweep:
        fs.set_omega(2*pi*f)
        for p in ports:                          # one solve per driven port
            x = fs.solve(e[b_p])                 # unit source voltage
            a_p = 1/(2*sqrt(z0_p))
            for k in ports:
                V_k = x[n_k] (+j x[n+n_k]);  I_k = -(x[b_k] + j x[n+b_k])
                b_k = (V_k - z0_k*I_k)/(2*sqrt(z0_k))
                S[k][p](f) = b_k / a_p
```

## 4. Pseudo-code, GPU parallel

Same shape as AC ([ac-small-signal-noise.md](ac-small-signal-noise.md) §4)
with one extra inner axis:

- **frequency points** — independent lanes (shared symbolic, per-lane
  values);
- **driven ports** — the $P$ RHS per frequency are a multiple-RHS block
  solve on one factorization (blocked triangular solves; $P$ is small so
  this rides along free);
- wave extraction is a trivial per-lane epilogue.

```
kernel sp(lanes = freq points):
    build values for omega_lane; factor (batched) or GMRES matrix-free
    block-solve P RHS (unit branch excitations)
    parallel over (k, p): S[k][p] = wave_ratio(x_p, port k)
```

## Solvers used

| Phase | Solver doc | Impl |
|---|---|---|
| Stacked-real frequency solves | [klu-pipeline.md](../solvers/klu-pipeline.md) (sparse path), dense below threshold | `modules/solvers/src/freq_solve.zig` (`initDense` here; `DENSE_THRESHOLD = 16` governs the `fromCircuit` route) |
| Dense factorization per point | none (dense path) | `modules/solvers/src/dense_lu.zig` |
| Upstream OP | [homotopy-continuation.md](../solvers/homotopy-continuation.md) | `dc/op.zig` |

Note: the termination stamp densifies only port branch diagonals — a
sparse-path variant would stamp $-z_0$ into the CSC copy and keep the KLU
pipeline; documented upgrade for many-node DUTs.

---

**Sources fetched**

| Source | Status |
|---|---|
| Kundert rf-sim.pdf | fetched (background; no S-param formulation section) |
| Power-wave definition (Kurokawa 1965) | **paywalled — derived, not source-verified** (standard definition) |
| designers-guide S-param paper | none found on the fetched analysis index |

**Per-section verification**

- §1 Thevenin termination stamp, $a$/$b$ extraction incl. the
  $I = -i_{br}$ sign and $a_p = 1/(2\sqrt{z_0})$: verified against
  `sp.zig` source.
- §2/§3: direct transcription. §4: prospective.

**Our implementation**

- `modules/analysis/src/ac/sp.zig`.
- Bench fixtures: `benchmark/fixtures/sp/*`.
