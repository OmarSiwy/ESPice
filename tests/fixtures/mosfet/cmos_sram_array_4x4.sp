* 4x4 SRAM Array using .SUBCKT
* 16 cells in 4 rows x 4 columns with wordline drivers and bitline precharge

VDD vdd 0 DC 3.3

.MODEL NMOD NMOS (VTO=0.7 KP=110u GAMMA=0.4 PHI=0.65 LAMBDA=0.04 CBD=10f CBS=10f)
.MODEL PMOD PMOS (VTO=-0.7 KP=50u GAMMA=0.4 PHI=0.65 LAMBDA=0.05 CBD=10f CBS=10f)

*** 6T SRAM Cell Subcircuit ***
* Ports: BL BLB WL VDD VSS
.SUBCKT SRAM6T bl blb wl vdd vss
* Cross-coupled inverter 1
M3 qbar q vdd vdd PMOD W=4u L=1u
M1 qbar q vss vss NMOD W=2u L=1u
* Cross-coupled inverter 2
M4 q qbar vdd vdd PMOD W=4u L=1u
M2 q qbar vss vss NMOD W=2u L=1u
* Access transistors
M5 bl wl q vss NMOD W=4u L=1u
M6 blb wl qbar vss NMOD W=4u L=1u
* Parasitic storage node capacitances
CQ q vss 1f
CQBAR qbar vss 1f
.ENDS SRAM6T

*** Bitline Precharge Subcircuit ***
* Ports: BL BLB PRE VDD
.SUBCKT PRECHARGE bl blb pre vdd
* Precharge to VDD when PRE is low (PMOS)
MP1 bl pre vdd vdd PMOD W=10u L=1u
MP2 blb pre vdd vdd PMOD W=10u L=1u
* Equalize
MPE bl pre blb vdd PMOD W=5u L=1u
.ENDS PRECHARGE

*** Wordline Drivers ***
* WL0 active first, WL1 active second
VWL0 wl0 0 PULSE(0 3.3 20n 0.5n 0.5n 20n 100n)
VWL1 wl1 0 PULSE(0 3.3 70n 0.5n 0.5n 20n 100n)
VWL2 wl2 0 DC 0
VWL3 wl3 0 DC 0

*** Precharge Control (active-low, precharge before wordline) ***
VPRE pre 0 PULSE(0 3.3 15n 0.5n 0.5n 80n 100n)

*** Bitline Precharge Circuits (4 columns) ***
XPRE0 bl0 blb0 pre vdd PRECHARGE
XPRE1 bl1 blb1 pre vdd PRECHARGE
XPRE2 bl2 blb2 pre vdd PRECHARGE
XPRE3 bl3 blb3 pre vdd PRECHARGE

*** Write Drivers for Column 0 (write '0' to cell [0,0]) ***
* During WL0 active window, pull BL0 low and keep BLB0 high
VWD0 wd0 0 PULSE(0 3.3 22n 0.5n 0.5n 15n 100n)
MWN0 bl0 wd0 0 0 NMOD W=20u L=1u

*** SRAM Cell Array: 4 rows x 4 columns ***
* Row 0
XC00 bl0 blb0 wl0 vdd 0 SRAM6T
XC01 bl1 blb1 wl0 vdd 0 SRAM6T
XC02 bl2 blb2 wl0 vdd 0 SRAM6T
XC03 bl3 blb3 wl0 vdd 0 SRAM6T

* Row 1
XC10 bl0 blb0 wl1 vdd 0 SRAM6T
XC11 bl1 blb1 wl1 vdd 0 SRAM6T
XC12 bl2 blb2 wl1 vdd 0 SRAM6T
XC13 bl3 blb3 wl1 vdd 0 SRAM6T

* Row 2
XC20 bl0 blb0 wl2 vdd 0 SRAM6T
XC21 bl1 blb1 wl2 vdd 0 SRAM6T
XC22 bl2 blb2 wl2 vdd 0 SRAM6T
XC23 bl3 blb3 wl2 vdd 0 SRAM6T

* Row 3
XC30 bl0 blb0 wl3 vdd 0 SRAM6T
XC31 bl1 blb1 wl3 vdd 0 SRAM6T
XC32 bl2 blb2 wl3 vdd 0 SRAM6T
XC33 bl3 blb3 wl3 vdd 0 SRAM6T

* Bitline parasitic capacitances (shared column capacitance)
CBL0 bl0 0 50f
CBLB0 blb0 0 50f
CBL1 bl1 0 50f
CBLB1 blb1 0 50f
CBL2 bl2 0 50f
CBLB2 blb2 0 50f
CBL3 bl3 0 50f
CBLB3 blb3 0 50f

.TRAN 0.1n 200n

.END
