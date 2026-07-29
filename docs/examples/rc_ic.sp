Capacitor discharge from an initial condition
* UIC skips the operating point and starts from the .ic values.
R1 top 0 1k
C1 top 0 1u
.ic v(top)=5
.tran 10u 5m uic
.meas tran vtau FIND v(top) AT=1m
.end
