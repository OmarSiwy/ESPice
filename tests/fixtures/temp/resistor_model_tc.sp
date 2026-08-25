* A resistor .model card's TC1/TC2/TNOM reach the instance (#159)
* Expected results: resistor_model_tc.expected.json
V1 a 0 1
R1 a 0 1k rm
V2 b 0 1
R2 b 0 1k rn
.model rm R(TC1=2e-3 TC2=1e-5)
.model rn R(TC1=1e-2 TNOM=35)
.temp 85
.op
.end
