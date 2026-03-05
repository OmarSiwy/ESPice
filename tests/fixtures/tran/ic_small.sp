* UIC magnitude and polarity
* Expected results: ic_small.expected.json
R1 out 0 1k
C1 out 0 1u
.ic v(out)=0.001
.tran 1u 5m uic
.end
