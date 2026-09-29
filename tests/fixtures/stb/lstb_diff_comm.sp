* Loop stability: differential and common-mode loops of a cross-coupled pair
* Expected results: lstb_diff_comm.expected.json
E1p ap 0 0 drvp 2
Exp a2p ap 0 drvn 0.5
R1p a2p bp 1k
C1p bp 0 1.5915494309189535e-07
E2p cp 0 bp 0 2
R2p cp dp 1k
C2p dp 0 1.5915494309189535e-07
E3p ep 0 dp 0 1
R3p ep fbkp 1k
C3p fbkp 0 1.5915494309189535e-07
Vp drvp fbkp 0
E1n an 0 0 drvn 2
Exn a2n an 0 drvp 0.5
R1n a2n bn 1k
C1n bn 0 1.5915494309189535e-07
E2n cn 0 bn 0 2
R2n cn dn 1k
C2n dn 0 1.5915494309189535e-07
E3n en 0 dn 0 1
R3n en fbkn 1k
C3n fbkn 0 1.5915494309189535e-07
Vn drvn fbkn 0
.ac dec 10 10 100k
.lstb mode=diff vsource=Vp,Vn
.lstb mode=comm vsource=Vp,Vn
.end
