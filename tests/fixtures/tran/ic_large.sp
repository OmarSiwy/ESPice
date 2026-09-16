* UIC magnitude and polarity
* Expected results: ic_large.expected.json
R1 out 0 1k
C1 out 0 1u
.ic v(out)=100
.tran 1u 5m uic
.end
