* HSPICE MOSRA level 1: one NMOS under constant DC stress, Vgs = 1.2 V,
* Vds = 1.5 V. Constant stress makes each mechanism's power law closed form:
*   BTI  dVth = tit0*exp(titfd*Vgs)*t^tn  = 1e-4*exp(0.6)*t^0.25
*   HCI  dVth = hci0*exp(hcifd*Vds)*t^hcin = 2e-6*t^0.5
*   delvto = BTI + HCI, mulu0 = 1/(1 + hcimu*HCI)
* at the reliability times 5e7 s and 1e8 s (RelStep), and the DegF = 0.05 V
* lifetime where BTI + HCI reaches 0.05 V.
* Expected results: nmos_dc_stress.expected.json
vd d 0 1.5
vg g 0 1.2
m1 d g 0 0 n3 w=10u l=0.18u
.model n3 nmos(level=49 version=3.3 tnom=27 tox=4.1e-9 vth0=0.35 k1=0.53 k2=-0.06 k3=80 nlx=1.74e-7 vsat=1.5e5 ua=-1.4e-9 ub=2.3e-18 uc=-4.6e-11 rdsw=200 u0=280 pclm=1.3 pdiblc1=0.39 pdiblc2=0.0086 nfactor=1.5 cdsc=0 voff=-0.1)
.model nra mosra level=1 tit0=1e-4 titfd=0.5 tn=0.25 hci0=2e-6 hcin=0.5 hcimu=0.1
.appendmodel nra mosra n3 nmos
.mosra reltotaltime=1e8 relstep=5e7 simmode=0 degf=0.05
.tran 1n 10n
.end
