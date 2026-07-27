# Annex D coverage — standard definitions

Source: `docs/annex-d-stddefs.html`. Annex D is normative and publishes the
verbatim `disciplines.vams`, `constants.vams`, and `driver_access.vams`
packages. These fixtures isolate their literal identifiers, macro families,
override branches, selector precedence, nature relationships, and values.

| Documentation ID | Rules and fixtures |
|---|---|
| `sD-1` | The `DISCIPLINES_VAMS` guard, standard electrical natures, `idt_nature`/`ddt_nature` relationships, access functions, units, default tolerances, and conservative/signal-flow disciplines are exercised by `electrical_definitions.va`, `literal_electrical_disciplines.va`, and `discrete_disciplines.va`. The literal escaped `\logic` discipline is isolated by `literal_logic_discipline.va`. Magnetic definitions and the normative reuse of `Flux` are covered by `magnetic_definitions.va` and `literal_magnetic_discipline.va`; thermal definitions by `thermal_definitions.va` and `literal_thermal_discipline.va`; kinematic definitions by `kinematic_definitions.va` and `literal_kinematic_disciplines.va`; rotational definitions by `rotational_definitions.va` and `literal_rotational_disciplines.va`. `abstol_override_branches.va` defines and selects all 16 published `_ABSTOL` override arms. |
| `sD-2` | The `CONSTANTS_VAMS` guard and all 14 literal `M_*` mathematical constants are used by `mathematical_constants.va`. `physical_constants_select.vh` reproduces the published nested selector chain; `physical_constants_nist2018.va`, `physical_constants_spice.va`, `physical_constants_old.va`, `physical_constants_nist2010.va`, and `physical_constants_nist1998.va` exercise its priority and fallback branches. `vacuum_constants.va` covers `P_C` and `P_U0_OLD`; `celsius_constant.va` covers `P_CELSIUS0`. These fixtures validate preprocessing and lowering of the literal names and values, not external metrology provenance. |
| `sD-3` | The `DRIVER_ACCESS_VAMS` guard and all 12 published `DRIVER_*` bit masks are split across `driver_flags_low.va` and `driver_flags_high.va`. Driver scheduling and connectmodule runtime behavior remain outside a standalone generated Verilog-A device. |

## Literal fixture inventory

- `abstol_override_branches.va`
- `celsius_constant.va`
- `discrete_disciplines.va`
- `driver_flags_high.va`
- `driver_flags_low.va`
- `electrical_definitions.va`
- `kinematic_definitions.va`
- `literal_electrical_disciplines.va`
- `literal_kinematic_disciplines.va`
- `literal_logic_discipline.va`
- `literal_magnetic_discipline.va`
- `literal_rotational_disciplines.va`
- `literal_thermal_discipline.va`
- `magnetic_definitions.va`
- `mathematical_constants.va`
- `physical_constants_nist1998.va`
- `physical_constants_nist2010.va`
- `physical_constants_nist2018.va`
- `physical_constants_old.va`
- `physical_constants_spice.va`
- `rotational_definitions.va`
- `thermal_definitions.va`
- `vacuum_constants.va`

The shared include `physical_constants_select.vh` is source support for the
five physical-constant selection fixtures and is not a standalone module.
