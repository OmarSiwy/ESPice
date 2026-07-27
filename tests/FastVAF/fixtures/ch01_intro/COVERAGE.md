# Chapter 1 coverage

Source: `docs/ch1-intro.html`, read section by section.

HTML section-ID audit: `s1-1` `s1-2` `s1-3` `s1-3-1` `s1-3-1-1` `s1-3-1-2` `s1-3-2` `s1-3-3` `s1-3-4` `s1-3-4-1` `s1-3-4-2` `s1-3-5` `s1-4` `s1-5`.

| LRM section/rule | Fixture or disposition |
|---|---|
| 1.1 behavioral continuous component | `01_conservative_resistor.va` |
| 1.2 analog potentials/flows receive contributions only in an analog block | every behavioral fixture in this folder places `<+` only in `analog`; mixed digital semantics belong to Chapter 7 |
| 1.3 components, nets, ports, and nodes | every fixture declares ports and disciplined nets |
| 1.3.1 conservative nodes have potential and flow; branch constitutive equation | `01_conservative_resistor.va`, `03_named_branch.va`, `05_potential_and_flow.va` |
| 1.3.1.1 continuous ground is the zero-potential reference | `02_reference_ground.va` |
| 1.3.1.2 associated A-to-B potential/flow reference direction | `03_named_branch.va` names `(a,b)` and probes/contributes to that same branch |
| 1.3.2 additive KFL contributions and KPL potential differences | `04_kirchhoff_flow_sum.va`; topology-dependent numerical conservation is a simulator/runtime property, not a source-to-Zig structural golden |
| 1.3.3 disciplines and access functions | the standard `electrical` discipline and `V`/`I` accesses are exercised throughout; custom nature declarations are covered in `ch03_data_types` |
| 1.3.4 potential-only and flow-only signal-flow disciplines | `11_potential_signal_flow.va` and `12_flow_signal_flow.va` directly declare the single-nature disciplines, directional ports, access probes, and matching sources; generated compile-error pairs pin the current custom-access ABI boundary |
| 1.3.5 freely mixing conservative and signal-flow descriptions | `13_mixed_conservative_signal_flow.va` directly mixes potential-only and conservative ports/equations; `14_signal_flow_illegal_quantity.va` independently rejects use of the undeclared flow quantity |
| 1.4 BNF notation conventions | documentation convention, with executable productions covered by `annex_a_syntax` |
| 1.5 document contents | index only; no language rule to execute |

Atomic expansion inventory: `06_voltage_source.va` (potential source), `07_current_source.va` (flow source), `08_series_potentials.va` (KPL-oriented series branches), `09_potential_probe.va` (potential signal flow), and `10_flow_probe.va` (named-branch flow probe). These split the source/probe concepts of `s1-3-1`, `s1-3-1-2`, `s1-3-2`, `s1-3-4-1`, and `s1-3-4-2` into independently diffable Zig dumps.

## Signal-flow completion

- `11_potential_signal_flow.va` uses an actual potential-only discipline, `input`/`output` ports, its declared access function, and a potential source.
- `12_flow_signal_flow.va` uses an actual flow-only discipline, `input`/`output` ports, its declared access function, and a flow source.
- `13_mixed_conservative_signal_flow.va` mixes a potential-only signal-flow port with a conservative electrical port in one behavioral model; its generated-code failure records FastVAF's present custom-access ABI boundary.
- `14_signal_flow_illegal_quantity.va` snapshots rejection of attempting a flow contribution on a potential-only signal-flow discipline, covering 1.3.5's declared-quantity rule.
