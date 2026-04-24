* Current-Controlled Voltage Source (H element) — DC test
*
* H element: Hxxx n+ n- Vcontrolling transresistance
* Output voltage = transresistance * I(Vsense)
*
* Input branch: Vin -> Rsense -> 0
* Vsense measures current through the input branch
Vin in 0 DC 2
Rsense in sense_n 1k
Vsense sense_n 0 DC 0
*
* CCVS: Vout = 500 * I(Vsense)
* With I(Vsense) = 2V/1k = 2mA => Vout = 1V
H1 out 0 Vsense 500
Rload out 0 10k
*
.options noacct
.op
.dc Vin 0 5 0.5
.print DC V(out) I(Vsense) I(Vin)
.END
