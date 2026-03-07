* I-V Characteristics of JFET 2N4221
* Expected results: device_jfet_vds_vgs.expected.json
* Origin: benchmark/fixtures/devices/jfet_vds_vgs/circuit.sp
*
*
j1 2 1 0 MODJ
VD 2 0 25
VG 1 0 -2
*
.model MODJ NJF LEVEL=1 VTO=-3.5 BETA=4.1E-4 LAMBDA=0.002 RD=200
*
.options noacct
.op
.dc VD 0 25 1 VG -3 0 1
.print DC I(VD)
.END
