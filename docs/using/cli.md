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
      --measures-only         Measure .tran cards as the run goes; keep only the columns whole-run cards read
      --early-stop            End each .tran once its .meas cards have resolved (never with LAST, _CONT,
                              JITTER, .check/DOUT or a window without TO=)
      --abort-after=T         Fail a .tran still missing a .meas value past T seconds
      --warm-start            Start each transient's OP from the nominal one
      --tangents=P,...        Print d(.meas)/d(P) of the first .tran's cards for these .params
      --tangent-step=S        Relative step of --tangents (default 1e-6)
      --tokenizer=FMT         ngspice|hspice|spectre
      --vpi=APP               Load a VPI application (.so) for Verilog-A $systf calls; repeatable
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
  the old contents or the complete new result; an appended file is
  replaced once, when the run ends. See [Output](output.md).

`--format=FMT`
: The output format, default `binary`. Names and aliases: `binary` (`raw`),
  `ascii`, `csv`, `print` (`text`), `touchstone` (`snp`, `s2p`), `citi`
  (`citifile`), `psf`, `fsdb`, `sst2` (`hspice`). An unknown name is a usage
  error.

`--tokenizer=FMT`
: The netlist dialect: `ngspice` (default, alias `ng`), `hspice` (`hs`) or
  `spectre` (`scs`). The single-dash spelling `-tokenizer=hspice` works
  too. See [Dialects](dialects.md).

`--vpi=APP`
: Load the VPI application `APP`, a shared library exporting
  `vlog_startup_routines` (LRM 12.33.2), before the deck's `.hdl` models.
  Its analog system functions answer the models' `$name` calls. Repeat it
  for several applications; a deck adds its own with `.options vpi=`. See
  [VPI applications](devices.md#vpi-applications).

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
  can share it. Independent analyses run in parallel, and a finished one
  is replaced at once. In a sweep each point's transient starts as soon as
  its operating point is done. Results and output bytes are the same at
  every N.

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

`--warm-start`
: Solve the nominal circuit's transient operating point once, then start
  every transient's operating point from it (a `.step`, `.data` or Monte
  Carlo point) instead of the cold start. A point whose warm start fails
  takes the full ladder. The guess is the same for every point, so results
  do not depend on `--jobs` or point order, but they may differ from a cold
  run within the Newton tolerances. A point with its own topology (a model
  bin that moves) starts cold.

`--measures-only`
: For runs that only need their `.meas` results, such as large sweeps.
  Each transient measures its `.tran` cards as it accepts each step,
  with the same values to the last bit, and keeps no waveform for the
  cards that read each step once: WHEN, TRIG/TARG, FIND and DERIV with
  AT= or WHEN, and AVG, MIN, MAX, PP, RMS, INTEG, EM_AVG and ERR over a
  window. Cards that need the whole run (`_CONT`, JITTER, `.check`,
  DOUT), cards that read an earlier card's value (`AT=t50`), TARG with
  TD=TRIG, and FIND or DERIV whose WHEN has TD=, FROM= or a LAST count
  keep the columns they read. A written result then holds only the time
  and those columns. Ignored for a deck with `.save` or `.stim`.

`--early-stop`
: End each transient once all of its `.tran` cards have their final
  values, keeping the steps so far. An event card resolves at its event
  (or past its TO=), a window past its TO=, a PARAM once the cards it
  reads have. A deck with a card that can only resolve at the end (a LAST
  count without TO=, `_CONT`, JITTER, `.check`, DOUT, a window without
  TO=, a card reading a later card) runs to the end as usual; those
  cards still work. The `.meas` values equal a full run's.

`--abort-after=T`
: Fail a transient that passes time `T` (seconds, positive) with any
  `.tran` card still unresolved. Its `.meas` values print as NaN; the
  other points are unaffected.

`--tangents=P,...`, `--tangent-step=S`
: Make the `.param` names `P` live and integrate, beside the deck's first
  transient, one first-order prediction per parameter moved by `S` times
  its value (`S` itself at 0; default 1e-6). After the `.meas` results it
  prints the slope of each `.tran` card against each parameter:

    ```text
      Tangents for Transient Analysis

    d(tpd)/d(rv) = 6.560399e-14
    d(tpd)/d(cv) = 6.560684e2
    ```

    A name no `.param` defines, a name a `.meas` or analysis card reads, a
    swept deck, or a transient that cannot carry tangents (Gear 3 to 6,
    UIC, `.ic`) is an error. The values agree with central differences
    to about 1e-4.

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
Each sweep point's `.meas` block prints as soon as it and every point
before it have finished, so the output is the same at any `--jobs`. A
deck whose run fails prints the blocks of the points that finished, the
failed points' values as NaN, then the error.

## Environment variables

| Variable | Default | Effect |
|---|---|---|
| `ESPICE_THREADS` | 1 | worker threads for device evaluation; results are byte-identical at any count |
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
