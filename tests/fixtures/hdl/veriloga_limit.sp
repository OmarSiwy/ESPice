* User-defined limiter must preserve the exact equation root, V(out)=2.
.hdl "veriloga_limit.assets/va_limit.va"
N1 out 0 va_limit
.options reltol=1e-10 vntol=1e-12 abstol=1e-14
.op
.end
