# Loop-Gain Stability (STB)

Middlebrook and Tian loop-gain probes; return ratio, gain/phase margins.
`.stb` is a single voltage injection; `.lstb` is Tian's double injection
(VACASK `acstb`) with differential and common modes and margins.

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
single-injection caveat otherwise. The result is the complex $T(f)$
column; `.stb` computes no margins.

### `.lstb`: double injection and margins

`.lstb mode=single|diff|comm vsource=v1[,v2] [localgnd=n]` (HSPICE
[CR .LSTB]; `localgnd` is VACASK's) runs
VACASK's `acstb` algorithm (`lib/coreacstb.cpp`), read from its source.
The probe orientation is HSPICE's and VACASK's, the reverse of `.stb`:
`+` faces the loop's input (drv), `−` its output (fbk). At every
frequency two right-hand sides share one lane factorization:

- **current injection**: 1 A into the probe's `+` node from the local
  ground, the probe still a short. Probe current $A$, `+` node voltage $C$;
- **voltage injection**: 1 V on the probe's branch row. Probe current $B$,
  `+` node voltage $D$.

Both voltages are read against the local ground: `localgnd=n`, ground
when the card has none. A loop that reaches ground only through an
impedance (`stb/lstb_localgnd`, lifted on a 1 kΩ) keeps its own
y-parameters this way; from ground, $y_{21}$ and $y_{22}$ would see the
impedance. The loop gain is the same either way for that deck.

With $\Delta = AD - BC$ the DUT y-parameters and the loop gains are

$$
y_{11} = \frac{1+\Delta-A-D}{C},\;
y_{12} = \frac{D-\Delta}{C},\;
y_{21} = \frac{A-\Delta}{C},\;
y_{22} = \frac{\Delta}{C},
$$

$$
W_f = \frac{A-\Delta}{1+2\Delta-A-D},\quad
W_r = \frac{D-\Delta}{1+2\Delta-A-D},\quad
W = W_f + W_r .
$$

$W = N/(1-N)$ with $N = A + D - 2\Delta$, the form of Tian's loop gain
$T = -1/(1 - 1/(2(AD-BC)+A+D))$ with VACASK's signs for the four
responses. So VACASK's method is Tian's double injection, written as a
two-port so the forward and reverse parts come apart; we reproduce it.
$W$ is exact for a bilateral loop and any loading on either side of the
break (`stb/lstb_loaded_break` checks it against the return ratio of the
loop's transconductor, where a single voltage injection is off).

`diff` and `comm` drive the pair $\pm 1$ or $+1/+1$ in both right-hand
sides and read each response as the weighted mean
$(r_1 \mp r_2)/2$: the half circuit of a symmetric pair, so the same
formulas apply to the differential or common-mode loop.

The frequencies are the `.lstb` card's own `dec|oct|lin N f1 f2` when
it has one, else the deck's `.ac` sweep (HSPICE's rule). Each card
publishes two plots:

| Plot | Columns |
|---|---|
| `Loop Stability Analysis` (complex) | `frequency`, `loop_gain` ($W$), `loop_gain_forward`, `loop_gain_reverse`, `y11`, `y12`, `y21`, `y22` |
| `Loop Stability Margins` (one real row) | `gain_margin` (dB), `phase_crossover_freq` (Hz), `phase_margin` (deg), `unity_gain_freq` (Hz), `loop_gain_minifreq` (dB) |

The margins are HSPICE's listing scalars [CR .MEASURE LSTB] plus the
frequency the gain margin is read at. The first sweep interval where
$|W|$ crosses 1 (or where $W$ crosses the negative real axis) brackets
the crossing, and Illinois regula falsi refines it on the circuit itself,
one single-lane `solveBatch` per step, to a relative frequency width of
$10^{-13}$. The margins therefore do not depend on the grid, where
HSPICE's and a `.measure ... when lstb(db)=0` interpolate between points.
A crossing the sweep never brackets leaves its pair NaN, with a warning
on stderr.

Divergences, recorded:

- VACASK's `acstb` is newer than the pinned VACASK binary
  (unstable-2026 has `dcxf`/`acxf`/`dcinc` but no `acstb`), so the
  `.lstb` fixtures use analytic oracles.
- HSPICE's `lstb` output keeps a 180° offset convention we cannot check
  without a binary; `loop_gain` here is the return ratio $W$, positive at
  DC for negative feedback, unstable at $W = -1$, the same sign `.stb`
  publishes. $PM = 180° + \angle W$ at $|W| = 1$, $GM = -20\log_{10}|W|$
  where $\angle W = -180°$.
- The y-parameters divide by $C$: a probe whose `+` node is an ideal
  source (an E output) makes them infinite, as in VACASK. $W$ stays finite.

`.measure lstb` [CR .MEASURE] reads these plots. The margin keywords are
measures on their own (`.measure lstb pm phase_margin`, likewise
`gain_margin`, `unity_gain_freq`, `phase_crossover_freq`,
`loop_gain_minifreq`), read off the margins row. `lstb(db)`, `lstb(m)`,
`lstb(p)` (degrees), `lstb(r)` and `lstb(i)` are `loop_gain` in the
ordinary FIND, WHEN and window forms, interpolated on the sweep:
`.measure lstb f0 when lstb(db)=0` is the grid estimate of the refined
`unity_gain_freq`. This follows the manual's syntax and is unconfirmed
against HSPICE (`hspice/meas_lstb`, analytic).

## 2. Flow explanation

`src/analysis/ac/stb.zig`:

1. Linearize at the job's operating point (`linearizeAc`), the same
   `FreqSolver.fromCircuit` the `.ac` sweep uses.
2. One shared rhs: unit injection on the probe's branch row.
3. `ac/freq.zig` `Stream`: W-frequency lane chunks of
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
  publishing (`frequency`, `loop_gain`).
- `src/analysis/ac/lstb.zig`: `.lstb`, two right-hand sides per lane
  factorization through `freq.Stream`; the margins plot (its own query,
  fanned out by `frontend/analyses.zig` like `.noise`'s integrated plot)
  refines each crossing with single-lane `solveBatch` calls.
- Fixtures: `tests/fixtures/stb/` (`lstb_three_pole`, `lstb_diff_comm`,
  `lstb_loaded_break` and `lstb_localgnd` for `.lstb`, analytic).
