# Nonlinear convergence for a batch-evaluating GPU

**Status: research, nothing implemented.** Written against `main` at
`fa9f0b4`, with measurements from the experimental GPU work at `ee66e0b`
(not on `main`). No build, test or benchmark was run for this page: a
wall-clock benchmark held the machine. Every number marked *measured* comes
from an earlier run recorded in the sources named beside it. Every number
marked *model* is arithmetic on those measurements, and the experiments in
§5 exist to replace it. §9 is the exception: census counts measured at
`52a5903` for the cheap experiments of §7.

Part I (§1-§5) keeps ngspice's iterate sequence and time grid. Part II
(§6-§8) is an opt-in GPU-native mode that keeps only each deck's oracle
tolerance and ngspice-level accuracy, and re-ranks the options under that
contract.

The question: the GPU can evaluate many circuit states per launch (device
evaluation batched over instances, and potentially over several candidate
states at once). Which nonlinear algorithm makes the best use of that? We
would trade more computation per iteration for fewer serial iterations or
fewer host round trips. The suggestion that prompted it was that JFNK suits
a GPU better than Newton.

## Summary

In conformance mode a single solve has exactly one state to evaluate per
iteration. ngspice's NIiter fixes the iterate sequence: the full Newton step,
device `$limit` limiting, x_k published, at least two iterations per solve
(`finalizeStep` refuses iteration 0, as NIconvTest does), and a cap of 100.
The LTE controller fixes the timestep sequence. No algorithm evaluates extra
states to shorten that chain without changing the answer. The extra states a
launch can carry are therefore useful in three ways only:

1. Remove round trips the schedule adds. Today a transient step makes
   about 2I + 4 host syncs for I Newton iterations. About I + 1 are needed.
2. Batch independent problems. Monte Carlo, corners, temperature and DC
   sweep points are separate solves with one pattern. They fill the lanes and
   each lane still runs the conformant Newton.
3. Speculate on retry chains. The serial schedule's next candidates on its
   failure paths are known in advance: dt/8 after a Newton failure, the gmin
   retreat, source-step halving, the later OP rungs. Evaluating them as lanes
   and committing the first one the serial schedule would accept keeps the
   serial result.

Everything that changes the iterate sequence (chord, line search,
Newton-Krylov, parallel in time) can only be an opt-in mode that agrees with
the corpus within tolerance. JFNK comes last among the single-solve methods.
It helps codes that cannot afford to form the Jacobian. We get the Jacobian
from forward AD at little cost, the Arnoldi recurrence makes the matvecs
sequential, and in our host-solve design each finite-difference matvec
would be one more round trip.

| Rank | Option | Verdict (gpu-parallel-algorithm-thinking) | Buys | Result vs today |
|---|---|---|---|---|
| 1 | One sync per Newton iteration (§2.1) | artificial | about half the syncs per step | bitwise identical |
| 2 | Lanes over independent problems (§2.2) | nested-parallel | k solves per launch and per sync | per lane equal to a scalar replay of the same pivot tape |
| 3 | Exact speculation on retry chains, OP rung racing (§2.3) | weakenable | shorter failure chains | serial result; bitwise when pivot tapes match |
| 4 | Chord / stale-LU Newton with a residual-only kernel (§2.4) | weakenable, contract change | fewer factors, smaller downloads | within tolerance; opt-in |
| 5 | Parallel line search (§2.5) | span-win-work-loss | fewer OP ladder entries | within tolerance; opt-in |
| 6 | Assembled-Jacobian Newton-Krylov on the GPU (§2.6) | needs-new-math at our sizes | O(1) syncs per iteration at post-layout scale | within tolerance; opt-in |
| 7 | JFNK, block or s-step GMRES with batched matvecs (§2.7) | movement-bound | nothing here | slower (measured, `converger.zig`) |
| 8 | Parareal, waveform relaxation, MGRIT (§2.8) | needs-new-math | span on long transients | different time grid; not conformant |

A `--solver auto` built from this ranking would enable 2.1 wherever the GPU
path runs, 2.2 for ensemble and sweep queries, and 2.3 only when the lanes
are free (the §5 E2 knee). None of these moves a result beyond pivot-order
rounding, so the corpus agreement question stays the one the GPU path already
has (CPU vs GPU planes). Options 4 to 6 would be named opt-in modes.

The cross-field scan in [gpu-convergence-fields.md](gpu-convergence-fields.md)
confirms this split: chemistry, power flow and SUNDIALS all keep control on
the host and batch independent problems. It adds one opt-in candidate ahead
of chord: nonlinear elimination of instance-private internal nodes inside
the eval launch, which is on-device work with no round trip. It also gives
chord CVODE's lagging triggers as its specification.

## 1. Where an iteration's time goes today

### 1.1 The chain

One transient step on the GPU path (`tran.zig simulate`, `converger.newton`,
`gpu.zig`), for a deck whose resident devices have limit, state-latch and
charge kernels:

```
predictor x = cur + (dt/dt_prev)(cur - prev)
applyLimits(trial, cur)                       sync 1  (lim kernel, 4-byte flags)
repeat I times (I >= 2):
    assemble: evalOnGpu(x)                    sync    (x up, eval, reduce, planes down)
    host: cpu batches, planes add, combineGC, factor/refactor, solve
    finalizeStep: updateAndNorm, applyLimits  sync    (x, x_old up, lim kernel, flags down)
    gates: first-iter, delta, residual, device, updateStates
stateCtl(.query)                              sync    (ctl kernel, flags)
evalQ(trial)                                  sync    (full eval: no charge-only kernel)
LTE (host), accept, commitStates, stateCtl(.commit)   sync
evalQ(cur) when has_state_q                   sync
```

That is 2I + 4 syncs per accepted step (2I + 5 with stateful charge), and
I + 1 or I + 2 full device evaluations. On `main` no corpus deck
runs faster on the GPU (the `default_min_work` comment in `gpu.zig`). The dependency
edges, classified:

| Edge | Class | Removable |
|---|---|---|
| x_{k+1} = x_k + solve(J_k, F_k) → eval(x_{k+1}) | true RAW | no |
| limit(x_{k+1}, x_k) → eval(x_{k+1}) | true RAW, but both on the device | the host hop between them is artificial |
| eval_k → gates_k (F_k, diag J_k, limit flag) | true RAW | no |
| gates → next iteration or publish | control | only by speculation |
| accepted x_n → step n+1 | true RAW | no (parallel in time changes the math, §2.8) |
| LTE(q at x_n) → dt_{n+1} | control | no (conformance) |
| stateCtl(.commit) → next step | ordering only; the result is discarded (`_ =`) | the sync is artificial |
| stateCtl(.query) → evalQ(trial) | both device work at the same x | fusable into one sync |

The longest path is the Newton chain inside each step times the step count.
Both are fixed by the conformance contract, so the verdict for the single
conformant solve is **nested-parallel**: the chain is genuinely sequential,
and the parallel dimensions are the ones around it (instances, independent
problems, speculative candidates).

### 1.2 Measured costs

| Quantity | Value | Source |
|---|---|---|
| Fixed cost per Newton iteration (launches, two syncs, limit pass) | 150 µs | *measured*, `cost_fixed_us`, `gpu.zig` at `ee66e0b` (RTX 4060 Laptop, i9-14900HX) |
| Pinned transfer rate | ~11 GB/s | *measured*, `cost_bus_b_per_us`, same |
| bsim4va eval, 2000 inverters | 1.15 ms GPU vs 7.3 ms one host core | *measured*, `cost_kernel_ratio` comment, same |
| mos1 eval, 2000 inverters | 0.13 ms GPU vs 0.40 ms one host core | *measured*, same |
| bsim4_2000 whole run | 1.98 s GPU warm vs 9.1 s CPU 1 thread | *measured*, GPU status notes for `ee66e0b` |
| bsim3_2000 / mos1_2000 whole run | 0.69 vs 1.29 s / 0.58 vs 0.51 s | *measured*, same |
| psp103, hisimhv per iteration | ~2 vs ~8 ms / 6.3 vs ~33 ms | *measured*, same |
| bsim4 eval kernel | 255 registers, 18.7 KB stack per thread | *measured*, same |
| Cold JIT | bsim4va 14.7 s, psp103 ~35 s, hisimhv ~1070 s | *measured*, same; cached by the driver afterwards |
| Round trip on `main`'s grid decks | ~100 µs per iteration | *measured*, `gpu.zig` doc comments on `main` |
| ABI 5 sparse derivative lanes | bsim4 eval 4.3× faster; GPU hicum 354 → 47 ns | *measured*, VerA ABI 5 plan; design projects bsim4 frame 22.3 KB → ~5.3 KB |

Per-iteration *model* for bsim4_2000: 150 µs fixed + ~50 µs bus + 1150 µs
kernel ≈ 1.35 ms on the GPU against 7.3 ms on one core. That predicts 5.4×; the
whole run measured 4.6× (9.1 / 1.98 s), the gap being host work both paths
share.
Today the kernel is 85% of a GPU iteration, so the sync count barely matters
for bsim4. After ABI 5, if the GPU kernel gains what the CPU does (4.3×), it
drops to ~270 µs. The fixed cost and bus are then about 40% of the iteration.
mos1 is already there: 150 µs fixed against a 130 µs kernel.

Two floors follow:

- **The conformance floor.** A solve takes at least two iterations. The
  cap is 100: `optionsFromTolerances` raises ITL4's 10 to 100 as niiter.c
  does. A failed transient attempt can therefore cost 100 iterations before
  the dt/8 retry, and on the GPU path each is two syncs. Any acceleration of
  a *converging* conformant solve is bounded by I/2, so the per-iteration and
  per-retry costs are where the room is.
- **The occupancy floor.** At 255 registers a thread, an Ada SM holds
  8 warps (256 threads), so the 24-SM RTX 4060 Laptop runs about 6,100
  threads at once. The 4,000 bsim4 instances fill two thirds of one wave. A
  second state per instance needs a second wave, so today k states cost close
  to k times one (*model*). The measured kernel time for more instances per
  launch is what E2 records, before and after ABI 5. ABI 5's register counts
  (bsim4 38 → 9 to 12 per scalar value, per the ABI 5 design) are what could
  open free lanes.

### 1.3 Why "JFNK suits the GPU" does not transfer

Knoll and Keyes' survey (2004) is the source of that intuition. JFNK needs
only residual evaluations, which are data-parallel. It never stores a
Jacobian, and in PDE codes forming and storing the Jacobian is often the
dominant cost. None of those premises holds here:

- **The Jacobian is a by-product.** VerA's forward AD emits each instance's
  local Jacobian with its residual. The GPU already assembles the global
  values into `d_g`/`d_c` through the deterministic reduction (`gpu.zig`
  `enqueueEval`). An exact J·v is an SpMV on those values, far cheaper than
  another device evaluation. ABI 5 cuts the derivative-lane work to
  0.12-0.19× of today for models with n_u ≥ 14, which narrows the gap
  between a full evaluation and a residual-only one further.
- **The preconditioner is the exact LU.** `jfnk` right-preconditions with the
  factored Jacobian, so the preconditioned operator is the identity plus
  finite-difference error and GMRES stops after one or two steps. That is
  Newton plus extra residual evaluations. `converger.zig`'s own table:
  rc_ladder_10k takes 2.19 s direct, 4.76 s jfnk and 39.4 s jfnk-nolu. The
  CUDA row shows the same pattern.
- **Matvecs are sequential.** Arnoldi's v_{j+1} depends on J v_j, a true
  RAW. Only block and enlarged Krylov methods (§2.7) produce several
  independent matvecs per iteration, and they buy that with more total
  matvecs.
- **Solves run on the host.** Each finite-difference matvec is a host
  round trip, so JFNK raises syncs per Newton step from 1 to m + 1.

`op.zig` still says rung 4 is "the algorithm the GPU kernel runs". That
kernel was removed (`newton-raphson-convergence.md` §4), so the comment is
stale.

## 2. The candidates

Notation: N instances, n unknowns, k lanes, I Newton iterations per step,
E one device evaluation, E_r a residual-only evaluation, F the host
factor plus solve, R one sync.

| Option | Device work per step | Serial chain per step | Syncs per accepted step |
|---|---|---|---|
| today | (I+1)E | I(2R + E + F) + ~4R | 2I + 4 |
| 2.1 one sync | (I+1)E | I(R + E + F) + R | I + 1 |
| 2.2 k problems | k(I+1)E | I(R + E(kN) + F_k) + R | I + 1 per k problems |
| 2.3 speculation | k× on failure paths | failure chain f → ⌈f/k⌉ | as 2.1 |
| 2.4 chord | I_c·E_r + E/reuse | I_c(R + E_r + solve) | I_c + 1, I_c ≥ I |
| 2.5 line search | I_ls(E + k·E_r) | I_ls(R + E(kN) + F) | I_ls + 1 |
| 2.6 NK, assembled J | I(E + m·SpMV + m·precond) | on the device | ~I |
| 2.7 FD-JFNK | I(E + m·E_r) | I(m+1)(R + E_r) | I(m+1) |
| 2.8 parareal | (K+1)× serial fine work | ~K(serial/P + coarse·P) | per slice |

### 2.1 One sync per Newton iteration (rank 1)

**Idea.** The limit pass and the next evaluation are both device work at the
same x_{k+1}. The host hop between them exists only because
`applyLimitsOnGpu` synchronizes to return the flag, and `evalOnGpu`
re-uploads x. Enqueue the limit launch, the eval launch, the reduction and
every download together, then synchronize once. `enqueueEval` is already
separate from the wait, so this is a scheduling change.

**Avoiding a wasted evaluation.** On the iteration that converges, the eval
at x_{k+1} is never used. The host already knows, before calling
`applyLimits`, whether the iterate can pass. The first-iterate rule, the
delta test (`updateAndNorm` runs first in `finalizeStep`) and the residual
gate (F_k and diag J_k are in hand) do not depend on the limit flag. When
any of them already fails, the eval is certainly needed: fuse it. When all
pass, only the limit flag is undecided: keep today's limit-only sync, and
evaluate after it if limiting fired. No iteration evaluates anything today's
path would not.

The same rule covers the rest of the step. The predictor's
`applyLimits(trial, cur)` is always followed by the first eval, so it always
fuses. `stateCtl(.query)` and `evalQ(trial)` act at the same x and share one
sync. `stateCtl(.commit)` discards its result, so it can be enqueued without
waiting.

**Numbers.** Syncs per accepted step fall from 2I + 4 to I + 1, with the
same launches in the same order on the same data, so outputs are bitwise
identical to today's GPU path. The *model* saving is up to one sync (a share
of the 150 µs fixed cost) per iteration: large for mos1-class decks now,
10-15% of a bsim4 iteration after ABI 5, and small for bsim4 before it.
Conformance: identical. Preconditioner: none.

### 2.2 Lanes over independent problems (rank 2)

**Idea.** `sweep/lanes.zig solveLanes` runs N cold DC solves one after
another on one workspace (`mc.zig`, `temp_sweep.zig`), and `dc.zig` sweeps
point by point. Run k of them as lanes. The GPU evaluates k states per launch
(grid = instances × lanes). The host factors k matrices of one pattern with
`LaneLu(W)`, which replays one SparseLu pivot tape across W lanes and peels
failed lanes to the scalar path, exactly as `freq_solve.zig solveBatch`
already does for frequency points. Every lane runs the conformant Newton with
its own gates. Lanes that converge retire from the live mask.
`ensemble-sweeps.md` §4 already describes this design; this page adds the
GPU half and the exactness condition.

**Exactness.** Each lane's factors equal a scalar SparseLu replay of the same
tape bitwise (the LaneLu contract). Today's serial `solveLanes` carries the
tape from the previous lane through the shared workspace. The two agree to
rounding and are bitwise equal whenever both use the same pivots. The BBD
and tridiagonal engines have no lane form yet, so lanes need SparseLu or a
new LaneBbd.

**Numbers.** Per problem, syncs fall by a factor of k and device launches by
up to k. Download bytes do not change: each lane needs its full planes for
its LU, (2(nnz+1) + 2(n+1))·8 B per lane at ~11 GB/s. The *model* win is
largest for small circuits of cheap models (mos1: fixed cost > kernel),
exactly where the GPU loses today (`gbase.txt`: mos1_2000 is slower on the
GPU). Iteration counts are those of each serial solve. Preconditioner: none.

### 2.3 Exact speculation on retry chains, and OP rung racing (rank 3)

**Idea.** Wherever the serial schedule retries, it knows the next candidates
before the current one finishes. Evaluate the chain as lanes from the same
saved state and commit the first candidate in serial order that passes. The
committed result is the one the serial schedule would have reached, by the
same arithmetic up to the pivot-tape caveat of §2.2.

| Chain | Serial rule (source) | Lanes |
|---|---|---|
| Transient Newton failure | dt /= 8, order to BE, revert state (`tran.zig`, dctran.c:815) | dt, dt/8, dt/64 from the same accepted point |
| gmin retreat | factor ← factor^(1/4), restart from x_good (`op.zig`, cktop.c) | the next retreat factors |
| Source-step failure | delta /= 2 from lambda_good | delta/2, delta/4, ... |
| OP ladder | plain → gmin → source → JFNK → OPtran, each a cold start | race rungs 2-5, take the first in ladder order |

The success path cannot be speculated exactly. Rung r + 1 warm-starts from
rung r's solution, which is unknown until rung r converges: a true RAW.
Starting rungs from the same cold point instead changes which solution a
bistable circuit settles on. Rung racing is exact only if no device state
leaks between rungs (limit state and FSM latches). `converger.run` clears
limits, and E3's gate should check the latches. The OP rungs differ in
algorithm and in model parameters (source stepping calls `applyAttempt`), so
racing is thread-level work on cloned Circuits, not SIMD lanes.

**Numbers.** Work is k× on the chains taken. Racing dt and dt/8 on every step
costs a second lane always and wins only if Newton failures are frequent. It
is worth doing only where the lane is free (E2) and the host LU is lane-cheap
(LaneLu W = 2 or 4). A failed attempt of up to 100 iterations followed by a
retry collapses to the longer of the two. The case counts come from
`ZP_TRAN_STATS` (`rej_newton`), which E1 collects. Conformance: serial
result. Preconditioner: none.

### 2.4 Chord and stale-LU Newton with a residual-only kernel (rank 4)

**Idea.** Keep the last factorization for several iterations (and across
steps in transient, as SILCA's fixed-leading-coefficient integration does)
and evaluate only F. On the GPU that allows a residual-only kernel: the value
lane alone, the rhs/q staging alone, and n + 1 doubles down instead of
2(nnz+1) + 2(n+1). Anderson acceleration (Walker and Ni 2011) can recover
some of the lost rate.

**Iteration counts.** The chord method converges linearly, so I_c ≥ I and
each extra iteration is one more sync. CVODE's triggers and rate test
(gpu-convergence-fields.md §3.3) are the concrete rules to start from.
Li and Shi report more than an order of magnitude over SPICE3 on
parasitic-heavy transient, where the factor dominates. Our GPU decks are the opposite case: parallel inverters have a
nearly block-diagonal matrix and a cheap factor.

**Conformance.** Changes the iterate sequence, and it breaks the delta test's
meaning. Under linear contraction ρ, a step below tolerance still leaves an
error of about ρ/(1 − ρ) times the step. The gate would need a contraction
estimate, so this is opt-in only. It pays mainly on LU-bound post-layout
decks, which is a host-solver question more than a GPU one.

### 2.5 Parallel line search (rank 5)

**Idea.** Evaluate F(x + α_i dx) for α ∈ {1, 1/2, 1/4, ...} in one launch
and take the largest α that satisfies Armijo. cuRobo uses exactly this on the
GPU for trajectory optimization, and Gaedke-Merzhäuser et al. use it inside
INLA. We found no circuit-simulator precedent.

**Interaction.** ngspice has no line search. Device limiting is its
globalization, and a limited step is not along dx, so every candidate would
run limit and eval per lane from the same x_old. That changes the iterate
sequence, so it can only be opt-in. The useful place is a new OP rung before
gmin stepping. The metric is how many hard OP decks (`tests/fixtures/
convergence/`) then skip the ladder, and those decks are small circuits on the
CPU. Verdict: span-win-work-loss for transient, possibly useful for OP.

### 2.6 Newton-Krylov with the assembled Jacobian on the GPU (rank 6)

**Idea.** Keep x, F, the Krylov basis and a preconditioner on the device.
Compute J·v as an SpMV on the already-reduced `d_g + ag0·d_c`, run GMRES on
the device, and return only the convergence verdict. Syncs per iteration fall
to about one flag word, and the host solve disappears.

**Preconditioner.** Circuit Jacobians are hard for ILU: voltage-source rows
have zero diagonals, supply rails make dense rows, and the matrices are
unsymmetric and not diagonally dominant. Xyce's recipe for iterative circuit
solves is singleton removal, BTF, hypergraph partitioning and then block
Jacobi (Thornquist et al. 2009). The Xyce Users' Guide reports ShyLU
converging more consistently than that. Zhao and Feng's support-circuit
preconditioners report up to 22× faster linear solves. Our `bbd.zig` is an
exact structured alternative for subcircuit-expanded netlists: blocks of at
most 64 factored densely, which is the batched dense LU shape of MAGMA
batched, plus a border of at most 512.

**Assessment.** Commercial GPU SPICE moved the direct LU to the GPU (ALPS-GT
mixes left- and right-looking GPU factorization; GLU reports 19.56× over
KLU), not to Krylov. `gpu-sparse-lu.md` puts GLU's wins above about 80k rows,
above almost all of the corpus. This breaks the host-solve doctrine and the
iterate sequence (Eisenstat-Walker forcing terms make each step inexact). It
is research, worth revisiting only for post-layout decks where the LU
dominates.

### 2.7 JFNK with batched matvecs, block and s-step GMRES (rank 7)

- Finite-difference JFNK: see §1.3. It needs m + 1 syncs per Newton step
  and gives an m ≈ 1-2 GMRES with the exact LU. Without the LU,
  `jfnk-nolu` is 18× slower than direct on rc_ladder_10k.
- Block and enlarged Krylov methods (O'Leary 1980; Grigori, Moufawad and Nataf
  2016) produce t independent matvecs per iteration, which could be t
  perturbed states in one launch. With t·E_r per iteration against Newton's
  one E plus one host solve, the trade only pays when one launch of t·N
  states costs about one launch of N. Even then it needs a non-LU
  preconditioner to have iterations worth saving.
- s-step (communication-avoiding) GMRES (Hoemmen 2010; Carson 2015)
  reduces global reductions, not matvec dependencies. The monomial basis
  J^j v still has to be computed in order, and our reductions are host-side
  anyway.
- A directional-derivative AD lane (seed the dual with v) would give an
  exact J·v without the finite-difference error. It is still one evaluation
  per matvec, and the SpMV on assembled values is cheaper.

Verdict: movement-bound in this architecture, and more work than Newton in
any architecture where J comes with F.

### 2.8 Parallel in time (rank 8)

Parareal (Lions, Maday and Turinici 2001) converges superlinearly on bounded
intervals (Gander and Vandewalle 2007), with speedup at most P/K for P
slices and K iterations. Circuits make K large. Switching sources break plain
parareal, and Gander, Kulchytska-Ruchka, Niyonzima and Schöps (2019) had to
smooth the PWM input on the coarse level. A ring oscillator's phase error
accumulates across slices. MGRIT (Falgout et al. 2014) is non-intrusive,
reported up to 10× on power-electronics EMT (Energies 2022), and needs coarse
grids aligned to switching periods. Waveform relaxation (Lelarasmee, Ruehli
and Sangiovanni-Vincentelli 1982) converges slowly under strong coupling and
feedback.

All three replace the LTE-controlled step sequence with per-slice grids, so
waveforms differ from ngspice's at the tolerance level at best. For periodic
steady state we already have shooting and HB. Verdict: needs-new-math, not a
conformance-mode candidate.

### 2.9 Other GPU circuit-simulation work

- Gulati et al. (2009) moved BSIM3 evaluation to the GPU when it was about 75%
  of runtime. They got 2.36× overall on average (3.07× best), with an
  asymptote near 4×. Our Amdahl picture matches: after the device kernel, the
  rest of the iteration sets the ceiling.
- CUSPICE (ngspice on CUDA, 2014) puts device evaluation and matrix loading
  on the GPU. It reports more than 3× on transient for circuits with
  thousands of transistors, which is our shape.
- Kapre and DeHon (2009) compiled Verilog-AMS models to several targets and
  measured 3-131× on the GPU, in single precision. That is the closest
  precedent to VerA plus Gompute.
- Synopsys PrimeSim with GPUs reports about 3× on transient for a
  200M-device post-layout PLL, using 4 GPUs added to 32 CPU cores. ALPS-GT
  reports 5-13×, with GPU factorization. Neither publication mentions JFNK.
- Higher-order Newton (Halley via second-order AD lanes) saves at most about
  one iteration where Newton is already quadratic. Circuit Newton is limited
  by globalization far from the solution, not by the local rate. Not worth
  the ABI growth.

## 3. Data layout for the surviving options

The six questions, answered once for the lane machinery shared by §2.2 and
§2.3, then briefly for §2.1 and §2.4.

**Lanes (§2.2, §2.3).**

1. *In/out.* In: k start states, k parameter sets (ensemble) or k retry
   controls (speculation: dt, gmin, lambda), shared frozen tapes and pattern.
   Out: k solutions, a converged mask, per-lane iteration counts.
2. *How many.* k from 2 to 64. N from 10² to 10⁵ instances. n and nnz as the
   circuit.
3. *Widths.* Lane index u8 (k ≤ 64). Live, converged and failed-pivot masks
   in one u64. Per-lane iteration count u16, because `Options.max_iter` is u16
   (ITL1 can exceed 255). Instance, slot and staging indices stay u32, as the
   frozen tapes are.
4. *Access.* The kernel reads x[lane][gath[i]] and writes lane-private
   staging, so planes are lane-major, each lane's plane in today's frozen
   `[]f64` layout at stride nnz + 1 (or n + 1). LaneLu reads values as
   `[nnz]@Vector(W, f64)`, entry-major and lane-minor. Transpose on the host
   (nnz·W moves per factor, small against the refactor) before teaching the
   reduction kernel to write lane-minor. The reduction output is ours to
   shape; the tapes are not.
5. *Lifetime.* Per-query arena for lane planes, x and masks. For the device,
   per-lane `d_lim` (count·n_u f64 per batch), per-lane `d_states`, and
   per-lane `d_instances` only where the instance blob is mutable (bsim4's
   path latch pb/wb and pq/wq lives there, per the ctl kernel). Per-lane
   `d_models` only for ensemble lanes whose parameters differ.
6. *Parallel.* Lanes are independent by construction. A failed lane peels to
   the scalar path; the survivors stay exact.

Committing a speculative lane copies that lane's x, lim, states and mutable
instance bytes into lane 0 on the device. The host batches do the same
through the existing `stateCtl` revert/commit pair.

**One sync (§2.1).** No new table. The context gains the prefetched x (a
pinned copy already exists as `pin_x2`), a bool saying the planes in the
pinned buffers belong to it, and the `t` of that evaluation. The next
`evalPlanes` compares its x and t with them (an n-double memcmp) and skips
the launch on a match.

**Residual-only (§2.4).** The same tapes. Only the rhs/q staging and
reduction run, and n + 1 doubles come down. One more kernel image per model,
which doubles build time and cold JIT (hisimhv's JIT is already ~1070 s).

## 4. What would change where

### converger.zig

- §2.1: `finalizeStep` already computes `scaled` before `applyLimits`. Add
  the residual verdict ahead of it too, and pass the result to
  `sys.applyLimits` as a `prefetch` hint (or a new optional
  `sys.applyLimitsThenEval(x, x_old, t)`). `newton` is otherwise untouched,
  which is why its output cannot change.
- §2.2 and §2.3: a lane-generic Newton, `newtonLanes(W, ...)`. The per-lane
  gates reuse `finalizeStep` lane by lane, so there is no second gate
  implementation. Factoring goes through LaneLu with a failed-mask peel to
  `direct.Solver`, and a live mask retires converged lanes. Per the
  lane-axis doctrine the scalar oracle must be `newtonLanes(1)`. That can
  only replace `newton` after a corpus run shows the two bitwise equal.
  Until then it is a second path, and the page that lands it should say so
  with a `ponytail:` note.
- §2.4 and §2.5 would add `Options` fields (`chord_reuse`, `line_search`) and
  pins beside `ESPICE_SOLVER`. Neither may be default.
- JFNK stays as the OP rung 4 and the `ESPICE_SOLVER` pin. Nothing here
  argues for widening it. The stale comment in `op.zig` (rung 4) should be
  corrected in a code commit.

### gpu.zig and Circuit.GpuHook

- §2.1: `applyLimitsOnGpu(x, x_old, t, prefetch)` enqueues lim and eval
  launches, reduce, all downloads and the flags on the one stream, then
  synchronizes once. `evalOnGpu` checks the prefetch key and only stamps the
  host batches, which still run after `advanceIteration`. Resident devices
  cannot have `advanceIteration`, `beginSolve` or `checkConvergence`
  (`gpuEligible`), so prefetching the device half is safe. `stateCtlOnGpu`
  gets an async `.commit` and a combined `.query` plus charge evaluation.
  `GpuHook` gains a `t` argument on `apply_limits`.
- §2.2 and §2.3, first prototype without new kernels: per-lane buffers, and k
  launches of the existing entry points plus k reductions on one stream, with
  one sync. Second step: a lane axis in the kernel wrapper (grid y = lane,
  per-lane base pointers). That wrapper lives in `device/eval.zig`, so it
  needs the default GPU build. The tapes, the Model/Instance PODs and the
  per-lane plane layout stay frozen, so layout_hash does not move. New
  hooks: `eval_lanes`, `limit_lanes` and `commit_lane(j)`.

### The VerA seam

- §2.1: none.
- §2.2 and §2.3: none in the model cores, which are per instance. ABI 5 makes
  `SimState` an extern kernel argument. Speculative dt lanes need one
  `SimState` per lane (dt, t), which ARPice's wrapper can index by lane.
  One request to VerA: move mutable latch state (bsim4's pb/wb, pq/wq) out of
  the Instance blob into `State`. Lanes would then copy State only, not the
  whole parameter blob (to be sized: count × sizeof(Instance) × k).
- §2.4: a residual-only instantiation is the ABI 5 family with no derivative
  lanes (`Of(m)` = the value type). It is valid only for cores whose values
  never read a derivative (`ddx`). VerA knows this per value from
  `Analysis.deps` and would need to export it as a comptime flag.

## 5. First experiments

**E1. Sync census, then one sync per iteration.** Decks: the synthetic
`gpu-gen.py` families at 2000 inverters (mos1, bsim3, bsim4, psp103), and the
corpus decks `stress/scaling_parallel_inverters_2000` and
`stress/vacask_ring` (PSP103, eligible at `ee66e0b`), all with `--backend cuda`, warm JIT.

1. No code change beyond counters: syncs per accepted step, evals per step,
   µs per Newton iteration (`ESPICE_GPU_STATS` Prof at `ee66e0b`), and
   `ZP_TRAN_STATS` (attempts, nr_iters, rej_newton, rej_lte). This also gives
   I, and the Newton failure rate that §2.3 needs.
2. Implement §2.1.

Metric: syncs per accepted step (expect 2I + 4 → I + 1), µs per iteration,
and whole-run wall (median of 5, hyperfine or `zig build bench`). Gate:
`.raw` output bitwise identical between the fused and unfused GPU runs on
every deck. Predicted *model*: the largest gain on mos1_2000 and bsim3_2000,
small on bsim4_2000 until ABI 5.

**E2. Lane headroom curve.** Same families, N = 500, 1k, 2k, 4k, 8k, 16k and
32k inverters. Metric: measured kernel µs per evaluation against N, the knee
N* where it turns linear, and the bus bytes per lane (nnz, n). Free lanes at
N ≈ N*/N. Repeat after ABI 5 lands. The result decides whether §2.2 and §2.3
are worth building on the GPU. On the host side, compare `LaneLu(4)` refactor
time per lane with scalar SparseLu refactor on the same matrices.

**E3. Ensemble lanes prototype.** `solveLanes` with k = 4, 8, 16 lanes: k
launches plus one sync, and host `LaneLu(4)`. Correctness decks: every deck in
`tests/fixtures/mc/`, `tests/fixtures/temp/` and
`dc/bench_ensemble_sweep_lanes`; each lane must match a scalar replay of the
same tape bitwise and today's serial path within the deck tolerance. Speed
decks: `stress/sweep_opamp_wl_200` and a bsim4 500-inverter deck under
`.mc 64`. Metric: wall per lane against the serial lanes on CPU and GPU. Log
the pivot-tape mismatches that explain any bit difference from the serial
path.

# Part II: GPU-native mode

Part I keeps ngspice's iterate sequence and time grid. Part II drops that
promise and asks what the GPU could do. The cross-field sources behind it
are in [gpu-convergence-fields.md](gpu-convergence-fields.md); this part
re-ranks them for the new contract. Everything here is a proposal. Items
marked **speculative** have no source that does them in a circuit simulator.

## 6. The contract of GPU-native mode

**Relaxed.** Bitwise iterates, the NIiter gates, the ngspice time grid, and
the rule that one state is evaluated per iteration.

**Kept.**

- Every deck must pass its oracle at the deck's own tolerances, and the
  pass set must be at least today's. The common values in
  `tests/fixtures/**/*.expected.json` are rtol 1e-3 or 3e-3, and atol
  2e-6 V or 1e-11 to 1e-15 A.
  §10.1 found that nine of these oracles encode ngspice's per-step Newton
  error: publishing the more accurate x_k+1 fails them. A mode that changes
  the published iterate, the Newton test or the grid cannot meet this rule
  as written.
- The final Newton solution must meet ngspice-level tolerances (reltol,
  vntol, abstol), and the error per step must stay LTE-controlled at trtol.
  The mode may control error differently, but not loosely.
- The same answers on the CPU and GPU backends. Every algorithm below is
  backend-agnostic, and most of them help the CPU too.

**Figure of merit.** Wall time at equal accuracy, measured by the proof rule
(`zig build bench`, before and after).

**What a different time grid costs in the gate.** The corpus harness
compares transients at the oracle's accepted times, interpolating our
waveform linearly (`tests/test_correctness.zig`). A mode that takes much
larger steps can be accurate at its own points and still fail between them.
It needs dense output: evaluate the integration polynomial at the reference
times, or cap dt by the waveform's curvature. That is a real constraint on
multirate, exponential and parallel-in-time methods below.

Wall time is roughly

    steps × (Newton iterations per step) × (cost per iteration) / (problems per launch)

and each lever attacks one factor:

| Lever | Factor it cuts | Where it pays |
|---|---|---|
| Modified Newton, rate test, one-iteration acceptance | iterations and factors per step | every deck |
| Nonlinear elimination of internal nodes | iterations per step | devices with series resistances and internal networks |
| Activity-driven evaluation, multirate | cost per step, then steps for latent parts | chains, adders, digital-like decks |
| Lanes (ensembles, dt candidates, speculative retries) | problems per launch, rejected steps | Monte Carlo, corners, sweeps, rejection-heavy decks |
| Mixed precision, one sync | cost per iteration | GPU-path decks |
| Exponential, Rosenbrock, parallel in time | steps, or span of steps | linear-dominated or long periodic decks |

## 7. Re-ranked candidates

| Rank | Candidate | Mechanism | Fit to our structure | Regime (model, to be measured) |
|---|---|---|---|---|
| 1 | Modified Newton with CVODE's rules (§7.1) | lagged LU, rate test, accept at iteration 0, stale-LU-preconditioned Newton-Krylov as the fallback | strong: J comes with F, and factors are reusable | evals per step ~3 → ~1.5; factors per step → ≤0.3 |
| 2 | Activity-driven evaluation → multirate (§7.3) | bypass latent instances, compact the active ones, then per-partition steps | strong on chains and adders, nil on parallel inverters | eval work ∝ active fraction |
| 3 | Lanes as a first-class axis (§7.4) | ensembles with per-lane dt and GPU batched LU; dt-candidate lanes | strong for ensembles; single decks need free lanes (E2) | k× throughput up to the E2 knee |
| 4 | Nonlinear elimination of internal nodes, then blocks (§7.2) | fixed-count inner Newton on the device; multilevel Newton, ASPIN/RASPEN | good if internal nodes lead the Newton error | fewer global iterations, pending census |
| 5 | Mixed precision planes and LU (§7.5) | f32 g/c on the bus, f32 host LU; Newton corrects | good: fixed point set by the f64 residual | bus bytes ÷2, LU bandwidth ÷2 |
| 6 | Exponential integrators (§7.8) | MATEX, exponential Rosenbrock-Euler | good for RC-dominated decks, weak with strong devices | one LU per step; large steps between input edges |
| 7 | Consensus multi-start OP (§7.6) | k perturbed starts in lanes, accept on agreement | OP only; multistability is the risk | ladder time on hard OPs |
| 8 | Rosenbrock/W-methods (§7.7) | linearly implicit, fixed stages, no Newton loop | nowhere to apply `$limit`; good for ensembles of small circuits | uniform lane work |
| 9 | Parallel in time at tolerance (§7.9) | parareal with slices as lanes; WavePipe | poor on oscillators and switching; fair on RC and smooth decks | ≤ P/K |
| not ranked | Finite-difference JFNK (§7.1, last paragraph) | residual-only matvecs | still dominated: the assembled J is free | none |

### 7.1 Modified Newton with CVODE's rules (rank 1)

**Mechanism.** From CVODE (SUNDIALS docs) and RADAU5 (Hairer and Wanner
1999), with W-method theory (Steihaug and Wolfbrandt 1979) justifying a
stale matrix:

- Keep the LU of G + ag0·C and refactor only after 20 steps, when
  |ag0/ag0_LU − 1| > 0.3, or after a failure.
- Test convergence by the estimated contraction rate R, with
  R·‖δ‖ < 0.1·tol, instead of NIiter's delta test.
- Accept at iteration 0 when the predictor's first correction already
  passes. The `iter == 0` floor exists only for ngspice parity; CVODE caps
  Newton at 3 iterations and has no minimum.
- Use a better predictor: the integration polynomial through the last
  k + 1 points instead of MODEINITPRED's linear extrapolation.
- Iterations with a stale matrix need only F, which on the GPU means a
  residual-only download (n + 1 doubles).
- When the rate degrades (R > 0.3) but the LU is otherwise fine, run a
  few GMRES steps on the fresh assembled J, preconditioned by the stale
  LU, instead of refactoring. That is "JFNK with a physics-based
  preconditioner" in its useful form: an SpMV on the already-assembled
  values, never a finite-difference evaluation. Anderson acceleration over
  the chord iterates (Walker and Ni 2011; KINSOL; DEQ solvers) is the
  cheaper alternative, and both can be tried behind one pin.

**Fit.** Circuits deliver J with F, so a fresh J costs nothing extra; only
the factor is worth saving. Device limiting still applies per iteration.
MAPS (Ye et al. 2008) measured 20-34× from successive chord on clock meshes
and a convergence failure on an adder. The rate test plus refactor-on-failure
is what makes chord safe, and the MAPS failure is the case it must catch.

**Regime.** Eval-bound decks (heavy models, GPU path) gain from fewer evals
per step. LU-bound decks (RC meshes, post-layout, `scaling_rc_ladder_100k`,
`scaling_resistor_grid_100x100`) gain from fewer factors.

**Cheap falsifiable experiments.**

1. *Zero code.* The `ZP_OPDBG` trace prints `scaled` and the reject reason
   for each iterate. Count the transient solves where iteration 0 already
   had scaled < 1 and a passing residual, so only `first_iter` forced a
   second evaluation. Decks: `stress/scaling_inverter_chain_256`,
   `stress/vacask_ring`, `stress/scaling_parallel_inverters_2000`,
   `tran/bench_tran_fourbitadder`. If that share is under 20%, drop
   one-iteration acceptance.
2. *Small code.* An `ESPICE_SOLVER=modnewton` host pin, measured on the same
   decks plus the two LU-bound ones. Metrics: evals per accepted step,
   factors per accepted step, wall, and the full-corpus pass set at oracle
   tolerance. The claim fails if evals per step stay above 2 or the pass
   set shrinks.

**Finite-difference JFNK, for the record.** Physics-based preconditioning
(Knoll and Keyes 2004) needs a cheap approximate operator, and our stale LU
is a better one than any simplified physics. With that preconditioner, the
finite-difference matvec's only advantage (no assembled J) is worth nothing
here. No circuit simulator using JFNK turned up in the literature pass
either; Xyce uses assembled Jacobians with block-Jacobi, BTF and Schur
preconditioners.

### 7.2 Nonlinear elimination: internal nodes, then subcircuit blocks (rank 4)

**Mechanism.** Multilevel Newton (Rabbat, Sangiovanni-Vincentelli and Hsieh
1979) is the circuit form of nonlinear elimination: an inner Newton solves
each subcircuit, an outer Newton solves the interface, and local quadratic
convergence holds. ASPIN (Cai and Keyes 2002) and RASPEN (Dolean et al.
2016) are the modern subdomain forms. RASPEN applies Newton to the fixed
point of nonlinear restricted additive Schwarz, which converges on its own
and so preconditions better. The GPU form (fields page §3.1): each thread
takes a fixed 2-3 Newton steps on its instance's internal unknowns with the
AD local Jacobian, then stamps. The second level runs the same on BBD blocks,
batched dense per block (at most 64 wide), with the host solving the border.

**Fit.** Internal nodes are the one place our coupled instances become the
independent cells of chemistry codes. The pattern and the tapes are
unchanged. The risk is that terminal coupling (feedback, latches), not
internal lag, dominates the iteration count.

**Regime.** Decks whose Newton steps are led by internal nodes: diodes with
RS, MOS source and drain resistances, bsim4 gate and body networks.

**Cheap falsifiable experiment.** The zero-code census of fields page §3.1:
count the non-final iterates whose largest step is on an internal unknown.
If that is under 20% on `convergence/`, `op/` and the gpu-gen decks,
demote this below rank 8.

### 7.3 Activity-driven evaluation, then multirate (rank 2)

**Mechanism.** Three steps, each usable on its own.

1. *Latency bypass.* Evaluate only instances whose gathered voltages moved
   more than a tolerance since their last evaluation. The deterministic
   staging buffer keeps the latent instances' contributions (fields page
   §3.2). Unlike ngspice's bypass, the threshold is part of the accuracy
   contract: a skipped instance's stamp error must stay under the Newton
   tolerance, which a first-order bound from its local Jacobian times its
   voltage change can check.
2. *Compaction.* Launch only the active instances: a scan over one flag
   per instance, then an index list. That pays once the active set is
   under one GPU wave.
3. *Multirate.* Latent partitions take long steps and active ones short
   ones, coupled by interpolation. Options include Gear and Wells (1984),
   multirate partitioned RK (Günther, Kværnø and Rentrop 2001), a multirate
   W-method for circuits (Bartel and Günther 2002), and BDF slowest-first
   with automatic partitioning (Verhoeven et al. 2007, stable when the
   partitions are weakly coupled).

**Precedent.** Iterated timing analysis (SPLICE1, Saleh, Kleckner and Newton
1983) and relaxation-based simulation (Newton and Sangiovanni-Vincentelli
1984, "up to two orders of magnitude") are circuit precedents. Commercial
fast-SPICE partitions with event-driven multirate behind accuracy knobs.
Reservoir active sets (Jiang 2020) held 6.5-10% of cells with unchanged
Newton counts.

**Fit.** This is the only lever that changes the work per step in
proportion to circuit activity, and its winners are the decks the GPU cannot
help: `stress/scaling_inverter_chain_4k` (7.5 s on one CPU thread, and
timing-sensitive in the corpus) switches one stage at a time. It does
nothing for parallel inverters, where every instance switches together.
Multirate needs its own error control per partition, plus dense output for
the harness (§6).

**Cheap falsifiable experiment.** The activity census of fields page §3.2: a
host counter of the fraction of instances whose voltages moved more than
reltol·|v| + vntol, per Newton iteration and per step. Decks:
`stress/scaling_inverter_chain_4k`, `stress/scaling_inverter_chain_256`,
`tran/bench_tran_fourbitadder`, `stress/vacask_ring`. If the median active
fraction on the chains is over 30%, steps 1 and 2 cannot beat 3×; drop
multirate and keep bypass as a minor item.

### 7.4 Lanes as a first-class axis (rank 3)

**Mechanism.** Part I's lanes without the exactness constraint:

- **Ensembles.** Monte Carlo, corners, temperature and sweeps, with a
  per-lane dt and `SimState`, since lockstep costs up to 4× in steps
  (torchode). Planes stay on the GPU and are factored there by cuDSS
  uniform batch, following batched power flow: Zhou et al. report up to 76×
  over KLU, and Wang et al. (2021) more than 100× over pandapower.
- **dt-candidate lanes** (speculative). Solve step n at dt, 2dt, 4dt and
  8dt at once and accept the largest that passes LTE. That removes LTE
  rejections and ngspice's 2× growth cap after breakpoints: regrowing from
  0.1·dt after an edge takes about 4 serial steps, and would take 1-2.
- **Speculative retries** from Part I §2.3, now free to commit any passing
  candidate rather than the serial one.
- **WavePipe-style time-point pipelining** (Dong, Li and Ye 2008,
  speculative on the GPU). Lanes solve steps n+1 and n+2 from predicted
  histories while step n converges, then repair with one correction
  iteration when the prediction was close.

**Fit.** Ensembles are the textbook batched-independent case. On a single
deck, dt lanes and pipelining only pay when lanes are free (E2's knee) and
the host LU is lane-cheap (LaneLu, or on-device batched LU).

**Cheap falsifiable experiments.** E2 and E3 from §5. Plus a zero-code count
from `ZP_TRAN_STATS` (attempts, rej_lte, rej_newton) and one counter of
steps where the LTE wanted more than 2× growth. If rejected and
growth-capped steps together are under 10% of accepted steps on the stress
decks, drop dt lanes and keep ensembles.

### 7.5 Mixed precision (rank 5)

**Mechanism.** Newton's fixed point is set by the f64 residual, so the
Jacobian's precision affects only the rate. f32 derivative lanes already
ship (`gpuJacFloat`, commit `4853197`: 1.16× on `parallel_inverters_2000`,
Newton count 1356 → 1354). Two extensions:

- Download g and c as f32 after the ordered f64 reduction (fields page
  §3.4).
- Factor in f32 on the host. The Newton loop corrects the error, in the
  role that iterative refinement plays for a linear solve.

**Fit.** Good, except for ill-conditioned MNA systems. A 1e9-gain E source
row, as the residual-gate comment in `converger.zig` notes, would lose
digits in an f32 LU. So the pivot guard must fall back to f64, lane by lane.

**Experiment.** CPU-only: round g and c through f32 under an env flag, run
the corpus, and compare the pass set and Newton counts. Then the same for an
f32 LaneLu refactor on the stress matrices.

### 7.6 Consensus multi-start OP (rank 7, speculative)

**Mechanism.** When plain Newton fails, run k lanes from perturbed cold
starts: seeded junctions plus random node voltages inside the supply range.
Accept only if at least two lanes that started far apart converge to the
same x within tolerance. Agreement is evidence of a unique operating point.
Disagreement falls back to the conformant ladder, which is the only
defensible choice for a latch.

**Fit.** OP is a small share of a transient's wall time, but it dominates
DC sweeps of hard circuits, which fall back to the ladder per point. GPU
polynomial homotopy tracks many paths at once (Verschelde; HomotopyContinuation.jl),
and batched power flow solves many cases with one pattern. We found no GPU
multi-start Newton for DC operating points.

**Experiment.** A 30-line env-flag driver in `op.zig` (the frontend has no
`.nodeset`, so decks cannot seed starts). Run it on the `convergence/` decks
that reach gmin stepping. Metric: the fraction where consensus matches the
oracle, the fraction that falls back, and the ladder time saved. It fails
if consensus ever accepts a solution the oracle rejects.

### 7.7 Rosenbrock and W-methods (rank 8)

**Mechanism.** A linearly implicit step: one Jacobian and s stage solves,
with no Newton loop. W-methods allow a stale Jacobian. CHORAL, a
charge-oriented ROW method, ran in Infineon's TITAN simulator and did well
on oscillators (Günther et al. 1997). The multirate W-method of Bartel and
Günther (2002) is its latency-exploiting form. DiffEqGPU picked Rosenbrock
for GPU ensembles because every lane then does the same work.

**Fit.** Stage evaluations are sequential, so there is no batching gain on
one deck. There is also no iteration to apply `$limit` in, so strong
junction nonlinearity is left to step rejection. The regime is small-circuit
ensembles fully on the GPU, which would be a separate analysis.

**Experiment.** None cheap inside ESPice. The smallest test is a
DiffEqGPU ensemble of a hand-written diode-RC cell against our `.mc` on the
same cell, only if §7.4's ensembles leave a gap.

### 7.8 Exponential integrators (rank 6)

**Mechanism.** `.matex` implements R-MATEX for fixed-matrix (linear)
circuits: one factorization, rational Krylov for e^{hA}v, and steps bounded
by input transition points rather than LTE. MATEX reports about 13× over
fixed-step trapezoidal on IBM power grids (DAC 2014), and R-MATEX up to 14.4×
(TCAD 2016). Exponential Rosenbrock-Euler extends it to nonlinear circuits
with one LU per step and no refactor on a step change (Zhuang et al. DAC
2015). Its reported speedups conflict between sources, so they are not
quoted here.

**Fit.** RC-dominated decks. The Krylov basis is sequential and small, so
the GPU adds little beyond device evaluation.

**Experiment.** Available now: run `stress/scaling_rc_ladder_100k`,
`stress/scaling_rc_ladder_1k` and `stress/scaling_resistor_grid_100x100` as
`.matex` and as `.tran`, and compare wall time and oracle agreement. A clear
win on the linear decks justifies a GPU-native rule that routes linear
circuits to `.matex`. That is detection, not a new solver.

### 7.9 Parallel in time at a tolerance (rank 9)

**Mechanism.** Parareal: a cheap coarse propagator (BE with large steps, or
MATEX for linear parts) runs serially, and fine GPU-native transients run
per slice as lanes. They correct each other until the slice boundaries
agree to the tolerance. Speedup is at most P/K. Power-system parareal has
reported 5-7× in practice, and about 20× with cheap coarse solvers, at
0.01 rad (ORNL report, excerpt only). MGRIT gave up to 10× on EMT (Energies
2022).

**Fit.** Poor on oscillators, where phase error accumulates across slices
(`vacask_ring`), and on switching decks, where the coarse level needs
smoothed sources (Gander et al. 2019). Fair on long smooth or RC decks, which
MATEX already serves. Slices as lanes reuse §7.4's machinery.

**Experiment.** A script, no code: split `stress/vacask_ring` and
`stress/scaling_rc_ladder_1k` into P = 8 slices with `.ic` and `uic`, run a
coarse `.tran` with a large maximum step, iterate parareal outside the
simulator, and count K to reach the oracle tolerance. K ≥ P/2 falsifies it
for that deck class.

## 8. Top-3 GPU-native program, and how it coexists with the default

1. **Modified Newton (§7.1).** Every deck, CPU and GPU, lowest risk. It
   comes first because it changes only `converger.zig`, behind a pin, and
   the corpus gates it at once.
2. **Activity-driven evaluation (§7.3)**, taken in order: bypass with a
   checked stamp-error bound, then compaction on the GPU, then multirate
   only if the census shows latent partitions. It targets the chain and
   adder decks that neither the GPU nor Part I helps.
3. **Lanes (§7.4).** Ensembles with per-lane dt and on-device batched LU
   first, then dt-candidate lanes where E2 shows free lanes.

Nonlinear elimination (§7.2) and mixed precision (§7.5) join the program as
soon as their zero-code censuses come back positive. Both are small changes
inside the eval launch.

**Coexistence.**

- **Switch.** `--solver=conformant|gpu-native`. The default stays
  conformant, with Part I's exact improvements.
- **Pins.** Each GPU-native feature has its own `ESPICE_SOLVER`-style pin
  for A/B runs. The switch is a named bundle of them, so a regression can be
  bisected to one feature.
- **Backends.** The mode is backend-agnostic: `--backend cpu --solver
  gpu-native` must pass the same gate. That keeps the scalar-oracle rule
  (every lane kernel's W = 1 instance is the CPU path) and stops the mode
  from becoming GPU-only logic.
- **Gate.** The full corpus under `--solver=gpu-native`, at each deck's
  oracle rtol/atol, with the pass set a superset of the conformant pass set,
  and `zig build bench` wall time before and after per feature. A deck that
  passes conformant but fails GPU-native blocks the feature, not the deck.
- **Record.** Every divergence from ngspice this mode introduces (grid,
  iterate count, OP selection rule) is recorded in `dev/` with its
  measurement and fallback, per the proof rule.

## 9. Census results

Measured at `52a5903` plus two instrumentation commits (`ESPICE_CENSUS`,
`ESPICE_CENSUS_ACT`, `ESPICE_F32_PLANES`, and a `lu_trig` counter in
`ZP_TRAN_STATS`) that stay off `main`. CPU backend, `-Dgpu=false`, every
deck in `tran/`, `stress/`, `convergence/` and `op/` (166 decks). Other
builds shared the machine (load average 11 to 120), so every figure here
is a count except the MATEX wall times, which are marked. The gpu-gen
decks named in §7.2 are not in the tree and were not run.

### 9.1 Modified Newton (§7.1)

Transient solves only (t > 0). "Iterate 0 passes" means iterate 0 cleared
every gate except the first-iterate floor: not limited, scaled step < 1,
row-scaled residual, device convergence (state staging not replayed, so
an upper bound). Every such solve converged at iterate 1, so this is also
the share whose second evaluation exists only because of the floor.
"CVODE m=0" is CVODE's own test with a fresh LU (crate = 1): scaled step
≤ 0.1, not limited, publishing x0 + dx0. Factor calls split into exact
reuse (values bitwise equal to the last factor, already skipped by
`Solver.factor`) and numeric refactors on the stored pivot order.
"CVODE trigger" counts the factors CVODE's rules would take (refresh
after 20 attempts, on |ag0/ag0_LU − 1| > 0.3, or after a failure). It is
a floor, because a stale LU can also cost iterations.

| Decks | Solves | Iterate 0 passes | CVODE m=0 | Iterations 2 / 3 / 4 / ≥5 | Mean | Exact reuse | Factors per attempt | CVODE trigger per attempt |
|---|---|---|---|---|---|---|---|---|
| tran/ (69) | 457,717 | 64.9% | 11.7% | 99.8 / 0.1 / 0.1 / 0.0% | 2.00 | 75.3% | 0.50 | 0.06 |
| stress/ (16) | 2,531,043 | 95.1% | 87.0% | 98.4 / 1.5 / 0.1 / 0.0% | 2.02 | 39.3% | 1.23 | 0.05 |
| scaling_inverter_chain_256 | 1,209 | 0.5% | 0.5% | 3.3 / 5.6 / 87.4 / 3.6% | 3.91 | 0% | 3.91 | 0.19 |
| scaling_inverter_chain_4k | 1,202 | 0.5% | 0.5% | 3.4 / 5.4 / 87.5 / 3.7% | 3.91 | 0% | 3.91 | 0.19 |
| scaling_parallel_inverters_2000 | 589 | 65.7% | 63.2% | 84.2 / 9.3 / 5.6 / 0.8% | 2.23 | 26.2% | 1.65 | 0.19 |
| vacask_ring | 20,936 | 0.2% | 0.2% | 0.5 / 94.0 / 5.4 / 0.0% | 3.05 | 0% | 3.05 | 0.07 |
| vacask_mul | 500,027 | 85.6% | 63.1% | 96.4 / 3.6 / 0.0 / 0.0% | 2.04 | 0% | 2.04 | 0.05 |
| scaling_rc_ladder_100k | 235 | 12.8% | 0.4% | 100 / 0 / 0 / 0% | 2.00 | 90.4% | 0.19 | 0.20 |
| bench_tran_fourbitadder | 58 | 1.7% | 0% | 86.2 / 13.8 / 0 / 0% | 2.14 | 0% | 2.14 | 0.17 |
| bench_ngspice_mosamp | 100,248 | 0% | 0% | 99.8 / 0.2 / 0 / 0% | 2.00 | 0% | 2.00 | 0.05 |
| bench_ngspice_schmitt | 2,018 | 88.2% | 75.2% | 99.2 / 0.6 / 0.2 / 0% | 2.01 | 0% | 2.01 | 0.06 |

No solve ever took a single iteration (the floor), and in 2.99 M solves no
refactor lost its pivot order: the re-pivot count is zero. Over the 41
nonlinear decks with at least 50 steps, the per-deck median share of
iterate-0 passes is 62%, and 13 of them are under 20%. Summed over every
nonlinear deck's evaluations, acceptance at iterate 0 would remove 42% of
them, but most of that comes from `vacask_graetz` and `vacask_mul`. Of
the CVODE m=0 acceptances, 4 (all on `vacask_mul`) published an x1 that
the next delta test would have refused.

**Verdict: build.** It passes the §7.1 gate on the corpus as a whole but
fails it on three of the four named decks, so the win is split. Accepting
at iterate 0 costs one gate and saves up to half the evaluations on
quiescent decks (parallel inverters between edges, `vacask_mul`,
`schmitt`), and does nothing for the chains, the ring and the adder, which
take 3 to 3.9 iterations every step. Those need the lagged-LU half. There,
the CVODE trigger fires on 5-20% of attempts against 1.1-3.9 factors per
attempt today, and the pivot order never goes stale, so a kept LU is
cheap to keep valid. Whether chord iterations cost more evaluations than
they save in factors is the `ESPICE_SOLVER=modnewton` experiment (§7.1
item 2), which should run next on the chains and the ring.

### 9.2 Activity (§7.3)

Per host Newton evaluation, the share of model instances (linear element
types excluded) that bypass would still evaluate. An instance is active
when any gathered unknown moved more than 1e-3·max(|v|, |v_ref|) + 1e-6 V
(1e-12 A on a current row) from v_ref, its value at the instance's own
last active evaluation. This is ngspice's bypass reference, not the
previous iterate, so slow drift accumulates until it trips.

| Deck | Evals | Model instances | Median active | p10 / p90 | Mean | Evals under 20% active |
|---|---|---|---|---|---|---|
| scaling_inverter_chain_4k | 4,705 | 8,000 | 0.5% | 0.1 / 1.1% | 0.5% | 100% |
| scaling_inverter_chain_256 | 4,732 | 512 | 6.6% | 2.0 / 10.9% | 6.4% | 100% |
| scaling_parallel_inverters_2000 | 1,314 | 4,000 | 0% | 0 / 100% | 26.9% | 73% |
| bench_tran_fourbitadder | 124 | 288 | 30.6% | 2.8 / 61.1% | 32.0% | 44% |
| vacask_ring | 63,841 | 18 | 100% | 66.7 / 100% | 91.6% | 0.2% |
| vacask_mul | 1,018,425 | 4 | 50% | 0 / 100% | 45.0% | 48% |
| bench_ngspice_mosamp | 200,688 | 27 | 0% | 0 / 0% | 1.2% | 99% |
| bench_ngspice_mosmem | 332 | 12 | 8.3% | 0 / 91.7% | 34.8% | 50% |
| bench_ngspice_schmitt | 4,057 | 4 | 0% | 0 / 50% | 12.4% | 77% |

**Verdict: build bypass, host first.** The §7.3 gate (median active under
30% on the chains) passes by a wide margin: 0.5% on the 4k chain and 6.6%
on the 256 chain. On the 4k chain, the deck that motivated this, a
bypass that skips latent instances would evaluate about one MOSFET in
200. The adder sits right at the 3× line, and the ring is always active,
as expected. The parallel inverters are latent between edges and fully
active on them, which suits bypass and not multirate. The next test is
correctness, not headroom: a host bypass behind a pin, with §7.3's
first-order stamp-error bound, gated on the full corpus. GPU compaction
and multirate wait for that result.

### 9.3 Internal nodes (§7.2)

For every non-final Newton iterate, operating points included: the kind
of unknown with the largest step. "Scaled" ranks by |dx|/(reltol·|x| +
atol), which is what decides convergence. "Raw" ranks by |dx| alone, which
is what the `ZP_OPDBG` trace prints and which mixes volts with amperes.
Internal means unnamed and not a current row: a device's prime or
internal node.

| Decks | Non-final iterates | Scaled: named / internal / current | Raw: named / internal / current |
|---|---|---|---|
| convergence/ (31, all OP) | 841 | 79.1 / 8.6 / 12.4% | 86.1 / 11.3 / 2.6% |
| op/ (50) | 186 | 38.7 / 25.3 / 36.0% | 61.8 / 35.5 / 2.7% |
| stress/, transient | 2,576,266 | 31.5 / 19.5 / 49.1% | 69.2 / 28.8 / 2.0% |
| tran/, transient | 459,295 | 8.8 / 0.3 / 91.0% | 80.4 / 0.8 / 18.8% |

Decks where internal unknowns lead most often (scaled): `op/device_b3soidd`
80% (30 iterates), `convergence/bench_mos_series_r` 66%, `vacask_ring` 53%,
`vacask_graetz` 40%, `bench_tran_fourbitadder` 38%, `bench_ngspice_schmitt`
35%. Only 8 of the 86 decks with at least 20 non-final iterates cross 20%.

**Verdict: demote below rank 8, with one narrow exception.** The §7.2 gate
fails where it was set: on `convergence/`, internal nodes lead 8.6% of
iterates (11.3% by raw step), so terminal coupling, not internal lag,
drives the hard operating points. `op/` reaches 25%, but on 186 iterates
from single-device decks. The exception is the series-resistance regime
the idea was built for: `vacask_ring` (PSP103, 3.05 iterations per step),
`vacask_graetz` and `bench_mos_series_r`. A host prototype on those three
decks alone is the better test. It is only worth running if §9.1's
modified Newton leaves the ring at 3 iterations per step.

### 9.4 MATEX routing (§7.8)

Every linear transient deck (R, C, L, K and independent sources only)
run as `.tran` and with its `.tran` card rewritten to `.matex tstep
tstop`. Accuracy is the harness metric: our waveform interpolated at the
oracle's accepted times, worst err/(atol + rtol·|ref|) over every checked
column, so 1 is the pass line. Cost is callgrind instructions (Ir) for one
run. `stress/scaling_resistor_grid_100x100` is `.op` only and has no
transient to route.

| Deck (selected rows) | Worst err/tol, `.tran` | Worst err/tol, `.matex` | Ir `.matex` / `.tran` |
|---|---|---|---|
| scaling_rc_ladder_100k | 1.7e-7 | 965 | 2.12 |
| scaling_rc_ladder_1k | 1.7e-7 | 965 | 2.04 |
| vacask_rc | 5.9e-7 | 54 | 0.82 |
| bench_medium_rc_ladder_50 | 1.4e-5 | 89,080 | 3.15 |
| bench_tran_rc_pulse | 4.5e-8 | 2,058 | 0.80 |
| bench_digital_buffer_rc | 6.0e-8 | 673 | 0.81 |
| bench_digital_rc_filter_chain, exp_source, sffm_source, device_kinduc | ≤ 1.3e-3 | 3 to 2,788 | |
| sine, sine_offset_phase | 3.9e-3, 7.8e-3 | 3.4e-11, 2.9e-13 | 0.67, 0.67 |
| pwl_triangle, output_start_time | 1.6e-12, 3.9e-3 | 2.1e-12, 4.4e-11 | 0.65, 0.66 |
| finite_rise_positive, rc_pulse_history_trap | 1.9e-2, 1.9e-2 | 5.0e-10, 1.6e-10 | 0.80, 0.78 |
| rc_sinusoidal_startup, device_inductor, device_vsource | ≤ 1.4e-4 | ≤ 6.3e-5 | 0.85, 0.65, 0.67 |
| 14 `uic` decks (`ic_*`, `rc_discharge_*`, `lc_energy_*`) | ≤ 0.59 | 250 to 1,992 | |

On the two ladders, five alternating runs each (load 11 rising to 97):
the 100k ladder took 5.67 s wall / 5.24 s CPU as `.tran` and 8.19 s /
7.77 s as `.matex`, and the 1k ladder 0.046 s and 0.076 s. A first
five-run pass at load 75 to 120 showed the reverse on the 100k ladder,
so treat the earlier wall medians as noise; the Ir ratios are the record.

The failures are real, not an output-density effect. On
`bench_medium_rc_ladder_50`, `.matex` puts v(n3) at −0.178 V at t = 1 ns,
in the middle of a 1 ns input edge, where the oracle has 3.6e-14 V. Every
pulse-driven RC deck fails the same way. `.matex` also ignores `.ic` and
`uic` and starts from the operating point, so the `uic` decks cannot be
routed at all.

**Verdict: drop the routing rule.** On the decks the rule was meant for
(the RC ladders and pulse-driven meshes), `.matex` is up to 3× more work
and fails the oracle by 50 to 89,000×. It is exact and about a third
cheaper on smooth sources (sine, PWL, finite rise), but those decks are
already cheap. Revisit after `.matex` handles a fast source edge and
`uic`; until then detection would only route decks to a slower, wrong
answer.

### 9.5 f32 planes (§7.5)

`ESPICE_F32_PLANES=1` rounds `g_vals` and `c_vals` through f32 after every
host Newton stamp; rhs and q stay f64, and `Circuit.eval` (used for
linearizations) is untouched. Full corpus, same build, flag off then on.

| | Flag off | Flag on |
|---|---|---|
| Corpus | 598 / 616 (failing set identical to `cur-decks.txt`) | 596 / 616 |
| New failures | | `disto/bench_disto_bjt_ce` (3rd-harmonic i(vcc) 1.35% off, rtol 1e-3), `stress/vacask_graetz` (TimestepTooSmall) |
| Newton iterations, whole corpus | 7,472,838 | 5,486,139 (graetz aborts early) |
| Newton iterations without graetz | 5,472,814 | 5,485,108 (+0.22%) |
| Decks whose iteration count moved | | 58: 44 up, 14 down |

Largest increases: `multi_analysis/device_vbic_ce_amp` 224 → 579
(non-converged solves 1 → 5, still passes), `reference/bridge_capacitor_transient`
+16%, `vacask_ring` +7%. Several hard OPs improved:
`convergence/bench_mos_latch_ladder` −41%, `dc/device_vbic_temp` −33%.

**Verdict: needs a better test.** Where Newton converges, an f32 Jacobian
is nearly free (+0.22% iterations, the rate argument of §7.5 holds). But
the pass set shrinks by two, for two different reasons, and both need a
guard before a GPU version. `vacask_graetz` is the ill-conditioned case
§7.5 predicted: the diode bridge no longer converges, so the guard is
f64 fallback on a Newton failure, not only on a pivot check. `disto_bjt_ce`
is subtler, because disto linearizes with `Circuit.eval` and never sees an
f32 plane. The f32 Jacobian moves the converged OP within reltol, and the
third-harmonic finite difference amplifies that past the deck's 1e-3.
Neither this census nor any other CPU run can measure the payoff (bus
bytes), so the next test is §5 E1's sync census on the GPU decks, with
f32 download and f64 fallback, gated on the full corpus.

### 9.6 What changes in the ranking

Modified Newton stays first, but the census moves its value from the
iterate-0 acceptance to the lagged LU on the chain, ring and adder decks.
Bypass stays second and now has a number: 0.5% of the 4k chain's
MOSFETs are active per evaluation. Nonlinear elimination drops below rank 8
except as a three-deck prototype. MATEX routing is dropped until `.matex`
handles fast edges and `uic`. Mixed precision stays at rank 5, pending the
GPU measurement and an f64 fallback.

## 10. Retired experiment: modified Newton (§7.1)

**Status: retired, not on `main`.** The code is commit `29ac189` on branch
`worktree-agent-aba74880aa128df91` (also kept as branch
`retired/native-modified-newton`), measured on top of `29ae485`. It added a
`--solver=conformant|native` switch, a matching C API field and
`converger.modifiedNewton`. None of these exist on `main`. The experiment
was retired under the proof rule: it is not a net win, and it fails 9 decks
the conformant mode passes.

### 10.1 The constraint it found: the oracles encode ngspice's Newton truncation

This finding binds any future GPU-native mode, whatever its mechanism.

ngspice publishes x_k, the last linearization point, once the step x_k+1 − x_k
is within one Newton tolerance. It does not publish the more accurate x_k+1.
A throwaway build of the conformant Newton that published x_k+1 instead
(same iterates, same time grid, one step closer to the root) fails 10 corpus
decks that pass today. Nine of them are the decks the modified-Newton mode
failed, and its values match that mode's to three or four digits:

| Deck | Worst row, modified Newton | Same row, conformant publishing x_k+1 |
|---|---|---|
| `tran/bench_bypass_idle_ladder` | i(vin) −1.06899e-4 (oracle −1.06460e-4) | −1.06902e-4 |
| `tran/bench_ngspice_schmitt` | v(6) −0.22191 (oracle −0.22334) | −0.22154 |
| `tran/bench_tran_fourbitadder` | i(vin4b) −5.2463e-6 (oracle −5.2081e-6) | −5.2492e-6 |
| `tran/bench_tline_ltra1_1_line` | i(vs) 1.9548e-8 (oracle 1.7764e-8) | 1.9568e-8 |
| `tran/device_mos1_large_signal` | i(vdd) −8.7688e-8 (oracle −8.7157e-8) | −8.7666e-8 |
| `stress/scaling_parallel_inverters_100` | v(out3) 1.8294e-4 (oracle 1.7974e-4) | 1.8291e-4 |
| `multi_analysis/bench_ngspice_rca3040` | v(1) 9.5273e-2 (oracle 9.5585e-2) | 9.5276e-2 |
| `multi_analysis/bench_ngspice_rtlinv` | v(2) row 113, 0.13801 (oracle 0.13843) | fails at row 109 |
| `tran/device_mos6_simpleinv` | v(11) 0.376 (oracle 0.914), an edge moved in time | fails, i(vin) row 92 |

The tenth, `reference/diode_reverse_recovery`, fails only in the x_k+1
build. The x_k/x_k+1 difference is up to one Newton tolerance per step.
Trap does not damp it, and it lands on quantities with cancellation, such
as a source current through a small resistor.

So these oracles check ngspice's answer *including* its per-step Newton
error, at rtol 3e-3. A solver that is more accurate per step than ngspice
fails them, and no convergence-test setting fixes that. §6's contract,
"the pass set must be at least today's", cannot hold for any mode that
changes the published iterate, the Newton test or the time grid on these
decks. A future GPU-native mode needs one of:

- a gate that compares against a tighter reference (for example ngspice at
  reltol 1e-6) on these decks rather than ngspice's default-tolerance
  output;
- an explicit, recorded exemption list for decks shown to fail the
  x_k+1 build;
- or a mechanism that leaves the Newton test, the published iterate and
  the grid alone, as bypass (§7.3) can.

### 10.2 What was built

The mode swapped `converger.run` for `modifiedNewton` inside `tran.simulate`
only (`.tran`, `.four` and the operating point's pseudo-transient rung).
Every other Newton solve stayed conformant.

- The LU of G + ag0·C was kept across steps and refactored after 20 solves,
  when |ag0/ag0_LU − 1| > 0.3, after a failed solve, when an iterate
  contracted by less than 0.3, or on a non-finite step.
- Acceptance was CVODE's rate test, rate · scaled step ≤ 0.03, the rate
  decaying by at most CRDOWN = 0.3 per iterate and starting at 1 in every
  solve. Iterate 0 could be accepted when its own scaled step was ≤ 0.03.
  The corrected iterate x_k+1 was published.
- Full Newton that stopped contracting (fresh LU, rate ≥ 0.9, scaled step
  < 1) fell back to NIiter's delta test. `vacask_graetz` needed this: at
  t = 0.746 s its bridge cycles at a scaled step of 0.116, which a 0.03
  test never accepts.
- Device limiting, the residual gate, device convergence, state staging and
  MODEINITPRED's linear predictor were ngspice's.

The conformant path stayed byte-identical on all 616 decks. Native mode
passed 594 of 616 (`--backend cpu`, oracle tolerances) against conformant's
603: the 13 conformant failures plus the 9 decks of §10.1.

### 10.3 Measurements

Counts are per transient attempt, from `ZP_TRAN_STATS` plus a numeric
factorization counter on `direct.Solver` (calls the unchanged-values bypass
skips are not counted). Cost is callgrind Ir for one run, ReleaseFast,
`-Dgpu=false`, `--backend cpu`, on a shared machine. The last two columns
are the slow-rate fallbacks §7.1 proposed in place of a refactor:
GMRES(10) on the freshly assembled J, right-preconditioned by the stale LU,
to relative residual 1e-3 (refactor when it fails), and Anderson(1) mixing
over the chord iterates (refactor on a second slow iterate).

| Deck | Newton iterations per attempt, conformant / native | Factors per attempt | Ir conformant (1e9) | Ir native / conformant | GMRES fallback | Anderson fallback |
|---|---|---|---|---|---|---|
| `scaling_inverter_chain_256` | 3.98 / 4.84 | 3.982 / 1.760 | 3.86 | 1.11 | 1.19 | 1.27 |
| `scaling_inverter_chain_4k` | 3.98 / 4.83 | 3.981 / 1.752 | 62.19 | 1.10 | 1.17 | 1.26 |
| `scaling_parallel_inverters_100` | 2.23 / 1.82 | 1.679 / 0.316 | 0.46 | 0.85 | 0.86 | 0.87 |
| `scaling_parallel_inverters_2000` | 2.24 / 1.85 | 1.693 / 0.323 | 9.31 | 0.84 | 0.86 | 0.87 |
| `scaling_rc_ladder_1k` | 2.00 / 2.33 | 0.191 / 0.174 | 0.11 | 1.06 | 1.07 | 1.06 |
| `scaling_rc_ladder_100k` | 2.00 / 2.33 | 0.191 / 0.174 | 10.07 | 1.06 | 1.06 | 1.06 |
| `vacask_graetz` | 2.00 / 1.16 | 2.000 / 0.049 | 16.04 | 0.55 | 0.56 | 0.56 |
| `vacask_mul` | 2.04 / 2.51 | 2.037 / 0.417 | 8.40 | 0.94 | 1.11 | 0.97 |
| `vacask_rc` | 2.00 / 1.01 | 0.008 / 0.007 | 4.47 | 0.67 | 0.68 | 0.68 |
| `vacask_ring` | 3.05 / 5.49 | 3.049 / 0.969 | 28.35 | 1.54 | 1.65 | 1.67 |
| `bench_ngspice_mosamp` | 2.03 / 2.20 | 2.027 / 0.050 | 20.35 | 0.97 | 0.97 | 0.97 |
| `bench_ngspice_schmitt` | 2.01 / 1.43 | 2.010 / 0.074 | 0.11 | 0.71 | 0.72 | 0.72 |
| `bench_tran_fourbitadder` | 2.14 / 3.19 | 2.138 / 0.379 | 0.17 | 1.14 | 1.18 | 1.16 |

Factors per attempt fell 2 to 40 times on every nonlinear deck, as §9.1
predicted. Newton iterations did not follow. They fell where iterate 0
passes (quiescent decks: graetz, `vacask_rc`, schmitt, the parallel
inverters) and rose where every step moves (chains +22%, ring +80%, adder
+49%). On the chains a factor is about 12% of an iteration's cost (fitting
Ir against the two count sets gives 0.70 M Ir per evaluation and solve and
0.10 M per factor), so the saved factors could not pay for the extra
evaluations. The mode won on factor-heavy and quiescent decks (0.55 to
0.97) and lost on evaluation-bound, always-active ones (1.06 to 1.54), the
decks §9 named as the targets.

### 10.4 What didn't work

- **GMRES and Anderson fallbacks.** Both cut factors further on the chains
  and the ring (GMRES: 1,022 factors on the 256 chain instead of 2,112, at
  6,762 Krylov steps) but never cut Newton iterations, and each cost more
  Ir than a plain refactor on 12 of the 13 decks (tie on `vacask_rc`).
- **A 0.1 acceptance coefficient** (§7.1's value). `scaling_rc_ladder_1k`
  and `_100k` fail: i(vin) sits about 1e-8 A off on the whole decaying
  tail, the size of a 0.1-tolerance error per step that trap carries along.
  Carrying CVODE's rate estimate across steps failed the same decks, since
  a rate learned under one ag0 then accepted iterate 0 under another.
- **Relaxing iterates past 0 to 0.3**, tried together with a refresh at the
  start of every solve after a slow one. It saved 12 to 21% of iterations
  on the chains and the ring and added 6 failures: both RC ladders,
  `vacask_mul`, `bench_bypass_burst_clock`, `bench_bypass_gated_branch`,
  `bench_digital_clamp`.
- **Quadratic predictor** (Lagrange through the last three accepted points,
  trap steps only). It cut `vacask_mul` from 1.26 M to 0.59 M iterations
  and from 209 k to 26 k factors, and mosamp, schmitt and the adder by 8 to
  15%. It failed `bench_power_buck_open` (i(l1) 0.45% off) and `vacask_mul`
  (i(vs) 0.5% off) at every coefficient tried (0.003 to 0.1), and moved
  `vacask_mul`'s time grid from row 9 on. It lacked a guard for points
  straddling a source edge.
- **No stall fallback.** `vacask_graetz` ends in TimestepTooSmall.

### 10.5 Conclusion

A lagged LU saves factors, but on the decks that motivated the GPU-native
work (chains, ring, adder) the cost is device evaluation, and chord
iterations add evaluations. Bypass (§7.3) is the next candidate: §9.2 found
0.5% of the 4k chain's MOSFETs active per evaluation, so it attacks that
cost directly. It leaves the Newton test and the published iterate as
ngspice has them, which §10.1 shows the corpus requires, though its stamp
error still has to pass the same gate. If modified Newton is revisited, it
should come after bypass, with the quadratic predictor's edge guard and a
gate that settles §10.1 first.

## Sources

Code, read at `fa9f0b4` unless marked: `src/solver/converger.zig` (`newton`,
`finalizeStep`, `jfnk`, `run` and its direct-vs-JFNK table),
`src/solver/{gmres,direct,bbd,lane_lu}.zig`, `src/analysis/gpu.zig` (`main`
and `ee66e0b`: `Cost`, `Prof`), `src/analysis/Circuit.zig` (`GpuHook`,
`eval`, `evalQ`, `applyLimits`), `src/analysis/tran/tran.zig`,
`src/analysis/dc/op.zig`, `src/analysis/sweep/lanes.zig`,
`src/device/eval.zig` (`gpuEligible`). VerA ABI 5 design rev 4.1 (VerA
session notes, not in this repo). GPU status notes and `gbase.txt` for
`ee66e0b` (session notes).

Papers and documentation:

Part II additions:

- SUNDIALS CVODE Newton-matrix update rules and convergence test. <https://sundials.readthedocs.io/en/latest/cvode/Mathematics_link.html>
- Hairer, Wanner. Stiff differential equations solved by Radau methods. J. Comput. Appl. Math. 111, 1999. <https://www.sciencedirect.com/science/article/pii/S037704279900134X>
- Steihaug, Wolfbrandt. An attempt to avoid exact Jacobian and nonlinear equations in the numerical solution of stiff differential equations. Math. Comp. 33, 1979. DOI 10.1090/S0025-5718-1979-0521273-8
- Ye, Dong, Li, Nassif. MAPS: multi-algorithm parallel circuit simulation. ICCAD 2008. <https://www.cecs.uci.edu/~papers/iccad08/PDFs/Papers/01D.1.pdf>
- Dong, Li, Ye. WavePipe: parallel transient simulation of analog and digital circuits on multi-core shared-memory machines. DAC 2008. <https://ieeexplore.ieee.org/document/4555816>
- Rabbat, Sangiovanni-Vincentelli, Hsieh. A multilevel Newton algorithm with macromodeling and latency for the analysis of large-scale nonlinear circuits in the time domain. IEEE Trans. Circuits Syst. 26, 1979. <https://ieeexplore.ieee.org/document/1084693/>
- Dolean, Gander, Kheriji, Kwok, Masson. Nonlinear preconditioning: how to use a nonlinear Schwarz method to precondition Newton's method (RASPEN). SIAM J. Sci. Comput. 38, 2016. <https://arxiv.org/abs/1605.04419>
- Gear, Wells. Multirate linear multistep methods. BIT 24, 1984. <https://link.springer.com/article/10.1007/BF01934907>
- Günther, Kværnø, Rentrop. Multirate partitioned Runge-Kutta methods. BIT 41, 2001. <https://link.springer.com/article/10.1023/A:1021967112503>
- Bartel, Günther. A multirate W-method for electrical networks in state-space formulation. J. Comput. Appl. Math. 147, 2002. <https://www.sciencedirect.com/science/article/pii/S0377042702004764>
- Verhoeven, Beelen, El Guennouni, ter Maten, Mattheij, Tasić. Stability analysis of the BDF slowest-first multirate methods. Int. J. Comput. Math. 84, 2007. <https://www.tandfonline.com/doi/full/10.1080/00207160701458641>; Verhoeven et al. Automatic partitioning for multirate methods. SCEE 2006. <https://link.springer.com/chapter/10.1007/978-3-540-71980-9_24>
- Saleh, Kleckner, Newton. Iterated timing analysis in SPLICE1. ICCAD 1983 (citation from <https://www2.eecs.berkeley.edu/Pubs/Faculty/newton.html>; paper not opened).
- Newton, Sangiovanni-Vincentelli. Relaxation-based electrical simulation. IEEE TCAD 3, 1984. <https://ieeexplore.ieee.org/document/1270089/>
- Günther, Hoschek, Rentrop. ROW methods adapted to electric circuit simulation packages (CHORAL). J. Comput. Appl. Math., 1997. <https://www.sciencedirect.com/science/article/pii/S0377042797000435>
- Utkarsh et al. Automated translation and accelerated solving of differential equations on multiple GPU platforms (DiffEqGPU). CMAME 419, 2024. <https://arxiv.org/html/2304.06835v3>
- Lienen, Günnemann. torchode. 2022. <https://arxiv.org/abs/2210.12375>
- Zhou et al. GPU-based batch LU-factorization solver for concurrent analysis of massive power flows. IEEE Trans. Power Syst. 32, 2017. <https://ieeexplore.ieee.org/document/7837762/>
- Wang, Wende-von Berg, Braun. Fast parallel Newton-Raphson power flow solver for large number of system calculations with CPU and GPU. SEGAN, 2021. <https://arxiv.org/abs/2101.02270>
- Zhuang, Weng, Lin, Cheng. MATEX. DAC 2014. <https://arxiv.org/abs/1511.04519>; Zhuang et al. Simulation algorithms with exponential integration for time-domain analysis of large-scale power delivery networks. IEEE TCAD, 2016. <https://arxiv.org/abs/1505.06699>
- Zhuang, Yu, Kang, Wang, Cheng. An algorithmic framework for efficient large-scale circuit simulation using exponential integrators. DAC 2015. <https://arxiv.org/abs/1511.04515>
- ORNL, parareal for power-system dynamics (numbers from an excerpt only). <https://www.osti.gov/biblio/1265734>
- Verschelde. GPU Newton for polynomial homotopy. <https://homepages.math.uic.edu/~jan/gpunewton2.pdf>

- Knoll, Keyes. Jacobian-free Newton-Krylov methods: a survey. J. Comput. Phys. 193, 2004. <https://doi.org/10.1016/j.jcp.2003.08.010>
- Dembo, Eisenstat, Steihaug. Inexact Newton methods. SIAM J. Numer. Anal. 19, 1982. <https://doi.org/10.1137/0719025>
- Eisenstat, Walker. Choosing the forcing terms in an inexact Newton method. SIAM J. Sci. Comput. 17, 1996. <https://users.wpi.edu/~walker/Papers/forcing_terms,SISC_17,1996,16-32.pdf>
- Walker, Ni. Anderson acceleration for fixed-point iterations. SIAM J. Numer. Anal. 49, 2011. <https://doi.org/10.1137/10078356X>
- Thornquist, Keiter, Hoekstra, Day, Boman. A parallel preconditioning strategy for efficient transistor-level circuit simulation. ICCAD 2009. <https://dl.acm.org/doi/10.1145/1687399.1687477>
- Rajamanickam, Boman, Heroux. ShyLU. IPDPS 2012. <https://ieeexplore.ieee.org/document/6267865/>; Xyce Users' Guide 7.8. <https://xyce.sandia.gov/files/xyce/Xyce_Users_Guide_7.8.pdf>
- Davis, Palamadai Natarajan. Algorithm 907: KLU. ACM TOMS 37, 2010. <https://doi.org/10.1145/1824801.1824814>
- Chen, Wang, Yang. NICSLU. IEEE TCAD 32, 2013. <https://ieeexplore.ieee.org/document/6416098/>
- He, Tan, Wang, Shi. GPU-accelerated parallel sparse LU factorization for fast circuit analysis. IEEE TVLSI 24, 2016. <https://ieeexplore.ieee.org/document/7095579/>
- Peng, Tan. GLU3.0. arXiv:1908.00204. <https://arxiv.org/abs/1908.00204>
- Zhao, Feng. SPICE-accurate nonlinear circuit simulation with on-the-fly support-circuit preconditioners. DAC 2012. <https://ieeexplore.ieee.org/document/6241645/>
- Li, Shi. SILCA. IEEE TCAD 25, 2006. <http://labs.ece.uw.edu/mscad/shi/Papers/TCAD_2006_June_1.pdf>
- Gulati, Croix, Khatri, Shastry. Fast circuit simulation on graphics processing units. ASP-DAC 2009. <https://dl.acm.org/doi/abs/10.5555/1509633.1509733>
- Kapre, DeHon. Single-precision SPICE model evaluation on FPGA, GPU, Cell and multi-core. FPL 2009. <https://ic.ese.upenn.edu/abstracts/spice_fpl2009.html>
- Lannutti et al. CUSPICE. MOS-AK 2014. <https://www.mos-ak.org/venice_2014/publications/T_2_Lannutti_MOS-AK_2014.pdf>; <https://ngspice.sourceforge.io/cuspice.html>
- Empyrean ALPS-GT. ICCAD 2020. <https://dl.acm.org/doi/10.1145/3400302.3415762>
- Synopsys, PrimeSim SPICE on GPU. <https://www.synopsys.com/blogs/chip-design/accelerating-accuracy-primesim-spice-gpu.html>
- Sundaralingam et al. cuRobo (parallel line search). arXiv:2310.17274. <https://arxiv.org/abs/2310.17274>
- Gaedke-Merzhäuser, van Niekerk, Schenk, Rue. Parallelized INLA. arXiv:2204.04678. <https://arxiv.org/abs/2204.04678>
- Roychowdhury, Melville. Global DC convergence via homotopy. IEEE TCAD 25, 2006. <https://doi.org/10.1109/TCAD.2005.852461>
- Kelley, Keyes. Convergence analysis of pseudo-transient continuation. SIAM J. Numer. Anal. 35, 1998. <https://doi.org/10.1137/S0036142996304796>
- O'Leary. The block conjugate gradient algorithm. Linear Algebra Appl. 29, 1980. <https://doi.org/10.1016/0024-3795(80)90247-5>
- Hoemmen. Communication-avoiding Krylov subspace methods. UCB/EECS-2010-37. <https://www2.eecs.berkeley.edu/Pubs/TechRpts/2010/EECS-2010-37.html>
- Carson. Communication-avoiding Krylov subspace methods in theory and practice. UCB/EECS-2015-179. <https://www2.eecs.berkeley.edu/Pubs/TechRpts/2015/EECS-2015-179.html>
- Grigori, Moufawad, Nataf. Enlarged Krylov subspace CG. SIMAX 37, 2016. <https://doi.org/10.1137/140989492>
- Lions, Maday, Turinici. Parareal. C. R. Acad. Sci. Paris 332, 2001. <https://doi.org/10.1016/S0764-4442(00)01793-6>
- Gander, Vandewalle. Analysis of parareal. SIAM J. Sci. Comput. 29, 2007. <https://doi.org/10.1137/05064607X>
- Falgout, Friedhoff, Kolev, MacLachlan, Schroder. MGRIT. SIAM J. Sci. Comput. 36, 2014. <https://doi.org/10.1137/130944230>
- Lelarasmee, Ruehli, Sangiovanni-Vincentelli. Waveform relaxation. IEEE TCAD 1, 1982. <https://doi.org/10.1109/TCAD.1982.1270004>
- Gander, Kulchytska-Ruchka, Niyonzima, Schöps. Parareal for discontinuous sources. SIAM J. Sci. Comput. 41, 2019. <https://arxiv.org/abs/1803.05503>
- Bolten, Friedhoff, Hahne, Schöps. MGRIT for an electrical machine. arXiv:1912.03106. <https://arxiv.org/abs/1912.03106>
- MGRIT-based parallel-in-time EMT simulation. Energies 15(21), 2022. <https://doi.org/10.3390/en15217874>
- Kashi et al. Batched sparse iterative solvers on GPU (Ginkgo). IPDPS 2022. <https://doi.org/10.1109/IPDPS53621.2022.00024>
- NVIDIA cuSOLVER (`csrqrsvBatched`, one pattern, values back to back). <https://docs.nvidia.com/cuda/cusolver/index.html>; cuDSS uniform batch. <https://docs.nvidia.com/cuda/cudss>
- Cai, Keyes. Nonlinearly preconditioned inexact Newton (ASPIN). SIAM J. Sci. Comput. 24, 2002. <https://doi.org/10.1137/S106482750037620X>
- ngspice manual (ITL1/ITL4, gmin and source stepping). <https://ngspice.sourceforge.io/docs/ngspice-manual.pdf>

**Verification status.** Code facts: read directly. Paper citations: every
link was opened or seen in the publisher's or arXiv's listing by a literature
pass run for this page. The Gulati and ALPS-GT numbers came from
abstracts and excerpts where the full text was blocked; the PrimeSim blog was
read in full. We found no primary source that
states the ILU difficulties of §2.6 in one place. They are inferred from the
preconditioning pipelines of Thornquist et al. and Zhao and Feng, which exist
to work around them. No circuit-simulator use of a parallel line search or of
Broyden updates was found. All *model* numbers in §1.2 and §2 are predictions
for E1 and E2 to confirm or refute.
