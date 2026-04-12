* Simplified Boost Converter
*
* VIN=5V, target VOUT~12V
* Duty cycle ~58% => VOUT = VIN/(1-D) = 5/0.42 ~ 11.9V
* L=100uH, C=10uF, R_load=100 ohm
* Switching at 200kHz (period=5us, on-time=2.9us)

.MODEL NMOD NMOS (VTO=0.7 KP=110u GAMMA=0.4 PHI=0.65 LAMBDA=0.04)
.MODEL DMOD D (IS=1e-14 N=1.05 RS=10 BV=100 IBV=100u CJO=2p TT=5n)

* Input supply
VIN vin 0 DC 5

* Inductor from input to switch node
L1 vin sw 100u

* NMOS switch to ground
V_GATE gate 0 PULSE(0 10 0 10n 10n 2.89u 5u)
M1 sw gate 0 0 NMOD W=5000u L=1u

* Freewheeling diode to output
D1 sw out DMOD

* Output cap and load
C1 out 0 10u IC=12
R_load out 0 100

.IC V(out)=12

.TRAN 0.5u 500u UIC

.END
