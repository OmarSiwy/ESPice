* An .hdl instance with fewer nodes than module ports must be an error, not ground
* Expected results: veriloga_wrong_node_count.expected.json
.hdl "veriloga_hdl_errors.assets/va_rh.va"
N1 out va_rh R=50
R1 in out 100
Vin in 0 DC 1
.op
.end
