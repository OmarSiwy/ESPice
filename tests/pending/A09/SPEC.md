# A09 — Accepted/rejected state lifecycle

Plan row: **A09** (`ARPice/docs/verilog-ams-conformance-plan.md`, "Analog behaviour" section).
Scope: **host (ARPice) transient lifecycle**, exercised through `.hdl` Verilog-A models.

Nine fixtures, all positive (each asserts a concrete hand-derived value). No refusal
fixtures — see §5 for why the host oracle cannot express one.

Nothing outside this directory was touched. `src/`, `build.zig`, `tests/fixtures/` and
`VerA/tests/fixtures/` are unmodified.

**Headline count after the review corrections: 6 pass / 3 fail.** It was 5/4. Fixture 9
(`a09_limit_root_transient`) moved from fail to pass when the model stopped destroying its
own `$limit` seed — see §1 B2 (retracted) and §7. All three remaining failures are one root
cause (B1) seen three ways. That is a thinner deliverable than the row claimed, and it is
the true one.

---

## 1. Ground truth — what actually exists today

Established by reading source, not COVERAGE files, and then confirmed by running every
fixture from a source build (§4).

### Implemented and working

| Behaviour | Where | Evidence |
|---|---|---|
| `$abstime` published once per SOLVE ATTEMPT, before anything evaluates it | `src/analysis/tran/tran.zig:543` (`ckt.setSimState`), `src/problem/device_ir.zig:203` (`set_sim_state` contract) | `a09_abstime_per_attempt` passes with 53 rejections in the run |
| `analog initial` runs once per analysis | VerA lowering; not re-entered per attempt | `a09_analog_initial_once` passes |
| `cross()` held variables reverted on a rejected attempt, applied once on acceptance | `stateCtl(.revert)` at `tran.zig:580/609/668`; generated `stateCtl` at `VerA/src/backend/codegen.zig:2506` | `a09_cross_count_revert` passes; the counter reads back 0/1/2/3/4 bit-exactly |
| `absdelay` history pushed once per ACCEPTED step | `src/analysis/eval.zig:1291-1292` routes a device with `absdelay` state to the `commit_state` hook, which `tran.zig:796` calls once per accepted point | `a09_absdelay_accepted_only` passes with **zero** error across 51 rejections |
| `$limit` preserves the equation root through a transient | existing `tests/fixtures/hdl/veriloga_limit.sp` at `.op`; `a09_limit_root_transient` at `.tran` | `a09_limit_root_transient` passes: 57 accepted steps, 0 rejections, 2.00 NR iterations per attempt, root within 5.74e-8 |
| `$bound_step` read after an accepted step | `tran.zig:632` (`ckt.boundStep()`), `eval.zig:1494` | not asserted here — belongs to A10 |

The `.op` root of the A09 limiter model is **`1.0000000574268284`**, not "exactly 1.0" as two
places in the previous revision of this document asserted. Measured (§4); it is also exactly
the `t = 0` point of the transient, which is the consistency one would want.

### Broken

**B1 — operator accepted-time state is advanced on attempts that are later rejected, and
never rolled back.**

`Hooks.update_state` is called from `converger.checkConverged`
(`src/analysis/solvers/converger.zig:316`) — **once per CONVERGED attempt**, which is not
the same thing as once per accepted step. `tran.zig` then rejects converged attempts in two
places: the device-state flip (`tran.zig:607`) and the truncation-error bound
(`tran.zig:665`). Both call `ckt.stateCtl(.revert)`.

The generated `stateCtl` (`VerA/src/backend/codegen.zig:2506-2570`) reverts only
`State.limiter_previous`, `State.newton_iteration`, the FSM held variables and the `cross`
`__prev` histories. It does **not** revert `State.t_prev` (written at `codegen.zig:7237`),
the operator accumulators `inst.<op>__acc` / `inst.<op>__prev` (`codegen.zig:7060-7075`) or
the §9.13.1 internal RNG seeds `inst.rng_auto` (`codegen.zig:7039`).

So the retry evaluates `const dt = inst.abstime - state.t_prev;` (`codegen.zig:7024`) with
`state.t_prev` already sitting at the *rejected* time, making `dt` negative; `zIdtAcc`
(`codegen.zig:8155`) returns `ic` whenever `dt <= 0`, which discards the entire integral.

Measured today: `idt(1.0, 0)` over `.tran 0.05 1.0` ends at **0.12499937** instead of 1.0
with a cross-driven rejector present, and at **0.02712235** instead of 1.0 with a
truncation-error driven one. See §4.

`absdelay` escapes only because `hasAbsdelayState(D)` (`eval.zig:1291`) moves the *whole*
`updateState` of that device to the accepted-step hook. The split is **per device, not per
operator**: a device that owns an `idt` and no `absdelay` stays on the per-attempt hook.
The comment at `converger.zig:290` — "`state.t_prev` is written by every generated device
and read by none" — is the assumption that makes the placement look safe; `t_prev` is read,
by `updateState` itself, thirteen lines of generated code later.

**B2 — RETRACTED. `$limit` gets through a transient step; the previous revision's own
fixture was what stopped it.**

This document previously claimed "`$limit` cannot get through a transient step", evidenced
by `DT UNDERFLOW (newton) at t=0 dt=7.1e-19 accepted=0 attempts=48`. That was true of the
deck as written and false of the host. The model opened its limiting function with

```verilog
if ($simparam("iteration") == 1) limited = 0.0;
```

which throws away the state §9.17.3 defines for the second argument ("the appropriate
internal state; generally, this is the value that was returned by the `$limit()` function on
the previous iteration") and re-seeds the Newton iteration from 0 V at every attempt. With
that line deleted, and nothing else about the host changed, the same deck runs
**57 accepted / 57 attempts / 114 NR iterations / 0 rejections** and lands on the root to
5.74e-8. The claim is withdrawn. It is not relocated to another row: there was no host
defect to relocate.

The reviewer's related point stands and is recorded: closing a fixture by raising `itl4`
pins nothing about state lifecycle. That is precisely why the seed reset had to go rather
than the option be bumped.

### Found in passing — a real VerA codegen defect, out of this row's scope

VerA's codegen hoists a `real` that is assigned inside a branch into an array it names `h`
(`VerA/src/backend/codegen.zig:3248`, `hoistArray`). The generated core file already opens
with `const h = @import("../h.zig");`, so the hoist array shadows it and **any** model with a
conditionally-assigned real fails to build:

```
u/<module>__common__core.zig:64:9: error: local variable shadows declaration of 'h'
    var h: [2]S = undefined;
Error: <deck>.sp: GeneratedDeviceDoesNotCompile
```

Reproduced today on both a source build and the checked-in `zig-out/bin/espice`. It is why
`a09_limit_ramp`'s limiter is spelled with `min`/`max` rather than spicepnjlim's guarded
`if` block — the `.va` header says so at the point of the workaround. Fixing it is a one-word
rename in `hoistArray` and belongs to whoever owns `codegen.zig`, not to a fixture row.

### Dead exports (no fixture possible through this oracle — see §5)

* `$discontinuity`: VerA writes `inst.discontinuity_order` (`codegen.zig:7031, 7163, 7208`).
  Grep across `ARPice/src` finds **no reader**. The model announces a discontinuity and the
  engine neither drops integration order nor shortens the step because of it.
* §9.4.6 / §9.5.9 deferred output: `src/frontend/model_loader.zig:101` calls
  `result.generateDevice()` with the default `codegen_opts`, i.e.
  `codegen.Display = .drop` (`VerA/src/backend/codegen.zig:127-132`). Every `$strobe`,
  `$display`, `$fwrite` and `$fdebug` in a `.hdl` model is discarded at code generation.
  VerA does emit the entry point (`pub fn display(...)`, `codegen.zig:6239`) — nothing in
  ARPice references it.
* `request_reject_at`: `converger.zig:302` records that all 27 generated devices return
  `.ok` unconditionally, so the device-requested-reject branch is dead.

---

## 2. LRM clauses covered

Read from the offline HTML in `VerA/docs/`. Every quote below was re-opened in
`ch4-expressions.html`, `ch5-analog.html`, `ch8-scheduling.html` and `ch9-system.html`
during the post-review pass; the ones that did not survive are listed in §7.

| Clause | Sentence that governs |
|---|---|
| **4.5.4** Time integral operator | Table 4-18: `idt(expr,ic)` "Returns ∫(t0..t) x(τ)dτ + c, where in this case c is the value of ic at t0". |
| **4.5.7** Absolute delay operator | "In time-domain analyses, absdelay() introduces a transport delay equal to the instantaneous value of td based on the following formula. Output(t) = Input(max(t − td, 0))". |
| **4.5.15** Restrictions on analog operators | "It is important to ensure that all analog operators are evaluated every iteration of a simulation to ensure that the internal state is maintained." / "All analog operators are considered to have no state history prior to time t == 0." |
| **5.2.1** Analog initial block | "The analog initial block is executed once for each analysis, and can be executed for each sub-task of parameter sweep analysis (such as dc sweep)." Every deck here runs a single `.tran`, so the sub-task clause is not engaged. |
| **5.10.3.1** `cross` function | "If dir is +1, the event and timestep control only occur on rising edge transitions of the signal." / "The event shall occur after the threshold crossing, and while the signal remains in the box defined by actual crossing and expr_tol and time_tol." |
| **8.2** Simulation initialization | "It is during this process that module-level variable declaration assignments are evaluated followed by the execution of analog initial blocks." — before the 8.3 simulation cycle. |
| **8.3.2** Transient analysis | "The simulator controls the interval between the time points to ensure the accuracy of the finite difference approximation." — which is also why no step-count digits are written anywhere in this row. |
| **8.3.3** Convergence | the iterate values are not the solution; only the converged point is. The convergence criterion's shape, and reltol "typically … 0.001". |
| **8.4.7** Assumptions about the analog and digital algorithms | Under **"Advance of time in an analog algorithm"**, third bullet: "Having calculated the solution for a given time, the analog engine can either accept or reject that solution; it cannot calculate a solution for a future time until it has accepted the solution for the current time." **Nothing else in 8.4.7 is cited by this row** — see §7 for the withdrawal. |
| **9.10** Simulator time system functions | "$abstime returns the absolute time, that is a real value number representing time in seconds." |
| **9.17.1** `$discontinuity` | "A special form of the $discontinuity task, $discontinuity(-1), is used with the $limit() function". |
| **9.17.3** `$limit` | "When the simulator has converged, the return value of the $limit() function is the value of the access function reference, within appropriate tolerances" / "On any iteration where the output value is not the same as the value of the access function (within appropriate tolerances), the simulator is prevented from terminating the iteration" / "the simulator is responsible for determining if limiting should be applied and what the return value is on a given iteration". |

Quoted in the individual `.assets/*.va` headers, which is where the derivation lives.

---

## 3. One line per fixture

All decks force their rejections deterministically. The `cross`-driven decks use
`a09_cross_rejector`, whose rising zero crossings of `sin(2π(t−0.125)/0.25)` in (0, 1] are
exactly **t = 0.125, 0.375, 0.625, 0.875**; every sample time is chosen clear of those.

| # | Fixture | Pins | Expected value and derivation | Today |
|---|---|---|---|---|
| 1 | `a09_idt_ramp_clean` | control case: the `idt` accumulator advances once per accepted point, with no rejection in the run | `v(out) = t` at t = 0, 0.2, 0.4, 0.6, 0.8, 1.0. §4.5.4: ∫1 dτ + 0 = t. The accepted dt sum to t whatever the controller picks, so the identity is step-sequence- and method-independent. Linear in t ⇒ the harness's interpolation is exact. | **PASS** |
| 2 | `a09_idt_bystander_reject` | a rejection raised by *another* instance must not touch this one's operator state | `v(out) = t` at the same six times. N2 costs the host a rejected/retried step at each of the four crossings (§5.10.3.1, §8.4.7); N1 owns no event and no charge, so §4.5.15 leaves its accumulator on the accepted lifetime. | **FAIL** — ends at 0.12499937 |
| 3 | `a09_idt_self_reject` | the instance that *causes* the rejection keeps its own accepted-time state | `v(out) = t + 1e-3·flips(t)` sampled at the plateau **midpoints** t = 0.05, 0.25, 0.5, 0.75, 0.95, where flips = 0, 1, 2, 3, 4 ⇒ **0.05, 0.251, 0.502, 0.753, 0.954**. Midpoints, not the old 0/0.2/…/1.0 grid: the harness interpolates between bracketing accepted rows and the old grid sat 0.025 from a 1e-3 riser at rtol 1e-9 — clean only by luck of today's `avg_dt` = 6.8e-3. Nearest riser is now 0.075 away. | **FAIL** |
| 4 | `a09_idt_lte_reject` | the *second* rejection origin: the truncation-error controller, not an event | `v(out) = t` at the same six times as 1 and 2. The Rs/C1 branch at 20 Hz makes §8.3.2's step control reject repeatedly; N1 stores no charge. | **FAIL** — ends at 0.02712235 |
| 5 | `a09_abstime_per_attempt` | `$abstime` is the attempted point's time and the accepted row carries the accepted time | `v(ta) = t` at t = 0, 0.2, 0.4, 0.6, 0.8, 1.0. §9.10 + §8.4.7: the engine cannot advance past an unaccepted solution, so no accepted row may carry a rejected trial time. | **PASS** |
| 6 | `a09_analog_initial_once` | `analog initial` executes exactly once, at initialization | `v(ini) = 1.0` at t = 0, 0.25, 0.5, 0.75, 1.0. `real runs` defaults to 0 and is incremented once. §5.2.1 + §8.2: 0.0 ⇒ skipped, 2.0 ⇒ re-run for the transient's initial DC solve, climbing ⇒ re-run per timepoint/attempt/iterate. | **PASS** |
| 7 | `a09_cross_count_revert` | a side effect staged by a rejected attempt is rolled back; applied exactly once on acceptance | KCL `1e-3·(V − flips) = 0` ⇒ `v(rej) = flips` exactly ⇒ **0, 1, 2, 3, 4** at t = 0.05, 0.25, 0.5, 0.75, 0.95 (each inside a flat plateau, so interpolation is exact). §5.10.3.1 licenses exactly one event per rising transition, so four and only four; §8.4.7's analog-advance bullet plus §8.3.3 make an iterate not a solution. Over-count ⇒ a rejected increment survived; under-count ⇒ an accepted one was lost. | **PASS** |
| 8 | `a09_absdelay_accepted_only` | delay-line history is accepted-step state; a sample pushed on a rejected attempt records a time that never happened | §4.5.7's `Output(t) = Input(max(t − td, 0))` with `Input = $abstime`, `td = 0.1` ⇒ **0, 0.1, 0.3, 0.5, 0.7, 0.9** at t = 0.05, 0.2, 0.4, 0.6, 0.8, 1.0, all clear of the t = 0.1 kink. Input is linear in t ⇒ the history interpolation is exact. | **PASS** (error exactly 0) |
| 9 | `a09_limit_root_transient` | at a converged point the `$limit()` return value **is** the value of the access function reference | Unique real root of `exp(vlim) − exp(1 + 0.5t) = 0` is `vlim = 1 + 0.5t` ⇒ **1.0, 1.25, 1.5, 1.75, 2.0** at t = 0, 0.5, 1.0, 1.5, 2.0, and the rawfile records `V(p,n)`, so the equality is §9.17.3's converged-value sentence and nothing else. Band is rtol 1e-3 / atol 1e-6, not 1e-9: "within appropriate tolerances" is implementation-defined and §8.3.3 calls reltol "typically … 0.001". Still has teeth — a solver that terminates while the limiter clamps is off by up to 0.5 V, 250–500× the band. | **PASS** (max error 5.74e-8) |

6 pass / 3 fail. The three failures are all B1. Stated plainly: after the corrections this
row delivers **one** defect, demonstrated from three independent rejection origins
(another instance's event, its own event, the LTE controller), plus six regression pins for
behaviour that is implemented and was previously unpinned.

### What this row does *not* pin about `$limit`, and why no digits are written

§9.17.3 defines the second argument as "the appropriate internal state; generally, this is
the value that was returned by the `$limit()` function on the **previous iteration**". It
says nothing about the previous *accepted step*, and §8.3.2 leaves step placement to the
simulator. There is therefore no normative identity connecting `$limit` state to the
accept/reject boundary, so no fixture asserts one. Iteration count and step count are
likewise implementation-defined and no digits are written for them anywhere in this row.

---

## 4. Observed behaviour (captured, not typed)

ARPice does not build on `main` today — `src/analysis/pss/hb.zig:286` uses
`std.posix.getenv`, removed in Zig 0.16 (that is row **Q03**, see
`tests/pending/Q03-releasefast/SPEC.md`). Verification used a scratch tree with that one
token replaced by `std.c.getenv`, per Q03's own recipe:

```sh
rm -rf /tmp/a09 && mkdir -p /tmp/a09
cd /home/omare/Documents/Projects/Zig/ARPice \
  && tar --exclude=.zig-cache --exclude=zig-out --exclude=.git --exclude=obj_dir -cf - . \
   | (mkdir -p /tmp/a09/ARPice && cd /tmp/a09/ARPice && tar xf -)
ln -sfn /home/omare/Documents/Projects/Zig/VerA    /tmp/a09/VerA
ln -sfn /home/omare/Documents/Projects/Zig/gompute /tmp/a09/gompute
sed -i 's/std\.posix\.getenv("ESPICE_HB_TRACE")/std.c.getenv("ESPICE_HB_TRACE")/' \
  /tmp/a09/ARPice/src/analysis/pss/hb.zig
cd /tmp/a09/ARPice && zig build            # succeeds, produces zig-out/bin/espice
```

Every deck below was then run from a copy of this directory with the same argv the
correctness runner uses (`tests/test_correctness.zig:190`):

```sh
ZP_TRAN_STATS=1 /tmp/a09/ARPice/zig-out/bin/espice \
    --backend=cpu --format=binary -b -r <out>.raw <deck>.sp
```

and the rawfile sampled with linear interpolation between bracketing accepted rows, which is
what `tests/test_correctness.zig:510-534` does. Numbers below are copied from that output.

```
a09_idt_ramp_clean         accepted=57  attempts=57  rej[newton=0 lte=0 state=0]   avg_dt=1.754e-2
                           v(out) = 0, 0.2, 0.4, 0.6, 0.8, 1  exact at all six

a09_idt_bystander_reject   accepted=147 attempts=200 rej[newton=0 lte=0 state=53]  avg_dt=6.803e-3
                           v(out) = 0, 0.074999709, 0.024999264, 0.224999264,
                                    0.174999818, 0.124999373     want t  (resets to ic per burst)

a09_idt_self_reject        accepted=147 attempts=200 rej[newton=0 lte=0 state=53]
                           v(out)@{0.05,0.25,0.5,0.75,0.95} =
                                    0.05, 0.125999709, 0.126999264, 0.127999818, 0.078999373
                           want     0.05, 0.251,       0.502,       0.753,       0.954
                           the 1e-3 risers are all present and correctly placed — the idt
                           half is what is lost

a09_idt_lte_reject         accepted=300 attempts=425 rej[newton=0 lte=125 state=0] order_drops=52
                           v(out)(1.0) = 0.027122349     want 1.0

a09_abstime_per_attempt    accepted=147 attempts=200 rej[state=53]
                           v(ta) = 0, 0.2, 0.4, 0.6, 0.8, 1  exact at all six

a09_analog_initial_once    accepted=147 attempts=200 rej[state=53]
                           v(ini) = 1 at every sample; exactly one distinct value in the run

a09_cross_count_revert     accepted=147 attempts=200 rej[state=53]
                           v(rej)@{0.05,0.25,0.5,0.75,0.95} = 0, 1, 2, 3, 4   bit-exact

a09_absdelay_accepted_only accepted=177 attempts=228 rej[state=51] bp_landings=10
                           v(dl) = 0, 0.1, 0.3, 0.5, 0.7, 0.9   worst error exactly 0

a09_limit_root_transient   accepted=57  attempts=57  nr_iters=114  rej[newton=0 lte=0 state=0]
                           v(lim) = 1.0000000574268284, 1.2500000202674606,
                                    1.5000000202674602, 1.7500000202674604,
                                    2.0000000055791438
                           want     1.0, 1.25, 1.5, 1.75, 2.0    max |err| = 5.74e-8
                           .op on the same model: v(lim) = 1.0000000574268284
```

A standalone checker that replicates the oracle's sampling comparison is not shipped here;
§6 gives the real command. `netlist_sha256` in all nine `*.expected.json` was regenerated
from the shipped `.sp` bytes after these edits and re-verified — `test_correctness.zig:156`
returns `StaleOracle` otherwise, and three of them were stale before this pass.

---

## 5. Deliberately NOT covered

* **§9.4.6 deferred display output** ("All display tasks, except `$debug`, shall not display
  output unless an iteration has been accepted") and **§9.5.9 file I/O rollback** ("the file
  pointer is reset to the file position that it pointed to before the iterative solve
  started" / `$fdebug` writes even on a rejected iteration). Not expressible in this
  harness: `tests/test_correctness.zig` compares the rawfile, not stderr or a scratch file.
  And the feature is currently *absent by construction* — ARPice compiles every `.hdl` model
  with `Display = .drop`, so nothing is printed at all. Covering it needs a golden-stderr /
  golden-file host harness, which is a separate deliverable.
* **§9.17.1 `$discontinuity`** as a step-control hint. `inst.discontinuity_order` is written
  and read by nobody; the only observable through the rawfile would be an accuracy argument
  whose expected value is not hand-derivable. The `$discontinuity(-1)` *pairing* with
  `$limit` is exercised by fixture 9.
* **`$limit` state across a rejected step.** No fixture, because §9.17.3 states no identity
  to assert — see the note at the end of §3.
* **§9.13.1 random streams across rejection and re-entry.** The internal seed advance sits
  in `updateState` (`codegen.zig:7039`), i.e. on the same per-converged-attempt hook as B1,
  and `stateCtl(.revert)` does not restore it — so it has the same defect. No fixture,
  because no *hand-derived* expected value exists without pinning VerA's RNG kernel itself,
  which would be testing the implementation rather than the LRM. If a run-to-run pin is
  wanted later, `tests/test_correctness.zig:543` already supports a `repeatability` check
  (`same_netlist` + `bitwise_numeric_results`); it does not prove the stream is on the
  accepted-step boundary, only that two identical runs agree.
* **§9.17.2 `$bound_step`, `timer`, breakpoint requests, step bounds** — plan row **A10**.
* **Auxiliary transient drivers and periodic analyses** (pss / hb / pac / pnoise re-entry).
  Those analyses do not run `tran.zig`'s accept/reject loop; they need their own decks and
  their own derivations.
* **GPU execution** (`src/analysis/gpu.zig`). The plan says keep it excluded until it obeys
  the same semantics; every deck here runs `--backend=cpu` (the default).
* **Refusal fixtures.** Zero, on purpose. The §4.5.15 refusals (analog operator under a
  data-dependent conditional, inside an analog function, inside `repeat`/`while`/non-genvar
  `for`, inside `initial`) are already green in VerA at
  `tests/fixtures/ch04_expressions/{36,89,90,91,92,93}_*.va` and
  `tests/fixtures/ch05_analog_behavior/*`. And the host oracle could not express one anyway:
  `checkRejection` (`tests/test_correctness.zig:214-229`) maps only
  `invalid_analysis_arguments`, `nonunique_operating_point` and `inconsistent_circuit` —
  there is no category for a Verilog-A source refusal.

---

## 6. Command that will exercise these once wired up

The fixture catalog walks `tests/fixtures` for `*.sp` and requires a sibling
`<name>.expected.json` (`tests/fixture_catalog.zig:12-31`), and the runner resolves
`.hdl` paths relative to the netlist (verified from the repo root). So wiring is a move:

```sh
cd /home/omare/Documents/Projects/Zig/ARPice
git mv tests/pending/A09 tests/fixtures/a09_lifecycle     # SPEC.md may stay or move
zig build                                                 # blocked on Q03 today
zig build test -- --filter a09                            # or: zig build test-correctness -- --filter a09
```

Expected once A09 lands: **9/9 PASS**. Expected the moment they are wired in, before any
fix: **6 PASS, 3 FAIL** — `a09_idt_bystander_reject`, `a09_idt_self_reject` and
`a09_idt_lte_reject`, all on value, all B1.

Do **not** move them under `tests/fixtures/` until the row is being worked: the catalog is
compile-time and `zig build test` is the green gate.

---

## 7. Corrected after review

Every change below is inside `tests/pending/A09/`. Nothing in `src/`, `build.zig` or either
`tests/fixtures/` tree was touched.

**Citations that did not survive being opened.**

1. *Withdrawn, not relocated.* `a09_limit_ramp.va` called its limiter "the half-volt-per-
   iteration limiter of the LRM's own `$limit` example pattern". §9.17.3's only `$limit`
   example is `spicepnjlim`, which clamps by `vt*ln(arg)`, never by a fixed 0.5 V, and never
   discards the incoming value. There is no half-volt limiter in the standard. The phrase was
   not even a misreading of the LRM — it was copied from this repo's own comment on
   `tests/fixtures/hdl/veriloga_limit.assets/va_limit.va`. **Where it went: nowhere. No row
   owns it, because no clause contains it.** It can come back only if a future revision of
   the standard ships such an example. The model now states, and only states, what
   `spicepnjlim` actually demonstrates: return the first argument unchanged when no limiting
   is needed, and call `$discontinuity(-1)` exactly when it is.
2. *Withdrawn to M02.* §8.4.7's "they can be rejected along with the solution, if it is
   rejected" was cited by `a09_cross_count_revert`. Re-opened: that sentence sits under
   §8.4.7's **"Analog to digital events"** heading and is conditioned on "until they are
   consumed by the digital engine". These decks have no digital engine, so it does not reach
   them. **Where it went: plan row M02**, whose clause list already spans §8.4.1–§8.4.7 and
   which does have a digital consumer. It can come back to A09 only in a deck that gives the
   `cross` event a digital consumer. What A09 now cites from §8.4.7 is the third bullet of
   **"Advance of time in an analog algorithm"**, which is unconditional and on point; the
   revert obligation is carried instead by §5.10.3.1 ("shall occur", one event per rising
   transition) plus §8.3.3 (an iterate is not a solution). Corrected in the `.sp` header, the
   `.expected.json` derivation and §2/§3 of this document.
3. A `$limit` premise presented between two genuine §9.17.3 quotes — "it may defer
   convergence; it may not move the root and it may not cost the solver its step" — was not in
   §9.17.3 at all. §9.17.3 says the simulator "is responsible for determining if limiting
   should be applied and what the return value is on a given iteration", and §8.3.2 leaves
   "the interval between the time points" to the simulator. Iteration economy and step economy
   are therefore implementation-defined, **so no digits are written for them** in the deck, the
   oracle or this document. Only the first clause — the converged-value identity — is
   asserted, and that is the whole of what fixture 9 now claims.

**Wrong expected values and wrong recorded facts.**

4. This document twice asserted "`.op` on the A09 model gives exactly 1.0". Re-measured from
   a source build: **`1.0000000574268284`** (5.74e-8 high), identical to the transient's
   `t = 0` point. Corrected in §1 and used to justify fixture 9's band.
5. Fixture 9's column band was `rtol 1e-6 / atol 1e-7` in the oracle while the deck header
   claimed `rtol 1e-3 / atol 1e-6`. The header's reasoning was the right one and the oracle
   now matches it: `atol 1e-7` left only a 1.15× margin over the measured 5.74e-8 residual,
   which is a tripwire for any conforming solver that stops at its own reltol. The band keeps
   teeth — a solver terminating while the limiter clamps is off by up to 0.5 V, 250–500× it.
6. Fixture 9's model destroyed its own `$limit` seed with
   `if ($simparam("iteration") == 1) limited = 0.0;`, forcing ~20 NR iterations per timepoint
   by construction and producing the `TimestepTooSmall` this row banked as defect B2. Removed.
   B2 is retracted in §1 with the measurement that retracts it. The row's failing count drops
   from 4 to 3 and the headline in §0 says so.
7. `a09_idt_self_reject` sampled at t = 0.6, which is 0.025 before a 1e-3 riser at t = 0.625,
   at `rtol 1e-9`, while the harness interpolates linearly between bracketing accepted rows.
   It passed only because today's `avg_dt` is 6.8e-3. All five samples moved to plateau
   midpoints (0.05, 0.25, 0.5, 0.75, 0.95); the nearest riser is now 0.075 away, ~11 steps at
   today's `avg_dt` and still clear of a controller ten times coarser. The reviewer suggested
   moving the one sample to 0.55; moving all five to midpoints fixes the same hazard at the
   other four samples too, which the single move would have left in place.
8. **Reproduction defect, found during this pass and not in the review:** three
   `netlist_sha256` fields (`a09_cross_count_revert`, `a09_idt_self_reject`,
   `a09_limit_root_transient`) had gone stale against their edited `.sp` files.
   `test_correctness.zig:156` fails the case with `StaleOracle` before the simulator ever
   runs, so all three would have errored rather than failed on value. All nine regenerated and
   re-verified.
9. §4's transcript is re-captured, not carried over: every number in it was produced by the
   source build described at the top of §4 during this pass. The previous transcript was
   measured against a stale `zig-out/bin/espice`. Eight of the nine decks reproduced their old
   numbers exactly; the ninth (fixture 9) did not, for the reasons in items 5–6.

**Note left for `codegen.zig`, not fixed here.** The branch-hoist array VerA names `h`
shadows the generated file's own `const h = @import("../h.zig")`, so every model with a
conditionally-assigned real fails to build. §1 "Found in passing" has the reproducer. It is
why fixture 9's limiter is spelled branch-free; that workaround is documented at the point of
use in the `.va`.
