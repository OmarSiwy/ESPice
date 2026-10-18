* VPI FIXTURE: the harness passes --vpi with build.zig's vpi_gain (vpi_gain.c), which registers $espice_scaled and its analog callbacks
* LRM 12.31.3 in a transient (#198): acbInitialStep, a rejecting acbConvergenceTest, and an acbAbsTime at 0.37 ms, off the 0.02 ms grid
* Expected results: veriloga_vpi_callbacks.expected.json
.hdl "veriloga_vpi_callbacks.assets/va_vpi_scaled.va"
N1 out 0 va_vpi_scaled
R1 in out 1k
Vin in 0 DC 1
.tran 10u 1m
.end
