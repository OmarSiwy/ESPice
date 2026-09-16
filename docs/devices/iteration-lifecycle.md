# Verilog-AMS Newton iteration state

VAMS-2023 §§9.15 and 9.17.3 require runtime iteration information and history for
user-defined `$limit` functions. A limiter's `$discontinuity(-1)` prevents the
solver from accepting a point while the limited value differs materially from
the access-function value. These affect the convergence path, not the circuit's
constitutive equation. See the [Accellera language reference](https://www.accellera.org/images/downloads/standards/v-ams/VAMS-LRM-2023.pdf).

VerA emits optional `beginSolve`, `advanceIteration`, and `checkConvergence`
functions. ARPice exposes them through the device-type hook table:

1. Begin each direct Newton or JFNK solve, including continuation attempts and
   fallback solves, with `beginSolve`. This resets the iteration counter; it
   preserves limiter history and accepted-time state.
2. Before every subsequent outer iteration, call `advanceIteration` with the
   previous evaluated vector. Never advance on a finite-difference evaluation
   or after the final accepted iteration.
3. Check `checkConvergence` against the proposed accepted vector, after applying
   the Newton correction and before staging accepted-time state. JFNK's
   zero-residual path performs this check too.
4. Keep timestep commit/revert separate. VerA's `stateCtl` snapshots both the
   limiter history and iteration counter; a new solve resets the counter again.

Iteration hooks do not write the integration or event history managed by
`updateState`. Both CPU solvers stage that history only after their numerical
and device convergence gates pass. Existing transient commit/revert calls
continue to own accepted-time history.

Devices exposing iteration hooks are excluded from GPU residency. Mixed GPU
circuits evaluate those batches on the CPU and use the same solver lifecycle.
This is the fallback until resident kernels implement all three hooks and their
ordering. No GPU execution claim is made for these devices.

Verification includes solver tests for repeated solves, convergence vetoes,
zero residuals, preconditioner scaling, finite-difference isolation, and failure at the iteration limit;
batch tests for per-instance voltage gathering; and the `hdl/veriloga_limit`
numeric fixture, whose independently derived solution is 2 V. Run:

```sh
zig build test-solvers test-eval test-iteration
zig build test -- --filter hdl/veriloga_limit
ESPICE_SOLVER=jfnk zig build test -- --filter hdl/veriloga_limit
```

`test-iteration` compiles a Verilog-A model with limiter and reactive history.
Through Circuit and both solvers it commits an initial solution, forces a
Newton failure at a later trial, reverts, and retries at a smaller time. Its
residual, charge and solution match a circuit that never took the failed trial.
This uses the DC assembly hook at the selected times to isolate state rollback.
It does not exercise the transient companion equation, LTE rejection or the
transient driver's retry loop; those need separate integration coverage.

These tests cover the Newton hooks. They do not establish full Verilog-AMS
conformance, a digital event engine, arbitrary history/convolution support, or
bit-for-bit agreement with ngspice transmission-line algorithms. The full
compiler backlog remains in `../VerA/docs/CONFORMANCE-GAPS.md`.
