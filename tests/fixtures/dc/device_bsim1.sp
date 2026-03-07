* BSIM1 (Level 4) NMOS output and transfer characteristics.
* Expected results: device_bsim1.expected.json
* Origin: benchmark/fixtures/devices/bsim1/circuit.sp
Vds drain 0 DC 0
Vgs gate 0 DC 0
M1 drain gate 0 0 NMOD W=10u L=1u
.model NMOD NMOS(LEVEL=4 VFB=-0.3 PHI=0.65 K1=0.5 K2=-0.1 ETA=0.02 MUZ=600 U0=0.05 U1=0.01 TOX=40n DL=0 DW=0 X2MZ=0 X2U0=0 X2U1=0 X3U1=0)
.dc Vds 0 5 0.025 Vgs 0 5 0.5
.end
