* Misspelled .hdl instance parameter (RR for R) must be an error, not the default
* Expected results: veriloga_unknown_param.expected.json
.hdl "veriloga_hdl_errors.assets/va_rh.va"
N1 out 0 va_rh RR=50
R1 in out 100
Vin in 0 DC 1
.op
.end
