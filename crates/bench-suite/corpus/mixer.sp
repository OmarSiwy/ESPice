* Diode passive mixer, transient
Vlo lo 0 SIN(0 1 1G)
Vrf rf 0 SIN(0 0.1 1.1G)
R1 lo a 50
R2 rf a 50
D1 a out DMOD
Rl out 0 1k
Cl out 0 1p
.model DMOD D(IS=1e-14 N=1.0)
.tran 50p 5n
.end
