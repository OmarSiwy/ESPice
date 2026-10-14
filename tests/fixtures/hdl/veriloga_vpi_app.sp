* VPI FIXTURE: the harness passes --vpi with build.zig's vpi_gain (vpi_gain.c), which registers $espice_gain
* A Verilog-A conductance whose gain comes from a C VPI application's calltf (LRM 12.32, #197): G = 2 mS
* Expected results: veriloga_vpi_app.expected.json
.hdl "veriloga_vpi_app.assets/va_vpi_gain.va"
N1 out 0 va_vpi_gain
R1 in out 1k
Vin in 0 DC 1
.op
.end
