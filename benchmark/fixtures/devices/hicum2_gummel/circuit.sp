* HICUM/L2 NPN Gummel plot: Ic and Ib vs Vbe.
* Tests HICUM diode currents, recombination, tunneling.
Vce col 0 DC 3
Vbe base 0 DC 0
Q1 col base 0 0 hic2
.model hic2 NPN(LEVEL=8 TNOM=300.15 C10=2e-30 QP0=2e-14 ICH=0 IBEIS=1e-18 MBEI=1 IREIS=1e-15 MREI=2 IBEPS=0 MBEP=1 IBCIS=1e-16 MBCI=1 IBCXS=0 MBCX=1 RBI0=50 RBX=20 RE=2 RCX=10)
.dc Vbe 0.3 0.95 0.005
.end
