* SFFM stimulus into an RC: single-frequency FM, the last independent-source
* waveform nothing in the suite exercised. PULSE, SIN and PWL are each covered
* several times over; EXP (tran/exp_source) and this one were not covered at all.
*
* This deck arrives with its ngspice column already FAILING, and that is the
* finding, not a target to fix. For SFFM(VO VA FC MDI FS) the defining formula
* is
*
*     v(t) = VO + VA * sin(2*pi*FC*t + MDI * sin(2*pi*FS*t))
*
* espice and VACASK each reproduce it to better than 1e-3. ngspice 44.2 emits a
* clean 10 kHz sinusoid instead — the MODULATING frequency as the carrier, with
* no modulation on it — so it disagrees with the closed form, with espice and
* with VACASK alike. Comma-separated and fully-expanded argument forms produce
* the same output, so it is not a misparse of this deck.
*
* The pairwise matrix is what this is for: the reference is the outlier here,
* and before that matrix existed a row like this one could only have been read
* as an espice regression.
V1 in 0 SFFM(0 1 100k 2 10k)
R1 in out 1k
C1 out 0 1n
.tran 100n 200u
.end
