* Colpitts LC Oscillator
*
* NPN BJT with capacitive voltage divider (C1, C2) and inductor L1
* VCC=12V
* C1=100p, C2=100p, L1=10u
* f_osc = 1/(2*pi*sqrt(L*Cseries)) where Cseries = C1*C2/(C1+C2) = 50p
* f_osc ~ 7.1 MHz
*

VCC vcc 0 DC 12

* Bias network
RB1 vcc base 47k
RB2 base 0 10k
RE emit 0 470
CE emit 0 10u

* Collector load (RFC - RF choke approximated by resistor + inductor)
RC vcc col 1k

* Tank circuit
* L1 from collector to ground (through DC block)
LCHOKE col n_tank 10u
C1 n_tank 0 100p
C2 n_tank base_ac 100p

* AC coupling from tank to base
CCOUP base_ac base 100p

* DC blocking cap on collector output
COUT col out 100p
RLOAD out 0 1k

* BJT
Q1 col base emit NPN1

.MODEL NPN1 NPN (BF=100 IS=1e-15 VAF=100 RB=10 RC=1 RE=0.5 CJE=2p CJC=1p TF=0.3n TR=6n)

* Initial condition to start oscillation
.IC V(n_tank) 0.1

.TRAN 0.1n 10u

.END
