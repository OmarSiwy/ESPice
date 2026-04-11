* Noise Analysis — Common-Emitter BJT Amplifier
*
* Demonstrates: .NOISE analysis, BJT, input-referred and output noise
*
* Common-emitter stage biased at Ic ≈ 1 mA.
* Noise swept 1 kHz to 100 MHz, 10 points/decade.
* Output: ONOISE (V/sqrt(Hz) at collector), INOISE (A/sqrt(Hz) referred to input).

.MODEL Q2N2222 NPN (IS=14.34e-15 BF=255 NF=1 VAF=74.3
+                   CJE=22.01p VJE=0.756 MJE=0.5 TF=411p
+                   CJC=7.306p VJC=0.75 MJC=0.3 TR=46.91n
+                   RC=0.3 RB=10 RE=0.5)

.PARAM  VCC=12  RC=5k  RE=1k  RB1=68k  RB2=22k

Vcc    vcc  0  DC {VCC}

Rb1    vcc  base  {RB1}
Rb2    base  0    {RB2}
Rc     vcc  coll  {RC}
Re     emit  0    {RE}

Q1  coll  base  emit  Q2N2222

* Input source (used as reference for input-referred noise calculation)
Vin  in  0  DC 0  AC 1
Rin  in  base  1k

* Coupling / bypass
Cin   in    base  10u
Cbyp  emit  0     100u

.NOISE  V(coll)  Vin  DEC  10  1k  100MEG

.PRINT  NOISE  ONOISE  INOISE

.END
