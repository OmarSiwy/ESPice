# Full Verilog-AMS implementation plan

Target: Accellera Verilog-AMS 2023, including the inherited IEEE 1364 digital
language, mixed-signal execution, and the required programming interfaces.
Primary reference: [VAMS-2023 LRM](https://www.accellera.org/images/downloads/standards/v-ams/VAMS-LRM-2023.pdf).
Compiler inventory: [VerA conformance gaps](../../VerA/docs/CONFORMANCE-GAPS.md).
This plan covers VerA and the simulator services supplied by ARPice.

**Full conformance is not implemented.** This is an implementation and audit
checklist, not a certification or a measured percentage. Some entries identify
known missing code; others require execution evidence for code already present.
The inherited Verilog requirements still need a complete clause-level audit.
An unexamined requirement is open, even when every current fixture passes.

## Completion rules

Each requirement needs a standard reference, implementation owner, supported
execution path, positive behavioral test, applicable invalid-input test, and
recorded result. Compiler acceptance alone cannot close runtime behavior.
Rejection of a legal feature remains an implementation limitation. A rejection
fixture must not count as positive coverage of that feature.

For numeric behavior, tests must exercise the specified model and algorithmic
semantics with stated floating-point tolerances. Replacing a required operator
with a simpler transfer function does not close it. Test nondeterministic digital
behavior against the permitted outcomes; do not assert one arbitrary race order.

Resource limits, unspecified behavior, implementation-defined choices, optional
features, and mandatory features must be classified separately from the standard.
An implementation-defined choice needs documentation and tests. Annex C defines
the analog subset; it does not exempt this full-AMS target from digital features.
Annex G is historical material. SystemVerilog additions are a separate target.

No package below closes merely because its unit tests pass. The compiler, generated
device, standalone runner, simulator, and public interfaces involved must agree.
Every package requires a build, appropriate unit and behavioral tests, and the
relevant regression suites. Broader failures remain visible rather than being
reclassified as successes. See Q01–Q04 for the final conformance gate.

## Agent assignments and dependencies

Three implementation workers can run concurrently with the integrating agent.
Each works from the same source snapshot in a private directory; patches are
reviewed and combined before changes reach the shared compiler. This prevents
concurrent edits to `lower.zig` and `codegen.zig` from overwriting one another.

| Work item | Current assignment | Scope of the current patch |
|---|---|---|
| D01 | `ams_digital` | Frontend and packed four-state helpers integrated; initial-process source slice now preserves runtime X/Z |
| A05 | `ams_tables` | First-call mutable-array snapshots integrated; compiler regression and direct/JFNK numeric circuit pass |
| S01 | `ams_formatting` | Integer ASCII-string formatting implemented and reviewed. Unsupported operand widths diagnose explicitly |
| H01 | `ams_dynamic_arrays` | Exact defaults, conditional/short-circuit derivation, logical shifts and real remainder integrated and reviewed; general context typing remains open |
| A01 | `ams_dynamic_arrays` | Runtime multidimensional reads/writes, direction, scope and guarded reads integrated and reviewed |
| D02 | Integrating agent and `ams_parameter_precision` | Recursive typing, integral power, casts and concatenation/replication integrated; packed read selects under implementation |
| D04/D05 | `ams_parameter_precision` and `ams_standards_review` | Initial/always control flow and explicit `@` event control integrated; 44 scheduler/time/source tests and four CLI transcripts pass; implicit sensitivity, named events and mixed-signal re-entry remain open |
| A07 | `ams_dynamic_arrays` and `ams_standards_review` | Reference algorithms, guarded errors and host overrides integrated; paramset skipped-arm folding under implementation; fractional counts and lifecycle open |
| Q03 | Integrating agent | Loader isolation and CPU ABI 10 integrated; Problem allocation regressions and separate-object tests pass, combined verification continues |
| X01 | Integrating agent | Native routes and setup guards restored; prescribed ngspice-grid replay passes, five of eleven full waveform comparisons remain open |
| Q01–Q03 | Integrating agent and `ams_dynamic_arrays` | Compiler build, 370 units and 1,301 strict fixtures pass; host build and 295 units pass, circuit suite 494/616 with 122 failures |

Subsequent work is queued, not already running. The main dependencies are:

- D01 → D02/D03 → D04/D05 → D06/D07/D08/D09.
- D04/D05 plus analog lifecycle A09/A10 → M01/M02.
- D03/D07 plus hierarchy H01–H04 → M03/M04.
- The elaborated object model and scheduler → P01/P02/P03.
- A04/A09/A10/P03 plus a separate compatibility study → X01.
- Q01–Q04 apply throughout and finish after all mandatory requirements close.

## Digital language and execution

### D01 — Four-state literals and values

Known gap: the analog integer representation cannot retain digital X/Z states,
arbitrary packed widths, and all signedness information.

- Preserve literal width, radix, signedness, 0/1/X/Z bits and `?` spelling.
- Apply the required truncation and extension rules without clamping a declared
  width to the host's integer width or overflowing before truncation.
- Carry these values through parsing, constants, expressions and runtime storage.
- Distinguish unknown values from illegal analog uses; do not convert X/Z to zero.
- Test all based forms, unsized values, partial high digits, signed extension,
  values crossing word boundaries, and malformed input. Exhaustively test scalar
  truth tables and selected multiword cases.

The frontend retains packed four-state values and supplies tested arithmetic, bitwise,
logical, reduction, equality, conditional, shift, relational and resize helpers.
The initial-process runner preserves packed runtime values. Complete expression
sizing, additional storage kinds and legal analog case comparisons still need
D02, D03 and M01.

### D02 — Digital expression semantics

Packed value helpers implement addition, subtraction, multiplication, division,
remainder, integral power and unary minus, including multiword wraparound and X/Z
propagation. Twenty-two integer tests and the integrated compiler unit gate pass.
The source evaluator now propagates context through nested supported operators,
with separate sizing for comparison operands, shift counts, reductions/logicals
and conditional tests. Assignment contributes width without imposing its sign.
Independent review checked 61 value cases; permanent CLI fixtures include
129-bit cases. Integral power preserves independent exponent typing and uses
exact modular arithmetic; 112 independent Python-oracle cases pass in both
optimization modes. Casts, concatenation and replication now preserve
self-determined widths, X/Z and unsigned concatenation results. Independent
review checked 28 manual cases, 30 multiword cases and 17 rejection cases;
packed helpers have an independent bit oracle and allocation-failure tests.
Selects, general functions and complete unsized rules remain open.

- Implement expression and assignment sizing, signed/unsigned promotion, casts
  inherited from Verilog, arithmetic overflow, division, shifts, comparisons,
  logical/bitwise/reduction operators, and four-state conditional merging.
- Implement case equality/inequality, `case`, `casez`, `casex`, concatenation,
  replication, bit/part selects, and indexed part selects.
- Preserve widths through constant folding and generated execution; folding must
  not disagree with runtime evaluation.
- Test independent truth tables, signed boundary values, X/Z propagation, shift
  counts, mixed-width operands, select direction and out-of-range behavior.

### D03 — Digital declarations, memories, ports and drivers

- Represent packed nets/registers, integer/time/real/realtime/event declarations,
  arrays and memories, declaration assignments, port types and connections.
- Maintain independent drivers and receiver connectivity, including strengths,
  wired nets, supplies, tri-state behavior and charge-storage net behavior.
- Implement width/direction conversion at ports, collapsed connections where
  required, undriven values, and resolution after driver removal.
- Test multi-driver truth/strength tables, arrays, bidirectional connections,
  width mismatches, initialization and hierarchical port connectivity.

### D04 — Procedural execution

The shared-frontend `.v --run` path executes initial and always processes with
sequential blocks, whole-variable blocking/NBA assignments, integral delays,
explicit `@` event control, if/case and
while/repeat/for control, `%b` display and finish. CLI and unit tests distinguish inactive/NBA regions, captured RHS
values, lexical NBA order, time advance and cancellation. Unsupported forms
fail before execution. See [source execution scope](../../VerA/docs/digital-source-execution.md).

`@(v)`, `@(posedge v)`, `@(negedge v)` and `or` lists of those terms suspend a
process; both the active and NBA regions publish through one write path, so
either resumes it. The §5.10.1 edge table is followed on the least significant
bit, an unchanged write resumes nothing, and the terms of one event expression
share a single resumption. An `always` body that completes an iteration without
suspending is diagnosed rather than spinning the scheduler at one timestamp. An
edge-triggered D flip-flop with a clock generator simulates with correct NBA
sampling. Implicit sensitivity (`@*`), named events and intra-assignment event
controls remain open, as does
the general execution work below; analog device compilation still
uses its restricted constant-initial path.

- Execute `initial` and `always`, sequential/named blocks, conditionals, all
  inherited loops, blocking and nonblocking assignments.
- Implement delay/event controls, intra-assignment controls, `wait`, named event
  triggers, edge sensitivity and implicit sensitivity lists.
- Implement tasks/functions, argument passing, automatic/static lifetimes,
  recursion where permitted, `disable`, and parallel blocks/fork/join.
- Implement procedural assign/deassign and force/release with driver semantics.
- Test suspension/resumption, process lifetime, scope, edge tables, RHS sampling
  versus LHS update timing, and process cancellation.

### D05 — Event scheduler and time

Reference: AMS §8.5 and inherited Verilog scheduling rules.

The queue core and timescale utility pass 23 tests in Debug and ReleaseFast.
The connected initial-process runner brings `test-sim` to 39 passing tests in
Debug and ReleaseFast, plus scheduling, expression, control and concatenation
CLI transcripts. It preserves integer timestamps,
region promotion, NBA order, cancellation and analog request coalescing.
The analog solver is not connected yet. The
[scheduler notes](../../VerA/docs/simulator-scheduler.md) record the integration
work and the conflict between §8.5.1's D2A ordering and §8.5.2's pseudocode.
`src/sim/time.zig` validates decimal scales, preserves integral delay counts and
rounds real delays locally before integer global scaling. The
[time conversion notes](../../VerA/docs/digital-time.md) document real rounding,
explicit limits and the remaining source-level integration.

- Implement active, explicit D2A, inactive, nonblocking-update, analog
  macro-process, monitor, and future-event regions with the prescribed promotion
  and re-entry behavior.
- Preserve digital time precision and per-scope timescale conversion; avoid
  reducing digital timestamps to an inexact analog floating-point key.
- Schedule zero delays, delayed assignments, simultaneous events, cancellation,
  monitor/strobe output, simulation stop/finish and empty-queue termination.
- Test observable region traces, NBA and zero-delay interactions, repeated
  delta cycles, time rounding, far-future events and removal during dispatch.

### D06 — Continuous assignment and delay semantics

- Execute continuous assignments and reevaluate their dependencies.
- Implement net/assignment delays, rise/fall/turn-off delay choices, delay
  selection, pulse cancellation and inertial behavior where required.
- Test delayed pulses, input changes before delivery, multiple simultaneous
  assignments, strength changes and propagation across hierarchy.

### D07 — Elaboration of the inherited digital language

- Complete digital module instances, instance arrays, parameter and defparam
  binding, generate constructs and hierarchical names.
- Implement tasks/functions in hierarchy, scope rules and generated names.
- Audit library/configuration declarations and binding rules, top selection and
  mixed Verilog/AMS compilation units. Accept `.v` through a real execution path.
- Test multi-file designs, parameterized widths, recursive/invalid elaboration,
  generated hierarchies, configurations and name collisions.

### D08 — Gates, switches and UDPs

- Implement built-in logic/buffer/tri-state/MOS/CMOS/pass-switch families,
  primitives' delays and strengths, bidirectional switch networks and charge.
- Implement combinational and sequential UDP declarations and table execution,
  edge descriptors, state initialization and invalid-table diagnostics.
- Test each primitive's truth tables, X/Z transitions, opposing drivers,
  bidirectional networks, strength reduction and sequential UDP history.

### D09 — Timing constructs and digital system facilities

- Implement specify blocks, path delays, timing checks, specparams and notifier
  effects, including timing annotation facilities required by the target.
- Implement digital system tasks/functions not available through the analog
  backend: time queries/formatting, memory load/dump, value/strength formatting,
  simulation control and the remaining inherited standard facilities.
- Audit the complete inherited system-task list rather than inferring it from
  today's analog allowlist. Test actual outputs, file effects and timing events.

The inherited facility inventory below comes from IEEE 1364-2005 §§17–18,
checked against AMS §9's context tables. Every row remains open. Existing analog
implementations are reusable components, not evidence of digital execution.
The standalone digital runner currently dispatches only `$display`, `$finish`,
`$signed` and `$unsigned`, within its documented limits.

| Inherited clause | Digital implementation and behavioral evidence still needed |
|---|---|
| 17.1 — output | Complete display/write radix families and formatting; strobe/monitor scheduling, argument sampling, activation and suppression. |
| 17.2.1–17.2.8 — files/strings | Descriptor and multichannel handling; file display/write/strobe/monitor variants; string formatting/scanning; character, line and binary input; seek/tell/rewind, flush, EOF and errors. |
| 17.2.9 — memory loading | `$readmemb`/`$readmemh`: comments, addresses, ranges, direction, X/Z and malformed or excess data. Requires memories from D03. |
| 17.2.10 — annotation | `$sdf_annotate`: annotation targets, delays, timing checks and applicable SDF/version rules; coordinate with D07/D09. |
| 17.3 and 17.7 — time | `$printtimescale`, `$timeformat`, `$time`, `$stime`, `$realtime`: scope, rounding, return width and formatted output. Queue ticks alone do not implement these calls. |
| 17.4 — control | Complete `$finish` options and `$stop` host behavior; prove scheduler and resource cleanup. |
| 17.5 — PLA | All sixteen combinations of `$async`/`$sync`, `$and`/`$nand`/`$or`/`$nor`, and `$array`/`$plane`; personality data, four-state logic and update timing. |
| 17.6 — stochastic queues | `$q_initialize`, `$q_add`, `$q_remove`, `$q_full`, `$q_exam`: queue discipline, status codes, capacity and time statistics. |
| 17.8 — conversions | Digital real/integer and bit-pattern conversions, argument/result typing, X/Z and overflow handling; casts alone do not close this row. |
| 17.9 — distributions | Digital `$random` and `$dist_*`: typed inout seeds, exact reference sequence, default streams and call-order behavior. Analog kernel tests remain separate. |
| 17.10–17.11 — inputs/math | Both plusarg functions; `$clog2` and real math functions with digital typing, argument conversion, domain behavior and actual host inputs. |
| 18.1–18.2 — VCD | `$dumpfile`, `$dumpvars`, `$dumpoff`, `$dumpon`, `$dumpall`, `$dumplimit`, `$dumpflush`; scopes, identifiers, four-state values, timestamps and scheduling. |
| 18.3–18.4 — extended VCD | `$dumpports`, `$dumpportsoff`, `$dumpportson`, `$dumpportsall`, `$dumpportslimit`, `$dumpportsflush`; port direction, strengths and extended file encoding. |

IEEE 1364 Annex C is informative. Its additional utilities must be classified
separately; their presence in other simulators does not by itself make them
mandatory. AMS additions to digital system facilities still need their own
audit. This inventory does not close the broader inherited clause audit.

### D10 — Compiler directive semantics

Known gap: `default_nettype`, `celldefine`, `endcelldefine`,
`unconnected_drive` and `nounconnected_drive` are accepted-and-ignored entries.

- Carry directive state to the declarations/elaboration it affects.
- Validate timescale syntax and precision, reset behavior, file-boundary scope,
  keyword-set transitions, predefined macros and required pragma handling.
- Test implicit-net rejection, pull behavior of unconnected inputs, cell metadata,
  directive restoration and interaction with mixed-language files.

## Analog operators and simulator behavior

### A01 — Analog expressions, functions and numeric conversions

- Audit every operator/function signature, argument domain, constant-folding rule
  and derivative against the standard, including exceptional values.
- Finish dynamic multidimensional reads/writes with independently changing
  subscripts, declared index directions, bounds, and parameterized dimensions.
- Complete invalid-index value semantics, partial-slice assignment, dynamic
  scalar output/inout writeback and independently overridden structural dimensions.
- Complete `$discontinuity` argument conversion: the existing negative-integer
  diagnostic does not establish real/string/nonfinite/range behavior.
- Test finite-difference derivatives where appropriate, branch-sensitive errors,
  conversion boundaries and computed indexes. Avoid approximate replacements.

### A02 — Branch equations and topology

- Complete implicit-flow equations and reactive branch-current/port-current
  probes; each introduced unknown needs a defining equation.
- Verify source/probe/switch branch classification, contribution replacement,
  conditional topology, multiple access names and cross-hierarchy connections.
- Implement `$analog_node_alias`/`$analog_port_alias` topology effects and legal
  scopes, including required reevaluation when parameters change.
- Test unconstrained circuit solves, KCL, measured capacitor/inductor currents,
  alias identity and invalid/hierarchical targets.

### A03 — Analog control flow and held state

- Implement the permitted event-controlled `disable` cases and correct named-block
  exit without accidentally exiting a caller's loop or block.
- Track held variables by scoped identity, including named-block locals,
  shadowing, arrays and function-local lifetime where permitted.
- Complete analog named-event propagation and digital-event-controlled analog
  blocks in cooperation with D05/M01.
- Test event order, events before/after lexical trigger positions, shadowed names,
  nested exits and unchanged values between events.

### A04 — Stateful analog operators

- Audit `ddt`, `idt`, `idtmod`, `ddx`, delay, transition, slew, last-crossing,
  Laplace and Z-transform variants for all defined arguments and analyses.
- Remove semantic failure from fixed history capacities; preserve samples needed
  by supported delay bounds under adaptive stepping and rejection/retry.
- Test initialization/reset, variable input parameters where allowed, poles/zeros,
  discontinuities, AC behavior, long histories and rollback.
- Record resource failures explicitly; silently forgetting history is not a
  valid implementation-defined limit.

### A05 — Table-model lookup

Existing linear and nearest-point modes do not close the whole operator.

- Capture mutable array data on the actual first invocation per instance/site;
  later source mutations must not change the table. Avoid eager capture in an
  unexecuted conditional branch. This is the current table agent's task.
- Implement quadratic/cubic spline modes with the specified boundary conditions;
  ignored columns, fatal extrapolation and all control-string combinations.
- Load file-backed tables at their first executed runtime call instead of assuming a
  compile-time read is equivalent; validate rows, duplicate coordinates,
  isolines, ordering, dimensional coverage and failure cases.
- Independently validate whether calls through one analog-function body share
  its syntactic table site and snapshot.
- Test mixed interpolation dimensions, asymmetric grids, endpoints, ties,
  derivatives, file errors, multiple instances and repeated/rejected evaluations.

### A06 — Small-signal and noise behavior

- Implement `noise_table` and `noise_table_log` through emitted source metadata
  and host spectral integration. Preserve existing source correlation support.
- Audit AC stimulus behavior, white/flicker/tabulated PSDs, source naming,
  correlation, analysis enablement and derivative transfer to the simulator.
- Test analytic circuits and independent spectrum values across interpolation
  intervals, limits, correlated sources and zero/off-analysis behavior.

### A07 — Random distributions

The 4096-degree/stage substitution is removed. Supported integral counts follow
the IEEE reference listing, with independent C value/seed checks. Runtime
validation remains observable when outputs are unused and is skipped on untaken
paths; thirty-four generated-device scenarios cover guards, loops, host overrides and error order
in Debug/ReleaseFast. See [remaining distribution limits](../../VerA/docs/RNG-REFERENCE-LIMITS.md).

- Implement legal fractional/out-of-range count semantics without substitution.
- Validate dynamic argument domains, seed mutation and per-instance/per-analysis
  stream lifetimes; audit global/instance variation modes.
- Preserve the required distribution beyond current caps without replacing it
  with a normal approximation. Test seeds, invalid domains, boundaries, moments
  and distribution properties using justified statistical acceptance bounds.

### A08 — Initialization and parameter-dependent execution

- Deliver analog net initialization/node-set requests to the host; the parser
  currently discards net initializer expressions.
- Verify declaration initialization, analog initial, initial/final step and
  analysis-specific execution across sweeps and repeated analyses.
- Test illegal domains, dependent parameters, new instances and separate analysis
  runs. Do not infer success from a single DC residual evaluation.

### A09 — Accepted/rejected state lifecycle

Direct Newton/JFNK limiter hooks exist; this item is not a rewrite of those hooks.

- Prove hook ordering in real transient integration, timestep rejection/retry,
  auxiliary transient drivers and supported periodic analyses.
- Ensure finite-difference probes do not advance state; accepted-time state and
  Newton-iteration state must follow their separate lifetimes.
- Test model side effects, random streams, deferred output and stateful operators
  across rejection and re-entry according to each operator's specified behavior.
- Keep unsupported GPU execution excluded until it obeys the same semantics.

### A10 — Analog event scheduling and host queries

- Honor dynamically changing timer start/period/enable controls, crossing
  tolerances, breakpoint requests and step bounds in host scheduling.
- Implement required simulation/hierarchy queries with actual host values and
  correct dynamic-name, unknown-name and default behavior.
- Test off-grid events, disabled/re-enabled timers, canceled wakeups, rejected
  trial points, multiple analyses and hierarchical query paths.

## Hierarchy and mixed-signal integration

### H01 — Parameters, paramsets and elaborated identity

- Constant string overrides now honor `from`/`exclude` sets. Extend validation
  to the remaining final-value paths below.
- Validate final instance values, dependent ranges, arrays, host overrides and
  parameter sweeps without incorrectly rejecting an unused model default.
- Include unoverridden final defaults and string-aware paramset selection.
- Complete constant-function control flow, remaining host operators and string
  derivation, selected zero-divisor semantics, host override width changes and
  nonfinite/out-of-range real-to-integer conversion.
- Exact integral defaults and supported dependent expressions now preserve the
  bits of values such as `64'h4142434445464748` through Model initialization and
  derivation. Complete context width/signedness propagation remains open:
  known mixed-sign shift comparisons diagnose E0364, but compound expressions
  can still produce incorrect results.
- Preserve paramset output-variable and analog-function content, overload
  selection and observable instance behavior; the parser drops some content.
- Resolve escaped scalar names separately from generated vector-element names.
- Test valid/invalid overrides, exclusions overriding inclusion, aliases,
  defparams, string case/NUL semantics, nested hierarchy and collisions.

### H02 — Port and hierarchy completeness

- Audit ordered/named/concatenated/vector ports, range expressions depending on
  parameters, inherited connectivity rules and hierarchical access.
- Verify node tolerance resolution, nature inheritance, branch-vector indexing,
  primitive binding and names exposed to users and VPI.
- Test distinct instances, opposite index directions, nonliteral bounds and
  reconnecting the same logical signal through several hierarchy levels.

### H03 — Discipline resolution

- Complete basic/detail propagation algorithms, coercion of declared
  interconnects, defaults, incompatible connections and unresolved segments.
- Retain exact-match precedence and ambiguity reporting already implemented.
- Test cases where basic and detailed resolution differ, declared overrides,
  `resolveto`/`exclude`, and multiple disciplines sharing a node.

### H04 — SPICE interoperability

- Audit Annex E naming, binding, standard primitive interfaces, port disciplines,
  model-card parameters and netlist boundaries against the chosen documented
  SPICE integration. Some netlist model parameters are currently dropped.
- Test actual circuit behavior rather than only a parsed placeholder primitive.
- Separate implementation-defined SPICE behavior from mandated language behavior
  and the ngspice compatibility target in X01.

### M01 — Reading and triggering across domains

- Implement legal discrete values read by analog expressions, X/Z-sensitive
  case constructs, analog probes read by digital expressions and domain ownership.
- Implement digital edges/named events in analog blocks and analog events in
  digital processes, including `absdelta`.
- Test conversion tables, event timing, interpolation and illegal cross-domain
  assignments/function calls using an executing digital engine.

### M02 — Mixed-signal synchronization

- Iterate DC and time-zero digital activity to the required initial state.
- Coordinate analog candidate times, digital ticks, A2D quantization, D2A wakeups,
  zero-delay feedback, analog macro-process solves and trial rejection.
- Preserve event delivery exactly once where specified; speculative analog trials
  must not irreversibly advance digital state.
- Test comparator/DAC feedback, closely spaced crossings, half-tick boundaries,
  repeated delta cycles, event cancellation and rejected analog steps.

### M03 — Connectmodule insertion

- Select and insert bridges at the correct hierarchy boundaries; implement
  direction/discipline overrides and parameter passing.
- Implement default, merged and split modes, signal segmentation, supply-sensitive
  modules, generated instance/port names and defparams targeting generated bridges.
- Execute both analog and digital halves of each bridge.
- Test insertion counts, topology, overrides and numerical/logical behavior;
  parsing a `connectrules` declaration does not establish insertion support.

### M04 — Driver/receiver access and real nets

- Implement driver/receiver segregation and access from connectmodules, including
  updates that occur without a change to the resolved signal value.
- Complete `wreal` declaration, connectivity, assignment/event behavior and
  standard-defined special-value handling.
- Test multiple drivers, receiver groups, direction changes, driver-update events
  and real-valued digital-to-analog round trips.

## Standard I/O and programming interfaces

### S01 — Formatting, strings and files

- Add numeric `%s` with correct operand width, leading-zero and embedded-byte
  behavior through display/write/string/file variants; integer path is assigned.
- Audit every standard format conversion, signedness, width, precision, locale
  independence and strength/four-state formatting as digital values become usable.
- Remove file-scanning shortcuts that consume more input than required; test
  successive scans on one line, multiline fields, `$ftell`, EOF and failed matches.
- Audit all file/memory read/write/seek/descriptor tasks, scratch-buffer limits,
  per-instance isolation and errors. Test observable bytes and file positions.

### P01 — VPI object model and public C interface

- Provide the required C headers, constants, structs, startup registration and
  exported ABI; a custom value/partials callback is not a VPI implementation.
- Represent elaborated objects, stable handles, relationships, properties,
  iteration/scanning, lookup by name/index, comparison, release and errors.
- Test compiled C applications against nested digital/analog designs and real
  object lifetimes, including invalid handles and unsupported property requests.

### P02 — VPI values, scheduling and system tasks

- Implement get/put value and time formats, delays, force/release, delayed writes,
  callback registration/removal/info, simulation control, printing and MCD APIs.
- Register and invoke digital and analog system tasks/functions with the correct
  compile/call/size/derivative callbacks and argument handles.
- Test C plugins through executable simulation, region ordering, reentrant
  registration/removal and conversion round trips.
- Audit inherited PLI/VPI requirements explicitly; do not silently narrow the
  full language target to the current `SystfHost` bridge.

### P03 — Analog VPI and accepted-point callbacks

- Implement analog values, time/frequency/delta queries, derivative objects,
  analog callbacks and partial-derivative propagation through the host.
- Implement standard `acbAcceptedPoint` ordering/count/removal. There is no
  invented source-level `@(accepted_step)` substitute in this plan.
- Test C sample-and-hold and derivative plugins, accepted/rejected transient
  points, callbacks removed during dispatch and repeated analyses.

## Evidence and release gates

### Q01 — Complete requirement inventory

- Expand every mandatory AMS clause and inherited Verilog requirement into
  individually reviewable obligations, including syntax and semantic exceptions.
- Reconcile all chapter `COVERAGE.md` files, source limitation comments and tests.
  Remove stale analog-subset exemptions from full-target completion claims.
- Mark each obligation missing, partial, implemented-without-evidence, verified,
  optional, implementation-defined or non-normative, with a reason and reference.
- Keep native compatibility X01 separate. Do not use fixture count as a percent.

### Q02 — Independent behavioral oracles

- Add digital trace and mixed-signal circuit suites, C VPI programs, mathematical
  operator oracles, negative semantic tests and adversarial resource cases.
- Differential-test against independent conforming implementations where
  available, but resolve disagreements against the standard rather than copying
  one simulator's extensions or bugs.
- Audit every rejection fixture: distinguish illegal source from legal-but-
  unsupported source. Assert runtime output and exit status, not emitted text alone.

### Q03 — Host and backend qualification

- Test standalone, ARPice direct/JFNK, transient/AC/noise and other supported
  analysis paths with the same generated model requirements.
- Validate ABI/layout hashes, capabilities, lifecycle, multiple instances,
  concurrent evaluation and per-run ownership. Explicitly gate unsupported paths.
- GPU acceleration is an implementation choice, not a separate AMS language
  requirement; any advertised GPU path must preserve the supported semantics.

### Q04 — Final conformance review

- All mandatory requirement rows need executable evidence and independent review.
- All published support statements and implementation-defined choices must match
  the shipped compiler/host combination.
- The conformance gate must fail on missing evidence, skipped mandatory tests,
  unexpected rejection, abnormal termination and wrong results.
- A green analog suite, a complete parser, or a scheduler unit test alone cannot
  justify a full Verilog-AMS conformance claim.

## Separate required outcome: exact native-device migration

### X01 — LTRA, TXL and coupled transmission lines

The native source files remain under `models/native/`. The routing audit found
that O/Y/P paths selected approximate generated models. Native LTRA/TXL/CPL
registration and supported construction routes are restored through the neutral
CPU interface, with explicit rejection of unsupported setups. The
[migration audit](native-transmission-line-migration.md) records the algorithms,
standard facilities, numerical evidence and remaining differences. A replacement
may take over only after the comparisons below pass. The retained algorithms also have existing capacity,
setup-domain and non-transient limitations; their presence alone proves no
universal ngspice compatibility.

- Inventory each native model's equations, interpolation, convolution, initial
  conditions, accepted-history updates, step limiting and error-control behavior.
- Identify which pieces can be expressed with standard AMS constructs and which
  need standard simulator/VPI support. Do not invent a language builtin merely
  to copy an ngspice internal algorithm.
- Rewrite the devices and register them through the same path as other generated
  devices, retaining native implementations as comparison oracles during migration.
- Compare DC, AC and transient results, lossy/lossless limits, coupled ports,
  mismatched loads, discontinuities, long runs and rejected-step retries with
  justified tolerances. Preserve the numerical behavior requested by the user.
- Replace the native registrations only after those comparisons pass. The current
  approximate `.va` versions and generic rational filters do not meet this gate.
