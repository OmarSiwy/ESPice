# Simulator benchmark

- espice: `espice` — espice 0.1.0
- ngspice: `ngspice` — ngspice-45 : Circuit level simulation program
- vacask: `vacask` — This is vacask unknown.
- column espice: ` espice --backend=cpu`

Median of 3 measured runs after one warm-up; milliseconds include process startup and output. VACASK conversion is outside timing.

| Fixture | espice ms | ngspice ms | VACASK ms | espice/ngspice | espice/VACASK | ngspice/VACASK |
|---|---:|---:|---:|---|---|---|
| ac/bench_adversarial_extreme_values.sp | 4.185 | 16.606 | 16.868 | agree | agree | agree |
| ac/bench_bjt_common_emitter.sp | 4.730 | 16.368 | 17.072 | agree | agree | agree |
| ac/bench_medium_ladder_filter.sp | 5.088 | 16.717 | 17.582 | agree | agree | agree |
| ac/buffered_two_poles.sp | 4.389 | 15.120 | 16.569 | agree | agree | agree |
| ac/current_source_rc.sp | 4.361 | 11.941 | 16.466 | agree | agree | agree |
| ac/dec_lane_tail_15.sp | 3.955 | 14.069 | 12.592 | agree | agree | agree |
| ac/dec_lane_tail_16.sp | 4.140 | 15.571 | 14.487 | agree | unavailable | unavailable |
| ac/dec_lane_tail_17.sp | 4.104 | 12.475 | 13.084 | agree | agree | agree |
| ac/dec_lane_tail_2.sp | 4.779 | 13.229 | 14.024 | agree | agree | agree |
| ac/dec_lane_tail_3.sp | 4.028 | 15.922 | 15.805 | agree | agree | agree |
| ac/dec_lane_tail_31.sp | 4.054 | 16.520 | 13.554 | agree | unavailable | unavailable |
| ac/dec_lane_tail_32.sp | 4.445 | 12.467 | 14.759 | agree | agree | agree |
| ac/dec_lane_tail_33.sp | 4.796 | 16.065 | 13.449 | agree | agree | agree |
| ac/dec_lane_tail_4.sp | 4.022 | 13.126 | 12.528 | agree | agree | agree |
| ac/dec_lane_tail_5.sp | 4.557 | 12.421 | 16.446 | agree | agree | agree |
| ac/dec_lane_tail_65.sp | 3.495 | 11.233 | 12.353 | agree | agree | agree |
| ac/dec_lane_tail_7.sp | 4.594 | 11.919 | 15.009 | agree | agree | agree |
| ac/dec_lane_tail_8.sp | 4.350 | 11.799 | 17.110 | agree | agree | agree |
| ac/dec_lane_tail_9.sp | 4.365 | 16.134 | 15.927 | agree | agree | agree |
| ac/device_bsim4_capmod2.sp | 4.714 | 16.396 | 17.579 | agree | agree | agree |
| ac/device_capacitor_ac.sp | 4.251 | 15.713 | 16.510 | agree | agree | agree |
| ac/device_diode_capacitance.sp | 4.593 | 13.267 | 16.401 | agree | agree | agree |
| ac/device_inductor_ac.sp | 4.379 | 15.450 | 11.693 | agree | agree | agree |
| ac/device_tline_delay.sp | 3.286 | 15.593 | — | agree | unavailable | unavailable |
| ac/device_urc_ac.sp | 5.020 | 11.810 | — | agree | unavailable | unavailable |
| ac/diode_linearization_0p4.sp | 4.470 | 16.050 | 11.977 | agree | agree | agree |
| ac/diode_linearization_0p7.sp | 4.022 | 15.163 | 16.577 | agree | agree | agree |
| ac/diode_linearization_5.sp | 4.510 | 15.766 | 16.005 | agree | agree | agree |
| ac/divider_phase_0.sp | 4.461 | 15.801 | 15.966 | agree | agree | agree |
| ac/divider_phase_180.sp | 4.058 | 12.652 | 16.048 | agree | agree | agree |
| ac/divider_phase_45.sp | 4.117 | 11.369 | 11.022 | agree | agree | agree |
| ac/divider_phase_90.sp | 3.848 | 15.380 | 15.731 | agree | agree | agree |
| ac/divider_phase_minus90.sp | 3.976 | 12.321 | 12.783 | agree | agree | agree |
| ac/floating_ac_source.sp | 4.132 | 11.612 | 15.417 | agree | agree | agree |
| ac/lane_tail_15.sp | 4.270 | 16.016 | 16.703 | agree | agree | agree |
| ac/lane_tail_16.sp | 4.316 | 11.754 | 16.761 | agree | agree | agree |
| ac/lane_tail_17.sp | 4.435 | 16.260 | 16.524 | agree | agree | agree |
| ac/lane_tail_2.sp | 4.403 | 16.272 | 16.456 | unavailable | agree | unavailable |
| ac/lane_tail_3.sp | 4.311 | 11.963 | 15.997 | agree | agree | agree |
| ac/lane_tail_31.sp | 4.214 | 12.910 | 11.952 | agree | agree | agree |
| ac/lane_tail_32.sp | 4.335 | 11.796 | 15.493 | agree | agree | agree |
| ac/lane_tail_33.sp | 3.943 | 12.144 | 11.227 | agree | agree | agree |
| ac/lane_tail_4.sp | 4.398 | 13.767 | 12.316 | agree | agree | agree |
| ac/lane_tail_5.sp | 3.625 | 11.771 | 16.020 | agree | agree | agree |
| ac/lane_tail_65.sp | 3.786 | 15.313 | 16.284 | agree | agree | agree |
| ac/lane_tail_7.sp | 4.177 | 16.233 | 16.538 | agree | agree | agree |
| ac/lane_tail_8.sp | 4.333 | 11.129 | 17.085 | agree | agree | agree |
| ac/lane_tail_9.sp | 4.314 | 15.662 | 11.827 | agree | agree | agree |
| ac/no_ac_drive.sp | 3.999 | 15.869 | 11.456 | agree | agree | agree |
| ac/notch_tank.sp | 4.757 | 15.287 | 16.864 | agree | agree | agree |
| ac/rc_dec_3_10_730.sp | 4.578 | 15.253 | 11.964 | DIFFER | unavailable | unavailable |
| ac/rc_dec_4_100_100.sp | 3.716 | 15.990 | 17.122 | agree | agree | agree |
| ac/rc_dec_4_10_10000.sp | 4.483 | 15.572 | 13.543 | agree | agree | agree |
| ac/rc_highpass.sp | 4.322 | 16.003 | 17.052 | agree | agree | agree |
| ac/rc_lin_1_100_100.sp | 4.195 | 15.915 | — | agree | unavailable | unavailable |
| ac/rc_lin_9_0_1000.sp | 3.402 | 14.769 | 12.590 | agree | agree | agree |
| ac/rc_oct_2_10_1280.sp | 4.172 | 11.681 | 11.907 | agree | agree | agree |
| ac/resistance_ac_override.sp | 4.214 | 15.041 | — | agree | unavailable | unavailable |
| ac/rl_highpass.sp | 3.668 | 16.091 | 17.406 | agree | agree | agree |
| ac/rl_lowpass.sp | 4.574 | 15.588 | 16.337 | agree | agree | agree |
| ac/rlc_bandpass.sp | 4.104 | 14.807 | 17.129 | agree | agree | agree |
| ac/rlc_lowpass.sp | 4.322 | 16.578 | 17.007 | agree | agree | agree |
| ac/rlc_near_resonance_0p001.sp | 4.686 | 13.300 | 12.469 | agree | agree | agree |
| ac/rlc_near_resonance_0p1.sp | 4.105 | 14.239 | 12.506 | agree | agree | agree |
| ac/rlc_near_resonance_1.sp | 4.296 | 14.477 | 16.566 | agree | agree | agree |
| ac/rlc_near_resonance_10.sp | 4.213 | 15.470 | 16.952 | agree | agree | agree |
| ac/second_source_drive.sp | 4.183 | 14.902 | 15.850 | agree | agree | agree |
| ac/two_drive_cancellation.sp | 4.705 | 14.136 | 16.340 | agree | agree | agree |
| ac/two_drive_quadrature.sp | 4.485 | 11.866 | 11.574 | agree | agree | agree |
| ac/unbuffered_rc_ladder.sp | 4.486 | 16.514 | 16.933 | agree | agree | agree |
| ac/vccs_transimpedance.sp | 4.355 | 13.262 | 16.532 | agree | agree | agree |
| aliases/envlp.sp | 3.920 | — | — | unavailable | unavailable | unavailable |
| aliases/montecarlo.sp | 4.018 | — | — | unavailable | unavailable | unavailable |
| aliases/tran_noise.sp | 4.146 | — | — | unavailable | unavailable | unavailable |
| convergence/bench_diode_bridge.sp | 4.061 | 15.257 | 13.970 | agree | agree | agree |
| convergence/bench_high_gain_fb.sp | 3.850 | 15.596 | 15.924 | agree | agree | agree |
| convergence/bench_mos_latch_ladder.sp | 5.712 | 16.824 | 19.897 | agree | agree | agree |
| convergence/bench_mos_series_r.sp | 4.810 | 16.227 | 17.985 | agree | agree | agree |
| convergence/bench_ota_cutoff_abstol.sp | 30.335 | 45.766 | 115.882 | agree | agree | agree |
| convergence/bench_schmitt.sp | 4.291 | 10.814 | 16.215 | agree | agree | agree |
| convergence/diode_bad_nodeset_negative.sp | 4.273 | 14.283 | — | agree | unavailable | unavailable |
| convergence/diode_bad_nodeset_positive.sp | 3.970 | 17.419 | — | agree | unavailable | unavailable |
| convergence/diode_emission_two.sp | 4.179 | 15.839 | 16.974 | agree | agree | agree |
| convergence/diode_forward.sp | 4.215 | 15.894 | 16.431 | agree | agree | agree |
| convergence/diode_high_current.sp | 4.135 | 16.175 | 16.716 | agree | agree | agree |
| convergence/diode_knee.sp | 4.267 | 16.295 | 17.333 | agree | agree | agree |
| convergence/diode_large_is.sp | 4.279 | 14.256 | 17.391 | agree | agree | agree |
| convergence/diode_reverse.sp | 4.065 | 15.021 | 15.823 | agree | agree | agree |
| convergence/diode_small_is.sp | 3.982 | 15.701 | 11.347 | agree | agree | agree |
| convergence/diode_stack_2.sp | 3.824 | 11.594 | 13.404 | agree | agree | agree |
| convergence/diode_stack_32.sp | 4.894 | 14.462 | 17.496 | agree | agree | agree |
| convergence/diode_stack_8.sp | 3.752 | 14.356 | 16.109 | agree | agree | agree |
| convergence/diode_weak_current.sp | 4.397 | 11.466 | 11.570 | agree | agree | agree |
| convergence/diode_zero.sp | 3.865 | 15.560 | 16.839 | agree | agree | agree |
| convergence/monotonic_cubic_0p001.sp | 3.916 | 15.751 | — | agree | unavailable | unavailable |
| convergence/monotonic_cubic_1.sp | 3.701 | 15.490 | — | agree | unavailable | unavailable |
| convergence/monotonic_cubic_1000.sp | 3.964 | 15.670 | — | agree | unavailable | unavailable |
| convergence/monotonic_cubic_1e-09.sp | 4.095 | 13.381 | — | agree | unavailable | unavailable |
| convergence/negative_feedback_1000.sp | 3.803 | 12.827 | 11.839 | agree | agree | agree |
| convergence/negative_feedback_1000000.sp | 4.087 | 12.120 | 15.906 | agree | agree | agree |
| convergence/negative_feedback_1000000000.sp | 4.072 | 15.658 | 14.166 | agree | agree | agree |
| convergence/resistor_chain_257.sp | 4.745 | 16.694 | 19.289 | agree | agree | agree |
| convergence/resistor_chain_31.sp | 4.446 | 15.891 | 17.617 | agree | agree | agree |
| convergence/resistor_chain_64.sp | 4.891 | 16.152 | 17.453 | agree | agree | agree |
| convergence/resistor_chain_8.sp | 3.946 | 15.829 | 12.751 | agree | agree | agree |
| dc/ascending.sp | 4.265 | 16.072 | 16.432 | agree | agree | agree |
| dc/bench_bjt_diff_amp.sp | 4.641 | 16.080 | 18.401 | agree | agree | agree |
| dc/bench_dc_sweep_nested_sweep.sp | 4.577 | 12.884 | 14.055 | agree | agree | agree |
| dc/bench_dc_sweep_param_sweep.sp | 4.457 | 13.277 | 11.951 | agree | agree | agree |
| dc/bench_dc_sweep_vin_sweep.sp | 4.180 | 15.327 | 13.596 | agree | agree | agree |
| dc/bench_ensemble_sweep_lanes.sp | 4.485 | 11.658 | 11.301 | agree | agree | agree |
| dc/bench_mosfet_cmos_inverter.sp | 4.676 | 16.249 | 16.917 | agree | agree | agree |
| dc/bench_power_zener_reg.sp | 4.517 | 15.637 | 11.911 | agree | agree | agree |
| dc/bench_sweep_amp_bias_sweep.sp | 5.476 | 16.054 | 14.452 | agree | agree | agree |
| dc/bench_sweep_cmos_inv_sizing.sp | 4.933 | 13.490 | 17.934 | agree | agree | agree |
| dc/bench_sweep_nmos_wl_opt.sp | 5.255 | 15.996 | 13.305 | agree | agree | agree |
| dc/bench_sweep_pmos_wl_opt.sp | 5.405 | 18.644 | 17.916 | agree | agree | agree |
| dc/current_ascending.sp | 4.163 | 11.612 | 15.693 | agree | agree | agree |
| dc/current_descending.sp | 4.029 | 12.545 | 13.787 | agree | agree | agree |
| dc/descending.sp | 4.224 | 15.950 | 16.471 | agree | agree | agree |
| dc/device_b3soidd_output.sp | 11.014 | 23.503 | — | agree | unavailable | unavailable |
| dc/device_b3soifd_output.sp | 8.649 | 22.550 | — | agree | unavailable | unavailable |
| dc/device_b3soipd_output.sp | 14.347 | 60.323 | — | agree | unavailable | unavailable |
| dc/device_b4soi_output.sp | 10.063 | 40.689 | — | agree | unavailable | unavailable |
| dc/device_bjt_npn_early.sp | 8.805 | 22.131 | 18.483 | agree | agree | agree |
| dc/device_bjt_npn_gummel.sp | 4.434 | 16.458 | 14.361 | agree | agree | agree |
| dc/device_bjt_npn_high_injection.sp | 4.999 | 13.777 | 12.765 | agree | agree | agree |
| dc/device_bjt_npn_output.sp | 7.866 | 17.393 | 17.820 | agree | agree | agree |
| dc/device_bjt_npn_saturation.sp | 6.546 | 16.055 | 15.144 | agree | agree | agree |
| dc/device_bjt_npn_temp.sp | 5.605 | 16.827 | — | agree | unavailable | unavailable |
| dc/device_bjt_pnp_output.sp | 8.475 | 21.842 | 25.781 | agree | agree | agree |
| dc/device_bsim1.sp | 7.797 | 15.357 | — | agree | unavailable | unavailable |
| dc/device_bsim2.sp | 10.005 | 22.422 | — | agree | unavailable | unavailable |
| dc/device_bsim2_ngspice.sp | 11.002 | 19.697 | — | agree | unavailable | unavailable |
| dc/device_bsim3_body_effect.sp | 8.190 | 61.986 | — | agree | unavailable | unavailable |
| dc/device_bsim3_output.sp | 7.547 | 59.246 | — | agree | unavailable | unavailable |
| dc/device_bsim3_pmos.sp | 7.801 | 59.098 | — | agree | unavailable | unavailable |
| dc/device_bsim3_temp.sp | 8.275 | 66.747 | — | agree | unavailable | unavailable |
| dc/device_bsim3_transfer.sp | 5.028 | 24.930 | — | agree | unavailable | unavailable |
| dc/device_bsim4_output.sp | 8.839 | 39.163 | — | agree | unavailable | unavailable |
| dc/device_bsim4_pmos.sp | 7.889 | 41.891 | — | agree | unavailable | unavailable |
| dc/device_bsim4_transfer.sp | 5.851 | 20.359 | — | agree | unavailable | unavailable |
| dc/device_diode_breakdown.sp | 4.432 | 13.952 | 15.607 | agree | agree | agree |
| dc/device_diode_high_injection.sp | 4.837 | 15.428 | 14.056 | agree | agree | agree |
| dc/device_diode_iv_sweep.sp | 5.624 | 18.009 | 15.418 | agree | agree | agree |
| dc/device_diode_recombination.sp | 4.706 | 13.002 | 13.600 | agree | agree | agree |
| dc/device_diode_temp.sp | 5.248 | 18.888 | — | agree | unavailable | unavailable |
| dc/device_hfet1_output.sp | 8.921 | 18.837 | — | agree | unavailable | unavailable |
| dc/device_hfet2_output.sp | 9.327 | 22.078 | — | agree | unavailable | unavailable |
| dc/device_hfet_id_vgs.sp | 4.703 | 16.065 | — | agree | unavailable | unavailable |
| dc/device_hicum2_gummel.sp | 5.067 | 15.508 | — | agree | unavailable | unavailable |
| dc/device_hicum2_output.sp | 14.750 | 25.075 | — | agree | unavailable | unavailable |
| dc/device_hisim2.sp | 25.102 | 52.698 | — | agree | unavailable | unavailable |
| dc/device_hisimhv.sp | 31.546 | 30.513 | — | agree | unavailable | unavailable |
| dc/device_jfet2.sp | 8.503 | 22.064 | — | agree | unavailable | unavailable |
| dc/device_jfet_output.sp | 6.364 | 20.492 | 18.456 | agree | agree | agree |
| dc/device_jfet_transfer.sp | 5.036 | 17.448 | 18.208 | agree | agree | agree |
| dc/device_mesa_inverter.sp | 5.990 | 17.874 | — | agree | unavailable | unavailable |
| dc/device_mesa_output.sp | 10.510 | 21.025 | — | agree | unavailable | unavailable |
| dc/device_mesfet_output.sp | 7.498 | 19.175 | — | agree | unavailable | unavailable |
| dc/device_mesfet_subthreshold.sp | 4.813 | 16.552 | — | agree | unavailable | unavailable |
| dc/device_mesfet_transfer.sp | 4.928 | 12.790 | — | agree | unavailable | unavailable |
| dc/device_mos1_body_effect.sp | 6.490 | 22.378 | 22.748 | agree | agree | agree |
| dc/device_mos1_output.sp | 7.165 | 21.341 | 21.293 | agree | agree | agree |
| dc/device_mos1_pmos.sp | 6.398 | 19.459 | 19.883 | agree | agree | agree |
| dc/device_mos1_subthreshold.sp | 5.424 | 17.399 | 15.451 | agree | agree | agree |
| dc/device_mos1_temp.sp | 6.634 | 17.968 | — | agree | unavailable | unavailable |
| dc/device_mos1_transfer.sp | 4.688 | 17.585 | 16.612 | agree | agree | agree |
| dc/device_mos2.sp | 7.228 | 23.376 | 28.005 | agree | agree | agree |
| dc/device_mos2_transfer.sp | 5.256 | 17.558 | 14.153 | agree | agree | agree |
| dc/device_mos3.sp | 7.784 | 20.734 | — | agree | unavailable | unavailable |
| dc/device_mos3_transfer.sp | 5.282 | 13.339 | — | agree | unavailable | unavailable |
| dc/device_mos6.sp | 7.142 | 16.830 | 21.066 | agree | agree | agree |
| dc/device_mos9.sp | 7.741 | 18.746 | — | agree | unavailable | unavailable |
| dc/device_resistor_temp.sp | 4.824 | 11.988 | — | agree | unavailable | unavailable |
| dc/device_vbic_forced_output.sp | 9.416 | 17.276 | — | agree | unavailable | unavailable |
| dc/device_vbic_gummel.sp | 5.835 | 14.604 | — | agree | unavailable | unavailable |
| dc/device_vbic_output.sp | 12.877 | 22.846 | — | agree | unavailable | unavailable |
| dc/device_vbic_temp.sp | 5.716 | 15.831 | — | agree | unavailable | unavailable |
| dc/device_vdmos_output.sp | 8.046 | 24.079 | — | agree | unavailable | unavailable |
| dc/diode_forward.sp | 4.517 | 16.147 | 17.063 | agree | agree | agree |
| dc/diode_reverse.sp | 4.407 | 16.599 | 17.293 | agree | agree | agree |
| dc/diode_reverse_continuation.sp | 4.716 | 15.970 | 16.261 | agree | agree | agree |
| dc/fine_step.sp | 4.395 | 15.652 | 13.364 | agree | agree | agree |
| dc/mixed_voltage_current.sp | 4.379 | 16.003 | 17.558 | agree | agree | agree |
| dc/nested_sources.sp | 4.321 | 15.461 | 16.977 | agree | agree | agree |
| dc/nodeset_sweep_latch.sp | 4.305 | 13.831 | — | agree | unavailable | unavailable |
| dc/nondivisible_stop.sp | 3.806 | 15.087 | 12.954 | agree | agree | agree |
| dc/resistor_sweep.sp | 4.332 | 14.979 | — | agree | unavailable | unavailable |
| dc/second_voltage_source.sp | 4.441 | 12.597 | 12.580 | agree | agree | agree |
| dc/single_point.sp | 4.421 | 11.956 | — | agree | unavailable | unavailable |
| dc/zero_crossing.sp | 4.487 | 13.935 | 12.169 | agree | agree | agree |
| dcmatch/divider_0_1000.sp | 4.655 | — | — | unavailable | unavailable | unavailable |
| dcmatch/divider_10_1000.sp | 4.682 | — | — | unavailable | unavailable | unavailable |
| dcmatch/divider_1_0p001.sp | 3.995 | — | — | unavailable | unavailable | unavailable |
| dcmatch/high_resistance.sp | 4.353 | — | — | unavailable | unavailable | unavailable |
| dcmatch/unit_source.sp | 4.690 | — | — | unavailable | unavailable | unavailable |
| dcmatch/zero_source.sp | 5.011 | — | — | unavailable | unavailable | unavailable |
| disto/bench_disto_bjt_ce.sp | 6.092 | 16.154 | — | agree | unavailable | unavailable |
| disto/bench_disto_diode_clipper.sp | 5.072 | 16.393 | — | agree | unavailable | unavailable |
| disto/bench_disto_mos_cs.sp | 5.727 | 16.453 | — | agree | unavailable | unavailable |
| disto/bjt_caps.sp | 4.955 | 15.848 | — | agree | unavailable | unavailable |
| disto/diode_0p001.sp | 4.905 | 12.966 | — | agree | unavailable | unavailable |
| disto/diode_0p002.sp | 4.801 | 14.316 | — | agree | unavailable | unavailable |
| disto/diode_0p01.sp | 4.871 | 15.917 | — | agree | unavailable | unavailable |
| disto/diode_cap.sp | 5.143 | 14.441 | — | agree | unavailable | unavailable |
| disto/linear_divider_0p001.sp | 4.788 | 12.828 | — | agree | unavailable | unavailable |
| disto/linear_divider_0p01.sp | 5.157 | 16.318 | — | agree | unavailable | unavailable |
| disto/linear_divider_0p1.sp | 5.060 | 11.951 | — | agree | unavailable | unavailable |
| disto/two_tone_bjt_caps.sp | 5.653 | 13.620 | — | agree | unavailable | unavailable |
| disto/two_tone_bjt_ce.sp | 5.616 | 12.902 | — | agree | unavailable | unavailable |
| disto/two_tone_diode.sp | 5.228 | 12.701 | — | agree | unavailable | unavailable |
| disto/two_tone_diode_cap.sp | 4.887 | 13.893 | — | agree | unavailable | unavailable |
| disto/two_tone_diode_rc.sp | 4.271 | 16.417 | — | agree | unavailable | unavailable |
| envelope/dc_offset.sp | 4.318 | — | — | unavailable | unavailable | unavailable |
| envelope/dc_only.sp | 3.931 | — | — | unavailable | unavailable | unavailable |
| envelope/negative_offset.sp | 4.575 | — | — | unavailable | unavailable | unavailable |
| envelope/rc_startup_0p001.sp | 4.309 | — | — | unavailable | unavailable | unavailable |
| envelope/rc_startup_1e-05.sp | 4.323 | — | — | unavailable | unavailable | unavailable |
| envelope/sine.sp | 4.611 | — | — | unavailable | unavailable | unavailable |
| envelope/zero.sp | 4.017 | — | — | unavailable | unavailable | unavailable |
| four/dc_only.sp | 14.636 | 81.937 | — | agree | unavailable | unavailable |
| four/harmonic_count_1.sp | 18.238 | 78.152 | — | agree | unavailable | unavailable |
| four/harmonic_count_16.sp | 13.386 | 76.080 | — | agree | unavailable | unavailable |
| four/harmonic_count_3.sp | 14.261 | 97.229 | — | agree | unavailable | unavailable |
| four/multi_output.sp | 7.781 | 19.845 | — | agree | unavailable | unavailable |
| four/offset.sp | 13.749 | 64.645 | — | agree | unavailable | unavailable |
| four/phase_0.sp | 13.178 | 64.188 | — | agree | unavailable | unavailable |
| four/phase_180.sp | 18.133 | 73.997 | — | agree | unavailable | unavailable |
| four/phase_30.sp | 16.546 | 73.012 | — | agree | unavailable | unavailable |
| four/phase_90.sp | 18.151 | 63.084 | — | agree | unavailable | unavailable |
| four/polynomial_2.sp | 24.562 | 69.605 | — | agree | unavailable | unavailable |
| four/polynomial_3.sp | 33.473 | 81.296 | — | DIFFER | unavailable | unavailable |
| four/sine.sp | 13.596 | 73.111 | — | agree | unavailable | unavailable |
| hb/current_driven_rc.sp | 4.232 | — | — | unavailable | unavailable | unavailable |
| hb/dc_offset.sp | 4.743 | — | — | unavailable | unavailable | unavailable |
| hb/diode_clipper.sp | 20.470 | — | — | unavailable | unavailable | unavailable |
| hb/diode_rectifier_rc.sp | 70.864 | — | — | unavailable | unavailable | unavailable |
| hb/fast_rc.sp | 4.646 | — | — | unavailable | unavailable | unavailable |
| hb/lc_oscillator.sp | 14.120 | — | — | unavailable | unavailable | unavailable |
| hb/negative_dc.sp | 4.151 | — | — | unavailable | unavailable | unavailable |
| hb/one_harmonic.sp | 3.860 | — | — | unavailable | unavailable | unavailable |
| hb/polynomial_2.sp | 5.317 | — | — | unavailable | unavailable | unavailable |
| hb/polynomial_3.sp | 5.216 | — | — | unavailable | unavailable | unavailable |
| hb/rc.sp | 4.452 | — | — | unavailable | unavailable | unavailable |
| hb/rc_amplitude.sp | 4.076 | — | — | unavailable | unavailable | unavailable |
| hb/ring_oscillator.sp | 46.399 | — | — | unavailable | unavailable | unavailable |
| hb/subharms_cubic.sp | 4.356 | — | — | unavailable | unavailable | unavailable |
| hb/subharms_two_tone_square.sp | 4.957 | — | — | unavailable | unavailable | unavailable |
| hb/sweep_two_tone_cubic.sp | 6.417 | — | — | unavailable | unavailable | unavailable |
| hb/three_tone_cubic.sp | 8.280 | — | — | unavailable | unavailable | unavailable |
| hb/two_tone_box_square.sp | 5.194 | — | — | unavailable | unavailable | unavailable |
| hb/two_tone_cubic_im3.sp | 4.796 | — | — | unavailable | unavailable | unavailable |
| hb/two_tone_diode.sp | 19.665 | — | — | unavailable | unavailable | unavailable |
| hb/two_tone_diode_vacask.sp | 14.340 | — | — | unavailable | unavailable | unavailable |
| hbac/ideal_multiplier.sp | 4.686 | — | — | unavailable | unavailable | unavailable |
| hbac/multitone_multiplier.sp | 5.324 | — | — | unavailable | unavailable | unavailable |
| hbac/multitone_rc.sp | 6.370 | — | — | unavailable | unavailable | unavailable |
| hbac/rc.sp | 4.610 | — | — | unavailable | unavailable | unavailable |
| hbac/ss_tone_multiplier.sp | 4.395 | — | — | unavailable | unavailable | unavailable |
| hbac/two_poles_hspice.sp | 6.957 | — | — | unavailable | unavailable | unavailable |
| hbnoise/differential_rc.sp | 4.372 | — | — | unavailable | unavailable | unavailable |
| hbnoise/lti_rc.sp | 4.599 | — | — | unavailable | unavailable | unavailable |
| hbnoise/lti_rc_hspice.sp | 6.525 | — | — | unavailable | unavailable | unavailable |
| hbnoise/multiplier_1.sp | 5.787 | — | — | unavailable | unavailable | unavailable |
| hbnoise/multiplier_2.sp | 5.716 | — | — | unavailable | unavailable | unavailable |
| hbnoise/multitone_multiplier.sp | 5.686 | — | — | unavailable | unavailable | unavailable |
| hbxf/multitone_rc.sp | 5.678 | — | — | unavailable | unavailable | unavailable |
| hbxf/rc.sp | 4.953 | — | — | unavailable | unavailable | unavailable |
| hbxf/two_poles_hspice.sp | 6.091 | — | — | unavailable | unavailable | unavailable |
| hdl/verilog_adder_op.sp | 5.006 | — | — | unavailable | unavailable | unavailable |
| hdl/verilog_d2a_rc.sp | 5.861 | — | — | unavailable | unavailable | unavailable |
| hdl/verilog_inverter.sp | 4.470 | — | — | unavailable | unavailable | unavailable |
| hdl/verilog_tff_hysteresis.sp | 5.997 | — | — | unavailable | unavailable | unavailable |
| hdl/veriloga_diode_clamp.sp | 4.691 | — | — | unavailable | unavailable | unavailable |
| hdl/veriloga_idt_ac.sp | 4.950 | — | — | unavailable | unavailable | unavailable |
| hdl/veriloga_idt_uic.sp | 4.675 | — | — | unavailable | unavailable | unavailable |
| hdl/veriloga_limit.sp | 4.650 | — | — | unavailable | unavailable | unavailable |
| hdl/veriloga_optran_timer.sp | 5.255 | — | — | unavailable | unavailable | unavailable |
| hdl/veriloga_parallel.sp | 5.358 | — | — | unavailable | unavailable | unavailable |
| hdl/veriloga_pre_osdi_va.sp | 4.318 | — | — | unavailable | unavailable | unavailable |
| hdl/veriloga_res_divider.sp | 4.899 | — | — | unavailable | unavailable | unavailable |
| hdl/veriloga_simparam.sp | 4.385 | — | — | unavailable | unavailable | unavailable |
| hdl/veriloga_simparam_homotopy.sp | 4.161 | — | — | unavailable | unavailable | unavailable |
| hdl/veriloga_table_snapshot.sp | 4.488 | — | — | unavailable | unavailable | unavailable |
| hdl/veriloga_timer_rearm.sp | 5.117 | — | — | unavailable | unavailable | unavailable |
| hdl/veriloga_transition_reject.sp | 6.087 | — | — | unavailable | unavailable | unavailable |
| hdl/veriloga_unknown_param.sp | — | — | — | unavailable | unavailable | unavailable |
| hdl/veriloga_wrong_node_count.sp | — | — | — | unavailable | unavailable | unavailable |
| hspice/ac_poi.sp | 4.532 | — | — | unavailable | unavailable | unavailable |
| hspice/behavioural_sources.sp | 4.988 | — | — | unavailable | unavailable | unavailable |
| hspice/behavioural_time_delay.sp | 5.721 | — | — | unavailable | unavailable | unavailable |
| hspice/checks.sp | 5.665 | — | — | unavailable | unavailable | unavailable |
| hspice/connect.sp | 4.398 | — | — | unavailable | unavailable | unavailable |
| hspice/cshunt_delmax.sp | 4.191 | 16.589 | — | agree | unavailable | unavailable |
| hspice/dc_dec_grid.sp | 4.680 | — | — | unavailable | unavailable | unavailable |
| hspice/dc_poi_grid.sp | 4.389 | — | — | unavailable | unavailable | unavailable |
| hspice/dc_start_stop.sp | 4.263 | — | — | unavailable | unavailable | unavailable |
| hspice/dcvolt_uic.sp | 4.005 | — | — | unavailable | unavailable | unavailable |
| hspice/fft_hann.sp | 10.245 | — | — | unavailable | unavailable | unavailable |
| hspice/fft_meas.sp | 19.750 | — | — | unavailable | unavailable | unavailable |
| hspice/fft_rect.sp | 12.709 | — | — | unavailable | unavailable | unavailable |
| hspice/gshunt.sp | 4.188 | 12.740 | — | DIFFER | unavailable | unavailable |
| hspice/hblin_mixer.sp | 9.410 | — | — | unavailable | unavailable | unavailable |
| hspice/hblin_noise.sp | 6.201 | — | — | unavailable | unavailable | unavailable |
| hspice/laplace_source.sp | 4.650 | — | — | unavailable | unavailable | unavailable |
| hspice/lin_line.sp | 5.197 | — | — | unavailable | unavailable | unavailable |
| hspice/lin_mixed_mode.sp | 5.113 | — | — | unavailable | unavailable | unavailable |
| hspice/lin_pad.sp | 4.121 | — | — | unavailable | unavailable | unavailable |
| hspice/lin_rc_noise.sp | 4.656 | — | — | unavailable | unavailable | unavailable |
| hspice/load_ic.sp | 4.682 | — | — | unavailable | unavailable | unavailable |
| hspice/match_diode.sp | 5.972 | — | — | unavailable | unavailable | unavailable |
| hspice/meas_events.sp | 5.760 | — | — | unavailable | unavailable | unavailable |
| hspice/meas_forms.sp | 5.196 | 15.662 | — | agree | unavailable | unavailable |
| hspice/meas_lstb.sp | 5.407 | — | — | unavailable | unavailable | unavailable |
| hspice/meas_match.sp | 4.775 | — | — | unavailable | unavailable | unavailable |
| hspice/meas_ptdnoise.sp | 7.780 | — | — | unavailable | unavailable | unavailable |
| hspice/net_one_port.sp | 4.644 | — | — | unavailable | unavailable | unavailable |
| hspice/net_tpad_y.sp | 4.513 | — | — | unavailable | unavailable | unavailable |
| hspice/net_tpad_z.sp | 4.331 | — | — | unavailable | unavailable | unavailable |
| hspice/noise_ac_sweep.sp | 5.171 | — | — | unavailable | unavailable | unavailable |
| hspice/op_times.sp | 5.161 | 13.577 | — | incomplete | unavailable | unavailable |
| hspice/param_distributions.sp | 4.096 | — | — | unavailable | unavailable | unavailable |
| hspice/pattern_source.sp | 4.852 | — | — | unavailable | unavailable | unavailable |
| hspice/pole_source.sp | 4.812 | — | — | unavailable | unavailable | unavailable |
| hspice/pole_step.sp | 7.582 | — | — | unavailable | unavailable | unavailable |
| hspice/port_series_z0.sp | 5.557 | — | — | unavailable | unavailable | unavailable |
| hspice/power.sp | 7.885 | — | — | unavailable | unavailable | unavailable |
| hspice/ptdnoise_diode.sp | 11.079 | — | — | unavailable | unavailable | unavailable |
| hspice/ptdnoise_time_sweep.sp | 13.490 | — | — | unavailable | unavailable | unavailable |
| hspice/pz_source.sp | 4.205 | — | — | unavailable | unavailable | unavailable |
| hspice/s_element.sp | 5.284 | — | — | unavailable | unavailable | unavailable |
| hspice/s_element_tran.sp | 26.049 | — | — | unavailable | unavailable | unavailable |
| hspice/sample_rc.sp | 5.310 | — | — | unavailable | unavailable | unavailable |
| hspice/sample_rc_beta.sp | 4.755 | — | — | unavailable | unavailable | unavailable |
| hspice/search_lib.sp | 4.361 | — | — | unavailable | unavailable | unavailable |
| hspice/sffm_order.sp | 6.479 | 23.338 | 19.817 | DIFFER | DIFFER | DIFFER |
| hspice/sn_rc.sp | 5.680 | — | — | unavailable | unavailable | unavailable |
| hspice/snac_rc.sp | 6.387 | — | — | unavailable | unavailable | unavailable |
| hspice/snnoise_rc.sp | 6.408 | — | — | unavailable | unavailable | unavailable |
| hspice/snxf_rc.sp | 8.298 | — | — | unavailable | unavailable | unavailable |
| hspice/temp_list.sp | 4.012 | 16.490 | — | unavailable | unavailable | unavailable |
| hspice/tnom_default.sp | 4.041 | 13.782 | 15.269 | DIFFER | DIFFER | agree |
| hspice/tran_segments.sp | 4.622 | 14.625 | — | DIFFER | unavailable | unavailable |
| hspice/unknown_card.sp | — | — | — | unavailable | unavailable | unavailable |
| hspice/value_modifier.sp | 4.485 | — | — | unavailable | unavailable | unavailable |
| hspice/vec_stim.sp | 4.756 | — | — | unavailable | unavailable | unavailable |
| hspice/w_coupled_cpl.sp | 46.657 | — | — | unavailable | unavailable | unavailable |
| hspice/w_element.sp | 61.691 | — | — | unavailable | unavailable | unavailable |
| hspice/w_lossless_delay.sp | 20.877 | — | — | unavailable | unavailable | unavailable |
| hspice/w_settle.sp | 202.580 | — | — | unavailable | unavailable | unavailable |
| hspice/w_txl.sp | 17.223 | — | — | unavailable | unavailable | unavailable |
| invalid/ac_fractional_density.sp | — | 14.842 | 16.722 | unavailable | unavailable | unavailable |
| invalid/ac_negative_frequency.sp | — | 17.519 | — | unavailable | unavailable | unavailable |
| invalid/ac_zero_density.sp | — | 16.161 | — | unavailable | unavailable | unavailable |
| invalid/bench_topology_floating_node.sp | — | 16.762 | — | unavailable | unavailable | unavailable |
| invalid/contradictory_voltage_loop.sp | — | — | — | unavailable | unavailable | unavailable |
| invalid/contradictory_voltage_sources.sp | — | — | — | unavailable | unavailable | unavailable |
| invalid/current_into_capacitor_dc.sp | — | 16.613 | — | unavailable | unavailable | unavailable |
| invalid/current_into_open_node.sp | — | 15.681 | — | unavailable | unavailable | unavailable |
| invalid/dc_missing_source.sp | — | — | — | unavailable | unavailable | unavailable |
| invalid/dc_wrong_step_direction.sp | — | — | 16.586 | unavailable | unavailable | unavailable |
| invalid/dc_zero_step.sp | — | — | — | unavailable | unavailable | unavailable |
| invalid/dcmatch_unknown_node.sp | — | — | — | unavailable | unavailable | unavailable |
| invalid/disto_f2_without_source.sp | — | — | — | unavailable | unavailable | unavailable |
| invalid/disto_zero_count.sp | — | — | — | unavailable | unavailable | unavailable |
| invalid/envelope_zero_period.sp | — | — | — | unavailable | unavailable | unavailable |
| invalid/four_zero_fundamental.sp | — | — | — | unavailable | unavailable | unavailable |
| invalid/hb_fractional_harmonics.sp | — | — | — | unavailable | unavailable | unavailable |
| invalid/hb_negative_frequency.sp | — | — | — | unavailable | unavailable | unavailable |
| invalid/matex_negative_step.sp | — | — | — | unavailable | unavailable | unavailable |
| invalid/mc_fractional_trials.sp | — | — | — | unavailable | unavailable | unavailable |
| invalid/mc_negative_variation.sp | — | — | — | unavailable | unavailable | unavailable |
| invalid/mc_zero_trials.sp | — | — | — | unavailable | unavailable | unavailable |
| invalid/noise_missing_output.sp | — | — | — | unavailable | unavailable | unavailable |
| invalid/noise_missing_source.sp | — | — | — | unavailable | unavailable | unavailable |
| invalid/noise_zero_frequency.sp | — | — | — | unavailable | unavailable | unavailable |
| invalid/optimize_bisection.sp | — | — | — | unavailable | unavailable | unavailable |
| invalid/options_negative_reltol.sp | — | — | 12.469 | unavailable | unavailable | unavailable |
| invalid/pac_zero_lo.sp | — | — | — | unavailable | unavailable | unavailable |
| invalid/pnoise_fractional_sidebands.sp | — | — | — | unavailable | unavailable | unavailable |
| invalid/pnoise_negative_sidebands.sp | — | — | — | unavailable | unavailable | unavailable |
| invalid/pole_unpaired_root.sp | — | — | — | unavailable | unavailable | unavailable |
| invalid/pss_negative_samples.sp | — | — | — | unavailable | unavailable | unavailable |
| invalid/pss_zero_frequency.sp | — | — | — | unavailable | unavailable | unavailable |
| invalid/pxf_zero_lo.sp | — | — | — | unavailable | unavailable | unavailable |
| invalid/qpss_zero_second_frequency.sp | — | — | — | unavailable | unavailable | unavailable |
| invalid/sens_unknown_node.sp | — | 15.971 | — | unavailable | unavailable | unavailable |
| invalid/sp_zero_impedance.sp | — | — | — | unavailable | unavailable | unavailable |
| invalid/temp_absolute_zero.sp | — | 15.122 | 13.799 | unavailable | unavailable | agree |
| invalid/temp_below_absolute_zero.sp | — | — | — | unavailable | unavailable | unavailable |
| invalid/temp_zero_step.sp | — | — | — | unavailable | unavailable | unavailable |
| invalid/tf_missing_output.sp | — | 15.621 | — | unavailable | unavailable | unavailable |
| invalid/tf_missing_source.sp | — | — | — | unavailable | unavailable | unavailable |
| invalid/tran_negative_maxstep.sp | — | — | 12.577 | unavailable | unavailable | unavailable |
| invalid/tran_negative_stop.sp | — | — | — | unavailable | unavailable | unavailable |
| invalid/tran_zero_step.sp | — | — | — | unavailable | unavailable | unavailable |
| invalid/trannoise_zero_step.sp | — | — | — | unavailable | unavailable | unavailable |
| invalid/unresolved_parameter.sp | — | — | — | unavailable | unavailable | unavailable |
| layout/capacitive_divider_tran.sp | 12.378 | 16.854 | — | agree | unavailable | unavailable |
| layout/coupled_ac.sp | 4.566 | 16.194 | 15.640 | agree | agree | agree |
| layout/fanout_tran.sp | 33.782 | 127.800 | 164.009 | agree | agree | agree |
| layout/mesh_op.sp | 4.507 | 13.262 | 17.671 | agree | agree | agree |
| layout/metal_island_tran.sp | 11.044 | 19.638 | — | agree | unavailable | unavailable |
| matex/dc.sp | 5.985 | — | — | unavailable | unavailable | unavailable |
| matex/linear_ramp.sp | 7.575 | — | — | unavailable | unavailable | unavailable |
| matex/purely_algebraic.sp | 4.503 | — | — | unavailable | unavailable | unavailable |
| matex/sine.sp | 7.324 | — | — | unavailable | unavailable | unavailable |
| mc/gaussian_source.sp | 5.704 | — | — | unavailable | unavailable | unavailable |
| mc/zero_variation_1.sp | 3.531 | — | — | unavailable | unavailable | unavailable |
| mc/zero_variation_100.sp | 3.846 | — | — | unavailable | unavailable | unavailable |
| mc/zero_variation_2.sp | 3.681 | — | — | unavailable | unavailable | unavailable |
| mc/zero_variation_31.sp | 4.484 | — | — | unavailable | unavailable | unavailable |
| mc/zero_variation_32.sp | 4.215 | — | — | unavailable | unavailable | unavailable |
| mc/zero_variation_33.sp | 4.596 | — | — | unavailable | unavailable | unavailable |
| mc/zero_variation_7.sp | 4.730 | — | — | unavailable | unavailable | unavailable |
| mc/zero_variation_8.sp | 3.538 | — | — | unavailable | unavailable | unavailable |
| mc/zero_variation_9.sp | 4.708 | — | — | unavailable | unavailable | unavailable |
| mosra/nmos_aged_vth.sp | 6.588 | — | — | unavailable | unavailable | unavailable |
| mosra/nmos_dc_stress.sp | 4.429 | — | — | unavailable | unavailable | unavailable |
| mosra/nmos_dtemp_arrhenius.sp | 4.459 | — | — | unavailable | unavailable | unavailable |
| multi_analysis/bench_hb_tline_guard.sp | 5.687 | — | — | unavailable | unavailable | unavailable |
| multi_analysis/bench_ngspice_lowpass_filter.sp | 4.289 | 14.451 | — | agree | unavailable | unavailable |
| multi_analysis/bench_ngspice_rca3040.sp | 10.559 | 22.377 | — | agree | unavailable | unavailable |
| multi_analysis/bench_ngspice_res_array.sp | 7.115 | 17.726 | — | agree | unavailable | unavailable |
| multi_analysis/bench_ngspice_res_partition.sp | 4.472 | 12.433 | — | agree | unavailable | unavailable |
| multi_analysis/bench_ngspice_rtlinv.sp | 6.216 | 18.377 | — | agree | unavailable | unavailable |
| multi_analysis/bench_pz_filt_bridge_t.sp | 4.918 | 13.683 | — | agree | unavailable | unavailable |
| multi_analysis/bench_sens_diffpair.sp | 8.431 | 16.509 | — | incomplete | unavailable | unavailable |
| multi_analysis/device_jfet_vds_vgs.sp | 4.345 | 13.094 | 16.251 | agree | unavailable | unavailable |
| multi_analysis/device_vbic_ce_amp.sp | 6.802 | 19.326 | — | DIFFER | unavailable | unavailable |
| noise/balanced_temp_0.sp | 4.414 | 12.491 | 16.874 | agree | unavailable | unavailable |
| noise/balanced_temp_125.sp | 4.901 | 13.088 | 13.134 | agree | unavailable | unavailable |
| noise/balanced_temp_27.sp | 4.702 | 15.306 | 11.557 | agree | unavailable | unavailable |
| noise/balanced_temp_minus40.sp | 4.270 | 12.405 | 12.797 | agree | unavailable | unavailable |
| noise/bench_noise_amp_noise.sp | 4.519 | 15.004 | 14.151 | agree | unavailable | unavailable |
| noise/bench_noise_bjt_flicker.sp | 5.837 | 16.623 | 13.335 | agree | unavailable | unavailable |
| noise/clamped_output.sp | 3.799 | 13.265 | 14.123 | agree | unavailable | unavailable |
| noise/contributions.sp | 3.932 | 16.483 | — | incomplete | unavailable | unavailable |
| noise/current_source_input.sp | 4.761 | 16.817 | 16.263 | incomplete | unavailable | unavailable |
| noise/device_vbic_noise_scale.sp | 6.993 | 16.953 | — | agree | unavailable | unavailable |
| noise/differential_balanced.sp | 4.636 | 15.745 | — | agree | unavailable | unavailable |
| noise/differential_unbalanced.sp | 4.791 | 12.616 | — | agree | unavailable | unavailable |
| noise/jfet_channel.sp | 5.170 | 16.785 | — | agree | unavailable | unavailable |
| noise/noise_table_lin_clamp.sp | 5.310 | — | — | unavailable | unavailable | unavailable |
| noise/noise_table_lin_interior.sp | 5.084 | — | — | unavailable | unavailable | unavailable |
| noise/noise_table_log_clamp.sp | 4.913 | — | — | unavailable | unavailable | unavailable |
| noise/noise_table_log_interior.sp | 3.726 | — | — | unavailable | unavailable | unavailable |
| noise/noise_va_coeff.sp | 4.734 | — | — | unavailable | unavailable | unavailable |
| noise/noise_va_correlated.sp | 5.808 | — | — | unavailable | unavailable | unavailable |
| noise/noise_va_ground.sp | 5.117 | — | — | unavailable | unavailable | unavailable |
| noise/rc_1e-06.sp | 4.882 | 17.089 | 14.706 | agree | unavailable | unavailable |
| noise/rc_1e-09.sp | 4.823 | 13.056 | 13.807 | agree | unavailable | unavailable |
| noise/single_frequency.sp | 3.610 | 12.787 | 15.074 | agree | unavailable | unavailable |
| noise/unequal_temp_0.sp | 4.669 | 15.312 | 15.930 | agree | unavailable | unavailable |
| noise/unequal_temp_125.sp | 4.423 | 13.478 | 12.902 | agree | unavailable | unavailable |
| noise/unequal_temp_27.sp | 4.579 | 16.093 | 13.550 | agree | unavailable | unavailable |
| noise/unequal_temp_minus40.sp | 4.586 | 14.420 | 16.628 | agree | unavailable | unavailable |
| op/balanced_bridge.sp | 4.138 | 16.039 | 15.122 | agree | agree | agree |
| op/bench_adversarial_near_singular.sp | 3.817 | 13.302 | 12.729 | agree | agree | agree |
| op/bench_adversarial_tiny_resistor.sp | 4.065 | 13.220 | 16.526 | agree | agree | agree |
| op/bench_analog_current_mirror.sp | 4.408 | 16.214 | 13.302 | agree | agree | agree |
| op/bench_analog_diff_pair.sp | 4.400 | 16.782 | 17.685 | agree | agree | agree |
| op/bench_analog_opamp_inverting.sp | 4.701 | 16.435 | 11.930 | agree | agree | agree |
| op/bench_bjt_cascode.sp | 4.415 | 15.369 | 16.102 | agree | agree | agree |
| op/bench_ensemble_corner_pathological.sp | 4.613 | 12.598 | 17.041 | agree | agree | agree |
| op/bench_medium_resistor_mesh.sp | 4.800 | 15.221 | 14.532 | agree | agree | agree |
| op/bench_mosfet_nand2.sp | 4.949 | 17.007 | 14.305 | agree | agree | agree |
| op/bsource_brace_expr.sp | 4.968 | 12.988 | — | incomplete | unavailable | unavailable |
| op/capacitor_open_dc.sp | 4.313 | 16.553 | 15.480 | agree | agree | agree |
| op/cccs_sign.sp | 3.521 | 16.826 | 14.552 | agree | agree | agree |
| op/ccvs_gain.sp | 4.739 | 13.981 | 17.145 | agree | agree | agree |
| op/controlled_source_scaling.sp | 15.984 | 64.402 | 78.442 | agree | agree | agree |
| op/current_injection.sp | 3.628 | 12.419 | 16.463 | agree | agree | agree |
| op/current_withdrawal.sp | 4.316 | 13.278 | 11.850 | agree | agree | agree |
| op/device_b3soidd.sp | 4.044 | 12.470 | — | agree | unavailable | unavailable |
| op/device_b3soifd.sp | 4.030 | 17.264 | — | agree | unavailable | unavailable |
| op/device_b3soipd.sp | 4.923 | 16.708 | — | agree | unavailable | unavailable |
| op/device_b4soi.sp | 4.643 | 17.018 | — | agree | unavailable | unavailable |
| op/device_bjt_pnp.sp | 4.449 | 16.798 | 17.517 | agree | agree | agree |
| op/device_bsim3.sp | 3.778 | 11.822 | — | agree | unavailable | unavailable |
| op/device_bsim4.sp | 4.812 | 12.550 | 18.150 | agree | agree | agree |
| op/device_hfet1.sp | 4.366 | 16.662 | — | agree | unavailable | unavailable |
| op/device_hfet2.sp | 4.232 | 13.850 | — | agree | unavailable | unavailable |
| op/device_hicum2.sp | 4.047 | 12.790 | — | agree | unavailable | unavailable |
| op/device_jfet.sp | 4.353 | 13.257 | 12.854 | agree | agree | agree |
| op/device_lossy_tline_rg.sp | 4.033 | — | — | unavailable | unavailable | unavailable |
| op/device_mesa.sp | 3.416 | 14.034 | — | agree | unavailable | unavailable |
| op/device_mesfet.sp | 4.448 | 15.237 | — | agree | unavailable | unavailable |
| op/device_vbic.sp | 4.433 | 15.981 | — | agree | unavailable | unavailable |
| op/device_vdmos.sp | 4.296 | 12.580 | — | agree | unavailable | unavailable |
| op/divider_balanced.sp | 3.921 | 15.443 | 12.429 | agree | agree | agree |
| op/divider_default.sp | 4.130 | 16.179 | 11.857 | agree | agree | agree |
| op/floating_voltage_source.sp | 3.665 | 13.538 | 12.650 | agree | agree | agree |
| op/gigaohm_load.sp | 4.174 | 15.250 | 16.283 | agree | agree | agree |
| op/inductor_short_dc.sp | 3.773 | 12.944 | 13.138 | agree | agree | agree |
| op/kilovolt_supply.sp | 3.962 | 16.411 | 12.630 | agree | agree | agree |
| op/milliohm_load.sp | 3.748 | 17.224 | 16.180 | agree | agree | agree |
| op/millivolt_supply.sp | 4.633 | 13.751 | 12.402 | agree | agree | agree |
| op/negative_supply.sp | 4.387 | 16.074 | 16.126 | agree | agree | agree |
| op/nodeset_latch.sp | 4.519 | 14.125 | — | agree | unavailable | unavailable |
| op/parallel_resistors.sp | 4.109 | 11.681 | 15.500 | agree | agree | agree |
| op/ratio_million_to_one.sp | 4.237 | 15.611 | 12.696 | agree | agree | agree |
| op/ratio_one_to_million.sp | 3.932 | 13.869 | 14.093 | agree | agree | agree |
| op/series_sources.sp | 3.570 | 14.691 | 12.815 | agree | agree | agree |
| op/tiny_output.sp | 3.939 | 14.961 | 12.909 | agree | agree | agree |
| op/unequal_nondecimal.sp | 3.878 | 16.987 | 13.897 | agree | agree | agree |
| op/vccs_sign.sp | 4.389 | 16.390 | 13.398 | agree | agree | agree |
| op/vcvs_negative_gain.sp | 3.924 | 15.054 | 13.197 | agree | agree | agree |
| op/zero_supply.sp | 3.874 | 13.972 | 12.708 | agree | agree | agree |
| optimize/bisection_divider.sp | 10.950 | — | — | unavailable | unavailable | unavailable |
| optimize/bisection_rc_max.sp | 26.717 | — | — | unavailable | unavailable | unavailable |
| optimize/divider_goal.sp | 7.648 | — | — | unavailable | unavailable | unavailable |
| optimize/inequality_goals.sp | 8.808 | — | — | unavailable | unavailable | unavailable |
| optimize/passfail_level3.sp | 12.983 | — | — | unavailable | unavailable | unavailable |
| optimize/rc_delay_fit.sp | 20.363 | — | — | unavailable | unavailable | unavailable |
| optimize/step_optimize.sp | 12.550 | — | — | unavailable | unavailable | unavailable |
| optimize/two_param_ladder.sp | 13.432 | — | — | unavailable | unavailable | unavailable |
| optimize/unreachable_goal.sp | 7.027 | — | — | unavailable | unavailable | unavailable |
| pac/divider.sp | 5.542 | — | — | unavailable | unavailable | unavailable |
| pac/ideal_multiplier_1.sp | 4.741 | — | — | unavailable | unavailable | unavailable |
| pac/ideal_multiplier_2.sp | 5.491 | — | — | unavailable | unavailable | unavailable |
| pac/rc.sp | 5.322 | — | — | unavailable | unavailable | unavailable |
| pac/two_poles.sp | 7.308 | — | — | unavailable | unavailable | unavailable |
| phasenoise/acphasenoise_rc.sp | 4.804 | — | — | unavailable | unavailable | unavailable |
| phasenoise/am_noise.sp | 185.412 | — | — | unavailable | unavailable | unavailable |
| phasenoise/lc_oscillator.sp | 24.851 | — | — | unavailable | unavailable | unavailable |
| phasenoise/meas_phasenoise.sp | 22.616 | — | — | unavailable | unavailable | unavailable |
| phasenoise/varactor_flicker.sp | 81.836 | — | — | unavailable | unavailable | unavailable |
| pnoise/clamped_output.sp | 4.493 | — | — | unavailable | unavailable | unavailable |
| pnoise/differential_rc.sp | 6.007 | — | — | unavailable | unavailable | unavailable |
| pnoise/lti_rc_sidebands_0.sp | 4.402 | — | — | unavailable | unavailable | unavailable |
| pnoise/lti_rc_sidebands_1.sp | 5.020 | — | — | unavailable | unavailable | unavailable |
| pnoise/lti_rc_sidebands_3.sp | 5.186 | — | — | unavailable | unavailable | unavailable |
| pnoise/lti_rc_sidebands_7.sp | 6.623 | — | — | unavailable | unavailable | unavailable |
| pnoise/noise_multiplier_1.sp | 5.930 | — | — | unavailable | unavailable | unavailable |
| pnoise/noise_multiplier_2.sp | 5.706 | — | — | unavailable | unavailable | unavailable |
| pss/bench_pss_diode_rect_driven.sp | 7.120 | — | — | unavailable | unavailable | unavailable |
| pss/bench_pss_rlc_driven.sp | 6.170 | — | — | unavailable | unavailable | unavailable |
| pss/dc_is_periodic.sp | 4.671 | — | — | unavailable | unavailable | unavailable |
| pss/diode_clipper.sp | 6.941 | — | — | unavailable | unavailable | unavailable |
| pss/diode_rectifier_rc.sp | 9.151 | — | — | unavailable | unavailable | unavailable |
| pss/polynomial_2.sp | 5.553 | — | — | unavailable | unavailable | unavailable |
| pss/polynomial_3.sp | 5.172 | — | — | unavailable | unavailable | unavailable |
| pss/rc_default.sp | 5.929 | — | — | unavailable | unavailable | unavailable |
| pss/rc_fast.sp | 5.447 | — | — | unavailable | unavailable | unavailable |
| pss/rc_minimal_grid.sp | 4.480 | — | — | unavailable | unavailable | unavailable |
| pss/rc_negative_amplitude.sp | 5.520 | — | — | unavailable | unavailable | unavailable |
| pss/rc_offset.sp | 5.771 | — | — | unavailable | unavailable | unavailable |
| pss/rc_slow_settling.sp | 4.722 | — | — | unavailable | unavailable | unavailable |
| pss/ring_oscillator.sp | 41.246 | — | — | unavailable | unavailable | unavailable |
| pss/ring_oscillator_krylov.sp | 431.059 | — | — | unavailable | unavailable | unavailable |
| pss/ring_oscillator_snosc.sp | 44.316 | — | — | unavailable | unavailable | unavailable |
| pxf/divider.sp | 4.599 | — | — | unavailable | unavailable | unavailable |
| pxf/rc.sp | 4.987 | — | — | unavailable | unavailable | unavailable |
| pxf/two_poles.sp | 7.292 | — | — | unavailable | unavailable | unavailable |
| pz/bench_pz_filt_multistage.sp | 4.347 | 15.986 | — | DIFFER | unavailable | unavailable |
| pz/bench_pz_pz2.sp | 4.290 | 13.369 | — | unavailable | unavailable | unavailable |
| pz/bench_pz_pzt.sp | 4.324 | 12.864 | — | unavailable | unavailable | unavailable |
| pz/bench_pz_simplepz.sp | 3.253 | 16.255 | — | agree | unavailable | unavailable |
| pz/bench_pz_two_pole.sp | 4.717 | 13.021 | — | agree | unavailable | unavailable |
| pz/purely_resistive.sp | 4.289 | — | — | unavailable | unavailable | unavailable |
| pz/rc_highpass_zero.sp | 4.270 | — | — | unavailable | unavailable | unavailable |
| pz/rc_lowpass_ports.sp | 4.564 | — | — | unavailable | unavailable | unavailable |
| pz/rc_tau_0p001.sp | 4.454 | — | — | unavailable | unavailable | unavailable |
| pz/rc_tau_1.sp | 4.568 | — | — | unavailable | unavailable | unavailable |
| pz/rc_tau_1000.sp | 4.015 | — | — | unavailable | unavailable | unavailable |
| pz/rc_tau_1e-06.sp | 4.553 | — | — | unavailable | unavailable | unavailable |
| pz/rc_tau_1e-09.sp | 4.452 | — | — | unavailable | unavailable | unavailable |
| pz/rlc_notch_zeros.sp | 4.356 | — | — | unavailable | unavailable | unavailable |
| pz/rlc_r_1.sp | 4.201 | — | — | unavailable | unavailable | unavailable |
| pz/rlc_r_10.sp | 3.451 | — | — | unavailable | unavailable | unavailable |
| pz/rlc_r_100.sp | 4.426 | — | — | unavailable | unavailable | unavailable |
| pz/rlc_r_1000.sp | 4.423 | — | — | unavailable | unavailable | unavailable |
| pz/rlc_r_63p2456.sp | 3.991 | — | — | unavailable | unavailable | unavailable |
| pz/two_equal_uncoupled.sp | 4.196 | — | — | unavailable | unavailable | unavailable |
| pz/unbuffered_ladder.sp | 4.500 | — | — | unavailable | unavailable | unavailable |
| pz/unstable_negative_conductance.sp | 4.119 | — | — | unavailable | unavailable | unavailable |
| pz/widely_separated_modes.sp | 4.746 | — | — | unavailable | unavailable | unavailable |
| qpss/idt_lowpass_two_tone.sp | 5.111 | — | — | unavailable | unavailable | unavailable |
| qpss/linear_two_tone_1_1.sp | 5.042 | — | — | unavailable | unavailable | unavailable |
| qpss/linear_two_tone_2_2.sp | 5.118 | — | — | unavailable | unavailable | unavailable |
| qpss/linear_two_tone_3_2.sp | 5.140 | — | — | unavailable | unavailable | unavailable |
| qpss/square_mixer.sp | 4.933 | — | — | unavailable | unavailable | unavailable |
| reference/bjt_active.sp | 4.637 | 12.667 | 17.400 | agree | agree | agree |
| reference/bjt_cutoff.sp | 4.277 | 14.099 | 16.955 | agree | agree | agree |
| reference/bjt_diffpair_-0p1.sp | 4.307 | 13.641 | 17.281 | agree | agree | agree |
| reference/bjt_diffpair_0.sp | 4.700 | 12.873 | 12.820 | agree | agree | agree |
| reference/bjt_diffpair_0p1.sp | 4.816 | 12.200 | 16.194 | agree | agree | agree |
| reference/bjt_emitter_degenerated_ac.sp | 4.453 | 12.820 | 17.578 | agree | agree | agree |
| reference/bjt_emitter_degenerated_dc.sp | 4.712 | 16.327 | 17.417 | agree | agree | agree |
| reference/bjt_emitter_degenerated_op.sp | 4.408 | 16.305 | 17.605 | agree | agree | agree |
| reference/bjt_reverse_active.sp | 3.988 | 12.181 | 17.664 | agree | agree | agree |
| reference/bjt_saturation.sp | 4.535 | 16.756 | 15.960 | agree | agree | agree |
| reference/bridge_capacitor_transient.sp | 53.922 | 157.151 | 146.997 | agree | agree | agree |
| reference/bridge_op_-10.sp | 4.708 | 14.753 | 14.645 | agree | agree | agree |
| reference/bridge_op_1.sp | 4.376 | 12.659 | 12.057 | agree | agree | agree |
| reference/bridge_op_10.sp | 4.469 | 12.178 | 11.815 | agree | agree | agree |
| reference/bridge_op_100.sp | 3.528 | 12.484 | 13.354 | agree | agree | agree |
| reference/cmos_inverter_dc.sp | 5.104 | 14.114 | — | agree | unavailable | unavailable |
| reference/cmos_inverter_tran.sp | 15.631 | 38.928 | 43.019 | agree | agree | agree |
| reference/coupled_inductors_ac.sp | 4.209 | 15.482 | 15.910 | agree | agree | agree |
| reference/diode_charge_ac.sp | 4.247 | 12.199 | 17.597 | agree | agree | agree |
| reference/diode_high_injection.sp | 4.465 | 16.020 | 14.855 | agree | DIFFER | DIFFER |
| reference/diode_reverse_breakdown.sp | 5.060 | 17.491 | 17.727 | agree | agree | agree |
| reference/diode_reverse_recovery.sp | 16.381 | 40.811 | 38.238 | agree | DIFFER | DIFFER |
| reference/diode_series_resistance.sp | 4.606 | 15.261 | 12.055 | agree | agree | agree |
| reference/jfet_common_source_ac.sp | 4.468 | 15.821 | 15.561 | agree | agree | agree |
| reference/lossless_transmission_line.sp | 4.499 | 14.847 | — | agree | unavailable | unavailable |
| reference/mos_body_effect.sp | 3.467 | 11.551 | 16.731 | agree | agree | agree |
| reference/mos_common_source_ac.sp | 4.672 | 16.774 | 12.452 | agree | agree | agree |
| reference/mos_cutoff.sp | 4.332 | 13.014 | 13.067 | agree | agree | agree |
| reference/mos_linear.sp | 4.137 | 13.290 | 13.836 | agree | agree | agree |
| reference/mos_nested_output_curves.sp | 4.257 | 16.791 | 17.765 | agree | agree | agree |
| reference/mos_saturation.sp | 4.342 | 15.204 | 12.025 | agree | agree | agree |
| reference/mos_threshold.sp | 3.783 | 16.090 | 17.084 | agree | agree | agree |
| reference/rlc_underdamped_step.sp | 13.136 | 63.711 | 34.660 | agree | agree | agree |
| reference/stiff_two_time_constants.sp | 4.927 | 15.073 | 18.601 | agree | DIFFER | DIFFER |
| reference/voltage_switch_hysteresis.sp | 12.629 | 49.396 | — | agree | unavailable | unavailable |
| regression/bsim4_tnoimod1.sp | 4.205 | 13.163 | 12.370 | agree | agree | agree |
| regression/options_tnom.sp | 4.069 | 14.868 | 13.909 | agree | agree | agree |
| sens/balanced.sp | 4.192 | 15.131 | — | incomplete | unavailable | unavailable |
| sens/bench_sens_bridge.sp | 3.941 | 13.604 | — | incomplete | unavailable | unavailable |
| sens/divider.sp | 4.876 | 16.233 | — | incomplete | unavailable | unavailable |
| sens/high_impedance.sp | 4.617 | 16.423 | — | incomplete | unavailable | unavailable |
| sens/low_impedance.sp | 4.776 | 12.478 | — | incomplete | unavailable | unavailable |
| sens/negative_bias.sp | 4.537 | 12.668 | — | incomplete | unavailable | unavailable |
| sp/bench_sp_lc_lowpass.sp | 5.128 | 17.129 | — | incomplete | unavailable | unavailable |
| sp/bench_sp_rc_twoport.sp | 3.807 | 16.436 | — | incomplete | unavailable | unavailable |
| sp/capacitor.sp | 4.466 | — | — | unavailable | unavailable | unavailable |
| sp/inductor.sp | 5.107 | — | — | unavailable | unavailable | unavailable |
| sp/linear_grid_1.sp | 4.402 | — | — | unavailable | unavailable | unavailable |
| sp/linear_grid_17.sp | 4.473 | — | — | unavailable | unavailable | unavailable |
| sp/linear_grid_3.sp | 4.375 | — | — | unavailable | unavailable | unavailable |
| sp/linear_grid_8.sp | 3.891 | — | — | unavailable | unavailable | unavailable |
| sp/matched_pi_attenuator.sp | 4.310 | 12.808 | — | incomplete | unavailable | unavailable |
| sp/one_port_0p001.sp | 4.041 | — | — | unavailable | unavailable | unavailable |
| sp/one_port_100.sp | 4.280 | — | — | unavailable | unavailable | unavailable |
| sp/one_port_1e+09.sp | 4.330 | — | — | unavailable | unavailable | unavailable |
| sp/one_port_25.sp | 4.170 | — | — | unavailable | unavailable | unavailable |
| sp/one_port_50.sp | 4.314 | — | — | unavailable | unavailable | unavailable |
| sp/one_port_75.sp | 4.140 | — | — | unavailable | unavailable | unavailable |
| sp/parallel_rc.sp | 4.189 | — | — | unavailable | unavailable | unavailable |
| sp/series_0p001_z_50_50.sp | 4.394 | 16.143 | — | incomplete | unavailable | unavailable |
| sp/series_1000_z_50_50.sp | 4.318 | 16.479 | — | incomplete | unavailable | unavailable |
| sp/series_100_z_50_50.sp | 4.095 | 14.668 | — | incomplete | unavailable | unavailable |
| sp/series_25_z_25_100.sp | 4.787 | 16.205 | — | incomplete | unavailable | unavailable |
| sp/series_50_z_50_50.sp | 4.474 | 16.496 | — | incomplete | unavailable | unavailable |
| stb/lstb_diff_comm.sp | 7.288 | — | — | unavailable | unavailable | unavailable |
| stb/lstb_loaded_break.sp | 5.729 | — | — | unavailable | unavailable | unavailable |
| stb/lstb_localgnd.sp | 6.443 | — | — | unavailable | unavailable | unavailable |
| stb/lstb_three_pole.sp | 5.070 | — | — | unavailable | unavailable | unavailable |
| stb/negative_feedback_gain_1.sp | 4.099 | — | — | unavailable | unavailable | unavailable |
| stb/negative_feedback_gain_10.sp | 3.987 | — | — | unavailable | unavailable | unavailable |
| stb/negative_feedback_gain_100.sp | 4.371 | — | — | unavailable | unavailable | unavailable |
| stb/negative_feedback_gain_100000.sp | 4.464 | — | — | unavailable | unavailable | unavailable |
| stb/one_pole_1e-06.sp | 4.786 | — | — | unavailable | unavailable | unavailable |
| stb/one_pole_1e-09.sp | 4.409 | — | — | unavailable | unavailable | unavailable |
| stress/scaling_divider_chain.sp | 5.105 | 18.684 | 17.161 | agree | agree | agree |
| stress/scaling_inverter_chain_256.sp | 488.015 | 570.345 | 6349.248 | agree | DIFFER | DIFFER |
| stress/scaling_inverter_chain_4k.sp | 6654.160 | 15810.543 | 271530.030 | agree | DIFFER | DIFFER |
| stress/scaling_parallel_inverters_100.sp | 61.344 | 97.829 | 302.822 | agree | DIFFER | DIFFER |
| stress/scaling_parallel_inverters_2000.sp | 1500.433 | 1574.699 | 7107.350 | agree | DIFFER | DIFFER |
| stress/scaling_rc_ladder_100k.sp | 5430.823 | 16370.799 | 19906.981 | agree | DIFFER | DIFFER |
| stress/scaling_rc_ladder_1k.sp | 27.980 | 63.589 | 234.376 | agree | DIFFER | DIFFER |
| stress/scaling_resistor_grid.sp | 7.695 | 31.298 | 26.824 | agree | agree | agree |
| stress/scaling_resistor_grid_100x100.sp | 66.643 | 7758.362 | 204.135 | agree | agree | agree |
| stress/scaling_resistor_grid_32x32.sp | 9.242 | 61.633 | 35.280 | agree | agree | agree |
| stress/sweep_opamp_wl_200.sp | 21.834 | 38.343 | 113.722 | agree | agree | agree |
| stress/sweep_opamp_wl_5000.sp | 616.419 | 8191.406 | 4432.586 | agree | agree | agree |
| stress/vacask_graetz.sp | 1846.846 | 4170.383 | — | agree | unavailable | unavailable |
| stress/vacask_mul.sp | 986.532 | 2344.552 | — | agree | unavailable | unavailable |
| stress/vacask_rc.sp | 518.643 | 2224.195 | 2620.751 | agree | agree | agree |
| stress/vacask_ring.sp | 2435.784 | — | — | unavailable | unavailable | unavailable |
| syntax/global_net.sp | 3.726 | 13.206 | — | agree | unavailable | unavailable |
| syntax/hspice_suffix.sp | 3.719 | 10.583 | — | agree | unavailable | unavailable |
| syntax/ngspice_syntax.sp | 2.914 | 10.157 | 10.146 | agree | agree | agree |
| syntax/subckt_params.sp | 4.206 | 11.843 | — | agree | unavailable | unavailable |
| temp/fine.sp | 3.875 | — | — | unavailable | unavailable | unavailable |
| temp/nominal.sp | 3.950 | — | — | unavailable | unavailable | unavailable |
| temp/resistor_tc_-0p001_0.sp | 3.837 | — | — | unavailable | unavailable | unavailable |
| temp/resistor_tc_0_1e-05.sp | 3.773 | — | — | unavailable | unavailable | unavailable |
| temp/resistor_tc_0p001_0.sp | 3.796 | — | — | unavailable | unavailable | unavailable |
| temp/resistor_tc_0p001_1e-05.sp | 3.602 | — | — | unavailable | unavailable | unavailable |
| temp/wide.sp | 3.783 | — | — | unavailable | unavailable | unavailable |
| tf/balanced.sp | 3.744 | 14.762 | — | incomplete | unavailable | unavailable |
| tf/bench_tf_r_ladder.sp | 3.910 | 14.884 | — | incomplete | unavailable | unavailable |
| tf/current_input.sp | 3.672 | 15.594 | — | incomplete | unavailable | unavailable |
| tf/current_output.sp | 3.586 | 11.379 | — | agree | unavailable | unavailable |
| tf/differential_output.sp | 3.677 | 13.525 | — | incomplete | unavailable | unavailable |
| tf/diode_bias_0p4.sp | 4.129 | 15.369 | — | incomplete | unavailable | unavailable |
| tf/diode_bias_0p7.sp | 4.506 | 14.682 | — | incomplete | unavailable | unavailable |
| tf/diode_bias_5.sp | 4.141 | 15.184 | — | incomplete | unavailable | unavailable |
| tf/divider.sp | 3.870 | 15.067 | — | incomplete | unavailable | unavailable |
| tf/high_impedance.sp | 3.598 | 10.322 | — | incomplete | unavailable | unavailable |
| tf/ideal_voltage_output.sp | 3.654 | 14.820 | — | incomplete | unavailable | unavailable |
| tf/low_impedance.sp | 3.746 | 14.011 | — | incomplete | unavailable | unavailable |
| tf/negative_bias.sp | 3.621 | 11.527 | — | incomplete | unavailable | unavailable |
| tf/second_source.sp | 3.838 | 14.034 | — | incomplete | unavailable | unavailable |
| tran/bench_bypass_burst_clock.sp | 6.693 | 23.769 | — | agree | unavailable | unavailable |
| tran/bench_bypass_gated_branch.sp | 10.493 | 28.237 | 30.129 | agree | agree | agree |
| tran/bench_bypass_idle_ladder.sp | 10.506 | 27.626 | 33.590 | agree | agree | agree |
| tran/bench_digital_buffer_rc.sp | 4.992 | 16.251 | 17.310 | agree | agree | agree |
| tran/bench_digital_clamp.sp | 4.930 | 16.369 | 17.789 | agree | DIFFER | DIFFER |
| tran/bench_digital_rc_filter_chain.sp | 4.925 | 17.419 | 17.303 | agree | DIFFER | DIFFER |
| tran/bench_ensemble_opamp_mc.sp | 9.230 | 19.960 | 23.639 | agree | agree | agree |
| tran/bench_ensemble_pvt_corners.sp | 13.704 | 32.320 | 49.105 | agree | DIFFER | DIFFER |
| tran/bench_medium_rc_ladder_50.sp | 8.010 | 21.508 | 18.189 | agree | agree | agree |
| tran/bench_mosfet_nmos_cs.sp | 4.658 | 16.357 | 16.599 | agree | agree | agree |
| tran/bench_ngspice_mosamp.sp | 2644.156 | 3670.708 | — | agree | unavailable | unavailable |
| tran/bench_ngspice_mosmem.sp | 7.123 | 14.542 | — | agree | unavailable | unavailable |
| tran/bench_ngspice_rc.sp | 4.304 | 16.194 | 16.422 | agree | agree | agree |
| tran/bench_ngspice_schmitt.sp | 20.910 | 23.619 | 38.457 | agree | agree | agree |
| tran/bench_power_buck_open.sp | 7.160 | 23.695 | 23.448 | agree | agree | agree |
| tran/bench_power_rectifier.sp | 10.856 | 36.849 | 32.173 | agree | DIFFER | DIFFER |
| tran/bench_tline_cpl3_4_line.sp | 135.709 | 28.887 | — | DIFFER | unavailable | unavailable |
| tran/bench_tline_cpl_ibm2.sp | 19.624 | 17.118 | — | DIFFER | unavailable | unavailable |
| tran/bench_tline_delay_line.sp | 5.087 | 18.287 | — | agree | unavailable | unavailable |
| tran/bench_tline_ideal_tline.sp | 5.320 | 16.762 | — | agree | unavailable | unavailable |
| tran/bench_tline_ltra1_1_line.sp | 18.628 | 30.127 | — | agree | unavailable | unavailable |
| tran/bench_tline_ltra2_2_line.sp | 31.709 | 28.532 | — | agree | unavailable | unavailable |
| tran/bench_tline_terminated.sp | 5.341 | 18.067 | — | agree | unavailable | unavailable |
| tran/bench_tline_txl1_1_line.sp | 20.611 | 15.023 | — | DIFFER | unavailable | unavailable |
| tran/bench_tline_txl2_3_line.sp | 54.610 | 20.028 | — | DIFFER | unavailable | unavailable |
| tran/bench_tran_exp_source.sp | 4.636 | 16.452 | 14.357 | agree | agree | agree |
| tran/bench_tran_fourbitadder.sp | 34.132 | 36.026 | 67.369 | agree | agree | agree |
| tran/bench_tran_rc_pulse.sp | 4.096 | 15.299 | 17.093 | agree | agree | agree |
| tran/bench_tran_sffm_source.sp | 6.314 | 16.620 | 20.517 | agree | DIFFER | DIFFER |
| tran/dc_only.sp | 5.499 | 25.436 | 21.367 | agree | agree | agree |
| tran/device_coupled_tlines.sp | 33.235 | 21.325 | — | DIFFER | unavailable | unavailable |
| tran/device_cswitch.sp | 4.158 | 15.362 | — | agree | unavailable | unavailable |
| tran/device_hfet_inverter.sp | 10.000 | 18.221 | — | agree | unavailable | unavailable |
| tran/device_inductor.sp | 4.787 | 16.415 | 16.638 | agree | agree | agree |
| tran/device_kinduc.sp | 5.112 | 16.175 | 17.527 | agree | agree | agree |
| tran/device_lossy_tline.sp | 15.340 | 20.820 | — | agree | unavailable | unavailable |
| tran/device_mesa_oscillator.sp | 2992.261 | 5903.487 | — | agree | unavailable | unavailable |
| tran/device_mesa_oscillator_fast.sp | 26.618 | 37.209 | — | agree | unavailable | unavailable |
| tran/device_mos1_large_signal.sp | 7.014 | 19.357 | 18.252 | agree | DIFFER | DIFFER |
| tran/device_mos6_inverter.sp | 26.229 | 36.572 | — | agree | unavailable | unavailable |
| tran/device_mos6_simpleinv.sp | 4.756 | 13.742 | — | agree | unavailable | unavailable |
| tran/device_switch.sp | 4.309 | 16.159 | — | agree | unavailable | unavailable |
| tran/device_switch_hysteresis.sp | 4.307 | 16.626 | — | agree | unavailable | unavailable |
| tran/device_tline.sp | 5.268 | 17.608 | — | agree | unavailable | unavailable |
| tran/device_urc.sp | 6.748 | 15.680 | — | agree | unavailable | unavailable |
| tran/device_vsource.sp | 4.435 | 15.776 | 15.788 | agree | agree | agree |
| tran/finite_rise_negative.sp | 9.808 | 39.734 | 31.405 | agree | agree | agree |
| tran/finite_rise_positive.sp | 9.209 | 30.544 | 29.847 | agree | agree | agree |
| tran/ic_large.sp | 5.952 | 26.737 | — | agree | unavailable | unavailable |
| tran/ic_negative.sp | 5.801 | 29.032 | — | agree | unavailable | unavailable |
| tran/ic_no_uic_op.sp | 4.304 | 15.555 | — | agree | unavailable | unavailable |
| tran/ic_small.sp | 6.105 | 29.049 | — | agree | unavailable | unavailable |
| tran/jitter_sffm.sp | 582.285 | — | — | unavailable | unavailable | unavailable |
| tran/lc_energy_gear.sp | 36.590 | 328.904 | — | agree | unavailable | unavailable |
| tran/lc_energy_trap.sp | 51.877 | 303.587 | — | agree | unavailable | unavailable |
| tran/output_start_time.sp | 4.558 | 23.075 | — | agree | unavailable | unavailable |
| tran/pwl_isource_breakpoints.sp | 3.857 | 15.347 | — | agree | unavailable | unavailable |
| tran/pwl_nonzero_start.sp | 5.743 | 23.691 | — | agree | unavailable | unavailable |
| tran/pwl_triangle.sp | 5.578 | 23.561 | — | agree | unavailable | unavailable |
| tran/rc_discharge_euler_0p001.sp | 7.056 | 30.296 | — | agree | unavailable | unavailable |
| tran/rc_discharge_euler_1.sp | 7.152 | 30.132 | — | agree | unavailable | unavailable |
| tran/rc_discharge_euler_1e-06.sp | 7.062 | 30.434 | — | agree | unavailable | unavailable |
| tran/rc_discharge_gear_0p001.sp | 7.498 | 30.244 | — | agree | unavailable | unavailable |
| tran/rc_discharge_gear_1.sp | 7.209 | 27.170 | — | agree | unavailable | unavailable |
| tran/rc_discharge_gear_1e-06.sp | 7.926 | 31.070 | — | agree | unavailable | unavailable |
| tran/rc_discharge_trap_0p001.sp | 7.195 | 28.421 | — | agree | unavailable | unavailable |
| tran/rc_discharge_trap_1.sp | 7.401 | 31.141 | — | agree | unavailable | unavailable |
| tran/rc_discharge_trap_1e-06.sp | 7.208 | 30.342 | — | agree | unavailable | unavailable |
| tran/rc_pulse_history_gear.sp | 8.125 | 34.088 | 27.704 | agree | agree | agree |
| tran/rc_pulse_history_trap.sp | 8.439 | 34.326 | 26.025 | agree | agree | agree |
| tran/rc_sinusoidal_startup.sp | 18.241 | 86.460 | 59.556 | agree | agree | agree |
| tran/sine.sp | 5.255 | 22.237 | 20.982 | agree | agree | agree |
| tran/sine_offset_phase.sp | 5.592 | 22.722 | — | agree | unavailable | unavailable |
| tran/trap_xmu_damping.sp | 4.779 | 16.269 | — | agree | unavailable | unavailable |
| tran_noise/hspice_samples.sp | 301.100 | — | — | unavailable | unavailable | unavailable |
| tran_noise/hspice_sde_flicker.sp | 6.061 | — | — | unavailable | unavailable | unavailable |
| tran_noise/hspice_sde_rc.sp | 5.544 | — | — | unavailable | unavailable | unavailable |
| tran_noise/ideal_clamp_-2.sp | 4.250 | — | — | unavailable | unavailable | unavailable |
| tran_noise/ideal_clamp_0.sp | 4.263 | — | — | unavailable | unavailable | unavailable |
| tran_noise/ideal_clamp_2.sp | 3.633 | — | — | unavailable | unavailable | unavailable |
| tran_noise/jfet_flicker.sp | 143.878 | — | — | unavailable | unavailable | unavailable |
| tran_noise/rc_equilibrium.sp | 66.036 | — | — | unavailable | unavailable | unavailable |
| variants/alter_cumulative.sp | 3.460 | — | — | unavailable | unavailable | unavailable |
| variants/data_lam.sp | 4.307 | — | — | unavailable | unavailable | unavailable |
| variants/data_mer.sp | 4.218 | — | — | unavailable | unavailable | unavailable |
| variants/data_sweep.sp | 4.991 | — | — | unavailable | unavailable | unavailable |
| variants/monte_dev_lot.sp | 11.127 | — | — | unavailable | unavailable | unavailable |
| variants/monte_divider.sp | 5.982 | — | — | unavailable | unavailable | unavailable |
| variants/monte_list.sp | 4.778 | — | — | unavailable | unavailable | unavailable |
| variants/monte_tran_meas.sp | 206.888 | — | — | unavailable | unavailable | unavailable |
| variants/step_param_bsource_bare.sp | 4.046 | — | — | unavailable | unavailable | unavailable |
| variants/step_param_divider.sp | 4.196 | — | — | unavailable | unavailable | unavailable |
| variants/step_temp_source.sp | 4.785 | — | — | unavailable | unavailable | unavailable |
| xf/diode_divider.sp | 5.017 | — | — | unavailable | unavailable | unavailable |
| xf/resistive_bridge.sp | 3.169 | — | — | unavailable | unavailable | unavailable |
| xf/sensed_source.sp | 3.888 | — | — | unavailable | unavailable | unavailable |

- ac/device_tline_delay.sp / VACASK: 't' device (t1) has no VACASK counterpart here
- ac/device_urc_ac.sp / VACASK: 'u' device (u1) has no VACASK counterpart here
- ac/rc_lin_1_100_100.sp / VACASK: .ac with 1 points
- ac/resistance_ac_override.sp / VACASK: SimulatorFailed
- aliases/envlp.sp / ngspice: SimulatorFailed
- aliases/envlp.sp / VACASK: '.envlp' has no VACASK counterpart here
- aliases/montecarlo.sp / ngspice: SimulatorFailed
- aliases/montecarlo.sp / VACASK: '.montecarlo' has no VACASK counterpart here
- aliases/tran_noise.sp / ngspice: SimulatorFailed
- aliases/tran_noise.sp / VACASK: '.tran_noise' has no VACASK counterpart here
- convergence/diode_bad_nodeset_negative.sp / VACASK: '.nodeset' has no VACASK counterpart here
- convergence/diode_bad_nodeset_positive.sp / VACASK: '.nodeset' has no VACASK counterpart here
- convergence/monotonic_cubic_0p001.sp / VACASK: 'b' device (b1) has no VACASK counterpart here
- convergence/monotonic_cubic_1.sp / VACASK: 'b' device (b1) has no VACASK counterpart here
- convergence/monotonic_cubic_1000.sp / VACASK: 'b' device (b1) has no VACASK counterpart here
- convergence/monotonic_cubic_1e-09.sp / VACASK: 'b' device (b1) has no VACASK counterpart here
- dc/device_b3soidd_output.sp / VACASK: .model nsoidd: nmos LEVEL=56 has no VACASK module
- dc/device_b3soifd_output.sp / VACASK: .model nsoifd: nmos LEVEL=55 has no VACASK module
- dc/device_b3soipd_output.sp / VACASK: .model nsoipd: nmos LEVEL=10 has no VACASK module
- dc/device_b4soi_output.sp / VACASK: .model nb4soi: nmos LEVEL=58 has no VACASK module
- dc/device_bjt_npn_temp.sp / VACASK: .dc sweeps 'temp', which is not an independent source
- dc/device_bsim1.sp / VACASK: .model nmod: nmos LEVEL=4 has no VACASK module
- dc/device_bsim2.sp / VACASK: .model nmod: nmos LEVEL=5 has no VACASK module
- dc/device_bsim2_ngspice.sp / VACASK: .model nmos: nmos LEVEL=5 has no VACASK module
- dc/device_bsim3_body_effect.sp / VACASK: SimulatorFailed
- dc/device_bsim3_output.sp / VACASK: SimulatorFailed
- dc/device_bsim3_pmos.sp / VACASK: SimulatorFailed
- dc/device_bsim3_temp.sp / VACASK: .dc sweeps 'temp', which is not an independent source
- dc/device_bsim3_transfer.sp / VACASK: SimulatorFailed
- dc/device_bsim4_output.sp / VACASK: SimulatorFailed
- dc/device_bsim4_pmos.sp / VACASK: SimulatorFailed
- dc/device_bsim4_transfer.sp / VACASK: SimulatorFailed
- dc/device_diode_temp.sp / VACASK: .dc sweeps 'temp', which is not an independent source
- dc/device_hfet1_output.sp / VACASK: 'z' device (z1) has no VACASK counterpart here
- dc/device_hfet2_output.sp / VACASK: 'z' device (z1) has no VACASK counterpart here
- dc/device_hfet_id_vgs.sp / VACASK: 'z' device (z1) has no VACASK counterpart here
- dc/device_hicum2_gummel.sp / VACASK: .model hic2: npn LEVEL=8 has no VACASK module
- dc/device_hicum2_output.sp / VACASK: .model hic2: npn LEVEL=8 has no VACASK module
- dc/device_hisim2.sp / VACASK: .model nhsm: nmos LEVEL=68 has no VACASK module
- dc/device_hisimhv.sp / VACASK: .model nhv: nmos LEVEL=73 has no VACASK module
- dc/device_jfet2.sp / VACASK: .model nj2: njf LEVEL=2 has no VACASK module
- dc/device_mesa_inverter.sp / VACASK: 'b' device (bl1) has no VACASK counterpart here
- dc/device_mesa_output.sp / VACASK: 'z' device (z1) has no VACASK counterpart here
- dc/device_mesfet_output.sp / VACASK: 'z' device (z1) has no VACASK counterpart here
- dc/device_mesfet_subthreshold.sp / VACASK: 'z' device (z1) has no VACASK counterpart here
- dc/device_mesfet_transfer.sp / VACASK: 'z' device (z1) has no VACASK counterpart here
- dc/device_mos1_temp.sp / VACASK: .dc sweeps 'temp', which is not an independent source
- dc/device_mos3.sp / VACASK: MissingRaw
- dc/device_mos3_transfer.sp / VACASK: MissingRaw
- dc/device_mos9.sp / VACASK: MissingRaw
- dc/device_resistor_temp.sp / VACASK: .dc sweeps 'temp', which is not an independent source
- dc/device_vbic_forced_output.sp / VACASK: .model n1: npn LEVEL=4 has no VACASK module
- dc/device_vbic_gummel.sp / VACASK: .model vb1: npn LEVEL=4 has no VACASK module
- dc/device_vbic_output.sp / VACASK: .model vb1: npn LEVEL=4 has no VACASK module
- dc/device_vbic_temp.sp / VACASK: .model n1: npn LEVEL=4 has no VACASK module
- dc/device_vdmos_output.sp / VACASK: m1: 3 nodes before the model name, expected 4
- dc/nodeset_sweep_latch.sp / VACASK: 'b' device (b1) has no VACASK counterpart here
- dc/resistor_sweep.sp / VACASK: .dc sweeps 'r2', which is not an independent source
- dc/single_point.sp / VACASK: .dc vin covers 0 intervals
- dcmatch/divider_0_1000.sp / ngspice: SimulatorFailed
- dcmatch/divider_0_1000.sp / VACASK: '.dcmatch' has no VACASK counterpart here
- dcmatch/divider_10_1000.sp / ngspice: SimulatorFailed
- dcmatch/divider_10_1000.sp / VACASK: '.dcmatch' has no VACASK counterpart here
- dcmatch/divider_1_0p001.sp / ngspice: SimulatorFailed
- dcmatch/divider_1_0p001.sp / VACASK: '.dcmatch' has no VACASK counterpart here
- dcmatch/high_resistance.sp / ngspice: SimulatorFailed
- dcmatch/high_resistance.sp / VACASK: '.dcmatch' has no VACASK counterpart here
- dcmatch/unit_source.sp / ngspice: SimulatorFailed
- dcmatch/unit_source.sp / VACASK: '.dcmatch' has no VACASK counterpart here
- dcmatch/zero_source.sp / ngspice: SimulatorFailed
- dcmatch/zero_source.sp / VACASK: '.dcmatch' has no VACASK counterpart here
- disto/bench_disto_bjt_ce.sp / VACASK: '.disto' has no VACASK counterpart here
- disto/bench_disto_diode_clipper.sp / VACASK: '.disto' has no VACASK counterpart here
- disto/bench_disto_mos_cs.sp / VACASK: '.disto' has no VACASK counterpart here
- disto/bjt_caps.sp / VACASK: '.disto' has no VACASK counterpart here
- disto/diode_0p001.sp / VACASK: '.disto' has no VACASK counterpart here
- disto/diode_0p002.sp / VACASK: '.disto' has no VACASK counterpart here
- disto/diode_0p01.sp / VACASK: '.disto' has no VACASK counterpart here
- disto/diode_cap.sp / VACASK: '.disto' has no VACASK counterpart here
- disto/linear_divider_0p001.sp / VACASK: '.disto' has no VACASK counterpart here
- disto/linear_divider_0p01.sp / VACASK: '.disto' has no VACASK counterpart here
- disto/linear_divider_0p1.sp / VACASK: '.disto' has no VACASK counterpart here
- disto/two_tone_bjt_caps.sp / VACASK: '.disto' has no VACASK counterpart here
- disto/two_tone_bjt_ce.sp / VACASK: '.disto' has no VACASK counterpart here
- disto/two_tone_diode.sp / VACASK: '.disto' has no VACASK counterpart here
- disto/two_tone_diode_cap.sp / VACASK: '.disto' has no VACASK counterpart here
- disto/two_tone_diode_rc.sp / VACASK: '.disto' has no VACASK counterpart here
- envelope/dc_offset.sp / ngspice: SimulatorFailed
- envelope/dc_offset.sp / VACASK: '.envelope' has no VACASK counterpart here
- envelope/dc_only.sp / ngspice: SimulatorFailed
- envelope/dc_only.sp / VACASK: '.envelope' has no VACASK counterpart here
- envelope/negative_offset.sp / ngspice: SimulatorFailed
- envelope/negative_offset.sp / VACASK: '.envelope' has no VACASK counterpart here
- envelope/rc_startup_0p001.sp / ngspice: SimulatorFailed
- envelope/rc_startup_0p001.sp / VACASK: '.envelope' has no VACASK counterpart here
- envelope/rc_startup_1e-05.sp / ngspice: SimulatorFailed
- envelope/rc_startup_1e-05.sp / VACASK: '.envelope' has no VACASK counterpart here
- envelope/sine.sp / ngspice: SimulatorFailed
- envelope/sine.sp / VACASK: '.envelope' has no VACASK counterpart here
- envelope/zero.sp / ngspice: SimulatorFailed
- envelope/zero.sp / VACASK: '.envelope' has no VACASK counterpart here
- four/dc_only.sp / VACASK: '.four' has no VACASK counterpart here
- four/harmonic_count_1.sp / VACASK: '.four' has no VACASK counterpart here
- four/harmonic_count_16.sp / VACASK: '.four' has no VACASK counterpart here
- four/harmonic_count_3.sp / VACASK: '.four' has no VACASK counterpart here
- four/multi_output.sp / VACASK: '.four' has no VACASK counterpart here
- four/offset.sp / VACASK: '.four' has no VACASK counterpart here
- four/phase_0.sp / VACASK: vin: SIN phase (0 deg) is accepted but ignored by VACASK
- four/phase_180.sp / VACASK: vin: SIN phase (180 deg) is accepted but ignored by VACASK
- four/phase_30.sp / VACASK: vin: SIN phase (30 deg) is accepted but ignored by VACASK
- four/phase_90.sp / VACASK: vin: SIN phase (90 deg) is accepted but ignored by VACASK
- four/polynomial_2.sp / VACASK: 'b' device (bout) has no VACASK counterpart here
- four/polynomial_3.sp / VACASK: 'b' device (bout) has no VACASK counterpart here
- four/sine.sp / VACASK: '.four' has no VACASK counterpart here
- hb/current_driven_rc.sp / ngspice: SimulatorFailed
- hb/current_driven_rc.sp / VACASK: '.hb' has no VACASK counterpart here
- hb/dc_offset.sp / ngspice: SimulatorFailed
- hb/dc_offset.sp / VACASK: '.hb' has no VACASK counterpart here
- hb/diode_clipper.sp / ngspice: SimulatorFailed
- hb/diode_clipper.sp / VACASK: '.hb' has no VACASK counterpart here
- hb/diode_rectifier_rc.sp / ngspice: SimulatorFailed
- hb/diode_rectifier_rc.sp / VACASK: '.hb' has no VACASK counterpart here
- hb/fast_rc.sp / ngspice: SimulatorFailed
- hb/fast_rc.sp / VACASK: '.hb' has no VACASK counterpart here
- hb/lc_oscillator.sp / ngspice: SimulatorFailed
- hb/lc_oscillator.sp / VACASK: 'b' device (bneg) has no VACASK counterpart here
- hb/negative_dc.sp / ngspice: SimulatorFailed
- hb/negative_dc.sp / VACASK: '.hb' has no VACASK counterpart here
- hb/one_harmonic.sp / ngspice: SimulatorFailed
- hb/one_harmonic.sp / VACASK: '.hb' has no VACASK counterpart here
- hb/polynomial_2.sp / ngspice: SimulatorFailed
- hb/polynomial_2.sp / VACASK: 'b' device (bout) has no VACASK counterpart here
- hb/polynomial_3.sp / ngspice: SimulatorFailed
- hb/polynomial_3.sp / VACASK: 'b' device (bout) has no VACASK counterpart here
- hb/rc.sp / ngspice: SimulatorFailed
- hb/rc.sp / VACASK: '.hb' has no VACASK counterpart here
- hb/rc_amplitude.sp / ngspice: SimulatorFailed
- hb/rc_amplitude.sp / VACASK: '.hb' has no VACASK counterpart here
- hb/ring_oscillator.sp / ngspice: SimulatorFailed
- hb/ring_oscillator.sp / VACASK: 'b' device (b1) has no VACASK counterpart here
- hb/subharms_cubic.sp / ngspice: SimulatorFailed
- hb/subharms_cubic.sp / VACASK: 'b' device (bout) has no VACASK counterpart here
- hb/subharms_two_tone_square.sp / ngspice: SimulatorFailed
- hb/subharms_two_tone_square.sp / VACASK: 'b' device (bout) has no VACASK counterpart here
- hb/sweep_two_tone_cubic.sp / ngspice: SimulatorFailed
- hb/sweep_two_tone_cubic.sp / VACASK: 'b' device (bout) has no VACASK counterpart here
- hb/three_tone_cubic.sp / ngspice: SimulatorFailed
- hb/three_tone_cubic.sp / VACASK: 'b' device (bout) has no VACASK counterpart here
- hb/two_tone_box_square.sp / ngspice: SimulatorFailed
- hb/two_tone_box_square.sp / VACASK: 'b' device (bout) has no VACASK counterpart here
- hb/two_tone_cubic_im3.sp / ngspice: SimulatorFailed
- hb/two_tone_cubic_im3.sp / VACASK: 'b' device (bout) has no VACASK counterpart here
- hb/two_tone_diode.sp / ngspice: SimulatorFailed
- hb/two_tone_diode.sp / VACASK: '.hb' has no VACASK counterpart here
- hb/two_tone_diode_vacask.sp / ngspice: SimulatorFailed
- hb/two_tone_diode_vacask.sp / VACASK: '.hb' has no VACASK counterpart here
- hbac/ideal_multiplier.sp / ngspice: SimulatorFailed
- hbac/ideal_multiplier.sp / VACASK: vlo: SIN phase (90 deg) is accepted but ignored by VACASK
- hbac/multitone_multiplier.sp / ngspice: SimulatorFailed
- hbac/multitone_multiplier.sp / VACASK: vlo1: SIN phase (90 deg) is accepted but ignored by VACASK
- hbac/multitone_rc.sp / ngspice: SimulatorFailed
- hbac/multitone_rc.sp / VACASK: '.hb' has no VACASK counterpart here
- hbac/rc.sp / ngspice: SimulatorFailed
- hbac/rc.sp / VACASK: '.hbac' has no VACASK counterpart here
- hbac/ss_tone_multiplier.sp / ngspice: SimulatorFailed
- hbac/ss_tone_multiplier.sp / VACASK: vlo: SIN phase (90 deg) is accepted but ignored by VACASK
- hbac/two_poles_hspice.sp / ngspice: SimulatorFailed
- hbac/two_poles_hspice.sp / VACASK: '.hb' has no VACASK counterpart here
- hbnoise/differential_rc.sp / ngspice: SimulatorFailed
- hbnoise/differential_rc.sp / VACASK: '.hbnoise' has no VACASK counterpart here
- hbnoise/lti_rc.sp / ngspice: SimulatorFailed
- hbnoise/lti_rc.sp / VACASK: '.hbnoise' has no VACASK counterpart here
- hbnoise/lti_rc_hspice.sp / ngspice: SimulatorFailed
- hbnoise/lti_rc_hspice.sp / VACASK: '.hb' has no VACASK counterpart here
- hbnoise/multiplier_1.sp / ngspice: SimulatorFailed
- hbnoise/multiplier_1.sp / VACASK: vlo: SIN phase (90 deg) is accepted but ignored by VACASK
- hbnoise/multiplier_2.sp / ngspice: SimulatorFailed
- hbnoise/multiplier_2.sp / VACASK: vlo: SIN phase (90 deg) is accepted but ignored by VACASK
- hbnoise/multitone_multiplier.sp / ngspice: SimulatorFailed
- hbnoise/multitone_multiplier.sp / VACASK: vlo1: SIN phase (90 deg) is accepted but ignored by VACASK
- hbxf/multitone_rc.sp / ngspice: SimulatorFailed
- hbxf/multitone_rc.sp / VACASK: '.hb' has no VACASK counterpart here
- hbxf/rc.sp / ngspice: SimulatorFailed
- hbxf/rc.sp / VACASK: '.hbxf' has no VACASK counterpart here
- hbxf/two_poles_hspice.sp / ngspice: SimulatorFailed
- hbxf/two_poles_hspice.sp / VACASK: '.hb' has no VACASK counterpart here
- hdl/verilog_adder_op.sp / ngspice: SimulatorFailed
- hdl/verilog_adder_op.sp / VACASK: '.hdl' has no VACASK counterpart here
- hdl/verilog_d2a_rc.sp / ngspice: SimulatorFailed
- hdl/verilog_d2a_rc.sp / VACASK: '.hdl' has no VACASK counterpart here
- hdl/verilog_inverter.sp / ngspice: SimulatorFailed
- hdl/verilog_inverter.sp / VACASK: '.hdl' has no VACASK counterpart here
- hdl/verilog_tff_hysteresis.sp / ngspice: SimulatorFailed
- hdl/verilog_tff_hysteresis.sp / VACASK: '.hdl' has no VACASK counterpart here
- hdl/veriloga_diode_clamp.sp / ngspice: SimulatorFailed
- hdl/veriloga_diode_clamp.sp / VACASK: '.hdl' has no VACASK counterpart here
- hdl/veriloga_idt_ac.sp / ngspice: SimulatorFailed
- hdl/veriloga_idt_ac.sp / VACASK: '.hdl' has no VACASK counterpart here
- hdl/veriloga_idt_uic.sp / ngspice: SimulatorFailed
- hdl/veriloga_idt_uic.sp / VACASK: '.hdl' has no VACASK counterpart here
- hdl/veriloga_limit.sp / ngspice: SimulatorFailed
- hdl/veriloga_limit.sp / VACASK: '.hdl' has no VACASK counterpart here
- hdl/veriloga_optran_timer.sp / ngspice: SimulatorFailed
- hdl/veriloga_optran_timer.sp / VACASK: '.hdl' has no VACASK counterpart here
- hdl/veriloga_parallel.sp / ngspice: SimulatorFailed
- hdl/veriloga_parallel.sp / VACASK: '.hdl' has no VACASK counterpart here
- hdl/veriloga_pre_osdi_va.sp / ngspice: SimulatorFailed
- hdl/veriloga_pre_osdi_va.sp / VACASK: '.control' has no VACASK counterpart here
- hdl/veriloga_res_divider.sp / ngspice: SimulatorFailed
- hdl/veriloga_res_divider.sp / VACASK: '.hdl' has no VACASK counterpart here
- hdl/veriloga_simparam.sp / ngspice: SimulatorFailed
- hdl/veriloga_simparam.sp / VACASK: '.hdl' has no VACASK counterpart here
- hdl/veriloga_simparam_homotopy.sp / ngspice: SimulatorFailed
- hdl/veriloga_simparam_homotopy.sp / VACASK: '.hdl' has no VACASK counterpart here
- hdl/veriloga_table_snapshot.sp / ngspice: SimulatorFailed
- hdl/veriloga_table_snapshot.sp / VACASK: '.hdl' has no VACASK counterpart here
- hdl/veriloga_timer_rearm.sp / ngspice: SimulatorFailed
- hdl/veriloga_timer_rearm.sp / VACASK: '.hdl' has no VACASK counterpart here
- hdl/veriloga_transition_reject.sp / ngspice: SimulatorFailed
- hdl/veriloga_transition_reject.sp / VACASK: '.hdl' has no VACASK counterpart here
- hdl/veriloga_unknown_param.sp / espice: SimulatorFailed
- hdl/veriloga_unknown_param.sp / ngspice: SimulatorFailed
- hdl/veriloga_unknown_param.sp / VACASK: '.hdl' has no VACASK counterpart here
- hdl/veriloga_wrong_node_count.sp / espice: SimulatorFailed
- hdl/veriloga_wrong_node_count.sp / ngspice: SimulatorFailed
- hdl/veriloga_wrong_node_count.sp / VACASK: '.hdl' has no VACASK counterpart here
- hspice/ac_poi.sp / ngspice: SimulatorFailed
- hspice/ac_poi.sp / VACASK: .ac with 5 fields, expected 4
- hspice/behavioural_sources.sp / ngspice: SimulatorFailed
- hspice/behavioural_sources.sp / VACASK: '+1}': expressions are not translated
- hspice/behavioural_time_delay.sp / ngspice: SimulatorFailed
- hspice/behavioural_time_delay.sp / VACASK: va: PWL is not translated (VACASK's `type="pwl"` aborts on this build)
- hspice/checks.sp / ngspice: SimulatorFailed
- hspice/checks.sp / VACASK: va: PWL is not translated (VACASK's `type="pwl"` aborts on this build)
- hspice/connect.sp / ngspice: SimulatorFailed
- hspice/connect.sp / VACASK: '.connect' has no VACASK counterpart here
- hspice/cshunt_delmax.sp / VACASK: .options cshunt= changes the answer and has no known VACASK spelling
- hspice/dc_dec_grid.sp / ngspice: SimulatorFailed
- hspice/dc_dec_grid.sp / VACASK: .dc with 5 fields, expected 4 or 8
- hspice/dc_poi_grid.sp / ngspice: SimulatorFailed
- hspice/dc_poi_grid.sp / VACASK: .dc with 11 fields, expected 4 or 8
- hspice/dc_start_stop.sp / ngspice: SimulatorFailed
- hspice/dc_start_stop.sp / VACASK: .dc: 'start=0' is not a number
- hspice/dcvolt_uic.sp / ngspice: SimulatorFailed
- hspice/dcvolt_uic.sp / VACASK: '.dcvolt' has no VACASK counterpart here
- hspice/fft_hann.sp / ngspice: SimulatorFailed
- hspice/fft_hann.sp / VACASK: '.fft' has no VACASK counterpart here
- hspice/fft_meas.sp / ngspice: SimulatorFailed
- hspice/fft_meas.sp / VACASK: '.fft' has no VACASK counterpart here
- hspice/fft_rect.sp / ngspice: SimulatorFailed
- hspice/fft_rect.sp / VACASK: '.fft' has no VACASK counterpart here
- hspice/gshunt.sp / VACASK: .options gshunt= changes the answer and has no known VACASK spelling
- hspice/hblin_mixer.sp / ngspice: SimulatorFailed
- hspice/hblin_mixer.sp / VACASK: 'p' device (p1) has no VACASK counterpart here
- hspice/hblin_noise.sp / ngspice: SimulatorFailed
- hspice/hblin_noise.sp / VACASK: 'p' device (p1) has no VACASK counterpart here
- hspice/laplace_source.sp / ngspice: SimulatorFailed
- hspice/laplace_source.sp / VACASK: e1: 10 fields, expected 6 (POLY/VALUE/TABLE forms are not translated)
- hspice/lin_line.sp / ngspice: SimulatorFailed
- hspice/lin_line.sp / VACASK: 'p' device (p1) has no VACASK counterpart here
- hspice/lin_mixed_mode.sp / ngspice: SimulatorFailed
- hspice/lin_mixed_mode.sp / VACASK: 'p' device (p1) has no VACASK counterpart here
- hspice/lin_pad.sp / ngspice: SimulatorFailed
- hspice/lin_pad.sp / VACASK: 'p' device (p1) has no VACASK counterpart here
- hspice/lin_rc_noise.sp / ngspice: SimulatorFailed
- hspice/lin_rc_noise.sp / VACASK: 'p' device (p1) has no VACASK counterpart here
- hspice/load_ic.sp / ngspice: SimulatorFailed
- hspice/load_ic.sp / VACASK: '.load' has no VACASK counterpart here
- hspice/match_diode.sp / ngspice: SimulatorFailed
- hspice/match_diode.sp / VACASK: '.variation' has no VACASK counterpart here
- hspice/meas_events.sp / ngspice: SimulatorFailed
- hspice/meas_events.sp / VACASK: .options delmax= changes the answer and has no known VACASK spelling
- hspice/meas_forms.sp / VACASK: '.measure' has no VACASK counterpart here
- hspice/meas_lstb.sp / ngspice: SimulatorFailed
- hspice/meas_lstb.sp / VACASK: '.lstb' has no VACASK counterpart here
- hspice/meas_match.sp / ngspice: SimulatorFailed
- hspice/meas_match.sp / VACASK: '.variation' has no VACASK counterpart here
- hspice/meas_ptdnoise.sp / ngspice: SimulatorFailed
- hspice/meas_ptdnoise.sp / VACASK: '.sn' has no VACASK counterpart here
- hspice/net_one_port.sp / ngspice: SimulatorFailed
- hspice/net_one_port.sp / VACASK: '.net' has no VACASK counterpart here
- hspice/net_tpad_y.sp / ngspice: SimulatorFailed
- hspice/net_tpad_y.sp / VACASK: .ac with 1 points
- hspice/net_tpad_z.sp / ngspice: SimulatorFailed
- hspice/net_tpad_z.sp / VACASK: .ac with 1 points
- hspice/noise_ac_sweep.sp / ngspice: SimulatorFailed
- hspice/noise_ac_sweep.sp / VACASK: .noise with 4 fields
- hspice/op_times.sp / VACASK: v1: a pulse source cannot also hold the DC value a static analysis needs
- hspice/param_distributions.sp / ngspice: SimulatorFailed
- hspice/param_distributions.sp / VACASK: .param: stray field '1k'
- hspice/pattern_source.sp / ngspice: SimulatorFailed
- hspice/pattern_source.sp / VACASK: '.pat' has no VACASK counterpart here
- hspice/pole_source.sp / ngspice: SimulatorFailed
- hspice/pole_source.sp / VACASK: e1: 15 fields, expected 6 (POLY/VALUE/TABLE forms are not translated)
- hspice/pole_step.sp / ngspice: SimulatorFailed
- hspice/pole_step.sp / VACASK: v1: PWL is not translated (VACASK's `type="pwl"` aborts on this build)
- hspice/port_series_z0.sp / ngspice: SimulatorFailed
- hspice/port_series_z0.sp / VACASK: 'p' device (p1) has no VACASK counterpart here
- hspice/power.sp / ngspice: SimulatorFailed
- hspice/power.sp / VACASK: .options delmax= changes the answer and has no known VACASK spelling
- hspice/ptdnoise_diode.sp / ngspice: SimulatorFailed
- hspice/ptdnoise_diode.sp / VACASK: '.sn' has no VACASK counterpart here
- hspice/ptdnoise_time_sweep.sp / ngspice: SimulatorFailed
- hspice/ptdnoise_time_sweep.sp / VACASK: '.sn' has no VACASK counterpart here
- hspice/pz_source.sp / ngspice: SimulatorFailed
- hspice/pz_source.sp / VACASK: '.pz' has no VACASK counterpart here
- hspice/s_element.sp / ngspice: SimulatorFailed
- hspice/s_element.sp / VACASK: 's' device (s1) has no VACASK counterpart here
- hspice/s_element_tran.sp / ngspice: SimulatorFailed
- hspice/s_element_tran.sp / VACASK: 's' device (s1) has no VACASK counterpart here
- hspice/sample_rc.sp / ngspice: SimulatorFailed
- hspice/sample_rc.sp / VACASK: .noise with 3 fields
- hspice/sample_rc_beta.sp / ngspice: SimulatorFailed
- hspice/sample_rc_beta.sp / VACASK: .noise with 3 fields
- hspice/search_lib.sp / ngspice: SimulatorFailed
- hspice/search_lib.sp / VACASK: .options search= changes the answer and has no known VACASK spelling
- hspice/sn_rc.sp / ngspice: SimulatorFailed
- hspice/sn_rc.sp / VACASK: '.sn' has no VACASK counterpart here
- hspice/snac_rc.sp / ngspice: SimulatorFailed
- hspice/snac_rc.sp / VACASK: '.sn' has no VACASK counterpart here
- hspice/snnoise_rc.sp / ngspice: SimulatorFailed
- hspice/snnoise_rc.sp / VACASK: '.sn' has no VACASK counterpart here
- hspice/snxf_rc.sp / ngspice: SimulatorFailed
- hspice/snxf_rc.sp / VACASK: '.sn' has no VACASK counterpart here
- hspice/temp_list.sp / VACASK: .temp with 3 values (a temperature sweep is not one analysis)
- hspice/tran_segments.sp / VACASK: .tran TSTART=1n has no VACASK counterpart
- hspice/unknown_card.sp / espice: SimulatorFailed
- hspice/unknown_card.sp / ngspice: SimulatorFailed
- hspice/unknown_card.sp / VACASK: '.stateye' has no VACASK counterpart here
- hspice/value_modifier.sp / ngspice: SimulatorFailed
- hspice/value_modifier.sp / VACASK: e1: 7 fields, expected 6 (POLY/VALUE/TABLE forms are not translated)
- hspice/vec_stim.sp / ngspice: SimulatorFailed
- hspice/vec_stim.sp / VACASK: '.vec' has no VACASK counterpart here
- hspice/w_coupled_cpl.sp / ngspice: SimulatorFailed
- hspice/w_coupled_cpl.sp / VACASK: 'w' device (w1) has no VACASK counterpart here
- hspice/w_element.sp / ngspice: SimulatorFailed
- hspice/w_element.sp / VACASK: 'w' device (w1) has no VACASK counterpart here
- hspice/w_lossless_delay.sp / ngspice: SimulatorFailed
- hspice/w_lossless_delay.sp / VACASK: v1: PWL is not translated (VACASK's `type="pwl"` aborts on this build)
- hspice/w_settle.sp / ngspice: SimulatorFailed
- hspice/w_settle.sp / VACASK: 'w' device (w1) has no VACASK counterpart here
- hspice/w_txl.sp / ngspice: SimulatorFailed
- hspice/w_txl.sp / VACASK: 'w' device (w1) has no VACASK counterpart here
- invalid/ac_fractional_density.sp / espice: SimulatorFailed
- invalid/ac_negative_frequency.sp / espice: SimulatorFailed
- invalid/ac_negative_frequency.sp / VACASK: MissingRaw
- invalid/ac_zero_density.sp / espice: SimulatorFailed
- invalid/ac_zero_density.sp / VACASK: .ac with 0 points
- invalid/bench_topology_floating_node.sp / espice: SimulatorFailed
- invalid/bench_topology_floating_node.sp / VACASK: MissingRaw
- invalid/contradictory_voltage_loop.sp / espice: SimulatorFailed
- invalid/contradictory_voltage_loop.sp / ngspice: SimulatorFailed
- invalid/contradictory_voltage_loop.sp / VACASK: MissingRaw
- invalid/contradictory_voltage_sources.sp / espice: SimulatorFailed
- invalid/contradictory_voltage_sources.sp / ngspice: SimulatorFailed
- invalid/contradictory_voltage_sources.sp / VACASK: MissingRaw
- invalid/current_into_capacitor_dc.sp / espice: SimulatorFailed
- invalid/current_into_capacitor_dc.sp / VACASK: MissingRaw
- invalid/current_into_open_node.sp / espice: SimulatorFailed
- invalid/current_into_open_node.sp / VACASK: MissingRaw
- invalid/dc_missing_source.sp / espice: SimulatorFailed
- invalid/dc_missing_source.sp / ngspice: SimulatorFailed
- invalid/dc_missing_source.sp / VACASK: .dc sweeps 'missing', which is not an independent source
- invalid/dc_wrong_step_direction.sp / espice: SimulatorFailed
- invalid/dc_wrong_step_direction.sp / ngspice: MissingOrInvalidRaw
- invalid/dc_zero_step.sp / espice: SimulatorFailed
- invalid/dc_zero_step.sp / ngspice: SimulatorFailed
- invalid/dc_zero_step.sp / VACASK: .dc with a zero step
- invalid/dcmatch_unknown_node.sp / espice: SimulatorFailed
- invalid/dcmatch_unknown_node.sp / ngspice: SimulatorFailed
- invalid/dcmatch_unknown_node.sp / VACASK: '.dcmatch' has no VACASK counterpart here
- invalid/disto_f2_without_source.sp / espice: SimulatorFailed
- invalid/disto_f2_without_source.sp / ngspice: SimulatorFailed
- invalid/disto_f2_without_source.sp / VACASK: '.disto' has no VACASK counterpart here
- invalid/disto_zero_count.sp / espice: SimulatorFailed
- invalid/disto_zero_count.sp / ngspice: SimulatorFailed
- invalid/disto_zero_count.sp / VACASK: '.disto' has no VACASK counterpart here
- invalid/envelope_zero_period.sp / espice: SimulatorFailed
- invalid/envelope_zero_period.sp / ngspice: SimulatorFailed
- invalid/envelope_zero_period.sp / VACASK: '.envelope' has no VACASK counterpart here
- invalid/four_zero_fundamental.sp / espice: SimulatorFailed
- invalid/four_zero_fundamental.sp / ngspice: FileNotFound
- invalid/four_zero_fundamental.sp / VACASK: '.four' has no VACASK counterpart here
- invalid/hb_fractional_harmonics.sp / espice: SimulatorFailed
- invalid/hb_fractional_harmonics.sp / ngspice: SimulatorFailed
- invalid/hb_fractional_harmonics.sp / VACASK: '.hb' has no VACASK counterpart here
- invalid/hb_negative_frequency.sp / espice: SimulatorFailed
- invalid/hb_negative_frequency.sp / ngspice: SimulatorFailed
- invalid/hb_negative_frequency.sp / VACASK: '.hb' has no VACASK counterpart here
- invalid/matex_negative_step.sp / espice: SimulatorFailed
- invalid/matex_negative_step.sp / ngspice: SimulatorFailed
- invalid/matex_negative_step.sp / VACASK: '.matex' has no VACASK counterpart here
- invalid/mc_fractional_trials.sp / espice: SimulatorFailed
- invalid/mc_fractional_trials.sp / ngspice: SimulatorFailed
- invalid/mc_fractional_trials.sp / VACASK: '.mc' has no VACASK counterpart here
- invalid/mc_negative_variation.sp / espice: SimulatorFailed
- invalid/mc_negative_variation.sp / ngspice: SimulatorFailed
- invalid/mc_negative_variation.sp / VACASK: '.mc' has no VACASK counterpart here
- invalid/mc_zero_trials.sp / espice: SimulatorFailed
- invalid/mc_zero_trials.sp / ngspice: SimulatorFailed
- invalid/mc_zero_trials.sp / VACASK: '.mc' has no VACASK counterpart here
- invalid/noise_missing_output.sp / espice: SimulatorFailed
- invalid/noise_missing_output.sp / ngspice: SimulatorFailed
- invalid/noise_missing_output.sp / VACASK: MissingRaw
- invalid/noise_missing_source.sp / espice: SimulatorFailed
- invalid/noise_missing_source.sp / ngspice: SimulatorFailed
- invalid/noise_missing_source.sp / VACASK: MissingRaw
- invalid/noise_zero_frequency.sp / espice: SimulatorFailed
- invalid/noise_zero_frequency.sp / ngspice: SimulatorFailed
- invalid/noise_zero_frequency.sp / VACASK: MissingRaw
- invalid/optimize_bisection.sp / espice: SimulatorFailed
- invalid/optimize_bisection.sp / ngspice: SimulatorFailed
- invalid/optimize_bisection.sp / VACASK: .param: stray field '1k'
- invalid/options_negative_reltol.sp / espice: SimulatorFailed
- invalid/options_negative_reltol.sp / ngspice: SimulatorFailed
- invalid/pac_zero_lo.sp / espice: SimulatorFailed
- invalid/pac_zero_lo.sp / ngspice: SimulatorFailed
- invalid/pac_zero_lo.sp / VACASK: '.pac' has no VACASK counterpart here
- invalid/pnoise_fractional_sidebands.sp / espice: SimulatorFailed
- invalid/pnoise_fractional_sidebands.sp / ngspice: SimulatorFailed
- invalid/pnoise_fractional_sidebands.sp / VACASK: '.pnoise' has no VACASK counterpart here
- invalid/pnoise_negative_sidebands.sp / espice: SimulatorFailed
- invalid/pnoise_negative_sidebands.sp / ngspice: SimulatorFailed
- invalid/pnoise_negative_sidebands.sp / VACASK: '.pnoise' has no VACASK counterpart here
- invalid/pole_unpaired_root.sp / espice: SimulatorFailed
- invalid/pole_unpaired_root.sp / ngspice: SimulatorFailed
- invalid/pole_unpaired_root.sp / VACASK: e1: 11 fields, expected 6 (POLY/VALUE/TABLE forms are not translated)
- invalid/pss_negative_samples.sp / espice: SimulatorFailed
- invalid/pss_negative_samples.sp / ngspice: SimulatorFailed
- invalid/pss_negative_samples.sp / VACASK: '.pss' has no VACASK counterpart here
- invalid/pss_zero_frequency.sp / espice: SimulatorFailed
- invalid/pss_zero_frequency.sp / ngspice: SimulatorFailed
- invalid/pss_zero_frequency.sp / VACASK: '.pss' has no VACASK counterpart here
- invalid/pxf_zero_lo.sp / espice: SimulatorFailed
- invalid/pxf_zero_lo.sp / ngspice: SimulatorFailed
- invalid/pxf_zero_lo.sp / VACASK: '.pxf' has no VACASK counterpart here
- invalid/qpss_zero_second_frequency.sp / espice: SimulatorFailed
- invalid/qpss_zero_second_frequency.sp / ngspice: SimulatorFailed
- invalid/qpss_zero_second_frequency.sp / VACASK: '.qpss' has no VACASK counterpart here
- invalid/sens_unknown_node.sp / espice: SimulatorFailed
- invalid/sens_unknown_node.sp / VACASK: '.sens' has no VACASK counterpart here
- invalid/sp_zero_impedance.sp / espice: SimulatorFailed
- invalid/sp_zero_impedance.sp / ngspice: SimulatorFailed
- invalid/sp_zero_impedance.sp / VACASK: vp: unhandled source field 'portnum'
- invalid/temp_absolute_zero.sp / espice: SimulatorFailed
- invalid/temp_below_absolute_zero.sp / espice: SimulatorFailed
- invalid/temp_below_absolute_zero.sp / ngspice: FileNotFound
- invalid/temp_below_absolute_zero.sp / VACASK: .temp with 3 values (a temperature sweep is not one analysis)
- invalid/temp_zero_step.sp / espice: SimulatorFailed
- invalid/temp_zero_step.sp / ngspice: FileNotFound
- invalid/temp_zero_step.sp / VACASK: .temp with 3 values (a temperature sweep is not one analysis)
- invalid/tf_missing_output.sp / espice: SimulatorFailed
- invalid/tf_missing_output.sp / VACASK: '.tf' has no VACASK counterpart here
- invalid/tf_missing_source.sp / espice: SimulatorFailed
- invalid/tf_missing_source.sp / ngspice: SimulatorFailed
- invalid/tf_missing_source.sp / VACASK: '.tf' has no VACASK counterpart here
- invalid/tran_negative_maxstep.sp / espice: SimulatorFailed
- invalid/tran_negative_maxstep.sp / ngspice: SimulatorFailed
- invalid/tran_negative_stop.sp / espice: SimulatorFailed
- invalid/tran_negative_stop.sp / ngspice: SimulatorFailed
- invalid/tran_negative_stop.sp / VACASK: MissingRaw
- invalid/tran_zero_step.sp / espice: SimulatorFailed
- invalid/tran_zero_step.sp / ngspice: SimulatorFailed
- invalid/tran_zero_step.sp / VACASK: MissingRaw
- invalid/trannoise_zero_step.sp / espice: SimulatorFailed
- invalid/trannoise_zero_step.sp / ngspice: SimulatorFailed
- invalid/trannoise_zero_step.sp / VACASK: '.trannoise' has no VACASK counterpart here
- invalid/unresolved_parameter.sp / espice: SimulatorFailed
- invalid/unresolved_parameter.sp / ngspice: SimulatorFailed
- invalid/unresolved_parameter.sp / VACASK: SimulatorFailed
- layout/capacitive_divider_tran.sp / VACASK: MissingRaw
- layout/metal_island_tran.sp / VACASK: MissingRaw
- matex/dc.sp / ngspice: SimulatorFailed
- matex/dc.sp / VACASK: '.matex' has no VACASK counterpart here
- matex/linear_ramp.sp / ngspice: SimulatorFailed
- matex/linear_ramp.sp / VACASK: vin: PWL is not translated (VACASK's `type="pwl"` aborts on this build)
- matex/purely_algebraic.sp / ngspice: SimulatorFailed
- matex/purely_algebraic.sp / VACASK: vin: PWL is not translated (VACASK's `type="pwl"` aborts on this build)
- matex/sine.sp / ngspice: SimulatorFailed
- matex/sine.sp / VACASK: '.matex' has no VACASK counterpart here
- mc/gaussian_source.sp / ngspice: SimulatorFailed
- mc/gaussian_source.sp / VACASK: '.mc' has no VACASK counterpart here
- mc/zero_variation_1.sp / ngspice: SimulatorFailed
- mc/zero_variation_1.sp / VACASK: '.mc' has no VACASK counterpart here
- mc/zero_variation_100.sp / ngspice: SimulatorFailed
- mc/zero_variation_100.sp / VACASK: '.mc' has no VACASK counterpart here
- mc/zero_variation_2.sp / ngspice: SimulatorFailed
- mc/zero_variation_2.sp / VACASK: '.mc' has no VACASK counterpart here
- mc/zero_variation_31.sp / ngspice: SimulatorFailed
- mc/zero_variation_31.sp / VACASK: '.mc' has no VACASK counterpart here
- mc/zero_variation_32.sp / ngspice: SimulatorFailed
- mc/zero_variation_32.sp / VACASK: '.mc' has no VACASK counterpart here
- mc/zero_variation_33.sp / ngspice: SimulatorFailed
- mc/zero_variation_33.sp / VACASK: '.mc' has no VACASK counterpart here
- mc/zero_variation_7.sp / ngspice: SimulatorFailed
- mc/zero_variation_7.sp / VACASK: '.mc' has no VACASK counterpart here
- mc/zero_variation_8.sp / ngspice: SimulatorFailed
- mc/zero_variation_8.sp / VACASK: '.mc' has no VACASK counterpart here
- mc/zero_variation_9.sp / ngspice: SimulatorFailed
- mc/zero_variation_9.sp / VACASK: '.mc' has no VACASK counterpart here
- mosra/nmos_aged_vth.sp / ngspice: SimulatorFailed
- mosra/nmos_aged_vth.sp / VACASK: .model nra: type 'mosra' is not translated
- mosra/nmos_dc_stress.sp / ngspice: SimulatorFailed
- mosra/nmos_dc_stress.sp / VACASK: .model nra: type 'mosra' is not translated
- mosra/nmos_dtemp_arrhenius.sp / ngspice: SimulatorFailed
- mosra/nmos_dtemp_arrhenius.sp / VACASK: .model nra: type 'mosra' is not translated
- multi_analysis/bench_hb_tline_guard.sp / ngspice: SimulatorFailed
- multi_analysis/bench_hb_tline_guard.sp / VACASK: vin: a sin source cannot also hold the DC value a static analysis needs
- multi_analysis/bench_ngspice_lowpass_filter.sp / VACASK: v1: a sin source cannot also hold the DC value a static analysis needs
- multi_analysis/bench_ngspice_rca3040.sp / VACASK: vin: a sin source cannot also hold the DC value a static analysis needs
- multi_analysis/bench_ngspice_res_array.sp / VACASK: vin: a sin source cannot also hold the DC value a static analysis needs
- multi_analysis/bench_ngspice_res_partition.sp / VACASK: SimulatorFailed
- multi_analysis/bench_ngspice_rtlinv.sp / VACASK: vin: a pulse source cannot also hold the DC value a static analysis needs
- multi_analysis/bench_pz_filt_bridge_t.sp / VACASK: '.pz' has no VACASK counterpart here
- multi_analysis/bench_sens_diffpair.sp / VACASK: '.tf' has no VACASK counterpart here
- multi_analysis/device_vbic_ce_amp.sp / VACASK: '.pz' has no VACASK counterpart here
- noise/contributions.sp / VACASK: .noise with 8 fields
- noise/device_vbic_noise_scale.sp / VACASK: .model n1: npn LEVEL=4 has no VACASK module
- noise/differential_balanced.sp / VACASK: .noise with 8 fields
- noise/differential_unbalanced.sp / VACASK: .noise with 8 fields
- noise/jfet_channel.sp / VACASK: .noise with 1 points
- noise/noise_table_lin_clamp.sp / ngspice: SimulatorFailed
- noise/noise_table_lin_clamp.sp / VACASK: '.hdl' has no VACASK counterpart here
- noise/noise_table_lin_interior.sp / ngspice: SimulatorFailed
- noise/noise_table_lin_interior.sp / VACASK: '.hdl' has no VACASK counterpart here
- noise/noise_table_log_clamp.sp / ngspice: SimulatorFailed
- noise/noise_table_log_clamp.sp / VACASK: '.hdl' has no VACASK counterpart here
- noise/noise_table_log_interior.sp / ngspice: SimulatorFailed
- noise/noise_table_log_interior.sp / VACASK: '.hdl' has no VACASK counterpart here
- noise/noise_va_coeff.sp / ngspice: SimulatorFailed
- noise/noise_va_coeff.sp / VACASK: '.hdl' has no VACASK counterpart here
- noise/noise_va_correlated.sp / ngspice: SimulatorFailed
- noise/noise_va_correlated.sp / VACASK: '.hdl' has no VACASK counterpart here
- noise/noise_va_ground.sp / ngspice: SimulatorFailed
- noise/noise_va_ground.sp / VACASK: '.hdl' has no VACASK counterpart here
- op/bsource_brace_expr.sp / VACASK: 'b' device (b1) has no VACASK counterpart here
- op/device_b3soidd.sp / VACASK: .model nsoidd: nmos LEVEL=56 has no VACASK module
- op/device_b3soifd.sp / VACASK: .model nsoifd: nmos LEVEL=55 has no VACASK module
- op/device_b3soipd.sp / VACASK: .model nsoipd: nmos LEVEL=10 has no VACASK module
- op/device_b4soi.sp / VACASK: .model nb4soi: nmos LEVEL=58 has no VACASK module
- op/device_bsim3.sp / VACASK: SimulatorFailed
- op/device_hfet1.sp / VACASK: 'z' device (z1) has no VACASK counterpart here
- op/device_hfet2.sp / VACASK: 'z' device (z1) has no VACASK counterpart here
- op/device_hicum2.sp / VACASK: .model hic2: npn LEVEL=8 has no VACASK module
- op/device_lossy_tline_rg.sp / ngspice: SimulatorFailed
- op/device_lossy_tline_rg.sp / VACASK: 'o' device (o1) has no VACASK counterpart here
- op/device_mesa.sp / VACASK: 'z' device (z1) has no VACASK counterpart here
- op/device_mesfet.sp / VACASK: 'z' device (z1) has no VACASK counterpart here
- op/device_vbic.sp / VACASK: .model vb1: npn LEVEL=4 has no VACASK module
- op/device_vdmos.sp / VACASK: m1: 3 nodes before the model name, expected 4
- op/nodeset_latch.sp / VACASK: '.nodeset' has no VACASK counterpart here
- optimize/bisection_divider.sp / ngspice: SimulatorFailed
- optimize/bisection_divider.sp / VACASK: .param: stray field '5k'
- optimize/bisection_rc_max.sp / ngspice: SimulatorFailed
- optimize/bisection_rc_max.sp / VACASK: .param: stray field '1k'
- optimize/divider_goal.sp / ngspice: SimulatorFailed
- optimize/divider_goal.sp / VACASK: .param: stray field '1k'
- optimize/inequality_goals.sp / ngspice: SimulatorFailed
- optimize/inequality_goals.sp / VACASK: .param: stray field '1k'
- optimize/passfail_level3.sp / ngspice: SimulatorFailed
- optimize/passfail_level3.sp / VACASK: .param: stray field '5k'
- optimize/rc_delay_fit.sp / ngspice: SimulatorFailed
- optimize/rc_delay_fit.sp / VACASK: .param: stray field '1k'
- optimize/step_optimize.sp / ngspice: SimulatorFailed
- optimize/step_optimize.sp / VACASK: .param: stray field '1k'
- optimize/two_param_ladder.sp / ngspice: SimulatorFailed
- optimize/two_param_ladder.sp / VACASK: .param: stray field '1k'
- optimize/unreachable_goal.sp / ngspice: SimulatorFailed
- optimize/unreachable_goal.sp / VACASK: .param: stray field '1k'
- pac/divider.sp / ngspice: SimulatorFailed
- pac/divider.sp / VACASK: '.pac' has no VACASK counterpart here
- pac/ideal_multiplier_1.sp / ngspice: SimulatorFailed
- pac/ideal_multiplier_1.sp / VACASK: vlo: SIN phase (90 deg) is accepted but ignored by VACASK
- pac/ideal_multiplier_2.sp / ngspice: SimulatorFailed
- pac/ideal_multiplier_2.sp / VACASK: vlo: SIN phase (90 deg) is accepted but ignored by VACASK
- pac/rc.sp / ngspice: SimulatorFailed
- pac/rc.sp / VACASK: '.pac' has no VACASK counterpart here
- pac/two_poles.sp / ngspice: SimulatorFailed
- pac/two_poles.sp / VACASK: '.pac' has no VACASK counterpart here
- phasenoise/acphasenoise_rc.sp / ngspice: SimulatorFailed
- phasenoise/acphasenoise_rc.sp / VACASK: '.acphasenoise' has no VACASK counterpart here
- phasenoise/am_noise.sp / ngspice: SimulatorFailed
- phasenoise/am_noise.sp / VACASK: 'b' device (bneg) has no VACASK counterpart here
- phasenoise/lc_oscillator.sp / ngspice: SimulatorFailed
- phasenoise/lc_oscillator.sp / VACASK: 'b' device (bneg) has no VACASK counterpart here
- phasenoise/meas_phasenoise.sp / ngspice: SimulatorFailed
- phasenoise/meas_phasenoise.sp / VACASK: 'b' device (bneg) has no VACASK counterpart here
- phasenoise/varactor_flicker.sp / ngspice: SimulatorFailed
- phasenoise/varactor_flicker.sp / VACASK: 'b' device (bc) has no VACASK counterpart here
- pnoise/clamped_output.sp / ngspice: SimulatorFailed
- pnoise/clamped_output.sp / VACASK: '.pnoise' has no VACASK counterpart here
- pnoise/differential_rc.sp / ngspice: SimulatorFailed
- pnoise/differential_rc.sp / VACASK: '.pnoise' has no VACASK counterpart here
- pnoise/lti_rc_sidebands_0.sp / ngspice: SimulatorFailed
- pnoise/lti_rc_sidebands_0.sp / VACASK: '.pnoise' has no VACASK counterpart here
- pnoise/lti_rc_sidebands_1.sp / ngspice: SimulatorFailed
- pnoise/lti_rc_sidebands_1.sp / VACASK: '.pnoise' has no VACASK counterpart here
- pnoise/lti_rc_sidebands_3.sp / ngspice: SimulatorFailed
- pnoise/lti_rc_sidebands_3.sp / VACASK: '.pnoise' has no VACASK counterpart here
- pnoise/lti_rc_sidebands_7.sp / ngspice: SimulatorFailed
- pnoise/lti_rc_sidebands_7.sp / VACASK: '.pnoise' has no VACASK counterpart here
- pnoise/noise_multiplier_1.sp / ngspice: SimulatorFailed
- pnoise/noise_multiplier_1.sp / VACASK: vlo: SIN phase (90 deg) is accepted but ignored by VACASK
- pnoise/noise_multiplier_2.sp / ngspice: SimulatorFailed
- pnoise/noise_multiplier_2.sp / VACASK: vlo: SIN phase (90 deg) is accepted but ignored by VACASK
- pss/bench_pss_diode_rect_driven.sp / ngspice: SimulatorFailed
- pss/bench_pss_diode_rect_driven.sp / VACASK: '.pss' has no VACASK counterpart here
- pss/bench_pss_rlc_driven.sp / ngspice: SimulatorFailed
- pss/bench_pss_rlc_driven.sp / VACASK: '.pss' has no VACASK counterpart here
- pss/dc_is_periodic.sp / ngspice: SimulatorFailed
- pss/dc_is_periodic.sp / VACASK: '.pss' has no VACASK counterpart here
- pss/diode_clipper.sp / ngspice: SimulatorFailed
- pss/diode_clipper.sp / VACASK: '.pss' has no VACASK counterpart here
- pss/diode_rectifier_rc.sp / ngspice: SimulatorFailed
- pss/diode_rectifier_rc.sp / VACASK: '.pss' has no VACASK counterpart here
- pss/polynomial_2.sp / ngspice: SimulatorFailed
- pss/polynomial_2.sp / VACASK: 'b' device (bout) has no VACASK counterpart here
- pss/polynomial_3.sp / ngspice: SimulatorFailed
- pss/polynomial_3.sp / VACASK: 'b' device (bout) has no VACASK counterpart here
- pss/rc_default.sp / ngspice: SimulatorFailed
- pss/rc_default.sp / VACASK: '.pss' has no VACASK counterpart here
- pss/rc_fast.sp / ngspice: SimulatorFailed
- pss/rc_fast.sp / VACASK: '.pss' has no VACASK counterpart here
- pss/rc_minimal_grid.sp / ngspice: SimulatorFailed
- pss/rc_minimal_grid.sp / VACASK: '.pss' has no VACASK counterpart here
- pss/rc_negative_amplitude.sp / ngspice: SimulatorFailed
- pss/rc_negative_amplitude.sp / VACASK: '.pss' has no VACASK counterpart here
- pss/rc_offset.sp / ngspice: SimulatorFailed
- pss/rc_offset.sp / VACASK: '.pss' has no VACASK counterpart here
- pss/rc_slow_settling.sp / ngspice: SimulatorFailed
- pss/rc_slow_settling.sp / VACASK: '.pss' has no VACASK counterpart here
- pss/ring_oscillator.sp / ngspice: SimulatorFailed
- pss/ring_oscillator.sp / VACASK: 'b' device (b1) has no VACASK counterpart here
- pss/ring_oscillator_krylov.sp / ngspice: SimulatorFailed
- pss/ring_oscillator_krylov.sp / VACASK: 'b' device (b1) has no VACASK counterpart here
- pss/ring_oscillator_snosc.sp / ngspice: SimulatorFailed
- pss/ring_oscillator_snosc.sp / VACASK: 'b' device (b1) has no VACASK counterpart here
- pxf/divider.sp / ngspice: SimulatorFailed
- pxf/divider.sp / VACASK: '.pxf' has no VACASK counterpart here
- pxf/rc.sp / ngspice: SimulatorFailed
- pxf/rc.sp / VACASK: '.pxf' has no VACASK counterpart here
- pxf/two_poles.sp / ngspice: SimulatorFailed
- pxf/two_poles.sp / VACASK: '.pxf' has no VACASK counterpart here
- pz/bench_pz_filt_multistage.sp / VACASK: '.pz' has no VACASK counterpart here
- pz/bench_pz_pz2.sp / VACASK: '.pz' has no VACASK counterpart here
- pz/bench_pz_pzt.sp / VACASK: '.pz' has no VACASK counterpart here
- pz/bench_pz_simplepz.sp / VACASK: '.pz' has no VACASK counterpart here
- pz/bench_pz_two_pole.sp / VACASK: '.pz' has no VACASK counterpart here
- pz/purely_resistive.sp / ngspice: SimulatorFailed
- pz/purely_resistive.sp / VACASK: '.pz' has no VACASK counterpart here
- pz/rc_highpass_zero.sp / ngspice: SimulatorFailed
- pz/rc_highpass_zero.sp / VACASK: '.pz' has no VACASK counterpart here
- pz/rc_lowpass_ports.sp / ngspice: SimulatorFailed
- pz/rc_lowpass_ports.sp / VACASK: '.pz' has no VACASK counterpart here
- pz/rc_tau_0p001.sp / ngspice: SimulatorFailed
- pz/rc_tau_0p001.sp / VACASK: '.pz' has no VACASK counterpart here
- pz/rc_tau_1.sp / ngspice: SimulatorFailed
- pz/rc_tau_1.sp / VACASK: '.pz' has no VACASK counterpart here
- pz/rc_tau_1000.sp / ngspice: SimulatorFailed
- pz/rc_tau_1000.sp / VACASK: '.pz' has no VACASK counterpart here
- pz/rc_tau_1e-06.sp / ngspice: SimulatorFailed
- pz/rc_tau_1e-06.sp / VACASK: '.pz' has no VACASK counterpart here
- pz/rc_tau_1e-09.sp / ngspice: SimulatorFailed
- pz/rc_tau_1e-09.sp / VACASK: '.pz' has no VACASK counterpart here
- pz/rlc_notch_zeros.sp / ngspice: SimulatorFailed
- pz/rlc_notch_zeros.sp / VACASK: '.pz' has no VACASK counterpart here
- pz/rlc_r_1.sp / ngspice: SimulatorFailed
- pz/rlc_r_1.sp / VACASK: '.pz' has no VACASK counterpart here
- pz/rlc_r_10.sp / ngspice: SimulatorFailed
- pz/rlc_r_10.sp / VACASK: '.pz' has no VACASK counterpart here
- pz/rlc_r_100.sp / ngspice: SimulatorFailed
- pz/rlc_r_100.sp / VACASK: '.pz' has no VACASK counterpart here
- pz/rlc_r_1000.sp / ngspice: SimulatorFailed
- pz/rlc_r_1000.sp / VACASK: '.pz' has no VACASK counterpart here
- pz/rlc_r_63p2456.sp / ngspice: SimulatorFailed
- pz/rlc_r_63p2456.sp / VACASK: '.pz' has no VACASK counterpart here
- pz/two_equal_uncoupled.sp / ngspice: SimulatorFailed
- pz/two_equal_uncoupled.sp / VACASK: '.pz' has no VACASK counterpart here
- pz/unbuffered_ladder.sp / ngspice: SimulatorFailed
- pz/unbuffered_ladder.sp / VACASK: '.pz' has no VACASK counterpart here
- pz/unstable_negative_conductance.sp / ngspice: SimulatorFailed
- pz/unstable_negative_conductance.sp / VACASK: '.pz' has no VACASK counterpart here
- pz/widely_separated_modes.sp / ngspice: SimulatorFailed
- pz/widely_separated_modes.sp / VACASK: '.pz' has no VACASK counterpart here
- qpss/idt_lowpass_two_tone.sp / ngspice: SimulatorFailed
- qpss/idt_lowpass_two_tone.sp / VACASK: '.hdl' has no VACASK counterpart here
- qpss/linear_two_tone_1_1.sp / ngspice: SimulatorFailed
- qpss/linear_two_tone_1_1.sp / VACASK: '.qpss' has no VACASK counterpart here
- qpss/linear_two_tone_2_2.sp / ngspice: SimulatorFailed
- qpss/linear_two_tone_2_2.sp / VACASK: '.qpss' has no VACASK counterpart here
- qpss/linear_two_tone_3_2.sp / ngspice: SimulatorFailed
- qpss/linear_two_tone_3_2.sp / VACASK: '.qpss' has no VACASK counterpart here
- qpss/square_mixer.sp / ngspice: SimulatorFailed
- qpss/square_mixer.sp / VACASK: 'b' device (bout) has no VACASK counterpart here
- reference/cmos_inverter_dc.sp / VACASK: vin: a pulse source cannot also hold the DC value a static analysis needs
- reference/lossless_transmission_line.sp / VACASK: 't' device (t1) has no VACASK counterpart here
- reference/voltage_switch_hysteresis.sp / VACASK: vc: PWL is not translated (VACASK's `type="pwl"` aborts on this build)
- sens/balanced.sp / VACASK: '.sens' has no VACASK counterpart here
- sens/bench_sens_bridge.sp / VACASK: '.sens' has no VACASK counterpart here
- sens/divider.sp / VACASK: '.sens' has no VACASK counterpart here
- sens/high_impedance.sp / VACASK: '.sens' has no VACASK counterpart here
- sens/low_impedance.sp / VACASK: '.sens' has no VACASK counterpart here
- sens/negative_bias.sp / VACASK: '.sens' has no VACASK counterpart here
- sp/bench_sp_lc_lowpass.sp / VACASK: vp1: unhandled source field 'portnum'
- sp/bench_sp_rc_twoport.sp / VACASK: vp1: unhandled source field 'portnum'
- sp/capacitor.sp / ngspice: SimulatorFailed
- sp/capacitor.sp / VACASK: vp: unhandled source field 'portnum'
- sp/inductor.sp / ngspice: SimulatorFailed
- sp/inductor.sp / VACASK: vp: unhandled source field 'portnum'
- sp/linear_grid_1.sp / ngspice: SimulatorFailed
- sp/linear_grid_1.sp / VACASK: vp: unhandled source field 'portnum'
- sp/linear_grid_17.sp / ngspice: SimulatorFailed
- sp/linear_grid_17.sp / VACASK: vp: unhandled source field 'portnum'
- sp/linear_grid_3.sp / ngspice: SimulatorFailed
- sp/linear_grid_3.sp / VACASK: vp: unhandled source field 'portnum'
- sp/linear_grid_8.sp / ngspice: SimulatorFailed
- sp/linear_grid_8.sp / VACASK: vp: unhandled source field 'portnum'
- sp/matched_pi_attenuator.sp / VACASK: vp1: unhandled source field 'portnum'
- sp/one_port_0p001.sp / ngspice: SimulatorFailed
- sp/one_port_0p001.sp / VACASK: vp: unhandled source field 'portnum'
- sp/one_port_100.sp / ngspice: SimulatorFailed
- sp/one_port_100.sp / VACASK: vp: unhandled source field 'portnum'
- sp/one_port_1e+09.sp / ngspice: SimulatorFailed
- sp/one_port_1e+09.sp / VACASK: vp: unhandled source field 'portnum'
- sp/one_port_25.sp / ngspice: SimulatorFailed
- sp/one_port_25.sp / VACASK: vp: unhandled source field 'portnum'
- sp/one_port_50.sp / ngspice: SimulatorFailed
- sp/one_port_50.sp / VACASK: vp: unhandled source field 'portnum'
- sp/one_port_75.sp / ngspice: SimulatorFailed
- sp/one_port_75.sp / VACASK: vp: unhandled source field 'portnum'
- sp/parallel_rc.sp / ngspice: SimulatorFailed
- sp/parallel_rc.sp / VACASK: vp: unhandled source field 'portnum'
- sp/series_0p001_z_50_50.sp / VACASK: vp1: unhandled source field 'portnum'
- sp/series_1000_z_50_50.sp / VACASK: vp1: unhandled source field 'portnum'
- sp/series_100_z_50_50.sp / VACASK: vp1: unhandled source field 'portnum'
- sp/series_25_z_25_100.sp / VACASK: vp1: unhandled source field 'portnum'
- sp/series_50_z_50_50.sp / VACASK: vp1: unhandled source field 'portnum'
- stb/lstb_diff_comm.sp / ngspice: SimulatorFailed
- stb/lstb_diff_comm.sp / VACASK: '.lstb' has no VACASK counterpart here
- stb/lstb_loaded_break.sp / ngspice: SimulatorFailed
- stb/lstb_loaded_break.sp / VACASK: '.lstb' has no VACASK counterpart here
- stb/lstb_localgnd.sp / ngspice: SimulatorFailed
- stb/lstb_localgnd.sp / VACASK: '.lstb' has no VACASK counterpart here
- stb/lstb_three_pole.sp / ngspice: SimulatorFailed
- stb/lstb_three_pole.sp / VACASK: '.lstb' has no VACASK counterpart here
- stb/negative_feedback_gain_1.sp / ngspice: SimulatorFailed
- stb/negative_feedback_gain_1.sp / VACASK: '.stb' has no VACASK counterpart here
- stb/negative_feedback_gain_10.sp / ngspice: SimulatorFailed
- stb/negative_feedback_gain_10.sp / VACASK: '.stb' has no VACASK counterpart here
- stb/negative_feedback_gain_100.sp / ngspice: SimulatorFailed
- stb/negative_feedback_gain_100.sp / VACASK: '.stb' has no VACASK counterpart here
- stb/negative_feedback_gain_100000.sp / ngspice: SimulatorFailed
- stb/negative_feedback_gain_100000.sp / VACASK: '.stb' has no VACASK counterpart here
- stb/one_pole_1e-06.sp / ngspice: SimulatorFailed
- stb/one_pole_1e-06.sp / VACASK: '.stb' has no VACASK counterpart here
- stb/one_pole_1e-09.sp / ngspice: SimulatorFailed
- stb/one_pole_1e-09.sp / VACASK: '.stb' has no VACASK counterpart here
- stress/vacask_graetz.sp / VACASK: .options maxord= changes the answer and has no known VACASK spelling
- stress/vacask_mul.sp / VACASK: '{c}': expressions are not translated
- stress/vacask_ring.sp / ngspice: ngspice-45 has no PSP103 (LEVEL=1040)
- stress/vacask_ring.sp / VACASK: '{w}': expressions are not translated
- syntax/global_net.sp / VACASK: '.global' has no VACASK counterpart here
- syntax/hspice_suffix.sp / VACASK: ''rval'': expressions are not translated
- syntax/subckt_params.sp / VACASK: '{r}': expressions are not translated
- temp/fine.sp / ngspice: FileNotFound
- temp/fine.sp / VACASK: .temp with 3 values (a temperature sweep is not one analysis)
- temp/nominal.sp / ngspice: FileNotFound
- temp/nominal.sp / VACASK: .temp with 3 values (a temperature sweep is not one analysis)
- temp/resistor_tc_-0p001_0.sp / ngspice: FileNotFound
- temp/resistor_tc_-0p001_0.sp / VACASK: .temp with 3 values (a temperature sweep is not one analysis)
- temp/resistor_tc_0_1e-05.sp / ngspice: FileNotFound
- temp/resistor_tc_0_1e-05.sp / VACASK: .temp with 3 values (a temperature sweep is not one analysis)
- temp/resistor_tc_0p001_0.sp / ngspice: FileNotFound
- temp/resistor_tc_0p001_0.sp / VACASK: .temp with 3 values (a temperature sweep is not one analysis)
- temp/resistor_tc_0p001_1e-05.sp / ngspice: FileNotFound
- temp/resistor_tc_0p001_1e-05.sp / VACASK: .temp with 3 values (a temperature sweep is not one analysis)
- temp/wide.sp / ngspice: FileNotFound
- temp/wide.sp / VACASK: .temp with 3 values (a temperature sweep is not one analysis)
- tf/balanced.sp / VACASK: '.tf' has no VACASK counterpart here
- tf/bench_tf_r_ladder.sp / VACASK: '.tf' has no VACASK counterpart here
- tf/current_input.sp / VACASK: '.tf' has no VACASK counterpart here
- tf/current_output.sp / VACASK: '.tf' has no VACASK counterpart here
- tf/differential_output.sp / VACASK: '.tf' has no VACASK counterpart here
- tf/diode_bias_0p4.sp / VACASK: '.tf' has no VACASK counterpart here
- tf/diode_bias_0p7.sp / VACASK: '.tf' has no VACASK counterpart here
- tf/diode_bias_5.sp / VACASK: '.tf' has no VACASK counterpart here
- tf/divider.sp / VACASK: '.tf' has no VACASK counterpart here
- tf/high_impedance.sp / VACASK: '.tf' has no VACASK counterpart here
- tf/ideal_voltage_output.sp / VACASK: '.tf' has no VACASK counterpart here
- tf/low_impedance.sp / VACASK: '.tf' has no VACASK counterpart here
- tf/negative_bias.sp / VACASK: '.tf' has no VACASK counterpart here
- tf/second_source.sp / VACASK: '.tf' has no VACASK counterpart here
- tran/bench_bypass_burst_clock.sp / VACASK: vin: PWL is not translated (VACASK's `type="pwl"` aborts on this build)
- tran/bench_ngspice_mosamp.sp / VACASK: .options trtol= changes the answer and has no known VACASK spelling
- tran/bench_ngspice_mosmem.sp / VACASK: SimulatorFailed
- tran/bench_tline_cpl3_4_line.sp / VACASK: 'p' device (p1) has no VACASK counterpart here
- tran/bench_tline_cpl_ibm2.sp / VACASK: 'p' device (p1) has no VACASK counterpart here
- tran/bench_tline_delay_line.sp / VACASK: 't' device (t1) has no VACASK counterpart here
- tran/bench_tline_ideal_tline.sp / VACASK: 't' device (t1) has no VACASK counterpart here
- tran/bench_tline_ltra1_1_line.sp / VACASK: 'o' device (o1) has no VACASK counterpart here
- tran/bench_tline_ltra2_2_line.sp / VACASK: 'o' device (o1) has no VACASK counterpart here
- tran/bench_tline_terminated.sp / VACASK: 't' device (t1) has no VACASK counterpart here
- tran/bench_tline_txl1_1_line.sp / VACASK: 'y' device (y1) has no VACASK counterpart here
- tran/bench_tline_txl2_3_line.sp / VACASK: 'y' device (y1) has no VACASK counterpart here
- tran/device_coupled_tlines.sp / VACASK: 'p' device (p1) has no VACASK counterpart here
- tran/device_cswitch.sp / VACASK: vctl: PWL is not translated (VACASK's `type="pwl"` aborts on this build)
- tran/device_hfet_inverter.sp / VACASK: 'z' device (z1) has no VACASK counterpart here
- tran/device_lossy_tline.sp / VACASK: 'o' device (o1) has no VACASK counterpart here
- tran/device_mesa_oscillator.sp / VACASK: 'b' device (bl1) has no VACASK counterpart here
- tran/device_mesa_oscillator_fast.sp / VACASK: 'b' device (bl1) has no VACASK counterpart here
- tran/device_mos6_inverter.sp / VACASK: vin: PWL is not translated (VACASK's `type="pwl"` aborts on this build)
- tran/device_mos6_simpleinv.sp / VACASK: vin: PWL is not translated (VACASK's `type="pwl"` aborts on this build)
- tran/device_switch.sp / VACASK: vc: PWL is not translated (VACASK's `type="pwl"` aborts on this build)
- tran/device_switch_hysteresis.sp / VACASK: vc: PWL is not translated (VACASK's `type="pwl"` aborts on this build)
- tran/device_tline.sp / VACASK: 't' device (t1) has no VACASK counterpart here
- tran/device_urc.sp / VACASK: 'u' device (u1) has no VACASK counterpart here
- tran/ic_large.sp / VACASK: '.ic' has no VACASK counterpart here
- tran/ic_negative.sp / VACASK: '.ic' has no VACASK counterpart here
- tran/ic_no_uic_op.sp / VACASK: '.nodeset' has no VACASK counterpart here
- tran/ic_small.sp / VACASK: '.ic' has no VACASK counterpart here
- tran/jitter_sffm.sp / ngspice: SimulatorFailed
- tran/jitter_sffm.sp / VACASK: '.jitter' has no VACASK counterpart here
- tran/lc_energy_gear.sp / VACASK: '.ic' has no VACASK counterpart here
- tran/lc_energy_trap.sp / VACASK: '.ic' has no VACASK counterpart here
- tran/output_start_time.sp / VACASK: .tran TSTART=1m has no VACASK counterpart
- tran/pwl_isource_breakpoints.sp / VACASK: i1: PWL is not translated (VACASK's `type="pwl"` aborts on this build)
- tran/pwl_nonzero_start.sp / VACASK: vin: PWL is not translated (VACASK's `type="pwl"` aborts on this build)
- tran/pwl_triangle.sp / VACASK: vin: PWL is not translated (VACASK's `type="pwl"` aborts on this build)
- tran/rc_discharge_euler_0p001.sp / VACASK: '.ic' has no VACASK counterpart here
- tran/rc_discharge_euler_1.sp / VACASK: '.ic' has no VACASK counterpart here
- tran/rc_discharge_euler_1e-06.sp / VACASK: '.ic' has no VACASK counterpart here
- tran/rc_discharge_gear_0p001.sp / VACASK: '.ic' has no VACASK counterpart here
- tran/rc_discharge_gear_1.sp / VACASK: '.ic' has no VACASK counterpart here
- tran/rc_discharge_gear_1e-06.sp / VACASK: '.ic' has no VACASK counterpart here
- tran/rc_discharge_trap_0p001.sp / VACASK: '.ic' has no VACASK counterpart here
- tran/rc_discharge_trap_1.sp / VACASK: '.ic' has no VACASK counterpart here
- tran/rc_discharge_trap_1e-06.sp / VACASK: '.ic' has no VACASK counterpart here
- tran/sine_offset_phase.sp / VACASK: vin: SIN phase (90 deg) is accepted but ignored by VACASK
- tran/trap_xmu_damping.sp / VACASK: vin: PWL is not translated (VACASK's `type="pwl"` aborts on this build)
- tran_noise/hspice_samples.sp / ngspice: SimulatorFailed
- tran_noise/hspice_samples.sp / VACASK: '.trannoise' has no VACASK counterpart here
- tran_noise/hspice_sde_flicker.sp / ngspice: SimulatorFailed
- tran_noise/hspice_sde_flicker.sp / VACASK: '.trannoise' has no VACASK counterpart here
- tran_noise/hspice_sde_rc.sp / ngspice: SimulatorFailed
- tran_noise/hspice_sde_rc.sp / VACASK: '.trannoise' has no VACASK counterpart here
- tran_noise/ideal_clamp_-2.sp / ngspice: SimulatorFailed
- tran_noise/ideal_clamp_-2.sp / VACASK: '.trannoise' has no VACASK counterpart here
- tran_noise/ideal_clamp_0.sp / ngspice: SimulatorFailed
- tran_noise/ideal_clamp_0.sp / VACASK: '.trannoise' has no VACASK counterpart here
- tran_noise/ideal_clamp_2.sp / ngspice: SimulatorFailed
- tran_noise/ideal_clamp_2.sp / VACASK: '.trannoise' has no VACASK counterpart here
- tran_noise/jfet_flicker.sp / ngspice: SimulatorFailed
- tran_noise/jfet_flicker.sp / VACASK: '.trannoise' has no VACASK counterpart here
- tran_noise/rc_equilibrium.sp / ngspice: SimulatorFailed
- tran_noise/rc_equilibrium.sp / VACASK: '.trannoise' has no VACASK counterpart here
- variants/alter_cumulative.sp / ngspice: SimulatorFailed
- variants/alter_cumulative.sp / VACASK: '.alter' has no VACASK counterpart here
- variants/data_lam.sp / ngspice: SimulatorFailed
- variants/data_lam.sp / VACASK: '.data' has no VACASK counterpart here
- variants/data_mer.sp / ngspice: SimulatorFailed
- variants/data_mer.sp / VACASK: '.data' has no VACASK counterpart here
- variants/data_sweep.sp / ngspice: SimulatorFailed
- variants/data_sweep.sp / VACASK: '.data' has no VACASK counterpart here
- variants/monte_dev_lot.sp / ngspice: SimulatorFailed
- variants/monte_dev_lot.sp / VACASK: .options seed= changes the answer and has no known VACASK spelling
- variants/monte_divider.sp / ngspice: SimulatorFailed
- variants/monte_divider.sp / VACASK: .param: stray field '1k'
- variants/monte_list.sp / ngspice: SimulatorFailed
- variants/monte_list.sp / VACASK: .param: stray field '1k'
- variants/monte_tran_meas.sp / ngspice: SimulatorFailed
- variants/monte_tran_meas.sp / VACASK: .param: stray field '1k'
- variants/step_param_bsource_bare.sp / ngspice: SimulatorFailed
- variants/step_param_bsource_bare.sp / VACASK: 'b' device (bout) has no VACASK counterpart here
- variants/step_param_divider.sp / ngspice: SimulatorFailed
- variants/step_param_divider.sp / VACASK: ''rv/2'': expressions are not translated
- variants/step_temp_source.sp / ngspice: SimulatorFailed
- variants/step_temp_source.sp / VACASK: '.step' has no VACASK counterpart here
- xf/diode_divider.sp / ngspice: SimulatorFailed
- xf/diode_divider.sp / VACASK: '.dcxf' has no VACASK counterpart here
- xf/resistive_bridge.sp / ngspice: SimulatorFailed
- xf/resistive_bridge.sp / VACASK: '.dcxf' has no VACASK counterpart here
- xf/sensed_source.sp / ngspice: SimulatorFailed
- xf/sensed_source.sp / VACASK: '.dcxf' has no VACASK counterpart here
