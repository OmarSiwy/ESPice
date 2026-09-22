* X01 pending fixture: LTRA small-signal AC must rotate phase with frequency.
* Z0 = sqrt(l/c) = sqrt(250n/100p) = 50 ohm, Td = len*sqrt(l*c) = 2*5n = 10 ns.
*
* CORRECTED AFTER REVIEW, twice.
* (1) Teeth.  The previous deck terminated in RL = 50 = Z0.  A load matched to
*     Z0 makes Zin = Zc at every frequency, so v(a) = 0.5 + 0j at every point --
*     which is also what the host's DC-resistance fallback returns.  17 of the
*     24 asserted values were therefore satisfiable with no AC stamp at all;
*     only 7 v(b) rows discriminated.  The load is now RL = 150 = 3*Z0, which
*     makes BOTH v(a) and v(b) frequency-dependent, and the eight frequencies
*     are moved off the multiples of pi/2 where the phasor turns real and would
*     coincide with the DC answer again.  All 24 values now discriminate.
* (2) Arithmetic.  The old header said the DC-resistance fallback returns
*     0.495049504950495+j0.  That is ltra_op_series_resistance's number (r=0.5,
*     R_line = 1 ohm).  This deck has r=1e-6, R_line = r*len = 2e-6, so the
*     fallback is v(a) = (150+2e-6)/200.000002 = 0.7500000025000000 and
*     v(b) = 150/200.000002 = 0.7499999925000000.  Confirmed by running the
*     checkpoint binary: it returns exactly those two numbers, purely real, at
*     all eight frequencies.
*
* Closed form.  Rs = Z0, so the source end is reflectionless: a fixed forward
* wave of Vs/2 = 0.5 travels once, reflects at the load with
*   GammaL = (RL - Z0)/(RL + Z0) = (150-50)/(150+50) = 0.5,
* and returns to the source end without re-reflecting.  With theta = w*Td,
*   v(a) = 0.5*(1 + GammaL*exp(-2j*theta))     (circle, radius 0.25 about 0.5)
*   v(b) = 0.5*(1 + GammaL)*exp(-j*theta) = 0.75*exp(-j*theta)   (pure rotation)
* Frequencies: theta = (2k-1)*pi/8, k = 1..8, i.e. f = (2k-1)*6.25 MHz =
* 6.25, 18.75, ... 93.75 MHz -- 337.5 degrees of one turn of v(b), deliberately
* skipping the multiples of pi/2 (k*pi/4 would have hit theta = pi and 2*pi,
* where v(a) collapses to the real 0.75 of the DC stamp).  Because 2*theta has
* period 4 in k, v(a) takes four distinct values and v(b) eight; none of the
* twelve is real, and the closest any of them comes to the DC answer is
* |(0.676776698-0.176776694j) - 0.750000003| = sqrt(0.073223^2 + 0.176777^2)
* = 0.19134171, i.e. 9567x the 2e-5 rtol asserted below.  (The "0.28" written
* here before the review was the v(b) margin quoted as if it bounded both
* columns; the binding margin is v(a)'s 0.19134171.)
*
* The checked-in numbers are the EXACT telegrapher solution with r=1e-6 kept in
*   Zc = sqrt((r+jwl)/(g+jwc)),  gamma = sqrt((r+jwl)(g+jwc)),  gL = gamma*len
*   Zin = Zc(RL + Zc tanh(gL))/(Zc + RL tanh(gL)),  v(a) = Zin/(Rs+Zin),
*   v(b) = v(a)/(cosh(gL) + (Zc/RL) sinh(gL)),  i(vin) = -(1 - v(a))/Rs,
* which differs from the ideal lossless form above only by the total attenuation
* alpha*L = r*len/(2*Z0) = 2e-6/100 = 2e-8 Np -- and the two agree to 1.7e-8,
* so the ideal hand derivation is an independent check on the tabulated exact
* one.  An independent ngspice-44.2 run of this exact netlist reproduces all 24
* tabulated values to <= 1.3e-15.
* Expected results: ltra_ac_lossless_limit.expected.json
Vin in 0 AC 1
Rs in a 50
O1 a 0 b 0 lline
RL b 0 150
.model lline LTRA(r=1e-6 l=250n g=0 c=100p len=2 rel=1)
.ac lin 8 6.25meg 93.75meg
.end
