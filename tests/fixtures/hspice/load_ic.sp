* HSPICE .load [CR .LOAD] inlines the .ic cards a .save TYPE=IC wrote
* (load_ic.ic0: v(b) = 0.25 V). Oracle: analytic; with UIC the capacitor
* starts at 0.25 V and charges through 1k from 1 V: v(b) = 1 - 0.75
* exp(-t / 1 us). Without the load it would start at 0.
* Expected results: load_ic.expected.json
v1 a 0 1
r1 a b 1k
c1 b 0 1n
.load file=load_ic.ic0
.tran 10n 5u uic
.end
