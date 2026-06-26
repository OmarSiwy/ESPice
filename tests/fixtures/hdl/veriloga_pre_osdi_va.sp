* pre_osdi of an .osdi with a .va beside it loads that .va: va_rh divider -> v(out) = 1/3
* Expected results: veriloga_pre_osdi_va.expected.json
.control
pre_osdi veriloga_hdl_errors.assets/va_rh.osdi
.endc
N1 out 0 va_rh R=50
R1 in out 100
Vin in 0 DC 1
.op
.end
