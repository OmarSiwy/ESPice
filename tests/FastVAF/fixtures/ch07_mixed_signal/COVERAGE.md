# Chapter 7 — mixed signal

Source: docs/ch7-mixed-signal.html. Every HTML section id is inventoried literally. FastVAF's Verilog-A backend intentionally has no digital scheduler or hierarchy elaborator, so those normative rules are represented by focused diagnostics or marked host-only.

Parser-boundary disclosure: `discrete_real_from_analog_unsupported.va` stops at its
digital `initial` item, and all three bus-width fixtures stop at vector declarations;
the ownership/extension/31-bit rules are therefore source inventories, not semantic
checks. Digital-process bodies (including continuous assignment and the analog-function
call) are masked by unsupported digital module items. Connectrule/connectmodule files
parse their source forms but ultimately assert `NoModule`; primitive generated-port
access stops at the primitive instance before the following `defparam`.

| HTML id | Rule exercised | Fixtures / disposition |
|---|---|---|
| `s7-1` | mixed-signal overview/connect rules | `connectmodule_unsupported.va`, `connectrules_unsupported.va` |
| `s7-2` | continuous/discrete fundamentals | `continuous_context.va`, `digital_always_unsupported.va` |
| `s7-2-1` | value domains | `continuous_context.va` |
| `s7-2-2` | assignment context determines domain | `continuous_context.va`, `digital_initial_unsupported.va` |
| `s7-2-3` | nets/nodes/ports/signals and hierarchy | `analog_port.va`; `hierarchy_unsupported.va` |
| `s7-2-4` | mixed-signal/net discipline and abstol | `custom_disciplines.va`; node tolerance aggregation is elaborator behavior |
| `s7-3` | cross-domain behavioral interaction | `analog_reads_integer.va` plus digital diagnostics |
| `s7-3-1` | discrete real/integer/scalar bit/bus values, zero extension, and >31-bit rejection | `analog_reads_integer.va`, `discrete_scalar_bit_unsupported.va`; `discrete_real_from_analog_unsupported.va` is masked by digital initialization, while `discrete_bus_narrow_unsupported.va`, `discrete_bus_31_unsupported.va`, and `discrete_bus_over31_rejected.va` are masked by vector declarations |
| `s7-3-2` | x/z case equality/inequality, case/casex/casez, and numeric literals | `case_equality.va`, `x_case_equality_unsupported.va`, `z_case_inequality_unsupported.va`, `xz_case_statement_unsupported.va`, `xz_casex_statement_unsupported.va`, `xz_casez_statement_unsupported.va`, `x_literal_unsupported.va`, `z_literal_unsupported.va` |
| `s7-3-2-1` | infinity/NaN cannot be contributed | `inf_contribution.va` records the syntax; runtime finite-value enforcement is host behavior |
| `s7-3-3` | continuous values read in discrete context | `digital_probe_unsupported.va` |
| `s7-3-4` | discrete events in continuous context | `digital_event_unsupported.va` |
| `s7-3-5` | continuous events in discrete context | `digital_cross_unsupported.va` |
| `s7-3-6` | concurrency/synchronization | `analog_event.va`; cross-engine ordering is Clause 8 host behavior |
| `s7-3-6-1` | analog event in digital event control | `digital_cross_unsupported.va` |
| `s7-3-6-2` | digital event in analog event control | `digital_event_unsupported.va` |
| `s7-3-6-3` | analog primary in digital expression | `digital_probe_unsupported.va` |
| `s7-3-6-4` | analog-event-owned variable in a continuous assign | `continuous_assign_unsupported.va`; source inventory masked before continuous-assignment scheduling semantics |
| `s7-3-6-5` | digital primary in analog expression | `analog_reads_integer.va` |
| `s7-3-7` | both prohibited cross-domain function-call directions | `digital_function_from_analog_unsupported.va`, `analog_function_from_digital_unsupported.va`, `cross_domain_function_unsupported.va` |
| `s7-4` | discipline resolution | `custom_disciplines.va` and Annex F fixtures |
| `s7-4-1` | compatible discipline resolution | `compatible_disciplines.va` |
| `s7-4-2` | discrete discipline connection | `discrete_discipline.va`; connection is elaborator behavior |
| `s7-4-3` | continuous discipline connection | `compatible_disciplines.va` |
| `s7-4-4` | resolution of mixed signals | `hierarchy_unsupported.va`; Annex F algorithms |
| `s7-4-4-1` | basic resolution algorithm | Annex F `default_algorithm_unsupported.va` |
| `s7-4-4-2` | detailed resolution algorithm | Annex F hierarchy fixtures |
| `s7-4-4-3` | coercing discipline resolution | `connectrules_unsupported.va` |
| `s7-4-5` | continuous signal resolution | `compatible_disciplines.va` |
| `s7-5` | connect modules | `connectmodule_unsupported.va` |
| `s7-6` | connectmodule declaration restrictions | `connectmodule_unsupported.va` |
| `s7-7` | connect specification statements | `connectrules_unsupported.va` |
| `s7-7-1` | auto-insertion connect statement | `connectrules_unsupported.va` |
| `s7-7-2` | discipline resolution connect...resolveto statement | `resolution_connect_unsupported.va` |
| `s7-7-2-1` | connect-rule selection | `resolution_connect_unsupported.va` |
| `s7-7-3` | parameter passing attribute | `connect_parameter_unsupported.va` |
| `s7-7-4` | connect_mode | `connect_mode_unsupported.va` |
| `s7-8` | automatic insertion | `hierarchy_unsupported.va`; post-elaboration host function |
| `s7-8-1` | connect module selection | `connectrules_unsupported.va` |
| `s7-8-2` | signal segmentation | `hierarchy_unsupported.va` |
| `s7-8-3` | connect_mode parameter | `connect_mode_unsupported.va` |
| `s7-8-3-1` | merged insertion | `connect_mode_unsupported.va` |
| `s7-8-3-2` | split insertion | `connect_mode_unsupported.va` |
| `s7-8-4` | segregation/selection/insertion rules | `hierarchy_unsupported.va` |
| `s7-8-5` | merged/split generated instance names and defparam access | `connect_generated_defparam_unsupported.va`, `connect_generated_split_name_unsupported.va` |
| `s7-8-5-1` | built-in primitive port naming | `primitive_generated_ports_unsupported.va`; the primitive-instantiation error precedes the generated-port `defparam` check |
| `s7-8-6` | supply-sensitive connect modules and hierarchical supply access | `connect_supply_unsupported.va`, `supply_hierarchical_connectmodule_unsupported.va` |
| `s7-9` | driver-receiver segregation | digital scheduler/elaborator rule; `hierarchy_unsupported.va` |
