* Loop stability: three identical 1 kHz poles, DC loop gain 4
* Expected results: lstb_three_pole.expected.json
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
.end
