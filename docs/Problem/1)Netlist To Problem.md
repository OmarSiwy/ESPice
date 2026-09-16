# Netlist to Problem

`Problem` owns a prepared circuit, its query graph, execution configuration,
retained results, and one output selection. Frontend code produces the prepared
data; analysis consumes that data without importing parsers or construction
policy.

```zig
const p = try problem.Problem.init(allocator, io, .{
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

The declarations are in [problem/root.zig](../../src/problem/root.zig).
Creation performs source/model preparation and graph validation. It does not
start a query, allocate its solver workspace, or write the output destination.
A deck with no analysis requests receives an operating-point query.

## Source and construction

`frontend.prepare(io, arena, source, dialect)` reads a file or copies supplied
bytes, expands SPICE includes and selected library sections, parses the chosen
dialect, and loads referenced HDL models. Byte input includes an `origin` real
or virtual filename; relative paths use its directory. Spectre uses its parser
without the SPICE include-expansion pass. Model registry bindings and loaded
code have process lifetime; multiple-file loading propagates errors.

`frontend.build(session_arena, parse_arena, ast)` resolves nodes,
parameters, source identities, initial conditions, probes, and query options.
It creates [Prepared](../../src/problem/types.zig), whose circuit contains
frozen CSC connectivity, per-type device batches, model/instance template
storage, gather/scatter bindings, and labels. It contains no solver workspace.

Device construction belongs to frontend. Model definitions live in `models/`;
VerA supplies their compiled representation. Shared device IR and ABI live in
[device_ir.zig](../../src/problem/device_ir.zig); numerical evaluation and GPU
launch policy live under `src/analysis/`. Analysis binds private mutable
instances from the prepared template when a query starts. Model compilation
and instance construction are distinct operations.

Preserve the GPU contract: `u32` connectivity/tape indices, Model/Instance POD
layouts, layout hashes, and `f64` numerical planes. Host callback pointers are
execution bindings, not a portable serialized circuit representation.

The [frontend file map and measurements](frontend.md) describe the tokenizer,
AST, elaboration and device-binding boundaries.

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
[output/types.zig](../../src/output/types.zig) owns this shared schema. Encoding
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
