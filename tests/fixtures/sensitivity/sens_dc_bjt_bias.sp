* DC Sensitivity of BJT Bias Point
*
* VCC=12V, voltage divider bias with emitter degeneration
* R1=56k, R2=10k => VB ~ 12*10k/66k ~ 1.82V
* VE ~ VB - 0.7 ~ 1.12V, IE ~ 1.12/1k ~ 1.12mA
* VC ~ 12 - 1.12m*4.7k ~ 6.7V
* Sensitivity shows which component most affects collector voltage

.MODEL NPN1 NPN (BF=100 IS=1e-15 VAF=100 RB=10 RC=1 RE=0.5 CJE=2p CJC=1p TF=0.3n TR=6n)

VCC vcc 0 DC 12

* Bias network
R1 vcc b 56k
R2 b 0 10k

* CE amplifier
Q1 c b e NPN1
RC vcc c 4.7k
RE e 0 1k

.SENS V(c)

.END
