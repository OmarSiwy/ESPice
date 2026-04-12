* VBIC Advanced BJT Model — DC operating point bias
*
* NPN BJT using VBIC model (Level=4)
* Simple common-emitter bias for DC operating point
VCC vcc 0 DC 5
RC vcc coll 1k
RB base 0 0
VBB base 0 DC 0.85
Q1 coll base 0 VBIC_NPN
*
.model VBIC_NPN NPN LEVEL=4
+ TNOM=27 RCX=10 RCI=60 VO=2 GAMM=2E-11 HRCF=2
+ RBX=10 RBI=40 RE=2 RS=100
+ IS=1E-16 NF=1.0 NR=1.0 FC=0.5
+ CBEO=0 CJE=1.5P PE=0.75 ME=0.33
+ CBCO=0 CJC=0.5P PC=0.6 MC=0.3 AJC=-0.5
+ CJEP=0.5P
+ BF=150 IBF=0 NF=1.0
+ BR=5 IBR=0 NR=1.0
+ AVC1=0.02 AVC2=3.5
+ TR=10N TF=15P
+ EG=1.12 XTB=0 XTI=3
*
.options noacct
.op
.dc VBB 0.6 1.0 0.02
.print DC I(RC) V(coll) V(base)
.END
