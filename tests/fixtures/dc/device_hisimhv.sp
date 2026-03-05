* HiSIM_HV (Level 73) high-voltage NMOS output and transfer.
* Expected results: device_hisimhv.expected.json
* Origin: benchmark/fixtures/devices/hisimhv/circuit.sp
Vds drain 0 DC 0
Vgs gate 0 DC 0
M1 drain gate 0 0 nhv W=10u L=10u
.model nhv NMOS(LEVEL=73 VERSION=2.20 TNOM=27 TOX=10e-9)
.dc Vds 0 10 0.05 Vgs 0 5 0.5
.end
