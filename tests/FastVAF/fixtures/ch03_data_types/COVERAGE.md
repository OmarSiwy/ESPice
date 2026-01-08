# Chapter 3 coverage

Source: `docs/ch3-datatypes.html`, read in full through Section 3.13.4.

HTML section-ID audit: `s3-1` `s3-2` `s3-2-1` `s3-3` `s3-4` `s3-4-1` `s3-4-2` `s3-4-3` `s3-4-4` `s3-4-5` `s3-4-6` `s3-4-7` `s3-4-8` `s3-5` `s3-6` `s3-6-1` `s3-6-1-1` `s3-6-1-2` `s3-6-1-3` `s3-6-2` `s3-6-2-1` `s3-6-2-2` `s3-6-2-3` `s3-6-2-4` `s3-6-2-5` `s3-6-2-6` `s3-6-2-7` `s3-6-3` `s3-6-3-1` `s3-6-3-2` `s3-6-4` `s3-6-5` `s3-7` `s3-8` `s3-9` `s3-10` `s3-11` `s3-11-1` `s3-12` `s3-12-1` `s3-13` `s3-13-1` `s3-13-2` `s3-13-3` `s3-13-4`.

| LRM section/rule | Fixture or disposition |
|---|---|
| 3.1 integer, genvar, real, realtime, time, parameter, string, net-discipline types | `01_integer_real_variables.va`, `03_string_variables.va`, `04_parameter_types.va`, `09_genvar.va`, `10_nature_declarations.va`, `11_discipline_declarations.va`, `29_time_realtime_parameters.va` |
| 3.2 integer/real declarations, initialization, arrays, multidimensional arrays | `01_integer_real_variables.va`, `02_variable_arrays.va`; FastVAF scalarizes one-dimensional arrays and does not yet parse multidimensional dimensions |
| 3.2.1 module-scope output-variable attributes | Chapter 2 `11_attributes.va`; reporting/plot exposure is runtime simulator behavior |
| 3.3 string declaration/default/assignment, arrays, NUL removal, operators | `03_string_variables.va`, `17_string_parameter_range.va`, and the atomic string suite `23_string_arrays.va` through `28_string_replication.va`; unsupported multidimensional/replication grammar is diagnostic-pinned |
| 3.4, 3.4.1 typed scalar parameters and coercion | `04_parameter_types.va` |
| 3.4.2 inclusive/exclusive endpoints, infinity, multiple ranges, excluded scalar | `05_parameter_ranges.va`; range metadata is parsed but runtime override validation remains a compiler gap |
| 3.4.2 string value sets | `17_string_parameter_range.va` records current parsing/codegen behavior |
| 3.4.3 units/description attributes | Chapter 2 `11_attributes.va`; dimensional analysis is expressly not required |
| 3.4.4 typed parameter arrays and exact-size initializer | `08_parameter_array.va` |
| 3.4.5 local parameters derive from overridable parameters | `06_local_parameter.va` |
| 3.4.6 string parameters | `03_string_variables.va`; the transistor example's numeric portion is covered by Chapter 4 function/operator fixtures |
| 3.4.7 parameter aliases | `07_parameter_alias.va`; hierarchical override conflict checks require module instantiation, which FastVAF explicitly rejects |
| 3.4.8 multidimensional parameters/assignment patterns | one-dimensional executable subset in `08_parameter_array.va`; `18_multidimensional_array_rejected.va` records the parser diagnostic |
| 3.5 genvar static loop | `09_genvar.va` |
| 3.6–3.6.1 base/derived natures, predefined and user attributes | `10_nature_declarations.va`, `35_base_nature_required_attributes.va`, `36_derived_nature_inheritance.va`, `37_derived_units_immutable.va`, `38_derived_access_immutable.va`; accepted invalid cases explicitly pin missing semantic validation |
| 3.6.2 conservative and potential-/flow-only disciplines; continuous domain | `11_discipline_declarations.va`; discipline declarations are parsed, while custom-discipline equation typing/resolution is not yet lowered |
| 3.6.2.2 discrete domain | Annex C makes `discrete` an error in Verilog-A; FastVAF currently lacks that semantic diagnostic |
| 3.6.2.3 natureless/domainless disciplines | direct declarations in `30_natureless_discipline.va` and `31_domainless_discipline.va`; connectivity resolution remains a hierarchy concern |
| 3.6.2.4 undeclared/discrete nets | `34_implicit_nets.va` directly preserves the implicit structural-net form and pins hierarchy rejection |
| 3.6.2.5 discipline nature-attribute override | `19_discipline_override.va` records the accepted declaration and current lack of downstream effect |
| 3.6.2.6 nature derived from `discipline.potential/flow` | `20_derived_nature_from_discipline_rejected.va` records the dotted-parent grammar gap |
| 3.6.2.7 user discipline attributes | declaration parsing covered by `11_discipline_declarations.va`; no downstream effect yet |
| 3.6.3 scalar and vector disciplined nets | `12_scalar_nets.va`, `32_vector_nets.va`; vector ranges are diagnostic-pinned rather than disposition-only |
| 3.6.3.1 net description | Chapter 2 `11_attributes.va` |
| 3.6.3.2 net nodeset initializer | `21_net_nodeset_rejected.va`; runtime initial guess is outside generated contract |
| 3.6.4 continuous ground declaration | `13_ground_declaration.va` |
| 3.6.5 implicit structural nets | `34_implicit_nets.va` records the normative undeclared connection and intentional hierarchy rejection |
| 3.7 `wreal` | explicitly excluded by Annex C's Verilog-A subset; no pure-Verilog-A fixture |
| 3.8 default discipline | explicitly excluded by Annex C; compiler-directive handling is covered in Chapter 10 |
| 3.9–3.11 primitive discipline, precedence, resolution, compatibility | topology/elaboration semantics requiring hierarchy and mixed domains; not expressible in a single generated device Zig dump |
| 3.12 scalar/vector named branches with one and two terminals | `14_named_branches.va`, `33_vector_branches.va`; port-branch grammar rejection is `22_port_branch_rejected.va` |
| 3.13 namespace separation and access lookup | `39_nature_discipline_namespace_collision.va` through `42_wrong_access_function.va` directly test collision, shadow, duplicate-access, and wrong-access cases; accepted invalid forms pin validation gaps |
| Paramset grammar encountered in Annex A/Chapter 6 | `16_paramset_rejected.va` verifies the intentional loud rejection |

Additional atomic rule fixtures: `15_dynamic_array_index.va` exercises runtime indexing over a scalarized real array; `17_string_parameter_range.va`, `18_multidimensional_array_rejected.va`, `19_discipline_override.va`, `20_derived_nature_from_discipline_rejected.va`, `21_net_nodeset_rejected.va`, and `22_port_branch_rejected.va` keep each later gap independently executable.

## Data-type and namespace completion

- Strings: `23_string_arrays.va`, `24_multidimensional_strings.va`, `25_string_nul_removal.va`, `26_string_comparisons.va`, `27_string_concatenation.va`, and `28_string_replication.va` cover scalar/array/multidimensional storage, literal NUL removal, all six relational/equality operators, concatenation, and replication. Unsupported multidimensional and replication syntax is diagnostic-pinned.
- Time types: `29_time_realtime_parameters.va` covers `time` and `realtime` parameters and variables and records the current module-item rejection.
- Discipline edge forms: `30_natureless_discipline.va` and `31_domainless_discipline.va` cover natureless continuous and fully domainless declarations.
- Structural nets/branches: `32_vector_nets.va`, `33_vector_branches.va`, and `34_implicit_nets.va` preserve the normative source forms and current vector/hierarchy boundaries.
- Nature validation: `35_base_nature_required_attributes.va`, `36_derived_nature_inheritance.va`, `37_derived_units_immutable.va`, and `38_derived_access_immutable.va` cover required base attributes, inherited derived attributes, and the immutable `units`/`access` rules. Accepted invalid cases deliberately snapshot missing semantic validation.
- Namespace/access validation: `39_nature_discipline_namespace_collision.va`, `40_access_name_shadow.va`, `41_duplicate_access_name.va`, and `42_wrong_access_function.va` cover global namespace collision, local shadowing, duplicate base-nature access names, and using an access name not supplied by a net's discipline; accepted cases are explicit implementation-gap snapshots.
