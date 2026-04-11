* DC Operating Point — Resistive Voltage Divider
*
* Demonstrates: .OP analysis, V source, resistors, .PRINT DC
*
* Circuit: VDD -> R1 -> mid -> R2 -> GND
* Expected: V(mid) = VDD * R2 / (R1 + R2) = 3.3 * 2k / (1k + 2k) = 2.2 V

.PARAM  VDD=3.3

Vsupply  vdd  0  DC {VDD}
R1       vdd  mid  1k
R2       mid  0    2k

.OP
.PRINT  DC  V(vdd)  V(mid)  I(Vsupply)

.END
