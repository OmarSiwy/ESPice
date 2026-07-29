# Command line

```text
espice [OPTION]... FILE...
```

Each `FILE` is a netlist. ESPice reads it, runs every analysis it asks for,
prints the `.meas` results on stdout and a one-line summary per result on
stderr, and writes the results if you name an output file. Several files
run one after another, each as its own independent problem.

`espice --help` prints:

```text
Usage: espice [OPTION]... FILE...
  -b, --batch                 Run all queries (default)
  -r, --rawfile=FILE          Result destination
      --format=FMT            binary|ascii|csv|touchstone|psf|fsdb|sst2|citi|print
      --backend=BE            cpu|auto|cuda|hip (default cpu)
      --gpu                   Require an available GPU
      --jobs=N                Maximum parallel queries (default 1)
      --print-dag             Print the next query frontier before running
      --plan                  Print the DAG without running analyses
      --timing-in-depth       Time preparation, queries, and individual steps
      --tokenizer=FMT         ngspice|hspice|spectre
  -v, --version               Version
```

A flag that takes a value accepts it three ways: `--rawfile=out.raw`,
`--rawfile out.raw`, or the short form `-r out.raw`. An empty value
(`--rawfile=`) is a usage error.

## Options

`-r FILE`, `--rawfile=FILE`
: Where to write the results. Without it nothing is written to disk: the
  summary and the `.meas` results are the only output. With it, the first
  result goes to `FILE`. In the binary, ASCII and print formats every
  later result is appended to the same file, as ngspice does; in the other
  formats result *n* goes to `FILE.n` (`out.csv`, `out.csv.2`,
  `out.csv.3`, ...). The file is replaced atomically, so it holds either
  the old contents or the complete new result. See [Output](output.md).

`--format=FMT`
: The output format, default `binary`. Names and aliases: `binary` (`raw`),
  `ascii`, `csv`, `print` (`text`), `touchstone` (`snp`, `s2p`), `citi`
  (`citifile`), `psf`, `fsdb`, `sst2` (`hspice`). An unknown name is a usage
  error.

`--tokenizer=FMT`
: The netlist dialect: `ngspice` (default, alias `ng`), `hspice` (`hs`) or
  `spectre` (`scs`). The single-dash spelling `-tokenizer=hspice` works
  too. See [Dialects](dialects.md).

`--backend=BE`
: Where device models are evaluated: `cpu` (default), `auto`, `cuda` or
  `hip`. `auto` uses a GPU when one is present and the circuit is worth it,
  and falls back to the CPU otherwise. `cuda` and `hip` fail rather than
  fall back. See [GPU backend](gpu.md).

`--gpu`
: The same as `--backend=auto`, except that a machine with no usable GPU
  is an error instead of a fallback.

`--jobs=N`
: Run up to N analyses at once (default 1, must be at least 1). Analyses
  form a dependency graph: an `.ac` needs the operating point, a `.noise`
  can share it. Independent analyses run in parallel.

`--plan`
: Print the query graph and exit without simulating:

    ```text
    $ espice --plan rc_lowpass.sp
    Problem: 3 requested queries, 4 total queries, 2 components
    ├── Component 0
    │   ├── q0 op [ready; NEXT]
    │   └── q1 ac [pending; waiting for q0]
    │       └── ↪ q0 op [ready; shared; NEXT]
    └── Component 2
        └── q3 tran [pending; waiting for q2]
            └── q2 op [ready; deferred by selection]
    ```

    The deck asked for three analyses (`.op`, `.ac`, `.tran`); ESPice adds
    a fourth, the transient's own operating point. The `.ac` reuses the
    `.op` result. `NEXT` marks what would run first.

`--print-dag`
: Print the same graph, then run. With `--jobs=2` the two operating points
  above are both `NEXT`.

`--timing-in-depth`
: Print where the time went, on stderr: parsing, problem creation, each
  query's setup and Newton iterations (iterations, factorizations,
  evaluation, load, factor and solve times, matrix size), and output:

    ```text
    timing: divider.sp
    timing: frontend (source, parsing, HDL): 0.654533ms
    timing: Problem creation (expansion, binding, topology): 0.189907ms
    timing: query graph and output setup: 0.006795ms
    timing: query 0 op setup: 0.002462ms
    timing: query 0 nonlinear checkpoint=1/100: 0.092685ms
    timing: query 0 nonlinear checkpoint=2/100: 0.001677ms
    timing: op newton: iterations=3 factors=3 eval=0.002ms load=0.006ms factor=0.014ms solve=0.001ms update=0.001ms n=4 lu_nnz=9
    timing: query 0 complete: final=0.016602ms active_total=0.110964ms
    timing: output delivery: 0.000571ms
    timing: output finish: 0.000336ms
    timing: run total (analysis, scheduling, output): 0.330372ms
    ```

`-b`, `--batch`
: Accepted for ngspice compatibility. ESPice always runs in batch mode.

`-v`, `--version`
: Print `espice 1.0.0`.

`-h`, `--help`
: Print the usage above.

## Exit status

| Code | Meaning |
|---|---|
| 0 | every file ran |
| 1 | at least one file failed to parse, build or simulate, or its output could not be written. The other files still run |
| 2 | usage error: an unknown option, a missing or invalid value, or no file |

A failed `.meas` card prints an error but does not change the exit status.

## Environment variables

| Variable | Default | Effect |
|---|---|---|
| `ESPICE_THREADS` | 1 | worker threads for device evaluation |
| `ESPICE_SOLVER_THREADS` | 1 | threads for the bordered-block-diagonal matrix factorization, at most 16 |
| `ZIG` | `zig` on `PATH` | the Zig compiler `.hdl` uses to build Verilog-A models at run time |
| `ESPICE_CACHE` | see below | cache directory for compiled `.hdl` models (`$ESPICE_CACHE/hdl`) |
| `ESPICE_GPU_LU` | unset | `1` forces the GPU LU factorization on under a GPU backend, `0` forces it off |

A thread count that is unset, zero or not a number reads as 1. The `.hdl`
cache is `$ESPICE_CACHE/hdl`, else `$XDG_CACHE_HOME/espice/hdl`, else
`~/.cache/espice/hdl`, else `$TMPDIR/espice-cache/hdl`.

## Examples

```sh
# Run a deck; results stay in memory, .meas results print
espice amp.sp

# Binary raw file, for a waveform viewer
espice amp.sp -r amp.raw

# Text tables
espice amp.sp -r amp.txt --format=print

# An HSPICE deck, S-parameters to Touchstone
espice --tokenizer=hspice filter.sp --format=touchstone -r filter.s2p

# Four analyses at once, eight device threads
ESPICE_THREADS=8 espice --jobs=4 big.sp -r big.raw

# Check what a deck will run without running it
espice --plan big.sp
```
