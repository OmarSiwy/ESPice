# Frontend pipeline

Netlist bytes in, passive `Prepared` circuit out. Four stages, three
intermediate types, each owned by one file.

| Stage | File | In | Out |
|---|---|---|---|
| expand | `source.zig` | bytes + origin path | bytes (`.include`/`.lib` inlined; spectre skips) |
| parse | `parser.zig` over `tokenizer.zig` | bytes | `Ast` (declarations, values unresolved) |
| elaborate | `elaborate.zig` | `Ast` | `Netlist` (params folded, subcircuits flattened, model bins picked, devices sorted by letter) |
| build | `prepare.zig` + `builder.zig` | `Netlist` | `Prepared` (frozen `Circuit`, probes, bindings, queries) |

`prepare` runs expand and parse and loads HDL models named by the `Ast`;
`build` runs elaborate and construction. Problem times the two separately.

Lifetimes: bytes, `Ast` and `Netlist` live in the parse arena and die after
`build`. Everything in `Prepared` lives in the session arena, except the
`Circuit` tables, which its own allocator owns.

`Netlist.devices` is AoS sorted by card letter with 27 bucket offsets: the
builder stamps letters in a fixed order (V, L, I, then the rest; F/H/W/K last
because they reference V and L cards), and every consumer reads a device's
name, nodes and values together.

`NetBuilder` keeps one `MultiArrayList` per card table (V, I, L, AC drives,
branch probes, AC resistances, topology nodes). Its rows are recorded before
the freeze, so they alone go through the BBD permutation. Directive nodes
(`.ic`, output `v(...)`, `.pz` ports) are resolved after the freeze, by
name, with the same code the appended-directive path (`resolveQueries`)
uses.
