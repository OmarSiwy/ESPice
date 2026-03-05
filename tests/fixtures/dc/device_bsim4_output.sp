* BSIM4 NMOS output characteristics: Ids vs Vds family.
* Expected results: device_bsim4_output.expected.json
* Origin: benchmark/fixtures/devices/bsim4_output/circuit.sp
* Tests advanced BSIM4 physics: gate tunneling, stress effects.
Vds drain 0 DC 0
Vgs gate 0 DC 0
M1 drain gate 0 0 n4 W=1u L=0.1u
.model n4 NMOS(LEVEL=54 VERSION=4.5 TNOM=27 TOXE=1.8e-9 TOXP=1.5e-9 TOXM=1.8e-9 EPSROX=3.9 WINT=5e-9 LINT=0 VTH0=0.3 K1=0.5 K2=-0.1 DVT0=0 DVT1=0 DVT2=0 VSAT=1.5e5 UA=1e-9 UB=1e-18 UC=-4.6e-11 U0=300 PCLM=1.3 PDIBLC1=0.39 PDIBLC2=0.009 RDSW=200 DELTA=0.01 FPROUT=0.2 PDITS=0 PDITSL=0 PDITSD=0)
.dc Vds 0 1.1 0.01 Vgs 0 1.1 0.2
.end
