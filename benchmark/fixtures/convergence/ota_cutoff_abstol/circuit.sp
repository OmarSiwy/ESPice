* 5T OTA at the abstol floor -- CONVERGENCE-GATE STRESS, NOT AN ACCURACY REFERENCE
* ============================================================================
* Deliberately biased into cutoff: VBIAS=0.55 against VTO=0.7 puts every tail
* device off, so EVERY branch current in this deck is 1.368e-12 A against the
* default abstol of 1e-12 A -- 1.4x the gate. The AC gain of v(d1_i) is a
* ratio of two gate overdrives of 30 uV and 113 uV, and abstol/gm3 is 86 uV of
* freedom on that node, i.e. 76% of vgst3.
*
* CONSEQUENCE, READ THIS BEFORE REPORTING A NUMBER FROM THIS DECK:
* no engine at default tolerances resolves this operating point. ngspice
* misses KCL at d1_1 by 2.7x abstol, espice by 21x. The resulting ~3.2e5
* deviation between any two simulators here is the distance between two
* stopping points INSIDE the convergence tolerance. It is NOT a model
* discrepancy and must never be scored as one. Asked to converge
* (.options abstol=1e-18 reltol=1e-10 vntol=1e-12) ngspice and espice agree
* to 8.6e-11 normalized over all signals.
*
* What this deck is for: exercising the Newton convergence gate on a circuit
* whose entire signal sits at the tolerance floor. Judge it on whether an
* engine converges at all and how far it lands from the tolerance-converged
* reference -- never on engine-vs-engine deviation at default tolerances.
*
* The accuracy/scaling version of this circuit is benchmark/fixtures/sweep/
* opamp_wl_{200,1000,5000}, re-biased to VBIAS=1.0. Full diagnosis:
* docs/perf/mos1-ac-2026-09-10.md and docs/perf/fixture-bias-2026-09-10.md.
* ============================================================================
* 5T OTA W/L sweep: 20x10 = 200 independent instances
* Sweep differential pair W: 20 points [0.5u..50u]
* Sweep differential pair L: 10 points [0.1u..5u]
* Load/tail transistors fixed. Each instance electrically independent.
*
.model nch NMOS(level=1 VTO=0.7 KP=110u GAMMA=0.4 LAMBDA=0.04 PHI=0.65)
.model pch PMOS(level=1 VTO=-0.7 KP=50u GAMMA=0.57 LAMBDA=0.05 PHI=0.65)
*
Vdd vdd 0 DC 1.8
Vbias vbias 0 DC 0.55
Vinp inp 0 DC 0.9 AC 1
Vinn inn 0 DC 0.9
* --- Instance 1: W=0.500u L=0.100u ---
M1_1 d1_1 inp tail_1 0 nch W=0.500u L=0.100u
M2_1 out_1 inn tail_1 0 nch W=0.500u L=0.100u
M3_1 d1_1 d1_1 vdd vdd pch W=2u L=1u
M4_1 out_1 d1_1 vdd vdd pch W=2u L=1u
M5_1 tail_1 vbias 0 0 nch W=4u L=1u
Cl_1 out_1 0 100f
* --- Instance 2: W=0.500u L=0.154u ---
M1_2 d1_2 inp tail_2 0 nch W=0.500u L=0.154u
M2_2 out_2 inn tail_2 0 nch W=0.500u L=0.154u
M3_2 d1_2 d1_2 vdd vdd pch W=2u L=1u
M4_2 out_2 d1_2 vdd vdd pch W=2u L=1u
M5_2 tail_2 vbias 0 0 nch W=4u L=1u
Cl_2 out_2 0 100f
* --- Instance 3: W=0.500u L=0.239u ---
M1_3 d1_3 inp tail_3 0 nch W=0.500u L=0.239u
M2_3 out_3 inn tail_3 0 nch W=0.500u L=0.239u
M3_3 d1_3 d1_3 vdd vdd pch W=2u L=1u
M4_3 out_3 d1_3 vdd vdd pch W=2u L=1u
M5_3 tail_3 vbias 0 0 nch W=4u L=1u
Cl_3 out_3 0 100f
* --- Instance 4: W=0.500u L=0.368u ---
M1_4 d1_4 inp tail_4 0 nch W=0.500u L=0.368u
M2_4 out_4 inn tail_4 0 nch W=0.500u L=0.368u
M3_4 d1_4 d1_4 vdd vdd pch W=2u L=1u
M4_4 out_4 d1_4 vdd vdd pch W=2u L=1u
M5_4 tail_4 vbias 0 0 nch W=4u L=1u
Cl_4 out_4 0 100f
* --- Instance 5: W=0.500u L=0.569u ---
M1_5 d1_5 inp tail_5 0 nch W=0.500u L=0.569u
M2_5 out_5 inn tail_5 0 nch W=0.500u L=0.569u
M3_5 d1_5 d1_5 vdd vdd pch W=2u L=1u
M4_5 out_5 d1_5 vdd vdd pch W=2u L=1u
M5_5 tail_5 vbias 0 0 nch W=4u L=1u
Cl_5 out_5 0 100f
* --- Instance 6: W=0.500u L=0.879u ---
M1_6 d1_6 inp tail_6 0 nch W=0.500u L=0.879u
M2_6 out_6 inn tail_6 0 nch W=0.500u L=0.879u
M3_6 d1_6 d1_6 vdd vdd pch W=2u L=1u
M4_6 out_6 d1_6 vdd vdd pch W=2u L=1u
M5_6 tail_6 vbias 0 0 nch W=4u L=1u
Cl_6 out_6 0 100f
* --- Instance 7: W=0.500u L=1.357u ---
M1_7 d1_7 inp tail_7 0 nch W=0.500u L=1.357u
M2_7 out_7 inn tail_7 0 nch W=0.500u L=1.357u
M3_7 d1_7 d1_7 vdd vdd pch W=2u L=1u
M4_7 out_7 d1_7 vdd vdd pch W=2u L=1u
M5_7 tail_7 vbias 0 0 nch W=4u L=1u
Cl_7 out_7 0 100f
* --- Instance 8: W=0.500u L=2.096u ---
M1_8 d1_8 inp tail_8 0 nch W=0.500u L=2.096u
M2_8 out_8 inn tail_8 0 nch W=0.500u L=2.096u
M3_8 d1_8 d1_8 vdd vdd pch W=2u L=1u
M4_8 out_8 d1_8 vdd vdd pch W=2u L=1u
M5_8 tail_8 vbias 0 0 nch W=4u L=1u
Cl_8 out_8 0 100f
* --- Instance 9: W=0.500u L=3.237u ---
M1_9 d1_9 inp tail_9 0 nch W=0.500u L=3.237u
M2_9 out_9 inn tail_9 0 nch W=0.500u L=3.237u
M3_9 d1_9 d1_9 vdd vdd pch W=2u L=1u
M4_9 out_9 d1_9 vdd vdd pch W=2u L=1u
M5_9 tail_9 vbias 0 0 nch W=4u L=1u
Cl_9 out_9 0 100f
* --- Instance 10: W=0.500u L=5.000u ---
M1_10 d1_10 inp tail_10 0 nch W=0.500u L=5.000u
M2_10 out_10 inn tail_10 0 nch W=0.500u L=5.000u
M3_10 d1_10 d1_10 vdd vdd pch W=2u L=1u
M4_10 out_10 d1_10 vdd vdd pch W=2u L=1u
M5_10 tail_10 vbias 0 0 nch W=4u L=1u
Cl_10 out_10 0 100f
* --- Instance 11: W=0.637u L=0.100u ---
M1_11 d1_11 inp tail_11 0 nch W=0.637u L=0.100u
M2_11 out_11 inn tail_11 0 nch W=0.637u L=0.100u
M3_11 d1_11 d1_11 vdd vdd pch W=2u L=1u
M4_11 out_11 d1_11 vdd vdd pch W=2u L=1u
M5_11 tail_11 vbias 0 0 nch W=4u L=1u
Cl_11 out_11 0 100f
* --- Instance 12: W=0.637u L=0.154u ---
M1_12 d1_12 inp tail_12 0 nch W=0.637u L=0.154u
M2_12 out_12 inn tail_12 0 nch W=0.637u L=0.154u
M3_12 d1_12 d1_12 vdd vdd pch W=2u L=1u
M4_12 out_12 d1_12 vdd vdd pch W=2u L=1u
M5_12 tail_12 vbias 0 0 nch W=4u L=1u
Cl_12 out_12 0 100f
* --- Instance 13: W=0.637u L=0.239u ---
M1_13 d1_13 inp tail_13 0 nch W=0.637u L=0.239u
M2_13 out_13 inn tail_13 0 nch W=0.637u L=0.239u
M3_13 d1_13 d1_13 vdd vdd pch W=2u L=1u
M4_13 out_13 d1_13 vdd vdd pch W=2u L=1u
M5_13 tail_13 vbias 0 0 nch W=4u L=1u
Cl_13 out_13 0 100f
* --- Instance 14: W=0.637u L=0.368u ---
M1_14 d1_14 inp tail_14 0 nch W=0.637u L=0.368u
M2_14 out_14 inn tail_14 0 nch W=0.637u L=0.368u
M3_14 d1_14 d1_14 vdd vdd pch W=2u L=1u
M4_14 out_14 d1_14 vdd vdd pch W=2u L=1u
M5_14 tail_14 vbias 0 0 nch W=4u L=1u
Cl_14 out_14 0 100f
* --- Instance 15: W=0.637u L=0.569u ---
M1_15 d1_15 inp tail_15 0 nch W=0.637u L=0.569u
M2_15 out_15 inn tail_15 0 nch W=0.637u L=0.569u
M3_15 d1_15 d1_15 vdd vdd pch W=2u L=1u
M4_15 out_15 d1_15 vdd vdd pch W=2u L=1u
M5_15 tail_15 vbias 0 0 nch W=4u L=1u
Cl_15 out_15 0 100f
* --- Instance 16: W=0.637u L=0.879u ---
M1_16 d1_16 inp tail_16 0 nch W=0.637u L=0.879u
M2_16 out_16 inn tail_16 0 nch W=0.637u L=0.879u
M3_16 d1_16 d1_16 vdd vdd pch W=2u L=1u
M4_16 out_16 d1_16 vdd vdd pch W=2u L=1u
M5_16 tail_16 vbias 0 0 nch W=4u L=1u
Cl_16 out_16 0 100f
* --- Instance 17: W=0.637u L=1.357u ---
M1_17 d1_17 inp tail_17 0 nch W=0.637u L=1.357u
M2_17 out_17 inn tail_17 0 nch W=0.637u L=1.357u
M3_17 d1_17 d1_17 vdd vdd pch W=2u L=1u
M4_17 out_17 d1_17 vdd vdd pch W=2u L=1u
M5_17 tail_17 vbias 0 0 nch W=4u L=1u
Cl_17 out_17 0 100f
* --- Instance 18: W=0.637u L=2.096u ---
M1_18 d1_18 inp tail_18 0 nch W=0.637u L=2.096u
M2_18 out_18 inn tail_18 0 nch W=0.637u L=2.096u
M3_18 d1_18 d1_18 vdd vdd pch W=2u L=1u
M4_18 out_18 d1_18 vdd vdd pch W=2u L=1u
M5_18 tail_18 vbias 0 0 nch W=4u L=1u
Cl_18 out_18 0 100f
* --- Instance 19: W=0.637u L=3.237u ---
M1_19 d1_19 inp tail_19 0 nch W=0.637u L=3.237u
M2_19 out_19 inn tail_19 0 nch W=0.637u L=3.237u
M3_19 d1_19 d1_19 vdd vdd pch W=2u L=1u
M4_19 out_19 d1_19 vdd vdd pch W=2u L=1u
M5_19 tail_19 vbias 0 0 nch W=4u L=1u
Cl_19 out_19 0 100f
* --- Instance 20: W=0.637u L=5.000u ---
M1_20 d1_20 inp tail_20 0 nch W=0.637u L=5.000u
M2_20 out_20 inn tail_20 0 nch W=0.637u L=5.000u
M3_20 d1_20 d1_20 vdd vdd pch W=2u L=1u
M4_20 out_20 d1_20 vdd vdd pch W=2u L=1u
M5_20 tail_20 vbias 0 0 nch W=4u L=1u
Cl_20 out_20 0 100f
* --- Instance 21: W=0.812u L=0.100u ---
M1_21 d1_21 inp tail_21 0 nch W=0.812u L=0.100u
M2_21 out_21 inn tail_21 0 nch W=0.812u L=0.100u
M3_21 d1_21 d1_21 vdd vdd pch W=2u L=1u
M4_21 out_21 d1_21 vdd vdd pch W=2u L=1u
M5_21 tail_21 vbias 0 0 nch W=4u L=1u
Cl_21 out_21 0 100f
* --- Instance 22: W=0.812u L=0.154u ---
M1_22 d1_22 inp tail_22 0 nch W=0.812u L=0.154u
M2_22 out_22 inn tail_22 0 nch W=0.812u L=0.154u
M3_22 d1_22 d1_22 vdd vdd pch W=2u L=1u
M4_22 out_22 d1_22 vdd vdd pch W=2u L=1u
M5_22 tail_22 vbias 0 0 nch W=4u L=1u
Cl_22 out_22 0 100f
* --- Instance 23: W=0.812u L=0.239u ---
M1_23 d1_23 inp tail_23 0 nch W=0.812u L=0.239u
M2_23 out_23 inn tail_23 0 nch W=0.812u L=0.239u
M3_23 d1_23 d1_23 vdd vdd pch W=2u L=1u
M4_23 out_23 d1_23 vdd vdd pch W=2u L=1u
M5_23 tail_23 vbias 0 0 nch W=4u L=1u
Cl_23 out_23 0 100f
* --- Instance 24: W=0.812u L=0.368u ---
M1_24 d1_24 inp tail_24 0 nch W=0.812u L=0.368u
M2_24 out_24 inn tail_24 0 nch W=0.812u L=0.368u
M3_24 d1_24 d1_24 vdd vdd pch W=2u L=1u
M4_24 out_24 d1_24 vdd vdd pch W=2u L=1u
M5_24 tail_24 vbias 0 0 nch W=4u L=1u
Cl_24 out_24 0 100f
* --- Instance 25: W=0.812u L=0.569u ---
M1_25 d1_25 inp tail_25 0 nch W=0.812u L=0.569u
M2_25 out_25 inn tail_25 0 nch W=0.812u L=0.569u
M3_25 d1_25 d1_25 vdd vdd pch W=2u L=1u
M4_25 out_25 d1_25 vdd vdd pch W=2u L=1u
M5_25 tail_25 vbias 0 0 nch W=4u L=1u
Cl_25 out_25 0 100f
* --- Instance 26: W=0.812u L=0.879u ---
M1_26 d1_26 inp tail_26 0 nch W=0.812u L=0.879u
M2_26 out_26 inn tail_26 0 nch W=0.812u L=0.879u
M3_26 d1_26 d1_26 vdd vdd pch W=2u L=1u
M4_26 out_26 d1_26 vdd vdd pch W=2u L=1u
M5_26 tail_26 vbias 0 0 nch W=4u L=1u
Cl_26 out_26 0 100f
* --- Instance 27: W=0.812u L=1.357u ---
M1_27 d1_27 inp tail_27 0 nch W=0.812u L=1.357u
M2_27 out_27 inn tail_27 0 nch W=0.812u L=1.357u
M3_27 d1_27 d1_27 vdd vdd pch W=2u L=1u
M4_27 out_27 d1_27 vdd vdd pch W=2u L=1u
M5_27 tail_27 vbias 0 0 nch W=4u L=1u
Cl_27 out_27 0 100f
* --- Instance 28: W=0.812u L=2.096u ---
M1_28 d1_28 inp tail_28 0 nch W=0.812u L=2.096u
M2_28 out_28 inn tail_28 0 nch W=0.812u L=2.096u
M3_28 d1_28 d1_28 vdd vdd pch W=2u L=1u
M4_28 out_28 d1_28 vdd vdd pch W=2u L=1u
M5_28 tail_28 vbias 0 0 nch W=4u L=1u
Cl_28 out_28 0 100f
* --- Instance 29: W=0.812u L=3.237u ---
M1_29 d1_29 inp tail_29 0 nch W=0.812u L=3.237u
M2_29 out_29 inn tail_29 0 nch W=0.812u L=3.237u
M3_29 d1_29 d1_29 vdd vdd pch W=2u L=1u
M4_29 out_29 d1_29 vdd vdd pch W=2u L=1u
M5_29 tail_29 vbias 0 0 nch W=4u L=1u
Cl_29 out_29 0 100f
* --- Instance 30: W=0.812u L=5.000u ---
M1_30 d1_30 inp tail_30 0 nch W=0.812u L=5.000u
M2_30 out_30 inn tail_30 0 nch W=0.812u L=5.000u
M3_30 d1_30 d1_30 vdd vdd pch W=2u L=1u
M4_30 out_30 d1_30 vdd vdd pch W=2u L=1u
M5_30 tail_30 vbias 0 0 nch W=4u L=1u
Cl_30 out_30 0 100f
* --- Instance 31: W=1.035u L=0.100u ---
M1_31 d1_31 inp tail_31 0 nch W=1.035u L=0.100u
M2_31 out_31 inn tail_31 0 nch W=1.035u L=0.100u
M3_31 d1_31 d1_31 vdd vdd pch W=2u L=1u
M4_31 out_31 d1_31 vdd vdd pch W=2u L=1u
M5_31 tail_31 vbias 0 0 nch W=4u L=1u
Cl_31 out_31 0 100f
* --- Instance 32: W=1.035u L=0.154u ---
M1_32 d1_32 inp tail_32 0 nch W=1.035u L=0.154u
M2_32 out_32 inn tail_32 0 nch W=1.035u L=0.154u
M3_32 d1_32 d1_32 vdd vdd pch W=2u L=1u
M4_32 out_32 d1_32 vdd vdd pch W=2u L=1u
M5_32 tail_32 vbias 0 0 nch W=4u L=1u
Cl_32 out_32 0 100f
* --- Instance 33: W=1.035u L=0.239u ---
M1_33 d1_33 inp tail_33 0 nch W=1.035u L=0.239u
M2_33 out_33 inn tail_33 0 nch W=1.035u L=0.239u
M3_33 d1_33 d1_33 vdd vdd pch W=2u L=1u
M4_33 out_33 d1_33 vdd vdd pch W=2u L=1u
M5_33 tail_33 vbias 0 0 nch W=4u L=1u
Cl_33 out_33 0 100f
* --- Instance 34: W=1.035u L=0.368u ---
M1_34 d1_34 inp tail_34 0 nch W=1.035u L=0.368u
M2_34 out_34 inn tail_34 0 nch W=1.035u L=0.368u
M3_34 d1_34 d1_34 vdd vdd pch W=2u L=1u
M4_34 out_34 d1_34 vdd vdd pch W=2u L=1u
M5_34 tail_34 vbias 0 0 nch W=4u L=1u
Cl_34 out_34 0 100f
* --- Instance 35: W=1.035u L=0.569u ---
M1_35 d1_35 inp tail_35 0 nch W=1.035u L=0.569u
M2_35 out_35 inn tail_35 0 nch W=1.035u L=0.569u
M3_35 d1_35 d1_35 vdd vdd pch W=2u L=1u
M4_35 out_35 d1_35 vdd vdd pch W=2u L=1u
M5_35 tail_35 vbias 0 0 nch W=4u L=1u
Cl_35 out_35 0 100f
* --- Instance 36: W=1.035u L=0.879u ---
M1_36 d1_36 inp tail_36 0 nch W=1.035u L=0.879u
M2_36 out_36 inn tail_36 0 nch W=1.035u L=0.879u
M3_36 d1_36 d1_36 vdd vdd pch W=2u L=1u
M4_36 out_36 d1_36 vdd vdd pch W=2u L=1u
M5_36 tail_36 vbias 0 0 nch W=4u L=1u
Cl_36 out_36 0 100f
* --- Instance 37: W=1.035u L=1.357u ---
M1_37 d1_37 inp tail_37 0 nch W=1.035u L=1.357u
M2_37 out_37 inn tail_37 0 nch W=1.035u L=1.357u
M3_37 d1_37 d1_37 vdd vdd pch W=2u L=1u
M4_37 out_37 d1_37 vdd vdd pch W=2u L=1u
M5_37 tail_37 vbias 0 0 nch W=4u L=1u
Cl_37 out_37 0 100f
* --- Instance 38: W=1.035u L=2.096u ---
M1_38 d1_38 inp tail_38 0 nch W=1.035u L=2.096u
M2_38 out_38 inn tail_38 0 nch W=1.035u L=2.096u
M3_38 d1_38 d1_38 vdd vdd pch W=2u L=1u
M4_38 out_38 d1_38 vdd vdd pch W=2u L=1u
M5_38 tail_38 vbias 0 0 nch W=4u L=1u
Cl_38 out_38 0 100f
* --- Instance 39: W=1.035u L=3.237u ---
M1_39 d1_39 inp tail_39 0 nch W=1.035u L=3.237u
M2_39 out_39 inn tail_39 0 nch W=1.035u L=3.237u
M3_39 d1_39 d1_39 vdd vdd pch W=2u L=1u
M4_39 out_39 d1_39 vdd vdd pch W=2u L=1u
M5_39 tail_39 vbias 0 0 nch W=4u L=1u
Cl_39 out_39 0 100f
* --- Instance 40: W=1.035u L=5.000u ---
M1_40 d1_40 inp tail_40 0 nch W=1.035u L=5.000u
M2_40 out_40 inn tail_40 0 nch W=1.035u L=5.000u
M3_40 d1_40 d1_40 vdd vdd pch W=2u L=1u
M4_40 out_40 d1_40 vdd vdd pch W=2u L=1u
M5_40 tail_40 vbias 0 0 nch W=4u L=1u
Cl_40 out_40 0 100f
* --- Instance 41: W=1.318u L=0.100u ---
M1_41 d1_41 inp tail_41 0 nch W=1.318u L=0.100u
M2_41 out_41 inn tail_41 0 nch W=1.318u L=0.100u
M3_41 d1_41 d1_41 vdd vdd pch W=2u L=1u
M4_41 out_41 d1_41 vdd vdd pch W=2u L=1u
M5_41 tail_41 vbias 0 0 nch W=4u L=1u
Cl_41 out_41 0 100f
* --- Instance 42: W=1.318u L=0.154u ---
M1_42 d1_42 inp tail_42 0 nch W=1.318u L=0.154u
M2_42 out_42 inn tail_42 0 nch W=1.318u L=0.154u
M3_42 d1_42 d1_42 vdd vdd pch W=2u L=1u
M4_42 out_42 d1_42 vdd vdd pch W=2u L=1u
M5_42 tail_42 vbias 0 0 nch W=4u L=1u
Cl_42 out_42 0 100f
* --- Instance 43: W=1.318u L=0.239u ---
M1_43 d1_43 inp tail_43 0 nch W=1.318u L=0.239u
M2_43 out_43 inn tail_43 0 nch W=1.318u L=0.239u
M3_43 d1_43 d1_43 vdd vdd pch W=2u L=1u
M4_43 out_43 d1_43 vdd vdd pch W=2u L=1u
M5_43 tail_43 vbias 0 0 nch W=4u L=1u
Cl_43 out_43 0 100f
* --- Instance 44: W=1.318u L=0.368u ---
M1_44 d1_44 inp tail_44 0 nch W=1.318u L=0.368u
M2_44 out_44 inn tail_44 0 nch W=1.318u L=0.368u
M3_44 d1_44 d1_44 vdd vdd pch W=2u L=1u
M4_44 out_44 d1_44 vdd vdd pch W=2u L=1u
M5_44 tail_44 vbias 0 0 nch W=4u L=1u
Cl_44 out_44 0 100f
* --- Instance 45: W=1.318u L=0.569u ---
M1_45 d1_45 inp tail_45 0 nch W=1.318u L=0.569u
M2_45 out_45 inn tail_45 0 nch W=1.318u L=0.569u
M3_45 d1_45 d1_45 vdd vdd pch W=2u L=1u
M4_45 out_45 d1_45 vdd vdd pch W=2u L=1u
M5_45 tail_45 vbias 0 0 nch W=4u L=1u
Cl_45 out_45 0 100f
* --- Instance 46: W=1.318u L=0.879u ---
M1_46 d1_46 inp tail_46 0 nch W=1.318u L=0.879u
M2_46 out_46 inn tail_46 0 nch W=1.318u L=0.879u
M3_46 d1_46 d1_46 vdd vdd pch W=2u L=1u
M4_46 out_46 d1_46 vdd vdd pch W=2u L=1u
M5_46 tail_46 vbias 0 0 nch W=4u L=1u
Cl_46 out_46 0 100f
* --- Instance 47: W=1.318u L=1.357u ---
M1_47 d1_47 inp tail_47 0 nch W=1.318u L=1.357u
M2_47 out_47 inn tail_47 0 nch W=1.318u L=1.357u
M3_47 d1_47 d1_47 vdd vdd pch W=2u L=1u
M4_47 out_47 d1_47 vdd vdd pch W=2u L=1u
M5_47 tail_47 vbias 0 0 nch W=4u L=1u
Cl_47 out_47 0 100f
* --- Instance 48: W=1.318u L=2.096u ---
M1_48 d1_48 inp tail_48 0 nch W=1.318u L=2.096u
M2_48 out_48 inn tail_48 0 nch W=1.318u L=2.096u
M3_48 d1_48 d1_48 vdd vdd pch W=2u L=1u
M4_48 out_48 d1_48 vdd vdd pch W=2u L=1u
M5_48 tail_48 vbias 0 0 nch W=4u L=1u
Cl_48 out_48 0 100f
* --- Instance 49: W=1.318u L=3.237u ---
M1_49 d1_49 inp tail_49 0 nch W=1.318u L=3.237u
M2_49 out_49 inn tail_49 0 nch W=1.318u L=3.237u
M3_49 d1_49 d1_49 vdd vdd pch W=2u L=1u
M4_49 out_49 d1_49 vdd vdd pch W=2u L=1u
M5_49 tail_49 vbias 0 0 nch W=4u L=1u
Cl_49 out_49 0 100f
* --- Instance 50: W=1.318u L=5.000u ---
M1_50 d1_50 inp tail_50 0 nch W=1.318u L=5.000u
M2_50 out_50 inn tail_50 0 nch W=1.318u L=5.000u
M3_50 d1_50 d1_50 vdd vdd pch W=2u L=1u
M4_50 out_50 d1_50 vdd vdd pch W=2u L=1u
M5_50 tail_50 vbias 0 0 nch W=4u L=1u
Cl_50 out_50 0 100f
* --- Instance 51: W=1.680u L=0.100u ---
M1_51 d1_51 inp tail_51 0 nch W=1.680u L=0.100u
M2_51 out_51 inn tail_51 0 nch W=1.680u L=0.100u
M3_51 d1_51 d1_51 vdd vdd pch W=2u L=1u
M4_51 out_51 d1_51 vdd vdd pch W=2u L=1u
M5_51 tail_51 vbias 0 0 nch W=4u L=1u
Cl_51 out_51 0 100f
* --- Instance 52: W=1.680u L=0.154u ---
M1_52 d1_52 inp tail_52 0 nch W=1.680u L=0.154u
M2_52 out_52 inn tail_52 0 nch W=1.680u L=0.154u
M3_52 d1_52 d1_52 vdd vdd pch W=2u L=1u
M4_52 out_52 d1_52 vdd vdd pch W=2u L=1u
M5_52 tail_52 vbias 0 0 nch W=4u L=1u
Cl_52 out_52 0 100f
* --- Instance 53: W=1.680u L=0.239u ---
M1_53 d1_53 inp tail_53 0 nch W=1.680u L=0.239u
M2_53 out_53 inn tail_53 0 nch W=1.680u L=0.239u
M3_53 d1_53 d1_53 vdd vdd pch W=2u L=1u
M4_53 out_53 d1_53 vdd vdd pch W=2u L=1u
M5_53 tail_53 vbias 0 0 nch W=4u L=1u
Cl_53 out_53 0 100f
* --- Instance 54: W=1.680u L=0.368u ---
M1_54 d1_54 inp tail_54 0 nch W=1.680u L=0.368u
M2_54 out_54 inn tail_54 0 nch W=1.680u L=0.368u
M3_54 d1_54 d1_54 vdd vdd pch W=2u L=1u
M4_54 out_54 d1_54 vdd vdd pch W=2u L=1u
M5_54 tail_54 vbias 0 0 nch W=4u L=1u
Cl_54 out_54 0 100f
* --- Instance 55: W=1.680u L=0.569u ---
M1_55 d1_55 inp tail_55 0 nch W=1.680u L=0.569u
M2_55 out_55 inn tail_55 0 nch W=1.680u L=0.569u
M3_55 d1_55 d1_55 vdd vdd pch W=2u L=1u
M4_55 out_55 d1_55 vdd vdd pch W=2u L=1u
M5_55 tail_55 vbias 0 0 nch W=4u L=1u
Cl_55 out_55 0 100f
* --- Instance 56: W=1.680u L=0.879u ---
M1_56 d1_56 inp tail_56 0 nch W=1.680u L=0.879u
M2_56 out_56 inn tail_56 0 nch W=1.680u L=0.879u
M3_56 d1_56 d1_56 vdd vdd pch W=2u L=1u
M4_56 out_56 d1_56 vdd vdd pch W=2u L=1u
M5_56 tail_56 vbias 0 0 nch W=4u L=1u
Cl_56 out_56 0 100f
* --- Instance 57: W=1.680u L=1.357u ---
M1_57 d1_57 inp tail_57 0 nch W=1.680u L=1.357u
M2_57 out_57 inn tail_57 0 nch W=1.680u L=1.357u
M3_57 d1_57 d1_57 vdd vdd pch W=2u L=1u
M4_57 out_57 d1_57 vdd vdd pch W=2u L=1u
M5_57 tail_57 vbias 0 0 nch W=4u L=1u
Cl_57 out_57 0 100f
* --- Instance 58: W=1.680u L=2.096u ---
M1_58 d1_58 inp tail_58 0 nch W=1.680u L=2.096u
M2_58 out_58 inn tail_58 0 nch W=1.680u L=2.096u
M3_58 d1_58 d1_58 vdd vdd pch W=2u L=1u
M4_58 out_58 d1_58 vdd vdd pch W=2u L=1u
M5_58 tail_58 vbias 0 0 nch W=4u L=1u
Cl_58 out_58 0 100f
* --- Instance 59: W=1.680u L=3.237u ---
M1_59 d1_59 inp tail_59 0 nch W=1.680u L=3.237u
M2_59 out_59 inn tail_59 0 nch W=1.680u L=3.237u
M3_59 d1_59 d1_59 vdd vdd pch W=2u L=1u
M4_59 out_59 d1_59 vdd vdd pch W=2u L=1u
M5_59 tail_59 vbias 0 0 nch W=4u L=1u
Cl_59 out_59 0 100f
* --- Instance 60: W=1.680u L=5.000u ---
M1_60 d1_60 inp tail_60 0 nch W=1.680u L=5.000u
M2_60 out_60 inn tail_60 0 nch W=1.680u L=5.000u
M3_60 d1_60 d1_60 vdd vdd pch W=2u L=1u
M4_60 out_60 d1_60 vdd vdd pch W=2u L=1u
M5_60 tail_60 vbias 0 0 nch W=4u L=1u
Cl_60 out_60 0 100f
* --- Instance 61: W=2.141u L=0.100u ---
M1_61 d1_61 inp tail_61 0 nch W=2.141u L=0.100u
M2_61 out_61 inn tail_61 0 nch W=2.141u L=0.100u
M3_61 d1_61 d1_61 vdd vdd pch W=2u L=1u
M4_61 out_61 d1_61 vdd vdd pch W=2u L=1u
M5_61 tail_61 vbias 0 0 nch W=4u L=1u
Cl_61 out_61 0 100f
* --- Instance 62: W=2.141u L=0.154u ---
M1_62 d1_62 inp tail_62 0 nch W=2.141u L=0.154u
M2_62 out_62 inn tail_62 0 nch W=2.141u L=0.154u
M3_62 d1_62 d1_62 vdd vdd pch W=2u L=1u
M4_62 out_62 d1_62 vdd vdd pch W=2u L=1u
M5_62 tail_62 vbias 0 0 nch W=4u L=1u
Cl_62 out_62 0 100f
* --- Instance 63: W=2.141u L=0.239u ---
M1_63 d1_63 inp tail_63 0 nch W=2.141u L=0.239u
M2_63 out_63 inn tail_63 0 nch W=2.141u L=0.239u
M3_63 d1_63 d1_63 vdd vdd pch W=2u L=1u
M4_63 out_63 d1_63 vdd vdd pch W=2u L=1u
M5_63 tail_63 vbias 0 0 nch W=4u L=1u
Cl_63 out_63 0 100f
* --- Instance 64: W=2.141u L=0.368u ---
M1_64 d1_64 inp tail_64 0 nch W=2.141u L=0.368u
M2_64 out_64 inn tail_64 0 nch W=2.141u L=0.368u
M3_64 d1_64 d1_64 vdd vdd pch W=2u L=1u
M4_64 out_64 d1_64 vdd vdd pch W=2u L=1u
M5_64 tail_64 vbias 0 0 nch W=4u L=1u
Cl_64 out_64 0 100f
* --- Instance 65: W=2.141u L=0.569u ---
M1_65 d1_65 inp tail_65 0 nch W=2.141u L=0.569u
M2_65 out_65 inn tail_65 0 nch W=2.141u L=0.569u
M3_65 d1_65 d1_65 vdd vdd pch W=2u L=1u
M4_65 out_65 d1_65 vdd vdd pch W=2u L=1u
M5_65 tail_65 vbias 0 0 nch W=4u L=1u
Cl_65 out_65 0 100f
* --- Instance 66: W=2.141u L=0.879u ---
M1_66 d1_66 inp tail_66 0 nch W=2.141u L=0.879u
M2_66 out_66 inn tail_66 0 nch W=2.141u L=0.879u
M3_66 d1_66 d1_66 vdd vdd pch W=2u L=1u
M4_66 out_66 d1_66 vdd vdd pch W=2u L=1u
M5_66 tail_66 vbias 0 0 nch W=4u L=1u
Cl_66 out_66 0 100f
* --- Instance 67: W=2.141u L=1.357u ---
M1_67 d1_67 inp tail_67 0 nch W=2.141u L=1.357u
M2_67 out_67 inn tail_67 0 nch W=2.141u L=1.357u
M3_67 d1_67 d1_67 vdd vdd pch W=2u L=1u
M4_67 out_67 d1_67 vdd vdd pch W=2u L=1u
M5_67 tail_67 vbias 0 0 nch W=4u L=1u
Cl_67 out_67 0 100f
* --- Instance 68: W=2.141u L=2.096u ---
M1_68 d1_68 inp tail_68 0 nch W=2.141u L=2.096u
M2_68 out_68 inn tail_68 0 nch W=2.141u L=2.096u
M3_68 d1_68 d1_68 vdd vdd pch W=2u L=1u
M4_68 out_68 d1_68 vdd vdd pch W=2u L=1u
M5_68 tail_68 vbias 0 0 nch W=4u L=1u
Cl_68 out_68 0 100f
* --- Instance 69: W=2.141u L=3.237u ---
M1_69 d1_69 inp tail_69 0 nch W=2.141u L=3.237u
M2_69 out_69 inn tail_69 0 nch W=2.141u L=3.237u
M3_69 d1_69 d1_69 vdd vdd pch W=2u L=1u
M4_69 out_69 d1_69 vdd vdd pch W=2u L=1u
M5_69 tail_69 vbias 0 0 nch W=4u L=1u
Cl_69 out_69 0 100f
* --- Instance 70: W=2.141u L=5.000u ---
M1_70 d1_70 inp tail_70 0 nch W=2.141u L=5.000u
M2_70 out_70 inn tail_70 0 nch W=2.141u L=5.000u
M3_70 d1_70 d1_70 vdd vdd pch W=2u L=1u
M4_70 out_70 d1_70 vdd vdd pch W=2u L=1u
M5_70 tail_70 vbias 0 0 nch W=4u L=1u
Cl_70 out_70 0 100f
* --- Instance 71: W=2.728u L=0.100u ---
M1_71 d1_71 inp tail_71 0 nch W=2.728u L=0.100u
M2_71 out_71 inn tail_71 0 nch W=2.728u L=0.100u
M3_71 d1_71 d1_71 vdd vdd pch W=2u L=1u
M4_71 out_71 d1_71 vdd vdd pch W=2u L=1u
M5_71 tail_71 vbias 0 0 nch W=4u L=1u
Cl_71 out_71 0 100f
* --- Instance 72: W=2.728u L=0.154u ---
M1_72 d1_72 inp tail_72 0 nch W=2.728u L=0.154u
M2_72 out_72 inn tail_72 0 nch W=2.728u L=0.154u
M3_72 d1_72 d1_72 vdd vdd pch W=2u L=1u
M4_72 out_72 d1_72 vdd vdd pch W=2u L=1u
M5_72 tail_72 vbias 0 0 nch W=4u L=1u
Cl_72 out_72 0 100f
* --- Instance 73: W=2.728u L=0.239u ---
M1_73 d1_73 inp tail_73 0 nch W=2.728u L=0.239u
M2_73 out_73 inn tail_73 0 nch W=2.728u L=0.239u
M3_73 d1_73 d1_73 vdd vdd pch W=2u L=1u
M4_73 out_73 d1_73 vdd vdd pch W=2u L=1u
M5_73 tail_73 vbias 0 0 nch W=4u L=1u
Cl_73 out_73 0 100f
* --- Instance 74: W=2.728u L=0.368u ---
M1_74 d1_74 inp tail_74 0 nch W=2.728u L=0.368u
M2_74 out_74 inn tail_74 0 nch W=2.728u L=0.368u
M3_74 d1_74 d1_74 vdd vdd pch W=2u L=1u
M4_74 out_74 d1_74 vdd vdd pch W=2u L=1u
M5_74 tail_74 vbias 0 0 nch W=4u L=1u
Cl_74 out_74 0 100f
* --- Instance 75: W=2.728u L=0.569u ---
M1_75 d1_75 inp tail_75 0 nch W=2.728u L=0.569u
M2_75 out_75 inn tail_75 0 nch W=2.728u L=0.569u
M3_75 d1_75 d1_75 vdd vdd pch W=2u L=1u
M4_75 out_75 d1_75 vdd vdd pch W=2u L=1u
M5_75 tail_75 vbias 0 0 nch W=4u L=1u
Cl_75 out_75 0 100f
* --- Instance 76: W=2.728u L=0.879u ---
M1_76 d1_76 inp tail_76 0 nch W=2.728u L=0.879u
M2_76 out_76 inn tail_76 0 nch W=2.728u L=0.879u
M3_76 d1_76 d1_76 vdd vdd pch W=2u L=1u
M4_76 out_76 d1_76 vdd vdd pch W=2u L=1u
M5_76 tail_76 vbias 0 0 nch W=4u L=1u
Cl_76 out_76 0 100f
* --- Instance 77: W=2.728u L=1.357u ---
M1_77 d1_77 inp tail_77 0 nch W=2.728u L=1.357u
M2_77 out_77 inn tail_77 0 nch W=2.728u L=1.357u
M3_77 d1_77 d1_77 vdd vdd pch W=2u L=1u
M4_77 out_77 d1_77 vdd vdd pch W=2u L=1u
M5_77 tail_77 vbias 0 0 nch W=4u L=1u
Cl_77 out_77 0 100f
* --- Instance 78: W=2.728u L=2.096u ---
M1_78 d1_78 inp tail_78 0 nch W=2.728u L=2.096u
M2_78 out_78 inn tail_78 0 nch W=2.728u L=2.096u
M3_78 d1_78 d1_78 vdd vdd pch W=2u L=1u
M4_78 out_78 d1_78 vdd vdd pch W=2u L=1u
M5_78 tail_78 vbias 0 0 nch W=4u L=1u
Cl_78 out_78 0 100f
* --- Instance 79: W=2.728u L=3.237u ---
M1_79 d1_79 inp tail_79 0 nch W=2.728u L=3.237u
M2_79 out_79 inn tail_79 0 nch W=2.728u L=3.237u
M3_79 d1_79 d1_79 vdd vdd pch W=2u L=1u
M4_79 out_79 d1_79 vdd vdd pch W=2u L=1u
M5_79 tail_79 vbias 0 0 nch W=4u L=1u
Cl_79 out_79 0 100f
* --- Instance 80: W=2.728u L=5.000u ---
M1_80 d1_80 inp tail_80 0 nch W=2.728u L=5.000u
M2_80 out_80 inn tail_80 0 nch W=2.728u L=5.000u
M3_80 d1_80 d1_80 vdd vdd pch W=2u L=1u
M4_80 out_80 d1_80 vdd vdd pch W=2u L=1u
M5_80 tail_80 vbias 0 0 nch W=4u L=1u
Cl_80 out_80 0 100f
* --- Instance 81: W=3.476u L=0.100u ---
M1_81 d1_81 inp tail_81 0 nch W=3.476u L=0.100u
M2_81 out_81 inn tail_81 0 nch W=3.476u L=0.100u
M3_81 d1_81 d1_81 vdd vdd pch W=2u L=1u
M4_81 out_81 d1_81 vdd vdd pch W=2u L=1u
M5_81 tail_81 vbias 0 0 nch W=4u L=1u
Cl_81 out_81 0 100f
* --- Instance 82: W=3.476u L=0.154u ---
M1_82 d1_82 inp tail_82 0 nch W=3.476u L=0.154u
M2_82 out_82 inn tail_82 0 nch W=3.476u L=0.154u
M3_82 d1_82 d1_82 vdd vdd pch W=2u L=1u
M4_82 out_82 d1_82 vdd vdd pch W=2u L=1u
M5_82 tail_82 vbias 0 0 nch W=4u L=1u
Cl_82 out_82 0 100f
* --- Instance 83: W=3.476u L=0.239u ---
M1_83 d1_83 inp tail_83 0 nch W=3.476u L=0.239u
M2_83 out_83 inn tail_83 0 nch W=3.476u L=0.239u
M3_83 d1_83 d1_83 vdd vdd pch W=2u L=1u
M4_83 out_83 d1_83 vdd vdd pch W=2u L=1u
M5_83 tail_83 vbias 0 0 nch W=4u L=1u
Cl_83 out_83 0 100f
* --- Instance 84: W=3.476u L=0.368u ---
M1_84 d1_84 inp tail_84 0 nch W=3.476u L=0.368u
M2_84 out_84 inn tail_84 0 nch W=3.476u L=0.368u
M3_84 d1_84 d1_84 vdd vdd pch W=2u L=1u
M4_84 out_84 d1_84 vdd vdd pch W=2u L=1u
M5_84 tail_84 vbias 0 0 nch W=4u L=1u
Cl_84 out_84 0 100f
* --- Instance 85: W=3.476u L=0.569u ---
M1_85 d1_85 inp tail_85 0 nch W=3.476u L=0.569u
M2_85 out_85 inn tail_85 0 nch W=3.476u L=0.569u
M3_85 d1_85 d1_85 vdd vdd pch W=2u L=1u
M4_85 out_85 d1_85 vdd vdd pch W=2u L=1u
M5_85 tail_85 vbias 0 0 nch W=4u L=1u
Cl_85 out_85 0 100f
* --- Instance 86: W=3.476u L=0.879u ---
M1_86 d1_86 inp tail_86 0 nch W=3.476u L=0.879u
M2_86 out_86 inn tail_86 0 nch W=3.476u L=0.879u
M3_86 d1_86 d1_86 vdd vdd pch W=2u L=1u
M4_86 out_86 d1_86 vdd vdd pch W=2u L=1u
M5_86 tail_86 vbias 0 0 nch W=4u L=1u
Cl_86 out_86 0 100f
* --- Instance 87: W=3.476u L=1.357u ---
M1_87 d1_87 inp tail_87 0 nch W=3.476u L=1.357u
M2_87 out_87 inn tail_87 0 nch W=3.476u L=1.357u
M3_87 d1_87 d1_87 vdd vdd pch W=2u L=1u
M4_87 out_87 d1_87 vdd vdd pch W=2u L=1u
M5_87 tail_87 vbias 0 0 nch W=4u L=1u
Cl_87 out_87 0 100f
* --- Instance 88: W=3.476u L=2.096u ---
M1_88 d1_88 inp tail_88 0 nch W=3.476u L=2.096u
M2_88 out_88 inn tail_88 0 nch W=3.476u L=2.096u
M3_88 d1_88 d1_88 vdd vdd pch W=2u L=1u
M4_88 out_88 d1_88 vdd vdd pch W=2u L=1u
M5_88 tail_88 vbias 0 0 nch W=4u L=1u
Cl_88 out_88 0 100f
* --- Instance 89: W=3.476u L=3.237u ---
M1_89 d1_89 inp tail_89 0 nch W=3.476u L=3.237u
M2_89 out_89 inn tail_89 0 nch W=3.476u L=3.237u
M3_89 d1_89 d1_89 vdd vdd pch W=2u L=1u
M4_89 out_89 d1_89 vdd vdd pch W=2u L=1u
M5_89 tail_89 vbias 0 0 nch W=4u L=1u
Cl_89 out_89 0 100f
* --- Instance 90: W=3.476u L=5.000u ---
M1_90 d1_90 inp tail_90 0 nch W=3.476u L=5.000u
M2_90 out_90 inn tail_90 0 nch W=3.476u L=5.000u
M3_90 d1_90 d1_90 vdd vdd pch W=2u L=1u
M4_90 out_90 d1_90 vdd vdd pch W=2u L=1u
M5_90 tail_90 vbias 0 0 nch W=4u L=1u
Cl_90 out_90 0 100f
* --- Instance 91: W=4.429u L=0.100u ---
M1_91 d1_91 inp tail_91 0 nch W=4.429u L=0.100u
M2_91 out_91 inn tail_91 0 nch W=4.429u L=0.100u
M3_91 d1_91 d1_91 vdd vdd pch W=2u L=1u
M4_91 out_91 d1_91 vdd vdd pch W=2u L=1u
M5_91 tail_91 vbias 0 0 nch W=4u L=1u
Cl_91 out_91 0 100f
* --- Instance 92: W=4.429u L=0.154u ---
M1_92 d1_92 inp tail_92 0 nch W=4.429u L=0.154u
M2_92 out_92 inn tail_92 0 nch W=4.429u L=0.154u
M3_92 d1_92 d1_92 vdd vdd pch W=2u L=1u
M4_92 out_92 d1_92 vdd vdd pch W=2u L=1u
M5_92 tail_92 vbias 0 0 nch W=4u L=1u
Cl_92 out_92 0 100f
* --- Instance 93: W=4.429u L=0.239u ---
M1_93 d1_93 inp tail_93 0 nch W=4.429u L=0.239u
M2_93 out_93 inn tail_93 0 nch W=4.429u L=0.239u
M3_93 d1_93 d1_93 vdd vdd pch W=2u L=1u
M4_93 out_93 d1_93 vdd vdd pch W=2u L=1u
M5_93 tail_93 vbias 0 0 nch W=4u L=1u
Cl_93 out_93 0 100f
* --- Instance 94: W=4.429u L=0.368u ---
M1_94 d1_94 inp tail_94 0 nch W=4.429u L=0.368u
M2_94 out_94 inn tail_94 0 nch W=4.429u L=0.368u
M3_94 d1_94 d1_94 vdd vdd pch W=2u L=1u
M4_94 out_94 d1_94 vdd vdd pch W=2u L=1u
M5_94 tail_94 vbias 0 0 nch W=4u L=1u
Cl_94 out_94 0 100f
* --- Instance 95: W=4.429u L=0.569u ---
M1_95 d1_95 inp tail_95 0 nch W=4.429u L=0.569u
M2_95 out_95 inn tail_95 0 nch W=4.429u L=0.569u
M3_95 d1_95 d1_95 vdd vdd pch W=2u L=1u
M4_95 out_95 d1_95 vdd vdd pch W=2u L=1u
M5_95 tail_95 vbias 0 0 nch W=4u L=1u
Cl_95 out_95 0 100f
* --- Instance 96: W=4.429u L=0.879u ---
M1_96 d1_96 inp tail_96 0 nch W=4.429u L=0.879u
M2_96 out_96 inn tail_96 0 nch W=4.429u L=0.879u
M3_96 d1_96 d1_96 vdd vdd pch W=2u L=1u
M4_96 out_96 d1_96 vdd vdd pch W=2u L=1u
M5_96 tail_96 vbias 0 0 nch W=4u L=1u
Cl_96 out_96 0 100f
* --- Instance 97: W=4.429u L=1.357u ---
M1_97 d1_97 inp tail_97 0 nch W=4.429u L=1.357u
M2_97 out_97 inn tail_97 0 nch W=4.429u L=1.357u
M3_97 d1_97 d1_97 vdd vdd pch W=2u L=1u
M4_97 out_97 d1_97 vdd vdd pch W=2u L=1u
M5_97 tail_97 vbias 0 0 nch W=4u L=1u
Cl_97 out_97 0 100f
* --- Instance 98: W=4.429u L=2.096u ---
M1_98 d1_98 inp tail_98 0 nch W=4.429u L=2.096u
M2_98 out_98 inn tail_98 0 nch W=4.429u L=2.096u
M3_98 d1_98 d1_98 vdd vdd pch W=2u L=1u
M4_98 out_98 d1_98 vdd vdd pch W=2u L=1u
M5_98 tail_98 vbias 0 0 nch W=4u L=1u
Cl_98 out_98 0 100f
* --- Instance 99: W=4.429u L=3.237u ---
M1_99 d1_99 inp tail_99 0 nch W=4.429u L=3.237u
M2_99 out_99 inn tail_99 0 nch W=4.429u L=3.237u
M3_99 d1_99 d1_99 vdd vdd pch W=2u L=1u
M4_99 out_99 d1_99 vdd vdd pch W=2u L=1u
M5_99 tail_99 vbias 0 0 nch W=4u L=1u
Cl_99 out_99 0 100f
* --- Instance 100: W=4.429u L=5.000u ---
M1_100 d1_100 inp tail_100 0 nch W=4.429u L=5.000u
M2_100 out_100 inn tail_100 0 nch W=4.429u L=5.000u
M3_100 d1_100 d1_100 vdd vdd pch W=2u L=1u
M4_100 out_100 d1_100 vdd vdd pch W=2u L=1u
M5_100 tail_100 vbias 0 0 nch W=4u L=1u
Cl_100 out_100 0 100f
* --- Instance 101: W=5.644u L=0.100u ---
M1_101 d1_101 inp tail_101 0 nch W=5.644u L=0.100u
M2_101 out_101 inn tail_101 0 nch W=5.644u L=0.100u
M3_101 d1_101 d1_101 vdd vdd pch W=2u L=1u
M4_101 out_101 d1_101 vdd vdd pch W=2u L=1u
M5_101 tail_101 vbias 0 0 nch W=4u L=1u
Cl_101 out_101 0 100f
* --- Instance 102: W=5.644u L=0.154u ---
M1_102 d1_102 inp tail_102 0 nch W=5.644u L=0.154u
M2_102 out_102 inn tail_102 0 nch W=5.644u L=0.154u
M3_102 d1_102 d1_102 vdd vdd pch W=2u L=1u
M4_102 out_102 d1_102 vdd vdd pch W=2u L=1u
M5_102 tail_102 vbias 0 0 nch W=4u L=1u
Cl_102 out_102 0 100f
* --- Instance 103: W=5.644u L=0.239u ---
M1_103 d1_103 inp tail_103 0 nch W=5.644u L=0.239u
M2_103 out_103 inn tail_103 0 nch W=5.644u L=0.239u
M3_103 d1_103 d1_103 vdd vdd pch W=2u L=1u
M4_103 out_103 d1_103 vdd vdd pch W=2u L=1u
M5_103 tail_103 vbias 0 0 nch W=4u L=1u
Cl_103 out_103 0 100f
* --- Instance 104: W=5.644u L=0.368u ---
M1_104 d1_104 inp tail_104 0 nch W=5.644u L=0.368u
M2_104 out_104 inn tail_104 0 nch W=5.644u L=0.368u
M3_104 d1_104 d1_104 vdd vdd pch W=2u L=1u
M4_104 out_104 d1_104 vdd vdd pch W=2u L=1u
M5_104 tail_104 vbias 0 0 nch W=4u L=1u
Cl_104 out_104 0 100f
* --- Instance 105: W=5.644u L=0.569u ---
M1_105 d1_105 inp tail_105 0 nch W=5.644u L=0.569u
M2_105 out_105 inn tail_105 0 nch W=5.644u L=0.569u
M3_105 d1_105 d1_105 vdd vdd pch W=2u L=1u
M4_105 out_105 d1_105 vdd vdd pch W=2u L=1u
M5_105 tail_105 vbias 0 0 nch W=4u L=1u
Cl_105 out_105 0 100f
* --- Instance 106: W=5.644u L=0.879u ---
M1_106 d1_106 inp tail_106 0 nch W=5.644u L=0.879u
M2_106 out_106 inn tail_106 0 nch W=5.644u L=0.879u
M3_106 d1_106 d1_106 vdd vdd pch W=2u L=1u
M4_106 out_106 d1_106 vdd vdd pch W=2u L=1u
M5_106 tail_106 vbias 0 0 nch W=4u L=1u
Cl_106 out_106 0 100f
* --- Instance 107: W=5.644u L=1.357u ---
M1_107 d1_107 inp tail_107 0 nch W=5.644u L=1.357u
M2_107 out_107 inn tail_107 0 nch W=5.644u L=1.357u
M3_107 d1_107 d1_107 vdd vdd pch W=2u L=1u
M4_107 out_107 d1_107 vdd vdd pch W=2u L=1u
M5_107 tail_107 vbias 0 0 nch W=4u L=1u
Cl_107 out_107 0 100f
* --- Instance 108: W=5.644u L=2.096u ---
M1_108 d1_108 inp tail_108 0 nch W=5.644u L=2.096u
M2_108 out_108 inn tail_108 0 nch W=5.644u L=2.096u
M3_108 d1_108 d1_108 vdd vdd pch W=2u L=1u
M4_108 out_108 d1_108 vdd vdd pch W=2u L=1u
M5_108 tail_108 vbias 0 0 nch W=4u L=1u
Cl_108 out_108 0 100f
* --- Instance 109: W=5.644u L=3.237u ---
M1_109 d1_109 inp tail_109 0 nch W=5.644u L=3.237u
M2_109 out_109 inn tail_109 0 nch W=5.644u L=3.237u
M3_109 d1_109 d1_109 vdd vdd pch W=2u L=1u
M4_109 out_109 d1_109 vdd vdd pch W=2u L=1u
M5_109 tail_109 vbias 0 0 nch W=4u L=1u
Cl_109 out_109 0 100f
* --- Instance 110: W=5.644u L=5.000u ---
M1_110 d1_110 inp tail_110 0 nch W=5.644u L=5.000u
M2_110 out_110 inn tail_110 0 nch W=5.644u L=5.000u
M3_110 d1_110 d1_110 vdd vdd pch W=2u L=1u
M4_110 out_110 d1_110 vdd vdd pch W=2u L=1u
M5_110 tail_110 vbias 0 0 nch W=4u L=1u
Cl_110 out_110 0 100f
* --- Instance 111: W=7.192u L=0.100u ---
M1_111 d1_111 inp tail_111 0 nch W=7.192u L=0.100u
M2_111 out_111 inn tail_111 0 nch W=7.192u L=0.100u
M3_111 d1_111 d1_111 vdd vdd pch W=2u L=1u
M4_111 out_111 d1_111 vdd vdd pch W=2u L=1u
M5_111 tail_111 vbias 0 0 nch W=4u L=1u
Cl_111 out_111 0 100f
* --- Instance 112: W=7.192u L=0.154u ---
M1_112 d1_112 inp tail_112 0 nch W=7.192u L=0.154u
M2_112 out_112 inn tail_112 0 nch W=7.192u L=0.154u
M3_112 d1_112 d1_112 vdd vdd pch W=2u L=1u
M4_112 out_112 d1_112 vdd vdd pch W=2u L=1u
M5_112 tail_112 vbias 0 0 nch W=4u L=1u
Cl_112 out_112 0 100f
* --- Instance 113: W=7.192u L=0.239u ---
M1_113 d1_113 inp tail_113 0 nch W=7.192u L=0.239u
M2_113 out_113 inn tail_113 0 nch W=7.192u L=0.239u
M3_113 d1_113 d1_113 vdd vdd pch W=2u L=1u
M4_113 out_113 d1_113 vdd vdd pch W=2u L=1u
M5_113 tail_113 vbias 0 0 nch W=4u L=1u
Cl_113 out_113 0 100f
* --- Instance 114: W=7.192u L=0.368u ---
M1_114 d1_114 inp tail_114 0 nch W=7.192u L=0.368u
M2_114 out_114 inn tail_114 0 nch W=7.192u L=0.368u
M3_114 d1_114 d1_114 vdd vdd pch W=2u L=1u
M4_114 out_114 d1_114 vdd vdd pch W=2u L=1u
M5_114 tail_114 vbias 0 0 nch W=4u L=1u
Cl_114 out_114 0 100f
* --- Instance 115: W=7.192u L=0.569u ---
M1_115 d1_115 inp tail_115 0 nch W=7.192u L=0.569u
M2_115 out_115 inn tail_115 0 nch W=7.192u L=0.569u
M3_115 d1_115 d1_115 vdd vdd pch W=2u L=1u
M4_115 out_115 d1_115 vdd vdd pch W=2u L=1u
M5_115 tail_115 vbias 0 0 nch W=4u L=1u
Cl_115 out_115 0 100f
* --- Instance 116: W=7.192u L=0.879u ---
M1_116 d1_116 inp tail_116 0 nch W=7.192u L=0.879u
M2_116 out_116 inn tail_116 0 nch W=7.192u L=0.879u
M3_116 d1_116 d1_116 vdd vdd pch W=2u L=1u
M4_116 out_116 d1_116 vdd vdd pch W=2u L=1u
M5_116 tail_116 vbias 0 0 nch W=4u L=1u
Cl_116 out_116 0 100f
* --- Instance 117: W=7.192u L=1.357u ---
M1_117 d1_117 inp tail_117 0 nch W=7.192u L=1.357u
M2_117 out_117 inn tail_117 0 nch W=7.192u L=1.357u
M3_117 d1_117 d1_117 vdd vdd pch W=2u L=1u
M4_117 out_117 d1_117 vdd vdd pch W=2u L=1u
M5_117 tail_117 vbias 0 0 nch W=4u L=1u
Cl_117 out_117 0 100f
* --- Instance 118: W=7.192u L=2.096u ---
M1_118 d1_118 inp tail_118 0 nch W=7.192u L=2.096u
M2_118 out_118 inn tail_118 0 nch W=7.192u L=2.096u
M3_118 d1_118 d1_118 vdd vdd pch W=2u L=1u
M4_118 out_118 d1_118 vdd vdd pch W=2u L=1u
M5_118 tail_118 vbias 0 0 nch W=4u L=1u
Cl_118 out_118 0 100f
* --- Instance 119: W=7.192u L=3.237u ---
M1_119 d1_119 inp tail_119 0 nch W=7.192u L=3.237u
M2_119 out_119 inn tail_119 0 nch W=7.192u L=3.237u
M3_119 d1_119 d1_119 vdd vdd pch W=2u L=1u
M4_119 out_119 d1_119 vdd vdd pch W=2u L=1u
M5_119 tail_119 vbias 0 0 nch W=4u L=1u
Cl_119 out_119 0 100f
* --- Instance 120: W=7.192u L=5.000u ---
M1_120 d1_120 inp tail_120 0 nch W=7.192u L=5.000u
M2_120 out_120 inn tail_120 0 nch W=7.192u L=5.000u
M3_120 d1_120 d1_120 vdd vdd pch W=2u L=1u
M4_120 out_120 d1_120 vdd vdd pch W=2u L=1u
M5_120 tail_120 vbias 0 0 nch W=4u L=1u
Cl_120 out_120 0 100f
* --- Instance 121: W=9.165u L=0.100u ---
M1_121 d1_121 inp tail_121 0 nch W=9.165u L=0.100u
M2_121 out_121 inn tail_121 0 nch W=9.165u L=0.100u
M3_121 d1_121 d1_121 vdd vdd pch W=2u L=1u
M4_121 out_121 d1_121 vdd vdd pch W=2u L=1u
M5_121 tail_121 vbias 0 0 nch W=4u L=1u
Cl_121 out_121 0 100f
* --- Instance 122: W=9.165u L=0.154u ---
M1_122 d1_122 inp tail_122 0 nch W=9.165u L=0.154u
M2_122 out_122 inn tail_122 0 nch W=9.165u L=0.154u
M3_122 d1_122 d1_122 vdd vdd pch W=2u L=1u
M4_122 out_122 d1_122 vdd vdd pch W=2u L=1u
M5_122 tail_122 vbias 0 0 nch W=4u L=1u
Cl_122 out_122 0 100f
* --- Instance 123: W=9.165u L=0.239u ---
M1_123 d1_123 inp tail_123 0 nch W=9.165u L=0.239u
M2_123 out_123 inn tail_123 0 nch W=9.165u L=0.239u
M3_123 d1_123 d1_123 vdd vdd pch W=2u L=1u
M4_123 out_123 d1_123 vdd vdd pch W=2u L=1u
M5_123 tail_123 vbias 0 0 nch W=4u L=1u
Cl_123 out_123 0 100f
* --- Instance 124: W=9.165u L=0.368u ---
M1_124 d1_124 inp tail_124 0 nch W=9.165u L=0.368u
M2_124 out_124 inn tail_124 0 nch W=9.165u L=0.368u
M3_124 d1_124 d1_124 vdd vdd pch W=2u L=1u
M4_124 out_124 d1_124 vdd vdd pch W=2u L=1u
M5_124 tail_124 vbias 0 0 nch W=4u L=1u
Cl_124 out_124 0 100f
* --- Instance 125: W=9.165u L=0.569u ---
M1_125 d1_125 inp tail_125 0 nch W=9.165u L=0.569u
M2_125 out_125 inn tail_125 0 nch W=9.165u L=0.569u
M3_125 d1_125 d1_125 vdd vdd pch W=2u L=1u
M4_125 out_125 d1_125 vdd vdd pch W=2u L=1u
M5_125 tail_125 vbias 0 0 nch W=4u L=1u
Cl_125 out_125 0 100f
* --- Instance 126: W=9.165u L=0.879u ---
M1_126 d1_126 inp tail_126 0 nch W=9.165u L=0.879u
M2_126 out_126 inn tail_126 0 nch W=9.165u L=0.879u
M3_126 d1_126 d1_126 vdd vdd pch W=2u L=1u
M4_126 out_126 d1_126 vdd vdd pch W=2u L=1u
M5_126 tail_126 vbias 0 0 nch W=4u L=1u
Cl_126 out_126 0 100f
* --- Instance 127: W=9.165u L=1.357u ---
M1_127 d1_127 inp tail_127 0 nch W=9.165u L=1.357u
M2_127 out_127 inn tail_127 0 nch W=9.165u L=1.357u
M3_127 d1_127 d1_127 vdd vdd pch W=2u L=1u
M4_127 out_127 d1_127 vdd vdd pch W=2u L=1u
M5_127 tail_127 vbias 0 0 nch W=4u L=1u
Cl_127 out_127 0 100f
* --- Instance 128: W=9.165u L=2.096u ---
M1_128 d1_128 inp tail_128 0 nch W=9.165u L=2.096u
M2_128 out_128 inn tail_128 0 nch W=9.165u L=2.096u
M3_128 d1_128 d1_128 vdd vdd pch W=2u L=1u
M4_128 out_128 d1_128 vdd vdd pch W=2u L=1u
M5_128 tail_128 vbias 0 0 nch W=4u L=1u
Cl_128 out_128 0 100f
* --- Instance 129: W=9.165u L=3.237u ---
M1_129 d1_129 inp tail_129 0 nch W=9.165u L=3.237u
M2_129 out_129 inn tail_129 0 nch W=9.165u L=3.237u
M3_129 d1_129 d1_129 vdd vdd pch W=2u L=1u
M4_129 out_129 d1_129 vdd vdd pch W=2u L=1u
M5_129 tail_129 vbias 0 0 nch W=4u L=1u
Cl_129 out_129 0 100f
* --- Instance 130: W=9.165u L=5.000u ---
M1_130 d1_130 inp tail_130 0 nch W=9.165u L=5.000u
M2_130 out_130 inn tail_130 0 nch W=9.165u L=5.000u
M3_130 d1_130 d1_130 vdd vdd pch W=2u L=1u
M4_130 out_130 d1_130 vdd vdd pch W=2u L=1u
M5_130 tail_130 vbias 0 0 nch W=4u L=1u
Cl_130 out_130 0 100f
* --- Instance 131: W=11.679u L=0.100u ---
M1_131 d1_131 inp tail_131 0 nch W=11.679u L=0.100u
M2_131 out_131 inn tail_131 0 nch W=11.679u L=0.100u
M3_131 d1_131 d1_131 vdd vdd pch W=2u L=1u
M4_131 out_131 d1_131 vdd vdd pch W=2u L=1u
M5_131 tail_131 vbias 0 0 nch W=4u L=1u
Cl_131 out_131 0 100f
* --- Instance 132: W=11.679u L=0.154u ---
M1_132 d1_132 inp tail_132 0 nch W=11.679u L=0.154u
M2_132 out_132 inn tail_132 0 nch W=11.679u L=0.154u
M3_132 d1_132 d1_132 vdd vdd pch W=2u L=1u
M4_132 out_132 d1_132 vdd vdd pch W=2u L=1u
M5_132 tail_132 vbias 0 0 nch W=4u L=1u
Cl_132 out_132 0 100f
* --- Instance 133: W=11.679u L=0.239u ---
M1_133 d1_133 inp tail_133 0 nch W=11.679u L=0.239u
M2_133 out_133 inn tail_133 0 nch W=11.679u L=0.239u
M3_133 d1_133 d1_133 vdd vdd pch W=2u L=1u
M4_133 out_133 d1_133 vdd vdd pch W=2u L=1u
M5_133 tail_133 vbias 0 0 nch W=4u L=1u
Cl_133 out_133 0 100f
* --- Instance 134: W=11.679u L=0.368u ---
M1_134 d1_134 inp tail_134 0 nch W=11.679u L=0.368u
M2_134 out_134 inn tail_134 0 nch W=11.679u L=0.368u
M3_134 d1_134 d1_134 vdd vdd pch W=2u L=1u
M4_134 out_134 d1_134 vdd vdd pch W=2u L=1u
M5_134 tail_134 vbias 0 0 nch W=4u L=1u
Cl_134 out_134 0 100f
* --- Instance 135: W=11.679u L=0.569u ---
M1_135 d1_135 inp tail_135 0 nch W=11.679u L=0.569u
M2_135 out_135 inn tail_135 0 nch W=11.679u L=0.569u
M3_135 d1_135 d1_135 vdd vdd pch W=2u L=1u
M4_135 out_135 d1_135 vdd vdd pch W=2u L=1u
M5_135 tail_135 vbias 0 0 nch W=4u L=1u
Cl_135 out_135 0 100f
* --- Instance 136: W=11.679u L=0.879u ---
M1_136 d1_136 inp tail_136 0 nch W=11.679u L=0.879u
M2_136 out_136 inn tail_136 0 nch W=11.679u L=0.879u
M3_136 d1_136 d1_136 vdd vdd pch W=2u L=1u
M4_136 out_136 d1_136 vdd vdd pch W=2u L=1u
M5_136 tail_136 vbias 0 0 nch W=4u L=1u
Cl_136 out_136 0 100f
* --- Instance 137: W=11.679u L=1.357u ---
M1_137 d1_137 inp tail_137 0 nch W=11.679u L=1.357u
M2_137 out_137 inn tail_137 0 nch W=11.679u L=1.357u
M3_137 d1_137 d1_137 vdd vdd pch W=2u L=1u
M4_137 out_137 d1_137 vdd vdd pch W=2u L=1u
M5_137 tail_137 vbias 0 0 nch W=4u L=1u
Cl_137 out_137 0 100f
* --- Instance 138: W=11.679u L=2.096u ---
M1_138 d1_138 inp tail_138 0 nch W=11.679u L=2.096u
M2_138 out_138 inn tail_138 0 nch W=11.679u L=2.096u
M3_138 d1_138 d1_138 vdd vdd pch W=2u L=1u
M4_138 out_138 d1_138 vdd vdd pch W=2u L=1u
M5_138 tail_138 vbias 0 0 nch W=4u L=1u
Cl_138 out_138 0 100f
* --- Instance 139: W=11.679u L=3.237u ---
M1_139 d1_139 inp tail_139 0 nch W=11.679u L=3.237u
M2_139 out_139 inn tail_139 0 nch W=11.679u L=3.237u
M3_139 d1_139 d1_139 vdd vdd pch W=2u L=1u
M4_139 out_139 d1_139 vdd vdd pch W=2u L=1u
M5_139 tail_139 vbias 0 0 nch W=4u L=1u
Cl_139 out_139 0 100f
* --- Instance 140: W=11.679u L=5.000u ---
M1_140 d1_140 inp tail_140 0 nch W=11.679u L=5.000u
M2_140 out_140 inn tail_140 0 nch W=11.679u L=5.000u
M3_140 d1_140 d1_140 vdd vdd pch W=2u L=1u
M4_140 out_140 d1_140 vdd vdd pch W=2u L=1u
M5_140 tail_140 vbias 0 0 nch W=4u L=1u
Cl_140 out_140 0 100f
* --- Instance 141: W=14.882u L=0.100u ---
M1_141 d1_141 inp tail_141 0 nch W=14.882u L=0.100u
M2_141 out_141 inn tail_141 0 nch W=14.882u L=0.100u
M3_141 d1_141 d1_141 vdd vdd pch W=2u L=1u
M4_141 out_141 d1_141 vdd vdd pch W=2u L=1u
M5_141 tail_141 vbias 0 0 nch W=4u L=1u
Cl_141 out_141 0 100f
* --- Instance 142: W=14.882u L=0.154u ---
M1_142 d1_142 inp tail_142 0 nch W=14.882u L=0.154u
M2_142 out_142 inn tail_142 0 nch W=14.882u L=0.154u
M3_142 d1_142 d1_142 vdd vdd pch W=2u L=1u
M4_142 out_142 d1_142 vdd vdd pch W=2u L=1u
M5_142 tail_142 vbias 0 0 nch W=4u L=1u
Cl_142 out_142 0 100f
* --- Instance 143: W=14.882u L=0.239u ---
M1_143 d1_143 inp tail_143 0 nch W=14.882u L=0.239u
M2_143 out_143 inn tail_143 0 nch W=14.882u L=0.239u
M3_143 d1_143 d1_143 vdd vdd pch W=2u L=1u
M4_143 out_143 d1_143 vdd vdd pch W=2u L=1u
M5_143 tail_143 vbias 0 0 nch W=4u L=1u
Cl_143 out_143 0 100f
* --- Instance 144: W=14.882u L=0.368u ---
M1_144 d1_144 inp tail_144 0 nch W=14.882u L=0.368u
M2_144 out_144 inn tail_144 0 nch W=14.882u L=0.368u
M3_144 d1_144 d1_144 vdd vdd pch W=2u L=1u
M4_144 out_144 d1_144 vdd vdd pch W=2u L=1u
M5_144 tail_144 vbias 0 0 nch W=4u L=1u
Cl_144 out_144 0 100f
* --- Instance 145: W=14.882u L=0.569u ---
M1_145 d1_145 inp tail_145 0 nch W=14.882u L=0.569u
M2_145 out_145 inn tail_145 0 nch W=14.882u L=0.569u
M3_145 d1_145 d1_145 vdd vdd pch W=2u L=1u
M4_145 out_145 d1_145 vdd vdd pch W=2u L=1u
M5_145 tail_145 vbias 0 0 nch W=4u L=1u
Cl_145 out_145 0 100f
* --- Instance 146: W=14.882u L=0.879u ---
M1_146 d1_146 inp tail_146 0 nch W=14.882u L=0.879u
M2_146 out_146 inn tail_146 0 nch W=14.882u L=0.879u
M3_146 d1_146 d1_146 vdd vdd pch W=2u L=1u
M4_146 out_146 d1_146 vdd vdd pch W=2u L=1u
M5_146 tail_146 vbias 0 0 nch W=4u L=1u
Cl_146 out_146 0 100f
* --- Instance 147: W=14.882u L=1.357u ---
M1_147 d1_147 inp tail_147 0 nch W=14.882u L=1.357u
M2_147 out_147 inn tail_147 0 nch W=14.882u L=1.357u
M3_147 d1_147 d1_147 vdd vdd pch W=2u L=1u
M4_147 out_147 d1_147 vdd vdd pch W=2u L=1u
M5_147 tail_147 vbias 0 0 nch W=4u L=1u
Cl_147 out_147 0 100f
* --- Instance 148: W=14.882u L=2.096u ---
M1_148 d1_148 inp tail_148 0 nch W=14.882u L=2.096u
M2_148 out_148 inn tail_148 0 nch W=14.882u L=2.096u
M3_148 d1_148 d1_148 vdd vdd pch W=2u L=1u
M4_148 out_148 d1_148 vdd vdd pch W=2u L=1u
M5_148 tail_148 vbias 0 0 nch W=4u L=1u
Cl_148 out_148 0 100f
* --- Instance 149: W=14.882u L=3.237u ---
M1_149 d1_149 inp tail_149 0 nch W=14.882u L=3.237u
M2_149 out_149 inn tail_149 0 nch W=14.882u L=3.237u
M3_149 d1_149 d1_149 vdd vdd pch W=2u L=1u
M4_149 out_149 d1_149 vdd vdd pch W=2u L=1u
M5_149 tail_149 vbias 0 0 nch W=4u L=1u
Cl_149 out_149 0 100f
* --- Instance 150: W=14.882u L=5.000u ---
M1_150 d1_150 inp tail_150 0 nch W=14.882u L=5.000u
M2_150 out_150 inn tail_150 0 nch W=14.882u L=5.000u
M3_150 d1_150 d1_150 vdd vdd pch W=2u L=1u
M4_150 out_150 d1_150 vdd vdd pch W=2u L=1u
M5_150 tail_150 vbias 0 0 nch W=4u L=1u
Cl_150 out_150 0 100f
* --- Instance 151: W=18.963u L=0.100u ---
M1_151 d1_151 inp tail_151 0 nch W=18.963u L=0.100u
M2_151 out_151 inn tail_151 0 nch W=18.963u L=0.100u
M3_151 d1_151 d1_151 vdd vdd pch W=2u L=1u
M4_151 out_151 d1_151 vdd vdd pch W=2u L=1u
M5_151 tail_151 vbias 0 0 nch W=4u L=1u
Cl_151 out_151 0 100f
* --- Instance 152: W=18.963u L=0.154u ---
M1_152 d1_152 inp tail_152 0 nch W=18.963u L=0.154u
M2_152 out_152 inn tail_152 0 nch W=18.963u L=0.154u
M3_152 d1_152 d1_152 vdd vdd pch W=2u L=1u
M4_152 out_152 d1_152 vdd vdd pch W=2u L=1u
M5_152 tail_152 vbias 0 0 nch W=4u L=1u
Cl_152 out_152 0 100f
* --- Instance 153: W=18.963u L=0.239u ---
M1_153 d1_153 inp tail_153 0 nch W=18.963u L=0.239u
M2_153 out_153 inn tail_153 0 nch W=18.963u L=0.239u
M3_153 d1_153 d1_153 vdd vdd pch W=2u L=1u
M4_153 out_153 d1_153 vdd vdd pch W=2u L=1u
M5_153 tail_153 vbias 0 0 nch W=4u L=1u
Cl_153 out_153 0 100f
* --- Instance 154: W=18.963u L=0.368u ---
M1_154 d1_154 inp tail_154 0 nch W=18.963u L=0.368u
M2_154 out_154 inn tail_154 0 nch W=18.963u L=0.368u
M3_154 d1_154 d1_154 vdd vdd pch W=2u L=1u
M4_154 out_154 d1_154 vdd vdd pch W=2u L=1u
M5_154 tail_154 vbias 0 0 nch W=4u L=1u
Cl_154 out_154 0 100f
* --- Instance 155: W=18.963u L=0.569u ---
M1_155 d1_155 inp tail_155 0 nch W=18.963u L=0.569u
M2_155 out_155 inn tail_155 0 nch W=18.963u L=0.569u
M3_155 d1_155 d1_155 vdd vdd pch W=2u L=1u
M4_155 out_155 d1_155 vdd vdd pch W=2u L=1u
M5_155 tail_155 vbias 0 0 nch W=4u L=1u
Cl_155 out_155 0 100f
* --- Instance 156: W=18.963u L=0.879u ---
M1_156 d1_156 inp tail_156 0 nch W=18.963u L=0.879u
M2_156 out_156 inn tail_156 0 nch W=18.963u L=0.879u
M3_156 d1_156 d1_156 vdd vdd pch W=2u L=1u
M4_156 out_156 d1_156 vdd vdd pch W=2u L=1u
M5_156 tail_156 vbias 0 0 nch W=4u L=1u
Cl_156 out_156 0 100f
* --- Instance 157: W=18.963u L=1.357u ---
M1_157 d1_157 inp tail_157 0 nch W=18.963u L=1.357u
M2_157 out_157 inn tail_157 0 nch W=18.963u L=1.357u
M3_157 d1_157 d1_157 vdd vdd pch W=2u L=1u
M4_157 out_157 d1_157 vdd vdd pch W=2u L=1u
M5_157 tail_157 vbias 0 0 nch W=4u L=1u
Cl_157 out_157 0 100f
* --- Instance 158: W=18.963u L=2.096u ---
M1_158 d1_158 inp tail_158 0 nch W=18.963u L=2.096u
M2_158 out_158 inn tail_158 0 nch W=18.963u L=2.096u
M3_158 d1_158 d1_158 vdd vdd pch W=2u L=1u
M4_158 out_158 d1_158 vdd vdd pch W=2u L=1u
M5_158 tail_158 vbias 0 0 nch W=4u L=1u
Cl_158 out_158 0 100f
* --- Instance 159: W=18.963u L=3.237u ---
M1_159 d1_159 inp tail_159 0 nch W=18.963u L=3.237u
M2_159 out_159 inn tail_159 0 nch W=18.963u L=3.237u
M3_159 d1_159 d1_159 vdd vdd pch W=2u L=1u
M4_159 out_159 d1_159 vdd vdd pch W=2u L=1u
M5_159 tail_159 vbias 0 0 nch W=4u L=1u
Cl_159 out_159 0 100f
* --- Instance 160: W=18.963u L=5.000u ---
M1_160 d1_160 inp tail_160 0 nch W=18.963u L=5.000u
M2_160 out_160 inn tail_160 0 nch W=18.963u L=5.000u
M3_160 d1_160 d1_160 vdd vdd pch W=2u L=1u
M4_160 out_160 d1_160 vdd vdd pch W=2u L=1u
M5_160 tail_160 vbias 0 0 nch W=4u L=1u
Cl_160 out_160 0 100f
* --- Instance 161: W=24.165u L=0.100u ---
M1_161 d1_161 inp tail_161 0 nch W=24.165u L=0.100u
M2_161 out_161 inn tail_161 0 nch W=24.165u L=0.100u
M3_161 d1_161 d1_161 vdd vdd pch W=2u L=1u
M4_161 out_161 d1_161 vdd vdd pch W=2u L=1u
M5_161 tail_161 vbias 0 0 nch W=4u L=1u
Cl_161 out_161 0 100f
* --- Instance 162: W=24.165u L=0.154u ---
M1_162 d1_162 inp tail_162 0 nch W=24.165u L=0.154u
M2_162 out_162 inn tail_162 0 nch W=24.165u L=0.154u
M3_162 d1_162 d1_162 vdd vdd pch W=2u L=1u
M4_162 out_162 d1_162 vdd vdd pch W=2u L=1u
M5_162 tail_162 vbias 0 0 nch W=4u L=1u
Cl_162 out_162 0 100f
* --- Instance 163: W=24.165u L=0.239u ---
M1_163 d1_163 inp tail_163 0 nch W=24.165u L=0.239u
M2_163 out_163 inn tail_163 0 nch W=24.165u L=0.239u
M3_163 d1_163 d1_163 vdd vdd pch W=2u L=1u
M4_163 out_163 d1_163 vdd vdd pch W=2u L=1u
M5_163 tail_163 vbias 0 0 nch W=4u L=1u
Cl_163 out_163 0 100f
* --- Instance 164: W=24.165u L=0.368u ---
M1_164 d1_164 inp tail_164 0 nch W=24.165u L=0.368u
M2_164 out_164 inn tail_164 0 nch W=24.165u L=0.368u
M3_164 d1_164 d1_164 vdd vdd pch W=2u L=1u
M4_164 out_164 d1_164 vdd vdd pch W=2u L=1u
M5_164 tail_164 vbias 0 0 nch W=4u L=1u
Cl_164 out_164 0 100f
* --- Instance 165: W=24.165u L=0.569u ---
M1_165 d1_165 inp tail_165 0 nch W=24.165u L=0.569u
M2_165 out_165 inn tail_165 0 nch W=24.165u L=0.569u
M3_165 d1_165 d1_165 vdd vdd pch W=2u L=1u
M4_165 out_165 d1_165 vdd vdd pch W=2u L=1u
M5_165 tail_165 vbias 0 0 nch W=4u L=1u
Cl_165 out_165 0 100f
* --- Instance 166: W=24.165u L=0.879u ---
M1_166 d1_166 inp tail_166 0 nch W=24.165u L=0.879u
M2_166 out_166 inn tail_166 0 nch W=24.165u L=0.879u
M3_166 d1_166 d1_166 vdd vdd pch W=2u L=1u
M4_166 out_166 d1_166 vdd vdd pch W=2u L=1u
M5_166 tail_166 vbias 0 0 nch W=4u L=1u
Cl_166 out_166 0 100f
* --- Instance 167: W=24.165u L=1.357u ---
M1_167 d1_167 inp tail_167 0 nch W=24.165u L=1.357u
M2_167 out_167 inn tail_167 0 nch W=24.165u L=1.357u
M3_167 d1_167 d1_167 vdd vdd pch W=2u L=1u
M4_167 out_167 d1_167 vdd vdd pch W=2u L=1u
M5_167 tail_167 vbias 0 0 nch W=4u L=1u
Cl_167 out_167 0 100f
* --- Instance 168: W=24.165u L=2.096u ---
M1_168 d1_168 inp tail_168 0 nch W=24.165u L=2.096u
M2_168 out_168 inn tail_168 0 nch W=24.165u L=2.096u
M3_168 d1_168 d1_168 vdd vdd pch W=2u L=1u
M4_168 out_168 d1_168 vdd vdd pch W=2u L=1u
M5_168 tail_168 vbias 0 0 nch W=4u L=1u
Cl_168 out_168 0 100f
* --- Instance 169: W=24.165u L=3.237u ---
M1_169 d1_169 inp tail_169 0 nch W=24.165u L=3.237u
M2_169 out_169 inn tail_169 0 nch W=24.165u L=3.237u
M3_169 d1_169 d1_169 vdd vdd pch W=2u L=1u
M4_169 out_169 d1_169 vdd vdd pch W=2u L=1u
M5_169 tail_169 vbias 0 0 nch W=4u L=1u
Cl_169 out_169 0 100f
* --- Instance 170: W=24.165u L=5.000u ---
M1_170 d1_170 inp tail_170 0 nch W=24.165u L=5.000u
M2_170 out_170 inn tail_170 0 nch W=24.165u L=5.000u
M3_170 d1_170 d1_170 vdd vdd pch W=2u L=1u
M4_170 out_170 d1_170 vdd vdd pch W=2u L=1u
M5_170 tail_170 vbias 0 0 nch W=4u L=1u
Cl_170 out_170 0 100f
* --- Instance 171: W=30.792u L=0.100u ---
M1_171 d1_171 inp tail_171 0 nch W=30.792u L=0.100u
M2_171 out_171 inn tail_171 0 nch W=30.792u L=0.100u
M3_171 d1_171 d1_171 vdd vdd pch W=2u L=1u
M4_171 out_171 d1_171 vdd vdd pch W=2u L=1u
M5_171 tail_171 vbias 0 0 nch W=4u L=1u
Cl_171 out_171 0 100f
* --- Instance 172: W=30.792u L=0.154u ---
M1_172 d1_172 inp tail_172 0 nch W=30.792u L=0.154u
M2_172 out_172 inn tail_172 0 nch W=30.792u L=0.154u
M3_172 d1_172 d1_172 vdd vdd pch W=2u L=1u
M4_172 out_172 d1_172 vdd vdd pch W=2u L=1u
M5_172 tail_172 vbias 0 0 nch W=4u L=1u
Cl_172 out_172 0 100f
* --- Instance 173: W=30.792u L=0.239u ---
M1_173 d1_173 inp tail_173 0 nch W=30.792u L=0.239u
M2_173 out_173 inn tail_173 0 nch W=30.792u L=0.239u
M3_173 d1_173 d1_173 vdd vdd pch W=2u L=1u
M4_173 out_173 d1_173 vdd vdd pch W=2u L=1u
M5_173 tail_173 vbias 0 0 nch W=4u L=1u
Cl_173 out_173 0 100f
* --- Instance 174: W=30.792u L=0.368u ---
M1_174 d1_174 inp tail_174 0 nch W=30.792u L=0.368u
M2_174 out_174 inn tail_174 0 nch W=30.792u L=0.368u
M3_174 d1_174 d1_174 vdd vdd pch W=2u L=1u
M4_174 out_174 d1_174 vdd vdd pch W=2u L=1u
M5_174 tail_174 vbias 0 0 nch W=4u L=1u
Cl_174 out_174 0 100f
* --- Instance 175: W=30.792u L=0.569u ---
M1_175 d1_175 inp tail_175 0 nch W=30.792u L=0.569u
M2_175 out_175 inn tail_175 0 nch W=30.792u L=0.569u
M3_175 d1_175 d1_175 vdd vdd pch W=2u L=1u
M4_175 out_175 d1_175 vdd vdd pch W=2u L=1u
M5_175 tail_175 vbias 0 0 nch W=4u L=1u
Cl_175 out_175 0 100f
* --- Instance 176: W=30.792u L=0.879u ---
M1_176 d1_176 inp tail_176 0 nch W=30.792u L=0.879u
M2_176 out_176 inn tail_176 0 nch W=30.792u L=0.879u
M3_176 d1_176 d1_176 vdd vdd pch W=2u L=1u
M4_176 out_176 d1_176 vdd vdd pch W=2u L=1u
M5_176 tail_176 vbias 0 0 nch W=4u L=1u
Cl_176 out_176 0 100f
* --- Instance 177: W=30.792u L=1.357u ---
M1_177 d1_177 inp tail_177 0 nch W=30.792u L=1.357u
M2_177 out_177 inn tail_177 0 nch W=30.792u L=1.357u
M3_177 d1_177 d1_177 vdd vdd pch W=2u L=1u
M4_177 out_177 d1_177 vdd vdd pch W=2u L=1u
M5_177 tail_177 vbias 0 0 nch W=4u L=1u
Cl_177 out_177 0 100f
* --- Instance 178: W=30.792u L=2.096u ---
M1_178 d1_178 inp tail_178 0 nch W=30.792u L=2.096u
M2_178 out_178 inn tail_178 0 nch W=30.792u L=2.096u
M3_178 d1_178 d1_178 vdd vdd pch W=2u L=1u
M4_178 out_178 d1_178 vdd vdd pch W=2u L=1u
M5_178 tail_178 vbias 0 0 nch W=4u L=1u
Cl_178 out_178 0 100f
* --- Instance 179: W=30.792u L=3.237u ---
M1_179 d1_179 inp tail_179 0 nch W=30.792u L=3.237u
M2_179 out_179 inn tail_179 0 nch W=30.792u L=3.237u
M3_179 d1_179 d1_179 vdd vdd pch W=2u L=1u
M4_179 out_179 d1_179 vdd vdd pch W=2u L=1u
M5_179 tail_179 vbias 0 0 nch W=4u L=1u
Cl_179 out_179 0 100f
* --- Instance 180: W=30.792u L=5.000u ---
M1_180 d1_180 inp tail_180 0 nch W=30.792u L=5.000u
M2_180 out_180 inn tail_180 0 nch W=30.792u L=5.000u
M3_180 d1_180 d1_180 vdd vdd pch W=2u L=1u
M4_180 out_180 d1_180 vdd vdd pch W=2u L=1u
M5_180 tail_180 vbias 0 0 nch W=4u L=1u
Cl_180 out_180 0 100f
* --- Instance 181: W=39.238u L=0.100u ---
M1_181 d1_181 inp tail_181 0 nch W=39.238u L=0.100u
M2_181 out_181 inn tail_181 0 nch W=39.238u L=0.100u
M3_181 d1_181 d1_181 vdd vdd pch W=2u L=1u
M4_181 out_181 d1_181 vdd vdd pch W=2u L=1u
M5_181 tail_181 vbias 0 0 nch W=4u L=1u
Cl_181 out_181 0 100f
* --- Instance 182: W=39.238u L=0.154u ---
M1_182 d1_182 inp tail_182 0 nch W=39.238u L=0.154u
M2_182 out_182 inn tail_182 0 nch W=39.238u L=0.154u
M3_182 d1_182 d1_182 vdd vdd pch W=2u L=1u
M4_182 out_182 d1_182 vdd vdd pch W=2u L=1u
M5_182 tail_182 vbias 0 0 nch W=4u L=1u
Cl_182 out_182 0 100f
* --- Instance 183: W=39.238u L=0.239u ---
M1_183 d1_183 inp tail_183 0 nch W=39.238u L=0.239u
M2_183 out_183 inn tail_183 0 nch W=39.238u L=0.239u
M3_183 d1_183 d1_183 vdd vdd pch W=2u L=1u
M4_183 out_183 d1_183 vdd vdd pch W=2u L=1u
M5_183 tail_183 vbias 0 0 nch W=4u L=1u
Cl_183 out_183 0 100f
* --- Instance 184: W=39.238u L=0.368u ---
M1_184 d1_184 inp tail_184 0 nch W=39.238u L=0.368u
M2_184 out_184 inn tail_184 0 nch W=39.238u L=0.368u
M3_184 d1_184 d1_184 vdd vdd pch W=2u L=1u
M4_184 out_184 d1_184 vdd vdd pch W=2u L=1u
M5_184 tail_184 vbias 0 0 nch W=4u L=1u
Cl_184 out_184 0 100f
* --- Instance 185: W=39.238u L=0.569u ---
M1_185 d1_185 inp tail_185 0 nch W=39.238u L=0.569u
M2_185 out_185 inn tail_185 0 nch W=39.238u L=0.569u
M3_185 d1_185 d1_185 vdd vdd pch W=2u L=1u
M4_185 out_185 d1_185 vdd vdd pch W=2u L=1u
M5_185 tail_185 vbias 0 0 nch W=4u L=1u
Cl_185 out_185 0 100f
* --- Instance 186: W=39.238u L=0.879u ---
M1_186 d1_186 inp tail_186 0 nch W=39.238u L=0.879u
M2_186 out_186 inn tail_186 0 nch W=39.238u L=0.879u
M3_186 d1_186 d1_186 vdd vdd pch W=2u L=1u
M4_186 out_186 d1_186 vdd vdd pch W=2u L=1u
M5_186 tail_186 vbias 0 0 nch W=4u L=1u
Cl_186 out_186 0 100f
* --- Instance 187: W=39.238u L=1.357u ---
M1_187 d1_187 inp tail_187 0 nch W=39.238u L=1.357u
M2_187 out_187 inn tail_187 0 nch W=39.238u L=1.357u
M3_187 d1_187 d1_187 vdd vdd pch W=2u L=1u
M4_187 out_187 d1_187 vdd vdd pch W=2u L=1u
M5_187 tail_187 vbias 0 0 nch W=4u L=1u
Cl_187 out_187 0 100f
* --- Instance 188: W=39.238u L=2.096u ---
M1_188 d1_188 inp tail_188 0 nch W=39.238u L=2.096u
M2_188 out_188 inn tail_188 0 nch W=39.238u L=2.096u
M3_188 d1_188 d1_188 vdd vdd pch W=2u L=1u
M4_188 out_188 d1_188 vdd vdd pch W=2u L=1u
M5_188 tail_188 vbias 0 0 nch W=4u L=1u
Cl_188 out_188 0 100f
* --- Instance 189: W=39.238u L=3.237u ---
M1_189 d1_189 inp tail_189 0 nch W=39.238u L=3.237u
M2_189 out_189 inn tail_189 0 nch W=39.238u L=3.237u
M3_189 d1_189 d1_189 vdd vdd pch W=2u L=1u
M4_189 out_189 d1_189 vdd vdd pch W=2u L=1u
M5_189 tail_189 vbias 0 0 nch W=4u L=1u
Cl_189 out_189 0 100f
* --- Instance 190: W=39.238u L=5.000u ---
M1_190 d1_190 inp tail_190 0 nch W=39.238u L=5.000u
M2_190 out_190 inn tail_190 0 nch W=39.238u L=5.000u
M3_190 d1_190 d1_190 vdd vdd pch W=2u L=1u
M4_190 out_190 d1_190 vdd vdd pch W=2u L=1u
M5_190 tail_190 vbias 0 0 nch W=4u L=1u
Cl_190 out_190 0 100f
* --- Instance 191: W=50.000u L=0.100u ---
M1_191 d1_191 inp tail_191 0 nch W=50.000u L=0.100u
M2_191 out_191 inn tail_191 0 nch W=50.000u L=0.100u
M3_191 d1_191 d1_191 vdd vdd pch W=2u L=1u
M4_191 out_191 d1_191 vdd vdd pch W=2u L=1u
M5_191 tail_191 vbias 0 0 nch W=4u L=1u
Cl_191 out_191 0 100f
* --- Instance 192: W=50.000u L=0.154u ---
M1_192 d1_192 inp tail_192 0 nch W=50.000u L=0.154u
M2_192 out_192 inn tail_192 0 nch W=50.000u L=0.154u
M3_192 d1_192 d1_192 vdd vdd pch W=2u L=1u
M4_192 out_192 d1_192 vdd vdd pch W=2u L=1u
M5_192 tail_192 vbias 0 0 nch W=4u L=1u
Cl_192 out_192 0 100f
* --- Instance 193: W=50.000u L=0.239u ---
M1_193 d1_193 inp tail_193 0 nch W=50.000u L=0.239u
M2_193 out_193 inn tail_193 0 nch W=50.000u L=0.239u
M3_193 d1_193 d1_193 vdd vdd pch W=2u L=1u
M4_193 out_193 d1_193 vdd vdd pch W=2u L=1u
M5_193 tail_193 vbias 0 0 nch W=4u L=1u
Cl_193 out_193 0 100f
* --- Instance 194: W=50.000u L=0.368u ---
M1_194 d1_194 inp tail_194 0 nch W=50.000u L=0.368u
M2_194 out_194 inn tail_194 0 nch W=50.000u L=0.368u
M3_194 d1_194 d1_194 vdd vdd pch W=2u L=1u
M4_194 out_194 d1_194 vdd vdd pch W=2u L=1u
M5_194 tail_194 vbias 0 0 nch W=4u L=1u
Cl_194 out_194 0 100f
* --- Instance 195: W=50.000u L=0.569u ---
M1_195 d1_195 inp tail_195 0 nch W=50.000u L=0.569u
M2_195 out_195 inn tail_195 0 nch W=50.000u L=0.569u
M3_195 d1_195 d1_195 vdd vdd pch W=2u L=1u
M4_195 out_195 d1_195 vdd vdd pch W=2u L=1u
M5_195 tail_195 vbias 0 0 nch W=4u L=1u
Cl_195 out_195 0 100f
* --- Instance 196: W=50.000u L=0.879u ---
M1_196 d1_196 inp tail_196 0 nch W=50.000u L=0.879u
M2_196 out_196 inn tail_196 0 nch W=50.000u L=0.879u
M3_196 d1_196 d1_196 vdd vdd pch W=2u L=1u
M4_196 out_196 d1_196 vdd vdd pch W=2u L=1u
M5_196 tail_196 vbias 0 0 nch W=4u L=1u
Cl_196 out_196 0 100f
* --- Instance 197: W=50.000u L=1.357u ---
M1_197 d1_197 inp tail_197 0 nch W=50.000u L=1.357u
M2_197 out_197 inn tail_197 0 nch W=50.000u L=1.357u
M3_197 d1_197 d1_197 vdd vdd pch W=2u L=1u
M4_197 out_197 d1_197 vdd vdd pch W=2u L=1u
M5_197 tail_197 vbias 0 0 nch W=4u L=1u
Cl_197 out_197 0 100f
* --- Instance 198: W=50.000u L=2.096u ---
M1_198 d1_198 inp tail_198 0 nch W=50.000u L=2.096u
M2_198 out_198 inn tail_198 0 nch W=50.000u L=2.096u
M3_198 d1_198 d1_198 vdd vdd pch W=2u L=1u
M4_198 out_198 d1_198 vdd vdd pch W=2u L=1u
M5_198 tail_198 vbias 0 0 nch W=4u L=1u
Cl_198 out_198 0 100f
* --- Instance 199: W=50.000u L=3.237u ---
M1_199 d1_199 inp tail_199 0 nch W=50.000u L=3.237u
M2_199 out_199 inn tail_199 0 nch W=50.000u L=3.237u
M3_199 d1_199 d1_199 vdd vdd pch W=2u L=1u
M4_199 out_199 d1_199 vdd vdd pch W=2u L=1u
M5_199 tail_199 vbias 0 0 nch W=4u L=1u
Cl_199 out_199 0 100f
* --- Instance 200: W=50.000u L=5.000u ---
M1_200 d1_200 inp tail_200 0 nch W=50.000u L=5.000u
M2_200 out_200 inn tail_200 0 nch W=50.000u L=5.000u
M3_200 d1_200 d1_200 vdd vdd pch W=2u L=1u
M4_200 out_200 d1_200 vdd vdd pch W=2u L=1u
M5_200 tail_200 vbias 0 0 nch W=4u L=1u
Cl_200 out_200 0 100f
*
.ac dec 10 1 1G
.end
