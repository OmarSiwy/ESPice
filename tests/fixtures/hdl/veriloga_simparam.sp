* $simparam("reltol"/"abstol"/"vntol") reads .options: G = 1e-2*1e3 + 1e-9*1e9 + 1e-4*1e4 = 12 S
* Expected results: veriloga_simparam.expected.json
.hdl "veriloga_simparam.assets/va_gtol.va"
.options reltol=1e-2 abstol=1e-9 vntol=1e-4
N1 out 0 va_gtol
R1 in out 1
Vin in 0 DC 1.3
.op
.end
