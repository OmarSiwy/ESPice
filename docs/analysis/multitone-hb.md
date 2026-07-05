# Multi-tone harmonic balance

`.hb TONES=f1 f2 ... [NHARMS=h1 h2 ...] [INTMODMAX=n]` [CR .HB] solves the
steady state under any number of tones (`src/analysis/pss/mhb.zig`). A
single-tone `.hb f0 K` keeps the dense solver in `hb.zig` until the circuit
is large enough for the Krylov path to pay (see [Crossover](#crossover)).

## Card options

`.hb TONES= ... [SUBHARMS=s] [SS_TONE=i] [SWEEP ...]`:

- SUBHARMS=s puts the lowest tone f's lines at multiples of f/s, up to its
  NHARMS·f. In the INTMODMAX order s steps of f/s count as one, so the
  subharmonics do not crowd out the other tones' products. The manual only
  says the lowest non-DC line is f/s; the order rule is ours. Oracles
  `hb/subharms_cubic` and `hb/subharms_two_tone_square`.
- SS_TONE=i (from 1) takes tone i out of the large-signal spectrum. It is
  the small-signal tone: `.hbac`, `.hbxf` and `.hbnoise` supply its
  frequency through their own sweep. With one tone left the small-signal
  analyses take the one-tone path (`hbac/ss_tone_multiplier`).
- SWEEP is the generic HSPICE card sweep: the `.hb` card reruns once per
  point, one plot per point (`hb/sweep_two_tone_cubic`).

## Spectrum

A line is a mixing product k·f = k1·f1 + k2·f2 + ... with |ki| <= Hi. With
INTMODMAX = N the products are also cut to |k1| + |k2| + ... <= N, except
that each tone's own harmonics stay up to its Hi. That is HSPICE's rule and
VACASK's `truncate="hybrid"`:

- box: INTMODMAX >= H1 + H2 + ... keeps the whole box;
- diamond: Hi = INTMODMAX for every tone (NHARMS omitted).

NHARMS defaults every tone to INTMODMAX and INTMODMAX defaults to the
largest NHARMS, so `.hb tones=f1 f2 nharms=2 2` is the order-2 diamond, as
in the manual's example 4. Products whose frequencies agree to 1e-14
relative are one line: the lower order wins, then a single tone's harmonic,
then the earlier product (VACASK `lib/spurs.cpp`). A line is the whole
physical response at its frequency, so commensurate tones lose nothing.
Lines are sorted by frequency, DC first. The unit tests reproduce the
manual's six examples.

Unknowns per node are [dc, c1, s1, ..., c(m-1), s(m-1)] with
x(t) = dc + Σ cj·cos(ωj t) + sj·sin(ωj t), the layout `hb.zig` uses, so one
tone is lines 0..K.

## Transform

One tone samples one period 2x oversampled, as `hb.zig` does, and projects
with the Galerkin weights, so both solvers share a fixed point.

Several tones have no common period. The solver picks 2m-1 collocation
instants from a pool of 5·(2m-1) uniform points, greedily keeping the row
farthest from the span of the rows already kept (modified Gram-Schmidt),
then inverts that square transform once per analysis (the APFT; Kundert,
White and Sangiovanni-Vincentelli 1990, App. B; VACASK
`lib/corehbcoloc.cpp`). Each tone's phase is reduced to [0, 1) cycles with
an fma-recovered product before the lines combine it, so late instants keep
their phase.

Divergence from VACASK: the pool spans 1/(closest line spacing), not one
period of the lowest line. Two lines Δf apart only separate over a window
near 1/Δf. On tones 1 kHz and 1.3 kHz at order 5 the lines sit every
100 Hz but the lowest is 300 Hz, and VACASK's window left our transform
singular (inverse error 3.9, entries of 4e11). The wider window gives an
inverse error of 1e-15 on the same spectrum.

## Newton step

Each Newton step solves J·dx = -F by GMRES (restart 40, relative tolerance
1e-7). J is never formed: a product is IDFT, G(t) and C(t) at every sample
(`qpss.gvProduct`), and two DFTs, the charge one scaled by ω per line. This
is VACASK's sparse block Jacobian applied without storing the blocks. C(t)
enters at every sample, so nonlinear charge gets an exact Newton, where
`hb.zig` and `qpss.zig` hold C(t0).

The right preconditioner is block diagonal, one n x n block G0 + jωj·C0 per
line, with G0 and C0 the sample means of G(t) and C(t). The blocks share one
pattern and differ only in ω, so `FreqSolver.factorEach` factors them as
LaneLu frequency lanes once per Newton step and every GMRES iteration
solves all of them with `solveEach`, a different right-hand side per lane.
Line j's (c, s) rows are the phasor X = c - js of (G0 + jωC0)X = r_c - j·r_s.
A lane the shared pivot tape cannot replay has the tape repivoted at its ω,
twice at most, after which it is held as the identity; GMRES stays correct
and only slows down.

G0 is the mean, not the DC line through the collocation inverse: that fit
aliases G(t)'s harmonics past the kept band into DC, and an exponential's
can push it negative. The mean keeps every conductance's sign.

The line search is `hb.zig`'s: a step that raises the residual is halved
from the previous point, and a good one earns the length back.

## Crossover

Callgrind instruction counts (ReleaseFast, `--backend=cpu`), dense `hb.zig`
against the GMRES path on the same deck. Diode-RC ladders: `N` sections of
diode, 10 nF and 100 Ω, driven at 1 kHz with 1 V.

| Deck | n | K | dense Ir | GMRES Ir | ratio |
|---|---|---|---|---|---|
| hb/diode_clipper | 4 | 32 | 85.5M | 105.0M | 0.81 |
| hb/diode_rectifier_rc | 6 | 32 | 381.1M | 500.9M | 0.76 |
| hb/rc (and the other 17-coefficient RCs) | 4 | 8 | 1.57M | 1.34M | 1.17 |
| ladder N=1 | 5 | 32 | 151.8M | 82.5M | 1.84 |
| ladder N=5 | 9 | 8 | 21.4M | 16.1M | 1.32 |
| ladder N=5 | 9 | 32 | 687.9M | 189.0M | 3.64 |
| ladder N=10 | 14 | 8 | 61.9M | 28.7M | 2.16 |
| ladder N=20 | 24 | 8 | 221.1M | 41.0M | 5.39 |
| ladder N=40 | 44 | 8 | 1170.4M | 72.7M | 16.1 |

Wall time at N=80 (n = 84, K = 8): 1.73 s dense, 0.030 s GMRES. The two
paths agree to 2e-11 V on every ladder.

The dense step is O((n·nf)³) and the Krylov step O(iterations·n·nf²), so n
decides; strongly nonlinear small circuits (the clipper and rectifier) need
more GMRES iterations and stay cheaper dense. `hb.useGmres` takes the
Krylov path at n >= 10 or n·nf >= 512. Every hb deck in the corpus stays
below that, so their outputs are unchanged. Autonomous solves (`.hbosc`)
stay dense: the f0 column and the `ppv` adjoint are written for the dense
Jacobian.

## Conversion matrix

The periodic small-signal sweep behind `.pac`, `.pxf`, `.pnoise`, `.hbac`,
`.hbxf` and `.hbnoise` (`pac.sweep`) solves the same way past
`pac.useKrylov`: GMRES (restart 60, relative tolerance 1e-11) on the
conversion matrix applied as the block convolution
Σ_q (G_{p-q} + jω_p·C_{p-q}) x_q, right preconditioned by its block diagonal
G_0 + jω_p·C_0, one `factorEach` lane per sideband per input frequency. The
adjoint sweeps apply A^H and solve the lanes with `solveEach(.., true)`, the
stacked-real transpose. A circuit with frequency-dependent entries (a
transmission line) keeps the dense LU.

Whole-run medians (hyperfine, 15 runs, load average about 16; callgrind
cannot run these decks, the FFT build uses GFNI instructions valgrind does
not decode), `.hbac dec 5 10 100k` on the diode-RC ladders:

| n | 2M+1 | n·(2M+1) | dense | Krylov | ratio |
|---|---|---|---|---|---|
| 5 | 7 | 35 | 4.9 ms | 5.2 ms | 0.94 |
| 7 | 7 | 49 | 7.1 ms | 7.1 ms | 1.00 |
| 10 | 7 | 70 | 11.9 ms | 9.6 ms | 1.25 |
| 5 | 17 | 85 | 17.8 ms | 12.4 ms | 1.44 |
| 14 | 7 | 98 | 20.6 ms | 12.8 ms | 1.61 |
| 9 | 17 | 153 | 53.6 ms | 29.2 ms | 1.84 |
| 24 | 17 | 408 | 632 ms | 61 ms | 10.3 |
| 44 | 17 | 748 | 4.63 s | 0.108 s | 42.8 |

The switch is at n·(2M+1) >= 64. Every PAC-family deck in the corpus is at
60 or below and stays dense. GMRES converges in about 25 iterations; the two
paths agree to 1e-7 of each output's peak (`.hbac`, `.hbxf`) and 1e-12 on
`.hbnoise`.

## Small signal

`.hbac`, `.hbxf` and `.hbnoise` after a multi-tone `.hb` card linearize
about its solution (`src/analysis/pss/mhb_lptv.zig`). A small signal at f
rides every line, so its sidebands are f + f_p over the signed lines p.
The linear system is the conversion matrix over those sidebands,
A(ω)[p][q] = G_{p-q} + j(ω + ω_p)·C_{p-q}, with G_d and C_d the phasors
of G(t) and C(t) on the line at f_p - f_q and zero when that difference
is not a line. With one tone this is `pac.zig`'s conversion matrix.

Divergence, measured: the first version formed A as the HB Jacobian
DFT·diag(G(t_s))·IDFT over the collocation instants. That folds every
product that leaves the spectrum back onto the kept lines, and on
`hbnoise/multitone_multiplier` it gave 3.05x the analytic density at
NHARMS=1 1, still 0.3% off at NHARMS=6 6. The conversion matrix drops
those products instead and matches the closed form at NHARMS=1 1.
Columns are named by mixing product: `tf_h[1,-1]` is the sideband
at f + f1 - f2. `.hbnoise` modulates each source by its amplitude
sqrt(PSD(t)) along the orbit and adds the pairs that land on the same
frequency offset coherently.

Oracles: `hbac/multitone_rc` and `hbxf/multitone_rc` (a linear RC under
two large tones is plain AC on sideband 0), `hbac/multitone_multiplier`
(a multiplier pumped by cos ω1t + cos ω2t puts 1/2 on each tone's
sidebands), `hbnoise/multitone_multiplier` (RC noise folded through the
same multiplier, ¼ Σ [Sx(|f - fLO|) + Sx(f + fLO)]).

`ponytail:` A(ω) is dense, one LU of the stacked-real 2·n·nf system per
frequency. Past a few hundred unknowns the upgrade is `pac.sweepKrylov`'s
GMRES with the G_0 + j(ω + ω_p)·C_0 lane preconditioner.

## QPSS

Multi-tone HB subsumes `.qpss`: `.qpss f1 f2 K1 K2` is
`.hb tones=f1 f2 nharms=K1 K2 intmodmax=K1+K2` with a two-sided output.
`src/tests/analyses.zig` checks that every one-sided HB line equals twice
the QPSS |X_kl| on a square-law mixer over incommensurate tones. `.qpss`
stays as it is for its card and its decks' output. It is the older solver
(unpreconditioned GMRES, C at one sample) and new work should target
`.hb tones=`; retire `.qpss` when a deck needs neither its two-sided
layout nor its card.

## Oracles

- `hb/two_tone_cubic_im3`, `hb/three_tone_cubic`: a cubic B source,
  analytic line values (IM3 at 2f1-f2 is 3A²B/4) to 1e-9.
- `hb/two_tone_box_square`: box truncation over incommensurate tones.
- `hb/two_tone_diode`: a diode under two 20 mV tones against ngspice 45's
  settled transient with `fourier` over the tones' 10 ms common period;
  IM3 agrees to 5e-6 relative.
- `hb/two_tone_diode_vacask`: the same circuit against VACASK's multi-tone
  HB run at reltol=1e-8, vntol=1e-12; IM3 agrees to 7e-6 relative. At
  VACASK's default reltol=1e-3 and vntol=1e-6 its lines move by up to
  6.5e-7 V (0.75% on the 42 µV IM3). Lines of order 6 and 7, below 2e-8 V,
  differ by the aliasing of the two solvers' different collocation instants.
- The two diode oracles hold magnitudes only, so their columns set
  `"magnitude": true` and the harness compares |X|. The analytic decks
  check the full phasors.

## Divergences

- Output of the `TONES=` form, one tone or several, is a complex plot:
  per line the peak phasor X = c - j·s, x(t) = Re{X·e^(jωt)}, with DC
  real. VACASK writes the same phasors. The positional `.hb f0 K` card
  keeps its magnitudes with a signed DC. HSPICE's own `.hb` output
  layout (its `.printhb` forms and the `.hb0` file) has not been checked
  against a real run.
- `.hblin` linearizes about one tone; with a multi-tone `.hb` card it is
  an argument error.
- SUBHARMS and SS_TONE follow the manual's text and have not been run
  against HSPICE (see [Card options](#card-options)).

`ponytail:` the collocation pool is O(nt·pool·nf) greedy selection and the
transforms are dense O(n·nt·nf) products. For many lines (three tones at
order 7 and up) an FFT on the one-tone grid, or a smaller pool factor, is
the upgrade.
