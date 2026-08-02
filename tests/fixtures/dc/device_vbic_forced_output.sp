VBIC Output Test
* VBIC 1.3 (models/vbic13_4t.va) against VACASK running the same VBIC 1.3
* reference Verilog-A (vbic_1p3_4t.osdi), not ngspice's VBIC 1.2 (#16): 1.3's
* avalm shifts the smooth max by vminm, 1.2 (vbicload.c:3597) does not
* (dev/devices/models.md). Tight tolerances on both sides: at the default
* reltol=1e-3 the deep-saturation points move by up to 7e-4.
* Expected results: device_vbic_forced_output.expected.json
* Origin: benchmark/fixtures/devices/vbic_forced_output/circuit.sp
V1 V1_P V1_N 0.0
VB V1_N 0 0.5
VC Q1_C 0 0.0
Q1 Q1_C V1_P 0 N1

.OPTIONS NOACCT reltol=1e-10 vntol=1e-12 abstol=1e-15

.DC VC 0 5 50M VB 700M 1 50M

.print dc -i(vc)
.print dc -i(vb)

.MODEL N1 NPN LEVEL=4 
+ IS=1e-16 IBEI=1e-18 IBEN=5e-15 IBCI=2e-17 IBCN=5e-15 ISP=1e-15 RCX=10
+ RCI=60 RBX=10 RBI=40 RE=2 RS=20 RBP=40 VEF=10 VER=4 IKF=2e-3 ITF=8e-2
+ XTF=20 IKR=2e-4 IKP=2e-4 CJE=1e-13 CJC=2e-14 CJEP=1e-13 CJCP=4e-13 VO=2
+ GAMM=2e-11 HRCF=2 QCO=1e-12 AVC1=2 AVC2=15 TF=10e-12 TR=100e-12 TD=2e-11 RTH=300

.END
