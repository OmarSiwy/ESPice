* asap7 TT inverter sizing template for MATCHA (ESPice >= v1.1.0, built-in level 72).
* Live params: nfp, nfn (fins), cl (load). Run: espice --tokenizer=hspice inv_template.sp
* Swap 7nm_TT.pm for 7nm_FF.pm / 7nm_SS.pm for corners (same cards, so same topology).
.include "/home/omare/Documents/University/ECE636/MiniProj1/.schemify/pdks/asap7/58d72c9d291e186a77468586ab0c43d8a21eda6a/root/models/hspice/7nm_TT.pm"
.temp 27
.param nfp=2 nfn=2 cl=1f
Mp out a vdd vdd pmos_rvt nfin=nfp
Mn out a 0 0 nmos_rvt nfin=nfn
VDD vdd 0 0.7
VIN a 0 pulse(0 0.7 20p 10p 10p 90p 200p)
CL out 0 cl
.tran 1p 250p sweep data=pts
.data pts nfp nfn cl
+ 1 1 0.5f
+ 2 2 1f
+ 3 2 2f
+ 4 3 2f
.enddata
.meas tran tphl trig v(a) val=0.35 rise=1 targ v(out) val=0.35 fall=1
.meas tran tplh trig v(a) val=0.35 fall=1 targ v(out) val=0.35 rise=1
.meas tran tfall trig v(out) val=0.56 fall=1 targ v(out) val=0.14 fall=1
.meas tran trise trig v(out) val=0.14 rise=1 targ v(out) val=0.56 rise=1
.meas tran e_sw integ par('-v(vdd)*i(vdd)') from=15p to=200p
.end
