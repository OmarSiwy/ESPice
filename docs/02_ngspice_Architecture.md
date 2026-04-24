# Document 2: ngspice Architecture — Step-by-Step Pipeline and Block Diagram

**Date:** 2026-04-21 | **Version:** 1.0

---

## 1. Heritage and Design Philosophy

ngspice descends from Berkeley SPICE3f5 (1993), itself the successor to SPICE2G6 (1983). Written in C (mixed K&R and ANSI), it inherits SPICE3's architecture: linked-list data structures, function-pointer dispatch, per-element dynamic memory allocation, and a single-threaded core simulation loop.

Key architectural decisions from SPICE3 that persist in ngspice:
- **Global mutable state**: `CKTcircuit` is a global singleton with 200+ fields
- **Linked-list traversal**: All device iteration via pointer-chasing through `GENmodel → GENinstance` chains
- **Per-element malloc**: Sparse 1.3 matrix allocates each nonzero individually
- **Function pointer tables**: `SPICEdev` structure contains ~20 function pointers per device type
- **State vector arrays**: 8 historical time-point snapshots in `CKTstates[0..7]`

---

## 2. Complete Block Diagram

```
                        NGSPICE COMPLETE SIMULATION PIPELINE
                        =====================================

 ┌─────────────────────────────────────────────────────────────────────────┐
 │                        INPUT PROCESSING                                 │
 │                                                                         │
 │  .cir file                                                              │
 │     │                                                                   │
 │     ▼                                                                   │
 │  inp_readall()                                                          │
 │  ┌──────────────────────────────────────────────────────────────┐       │
 │  │ 1. Read entire file into linked list of (struct line)        │       │
 │  │    - li_line: char*  (text content)                          │       │
 │  │    - li_next: struct line*  (next line pointer)              │       │
 │  │    - li_linenum: int                                         │       │
 │  │    - li_error: char*                                         │       │
 │  │                                                              │       │
 │  │ 2. inp_stitch_continuation_lines()                           │       │
 │  │    - Join lines starting with '+' to preceding line          │       │
 │  │                                                              │       │
 │  │ 3. inp_stripcomments_line()                                  │       │
 │  │    - Remove lines starting with '*'                          │       │
 │  │    - Strip inline comments after '$'                         │       │
 │  │                                                              │       │
 │  │ 4. .include / .lib resolution                                │       │
 │  │    - Recursive file inclusion                                │       │
 │  │    - Library section selection (.lib name)                   │       │
 │  │                                                              │       │
 │  │ 5. inp_subcktexpand()                                        │       │
 │  │    - Collect all .SUBCKT definitions into table               │       │
 │  │    - For each X instance:                                    │       │
 │  │      a. Find matching .SUBCKT definition                     │       │
 │  │      b. Copy definition lines with param substitution        │       │
 │  │      c. Prefix internal nodes: X1:N005                       │       │
 │  │      d. .GLOBAL nodes bypass prefixing                       │       │
 │  │      e. Recurse for nested subcircuits                       │       │
 │  │                                                              │       │
 │  │ 6. NumParam: nupa_scan() + nupa_eval()                      │       │
 │  │    - Pass 1: identify .PARAM and {expressions}               │       │
 │  │    - Build symbol table with placeholder tokens              │       │
 │  │    - Pass 2: evaluate all expressions post-expansion         │       │
 │  │                                                              │       │
 │  │ 7. ngspice_compat_mode()                                    │       │
 │  │    - HSPICE dialect transforms                               │       │
 │  │    - PSpice dialect transforms                               │       │
 │  │    - LTspice dialect transforms                              │       │
 │  └──────────────────────────────────────────────────────────────┘       │
 │                           │                                             │
 │                           ▼                                             │
 │  inp_spsource()                                                         │
 │  ┌──────────────────────────────────────────────────────────────┐       │
 │  │ INPpas1(): Create nodes as CKTnode linked list               │       │
 │  │ INPpas2(): Create GENmodel + GENinstance structures          │       │
 │  │ INPpas3(): Bind device terminals to nodes                    │       │
 │  │                                                              │       │
 │  │ DEVnameHash / MODnameHash: O(1) name lookup hash tables     │       │
 │  └──────────────────────────────────────────────────────────────┘       │
 └─────────────────────────────────────────────────────────────────────────┘
                           │
                           ▼
 ┌─────────────────────────────────────────────────────────────────────────┐
 │                     CKTcircuit STRUCTURE                                 │
 │                                                                         │
 │  ┌───────────────────────────────────────────────────────────────┐      │
 │  │  CKThead[0..MAXNUMDEVS]  ← Array of GENmodel linked lists    │      │
 │  │    │                          indexed by device type code      │      │
 │  │    ▼                                                           │      │
 │  │  GENmodel (type=BSIM4)                                        │      │
 │  │    ├─ GENnextModel ──────► GENmodel (type=BSIM4, diff params) │      │
 │  │    ├─ GENinstances ──────► GENinstance (M1)                   │      │
 │  │    │                         ├─ GENnextInstance ──► GENinst   │      │
 │  │    │                         ├─ terminal pointers (node*)      │      │
 │  │    │                         ├─ matrix element pointers        │      │
 │  │    │                         ├─ operating point state          │      │
 │  │    │                         └─ per-device parameters          │      │
 │  │    └─ model parameters (process corners, physics)             │      │
 │  │                                                               │      │
 │  │  CKTnodes ──► CKTnode ──► CKTnode ──► ... ──► CKTlastNode    │      │
 │  │    (linked list of circuit nodes)                              │      │
 │  │    Each: number (matrix index), name, ptr (diagonal element)  │      │
 │  │                                                               │      │
 │  │  CKTmatrix (SMPmatrix*)                                       │      │
 │  │    Sparse matrix for equation solving                         │      │
 │  │    Sparse 1.3: per-element malloc, Markowitz ordering          │      │
 │  │    — OR — KLU: CSC workspace, BTF+AMD ordering                │      │
 │  │                                                               │      │
 │  │  CKTrhs[N]          ← Real RHS vector                        │      │
 │  │  CKTrhsOld[N]       ← Previous RHS                           │      │
 │  │  CKTirhs[N]         ← Imaginary RHS (AC analysis)            │      │
 │  │  CKTrhsSpare[N]     ← Scratch vector                         │      │
 │  │                                                               │      │
 │  │  CKTstates[0..7]    ← State vectors at 8 timepoints          │      │
 │  │    Each: array of doubles, one per state variable             │      │
 │  │    state0 = current, state1 = previous, ...                   │      │
 │  │                                                               │      │
 │  │  CKTtime             ← Current simulation time                │      │
 │  │  CKTdelta            ← Current timestep                      │      │
 │  │  CKTdeltaOld[7]      ← Previous 7 timesteps                  │      │
 │  │  CKTag[7]            ← Integration coefficients              │      │
 │  │  CKTorder            ← Current integration order              │      │
 │  │                                                               │      │
 │  │  CKTtemp             ← Circuit temperature (K)               │      │
 │  │  CKTnomTemp          ← Nominal temperature (K)               │      │
 │  │  CKTmode             ← Simulation mode flags                 │      │
 │  │  CKTnoncon           ← Non-convergence counter (global)      │      │
 │  │                                                               │      │
 │  │  Task system:                                                 │      │
 │  │    ci_defTask  (default convergence settings)                 │      │
 │  │    ci_specTask (interactive overrides)                        │      │
 │  │    ci_curTask  (active task pointer)                          │      │
 │  └───────────────────────────────────────────────────────────────┘      │
 └─────────────────────────────────────────────────────────────────────────┘
                           │
                           ▼
 ┌─────────────────────────────────────────────────────────────────────────┐
 │                     CKTsetup()                                          │
 │                                                                         │
 │  1. SMPnewMatrix() → allocate sparse matrix structure                   │
 │     Sparse 1.3: spCreate() — empty matrix, grow-on-demand              │
 │     KLU: allocate CSC workspace arrays                                  │
 │                                                                         │
 │  2. For each device type [0..MAXNUMDEVS]:                               │
 │       For each model in CKThead[type]:                                  │
 │         For each instance in model:                                     │
 │           DEVsetup(instance, model, ckt) →                              │
 │             a. Validate parameters, apply defaults                       │
 │             b. Allocate state vector entries (CKTstates)                │
 │             c. Bind matrix element pointers:                            │
 │                instance->BSIM4DdPtr = SMPmakeElt(matrix, dNode, dNode) │
 │                instance->BSIM4GgPtr = SMPmakeElt(matrix, gNode, gNode) │
 │                instance->BSIM4DgPtr = SMPmakeElt(matrix, dNode, gNode) │
 │                ... (dozens per BSIM4 instance)                          │
 │             d. These pointers are CACHED for the simulation lifetime    │
 │                                                                         │
 │  3. DEVtemp() for all devices — compute temperature-dependent params    │
 │                                                                         │
 │  4. Create branch equations for V-sources, inductors, etc.              │
 └─────────────────────────────────────────────────────────────────────────┘
                           │
                           ▼
 ┌─────────────────────────────────────────────────────────────────────────┐
 │                     ANALYSIS DISPATCH                                    │
 │                                                                         │
 │  Based on analysis cards parsed from netlist:                           │
 │                                                                         │
 │  .OP     → CKTop()      DC operating point                             │
 │  .DC     → DCtrCurv()   DC parameter sweep                             │
 │  .AC     → ACan()       AC small-signal frequency sweep                │
 │  .TRAN   → DCtran()     Transient time-domain                          │
 │  .NOISE  → NOISEan()    Noise frequency sweep                          │
 │  .PZ     → PZan()       Pole-zero extraction                           │
 │  .SENS   → SENSitivity() Sensitivity analysis                          │
 │  .DISTO  → DISTOan()    Distortion analysis                            │
 │  .TF     → TFan()       Transfer function                              │
 │                                                                         │
 │  Each analysis calls into the NR iteration core (NIiter)                │
 └─────────────────────────────────────────────────────────────────────────┘
                           │
                           ▼
 ┌─────────────────────────────────────────────────────────────────────────┐
 │              NEWTON-RAPHSON CORE LOOP (NIiter — niiter.c)               │
 │                                                                         │
 │  Entry: NIiter(ckt, maxIter)                                            │
 │                                                                         │
 │  for (iterno = 0; ; iterno++) {                                         │
 │                                                                         │
 │    ┌────────────────────────────────────────────────────┐               │
 │    │ PHASE 1: DEVICE EVALUATION + MATRIX STAMPING        │               │
 │    │ CKTload(ckt)                                        │               │
 │    │                                                     │               │
 │    │ CKTnoncon = 0;  // reset non-convergence counter    │               │
 │    │                                                     │               │
 │    │ for (type = 0; type < MAXNUMDEVS; type++) {         │               │
 │    │   for (model = CKThead[type]; model; model=next) {  │               │
 │    │     for (inst = model->instances; inst; inst=next) { │               │
 │    │                                                     │               │
 │    │       // COMPUTE: Evaluate device physics            │               │
 │    │       Vgs = *(ckt->CKTrhs + gNode)                  │               │
 │    │            - *(ckt->CKTrhs + sNode);                │               │
 │    │       Ids = bsim4_drain_current(Vgs, Vds, Vbs, ...)│               │
 │    │       gm  = dIds/dVgs;                               │               │
 │    │       gds = dIds/dVds;                               │               │
 │    │       gmbs = dIds/dVbs;                              │               │
 │    │       // ... capacitances, leakage, etc.            │               │
 │    │                                                     │               │
 │    │       // STAMP: Write into MNA matrix via cached ptrs│               │
 │    │       *(inst->BSIM4DdPtr) += gds + gbd;             │               │
 │    │       *(inst->BSIM4GgPtr) += gm + ggs;              │               │
 │    │       *(inst->BSIM4DgPtr) += gm;                    │               │
 │    │       *(inst->BSIM4DsPtr) -= (gm + gds + gmbs);    │               │
 │    │       // ... 30-50 more stamp operations             │               │
 │    │                                                     │               │
 │    │       // RHS contributions                           │               │
 │    │       *(ckt->CKTrhs + dNode) -= Ids_eq;            │               │
 │    │       *(ckt->CKTrhs + sNode) += Ids_eq;            │               │
 │    │                                                     │               │
 │    │       // Per-device convergence check                │               │
 │    │       if (fabs(Vgs - Vgs_old) > TOLVGS)            │               │
 │    │         ckt->CKTnoncon++;                            │               │
 │    │                                                     │               │
 │    │     }  // end instance loop                          │               │
 │    │   }  // end model loop                               │               │
 │    │ }  // end type loop                                  │               │
 │    └────────────────────────────────────────────────────┘               │
 │                           │                                             │
 │                           ▼                                             │
 │    ┌────────────────────────────────────────────────────┐               │
 │    │ PHASE 2: LOAD Gmin                                  │               │
 │    │ LoadGmin(matrix, diagGmin_value)                     │               │
 │    │   Add small conductance to every diagonal element    │               │
 │    │   for numerical stability (if diagGmin > 0)         │               │
 │    └────────────────────────────────────────────────────┘               │
 │                           │                                             │
 │                           ▼                                             │
 │    ┌────────────────────────────────────────────────────┐               │
 │    │ PHASE 3: MATRIX FACTORIZATION                       │               │
 │    │                                                     │               │
 │    │ if (first_iteration) {                               │               │
 │    │   SMPpreOrder(matrix)                                │               │
 │    │     → spMNA_Preorder(): MNA-aware column permutation │               │
 │    │ }                                                    │               │
 │    │                                                     │               │
 │    │ if (needs_reorder) {                                 │               │
 │    │   SMPreorder(matrix, pivot_abs_tol, pivot_rel_tol)  │               │
 │    │     → spOrderAndFactor():                            │               │
 │    │       Markowitz strategy: pick pivot minimizing      │               │
 │    │         (row_count - 1) × (col_count - 1)           │               │
 │    │       Full LU with partial pivoting                  │               │
 │    │       Dynamic fill-in via individual malloc           │               │
 │    │ } else {                                             │               │
 │    │   SMPluFac(matrix, pivot_abs_tol, diagGmin)         │               │
 │    │     → spFactor():                                    │               │
 │    │       LU with existing ordering (faster)             │               │
 │    │       Reuses pivot sequence from last reorder        │               │
 │    │ }                                                    │               │
 │    │                                                     │               │
 │    │ — OR (if KLU enabled) —                              │               │
 │    │                                                     │               │
 │    │ if (first_solve) {                                   │               │
 │    │   KLU_symbolic(A):                                   │               │
 │    │     BTF decomposition (max transversal + Tarjan SCC) │               │
 │    │     AMD ordering within each diagonal block          │               │
 │    │     Predict L/U nonzero pattern                      │               │
 │    │   KLU_numeric(A):                                    │               │
 │    │     Gilbert-Peierls left-looking LU per block        │               │
 │    │     Partial pivoting within blocks                   │               │
 │    │ } else {                                             │               │
 │    │   KLU_refactor(A):                                   │               │
 │    │     Reuse symbolic pattern + pivot sequence           │               │
 │    │     Only recompute numeric L/U values                │               │
 │    │     5-10x faster than full factorization             │               │
 │    │     Falls back to full if instability detected        │               │
 │    │ }                                                    │               │
 │    └────────────────────────────────────────────────────┘               │
 │                           │                                             │
 │                           ▼                                             │
 │    ┌────────────────────────────────────────────────────┐               │
 │    │ PHASE 4: SOLVE                                      │               │
 │    │ SMPsolve(matrix, rhs, irhs)                         │               │
 │    │   → spSolve() / KLU_solve()                         │               │
 │    │   Forward substitution: Ly = Pb                     │               │
 │    │   Back substitution: Ux = y                          │               │
 │    │   Unpermute: x = Q^T * x_internal                   │               │
 │    │                                                     │               │
 │    │   Result: new voltage/current solution vector        │               │
 │    └────────────────────────────────────────────────────┘               │
 │                           │                                             │
 │                           ▼                                             │
 │    ┌────────────────────────────────────────────────────┐               │
 │    │ PHASE 5: DAMPING                                    │               │
 │    │                                                     │               │
 │    │ for each node i:                                     │               │
 │    │   delta_v = rhs_new[i] - rhs_old[i]                │               │
 │    │   if |delta_v| > 10.0 V:                            │               │
 │    │     damp = min(10.0 / |delta_v|, 0.1)              │               │
 │    │     // Scale ENTIRE update vector by damp            │               │
 │    │     break  (one global damp factor)                  │               │
 │    │                                                     │               │
 │    │ rhs_new = rhs_old + damp * (rhs_new - rhs_old)     │               │
 │    └────────────────────────────────────────────────────┘               │
 │                           │                                             │
 │                           ▼                                             │
 │    ┌────────────────────────────────────────────────────┐               │
 │    │ PHASE 6: CONVERGENCE TEST (NIconvTest)              │               │
 │    │                                                     │               │
 │    │ converged = true                                     │               │
 │    │                                                     │               │
 │    │ // Global voltage convergence                        │               │
 │    │ for each voltage node i:                             │               │
 │    │   tol = RELTOL * max(|V_new[i]|, |V_old[i]|) + VNTOL│               │
 │    │   if |V_new[i] - V_old[i]| > tol:                  │               │
 │    │     converged = false                                │               │
 │    │                                                     │               │
 │    │ // Global current convergence                        │               │
 │    │ for each branch current j:                           │               │
 │    │   tol = RELTOL * max(|I_new[j]|, |I_old[j]|) + ABSTOL│              │
 │    │   if |I_new[j] - I_old[j]| > tol:                  │               │
 │    │     converged = false                                │               │
 │    │                                                     │               │
 │    │ // Per-device convergence (CKTnoncon)                │               │
 │    │ if CKTnoncon > 0:                                    │               │
 │    │   converged = false  // devices flagged issues        │               │
 │    │                                                     │               │
 │    │ Default tolerances:                                  │               │
 │    │   RELTOL = 1e-3                                      │               │
 │    │   VNTOL  = 1e-6 V                                    │               │
 │    │   ABSTOL = 1e-12 A                                   │               │
 │    │   ITL1   = 100 (max DC iterations)                   │               │
 │    │   ITL4   = 10 (max transient iterations per step)    │               │
 │    └────────────────────────────────────────────────────┘               │
 │                           │                                             │
 │              NO ◄─────────┤──────────► YES                              │
 │              │                          │                                │
 │              │ (loop back to Phase 1)   │                                │
 │              │                          │ ──► return CONVERGED           │
 │              │                          │                                │
 │              │ if iterno > maxIter:     │                                │
 │              │   return E_ITERLIM       │                                │
 │              │                          │                                │
 └──────────────┘──────────────────────────┘                                │
 └─────────────────────────────────────────────────────────────────────────┘
```

---

## 3. DC Operating Point Convergence Algorithm

When plain Newton-Raphson fails to converge for DC operating point, ngspice falls through a specific sequence:

### Fallback 1: Junction-Initialized NR

Initialize semiconductor junctions with small forward voltages (~0.6V for silicon), set mode to `MODEINITJCT`. Run NR iterations. Transition through `MODEINITFIX` → `MODEINITFLOAT`. This is the fastest method and usually succeeds for well-conditioned circuits.

### Fallback 2: Dynamic GMIN Stepping

```
diagGmin = GMIN_INIT (1e-2 S)
step_factor = 10

while (diagGmin > GMIN_FINAL):
  LoadGmin(matrix, diagGmin)    // add to all diagonals
  run NR iterations

  if converged:
    save_solution()
    diagGmin /= step_factor     // reduce conductance
    if step_factor < 100:
      step_factor *= 2          // accelerate on success
  else:
    restore_solution()
    step_factor = max(step_factor / 2, 2)
    diagGmin *= step_factor      // back off

// Final solve with diagGmin = GMIN (1e-12)
LoadGmin(matrix, GMIN)
run NR iterations
```

Physics: Large diagGmin swamps nonlinearities — every node sees a strong conductance to ground, linearizing the system. As diagGmin shrinks, nonlinear behavior gradually emerges, guided by the previous solution.

### Fallback 3: Dynamic Source Stepping

```
alpha = 0  // source scaling factor
step_factor = 1.0 / ITL6  // typically 0.1

while (alpha < 1.0):
  scale_all_sources(alpha)
  run NR iterations

  if converged:
    save_node_voltages()
    alpha += step_factor
    step_factor = min(step_factor * 2, 0.5)  // accelerate
  else:
    restore_node_voltages()
    step_factor /= 2
    if step_factor < 1e-6:
      return FAILURE
```

Physics: At alpha=0, all sources are off — solution is trivially zero. Gradually ramp sources toward full value, using each converged solution as starting point for the next.

Limitation: Fails for regenerative circuits (Schmitt triggers, latches) where the output feeds back to determine the operating point.

### Fallback 4: Pseudo-Transient Continuation

Add supplementary capacitance to every node. Run a transient-like simulation from zero initial conditions while ramping sources over `RAMPTIME`. The capacitive dynamics provide natural damping that prevents oscillation. Nearly always succeeds but is the slowest method (requires many timepoints).

---

## 4. Transient Analysis — Detailed Algorithm

### Time Integration Methods

**Trapezoidal Rule (default):**
```
q(t_{n+1}) = q(t_n) + h/2 × [i(t_{n+1}) + i(t_n)]

Equivalent companion model:
  G_eq = 2C/h
  I_eq = G_eq × V_old + I_old
```

Second-order accurate. Can exhibit "trap ringing" — oscillation about the true solution at sharp discontinuities. Mitigated by `XMU=0.495` damping (slightly off-center trapezoid).

**Gear BDF (Backward Differentiation Formula):**

Order k formula:
```
Σ(j=0..k) α_j × q(t_{n+1-j}) = h × β × i(t_{n+1})
```

Coefficient table (first 4 orders):

| Order | α₀ | α₁ | α₂ | α₃ | α₄ | β |
|-------|-----|-----|-----|-----|-----|---|
| 1 (BE) | 1 | -1 | | | | 1 |
| 2 | 3/2 | -2 | 1/2 | | | 1 |
| 3 | 11/6 | -3 | 3/2 | -1/3 | | 1 |
| 4 | 25/12 | -4 | 3 | -4/3 | 1/4 | 1 |

More stable than trapezoidal for stiff systems. Less accurate (order k is only kth-order accurate). Default `MAXORD=2`.

### Timestep Control

```
for each timepoint t_n:
  1. CKTtime += CKTdelta
  2. Update CKTag[0..order] integration coefficients
  3. NIiter(ckt, ITL4)  // NR iterations (max 10)

  if NR fails to converge:
    CKTdelta /= 2        // halve timestep
    CKTtime -= CKTdelta   // rewind
    retry

  if converged:
    // Local Truncation Error estimation
    for each device:
      DEVtrunc(device, ckt):
        // Estimate LTE from state variable change rates
        // For trapezoidal: LTE ≈ h³/12 × |y'''|
        // Computed from finite differences of CKTstates
        proposed_dt = TRTOL × tolerance / LTE_estimate
      global_next_dt = min(global_next_dt, proposed_dt)

    // Breakpoint check
    next_breakpoint = earliest device breakpoint (PWL, PULSE edges)
    global_next_dt = min(global_next_dt, next_breakpoint - CKTtime)

    // Accept step
    CKTaccept():
      rotate state vectors: states[7]=states[6], ..., states[1]=states[0]
      update CKTdeltaOld history
      devices may set new breakpoints

    CKTdelta = global_next_dt
```

**TRTOL (default 7):** Fudge factor. SPICE assumes it overestimates LTE by ~7x, so the actual timestep is effectively 7x larger than the strict LTE bound would permit.

### State Vector Management

8 state vectors `CKTstates[0..7]` store device state at historical timepoints:
- `states[0]`: Current timepoint (being computed)
- `states[1]`: Previous timepoint
- `states[2..7]`: Earlier timepoints (for higher-order BDF)

Each state variable is a double. State variables include: junction voltages, capacitor charges, inductor fluxes, branch currents. Total state count = sum over all devices of per-device state variables.

On step acceptance: `states[7] = states[6]`, ..., `states[1] = states[0]`, and `states[0]` is ready for the next timepoint.

---

## 5. AC Small-Signal Analysis

```
1. Solve DC operating point (CKTop)
   → linearization point x0

2. For each device:
   DEVacLoad(device, ckt):
     Compute small-signal conductances G and capacitances C
     at operating point x0
     Stamp into separate G and C matrices

3. For each frequency f in sweep:
   ω = 2π × f

   // Build complex admittance matrix
   Y(jω) = G + jωC

   // Set up stimulus
   For AC source with magnitude AC_MAG and phase AC_PHASE:
     b[branch] = AC_MAG × exp(j × AC_PHASE)

   // Factor and solve complex system
   SMPcLUfac(Y)     // Complex LU factorization
   SMPcSolve(Y, b)  // Complex forward/back solve

   // Store results
   For each node n:
     V_n = rhs_real[n] + j × rhs_imag[n]
     magnitude[n] = |V_n|
     phase[n] = atan2(imag, real)
```

Note: ngspice performs true complex arithmetic in the AC solver, requiring separate real and imaginary RHS vectors and a complex matrix factorization.

---

## 6. Device Model Interface (SPICEdev)

Every device type implements the `SPICEdev` structure:

```c
typedef struct SPICEdev {
    IFdevice    DEVpublic;           // Name, type code, parameter descriptors

    // ──── Function Pointer Table ────
    int (*DEVparam)();               // Set instance parameter from netlist
    int (*DEVmodParam)();            // Set model parameter from .MODEL
    int (*DEVload)();                // Stamp matrix (called every NR iter)
    int (*DEVsetup)();               // One-time initialization
    int (*DEVunsetup)();             // Cleanup after simulation
    int (*DEVpzLoad)();              // Pole-zero matrix contribution
    int (*DEVtemp)();                // Temperature-dependent recalculation
    int (*DEVtrunc)();               // Truncation error for timestep control
    int (*DEVfindBranch)();          // Locate branch equation index
    int (*DEVacLoad)();              // AC small-signal stamp
    int (*DEVaccept)();              // Post-convergence bookkeeping
    int (*DEVdestroy)();             // Free all memory
    int (*DEVmodDelete)();           // Delete model
    int (*DEVdelete)();              // Delete instance
    int (*DEVsetic)();               // Set initial conditions
    int (*DEVask)();                 // Query instance output parameter
    int (*DEVmodAsk)();              // Query model parameter
    int (*DEVconvTest)();            // Per-device convergence verification
    int (*DEVsenSetup)();            // Sensitivity setup
    int (*DEVsenLoad)();             // Sensitivity matrix stamp
    int (*DEVsenUpdate)();           // Sensitivity state update
    int (*DEVsenAcLoad)();           // AC sensitivity stamp
    int (*DEVsenPrint)();            // Print sensitivity results
    int (*DEVsenTrunc)();            // Sensitivity truncation
    int (*DEVdisto)();               // Distortion contribution
    int (*DEVnoise)();               // Noise contribution

    // ──── Size Information ────
    int DEVinstSize;                 // sizeof(device-specific instance)
    int DEVmodSize;                  // sizeof(device-specific model)
    int *DEVpublic.numModelParms;    // Number of model parameters
    int *DEVpublic.numInstanceParms; // Number of instance parameters
} SPICEdev;
```

Registration: `spice_init_devices()` populates the global `DEVices[MAXNUMDEVS]` array at startup. Each entry is populated by device-specific `get_xxx_info()` functions.

### Device Type Catalog (ngspice)

| Code | Device | Source Directory | Notes |
|------|--------|-----------------|-------|
| 0 | Resistor | `res/` | Linear + semiconductor + TC1/TC2 |
| 1 | Capacitor | `cap/` | Linear + voltage-dependent + semiconductor |
| 2 | Inductor | `ind/` | Linear + mutual coupling |
| 3 | Mutual Inductance | `mut/` | K-element for coupled inductors |
| 4 | Diode | `dio/` | Level 1 (Shockley) + Level 3 |
| 5 | BJT | `bjt/` | Gummel-Poon + substrate diode |
| 6 | JFET | `jfet/` + `jfet2/` | Level 1 + Parker-Skellern |
| 7 | MOSFET Level 1 | `mos1/` | Shichman-Hodges |
| 8 | MOSFET Level 2 | `mos2/` | Improved S-H with velocity sat |
| 9 | MOSFET Level 3 | `mos3/` | Semi-empirical short-channel |
| 10 | MOSFET Level 6 | `mos6/` | MOS6 model |
| 11 | BSIM3v3 | `bsim3v32/` | ~500 parameters |
| 12 | BSIM4v5 | `bsim4v5/` | ~500 parameters |
| 13 | BSIM4v7 | `bsim4v7/` | Latest BSIM4 |
| 14 | BSIMSOI | `bsimsoi/` | SOI variant |
| 15 | EKV | `ekv/` | Enz-Krummenacher-Vittoz |
| 16 | PSP | `psp/` | Surface-potential based |
| 17 | HICUM | `hicum2/` | High-Current Model for BJT |
| 18 | MEXTRAM | `mextram/` | Most EXquisite TRAnsistor Model |
| 19 | VBIC | `vbic/` | Vertical Bipolar Inter-Company |
| 20 | MESFET | `mes/` | Statz + Curtis + TOM |
| 21-30 | V/I-sources | `vsrc/` `isrc/` | DC + AC + transient waveforms |
| 31-34 | Controlled sources | `vcvs/` `vccs/` `ccvs/` `cccs/` | Linear + polynomial + TABLE |
| 35 | Transmission line | `tra/` | Ideal (lossless) |
| 36 | LTRA | `ltra/` | Lossy transmission line |
| 37 | TXL | `txl/` | Frequency-dependent T-line |
| 38 | URC | `urc/` | Uniform RC line |
| 39-40 | Switches | `sw/` `csw/` | Voltage/current controlled |
| 41+ | XSPICE code models | `xspice/icm/` | ~100+ extensible models |

---

## 7. Sparse Matrix Solvers

### Sparse 1.3 (Default, Legacy)

**Architecture:** Each matrix element is individually `malloc()`'d as a `struct spMatrixElement`:
```c
struct spMatrixElement {
    double Real;           // Value
    double Imag;           // For complex (AC)
    int Row, Col;          // Position
    struct spMatrixElement *NextInRow;   // Linked list
    struct spMatrixElement *NextInCol;   // Linked list
};
```

**Memory overhead:** Each nonzero element = 48+ bytes (value + indices + 2 pointers + malloc header). For a 1000-node circuit with ~5000 nonzeros: ~240 KB of scattered heap allocations. Cache-unfriendly.

**Operations:**
1. `spCreate(n)` → allocate empty matrix
2. `spGetElement(row, col)` → find or create element (may malloc)
3. `spClear()` → zero all values but keep structure
4. `spMNA_Preorder()` → MNA-aware column reordering
5. `spOrderAndFactor()` → Markowitz pivot selection + LU factorization
6. `spFactor()` → LU with existing ordering (subsequent iterations)
7. `spSolve()` → forward/back substitution

**Markowitz strategy:** At each elimination step k:
- For each candidate pivot (i,j):
  - Cost = (nonzeros in row i - 1) × (nonzeros in col j - 1)
- Select pivot with minimum cost
- Threshold pivoting: |pivot| must exceed PIVTOL × max_in_column
- Fill-in elements are dynamically malloc'd

### KLU (Optional, High-Performance)

**Architecture:** Pre-allocated CSC workspace. All L/U storage in contiguous arrays.

**Three-phase algorithm:**

**Phase 1 — Symbolic Analysis (once per topology):**
```
BTF Decomposition:
  1. Maximum transversal (Duff's algorithm / Hopcroft-Karp DFS)
     Find permutation P s.t. PAP^T has nonzero diagonal
  2. Tarjan SCC on column dependency graph
     Find strongly-connected components → diagonal blocks
  3. Sort blocks in reverse topological order (leaves first)

AMD within each block:
  For block B of size m:
    1. Compute elimination graph of B
    2. Repeatedly eliminate vertex of minimum degree
    3. Output fill-reducing permutation
```

**Phase 2 — Numeric Factorization (first solve):**
```
For each diagonal block B in BTF order:
  Gilbert-Peierls left-looking algorithm:
    For each column k = 0..m-1:
      1. DFS on L^T from nonzero rows of A(:,k)
         → sparsity pattern of L(:,k) and U(:,k)
      2. Scatter A(:,k) into dense work vector x
      3. For each j in pattern with j < k:
           x[i] -= L(i,j) × x[j]  for i in L(:,j) below diagonal
      4. Partial pivot: select largest |x[i]| among unpivoted
      5. L(:,k) = x[below_pivot] / x[pivot]
         U(:,k) = x[above_pivot]
```

**Phase 3 — Refactorization (subsequent NR iterations):**
```
Reuse: symbolic pattern, pivot sequence, permutations
Recompute: only numeric values of L and U
Speed: 5-10x faster than Phase 2
Fallback: if near-zero pivot detected → full Phase 2
```

**KLU vs Sparse 1.3 performance** (measured on ngspice benchmarks):
- Small circuits (<100 nodes): Similar (KLU has more setup overhead)
- Medium circuits (100-1000 nodes): KLU 2-3x faster
- Large circuits (1000-10000 nodes): KLU 5-11x faster
- Very large (>10000 nodes): KLU up to 100x faster (CSC eliminates malloc overhead)

---

## 8. Performance Characteristics

### Single-Threaded Bottleneck

ngspice's `NIiter` loop is strictly sequential:
```
CKTload() → SMPluFac() → SMPsolve() → NIconvTest() → [loop]
```

No pipeline parallelism. No concurrent device evaluation with matrix factorization.

**OpenMP support** is limited:
- Only BSIM3v3.24, BSIM4v5, and BSIMSOI4 have OpenMP-parallel `DEVload()`
- Parallel evaluation across instances within one model only
- Stamping (writing to shared matrix) creates write conflicts that serialize
- Typical speedup: ~2x on 4 cores for transistor-heavy circuits
- Matrix solver is NOT parallelized, capping total speedup

### Memory Allocation Patterns

| Pattern | Impact | Scale |
|---------|--------|-------|
| Per-element sparse matrix malloc | Cache fragmentation | 5-10N individual allocs |
| GENmodel/GENinstance linked lists | Pointer-chasing misses | O(devices) per NR iter |
| PDK model binning | Massive bloat | 180 bins × all devices → GB |
| State vector duplication | 8 copies of device state | 8 × sizeof(states) |
| RHS vector pair | Double-buffered solution | 2 × N doubles |

**Real-world impact:** A 394-transistor circuit with Skywater 130nm PDK consumed 2.2 GB in ngspice due to loading ALL 180 W/L bins as separate models (even for unused bins). A memory-reduction branch cut this to ~425 MB.

### Profiling Breakdown

**Transistor-heavy circuits (typical analog):**

| Phase | % of NR iteration | Notes |
|-------|-------------------|-------|
| `CKTload()` (device eval + stamp) | 60-70% | BSIM4 eval dominates |
| `SMPluFac()`/KLU factor | 15-25% | Refactorization cheaper |
| `SMPsolve()` fwd/back | 5-10% | O(nnz) |
| `NIconvTest()` | <5% | O(N) |
| Output/bookkeeping | <5% | |

**Linear-dominant circuits (RC ladders, T-lines):**

| Phase | % of NR iteration | Notes |
|-------|-------------------|-------|
| `CKTload()` | 10-20% | Simple resistor/cap stamps |
| `SMPluFac()`/KLU factor | 60-80% | Solver dominates |
| `SMPsolve()` fwd/back | 10-20% | Large systems |
| Other | <5% | |

### Cache-Unfriendly Access Pattern

```
CKTload() iteration:

  CKThead[type] ──ptr──► GENmodel_A ──ptr──► GENmodel_B ──ptr──► NULL
                              │                    │
                              ▼                    ▼
                         GENinst_1 ──ptr──►  GENinst_3 ──ptr──► NULL
                              │
                              ▼
                         GENinst_2 ──ptr──► NULL

  Each '──ptr──►' is a pointer dereference to a different heap location.
  Typical IPC (instructions per cycle): 0.12 during pointer-chasing
  vs 0.96 for sequential array access.
```

This fundamental architectural limitation cannot be fixed without a complete rewrite of ngspice's data structures.

---

## 9. Output Processing

### Rawfile Format

**Header (ASCII text):**
```
Title: NMOS Characterization
Date: Mon Apr 21 10:30:00 2026
Plotname: DC transfer characteristic
Flags: real
No. Variables: 3
No. Points: 181
Variables:
  0  v-sweep  voltage
  1  v(drain) voltage
  2  i(vds)   current
```

**Binary data:** Packed `double` values, column-major:
```
[v_sweep[0]] [v_drain[0]] [i_vds[0]]
[v_sweep[1]] [v_drain[1]] [i_vds[1]]
...
```

**ASCII data:**
```
Values:
0  0.000000e+00
   1.800000e+00
   -1.234567e-12
1  1.000000e-02
   1.799876e+00
   ...
```

### Nutmeg Post-Processing

Interactive command interpreter:
- `plot v(drain) vs v(gate)` — waveform display
- `let gm = deriv(i(vds))` — vector math
- `meas dc vth find v(gate) when i(vds)=1e-7` — measurement
- `write results.raw` — save to file
- `set color0=white` — display configuration

---

## 10. Known Limitations

1. **No caching between runs** — every simulation starts from scratch
2. **Single-threaded matrix solver** — no parallel LU factorization
3. **Per-element malloc** — severe cache fragmentation with Sparse 1.3
4. **Linked-list device iteration** — pointer-chasing cache misses
5. **PDK model bloat** — loads all bins even for unused geometries
6. **No RF analyses** — no Harmonic Balance, PSS, or Envelope Following
7. **No built-in Monte Carlo** — requires `.control` scripting
8. **No S-parameter analysis** — requires XSPICE workaround
9. **Limited output formats** — rawfile only (no HSPICE, Touchstone, CSV natively)
10. **No incremental simulation** — topology changes require full rebuild
