* Unit fixture: lossy transmission line (LTRA), matched pulse.
Vin in 0 DC 0 PULSE(0 1 1n 0.5n 0.5n 5n 20n)
Rs in a 50
O1 a 0 b 0 ltra1
RL b 0 50
.model ltra1 LTRA(r=0.5 l=250n c=100p len=2)
.tran 0.05n 30n
.end
