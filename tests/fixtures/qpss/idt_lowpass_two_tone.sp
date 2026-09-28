* Verilog-A idt lowpass under two incommensurate tones: QPSS integrates it
* Expected results: idt_lowpass_two_tone.expected.json
* The idt with ic is the RC of linear_two_tone_1_1 (wc = 1/RC), so the spectra match it.
.hdl "idt_lowpass_two_tone.assets/va_idt_lp.va"
V1 a 0 SIN(0 1 1000)
V2 in a SIN(0 0.5 1414.213562373095)
N1 in out va_idt_lp wc=1000
.qpss 1000 1414.213562373095 1 1
.end
