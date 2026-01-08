# Chapter 5 — analog behavior

Source: docs/ch5-analog.html. Every valid .va is paired with an exact .expected.zig dump; diagnostic cases use .expected-error.txt.

Parser-boundary disclosure: `analog_initial_digital_access_rejected.va` stops at the
unsupported digital `initial` item before FastVAF can check the analog-initial read.
`vector_access.va` and `analog_genvar_loop.va` stop at vector declarations before
selection/elaboration semantics. `hierarchical_contribution_unsupported.va` contains
the hierarchical contribution, but its asserted diagnostic is the later unsupported
module instance. These fixtures preserve the required source syntax; they do not claim
that FastVAF validates those masked semantic rules.

| LRM section | Rule exercised | Fixtures / disposition |
|---|---|---|
| `s5.2` | HTML anchor for 5.2 analog procedural blocks | `analog_block.va`, `multiple_analog_blocks.va` |
| `s5-2-1` | HTML anchor for 5.2.1 analog initial | `analog_initial.va`, `analog_initial_contribution.va` |
| `s5-4-3` | HTML anchor for 5.4.3 port-flow access | `port_flow_probe.va`, `port_potential_invalid.va` |
| 5.1–5.2 | analog procedural block; sequential execution; multiple blocks | `analog_block.va`, `multiple_analog_blocks.va` |
| 5.2.1 | analog initial initialization and each restriction | `analog_initial.va`; `analog_initial_contribution.va`, `analog_initial_access_rejected.va`, `analog_initial_operator_rejected.va`, and `analog_initial_event_rejected.va` snapshot missing semantic diagnostics; `analog_initial_digital_access_rejected.va` records the digital-syntax rejection |
| 5.3.1–5.3.2 | sequential/named blocks and local data | `sequential_block.va`, `named_block_locals.va` |
| 5.4.1 | one/two-node, named-branch, and port-flow access | `access_one_node.va`, `access_two_nodes.va`, `named_branch_probe.va`, `port_flow_probe.va` |
| 5.4.2.1–5.4.2.2 | potential/flow probes and sources | `potential_probe.va`, `flow_probe.va`, `potential_source.va`, `flow_source.va` |
| 5.4.3 | legal port flow and illegal port potential access | `port_flow_probe.va`; `port_potential_invalid.va` snapshots the current acceptance gap |
| 5.4.4 | unassigned alternate arm becomes zero flow | `unassigned_switch_arm.va` |
| 5.5.1 | discipline and generic potential/flow access | `generic_access.va` |
| 5.5.2 | vector scalar selection and genvar index | `vector_access.va`, `analog_genvar_loop.va`; both are masked by the earlier unsupported vector declaration |
| 5.5.3 | nature attributes | `nature_attribute_unsupported.va` records the unimplemented net-dot-nature syntax |
| 5.5.4–5.5.5 | hierarchical nets/branches | `hierarchical_access_unsupported.va` |
| 5.6.1–5.6.1.3 | direct contribution, evaluation and retention | `direct_flow.va`, `direct_potential.va`, `retained_conditional_contribution.va` |
| 5.6.2.1 | four controlled source equations | `controlled_sources.va` plus atomic `controlled_voltage_source.va`, `voltage_controlled_current.va`, `current_controlled_voltage.va`, `current_controlled_current.va` |
| 5.6.3–5.6.4 | resistor, conductor and RLC | `resistor.va`, `conductor.va`, `rlc.va` |
| 5.6.5–5.6.6 | switch branches and implicit zero contribution | `switch_branch.va`, `implicit_zero_contribution.va` |
| 5.6.7–5.6.7.2 | indirect constraints and interaction | `indirect_contribution.va`, `multiple_indirect.va` |
| 5.6.8 | hierarchical contribution | `hierarchical_contribution_unsupported.va`; source inventory only, with the asserted failure at module instantiation |
| 5.7 | real/integer procedural assignments | `procedural_assignments.va` |
| 5.8.1–5.8.4 | if/else, case, conditional rules | `if_else.va`, `case_statement.va`, `conditional_contribution.va`; well-formed `conditional_filter_invalid.va` snapshots the missing dynamic-filter diagnostic |
| 5.9.1–5.9.2 | repeat, while and runtime for | `repeat_loop.va`, `while_loop.va`, `for_loop.va` |
| 5.9.3 | analog genvar-for elaboration | `analog_genvar_loop.va` |
| 5.10–5.10.1 | event control and event OR | `event_cross.va`, `event_or.va` |
| 5.10.2 | initial/final global events and optional analysis lists | `initial_step.va`, `final_step.va`, `initial_final_analysis_lists.va` |
| 5.10.3.1–5.10.3.3 | cross, above and timer, including tolerance and enable arguments | `event_cross.va`, `event_above.va`, `event_timer.va`, `event_cross_enable.va`, `event_above_enable.va`, `event_timer_enable.va` |
| 5.10.3.4 | absdelta is digital-context-only | `absdelta_digital_only.va` |
| 5.10.4–5.10.5 | named/digital events | `named_event_unsupported.va` snapshots the current acceptance gap |
| 5.11 | break/continue jump statement context rules | `jump_statement_unsupported.va`, `jump_continue_unsupported.va` snapshot current acceptance without the normative jump semantics |

## Printed-section inventory

Additional atomic rule snapshots: `analog_initial_integer.va`, `analog_initial_real.va`,
`nested_sequential_blocks.va`, `single_terminal_branch.va`, `two_named_branches.va`,
`constant_current_source.va`, `controlled_voltage_source.va`, `source_probe_both.va`,
`conditional_no_else.va`, `case_default_only.va`, `repeat_single.va`, `while_false.va`,
`for_zero_iterations.va`, `event_cross_falling.va`, `event_cross_any.va`,
`event_timer_one_shot.va`, `event_above_tolerance.va`, `event_initial_or_cross.va`,
`indirect_and_direct.va`, and `derivative_contribution.va`.


The chapter is a layout-preserving extraction with only three HTML anchors, so
the printed headings are inventoried separately: 5.1; 5.2; 5.2.1; 5.3; 5.3.1;
5.3.2; 5.4; 5.4.1; 5.4.2; 5.4.2.1; 5.4.2.2; 5.4.3; 5.4.4; 5.5; 5.5.1;
5.5.2; 5.5.3; 5.5.4; 5.5.5; 5.6; 5.6.1; 5.6.1.1; 5.6.1.2; 5.6.1.3;
5.6.2; 5.6.2.1; 5.6.3; 5.6.4; 5.6.5; 5.6.6; 5.6.7; 5.6.7.1; 5.6.7.2;
5.6.8; 5.6.8.1; 5.6.8.2; 5.7; 5.8; 5.8.1; 5.8.2; 5.8.3; 5.8.4; 5.9;
5.9.1; 5.9.2; 5.9.3; 5.10; 5.10.1; 5.10.2; 5.10.3; 5.10.3.1;
5.10.3.2; 5.10.3.3; 5.10.3.4; 5.10.4; 5.10.5; and 5.11.
