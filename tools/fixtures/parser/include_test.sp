* Parser Test — .INCLUDE file inclusion
*
* Models are defined in a separate file and pulled in with .include
* The included file defines DMOD and QNPN
*
.include "models.lib"
*
VCC vcc 0 DC 5
RC vcc out 2.2k
RB in base 47k
Vin in 0 DC 0.7
Q1 out base 0 QNPN
*
.options noacct
.op
.dc Vin 0.4 1.0 0.02
.print DC V(out) I(RC)
.END
