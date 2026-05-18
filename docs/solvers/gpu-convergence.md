# Nonlinear convergence for a batch-evaluating GPU

**Status: research, nothing implemented.** Written against `main` at
`fa9f0b4`, with measurements from the experimental GPU work at `ee66e0b`
(not on `main`). No build, test or benchmark was run for this page: a
wall-clock benchmark held the machine. Every number marked *measured* comes
from an earlier run recorded in the sources named beside it. Every number
marked *model* is arithmetic on those measurements, and the experiments in
§5 exist to replace it.

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
each extra iteration is one more sync. Li and Shi report more than an order
of magnitude over SPICE3 on parasitic-heavy transient, where the factor
dominates. Our GPU decks are the opposite case: parallel inverters have a
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
