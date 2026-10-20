#!/usr/bin/env python3
"""MATCHA-style sizing sweep in plain HSPICE syntax: one asap7 template
(driver -> 2:1 transmission-gate mux -> wire RC pi -> 2-stage buffer ->
load), N sizing points in a .data table, per-point fins and per-point R/C
parasitics, .tran + delay/slew/energy .meas. Same file for HSPICE and ESPice.

Usage: gen_mux_sweep.py N [SEED] > deck.sp
"""
import random, sys

N = int(sys.argv[1])
seed = int(sys.argv[2]) if len(sys.argv) > 2 else 1
rng = random.Random(seed)

rows = []
for _ in range(N):
    nfd = rng.choice([1, 2, 3, 4])           # driver fins
    nft = rng.choice([1, 2, 3])              # transmission-gate fins
    nfb1 = rng.choice([1, 2, 3])             # buffer stage 1 fins
    nfb2 = rng.choice([2, 3, 4, 5, 6])       # buffer stage 2 fins
    rw = round(rng.uniform(50, 800), 3)      # wire R per pi segment (ohm)
    cw = round(rng.uniform(0.05, 0.6), 4)    # wire C per pi half (fF)
    cl = round(rng.uniform(0.5, 4.0), 4)     # load (fF)
    rows.append(f"+ {nfd} {nft} {nfb1} {nfb2} {rw} {cw}f {cl}f")

print(f"""* MATCHA-style FPGA tile sizing sweep: {N} points, seed {seed} (bench/matcha/gen_mux_sweep.py)
* asap7 TT, BSIM-CMG LEVEL 72. Template: driver inverter -> 2:1 transmission-gate mux
* (input a selected) -> wire RC pi (rw, cw) -> two-stage buffer -> load cl.
* Every sizing point is one .data row: per-point fins and per-point parasitics, as MATCHA
* sweeps them. Runs unchanged in HSPICE and ESPice (--tokenizer=hspice). See EXAMPLES.md.
.include '7nm_TT.pm'
.temp 27
.param vdd=0.7
.param nfd=2 nft=2 nfb1=2 nfb2=4 rw=200 cw=0.2f cl=1f

.subckt inv a y vdd nf=2
mp y a vdd vdd pmos_rvt nfin=nf
mn y a 0 0 nmos_rvt nfin=nf
.ends

.subckt tg a y en enb nf=2
mn a en y 0 nmos_rvt nfin=nf
mp a enb y vdd pmos_rvt nfin=nf
.ends

vdd vdd 0 'vdd'
vsel sel 0 'vdd'
vselb selb 0 0
vin in 0 pulse(0 'vdd' 50p 20p 20p 480p 1n)
vb b 0 0

xdrv in a vdd inv nf=nfd
xtga a m sel selb tg nf=nft
xtgb b m selb sel tg nf=nft
cw1 m 0 cw
rw1 m w rw
cw2 w 0 cw
xb1 w b1 vdd inv nf=nfb1
xb2 b1 out vdd inv nf=nfb2
cl out 0 cl

.tran 1p 1.2n sweep data=pts
.data pts nfd nft nfb1 nfb2 rw cw cl""")
print("\n".join(rows))
print(""".enddata

* in rises at 60 ps (50%) and falls at 560 ps; out is inverted (driver + two buffer stages).
.meas tran tpd_hl trig v(in) val='vdd/2' rise=1 targ v(out) val='vdd/2' fall=1
.meas tran tpd_lh trig v(in) val='vdd/2' fall=1 targ v(out) val='vdd/2' rise=1
.meas tran trise trig v(out) val='0.2*vdd' rise=1 targ v(out) val='0.8*vdd' rise=1
.meas tran tfall trig v(out) val='0.8*vdd' fall=1 targ v(out) val='0.2*vdd' fall=1
.meas tran e_cycle integ par('-vdd*i(vdd)') from=40p to=1.04n
.end""")
