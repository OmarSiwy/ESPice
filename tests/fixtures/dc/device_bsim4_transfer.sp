* BSIM4 NMOS transfer characteristics: Ids vs Vgs.
* Expected results: device_bsim4_transfer.expected.json
* Origin: benchmark/fixtures/devices/bsim4_transfer/circuit.sp
* Tests subthreshold, mobility models, gate current.
Vds drain 0 DC 0.55
Vgs gate 0 DC 0
M1 drain gate 0 0 n4 W=1u L=0.1u
.model n4 NMOS(LEVEL=54 VERSION=4.5 TNOM=27 TOXE=1.8e-9 TOXP=1.5e-9 TOXM=1.8e-9 VTH0=0.3 K1=0.5 K2=-0.1 VSAT=1.5e5 U0=300 UA=1e-9 UB=1e-18 UC=-4.6e-11 RDSW=200 NFACTOR=1.5 VOFF=-0.1 CDSC=0 CDSCD=0)
.dc Vgs 0 1.1 0.005
.end
