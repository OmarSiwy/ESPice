# The C API

ESPice is also a library. `include/espice.h` is its C interface, and
`zig build` installs it with the static library:

```text
zig-out/include/espice.h
zig-out/lib/libespice.a
```

The release tarballs carry the same two files. Everything below is in the
header; this page explains how the calls fit together.

## A minimal host

This program simulates an RC low-pass from netlist text and prints the AC
magnitude at `v(out)`. It is `docs/embed/host.c` in the repository, and
`zig build c-example` compiles and runs it on every docs build, so it
stays in step with the header.

```c
--8<-- "embed/host.c"
```

Build it against an installed ESPice with `zig cc`, or with GCC, which
needs the math and thread libraries named:

```sh
zig cc host.c -I zig-out/include zig-out/lib/libespice.a -lc -o host
gcc host.c -I zig-out/include zig-out/lib/libespice.a -lc -lm -lpthread -o host
./host
```

```text
        10 Hz  |v(out)| = 1.0000
       100 Hz  |v(out)| = 0.9950
      1000 Hz  |v(out)| = 0.7075
     10000 Hz  |v(out)| = 0.0996
    100000 Hz  |v(out)| = 0.0100
```

## The Problem lifecycle

```text
espice_default_options → espice_create → [espice_print] → espice_run_all or espice_advance… → results → espice_destroy
```

**Create.** `espice_default_options` fills an `espice_create_options` with
defaults (including `abi_version`, `struct_size` and `max_parallel = 1`).
Set what you need, then call `espice_create`:

| Field | Values |
|---|---|
| `source_kind` | `ESPICE_FILE`: `source` is a path. `ESPICE_BYTES`: `source` is netlist text |
| `source`, `origin` | the path or text; `origin` names the file relative includes resolve against |
| `dialect` | `ESPICE_NGSPICE`, `ESPICE_HSPICE`, `ESPICE_SPECTRE` |
| `backend`, `explicit_gpu` | `ESPICE_CPU`, `ESPICE_AUTO`, `ESPICE_CUDA`, `ESPICE_HIP`; `explicit_gpu = 1` is the CLI's `--gpu` |
| `output_format`, `output_path` | write results to a file as the CLI's `--format` and `--rawfile` do; an empty path writes nothing |
| `max_parallel` | queries that may run at once, as `--jobs` |
| `zig_path`, `share_path` | for decks that load `.hdl` models: the Zig compiler, and the `share/espice` directory of evaluator sources, inside your own bundle. Empty keeps `$ZIG` (else `zig` on `PATH`) and the `share/espice` beside the executable. A `share_path` without `device/eval.zig` fails with `HdlShareNotFound` |
| `live_params`, `live_param_count` | the global `.param` names `espice_set_params` may change later (see [Sizing loops](#sizing-loops)). A name no `.param` defines fails with `UnknownParameter` |
| `display`, `display_user` | a callback `void (*)(const char *text, size_t len, void *user)` that receives `.hdl` display-task text instead of stdout (see **Output** below); NULL prints on stdout |

`espice_create` parses the deck, builds the circuit and plans the queries.
On failure it returns a status, leaves `*out` NULL and writes the error
name (`ParseError`, `FileNotFound`, ...) into `diagnostic`. The source is
copied, so your buffer can go away once the call returns.

**Queries.** Each analysis card becomes a query, and ESPice adds the
prerequisites they need (a transient's operating point, say). Queries
form a DAG. `espice_query_count` and `espice_get_query_info` describe each
one:

| `espice_query_info` field | Meaning |
|---|---|
| `id` | 0 to count − 1; stable across appends |
| `kind` | `ESPICE_OP`, `ESPICE_AC`, `ESPICE_TRAN`, ... (one per analysis) |
| `status` | `ESPICE_PENDING`, `PAUSED`, `COMPLETE`, `QUERY_FAILED`, `DEPENDENCY_FAILED`, `CANCELLED` |
| `dependency` | the query it waits on, or `ESPICE_NO_QUERY` |
| `requested` | 1 for a card in the deck, 0 for an added prerequisite |
| `component` | the connected component of the DAG it belongs to |
| `progress`, `has_progress` | phase and completed/total work, when known |
| `failure_code` | the numerical failure of a failed query |

`espice_print` renders the DAG as text, like `espice --plan`, without
running anything.

**Run.** `espice_run_all` runs every query to completion, using up to
`max_parallel` threads across independent queries, and writes the output
file if you asked for one. It returns the first query failure.

To drive the schedule yourself, step instead:

- `espice_ready_queries(p, scope, ids, cap, &required)` lists the queries
  that can advance now, in a scope (`ESPICE_ALL`, one query and its
  prerequisites with `ESPICE_QUERY`, or one `ESPICE_COMPONENT`).
- `espice_advance(p, id, &event)` runs one quantum of `id`, or of its
  first unfinished prerequisite, and returns. The event says which query
  advanced, its status, its progress and any output error. A long query
  comes back `ESPICE_PAUSED` between quanta, so a host can show progress
  or cancel by destroying the problem.
- `espice_advance_ready(p, ids, n, max_parallel, events, cap, &required)`
  advances a whole frontier at once, one event per query.

**Append.** `espice_append_directives` adds analysis cards
(`".ac dec 10 1 1meg\n"`) to an existing problem without rebuilding the
circuit, and returns the new query IDs. It is transactional: a bad card
adds nothing. Device cards are refused.

**Change parameters.** `espice_set_params` gives global `.param` values
new values for the queries appended after it; see [Sizing loops](#sizing-loops).

**Results.** Once a query is complete:

- `espice_get_result_info` gives `variable_count`, `point_count`,
  `is_complex` and `value_count`.
- `espice_copy_result` copies the values; `espice_result_view` hands out a
  read-only pointer to them, valid until `espice_destroy`. Data is
  point-major: row `i` is `variable_count` values (twice that for complex
  results, as adjacent real and imaginary parts). Column 0 is the
  independent variable where the plot has one.
- `espice_copy_result_name(p, id, v, ...)` gives column `v`'s name
  (`v(out)`), or the plot title with `ESPICE_PLOT_TITLE`.

**Destroy.** `espice_destroy` cancels and joins any paused work and frees
everything, including result views. Afterwards the handle is dead: every
call on it, a second `espice_destroy` included, returns
`ESPICE_INVALID_HANDLE` and does nothing, even after a later
`espice_create` reuses its slot. `espice_destroy(NULL)` is a no-op that
returns `ESPICE_OK`.

## Sizing loops

A sizing or centering loop changes a few `.param` values and runs the
same analyses again, hundreds of times. Re-creating the problem for each
point re-reads the whole deck, which with a PDK like sky130 is most of
the run. Instead, name the parameters you will change when you create
the problem, then set them on the live one:

```c
const espice_bytes live[] = {{"wn", 2}, {"wp", 2}};
options.live_params = live;
options.live_param_count = 2;
espice_create(&options, &p, diagnostic, sizeof diagnostic);

const char *cards = ".op\n.ac dec 10 1 1g\n";
for (int i = 0; i < n; i++) {
    double values[2] = {wn[i], wp[i]};
    espice_set_params(p, live, values, 2);
    espice_append_directives(p, (espice_bytes){cards, strlen(cards)}, ids, 2, &required);
    espice_run_all(p);
    /* read ids[0], ids[1] */
}
```

`espice_set_params(p, names, values, count)` sets each name for every
query appended afterwards; names you leave out keep their last values,
and queries appended earlier keep the values they were appended with, so
their results stay valid. Append the analyses again after each call.
Their plots are named after the point, `Operating Point (wn=1, wp=2)`.
Names match case-insensitively, except in the Spectre dialect.

Nothing is parsed again. The point is evaluated from the prepared deck as a
`.step` point is: usually a handful of parameter writes, sometimes a rebuild
of the circuit from the prepared netlist. A binned MOSFET (sky130's
`sky130_fd_pr__nfet_01v8`, say) whose L or W moves takes the bin the new
size selects. Sizing a sky130 OTA's input pair this way, an `.op` point
costs about 6 ms against about 87 ms for re-creating the problem.

The call is all-or-nothing. `ESPICE_INVALID_ARGUMENT` means a name not in
`live_params` or a value that is not finite. `ESPICE_FAILED` means no model
bin holds the new size (`ModelBinNotFound`), or the values would change
the circuit's topology or flip a top-level `.if` (`UnsupportedCard`). A
parameter an analysis card, `.meas`, `.ic` or `.options` reads cannot be
live: `espice_create` refuses it with `UnsupportedCard`, as `.step` does.

Each call keeps one variant row (and, after a bin change, one circuit)
until `espice_destroy`.

From Zig the same calls are `Options.live_params` and
`Problem.set_params(names, values)`.

## Conventions

**Status codes.** Every call returns an `espice_status`:

| Status | Meaning |
|---|---|
| `ESPICE_OK` | success |
| `ESPICE_INVALID_ARGUMENT` | a bad pointer (a NULL problem included), tag or option, or malformed analysis text |
| `ESPICE_BUFFER_TOO_SMALL` | the buffer is too short; `required` says how long it must be |
| `ESPICE_OUT_OF_MEMORY` | allocation failed, or `espice_create` with 4095 problems already live (`TooManyProblems`) |
| `ESPICE_INVALID_QUERY` | an ID outside the problem |
| `ESPICE_RESULT_UNAVAILABLE` | the query has not completed |
| `ESPICE_FAILED` | a numerical or I/O failure |
| `ESPICE_ABI_MISMATCH` | the header and the library disagree (`abi_version`, `struct_size`) |
| `ESPICE_INVALID_HANDLE` | the problem was destroyed, or the value never came from `espice_create` |

`espice_error_message` returns the last failing call's error name;
`espice_query_error_message` a failed query's own. An advance event's
`output_error` uses the same codes; `ESPICE_INVALID_QUERY` or
`ESPICE_RESULT_UNAVAILABLE` there means ESPice's own query bookkeeping
broke, which is a bug worth reporting.

**Buffers.** Calls that copy out take `(buffer, capacity, &required)`. On
`ESPICE_OK` or `ESPICE_BUFFER_TOO_SMALL` they set `required` (strings
count the trailing NUL) and write nothing partial. To size a buffer, call
once with capacity 0, allocate `required`, call again. NULL is allowed
only with capacity 0.

**Threads.** Calls on one handle must not overlap, reads and destroy
included. Different handles are independent, and calls on them may run
on any threads at once. A handle is a generation-checked token into one
process-wide table, not an address; each call checks it under a lock that
guards a few loads, so the check costs nothing next to a simulation. A
value that never came from `espice_create` is rejected unless its bits
happen to match a live handle's. Parallelism happens inside
`espice_run_all` and `espice_advance_ready`.

**Output.** A `.hdl` model's display-task lines (`$strobe`, `$display`
and the rest; see [Verilog-A](../using/devices.md#your-own-verilog-a))
go to the process's standard output, unbuffered, unless you set the
`display` callback. It gets each accepted point's lines in one call
(`text` is not NUL-terminated) from the thread running the query, so with
`max_parallel` above 1 calls can overlap. It must not call back into the
same handle. From Zig, `Options.display` takes a `*std.Io.Writer`.

**ABI.** `ESPICE_ABI_VERSION` (1) must match `espice_abi_version()` and
the `abi_version` in the options; a mismatch is `ESPICE_ABI_MISMATCH`.
