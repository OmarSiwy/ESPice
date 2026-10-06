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
everything, including result views.

## Conventions

**Status codes.** Every call returns an `espice_status`:

| Status | Meaning |
|---|---|
| `ESPICE_OK` | success |
| `ESPICE_INVALID_ARGUMENT` | a bad pointer, tag or option, or malformed analysis text |
| `ESPICE_BUFFER_TOO_SMALL` | the buffer is too short; `required` says how long it must be |
| `ESPICE_OUT_OF_MEMORY` | |
| `ESPICE_INVALID_QUERY` | an ID outside the problem |
| `ESPICE_RESULT_UNAVAILABLE` | the query has not completed |
| `ESPICE_FAILED` | a numerical or I/O failure |
| `ESPICE_ABI_MISMATCH` | the header and the library disagree (`abi_version`, `struct_size`) |

`espice_error_message` returns the last failing call's error name;
`espice_query_error_message` a failed query's own.

**Buffers.** Calls that copy out take `(buffer, capacity, &required)`. On
`ESPICE_OK` or `ESPICE_BUFFER_TOO_SMALL` they set `required` (strings
count the trailing NUL) and write nothing partial. To size a buffer, call
once with capacity 0, allocate `required`, call again. NULL is allowed
only with capacity 0.

**Threads.** Calls on one handle must not overlap, reads and destroy
included. Different handles are independent. Parallelism happens inside
`espice_run_all` and `espice_advance_ready`.

**ABI.** `ESPICE_ABI_VERSION` (1) must match `espice_abi_version()` and
the `abi_version` in the options; a mismatch is `ESPICE_ABI_MISMATCH`.
