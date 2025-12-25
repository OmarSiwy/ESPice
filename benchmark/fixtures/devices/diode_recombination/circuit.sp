* Diode with recombination current (ISR, NR).
* Tests low-current region where recombination dominates.
V1 anode 0 DC 0
D1 anode 0 DMOD
.model DMOD D(IS=1e-14 N=1 ISR=1e-10 NR=2 RS=5)
.dc V1 0 0.8 0.002
.end
