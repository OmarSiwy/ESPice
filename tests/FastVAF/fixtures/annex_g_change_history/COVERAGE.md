# Annex G coverage

Source: `modules/FastVAF/docs/annex-g-changes.html`. This annex is
informative. Its revision tables point to normative rules tested in their
own chapter folders; they do not create duplicate language rules.

| Documentation id | Coverage |
|---|---|
| `sG-1` | Revision-history tables are non-normative. Representative transitions are isolated in `01_abstime_replaced_realtime.va`, `02_2023_math_additions.va`, and `03_system_math_style.va`. `08_new_receiver_count.va` is only a nonconforming acceptance snapshot: `$receiver_count` is valid in a connectmodule, not the ordinary module used by that fixture. Normative features, including dynamic event tolerances, remain mapped by their chapter `COVERAGE.md` files. |
| `sG-2` | Obsolete-functionality boundary: `04`-`07`. |
| `sG-2-1` | Obsolete `forever`: `04_obsolete_forever.va`. Its successful dump deliberately records FastVAF's current failure to reject the obsolete identifier form. |
| `sG-2-2` | `05_null_statement_scope.va` mixes an invalid unconditional null (currently accepted) with a valid conditional null. Its successful dump freezes the gap but does not isolate the two outcomes. |
| `sG-2-3` | Obsolete Verilog-A `generate i(start,end,incr)` syntax must fail: `06_obsolete_generate.va`. Modern `generate`/`genvar` belongs to Chapter 6. |
| `sG-2-4` | Obsolete ``default_function_type_analog` directive must fail: `07_obsolete_default_function_type.va`. The compile API reports only generic `ParseError` for the unknown directive, so this expectation cannot yet assert a more specific cause. |

The expected dumps preserve observed implementation behavior; the normative
status comes from the current LRM chapters, never from this historical annex.

## Literal fixture inventory

Every fixture named below is part of this chapter's section mapping above.

- `01_abstime_replaced_realtime.va`
- `02_2023_math_additions.va`
- `03_system_math_style.va`
- `04_obsolete_forever.va`
- `05_null_statement_scope.va`
- `06_obsolete_generate.va`
- `07_obsolete_default_function_type.va`
- `08_new_receiver_count.va`
