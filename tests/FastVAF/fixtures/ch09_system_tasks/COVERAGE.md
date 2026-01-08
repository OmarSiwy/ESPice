# Chapter 9 coverage

Source: `modules/FastVAF/docs/ch9-system.html`. A fixture with an
`expected-error.txt` exercises a construct that FastVAF must reject rather
than silently compile. Other fixtures freeze the generated Zig, including
the backend's documented simulator-free placeholders.

| Documentation id | Rules and fixtures |
|---|---|
| `s9.1` | Overview and analog-context availability: the full folder. |
| `s9.2` | Every category in Tables 9-1 through 9-20 is represented by `01`-`37`; PLA, queue, digital-only timescale, and connectmodule scheduling have no analog device-code semantics. |
| `s9.3` | Analog-context call sites: `01`-`13`; generated devices deliberately make display/file/control tasks void. These fixtures do not distinguish accepted from rejected solver iterations; rollback/commit behavior is outside source-to-Zig lowering. |
| `s9.4` | Display task family: `01`-`06`. |
| `s9.4.1` | `$strobe`, `$display`, `$monitor`, `$write`, `$debug`: `01`-`05`. |
| `s9.4.2` | String escapes: `06_display_formats.va`. |
| `s9.4.3` | Integer, string, and real format specifications: `06_display_formats.va`. |
| `s9.4.4` | `%m`: `06_display_formats.va`; hierarchy formatting is runtime-only. |
| `s9.4.5` | `%s`: `06_display_formats.va`. |
| `s9.4.6` | Display call sites are present in `01`-`05`, but the iterative-solve emission rule is not executable in the simulator-free fixture harness. |
| `s9.4.7` | Digital-context `%r`: syntax in `03_display_write.va`; digital simulation is outside FastVAF's Verilog-A backend. |
| `s9.5` | File-I/O family: `07`-`11`. |
| `s9.5.1` | `$fopen` descriptor forms and `$fclose`: `07_file_open_close.va`. |
| `s9.5.1.1` | Reopen behavior across analyses is simulator runtime policy; call forms are covered by `07`. |
| `s9.5.1.2` | Analog/digital descriptor sharing is mixed-signal runtime policy; analog form is covered by `07`-`08`. |
| `s9.5.2` | `$fdisplay`, `$fwrite`, `$fstrobe`, `$fmonitor`, `$fdebug`: `08_file_output.va`. |
| `s9.5.3` | `$swrite` and `$sformat`: `09_string_formatting.va`. |
| `s9.5.4` | File reads and formatted scans: `10_file_read_scan.va`. |
| `s9.5.4.1` | `$fgets`: `10_file_read_scan.va`. |
| `s9.5.4.2` | `$fscanf` and `$sscanf`: `10_file_read_scan.va`. |
| `s9.5.5` | `$ftell`, `$fseek`, `$rewind`: `11_file_position_status.va`. |
| `s9.5.6` | `$fflush`: `11_file_position_status.va`. |
| `s9.5.7` | `$ferror`: `11_file_position_status.va`. |
| `s9.5.8` | `$feof`: `11_file_position_status.va`. |
| `s9.5.9` | Rollback/commit of file position and output is simulator runtime policy; call sites are `08`-`11`. |
| `s9.6` | Timescale system tasks are digital-only and have no Verilog-A code-generation rule. |
| `s9.7` | Simulation control task family: `12`-`13`. |
| `s9.7.1` | `$finish` optional diagnostic level: `12_finish_stop.va`. |
| `s9.7.2` | `$stop` optional diagnostic level: `12_finish_stop.va`. |
| `s9.7.3` | `$fatal`, `$error`, `$warning`, `$info`: `13_severity_tasks.va`. |
| `s9.8` | PLA tasks are expressly not extended to analog context; non-applicable to FastVAF device code. |
| `s9.9` | Stochastic queue tasks are expressly not extended to analog context; non-applicable. |
| `s9.10` | `$abstime`: `14_abstime.va`. |
| `s9.11` | Conversion function call forms: `15_conversion_functions.va`; the current backend emits placeholders for conversion functions. |
| `s9.12` | `$test$plusargs` and `$value$plusargs`: `16_plusargs.va`; invocation options are unavailable to compiled devices. |
| `s9.13` | Every named random/distribution call family has an atomic source fixture in `32`-`35` and `115`-`130`; the paramset-only type-string spellings are retained in `132`-`133`. These fixtures assert exact lowering or diagnostics, never distribution quality. |
| `s9.13.1` | `$random` is covered both without a seed (`115_random_no_seed_unsupported.va`) and with an integer-variable seed (`32_random_unsupported.va`). `$arandom` is covered without a seed (`116_arandom_no_seed_unsupported.va`), with an integer variable (`33_arandom_unsupported.va`), integer parameter (`117_arandom_parameter_seed_unsupported.va`), and signed decimal constant (`118_arandom_negative_seed_unsupported.va`). `132_arandom_type_string_paramset_unsupported.va` contains the paramset-only `"instance"` form, but FastVAF rejects the enclosing paramset before parsing or lowering the call. Supported seed mutation, repeatable streams, and Monte-Carlo scoping are therefore not claimed. |
| `s9.13.2` | All seven integer names are atomic: `$dist_normal` in `34_distribution_unsupported.va` plus `$dist_uniform`, `$dist_exponential`, `$dist_poisson`, `$dist_chi_square`, `$dist_t`, and `$dist_erlang` in `119`-`124`; each is rejected by its exact function name. All seven real names are atomic: `$rdist_uniform` in `35_real_distribution_unsupported.va`, `$rdist_normal` in `125_rdist_normal_unsupported.va`, and the remaining five in `126`-`130`. The first two are rejected; `126`-`130` currently lower the call result to zero. `133_rdist_type_string_paramset_unsupported.va` contains a negative constant seed and the paramset-only `"global"` form, but stops at the unsupported paramset boundary. Argument-domain rules, seed updates, Monte-Carlo scope, and returned distributions are not exercised. |
| `s9.13.3` | No fixture claims the specified probability algorithms: the functions either receive an exact unsupported diagnostic, stop at the paramset boundary, or produce a zero-placeholder Zig snapshot. |
| `s9.14` | Unary, trigonometric, binary, min/max/abs, and 2023 math forms: `17`-`20`. |
| `s9.15` | `$temperature`, `$vt`, `$simparam`, and the type-correct string assignment form of `$simparam$str`: `21`-`23`. The backend lowers `$simparam$str` to an empty placeholder rather than a simulator string. |
| `s9.16` | `$simprobe`: `36_simprobe_unsupported.va`. |
| `s9.17` | Analog kernel control family: `24`-`27`. |
| `s9.17.1` | `$discontinuity`, including `0` and `-1`: `24_discontinuity.va`. |
| `s9.17.2` | `$bound_step`: `25_bound_step.va`. |
| `s9.17.3` | `$limit` single-argument and named-limiter forms: `26_limit.va`, `27_limit_named.va`. User limiter callback execution remains simulator policy. |
| `s9.18` | `$mfactor`, `$xposition`, `$yposition`, `$angle`, `$hflip`, `$vflip`: `28_hierarchical_parameters.va`. Only multiplicity has a specialized backend path. |
| `s9.19` | `$param_given` and `$port_connected` call sites: `29_binding_detection.va`. Current lowering is not conforming elaboration metadata: `$param_given` compares the value with its default and therefore cannot distinguish an explicit override equal to the default, while `$port_connected` is constant true. |
| `s9.20` | `$analog_node_alias` and `$analog_port_alias` call forms: `30_node_alias_calls.va`; topology aliasing is not implemented by the simulator-free backend. |
| `s9.21` | `$table_model` is rejected by exact function-name diagnostics for both file-backed (`37_table_model_unsupported.va`) and array-backed (`131_table_model_array_control_unsupported.va`) calls. |
| `s9.21.1` | `37` supplies a file name; `131` supplies independent/dependent real arrays. Both stop before data capture, sorting, or interpolation. |
| `s9.21.2` | Control strings are present with both data-source forms: `"1LL"` in `37` and `"1LL;1"` (including the dependent selector) in `131`. |
| `s9.21.3` | Example `1LL` control is present in `37`. |
| `s9.21.4` | Interpolation algorithms require table runtime support and are rejected. |
| `fn9.21.4-1` | Informative bibliography footnote; no language rule. |
| `s9.21.5` | The documented file-backed and array-backed example shapes are represented by `37` and `131`, respectively; neither executes. |
| `s9.22` | `31_driver_access.va` and atomics `107`-`110` freeze a current frontend gap: connectmodule-only driver/receiver calls are incorrectly accepted in an ordinary module's analog block and lowered to zero. They are not valid examples of the documented context. |
| `s9.22.1` | `$driver_count`: invalid-context acceptance snapshots `31`, `107`. |
| `s9.22.2` | `$receiver_count`: invalid ordinary-module acceptance snapshots `31`, `108`; its valid analog context is still a connectmodule. |
| `s9.22.3` | `$driver_state`: invalid-context acceptance snapshots `31`, `109`. |
| `s9.22.4` | `$driver_strength`: invalid-context acceptance snapshots `31`, `110`. |
| `s9.22.5` | `38_driver_update_connectmodule_unsupported.va` reaches the unsupported top-level `connectmodule` boundary and returns `NoModule`; it does not independently prove parsing or rejection of `driver_update`. |
| `s9.22.6` | Receiver net resolution is connectmodule elaboration, not device code. |
| `s9.22.7` | The full connectmodule example is mixed-signal/digital and non-applicable. `31` contains only invalid ordinary-module acceptance snapshots, not a substitute for the example. |
| `s9.23` | `31` and atomics `111`-`114` freeze invalid ordinary-module acceptance of supplementary functions that the LRM permits only in the digital context of connectmodules. |
| `s9.23.1` | `$driver_delay`: invalid-context acceptance snapshots `31`, `111`. |
| `s9.23.2` | `$driver_next_state`: invalid-context acceptance snapshots `31`, `112`. |
| `s9.23.3` | `$driver_next_strength`: invalid-context acceptance snapshots `31`, `113`. |
| `s9.23.4` | `$driver_type`: invalid-context acceptance snapshots `31`, `114`. |

Known implementation gaps deliberately frozen by expected Zig dumps include
placeholder-zero conversion, plusarg, `ln1p`/`expm1`, string-simparam,
hierarchical placement, alias, and driver-access calls. Binding detection is
also approximate as described for `s9.19`. A dump fixture is not a claim that
FastVAF implements the simulator-side semantic effect, and the driver-access
dumps are specifically nonconforming context-acceptance snapshots.

## Literal fixture inventory

Every fixture named below is part of this chapter's section mapping above.

- `01_display_strobe.va`
- `02_display_display.va`
- `03_display_write.va`
- `04_display_monitor.va`
- `05_display_debug.va`
- `06_display_formats.va`
- `07_file_open_close.va`
- `08_file_output.va`
- `09_string_formatting.va`
- `10_file_read_scan.va`
- `11_file_position_status.va`
- `12_finish_stop.va`
- `13_severity_tasks.va`
- `14_abstime.va`
- `15_conversion_functions.va`
- `16_plusargs.va`
- `17_math_unary.va`
- `18_math_trig.va`
- `19_math_binary.va`
- `20_math_2023.va`
- `21_temperature_vt.va`
- `22_simparam.va`
- `23_simparam_string.va`
- `24_discontinuity.va`
- `25_bound_step.va`
- `26_limit.va`
- `27_limit_named.va`
- `28_hierarchical_parameters.va`
- `29_binding_detection.va`
- `30_node_alias_calls.va`
- `31_driver_access.va`
- `32_random_unsupported.va`
- `33_arandom_unsupported.va`
- `34_distribution_unsupported.va`
- `35_real_distribution_unsupported.va`
- `36_simprobe_unsupported.va`
- `37_table_model_unsupported.va`
- `38_driver_update_connectmodule_unsupported.va`
- `115_random_no_seed_unsupported.va`
- `116_arandom_no_seed_unsupported.va`
- `117_arandom_parameter_seed_unsupported.va`
- `118_arandom_negative_seed_unsupported.va`
- `119_dist_uniform_unsupported.va`
- `120_dist_exponential_unsupported.va`
- `121_dist_poisson_unsupported.va`
- `122_dist_chi_square_unsupported.va`
- `123_dist_t_unsupported.va`
- `124_dist_erlang_unsupported.va`
- `125_rdist_normal_unsupported.va`
- `126_rdist_exponential_lowering.va`
- `127_rdist_poisson_lowering.va`
- `128_rdist_chi_square_lowering.va`
- `129_rdist_t_lowering.va`
- `130_rdist_erlang_lowering.va`
- `131_table_model_array_control_unsupported.va`
- `132_arandom_type_string_paramset_unsupported.va`
- `133_rdist_type_string_paramset_unsupported.va`

### Atomic per-call fixtures

The following fixtures split every source-facing spelling previously exercised
in a family fixture into one-call snapshots. File-I/O calls map to sections
9.5.2--9.5.8, controls to 9.7, conversions and plusargs to 9.11--9.12,
math calls to 9.14, environment calls to 9.15/9.18--9.20, and driver calls
to 9.22--9.23. The node-alias atomics use the required `analog initial`
context. Driver-access atomics `107`--`114` intentionally record the invalid
ordinary-module acceptance gap described above; they are not positive
conformance fixtures.

- `01_display_strobe.va`
- `02_display_display.va`
- `039_fdisplay.va`
- `03_display_write.va`
- `040_fwrite.va`
- `041_fstrobe.va`
- `042_fmonitor.va`
- `043_fdebug.va`
- `044_swrite.va`
- `045_sformat.va`
- `046_fgets.va`
- `047_fscanf.va`
- `048_sscanf.va`
- `049_ftell.va`
- `04_display_monitor.va`
- `050_fseek.va`
- `051_rewind.va`
- `052_fflush.va`
- `053_ferror.va`
- `054_feof.va`
- `055_finish.va`
- `056_stop.va`
- `057_fatal.va`
- `058_error.va`
- `059_warning.va`
- `05_display_debug.va`
- `060_info.va`
- `061_rtoi.va`
- `062_itor.va`
- `063_realtobits.va`
- `064_bitstoreal.va`
- `065_test_plusargs.va`
- `066_value_plusargs.va`
- `067_ln.va`
- `068_log10.va`
- `069_exp.va`
- `06_display_formats.va`
- `070_sqrt.va`
- `071_floor.va`
- `072_ceil.va`
- `073_abs.va`
- `074_clog2.va`
- `075_sin.va`
- `076_cos.va`
- `077_tan.va`
- `078_asin.va`
- `079_acos.va`
- `07_file_open_close.va`
- `080_atan.va`
- `081_sinh.va`
- `082_cosh.va`
- `083_tanh.va`
- `084_asinh.va`
- `085_acosh.va`
- `086_atanh.va`
- `087_pow.va`
- `088_atan2.va`
- `089_hypot.va`
- `08_file_output.va`
- `090_min.va`
- `091_max.va`
- `092_ln1p.va`
- `093_expm1.va`
- `094_temperature.va`
- `095_vt_ambient.va`
- `096_vt_temperature.va`
- `097_mfactor.va`
- `098_xposition.va`
- `099_yposition.va`
- `100_angle.va`
- `101_hflip.va`
- `102_vflip.va`
- `103_param_given.va`
- `104_port_connected.va`
- `105_analog_node_alias.va`
- `106_analog_port_alias.va`
- `107_driver_count.va`
- `108_receiver_count.va`
- `109_driver_state.va`
- `110_driver_strength.va`
- `111_driver_delay.va`
- `112_driver_next_state.va`
- `113_driver_next_strength.va`
- `114_driver_type.va`
- `115_random_no_seed_unsupported.va`
- `116_arandom_no_seed_unsupported.va`
- `117_arandom_parameter_seed_unsupported.va`
- `118_arandom_negative_seed_unsupported.va`
- `119_dist_uniform_unsupported.va`
- `120_dist_exponential_unsupported.va`
- `121_dist_poisson_unsupported.va`
- `122_dist_chi_square_unsupported.va`
- `123_dist_t_unsupported.va`
- `124_dist_erlang_unsupported.va`
- `125_rdist_normal_unsupported.va`
- `126_rdist_exponential_lowering.va`
- `127_rdist_poisson_lowering.va`
- `128_rdist_chi_square_lowering.va`
- `129_rdist_t_lowering.va`
- `130_rdist_erlang_lowering.va`
- `131_table_model_array_control_unsupported.va`
- `132_arandom_type_string_paramset_unsupported.va`
- `133_rdist_type_string_paramset_unsupported.va`
- `09_string_formatting.va`
