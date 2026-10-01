* HSPICE .measure LSTB [CR .MEASURE]: the margin keywords and lstb(db|p|m)
* over the loop gain of stb/lstb_three_pole (three identical 1 kHz poles,
* DC loop gain 4). Oracle: analytic, W = 4/(1+jf/1k)^3.
* Expected results: meas_lstb.expected.json
E1 a2 0 0 drv 2
R1 a2 b 1k
C1 b 0 1.5915494309189535e-07
E2 c 0 b 0 2
R2 c d 1k
C2 d 0 1.5915494309189535e-07
E3 e 0 d 0 1
R3 e fbk 1k
C3 fbk 0 1.5915494309189535e-07
Vprobe drv fbk 0
.ac dec 10 10 100k
.lstb mode=single vsource=Vprobe
.measure lstb pm phase_margin
.measure lstb gm gain_margin
.measure lstb ugf unity_gain_freq
.measure lstb f0 when lstb(db)=0
.measure lstb ph find lstb(p) at=1k
.measure lstb mag find lstb(m) at=1k
.end
