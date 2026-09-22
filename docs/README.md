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

The four contracts are:

1. [Problem creation and C ABI](<Problem/1)Netlist To Problem.md>): source and
   model preparation, circuit/device IR, ownership, and foreign-language access.
2. [Analysis queries](<Problem/2)Analysis Queries.md>): prerequisites,
   advancement, completion, failures, and retained results.
3. [Parallel execution](<Problem/3)Parallel Query Execution.md>): ready sets,
   independent state, CPU/GPU lanes, and tree previews.
4. [Module APIs and main](<Problem/4)Module APIs and main.md>): the concrete
   producer/consumer seams and CLI orchestration.

Model sources live in `models/`. Construction lives in `src/frontend/`, the
owning API in `src/problem/`, execution in `src/analysis/`, and encoding in
`src/output/`. Solvers under `src/analysis/solvers/` are private to analysis.
[Migration notes](Problem/migration-notes.md) record deliberate limitations,
retired paths, and their replacements.

## Writing accurate long-term docs

Lead with the transformation: inputs, outputs, owner, permitted mutations,
and lifetime. Describe devices through their IR and evaluation contract here;
individual device equations do not define the architecture.

Analysis pages should explain the mathematical question, prerequisites,
algorithm, output layout, failure conditions, and supported limits. Solver
pages describe internal numerical systems, workspace ownership and fallbacks.
Output pages describe dimensions, labels, encodings and delivery lifetime.
Keep each contract in one authoritative place and link to it.

The existing [analysis](analysis/README.md) and [solver](solvers/README.md)
pages contain theory and historical implementation notes. Their status labels
need individual verification against code and fixtures; registration in a
dispatch table does not establish complete SPICE conformance. These references
remain in their existing documentation directories during that audit.

State an approximation or unsupported case beside the affected claim. Keep
research targets separate from implemented behavior. Describe CPU/GPU
participation per operation: shared mathematics does not establish complete
device residency. Performance claims require measured before/after evidence.
