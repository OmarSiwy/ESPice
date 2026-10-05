* pre_osdi is an error: espice never loads OSDI, even with a .va beside the .osdi
* Expected results: veriloga_pre_osdi_va.expected.json
.control
pre_osdi veriloga_hdl_errors.assets/va_rh.osdi
.endc
N1 out 0 va_rh R=50
R1 in out 100
Vin in 0 DC 1
.op
.end
