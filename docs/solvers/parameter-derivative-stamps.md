# Parameter-Derivative Stamps (∂F/∂p Device Hooks)

Analytic parameter Jacobians through the device contract: interface,
adjoint accumulation, SoA layout, GPU variant. Serves dcmatch, adjoint
DC/AC sensitivity, and (later) optimization loops.

**Status: not implemented** — today's sensitivity is finite-difference
re-solve (`sweep/sens.zig`) and Monte-Carlo perturbs raw f32 params.
This doc specs the analytic route the contract already almost supports.

## 1. Mathematical specification

### What is needed

Adjoint sensitivity and dcmatch ([dcmatch](../analysis/dcmatch.md),
[sensitivity](../analysis/sensitivity.md)) need, per parameter $p$ of
device $d$:

$$
\frac{\partial y}{\partial p} = -\,\lambda^{\mathsf T}\, \frac{\partial F}{\partial p},
\qquad J^{\mathsf T}\lambda = e_{\text{out}},
$$

where $\partial F/\partial p \in \mathbb{R}^n$ is **sparse with the
device's own footprint**: only the $n_u$ rows device $d$ stamps are
nonzero. So the deliverable per (instance, parameter) is an $n_u$-vector
$\partial F_{\text{local}}/\partial p$ — a *residual derivative stamp* —
and the analysis-side operation is one $n_u$-wide dot against the gathered
adjoint values $\lambda_{\text{local}}$. Nothing is ever assembled into a
matrix; no $\partial J/\partial p$ is needed for first-order sensitivity
(it appears only in second-order/Hessian work — out of scope, YAGNI).

For AC sensitivity the same stamp evaluated on the charge function gives
$\partial Q_{\text{local}}/\partial p$, and the frequency-domain
derivative is $\partial A/\partial p = \partial G/\partial p + j\omega\,
\partial C/\partial p$ acting on the known $X$ — still only
residual-level derivatives contracted with known vectors:
$\lambda^{\mathsf H} (\partial F/\partial p + j\omega\, \partial q/\partial p)\big|_{\text{directional through } X}$.

### How the contract delivers it: one more dual lane

Device physics is value-form, generic over an opaque scalar `S`
(`contract.zig`); the batch instantiates `S = AdScalar(n_u)` seeding the
$n_u$ unknowns — one pass yields residual + full local Jacobian. The
parameter derivative is the **same mechanism with one more seed lane**:

$$
S = \mathrm{AdScalar}(n_u + 1), \qquad
d\text{-vector} = (\underbrace{e_0 \dots e_{n_u-1}}_{\text{unknowns}},\ \underbrace{e_{n_u}}_{\text{the parameter}}),
$$

so `out[ru].d[0..n_u]` is the Jacobian row (unchanged) and
`out[ru].d[n_u]` is $\partial F_{ru}/\partial p$ — exact, one eval, no FD.

The catch: physics currently reads parameters as plain f64 **constants**
(`x.scale(model.g)`, `S.con(model.c)`), so the seed has nowhere to enter.
Two contract-compatible hook designs:

- **(a) `evalp` wrapper (chosen)** — optional device decl
  `pub fn evalp(comptime S, x: [n_u]S, p: S, m: *const Model, i: *const Instance, t: f64) [n_u]S`
  that re-expresses `eval` with ONE named parameter routed through `S`
  (which parameter: the device's `mc_param`, already a validated contract
  decl naming the principal f32 field). Hand-written devices add a
  few-line wrapper; VAF/VF-generated devices get it emitted for free
  (the generator knows every parameter's dataflow). Multiple parameters =
  multiple seed lanes `AdScalar(n_u + n_p)` with `p: [n_p]S` — same shape.
- **(b) seed-vector substitution** — no signature change: promote the
  *Model/Instance field itself* to a dual by instantiating the whole
  Model over S. Rejected: Model fields are plain f64/f32 by contract
  (`validateDefaultedStruct` enforces value types), temperature/geometry
  prep intentionally stays out of the S graph ("everything not depending
  on x stays plain f64"), and duplicating Model per scalar type doubles
  every batch's memory. The wrapper keeps prep-vs-physics separation and
  costs one extra lane only where requested.

FD fallback stays: devices without `evalp` get the existing
perturb-and-re-solve path (`sens.zig`) or a *stamp-level* FD
(perturb $p$, re-eval the one device, difference the local residual —
$O(1)$ evals per device, no extra Newton solves; strictly better than
today's global FD and needing no contract change at all — the honest
first rung).

### Adjoint accumulation

With stamps available, dcmatch/adjoint-sens is one pass:

$$
\frac{\partial y}{\partial p_d} = -\sum_{ru=0}^{n_u-1} \lambda[\mathrm{node}_d(ru)]\cdot \frac{\partial F_{ru}}{\partial p_d},
$$

gather $\lambda$ through the batch's existing `gath` index table (the same
gather `localX` does for $x$), dot, write one scalar per (instance,
param). Variance accumulation for dcmatch multiplies by
$\sigma^2(\delta p_d)$ and reduces.

### SoA memory layout

Batches are SoA per device type (`batch.zig`): `models[]`, `instances[]`,
`gath[count × n_u]`, `rhs_idx[count × n_u]`. The stamp pass needs **no new
persistent arrays** in the common case — it is a streaming
eval-gather-dot-reduce with one output scalar per (instance, param):

- output: `dydp[count]` per batch (or accumulate variance in-place:
  `var_acc[count]` → one grid/loop reduction), instance-major;
- if stamps must be *stored* (AC sweep reusing them per frequency):
  `dfdp[count × n_u]` instance-major — same stride discipline as `gath`,
  memory = one extra plane row per parameter, allocated per analysis, not
  per circuit.

## 2. Flow explanation

1. **Contract**: add `evalp` to the allowlist + `validate()` shape check
   (mirrors how `limit`/`seed`/`attempt` are optional, checked decls);
   `mc_param` names the default parameter, an explicit param-id argument
   generalizes later. Devices without it: stamp-level FD fallback.
2. **Batch hook**: a cold-path method on `DeviceBatch` (next to the noise
   collector, which already does exactly this gather-and-report shape —
   see `collectNoiseSources` flow): for each instance, gather
   $x_{\text{local}}$ and $\lambda_{\text{local}}$, instantiate
   `S = AdScalar(n_u + 1)` (comptime, per device type — same comptime
   dispatch as everything else), call `evalp`, dot lane $n_u$ against
   $\lambda$, emit.
3. **Analysis side** (dcmatch / adjoint sens): OP solve → keep factors →
   `slv.solveT(e_out, λ)` (`direct.zig`, exists) → one batch pass → report.
   AC variant: per frequency, `freq_solve.solveRhsT` (exists) for the
   complex adjoint, batch pass with the $j\omega\,\partial q/\partial p$
   term added.
4. **Failure handling**: none new — the pass is post-solve, read-only on
   circuit state; a device lacking both `evalp` and a finite nominal
   (FD-able) parameter reports zero sensitivity *explicitly flagged*, not
   silently (ngspice's zero-param skip, surfaced).

## 3. Pseudo-code, CPU sequential

```
# analysis side (dcmatch / adjoint DC sens)
solve OP; keep factored J
lambda = slv.solveT(e_out)                       # exists: direct.zig

for each batch B (device type D):                # comptime dispatch
    for id in 0..B.count:
        xl  = gather(x,      B.gath[id])          # existing localX
        ll  = gather(lambda, B.gath[id])          # same index table
        if D has evalp:
            S = AdScalar(n_u + 1)
            xd[u] = seed(xl[u], lane=u);  pd = seed(p_val(id), lane=n_u)
            out = D.evalp(S, xd, pd, model, inst, t)
            dFdp[ru] = out[ru].d[n_u]
        else:                                     # stamp-level FD fallback
            r0 = D.eval(Value, xl, ...); nudge p; r1 = D.eval(Value, xl, ...)
            dFdp = (r1 - r0)/dp; restore p
        dydp[id] = -sum_ru ll[ru] * dFdp[ru]
        var_acc += dydp[id]^2 * sigma2(id)        # dcmatch
```

## 4. Pseudo-code, GPU parallel

The pass is one more comptime-dispatched batch kernel, identical in shape
to the residual megakernel pass (`kernel.zig assemble`): grid-stride over
instances, SoA gathers, no atomics needed (output is instance-major, one
writer per slot).

```
kernel param_stamp_pass(blob, x, lambda):
    for each batch desc (comptime device dispatch, as in assemble):
        id = tid; while id < desc.count: id += stride
            gather xl, ll via gath[id*n_u..]
            evalp with AdScalar(n_u+1)             # one extra SIMD lane;
                                                   # register cost ~ (n_u+1)/n_u
            dydp[id] = -dot(ll, d[.., n_u])
    grid reduction: var_acc = sum dydp^2 * sigma2   # block partials + atomicAdd
```

- The adjoint $\lambda$ comes from either a host `solveT` (upload one
  vector) or, matrix-free, transposed-GMRES on-device (the megakernel's
  GMRES with the transposed-scatter eval — same machinery listed in
  [lptv-block-solves.md](lptv-block-solves.md) §4).
- The extra dual lane costs one more `@Vector` lane in registers — on GPU
  the `AdScalar` vector width already rounds up; for most devices
  $n_u + 1$ stays within the same occupancy bucket (measure per model, as
  with everything ptx).
- Ensemble axis composes: per-lane $\lambda$ and stamps for MC/corner
  sensitivity clouds.

---

**Sources fetched**

| Source | Status |
|---|---|
| Director & Rohrer adjoint sensitivity | **paywalled — derived, not source-verified** (standard; identity restated from [sensitivity](../analysis/sensitivity.md)) |
| Forward-mode AD for parameter derivatives (Griewank & Walther) | **book — derived, not source-verified** (extra-seed-lane construction is elementary forward AD) |

**Per-section verification**

- §1 what-is-needed + sparsity of $\partial F/\partial p$: derived,
  standard.
- §1 contract analysis (S-generic physics, `AdScalar(N)` seeding,
  params-as-constants, `mc_param`, Model value-type enforcement, prep
  rules): **verified against source** — `../VerA/tools/contract.zig`
  (module doc RULES, `Dual`, `validateMcParam`,
  `validateDefaultedStruct`), `src/devices/engine.zig`,
  `src/devices/engine.zig` (seed loop `d[u] = 1`, `gath`
  tables, `localX`, noise-collector shape).
- §2–§4: design spec (nothing implemented); FD-fallback rung verified
  feasible against existing `evalValues` helper in `contract.zig`.

**Our implementation**

- Exists (ingredients): `../VerA/tools/contract.zig` (S contract,
  `Dual`, `mc_param`, `evalValues`), `src/devices/engine.zig`
  (`AdScalar`), `src/devices/engine.zig` (SoA layout,
  gathers), `src/solvers/direct.zig solveT`,
  `src/solvers/freq_solve.zig solveRhsT`.
- Consumers: [dcmatch](../analysis/dcmatch.md) (future — hard
  requirement), [sensitivity](../analysis/sensitivity.md) adjoint + AC
  upgrade, later optimization/tuning loops.
- Bench fixtures: `benchmark/fixtures/sens/*` (FD path is the oracle the
  analytic stamps must match).
