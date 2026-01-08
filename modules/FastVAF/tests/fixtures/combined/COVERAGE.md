# Combined coverage

The documentation `index.html` is a navigation/index page and defines no
language rules of its own. These fixtures deliberately combine rules that
are tested atomically in the per-document folders.

| Fixture | Cross-chapter coverage |
|---|---|
| `01_resistor_with_directives.va` | Macro expansion, parameter range, SI literal, access functions, and contribution are substantive; `$bound_step` is currently erased to a zero placeholder. |
| `02_temperature_diode.va` | Parameters, `$temperature`, `$vt`, `limexp`, local variables, nonlinear contribution. |
| `03_piecewise_param_model.va` | Multiple parameters, conditional arithmetic, and contribution. `$param_given` is approximated by comparing against the default, which is wrong for an explicit override equal to that default. |
| `04_macro_function_math.va` | Formal macro arguments, analog user function, system-style `$min`/`$max`/`$exp`, return assignment, call lowering. |
| `05_loop_case_system_message.va` | Integer loop, case/default, `$abstime`, and the accumulated analog expression are substantive. `$strobe` and `$warning` calls are erased and no message behavior is tested. |
| `06_noise_and_analysis.va` | Standard include, physical macro, analysis selection, temperature, and resistor law are lowered. The expected Zig has an empty `noise_gens` array and a zero noise contribution, so it does not substantively cover `white_noise`. |
| `07_limit_and_discontinuity.va` | `$vt`, `limexp`, and the nonlinear contribution are lowered. `$discontinuity` is erased and named `$limit` is pass-through, so solver control semantics are not covered. |
| `08_file_and_display_side_effects.va` | Absolute time and the analog contribution remain observable. `$fopen`, file/display tasks, and `$fclose` are erased/placeholders; descriptor flow and side effects are not substantively covered. |
| `09_optional_port_environment.va` | Parameter/fallback arithmetic is present, but `$port_connected` lowers to constant true and `$simparam` always chooses the source fallback; the disconnected and simulator-parameter paths are not covered. |
| `10_nested_preprocessor_model.va` | Nested `ifdef`/`ifndef`, macro state, `$pow`, conditional source selection. |
| `11_controlled_source_named_branches.va` | Four-terminal controlled source, named branch probing/contribution, parameter range, and control-port loading. |
| `12_multi_branch_nonlinear_device.va` | Three-terminal nonlinear device, guarded parameter, local operating value, `max`, `tanh`, and multiple branch contributions. |
| `13_noise_temperature_analysis.va` | Constants include, bounded parameters, analysis selection, temperature arithmetic, and deterministic conductance are lowered. Both noise calls become zero and `noise_gens` is empty, so white/flicker noise generation is an implementation gap. |
| `14_macro_alias_parameter_ranges.va` | Formal macro and parameter declarations parse, but the expected Zig multiplies by zero instead of `scale`: `aliasparam gain = scale` is not implemented. The snapshot records this gap rather than correct alias semantics. |
| `15_electrothermal_dual_discipline.va` | Electrical and thermal ports, Joule heating, two disciplines' access functions, and dual-domain contributions. |
| `16_file_display_diagnostics.va` | The source contains the complete open/write/flush/close lifecycle, but those calls and `$warning` are erased in generated Zig. Only the voltage condition and electrical contribution are observable; lifecycle side effects are not substantively covered. |
| `17_optional_port_hierarchy.va` | The controlled-source arithmetic parses, but `$port_connected` is constant true, `$mfactor` is constant one, placement values are zero, and the environment term is multiplied by zero. Neither optional-port nor hierarchy behavior is substantively covered. |
| `18_analysis_modes_and_severity.va` | Multiple analysis names, piecewise conductance, and the guarded parameter are substantive; `$info` is erased, so informational diagnostic behavior is not covered. |
| `19_named_limiter_nonlinear.va` | Thermal voltage, `limexp`, and nonlinear current are lowered. Named `$limit` is pass-through and `$bound_step` is erased, so limiter/timestep semantics are implementation gaps. |
| `20_function_branch_system_math.va` | Named branch, analog function, system-style hyperbolic/min/max math, and contribution. |
| `21_three_terminal_piecewise_device.va` | Three-terminal piecewise conductance selected by `case`, local state, and multiple branch loads. |
| `22_parameter_binding_environment.va` | Ternary/local-gain arithmetic and contribution are lowered. Override detection uses the default-value comparison heuristic and optional-port detection is constant true, so explicit-default and disconnected cases are not covered. |

Combined cases are regression fixtures, not substitutes for the literal
section-by-section inventories in each chapter or annex `COVERAGE.md`.
Successful snapshots above may intentionally freeze implementation gaps; only
the effects explicitly described as substantive should be read as semantic
coverage.
