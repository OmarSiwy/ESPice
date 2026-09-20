* Two equal 1 V sources in parallel (#70): KVL holds, but no equation fixes
* how the load current splits between them, so the operating point is not
* unique. Oracle: ngspice 45 stops ("singular matrix", the operating point
* could not be simulated); ESPice names the loop.
* Expected results: topology_parallel_voltage_sources.expected.json
V1 a 0 1
V2 a 0 1
R1 a 0 1k
.op
.end
