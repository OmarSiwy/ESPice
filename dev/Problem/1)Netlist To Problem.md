# Netlist to Problem

`Problem` owns a prepared circuit, its query graph, execution configuration,
retained results, and one output selection. Frontend code produces the prepared
data; analysis consumes that data without importing parsers or construction
policy.

```zig
const espice = @import("espice");

const p = try espice.Problem.init(allocator, io, .{
    .source = .{ .file = "circuit.cir" },
    .dialect = .ngspice,
    .backend = .{ .backend = .cpu },
    .output = .{ .format = .binary, .path = "circuit.raw" },
    .max_parallel = 1,
});
defer p.deinit();
try p.print(writer, .{});
try p.run_all();
```

The declarations are in [espice.zig](../../src/espice.zig).
Creation performs source/model preparation and graph validation. It does not
start a query, allocate its solver workspace, or write the output destination.
A deck with no analysis requests receives an operating-point query.

## Source and construction

`frontend.prepare(io, &library, arena, source, dialect)` reads a file or
copies supplied bytes, expands SPICE includes and selected library sections,
parses the chosen dialect into a `Netlist`, and loads referenced HDL models
into the Problem's device `Library`. Byte input includes an `origin` real or
virtual filename; relative paths use its directory. Spectre uses its parser
without the SPICE include-expansion pass. The `Library` lives as long as the
Problem; loaded shared libraries are never unloaded, so their code has process
lifetime. Loading several files propagates the first error.

`frontend.build(&library, session_arena, parse_arena, netlist)` resolves
nodes, parameters, source identities, initial conditions, probes and query
options. It returns [`Prepared`](../../src/frontend/prepare.zig): a frozen
[`device.Circuit`](../../src/device/Circuit.zig) (CSC connectivity, per-type
device batches, model/instance template storage, gather/scatter bindings,
labels) and a [`core.Deck`](../../src/core/deck.zig). It contains no solver
workspace.

The frontend decides which device a card names and binds the card
(`spice.zig`, `builder.zig`). Model definitions live in `models/`; VerA
compiles them. The device ABI is [abi.zig](../../src/device/abi.zig),
evaluation is `src/device/eval.zig`, and GPU launch policy is
`src/analysis/gpu.zig`. Analysis binds private mutable instances from the
prepared template when a query starts. Model compilation and instance
construction are distinct operations.

Preserve the GPU contract: `u32` connectivity/tape indices, Model/Instance POD
layouts, layout hashes, and `f64` numerical planes. Host callback pointers are
execution bindings, not a portable serialized circuit representation.

The [frontend page](../frontend.md) describes line splitting, the netlist
tables, subcircuit flattening and device binding.

## Ownership

| Data | Owner and lifetime |
|---|---|
| Parser and construction scratch | Creation call; released after preparation |
| Expanded source, origin, prepared circuit and resolved name bindings | Problem session |
| Query descriptions and their copied slices | Accepted graph extension; retained until Problem destruction |
| Mutable device state, solver planes and temporary allocations | Analysis executor for that query |
| Completed results and accepted prerequisite state | Session; available to later appended queries |
| Output destination string and publication cursor | Output session; fixed at creation |
| Loaded model code and registry keys | Process model registry |

The full parsed netlist is not retained. Appending directives uses the stored
node/source/card/port bindings. It cannot change topology, model definitions,
initial conditions, or deck-wide options. Changing the circuit requires a new
Problem.

`QueryId` is an `enum(u32)`; `UINT32_MAX` is reserved as invalid. Appends preserve
existing IDs. Array sizes use checked host lengths. The graph stores columns
separately; names and descriptions remain outside numerical loops. Initial
conditions and parameter overrides are cold records consumed together.

## Fixed output

`output.Selection` contains a format and optional destination. A null path
retains numerical results without file output. Construction and append validate
requested output schemas before graph publication. Touchstone/CITI require
S-parameter queries; writer-specific dimensions and name limits are checked
before writing.

Analysis results are point-major `f64` arrays with names, point count, and a
real/complex flag. Complex values use adjacent real/imaginary scalars.
[core/result.zig](../../src/core/result.zig) owns this shared schema;
`output` re-exports it. Encoding
does not change numerical algorithms.

The output session publishes whole completed plots in request order. Binary raw
plots append to one file; other formats use the destination, then `.2`, `.3`,
and so on. Results remain readable if output fails. Finishing current delivery
does not close the Problem: later appended queries can publish more results.
See [module APIs](<4)Module APIs and main.md>) for failure and resource ownership.

## C ABI

`zig build` installs the static `libespice` library and
[espice.h](../../include/espice.h). The simulator ABI is separate from the
model-plugin ABI. Version 1 uses an opaque `espice_problem`, explicit integer
tags, sized buffers, and `espice_create_options.struct_size`.

Start with `espice_default_options`, then `espice_create`, `espice_run_all`,
result-copy functions, and `espice_destroy`. Advanced consumers can append
analysis directives, inspect query information, advance one query or a ready
set, and copy a tree preview. These functions delegate to the same Problem
implementation as Zig and the CLI.

Input bytes are copied during create/append. Result pointers do not escape the
ABI. Copy functions return the required capacity without partial writes;
string capacities include the trailing NUL. A sizing call to append does not
modify the graph. Creation returns a diagnostic buffer on failure; query error
messages and the last operation error remain separately accessible.

Serialize all calls on one C handle, including reads and destruction. Parallel
execution happens inside `advance_ready`/`run_all`; separate handles are
independent. Destruction cancels and joins workers before releasing their data.
