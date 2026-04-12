* LDO Regulator with PMOS Pass Transistor
*
* PMOS pass element controlled by error amplifier (VCVS)
* Voltage reference = 1.25V (bandgap reference approximation)
* Feedback resistor divider sets output: VOUT = VREF * (1 + R1/R2) = 1.25 * (1 + 33k/20k) ~ 3.3V
* VIN=5V, VOUT~3.3V
* Load step test: current source steps from 10mA to 100mA at t=50u

.MODEL PMOD PMOS (VTO=-0.7 KP=50u GAMMA=0.4 PHI=0.65 LAMBDA=0.05)

* Input supply
VIN vin 0 DC 5

* Voltage reference (bandgap approximation)
VREF vref 0 DC 1.25

* Error amplifier: compares feedback voltage to reference
* E1 output drives PMOS gate. High gain, inverting sense.
* Gate voltage = large_gain * (VREF - V_fb)
* Using VCVS: E1 out+ out- controlling_node+ controlling_node-
E1 gate 0 vref fb 10000

* PMOS pass transistor: source=VIN, gate=gate, drain=output
M1 out gate vin vin PMOD W=10000u L=1u

* Output capacitor (with ESR)
R_esr out_cap out 0.1
C_out out_cap 0 10u

* Feedback resistor divider
R1 out fb 33k
R2 fb 0 20k

* Load: DC bias + step
* 10mA steady, stepping to 100mA at 50us
I_load out 0 PULSE(10m 100m 50u 1u 1u 49u 200u)

.IC V(out)=3.3

.TRAN 1u 100u UIC

.END
