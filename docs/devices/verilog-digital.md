# Verilog digital devices (`.v`)

A deck loads a Verilog-1364 module with `.hdl "design.v"` and instantiates it
with an `N` card, the same way as a Verilog-A model. VerA compiles the module
into a contract device that wraps its event-driven digital engine: IEEE 1364
scheduling, four-state values, up to 256 pins.

## Analog boundary

- Inputs cross from analog to digital at a threshold (A2D), with an optional
  hysteresis band (`vth`, `vhys` on the card).
- Outputs drive back into the circuit as a Thevenin source (`rout`) through
  linear `trise`/`tfall` ramps (D2A). A ramp is never an ideal step; its
  minimum length is 1 ps.

## Timing and its cost

Only A2D crossings that some process is sensitive to are located, and only
those constrain the time step. A crossing nothing waits on costs nothing.

The host may accept a time point up to `ttol` after a located crossing. The
default is `min(trise, tfall)/50`, so a ramp that a crossing triggers starts
at most 2% of its own length late. Set `ttol` on the device card for tighter
timing, for example half the simulator tick
(`tests/fixtures/hdl/verilog_tff_hysteresis.sp` uses `ttol=0.5p`). A smaller
`ttol` adds time points around every crossing that wakes a process.

Building a `.v` device compiles VerA's digital engine with it, so even a tiny
module takes a few seconds to build the first time; the build is cached
(`$ESPICE_CACHE/hdl`, see the README).

## Not supported

Inside a device VerA refuses (E1103) `--state=2`, `assign`/`force`,
`$readmem` and §17.6 queues. There is no host-supplied timescale option.
