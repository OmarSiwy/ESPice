* Ideal transmission line in AC: the far end lags by the line delay.
* KNOWN GAP: absdelay's small-signal form is the static pass-through, so AC sees a transparent line (magnitude right, no e^(-jw*TD) phase).
* Expected results: device_tline_delay.expected.json
* Matched source, 100 ohm load: |v(b)| = 2/3 at phase -360*f*TD degrees; v(a) moves with the reflected wave.
Vin in 0 DC 0 AC 1
Rs in a 50
T1 a 0 b 0 Z0=50 TD=1n
RL b 0 100
.ac lin 6 50meg 300meg
.end
