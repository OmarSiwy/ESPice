# Loop-Gain Stability (STB)

Middlebrook and Tian loop-gain probes; return ratio, gain/phase margins.

## 1. Mathematical specification

### Return ratio

For a feedback loop broken at a controlled source $x$, Bode's **return
ratio** $T$ is the negated signal returned around the loop for a unit
injected signal, with the external inputs dead; the stability measure is
the distance of $T$ from $-1$ (equivalently loop gain $-T$ from $+1$).
Margins (Tian et al., fetched):

$$
\text{GM} = -20\log_{10}|T(f_{180})| \ \text{dB}, \qquad
\text{PM} = 180^\circ + \angle T(f_{0\text{dB}}),
$$

with $f_{0\text{dB}}$ the unity-magnitude crossing and $f_{180}$ the
$-180^\circ$ phase crossing.

### Middlebrook's double null injection

Breaking a physical loop disturbs the DC bias and loading. Middlebrook's
method injects at an *unbroken* point: a voltage injection measurement and
a current injection measurement, whose null-based return ratios
$T_v^n = -v_f/v_e|_{i_f=0}$ and $T_i^n = -i_f/i_e|_{v_f=0}$ combine as
(Tian paper eq. 18, fetched):

$$
T = \frac{T_v^n\, T_i^n}{T_v^n + T_i^n}
$$

— exact for a **unilateral** loop regardless of the impedances either side
of the injection point (a single voltage injection alone requires
$|Y_f| \ll |Y_e|$; the double injection cancels the break-point loading).

### Tian's method

*(formula structure fetched; full bidirectional derivation in the paper)*
Middlebrook's combination still assumes forward-only signal flow through
the injection point. Tian et al. account for **bidirectional** transmission
(feedback signal flowing both ways through the break), deriving the loop
gain from two standard AC analyses at the same probe element — this is
Spectre's `.stb`. In simulator form: insert a 0 V source (or replicate the
probe element), run two small-signal solves (voltage-drive and
current-drive configurations), and combine the four measured responses so
both the forward and reverse transmission through the probe are separated.

### What this repo implements

A **single-injection voltage return-ratio probe**: augment the linearized
$(G, C)$ with one extra branch (a 0 V probe source between `probe_p` and
`probe_n`):

$$
\begin{pmatrix} G & \pm e \\ \pm e^{\mathsf T} & 0 \end{pmatrix},
$$

drive the probe branch row with a unit AC voltage, and read the loop gain
as the negated branch current:

$$
T(\omega) = -\,i_{br}(\omega).
$$

This is exact where the probe point is a good voltage-transfer break
(low source impedance driving high load impedance — output of an op-amp /
controlled source, the usual `.stb` probe discipline) and inherits the
single-injection caveat otherwise. Tian's two-analysis combination is the
documented upgrade (it costs exactly one more solve per frequency on the
same factorization). Margin extraction: linear interpolation between sweep
points at the crossings, with **phase unwrapping** for the gain margin —
atan2 wraps to $(-180°, 180°]$, so the $-180°$ crossing is invisible to a
raw comparison; the phase sequence is unwrapped before the scan.

## 2. Flow explanation

`src/analysis/ac/stb.zig`:

1. DC solve (own call — stability wants its exact bias), one `eval()` at
   the op; dense $G$/$C$ copies.
2. Augment to $(n{+}1)^2$: probe branch row/column stamped ($\pm 1$
   couplings, zero diagonal — an ideal 0 V source).
3. `FreqSolver.initDense` over the augmented pair; log sweep with unit RHS
   on the probe branch; $T(f) = -(x[br] + j\,x[n{+}br])$.
4. `computeMargins`: PM from the 0 dB crossing (first strict down-crossing
   preferred, any crossing as fallback), GM from the unwrapped $-180°$
   crossing; NaN when a margin's crossing doesn't exist in-band (two-pole
   loops never cross $-180°$ — correctly NaN, covered by unit test).

Knobs: probe node pair (defaults: drive source node → ground), sweep
triple, tolerance bundle for the DC solve.

## 3. Pseudo-code, CPU sequential

```
stb(ckt, probe_p, probe_n):
    x_op = dc_solve(ckt)
    eval(x_op); G, C = dense copies
    augment: G_aug[(n+1)^2] with probe branch b:
        G_aug[probe_p, b] += 1; G_aug[b, probe_p] += 1   (0V source stamps)
        G_aug[probe_n, b] -= 1; G_aug[b, probe_n] -= 1
    fs = FreqSolver(G_aug, C_aug)
    for f in log_sweep:
        x = fs.solve(e[b])                    # unit voltage on probe branch
        T(f) = -(x[b] + j*x[n_aug + b])
    PM: find |T| 0dB crossing, interpolate phase, PM = 180 + phase
    GM: unwrap phase, find -180 crossing, GM = -|T|_dB there
```

## 4. Pseudo-code, GPU parallel

Identical shape to AC: frequency points are independent lanes; the Tian
upgrade adds a second RHS per lane (multiple-RHS on one factorization).
Margins are a host-side epilogue over the sorted lane results (crossing
scan is inherently sequential but trivial).

```
kernel stb(lanes = freq points):
    per lane: fill values(omega); factor/GMRES; solve e[b] (+ e_i for Tian)
    T[lane] = combine(responses)
host: unwrap + crossing scan -> PM, GM
```

## Solvers used

| Phase | Solver doc | Impl |
|---|---|---|
| Upstream DC | [homotopy-continuation.md](../solvers/homotopy-continuation.md), [newton-raphson-convergence.md](../solvers/newton-raphson-convergence.md) | `dc/dc.zig solve` |
| Augmented stacked-real sweep | [klu-pipeline.md](../solvers/klu-pipeline.md) (sparse path exists; dense used here) | `src/analysis/solvers/freq_solve.zig initDense`, `src/analysis/solvers/dense_lu.zig` |

The probe augmentation changes the pattern (one extra row/col) — a
sparse-path variant needs the probe branch included in the symbolic
analysis; cheap, since one branch row is exactly what the MNA pattern
machinery already handles ([circuit-matrix-specifics.md](../solvers/circuit-matrix-specifics.md)).

---

**Sources fetched**

| Source | Status |
|---|---|
| Tian, Visvanathan, Hantgan, Kundert, "Striving for small-signal stability", IEEE Circuits & Devices 17(1) 2001 (kenkundert.com/docs/cd2001-01.pdf) | **fetched, verified** — return ratio definition, Middlebrook null double injection, $T = T_v^n T_i^n/(T_v^n + T_i^n)$, margin definitions |
| Middlebrook 1975 original | **paywalled — covered via the fetched Tian review** |

**Per-section verification**

- §1 return ratio/margins/Middlebrook formula: verified against the
  fetched paper. Tian bidirectional details: paper fetched, combination
  described at review level (full four-response algebra not transcribed).
- §1 our single-injection probe + its validity condition: verified against
  `stb.zig` source; honestly flagged as not-yet-Tian.
- §2/§3: direct transcription (incl. unwrapped GM scan). §4: prospective.

**Our implementation**

- `src/analysis/ac/stb.zig` — probe, sweep, margins (+ unit tests
  for one/two/three-pole margin behavior).
- Bench fixtures: `benchmark/fixtures/stb/*`.
