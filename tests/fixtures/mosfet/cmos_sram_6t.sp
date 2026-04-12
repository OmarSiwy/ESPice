* 6-Transistor SRAM Cell
* Cross-coupled inverters (M1-M4) + 2 access transistors (M5, M6)
* Demonstrates read and write operations

VDD vdd 0 DC 3.3

* Wordline: active during read/write windows
VWL wl 0 PULSE(0 3.3 10n 0.5n 0.5n 20n 60n)

* Bitline: precharged high, pulled low for write-0
VBL bl 0 PULSE(3.3 0 15n 0.5n 0.5n 10n 60n)

* Bitline bar: precharged high, stays high during write-0
VBLB blb 0 DC 3.3

*** Cross-coupled inverters ***
* Inverter 1: M1 (NMOS) + M3 (PMOS), input=q, output=qbar
M3 qbar q vdd vdd PMOD W=4u L=1u
M1 qbar q 0 0 NMOD W=2u L=1u

* Inverter 2: M2 (NMOS) + M4 (PMOS), input=qbar, output=q
M4 q qbar vdd vdd PMOD W=4u L=1u
M2 q qbar 0 0 NMOD W=2u L=1u

*** Access transistors ***
* M5: connects BL to Q when WL is high
M5 bl wl q 0 NMOD W=4u L=1u

* M6: connects BLB to Qbar when WL is high
M6 blb wl qbar 0 NMOD W=4u L=1u

* Small parasitic capacitances on storage nodes
CQ q 0 1f
CQBAR qbar 0 1f

.MODEL NMOD NMOS (VTO=0.7 KP=110u GAMMA=0.4 PHI=0.65 LAMBDA=0.04 CBD=10f CBS=10f)
.MODEL PMOD PMOS (VTO=-0.7 KP=50u GAMMA=0.4 PHI=0.65 LAMBDA=0.05 CBD=10f CBS=10f)

* Initial conditions to set stored value
.IC V(q)=3.3 V(qbar)=0

.TRAN 0.1n 100n UIC

.END
