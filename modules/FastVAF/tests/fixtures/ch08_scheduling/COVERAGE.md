# Chapter 8 — scheduling semantics

Source: docs/ch8-scheduling.html. Every HTML section id is listed literally. Device dumps cover equations and event metadata; global queues, engine arbitration and time advancement belong to the simulator host.

Parser-boundary disclosure: FastVAF rejects digital `initial`/`always` module items
before entering their statement bodies. Consequently the blocking-timing,
assign/deassign, force/release, and nonblocking fixtures preserve the normative source
forms but do not validate queue-region semantics. The mixed analog/digital initial-order
fixture likewise cannot test relative execution order after the digital item is rejected.

| HTML id | Rule exercised | Fixtures / disposition |
|---|---|---|
| `s8-1` | analog/digital engines and macro-processes | `analog_macro_process.va`; digital engine is outside VA codegen |
| `s8-2` | compilation, elaboration and initialization order | `analog_initial_order.va` |
| `s8-3` | iterative analog simulation cycle | `static_nodal.va`, `dynamic_nodal.va` |
| `s8-3-1` | f(v,t)=dq/dt+i and KFL stamping | `static_nodal.va`, `dynamic_nodal.va`, `multi_branch_kfl.va` |
| `s8-3-2` | transient derivative discretization | `dynamic_nodal.va`, `integrator_state.va` |
| `s8-3-3` | Newton convergence and safe nonlinear equations | `nonlinear_safe.va` |
| `s8-4` | mixed-signal cycle | `analog_event.va`; cross-engine loop is host-only |
| `s8-4-1` | analog initial before time-zero digital initial | `analog_initial_order.va`; `analog_digital_initial_order_unsupported.va` is source inventory masked at the digital `initial` item |
| `s8-4-2` | iterative mixed-signal DC | `above_initial_event.va`; fixed-point engine loop is host-only |
| `s8-4-3` | transient mixed-signal processes | `analog_event.va` |
| `s8-4-3-1` | concurrency and shared-memory restriction | `multiple_analog_blocks.va`; thread scheduling is host-only |
| `s8-4-3-2` | acceptance/wakeup and guarded sensitivity | `cross_wakeup.va`, `timer_wakeup.va`, `explicit_guard.va` |
| `s8-4-3-3` | A/D time quantization/zero-delay round trip | `digital_boundary_unsupported.va` |
| `s8-4-4` | synchronization loop and event cancellation | `cross_wakeup.va`; cancellation implementation is host-only |
| `s8-4-5` | synchronization/communication algorithm | `analog_event.va`; engine arbitration is host-only |
| `s8-4-6` | interpolated absdelta A2D events | `absdelta_unsupported.va` |
| `s8-4-7` | analog/digital advance and rejection assumptions | `event_state.va`; solution accept/reject is host contract |
| `s8-5` | digital engine scheduling semantics | `digital_process_unsupported.va` |
| `s8-5-1` | seven stratified queue regions | `digital_process_unsupported.va`; queue is not generated device code |
| `s8-5-2` | digital reference-model loop | `digital_process_unsupported.va` |
| `s8-5-3` | assignment scheduling | `digital_assignment_unsupported.va` |
| `s8-5-3-1` | continuous assignment active update | `digital_assignment_unsupported.va` |
| `s8-5-3-2` | procedural assign/deassign/force/release | `procedural_assign_unsupported.va`, `procedural_deassign_unsupported.va`, `procedural_force_unsupported.va`, `procedural_release_unsupported.va`, `procedural_continuous_unsupported.va`; bodies are masked by the outer unsupported digital process |
| `s8-5-3-3` | blocking assignment delay and event timing | `blocking_timing_unsupported.va`; body is masked by the outer unsupported digital process |
| `s8-5-3-4` | nonblocking update region | `nonblocking_unsupported.va` |
| `s8-5-3-5` | bidirectional switch processing | `switch_primitive_unsupported.va` |
| `s8-5-3-6` | explicit D2A region 1b | `digital_boundary_unsupported.va` |
| `s8-5-3-7` | macro-process region 3b | `analog_macro_process.va`; queue placement is host-only |
