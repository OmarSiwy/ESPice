* BJT Common-Emitter Amplifier — Shot Noise Analysis
*
* VCC=12V, NPN CE amplifier with voltage divider bias
* Shot noise from collector current: Si = 2*q*IC
* Base resistance thermal noise: Sv = 4*k*T*RB
* Tests noise analysis with active device

.MODEL NPN1 NPN (BF=100 IS=1e-15 VAF=100 RB=10 RC=1 RE=0.5 CJE=2p CJC=1p TF=0.3n TR=6n)

VCC vcc 0 DC 12
VIN in 0 DC 0 AC 1

* Input coupling
C_in in b 1u

* Bias network: voltage divider
R1 vcc b 56k
R2 b 0 10k

* CE amplifier
Q1 c b e NPN1
RC vcc c 4.7k
RE e 0 1k

* Bypass cap on emitter (AC ground for gain)
CE e 0 100u

* Output coupling
C_out c out 1u
R_load out 0 10k

.NOISE V(out) VIN DEC 20 10 100MEG

.END
