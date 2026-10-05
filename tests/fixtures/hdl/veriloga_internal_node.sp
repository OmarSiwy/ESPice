* A Verilog-A internal net publishes as ngspice names an OSDI device's: v(<instance>#<net>)
* Expected results: veriloga_internal_node.expected.json
.hdl "veriloga_internal_node.assets/vdiv2.va"
V1 in 0 DC 1
N1 in 0 vdiv2
.op
.end
