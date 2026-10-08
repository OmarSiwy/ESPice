# VerA gaps for the transmission-line models

The O, Y and P cards run on Verilog-A: `models/ltra.va` (LTRA),
`models/txl.va` (TXL) and `models/coupled_ltra.va` (CPL, with the 3- and
4-conductor wrappers `coupled_ltra3.va` and `coupled_ltra4.va`). No native Zig
device is left under `models/`. Parity with the retired native devices is
measured in
[native-transmission-line-migration.md](native-transmission-line-migration.md).

`build.zig.zon` pins VerA to main at `2692a15b` (`git+https://github.com/OmarSiwy/VerA#2692a15bd6f72c0e88287a4e990e45e33eb94bed`, contract abi_version 6).

## Status

| # | Gap | ltra.va | txl.va | coupled_ltra.va | Status |
|---|---|---|---|---|---|
| 1 | `erfc()` | yes | | | Not a builtin and will not become one; ltra.va defines it (see below) |
| 2 | Memory-backed arrays with runtime indexing | yes | yes | yes | Landed; held arrays are stored in place |
| 3 | Growable per-instance history | yes | yes | yes | Open. The files keep the native caps (8192 LTRA, 2048 TXL/CPL) |
| 4 | Per-timepoint cache that survives Newton iterations and is dropped on rejection | yes | yes | yes | Landed (`vera_timepoint`) |
| 5 | Re-arming a timer to an earlier time (VAMS-2023 §5.10.3.3) | yes | | | Fixed; ltra.va's wavefront breakpoints match the native ring |
| 6 | Held `analog initial` results | yes | yes | yes | Landed. The host clears `SimState.analog_initial` once `updateState` holds them (below) |
| 7 | Array slices as analog-function actuals | | | yes | Fixed in `a21c0b0c` |
| 8 | A held integer keeps its integer type through nested joins | | yes | | Fixed in `651a7118` |
| 9 | Generated code a host can compile in reasonable time | | yes | yes | Resolved by 2 |
| 10 | The step size, readable from the model | | yes | yes | Fixed: `$simparam("dt")` is the host's `SimState.dt` (558c520c) |
| 11 | Wrong held field loaded (codegen) | | yes | | Fixed in ce13b27f; the workaround is gone |
| 12 | A device that can refuse a run (`$fatal`/`$error`) | | yes | yes | Fixed: VerA's status channel; the host refuses the query (`error.DeviceRefused`) |

## Notes on the closed and open items

**1, erfc.** VAMS-2023 lists its mathematical functions in Tables 4-14 and
4-15, and neither has `erf` or `erfc`. ltra.va defines erfc as an analog
function copied from VerA's `tests/fixtures/erfc.vh` (series below |x| = 1.5,
continued fraction above), within 1.9e-13 relative of libm on [-6, 6]. The RC
kernels are therefore not bit-equal to the native libm calls. No fixture runs
an RC line.

**3, growable history.** The Verilog-A lines fail the way the native models
did once a run outgrows the cap after pruning.

**6, `analog initial` once.** The host left `SimState.analog_initial` true on
every call, so the TXL Padé fit and the CPL modal fit reran on every Newton
iterate (`bench_tline_cpl3_4_line` took 449 ms against the native 15 ms). A
batch now clears it after its first `updateState` holds the results. The flag
follows the held values through `stateCtl` commit and revert, `copy_state`
and `instantiate`; a revert to the birth commit sets it again, and `reprep`
(new parameters or temperature) does too.

**10, step size.** ngspice's TXL and CPL label each accepted point with
trunc((CKTtime - CKTdelta)*1e12) at the next load. txl.va and
coupled_ltra.va stage the accepted point and commit it in the next
timepoint's `vera_timepoint` block as trunc(($abstime - $simparam("dt"))*1e12).
With `$abstime` alone the label was 1 ps low whenever t_acc*1e12 landed an ulp
below an integer, which failed `tran/bench_tline_txl1_1_line` at 1.044 of
tolerance.

**12, refusal.** A TXL or CPL card whose Padé or modal fit fails, or yields a
non-finite coefficient, `$fatal`s in `analog initial`. The builder used to
refuse those at construction by calling the native fit; now the run stops at
the first evaluation with `<card>: <file>:<line>: fatal: <message>` and
`error.DeviceRefused`. lossy_tline.va's `$error` (unsupported r/l/g/c sets)
refuses the same way; before the status channel it was dropped.

## Build size

txl.va emits about 600 KB of Zig, coupled_ltra.va 5.8 MB for N = 2, and
ltra.va 445 KB. Before memory-backed arrays VerA scalarized every array:
txl.va emitted 26 MB, and LLVM ReleaseFast did not finish that object after
12.5 hours on one thread.
