# Chapter 10 coverage

Source: `modules/FastVAF/docs/ch10-directives.html`.

| Documentation id | Rules and fixtures |
|---|---|
| `s10-1` | Accent-grave directive handling represented by `01`-`27`. `19` samples several ignored IEEE directives, but it does not exhaust Table 10-1 (for example, the decay/strength, delay-mode, protect, and `unconnected_drive` directives are absent). |
| `s10-2` | Nonempty base and qualifier forms are `01_default_discipline.va` and `02_default_discipline_qualified.va`; `24_default_discipline_empty_reset.va` first establishes a default and then uses the empty directive to reset it. FastVAF consumes these directives but does not apply discipline resolution, and the fixtures explicitly declare their net disciplines, so the snapshots prove directive acceptance rather than the resulting discipline state. |
| `s10-3` | `default_transition`: `03_default_transition.va`; the directive is consumed but its default is not retained or applied by lowering. Stateful `transition()` behavior is covered in Chapter 4 fixtures. |
| `s10-4` | Object, formal-argument, multiline and nested `define`: `04`-`07`; `undef`: `08`; forbidden `__VAMS_` prefix nonconformance: `15`; undefined macro diagnostic: `23`. |
| `s10-5` | `__VAMS_ENABLE__` and `__VAMS_COMPACT_MODELING__`: `13`, `14`. The false branch of `13` is a conformance gap because `__VAMS_ENABLE__` is mandatory. The compact-modeling macro is conditional on complete extension support, so its absence is not by itself a conformance failure. Standard constants via include are in `18`. |
| `s10-6` | Atomic `begin_keywords`/`end_keywords` pairs cover every required spelling: `25_begin_keywords_1364_1995.va`, `26_begin_keywords_1364_2001.va`, `16_begin_keywords_verilog.va` (`1364-2005`), `27_begin_keywords_vams_2_3.va`, and `17_begin_keywords_vams.va` (`VAMS-2023`). FastVAF currently ignores the selected keyword set: the three 1364 fixtures validly accept identifier `sin`, while the two VAMS fixtures freeze its invalid acceptance even though `sin` is reserved in those keyword sets. |
| `s10-7` | Unsupported `__FILE__` and `__LINE__` expansion paths: `21`, `22`; neither macro is currently implemented. The compile API currently exposes these preprocessing failures only as generic `ParseError`, so the expectations cannot distinguish them from another parse failure. `line` consumption is sampled by `19` but its remapped location is not observable in a successful Zig dump. |

Conditional compilation is split into `08`-`12`, including `ifdef`, `ifndef`,
`elsif`, `else`, nested conditions, `endif`, and `undef`. `20` verifies
`resetall` clears user macros. `18` verifies the built-in standard include;
arbitrary include-directory resolution belongs to the compile API rather than
a self-contained fixture. `19` covers `timescale`, `default_nettype`,
`celldefine`, `endcelldefine`, `pragma`, `line`, and
`nounconnected_drive` consumption. `20` and `23` likewise receive only the
generic `ParseError` exposed by the compile API for an undefined macro; their
expected-error files cannot yet assert the internal `UndefinedMacro` cause.

## Literal fixture inventory

Every fixture named below is part of this chapter's section mapping above.

- `01_default_discipline.va`
- `02_default_discipline_qualified.va`
- `03_default_transition.va`
- `04_define_object.va`
- `05_define_function.va`
- `06_define_multiline.va`
- `07_nested_macros.va`
- `08_undef_conditional.va`
- `09_ifdef_else.va`
- `10_ifndef.va`
- `11_elsif.va`
- `12_nested_conditionals.va`
- `13_predefined_vams_enable.va`
- `14_predefined_compact_modeling.va`
- `15_reserved_vams_macro_prefix.va`
- `16_begin_keywords_verilog.va`
- `17_begin_keywords_vams.va`
- `18_include_constants.va`
- `19_ignored_standard_directives.va`
- `20_resetall_clears_macro.va`
- `21_file_macro_unsupported.va`
- `22_line_macro_unsupported.va`
- `23_undefined_macro.va`
- `24_default_discipline_empty_reset.va`
- `25_begin_keywords_1364_1995.va`
- `26_begin_keywords_1364_2001.va`
- `27_begin_keywords_vams_2_3.va`
