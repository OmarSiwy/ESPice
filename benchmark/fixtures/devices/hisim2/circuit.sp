* HiSIM2 (Level 68) NMOS output and transfer characteristics.
Vds drain 0 DC 0
Vgs gate 0 DC 0
M1 drain gate 0 0 nhsm W=1u L=0.1u
.model nhsm NMOS(LEVEL=68 VERSION=3.0 TNOM=27 TOX=2e-9 VTH0=0.3 MUEPH1=0.3 MUEPH0=0.035)
.dc Vds 0 1.2 0.01 Vgs 0 1.2 0.2
.end
