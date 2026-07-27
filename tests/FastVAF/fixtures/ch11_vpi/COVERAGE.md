# Chapter 11 coverage

Source: `modules/FastVAF/docs/ch11-vpi.html`. VPI is a simulator-host C API,
not Verilog-A syntax and not part of FastVAF's generated-device contract.
Consequently the exhaustive inventory below marks C-only rules as
non-codegen-applicable. `09` and `10` prove that C VPI routine names are not
silently treated as Verilog-A functions. `01`-`08` supply representative HDL
objects and system-task/function call sites that a host VPI would inspect.

| Documentation id | Applicability / fixture |
|---|---|
| `s11-1` | VPI overview; host C API, non-codegen. |
| `s11-2` | Interface and two functional areas; host C API, non-codegen. |
| `s11-2-1` | Callback registration is host-side; representative callback-invoked call site: `08_callback_call_site.va`; direct registration rejection: `10_c_vpi_register_cb_not_va.va`. |
| `s11-2-2` | Instantiated design object access is unavailable in a single-device compiler; representative source objects: `01`-`07`. |
| `s11-2-3` | `vpi_chk_error()` is C-only; covered as part of the Chapter 12 inventory. |
| `s11-3` | Object classifications are host metadata, not generated device state. |
| `s11-3-1` | Handles, one-to-one and one-to-many traversal, and property getters are C-only; `09_c_vpi_get_not_va.va` is the explicit source-language rejection. |
| `s11-3-2` | Delay/value structures and analog derivatives are C-only; representative analog branch: `02_branch_quantity.va`. |
| `s11-4` | Tables 11-1 through 11-10 are completely mapped routine-by-routine in `ch12_vpi_routines/COVERAGE.md`; no Verilog-A production is defined here. |
| `s11-5` | Diagram legend only; no executable language rule. |
| `s11-5-1` | Object/class enclosure legend; informative, non-codegen. |
| `s11-5-2` | Property access legend; host C API, non-codegen. |
| `s11-5-3` | Relationship traversal legend; host C API, non-codegen. |
| `s11-6` | Object-model inventory; representative source objects are `01`-`08`; FastVAF exposes no VPI model. |
| `s11-6-1` | Module properties/relations: `01_module_port_node.va`. |
| `s11-6-2` | Standard nature/discipline source objects and their access functions are isolated by `11_nature_discipline_objects.va`; VPI properties remain host metadata. |
| `s11-6-3` | Function and IO declarations: `12_function_io_objects.va`; module scope is also present in every valid fixture. |
| `s11-6-4` | Port objects: `13_port_node_objects.va`. |
| `s11-6-5` | Continuous node objects: `13_port_node_objects.va`. |
| `s11-6-6` | Branch objects: `14_branch_object.va`. |
| `s11-6-7` | Potential/flow quantity objects and probes: `15_quantity_objects.va`. |
| `s11-6-8` | Net objects and relations: `01_module_port_node.va`. |
| `s11-6-9` | Reg objects are discrete Verilog objects outside FastVAF's Verilog-A device subset. |
| `s11-6-10` | Real/integer variables: `16_variable_objects.va`; named events are not supported by FastVAF. |
| `s11-6-11` | Verilog memory object model is discrete-host metadata; no FastVAF VPI layer. |
| `s11-6-12` | Parameter objects: `17_parameter_object.va`; specparam/defparam/param-assign VPI relations are not exposed. |
| `s11-6-13` | Primitive/terminal object model is a host elaboration concern; no generated-device VPI. |
| `s11-6-14` | UDP definitions/table entries are discrete Verilog and non-applicable. |
| `s11-6-15` | Module paths/timing checks/intermodule paths are discrete timing-model metadata and non-applicable. |
| `s11-6-16` | Function, system-task, and system-function calls are isolated in `18_function_call_object_atomic.va`, `19_system_task_call_object_atomic.va`, and `20_system_function_call_object_atomic.va`. |
| `s11-6-17` | Continuous assignment VPI objects are discrete Verilog; analog contribution counterpart: `02`. |
| `s11-6-18` | Simple expression objects: `21_simple_expression_object.va`. |
| `s11-6-19` | Operations and access-function objects: `22_operation_access_objects.va`; call objects are `18`-`20`. |
| `s11-6-20` | Contribution and direct/flow properties: `23_contribution_object.va`. |
| `s11-6-21` | Analog process, named block, and contained statements: `24_named_process_object.va`; VPI event-control objects are host metadata and source event syntax is covered by Chapter 5. |
| `s11-6-22` | Assignment and loop controls: `25_assignment_loop_objects.va`; VPI event/delay/repeat-control objects are discrete-runtime host metadata. |
| `s11-6-23` | If/if-else/case and case items: `26_conditional_case_objects.va`. |
| `s11-6-24` | Procedural assign/deassign/force/release/disable are digital procedural constructs and outside compiled Verilog-A devices. |
| `s11-6-25` | Callback/time-queue objects are simulator-host state; callback-invoked system call site: `08`; direct C callback misuse: `10`. |

The expected Zig for custom `$fixture_*` calls records only parsing/lowering of
the HDL call object. It does not imply a VPI registration or callback engine.

## Literal fixture inventory

Every fixture named below is part of this chapter's section mapping above.

- `01_module_port_node.va`
- `02_branch_quantity.va`
- `03_parameters_variables.va`
- `04_function_call_object.va`
- `05_system_task_call_object.va`
- `06_system_function_call_object.va`
- `07_process_statement_objects.va`
- `08_callback_call_site.va`
- `09_c_vpi_get_not_va.va`
- `10_c_vpi_register_cb_not_va.va`
- `11_nature_discipline_objects.va`
- `12_function_io_objects.va`
- `13_port_node_objects.va`
- `14_branch_object.va`
- `15_quantity_objects.va`
- `16_variable_objects.va`
- `17_parameter_object.va`
- `18_function_call_object_atomic.va`
- `19_system_task_call_object_atomic.va`
- `20_system_function_call_object_atomic.va`
- `21_simple_expression_object.va`
- `22_operation_access_objects.va`
- `23_contribution_object.va`
- `24_named_process_object.va`
- `25_assignment_loop_objects.va`
- `26_conditional_case_objects.va`
