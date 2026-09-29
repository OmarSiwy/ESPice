# Optimization: HSPICE `OPTIMIZE=`

HSPICE fits `.param` values to `.meas` goals with a bounded
Levenberg-Marquardt search [SA Ch.27; CR .MODEL (Optimization)]. This page
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
| `.model mod OPT` keys | ITROPT (20), RELIN (1e-3), RELOUT (1e-3), CLOSE (1), CUT (2), DIFSIZ (1e-3), PARMIN (0.1), GRAD (1e-6), MAX (6e5), LEVEL=1, METHOD=LM; CENDIF is read and ignored |

The optimized card, and every analysis card after it, run once more at
the optimum. Their plots carry the label ` (optimize=NAME)`; cards before
it run at the initial values. `.meas` then prints over those final runs.

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
`--jobs`. They do not use the structural lanes of `sweep/lanes.zig`.
Those lanes solve one operating point per lane and publish its probes.
A RESULTS card needs the card's own result, such as a DC sweep, an AC
sweep or a transient, so each point has to be a full query. The output
is the same at any `--jobs` count: every point is its own query on its
own row, and the solver reads the residuals in point order.

When the optimization ends, the optimum's writes fill the rows that the
optimized card and the cards after it run. The optimization runs once,
before the first query advances (`run_all`, `advance`, `advance_ready`).

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

## 6. Not supported

Each of these is refused with `UnsupportedCard` or `ParseError`, never
run another way:

- `METHOD=BISECTION`, `METHOD=PASSFAIL` and `.meas ... pushout=`.
- `LEVEL` other than 1, and `.model OPT` keys not listed in §1.
- More than one `OPTIMIZE=` card in a deck, and `OPTIMIZE=` together with
  `.step`, `.alter` or another card's `SWEEP` (`.dc DATA=d OPTIMIZE=` fits
  to a table and is not read).
- A RESULTS name that is not a `.meas` card of the optimizing card's
  analysis with `GOAL=`.
- A value that changes the topology (for example, one that crosses zero
  and collapses a node) at an optimizer point.
- `GOAL` inequalities (`GOAL=>v`, `GOAL=<v`).
- A `.model` card that reads an optimized parameter, as for `.step`
  (variants.md §4): models are read before the analysis cards that make
  the parameter live.

## 7. Verification

- `core/lm.zig` unit tests: a divider solved to its exact resistance,
  Rosenbrock's valley (two parameters, optimum (1, 1)) and an unreachable
  goal held on its limit.
- Fixtures, all analytic (`tests/fixtures/optimize/`): `divider_goal`
  (rx = 2k/3 to 1e-5), `rc_delay_fit` (R = 1 µs / (1 nF ln 2) through
  OPTRANGE on a transient), `two_param_ladder` (two parameters, two goals,
  unique solution 2k/2k), `unreachable_goal` (rx held at 10k).
  `invalid/optimize_bisection` asserts the METHOD=BISECTION refusal.
- The output with `--jobs=4` is byte-identical to `--jobs=1` on
  `two_param_ladder` and `rc_delay_fit`.
