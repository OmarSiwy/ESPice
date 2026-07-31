* CPL even mode (cpl_tran_even_mode's line) run at a forced 1 ps step, so the
* 8 ns delay reads an entry ~8000 accepted points back, past the 2048-point
* history capacity of coupled_ltra.va (#105).
* Matched even mode, Ze = 100 ohm, Td = 8 ns: the 6 ns source edge reaches the
* far end at 14 ns.
*   t =  4.0 ns  v(a1)=0    v(b1)=0
*   t = 10.0 ns  v(a1)=0.5  v(b1)=0
*   t = 13.9 ns  v(a1)=0.5  v(b1)=0    (100 ps before arrival)
*   t = 14.2 ns  v(a1)=0.5  v(b1)=0.5
*   t = 15.9 ns  v(a1)=0.5  v(b1)=0.5
* Dropping the oldest live entry when the history fills publishes the edge at
* about 6 ns + 2048 ps + Td instead.
Vs in 0 PULSE(0 1 6n 10p 10p 500n 1u)
Rs1 in a1 100
Rs2 in a2 100
P1 a1 a2 0 b1 b2 0 cmod
RL1 b1 0 100
RL2 b2 0 100
.model cmod CPL
+R = 1e-6 0 1e-6
+L = 250n 150n
+     250n
+C = 100p -60p
+     100p
+G = 0 0 0
+length = 2
.tran 1p 16n 0 1p
.end
