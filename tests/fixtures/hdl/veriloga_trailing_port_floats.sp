* An .hdl instance that omits a trailing port floats it, as ngspice leaves an OSDI card's
* Expected results: veriloga_trailing_port_floats.expected.json
.hdl "veriloga_hdl_errors.assets/va_rh.va"
N1 out va_rh R=50
R1 in out 100
Vin in 0 DC 1
.op
.end
