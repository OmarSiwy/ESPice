* Cross-Coupled CMOS Inverters — Bistable / Multiple DC Solutions
*
* Two CMOS inverters cross-coupled form a latch
* Has two stable DC operating points:
*   q=VDD, qbar=0 or q=0, qbar=VDD
* Plus one metastable point at q=qbar=VDD/2
* Tests DC operating point solver handling of multiple solutions

VDD vdd 0 DC 3.3

* Inverter 1: input=qbar, output=q
M1 q qbar 0 0 NMOD W=10u L=1u
M2 q qbar vdd vdd PMOD W=20u L=1u

* Inverter 2: input=q, output=qbar
M3 qbar q 0 0 NMOD W=10u L=1u
M4 qbar q vdd vdd PMOD W=20u L=1u

.MODEL NMOD NMOS (VTO=0.7 KP=110u)
.MODEL PMOD PMOS (VTO=-0.7 KP=50u)

.OP

.END
