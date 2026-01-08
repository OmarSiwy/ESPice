# Annex A coverage

Source: `docs/annex-a-syntax.html`, read as the normative grammar. Fixtures target the productions that can occur in an analog-only, contract-shaped device; the rest are explicitly classified below.

HTML section-ID audit: `a-1` `a-1-1` `a-1-2` `a-1-3` `a-1-4` `a-1-5` `a-1-6` `a-1-7` `a-1-8` `a-1-9` `a-2` `a-2-1` `a-2-1-1` `a-2-1-2` `a-2-1-3` `a-2-2` `a-2-2-1` `a-2-2-2` `a-2-2-3` `a-2-3` `a-2-4` `a-2-5` `a-2-6` `a-2-7` `a-2-8` `a-3` `a-3-1` `a-3-2` `a-3-3` `a-3-4` `a-4` `a-4-1` `a-4-2` `a-5` `a-5-1` `a-5-2` `a-5-3` `a-5-4` `a-6` `a-6-1` `a-6-2` `a-6-3` `a-6-4` `a-6-5` `a-6-6` `a-6-7` `a-6-8` `a-6-9` `a-6-10` `a-7` `a-7-1` `a-7-2` `a-7-3` `a-7-4` `a-7-5` `a-7-5-1` `a-7-5-2` `a-7-5-3` `a-8` `a-8-1` `a-8-2` `a-8-3` `a-8-4` `a-8-5` `a-8-6` `a-8-7` `a-8-8` `a-8-9` `a-9` `a-9-1` `a-9-2` `a-9-3` `a-9-4` `a-10`.

| BNF area | Fixture or disposition |
|---|---|
| A.1 source text, nature, discipline, modules | `01_source_text.va` |
| A.1 module parameter/port lists and module items | `02_module_ports.va`, `03_declarations.va`, `13_parameter_port_list.va` |
| A.1 connectrules/config/library | mixed-signal compilation-unit constructs, outside Annex C's analog subset and FastVAF device codegen |
| A.1 paramset | `10_paramset_rejected.va` verifies deliberate loud rejection |
| A.2 parameters, ports, net/variable/branch declarations, lists, assignments, ranges | `03_declarations.va` |
| A.2 analog function and block declarations | `04_analog_function.va`, `05_behavioral_statements.va` |
| A.2 digital task, reg, event, time, strength, and delay productions | IEEE 1364/mixed-signal constructs outside a Verilog-A device dump |
| A.3 primitive instances | SPICE primitive compatibility belongs to Annex E; Verilog gate/switch primitives are digital |
| A.4 module instantiation | `11_module_instantiation_rejected.va`; hierarchy is rejected rather than flattened incorrectly |
| A.4 generate | `09_generate.va`, `14_if_generate.va`, `15_case_generate.va` |
| A.5 UDP declaration/instantiation | digital-only, excluded from Verilog-A |
| A.6 analog assignments, blocks, initial, conditional/case/loop/event/direct/indirect contribution statements | `05_behavioral_statements.va`, `06_event_control.va`, `16_analog_initial.va`, `21_indirect_contribution.va`, `22_null_attributed_statements.va` |
| A.6 event trigger/disable/jump/task enable boundaries | `17_named_event_trigger.va`, `18_disable_statement.va`, `19_jump_statements.va`, `20_task_enable.va`; continuous assign/digital procedural/fork remain digital-only |
| A.7 specify paths/timing checks | digital timing constructs, excluded from Verilog-A |
| A.8 arrays, calls, expressions, primaries, operators, numbers, strings, analog references | `07_expressions.va`, `23_expression_primaries.va`, `24_expression_composites.va` plus all of `ch02_lexical` and `ch04_expressions` |
| A.9 attributes/comments/identifiers/whitespace | `08_attributes_comments_identifiers.va` |
| A.10 semantic detail references | mapped to the chapter-specific coverage files; there is no standalone production |
| Parameter override via `defparam` | `12_defparam_rejected.va` verifies deliberate loud rejection |

## Production completion

- A.1/A.2 module-header parameters: `13_parameter_port_list.va`.
- A.1/A.6 generate alternatives: `14_if_generate.va` and `15_case_generate.va`.
- A.6 analog initialization: `16_analog_initial.va`.
- A.2/A.6 named event declarations/triggers, disable, jump, and task enable: `17_named_event_trigger.va`, `18_disable_statement.va`, `19_jump_statements.va`, and `20_task_enable.va`.
- A.6 indirect contribution and attributed/null statements: `21_indirect_contribution.va` and `22_null_attributed_statements.va`.
- A.8 primary/call/probe/index families and composite concatenation/replication/unary/binary/conditional families: `23_expression_primaries.va` and `24_expression_composites.va`.

These source-expressible grammar families are no longer disposition-only. Where FastVAF rejects a normative form, the precise current failure class is paired instead of claiming generated support.
