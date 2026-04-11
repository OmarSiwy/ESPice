* Monte Carlo Parameter Sweep — RC Filter Corner Frequency
*
* Demonstrates: .SAMPLING (quasi-Monte Carlo), .PARAM with tolerances,
*               .STEP, .MEASURE across a statistical ensemble
*
* Sweeps 200 Latin-Hypercube samples over R and C tolerances (1% and 5%).
* For each sample a .TRAN is run and the 50%-crossing time of the step response
* is measured to characterise the spread of the filter time constant.
*
* Requires Wave Q.6 (.SAMPLING LHS) to be fully implemented; on earlier builds
* replace .SAMPLING with .STEP LIST or run repeated .DC/.TRAN manually.

.PARAM  R_NOM=1k   R_TOL=0.01    * 1 % resistor
.PARAM  C_NOM=100n  C_TOL=0.05   * 5 % capacitor

* DEV= gives per-instance independent variation
.MODEL RMOD RES (TC1=0  DEV={R_TOL})
.MODEL CMOD CAP (TC1=0  DEV={C_TOL})

Vstep  vin  0  PULSE(0 1 0 1n 1n 5u 10u)

R1  vin  out  {R_NOM}  MODEL=RMOD
C1  out  0   {C_NOM}  MODEL=CMOD

.TRAN  10n  5u

.MEAS  TRAN  t50  CROSS  V(out)  VAL=0.5  RISE=1

.SAMPLING  N=200  METHOD=LHS  SEED=42

.PRINT  TRAN  V(vin)  V(out)

.END
