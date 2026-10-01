* Loop stability with localgnd: stb/lstb_three_pole lifted onto node lg,
* which reaches ground only through Rg. Injecting from lg and reading
* against lg sees the same loop as the grounded deck; injecting from
* ground would send the probe current back through Rg.
* Expected results: lstb_localgnd.expected.json
E1 a2 lg lg drv 2
R1 a2 b 1k
C1 b lg 1.5915494309189535e-07
E2 c lg b lg 2
R2 c d 1k
C2 d lg 1.5915494309189535e-07
E3 e lg d lg 1
R3 e fbk 1k
C3 fbk lg 1.5915494309189535e-07
Vprobe drv fbk 0
Rg lg 0 1k
.ac dec 10 10 100k
.lstb mode=single vsource=Vprobe localgnd=lg
.end
