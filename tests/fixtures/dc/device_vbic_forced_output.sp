VBIC Output Test
* KNOWN GAP: model version — models/vbic13_4t.va (VBIC 1.3) avalm shifts the smooth max by vminm (lines ~753-757); the ngspice oracle is VBIC 1.2 (vbicload.c:3597) with no shift.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: device_vbic_forced_output.expected.json
* Origin: benchmark/fixtures/devices/vbic_forced_output/circuit.sp
V1 V1_P V1_N 0.0
VB V1_N 0 0.5
VC Q1_C 0 0.0
Q1 Q1_C V1_P 0 N1

.OPTIONS NOACCT

.DC VC 0 5 50M VB 700M 1 50M

.print dc -i(vc)
.print dc -i(vb)

.MODEL N1 NPN LEVEL=4 
+ IS=1e-16 IBEI=1e-18 IBEN=5e-15 IBCI=2e-17 IBCN=5e-15 ISP=1e-15 RCX=10
+ RCI=60 RBX=10 RBI=40 RE=2 RS=20 RBP=40 VEF=10 VER=4 IKF=2e-3 ITF=8e-2
+ XTF=20 IKR=2e-4 IKP=2e-4 CJE=1e-13 CJC=2e-14 CJEP=1e-13 CJCP=4e-13 VO=2
+ GAMM=2e-11 HRCF=2 QCO=1e-12 AVC1=2 AVC2=15 TF=10e-12 TR=100e-12 TD=2e-11 RTH=300

.END
