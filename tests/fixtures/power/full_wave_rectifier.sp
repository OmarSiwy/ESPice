* Full-Wave Diode Bridge Rectifier
*
* 4 diodes in bridge configuration
* AC source: SIN(0 10 60) — 10V peak, 60Hz mains
* R_load=1k, C_filter=100uF
* Output: ~10 - 2*0.7 = 8.6V DC (with ripple)

.MODEL DMOD D (IS=1e-14 N=1.05 RS=10 BV=100 IBV=100u CJO=2p TT=5n)

* AC mains source
V1 ac_p ac_n SIN(0 10 60)

* Bridge rectifier
* D1: ac_p -> out_p (positive half)
D1 ac_p out_p DMOD
* D2: out_n -> ac_p (return path for positive half)
D2 out_n ac_p DMOD
* D3: ac_n -> out_p (negative half, reversed)
D3 ac_n out_p DMOD
* D4: out_n -> ac_n (return path for negative half)
D4 out_n ac_n DMOD

* Ground reference for output
* The negative output rail is ground
R_gnd out_n 0 0.001

* Filter capacitor and load
C_filter out_p out_n 100u
R_load out_p out_n 1k

.TRAN 100u 100m

.END
