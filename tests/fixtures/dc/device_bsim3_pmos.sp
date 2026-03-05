* BSIM3v3 PMOS output characteristics.
* Expected results: device_bsim3_pmos.expected.json
* Origin: benchmark/fixtures/devices/bsim3_pmos/circuit.sp
* Tests PMOS-specific parameter handling.
Vsd 0 drain DC 0
Vsg 0 gate DC 0
M1 drain gate 0 0 p3 W=20u L=0.18u
.model p3 PMOS(LEVEL=49 VERSION=3.3 TNOM=27 TOX=4.1e-9 VTH0=-0.4 K1=0.55 K2=-0.05 K3=80 VSAT=1.2e5 UA=-1.4e-9 UB=2.3e-18 UC=-4.6e-11 RDSW=400 U0=100 PCLM=1.3 PDIBLC1=0.39 PDIBLC2=0.0086)
.dc Vsd 0 1.8 0.01 Vsg 0 1.8 0.3
.end
