* PMOS W/L Optimization Sweep — find W/L for target gm/Id
.model pch PMOS(level=54)
Vdd vdd 0 DC 1.1
Vgs gate 0 DC -0.5
Vds drain 0 0
M1 drain gate vdd vdd pch W=2u L=0.1u
.dc Vgs -1.1 -0.2 0.01
.end
