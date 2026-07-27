# Chapter 4 coverage

Source: `docs/ch4-expressions.html`, read in full through Section 4.7.3.

HTML section-ID audit: `s4-1` `s4-2` `s4-2-1` `s4-2-1-1` `s4-2-1-2` `s4-2-1-3` `s4-2-2` `s4-2-3` `s4-2-4` `s4-2-5` `s4-2-6` `s4-2-7` `s4-2-8` `s4-2-9` `s4-2-10` `s4-2-11` `s4-2-12` `s4-2-13` `s4-2-14` `s4-3` `s4-3-1` `s4-3-2` `s4-4` `s4-5` `s4-5-1` `s4-5-2` `s4-5-3` `s4-5-4` `s4-5-5` `s4-5-6` `s4-5-7` `s4-5-8` `s4-5-9` `s4-5-10` `s4-5-11` `s4-5-11-1` `s4-5-11-2` `s4-5-11-3` `s4-5-11-4` `s4-5-11-5` `s4-5-12` `s4-5-12-1` `s4-5-12-2` `s4-5-12-3` `s4-5-12-4` `s4-5-13` `s4-5-14` `s4-5-15` `s4-6` `s4-6-1` `s4-6-2` `s4-6-3` `s4-6-4` `s4-6-4-1` `s4-6-4-2` `s4-6-4-3` `s4-6-4-4` `s4-6-4-5` `s4-6-4-6` `s4-7` `s4-7-1` `s4-7-2` `s4-7-2-1` `s4-7-2-2` `s4-7-2-3` `s4-7-2-4` `s4-7-3`.

| LRM section/rule | Fixture or disposition |
|---|---|
| 4.1 expressions and constant expressions | every fixture; parameter constant lists in `09_assignment_pattern.va` |
| 4.2.1 real-legal operators and 4.2.1.1–.3 numeric conversion | `01_arithmetic_operators.va`, `02_numeric_conversions.va` |
| 4.2.2 precedence/associativity and parentheses | `03_precedence_associativity.va`, right-associated conditional in `08_conditional_operator.va` |
| 4.2.3 short-circuit operators | `04_relational_logical.va`; a structural Zig golden proves lowering shape, while suppression of runtime side effects requires numeric execution |
| 4.2.4 arithmetic/unary/modulus/power | `01_arithmetic_operators.va` |
| 4.2.5 relational | `04_relational_logical.va` |
| 4.2.6 case equality | `29_case_equality.va` records general Verilog-AMS parsing; Annex C identifies this as illegal in Verilog-A, a semantic validation gap |
| 4.2.7 logical equality and 4.2.8 logical operators | `04_relational_logical.va` |
| 4.2.9 bitwise operators and both xnor spellings | `05_bitwise_shift.va` |
| 4.2.10 reduction | `06_reduction_supported.va`; parity reductions are deliberately rejected by `07_reduction_xor_rejected.va` rather than silently miscompiled |
| 4.2.11 logical/arithmetic shifts | `05_bitwise_shift.va`; arithmetic shifts are forbidden in the analog subset but presently share lowering with logical shifts |
| 4.2.12 conditional/right association | `08_conditional_operator.va` |
| 4.2.13 concatenation/replication | `30_concatenation.va` snapshots current brace lowering; `31_replication_rejected.va` records the nested-replication grammar gap |
| 4.2.14 array assignment patterns | parameter initialization in `09_assignment_pattern.va`; post-declaration assignment in `32_array_assignment.va` |
| 4.3.1 traditional and `$` standard math styles | `10_standard_math_traditional.va`, `11_standard_math_system.va`; `33_ln1p_expm1.va` snapshots the generic-call behavior |
| 4.3.2 trigonometric, inverse, and hyperbolic functions | `12_transcendental_math.va` |
| 4.4 named branch, one-/two-net, port, generic, and validation rules | `13_signal_access.va`, `13b_generic_access_rejected.va`, `34_port_access.va`, `86_same_flow_terminals.va`, `87_wrong_discipline_access.va`; the last two pin missing same-signal/discipline-name checks |
| 4.5.1 array operator arguments | literal coefficient vectors in `23_laplace_filters.va`, `24_z_transform_filters.va`, `27_noise_sources.va`; parameter-array arguments in `35_filter_parameter_arrays.va` |
| 4.5.2 equation/tolerance role | structural output only; tolerances are simulator numerical policy |
| 4.5.3 `ddt` | `14_ddt.va` |
| 4.5.4 `idt` bare/IC and reset form | `15_idt.va`; explicit unsupported reset semantics in `16_idt_reset_rejected.va` |
| 4.5.5 `idtmod` | `17_idtmod.va` |
| 4.5.6 `ddx` | `18_ddx.va` |
| 4.5.7 `absdelay` | `19_absdelay.va` |
| 4.5.8 `transition` | `20_transition.va` |
| 4.5.9 `slew` | `21_slew.va` |
| 4.5.10 `last_crossing` | `22_last_crossing.va` |
| 4.5.11 and 4.5.11.1–.5 all four Laplace forms | `23_laplace_filters.va` |
| 4.5.12 and 4.5.12.1–.4 all four Z-transform forms | `24_z_transform_filters.va` |
| 4.5.13 limited exponential | `25_limexp.va` |
| 4.5.14 constant/dynamic argument classes | constant filter coefficients and dynamic signal first arguments in `19_absdelay.va`–`24_z_transform_filters.va` |
| 4.5.15 analog-operator placement restrictions | `36_operator_in_conditional.va` plus `88_operator_in_event.va` through `94_operator_null_argument.va` independently cover runtime conditional, event, repeat/while/for, function, initial, and null-argument rules |
| 4.6.1 `analysis()` multi-name query | `26_analysis.va` |
| 4.6.2 DC/static behavior | `26_analysis.va`; actual analysis-kind values are runtime inputs |
| 4.6.3 `ac_stim` | `37_ac_stim.va` snapshots current generic-call behavior |
| 4.6.4.1–.4 all four noise functions and optional names | `27_noise_sources.va` |
| 4.6.4.5 diode noise composition | diode nonlinearity in `25_limexp.va`, source kinds in `27_noise_sources.va` |
| 4.6.4.6 correlated noise by sharing a result | `38_correlated_noise.va` snapshots current sharing/dataflow behavior |
| 4.7.1 definition, typed inputs, conditional statement, body/formal restrictions | `28_user_function.va`; `95_function_access_ban.va` through `103_function_nonlocal_variable.va` isolate every listed body/formal restriction |
| 4.7.2.1 function-name return variable | `28_user_function.va` |
| 4.7.2.2 `return` statement | `40_function_return_rejected.va` snapshots current acceptance (the parser does not yet give `return` its normative early-exit semantics) |
| 4.7.2.3 output and 4.7.2.4 inout arguments | `39_function_output_inout.va`, `106_function_output_nonvariable.va`, `107_function_inout_nonvariable.va`, `108_function_array_output_pattern.va`, `109_function_array_inout_pattern.va` cover valid copy-out plus scalar/array actual restrictions and current gaps |
| 4.7.3 call context, recursion, and actual evaluation | `28_user_function.va`, `104_function_direct_recursion.va`, `105_function_indirect_recursion.va`, and `106_function_output_nonvariable.va` through `109_function_array_inout_pattern.va` |

Atomic operator fixtures (each produces an independent full Zig dump): `41_add.va`, `42_subtract.va`, `43_multiply.va`, `44_divide.va`, `45_modulo.va`, `46_power_operator.va`, `47_less_than.va`, `48_greater_than.va`, `49_less_equal.va`, `50_greater_equal.va`, `51_logical_equal.va`, `52_logical_unequal.va`, `53_logical_and.va`, `54_logical_or.va`, `55_logical_not.va`, `56_bitwise_and.va`, `57_bitwise_or.va`, `58_bitwise_xor.va`, `59_bitwise_xnor.va`, `60_shift_left.va`, `61_shift_right.va`, `62_bitwise_not.va`, `63_unary_plus.va`, and `64_unary_minus.va`. These individually dissect `s4-2-1` through `s4-2-12` rather than relying only on omnibus expressions.

Atomic mathematical-function fixtures: `65_sqrt.va`, `66_exp.va`, `67_ln.va`, `68_log10.va`, `69_floor.va`, `70_ceil.va`, `71_sin.va`, `72_cos.va`, `73_tan.va`, `74_asin.va`, `75_acos.va`, `76_atan.va`, `77_sinh.va`, `78_cosh.va`, `79_tanh.va`, `80_hypot.va`, `81_atan2.va`, `82_min.va`, `83_max.va`, `84_abs.va`, and `85_pow.va`. Together they give `s4-3-1` and `s4-3-2` a one-function-per-dump regression surface.

## Access, operator, and function restriction completion

- Signal-access validation: `86_same_flow_terminals.va` exercises the forbidden same-signal two-terminal flow form; `87_wrong_discipline_access.va` uses `V` on a custom discipline whose access names are `CustomV`/`CustomI`. Both currently compile and therefore pin semantic-validation gaps.
- Stateful analog-operator placement: `88_operator_in_event.va`, `89_operator_in_repeat.va`, `90_operator_in_while.va`, `91_operator_in_runtime_for.va`, `92_operator_in_function.va`, `93_operator_in_initial.va`, and `94_operator_null_argument.va` independently cover event, each runtime loop family, analog function, digital initial, and null-argument restrictions. Accepted forms pin missing restriction checks.
- Analog-function body/formal restrictions: `95_function_access_ban.va`, `96_function_filter_ban.va`, `97_function_contribution_ban.va`, `98_function_event_ban.va`, `99_function_named_block_ban.va`, `100_function_no_arguments.va`, `101_function_untyped_argument.va`, `102_function_undirected_argument.va`, and `103_function_nonlocal_variable.va` each isolate one normative ban or requirement.
- Call-graph/actual-argument rules: `104_function_direct_recursion.va` and `105_function_indirect_recursion.va` retain direct and mutual recursive definitions without executing them, pinning the missing static recursion check. `106_function_output_nonvariable.va` and `107_function_inout_nonvariable.va` pass branch probes rather than variables and pin the current acceptance gap. `108_function_array_output_pattern.va` and `109_function_array_inout_pattern.va` preserve the normative assignment-pattern actual forms and record the current array-formal parser boundary.
