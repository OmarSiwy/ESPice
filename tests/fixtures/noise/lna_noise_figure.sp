* Low-Noise Amplifier — BJT Cascode with Input Matching
*
* VCC=5V, BJT cascode (Q1 CE + Q2 CB) for low noise figure
* Input matching network: series inductor for impedance match to 50 ohm
* Source impedance = 50 ohm
* Cascode provides high gain with low Miller effect
* Measures noise at output referred to input source

.MODEL NPN1 NPN (BF=100 IS=1e-15 VAF=100 RB=10 RC=1 RE=0.5 CJE=2p CJC=1p TF=0.3n TR=6n)

VCC vcc 0 DC 5
VIN in 0 DC 0 AC 1

* Source impedance
RS in match 50

* Input matching inductor (resonates with Cpi at ~1GHz)
L_match match b1 5n

* DC bias for Q1 (CE stage)
R_bias1 vcc b1_bias 10k
R_bias2 b1_bias 0 2.2k
L_bias b1_bias b1 100n

* Input coupling cap
C_in match b1_ac 100p
R_b1 b1_ac b1 0.001

* CE stage (Q1): provides transconductance gain
Q1 c1 b1 e1 NPN1
RE e1 0 10

* Cascode base bias (fixed voltage ~ 2.5V)
R_cb1 vcc b2 10k
R_cb2 b2 0 10k
C_cb b2 0 100p

* CB stage (Q2): provides isolation, no Miller effect
Q2 out b2 c1 NPN1

* Collector load
RC vcc out 1k

* Output coupling
C_out out out_ac 100p
R_load out_ac 0 50

.NOISE V(out_ac) VIN DEC 20 1MEG 10G

.END
