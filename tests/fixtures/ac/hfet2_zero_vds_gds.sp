* HFET2 output conductance at exactly vds = 0 (#47): the channel is on
* (vgs = 0 > VTO), and the drain small-signal current is gds*v(d). A
* max(|vds|, 1e-30) floor made gds 0 there.
VD d 0 DC 0 AC 1
VG g 0 0
Z1 d g 0 hm
.model hm NHFET LEVEL=6
.ac dec 1 1k 1meg
.end
