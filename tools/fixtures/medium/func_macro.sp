* M14: Parameter Expressions and Functions — .PARAM with arithmetic
.PARAM vdd_val=3.3
.PARAM r_val='1k*2'
V1 in 0 DC {vdd_val}
R1 in out {r_val}
R2 out 0 {r_val/2}
.OP
.END
