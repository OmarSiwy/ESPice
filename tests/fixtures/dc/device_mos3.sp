* NMOS Level 3 (empirical short-channel) output and transfer.
* Expected results: device_mos3.expected.json
* Origin: benchmark/fixtures/devices/mos3/circuit.sp
* Tests non-uniform doping and short-channel effects.
Vds drain 0 DC 0
Vgs gate 0 DC 0
M1 drain gate 0 0 NMOD W=10u L=1u
.model NMOD NMOS(LEVEL=3 VTO=0.7 KP=120u GAMMA=0.4 PHI=0.65 THETA=0.1 ETA=0.05 KAPPA=0.5 TOX=40n NFS=1e11)
.dc Vds 0 5 0.025 Vgs 0 5 0.5
.end
