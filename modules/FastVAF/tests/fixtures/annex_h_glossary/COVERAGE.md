# Annex H coverage

Source: `modules/FastVAF/docs/annex-h-glossary.html`. The glossary is
informative, so definitions are demonstrated with compact representative
models rather than treated as independent grammar productions.

| Documentation id | Terms and fixtures |
|---|---|
| `glossary-a` | AMS / Verilog-AMS cross-reference: informative; all fixtures are analog subset examples. |
| `glossary-b` | Behavioral description/model: `01_behavioral_description.va`, `02_behavioral_model.va`; block and branch: `03_block_control_flow.va`, `04_branch_flow_potential.va`. |
| `glossary-c` | Compact model/component/constitutive relationship/control flow: `01`-`05`. No fixture instantiates a child module; child-module elaboration is outside a single generated device dump. |
| `glossary-f` | Flow quantity: `04_branch_flow_potential.va`. |
| `glossary-i` | Instance/instantiation are elaboration concepts and are not represented by `05_module_parameter.va`, which is only a parameterized module definition. FastVAF compiles the selected device definition, not a hierarchy. |
| `glossary-k` | Kirchhoff laws are solver equations induced by the contribution in `04_branch_flow_potential.va`; numerical KCL/KVL is outside syntax testing. |
| `glossary-l` | Behavioral level/named block: `03_block_control_flow.va`. |
| `glossary-m` | Model and module: parameterized modules `02_behavioral_model.va`, `05_module_parameter.va`. |
| `glossary-n` | Net declaration/node: `06_node_port_terminal.va`; Newton-Raphson relationship: nonlinear residual `09_nonlinear_nr_relationship.va`. |
| `glossary-p` | Parameter/declaration: `05`; port/potential: `06`; primitive is simulator-defined and non-source here; probe: `07_probe.va`. |
| `glossary-r` | Reference direction: oriented branch `04`; reference node/ground: `08_reference_node.va`. |
| `glossary-s` | Scope: named block `03`; no fixture contains a structural child instantiation, because hierarchy elaboration is non-codegen for a selected FastVAF device. |
| `glossary-t` | Terminal/port: `06_node_port_terminal.va`. |
| `glossary-v` | Verilog-A and Verilog-AMS definitions are informative language-scope terms; the fixtures use the Verilog-A subset compiled by FastVAF. |

## Literal fixture inventory

Every fixture named below is part of this chapter's section mapping above.

- `01_behavioral_description.va`
- `02_behavioral_model.va`
- `03_block_control_flow.va`
- `04_branch_flow_potential.va`
- `05_module_parameter.va`
- `06_node_port_terminal.va`
- `07_probe.va`
- `08_reference_node.va`
- `09_nonlinear_nr_relationship.va`
