* BSIM4 PMOS output characteristics.
* Expected results: device_bsim4_pmos.expected.json
* Origin: benchmark/fixtures/devices/bsim4_pmos/circuit.sp
Vsd 0 drain DC 0
Vsg 0 gate DC 0
M1 drain gate 0 0 p4 W=2u L=0.1u
.model p4 PMOS(LEVEL=54 VERSION=4.5 TNOM=27 TOXE=1.8e-9 TOXP=1.5e-9 TOXM=1.8e-9 VTH0=-0.35 K1=0.5 K2=-0.1 VSAT=1.2e5 U0=100 RDSW=400)
.dc Vsd 0 1.1 0.01 Vsg 0 1.1 0.2
.end
