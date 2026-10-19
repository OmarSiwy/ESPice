# Writes chain24.sp: 24 asap7 inverters (BSIM-CMG, LEVEL 72) with an RC wire
# after each, pulse input, .tran 1p 1.5n, three .meas. Usage: gen_chain.py PM
# where PM is asap7's 7nm_TT_160803.pm (lambdapdk asap7/base/spice/hspice).
import sys
P, N = sys.argv[1], 24
L = ["* MATCHA-like: 24-stage asap7 inverter chain with RC wires",
     f".include '{P}'",
     ".param nfn=3 nfp=3 rw=200 cw=0.5f",
     "vdd vdd 0 0.7",
     "vin in 0 pulse(0 0.7 50p 10p 10p 400p 1n)"]
prev = "in"
for i in range(N):
    o, w = f"o{i}", f"w{i}"
    L += [f"mp{i} {o} {prev} vdd vdd pmos_rvt l=20n nfin={{nfp}}",
          f"mn{i} {o} {prev} 0 0 nmos_rvt l=20n nfin={{nfn}}",
          f"r{i} {o} {w} {{rw}}", f"c{i} {w} 0 {{cw}}"]
    prev = w
L += [".tran 1p 1.5n",
      f".meas tran tpd trig v(in) val=0.35 rise=1 targ v({prev}) val=0.35 rise=1",
      f".meas tran trise trig v({prev}) val=0.07 rise=1 targ v({prev}) val=0.63 rise=1",
      f".meas tran tfall trig v({prev}) val=0.63 fall=1 targ v({prev}) val=0.07 fall=1",
      ".end"]
open("chain24.sp", "w").write("\n".join(L) + "\n")
