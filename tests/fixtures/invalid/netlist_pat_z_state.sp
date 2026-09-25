* A PAT source with a Z (high-impedance) state is refused as unsupported (#63).
* Expected results: netlist_pat_z_state.expected.json
V1 a 0 PAT (1 0 0 1n 1n 5n b10z1)
R1 a 0 1k
.tran 1n 20n
.end
