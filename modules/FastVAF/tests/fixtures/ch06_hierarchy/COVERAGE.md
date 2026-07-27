# Chapter 6 — hierarchical structures

Source: docs/ch6-hierarchy.html. Every HTML section id is listed literally below.

Boundary disclosure: FastVAF currently lowers `$mfactor` to the constant `1.0` and
emits no instance multiplicity field or automatic flow/probe/noise scaling. The five
`mfactor_*` sources therefore snapshot the currently *unscaled* affected constructs;
propagation stops at unsupported hierarchy. `instance_array_unsupported.va` stops at
its vector declaration before array elaboration. Dotted `$root`, OOMR, and genblk
sources are present, but their diagnostics are parser-token boundaries rather than
hierarchical semantic checks.

| HTML id / section | Rule exercised | Fixtures / disposition |
|---|---|---|
| `s6.1` | overview of structural hierarchy | `module_definition.va`; actual hierarchy is rejected by `module_instantiation_unsupported.va` |
| `s6.2` | module declaration, module items, multiple analog blocks | `module_definition.va`, `ansi_ports.va`, `multiple_analog_blocks.va` |
| `s6.2.1` | top-level modules and $root | `top_level_module.va`, `root_reference_unsupported.va` |
| `s6.2.2` | module instantiation, instance arrays, multiple instances, parameter-port lists, and blank/omitted connections | `module_instantiation_unsupported.va`, `multiple_instances_unsupported.va`, `parameter_port_list.va`, `blank_ordered_connection_unsupported.va`, `empty_named_connection_unsupported.va`, `omitted_named_connection_unsupported.va`; `instance_array_unsupported.va` is source inventory masked by vector-declaration parsing |
| `s6.3` | three parameter override mechanisms | `parameter_default.va` plus diagnostics below |
| `s6.3.1` | defparam statement and scope restrictions | `defparam_unsupported.va` |
| `s6.3.2` | ordered parameter assignment | `parameterized_instantiation_unsupported.va` |
| `s6.3.3` | named parameter assignment | `named_parameter_instantiation_unsupported.va` |
| `s6.3.4` | dependent parameter expressions | `dependent_parameters.va` |
| `s6.3.5` | $param_given | `param_given.va` |
| `s6.3.6` | $mfactor syntax, all five affected construct classes, and geometric system parameters | `mfactor.va` exposes constant-1 lowering; `mfactor_flow_contribution.va`, `mfactor_flow_probe.va`, `mfactor_flow_noise.va`, and `mfactor_potential_noise.va` snapshot absence of automatic scaling; `mfactor_propagation_unsupported.va` stops at hierarchy; `geometric_system_parameters.va` |
| `s6.4` | paramsets | `paramset_unsupported.va` |
| `s6.4.1` | paramset statements | `paramset_unsupported.va` |
| `s6.4.2` | overload selection/tie breaking | `paramset_overload_unsupported.va` |
| `s6.4.3` | output variables | `paramset_output_unsupported.va` |
| `s6.5` | ports | `ansi_ports.va`, `nonansi_ports.va` |
| `s6.5.1` | port definition | `ansi_ports.va` |
| `s6.5.2` | port declarations | `nonansi_ports.va` |
| `s6.5.2.1` | port type/discipline | `typed_ports.va` |
| `s6.5.2.2` | input/output/inout directions | `port_directions.va` |
| `s6.5.3` | real-valued ports | `real_port_unsupported.va` |
| `s6.5.4` | ordered port connection | `module_instantiation_unsupported.va` |
| `s6.5.5` | named port connection | `named_port_instantiation_unsupported.va` |
| `s6.5.6` | $port_connected | `port_connected.va` |
| `s6.5.7` | connection rules | needs hierarchy; `module_instantiation_unsupported.va` |
| `s6.5.7.1` | matching size | `vector_ports.va`; cross-instance checking needs hierarchy |
| `s6.5.7.2` | undeclared interconnect discipline resolution | Annex F fixtures; not single-module codegen |
| `s6.5.8` | inheriting port natures | `typed_ports.va`; inheritance is elaboration behavior |
| `s6.6` | generate constructs/regions | `generate_region.va` |
| `s6.6.1` | loop-generate/genvar/implicit-localparam semantics and assignment restrictions | `generate_loop.va`, `generate_implicit_localparam.va`, `generate_mismatched_genvar_rejected.va` |
| `s6.6.2` | conditional if/case generate, constant conditions, and direct nesting | `generate_if.va`, `generate_case_unsupported.va`, `generate_nonconstant_rejected.va`, `generate_direct_nesting.va` |
| `s6.6.2.1` | dynamic sweep parameters | analysis/elaboration host behavior; no device dump rule |
| `s6.6.3` | external genblk names | `external_genblk_reference_unsupported.va` |
| `s6.7` | hierarchical names | `root_reference_unsupported.va`, `oomr_branch_probe_unsupported.va` |
| `s6.7.1` | legal/illegal OOMR probes, parameters, functions, variables and assignments | `oomr_branch_probe_unsupported.va`, `oomr_parameter_unsupported.va`, `oomr_function_unsupported.va`, `oomr_variable_read_rejected.va`, `oomr_variable_assign_rejected.va` |
| `s6.8` | scope lookup and uniqueness | `local_scope_shadow.va` |
| `s6.9` | elaboration | compile-host concern, represented by generation fixtures |
| `s6.9.1` | analog block concatenation | `multiple_analog_blocks.va` |
| `s6.9.2` | elaboration/paramsets | `paramset_unsupported.va` |
| `s6.9.3` | elaboration/connectmodules | Chapter 7 diagnostics |
| `s6.9.4` | elaboration order | `generate_loop.va`; full hierarchy order outside FastVAF device codegen |
| generate-region restrictions | non-nesting and directly-in-module restrictions | `generate_nested_region_rejected.va`, `generate_region.va` |
| atomic expansion | individual direction, dependency, generation and geometry rules | `input_port.va`, `output_port.va`, `inout_port.va`, `localparam_dependency.va`, `three_dependent_parameters.va`, `generate_loop_descending.va`, `generate_if_true.va`, `generate_if_false.va`, `generate_two_loops.va`, `geometric_system_parameters.va` |
