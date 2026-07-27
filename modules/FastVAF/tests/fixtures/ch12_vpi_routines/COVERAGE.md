# Chapter 12 coverage

Source: `modules/FastVAF/docs/ch12-vpi-routines.html`. Every routine in this
chapter is a C function exported by a simulator's VPI host. FastVAF compiles a
Verilog-A device into Zig and has no C VPI ABI, handles, iterators, callbacks,
or `vpi_user.h` structures. Therefore each section is inventoried below as
non-codegen-applicable. Representative `.va` misuse fixtures (`03`-`13`)
require a loud `unknown call` diagnostic; `01` and `02` exercise the only
source-facing part, calls to a system task/function that could be registered
by an external VPI host.

| Documentation id | Applicability / representative fixture |
|---|---|
| `s12-1` | C routine definition conventions; no Verilog-A rule. |
| `s12-2` | `vpi_chk_error()`: C-only; `03_chk_error_not_va.va`. |
| `s12-3` | Host C routine boundary; direct Verilog-A misuse is rejected by `14_compare_objects_not_va.va` (`compare_objects`). |
| `s12-4` | Host C routine boundary; direct Verilog-A misuse is rejected by `15_free_object_not_va.va` (`free_object`). |
| `s12-5` | Host C routine boundary; direct Verilog-A misuse is rejected by `16_get_not_va.va` (`get`). |
| `s12-6` | Host C routine boundary; direct Verilog-A misuse is rejected by `17_get_cb_info_not_va.va` (`get_cb_info`). |
| `s12-7` | Host C routine boundary; direct Verilog-A misuse is rejected by `18_get_analog_delta_not_va.va` (`get_analog_delta`). |
| `s12-8` | Host C routine boundary; direct Verilog-A misuse is rejected by `19_get_analog_freq_not_va.va` (`get_analog_freq`). |
| `s12-9` | Host C routine boundary; direct Verilog-A misuse is rejected by `20_get_analog_time_not_va.va` (`get_analog_time`). |
| `s12-10` | Host C routine boundary; direct Verilog-A misuse is rejected by `21_get_analog_value_not_va.va` (`get_analog_value`). |
| `s12-11` | Host C routine boundary; direct Verilog-A misuse is rejected by `22_get_delays_not_va.va` (`get_delays`). |
| `s12-12` | Host C routine boundary; direct Verilog-A misuse is rejected by `23_get_str_not_va.va` (`get_str`). |
| `s12-13` | Host C routine boundary; direct Verilog-A misuse is rejected by `24_get_analog_systf_info_not_va.va` (`get_analog_systf_info`). |
| `s12-14` | Host C routine boundary; direct Verilog-A misuse is rejected by `25_get_systf_info_not_va.va` (`get_systf_info`). |
| `s12-15` | Host C routine boundary; direct Verilog-A misuse is rejected by `26_get_time_not_va.va` (`get_time`). |
| `s12-16` | Host C routine boundary; direct Verilog-A misuse is rejected by `27_get_value_not_va.va` (`get_value`). |
| `s12-17` | Host C routine boundary; direct Verilog-A misuse is rejected by `28_get_vlog_info_not_va.va` (`get_vlog_info`). |
| `s12-18` | Host C routine boundary; direct Verilog-A misuse is rejected by `29_get_real_not_va.va` (`get_real`). |
| `s12-19` | Host C routine boundary; direct Verilog-A misuse is rejected by `30_handle_not_va.va` (`handle`). |
| `s12-20` | Host C routine boundary; direct Verilog-A misuse is rejected by `31_handle_by_index_not_va.va` (`handle_by_index`). |
| `s12-21` | Host C routine boundary; direct Verilog-A misuse is rejected by `32_handle_by_name_not_va.va` (`handle_by_name`). |
| `s12-22` | Host C routine boundary; direct Verilog-A misuse is rejected by `33_handle_multi_not_va.va` (`handle_multi`). |
| `s12-22-1` | Analog system-task derivative handles are registered and populated by C callbacks; source task call: `01`. |
| `s12-22-2` | LRM resistor analog-task example call: `01_analog_systf_resistor_call.va`; its C implementation is non-codegen. |
| `s12-23` | Host C routine boundary; direct Verilog-A misuse is rejected by `34_iterate_not_va.va` (`iterate`). |
| `s12-24` | Host C routine boundary; direct Verilog-A misuse is rejected by `35_mcd_close_not_va.va` (`mcd_close`). |
| `s12-25` | Host C routine boundary; direct Verilog-A misuse is rejected by `36_mcd_name_not_va.va` (`mcd_name`). |
| `s12-26` | Host C routine boundary; direct Verilog-A misuse is rejected by `37_mcd_open_not_va.va` (`mcd_open`). |
| `s12-27` | Host C routine boundary; direct Verilog-A misuse is rejected by `38_mcd_printf_not_va.va` (`mcd_printf`). |
| `s12-28` | Host C routine boundary; direct Verilog-A misuse is rejected by `39_printf_not_va.va` (`printf`). |
| `s12-29` | Host C routine boundary; direct Verilog-A misuse is rejected by `40_put_delays_not_va.va` (`put_delays`). |
| `s12-30` | Host C routine boundary; direct Verilog-A misuse is rejected by `41_put_value_not_va.va` (`put_value`). |
| `s12-31` | Host C routine boundary; direct Verilog-A misuse is rejected by `42_register_cb_not_va.va` (`register_cb`). |
| `s12-31-1` | Simulation-event callback reasons are host state; source event call site in Chapter 11 fixture `08_callback_call_site.va`. |
| `s12-31-2` | Simulation-time callback reasons are host queue state, non-codegen. |
| `s12-31-3` | Analog solver callback reasons are host solver state, non-codegen. |
| `s12-31-4` | Simulator action/feature callback reasons are process state, non-codegen. |
| `s12-32` | Host C routine boundary; direct Verilog-A misuse is rejected by `43_register_analog_systf_not_va.va` (`register_analog_systf`). |
| `s12-32-1` | Analog system task/function compile/call callbacks: source call sites `01`, `02`. |
| `s12-32-2` | Partial derivative declaration structure is C-only; `$resistor` arguments are represented by `01`. |
| `s12-32-3` | Registration/derivative examples are C-only; LRM `.va` call form is `01`. |
| `s12-33` | Host C routine boundary; direct Verilog-A misuse is rejected by `44_register_systf_not_va.va` (`register_systf`). |
| `s12-33-1` | User system task/function callback behavior: source call site `02`. |
| `s12-33-2` | Startup routine arrays/linking are host build configuration, not Verilog-A. |
| `s12-34` | Host C routine boundary; direct Verilog-A misuse is rejected by `45_remove_cb_not_va.va` (`remove_cb`). |
| `s12-35` | Host C routine boundary; direct Verilog-A misuse is rejected by `46_scan_not_va.va` (`scan`). |
| `s12-36` | Host C routine boundary; direct Verilog-A misuse is rejected by `47_sim_control_not_va.va` (`sim_control`). |

The VPI data structures, return constants, value encodings, callback reason
tables, ownership rules, and C examples cannot produce a device Zig dump.
They require a separate simulator-host VPI implementation and C conformance
suite; recording this boundary prevents misleading placeholder coverage.

## Literal fixture inventory

Every fixture named below is part of this chapter's section mapping above.

- `01_analog_systf_resistor_call.va`
- `02_user_systf_function_call.va`
- `03_chk_error_not_va.va`
- `04_object_property_not_va.va`
- `05_handle_not_va.va`
- `06_iteration_not_va.va`
- `07_delays_not_va.va`
- `08_values_not_va.va`
- `09_time_not_va.va`
- `10_callback_not_va.va`
- `11_register_systf_not_va.va`
- `12_mcd_not_va.va`
- `13_sim_control_not_va.va`
- `14_compare_objects_not_va.va`
- `15_free_object_not_va.va`
- `16_get_not_va.va`
- `17_get_cb_info_not_va.va`
- `18_get_analog_delta_not_va.va`
- `19_get_analog_freq_not_va.va`
- `20_get_analog_time_not_va.va`
- `21_get_analog_value_not_va.va`
- `22_get_delays_not_va.va`
- `23_get_str_not_va.va`
- `24_get_analog_systf_info_not_va.va`
- `25_get_systf_info_not_va.va`
- `26_get_time_not_va.va`
- `27_get_value_not_va.va`
- `28_get_vlog_info_not_va.va`
- `29_get_real_not_va.va`
- `30_handle_not_va.va`
- `31_handle_by_index_not_va.va`
- `32_handle_by_name_not_va.va`
- `33_handle_multi_not_va.va`
- `34_iterate_not_va.va`
- `35_mcd_close_not_va.va`
- `36_mcd_name_not_va.va`
- `37_mcd_open_not_va.va`
- `38_mcd_printf_not_va.va`
- `39_printf_not_va.va`
- `40_put_delays_not_va.va`
- `41_put_value_not_va.va`
- `42_register_cb_not_va.va`
- `43_register_analog_systf_not_va.va`
- `44_register_systf_not_va.va`
- `45_remove_cb_not_va.va`
- `46_scan_not_va.va`
- `47_sim_control_not_va.va`
