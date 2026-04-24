* ECL OR/NOR Gate
*
* VEE=-5.2V, differential pair with reference voltage
* Pull-down resistors, emitter followers on outputs
*

VEE vee 0 DC -5.2
VBB ref 0 DC -1.32

* Input signals
VA ina 0 PULSE(-1.7 -0.9 0 0.1n 0.1n 5n 10n)
VB inb 0 PULSE(-1.7 -0.9 2.5n 0.1n 0.1n 5n 10n)

* Collector pull-up resistors (to ground = VCC for ECL)
RC1 0 col1 220
RC2 0 col2 220

* Input differential pairs
* Q1A and Q1B share collector (OR function)
Q1A col1 ina tail NPN1
Q1B col1 inb tail NPN1

* Reference transistor
Q2 col2 ref tail NPN1

* Tail current source resistor
REE tail vee 780

* Output emitter followers
* NOR output (from col1 - inverted OR)
Q3 0 col1 nor_out NPN1
RNOR nor_out vee 2k

* OR output (from col2)
Q4 0 col2 or_out NPN1
ROR or_out vee 2k

.MODEL NPN1 NPN (BF=100 IS=1e-15 VAF=100 RB=10 RC=1 RE=0.5 CJE=2p CJC=1p TF=0.3n TR=6n)

.TRAN 0.1n 20n

.END
