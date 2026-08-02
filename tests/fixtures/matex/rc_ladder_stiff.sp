* Matrix-exponential transient of a stiff three-section RC ladder (#51): the
* Krylov space used to reach m = 4 on a rank-3 C through a round-off
* breakdown residual, and the inverted H_m sent every later point to NaN
* (exit 0). Oracle: ngspice 45 .tran of the same circuit at tmax = 50 ns,
* sampled at fixed times.
Vin in 0 PULSE(0 1 5e-07 1e-06 1e-06 0.0003333333333333333 0.001)
R1 in a 100
C1 a 0 1e-09
R2 a b 100000.0
C2 b 0 1e-12
R3 b c 10
C3 c 0 1e-07
.matex 5e-06 0.001
.end
