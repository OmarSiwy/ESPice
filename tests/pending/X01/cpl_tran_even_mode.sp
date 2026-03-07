* X01 pending fixture: CPL two-conductor EVEN mode, matched to Ze.
* The matrices are chosen so the medium is homogeneous (Le*Ce = Lo*Co) and both
* modal impedances are integers:
*   L = [[250n,150n],[150n,250n]],  C = [[100p,-60p],[-60p,100p]], length = 2 m
*   even: Le = L11+L12 = 400 nH/m, Ce = C11+C12 =  40 pF/m
*   odd : Lo = L11-L12 = 100 nH/m, Co = C11-C12 = 160 pF/m
*   Ze = sqrt(400n/40p)  = sqrt(10000) = 100 ohm
*   Zo = sqrt(100n/160p) = sqrt(625)   =  25 ohm
*   Le*Ce = Lo*Co = 1.6e-17 s^2/m^2 -> both modes travel at 4 ns/m, Td = 8 ns.
* Driving BOTH conductors from one source through equal 100 ohm resistors and
* terminating both far ends in 100 ohm excites the even mode alone and matches it,
* so the pair behaves as a single matched 100 ohm line:
*   v(a1) = v(a2) = 1 * Ze/(Rs+Ze) = 0.5   for t > 10 ps
*   v(b1) = v(b2) = 0.5 delayed by Td = 8 ns
* Hand-derived samples:
*   t =  4.0 ns  v(a1)=v(a2)=0.5  v(b1)=v(b2)=0    (before arrival)
*   t =  7.9 ns  v(a1)=v(a2)=0.5  v(b1)=v(b2)=0    (100 ps before arrival, pins Td)
*   t =  8.2 ns  v(a1)=v(a2)=0.5  v(b1)=v(b2)=0.5  (200 ps after arrival)
*   t = 20.0 ns  v(a1)=v(a2)=0.5  v(b1)=v(b2)=0.5
*   t = 39.0 ns  v(a1)=v(a2)=0.5  v(b1)=v(b2)=0.5  (DC check 100/200 = 0.5)
* Discriminator: ignoring the mutual terms gives Z0 = sqrt(250n/100p) = 50 ohm
* against 100 ohm terminations, i.e. GammaS = GammaL = -1/3 and a decaying
* staircase instead of a flat 0.5.  Independent ngspice-44.2 agreement: <= 1.5e-9.
* Expected results: cpl_tran_even_mode.expected.json
Vs in 0 PULSE(0 1 0 10p 10p 500n 1u)
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
.tran 20p 40n 0 20p
.end
