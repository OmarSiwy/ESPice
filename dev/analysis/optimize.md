# Optimization: HSPICE `OPTIMIZE=`

HSPICE fits `.param` values to `.meas` goals with a bounded
Levenberg-Marquardt search [SA Ch.27; CR .MODEL (Optimization)], or
bisects one parameter for the value where a `.meas` turns from fail to
pass [SA Ch.19 "Timing Analysis Using Bisection"]. This page
covers what ESPice reads, how a point is evaluated, the choices that are
ours, and what is not supported (hspice-comparison C8).

## 1. What a deck can say

```
.param rx=opt1(1k, 100, 10k)          $ init, lower limit, upper limit[, dels]
.param rv=optrange(1k, 100, 10k)      $ joins whichever optimization the deck runs
.model optmod opt itropt=30 relin=1e-4
.dc v1 0 5 1 sweep optimize=opt1 results=vout,iout model=optmod
.meas dc vout find v(out) at=5 goal=2 weight=1 minval=1e-12
```

| Form | Meaning |
|---|---|
| `.param p = NAME(init, lo, hi[, dels])` | p is optimized by the card whose `OPTIMIZE=NAME`; `dels` is its finite-difference step |
| `.param p = OPTRANGE(init, lo, hi[, dels])` | the same, for the deck's one optimization whatever its name |
| `<card> ... SWEEP OPTIMIZE=NAME RESULTS=m1,m2 MODEL=mod` | any analysis card (`.dc`, `.ac`, `.tran`, ...) fits the parameters to the RESULTS cards |
| `.meas ... GOAL=g [WEIGHT=w] [MINVAL=v]` | the card's error is `w (result - g) / max(|g|, v)`; MINVAL defaults to 1e-12 |
| `.meas ... GOAL < g`, `GOAL > g` [SA Ch.27 "Optimization Statements"] | an inequality: no error while the result is on that side of g, the equality error otherwise (`GOAL=<g` and `GOAL=>g` read the same) |
| `.model mod OPT` keys | ITROPT (20), RELIN (1e-3), RELOUT (1e-3), CLOSE (1), CUT (2), DIFSIZ (1e-3), PARMIN (0.1), GRAD (1e-6), MAX (6e5), ABSIN, ABSOUT; CENDIF and DYNACC are read and ignored |
| `METHOD=LM\|BISECTION\|PASSFAIL`, `LEVEL=1\|2\|3` [CR .MODEL] | the search: Levenberg-Marquardt (LEVEL 1, the default), bisection (2) or pass/fail (3); METHOD wins over LEVEL |
| `RESULT=` | read as `RESULTS=`, as the manual's bisection example writes it [SA Ch.19] |
| `.step` with `OPTIMIZE=` | one optimization per step point, each from that point's values |

The optimized card, and every analysis card after it, run once more at
the optimum. Their plots carry the label ` (optimize=NAME)`, plus the step
point's label under `.step` (` (optimize=opt1, rt=1000)`); cards before
it run at the initial values, once per step point. `.meas` then prints
over those final runs.

## 2. The algorithm

`core/lm.zig` holds the solver, which knows nothing about circuits. It
hands out the points it needs (`Lm.points`) and takes back their residual
vectors (`Lm.feed`), one per RESULTS card, so the caller decides how the
points run.

1. Residuals at x. The Jacobian by forward differences: parameter j
   steps by `dels` when given, else `DIFSIZ * max(|x_j|, PARMIN)`, and
   steps backward when forward would leave the box.
2. A parameter on a limit whose gradient points outward is held fixed.
   The rest solve `(JᵀJ + λ diag(JᵀJ)) δ = -Jᵀr` (Cholesky), and the
   trial point is `x + δ` clamped into the box.
3. If the residual sum of squares drops, the step is accepted and λ is
   divided by CUT. Otherwise λ is multiplied by CUT and the step is solved
   again from the same Jacobian. λ starts at CLOSE.
4. Stop on the first of: every parameter moved less than RELIN relative
   to `max(|x|, PARMIN)`; the sum of squares dropped by less than RELOUT
   relative, or reached zero; the scaled gradient norm is below GRAD; λ
   passed MAX; ITROPT iterations.

### Bisection and pass/fail

`core/bisect.zig` holds the search, with the same `points`/`feed`
contract as `Lm`. It searches one parameter between its limits; the
initial value is ignored [SA Ch.19].

1. Both limits are tested in one batch. A BISECTION test passes when the
   RESULTS card's goal error is positive (measure above GOAL, the
   manual's "measured value - goal > 0"); a PASSFAIL test passes when the
   card has a value at all. If both limits pass or both fail, the search
   stops: they do not bracket the target.
2. Each iteration tests the window's midpoint and moves the limit on its
   side. The result is the last passing value.
3. Stop when the window is at most ABSIN wide, when given (ABSIN
   overrides RELIN, RELOUT and ITROPT [CR .MODEL]); otherwise when it is
   at most RELIN times the initial window and, for BISECTION, the last
   goal error is below RELOUT (or the error in measure units below
   ABSOUT); or after ITROPT iterations. A BISECTION test that cannot be
   simulated or measured stops the search as failed; under PASSFAIL that
   is a fail.

## 3. How a point is evaluated

Each point is a set of values for the optimized parameters. It is not
parsed again. The parameters are registered as live names when the card
is read, exactly like a `.step` target (variants.md §2). `frontend.Tuner`
sets their values, runs the point through `Planner.add` and gets back a
`core.Variants` row of `ParamRef` writes. After one probe build, a point
costs no rebind; the probe-mapped fast path writes slot values straight
to parameters.

The facade (`Problem.optimize`, in `src/espice.zig`) turns each batch of
points (the n finite-difference points of a Jacobian, or one trial point)
into one session. It copies the optimized card's queries once per point,
each on its own row, and runs them `--jobs` at a time. Then it evaluates
the RESULTS cards over each point's results (`output.measureValues`). A
query that fails, or a card whose event never happens, gives a NaN
residual. The solver treats a NaN trial as a failed step and a NaN in
the Jacobian as a failed optimization.

The Jacobian's points are independent, so they run in parallel under
`--jobs`. Under `--jobs` above 1 the solver also batches (`Lm.batch`):
the start point and every trial point go out with the n Jacobian points
around them, so an accepted trial costs one round instead of two. A
rejected trial's Jacobian points are thrown away and not counted, so the
path, the evaluation counts and the printed summary are the same as with
`--jobs=1`; the price is the CPU spent on those discarded points.

Measured (ReleaseFast CPU build, hyperfine, `--jobs=3`, two parameters):
a 128-stage MOS1 chain with two delay goals (21 evaluations, 5 of 10
trials accepted) takes 12 rounds instead of 17, 1.81 s to 1.71 s wall for
1.71x the CPU; `optimize/rc_delay_fit` 13.9 ms to 10.1 ms. The wall gain
is below the round count's because a round waits for its slowest point:
transient points of this fit take 2416 to 4494 Newton iterations, and
three concurrent queries each run about 1.35x slower than one alone. At `--jobs=1` nothing changes.

### Warm starts

A Levenberg-Marquardt point's operating point starts from the one of
the iterate its step left (`Deck.op_guess`, `op.Options.warm_start`)
instead of the cold MODEINITJCT start. Each trial point and its
Jacobian points take the operating point of the accepted iterate they
step from; the start point and its Jacobian points start cold. The
Jacobian points of an accepted trial do not take the trial's own
operating point: under batching they run in the trial's round, before
it exists, and this rule keeps `--jobs=1` on the same path. The guess
is the facade's row 0 operating point of the round that accepted the
iterate (`Session.operatingPoint`). Bisection points start cold.

A warm Newton converges to the same solution within the Newton
tolerances, so the change in output is intentional and at most at that
level. Measured: no byte of the printed summary or the raw file moved on
any `tests/conformance/tests/netlist/optimize/` deck, a 32-stage MOS1 chain delay fit or
a two-parameter common-source DC fit, at `--jobs=1` and 3. Callgrind
(ReleaseFast, `-Dcpu=x86_64_v3`, `--jobs=1`): the 32-stage chain fit
4.257e9 to 4.104e9 instructions (-3.6%), the common-source DC fit
1.0651e8 to 1.0617e8 (-0.3%: its operating point is a few iterations
of a four-device circuit, and the sweep dominates).

### Direct sensitivities

When every query of the optimized card is a `.dc` sweep or a transient
(below), the Jacobian
comes from the trial point's own sweep instead of n more sweeps. The
solver always batches then, and the facade runs only row 0, with the n
Jacobian rows as `Dc.tangents`. At each converged sweep point `dc.zig`
evaluates F(x) on a full stamp (the baseline would hold the resistors at
their nominal values, as in `sens.zig`), factors J at x, and for each
row writes its parameter values, re-derives only the device types they
touch, evaluates F(x, row), restores the values and solves
dx = -J⁻¹ (F(x, row) - F(x)). The row's block of the result holds the
probes at x + dx: the first-order prediction of that row's sweep. The
facade measures each block as it would measure the row's own result, so
the RESULTS cards, `Lm` and its forward difference stay as they are; the
Jacobian becomes the derivative at x rather than a secant over DIFSIZ.
The perturbation of F is the same parameter step the finite difference
takes, so no new step size appears. A singular J, or a row that would
re-wire a device, gives NaN probes, which the solver reads as a failed
Jacobian.

The grid polish points (#95) are not a Jacobian, so they run as full
sweeps. The printed evaluation count still counts each Jacobian point, though it
costs a few evaluations and one back substitution per sweep point
instead of a sweep. AC goals keep the finite-difference points.

Measured (callgrind, ReleaseFast, `-Dcpu=x86_64_v3`, `--jobs=1`): a
two-parameter common-source DC fit (two goals on a 181-point sweep)
1.0617e8 to 4.229e7 instructions, 2.5x fewer, in 7 iterations and 22
evaluations instead of 16 and 60; the finite-difference Jacobian's
noise had cost it six rejected-step iterations near the optimum. Its
optimum moves along the fit's valley of equal goal errors (W 4.4536u to
4.4709u, R 11.227k to 11.183k, both goal errors below 3e-7): the two
goals do not fix W and R apart. On every `.dc` deck of
`tests/conformance/tests/netlist/optimize/` the printed optimum, stop reason and
evaluation count are unchanged; the per-iteration table moves in its
fourth digit on the first steps.

A transient goal takes the same route (`Tran.tangents`): each row's
block is its first-order trajectory on the trial point's own time grid,
integrated alongside it. At the operating point and at every accepted
step, `tran.zig` evaluates the step's residual R at the base solution x
(the companion's dynamic current over the base's charge history, under
the device state the step's Newton solved with), factors A = G + ag0·C
at x (G alone at the operating point), and for each row evaluates
R(x, row) with the row's parameter values, charge history and dynamic
current, and solves dx = -A⁻¹ (R(x, row) - R(x)). The row's point is
x + dx; its charge q(x + dx), dynamic current and device state (Meyer
`$prev`, delay lines) are committed as the base commits its own, so the
row carries its own history to the next step. Each row keeps its device
state, parameter values included, as a `Circuit.SavedState` swapped in
for its turn, so a row costs two device evaluations, a charge
evaluation, a back substitution and two state copies per accepted step,
and the base run one more evaluation and factorization; rejected steps
cost the rows nothing. The tangent is taken on the base's grid, so the
measured Jacobian has no time-grid noise, which the finite difference
of two separately stepped transients does have.

The base matrix A stands in for the row's own, so the prediction's error
is second order in the parameter step: on an RC driven by a sine, a
1e-3 step in C is off by up to 3.4% of its move and a step in R by
0.07%, a 1e-6 step a thousand times less (`src/analysis/tests/sweep.zig`
checks a 1e-4 step to 1%). The rows need an operating point the transient
solves on its own and host device state, so the facade keeps the
finite-difference points for `uic`, `.ic` holds, a capacitor-only node
(OPtran), VPI callbacks and a GPU backend (`Problem.tangentable`).
`ZP_NO_TANGENTS` forces the finite-difference points everywhere, for
A/B runs.

Measured (ReleaseFast, `-Dcpu=x86_64_v3`, `--jobs=1`, against
`ZP_NO_TANGENTS=1` on the same binary), MOS1 inverter chains (Meyer caps,
20 fF loads) fitting NMOS and PMOS W to the rise and fall delays the
chain has at 8u/14u, `parmin=1e-12`:

| Deck | Jacobian | Iter / evals | Final RSS | Callgrind Ir | Wall (hyperfine) |
|---|---|---|---|---|---|
| 32 stages | finite difference | 8 / 38 | 3.9e-5 | 7.43e9 | 1.050 s |
| 32 stages | tangents | 10 / 31 | 7.4e-11 | 4.98e9 | 0.686 s |
| 128 stages | finite difference | 6 / 19 | 6.3e-6 | | 2.94 s |
| 128 stages | tangents | 11 / 50 | 2.4e-8 | | 8.36 s |
| `rc_delay_fit` | finite difference | 7 / 15 | 9.2e-16 | | 15.8 ms |
| `rc_delay_fit` | tangents | 7 / 15 | 8.4e-16 | | 18.8 ms |

A round of the trial point with its two tangent rows costs 2.3
transients on the 32-stage chain (4.5e8 Ir against 1.96e8 per
finite-difference transient), not three. The larger gain is the path:
the finite difference of two separately stepped transients carries
time-grid noise that stalls both chain fits in RELIN at goal errors of
1e-3 to 5e-3, while the tangent fits reach the generating widths (32
stages: W 7.9997u/14.001u, goal errors under 1e-5). The 128-stage fit
therefore runs longer, to a 270x lower RSS. A three-device RC is
slower: the per-step state copies and the extra factorization outweigh
the one transient they replace. `rc_delay_fit` keeps its optimum
(1.442693e3) and evaluation count; every `.dc` deck of
`tests/conformance/tests/netlist/optimize/` is byte-identical, and every deck gives the
same bytes at `--jobs=1` and 3.

The points do not use the structural lanes of `sweep/lanes.zig`.
Those lanes solve one operating point per lane and publish its probes.
A RESULTS card needs the card's own result, such as a DC sweep, an AC
sweep or a transient, so each point has to be a full query. The output
is the same at any `--jobs` count: every point is its own query on its
own row, and the solver reads the residuals in point order.

When the optimization ends, the optimum's writes fill the rows that the
optimized card and the cards after it run. The optimization runs once,
before the first query advances (`run_all`, `advance`, `advance_ready`).

Under `.step` the planner (`Planner.planOptimize`) lays out S step
points as three blocks of S rows: the optimized card's, the later cards',
and the earlier cards' (at the initial values). The facade runs one
optimization per step point in turn, each over rows on top of that
point's writes (`Tuner.rows(..., base)`), and the optimum of point k
fills row k of the first two blocks.

## 4. Output

`print_measures` prints the summary ahead of the `.meas` lines:

```
  Optimization opt1 (Levenberg-Marquardt, model optmod)

  iter  evals  residual sum of squares  marquardt param              rx
     0      1              6.250000e-2       1.000000e0      1.000000e3
     ...
     6     13             1.284073e-12      1.562500e-2      6.666679e2

  optimization completed: RELIN = 1e-3 on last iteration
  residual sum of squares       = 1.284073e-12
  norm of the gradient          = 4.547112e-5
  marquardt scaling parameter   = 1.562500e-2
  no. of function evaluations   = 13
  no. of iterations             = 6

  optimized parameters opt1 -- final values
  rx = 6.666679e2 $ initial 1.000000e3, range 1.000000e2 to 1.000000e4

  goal errors at the optimum (weight * (result - goal) / max(|goal|, minval))
  error(vout) = 1.133169e-6
```

A bisection prints one line per midpoint test (the window it halved, the
value and its goal error), the stop reason, the evaluation and iteration
counts, and `rx = <value> $ last passing value, range <lo> to <hi>`.
Under `.step`, each summary's title ends with ` at <step label>`.

A goal outside the ranges ends with `optimization stopped at a limit: the
goals are not reachable inside the parameter ranges` and a
`<name> is held at its upper limit <value>` line per parameter held on a
limit.

## 5. Choices that are ours

These are not checked against an HSPICE run.

- **The summary layout** follows the figures HSPICE's listing reports
  (residual sum of squares, gradient norm, Marquardt parameter,
  evaluations, iterations, final values). The per-iteration table, the
  limit status lines and the goal-error lines are ours.
- **GRAD** is tested against the gradient of the residual sum of squares
  with component j scaled by `max(|x_j|, PARMIN)`, so the test does not
  depend on the parameters' units. The manual says only "the gradient of
  the RESULTS function".
- **Convergence** is the first criterion met. The manual lists RELIN,
  RELOUT and GRAD as separate tests and does not say how they combine.
- **Later cards run at the optimum**, following HSPICE's examples, which
  add a plain analysis card after the optimizing one for the final run.
  The optimizing card also publishes its own run at the optimum.
- **OPTRANGE** parameters join the deck's one optimization.
- **Inequality goals**: the manual gives the syntax, `GOAL = | < | > val`
  with a space around the operator (E-2010.12 p. 873; the operator glyphs
  are missing from that PDF), and says to use it when some criteria
  matter less than others. It does not give the error of a violated
  inequality; ours is the equality error, so a violated card pulls like
  `GOAL=`.
- **`.step` with OPTIMIZE** runs one independent optimization per step
  point. The manual does not describe the combination.
- **Bisection reports the last passing value** and its goal error. The
  RELOUT test reads the goal error, which is relative to max(|GOAL|,
  MINVAL); ABSOUT reads the same error in measure units.
- **The grid** (`name(init, lo, hi, dels, grid)`, #95) is an ESPice
  extension for W and L on a manufacturing grid. Every simulated point is
  on each parameter's own grid. LM rounds the Jacobian step up to whole
  grid steps and each trial onto the grid, so a step under half a grid step
  rounds back onto `x` and ends the run as RELIN; then it tries x ± one grid
  step one parameter at a time, keeping each improvement (`Lm.polish_j`).
  Bisection halves the window in grid indices and stops at one step.
- **A trial point that cannot be evaluated fails the run** (#29), with the
  best point so far as the result, as `Status` documents. Retrying it with
  a larger Marquardt parameter was the alternative.
- **PARMIN keeps HSPICE's default 0.1**, which sizes the first
  finite-difference step of an SI-unit width or current far too large; the
  docs tell sizing decks to lower it (#96).

## 6. Not supported

Each of these is refused with `UnsupportedCard` or `ParseError`, never
run another way:

- `.meas ... pushout=`.
- A bisection over more than one parameter or RESULTS card: the manual
  does not say how several bisected parameters combine. A bisection on a
  `GOAL <`/`GOAL >` card, whose error is zero on both sides of a pass.
- `LEVEL` other than 1 to 3, and `.model OPT` keys not listed in §1.
- More than one `OPTIMIZE=` card in a deck, and `OPTIMIZE=` together with
  `.alter` or another card's `SWEEP` (`.dc DATA=d OPTIMIZE=` fits to a
  table and is not read). A `.step` point that changes the topology.
- A RESULTS name that is not a `.meas` card of the optimizing card's
  analysis with `GOAL=`.
- A value that changes the topology (for example, one that crosses zero
  and collapses a node) at an optimizer point.
- A `.model` card that reads an optimized parameter, as for `.step`
  (variants.md §4): models are read before the analysis cards that make
  the parameter live.

## 7. Verification

- `core/lm.zig` unit tests: a divider solved to its exact resistance,
  Rosenbrock's valley (two parameters, optimum (1, 1)) and an unreachable
  goal held on its limit.
- Fixtures, all analytic (`tests/conformance/tests/netlist/optimize/`): `divider_goal`
  (rx = 2k/3 to 1e-5), `rc_delay_fit` (R = 1 µs / (1 nF ln 2) through
  OPTRANGE on a transient), `two_param_ladder` (two parameters, two goals,
  unique solution 2k/2k), `unreachable_goal` (rx held at 10k).
  `inequality_goals` (one satisfied and one violated inequality: v =
  30/13 V), `step_optimize` (one fit per step point, rx = 2 rt / 3, checked
  through the later `.op` at each optimum), `bisection_divider` (rx =
  2k/3), `bisection_rc_max` (R = 1 µs / (1 nF ln 2) through MAX on a
  transient) and `passfail_level3` (LEVEL=3 on whether a WHEN finds its
  crossing). `invalid/optimize_bisection` asserts the refusal of a
  two-parameter bisection.
- `core/bisect.zig` unit tests: a divider bisected from its passing side,
  and pass/fail with a non-bracketing pair of limits.
- `src/analysis/tests/sweep.zig`: the `.dc` tangent blocks against the
  closed-form first-order prediction, and the `.tran` tangent blocks
  against a transient rerun at each row on the same grid.
- The output with `--jobs=4` is byte-identical to `--jobs=1` on
  `two_param_ladder` and `rc_delay_fit`.
