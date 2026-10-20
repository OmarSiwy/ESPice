* MATCHA-style FPGA tile sizing sweep: 16 points, seed 1 (bench/matcha/gen_mux_sweep.py)
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
.data pts nfd nft nfb1 nfb2 rw cw cl
+ 2 3 1 4 138.439 0.4685f 2.1529f
+ 4 1 1 5 71.261 0.5097f 2.0147f
+ 1 3 2 4 591.155 0.1758f 3.8084f
+ 3 1 1 2 537.16 0.0551f 3.5843f
+ 2 2 3 2 445.722 0.47f 3.7871f
+ 2 2 1 3 620.711 0.5737f 3.7428f
+ 4 3 3 2 189.43 0.5959f 3.5098f
+ 1 3 2 6 752.33 0.2822f 3.4051f
+ 2 2 2 6 780.089 0.3246f 3.7932f
+ 4 3 1 5 232.055 0.4886f 1.9501f
+ 2 2 3 4 114.851 0.4151f 0.8778f
+ 2 3 2 4 417.27 0.0663f 0.6522f
+ 4 3 1 3 426.679 0.5901f 3.1968f
+ 2 2 3 4 764.351 0.3678f 2.107f
+ 3 3 3 6 767.837 0.0531f 3.2428f
+ 2 3 3 3 369.568 0.0809f 3.545f
.enddata

* in rises at 60 ps (50%) and falls at 560 ps; out is inverted (driver + two buffer stages).
.meas tran tpd_hl trig v(in) val='vdd/2' rise=1 targ v(out) val='vdd/2' fall=1
.meas tran tpd_lh trig v(in) val='vdd/2' fall=1 targ v(out) val='vdd/2' rise=1
.meas tran trise trig v(out) val='0.2*vdd' rise=1 targ v(out) val='0.8*vdd' rise=1
.meas tran tfall trig v(out) val='0.8*vdd' fall=1 targ v(out) val='0.2*vdd' fall=1
.meas tran e_cycle integ par('-vdd*i(vdd)') from=40p to=1.04n
.end
