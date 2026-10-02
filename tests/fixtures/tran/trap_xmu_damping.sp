* .options xmu damps the trapezoid's ringing on a capacitor-only current
* Expected results: trap_xmu_damping.expected.json
* v(out) steps quickly as v(in) crosses 0.5 V, at no breakpoint, so the
* step that takes the edge integrates with the trapezoid, whose ringing in
* i(vm) never decays at xmu = 0.5 (+-4e-4 A in ngspice-44.2 and espice).
* xmu = 0.45 multiplies the ringing by 0.45/0.55 per step.
Vin in 0 PWL(0 0 1u 1)
B1 out 0 V=tanh(50*(v(in)-0.5))
Vm out a 0
C1 a 0 1n
.options xmu=0.45
.tran 10n 1u
.end
