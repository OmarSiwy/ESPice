* Clocked RC chain emulating a digital buffer delay line (transient edges).
Vclk clk 0 DC 0 PULSE(0 5 0 1n 1n 50n 100n)
R1 clk n1 1k
C1 n1 0 10p
R2 n1 n2 1k
C2 n2 0 10p
R3 n2 out 1k
C3 out 0 10p
.tran 1n 400n
.end
