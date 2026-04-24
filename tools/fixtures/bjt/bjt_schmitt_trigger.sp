* Schmitt Trigger with Hysteresis
*
* VCC=5V, two NPN transistors with common emitter resistor
* Positive feedback creates hysteresis
* PULSE input for testing switching thresholds
*

VCC vcc 0 DC 5

* Input: slow ramp via pulse
VIN in 0 PULSE(0 5 10u 80u 80u 10u 200u)

* Input resistor
RIN in base1 10k

* Q1: input transistor
Q1 col1 base1 emit NPN1

* Q1 collector load (also provides base drive for Q2)
RC1 vcc col1 4.7k

* Q2: output transistor, base driven from Q1 collector
RB2 col1 base2 10k
Q2 col2 base2 emit NPN1

* Q2 collector load
RC2 vcc col2 4.7k

* Common emitter resistor (creates positive feedback / hysteresis)
RE emit 0 1k

* Feedback from Q2 collector to Q1 base (positive feedback path)
RF col2 base1 47k

* Output
RLOAD col2 0 100k

.MODEL NPN1 NPN (BF=100 IS=1e-15 VAF=100 RB=10 RC=1 RE=0.5 CJE=2p CJC=1p TF=0.3n TR=6n)

.TRAN 1u 200u

.END
