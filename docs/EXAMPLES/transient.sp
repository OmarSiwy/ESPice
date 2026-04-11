* Transient — RLC Step Response
*
* Demonstrates: .TRAN, PULSE waveform, RLC series circuit, .MEASURE rise time
*
* Series RLC driven by a step input.
* Component values chosen for underdamped response:
*   R = 100 Ohm, L = 10 uH, C = 10 nF
*   omega_0 = 1/sqrt(LC) = 1/sqrt(10u * 10n) ≈ 3.16 Mrad/s (503 kHz)
*   zeta    = R/(2) * sqrt(C/L) = 100/2 * sqrt(10n/10u) ≈ 0.158  (underdamped)

.PARAM  VSTEP=5

Vstep  vin  0  PULSE(0 {VSTEP} 0 1n 1n 10u 20u)

R1  vin   rlc_mid  100
L1  rlc_mid  out   10u   IC=0
C1  out   0        10n   IC=0

.TRAN  5n  10u  0  20n

.MEAS  TRAN  trise  TRIG  V(out)  VAL={0.1*VSTEP}  RISE=1
+                   TARG  V(out)  VAL={0.9*VSTEP}  RISE=1

.PRINT  TRAN  V(vin)  V(out)  I(L1)

.END
