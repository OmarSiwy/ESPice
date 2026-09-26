# Loop-Gain Stability (STB)

Middlebrook and Tian loop-gain probes; return ratio, gain/phase margins
(theory; the analysis publishes $T(f)$ only).

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

- exact for a **unilateral** loop regardless of the impedances either side
of the injection point (a single voltage injection alone requires
$|Y_f| \ll |Y_e|$; the double injection cancels the break-point loading).

### Tian's method

*(formula structure fetched; full bidirectional derivation in the paper)*
Middlebrook's combination still assumes forward-only signal flow through
the injection point. Tian et al. account for **bidirectional** transmission
(feedback signal flowing both ways through the break), deriving the loop
gain from two standard AC analyses at the same probe element: this is
Spectre's `.stb`. In simulator form: insert a 0 V source (or replicate the
probe element), run two small-signal solves (voltage-drive and
current-drive configurations), and combine the four measured responses so
both the forward and reverse transmission through the probe are separated.

### What this repo implements

A **single-injection voltage return-ratio probe** on the deck's own 0 V
source (`.stb Vprobe ...`). Its branch equation is already
$v_p - v_n - V = 0$, so driving `rhs[branch] = 1` makes it the 1 V loop
injection and leaves every other stamp alone; no augmentation, no second
source across the same node pair. Return ratio, ngspice's orientation:
$T(\omega) = -V(+)/V(-)$, with `+` the side where the signal arrives.

This is exact where the probe point is a good voltage-transfer break
(low source impedance driving high load impedance: output of an op-amp /
controlled source, the usual `.stb` probe discipline) and inherits the
single-injection caveat otherwise. Tian's two-analysis combination is the
documented upgrade (it costs exactly one more solve per frequency on the
same factorization). The result is the complex $T(f)$ column; margins are
not computed (nothing in the raw output carries them).

## 2. Flow explanation

`src/analysis/ac/stb.zig`:

1. Linearize at the job's operating point (`linearizeAc`), the same
   `FreqSolver.fromCircuit` the `.ac` sweep uses.
2. One shared rhs: unit injection on the probe's branch row.
3. `ac/freq.zig` `Stream`: 64-frequency lane chunks of
   `FreqSolver.solveBatch`; each point gives $T = -V(+)/V(-)$.

Knobs: probe node pair and branch, sweep.

## 3. Pseudo-code, CPU sequential

```
stb(ckt, x_op, probe_p, probe_n, probe_branch):
    linearize(x_op)
    fs = FreqSolver(G, C)
    rhs = e[probe_branch]
    for f in sweep (64-lane chunks):
        x = fs.solve(omega(f), rhs)
        T(f) = -x[probe_p] / x[probe_n]        # complex, stacked-real x
```

## 4. Parallel design notes (not implemented)

Identical shape to AC: frequency points are independent lanes; the Tian
upgrade adds a second RHS per lane (multiple-RHS on one factorization).

```
kernel stb(lanes = freq points):
    per lane: fill values(omega); factor/GMRES; solve e[b] (+ e_i for Tian)
    T[lane] = combine(responses)
```

## Solvers used

| Phase | Solver doc | Impl |
|---|---|---|
| Upstream DC | [homotopy-continuation.md](../solvers/homotopy-continuation.md), [newton-raphson-convergence.md](../solvers/newton-raphson-convergence.md) | the job's shared operating point (`dc/op.zig`) |
| Stacked-real sweep | [klu-pipeline.md](../solvers/klu-pipeline.md) | `src/solver/freq_solve.zig fromCircuit` + `solveBatch`, streamed by `src/analysis/ac/freq.zig` |

---

**Sources fetched**

| Source | Status |
|---|---|
| Tian, Visvanathan, Hantgan, Kundert, "Striving for small-signal stability", IEEE Circuits & Devices 17(1) 2001 (kenkundert.com/docs/cd2001-01.pdf) | **fetched, verified**: return ratio definition, Middlebrook null double injection, $T = T_v^n T_i^n/(T_v^n + T_i^n)$, margin definitions |
| Middlebrook 1975 original | **paywalled: covered via the fetched Tian review** |

**Per-section verification**

- §1 return ratio/margins/Middlebrook formula: verified against the
  fetched paper. Tian bidirectional details: paper fetched, combination
  described at review level (full four-response algebra not transcribed).
- §1 our single-injection probe + its validity condition: verified against
  `stb.zig` source; honestly flagged as not-yet-Tian.
- §2/§3: transcribed from `stb.zig`. §4: design notes.

**Our implementation**

- `src/analysis/ac/stb.zig`: probe and sweep through `freq.Stream`,
  publishing (`frequency`, `loop_gain`). Margin extraction was deleted
  (commit `9761a98`) because nothing in the raw output carries it.
- Fixtures: `tests/fixtures/stb/`.
