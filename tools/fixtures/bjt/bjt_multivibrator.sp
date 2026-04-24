* Astable Multivibrator (2 NPN Cross-Coupled)
*
* VCC=5V, R1=R2=10k, C1=C2=10n
* Free-running oscillation
*

VCC vcc 0 DC 5

* Collector loads
RC1 vcc col1 10k
RC2 vcc col2 10k

* Cross-coupling capacitors
C1 col1 base2 10n
C2 col2 base1 10n

* Base resistors
RB1 vcc base1 10k
RB2 vcc base2 10k

* Transistors
Q1 col1 base1 0 NPN1
Q2 col2 base2 0 NPN1

* Small initial asymmetry to start oscillation
VSTART base1 base1x DC 0.001
RSTART base1x 0 100MEG

.MODEL NPN1 NPN (BF=100 IS=1e-15 VAF=100 RB=10 RC=1 RE=0.5 CJE=2p CJC=1p TF=0.3n TR=6n)

.TRAN 10n 1m

.END
