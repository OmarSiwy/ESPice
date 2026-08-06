# ESPice

The terms ESPice's code, notes and reviews use, one word per concept. A term
here beats its synonyms in identifiers, comments and `dev/` notes.

## Input and preparation

**Deck**:
One SPICE input file and everything it includes: devices, models, parameters, analysis cards and options (`core.Deck` holds the non-circuit part).
_Avoid_: netlist file, input, circuit file

**Netlist**:
The parsed, expanded form of a deck before devices bind: the interned name pool, the node hypergraph (`csr`), parameter values and expressions (`frontend/netlist.zig`).
_Avoid_: AST, parse tree

**Card**:
One logical line of a deck after continuation joining: a device line, a dot-command (`.tran`), or a model line.
_Avoid_: statement, directive (except for `append_directives`, which takes card text)

**Dialect**:
The input language a deck is read as: ngspice, HSPICE or Spectre.
_Avoid_: flavour, mode

**Live value**:
A netlist parameter value that a variant point overrides without re-parsing (`Netlist.setLive`).
_Avoid_: override, patch

**Variant**:
One re-run of the same deck with changed live values: a `.step` point, a sweep point, an `.alter`, a Monte Carlo trial, an optimizer trial.
_Avoid_: run (a run is one built circuit), sample (only for Monte Carlo)

**Prepared**:
What the frontend hands on: `{ circuit: device.Circuit, deck: core.Deck }`.
_Avoid_: compiled netlist

**KNOWN GAP**:
A `* KNOWN GAP: <cause>` line in a fixture deck: the deck is expected to fail until the named feature lands, and the harness reports it XFAIL.
_Avoid_: skip, todo

## Devices

**Device type**:
One compiled device model (`DeviceType`, a dense id per Problem): built-in from `models/` or loaded from an `.hdl` deck.
_Avoid_: model kind, element type

**Model**:
A parameter set for one device type, from a `.model` card (the `Model` POD).
_Avoid_: model card when the parameters are meant, device

**Instance**:
One device in the circuit (`Instance` POD), bound to a model and to nodes.
_Avoid_: element, device (alone)

**Batch**:
All instances of one device type in a circuit, evaluated together through one function-pointer table (`abi.Batch`).
_Avoid_: group, bucket

**Unknown**:
One solution variable a device reads: a terminal voltage or an internal node or branch (`n_u` per device type).
_Avoid_: port, pin (a pin is a terminal)

**Plane**:
One dense `[]f64` the evaluation writes per pattern slot or per row: `g` (conductance), `c` (capacitance), `rhs`, `q` (charge).
_Avoid_: buffer, array

**Pattern**:
The circuit's fixed matrix sparsity in CSC (`col_ptr`, `row_idx`), frozen at preparation.
_Avoid_: structure, topology (topology is the node graph)

**Slot**:
An index into the pattern's nonzeros: where one Jacobian entry lands.
_Avoid_: nnz index, position

**Scatter tape**:
The per-batch `u32` tapes (`gath`, `rhs_idx`, `slots`) that route a device's local stamps to slots and rows. Frozen at the GPU boundary.
_Avoid_: stamp map, index list

**Limiting**:
Clamping a device's Newton update (pnjlim, fetlim and the model's own) before evaluation.
_Avoid_: damping (damping scales the whole update)

**Baseline**:
The constant-Jacobian contribution precomputed once into `g_base`/`c_base`, so Newton re-stamps only nonlinear batches.

## Solving

**Problem**:
One deck, prepared once, with its queries and results (`espice.Problem`); the C ABI handle.
_Avoid_: simulation, job

**Query**:
One analysis request with its parameters (`core.query.Query`); it runs on an executor and produces one result.
_Avoid_: job, task, analysis (alone)

**Session**:
The analysis-side scheduler for a Problem's queries and their prerequisites (`analysis.Session`).

**Executor**:
One query's mutable numerical state and the worker thread that runs it.

**Pivot tape**:
The recorded pivot order and fill of one full `SparseLu.factor`, replayed by `refactor` and by lane LUs.
_Avoid_: symbolic factorization, plan

**Refactor**:
Numeric LU with the pivot tape of an earlier factor; no pivot search.
_Avoid_: reuse, fast factor

**Lane**:
One of W independent instances in a SIMD kernel (a frequency point in `LaneLu(W)`, a derivative in `Dual`).
_Avoid_: channel, slot

**Peel**:
Rerunning a failed lane on the scalar path, whose full factor re-pivots.
_Avoid_: fallback (alone)

**Scalar oracle**:
The `W == 1` instantiation of a lane kernel, the reference every wider instantiation is tested against.

**Companion model**:
The linear stamp an integrator substitutes for a charge or flux at one timestep.

**LTE**:
Local truncation error, the estimate that bounds the next timestep (`integrator.stepBound`).

## Verification

**Fixture**:
A deck in `tests/fixtures/**` with its `.expected.json` (values and their provenance) or its input contract.
_Avoid_: test case (for decks), golden

**Verdict**:
A fixture's measured outcome: PASS, FAIL, XFAIL (fails under a KNOWN GAP) or XPASS (passes under one, which fails the run).

**Certificate**:
A cheap check of an expensive answer: a KCL residual of a converged point, a scaled LU residual, a Jacobian against finite differences.
