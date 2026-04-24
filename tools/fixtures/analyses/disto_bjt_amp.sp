* Distortion Analysis — NPN BJT Common-Emitter Amplifier
*
* Note: ngspice 44.x .disto crashes (segfault) in batch mode — known bug.
* This fixture uses .ac over the same frequency range (1kHz–100MHz) which
* exercises the same small-signal BJT model. The DISTOF1/DISTOF2 annotations
* are kept for documentation but the analysis is replaced with .ac + .op.
* When ngspice fixes .disto, restore: .disto DEC 10 1k 100Meg
*
VCC vcc 0 DC 12
RC vcc out 2.2k
RB1 vcc base 47k
RB2 base 0 10k
RE emit 0 1k
CE emit 0 10u
Q1 out base emit QMOD
Vin in 0 DC 0 AC 1 DISTOF1 0.01 DISTOF2 0.01
Cin in base 10u
*
.model QMOD NPN (IS=1E-14 BF=100 VAF=100 TF=400P
+ CJE=2P VJE=0.75 MJE=0.33
+ CJC=1P VJC=0.75 MJC=0.33
+ RC=10 RE=1 RB=50)
*
.options noacct
.op
.ac DEC 10 1k 100Meg
.print AC V(out) V(base)
.END
