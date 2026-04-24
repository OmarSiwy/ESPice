* DC Sensitivity of Voltage Divider
*
* Simple resistive divider: V(out) = VIN * R2/(R1+R2) = 2.5V
* Sensitivity analysis shows how V(out) changes with each parameter
* dV(out)/dR1 = -VIN*R2/(R1+R2)^2, dV(out)/dR2 = VIN*R1/(R1+R2)^2

V1 in 0 DC 5
R1 in out 1k
R2 out 0 1k

.SENS V(out)

.END
