* UIC magnitude and polarity
* Expected results: ic_negative.expected.json
R1 out 0 1k
C1 out 0 1u
.ic v(out)=-2
.tran 1u 5m uic
.end
