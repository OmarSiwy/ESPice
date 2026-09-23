* A PWL repeat time that is not one of its time points is refused (#73).
* Expected results: source_pwl_repeat_unmatched.expected.json
* ngspice vsrcpar.c: "repeat start time value ... does not match any time point given".
V1 a 0 PWL(0 0 1u 1 2u 0) r=0.5u
R1 a 0 1k
.tran 10n 5u
.end
