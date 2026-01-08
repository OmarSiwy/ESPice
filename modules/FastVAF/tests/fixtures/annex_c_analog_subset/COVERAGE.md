# Annex C coverage

Source: `docs/annex-c-veriloga.html`, read in full.

HTML section-ID audit: `sC-1` `sC-2` `sC-3` `sC-4` `sC-5` `sC-6` `sC-7` `sC-8` `sC-9` `sC-10` `sC-11` `sC-12` `sC-13` `sC-14` `sC-15` `sC-16` `sC-17` `sC-18` `sC-19` `sC-20`.

| Annex section/rule | Fixture or disposition |
|---|---|
| C.1 analog-only conservative behavioral module | `01_analog_only_device.va` |
| C.2 analog blocks, named branches, ranges, operators, filters/events | `01_analog_only_device.va`–`05_analog_event.va`; individual families are exhaustive in Chapters 3–5 |
| C.3 lexical rules; x/z/? restricted to mixed-signal contexts | Chapter 2 plus `06_xz_rejected.va` |
| C.4 Clause 3 applies; discrete domains, wreal, default_discipline excluded | allowed data rules are in Chapter 3; `07_discrete_discipline_current_behavior.va`, `08_wreal_current_behavior.va`, and `09_default_discipline_current_behavior.va` snapshot the three missing exclusion diagnostics |
| C.5 case equality excluded | `10_case_equality_current_behavior.va` and `17_case_inequality.va` independently expose current acceptance of `===` and `!==` and the missing Verilog-A semantic diagnostics |
| C.6 analog signals require disciplined nets | `01_analog_only_device.va`, `02_named_branch.va`; `18_no_discipline_analog_net.va` snapshots the current missing-discipline acceptance gap |
| C.7 analog behavior; digital behavior/events/casex/casez excluded | `05_analog_event.va` is an analog event; `11_casex_rejected.va`, `12_casez_rejected.va`, `13_digital_initial_rejected.va`, `14_digital_always_rejected.va`, and `19_digital_event_trigger.va` record exclusions/current diagnostics |
| C.8 hierarchy applies except real-value ports | hierarchy is deliberately rejected by Annex A's instantiation fixture; `15_real_value_port_rejected.va` records the real-port parser rejection |
| C.9 mixed signal excluded | no mixed-signal valid fixture |
| C.10 analog scheduling only | analog initial/cross event in `05_analog_event.va`; scheduling is runtime behavior |
| C.11 analog-context tasks/functions | Chapter 9 fixtures |
| C.12 directives | Chapter 10 fixtures |
| C.13–C.14 VPI | Chapters 11–12 coverage; no static source syntax beyond calls/tasks |
| C.15 Annex A BNF relationship | `annex_a_syntax` |
| C.16 `connect connectmodule connectrules driver_update endconnectrules merged resolveto split wreal` unused but all AMS words reserved | `16_unused_ams_words_current_behavior.va` snapshots the current reservation gap; Annex B inventories the complete keyword set |
| C.17 standard definitions except discrete disciplines | Annex D fixtures; discrete definitions are to be ignored |
| C.18 SPICE compatibility | Annex E fixtures |
| C.19 changes | Annex G coverage |
| C.20 obsolete functionality | Annex G coverage; no valid current-language fixture |

Fixture-name audit: `01_analog_only_device.va`, `02_named_branch.va`, `03_parameter_range.va`, `04_analog_operators.va`, `05_analog_event.va`, `06_xz_rejected.va`, `07_discrete_discipline_current_behavior.va`, `08_wreal_current_behavior.va`, `09_default_discipline_current_behavior.va`, `10_case_equality_current_behavior.va`, `11_casex_rejected.va`, `12_casez_rejected.va`, `13_digital_initial_rejected.va`, `14_digital_always_rejected.va`, `15_real_value_port_rejected.va`, and `16_unused_ams_words_current_behavior.va` are all mapped above.

## Subset boundary completion

- `17_case_inequality.va` covers the Annex C permitted `!==` operator independently of `===`.
- `18_no_discipline_analog_net.va` exercises an analog behavioral port with no discipline declaration and snapshots FastVAF's current implicit-electrical acceptance gap.
- `19_digital_event_trigger.va` contains both a digital event declaration and `->` trigger inside an otherwise analog module and pins the Annex C rejection boundary.
