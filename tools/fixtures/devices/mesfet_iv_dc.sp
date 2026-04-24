* GaAs MESFET I-V Characteristics — DC sweep Id vs Vds
*
* Z1 is a GaAs N-channel MESFET (NMF type)
* Nodes: drain gate source
Z1 drain gate 0 NMESFET
VDS drain 0 3
VGS gate 0 -0.5
*
.model NMESFET NMF LEVEL=1 VTO=-1.8 BETA=0.1 ALPHA=2 LAMBDA=0.05
+ RD=1 RS=1 IS=1E-14 N=1 CGS=1P CGD=0.5P
*
.options noacct
.dc VDS 0 3 0.1 VGS -1.5 0 0.5
.print DC I(VDS) V(drain)
.END
