* BJT Output Characteristics (Ic vs Vce, Stepped Ib)
* NPN BJT with swept collector-emitter voltage and stepped base current

VCE c 0 DC 0
IB 0 b DC 10u
Q1 c b 0 0 NPN1

.MODEL NPN1 NPN (BF=100 IS=1e-15 VAF=100 RB=10 RC=1 RE=0.5)

.DC VCE 0 5 0.01 IB 10u 100u 10u

.END
