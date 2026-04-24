* FFT Post-processing — 5-stage Ring Oscillator
*
* Transient run followed by .measure and FFT in .control block
* Uses ngspice linearize + fft commands
*
.options noacct
*
* Supply
VDD vdd 0 DC 1.8
*
* CMOS inverter subcircuit
.subckt INV in out vdd vss
MP out in vdd vdd PMOD W=2u L=180n
MN out in vss vss NMOD W=1u L=180n
.ends INV
*
* 5-stage ring (odd number = oscillates)
X1 n1 n2 vdd 0 INV
X2 n2 n3 vdd 0 INV
X3 n3 n4 vdd 0 INV
X4 n4 n5 vdd 0 INV
X5 n5 n1 vdd 0 INV
*
* Load cap to set frequency
CL n1 0 10f
*
.model NMOD NMOS LEVEL=1 VTO=0.4 KP=200u GAMMA=0.4 LAMBDA=0.01
.model PMOD PMOS LEVEL=1 VTO=-0.4 KP=80u GAMMA=0.4 LAMBDA=0.01
*
* UIC: skip DC OP entirely — use the .ic values as the t=0 state.
* Without UIC the symmetric DC OP fails to converge (all nodes identical).
.ic V(n1)=1.8 V(n2)=0 V(n3)=1.8 V(n4)=0 V(n5)=1.8
.tran 10p 10n UIC
*
.control
run
linearize v(n1)
fft v(n1)
print v(n1)
.endc
*
.END
