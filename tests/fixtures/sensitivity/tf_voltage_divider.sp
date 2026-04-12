* Transfer Function of Voltage Divider
*
* .TF computes: V(out)/V1, input resistance, output resistance
* Expected: V(out)/V1 = R2/(R1+R2) = 0.5
* Rin = R1 + R2 = 2k (seen by V1)
* Rout = R1 || R2 = 500 (seen at output node)

V1 in 0 DC 5
R1 in out 1k
R2 out 0 1k

.TF V(out) V1

.END
