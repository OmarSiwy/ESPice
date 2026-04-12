* Transfer Function of Common-Emitter Amplifier
*
* VCC=12V, NPN CE amp with voltage divider bias
* .TF computes: V(out)/VIN, input resistance, output resistance
* Expected mid-band voltage gain: Av ~ -gm*RC ~ -(IC/VT)*RC
* With IC~1.1mA, VT=26mV: Av ~ -1.1m/26m * 4.7k ~ -199
* (bypassed emitter resistor for full AC gain)

.MODEL NPN1 NPN (BF=100 IS=1e-15 VAF=100 RB=10 RC=1 RE=0.5 CJE=2p CJC=1p TF=0.3n TR=6n)

VCC vcc 0 DC 12
VIN in 0 DC 0

* Input coupling
C_in in b 1u

* Bias network
R1 vcc b 56k
R2 b 0 10k

* CE amplifier
Q1 c b e NPN1
RC vcc c 4.7k
RE e 0 1k

* Emitter bypass cap
CE e 0 100u

* Output
R_load c 0 100k

.TF V(c) VIN

.END
