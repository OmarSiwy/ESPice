* .tran 1u 100u 90u caps the step at min(tstep, (tstop - tstart)/50) = 0.2u
* (ngspice traninit.c:29-34), so the saved window holds 51 points (#56).
* Oracle: ngspice 45 saves 51 points from 90.12u to 100u.
* Expected results: tstart_tmax_ngspice.expected.json
V1 in 0 sin(0 1 10k)
R1 in 0 1k
.tran 1u 100u 90u
.end
