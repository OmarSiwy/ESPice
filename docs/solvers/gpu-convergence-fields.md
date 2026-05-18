# Batched nonlinear solving in other fields, mapped onto ESPice

**Status: research, nothing implemented.** Companion to
[gpu-convergence.md](gpu-convergence.md), which ranks the options from
circuit-simulation sources and our code. GPU-batched Newton is close to
absent from published SPICE work. This page looks at fields that already
solve stiff nonlinear ODE, DAE and algebraic systems with batched GPU
evaluation, and asks what carries over. Nothing was built or run: a
benchmark held the machine. Ideas marked **speculative** are ours, not
taken from a source, and each comes with the cheapest experiment we could
find to test it.

## 1. Our structure, and the one difference that decides most mappings

What we solve:

- **Coupled instances.** A sparse MNA Jacobian is assembled from N device
  instances, which are coupled through the nodes they share. One instance's
  Jacobian is a dense n_u × n_u block, with n_u from 4 (diode) to 32
  (hisimhv).
- **Nonlinearity.** Exponential junctions, handled by per-device voltage
  limiting (`$limit`, ngspice's `pnjlim`/`fetlim`) rather than by line
  search or trust regions.
- **Time stepping.** Many adaptive timesteps, a few Newton iterations each,
  and conformance to ngspice's iterate sequence by default.
- **Hardware split.** The GPU evaluates, the host factors.

Most GPU successes elsewhere batch **independent problems**:

- chemistry cells after operator splitting;
- N-1 power-flow contingencies;
- ODE ensembles and DEQ minibatches;
- polynomial homotopy paths.

Our device instances are not independent. A diode's current depends on the
node voltage every other device on that node also sets. So a technique that
batches independent systems maps onto one of three things here:

1. **Ensemble lanes.** Monte Carlo, corners, temperature and sweep points
   are independent problems. The mapping is direct.
2. **Instance-private unknowns.** Internal nodes are independent across
   instances once the terminal voltages are fixed. This needs an elimination
   step (§3.1).
3. **A split of the circuit.** Relaxation or waveform relaxation, which
   changes the algorithm.

The table below applies that test to each field.

| Field | What is batched | Coupling inside the batch | Nonlinear solver | GPU / host split | Our analogue |
|---|---|---|---|---|---|
| Combustion chemistry (Pele, Zero-RK, pyJac) | one small stiff ODE per cell | none (operator split) | CVODE modified Newton, lagged Jacobian | kernels on GPU, integrator logic on host (SUNDIALS) | ensemble lanes; internal-node elimination |
| Power flow, N-1 (Zhou et al.) | one Newton power flow per contingency | none | Newton, batched same-pattern LU | GPU LU and eval | ensemble lanes with GPU LU |
| Transient stability, EMT (Dinavahi) | subsystems | relaxed between subsystems | Newton + sparse LU per subsystem | all-GPU or hybrid | BBD blocks; waveform relaxation |
| Reservoir (OPM, Echelon, Tchelepi) | cells | strong (flux) | Newton with per-cell chops, localization | linear solve on GPU (OPM) | device limiting; bypass |
| ODE ensembles (DiffEqGPU, torchode) | whole trajectories | none | Rosenbrock (no Newton loop), per-lane step | one trajectory per thread | tiny-circuit Monte Carlo |
| ML implicit layers (DEQ, TorchDEQ) | minibatch samples | none | Broyden, Anderson | all-GPU | ensemble lanes; chord acceleration |
| Homotopy (HomotopyContinuation.jl, GPU path trackers) | solution paths | none | fixed-step predictor, fixed-count Newton corrector | all-GPU | OP multi-start |
| FEM matrix-free (MFEM, deal.II) | elements | assembled through shared nodes | Newton-Krylov, partial assembly | all-GPU | our staging buffer is partial assembly |
| Molecular dynamics (LINCS) | constraints | coupled, weakly | fixed-order expansion instead of iteration | all-GPU | fixed-count inner loops |

## 2. What the other fields confirm

Several findings independently support the ranking in
[gpu-convergence.md](gpu-convergence.md).

**The host keeps the control flow.** SUNDIALS keeps integrator logic on the
CPU and runs only the vector and matrix kernels on GPU-resident data (Balos
et al. 2024), because per-cell step adaptivity diverges threads. Curtis,
Niemeyer and Sung (2017) and Stone, Alferman and Niemeyer (2018) name
thread divergence from adaptive steps and iteration counts as the main GPU
bottleneck for stiff chemistry. The latter measured GPU SIMT gains of only
1.4-1.6× against 4.7-4.9× on Xeon Phi SIMD. Our split (GPU evaluates, host
decides) is the one these groups converged on.

**Same-pattern batched factorization is the batched-problem workhorse.**
Zhou et al. (2017) report up to 76× over KLU for many LU factorizations of
one power-grid topology. With batched Newton power flows they report up to
57.6× over one core on 8503 buses. That is the LaneLu idea (one pivot tape,
many value sets) running on the GPU. NVIDIA's `cusolverRfBatch` did the same
but is deprecated in favour of cuDSS, whose uniform batch reuses one analysis
for every matrix. Theseus (Pineda et al. 2022) found cuSolverRF awkward: its
contexts cannot be split and its batch size is fixed. Any GPU LU we add
should target cuDSS.

**Per-lane convergence with one global reduction.** SUNDIALS' task-local
Newton (Gardner et al. 2022) lets each task converge on its own and
communicates once, to check that all succeeded. It measured 4.2-7.9× over
global Newton-GMRES. Our planned lane mask with peel-to-scalar is the same
design.

**Lockstep lanes pay for the hardest lane.** In SUNDIALS' batched mode the
stiffest cell sets the step for its whole batch. torchode (Lienen and
Günnemann 2022) measured up to 4× more steps from joint stepping than from
per-sample stepping. For transient ensemble lanes, each lane must keep its
own dt, and so its own `SimState` (dt, t) in the kernel arguments. It must
not share a step with its neighbours.

**Amdahl sets in early.** Gulati et al. (2009) moved BSIM3 evaluation (75%
of runtime) to the GPU. The kernel ran 32-41× faster, and the whole
simulation 2.36× on average. Our bsim4 numbers show the same shape: the
kernel is 85% of a GPU iteration today, and after ABI 5 the rest dominates.

**Mixed precision in the Jacobian is already here.** Gulati et al. found
single precision adequate for model evaluation, and DiffEqGPU runs its
ensembles in float32. The fixed point of Newton depends on F alone, so a
lower-precision J costs convergence rate, not accuracy. ESPice already does
this: `gpuJacFloat` gives the GPU kernel f32 derivative lanes with an f64
residual. Commit `4853197` measured `parallel_inverters_2000` at 927 → 799 ms,
1356 → 1354 Newton iterations, and every fixture raw byte-identical on the CPU
path. §3.4 takes it one step further.

**Per-cell step chopping is limiting.** Wang and Tchelepi (2013) chop a
reservoir cell's Newton update at physics-derived trust-region boundaries.
That is `pnjlim`/`fetlim` by another name, and it confirms that per-instance
limiting is cheap on wide hardware. Younis, Tchelepi and Aziz (2010) fall
back to continuation in the timestep, which is our dt/8 retry.

## 3. Ideas that carry over

### 3.1 Nonlinear elimination of instance-private unknowns (speculative)

**Sources.** Nonlinear elimination (Lanzkron, Rose and Wilkes 1996; Cai and
Li 2011): solve the subproblem that holds the strong local nonlinearity
first, then take the global Newton step. ASPIN (Cai and Keyes 2002) and
PETSc's composed solvers (Brune et al. 2015) generalize it to subdomains.
Chemistry's per-cell implicit solve is the extreme case, where every cell is
a subdomain. LINCS (Hess 2008) and GPU homotopy trackers (Plecnik et al.
2020) use a fixed number of inner steps so that every thread runs the same
instruction stream.

**Mapping.** Internal nodes belong to exactly one instance. Examples are the
diode's RS node, the MOSFET's source and drain prime nodes, and bsim4's gate
and body network. They make up much of n_u. With the terminal voltages held,
each instance's internal equations form an independent small system, which
is the chemistry cell. Inside one eval launch each thread would:

1. evaluate the core;
2. take j Newton steps on its internal unknowns only, using the dense local
   Jacobian the AD already produced (at most n_u ≤ 32 wide) and applying
   `$limit` inside;
3. write the updated internal voltages back to x;
4. stamp as usual.

j is fixed at 2 or 3, with no convergence loop, so warps stay uniform. The
global Newton step then starts with the internal residuals near zero, and
the host LU sees the same pattern as today. Nothing crosses the frozen
boundary: the tapes, the PODs and the plane layout are unchanged. The kernel
additionally writes n_internal doubles of x, which are private to the
instance, so there is no write conflict.

**Why it could pay.** The work is on-device evaluations that need no round
trip, exactly the trade the question asked for. The series-resistance
problem is the classic cause of extra Newton iterations: a junction behind
an internal node whose voltage lags. The elimination removes that lag
locally.

**Why it might not.** Circuit Newton is usually limited by the coupling
between terminals (feedback, latches), which the elimination does not touch.
It also changes the iterate sequence, so it is opt-in only, even though the
fixed point is the same. And the core has to be evaluated j + 1 times per
launch, which is costly for bsim4 before ABI 5.

**Second level.** The same idea applies to BBD blocks. A subcircuit
instance's internal nodes form a block whose border is the coupling nodes,
and `bbd.zig` already factors blocks densely (at most 64 wide, at least 8
blocks, a border of at most 512). A block Newton with the border fixed is
batched dense work, MAGMA's batched LU shape. The host then solves only the
border Schur system. That is ASPIN with the subcircuit as the subdomain.

**Cheap experiment (no code).** `ZP_OPDBG` already prints, for every Newton
iterate, the unknown with the largest step and its name. Internal unknowns
print an empty name, and `current_row` separates them from branch currents.
Run the corpus's `convergence/` and `op/` decks, plus
`stress/scaling_inverter_chain_256` and the gpu-gen mos1 and bsim4 decks, and
count the non-final iterations whose largest step is on an internal node.
If internal nodes rarely lead, drop the idea. If they often lead, the next
step is a host-only prototype: j inner steps inside `DeviceBatch.eval` behind
an env flag, measured by Newton iterations per solve and per step.

### 3.2 Localization with the staging buffer as a contribution cache (speculative)

**Sources.** Jiang (2020) solves each reservoir Newton iteration only on an
active set: the cells whose last update exceeded a cutoff, and their
neighbours. The active set holds 6.5-10% of cells, the work falls 13-16×, and
the iteration count barely moves (159 against 156). SPICE bypass is the
older version of the same idea, at the device level.

**Mapping.** The deterministic scatter in `gpu.zig` gives every stamp
contribution its own staging cell, then reduces the cells in a fixed order.
If a launch evaluates only the instances whose gathered voltages moved more
than reltol·|v| + vntol, and leaves the other staging cells as they were,
then the reduction reproduces the planes from the cached contributions with
no other change. The staging buffer is already the cache that bypass needs.
Launching only the active instances needs one compaction (a scan over a flag
per instance) and an index list.

**Why it could pay.** Digital-style and clock-mesh decks have most devices
idle at any moment. Parallel-inverter decks have the opposite profile: every
inverter switches at once.

**Why it might not.** It changes results unless the skip threshold is
exactly zero, so it is opt-in only. ngspice's bypass semantics would need
checking before it could be anything else. It also saves nothing while the
GPU runs a single partial wave: at today's bsim4 register use, 4,000
instances take two thirds of one wave, and running fewer threads does not
shorten it.

**Cheap experiment.** A host-side counter in the CPU eval path: per Newton
iteration and per step, the fraction of instances whose terminal and internal
voltages moved less than the tolerance. Decks: `stress/scaling_inverter_chain_4k`,
`stress/vacask_ring`, `stress/scaling_parallel_inverters_2000`,
`tran/bench_tran_fourbitadder`. Below about 20% active, prototype the GPU version.

### 3.3 Lagged Newton matrix with explicit triggers, and racing it (opt-in)

**Sources.**
- **CVODE** refreshes its Newton matrix only after 20 steps, when
  |γ/γ̄ − 1| > 0.3, or after a failure. It re-evaluates J at most every 50
  steps. It caps Newton at 3 iterations and tests convergence with a rate
  estimate, R·‖δ‖ < 0.1ε.
- **RADAU5** (Hairer and Wanner 1999) keeps its LU while the step ratio
  stays in a small window.
- **W-methods** (Steihaug and Wolfbrandt 1979) stay stable with a stale
  Jacobian.
- **MAPS** (Ye, Dong, Li and Nassif 2008) raced four circuit algorithms on
  four cores. Successive-chord with BE won 34.2× and 20.8× on clock meshes,
  failed to converge on an adder, and gave 3-4.5× on analog circuits. It
  synchronized for 1-2% overhead.

**Mapping.** These rules give §2.4 of the main page concrete numbers. In the
transient, the Newton matrix is G + ag0·C. Keep its LU while |ag0/ag0_LU − 1|
< 0.3 and no attempt fails. Replace the delta test with CVODE's rate-based
test, because the plain delta test overstates convergence under linear
contraction. On the GPU path this pairs with a residual-only kernel: only
n + 1 doubles come down per iteration. Anderson acceleration (Walker and Ni
2011; KINSOL) over the chord iterates can buy back part of the lost rate
with a small least-squares solve on the host.

MAPS's lesson is that the aggressive variant pays when a robust one runs
beside it. As an opt-in mode, race chord and conformant Newton on two threads
and publish whichever passes the gates first. In conformance mode that race
is pointless, because Newton's answer has to be published either way.

**Why it carries over, and where not.** Circuits give J with F, which is
CHORAL's argument for ROW methods and the reason chord is cheap here. But
our GPU decks (parallel inverters) have cheap factors, so chord pays on the
LU-bound decks (RC meshes, post-layout), which are a host question.

**Cheap experiment.** An `ESPICE_SOLVER=chord` pin in `converger.run`: skip
`factor` unless the trigger fires, and use the rate test. It is host-only, on
`stress/scaling_rc_ladder_100k`, `stress/scaling_resistor_grid_100x100`,
`stress/scaling_inverter_chain_4k` and `stress/vacask_ring`. Metric: Newton
iterations, factor count and wall time, plus the failing-set diff on the full
corpus.

### 3.4 f32 planes on the bus (speculative)

**Source.** The same mixed-precision argument as §2: J's precision affects
rate, F's affects the answer.

**Mapping.** The GPU kernel already computes derivative lanes in f32
(`gpuJacFloat`) and widens them to f64 before the scatter. The reduction
must stay f64 and ordered for reproducibility (`gpu.zig`'s Vdd-row note:
8000 contributions cancelling to 3.6e-9). But its output for g and c could
be converted to f32 at the final level and downloaded at half the bytes. rhs
and q stay f64. On `ee66e0b`'s cost model the bus is ~11 GB/s, and the g
and c planes are most of the per-iteration bytes. That matters more for
ensemble lanes (§2.2 of the main page), where each lane downloads its own
planes.

**Why it might not.** The host LU then factors f32-rounded values. That is
harmless for Newton, but the AC analyses linearize from the same planes, so
the conversion must be limited to Newton evaluations.

**Cheap experiment.** CPU-only: under an env flag, round `g_vals` and
`c_vals` through f32 after each Newton eval, then run the corpus. Compare the
failing set and the Newton counts from `ZP_TRAN_STATS`. If both hold, build
the GPU version.

### 3.5 GPU batched LU for ensemble lanes

**Sources.** Zhou et al. (2017), cuDSS uniform batch, Theseus.

**Mapping.** Step two of the main page's §2.2. Once k lanes run, each lane
downloads (2(nnz+1) + 2(n+1))·8 B of planes for the host LU. Factoring the
lanes on the GPU with one symbolic analysis keeps the planes on the device,
and only the k solution vectors come down. This departs from "every solve
runs on the host" for ensemble queries only, where the power-flow N-1 work is
a strong precedent.

**Cheap experiment.** It comes after E3 in the main page. If E3 shows bus or
host LU as the lane bottleneck, time cuDSS uniform-batch refactor and solve
on the planes E3 already produces, outside the simulator.

### 3.6 Multi-start Newton for hard operating points (opt-in)

**Sources.** HomotopyContinuation.jl and GPU path trackers (Plecnik et al.
2020: fixed step and fixed Newton count per thread; Verschelde and Yu 2015)
track many paths at once. Roychowdhury and Melville (2006) use homotopy for
industrial DC convergence.

**Mapping.** When plain Newton fails, launch k lanes from perturbed starts
(random node voltages inside the supply range, or nodeset variations) and
take any that converge.

**Why it is opt-in only.** A multistable circuit (a latch, a Schmitt
trigger) can settle on a different solution than ngspice's gmin ladder
would. Conformance needs the ladder's solution, and §2.3 of the main page
(racing the ladder's own rungs) already covers the exact version. Multi-start
could serve as a last rung before OPtran. Experiment: on the
`convergence/` decks that reach gmin stepping, record whether a 16-start
Newton finds the ladder's solution.

## 4. Ideas that do not carry over

**JFNK as a GPU technique.** The fields that use it (PDE multiphysics,
Knoll and Keyes 2004; NEK and PETSc applications) cannot afford an assembled
Jacobian. Chemistry codes went the other way: pyJac generates analytic
Jacobians, because finite-difference Jacobians cost 7-241× on the GPU (Curtis
et al. 2017). Our AD Jacobian is pyJac's answer, so the argument against JFNK
in the main page stands.

**Rosenbrock and W-methods as the default integrator.** DiffEqGPU chose them
because they have no Newton loop, so every thread does fixed work. CHORAL, a
charge-oriented ROW method, ran in Infineon's TITAN circuit simulator and did
well on oscillators (Günther, Hoschek and Rentrop 1997). But a linearly
implicit step has nowhere to apply `$limit`, so strong junction
nonlinearity is left to step-size control alone. It is also not ngspice's
integrator.

The place it fits is tiny-circuit Monte Carlo fully on the GPU. DiffEqGPU's
per-thread dense LU stops scaling past about 100 states, and it could run
thousands of samples of a small cell as one trajectory per thread. That
would be a separate opt-in analysis, not a solver mode. We have no cheap
experiment short of prototyping it outside ESPice.

**DEER and quasi-DEER** (Lim et al. 2024; Gonzalez et al. 2024). These run
Newton over the whole trajectory, with the linearized recurrence solved by a
parallel prefix scan. The scan composes dense n × n transition matrices,
which is O(n³) per step for our n of 10³ to 10⁵. The diagonal quasi-DEER
approximation throws away the MNA coupling that makes the problem stiff, and
both need a fixed time grid, not LTE control. For tiny circuits it reduces to
the ensemble case.

**Element-by-element preconditioning** (Hughes, Levit and Winget 1983). A
two-terminal device's local stamp is singular on its own, and the difficulty
of a circuit Jacobian is the global KCL coupling. Products of per-device
factors do not approximate that. There is one real correspondence: our
staging buffer is MFEM's partial assembly (unreduced per-element
contributions plus a gather map). A GPU matvec could run straight from it if
§2.6 of the main page is ever built.

**Relaxation across subsystems** (Dinavahi's instantaneous relaxation,
waveform relaxation on GPUs, Conte et al. 2016). Relaxation converges when
subsystems are weakly coupled. The strongly coupled feedback paths of analog
circuits are what defeat it. The main page already rejects it for
conformance.

**CPR-style physics splitting** (reservoir pressure/saturation). The closest
circuit analogue is to split the linear RC network from the devices, as in
Zhao and Feng's support-circuit preconditioner. That is a preconditioner for
a Krylov solve we do not run.

## 5. Effect on the ranking

- **Nonlinear elimination (§3.1)** enters as the most promising opt-in
  mode. It is ahead of chord because it spends on-device work without round
  trips, which is the trade the question asked for. It stays behind the
  three exact options, pending its zero-code experiment.
- **Chord (main page §2.4)** gets CVODE's triggers and rate test as its
  specification, and MAPS's clock-mesh result as evidence for LU-bound
  decks.
- **GPU batched LU for lanes (§3.5)** becomes the planned second step of
  ensemble lanes, targeting cuDSS.
- **f32 g/c planes on the bus (§3.4)** and **localization (§3.2)** are cheap
  to test. Their value depends on E2 (bus share) and on the activity census.
- **The JFNK and parallel-in-time verdicts are unchanged.**

## Sources

- Niemeyer, Sung. Accelerating moderately stiff chemical kinetics in reactive-flow simulations using GPUs. J. Comput. Phys. 256, 2014. <https://arxiv.org/abs/1309.2710>
- Curtis, Niemeyer, Sung. An investigation of GPU-based stiff chemical kinetics integration methods. Combust. Flame 179, 2017. <https://arxiv.org/abs/1607.03884>
- Niemeyer, Curtis, Sung. pyJac: analytical Jacobian generator for chemical kinetics. Comput. Phys. Commun. 215, 2017. <https://arxiv.org/abs/1605.03262>
- Stone, Alferman, Niemeyer. Accelerating finite-rate chemical kinetics with coprocessors. Comput. Phys. Commun. 226, 2018. <https://arxiv.org/abs/1608.05794>
- McNenly, Whitesides, Flowers. Faster solvers for large kinetic mechanisms using adaptive preconditioners (Zero-RK). Proc. Combust. Inst. 35, 2015. <https://www.osti.gov/pages/biblio/1251897>
- Balos, Gardner, Woodward, Reynolds. Enabling GPU accelerated computing in the SUNDIALS time integration library. Parallel Computing 108, 2021. <https://arxiv.org/abs/2011.12984>
- Balos et al. SUNDIALS time integrators for exascale applications with many independent ODE systems. arXiv:2405.01713, 2024. <https://arxiv.org/html/2405.01713>
- Aggarwal, Kashi, Nayak, Balos, Woodward, Anzt. Batched sparse iterative solvers for computational chemistry simulations on GPUs. ScalA@SC21. <https://www.osti.gov/biblio/1860721>
- SUNDIALS documentation: CVODE Newton-matrix update rules <https://sundials.readthedocs.io/en/latest/cvode/Mathematics_link.html>; KINSOL (line search, modified Newton, Anderson) <https://sundials.readthedocs.io/en/latest/kinsol/Mathematics_link.html>; MAGMA batched dense linear solver <https://sundials.readthedocs.io/en/latest/sunlinsol/SUNLinSol_links.html>
- Gardner, Reynolds, Woodward, Balos. Enabling new flexibility in the SUNDIALS suite of nonlinear and differential/algebraic equation solvers (task-local Newton, §6.1). ACM TOMS, 2022. <https://arxiv.org/abs/2011.10073>
- Brune, Knepley, Smith, Tu. Composing scalable nonlinear algebraic solvers. SIAM Review 57, 2015. <https://arxiv.org/abs/1607.04254>
- PETSc SNESNGMRES (after Oosterlee and Washio 2000). <https://petsc.org/release/manualpages/SNES/SNESNGMRES/>
- Lanzkron, Rose, Wilkes. An analysis of approximate nonlinear elimination. SIAM J. Sci. Comput. 17, 1996. <https://dblp.org/rec/journals/siamsc/LanzkronRW96.html>
- Cai, Li. Inexact Newton methods with restricted additive Schwarz based nonlinear elimination for problems with high local nonlinearity. SIAM J. Sci. Comput. 33, 2011 (seen in search listings; abstract not retrieved).
- Cai, Keyes. Nonlinearly preconditioned inexact Newton algorithms (ASPIN). SIAM J. Sci. Comput. 24, 2002. <https://doi.org/10.1137/S106482750037620X>
- Younis, Tchelepi, Aziz. Adaptively localized continuation-Newton method. SPE J. 15, 2010. <https://www.onepetro.org/journal-paper/SPE-119147-PA>
- Wang, Tchelepi. Trust-region based solver for nonlinear transport in heterogeneous porous media. J. Comput. Phys. 253, 2013. <https://ui.adsabs.harvard.edu/abs/2013JCoPh.253..114W/abstract>
- Jiang. Localized nonlinear solution strategies for efficient simulation of unconventional reservoirs. arXiv:2008.01539. <https://arxiv.org/abs/2008.01539>
- Qiu et al. GPU hardware and solver libraries for accelerating the OPM Flow reservoir simulator. arXiv:2309.11488. <https://arxiv.org/abs/2309.11488>
- Zhou, Bo, Chien, Zhang, Shi, Xu, Feng. GPU-based batch LU-factorization solver for concurrent analysis of massive power flows. IEEE Trans. Power Syst. 32, 2017. <https://ieeexplore.ieee.org/document/7837762/>
- Zhou, Feng, Bo et al. GPU-accelerated batch-ACPF solution for N-1 static security analysis. IEEE Trans. Smart Grid 8, 2017. <https://scholarsmine.mst.edu/ele_comeng_facwork/2662/>
- Jalili-Marandi, Dinavahi. SIMD-based large-scale transient stability simulation on the GPU. IEEE Trans. Power Syst. 25, 2010. <https://zenodo.org/records/7709072>
- Jalili-Marandi, Zhou, Dinavahi. Large-scale transient stability simulation of electrical power systems on parallel GPUs, 2012. <https://zenodo.org/records/7707159>
- Kim, Pacaud, Kim, Anitescu. Leveraging GPU batching for scalable nonlinear programming through massive Lagrangian decomposition (ExaTron). <https://arxiv.org/abs/2106.14995>
- ExaPF.jl. <https://github.com/exanauts/ExaPF.jl>
- Utkarsh, Churavy, Ma, ..., Rackauckas. Automated translation and accelerated solving of differential equations on multiple GPU platforms (DiffEqGPU). CMAME 419, 2024. <https://arxiv.org/html/2304.06835v3>
- Lienen, Günnemann. torchode: a parallel ODE solver for PyTorch. 2022. <https://arxiv.org/abs/2210.12375>
- Abdelfattah, Tomov, Dongarra. Progressive optimization of batched LU factorization on GPUs. <https://www.netlib.org/utk/people/JackDongarra/PAPERS/icl-utk-1237-2018.pdf>
- NVIDIA cuSOLVER (cuSolverRF batch, deprecated) <https://docs.nvidia.com/cuda/cusolver/index.html>; cuDSS <https://docs.nvidia.com/cuda/cudss>
- Pineda et al. Theseus: a library for differentiable nonlinear optimization. NeurIPS 2022. <https://arxiv.org/abs/2207.09442>
- Bai, Kolter, Koltun. Deep equilibrium models. NeurIPS 2019. <https://arxiv.org/abs/1909.01377>
- Bai, Koltun, Kolter. Stabilizing equilibrium models by Jacobian regularization. ICML 2021. <https://arxiv.org/abs/2106.14342>
- Geng, Kolter. TorchDEQ. arXiv:2310.18605. <https://arxiv.org/abs/2310.18605>
- Walker, Ni. Anderson acceleration for fixed-point iterations. SIAM J. Numer. Anal. 49, 2011. <https://doi.org/10.1137/10078356X>
- Hess. P-LINCS. J. Chem. Theory Comput. 4, 2008. <https://pubs.acs.org/doi/10.1021/ct700200b>
- Hughes, Levit, Winget. An element-by-element solution algorithm for problems of structural and solid mechanics. CMAME 36, 1983. <https://www.sciencedirect.com/science/article/abs/pii/0045782583901159>
- Vargas et al. Matrix-free approaches for GPU acceleration of a high-order FE hydrodynamics application using MFEM, Umpire, and RAJA. <https://arxiv.org/abs/2112.07075>
- Plecnik et al. Numerical continuation on a GPU for kinematic synthesis. J. Comput. Inf. Sci. Eng. 20, 2020. <https://asmedigitalcollection.asme.org/computingengineering/article/20/6/061009/1083893>
- Verschelde, Yu. Accelerating polynomial homotopy continuation on a GPU with double double and quad double arithmetic. <https://arxiv.org/abs/1501.06625>
- Hairer, Wanner. Stiff differential equations solved by Radau methods. J. Comput. Appl. Math. 111, 1999. <https://www.sciencedirect.com/science/article/pii/S037704279900134X>
- Steihaug, Wolfbrandt. An attempt to avoid exact Jacobian and nonlinear equations in the numerical solution of stiff differential equations. Math. Comp. 33, 1979. DOI 10.1090/S0025-5718-1979-0521273-8
- Günther, Hoschek, Rentrop. ROW methods adapted to electric circuit simulation packages. J. Comput. Appl. Math., 1997. <https://www.sciencedirect.com/science/article/pii/S0377042797000435>
- Ye, Dong, Li, Nassif. MAPS: multi-algorithm parallel circuit simulation. ICCAD 2008. <https://www.cecs.uci.edu/~papers/iccad08/PDFs/Papers/01D.1.pdf>
- Conte, D'Ambrosio, Paternoster. GPU-acceleration of waveform relaxation methods for large differential systems. Numer. Algorithms 71, 2016. <https://doi.org/10.1007/s11075-015-9993-6>
- Lim, Zhu, Selfridge, Kasim. Parallelizing non-linear sequential models over the sequence length (DEER). ICLR 2024. <https://arxiv.org/abs/2309.12252>
- Gonzalez, Warrington, Smith, Linderman. Towards scalable and stable parallelization of nonlinear RNNs. NeurIPS 2024. <https://arxiv.org/abs/2407.19115>
- Gulati, Croix, Khatri, Shastry. Fast circuit simulation on graphics processing units. ASP-DAC 2009. <https://www.aspdac.com/aspdac2009/archive/pdf/4C-6s.pdf>
- ESPice commit `4853197` (jac-width: f32 GPU Jacobian, measured) and `gpu.zig` at `fa9f0b4` and `ee66e0b`.

**Verification status.** A literature pass run for this page opened each
link or saw it in the publisher's, arXiv's or the docs' own listing. Some
numbers come from abstracts or search excerpts because the full text was
blocked. Those are Stone and Davis (not used here), the Ginkgo PeleLM
figures (not used here), Zhou's 76× (abstract), Jalili-Marandi's speedups
(not used here) and the RADAU5 parameters (documentation excerpts). The
CVODE and KINSOL rules were read from the SUNDIALS docs. The Cai and Li
summary is from general knowledge of the paper, not its text. Everything
marked speculative is our proposal and has no source.
