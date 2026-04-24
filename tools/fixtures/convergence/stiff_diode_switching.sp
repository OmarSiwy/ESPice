* Stiff Diode Reverse Recovery — Fast Switching Stress Test
*
* Forward-biased diode suddenly reverse-biased by fast voltage step
* Very stiff ODE transition tests adaptive timestep and convergence

V1 in 0 PULSE(1 -5 10n 0.1n 0.1n 100n 200n)
R1 in a 50
D1 a 0 DMOD

.MODEL DMOD D (IS=1e-14 N=1 TT=5n CJO=2p)

.TRAN 0.01n 50n

.END
