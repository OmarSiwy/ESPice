* BSIM3v3 NMOS transfer characteristics: Ids vs Vgs.
* Expected results: device_bsim3_transfer.expected.json
* Origin: benchmark/fixtures/devices/bsim3_transfer/circuit.sp
* Tests subthreshold slope, mobility, threshold voltage.
Vds drain 0 DC 0.9
Vgs gate 0 DC 0
M1 drain gate 0 0 n3 W=10u L=0.18u
.model n3 NMOS(LEVEL=49 VERSION=3.3 TNOM=27 TOX=4.1e-9 VTH0=0.35 K1=0.53 K2=-0.06 K3=80 NLX=1.74e-7 VSAT=1.5e5 UA=-1.4e-9 UB=2.3e-18 UC=-4.6e-11 RDSW=200 U0=280 PCLM=1.3 PDIBLC1=0.39 PDIBLC2=0.0086 NFACTOR=1.5 CDSC=0 VOFF=-0.1  )
.dc Vgs 0 1.8 0.005
.end
