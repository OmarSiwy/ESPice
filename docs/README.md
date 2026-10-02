# ESPice documentation

ESPice prepares a circuit `Problem`, executes analysis queries against it, and
encodes completed results using the output selection fixed at creation.

```text
Source → frontend → Prepared circuit + query descriptions
                            ↓
                      Problem API / C ABI
                            ↓
                   analysis + private solvers
                            ↓
                   numerical results → output
```

## Contracts

1. [Problem creation and C ABI](<Problem/1)Netlist To Problem.md>): source and
   model preparation, circuit/device IR, ownership, and foreign-language access.
2. [Analysis queries](<Problem/2)Analysis Queries.md>): prerequisites,
   advancement, completion, failures, and retained results.
3. [Parallel execution](<Problem/3)Parallel Query Execution.md>): ready sets,
   independent state, CPU/GPU lanes, and tree previews.
4. [Module APIs and main](<Problem/4)Module APIs and main.md>): the concrete
   producer/consumer seams and CLI orchestration.

[Migration notes](Problem/migration-notes.md) record deliberate limitations,
retired paths and their replacements.

## Pages by area

| Area | Pages |
|---|---|
| Frontend | [frontend.md](frontend.md): netlist bytes to `Prepared`, stage by stage, with measurements; [preparation performance](Problem/preparation-performance.md) |
| Devices | [devices/models.md](devices/models.md): attribution, licensing and ngspice-conformance fixes per model; [devices/abi.md](devices/abi.md): the device ABI and its identity rules; [devices/iteration-lifecycle.md](devices/iteration-lifecycle.md): Verilog-AMS iteration hooks; [devices/gpu-evaluation.md](devices/gpu-evaluation.md): device planes on the GPU, the wait schedule and the `auto` cost model; [devices/verilog-digital.md](devices/verilog-digital.md): `.v` digital devices, A2D/D2A and the `ttol` cost; [devices/w-s-elements.md](devices/w-s-elements.md): HSPICE W and S elements, their rational fits and accuracy |
| Analyses | [analysis/](analysis/README.md): one page per analysis |
| Solvers | [solvers/](solvers/README.md): sparse LU, ordering, Newton, continuation, measured performance |
| Conformance | [conformance-phase2.md](conformance-phase2.md): root causes and fix recipes behind `issues.md` section F; [verilog-ams-conformance-plan.md](verilog-ams-conformance-plan.md): the Verilog-AMS audit checklist |
| Transmission lines | [vera-gaps.md](vera-gaps.md): what VerA still needs before the native lines move to Verilog-A; [native-transmission-line-migration.md](native-transmission-line-migration.md): the migration audit |
| Plans | [plan/optimize.md](plan/optimize.md): open work streams; [plan/vacask-comparison.md](plan/vacask-comparison.md): feature and speed comparison with VACASK, ranked gaps |

Model sources live in `models/`. Shared data lives in `src/core/`, devices
and HDL loading in `src/device/`, construction in `src/frontend/`, execution
in `src/analysis/`, encoding in `src/output/`, and the owning API in
`src/espice.zig`. Solvers under `src/solver/` are private to analysis.

## Writing docs that last

Lead with the transformation: inputs, outputs, owner, permitted mutations,
and lifetime. Describe devices through their IR and evaluation contract;
individual device equations do not define the architecture.

Analysis pages explain the mathematical question, prerequisites, algorithm,
output layout, failure conditions and supported limits. Solver pages describe
internal numerical systems, workspace ownership and fallbacks. Output pages
describe dimensions, labels, encodings and delivery lifetime. Keep each
contract in one place and link to it.

State an approximation or unsupported case beside the claim it affects, and
keep research targets apart from implemented behavior. Describe CPU/GPU
participation per operation: the GPU evaluates device planes, and every
solve runs on the host. Registration in a dispatch table does not establish
SPICE conformance.

Describe the code as it is. A divergence from ngspice or VACASK, or a
retired experiment, is recorded on the topical page with its measurements
and fallback (the proof rule in `AGENTS.md`). Session handoffs and branch
logs do not belong here: fold what lasts into the topical page and delete
the rest.
